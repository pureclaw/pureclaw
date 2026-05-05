module PureClaw.Frontend.Server
  ( -- * Server
    runFrontend
    -- * Configuration
  , FrontendConfig (..)
  , defaultFrontendConfig
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeExtension)

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

-- | Start the frontend static file server.
runFrontend :: FrontendConfig -> IO ()
runFrontend cfg = do
  putStrLn "PureClaw frontend server"
  putStrLn $ "  Serving: " <> _fsc_staticDir cfg
  putStrLn $ "  URL:     http://localhost:" <> show (_fsc_port cfg)
  Warp.run (_fsc_port cfg) (staticApp (_fsc_staticDir cfg))

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
