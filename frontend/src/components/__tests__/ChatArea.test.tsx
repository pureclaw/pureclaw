import { render, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { ChatArea } from '../ChatArea'
import { transcriptToMessages } from '../../App'
import type { Agent, Message, TranscriptEntry } from '../../types'

function makeAgent(): Agent {
  return { id: 'a1', name: 'Coder', status: 'idle', tokenCount: '0' }
}

function makeMessage(id: string, text: string): Message {
  return {
    id,
    agentName: 'You',
    agentStatus: 'idle',
    timestamp: '12:00',
    blocks: [{ text }],
  }
}

function makeMessageWithRawJson(id: string, text: string, rawJson: string): Message {
  return { ...makeMessage(id, text), rawJson }
}

// jsdom doesn't compute layout, so we drive the at-bottom heuristic by
// mocking scrollHeight / scrollTop / clientHeight on the element prototype.
// Tests mutate the module-level vars to simulate user scrolling and content
// growth between renders.
describe('ChatArea sticky-bottom auto-scroll', () => {
  let scrollHeight = 100
  let scrollTop = 0
  let clientHeight = 100
  let scrollIntoViewSpy: ReturnType<typeof vi.fn>

  beforeEach(() => {
    scrollHeight = 100
    scrollTop = 0
    clientHeight = 100

    vi.spyOn(HTMLElement.prototype, 'scrollHeight', 'get')
      .mockImplementation(function (this: HTMLElement) {
        return this.classList.contains('chat-scroll') ? scrollHeight : 0
      })
    vi.spyOn(HTMLElement.prototype, 'scrollTop', 'get')
      .mockImplementation(function (this: HTMLElement) {
        return this.classList.contains('chat-scroll') ? scrollTop : 0
      })
    vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get')
      .mockImplementation(function (this: HTMLElement) {
        return this.classList.contains('chat-scroll') ? clientHeight : 0
      })

    scrollIntoViewSpy = vi.fn()
    HTMLElement.prototype.scrollIntoView = scrollIntoViewSpy as unknown as HTMLElement['scrollIntoView']
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('auto-scrolls to bottom when tall new content arrives while user was at bottom', () => {
    scrollHeight = 100
    scrollTop = 0
    clientHeight = 100

    const { rerender } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeMessage('m1', 'first')]} />,
    )

    // First render auto-scrolls. Clear so we can assert on the rerender.
    scrollIntoViewSpy.mockClear()

    // Tall response arrives below the viewport. scrollTop is unchanged
    // because content was appended off-screen; only scrollHeight grew, and
    // it grew well past the 80px "near-bottom" threshold.
    scrollHeight = 1000

    rerender(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessage('m1', 'first'), makeMessage('m2', 'tall response')]}
      />,
    )

    expect(scrollIntoViewSpy).toHaveBeenCalled()
  })

  it('does not auto-scroll when the user has scrolled up away from the bottom', () => {
    scrollHeight = 1000
    scrollTop = 0
    clientHeight = 100

    const { container, rerender } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeMessage('m1', 'first')]} />,
    )

    // Record the user's actual scroll position.
    const scroller = container.querySelector('.chat-scroll') as HTMLElement | null
    expect(scroller).not.toBeNull()
    scroller!.dispatchEvent(new Event('scroll'))

    scrollIntoViewSpy.mockClear()

    scrollHeight = 1100
    rerender(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessage('m1', 'first'), makeMessage('m2', 'second')]}
      />,
    )

    expect(scrollIntoViewSpy).not.toHaveBeenCalled()
  })
})

describe('ChatArea raw-JSON modal', () => {
  it('shows a JSON button on message headers when rawJson is set', () => {
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"model":"sonnet"}')]}
      />,
    )
    expect(getByLabelText('View raw JSON (message)')).toBeTruthy()
  })

  it('omits the JSON button when rawJson is not set', () => {
    const { queryByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeMessage('m1', 'hi')]} />,
    )
    expect(queryByLabelText('View raw JSON (message)')).toBeNull()
  })

  it('shows pretty-printed JSON in the Raw tab when the button is clicked', () => {
    const raw = '{"model":"sonnet","messages":[{"role":"user","content":"hi"}]}'
    const { getByLabelText, queryByTestId, getByTestId, getByRole } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', raw)]}
      />,
    )

    expect(queryByTestId('raw-json-modal')).toBeNull()
    fireEvent.click(getByLabelText('View raw JSON (message)'))

    const modal = getByTestId('raw-json-modal')
    expect(modal).toBeTruthy()

    fireEvent.click(getByRole('tab', { name: 'Raw' }))
    const pretty = JSON.stringify(JSON.parse(raw), null, 2)
    expect(getByTestId('raw-json-body').textContent).toBe(pretty)
  })

  it('falls back to the raw payload in the Raw tab when content is not parseable JSON', () => {
    const raw = 'not-json-payload\nsecond line'
    const { getByLabelText, getByTestId, getByRole } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', raw)]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    fireEvent.click(getByRole('tab', { name: 'Raw' }))
    expect(getByTestId('raw-json-body').textContent).toBe(raw)
  })

  it('defaults to the Formatted tab and renders a JSON tree', () => {
    const raw = '{"model":"sonnet"}'
    const { getByLabelText, getByTestId, queryByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', raw)]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    expect(getByTestId('formatted-json-body')).toBeTruthy()
    expect(queryByTestId('raw-json-body')).toBeNull()
  })

  it('Formatted tab unescapes \\n in string values to real newlines', () => {
    const raw = JSON.stringify({ system_prompt: 'Hello\nWorld' })
    const { getByLabelText, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', raw)]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    const body = getByTestId('formatted-json-body')
    expect(body.textContent).toContain('Hello\nWorld')
    expect(body.textContent).not.toContain('Hello\\nWorld')
  })

  it('Formatted tab shows a fallback when payload is not valid JSON', () => {
    const { getByLabelText, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', 'not-json')]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    expect(getByTestId('formatted-json-body').textContent).toMatch(/not valid JSON/i)
  })

  it('closes the modal on the close button', () => {
    const { getByLabelText, queryByTestId, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"a":1}')]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    expect(getByTestId('raw-json-modal')).toBeTruthy()
    fireEvent.click(getByLabelText('Close raw JSON view'))
    expect(queryByTestId('raw-json-modal')).toBeNull()
  })

  it('closes the modal on Escape', () => {
    const { getByLabelText, queryByTestId, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"a":1}')]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    expect(getByTestId('raw-json-modal')).toBeTruthy()
    fireEvent.keyDown(window, { key: 'Escape' })
    expect(queryByTestId('raw-json-modal')).toBeNull()
  })

  it('closes the modal when the backdrop is clicked', () => {
    const { getByLabelText, queryByTestId, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"a":1}')]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    fireEvent.click(getByTestId('raw-json-backdrop'))
    expect(queryByTestId('raw-json-modal')).toBeNull()
  })

  it('restores focus to the triggering button on close', () => {
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"a":1}')]}
      />,
    )
    const trigger = getByLabelText('View raw JSON (message)') as HTMLButtonElement
    trigger.focus()
    expect(document.activeElement).toBe(trigger)

    fireEvent.click(trigger)
    fireEvent.click(getByLabelText('Close raw JSON view'))
    expect(document.activeElement).toBe(trigger)
  })

  it('focuses the close button when the modal opens', () => {
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', '{"a":1}')]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    expect(document.activeElement).toBe(getByLabelText('Close raw JSON view'))
  })

  it('copies the pretty-printed JSON to the clipboard', () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    const originalClipboard = navigator.clipboard
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText },
      configurable: true,
    })
    try {
      const raw = '{"model":"sonnet"}'
      const { getByLabelText } = render(
        <ChatArea
          selectedAgent={makeAgent()}
          messages={[makeMessageWithRawJson('m1', 'hi', raw)]}
        />,
      )
      fireEvent.click(getByLabelText('View raw JSON (message)'))
      fireEvent.click(getByLabelText('Copy raw JSON to clipboard'))
      const pretty = JSON.stringify(JSON.parse(raw), null, 2)
      expect(writeText).toHaveBeenCalledWith(pretty)
    } finally {
      Object.defineProperty(navigator, 'clipboard', {
        value: originalClipboard,
        configurable: true,
      })
    }
  })

  // pureclaw-1xd — when rawJson is the full verbatim transcript line, the modal
  // must surface every _te_* field, including _te_metadata / _te_correlationId /
  // _te_durationMs. Governing principle: everything is visible to the user.
  it('displays the full verbatim line fields (metadata, correlationId, durationMs)', () => {
    const fullLine = JSON.stringify({
      _te_correlationId: 'corr-xyz',
      _te_direction: 'Response',
      _te_durationMs: 1234,
      _te_harness: null,
      _te_id: 'te-9',
      _te_metadata: { source: 'sender-1' },
      _te_model: 'sonnet',
      _te_payload: JSON.stringify({ content: [{ type: 'text', text: 'hi' }] }),
      _te_timestamp: '2024-01-01T00:00:00Z',
    })
    const { getByLabelText, getByTestId, getByRole } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessageWithRawJson('m1', 'hi', fullLine)]}
      />,
    )
    fireEvent.click(getByLabelText('View raw JSON (message)'))
    fireEvent.click(getByRole('tab', { name: 'Raw' }))
    const body = getByTestId('raw-json-body').textContent ?? ''
    expect(body).toContain('_te_metadata')
    expect(body).toContain('_te_correlationId')
    expect(body).toContain('_te_durationMs')
    expect(body).toContain('1234')
    expect(body).toContain('source')
    // The payload remains an escaped JSON string inside the verbatim line.
    expect(body).toContain('_te_payload')
  })
})

describe('ChatArea permalink highlight', () => {
  beforeEach(() => {
    // jsdom doesn't implement scrollIntoView; useFragmentAnchor scrolls
    // the targeted ref into view on focus and ChatArea scrolls the
    // messages-end ref on render. Stub both to keep the renders quiet.
    HTMLElement.prototype.scrollIntoView = vi.fn() as unknown as HTMLElement['scrollIntoView']
    // Reset the URL hash so prior tests don't pre-target our message.
    window.history.replaceState(null, '', window.location.pathname + window.location.search)
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('highlights the message immediately when the permalink button is clicked', () => {
    const { container, getByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeMessage('m1', 'hello')]} />,
    )
    const msgEl = container.querySelector('#msg-m1') as HTMLElement | null
    expect(msgEl).not.toBeNull()
    // Initially not targeted: the highlight inline style isn't applied.
    expect(msgEl!.style.background).toBe('')

    fireEvent.click(getByLabelText('Copy permalink (Link)'))

    // After clicking, useFragmentAnchor should observe the fragment via
    // the synthetic hashchange dispatched by copyAnchorLink (history
    // replaceState alone does NOT fire hashchange — that's the bug
    // this regression test guards against).
    expect(msgEl!.style.background).toBe('var(--bg-elevated)')
    expect(window.location.hash).toBe('#msg-m1')
  })
})

describe('ChatArea textarea focus management', () => {
  it('focuses the message input on initial mount', () => {
    render(<ChatArea selectedAgent={makeAgent()} messages={[]} />)
    const textarea = document.querySelector('textarea')
    expect(textarea).not.toBeNull()
    expect(document.activeElement).toBe(textarea)
  })

  it('refocuses the message input when selectedId changes (session/tab switch)', () => {
    const { rerender } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[]} selectedId={'tab:0'} />,
    )
    const textarea = document.querySelector('textarea')
    expect(document.activeElement).toBe(textarea)

    // Simulate the user clicking elsewhere (e.g. the sidebar) which
    // takes focus away from the textarea.
    const fakeBtn = document.createElement('button')
    document.body.appendChild(fakeBtn)
    fakeBtn.focus()
    expect(document.activeElement).toBe(fakeBtn)

    // Selecting a different tab should re-focus the textarea.
    rerender(
      <ChatArea selectedAgent={makeAgent()} messages={[]} selectedId={'tab:1'} />,
    )
    expect(document.activeElement).toBe(textarea)

    // Same again — selecting an archived session.
    fakeBtn.focus()
    expect(document.activeElement).toBe(fakeBtn)
    rerender(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        selectedId={'session:abc-123'}
      />,
    )
    expect(document.activeElement).toBe(textarea)

    document.body.removeChild(fakeBtn)
  })

  it('refocuses the message input on every New-tab click, even when already in compose mode', () => {
    // Already in compose mode (selectedId=null), so a "+" click does
    // NOT change selectedId. The newTabFocusTick prop is the recovery
    // signal for this case.
    const composer = {
      panel: <div>compose panel</div>,
      kind: 'provider' as const,
      valid: true,
      onSubmit: () => {},
    }
    const { rerender } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={composer}
        selectedId={null}
        newTabFocusTick={0}
      />,
    )

    const textarea = document.querySelector('textarea')
    expect(document.activeElement).toBe(textarea)

    const fakeBtn = document.createElement('button')
    document.body.appendChild(fakeBtn)
    fakeBtn.focus()
    expect(document.activeElement).toBe(fakeBtn)

    rerender(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={composer}
        selectedId={null}
        newTabFocusTick={1}
      />,
    )
    expect(document.activeElement).toBe(textarea)

    document.body.removeChild(fakeBtn)
  })
})

// ---------------------------------------------------------------------------
// D8 — transcriptToMessages entry-id plumbing
// ---------------------------------------------------------------------------
describe('transcriptToMessages entryId plumbing (D8)', () => {
  function requestEntry(id: string, opts: { system?: string; userText?: string }): TranscriptEntry {
    const messages: Array<{ role: string; content: Array<{ type: string; text?: string }> }> = []
    if (opts.userText !== undefined) {
      messages.push({ role: 'user', content: [{ type: 'text', text: opts.userText }] })
    }
    const payload: Record<string, unknown> = { model: 'sonnet', messages }
    if (opts.system !== undefined) payload.system_prompt = opts.system
    return {
      id,
      timestamp: '2024-01-01T00:00:00Z',
      direction: 'request',
      payload: JSON.stringify(payload),
      harness: null,
      model: 'sonnet',
      raw: JSON.stringify({ _te_id: id, _te_payload: JSON.stringify(payload) }),
    }
  }

  function responseEntry(id: string, text: string): TranscriptEntry {
    return {
      id,
      timestamp: '2024-01-01T00:00:01Z',
      direction: 'response',
      payload: JSON.stringify({ content: [{ type: 'text', text }] }),
      harness: null,
      model: 'sonnet',
      raw: JSON.stringify({ _te_id: id, _te_payload: text }),
    }
  }

  it('sets entryId to the raw _te_id on the user row', () => {
    const msgs = transcriptToMessages([requestEntry('te-1', { userText: 'hello' })])
    const user = msgs.find((m) => m.id === 'te-1-user')
    expect(user).toBeTruthy()
    expect(user!.entryId).toBe('te-1')
  })

  it('sets entryId to the raw _te_id on the request-derived assistant row', () => {
    const reqWithAsst: TranscriptEntry = {
      id: 'te-2',
      timestamp: '2024-01-01T00:00:00Z',
      direction: 'request',
      payload: JSON.stringify({
        model: 'sonnet',
        messages: [{ role: 'assistant', content: [{ type: 'text', text: 'prior turn' }] }],
      }),
      harness: null,
      model: 'sonnet',
      raw: JSON.stringify({ _te_id: 'te-2', _te_payload: 'prior turn' }),
    }
    const msgs = transcriptToMessages([reqWithAsst])
    const asst = msgs.find((m) => m.id === 'te-2-asst')
    expect(asst).toBeTruthy()
    expect(asst!.entryId).toBe('te-2')
  })

  it('sets entryId to the raw _te_id on the response row', () => {
    const msgs = transcriptToMessages([responseEntry('te-3', 'hi there')])
    const resp = msgs.find((m) => m.id === 'te-3')
    expect(resp).toBeTruthy()
    expect(resp!.entryId).toBe('te-3')
  })

  it('does NOT set entryId on the synthesized System row', () => {
    const msgs = transcriptToMessages([
      requestEntry('te-4', { system: 'You are helpful.', userText: 'hello' }),
    ])
    const sys = msgs.find((m) => m.id === 'te-4-sys')
    expect(sys).toBeTruthy()
    expect(sys!.entryId).toBeUndefined()
    // adjacent user row from the same entry still carries entryId
    const user = msgs.find((m) => m.id === 'te-4-user')
    expect(user!.entryId).toBe('te-4')
  })
})

// ---------------------------------------------------------------------------
// D9 / D10 — BranchButton rendering + wiring
// ---------------------------------------------------------------------------
function makeMessageWithEntryId(id: string, text: string, entryId?: string): Message {
  const m = makeMessage(id, text)
  if (entryId !== undefined) m.entryId = entryId
  return m
}

describe('ChatArea branch button (D9, D10)', () => {
  const BRANCH_LABEL = 'branch session from here'

  it('renders a branch button next to the JSON button when onBranch and entryId are present (D9)', () => {
    const onBranch = vi.fn()
    const msg = { ...makeMessageWithRawJson('m1', 'hi', '{"model":"sonnet"}'), entryId: 'te-1' }
    const { getByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[msg]} onBranch={onBranch} />,
    )
    expect(getByLabelText('View raw JSON (message)')).toBeTruthy()
    const branchBtn = getByLabelText(BRANCH_LABEL)
    expect(branchBtn).toBeTruthy()
    expect(branchBtn.getAttribute('title')).toBe(BRANCH_LABEL)
  })

  it('calls onBranch with the entry id when clicked (D9)', () => {
    const onBranch = vi.fn()
    const msg = makeMessageWithEntryId('m1', 'hi', 'te-42')
    const { getByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[msg]} onBranch={onBranch} />,
    )
    fireEvent.click(getByLabelText(BRANCH_LABEL))
    expect(onBranch).toHaveBeenCalledTimes(1)
    expect(onBranch).toHaveBeenCalledWith('te-42')
  })

  it('shows a branch button on the user row but NOT on the System row (D9)', () => {
    const onBranch = vi.fn()
    const sysRow: Message = {
      id: 'te-1-sys',
      agentName: 'System',
      agentStatus: 'idle',
      timestamp: '12:00',
      blocks: [{ collapsedText: 'You are helpful.' }],
    }
    const userRow = makeMessageWithEntryId('te-1-user', 'hello', 'te-1')
    const { getAllByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[sysRow, userRow]} onBranch={onBranch} />,
    )
    // Exactly one branch button — for the user row, not the System row.
    expect(getAllByLabelText(BRANCH_LABEL)).toHaveLength(1)
  })

  it('renders no branch button when onBranch is undefined (D10)', () => {
    const msg = makeMessageWithEntryId('m1', 'hi', 'te-1')
    const { queryByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[msg]} />,
    )
    expect(queryByLabelText(BRANCH_LABEL)).toBeNull()
  })

  it('renders no branch button when the message has no entryId (D9)', () => {
    const onBranch = vi.fn()
    const msg = makeMessage('m1', 'hi')
    const { queryByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[msg]} onBranch={onBranch} />,
    )
    expect(queryByLabelText(BRANCH_LABEL)).toBeNull()
  })

  it('disables the branch button while a send is in flight (D10)', () => {
    const onBranch = vi.fn()
    const msg = makeMessageWithEntryId('m1', 'hi', 'te-1')
    const { getByLabelText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[msg]} onBranch={onBranch} sending />,
    )
    const branchBtn = getByLabelText(BRANCH_LABEL) as HTMLButtonElement
    expect(branchBtn.disabled).toBe(true)
    fireEvent.click(branchBtn)
    expect(onBranch).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Header subtitle spacing (#67): the separator + subtitle form a single flex
// child so the title↔subtitle gap is one standard gap, not two.
// ---------------------------------------------------------------------------
describe('ChatArea header subtitle spacing', () => {
  it('groups the middot separator and subtitle into one element', () => {
    HTMLElement.prototype.scrollIntoView = vi.fn() as unknown as HTMLElement['scrollIntoView']
    const agent = { ...makeAgent(), description: 'signal:+15551234567' }
    const { getByTestId } = render(<ChatArea selectedAgent={agent} messages={[]} />)
    const subtitle = getByTestId('header-subtitle')
    // Separator and subtitle text live in the SAME element (one flex child →
    // one gap between the title and the subtitle), with the middot followed by
    // a normal space — matching the spacing of the dots inside the subtitle.
    expect(subtitle.textContent).toBe('· signal:+15551234567')
  })
})

// ---------------------------------------------------------------------------
// D12a / D12b — read-only branch prefix above the composer
// ---------------------------------------------------------------------------
describe('ChatArea branch-draft prefix (D12a, D12b)', () => {
  const BRANCH_LABEL = 'branch session from here'
  const composer = {
    panel: <div>compose panel</div>,
    kind: 'provider' as const,
    valid: true,
    onSubmit: () => {},
  }

  it('renders prefixMessages read-only above the composer panel (D12b)', () => {
    const prefix = [
      makeMessageWithEntryId('p1', 'prefix one', 'te-1'),
      makeMessageWithEntryId('p2', 'prefix two', 'te-2'),
    ]
    const { getByText, getByTestId } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={composer}
        prefixMessages={prefix}
        selectedId={null}
      />,
    )
    expect(getByTestId('branch-prefix')).toBeTruthy()
    expect(getByText('prefix one')).toBeTruthy()
    expect(getByText('prefix two')).toBeTruthy()
    expect(getByText('compose panel')).toBeTruthy()
  })

  it('prefix rows carry NO branch button even when onBranch is undefined in compose mode (D12a)', () => {
    const prefix = [makeMessageWithEntryId('p1', 'prefix one', 'te-1')]
    const { queryByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={composer}
        prefixMessages={prefix}
        selectedId={null}
      />,
    )
    expect(queryByLabelText(BRANCH_LABEL)).toBeNull()
  })

  it('renders a compose error banner when composeError is set (D14)', () => {
    const { getByRole } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={composer}
        composeError={'Could not create the branch'}
        selectedId={null}
      />,
    )
    expect(getByRole('alert').textContent).toMatch(/could not create the branch/i)
  })
})

// ---------------------------------------------------------------------------
// U1 / U2 — per-session model dropdown in the chat input row
// ---------------------------------------------------------------------------
describe('ChatArea model dropdown (U1, U2)', () => {
  const MODEL_LABEL = 'session model'

  it('renders the model dropdown for an existing session with the current model selected (U1)', () => {
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessage('m1', 'hi')]}
        onSend={() => {}}
        currentModel="sonnet-4"
        availableModels={['sonnet-4', 'opus-4']}
        onModelChange={() => {}}
      />,
    )
    const select = getByLabelText(MODEL_LABEL) as HTMLSelectElement
    expect(select).toBeTruthy()
    expect(select.value).toBe('sonnet-4')
  })

  it('includes the current model in the options even when it is not in availableModels (U1)', () => {
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessage('m1', 'hi')]}
        onSend={() => {}}
        currentModel="legacy-model"
        availableModels={['sonnet-4']}
        onModelChange={() => {}}
      />,
    )
    const select = getByLabelText(MODEL_LABEL) as HTMLSelectElement
    expect(select.value).toBe('legacy-model')
    const options = Array.from(select.options).map((o) => o.value)
    expect(options).toContain('legacy-model')
    expect(options).toContain('sonnet-4')
  })

  it('calls onModelChange when the user picks a different model (U2)', () => {
    const onModelChange = vi.fn()
    const { getByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[makeMessage('m1', 'hi')]}
        onSend={() => {}}
        currentModel="sonnet-4"
        availableModels={['sonnet-4', 'opus-4']}
        onModelChange={onModelChange}
      />,
    )
    const select = getByLabelText(MODEL_LABEL) as HTMLSelectElement
    fireEvent.change(select, { target: { value: 'opus-4' } })
    expect(onModelChange).toHaveBeenCalledWith('opus-4')
  })

  it('does not render the model dropdown in compose mode (U1)', () => {
    const { queryByLabelText } = render(
      <ChatArea
        selectedAgent={makeAgent()}
        messages={[]}
        composerControls={{ panel: <div>p</div>, kind: 'provider', valid: true, onSubmit: () => {} }}
        currentModel="sonnet-4"
        availableModels={['sonnet-4']}
        onModelChange={() => {}}
        selectedId={null}
      />,
    )
    expect(queryByLabelText(MODEL_LABEL)).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// WU8 — claude-code "thinking" content block rendering
// ---------------------------------------------------------------------------
describe('ChatArea thinking block (WU8)', () => {
  beforeEach(() => {
    HTMLElement.prototype.scrollIntoView = vi.fn() as unknown as HTMLElement['scrollIntoView']
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  function thinkingMessage(id: string, thinkingText: string): Message {
    return {
      id,
      agentName: 'Assistant',
      agentStatus: 'idle',
      timestamp: '12:00',
      blocks: [{ id: 'tk-' + id, thinkingText }],
    }
  }

  it('D8.2: renders the thinking block collapsed by default with a distinct "Thinking" label', () => {
    const { getByText, container } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[thinkingMessage('m1', 'let me reason about this')]} />,
    )
    // Distinct "Thinking" label is visible.
    expect(getByText('Thinking')).toBeTruthy()
    // Collapsed by default: full text is not rendered as expanded content.
    // The preview is shown, but the expanded <pre> is absent until clicked.
    expect(container.querySelector('pre')).toBeNull()
  })

  it('D8.2: expands to show the thinking text when clicked', () => {
    const { getByText, container } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[thinkingMessage('m1', 'detailed chain of thought here')]} />,
    )
    fireEvent.click(getByText('Thinking'))
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    expect(pre!.textContent).toContain('detailed chain of thought here')
  })

  it('D8.2: escapes thinking content as React text — no HTML injection', () => {
    const xss = '<img src=x onerror=alert(1)>'
    const { getByText, container } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[thinkingMessage('m1', xss)]} />,
    )
    // Expand so the full payload is in the DOM.
    fireEvent.click(getByText('Thinking'))
    // The payload must NOT have produced a real <img> element.
    expect(container.querySelector('img')).toBeNull()
    // It must appear verbatim as text instead.
    const pre = container.querySelector('pre')
    expect(pre).not.toBeNull()
    expect(pre!.textContent).toContain(xss)
  })

  it('D8.2: the Thinking label is distinct from the System collapsed block', () => {
    const thinkingRow = thinkingMessage('m1', 'inner reasoning')
    const sysRow: Message = {
      id: 'te-1-sys',
      agentName: 'System',
      agentStatus: 'idle',
      timestamp: '12:00',
      blocks: [{ collapsedText: 'You are helpful.' }],
    }
    const { getByText, queryAllByText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[sysRow, thinkingRow]} />,
    )
    // "Thinking" label appears for the thinking block only.
    expect(queryAllByText('Thinking')).toHaveLength(1)
    // The System collapsed block does not borrow the Thinking label — its
    // preview text is shown plainly.
    expect(getByText('You are helpful.')).toBeTruthy()
  })

  it('D8.3 regression: System collapsedText block still renders its preview unchanged', () => {
    const sysRow: Message = {
      id: 'te-1-sys',
      agentName: 'System',
      agentStatus: 'idle',
      timestamp: '12:00',
      blocks: [{ collapsedText: 'You are a helpful assistant.' }],
    }
    const { getByText, queryByText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[sysRow]} />,
    )
    expect(getByText('You are a helpful assistant.')).toBeTruthy()
    // The System block must NOT acquire a "Thinking" label.
    expect(queryByText('Thinking')).toBeNull()
  })

  it('D8.3 regression: plain text blocks render unchanged', () => {
    const { getByText } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeMessage('m1', 'a plain text message')]} />,
    )
    expect(getByText('a plain text message')).toBeTruthy()
  })
})

// ---------------------------------------------------------------------------
// WU8 — transcript extractor maps type:"thinking" blocks into thinkingText
// ---------------------------------------------------------------------------
describe('transcriptToMessages thinking extraction (WU8)', () => {
  function responseEntry(content: unknown[]): TranscriptEntry {
    return {
      id: 'e1',
      timestamp: '2025-01-01T00:00:00Z',
      direction: 'response',
      payload: JSON.stringify({ content }),
      harness: 'claude-code',
      model: 'claude-sonnet-4',
      raw: JSON.stringify({ _te_id: 'e1', _te_payload: JSON.stringify({ content }) }),
    }
  }

  it('D8.1: extracts a type:"thinking" block into a thinkingText MessageContent', () => {
    const msgs = transcriptToMessages([
      responseEntry([{ type: 'thinking', thinking: 'pondering the problem', signature: 'sig123' }]),
    ])
    const block = msgs.flatMap((m) => m.blocks).find((b) => b.thinkingText !== undefined)
    expect(block).toBeTruthy()
    expect(block!.thinkingText).toBe('pondering the problem')
    // It must NOT be conflated with collapsedText (the System-prompt block).
    expect(block!.collapsedText).toBeUndefined()
  })

  it('D8.1: thinking and text blocks coexist on the same assistant response', () => {
    const msgs = transcriptToMessages([
      responseEntry([
        { type: 'thinking', thinking: 'first I think' },
        { type: 'text', text: 'then I answer' },
      ]),
    ])
    const blocks = msgs.flatMap((m) => m.blocks)
    expect(blocks.some((b) => b.thinkingText === 'first I think')).toBe(true)
    expect(blocks.some((b) => b.text === 'then I answer')).toBe(true)
  })

  it('D8.3 regression: a plain text-only response carries no thinkingText', () => {
    const msgs = transcriptToMessages([responseEntry([{ type: 'text', text: 'hello' }])])
    const blocks = msgs.flatMap((m) => m.blocks)
    expect(blocks.some((b) => b.text === 'hello')).toBe(true)
    expect(blocks.every((b) => b.thinkingText === undefined)).toBe(true)
  })
})
