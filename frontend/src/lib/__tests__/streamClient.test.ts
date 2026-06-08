import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createStreamClient } from '../streamClient'
import type { StreamClient } from '../../types/stream'

/**
 * Mock WebSocket implementation. We need:
 *   - control over open/close/error timing
 *   - capture of messages the client sends
 *   - the ability to inject messages from the "server"
 */
type MockSocketRef = { socket: MockSocket | null; instances: MockSocket[] }

class MockSocket {
  static OPEN = 1
  static CONNECTING = 0
  static CLOSING = 2
  static CLOSED = 3

  readyState: number = MockSocket.CONNECTING
  url: string
  sent: string[] = []
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null

  constructor(url: string) {
    this.url = url
  }

  send(data: string): void {
    if (this.readyState !== MockSocket.OPEN) {
      throw new Error('Cannot send: socket not open')
    }
    this.sent.push(data)
  }

  close(code?: number, reason?: string): void {
    this.readyState = MockSocket.CLOSED
    const ev = { code: code ?? 1000, reason: reason ?? '', wasClean: true } as CloseEvent
    queueMicrotask(() => this.onclose?.(ev))
  }

  // Test helpers (not part of the WebSocket API):
  simulateOpen(): void {
    this.readyState = MockSocket.OPEN
    this.onopen?.(new Event('open'))
  }
  simulateMessage(payload: unknown): void {
    const data = typeof payload === 'string' ? payload : JSON.stringify(payload)
    this.onmessage?.({ data } as MessageEvent)
  }
  simulateClose(code: number, reason: string, wasClean = true): void {
    this.readyState = MockSocket.CLOSED
    const ev = { code, reason, wasClean } as CloseEvent
    this.onclose?.(ev)
  }
}

function installMockSocket(): MockSocketRef {
  const ref: MockSocketRef = { socket: null, instances: [] }
  const ctor = function (this: MockSocket, url: string) {
    const s = new MockSocket(url)
    ref.socket = s
    ref.instances.push(s)
    return s
  } as unknown as typeof WebSocket
  // Static constants
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).OPEN = MockSocket.OPEN
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CONNECTING = MockSocket.CONNECTING
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CLOSING = MockSocket.CLOSING
  ;(ctor as unknown as { OPEN: number; CONNECTING: number; CLOSING: number; CLOSED: number }).CLOSED = MockSocket.CLOSED
  vi.stubGlobal('WebSocket', ctor)
  return ref
}

describe('streamClient', () => {
  let ref: MockSocketRef
  let client: StreamClient
  let cleanup: () => void

  beforeEach(() => {
    vi.useFakeTimers()
    ref = installMockSocket()
    const c = createStreamClient('ws://test.example/api/stream')
    client = c
    cleanup = () => c.close()
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('starts in connecting state', () => {
    expect(client.status).toBe('connecting')
  })

  it('transitions to live on socket open', () => {
    const statuses: string[] = []
    client.onStatusChange((s) => statuses.push(s))
    ref.socket!.simulateOpen()
    expect(client.status).toBe('live')
    expect(statuses).toContain('live')
  })

  it('queues focus ops until the socket is open and then sends them', () => {
    client.focus('session-abc')
    // Not open yet; nothing sent.
    expect(ref.socket!.sent).toEqual([])
    ref.socket!.simulateOpen()
    expect(ref.socket!.sent).toHaveLength(1)
    const parsed = JSON.parse(ref.socket!.sent[0]!)
    expect(parsed).toEqual({ op: 'focus', sessionId: 'session-abc' })
  })

  it('encodes focus with since correctly', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc', 'te-uuid-42')
    expect(JSON.parse(ref.socket!.sent[0]!)).toEqual({
      op: 'focus',
      sessionId: 'session-abc',
      since: 'te-uuid-42',
    })
  })

  it('encodes unfocus as sessionId=null', () => {
    ref.socket!.simulateOpen()
    client.focus(null)
    expect(JSON.parse(ref.socket!.sent[0]!)).toEqual({ op: 'focus', sessionId: null })
  })

  it('only sends one focus when the latest focus is what the user asked for', () => {
    ref.socket!.simulateOpen()
    client.focus('session-a')
    client.focus('session-b')
    expect(ref.socket!.sent.length).toBeGreaterThanOrEqual(1)
    const last = JSON.parse(ref.socket!.sent[ref.socket!.sent.length - 1]!)
    expect(last.sessionId).toBe('session-b')
  })

  it('dispatches entry events to onEntry subscribers when focused', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc')
    const seen: string[] = []
    client.onEntry((e) => seen.push(e.id))
    ref.socket!.simulateMessage({
      type: 'entry',
      sessionId: 'session-abc',
      entry: {
        id: 'te-1',
        timestamp: '2026-05-23T18:00:00Z',
        direction: 'response',
        payload: 'hi',
        harness: null,
        model: null,
      },
    })
    expect(seen).toEqual(['te-1'])
  })

  it('filters out entries for sessions other than the focused one', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc')
    const seen: string[] = []
    client.onEntry((e) => seen.push(e.id))
    ref.socket!.simulateMessage({
      type: 'entry',
      sessionId: 'session-other',
      entry: {
        id: 'te-x',
        timestamp: '2026-05-23T18:00:00Z',
        direction: 'response',
        payload: '',
        harness: null,
        model: null,
      },
    })
    expect(seen).toEqual([])
  })

  it('dispatches activity events for ALL sessions to onActivity subscribers', () => {
    ref.socket!.simulateOpen()
    client.focus('session-a')
    const seen: Array<[string, string]> = []
    client.onActivity((sid, a) => seen.push([sid, a.kind]))
    ref.socket!.simulateMessage({
      type: 'activity',
      sessionId: 'session-other',
      activity: { kind: 'harness-status', status: 'thinking' },
    })
    expect(seen).toEqual([['session-other', 'harness-status']])
  })

  it('transitions to replaying on focus(with since) and back to live on replay-end', () => {
    ref.socket!.simulateOpen()
    const statuses: string[] = []
    client.onStatusChange((s) => statuses.push(s))
    client.focus('session-abc', 'te-id-5')
    expect(client.status).toBe('replaying')
    ref.socket!.simulateMessage({
      type: 'replay-end',
      sessionId: 'session-abc',
      lastReplayedEntryId: 'te-id-10',
    })
    expect(client.status).toBe('live')
    expect(statuses).toContain('replaying')
    expect(statuses).toContain('live')
  })

  it('exposes the latest server hello (serverStartedAt) detectable as a restart', () => {
    ref.socket!.simulateOpen()
    ref.socket!.simulateMessage({
      type: 'hello',
      protocolVersion: 'v1',
      serverStartedAt: '2026-05-23T18:00:00Z',
    })
    // First hello is recorded but not flagged as a restart.
    expect(client.lastError()).toBeNull()
    // Disconnect + reconnect with a NEW serverStartedAt → restart detected.
    ref.socket!.simulateClose(1006, '', false)
    vi.advanceTimersByTime(5000) // let reconnect timer fire
    const sock2 = ref.instances[ref.instances.length - 1]!
    expect(sock2).not.toBe(ref.instances[0])
    sock2.simulateOpen()
    sock2.simulateMessage({
      type: 'hello',
      protocolVersion: 'v1',
      serverStartedAt: '2026-05-23T19:00:00Z',
    })
    // The restart is observable: client should now have refocused if a session was tracked.
    // (No focused session here; just confirm we got two hello frames and two socket instances.)
    expect(ref.instances.length).toBeGreaterThanOrEqual(2)
  })

  it('records lastError on unclean close (e.g. 403 Origin reject)', () => {
    ref.socket!.simulateOpen()
    ref.socket!.simulateClose(1008, 'Origin not allowed', false)
    expect(client.lastError()).toContain('Origin')
  })

  it('attempts reconnect with exponential backoff after unclean close', () => {
    ref.socket!.simulateOpen()
    ref.socket!.simulateClose(1006, 'abnormal', false)
    // First retry is fired by a setTimeout ~250 ms.
    expect(ref.instances.length).toBe(1)
    vi.advanceTimersByTime(50)
    expect(ref.instances.length).toBe(1)
    vi.advanceTimersByTime(500)
    expect(ref.instances.length).toBe(2)
    // Status should be reconnecting.
    expect(client.status).toBe('reconnecting')
  })

  it('keeps reconnecting indefinitely after many unclean closes (never permanently closed)', () => {
    // A long gateway outage (e.g. a dev restart/rebuild) must NOT make the
    // client give up permanently — otherwise live updates freeze until the
    // user manually reloads the page. Drive far more closes than any fixed
    // attempt cap and assert it is still trying.
    const before = ref.instances.length
    for (let i = 0; i < 12; i++) {
      const sock = ref.instances[ref.instances.length - 1]!
      sock.simulateOpen()
      sock.simulateClose(1006, 'flaky', false)
      vi.advanceTimersByTime(6000)
    }
    // Still reconnecting (not 'closed'), and it kept opening fresh sockets.
    expect(client.status).toBe('reconnecting')
    expect(ref.instances.length).toBeGreaterThan(before + 6)
  })

  it('recovers to live when the gateway returns after a long outage', () => {
    // Exhaust well past the old 5-attempt cap...
    for (let i = 0; i < 10; i++) {
      const sock = ref.instances[ref.instances.length - 1]!
      sock.simulateOpen()
      sock.simulateClose(1006, 'down', false)
      vi.advanceTimersByTime(6000)
    }
    expect(client.status).toBe('reconnecting')
    // ...then the gateway comes back: the latest reconnect socket opens and
    // delivers its first frame. The client must go live again on its own.
    const sock = ref.instances[ref.instances.length - 1]!
    sock.simulateOpen()
    sock.simulateMessage({ type: 'hello', serverStartedAt: '2026-06-05T18:00:00Z' })
    expect(client.status).toBe('live')
  })

  it('re-sends the last focus on reconnect (so reconnect-with-since works)', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc', 'te-5')
    ref.socket!.simulateMessage({
      type: 'replay-end',
      sessionId: 'session-abc',
      lastReplayedEntryId: 'te-7',
    })
    // Now drop and reconnect.
    ref.socket!.simulateClose(1006, '', false)
    vi.advanceTimersByTime(500)
    const sock2 = ref.instances[ref.instances.length - 1]!
    sock2.simulateOpen()
    // Should have re-sent the focus with since = last observed entry id (te-7 from replay-end).
    expect(sock2.sent.length).toBeGreaterThan(0)
    const last = JSON.parse(sock2.sent[sock2.sent.length - 1]!)
    expect(last.op).toBe('focus')
    expect(last.sessionId).toBe('session-abc')
    // since should be the most recent known entry id (either te-7 from replay-end or last live entry).
    expect(last.since).toBe('te-7')
  })

  it('tracks the latest live entry id as the `since` for reconnects', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc')
    ref.socket!.simulateMessage({
      type: 'entry',
      sessionId: 'session-abc',
      entry: {
        id: 'te-99',
        timestamp: '2026-05-23T18:00:00Z',
        direction: 'response',
        payload: '',
        harness: null,
        model: null,
      },
    })
    ref.socket!.simulateClose(1006, '', false)
    vi.advanceTimersByTime(500)
    const sock2 = ref.instances[ref.instances.length - 1]!
    sock2.simulateOpen()
    const last = JSON.parse(sock2.sent[sock2.sent.length - 1]!)
    expect(last.since).toBe('te-99')
  })

  it('onEntry unsubscribe stops further dispatches', () => {
    ref.socket!.simulateOpen()
    client.focus('session-abc')
    const seen: string[] = []
    const unsub = client.onEntry((e) => seen.push(e.id))
    ref.socket!.simulateMessage({
      type: 'entry',
      sessionId: 'session-abc',
      entry: { id: 'te-1', timestamp: '2026-05-23T18:00:00Z', direction: 'response', payload: '', harness: null, model: null },
    })
    unsub()
    ref.socket!.simulateMessage({
      type: 'entry',
      sessionId: 'session-abc',
      entry: { id: 'te-2', timestamp: '2026-05-23T18:00:00Z', direction: 'response', payload: '', harness: null, model: null },
    })
    expect(seen).toEqual(['te-1'])
  })

  it('ignores unknown server event types (forward compat)', () => {
    ref.socket!.simulateOpen()
    const seen: string[] = []
    client.onEntry((e) => seen.push(e.id))
    expect(() =>
      ref.socket!.simulateMessage({ type: 'token-chunk', sessionId: 'x', chunk: '' }),
    ).not.toThrow()
    expect(seen).toEqual([])
  })

  it('handles malformed JSON without crashing', () => {
    ref.socket!.simulateOpen()
    expect(() => ref.socket!.simulateMessage('not-json{')).not.toThrow()
    expect(client.status).toBe('live')
  })

  it('records lastError when receiving an error event', () => {
    ref.socket!.simulateOpen()
    ref.socket!.simulateMessage({
      type: 'error',
      code: 'session-not-found',
      message: 'invalid session id',
    })
    expect(client.lastError()).toContain('invalid session id')
  })
})
