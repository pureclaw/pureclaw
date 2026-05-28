import { useState, useEffect, useCallback, useMemo, useRef } from 'react'
import { TopBar } from './components/TopBar'
import { Sidebar } from './components/Sidebar'
import { ChatArea } from './components/ChatArea'
import { NewTabComposer } from './components/NewTabComposer'
import { useTranscript, useSendMessage, useAgents, setSessionPrompt, setSessionArchived, setSessionDescription, closeTab } from './hooks/useApi'
import { useListsStream } from './hooks/useListsStream'
import { useNewTabSpec } from './hooks/useNewTabSpec'
import { useTranscriptStream, reconcileEntries } from './hooks/useTranscriptStream'
import { useSessionActivityStream } from './hooks/useSessionActivityStream'
import { streamClient } from './lib/streamClient'
import type { Message, MessageContent, TranscriptEntry, ToolCallInfo } from './types'

/** Parse the current URL path into a selectedId, or null for root. */
function selectedIdFromPath(): string | null {
  const path = window.location.pathname
  const m = path.match(/^\/(harness|session|tab)\/(.+)$/)
  if (m) return `${m[1]}:${m[2]}`
  return null
}

/** Convert a selectedId back to a URL path. */
function pathFromSelectedId(selectedId: string | null): string {
  if (!selectedId) return '/'
  const [type, ...rest] = selectedId.split(':')
  return `/${type}/${rest.join(':')}`
}

/** Extract session ID from selectedId, or null if not a session selection.
 *  For tab selections, looks up the tab's session_id from the tabs array. */
function sessionIdFromSelection(
  selectedId: string | null,
  tabs: import('./types').TabInfo[],
): string | null {
  if (!selectedId) return null
  const [type, ...rest] = selectedId.split(':')
  if (type === 'session') return rest.join(':')
  if (type === 'tab') {
    const tabIndex = parseInt(rest.join(':'), 10)
    const tab = tabs.find((t) => t.index === tabIndex)
    return tab?.session_id ?? null
  }
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
    const rawJson = e.payload

    if (e.direction === 'request') {
      const parsed = tryParseJson(e.payload)
      if (parsed) {
        // Extract system prompt as a separate collapsed message (only first occurrence).
        // The synthesized row deliberately omits rawJson: clicking JSON here would
        // show the full request payload (system + messages + model + ...) rather
        // than the system prompt, which is misleading. The user message that
        // follows from the same entry carries the same payload.
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
                rawJson,
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
                rawJson,
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
          rawJson,
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
          rawJson,
        })
      } else {
        // Non-JSON response (e.g. harness output)
        messages.push({
          id: e.id,
          agentName: e.harness ?? e.model ?? 'Assistant',
          agentStatus: 'completed',
          timestamp: ts,
          blocks: [{ id: 'raw-' + e.id, text: e.payload }],
          rawJson,
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
  const { tabs, recentSessions: rawSessions, archivedSessions } = useListsStream()
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

  const handleUnarchiveSession = useCallback(async (id: string) => {
    await setSessionArchived(id, false)
  }, [])

  // Optimistic overlay for description edits — we apply the user's text
  // immediately so the chat header doesn't flicker back to the fallback
  // while the next poll arrives. Cleared per-id when the polled value
  // catches up. Stores empty string to mean "cleared".
  const [descriptionOverrides, setDescriptionOverrides] = useState<Map<string, string>>(() => new Map())
  const handleSetDescription = useCallback(async (id: string, description: string) => {
    const trimmed = description.trim()
    setDescriptionOverrides((m) => {
      const next = new Map(m)
      next.set(id, trimmed)
      return next
    })
    const ok = await setSessionDescription(id, trimmed.length > 0 ? trimmed : null)
    if (!ok) {
      setDescriptionOverrides((m) => {
        const next = new Map(m)
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

  const currentSessionId = sessionIdFromSelection(selectedId, tabs)
  const { entries: httpEntries, loading, refresh } = useTranscript(currentSessionId)
  // Live WebSocket tail: merges its own HTTP-seed + WS-delivered entries.
  // We additionally reconcile against the manual-refresh `useTranscript` view
  // so behavior is unchanged when the WS connection is unavailable.
  const { entries: streamEntries } = useTranscriptStream(currentSessionId)
  const { sessions: sessionActivity } = useSessionActivityStream(currentSessionId)
  const entries = useMemo(() => {
    if (streamEntries.length === 0) return httpEntries
    let merged: TranscriptEntry[] = httpEntries
    for (const e of streamEntries) merged = reconcileEntries(merged, e)
    return merged
  }, [httpEntries, streamEntries])
  const { send, sending } = useSendMessage(currentSessionId, refresh)
  const [pendingMessage, setPendingMessage] = useState<string | null>(null)
  // Model id to render as the agentName for the optimistic pending-thinking
  // block. Captured at send-time from composerSpec (compose-send flow) or
  // selectedSession (existing-session send). Cleared together with
  // pendingMessage once the real transcript catches up.
  const [pendingMessageModel, setPendingMessageModel] = useState<string | null>(null)
  const entryCountAtSend = useRef(0)
  const transcriptMessages = useMemo(() => transcriptToMessages(entries), [entries])

  // Is the currently-focused session processing a request right now?
  // Sourced from the live activity stream: provider sessions emit this
  // from doCompletion's bracket; harness sessions emit this from the
  // 2s probe loop. Drives both the sidebar spinner (already wired in
  // Sidebar.tsx) and the bottom-of-chat thinking indicator below.
  const sessionIsThinking = currentSessionId !== null
    && sessionActivity?.[currentSessionId]?.harness === 'thinking'

  // Combine transcript messages with a thinking indicator at the bottom.
  // Two cases compose to render the indicator:
  //   1. Local optimistic: the LOCAL tab just sent a message — show
  //      `pending-user` + `pending-thinking` immediately so the user
  //      sees their typed message echoed before the HTTP POST returns.
  //   2. Remote-driven: some OTHER tab/device sent a message on the
  //      same session — `pendingMessage` is null but the broker's
  //      SaHarnessStatus thinking event reached us via WS. Render just
  //      a `remote-thinking` block so the user can see the session is
  //      currently busy.
  // The two are mutually exclusive in the messages array (case 1 takes
  // precedence) so the indicator never duplicates.
  // Model id to display on the thinking indicator. Prefer the explicit
  // pending-thinking model captured at send-time (handles the brand-new
  // session case where the recents list doesn't yet include this session
  // and selectedSession?.model is null); fall back to the most recent
  // assistant message's agentName (which is itself the model id thanks
  // to transcriptToMessages); finally fall back to "Assistant".
  const thinkingAgentName = (() => {
    if (pendingMessageModel) return pendingMessageModel
    for (let i = transcriptMessages.length - 1; i >= 0; i--) {
      const m = transcriptMessages[i]!
      if (m.agentName && m.agentName !== 'You' && m.agentName !== 'Assistant') {
        return m.agentName
      }
    }
    return rawSessions.find((s) => s.id === currentSessionId)?.model ?? 'Assistant'
  })()

  const messages = useMemo(() => {
    const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    if (pendingMessage) {
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
          agentName: thinkingAgentName,
          agentStatus: 'thinking' as const,
          timestamp: now,
          blocks: [],
          isGenerating: true,
        },
      ]
    }
    if (sessionIsThinking) {
      return [
        ...transcriptMessages,
        {
          id: 'remote-thinking',
          agentName: thinkingAgentName,
          agentStatus: 'thinking' as const,
          timestamp: now,
          blocks: [],
          isGenerating: true,
        },
      ]
    }
    return transcriptMessages
  }, [transcriptMessages, pendingMessage, sessionIsThinking, thinkingAgentName])

  // Clear pending message when transcript gains new entries after the send
  useEffect(() => {
    if (pendingMessage && entries.length > entryCountAtSend.current) {
      setPendingMessage(null)
      setPendingMessageModel(null)
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
    if (currentSessionId && archivedSessions.some((s) => s.id === currentSessionId)) {
      await setSessionArchived(currentSessionId, false)
    }
    entryCountAtSend.current = entries.length
    // Capture the model so the pending-thinking block can label itself
    // with the actual model id instead of the generic "Assistant".
    const sessionModel = sessions.find((s) => s.id === currentSessionId)?.model
      ?? archivedSessions.find((s) => s.id === currentSessionId)?.model
      ?? null
    setPendingMessageModel(sessionModel)
    setPendingMessage(message)
    send(message)
  }, [send, entries.length, customPromptFile, currentSessionId, archivedSessions, sessions])

  // Compose mode is implicit: selectedId === null means "no tab focused,
  // show the inline new-tab composer in the ChatArea". Clicking the "New
  // tab" button just clears the selection — there's no separate modal
  // or composing flag.
  //
  // 'newTabFocusTick' increments on every click. ChatArea uses it as a
  // useEffect dep to focus the message textarea after the click — even
  // when already in compose mode (in which case the inComposeMode-based
  // effect would not re-fire and the button click would have stolen
  // focus).
  const [newTabFocusTick, setNewTabFocusTick] = useState(0)
  const handleNewTab = useCallback(() => {
    setSelectedId(null)
    setNewTabFocusTick((n) => n + 1)
    window.history.pushState(null, '', '/')
    setCustomPromptFile(null)
  }, [])

  // Shared composer state. Lives in App so that both the inline panel
  // (in ChatArea's messages region) and the existing bottom chat input
  // can read from a single source of truth — the panel renders config
  // fields, the bottom input drives the create-and-send flow on submit.
  const composerSpec = useNewTabSpec()
  const composing = selectedId === null

  // The transcript refresh callback is bound to whichever session is
  // currently focused. We keep the latest one in a ref so that the
  // compose-send flow — which switches the focus mid-flight — can call
  // the *new* session's refresh once the first-message LLM call returns.
  const refreshRef = useRef<() => void>(() => {})
  useEffect(() => { refreshRef.current = refresh }, [refresh])

  const handleComposerSend = useCallback(
    async (message: string) => {
      const body = composerSpec.buildBody()
      const res = await fetch('/api/tabs/new', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (!res.ok) return
      const tab = await res.json() as import('./hooks/useApi').NewTabResponse

      // Pick a permanent, session-id-keyed selectedId rather than
      // `tab:N`. Two reasons:
      //
      //   1. `sessionIdFromSelection('tab:N', tabs)` requires `tabs` to
      //      contain index N. In gateway mode the server's _fe_listTabs
      //      is currently `pure []`, so every WS lists snapshot delivers
      //      empty tabs — `tab:N` can never resolve and every
      //      session-bound hook is permanently bound to null.
      //
      //   2. The session id (e.g. `20260528-163436-088`) IS permanent —
      //      it survives reloads and is bookmarkable. The tab index is
      //      ephemeral state held only on the server until the next
      //      restart.
      //
      // Eagerly focus the WS before issuing POST /send so the server's
      // _conn_focus matches when doCompletion publishes its first entry.
      if (tab.session_id) {
        streamClient().focus(tab.session_id)
      }

      // Switch to the new session immediately after creation so the
      // composer disappears and the main window begins tracking the
      // new session. The first-message send below blocks on the LLM
      // response — doing it before the switch would leave the composer
      // visible for the entire LLM completion.
      const newId = tab.session_id ? `session:${tab.session_id}` : `tab:${tab.tab_index}`
      const trimmed = message.trim()
      const sendFirst = trimmed.length > 0
      if (sendFirst) {
        // Mirror the first message locally so the new session's
        // transcript shows it immediately (instead of a blank screen
        // until the send completes and the next transcript refresh
        // lands).
        entryCountAtSend.current = 0
        // The session isn't yet in the recents list (empty transcript),
        // so selectedSession?.model isn't available. Use the model the
        // composer just submitted.
        setPendingMessageModel(composerSpec.model || null)
        setPendingMessage(trimmed)
      }
      setSelectedId(newId)
      window.history.pushState(null, '', pathFromSelectedId(newId))
      setCustomPromptFile(null)

      if (sendFirst && tab.session_id) {
        try {
          await fetch(`/api/sessions/${encodeURIComponent(tab.session_id)}/send`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ message: trimmed }),
          })
        } catch {
          // Tab created; the message failed. The user can retry from
          // the new tab's transcript view.
        }
        // After the LLM call returns, refresh the now-focused
        // transcript so the user message + assistant reply land in
        // place of the optimistic pending pair.
        refreshRef.current()
      }
    },
    [composerSpec],
  )

  // Sync state from browser back/forward navigation
  useEffect(() => {
    const onPopState = () => setSelectedId(selectedIdFromPath())
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [])

  const handleSelectTab = useCallback((index: number) => {
    const newId = `tab:${index}`
    setSelectedId(newId)
    window.history.pushState(null, '', pathFromSelectedId(newId))
  }, [])

  const handleSelectSession = useCallback((id: string) => {
    const newId = `session:${id}`
    setSelectedId(newId)
    window.history.pushState(null, '', pathFromSelectedId(newId))
  }, [])

  // L1/L2: Close a tab (session-backed or raw shell).
  // The backend handles save + cleanup; the frontend just deselects if needed.
  const handleCloseTab = useCallback(async (index: number) => {
    await closeTab(index)
    // If the closed tab was selected, clear the selection
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      window.history.pushState(null, '', '/')
    }
  }, [selectedId])

  // L4: Archive a running session — close tab first, then archive.
  const handleArchiveTab = useCallback(async (index: number) => {
    const tab = tabs.find((t) => t.index === index)
    if (!tab) return
    // Close the tab first (backend saves session state)
    await closeTab(index)
    // If session-backed, archive the session so it moves to Archived
    if (tab.session_id) {
      await setSessionArchived(tab.session_id, true)
    }
    // If the archived tab was selected, clear the selection
    if (selectedId === `tab:${index}`) {
      setSelectedId(null)
      window.history.pushState(null, '', '/')
    }
  }, [tabs, selectedId])

  // Derive a display agent for the chat area from the selection
  const displayAgent = selectedId
    ? deriveAgent(selectedId, tabs, sessions)
    : null

  const taskTitle = displayAgent?.name ?? 'PureClaw'

  // Compute session stats from transcript entries
  const sessionStats = useMemo(() => computeSessionStats(entries), [entries])
  const selectedSession = useMemo(() => {
    const base = sessions.find((s) => s.id === currentSessionId)
      ?? archivedSessions.find((s) => s.id === currentSessionId)
      ?? null
    if (!base) return null
    const override = descriptionOverrides.get(base.id)
    return override === undefined
      ? base
      : { ...base, description: override.length > 0 ? override : null }
  }, [sessions, archivedSessions, currentSessionId, descriptionOverrides])

  return (
    <>
      <TopBar taskTitle={taskTitle} />
      <div className="flex flex-1 min-h-0">
        <Sidebar
          tabs={tabs}
          sessions={sessions}
          archivedSessions={archivedSessions}
          selectedId={selectedId}
          sessionActivity={sessionActivity}
          onSelectTab={handleSelectTab}
          onSelectSession={handleSelectSession}
          onNewTab={handleNewTab}
          onArchiveSession={handleArchiveSession}
          onUnarchiveSession={handleUnarchiveSession}
          onCloseTab={handleCloseTab}
          onArchiveTab={handleArchiveTab}
        />
        <ChatArea
          selectedAgent={displayAgent ?? { id: 'none', name: 'PureClaw', status: 'idle', tokenCount: '0' }}
          selectedSession={selectedSession}
          onSetDescription={handleSetDescription}
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
          composerControls={composing ? {
            panel: <NewTabComposer spec={composerSpec} />,
            kind: composerSpec.kind,
            valid: composerSpec.validationError === null,
            onSubmit: handleComposerSend,
          } : null}
          newTabFocusTick={newTabFocusTick}
          selectedId={selectedId}
        />
      </div>
    </>
  )
}

function deriveAgent(
  selectedId: string,
  tabs: import('./types').TabInfo[],
  sessions: import('./types').SessionInfo[],
) {
  const [type, ...rest] = selectedId.split(':')
  const id = rest.join(':')

  if (type === 'tab') {
    const tabIndex = parseInt(id, 10)
    const tab = tabs.find((t) => t.index === tabIndex)
    if (!tab) return null
    return {
      id: `tab:${tab.index}`,
      name: tab.name,
      status: tab.status === 'running' ? 'thinking' as const
        : tab.status === 'idle' ? 'idle' as const
        : 'completed' as const,
      tokenCount: '',
    }
  }

  if (type === 'session') {
    const s = sessions.find((s) => s.id === id)
    if (!s) return null
    // Display name preference: agent name → model id → (last resort)
    // session id. The session id is a timestamp-like string like
    // "20260522-..." — useless to surface in a chat input placeholder,
    // so we only fall back to it when both agent and model are missing.
    const displayName = s.agent ?? (s.model && s.model.length > 0 ? s.model : s.id)
    return {
      id: `session:${s.id}`,
      name: displayName,
      status: 'completed' as const,
      tokenCount: '',
      description: s.model,
    }
  }

  return null
}
