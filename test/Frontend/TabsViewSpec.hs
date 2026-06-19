-- |
-- Module      : Frontend.TabsViewSpec
-- Description : WU3-FE — pure tabSnapshotsFromRegistry branch matrix.
--
-- Tests the 'tabSnapshotsFromRegistry' projection over its full branch matrix
-- using only injected pure lookups (no IO). Covers:
--
--   1. BoundSession (Live) → provider\/idle, sessionId, no origin\/attach.
--   2. BoundSession with Dead status → exited.
--   3. BoundHarness + present HarnessEntry (LivenessThinking) → harness, running,
--      origin pill, attach command, sessionId from entry.
--   4. BoundHarness + present HarnessEntry (LivenessExited) → harness, exited.
--   5. BoundHarness + vanished entry (Nothing) → exited\/stale.
--   6. No-secret-leak: structural guarantee — projection takes only TabList +
--      harness lookup; no session metadata can appear in a TabSnapshot.
--   7. Empty TabList → empty result.
--   8. Multi-tab slot order preserved.
module Frontend.TabsViewSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Tabs.Types
  ( TabRef (..)
  , appendTab
  , emptyTabs
  , setStatus
  )
import PureClaw.Tabs.Types qualified as TabsTypes

import PureClaw.Frontend.TabsView
  ( TabSnapshot (..)
  , livenessToTabStatus
  , tabSnapshotsFromRegistry
  )

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Force-parse a 'Registry.HarnessId' from canonical UUID text (test-only).
mustParseHid :: Text -> Registry.HarnessId
mustParseHid t = case Registry.parseHarnessId t of
  Just h  -> h
  Nothing -> error ("mustParseHid: not a UUID: " <> T.unpack t)

hid1 :: Registry.HarnessId
hid1 = mustParseHid "11111111-1111-4111-8111-111111111111"

hid2 :: Registry.HarnessId
hid2 = mustParseHid "22222222-2222-4222-8222-222222222222"

sid1 :: SessionId
sid1 = SessionId "session-abc"

-- | A minimal 'HarnessEntry' for testing: no IO handle, idle liveness, spawned
-- origin, no pids, no sessionId, extModified\/stale both False.
mkEntry :: Registry.HarnessId -> Text -> Registry.HarnessEntry
mkEntry hid label = Registry.HarnessEntry
  { Registry._he_id            = hid
  , Registry._he_session       = "pureclaw"
  , Registry._he_windowName    = label
  , Registry._he_shellPid      = Nothing
  , Registry._he_harnessPid    = Nothing
  , Registry._he_origin        = Registry.OriginSpawned
  , Registry._he_liveness      = Registry.LivenessIdle
  , Registry._he_extModified   = False
  , Registry._he_stale         = False
  , Registry._he_sessionId     = Nothing
  , Registry._he_label         = label
  , Registry._he_orphanedTicks = 0
  , Registry._he_handle        = Nothing
  }

-- | Build a 'TabList' with a single Live tab. Uses the exported 'appendTab'
-- pure operation; panics on error (only safe for unique refs in tests). Tabs
-- no longer carry a label of their own; the @_name@ argument is retained for
-- call-site readability and ignored.
singleLiveTab :: TabRef -> Text -> TabsTypes.TabList
singleLiveTab ref _name =
  case appendTab ref emptyTabs of
    Right (_, tl) -> tl
    Left  _       -> error "singleLiveTab: unexpected allocation error"

-- | Build a 'TabList' with a single Dead tab. Appends with Live status then
-- flips to Dead via the exported 'setStatus'.
singleDeadTab :: TabRef -> Text -> TabsTypes.TabList
singleDeadTab ref name =
  setStatus ref TabsTypes.Dead (singleLiveTab ref name)

-- | A no-op harness lookup (always Nothing).
noHarness :: Registry.HarnessId -> Maybe Registry.HarnessEntry
noHarness _ = Nothing

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "tabSnapshotsFromRegistry" $ do

    -- 1. BoundSession (Live) → provider/idle
    describe "BoundSession (Live)" $ do
      it "projects kind=provider, status=idle, sessionId set, no origin/attach" $ do
        let tl    = singleLiveTab (BoundSession sid1) "My Session"
            snaps = tabSnapshotsFromRegistry tl noHarness
        case snaps of
          [ts] -> do
            _ts_kind ts          `shouldBe` "provider"
            _ts_status ts        `shouldBe` "idle"
            _ts_sessionId ts     `shouldBe` Just "session-abc"
            _ts_origin ts        `shouldBe` ""
            _ts_attachCommand ts `shouldBe` Nothing
            _ts_index ts         `shouldBe` 0
            -- Provider tabs carry no label fallback; the title derives from the
            -- session (via _ts_sessionId) at the frontend.
            _ts_label ts         `shouldBe` Nothing
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 2. BoundSession with Dead status → exited
    describe "BoundSession (Dead)" $ do
      it "projects status=exited for a Dead provider tab" $ do
        let tl    = singleDeadTab (BoundSession sid1) "Dead Session"
            snaps = tabSnapshotsFromRegistry tl noHarness
        case snaps of
          [ts] -> _ts_status ts `shouldBe` "exited"
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 3. BoundHarness + present entry (LivenessThinking) → full harness projection
    describe "BoundHarness with present HarnessEntry (LivenessThinking)" $ do
      it "projects kind=harness, livenessToTabStatus, origin, attach command, sessionId" $ do
        let entry = (mkEntry hid1 "claude-code")
                      { Registry._he_liveness    = Registry.LivenessThinking
                      , Registry._he_session     = "pureclaw"
                      , Registry._he_windowName  = "claude-code"
                      , Registry._he_origin      = Registry.OriginDiscovered
                      , Registry._he_sessionId   = Just "sess-xyz"
                      , Registry._he_extModified = True
                      , Registry._he_stale       = False
                      }
            tl     = singleLiveTab (BoundHarness hid1) "claude-code"
            harnOf hid = if hid == hid1 then Just entry else Nothing
            snaps  = tabSnapshotsFromRegistry tl harnOf
        case snaps of
          [ts] -> do
            _ts_kind ts          `shouldBe` "harness"
            -- Harness tabs keep a label fallback (the registry entry's label)
            -- so they never render blank even when the session id is Nothing.
            _ts_label ts         `shouldBe` Just "claude-code"
            _ts_status ts        `shouldBe` livenessToTabStatus Registry.LivenessThinking
            _ts_status ts        `shouldBe` "running"
            _ts_origin ts        `shouldBe` "discovered"
            _ts_attachCommand ts `shouldBe` Just "tmux attach -t pureclaw:claude-code"
            _ts_sessionId ts     `shouldBe` Just "sess-xyz"
            _ts_extModified ts   `shouldBe` True
            _ts_stale ts         `shouldBe` False
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 4. BoundHarness + present entry (LivenessExited) → status exited
    describe "BoundHarness with present HarnessEntry (LivenessExited)" $ do
      it "projects status=exited for a LivenessExited harness entry" $ do
        let entry = (mkEntry hid1 "exited-harness")
                      { Registry._he_liveness = Registry.LivenessExited
                      }
            tl     = singleLiveTab (BoundHarness hid1) "exited-harness"
            harnOf hid = if hid == hid1 then Just entry else Nothing
            snaps  = tabSnapshotsFromRegistry tl harnOf
        case snaps of
          [ts] -> do
            _ts_kind ts   `shouldBe` "harness"
            _ts_status ts `shouldBe` "exited"
            _ts_stale ts  `shouldBe` False
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 5. BoundHarness with vanished entry → exited/stale
    describe "BoundHarness with vanished entry (lookup returns Nothing)" $ do
      it "projects status=exited, stale=True, no sessionId/origin/attach" $ do
        let tl    = singleLiveTab (BoundHarness hid2) "ghost-harness"
            snaps = tabSnapshotsFromRegistry tl noHarness
        case snaps of
          [ts] -> do
            _ts_kind ts          `shouldBe` "harness"
            _ts_status ts        `shouldBe` "exited"
            _ts_stale ts         `shouldBe` True
            _ts_sessionId ts     `shouldBe` Nothing
            -- No registry entry survives, so there is no label fallback either.
            _ts_label ts         `shouldBe` Nothing
            _ts_origin ts        `shouldBe` ""
            _ts_attachCommand ts `shouldBe` Nothing
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 6. No-secret-leak: structural guarantee
    describe "No-secret-leak" $ do
      it "carries no session metadata — projection takes only the TabList + harness lookup" $ do
        -- 'tabSnapshotsFromRegistry' takes NO session-meta input, so no
        -- session metadata (_sm_source, channelUserId, credentials) can
        -- possibly appear in a TabSnapshot by construction.  This test
        -- confirms the projected provider-tab fields are exactly the
        -- Tab-derived values: no label fallback (the title derives from the
        -- session), sid from the ref, kind "provider", status idle — nothing
        -- else.
        let tl    = singleLiveTab (BoundSession sid1) "Protected"
            snaps = tabSnapshotsFromRegistry tl noHarness
        case snaps of
          [ts] -> do
            _ts_kind ts          `shouldBe` "provider"
            _ts_label ts         `shouldBe` Nothing
            _ts_status ts        `shouldBe` "idle"
            _ts_sessionId ts     `shouldBe` Just "session-abc"
            _ts_origin ts        `shouldBe` ""
            _ts_attachCommand ts `shouldBe` Nothing
            _ts_extModified ts   `shouldBe` False
            _ts_stale ts         `shouldBe` False
          other -> expectationFailure ("expected 1 snapshot, got " <> show (length other))

    -- 7. Empty TabList → empty result
    describe "Empty TabList" $ do
      it "returns an empty list" $
        tabSnapshotsFromRegistry emptyTabs noHarness `shouldBe` []

    -- 8. Multi-tab slot order preserved
    describe "Multi-tab slot order" $ do
      it "snapshots are in slot order (index 0, 1)" $ do
        let tl0  = singleLiveTab (BoundSession sid1) "Tab0"
            tl   = case appendTab (BoundSession (SessionId "session-def")) tl0 of
                     Right (_, tl') -> tl'
                     Left  _        -> error "appendTab failed"
            snaps = tabSnapshotsFromRegistry tl noHarness
        case snaps of
          [t0, t1] -> do
            _ts_index t0 `shouldBe` 0
            _ts_index t1 `shouldBe` 1
          other -> expectationFailure ("expected 2 snapshots, got " <> show (length other))

  -- Task 3: livenessToTabStatus — LivenessAwaitingInput maps to "running"
  describe "livenessToTabStatus LivenessAwaitingInput" $ do
    it "maps LivenessAwaitingInput to \"running\" (state shown via activity dot, not tab badge)" $
      livenessToTabStatus Registry.LivenessAwaitingInput `shouldBe` "running"
