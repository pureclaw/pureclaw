import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { closeTab, resumeArchivedSession, useSendMessage } from '../useApi'

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
