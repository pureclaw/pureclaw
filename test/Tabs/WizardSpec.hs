-- |
-- Module      : Tabs.WizardSpec
-- Description : WU6 — the @\/tab@ attach-wizard state machine.
--
-- Covers the WU6 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79), spec §11:
--
--   1. A valid pick binds the EXACT snapshot id (captured at snapshot time),
--      never re-resolved by list position.
--   2. A vanished harness target (@_wz_live@ False) re-prompts with a refreshed
--      list that no longer offers it.
--   3. Cancel paths: @0@\/@cancel@ → 'Cancelled'; a @\/@-prefixed reply →
--      'RunCommand'; an unknown\/empty\/multi-char reply → 'Reprompt' with the
--      state unchanged.
--   4. Overflow\/cap: a snapshot built from more candidates than the key
--      namespace is capped, harnesses listed before sessions; 'filterCandidates'
--      is a sanitised case-insensitive substring filter on labels.
--   5. A 'ReopenSession' pick performs no liveness check and returns 'Done'.
module Tabs.WizardSpec (spec) where

import Data.Maybe qualified as Maybe
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Harness.Registry (HarnessId, parseHarnessId)

import PureClaw.Tabs.Wizard

-- | Build a 'HarnessId' from a fixed UUID text. Total within the test: the
-- literals below are valid UUIDs, so 'Maybe.fromJust' never fires; 'error'
-- pinpoints a typo if one is introduced.
hid :: Text -> HarnessId
hid t = Maybe.fromMaybe (error ("bad test UUID: " <> T.unpack t)) (parseHarnessId t)

h1, h2, h3 :: HarnessId
h1 = hid "11111111-1111-1111-1111-111111111111"
h2 = hid "22222222-2222-2222-2222-222222222222"
h3 = hid "33333333-3333-3333-3333-333333333333"

sid :: Text -> SessionId
sid = SessionId

-- | A 'WizardEnv' whose liveness probe consults a fixed allow-list of ids.
liveOnly :: [HarnessId] -> WizardEnv
liveOnly alive = WizardEnv (\h -> pure (h `elem` alive))

-- | A 'WizardEnv' whose probe always reports alive.
allLive :: WizardEnv
allLive = WizardEnv (\_ -> pure True)

spec :: Spec
spec = do
  describe "mkWizardSnapshot" $ do
    it "numbers harnesses first, then sessions, starting at key '1'" $ do
      let st = mkWizardSnapshot [(h1, "alpha"), (h2, "beta")] [(sid "s1", "gamma")]
      _wz_options st
        `shouldBe` [ ('1', AttachHarness h1)
                   , ('2', AttachHarness h2)
                   , ('3', ReopenSession (sid "s1"))
                   ]

    it "never assigns the reserved '0' key to an option" $ do
      let st = mkWizardSnapshot (replicate 40 (h1, "x")) []
      map fst (_wz_options st) `shouldNotContain` ['0']

    it "caps the option list at the key-namespace size" $ do
      -- 40 harness candidates, but only the [1-9a-z] keys are available.
      let st = mkWizardSnapshot [ (hid u, "x") | u <- manyUuids 40 ] []
          n  = length (_wz_options st)
      n `shouldBe` length wizardKeys
      map fst (_wz_options st) `shouldBe` wizardKeys

    it "harnesses are listed before sessions when both overflow" $ do
      let st = mkWizardSnapshot
                 [ (hid u, "h") | u <- manyUuids 30 ]
                 [ (sid (T.pack ('s' : show i)), "s") | i <- [0 :: Int .. 30] ]
          targets = map snd (_wz_options st)
          isHarness (AttachHarness _) = True
          isHarness _                 = False
          (front, back) = span isHarness targets
      length front `shouldBe` 30          -- all 30 harnesses kept, contiguous
      any isHarness back `shouldBe` False

  describe "renderMenu" $ do
    -- The engine-level renderer is label-free: 'mkWizardSnapshot' keeps only the
    -- binding-relevant '(Char, WizardTarget)', so the menu shows the target id
    -- text. (The dispatcher renders the richer friendly-label menu in WU8.)
    it "renders one numbered line per option plus a 0/cancel line" $ do
      let st   = mkWizardSnapshot [(h1, "claude-code")] [(sid "20260607", "refactor")]
          menu = renderMenu st
      -- both option keys, the two target ids, and the reserved cancel line.
      menu `shouldSatisfy` T.isInfixOf "1"
      menu `shouldSatisfy` T.isInfixOf "2"
      menu `shouldSatisfy` T.isInfixOf "20260607"
      menu `shouldSatisfy` T.isInfixOf "0"
      menu `shouldSatisfy` T.isInfixOf "cancel"
      -- one line per option plus header plus cancel line.
      length (T.lines menu) `shouldBe` 4

  describe "stepWizard — valid pick binds the exact snapshot id (DoD 1)" $ do
    it "reply '1' returns Done with the harness id captured at snapshot time" $ do
      let st = mkWizardSnapshot [(h1, "a"), (h2, "b")] []
      (next, step) <- stepWizard allLive st "1"
      step `shouldBe` Done (AttachHarness h1)
      next `shouldBe` Nothing

    it "binds by key, not by post-snapshot position" $ do
      -- Even if a re-resolve by position would pick differently, key '2'
      -- binds the id captured under '2' at snapshot time.
      let st = mkWizardSnapshot [(h1, "a"), (h2, "b"), (h3, "c")] []
      (_, step) <- stepWizard allLive st "2"
      step `shouldBe` Done (AttachHarness h2)

  describe "stepWizard — vanished target (DoD 2)" $ do
    it "re-prompts and the refreshed state no longer offers the dead harness" $ do
      let st = mkWizardSnapshot [(h1, "a"), (h2, "b")] []
      (next, step) <- stepWizard (liveOnly [h2]) st "1"   -- h1 has died
      case step of
        Reprompt notice -> notice `shouldSatisfy` T.isInfixOf "gone"
        other           -> expectationFailure ("expected Reprompt, got " <> show other)
      case next of
        Just st' -> map snd (_wz_options st') `shouldNotContain` [AttachHarness h1]
        Nothing  -> expectationFailure "expected a refreshed state, got Nothing"

    it "the refreshed state still offers the surviving harness" $ do
      let st = mkWizardSnapshot [(h1, "a"), (h2, "b")] []
      (Just st', _) <- stepWizard (liveOnly [h2]) st "1"
      map snd (_wz_options st') `shouldContain` [AttachHarness h2]

  describe "stepWizard — ReopenSession pick has no liveness check (DoD 5)" $ do
    it "returns Done immediately even with an always-dead probe" $ do
      let st = mkWizardSnapshot [] [(sid "s1", "x")]
      (next, step) <- stepWizard (liveOnly []) st "1"
      step `shouldBe` Done (ReopenSession (sid "s1"))
      next `shouldBe` Nothing

  describe "stepWizard — cancel paths (DoD 3)" $ do
    let st = mkWizardSnapshot [(h1, "a")] []

    it "'0' cancels" $ do
      (next, step) <- stepWizard allLive st "0"
      step `shouldBe` Cancelled
      next `shouldBe` Nothing

    it "'cancel' (case-insensitive, trimmed) cancels" $ do
      (next, step) <- stepWizard allLive st "  CaNcEl "
      step `shouldBe` Cancelled
      next `shouldBe` Nothing

    it "a '/'-prefixed reply runs that command (trimmed, verbatim)" $ do
      (next, step) <- stepWizard allLive st "  /tabs "
      step `shouldBe` RunCommand "/tabs"
      next `shouldBe` Nothing

    it "an unknown single key re-prompts with the state unchanged" $ do
      (next, step) <- stepWizard allLive st "z"
      case step of
        Reprompt _ -> pure ()
        other      -> expectationFailure ("expected Reprompt, got " <> show other)
      next `shouldBe` Just st

    it "an empty reply re-prompts with the state unchanged" $ do
      (next, step) <- stepWizard allLive st "   "
      case step of
        Reprompt _ -> pure ()
        other      -> expectationFailure ("expected Reprompt, got " <> show other)
      next `shouldBe` Just st

    it "a multi-char non-command reply re-prompts with the state unchanged" $ do
      (next, step) <- stepWizard allLive st "zzz"
      case step of
        Reprompt _ -> pure ()
        other      -> expectationFailure ("expected Reprompt, got " <> show other)
      next `shouldBe` Just st

  describe "filterCandidates (DoD 4 — substring filter)" $ do
    let cands =
          [ (1 :: Int, "refactor routing")
          , (2,        "vault work")
          , (3,        "Routing cleanup")
          ]

    it "keeps only candidates whose label contains the query (case-insensitive)" $ do
      map fst (filterCandidates "rout" cands) `shouldBe` [1, 3]

    it "trims and lowercases the query before matching" $ do
      map fst (filterCandidates "  VAULT  " cands) `shouldBe` [2]

    it "an empty (or whitespace-only) query keeps everything" $ do
      map fst (filterCandidates "   " cands) `shouldBe` [1, 2, 3]

    it "a non-matching query keeps nothing" $ do
      filterCandidates "nope" cands `shouldBe` []

-- | Deterministic distinct UUID texts of the form @0000…000N@.
manyUuids :: Int -> [Text]
manyUuids n = [ pad i | i <- [0 .. n - 1] ]
  where
    pad i =
      let hexd = T.pack (showHex12 i)
      in "00000000-0000-0000-0000-" <> hexd
    showHex12 i =
      let s = toHex i
      in replicate (12 - length s) '0' <> s
    toHex 0 = "0"
    toHex k = go k ""
      where
        go 0 acc = acc
        go m acc = go (m `div` 16) (digit (m `mod` 16) : acc)
        digit d
          | d < 10    = toEnum (fromEnum '0' + d)
          | otherwise = toEnum (fromEnum 'a' + (d - 10))
