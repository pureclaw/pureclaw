-- | Turn-content provider seam (Harness log content source — Task 4).
--
-- A 'TurnProvider' is the source of a harness turn's text, a finalize signal,
-- and an optional stable turn id, consumed by the reconcile loop's
-- content-driven turn watcher ('PureClaw.Harness.Reconcile.stepTurns'). It
-- decouples /where/ a turn's text comes from (tmux screen capture today, the
-- claude JSONL log later) from the loop that streams + finalizes it.
--
-- This module is a LEAF below "PureClaw.Harness.Reconcile" — it must NOT import
-- Reconcile (Reconcile imports this for 'TurnProvider'). Keeping it a leaf
-- avoids an import cycle.
--
-- == The two built-in providers
--
--   * 'tmuxProvider' — preserves today's behavior VERBATIM: the turn text is
--     the handle's '_hh_snapshotTurn', it never finalizes itself
--     (@finalized = False@), and it derives no id (@_tp_turnId = pure Nothing@,
--     so the loop falls back to its '_rd_mintTurn'). The tmux path stays
--     byte-identical.
--   * 'nullProvider' — a handle-less entry: empty text, never finalizes, no
--     derived id.
--
-- The log provider (Task 5) supplies a non-trivial '_tp_snapshot' whose
-- @finalized@ flag is an AUTHORITATIVE finalize and a '_tp_turnId' that derives
-- a stable id from the JSONL event — wired in later; the seam lives here.
module PureClaw.Harness.LogProvider
  ( TurnProvider (..)
  , tmuxProvider
  , nullProvider
  ) where

import Data.Text (Text)
import Data.Time (UTCTime)

import PureClaw.Handles.Harness (HarnessHandle (..))

-- | The source of a harness turn's content for the reconcile loop.
--
--   * '_tp_snapshot' returns @(currentTurnText, finalized?)@. @finalized == True@
--     is an authoritative finalize that bypasses the loop's idle-stability guard.
--   * '_tp_turnId' returns @Just (derivedId, ts)@ to pin a stable id + the
--     turn's timestamp (the log provider derives both from the JSONL event), or
--     'Nothing' to fall back to the loop's @_rd_mintTurn :: IO (Text, UTCTime)@.
--     Carrying the timestamp avoids a second clock call — 'mkTurnEntry' needs
--     both the id AND a 'UTCTime'.
data TurnProvider = TurnProvider
  { _tp_snapshot :: IO (Text, Bool)
    -- ^ @(currentTurnText, finalized?)@
  , _tp_turnId   :: IO (Maybe (Text, UTCTime))
    -- ^ @Just (derivedId, ts)@ for the log provider; 'Nothing' → fall back to
    --   @_rd_mintTurn@.
  }

-- | The tmux content provider: text from '_hh_snapshotTurn', never finalizes,
-- derives no id. Preserves today's tmux behavior verbatim.
tmuxProvider :: HarnessHandle -> TurnProvider
tmuxProvider hh = TurnProvider
  { _tp_snapshot = (,) <$> _hh_snapshotTurn hh <*> pure False
  , _tp_turnId   = pure Nothing
  }

-- | A provider for a handle-less entry: empty text, never finalizes, no id.
nullProvider :: TurnProvider
nullProvider = TurnProvider
  { _tp_snapshot = pure ("", False)
  , _tp_turnId   = pure Nothing
  }
