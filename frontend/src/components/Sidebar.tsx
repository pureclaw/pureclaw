import type { HarnessInfo, SessionInfo } from '../types'
import { ActivityDot } from './StatusDot'

function SectionHeader({ label }: { label: string }) {
  return (
    <div
      className="px-3 py-1.5 text-xs font-semibold uppercase"
      style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
    >
      {label}
    </div>
  )
}

function HarnessRow({
  harness,
  selected,
  onSelect,
}: {
  harness: HarnessInfo
  selected: boolean
  onSelect: () => void
}) {
  const isThinking = harness.activity === 'thinking'

  const rowClasses = [
    'agent-row px-3 py-2',
    selected ? 'selected' : '',
    isThinking ? 'shimmer' : '',
  ].filter(Boolean).join(' ')

  const nameColor = harness.activity === 'stopped'
    ? 'var(--text-muted)'
    : 'var(--text-primary)'

  const activityLabel = harness.activity === 'thinking'
    ? 'Thinking\u2026'
    : harness.activity === 'idle'
      ? 'Idle'
      : 'Stopped'

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        <ActivityDot activity={harness.activity} />
        <span
          className="text-sm font-medium"
          style={{ color: nameColor, letterSpacing: 'var(--tracking-tight)' }}
        >
          {harness.name}
        </span>
      </div>
      <div
        className="text-xs ml-4 mt-0.5"
        style={{ color: 'var(--text-muted)', lineHeight: 'var(--leading-tight)' }}
      >
        {activityLabel}
      </div>
    </div>
  )
}

function ArchiveButton({ onArchive }: { onArchive: () => void }) {
  return (
    <button
      className="session-archive"
      title="Archive (hide from Recent Sessions; transcript stays on disk)"
      aria-label="Archive session"
      onClick={(e) => { e.stopPropagation(); onArchive() }}
    >
      <svg
        width="11" height="11" viewBox="0 0 16 16" fill="none"
        stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
        aria-hidden="true"
      >
        <rect x="2" y="3" width="12" height="3" rx="0.5" />
        <path d="M3 6 v6 a1 1 0 0 0 1 1 h8 a1 1 0 0 0 1 -1 v-6" />
        <path d="M6.5 9 h3" />
      </svg>
    </button>
  )
}

function SessionRow({
  session,
  selected,
  onSelect,
  onArchive,
}: {
  session: SessionInfo
  selected: boolean
  onSelect: () => void
  onArchive: (id: string) => void
}) {
  const rowClasses = [
    'agent-row session-row px-3 py-2',
    selected ? 'selected' : '',
  ].filter(Boolean).join(' ')

  const displayName = session.agent ?? session.id
  const age = formatAge(session.lastActive)

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        <span
          className="text-sm truncate"
          style={{ color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {displayName}
        </span>
        <span className="pill token-count ml-auto">{age}</span>
        <ArchiveButton onArchive={() => onArchive(session.id)} />
      </div>
      {session.model && (
        <div
          className="text-xs ml-0 mt-0.5"
          style={{ color: 'var(--text-faint)', lineHeight: 'var(--leading-tight)' }}
        >
          {shortenModel(session.model)}
        </div>
      )}
    </div>
  )
}

function formatAge(isoDate: string): string {
  const diff = Date.now() - new Date(isoDate).getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'now'
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  const days = Math.floor(hours / 24)
  return `${days}d`
}

function shortenModel(model: string): string {
  // "claude-sonnet-4-20250514" → "sonnet-4"
  const m = model.match(/claude-(\w+-\d+)/)
  return m ? m[1]! : model
}

export function Sidebar({
  harnesses,
  sessions,
  selectedId,
  onSelect,
  onArchiveSession,
}: {
  harnesses: HarnessInfo[]
  sessions: SessionInfo[]
  selectedId: string | null
  onSelect: (type: 'harness' | 'session', id: string) => void
  onArchiveSession: (id: string) => void
}) {
  return (
    <div
      className="shrink-0 flex flex-col"
      style={{ width: 'var(--sidebar-width)', background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
    >
      <div className="flex-1 overflow-y-auto sidebar-scroll py-1">
        {harnesses.length > 0 && (
          <>
            <SectionHeader label="Harnesses" />
            {harnesses.map((h) => (
              <HarnessRow
                key={h.name}
                harness={h}
                selected={selectedId === `harness:${h.name}`}
                onSelect={() => onSelect('harness', h.name)}
              />
            ))}
          </>
        )}
        {sessions.length > 0 && (
          <>
            <SectionHeader label="Recent Sessions" />
            {sessions.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                selected={selectedId === `session:${s.id}`}
                onSelect={() => onSelect('session', s.id)}
                onArchive={onArchiveSession}
              />
            ))}
          </>
        )}
        {harnesses.length === 0 && sessions.length === 0 && (
          <div className="px-3 py-4 text-xs" style={{ color: 'var(--text-muted)' }}>
            No harnesses or sessions yet.
          </div>
        )}
      </div>
    </div>
  )
}
