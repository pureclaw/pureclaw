/**
 * React hook: subscribe to a session's transcript via:
 *   1. an initial HTTP GET seed (existing /api/sessions/:id/transcript),
 *   2. a WS subscription that focuses the session and tails subsequent entries.
 *
 * The hook deduplicates by entry id and keeps the array sorted by timestamp
 * ascending. Status + lastError reflect the underlying singleton stream client.
 */

import { useEffect, useState } from 'react'
import type { TranscriptEntry } from '../types'
import type { StreamClient, StreamStatus, UseTranscriptStream } from '../types/stream'
import { streamClient } from '../lib/streamClient'

async function fetchTranscriptSeed(sessionId: string): Promise<TranscriptEntry[]> {
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/transcript`)
    if (!res.ok) return []
    return (await res.json()) as TranscriptEntry[]
  } catch {
    return []
  }
}

/**
 * Pure reconciler: insert `incoming` into `existing`, dedup by id, sort by
 * timestamp ascending. Replaces the entry with a matching id (always returns
 * a new array), or inserts new entries at the sorted position by timestamp.
 */
export function reconcileEntries(
  existing: TranscriptEntry[],
  incoming: TranscriptEntry,
): TranscriptEntry[] {
  for (let i = 0; i < existing.length; i++) {
    if (existing[i]!.id === incoming.id) {
      // Replace in place (stable timestamp keeps sort order intact; streaming
      // entry-update entries carry their original timestamp throughout).
      const next = existing.slice()
      next[i] = incoming
      return next
    }
  }
  // Find insertion index that keeps the array sorted by timestamp ascending.
  let insertAt = existing.length
  for (let i = existing.length - 1; i >= 0; i--) {
    if (existing[i]!.timestamp.localeCompare(incoming.timestamp) <= 0) {
      insertAt = i + 1
      break
    }
    insertAt = i
  }
  const next = existing.slice()
  next.splice(insertAt, 0, incoming)
  return next
}

export function useTranscriptStream(
  sessionId: string | null,
  client?: StreamClient,
): UseTranscriptStream {
  const sc = client ?? streamClient()
  const [entries, setEntries] = useState<TranscriptEntry[]>([])
  const [status, setStatus] = useState<StreamStatus>(sc.status)
  const [lastError, setLastError] = useState<string | null>(sc.lastError())

  // Initial HTTP GET seed + focus the session.
  //
  // NOTE on focus timing: the WS server filters EntryRecorded events by
  // `_conn_focus` (PureClaw.Frontend.Stream.handleEvent). If focus isn't
  // set when a broker event is published, the event is silently dropped
  // for this connection. There are two cases that used to lose events:
  //
  //   1. General session switch: focus(sid, lastId) only fired AFTER the
  //      seed HTTP GET resolved, so any live event during the GET round
  //      trip was filtered out. Fix: set live focus eagerly, BEFORE the
  //      seed fetch, then upgrade to a `since`-replay focus once the
  //      seed lands.
  //
  //   2. Compose-send race: handleComposerSend (App.tsx) sets selectedId
  //      to the new tab and triggers POST /send before the WS lists
  //      snapshot has populated the local `tabs` array. During that
  //      window, sessionIdFromSelection resolves to null and this hook
  //      runs with sessionId === null. We must NOT downgrade focus to
  //      null in that case — handleComposerSend has already eagerly
  //      focused the new session id, and clearing it here would re-open
  //      the drop window. Genuine compose-mode (no selection at all) is
  //      indistinguishable from the lag, but a stale focus on a closed
  //      session is harmless: the server still routes only matching
  //      events, and no hook is subscribed to consume them.
  useEffect(() => {
    if (sessionId === null) {
      setEntries([])
      return
    }
    sc.focus(sessionId)
    let cancelled = false
    fetchTranscriptSeed(sessionId).then((seed) => {
      if (cancelled) return
      setEntries(seed)
      const lastId = seed.length > 0 ? seed[seed.length - 1]!.id : undefined
      if (lastId !== undefined) {
        sc.focus(sessionId, lastId)
      }
    })
    return () => {
      cancelled = true
    }
  }, [sessionId, sc])

  // WS entry subscription (focused session only).
  useEffect(() => {
    if (sessionId === null) return
    const unsub = sc.onEntry((e) => {
      setEntries((prev) => reconcileEntries(prev, e))
    })
    return unsub
  }, [sessionId, sc])

  // Status + lastError subscriptions.
  useEffect(() => {
    const unsub = sc.onStatusChange((s) => {
      setStatus(s)
      setLastError(sc.lastError())
    })
    return unsub
  }, [sc])

  return { entries, status, lastError }
}
