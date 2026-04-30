import type { AgentStatus } from '../types'

const dotClass: Record<AgentStatus, string> = {
  'needs-input': 'dot dot-needs',
  'thinking': 'dot dot-thinking',
  'idle': 'dot dot-idle',
  'completed': 'dot dot-completed',
}

export function StatusDot({ status, small }: { status: AgentStatus; small?: boolean }) {
  const base = small ? 'dot-sm' : ''
  const variant = dotClass[status]
  return <div className={`${base} ${variant}`.trim()} />
}
