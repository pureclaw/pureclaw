module PureClaw.Gateway.Server
  ( -- * Server
    runGateway
    -- * Configuration
  , GatewayConfig (..)
  , GatewayBind (..)
  , defaultGatewayConfig
    -- * Warp settings
  , mkWarpSettings
  ) where

import Data.Text qualified as T
import Network.Wai.Handler.Warp qualified as Warp

import PureClaw.Gateway.Routes
import PureClaw.Handles.Log
import PureClaw.Security.Pairing

-- | How the gateway binds to the network.
data GatewayBind
  = LocalhostOnly
  | PublicBind
  deriving stock (Show, Eq)

-- | Gateway configuration.
data GatewayConfig = GatewayConfig
  { _gc_port    :: Int
  , _gc_bind    :: GatewayBind
  , _gc_timeout :: Int
  , _gc_maxConn :: Int
  }
  deriving stock (Show, Eq)

-- | Secure defaults: localhost-only, port 3000, 30s timeout, 100 connections.
defaultGatewayConfig :: GatewayConfig
defaultGatewayConfig = GatewayConfig
  { _gc_port    = 3000
  , _gc_bind    = LocalhostOnly
  , _gc_timeout = 30
  , _gc_maxConn = 100
  }

-- | Build Warp settings from our gateway config.
mkWarpSettings :: GatewayConfig -> Warp.Settings
mkWarpSettings gc =
  Warp.setPort (_gc_port gc)
  $ Warp.setTimeout (_gc_timeout gc)
  $ Warp.setHost (bindHost (_gc_bind gc))
    Warp.defaultSettings

bindHost :: GatewayBind -> Warp.HostPreference
bindHost LocalhostOnly = "127.0.0.1"
bindHost PublicBind     = "*"

-- | Start the gateway HTTP server.
runGateway :: GatewayConfig -> PairingState -> LogHandle -> IO ()
runGateway gc ps lh = do
  case _gc_bind gc of
    PublicBind -> _lh_logWarn lh "Gateway bound to 0.0.0.0 — ensure tunnel is in use"
    LocalhostOnly -> pure ()
  _lh_logInfo lh $ "Gateway starting on port " <> T.pack (show (_gc_port gc))
  let settings = mkWarpSettings gc
      app = mkApp ps lh
  Warp.runSettings settings app
