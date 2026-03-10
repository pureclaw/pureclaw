module PureClaw.Agent.SlashCommands
  ( -- * Slash command parsing
    SlashCommand (..)
  , VaultSubCommand (..)
  , parseSlashCommand
    -- * Slash command execution
  , executeSlashCommand
  ) where

import Control.Exception
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import PureClaw.Agent.Compaction
import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Handles.Channel
import PureClaw.Security.Vault
import PureClaw.Security.Vault.Age

-- | Vault subcommands recognized by the '/vault' command family.
data VaultSubCommand
  = VaultInit                 -- ^ Initialize the vault file on disk
  | VaultAdd Text             -- ^ Add a named secret
  | VaultList                 -- ^ List secret names
  | VaultDelete Text          -- ^ Delete a named secret
  | VaultLock                 -- ^ Lock the vault
  | VaultUnlock               -- ^ Unlock the vault
  | VaultStatus'              -- ^ Show vault status
  | VaultUnknown Text         -- ^ Unrecognized subcommand
  deriving stock (Show, Eq)

-- | Recognized slash commands.
data SlashCommand
  = CmdNew           -- ^ Start a new session (clear context)
  | CmdReset         -- ^ Full reset (clear context and usage)
  | CmdStatus        -- ^ Show session status
  | CmdCompact       -- ^ Trigger context compaction
  | CmdVault VaultSubCommand  -- ^ Vault command family
  deriving stock (Show, Eq)

-- | Parse a user message as a slash command, if it starts with '/'.
-- Returns 'Nothing' for non-commands or unrecognized commands.
parseSlashCommand :: Text -> Maybe SlashCommand
parseSlashCommand input =
  let stripped = T.strip input
      lower    = T.toLower stripped
  in case lower of
    "/new"     -> Just CmdNew
    "/reset"   -> Just CmdReset
    "/status"  -> Just CmdStatus
    "/compact" -> Just CmdCompact
    _
      | "/vault" `T.isPrefixOf` lower ->
          let rest = T.strip (T.drop (T.length "/vault") stripped)
          in Just (CmdVault (parseVaultSubCommand rest))
      | otherwise -> Nothing

-- | Parse the subcommand portion of a '/vault <subcommand> [args]' input.
-- The input is the text after '/vault', already stripped.
parseVaultSubCommand :: Text -> VaultSubCommand
parseVaultSubCommand rest =
  let (sub, args) = T.break (== ' ') rest
      arg = T.strip args
  in case T.toLower sub of
    "init"   -> VaultInit
    "add"    -> VaultAdd arg
    "list"   -> VaultList
    "delete" -> VaultDelete arg
    "lock"   -> VaultLock
    "unlock" -> VaultUnlock
    "status" -> VaultStatus'
    _        -> VaultUnknown sub

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

executeSlashCommand env (CmdVault sub) ctx =
  case _env_vault env of
    Nothing -> do
      _ch_send (_env_channel env)
        (OutgoingMessage "No vault configured. Add vault settings to .pureclaw/config.toml.")
      pure ctx
    Just vault ->
      executeVaultCommand env vault sub ctx

-- | Execute a vault subcommand given a 'VaultHandle'.
executeVaultCommand
  :: AgentEnv
  -> VaultHandle
  -> VaultSubCommand
  -> Context
  -> IO Context
executeVaultCommand env vault sub ctx = do
  let ch   = _env_channel env
      send = _ch_send ch . OutgoingMessage
  case sub of
    VaultInit -> do
      result <- _vh_init vault
      case result of
        Left VaultAlreadyExists ->
          send "Vault already exists. Use /vault status to inspect."
        Left err ->
          send ("Vault init failed: " <> T.pack (show err))
        Right () ->
          send "Vault initialized successfully."
      pure ctx

    VaultAdd name -> do
      send ("Enter value for '" <> name <> "' (input will not be echoed):")
      valueResult <- try @IOError (_ch_readSecret ch)
      case valueResult of
        Left e ->
          send ("Error reading secret: " <> T.pack (show e))
        Right value -> do
          result <- _vh_put vault name (TE.encodeUtf8 value)
          case result of
            Left err -> send ("Error storing secret: " <> T.pack (show err))
            Right () -> send ("Secret '" <> name <> "' stored.")
      pure ctx

    VaultList -> do
      result <- _vh_list vault
      case result of
        Left err  -> send ("Error: " <> T.pack (show err))
        Right []  -> send "Vault is empty."
        Right names ->
          send ("Secrets:\n" <> T.unlines (map ("  \x2022 " <>) names))
      pure ctx

    VaultDelete name -> do
      send ("Delete secret '" <> name <> "'? [y/N]:")
      confirmMsg <- _ch_receive ch
      let confirm = T.strip (_im_content confirmMsg)
      if confirm == "y" || confirm == "Y"
        then do
          result <- _vh_delete vault name
          case result of
            Left err -> send ("Error: " <> T.pack (show err))
            Right () -> send ("Secret '" <> name <> "' deleted.")
        else send "Cancelled."
      pure ctx

    VaultLock -> do
      _vh_lock vault
      send "Vault locked."
      pure ctx

    VaultUnlock -> do
      result <- _vh_unlock vault
      case result of
        Left err -> send ("Error unlocking vault: " <> T.pack (show err))
        Right () -> send "Vault unlocked."
      pure ctx

    VaultStatus' -> do
      status <- _vh_status vault
      let lockedText = if _vs_locked status then "Locked" else "Unlocked"
          msg = T.intercalate "\n"
            [ "Vault status:"
            , "  State:   " <> lockedText
            , "  Secrets: " <> T.pack (show (_vs_secretCount status))
            , "  Key:     " <> _vs_keyType status
            ]
      send msg
      pure ctx

    VaultUnknown _ ->
      send "Unknown vault command. Available: init, add, list, delete, lock, unlock, status"
      >> pure ctx
