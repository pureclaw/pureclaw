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
