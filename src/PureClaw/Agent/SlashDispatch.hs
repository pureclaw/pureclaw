-- |
-- Module      : PureClaw.Agent.SlashDispatch
-- Description : Pure classification of web-frontend slash input.
--
-- This module owns the PURE half of slash dispatch for the web
-- frontend: 'classifyInput' maps raw user input to a 'SlashClass' by
-- reusing the SAME routing parser the TUI and channels use
-- ('PureClaw.Routing.Parse.parseInput'). Slash input is therefore
-- classified identically across every front end, and recognised
-- commands / short-circuit messages never reach the LLM.
--
-- The IO half ('runSlashInput') classifies input and executes a
-- recognised command against a lazily-built scoped env, returning the
-- captured output.
module PureClaw.Agent.SlashDispatch
  ( SlashResult (..)
  , SlashClass (..)
  , classifyInput
  , runSlashInput
  , deferralMessage
  ) where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context (Context, addMessage, emptyContext)
import PureClaw.Agent.Env (AgentEnv (..), envTranscript)
import PureClaw.Agent.SlashCommands (SlashCommand, executeSlashCommand)
import PureClaw.Handles.Channel (InteractiveUnsupported (..))
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT
import PureClaw.Session.Handle (loadRecentMessages)

-- | Outcome the transport acts on. 'SlashHandled' must NOT reach
-- inference.
data SlashResult
  = SlashHandled !Text      -- ^ short-circuit; this is the user-facing output
  | SlashPassThrough !Text  -- ^ ordinary chat; caller proceeds to inference
  deriving stock (Show, Eq)

-- | Pure classification of raw input.
data SlashClass
  = ClassPass !Text            -- ^ 'RT.Default': passthrough to inference
  | ClassMessage !Text         -- ^ Switch \/ Inject \/ ParseError: short-circuit text
  | ClassCommand !SlashCommand -- ^ a recognised command to execute
  deriving stock (Show, Eq)

-- | Classify input using the SAME parser the TUI \/ channels use.
--
-- The 'RT.Switch' and 'RT.Inject' forms are tab-routing shapes that
-- have no meaning in the web client, so they short-circuit to a
-- friendly message rather than being executed. Parser failures are
-- rendered with 'renderParseError'.
classifyInput :: RT.RoutingConfig -> Text -> SlashClass
classifyInput rc raw =
  case Parse.parseInput rc raw of
    Right (RT.Default t)        -> ClassPass t
    Right (RT.ParsedSlashCmd c) -> ClassCommand c
    Right (RT.Switch {})        -> ClassMessage switchMsg
    Right (RT.Inject {})        -> ClassMessage injectMsg
    Left err                    -> ClassMessage (renderParseError raw err)
  where
    switchMsg = "Tab switching isn't typed as /N in the web client — use the tab controls."
    injectMsg = "Cross-tab send isn't available from the web client yet."

-- | User-friendly rendering of a routing 'RT.ParseError' for a browser
-- bubble. Total over all 'RT.ParseError' constructors via the
-- catch-all arm, which doubles as the "unknown command" message.
renderParseError :: Text -> RT.ParseError -> Text
renderParseError raw err = case err of
  RT.ParseErrorInvalidSessionId -> "That doesn't look like a valid session id. Try /tabs to list."
  RT.ParseErrorEmptyInput       -> "Empty command. Try /help."
  RT.ParseErrorIndexOutOfRange n ->
    "Tab " <> T.pack (show n) <> " doesn't exist. Try /tabs to list."
  _ -> "Unknown command: " <> firstWord <> ". Try /help."
  where
    firstWord = T.takeWhile (/= ' ') (T.stripStart raw)

-- | Tracking issue for interactive-command support in the web UI. Embedded in
-- the deferral message shown when a prompting command is invoked over the web.
interactiveIssueUrl :: Text
interactiveIssueUrl = "https://github.com/pureclaw/pureclaw/issues/84"

-- | Execute one line of user input against a lazily-built scoped env.
--
-- @mkScoped@ builds (scoped env, output reader): the env's '_env_channel' is a
-- capture channel and '_env_session' the target session. It is invoked ONLY for
-- a recognized command, so passthrough chat and short-circuit messages pay no
-- scoping cost.
runSlashInput :: AgentEnv -> IO (AgentEnv, IO Text) -> Text -> IO SlashResult
runSlashInput base mkScoped raw =
  case classifyInput (_env_routingConfig base) raw of
    ClassPass t      -> pure (SlashPassThrough t)
    ClassMessage t   -> pure (SlashHandled t)
    ClassCommand cmd -> do
      (scoped, readOut) <- mkScoped
      ctx <- buildContext scoped
      outcome <- try (executeSlashCommand scoped cmd ctx)
        :: IO (Either InteractiveUnsupported Context)
      case outcome of
        Right _ -> SlashHandled <$> readOut
        Left (InteractiveUnsupported _) ->
          SlashHandled . deferralMessage cmd <$> readOut

-- | Build a Context from the scoped session's transcript so read-only commands
-- (e.g. /status) report accurate counts. The Context returned by the command is
-- discarded (output is transient).
buildContext :: AgentEnv -> IO Context
buildContext env = do
  tx <- envTranscript env
  history <- loadRecentMessages tx 50 100000
  pure (foldl (flip addMessage) (emptyContext Nothing) history)

-- | Render the user-facing deferral text for an interactive command, preserving
-- any output the command buffered before it tried to prompt.
deferralMessage :: SlashCommand -> Text -> Text
deferralMessage _cmd buffered =
  let note = "This command needs interactive input, which the web UI doesn't \
             \support yet (tracking: " <> interactiveIssueUrl <> "). Use the CLI for now."
   in if T.null buffered then note else buffered <> "\n" <> note
