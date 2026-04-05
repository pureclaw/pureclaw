module PureClaw.Handles.Harness
  ( -- * Types
    HarnessStatus (..)
  , HarnessHandle (..)
  , HarnessError (..)
    -- * Implementations
  , mkNoOpHarnessHandle
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import System.Exit

import PureClaw.Security.Command

-- | Status of a harness process.
data HarnessStatus
  = HarnessRunning
  | HarnessExited ExitCode
  deriving stock (Show, Eq)

-- | Errors that can occur during harness operations.
data HarnessError
  = HarnessNotAuthorized CommandError
  | HarnessBinaryNotFound Text
  | HarnessTmuxNotAvailable Text  -- ^ detail message (stderr from tmux, or "not found")
  deriving stock (Show, Eq)

-- | Capability handle for interacting with a harness (e.g. Claude Code in tmux).
data HarnessHandle = HarnessHandle
  { _hh_send    :: ByteString -> IO ()   -- ^ Write to harness input
  , _hh_receive :: IO ByteString         -- ^ Read harness output (scrollback capture)
  , _hh_name    :: Text                  -- ^ Human-readable name
  , _hh_session :: Text                  -- ^ tmux session name
  , _hh_status  :: IO HarnessStatus      -- ^ Check if running
  , _hh_stop    :: IO ()                 -- ^ Kill and cleanup
  }

-- | No-op harness handle for testing.
mkNoOpHarnessHandle :: HarnessHandle
mkNoOpHarnessHandle = HarnessHandle
  { _hh_send    = \_ -> pure ()
  , _hh_receive = pure ""
  , _hh_name    = ""
  , _hh_session = ""
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = pure ()
  }
