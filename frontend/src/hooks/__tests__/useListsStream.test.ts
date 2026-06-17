import { describe, it, expect, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'

// Mock the shared streamClient singleton so the default-client branch
// (`client ?? streamClient()`) can be exercised without opening a real
// WebSocket. Explicit-client tests pass their own fake and never hit this.
const mocks = vi.hoisted(() => {
  const unsub = vi.fn()
  const fake = { onLists: vi.fn(() => unsub) }
  return { streamClient: vi.fn(() => fake), fake, unsub }
})
vi.mock('../../lib/streamClient', () => ({ streamClient: mocks.streamClient }))

import { useListsStream } from '../useListsStream'
import type { SessionInfo } from '../../types'
import type { ListsSnapshot, StreamClient } from '../../types/stream'

function mkSession(id: string): SessionInfo {
  return {
    id,
    agent: null,
    runtime: 'provider',
    model: 'opus',
    lastActive: '2026-06-01T00:00:00Z',
    createdAt: '2026-06-01T00:00:00Z',
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
  }
}

/** A fake StreamClient that captures the `onLists` callback so a test can
 *  drive a snapshot through it, and records its unsubscribe call. */
function makeFakeClient() {
  let cb: ((s: ListsSnapshot) => void) | null = null
  const unsub = vi.fn()
  const onLists = vi.fn((c: (s: ListsSnapshot) => void) => {
    cb = c
    return unsub
  })
  const client = {
    status: 'open',
    focus: vi.fn(),
    onEntry: vi.fn(() => () => {}),
    onActivity: vi.fn(() => () => {}),
    onLists,
    onStatusChange: vi.fn(() => () => {}),
    lastError: () => null,
  } as unknown as StreamClient
  return {
    client,
    unsub,
    emit: (s: ListsSnapshot) => {
      if (cb) cb(s)
    },
  }
}

describe('useListsStream', () => {
  it('starts with empty tabs and session lists', () => {
    const { client } = makeFakeClient()
    const { result } = renderHook(() => useListsStream(client))
    expect(result.current.tabs).toEqual([])
    expect(result.current.recentSessions).toEqual([])
    expect(result.current.archivedSessions).toEqual([])
  })

  it('maps snake_case wire tabs to camelCase and stores the session lists on a snapshot', () => {
    const { client, emit } = makeFakeClient()
    const { result } = renderHook(() => useListsStream(client))
    const recent = [mkSession('r1')]
    const archived = [mkSession('a1')]
    act(() => {
      emit({
        tabs: [
          { index: 0, kind: 'shell:bash', name: 'bash', status: 'idle', session_id: null },
        ],
        recentSessions: recent,
        archivedSessions: archived,
      })
    })
    expect(result.current.tabs).toEqual([
      {
        index: 0,
        kind: 'shell:bash',
        name: 'bash',
        status: 'idle',
        session_id: null,
        extModified: false,
        stale: false,
        origin: undefined,
        attachCommand: null,
      },
    ])
    expect(result.current.recentSessions).toEqual(recent)
    expect(result.current.archivedSessions).toEqual(archived)
  })

  it('unsubscribes from the client on unmount', () => {
    const { client, unsub } = makeFakeClient()
    const { unmount } = renderHook(() => useListsStream(client))
    unmount()
    expect(unsub).toHaveBeenCalledTimes(1)
  })

  it('falls back to the shared streamClient when no client is passed', () => {
    renderHook(() => useListsStream())
    expect(mocks.streamClient).toHaveBeenCalled()
    expect(mocks.fake.onLists).toHaveBeenCalled()
  })
})
