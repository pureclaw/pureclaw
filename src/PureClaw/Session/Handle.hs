module PureClaw.Session.Handle
  ( -- * Session handle
    SessionHandle (..)
  , mkSessionHandle
  , mkNoOpSessionHandle
  , noOpSessionHandle
  , noOpOnFirstStreamDoneRef
    -- * Resume
  , ResumeError (..)
  , resumeSession
    -- * Enumeration and lookup
  , listSessions
  , ResolveError (..)
  , resolveSessionRef
    -- * Runtime validation
  , ResolvedRuntime (..)
  , validateRuntime
  , resolveResumedTarget
    -- * Bootstrap consumption
  , markBootstrapConsumed
    -- * Archive flag (disk-only)
  , setArchived
  , SetArchivedError (..)
    -- * Description (disk-only)
  , setDescription
  , SetDescriptionError (..)
    -- * Resume context reload
  , loadRecentMessages
  ) where

import Control.Exception (IOException, try)
import System.IO.Unsafe (unsafePerformIO)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , renameFile
  )
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

import PureClaw.Agent.AgentDef (AgentName)
import PureClaw.Agent.Compaction (compactionMetadataKey)
import PureClaw.Core.Types
  ( MessageTarget (..)
  , ModelId (..)
  , SessionId (..)
  , parseSessionId
  )
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Handles.Transcript
  ( TranscriptHandle (..)
  , mkFileTranscriptHandle
  , mkNoOpTranscriptHandle
  )
import PureClaw.Providers.Class
  ( ContentBlock (..)
  , Message (..)
  , Role (..)
  )
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , TranscriptFilter (..)
  )
import PureClaw.Session.Types
  ( SessionKind (..)
  , SessionMeta (..)
  , ProviderSpec (..)
  , HarnessSpec (..)
  , HarnessFlavour (..)
  , inferProviderId
  )

-- ----------------------------------------------------------------------------
-- Types
-- ----------------------------------------------------------------------------

-- | Handle for the current conversation session.
--
-- Owns the on-disk session directory (mode @0o700@), the @session.json@
-- metadata file (mode @0o600@), and the per-session transcript handle
-- writing to @transcript.jsonl@ (mode @0o600@).
data SessionHandle = SessionHandle
  { _sh_meta       :: IORef SessionMeta
    -- ^ Mutable session metadata. Updated by callers (e.g. to bump
    -- @last_active@) and persisted by '_sh_save'.
  , _sh_transcript :: TranscriptHandle
    -- ^ Transcript handle owned by the session.
  , _sh_dir        :: FilePath
    -- ^ On-disk session directory, i.e. @<baseDir>/<sessionId>/@.
  , _sh_save       :: IO ()
    -- ^ Persist '_sh_meta' to @session.json@ atomically (write to
    -- @session.json.tmp@ then rename).
  }

-- | Reasons a resume attempt can fail.
data ResumeError
  = ResumeMissingMetadata FilePath
    -- ^ No @session.json@ at the expected path.
  | ResumeCorruptedMetadata FilePath String
    -- ^ @session.json@ exists but does not parse as 'SessionMeta'.
    -- The second field is a human-readable recovery hint.
  deriving stock (Show, Eq)

-- | Lookup result for 'resolveSessionRef'.
data ResolveError
  = NotFound
  | Ambiguous [SessionId]
  deriving stock (Show, Eq)

-- | Result of 'validateRuntime'. 'RuntimeFallback' carries the chosen
-- fallback target plus a warning message suitable for logging.
data ResolvedRuntime
  = RuntimeOk MessageTarget
  | RuntimeFallback MessageTarget Text
  deriving stock (Show, Eq)

-- ----------------------------------------------------------------------------
-- Creation
-- ----------------------------------------------------------------------------

-- | Create a brand-new on-disk session handle.
--
-- Creates @\<baseDir\>/\<sessionId\>/@ with mode @0o700@, writes the
-- initial @session.json@ (mode @0o600@) via 'saveMeta', and opens
-- @transcript.jsonl@ (mode @0o600@) through 'mkFileTranscriptHandle'.
mkSessionHandle :: LogHandle -> FilePath -> SessionMeta -> IO SessionHandle
mkSessionHandle logger baseDir meta = do
  let sid  = unSessionId (_sm_id meta)
      dir  = baseDir </> T.unpack sid
      txp  = dir </> "transcript.jsonl"
  createDirectoryIfMissing True dir
  setFileMode dir 0o700
  metaRef <- newIORef meta
  saveMeta dir metaRef
  tx <- mkFileTranscriptHandle logger txp
  pure SessionHandle
    { _sh_meta       = metaRef
    , _sh_transcript = tx
    , _sh_dir        = dir
    , _sh_save       = saveMeta dir metaRef
    }

-- | Atomically persist the metadata IORef to @\<dir\>/session.json@ by
-- writing to a sibling @session.json.tmp@ with mode @0o600@ then
-- 'renameFile'-ing it into place. The rename is atomic on POSIX, so a
-- crash mid-write leaves the previous @session.json@ intact.
saveMeta :: FilePath -> IORef SessionMeta -> IO ()
saveMeta dir ref = do
  meta <- readIORef ref
  let finalP = dir </> "session.json"
      tmpP   = finalP <> ".tmp"
  LBS.writeFile tmpP (Aeson.encode meta)
  setFileMode tmpP 0o600
  renameFile tmpP finalP

-- ----------------------------------------------------------------------------
-- No-op handle
-- ----------------------------------------------------------------------------

-- | A no-op session handle for tests and for the backward-compat
-- no-session path.
mkNoOpSessionHandle :: IO SessionHandle
mkNoOpSessionHandle = do
  ref <- newIORef noOpMeta
  pure SessionHandle
    { _sh_meta       = ref
    , _sh_transcript = mkNoOpTranscriptHandle
    , _sh_dir        = ""
    , _sh_save       = pure ()
    }

-- | Pure no-op session handle placeholder — kept for the many test
-- call sites that need a 'SessionHandle' inside a pure @let@ binding.
-- Prefer 'mkNoOpSessionHandle' anywhere IO is already in scope.
--
-- The '_sh_meta' 'IORef' is created once at module load via
-- 'unsafePerformIO' with 'NOINLINE' so every reference shares the
-- same sentinel cell.
noOpSessionHandle :: SessionHandle
noOpSessionHandle = SessionHandle
  { _sh_meta       = noOpMetaRef
  , _sh_transcript = mkNoOpTranscriptHandle
  , _sh_dir        = ""
  , _sh_save       = pure ()
  }

{-# NOINLINE noOpMetaRef #-}
noOpMetaRef :: IORef SessionMeta
noOpMetaRef = unsafePerformIO (newIORef noOpMeta)

-- | Shared no-op callback slot for tests that do not care about
-- bootstrap consumption. Equivalent in spirit to 'noOpMetaRef': tests
-- that only READ or only set-to-'Nothing' can share the same cell.
-- Tests that need to OBSERVE the callback firing should create their
-- own @IORef (Maybe (IO ()))@ rather than using this sentinel.
{-# NOINLINE noOpOnFirstStreamDoneRef #-}
noOpOnFirstStreamDoneRef :: IORef (Maybe (IO ()))
noOpOnFirstStreamDoneRef = unsafePerformIO (newIORef Nothing)

-- | Static default metadata for no-op handles.
noOpMeta :: SessionMeta
noOpMeta = SessionMeta
  { _sm_id                = parseSessionId "noop"
  , _sm_agent             = Nothing
  , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "") (ModelId "") Nothing)
  , _sm_model             = ""
  , _sm_channel           = ""
  , _sm_createdAt         = epoch
  , _sm_lastActive        = epoch
  , _sm_bootstrapConsumed = False
  , _sm_archived          = False
  , _sm_description       = Nothing
  , _sm_autoSummary       = Nothing
  }
  where
    epoch = UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0)

-- ----------------------------------------------------------------------------
-- Resume
-- ----------------------------------------------------------------------------

-- | Reopen an existing session by ID. Reads @session.json@, validates
-- the JSON, and reopens @transcript.jsonl@ for append.
resumeSession
  :: LogHandle
  -> FilePath
  -> SessionId
  -> IO (Either ResumeError SessionHandle)
resumeSession logger baseDir sid = do
  let dir    = baseDir </> T.unpack (unSessionId sid)
      metaP  = dir </> "session.json"
      txP    = dir </> "transcript.jsonl"
  exists <- doesFileExist metaP
  if not exists
    then pure (Left (ResumeMissingMetadata metaP))
    else do
      raw <- LBS.readFile metaP
      case Aeson.eitherDecode' raw of
        Left err -> pure
          (Left (ResumeCorruptedMetadata metaP
            ("failed to parse session metadata: " <> err
              <> " — recovery hint: inspect or remove " <> metaP)))
        Right meta -> do
          metaRef <- newIORef (meta :: SessionMeta)
          tx <- mkFileTranscriptHandle logger txP
          pure (Right SessionHandle
            { _sh_meta       = metaRef
            , _sh_transcript = tx
            , _sh_dir        = dir
            , _sh_save       = saveMeta dir metaRef
            })

-- ----------------------------------------------------------------------------
-- Enumeration and lookup
-- ----------------------------------------------------------------------------

-- | Read all @session.json@ files under @baseDir@, optionally filtering
-- by agent name, sorted by @last_active@ descending, and capped at
-- @limit@ entries.
--
-- Silently skips entries that fail to decode so that a single corrupted
-- metadata file does not hide the remaining sessions from the user.
listSessions :: FilePath -> Maybe AgentName -> Int -> IO [SessionMeta]
listSessions baseDir mAgent limit = do
  exists <- doesDirectoryExist baseDir
  if not exists
    then pure []
    else do
      entries <- listDirectory baseDir
      metas <- fmap catMaybes' (traverse (tryLoad baseDir) entries)
      let filtered = case mAgent of
            Nothing -> metas
            Just a  -> filter (\m -> _sm_agent m == Just a) metas
          sorted = sortOn (Down . _sm_lastActive) filtered
      pure (take limit sorted)
  where
    catMaybes' = foldr (\mx acc -> case mx of
                          Just x  -> x : acc
                          Nothing -> acc) []

-- | Attempt to load @\<baseDir\>/\<name\>/session.json@. Returns
-- 'Nothing' if the path is not a directory, the metadata file is
-- missing, unreadable, or malformed.
tryLoad :: FilePath -> FilePath -> IO (Maybe SessionMeta)
tryLoad baseDir name = do
  let dir   = baseDir </> name
      metaP = dir </> "session.json"
  isDir <- doesDirectoryExist dir
  if not isDir
    then pure Nothing
    else do
      exists <- doesFileExist metaP
      if not exists
        then pure Nothing
        else do
          eBytes <- try (LBS.readFile metaP) :: IO (Either IOException LBS.ByteString)
          case eBytes of
            Left _     -> pure Nothing
            Right raw  -> case Aeson.decode' raw of
              Just m  -> pure (Just m)
              Nothing -> pure Nothing

-- | Resolve a user-supplied reference (exact ID or prefix) to a concrete
-- 'SessionId'. Exact matches win outright; otherwise the match set is
-- computed by 'T.isPrefixOf' over the full ID string.
resolveSessionRef
  :: FilePath
  -> Text
  -> IO (Either ResolveError SessionId)
resolveSessionRef baseDir ref = do
  exists <- doesDirectoryExist baseDir
  if not exists
    then pure (Left NotFound)
    else do
      entries <- listDirectory baseDir
      -- Keep only entries that actually have a session.json — avoids
      -- matching stray directories created by unrelated tests or users.
      valid <- filterM hasMetadata entries
      let ids = map (SessionId . T.pack) valid
      if ref `elem` map (\(SessionId t) -> t) ids
        then pure (Right (SessionId ref))
        else case filter (\(SessionId t) -> ref `T.isPrefixOf` t) ids of
          []  -> pure (Left NotFound)
          [x] -> pure (Right x)
          xs  -> pure (Left (Ambiguous xs))
  where
    hasMetadata name = do
      let metaP = baseDir </> name </> "session.json"
      doesFileExist metaP

    -- Local strict filterM to avoid pulling in Control.Monad just for this.
    filterM _ []     = pure []
    filterM p (x:xs) = do
      keep <- p x
      rest <- filterM p xs
      pure (if keep then x : rest else rest)

-- ----------------------------------------------------------------------------
-- Runtime validation
-- ----------------------------------------------------------------------------

-- | Validate a 'SessionKind' against the currently-running harnesses.
--
-- * 'SkProvider' always resolves to @RuntimeOk TargetProvider@.
-- * @'SkHarness' spec@ resolves to @RuntimeOk (TargetHarness name)@ if
--   a harness with that name is present in the map (name derived from
--   the harness flavour).
-- * @'SkHarness' spec@ resolves to @RuntimeFallback TargetProvider msg@
--   if the harness is absent, where @msg@ explains the fallback for
--   logging at warn level.
validateRuntime :: Map Text HarnessHandle -> SessionKind -> ResolvedRuntime
validateRuntime _ (SkProvider _) = RuntimeOk TargetProvider
validateRuntime harnesses (SkHarness spec) =
  let name = sessionKindHarnessName spec
  in if Map.member name harnesses
       then RuntimeOk (TargetHarness name)
       else let msg = "harness '" <> name <> "' is not running, falling back to provider"
            in RuntimeFallback TargetProvider msg

-- | Extract the harness name from a 'HarnessSpec' by rendering its flavour.
sessionKindHarnessName :: HarnessSpec -> Text
sessionKindHarnessName spec = case _h_flavour spec of
  HClaudeCode -> "claude-code"
  HCodex      -> "codex"
  HOpenCode   -> "opencode"
  HHermes     -> "hermes"
  HPureClaw   -> "pureclaw"
  HCustom n   -> n

-- | Resolve a resumed session's 'SessionKind' to a concrete
-- 'MessageTarget' given the currently-running harness map, logging a
-- warning if the recorded runtime is no longer available.
--
-- Wraps 'validateRuntime': on 'RuntimeFallback' the provided warning
-- message is routed to @_lh_logWarn@ and the fallback target (always
-- 'TargetProvider') is returned; on 'RuntimeOk' the target is returned
-- without logging.
resolveResumedTarget
  :: LogHandle
  -> Map Text HarnessHandle
  -> SessionKind
  -> IO MessageTarget
resolveResumedTarget logger harnesses sk = case validateRuntime harnesses sk of
  RuntimeOk tgt -> pure tgt
  RuntimeFallback tgt warning -> do
    _lh_logWarn logger warning
    pure tgt

-- ----------------------------------------------------------------------------
-- Bootstrap consumption
-- ----------------------------------------------------------------------------

-- | Flip '_sm_bootstrapConsumed' to 'True' in the session metadata
-- 'IORef' and persist the change to @session.json@ via '_sh_save'.
--
-- Called by the agent loop the first time a provider response completes
-- ('StreamDone'), via the one-shot callback installed on
-- @_env_onFirstStreamDone@. Idempotent: re-invocations re-save the same
-- metadata without error.
markBootstrapConsumed :: SessionHandle -> IO ()
markBootstrapConsumed sh = do
  atomicModifyIORef' (_sh_meta sh) $ \m ->
    (m { _sm_bootstrapConsumed = True }, ())
  _sh_save sh

-- ----------------------------------------------------------------------------
-- Archive flag
-- ----------------------------------------------------------------------------

-- | Reasons 'setArchived' may fail. The session directory and transcript
-- are never touched, so failure leaves on-disk state unchanged.
data SetArchivedError
  = SetArchivedSessionMissing
    -- ^ @\<baseDir\>/\<sid\>/session.json@ does not exist.
  | SetArchivedParseFailed Text
    -- ^ session.json was unreadable or did not decode as 'SessionMeta'.
  deriving stock (Show, Eq)

-- | Toggle 'SessionMeta._sm_archived' for a session that may or may not
-- have a live 'SessionHandle'. Operates directly on the on-disk
-- @session.json@: reads, updates the archive flag, writes back via the
-- usual tmp-file + rename atomicity pattern.
--
-- Crucially, this is **display state only** — neither the session
-- directory nor the transcript is removed. Unarchiving restores the
-- session to "Recent Sessions" with all history intact.
setArchived :: FilePath -> SessionId -> Bool -> IO (Either SetArchivedError ())
setArchived baseDir sid archived =
  updateSessionMeta baseDir sid (\m -> m { _sm_archived = archived })
    SetArchivedSessionMissing SetArchivedParseFailed

-- | Reasons 'setDescription' may fail. Same shape as 'SetArchivedError'.
data SetDescriptionError
  = SetDescriptionSessionMissing
  | SetDescriptionParseFailed Text
  deriving stock (Show, Eq)

-- | Set or clear the user-provided session description. Passing 'Just t'
-- stores the description (trimmed of surrounding whitespace; an empty
-- result is treated as 'Nothing' so callers can pass through what the
-- user typed without preprocessing). Passing 'Nothing' clears it,
-- letting display surfaces fall back to '_sm_autoSummary' or a
-- transcript-derived snippet.
setDescription :: FilePath -> SessionId -> Maybe Text -> IO (Either SetDescriptionError ())
setDescription baseDir sid mDesc =
  let normalized = mDesc >>= \t -> let s = T.strip t in if T.null s then Nothing else Just s
  in  updateSessionMeta baseDir sid (\m -> m { _sm_description = normalized })
        SetDescriptionSessionMissing SetDescriptionParseFailed

-- | Shared read-modify-write helper for the disk-only meta mutators.
-- Reads @session.json@, applies @f@, and writes back via tmp-file +
-- rename. @missing@ and @parseFail@ are the caller's error
-- constructors so each public mutator returns its own error type.
updateSessionMeta
  :: FilePath
  -> SessionId
  -> (SessionMeta -> SessionMeta)
  -> e
  -> (Text -> e)
  -> IO (Either e ())
updateSessionMeta baseDir sid f missing parseFail = do
  let dir    = baseDir </> T.unpack (unSessionId sid)
      finalP = dir </> "session.json"
      tmpP   = finalP <> ".tmp"
  exists <- doesFileExist finalP
  if not exists
    then pure (Left missing)
    else do
      eBytes <- try (LBS.readFile finalP) :: IO (Either IOException LBS.ByteString)
      case eBytes of
        Left e -> pure (Left (parseFail (T.pack (show e))))
        Right raw -> case Aeson.eitherDecode' raw of
          Left  err  -> pure (Left (parseFail (T.pack err)))
          Right meta -> do
            LBS.writeFile tmpP (Aeson.encode (f meta))
            setFileMode tmpP 0o600
            renameFile tmpP finalP
            pure (Right ())

-- ----------------------------------------------------------------------------
-- Resume context reload
-- ----------------------------------------------------------------------------

-- | Load a bounded window of recent 'Message' values from a session's
-- transcript, oldest-first.
--
-- @loadRecentMessages th maxCount maxTokens@ reads every recorded
-- transcript entry via '_th_query', converts each to a text 'Message'
-- (mapping 'Request' → 'User' and 'Response' → 'Assistant'), keeps at
-- most the last @maxCount@, then walks that window from newest back to
-- oldest accumulating an estimated token budget (computed as
-- @T.length payload `div` 4@ — a rough heuristic, not a true tokenizer).
-- Once the budget is exhausted no further messages are added.
--
-- If the transcript contains a compaction boundary (an entry whose
-- metadata includes the 'compactionMetadataKey'), only entries from the
-- last such boundary onward are considered.  The compaction entry itself
-- is included — its payload carries the summary text that replaces the
-- earlier conversation.  This ensures that after a gateway restart the
-- agent resumes with the compacted view rather than double-counting
-- messages that were folded into the summary.
--
-- Returns the surviving messages in chronological (oldest-first) order
-- so they can be replayed directly into the context.
loadRecentMessages :: TranscriptHandle -> Int -> Int -> IO [Message]
loadRecentMessages th maxCount maxTokens = do
  entries <- _th_query th TranscriptFilter
    { _tf_harness   = Nothing
    , _tf_model     = Nothing
    , _tf_direction = Nothing
    , _tf_timeRange = Nothing
    , _tf_limit     = Nothing
    }
  let -- Trim to entries from the last compaction boundary onward.
      postCompaction = trimToLastCompaction entries
      total     = length postCompaction
      countWin  = if total > maxCount
                    then drop (total - maxCount) postCompaction
                    else postCompaction
      -- Walk newest→oldest, adding to the budget; stop at the first
      -- entry that would push us OVER the limit. Always include at
      -- least one entry if the window is non-empty, so a single
      -- oversized message is not silently dropped.
      reversed  = reverse countWin
      budgeted  = goBudget 0 True reversed
      goBudget _    _     [] = []
      goBudget used first (e:es) =
        let cost  = T.length (_te_payload e) `div` 4
            used' = used + cost
        in if used' > maxTokens && not first
             then []
             else e : goBudget used' False es
  pure (map entryToMessage (reverse budgeted))
  where
    entryToMessage e =
      let role = case _te_direction e of
            Request  -> User
            Response -> Assistant
      in Message role [TextBlock (_te_payload e)]

-- | If any entry carries the compaction metadata key, return entries
-- from the last such entry onward (inclusive).  Otherwise return the
-- full list unchanged.
trimToLastCompaction :: [TranscriptEntry] -> [TranscriptEntry]
trimToLastCompaction entries =
  case lastCompactionIdx of
    Nothing -> entries
    Just i  -> drop i entries
  where
    isCompaction e = Map.member compactionMetadataKey (_te_metadata e)
    lastCompactionIdx = go Nothing 0 entries
    go acc _ []     = acc
    go acc n (e:es)
      | isCompaction e = go (Just n) (n + 1) es
      | otherwise      = go acc      (n + 1) es

