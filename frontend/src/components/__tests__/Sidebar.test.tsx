import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { Sidebar } from '../Sidebar'
import type { SessionInfo, TabInfo } from '../../types'

function makeTabs(...overrides: Partial<TabInfo>[]): TabInfo[] {
  return overrides.map((o, i) => ({
    index: o.index ?? i,
    kind: o.kind ?? 'session:provider',
    name: o.name ?? `tab-${i}`,
    status: o.status ?? 'idle',
    session_id: o.session_id ?? `sess-${i}`,
  }))
}

function makeSessions(...overrides: Partial<SessionInfo>[]): SessionInfo[] {
  return overrides.map((o, i) => ({
    id: o.id ?? `session-${i}`,
    agent: o.agent ?? null,
    runtime: o.runtime ?? 'session:provider',
    model: o.model ?? '',
    lastActive: o.lastActive ?? new Date().toISOString(),
    createdAt: o.createdAt ?? new Date().toISOString(),
    description: o.description ?? null,
    autoSummary: o.autoSummary ?? null,
    firstMessageSnippet: o.firstMessageSnippet ?? null,
    channel: o.channel ?? null,
    channelUserId: o.channelUserId ?? null,
  }))
}

describe('Sidebar lifecycle transitions', () => {
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

  it('passes onCloseTab to ActiveTabs so close buttons appear', () => {
    const onCloseTab = vi.fn()
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'tab-a' })}
        onCloseTab={onCloseTab}
      />,
    )
    const closeBtn = screen.getByRole('button', { name: /close tab/i })
    fireEvent.click(closeBtn)
    expect(onCloseTab).toHaveBeenCalledWith(0)
  })

  it('passes onArchiveTab to ActiveTabs for session-backed tabs', () => {
    const onArchiveTab = vi.fn()
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'session-tab', kind: 'session:provider', session_id: 'sess-0' })}
        onArchiveTab={onArchiveTab}
      />,
    )
    const archiveBtn = screen.getByRole('button', { name: /archive tab/i })
    fireEvent.click(archiveBtn)
    expect(onArchiveTab).toHaveBeenCalledWith(0)
  })

  it('clicking an archived session selects it without unarchiving', () => {
    const onSelectSession = vi.fn()
    const archivedSessions = makeSessions({ id: 'arch-1', description: 'old session' })
    render(
      <Sidebar
        {...defaultProps}
        archivedSessions={archivedSessions}
        onSelectSession={onSelectSession}
      />,
    )
    // Expand the archived section
    fireEvent.click(screen.getByText(/Archived/))
    // Click on the archived session row
    fireEvent.click(screen.getByText('old session'))
    expect(onSelectSession).toHaveBeenCalledWith('arch-1')
  })
})
