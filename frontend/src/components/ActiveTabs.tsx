import type { TabInfo, TabStatus } from '../types'
import type { SessionActivityState } from '../types/stream'
import { ActivityDot } from './StatusDot'

const statusIcon: Record<TabStatus, { char: string; color: string }> = {
  running: { char: '●', color: 'var(--success)' },       // ●
  idle:    { char: '○', color: 'var(--text-muted)' },     // ○
  crashed: { char: '✕', color: 'var(--needs-input)' },    // ✕
}

const statusLabel: Record<TabStatus, string> = {
  running: 'Running',
  idle: 'Idle',
  crashed: 'Crashed',
}

function TabRow({
  tab,
  selected,
  onSelect,
  onClose,
  onArchive,
  activity,
}: {
  tab: TabInfo
  selected: boolean
  onSelect: () => void
  onClose: () => void
  onArchive: () => void
  activity?: SessionActivityState
}) {
  const icon = statusIcon[tab.status]
  const isRawShell = tab.kind.startsWith('shell:')
  const isSessionBacked = tab.session_id !== null
  const isThinking = activity?.harness === 'thinking'

  const rowClasses = [
    'agent-row px-3 py-2',
    selected ? 'selected' : '',
    isThinking ? 'shimmer' : '',
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
        {isRawShell && (
          <span
            className="pill"
            style={{
              background: 'var(--bg-elevated)',
              color: 'var(--text-faint)',
              fontSize: 10,
              padding: '0 4px',
              borderRadius: 'var(--radius-sm)',
            }}
          >
            raw
          </span>
        )}
        <span className="ml-auto flex items-center gap-1">
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
        {statusLabel[tab.status]}
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
}: {
  tabs: TabInfo[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  onSelectTab: (index: number) => void
  onNewTab: () => void
  onCloseTab: (index: number) => void
  onArchiveTab: (index: number) => void
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
          activity={tab.session_id ? sessionActivity?.[tab.session_id] : undefined}
        />
      ))}
    </>
  )
}
