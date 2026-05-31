import { describe, it, expect } from 'vitest'
import { sessionSubtitle } from '../types'

// Issue #67 follow-up: the transcript header subtitle should drop the model
// (which can change over a session's lifetime) and instead show the
// communications channel name + user id when one exists, or nothing (just the
// agent) when there is no channel user id (e.g. `pureclaw tui`).
describe('sessionSubtitle (channel + user id, not model)', () => {
  it('renders "agent · channel:userId" when a channel user id exists', () => {
    expect(
      sessionSubtitle({ agent: 'assistant', channel: 'signal', channelUserId: '+15551234567' }),
    ).toBe('assistant · signal:+15551234567')
  })

  it('renders just the agent when there is no channel user id (e.g. tui)', () => {
    expect(sessionSubtitle({ agent: 'assistant', channel: null, channelUserId: null })).toBe(
      'assistant',
    )
  })

  it('renders just "channel:userId" when there is no agent', () => {
    expect(sessionSubtitle({ agent: null, channel: 'telegram', channelUserId: '42' })).toBe(
      'telegram:42',
    )
  })

  it('ignores the model entirely (model present but no channel id → agent only)', () => {
    expect(
      sessionSubtitle({ agent: 'assistant', model: 'claude-sonnet-4-20250514' } as never),
    ).toBe('assistant')
  })

  it('returns an empty string when nothing is available', () => {
    expect(sessionSubtitle({ agent: null, channel: null, channelUserId: null })).toBe('')
  })
})
