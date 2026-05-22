import { useState, useEffect, useCallback } from 'react'
import type { AgentInfo, HarnessInfo, SessionInfo, TranscriptEntry } from '../types'

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

/** Set or clear the user-provided session description. Passing null
 *  (or an all-whitespace string, which the backend normalises) clears
 *  the field, restoring the auto-summary / snippet / agent fallback. */
export async function setSessionDescription(sessionId: string, description: string | null): Promise<boolean> {
  try {
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/description`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ description }),
    })
    return res.ok
  } catch {
    return false
  }
}

/** Set the archive flag on a session. Pure UI hint — the session
 *  directory and transcript stay on disk. */
export async function setSessionArchived(sessionId: string, archived: boolean): Promise<boolean> {
  try {
    const path = archived ? 'archive' : 'unarchive'
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/${path}`, {
      method: 'POST',
    })
    return res.ok
  } catch {
    return false
  }
}

export async function setSessionPrompt(sessionId: string, prompt: string, name?: string): Promise<boolean> {
  try {
    const body: Record<string, string> = { prompt }
    if (name) body.name = name
    const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/prompt`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    return res.ok
  } catch {
    return false
  }
}

export function useAgents() {
  const [agents, setAgents] = useState<AgentInfo[]>([])

  useEffect(() => {
    fetchJson<AgentInfo[]>('/api/agents').then((data) => {
      if (data) setAgents(data)
    })
  }, [])

  return { agents }
}

export async function createSession(agent?: string, customPrompt?: string): Promise<import('../types').SessionInfo | null> {
  try {
    const body: Record<string, string> = {}
    if (agent) body.agent = agent
    if (customPrompt) body.customPrompt = customPrompt
    const res = await fetch('/api/sessions/new', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) return null
    return await res.json() as import('../types').SessionInfo
  } catch {
    return null
  }
}
