-- |
-- Module      : Integration.TabsSyncSpec
-- Description : WU8 — registry<->frontend sync + boot-persistence wiring.
--
-- Two cross-surface invariants for the Frontend Active-Tabs unification
-- (GitHub #80):
--
--   1. __Dual-write consistency__ (requirement 4): the frontend and the chat
--      surface share ONE 'TabRegistry'. What the frontend appends at slot @N@
--      is exactly the ref the chat @/N@ command resolves at slot @N@ — both
--      read the same 'IORef'. We assert the round trip:
--      'registryAppend' (the frontend write) then 'registryLookupSlot' (the
--      chat read) return the same 'TabRef'.
--
--   2. __Boot-persistence seam__: the substantive WU8 wiring. At boot,
--      "PureClaw.CLI.Commands" runs 'loadTabs' (with @_pd_sessionExists@ a real
--      on-disk @session.json@ check) and SEEDS the shared subsystem registry
--      via 'overwriteTabs' BEFORE the server starts, so the first lists
--      snapshot reflects restored tabs. We drive that exact seam here:
--      'saveTabs' a tab whose @session.json@ exists, 'loadTabs' it back through
--      a 'PersistDeps' whose @_pd_sessionExists@ is 'doesFileExist', then
--      'overwriteTabs' the loaded list into a fresh shared registry and assert
--      'readTabs' reflects it (and that a tab whose @session.json@ is absent is
--      reconciled away before seeding).
module Integration.TabsSyncSpec (spec) where

import Data.ByteString.Lazy qualified as LBS
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Core.Types
  ( ModelId (..)
  , SessionId (..)
  )
import PureClaw.Session.Kind (ProviderSpec (..), SessionKind (..), inferProviderId)
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Handles.Tab (mkTabIndex, unTabIndex)
import PureClaw.Tabs
  ( newTabRegistry
  , overwriteTabs
  , readTabs
  , registryAppend
  , registryLookupSlot
  )
import PureClaw.Tabs.Persist
  ( PersistDeps (..)
  , loadTabs
  , saveTabs
  )
import PureClaw.Tabs.Types
  ( Tab (..)
  , TabRef (..)
  , emptyCursors
  , toList
  )

-- | Write a minimal @session.json@ under @<sessionsDir>/<sid>/@ so that the
-- boot @_pd_sessionExists@ check (a real 'doesFileExist') passes.
writeSessionJson :: FilePath -> SessionId -> IO ()
writeSessionJson sessionsDir (SessionId sid) = do
  let dir = sessionsDir </> T.unpack sid
  createDirectoryIfMissing True dir
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  where
    meta = SessionMeta
      { _sm_id                = SessionId sid
      , _sm_agent             = Nothing
      , _sm_kind              = SkProvider
          (ProviderSpec (inferProviderId "mock") (ModelId "mock") Nothing)
      , _sm_model             = "mock"
      , _sm_channel           = "cli"
      , _sm_createdAt         = epoch
      , _sm_lastActive        = epoch
      , _sm_bootstrapConsumed = True
      , _sm_archived          = False
      , _sm_description       = Nothing
      , _sm_autoSummary       = Nothing
      , _sm_source            = Nothing
      }
    epoch = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)

-- | The boot 'PersistDeps' that "PureClaw.CLI.Commands" constructs in WU8:
-- @_pd_sessionExists@ is the real on-disk @session.json@ probe; harnesses are
-- treated as dead here (no real tmux), discovery is a no-op.
bootDeps :: FilePath -> FilePath -> PersistDeps
bootDeps stateDir sessionsDir =
  PersistDeps
    { _pd_stateDir       = stateDir
    , _pd_harnessLive    = \_ -> pure False
    , _pd_discoveryReady = pure ()
    , _pd_sessionExists  = \(SessionId t) ->
        doesFileExist (sessionsDir </> T.unpack t </> "session.json")
    }

spec :: Spec
spec = do
  describe "dual-write consistency (requirement 4 — shared registry)" $
    it "a frontend-appended BoundSession tab and the chat /N read resolve the SAME ref" $ do
      reg <- newTabRegistry
      let sid = SessionId "cli-20240101-120000-dualw"
      -- The frontend write path: append a BoundSession tab.
      appended <- registryAppend reg (BoundSession sid)
      slot <- case appended of
        Left err   -> fail ("unexpected append failure: " <> show err)
        Right slot -> pure slot
      -- The chat read path (/N): resolve the slot back to its tab.
      mTab <- registryLookupSlot reg slot
      case mTab of
        Nothing  -> fail "slot did not resolve to a tab"
        Just tab -> _tab_ref tab `shouldBe` BoundSession sid

  describe "boot-persistence seam (loadTabs + overwriteTabs seed)" $ do
    it "seeds the shared registry from tabs.json when the session.json exists" $
      withSystemTempDirectory "pureclaw-wu8-seed" $ \root -> do
        let stateDir    = root </> "state"
            sessionsDir = root </> "sessions"
            sid         = SessionId "cli-20240101-120000-seeded"
        createDirectoryIfMissing True stateDir
        writeSessionJson sessionsDir sid
        -- Persist a tab view (the chat surface's saveTabs on /nt).
        srcReg <- newTabRegistry
        _ <- registryAppend srcReg (BoundSession sid)
        srcTabs <- readTabs srcReg
        saveTabs stateDir srcTabs emptyCursors
        -- Boot: load + reconcile, then SEED a FRESH shared registry.
        (loadedTabs, _loadedCursors) <- loadTabs (bootDeps stateDir sessionsDir)
        shared <- newTabRegistry
        overwriteTabs shared loadedTabs
        seeded <- toList <$> readTabs shared
        map _tab_ref seeded `shouldBe` [BoundSession sid]
        map (unTabIndex . _tab_slot) seeded `shouldBe` [0]

    it "reconciles away a tab whose session.json is absent before seeding" $
      withSystemTempDirectory "pureclaw-wu8-drop" $ \root -> do
        let stateDir    = root </> "state"
            sessionsDir = root </> "sessions"
            present     = SessionId "cli-20240101-120000-present"
            absent      = SessionId "cli-20240101-120000-absent"
        createDirectoryIfMissing True stateDir
        writeSessionJson sessionsDir present  -- only the present session exists
        srcReg <- newTabRegistry
        _ <- registryAppend srcReg (BoundSession present)
        _ <- registryAppend srcReg (BoundSession absent)
        srcTabs <- readTabs srcReg
        saveTabs stateDir srcTabs emptyCursors
        (loadedTabs, _) <- loadTabs (bootDeps stateDir sessionsDir)
        shared <- newTabRegistry
        overwriteTabs shared loadedTabs
        seeded <- toList <$> readTabs shared
        map _tab_ref seeded `shouldBe` [BoundSession present]

    it "overwriteTabs replaces any prior contents of the registry" $ do
      let old = SessionId "cli-20240101-120000-old"
          new = SessionId "cli-20240101-120000-new"
      reg <- newTabRegistry
      _ <- registryAppend reg (BoundSession old)
      -- Build the replacement list out-of-band.
      replReg <- newTabRegistry
      _ <- registryAppend replReg (BoundSession new)
      replacement <- readTabs replReg
      overwriteTabs reg replacement
      afterTabs <- toList <$> readTabs reg
      map _tab_ref afterTabs `shouldBe` [BoundSession new]

    it "mkTabIndex 0 resolves the first seeded slot (sanity)" $ do
      reg <- newTabRegistry
      let sid = SessionId "cli-20240101-120000-slot0"
      srcReg <- newTabRegistry
      _ <- registryAppend srcReg (BoundSession sid)
      tabs <- readTabs srcReg
      overwriteTabs reg tabs
      case mkTabIndex 0 of
        Nothing  -> fail "mkTabIndex 0 unexpectedly Nothing"
        Just idx -> do
          mTab <- registryLookupSlot reg idx
          fmap _tab_ref mTab `shouldBe` Just (BoundSession sid)
