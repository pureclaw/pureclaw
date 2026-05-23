/**
 * Singleton WebSocket client for the live transcript streaming endpoint.
 *
 * Responsibilities:
 *   - Open a WS connection to `/api/stream` (relative URL by default).
 *   - Auto-reconnect with exponential backoff (250 ms -> 5 s, jittered, max 5
 *     attempts). On reconnect, re-send the last focus op with the most recent
 *     entry id as `since` so the server can replay missed entries.
 *   - Maintain a status union and notify subscribers on transitions.
 *   - Track `lastError` to distinguish hard errors (403/503) from clean closes.
 *
 * Per the design doc the client is a singleton at module scope; we also expose
 * a `createStreamClient(url)` factory for tests so each test can spin up a
 * fresh instance without polluting global state.
 */

import type {
  ActivityEvent,
  ClientOp,
  ServerEvent,
  StreamClient,
  StreamStatus,
} from '../types/stream'
import type { TranscriptEntry } from '../types'

const RECONNECT_BASE_MS = 250
const RECONNECT_MAX_MS = 5000
const RECONNECT_MAX_ATTEMPTS = 5

type FocusState =
  | { kind: 'none' }
  | { kind: 'focused'; sessionId: string | null; since: string | undefined }

class StreamClientImpl implements StreamClient {
  private url: string
  private ws: WebSocket | null = null
  private _status: StreamStatus = 'connecting'
  private focusState: FocusState = { kind: 'none' }
  private lastEntryId: string | null = null
  private _lastServerStartedAt: string | null = null
  private reconnectAttempt = 0
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private closedByUser = false
  private _lastError: string | null = null
  private statusListeners = new Set<(s: StreamStatus) => void>()
  private entryListeners = new Set<(e: TranscriptEntry) => void>()
  private activityListeners = new Set<(sid: string, a: ActivityEvent) => void>()

  constructor(url: string) {
    this.url = url
    this.connect()
  }

  get status(): StreamStatus {
    return this._status
  }

  lastError(): string | null {
    return this._lastError
  }

  /** Most recent `serverStartedAt` from a `hello` frame, or null. */
  lastServerStartedAt(): string | null {
    return this._lastServerStartedAt
  }

  focus(sessionId: string | null, since?: string): void {
    // Update intended focus state regardless of socket readiness.
    this.focusState = { kind: 'focused', sessionId, since }
    // When a session is unfocused, drop the entry-id tracker so a future
    // refocus does not accidentally replay from a stale id.
    if (sessionId === null) {
      this.lastEntryId = null
    }
    // If we have a session + since, optimistically enter `replaying` until
    // the server emits `replay-end` for this session.
    if (sessionId !== null && since !== undefined) {
      this.setStatus('replaying')
    }
    this.sendFocus()
  }

  onEntry(cb: (e: TranscriptEntry) => void): () => void {
    this.entryListeners.add(cb)
    return () => {
      this.entryListeners.delete(cb)
    }
  }

  onActivity(cb: (sid: string, a: ActivityEvent) => void): () => void {
    this.activityListeners.add(cb)
    return () => {
      this.activityListeners.delete(cb)
    }
  }

  onStatusChange(cb: (s: StreamStatus) => void): () => void {
    this.statusListeners.add(cb)
    return () => {
      this.statusListeners.delete(cb)
    }
  }

  /** Closes the connection permanently. No further reconnect attempts. */
  close(): void {
    this.closedByUser = true
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws !== null) {
      try {
        this.ws.close(1000, 'client closed')
      } catch {
        /* ignore */
      }
      this.ws = null
    }
    this.setStatus('closed')
  }

  // ---- internals -----------------------------------------------------------

  private connect(): void {
    let sock: WebSocket
    try {
      sock = new WebSocket(this.url)
    } catch (e) {
      // Browsers throw synchronously on some bad URLs. Treat as a fatal error.
      this._lastError = e instanceof Error ? e.message : 'WebSocket construction failed'
      this.setStatus('closed')
      return
    }
    this.ws = sock
    sock.onopen = () => this.handleOpen()
    sock.onmessage = (ev: MessageEvent) => this.handleMessage(ev)
    sock.onclose = (ev: CloseEvent) => this.handleClose(ev)
    sock.onerror = () => {
      // onerror always precedes onclose; we let close handle the bookkeeping
      // but capture the fact that an error occurred.
    }
  }

  private handleOpen(): void {
    this.setStatus('live')
    // If a focus was requested before/during disconnect, send it now.
    if (this.focusState.kind === 'focused') {
      // On reconnect, prefer the most recently seen entry id as `since`.
      const since =
        this.lastEntryId !== null && this.focusState.sessionId !== null
          ? this.lastEntryId
          : this.focusState.since
      const stateToSend: FocusState = {
        kind: 'focused',
        sessionId: this.focusState.sessionId,
        since,
      }
      // If we're sending a non-null sessionId WITH a since, we are in replay.
      if (stateToSend.sessionId !== null && since !== undefined) {
        this.setStatus('replaying')
      }
      this.sendFocusFrame(stateToSend)
    }
  }

  private sendFocus(): void {
    if (this.focusState.kind !== 'focused') return
    if (this.ws !== null && this.ws.readyState === WebSocket.OPEN) {
      this.sendFocusFrame(this.focusState)
    }
    // Otherwise: drop. `handleOpen` reads from `focusState` and sends on next connect.
  }

  private sendFocusFrame(fs: FocusState): void {
    if (fs.kind !== 'focused') return
    if (this.ws === null || this.ws.readyState !== WebSocket.OPEN) return
    const op: ClientOp =
      fs.sessionId === null
        ? { op: 'focus', sessionId: null }
        : fs.since !== undefined
          ? { op: 'focus', sessionId: fs.sessionId, since: fs.since }
          : { op: 'focus', sessionId: fs.sessionId }
    try {
      this.ws.send(JSON.stringify(op))
    } catch (e) {
      this._lastError = e instanceof Error ? e.message : 'send failed'
    }
  }

  private handleMessage(ev: MessageEvent): void {
    let parsed: unknown
    try {
      parsed = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data))
    } catch {
      // Malformed frame from server — ignore and keep the connection open.
      return
    }
    if (parsed === null || typeof parsed !== 'object' || !('type' in parsed)) return
    // First server message after a (re)connect is evidence the connection is
    // healthy — reset the reconnect attempt counter. Resetting on `open` is
    // insufficient because some failure modes (e.g. immediate server-side
    // close after upgrade) raise close without ever delivering a frame.
    this.reconnectAttempt = 0
    const event = parsed as ServerEvent
    switch (event.type) {
      case 'hello':
        this._lastServerStartedAt = event.serverStartedAt
        break
      case 'entry': {
        // Track most-recent entry id for reconnect-with-since.
        this.lastEntryId = event.entry.id
        // Dispatch only when the event matches the currently focused session.
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId !== null &&
          this.focusState.sessionId === event.sessionId
        ) {
          for (const cb of this.entryListeners) cb(event.entry)
        }
        break
      }
      case 'activity':
        for (const cb of this.activityListeners) cb(event.sessionId, event.activity)
        break
      case 'replay-end':
        if (
          this.focusState.kind === 'focused' &&
          this.focusState.sessionId === event.sessionId
        ) {
          if (event.lastReplayedEntryId !== null) {
            this.lastEntryId = event.lastReplayedEntryId
          }
          this.setStatus('live')
        }
        break
      case 'overflow':
        this._lastError = 'Server queue overflow — please refresh'
        break
      case 'error':
        this._lastError = `${event.code}: ${event.message}`
        break
      default:
        // Forward-compat: ignore unknown event types.
        break
    }
  }

  private handleClose(ev: CloseEvent): void {
    if (this.closedByUser) {
      this.setStatus('closed')
      return
    }
    if (!ev.wasClean) {
      // Capture diagnostic reason (e.g., "Origin not allowed" on 403).
      if (ev.reason) {
        this._lastError = ev.reason
      } else if (this._lastError === null) {
        this._lastError = `connection closed (code ${ev.code})`
      }
    }
    this.ws = null
    if (this.reconnectAttempt >= RECONNECT_MAX_ATTEMPTS) {
      this.setStatus('closed')
      return
    }
    this.setStatus('reconnecting')
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    const attempt = this.reconnectAttempt
    this.reconnectAttempt += 1
    // Exponential backoff: 250, 500, 1000, 2000, 4000 — capped at RECONNECT_MAX_MS.
    const expo = Math.min(RECONNECT_BASE_MS * Math.pow(2, attempt), RECONNECT_MAX_MS)
    // Full jitter in [0.5x, 1.0x] to avoid thundering-herd reconnects.
    const jitterFloor = expo * 0.5
    const delay = jitterFloor + Math.random() * (expo - jitterFloor)
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null
      if (this.closedByUser) return
      this.connect()
    }, delay)
  }

  private setStatus(s: StreamStatus): void {
    if (this._status === s) return
    this._status = s
    for (const cb of this.statusListeners) cb(s)
  }
}

/** Factory used by tests; production uses the shared `streamClient` singleton. */
export function createStreamClient(url: string): StreamClient & { close(): void } {
  return new StreamClientImpl(url)
}

/**
 * Build the default WS URL from the current page. Uses `wss:` on https pages
 * and `ws:` on http pages; the path is `/api/stream`.
 */
function defaultStreamUrl(): string {
  if (typeof window === 'undefined') return 'ws://localhost:8080/api/stream'
  const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${proto}//${window.location.host}/api/stream`
}

let _instance: (StreamClient & { close(): void }) | null = null

/** Shared singleton — lazily constructed on first access. */
export function streamClient(): StreamClient {
  if (_instance === null) {
    _instance = new StreamClientImpl(defaultStreamUrl())
  }
  return _instance
}
