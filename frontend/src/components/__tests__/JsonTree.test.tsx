import { render, fireEvent } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { JsonTree } from '../JsonTree'

describe('JsonTree rendering', () => {
  it('renders primitives with type-specific styling', () => {
    const { container } = render(<JsonTree value={{ s: 'hi', n: 42, b: true, z: null }} />)
    const text = container.textContent ?? ''
    expect(text).toContain('"s"')
    expect(text).toContain('"hi"')
    expect(text).toContain('42')
    expect(text).toContain('true')
    expect(text).toContain('null')
  })

  it('renders multi-line strings with real newlines, not literal \\n', () => {
    const { container } = render(<JsonTree value={{ text: 'line1\nline2\nline3' }} />)
    const text = container.textContent ?? ''
    expect(text).toContain('line1\nline2\nline3')
    expect(text).not.toContain('line1\\nline2')
  })

  it('renders multi-line strings via a <pre> block', () => {
    const { container } = render(<JsonTree value={{ text: 'a\nb' }} />)
    const pre = container.querySelector('.json-string-block')
    expect(pre).not.toBeNull()
    expect(pre!.tagName).toBe('PRE')
    expect(pre!.textContent).toBe('a\nb')
  })

  it('renders short single-line strings inline (no <pre> block)', () => {
    const { container } = render(<JsonTree value={{ name: 'shell' }} />)
    expect(container.querySelector('.json-string-block')).toBeNull()
  })

  it('renders empty objects and arrays compactly', () => {
    const { container } = render(<JsonTree value={{ a: {}, b: [] }} />)
    const text = container.textContent ?? ''
    expect(text).toContain('{}')
    expect(text).toContain('[]')
  })

  it('collapses an object when its toggle is clicked', () => {
    const { container, getAllByRole } = render(
      <JsonTree value={{ outer: { inner: 'v' } }} />,
    )
    expect(container.textContent ?? '').toContain('inner')

    const toggles = getAllByRole('button', { name: /Collapse|Expand/ })
    // first toggle is root object; second is the inner object
    fireEvent.click(toggles[1]!)
    expect(container.textContent ?? '').not.toContain('inner')
  })

  it('collapses an array when its toggle is clicked', () => {
    const { container, getAllByRole } = render(
      <JsonTree value={{ list: ['a', 'b', 'c'] }} />,
    )
    expect(container.textContent ?? '').toContain('"a"')

    const toggles = getAllByRole('button', { name: /Collapse|Expand/ })
    fireEvent.click(toggles[1]!)
    expect(container.textContent ?? '').not.toContain('"a"')
  })

  it('shows item count when an array is collapsed', () => {
    const { getAllByRole, getByText } = render(<JsonTree value={['x', 'y', 'z']} />)
    const toggles = getAllByRole('button', { name: /Collapse|Expand/ })
    fireEvent.click(toggles[0]!)
    expect(getByText(/3 items/)).toBeTruthy()
  })

  it('renders nested arrays and objects', () => {
    const { container } = render(
      <JsonTree value={{ messages: [{ role: 'user', content: 'hi' }] }} />,
    )
    const text = container.textContent ?? ''
    expect(text).toContain('"messages"')
    expect(text).toContain('"role"')
    expect(text).toContain('"user"')
    expect(text).toContain('"content"')
    expect(text).toContain('"hi"')
  })
})
