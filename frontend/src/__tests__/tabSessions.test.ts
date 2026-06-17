import { describe, it, expect } from 'vitest'
import type { SessionInfo } from '../types'
import { findSession, sessionDisplayTitle, tabDisplayLabel } from '../types'

/** Active-tab sessions are deduped OUT of the `recentSessions`/`archivedSessions`
 *  lists by the backend (a tab's session is not also a Recent Sessions row), and
 *  the tab snapshot itself is meta-free. The backend therefore carries those
 *  sessions' full SessionInfo in a dedicated `tabSessions` array so the frontend
 *  can still resolve a tab's backing session — to render the chat-header edit
 *  pencil and the rename-derived title for OPEN tabs. These tests pin that
 *  `findSession` consults `tabSessions`, and that a session found only there
 *  yields the same label it would as a Recent Sessions row. */

function makeSession(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 's-tab',
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

describe('findSession consults tabSessions for active-tab-backed sessions', () => {
  it('resolves a session present ONLY in tabSessions (not in recents/archived)', () => {
    const s = makeSession({ id: 'open-tab-sid', description: 'Renamed In Tab' })
    const found = findSession('open-tab-sid', [], [], [s])
    expect(found).toBe(s)
  })

  it('still resolves recents and archived (tabSessions is additive, not a replacement)', () => {
    const recent = makeSession({ id: 'recent-sid' })
    const archived = makeSession({ id: 'archived-sid' })
    const tab = makeSession({ id: 'tab-sid' })
    expect(findSession('recent-sid', [recent], [archived], [tab])).toBe(recent)
    expect(findSession('archived-sid', [recent], [archived], [tab])).toBe(archived)
    expect(findSession('tab-sid', [recent], [archived], [tab])).toBe(tab)
  })

  it('a tab-only session yields the SAME label as it would as a Recent Session', () => {
    const s = makeSession({ id: 'open-tab-sid', description: 'Renamed In Tab' })
    const tab = {
      index: 0,
      kind: 'session:provider',
      label: 'STALE-TAB-LABEL-SHOULD-NEVER-WIN',
      status: 'idle' as const,
      session_id: 'open-tab-sid',
    }
    const viaTabJoin = tabDisplayLabel(tab, findSession('open-tab-sid', [], [], [s]))
    expect(viaTabJoin).toBe('Renamed In Tab')
    expect(viaTabJoin).toBe(sessionDisplayTitle(s))
  })
})
