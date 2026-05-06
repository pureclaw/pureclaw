import { useState, useEffect, useCallback } from 'react'
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
  const [refreshCount, setRefreshCount] = useState(0)

  const refresh = useCallback(() => {
    setRefreshCount((c) => c + 1)
  }, [])

  useEffect(() => {
    if (!sessionId) {
      setEntries([])
      return
    }

    let cancelled = false
    setLoading(true)

    fetchJson<TranscriptEntry[]>(`/api/sessions/${encodeURIComponent(sessionId)}/transcript`)
      .then((data) => {
        if (cancelled) return
        setEntries(data ?? [])
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [sessionId, refreshCount])

  return { entries, loading, refresh }
}

export function useSendMessage(sessionId: string | null, onComplete: () => void) {
  const [sending, setSending] = useState(false)

  const send = useCallback(async (message: string) => {
    if (!sessionId || sending) return
    setSending(true)
    try {
      const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/send`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message }),
      })
      if (!res.ok) {
        const err = await res.json().catch(() => ({}))
        console.error('Send failed:', err)
      }
    } catch (e) {
      console.error('Send error:', e)
    } finally {
      setSending(false)
      onComplete()
    }
  }, [sessionId, sending, onComplete])

  return { send, sending }
}
