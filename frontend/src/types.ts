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

export interface MessageContent {
  text?: string
  codeBlock?: CodeSpan[][]
  listItems?: string[]
  orderedItems?: string[]
  collapsedText?: string   // shown collapsed by default, expandable
  rawJson?: string         // raw JSON, hidden by default, toggleable
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
