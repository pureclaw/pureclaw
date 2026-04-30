function ProgressBar({ value, max, widthPx }: { value: number; max: number; widthPx: number }) {
  const pct = Math.min((value / max) * 100, 100)
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
  tokensUsed, tokensTotal,
  budgetUsed, budgetTotal,
  elapsed,
  active, waiting, idle, done,
}: {
  tokensUsed: number
  tokensTotal: number
  budgetUsed: number
  budgetTotal: number
  elapsed: string
  active: number
  waiting: number
  idle: number
  done: number
}) {
  const formatTokens = (n: number) => n >= 1000 ? `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k` : String(n)

  return (
    <div
      className="shrink-0 flex items-center gap-5 px-4"
      style={{ height: 'var(--bottombar-height)', background: 'var(--bg-surface)', borderTop: '1px solid var(--border)' }}
    >
      {/* Tokens */}
      <div className="flex items-center gap-2">
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>Tokens</span>
        <ProgressBar value={tokensUsed} max={tokensTotal} widthPx={80} />
        <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>
          {formatTokens(tokensUsed)}{' '}
          <span style={{ color: 'var(--text-faint)' }}>/ {formatTokens(tokensTotal)}</span>
        </span>
      </div>

      <Divider />

      {/* Budget */}
      <div className="flex items-center gap-2">
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>Budget</span>
        <ProgressBar value={budgetUsed} max={budgetTotal} widthPx={80} />
        <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>
          ${budgetUsed.toFixed(2)}{' '}
          <span style={{ color: 'var(--text-faint)' }}>/ ${budgetTotal.toFixed(2)}</span>
        </span>
      </div>

      <Divider />

      {/* Elapsed */}
      <div className="flex items-center gap-1.5">
        <svg width="11" height="11" viewBox="0 0 12 12" fill="none" style={{ color: 'var(--text-faint)' }}>
          <circle cx="6" cy="6" r="4.5" stroke="currentColor" strokeWidth="1.2" />
          <path d="M6 3.5V6l1.5 1.5" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
        </svg>
        <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>{elapsed}</span>
      </div>

      <Divider />

      {/* Agent counts */}
      <div className="flex items-center gap-1.5">
        <div className="dot-sm dot-thinking" />
        <span className="text-xs font-medium" style={{ color: 'var(--text-primary)' }}>{active} active</span>
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
          &middot; {waiting} waiting &middot; {idle} idle &middot; {done} done
        </span>
      </div>

      {/* Running indicator */}
      <div className="ml-auto flex items-center gap-1.5">
        <div className="dot-sm dot-needs" style={{ width: 6, height: 6 }} />
        <span className="text-xs" style={{ color: 'var(--text-faint)' }}>Running</span>
      </div>
    </div>
  )
}
