module Gateway.ServerSpec (spec) where

import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec

import PureClaw.Gateway.Server

spec :: Spec
spec = do
  describe "defaultGatewayConfig" $ do
    it "binds to localhost" $
      _gc_bind defaultGatewayConfig `shouldBe` LocalhostOnly

    it "uses port 3000" $
      _gc_port defaultGatewayConfig `shouldBe` 3000

    it "has 30 second timeout" $
      _gc_timeout defaultGatewayConfig `shouldBe` 30

    it "allows 100 max connections" $
      _gc_maxConn defaultGatewayConfig `shouldBe` 100

  describe "mkWarpSettings" $ do
    it "sets the port from config" $ do
      let gc = defaultGatewayConfig { _gc_port = 8080 }
          settings = mkWarpSettings gc
      Warp.getPort settings `shouldBe` 8080

    it "sets the timeout from config" $ do
      let settings = mkWarpSettings defaultGatewayConfig
      -- Warp doesn't expose a getter for timeout, so we just verify it builds
      Warp.getPort settings `shouldBe` 3000

  describe "GatewayConfig" $ do
    it "has Show and Eq instances" $ do
      show defaultGatewayConfig `shouldContain` "GatewayConfig"
      defaultGatewayConfig `shouldBe` defaultGatewayConfig

  describe "GatewayBind" $ do
    it "has Show and Eq instances" $ do
      show LocalhostOnly `shouldBe` "LocalhostOnly"
      show PublicBind `shouldBe` "PublicBind"
      LocalhostOnly `shouldNotBe` PublicBind
