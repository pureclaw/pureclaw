import type { AgentStatus, HarnessActivity } from '../types'

const dotClass: Record<AgentStatus, string> = {
  'needs-input': 'dot dot-needs',
  'thinking': 'dot dot-thinking',
  'idle': 'dot dot-idle',
  'completed': 'dot dot-completed',
}

const activityDotClass: Record<HarnessActivity, string> = {
  'thinking': 'dot dot-thinking',
  'idle': 'dot dot-idle',
  'needs-input': 'dot dot-needs',
  'stopped': 'dot dot-completed',
}

export function StatusDot({ status, small }: { status: AgentStatus; small?: boolean }) {
  const base = small ? 'dot-sm' : ''
  const variant = dotClass[status]
  return <div className={`${base} ${variant}`.trim()} />
}

export function ActivityDot({ activity }: { activity: HarnessActivity }) {
  return <div className={activityDotClass[activity]} />
}
