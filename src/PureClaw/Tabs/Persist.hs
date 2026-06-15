-- |
-- Module      : PureClaw.Tabs.Persist
-- Description : Persist the tab view to @~\/.pureclaw\/state\/tabs.json@.
--
-- The tab /view/ — the ordered 'TabList', the per-'ConversationKey' cursors,
-- and the per-conversation 'RelayMode' overrides — is machine-local mutable
-- runtime state, kept apart from the version-controllable session\/agent
-- ground truth. It lives under @state\/@ (mode @0700@) as @tabs.json@ (mode
-- @0600@). See the Tabs-as-View design §10 (GitHub #79).
--
-- Codec policy (project convention): the on-disk shape is a __hand-written__
-- Aeson codec, never generic deriving, so the wire format is reviewable and
-- stable. Maps with tuple keys ('ConversationKey') serialize as an /array of
-- objects/ (@{"channel":…,"conversation":…,…}@), not as JSON object keys, so
-- the key structure is explicit. A 'TabRef' is a tag-discriminated object
-- (@session@\/@harness@), mirroring the @TerminalBackend@ codec in
-- "PureClaw.Session.Kind".
--
-- Security (§2): the file stores __no secrets__ — no tokens, API keys,
-- passwords, or absolute filesystem paths. Only tab refs (opaque ids), names,
-- statuses, channel kinds, conversation ids, cursors, and relay modes.
--
-- IO seams are injected through 'PersistDeps' so boot reconcile is testable
-- without a real tmux\/harness: liveness probing and the "one discovery pass
-- completed" gate are both functions in the record.
module PureClaw.Tabs.Persist
  ( -- * Injected dependencies
    PersistDeps (..)
    -- * Save \/ load
  , saveTabs
  , loadTabs
  ) where

import Control.Exception (SomeException, try)
import Control.Exception qualified as E
import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.IO qualified as IO
import System.Posix.Files qualified as PF
import System.Posix.Temp qualified as Temp

import PureClaw.Core.Types
  ( ConversationId (..)
  , SessionId (..)
  , channelKindFromText
  , channelKindToText
  , isValidSessionId
  )
import PureClaw.Harness.Registry
  ( HarnessId
  , harnessIdToText
  , parseHarnessId
  )
import PureClaw.Security.Path (ensureRuntimeRoot)
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
  , pruneDangling
  , setStatus
  , toList
  )

-- ---------------------------------------------------------------------------
-- Injected dependencies
-- ---------------------------------------------------------------------------

-- | The IO seams 'loadTabs' needs, injected so boot reconcile is deterministic
-- in tests (no real tmux\/harness).
data PersistDeps = PersistDeps
  { _pd_stateDir       :: !FilePath
    -- ^ The @state\/@ directory (created @0700@ if missing on save).
  , _pd_harnessLive    :: !(HarnessId -> IO Bool)
    -- ^ Probe whether a harness-backed tab's ground truth is still alive.
  , _pd_discoveryReady :: !(IO ())
    -- ^ Block until at least one harness-discovery\/reconcile pass has
    --   completed, so a transiently-absent live harness is not wrongly
    --   dropped at boot. Awaited /before/ any harness pruning.
  , _pd_sessionExists  :: !(SessionId -> IO Bool)
    -- ^ Probe whether a session-backed tab's ground truth still exists on
    --   disk. A 'BoundSession' tab whose session.json has been removed
    --   out-of-band is dropped during reconcile (analogous to the harness
    --   liveness probe for 'BoundHarness' tabs).
  }

-- | The on-disk file name under '_pd_stateDir'.
tabsFileName :: FilePath
tabsFileName = "tabs.json"

-- ---------------------------------------------------------------------------
-- Save
-- ---------------------------------------------------------------------------

-- | Write the tab view to @<stateDir>\/tabs.json@. The @state\/@ directory is
-- created @0700@ if missing (via 'ensureRuntimeRoot').
--
-- Security-by-construction (§2): the file is created @0600@ /atomically/ — the
-- payload is written to a unique temp file in the same directory, created at
-- mode @0600@ by 'mkstemp' (POSIX), then 'rename'd over the target. This
-- avoids both the world-readable window of a write-then-chmod (the file is
-- never momentarily @0644@) and the re-exposure window when overwriting an
-- existing @0600@ file. The same-directory rename is atomic, so a crash mid-
-- write never leaves a torn @tabs.json@; the temp artifact is removed on any
-- failure.
saveTabs :: FilePath -> TabList -> CursorState -> IO ()
saveTabs stateDir tabs cursors = do
  _ <- ensureRuntimeRoot stateDir
  let path    = stateDir </> tabsFileName
      tmplate = stateDir </> (tabsFileName <> ".")
      payload = BL.toStrict (Aeson.encode (encodeState tabs cursors))
  E.bracketOnError
    (Temp.mkstemp tmplate)
    (uncurry cleanupTemp)
    (\(tmpPath, h) -> do
        BS.hPut h payload
        IO.hClose h
        PF.rename tmpPath path)

-- | Best-effort cleanup of a temp file after a failed save: close the handle
-- and remove the file, swallowing any error so the original failure (e.g. a
-- disk-full write) is the one that propagates.
cleanupTemp :: FilePath -> IO.Handle -> IO ()
cleanupTemp tmpPath h = do
  ignore (IO.hClose h)
  ignore (removeFile tmpPath)
  where
    ignore :: IO () -> IO ()
    ignore act = act `E.catch` \(_ :: SomeException) -> pure ()

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

-- | Load and reconcile the tab view from @<stateDir>\/tabs.json@:
--
--   1. Read + decode the file. A missing file, an IO error, or any decode
--      failure yields a __fresh__ @('emptyTabs', 'emptyCursors')@ — never an
--      exception (Tabs-as-View design §10.2\/§10.3).
--   2. Await one discovery pass ('_pd_discoveryReady') before pruning.
--   3. Drop harness-backed tabs whose '_pd_harnessLive' reports False
--      (silently — the documented I5 boot-drop exception); provider-session
--      tabs are kept as-is.
--   4. Prune any cursor whose 'TabRef' no longer resolves (I3).
loadTabs :: PersistDeps -> IO (TabList, CursorState)
loadTabs deps = do
  decoded <- readPersisted (_pd_stateDir deps </> tabsFileName)
  case decoded of
    Nothing                -> pure (emptyTabs, emptyCursors)
    Just (tabs, cursors)   -> do
      _pd_discoveryReady deps
      liveTabs <- reconcileTabs deps tabs
      pure (liveTabs, pruneDangling liveTabs cursors)

-- | Read and decode the persisted state, returning 'Nothing' on any failure
-- (missing file, IO error, or malformed JSON) so the caller starts fresh.
--
-- The read is __strict__ ('BS.readFile') and the decode strict
-- ('Aeson.eitherDecodeStrict''), both inside the 'try'. Lazy
-- 'Data.ByteString.Lazy.readFile' would defer the actual read syscalls until
-- the bytes are forced by the decoder, /outside/ the guard — a read-time
-- 'IOException' (truncation or removal mid-read, disk @EIO@, a stale NFS
-- handle) would then escape 'loadTabs' and crash boot. Reading and decoding
-- strictly forces every read syscall and the full parse within the guarded
-- scope, so any IO error or decode error degrades to a fresh start.
readPersisted :: FilePath -> IO (Maybe (TabList, CursorState))
readPersisted path = do
  result <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _    -> pure Nothing
    Right raw -> case Aeson.eitherDecodeStrict' raw of
      Left _   -> pure Nothing
      Right ps -> pure (Just (psTabs ps, psCursors ps))

-- | A tab's persisted content, slot excluded — the slot is always re-derived
-- (I1) by 'rebuildTabs', never trusted from disk.
type TabSpec = (TabRef, Text, TabStatus)

-- | Project a 'Tab' onto its persisted content (dropping the slot).
tabSpec :: Tab -> TabSpec
tabSpec t = (_tab_ref t, _tab_name t, _tab_status t)

-- | Drop harness-backed tabs whose ground truth is gone. Provider tabs are
-- always retained; the surviving tabs are re-appended in order so the result
-- satisfies I1 (contiguous slots) via 'rebuildTabs'.
reconcileTabs :: PersistDeps -> TabList -> IO TabList
reconcileTabs deps tabs = do
  survivors <- filterM keepTab (toList tabs)
  pure (rebuildTabs (map tabSpec survivors))
  where
    keepTab :: Tab -> IO Bool
    keepTab t = case _tab_ref t of
      BoundSession s -> _pd_sessionExists deps s
      BoundHarness h -> _pd_harnessLive deps h

-- | Re-append a list of tab specs into a fresh 'TabList', stamping contiguous
-- slots (I1) and carrying each tab's original 'TabStatus' through (so a 'Dead'
-- tombstone survives). The input satisfies I2 (unique refs) — for decoded
-- input this is enforced by 'appendTab' itself silently de-duplicating, which
-- is the desired tolerant-load behaviour.
rebuildTabs :: [TabSpec] -> TabList
rebuildTabs = foldl step emptyTabs
  where
    step tl (ref, name, status) = case appendTab ref name tl of
      Right (_, tl') -> setStatus ref status tl'
      Left _         -> tl

-- | A small local 'filterM' to avoid pulling in @Control.Monad@ for one use.
filterM :: Applicative m => (a -> m Bool) -> [a] -> m [a]
filterM p = foldr step (pure [])
  where
    step x acc = (\keep rest -> if keep then x : rest else rest) <$> p x <*> acc

-- ---------------------------------------------------------------------------
-- On-disk representation + hand-written codec
-- ---------------------------------------------------------------------------

-- | The decoded on-disk payload.
data PersistedState = PersistedState
  { psTabs    :: !TabList
  , psCursors :: !CursorState
  }

-- | Build the top-level JSON 'Aeson.Value' for the tab view.
encodeState :: TabList -> CursorState -> Aeson.Value
encodeState tabs cursors =
  Aeson.object
    [ "tabs"    .= map encodeTab (toList tabs)
    , "cursors" .= map encodeCursorEntry (Map.toList (_cs_cursors cursors))
    , "relay"   .= map encodeRelayEntry (Map.toList (_cs_relay cursors))
    ]

instance Aeson.FromJSON PersistedState where
  parseJSON = Aeson.withObject "PersistedState" $ \o -> do
    tabRows    <- o .: "tabs"
    cursorRows <- o .: "cursors"
    relayRows  <- o .: "relay"
    tabs       <- rebuildTabs <$> traverse parseTab tabRows
    cursorMap  <- Map.fromList <$> traverse parseCursorEntry cursorRows
    relayMap   <- Map.fromList <$> traverse parseRelayEntry relayRows
    pure (PersistedState tabs (CursorState cursorMap relayMap))

-- Tab -----------------------------------------------------------------------

encodeTab :: Tab -> Aeson.Value
encodeTab t =
  Aeson.object
    [ "ref"    .= encodeRef (_tab_ref t)
    , "name"   .= _tab_name t
    , "status" .= statusToText (_tab_status t)
    ]

-- | Parse a tab row into a slot-less 'TabSpec'; the slot is re-derived on load
-- (I1) by 'rebuildTabs', never read from disk.
parseTab :: Aeson.Value -> Aeson.Parser TabSpec
parseTab = Aeson.withObject "Tab" $ \o -> do
  ref    <- o .: "ref" >>= parseRef
  name   <- o .: "name"
  status <- o .: "status" >>= statusFromText
  pure (ref, name, status)

-- TabRef --------------------------------------------------------------------

encodeRef :: TabRef -> Aeson.Value
encodeRef (BoundSession (SessionId s)) =
  Aeson.object ["tag" .= ("session" :: Text), "sessionId" .= s]
encodeRef (BoundHarness h) =
  Aeson.object ["tag" .= ("harness" :: Text), "harnessId" .= harnessIdToText h]

parseRef :: Aeson.Value -> Aeson.Parser TabRef
parseRef = Aeson.withObject "TabRef" $ \o -> do
  tag <- o .: "tag" :: Aeson.Parser Text
  case tag of
    "session" -> do
      raw <- o .: "sessionId"
      if isValidSessionId raw
        then pure (BoundSession (SessionId raw))
        else fail "invalid sessionId in tabs.json"
    "harness" -> do
      raw <- o .: "harnessId"
      case parseHarnessId raw of
        Just h  -> pure (BoundHarness h)
        Nothing -> fail "invalid harnessId in tabs.json"
    _ -> fail "unknown TabRef tag"

-- TabStatus -----------------------------------------------------------------

statusToText :: TabStatus -> Text
statusToText Live = "live"
statusToText Dead = "dead"

statusFromText :: Text -> Aeson.Parser TabStatus
statusFromText "live" = pure Live
statusFromText "dead" = pure Dead
statusFromText _      = fail "unknown tab status"

-- Cursor entry --------------------------------------------------------------

encodeCursorEntry :: (ConversationKey, TabRef) -> Aeson.Value
encodeCursorEntry ((ch, conv), ref) =
  Aeson.object
    [ "channel"      .= channelKindToText ch
    , "conversation" .= conversationIdToText conv
    , "ref"          .= encodeRef ref
    ]

parseCursorEntry :: Aeson.Value -> Aeson.Parser (ConversationKey, TabRef)
parseCursorEntry = Aeson.withObject "CursorEntry" $ \o -> do
  key <- parseKey o
  ref <- o .: "ref" >>= parseRef
  pure (key, ref)

-- Relay entry ---------------------------------------------------------------

encodeRelayEntry :: (ConversationKey, RelayMode) -> Aeson.Value
encodeRelayEntry ((ch, conv), mode) =
  Aeson.object
    [ "channel"      .= channelKindToText ch
    , "conversation" .= conversationIdToText conv
    , "mode"         .= relayModeToText mode
    ]

parseRelayEntry :: Aeson.Value -> Aeson.Parser (ConversationKey, RelayMode)
parseRelayEntry = Aeson.withObject "RelayEntry" $ \o -> do
  key  <- parseKey o
  mode <- o .: "mode" >>= relayModeFromText
  pure (key, mode)

-- ConversationKey -----------------------------------------------------------

parseKey :: Aeson.Object -> Aeson.Parser ConversationKey
parseKey o = do
  ch   <- channelKindFromText <$> o .: "channel"
  conv <- ConversationId <$> o .: "conversation"
  pure (ch, conv)

conversationIdToText :: ConversationId -> Text
conversationIdToText (ConversationId t) = t

-- RelayMode -----------------------------------------------------------------

relayModeToText :: RelayMode -> Text
relayModeToText FocusedOnly    = "focused"
relayModeToText ActivityDigest = "activity"
relayModeToText Firehose       = "firehose"

relayModeFromText :: Text -> Aeson.Parser RelayMode
relayModeFromText "focused"  = pure FocusedOnly
relayModeFromText "activity" = pure ActivityDigest
relayModeFromText "firehose" = pure Firehose
relayModeFromText _          = fail "unknown relay mode"
