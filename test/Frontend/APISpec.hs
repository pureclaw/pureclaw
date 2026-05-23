{-# OPTIONS_GHC -Wno-x-partial #-}
{- HLINT ignore "Use head" -}
module Frontend.APISpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson (object, (.=))
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Builder qualified
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Core.Types (ModelId (..), SessionId (..))
import PureClaw.Frontend.API
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Session.Types (SessionMeta (..), SessionKind (..), ProviderSpec (..), inferProviderId)

spec :: Spec
spec = do
  describe "POST /api/tabs/new" $ do
    it "creates a provider tab and returns tab_index + session_id" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "kind" .= object
                [ "tag" .= ("session" :: T.Text)
                , "session_kind" .= object
                    [ "tag"      .= ("provider" :: T.Text)
                    , "provider" .= ("anthropic" :: T.Text)
                    , "model"    .= ("claude-sonnet-4-20250514" :: T.Text)
                    ]
                ]
            ]
      (st, respBody) <- postJSON env ["api", "tabs", "new"] body
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (val :: Aeson.Value) -> do
          lookupKey val "tab_index" `shouldBe` Just (Aeson.Number 0)
          -- session_id should be a non-null string
          case lookupKey val "session_id" of
            Just (Aeson.String sid) -> sid `shouldSatisfy` (not . T.null)
            _ -> expectationFailure "Expected session_id to be a non-null string"
          lookupKey val "kind" `shouldBe` Just (Aeson.String "provider")

    it "creates a raw shell tab and returns session_id as null" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "kind" .= object
                [ "tag" .= ("raw_shell" :: T.Text)
                , "backend" .= object
                    [ "tag" .= ("local" :: T.Text)
                    ]
                ]
            ]
      (st, respBody) <- postJSON env ["api", "tabs", "new"] body
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (val :: Aeson.Value) -> do
          lookupKey val "tab_index" `shouldBe` Just (Aeson.Number 0)
          lookupKey val "session_id" `shouldBe` Just Aeson.Null
          lookupKey val "kind" `shouldBe` Just (Aeson.String "raw_shell")

    it "returns error when at maxTabs" $ do
      env <- mkTestFrontendEnvWith 0  -- maxTabs = 0
      let body = Aeson.encode $ object
            [ "kind" .= object
                [ "tag" .= ("session" :: T.Text)
                , "session_kind" .= object
                    [ "tag"      .= ("provider" :: T.Text)
                    , "provider" .= ("anthropic" :: T.Text)
                    , "model"    .= ("claude-sonnet-4-20250514" :: T.Text)
                    ]
                ]
            ]
      (st, respBody) <- postJSON env ["api", "tabs", "new"] body
      st `shouldBe` HTTP.status409
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (val :: Aeson.Value) ->
          lookupKey val "error" `shouldSatisfy` isJustString

    it "returns 400 on invalid JSON body" $ do
      env <- mkTestFrontendEnv
      (st, _) <- postJSON env ["api", "tabs", "new"] "not valid json"
      st `shouldBe` HTTP.status400

    it "response JSON uses snake_case keys" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "kind" .= object
                [ "tag" .= ("session" :: T.Text)
                , "session_kind" .= object
                    [ "tag"      .= ("provider" :: T.Text)
                    , "provider" .= ("anthropic" :: T.Text)
                    , "model"    .= ("claude-sonnet-4-20250514" :: T.Text)
                    ]
                ]
            ]
      (_, respBody) <- postJSON env ["api", "tabs", "new"] body
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (val :: Aeson.Value) -> do
          hasKey val "tab_index" `shouldBe` True
          hasKey val "session_id" `shouldBe` True
          hasKey val "kind" `shouldBe` True

  describe "POST /api/sessions/new (410 Gone)" $ do
    it "returns 410 Gone status" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "agent" .= ("test" :: T.Text) ]
      (st, _) <- postJSON env ["api", "sessions", "new"] body
      st `shouldBe` HTTP.status410

    it "includes Location header pointing to /api/tabs/new" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "agent" .= ("test" :: T.Text) ]
      (_, _, hdrs) <- postJSONFull env ["api", "sessions", "new"] body
      lookup "Location" hdrs `shouldBe` Just "/api/tabs/new"

    it "returns deprecation error body" $ do
      env <- mkTestFrontendEnv
      let body = Aeson.encode $ object
            [ "agent" .= ("test" :: T.Text) ]
      (_, respBody) <- postJSON env ["api", "sessions", "new"] body
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (val :: Aeson.Value) -> do
          lookupKey val "error" `shouldBe` Just (Aeson.String "deprecated")
          lookupKey val "use" `shouldBe` Just (Aeson.String "/api/tabs/new")


  -- -----------------------------------------------------------------------
  -- WU-8: GET /api/tabs
  -- -----------------------------------------------------------------------

  describe "GET /api/tabs" $ do
    it "returns an empty list when no tabs are open" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      respBody `shouldBe` Aeson.encode ([] :: [Aeson.Value])

    it "returns tab list with correct status words" $ do
      let tabs =
            [ TabSnapshot
                { _ts_index     = 0
                , _ts_kind      = "provider"
                , _ts_name      = "claude-opus"
                , _ts_status    = "running"
                , _ts_sessionId = Just "session-001"
                }
            , TabSnapshot
                { _ts_index     = 1
                , _ts_kind      = "raw_shell"
                , _ts_name      = "bash"
                , _ts_status    = "idle"
                , _ts_sessionId = Nothing
                }
            , TabSnapshot
                { _ts_index     = 2
                , _ts_kind      = "provider"
                , _ts_name      = "gpt"
                , _ts_status    = "crashed"
                , _ts_sessionId = Just "session-002"
                }
            ]
      env <- mkTestFrontendEnvWithTabs tabs
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (Aeson.Array arr) -> do
          let items = toList' arr
          length items `shouldBe` 3
          -- Check first tab (running)
          let t0 = head items
          lookupKey t0 "index"      `shouldBe` Just (Aeson.Number 0)
          lookupKey t0 "kind"       `shouldBe` Just (Aeson.String "provider")
          lookupKey t0 "name"       `shouldBe` Just (Aeson.String "claude-opus")
          lookupKey t0 "status"     `shouldBe` Just (Aeson.String "running")
          lookupKey t0 "session_id" `shouldBe` Just (Aeson.String "session-001")
          -- Check second tab (idle, no session)
          let t1 = items !! 1
          lookupKey t1 "status"     `shouldBe` Just (Aeson.String "idle")
          lookupKey t1 "session_id" `shouldBe` Just Aeson.Null
          -- Check third tab (crashed)
          let t2 = items !! 2
          lookupKey t2 "status"     `shouldBe` Just (Aeson.String "crashed")
        Just _ -> expectationFailure "Expected JSON array"

  -- -----------------------------------------------------------------------
  -- WU-8: GET /api/sessions/recent excludes active-tab sessions
  -- -----------------------------------------------------------------------

  describe "GET /api/sessions/recent (active-tab filtering)" $ do
    it "excludes sessions that are in active tabs" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        -- Create two sessions on disk
        let sid1 = "test-20240101-120000-001"
            sid2 = "test-20240101-120000-002"
        writeTestSession tmpDir sid1 False
        writeTestSession tmpDir sid2 False
        -- Tab has session sid1 open
        let tabs = [ TabSnapshot 0 "provider" "tab0" "running" (Just sid1) ]
        env <- mkTestFrontendEnvWithTabsAndDir tabs tmpDir
        (st, respBody) <- getJSON env ["api", "sessions", "recent"]
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Nothing -> expectationFailure "Could not decode response JSON"
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` notElem sid1
            ids `shouldSatisfy` elem sid2
          Just _ -> expectationFailure "Expected JSON array"

    it "archived sessions do not appear in recent" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid1 = "test-20240101-120000-001"
            sid2 = "test-20240101-120000-002"
        writeTestSession tmpDir sid1 False
        writeTestSession tmpDir sid2 True  -- archived
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- getJSON env ["api", "sessions", "recent"]
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Nothing -> expectationFailure "Could not decode response JSON"
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` elem sid1
            ids `shouldSatisfy` notElem sid2
          Just _ -> expectationFailure "Expected JSON array"

  -- -----------------------------------------------------------------------
  -- WU-8: GET /api/sessions/archived
  -- -----------------------------------------------------------------------

  describe "GET /api/sessions/archived" $ do
    it "returns only archived sessions" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid1 = "test-20240101-120000-001"
            sid2 = "test-20240101-120000-002"
        writeTestSession tmpDir sid1 False
        writeTestSession tmpDir sid2 True  -- archived
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- getJSON env ["api", "sessions", "archived"]
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Nothing -> expectationFailure "Could not decode response JSON"
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldBe` [sid2]
          Just _ -> expectationFailure "Expected JSON array"

    it "returns empty list when no sessions are archived" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid1 = "test-20240101-120000-001"
        writeTestSession tmpDir sid1 False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- getJSON env ["api", "sessions", "archived"]
        st `shouldBe` HTTP.status200
        respBody `shouldBe` Aeson.encode ([] :: [Aeson.Value])

  -- -----------------------------------------------------------------------
  -- WU-8: POST /api/sessions/{id}/archive and /unarchive idempotence
  -- -----------------------------------------------------------------------

  describe "POST /api/sessions/{id}/archive and /unarchive" $ do
    it "archive is idempotent (archiving twice succeeds)" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-001"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Archive once
        (st1, _) <- postJSON env ["api", "sessions", sid, "archive"] ""
        st1 `shouldBe` HTTP.status200
        -- Archive again (idempotent)
        (st2, body2) <- postJSON env ["api", "sessions", sid, "archive"] ""
        st2 `shouldBe` HTTP.status200
        case Aeson.decode body2 of
          Nothing -> expectationFailure "Could not decode response"
          Just val -> lookupKey val "archived" `shouldBe` Just (Aeson.Bool True)

    it "unarchive is idempotent (unarchiving non-archived succeeds)" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-001"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Unarchive a non-archived session (no-op success)
        (st1, body1) <- postJSON env ["api", "sessions", sid, "unarchive"] ""
        st1 `shouldBe` HTTP.status200
        case Aeson.decode body1 of
          Nothing -> expectationFailure "Could not decode response"
          Just val -> lookupKey val "archived" `shouldBe` Just (Aeson.Bool False)

    it "archive then unarchive round-trips" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-001"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Archive
        (st1, _) <- postJSON env ["api", "sessions", sid, "archive"] ""
        st1 `shouldBe` HTTP.status200
        -- Verify it appears in archived list
        (_, arBody) <- getJSON env ["api", "sessions", "archived"]
        case Aeson.decode arBody of
          Nothing -> expectationFailure "Could not decode archived list"
          Just (Aeson.Array arr) ->
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            in ids `shouldSatisfy` elem sid
          Just _ -> expectationFailure "Expected JSON array"
        -- Unarchive
        (st2, _) <- postJSON env ["api", "sessions", sid, "unarchive"] ""
        st2 `shouldBe` HTTP.status200
        -- Verify it no longer appears in archived list
        (_, arBody2) <- getJSON env ["api", "sessions", "archived"]
        case Aeson.decode arBody2 of
          Nothing -> expectationFailure "Could not decode archived list"
          Just (Aeson.Array arr2) ->
            let ids2 = [ t | v <- toList' arr2
                           , Just (Aeson.String t) <- [lookupKey v "id"] ]
            in ids2 `shouldSatisfy` notElem sid
          Just _ -> expectationFailure "Expected JSON array"

    it "returns 404 for nonexistent session" $ do
      env <- mkTestFrontendEnv
      (st, _) <- postJSON env ["api", "sessions", "nonexistent", "archive"] ""
      st `shouldBe` HTTP.status404

  -- -----------------------------------------------------------------------
  -- WU-14: POST /api/tabs/{index}/close
  -- -----------------------------------------------------------------------

  describe "POST /api/tabs/{index}/close" $ do
    it "succeeds when _fe_closeTab returns Right ()" $ do
      env <- mkTestFrontendEnv
      let env' = env { _fe_closeTab = \_ -> pure (Right ()) }
      (st, respBody) <- postJSON env' ["api", "tabs", "0", "close"] ""
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "closed" `shouldBe` Just (Aeson.Bool True)

    it "returns 404 when _fe_closeTab returns Left with error" $ do
      env <- mkTestFrontendEnv
      let env' = env { _fe_closeTab = \_ -> pure (Left "tab: not found") }
      (st, respBody) <- postJSON env' ["api", "tabs", "5", "close"] ""
      st `shouldBe` HTTP.status404
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "error" `shouldBe` Just (Aeson.String "tab: not found")

    it "returns 400 for non-numeric tab index" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- postJSON env ["api", "tabs", "abc", "close"] ""
      st `shouldBe` HTTP.status400
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "error" `shouldBe` Just (Aeson.String "Invalid tab index")

    it "passes the correct index to _fe_closeTab" $ do
      receivedRef <- newIORef (Nothing :: Maybe Int)
      env <- mkTestFrontendEnv
      let env' = env { _fe_closeTab = \idx -> do
                         writeIORef receivedRef (Just idx)
                         pure (Right ())
                     }
      (st, _) <- postJSON env' ["api", "tabs", "7", "close"] ""
      st `shouldBe` HTTP.status200
      received <- readIORef receivedRef
      received `shouldBe` Just 7


-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Build a minimal FrontendEnv for testing.
mkTestFrontendEnv :: IO FrontendEnv
mkTestFrontendEnv = mkTestFrontendEnvWith 36

mkTestFrontendEnvWith :: Int -> IO FrontendEnv
mkTestFrontendEnvWith maxTabs = do
  harnessRef  <- newIORef Map.empty
  provRef     <- newIORef Nothing
  modelRef    <- newIORef Nothing
  let logger  = mkNoOpLogHandle
  tabCountRef <- newIORef 0
  pure FrontendEnv
    { _fe_harnesses    = harnessRef
    , _fe_sessionsDir  = "/tmp/pureclaw-test-sessions"
    , _fe_recentLimit  = 20
    , _fe_provider     = provRef
    , _fe_model        = modelRef
    , _fe_systemPrompt = Nothing
    , _fe_logger       = logger
    , _fe_agentsDir    = "/tmp/pureclaw-test-agents"
    , _fe_defaultAgent = Nothing
    , _fe_maxTabs      = maxTabs
    , _fe_tabCount     = tabCountRef
    , _fe_listTabs     = pure []
    , _fe_closeTab     = \_ -> pure (Left "not wired in test")
    , _fe_listModels   = \_ -> pure []
    , _fe_listProviders = pure ([] :: [ProviderInfo])
    }

-- | Build a FrontendEnv with a pre-set tab listing.
mkTestFrontendEnvWithTabs :: [TabSnapshot] -> IO FrontendEnv
mkTestFrontendEnvWithTabs tabs = do
  env <- mkTestFrontendEnv
  pure env { _fe_listTabs = pure tabs }

-- | Build a FrontendEnv with tabs and a real sessions directory.
mkTestFrontendEnvWithTabsAndDir :: [TabSnapshot] -> FilePath -> IO FrontendEnv
mkTestFrontendEnvWithTabsAndDir tabs dir = do
  env <- mkTestFrontendEnvWithTabs tabs
  pure env { _fe_sessionsDir = dir }

-- | Write a minimal session.json + transcript.jsonl to disk so that
-- @listSessions@ and @handleRecentSessions@ pick it up.
writeTestSession :: FilePath -> Text -> Bool -> IO ()
writeTestSession baseDir sid archived = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = Nothing
        , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "claude-sonnet-4-20250514") (ModelId "claude-sonnet-4-20250514") Nothing)
        , _sm_model             = "claude-sonnet-4-20250514"
        , _sm_channel           = "web"
        , _sm_createdAt         = epoch
        , _sm_lastActive        = epoch
        , _sm_bootstrapConsumed = True
        , _sm_archived          = archived
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        }
      epoch = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  -- Write a non-empty transcript so hasTranscriptEntries returns True
  LBS.writeFile (dir </> "transcript.jsonl") "{\"id\":\"1\",\"timestamp\":\"2024-01-01T00:00:00Z\",\"direction\":\"request\",\"payload\":\"hello\",\"metadata\":{}}\n"

-- | GET a path from the apiApp and return (status, response body).
getJSON :: FrontendEnv -> [Text] -> IO (HTTP.Status, LBS.ByteString)
getJSON env pathParts = do
  ref <- newIORef (Nothing :: Maybe Wai.Response)
  let req = Wai.defaultRequest
        { Wai.requestMethod  = "GET"
        , Wai.pathInfo       = pathParts
        , Wai.requestHeaders = [(HTTP.hContentType, "application/json")]
        }
      capture resp = do
        writeIORef ref (Just resp)
        pure ResponseReceived
  _ <- apiApp env req capture
  Just resp <- readIORef ref
  let (st, _, _) = Wai.responseToStream resp
  respBody <- extractBody resp
  pure (st, respBody)

-- | POST a JSON body to the apiApp and return (status, response body).
postJSON :: FrontendEnv -> [Text] -> LBS.ByteString
         -> IO (HTTP.Status, LBS.ByteString)
postJSON env pathParts body = do
  (st, respBody, _) <- postJSONFull env pathParts body
  pure (st, respBody)

-- | POST a JSON body and return (status, body, headers).
postJSONFull :: FrontendEnv -> [Text] -> LBS.ByteString
             -> IO (HTTP.Status, LBS.ByteString, [HTTP.Header])
postJSONFull env pathParts body = do
  ref <- newIORef (Nothing :: Maybe Wai.Response)
  bodyRef <- newIORef (LBS.toChunks body)
  let getChunk = do
        chunks <- readIORef bodyRef
        case chunks of
          []     -> pure mempty
          (c:cs) -> writeIORef bodyRef cs >> pure c
      req = Wai.setRequestBodyChunks getChunk
          $ Wai.defaultRequest
        { Wai.requestMethod  = "POST"
        , Wai.pathInfo       = pathParts
        , Wai.requestHeaders = [(HTTP.hContentType, "application/json")]
        }
      capture resp = do
        writeIORef ref (Just resp)
        pure ResponseReceived
  _ <- apiApp env req capture
  Just resp <- readIORef ref
  let (st, hdrs, _) = Wai.responseToStream resp
  respBody <- extractBody resp
  pure (st, respBody, hdrs)

-- | Extract the full response body from a WAI Response.
--
-- 'Wai.responseToStream' yields a streaming-body callback whose chunks
-- are 'Builder' values. We convert each chunk to a strict 'ByteString'
-- via 'Data.ByteString.Builder.toLazyByteString' and accumulate.
extractBody :: Wai.Response -> IO LBS.ByteString
extractBody resp = do
  let (_, _, withBody) = Wai.responseToStream resp
  ref <- newIORef mempty
  withBody $ \streamingBody ->
    streamingBody
      (\builder -> modifyIORef ref
         (<> Data.ByteString.Builder.toLazyByteString builder))
      (pure ())
  readIORef ref

-- | Look up a key in a JSON Value (must be an Object).
lookupKey :: Aeson.Value -> Text -> Maybe Aeson.Value
lookupKey (Aeson.Object o) k = KM.lookup (AesonKey.fromText k) o
lookupKey _ _ = Nothing

-- | Check if a key exists in a JSON Object.
hasKey :: Aeson.Value -> Text -> Bool
hasKey v k = case lookupKey v k of
  Nothing -> False
  Just _  -> True

-- | Check if a Maybe Aeson.Value is a Just containing a String.
isJustString :: Maybe Aeson.Value -> Bool
isJustString (Just (Aeson.String _)) = True
isJustString _                       = False

-- | Convert an Aeson Array (Vector) to a list.
toList' :: Aeson.Array -> [Aeson.Value]
toList' = foldr (:) []
