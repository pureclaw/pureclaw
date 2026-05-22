module Frontend.ServerSpec (spec) where

import Data.IORef
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

import PureClaw.Frontend.Server

spec :: Spec
spec = do
  describe "mkFrontendSettings" $ do
    it "uses default host (all interfaces)" $ do
      let settings = mkFrontendSettings defaultFrontendConfig
      Warp.getHost settings `shouldBe` "*4"

    it "uses the configured port" $ do
      let cfg = defaultFrontendConfig { _fsc_port = 9090 }
          settings = mkFrontendSettings cfg
      Warp.getPort settings `shouldBe` 9090

    it "uses default port 8080" $ do
      let settings = mkFrontendSettings defaultFrontendConfig
      Warp.getPort settings `shouldBe` 8080

  describe "corsMiddleware" $ do
    it "sets CORS headers on normal responses" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      let cfg  = defaultFrontendConfig
          inner _req respond =
            respond $ Wai.responseLBS HTTP.status200 [] "ok"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      let hdrs = respHeaders resp
      lookup "Access-Control-Allow-Origin" hdrs
        `shouldBe` Just "http://localhost:8080"
      lookup "Access-Control-Allow-Methods" hdrs
        `shouldBe` Just "GET, POST, PUT, DELETE, OPTIONS"
      lookup "Access-Control-Allow-Headers" hdrs
        `shouldBe` Just "Content-Type"
      respStatus resp `shouldBe` HTTP.status200

    it "responds 200 to OPTIONS preflight requests" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      let cfg  = defaultFrontendConfig
          inner _req respond =
            respond $ Wai.responseLBS HTTP.status200 [] "should not reach"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest { Wai.requestMethod = "OPTIONS" }
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      respStatus resp `shouldBe` HTTP.status200
      let hdrs = respHeaders resp
      lookup "Access-Control-Allow-Origin" hdrs
        `shouldBe` Just "http://localhost:8080"
      lookup "Access-Control-Allow-Methods" hdrs
        `shouldBe` Just "GET, POST, PUT, DELETE, OPTIONS"
      lookup "Access-Control-Allow-Headers" hdrs
        `shouldBe` Just "Content-Type"

    it "uses the configured port in the origin" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      let cfg  = defaultFrontendConfig { _fsc_port = 3456 }
          inner _req respond =
            respond $ Wai.responseLBS HTTP.status200 [] "ok"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      let hdrs = respHeaders resp
      lookup "Access-Control-Allow-Origin" hdrs
        `shouldBe` Just "http://localhost:3456"

    it "does not call the inner app for OPTIONS" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      innerCalled <- newIORef False
      let cfg  = defaultFrontendConfig
          inner _req _respond = do
            writeIORef innerCalled True
            error "inner app should not be called for OPTIONS"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest { Wai.requestMethod = "OPTIONS" }
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      respStatus resp `shouldBe` HTTP.status200
      called <- readIORef innerCalled
      called `shouldBe` False

  describe "defaultFrontendConfig" $ do
    it "has port 8080" $
      _fsc_port defaultFrontendConfig `shouldBe` 8080

    it "has static dir frontend/dist" $
      _fsc_staticDir defaultFrontendConfig `shouldBe` "frontend/dist"

-- | Extract response status from a Response.
respStatus :: Wai.Response -> HTTP.Status
respStatus resp =
  let (st, _, _) = Wai.responseToStream resp
  in st

-- | Extract response headers from a Response.
respHeaders :: Wai.Response -> [HTTP.Header]
respHeaders resp =
  let (_, hdrs, _) = Wai.responseToStream resp
  in hdrs
