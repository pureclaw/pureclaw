import { render } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { ChatArea } from '../ChatArea'
import type { Agent, Message } from '../../types'

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
