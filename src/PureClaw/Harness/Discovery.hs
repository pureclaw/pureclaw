-- | On-demand discovery of adoptable (PureClaw-UNMARKED) tmux windows.
--
-- Discovery is the read-only, user-invoked precursor to adoption (Phase 3,
-- design @docs\/harness-registry.md@ §6, §8 B2\/C1). It answers "which external
-- windows COULD I adopt?" and nothing more:
--
--   * __Lists ALL sessions.__ The adoption allow-list was deliberately dropped
--     (the user picking a session in the foreground New-Tab form IS the
--     consent — enforced at adopt time by 'PureClaw.Security.Adoption'). So a
--     scan enumerates every tmux session and surfaces every UNMARKED, live
--     window regardless of session name. Consent gates adoption, not discovery.
--   * __Metadata-only (§8 C1), by construction.__ A scan returns a transient
--     list of 'DiscoverableWindow' values. A 'DiscoverableWindow' carries NO
--     handle and NO capture capability, so a discovered candidate is
--     structurally incapable of having its pane captured. The scan function
--     itself is only given a @readMarkers@-shaped seam (window metadata) and a
--     @listSessions@-shaped seam — it has no way to call @capture-pane@.
--
-- Discovered candidates are NOT registry entries: they are never inserted into
-- the 'PureClaw.Harness.Registry' and are never managed until an explicit,
-- consent-gated adoption (WU4) promotes one to an @OriginAdopted@ entry.
module PureClaw.Harness.Discovery
  ( -- * Transient discovery result (no handle, no capture)
    DiscoverableWindow (..)
    -- * Bounded, metadata-only scan
  , scanDiscoverable
  , scanDiscoverableIO
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)

import PureClaw.Harness.Tmux (TmuxWindowRow (..), listTmuxSessions, readMarkers)

-- | A single adoptable candidate window surfaced by a discovery scan.
--
-- This is a TRANSIENT, metadata-only value — deliberately NOT a
-- 'PureClaw.Harness.Registry.HarnessEntry'. It carries no 'HarnessHandle' and
-- no capture field, so a discovered candidate cannot be captured or managed
-- (§8 C1 by construction). It is the projection of a tmux window's identifying
-- metadata that the adopt UI needs to present a candidate to the user.
data DiscoverableWindow = DiscoverableWindow
  { _dw_session     :: !Text          -- ^ owning tmux session name
  , _dw_windowName  :: !Text          -- ^ @#{window_name}@ (display only)
  , _dw_windowIndex :: !Int           -- ^ @#{window_index}@ within the session
  , _dw_panePid     :: !(Maybe Int)   -- ^ @#{pane_pid}@ (shell PID), if known
  }
  deriving stock (Eq, Show)

-- | JSON shape consumed by the discovery endpoint / frontend. Snake-cased
-- keys: @session@, @window_name@, @window_index@, @pane_pid@.
instance ToJSON DiscoverableWindow where
  toJSON dw = object
    [ "session"      .= _dw_session dw
    , "window_name"  .= _dw_windowName dw
    , "window_index" .= _dw_windowIndex dw
    , "pane_pid"     .= _dw_panePid dw
    ]

-- | Scan for adoptable windows across ALL sessions, METADATA-ONLY.
--
-- Seamed for testability and for the §8 C1 structural guarantee — the function
-- is given only:
--
--   * a @readMarkers@-shaped seam returning per-window metadata rows, and
--   * a @listSessions@-shaped seam returning the server's session names.
--
-- It has NO capture-pane seam, so it is structurally incapable of capturing a
-- pane. Logic:
--
--   1. list all sessions (the allow-list was dropped — consent gates adoption,
--      not discovery);
--   2. for each session, read its window metadata rows;
--   3. keep rows that are UNMARKED (@_twr_pclId == ""@ — not already ours) AND
--      not @pane_dead@;
--   4. project each surviving row into a 'DiscoverableWindow'.
--
-- Pure-ish: all IO is in the injected seams, so the filtering logic is fully
-- unit-testable.
scanDiscoverable
  :: (Text -> IO [TmuxWindowRow])      -- ^ @readMarkers@-shaped seam
  -> IO [Text]                         -- ^ @listTmuxSessions@-shaped seam
  -> IO [DiscoverableWindow]
scanDiscoverable readMarkersSeam listSessionsSeam = do
  sessions <- listSessionsSeam
  concat <$> mapM scanSession sessions
  where
    scanSession :: Text -> IO [DiscoverableWindow]
    scanSession session = do
      rows <- readMarkersSeam session
      pure [ toDiscoverable session row | row <- rows, isAdoptable row ]

    isAdoptable :: TmuxWindowRow -> Bool
    isAdoptable row = _twr_pclId row == "" && not (_twr_paneDead row)

    toDiscoverable :: Text -> TmuxWindowRow -> DiscoverableWindow
    toDiscoverable session row = DiscoverableWindow
      { _dw_session     = session
      , _dw_windowName  = _twr_windowName row
      , _dw_windowIndex = _twr_windowIndex row
      , _dw_panePid     = _twr_panePid row
      }

-- | Production wrapper: scan the real tmux server (ALL sessions) using the real
-- metadata-only tmux seams. Wires 'readMarkers' and 'listTmuxSessions' into
-- 'scanDiscoverable'. Like 'scanDiscoverable', it never captures a pane.
scanDiscoverableIO :: IO [DiscoverableWindow]
scanDiscoverableIO = scanDiscoverable readMarkers listTmuxSessions
