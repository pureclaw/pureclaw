import logoSvg from '../../assets/logo.svg'

export function TopBar({ taskTitle }: { taskTitle: string }) {
  return (
    <div
      className="topbar-bg flex items-center px-4 gap-4 shrink-0"
      style={{ height: 'var(--topbar-height)', borderBottom: '1px solid var(--border)' }}
    >
      <div className="flex items-center gap-2.5">
        <img
          src={logoSvg}
          alt="PureClaw"
          style={{ width: 'var(--logo-size)', height: 'var(--logo-size)', borderRadius: 'var(--radius-md)', objectFit: 'cover' }}
        />
        <span className="font-semibold text-sm" style={{ color: 'var(--text-primary)', letterSpacing: 'var(--tracking-tighter)' }}>
          PureClaw
        </span>
        <span style={{ color: 'var(--border)' }}>|</span>
        <span className="text-xs font-medium truncate" style={{ color: 'var(--text-muted)', maxWidth: 280 }}>
          {taskTitle}
        </span>
      </div>

      <div className="flex-1" />

      <div className="flex items-center gap-2">
        <button className="btn btn-ghost flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
            <rect x="2" y="2" width="3" height="8" rx="0.5" />
            <rect x="7" y="2" width="3" height="8" rx="0.5" />
          </svg>
          Pause
        </button>
        <button className="btn btn-danger-ghost flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
            <rect x="2" y="2" width="8" height="8" rx="1" />
          </svg>
          Stop
        </button>
        <div
          className="text-xs px-2 py-1 rounded-md"
          style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', border: '1px solid var(--border)' }}
        >
          v0.1.0
        </div>
      </div>
    </div>
  )
}
