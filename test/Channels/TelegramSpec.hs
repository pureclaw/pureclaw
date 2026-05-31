module Channels.TelegramSpec (spec) where

import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import PureClaw.Channels.Class
import PureClaw.Channels.Telegram
import PureClaw.Core.Errors
import PureClaw.Core.Types
import PureClaw.Handles.Channel
import PureClaw.Handles.Log
import PureClaw.Handles.Network

spec :: Spec
spec = do
  describe "TelegramConfig" $ do
    it "has Show and Eq instances" $ do
      let cfg = TelegramConfig "tok" "https://api.telegram.org" AllowAll
      show cfg `shouldContain` "TelegramConfig"
      cfg `shouldBe` cfg

  describe "mkTelegramChannel" $ do
    it "creates a channel that can receive pushed updates" $ do
      tc <- mkTestTelegramChannel
      let update = mkTestUpdate 1 42 "Alice" 100 "private" "Hello"
      atomically $ writeTQueue (_tch_inbox tc) update
      let h = toHandle tc
      msg <- _ch_receive h
      _im_content msg `shouldBe` "Hello"

    it "extracts user id from the update" $ do
      tc <- mkTestTelegramChannel
      let update = mkTestUpdate 1 99 "Bob" 100 "private" "Hi"
      atomically $ writeTQueue (_tch_inbox tc) update
      msg <- _ch_receive (toHandle tc)
      imUserId msg `shouldBe` UserId "99"
      _ms_channel (_im_source msg) `shouldBe` CkTelegram
      Map.lookup "chat_id" (_ms_fields (_im_source msg))
        `shouldBe` Just (toJSON (100 :: Int))

  describe "parseTelegramUpdate" $ do
    it "parses a valid update JSON" $ do
      let json = object
            [ "update_id" .= (1 :: Int)
            , "message" .= object
                [ "message_id" .= (10 :: Int)
                , "from" .= object ["id" .= (42 :: Int), "first_name" .= ("Alice" :: String)]
                , "chat" .= object ["id" .= (100 :: Int), "type" .= ("private" :: String)]
                , "text" .= ("Hello" :: String)
                ]
            ]
      case parseTelegramUpdate json of
        Left err -> expectationFailure err
        Right upd -> do
          _tu_updateId upd `shouldBe` 1
          _tm_text (_tu_message upd) `shouldBe` "Hello"
          _tu_id (_tm_from (_tu_message upd)) `shouldBe` 42

    it "rejects invalid JSON" $ do
      let json = object ["wrong" .= ("field" :: String)]
      parseTelegramUpdate json `shouldSatisfy` isLeft

  describe "TelegramUpdate" $ do
    it "has Show and Eq instances" $ do
      let upd = mkTestUpdate 1 42 "Alice" 100 "private" "hi"
      show upd `shouldContain` "TelegramUpdate"
      upd `shouldBe` upd

  describe "TelegramMessage" $ do
    it "has Show and Eq instances" $ do
      let msg = TelegramMessage 1 (TelegramUser 42 "Alice") (TelegramChat 100 "private") "hi"
      show msg `shouldContain` "TelegramMessage"
      msg `shouldBe` msg

  describe "send and sendError" $ do
    it "send without prior receive logs warning (no chat_id)" $ do
      tc <- mkTestTelegramChannel
      let h = toHandle tc
      _ch_send h (OutgoingMessage "test") `shouldReturn` ()

    it "sendError without prior receive logs warning" $ do
      tc <- mkTestTelegramChannel
      let h = toHandle tc
      _ch_sendError h (TemporaryError "oops") `shouldReturn` ()

    it "send after receive POSTs to Telegram API" $ do
      postRef <- newIORef (Nothing :: Maybe (Text, ByteString))
      let nh = mkNoOpNetworkHandle
            { _nh_httpPost = \url body -> do
                writeIORef postRef (Just (getAllowedUrl url, body))
                pure HttpResponse { _hr_statusCode = 200, _hr_body = "{}" }
            }
      tc <- mkTelegramChannel (TelegramConfig "test-token" "https://api.telegram.org" AllowAll) nh mkNoOpLogHandle
      let update = mkTestUpdate 1 42 "Alice" 100 "private" "Hello"
      atomically $ writeTQueue (_tch_inbox tc) update
      let h = toHandle tc
      _ <- _ch_receive h
      _ch_send h (OutgoingMessage "reply text")
      posted <- readIORef postRef
      case posted of
        Nothing -> expectationFailure "expected POST call"
        Just (url, body) -> do
          T.unpack url `shouldContain` "/bot"
          T.unpack url `shouldContain` "test-token"
          T.unpack url `shouldContain` "sendMessage"
          T.unpack (TE.decodeUtf8 body) `shouldContain` "chat_id="
          T.unpack (TE.decodeUtf8 body) `shouldContain` "text="

    it "sendError after receive POSTs error message" $ do
      postRef <- newIORef (Nothing :: Maybe (Text, ByteString))
      let nh = mkNoOpNetworkHandle
            { _nh_httpPost = \url body -> do
                writeIORef postRef (Just (getAllowedUrl url, body))
                pure HttpResponse { _hr_statusCode = 200, _hr_body = "{}" }
            }
      tc <- mkTelegramChannel (TelegramConfig "tok" "https://api.telegram.org" AllowAll) nh mkNoOpLogHandle
      let update = mkTestUpdate 1 42 "Bob" 200 "private" "hi"
      atomically $ writeTQueue (_tch_inbox tc) update
      let h = toHandle tc
      _ <- _ch_receive h
      _ch_sendError h RateLimitError
      posted <- readIORef postRef
      case posted of
        Nothing -> expectationFailure "expected POST call"
        Just (_, body) ->
          T.unpack (TE.decodeUtf8 body) `shouldContain` "text="

    it "readSecret throws IOError (vault requires CLI)" $ do
      tc <- mkTestTelegramChannel
      let h = toHandle tc
      result <- try @IOError (_ch_readSecret h)
      result `shouldSatisfy` isLeft

  describe "botFatherCommands / registerBotFatherCommands (Tabbed Chat O3)" $ do
    it "botFatherCommands re-exports the Onboarding list verbatim" $ do
      length botFatherCommands `shouldBe` 39   -- 10 digits + 26 letters + /tab + /tabs + /start

    it "encodeBotFatherCommands strips the leading '/' from each \
       \command word (Telegram setMyCommands API requirement)" $ do
      let payload = encodeBotFatherCommands botFatherCommands
          decoded = T.unpack (TE.decodeUtf8 payload)
      decoded `shouldContain` "\"command\":\"0\""
      decoded `shouldContain` "\"command\":\"start\""
      decoded `shouldNotContain` "\"command\":\"/"

    it "registerBotFatherCommands POSTs the encoded list to \
       \setMyCommands at the Bot API base URL" $ do
      postRef <- newIORef (Nothing :: Maybe (Text, ByteString))
      let nh = mkNoOpNetworkHandle
            { _nh_httpPost = \url body -> do
                writeIORef postRef (Just (getAllowedUrl url, body))
                pure HttpResponse { _hr_statusCode = 200, _hr_body = "{}" }
            }
      tc <- mkTelegramChannel
              (TelegramConfig "tok" "https://api.telegram.org" AllowAll)
              nh mkNoOpLogHandle
      registerBotFatherCommands tc
      posted <- readIORef postRef
      case posted of
        Nothing -> expectationFailure "expected setMyCommands POST"
        Just (url, body) -> do
          T.unpack url `shouldContain` "/bot"
          T.unpack url `shouldContain` "tok"
          T.unpack url `shouldContain` "setMyCommands"
          T.unpack (TE.decodeUtf8 body) `shouldContain` "commands"
          T.unpack (TE.decodeUtf8 body) `shouldContain` "start"

    it "registerBotFatherCommands tolerates a non-200 response \
       \(BotFather autocomplete is best-effort, not a boot blocker)" $ do
      tc <- mkTelegramChannel
              (TelegramConfig "tok" "https://api.telegram.org" AllowAll)
              ( mkNoOpNetworkHandle
                  { _nh_httpPost = \_ _ ->
                      pure HttpResponse
                        { _hr_statusCode = 500
                        , _hr_body       = "boom"
                        }
                  }
              )
              mkNoOpLogHandle
      registerBotFatherCommands tc `shouldReturn` ()

    it "registerBotFatherCommands tolerates a network exception \
       \(handler does not propagate)" $ do
      tc <- mkTelegramChannel
              (TelegramConfig "tok" "https://api.telegram.org" AllowAll)
              ( mkNoOpNetworkHandle
                  { _nh_httpPost = \_ _ ->
                      throwIO (userError "network down")
                  }
              )
              mkNoOpLogHandle
      registerBotFatherCommands tc `shouldReturn` ()

  describe "receiveUpdate allow-list enforcement" $ do
    it "returns the message when the sender's user id is allowed" $ do
      tc <- mkAllowListChannel (AllowList (Set.fromList [UserId "42"])) mkNoOpLogHandle
      enqueueUpdate tc (mkTestUpdate 1 42 "Alice" 100 "private" "Hello")
      msg <- receiveUpdate tc
      _im_content msg `shouldBe` "Hello"
      imUserId msg `shouldBe` UserId "42"

    it "returns the message when the chat id is allowed (user id is not)" $ do
      tc <- mkAllowListChannel (AllowList (Set.fromList [UserId "100"])) mkNoOpLogHandle
      enqueueUpdate tc (mkTestUpdate 1 999 "Stranger" 100 "private" "Hello")
      msg <- receiveUpdate tc
      _im_content msg `shouldBe` "Hello"
      imUserId msg `shouldBe` UserId "999"

    it "drops+logs an unauthorized update then returns the next authorized one" $ do
      logRef <- newIORef []
      tc <- mkAllowListChannel (AllowList (Set.fromList [UserId "42"]))
                               (mkRecordingLogHandle logRef)
      enqueueUpdate tc (mkTestUpdate 1 7 "Mallory" 7 "private" "blocked")
      enqueueUpdate tc (mkTestUpdate 2 42 "Alice" 100 "private" "allowed")
      msg <- receiveUpdate tc
      _im_content msg `shouldBe` "allowed"
      imUserId msg `shouldBe` UserId "42"
      logged <- readIORef logRef
      T.unlines logged `shouldSatisfy` T.isInfixOf "unauthorized sender"

    it "does not update lastChat when an update is blocked" $ do
      tc <- mkAllowListChannel (AllowList (Set.fromList [UserId "42"])) mkNoOpLogHandle
      enqueueUpdate tc (mkTestUpdate 1 7 "Mallory" 7 "private" "blocked")
      enqueueUpdate tc (mkTestUpdate 2 42 "Alice" 42 "private" "allowed")
      _ <- receiveUpdate tc
      lastChat <- readIORef (_tch_lastChat tc)
      lastChat `shouldBe` Just 42

    it "passes everyone through when the policy is AllowAll" $ do
      tc <- mkAllowListChannel AllowAll mkNoOpLogHandle
      enqueueUpdate tc (mkTestUpdate 1 12345 "Anyone" 6789 "private" "hi")
      msg <- receiveUpdate tc
      _im_content msg `shouldBe` "hi"

  describe "withTelegramChannel open-allow-list warning" $ do
    it "warns (WARN log) when the allow-list is open" $ do
      logRef <- newIORef []
      withTelegramChannel
        (TelegramConfig "tok" "https://api.telegram.org" AllowAll)
        mkNoOpNetworkHandle
        (mkRecordingLogHandle logRef)
        (\_ -> pure ())
      logged <- readIORef logRef
      T.unlines logged `shouldSatisfy` T.isInfixOf "no allow-list configured"

    it "is silent (no WARN log) when the allow-list is closed" $ do
      logRef <- newIORef []
      withTelegramChannel
        (TelegramConfig "tok" "https://api.telegram.org"
          (AllowList (Set.fromList [UserId "1"])))
        mkNoOpNetworkHandle
        (mkRecordingLogHandle logRef)
        (\_ -> pure ())
      logged <- readIORef logRef
      logged `shouldBe` []

-- Helpers

mkTestTelegramChannel :: IO TelegramChannel
mkTestTelegramChannel =
  mkTelegramChannel (TelegramConfig "test-token" "https://api.telegram.org" AllowAll) mkNoOpNetworkHandle mkNoOpLogHandle

mkTestUpdate :: Int -> Int -> Text -> Int -> Text -> Text -> TelegramUpdate
mkTestUpdate updId userId firstName chatId chatType txt =
  TelegramUpdate updId (TelegramMessage 1 (TelegramUser userId firstName) (TelegramChat chatId chatType) txt)

-- | Build a Telegram channel with a given allow-list policy and log handle.
mkAllowListChannel :: AllowList UserId -> LogHandle -> IO TelegramChannel
mkAllowListChannel policy =
  mkTelegramChannel
    (TelegramConfig "test-token" "https://api.telegram.org" policy)
    mkNoOpNetworkHandle

-- | Enqueue an update directly into a channel's inbox.
enqueueUpdate :: TelegramChannel -> TelegramUpdate -> IO ()
enqueueUpdate tc update = atomically $ writeTQueue (_tch_inbox tc) update

-- | A 'LogHandle' that records WARN messages into an 'IORef'; other levels
-- are no-ops.
mkRecordingLogHandle :: IORef [Text] -> LogHandle
mkRecordingLogHandle ref =
  LogHandle
    { _lh_logInfo  = \_ -> pure ()
    , _lh_logWarn  = \msg -> modifyIORef' ref (++ [msg])
    , _lh_logError = \_ -> pure ()
    , _lh_logDebug = \_ -> pure ()
    }
