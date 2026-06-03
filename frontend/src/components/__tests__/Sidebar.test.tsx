import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { Sidebar } from '../Sidebar'
import type { DiscoverableWindow, SessionInfo, TabInfo } from '../../types'

function makeWindows(...overrides: Partial<DiscoverableWindow>[]): DiscoverableWindow[] {
  return overrides.map((o, i) => ({
    session: o.session ?? 'work',
    windowName: o.windowName ?? `win-${i}`,
    windowIndex: o.windowIndex ?? i,
    panePid: 'panePid' in o ? (o.panePid ?? null) : 1000 + i,
  }))
}

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
    discoverableWindows: [] as DiscoverableWindow[],
    selectedId: null as string | null,
    onSelectTab: vi.fn(),
    onSelectSession: vi.fn(),
    onNewTab: vi.fn(),
    onArchiveSession: vi.fn(),
    onUnarchiveSession: vi.fn(),
    onCloseTab: vi.fn(),
    onArchiveTab: vi.fn(),
    onDismissTab: vi.fn(),
    onAcknowledgeTab: vi.fn(),
    onReleaseTab: vi.fn(),
    onScanDiscoverable: vi.fn(),
    onAdoptWindow: vi.fn(),
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

  it('truncates the channel:userId subtitle to one line and shows the full text on hover', () => {
    const subtitle = 'assistant · signal:+15551234567890'
    render(
      <Sidebar
        {...defaultProps}
        sessions={makeSessions({
          id: 'sess-sig',
          agent: 'assistant',
          channel: 'signal',
          channelUserId: '+15551234567890',
        })}
      />,
    )
    const el = screen.getByText(subtitle)
    // Single-line clipping (Tailwind `truncate` = overflow-hidden + nowrap + ellipsis)
    expect(el.className).toContain('truncate')
    // Full, untruncated value available on hover
    expect(el.getAttribute('title')).toBe(subtitle)
  })

  it('shows the subtitle for a session that has only a channel user id (no agent/model)', () => {
    render(
      <Sidebar
        {...defaultProps}
        sessions={makeSessions({
          id: 'sess-tui',
          agent: null,
          model: '',
          channel: 'telegram',
          channelUserId: '42',
        })}
      />,
    )
    expect(screen.getByText('telegram:42')).toBeTruthy()
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

  it('D7.3: passes onReleaseTab to ActiveTabs so adopted rows get a Release control', () => {
    const onReleaseTab = vi.fn()
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'adopted-tab' }).map((t) => ({ ...t, origin: 'adopted' as const }))}
        onReleaseTab={onReleaseTab}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /release tab/i }))
    expect(onReleaseTab).toHaveBeenCalledWith(0)
  })
})

describe('Sidebar DiscoverableSection (D7.1/D7.2)', () => {
  const defaultProps = {
    tabs: [] as TabInfo[],
    sessions: [] as SessionInfo[],
    archivedSessions: [] as SessionInfo[],
    discoverableWindows: [] as DiscoverableWindow[],
    selectedId: null as string | null,
    onSelectTab: vi.fn(),
    onSelectSession: vi.fn(),
    onNewTab: vi.fn(),
    onArchiveSession: vi.fn(),
    onUnarchiveSession: vi.fn(),
    onCloseTab: vi.fn(),
    onArchiveTab: vi.fn(),
    onDismissTab: vi.fn(),
    onAcknowledgeTab: vi.fn(),
    onReleaseTab: vi.fn(),
    onScanDiscoverable: vi.fn(),
    onAdoptWindow: vi.fn(),
  }

  it('D7.1: hidden when there are no discoverable windows', () => {
    render(<Sidebar {...defaultProps} discoverableWindows={[]} />)
    expect(screen.queryByTestId('discoverable-section')).not.toBeInTheDocument()
  })

  it('D7.1: a Scan control is always available even when empty', () => {
    const onScanDiscoverable = vi.fn()
    render(<Sidebar {...defaultProps} onScanDiscoverable={onScanDiscoverable} />)
    const scan = screen.getByRole('button', { name: /scan/i })
    fireEvent.click(scan)
    expect(onScanDiscoverable).toHaveBeenCalledTimes(1)
  })

  it('D7.1: shows a counted header and is collapsed by default (rows hidden)', () => {
    render(
      <Sidebar
        {...defaultProps}
        discoverableWindows={makeWindows({ windowName: 'editor' }, { windowName: 'logs' })}
      />,
    )
    expect(screen.getByTestId('discoverable-section')).toBeInTheDocument()
    expect(screen.getByText(/Discoverable \(2\)/)).toBeInTheDocument()
    // Collapsed by default — the candidate rows are not rendered yet.
    expect(screen.queryByText('work:editor')).not.toBeInTheDocument()
  })

  it('D7.1: expanding reveals session:window rows', () => {
    render(
      <Sidebar
        {...defaultProps}
        discoverableWindows={makeWindows({ session: 'work', windowName: 'editor' })}
      />,
    )
    fireEvent.click(screen.getByText(/Discoverable \(1\)/))
    expect(screen.getByText('work:editor')).toBeInTheDocument()
  })

  it('D7.2: clicking Adopt shows a consent confirmation naming the trust consequence', () => {
    render(
      <Sidebar
        {...defaultProps}
        discoverableWindows={makeWindows({ session: 'work', windowName: 'editor' })}
      />,
    )
    fireEvent.click(screen.getByText(/Discoverable \(1\)/))
    fireEvent.click(screen.getByRole('button', { name: /^adopt$/i }))
    // The consent text must name the trust consequence (manage + capture output).
    expect(screen.getByText(/manage it and capture its output/i)).toBeInTheDocument()
  })

  it('D7.2: confirming the consent calls onAdoptWindow(session, window)', () => {
    const onAdoptWindow = vi.fn()
    render(
      <Sidebar
        {...defaultProps}
        discoverableWindows={makeWindows({ session: 'work', windowName: 'editor' })}
        onAdoptWindow={onAdoptWindow}
      />,
    )
    fireEvent.click(screen.getByText(/Discoverable \(1\)/))
    fireEvent.click(screen.getByRole('button', { name: /^adopt$/i }))
    fireEvent.click(screen.getByRole('button', { name: /confirm adopt/i }))
    expect(onAdoptWindow).toHaveBeenCalledWith('work', 'editor')
  })

  it('D7.2: cancelling the consent does NOT call onAdoptWindow', () => {
    const onAdoptWindow = vi.fn()
    render(
      <Sidebar
        {...defaultProps}
        discoverableWindows={makeWindows({ session: 'work', windowName: 'editor' })}
        onAdoptWindow={onAdoptWindow}
      />,
    )
    fireEvent.click(screen.getByText(/Discoverable \(1\)/))
    fireEvent.click(screen.getByRole('button', { name: /^adopt$/i }))
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }))
    expect(onAdoptWindow).not.toHaveBeenCalled()
    // The confirmation is dismissed.
    expect(screen.queryByText(/manage it and capture its output/i)).not.toBeInTheDocument()
  })
})
