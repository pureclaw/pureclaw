// Wire-protocol TypeScript types for the live transcript streaming WebSocket.
// Hand-mirrored from the Haskell ADTs in `PureClaw.Frontend.Stream`.
//
// IMPORTANT: discriminants are intentionally asymmetric. Server -> client
// frames use `type`; client -> server frames use `op`. Keeping them distinct
// guards against accidental cross-dispatch during refactors.

import type { HarnessActivity, SessionInfo, TranscriptEntry } from '../types'
import type { TabInfoWire } from '../hooks/useApi'

// -- Server -> Client ---------------------------------------------------------

export interface HelloEvent {
  type: 'hello'
  protocolVersion: 'v1'
  /** ISO-8601 timestamp; clients use changes here to detect server restarts. */
  serverStartedAt: string
}

export interface EntryEvent {
  type: 'entry'
  sessionId: string
  entry: TranscriptEntry
}

/** Emitted when a streaming entry's payload grows (Task 3). The entry already
 *  exists in the transcript (same id); consumers should replace it in place. */
export interface EntryUpdateEvent {
  type: 'entry-update'
  sessionId: string
  entry: TranscriptEntry
}

/**
 * `SessionMeta` shape as emitted by the Haskell backend's `ToJSON SessionMeta`
 * (snake_case fields). Distinct from `SessionInfo` (camelCase) used by REST
 * endpoints; the activity event carries the raw on-disk meta.
 */
export interface StreamSessionMeta {
  id: string
  agent?: string
  runtime: string
  model: string
  channel: string
  created_at: string
  last_active: string
  bootstrap_consumed: boolean
}

export type ActivityEvent =
  | { kind: 'entry-at'; timestamp: string }
  | { kind: 'harness-status'; status: HarnessActivity }
  | { kind: 'session-created'; session: StreamSessionMeta }

export interface ActivityEnvelope {
  type: 'activity'
  sessionId: string
  activity: ActivityEvent
}

export interface ReplayEndEvent {
  type: 'replay-end'
  sessionId: string
  lastReplayedEntryId: string | null
}

export interface OverflowEvent {
  type: 'overflow'
}

export type StreamErrorCode =
  | 'invalid-op'
  | 'invalid-frame'
  | 'session-not-found'
  | 'frame-too-large'
  | 'replay-failed'
  | 'replay-aborted'
  | 'internal'

export interface ErrorEvent {
  type: 'error'
  code: StreamErrorCode
  message: string
}

export interface ListsEvent {
  type: 'lists'
  // The WS `lists` frame carries tabs as raw backend JSON (snake_case health
  // fields), exactly like the REST `/api/tabs` payload — NOT the camelCase
  // `TabInfo` the UI renders. Typing it as `TabInfoWire[]` lets `useListsStream`
  // funnel through the single `mapTabInfo` boundary with no `as unknown` cast.
  tabs: TabInfoWire[]
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  // Sessions backing an open tab. Deduped out of `recentSessions` above (a tab's
  // session is not also a Recent Sessions row); carried here so the frontend can
  // still join a tab to its session for the label/edit-pencil.
  tabSessions: SessionInfo[]
}

export type ServerEvent =
  | HelloEvent
  | EntryEvent
  | EntryUpdateEvent
  | ActivityEnvelope
  | ReplayEndEvent
  | OverflowEvent
  | ErrorEvent
  | ListsEvent

// -- Client -> Server ---------------------------------------------------------

export type ClientOp =
  | { op: 'focus'; sessionId: string | null }
  | { op: 'focus'; sessionId: string; since: string }

// -- Stream client + hook contracts ------------------------------------------

export type StreamStatus =
  | 'connecting'
  | 'live'
  | 'reconnecting'
  | 'replaying'
  | 'closed'

export interface ListsSnapshot {
  // Raw wire tabs (snake_case), mapped to `TabInfo` at the `useListsStream`
  // boundary via `mapTabInfo` — the single mapping point.
  tabs: TabInfoWire[]
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  // Sessions backing an open tab — see `ListsEvent.tabSessions`.
  tabSessions: SessionInfo[]
}

export interface StreamClient {
  /** Current connection status. */
  readonly status: StreamStatus
  /** Focus a session (optionally requesting replay from `since`). */
  focus(sessionId: string | null, since?: string): void
  /** Subscribe to entries for the currently-focused session. */
  onEntry(cb: (e: TranscriptEntry) => void): () => void
  /** Subscribe to activity events for ALL sessions. */
  onActivity(cb: (sessionId: string, a: ActivityEvent) => void): () => void
  /** Subscribe to sidebar list snapshots (tabs + sessions). */
  onLists(cb: (snapshot: ListsSnapshot) => void): () => void
  /** Subscribe to status changes. */
  onStatusChange(cb: (s: StreamStatus) => void): () => void
  /** Last error message, or null when no terminal error has occurred. */
  lastError(): string | null
}

export interface SessionActivityState {
  harness: HarnessActivity | null
  /** Count of entries since last focus or since mount. */
  unread: number
  /** ISO timestamp of most recent entry, or null. */
  lastEntryAt: string | null
}

export interface UseTranscriptStream {
  entries: TranscriptEntry[]
  status: StreamStatus
  lastError: string | null
}

export interface UseSessionActivityStream {
  sessions: Record<string, SessionActivityState>
  status: StreamStatus
  lastError: string | null
}
