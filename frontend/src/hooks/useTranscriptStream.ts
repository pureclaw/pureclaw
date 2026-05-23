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
 * timestamp ascending. Returns the same reference when nothing changes so
 * React can short-circuit re-renders.
 */
export function reconcileEntries(
  existing: TranscriptEntry[],
  incoming: TranscriptEntry,
): TranscriptEntry[] {
  for (let i = 0; i < existing.length; i++) {
    if (existing[i]!.id === incoming.id) return existing
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
  useEffect(() => {
    if (sessionId === null) {
      setEntries([])
      sc.focus(null)
      return
    }
    let cancelled = false
    fetchTranscriptSeed(sessionId).then((seed) => {
      if (cancelled) return
      setEntries(seed)
      const lastId = seed.length > 0 ? seed[seed.length - 1]!.id : undefined
      sc.focus(sessionId, lastId)
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
