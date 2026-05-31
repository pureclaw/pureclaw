import { describe, it, expect } from 'vitest'
import { formatTimestamp, transcriptToMessages } from '../App'
import type { TranscriptEntry } from '../types'

describe('formatTimestamp (issue #67: show date AND time, not just time)', () => {
  it('renders YYYY-MM-DD HH:MM:SS in local time', () => {
    // Build a Date from LOCAL components, round-trip through ISO (UTC), and
    // expect the local components back — deterministic in any timezone since
    // both construction and formatting use local time.
    const local = new Date(2024, 5, 15, 13, 5, 9) // 2024-06-15 13:05:09 local
    expect(formatTimestamp(local.toISOString())).toBe('2024-06-15 13:05:09')
  })

  it('zero-pads month, day, hour, minute, and second', () => {
    const local = new Date(2024, 0, 2, 3, 4, 5) // 2024-01-02 03:04:05 local
    expect(formatTimestamp(local.toISOString())).toBe('2024-01-02 03:04:05')
  })

  it('matches the YYYY-MM-DD HH:MM:SS shape', () => {
    expect(formatTimestamp('2024-01-01T00:00:00Z')).toMatch(
      /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/,
    )
  })

  it('transcriptToMessages stamps each message with the date-and-time format', () => {
    const entries: TranscriptEntry[] = [
      {
        id: 'e1',
        direction: 'request',
        payload: 'hello',
        timestamp: '2024-01-01T00:00:00Z',
      } as TranscriptEntry,
    ]
    const msgs = transcriptToMessages(entries)
    expect(msgs.length).toBeGreaterThan(0)
    for (const m of msgs) {
      expect(m.timestamp).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/)
    }
  })
})
