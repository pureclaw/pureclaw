import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { KindPickerModal } from '../KindPickerModal'

describe('KindPickerModal', () => {
  let onClose: Mock
  let onCreated: Mock

  beforeEach(() => {
    onClose = vi.fn()
    onCreated = vi.fn()
    // Reset fetch mock before each test
    vi.restoreAllMocks()
  })

  // ── Test 1: Modal renders visible content ───────────────────────────
  it('renders visible content when open', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    expect(screen.getByText('New Tab')).toBeInTheDocument()
  })

  it('does not render content when closed', () => {
    render(<KindPickerModal open={false} onClose={onClose} onCreated={onCreated} />)
    expect(screen.queryByText('New Tab')).not.toBeInTheDocument()
  })

  // ── Test 2: Step 1 shows three category buttons ─────────────────────
  it('shows three category buttons in step 1', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    expect(screen.getByText('AI Provider')).toBeInTheDocument()
    expect(screen.getByText('AI Harness')).toBeInTheDocument()
    expect(screen.getByText('Raw Shell')).toBeInTheDocument()
  })

  it('shows category descriptions', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    expect(screen.getByText(/Direct API call/)).toBeInTheDocument()
    expect(screen.getByText(/External AI CLI tool/)).toBeInTheDocument()
    expect(screen.getByText(/Terminal session/)).toBeInTheDocument()
  })

  // ── Test 3: Clicking "AI Provider" shows provider form (step 2) ─────
  it('shows provider form when "AI Provider" is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))

    // Should show provider form fields
    expect(screen.getByLabelText('Provider')).toBeInTheDocument()
    expect(screen.getByLabelText('Model')).toBeInTheDocument()
    expect(screen.getByLabelText('Agent')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument()
  })

  it('shows provider form with correct defaults', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))

    const providerSelect = screen.getByLabelText('Provider') as HTMLSelectElement
    expect(providerSelect.value).toBe('anthropic')

    const modelInput = screen.getByLabelText('Model') as HTMLInputElement
    expect(modelInput.value).toBe('claude-sonnet-4-20250514')

    const agentInput = screen.getByLabelText('Agent') as HTMLInputElement
    expect(agentInput.value).toBe('')
  })

  // ── Test 4: Clicking "Back" returns to step 1 ──────────────────────
  it('returns to step 1 when "Back" is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))

    // Should be on step 2
    expect(screen.getByLabelText('Provider')).toBeInTheDocument()

    // Click back
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))

    // Should be back on step 1
    expect(screen.getByText('AI Provider')).toBeInTheDocument()
    expect(screen.getByText('AI Harness')).toBeInTheDocument()
    expect(screen.getByText('Raw Shell')).toBeInTheDocument()
  })

  // ── Test 5: Provider form submission produces correct JSON body ──────
  it('submits provider form with correct JSON body', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 0, session_id: 'sess-1', kind: 'session:provider' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))

    // Fill in custom model
    const modelInput = screen.getByLabelText('Model') as HTMLInputElement
    fireEvent.change(modelInput, { target: { value: 'gpt-4o' } })

    // Change provider
    const providerSelect = screen.getByLabelText('Provider') as HTMLSelectElement
    fireEvent.change(providerSelect, { target: { value: 'openai' } })

    // Submit
    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(mockFetch).toHaveBeenCalledWith('/api/tabs/new', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          kind: {
            tag: 'session',
            session_kind: {
              tag: 'provider',
              provider: 'openai',
              model: 'gpt-4o',
            },
          },
        }),
      })
    })

    await waitFor(() => {
      expect(onCreated).toHaveBeenCalledWith({ tab_index: 0, session_id: 'sess-1', kind: 'session:provider' })
    })
  })

  it('submits provider form with agent when specified', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 0, session_id: 'sess-1', kind: 'session:provider' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))

    fireEvent.change(screen.getByLabelText('Agent'), { target: { value: 'my-agent' } })
    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      const call = mockFetch.mock.calls[0]!
      const body = JSON.parse(call[1].body)
      expect(body.kind.session_kind.agent).toBe('my-agent')
    })
  })

  // ── Test 6: Harness form shows backend-specific sub-fields ──────────
  it('shows harness form when "AI Harness" is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    expect(screen.getByLabelText('Flavour')).toBeInTheDocument()
    expect(screen.getByLabelText('Backend')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument()
  })

  it('shows tmux sub-fields when tmux backend is selected in harness form', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    const backendSelect = screen.getByLabelText('Backend') as HTMLSelectElement
    fireEvent.change(backendSelect, { target: { value: 'tmux' } })

    expect(screen.getByLabelText('Session Name')).toBeInTheDocument()
    expect(screen.getByLabelText('Window')).toBeInTheDocument()
  })

  it('shows ssh sub-fields when ssh backend is selected in harness form', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    const backendSelect = screen.getByLabelText('Backend') as HTMLSelectElement
    fireEvent.change(backendSelect, { target: { value: 'ssh' } })

    expect(screen.getByLabelText('Host')).toBeInTheDocument()
    expect(screen.getByLabelText('Port')).toBeInTheDocument()
  })

  it('shows container sub-fields when container backend is selected in harness form', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    const backendSelect = screen.getByLabelText('Backend') as HTMLSelectElement
    fireEvent.change(backendSelect, { target: { value: 'container' } })

    expect(screen.getByLabelText('Engine')).toBeInTheDocument()
    expect(screen.getByLabelText('Target')).toBeInTheDocument()
  })

  it('shows custom binary input when custom flavour is selected', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    const flavourSelect = screen.getByLabelText('Flavour') as HTMLSelectElement
    fireEvent.change(flavourSelect, { target: { value: 'custom' } })

    expect(screen.getByLabelText('Binary Name')).toBeInTheDocument()
  })

  it('submits harness form with correct JSON body', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 1, session_id: 'sess-2', kind: 'session:harness' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    // Select tmux backend
    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'tmux' } })
    fireEvent.change(screen.getByLabelText('Session Name'), { target: { value: 'my-session' } })
    fireEvent.change(screen.getByLabelText('Window'), { target: { value: 'main' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      const call = mockFetch.mock.calls[0]!
      const body = JSON.parse(call[1].body)
      expect(body).toEqual({
        kind: {
          tag: 'session',
          session_kind: {
            tag: 'harness',
            flavour: 'claude-code',
            backend: {
              tag: 'tmux',
              session: 'my-session',
              window: 'main',
            },
            args: [],
          },
        },
      })
    })
  })

  // ── Raw Shell form ──────────────────────────────────────────────────
  it('shows raw shell form when "Raw Shell" is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('Raw Shell'))

    expect(screen.getByLabelText('Backend')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument()
  })

  it('submits raw shell form with correct JSON body for local backend', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 2, session_id: null, kind: 'shell:local' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('Raw Shell'))

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(mockFetch).toHaveBeenCalledWith('/api/tabs/new', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          kind: {
            tag: 'raw_shell',
            backend: { tag: 'local' },
          },
        }),
      })
    })
  })

  it('submits raw shell form with ssh backend fields', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 3, session_id: null, kind: 'shell:ssh' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('Raw Shell'))

    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'ssh' } })
    fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'user@example.com' } })
    fireEvent.change(screen.getByLabelText('Port'), { target: { value: '2222' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      const call = mockFetch.mock.calls[0]!
      const body = JSON.parse(call[1].body)
      expect(body).toEqual({
        kind: {
          tag: 'raw_shell',
          backend: {
            tag: 'ssh',
            host: 'user@example.com',
            port: 2222,
          },
        },
      })
    })
  })

  // ── Test 7: Validation ──────────────────────────────────────────────
  it('shows validation error when submitting harness form with custom flavour but empty binary name', async () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    fireEvent.change(screen.getByLabelText('Flavour'), { target: { value: 'custom' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(screen.getByText(/binary name is required/i)).toBeInTheDocument()
    })
  })

  it('shows validation error when submitting raw shell with ssh but empty host', async () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('Raw Shell'))

    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'ssh' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(screen.getByText(/host is required/i)).toBeInTheDocument()
    })
  })

  // ── Close/cancel ────────────────────────────────────────────────────
  it('calls onClose when close button is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByRole('button', { name: /close/i }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('calls onClose when overlay is clicked', () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByTestId('modal-overlay'))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // ── API error handling ──────────────────────────────────────────────
  it('shows error message when API call fails', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: () => Promise.resolve({ error: 'Internal server error' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))
    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(screen.getByText(/failed to create tab/i)).toBeInTheDocument()
    })
  })

  it('shows error message when fetch throws', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Network error'))
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))
    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(screen.getByText(/failed to create tab/i)).toBeInTheDocument()
    })
  })

  // ── Modal resets state on re-open ───────────────────────────────────
  it('resets to step 1 when modal is re-opened', () => {
    const { rerender } = render(
      <KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />,
    )
    fireEvent.click(screen.getByText('AI Provider'))
    expect(screen.getByLabelText('Provider')).toBeInTheDocument()

    // Close and re-open
    rerender(<KindPickerModal open={false} onClose={onClose} onCreated={onCreated} />)
    rerender(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)

    // Should be back at step 1
    expect(screen.getByText('AI Provider')).toBeInTheDocument()
    expect(screen.getByText('AI Harness')).toBeInTheDocument()
    expect(screen.getByText('Raw Shell')).toBeInTheDocument()
  })

  it('closes modal on successful submission', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 0, session_id: 'sess-1', kind: 'session:provider' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Provider'))
    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(onClose).toHaveBeenCalledTimes(1)
    })
  })

  // ── Harness extra args and working directory ────────────────────────
  it('includes working directory and extra args in harness submission', async () => {
    const mockFetch = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ tab_index: 1, session_id: 'sess-2', kind: 'session:harness' }),
    })
    vi.stubGlobal('fetch', mockFetch)

    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    fireEvent.change(screen.getByLabelText('Working Directory'), { target: { value: '/home/user/project' } })
    fireEvent.change(screen.getByLabelText('Extra Args'), { target: { value: '--verbose --debug' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      const call = mockFetch.mock.calls[0]!
      const body = JSON.parse(call[1].body)
      expect(body.kind.session_kind.working_dir).toBe('/home/user/project')
      expect(body.kind.session_kind.args).toEqual(['--verbose', '--debug'])
    })
  })

  // ── Container backend validation ────────────────────────────────────
  it('shows validation error for container backend with empty target', async () => {
    render(<KindPickerModal open={true} onClose={onClose} onCreated={onCreated} />)
    fireEvent.click(screen.getByText('AI Harness'))

    fireEvent.change(screen.getByLabelText('Backend'), { target: { value: 'container' } })

    fireEvent.click(screen.getByRole('button', { name: 'Create' }))

    await waitFor(() => {
      expect(screen.getByText(/target is required/i)).toBeInTheDocument()
    })
  })
})
