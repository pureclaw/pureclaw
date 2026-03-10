module PureClaw.Channels.Signal
  ( -- * Signal channel
    SignalChannel (..)
  , SignalConfig (..)
  , mkSignalChannel
    -- * Message parsing
  , parseSignalEnvelope
  , SignalEnvelope (..)
  , SignalDataMessage (..)
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

-- | Configuration for Signal channel.
newtype SignalConfig = SignalConfig
  { _sc_account :: Text
  }
  deriving stock (Show, Eq)

-- | A Signal channel backed by a message queue. Messages from signal-cli
-- are pushed into the queue and the agent loop pulls them out via 'receive'.
data SignalChannel = SignalChannel
  { _sch_config :: SignalConfig
  , _sch_inbox  :: TQueue SignalEnvelope
  , _sch_log    :: LogHandle
  }

-- | Create a Signal channel with an empty inbox.
mkSignalChannel :: SignalConfig -> LogHandle -> IO SignalChannel
mkSignalChannel config lh = do
  inbox <- newTQueueIO
  pure SignalChannel
    { _sch_config = config
    , _sch_inbox  = inbox
    , _sch_log    = lh
    }

instance Channel SignalChannel where
  toHandle sc = ChannelHandle
    { _ch_receive   = receiveEnvelope sc
    , _ch_send      = sendSignalMessage sc
    , _ch_sendError = sendSignalError sc
    , _ch_sendChunk = \_ -> pure ()  -- Signal doesn't support streaming
    }

-- | Block until a Signal envelope arrives in the queue.
receiveEnvelope :: SignalChannel -> IO IncomingMessage
receiveEnvelope sc = do
  envelope <- atomically $ readTQueue (_sch_inbox sc)
  let sender = _se_source envelope
      content = maybe "" _sdm_message (_se_dataMessage envelope)
  pure IncomingMessage
    { _im_userId  = UserId sender
    , _im_content = content
    }

-- | Send a message via Signal. In a full implementation this would
-- invoke signal-cli. For now, logs the outgoing message.
sendSignalMessage :: SignalChannel -> OutgoingMessage -> IO ()
sendSignalMessage sc msg =
  _lh_logInfo (_sch_log sc) $ "Signal send: " <> _om_content msg

-- | Send an error via Signal.
sendSignalError :: SignalChannel -> PublicError -> IO ()
sendSignalError sc err =
  _lh_logWarn (_sch_log sc) $ "Signal error: " <> T.pack (show err)

-- | A Signal envelope (simplified JSON-RPC format from signal-cli).
data SignalEnvelope = SignalEnvelope
  { _se_source      :: Text
  , _se_timestamp   :: Int
  , _se_dataMessage :: Maybe SignalDataMessage
  }
  deriving stock (Show, Eq)

-- | A Signal data message.
data SignalDataMessage = SignalDataMessage
  { _sdm_message   :: Text
  , _sdm_timestamp :: Int
  }
  deriving stock (Show, Eq)

instance FromJSON SignalEnvelope where
  parseJSON = withObject "SignalEnvelope" $ \o ->
    SignalEnvelope <$> o .: "source" <*> o .: "timestamp" <*> o .:? "dataMessage"

instance FromJSON SignalDataMessage where
  parseJSON = withObject "SignalDataMessage" $ \o ->
    SignalDataMessage <$> o .: "message" <*> o .: "timestamp"

-- | Parse a JSON value as a Signal envelope.
parseSignalEnvelope :: Value -> Either String SignalEnvelope
parseSignalEnvelope v = case fromJSON v of
  Error err -> Left err
  Success e -> Right e
