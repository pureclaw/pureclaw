module PureClaw.Agent.Loop
  ( -- * Agent loop
    runAgentLoop
  , runAgentLoopWith
    -- * Background tasks (/bg, issue #52)
  , runBackgroundTurn
    -- * Re-exports from Handles.Harness (for backward compatibility)
  , sanitizeHarnessOutput
  ) where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.Foldable (for_)
import Data.Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE

import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.Agent.Context
import PureClaw.Core.Types
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Errors
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript qualified as Transcript
import PureClaw.MCP (mcpRegistry)
import PureClaw.Providers.Class
import PureClaw.Routing.LegacyDispatch (dispatchLegacyTabCmd)
import PureClaw.Session.Handle qualified as Session
import PureClaw.Session.Types qualified as SessionTypes
import PureClaw.Tools.Delegate (runSubAgent)
import PureClaw.Tools.Registry
import PureClaw.Transcript.Provider

-- | Run the main agent loop. Reads messages from the channel, sends
-- them to the provider (with tool definitions), handles tool call/result
-- cycles, and writes responses back.
--
-- Slash commands (messages starting with '/') are intercepted and
-- handled before being sent to the provider.
--
-- If no provider is configured ('Nothing' in the IORef), chat messages
-- produce a helpful error directing the user to configure credentials.
-- Slash commands always work regardless of provider state.
--
-- Exits cleanly on 'IOException' from the channel (e.g. EOF / Ctrl-D).
-- Provider errors are logged and a 'PublicError' is sent to the channel.
--
-- == WU10 (Tabbed Chat #51) refactor status
--
-- The original WU10 plan called for 'runAgentLoop' to become a thin
-- wrapper around 'PureClaw.Routing.Dispatcher.runDispatcher'. WU10
-- escalated this part of the refactor: the WU6 AI tab loop in
-- 'PureClaw.Tab.Ai' is not yet a drop-in replacement for the
-- single-tab semantics this loop owns (model prefix emission on
-- channel output, tool-call execution cycle, transcript provider
-- wrapping via 'PureClaw.Transcript.Provider.mkTranscriptProvider',
-- '_env_onFirstStreamDone' callback, harness routing via
-- 'PureClaw.Handles.Harness.HarnessHandle'). Migrating all of those
-- features into 'Tab.Ai' is itself a multi-WU refactor and was
-- deferred to WU11\/WU12.
--
-- For now 'runAgentLoop' is the production entry-point for the
-- single-tab CLI flow; tabbed-chat is exercised via
-- 'PureClaw.Routing.Dispatcher.runDispatcher' (which the K-series
-- tests in @test\/Coexistence\/SlashCmdSpec.hs@ drive directly). The
-- two entry points coexist until the Tab.Ai feature gap closes.
runAgentLoop :: AgentEnv -> IO ()
runAgentLoop env = runAgentLoopWith env []

-- | Like 'runAgentLoop' but seeds the initial 'Context' with the given
-- messages (in chronological, oldest-first order). Used by the resume
-- path to replay recent transcript entries so the agent has memory of
-- prior turns.
runAgentLoopWith :: AgentEnv -> [Message] -> IO ()
runAgentLoopWith env initialMessages = do
  _lh_logInfo logger "Agent loop started"
  let ctx0 = replaceMessages initialMessages (emptyContext (_env_systemPrompt env))
  go ctx0
  where
    channel  = _env_channel env
    logger   = _env_logger env
    baseRegistry = _env_registry env

    -- | Build the effective registry by merging built-in tools with
    -- any connected MCP server tools.
    effectiveRegistry :: IO ToolRegistry
    effectiveRegistry = do
      servers <- readIORef (_env_mcpServers env)
      if Map.null servers
        then pure baseRegistry
        else pure $ mergeRegistries baseRegistry (mcpRegistry (Map.elems servers))

    go ctx = do
      receiveResult <- try @IOException (_ch_receive channel)
      case receiveResult of
        Left _ -> _lh_logInfo logger "Session ended"
        Right msg -> do
          -- Capture the session origin (set-once) BEFORE any slash/harness/
          -- /bg/provider branching, covering the empty-message branch too:
          -- origin is about the SENDER, not the content. This is the
          -- single-tab loop's sole inbound entry; the tabbed dispatcher
          -- runtime is a separate path (out of scope, see design WU3).
          --
          -- SECURITY: _sm_source is attacker-asserted provenance and MUST
          -- NOT feed any access-control decision.
          sh <- readIORef (_env_session env)
          Session.setSourceIfAbsent sh (_im_source msg)
          dispatchMsg
          where
            stripped = T.strip (_im_content msg)
            dispatchMsg
              | T.null stripped = go ctx
              -- INVARIANT: any message beginning with '/' is handled locally
              -- and NEVER forwarded to the provider. Unknown slash commands
              -- get an error response rather than silently routing to the LLM.
              | "/" `T.isPrefixOf` stripped =
                  case parseSlashCommand stripped of
                    Just (CmdTab tabCmd) -> do
                      -- Tab commands need callbacks (SpawnIO, PromptRenderer,
                      -- BannerEmit, etc.) that 'executeSlashCommand' can't wire
                      -- without a dependency cycle. Dispatch via the legacy
                      -- bridge instead. The bridge invokes the canonical
                      -- 'Routing.AutoSpawn' handlers so /tab* commands behave
                      -- the same way they would under the new dispatcher.
                      _lh_logInfo logger $ "Slash command (tab): " <> stripped
                      dispatchLegacyTabCmd env tabCmd
                      go ctx
                    Just (CmdBg prompt) -> do
                      -- /bg runs the prompt in a fresh background session
                      -- (issue #52). The single-tab loop has no tabbed-chat
                      -- dispatcher, so we fork a self-contained background
                      -- turn that emits its result directly to the channel
                      -- (the ChannelOut writer is not running in this path).
                      -- The foreground loop continues uninterrupted.
                      _lh_logInfo logger $ "Slash command (bg): " <> stripped
                      _ch_send channel (OutgoingMessage
                        "\x1F504 /bg: running in the background \x2014 the result will appear here when ready.")
                      _ <- _env_fork env (runBackgroundTurn env prompt)
                      go ctx
                    Just cmd -> do
                      _lh_logInfo logger $ "Slash command: " <> stripped
                      ctx' <- executeSlashCommand env cmd ctx
                      go ctx'
                    Nothing -> do
                      _lh_logWarn logger $ "Unrecognized slash command: " <> stripped
                      _ch_send channel
                        (OutgoingMessage ("Unknown command: " <> stripped
                          <> "\nType /status for session info, /help for available commands."))
                      go ctx
              | otherwise = do
                  target <- readIORef (_env_target env)
                  case target of
                    TargetHarness name -> do
                      harnesses <- readIORef (_env_harnesses env)
                      case Map.lookup name harnesses of
                        Nothing -> do
                          _ch_send channel (OutgoingMessage
                            ("Harness \"" <> name <> "\" is not running. Use /harness start "
                              <> name <> " or /target to switch targets."))
                          go ctx
                        Just hh -> do
                          _lh_logInfo logger $ "Routing to harness: " <> name
                          _hh_send hh (TE.encodeUtf8 stripped)
                          output <- _hh_receive hh
                          let response = sanitizeHarnessOutput (TE.decodeUtf8 output)
                          unless (T.null (T.strip response)) $
                            _ch_send channel (OutgoingMessage (prefixHarnessOutput name response))
                          go ctx
                    TargetProvider -> do
                      mProvider <- readIORef (_env_provider env)
                      case mProvider of
                        Nothing -> do
                          _ch_send channel (OutgoingMessage noProviderMessage)
                          go ctx
                        Just provider -> do
                          mModel <- readIORef (_env_model env)
                          case mModel of
                            Nothing -> do
                              _ch_send channel (OutgoingMessage noModelMessage)
                              go ctx
                            Just model -> do
                              let userMsg = textMessage User stripped
                                  ctx' = addMessage userMsg ctx
                              _lh_logDebug logger $
                                "Sending " <> T.pack (show (length (contextMessages ctx'))) <> " messages"
                              -- Wrap provider with transcript logging (session owns the transcript)
                              th <- envTranscript env
                              let provider' = mkTranscriptProvider th (unModelId model) (Just (_im_source msg)) provider
                              handleCompletion provider' ctx'

    handleCompletion provider ctx = do
      mModel <- readIORef (_env_model env)
      registry <- effectiveRegistry
      let tools = registryDefinitions registry
          model = fromMaybe (ModelId "") mModel
          modelName = unModelId model
          req = CompletionRequest
            { _cr_model        = model
            , _cr_messages     = contextMessages ctx
            , _cr_systemPrompt = contextSystemPrompt ctx
            , _cr_maxTokens    = Just 4096
            , _cr_tools        = tools
            , _cr_toolChoice   = Nothing
            }
      responseRef <- newIORef (Nothing :: Maybe CompletionResponse)
      streamedRef <- newIORef False
      prefixSentRef <- newIORef False
      providerResult <- try @SomeException $
        completeStream provider req $ \case
          StreamText t -> do
            -- Emit origin prefix before the first streamed chunk
            prefixSent <- readIORef prefixSentRef
            unless prefixSent $ do
              _ch_sendChunk channel (ChunkText (modelName <> "> "))
              writeIORef prefixSentRef True
            _ch_sendChunk channel (ChunkText t)
            writeIORef streamedRef True
          StreamDone resp -> do
            writeIORef responseRef (Just resp)
            -- Fire and clear the one-shot "first StreamDone" callback
            -- atomically so concurrent StreamDone deliveries cannot
            -- race and invoke it twice. In production this is used to
            -- mark the active session's bootstrap as consumed.
            mAction <- atomicModifyIORef' (_env_onFirstStreamDone env)
                         (Nothing,)
            for_ mAction id
          StreamWarning w -> _lh_logWarn logger w
          _ -> pure ()
      case providerResult of
        Left e -> do
          _lh_logError logger $ "Provider error: " <> T.pack (show e)
          _ch_sendError channel (TemporaryError "Something went wrong. Please try again.")
          go ctx
        Right () -> do
          wasStreaming <- readIORef streamedRef
          when wasStreaming $ _ch_sendChunk channel ChunkDone
          mResp <- readIORef responseRef
          case mResp of
            Nothing -> go ctx  -- shouldn't happen
            Just response -> do
              let calls = toolUseCalls response
                  text = responseText response
                  ctx' = recordUsage (_crsp_usage response)
                       $ addMessage (Message Assistant (_crsp_content response)) ctx
              -- Send the full text. For streaming channels, the text was already
              -- displayed chunk-by-chunk so we skip the full send to avoid duplicates.
              unless (wasStreaming && _ch_streaming channel || T.null (T.strip text)) $
                _ch_send channel (OutgoingMessage (prefixHarnessOutput modelName text))
              -- If there are tool calls, execute them and continue
              if null calls
                then go ctx'
                else do
                  results <- mapM executeCall calls
                  let resultMsg = toolResultMessage results
                      ctx'' = addMessage resultMsg ctx'
                  _lh_logDebug logger $
                    "Executed " <> T.pack (show (length results)) <> " tool calls, continuing"
                  handleCompletion provider ctx''

    executeCall (callId, name, input) = do
      _lh_logInfo logger $ "Tool call: " <> name
      registry <- effectiveRegistry
      result <- executeTool registry name input
      case result of
        Nothing -> do
          _lh_logWarn logger $ "Unknown tool: " <> name
          pure (callId, [TRPText ("Unknown tool: " <> name)], True)
        Just (parts, isErr) -> do
          when isErr $ _lh_logWarn logger $ "Tool error in " <> name <> ": " <> partsToText parts
          pure (callId, parts, isErr)

    partsToText :: [ToolResultPart] -> Text
    partsToText parts = T.intercalate "\n" [t | TRPText t <- parts]

-- | Maximum turns for a @\/bg@ background task (provider + tool-call cycles).
backgroundMaxTurns :: Int
backgroundMaxTurns = 20

-- | Run a @\/bg@ prompt in a fresh background session and push the result
-- directly to the channel (issue #52).
--
-- The background turn runs in its OWN session — a brand-new
-- 'PureClaw.Session.Handle.SessionHandle' created under the same sessions
-- directory as the foreground session and wired to the same
-- 'PureClaw.Frontend.StreamBroker.StreamBroker'. The provider is wrapped
-- with 'mkTranscriptProvider' so every request/response is recorded to the
-- session's @transcript.jsonl@ (and broadcast to the broker). This is what
-- makes the background conversation appear in the frontend UI like any
-- other conversation: the frontend enumerates session directories on disk
-- and subscribes to broker events. The fresh session also means the
-- background turn does NOT leak into the foreground conversation history.
--
-- It uses the process default provider/model and the effective tool
-- registry (built-ins + connected MCP servers), runs to completion via
-- 'runSubAgent' (non-streaming, so it does not interleave with the
-- foreground), and emits a single @[bg done] …@ message via '_ch_send'.
-- This intentionally does NOT go through '_env_channelOutQ' — the
-- single-tab CLI loop does not run the 'PureClaw.Routing.ChannelOut'
-- writer, so a queued event would never be delivered.
--
-- Provider/model-absent and provider-failure cases each emit a short,
-- redacted @[bg] …@ message rather than throwing (the caller forks this
-- with '_env_fork' and does not observe its result).
runBackgroundTurn :: AgentEnv -> Text -> IO ()
runBackgroundTurn env prompt = do
  let channel = _env_channel env
  mProvider <- readIORef (_env_provider env)
  mModel    <- readIORef (_env_model env)
  case (mProvider, mModel) of
    (Nothing, _) ->
      _ch_send channel (OutgoingMessage "[bg] Cannot run: no provider configured.")
    (_, Nothing) ->
      _ch_send channel (OutgoingMessage "[bg] Cannot run: no model configured.")
    (Just provider, Just model) -> do
      outcome <- try @SomeException (runBackgroundSession env provider model prompt)
      case outcome of
        Left e -> do
          _lh_logError (_env_logger env) $
            "Background task error: " <> T.pack (show e)
          _ch_send channel (OutgoingMessage
            "[bg] Something went wrong running the background task.")
        Right text ->
          let body = if T.null (T.strip text) then "(no response)" else text
          in _ch_send channel (OutgoingMessage ("[bg done] " <> body))

-- | Create the fresh background session, run the prompt against a
-- transcript-recording provider, persist + close the session, and return
-- the final assistant text. Any exception propagates to 'runBackgroundTurn'
-- (which reports a redacted failure); the session is saved + closed
-- regardless via 'finally'.
runBackgroundSession :: AgentEnv -> SomeProvider -> ModelId -> Text -> IO Text
runBackgroundSession env provider model prompt = do
  registry  <- backgroundRegistry env
  bgSession <- mkBackgroundSession env model prompt
  let transcript = Session._sh_transcript bgSession
      -- Recording wrapper: each provider call writes a request/response
      -- pair to the session transcript (and fans out to the broker).
      provider'  = mkTranscriptProvider transcript (unModelId model) Nothing provider
  runSubAgent provider' model registry (_env_systemPrompt env)
              prompt backgroundMaxTurns
    `finally` do
      ignoreExc (Session._sh_save bgSession)
      ignoreExc (Transcript._th_close transcript)

-- | Build a fresh on-disk session for a @\/bg@ turn, rooted under the same
-- sessions directory as the foreground session (so the frontend — which
-- scans that directory — discovers it) and wired to '_env_broker' (so its
-- transcript writes broadcast live).
mkBackgroundSession :: AgentEnv -> ModelId -> Text -> IO Session.SessionHandle
mkBackgroundSession env model prompt = do
  now         <- getCurrentTime
  sessionsDir <- backgroundSessionsDir env
  createDirectoryIfMissing True sessionsDir
  let modelTxt = unModelId model
      mAgent   = AgentDef._ad_name <$> _env_agentDef env
      meta = SessionTypes.SessionMeta
        { SessionTypes._sm_id    = SessionTypes.newSessionId Nothing now
        , SessionTypes._sm_agent = mAgent
        , SessionTypes._sm_kind  = SessionTypes.SkProvider
            (SessionTypes.ProviderSpec
              (SessionTypes.inferProviderId modelTxt) model mAgent)
        , SessionTypes._sm_model   = modelTxt
        , SessionTypes._sm_channel = "bg"
        , SessionTypes._sm_createdAt  = now
        , SessionTypes._sm_lastActive = now
        , SessionTypes._sm_bootstrapConsumed = False
        , SessionTypes._sm_archived = False
        , SessionTypes._sm_description = Just (backgroundDescription prompt)
        , SessionTypes._sm_autoSummary = Nothing
        , SessionTypes._sm_source = Nothing
        }
  Session.mkSessionHandle (_env_broker env) (_env_logger env) sessionsDir meta

-- | The sessions directory a @\/bg@ session should be created under: the
-- parent of the foreground session's directory (which is exactly the
-- directory the frontend enumerates). Falls back to 'getSessionsDir' when
-- the foreground session has no on-disk directory (e.g. a no-op handle).
backgroundSessionsDir :: AgentEnv -> IO FilePath
backgroundSessionsDir env = do
  sh <- readIORef (_env_session env)
  let dir = Session._sh_dir sh
  if null dir then getSessionsDir else pure (takeDirectory dir)

-- | A short sidebar label for a @\/bg@ session.
backgroundDescription :: Text -> Text
backgroundDescription prompt = "/bg: " <> T.take 80 (T.strip prompt)

-- | Run an IO action and swallow its exception. Used to make the
-- background session's save/close best-effort so a flush failure does not
-- mask the turn's own result. Although this catches 'SomeException', it is
-- only ever invoked inside 'finally's finalizer (which runs with async
-- exceptions masked), so in practice it swallows synchronous IO failures
-- from save/close — not an asynchronous 'AsyncCancelled'.
ignoreExc :: IO () -> IO ()
ignoreExc m = m `catch` \(_ :: SomeException) -> pure ()

-- | The effective tool registry for a background turn: built-in tools
-- merged with any connected MCP server tools. Mirrors the @effectiveRegistry@
-- helper inside 'runAgentLoopWith'.
backgroundRegistry :: AgentEnv -> IO ToolRegistry
backgroundRegistry env = do
  servers <- readIORef (_env_mcpServers env)
  let base = _env_registry env
  pure $ if Map.null servers
           then base
           else mergeRegistries base (mcpRegistry (Map.elems servers))

-- | Message shown when user sends a chat message but no provider is configured.
noProviderMessage :: Text
noProviderMessage = T.intercalate "\n"
  [ "No provider configured. To start chatting, configure your provider with:"
  , ""
  , "  /provider <PROVIDER>"
  , ""
  ]

-- | Message shown when user sends a chat message but no model is configured.
noModelMessage :: Text
noModelMessage = T.intercalate "\n"
  [ "No model configured. Set a model with:"
  , ""
  , "  /target <MODEL>"
  , ""
  , "or add 'model = \"<model>\"' to your config file."
  ]
