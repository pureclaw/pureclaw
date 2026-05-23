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
  }))
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
      />,
    )
    const indicator = container.querySelector('[data-testid="status-idle"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('○') // ○
  })

  it('maps crashed status to a red X icon', () => {
    const tabs = makeTabs({ status: 'crashed', name: 'crash-tab' })
    const { container } = render(
      <ActiveTabs
        tabs={tabs}
        selectedId={null}
        onSelectTab={() => {}}
        onNewTab={() => {}}
        onCloseTab={() => {}}
        onArchiveTab={() => {}}
      />,
    )
    const indicator = container.querySelector('[data-testid="status-crashed"]')
    expect(indicator).toBeInTheDocument()
    expect(indicator!.textContent).toBe('✕') // ✕
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
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /archive tab/i }))
    expect(onArchiveTab).toHaveBeenCalledWith(0)
  })
})
