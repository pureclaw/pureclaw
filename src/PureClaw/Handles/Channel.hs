module PureClaw.Handles.Channel
  ( -- * Message types
    IncomingMessage (..)
  , imUserId
  , OutgoingMessage (..)
    -- * Streaming
  , StreamChunk (..)
    -- * Handle type
  , ChannelHandle (..)
    -- * Implementations
  , mkNoOpChannelHandle
  , noopConversationId
  , mkCaptureChannelHandle
  , InteractiveUnsupported (..)
  , renderPublicError
  ) where

import Control.Exception (Exception, throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import PureClaw.Core.Errors
import PureClaw.Core.Types

-- | A message received from a channel user, tagged with the source that
-- describes where it came from (channel + optional user id + extensible
-- fields). The source is captured at the channel boundary via
-- 'mkMessageSource'.
data IncomingMessage = IncomingMessage
  { _im_source  :: MessageSource
  , _im_content :: Text
  }
  deriving stock (Show, Eq)

-- | Derive the channel user id from a message's source, preserving the
-- legacy '_im_userId' behavior. A source with no user id (@Nothing@)
-- yields the @UserId ""@ sentinel — the same value the no-op channel
-- produced before the 'MessageSource' migration — so dispatcher routing
-- against the allow-list is unchanged.
imUserId :: IncomingMessage -> UserId
imUserId m = fromMaybe (UserId "") (_ms_userId (_im_source m))

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
  { _ch_receive      :: IO IncomingMessage
  , _ch_send         :: OutgoingMessage -> IO ()
  , _ch_sendError    :: PublicError -> IO ()
  , _ch_sendChunk    :: StreamChunk -> IO ()
  , _ch_streaming    :: Bool
    -- ^ Whether this channel supports streaming output. When 'True',
    -- the agent loop sends text via '_ch_sendChunk' during generation
    -- and skips the full '_ch_send'. When 'False', only '_ch_send'
    -- is used for the final complete response.
  , _ch_readSecret   :: IO Text    -- ^ Read a line without echo (CLI only)
  , _ch_prompt       :: Text -> IO Text
    -- ^ Display a prompt and read input on the same line (no trailing
    -- newline after the prompt text). For non-interactive channels this
    -- falls back to send-then-receive.
  , _ch_promptSecret :: Text -> IO Text
    -- ^ Like '_ch_prompt' but with echo disabled (for passwords / API keys).
    -- For non-interactive channels this falls back to '_ch_readSecret'.
  }

-- | No-op channel handle. Receive returns an empty message, send and
-- sendError are silent. readSecret returns empty text.
mkNoOpChannelHandle :: ChannelHandle
mkNoOpChannelHandle = ChannelHandle
  { _ch_receive      = pure (IncomingMessage (mkMessageSource (CkOther "noop") noopConversationId Nothing mempty) "")
  , _ch_send         = \_ -> pure ()
  , _ch_sendError    = \_ -> pure ()
  , _ch_sendChunk    = \_ -> pure ()
  , _ch_streaming    = False
  , _ch_readSecret   = pure ""
  , _ch_prompt       = \_ -> pure ""
  , _ch_promptSecret = \_ -> pure ""
  }

-- | The conversation id for the no-op channel handle. A constant, since the
-- no-op handle has no real transport and never carries a routable
-- conversation.
noopConversationId :: ConversationId
noopConversationId = ConversationId "noop"

-- | Thrown when a slash command tries to read interactive input through a
-- capture channel (which has no interactive transport). Carries the prompt
-- label so the caller can report which command needs the CLI.
newtype InteractiveUnsupported = InteractiveUnsupported Text
  deriving stock (Show, Eq)

instance Exception InteractiveUnsupported

-- | Render a 'PublicError' to channel-safe display text (for buffering).
renderPublicError :: PublicError -> Text
renderPublicError (TemporaryError t) = t
renderPublicError RateLimitError     = "Rate limit reached."
renderPublicError NotAllowedError    = "Not authorized."

-- | A channel handle that buffers all output instead of writing to a
-- transport, and refuses interactive input. Returns the handle plus a reader
-- that yields the accumulated output (messages joined by newline).
mkCaptureChannelHandle :: IO (ChannelHandle, IO Text)
mkCaptureChannelHandle = do
  buf <- newIORef []  -- reversed list of emitted fragments
  let append t = modifyIORef' buf (t :)
      handle = ChannelHandle
        { _ch_receive      = throwIO (InteractiveUnsupported "(receive)")
        , _ch_send         = \(OutgoingMessage t) -> append t
        , _ch_sendError    = append . renderPublicError
        , _ch_sendChunk    = \case
            ChunkText t -> append t
            ChunkDone   -> pure ()
        , _ch_streaming    = False
        , _ch_readSecret   = throwIO (InteractiveUnsupported "(secret)")
        , _ch_prompt       = throwIO . InteractiveUnsupported
        , _ch_promptSecret = throwIO . InteractiveUnsupported
        }
      reader = T.intercalate "\n" . reverse <$> readIORef buf
  pure (handle, reader)
