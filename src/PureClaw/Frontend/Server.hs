module PureClaw.Frontend.Server
  ( -- * Server
    runFrontend
    -- * Configuration
  , FrontendConfig (..)
  , defaultFrontendConfig
    -- * Re-export environment
  , FrontendEnv (..)
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types
import Network.Socket (SockAddr)
import Network.Wai
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)

import PureClaw.Frontend.API
import PureClaw.Frontend.Stream (streamApp)
import PureClaw.Handles.Log (LogHandle(..))

-- | Frontend server configuration.
data FrontendConfig = FrontendConfig
  { _fsc_port         :: Int
  , _fsc_staticDir    :: FilePath
  , _fc_allowedOrigins :: [Text]
    -- ^ Exact-match allowlist of @Origin@ headers permitted to upgrade to
    -- the WS endpoint. Matching is case-insensitive on scheme + host per
    -- RFC 6454 (see "PureClaw.Frontend.Stream.normalizeOrigin"). An empty
    -- list denies every origin (the deny-all configuration). The default
    -- admits @http://localhost:8080@ and @http://127.0.0.1:8080@.
  }
  deriving stock (Show, Eq)

-- | Default: port 8080, serving from @frontend\/dist@, accepting WS
-- upgrades from @http://localhost:8080@ and @http://127.0.0.1:8080@.
defaultFrontendConfig :: FrontendConfig
defaultFrontendConfig = FrontendConfig
  { _fsc_port          = 8080
  , _fsc_staticDir     = "frontend/dist"
  , _fc_allowedOrigins = [ "http://localhost:8080"
                          , "http://127.0.0.1:8080"
                          ]
  }

-- | Start the frontend server with API endpoints and static file serving.
-- API routes (@\/api\/*@) are handled by 'apiApp'; the WS endpoint at
-- @\/api\/stream@ is composed via 'WaiWS.websocketsOr' from 'streamApp';
-- everything else falls through to the static file server with SPA
-- fallback.
--
-- Warp hardening (D20): an accept-side connection counter caps concurrent
-- HTTP connections at 1024 (Warp 3.4 dropped the dedicated
-- @setMaxTotalConnections@ helper; the same effect is achieved via
-- @setOnOpen@/@setOnClose@ with a TVar gate). @setTimeout 30@ closes
-- idle non-WS HTTP routes after 30 s. The timeout does NOT apply to
-- hijacked WS sockets — those use 'Network.WebSockets.withPingThread'
-- for keepalive (per the design's §Security and 'SECURITY_PRACTICES.md'
-- §9.1).
runFrontend :: FrontendConfig -> Maybe FrontendEnv -> LogHandle -> IO ()
runFrontend cfg mEnv logger = do
  let logInfo = _lh_logInfo logger
  logInfo "PureClaw frontend server"
  logInfo $ "  Serving: " <> T.pack (_fsc_staticDir cfg)
  logInfo $ "  URL:     http://localhost:" <> T.pack (show (_fsc_port cfg))
  counterTv <- newTVarIO 0
  let cap = 1024 :: Int
      settings = Warp.setPort (_fsc_port cfg)
               $ Warp.setTimeout 30
               $ Warp.setOnOpen  (onOpenCounter counterTv cap)
               $ Warp.setOnClose (onCloseCounter counterTv)
                 Warp.defaultSettings
  Warp.runSettings settings (combinedApp cfg mEnv (_fsc_staticDir cfg))

-- | Connection-open callback. Blocks (via STM @retry@) when the active
-- count reaches the cap so Warp pauses 'accept' until a slot opens up.
-- Returning 'True' admits the connection; 'False' would reject it (we
-- never reject — we throttle by blocking).
onOpenCounter :: TVar Int -> Int -> SockAddr -> IO Bool
onOpenCounter tv cap _addr = do
  atomically $ do
    n <- readTVar tv
    if n >= cap then retry else modifyTVar' tv (+ 1)
  pure True

-- | Connection-close callback. Decrement the counter.
onCloseCounter :: TVar Int -> SockAddr -> IO ()
onCloseCounter tv _addr = atomically $ modifyTVar' tv (subtract 1)

-- | Combined WAI application: WS upgrade (@\/api\/stream@) is composed via
-- 'WaiWS.websocketsOr' so that a single 'Application' handles both the WS
-- upgrade and the JSON HTTP routes. Non-API paths fall through to
-- 'staticApp'.
combinedApp :: FrontendConfig -> Maybe FrontendEnv -> FilePath -> Application
combinedApp cfg mEnv staticDir = WaiWS.websocketsOr
  WS.defaultConnectionOptions
  (case mEnv of
     Just env -> streamApp (_fc_allowedOrigins cfg) env
     Nothing  -> rejectStreaming)
  apiOrStatic
  where
    apiOrStatic req respond = case pathInfo req of
      ("api" : _) -> case mEnv of
        Just env -> apiApp env req respond
        Nothing  -> respond $ responseLBS status503
          [(hContentType, "application/json")]
          "{\"error\":\"API not available in standalone serve mode\"}"
      _ -> staticApp staticDir req respond

    rejectStreaming :: WS.ServerApp
    rejectStreaming pending =
      WS.rejectRequestWith pending
        (WS.defaultRejectRequest
          { WS.rejectCode    = 503
          , WS.rejectMessage = "streaming disabled"
          , WS.rejectBody    = "streaming disabled"
          })

-- | WAI application that serves static files with SPA fallback.
staticApp :: FilePath -> Application
staticApp dir req respond = do
  let segments = pathInfo req
  -- Reject path traversal
  if any (\s -> s == ".." || s == ".") segments
    then respond $ responseLBS status400 [] "Invalid path"
    else do
      let relPath  = T.unpack (T.intercalate "/" segments)
          filePath = dir </> if null relPath then "index.html" else relPath
      exists <- doesFileExist filePath
      if exists
        then serveFile filePath respond
        else do
          -- SPA fallback: serve index.html for client-side routing
          let indexPath = dir </> "index.html"
          indexExists <- doesFileExist indexPath
          if indexExists
            then serveFile indexPath respond
            else respond $ responseLBS status404 [] "Not found"

serveFile :: FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveFile path respond = do
  contents <- LBS.readFile path
  let ct = mimeType (takeExtension path)
  respond $ responseLBS status200 [(hContentType, ct)] contents

-- | Map file extensions to MIME types.
mimeType :: String -> BS.ByteString
mimeType ".html"  = "text/html; charset=utf-8"
mimeType ".js"    = "application/javascript"
mimeType ".css"   = "text/css"
mimeType ".svg"   = "image/svg+xml"
mimeType ".json"  = "application/json"
mimeType ".png"   = "image/png"
mimeType ".jpg"   = "image/jpeg"
mimeType ".jpeg"  = "image/jpeg"
mimeType ".ico"   = "image/x-icon"
mimeType ".woff"  = "font/woff"
mimeType ".woff2" = "font/woff2"
mimeType ".map"   = "application/json"
mimeType _        = "application/octet-stream"
