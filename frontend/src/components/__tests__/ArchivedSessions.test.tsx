import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { Sidebar } from '../Sidebar'
import type { SessionInfo, TabInfo } from '../../types'

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

const defaultProps = {
  tabs: [] as TabInfo[],
  sessions: [] as SessionInfo[],
  archivedSessions: [] as SessionInfo[],
  selectedId: null as string | null,
  onSelectTab: vi.fn(),
  onSelectSession: vi.fn(),
  onNewTab: vi.fn(),
  onArchiveSession: vi.fn(),
  onUnarchiveSession: vi.fn(),
  onCloseTab: vi.fn(),
  onArchiveTab: vi.fn(),
}

describe('ArchivedSessions', () => {
  it('is collapsed by default', () => {
    const archivedSessions = makeSessions({ description: 'old session' })
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    expect(screen.queryByText('old session')).not.toBeInTheDocument()
  })

  it('shows count in header when collapsed', () => {
    const archivedSessions = makeSessions(
      { description: 'one' },
      { description: 'two' },
      { description: 'three' },
    )
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    expect(screen.getByText(/Archived/)).toHaveTextContent('Archived (3)')
  })

  it('expands on header click to show sessions', () => {
    const archivedSessions = makeSessions({ description: 'old session' })
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    fireEvent.click(screen.getByText(/Archived/))
    expect(screen.getByText('old session')).toBeInTheDocument()
  })

  it('shows expand/collapse icons', () => {
    const archivedSessions = makeSessions({ description: 'test' })
    const { container } = render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    expect(container.querySelector('[data-testid="collapse-icon"]')).toHaveTextContent('▸')
    fireEvent.click(screen.getByText(/Archived/))
    expect(container.querySelector('[data-testid="collapse-icon"]')).toHaveTextContent('▾')
  })

  it('shows unarchive button for each session when expanded', () => {
    const archivedSessions = makeSessions(
      { description: 'session-a' },
      { description: 'session-b' },
    )
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    fireEvent.click(screen.getByText(/Archived/))
    const unarchiveButtons = screen.getAllByRole('button', { name: /unarchive/i })
    expect(unarchiveButtons).toHaveLength(2)
  })

  it('calls onUnarchiveSession with session id when unarchive button is clicked', () => {
    const onUnarchiveSession = vi.fn()
    const archivedSessions = makeSessions({ id: 'sess-abc', description: 'to-unarchive' })
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} onUnarchiveSession={onUnarchiveSession} />,
    )
    fireEvent.click(screen.getByText(/Archived/))
    const unarchiveBtn = screen.getByRole('button', { name: /unarchive/i })
    fireEvent.click(unarchiveBtn)
    expect(onUnarchiveSession).toHaveBeenCalledWith('sess-abc')
  })

  it('calls onSelectSession with session id when a session row is clicked', () => {
    const onSelectSession = vi.fn()
    const archivedSessions = makeSessions({ id: 'sess-xyz', description: 'click me' })
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} onSelectSession={onSelectSession} />,
    )
    fireEvent.click(screen.getByText(/Archived/))
    fireEvent.click(screen.getByText('click me'))
    expect(onSelectSession).toHaveBeenCalledWith('sess-xyz')
  })

  it('does not render section when sessions array is empty', () => {
    render(
      <Sidebar {...defaultProps} archivedSessions={[]} />,
    )
    expect(screen.queryByText(/Archived/)).not.toBeInTheDocument()
  })

  it('shows relative time for each archived session', () => {
    const archivedSessions = makeSessions(
      { description: 'old-one', lastActive: new Date(Date.now() - 3 * 86400000).toISOString() },
    )
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    fireEvent.click(screen.getByText(/Archived/))
    expect(screen.getByText('3d')).toBeInTheDocument()
  })

  it('collapses when header is clicked a second time', () => {
    const archivedSessions = makeSessions({ description: 'toggling' })
    render(
      <Sidebar {...defaultProps} archivedSessions={archivedSessions} />,
    )
    const header = screen.getByText(/Archived/)
    fireEvent.click(header)
    expect(screen.getByText('toggling')).toBeInTheDocument()
    fireEvent.click(header)
    expect(screen.queryByText('toggling')).not.toBeInTheDocument()
  })
})
