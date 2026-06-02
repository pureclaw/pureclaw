import {
  CUSTOM_MODEL_VALUE,
  type BackendConfig,
  type BackendTag,
  type HarnessFlavour,
  type NewTabKind,
  type NewTabSpec,
} from '../hooks/useNewTabSpec'

const PROVIDER_LABELS: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI',
  openrouter: 'OpenRouter',
  ollama: 'Ollama',
}

// ── Props ─────────────────────────────────────────────────────────────

interface NewTabComposerProps {
  spec: NewTabSpec
}

// ── Component ─────────────────────────────────────────────────────────

export function NewTabComposer({ spec }: NewTabComposerProps) {
  const safeAgents = Array.isArray(spec.agents) ? spec.agents : []
  const noProviders = spec.providersLoaded && spec.configuredProviders.length === 0

  return (
    <div style={{
      display: 'flex',
      flexDirection: 'column',
      gap: 16,
      maxWidth: 640,
      margin: '0 auto',
      padding: '24px 0',
    }}>
      <div style={{ fontSize: 16, fontWeight: 600, color: 'var(--text-primary)' }}>
        Start a new tab
      </div>

      {/* Kind pills */}
      <div role="radiogroup" aria-label="Tab kind" style={{ display: 'flex', gap: 6 }}>
        {(['provider', 'harness'] as NewTabKind[]).map((k) => (
          <button
            key={k}
            type="button"
            role="radio"
            aria-checked={spec.kind === k}
            onClick={() => spec.setKind(k)}
            className={spec.kind === k ? 'btn btn-primary' : 'btn btn-ghost'}
            style={{
              padding: '6px 12px',
              fontSize: 13,
              borderRadius: 'var(--radius-sm)',
              border: '1px solid var(--border)',
            }}
          >
            {k === 'provider' ? 'AI Provider' : 'AI Harness'}
          </button>
        ))}
      </div>

      {/* Provider kind config */}
      {spec.kind === 'provider' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Row label="Provider" htmlFor="provider-select">
            <select
              id="provider-select"
              value={spec.provider}
              onChange={(e) => spec.setProvider(e.target.value)}
              disabled={!spec.providersLoaded || noProviders}
              style={inputStyle}
            >
              {!spec.providersLoaded && <option value="">Loading…</option>}
              {noProviders && (
                <option value="" disabled>
                  (no providers configured — set an API key or start Ollama)
                </option>
              )}
              {spec.configuredProviders.map((p) => (
                <option key={p.name} value={p.name}>
                  {PROVIDER_LABELS[p.name] ?? p.name}{p.isDefault ? ' (default)' : ''}
                </option>
              ))}
            </select>
          </Row>

          <Row label="Model" htmlFor="provider-model">
            <select
              id="provider-model"
              value={spec.useCustomModel ? CUSTOM_MODEL_VALUE : spec.model}
              onChange={(e) => spec.handleModelSelectChange(e.target.value)}
              disabled={spec.modelsLoading}
              style={inputStyle}
            >
              {spec.modelsLoading && <option value="">Loading…</option>}
              {!spec.modelsLoading && spec.models.length === 0 && (
                <option value="" disabled>(no models — choose Custom… and enter one)</option>
              )}
              {spec.models.map((m) => <option key={m} value={m}>{m}</option>)}
              <option value={CUSTOM_MODEL_VALUE}>Custom…</option>
            </select>
          </Row>

          {spec.useCustomModel && (
            <Row label="Custom Model" htmlFor="provider-model-custom">
              <input
                id="provider-model-custom"
                type="text"
                value={spec.model}
                onChange={(e) => spec.setModel(e.target.value)}
                style={inputStyle}
                placeholder="model id (e.g. claude-3-opus-20240229)"
              />
            </Row>
          )}

          <Row label="Agent" htmlFor="provider-agent">
            <select
              id="provider-agent"
              value={spec.agent}
              onChange={(e) => spec.handleAgentChange(e.target.value)}
              style={inputStyle}
            >
              <option value="">(none)</option>
              {safeAgents.map((a) => (
                <option key={a.name} value={a.name}>
                  {a.name}{a.isDefault ? ' (default)' : ''}
                </option>
              ))}
            </select>
          </Row>

          {/* Backend for tool-call execution. The LLM exchange itself is
              just prompts in, responses out — but tool calls (shell,
              file ops, ...) need an execution environment. */}
          <Row label="Tool Backend" htmlFor="provider-backend">
            <select
              id="provider-backend"
              value={spec.backendTag}
              onChange={(e) => spec.handleBackendTagChange(e.target.value as BackendTag)}
              style={inputStyle}
            >
              <option value="local">Local</option>
              <option value="tmux">tmux</option>
              <option value="ssh">SSH</option>
              <option value="container">Container</option>
            </select>
          </Row>

          <BackendFields tag={spec.backendTag} config={spec.backendConfig} onConfigUpdate={spec.updateBackendConfig} includeContainer={true} />
        </div>
      )}

      {/* Harness kind config */}
      {spec.kind === 'harness' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <Row label="Flavour" htmlFor="harness-flavour">
            <select
              id="harness-flavour"
              value={spec.flavour}
              onChange={(e) => spec.setFlavour(e.target.value as HarnessFlavour)}
              style={inputStyle}
            >
              <option value="claude-code">Claude Code</option>
              <option value="codex">Codex</option>
              <option value="opencode">OpenCode</option>
              <option value="hermes">Hermes</option>
              <option value="pureclaw">PureClaw</option>
              <option value="custom">Custom</option>
            </select>
          </Row>

          {spec.flavour === 'custom' && (
            <Row label="Binary Name" htmlFor="harness-binary">
              <input
                id="harness-binary"
                type="text"
                value={spec.customBinary}
                onChange={(e) => spec.setCustomBinary(e.target.value)}
                style={inputStyle}
                placeholder="e.g. my-ai-tool"
              />
            </Row>
          )}

          <Row label="Backend" htmlFor="harness-backend">
            <select
              id="harness-backend"
              value={spec.backendTag}
              onChange={(e) => spec.handleBackendTagChange(e.target.value as BackendTag)}
              style={inputStyle}
            >
              <option value="local">Local</option>
              <option value="tmux">tmux</option>
              <option value="ssh">SSH</option>
              <option value="container">Container</option>
            </select>
          </Row>

          <BackendFields tag={spec.backendTag} config={spec.backendConfig} onConfigUpdate={spec.updateBackendConfig} includeContainer={true} />

          <Row label="Working Directory" htmlFor="harness-workdir">
            <input
              id="harness-workdir"
              type="text"
              value={spec.workingDir}
              onChange={(e) => spec.setWorkingDir(e.target.value)}
              style={inputStyle}
              placeholder="Optional working directory"
            />
          </Row>

          <Row label="Extra Args" htmlFor="harness-args">
            <input
              id="harness-args"
              type="text"
              value={spec.extraArgs}
              onChange={(e) => spec.setExtraArgs(e.target.value)}
              style={inputStyle}
              placeholder="e.g. --verbose --debug"
            />
          </Row>
        </div>
      )}

      {/* Inline validation hint. Helps the user understand why the
          bottom send button is disabled (and what to fix). */}
      {spec.validationError && (
        <div
          data-testid="composer-validation-error"
          style={{ fontSize: 12, color: 'var(--needs-input)' }}
        >
          {spec.validationError}
        </div>
      )}
    </div>
  )
}

// ── Small helpers ─────────────────────────────────────────────────────

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
  width: '100%',
}

function Row({
  label, htmlFor, children,
}: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '140px 1fr', alignItems: 'center', gap: 12 }}>
      <label htmlFor={htmlFor} style={labelStyle}>{label}</label>
      <div>{children}</div>
    </div>
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
          {/* No Window input: the tmux window is auto-assigned by the
              backend (`canonical-<idx>`) and ignored for placement, so the
              user only picks the session. buildBackendPayload still sends
              `window: ''` to satisfy the backend's required decode. */}
          <Row label="Session Name" htmlFor="backend-session">
            <input
              id="backend-session"
              type="text"
              value={config.session ?? ''}
              onChange={(e) => onConfigUpdate({ session: e.target.value })}
              style={inputStyle}
              placeholder="e.g. main"
            />
          </Row>
        </>
      )}
      {tag === 'ssh' && (
        <>
          <Row label="Host" htmlFor="backend-host">
            <input
              id="backend-host"
              type="text"
              value={config.host ?? ''}
              onChange={(e) => onConfigUpdate({ host: e.target.value })}
              style={inputStyle}
              placeholder="user@hostname"
            />
          </Row>
          <Row label="Port" htmlFor="backend-port">
            <input
              id="backend-port"
              type="number"
              value={config.port ?? ''}
              onChange={(e) => onConfigUpdate({ port: e.target.value ? parseInt(e.target.value, 10) : undefined })}
              style={inputStyle}
              placeholder="22"
            />
          </Row>
        </>
      )}
      {includeContainer && tag === 'container' && (
        <>
          <Row label="Engine" htmlFor="backend-engine">
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
          </Row>
          <Row label="Target" htmlFor="backend-target">
            <input
              id="backend-target"
              type="text"
              value={config.target ?? ''}
              onChange={(e) => onConfigUpdate({ target: e.target.value })}
              style={inputStyle}
              placeholder="container name or id"
            />
          </Row>
        </>
      )}
    </>
  )
}
