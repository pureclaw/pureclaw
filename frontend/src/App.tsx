import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { useHarnesses, useRecentSessions, useTranscript, useSendMessage, useAgents, createSession, setSessionPrompt, setSessionArchived } from './hooks/useApi'
import type { Message, MessageContent, TranscriptEntry, ToolCallInfo } from './types'

/** Parse the current URL path into a selectedId, or null for root. */
function selectedIdFromPath(): string | null {
  const path = window.location.pathname
  const m = path.match(/^\/(harness|session)\/(.+)$/)
  if (m) return `${m[1]}:${m[2]}`
  return null
}

/** Convert a selectedId back to a URL path. */
function pathFromSelectedId(selectedId: string | null): string {
  if (!selectedId) return '/'
  const [type, ...rest] = selectedId.split(':')
  return `/${type}/${rest.join(':')}`
}

/** Extract session ID from selectedId, or null if not a session selection. */
function sessionIdFromSelection(selectedId: string | null): string | null {
  if (!selectedId) return null
  const [type, ...rest] = selectedId.split(':')
  if (type === 'session') return rest.join(':')
  return null
}

interface ToolResultRecord {
  content: string
  isError?: boolean
}

/** Index every tool_use_id we have a tool_result for, scanning the full transcript. */
function buildToolResultIndex(entries: TranscriptEntry[]): Map<string, ToolResultRecord> {
  const map = new Map<string, ToolResultRecord>()
  for (const e of entries) {
    if (e.direction !== 'request') continue
    const parsed = tryParseJson(e.payload)
    if (!parsed) continue
    const msgs = parsed.messages as Array<{ role: string; content: unknown }> | undefined
    if (!msgs) continue
    for (const m of msgs) {
      if (m.role !== 'user' || !Array.isArray(m.content)) continue
      for (const b of m.content as Array<{ type: string; tool_use_id?: string; content?: unknown; is_error?: boolean }>) {
        if (b.type === 'tool_result' && b.tool_use_id) {
          map.set(b.tool_use_id, {
            content: formatToolResultContent(b.content),
            isError: b.is_error,
          })
        }
      }
    }
  }
  return map
}

function formatToolResultContent(content: unknown): string {
  if (content == null) return ''
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (b && typeof b === 'object') {
          const o = b as { type?: string; text?: string }
          if (o.type === 'text' && typeof o.text === 'string') return o.text
        }
        return JSON.stringify(b)
      })
      .join('\n')
  }
  return JSON.stringify(content, null, 2)
}

/** Convert transcript entries to the Message format ChatArea expects. */
function transcriptToMessages(entries: TranscriptEntry[]): Message[] {
  const messages: Message[] = []
  const seenSystemPrompts = new Set<string>()
  const toolResults = buildToolResultIndex(entries)

  for (const e of entries) {
    const ts = new Date(e.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })

    if (e.direction === 'request') {
      const parsed = tryParseJson(e.payload)
      if (parsed) {
        // Extract system prompt as a separate collapsed message (only first occurrence)
        const sysPrompt = parsed.system_prompt as string | undefined
        if (sysPrompt && !seenSystemPrompts.has(sysPrompt)) {
          seenSystemPrompts.add(sysPrompt)
          messages.push({
            id: e.id + '-sys',
            agentName: 'System',
            agentStatus: 'idle',
            timestamp: ts,
            blocks: [{ id: 'sys-' + e.id, collapsedText: sysPrompt }],
          })
        }
        // Extract only the LAST message from the request — it's the new
        // one being sent. Earlier messages in the array are conversation
        // history already represented by previous transcript entries.
        const msgs = parsed.messages as Array<{ role: string; content: Array<{ type: string; text?: string; name?: string; id?: string; input?: unknown }> }> | undefined
        if (msgs && msgs.length > 0) {
          const msg = msgs[msgs.length - 1]!
          const textParts = extractTextFromContent(msg.content)
          const toolCalls = extractToolCalls(msg.content, toolResults)
          if (msg.role === 'user') {
            if (textParts) {
              messages.push({
                id: e.id + '-user',
                agentName: 'You',
                agentStatus: 'completed',
                timestamp: ts,
                blocks: [{ id: 'u-' + e.id, text: textParts }],
                meta: parsed.model as string | undefined,
              })
            }
          } else if (msg.role === 'assistant') {
            const blocks: MessageContent[] = []
            if (textParts) blocks.push({ id: 'a-' + e.id + '-text', text: textParts })
            for (const tc of toolCalls) blocks.push({ id: 'tc-' + tc.id, toolCall: tc })
            if (blocks.length > 0) {
              messages.push({
                id: e.id + '-asst',
                agentName: e.model ?? 'Assistant',
                agentStatus: 'completed',
                timestamp: ts,
                blocks,
              })
            }
          }
        }
      } else {
        // Non-JSON request (e.g. harness send)
        messages.push({
          id: e.id,
          agentName: 'You',
          agentStatus: 'completed',
          timestamp: ts,
          blocks: [{ id: 'raw-' + e.id, text: e.payload }],
        })
      }
    } else {
      // Response
      const parsed = tryParseJson(e.payload)
      if (parsed) {
        const content = parsed.content as Array<{ type: string; text?: string; name?: string; id?: string; input?: unknown }> | undefined
        const textParts = extractTextFromContent(content)
        const toolCalls = extractToolCalls(content, toolResults)
        const usage = parsed.usage as { input_tokens?: number; output_tokens?: number } | undefined
        const usageMeta = usage
          ? `${usage.input_tokens ?? 0} in / ${usage.output_tokens ?? 0} out tokens`
          : undefined

        const blocks: MessageContent[] = []
        if (textParts) blocks.push({ id: 'r-' + e.id + '-text', text: textParts })
        for (const tc of toolCalls) blocks.push({ id: 'tc-' + tc.id, toolCall: tc })
        if (blocks.length === 0) blocks.push({ id: 'r-' + e.id + '-empty', text: '(empty response)' })

        messages.push({
          id: e.id,
          agentName: e.model ?? e.harness ?? 'Assistant',
          agentStatus: 'completed',
          timestamp: ts,
          blocks,
          meta: usageMeta,
        })
      } else {
        // Non-JSON response (e.g. harness output)
        messages.push({
          id: e.id,
          agentName: e.harness ?? e.model ?? 'Assistant',
          agentStatus: 'completed',
          timestamp: ts,
          blocks: [{ id: 'raw-' + e.id, text: e.payload }],
        })
      }
    }
  }

  return messages
}

function tryParseJson(s: string): Record<string, unknown> | null {
  try {
    const v = JSON.parse(s)
    return typeof v === 'object' && v !== null ? v : null
  } catch {
    return null
  }
}

function extractTextFromContent(content: Array<{ type: string; text?: string }> | undefined): string | null {
  if (!content) return null
  const texts = content
    .filter((b) => b.type === 'text' && b.text)
    .map((b) => b.text!)
  return texts.length > 0 ? texts.join('\n') : null
}

function extractToolCalls(
  content: Array<{ type: string; name?: string; id?: string; input?: unknown }> | undefined,
  results: Map<string, ToolResultRecord>,
): ToolCallInfo[] {
  if (!content) return []
  return content
    .filter((b) => b.type === 'tool_use' && b.name)
    .map((b, i) => {
      const id = b.id ?? `unknown-${i}`
      const r = results.get(id)
      return {
        id,
        name: b.name!,
        input: b.input,
        result: r?.content,
        resultIsError: r?.isError,
      }
    })
}

function computeSessionStats(entries: TranscriptEntry[]): { tokensUsed: number; contextWindow: number } {
  let realTokens = 0
  let hasRealUsage = false
  let lastModel: string | null = null

  // The most useful token metric is the last request's input_tokens
  // (= full context size) + cumulative output_tokens across all responses.
  // When real usage data isn't available, estimate from payload text.
  let lastInputTokens = 0
  let totalOutputTokens = 0
  let estimatedTokens = 0

  for (const e of entries) {
    const parsed = tryParseJson(e.payload)
    if (!parsed) {
      // Non-JSON payload — estimate from raw text
      estimatedTokens += Math.ceil(e.payload.length / 4)
      continue
    }

    if (e.direction === 'request') {
      if (parsed.model) lastModel = parsed.model as string
    } else if (e.direction === 'response') {
      if (parsed.model) lastModel = parsed.model as string
      const usage = parsed.usage as { input_tokens?: number; output_tokens?: number } | undefined
      if (usage && (usage.input_tokens != null || usage.output_tokens != null)) {
        hasRealUsage = true
        lastInputTokens = usage.input_tokens ?? lastInputTokens
        totalOutputTokens += usage.output_tokens ?? 0
      } else {
        // Estimate output tokens from response text content
        const content = parsed.content as Array<{ type: string; text?: string }> | undefined
        if (content) {
          for (const block of content) {
            if (block.type === 'text' && block.text) {
              estimatedTokens += Math.ceil(block.text.length / 4)
            }
          }
        }
      }
    }
  }

  if (hasRealUsage) {
    // last input_tokens reflects total context size, plus all output tokens
    realTokens = lastInputTokens + totalOutputTokens
    return { tokensUsed: realTokens, contextWindow: modelContextWindow(lastModel) }
  }

  // Fallback: estimate from all payload text (~4 chars per token)
  // For requests, the last one's messages array size is the best proxy
  // for current context usage
  let lastRequestTextLen = 0
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i]!.direction === 'request') {
      lastRequestTextLen = entries[i]!.payload.length
      break
    }
  }
  const estimatedContext = Math.ceil(lastRequestTextLen / 4)
  return { tokensUsed: estimatedContext + estimatedTokens, contextWindow: modelContextWindow(lastModel) }
}

/** Best-effort context window lookup for common models. Returns 0 if unknown. */
function modelContextWindow(model: string | null): number {
  if (!model) return 0
  const m = model.toLowerCase()

  // Anthropic Claude
  if (m.includes('claude') && m.includes('opus')) return 200000
  if (m.includes('claude') && m.includes('sonnet')) return 200000
  if (m.includes('claude') && m.includes('haiku')) return 200000

  // OpenAI
  if (m.includes('gpt-4o')) return 128000
  if (m.includes('gpt-4-turbo')) return 128000
  if (m.includes('gpt-4')) return 8192
  if (m.includes('gpt-3.5')) return 16385
  if (m.includes('o1') || m.includes('o3') || m.includes('o4')) return 200000

  // Ollama / common open models
  if (m.includes('llama3') || m.includes('llama-3')) return 8192
  if (m.includes('llama4') || m.includes('llama-4')) return 10000000
  if (m.includes('gemma3') || m.includes('gemma-3')) return 128000
  if (m.includes('gemma4') || m.includes('gemma-4')) return 128000
  if (m.includes('gemma2') || m.includes('gemma-2')) return 8192
  if (m.includes('mistral')) return 32768
  if (m.includes('mixtral')) return 32768
  if (m.includes('qwen')) return 32768
  if (m.includes('phi')) return 128000
  if (m.includes('deepseek')) return 128000
  if (m.includes('command-r')) return 128000
  if (m.includes('codestral')) return 32768

  return 0
}

export default function App() {
  const { harnesses } = useHarnesses()
  const { sessions: rawSessions } = useRecentSessions()
  const { agents } = useAgents()
  const [selectedId, setSelectedId] = useState<string | null>(selectedIdFromPath)
  const [selectedAgent, setSelectedAgent] = useState<string | null>(null)
  const [customPromptFile, setCustomPromptFile] = useState<{ name: string; content: string } | null>(null)

  // Optimistic strip — when the user archives a session, hide it from the
  // sidebar immediately rather than waiting for the next 3s poll. Server-side
  // filtering will catch up; the set just accumulates a few session ids in
  // the meantime, which is fine.
  const [archivedOptimistically, setArchivedOptimistically] = useState<Set<string>>(() => new Set())
  const sessions = useMemo(
    () => rawSessions.filter((s) => !archivedOptimistically.has(s.id)),
    [rawSessions, archivedOptimistically],
  )

  const handleArchiveSession = useCallback(async (id: string) => {
    setArchivedOptimistically((s) => {
      const next = new Set(s)
      next.add(id)
      return next
    })
    const ok = await setSessionArchived(id, true)
    if (!ok) {
      // Backend rejected — restore the row so the user can see and retry.
      setArchivedOptimistically((s) => {
        const next = new Set(s)
        next.delete(id)
        return next
      })
    }
  }, [])

  // Initialize selectedAgent from default agent once agents load
  useEffect(() => {
    if (selectedAgent === null && agents.length > 0) {
      const defaultAgent = agents.find((a) => a.isDefault)
      setSelectedAgent(defaultAgent?.name ?? agents[0]?.name ?? null)
    }
  }, [agents, selectedAgent])

  const currentSessionId = sessionIdFromSelection(selectedId)
  const { entries, loading, refresh } = useTranscript(currentSessionId)
  const { send, sending } = useSendMessage(currentSessionId, refresh)
  const [pendingMessage, setPendingMessage] = useState<string | null>(null)
  const entryCountAtSend = useRef(0)
  const transcriptMessages = useMemo(() => transcriptToMessages(entries), [entries])

  // Combine transcript messages with optimistic pending message + thinking indicator
  const messages = useMemo(() => {
    if (!pendingMessage) return transcriptMessages
    const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    return [
      ...transcriptMessages,
      {
        id: 'pending-user',
        agentName: 'You',
        agentStatus: 'completed' as const,
        timestamp: now,
        blocks: [{ text: pendingMessage }],
      },
      {
        id: 'pending-thinking',
        agentName: 'Assistant',
        agentStatus: 'thinking' as const,
        timestamp: now,
        blocks: [],
        isGenerating: true,
      },
    ]
  }, [transcriptMessages, pendingMessage])

  // Clear pending message when transcript gains new entries after the send
  useEffect(() => {
    if (pendingMessage && entries.length > entryCountAtSend.current) {
      setPendingMessage(null)
    }
  }, [entries.length, pendingMessage])

  const handleSend = useCallback(async (message: string) => {
    // Upload custom prompt before the first message in the session
    if (customPromptFile && currentSessionId && entries.length === 0) {
      // Derive agent name from filename: "my-agent.md" → "my-agent"
      const name = customPromptFile.name.replace(/\.[^.]+$/, '')
      await setSessionPrompt(currentSessionId, customPromptFile.content, name)
      setCustomPromptFile(null)
    }
    entryCountAtSend.current = entries.length
    setPendingMessage(message)
    send(message)
  }, [send, entries.length, customPromptFile, currentSessionId])

  const handleNewSession = useCallback(async () => {
    const session = await createSession(selectedAgent || undefined, customPromptFile?.content)
    if (session) {
      const newId = `session:${session.id}`
      setSelectedId(newId)
      window.history.pushState(null, '', pathFromSelectedId(newId))
      setCustomPromptFile(null)
    }
  }, [selectedAgent, customPromptFile])

  // Sync state from browser back/forward navigation
  useEffect(() => {
    const onPopState = () => setSelectedId(selectedIdFromPath())
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  const handleSelect = useCallback((type: 'harness' | 'session', id: string) => {
    const newId = `${type}:${id}`
    setSelectedId(newId)
    window.history.pushState(null, '', pathFromSelectedId(newId))
  }, [])

  // Derive a display agent for the chat area from the selection
  const displayAgent = selectedId
    ? deriveAgent(selectedId, harnesses, sessions)
    : null

  const taskTitle = displayAgent?.name ?? 'PureClaw'

  // Compute session stats from transcript entries
  const sessionStats = useMemo(() => computeSessionStats(entries), [entries])
  const selectedSession = sessions.find((s) => s.id === currentSessionId)

  return (
    <>
      <TopBar taskTitle={taskTitle} onNewSession={handleNewSession} />
      <div className="flex flex-1 min-h-0">
        <Sidebar
          harnesses={harnesses}
          sessions={sessions}
          selectedId={selectedId}
          onSelect={handleSelect}
          onArchiveSession={handleArchiveSession}
        />
        <ChatArea
          selectedAgent={displayAgent ?? { id: 'none', name: 'PureClaw', status: 'idle', tokenCount: '0' }}
          messages={messages}
          loading={loading}
          onSend={currentSessionId ? handleSend : undefined}
          sending={sending}
          tokensUsed={sessionStats.tokensUsed}
          contextWindow={sessionStats.contextWindow}
          sessionStart={selectedSession?.createdAt ?? null}
          agents={agents}
          currentAgent={selectedAgent}
          onAgentChange={setSelectedAgent}
          customPromptFile={customPromptFile}
          onCustomPromptFile={setCustomPromptFile}
        />
      </div>
    </>
  )
}

function deriveAgent(
  selectedId: string,
  harnesses: import('./types').HarnessInfo[],
  sessions: import('./types').SessionInfo[],
) {
  const [type, ...rest] = selectedId.split(':')
  const id = rest.join(':')

  if (type === 'harness') {
    const h = harnesses.find((h) => h.name === id)
    if (!h) return null
    return {
      id: `harness:${h.name}`,
      name: h.name,
      status: h.activity === 'thinking' ? 'thinking' as const
        : h.activity === 'idle' ? 'idle' as const
        : 'completed' as const,
      tokenCount: '',
    }
  }

  if (type === 'session') {
    const s = sessions.find((s) => s.id === id)
    if (!s) return null
    return {
      id: `session:${s.id}`,
      name: s.agent ?? s.id,
      status: 'completed' as const,
      tokenCount: '',
      description: s.model,
    }
  }

  return null
}
