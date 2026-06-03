import { useState } from 'react'
import type { DiscoverableWindow, SessionInfo, TabInfo } from '../types'
import { sessionDisplayTitle, sessionSubtitle } from '../types'
import type { SessionActivityState } from '../types/stream'
import { ActiveTabs } from './ActiveTabs'
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

function UnarchiveButton({ onUnarchive }: { onUnarchive: () => void }) {
  return (
    <button
      className="btn btn-ghost"
      style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
      aria-label="Unarchive"
      onClick={(e) => { e.stopPropagation(); onUnarchive() }}
    >
      Unarchive
    </button>
  )
}

function SessionRow({
  session,
  selected,
  onSelect,
  onArchive,
  onUnarchive,
  activity,
}: {
  session: SessionInfo
  selected: boolean
  onSelect: () => void
  onArchive?: (id: string) => void
  onUnarchive?: (id: string) => void
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
        {onArchive && <ArchiveButton onArchive={() => onArchive(session.id)} />}
        {onUnarchive && <UnarchiveButton onUnarchive={() => onUnarchive(session.id)} />}
        <span className="pill token-count">{age}</span>
      </div>
      {(() => {
        const subtitle = sessionSubtitle(session)
        if (!subtitle) return null
        return (
          <div
            className="text-xs ml-0 mt-0.5 truncate"
            style={{ color: 'var(--text-faint)', lineHeight: 'var(--leading-tight)' }}
            title={subtitle}
          >
            {subtitle}
          </div>
        )
      })()}
    </div>
  )
}

function ArchivedSection({
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
    <div
      data-testid="archived-section"
      className="shrink-0 flex flex-col"
      style={{
        borderTop: '1px solid var(--border)',
        maxHeight: '50%',
        // When collapsed, pin the section to the status-line height so its
        // 1px top border lines up exactly with the status line's top border
        // (border-box includes the border). Released when expanded so the
        // session list can grow.
        ...(expanded ? {} : { height: 'var(--bottombar-height)', justifyContent: 'center' }),
      }}
    >
      <div
        className="px-3 py-1.5 flex items-center justify-between cursor-pointer shrink-0"
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
      {expanded && (
        <div className="overflow-y-auto sidebar-scroll">
          {sessions.map((s) => (
            <SessionRow
              key={s.id}
              session={s}
              selected={selectedId === `session:${s.id}`}
              onSelect={() => onSelectSession(s.id)}
              onUnarchive={onUnarchive}
            />
          ))}
        </div>
      )}
    </div>
  )
}

/** The collapsed-by-default "Discoverable" section: lists external (unmanaged)
 *  tmux windows surfaced by an on-demand discovery scan, each with an Adopt
 *  action gated behind a consent confirmation naming the trust consequence.
 *  Modeled on `ArchivedSection` (collapsed/counted/hidden-when-empty) but the
 *  Scan button lives in the standalone header so the user can scan even when
 *  the list is currently empty. */
function DiscoverableSection({
  windows,
  onScan,
  onAdopt,
}: {
  windows: DiscoverableWindow[]
  onScan: () => void
  onAdopt: (session: string, window: string) => void
}) {
  const [expanded, setExpanded] = useState(false)
  // The candidate awaiting consent confirmation (null = no dialog shown).
  const [pendingAdopt, setPendingAdopt] = useState<DiscoverableWindow | null>(null)

  return (
    <>
      {/* Standalone Scan control — always available, even with no results. */}
      <div
        className="px-3 py-1.5 flex items-center justify-between"
        style={{ color: 'var(--text-muted)' }}
      >
        <span className="text-xs font-semibold uppercase" style={{ letterSpacing: '0.08em' }}>
          Discover
        </span>
        <button
          className="btn btn-ghost"
          style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
          onClick={onScan}
          aria-label="Scan for adoptable tmux windows"
          title="Scan tmux for adoptable external windows"
        >
          Scan
        </button>
      </div>

      {windows.length > 0 && (
        <div data-testid="discoverable-section" className="flex flex-col">
          <div
            className="px-3 py-1.5 flex items-center justify-between cursor-pointer"
            style={{ color: 'var(--text-muted)' }}
            onClick={() => setExpanded(!expanded)}
          >
            <span className="text-xs font-semibold uppercase" style={{ letterSpacing: '0.08em' }}>
              Discoverable ({windows.length})
            </span>
            <span style={{ fontSize: 12 }}>{expanded ? '▾' : '▸'}</span>
          </div>
          {expanded && (
            <div>
              {windows.map((w) => (
                <div
                  key={`${w.session}:${w.windowIndex}:${w.windowName}`}
                  className="agent-row px-3 py-2 flex items-center gap-2"
                >
                  <span
                    className="text-sm truncate mr-auto"
                    style={{ color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }}
                    title={`${w.session}:${w.windowName}`}
                  >
                    {w.session}:{w.windowName}
                  </span>
                  <button
                    className="btn btn-ghost"
                    style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
                    aria-label="Adopt"
                    title={`Adopt ${w.session}:${w.windowName}`}
                    onClick={() => setPendingAdopt(w)}
                  >
                    Adopt
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {pendingAdopt && (
        <div
          className="px-3 py-2"
          role="dialog"
          aria-label="Confirm adopt external tmux window"
          style={{ borderTop: '1px solid var(--border)', background: 'var(--bg-elevated)' }}
        >
          <div className="text-xs" style={{ color: 'var(--text-primary)', lineHeight: 'var(--leading-tight)' }}>
            Adopt <strong>{pendingAdopt.session}:{pendingAdopt.windowName}</strong>? PureClaw will
            manage it and capture its output from now on.
          </div>
          <div className="flex items-center gap-2 mt-2">
            <button
              className="btn btn-ghost"
              style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
              onClick={() => {
                onAdopt(pendingAdopt.session, pendingAdopt.windowName)
                setPendingAdopt(null)
              }}
            >
              Confirm Adopt
            </button>
            <button
              className="btn btn-ghost"
              style={{ fontSize: 10, padding: '1px 6px', lineHeight: 1.4 }}
              onClick={() => setPendingAdopt(null)}
            >
              Cancel
            </button>
          </div>
        </div>
      )}
    </>
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
  discoverableWindows,
  selectedId,
  sessionActivity,
  onSelectTab,
  onSelectSession,
  onNewTab,
  onArchiveSession,
  onUnarchiveSession,
  onCloseTab,
  onArchiveTab,
  onDismissTab,
  onAcknowledgeTab,
  onReleaseTab,
  onScanDiscoverable,
  onAdoptWindow,
}: {
  tabs: TabInfo[]
  sessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  discoverableWindows: DiscoverableWindow[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  onSelectTab: (index: number) => void
  onSelectSession: (id: string) => void
  onNewTab: () => void
  onArchiveSession: (id: string) => void
  onUnarchiveSession: (id: string) => void
  onCloseTab: (index: number) => void
  onArchiveTab: (index: number) => void
  onDismissTab: (index: number) => void
  onAcknowledgeTab: (index: number) => void
  onReleaseTab: (index: number) => void
  onScanDiscoverable: () => void
  onAdoptWindow: (session: string, window: string) => void
}) {
  return (
    <div
      className="shrink-0 flex flex-col"
      style={{ width: 'var(--sidebar-width)', background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
    >
      <div className="flex-1 overflow-y-auto sidebar-scroll py-1 min-h-0">
        <ActiveTabs
          tabs={tabs}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          onSelectTab={onSelectTab}
          onNewTab={onNewTab}
          onCloseTab={onCloseTab}
          onArchiveTab={onArchiveTab}
          onDismiss={onDismissTab}
          onAcknowledge={onAcknowledgeTab}
          onRelease={onReleaseTab}
        />

        <DiscoverableSection
          windows={discoverableWindows}
          onScan={onScanDiscoverable}
          onAdopt={onAdoptWindow}
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

        {tabs.length === 0 && sessions.length === 0 && archivedSessions.length === 0 && (
          <div className="px-3 py-4 text-xs" style={{ color: 'var(--text-muted)' }}>
            No tabs or sessions yet.
          </div>
        )}
      </div>
      <ArchivedSection
        sessions={archivedSessions}
        selectedId={selectedId}
        onSelectSession={onSelectSession}
        onUnarchive={onUnarchiveSession}
      />
    </div>
  )
}
