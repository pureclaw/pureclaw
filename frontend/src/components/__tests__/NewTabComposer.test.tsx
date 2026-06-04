import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { useState } from 'react'
import { NewTabComposer } from '../NewTabComposer'
import { useNewTabSpec } from '../../hooks/useNewTabSpec'

// Default mock: provides anthropic + openai providers, one model each,
// one default agent.
function defaultMockFetch() {
  return vi.fn().mockImplementation((url: string) => {
    if (url === '/api/providers') {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve([
          { name: 'anthropic', isDefault: true },
          { name: 'openai',    isDefault: false },
        ]),
      })
    }
    if (url === '/api/providers/anthropic/models') {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve(['claude-sonnet-4-5']),
      })
    }
    if (url === '/api/providers/openai/models') {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve(['gpt-4o']),
      })
    }
    if (url === '/api/agents') {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve([{ name: 'coder', isDefault: true }]),
      })
    }
    return Promise.resolve({ ok: true, json: () => Promise.resolve({}) })
  })
}

/**
 * Test harness that mirrors how App wires the composer + bottom input:
 * the hook owns the state, the panel renders the config fields, and a
 * separate "Send" button reads spec.validationError to decide whether
 * to disable, then calls spec.buildBody() on click.
 */
function ComposerHarness({ onSubmit }: { onSubmit: (body: unknown, message: string) => void }) {
  const spec = useNewTabSpec()
  const [message, setMessage] = useState('')
  const disabled = spec.validationError !== null || !message.trim()
  return (
    <div>
      <NewTabComposer spec={spec} />
      <textarea
        aria-label="Bottom message input"
        value={message}
        onChange={(e) => setMessage(e.target.value)}
      />
      <button
        type="button"
        aria-label="Bottom send button"
        onClick={() => onSubmit(spec.buildBody(), message)}
        disabled={disabled}
      >
        Send
      </button>
    </div>
  )
}

describe('NewTabComposer (presentation) + useNewTabSpec (state)', () => {
  let onSubmit: Mock

  beforeEach(() => {
    onSubmit = vi.fn()
    vi.restoreAllMocks()
  })

  it('the inline panel has no message input — that lives in the parent', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)
    // The composer should NOT render anything labelled "First message"
    // anymore — the parent owns the message input.
    expect(screen.queryByLabelText('First message')).not.toBeInTheDocument()
  })

  it('renders kind pills and provider config by default', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    expect(screen.getByRole('radio', { name: 'AI Provider' })).toHaveAttribute('aria-checked', 'true')
    expect(screen.getByRole('radio', { name: 'New Harness' })).toHaveAttribute('aria-checked', 'false')
    // Raw Shell has been removed as a top-level option — the backend
    // selector now lives inside the AI Provider section.
    expect(screen.queryByRole('radio', { name: 'Raw Shell' })).not.toBeInTheDocument()

    await waitFor(() => {
      expect((screen.getByLabelText('Provider') as HTMLSelectElement).value).toBe('anthropic')
    })
    await waitFor(() => {
      expect((screen.getByLabelText('Model') as HTMLSelectElement).value).toBe('claude-sonnet-4-5')
    })
    await waitFor(() => {
      expect((screen.getByLabelText('Agent') as HTMLSelectElement).value).toBe('coder')
    })
  })

  it('switching to Harness shows harness fields and hides provider fields', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))

    expect(screen.getByLabelText('Flavour')).toBeInTheDocument()
    expect(screen.getByLabelText('Backend')).toBeInTheDocument()
    expect(screen.queryByLabelText('Provider')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Model')).not.toBeInTheDocument()
  })

  it('AI Provider config exposes a Tool Backend selector (SSH / container / tmux / local)', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    const backend = await screen.findByLabelText('Tool Backend') as HTMLSelectElement
    expect(backend.value).toBe('local')

    // Picking SSH reveals the host/port sub-fields (shared with harness).
    fireEvent.change(backend, { target: { value: 'ssh' } })
    expect(screen.getByLabelText('Host')).toBeInTheDocument()
    expect(screen.getByLabelText('Port')).toBeInTheDocument()
  })

  it('defaults yield a valid spec — bottom send enables as soon as a message is typed', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    await waitFor(() => {
      expect((screen.getByLabelText('Model') as HTMLSelectElement).value).toBe('claude-sonnet-4-5')
    })

    const sendButton = screen.getByLabelText('Bottom send button') as HTMLButtonElement
    expect(sendButton.disabled).toBe(true)  // still need a message

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect(sendButton.disabled).toBe(false)
  })

  it('"Custom…" with no value disables the bottom send and shows a validation hint', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    await waitFor(() => {
      expect((screen.getByLabelText('Model') as HTMLSelectElement).value).toBe('claude-sonnet-4-5')
    })

    // Type a message first — would normally enable the button.
    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(false)

    // Opt into a known-invalid state.
    fireEvent.change(screen.getByLabelText('Model'), { target: { value: '__custom__' } })

    expect(screen.getByTestId('composer-validation-error')).toBeInTheDocument()
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(true)

    // Filling in the custom model id re-validates and re-enables.
    fireEvent.change(screen.getByLabelText('Custom Model'), { target: { value: 'claude-future-99' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(false)
  })

  it('SSH backend with no host disables the bottom send', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'ssh' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Host is required/i)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'user@host' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(false)
  })

  it('custom harness flavour with no binary disables the bottom send', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Flavour'), { target: { value: 'custom' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(true)
    expect(screen.getByText(/Binary name is required/i)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText('Binary Name'), { target: { value: 'my-tool' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(false)
  })

  it('container backend with no target disables the bottom send', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'container' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(true)

    fireEvent.change(screen.getByLabelText('Target'), { target: { value: 'mycontainer' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(false)
  })

  it('buildBody produces correct provider JSON', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    await waitFor(() => {
      expect((screen.getByLabelText('Model') as HTMLSelectElement).value).toBe('claude-sonnet-4-5')
    })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hello' } })
    fireEvent.click(screen.getByLabelText('Bottom send button'))

    expect(onSubmit).toHaveBeenCalledWith(
      {
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'provider',
            provider: 'anthropic',
            model: 'claude-sonnet-4-5',
            agent: 'coder',
            backend: { tag: 'local' },
          },
        },
      },
      'hello',
    )
  })

  it('AI Provider buildBody includes the chosen tool backend', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    await waitFor(() => {
      expect((screen.getByLabelText('Model') as HTMLSelectElement).value).toBe('claude-sonnet-4-5')
    })

    fireEvent.change(screen.getByLabelText('Tool Backend'), { target: { value: 'ssh' } })
    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'user@host' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    fireEvent.click(screen.getByLabelText('Bottom send button'))

    expect(onSubmit).toHaveBeenCalledWith(
      {
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'provider',
            provider: 'anthropic',
            model: 'claude-sonnet-4-5',
            agent: 'coder',
            backend: { tag: 'ssh', host: 'user@host' },
          },
        },
      },
      'hi',
    )
  })

  it('tmux backend has a Session Name field but no Window field (window is auto-assigned)', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'tmux' } })

    // Session Name is still there...
    expect(screen.getByLabelText('Session Name')).toBeInTheDocument()
    // ...but the Window input has been removed — the backend auto-assigns
    // a canonical window name, so the user never picks one.
    expect(screen.queryByLabelText('Window')).not.toBeInTheDocument()
  })

  it('tmux harness buildBody always carries window:"" so the backend decode succeeds', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'tmux' } })
    fireEvent.change(screen.getByLabelText('Session Name'), { target: { value: 'main' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    fireEvent.click(screen.getByLabelText('Bottom send button'))

    expect(onSubmit).toHaveBeenCalledWith(
      {
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'harness',
            flavour: 'claude-code',
            // window is emitted unconditionally for tmux (auto-assigned
            // server-side, ignored for placement) so the required
            // `o .: "window"` backend decode still succeeds.
            backend: { tag: 'tmux', session: 'main', window: '' },
            args: [],
          },
        },
      },
      'hi',
    )
  })

  it('tmux harness buildBody carries window:"" even with no session typed', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'tmux' } })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    fireEvent.click(screen.getByLabelText('Bottom send button'))

    expect(onSubmit).toHaveBeenCalledWith(
      {
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'harness',
            flavour: 'claude-code',
            backend: { tag: 'tmux', window: '' },
            args: [],
          },
        },
      },
      'hi',
    )
  })

  it('New Harness buildBody sends the working directory as `cwd` (the backend HarnessSpec field name)', async () => {
    vi.stubGlobal('fetch', defaultMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    fireEvent.click(screen.getByRole('radio', { name: 'New Harness' }))
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'tmux' } })
    fireEvent.change(screen.getByLabelText('Session Name'), { target: { value: 'main' } })
    fireEvent.change(screen.getByLabelText('Working Directory'), {
      target: { value: '/home/me/project' },
    })

    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    fireEvent.click(screen.getByLabelText('Bottom send button'))

    expect(onSubmit).toHaveBeenCalledWith(
      {
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'harness',
            flavour: 'claude-code',
            // The backend's FromJSON HarnessSpec decodes `cwd` (Session/Kind.hs);
            // `working_dir` would be silently dropped to Nothing and the harness
            // would start in the default directory.
            cwd: '/home/me/project',
            backend: { tag: 'tmux', session: 'main', window: '' },
            args: [],
          },
        },
      },
      'hi',
    )
  })

  it('shows "no providers configured" hint when /api/providers is empty', async () => {
    const mockFetch = vi.fn().mockImplementation((url: string) => {
      if (url === '/api/providers') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<ComposerHarness onSubmit={onSubmit} />)
    await waitFor(() => {
      expect(screen.getByTestId('composer-validation-error')).toHaveTextContent(/no providers configured/i)
    })
    expect((screen.getByLabelText('Provider') as HTMLSelectElement).disabled).toBe(true)

    // And bottom send is disabled even with a message typed.
    fireEvent.change(screen.getByLabelText('Bottom message input'), { target: { value: 'hi' } })
    expect((screen.getByLabelText('Bottom send button') as HTMLButtonElement).disabled).toBe(true)
  })

  it('defaults the Provider dropdown to the entry marked isDefault by the backend', async () => {
    const mockFetch = vi.fn().mockImplementation((url: string) => {
      if (url === '/api/providers') {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve([
            { name: 'anthropic', isDefault: false },
            { name: 'openai',    isDefault: true  },
            { name: 'ollama',    isDefault: false },
          ]),
        })
      }
      if (url === '/api/providers/openai/models') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(['gpt-4o']) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<ComposerHarness onSubmit={onSubmit} />)

    // Even though anthropic appears first in the list, openai is the
    // configured default and that's what the dropdown lands on.
    await waitFor(() => {
      expect((screen.getByLabelText('Provider') as HTMLSelectElement).value).toBe('openai')
    })
    // The option label is annotated "(default)".
    expect(screen.getByRole('option', { name: /OpenAI \(default\)/ })).toBeInTheDocument()
  })

  it('falls back to the first configured provider when none is marked default', async () => {
    const mockFetch = vi.fn().mockImplementation((url: string) => {
      if (url === '/api/providers') {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve([
            { name: 'openai', isDefault: false },
            { name: 'ollama', isDefault: false },
          ]),
        })
      }
      if (url === '/api/providers/openai/models') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(['gpt-4o']) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<ComposerHarness onSubmit={onSubmit} />)
    await waitFor(() => {
      expect((screen.getByLabelText('Provider') as HTMLSelectElement).value).toBe('openai')
    })
  })

  it('only lists configured providers in the Provider dropdown', async () => {
    const mockFetch = vi.fn().mockImplementation((url: string) => {
      if (url === '/api/providers') {
        return Promise.resolve({
          ok: true,
          json: () => Promise.resolve([
            { name: 'openai', isDefault: false },
            { name: 'ollama', isDefault: false },
          ]),
        })
      }
      if (url === '/api/providers/openai/models') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(['gpt-4o']) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<ComposerHarness onSubmit={onSubmit} />)

    await waitFor(() => {
      expect((screen.getByLabelText('Provider') as HTMLSelectElement).value).toBe('openai')
    })
    expect(screen.getByRole('option', { name: 'OpenAI' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Ollama' })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Anthropic' })).not.toBeInTheDocument()
  })

  // ── Existing Harness (attach / adoption) section ───────────────────

  // Default mock that also answers the discovery scan with two windows.
  function attachMockFetch(windows: Array<{ session: string; window_name: string; window_index: number; pane_pid: number | null }> = [
    { session: 'work', window_name: 'claude', window_index: 0, pane_pid: 111 },
    { session: 'side', window_name: 'codex', window_index: 1, pane_pid: 222 },
  ]) {
    return vi.fn().mockImplementation((url: string, _init?: RequestInit) => {
      if (url === '/api/discovery/scan') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(windows) })
      }
      if (url === '/api/providers') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve([{ name: 'anthropic', isDefault: true }]) })
      }
      if (url === '/api/providers/anthropic/models') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(['claude-sonnet-4-5']) })
      }
      if (url === '/api/agents') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve([{ name: 'coder', isDefault: true }]) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve({}) })
    })
  }

  it('W3.1: the kind selector shows 3 options — AI Provider, New Harness, Existing Harness', async () => {
    vi.stubGlobal('fetch', attachMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)

    expect(screen.getByRole('radio', { name: 'AI Provider' })).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: 'New Harness' })).toBeInTheDocument()
    expect(screen.getByRole('radio', { name: 'Existing Harness' })).toBeInTheDocument()
  })

  it('W3.2: selecting "Existing Harness" auto-loads the detected-sessions dropdown (scans once)', async () => {
    const mockFetch = attachMockFetch()
    vi.stubGlobal('fetch', mockFetch)
    render(<ComposerHarness onSubmit={onSubmit} />)

    // No scan before the section is shown.
    expect(mockFetch.mock.calls.filter((c) => c[0] === '/api/discovery/scan')).toHaveLength(0)

    fireEvent.click(screen.getByRole('radio', { name: 'Existing Harness' }))

    // Auto-loads: scan is POSTed exactly once on show.
    await waitFor(() => {
      expect(mockFetch.mock.calls.filter((c) => c[0] === '/api/discovery/scan')).toHaveLength(1)
    })
    const scanCall = mockFetch.mock.calls.find((c) => c[0] === '/api/discovery/scan')!
    expect((scanCall[1] as RequestInit).method).toBe('POST')

    // Options reflect the returned windows (session:windowName).
    const select = await screen.findByLabelText('Detected Session') as HTMLSelectElement
    await waitFor(() => {
      expect(screen.getByRole('option', { name: 'work:claude' })).toBeInTheDocument()
    })
    expect(screen.getByRole('option', { name: 'side:codex' })).toBeInTheDocument()
    expect(select).toBeInTheDocument()
  })

  it('W3.3: a manual-entry fallback lets the user specify a session/window not in the dropdown', async () => {
    vi.stubGlobal('fetch', attachMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)
    fireEvent.click(screen.getByRole('radio', { name: 'Existing Harness' }))

    // Wait for the auto-load so the dropdown (and the manual toggle) appear.
    const toggle = await screen.findByLabelText('Enter manually')
    // Reveal the manual fields.
    fireEvent.click(toggle)
    expect(screen.getByLabelText('Session')).toBeInTheDocument()
    expect(screen.getByLabelText('Window')).toBeInTheDocument()
  })

  it('W3.5: a consent note naming the trust consequence is shown in the Existing-Harness section', async () => {
    vi.stubGlobal('fetch', attachMockFetch())
    render(<ComposerHarness onSubmit={onSubmit} />)
    fireEvent.click(screen.getByRole('radio', { name: 'Existing Harness' }))

    expect(screen.getByText(/PureClaw will manage this window and capture its output/i)).toBeInTheDocument()
  })

  it('Existing Harness with empty scan results shows a hint and falls back to manual entry', async () => {
    vi.stubGlobal('fetch', attachMockFetch([]))
    render(<ComposerHarness onSubmit={onSubmit} />)
    fireEvent.click(screen.getByRole('radio', { name: 'Existing Harness' }))

    await waitFor(() => {
      expect(screen.getByText(/no .* sessions detected/i)).toBeInTheDocument()
    })
    // Manual fields are available directly (no dropdown to pick from).
    expect(screen.getByLabelText('Session')).toBeInTheDocument()
  })

  it('Existing Harness surfaces a scan error and still offers manual entry', async () => {
    const mockFetch = vi.fn().mockImplementation((url: string) => {
      if (url === '/api/discovery/scan') {
        return Promise.resolve({ ok: false, json: () => Promise.resolve([]) })
      }
      if (url === '/api/providers') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve([{ name: 'anthropic', isDefault: true }]) })
      }
      if (url === '/api/providers/anthropic/models') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(['claude-sonnet-4-5']) })
      }
      return Promise.resolve({ ok: true, json: () => Promise.resolve([]) })
    })
    vi.stubGlobal('fetch', mockFetch)
    render(<ComposerHarness onSubmit={onSubmit} />)
    fireEvent.click(screen.getByRole('radio', { name: 'Existing Harness' }))

    await waitFor(() => {
      expect(screen.getByText(/could not scan/i)).toBeInTheDocument()
    })
    expect(screen.getByLabelText('Session')).toBeInTheDocument()
  })
})
