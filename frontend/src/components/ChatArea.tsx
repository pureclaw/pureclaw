import { useState, useRef, useEffect } from 'react'
import type { Agent, Message, MessageContent, CodeSpan } from '../types'
import { StatusDot } from './StatusDot'
import { BottomBar } from './BottomBar'

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

function CollapsedBlock({ text }: { text: string }) {
  const [expanded, setExpanded] = useState(false)
  const preview = text.slice(0, 120).replace(/\n/g, ' ')
  const truncated = text.length > 120

  return (
    <div
      className="rounded px-3 py-2 mb-2 text-xs cursor-pointer select-none"
      style={{
        background: 'var(--bg-sunken)',
        border: '1px solid var(--border)',
        color: 'var(--text-muted)',
      }}
      onClick={() => setExpanded(!expanded)}
    >
      <div className="flex items-center gap-1.5">
        <span style={{ fontSize: 10, opacity: 0.6 }}>{expanded ? '\u25BC' : '\u25B6'}</span>
        {expanded ? (
          <pre className="whitespace-pre-wrap break-words" style={{ fontFamily: 'inherit', margin: 0, maxHeight: 400, overflow: 'auto' }}>
            {text}
          </pre>
        ) : (
          <span>{preview}{truncated ? '\u2026' : ''}</span>
        )}
      </div>
    </div>
  )
}

function MessageBlock({ block }: { block: MessageContent }) {
  if (block.collapsedText) {
    return <CollapsedBlock text={block.collapsedText} />
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

function ChatMessage({ message }: { message: Message }) {
  return (
    <div className="message-group flex flex-col gap-1">
      <div className="flex items-center gap-2">
        <span className="text-xs font-semibold" style={{ color: agentNameColor(message) }}>
          {message.agentName}
        </span>
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
          {message.timestamp}
        </span>
        {message.meta && (
          <span className="text-xs" style={{ color: 'var(--text-faint)', opacity: 0.7 }}>
            {message.meta}
          </span>
        )}
        {message.isGenerating && <TypingIndicator />}
      </div>
      <div className="text-sm" style={{ lineHeight: 'var(--leading-relaxed)' }}>
        {message.blocks.map((block, i) => (
          <MessageBlock key={i} block={block} />
        ))}
      </div>
    </div>
  )
}

export function ChatArea({
  selectedAgent,
  messages,
  loading,
  onSend,
  sending,
  tokensUsed,
  sessionStart,
}: {
  selectedAgent: Agent
  messages: Message[]
  loading?: boolean
  onSend?: (message: string) => void
  sending?: boolean
  tokensUsed?: number
  sessionStart?: string | null
}) {
  const [input, setInput] = useState('')
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const messagesEndRef = useRef<HTMLDivElement>(null)

  // Auto-scroll to bottom when messages change
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

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
        <span className="font-semibold text-sm" style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }}>
          {selectedAgent.name}
        </span>
        {selectedAgent.description && (
          <>
            <span style={{ color: 'var(--border)' }}>&middot;</span>
            <span className="text-xs truncate" style={{ color: 'var(--text-muted)' }}>
              {selectedAgent.description}
            </span>
          </>
        )}
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto chat-scroll px-5 py-6">
        <div className="flex flex-col gap-5" style={{ maxWidth: 'var(--chat-max-width)', width: '100%', margin: '0 auto' }}>
          {loading ? (
            <div className="text-sm" style={{ color: 'var(--text-muted)' }}>Loading transcript...</div>
          ) : messages.length === 0 ? (
            <div className="text-sm" style={{ color: 'var(--text-muted)' }}>No messages yet. Select a session to view its transcript.</div>
          ) : (
            messages.map((msg) => (
              <ChatMessage key={msg.id} message={msg} />
            ))
          )}
          <div ref={messagesEndRef} />
        </div>
      </div>

      {/* Input area */}
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
            placeholder={`Message ${selectedAgent.name}\u2026`}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            rows={1}
          />
          <button
            className="btn btn-primary px-4 py-3 rounded-lg text-sm font-medium flex items-center gap-2"
            onClick={handleSend}
            disabled={!input.trim() || !onSend}
            style={{ opacity: (!input.trim() || !onSend) ? 0.5 : 1 }}
          >
            Send <span className="kbd">{'\u2318\u21B5'}</span>
          </button>
        </div>
      </div>

      <BottomBar
        tokensUsed={tokensUsed ?? 0}
        contextWindow={0}
        sessionStart={sessionStart ?? null}
        running={sending ?? false}
      />
    </div>
  )
}
