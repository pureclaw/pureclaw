-- | HTTP regression tests for the existing JSON endpoints exposed by
-- "PureClaw.Frontend.API" — WU6 (live transcript streaming).
--
-- These endpoints already shipped before the transcript-streaming work
-- (#57) started, but the @test\/Frontend\/@ tree did not yet exercise
-- them through the WAI layer. WU6 lands a regression suite that pins
-- the public JSON shapes (status code, body envelope, key set, runtime
-- types) so that future changes to the API surface cannot silently
-- regress the contract relied upon by the React frontend (WU5) and by
-- the wire-protocol golden fixtures (WU3b).
--
-- DoD coverage:
--
--   * D21 — Coverage gate. This spec is one of the test corpora that
--     close the gap to the @.coverage-thresholds.json@ thresholds on
--     the new WU1–WU5 modules; the others are the in-process broker /
--     activity-probe / WS-integration suites that landed alongside
--     their respective production modules.
--
--   * D23 — HTTP endpoints behave identically before and after the
--     transcript-streaming changes. Each endpoint test asserts (a) the
--     2xx body shape per the 'ToJSON' instance in
--     "PureClaw.Frontend.API", and (b) the documented error responses
--     (404 / 400 / 503). The tests intentionally avoid any reference to
--     'StreamBroker' state or WS subscribers — D23's contract is the
--     legacy HTTP surface in isolation.
--
-- The harness spins up a real Warp server via
-- 'Warp.testWithApplication' on an ephemeral port, then drives it with
-- an HTTP client from "Network.HTTP.Client". The 'FrontendEnv' is
-- assembled with a temporary sessions directory, an empty harness map,
-- and no provider / model (the @send@ endpoint's happy path requires
-- both, so the suite covers the 503 / 404 / 400 paths only; the broker
-- request\/response wiring is exercised in
-- 'Frontend.BroadcastingTranscriptSpec' and
-- 'Frontend.StreamIntegrationSpec').
module Frontend.APISpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as AesonT
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
  ( methodGet
  , methodPost
  , methodPut
  , status200
  , status400
  , status404
  , status503
  , statusCode
  )
import Network.Wai.Handler.Warp qualified as Warp
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Frontend.API
  ( FrontendEnv (..)
  , apiApp
  )
import PureClaw.Handles.Log (mkNoOpLogHandle)

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

-- | Build a 'FrontendEnv' wired with @sessionsDir@ and @agentsDir@,
-- empty harness map, no provider / model, no broker, no stream guard.
-- Suitable for HTTP-only regression tests — the streaming surface is
-- exercised elsewhere ('Frontend.StreamIntegrationSpec',
-- 'Frontend.ActivityProbeSpec', 'Frontend.StreamGoldensSpec').
mkApiEnv :: FilePath -> FilePath -> IO FrontendEnv
mkApiEnv sessionsDir agentsDir = do
  harnesses    <- newIORef Map.empty
  providerRef  <- newIORef Nothing
  modelRef     <- newIORef Nothing
  pure FrontendEnv
    { _fe_harnesses    = harnesses
    , _fe_sessionsDir  = sessionsDir
    , _fe_recentLimit  = 20
    , _fe_provider     = providerRef
    , _fe_model        = modelRef
    , _fe_systemPrompt = Nothing
    , _fe_logger       = mkNoOpLogHandle
    , _fe_agentsDir    = agentsDir
    , _fe_defaultAgent = Nothing
    , _fe_broker       = Nothing
    , _fe_streamGuard  = Nothing
    }

-- | Spin up Warp on an ephemeral port serving 'apiApp', run the test
-- action, then tear it down. Uses 'Warp.testWithApplication' so the
-- caller learns the port via the callback.
withApiServer :: FrontendEnv -> (Int -> IO a) -> IO a
withApiServer env =
  Warp.testWithApplication (pure (apiApp env))

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "GET /api/harnesses" $
    it "returns 200 with a JSON array when no harnesses are configured" $
      withSystemTempDirectory "pureclaw-api-harnesses" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/harnesses"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          arr `shouldBe` V.empty

  describe "GET /api/sessions/recent" $ do
    it "returns 200 with empty array when no sessions exist" $
      withSystemTempDirectory "pureclaw-api-recent-empty" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/sessions/recent"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          arr `shouldBe` V.empty

    it "omits sessions with no transcript entries" $
      withSystemTempDirectory "pureclaw-api-recent-empty-tx" $ \tmp -> do
        -- A session directory whose transcript.jsonl is empty must NOT
        -- be returned (legacy behaviour preserved from
        -- 'handleRecentSessions').
        let sid = "session-empty"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        TIO.writeFile (sd </> "session.json") $
          mconcat
            [ "{\"id\":\"", sid, "\""
            , ",\"runtime\":\"provider\""
            , ",\"model\":\"\""
            , ",\"channel\":\"web\""
            , ",\"created_at\":\"2026-05-23T00:00:00Z\""
            , ",\"last_active\":\"2026-05-23T00:00:00Z\""
            , ",\"bootstrap_consumed\":true"
            , "}"
            ]
        TIO.writeFile (sd </> "transcript.jsonl") ""
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/sessions/recent"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          arr `shouldBe` V.empty

  describe "GET /api/sessions/{sid}/transcript" $ do
    it "rejects a path-traversal session id" $
      withSystemTempDirectory "pureclaw-api-tx-traversal" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          -- The literal pattern '..' inside a path segment is what
          -- 'isValidSessionId' rejects. WAI sometimes pre-normalises the
          -- URL — both 400 (validator-reject) and 404 (route did not
          -- match) are acceptable; the contract is that traversal does
          -- not succeed.
          resp <- httpGet mgr port "/api/sessions/foo%2E%2Ebar/transcript"
          let st = statusCode (HTTP.responseStatus resp)
          st `shouldSatisfy` (`elem` [400, 404])

    it "returns 404 with {\"error\":\"Session not found\"} for a missing session" $
      withSystemTempDirectory "pureclaw-api-tx-missing" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/sessions/does-not-exist/transcript"
          HTTP.responseStatus resp `shouldBe` status404
          errMsg <- decodeErrorField resp
          errMsg `shouldBe` "Session not found"

    it "returns 200 with a JSON array of entries for a real session" $
      withSystemTempDirectory "pureclaw-api-tx-happy" $ \tmp -> do
        -- Hand-write a tiny transcript.jsonl with one Request and one
        -- Response entry; the endpoint must parse, project to
        -- TranscriptEntryInfo, and return the array in insertion order.
        let sid = "session-ok"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        let entryReq = mconcat
              [ "{\"_te_id\":\"e1\""
              , ",\"_te_timestamp\":\"2026-05-23T00:00:00Z\""
              , ",\"_te_harness\":null"
              , ",\"_te_model\":null"
              , ",\"_te_direction\":\"Request\""
              , ",\"_te_payload\":\"hello\""
              , ",\"_te_durationMs\":null"
              , ",\"_te_correlationId\":\"c1\""
              , ",\"_te_metadata\":{}"
              , "}"
              ]
            entryResp = mconcat
              [ "{\"_te_id\":\"e2\""
              , ",\"_te_timestamp\":\"2026-05-23T00:00:01Z\""
              , ",\"_te_harness\":null"
              , ",\"_te_model\":\"test-model\""
              , ",\"_te_direction\":\"Response\""
              , ",\"_te_payload\":\"world\""
              , ",\"_te_durationMs\":null"
              , ",\"_te_correlationId\":\"c1\""
              , ",\"_te_metadata\":{}"
              , "}"
              ]
        TIO.writeFile (sd </> "transcript.jsonl")
          (entryReq <> "\n" <> entryResp <> "\n")
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/sessions/session-ok/transcript"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          V.length arr `shouldBe` 2
          let first  = arr V.! 0
              second = arr V.! 1
          -- D23: pin every documented key in the response envelope.
          objectKeys first  `shouldMatchList`
            ["id", "timestamp", "direction", "payload", "harness", "model"]
          objectKeys second `shouldMatchList`
            ["id", "timestamp", "direction", "payload", "harness", "model"]
          stringField "id"        first  `shouldBe` "e1"
          stringField "direction" first  `shouldBe` "request"
          stringField "payload"   first  `shouldBe` "hello"
          stringField "id"        second `shouldBe` "e2"
          stringField "direction" second `shouldBe` "response"
          stringField "payload"   second `shouldBe` "world"

  describe "POST /api/sessions/new" $ do
    it "returns 200 with a SessionInfo body keyed by the documented fields" $
      withSystemTempDirectory "pureclaw-api-new" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/new" "{}"
          HTTP.responseStatus resp `shouldBe` status200
          v <- decodeValue resp
          objectKeys v `shouldMatchList`
            ["id", "agent", "runtime", "model", "lastActive", "createdAt"]
          stringField "runtime" v `shouldBe` "provider"
          -- model defaults to "" (no model configured); ToJSON encodes
          -- as the empty string per 'toSessionInfo'.
          stringField "model"   v `shouldBe` ""
          -- agent is null when no agent is supplied.
          parseField "agent" v `shouldBe` Just (Nothing :: Maybe Text)

    it "creates the session directory and session.json on disk" $
      withSystemTempDirectory "pureclaw-api-new-disk" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/new" "{}"
          v   <- decodeValue resp
          sid <- requireField "id" v
          let metaPath = tmp </> T.unpack sid </> "session.json"
          metaExists <- doesPathExist metaPath
          metaExists `shouldBe` True

  describe "POST /api/sessions/{sid}/send" $ do
    it "rejects a path-traversal session id" $
      withSystemTempDirectory "pureclaw-api-send-traversal" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/foo%2E%2Ebar/send"
                    "{\"message\":\"hi\"}"
          let st = statusCode (HTTP.responseStatus resp)
          -- Either 400 (validator-reject) or 404 (WAI URL normalisation
          -- collapsed the path). The contract is "does not succeed".
          st `shouldSatisfy` (`elem` [400, 404])

    it "returns 404 when the session directory has no transcript.jsonl" $
      withSystemTempDirectory "pureclaw-api-send-missing" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/no-such/send"
                    "{\"message\":\"hi\"}"
          HTTP.responseStatus resp `shouldBe` status404
          errMsg <- decodeErrorField resp
          errMsg `shouldBe` "Session not found"

    it "returns 503 with {\"error\":\"No provider configured\"} when transcript exists but provider is unset" $
      withSystemTempDirectory "pureclaw-api-send-noprov" $ \tmp -> do
        let sid = "session-with-tx"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        TIO.writeFile (sd </> "transcript.jsonl") ""
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/session-with-tx/send"
                    "{\"message\":\"hi\"}"
          HTTP.responseStatus resp `shouldBe` status503
          errMsg <- decodeErrorField resp
          errMsg `shouldBe` "No provider configured"

    it "returns 400 with {\"error\":...} on invalid JSON body" $
      withSystemTempDirectory "pureclaw-api-send-badjson" $ \tmp -> do
        let sid = "session-bad-json"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        TIO.writeFile (sd </> "transcript.jsonl") ""
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPost mgr port "/api/sessions/session-bad-json/send"
                    "not-json"
          HTTP.responseStatus resp `shouldBe` status400
          errMsg <- decodeErrorField resp
          errMsg `shouldSatisfy` ("Invalid JSON" `T.isInfixOf`)

  describe "PUT /api/sessions/{sid}/prompt" $ do
    it "rejects a path-traversal session id" $
      withSystemTempDirectory "pureclaw-api-prompt-traversal" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPut mgr port "/api/sessions/foo%2E%2Ebar/prompt"
                    "{\"prompt\":\"x\"}"
          let st = statusCode (HTTP.responseStatus resp)
          st `shouldSatisfy` (`elem` [400, 404])

    it "returns 400 with {\"error\":\"Missing 'prompt' field\"} when payload omits prompt" $
      withSystemTempDirectory "pureclaw-api-prompt-missing-field" $ \tmp -> do
        let sid = "session-prompt-mf"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPut mgr port "/api/sessions/session-prompt-mf/prompt"
                    "{\"name\":\"x\"}"
          HTTP.responseStatus resp `shouldBe` status400
          errMsg <- decodeErrorField resp
          errMsg `shouldBe` "Missing 'prompt' field"

    it "returns 400 on an unparseable JSON body" $
      withSystemTempDirectory "pureclaw-api-prompt-bad-json" $ \tmp -> do
        let sid = "session-prompt-bj"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPut mgr port "/api/sessions/session-prompt-bj/prompt"
                    "not-json"
          HTTP.responseStatus resp `shouldBe` status400
          errMsg <- decodeErrorField resp
          errMsg `shouldSatisfy` ("Invalid JSON" `T.isInfixOf`)

    it "returns 200 {\"ok\":true} and writes custom-prompt.md when payload is valid" $
      withSystemTempDirectory "pureclaw-api-prompt-ok" $ \tmp -> do
        let sid = "session-prompt-ok"
            sd  = tmp </> T.unpack sid
        createDirectoryIfMissing True sd
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpPut mgr port "/api/sessions/session-prompt-ok/prompt"
                    "{\"prompt\":\"You are a tester.\"}"
          HTTP.responseStatus resp `shouldBe` status200
          v <- decodeValue resp
          parseField "ok" v `shouldBe` Just True
          -- The handler must have written custom-prompt.md.
          contents <- TIO.readFile (sd </> "custom-prompt.md")
          contents `shouldBe` "You are a tester."

  describe "GET /api/agents" $ do
    it "returns 200 with [] when the agents directory is empty" $
      withSystemTempDirectory "pureclaw-api-agents-empty" $ \tmp -> do
        let agentsDir = tmp </> "agents"
        createDirectoryIfMissing True agentsDir
        env <- mkApiEnv tmp agentsDir
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/agents"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          arr `shouldBe` V.empty

    it "returns 200 with one AgentInfo per agent subdirectory" $
      withSystemTempDirectory "pureclaw-api-agents-one" $ \tmp -> do
        let agentsDir = tmp </> "agents"
        createDirectoryIfMissing True (agentsDir </> "tester")
        env0 <- mkApiEnv tmp agentsDir
        -- Mark "tester" as the default to exercise the isDefault=True branch.
        let env = env0 { _fe_defaultAgent = Just "tester" }
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/agents"
          HTTP.responseStatus resp `shouldBe` status200
          arr <- decodeArray resp
          V.length arr `shouldBe` 1
          let v = arr V.! 0
          objectKeys v `shouldMatchList` ["name", "isDefault"]
          stringField "name" v `shouldBe` "tester"
          parseField "isDefault" v `shouldBe` Just True

  describe "Unknown route" $
    it "returns 404 {\"error\":\"Not found\"} for an unmatched path" $
      withSystemTempDirectory "pureclaw-api-404" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/no-such-route"
          HTTP.responseStatus resp `shouldBe` status404
          errMsg <- decodeErrorField resp
          errMsg `shouldBe` "Not found"

  describe "CORS surface" $
    it "every JSON response carries Access-Control-Allow-Origin: *" $
      withSystemTempDirectory "pureclaw-api-cors" $ \tmp -> do
        env <- mkApiEnv tmp tmp
        withApiServer env $ \port -> do
          mgr <- HTTP.newManager HTTP.defaultManagerSettings
          resp <- httpGet mgr port "/api/harnesses"
          -- D23: CORS allow-origin: '*' is part of the public surface
          -- (the React app at a different origin relies on this).
          let headers = HTTP.responseHeaders resp
          lookup "Access-Control-Allow-Origin" headers
            `shouldBe` Just "*"

-- ---------------------------------------------------------------------------
-- HTTP helpers
-- ---------------------------------------------------------------------------

httpGet :: HTTP.Manager -> Int -> String -> IO (HTTP.Response LBS.ByteString)
httpGet mgr port path = do
  req <- mkReq port path
  HTTP.httpLbs req { HTTP.method = methodGet } mgr

httpPost :: HTTP.Manager -> Int -> String -> LBS.ByteString -> IO (HTTP.Response LBS.ByteString)
httpPost mgr port path body = do
  req <- mkReq port path
  HTTP.httpLbs req
    { HTTP.method         = methodPost
    , HTTP.requestBody    = HTTP.RequestBodyLBS body
    , HTTP.requestHeaders = [("Content-Type", "application/json")]
    } mgr

httpPut :: HTTP.Manager -> Int -> String -> LBS.ByteString -> IO (HTTP.Response LBS.ByteString)
httpPut mgr port path body = do
  req <- mkReq port path
  HTTP.httpLbs req
    { HTTP.method         = methodPut
    , HTTP.requestBody    = HTTP.RequestBodyLBS body
    , HTTP.requestHeaders = [("Content-Type", "application/json")]
    } mgr

mkReq :: Int -> String -> IO HTTP.Request
mkReq port path = do
  req <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
  -- Suppress http-client's status-throwing for 4xx/5xx so we can
  -- assert on the actual status code rather than catch exceptions.
  pure req { HTTP.checkResponse = \_ _ -> pure () }

-- ---------------------------------------------------------------------------
-- JSON helpers
-- ---------------------------------------------------------------------------

-- | Decode a response body as a JSON 'Aeson.Value', failing the test
-- on parse error.
decodeValue :: HTTP.Response LBS.ByteString -> IO Value
decodeValue resp =
  case Aeson.eitherDecode (HTTP.responseBody resp) of
    Right v -> pure v
    Left e  -> do
      expectationFailure $
        "expected JSON body, got parse error: " <> e <>
        " in: " <> show (HTTP.responseBody resp)
      error "unreachable"

-- | Decode a response body as a JSON array.
decodeArray :: HTTP.Response LBS.ByteString -> IO (V.Vector Value)
decodeArray resp = do
  v <- decodeValue resp
  case v of
    Array xs -> pure xs
    _        -> do
      expectationFailure $ "expected JSON array, got: " <> show v
      error "unreachable"

-- | Decode the @"error"@ field from an error envelope.
decodeErrorField :: HTTP.Response LBS.ByteString -> IO Text
decodeErrorField resp = do
  v <- decodeValue resp
  case AesonT.parseEither (Aeson.withObject "err" (Aeson..: "error")) v of
    Right t -> pure t
    Left e  -> do
      expectationFailure $ "expected {\"error\":...}: " <> e
      error "unreachable"

-- | Return the field names of a JSON object as a list of Text.
objectKeys :: Value -> [Text]
objectKeys (Object o) = map (Key.toText . fst) (KM.toList o)
objectKeys v          = error $ "objectKeys: expected Object, got " <> show v

-- | Extract a 'Text' field by name from a JSON object.
stringField :: Text -> Value -> Text
stringField k v =
  case AesonT.parseEither parser v of
    Right t -> t
    Left e  -> error $ "stringField " <> show k <> ": " <> e
  where
    parser = Aeson.withObject "obj" (\o -> o Aeson..: Key.fromText k)

-- | Parse a typed field. Returns 'Nothing' on parse failure so callers
-- can use it inside 'shouldBe' without raising mid-assertion.
parseField :: Aeson.FromJSON a => Text -> Value -> Maybe a
parseField k v =
  case AesonT.parseEither (Aeson.withObject "obj" (\o -> o Aeson..: Key.fromText k)) v of
    Right t -> Just t
    Left _  -> Nothing

-- | Read a required text field, failing the test if absent.
requireField :: Text -> Value -> IO Text
requireField k v =
  case AesonT.parseEither (Aeson.withObject "obj" (\o -> o Aeson..: Key.fromText k)) v of
    Right t -> pure t
    Left e  -> do
      expectationFailure $ "missing field " <> show k <> ": " <> e
      error "unreachable"

-- ---------------------------------------------------------------------------
-- IO helpers
-- ---------------------------------------------------------------------------

doesPathExist :: FilePath -> IO Bool
doesPathExist p = do
  r <- try @SomeException (TIO.readFile p)
  case r of
    Left _  -> pure False
    Right _ -> pure True
