-- |
-- Module      : Routing.DepthLimitSpec
-- Description : Tests for HPureClaw recursion depth limiting (WU-9).
--
-- Covers the 'SpawnError' type, 'checkPureClawDepth' pure guard, the
-- new 'RoutingConfig' fields ('_rc_maxPureClawDepth', '_rc_pureClawDepth'),
-- and the '--depth' CLI flag.
module Routing.DepthLimitSpec (spec) where

import Test.Hspec

import PureClaw.Routing.Config
import PureClaw.Routing.Types

spec :: Spec
spec = do
  describe "defaultRoutingConfig depth fields" $ do
    it "has _rc_maxPureClawDepth == 2" $ do
      _rc_maxPureClawDepth defaultRoutingConfig `shouldBe` 2

    it "has _rc_pureClawDepth == 0" $ do
      _rc_pureClawDepth defaultRoutingConfig `shouldBe` 0

  describe "checkPureClawDepth" $ do
    it "allows depth 0 with max 2" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 0
              , _rc_maxPureClawDepth = 2
              }
      checkPureClawDepth cfg `shouldBe` Right ()

    it "allows depth 1 with max 2" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 1
              , _rc_maxPureClawDepth = 2
              }
      checkPureClawDepth cfg `shouldBe` Right ()

    it "rejects depth 2 with max 2" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 2
              , _rc_maxPureClawDepth = 2
              }
      checkPureClawDepth cfg `shouldBe` Left (MaxPureClawDepthExceeded 2 2)

    it "rejects depth 3 with max 2" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 3
              , _rc_maxPureClawDepth = 2
              }
      checkPureClawDepth cfg `shouldBe` Left (MaxPureClawDepthExceeded 3 2)

    it "allows depth 0 with max 1" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 0
              , _rc_maxPureClawDepth = 1
              }
      checkPureClawDepth cfg `shouldBe` Right ()

    it "rejects depth 1 with max 1" $ do
      let cfg = defaultRoutingConfig
              { _rc_pureClawDepth = 1
              , _rc_maxPureClawDepth = 1
              }
      checkPureClawDepth cfg `shouldBe` Left (MaxPureClawDepthExceeded 1 1)

  describe "SpawnError" $ do
    it "has a Show instance" $ do
      show (MaxPureClawDepthExceeded 2 2)
        `shouldBe` "MaxPureClawDepthExceeded 2 2"

    it "has an Eq instance" $ do
      MaxPureClawDepthExceeded 2 2 `shouldBe` MaxPureClawDepthExceeded 2 2
      MaxPureClawDepthExceeded 1 2 `shouldNotBe` MaxPureClawDepthExceeded 2 2

  -- NOTE: Vault non-propagation (S8) — the factory code that sets
  -- _env_vault = Nothing on child AgentEnv records will be enforced
  -- in WU-10 (tab factory arms). This WU establishes the depth-check
  -- infrastructure that the factory will use before spawning.
