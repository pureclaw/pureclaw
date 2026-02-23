module PureClaw.Channels.Telegram
  ( -- * Telegram channel
    TelegramChannel (..)
  , TelegramConfig (..)
  , mkTelegramChannel
    -- * Message parsing
  , parseTelegramUpdate
  , TelegramUpdate (..)
  , TelegramMessage (..)
  , TelegramChat (..)
  , TelegramUser (..)
  ) where

import Control.Concurrent.STM
import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Channels.Class
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Handles.Network

-- | Configuration for Telegram channel.
data TelegramConfig = TelegramConfig
  { _tc_botToken :: Text
  , _tc_apiBase  :: Text
  }
  deriving stock (Show, Eq)

-- | A Telegram channel backed by a message queue. Updates are pushed
-- into the queue (e.g. from a webhook endpoint) and the agent loop
-- pulls them out via 'receive'. Responses are sent via the Telegram
-- Bot API using the provided 'NetworkHandle'.
data TelegramChannel = TelegramChannel
  { _tch_config  :: TelegramConfig
  , _tch_inbox   :: TQueue TelegramUpdate
  , _tch_network :: NetworkHandle
  , _tch_log     :: LogHandle
  }

-- | Create a Telegram channel with an empty inbox.
mkTelegramChannel :: TelegramConfig -> NetworkHandle -> LogHandle -> IO TelegramChannel
mkTelegramChannel config nh lh = do
  inbox <- newTQueueIO
  pure TelegramChannel
    { _tch_config  = config
    , _tch_inbox   = inbox
    , _tch_network = nh
    , _tch_log     = lh
    }

instance Channel TelegramChannel where
  toHandle tc = ChannelHandle
    { _ch_receive   = receiveUpdate tc
    , _ch_send      = sendMessage tc
    , _ch_sendError = sendTelegramError tc
    }

-- | Block until a Telegram update arrives in the queue.
receiveUpdate :: TelegramChannel -> IO IncomingMessage
receiveUpdate tc = do
  update <- atomically $ readTQueue (_tch_inbox tc)
  let msg = _tu_message update
      userId = T.pack (show (_tu_id (_tm_from msg)))
      content = _tm_text msg
  pure IncomingMessage
    { _im_userId  = UserId userId
    , _im_content = content
    }

-- | Send a message to the chat that the last update came from.
-- In a full implementation this would POST to the Telegram sendMessage API.
-- For now, logs the outgoing message.
sendMessage :: TelegramChannel -> OutgoingMessage -> IO ()
sendMessage tc msg =
  _lh_logInfo (_tch_log tc) $ "Telegram send: " <> _om_content msg

-- | Send an error to the Telegram chat.
sendTelegramError :: TelegramChannel -> PublicError -> IO ()
sendTelegramError tc err =
  _lh_logWarn (_tch_log tc) $ "Telegram error: " <> T.pack (show err)

-- | A Telegram Update object (simplified).
data TelegramUpdate = TelegramUpdate
  { _tu_updateId :: Int
  , _tu_message  :: TelegramMessage
  }
  deriving stock (Show, Eq)

-- | A Telegram Message object (simplified).
data TelegramMessage = TelegramMessage
  { _tm_messageId :: Int
  , _tm_from      :: TelegramUser
  , _tm_chat      :: TelegramChat
  , _tm_text      :: Text
  }
  deriving stock (Show, Eq)

-- | A Telegram Chat object (simplified).
data TelegramChat = TelegramChat
  { _tcht_id   :: Int
  , _tcht_type :: Text
  }
  deriving stock (Show, Eq)

-- | A Telegram User object (simplified).
data TelegramUser = TelegramUser
  { _tu_id        :: Int
  , _tu_firstName :: Text
  }
  deriving stock (Show, Eq)

instance FromJSON TelegramUpdate where
  parseJSON = withObject "TelegramUpdate" $ \o ->
    TelegramUpdate <$> o .: "update_id" <*> o .: "message"

instance FromJSON TelegramMessage where
  parseJSON = withObject "TelegramMessage" $ \o ->
    TelegramMessage <$> o .: "message_id" <*> o .: "from" <*> o .: "chat" <*> o .: "text"

instance FromJSON TelegramChat where
  parseJSON = withObject "TelegramChat" $ \o ->
    TelegramChat <$> o .: "id" <*> o .: "type"

instance FromJSON TelegramUser where
  parseJSON = withObject "TelegramUser" $ \o ->
    TelegramUser <$> o .: "id" <*> o .: "first_name"

-- | Parse a JSON value as a Telegram update.
parseTelegramUpdate :: Value -> Either String TelegramUpdate
parseTelegramUpdate v = case fromJSON v of
  Error err   -> Left err
  Success upd -> Right upd
