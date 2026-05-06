function ProgressBar({ value, max, widthPx }: { value: number; max: number; widthPx: number }) {
  const pct = max > 0 ? Math.min((value / max) * 100, 100) : 0
  return (
    <div className="rounded-full overflow-hidden" style={{ width: widthPx, height: 3, background: 'var(--bg-elevated)' }}>
      <div className="progress-fill" style={{ width: `${pct}%` }} />
    </div>
  )
}

function Divider() {
  return <div style={{ width: 1, height: 14, background: 'var(--border)' }} />
}

export function BottomBar({
  tokensUsed,
  contextWindow,
  sessionStart,
  running,
}: {
  tokensUsed: number
  contextWindow: number
  sessionStart: string | null
  running: boolean
}) {
  const formatTokens = (n: number) => n >= 1000 ? `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k` : String(n)

  const elapsed = sessionStart ? formatElapsed(sessionStart) : '--:--'

  return (
    <div
      className="shrink-0 flex items-center gap-5 px-4"
      style={{ height: 'var(--bottombar-height)', background: 'var(--bg-surface)', borderTop: '1px solid var(--border)' }}
    >
      {/* Tokens */}
      <div className="flex items-center gap-2">
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>Tokens</span>
        {contextWindow > 0 ? (
          <>
            <ProgressBar value={tokensUsed} max={contextWindow} widthPx={80} />
            <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>
              {formatTokens(tokensUsed)}{' '}
              <span style={{ color: 'var(--text-faint)' }}>
                / {formatTokens(contextWindow)} ({Math.round((tokensUsed / contextWindow) * 100)}%)
              </span>
            </span>
          </>
        ) : (
          <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>
            {formatTokens(tokensUsed)}
          </span>
        )}
      </div>

      <Divider />

      {/* Session length */}
      <div className="flex items-center gap-1.5">
        <svg width="11" height="11" viewBox="0 0 12 12" fill="none" style={{ color: 'var(--text-faint)' }}>
          <circle cx="6" cy="6" r="4.5" stroke="currentColor" strokeWidth="1.2" />
          <path d="M6 3.5V6l1.5 1.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
        </svg>
        <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>{elapsed}</span>
      </div>

      {/* Running indicator */}
      <div className="ml-auto flex items-center gap-1.5">
        <div
          className={`dot-sm ${running ? 'dot-thinking' : 'dot-completed'}`}
          style={{ width: 6, height: 6 }}
        />
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
          {running ? 'Running' : 'Idle'}
        </span>
      </div>
    </div>
  )
}

function formatElapsed(isoDate: string): string {
  const diff = Math.max(0, Date.now() - new Date(isoDate).getTime())
  const totalSecs = Math.floor(diff / 1000)
  const hours = Math.floor(totalSecs / 3600)
  const mins = Math.floor((totalSecs % 3600) / 60)
  const secs = totalSecs % 60
  const pad = (n: number) => String(n).padStart(2, '0')
  if (hours > 0) return `${pad(hours)}:${pad(mins)}:${pad(secs)}`
  return `${pad(mins)}:${pad(secs)}`
}
