module PureClaw.Handles.Channel
  ( -- * Message types
    IncomingMessage (..)
  , OutgoingMessage (..)
    -- * Streaming
  , StreamChunk (..)
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
newtype OutgoingMessage = OutgoingMessage
  { _om_content :: Text
  }
  deriving stock (Show, Eq)

-- | A chunk of streamed text from the provider.
data StreamChunk
  = ChunkText Text    -- ^ Partial text content
  | ChunkDone         -- ^ Stream finished
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
  , _ch_sendChunk :: StreamChunk -> IO ()
  }

-- | No-op channel handle. Receive returns an empty message, send and
-- sendError are silent.
mkNoOpChannelHandle :: ChannelHandle
mkNoOpChannelHandle = ChannelHandle
  { _ch_receive   = pure (IncomingMessage (UserId "") "")
  , _ch_send      = \_ -> pure ()
  , _ch_sendError = \_ -> pure ()
  , _ch_sendChunk = \_ -> pure ()
  }
