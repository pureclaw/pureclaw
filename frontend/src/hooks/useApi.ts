import { useState, useEffect, useCallback } from 'react'
import type { AgentInfo, HarnessInfo, SessionInfo, TabInfo, TabOrigin, TabStatus, TranscriptEntry } from '../types'

const POLL_INTERVAL = 3000

/** Raw `/api/tabs` (and WS `lists`) wire shape: the backend emits the new
 *  health fields in snake_case. `index`/`kind`/`name`/`status`/`session_id`
 *  are already in their final shape; the rest map to camelCase TabInfo keys. */
interface TabInfoWire {
  index: number
  kind: string
  name: string
  status: string
  session_id: string | null
  ext_modified?: boolean
  stale?: boolean
  origin?: string
  attach_command?: string | null
}

/** Normalize a backend tab object to the camelCase `TabInfo` shape the UI
 *  renders. Tolerant of Phase-1 objects lacking the new fields (back-compat):
 *  flags default to false, attachCommand to null, origin to undefined. */
export function mapTabInfo(wire: TabInfoWire): TabInfo {
  return {
    index: wire.index,
    kind: wire.kind,
    name: wire.name,
    status: wire.status as TabStatus,
    session_id: wire.session_id,
    extModified: wire.ext_modified ?? false,
    stale: wire.stale ?? false,
    origin: wire.origin as TabOrigin | undefined,
    attachCommand: wire.attach_command ?? null,
  }
}

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

export function useTabs() {
  const [tabs, setTabs] = useState<TabInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<TabInfoWire[]>('/api/tabs')
    if (data) {
      setTabs(data.map(mapTabInfo))
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

  // `refresh` lets callers force an immediate poll instead of waiting
  // for the next interval. The new-tab compose-send flow uses this so
  // that the just-created tab is in the local tabs list BEFORE it sets
  // selectedId — without this, sessionIdFromSelection can't resolve
  // "tab:N" until the next interval fires, leaving downstream session-
  // derived state (useTranscript, useSendMessage, useTranscriptStream
  // focus) bound to null and silently dropping live transcript updates
  // for the new tab's first message.
  return { tabs, error, refresh: poll }
}

export function useArchivedSessions() {
  const [sessions, setSessions] = useState<SessionInfo[]>([])
  const [error, setError] = useState(false)

  const poll = useCallback(async () => {
    const data = await fetchJson<SessionInfo[]>('/api/sessions/archived')
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

  // `model` selects the per-session model for this turn (frontend-only
  // state, never persisted). When null/empty it is omitted from the body
  // so the backend falls back to the most-recent transcript `_te_model`
  // (else the global default) per §9.2.
  const send = useCallback(async (message: string, model?: string | null) => {
    if (!sessionId || sending) return
    setSending(true)
    try {
      const body: { message: string; model?: string } = { message }
      if (model && model.trim()) body.model = model
      const res = await fetch(`/api/sessions/${encodeURIComponent(sessionId)}/send`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
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
      if (Array.isArray(data)) setAgents(data)
    })
  }, [])

  return { agents }
}

/** Live fetch of available model IDs for a provider. The backend proxies
 *  the call to the provider's `/v1/models` endpoint using the credentials
 *  configured in the vault. Returns an empty list when the provider is
 *  unknown, has no credentials, or the upstream call fails. Never throws. */
export async function fetchProviderModels(provider: string): Promise<string[]> {
  const data = await fetchJson<string[]>(`/api/providers/${encodeURIComponent(provider)}/models`)
  return Array.isArray(data) ? data : []
}

/** A provider the user has configured. `isDefault` marks the one the
 *  running PureClaw instance is configured to use (from CLI flag or
 *  config file). At most one entry has it set to true. */
export interface ProviderInfo {
  name: string
  isDefault: boolean
  defaultModel?: string
}

/** Providers the user has actually configured (API key present, or
 *  Ollama reachable). Used to filter the New Tab provider dropdown.
 *  Returns an empty list if the call fails. */
export function useConfiguredProviders() {
  const [providers, setProviders] = useState<ProviderInfo[]>([])
  const [loaded, setLoaded] = useState(false)

  useEffect(() => {
    fetchJson<ProviderInfo[]>('/api/providers').then((data) => {
      if (Array.isArray(data)) setProviders(data)
      setLoaded(true)
    })
  }, [])

  return { providers, loaded }
}

/** Response from POST /api/tabs/new */
export interface NewTabResponse {
  tab_index: number
  session_id: string | null
  kind: string
}

/** Create a new tab via the unified POST /api/tabs/new endpoint.
 *  For provider-backed sessions, the response includes a session_id
 *  that can be used to load the transcript. For raw shell tabs the
 *  session_id is null. */
export async function createTab(agent?: string, _customPrompt?: string): Promise<NewTabResponse | null> {
  try {
    // Build the TabKind payload. For now the frontend only creates
    // provider-backed session tabs (the "New Session" button path).
    const sessionKind: Record<string, unknown> = {
      tag: 'provider',
      provider: 'anthropic',
      model: 'placeholder',
    }
    if (agent) {
      sessionKind.agent = agent
    }
    const body = {
      kind: {
        tag: 'session',
        session_kind: sessionKind,
      },
    }
    const res = await fetch('/api/tabs/new', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) return null
    return await res.json() as NewTabResponse
  } catch {
    return null
  }
}

/** Close a tab by index. Returns true if the backend accepted the close. */
export async function closeTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/close`, {
      method: 'POST',
    })
    return res.ok
  } catch {
    return false
  }
}

/** Dismiss an exited/orphaned tab by index — removes the live row. The
 *  underlying session stays in Recent Sessions (session.json is untouched).
 *  Returns true if the backend accepted the dismiss. */
export async function dismissTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/dismiss`, {
      method: 'POST',
    })
    return res.ok
  } catch {
    return false
  }
}

/** Acknowledge an externally-modified tab by index — clears its `ext_modified`
 *  flag on the registry entry. Returns true if the backend accepted it. */
export async function acknowledgeTab(index: number): Promise<boolean> {
  try {
    const res = await fetch(`/api/tabs/${index}/acknowledge`, {
      method: 'POST',
    })
    return res.ok
  } catch {
    return false
  }
}

/** Resume an archived session: unarchive it, then create a new tab for it.
 *  Returns the new tab response on success, or null on failure. */
export async function resumeArchivedSession(sessionId: string): Promise<NewTabResponse | null> {
  // Step 1: Unarchive the session
  const unarchived = await setSessionArchived(sessionId, false)
  if (!unarchived) return null

  // Step 2: Create a new tab for the session
  const tab = await createTab()
  return tab
}

/** @deprecated Use createTab instead. This function is kept for
 *  backward compatibility but now calls the new /api/tabs/new endpoint
 *  and wraps the response to match the old SessionInfo shape. */
export async function createSession(agent?: string, customPrompt?: string): Promise<import('../types').SessionInfo | null> {
  const tab = await createTab(agent, customPrompt)
  if (!tab || !tab.session_id) return null
  // Synthesise a minimal SessionInfo from the tab response so existing
  // call sites continue to work until they migrate to createTab.
  return {
    id: tab.session_id,
    agent: agent ?? null,
    runtime: tab.kind,
    model: '',
    lastActive: new Date().toISOString(),
    createdAt: new Date().toISOString(),
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
  }
}
