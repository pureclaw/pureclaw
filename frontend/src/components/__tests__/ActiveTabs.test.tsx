import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { ActiveTabs } from '../ActiveTabs'
import type { TabInfo } from '../../types'

function makeTabs(...overrides: Partial<TabInfo>[]): TabInfo[] {
  return overrides.map((o, i) => ({
    index: o.index ?? i,
    kind: o.kind ?? 'session:provider',
    name: o.name ?? `tab-${i}`,
    status: o.status ?? 'idle',
    session_id: 'session_id' in o ? (o.session_id ?? null) : `sess-${i}`,
    ...('extModified' in o ? { extModified: o.extModified } : {}),
    ...('stale' in o ? { stale: o.stale } : {}),
    ...('origin' in o ? { origin: o.origin } : {}),
    ...('attachCommand' in o ? { attachCommand: o.attachCommand } : {}),
  }))
}

/** All callback props ActiveTabs requires, with no-op defaults so each
 *  test only overrides the one(s) it asserts on. */
function noopProps() {
  return {
    onSelectTab: () => {},
    onNewTab: () => {},
    onCloseTab: () => {},
    onArchiveTab: () => {},
    onDismiss: () => {},
    onAcknowledge: () => {},
    onRelease: () => {},
  }
}

describe('ActiveTabs', () => {
  it('renders tab rows from mock data', () => {
    const tabs = makeTabs(
      { index: 0, name: 'claude-opus', status: 'running' },
      { index: 1, name: 'bash', status: 'idle' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )

    expect(screen.getByText('claude-opus')).toBeInTheDocument()
    expect(screen.getByText('bash')).toBeInTheDocument()
  })

  it('renders the section header with "Active Tabs"', () => {
    render(
      <ActiveTabs
        tabs={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('Active Tabs')).toBeInTheDocument()
  })

  it('renders a [+] new tab button', () => {
    const onNewTab = vi.fn()
    render(
      <ActiveTabs
        tabs={[]}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={onNewTab}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const btn = screen.getByRole('button', { name: /new tab/i })
    expect(btn).toBeInTheDocument()
    fireEvent.click(btn)
    expect(onNewTab).toHaveBeenCalledTimes(1)
  })

  it('maps running status to a green filled circle icon', () => {
    const tabs = makeTabs({ status: 'running', name: 'run-tab' })
    const { container } = render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    // The running indicator should display the filled circle character
    const indicator = container.querySelector('[data-testid="status-running"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('●') // ●
  })

  it('maps idle status to a gray circle icon', () => {
    const tabs = makeTabs({ status: 'idle', name: 'idle-tab' })
    const { container } = render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const indicator = container.querySelector('[data-testid="status-idle"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('○') // ○
  })

  it('defensive: an UNKNOWN status string renders a fallback glyph instead of crashing', () => {
    // A malformed/forward-incompatible backend status must not crash the render
    // (statusIcon[status] would be undefined → reading .char/.color throws).
    // Cast through unknown to model a wire value outside the TabStatus union.
    const tabs = makeTabs({ index: 0, name: 'weird-tab' })
    tabs[0]!.status = 'totally-bogus' as unknown as TabInfo['status']
    const { container } = render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />,
    )
    // The row still renders (no throw) and shows a status indicator with a
    // sensible fallback glyph rather than blowing up.
    expect(screen.getByText('weird-tab')).toBeInTheDocument()
    const indicator = container.querySelector('[data-testid="status-totally-bogus"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('?')
  })

  it('D4.1: maps exited status to a red X icon', () => {
    const tabs = makeTabs({ status: 'exited', name: 'exit-tab' })
    const { container } = render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />,
    )
    const indicator = container.querySelector('[data-testid="status-exited"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('✕') // ✕
  })

  it('D4.1: maps orphaned status to a red X icon', () => {
    const tabs = makeTabs({ status: 'orphaned', name: 'orphan-tab' })
    const { container } = render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />,
    )
    const indicator = container.querySelector('[data-testid="status-orphaned"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('✕') // ✕
  })

  it('D4.1: an exited tab renders a (disabled, reserved) Restart control and a Dismiss control', () => {
    const tabs = makeTabs({ index: 0, status: 'exited', name: 'exit-tab' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    const restart = screen.getByRole('button', { name: /restart tab/i })
    expect(restart).toBeInTheDocument()
    expect(restart).toBeDisabled()
    expect(screen.getByRole('button', { name: /dismiss tab/i })).toBeInTheDocument()
  })

  it('D4.1: an orphaned tab renders greyed + Dismiss and NOT an enabled Restart', () => {
    const tabs = makeTabs({ index: 0, status: 'orphaned', name: 'orphan-tab' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    const row = screen.getByText('orphan-tab').closest('.agent-row')
    expect(row).toHaveClass('tab-orphaned')
    expect(screen.getByRole('button', { name: /dismiss tab/i })).toBeInTheDocument()
    // No enabled Restart on an orphaned row.
    expect(screen.queryByRole('button', { name: /restart tab/i })).not.toBeInTheDocument()
  })

  it('D4.1: idle/running tabs render neither Dismiss nor Restart', () => {
    const tabs = makeTabs({ index: 0, status: 'running', name: 'run-tab' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByRole('button', { name: /dismiss tab/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /restart tab/i })).not.toBeInTheDocument()
  })

  it('D4.4: Dismiss calls onDismiss with the correct tab index', () => {
    const onDismiss = vi.fn()
    const tabs = makeTabs(
      { index: 0, status: 'exited', name: 'first' },
      { index: 1, status: 'orphaned', name: 'second' },
    )
    render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} onDismiss={onDismiss} />,
    )
    const dismissButtons = screen.getAllByRole('button', { name: /dismiss tab/i })
    fireEvent.click(dismissButtons[1]!)
    expect(onDismiss).toHaveBeenCalledWith(1)
  })

  it('D4.4: Dismiss click does not trigger row selection', () => {
    const onSelectTab = vi.fn()
    const onDismiss = vi.fn()
    const tabs = makeTabs({ index: 3, status: 'exited', name: 'only' })
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        {...noopProps()}
        onSelectTab={onSelectTab}
        onDismiss={onDismiss}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /dismiss tab/i }))
    expect(onDismiss).toHaveBeenCalledWith(3)
    expect(onSelectTab).not.toHaveBeenCalled()
  })

  it('D4.2: an extModified tab renders the edited pill and an Acknowledge control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'edited-tab', extModified: true })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.getByText('edited')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /acknowledge tab/i })).toBeInTheDocument()
  })

  it('D4.2: a tab without extModified shows no edited pill or Acknowledge control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'plain-tab' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByText('edited')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /acknowledge tab/i })).not.toBeInTheDocument()
  })

  it('D4.2: Acknowledge calls onAcknowledge with the correct tab index', () => {
    const onAcknowledge = vi.fn()
    const tabs = makeTabs(
      { index: 0, status: 'idle', name: 'first' },
      { index: 7, status: 'idle', name: 'second', extModified: true },
    )
    render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} onAcknowledge={onAcknowledge} />,
    )
    fireEvent.click(screen.getByRole('button', { name: /acknowledge tab/i }))
    expect(onAcknowledge).toHaveBeenCalledWith(7)
  })

  it('D4.2: Acknowledge click does not trigger row selection', () => {
    const onSelectTab = vi.fn()
    const onAcknowledge = vi.fn()
    const tabs = makeTabs({ index: 2, status: 'idle', name: 'only', extModified: true })
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        {...noopProps()}
        onSelectTab={onSelectTab}
        onAcknowledge={onAcknowledge}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /acknowledge tab/i }))
    expect(onAcknowledge).toHaveBeenCalledWith(2)
    expect(onSelectTab).not.toHaveBeenCalled()
  })

  it('D4.3: a stale tab renders a dimmed/stale cue and holds its last icon', () => {
    const tabs = makeTabs({ index: 0, status: 'running', name: 'stale-tab', stale: true })
    const { container } = render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />,
    )
    const row = screen.getByText('stale-tab').closest('.agent-row')
    expect(row).toHaveClass('tab-stale')
    // The last (running) icon is still shown — no distinct stale glyph.
    expect(container.querySelector('[data-testid="status-running"]')).toBeInTheDocument()
  })

  it('D4.3: a non-stale tab has no stale cue', () => {
    const tabs = makeTabs({ index: 0, status: 'running', name: 'fresh-tab' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    const row = screen.getByText('fresh-tab').closest('.agent-row')
    expect(row).not.toHaveClass('tab-stale')
  })

  it('D4.5: the attach command is rendered as a copyable control for a tab with attachCommand', () => {
    const cmd = 'tmux attach -t canonical-0:win'
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'live-tab', attachCommand: cmd })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    const control = screen.getByRole('button', { name: /copy attach command/i })
    expect(control).toBeInTheDocument()
    // The control carries the command so the user can copy it.
    expect(control).toHaveAttribute('data-attach-command', cmd)
  })

  it('D4.5: a tab without attachCommand shows no copy control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'no-attach', attachCommand: null })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByRole('button', { name: /copy attach command/i })).not.toBeInTheDocument()
  })

  it('D4.6: the origin pill renders the origin', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'origin-tab', origin: 'spawned' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.getByText('spawned')).toBeInTheDocument()
  })

  it('D4.6: a tab without origin shows no origin pill', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'no-origin' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByText(/^(spawned|discovered|adopted)$/)).not.toBeInTheDocument()
  })

  it('D7.4: the origin pill renders "adopted" on an adopted row', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'adopted-tab', origin: 'adopted' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.getByText('adopted')).toBeInTheDocument()
  })

  it('D7.3: an adopted tab renders a Release control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'adopted-tab', origin: 'adopted' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.getByRole('button', { name: /release tab/i })).toBeInTheDocument()
  })

  it('D7.3: a non-adopted tab (spawned) renders NO Release control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'spawned-tab', origin: 'spawned' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByRole('button', { name: /release tab/i })).not.toBeInTheDocument()
  })

  it('D7.3: a tab with no origin renders NO Release control', () => {
    const tabs = makeTabs({ index: 0, status: 'idle', name: 'no-origin' })
    render(<ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} />)
    expect(screen.queryByRole('button', { name: /release tab/i })).not.toBeInTheDocument()
  })

  it('D7.3: Release calls onRelease with the correct tab index', () => {
    const onRelease = vi.fn()
    const tabs = makeTabs(
      { index: 0, status: 'idle', name: 'spawned', origin: 'spawned' },
      { index: 9, status: 'idle', name: 'adopted', origin: 'adopted' },
    )
    render(
      <ActiveTabs tabs={tabs} selectedId={null} {...noopProps()} onRelease={onRelease} />,
    )
    fireEvent.click(screen.getByRole('button', { name: /release tab/i }))
    expect(onRelease).toHaveBeenCalledWith(9)
  })

  it('D7.3: Release click does not trigger row selection', () => {
    const onSelectTab = vi.fn()
    const onRelease = vi.fn()
    const tabs = makeTabs({ index: 4, status: 'idle', name: 'adopted', origin: 'adopted' })
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        {...noopProps()}
        onSelectTab={onSelectTab}
        onRelease={onRelease}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /release tab/i }))
    expect(onRelease).toHaveBeenCalledWith(4)
    expect(onSelectTab).not.toHaveBeenCalled()
  })

  it('shows [raw] badge for shell tabs', () => {
    const tabs = makeTabs(
      { kind: 'shell:bash', name: 'bash-raw' },
      { kind: 'session:provider', name: 'normal-tab' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const badges = screen.getAllByText('raw')
    expect(badges).toHaveLength(1)
  })

  it('does not show [raw] badge for non-shell tabs', () => {
    const tabs = makeTabs({ kind: 'session:provider', name: 'normal-tab' })
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.queryByText('raw')).not.toBeInTheDocument()
  })

  it('calls onSelectTab with tab index when a row is clicked', () => {
    const onSelectTab = vi.fn()
    const tabs = makeTabs(
      { index: 0, name: 'first' },
      { index: 1, name: 'second' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={onSelectTab}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    fireEvent.click(screen.getByText('second'))
    expect(onSelectTab).toHaveBeenCalledWith(1)
  })

  it('highlights the selected tab', () => {
    const tabs = makeTabs(
      { index: 0, name: 'first', session_id: 'sess-0' },
      { index: 1, name: 'second', session_id: 'sess-1' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId="tab:1"
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    // The selected row should have the 'selected' class
    const secondRow = screen.getByText('second').closest('.agent-row')
    expect(secondRow).toHaveClass('selected')
    const firstRow = screen.getByText('first').closest('.agent-row')
    expect(firstRow).not.toHaveClass('selected')
  })

  it('shows status text next to the tab name', () => {
    const tabs = makeTabs(
      { name: 'test-tab', status: 'running' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('Running')).toBeInTheDocument()
  })

  it('shows tab index numbers', () => {
    const tabs = makeTabs(
      { index: 0, name: 'first' },
      { index: 1, name: 'second' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByText('0')).toBeInTheDocument()
    expect(screen.getByText('1')).toBeInTheDocument()
  })

  it('shows a close button on each tab row', () => {
    const tabs = makeTabs(
      { index: 0, name: 'first' },
      { index: 1, name: 'second' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const closeButtons = screen.getAllByRole('button', { name: /close tab/i })
    expect(closeButtons).toHaveLength(2)
  })

  it('calls onCloseTab with tab index when close button is clicked', () => {
    const onCloseTab = vi.fn()
    const tabs = makeTabs(
      { index: 0, name: 'first' },
      { index: 1, name: 'second' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={onCloseTab}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const closeButtons = screen.getAllByRole('button', { name: /close tab/i })
    fireEvent.click(closeButtons[1]!)
    expect(onCloseTab).toHaveBeenCalledWith(1)
  })

  it('close button click does not trigger row selection', () => {
    const onSelectTab = vi.fn()
    const onCloseTab = vi.fn()
    const tabs = makeTabs({ index: 0, name: 'only' })
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={onSelectTab}
        onNewTab={() => {}}
        onCloseTab={onCloseTab}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    const closeBtn = screen.getByRole('button', { name: /close tab/i })
    fireEvent.click(closeBtn)
    expect(onCloseTab).toHaveBeenCalledWith(0)
    expect(onSelectTab).not.toHaveBeenCalled()
  })

  it('shows archive button on session-backed tabs', () => {
    const tabs = makeTabs(
      { index: 0, name: 'session-tab', kind: 'session:provider', session_id: 'sess-0' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.getByRole('button', { name: /archive tab/i })).toBeInTheDocument()
  })

  it('does not show archive button on raw shell tabs', () => {
    const tabs = makeTabs(
      { index: 0, name: 'raw-tab', kind: 'shell:bash', session_id: null },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    expect(screen.queryByRole('button', { name: /archive tab/i })).not.toBeInTheDocument()
  })

  it('calls onArchiveTab with tab index when archive button is clicked', () => {
    const onArchiveTab = vi.fn()
    const tabs = makeTabs(
      { index: 0, name: 'session-tab', kind: 'session:provider', session_id: 'sess-0' },
    )
    render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={onArchiveTab}
        onDismiss={() => {}}
        onAcknowledge={() => {}}
        onRelease={() => {}}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /archive tab/i }))
    expect(onArchiveTab).toHaveBeenCalledWith(0)
  })
})
