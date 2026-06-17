-- |
-- Module      : Tabs.PersistSpec
-- Description : WU3 — persistence of the tab view to @state/tabs.json@.
--
-- Covers the WU3 Definition-of-Done items for the Tabs-as-View refactor
-- (GitHub #79):
--
--   1. Round-trip — 'saveTabs' then 'loadTabs' (all-live probe, no-op
--      discovery) returns the same 'TabList' + 'CursorState'.
--   2. Permissions — after 'saveTabs', @tabs.json@ is mode @0600@ and the
--      @state/@ directory is mode @0700@.
--   3. Decode failure → fresh — a corrupt @tabs.json@ makes 'loadTabs' return
--      @(emptyTabs, emptyCursors)@ without raising.
--   4. Boot reconcile — a harness-backed tab whose @_pd_harnessLive@ is False
--      is dropped silently, its cursor pruned, provider tabs kept, and
--      @_pd_discoveryReady@ is awaited before pruning.
--   5. No-secrets — the serialized JSON carries only the documented
--      ref\/name\/status\/channel\/conversation fields; no token, apikey,
--      password, or absolute-path field.
module Tabs.PersistSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (createDirectory, createDirectoryIfMissing, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files qualified as PF
import Test.Hspec

import PureClaw.Core.Types
  ( ChannelKind (..)
  , ConversationId (..)
  , SessionId (..)
  )
import PureClaw.Handles.Tab (unTabIndex)
import PureClaw.Harness.Registry (HarnessId, parseHarnessId)
import PureClaw.Tabs.Types
  ( ConversationKey
  , CursorState (..)
  , RelayMode (..)
  , Tab (..)
  , TabList
  , TabRef (..)
  , TabStatus (..)
  , appendTab
  , emptyCursors
  , emptyTabs
  , setCursor
  , setStatus
  , toList
  )

import PureClaw.Tabs.Persist
  ( PersistDeps (..)
  , loadTabs
  , saveTabs
  )

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- | A deterministic 'HarnessId' from a small int (distinct UUIDs).
hid :: Int -> HarnessId
hid n =
  fromMaybe (error "bad HarnessId fixture") $
    parseHarnessId (T.pack ("00000000-0000-0000-0000-0000000000" <> pad n))
  where
    pad k = let s = show k in replicate (2 - length s) '0' <> s

sid :: Text -> TabRef
sid t = BoundSession (SessionId t)

harnessRef :: Int -> TabRef
harnessRef = BoundHarness . hid

-- | Build a 'TabList' from a list of (ref, name) appends, erroring on any
-- rejection (fixtures are always valid). Tabs no longer carry a label of their
-- own; the name is retained in the fixture tuples for readability and ignored.
buildTabs :: [(TabRef, Text)] -> TabList
buildTabs = List.foldl' step emptyTabs
  where
    step tl (ref, _name) = case appendTab ref tl of
      Right (_, tl') -> tl'
      Left err       -> error ("buildTabs: " <> show err)

ckey :: ChannelKind -> Text -> ConversationKey
ckey ch c = (ch, ConversationId c)

-- | Deps with an all-live probe, a no-op discovery gate, and all sessions
-- present (suitable for tests that do not exercise session-orphan pruning).
allLiveDeps :: FilePath -> PersistDeps
allLiveDeps dir =
  PersistDeps
    { _pd_stateDir       = dir
    , _pd_harnessLive    = \_ -> pure True
    , _pd_discoveryReady = pure ()
    , _pd_sessionExists  = \_ -> pure True
    }

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "round-trip" $
    it "saveTabs then loadTabs returns the same TabList + CursorState" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let tabs =
              -- One Dead tombstone exercises the status round-trip; the dead
              -- tab here is provider-backed so reconcile keeps it.
              setStatus (sid "alpha") Dead $
                buildTabs
                  [ (sid "alpha", "Alpha")
                  , (harnessRef 1, "Harness One")
                  ]
            cursors =
              setCursor (ckey CkCli "cli") (sid "alpha") $
                setCursor (ckey CkTelegram "42") (harnessRef 1) $
                  emptyCursors { _cs_relay =
                                   Map.fromList
                                     [ (ckey CkCli "cli", Firehose)
                                     , (ckey CkTelegram "42", ActivityDigest)
                                     , (ckey CkSignal "s", FocusedOnly)
                                     ]
                               }
        saveTabs dir tabs cursors
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        tabs' `shouldBe` tabs
        cursors' `shouldBe` cursors

  describe "permissions" $
    it "tabs.json is 0600 and state/ dir is 0700" $
      withSystemTempDirectory "pureclaw-tabs" $ \root -> do
        let dir = root </> "state"
        saveTabs dir (buildTabs [(sid "x", "X")]) emptyCursors
        dirSt  <- PF.getFileStatus dir
        fileSt <- PF.getFileStatus (dir </> "tabs.json")
        (PF.fileMode dirSt  `PF.intersectFileModes` 0o777) `shouldBe` 0o700
        (PF.fileMode fileSt `PF.intersectFileModes` 0o777) `shouldBe` 0o600

  describe "atomic 0600 create on overwrite" $ do
    -- saveTabs must never expose a world-readable window: the file is
    -- created 0600 via a temp file and atomically renamed over the target.
    -- Overwriting an existing tabs.json keeps it 0600 and leaves no temp
    -- artifact behind in the state dir.
    it "overwriting an existing tabs.json keeps it 0600 with no temp leftovers" $
      withSystemTempDirectory "pureclaw-tabs" $ \root -> do
        let dir = root </> "state"
        -- First write creates the file.
        saveTabs dir (buildTabs [(sid "x", "X")]) emptyCursors
        -- Second write overwrites it (the re-exposure window case).
        saveTabs dir (buildTabs [(sid "y", "Y")]) emptyCursors
        fileSt <- PF.getFileStatus (dir </> "tabs.json")
        (PF.fileMode fileSt `PF.intersectFileModes` 0o777) `shouldBe` 0o600
        -- No temp artifact left behind: the only file is tabs.json.
        entries <- listDirectory dir
        entries `shouldBe` ["tabs.json"]

    it "removes the temp file and rethrows when the final rename fails" $
      withSystemTempDirectory "pureclaw-tabs" $ \root -> do
        let dir = root </> "state"
        -- Pre-create tabs.json as a *directory* so the atomic rename of the
        -- temp file over it fails (EISDIR/ENOTDIR), driving the
        -- bracketOnError cleanup path: the temp file is removed and the
        -- exception propagates.
        createDirectoryIfMissing True (dir </> "tabs.json")
        saveTabs dir (buildTabs [(sid "z", "Z")]) emptyCursors
          `shouldThrow` anyIOException
        -- Cleanup ran: no leftover temp artifact beside the tabs.json dir.
        entries <- listDirectory dir
        entries `shouldBe` ["tabs.json"]

  describe "decode failure → fresh" $
    it "returns (emptyTabs, emptyCursors) on a corrupt tabs.json, no exception" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        writeFile (dir </> "tabs.json") "{ this is not valid json at all >>>"
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        tabs' `shouldBe` emptyTabs
        cursors' `shouldBe` emptyCursors

  describe "decode failure → fresh (missing file)" $
    it "returns fresh when tabs.json does not exist" $
      withSystemTempDirectory "pureclaw-tabs" $ \root -> do
        let dir = root </> "no-state-yet"
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        tabs' `shouldBe` emptyTabs
        cursors' `shouldBe` emptyCursors

  describe "read/open IOException → fresh" $
    -- 'readPersisted' must catch *any* IOException raised while loading the
    -- file, not just a missing file. Making <dir>/tabs.json a *directory* is
    -- the reliable cross-platform trigger: opening/reading a directory's
    -- bytes raises an IOException (on Linux at read/force time, on macOS at
    -- open time). The fix reads strictly ('BS.readFile') and decodes strictly
    -- ('eitherDecodeStrict'') *inside* the 'try', so the failure is caught
    -- wherever it manifests and 'loadTabs' degrades to a fresh start. The old
    -- lazy 'BL.readFile' + 'eitherDecode' forced the bytes inside the decoder
    -- *outside* the guard, letting a read-time IOException escape and crash
    -- boot.
    it "returns fresh when tabs.json is unreadable (path is a directory)" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        createDirectory (dir </> "tabs.json")
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        tabs' `shouldBe` emptyTabs
        cursors' `shouldBe` emptyCursors

  describe "malformed structured JSON → fresh" $ do
    -- These are syntactically valid JSON but violate the codec's enum/tag
    -- contracts, exercising each hand-written parser's failure branch. Every
    -- one must degrade to a fresh start, not crash.
    let freshOn label body =
          it ("returns fresh on " <> label) $
            withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
              writeFile (dir </> "tabs.json") body
              (tabs', cursors') <- loadTabs (allLiveDeps dir)
              tabs' `shouldBe` emptyTabs
              cursors' `shouldBe` emptyCursors
    freshOn "an unknown tab status"
      "{\"tabs\":[{\"ref\":{\"tag\":\"session\",\"sessionId\":\"a\"},\"name\":\"A\",\"status\":\"zombie\"}],\"cursors\":[],\"relay\":[]}"
    freshOn "an unknown TabRef tag"
      "{\"tabs\":[{\"ref\":{\"tag\":\"wat\"},\"name\":\"A\",\"status\":\"live\"}],\"cursors\":[],\"relay\":[]}"
    freshOn "a non-UUID harnessId"
      "{\"tabs\":[{\"ref\":{\"tag\":\"harness\",\"harnessId\":\"not-a-uuid\"},\"name\":\"A\",\"status\":\"live\"}],\"cursors\":[],\"relay\":[]}"
    freshOn "an unknown relay mode"
      "{\"tabs\":[],\"cursors\":[],\"relay\":[{\"channel\":\"cli\",\"conversation\":\"c\",\"mode\":\"blast\"}]}"

  describe "tolerant load" $
    it "de-duplicates a repeated TabRef in the tabs array (keeps one, I2)" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        writeFile (dir </> "tabs.json")
          "{\"tabs\":[\
          \{\"ref\":{\"tag\":\"session\",\"sessionId\":\"dup\"},\"name\":\"First\",\"status\":\"live\"},\
          \{\"ref\":{\"tag\":\"session\",\"sessionId\":\"dup\"},\"name\":\"Second\",\"status\":\"dead\"}\
          \],\"cursors\":[],\"relay\":[]}"
        (tabs', _) <- loadTabs (allLiveDeps dir)
        map _tab_ref (toList tabs') `shouldBe` [sid "dup"]

  describe "session-exists reconcile" $ do
    it "reconcile drops a BoundSession whose session.json is absent, keeps an existing one" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let s1 = "s1valid"
            s2 = "s2missing"
            tabs =
              buildTabs
                [ (sid s1, "Session One")   -- session exists → kept
                , (sid s2, "Session Two")   -- session gone → dropped
                ]
            cursors =
              setCursor (ckey CkCli "c1") (sid s1) $
                setCursor (ckey CkCli "c2") (sid s2) emptyCursors
        saveTabs dir tabs cursors
        let deps =
              PersistDeps
                { _pd_stateDir       = dir
                , _pd_harnessLive    = \_ -> pure True
                , _pd_discoveryReady = pure ()
                , _pd_sessionExists  = \(SessionId t) -> pure (t == s1)
                }
        (tabs', cursors') <- loadTabs deps
        map _tab_ref (toList tabs') `shouldBe` [sid s1]
        Map.keys (_cs_cursors cursors') `shouldBe` [ckey CkCli "c1"]

    it "reconcile keeps a BoundSession whose session.json exists" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let tabs    = buildTabs [(sid "aliveSession", "Alive")]
            cursors = setCursor (ckey CkCli "c1") (sid "aliveSession") emptyCursors
        saveTabs dir tabs cursors
        let deps =
              PersistDeps
                { _pd_stateDir       = dir
                , _pd_harnessLive    = \_ -> pure True
                , _pd_discoveryReady = pure ()
                , _pd_sessionExists  = \_ -> pure True
                }
        (tabs', _) <- loadTabs deps
        map _tab_ref (toList tabs') `shouldBe` [sid "aliveSession"]

    it "loadTabs boots FRESH when tabs.json has a leading-dot/traversal session id" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        -- "." prefix makes isValidSessionId return False → whole-file fresh load
        writeFile (dir </> "tabs.json")
          "{\"tabs\":[\
          \{\"ref\":{\"tag\":\"session\",\"sessionId\":\"../etc\"},\"name\":\"Bad\",\"status\":\"live\"},\
          \{\"ref\":{\"tag\":\"session\",\"sessionId\":\"good1\"},\"name\":\"Good\",\"status\":\"live\"}\
          \],\"cursors\":[],\"relay\":[]}"
        let deps =
              PersistDeps
                { _pd_stateDir       = dir
                , _pd_harnessLive    = \_ -> pure True
                , _pd_discoveryReady = pure ()
                , _pd_sessionExists  = \_ -> pure True
                }
        (tabs', cursors') <- loadTabs deps
        tabs'    `shouldBe` emptyTabs
        cursors' `shouldBe` emptyCursors

  describe "boot reconcile" $ do
    it "drops dead-harness tabs silently, prunes their cursors, keeps provider tabs, awaits discovery" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let tabs =
              buildTabs
                [ (sid "alpha", "Alpha")       -- provider, kept
                , (harnessRef 1, "Live H")     -- harness, live, kept
                , (harnessRef 2, "Dead H")     -- harness, dead, dropped
                ]
            cursors =
              setCursor (ckey CkCli "cli") (sid "alpha") $
                setCursor (ckey CkSignal "g1") (harnessRef 1) $
                  setCursor (ckey CkTelegram "99") (harnessRef 2) emptyCursors
        saveTabs dir tabs cursors

        discoveryFlag <- newIORef (0 :: Int)
        let deps =
              PersistDeps
                { _pd_stateDir       = dir
                , _pd_harnessLive    = \h -> pure (h /= hid 2)
                , _pd_discoveryReady = modifyIORef' discoveryFlag (+ 1)
                , _pd_sessionExists  = \_ -> pure True
                }
        (tabs', cursors') <- loadTabs deps

        -- discovery awaited (at least once) before pruning
        readIORef discoveryFlag `shouldReturn` 1

        -- dead-harness tab dropped; the rest kept (and compacted, I1)
        map _tab_ref (toList tabs')
          `shouldBe` [sid "alpha", harnessRef 1]
        map (unTabIndex . _tab_slot) (toList tabs') `shouldBe` [0, 1]

        -- dead-harness cursor pruned; live ones survive
        Map.keys (_cs_cursors cursors')
          `shouldMatchList` [ckey CkCli "cli", ckey CkSignal "g1"]

    it "keeps a harness tab when its probe reports live" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let tabs    = buildTabs [(harnessRef 1, "Only H")]
            cursors = setCursor (ckey CkCli "cli") (harnessRef 1) emptyCursors
        saveTabs dir tabs cursors
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        map _tab_ref (toList tabs') `shouldBe` [harnessRef 1]
        Map.keys (_cs_cursors cursors') `shouldBe` [ckey CkCli "cli"]

  describe "legacy name back-compat" $ do
    -- A tabs.json written by an older pureclaw carries a per-tab "name" key.
    -- After the _tab_name removal, parseTab must IGNORE that legacy key (the
    -- file still loads), and a subsequent re-encode must DROP it (the new wire
    -- shape no longer carries "name").
    it "loads a legacy tabs.json containing a per-tab name key, then re-encodes without it" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        writeFile (dir </> "tabs.json")
          "{\"tabs\":[\
          \{\"ref\":{\"tag\":\"session\",\"sessionId\":\"legacy\"},\"name\":\"Legacy Name\",\"status\":\"live\"}\
          \],\"cursors\":[],\"relay\":[]}"
        -- Legacy file loads despite the now-unused "name" key.
        (tabs', cursors') <- loadTabs (allLiveDeps dir)
        map _tab_ref (toList tabs') `shouldBe` [sid "legacy"]
        -- Re-encode the loaded registry: the "name" key is gone.
        saveTabs dir tabs' cursors'
        raw <- BL.readFile (dir </> "tabs.json")
        let lowered = T.toLower (TE.decodeUtf8 (BL.toStrict raw))
        ("\"name\"" `T.isInfixOf` lowered) `shouldBe` False
        ("legacy name" `T.isInfixOf` lowered) `shouldBe` False

  describe "no-secrets" $
    it "serialized JSON contains only documented fields" $
      withSystemTempDirectory "pureclaw-tabs" $ \dir -> do
        let tabs =
              buildTabs
                [ (sid "alpha", "Alpha")
                , (harnessRef 1, "Harness One")
                ]
            cursors =
              setCursor (ckey CkCli "cli") (sid "alpha") $
                emptyCursors { _cs_relay =
                                 Map.singleton (ckey CkCli "cli") Firehose }
        saveTabs dir tabs cursors
        raw <- BL.readFile (dir </> "tabs.json")
        let lowered = T.toLower (TE.decodeUtf8 (BL.toStrict raw))
            hasField needle = needle `T.isInfixOf` lowered
        -- forbidden: no secret-bearing or absolute-path fields
        hasField "token"    `shouldBe` False
        hasField "apikey"   `shouldBe` False
        hasField "api_key"  `shouldBe` False
        hasField "password" `shouldBe` False
        hasField "secret"   `shouldBe` False
        hasField "/users/"  `shouldBe` False
        hasField "/home/"   `shouldBe` False
        -- it really is JSON we can re-parse (sanity)
        (Aeson.decode raw :: Maybe Aeson.Value) `shouldSatisfy` (/= Nothing)
