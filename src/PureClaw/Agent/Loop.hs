module PureClaw.Agent.Loop
  ( -- * Agent loop
    runAgentLoop
  ) where

import Control.Exception
import Control.Monad
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands
import PureClaw.Core.Errors
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Run the main agent loop. Reads messages from the channel, sends
-- them to the provider (with tool definitions), handles tool call/result
-- cycles, and writes responses back.
--
-- Slash commands (messages starting with '/') are intercepted and
-- handled before being sent to the provider.
--
-- Exits cleanly on 'IOException' from the channel (e.g. EOF / Ctrl-D).
-- Provider errors are logged and a 'PublicError' is sent to the channel.
runAgentLoop :: AgentEnv -> IO ()
runAgentLoop env = do
  _lh_logInfo logger "Agent loop started"
  go (emptyContext (_env_systemPrompt env))
  where
    provider = _env_provider env
    model    = _env_model env
    channel  = _env_channel env
    logger   = _env_logger env
    registry = _env_registry env
    tools    = registryDefinitions registry

    go ctx = do
      receiveResult <- try @IOException (_ch_receive channel)
      case receiveResult of
        Left _ -> _lh_logInfo logger "Session ended"
        Right msg
          | T.null (T.strip (_im_content msg)) -> go ctx
          | otherwise ->
              case parseSlashCommand (_im_content msg) of
                Just cmd -> do
                  _lh_logInfo logger $ "Slash command: " <> T.strip (_im_content msg)
                  ctx' <- executeSlashCommand env cmd ctx
                  go ctx'
                Nothing -> do
                  let userMsg = textMessage User (_im_content msg)
                      ctx' = addMessage userMsg ctx
                  _lh_logDebug logger $
                    "Sending " <> T.pack (show (length (contextMessages ctx'))) <> " messages"
                  handleCompletion ctx'

    handleCompletion ctx = do
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
              -- If not streamed, send the full text
              unless (wasStreaming || T.null (T.strip text)) $
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
                  handleCompletion ctx''

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
