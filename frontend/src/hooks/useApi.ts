import { useState, useEffect, useCallback, useRef } from 'react'
import type { HarnessInfo, SessionInfo, TranscriptEntry } from '../types'

const POLL_INTERVAL = 3000

async function fetchJson<T>(url: string): Promise<T | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    return await res.json() as T
  } catch {
    return null
  }
}

export function useHarnesses() {
  const [harnesses, setHarnesses] = useState<HarnessInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<HarnessInfo[]>('/api/harnesses')
    if (data) {
      setHarnesses(data)
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { harnesses, error }
}

export function useRecentSessions() {
  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<SessionInfo[]>('/api/sessions/recent')
    if (data) {
      setSessions(data)
      setError(false)
    } else {
      setError(true)
    }
  }, [])

  useEffect(() => {
    poll()
    const id = setInterval(poll, POLL_INTERVAL)
    return () => clearInterval(id)
  }, [poll])

  return { sessions, error }
}

export function useTranscript(sessionId: string | null) {
  const [entries, setEntries] = useState<TranscriptEntry[]>([])
  const [loading, setLoading] = useState(false)
  const lastFetchedId = useRef<string | null>(null)

  useEffect(() => {
    if (!sessionId) {
      setEntries([])
      lastFetchedId.current = null
      return
    }

    // Don't re-fetch if already loaded
    if (sessionId === lastFetchedId.current) return

    let cancelled = false
    setLoading(true)

    fetchJson<TranscriptEntry[]>(`/api/sessions/${encodeURIComponent(sessionId)}/transcript`)
      .then((data) => {
        if (cancelled) return
        setEntries(data ?? [])
        lastFetchedId.current = sessionId
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [sessionId])

  return { entries, loading }
}
