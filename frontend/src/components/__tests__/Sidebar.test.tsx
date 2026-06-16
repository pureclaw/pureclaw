import { render, screen, fireEvent, within } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { Sidebar } from '../Sidebar'
import type { SessionInfo, TabInfo } from '../../types'

/** Tabs no longer carry a `name`; the display label derives from the backing
 *  session (else the harness `label` fallback). The old `name` overrides are
 *  mapped onto `label` so these tests, which mostly pass no matching session,
 *  still render the expected row text via the fallback. */
function makeTabs(...overrides: (Partial<TabInfo> & { name?: string })[]): TabInfo[] {
  return overrides.map((o, i) => ({
    index: o.index ?? i,
    kind: o.kind ?? 'session:provider',
    label: o.label ?? o.name ?? `tab-${i}`,
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
    onDismissTab: vi.fn(),
    onAcknowledgeTab: vi.fn(),
    onReleaseTab: vi.fn(),
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

  it('W2.1: renders no Discoverable section and no Scan button (discovery moved into the New-tab form)', () => {
    render(<Sidebar {...defaultProps} />)
    expect(screen.queryByTestId('discoverable-section')).not.toBeInTheDocument()
    expect(screen.queryByText(/Discover/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /scan/i })).not.toBeInTheDocument()
  })

  it('RH.1: harness-kind tabs render under "Running Harnesses", not "Active Tabs"', () => {
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'claude-code-0', kind: 'harness', session_id: 'sess-h' })}
      />,
    )
    // The "Active Tabs" header still exists (kept, but empty for now)...
    expect(screen.getByText('Active Tabs')).toBeInTheDocument()
    // ...and the harness row lives inside the Running Harnesses section.
    const section = screen.getByTestId('running-harnesses-section')
    expect(within(section).getByText('claude-code-0')).toBeInTheDocument()
  })

  it('RH.2: a non-harness tab stays in Active Tabs and not in Running Harnesses', () => {
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'plain-tab', kind: 'session:provider', session_id: 'sess-p' })}
      />,
    )
    expect(screen.queryByTestId('running-harnesses-section')).not.toBeInTheDocument()
    expect(screen.getByText('plain-tab')).toBeInTheDocument()
  })

  it('RH.3: a session backed by a running harness ALSO appears in Recent Sessions', () => {
    // A harness has a controls entry under "Running Harnesses" AND its
    // conversation should be reachable as a normal session row, so the user can
    // jump straight to it. The sidebar no longer de-dupes it out (the backend
    // already keeps non-harness tab sessions out of the recents payload).
    render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'claude-code-0', kind: 'harness', session_id: 'sess-h' })}
        sessions={makeSessions(
          { id: 'sess-h', description: 'harness session' },
          { id: 'sess-p', description: 'plain session' },
        )}
      />,
    )
    // The harness controls row is still present under Running Harnesses, and
    // its label now derives from the backing session's title (identical to its
    // Recent Sessions row) — NOT the harness fallback name.
    const section = screen.getByTestId('running-harnesses-section')
    expect(within(section).getByText('harness session')).toBeInTheDocument()
    // The same session is also listed under Recent Sessions (clickable row), so
    // 'harness session' appears twice across the sidebar.
    expect(screen.getAllByText('harness session').length).toBeGreaterThanOrEqual(2)
    // Unrelated provider sessions are unaffected.
    expect(screen.getByText('plain session')).toBeInTheDocument()
  })

  it('RH.4: the Running Harnesses accordion collapses on click and re-expands when a new harness is added', () => {
    const { rerender } = render(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs({ index: 0, name: 'h0', kind: 'harness', session_id: 's0' })}
      />,
    )
    // Starts expanded → the row is visible.
    expect(screen.getByText('h0')).toBeInTheDocument()
    // User collapses it.
    fireEvent.click(screen.getByText('Running Harnesses'))
    expect(screen.queryByText('h0')).not.toBeInTheDocument()
    // A new harness appears → the section auto-expands.
    rerender(
      <Sidebar
        {...defaultProps}
        tabs={makeTabs(
          { index: 0, name: 'h0', kind: 'harness', session_id: 's0' },
          { index: 1, name: 'h1', kind: 'harness', session_id: 's1' },
        )}
      />,
    )
    expect(screen.getByText('h1')).toBeInTheDocument()
    expect(screen.getByText('h0')).toBeInTheDocument()
  })
})
