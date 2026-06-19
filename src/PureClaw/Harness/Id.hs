-- | Leaf module for 'HarnessId' — a UUID-backed harness identity.
--
-- This module exists purely to break the import cycle between
-- 'PureClaw.Harness.Registry' (which defines 'HarnessEntry' and may import
-- 'PureClaw.Session.Kind') and 'PureClaw.Session.Kind' (which embeds
-- 'HarnessId' in 'HarnessSpec'). By isolating 'HarnessId' here, both modules
-- can import this leaf without creating a cycle.
--
-- Depends ONLY on @uuid@, @text@, @aeson@, and @base@. Never imports any
-- project module.
module PureClaw.Harness.Id
  ( -- * Identity
    HarnessId (..)
  , parseHarnessId
  , harnessIdToText
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.UUID (UUID)
import Data.UUID qualified as UUID

-- | A PureClaw-assigned, UUID-backed harness identity. This is the canonical
-- key for the registry and the durable anchor that survives tmux window
-- rename\/move and PureClaw restart (persisted in @session.json@).
newtype HarnessId = HarnessId { unHarnessId :: UUID }
  deriving stock (Eq, Ord, Show)

-- | Parse a 'HarnessId' from its canonical UUID text representation.
-- Returns 'Nothing' for any non-UUID input.
parseHarnessId :: Text -> Maybe HarnessId
parseHarnessId = fmap HarnessId . UUID.fromText

-- | Render a 'HarnessId' as its canonical UUID text representation.
harnessIdToText :: HarnessId -> Text
harnessIdToText = UUID.toText . unHarnessId

-- | Round-trippable JSON: a 'HarnessId' is encoded as the canonical UUID
-- string (D2.4). We hand-write the codec rather than @deriving newtype@ so the
-- on-the-wire shape (a plain string) is explicit and decode rejects malformed
-- UUIDs with a clear error.
instance ToJSON HarnessId where
  toJSON = Aeson.String . harnessIdToText

instance FromJSON HarnessId where
  parseJSON = Aeson.withText "HarnessId" $ \t ->
    case parseHarnessId t of
      Just hid -> pure hid
      Nothing  -> fail ("invalid HarnessId (not a UUID): " <> show t)
