module PureClaw.Channels.Class
  ( -- * Channel typeclass
    Channel (..)
    -- * Existential wrapper
  , SomeChannel (..)
  , someChannelHandle
  ) where

import PureClaw.Handles.Channel

-- | Typeclass for channel implementations. Each channel knows how to
-- receive messages from users and send responses back. The 'toHandle'
-- method converts any channel into the uniform 'ChannelHandle' used
-- by the agent loop.
class Channel c where
  -- | Convert this channel into a 'ChannelHandle'.
  toHandle :: c -> ChannelHandle

-- | Existential wrapper for runtime channel selection (e.g. from config).
-- Use 'someChannelHandle' to extract the 'ChannelHandle'.
data SomeChannel where
  MkChannel :: Channel c => c -> SomeChannel

-- | Extract a 'ChannelHandle' from a 'SomeChannel'.
someChannelHandle :: SomeChannel -> ChannelHandle
someChannelHandle (MkChannel c) = toHandle c
