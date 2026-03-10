module Channels.TelegramSpec (spec) where

import Control.Concurrent.STM
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.IORef
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
      let cfg = TelegramConfig "tok" "https://api.telegram.org"
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
      _im_userId msg `shouldBe` UserId "99"

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
      tc <- mkTelegramChannel (TelegramConfig "test-token" "https://api.telegram.org") nh mkNoOpLogHandle
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
      tc <- mkTelegramChannel (TelegramConfig "tok" "https://api.telegram.org") nh mkNoOpLogHandle
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

-- Helpers

mkTestTelegramChannel :: IO TelegramChannel
mkTestTelegramChannel =
  mkTelegramChannel (TelegramConfig "test-token" "https://api.telegram.org") mkNoOpNetworkHandle mkNoOpLogHandle

mkTestUpdate :: Int -> Int -> Text -> Int -> Text -> Text -> TelegramUpdate
mkTestUpdate updId userId firstName chatId chatType txt =
  TelegramUpdate updId (TelegramMessage 1 (TelegramUser userId firstName) (TelegramChat chatId chatType) txt)
