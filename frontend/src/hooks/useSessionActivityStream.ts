/**
 * React hook: subscribe to per-session activity signals (entry-at,
 * harness-status, session-created) for ALL sessions.
 *
 * Used by the sidebar to render:
 *   - a thinking-spinner when `harness === 'thinking'`,
 *   - an unread badge when `unread > 0`,
 *   - "X seconds ago" from `lastEntryAt`.
 */

import { useEffect, useState } from 'react'
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
  client?: StreamClient,
): UseSessionActivityStream {
  const sc = client ?? streamClient()
  const [sessions, setSessions] = useState<Record<string, SessionActivityState>>({})
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())

  useEffect(() => {
    const unsub = sc.onActivity((sid, event) => {
      setSessions((prev) => applyActivity(prev, sid, event))
    })
    return unsub
  }, [sc])

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
