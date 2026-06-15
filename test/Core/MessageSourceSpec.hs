module Core.MessageSourceSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Channels.CLI (cliConversationId)
import PureClaw.Channels.Signal
  ( SignalDataMessage (..)
  , SignalEnvelope (..)
  , conversationIdForSignal
  )
import PureClaw.Channels.Telegram
  ( TelegramChat (..)
  , TelegramMessage (..)
  , TelegramUser (..)
  , conversationIdForTelegram
  )
import PureClaw.Core.Types
import PureClaw.Handles.Channel (noopConversationId)

-- | Build a Telegram message from a sender user id and a chat id so the
-- derivation tests can vary the two independently.
mkTgMessage :: Int -> Int -> TelegramMessage
mkTgMessage senderId chatId = TelegramMessage
  { _tm_messageId = 1
  , _tm_from      = TelegramUser { _tu_id = senderId, _tu_firstName = "tester" }
  , _tm_chat      = TelegramChat { _tcht_id = chatId, _tcht_type = "group" }
  , _tm_text      = "hello"
  }

-- | Build a Signal envelope from a peer/source identifier.
mkSignalEnvelope :: T.Text -> SignalEnvelope
mkSignalEnvelope src = SignalEnvelope
  { _se_source      = src
  , _se_sourceUuid  = Nothing
  , _se_timestamp   = Just 0
  , _se_dataMessage = Just (SignalDataMessage { _sdm_message = "hi", _sdm_timestamp = 0 })
  }

spec :: Spec
spec = do
  describe "mkMessageSource conversation provenance" $ do
    it "uses the transport-supplied ConversationId, ignoring any body field" $ do
      -- A forged "conversation_id" inside the field map must NOT override the
      -- server-derived id that is passed as the positional argument.
      let forged = Map.fromList
            [ ("conversation_id", Aeson.String "attacker-controlled") ]
          src = mkMessageSource CkCli (ConversationId "trusted") Nothing forged
      _ms_conversation src `shouldBe` ConversationId "trusted"

    it "normalizes (strips control chars) but otherwise preserves the id arg" $ do
      let src = mkMessageSource CkTelegram (ConversationId "12345") Nothing Map.empty
      _ms_conversation src `shouldBe` ConversationId "12345"

  describe "per-channel ConversationId derivation" $ do
    it "CLI derives the constant \"cli\" conversation id" $
      cliConversationId `shouldBe` ConversationId "cli"

    it "the noop handle derives the constant \"noop\" conversation id" $
      noopConversationId `shouldBe` ConversationId "noop"

    it "Telegram derives the id from the CHAT id, not the sender user id" $ do
      -- Sender 999 in chat 42 -> conversation id "42" (the chat), never "999".
      let msg = mkTgMessage 999 42
      conversationIdForTelegram msg `shouldBe` ConversationId "42"
      conversationIdForTelegram msg `shouldNotBe` ConversationId "999"

    it "Signal derives the id from the conversation/peer source" $ do
      let env = mkSignalEnvelope "+15551234567"
      conversationIdForSignal env `shouldBe` ConversationId "+15551234567"

  describe "group-chat shared cursor (Telegram)" $ do
    it "two senders in the same chat produce the SAME ConversationKey" $ do
      let alice = mkTgMessage 111 42   -- sender 111, chat 42
          bob   = mkTgMessage 222 42   -- sender 222, SAME chat 42
          keyOf m = (CkTelegram, conversationIdForTelegram m)
      keyOf alice `shouldBe` keyOf bob
      keyOf alice `shouldBe` (CkTelegram, ConversationId "42")

    it "senders in DIFFERENT chats produce DIFFERENT conversation ids" $ do
      let inChat42 = mkTgMessage 111 42
          inChat43 = mkTgMessage 111 43
      conversationIdForTelegram inChat42
        `shouldNotBe` conversationIdForTelegram inChat43
