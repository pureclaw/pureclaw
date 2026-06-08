-- | Durable harness identity registry (Harness Registry & Lifecycle, Phase 1).
--
-- This is the source of truth for harness identity and health. A harness is
-- keyed by a PureClaw-assigned 'HarnessId' (a UUID), NOT by its mutable tmux
-- window name (which the user can rename) — see @docs\/harness-registry.md@ §3.
--
-- The registry itself is a 'TVar' (STM) because a background reconcile loop
-- performs compound read-modify-write concurrently with HTTP\/slash handlers
-- (design decision K2b). The critical invariant is that 'mergeReconcile' merges
-- tmux-observed fields into existing entries /by key/ inside a single
-- 'atomically', recomputing from the CURRENT 'TVar' contents — so an entry
-- inserted by another transaction between a naive read and write is never
-- clobbered (the lost-update-safe path, §4).
--
-- Leaf module: it may import 'PureClaw.Handles.Harness' (for 'HarnessHandle')
-- and standard libraries only — never @Agent@\/@Frontend@\/@CLI@.
module PureClaw.Harness.Registry
  ( -- * Identity
    HarnessId
  , newHarnessId
  , parseHarnessId
  , harnessIdToText
    -- * Entry types
  , HarnessOrigin (..)
  , Liveness (..)
  , HarnessEntry (..)
    -- * The registry
  , HarnessRegistry (..)
  , newRegistry
    -- * CRUD
  , insertEntry
  , lookupById
  , lookupByLabel
  , deleteEntry
  , modifyEntry
  , snapshot
    -- * Reconciliation
  , ObservedHarness (..)
  , mergeReconcile
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUIDv4

import PureClaw.Handles.Harness (HarnessHandle)

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- | A PureClaw-assigned, UUID-backed harness identity. This is the canonical
-- key for the registry and the durable anchor that survives tmux window
-- rename\/move and PureClaw restart (persisted in @session.json@).
newtype HarnessId = HarnessId { unHarnessId :: UUID }
  deriving stock (Eq, Ord, Show)

-- | Generate a fresh random 'HarnessId' (UUID v4).
newHarnessId :: IO HarnessId
newHarnessId = HarnessId <$> UUIDv4.nextRandom

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

-- ---------------------------------------------------------------------------
-- Entry types
-- ---------------------------------------------------------------------------

-- | How PureClaw came to manage this harness.
--
-- Phase 1 produces 'OriginSpawned' (we launched it) and 'OriginDiscovered'
-- (boot-reconstructed from a window carrying our @\@pcl_id@). 'OriginAdopted'
-- (an external window we took over) is defined here but exercised in Phase 3.
data HarnessOrigin
  = OriginSpawned
  | OriginDiscovered
  | OriginAdopted
  deriving stock (Eq, Show)

-- | Liveness of a harness (design §5 / decision K7).
--
-- Note that @ExternallyModified@ and @Unknown@ are intentionally NOT liveness
-- states: the former is the orthogonal '_he_extModified' flag, and the latter
-- maps to the '_he_stale' flag (hold last-known liveness).
data Liveness
  = LivenessIdle      -- ^ Window present, harness running, not actively working.
  | LivenessThinking  -- ^ Harness actively working (screen-capture heuristic).
  | LivenessExited    -- ^ Harness PID gone or @pane_dead@, window still present.
  | LivenessOrphaned  -- ^ No live window+PID for this id.
  deriving stock (Eq, Show)

-- | A registry entry: the durable identity plus the reconciled health\/coordinate
-- cache (design §4). The cached @(session, windowName)@ coordinate lets handles
-- target tmux without a per-I\/O @\@pcl_id@ sweep; the reconcile loop is the sole
-- owner that refreshes it.
--
-- Note: '_he_handle' is a 'HarnessHandle', which is a record of @IO@ actions and
-- therefore has no 'Eq'\/'Show'. Consequently 'HarnessEntry' does NOT derive
-- 'Eq'\/'Show'; tests assert via field projections instead.
data HarnessEntry = HarnessEntry
  { _he_id          :: !HarnessId
    -- ^ Canonical identity (the map key).
  , _he_session     :: !Text
    -- ^ Cached tmux session name (coordinate; revalidated by reconcile, K3).
  , _he_windowName  :: !Text
    -- ^ Cached tmux window name (coordinate; revalidated by reconcile, K3).
  , _he_shellPid    :: !(Maybe Int)
    -- ^ Recorded pane shell PID (@#{pane_pid}@) — provenance + liveness.
  , _he_harnessPid  :: !(Maybe Int)
    -- ^ Recorded harness-process PID (the agent binary) — trust anchor.
  , _he_origin      :: !HarnessOrigin
    -- ^ How PureClaw came to manage this harness.
  , _he_liveness    :: !Liveness
    -- ^ Current reconciled liveness.
  , _he_extModified :: !Bool
    -- ^ Orthogonal flag: a matched window's name\/session changed out-of-band.
  , _he_stale       :: !Bool
    -- ^ The last sweep\/capture failed; hold last-known liveness, don't repaint.
  , _he_sessionId   :: !(Maybe Text)
    -- ^ The PureClaw session this harness backs (the join to @session.json@).
  , _he_label       :: !Text
    -- ^ Legacy window-name label, used for name->id resolution ('lookupByLabel').
  , _he_orphanedTicks :: !Int
    -- ^ Consecutive reconcile ticks this entry has been classified Orphaned.
    --   0 whenever the entry is live (Idle\/Thinking\/Exited); the reconcile
    --   loop increments it each tick the corroborated window stays absent and
    --   auto-evicts the entry once it reaches 'PureClaw.Harness.Reconcile.defaultOrphanGraceTicks'
    --   (the wall-clock-free grace policy, design §5\/§10 Q2). Eviction drops
    --   the entry from the registry + the legacy harness map but never touches
    --   @session.json@ (the session reappears in Recent Sessions).
  , _he_handle      :: !(Maybe HarnessHandle)
    -- ^ The live handle, if we have one. 'Nothing' for a boot-discovered entry
    --   that has not yet had a handle attached.
  }

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The durable harness registry: a strict 'Map' from 'HarnessId' to
-- 'HarnessEntry', held in a 'TVar' for safe concurrent read-modify-write.
newtype HarnessRegistry = HarnessRegistry
  { unHarnessRegistry :: TVar (Map HarnessId HarnessEntry) }

-- | Create a new, empty registry.
newRegistry :: IO HarnessRegistry
newRegistry = HarnessRegistry <$> newTVarIO Map.empty

-- ---------------------------------------------------------------------------
-- CRUD
-- ---------------------------------------------------------------------------

-- | Insert (or overwrite) an entry by its 'HarnessId'.
insertEntry :: HarnessRegistry -> HarnessEntry -> IO ()
insertEntry reg e =
  atomically (modifyTVar' (unHarnessRegistry reg) (Map.insert (_he_id e) e))

-- | Look up an entry by its canonical id.
lookupById :: HarnessRegistry -> HarnessId -> IO (Maybe HarnessEntry)
lookupById reg hid =
  atomically (Map.lookup hid <$> readTVar (unHarnessRegistry reg))

-- | Resolve an entry by its label (legacy window-name). Returns the first
-- match (label is not guaranteed unique on a shared server; the canonical key
-- is the id). Used by name->id resolution for legacy\/CLI routing surfaces.
lookupByLabel :: HarnessRegistry -> Text -> IO (Maybe HarnessEntry)
lookupByLabel reg lbl = do
  m <- readTVarIO (unHarnessRegistry reg)
  pure (firstMatch (Map.elems m))
  where
    firstMatch []       = Nothing
    firstMatch (e : es)
      | _he_label e == lbl = Just e
      | otherwise          = firstMatch es

-- | Remove an entry by id (no-op if absent).
deleteEntry :: HarnessRegistry -> HarnessId -> IO ()
deleteEntry reg hid =
  atomically (modifyTVar' (unHarnessRegistry reg) (Map.delete hid))

-- | Apply a pure function to the entry with the given id, in-place, as a
-- SINGLE-STM read-modify-write (no-op if the id is absent). This is the
-- race-safe way to flip a flag on one entry (e.g. clearing '_he_extModified'
-- for Acknowledge): unlike a 'lookupById' followed by 'insertEntry' — two
-- separate transactions — the whole adjust commits atomically, so a concurrent
-- 'mergeReconcile' tick cannot interleave and clobber the change (a lost
-- update). 'Map.adjust' touches only the named key, leaving every other entry
-- intact.
modifyEntry :: HarnessRegistry -> HarnessId -> (HarnessEntry -> HarnessEntry) -> IO ()
modifyEntry reg hid f =
  atomically (modifyTVar' (unHarnessRegistry reg) (Map.adjust f hid))

-- | Snapshot all current entries.
snapshot :: HarnessRegistry -> IO [HarnessEntry]
snapshot reg =
  atomically (Map.elems <$> readTVar (unHarnessRegistry reg))

-- ---------------------------------------------------------------------------
-- Reconciliation
-- ---------------------------------------------------------------------------

-- | The tmux-observed fields the reconcile loop merges into an existing entry,
-- keyed by 'HarnessId'. This is deliberately a small projection of
-- 'HarnessEntry' — it carries only what a server sweep observes, never the
-- handle or the durable provenance/origin, which the registry owns.
data ObservedHarness = ObservedHarness
  { _oh_id          :: !HarnessId
  , _oh_session     :: !Text
  , _oh_windowName  :: !Text
  , _oh_shellPid    :: !(Maybe Int)
  , _oh_harnessPid  :: !(Maybe Int)
  , _oh_liveness    :: !Liveness
  , _oh_extModified :: !Bool
  , _oh_stale       :: !Bool
  , _oh_orphanedTicks :: !Int
    -- ^ The entry's new consecutive-orphaned-tick count for this observation:
    --   @old + 1@ when classified Orphaned, @0@ when live. Rides the
    --   'mergeReconcile' path so the counter lives durably on the entry.
  }
  deriving stock (Eq, Show)

-- | Merge tmux-observed fields into existing entries BY KEY, inside a single
-- 'atomically'. This is the lost-update-safe reconcile path (design §4):
--
--   * The new map is computed from the CURRENT 'TVar' contents inside the
--     transaction, so a concurrent insert that landed before this transaction
--     commits is preserved.
--   * Only keys present in the observed set are updated; every other key
--     (including newly-inserted ones) is left intact.
--   * An observed row whose id is NOT already in the registry is ignored — an
--     observation alone never resurrects\/creates an entry (registration is the
--     caller's job; this defends against, e.g., a spoofed marker).
mergeReconcile :: HarnessRegistry -> [ObservedHarness] -> IO ()
mergeReconcile reg observed =
  atomically (modifyTVar' (unHarnessRegistry reg) merge)
  where
    obsMap :: Map HarnessId ObservedHarness
    obsMap = Map.fromList [ (_oh_id o, o) | o <- observed ]

    -- Map over the CURRENT contents, updating only keys we observed and
    -- leaving all others (incl. concurrently-inserted) untouched.
    merge :: Map HarnessId HarnessEntry -> Map HarnessId HarnessEntry
    merge = Map.mapWithKey applyObserved

    applyObserved :: HarnessId -> HarnessEntry -> HarnessEntry
    applyObserved hid e =
      case Map.lookup hid obsMap of
        Nothing -> e
        Just o  -> e
          { _he_session     = _oh_session o
          , _he_windowName  = _oh_windowName o
          , _he_shellPid    = _oh_shellPid o
          , _he_harnessPid  = _oh_harnessPid o
          , _he_liveness    = _oh_liveness o
          , _he_extModified = _oh_extModified o
          , _he_stale       = _oh_stale o
          , _he_orphanedTicks = _oh_orphanedTicks o
          }
