import { render, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { ChatArea } from '../ChatArea'
import type { Agent, Message, ToolCallInfo } from '../../types'

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

function makeToolCallMessage(id: string, tc: ToolCallInfo): Message {
  return {
    id,
    agentName: 'Assistant',
    agentStatus: 'completed',
    timestamp: '12:00',
    blocks: [{ id: `tc-${tc.id}`, toolCall: tc }],
  }
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

  it('exposes a JSON button on tool-call headers showing the tool-call payload', () => {
    const tc: ToolCallInfo = {
      id: 'tu_1',
      name: 'shell',
      input: { command: 'ls' },
      result: 'a\nb',
    }
    const { getByLabelText, getByTestId, getByRole } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[makeToolCallMessage('m1', tc)]} />,
    )
    fireEvent.click(getByLabelText('View raw JSON (tool call)'))
    fireEvent.click(getByRole('tab', { name: 'Raw' }))
    const body = getByTestId('raw-json-body').textContent ?? ''
    expect(body).toContain('"name": "shell"')
    expect(body).toContain('"command": "ls"')
    expect(body).toContain('"result": "a\\nb"')
  })

  it('Escape closes only the topmost modal when two are stacked', () => {
    const tc: ToolCallInfo = { id: 'tu_1', name: 'shell', input: { command: 'ls' } }
    const message: Message = {
      id: 'm1',
      agentName: 'Assistant',
      agentStatus: 'completed',
      timestamp: '12:00',
      blocks: [{ id: `tc-${tc.id}`, toolCall: tc }],
      rawJson: '{"x":1}',
    }
    const { getByLabelText, queryAllByTestId } = render(
      <ChatArea selectedAgent={makeAgent()} messages={[message]} />,
    )

    fireEvent.click(getByLabelText('View raw JSON (message)'))
    fireEvent.click(getByLabelText('View raw JSON (tool call)'))
    expect(queryAllByTestId('raw-json-modal')).toHaveLength(2)

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(queryAllByTestId('raw-json-modal')).toHaveLength(1)

    fireEvent.keyDown(window, { key: 'Escape' })
    expect(queryAllByTestId('raw-json-modal')).toHaveLength(0)
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
