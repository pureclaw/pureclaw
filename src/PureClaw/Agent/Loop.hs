module PureClaw.Agent.Loop
  ( -- * Agent loop
    runAgentLoop
    -- * Sanitization (exported for testing)
  , sanitizeHarnessOutput
  ) where

import Control.Exception
import Control.Monad
import Data.Char qualified as Char
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T

import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE

import PureClaw.Agent.Context
import PureClaw.Core.Types
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Errors
import PureClaw.Handles.Channel
import PureClaw.Handles.Harness
import PureClaw.Handles.Log
import PureClaw.Providers.Class
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
runAgentLoop :: AgentEnv -> IO ()
runAgentLoop env = do
  _lh_logInfo logger "Agent loop started"
  go (emptyContext (_env_systemPrompt env))
  where
    channel  = _env_channel env
    logger   = _env_logger env
    registry = _env_registry env
    tools    = registryDefinitions registry

    go ctx = do
      receiveResult <- try @IOException (_ch_receive channel)
      case receiveResult of
        Left _ -> _lh_logInfo logger "Session ended"
        Right msg
          | T.null stripped -> go ctx
          -- INVARIANT: any message beginning with '/' is handled locally and
          -- NEVER forwarded to the provider. Unknown slash commands get an
          -- error response rather than silently routing to the LLM.
          | "/" `T.isPrefixOf` stripped ->
              case parseSlashCommand stripped of
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
          | otherwise -> do
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
                        _ch_send channel (OutgoingMessage response)
                      go ctx
                TargetProvider -> do
                  mProvider <- readIORef (_env_provider env)
                  case mProvider of
                    Nothing -> do
                      _ch_send channel (OutgoingMessage noProviderMessage)
                      go ctx
                    Just provider -> do
                      let userMsg = textMessage User stripped
                          ctx' = addMessage userMsg ctx
                      _lh_logDebug logger $
                        "Sending " <> T.pack (show (length (contextMessages ctx'))) <> " messages"
                      -- Wrap provider with transcript logging if configured
                      mTranscript <- readIORef (_env_transcript env)
                      model <- readIORef (_env_model env)
                      let provider' = case mTranscript of
                            Just th -> mkTranscriptProvider th (unModelId model) provider
                            Nothing -> provider
                      handleCompletion provider' ctx'
          where stripped = T.strip (_im_content msg)

    handleCompletion provider ctx = do
      model <- readIORef (_env_model env)
      let req = CompletionRequest
            { _cr_model        = model
            , _cr_messages     = contextMessages ctx
            , _cr_systemPrompt = contextSystemPrompt ctx
            , _cr_maxTokens    = Just 4096
            , _cr_tools        = tools
            , _cr_toolChoice   = Nothing
            }
      responseRef <- newIORef (Nothing :: Maybe CompletionResponse)
      streamedRef <- newIORef False
      providerResult <- try @SomeException $
        completeStream provider req $ \case
          StreamText t -> do
            _ch_sendChunk channel (ChunkText t)
            writeIORef streamedRef True
          StreamDone resp ->
            writeIORef responseRef (Just resp)
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
                _ch_send channel (OutgoingMessage text)
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

-- | Message shown when user sends a chat message but no provider is configured.
noProviderMessage :: Text
noProviderMessage = T.intercalate "\n"
  [ "No provider configured. To start chatting, configure your provider with:"
  , ""
  , "  /provider <PROVIDER>"
  , ""
  ]

-- | Sanitize harness output for display in a TUI.
-- Strips ANSI escape sequences (CSI, OSC, DCS, etc.), C0\/C1 control
-- characters, and decorative Unicode (box drawing, block elements,
-- Private Use Area, etc.) that TUI applications use for rendering.
-- Also trims leading and trailing blank lines from tmux capture output.
sanitizeHarnessOutput :: Text -> Text
sanitizeHarnessOutput =
    trimBlankLines . T.pack . go . T.unpack
  where
    trimBlankLines =
      T.intercalate "\n"
      . dropWhileEnd isBlankLine
      . dropWhile isBlankLine
      . T.splitOn "\n"

    isBlankLine = T.all Char.isSpace

    dropWhileEnd _ [] = []
    dropWhileEnd p xs = reverse (dropWhile p (reverse xs))

    go [] = []
    go ('\ESC' : rest) = skipEscape rest
    -- Keep newlines and tabs
    go ('\n' : cs) = '\n' : go cs
    go ('\t' : cs) = '\t' : go cs
    -- Replace carriage return with newline (handles \r\n and bare \r)
    go ('\r' : '\n' : cs) = '\n' : go cs
    go ('\r' : cs) = '\n' : go cs
    -- Drop control characters, then decorative Unicode
    go (c : cs)
      | Char.isControl c  = go cs
      | isDecorativeChar c = go cs
      | otherwise          = c : go cs

    -- Skip ESC [ ... (final byte) — CSI sequences
    skipEscape ('[' : cs) = skipCsi cs
    -- Skip ESC ] ... ST — OSC sequences (terminated by BEL or ESC \)
    skipEscape (']' : cs) = skipOsc cs
    -- Skip ESC P ... ST — DCS sequences
    skipEscape ('P' : cs) = skipOsc cs
    -- Skip ESC ( X, ESC ) X — charset designators
    skipEscape ('(' : _ : cs) = go cs
    skipEscape (')' : _ : cs) = go cs
    -- Skip ESC followed by any single character (SS2, SS3, etc.)
    skipEscape (_ : cs) = go cs
    skipEscape [] = []

    -- CSI: skip parameter bytes (0x30-0x3F) and intermediate bytes (0x20-0x2F)
    -- until a final byte (0x40-0x7E)
    skipCsi [] = []
    skipCsi (c : cs)
      | c >= '@' && c <= '~' = go cs  -- final byte, done
      | otherwise             = skipCsi cs

    -- OSC / DCS: skip until BEL (0x07) or ST (ESC \)
    skipOsc [] = []
    skipOsc ('\BEL' : cs) = go cs
    skipOsc ('\ESC' : '\\' : cs) = go cs
    skipOsc (_ : cs) = skipOsc cs

-- | Characters used by TUI applications for rendering decorative elements.
-- These are valid Unicode but produce visual garbage when displayed outside
-- the originating terminal application.
isDecorativeChar :: Char -> Bool
isDecorativeChar c = let cp = Char.ord c in
  -- Box Drawing (U+2500–U+257F)
     (cp >= 0x2500 && cp <= 0x257F)
  -- Block Elements (U+2580–U+259F)
  || (cp >= 0x2580 && cp <= 0x259F)
  -- Geometric Shapes (U+25A0–U+25FF) — squares, circles, triangles
  || (cp >= 0x25A0 && cp <= 0x25FF)
  -- Braille Patterns (U+2800–U+28FF) — used for sparklines/graphs
  || (cp >= 0x2800 && cp <= 0x28FF)
  -- Private Use Area (U+E000–U+F8FF) — Powerline, Nerd Font icons
  || (cp >= 0xE000 && cp <= 0xF8FF)
  -- Supplementary Private Use Areas (U+F0000–U+10FFFF)
  || cp >= 0xF0000
