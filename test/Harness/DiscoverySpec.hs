-- | Tests for on-demand discovery of adoptable (unmarked) tmux windows
-- (Phase 3, WU2; adoption-UX-rework WU1). Discovery is METADATA-ONLY and now
-- LISTS ALL sessions (the adoption allow-list was dropped — consent is the
-- gate, applied at adopt time, not at discovery time). Design
-- @docs\/harness-registry.md@ §6, §8 B4\/C1.
--
-- Every test injects seams in place of the real tmux IO:
--
--   * a @listSessions@ seam (stands in for 'listTmuxSessions'), and
--   * a @readMarkers@ seam (stands in for 'readMarkers').
--
-- 'scanDiscoverable' is given NO capture-pane seam at all — it is
-- structurally incapable of capturing a pane (C1 by construction).
module Harness.DiscoverySpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import PureClaw.Harness.Discovery
import PureClaw.Harness.Tmux (TmuxWindowRow (..))

-- | A marked window row (has a non-empty @pcl_id — already managed by us).
markedRow :: Int -> Text -> Text -> TmuxWindowRow
markedRow idx name pclId = TmuxWindowRow
  { _twr_windowIndex = idx
  , _twr_windowName  = name
  , _twr_pclId       = pclId
  , _twr_panePid     = Just (1000 + idx)
  , _twr_paneDead    = False
  }

-- | An unmarked, live window row (a genuine adoption candidate).
unmarkedRow :: Int -> Text -> TmuxWindowRow
unmarkedRow idx name = TmuxWindowRow
  { _twr_windowIndex = idx
  , _twr_windowName  = name
  , _twr_pclId       = ""
  , _twr_panePid     = Just (2000 + idx)
  , _twr_paneDead    = False
  }

-- | An unmarked but DEAD window (pane process exited) — must be excluded.
deadUnmarkedRow :: Int -> Text -> TmuxWindowRow
deadUnmarkedRow idx name = (unmarkedRow idx name) { _twr_paneDead = True }

-- | A fixture server: TWO sessions. @work@ has a mix of marked + unmarked +
-- dead windows; @home@ has its own unmarked + dead windows. With the
-- allow-list dropped, BOTH sessions' unmarked-live windows are discoverable —
-- regardless of session name.
fixtureSessions :: [Text]
fixtureSessions = ["work", "home"]

fixtureMarkers :: Text -> [TmuxWindowRow]
fixtureMarkers "work" =
  [ markedRow 0 "claude-code-abc" "11111111-1111-1111-1111-111111111111"
  , unmarkedRow 1 "vim"
  , unmarkedRow 2 "build"
  , deadUnmarkedRow 3 "stale-shell"
  ]
fixtureMarkers "home" =
  [ unmarkedRow 0 "secrets"          -- now DISCOVERABLE (no allow-list)
  , deadUnmarkedRow 1 "home-dead"    -- excluded: pane_dead
  ]
fixtureMarkers _ = []

-- | Build a counting @readMarkers@ seam: returns the fixture rows AND records
-- which session names it was asked to read (so a test can assert ALL sessions
-- are read now that discovery is unbounded).
countingReadMarkers :: IO (Text -> IO [TmuxWindowRow], IORef [Text])
countingReadMarkers = do
  callsRef <- newIORef []
  let seam s = do
        modifyIORef' callsRef (++ [s])
        pure (fixtureMarkers s)
  pure (seam, callsRef)

spec :: Spec
spec = do
  describe "scanDiscoverable (list-all — allow-list dropped, consent-gated at adopt)" $ do
    it "W1.4 lists unmarked+live windows across ALL sessions, regardless of session name" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable seam (pure fixtureSessions)
      result `shouldBe`
        [ DiscoverableWindow
            { _dw_session     = "work"
            , _dw_windowName  = "vim"
            , _dw_windowIndex = 1
            , _dw_panePid     = Just 2001
            }
        , DiscoverableWindow
            { _dw_session     = "work"
            , _dw_windowName  = "build"
            , _dw_windowIndex = 2
            , _dw_panePid     = Just 2002
            }
        , DiscoverableWindow
            { _dw_session     = "home"
            , _dw_windowName  = "secrets"
            , _dw_windowIndex = 0
            , _dw_panePid     = Just 2000
            }
        ]

    it "W1.4 reads EVERY session (unbounded enumeration — no allow-list filter)" $ do
      (seam, callsRef) <- countingReadMarkers
      _ <- scanDiscoverable seam (pure fixtureSessions)
      calls <- readIORef callsRef
      -- Both 'work' AND 'home' are read now (previously 'home' was skipped).
      calls `shouldBe` ["work", "home"]

    it "W1.4 never returns a window carrying a non-empty @pcl_id (still ours-only excluded)" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable seam (pure fixtureSessions)
      map _dw_windowName result `shouldNotContain` ["claude-code-abc"]

    it "W1.4 excludes a pane_dead window even when unmarked (in any session)" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable seam (pure fixtureSessions)
      map _dw_windowName result `shouldNotContain` ["stale-shell", "home-dead"]

    it "W1.4 an empty server yields an empty result" $ do
      result <- scanDiscoverable (\_ -> pure []) (pure [])
      result `shouldBe` []

  describe "DiscoverableWindow ToJSON" $ do
    it "D2.5 encodes snake_case keys (session/window_name/window_index/pane_pid)" $ do
      let dw = DiscoverableWindow
            { _dw_session     = "work"
            , _dw_windowName  = "vim"
            , _dw_windowIndex = 1
            , _dw_panePid     = Just 2001
            }
      jsonKey dw "session"      `shouldBe` Just (Aeson.String "work")
      jsonKey dw "window_name"  `shouldBe` Just (Aeson.String "vim")
      jsonKey dw "window_index" `shouldBe` Just (Aeson.Number 1)
      jsonKey dw "pane_pid"     `shouldBe` Just (Aeson.Number 2001)

    it "D2.5 encodes a null pane_pid as JSON null" $ do
      let dw = DiscoverableWindow
            { _dw_session     = "work"
            , _dw_windowName  = "vim"
            , _dw_windowIndex = 1
            , _dw_panePid     = Nothing
            }
      jsonKey dw "pane_pid" `shouldBe` Just Aeson.Null

-- | Look up a key in the JSON encoding of a 'DiscoverableWindow'.
jsonKey :: DiscoverableWindow -> Text -> Maybe Aeson.Value
jsonKey dw k =
  case Aeson.toJSON dw of
    Aeson.Object o -> KM.lookup (AesonKey.fromText k) o
    _              -> Nothing
