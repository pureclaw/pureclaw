import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import type {
  ServerEvent,
  ClientOp,
  HelloEvent,
  EntryEvent,
  ActivityEnvelope,
  ReplayEndEvent,
  OverflowEvent,
  ErrorEvent,
} from '../stream'

const __dirname = dirname(fileURLToPath(import.meta.url))
const FIXTURES_DIR = resolve(__dirname, '../../../../test/Frontend/fixtures/stream-events')

function loadFixture(name: string): unknown {
  return JSON.parse(readFileSync(resolve(FIXTURES_DIR, name), 'utf-8'))
}

describe('wire-protocol golden fixtures parse as the declared TS types', () => {
  it('hello.json parses as HelloEvent', () => {
    const ev = loadFixture('hello.json') as ServerEvent
    expect(ev.type).toBe('hello')
    const hello = ev as HelloEvent
    expect(hello.protocolVersion).toBe('v1')
    expect(typeof hello.serverStartedAt).toBe('string')
  })

  it('entry.json parses as EntryEvent with a TranscriptEntry payload', () => {
    const ev = loadFixture('entry.json') as ServerEvent
    expect(ev.type).toBe('entry')
    const entry = ev as EntryEvent
    expect(typeof entry.sessionId).toBe('string')
    expect(typeof entry.entry.id).toBe('string')
    expect(typeof entry.entry.timestamp).toBe('string')
    expect(['request', 'response']).toContain(entry.entry.direction)
    expect(typeof entry.entry.payload).toBe('string')
  })

  it('activity-entry-at.json parses as ActivityEnvelope with kind=entry-at', () => {
    const ev = loadFixture('activity-entry-at.json') as ServerEvent
    expect(ev.type).toBe('activity')
    const env = ev as ActivityEnvelope
    expect(env.activity.kind).toBe('entry-at')
    if (env.activity.kind === 'entry-at') {
      expect(typeof env.activity.timestamp).toBe('string')
    }
  })

  it('activity-harness-status.json parses as ActivityEnvelope with kind=harness-status', () => {
    const ev = loadFixture('activity-harness-status.json') as ServerEvent
    expect(ev.type).toBe('activity')
    const env = ev as ActivityEnvelope
    expect(env.activity.kind).toBe('harness-status')
    if (env.activity.kind === 'harness-status') {
      expect(['thinking', 'idle', 'stopped']).toContain(env.activity.status)
    }
  })

  it('activity-session-created.json parses as ActivityEnvelope with kind=session-created', () => {
    const ev = loadFixture('activity-session-created.json') as ServerEvent
    expect(ev.type).toBe('activity')
    const env = ev as ActivityEnvelope
    expect(env.activity.kind).toBe('session-created')
    if (env.activity.kind === 'session-created') {
      // Snake-case fields — these MUST match the Haskell SessionMeta encoding.
      expect(typeof env.activity.session.id).toBe('string')
      expect(typeof env.activity.session.created_at).toBe('string')
      expect(typeof env.activity.session.last_active).toBe('string')
      expect(typeof env.activity.session.bootstrap_consumed).toBe('boolean')
    }
  })

  it('replay-end.json parses as ReplayEndEvent', () => {
    const ev = loadFixture('replay-end.json') as ServerEvent
    expect(ev.type).toBe('replay-end')
    const replay = ev as ReplayEndEvent
    expect(typeof replay.sessionId).toBe('string')
    // lastReplayedEntryId may be string or null
    expect(['string', 'object']).toContain(typeof replay.lastReplayedEntryId)
  })

  it('overflow.json parses as OverflowEvent', () => {
    const ev = loadFixture('overflow.json') as ServerEvent
    expect(ev.type).toBe('overflow')
    const ovf = ev as OverflowEvent
    expect(ovf.type).toBe('overflow')
  })

  it('error.json parses as ErrorEvent with a known error code', () => {
    const ev = loadFixture('error.json') as ServerEvent
    expect(ev.type).toBe('error')
    const err = ev as ErrorEvent
    expect(typeof err.message).toBe('string')
    expect([
      'invalid-op',
      'invalid-frame',
      'session-not-found',
      'frame-too-large',
      'replay-failed',
      'replay-aborted',
      'internal',
    ]).toContain(err.code)
  })

  it('focus.json parses as ClientOp (focus without since)', () => {
    const op = loadFixture('focus.json') as ClientOp
    expect(op.op).toBe('focus')
    expect(typeof op.sessionId).toBe('string')
    // No `since` on this fixture.
    expect('since' in op).toBe(false)
  })

  it('focus-with-since.json parses as ClientOp (focus with since)', () => {
    const op = loadFixture('focus-with-since.json') as ClientOp
    expect(op.op).toBe('focus')
    if (op.sessionId !== null && 'since' in op) {
      expect(typeof op.since).toBe('string')
    }
  })
})
