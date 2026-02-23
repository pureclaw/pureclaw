module PureClaw.Core.Errors
  ( -- * Public errors (safe to send to channel users)
    PublicError (..)
    -- * Conversion typeclass
  , ToPublicError (..)
  ) where

import Data.Text (Text)

-- | Errors safe to send to external users via channels.
-- Contains no internal detail — model names, URLs, stack traces, etc.
-- are stripped by 'ToPublicError' instances on internal error types.
data PublicError
  = TemporaryError Text   -- ^ Generic temporary error with user-facing message
  | RateLimitError        -- ^ Rate limit reached
  | NotAllowedError       -- ^ User not authorized
  deriving stock (Show, Eq)

-- | Convert internal errors to channel-safe public errors.
-- Implementations must strip all internal detail.
class ToPublicError e where
  toPublicError :: e -> PublicError
