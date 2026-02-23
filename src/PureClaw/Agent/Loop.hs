module PureClaw.Agent.Loop
  ( -- * Agent loop
    runAgentLoop
  ) where

import Control.Exception
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Context
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Providers.Class

-- | Run the main agent loop. Reads messages from the channel, sends
-- them to the provider, and writes responses back.
--
-- Exits cleanly on 'IOException' from the channel (e.g. EOF / Ctrl-D).
-- Provider errors are logged and a 'PublicError' is sent to the channel.
runAgentLoop :: Provider p => p -> ModelId -> ChannelHandle -> LogHandle -> Maybe Text -> IO ()
runAgentLoop provider model channel logger systemPrompt = do
  _lh_logInfo logger "Agent loop started"
  go (emptyContext systemPrompt)
  where
    go ctx = do
      receiveResult <- try @IOException (_ch_receive channel)
      case receiveResult of
        Left _ -> _lh_logInfo logger "Session ended"
        Right msg
          | T.null (T.strip (_im_content msg)) -> go ctx
          | otherwise -> do
              let userMsg = Message User (_im_content msg)
                  ctx' = addMessage userMsg ctx
                  req = CompletionRequest
                    { _cr_model        = model
                    , _cr_messages     = contextMessages ctx'
                    , _cr_systemPrompt = contextSystemPrompt ctx'
                    , _cr_maxTokens    = Just 4096
                    }
              _lh_logDebug logger $
                "Sending " <> T.pack (show (length (contextMessages ctx'))) <> " messages"
              providerResult <- try @SomeException (complete provider req)
              case providerResult of
                Left e -> do
                  _lh_logError logger $ "Provider error: " <> T.pack (show e)
                  _ch_sendError channel (TemporaryError "Something went wrong. Please try again.")
                  go ctx'
                Right response -> do
                  let assistantMsg = Message Assistant (_crsp_content response)
                      ctx'' = addMessage assistantMsg ctx'
                  _ch_send channel (OutgoingMessage (_crsp_content response))
                  go ctx''
