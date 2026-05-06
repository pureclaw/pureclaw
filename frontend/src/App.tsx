import { useState, useEffect, useCallback, useMemo } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { BottomBar } from './components/BottomBar'
import { useHarnesses, useRecentSessions, useTranscript, useSendMessage } from './hooks/useApi'
import { mockStats } from './data/mockData'
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
        // Extract user messages
        const msgs = parsed.messages as Array<{ role: string; content: Array<{ type: string; text?: string; name?: string; input?: unknown }> }> | undefined
        if (msgs) {
          for (const msg of msgs) {
            const textParts = extractTextFromContent(msg.content)
            const toolCalls = extractToolCalls(msg.content)
            if (msg.role === 'user') {
              if (textParts) {
                messages.push({
                  id: e.id + '-user-' + messages.length,
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
                  id: e.id + '-asst-' + messages.length,
                  agentName: e.model ?? 'Assistant',
                  agentStatus: 'completed',
                  timestamp: ts,
                  blocks,
                })
              }
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

export default function App() {
  const { harnesses } = useHarnesses()
  const { sessions } = useRecentSessions()
  const [selectedId, setSelectedId] = useState<string | null>(selectedIdFromPath)

  const currentSessionId = sessionIdFromSelection(selectedId)
  const { entries, loading, refresh } = useTranscript(currentSessionId)
  const { send, sending } = useSendMessage(currentSessionId, refresh)
  const messages = useMemo(() => transcriptToMessages(entries), [entries])

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
        <ChatArea
          selectedAgent={selectedAgent ?? { id: 'none', name: 'PureClaw', status: 'idle', tokenCount: '0' }}
          messages={messages}
          loading={loading}
          onSend={currentSessionId ? send : undefined}
          sending={sending}
        />
      </div>
      <BottomBar
        {...mockStats}
        active={harnesses.filter((h) => h.activity === 'thinking').length}
        idle={harnesses.filter((h) => h.activity === 'idle').length}
        done={harnesses.filter((h) => h.activity === 'stopped').length}
      />
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
