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
-- The IO half ('runSlashInput') lands in a later task; it is
-- deliberately NOT defined or exported here.
module PureClaw.Agent.SlashDispatch
  ( SlashResult (..)
  , SlashClass (..)
  , classifyInput
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.SlashCommands (SlashCommand)
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Types qualified as RT

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
