import { useState, useEffect, useCallback, useMemo } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { BottomBar } from './components/BottomBar'
import { useHarnesses, useRecentSessions, useTranscript } from './hooks/useApi'
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
  return entries.map((e) => ({
    id: e.id,
    agentName: e.direction === 'request' ? 'You' : (e.harness ?? e.model ?? 'Assistant'),
    agentStatus: e.direction === 'request' ? 'completed' as const : 'completed' as const,
    timestamp: new Date(e.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }),
    blocks: [{ text: e.payload }],
  }))
}

export default function App() {
  const { harnesses } = useHarnesses()
  const { sessions } = useRecentSessions()
  const [selectedId, setSelectedId] = useState<string | null>(selectedIdFromPath)

  const currentSessionId = sessionIdFromSelection(selectedId)
  const { entries, loading } = useTranscript(currentSessionId)
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
