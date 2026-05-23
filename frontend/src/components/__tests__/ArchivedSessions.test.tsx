import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { ArchivedSessions } from '../ArchivedSessions'
import type { SessionInfo } from '../../types'

function makeSessions(...overrides: Partial<SessionInfo>[]): SessionInfo[] {
  return overrides.map((o, i) => ({
    id: o.id ?? `archived-${i}`,
    agent: o.agent ?? null,
    runtime: o.runtime ?? 'session:provider',
    model: o.model ?? '',
    lastActive: o.lastActive ?? new Date(Date.now() - 3 * 86400000).toISOString(),
    createdAt: o.createdAt ?? new Date(Date.now() - 3 * 86400000).toISOString(),
    description: o.description ?? null,
    autoSummary: o.autoSummary ?? null,
    firstMessageSnippet: o.firstMessageSnippet ?? null,
  }))
}

describe('ArchivedSessions', () => {
  it('is collapsed by default', () => {
    const sessions = makeSessions({ description: 'old session' })
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )
    // Session content should NOT be visible when collapsed
    expect(screen.queryByText('old session')).not.toBeInTheDocument()
  })

  it('shows count in header when collapsed', () => {
    const sessions = makeSessions(
      { description: 'one' },
      { description: 'two' },
      { description: 'three' },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )
    expect(screen.getByText(/Archived/)).toHaveTextContent('Archived (3)')
  })

  it('expands on header click to show sessions', () => {
    const sessions = makeSessions(
      { description: 'old session' },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )

    // Click to expand
    fireEvent.click(screen.getByText(/Archived/))

    // Now the session should be visible
    expect(screen.getByText('old session')).toBeInTheDocument()
  })

  it('shows expand/collapse icons', () => {
    const sessions = makeSessions({ description: 'test' })
    const { container } = render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )

    // Collapsed: should show right-pointing triangle
    expect(container.querySelector('[data-testid="collapse-icon"]')).toHaveTextContent('▸') // ▸

    // Expand
    fireEvent.click(screen.getByText(/Archived/))

    // Expanded: should show down-pointing triangle
    expect(container.querySelector('[data-testid="collapse-icon"]')).toHaveTextContent('▾') // ▾
  })

  it('shows unarchive button for each session when expanded', () => {
    const sessions = makeSessions(
      { description: 'session-a' },
      { description: 'session-b' },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )

    // Expand
    fireEvent.click(screen.getByText(/Archived/))

    const unarchiveButtons = screen.getAllByRole('button', { name: /unarchive/i })
    expect(unarchiveButtons).toHaveLength(2)
  })

  it('calls onUnarchive with session id when unarchive button is clicked', () => {
    const onUnarchive = vi.fn()
    const sessions = makeSessions(
      { id: 'sess-abc', description: 'to-unarchive' },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={onUnarchive}
      />,
    )

    // Expand first
    fireEvent.click(screen.getByText(/Archived/))

    // Click unarchive
    const unarchiveBtn = screen.getByRole('button', { name: /unarchive/i })
    fireEvent.click(unarchiveBtn)

    expect(onUnarchive).toHaveBeenCalledWith('sess-abc')
  })

  it('calls onSelectSession with session id when a session row is clicked', () => {
    const onSelectSession = vi.fn()
    const sessions = makeSessions(
      { id: 'sess-xyz', description: 'click me' },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={onSelectSession}
        onUnarchive={() => {}}
      />,
    )

    // Expand first
    fireEvent.click(screen.getByText(/Archived/))

    // Click the session row
    fireEvent.click(screen.getByText('click me'))

    expect(onSelectSession).toHaveBeenCalledWith('sess-xyz')
  })

  it('does not render section when sessions array is empty', () => {
    const { container } = render(
      <ArchivedSessions
        sessions={[]}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )
    expect(container.firstChild).toBeNull()
  })

  it('shows relative time for each archived session', () => {
    // 3 days ago
    const sessions = makeSessions(
      { description: 'old-one', lastActive: new Date(Date.now() - 3 * 86400000).toISOString() },
    )
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )

    // Expand
    fireEvent.click(screen.getByText(/Archived/))

    expect(screen.getByText('3d')).toBeInTheDocument()
  })

  it('collapses when header is clicked a second time', () => {
    const sessions = makeSessions({ description: 'toggling' })
    render(
      <ArchivedSessions
        sessions={sessions}
        selectedId={null}
        onSelectSession={() => {}}
        onUnarchive={() => {}}
      />,
    )

    const header = screen.getByText(/Archived/)

    // Expand
    fireEvent.click(header)
    expect(screen.getByText('toggling')).toBeInTheDocument()

    // Collapse
    fireEvent.click(header)
    expect(screen.queryByText('toggling')).not.toBeInTheDocument()
  })
})
