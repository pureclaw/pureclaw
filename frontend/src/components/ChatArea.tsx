import { useState, useRef, useEffect, useCallback } from 'react'
import type { Agent, AgentInfo, Message, MessageContent, CodeSpan } from '../types'
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
}: {
  selectedAgent: Agent
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
        <div className="flex flex-col gap-5">
          {loading ? (
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
        contextWindow={contextWindow ?? 0}
        sessionStart={sessionStart ?? null}
        running={sending ?? false}
      />
    </div>
  )
}
