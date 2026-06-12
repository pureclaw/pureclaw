import { describe, it, expect } from 'vitest'
import { transcriptToMessages } from '../App'
import type { TranscriptEntry } from '../types'

// ---------------------------------------------------------------------------
// pureclaw-1xd — "View raw JSON (message)" must show the full verbatim
// transcript.jsonl line (all 9 _te_* fields incl. _te_metadata), not just the
// payload body. transcriptToMessages must therefore set `rawJson` to `e.raw`
// (the byte-faithful on-disk line) rather than `e.payload`.
//
// Governing principle: PureClaw always makes EVERYTHING visible to the user.
// ---------------------------------------------------------------------------

/** A full verbatim line carrying every _te_* field, with `payload` holding only
 *  the inner request/response body the message-extraction logic parses. */
function fullLine(id: string, direction: 'request' | 'response', payload: string): string {
  return JSON.stringify({
    _te_correlationId: 'corr-' + id,
    _te_direction: direction === 'request' ? 'Request' : 'Response',
    _te_durationMs: 42,
    _te_harness: null,
    _te_id: id,
    _te_metadata: { source: 'sender-1' },
    _te_model: 'sonnet',
    _te_payload: payload,
    _te_timestamp: '2024-01-01T00:00:00Z',
  })
}

function userEntry(id: string, text: string): TranscriptEntry {
  const payload = JSON.stringify({
    model: 'sonnet',
    messages: [{ role: 'user', content: [{ type: 'text', text }] }],
  })
  return {
    id,
    timestamp: '2024-01-01T00:00:00Z',
    direction: 'request',
    payload,
    harness: null,
    model: 'sonnet',
    raw: fullLine(id, 'request', payload),
  }
}

function assistantEntry(id: string, text: string): TranscriptEntry {
  const payload = JSON.stringify({ content: [{ type: 'text', text }] })
  return {
    id,
    timestamp: '2024-01-01T00:00:01Z',
    direction: 'response',
    payload,
    harness: null,
    model: 'sonnet',
    raw: fullLine(id, 'response', payload),
  }
}

describe('transcriptToMessages rawJson = e.raw (pureclaw-1xd)', () => {
  it('sets the user row rawJson to the full verbatim line, not the payload', () => {
    const e = userEntry('te-1', 'hello')
    const user = transcriptToMessages([e]).find((m) => m.id === 'te-1-user')
    expect(user).toBeTruthy()
    expect(user!.rawJson).toBe(e.raw)
    expect(user!.rawJson).not.toBe(e.payload)
  })

  it('sets the assistant row rawJson to the full verbatim line', () => {
    const e = assistantEntry('te-2', 'hi there')
    const asst = transcriptToMessages([e]).find((m) => m.id === 'te-2')
    expect(asst).toBeTruthy()
    expect(asst!.rawJson).toBe(e.raw)
  })

  it('sets a non-JSON request row rawJson to the full verbatim line', () => {
    const payload = 'plain harness send'
    const e: TranscriptEntry = {
      id: 'te-3',
      timestamp: '2024-01-01T00:00:00Z',
      direction: 'request',
      payload,
      harness: null,
      model: null,
      raw: fullLine('te-3', 'request', payload),
    }
    const row = transcriptToMessages([e]).find((m) => m.id === 'te-3')
    expect(row).toBeTruthy()
    expect(row!.rawJson).toBe(e.raw)
  })

  it('sets a non-JSON response row rawJson to the full verbatim line', () => {
    const payload = 'plain harness output'
    const e: TranscriptEntry = {
      id: 'te-4',
      timestamp: '2024-01-01T00:00:01Z',
      direction: 'response',
      payload,
      harness: 'claude-code',
      model: null,
      raw: fullLine('te-4', 'response', payload),
    }
    const row = transcriptToMessages([e]).find((m) => m.id === 'te-4')
    expect(row).toBeTruthy()
    expect(row!.rawJson).toBe(e.raw)
  })

  it('the synthesized System-prompt row still omits rawJson', () => {
    const payload = JSON.stringify({
      model: 'sonnet',
      system_prompt: 'You are helpful.',
      messages: [{ role: 'user', content: [{ type: 'text', text: 'hi' }] }],
    })
    const e: TranscriptEntry = {
      id: 'te-5',
      timestamp: '2024-01-01T00:00:00Z',
      direction: 'request',
      payload,
      harness: null,
      model: 'sonnet',
      raw: fullLine('te-5', 'request', payload),
    }
    const sysRow = transcriptToMessages([e]).find((m) => m.id === 'te-5-sys')
    expect(sysRow).toBeTruthy()
    expect(sysRow!.rawJson).toBeUndefined()
  })
})
