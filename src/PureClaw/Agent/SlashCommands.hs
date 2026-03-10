module PureClaw.Agent.SlashCommands
  ( -- * Slash command parsing
    SlashCommand (..)
  , parseSlashCommand
    -- * Slash command execution
  , executeSlashCommand
  ) where

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Compaction
import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Handles.Channel

-- | Recognized slash commands.
data SlashCommand
  = CmdNew           -- ^ Start a new session (clear context)
  | CmdReset         -- ^ Full reset (clear context and usage)
  | CmdStatus        -- ^ Show session status
  | CmdCompact       -- ^ Trigger context compaction
  deriving stock (Show, Eq)

-- | Parse a user message as a slash command, if it starts with '/'.
-- Returns 'Nothing' for non-commands or unrecognized commands.
parseSlashCommand :: Text -> Maybe SlashCommand
parseSlashCommand input =
  let stripped = T.strip input
  in case T.toLower stripped of
    "/new"     -> Just CmdNew
    "/reset"   -> Just CmdReset
    "/status"  -> Just CmdStatus
    "/compact" -> Just CmdCompact
    _          -> Nothing

-- | Execute a slash command against a context.
-- Returns the updated context.
executeSlashCommand
  :: AgentEnv
  -> SlashCommand
  -> Context
  -> IO Context
executeSlashCommand env CmdNew ctx = do
  _ch_send (_env_channel env) (OutgoingMessage "Session cleared. Starting fresh.")
  pure (clearMessages ctx)

executeSlashCommand env CmdReset _ctx = do
  _ch_send (_env_channel env) (OutgoingMessage "Full reset. Context and usage cleared.")
  pure (emptyContext (contextSystemPrompt _ctx))

executeSlashCommand env CmdStatus ctx = do
  let tokens   = contextTokenEstimate ctx
      msgs     = contextMessageCount ctx
      inToks   = contextTotalInputTokens ctx
      outToks  = contextTotalOutputTokens ctx
      status   = T.intercalate "\n"
        [ "Session status:"
        , "  Messages: " <> T.pack (show msgs)
        , "  Est. context tokens: " <> T.pack (show tokens)
        , "  Total input tokens: " <> T.pack (show inToks)
        , "  Total output tokens: " <> T.pack (show outToks)
        ]
  _ch_send (_env_channel env) (OutgoingMessage status)
  pure ctx

executeSlashCommand env CmdCompact ctx = do
  (ctx', result) <- compactContext
    (_env_provider env)
    (_env_model env)
    0  -- force compaction regardless of threshold
    defaultKeepRecent
    ctx
  let msg = case result of
        NotNeeded      -> "Nothing to compact (too few messages)."
        Compacted o n  -> "Compacted: " <> T.pack (show o)
                       <> " messages → " <> T.pack (show n)
        CompactionError e -> "Compaction failed: " <> e
  _ch_send (_env_channel env) (OutgoingMessage msg)
  pure ctx'
