import { useState } from 'react'
import type { SessionInfo } from '../types'
import { sessionDisplayTitle } from '../types'

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

function ArchivedRow({
  session,
  selected,
  onSelect,
  onUnarchive,
}: {
  session: SessionInfo
  selected: boolean
  onSelect: () => void
  onUnarchive: () => void
}) {
  const rowClasses = [
    'agent-row session-row px-3 py-2',
    selected ? 'selected' : '',
  ].filter(Boolean).join(' ')

  const displayName = sessionDisplayTitle(session)
  const age = formatAge(session.lastActive)

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        <span
          className="text-sm truncate mr-auto"
          style={{ color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {displayName}
        </span>
        <button
          className="btn btn-ghost"
          style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
          aria-label="Unarchive"
          onClick={(e) => { e.stopPropagation(); onUnarchive() }}
        >
          Unarchive
        </button>
        <span className="pill token-count">{age}</span>
      </div>
    </div>
  )
}

export function ArchivedSessions({
  sessions,
  selectedId,
  onSelectSession,
  onUnarchive,
}: {
  sessions: SessionInfo[]
  selectedId: string | null
  onSelectSession: (id: string) => void
  onUnarchive: (id: string) => void
}) {
  const [expanded, setExpanded] = useState(false)

  if (sessions.length === 0) return null

  return (
    <>
      <div
        className="px-3 py-1.5 flex items-center justify-between cursor-pointer"
        style={{ color: 'var(--text-muted)' }}
        onClick={() => setExpanded(!expanded)}
      >
        <span
          className="text-xs font-semibold uppercase"
          style={{ letterSpacing: '0.08em' }}
        >
          Archived ({sessions.length})
        </span>
        <span data-testid="collapse-icon" style={{ fontSize: 12 }}>
          {expanded ? '▾' : '▸'}
        </span>
      </div>
      {expanded && sessions.map((s) => (
        <ArchivedRow
          key={s.id}
          session={s}
          selected={selectedId === `session:${s.id}`}
          onSelect={() => onSelectSession(s.id)}
          onUnarchive={() => onUnarchive(s.id)}
        />
      ))}
    </>
  )
}
