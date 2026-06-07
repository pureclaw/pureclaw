module PureClaw.Harness.ClaudeCode
  ( -- * Construction
    mkClaudeCodeHarness
  , mkClaudeCodeHarnessWith
  , mkClaudeCodeHandleWithBaseline
  , mkDiscoveredClaudeCodeHandle
    -- * Adopt an existing external window (WU4)
  , adoptExternalWindow
    -- * Production name-based tmux IO (exported for fail-closed testing — WU8)
  , realSendNamed
  , realCaptureNamed
  , realStatus
    -- * Injectable dependencies (D4.2 / D4.3 seam)
  , ClaudeCodeDeps (..)
  , defaultClaudeCodeDeps
    -- * Spawn arg construction (WU6 — exported for testing)
  , claudeCodeExtraArgs
  , hasUnsafeFlag
    -- * Response extraction (exported for testing)
  , extractLastResponse
  , dropBaselineLines
  , countCaptureLines
  , isIdle
  , isResponseMarker
  , isUiBoundary
  ) where

import Control.Concurrent
import Control.Exception (try)
import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding qualified as TE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import System.Directory qualified as Dir
import System.Exit
import System.FilePath ((</>))
import System.Process.Typed qualified as P
import PureClaw.Handles.Harness
import PureClaw.Handles.Transcript
import PureClaw.Harness.Registry (HarnessId, HarnessRegistry)
import PureClaw.Harness.Registry qualified as Reg
import PureClaw.Harness.Tmux
import PureClaw.Security.Adoption (AdoptedHarness, adoptedSession)
import PureClaw.Security.Command
import PureClaw.Security.Policy
import PureClaw.Session.Kind
  ( HarnessFlavour (..)
  , HarnessSpec (..)
  , SessionKind (..)
  , TerminalBackend (..)
  , TmuxConfig (..)
  )
import PureClaw.Session.Types (SessionMeta (..), newSessionId)
import PureClaw.Core.Types (SessionId (..))
import PureClaw.Transcript.Types

-- ---------------------------------------------------------------------------
-- Injectable dependencies
-- ---------------------------------------------------------------------------

-- | The injectable tmux\/identity operations a Claude Code harness needs.
--
-- This record is the dependency-injection seam for the spawn-identity sequence
-- (D4.2) and the cached-coordinate, self-healing handle (D4.3): tests supply
-- fakes that record calls and simulate a tmux \"no such window\" so the
-- re-resolve path runs without a real tmux server. The production set is
-- 'defaultClaudeCodeDeps'.
--
-- The name-based I\/O ops report /found/-vs-/not found/ so the handle can
-- re-resolve its coordinate (a renamed\/moved window) by sweeping for its
-- @\@pcl_id@ and retrying once (design §4 \/ K3).
data ClaudeCodeDeps = ClaudeCodeDeps
  { _ccd_newId        :: IO HarnessId
    -- ^ Generate a fresh 'HarnessId' (production: 'Reg.newHarnessId').
  , _ccd_findClaude   :: IO (Maybe FilePath)
    -- ^ Locate the @claude@ binary (production: @findExecutable \"claude\"@).
  , _ccd_checkTmux    :: IO (Either HarnessError ())
    -- ^ Confirm tmux is available (production: 'requireTmux').
  , _ccd_addWindow    :: Text -> Text -> FilePath -> [Text] -> Maybe FilePath -> IO (Either HarnessError ())
    -- ^ Create the harness window: @session windowName binary args workDir@
    --   (production: 'addHarnessWindowNamed').
  , _ccd_startSession :: Text -> IO (Either HarnessError ())
    -- ^ Ensure the tmux session exists (production: 'startTmuxSession').
  , _ccd_setMarker    :: Text -> Text -> Text -> IO ()
    -- ^ Stamp the @\@pcl_id@ marker: @session windowName uuidText@
    --   (production: 'setWindowMarker').
  , _ccd_renameWindow :: Text -> Text -> Text -> IO ()
    -- ^ Rename a window: @session windowTarget newName@. The target may be a
    --   window name OR an index (e.g. @"0"@). Adopt renames the user-picked
    --   window BY INDEX to a safe canonical name so the @session:name@ targeting
    --   used by every other op cannot misparse a @.@\/numeric name as
    --   @index.pane@ (production: 'renameWindowNamed').
  , _ccd_setRemain    :: Text -> Text -> IO ()
    -- ^ Set @remain-on-exit on@: @session windowName@ (production:
    --   'setRemainOnExit').
  , _ccd_panePidOf    :: Text -> Text -> IO (Maybe Int)
    -- ^ Read the pane shell PID for @session windowName@ from a sweep
    --   (production: derive from 'readMarkers').
  , _ccd_harnessPidOf :: Int -> Text -> IO (Maybe Int)
    -- ^ Derive the harness-process PID from a pane shell PID + flavour comm
    --   (production: 'harnessPidOf').
  , _ccd_sweep        :: Text -> IO [TmuxWindowRow]
    -- ^ One server sweep of a session (production: 'readMarkers'). Used by the
    --   re-resolve path to find a moved window by its @\@pcl_id@.
  , _ccd_sendNamed    :: Text -> Text -> ByteString -> IO Bool
    -- ^ Send input to @session windowName@; 'True' iff the window was found.
  , _ccd_captureNamed :: Text -> Text -> Int -> IO (Maybe ByteString)
    -- ^ Capture from @session windowName@; 'Nothing' iff the window was not
    --   found ('Just' empty is a present-but-blank pane).
  , _ccd_stopNamed    :: Text -> Text -> IO ()
    -- ^ Kill @session windowName@ (production: 'stopHarnessWindowNamed').
  , _ccd_status       :: Text -> Text -> IO HarnessStatus
    -- ^ Check liveness of @session windowName@.
  }

-- | The comm name of the flavour binary used for harness-PID derivation.
claudeComm :: Text
claudeComm = "claude"

-- | Production dependency set: every op wired to the real tmux primitives.
-- All tmux subprocesses flow through the WU3 authorization seam
-- ('authorizeTmuxCommand' \/ 'tmuxProc') — never a bare @P.proc tmux@.
defaultClaudeCodeDeps :: ClaudeCodeDeps
defaultClaudeCodeDeps = ClaudeCodeDeps
  { _ccd_newId        = Reg.newHarnessId
  , _ccd_findClaude   = Dir.findExecutable "claude"
  , _ccd_checkTmux    = requireTmux
  , _ccd_addWindow    = addHarnessWindowNamed
  , _ccd_startSession = startTmuxSession
  , _ccd_setMarker    = setWindowMarker
  , _ccd_renameWindow = renameWindowNamed
  , _ccd_setRemain    = setRemainOnExit
  , _ccd_panePidOf    = realPanePidOf
  , _ccd_harnessPidOf = harnessPidOf
  , _ccd_sweep        = readMarkers
  , _ccd_sendNamed    = realSendNamed
  , _ccd_captureNamed = realCaptureNamed
  , _ccd_stopNamed    = stopHarnessWindowNamed
  , _ccd_status       = realStatus
  }

-- | Read the pane shell PID for a window by sweeping the session and matching
-- the window name.
realPanePidOf :: Text -> Text -> IO (Maybe Int)
realPanePidOf session windowName = do
  rows <- readMarkers session
  pure (find ((== windowName) . _twr_windowName) rows >>= _twr_panePid)

-- | Send to a named window through the WU3 tmux seam, reporting whether the
-- window was found. tmux exits non-zero when @-t@ targets a missing window.
--
-- C3 input hygiene (§8 C3): the payload is sent LITERALLY (@send-keys -l --@)
-- so embedded tmux key tokens (@C-c@, @Enter@, @;@, …) are typed verbatim rather
-- than interpreted, then a SEPARATE @Enter@ submits the line (so a launch
-- command still executes). The two-step preserves this function's @IO Bool@
-- contract: found-ness is determined by the LITERAL send (the targeting step);
-- the Enter is only attempted when that succeeded.
realSendNamed :: Text -> Text -> ByteString -> IO Bool
realSendNamed session windowName _input
  -- WU8 Part A (§8 C3/C4): fail-closed on the adopted/discovered path — an
  -- invalid session/window identifier is refused (False) WITHOUT any tmux op.
  | not (validateTmuxIdent session && validateTmuxIdent windowName) = pure False
realSendNamed session windowName input = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure False
    Just tmuxBin -> do
      let run args = P.runProcess
            $ P.setStdin P.closed
            $ P.setStdout P.nullStream
            $ P.setStderr P.nullStream
            $ tmuxProc (authorizeTmuxCommand tmuxBin (map T.pack args))
      litCode <- run (sendKeysNamedArgs session windowName input)
      case litCode of
        ExitSuccess -> do
          _ <- run (sendEnterNamedArgs session windowName)
          pure True
        ExitFailure _ -> pure False

-- | Capture from a named window through the WU3 tmux seam. 'Nothing' signals a
-- missing window (tmux exit non-zero); 'Just' carries the (ANSI-stripped) bytes.
realCaptureNamed :: Text -> Text -> Int -> IO (Maybe ByteString)
realCaptureNamed session windowName _lineCount
  -- WU8 Part A (§8 C3/C4): fail-closed — an invalid identifier is refused
  -- (Nothing, the missing-window value) WITHOUT issuing capture-pane.
  | not (validateTmuxIdent session && validateTmuxIdent windowName) = pure Nothing
realCaptureNamed session windowName lineCount = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure Nothing
    Just tmuxBin -> do
      let args = captureNamedArgs session windowName lineCount
          config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (authorizeTmuxCommand tmuxBin (map T.pack args))
      (exitCode, stdout, _stderr) <- P.readProcess config
      pure $ case exitCode of
        ExitSuccess   -> Just (LBS.toStrict stdout)
        ExitFailure _ -> Nothing

-- | Window-status check by name through the WU3 tmux seam: a present window is
-- 'HarnessRunning'; a missing one is 'HarnessExited'.
realStatus :: Text -> Text -> IO HarnessStatus
realStatus session windowName
  -- WU8 Part A (§8 C3/C4): fail-closed — an invalid identifier is treated as a
  -- missing/unusable window ('HarnessExited') WITHOUT issuing list-windows.
  | not (validateTmuxIdent session && validateTmuxIdent windowName) =
      pure (HarnessExited (ExitFailure 1))
realStatus session windowName = do
  mTmux <- findTmux
  case mTmux of
    Nothing -> pure (HarnessExited (ExitFailure 127))
    Just tmuxBin -> do
      exitCode <- P.runProcess
        $ P.setStdin P.closed
        $ P.setStdout P.nullStream
        $ P.setStderr P.nullStream
        $ tmuxProc (authorizeTmuxCommand tmuxBin
            ["list-windows", "-t", T.pack (windowTarget session windowName)
            , "-F", "#{window_name}"])
      pure $ case exitCode of
        ExitSuccess      -> HarnessRunning
        ExitFailure code -> HarnessExited (ExitFailure code)

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a Claude Code harness using the production dependency set.
--
-- On success it has stamped the durable @\@pcl_id@ identity marker, enabled
-- @remain-on-exit@, recorded the shell + harness PIDs, and registered a
-- @Spawned@ 'Reg.HarnessEntry' in the registry. The returned 'HarnessId' lets
-- the caller persist the identity and sync the legacy name-keyed map.
mkClaudeCodeHarness
  :: SecurityPolicy
  -> TranscriptHandle
  -> Text             -- ^ tmux session name (default @"pureclaw"@)
  -> Text             -- ^ tmux window name (display-only, e.g. @claude-code-0@)
  -> Int              -- ^ tmux window index (placement hint for the new window)
  -> Maybe FilePath   -- ^ optional working directory
  -> [Text]           -- ^ extra CLI arguments (e.g. --dangerously-skip-permissions)
  -> HarnessRegistry  -- ^ the durable registry to register the spawned entry into
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
mkClaudeCodeHarness = mkClaudeCodeHarnessWith defaultClaudeCodeDeps

-- | Testable variant with injectable dependencies ('ClaudeCodeDeps').
mkClaudeCodeHarnessWith
  :: ClaudeCodeDeps
  -> SecurityPolicy
  -> TranscriptHandle
  -> Text             -- ^ tmux session name
  -> Text             -- ^ tmux window name
  -> Int              -- ^ tmux window index
  -> Maybe FilePath   -- ^ optional working directory
  -> [Text]           -- ^ extra CLI arguments
  -> HarnessRegistry
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
mkClaudeCodeHarnessWith deps policy th session windowName _windowIdx mWorkDir extraArgs reg =
  -- Step 1: Pre-check authorization (pure, no IO needed).
  case preAuthorize policy of
    Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
    Right () -> do
      -- Step 2: Check tmux availability
      tmuxResult <- _ccd_checkTmux deps
      case tmuxResult of
        Left err -> pure (Left err)
        Right () -> do
          -- Step 3: Find claude binary
          mClaudePath <- _ccd_findClaude deps
          case mClaudePath of
            Nothing -> pure (Left (HarnessBinaryNotFound "claude"))
            Just claudePath ->
              -- Step 4: Authorize the full command path
              case authorize policy claudePath [] of
                Left cmdErr -> pure (Left (HarnessNotAuthorized cmdErr))
                Right authorizedCmd -> do
                  let program = getCommandProgram authorizedCmd
                  -- Step 5: Start tmux session (idempotent)
                  sessionResult <- _ccd_startSession deps session
                  case sessionResult of
                    Left err -> pure (Left err)
                    Right () -> do
                      -- Step 6: Add harness window (named)
                      windowResult <- _ccd_addWindow deps session windowName program extraArgs mWorkDir
                      case windowResult of
                        Left err -> pure (Left err)
                        Right () -> do
                          -- Step 6b: If unsafe mode, auto-confirm the safety prompt
                          when (hasUnsafeFlag extraArgs) $ do
                            threadDelay 2000000  -- 2s for the prompt to appear
                            _ <- _ccd_sendNamed deps session windowName ""
                            pure ()
                          -- Step 7: Establish identity (D4.2).
                          hid <- _ccd_newId deps
                          _ccd_setMarker deps session windowName (Reg.harnessIdToText hid)
                          _ccd_setRemain deps session windowName
                          mShellPid <- _ccd_panePidOf deps session windowName
                          mHarnessPid <- case mShellPid of
                            Just shellPid -> _ccd_harnessPidOf deps shellPid claudeComm
                            Nothing       -> pure Nothing
                          -- Step 8: Wire up the cached-coordinate handle (D4.3).
                          -- Spawn baseline = 0: PureClaw created this window
                          -- fresh, so there is no pre-existing backlog to
                          -- exclude (B3 / D3.2 — behavior unchanged). WU4
                          -- (adopt) instead calls
                          -- 'mkClaudeCodeHandleWithBaseline' with the window's
                          -- current scrollback line count so an adopted
                          -- window's prior backlog never enters the transcript.
                          handle <- mkClaudeCodeHandleWithBaseline deps reg hid th session 0
                          -- Step 9: Register the Spawned entry (D4.2).
                          let entry = Reg.HarnessEntry
                                { Reg._he_id          = hid
                                , Reg._he_session     = session
                                , Reg._he_windowName  = windowName
                                , Reg._he_shellPid    = mShellPid
                                , Reg._he_harnessPid  = mHarnessPid
                                , Reg._he_origin      = Reg.OriginSpawned
                                , Reg._he_liveness    = Reg.LivenessIdle
                                , Reg._he_extModified = False
                                , Reg._he_stale       = False
                                , Reg._he_sessionId   = Nothing
                                , Reg._he_label       = windowName
                                , Reg._he_orphanedTicks = 0
                                , Reg._he_handle      = Just handle
                                }
                          Reg.insertEntry reg entry
                          pure (Right (hid, handle))

-- | Check whether the extra args include the unsafe/skip-permissions flag.
hasUnsafeFlag :: [Text] -> Bool
hasUnsafeFlag = elem "--dangerously-skip-permissions"

-- | Build the extra CLI args for a spawned @claude-code@ harness from the
-- two spawn-time inputs: whether to skip permission checks, and the optional
-- minted @claude-code@ session UUID (WU6, D6.1).
--
-- The @--session-id \<uuid\>@ pair is appended through the EXISTING @[Text]@
-- args that flow to 'mkClaudeCodeHarnessWith' — the @_ccd_addWindow@ signature
-- is deliberately NOT widened. Ordering: the unsafe flag (if any) comes first,
-- exactly as before, so 'hasUnsafeFlag' (which scans the whole list) still
-- detects it; appending @--session-id@ afterwards cannot perturb that. When
-- the uuid is 'Nothing' the result is identical to the legacy behaviour, so a
-- non-correlated spawn (e.g. uuid minting elided) is byte-for-byte unchanged.
claudeCodeExtraArgs :: Bool -> Maybe Text -> [Text]
claudeCodeExtraArgs skipPerms mUuid =
  ["--dangerously-skip-permissions" | skipPerms]
    ++ maybe [] (\u -> ["--session-id", u]) mUuid

-- | Pre-authorize: check that the policy would allow "claude" at all.
preAuthorize :: SecurityPolicy -> Either CommandError ()
preAuthorize policy = case authorize policy "claude" [] of
  Left err -> Left err
  Right _  -> Right ()

-- | Build a cached-coordinate 'HarnessHandle' for an already-registered harness
-- with an explicit capture /baseline/ (B3 mechanism, D5).
--
-- The baseline is the number of pre-existing scrollback lines to EXCLUDE from
-- captured\/recorded output (see 'dropBaselineLines'). 'harnessReceive' drops
-- the first @baseline@ lines of every full capture before extraction, so
-- pre-baseline backlog can never reach the transcript NOR the WS broadcast
-- (D3.3 — both derive from the baseline-stripped capture).
--
-- The spawn path ('mkClaudeCodeHarnessWith') passes @0@: a freshly-created
-- window has no pre-existing backlog, so behavior is unchanged (D3.2). WU4
-- (adopt) is the intended other caller: it passes the adopted window's CURRENT
-- scrollback line count so the window's prior backlog is excluded from the
-- adoption point forward.
mkClaudeCodeHandleWithBaseline
  :: ClaudeCodeDeps
  -> HarnessRegistry
  -> HarnessId
  -> TranscriptHandle
  -> Text            -- ^ tmux session name (for '_hh_session')
  -> Int             -- ^ initial capture baseline: pre-existing lines to exclude
  -> IO HarnessHandle
mkClaudeCodeHandleWithBaseline deps reg hid th session baseline = do
  baselineRef <- newIORef baseline
  pure HarnessHandle
    { _hh_send    = harnessSend deps reg hid th baselineRef
    , _hh_receive = harnessReceive deps reg hid th baselineRef
    , _hh_name    = "Claude Code"
    , _hh_session = session
    , _hh_status  = harnessStatus deps reg hid
    , _hh_stop    = harnessStop deps reg hid
    }

-- ---------------------------------------------------------------------------
-- Adopt an existing external window (WU4 — design §6, §8 B2\/B3, D6)
-- ---------------------------------------------------------------------------

-- | Adopt an EXTERNAL (discovered, PureClaw-UNMARKED) tmux window into the
-- registry. This is the spawn path MINUS window creation: the window already
-- exists, so we only stamp identity, set the capture baseline, register, and
-- link a @session.json@.
--
-- The first argument is an 'AdoptedHarness' capability TOKEN. Its value
-- constructor is unexported, so the ONLY way to obtain one is
-- 'PureClaw.Security.Adoption.authorizeAdoption', which enforces the consent +
-- allow-list gate. Requiring the token as a parameter makes it impossible BY
-- CONSTRUCTION to adopt a window without first passing the gate (D4.3) — there
-- is no token-free adopt path. The tmux session name rides in the token
-- ('adoptedSession'); only the window name is supplied separately.
--
-- Steps (mirror 'mkClaudeCodeHarnessWith', omitting tmux session\/window
-- creation):
--
--   1. Generate a fresh 'HarnessId'.
--   2. Stamp the durable @\@pcl_id@ marker and enable @remain-on-exit@ on the
--      adopted coordinates (the C4 trust anchor is established AT adopt time).
--   3. Measure the window's CURRENT scrollback line count and build the handle
--      with that as its capture baseline (B3 \/ D5): the pre-existing backlog
--      is excluded from the transcript and the WS broadcast from the adoption
--      point forward.
--   4. Record the shell PID (best-effort) and derive the harness PID
--      best-effort (may be 'Nothing' for a non-flavour window — OK).
--   5. Register an @OriginAdopted@ 'Reg.HarnessEntry' (with the handle) into the
--      registry.
--   6. Create\/link a harness @session.json@ that persists the 'HarnessId' and
--      the adopted tmux coordinates (mirrors the spawn persistence).
--
-- Does NOT create the window and does NOT capture the backlog. The legacy
-- '_fe_harnesses' map sync (D-ADD-2) is the ENDPOINT's responsibility (it has
-- the map); this mechanism returns the @(HarnessId, HarnessHandle)@ the caller
-- inserts.
adoptExternalWindow
  :: ClaudeCodeDeps
  -> HarnessRegistry
  -> TranscriptHandle
  -> FilePath            -- ^ sessions base directory (where @session.json@ is linked)
  -> AdoptedHarness      -- ^ capability token (REQUIRED — type-enforced, D4.3)
  -> Text                -- ^ tmux window name to adopt
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
adoptExternalWindow deps reg th sessionsDir token windowName = do
  let session = adoptedSession token
  -- WU8 Part A (§8 C3/C4 defense-in-depth): the adopted coordinates originate
  -- from the server-wide sweep (attacker-writable) and the allow-list (a literal
  -- pattern can mint any session string). Validate BOTH identifiers FAIL-CLOSED
  -- BEFORE any tmux mutation — a leading @-@ / @:@ / control char never reaches
  -- set-option, capture-pane, or registration. The argv defense already holds;
  -- this refuses the most-exposed path outright (no marker stamped, nothing
  -- registered, no session.json written).
  if not (validateTmuxIdent session && validateTmuxIdent windowName)
    then pure (Left (HarnessNotAuthorized
      (CommandNotAllowed ("invalid tmux identifier for adoption: "
        <> session <> ":" <> windowName))))
    else adoptValidated deps reg th sessionsDir session windowName

-- | The adopt mechanism proper, reached only AFTER both tmux identifiers have
-- passed 'validateTmuxIdent' (WU8 Part A). Split out so the guard in
-- 'adoptExternalWindow' provably precedes every tmux op below.
adoptValidated
  :: ClaudeCodeDeps
  -> HarnessRegistry
  -> TranscriptHandle
  -> FilePath
  -> Text                -- ^ validated tmux session name
  -> Text                -- ^ validated tmux window name
  -> IO (Either HarnessError (HarnessId, HarnessHandle))
adoptValidated deps reg th sessionsDir session windowName = do
  -- Step 1: fresh identity.
  hid <- _ccd_newId deps
  -- Step 2: resolve the user-picked window to its INDEX via a fresh scan. The
  -- scan reads @#{window_name}@ as DATA, so a name containing @.@ (or a purely
  -- numeric name) cannot be misparsed here. We pick the FIRST UNMARKED window
  -- whose name matches (mirrors discovery's adoptable filter — avoids grabbing
  -- an already-ours duplicate-named window). If none matches, the window is
  -- gone\/already adopted: refuse with NO mutation (maps to 503).
  rows <- _ccd_sweep deps session
  case find (\r -> _twr_windowName r == windowName && _twr_pclId r == "") rows of
    Nothing -> pure (Left (HarnessTmuxNotAvailable
      ("adopt: no unmarked window named " <> windowName
        <> " in session " <> session)))
    Just row -> do
      let idx = _twr_windowIndex row
          -- Step 3: a SAFE canonical name. The HarnessId UUID is hex + hyphens,
          -- so the result never contains @.@\/@:@ and passes 'validateTmuxIdent'.
          -- We DO NOT reuse the user's name (which may contain a @.@ that breaks
          -- the @session:name@ targeting every downstream op relies on — the
          -- root-cause of the §8 C4 "no corroborating PID" eviction).
          safeName = "adopted-" <> T.take 8 (Reg.harnessIdToText hid)
      -- Step 4: rename the window BY INDEX (@session:<int>@ resolves by window
      -- index — unambiguous, immune to the @.@ misparse). After this, the window
      -- name is safe and @session:safeName@ targeting is correct.
      _ccd_renameWindow deps session (T.pack (show idx)) safeName
      -- From here EVERYTHING addresses the window by the SAFE name.
      -- Step 5: establish identity on the renamed window (C4 anchor at adopt time).
      _ccd_setMarker deps session safeName (Reg.harnessIdToText hid)
      _ccd_setRemain deps session safeName
      -- Step 6: measure the window's current scrollback and set the baseline so
      -- the pre-existing backlog is excluded (B3 / D5). A full capture
      -- (lineCount 0) mirrors the receive path's full-screen capture; we count
      -- its lines.
      fullCapture <- fromMaybe "" <$> _ccd_captureNamed deps session safeName 0
      let baseline = countCaptureLines fullCapture
      -- Step 7: PID provenance (both best-effort).
      mShellPid <- _ccd_panePidOf deps session safeName
      mHarnessPid <- case mShellPid of
        Just shellPid -> _ccd_harnessPidOf deps shellPid claudeComm
        Nothing       -> pure Nothing
      -- Step 8: build the cached-coordinate handle with the adoption baseline.
      handle <- mkClaudeCodeHandleWithBaseline deps reg hid th session baseline
      -- Step 9: link a harness session.json (mirrors the spawn persistence;
      -- persists the HarnessId + adopted coords like WU6 / Phase 2).
      now <- getCurrentTime
      let sid = newSessionId Nothing now
          entry = Reg.HarnessEntry
            { Reg._he_id          = hid
            , Reg._he_session     = session
            , Reg._he_windowName  = safeName
            , Reg._he_shellPid    = mShellPid
            , Reg._he_harnessPid  = mHarnessPid
            , Reg._he_origin      = Reg.OriginAdopted
            , Reg._he_liveness    = Reg.LivenessIdle
            , Reg._he_extModified = False
            , Reg._he_stale       = False
            , Reg._he_sessionId   = Just (unSessionId sid)
            , Reg._he_label       = safeName
            , Reg._he_orphanedTicks = 0
            , Reg._he_handle      = Just handle
            }
          meta = SessionMeta
            { _sm_id                = sid
            , _sm_agent             = Nothing
            , _sm_kind              = SkHarness HarnessSpec
                { _h_flavour   = HClaudeCode
                , _h_backend   = TbTmux TmuxConfig
                    { _tc_session = session
                    , _tc_window  = safeName
                    , _tc_pane    = Nothing
                    }
                , _h_cwd       = Nothing
                , _h_args      = []
                , _h_harnessId = Just hid
                -- Adopted harnesses are NOT spawned by PureClaw, so we never
                -- minted a --session-id for them and cannot correlate their
                -- JSONL log (WU6: claude-code log capture is spawned-only).
                -- Both Nothing.
                , _h_claudeSessionUuid = Nothing
                , _h_canonicalCwd      = Nothing
                }
            , _sm_model             = ""
            , _sm_channel           = "web"
            , _sm_createdAt         = now
            , _sm_lastActive        = now
            , _sm_bootstrapConsumed = True
            , _sm_archived          = False
            , _sm_description       = Nothing
            , _sm_autoSummary       = Nothing
            , _sm_source            = Nothing
            }
      Reg.insertEntry reg entry
      writeSessionMeta sessionsDir meta
      pure (Right (hid, handle))

-- | Count the newline-delimited lines in a raw capture, matching the splitting
-- 'dropBaselineLines' \/ 'extractLastResponse' use (split on @0x0A@). An empty
-- capture is 0 lines; otherwise it is one more than the number of @0x0A@ bytes.
-- This is the adoption baseline: the count of pre-existing scrollback lines to
-- exclude from the adoption point forward (B3).
countCaptureLines :: ByteString -> Int
countCaptureLines bs
  | BS.null bs = 0
  | otherwise  = length (BS.split 0x0A bs)

-- | Atomically write a session's @session.json@ (mirrors
-- @PureClaw.Session.Handle.saveMeta@: tmp-file + 'Dir.renameFile'). Kept local
-- so the adopt mechanism does not depend on the higher broker-aware
-- 'PureClaw.Session.Handle' layer. Creates the session directory if needed.
writeSessionMeta :: FilePath -> SessionMeta -> IO ()
writeSessionMeta baseDir meta = do
  let dir    = baseDir </> T.unpack (unSessionId (_sm_id meta))
      finalP = dir </> "session.json"
      tmpP   = finalP <> ".tmp"
  Dir.createDirectoryIfMissing True dir
  LBS.writeFile tmpP (Aeson.encode meta)
  -- Best-effort persistence: a failed rename is SWALLOWED (swallow-and-continue),
  -- not surfaced. The adopt mechanism has already stamped identity and registered
  -- the OriginAdopted entry by this point, so a session.json write fault must not
  -- fail the adoption — the in-memory registry entry still routes; the persisted
  -- metadata is a reconnect convenience that the next reconcile/save can rebuild.
  result <- try (Dir.renameFile tmpP finalP) :: IO (Either IOError ())
  case result of
    Right () -> pure ()
    Left _   -> pure ()

-- ---------------------------------------------------------------------------
-- Cached-coordinate, self-healing handle (D4.3)
-- ---------------------------------------------------------------------------

-- | Read the current cached coordinate @(session, windowName)@ for a harness
-- from its registry entry. The handle does NOT close over a frozen window name
-- (design §4): it reads the live entry on every I\/O so the reconcile loop
-- (WU5) can update the coordinate underneath it.
currentCoord :: HarnessRegistry -> HarnessId -> IO (Maybe (Text, Text))
currentCoord reg hid = do
  mEntry <- Reg.lookupById reg hid
  pure (fmap (\e -> (Reg._he_session e, Reg._he_windowName e)) mEntry)

-- | Re-resolve a harness's window after a tmux \"no such window\": sweep the
-- session, find the row whose @\@pcl_id@ matches this harness's id, update the
-- cached '_he_windowName', and return the new name. 'Nothing' if no marked
-- window matches (the full reconcile loop is WU5; this is the minimal
-- one-shot heal).
reResolve :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> Text -> IO (Maybe Text)
reResolve deps reg hid session = do
  rows <- _ccd_sweep deps session
  let idText = Reg.harnessIdToText hid
  case find ((== idText) . _twr_pclId) rows of
    Nothing  -> pure Nothing
    Just row -> do
      let newName = _twr_windowName row
      mEntry <- Reg.lookupById reg hid
      case mEntry of
        Nothing -> pure ()
        Just e  -> Reg.insertEntry reg e { Reg._he_windowName = newName }
      pure (Just newName)

-- | Send input to the harness, logging the request. Reads the cached coordinate;
-- on a tmux \"no such window\" it re-resolves once by @\@pcl_id@ and retries.
harnessSend :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> TranscriptHandle -> IORef Int -> ByteString -> IO ()
harnessSend deps reg hid th _baselineRef input = do
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Request
        , _te_payload       = encodePayload input
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ()  -- entry vanished; nothing to target
    Just (session, windowName) -> do
      found <- _ccd_sendNamed deps session windowName input
      unless found $ do
        mNew <- reResolve deps reg hid session
        case mNew of
          Nothing      -> pure ()  -- could not heal; give up (WU5 owns reconcile)
          Just newName -> do
            _ <- _ccd_sendNamed deps session newName input
            pure ()

-- | Poll the harness window until idle, then capture and extract the last
-- response. Re-resolves the coordinate once on a tmux \"no such window\".
harnessReceive :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> TranscriptHandle -> IORef Int -> IO ByteString
harnessReceive deps reg hid th baselineRef = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ""
    Just (session, windowName0) -> do
      -- Ensure the window is reachable; re-resolve once if not.
      windowName <- do
        probe <- _ccd_captureNamed deps session windowName0 1
        case probe of
          Just _  -> pure windowName0
          Nothing -> do
            mNew <- reResolve deps reg hid session
            pure (fromMaybe windowName0 mNew)
      startTime <- getCurrentTime
      pollUntilIdle session windowName startTime "" (0 :: Int)
      fullCapture <- fromMaybe "" <$> _ccd_captureNamed deps session windowName 0
      -- B3: exclude everything before the recorded baseline (the count of
      -- pre-existing scrollback lines) so pre-baseline backlog can never be
      -- extracted/recorded. Both 'responseText' (the WS-broadcast value) and
      -- the transcript entry below derive from the stripped capture (D3.3).
      baseline <- readIORef baselineRef
      let responseText = extractLastResponse (dropBaselineLines baseline fullCapture)
      entryId <- UUID.toText <$> UUID.nextRandom
      now <- getCurrentTime
      let entry = TranscriptEntry
            { _te_id            = entryId
            , _te_timestamp     = now
            , _te_harness       = Just "claude-code"
            , _te_model         = Nothing
            , _te_direction     = Response
            , _te_payload       = encodePayload responseText
            , _te_durationMs    = Nothing
            , _te_correlationId = entryId
            , _te_metadata      = Map.empty
            }
      _th_record th entry
      pure responseText
  where
    pollUntilIdle session windowName startTime lastScreen stableCount = do
      threadDelay 500000  -- 500ms
      current <- fromMaybe "" <$> _ccd_captureNamed deps session windowName 300
      now <- getCurrentTime
      let elapsed = diffUTCTime now startTime
          screenText = TE.decodeUtf8Lenient current
      if elapsed > 120
        then pure ()
        else if isIdle screenText
          then if current == lastScreen
            then if stableCount >= 2
              then pure ()
              else pollUntilIdle session windowName startTime current (stableCount + 1)
            else pollUntilIdle session windowName startTime current 0
          else pollUntilIdle session windowName startTime "" 0

-- | Check the harness window status via the cached coordinate.
harnessStatus :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> IO HarnessStatus
harnessStatus deps reg hid = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure (HarnessExited (ExitFailure 127))
    Just (session, windowName) -> _ccd_status deps session windowName

-- | Stop (kill) the harness window via the cached coordinate.
harnessStop :: ClaudeCodeDeps -> HarnessRegistry -> HarnessId -> IO ()
harnessStop deps reg hid = do
  mCoord <- currentCoord reg hid
  case mCoord of
    Nothing -> pure ()
    Just (session, windowName) -> _ccd_stopNamed deps session windowName

-- ---------------------------------------------------------------------------
-- Response extraction (pure)
-- ---------------------------------------------------------------------------

-- | Check if Claude Code is idle (showing prompt, not busy).
isIdle :: Text -> Bool
isIdle screen =
  let hasPrompt = T.isInfixOf "\x276F" screen   -- ❯
      isBusy    = T.isInfixOf "\x280B" screen    -- ⠋ (spinner)
                || T.isInfixOf "Thinking" screen
                || T.isInfixOf "Running" screen
  in hasPrompt && not isBusy

-- | Drop the first @n@ scrollback lines from a raw capture (B3 baseline
-- mechanism). The baseline is the number of pre-existing lines to EXCLUDE.
--
-- Total: @n <= 0@ → identity; @n >= line count@ → empty; otherwise drops
-- exactly @n@ leading newline-delimited lines and re-joins the remainder with
-- @0x0A@. Splitting on @0x0A@ mirrors 'extractLastResponse' so the line indices
-- agree.
dropBaselineLines :: Int -> ByteString -> ByteString
dropBaselineLines n capture
  | n <= 0    = capture
  | otherwise = BS.intercalate (BS.singleton 0x0A) (drop n (BS.split 0x0A capture))

-- | Extract the last response block from Claude Code scrollback.
extractLastResponse :: ByteString -> ByteString
extractLastResponse capture =
  let allLines  = map TE.decodeUtf8Lenient (BS.split 0x0A capture)
      markerIdxs = [ i | (i, line) <- zip [0..] allLines
                       , isResponseMarker line ]
  in case markerIdxs of
    [] -> ""  -- no response found
    _  ->
      let startIdx   = last markerIdxs
          response   = takeWhile (not . isUiBoundary)
                     $ drop startIdx allLines
          cleaned    = case response of
            (firstLine : rest) -> stripMarker firstLine : rest
            []                 -> []
      in TE.encodeUtf8 (T.intercalate "\n" cleaned)

-- | Lines starting with ⏺ (U+23FA, BLACK CIRCLE FOR RECORD) are response markers.
isResponseMarker :: Text -> Bool
isResponseMarker line =
  T.isPrefixOf "\x23FA" (T.stripStart line)
  || T.isPrefixOf "\x2B24" (T.stripStart line)  -- ⬤ alternate marker

-- | UI boundaries that terminate response extraction.
isUiBoundary :: Text -> Bool
isUiBoundary line =
  let stripped = T.stripStart line
  in T.isPrefixOf "\x276F" stripped         -- ❯ input prompt
  || T.isPrefixOf "?" stripped
     && T.isInfixOf "shortcut" line         -- "? for shortcuts"
  || T.isInfixOf "\x2580\x2580" line        -- ▀▀ top bar
  || T.isInfixOf "\x2584\x2584" line        -- ▄▄ bottom bar
  || T.isInfixOf "\x2500\x2500\x2500" line  -- ─── horizontal rule

-- | Strip the response marker prefix (⏺ or ⬤) from a line.
stripMarker :: Text -> Text
stripMarker line =
  let stripped = T.stripStart line
  in if T.isPrefixOf "\x23FA" stripped || T.isPrefixOf "\x2B24" stripped
     then T.stripStart (T.drop 1 stripped)
     else line

-- ---------------------------------------------------------------------------
-- Discovered handle
-- ---------------------------------------------------------------------------

-- | Reconstruct a 'HarnessHandle' for an already-running Claude Code window
-- discovered via tmux. Used on startup to recover harness state.
--
-- This is the legacy, registry-less discovery path (the boot reconstruction
-- that builds registry entries is WU5). It targets the window by name directly
-- using the production tmux ops; it does NOT re-resolve (no registry entry to
-- update). The 'Text' session and window name are threaded through (D4.1).
mkDiscoveredClaudeCodeHandle :: TranscriptHandle -> Text -> Text -> IO HarnessHandle
mkDiscoveredClaudeCodeHandle th session windowName =
  pure HarnessHandle
    { _hh_send    = discoveredSend th session windowName
    , _hh_receive = discoveredReceive th session windowName
    , _hh_name    = "Claude Code"
    , _hh_session = session
    , _hh_status  = realStatus session windowName
    , _hh_stop    = stopHarnessWindowNamed session windowName
    }

-- | Send for a discovered (registry-less) handle: log the request, then send by
-- name. No re-resolve (no registry entry to heal).
discoveredSend :: TranscriptHandle -> Text -> Text -> ByteString -> IO ()
discoveredSend th session windowName input = do
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Request
        , _te_payload       = encodePayload input
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  _ <- realSendNamed session windowName input
  pure ()

-- | Receive for a discovered handle: poll until idle, capture, extract, log.
discoveredReceive :: TranscriptHandle -> Text -> Text -> IO ByteString
discoveredReceive th session windowName = do
  startTime <- getCurrentTime
  pollUntilIdle startTime "" (0 :: Int)
  fullCapture <- captureFullScrollbackNamed session windowName
  let responseText = extractLastResponse fullCapture
  entryId <- UUID.toText <$> UUID.nextRandom
  now <- getCurrentTime
  let entry = TranscriptEntry
        { _te_id            = entryId
        , _te_timestamp     = now
        , _te_harness       = Just "claude-code"
        , _te_model         = Nothing
        , _te_direction     = Response
        , _te_payload       = encodePayload responseText
        , _te_durationMs    = Nothing
        , _te_correlationId = entryId
        , _te_metadata      = Map.empty
        }
  _th_record th entry
  pure responseText
  where
    pollUntilIdle startTime lastScreen stableCount = do
      threadDelay 500000
      current <- fromMaybe "" <$> realCaptureNamed session windowName 300
      now <- getCurrentTime
      let elapsed = diffUTCTime now startTime
          screenText = TE.decodeUtf8Lenient current
      if elapsed > 120
        then pure ()
        else if isIdle screenText
          then if current == lastScreen
            then if stableCount >= 2
              then pure ()
              else pollUntilIdle startTime current (stableCount + 1)
            else pollUntilIdle startTime current 0
          else pollUntilIdle startTime "" 0

-- | Capture the full scrollback buffer (not just the visible pane) by name,
-- through the WU3 tmux seam. Returns empty on a missing window or tmux absence.
captureFullScrollbackNamed :: Text -> Text -> IO ByteString
captureFullScrollbackNamed session windowName
  -- WU8 Part A (§8 C3/C4): fail-closed on the discovered receive path — an
  -- invalid identifier yields the empty capture WITHOUT issuing capture-pane.
  | not (validateTmuxIdent session && validateTmuxIdent windowName) = pure ""
captureFullScrollbackNamed session windowName = do
  mPath <- findTmux
  case mPath of
    Nothing -> pure ""
    Just tmuxBin -> do
      let config = P.setStdin P.closed
                 $ P.setStdout P.byteStringOutput
                 $ P.setStderr P.nullStream
                 $ tmuxProc (authorizeTmuxCommand tmuxBin
                     [ "capture-pane", "-t", T.pack (windowTarget session windowName)
                     , "-p", "-S", "-", "-E", "-"
                     ])
      (exitCode, stdout, _stderr) <- P.readProcess config
      pure $ case exitCode of
        ExitSuccess   -> LBS.toStrict stdout
        ExitFailure _ -> ""
