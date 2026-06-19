import { render } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { ActivityDot } from '../StatusDot'

describe('ActivityDot', () => {
  it('renders a needs-input activity with the dot-needs class', () => {
    const { container } = render(<ActivityDot activity={'needs-input'} />)
    expect(container.firstChild).toHaveClass('dot-needs')
  })

  it('renders a thinking activity with the dot-thinking class', () => {
    const { container } = render(<ActivityDot activity={'thinking'} />)
    expect(container.firstChild).toHaveClass('dot-thinking')
  })

  it('renders an idle activity with the dot-idle class', () => {
    const { container } = render(<ActivityDot activity={'idle'} />)
    expect(container.firstChild).toHaveClass('dot-idle')
  })

  it('renders a stopped activity with the dot-completed class', () => {
    const { container } = render(<ActivityDot activity={'stopped'} />)
    expect(container.firstChild).toHaveClass('dot-completed')
  })
})
