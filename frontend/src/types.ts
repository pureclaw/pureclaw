export type AgentStatus = 'needs-input' | 'thinking' | 'idle' | 'completed'

export interface Agent {
  id: string
  name: string
  status: AgentStatus
  tokenCount: string
  description?: string
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
}

export interface Message {
  id: string
  agentName: string
  agentStatus: AgentStatus
  timestamp: string
  blocks: MessageContent[]
  isGenerating?: boolean
}
