import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { BottomBar } from './components/BottomBar'
import { useHarnesses, useRecentSessions, useTranscript, useSendMessage } from './hooks/useApi'
import type { Message, TranscriptEntry } from './types'

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

/** Convert transcript entries to the Message format ChatArea expects. */
function transcriptToMessages(entries: TranscriptEntry[]): Message[] {
  const messages: Message[] = []
  const seenSystemPrompts = new Set<string>()

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
            blocks: [{ collapsedText: sysPrompt }],
          })
        }
        // Extract only the LAST message from the request — it's the new
        // one being sent. Earlier messages in the array are conversation
        // history already represented by previous transcript entries.
        const msgs = parsed.messages as Array<{ role: string; content: Array<{ type: string; text?: string; name?: string; input?: unknown }> }> | undefined
        if (msgs && msgs.length > 0) {
          const msg = msgs[msgs.length - 1]!
          const textParts = extractTextFromContent(msg.content)
          const toolCalls = extractToolCalls(msg.content)
          if (msg.role === 'user') {
            if (textParts) {
              messages.push({
                id: e.id + '-user',
                agentName: 'You',
                agentStatus: 'completed',
                timestamp: ts,
                blocks: [{ text: textParts }],
                meta: parsed.model as string | undefined,
              })
            }
          } else if (msg.role === 'assistant') {
            const blocks: import('./types').MessageContent[] = []
            if (textParts) blocks.push({ text: textParts })
            for (const tc of toolCalls) blocks.push({ text: tc })
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
          blocks: [{ text: e.payload }],
        })
      }
    } else {
      // Response
      const parsed = tryParseJson(e.payload)
      if (parsed) {
        const content = parsed.content as Array<{ type: string; text?: string; name?: string; id?: string; input?: unknown }> | undefined
        const textParts = extractTextFromContent(content)
        const toolCalls = extractToolCalls(content)
        const usage = parsed.usage as { input_tokens?: number; output_tokens?: number } | undefined
        const usageMeta = usage
          ? `${usage.input_tokens ?? 0} in / ${usage.output_tokens ?? 0} out tokens`
          : undefined

        const blocks: import('./types').MessageContent[] = []
        if (textParts) blocks.push({ text: textParts })
        for (const tc of toolCalls) blocks.push({ text: tc })
        if (blocks.length === 0) blocks.push({ text: '(empty response)' })

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
          blocks: [{ text: e.payload }],
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

function extractToolCalls(content: Array<{ type: string; name?: string; id?: string; input?: unknown }> | undefined): string[] {
  if (!content) return []
  return content
    .filter((b) => b.type === 'tool_use' && b.name)
    .map((b) => `Tool call: ${b.name}`)
}

function computeSessionStats(entries: TranscriptEntry[]): { tokensUsed: number } {
  let tokensUsed = 0
  for (const e of entries) {
    if (e.direction !== 'response') continue
    const parsed = tryParseJson(e.payload)
    if (!parsed) continue
    const usage = parsed.usage as { input_tokens?: number; output_tokens?: number } | undefined
    if (usage) {
      tokensUsed += (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0)
    }
  }
  return { tokensUsed }
}

export default function App() {
  const { harnesses } = useHarnesses()
  const { sessions } = useRecentSessions()
  const [selectedId, setSelectedId] = useState<string | null>(selectedIdFromPath)

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

  const handleSend = useCallback((message: string) => {
    entryCountAtSend.current = entries.length
    setPendingMessage(message)
    send(message)
  }, [send, entries.length])

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
  const selectedAgent = selectedId
    ? deriveAgent(selectedId, harnesses, sessions)
    : null

  const taskTitle = selectedAgent?.name ?? 'PureClaw'

  // Compute session stats from transcript entries
  const sessionStats = useMemo(() => computeSessionStats(entries), [entries])
  const selectedSession = sessions.find((s) => s.id === currentSessionId)

  return (
    <>
      <TopBar taskTitle={taskTitle} />
      <div className="flex flex-1 min-h-0">
        <Sidebar
          harnesses={harnesses}
          sessions={sessions}
          selectedId={selectedId}
          onSelect={handleSelect}
        />
        <div className="flex-1 flex flex-col min-w-0">
          <ChatArea
            selectedAgent={selectedAgent ?? { id: 'none', name: 'PureClaw', status: 'idle', tokenCount: '0' }}
            messages={messages}
            loading={loading}
            onSend={currentSessionId ? handleSend : undefined}
            sending={sending}
          />
          <BottomBar
            tokensUsed={sessionStats.tokensUsed}
            contextWindow={0}
            sessionStart={selectedSession?.createdAt ?? null}
            running={sending}
          />
        </div>
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
