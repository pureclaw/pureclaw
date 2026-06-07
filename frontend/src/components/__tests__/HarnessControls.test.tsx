import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { HarnessControls } from '../HarnessControls'
import type { SessionInfo, TabInfo } from '../../types'

function harnessTab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    index: 0,
    kind: 'harness',
    name: 'claude-code-0',
    status: 'running',
    session_id: 'sess-h',
    ...overrides,
  }
}

function session(overrides: Partial<SessionInfo> = {}): SessionInfo {
  return {
    id: 'sess-h',
    agent: null,
    runtime: 'harness:claude-code',
    model: '',
    lastActive: '2024-01-01T00:00:00Z',
    createdAt: '2024-01-01T00:00:00Z',
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
    ...overrides,
  }
}

describe('HarnessControls', () => {
  it('HC.1: shows the harness name and its status', () => {
    render(<HarnessControls tab={harnessTab()} session={session()} onDestroy={vi.fn()} />)
    expect(screen.getByText('claude-code-0')).toBeInTheDocument()
    expect(screen.getByText(/Running/i)).toBeInTheDocument()
  })

  it('HC.2: lists the associated session', () => {
    render(
      <HarnessControls
        tab={harnessTab()}
        session={session({ description: 'my harness session' })}
        onDestroy={vi.fn()}
      />,
    )
    expect(screen.getByText('my harness session')).toBeInTheDocument()
  })

  it('HC.3: indicates when no session is associated yet', () => {
    render(<HarnessControls tab={harnessTab({ session_id: null })} session={null} onDestroy={vi.fn()} />)
    expect(screen.getByText(/no session/i)).toBeInTheDocument()
  })

  it('HC.6: surfaces the linked session id even when the session object is not loaded', () => {
    // A running harness owns its session, but that session is excluded from the
    // recents list (it is an active tab with an empty transcript), so the parent
    // passes session=null. The tab's session_id is the source of truth: the view
    // must show it as associated, NOT claim "no session".
    render(<HarnessControls tab={harnessTab({ session_id: 'sess-h' })} session={null} onDestroy={vi.fn()} />)
    expect(screen.queryByText(/no session/i)).not.toBeInTheDocument()
    expect(screen.getByText('sess-h')).toBeInTheDocument()
  })

  it('HC.7: the associated session is a link that navigates to the session', () => {
    const onOpenSession = vi.fn()
    render(
      <HarnessControls
        tab={harnessTab({ session_id: 'sess-h' })}
        session={null}
        onOpenSession={onOpenSession}
        onDestroy={vi.fn()}
      />,
    )
    fireEvent.click(screen.getByText('sess-h'))
    expect(onOpenSession).toHaveBeenCalledWith('sess-h')
  })

  it('HC.8: an ADOPTED harness offers Release (stop managing, leave running)', () => {
    const onRelease = vi.fn()
    render(
      <HarnessControls
        tab={harnessTab({ origin: 'adopted' })}
        session={null}
        onRelease={onRelease}
        onDestroy={vi.fn()}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /release/i }))
    expect(onRelease).toHaveBeenCalledWith(0)
  })

  it('HC.8: a SPAWNED harness does NOT offer Release (only Destroy)', () => {
    render(
      <HarnessControls
        tab={harnessTab({ origin: 'spawned' })}
        session={null}
        onRelease={vi.fn()}
        onDestroy={vi.fn()}
      />,
    )
    expect(screen.queryByRole('button', { name: /release/i })).not.toBeInTheDocument()
  })

  it('HC.4: a SPAWNED harness destroys immediately (no confirm step)', () => {
    const onDestroy = vi.fn()
    render(
      <HarnessControls tab={harnessTab({ origin: 'spawned' })} session={session()} onDestroy={onDestroy} />,
    )
    fireEvent.click(screen.getByRole('button', { name: /destroy/i }))
    expect(onDestroy).toHaveBeenCalledWith(0, false)
  })

  it('HC.5: an ADOPTED harness requires a confirmation naming the kill consequence before destroying', () => {
    const onDestroy = vi.fn()
    render(
      <HarnessControls tab={harnessTab({ origin: 'adopted' })} session={session()} onDestroy={onDestroy} />,
    )
    // First click reveals the confirmation, does NOT destroy.
    fireEvent.click(screen.getByRole('button', { name: /destroy/i }))
    expect(onDestroy).not.toHaveBeenCalled()
    // The confirmation must name the consequence: it kills a window PureClaw
    // did not create.
    expect(screen.getByText(/did not create/i)).toBeInTheDocument()
    // Confirming destroys with the adopted-confirm flag set.
    fireEvent.click(screen.getByRole('button', { name: /confirm destroy/i }))
    expect(onDestroy).toHaveBeenCalledWith(0, true)
  })
})
