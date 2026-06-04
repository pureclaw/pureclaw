import { useState } from 'react'
import type { SessionInfo, TabInfo, TabStatus } from '../types'
import { sessionDisplayTitle } from '../types'

const statusLabel: Record<TabStatus, string> = {
  running: 'Running',
  idle: 'Idle',
  exited: 'Exited',
  orphaned: 'Orphaned',
}

const statusColor: Record<TabStatus, string> = {
  running: 'var(--success)',
  idle: 'var(--text-muted)',
  exited: 'var(--needs-input)',
  orphaned: 'var(--needs-input)',
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <span
        className="text-xs font-semibold uppercase"
        style={{ color: 'var(--text-muted)', letterSpacing: '0.08em' }}
      >
        {label}
      </span>
      <div className="text-sm" style={{ color: 'var(--text-primary)' }}>
        {children}
      </div>
    </div>
  )
}

/** The right-pane view shown when a running harness is selected. A harness has
 *  no conversation transcript of its own, so instead of a chat we surface its
 *  status, the session(s) it is associated with, and a Destroy control.
 *
 *  Destroy terminates the harness's claude-code + shell processes and archives
 *  its session. For an ADOPTED harness (one PureClaw attached to but did not
 *  spawn) destroying breaks the "release never kills" contract, so it is gated
 *  behind an explicit confirmation that names the consequence. */
export function HarnessControls({
  tab,
  session,
  onDestroy,
}: {
  tab: TabInfo
  session: SessionInfo | null
  onDestroy: (index: number, confirmAdopted: boolean) => void
}) {
  const [confirming, setConfirming] = useState(false)
  const isAdopted = tab.origin === 'adopted'
  const status = statusLabel[tab.status] ?? tab.status

  const handleDestroyClick = () => {
    if (isAdopted) {
      setConfirming(true)
    } else {
      onDestroy(tab.index, false)
    }
  }

  return (
    <div className="flex-1 overflow-y-auto" style={{ padding: '24px 32px' }}>
      <div className="flex flex-col gap-5" style={{ maxWidth: 560 }}>
        <div className="flex items-center gap-2">
          <span className="text-lg font-semibold" style={{ color: 'var(--text-primary)' }}>
            {tab.name}
          </span>
          {tab.origin && (
            <span
              className="pill"
              style={{ background: 'var(--bg-elevated)', color: 'var(--text-faint)', fontSize: 11, padding: '0 6px' }}
            >
              {tab.origin}
            </span>
          )}
        </div>

        <Field label="Status">
          <span style={{ color: statusColor[tab.status] ?? 'var(--text-muted)' }}>● </span>
          {status}
          {tab.stale && <span style={{ color: 'var(--text-faint)' }}> (stale)</span>}
        </Field>

        <Field label="Associated session">
          {session ? (
            <div className="flex flex-col">
              <span>{sessionDisplayTitle(session)}</span>
              <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
                {session.id}
              </span>
            </div>
          ) : (
            <span style={{ color: 'var(--text-faint)' }}>No session associated yet.</span>
          )}
        </Field>

        {tab.attachCommand && (
          <Field label="Attach command">
            <code className="text-xs" style={{ color: 'var(--text-muted)' }}>
              {tab.attachCommand}
            </code>
          </Field>
        )}

        <div className="flex flex-col gap-2" style={{ borderTop: '1px solid var(--border)', paddingTop: 16 }}>
          {!confirming ? (
            <button
              className="btn"
              style={{
                alignSelf: 'flex-start',
                background: 'var(--needs-input-bg, var(--bg-elevated))',
                color: 'var(--needs-input)',
                border: '1px solid var(--needs-input)',
              }}
              onClick={handleDestroyClick}
            >
              Destroy harness
            </button>
          ) : (
            <div className="flex flex-col gap-2">
              <span className="text-sm" style={{ color: 'var(--needs-input)' }}>
                This harness was adopted — PureClaw did not create it. Destroying it will{' '}
                <strong>kill the underlying tmux window and its processes</strong>, not just stop
                managing it. This cannot be undone.
              </span>
              <div className="flex gap-2">
                <button
                  className="btn"
                  style={{ background: 'var(--needs-input)', color: 'var(--text-primary)' }}
                  onClick={() => {
                    setConfirming(false)
                    onDestroy(tab.index, true)
                  }}
                >
                  Confirm destroy
                </button>
                <button className="btn btn-ghost" onClick={() => setConfirming(false)}>
                  Cancel
                </button>
              </div>
            </div>
          )}
          <span className="text-xs" style={{ color: 'var(--text-faint)' }}>
            Terminates the harness's claude-code and shell processes and archives its session
            (the transcript is kept on disk).
          </span>
        </div>
      </div>
    </div>
  )
}
