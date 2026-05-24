import type { SessionInfo, TabInfo } from '../types'
import { sessionDisplayTitle, sessionSubtitle } from '../types'
import type { SessionActivityState } from '../types/stream'
import { ActiveTabs } from './ActiveTabs'
import { ArchivedSessions } from './ArchivedSessions'
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
  activity,
}: {
  session: SessionInfo
  selected: boolean
  onSelect: () => void
  onArchive: (id: string) => void
  activity?: SessionActivityState
}) {
  const isThinking = activity?.harness === 'thinking'
  const unread = activity?.unread ?? 0

  const rowClasses = [
    'agent-row session-row px-3 py-2',
    selected ? 'selected' : '',
    isThinking ? 'shimmer' : '',
  ].filter(Boolean).join(' ')

  const displayName = sessionDisplayTitle(session)
  // Prefer the live "last entry at" timestamp when available; fall back to
  // the meta's lastActive otherwise.
  const ageBasis = activity?.lastEntryAt ?? session.lastActive
  const age = formatAge(ageBasis)

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        {isThinking && <ActivityDot activity="thinking" />}
        <span
          className="text-sm truncate mr-auto"
          style={{ color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {displayName}
        </span>
        {unread > 0 && (
          <span
            className="pill"
            style={{
              background: 'var(--accent-primary)',
              color: 'var(--text-primary)',
              padding: '0 0.4em',
              fontSize: '0.7em',
            }}
            aria-label={`${unread} new entries`}
          >
            {unread}
          </span>
        )}
        <ArchiveButton onArchive={() => onArchive(session.id)} />
        <span className="pill token-count">{age}</span>
      </div>
      {(session.agent || session.model) && (
        <div
          className="text-xs ml-0 mt-0.5"
          style={{ color: 'var(--text-faint)', lineHeight: 'var(--leading-tight)' }}
        >
          {sessionSubtitle(session)}
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

export function Sidebar({
  tabs,
  sessions,
  archivedSessions,
  selectedId,
  sessionActivity,
  onSelectTab,
  onSelectSession,
  onNewTab,
  onArchiveSession,
  onUnarchiveSession,
  onCloseTab,
  onArchiveTab,
  onResumeArchivedSession,
}: {
  tabs: TabInfo[]
  sessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  onSelectTab: (index: number) => void
  onSelectSession: (id: string) => void
  onNewTab: () => void
  onArchiveSession: (id: string) => void
  onUnarchiveSession: (id: string) => void
  onCloseTab: (index: number) => void
  onArchiveTab: (index: number) => void
  onResumeArchivedSession: (id: string) => void
}) {
  return (
    <div
      className="shrink-0 flex flex-col"
      style={{ width: 'var(--sidebar-width)', background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
    >
      <div className="flex-1 overflow-y-auto sidebar-scroll py-1">
        <ActiveTabs
          tabs={tabs}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          onSelectTab={onSelectTab}
          onNewTab={onNewTab}
          onCloseTab={onCloseTab}
          onArchiveTab={onArchiveTab}
        />

        {sessions.length > 0 && (
          <>
            <SectionHeader label="Recent Sessions" />
            {sessions.map((s) => (
              <SessionRow
                key={s.id}
                session={s}
                selected={selectedId === `session:${s.id}`}
                onSelect={() => onSelectSession(s.id)}
                onArchive={onArchiveSession}
                activity={sessionActivity?.[s.id]}
              />
            ))}
          </>
        )}

        <ArchivedSessions
          sessions={archivedSessions}
          selectedId={selectedId}
          onSelectSession={onResumeArchivedSession}
          onUnarchive={onUnarchiveSession}
        />

        {tabs.length === 0 && sessions.length === 0 && archivedSessions.length === 0 && (
          <div className="px-3 py-4 text-xs" style={{ color: 'var(--text-muted)' }}>
            No tabs or sessions yet.
          </div>
        )}
      </div>
    </div>
  )
}
