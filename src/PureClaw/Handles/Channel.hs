module PureClaw.Handles.Channel
  ( -- * Message types
    IncomingMessage (..)
  , OutgoingMessage (..)
    -- * Handle type
  , ChannelHandle (..)
    -- * Implementations
  , mkNoOpChannelHandle
  ) where

import Data.Text (Text)

import PureClaw.Core.Errors
import PureClaw.Core.Types

-- | A message received from a channel user.
data IncomingMessage = IncomingMessage
  { _im_userId  :: UserId
  , _im_content :: Text
  }
  deriving stock (Show, Eq)

-- | A message to send to a channel user.
data OutgoingMessage = OutgoingMessage
  { _om_content :: Text
  }
  deriving stock (Show, Eq)

-- | Channel communication capability interface. Concrete implementations
-- (CLI, Telegram, Signal) live in @PureClaw.Channels.*@ modules.
--
-- 'sendError' only accepts 'PublicError' — internal errors with stack
-- traces or model names cannot be sent to channel users. This is enforced
-- at the type level.
data ChannelHandle = ChannelHandle
  { _ch_receive   :: IO IncomingMessage
  , _ch_send      :: OutgoingMessage -> IO ()
  , _ch_sendError :: PublicError -> IO ()
  }

-- | No-op channel handle. Receive returns an empty message, send and
-- sendError are silent.
mkNoOpChannelHandle :: ChannelHandle
mkNoOpChannelHandle = ChannelHandle
  { _ch_receive   = pure (IncomingMessage (UserId "") "")
  , _ch_send      = \_ -> pure ()
  , _ch_sendError = \_ -> pure ()
  }
