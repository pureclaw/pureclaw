module PureClaw.Session.Handle
  ( -- * Session handle (WU1 stub)
    SessionHandle (..)
  , mkNoOpSessionHandle
  , noOpSessionHandle
  ) where

import PureClaw.Handles.Transcript (TranscriptHandle, mkNoOpTranscriptHandle)

-- | Handle for the current conversation session. WU1 only provides a no-op
-- placeholder so the agent loop can compile with the field added to
-- 'PureClaw.Agent.Env.AgentEnv'. WU2 will extend this with metadata
-- persistence, resume, and transcript directory management.
data SessionHandle = SessionHandle
  { _sh_transcript :: TranscriptHandle
    -- ^ Transcript handle owned by the session. In WU1 this is always the
    -- no-op transcript; WU2 replaces it with a per-session file handle.
  , _sh_dir        :: FilePath
    -- ^ On-disk session directory. Empty in WU1.
  }

-- | A no-op session handle for tests and for WU1 (pre-session integration).
mkNoOpSessionHandle :: IO SessionHandle
mkNoOpSessionHandle = pure noOpSessionHandle

-- | Pure no-op session handle. Useful for tests that build 'AgentEnv'
-- records inside pure @let@-bindings without threading 'IO'.
noOpSessionHandle :: SessionHandle
noOpSessionHandle = SessionHandle
  { _sh_transcript = mkNoOpTranscriptHandle
  , _sh_dir        = ""
  }
