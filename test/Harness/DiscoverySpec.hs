-- | Tests for on-demand discovery of adoptable (unmarked) tmux windows
-- (Phase 3, WU2). Discovery is METADATA-ONLY and BOUNDED to the adoption
-- allow-list (design @docs\/harness-registry.md@ §6, §8 B4\/C1).
--
-- Every test injects seams in place of the real tmux IO:
--
--   * a @listSessions@ seam (stands in for 'listTmuxSessions'), and
--   * a @readMarkers@ seam (stands in for 'readMarkers').
--
-- 'scanDiscoverable' is given NO capture-pane seam at all — it is
-- structurally incapable of capturing a pane (C1 by construction). The tests
-- also count seam calls to prove the scan reads ONLY allow-listed sessions
-- (B4 — bounded enumeration).
module Harness.DiscoverySpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.IORef
import Data.Text (Text)
import Test.Hspec

import PureClaw.Harness.Discovery
import PureClaw.Harness.Tmux (TmuxWindowRow (..))
import PureClaw.Security.Policy (SessionPattern, parseSessionPattern)

-- | Parse a pattern the test author KNOWS is well-formed. Fails loudly rather
-- than silently producing an empty allow-list (which would make a deny test
-- pass for the wrong reason).
mustParse :: Text -> SessionPattern
mustParse t = case parseSessionPattern t of
  Just p  -> p
  Nothing -> error ("test setup: parseSessionPattern rejected " <> show t)

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

-- | A fixture server: two sessions. @work@ has a mix of marked + unmarked +
-- dead windows; @home@ is NOT allow-listed and should never be read.
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
  [ unmarkedRow 0 "secrets" ]   -- never read: 'home' is not allow-listed
fixtureMarkers _ = []

-- | Build a counting @readMarkers@ seam: returns the fixture rows AND records
-- which session names it was asked to read (so a test can assert that only
-- allow-listed sessions were ever read — B4).
countingReadMarkers :: IO (Text -> IO [TmuxWindowRow], IORef [Text])
countingReadMarkers = do
  callsRef <- newIORef []
  let seam s = do
        modifyIORef' callsRef (++ [s])
        pure (fixtureMarkers s)
  pure (seam, callsRef)

spec :: Spec
spec = do
  describe "scanDiscoverable" $ do
    it "D2.1 returns ONLY unmarked, live windows in allow-listed sessions" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable [mustParse "work"] seam (pure fixtureSessions)
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
        ]

    it "D2.2 empty allow-list -> empty result (no session scanned)" $ do
      (seam, callsRef) <- countingReadMarkers
      result <- scanDiscoverable [] seam (pure fixtureSessions)
      result `shouldBe` []
      calls <- readIORef callsRef
      calls `shouldBe` []   -- nothing read at all

    it "D2.3 never returns a window carrying a non-empty @pcl_id" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable [mustParse "work"] seam (pure fixtureSessions)
      map _dw_windowName result `shouldNotContain` ["claude-code-abc"]

    it "D2.3 excludes a pane_dead window even when unmarked" $ do
      (seam, _) <- countingReadMarkers
      result <- scanDiscoverable [mustParse "work"] seam (pure fixtureSessions)
      map _dw_windowName result `shouldNotContain` ["stale-shell"]

    it "D2.4 reads ONLY allow-listed sessions (bounded enumeration, B4)" $ do
      (seam, callsRef) <- countingReadMarkers
      _ <- scanDiscoverable [mustParse "work"] seam (pure fixtureSessions)
      calls <- readIORef callsRef
      -- 'home' is present on the server but NOT allow-listed: never read.
      calls `shouldBe` ["work"]
      calls `shouldNotContain` ["home"]

    it "D2.4 a prefix pattern bounds the scan to matching sessions" $ do
      (seam, callsRef) <- countingReadMarkers
      _ <- scanDiscoverable [mustParse "wor*"] seam (pure fixtureSessions)
      calls <- readIORef callsRef
      calls `shouldBe` ["work"]

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
