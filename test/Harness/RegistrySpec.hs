module Harness.RegistrySpec (spec) where

import Control.Concurrent.STM (readTVarIO)
import Data.Aeson qualified as Aeson
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Test.Hspec

import PureClaw.Handles.Harness (mkNoOpHarnessHandle)
import PureClaw.Harness.Registry

-- | Deterministic test ids built from fixed UUID strings (no IO randomness),
-- so assertions are stable.
testId :: Text -> HarnessId
testId s = case parseHarnessId s of
  Just hid -> hid
  Nothing -> error ("testId: not a valid UUID: " ++ show s)

idA :: HarnessId
idA = testId "11111111-1111-1111-1111-111111111111"

idB :: HarnessId
idB = testId "22222222-2222-2222-2222-222222222222"

-- | A baseline entry; individual tests override fields as needed.
mkEntry :: HarnessId -> Text -> HarnessEntry
mkEntry hid lbl = HarnessEntry
  { _he_id          = hid
  , _he_session     = "pureclaw"
  , _he_windowName  = lbl
  , _he_shellPid    = Nothing
  , _he_harnessPid  = Nothing
  , _he_origin      = OriginSpawned
  , _he_liveness    = LivenessIdle
  , _he_extModified = False
  , _he_stale       = False
  , _he_sessionId   = Nothing
  , _he_label       = lbl
  , _he_orphanedTicks = 0
  , _he_handle      = Nothing
  }

spec :: Spec
spec = do
  -- D2.1 — CRUD + snapshot round-trip under STM.
  describe "CRUD + snapshot (D2.1)" $ do
    it "newRegistry starts empty" $ do
      reg <- newRegistry
      snap <- snapshot reg
      map _he_id snap `shouldBe` []

    it "insert then lookupById returns the entry" $ do
      reg <- newRegistry
      let e = mkEntry idA "claude-code-0"
      insertEntry reg e
      found <- lookupById reg idA
      (_he_id <$> found) `shouldBe` Just idA
      (_he_label <$> found) `shouldBe` Just "claude-code-0"

    it "lookupById returns Nothing for an unknown id" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "claude-code-0")
      found <- lookupById reg idB
      (_he_id <$> found) `shouldBe` Nothing

    it "snapshot returns all inserted entries" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "a")
      insertEntry reg (mkEntry idB "b")
      snap <- snapshot reg
      sort (map _he_id snap) `shouldBe` sort [idA, idB]

    it "deleteEntry removes the entry" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "a")
      insertEntry reg (mkEntry idB "b")
      deleteEntry reg idA
      gone <- lookupById reg idA
      stillThere <- lookupById reg idB
      (_he_id <$> gone) `shouldBe` Nothing
      (_he_id <$> stillThere) `shouldBe` Just idB

    it "insert overwrites an existing entry with the same id" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "old")
      insertEntry reg ((mkEntry idA "new") { _he_label = "new" })
      found <- lookupById reg idA
      (_he_label <$> found) `shouldBe` Just "new"

  -- D2.3 — label -> entry resolution.
  describe "lookupByLabel (D2.3)" $ do
    it "resolves an entry by its label" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "claude-code-0")
      insertEntry reg (mkEntry idB "claude-code-1")
      found <- lookupByLabel reg "claude-code-1"
      (_he_id <$> found) `shouldBe` Just idB

    it "returns Nothing for an unknown label" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "claude-code-0")
      found <- lookupByLabel reg "nope"
      (_he_id <$> found) `shouldBe` Nothing

  -- D2.2 — mergeReconcile is lost-update-safe: an entry inserted before the
  -- merge (representing a concurrent HTTP/slash insert that landed between a
  -- naive read and write) MUST survive a merge whose observed set names only a
  -- different entry, AND the named entry must reflect the merged fields.
  describe "mergeReconcile (D2.2 — no lost update)" $ do
    it "preserves a concurrently-inserted entry while merging another" $ do
      reg <- newRegistry
      -- A is present before the merge and is the target of the observed row.
      insertEntry reg (mkEntry idA "a")
      -- B simulates an entry inserted concurrently (after the loop computed its
      -- view of the world but before the merge transaction commits). Because
      -- mergeReconcile recomputes from the CURRENT TVar inside one atomically,
      -- B must not be clobbered.
      insertEntry reg (mkEntry idB "b")
      -- Observed set names ONLY A, with updated tmux-derived fields.
      let obsA = ObservedHarness
            { _oh_id          = idA
            , _oh_session     = "pureclaw"
            , _oh_windowName  = "a-renamed"
            , _oh_shellPid    = Just 4242
            , _oh_harnessPid  = Just 4243
            , _oh_liveness    = LivenessThinking
            , _oh_extModified = True
            , _oh_stale       = False
            , _oh_orphanedTicks = 0
            }
      mergeReconcile reg [obsA]
      -- B survives untouched (no lost update).
      foundB <- lookupById reg idB
      (_he_id <$> foundB) `shouldBe` Just idB
      (_he_label <$> foundB) `shouldBe` Just "b"
      -- A reflects the merged observed fields.
      foundA <- lookupById reg idA
      (_he_windowName <$> foundA) `shouldBe` Just "a-renamed"
      (_he_shellPid <$> foundA) `shouldBe` Just (Just 4242)
      (_he_harnessPid <$> foundA) `shouldBe` Just (Just 4243)
      (_he_liveness <$> foundA) `shouldBe` Just LivenessThinking
      (_he_extModified <$> foundA) `shouldBe` Just True

    it "ignores observed rows whose id is not in the registry (no resurrection)" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "a")
      let obsB = ObservedHarness
            { _oh_id          = idB
            , _oh_session     = "pureclaw"
            , _oh_windowName  = "ghost"
            , _oh_shellPid    = Nothing
            , _oh_harnessPid  = Nothing
            , _oh_liveness    = LivenessExited
            , _oh_extModified = False
            , _oh_stale       = False
            , _oh_orphanedTicks = 0
            }
      mergeReconcile reg [obsB]
      -- B was never registered; an observed row alone must not create it.
      foundB <- lookupById reg idB
      (_he_id <$> foundB) `shouldBe` Nothing
      -- A is untouched.
      foundA <- lookupById reg idA
      (_he_id <$> foundA) `shouldBe` Just idA

    it "merges multiple observed rows in one transaction" $ do
      reg <- newRegistry
      insertEntry reg ((mkEntry idA "a") { _he_liveness = LivenessIdle })
      insertEntry reg ((mkEntry idB "b") { _he_liveness = LivenessIdle })
      let obs hid lv = ObservedHarness
            { _oh_id          = hid
            , _oh_session     = "pureclaw"
            , _oh_windowName  = "w"
            , _oh_shellPid    = Nothing
            , _oh_harnessPid  = Nothing
            , _oh_liveness    = lv
            , _oh_extModified = False
            , _oh_stale       = False
            , _oh_orphanedTicks = 0
            }
      mergeReconcile reg [obs idA LivenessThinking, obs idB LivenessExited]
      fa <- lookupById reg idA
      fb <- lookupById reg idB
      (_he_liveness <$> fa) `shouldBe` Just LivenessThinking
      (_he_liveness <$> fb) `shouldBe` Just LivenessExited

    it "is observable via the underlying TVar map (STM source of truth)" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "a")
      m <- readTVarIO (unHarnessRegistry reg)
      Map.keys m `shouldBe` [idA]

    -- WU2 (D2): applyObserved must copy the observed orphaned-tick counter onto
    -- the entry so the grace policy rides the existing merge path.
    it "copies _oh_orphanedTicks into the entry (grace counter rides the merge)" $ do
      reg <- newRegistry
      insertEntry reg (mkEntry idA "a")
      let obs = ObservedHarness
            { _oh_id          = idA
            , _oh_session     = "pureclaw"
            , _oh_windowName  = "a"
            , _oh_shellPid    = Nothing
            , _oh_harnessPid  = Nothing
            , _oh_liveness    = LivenessOrphaned
            , _oh_extModified = False
            , _oh_stale       = False
            , _oh_orphanedTicks = 3
            }
      mergeReconcile reg [obs]
      found <- lookupById reg idA
      (_he_orphanedTicks <$> found) `shouldBe` Just 3

  -- D2.4 — HarnessId JSON + text round-trips.
  describe "HarnessId round-trips (D2.4)" $ do
    it "ToJSON/FromJSON round-trips" $ do
      let hid = idA
      Aeson.decode (Aeson.encode hid) `shouldBe` Just hid

    it "encodes as the canonical UUID string" $ do
      let hid = idA
      Aeson.encode hid `shouldBe` Aeson.encode ("11111111-1111-1111-1111-111111111111" :: Text)

    it "parseHarnessId / harnessIdToText round-trips" $ do
      let hid = idA
      parseHarnessId (harnessIdToText hid) `shouldBe` Just hid

    it "parseHarnessId rejects non-UUID text" $
      parseHarnessId "not-a-uuid" `shouldSatisfy` isNothing

    it "rejects malformed UUID JSON" $
      (Aeson.decode "\"not-a-uuid\"" :: Maybe HarnessId) `shouldSatisfy` isNothing

    it "newHarnessId produces parseable distinct ids" $ do
      h1 <- newHarnessId
      h2 <- newHarnessId
      h1 `shouldNotBe` h2
      parseHarnessId (harnessIdToText h1) `shouldBe` Just h1

    it "harnessIdToText agrees with Data.UUID.toText" $ do
      -- guards against accidentally re-implementing the rendering
      let hid = idA
      Just (harnessIdToText hid)
        `shouldBe` (UUID.toText <$> UUID.fromText "11111111-1111-1111-1111-111111111111")

  -- The FromJSON failure branch must evaluate its error-message expression so
  -- the malformed-UUID path (and its message text) is exercised, not just the
  -- isNothing outcome. eitherDecode surfaces the message; assert on its content.
  describe "FromJSON HarnessId failure message" $ do
    it "reports an 'invalid HarnessId' error for non-UUID JSON" $ do
      let res = Aeson.eitherDecode "\"not-a-uuid\"" :: Either String HarnessId
      case res of
        Right hid -> expectationFailure
          ("expected decode failure, got: " ++ show hid)
        Left msg -> do
          msg `shouldSatisfy` ("invalid HarnessId" `isInfixOf`)
          -- Force the full message (including the @show t@ tail that renders
          -- the offending text) so the whole error expression is evaluated.
          msg `shouldSatisfy` ("not-a-uuid" `isInfixOf`)

    it "rejects a non-string JSON value with the withText type label" $ do
      -- Decoding a JSON number (not a string) drives @Aeson.withText "HarnessId"@
      -- down its type-mismatch path, which evaluates the "HarnessId" label.
      let res = Aeson.eitherDecode "123" :: Either String HarnessId
      case res of
        Right hid -> expectationFailure
          ("expected decode failure, got: " ++ show hid)
        Left msg -> msg `shouldSatisfy` ("HarnessId" `isInfixOf`)

  -- Every HarnessEntry field selector must be read by at least one test so the
  -- record accessors are covered. Build a fully-populated entry (with a handle)
  -- and project every field; then build the Nothing-handle variant.
  describe "HarnessEntry field selectors" $ do
    let full = HarnessEntry
          { _he_id          = idA
          , _he_session     = "sess-1"
          , _he_windowName  = "win-1"
          , _he_shellPid    = Just 100
          , _he_harnessPid  = Just 200
          , _he_origin      = OriginDiscovered
          , _he_liveness    = LivenessThinking
          , _he_extModified = True
          , _he_stale       = True
          , _he_sessionId   = Just "pcl-session-42"
          , _he_label       = "label-1"
          , _he_orphanedTicks = 7
          , _he_handle      = Just mkNoOpHarnessHandle
          }

    it "projects every field of a fully-populated entry" $ do
      _he_id full          `shouldBe` idA
      _he_session full     `shouldBe` "sess-1"
      _he_windowName full  `shouldBe` "win-1"
      _he_shellPid full    `shouldBe` Just 100
      _he_harnessPid full  `shouldBe` Just 200
      _he_origin full      `shouldBe` OriginDiscovered
      _he_liveness full    `shouldBe` LivenessThinking
      _he_extModified full `shouldBe` True
      _he_stale full       `shouldBe` True
      _he_sessionId full   `shouldBe` Just "pcl-session-42"
      _he_label full       `shouldBe` "label-1"
      _he_orphanedTicks full `shouldBe` 7
      -- HarnessHandle has no Eq/Show; assert presence via isJust.
      isJust (_he_handle full) `shouldBe` True

    it "carries Nothing for an entry without an attached handle" $ do
      let bare = full { _he_handle = Nothing }
      isNothing (_he_handle bare) `shouldBe` True

  -- Exercise the derived Eq/Ord/Show instances on HarnessId so their generated
  -- code is covered (the round-trip tests use Eq via shouldBe but Ord/Show were
  -- never invoked directly).
  describe "HarnessId derived instances" $ do
    it "Show renders the canonical UUID text" $ do
      -- derived Show on the newtype wraps the inner UUID's Show.
      show idA `shouldContain` "11111111-1111-1111-1111-111111111111"

    it "Eq holds reflexively and distinguishes ids" $ do
      idA `shouldBe` idA
      idA `shouldNotBe` idB

    it "Ord is consistent with the underlying UUID ordering" $ do
      compare idA idB `shouldBe` LT
      compare idB idA `shouldBe` GT
      compare idA idA `shouldBe` EQ

  -- Exercise Eq/Show for HarnessOrigin and Liveness directly.
  describe "HarnessOrigin instances" $ do
    it "Show distinguishes each constructor" $ do
      show OriginSpawned    `shouldBe` "OriginSpawned"
      show OriginDiscovered `shouldBe` "OriginDiscovered"
      show OriginAdopted    `shouldBe` "OriginAdopted"

    it "Eq distinguishes constructors" $ do
      OriginSpawned `shouldBe` OriginSpawned
      OriginSpawned `shouldNotBe` OriginDiscovered
      OriginDiscovered `shouldNotBe` OriginAdopted

  describe "Liveness instances" $ do
    it "Show distinguishes each constructor" $ do
      show LivenessIdle     `shouldBe` "LivenessIdle"
      show LivenessThinking `shouldBe` "LivenessThinking"
      show LivenessExited   `shouldBe` "LivenessExited"
      show LivenessOrphaned `shouldBe` "LivenessOrphaned"

    it "Eq distinguishes constructors" $ do
      LivenessIdle `shouldBe` LivenessIdle
      LivenessIdle `shouldNotBe` LivenessThinking
      LivenessExited `shouldNotBe` LivenessOrphaned
