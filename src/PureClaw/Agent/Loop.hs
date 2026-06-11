module PureClaw.Agent.Loop
  ( -- * Background tasks (/bg, issue #52)
    runBackgroundTurn
    -- * Re-exports from Handles.Harness (for backward compatibility)
  , sanitizeHarnessOutput
  ) where

import Control.Exception
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import Data.Map.Strict qualified as Map

import PureClaw.Agent.AgentDef qualified as AgentDef
import PureClaw.Core.Types
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands (getSessionsDir)
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Handles.Transcript qualified as Transcript
import PureClaw.MCP (mcpRegistry)
import PureClaw.Providers.Class
import PureClaw.Session.Handle qualified as Session
import PureClaw.Session.Types qualified as SessionTypes
import PureClaw.Tools.Delegate (runSubAgent)
import PureClaw.Tools.Registry
import PureClaw.Transcript.Provider

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
-- This intentionally does NOT go through the tab-output queue
-- ('_env_tabOutQ') — the background turn emits directly so its result is
-- delivered even without the relay-writer thread in scope.
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
-- merged with any connected MCP server tools.
backgroundRegistry :: AgentEnv -> IO ToolRegistry
backgroundRegistry env = do
  servers <- readIORef (_env_mcpServers env)
  let base = _env_registry env
  pure $ if Map.null servers
           then base
           else mergeRegistries base (mcpRegistry (Map.elems servers))
