module PureClaw.Agent.Loop
  ( -- * Agent loop
    runAgentLoop
    -- * Re-exports from Handles.Harness (for backward compatibility)
  , sanitizeHarnessOutput
  ) where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.Foldable (for_)
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
                        _ch_send channel (OutgoingMessage (prefixHarnessOutput name response))
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
                      -- Wrap provider with transcript logging (session owns the transcript)
                      th <- envTranscript env
                      model <- readIORef (_env_model env)
                      let provider' = mkTranscriptProvider th (unModelId model) provider
                      handleCompletion provider' ctx'
          where stripped = T.strip (_im_content msg)

    handleCompletion provider ctx = do
      model <- readIORef (_env_model env)
      let modelName = unModelId model
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
                         (\m -> (Nothing, m))
            for_ mAction id
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
