module PureClaw.Tools.Message
  ( -- * Tool registration
    messageTool
  ) where

import Control.Exception
import Data.Aeson
import Data.Aeson.Types
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Handles.Channel
import PureClaw.Providers.Class
import PureClaw.Tools.Registry

-- | Create a message tool for proactive agent-initiated messaging.
-- Sends a message to the active channel (Signal, Telegram, CLI, etc.).
-- Used for cron results, alerts, and notifications.
messageTool :: ChannelHandle -> (ToolDefinition, ToolHandler)
messageTool ch = (def, handler)
  where
    def = ToolDefinition
      { _td_name        = "message"
      , _td_description = "Send a proactive message to the user via the active channel. Use for alerts, cron results, and notifications."
      , _td_inputSchema = object
          [ "type" .= ("object" :: Text)
          , "properties" .= object
              [ "content" .= object
                  [ "type" .= ("string" :: Text)
                  , "description" .= ("The message content to send" :: Text)
                  ]
              ]
          , "required" .= (["content"] :: [Text])
          ]
      }

    handler = ToolHandler $ \input ->
      case parseEither parseInput input of
        Left err -> pure (T.pack err, True)
        Right content
          | T.null (T.strip content) -> pure ("Empty message", True)
          | otherwise -> do
              result <- try @SomeException
                (_ch_send ch (OutgoingMessage content))
              case result of
                Left e -> pure (T.pack (show e), True)
                Right () -> pure ("Message sent", False)

    parseInput :: Value -> Parser Text
    parseInput = withObject "MessageInput" $ \o -> o .: "content"
