import { useEffect, useRef, useState } from 'react'
import type { TabInfo } from '../types'
import type { SessionActivityState } from '../types/stream'
import { TabRow } from './ActiveTabs'

/** Collapsible "Running Harnesses" section. Renders the harness-kind tabs
 *  (the harness registry rows) as their own list, separate from "Active Tabs".
 *
 *  Accordion behaviour: starts expanded, can be collapsed by clicking the
 *  header, and AUTO-EXPANDS whenever a new harness appears (the count grows) so
 *  a freshly-spawned harness is never hidden behind a collapsed section. */
export function RunningHarnesses({
  tabs,
  selectedId,
  sessionActivity,
  tabLabel,
  onSelectTab,
  onCloseTab,
  onArchiveTab,
  onDismiss,
  onAcknowledge,
  onRelease,
}: {
  tabs: TabInfo[]
  selectedId: string | null
  sessionActivity?: Record<string, SessionActivityState>
  /** Resolve a tab to its display label (session title, harness fallback,
   *  else ellipsis). Centralized by the parent so all tab-label consumers
   *  agree. */
  tabLabel: (tab: TabInfo) => string
  onSelectTab: (index: number) => void
  onCloseTab: (index: number) => void
  onArchiveTab: (index: number) => void
  onDismiss: (index: number) => void
  onAcknowledge: (index: number) => void
  onRelease: (index: number) => void
}) {
  const [expanded, setExpanded] = useState(true)
  const prevCount = useRef(tabs.length)

  // Auto-expand when a new harness is added (count increases). We compare
  // against the previous render's count so a user-initiated collapse sticks
  // until the next harness actually appears.
  useEffect(() => {
    if (tabs.length > prevCount.current) setExpanded(true)
    prevCount.current = tabs.length
  }, [tabs.length])

  if (tabs.length === 0) return null

  return (
    <div data-testid="running-harnesses-section">
      <div
        className="px-3 py-1.5 flex items-center justify-between cursor-pointer"
        style={{ color: 'var(--text-muted)' }}
        onClick={() => setExpanded((e) => !e)}
      >
        <span className="text-xs font-semibold uppercase" style={{ letterSpacing: '0.08em' }}>
          Running Harnesses
        </span>
        <span data-testid="running-harnesses-collapse-icon" style={{ fontSize: 12 }}>
          {expanded ? '▾' : '▸'}
        </span>
      </div>
      {expanded &&
        tabs.map((tab) => (
          <TabRow
            key={tab.index}
            tab={tab}
            label={tabLabel(tab)}
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
    </div>
  )
}
