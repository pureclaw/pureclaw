export type AgentStatus = 'needs-input' | 'thinking' | 'idle' | 'completed'

export interface Agent {
  id: string
  name: string
  status: AgentStatus
  tokenCount: string
  description?: string
}

// API types matching the Haskell backend

export type HarnessActivity = 'thinking' | 'idle' | 'stopped'

export interface HarnessInfo {
  name: string
  activity: HarnessActivity
}

export interface SessionInfo {
  id: string
  agent: string | null
  runtime: string
  model: string
  lastActive: string
  createdAt: string
  description: string | null
  autoSummary: string | null
  firstMessageSnippet: string | null
  /** Communications channel name of the session origin (e.g. "signal",
   *  "telegram", "cli"), or null when no source was recorded. */
  channel: string | null
  /** Channel user id of the session origin, or null when the channel
   *  carries no user id (e.g. `pureclaw tui`). */
  channelUserId: string | null
}

/** Cascade used to pick the display title for a session.
 *  Order: user-set description → model-generated summary → snippet of
 *  the first user message → agent name → short id prefix. */
export function sessionDisplayTitle(s: SessionInfo): string {
  if (s.description)         return s.description
  if (s.autoSummary)         return s.autoSummary
  if (s.firstMessageSnippet) return s.firstMessageSnippet
  if (s.agent)               return s.agent
  return s.id.slice(0, 12) || 'New session'
}

/** Strip the Anthropic date suffix and verbose family prefix from a
 *  model id so we can fit it in tight UI surfaces. Examples:
 *    claude-sonnet-4-20250514 → sonnet-4
 *    other ids pass through unchanged. */
export function shortenModel(model: string): string {
  const m = model.match(/claude-(\w+-\d+)/)
  return m ? m[1]! : model
}

/** Agent + communications channel formatted as "agent · channel:userId"
 *  (with the middle dot). The model is deliberately omitted — it can change
 *  over a session's lifetime. The channel piece is shown only when the
 *  origin carries a channel user id; sessions with no channel user id
 *  (e.g. `pureclaw tui`) show just the agent. Skips either piece if missing. */
export function sessionSubtitle(s: { agent?: string | null; channel?: string | null; channelUserId?: string | null }): string {
  const parts: string[] = []
  if (s.agent) parts.push(s.agent)
  if (s.channelUserId) parts.push(`${s.channel ?? ''}:${s.channelUserId}`)
  return parts.join(' · ')
}

/** Resolve the display label for a tab. The label is the backing SESSION's
 *  title (so a tab reads identically to its Recent Sessions row); only when no
 *  session resolves do we fall back to the harness `label`, and as an absolute
 *  last resort an ellipsis — NEVER blank. Centralized so every tab-label
 *  consumer (sidebar rows, harness header, chat-header title) agrees. */
export function tabDisplayLabel(tab: TabInfo, session: SessionInfo | null | undefined): string {
  if (session) return sessionDisplayTitle(session)
  return tab.label ?? '…'
}

/** Find the session backing a tab id across both the live (recents) and
 *  archived lists. Returns undefined when the id is null/unknown. */
export function findSession(
  id: string | null | undefined,
  sessions: SessionInfo[],
  archivedSessions: SessionInfo[],
): SessionInfo | undefined {
  if (!id) return undefined
  return sessions.find((s) => s.id === id) ?? archivedSessions.find((s) => s.id === id)
}

/** Liveness of a tab/harness. `exited` (harness process died, window still
 *  present) and `orphaned` (no live window for this id) replace the old
 *  collapsed `crashed` value — the backend now reports them distinctly. */
export type TabStatus = 'running' | 'idle' | 'exited' | 'orphaned'

/** Where a harness came from, surfaced as a small pill. */
export type TabOrigin = 'spawned' | 'discovered' | 'adopted'

export interface TabInfo {
  index: number
  kind: string
  /** Harness-only fallback label (the tmux window/session name), or null for
   *  session-backed tabs. The tab's DISPLAY label is NOT this field — it is
   *  derived from the backing session's title (see `tabDisplayLabel`), so a
   *  session-backed tab reads identically to its Recent Sessions row. This
   *  `label` is only the last-resort fallback for harness tabs whose session
   *  has not (yet) resolved. */
  label: string | null
  status: TabStatus
  session_id: string | null
  /** The harness window's name/session changed out-of-band since PureClaw
   *  last reconciled it. An orthogonal flag (not a liveness state) — shows a
   *  ⚠ "edited" pill + an Acknowledge action. */
  extModified?: boolean
  /** The last reconcile sweep failed for this entry, so its liveness is held
   *  from the previous tick. Renders a subtle dimmed cue, no distinct glyph. */
  stale?: boolean
  /** How the harness entered the registry. */
  origin?: TabOrigin
  /** A copyable `tmux attach -t …` command for live rows, or null when the
   *  tab has no attachable window. */
  attachCommand?: string | null
}

/** An external (unmanaged) tmux window that PureClaw discovered via an
 *  on-demand discovery scan and could be adopted. Transient, metadata-only —
 *  it is NOT a registry entry and carries no capture capability. Mirrors the
 *  backend `DiscoverableWindow` JSON (snake_case `window_name`/`window_index`/
 *  `pane_pid`), mapped to camelCase at the fetch boundary. */
export interface DiscoverableWindow {
  session: string
  windowName: string
  windowIndex: number
  /** The pane's shell PID, or null when tmux reported none. */
  panePid: number | null
}

export interface AgentInfo {
  name: string
  isDefault: boolean
}

export interface TranscriptEntry {
  id: string
  timestamp: string
  direction: 'request' | 'response'
  payload: string
  harness: string | null
  model: string | null
  /** The full, verbatim on-disk transcript.jsonl line for this entry — all 9
   *  `_te_*` fields including `_te_metadata`, byte-faithful to disk. Surfaced in
   *  the "View raw JSON (message)" modal. Required, never optional, per the
   *  governing principle: PureClaw always makes EVERYTHING visible to the user;
   *  raw views must never silently hide fields. */
  raw: string
}

export interface CodeSpan {
  type: 'kw' | 'str' | 'fn' | 'cm' | 'text'
  text: string
}

export interface ToolCallInfo {
  id: string                // stable id (from the provider's tool_use_id when available)
  name: string              // tool name, e.g. "shell"
  input: unknown            // argument payload
  result?: string           // matching tool_result content, pretty-printed
  resultIsError?: boolean
}

export interface MessageContent {
  id?: string              // stable per-block id used for #fragment deep-links
  text?: string
  codeBlock?: CodeSpan[][]
  listItems?: string[]
  orderedItems?: string[]
  collapsedText?: string   // System-prompt block, shown collapsed by default, expandable
  thinkingText?: string    // claude-code "thinking" block, collapsed by default under a "Thinking" label
  rawJson?: string         // raw JSON, hidden by default, toggleable
  toolCall?: ToolCallInfo  // assistant tool invocation (with matched result when available)
}

export interface Message {
  id: string
  /** Raw transcript-entry id (`_te_id`) this row was derived from. Present
   *  on branchable rows (user + assistant); absent on synthesized rows
   *  (e.g. the System prompt row). Used as the branch boundary key. */
  entryId?: string
  agentName: string
  agentStatus: AgentStatus
  timestamp: string
  blocks: MessageContent[]
  isGenerating?: boolean
  meta?: string            // e.g. model name, token usage
  rawJson?: string         // full transcript-entry payload (pretty-printed when JSON)
  /** Marks a TRANSIENT slash-command output bubble (kind:"slash" send
   *  response). These rows are NOT persisted — they never enter the
   *  transcript and vanish on reload. Rendered in a muted "command output"
   *  style with a "command output — not saved" label. */
  slashBubble?: boolean
}
