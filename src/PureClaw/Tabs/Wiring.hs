{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : PureClaw.Tabs.Wiring
-- Description : Live wiring of the tab subsystem (Tabs-as-View 8c.2 flip).
--
-- This module is the 8c.2 /wiring flip/ (GitHub #79; execution-binding spike
-- §3–§6). It binds the additive 8b\/8c.1 pieces — the per-'TabRef' runtime
-- registry ("PureClaw.Tabs.Exec"), the real runtime constructors
-- ("PureClaw.Tabs.Runtimes"), the output-side relay writer
-- ("PureClaw.Tabs.RelayWriter"), and the per-conversation router
-- ("PureClaw.Routing.TabDispatch") — to the live 'AgentEnv', and exposes
-- 'runTabbedLoop', the new production entry point.
--
-- 'runTabbedLoop':
--
--   1. Forks the __relay-writer thread__ draining '_env_tabOutQ' through
--      'RelayWriter.processOutput'.
--   2. Registers the CLI conversation's __output sink__ (its
--      'ConversationKey' -> '_env_channel') in '_env_sinks'.
--   3. Loops reading messages from '_env_channel', extracting each message's
--      'ConversationKey' from its 'MessageSource', and dispatching to
--      'TabDispatch.handleInbound' built from the live 'AgentEnv'.
--
-- The real @_ex_startRuntime@ closure ('mkExecDeps') builds a
-- 'Runtimes.mkProviderRuntime' for a @BoundSession@ (pooled 'SessionHandle',
-- context seeded from the transcript, transcript-recording provider stream,
-- tool exec over the env registry) and a 'Runtimes.mkHarnessRuntime' for a
-- @BoundHarness@ (the 'HarnessHandle' resolved from '_env_harnessRegistry').
--
-- == Additive
--
-- This is the live flip but it is ADDITIVE: the legacy
-- 'PureClaw.Agent.Loop.runAgentLoopWith' path and the legacy 'AgentEnv'
-- fields are untouched here and deleted in 8c.3.
module PureClaw.Tabs.Wiring
  ( -- * Production entry point
    runTabbedLoop
    -- * Exec wiring (exposed for tests \/ reuse)
  , mkExecDeps
  , mkTabDispatchDeps
    -- * Effective tool registry (exposed for tests \/ reuse)
  , effectiveRegistry
  , execOneTool
  ) where

import Control.Concurrent.STM (atomically, readTBQueue, writeTBQueue)
import Control.Exception (try)
import Control.Exception qualified as E
import Control.Monad (forever)
import Data.Aeson (Value)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory)

import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.Agent.Context qualified as Ctx
import PureClaw.Agent.Env
import PureClaw.Agent.Loop qualified as Loop
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types (ModelId (..), ToolCallId)
import PureClaw.Core.Types qualified as Core
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
  ( HarnessHandle (..)
  , HarnessStatus (..)
  , mkNoOpHarnessHandle
  )
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Transcript (TranscriptHandle)
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Providers.Class qualified as P
import PureClaw.Routing.TabDispatch (TabDispatchDeps (..))
import PureClaw.Routing.TabDispatch qualified as Dispatch
import PureClaw.Routing.Types qualified as RT
import PureClaw.Session.Handle qualified as Session
import PureClaw.Session.Types qualified as SessionTypes
import PureClaw.Tabs qualified as Tabs
import PureClaw.Tabs.Exec (ExecDeps (..), Runtime, ensure, release, sendTo)
import PureClaw.Tabs.RelayWriter
  ( RelayWriterDeps (..)
  , lookupSink
  , processOutput
  , registerSink
  )
import PureClaw.Tabs.Runtimes
  ( HarnessRuntimeDeps (..)
  , ProviderRuntimeDeps (..)
  , mkHarnessRuntime
  , mkProviderRuntime
  )
import PureClaw.Tabs.Types
  ( ConversationKey
  , RelayMode (..)
  , Tab (..)
  , TabRef (..)
  , resolveCursorSlot
  )
import PureClaw.Tools.Registry
  ( ToolRegistry
  , executeTool
  , registryDefinitions
  )
import PureClaw.Transcript.Provider (mkTranscriptProvider)

-- ---------------------------------------------------------------------------
-- Session-handle pool (8c.2-local)
-- ---------------------------------------------------------------------------

-- | A tiny @'Core.SessionId' -> 'Session.SessionHandle'@ pool, owned by one
-- 'runTabbedLoop' invocation. The default-session minter ('mkNewDefaultSession')
-- inserts a freshly-opened handle keyed by its id; the provider runtime
-- constructor ('mkExecDeps') reads it back to seed + record against the same
-- on-disk session. This is the 8c.2 stand-in for the full
-- "PureClaw.Tabs.SessionPool" wiring (which lands with detach\/refcount work);
-- here it is a write-on-create, read-on-bind map — adequate for the CLI flip,
-- where every bound session was minted by '_td_newDefaultSession'.
type SessionStore = IORef (Map Core.SessionId Session.SessionHandle)

-- ---------------------------------------------------------------------------
-- Production entry point
-- ---------------------------------------------------------------------------

-- | The Tabs-as-View production loop (replaces 'runAgentLoopWith' at the 8c.2
-- flip). Forks the relay-writer thread, registers the CLI sink, then reads the
-- channel and dispatches each inbound message per conversation.
runTabbedLoop :: AgentEnv -> IO ()
runTabbedLoop env = do
  let logger = _env_logger env
  _lh_logInfo logger "Tabbed agent loop started"
  store <- newIORef Map.empty
  let execDeps   = mkExecDeps env store
      relayDeps  = RelayWriterDeps
        { _rw_sinks   = _env_sinks env
        , _rw_cursors = readIORef (_env_cursors env)
        , _rw_tabs    = Tabs.readTabs (_env_tabRegistry env)
        , _rw_default = defaultRelayMode
        }
  -- (a) Fork the relay-writer thread draining the ref-tagged tab-output queue.
  _ <- _env_fork env $ forever $ do
    (ref, ev) <- atomically (readTBQueue (_env_tabOutQ env))
    processOutput relayDeps (_env_relayWriter env) ref ev
  -- The dispatcher deps are built once; they close over the live env + store.
  let dispatchDeps = mkTabDispatchDeps env execDeps store
  -- Read the first inbound message to learn the CLI conversation key, register
  -- its sink, then loop. (b) + (c).
  loop store dispatchDeps
  where
    channel = _env_channel env
    logger  = _env_logger env

    loop store dispatchDeps = do
      receiveResult <- try @E.IOException (_ch_receive channel)
      case receiveResult of
        Left _    -> _lh_logInfo logger "Session ended"
        Right msg -> do
          let src     = _im_source msg
              convKey = conversationKeyOf src
          -- (b) Register this conversation's output sink (idempotent).
          registerSink (_env_sinks env) convKey channel
          -- Capture the session origin (set-once) on the FOREGROUND session,
          -- mirroring the legacy loop (the no-active-tab case relies on this —
          -- Tabs.WiringSpec).
          fgSh <- readIORef (_env_session env)
          Session.setSourceIfAbsent fgSh src
          -- Also capture it (set-once) on the conversation's ACTIVE BOUND
          -- session, so provenance lands on the session the turn actually runs
          -- in (pureclaw-opr; #79). No active tab / non-session ref → no-op.
          captureBoundSource env store convKey src
          -- (c) Dispatch per conversation.
          Dispatch.handleInbound dispatchDeps convKey (_im_content msg)
          loop store dispatchDeps

-- | The 'ConversationKey' for a message source: its channel + conversation id
-- (invariant I3 — the dispatcher keys cursors\/relay by this pair).
conversationKeyOf :: Core.MessageSource -> ConversationKey
conversationKeyOf src = (Core._ms_channel src, Core._ms_conversation src)

-- | Capture the inbound message source (set-once) onto the conversation's
-- ACTIVE BOUND session — the session the turn actually runs in. Resolves the
-- active tab exactly as 'TabDispatch.doDefault' does (cursor -> ref -> tab) and,
-- when the ref is a @BoundSession@, resolves its 'Session.SessionHandle' from
-- the loop's @store@ and applies 'Session.setSourceIfAbsent'. No active tab (no
-- cursor / dangling cursor) or a non-session ref (@BoundHarness@) is a safe
-- no-op. This restores the provenance the 8c cutover dropped (pureclaw-opr; #79)
-- without disturbing the foreground @_env_session@ capture the no-tab case needs.
captureBoundSource
  :: AgentEnv -> SessionStore -> ConversationKey -> Core.MessageSource -> IO ()
captureBoundSource env store convKey src = do
  cs <- readIORef (_env_cursors env)
  tl <- Tabs.readTabs (_env_tabRegistry env)
  case resolveCursorSlot convKey cs tl of
    Nothing   -> pure ()
    Just slot -> do
      mTab <- Tabs.registryLookupSlot (_env_tabRegistry env) slot
      case _tab_ref <$> mTab of
        Just (BoundSession sid) -> do
          sh <- resolveSession env store sid
          Session.setSourceIfAbsent sh src
        _ -> pure ()

-- | The global default 'RelayMode' for conversations with no override.
-- 'FocusedOnly' matches the design default (only the focused tab is relayed).
defaultRelayMode :: RelayMode
defaultRelayMode = FocusedOnly

-- ---------------------------------------------------------------------------
-- Exec wiring — the real _ex_startRuntime closure
-- ---------------------------------------------------------------------------

-- | Build the production 'ExecDeps': the '_ex_startRuntime' closure that
-- constructs a provider or harness runtime for a 'TabRef' against the live
-- 'AgentEnv'.
--
--   * @BoundSession sid@ — 'mkProviderRuntime' over the session's pooled
--     'SessionHandle' (resolved from @store@), seeding 'Ctx.Context' from the
--     transcript via 'Session.loadRecentMessages', streaming through a
--     transcript-recording provider, executing tools against the env registry,
--     and emitting @('TabRef','ChannelEvent')@ onto '_env_tabOutQ'.
--   * @BoundHarness hid@ — 'mkHarnessRuntime' over the 'HarnessHandle' resolved
--     from '_env_harnessRegistry'.
mkExecDeps :: AgentEnv -> SessionStore -> ExecDeps
mkExecDeps env store = ExecDeps { _ex_startRuntime = startRuntime }
  where
    startRuntime :: TabRef -> IO Runtime
    startRuntime = \case
      BoundSession sid -> startProvider env store sid
      BoundHarness hid -> startHarness env hid

-- | Enqueue a ref-tagged output event onto the tab-output queue (the relay
-- writer's source).
enqueueTabOut :: AgentEnv -> TabRef -> RT.ChannelEvent -> IO ()
enqueueTabOut env ref ev =
  atomically (writeTBQueue (_env_tabOutQ env) (ref, ev))

-- | Build + start a provider-session runtime for a 'Core.SessionId'.
startProvider :: AgentEnv -> SessionStore -> Core.SessionId -> IO Runtime
startProvider env store sid = do
  sh <- resolveSession env store sid
  let th = Session._sh_transcript sh
  mProvider <- readIORef (_env_provider env)
  mModel    <- readIORef (_env_model env)
  let model     = fromMaybe (ModelId "") mModel
      modelName = unModelId model
  -- Wrap the provider with the per-session transcript recorder (records
  -- request/response entries to transcript.jsonl + broker), exactly as the
  -- legacy loop did. A 'Nothing' provider yields a stream that records nothing
  -- and produces no StreamDone (the turn returns the seeded context).
  --
  -- The transcript's Request @metadata.source@ is the BOUND session's current
  -- @_sm_source@, read per turn: 'runTabbedLoop' captures the inbound source
  -- set-once onto this session before the worker runs, so this restores the
  -- legacy loop's @(Just (_im_source msg))@ semantics (pureclaw-opr; #79).
  let streamFn req cb = case mProvider of
        Nothing -> pure ()
        Just provider -> do
          meta <- readIORef (Session._sh_meta sh)
          let provider' =
                mkTranscriptProvider th modelName (SessionTypes._sm_source meta) provider
          P.completeStream provider' req cb
  let deps = ProviderRuntimeDeps
        { _prd_ref          = BoundSession sid
        , _prd_emit         = enqueueTabOut env
        , _prd_stream       = streamFn
        , _prd_execTool     = execOneTool env
        , _prd_record       = \_ -> pure ()
            -- Transcript append is performed by the transcript-recording
            -- provider wrapper above (request/response entries); the
            -- message-level append is a no-op, matching the legacy Tab.Ai path.
        , _prd_seedCtx      = seedContextFrom env th
        , _prd_model        = model
        , _prd_systemPrompt = _env_systemPrompt env
        , _prd_tools        = registryDefinitions (_env_registry env)
        , _prd_maxTokens    = Just 4096
        , _prd_fork         = _env_fork env
        , _prd_inputBound   = RT._rc_inputQueueBound (_env_routingConfig env)
        }
  mkProviderRuntime deps

-- | Build + start a harness runtime for a 'Registry.HarnessId'. The
-- 'HarnessHandle' is resolved from '_env_harnessRegistry'; when the entry has
-- no live handle yet (boot-discovered, not attached), a no-op handle is used so
-- the runtime starts cleanly and simply produces no output until reconcile
-- attaches one.
startHarness :: AgentEnv -> Registry.HarnessId -> IO Runtime
startHarness env hid = do
  mEntry <- Registry.lookupById (_env_harnessRegistry env) hid
  let mHandle = mEntry >>= Registry._he_handle
  case mHandle of
    Just h  -> startHarnessWith env hid h
    Nothing ->
      -- TODO(8c.3): resolve a freshly-attached handle once detach/re-attach
      -- lifecycle lands; for now an unattached harness ref produces no output.
      startHarnessWith env hid noOutputHarness

-- | The harness-runtime build over a resolved 'HarnessHandle'.
startHarnessWith :: AgentEnv -> Registry.HarnessId -> HarnessHandle -> IO Runtime
startHarnessWith env hid h =
  mkHarnessRuntime HarnessRuntimeDeps
    { _hrd_ref        = BoundHarness hid
    , _hrd_emit       = enqueueTabOut env
    , _hrd_handle     = h
    , _hrd_fork       = _env_fork env
    , _hrd_pollMicros = 100000  -- 100ms drainer poll, matching the legacy loop
    , _hrd_sendBound  = RT._rc_inputQueueBound (_env_routingConfig env)
    }

-- | A 'HarnessHandle' for an unattached harness ref (boot-discovered, no live
-- handle yet — TODO(8c.3)): it discards input and reports 'HarnessExited' so
-- the runtime's drainer stops immediately rather than spinning on an empty
-- receive. Re-attaching a real handle is 8c.3 detach/re-attach work.
noOutputHarness :: HarnessHandle
noOutputHarness = mkNoOpHarnessHandle { _hh_status = pure (HarnessExited ExitSuccess) }

-- ---------------------------------------------------------------------------
-- Provider-runtime helpers
-- ---------------------------------------------------------------------------

-- | Seed a fresh 'Ctx.Context' for a provider runtime from its session's
-- transcript: reload a bounded window of recent messages
-- ('Session.loadRecentMessages') and replace them into an empty context
-- carrying the env system prompt (mirrors the CLI resume seam, spike §2).
seedContextFrom :: AgentEnv -> TranscriptHandle -> IO Ctx.Context
seedContextFrom env th = do
  recent <- Session.loadRecentMessages th 50 100000
  pure (Ctx.replaceMessages recent (Ctx.emptyContext (_env_systemPrompt env)))

-- | The effective tool registry for a per-tab runtime: the env's built-in
-- registry merged with any connected MCP server tools (read per call, so tools
-- connected after a tab is created are still seen). Mirrors the still-live
-- @Loop.backgroundRegistry@ \/ legacy @effectiveRegistry@ (pureclaw-2u4; #79).
effectiveRegistry :: AgentEnv -> IO ToolRegistry
effectiveRegistry env = do
  -- TEMP (RED): ignores _env_mcpServers — proves MCP tools are unreachable on
  -- the tabbed path. GREEN merges mcpRegistry below.
  _servers <- readIORef (_env_mcpServers env)
  pure (_env_registry env)

-- | Run ONE tool call against the effective registry, returning a tool-result
-- 'P.Message'. Mirrors @Loop.executeCall@ + @toolResultMessage@ for a single
-- call: an unknown tool yields a one-line error result rather than throwing.
execOneTool :: AgentEnv -> ToolCallId -> Text -> Value -> IO P.Message
execOneTool env callId name input = do
  reg    <- effectiveRegistry env
  result <- executeTool reg name input
  let (parts, isErr) = case result of
        Nothing       -> ([P.TRPText ("Unknown tool: " <> name)], True)
        Just (ps, er) -> (ps, er)
  pure (P.toolResultMessage [(callId, parts, isErr)])

-- | Resolve the 'Session.SessionHandle' for a 'Core.SessionId': prefer the
-- @store@ entry (minted by '_td_newDefaultSession'); fall back to the live
-- '_env_session' if its id matches; otherwise open a fresh handle from disk and
-- cache it. The store guarantees the common case (every bound session was
-- minted by the dispatcher) never touches disk twice.
resolveSession :: AgentEnv -> SessionStore -> Core.SessionId -> IO Session.SessionHandle
resolveSession env store sid = do
  m <- readIORef store
  case Map.lookup sid m of
    Just sh -> pure sh
    Nothing -> do
      cur <- readIORef (_env_session env)
      curMeta <- readIORef (Session._sh_meta cur)
      if SessionTypes._sm_id curMeta == sid
        then do
          cacheSession store sid cur
          pure cur
        else do
          -- TODO(8c.3): a wizard-reopened session whose handle was not minted
          -- here. Open it from disk via the same sessions dir and cache it.
          sh <- openSessionFromDisk env sid
          cacheSession store sid sh
          pure sh

-- | Cache a resolved handle in the store under its id.
cacheSession :: SessionStore -> Core.SessionId -> Session.SessionHandle -> IO ()
cacheSession store sid sh =
  atomicModifyIORef' store (\m -> (Map.insert sid sh m, ()))

-- | Open a 'Session.SessionHandle' for an existing on-disk session id, rooted
-- under the foreground session's sessions directory. Used only on the
-- wizard-reopen fallback path (TODO(8c.3) makes this a real
-- 'Session.resumeSession' resolve with metadata validation).
openSessionFromDisk :: AgentEnv -> Core.SessionId -> IO Session.SessionHandle
openSessionFromDisk env sid = do
  dir <- sessionsDirOf env
  now <- getCurrentTime
  let modelTxt = Core.unSessionId sid
      meta = baseProviderMeta env now sid (ModelId modelTxt) "session"
  Session.mkSessionHandle (_env_broker env) (_env_logger env) dir meta

-- ---------------------------------------------------------------------------
-- TabDispatchDeps — built from the live AgentEnv
-- ---------------------------------------------------------------------------

-- | Build the per-conversation 'Dispatch.TabDispatchDeps' from the live
-- 'AgentEnv': the runtime-binding seams are the 'Exec' ops applied to
-- '_env_exec'; the emit seam writes a banner to the conversation's sink;
-- '_td_newDefaultSession' mints a fresh default-provider session and caches its
-- handle in @store@; the wizard candidate lists come from the harness registry
-- and the sessions directory; '_td_fallthrough' handles non-tab slash commands.
mkTabDispatchDeps :: AgentEnv -> ExecDeps -> SessionStore -> Dispatch.TabDispatchDeps
mkTabDispatchDeps env execDeps store = TabDispatchDeps
  { _td_tabs              = _env_tabRegistry env
  , _td_cursors           = _env_cursors env
  , _td_wizard            = _env_wizard env
  , _td_ensure            = ensure execDeps (_env_exec env)
  , _td_release           = release (_env_exec env)
  , _td_sendTo            = sendTo (_env_exec env)
  , _td_emit              = emitToConversation env
  , _td_newDefaultSession = mkNewDefaultSession env store
  , _td_recentHarnesses   = recentHarnesses env
  , _td_recentSessions    = recentSessions env
  , _td_liveHarness       = liveHarness env
  , _td_relayDefault      = defaultRelayMode
  , _td_routingConfig     = _env_routingConfig env
  , _td_fallthrough       = fallthrough env
  }

-- | Emit a dispatcher banner\/reply to a conversation's registered sink. The
-- CLI conversation's sink is '_env_channel'; a missing sink is a safe drop.
emitToConversation :: AgentEnv -> ConversationKey -> Text -> IO ()
emitToConversation env convKey txt = do
  mSink <- lookupSinkFor env convKey
  case mSink of
    Just ch -> _ch_send ch (OutgoingMessage txt)
    Nothing -> pure ()

-- | Look up a conversation's sink via the relay-writer registry.
lookupSinkFor :: AgentEnv -> ConversationKey -> IO (Maybe ChannelHandle)
lookupSinkFor env = lookupSink (_env_sinks env)

-- | Mint a fresh default-provider session, cache its handle in @store@, and
-- return its 'BoundSession' ref. @'Left' msg@ when no default provider\/model
-- is configured.
mkNewDefaultSession :: AgentEnv -> SessionStore -> IO (Either Text TabRef)
mkNewDefaultSession env store = do
  mModel <- readIORef (_env_model env)
  case mModel of
    Nothing    -> pure (Left "no default provider configured")
    Just model -> do
      now <- getCurrentTime
      dir <- sessionsDirOf env
      let sid  = SessionTypes.newSessionId Nothing now
          meta = baseProviderMeta env now sid model "session"
      sh <- Session.mkSessionHandle (_env_broker env) (_env_logger env) dir meta
      cacheSession store sid sh
      pure (Right (BoundSession sid))

-- | A 'SessionTypes.SessionMeta' for a fresh provider-backed session.
baseProviderMeta
  :: AgentEnv
  -> UTCTime
  -> Core.SessionId
  -> ModelId
  -> Text
  -> SessionTypes.SessionMeta
baseProviderMeta env now sid model _label =
  SessionTypes.SessionMeta
    { SessionTypes._sm_id                = sid
    , SessionTypes._sm_agent             = mAgent
    , SessionTypes._sm_kind              = SessionTypes.SkProvider
        (SessionTypes.ProviderSpec
          (SessionTypes.inferProviderId (unModelId model)) model mAgent)
    , SessionTypes._sm_model             = unModelId model
    , SessionTypes._sm_channel           = "cli"
    , SessionTypes._sm_createdAt         = now
    , SessionTypes._sm_lastActive        = now
    , SessionTypes._sm_bootstrapConsumed = False
    , SessionTypes._sm_archived          = False
    , SessionTypes._sm_description       = Nothing
    , SessionTypes._sm_autoSummary       = Nothing
    , SessionTypes._sm_source            = Nothing
    }
  where
    mAgent = AgentDef._ad_name <$> _env_agentDef env

-- | The sessions directory: the parent of the foreground session's directory
-- (the directory the frontend enumerates), falling back to
-- 'Slash.getSessionsDir' when the foreground session has no on-disk dir.
sessionsDirOf :: AgentEnv -> IO FilePath
sessionsDirOf env = do
  sh <- readIORef (_env_session env)
  let dir = Session._sh_dir sh
  if null dir then Slash.getSessionsDir else pure (takeDirectory dir)

-- | Running harnesses (id + label) for the @\/tab@ wizard menu.
recentHarnesses :: AgentEnv -> IO [(Registry.HarnessId, Text)]
recentHarnesses env = do
  entries <- Registry.snapshot (_env_harnessRegistry env)
  pure [ (Registry._he_id e, Registry._he_label e)
       | e <- entries
       , isLive (Registry._he_liveness e)
       ]

-- | Recent sessions (id + label) for the @\/tab@ wizard menu.
recentSessions :: AgentEnv -> IO [(Core.SessionId, Text)]
recentSessions env = do
  dir   <- sessionsDirOf env
  metas <- Session.listSessions dir Nothing 50
  pure [ (SessionTypes._sm_id m, sessionLabel m) | m <- metas ]

-- | A terse session label for the wizard menu.
sessionLabel :: SessionTypes.SessionMeta -> Text
sessionLabel m =
  fromMaybe (Core.unSessionId (SessionTypes._sm_id m))
            (SessionTypes._sm_description m)

-- | Liveness probe used by the wizard when a harness pick is resolved.
liveHarness :: AgentEnv -> Registry.HarnessId -> IO Bool
liveHarness env hid = do
  mEntry <- Registry.lookupById (_env_harnessRegistry env) hid
  pure (maybe False (isLive . Registry._he_liveness) mEntry)

-- | Whether a registry 'Registry.Liveness' counts as a live harness for the
-- wizard menu (anything that is not 'Registry.Exited').
isLive :: Registry.Liveness -> Bool
isLive = \case
  Registry.LivenessExited -> False
  _                       -> True

-- | Handle a non-tab slash command (the routing grammar's
-- 'RT.ParsedSlashCmd'): the legacy slash-command surface (@\/help@, @\/status@,
-- @\/provider@, @\/vault@, …) still runs through 'Slash.executeSlashCommand',
-- which emits to '_env_channel' — the CLI conversation's registered sink — so
-- all non-tab commands behave exactly as before the flip.
--
-- @\/bg@ is special-cased: 'Slash.executeSlashCommand' only stubs it (it has no
-- dispatcher), so the tabbed loop forks a self-contained background turn
-- ('runBg') instead, matching the legacy loop's @\/bg@ handling.
--
-- The per-call 'Ctx.Context' is empty: these commands (status\/help\/config\/…)
-- do not consult conversation history. Per-conversation provider turns flow
-- through the runtime worker's own 'Ctx.Context', not this path.
fallthrough :: AgentEnv -> ConversationKey -> Slash.SlashCommand -> IO ()
fallthrough env _convKey cmd = case cmd of
  Slash.CmdBg prompt -> do
    _ch_send (_env_channel env)
      (OutgoingMessage
        "\x1F504 /bg: running in the background \x2014 the result will appear here when ready.")
    _ <- _env_fork env (runBg env prompt)
    pure ()
  _ -> do
    _ <- Slash.executeSlashCommand env cmd (Ctx.emptyContext (_env_systemPrompt env))
    pure ()

-- | Fork a @\/bg@ background turn. Re-exported from the loop so the tabbed
-- fallthrough preserves @\/bg@ semantics without importing the whole loop's
-- internals. The result is pushed directly to the conversation channel by
-- 'runBackgroundTurn'.
runBg :: AgentEnv -> Text -> IO ()
runBg = Loop.runBackgroundTurn
