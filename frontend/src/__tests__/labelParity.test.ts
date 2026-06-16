import { describe, it, expect } from 'vitest'
import type { SessionInfo, TabInfo } from '../types'
import { sessionDisplayTitle, tabDisplayLabel } from '../types'

/** Task 7 — the cross-surface PARITY guarantee.
 *
 *  After the unify-name refactor a tab carries NO label of its own: every
 *  surface derives the label from the backing SESSION's title. These tests pin
 *  the headline invariant — the SAME session yields the SAME label string
 *  whether it is rendered in the Active Tabs path (via `tabDisplayLabel`) or
 *  the Recent Sessions path (via `sessionDisplayTitle`). If the two cascades
 *  ever drift, a tab would read differently from its Recent Sessions row, which
 *  is exactly the bug this refactor eliminated. */

/** Build a fully-populated SessionInfo with sensible nulls, overridable. */
function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's-parity',
    agent: null,
    runtime: 'session:provider',
    model: '',
    lastActive: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    ...overrides,
  }
}

/** A session-backed tab whose `session_id` matches the given session. The tab's
 *  own `label` is deliberately set to a DIFFERENT string so the test proves the
 *  rendered label comes from the session (via the join), not the tab field. */
function tabFor(session: SessionInfo): TabInfo {
  return {
    index: 0,
    kind: 'session:provider',
    label: 'STALE-TAB-LABEL-SHOULD-NEVER-WIN',
    status: 'idle',
    session_id: session.id,
  }
}

describe('cross-surface label parity (Active Tab === Recent Session)', () => {
  it('a session WITH a description yields the SAME label on both surfaces', () => {
    const s = makeSession({ description: 'Custom' })
    const activeTabLabel = tabDisplayLabel(tabFor(s), s)
    const recentSessionLabel = sessionDisplayTitle(s)

    // Both must be the user-set description...
    expect(activeTabLabel).toBe('Custom')
    expect(recentSessionLabel).toBe('Custom')
    // ...and, the headline guarantee, they must be the SAME string.
    expect(activeTabLabel).toBe(recentSessionLabel)
  })

  it('a session with NO description but a first-message snippet falls back identically on both surfaces', () => {
    const s = makeSession({ description: null, firstMessageSnippet: 'do the thing' })
    const activeTabLabel = tabDisplayLabel(tabFor(s), s)
    const recentSessionLabel = sessionDisplayTitle(s)

    expect(activeTabLabel).toBe('do the thing')
    expect(recentSessionLabel).toBe('do the thing')
    expect(activeTabLabel).toBe(recentSessionLabel)
  })

  it('the parity holds across the WHOLE cascade arm-by-arm (description → autoSummary → snippet → agent → id)', () => {
    const cases: SessionInfo[] = [
      makeSession({ description: 'desc-arm' }),
      makeSession({ autoSummary: 'summary-arm' }),
      makeSession({ firstMessageSnippet: 'snippet-arm' }),
      makeSession({ agent: 'agent-arm' }),
      makeSession({ id: 'id-cascade-arm' }), // all-null → id prefix
    ]
    for (const s of cases) {
      expect(tabDisplayLabel(tabFor(s), s)).toBe(sessionDisplayTitle(s))
    }
  })
})

describe('label stability across the Active-Tab <-> Recent-Session transition', () => {
  // Persistence transition: a session's label must be invariant under
  // "open it as a tab" / "close it back to a Recent Session". Since both
  // surfaces compute from the SAME SessionInfo via the SAME cascade, opening or
  // closing a session cannot change the string. One representative session
  // documents the invariant; the tab's own (different) `label` must never leak.
  it('a representative session reads identically whether rendered as an Active Tab or a Recent Session', () => {
    const s = makeSession({ description: 'Stable Across Open/Close' })
    const tab = tabFor(s)

    const asActiveTab = tabDisplayLabel(tab, s) // opened as a tab
    const asRecentSession = sessionDisplayTitle(s) // closed back to a recent row

    expect(asActiveTab).toBe(asRecentSession)
    // The tab's own fallback label (set to a sentinel above) must NOT win while
    // the session resolves — proving the label survives the transition unchanged.
    expect(asActiveTab).not.toBe(tab.label)
  })
})
