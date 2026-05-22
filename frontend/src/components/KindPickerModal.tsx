import { useState, useEffect, useCallback } from 'react'
import type { NewTabResponse } from '../hooks/useApi'

// ── Types ─────────────────────────────────────────────────────────────

type Category = 'provider' | 'harness' | 'raw_shell'
type Step = 'pick' | 'form'
type BackendTag = 'local' | 'tmux' | 'ssh' | 'container'
type HarnessFlavour = 'claude-code' | 'codex' | 'opencode' | 'hermes' | 'pureclaw' | 'custom'

interface BackendConfig {
  tag: BackendTag
  // tmux
  session?: string
  window?: string
  // ssh
  host?: string
  port?: number
  // container
  engine?: 'docker' | 'podman' | 'kubectl'
  target?: string
}

// ── Props ─────────────────────────────────────────────────────────────

interface KindPickerModalProps {
  open: boolean
  onClose: () => void
  onCreated: (tab: NewTabResponse) => void
}

// ── Helpers ───────────────────────────────────────────────────────────

function buildBackendPayload(tag: BackendTag, config: BackendConfig): Record<string, unknown> {
  const backend: Record<string, unknown> = { tag }
  if (tag === 'tmux') {
    if (config.session) backend.session = config.session
    if (config.window) backend.window = config.window
  } else if (tag === 'ssh') {
    if (config.host) backend.host = config.host
    if (config.port) backend.port = config.port
  } else if (tag === 'container') {
    if (config.engine) backend.engine = config.engine
    if (config.target) backend.target = config.target
  }
  return backend
}

function parseArgs(input: string): string[] {
  const trimmed = input.trim()
  if (!trimmed) return []
  return trimmed.split(/\s+/)
}

// ── Component ─────────────────────────────────────────────────────────

export function KindPickerModal({ open, onClose, onCreated }: KindPickerModalProps) {
  const [step, setStep] = useState<Step>('pick')
  const [category, setCategory] = useState<Category | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  // Provider form state
  const [provider, setProvider] = useState('anthropic')
  const [model, setModel] = useState('claude-sonnet-4-20250514')
  const [agent, setAgent] = useState('')

  // Harness form state
  const [flavour, setFlavour] = useState<HarnessFlavour>('claude-code')
  const [customBinary, setCustomBinary] = useState('')
  const [workingDir, setWorkingDir] = useState('')
  const [extraArgs, setExtraArgs] = useState('')

  // Backend state (shared by harness and raw shell)
  const [backendTag, setBackendTag] = useState<BackendTag>('local')
  const [backendConfig, setBackendConfig] = useState<BackendConfig>({ tag: 'local' })

  // Reset state when modal closes/opens
  useEffect(() => {
    if (open) {
      setStep('pick')
      setCategory(null)
      setError(null)
      setSubmitting(false)
      setProvider('anthropic')
      setModel('claude-sonnet-4-20250514')
      setAgent('')
      setFlavour('claude-code')
      setCustomBinary('')
      setWorkingDir('')
      setExtraArgs('')
      setBackendTag('local')
      setBackendConfig({ tag: 'local' })
    }
  }, [open])

  const handleCategorySelect = useCallback((cat: Category) => {
    setCategory(cat)
    setStep('form')
    setError(null)
    // Reset backend when switching categories
    setBackendTag('local')
    setBackendConfig({ tag: 'local' })
  }, [])

  const handleBack = useCallback(() => {
    setStep('pick')
    setError(null)
  }, [])

  const handleBackendTagChange = useCallback((tag: BackendTag) => {
    setBackendTag(tag)
    setBackendConfig({ tag })
  }, [])

  const updateBackendConfig = useCallback((updates: Partial<BackendConfig>) => {
    setBackendConfig((prev) => ({ ...prev, ...updates }))
  }, [])

  const validate = useCallback((): string | null => {
    if (category === 'harness' && flavour === 'custom' && !customBinary.trim()) {
      return 'Binary name is required for custom flavour'
    }
    if (category === 'harness' && backendTag === 'container' && !backendConfig.target?.trim()) {
      return 'Target is required for container backend'
    }
    if ((category === 'harness' || category === 'raw_shell') && backendTag === 'ssh' && !backendConfig.host?.trim()) {
      return 'Host is required for SSH backend'
    }
    return null
  }, [category, flavour, customBinary, backendTag, backendConfig])

  const buildBody = useCallback((): Record<string, unknown> => {
    if (category === 'provider') {
      const sessionKind: Record<string, unknown> = {
        tag: 'provider',
        provider,
        model,
      }
      if (agent.trim()) {
        sessionKind.agent = agent.trim()
      }
      return {
        kind: {
          tag: 'session',
          session_kind: sessionKind,
        },
      }
    }

    if (category === 'harness') {
      const effectiveFlavour = flavour === 'custom' ? customBinary.trim() : flavour
      const sessionKind: Record<string, unknown> = {
        tag: 'harness',
        flavour: effectiveFlavour,
        backend: buildBackendPayload(backendTag, backendConfig),
        args: parseArgs(extraArgs),
      }
      if (workingDir.trim()) {
        sessionKind.working_dir = workingDir.trim()
      }
      return {
        kind: {
          tag: 'session',
          session_kind: sessionKind,
        },
      }
    }

    // raw_shell
    return {
      kind: {
        tag: 'raw_shell',
        backend: buildBackendPayload(backendTag, backendConfig),
      },
    }
  }, [category, provider, model, agent, flavour, customBinary, backendTag, backendConfig, workingDir, extraArgs])

  const handleSubmit = useCallback(async () => {
    const validationError = validate()
    if (validationError) {
      setError(validationError)
      return
    }

    setSubmitting(true)
    setError(null)

    try {
      const body = buildBody()
      const res = await fetch('/api/tabs/new', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      })
      if (!res.ok) {
        setError('Failed to create tab')
        setSubmitting(false)
        return
      }
      const tab = await res.json() as NewTabResponse
      onCreated(tab)
      onClose()
    } catch {
      setError('Failed to create tab')
    } finally {
      setSubmitting(false)
    }
  }, [validate, buildBody, onCreated, onClose])

  if (!open) return null

  return (
    <div
      data-testid="modal-overlay"
      onClick={onClose}
      style={{
        position: 'fixed',
        inset: 0,
        background: 'rgba(0, 0, 0, 0.6)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        zIndex: 1000,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: 'var(--bg-surface)',
          border: '1px solid var(--border)',
          borderRadius: 'var(--radius-lg)',
          padding: 24,
          width: 480,
          maxHeight: '80vh',
          overflowY: 'auto',
          position: 'relative',
        }}
      >
        {/* Header */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
          <h2
            style={{
              fontSize: 16,
              fontWeight: 'var(--font-semibold)' as unknown as number,
              color: 'var(--text-primary)',
              margin: 0,
            }}
          >
            New Tab
          </h2>
          <button
            className="btn btn-ghost"
            onClick={onClose}
            aria-label="Close"
            style={{ width: 28, height: 28, padding: 0, fontSize: 16, lineHeight: 1 }}
          >
            ×
          </button>
        </div>

        {step === 'pick' && (
          <StepPick onSelect={handleCategorySelect} />
        )}

        {step === 'form' && category === 'provider' && (
          <ProviderForm
            provider={provider}
            model={model}
            agent={agent}
            onProviderChange={setProvider}
            onModelChange={setModel}
            onAgentChange={setAgent}
            onBack={handleBack}
            onSubmit={handleSubmit}
            submitting={submitting}
            error={error}
          />
        )}

        {step === 'form' && category === 'harness' && (
          <HarnessForm
            flavour={flavour}
            customBinary={customBinary}
            backendTag={backendTag}
            backendConfig={backendConfig}
            workingDir={workingDir}
            extraArgs={extraArgs}
            onFlavourChange={setFlavour}
            onCustomBinaryChange={setCustomBinary}
            onBackendTagChange={handleBackendTagChange}
            onBackendConfigUpdate={updateBackendConfig}
            onWorkingDirChange={setWorkingDir}
            onExtraArgsChange={setExtraArgs}
            onBack={handleBack}
            onSubmit={handleSubmit}
            submitting={submitting}
            error={error}
          />
        )}

        {step === 'form' && category === 'raw_shell' && (
          <RawShellForm
            backendTag={backendTag}
            backendConfig={backendConfig}
            onBackendTagChange={handleBackendTagChange}
            onBackendConfigUpdate={updateBackendConfig}
            onBack={handleBack}
            onSubmit={handleSubmit}
            submitting={submitting}
            error={error}
          />
        )}
      </div>
    </div>
  )
}

// ── Step 1: Category picker ───────────────────────────────────────────

const categories: { key: Category; label: string; description: string }[] = [
  { key: 'provider', label: 'AI Provider', description: 'Direct API call (Claude, GPT, Gemini...)' },
  { key: 'harness', label: 'AI Harness', description: 'External AI CLI tool (Claude Code, Codex, Aider...)' },
  { key: 'raw_shell', label: 'Raw Shell', description: 'Terminal session (local, SSH, tmux)' },
]

function StepPick({ onSelect }: { onSelect: (cat: Category) => void }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {categories.map((cat) => (
        <button
          key={cat.key}
          className="btn btn-ghost"
          onClick={() => onSelect(cat.key)}
          style={{
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'flex-start',
            padding: '12px 16px',
            textAlign: 'left',
          }}
        >
          <span
            style={{
              fontSize: 14,
              fontWeight: 'var(--font-semibold)' as unknown as number,
              color: 'var(--text-primary)',
            }}
          >
            {cat.label}
          </span>
          <span style={{ fontSize: 12, color: 'var(--text-muted)', marginTop: 2 }}>
            {cat.description}
          </span>
        </button>
      ))}
    </div>
  )
}

// ── Shared UI ─────────────────────────────────────────────────────────

const fieldStyle: React.CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 4,
}

const labelStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 500,
  color: 'var(--text-muted)',
}

const inputStyle: React.CSSProperties = {
  fontSize: 14,
  padding: '6px 10px',
  background: 'var(--bg-sunken)',
  border: '1px solid var(--border)',
  borderRadius: 'var(--radius-sm)',
  color: 'var(--text-primary)',
  outline: 'none',
  fontFamily: 'inherit',
}

function FormFooter({
  onBack,
  onSubmit,
  submitting,
  error,
}: {
  onBack: () => void
  onSubmit: () => void
  submitting: boolean
  error: string | null
}) {
  return (
    <>
      {error && (
        <div style={{ fontSize: 12, color: 'var(--needs-input)', marginTop: 8 }}>
          {error}
        </div>
      )}
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 16 }}>
        <button
          className="btn btn-ghost"
          onClick={onBack}
          aria-label="Back"
          style={{ padding: '6px 16px', fontSize: 13 }}
        >
          Back
        </button>
        <button
          className="btn btn-primary"
          onClick={onSubmit}
          disabled={submitting}
          style={{ padding: '6px 16px', fontSize: 13, borderRadius: 'var(--radius-sm)' }}
        >
          {submitting ? 'Creating...' : 'Create'}
        </button>
      </div>
    </>
  )
}

function BackendFields({
  tag,
  config,
  onConfigUpdate,
  includeContainer,
}: {
  tag: BackendTag
  config: BackendConfig
  onConfigUpdate: (updates: Partial<BackendConfig>) => void
  includeContainer?: boolean
}) {
  return (
    <>
      {tag === 'tmux' && (
        <>
          <div style={fieldStyle}>
            <label htmlFor="backend-session" style={labelStyle}>Session Name</label>
            <input
              id="backend-session"
              type="text"
              value={config.session ?? ''}
              onChange={(e) => onConfigUpdate({ session: e.target.value })}
              style={inputStyle}
              placeholder="e.g. main"
            />
          </div>
          <div style={fieldStyle}>
            <label htmlFor="backend-window" style={labelStyle}>Window</label>
            <input
              id="backend-window"
              type="text"
              value={config.window ?? ''}
              onChange={(e) => onConfigUpdate({ window: e.target.value })}
              style={inputStyle}
              placeholder="e.g. 0"
            />
          </div>
        </>
      )}

      {tag === 'ssh' && (
        <>
          <div style={fieldStyle}>
            <label htmlFor="backend-host" style={labelStyle}>Host</label>
            <input
              id="backend-host"
              type="text"
              value={config.host ?? ''}
              onChange={(e) => onConfigUpdate({ host: e.target.value })}
              style={inputStyle}
              placeholder="user@hostname"
            />
          </div>
          <div style={fieldStyle}>
            <label htmlFor="backend-port" style={labelStyle}>Port</label>
            <input
              id="backend-port"
              type="number"
              value={config.port ?? ''}
              onChange={(e) => onConfigUpdate({ port: e.target.value ? parseInt(e.target.value, 10) : undefined })}
              style={inputStyle}
              placeholder="22"
            />
          </div>
        </>
      )}

      {includeContainer && tag === 'container' && (
        <>
          <div style={fieldStyle}>
            <label htmlFor="backend-engine" style={labelStyle}>Engine</label>
            <select
              id="backend-engine"
              value={config.engine ?? 'docker'}
              onChange={(e) => onConfigUpdate({ engine: e.target.value as 'docker' | 'podman' | 'kubectl' })}
              style={inputStyle}
            >
              <option value="docker">Docker</option>
              <option value="podman">Podman</option>
              <option value="kubectl">kubectl</option>
            </select>
          </div>
          <div style={fieldStyle}>
            <label htmlFor="backend-target" style={labelStyle}>Target</label>
            <input
              id="backend-target"
              type="text"
              value={config.target ?? ''}
              onChange={(e) => onConfigUpdate({ target: e.target.value })}
              style={inputStyle}
              placeholder="container name or id"
            />
          </div>
        </>
      )}
    </>
  )
}

// ── Provider form ─────────────────────────────────────────────────────

function ProviderForm({
  provider,
  model,
  agent,
  onProviderChange,
  onModelChange,
  onAgentChange,
  onBack,
  onSubmit,
  submitting,
  error,
}: {
  provider: string
  model: string
  agent: string
  onProviderChange: (v: string) => void
  onModelChange: (v: string) => void
  onAgentChange: (v: string) => void
  onBack: () => void
  onSubmit: () => void
  submitting: boolean
  error: string | null
}) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={fieldStyle}>
        <label htmlFor="provider-select" style={labelStyle}>Provider</label>
        <select
          id="provider-select"
          value={provider}
          onChange={(e) => onProviderChange(e.target.value)}
          style={inputStyle}
        >
          <option value="anthropic">Anthropic</option>
          <option value="openai">OpenAI</option>
          <option value="google">Google</option>
        </select>
      </div>

      <div style={fieldStyle}>
        <label htmlFor="provider-model" style={labelStyle}>Model</label>
        <input
          id="provider-model"
          type="text"
          value={model}
          onChange={(e) => onModelChange(e.target.value)}
          style={inputStyle}
          placeholder="e.g. claude-sonnet-4-20250514"
        />
      </div>

      <div style={fieldStyle}>
        <label htmlFor="provider-agent" style={labelStyle}>Agent</label>
        <input
          id="provider-agent"
          type="text"
          value={agent}
          onChange={(e) => onAgentChange(e.target.value)}
          style={inputStyle}
          placeholder="Optional agent name"
        />
      </div>

      <FormFooter onBack={onBack} onSubmit={onSubmit} submitting={submitting} error={error} />
    </div>
  )
}

// ── Harness form ──────────────────────────────────────────────────────

function HarnessForm({
  flavour,
  customBinary,
  backendTag,
  backendConfig,
  workingDir,
  extraArgs,
  onFlavourChange,
  onCustomBinaryChange,
  onBackendTagChange,
  onBackendConfigUpdate,
  onWorkingDirChange,
  onExtraArgsChange,
  onBack,
  onSubmit,
  submitting,
  error,
}: {
  flavour: HarnessFlavour
  customBinary: string
  backendTag: BackendTag
  backendConfig: BackendConfig
  workingDir: string
  extraArgs: string
  onFlavourChange: (v: HarnessFlavour) => void
  onCustomBinaryChange: (v: string) => void
  onBackendTagChange: (tag: BackendTag) => void
  onBackendConfigUpdate: (updates: Partial<BackendConfig>) => void
  onWorkingDirChange: (v: string) => void
  onExtraArgsChange: (v: string) => void
  onBack: () => void
  onSubmit: () => void
  submitting: boolean
  error: string | null
}) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={fieldStyle}>
        <label htmlFor="harness-flavour" style={labelStyle}>Flavour</label>
        <select
          id="harness-flavour"
          value={flavour}
          onChange={(e) => onFlavourChange(e.target.value as HarnessFlavour)}
          style={inputStyle}
        >
          <option value="claude-code">Claude Code</option>
          <option value="codex">Codex</option>
          <option value="opencode">OpenCode</option>
          <option value="hermes">Hermes</option>
          <option value="pureclaw">PureClaw</option>
          <option value="custom">Custom</option>
        </select>
      </div>

      {flavour === 'custom' && (
        <div style={fieldStyle}>
          <label htmlFor="harness-binary" style={labelStyle}>Binary Name</label>
          <input
            id="harness-binary"
            type="text"
            value={customBinary}
            onChange={(e) => onCustomBinaryChange(e.target.value)}
            style={inputStyle}
            placeholder="e.g. my-ai-tool"
          />
        </div>
      )}

      <div style={fieldStyle}>
        <label htmlFor="harness-backend" style={labelStyle}>Backend</label>
        <select
          id="harness-backend"
          value={backendTag}
          onChange={(e) => onBackendTagChange(e.target.value as BackendTag)}
          style={inputStyle}
        >
          <option value="local">Local</option>
          <option value="tmux">tmux</option>
          <option value="ssh">SSH</option>
          <option value="container">Container</option>
        </select>
      </div>

      <BackendFields
        tag={backendTag}
        config={backendConfig}
        onConfigUpdate={onBackendConfigUpdate}
        includeContainer={true}
      />

      <div style={fieldStyle}>
        <label htmlFor="harness-workdir" style={labelStyle}>Working Directory</label>
        <input
          id="harness-workdir"
          type="text"
          value={workingDir}
          onChange={(e) => onWorkingDirChange(e.target.value)}
          style={inputStyle}
          placeholder="Optional working directory"
        />
      </div>

      <div style={fieldStyle}>
        <label htmlFor="harness-args" style={labelStyle}>Extra Args</label>
        <input
          id="harness-args"
          type="text"
          value={extraArgs}
          onChange={(e) => onExtraArgsChange(e.target.value)}
          style={inputStyle}
          placeholder="e.g. --verbose --debug"
        />
      </div>

      <FormFooter onBack={onBack} onSubmit={onSubmit} submitting={submitting} error={error} />
    </div>
  )
}

// ── Raw shell form ────────────────────────────────────────────────────

function RawShellForm({
  backendTag,
  backendConfig,
  onBackendTagChange,
  onBackendConfigUpdate,
  onBack,
  onSubmit,
  submitting,
  error,
}: {
  backendTag: BackendTag
  backendConfig: BackendConfig
  onBackendTagChange: (tag: BackendTag) => void
  onBackendConfigUpdate: (updates: Partial<BackendConfig>) => void
  onBack: () => void
  onSubmit: () => void
  submitting: boolean
  error: string | null
}) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={fieldStyle}>
        <label htmlFor="shell-backend" style={labelStyle}>Backend</label>
        <select
          id="shell-backend"
          value={backendTag}
          onChange={(e) => onBackendTagChange(e.target.value as BackendTag)}
          style={inputStyle}
        >
          <option value="local">Local</option>
          <option value="tmux">tmux</option>
          <option value="ssh">SSH</option>
        </select>
      </div>

      <BackendFields
        tag={backendTag}
        config={backendConfig}
        onConfigUpdate={onBackendConfigUpdate}
      />

      <FormFooter onBack={onBack} onSubmit={onSubmit} submitting={submitting} error={error} />
    </div>
  )
}
