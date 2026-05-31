import { render, fireEvent, waitFor, act } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { SessionInfo, TabInfo, TranscriptEntry, AgentInfo } from '../types'

// ---------------------------------------------------------------------------
// Mock all of App's data hooks so it renders without real WS / network. Each
// mock reads from mutable module-level state we control per-test so we can
// drive the focused-session, transcript, and sessions-list inputs that gate
// the branch flow.
// ---------------------------------------------------------------------------

interface HookState {
  tabs: TabInfo[]
  recentSessions: SessionInfo[]
  archivedSessions: SessionInfo[]
  agents: AgentInfo[]
  // Transcript entries keyed by the session id useTranscript is asked for.
  transcripts: Record<string, TranscriptEntry[]>
}

const state: HookState = {
  tabs: [],
  recentSessions: [],
  archivedSessions: [],
  agents: [],
  transcripts: {},
}

const focusSpy = vi.fn()
const sendSpy = vi.fn()

vi.mock('../lib/streamClient', () => ({
  streamClient: () => ({
    focus: focusSpy,
    onLists: () => () => {},
    onEntry: () => () => {},
    onActivity: () => () => {},
    onStatus: () => () => {},
  }),
}))

vi.mock('../hooks/useListsStream', () => ({
  useListsStream: () => ({
    tabs: state.tabs,
    recentSessions: state.recentSessions,
    archivedSessions: state.archivedSessions,
  }),
}))

vi.mock('../hooks/useTranscriptStream', () => ({
  useTranscriptStream: () => ({ entries: [] }),
  reconcileEntries: (acc: TranscriptEntry[]) => acc,
}))

vi.mock('../hooks/useSessionActivityStream', () => ({
  useSessionActivityStream: () => ({ sessions: {} }),
}))

vi.mock('../hooks/useApi', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useApi')>()
  return {
    ...actual,
    useTranscript: (sessionId: string | null) => ({
      entries: sessionId ? (state.transcripts[sessionId] ?? []) : [],
      loading: false,
      refresh: vi.fn(),
    }),
    useSendMessage: () => ({ send: sendSpy, sending: false }),
    useAgents: () => ({ agents: state.agents }),
    setSessionPrompt: vi.fn().mockResolvedValue(true),
    setSessionArchived: vi.fn().mockResolvedValue(true),
    setSessionDescription: vi.fn().mockResolvedValue(true),
    closeTab: vi.fn().mockResolvedValue(undefined),
  }
})

// useNewTabSpec drives the composer; we only need buildBody + a few scalar
// fields read by App and ChatArea.
vi.mock('../hooks/useNewTabSpec', () => ({
  CUSTOM_MODEL_VALUE: '__custom__',
  useNewTabSpec: () => ({
    kind: 'provider',
    setKind: vi.fn(),
    configuredProviders: [],
    providersLoaded: true,
    provider: '',
    setProvider: vi.fn(),
    model: 'sonnet',
    setModel: vi.fn(),
    models: [],
    modelsLoading: false,
    useCustomModel: false,
    handleModelSelectChange: vi.fn(),
    agent: '',
    agents: [],
    handleAgentChange: vi.fn(),
    flavour: 'claude-code',
    setFlavour: vi.fn(),
    customBinary: '',
    setCustomBinary: vi.fn(),
    workingDir: '',
    setWorkingDir: vi.fn(),
    extraArgs: '',
    setExtraArgs: vi.fn(),
    backendTag: 'local',
    handleBackendTagChange: vi.fn(),
    backendConfig: {},
    updateBackendConfig: vi.fn(),
    validationError: null,
    // Worst case for the branch flow: the shared composer is in 'harness'
    // mode (the user toggled it on a prior New-tab). A branch send must
    // override this to a provider kind (see the D-harness-override test),
    // otherwise the backend rejects the branch with a misleading error.
    buildBody: () => ({ kind: { tag: 'session', session_kind: { tag: 'harness', flavour: 'claude-code' } } }),
  }),
}))

// Import App AFTER the mocks are registered.
import App from '../App'

function providerSession(id: string): SessionInfo {
  return {
    id,
    agent: null,
    runtime: 'provider',
    model: 'sonnet',
    lastActive: '2024-01-01T00:00:00Z',
    createdAt: '2024-01-01T00:00:00Z',
    description: null,
    autoSummary: null,
    firstMessageSnippet: null,
    channel: null,
    channelUserId: null,
  }
}

function harnessSession(id: string): SessionInfo {
  return { ...providerSession(id), runtime: 'harness:claude-code' }
}

/** Build a request entry that produces a user row with the given text. */
function userEntry(id: string, text: string): TranscriptEntry {
  return {
    id,
    timestamp: '2024-01-01T00:00:00Z',
    direction: 'request',
    payload: JSON.stringify({ model: 'sonnet', messages: [{ role: 'user', content: [{ type: 'text', text }] }] }),
    harness: null,
    model: 'sonnet',
  }
}

/** Build a response entry (assistant row) with the given text. */
function assistantEntry(id: string, text: string): TranscriptEntry {
  return {
    id,
    timestamp: '2024-01-01T00:00:01Z',
    direction: 'response',
    payload: JSON.stringify({ content: [{ type: 'text', text }] }),
    harness: null,
    model: 'sonnet',
  }
}

function mockFetchOk(sessionId: string, tabIndex = 1) {
  const fetchMock = vi.fn(async (url: string, _init?: RequestInit) => {
    if (typeof url === 'string' && url === '/api/tabs/new') {
      return new Response(JSON.stringify({ tab_index: tabIndex, session_id: sessionId, kind: 'session' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }
    // /send and anything else
    return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } })
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

beforeEach(() => {
  state.tabs = []
  state.recentSessions = []
  state.archivedSessions = []
  state.agents = []
  state.transcripts = {}
  focusSpy.mockReset()
  sendSpy.mockReset()
  window.history.replaceState(null, '', '/')
  // jsdom has no layout; ChatArea scrolls refs into view.
  HTMLElement.prototype.scrollIntoView = vi.fn() as unknown as HTMLElement['scrollIntoView']
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const BRANCH_LABEL = 'branch session from here'

/** Render App focused on a provider session whose transcript has two user
 *  rows, returning testing-library helpers. */
function renderOnProviderSession(sid = 'src-1') {
  state.recentSessions = [providerSession(sid)]
  state.transcripts[sid] = [userEntry('e1', 'first message'), userEntry('e2', 'second message')]
  window.history.replaceState(null, '', `/session/${sid}`)
  return render(<App />)
}

describe('App branch draft flow', () => {
  it('D12: clicking branch enters compose mode showing the prefix read-only and makes NO /api/tabs/new call', async () => {
    const fetchMock = mockFetchOk('new-1')
    const utils = renderOnProviderSession()

    // Two branch buttons (one per user row).
    const branchButtons = utils.getAllByLabelText(BRANCH_LABEL)
    expect(branchButtons.length).toBe(2)

    fireEvent.click(branchButtons[0]!)

    // Compose mode: the composer placeholder appears.
    await waitFor(() => {
      expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    })
    // Lazy: no tab creation on click.
    expect(fetchMock).not.toHaveBeenCalled()
    // Prefix (the clicked row, inclusive) is rendered.
    expect(utils.getByText('first message')).toBeTruthy()
    // The textarea is focused.
    const textarea = document.querySelector('textarea')
    expect(document.activeElement).toBe(textarea)
  })

  it('D12b: the prefix message text is present in the DOM while in compose mode (selectedId === null)', async () => {
    mockFetchOk('new-1')
    const utils = renderOnProviderSession()
    // Branch from the SECOND row → prefix includes both rows.
    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => {
      expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    })
    expect(utils.getByText('first message')).toBeTruthy()
    expect(utils.getByText('second message')).toBeTruthy()
  })

  it('a branch draft hides the new-session composer form (inherits source settings)', async () => {
    mockFetchOk('new-1')
    const utils = renderOnProviderSession()
    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[0]!)
    await waitFor(() => {
      expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    })
    // The NewTabComposer "Tab kind" radiogroup must NOT render for a branch
    // draft — it inherits the forked session's settings. The model dropdown
    // (input-row) is still available.
    expect(utils.queryByLabelText('Tab kind')).toBeNull()
    expect(utils.queryByLabelText('session model')).toBeTruthy()
  })

  it('a normal New-tab compose DOES show the composer form', async () => {
    mockFetchOk('new-1')
    // No branch: render at root (compose mode) with no recent sessions.
    window.history.replaceState(null, '', '/')
    const utils = render(<App />)
    await waitFor(() => {
      expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    })
    expect(utils.queryByLabelText('Tab kind')).toBeTruthy()
  })

  it('D12a: prefix rows in branch-draft mode render NO branch button (non-interactive)', async () => {
    mockFetchOk('new-1')
    const utils = renderOnProviderSession()
    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => {
      expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    })
    // No branch buttons on the read-only prefix rows.
    expect(utils.queryByLabelText(BRANCH_LABEL)).toBeNull()
  })

  it('D13: first send POSTs /api/tabs/new with branch_from, then POSTs /send, then switches to the new session', async () => {
    const newSid = 'new-99'
    const fetchMock = mockFetchOk(newSid)
    const utils = renderOnProviderSession('src-1')

    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'continue here' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    await waitFor(() => {
      const tabsNewCall = fetchMock.mock.calls.find((c) => c[0] === '/api/tabs/new')
      expect(tabsNewCall).toBeTruthy()
    })

    // Ordering: tabs/new before send.
    const urls = fetchMock.mock.calls.map((c) => c[0] as string)
    const newIdx = urls.indexOf('/api/tabs/new')
    const sendIdx = urls.findIndex((u) => u.includes('/send'))
    expect(newIdx).toBeGreaterThanOrEqual(0)
    expect(sendIdx).toBeGreaterThan(newIdx)

    // Body of tabs/new carries branch_from with source id + boundary.
    const newCall = fetchMock.mock.calls[newIdx]!
    const body = JSON.parse((newCall[1] as RequestInit).body as string)
    expect(body.branch_from).toEqual({ session_id: 'src-1', up_to_entry_id: 'e2' })

    // /send body carries the trimmed message.
    const sendCall = fetchMock.mock.calls[sendIdx]!
    const sendBody = JSON.parse((sendCall[1] as RequestInit).body as string)
    expect(sendBody.message).toBe('continue here')

    // Switched to the new session (URL reflects it).
    expect(window.location.pathname).toBe(`/session/${newSid}`)
  })

  it('forces a provider session_kind on a branch send even when the composer is in harness mode', async () => {
    const fetchMock = mockFetchOk('new-99')
    const utils = renderOnProviderSession('src-1')

    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'continue here' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    await waitFor(() => {
      expect(fetchMock.mock.calls.find((c) => c[0] === '/api/tabs/new')).toBeTruthy()
    })
    const urls = fetchMock.mock.calls.map((c) => c[0] as string)
    const newCall = fetchMock.mock.calls[urls.indexOf('/api/tabs/new')]!
    const body = JSON.parse((newCall[1] as RequestInit).body as string)
    // Even though buildBody() returned a harness kind, the branch path
    // forces a provider session_kind so the backend's provider-only guard
    // is never tripped.
    expect(body.kind.session_kind.tag).toBe('provider')
    expect(body.branch_from).toEqual({ session_id: 'src-1', up_to_entry_id: 'e2' })
  })

  it('D14: a non-OK branch POST shows a visible error and RETAINS the branch draft', async () => {
    // tabs/new returns 404.
    const fetchMock = vi.fn(async (url: string, _init?: RequestInit) => {
      if (url === '/api/tabs/new') {
        return new Response('{"error":"entry gone"}', { status: 404, headers: { 'Content-Type': 'application/json' } })
      }
      return new Response('{}', { status: 200, headers: { 'Content-Type': 'application/json' } })
    })
    vi.stubGlobal('fetch', fetchMock)

    const utils = renderOnProviderSession('src-1')
    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'continue here' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    // A visible error appears.
    await waitFor(() => {
      expect(utils.getByText(/could not (create|start) the branch|branch failed/i)).toBeTruthy()
    })
    // No /send happened.
    expect(fetchMock.mock.calls.some((c) => (c[0] as string).includes('/send'))).toBe(false)
    // Draft retained: still in compose mode, prefix still rendered.
    expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
    expect(utils.getByText('first message')).toBeTruthy()
    expect(window.location.pathname).toBe('/')
  })

  it('D15a: a second branch click before sending replaces the draft (prefix updates to the new boundary)', async () => {
    mockFetchOk('new-1')
    state.recentSessions = [providerSession('src-1')]
    // First row is a user message, second is an assistant response.
    state.transcripts['src-1'] = [userEntry('e1', 'only-first'), assistantEntry('e2', 'second-asst')]
    window.history.replaceState(null, '', '/session/src-1')
    const utils = render(<App />)

    // Branch from the FIRST (user) row → prefix = [e1].
    const branchBtns = utils.getAllByLabelText(BRANCH_LABEL)
    fireEvent.click(branchBtns[0]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))
    expect(utils.getByText('only-first')).toBeTruthy()
    expect(utils.queryByText('second-asst')).toBeNull()

    // Re-select the source session from the sidebar so its transcript (and
    // the branch buttons) render again, then branch from a different row.
    const srcRow = utils.getAllByText(/src-1/).map((el) => el.closest('.session-row')).find(Boolean)
    fireEvent.click(srcRow as HTMLElement)
    await waitFor(() => utils.getAllByLabelText(BRANCH_LABEL))
    const branchBtns2 = utils.getAllByLabelText(BRANCH_LABEL)
    // Branch from the LAST row (assistant) → prefix = [e1, e2].
    fireEvent.click(branchBtns2[branchBtns2.length - 1]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))
    expect(utils.getByText('only-first')).toBeTruthy()
    expect(utils.getByText('second-asst')).toBeTruthy()
  })

  it('D15: harness sessions get no branch button (onBranch undefined)', () => {
    state.recentSessions = [harnessSession('h-1')]
    state.transcripts['h-1'] = [userEntry('e1', 'harness msg')]
    window.history.replaceState(null, '', '/session/h-1')
    const utils = render(<App />)
    expect(utils.queryByLabelText(BRANCH_LABEL)).toBeNull()
  })

  it('D15: clicking New tab clears the branch draft (prefix no longer shown)', async () => {
    mockFetchOk('new-1')
    const utils = renderOnProviderSession('src-1')
    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => utils.getByText('first message'))

    // Click the New tab "+" button in the sidebar.
    const newTabBtn = utils.getByLabelText(/new (tab|session)/i)
    fireEvent.click(newTabBtn)

    await waitFor(() => {
      expect(utils.queryByText('first message')).toBeNull()
    })
    // Still in compose mode (New tab), but no prefix.
    expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()
  })

  it('U2/U5: overriding the model dropdown sends the chosen model on the next /send', async () => {
    const sid = 'src-1'
    state.recentSessions = [providerSession(sid)]
    // Two request entries; the most-recent _te_model column is "opus-4".
    state.transcripts[sid] = [
      { ...userEntry('e1', 'first'), model: 'sonnet-4' },
      { ...userEntry('e2', 'second'), model: 'opus-4' },
    ]
    window.history.replaceState(null, '', `/session/${sid}`)
    const utils = render(<App />)

    const select = utils.getByLabelText('session model') as HTMLSelectElement
    // U1: default = most-recent _te_model.
    expect(select.value).toBe('opus-4')

    // Override to sonnet-4 then send.
    fireEvent.change(select, { target: { value: 'sonnet-4' } })
    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'go' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter', metaKey: true })
    })
    expect(sendSpy).toHaveBeenCalledWith('go', 'sonnet-4')
  })

  it('U3: changing the model dropdown makes NO backend PUT/persist call', async () => {
    const fetchMock = mockFetchOk('new-1')
    const sid = 'src-1'
    state.recentSessions = [providerSession(sid)]
    state.transcripts[sid] = [{ ...userEntry('e1', 'first'), model: 'opus-4' }]
    window.history.replaceState(null, '', `/session/${sid}`)
    const utils = render(<App />)

    const sel = utils.getByLabelText('session model') as HTMLSelectElement
    fireEvent.change(sel, { target: { value: 'sonnet-4' } })

    // No PUT (description/prompt) and no /api/tabs/new call from a model change.
    const putCalls = fetchMock.mock.calls.filter((c) => (c[1] as RequestInit)?.method === 'PUT')
    expect(putCalls.length).toBe(0)
    expect(fetchMock.mock.calls.find((c) => c[0] === '/api/tabs/new')).toBeUndefined()
  })

  it('U6/U7: new-tab (non-branch) first send POSTs /send with the composer model', async () => {
    const fetchMock = mockFetchOk('new-7')
    render(<App />) // no selection → compose mode

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'hello new tab' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    await waitFor(() => {
      expect(fetchMock.mock.calls.some((c) => (c[0] as string).includes('/send'))).toBe(true)
    })
    const sendCall = fetchMock.mock.calls.find((c) => (c[0] as string).includes('/send'))!
    const sendBody = JSON.parse((sendCall[1] as RequestInit).body as string)
    // composerSpec.model is mocked as 'sonnet' (the composer selection, not a global IORef).
    expect(sendBody.model).toBe('sonnet')
    expect(sendBody.message).toBe('hello new tab')
  })

  it('U4/U8: branch first send POSTs /send with branchDraft.prefixModel (distinct from kind.model)', async () => {
    const fetchMock = mockFetchOk('new-99')
    const sid = 'src-1'
    state.recentSessions = [providerSession(sid)]
    // The last prefix entry's _te_model column is "opus-4" — distinct from
    // the composer's model ('sonnet').
    state.transcripts[sid] = [
      { ...userEntry('e1', 'first message'), model: 'sonnet-4' },
      { ...userEntry('e2', 'second message'), model: 'opus-4' },
    ]
    window.history.replaceState(null, '', `/session/${sid}`)
    const utils = render(<App />)

    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[1]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))

    // U8: in branch-draft compose mode the dropdown default = prefixModel.
    const select = utils.getByLabelText('session model') as HTMLSelectElement
    expect(select.value).toBe('opus-4')

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'branch on' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    await waitFor(() => {
      expect(fetchMock.mock.calls.some((c) => (c[0] as string).includes('/send'))).toBe(true)
    })
    const sendCall = fetchMock.mock.calls.find((c) => (c[0] as string).includes('/send'))!
    const sendBody = JSON.parse((sendCall[1] as RequestInit).body as string)
    // U4: /send body model = prefixModel (opus-4), NOT the composer's 'sonnet'.
    expect(sendBody.model).toBe('opus-4')
  })

  it('U4: a branch whose prefix entry has a null _te_model sends NO model field', async () => {
    const fetchMock = mockFetchOk('new-100')
    const sid = 'src-1'
    state.recentSessions = [providerSession(sid)]
    state.transcripts[sid] = [{ ...userEntry('e1', 'first message'), model: null }]
    window.history.replaceState(null, '', `/session/${sid}`)
    const utils = render(<App />)

    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[0]!)
    await waitFor(() => utils.getByPlaceholderText('Type your first message…'))

    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    fireEvent.change(textarea, { target: { value: 'branch on' } })
    await act(async () => {
      fireEvent.keyDown(textarea, { key: 'Enter' })
    })

    await waitFor(() => {
      expect(fetchMock.mock.calls.some((c) => (c[0] as string).includes('/send'))).toBe(true)
    })
    const sendCall = fetchMock.mock.calls.find((c) => (c[0] as string).includes('/send'))!
    const sendBody = JSON.parse((sendCall[1] as RequestInit).body as string)
    expect('model' in sendBody).toBe(false)
  })

  it('D15: selecting another session clears the branch draft', async () => {
    mockFetchOk('new-1')
    state.recentSessions = [providerSession('src-1'), providerSession('other-2')]
    state.transcripts['src-1'] = [userEntry('e1', 'first message'), userEntry('e2', 'second message')]
    state.transcripts['other-2'] = [userEntry('o1', 'other session msg')]
    window.history.replaceState(null, '', '/session/src-1')
    const utils = render(<App />)

    fireEvent.click(utils.getAllByLabelText(BRANCH_LABEL)[0]!)
    await waitFor(() => utils.getByText('first message'))
    expect(utils.getByPlaceholderText('Type your first message…')).toBeTruthy()

    // Select the OTHER session from the sidebar.
    const otherRow = utils.getAllByText(/other-2/).map((el) => el.closest('.session-row')).find(Boolean)
    fireEvent.click(otherRow as HTMLElement)

    await waitFor(() => {
      // Composer is gone; the other session's transcript shows.
      expect(utils.queryByPlaceholderText('Type your first message…')).toBeNull()
    })
    expect(utils.getByText('other session msg')).toBeTruthy()
  })
})
