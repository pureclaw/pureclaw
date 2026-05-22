module PureClaw.Frontend.Server
  ( -- * Server
    runFrontend
    -- * Configuration
  , FrontendConfig (..)
  , defaultFrontendConfig
    -- * Warp settings
  , mkFrontendSettings
    -- * Middleware
  , corsMiddleware
    -- * Re-export environment
  , FrontendEnv (..)
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Network.HTTP.Types qualified as HTTP
import Network.Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)

import PureClaw.Frontend.API
import PureClaw.Handles.Log

-- | Frontend server configuration.
data FrontendConfig = FrontendConfig
  { _fsc_port      :: Int
  , _fsc_staticDir :: FilePath
  }
  deriving stock (Show, Eq)

-- | Default: port 8080, serving from @frontend\/dist@.
defaultFrontendConfig :: FrontendConfig
defaultFrontendConfig = FrontendConfig
  { _fsc_port      = 8080
  , _fsc_staticDir = "frontend/dist"
  }

-- | Build Warp settings from the frontend config.
-- Binds to all interfaces; CORS middleware restricts allowed origins
-- to @http:\/\/localhost:\<port\>@.
mkFrontendSettings :: FrontendConfig -> Warp.Settings
mkFrontendSettings cfg =
  Warp.setPort (_fsc_port cfg)
    Warp.defaultSettings

-- | CORS middleware that restricts the @Access-Control-Allow-Origin@
-- header to @http:\/\/localhost:\<port\>@ and handles OPTIONS preflight
-- requests with a 200 response.
corsMiddleware :: FrontendConfig -> Middleware
corsMiddleware cfg app req respond
  | requestMethod req == "OPTIONS" =
      respond $ responseLBS HTTP.status200 corsHeaders ""
  | otherwise =
      app req $ \resp ->
        respond (mapResponseHeaders (corsHeaders ++) resp)
  where
    origin :: BS.ByteString
    origin = "http://localhost:" <> BS8.pack (show (_fsc_port cfg))

    corsHeaders :: [HTTP.Header]
    corsHeaders =
      [ ("Access-Control-Allow-Origin",  origin)
      , ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
      , ("Access-Control-Allow-Headers", "Content-Type")
      ]

-- | Start the frontend server with API endpoints and static file serving.
-- API routes (@\/api\/*@) are handled by 'apiApp'; everything else
-- falls through to the static file server with SPA fallback.
-- Binds to 127.0.0.1 and applies CORS middleware.
runFrontend :: FrontendConfig -> Maybe FrontendEnv -> LogHandle -> IO ()
runFrontend cfg mEnv logger = do
  let logInfo = _lh_logInfo logger
  logInfo "PureClaw frontend server"
  logInfo $ "  Serving: " <> T.pack (_fsc_staticDir cfg)
  logInfo $ "  URL:     http://localhost:" <> T.pack (show (_fsc_port cfg))
  let settings = mkFrontendSettings cfg
      app = corsMiddleware cfg (combinedApp mEnv (_fsc_staticDir cfg))
  Warp.runSettings settings app

-- | Combined WAI application: API routes first, then static files.
combinedApp :: Maybe FrontendEnv -> FilePath -> Application
combinedApp mEnv staticDir req respond =
  case pathInfo req of
    ("api" : _) -> case mEnv of
      Just env -> apiApp env req respond
      Nothing  -> respond $ responseLBS HTTP.status503
        [(HTTP.hContentType, "application/json")]
        "{\"error\":\"API not available in standalone serve mode\"}"
    _ -> staticApp staticDir req respond

-- | WAI application that serves static files with SPA fallback.
staticApp :: FilePath -> Application
staticApp dir req respond = do
  let segments = pathInfo req
  -- Reject path traversal
  if any (\s -> s == ".." || s == ".") segments
    then respond $ responseLBS HTTP.status400 [] "Invalid path"
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
            else respond $ responseLBS HTTP.status404 [] "Not found"

serveFile :: FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveFile path respond = do
  contents <- LBS.readFile path
  let ct = mimeType (takeExtension path)
  respond $ responseLBS HTTP.status200 [(HTTP.hContentType, ct)] contents

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
