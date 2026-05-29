import { useState, useRef, useEffect, useCallback } from 'react'
import { createPortal } from 'react-dom'
import type { Agent, AgentInfo, Message, MessageContent, CodeSpan, ToolCallInfo, SessionInfo } from '../types'
import { JsonTree } from './JsonTree'
import { sessionDisplayTitle, sessionSubtitle, shortenModel } from '../types'
import { StatusDot } from './StatusDot'
import { BottomBar } from './BottomBar'

/** Click-to-edit chat-header title. Displays the cascade
 *  (description → autoSummary → snippet → agent name → id prefix);
 *  clicking enters edit mode with the description prefilled.
 *  Enter / blur saves, Escape cancels. Empty input clears the
 *  description, restoring the fallback chain. */
function EditableSessionTitle({
  session,
  onSetDescription,
}: {
  session: SessionInfo
  onSetDescription: (id: string, description: string) => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)

  const startEditing = () => {
    setDraft(session.description ?? '')
    setEditing(true)
  }
  useEffect(() => {
    if (editing) {
      inputRef.current?.focus()
      inputRef.current?.select()
    }
  }, [editing])

  const commit = () => {
    if (!editing) return
    setEditing(false)
    // Only fire the API call when the value actually changed; otherwise
    // a blur with no edit is a silent no-op.
    if (draft.trim() !== (session.description ?? '').trim()) {
      onSetDescription(session.id, draft)
    }
  }
  const cancel = () => setEditing(false)

  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter')       { e.preventDefault(); commit() }
    else if (e.key === 'Escape') { e.preventDefault(); cancel() }
  }

  if (editing) {
    return (
      <input
        ref={inputRef}
        className="editable-title-input"
        value={draft}
        placeholder={sessionDisplayTitle(session)}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={onKeyDown}
        aria-label="Session title"
      />
    )
  }

  return (
    <button
      className="editable-title"
      title="Click to set a session title"
      onClick={startEditing}
    >
      <span className="editable-title-text">{sessionDisplayTitle(session)}</span>
      <svg
        className="editable-title-pencil"
        width="11" height="11" viewBox="0 0 16 16" fill="none"
        stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d="M11 2 L14 5 L5 14 L2 14 L2 11 Z" />
      </svg>
    </button>
  )
}

/** Per the "Context Reachability" rule in DESIGN.md: every addressable block
 *  reacts to the URL fragment so any tool call, system prompt, or message can
 *  be linked directly. Returns whether `anchorId` is currently targeted and
 *  scrolls the ref into view when it becomes targeted. */
function useFragmentAnchor<T extends HTMLElement>(anchorId: string | undefined, ref: React.RefObject<T | null>): boolean {
  const [targeted, setTargeted] = useState(
    () => typeof window !== 'undefined' && anchorId != null && window.location.hash === `#${anchorId}`,
  )
  useEffect(() => {
    if (!anchorId) return
    const check = () => {
      const match = window.location.hash === `#${anchorId}`
      setTargeted(match)
      if (match) ref.current?.scrollIntoView({ block: 'center' })
    }
    check()
    window.addEventListener('hashchange', check)
    return () => window.removeEventListener('hashchange', check)
  }, [anchorId, ref])
  return targeted
}

/** Best-effort clipboard copy that survives non-secure contexts. Returns a
 *  Promise<boolean> that resolves true if either the modern Clipboard API
 *  or the legacy execCommand path succeeded. */
async function copyTextToClipboard(text: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Fall through to the execCommand fallback (permissions / non-secure
      // context / Firefox-on-some-pages all reject the same way).
    }
  }
  return execCommandCopy(text)
}

function execCommandCopy(text: string): boolean {
  const ta = document.createElement('textarea')
  ta.value = text
  // Off-screen but still focusable.
  ta.style.position = 'fixed'
  ta.style.top = '0'
  ta.style.left = '0'
  ta.style.opacity = '0'
  ta.style.pointerEvents = 'none'
  ta.setAttribute('readonly', '')
  document.body.appendChild(ta)
  ta.select()
  let ok = false
  try {
    ok = document.execCommand('copy')
  } catch {
    ok = false
  }
  document.body.removeChild(ta)
  return ok
}

function copyAnchorLink(anchorId: string) {
  const url = `${window.location.origin}${window.location.pathname}${window.location.search}#${anchorId}`
  void copyTextToClipboard(url)
  if (window.location.hash !== `#${anchorId}`) {
    window.history.replaceState(null, '', url)
    // history.replaceState / pushState do NOT fire `hashchange`, so any
    // listener wired up to react to the targeted block (useFragmentAnchor's
    // highlight + scroll, App.tsx's hasFragment tracker) wouldn't run
    // and the block would stay unhighlighted until a manual refresh
    // re-evaluated `window.location.hash` from scratch. Dispatch the
    // event ourselves so the listeners fire as if the user had navigated.
    window.dispatchEvent(new Event('hashchange'))
  }
}

function LinkIcon() {
  return (
    <svg
      width="13" height="13" viewBox="0 0 16 16" fill="none"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M6.5 8 a2.5 2.5 0 0 1 0 -3.5 L8 3 a2.5 2.5 0 0 1 3.5 3.5 L10 8" />
      <path d="M9.5 8 a2.5 2.5 0 0 1 0 3.5 L8 13 a2.5 2.5 0 0 1 -3.5 -3.5 L6 8" />
    </svg>
  )
}

function BracesIcon() {
  return (
    <svg
      width="13" height="13" viewBox="0 0 16 16" fill="none"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M6 3 q-2 0 -2 2 v1.5 q0 1.5 -1.5 1.5 q1.5 0 1.5 1.5 V11 q0 2 2 2" />
      <path d="M10 3 q2 0 2 2 v1.5 q0 1.5 1.5 1.5 q-1.5 0 -1.5 1.5 V11 q0 2 -2 2" />
    </svg>
  )
}

function BranchIcon() {
  return (
    <svg
      width="13" height="13" viewBox="0 0 16 16" fill="none"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="5" cy="4" r="1.6" />
      <circle cx="5" cy="12" r="1.6" />
      <circle cx="11" cy="7" r="1.6" />
      <path d="M5 5.6 V10.4" />
      <path d="M5 8 q0 -2.4 4.4 -2.4" />
    </svg>
  )
}

function CheckIcon() {
  return (
    <svg
      width="13" height="13" viewBox="0 0 16 16" fill="none"
      stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M3 8.5 L6.5 12 L13 4.5" />
    </svg>
  )
}

function AnchorHandle({ anchorId, label = 'Link' }: { anchorId: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  const timerRef = useRef<number | null>(null)

  useEffect(() => () => {
    if (timerRef.current != null) window.clearTimeout(timerRef.current)
  }, [])

  const onClick = (e: React.MouseEvent) => {
    e.stopPropagation()
    copyAnchorLink(anchorId)
    setCopied(true)
    if (timerRef.current != null) window.clearTimeout(timerRef.current)
    timerRef.current = window.setTimeout(() => setCopied(false), 1400)
  }

  return (
    <button
      className={`icon-btn${copied ? ' icon-btn-success' : ''}`}
      title={copied ? 'Link copied' : 'Copy permalink to this block'}
      aria-label={copied ? 'Link copied to clipboard' : `Copy permalink (${label})`}
      onClick={onClick}
    >
      {copied ? <CheckIcon /> : <LinkIcon />}
    </button>
  )
}

function JsonButton({ onClick, kind }: { onClick: () => void; kind: 'message' | 'tool call' }) {
  return (
    <button
      className="icon-btn"
      title={`View raw JSON (${kind})`}
      aria-label={`View raw JSON (${kind})`}
      onClick={(e) => { e.stopPropagation(); onClick() }}
    >
      <BracesIcon />
    </button>
  )
}

function BranchButton({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) {
  return (
    <button
      className="icon-btn"
      title="branch session from here"
      aria-label="branch session from here"
      disabled={disabled}
      onClick={(e) => { e.stopPropagation(); onClick() }}
    >
      <BranchIcon />
    </button>
  )
}

function prettyJsonOrRaw(payload: string): string {
  try {
    return JSON.stringify(JSON.parse(payload), null, 2)
  } catch {
    return payload
  }
}

// Stack of currently-open modals. Only the top entry consumes Escape so
// that closing the topmost doesn't also collapse the one underneath.
const openModalStack: symbol[] = []

type JsonTab = 'formatted' | 'raw'

function CopyJsonButton({ text }: { text: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle')
  const timerRef = useRef<number | null>(null)
  useEffect(() => () => {
    if (timerRef.current != null) window.clearTimeout(timerRef.current)
  }, [])

  const onClick = () => {
    void copyTextToClipboard(text).then((ok) => {
      setState(ok ? 'copied' : 'failed')
      if (timerRef.current != null) window.clearTimeout(timerRef.current)
      timerRef.current = window.setTimeout(() => setState('idle'), 1400)
    })
  }

  const label = state === 'copied' ? 'Copied' : state === 'failed' ? 'Copy failed' : 'Copy'
  return (
    <button
      className={`raw-json-copy${state === 'copied' ? ' raw-json-copy-copied' : ''}${state === 'failed' ? ' raw-json-copy-failed' : ''}`}
      aria-label="Copy raw JSON to clipboard"
      title={label}
      onClick={onClick}
    >
      {label}
    </button>
  )
}

function RawJsonModal({ title, body, onClose }: { title: string; body: string; onClose: () => void }) {
  // Stash `onClose` in a ref so the effect that registers global state
  // (modal stack + key listener + focus restore) does NOT re-run when the
  // parent passes a fresh callback identity on each render.
  const onCloseRef = useRef(onClose)
  useEffect(() => { onCloseRef.current = onClose })

  const closeBtnRef = useRef<HTMLButtonElement>(null)
  const titleId = useRef(`raw-json-title-${Math.random().toString(36).slice(2, 10)}`).current
  const pretty = prettyJsonOrRaw(body)
  const parsed = tryParse(body)

  const [tab, setTab] = useState<JsonTab>('formatted')

  useEffect(() => {
    const id = Symbol('raw-json-modal')
    openModalStack.push(id)
    const previouslyFocused = (document.activeElement as HTMLElement | null) ?? null
    closeBtnRef.current?.focus()

    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      if (openModalStack[openModalStack.length - 1] !== id) return
      e.stopPropagation()
      onCloseRef.current()
    }
    window.addEventListener('keydown', onKey)

    return () => {
      window.removeEventListener('keydown', onKey)
      const idx = openModalStack.indexOf(id)
      if (idx >= 0) openModalStack.splice(idx, 1)
      previouslyFocused?.focus?.()
    }
  }, [])

  return createPortal(
    <div
      className="raw-json-backdrop"
      data-testid="raw-json-backdrop"
      onClick={() => onCloseRef.current()}
    >
      <div
        className="raw-json-modal"
        data-testid="raw-json-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="raw-json-header">
          <span id={titleId} className="raw-json-title">{title}</span>
          <div className="raw-json-tabs" role="tablist" aria-label="View mode">
            <button
              role="tab"
              aria-selected={tab === 'formatted'}
              className={`raw-json-tab${tab === 'formatted' ? ' raw-json-tab-active' : ''}`}
              onClick={() => setTab('formatted')}
            >
              Formatted
            </button>
            <button
              role="tab"
              aria-selected={tab === 'raw'}
              className={`raw-json-tab${tab === 'raw' ? ' raw-json-tab-active' : ''}`}
              onClick={() => setTab('raw')}
            >
              Raw
            </button>
          </div>
          <CopyJsonButton text={pretty} />
          <button
            ref={closeBtnRef}
            className="raw-json-close"
            aria-label="Close raw JSON view"
            title="Close (Esc)"
            onClick={() => onCloseRef.current()}
          >
            {'×'}
          </button>
        </div>
        {tab === 'formatted' ? (
          parsed.ok ? (
            <div className="raw-json-body raw-json-body-tree">
              <JsonTree value={parsed.value} />
            </div>
          ) : (
            <div
              className="raw-json-body raw-json-body-empty"
              data-testid="formatted-json-body"
            >
              Payload is not valid JSON. Use the Raw tab to view the source.
            </div>
          )
        ) : (
          <pre className="raw-json-body" data-testid="raw-json-body">{pretty}</pre>
        )}
      </div>
    </div>,
    document.body,
  )
}

function tryParse(s: string): { ok: true; value: unknown } | { ok: false } {
  try {
    return { ok: true, value: JSON.parse(s) }
  } catch {
    return { ok: false }
  }
}

function agentNameColor(message: Message): string {
  switch (message.agentStatus) {
    case 'needs-input': return 'var(--needs-input)'
    case 'thinking': return 'var(--accent-secondary)'
    case 'completed': return 'var(--accent-primary)'
    case 'idle': return 'var(--text-muted)'
  }
}

function CodeBlock({ lines }: { lines: CodeSpan[][] }) {
  return (
    <pre className="code-block mb-3">
      {lines.map((line, i) => (
        <div key={i}>
          {line.map((span, j) => (
            span.type === 'text'
              ? <span key={j}>{span.text}</span>
              : <span key={j} className={span.type}>{span.text}</span>
          ))}
        </div>
      ))}
    </pre>
  )
}

function CollapsedBlock({ text, anchorId }: { text: string; anchorId?: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const targeted = useFragmentAnchor(anchorId, ref)
  const [expanded, setExpanded] = useState(targeted)

  useEffect(() => { if (targeted) setExpanded(true) }, [targeted])

  const preview = text.slice(0, 120).replace(/\n/g, ' ')
  const truncated = text.length > 120

  return (
    <div
      ref={ref}
      id={anchorId}
      className="addressable-block rounded px-3 py-2 mb-2 text-xs cursor-pointer select-none"
      style={{
        background: 'var(--bg-sunken)',
        border: `1px solid ${targeted ? 'var(--accent-primary)' : 'var(--border)'}`,
        color: 'var(--text-muted)',
      }}
      onClick={() => setExpanded(!expanded)}
    >
      <div className="flex items-center gap-1.5">
        <span style={{ fontSize: 10, opacity: 0.6 }}>{expanded ? '\u25BC' : '\u25B6'}</span>
        {expanded ? (
          <pre className="whitespace-pre-wrap break-words flex-1" style={{ fontFamily: 'inherit', margin: 0, maxHeight: 400, overflow: 'auto' }}>
            {text}
          </pre>
        ) : (
          <span className="flex-1 truncate">{preview}{truncated ? '\u2026' : ''}</span>
        )}
      </div>
    </div>
  )
}

function toolCallSummary(input: unknown): string {
  if (input == null) return ''
  if (typeof input === 'string') return input
  if (typeof input !== 'object') return String(input)
  const obj = input as Record<string, unknown>
  // Show the most operationally relevant arg inline. Order is intentional:
  // shell-ish args first, then file/path, then query-style args.
  const preferredKeys = ['command', 'cmd', 'shell_command', 'script', 'code', 'file_path', 'path', 'pattern', 'query', 'url']
  for (const k of preferredKeys) {
    const v = obj[k]
    if (typeof v === 'string' && v.length > 0) return v
  }
  // Fall back to a JSON one-liner so we never silently hide structure.
  return JSON.stringify(obj)
}

const RESULT_PREVIEW_LINES = 4

/** Renders a tool-call result. Short results (≤ RESULT_PREVIEW_LINES) inline.
 *  Long results show the first few lines with a "Show all N lines" toggle so
 *  giant directory listings or stdout dumps don't dominate the transcript. */
function ResultPreview({ text, isError }: { text: string; isError?: boolean }) {
  const [expanded, setExpanded] = useState(false)
  const lines = text.split('\n')
  const isLong = lines.length > RESULT_PREVIEW_LINES
  const visible = !isLong || expanded
    ? text
    : lines.slice(0, RESULT_PREVIEW_LINES).join('\n')

  return (
    <div>
      <div className="text-xs font-medium mb-1" style={{ color: 'var(--text-muted)' }}>
        Result{isError ? ' (error)' : ''}
      </div>
      <pre
        className="code-block"
        style={{ maxHeight: expanded ? 280 : undefined, overflow: 'auto', margin: 0 }}
      >
        {visible}
      </pre>
      {isLong && (
        <button
          className="anchor-handle mt-1"
          onClick={(e) => { e.stopPropagation(); setExpanded(!expanded) }}
        >
          {expanded
            ? `Hide ${lines.length - RESULT_PREVIEW_LINES} lines`
            : `Show all ${lines.length} lines`}
        </button>
      )}
    </div>
  )
}

function ToolCallBlock({ tc, anchorId }: { tc: ToolCallInfo; anchorId: string }) {
  const ref = useRef<HTMLDivElement>(null)
  const targeted = useFragmentAnchor(anchorId, ref)
  const [expanded, setExpanded] = useState(targeted)

  useEffect(() => { if (targeted) setExpanded(true) }, [targeted])

  const summary = toolCallSummary(tc.input)
  const inputJson = (() => {
    try { return JSON.stringify(tc.input, null, 2) } catch { return String(tc.input) }
  })()

  return (
    <div
      ref={ref}
      id={anchorId}
      className="addressable-block tool-call mb-2"
      style={{
        background: 'var(--bg-sunken)',
        border: `1px solid ${targeted ? 'var(--accent-primary)' : 'var(--border)'}`,
        borderRadius: 'var(--radius-md)',
        overflow: 'hidden',
      }}
    >
      <div
        className="flex items-center gap-2 px-3 py-2 cursor-pointer select-none"
        onClick={() => setExpanded(!expanded)}
      >
        <span style={{ fontSize: 10, opacity: 0.6 }}>{expanded ? '\u25BC' : '\u25B6'}</span>
        <span
          className="text-xs font-semibold"
          style={{ color: tc.resultIsError ? 'var(--needs-input)' : 'var(--accent-secondary)' }}
        >
          {tc.name}
        </span>
        <span
          className="text-xs flex-1 truncate"
          style={{ color: 'var(--text-muted)', fontFamily: 'var(--font-mono)' }}
        >
          {summary}
        </span>
        {tc.resultIsError && (
          <span className="pill" style={{ background: 'rgba(255,107,107,0.12)', color: 'var(--needs-input)' }}>
            error
          </span>
        )}
        {tc.result !== undefined && !tc.resultIsError && (
          <span className="pill" style={{ background: 'rgba(52,211,153,0.10)', color: 'var(--success)' }}>
            ok
          </span>
        )}
      </div>
      {expanded && (
        <div className="px-3 pb-3 pt-1 flex flex-col gap-2" style={{ borderTop: '1px solid var(--border)' }}>
          <div>
            <div className="text-xs font-medium mb-1" style={{ color: 'var(--text-muted)' }}>Input</div>
            <pre className="code-block" style={{ maxHeight: 240, overflow: 'auto', margin: 0 }}>
              {inputJson}
            </pre>
          </div>
          {tc.result !== undefined && (
            <ResultPreview text={tc.result} isError={tc.resultIsError} />
          )}
          {tc.result === undefined && (
            <div className="text-xs" style={{ color: 'var(--text-faint)', fontStyle: 'italic' }}>
              Awaiting result\u2026
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function MessageBlock({ block }: { block: MessageContent }) {
  if (block.toolCall) {
    return <ToolCallBlock tc={block.toolCall} anchorId={block.id ?? `tc-${block.toolCall.id}`} />
  }
  if (block.collapsedText) {
    return <CollapsedBlock text={block.collapsedText} anchorId={block.id} />
  }
  if (block.codeBlock) {
    return <CodeBlock lines={block.codeBlock} />
  }
  if (block.orderedItems) {
    return (
      <ol className="mb-2" style={{ color: 'var(--text-primary)', paddingLeft: '1.25em', listStyle: 'decimal' }}>
        {block.orderedItems.map((item, i) => (
          <li key={i} style={{ marginBottom: 4 }}>{item}</li>
        ))}
      </ol>
    )
  }
  if (block.listItems) {
    return (
      <ul className="mb-2" style={{ color: 'var(--text-primary)', paddingLeft: '1.25em', listStyle: 'disc' }}>
        {block.listItems.map((item, i) => (
          <li key={i} style={{ marginBottom: 4 }}>{item}</li>
        ))}
      </ul>
    )
  }
  if (block.text) {
    return <p className="mb-2 whitespace-pre-wrap" style={{ color: 'var(--text-primary)' }}>{block.text}</p>
  }
  return null
}

function TypingIndicator() {
  return (
    <div className="flex items-center gap-1 ml-1">
      <div className="typing-dot" />
      <div className="typing-dot" />
      <div className="typing-dot" />
    </div>
  )
}

function ChatMessage({
  message,
  onBranch,
  sending,
}: {
  message: Message
  onBranch?: (entryId: string) => void
  sending?: boolean
}) {
  const anchorId = `msg-${message.id}`
  const ref = useRef<HTMLDivElement>(null)
  const targeted = useFragmentAnchor(anchorId, ref)
  const [jsonOpen, setJsonOpen] = useState(false)
  return (
    <div
      ref={ref}
      id={anchorId}
      className="message-group flex flex-col gap-1 addressable-block"
      style={
        targeted
          // Negative horizontal margins cancel the scroll container's 20px
          // (px-5) padding so the highlight bleeds to its edges; matching
          // horizontal padding keeps the content in the same column.
          ? {
              background: 'var(--bg-elevated)',
              marginLeft: -20,
              marginRight: -20,
              paddingLeft: 20,
              paddingRight: 20,
            }
          : undefined
      }
    >
      <div className="flex items-center gap-2">
        <span className="text-xs font-semibold" style={{ color: agentNameColor(message) }}>
          {message.agentName}
        </span>
        <span className="text-xs" style={{ color: 'var(--text-muted)' }}>
          {message.timestamp}
        </span>
        {message.meta && (
          <span className="text-xs" style={{ color: 'var(--text-muted)' }}>
            {message.meta}
          </span>
        )}
        {message.isGenerating && <TypingIndicator />}
        <AnchorHandle anchorId={anchorId} />
        {message.rawJson !== undefined && (
          <JsonButton kind="message" onClick={() => setJsonOpen(true)} />
        )}
        {onBranch !== undefined && message.entryId !== undefined && (
          <BranchButton
            onClick={() => onBranch(message.entryId!)}
            disabled={sending}
          />
        )}
      </div>
      <div className="text-sm" style={{ lineHeight: 'var(--leading-relaxed)' }}>
        {message.blocks.map((block, i) => (
          <MessageBlock key={block.id ?? i} block={block} />
        ))}
      </div>
      {jsonOpen && message.rawJson !== undefined && (
        <RawJsonModal
          title={`${message.agentName} · raw JSON`}
          body={message.rawJson}
          onClose={() => setJsonOpen(false)}
        />
      )}
    </div>
  )
}

function SessionSetup({
  agents,
  currentAgent,
  onAgentChange,
  customPromptFile,
  onCustomPromptFile,
}: {
  agents: AgentInfo[]
  currentAgent: string | null
  onAgentChange: (agent: string) => void
  customPromptFile: { name: string; content: string } | null
  onCustomPromptFile: (file: { name: string; content: string } | null) => void
}) {
  const [dragOver, setDragOver] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const handleFile = useCallback((file: File) => {
    const reader = new FileReader()
    reader.onload = (e) => {
      const content = e.target?.result as string
      onCustomPromptFile({ name: file.name, content })
      onAgentChange('')
    }
    reader.readAsText(file)
  }, [onCustomPromptFile, onAgentChange])

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault()
    setDragOver(false)
    const file = e.dataTransfer.files[0]
    if (file) handleFile(file)
  }, [handleFile])

  return (
    <div className="flex flex-col items-center gap-6 py-8" style={{ maxWidth: 420, margin: '0 auto', width: '100%' }}>
      <div className="text-center">
        <div className="text-sm font-semibold mb-1" style={{ color: 'var(--text-primary)' }}>
          Session setup
        </div>
        <div className="text-xs" style={{ color: 'var(--text-muted)', lineHeight: 1.5 }}>
          Choose an agent for this session. The agent definition is injected as the system prompt
          at the start of the conversation and cannot be changed after the first message.
        </div>
      </div>

      {agents.length > 0 && (
        <div className="w-full" style={{ opacity: customPromptFile ? 0.4 : 1, transition: 'opacity 0.15s' }}>
          <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--text-muted)' }}>
            Agent
          </label>
          <select
            className="w-full text-sm rounded-md px-3 py-2"
            style={{
              background: 'var(--bg-elevated)',
              color: currentAgent ? 'var(--text-primary)' : 'var(--text-muted)',
              border: '1px solid var(--border)',
              outline: 'none',
              cursor: customPromptFile ? 'default' : 'pointer',
            }}
            value={currentAgent ?? ''}
            disabled={!!customPromptFile}
            onChange={(e) => {
              onAgentChange(e.target.value)
              if (e.target.value) onCustomPromptFile(null)
            }}
          >
            <option value="">None</option>
            {agents.map((a) => (
              <option key={a.name} value={a.name}>
                {a.name}{a.isDefault ? ' (default)' : ''}
              </option>
            ))}
          </select>
        </div>
      )}

      <div className="flex items-center gap-3 w-full" style={{ color: 'var(--text-faint)' }}>
        <div className="flex-1" style={{ borderTop: '1px solid var(--border)' }} />
        <span className="text-xs">or</span>
        <div className="flex-1" style={{ borderTop: '1px solid var(--border)' }} />
      </div>

      <div className="w-full">
        <label className="text-xs font-medium mb-1.5 block" style={{ color: 'var(--text-muted)' }}>
          Use a one-off agent file
        </label>
        <div
          className="rounded-md px-4 py-5 text-center cursor-pointer transition-colors"
          style={{
            border: `2px dashed ${dragOver ? 'var(--accent-primary)' : 'var(--border)'}`,
            background: dragOver ? 'rgba(124,108,246,0.06)' : 'var(--bg-sunken)',
            color: 'var(--text-muted)',
          }}
          onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
          onDragLeave={() => setDragOver(false)}
          onDrop={handleDrop}
          onClick={() => fileInputRef.current?.click()}
        >
          <input
            ref={fileInputRef}
            type="file"
            accept=".md,.txt,.toml"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0]
              if (file) handleFile(file)
            }}
          />
          {customPromptFile ? (
            <div className="flex items-center justify-center gap-2">
              <span className="text-xs font-medium" style={{ color: 'var(--accent-primary)' }}>
                {customPromptFile.name}
              </span>
              <button
                className="text-xs px-1.5 py-0.5 rounded"
                style={{ color: 'var(--text-faint)', background: 'var(--bg-elevated)', border: '1px solid var(--border)' }}
                onClick={(e) => {
                  e.stopPropagation()
                  onCustomPromptFile(null)
                  const def = agents.find((a) => a.isDefault)
                  onAgentChange(def?.name ?? agents[0]?.name ?? '')
                }}
              >
                Remove
              </button>
            </div>
          ) : (
            <div className="text-xs">
              Drop a <code>.md</code> or <code>.txt</code> file here to use as the system prompt
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

export function ChatArea({
  selectedAgent,
  selectedSession,
  onSetDescription,
  messages,
  loading,
  onSend,
  sending,
  tokensUsed,
  contextWindow,
  sessionStart,
  agents,
  currentAgent,
  onAgentChange,
  customPromptFile,
  onCustomPromptFile,
  composerControls,
  newTabFocusTick,
  selectedId,
  onBranch,
  prefixMessages,
  composeError,
  currentModel,
  availableModels,
  onModelChange,
}: {
  selectedAgent: Agent
  selectedSession?: SessionInfo | null
  onSetDescription?: (id: string, description: string) => void
  messages: Message[]
  loading?: boolean
  onSend?: (message: string) => void
  sending?: boolean
  tokensUsed?: number
  contextWindow?: number
  sessionStart?: string | null
  agents?: AgentInfo[]
  currentAgent?: string | null
  onAgentChange?: (agent: string) => void
  customPromptFile?: { name: string; content: string } | null
  onCustomPromptFile?: (file: { name: string; content: string } | null) => void
  /** When set, ChatArea is in "new tab compose" mode. The messages region
   *  renders `panel` instead of the transcript, and the bottom input
   *  drives the new-tab create-and-send flow via `onSubmit`. The input
   *  stays in its normal position. */
  composerControls?: {
    panel: React.ReactNode
    kind: 'provider' | 'harness'
    /** False when the spec has a known-invalid field; the send button
     *  is disabled in that case. */
    valid: boolean
    onSubmit: (message: string) => void | Promise<void>
  } | null
  /** Increments on every "New tab" button click in the Sidebar. ChatArea
   *  uses it as a useEffect dep to focus the message textarea after the
   *  click, even when already in compose mode (where the inComposeMode
   *  transition wouldn't fire). */
  newTabFocusTick?: number
  /** The current selection identity ('tab:N' | 'session:id' | null).
   *  Whenever it changes, ChatArea re-focuses the message textarea so
   *  the user can type into the new session immediately without an
   *  extra click. Covers sidebar tab clicks, session clicks, the
   *  post-create transition into the new tab, and browser back/forward. */
  selectedId?: string | null
  /** When defined, each transcript row that carries an `entryId` renders a
   *  branch button wired to `onBranch(entryId)`. Supplied by App only for
   *  persisted provider sessions; undefined for harness sessions and in
   *  compose mode, which suppresses the button entirely. */
  onBranch?: (entryId: string) => void
  /** Read-only transcript prefix rendered ABOVE the composer panel in a
   *  branch-draft compose flow. These rows carry no `onBranch` so they
   *  render no branch button and offer no send affordance — the only send
   *  path is the composer's first-send. Empty/undefined ⇒ nothing extra. */
  prefixMessages?: Message[]
  /** When set, an inline error banner is shown inside the composer region
   *  (e.g. a failed branch create). Cleared by the caller. */
  composeError?: string | null
  /** The model the next /send should use for an existing session. Default
   *  is the most-recent transcript `_te_model`; the user can override via
   *  the input-row dropdown. Frontend-only state (never persisted). */
  currentModel?: string | null
  /** Models to offer in the input-row model dropdown. The current model is
   *  always included even if absent from this list. */
  availableModels?: string[]
  /** Called with the newly-picked model id when the user changes the
   *  input-row model dropdown. */
  onModelChange?: (model: string) => void
}) {
  const [input, setInput] = useState('')
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const messagesEndRef = useRef<HTMLDivElement>(null)
  const scrollerRef = useRef<HTMLDivElement>(null)
  const wasAtBottom = useRef(true)

  // Focus the message textarea on any user-initiated arrival at a
  // session, so the user can start typing immediately without an extra
  // click. Two signals feed this:
  //   * 'selectedId' — covers selecting a tab or archived session in the
  //     sidebar, the post-create transition into the new tab, browser
  //     back/forward (popstate), and the initial mount.
  //   * 'newTabFocusTick' — covers clicking the Sidebar's "+" button
  //     while ALREADY in compose mode. selectedId stays null in that
  //     case, but the click steals focus to the button, so a per-click
  //     signal is required to recover focus.
  useEffect(() => {
    textareaRef.current?.focus()
  }, [selectedId, newTabFocusTick])

  // Two scroll modes:
  //   1. Deep-link mode (URL has a fragment): suppress all auto-scroll. The
  //      targeted block's useFragmentAnchor handles initial positioning; the
  //      user is anchored to that spot until they clear the fragment.
  //   2. Sticky-bottom mode (no fragment, default): only auto-scroll when the
  //      user was already near the bottom before this render. Lets users scroll
  //      up to read history without being yanked down by transcript polls,
  //      while new messages still pin to the bottom in the common case.
  const [hasFragment, setHasFragment] = useState(
    () => typeof window !== 'undefined' && window.location.hash !== '',
  )
  useEffect(() => {
    const update = () => setHasFragment(window.location.hash !== '')
    window.addEventListener('hashchange', update)
    return () => window.removeEventListener('hashchange', update)
  }, [])

  // Track sticky-bottom state from real scroll events. Measuring this in a
  // post-render effect doesn't work: by then React has already committed the
  // new messages, scrollHeight has grown, scrollTop hasn't moved, and the
  // at-bottom check flips to false — exactly when we need it to stay true.
  // A scroll listener records the user's actual intent.
  useEffect(() => {
    if (hasFragment) return
    const el = scrollerRef.current
    if (!el) return
    const onScroll = () => {
      wasAtBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    }
    onScroll()
    el.addEventListener('scroll', onScroll, { passive: true })
    return () => el.removeEventListener('scroll', onScroll)
  }, [hasFragment])

  useEffect(() => {
    if (hasFragment) return
    if (wasAtBottom.current) {
      messagesEndRef.current?.scrollIntoView({ block: 'end' })
    }
  }, [messages, hasFragment])

  // When the user clicks a different session in the sidebar, force the next
  // render to auto-scroll to the most recent message. Without this, the
  // sticky-bottom ref ('wasAtBottom') retains the prior session's measured
  // scroll state — a user reading history in session A (scrolled up) and
  // switching to session B would land mid-transcript in B. Deep-link mode
  // (hasFragment) is still respected by the effect above.
  useEffect(() => {
    wasAtBottom.current = true
  }, [selectedSession?.id])

  const handleSend = () => {
    const trimmed = input.trim()
    if (!trimmed || sending || !onSend) return
    onSend(trimmed)
    setInput('')
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      handleSend()
    }
  }
  return (
    <div className="flex-1 flex flex-col min-w-0" style={{ background: 'var(--bg-base)' }}>
      {/* Chat header */}
      <div
        className="px-5 py-3 flex items-center gap-2.5 shrink-0"
        style={{ borderBottom: '1px solid var(--border)' }}
      >
        <StatusDot status={selectedAgent.status} />
        {selectedSession && onSetDescription ? (
          <EditableSessionTitle session={selectedSession} onSetDescription={onSetDescription} />
        ) : (
          <span className="font-semibold text-sm" style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}>
            {selectedAgent.name}
          </span>
        )}
        {(() => {
          // Prefer the live session's agent + model when viewing a session;
          // for harness selections fall back to whatever selectedAgent
          // exposes as a description (currently the harness's own metadata).
          const subtitle = selectedSession
            ? sessionSubtitle(selectedSession)
            : selectedAgent.description ?? ''
          if (!subtitle) return null
          return (
            <>
              <span style={{ color: 'var(--border)' }}>&middot;</span>
              <span className="text-xs truncate" style={{ color: 'var(--text-muted)' }}>
                {subtitle}
              </span>
            </>
          )
        })()}
        {messages.length > 0 && (
          <div className="ml-auto flex items-center gap-1 shrink-0">
            <button
              className="header-scroll-btn"
              title="Scroll to top of transcript"
              aria-label="Scroll to top"
              onClick={() => scrollerRef.current?.scrollTo({ top: 0 })}
            >
              <svg width="13" height="13" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true">
                <path d="M3 10 L8 5 L13 10" />
              </svg>
            </button>
            <button
              className="header-scroll-btn"
              title="Scroll to bottom of transcript"
              aria-label="Scroll to bottom"
              onClick={() => {
                const el = scrollerRef.current
                if (el) el.scrollTo({ top: el.scrollHeight })
              }}
            >
              <svg width="13" height="13" viewBox="0 0 16 16" fill="none"
                stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"
                aria-hidden="true">
                <path d="M3 6 L8 11 L13 6" />
              </svg>
            </button>
          </div>
        )}
      </div>

      {/* Messages or composer panel */}
      <div ref={scrollerRef} className="flex-1 overflow-y-auto chat-scroll px-5 py-6">
        <div className="flex flex-col gap-5">
          {composerControls ? (
            <>
              {prefixMessages && prefixMessages.length > 0 && (
                <div className="flex flex-col gap-5" data-testid="branch-prefix">
                  {prefixMessages.map((msg) => (
                    // Read-only: no onBranch (no branch button) and no send
                    // affordance — the only send path is the composer below.
                    <ChatMessage key={msg.id} message={msg} />
                  ))}
                </div>
              )}
              {composeError && (
                <div
                  role="alert"
                  className="text-sm rounded-md px-3 py-2"
                  style={{
                    background: 'rgba(255,107,107,0.10)',
                    border: '1px solid var(--needs-input)',
                    color: 'var(--needs-input)',
                  }}
                >
                  {composeError}
                </div>
              )}
              {composerControls.panel}
            </>
          ) : loading ? (
            <div className="text-sm" style={{ color: 'var(--text-muted)' }}>Loading transcript...</div>
          ) : messages.length === 0 && onSend && agents && agents.length > 0 && onAgentChange && onCustomPromptFile ? (
            <SessionSetup
              agents={agents}
              currentAgent={currentAgent ?? null}
              onAgentChange={onAgentChange}
              customPromptFile={customPromptFile ?? null}
              onCustomPromptFile={onCustomPromptFile}
            />
          ) : messages.length === 0 ? (
            <div className="text-sm" style={{ color: 'var(--text-muted)' }}>No messages yet. Select a session to view its transcript.</div>
          ) : (
            messages.map((msg) => (
              <ChatMessage key={msg.id} message={msg} onBranch={onBranch} sending={sending} />
            ))
          )}
          <div ref={messagesEndRef} />
        </div>
      </div>

      {/* Input area. In compose mode we keep the textarea right where it
          always lives, just rewire its submit path. For raw_shell the
          textarea disables (no message to send) and the button starts the
          shell. */}
      {(() => {
        const isCompose = !!composerControls
        const placeholder = isCompose
          ? 'Type your first message\u2026'
          : `Message ${selectedAgent.name}\u2026`
        const submitDisabled = isCompose
          ? !composerControls!.valid || !input.trim()
          : (!input.trim() || !onSend)
        const onSubmit = () => {
          if (isCompose) {
            if (submitDisabled) return
            void composerControls!.onSubmit(input.trim())
            setInput('')
          } else {
            handleSend()
          }
        }
        const onKeyDownLocal = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
          if (isCompose) {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              onSubmit()
            }
          } else {
            handleKeyDown(e)
          }
        }
        // Per-session model dropdown. Rendered for an existing session (the
        // input-row override) and for a branch draft (default = the source
        // prefix's last model, U8 — a branch draft is detected by the
        // presence of prefixMessages). A fresh new-tab compose has no
        // prefix and lets the NewTabComposer panel own model selection, so
        // the picker stays hidden there. The current model is always an
        // option, even if it isn't in availableModels, so the displayed
        // value can never disagree with what will be sent.
        const isBranchDraft = (prefixMessages?.length ?? 0) > 0
        const showModelPicker = onModelChange !== undefined
          && (currentModel ?? null) !== null
          && (!isCompose || isBranchDraft)
        const modelOptions = showModelPicker
          ? Array.from(new Set([currentModel as string, ...(availableModels ?? [])]))
          : []
        return (
          <div className="shrink-0" style={{ borderTop: '1px solid var(--border)' }}>
            <div className="px-4 py-3 flex items-end gap-3">
              <textarea
                ref={textareaRef}
                className="flex-1 rounded-lg px-4 py-3 text-sm resize-none"
                style={{
                  background: 'var(--bg-sunken)',
                  border: '1px solid var(--accent-primary)',
                  boxShadow: '0 0 0 2px rgba(124,108,246,0.12)',
                  color: 'var(--text-primary)',
                  outline: 'none',
                  minHeight: '44px',
                  maxHeight: '200px',
                }}
                placeholder={placeholder}
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={onKeyDownLocal}
                rows={1}
              />
              <button
                className="btn btn-primary px-4 py-3 rounded-lg text-sm font-medium flex items-center gap-2"
                onClick={onSubmit}
                disabled={submitDisabled}
                style={{ opacity: submitDisabled ? 0.5 : 1 }}
              >
                Send <span className="kbd">{'\u2318\u21B5'}</span>
              </button>
              {showModelPicker && (
                <select
                  aria-label="session model"
                  title="Model for this session"
                  className="rounded-lg px-2 py-3 text-xs"
                  style={{
                    background: 'var(--bg-sunken)',
                    border: '1px solid var(--border)',
                    color: 'var(--text-primary)',
                    outline: 'none',
                    maxWidth: '180px',
                  }}
                  value={currentModel as string}
                  onChange={(e) => onModelChange!(e.target.value)}
                >
                  {modelOptions.map((m) => (
                    <option key={m} value={m}>{shortenModel(m)}</option>
                  ))}
                </select>
              )}
            </div>
          </div>
        )
      })()}

      <BottomBar
        tokensUsed={tokensUsed ?? 0}
        contextWindow={contextWindow ?? 0}
        sessionStart={sessionStart ?? null}
        running={sending ?? false}
      />
    </div>
  )
}
