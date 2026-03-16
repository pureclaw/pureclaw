module PureClaw.Channels.Signal
  ( -- * Signal channel
    SignalChannel (..)
  , SignalConfig (..)
  , mkSignalChannel
  , withSignalChannel
  , readerLoop
    -- * Message parsing
  , parseSignalEnvelope
  , SignalEnvelope (..)
  , SignalDataMessage (..)
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Channels.Class
import PureClaw.Channels.Signal.Transport
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log

-- | Configuration for Signal channel.
data SignalConfig = SignalConfig
  { _sc_account        :: Text
  , _sc_textChunkLimit :: Int
  , _sc_allowFrom      :: AllowList UserId
  }
  deriving stock (Show, Eq)

-- | A Signal channel backed by a message queue and a transport.
-- The reader thread parses signal-cli output and pushes envelopes to the inbox.
-- Send goes through the transport directly.
data SignalChannel = SignalChannel
  { _sch_config    :: SignalConfig
  , _sch_inbox     :: TQueue SignalEnvelope
  , _sch_transport :: SignalTransport
  , _sch_lastSender :: IORef Text
  , _sch_log       :: LogHandle
  }

-- | Create a Signal channel from a config and transport.
-- Does NOT start the reader thread — use 'withSignalChannel' for that.
mkSignalChannel :: SignalConfig -> SignalTransport -> LogHandle -> IO SignalChannel
mkSignalChannel config transport lh = do
  inbox <- newTQueueIO
  lastSender <- newIORef (_sc_account config)
  pure SignalChannel
    { _sch_config     = config
    , _sch_inbox      = inbox
    , _sch_transport  = transport
    , _sch_lastSender = lastSender
    , _sch_log        = lh
    }

-- | Run a Signal channel with full lifecycle management.
-- Starts the reader thread, runs the callback, cleans up on exit.
withSignalChannel :: SignalConfig -> SignalTransport -> LogHandle -> (ChannelHandle -> IO a) -> IO a
withSignalChannel config transport lh action = do
  sc <- mkSignalChannel config transport lh
  -- Start the reader thread that pumps signal-cli output into the inbox
  readerTid <- forkIO (readerLoop sc)
  let cleanup = do
        killThread readerTid
        _st_close transport
  action (toHandle sc) `finally` cleanup

-- | Background thread that reads from the transport and pushes
-- parsed envelopes into the inbox queue.
readerLoop :: SignalChannel -> IO ()
readerLoop sc = go
  where
    go = do
      result <- try @SomeException (_st_receive (_sch_transport sc))
      case result of
        Left err -> do
          _lh_logWarn (_sch_log sc) $
            "signal-cli reader stopped: " <> T.pack (show err)
          -- Don't restart — let the channel die, agent loop will get IOError
        Right val -> do
          case parseSignalEnvelope val of
            Left err ->
              _lh_logWarn (_sch_log sc) $ "Ignoring unparseable envelope: " <> T.pack err
            Right envelope ->
              case _se_dataMessage envelope of
                Nothing -> pure ()  -- Skip non-data envelopes (receipts, typing, etc.)
                Just _ ->
                  let sender = UserId (_se_source envelope)
                      allowed = isAllowed (_sc_allowFrom (_sch_config sc)) sender
                  in if allowed
                    then atomically $ writeTQueue (_sch_inbox sc) envelope
                    else _lh_logWarn (_sch_log sc) $
                      "Blocked message from unauthorized sender: " <> _se_source envelope
          go

instance Channel SignalChannel where
  toHandle sc = ChannelHandle
    { _ch_receive      = receiveEnvelope sc
    , _ch_send         = sendSignalMessage sc
    , _ch_sendError    = sendSignalError sc
    , _ch_sendChunk    = \_ -> pure ()  -- Signal doesn't support streaming
    , _ch_readSecret   = ioError (userError "Vault management requires the CLI interface")
    , _ch_prompt       = \promptText -> do
        sendSignalMessage sc (OutgoingMessage promptText)
        _im_content <$> receiveEnvelope sc
    , _ch_promptSecret = \_ ->
        ioError (userError "Vault management requires the CLI interface")
    }

-- | Block until a Signal envelope arrives in the queue.
receiveEnvelope :: SignalChannel -> IO IncomingMessage
receiveEnvelope sc = do
  envelope <- atomically $ readTQueue (_sch_inbox sc)
  let sender = _se_source envelope
      content = maybe "" _sdm_message (_se_dataMessage envelope)
  writeIORef (_sch_lastSender sc) sender
  pure IncomingMessage
    { _im_userId  = UserId sender
    , _im_content = content
    }

-- | Send a message via Signal, chunking if necessary.
sendSignalMessage :: SignalChannel -> OutgoingMessage -> IO ()
sendSignalMessage sc msg = do
  recipient <- readIORef (_sch_lastSender sc)
  let limit  = _sc_textChunkLimit (_sch_config sc)
      chunks = chunkMessage limit (_om_content msg)
  mapM_ (_st_send (_sch_transport sc) recipient) chunks

-- | Send an error via Signal.
sendSignalError :: SignalChannel -> PublicError -> IO ()
sendSignalError sc err = do
  recipient <- readIORef (_sch_lastSender sc)
  _st_send (_sch_transport sc) recipient ("Error: " <> T.pack (show err))

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
  parseJSON = withObject "SignalEnvelope" $ \o -> do
    -- signal-cli uses "source" in older versions, "sourceNumber" in newer
    source <- o .:? "sourceNumber" >>= \case
      Just s  -> pure s
      Nothing -> o .: "source"
    SignalEnvelope source <$> o .: "timestamp" <*> o .:? "dataMessage"

instance FromJSON SignalDataMessage where
  parseJSON = withObject "SignalDataMessage" $ \o ->
    SignalDataMessage <$> o .: "message" <*> o .: "timestamp"

-- | Parse a JSON value as a Signal envelope.
-- Handles both raw envelopes and JSON-RPC wrapped messages from signal-cli.
-- JSON-RPC format: @{"jsonrpc":"2.0","method":"receive","params":{"envelope":{...}}}@
parseSignalEnvelope :: Value -> Either String SignalEnvelope
parseSignalEnvelope v = case parseEither unwrap v of
  Left err -> Left err
  Right env -> Right env
  where
    unwrap = withObject "SignalMessage" $ \o -> do
      -- Try JSON-RPC wrapper first: params.envelope
      mParams <- o .:? "params"
      case mParams of
        Just params -> do
          mEnvelope <- params .:? "envelope"
          case mEnvelope of
            Just envelope -> parseJSON envelope
            Nothing       -> fail "JSON-RPC message has no 'envelope' in 'params'"
        Nothing -> parseJSON (Object o)  -- Try raw envelope
