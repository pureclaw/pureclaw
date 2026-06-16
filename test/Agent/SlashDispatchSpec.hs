module Agent.SlashDispatchSpec (spec) where

import Test.Hspec

import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Agent.SlashCommands (SlashCommand (..))
import PureClaw.Agent.SlashDispatch
import PureClaw.Handles.Channel (mkCaptureChannelHandle)
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Types qualified as RT
import Support.AgentEnv (mkTestAgentEnv)

scopedCapture :: AgentEnv -> IO (AgentEnv, IO Text)
scopedCapture base = do
  (h, readOut) <- mkCaptureChannelHandle
  pure (base { _env_channel = h }, readOut)

spec :: Spec
spec = classifyInputSpec >> runSlashInputSpec >> deferralMessageSpec

classifyInputSpec :: Spec
classifyInputSpec = describe "classifyInput" $ do
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

  it "renders empty input distinctly" $
    case classifyInput rc "" of
      ClassMessage m -> T.unpack m `shouldContain` "Empty"
      other          -> expectationFailure ("expected ClassMessage, got " <> show other)

  it "renders an out-of-range tab index distinctly" $
    -- index 5 exceeds a reduced tab cap, so parseInput yields
    -- ParseErrorIndexOutOfRange (defaultRoutingConfig's cap is 36).
    let rcSmall = rc { RT._rc_maxTabs = 1 }
     in case classifyInput rcSmall "/5" of
          ClassMessage m -> T.unpack m `shouldContain` "doesn't exist"
          other          -> expectationFailure ("expected ClassMessage, got " <> show other)

runSlashInputSpec :: Spec
runSlashInputSpec = describe "runSlashInput" $ do
  it "passes ordinary chat through without building a scoped env" $ do
    env <- mkTestAgentEnv
    res <- runSlashInput env (error "mkScoped must not be called for passthrough") "hello there"
    res `shouldBe` SlashPassThrough "hello there"

  it "returns the captured output of a command" $ do
    env <- mkTestAgentEnv
    res <- runSlashInput env (scopedCapture env) "/help"
    case res of
      SlashHandled out -> out `shouldSatisfy` (not . T.null)
      _                -> expectationFailure "expected SlashHandled"

  it "short-circuits Switch/Inject without building a scoped env" $ do
    env <- mkTestAgentEnv
    res <- runSlashInput env (error "mkScoped must not be called for Switch") "/0"
    case res of
      SlashHandled _ -> pure ()
      _              -> expectationFailure "expected SlashHandled"

  it "converts InteractiveUnsupported into a deferral incl. buffered output" $ do
    env <- mkTestAgentEnv
    res <- runSlashInput env (scopedCapture env) "/vault setup"
    case res of
      SlashHandled out -> do
        T.unpack out `shouldContain` "interactive"
        T.unpack out `shouldContain` "/issues/"
        -- The buffered menu (sent before the interactive prompt) must be
        -- preserved ahead of the deferral note, so a regression that drops
        -- `buffered` from the deferral fails here.
        T.unpack out `shouldContain` "Choose your vault authentication method:"
      _ -> expectationFailure "expected SlashHandled deferral"

deferralMessageSpec :: Spec
deferralMessageSpec = describe "deferralMessage" $ do
  it "is the note alone when there is no buffered output" $ do
    let m = deferralMessage CmdHelp ""
    T.unpack m `shouldContain` "interactive"
    T.unpack m `shouldContain` "/issues/"
    -- No buffered prefix: the message starts with the note itself.
    T.unpack m `shouldStartWith` "This command needs interactive input"

  it "prepends buffered output before the note" $ do
    let m = deferralMessage CmdHelp "BUFFERED"
    T.unpack m `shouldContain` "BUFFERED\n"
    T.unpack m `shouldContain` "interactive"
    T.unpack m `shouldStartWith` "BUFFERED"
