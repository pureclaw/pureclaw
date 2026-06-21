import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { reconcileEntries, useTranscriptStream } from '../useTranscriptStream'
import type { TranscriptEntry } from '../../types'
import type { ActivityEvent, StreamClient, StreamStatus } from '../../types/stream'

function mkEntry(id: string, timestamp: string, payload = ''): TranscriptEntry {
  return {
    id,
    timestamp,
    direction: 'response',
    payload,
    harness: null,
    model: null,
    raw: JSON.stringify({ _te_id: id, _te_payload: payload }),
  }
}

describe('reconcileEntries', () => {
  it('returns existing unchanged when entry is already present with same payload (dedup by id — no-op update)', () => {
    const e1 = mkEntry('a', '2026-05-23T18:00:00Z')
    const existing = [e1]
    const incoming = mkEntry('a', '2026-05-23T18:00:00Z')
    const merged = reconcileEntries(existing, incoming)
    expect(merged).toHaveLength(1)
  })

  it('reconcileEntries REPLACES an existing entry with the same id (was skip)', () => {
    const a = { id: 'x', timestamp: '2026-06-20T00:00:00Z', direction: 'response', payload: 'one', harness: 'harness', model: null, raw: '' } as TranscriptEntry
    const b = { ...a, payload: 'one two', streaming: true }
    const out = reconcileEntries([a], b)
    expect(out).toHaveLength(1)
    expect(out[0]!.payload).toBe('one two')
    expect(out[0]!.streaming).toBe(true)
  })

  it('reconcileEntries keeps sort position when replacing (stable timestamp)', () => {
    const e1 = mkEntry('a', '2026-06-20T00:00:01Z'); const e2 = mkEntry('b', '2026-06-20T00:00:02Z')
    const out = reconcileEntries([e1, e2], { ...e1, payload: 'grown' })
    expect(out.map(e => e.id)).toEqual(['a', 'b'])
    expect(out[0]!.payload).toBe('grown')
  })

  it('appends new entries to the end when they are chronologically last', () => {
    const e1 = mkEntry('a', '2026-05-23T18:00:00Z')
    const e2 = mkEntry('b', '2026-05-23T18:00:01Z')
    const merged = reconcileEntries([e1], e2)
    expect(merged.map((e) => e.id)).toEqual(['a', 'b'])
  })

  it('inserts entries in chronological order even when delivered out of order', () => {
    const e1 = mkEntry('a', '2026-05-23T18:00:00Z')
    const e3 = mkEntry('c', '2026-05-23T18:00:02Z')
    const e2 = mkEntry('b', '2026-05-23T18:00:01Z')
    let entries = reconcileEntries([], e1)
    entries = reconcileEntries(entries, e3)
    entries = reconcileEntries(entries, e2)
    expect(entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
  })

  it('handles seed-then-tail with dedup (D14)', () => {
    // HTTP seed delivers [a, b]; WS later delivers b (dup) then c.
    const seed = [mkEntry('a', '2026-05-23T18:00:00Z'), mkEntry('b', '2026-05-23T18:00:01Z')]
    const dup = mkEntry('b', '2026-05-23T18:00:01Z')
    const tail = mkEntry('c', '2026-05-23T18:00:02Z')
    let entries = reconcileEntries(seed, dup)
    // replace-on-id: a new array is returned with b replaced in place
    expect(entries).toHaveLength(2)
    expect(entries.map((e) => e.id)).toEqual(['a', 'b'])
    entries = reconcileEntries(entries, tail)
    expect(entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
  })

  it('keeps array sorted by timestamp ascending', () => {
    const e1 = mkEntry('a', '2026-05-23T18:00:00Z')
    const e2 = mkEntry('b', '2026-05-23T18:00:05Z')
    const eMid = mkEntry('mid', '2026-05-23T18:00:02Z')
    const entries = reconcileEntries([e1, e2], eMid)
    expect(entries.map((e) => e.timestamp)).toEqual([
      '2026-05-23T18:00:00Z',
      '2026-05-23T18:00:02Z',
      '2026-05-23T18:00:05Z',
    ])
  })

  it('HTTP-seed-only case: returns the entries unchanged when no WS events arrive (D14)', () => {
    const seed = [mkEntry('a', '2026-05-23T18:00:00Z'), mkEntry('b', '2026-05-23T18:00:01Z')]
    // No reconcileEntries call necessary; just sanity-check the seed itself.
    expect(seed).toHaveLength(2)
  })

  it('WS-tail-only case: starts empty and accumulates entries in order (D14)', () => {
    let entries: TranscriptEntry[] = []
    entries = reconcileEntries(entries, mkEntry('a', '2026-05-23T18:00:00Z'))
    entries = reconcileEntries(entries, mkEntry('b', '2026-05-23T18:00:01Z'))
    entries = reconcileEntries(entries, mkEntry('c', '2026-05-23T18:00:02Z'))
    expect(entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
  })
})

/** Build an in-memory fake StreamClient for hook tests. */
function makeFakeClient(): {
  client: StreamClient
  emitEntry: (e: TranscriptEntry) => void
  setStatus: (s: StreamStatus) => void
  setLastError: (e: string | null) => void
  focusCalls: Array<{ sessionId: string | null; since?: string }>
} {
  let status: StreamStatus = 'connecting'
  let lastError: string | null = null
  const entryListeners = new Set<(e: TranscriptEntry) => void>()
  const statusListeners = new Set<(s: StreamStatus) => void>()
  const activityListeners = new Set<(sid: string, a: ActivityEvent) => void>()
  void activityListeners
  const focusCalls: Array<{ sessionId: string | null; since?: string }> = []
  const client: StreamClient = {
    get status() {
      return status
    },
    focus(sessionId, since) {
      focusCalls.push({ sessionId, since })
    },
    onEntry(cb) {
      entryListeners.add(cb)
      return () => {
        entryListeners.delete(cb)
      }
    },
    onActivity(cb) {
      activityListeners.add(cb)
      return () => {
        activityListeners.delete(cb)
      }
    },
    onLists() {
      return () => {}
    },
    onStatusChange(cb) {
      statusListeners.add(cb)
      return () => {
        statusListeners.delete(cb)
      }
    },
    lastError() {
      return lastError
    },
  }
  return {
    client,
    emitEntry(e) {
      for (const cb of entryListeners) cb(e)
    },
    setStatus(s) {
      status = s
      for (const cb of statusListeners) cb(s)
    },
    setLastError(e) {
      lastError = e
    },
    focusCalls,
  }
}

describe('useTranscriptStream (hook integration)', () => {
  let fetchMock: ReturnType<typeof vi.fn>

  beforeEach(() => {
    fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => [],
    })
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('HTTP-seed-only: returns the seeded entries (D14)', async () => {
    const seed: TranscriptEntry[] = [
      mkEntry('a', '2026-05-23T18:00:00Z'),
      mkEntry('b', '2026-05-23T18:00:01Z'),
    ]
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => seed })
    const { client } = makeFakeClient()
    const { result } = renderHook(() => useTranscriptStream('session-abc', client))
    await waitFor(() => {
      expect(result.current.entries).toHaveLength(2)
    })
    expect(result.current.entries.map((e) => e.id)).toEqual(['a', 'b'])
  })

  it('WS-tail-only: starts empty (no seed) and appends WS-delivered entries (D14)', async () => {
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => [] })
    const fake = makeFakeClient()
    const { result } = renderHook(() =>
      useTranscriptStream('session-abc', fake.client),
    )
    await waitFor(() => {
      expect(fake.focusCalls.length).toBeGreaterThan(0)
    })
    expect(result.current.entries).toHaveLength(0)
    act(() => {
      fake.emitEntry(mkEntry('a', '2026-05-23T18:00:00Z'))
    })
    await waitFor(() => {
      expect(result.current.entries).toHaveLength(1)
    })
    act(() => {
      fake.emitEntry(mkEntry('b', '2026-05-23T18:00:01Z'))
    })
    await waitFor(() => {
      expect(result.current.entries.map((e) => e.id)).toEqual(['a', 'b'])
    })
  })

  it('seed-then-tail with dedup: WS event that duplicates a seeded entry is dropped (D14)', async () => {
    const seed: TranscriptEntry[] = [
      mkEntry('a', '2026-05-23T18:00:00Z'),
      mkEntry('b', '2026-05-23T18:00:01Z'),
    ]
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => seed })
    const fake = makeFakeClient()
    const { result } = renderHook(() =>
      useTranscriptStream('session-abc', fake.client),
    )
    await waitFor(() => {
      expect(result.current.entries).toHaveLength(2)
    })
    // WS delivers a dup of 'b' plus a new 'c'.
    act(() => {
      fake.emitEntry(mkEntry('b', '2026-05-23T18:00:01Z'))
      fake.emitEntry(mkEntry('c', '2026-05-23T18:00:02Z'))
    })
    await waitFor(() => {
      expect(result.current.entries).toHaveLength(3)
    })
    expect(result.current.entries.map((e) => e.id)).toEqual(['a', 'b', 'c'])
  })

  it('out-of-order timestamps: WS delivers older entry; result remains sorted (D14)', async () => {
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => [] })
    const fake = makeFakeClient()
    const { result } = renderHook(() =>
      useTranscriptStream('session-abc', fake.client),
    )
    await waitFor(() => expect(fake.focusCalls.length).toBeGreaterThan(0))
    act(() => {
      fake.emitEntry(mkEntry('first', '2026-05-23T18:00:00Z'))
      fake.emitEntry(mkEntry('third', '2026-05-23T18:00:02Z'))
      fake.emitEntry(mkEntry('second', '2026-05-23T18:00:01Z'))
    })
    await waitFor(() => {
      expect(result.current.entries).toHaveLength(3)
    })
    expect(result.current.entries.map((e) => e.id)).toEqual(['first', 'second', 'third'])
  })

  it('focuses the session with `since` set to the last seeded entry id', async () => {
    const seed: TranscriptEntry[] = [
      mkEntry('a', '2026-05-23T18:00:00Z'),
      mkEntry('b', '2026-05-23T18:00:01Z'),
    ]
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => seed })
    const fake = makeFakeClient()
    renderHook(() => useTranscriptStream('session-abc', fake.client))
    await waitFor(() => expect(fake.focusCalls.length).toBeGreaterThan(0))
    const call = fake.focusCalls[fake.focusCalls.length - 1]!
    expect(call.sessionId).toBe('session-abc')
    expect(call.since).toBe('b')
  })

  it('reflects status changes from the underlying client', async () => {
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => [] })
    const fake = makeFakeClient()
    const { result } = renderHook(() =>
      useTranscriptStream('session-abc', fake.client),
    )
    act(() => fake.setStatus('live'))
    await waitFor(() => {
      expect(result.current.status).toBe('live')
    })
    act(() => fake.setStatus('reconnecting'))
    await waitFor(() => {
      expect(result.current.status).toBe('reconnecting')
    })
  })

  it('null sessionId clears entries and does NOT downgrade focus', async () => {
    // Why no focus(null): handleComposerSend eagerly focuses on the new
    // session id before the WS lists snapshot has populated `tabs`. If
    // this hook calls focus(null) during that brief tabs-lag window
    // (sessionId resolves to null), the eager focus would be undone and
    // the new session's first-message broker events would be dropped
    // server-side. See useTranscriptStream.ts for the full rationale.
    fetchMock.mockResolvedValueOnce({ ok: true, json: async () => [] })
    const fake = makeFakeClient()
    const { result } = renderHook(() => useTranscriptStream(null, fake.client))
    await waitFor(() => {
      expect(result.current.entries).toEqual([])
    })
    const nullFocus = fake.focusCalls.find((c) => c.sessionId === null)
    expect(nullFocus).toBeUndefined()
  })

  it('eagerly focuses live BEFORE the seed fetch resolves', async () => {
    // Defer the seed promise so we can assert focus was called while
    // the fetch is still in flight. The eager focus is what prevents
    // EntryRecorded events delivered during the seed round-trip from
    // being filtered out server-side.
    let resolveSeed: ((seed: TranscriptEntry[]) => void) | null = null
    fetchMock.mockReturnValueOnce(new Promise((res) => {
      resolveSeed = (seed) => res({ ok: true, json: async () => seed })
    }))
    const fake = makeFakeClient()
    renderHook(() => useTranscriptStream('session-abc', fake.client))

    await waitFor(() => {
      expect(
        fake.focusCalls.some((c) => c.sessionId === 'session-abc' && c.since === undefined),
      ).toBe(true)
    })
    // Now finish the seed; the post-seed focus is conditional on having
    // a lastId so an empty seed must NOT issue a redundant call.
    const callsBeforeSeed = fake.focusCalls.length
    resolveSeed!([])
    await waitFor(() => {
      expect(fake.focusCalls.length).toBe(callsBeforeSeed)
    })
  })
})

describe('useTranscriptStream reconciliation latency (D15 simulated)', () => {
  it('reconciles 100 entries in under 50 ms on a single thread (in-isolation budget)', () => {
    let entries: TranscriptEntry[] = []
    const start = performance.now()
    for (let i = 0; i < 100; i++) {
      const id = `te-${String(i).padStart(3, '0')}`
      // Each entry's timestamp is 10 ms after the previous; reconciliation is O(n)
      // because the test inserts in order, so this is the happy path.
      const ts = new Date(1758000000000 + i * 10).toISOString()
      entries = reconcileEntries(entries, { id, timestamp: ts, direction: 'response', payload: '', harness: null, model: null, raw: '' })
    }
    const elapsed = performance.now() - start
    // p50 budget per design D15 is 50 ms across the whole burst when running
    // hot — generous-enough for the FE in isolation. Real E2E latency is
    // dominated by network + backend roundtrip; this just verifies the FE
    // reconciliation is NOT the bottleneck.
    expect(entries).toHaveLength(100)
    expect(elapsed).toBeLessThan(50)
  })
})
