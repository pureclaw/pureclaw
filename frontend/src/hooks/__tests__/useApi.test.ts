import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook, waitFor } from '@testing-library/react'
import { acknowledgeTab, adoptWindow, closeTab, createSession, createTab, destroyHarness, dismissTab, fetchProviderModels, mapDiscoverableWindow, mapTabInfo, releaseHarness, resumeArchivedSession, setSessionArchived, setSessionDescription, setSessionPrompt, useAgents, useArchivedSessions, useConfiguredProviders, useDiscoverableWindows, useHarnesses, useRecentSessions, useSendMessage, useTabs, useTranscript } from '../useApi'

describe('mapTabInfo', () => {
  it('maps snake_case wire fields to the camelCase TabInfo shape', () => {
    const wire = {
      index: 4,
      kind: 'session:harness',
      label: 'claude-code-abc',
      status: 'exited',
      session_id: 'sess-9',
      ext_modified: true,
      stale: false,
      origin: 'discovered',
      attach_command: 'tmux attach -t canonical-4:win',
    }
    expect(mapTabInfo(wire)).toEqual({
      index: 4,
      kind: 'session:harness',
      label: 'claude-code-abc',
      status: 'exited',
      session_id: 'sess-9',
      extModified: true,
      stale: false,
      origin: 'discovered',
      attachCommand: 'tmux attach -t canonical-4:win',
    })
  })

  it('maps a null label (session-backed tab, no harness fallback)', () => {
    const wire = {
      index: 1,
      kind: 'session:provider',
      label: null,
      status: 'idle',
      session_id: 'sess-1',
    }
    expect(mapTabInfo(wire)).toEqual({
      index: 1,
      kind: 'session:provider',
      label: null,
      status: 'idle',
      session_id: 'sess-1',
      extModified: false,
      stale: false,
      origin: undefined,
      attachCommand: null,
    })
  })

  it('tolerates a Phase-1 wire object missing the new fields (back-compat)', () => {
    const wire = {
      index: 0,
      kind: 'shell:bash',
      label: 'bash',
      status: 'idle',
      session_id: null,
    }
    expect(mapTabInfo(wire)).toEqual({
      index: 0,
      kind: 'shell:bash',
      label: 'bash',
      status: 'idle',
      session_id: null,
      extModified: false,
      stale: false,
      origin: undefined,
      attachCommand: null,
    })
  })
})

describe('mapDiscoverableWindow', () => {
  it('maps the snake_case discovery wire row to the camelCase DiscoverableWindow shape', () => {
    const wire = {
      session: 'work',
      window_name: 'editor',
      window_index: 3,
      pane_pid: 4242,
    }
    expect(mapDiscoverableWindow(wire)).toEqual({
      session: 'work',
      windowName: 'editor',
      windowIndex: 3,
      panePid: 4242,
    })
  })

  it('maps a null pane_pid to a null panePid', () => {
    const wire = {
      session: 'work',
      window_name: 'editor',
      window_index: 0,
      pane_pid: null,
    }
    expect(mapDiscoverableWindow(wire)).toEqual({
      session: 'work',
      windowName: 'editor',
      windowIndex: 0,
      panePid: null,
    })
  })
})

describe('useDiscoverableWindows', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('starts with an empty list and does not fetch until scan() is called (on-demand, not polled)', () => {
    const { result } = renderHook(() => useDiscoverableWindows())
    expect(result.current.windows).toEqual([])
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })

  it('scan() POSTs /api/discovery/scan and maps the wire rows', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([
        { session: 'work', window_name: 'editor', window_index: 3, pane_pid: 4242 },
        { session: 'work', window_name: 'logs', window_index: 4, pane_pid: null },
      ]),
    })
    const { result } = renderHook(() => useDiscoverableWindows())
    await act(async () => { await result.current.scan() })
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/discovery/scan', { method: 'POST' })
    expect(result.current.windows).toEqual([
      { session: 'work', windowName: 'editor', windowIndex: 3, panePid: 4242 },
      { session: 'work', windowName: 'logs', windowIndex: 4, panePid: null },
    ])
  })

  it('scan() clears the list and sets error on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useDiscoverableWindows())
    await act(async () => { await result.current.scan() })
    expect(result.current.windows).toEqual([])
    expect(result.current.error).toBe(true)
  })

  it('scan() clears the list and sets error when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    const { result } = renderHook(() => useDiscoverableWindows())
    await act(async () => { await result.current.scan() })
    expect(result.current.windows).toEqual([])
    expect(result.current.error).toBe(true)
  })
})

describe('adoptWindow', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('POSTs /api/adopt with the session/window + consent_confirmed:true and returns the session id', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true, json: async () => ({ session_id: 'sess-1' }) })
    const result = await adoptWindow('work', 'editor')
    expect(result).toEqual({ ok: true, sessionId: 'sess-1' })
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/adopt')
    const init = call[1] as RequestInit
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({
      session: 'work',
      window: 'editor',
      consent_confirmed: true,
    })
  })

  it('returns sessionId:null when the server omits session_id', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true, json: async () => ({ adopted: true }) })
    expect(await adoptWindow('work', 'editor')).toEqual({ ok: true, sessionId: null })
  })

  it('returns ok:false on a non-ok response (e.g. 403 deny)', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false, status: 403 })
    expect(await adoptWindow('blocked', 'win')).toEqual({ ok: false, sessionId: null })
  })

  it('returns ok:false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await adoptWindow('work', 'editor')).toEqual({ ok: false, sessionId: null })
  })
})

describe('releaseHarness', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('POSTs /api/tabs/{index}/release', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    const result = await releaseHarness(2)
    expect(result).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/tabs/2/release', { method: 'POST' })
  })

  it('returns false on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await releaseHarness(1)).toBe(false)
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await releaseHarness(1)).toBe(false)
  })
})

describe('dismissTab', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('sends POST to /api/tabs/{index}/dismiss', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    const result = await dismissTab(5)
    expect(result).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/tabs/5/dismiss', { method: 'POST' })
  })

  it('returns false on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await dismissTab(1)).toBe(false)
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await dismissTab(1)).toBe(false)
  })
})

describe('acknowledgeTab', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('sends POST to /api/tabs/{index}/acknowledge', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    const result = await acknowledgeTab(6)
    expect(result).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/tabs/6/acknowledge', { method: 'POST' })
  })

  it('returns false on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await acknowledgeTab(2)).toBe(false)
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await acknowledgeTab(2)).toBe(false)
  })
})

describe('closeTab', () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('sends POST to /api/tabs/{index}/close', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ closed: true }),
    })

    const result = await closeTab(3)

    expect(result).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/tabs/3/close', {
      method: 'POST',
    })
  })

  it('returns false when the server responds with a non-ok status', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: false,
    })

    const result = await closeTab(0)
    expect(result).toBe(false)
  })

  it('returns false when fetch throws a network error', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(
      new Error('Network error'),
    )

    const result = await closeTab(1)
    expect(result).toBe(false)
  })
})

describe('resumeArchivedSession', () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    globalThis.fetch = vi.fn()
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('calls unarchive then createTab and returns the new tab', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce({ ok: true }) // unarchive
      .mockResolvedValueOnce({
        ok: true,
        json: () =>
          Promise.resolve({
            tab_index: 2,
            session_id: 'sess-abc',
            kind: 'provider',
          }),
      }) // createTab

    const result = await resumeArchivedSession('sess-abc')

    expect(result).not.toBeNull()
    expect(result!.tab_index).toBe(2)
    // Should have called unarchive first
    expect(globalThis.fetch).toHaveBeenCalledWith(
      '/api/sessions/sess-abc/unarchive',
      { method: 'POST' },
    )
  })

  it('returns null when unarchive fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: false,
    })

    const result = await resumeArchivedSession('sess-xyz')
    expect(result).toBeNull()
  })
})

describe('useSendMessage model body (U5)', () => {
  const originalFetch = globalThis.fetch

  beforeEach(() => {
    globalThis.fetch = vi.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({}) })
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it('includes the chosen model in the /send body (U5)', async () => {
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('sess-1', onComplete))
    await act(async () => {
      await result.current.send('hello', 'opus-4')
    })
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/sessions/sess-1/send')
    const body = JSON.parse((call[1] as RequestInit).body as string)
    expect(body).toEqual({ message: 'hello', model: 'opus-4' })
  })

  it('omits the model field when the chosen model is null/empty (U5, R2 fallback)', async () => {
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('sess-1', onComplete))
    await act(async () => {
      await result.current.send('hello', null)
    })
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    const body = JSON.parse((call[1] as RequestInit).body as string)
    expect(body).toEqual({ message: 'hello' })
    expect('model' in body).toBe(false)
  })

  it('omits the model field when no model argument is given (back-compat)', async () => {
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('sess-1', onComplete))
    await act(async () => {
      await result.current.send('hello')
    })
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    const body = JSON.parse((call[1] as RequestInit).body as string)
    expect(body).toEqual({ message: 'hello' })
  })
})

describe('useSendMessage guard + error handling', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch; vi.restoreAllMocks() })

  it('does nothing (no fetch, no onComplete) when there is no session id', async () => {
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage(null, onComplete))
    await act(async () => { await result.current.send('hi') })
    expect(globalThis.fetch).not.toHaveBeenCalled()
    expect(onComplete).not.toHaveBeenCalled()
  })

  it('logs and still calls onComplete on a non-ok response', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false, json: () => Promise.resolve({ error: 'bad' }) })
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('s', onComplete))
    await act(async () => { await result.current.send('hi') })
    expect(errSpy).toHaveBeenCalled()
    expect(onComplete).toHaveBeenCalled()
    expect(result.current.sending).toBe(false)
  })

  it('logs and still calls onComplete when fetch throws', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('s', onComplete))
    await act(async () => { await result.current.send('hi') })
    expect(errSpy).toHaveBeenCalled()
    expect(onComplete).toHaveBeenCalled()
  })
})

describe('setSessionDescription', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('PUTs the description (url-encoding the session id) and returns true', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    expect(await setSessionDescription('s 1', 'hello')).toBe(true)
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/sessions/s%201/description')
    const init = call[1] as RequestInit
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({ description: 'hello' })
  })

  it('returns false (clears via null) on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await setSessionDescription('s', null)).toBe(false)
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await setSessionDescription('s', 'x')).toBe(false)
  })
})

describe('setSessionArchived', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('POSTs /archive when archiving', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    expect(await setSessionArchived('s', true)).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/sessions/s/archive', { method: 'POST' })
  })

  it('POSTs /unarchive when unarchiving', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    expect(await setSessionArchived('s', false)).toBe(true)
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/sessions/s/unarchive', { method: 'POST' })
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await setSessionArchived('s', true)).toBe(false)
  })
})

describe('setSessionPrompt', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('PUTs the prompt and includes the name when provided', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    expect(await setSessionPrompt('s', 'do x', 'My Tab')).toBe(true)
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/sessions/s/prompt')
    const init = call[1] as RequestInit
    expect(init.method).toBe('PUT')
    expect(JSON.parse(init.body as string)).toEqual({ prompt: 'do x', name: 'My Tab' })
  })

  it('omits the name when not provided', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    await setSessionPrompt('s', 'do x')
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(JSON.parse((call[1] as RequestInit).body as string)).toEqual({ prompt: 'do x' })
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await setSessionPrompt('s', 'do x')).toBe(false)
  })
})

describe('createTab', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('POSTs a provider session tab to /api/tabs/new and returns the parsed response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 1, session_id: 's1', kind: 'session:provider' }),
    })
    const r = await createTab()
    expect(r).toEqual({ tab_index: 1, session_id: 's1', kind: 'session:provider' })
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/tabs/new')
    const init = call[1] as RequestInit
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body.kind.tag).toBe('session')
    expect(body.kind.session_kind).toEqual({ tag: 'provider', provider: 'anthropic', model: 'placeholder' })
  })

  it('includes the agent in the session_kind payload when given', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 2, session_id: 's2', kind: 'session:provider' }),
    })
    await createTab('researcher')
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    const body = JSON.parse((call[1] as RequestInit).body as string)
    expect(body.kind.session_kind.agent).toBe('researcher')
  })

  it('returns null on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await createTab()).toBeNull()
  })

  it('returns null when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await createTab()).toBeNull()
  })
})

describe('destroyHarness', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('POSTs /destroy with confirm_adopted and returns true', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: true })
    expect(await destroyHarness(3, true)).toBe(true)
    const call = (globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls[0]!
    expect(call[0]).toBe('/api/tabs/3/destroy')
    const init = call[1] as RequestInit
    expect(init.method).toBe('POST')
    expect(JSON.parse(init.body as string)).toEqual({ confirm_adopted: true })
  })

  it('returns false on a non-ok response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await destroyHarness(1, false)).toBe(false)
  })

  it('returns false when fetch throws', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    expect(await destroyHarness(1, true)).toBe(false)
  })
})

describe('createSession (deprecated wrapper)', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('synthesises a SessionInfo from the new-tab response', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 2, session_id: 's9', kind: 'session:provider' }),
    })
    const s = await createSession('agentX')
    expect(s).not.toBeNull()
    expect(s!.id).toBe('s9')
    expect(s!.agent).toBe('agentX')
    expect(s!.runtime).toBe('session:provider')
  })

  it('returns null when the created tab has no session_id (raw shell)', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 1, session_id: null, kind: 'shell:bash' }),
    })
    expect(await createSession()).toBeNull()
  })

  it('returns null when tab creation fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await createSession()).toBeNull()
  })
})

describe('fetchProviderModels', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('returns the provider model list', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(['opus-4', 'sonnet-4']),
    })
    expect(await fetchProviderModels('anthropic')).toEqual(['opus-4', 'sonnet-4'])
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/providers/anthropic/models')
  })

  it('returns [] when the response is not an array', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ not: 'an array' }),
    })
    expect(await fetchProviderModels('anthropic')).toEqual([])
  })

  it('returns [] when the call fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    expect(await fetchProviderModels('bogus')).toEqual([])
  })
})

describe('useHarnesses', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('polls /api/harnesses on mount and stores the result', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ name: 'h1', activity: 'idle' }]),
    })
    const { result } = renderHook(() => useHarnesses())
    await waitFor(() => expect(result.current.harnesses).toHaveLength(1))
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/harnesses')
    expect(result.current.error).toBe(false)
  })

  it('sets error when the poll fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useHarnesses())
    await waitFor(() => expect(result.current.error).toBe(true))
  })

  it('sets error when fetch throws (fetchJson swallows and returns null)', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error('net'))
    const { result } = renderHook(() => useHarnesses())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

describe('useRecentSessions', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('polls /api/sessions/recent on mount', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ id: 'r1' }]),
    })
    const { result } = renderHook(() => useRecentSessions())
    await waitFor(() => expect(result.current.sessions).toHaveLength(1))
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/sessions/recent')
  })

  it('sets error when the poll fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useRecentSessions())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

describe('useArchivedSessions', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('polls /api/sessions/archived on mount', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ id: 'a1' }]),
    })
    const { result } = renderHook(() => useArchivedSessions())
    await waitFor(() => expect(result.current.sessions).toHaveLength(1))
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/sessions/archived')
  })

  it('sets error when the poll fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useArchivedSessions())
    await waitFor(() => expect(result.current.error).toBe(true))
  })
})

describe('useTabs', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('polls /api/tabs and maps the wire rows to camelCase', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([
        { index: 0, kind: 'shell:bash', label: 'bash', status: 'idle', session_id: null },
      ]),
    })
    const { result } = renderHook(() => useTabs())
    await waitFor(() => expect(result.current.tabs).toHaveLength(1))
    expect(result.current.tabs[0]!.extModified).toBe(false)
    expect(result.current.tabs[0]!.attachCommand).toBeNull()
  })

  it('sets error when the poll fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useTabs())
    await waitFor(() => expect(result.current.error).toBe(true))
  })

  it('refresh() forces an immediate re-poll', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([]),
    })
    const { result } = renderHook(() => useTabs())
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1))
    await act(async () => { await result.current.refresh() })
    expect((globalThis.fetch as ReturnType<typeof vi.fn>).mock.calls.length).toBeGreaterThanOrEqual(2)
  })
})

describe('useTranscript', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('returns an empty list and does not fetch when sessionId is null', () => {
    const { result } = renderHook(() => useTranscript(null))
    expect(result.current.entries).toEqual([])
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })

  it('fetches the transcript for a session id (url-encoded)', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ id: 'e1' }]),
    })
    const { result } = renderHook(() => useTranscript('sess 1'))
    await waitFor(() => expect(result.current.entries).toHaveLength(1))
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/sessions/sess%201/transcript')
    expect(result.current.loading).toBe(false)
  })

  it('falls back to an empty list when the fetch fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useTranscript('s'))
    await waitFor(() => expect(result.current.loading).toBe(false))
    expect(result.current.entries).toEqual([])
  })

  it('re-fetches when refresh() is called', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([]),
    })
    const { result } = renderHook(() => useTranscript('s'))
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(1))
    act(() => { result.current.refresh() })
    await waitFor(() => expect(globalThis.fetch).toHaveBeenCalledTimes(2))
  })
})

describe('useAgents', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('loads the agent list from /api/agents', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ name: 'researcher', isDefault: true }]),
    })
    const { result } = renderHook(() => useAgents())
    await waitFor(() => expect(result.current.agents).toHaveLength(1))
    expect(globalThis.fetch).toHaveBeenCalledWith('/api/agents')
  })
})

describe('useConfiguredProviders', () => {
  const originalFetch = globalThis.fetch
  beforeEach(() => { globalThis.fetch = vi.fn() })
  afterEach(() => { globalThis.fetch = originalFetch })

  it('loads providers and flips loaded to true', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
      ok: true,
      json: () => Promise.resolve([{ name: 'anthropic', isDefault: true }]),
    })
    const { result } = renderHook(() => useConfiguredProviders())
    await waitFor(() => expect(result.current.loaded).toBe(true))
    expect(result.current.providers).toHaveLength(1)
  })

  it('still flips loaded to true when the call fails', async () => {
    ;(globalThis.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false })
    const { result } = renderHook(() => useConfiguredProviders())
    await waitFor(() => expect(result.current.loaded).toBe(true))
    expect(result.current.providers).toEqual([])
  })
})

describe('useSendMessage send result body', () => {
  const originalFetch = globalThis.fetch
  afterEach(() => { globalThis.fetch = originalFetch })

  it('resolves to the parsed {response, kind:"slash"} body on a 200', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ response: '/help output here', kind: 'slash' }),
    })
    const onComplete = vi.fn()
    const { result } = renderHook(() => useSendMessage('sess-1', onComplete))
    let resolved: unknown
    await act(async () => {
      resolved = await result.current.send('/help')
    })
    expect(resolved).toEqual({ response: '/help output here', kind: 'slash' })
    expect(onComplete).toHaveBeenCalledTimes(1)
  })

  it('resolves to the parsed {response, kind:"assistant"} body on a 200', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ response: 'hi there', kind: 'assistant' }),
    })
    const { result } = renderHook(() => useSendMessage('sess-1', vi.fn()))
    let resolved: unknown
    await act(async () => {
      resolved = await result.current.send('hello')
    })
    expect(resolved).toEqual({ response: 'hi there', kind: 'assistant' })
  })

  it('resolves to null on a non-ok response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue({
      ok: false,
      json: () => Promise.resolve({ error: 'boom' }),
    })
    const { result } = renderHook(() => useSendMessage('sess-1', vi.fn()))
    let resolved: unknown = 'unset'
    await act(async () => {
      resolved = await result.current.send('hello')
    })
    expect(resolved).toBeNull()
  })

  it('resolves to null when the fetch throws', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error('net'))
    const { result } = renderHook(() => useSendMessage('sess-1', vi.fn()))
    let resolved: unknown = 'unset'
    await act(async () => {
      resolved = await result.current.send('hello')
    })
    expect(resolved).toBeNull()
  })

  it('resolves to null when there is no session id', async () => {
    globalThis.fetch = vi.fn()
    const { result } = renderHook(() => useSendMessage(null, vi.fn()))
    let resolved: unknown = 'unset'
    await act(async () => {
      resolved = await result.current.send('hello')
    })
    expect(resolved).toBeNull()
    expect(globalThis.fetch).not.toHaveBeenCalled()
  })
})
