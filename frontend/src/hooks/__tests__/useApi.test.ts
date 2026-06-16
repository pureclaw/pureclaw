import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { acknowledgeTab, adoptWindow, closeTab, dismissTab, mapDiscoverableWindow, mapTabInfo, releaseHarness, resumeArchivedSession, useDiscoverableWindows, useSendMessage } from '../useApi'

describe('mapTabInfo', () => {
  it('maps snake_case wire fields to the camelCase TabInfo shape', () => {
    const wire = {
      index: 4,
      kind: 'session:harness',
      name: 'claude-code-abc',
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
      name: 'claude-code-abc',
      status: 'exited',
      session_id: 'sess-9',
      extModified: true,
      stale: false,
      origin: 'discovered',
      attachCommand: 'tmux attach -t canonical-4:win',
    })
  })

  it('tolerates a Phase-1 wire object missing the new fields (back-compat)', () => {
    const wire = {
      index: 0,
      kind: 'shell:bash',
      name: 'bash',
      status: 'idle',
      session_id: null,
    }
    expect(mapTabInfo(wire)).toEqual({
      index: 0,
      kind: 'shell:bash',
      name: 'bash',
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
