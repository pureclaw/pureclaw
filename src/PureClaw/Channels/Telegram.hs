module PureClaw.Channels.Telegram
  ( -- * Telegram channel
    TelegramChannel (..)
  , TelegramConfig (..)
  , mkTelegramChannel
  , withTelegramChannel
  , receiveUpdate
    -- * Message parsing
  , parseTelegramUpdate
  , TelegramUpdate (..)
  , TelegramMessage (..)
  , TelegramChat (..)
  , TelegramUser (..)
    -- * Conversation derivation
  , conversationIdForTelegram
    -- * BotFather command registration (Tabbed Chat O3)
  , botFatherCommands
  , registerBotFatherCommands
  , encodeBotFatherCommands
  ) where

import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types.URI qualified as URI

import PureClaw.Channels.AllowList
import PureClaw.Channels.Class
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Handles.Network
import PureClaw.Routing.Onboarding (botFatherCommandList)

-- | Configuration for Telegram channel.
data TelegramConfig = TelegramConfig
  { _tc_botToken  :: Text
  , _tc_apiBase   :: Text
  , _tc_allowFrom :: AllowList UserId
  }
  deriving stock (Show, Eq)

-- | A Telegram channel backed by a message queue. Updates are pushed
-- into the queue (e.g. from a webhook endpoint) and the agent loop
-- pulls them out via 'receive'. Responses are sent via the Telegram
-- Bot API using the provided 'NetworkHandle'.
data TelegramChannel = TelegramChannel
  { _tch_config   :: TelegramConfig
  , _tch_inbox    :: TQueue TelegramUpdate
  , _tch_network  :: NetworkHandle
  , _tch_log      :: LogHandle
  , _tch_lastChat :: IORef (Maybe Int)
  }

-- | Create a Telegram channel with an empty inbox.
mkTelegramChannel :: TelegramConfig -> NetworkHandle -> LogHandle -> IO TelegramChannel
mkTelegramChannel config nh lh = do
  inbox <- newTQueueIO
  chatRef <- newIORef Nothing
  pure TelegramChannel
    { _tch_config   = config
    , _tch_inbox    = inbox
    , _tch_network  = nh
    , _tch_log      = lh
    , _tch_lastChat = chatRef
    }

-- | The 'AllowListContext' used for the Telegram open-allow-list warning.
-- The example id is a sample numeric Telegram user/chat id.
telegramAllowListContext :: AllowListContext
telegramAllowListContext = AllowListContext "Telegram" "telegram" "123456789"

-- | Activate a Telegram channel with allow-list-warning handling.
--
-- Unlike Signal there is no reader thread and no transport to close: Telegram
-- updates are pushed into the inbox by an external webhook. This wrapper is
-- the SINGLE home for the Telegram open-allow-list warning — it fires whenever
-- Telegram is activated; a future gateway boot path routes through it.
-- 'mkTelegramChannel' itself stays warning-free (no test-construction noise).
withTelegramChannel :: TelegramConfig -> NetworkHandle -> LogHandle -> (ChannelHandle -> IO a) -> IO a
withTelegramChannel config nh lh action = do
  warnIfOpenAllowList lh telegramAllowListContext (_tc_allowFrom config)
  tc <- mkTelegramChannel config nh lh
  action (toHandle tc)

instance Channel TelegramChannel where
  toHandle tc = ChannelHandle
    { _ch_receive      = receiveUpdate tc
    , _ch_send         = sendMessage tc
    , _ch_sendError    = sendTelegramError tc
    , _ch_sendChunk    = \_ -> pure ()  -- Telegram doesn't support streaming
    , _ch_streaming    = False
    , _ch_readSecret   = ioError (userError "Vault management requires the CLI interface")
    , _ch_prompt       = \promptText -> do
        sendMessage tc (OutgoingMessage promptText)
        _im_content <$> receiveUpdate tc
    , _ch_promptSecret = \_ ->
        ioError (userError "Vault management requires the CLI interface")
    }

-- | Block until an *authorized* Telegram update arrives in the queue.
--
-- Reads one update at a time (consuming it from the inbox). An update passes
-- when its allow-list policy permits either the sender's user id or the
-- conversation's chat id.
--
-- Note: the chat id is matched by wrapping it in the 'UserId' newtype, the same
-- way Signal wraps both phone numbers and UUIDs. This is an intentional
-- conflation for access-control matching — the allow-list gates "may this
-- message in?" against any sender-or-conversation identifier; it is not
-- identity disambiguation. Numeric IDs only (usernames are not parsed or
-- supported). Unauthorized updates are consumed, logged at WARN, and discarded
-- (mirroring Signal's drop-and-log), then we recurse to read the next update.
receiveUpdate :: TelegramChannel -> IO IncomingMessage
receiveUpdate tc = do
  update <- atomically $ readTQueue (_tch_inbox tc)
  let msg = _tu_message update
      userId = T.pack (show (_tu_id (_tm_from msg)))
      chatId = _tcht_id (_tm_chat msg)
      content = _tm_text msg
      flds = Map.singleton "chat_id" (toJSON chatId)
      policy = _tc_allowFrom (_tch_config tc)
      allowed = isAllowed policy (UserId userId)
             || isAllowed policy (UserId (T.pack (show chatId)))
  if allowed
    then do
      writeIORef (_tch_lastChat tc) (Just chatId)
      pure IncomingMessage
        { _im_source  = mkMessageSource CkTelegram (conversationIdForTelegram msg)
                          (Just (UserId userId)) flds
        , _im_content = content
        }
    else do
      _lh_logWarn (_tch_log tc) $
        "Blocked Telegram message from unauthorized sender (user "
          <> userId <> ", chat " <> T.pack (show chatId) <> ")"
      receiveUpdate tc

-- | Derive the 'ConversationId' for a Telegram message from its CHAT id
-- (@_tcht_id . _tm_chat@), NOT the sender's user id (@_tm_from@).
--
-- Using the chat id means every sender in a group chat shares one
-- 'ConversationId' (and therefore one tab cursor), which is the intended
-- behaviour. It also avoids the UserId conflation the allow-list work warns
-- about: the conversation key is a property of the conversation, not of who
-- spoke. The id is server-derived from the authenticated Bot API payload.
conversationIdForTelegram :: TelegramMessage -> ConversationId
conversationIdForTelegram msg =
  ConversationId (T.pack (show (_tcht_id (_tm_chat msg))))

-- | Send a message to the last active chat via the Telegram Bot API.
sendMessage :: TelegramChannel -> OutgoingMessage -> IO ()
sendMessage tc msg = do
  chatId <- readIORef (_tch_lastChat tc)
  case chatId of
    Nothing -> _lh_logWarn (_tch_log tc) "No chat_id available for send"
    Just cid -> do
      result <- try @SomeException (postTelegram tc "sendMessage" cid (_om_content msg))
      case result of
        Left e -> _lh_logError (_tch_log tc) $ "Telegram send failed: " <> T.pack (show e)
        Right resp
          | _hr_statusCode resp == 200 -> pure ()
          | otherwise ->
              _lh_logError (_tch_log tc) $
                "Telegram API error " <> T.pack (show (_hr_statusCode resp))

-- | Send an error message to the Telegram chat.
sendTelegramError :: TelegramChannel -> PublicError -> IO ()
sendTelegramError tc err = do
  chatId <- readIORef (_tch_lastChat tc)
  case chatId of
    Nothing -> _lh_logWarn (_tch_log tc) "No chat_id available for error send"
    Just cid -> do
      let errText = case err of
            RateLimitError -> "Rate limited. Please try again in a moment."
            NotAllowedError -> "Not allowed."
            TemporaryError t -> t
      result <- try @SomeException (postTelegram tc "sendMessage" cid errText)
      case result of
        Left e -> _lh_logError (_tch_log tc) $ "Telegram error send failed: " <> T.pack (show e)
        Right _ -> pure ()

-- | POST to a Telegram Bot API method with chat_id and text parameters.
postTelegram :: TelegramChannel -> Text -> Int -> Text -> IO HttpResponse
postTelegram tc method chatId text = do
  let config = _tch_config tc
      url = _tc_apiBase config <> "/bot" <> _tc_botToken config <> "/" <> method
      body = "chat_id=" <> URI.urlEncode False (TE.encodeUtf8 (T.pack (show chatId)))
          <> "&text=" <> URI.urlEncode False (TE.encodeUtf8 text)
  case mkAllowedUrl AllowAll url of
    Left e -> throwIO (userError ("Bad Telegram URL: " <> show e))
    Right allowed -> _nh_httpPost (_tch_network tc) allowed body

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

-- ---------------------------------------------------------------------------
-- BotFather command registration (Tabbed Chat O3)
-- ---------------------------------------------------------------------------

-- | The list of @(command, description)@ tuples PureClaw registers
-- with Telegram's @setMyCommands@ API at channel-startup time.
--
-- Re-exported from "PureClaw.Routing.Onboarding" so the golden file
-- and the @\/help@ subsection live next to each other; the Telegram
-- channel only needs to publish the list, not own it.
--
-- See @docs\/tabbed-chat.md@ §\"Channel autocomplete\" (registration
-- list) and §\"Onboarding (O-series)\" O3 (the golden enumeration).
botFatherCommands :: [(Text, Text)]
botFatherCommands = botFatherCommandList

-- | Encode 'botFatherCommands' as the JSON payload Telegram's
-- @setMyCommands@ endpoint accepts.
--
-- The endpoint expects @{ \"commands\": [ { \"command\": \"...\",
-- \"description\": \"...\" }, ... ] }@. The leading slash on each
-- command is stripped (Telegram expects bare command words). The
-- resulting payload is a strict 'ByteString' suitable for an
-- @application\/json@ POST body.
encodeBotFatherCommands :: [(Text, Text)] -> ByteString
encodeBotFatherCommands cmds =
  BL.toStrict (encode (object ["commands" .= map toEntry cmds]))
  where
    toEntry (c, d) = object
      [ "command"     .= T.dropWhile (== '/') c
      , "description" .= d
      ]

-- | Register 'botFatherCommands' with Telegram via the
-- @setMyCommands@ Bot API method.
--
-- POSTs an @application\/json@ payload to
-- @\<api-base\>\/bot\<token\>\/setMyCommands@. Logs (but does not
-- throw) on failure: BotFather autocomplete is a UX enhancement, not
-- a correctness requirement, so a transient failure at startup must
-- not prevent the bot from booting.
--
-- Mirrors the existing 'postTelegram' helper for URL construction
-- (same shape, different endpoint name and Content-Type).
--
-- Per Tabbed Chat O3 this is invoked once at channel startup by the
-- gateway boot path (callers wire it in alongside 'mkTelegramChannel').
registerBotFatherCommands :: TelegramChannel -> IO ()
registerBotFatherCommands tc = do
  let config = _tch_config tc
      url    = _tc_apiBase config <> "/bot" <> _tc_botToken config
            <> "/setMyCommands"
      body   = encodeBotFatherCommands botFatherCommands
  case mkAllowedUrl AllowAll url of
    Left e ->
      _lh_logError (_tch_log tc) $
        "BotFather setMyCommands URL rejected: " <> T.pack (show e)
    Right allowed -> do
      result <- try @SomeException
                  (_nh_httpPost (_tch_network tc) allowed body)
      case result of
        Left e ->
          _lh_logError (_tch_log tc) $
            "BotFather setMyCommands failed: " <> T.pack (show e)
        Right resp
          | _hr_statusCode resp == 200 ->
              _lh_logInfo (_tch_log tc)
                "BotFather setMyCommands registered tab commands"
          | otherwise ->
              _lh_logError (_tch_log tc) $
                "BotFather setMyCommands HTTP "
                  <> T.pack (show (_hr_statusCode resp))
