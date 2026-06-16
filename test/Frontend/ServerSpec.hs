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
    it "binds loopback by default" $ do
      let settings = mkFrontendSettings defaultFrontendConfig
      Warp.getHost settings `shouldBe` "127.0.0.1"

    it "honors a configured non-loopback bind host" $ do
      let cfg = defaultFrontendConfig { _fsc_bindHost = "0.0.0.0" }
          settings = mkFrontendSettings cfg
      Warp.getHost settings `shouldBe` "0.0.0.0"

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

    it "falls back to localhost origin at the configured port when no Origin header is sent" $ do
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

    it "echoes an allowed request Origin header" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      let cfg  = defaultFrontendConfig
          inner _req respond =
            respond $ Wai.responseLBS HTTP.status200 [] "ok"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest
            { Wai.requestHeaders = [("Origin", "http://127.0.0.1:8080")] }
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      lookup "Access-Control-Allow-Origin" (respHeaders resp)
        `shouldBe` Just "http://127.0.0.1:8080"

    it "ignores a disallowed request Origin header (falls back)" $ do
      ref <- newIORef (Nothing :: Maybe Wai.Response)
      let cfg  = defaultFrontendConfig
          inner _req respond =
            respond $ Wai.responseLBS HTTP.status200 [] "ok"
          app  = corsMiddleware cfg inner
          req  = Wai.defaultRequest
            { Wai.requestHeaders = [("Origin", "http://evil.example.com")] }
          capture resp = do
            writeIORef ref (Just resp)
            pure ResponseReceived
      _ <- app req capture
      Just resp <- readIORef ref
      lookup "Access-Control-Allow-Origin" (respHeaders resp)
        `shouldBe` Just "http://localhost:8080"

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

    it "binds loopback (127.0.0.1) by default" $
      _fsc_bindHost defaultFrontendConfig `shouldBe` "127.0.0.1"

    it "has static dir frontend/dist" $
      _fsc_staticDir defaultFrontendConfig `shouldBe` "frontend/dist"

  describe "isLoopbackHost" $ do
    it "treats 127.0.0.1 as loopback" $
      isLoopbackHost "127.0.0.1" `shouldBe` True

    it "treats localhost as loopback" $
      isLoopbackHost "localhost" `shouldBe` True

    it "treats ::1 as loopback" $
      isLoopbackHost "::1" `shouldBe` True

    it "treats [::1] as loopback" $
      isLoopbackHost "[::1]" `shouldBe` True

    it "treats 0.0.0.0 as non-loopback" $
      isLoopbackHost "0.0.0.0" `shouldBe` False

    it "treats a LAN address as non-loopback" $
      isLoopbackHost "192.168.1.5" `shouldBe` False

    it "matches a hostname case-insensitively" $
      isLoopbackHost "Localhost" `shouldBe` True

  describe "corsAllowedOrigin" $ do
    it "echoes an allowed origin (default localhost)" $
      corsAllowedOrigin defaultFrontendConfig (Just "http://localhost:8080")
        `shouldBe` "http://localhost:8080"

    it "echoes an allowed origin (default 127.0.0.1)" $
      corsAllowedOrigin defaultFrontendConfig (Just "http://127.0.0.1:8080")
        `shouldBe` "http://127.0.0.1:8080"

    it "falls back to localhost for an unknown origin (loopback bind)" $
      corsAllowedOrigin defaultFrontendConfig (Just "http://evil.example.com")
        `shouldBe` "http://localhost:8080"

    it "falls back to localhost when no origin is supplied (loopback bind)" $
      corsAllowedOrigin defaultFrontendConfig Nothing
        `shouldBe` "http://localhost:8080"

    it "allows a configured non-loopback bind host's own origin" $
      let cfg = defaultFrontendConfig { _fsc_bindHost = "192.168.1.5" }
      in corsAllowedOrigin cfg (Just "http://192.168.1.5:8080")
           `shouldBe` "http://192.168.1.5:8080"

    it "falls back to the bound-host origin for a non-loopback bind" $
      let cfg = defaultFrontendConfig { _fsc_bindHost = "192.168.1.5" }
      in corsAllowedOrigin cfg (Just "http://evil.example.com")
           `shouldBe` "http://192.168.1.5:8080"

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
