module Agent.SlashDispatchSpec (spec) where

import Test.Hspec

import Data.Text qualified as T

import PureClaw.Agent.SlashCommands (SlashCommand (..))
import PureClaw.Agent.SlashDispatch
import PureClaw.Routing.Config (defaultRoutingConfig)

spec :: Spec
spec = describe "classifyInput" $ do
  let rc = defaultRoutingConfig

  it "passes ordinary chat through" $
    classifyInput rc "write a function" `shouldBe` ClassPass "write a function"

  it "classifies a known command" $
    classifyInput rc "/help" `shouldBe` ClassCommand CmdHelp

  it "short-circuits bare /N (Switch) with a message, not a command" $
    case classifyInput rc "/0" of
      ClassMessage _ -> pure ()
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "short-circuits Inject (/N payload) with a message" $
    case classifyInput rc "/3 run tests" of
      ClassMessage _ -> pure ()
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "renders an unknown command as a friendly message" $
    case classifyInput rc "/foo" of
      ClassMessage m -> T.unpack m `shouldContain` "/foo"
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "renders an invalid /tab resume id distinctly" $
    case classifyInput rc "/tab resume not a valid id!!" of
      ClassMessage m -> T.unpack m `shouldContain` "session id"
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)
