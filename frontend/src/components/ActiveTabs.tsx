import type { ReactNode } from 'react'
import type { TabInfo, TabStatus } from '../types'
import type { SessionActivityState } from '../types/stream'
import { ActivityDot } from './StatusDot'

const statusIcon: Record<TabStatus, { char: string; color: string }> = {
  running:  { char: '●', color: 'var(--success)' },       // ●
  idle:     { char: '○', color: 'var(--text-muted)' },     // ○
  exited:   { char: '✕', color: 'var(--needs-input)' },    // ✕ harness died, window present
  orphaned: { char: '✕', color: 'var(--needs-input)' },    // ✕ no live window
}

const statusLabel: Record<TabStatus, string> = {
  running: 'Running',
  idle: 'Idle',
  exited: 'Exited',
  orphaned: 'Orphaned',
}

/** Fallback glyph for a status string the frontend does not recognize (a
 *  malformed or forward-incompatible backend status). Defensive against an
 *  out-of-union value: a lookup miss must render this neutral cue rather than
 *  crash the row (`statusIcon[unknown].char` would throw on undefined). */
const FALLBACK_ICON = { char: '?', color: 'var(--text-muted)' }

/** A small inline pill used for the [raw], origin, and "edited" markers. */
function Pill({
  children,
  background = 'var(--bg-elevated)',
  color = 'var(--text-faint)',
}: {
  children: ReactNode
  background?: string
  color?: string
}) {
  return (
    <span
      className="pill"
      style={{
        background,
        color,
        fontSize: 10,
        padding: '0 4px',
        borderRadius: 'var(--radius-sm)',
      }}
    >
      {children}
    </span>
  )
}

function TabRow({
  tab,
  selected,
  onSelect,
  onClose,
  onArchive,
  onDismiss,
  onAcknowledge,
  onRelease,
  activity,
}: {
  tab: TabInfo
  selected: boolean
  onSelect: () => void
  onClose: () => void
  onArchive: () => void
  onDismiss: () => void
  onAcknowledge: () => void
  onRelease: () => void
  activity?: SessionActivityState
}) {
  // Defensive lookup: an unknown status string (malformed backend payload)
  // must not crash the render — fall back to a neutral glyph/label.
  const icon = statusIcon[tab.status] ?? FALLBACK_ICON
  const isRawShell = tab.kind.startsWith('shell:')
  const isSessionBacked = tab.session_id !== null
  const isThinking = activity?.harness === 'thinking'
  // Exited = harness process died (window still present) → offer a reserved
  // Restart + Dismiss. Orphaned = no live window → greyed row + Dismiss.
  const isExited = tab.status === 'exited'
  const isOrphaned = tab.status === 'orphaned'
  const isDead = isExited || isOrphaned
  // Adopted harnesses can be Released — PureClaw stops managing them without
  // killing the underlying tmux window. Distinct from Close/Dismiss, and only
  // offered on adopted rows.
  const isAdopted = tab.origin === 'adopted'

  const rowClasses = [
    'agent-row px-3 py-2',
    selected ? 'selected' : '',
    // Thinking shimmer is suppressed while stale — we hold the last icon and
    // dim instead of animating a possibly-stale liveness.
    isThinking && !tab.stale ? 'shimmer' : '',
    isOrphaned ? 'tab-orphaned' : '',
    tab.stale ? 'tab-stale' : '',
  ].filter(Boolean).join(' ')

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        <span
          className="text-xs"
          style={{ color: 'var(--text-faint)', minWidth: 12, textAlign: 'right' }}
        >
          {tab.index}
        </span>
        {isThinking ? (
          <ActivityDot activity="thinking" />
        ) : (
          <span
            data-testid={`status-${tab.status}`}
            style={{ color: icon.color, fontSize: 10, lineHeight: 1 }}
          >
            {icon.char}
          </span>
        )}
        <span
          className="text-sm font-medium"
          style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}
        >
          {tab.name}
        </span>
        {isRawShell && <Pill>raw</Pill>}
        {tab.origin && <Pill>{tab.origin}</Pill>}
        {tab.extModified && (
          <Pill background="var(--needs-input-bg, var(--bg-elevated))" color="var(--needs-input)">
            <span aria-hidden="true">⚠ </span>edited
          </Pill>
        )}
        <span className="ml-auto flex items-center gap-1">
          {tab.attachCommand && (
            <button
              className="session-archive"
              title={`Copy attach command: ${tab.attachCommand}`}
              aria-label="Copy attach command"
              data-attach-command={tab.attachCommand}
              onClick={(e) => {
                e.stopPropagation()
                void navigator.clipboard?.writeText(tab.attachCommand!)
              }}
            >
              <svg
                width="11" height="11" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true"
              >
                <rect x="5" y="5" width="8" height="8" rx="1" />
                <path d="M3 11 V3 a1 1 0 0 1 1 -1 h7" />
              </svg>
            </button>
          )}
          {tab.extModified && (
            <button
              className="session-archive"
              title="Acknowledge the out-of-band change (clears the edited flag)"
              aria-label="Acknowledge tab"
              onClick={(e) => { e.stopPropagation(); onAcknowledge() }}
            >
              <svg
                width="11" height="11" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true"
              >
                <path d="M3 8 L7 12 L13 4" />
              </svg>
            </button>
          )}
          {isExited && (
            <button
              className="session-archive"
              title="Restart this harness (coming soon)"
              aria-label="Restart tab"
              disabled
              onClick={(e) => { e.stopPropagation() }}
            >
              <svg
                width="11" height="11" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true"
              >
                <path d="M13 8 a5 5 0 1 1 -1.5 -3.5" />
                <path d="M13 2 v3 h-3" />
              </svg>
            </button>
          )}
          {isDead && (
            <button
              className="session-archive"
              title="Dismiss this row (the session stays in Recent Sessions)"
              aria-label="Dismiss tab"
              onClick={(e) => { e.stopPropagation(); onDismiss() }}
            >
              <svg
                width="11" height="11" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true"
              >
                <path d="M3 8 h10" />
              </svg>
            </button>
          )}
          {isSessionBacked && (
            <button
              className="session-archive"
              title="Archive this session (close tab and archive)"
              aria-label="Archive tab"
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
          )}
          {isAdopted && (
            <button
              className="session-archive"
              title="Release this adopted harness (stops managing it; does NOT kill the tmux window)"
              aria-label="Release tab"
              onClick={(e) => { e.stopPropagation(); onRelease() }}
            >
              <svg
                width="11" height="11" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true"
              >
                <path d="M6 3 H4 a1 1 0 0 0 -1 1 v8 a1 1 0 0 0 1 1 h8 a1 1 0 0 0 1 -1 v-2" />
                <path d="M9 7 L14 2" />
                <path d="M10 2 h4 v4" />
              </svg>
            </button>
          )}
          <button
            className="session-archive"
            title="Close tab"
            aria-label="Close tab"
            onClick={(e) => { e.stopPropagation(); onClose() }}
          >
            <svg
              width="11" height="11" viewBox="0 0 16 16" fill="none"
              stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
              aria-hidden="true"
            >
              <path d="M4 4 L12 12" />
              <path d="M12 4 L4 12" />
            </svg>
          </button>
        </span>
      </div>
      <div
        className="text-xs ml-6 mt-0.5"
        style={{ color: 'var(--text-muted)', lineHeight: 'var(--leading-tight)' }}
      >
        {statusLabel[tab.status] ?? tab.status}
      </div>
    </div>
  )
}

export function ActiveTabs({
  tabs,
  selectedId,
  sessionActivity,
  onSelectTab,
  onNewTab,
  onCloseTab,
  onArchiveTab,
  onDismiss,
  onAcknowledge,
  onRelease,
}: {
  tabs: TabInfo[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  onSelectTab: (index: number) => void
  onNewTab: () => void
  onCloseTab: (index: number) => void
  onArchiveTab: (index: number) => void
  onDismiss: (index: number) => void
  onAcknowledge: (index: number) => void
  onRelease: (index: number) => void
}) {
  return (
    <>
      <div
        className="px-3 py-1.5 flex items-center justify-between"
        style={{ color: 'var(--text-muted)' }}
      >
        <span
          className="text-xs font-semibold uppercase"
          style={{ letterSpacing: '0.08em' }}
        >
          Active Tabs
        </span>
        <button
          className="btn btn-ghost flex items-center justify-center"
          style={{ width: 22, height: 22, padding: 0, fontSize: 14, lineHeight: 1 }}
          onClick={onNewTab}
          aria-label="New tab"
          title="New tab"
        >
          +
        </button>
      </div>
      {tabs.map((tab) => (
        <TabRow
          key={tab.index}
          tab={tab}
          selected={selectedId === `tab:${tab.index}`}
          onSelect={() => onSelectTab(tab.index)}
          onClose={() => onCloseTab(tab.index)}
          onArchive={() => onArchiveTab(tab.index)}
          onDismiss={() => onDismiss(tab.index)}
          onAcknowledge={() => onAcknowledge(tab.index)}
          onRelease={() => onRelease(tab.index)}
          activity={tab.session_id ? sessionActivity?.[tab.session_id] : undefined}
        />
      ))}
    </>
  )
}
