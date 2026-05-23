-- | Shared activity types used by the WS-streaming broker and the HTTP API.
--
-- Originally these types lived in "PureClaw.Frontend.API"; they were promoted
-- to this module so "PureClaw.Frontend.StreamBroker" can reference
-- 'HarnessActivity' without taking a dependency on the WAI/API layer.
--
-- "PureClaw.Frontend.API" re-exports 'HarnessActivity' for compatibility so
-- its public surface is unchanged.
module PureClaw.Frontend.Activity.Types
  ( HarnessActivity (..)
  ) where

import Data.Aeson qualified as Aeson
import Data.Aeson (ToJSON (..))

-- | Activity state of a harness, derived from tmux screen capture.
data HarnessActivity
  = HarnessThinking
  | HarnessIdle
  | HarnessStopped
  deriving stock (Show, Eq)

instance ToJSON HarnessActivity where
  toJSON HarnessThinking = Aeson.String "thinking"
  toJSON HarnessIdle     = Aeson.String "idle"
  toJSON HarnessStopped  = Aeson.String "stopped"
