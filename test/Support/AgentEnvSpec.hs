module Support.AgentEnvSpec (spec) where

import Test.Hspec
import Data.IORef (readIORef)
import Data.Maybe (isNothing)
import PureClaw.Agent.Env (AgentEnv (..))
import Support.AgentEnv (mkTestAgentEnv)

spec :: Spec
spec = describe "mkTestAgentEnv" $
  it "builds a usable test AgentEnv" $ do
    -- 'SomeProvider' has no 'Show' instance, so reduce to a 'Bool' with
    -- 'isNothing' before asserting (both @shouldBe Nothing@ and
    -- @shouldSatisfy@ would otherwise demand a 'Show' instance).
    env <- mkTestAgentEnv
    prov <- readIORef (_env_provider env)
    isNothing prov `shouldBe` True
