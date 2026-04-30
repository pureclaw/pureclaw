import type { Agent } from '../types'
import { StatusDot } from './StatusDot'

function AgentRow({ agent, selected, onSelect }: { agent: Agent; selected: boolean; onSelect: () => void }) {
  const isThinking = agent.status === 'thinking'
  const isActive = agent.status === 'needs-input' || agent.status === 'thinking'
  const isCompleted = agent.status === 'completed'

  const rowClasses = [
    'agent-row px-3 py-2',
    selected ? 'selected' : '',
    isThinking ? 'shimmer' : '',
  ].filter(Boolean).join(' ')

  const nameStyle: React.CSSProperties = isCompleted
    ? { color: 'var(--text-muted)', opacity: 0.7, letterSpacing: 'var(--tracking-tight)' }
    : agent.status === 'idle'
      ? { color: 'var(--text-muted)', letterSpacing: 'var(--tracking-tight)' }
      : { color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tight)' }

  const descColor = agent.status === 'needs-input' ? 'var(--needs-input)' : 'var(--text-muted)'

  return (
    <div className={rowClasses} onClick={onSelect}>
      <div className="flex items-center gap-2">
        <StatusDot status={agent.status} />
        <span className="text-sm font-medium" style={nameStyle}>{agent.name}</span>
        <span className="pill token-count ml-auto">{agent.tokenCount}</span>
      </div>
      {isActive && agent.description && (
        <div
          className="text-xs ml-4 mt-0.5"
          style={{ color: descColor, opacity: agent.status === 'needs-input' ? 0.9 : 1, lineHeight: 'var(--leading-tight)' }}
        >
          {agent.description}
        </div>
      )}
    </div>
  )
}

export function Sidebar({
  agents,
  selectedId,
  onSelectAgent,
}: {
  agents: Agent[]
  selectedId: string
  onSelectAgent: (id: string) => void
}) {
  return (
    <div
      className="shrink-0 flex flex-col"
      style={{ width: 'var(--sidebar-width)', background: 'var(--bg-surface)', borderRight: '1px solid var(--border)' }}
    >
      <div className="flex-1 overflow-y-auto sidebar-scroll py-1">
        {agents.map((agent) => (
          <AgentRow
            key={agent.id}
            agent={agent}
            selected={agent.id === selectedId}
            onSelect={() => onSelectAgent(agent.id)}
          />
        ))}
      </div>
    </div>
  )
}
