/**
 * React hook: subscribe to per-session activity signals (entry-at,
 * harness-status, session-created) for ALL sessions.
 *
 * Used by the sidebar to render:
 *   - a thinking-spinner when `harness === 'thinking'`,
 *   - an unread badge when `unread > 0`,
 *   - "X seconds ago" from `lastEntryAt`.
 */

import { useEffect, useRef, useState } from 'react'
import type {
  ActivityEvent,
  SessionActivityState,
  StreamClient,
  StreamStatus,
  UseSessionActivityStream,
} from '../types/stream'
import { streamClient } from '../lib/streamClient'

const DEFAULT_STATE: SessionActivityState = {
  harness: null,
  unread: 0,
  lastEntryAt: null,
}

export function applyActivity(
  current: Record<string, SessionActivityState>,
  sessionId: string,
  event: ActivityEvent,
): Record<string, SessionActivityState> {
  const prev = current[sessionId] ?? DEFAULT_STATE
  let next: SessionActivityState
  switch (event.kind) {
    case 'entry-at':
      next = {
        ...prev,
        unread: prev.unread + 1,
        lastEntryAt: event.timestamp,
      }
      break
    case 'harness-status':
      if (prev.harness === event.status) return current
      next = { ...prev, harness: event.status }
      break
    case 'session-created':
      // session-created seeds an entry but otherwise leaves the counters alone
      // (the entry itself surfaces as entry-at later).
      if (current[sessionId] !== undefined) return current
      next = { ...DEFAULT_STATE }
      break
    default:
      return current
  }
  return { ...current, [sessionId]: next }
}

export function useSessionActivityStream(
  focusedSessionId: string | null,
  client?: StreamClient,
): UseSessionActivityStream {
  const sc = client ?? streamClient()
  const [sessions, setSessions] = useState<Record<string, SessionActivityState>>({})
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())

  // Latest focused id, accessed inside the activity callback. Using a ref
  // avoids re-subscribing to the stream every time focus changes.
  const focusedRef = useRef<string | null>(focusedSessionId)
  useEffect(() => {
    focusedRef.current = focusedSessionId
  }, [focusedSessionId])

  useEffect(() => {
    const unsub = sc.onActivity((sid, event) => {
      setSessions((prev) => {
        const next = applyActivity(prev, sid, event)
        // Entries arriving for the currently-viewed session are not
        // "unread" — the user is looking at them right now.
        if (
          event.kind === 'entry-at' &&
          focusedRef.current !== null &&
          focusedRef.current === sid
        ) {
          return clearUnread(next, sid)
        }
        return next
      })
    })
    return unsub
  }, [sc])

  // When the focus changes to a session, zero its accumulated unread —
  // by switching to it the user has caught up.
  useEffect(() => {
    if (focusedSessionId === null) return
    setSessions((prev) => clearUnread(prev, focusedSessionId))
  }, [focusedSessionId])

  useEffect(() => {
    const unsub = sc.onStatusChange((s) => {
      setStatus(s)
      setLastError(sc.lastError())
    })
    return unsub
  }, [sc])

  return { sessions, status, lastError }
}

/** Clear the unread counter for a session (e.g. when the user selects it). */
export function clearUnread(
  current: Record<string, SessionActivityState>,
  sessionId: string,
): Record<string, SessionActivityState> {
  const prev = current[sessionId]
  if (prev === undefined || prev.unread === 0) return current
  return { ...current, [sessionId]: { ...prev, unread: 0 } }
}
