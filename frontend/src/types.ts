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

/** Agent + short model formatted as "agent · sonnet-4" (with the
 *  middle dot). Skips either piece if it's missing. */
export function sessionSubtitle(s: { agent?: string | null; model?: string | null }): string {
  const parts: string[] = []
  if (s.agent) parts.push(s.agent)
  if (s.model) parts.push(shortenModel(s.model))
  return parts.join(' · ')
}

export type TabStatus = 'running' | 'idle' | 'crashed'

export interface TabInfo {
  index: number
  kind: string
  name: string
  status: TabStatus
  session_id: string | null
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
  collapsedText?: string   // shown collapsed by default, expandable
  rawJson?: string         // raw JSON, hidden by default, toggleable
  toolCall?: ToolCallInfo  // assistant tool invocation (with matched result when available)
}

export interface Message {
  id: string
  agentName: string
  agentStatus: AgentStatus
  timestamp: string
  blocks: MessageContent[]
  isGenerating?: boolean
  meta?: string            // e.g. model name, token usage
}
