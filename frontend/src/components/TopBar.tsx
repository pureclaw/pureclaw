import logoSvg from '../../assets/logo.svg'

export function TopBar({ taskTitle, onNewSession }: { taskTitle: string; onNewSession?: () => void }) {
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
        <button
          className="btn btn-ghost flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium"
          onClick={onNewSession}
          disabled={!onNewSession}
          style={{ opacity: onNewSession ? 1 : 0.5 }}
        >
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
            <line x1="6" y1="2" x2="6" y2="10" />
            <line x1="2" y1="6" x2="10" y2="6" />
          </svg>
          New Session
        </button>
        <div
          className="text-xs px-2.5 py-1.5 rounded-md flex items-center"
          style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', border: '1px solid var(--border)' }}
        >
          v0.1.0
        </div>
      </div>
    </div>
  )
}
