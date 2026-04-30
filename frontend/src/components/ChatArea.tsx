import type { Agent, Message, MessageContent, CodeSpan } from '../types'
import { StatusDot } from './StatusDot'

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

function MessageBlock({ block }: { block: MessageContent }) {
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
    return <p className="mb-2" style={{ color: 'var(--text-primary)' }}>{block.text}</p>
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
}: {
  selectedAgent: Agent
  messages: Message[]
}) {
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
        <span style={{ color: 'var(--border)' }}>&middot;</span>
        <span className="text-xs truncate" style={{ color: 'var(--text-muted)' }}>
          User auth with email/password, OAuth2, sessions, rate limiting
        </span>
        <div className="ml-auto flex items-center gap-4 text-xs" style={{ color: 'var(--text-faint)' }}>
          <span>claude-opus-4-6</span>
          <span style={{ color: 'var(--border)' }}>&middot;</span>
          <span>14,208 tokens</span>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto chat-scroll px-5 py-6">
        <div className="flex flex-col gap-5" style={{ maxWidth: 'var(--chat-max-width)', width: '100%', margin: '0 auto' }}>
          {messages.map((msg) => (
            <ChatMessage key={msg.id} message={msg} />
          ))}
        </div>
      </div>

      {/* Input area */}
      <div className="shrink-0" style={{ borderTop: '1px solid var(--border)' }}>
        <div className="px-4 py-3 flex items-end gap-3">
          <div
            className="flex-1 rounded-lg px-4 py-3 text-sm"
            style={{
              background: 'var(--bg-sunken)',
              border: '1px solid var(--accent-primary)',
              boxShadow: '0 0 0 2px rgba(124,108,246,0.12)',
            }}
          >
            <span style={{ color: 'var(--text-faint)' }}>Respond to {selectedAgent.name}\u2026</span>
            <span
              className="inline-block ml-0.5"
              style={{ color: 'var(--accent-primary)', animation: 'blink var(--blink-duration) step-end infinite' }}
            >
              |
            </span>
          </div>
          <button className="btn btn-primary px-4 py-3 rounded-lg text-sm font-medium flex items-center gap-2">
            Send <span className="kbd">\u2318\u21B5</span>
          </button>
        </div>
      </div>
    </div>
  )
}
