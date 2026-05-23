-- | WS-streaming endpoint for live transcript updates — WU3.
--
-- Implements the wire protocol defined in
-- @docs/transcript-streaming.md §Wire Protocol@: on upgrade, the server
-- sends a one-shot @hello@; then a reader/writer race forwards
-- 'BrokerEvent's from the broker to the WS peer while accepting
-- @focus@ ops from the client.
--
-- /Security/. Every WS upgrade is gated by an exact-match Origin allowlist
-- ('originAllowed' against the supplied list), a per-origin subscriber
-- cap (via 'StreamGuard'), and the broker's global cap. Inbound frames
-- are bounded at 4 KB; malformed JSON returns an in-band error without
-- closing the connection. 'Network.WebSockets.withPingThread' provides
-- the keepalive (Warp's idle timeout does NOT apply to hijacked sockets).
--
-- /Replay/. A focus op carrying @since@ enters replay mode: incoming
-- 'EntryRecorded' events for the focused session are buffered until the
-- file slice is read, then the buffered set is sent (UUID-deduped against
-- the file slice). The algorithm tolerates publishes-during-read and
-- falls back to @replay-failed@ on any anomaly so the client can refetch
-- via HTTP.
module PureClaw.Frontend.Stream
  ( -- * Server entry point
    streamApp
  , serverStartedAt
    -- * Origin normalization (exported for testing)
  , normalizeOrigin
  , originAllowed
    -- * StreamGuard operations
  , tryClaim
  , releaseClaim
    -- * Wire types (exported for testing)
  , ServerEvent (..)
  , ClientOp (..)
  , ErrorCode (..)
  , ActivityKind (..)
  , errorCodeText
  , encodeServerEvent
  , decodeClientOp
  ) where

import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
  ( STM
  , atomically
  , modifyTVar'
  , orElse
  , readTBQueue
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception
  ( SomeException
  , bracket
  , fromException
  , handle
  , try
  )
import Control.Exception qualified as Exception
import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Network.WebSockets qualified as WS
import System.IO.Error (isDoesNotExistError)
import System.IO.Unsafe (unsafePerformIO)

import PureClaw.Core.Types (SessionId (..))
import PureClaw.Frontend.API
  ( FrontendEnv (..)
  , HarnessActivity (..)
  , StreamGuard (..)
  , TranscriptEntryInfo (..)
  , isValidSessionId
  )
import PureClaw.Frontend.StreamBroker
  ( BrokerError (..)
  , BrokerEvent (..)
  , SessionActivity (..)
  , StreamBroker (..)
  , Subscription (..)
  )
import PureClaw.Handles.Log (LogHandle (..))
import PureClaw.Session.Types (SessionMeta (..))
import PureClaw.Transcript.Types (Direction (..), TranscriptEntry (..))

-- ---------------------------------------------------------------------------
-- Wire types
-- ---------------------------------------------------------------------------

-- | Server-to-client events. Encoded as a discriminated union with the
-- @type@ field.
data ServerEvent
  = SeHello   !Text !UTCTime
  | SeEntry   !SessionId !TranscriptEntry
  | SeActivity !SessionId !ActivityKind
  | SeReplayEnd !SessionId !(Maybe Text)
  | SeOverflow
  | SeError   !ErrorCode !Text
  deriving stock (Show, Eq)

-- | Activity-event kind (the @activity.kind@ discriminant).
data ActivityKind
  = AkEntryAt        !UTCTime
  | AkHarnessStatus  !HarnessActivity
  | AkSessionCreated !SessionMeta
  deriving stock (Show, Eq)

-- | Closed set of in-band error codes emitted by the WS handler.
data ErrorCode
  = EcInvalidOp
  | EcInvalidFrame
  | EcSessionNotFound
  | EcFrameTooLarge
  | EcReplayFailed
  | EcReplayAborted
  | EcInternal
  deriving stock (Show, Eq)

-- | Client-to-server ops.
data ClientOp
  = CoFocus !(Maybe SessionId) !(Maybe Text)
  deriving stock (Show, Eq)

errorCodeText :: ErrorCode -> Text
errorCodeText EcInvalidOp       = "invalid-op"
errorCodeText EcInvalidFrame    = "invalid-frame"
errorCodeText EcSessionNotFound = "session-not-found"
errorCodeText EcFrameTooLarge   = "frame-too-large"
errorCodeText EcReplayFailed    = "replay-failed"
errorCodeText EcReplayAborted   = "replay-aborted"
errorCodeText EcInternal        = "internal"

-- | Mirror of 'PureClaw.Frontend.API.toTranscriptEntryInfo' — we re-encode
-- entries through 'TranscriptEntryInfo' so the WS @entry@ event has the
-- same camelCase shape as the HTTP GET response.
toEntryInfo :: TranscriptEntry -> TranscriptEntryInfo
toEntryInfo e = TranscriptEntryInfo
  { _tei_id        = _te_id e
  , _tei_timestamp = _te_timestamp e
  , _tei_direction = case _te_direction e of
      Request  -> "request"
      Response -> "response"
  , _tei_payload   = _te_payload e
  , _tei_harness   = _te_harness e
  , _tei_model     = _te_model e
  }

encodeActivity :: ActivityKind -> Value
encodeActivity (AkEntryAt t) =
  object [ "kind" .= ("entry-at" :: Text), "timestamp" .= t ]
encodeActivity (AkHarnessStatus s) =
  object [ "kind" .= ("harness-status" :: Text), "status" .= s ]
encodeActivity (AkSessionCreated meta) =
  object [ "kind" .= ("session-created" :: Text), "session" .= meta ]

-- | Encode a 'ServerEvent' to JSON.
encodeServerEvent :: ServerEvent -> Value
encodeServerEvent (SeHello pv started) = object
  [ "type"            .= ("hello" :: Text)
  , "protocolVersion" .= pv
  , "serverStartedAt" .= T.pack (iso8601Show started)
  ]
encodeServerEvent (SeEntry sid entry) = object
  [ "type"      .= ("entry" :: Text)
  , "sessionId" .= unSessionId sid
  , "entry"     .= toEntryInfo entry
  ]
encodeServerEvent (SeActivity sid kind) = object
  [ "type"      .= ("activity" :: Text)
  , "sessionId" .= unSessionId sid
  , "activity"  .= encodeActivity kind
  ]
encodeServerEvent (SeReplayEnd sid mLast) = object
  [ "type"                .= ("replay-end" :: Text)
  , "sessionId"           .= unSessionId sid
  , "lastReplayedEntryId" .= mLast
  ]
encodeServerEvent SeOverflow = object [ "type" .= ("overflow" :: Text) ]
encodeServerEvent (SeError code msg) = object
  [ "type"    .= ("error" :: Text)
  , "code"    .= errorCodeText code
  , "message" .= msg
  ]

instance ToJSON ServerEvent where
  toJSON = encodeServerEvent

-- | Outcome of a 'decodeClientOp' attempt. Stays a sum so callers can
-- distinguish "JSON didn't parse" from "JSON parsed but the op was
-- unknown" (D29 vs D36).
data DecodeResult
  = DrOk !ClientOp
  | DrInvalidFrame
  | DrInvalidOp
  deriving stock (Show, Eq)

-- | Two-phase parse: structural JSON decode, then op-discriminant parse.
decodeClientOp :: LBS.ByteString -> DecodeResult
decodeClientOp bs = case Aeson.eitherDecode bs of
  Left _      -> DrInvalidFrame
  Right value -> case Aeson.parseEither parseFocus (value :: Value) of
    Right v   -> DrOk v
    Left err
      | "INVALID_OP_TAG" `T.isInfixOf` T.pack err -> DrInvalidOp
      | otherwise                                 -> DrInvalidFrame
  where
    -- Tag failures with a non-natural sentinel that's unlikely to collide
    -- with Aeson's generic decode errors. The match above lifts the tag
    -- out of the prefixed error message.
    parseFocus :: Value -> Aeson.Parser ClientOp
    parseFocus = withObject "ClientOp" $ \o -> do
      op <- o .: "op" :: Aeson.Parser Text
      case op of
        "focus" -> do
          msid   <- o .:? "sessionId"
          msince <- o .:? "since"
          pure (CoFocus (fmap SessionId msid) msince)
        _ -> fail "INVALID_OP_TAG"

instance FromJSON ClientOp where
  parseJSON = withObject "ClientOp" $ \o -> do
    op <- o .: "op" :: Aeson.Parser Text
    case op of
      "focus" -> do
        msid   <- o .:? "sessionId"
        msince <- o .:? "since"
        pure (CoFocus (fmap SessionId msid) msince)
      _ -> fail ("unknown-op: " <> T.unpack op)

-- ---------------------------------------------------------------------------
-- Origin matching
-- ---------------------------------------------------------------------------

-- | Lowercase the scheme and host components of an origin string; strip a
-- trailing slash. Port is left as-is.
normalizeOrigin :: Text -> Text
normalizeOrigin t = dropTrailingSlash (lowerSchemeHost t)
  where
    dropTrailingSlash s
      | T.null s          = s
      | T.last s == '/'   = T.init s
      | otherwise         = s
    lowerSchemeHost s =
      case T.breakOn "://" s of
        (scheme, rest) | T.isPrefixOf "://" rest ->
          let body = T.drop 3 rest
              (host, port) = T.breakOn ":" body
          in T.toLower scheme <> "://" <> T.toLower host <> port
        _ -> T.toLower s

-- | Exact-match origin lookup against a /list of normalized origins/.
-- Empty allowlist denies everything.
originAllowed :: [Text] -> Text -> Bool
originAllowed []      _      = False
originAllowed allowed origin = origin `elem` map normalizeOrigin allowed

-- ---------------------------------------------------------------------------
-- StreamGuard
-- ---------------------------------------------------------------------------

-- | Atomically increment the per-origin counter, returning 'True' if the
-- counter was strictly below '_streamGuard_maxPerOrigin' before the
-- increment. The caller must invoke 'releaseClaim' exactly once for each
-- successful claim.
tryClaim :: StreamGuard -> Text -> STM Bool
tryClaim g origin = do
  m <- readTVar (_streamGuard_perOrigin g)
  let current = Map.findWithDefault 0 origin m
  if current >= _streamGuard_maxPerOrigin g
    then pure False
    else do
      writeTVar (_streamGuard_perOrigin g) (Map.insert origin (current + 1) m)
      pure True

-- | Decrement (or remove) the per-origin counter. Idempotent against a
-- key with count 0.
releaseClaim :: StreamGuard -> Text -> STM ()
releaseClaim g origin = modifyTVar' (_streamGuard_perOrigin g) (Map.update dec origin)
  where
    dec n | n <= 1    = Nothing
          | otherwise = Just (n - 1)

-- ---------------------------------------------------------------------------
-- Server lifetime constant (process-global)
-- ---------------------------------------------------------------------------

-- | Per-process @serverStartedAt@ marker. Captured once at first access
-- so restarts (a fresh process) flip the value, letting clients detect a
-- new server (D37). 'unsafePerformIO' is appropriate — value is initialised
-- once and read many times; no IO escapes.
serverStartedAt :: UTCTime
serverStartedAt = unsafePerformIO getCurrentTime
{-# NOINLINE serverStartedAt #-}

-- ---------------------------------------------------------------------------
-- Inbound-frame size cap
-- ---------------------------------------------------------------------------

-- | Cap on inbound WS data-message size, in bytes (D13).
maxInboundBytes :: Int
maxInboundBytes = 4 * 1024

-- | Cap on inbound @since@ token length (D27).
maxSinceLength :: Int
maxSinceLength = 64

-- ---------------------------------------------------------------------------
-- Connection state
-- ---------------------------------------------------------------------------

-- | Per-WS-connection mutable state.
data ConnState = ConnState
  { _conn_focus       :: !(IORef (Maybe SessionId))
  , _conn_origin      :: !Text
  , _conn_originRaw   :: !Text
  , _conn_replayMode  :: !(IORef (Maybe SessionId))
    -- ^ When @Just sid@, the writer buffers 'EntryRecorded' events for
    -- @sid@ instead of forwarding them. @Nothing@ means live mode.
    --
    -- (Stored in an IORef because the WS handler is single-threaded
    -- per-connection; the reader thread sets it under STM only when
    -- aborting a replay mid-flight (D40), where the buffer drain and
    -- the flag flip must observe one consistent moment.)
  , _conn_replayBuf   :: !(IORef [TranscriptEntry])
  }

mkConnState :: Text -> Text -> IO ConnState
mkConnState origin originRaw = do
  focus      <- newIORef Nothing
  replayMode <- newIORef Nothing
  replayBuf  <- newIORef []
  pure ConnState
    { _conn_focus      = focus
    , _conn_origin     = origin
    , _conn_originRaw  = originRaw
    , _conn_replayMode = replayMode
    , _conn_replayBuf  = replayBuf
    }

-- ---------------------------------------------------------------------------
-- streamApp
-- ---------------------------------------------------------------------------

-- | The WS server-app. Returns a 'WS.ServerApp' suitable for composition
-- via 'Network.Wai.Handler.WebSockets.websocketsOr'. The list of allowed
-- origins is supplied by the caller (Server.hs reads it out of
-- @_fc_allowedOrigins@; tests inject their own).
streamApp :: [Text] -> FrontendEnv -> WS.ServerApp
streamApp allowed env pending = do
  let logger = _fe_logger env
  case (_fe_broker env, _fe_streamGuard env) of
    (Just broker, Just guard) ->
      handleUpgrade allowed env broker guard pending
    _ -> do
      _lh_logWarn logger "WS upgrade rejected: streaming disabled"
      WS.rejectRequestWith pending (rejection 503 "streaming disabled")

rejection :: Int -> BS.ByteString -> WS.RejectRequest
rejection code msg = WS.defaultRejectRequest
  { WS.rejectCode    = code
  , WS.rejectMessage = msg
  , WS.rejectBody    = msg
  }

-- | Handle a pending WS upgrade. Order:
-- Origin allowlist → 'tryClaim' → broker subscribe → 'acceptRequest'.
handleUpgrade
  :: [Text]
  -> FrontendEnv
  -> StreamBroker
  -> StreamGuard
  -> WS.PendingConnection
  -> IO ()
handleUpgrade allowed env broker guard pending = do
  let logger    = _fe_logger env
      req       = WS.pendingRequest pending
      headers   = WS.requestHeaders req
      mOriginBS = lookup "Origin" headers
      remote    = maybe "<unknown>" TE.decodeUtf8 (lookup "Host" headers)
  case mOriginBS of
    Nothing -> do
      _lh_logWarn logger $
        "WS upgrade rejected: missing Origin (remote=" <> remote <> ")"
      WS.rejectRequestWith pending (rejection 403 "missing Origin")
    Just rawBytes -> do
      let originRaw  = TE.decodeUtf8 rawBytes
          normalized = normalizeOrigin originRaw
      if not (originAllowed allowed normalized)
        then do
          _lh_logWarn logger $
            "WS upgrade rejected: Origin not allowed (origin="
              <> originRaw <> ", remote=" <> remote <> ")"
          WS.rejectRequestWith pending (rejection 403 "Origin not allowed")
        else do
          claimed <- atomically (tryClaim guard normalized)
          if not claimed
            then do
              _lh_logWarn logger $
                "WS upgrade rejected: per-origin cap reached (origin="
                  <> originRaw <> ", remote=" <> remote <> ")"
              WS.rejectRequestWith pending
                (rejection 503 "per-origin cap reached")
            else do
              subResult <- _streamBroker_subscribe broker
              case subResult of
                Left SubscriberCapReached -> do
                  atomically (releaseClaim guard normalized)
                  _lh_logWarn logger $
                    "WS upgrade rejected: broker cap reached (origin="
                      <> originRaw <> ")"
                  WS.rejectRequestWith pending
                    (rejection 503 "global cap reached")
                Right sub ->
                  bracket
                    (do
                       conn <- WS.acceptRequest pending
                       cs   <- mkConnState normalized originRaw
                       pure (conn, cs))
                    (\_ -> do
                       atomically (releaseClaim guard normalized)
                       _sub_cancel sub)
                    (uncurry (runConnection env sub))

-- ---------------------------------------------------------------------------
-- Per-connection runner
-- ---------------------------------------------------------------------------

-- | Once the upgrade has succeeded, send the hello, install the ping
-- thread, and run the reader/writer race. Any escaped exception is
-- caught, logged at error level, surfaced as @{code:\"internal\"}@,
-- and the connection is closed (D33).
runConnection
  :: FrontendEnv
  -> Subscription
  -> WS.Connection
  -> ConnState
  -> IO ()
runConnection env sub conn cs = do
  let logger = _fe_logger env
  handle (escapeHandler logger) $ do
    sendHello conn
    WS.withPingThread conn pingInterval (pure ()) $
      Async.race_ (readerLoop env conn cs)
                  (writerLoop sub conn cs)
  where
    escapeHandler :: LogHandle -> SomeException -> IO ()
    escapeHandler logger e
      | Just AsyncCancelled <- fromException e = Exception.throwIO e
      | Just (WS.CloseRequest {}) <- fromException e = pure ()
      | Just WS.ConnectionClosed <- fromException e = pure ()
      | otherwise = do
          _lh_logError logger $
            "WS connection internal error (origin=" <> _conn_originRaw cs
              <> "): " <> T.pack (show e)
          _ <- try @SomeException
                 (sendEvent conn (SeError EcInternal (T.pack (show e))))
          pure ()

-- | Ping every 25 s; the websockets lib's pong timeout (10 s) closes the
-- socket if the peer goes silent (D32). Logged via the bracket exit path
-- in 'handleUpgrade'.
pingInterval :: Int
pingInterval = 25

sendHello :: WS.Connection -> IO ()
sendHello conn = sendEvent conn (SeHello "v1" serverStartedAt)

sendEvent :: WS.Connection -> ServerEvent -> IO ()
sendEvent conn ev = WS.sendTextData conn (Aeson.encode (encodeServerEvent ev))

sendError :: WS.Connection -> ErrorCode -> Text -> IO ()
sendError conn code msg = sendEvent conn (SeError code msg)

-- ---------------------------------------------------------------------------
-- Reader loop
-- ---------------------------------------------------------------------------

-- | Read inbound frames forever. Each frame is bounded at 4 KB; oversize
-- frames close the connection. Malformed JSON or unknown ops surface as
-- in-band errors without closing.
readerLoop :: FrontendEnv -> WS.Connection -> ConnState -> IO ()
readerLoop env conn cs = loop
  where
    logger = _fe_logger env
    loop = do
      msg <- try @SomeException (WS.receiveDataMessage conn)
      case msg of
        Left e
          | Just AsyncCancelled <- fromException e -> Exception.throwIO e
          | otherwise -> pure () -- closed
        Right (WS.Text bs _) -> handleData bs >> loop
        Right (WS.Binary _)  -> do
          _lh_logWarn logger "WS rejecting binary frame"
          sendError conn EcInvalidFrame "binary frames not supported"
          loop

    handleData :: LBS.ByteString -> IO ()
    handleData bs
      | LBS.length bs > fromIntegral maxInboundBytes = do
          _lh_logWarn logger "WS frame-too-large: closing"
          sendError conn EcFrameTooLarge "inbound frame exceeded 4 KB"
          WS.sendClose conn ("frame too large" :: BS.ByteString)
      | otherwise = case decodeClientOp bs of
          DrInvalidFrame -> do
            _lh_logWarn logger $ "WS invalid frame: "
              <> TE.decodeUtf8 (BS.take 100 (LBS.toStrict bs))
            sendError conn EcInvalidFrame "malformed JSON"
          DrInvalidOp ->
            sendError conn EcInvalidOp "unknown op"
          DrOk (CoFocus mSid mSince) ->
            handleFocus env conn cs mSid mSince

-- ---------------------------------------------------------------------------
-- Focus / replay
-- ---------------------------------------------------------------------------

-- | Handle a @focus@ op. If @since@ is present and valid, run the replay
-- snapshot algorithm; otherwise just update the focus IORef.
handleFocus
  :: FrontendEnv
  -> WS.Connection
  -> ConnState
  -> Maybe SessionId
  -> Maybe Text
  -> IO ()
handleFocus env conn cs mSid mSince =
  case mSid of
    Just (SessionId raw) | not (isValidSessionId raw) ->
      sendError conn EcSessionNotFound ("invalid session id: " <> raw)
    _ -> case mSince of
      Nothing -> setLiveFocus
      Just s | T.length s > maxSinceLength ->
        sendError conn EcInvalidFrame "since exceeds 64 characters"
      Just sinceTok -> case mSid of
        Nothing  -> sendError conn EcInvalidFrame "since requires sessionId"
        Just sid -> startReplay env conn cs sid sinceTok
  where
    setLiveFocus = do
      abortInflightReplay conn cs
      writeIORef (_conn_focus cs) mSid

-- | Abort any in-flight replay. If a replay was in progress, emit
-- @replay-aborted@ and clear the buffer (D40).
abortInflightReplay :: WS.Connection -> ConnState -> IO ()
abortInflightReplay conn cs = do
  prev <- readIORef (_conn_replayMode cs)
  case prev of
    Nothing -> pure ()
    Just _  -> do
      writeIORef (_conn_replayMode cs) Nothing
      writeIORef (_conn_replayBuf cs) []
      _ <- try @SomeException
             (sendError conn EcReplayAborted "focus changed mid-replay")
      pure ()

-- | Snapshot-based replay algorithm:
--   1. Mark replay-mode for the session; writer starts buffering.
--   2. Update focus IORef.
--   3. Read transcript file (slice after @since@).
--   4. Send each file entry as @entry@.
--   5. Clear replay-mode; drain buffer, dedup against file ids, send.
--   6. Emit @replay-end@.
-- On any I/O error during step 3, clear state and emit @replay-failed@
-- (D28) — the client falls back to HTTP GET.
startReplay
  :: FrontendEnv
  -> WS.Connection
  -> ConnState
  -> SessionId
  -> Text
  -> IO ()
startReplay env conn cs sid sinceId = do
  abortInflightReplay conn cs
  writeIORef (_conn_replayMode cs) (Just sid)
  writeIORef (_conn_replayBuf cs) []
  writeIORef (_conn_focus cs) (Just sid)
  let logger = _fe_logger env
      path   = _fe_sessionsDir env <> "/" <> T.unpack (unSessionId sid) <> "/transcript.jsonl"
  result <- try @SomeException (readReplaySlice path sinceId)
  case result of
    Left e -> do
      _lh_logError logger $
        "replay read failed (session=" <> unSessionId sid <> "): "
          <> T.pack (show e)
      writeIORef (_conn_replayMode cs) Nothing
      writeIORef (_conn_replayBuf cs) []
      sendError conn EcReplayFailed (T.pack (show e))
    Right slice -> do
      forM_ slice $ \e -> sendEvent conn (SeEntry sid e)
      -- Drain buffer; if focus changed mid-replay, abortInflightReplay
      -- already cleared state, and replayMode is Nothing now — skip.
      currentMode <- readIORef (_conn_replayMode cs)
      case currentMode of
        Just sid' | sid' == sid -> do
          buf <- atomicModifyIORef' (_conn_replayBuf cs) ([],)
          writeIORef (_conn_replayMode cs) Nothing
          let dedup   = Set.fromList (map _te_id slice)
              residue = filter (\e -> not (Set.member (_te_id e) dedup)) buf
          forM_ residue $ \e -> sendEvent conn (SeEntry sid e)
          let lastId = case (reverse residue, reverse slice) of
                (e:_, _) -> Just (_te_id e)
                (_, e:_) -> Just (_te_id e)
                _        -> Nothing
          sendEvent conn (SeReplayEnd sid lastId)
        _ -> pure ()  -- focus changed mid-replay; abort path already fired

-- | Read JSONL file at @path@, returning entries strictly after @since@.
readReplaySlice :: FilePath -> Text -> IO [TranscriptEntry]
readReplaySlice path sinceId = do
  raw <- try @SomeException (LBS.readFile path)
  case raw of
    Left e
      | Just ioErr <- fromException e, isDoesNotExistError ioErr -> pure []
      | otherwise -> Exception.throwIO e
    Right contents -> do
      let raws    = filter (not . LBS.null) (LBS.split 0x0A contents)
          entries = [ x | l <- raws, Just x <- [Aeson.decode l] ]
      pure (sliceAfter sinceId entries)
  where
    sliceAfter "" es = es
    sliceAfter s  es = drop 1 (dropWhile (\e -> _te_id e /= s) es)

-- ---------------------------------------------------------------------------
-- Writer loop
-- ---------------------------------------------------------------------------

-- | Drain broker events; filter & forward to the WS peer. The reader
-- thread updates the focus IORef and the replay-mode IORef; the writer
-- consults both for every event.
writerLoop :: Subscription -> WS.Connection -> ConnState -> IO ()
writerLoop sub conn cs = loop
  where
    loop = do
      r <- atomically nextSignal
      case r of
        Left () -> do
          sendEvent conn SeOverflow
          WS.sendClose conn ("overflow" :: BS.ByteString)
        Right ev -> do
          handleEvent ev
          loop

    nextSignal :: STM (Either () BrokerEvent)
    nextSignal =
      (do
        b <- readTVar (_sub_overflow sub)
        if b then pure (Left ()) else retry)
      `orElse`
      (Right <$> readTBQueue (_sub_queue sub))

    handleEvent (EntryRecorded sid entry) = do
      replaying <- readIORef (_conn_replayMode cs)
      focus     <- readIORef (_conn_focus cs)
      case replaying of
        Just rsid | rsid == sid ->
          atomicModifyIORef' (_conn_replayBuf cs) (\xs -> (xs ++ [entry], ()))
        _ -> case focus of
          Just fsid | fsid == sid -> sendEvent conn (SeEntry sid entry)
          _ -> pure ()
    handleEvent (ActivityChanged sid (SaEntryAt t)) =
      sendEvent conn (SeActivity sid (AkEntryAt t))
    handleEvent (ActivityChanged sid (SaHarnessStatus s)) =
      sendEvent conn (SeActivity sid (AkHarnessStatus s))
    handleEvent (ActivityChanged sid (SaSessionCreated meta)) =
      sendEvent conn (SeActivity sid (AkSessionCreated meta))

