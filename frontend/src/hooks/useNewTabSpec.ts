import { useState, useEffect, useCallback } from 'react'
import { useAgents, useConfiguredProviders, fetchProviderModels, type ProviderInfo } from './useApi'
import type { AgentInfo } from '../types'

export type NewTabKind = 'provider' | 'harness'
export type BackendTag = 'local' | 'tmux' | 'ssh' | 'container'
export type HarnessFlavour = 'claude-code' | 'codex' | 'opencode' | 'hermes' | 'pureclaw' | 'custom'

export const CUSTOM_MODEL_VALUE = '__custom__'

export interface BackendConfig {
  tag: BackendTag
  session?: string
  window?: string
  host?: string
  port?: number
  engine?: 'docker' | 'podman' | 'kubectl'
  target?: string
}

/** State + handlers + computed values for the "new tab" inline composer.
 *
 * The hook tries to keep the form in a continuously-valid state so the
 * bottom message input stays active. The only way to land in an invalid
 * state is to opt into one explicitly (pick "Custom…" model and don't fill
 * it; pick the custom harness flavour and don't name a binary; pick SSH or
 * container backend without host/target). In those cases `validationError`
 * is non-null and the chat input disables. */
export interface NewTabSpec {
  // Kind
  kind: NewTabKind
  setKind: (k: NewTabKind) => void

  // Provider
  configuredProviders: ProviderInfo[]
  providersLoaded: boolean
  provider: string
  setProvider: (v: string) => void

  model: string
  setModel: (v: string) => void
  models: string[]
  modelsLoading: boolean
  useCustomModel: boolean
  handleModelSelectChange: (v: string) => void

  agent: string
  agents: AgentInfo[]
  handleAgentChange: (v: string) => void

  // Harness
  flavour: HarnessFlavour
  setFlavour: (v: HarnessFlavour) => void
  customBinary: string
  setCustomBinary: (v: string) => void
  workingDir: string
  setWorkingDir: (v: string) => void
  extraArgs: string
  setExtraArgs: (v: string) => void

  // Backend (shared by harness + raw_shell)
  backendTag: BackendTag
  handleBackendTagChange: (t: BackendTag) => void
  backendConfig: BackendConfig
  updateBackendConfig: (updates: Partial<BackendConfig>) => void

  // Computed
  /** Human-readable error if the spec is not submittable, else null. */
  validationError: string | null
  /** Build the POST /api/tabs/new body from the current spec. */
  buildBody: () => Record<string, unknown>
}

function buildBackendPayload(tag: BackendTag, config: BackendConfig): Record<string, unknown> {
  const backend: Record<string, unknown> = { tag }
  if (tag === 'tmux') {
    if (config.session) backend.session = config.session
    // The tmux window is auto-assigned by the backend (`canonical-<idx>`)
    // and ignored for placement, so the composer no longer offers a Window
    // input. We still emit the key unconditionally because the backend's
    // `TmuxConfig` request decode requires `o .: "window"`; sending `''`
    // satisfies that decode while letting the server pick the real name.
    backend.window = config.window ?? ''
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

export function useNewTabSpec(): NewTabSpec {
  // Kind
  const [kind, setKind] = useState<NewTabKind>('provider')

  // Provider
  const { providers: configuredProviders, loaded: providersLoaded } = useConfiguredProviders()
  const [provider, setProvider] = useState<string>('')
  const [model, setModel] = useState<string>('')
  const [useCustomModel, setUseCustomModel] = useState(false)
  const [models, setModels] = useState<string[]>([])
  const [modelsLoading, setModelsLoading] = useState(false)

  // Agent
  const { agents } = useAgents()
  const [agent, setAgent] = useState<string>('')
  const [agentTouched, setAgentTouched] = useState(false)

  // Harness
  const [flavour, setFlavour] = useState<HarnessFlavour>('claude-code')
  const [customBinary, setCustomBinary] = useState('')
  const [workingDir, setWorkingDir] = useState('')
  const [extraArgs, setExtraArgs] = useState('')

  // Backend
  const [backendTag, setBackendTag] = useState<BackendTag>('local')
  const [backendConfig, setBackendConfig] = useState<BackendConfig>({ tag: 'local' })

  // Default the provider to whatever PureClaw is configured to use (the
  // entry marked isDefault by the backend), or — failing that — the
  // first one in the configured list.
  useEffect(() => {
    if (!providersLoaded || configuredProviders.length === 0) return
    const names = configuredProviders.map((p) => p.name)
    if (!provider || !names.includes(provider)) {
      const def = configuredProviders.find((p) => p.isDefault)
      setProvider((def ?? configuredProviders[0]!).name)
    }
  }, [providersLoaded, configuredProviders, provider])

  // Fetch the model list when the provider changes (and we're in
  // provider mode). Pre-select the configured default if it appears in
  // the list, otherwise fall back to the first entry.
  useEffect(() => {
    if (kind !== 'provider' || !provider) return
    let cancelled = false
    setModelsLoading(true)
    setModels([])
    const info = configuredProviders.find((p) => p.name === provider)
    fetchProviderModels(provider).then((ids) => {
      if (cancelled) return
      setModels(ids)
      setModelsLoading(false)
      setUseCustomModel(false)
      const dflt = info?.defaultModel
      if (dflt && ids.includes(dflt)) {
        setModel(dflt)
      } else {
        setModel(ids.length > 0 ? ids[0]! : '')
      }
    })
    return () => { cancelled = true }
  }, [kind, provider, configuredProviders])

  // Auto-select the configured default agent.
  useEffect(() => {
    if (agentTouched) return
    const def = Array.isArray(agents) ? agents.find((a) => a.isDefault) : undefined
    if (def) setAgent(def.name)
  }, [agents, agentTouched])

  const handleModelSelectChange = useCallback((value: string) => {
    if (value === CUSTOM_MODEL_VALUE) {
      setUseCustomModel(true)
      setModel('')
    } else {
      setUseCustomModel(false)
      setModel(value)
    }
  }, [])

  const handleAgentChange = useCallback((value: string) => {
    setAgentTouched(true)
    setAgent(value)
  }, [])

  const handleBackendTagChange = useCallback((tag: BackendTag) => {
    setBackendTag(tag)
    setBackendConfig({ tag })
  }, [])

  const updateBackendConfig = useCallback((updates: Partial<BackendConfig>) => {
    setBackendConfig((prev) => ({ ...prev, ...updates }))
  }, [])

  // Validation. Defaults are designed to keep this null.
  const validationError: string | null = (() => {
    if (kind === 'provider') {
      if (providersLoaded && configuredProviders.length === 0) {
        return 'No providers configured — set an API key or start Ollama'
      }
      if (modelsLoading) return 'Loading models…'
      if (!model.trim()) return useCustomModel ? 'Enter a custom model id' : 'Pick a model'
    }
    if (kind === 'harness' && flavour === 'custom' && !customBinary.trim()) {
      return 'Binary name is required for custom flavour'
    }
    // Backend sub-field validation applies to both kinds — the LLM's
    // tool calls (provider) and the harness binary's environment
    // (harness) both run against the chosen TerminalBackend.
    if (backendTag === 'ssh' && !backendConfig.host?.trim()) {
      return 'Host is required for SSH backend'
    }
    if (backendTag === 'container' && !backendConfig.target?.trim()) {
      return 'Target is required for container backend'
    }
    return null
  })()

  const buildBody = useCallback((): Record<string, unknown> => {
    if (kind === 'provider') {
      const sessionKind: Record<string, unknown> = {
        tag: 'provider',
        provider,
        model: model.trim(),
        // Forward-compatible: the backend currently ignores this field
        // for provider sessions, but the frontend records the user's
        // chosen tool-execution environment so it's preserved once the
        // backend wires up remote tool execution.
        backend: buildBackendPayload(backendTag, backendConfig),
      }
      if (agent.trim()) sessionKind.agent = agent.trim()
      return { kind: { tag: 'session', session_kind: sessionKind } }
    }
    // kind === 'harness'
    const effectiveFlavour = flavour === 'custom' ? customBinary.trim() : flavour
    const sessionKind: Record<string, unknown> = {
      tag: 'harness',
      flavour: effectiveFlavour,
      backend: buildBackendPayload(backendTag, backendConfig),
      args: parseArgs(extraArgs),
    }
    if (workingDir.trim()) sessionKind.working_dir = workingDir.trim()
    return { kind: { tag: 'session', session_kind: sessionKind } }
  }, [kind, provider, model, agent, flavour, customBinary, workingDir, extraArgs, backendTag, backendConfig])

  return {
    kind, setKind,
    configuredProviders, providersLoaded,
    provider, setProvider,
    model, setModel, models, modelsLoading, useCustomModel, handleModelSelectChange,
    agent, agents, handleAgentChange,
    flavour, setFlavour,
    customBinary, setCustomBinary,
    workingDir, setWorkingDir,
    extraArgs, setExtraArgs,
    backendTag, handleBackendTagChange,
    backendConfig, updateBackendConfig,
    validationError,
    buildBody,
  }
}
