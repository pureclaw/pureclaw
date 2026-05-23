import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { useSessionActivityStream } from '../useSessionActivityStream'
import type { ActivityEvent, StreamClient, StreamStatus } from '../../types/stream'

function makeFakeClient(): {
  client: StreamClient
  emitActivity: (sid: string, a: ActivityEvent) => void
  setStatus: (s: StreamStatus) => void
} {
  let status: StreamStatus = 'connecting'
  const activityListeners = new Set<(sid: string, a: ActivityEvent) => void>()
  const statusListeners = new Set<(s: StreamStatus) => void>()
  const entryListeners = new Set<() => void>()
  void entryListeners
  const client: StreamClient = {
    get status() {
      return status
    },
    focus() {},
    onEntry() {
      return () => {}
    },
    onActivity(cb) {
      activityListeners.add(cb)
      return () => {
        activityListeners.delete(cb)
      }
    },
    onStatusChange(cb) {
      statusListeners.add(cb)
      return () => {
        statusListeners.delete(cb)
      }
    },
    lastError() {
      return null
    },
  }
  return {
    client,
    emitActivity(sid, a) {
      for (const cb of activityListeners) cb(sid, a)
    },
    setStatus(s) {
      status = s
      for (const cb of statusListeners) cb(s)
    },
  }
}

describe('useSessionActivityStream', () => {
  beforeEach(() => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts with an empty sessions map', () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    expect(result.current.sessions).toEqual({})
  })

  it('entry-at increments unread count and updates lastEntryAt', () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    act(() => {
      fake.emitActivity('session-abc', {
        kind: 'entry-at',
        timestamp: '2026-05-23T18:00:00Z',
      })
    })
    expect(result.current.sessions['session-abc']).toBeDefined()
    expect(result.current.sessions['session-abc']!.unread).toBe(1)
    expect(result.current.sessions['session-abc']!.lastEntryAt).toBe('2026-05-23T18:00:00Z')
    act(() => {
      fake.emitActivity('session-abc', {
        kind: 'entry-at',
        timestamp: '2026-05-23T18:00:01Z',
      })
    })
    expect(result.current.sessions['session-abc']!.unread).toBe(2)
    expect(result.current.sessions['session-abc']!.lastEntryAt).toBe('2026-05-23T18:00:01Z')
  })

  it('harness-status updates the harness state', () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    act(() => {
      fake.emitActivity('session-abc', { kind: 'harness-status', status: 'thinking' })
    })
    expect(result.current.sessions['session-abc']!.harness).toBe('thinking')
    act(() => {
      fake.emitActivity('session-abc', { kind: 'harness-status', status: 'idle' })
    })
    expect(result.current.sessions['session-abc']!.harness).toBe('idle')
    act(() => {
      fake.emitActivity('session-abc', { kind: 'harness-status', status: 'stopped' })
    })
    expect(result.current.sessions['session-abc']!.harness).toBe('stopped')
  })

  it('session-created adds an entry with default values', () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    act(() => {
      fake.emitActivity('session-new', {
        kind: 'session-created',
        session: {
          id: 'session-new',
          runtime: 'provider',
          model: 'claude-3-7-sonnet',
          channel: 'web',
          created_at: '2026-05-23T18:00:00Z',
          last_active: '2026-05-23T18:00:00Z',
          bootstrap_consumed: true,
        },
      })
    })
    expect(result.current.sessions['session-new']).toBeDefined()
    expect(result.current.sessions['session-new']!.harness).toBeNull()
    expect(result.current.sessions['session-new']!.unread).toBe(0)
  })

  it('keeps separate per-session counters', () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    act(() => {
      fake.emitActivity('s1', { kind: 'entry-at', timestamp: '2026-05-23T18:00:00Z' })
      fake.emitActivity('s2', { kind: 'entry-at', timestamp: '2026-05-23T18:00:01Z' })
      fake.emitActivity('s1', { kind: 'entry-at', timestamp: '2026-05-23T18:00:02Z' })
    })
    expect(result.current.sessions['s1']!.unread).toBe(2)
    expect(result.current.sessions['s2']!.unread).toBe(1)
  })

  it('reflects status changes from the underlying client', async () => {
    const fake = makeFakeClient()
    const { result } = renderHook(() => useSessionActivityStream(fake.client))
    expect(result.current.status).toBe('connecting')
    act(() => fake.setStatus('live'))
    await waitFor(() => expect(result.current.status).toBe('live'))
  })
})
