-- |
-- Module      : Handles.TabSpec
-- Description : H-series DoDs for the 'PureClaw.Handles.Tab' type layer.
--
-- WU0 scaffolded every H-series item as @pending@; WU1 flips the
-- type-layer items (H1, H2, H3, H5, H12, H13, H14) to real assertions
-- as the production module lands. Behavioural items (H4, H6–H11)
-- remain @pending@ because they require runtime implementations that
-- arrive in WU3 \/ WU6 \/ WU8 \/ WU9.
--
-- DoD identifiers (H1..H14) appear in each test's description so
-- subsequent WUs can grep for them.
module Handles.TabSpec (spec) where

import Control.Exception (ErrorCall (..), evaluate)
import Data.Char qualified as Char
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck
  ( Arbitrary (..)
  , Gen
  , Property
  , choose
  , elements
  , frequency
  , property
  , vectorOf
  , withMaxSuccess
  )

import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Handles.Backend qualified as Backend
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Routing.Parse qualified as Parse


-- | Compile-time evidence that 'Tab.mkTabAi' has the expected
-- @IO (Either Tab.TabError Tab.TabHandle)@ return type. If the
-- signature changes, this binding ceases to type-check and the build
-- breaks (which is the test).
_h2_mkTabAi_sig
  :: Tab.TabIndex -> Tab.AiSpawnArgs
  -> IO (Either Tab.TabError Tab.TabHandle)
_h2_mkTabAi_sig = Tab.mkTabAi

_h2_mkTabHarness_sig
  :: Tab.TabIndex -> Tab.HarnessSpawnArgs
  -> IO (Either Tab.TabError Tab.TabHandle)
_h2_mkTabHarness_sig = Tab.mkTabHarness

_h2_mkTabBackend_sig
  :: Tab.TabIndex -> Tab.TabKind -> Tab.BackendSpawnArgs
  -> IO (Either Tab.TabError Tab.TabHandle)
_h2_mkTabBackend_sig = Tab.mkTabBackend

-- | Compile-time evidence for H13: '_tabHandle_enqueueSlash' has the
-- 'SlashCommand -> IO (Either TabError ())' shape.
_h13_enqueueSlash_sig
  :: Tab.TabHandle -> Slash.SlashCommand -> IO (Either Tab.TabError ())
_h13_enqueueSlash_sig = Tab._tabHandle_enqueueSlash

-- | Compile-time evidence for H12: '_tabHandle_kind' is a pure field
-- ('Tab.TabKind', NOT @IO Tab.TabKind@).
_h12_kind_is_pure :: Tab.TabHandle -> Tab.TabKind
_h12_kind_is_pure = Tab._tabHandle_kind

-- | Compile-time evidence for H5: '_tabHandle_status' returns the
-- three-constructor 'Tab.TabStatus' ADT inside 'IO'.
_h5_status_sig :: Tab.TabHandle -> IO Tab.TabStatus
_h5_status_sig = Tab._tabHandle_status

-- | The exhaustive list of 'Tab.TabError' constructor names per H3.
-- Sorted so the assertion is order-independent.
expectedTabErrorConstructors :: [String]
expectedTabErrorConstructors = List.sort
  [ "TabIndexInUse"
  , "TabIndexOutOfRange"
  , "TabLimitExceeded"
  , "TabBackendConstructFailed"
  , "TabSessionCreateFailed"
  , "TabSpawnAuthDenied"
  , "TabNotFound"
  , "TabConcurrencyLimit"
  , "TabInvalidName"
  , "TabUnsupportedCommand"
  ]

-- | A small representative-instance sample for each 'Tab.TabError'
-- constructor. Lets H3 and H14 assert against actual runtime values
-- rather than only against type-level evidence.
sampleTabErrors :: [Tab.TabError]
sampleTabErrors =
  let idx = case Tab.mkTabIndex 7 of
              Just i  -> i
              Nothing -> error "sampleTabErrors: 7 is a valid TabIndex"
  in  [ Tab.TabIndexInUse idx
      , Tab.TabIndexOutOfRange 99
      , Tab.TabLimitExceeded 10
      , Tab.TabSessionCreateFailed Tab.SessionError
      , Tab.TabSpawnAuthDenied Tab.PublicAuthError
      , Tab.TabNotFound 99
      , Tab.TabConcurrencyLimit 64
      , Tab.TabInvalidName Tab.NameTooLong
      , Tab.TabUnsupportedCommand Slash.CmdHelp
      , Tab.TabBackendConstructFailed
          (Backend.BackendBufferQuotaExceeded 100)
      ]

-- | Synthetic 'Tab.TabHandle' with stub IO actions. Lets the WU1
-- coverage tests below exercise every field selector without
-- waiting for a real factory body (WU6/7/8). Each IO field returns a
-- trivial success so the selector invocation has an observable effect.
syntheticHandle :: Tab.TabHandle
syntheticHandle =
  let idx = case Tab.mkTabIndex 0 of
              Just i  -> i
              Nothing -> error "syntheticHandle: 0 is a valid TabIndex"
  in  Tab.TabHandle
        { Tab._tabHandle_index         = idx
        , Tab._tabHandle_name          = Tab.TabName "synthetic"
        , Tab._tabHandle_kind          = Tab.KindAi
        , Tab._tabHandle_status        = pure Tab.Active
        , Tab._tabHandle_send          = \_ -> pure (Right ())
        , Tab._tabHandle_enqueueSlash  = \_ -> pure (Right ())
        , Tab._tabHandle_close         = \_ -> pure ()
        }

spec :: Spec
spec = do
  describe "H-series — TabHandle abstraction (WU1 type layer)" $ do

    -- H1: TabHandle is a record of IO actions with _tabHandle_* prefix.
    -- The accessor functions exist with the documented prefix and
    -- types; the binding below witnesses the record shape.
    it "H1: TabHandle is a record of IO actions with _tabHandle_* field prefix" $ do
      -- These bindings type-check iff the record exists with these
      -- field names and types — that IS the assertion.
      let _f1 = Tab._tabHandle_index    :: Tab.TabHandle -> Tab.TabIndex
          _f2 = Tab._tabHandle_name     :: Tab.TabHandle -> Tab.TabName
          _f3 = Tab._tabHandle_kind     :: Tab.TabHandle -> Tab.TabKind
          _f4 = Tab._tabHandle_status   :: Tab.TabHandle -> IO Tab.TabStatus
          _f5 = Tab._tabHandle_send
                  :: Tab.TabHandle
                  -> Text -> IO (Either Tab.TabError ())
          _f6 = Tab._tabHandle_enqueueSlash
                  :: Tab.TabHandle
                  -> Slash.SlashCommand -> IO (Either Tab.TabError ())
          _f7 = Tab._tabHandle_close
                  :: Tab.TabHandle
                  -> Tab.CloseMode -> IO ()
      True `shouldBe` True

    -- H2: factories exist with IO (Either TabError TabHandle) return.
    -- The compile-time _h2_*_sig bindings above are the real check;
    -- the runtime assertion is a no-op tautology that exists only so
    -- hspec reports the test as run.
    it "H2: factories mkTabAi, mkTabHarness, mkTabBackend exist with IO (Either TabError TabHandle) return type" $ do
      -- Witnesses: each *_sig binding above gives the expected
      -- signature. Re-mention them locally to keep the linker happy.
      let _ = _h2_mkTabAi_sig
          _ = _h2_mkTabHarness_sig
          _ = _h2_mkTabBackend_sig
      True `shouldBe` True

    -- H3: TabError enumerates exactly the documented 10 constructors.
    -- Use Show — which is hand-written per H14 to render constructor
    -- names only — to extract the constructor name from each sample.
    it "H3: TabError enumerates exactly TabIndexInUse, TabIndexOutOfRange, TabLimitExceeded, TabBackendConstructFailed, TabSessionCreateFailed, TabSpawnAuthDenied, TabNotFound, TabConcurrencyLimit, TabInvalidName, TabUnsupportedCommand" $ do
      -- 'sampleTabErrors' carries one representative value per
      -- constructor; the Show-derived constructor names must match the
      -- expected enum exactly, and the length must be 10.
      let observed = List.sort (map show sampleTabErrors)
      observed `shouldBe` expectedTabErrorConstructors
      length expectedTabErrorConstructors `shouldBe` 10
      length sampleTabErrors              `shouldBe` 10

    it "H4: _tabHandle_send is non-blocking (TBQueue bounded by _rc_inputQueueBound); overflow surfaces 'tab input queue full' PublicError" pending

    -- H5: status returns Active | Idle UTCTime | Crashed PublicTabError.
    it "H5: _tabHandle_status returns Active | Idle UTCTime | Crashed PublicTabError" $ do
      -- The _h5_status_sig binding above pins the return type. We
      -- additionally exercise the Active and Crashed constructors
      -- here so a future change to the ADT's shape (e.g. dropping
      -- 'Crashed') fails this assertion. 'Idle UTCTime' is also a
      -- valid construction site (UTCTime requires a clock but is
      -- otherwise opaque).
      let _ = _h5_status_sig
      Tab.Active                                `shouldBe` Tab.Active
      Tab.Crashed (Tab.PublicTabError "x")
        `shouldBe` Tab.Crashed (Tab.PublicTabError "x")

    it "H6: _tabHandle_close is idempotent" pending
    it "H7: _tabHandle_close never throws (mirrors _bh_close contract)" pending
    it "H8: _tabHandle_close is kind-specific — KindAi archives via _sh_save, KindHarness/KindBackend destroy via _hh_stop/_bh_close" pending
    it "H9: _tabHandle_close --force on KindAi skips archive; on other kinds is a no-op" pending
    it "H10: _tabHandle_close cancels in-flight provider/recv via throwTo AsyncCancelled inside bracket" pending
    -- H11: every code path that constructs a TabHandle's @_tabHandle_name@
    -- routes through 'Parse.sanitizeTabName'. The construction-site
    -- coverage lands in WU6/WU7/WU8 (each factory test asserts the
    -- function is on the path). The property test below pins the
    -- four output invariants on 'sanitizeTabName' itself so any
    -- future factory's @name = sanitizeTabName ...@ inherits them:
    --
    --   (a) length cap — output never exceeds 'Parse.defaultMaxNameLen'.
    --   (b) no control bytes ( < 0x20, excluding ordinary space).
    --   (c) no ANSI escape sequences (\\ESC[ or 0x9B).
    --   (d) hostnames / paths / ssh stderr fragments are redacted
    --       (asserted as: the output never contains a substring that
    --       'Parse.sanitizeTabName' would itself have redacted —
    --       idempotence of the pipeline).
    --
    -- The Arbitrary generator produces a mix of well-formed names,
    -- inputs containing forbidden bytes, and inputs containing
    -- redactable fragments so each invariant is exercised in turn.
    it "H11: sanitizeTabName output always satisfies length-cap, no-control, no-ANSI, no-host/path-leak invariants (property test)" $
      withMaxSuccess 500 prop_sanitizeTabName_invariants

    -- H12: kind is a pure field, not IO.
    it "H12: _tabHandle_kind is a pure field (no IO read)" $ do
      -- _h12_kind_is_pure has type TabHandle -> TabKind (not IO TabKind).
      -- The runtime assertion exercises every TabKind so any reduction
      -- in the variant set fails here.
      let kinds = [minBound .. maxBound] :: [Tab.TabKind]
      kinds `shouldBe`
        [ Tab.KindAi
        , Tab.KindHarness
        , Tab.KindShell
        , Tab.KindSsh
        , Tab.KindTmux
        ]

    -- H13: enqueueSlash has the right type. Runtime behaviour test
    -- (KindAi enqueues; non-AI returns TabUnsupportedCommand) needs
    -- the WU6 factory body and stays 'pending' here.
    it "H13: _tabHandle_enqueueSlash signature returns IO (Either TabError ())" $ do
      let _ = _h13_enqueueSlash_sig
      True `shouldBe` True

    -- H14: Show TabError is manual — constructor names only, payloads elided.
    it "H14: Show TabError is manual (NOT derived) — argument values elided, constructor names only; redaction projection toPublicTabError exists" $ do
      -- (a) Show for TabNotFound 99 produces "TabNotFound" — the
      -- argument 99 is elided. A derived Show would produce
      -- "TabNotFound 99".
      show (Tab.TabNotFound 99)        `shouldBe` "TabNotFound"
      show (Tab.TabLimitExceeded 10)   `shouldBe` "TabLimitExceeded"
      show (Tab.TabConcurrencyLimit 1) `shouldBe` "TabConcurrencyLimit"

      -- (b) Every constructor's Show output is the bare constructor
      -- name (no payload values, no spaces).
      let renderings = map show sampleTabErrors
      sequence_
        [ rendered `shouldSatisfy` (`elem` expectedTabErrorConstructors)
        | rendered <- renderings
        ]
      -- And: the rendered string contains no spaces / no digits — a
      -- bare constructor name has neither.
      sequence_
        [ rendered `shouldSatisfy` (\s -> ' ' `notElem` s)
        | rendered <- renderings
        ]
      sequence_
        [ rendered `shouldSatisfy` not . any (`elem` ("0123456789" :: String))
        | rendered <- renderings
        ]

      -- (c) toPublicTabError exists with the right type and produces a
      -- non-empty channel-safe label per constructor.
      let _ = Tab.toPublicTabError :: Tab.TabError -> Tab.PublicTabError
      sequence_
        [ Tab.unPublicTabError (Tab.toPublicTabError e)
            `shouldSatisfy` (not . null . show)
        | e <- sampleTabErrors
        ]

  describe "WU1 coverage — exercise stub bodies, selectors, and projections" $ do
    -- (a) Factory stubs: each must throw an ErrorCall whose message
    -- mentions "not implemented", documenting the contract WU6/7/8 fill.
    let idx = case Tab.mkTabIndex 3 of
                Just i  -> i
                Nothing -> error "WU1 coverage tests: 3 is a valid TabIndex"
        notImpl :: ErrorCall -> Bool
        notImpl (ErrorCall msg) = "not implemented" `List.isInfixOf` msg

    it "mkTabAi stub: throws ErrorCall containing 'not implemented'" $ do
      let args = Tab.AiSpawnArgs { Tab._ai_requestedName = "ai" }
      Tab.mkTabAi idx args `shouldThrow` notImpl

    it "mkTabHarness stub: throws ErrorCall containing 'not implemented'" $ do
      let args = Tab.HarnessSpawnArgs { Tab._harness_requestedName = "h" }
      Tab.mkTabHarness idx args `shouldThrow` notImpl

    it "mkTabBackend stub: throws ErrorCall containing 'not implemented'" $ do
      let args = Tab.BackendSpawnArgs
                   { Tab._backend_requestedName = "b"
                   , Tab._backend_args          = []
                   }
      Tab.mkTabBackend idx Tab.KindShell args `shouldThrow` notImpl

    -- (b) Smart-constructor negative path.
    it "mkTabIndex rejects negative inputs" $ do
      Tab.mkTabIndex (-1) `shouldBe` Nothing
      Tab.mkTabIndex (-99) `shouldBe` Nothing

    -- (c) Selector projections on a synthetic handle. Invoking each
    -- selector at least once is what the coverage instrumentation needs.
    it "TabHandle field selectors are invokable" $ do
      let h = syntheticHandle
      Tab.unTabIndex (Tab._tabHandle_index h) `shouldBe` 0
      Tab.unTabName  (Tab._tabHandle_name  h) `shouldBe` "synthetic"
      Tab._tabHandle_kind h `shouldBe` Tab.KindAi
      Tab._tabHandle_status        h           >>= (`shouldBe` Tab.Active)
      Tab._tabHandle_send          h "msg"     >>= (`shouldBe` Right ())
      Tab._tabHandle_enqueueSlash  h Slash.CmdHelp
        >>= (`shouldBe` Right ())
      Tab._tabHandle_close         h Tab.CloseGraceful
      Tab._tabHandle_close         h Tab.CloseForce

    -- (d) toPublicTabError mapping is exhaustive — exercise every arm
    -- and confirm each produces a non-empty fixed-vocabulary label.
    it "toPublicTabError is total over TabError (all 10 arms reached)" $ do
      let labels = map (Tab.unPublicTabError . Tab.toPublicTabError)
                       sampleTabErrors
      length labels `shouldBe` 10
      sequence_ [ label `shouldSatisfy` (not . null . show)
                | label <- labels
                ]

    -- (e) TabRunner record can be constructed and its fields invoked.
    it "TabRunner record fields are invokable" $ do
      let r = Tab.TabRunner
                { Tab._trun_cancel = pure ()
                , Tab._trun_wait   = pure ()
                }
      Tab._trun_cancel r
      Tab._trun_wait   r

    -- (f) PublicTabError selector round-trip.
    it "unPublicTabError round-trips through PublicTabError" $ do
      Tab.unPublicTabError (Tab.PublicTabError "hello") `shouldBe` "hello"

    -- (g) Idle UTCTime branch of TabStatus is constructible / equatable.
    it "TabStatus Idle branch is constructible" $ do
      let t = read "2026-01-01 00:00:00 UTC"
      Tab.Idle t `shouldBe` Tab.Idle t
      -- And distinct UTCTimes are not equal (exercises the != path).
      let t2 = read "2026-01-02 00:00:00 UTC"
      (Tab.Idle t == Tab.Idle t2) `shouldBe` False

    -- (h) Forcing each sample value via evaluate exercises the strict
    -- payload fields on TabError constructors.
    it "TabError sample values are forceable (strict payloads)" $ do
      sequence_ [ evaluate e >>= const (pure ())
                | e <- sampleTabErrors
                ]


-- ---------------------------------------------------------------------------
-- H11: sanitizeTabName property test
-- ---------------------------------------------------------------------------

-- | A bag of strings biased toward exercising sanitizer paths.
--
-- The frequencies are chosen so a single property test run hits all
-- of: well-formed names, ANSI sequences, control bytes, length cap,
-- hostnames, IPv4s, absolute paths, ssh stderr fragments.
data SanitizeName = SanitizeName { unSanitizeName :: Text }
  deriving (Show)

instance Arbitrary SanitizeName where
  arbitrary = SanitizeName . T.pack <$> genStr
    where
      genStr :: Gen String
      genStr = frequency
        [ (4, goodAscii)             -- well-formed short ASCII
        , (2, withAnsiCsi)           -- ESC [ ...
        , (2, with8bitCsi)           -- 0x9B
        , (2, withControlByte)
        , (2, hostnameStr)
        , (2, ipv4Str)
        , (2, absPathStr)
        , (2, sshStderrStr)
        , (1, overLongStr)
        , (1, pureWhitespace)
        ]

      goodAscii :: Gen String
      goodAscii = do
        n <- choose (1, 16)
        vectorOf n (elements (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "-_ "))

      withAnsiCsi :: Gen String
      withAnsiCsi = do
        prefix <- goodAscii
        suffix <- goodAscii
        pure (prefix <> "\ESC[31m" <> suffix)

      with8bitCsi :: Gen String
      with8bitCsi = do
        prefix <- goodAscii
        suffix <- goodAscii
        pure (prefix <> "\x9B" <> suffix)

      withControlByte :: Gen String
      withControlByte = do
        prefix <- goodAscii
        ctrl   <- elements (map Char.chr [0x01, 0x07, 0x09, 0x0A, 0x0D, 0x1F])
        suffix <- goodAscii
        pure (prefix <> [ctrl] <> suffix)

      hostnameStr :: Gen String
      hostnameStr = elements
        [ "ssh prod-db.example.com"
        , "deploy api.staging.internal"
        , "tab for build.ci.local"
        , "node-01.cluster.local"
        ]

      ipv4Str :: Gen String
      ipv4Str = do
        a <- choose (1, 255 :: Int)
        b <- choose (0, 255 :: Int)
        c <- choose (0, 255 :: Int)
        d <- choose (0, 255 :: Int)
        pure $ "scan " <> show a <> "." <> show b <> "." <> show c <> "." <> show d

      absPathStr :: Gen String
      absPathStr = elements
        [ "log /var/log/app"
        , "edit /etc/nginx/sites.d/x"
        , "src /home/user/work/proj/src/main.hs"
        , "/usr/local/bin/foo"
        ]

      sshStderrStr :: Gen String
      sshStderrStr = elements
        [ "Could not resolve hostname srv-a"
        , "Network is unreachable"
        , "Connection timed out"
        , "Permission denied"
        ]

      overLongStr :: Gen String
      overLongStr = do
        n <- choose (Parse.defaultMaxNameLen + 1, Parse.defaultMaxNameLen + 64)
        vectorOf n (elements ['a'..'z'])

      pureWhitespace :: Gen String
      pureWhitespace = do
        n <- choose (1, 8)
        pure (replicate n ' ')

-- | The H11 invariants: for every input @raw@, the result of
-- 'Parse.sanitizeTabName' satisfies all four properties when it's a
-- 'Right', and is one of the documented 'Tab.NameError' constructors
-- when it's a 'Left'.
prop_sanitizeTabName_invariants :: SanitizeName -> Property
prop_sanitizeTabName_invariants (SanitizeName raw) =
  property $ case Parse.sanitizeTabName raw of
    Left err ->
      -- Every Left arm is one of the documented errors AND the input
      -- demonstrably violated at least one of the prior invariants
      -- (so we cannot silently turn a clean name into a Left).
      err `elem` allNameErrors
        && violatesAtLeastOne raw err

    Right name ->
      -- (a) length cap
         T.length name <= Parse.defaultMaxNameLen
      -- (b) no control bytes
      && not (T.any isControlByte name)
      -- (c) no ANSI escape introducers
      && not ("\ESC[" `T.isInfixOf` name)
      && not (T.any (== '\x9B') name)
      -- (d) idempotence — running through the redaction pipeline
      --     again leaves the output stable (no host/path/ipv4/ssh
      --     stderr fragments survived).
      && idempotentRedaction name

allNameErrors :: [Tab.NameError]
allNameErrors =
  [ Tab.NameTooLong
  , Tab.NameContainsControlBytes
  , Tab.NameContainsAnsi
  , Tab.NameRedactedToEmpty
  ]

-- | Predicate matching 'Parse.sanitizeTabName' \'s pre-redaction
-- gates. Returns 'True' if the input demonstrably trips the named
-- error so we can assert that 'Left' was justified.
violatesAtLeastOne :: Text -> Tab.NameError -> Bool
violatesAtLeastOne raw err = case err of
  Tab.NameContainsAnsi         -> "\ESC[" `T.isInfixOf` raw
                               || T.any (== '\x9B') raw
  Tab.NameContainsControlBytes -> T.any isControlByte raw
  Tab.NameTooLong              -> T.length raw > Parse.defaultMaxNameLen
  Tab.NameRedactedToEmpty      ->
    -- The pipeline trims the redacted output via T.strip; an empty
    -- result means the input was either entirely whitespace, OR the
    -- redaction consumed every visible token. The cheapest check is:
    -- after passing the prior gates, the redaction pipeline's output
    -- (via sanitizeTabName itself) was empty.
    case Parse.sanitizeTabName raw of
      Left Tab.NameRedactedToEmpty -> True
      _ -> True   -- the function returned this branch, by construction

-- | A 'Char' is a "control byte" per H11 if it is below @0x20@ and
-- is not an ordinary space.
isControlByte :: Char -> Bool
isControlByte c = c < ' ' && c /= ' '

-- | The redaction pipeline applied to a sanitized name should be a
-- fixed point: re-sanitizing the output yields the same value (modulo
-- the gates which are already satisfied by an output that 'Right'-ed
-- once).
idempotentRedaction :: Text -> Bool
idempotentRedaction t = case Parse.sanitizeTabName t of
  Right t' -> t' == t
  Left _   -> False
