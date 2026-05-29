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
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Agent.AgentDef (mkAgentName, unAgentName)
import PureClaw.Core.Types (ModelId (..), SessionId (..), ToolCallId (..))
import PureClaw.Frontend.API
import PureClaw.Handles.Log (mkNoOpLogHandle)
import PureClaw.Providers.Class
  ( CompletionRequest (..)
  , CompletionResponse (..)
  , ContentBlock (..)
  , Message (..)
  , SomeProvider (MkProvider)
  , ToolDefinition (..)
  )
import PureClaw.Session.Types
  ( SessionMeta (..)
  , SessionKind (..)
  , ProviderSpec (..)
  , HarnessSpec (..)
  , TerminalBackend (..)
  , TmuxConfig (..)
  , fixedFlavourLookup
  , inferProviderId
  )
import PureClaw.Transcript.Types
  ( Direction (..)
  , TranscriptEntry (..)
  , encodePayload
  )
import PureClaw.Tools.Registry
  ( ToolHandler (..)
  , emptyRegistry
  , registerTool
  )
import Test.Fake.Provider (FakeProvider, newFakeProvider, peekRecorded, queueResponse, queueResponses)

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

  -- -----------------------------------------------------------------------
  -- WU1 — POST /api/tabs/new with branch_from (session branching)
  -- -----------------------------------------------------------------------

  describe "POST /api/tabs/new (branch_from)" $ do
    -- D1: a non-branch POST behaves byte-for-byte as today.
    it "non-branch POST still creates a provider tab unchanged (D1)" $ do
      withSystemTempDirectory "pureclaw-branch-d1" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"] providerNewTabBody
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Just (val :: Aeson.Value) ->
            lookupKey val "kind" `shouldBe` Just (Aeson.String "provider")
          Nothing -> expectationFailure "Could not decode response JSON"
        readIORef (_fe_tabCount env) `shouldReturn` 1

    -- D3: branch copies the source prefix verbatim (incl. _te_id, order)
    -- and inherits _sm_model / _sm_agent from the source meta.
    it "copies the source prefix and inherits source metadata (D3, D3a)" $ do
      withSystemTempDirectory "pureclaw-branch-d3" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d3" (Just "helper") Nothing
          [ branchReqEntry "e1" "q1"
          , branchRespEntry "e2" "a1"
          , branchReqEntry "e3" "q2"
          , branchRespEntry "e4" "a2"
          ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d3" "e3")
        st `shouldBe` HTTP.status200
        newSid <- case Aeson.decode respBody of
          Just (val :: Aeson.Value) -> case lookupKey val "session_id" of
            Just (Aeson.String s) -> pure s
            _ -> expectationFailure "expected session_id string" >> pure ""
          Nothing -> expectationFailure "Could not decode response JSON" >> pure ""
        -- New transcript holds exactly the inclusive prefix [e1,e2,e3].
        entries <- readBranchTranscript tmpDir newSid
        map _te_id entries `shouldBe` ["e1", "e2", "e3"]
        -- Inherited metadata: agent carried through from the source.
        Right meta <- Aeson.eitherDecodeFileStrict'
          (tmpDir </> T.unpack newSid </> "session.json")
          :: IO (Either String SessionMeta)
        fmap unAgentName (_sm_agent meta) `shouldBe` Just "helper"
        _sm_model meta `shouldBe` "claude-sonnet-4-20250514"

    -- D3b: source without an agent ⇒ branch's agent is Nothing.
    it "inherits Nothing agent when source has none (D3b)" $ do
      withSystemTempDirectory "pureclaw-branch-d3b" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d3b" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d3b" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        Right meta <- Aeson.eitherDecodeFileStrict'
          (tmpDir </> T.unpack newSid </> "session.json")
          :: IO (Either String SessionMeta)
        _sm_agent meta `shouldBe` Nothing

    -- D6: branch of a source WITH custom-prompt.md copies it.
    it "copies custom-prompt.md from the source (D6)" $ do
      withSystemTempDirectory "pureclaw-branch-d6" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d6" Nothing (Just "you are a branch")
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d6" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        let promptPath = tmpDir </> T.unpack newSid </> "custom-prompt.md"
        doesFileExist promptPath `shouldReturn` True
        contents <- TIO.readFile promptPath
        contents `shouldBe` "you are a branch"

    -- D6b: branch of a source WITHOUT custom-prompt.md creates none.
    it "creates no custom-prompt.md when the source has none (D6b)" $ do
      withSystemTempDirectory "pureclaw-branch-d6b" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d6b" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d6b" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        let promptPath = tmpDir </> T.unpack newSid </> "custom-prompt.md"
        doesFileExist promptPath `shouldReturn` False

    -- D4: branch with a non-provider target TabKind ⇒ 400.
    it "rejects a branch with a raw_shell target kind (D4)" $ do
      withSystemTempDirectory "pureclaw-branch-d4" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d4" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let body = Aeson.encode $ object
              [ "kind" .= object
                  [ "tag" .= ("raw_shell" :: T.Text)
                  , "backend" .= object ["tag" .= ("local" :: T.Text)]
                  ]
              , "branch_from" .= object
                  [ "session_id"     .= ("src-d4" :: T.Text)
                  , "up_to_entry_id" .= ("e1" :: T.Text)
                  ]
              ]
        (st, respBody) <- postJSON env ["api", "tabs", "new"] body
        st `shouldBe` HTTP.status400
        expectErrorContains respBody "provider session"
        readIORef (_fe_tabCount env) `shouldReturn` 0

    -- D5: error mapping + tab-count invariance.
    it "maps an invalid/traversal source id to 400 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5a" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "../evil" "e1")
        st `shouldBe` HTTP.status400
        expectErrorContains respBody "invalid branch source id"
        readIORef (_fe_tabCount env) `shouldReturn` 0

    it "maps an unknown source session to 404 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5b" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "ghost" "e1")
        st `shouldBe` HTTP.status404
        expectErrorContains respBody "branch source session not found"
        readIORef (_fe_tabCount env) `shouldReturn` 0

    it "maps a harness source to 400 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5c" $ \tmpDir -> do
        writeHarnessBranchSource tmpDir "src-harness"
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-harness" "e1")
        st `shouldBe` HTTP.status400
        expectErrorContains respBody "not a provider session"
        readIORef (_fe_tabCount env) `shouldReturn` 0

    it "maps an unknown entry id to 404 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5d" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d5d" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d5d" "nope")
        st `shouldBe` HTTP.status404
        expectErrorContains respBody "branch source entry not found"
        readIORef (_fe_tabCount env) `shouldReturn` 0

    -- D5: repeated failing branch POSTs do not consume tab slots.
    it "leaves _fe_tabCount unchanged after repeated failing branches (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5e" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let post = postJSON env ["api", "tabs", "new"] (branchBody "ghost" "e1")
        (s1, _) <- post
        (s2, _) <- post
        (s3, _) <- post
        [s1, s2, s3] `shouldBe` [HTTP.status404, HTTP.status404, HTTP.status404]
        readIORef (_fe_tabCount env) `shouldReturn` 0

    -- D6 integration (UPDATED for §9.1 frozen-prompt; WU7/R1 will subsume
    -- this): a branch's first /send replays the copied prefix AND freezes
    -- the system_prompt recorded in the copied prefix's last Request entry,
    -- rather than recomputing it. (Pre-§9 this asserted the copied
    -- custom-prompt.md; §9 supersedes the fork's custom-prompt copy — the
    -- prompt now rides in the transcript.)
    it "first send replays the prefix and freezes the prefix's recorded prompt (D6)" $ do
      withSystemTempDirectory "pureclaw-branch-d6-send" $ \tmpDir -> do
        writeBranchSource tmpDir "src-send" Nothing Nothing
          [ branchReqEntryWithPrompt "e1" "q1" (Just "frozen prefix prompt")
          , branchRespEntry "e2" "a1"
          ]
        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "ok"]
          , _crsp_model   = ModelId "claude-sonnet-4-20250514"
          , _crsp_usage   = Nothing
          }
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "claude-sonnet-4-20250514"))
        let env = env0
              { _fe_provider = provRef
              , _fe_model = modelRef
              , _fe_systemPrompt = Just "GLOBAL (should be ignored)"
              }
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-send" "e2")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        (sendSt, _) <- postJSON env ["api", "sessions", newSid, "send"]
          (Aeson.encode (object ["message" .= ("continue" :: T.Text)]))
        sendSt `shouldBe` HTTP.status200
        recorded <- peekRecorded fakeProv
        case recorded of
          (creq:_) -> do
            -- The frozen prompt comes from the copied transcript, not the
            -- global fallback.
            _cr_systemPrompt creq `shouldBe` Just "frozen prefix prompt"
            -- The replayed prefix turns are present in the context.
            let blob = T.intercalate "\n"
                  [ t | Message _ blocks <- _cr_messages creq
                      , TextBlock t <- blocks ]
            (("q1" `T.isInfixOf` blob) && ("a1" `T.isInfixOf` blob))
              `shouldBe` True
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- D6b integration (UPDATED for §9.1; WU7/R5 will subsume this): a branch
    -- whose copied prefix's last Request recorded a null/absent system_prompt
    -- freezes null — it does NOT recompute, so the global prompt is ignored.
    it "first send freezes a null prefix prompt as null (D6b)" $ do
      withSystemTempDirectory "pureclaw-branch-d6b-send" $ \tmpDir -> do
        writeBranchSource tmpDir "src-send-b" Nothing Nothing
          [ branchReqEntryWithPrompt "e1" "q1" Nothing ]
        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "ok"]
          , _crsp_model   = ModelId "claude-sonnet-4-20250514"
          , _crsp_usage   = Nothing
          }
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "claude-sonnet-4-20250514"))
        let env = env0
              { _fe_provider = provRef
              , _fe_model = modelRef
              , _fe_systemPrompt = Just "GLOBAL PROMPT"
              }
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-send-b" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        (sendSt, _) <- postJSON env ["api", "sessions", newSid, "send"]
          (Aeson.encode (object ["message" .= ("continue" :: T.Text)]))
        sendSt `shouldBe` HTTP.status200
        recorded <- peekRecorded fakeProv
        case recorded of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Nothing
          []       -> expectationFailure "expected a recorded CompletionRequest"

    -- A present-but-malformed branch_from (missing required keys) fails to
    -- parse and returns 400 (also exercises the BranchSpec FromJSON failure
    -- label).
    it "rejects a malformed branch_from object with 400" $ do
      withSystemTempDirectory "pureclaw-branch-malformed" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let body = Aeson.encode $ object
              [ "kind" .= object
                  [ "tag" .= ("session" :: T.Text)
                  , "session_kind" .= object
                      [ "tag"      .= ("provider" :: T.Text)
                      , "provider" .= ("anthropic" :: T.Text)
                      , "model"    .= ("claude-sonnet-4-20250514" :: T.Text)
                      ]
                  ]
              , "branch_from" .= object [ "wrong_key" .= ("x" :: T.Text) ]
              ]
        (st, _) <- postJSON env ["api", "tabs", "new"] body
        st `shouldBe` HTTP.status400
        readIORef (_fe_tabCount env) `shouldReturn` 0

    -- A branch_from that is not even a JSON object exercises the
    -- BranchSpec 'withObject' type-mismatch label.
    it "rejects a non-object branch_from with 400" $ do
      withSystemTempDirectory "pureclaw-branch-nonobj" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let body = Aeson.encode $ object
              [ "kind" .= object
                  [ "tag" .= ("session" :: T.Text)
                  , "session_kind" .= object
                      [ "tag"      .= ("provider" :: T.Text)
                      , "provider" .= ("anthropic" :: T.Text)
                      , "model"    .= ("claude-sonnet-4-20250514" :: T.Text)
                      ]
                  ]
              , "branch_from" .= ("not-an-object" :: T.Text)
              ]
        (st, _) <- postJSON env ["api", "tabs", "new"] body
        st `shouldBe` HTTP.status400
        readIORef (_fe_tabCount env) `shouldReturn` 0

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
  -- POST /api/sessions/{sid}/send — tool registry forwarding
  -- -----------------------------------------------------------------------

  describe "POST /api/sessions/{sid}/send" $ do
    it "forwards registered tools into the CompletionRequest" $ do
      withSystemTempDirectory "pureclaw-send-tools" $ \tmpDir -> do
        let sid = "test-session-tools"
            sessionDir = tmpDir </> T.unpack sid
        createDirectoryIfMissing True sessionDir
        LBS.writeFile (sessionDir </> "transcript.jsonl") ""

        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "ok"]
          , _crsp_model   = ModelId "test-model"
          , _crsp_usage   = Nothing
          }

        let toolDef = ToolDefinition
              { _td_name        = "test_tool"
              , _td_description = "A tool used to verify registry forwarding"
              , _td_inputSchema = object []
              }
            handler = ToolHandler (\_ -> pure ("ok", False))
            reg = registerTool toolDef handler emptyRegistry

        env0 <- mkTestFrontendEnv
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "test-model"))
        let env = env0
              { _fe_provider    = provRef
              , _fe_model       = modelRef
              , _fe_sessionsDir = tmpDir
              , _fe_registry    = reg
              }

        let body = Aeson.encode (object ["message" .= ("hello" :: T.Text)])
        (st, _) <- postJSON env ["api", "sessions", sid, "send"] body
        st `shouldBe` HTTP.status200

        recorded <- peekRecorded fakeProv
        case recorded of
          [creq] -> _cr_tools creq `shouldBe` [toolDef]
          _      -> expectationFailure
                    $ "Expected exactly 1 recorded CompletionRequest; got "
                    <> show (length recorded)

    it "executes tool calls and continues until the model returns text" $ do
      withSystemTempDirectory "pureclaw-send-loop" $ \tmpDir -> do
        let sid = "test-session-loop"
            sessionDir = tmpDir </> T.unpack sid
        createDirectoryIfMissing True sessionDir
        LBS.writeFile (sessionDir </> "transcript.jsonl") ""

        fakeProv <- newFakeProvider
        -- Turn 1: model wants to call test_tool. Turn 2: model returns text.
        queueResponses fakeProv
          [ CompletionResponse
              { _crsp_content =
                  [ ToolUseBlock (ToolCallId "call-1") "test_tool" (object [])
                  ]
              , _crsp_model   = ModelId "test-model"
              , _crsp_usage   = Nothing
              }
          , CompletionResponse
              { _crsp_content = [TextBlock "final answer"]
              , _crsp_model   = ModelId "test-model"
              , _crsp_usage   = Nothing
              }
          ]

        let toolDef = ToolDefinition
              { _td_name        = "test_tool"
              , _td_description = "Loop test tool"
              , _td_inputSchema = object []
              }
            handler = ToolHandler (\_ -> pure ("tool-output", False))
            reg = registerTool toolDef handler emptyRegistry

        env0 <- mkTestFrontendEnv
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "test-model"))
        let env = env0
              { _fe_provider    = provRef
              , _fe_model       = modelRef
              , _fe_sessionsDir = tmpDir
              , _fe_registry    = reg
              }

        let body = Aeson.encode (object ["message" .= ("hello" :: T.Text)])
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"] body
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Just val -> lookupKey val "response" `shouldBe` Just (Aeson.String "final answer")
          Nothing  -> expectationFailure "Could not decode response JSON"

        recorded <- peekRecorded fakeProv
        length recorded `shouldBe` 2
        case recorded of
          [_, second] -> do
            -- The second turn's messages should end with a tool_result
            -- message echoing call-1, proving the loop fed results back.
            let msgs = _cr_messages second
                hasToolResult = any
                  (\(Message _ blocks) -> any isMatchingToolResult blocks)
                  msgs
                isMatchingToolResult (ToolResultBlock (ToolCallId tid) _ _) =
                  tid == "call-1"
                isMatchingToolResult _ = False
            hasToolResult `shouldBe` True
          _ -> expectationFailure "expected 2 recorded requests"

    it "stops at the configured iteration cap" $ do
      withSystemTempDirectory "pureclaw-send-cap" $ \tmpDir -> do
        let sid = "test-session-cap"
            sessionDir = tmpDir </> T.unpack sid
        createDirectoryIfMissing True sessionDir
        LBS.writeFile (sessionDir </> "transcript.jsonl") ""

        fakeProv <- newFakeProvider
        -- Queue more tool_use responses than the cap so the loop must
        -- bail out rather than terminate naturally.
        let toolUseResp = CompletionResponse
              { _crsp_content =
                  [ ToolUseBlock (ToolCallId "loop") "spin" (object [])
                  ]
              , _crsp_model = ModelId "test-model"
              , _crsp_usage = Nothing
              }
        queueResponses fakeProv (replicate 5 toolUseResp)

        let toolDef = ToolDefinition
              { _td_name        = "spin"
              , _td_description = "always says spin again"
              , _td_inputSchema = object []
              }
            handler = ToolHandler (\_ -> pure ("ok", False))
            reg = registerTool toolDef handler emptyRegistry

        env0 <- mkTestFrontendEnv
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "test-model"))
        let env = env0
              { _fe_provider    = provRef
              , _fe_model       = modelRef
              , _fe_sessionsDir = tmpDir
              , _fe_registry    = reg
              , _fe_maxToolIterations = 2
              }

        let body = Aeson.encode (object ["message" .= ("go" :: T.Text)])
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"] body
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Just val -> case lookupKey val "response" of
            Just (Aeson.String txt) ->
              txt `shouldSatisfy` T.isInfixOf "iteration cap"
            _ -> expectationFailure "Expected a string response containing 'iteration cap'"
          Nothing  -> expectationFailure "Could not decode response JSON"

        recorded <- peekRecorded fakeProv
        length recorded `shouldBe` 2

  -- -----------------------------------------------------------------------
  -- WU4: frozen system prompt + per-session agent rendering (§9.1)
  -- -----------------------------------------------------------------------

  describe "POST /api/sessions/{sid}/send (frozen system prompt — WU4)" $ do
    -- F1: first-turn agent session renders & freezes the agent's prompt.
    it "renders the per-session agent's prompt on the first turn (F1)" $ do
      withSystemTempDirectory "pureclaw-wu4-f1" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "you are myagent" Nothing
        writeBranchSource tmpDir "sess-f1" (Just "myagent") Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnce env "sess-f1" "hello"
        case prov of
          (creq:_) -> case _cr_systemPrompt creq of
            Just p -> do
              ("--- SOUL ---" `T.isInfixOf` p) `shouldBe` True
              ("you are myagent" `T.isInfixOf` p) `shouldBe` True
            Nothing -> expectationFailure "expected an agent-rendered system prompt"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F2: turn ≥2 reuses the frozen prompt; an agent-def edit between turns
    -- has NO effect (we point _fe_agentsDir at a different rendering for the
    -- second send and assert the prompt did not change).
    it "reuses the frozen prompt on turn 2; agent-def edits have no effect (F2)" $ do
      withSystemTempDirectory "pureclaw-wu4-f2" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "ORIGINAL SOUL" Nothing
        writeBranchSource tmpDir "sess-f2" (Just "myagent") Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnce env "sess-f2" "turn one"
        -- Mutate the agent definition between turns.
        writeAgentDir agentsDir "myagent" "MUTATED SOUL" Nothing
        prov <- sendOnce env "sess-f2" "turn two"
        -- Two requests recorded; both must carry the ORIGINAL frozen prompt.
        length prov `shouldBe` 2
        let prompts = map _cr_systemPrompt prov
        all (maybe False (T.isInfixOf "ORIGINAL SOUL")) prompts `shouldBe` True
        any (maybe False (T.isInfixOf "MUTATED SOUL")) prompts `shouldBe` False

    -- F3: custom-prompt.md overrides the agent on turn 1.
    it "custom-prompt.md overrides the agent on the first turn (F3)" $ do
      withSystemTempDirectory "pureclaw-wu4-f3" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "AGENT SOUL" Nothing
        writeBranchSource tmpDir "sess-f3" (Just "myagent") (Just "CUSTOM PROMPT WINS") []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnce env "sess-f3" "hello"
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Just "CUSTOM PROMPT WINS"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F4: no agent + no custom prompt ⇒ global.
    it "falls back to the global prompt with no agent and no custom prompt (F4)" $ do
      withSystemTempDirectory "pureclaw-wu4-f4" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-f4" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir (Just "GLOBAL PROMPT")
        prov <- sendOnce env "sess-f4" "hello"
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Just "GLOBAL PROMPT"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F5: the recorded system_prompt is what later turns replay (the frozen
    -- value comes from the transcript, identical across turns).
    it "later turns replay the recorded system_prompt (F5)" $ do
      withSystemTempDirectory "pureclaw-wu4-f5" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "FROZEN BODY" Nothing
        writeBranchSource tmpDir "sess-f5" (Just "myagent") Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnce env "sess-f5" "turn one"
        prov <- sendOnce env "sess-f5" "turn two"
        -- The recorded transcript's last request system_prompt equals the
        -- second send's system prompt.
        entries <- readBranchTranscript tmpDir "sess-f5"
        let lastReqSp = lastRequestSystemPrompt entries
        case prov of
          [_, second] -> _cr_systemPrompt second `shouldBe` lastReqSp
          _ -> expectationFailure "expected two recorded requests"

    -- F6: bootstrap inclusion follows _sm_bootstrapConsumed (both states).
    it "includes BOOTSTRAP when _sm_bootstrapConsumed is False (F6a)" $ do
      withSystemTempDirectory "pureclaw-wu4-f6a" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "SOUL TEXT" (Just "BOOTSTRAP TEXT")
        writeSessionBootstrap tmpDir "sess-f6a" (Just "myagent") False
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnce env "sess-f6a" "hello"
        case prov of
          (creq:_) -> case _cr_systemPrompt creq of
            Just p -> ("BOOTSTRAP TEXT" `T.isInfixOf` p) `shouldBe` True
            Nothing -> expectationFailure "expected an agent-rendered prompt"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    it "omits BOOTSTRAP when _sm_bootstrapConsumed is True (F6b)" $ do
      withSystemTempDirectory "pureclaw-wu4-f6b" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "SOUL TEXT" (Just "BOOTSTRAP TEXT")
        writeSessionBootstrap tmpDir "sess-f6b" (Just "myagent") True
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnce env "sess-f6b" "hello"
        case prov of
          (creq:_) -> case _cr_systemPrompt creq of
            Just p -> do
              ("BOOTSTRAP TEXT" `T.isInfixOf` p) `shouldBe` False
              ("SOUL TEXT" `T.isInfixOf` p) `shouldBe` True
            Nothing -> expectationFailure "expected an agent-rendered prompt"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F7: _sm_agent names a missing/undiscoverable agent ⇒ global, logged,
    -- NOT a 500.
    it "falls back to global (not 500) when the agent is missing (F7)" $ do
      withSystemTempDirectory "pureclaw-wu4-f7" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        -- agentsDir has no "ghostagent" directory.
        writeBranchSource tmpDir "sess-f7" (Just "ghostagent") Nothing []
        env <- mkSendEnv tmpDir agentsDir (Just "GLOBAL FALLBACK")
        (st, prov) <- sendOnceStatus env "sess-f7" "hello"
        st `shouldBe` HTTP.status200
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Just "GLOBAL FALLBACK"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F8: agent renders to empty/whitespace ⇒ treated as no-agent ⇒ global.
    it "treats an empty-rendering agent as no agent ⇒ global (F8)" $ do
      withSystemTempDirectory "pureclaw-wu4-f8" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        -- Agent dir exists but has no section files ⇒ renders to "".
        writeAgentDir agentsDir "emptyagent" "" Nothing
        writeBranchSource tmpDir "sess-f8" (Just "emptyagent") Nothing []
        env <- mkSendEnv tmpDir agentsDir (Just "GLOBAL FOR EMPTY")
        prov <- sendOnce env "sess-f8" "hello"
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Just "GLOBAL FOR EMPTY"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- F9 (integration): a frozen-null prompt stays null on turn ≥2 and is not
    -- recomputed from the agent.
    it "keeps a frozen-null prompt null on turn 2 (F9)" $ do
      withSystemTempDirectory "pureclaw-wu4-f9" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "WOULD RENDER" Nothing
        -- No agent on the session, no custom prompt, no global ⇒ turn 1 freezes null.
        writeBranchSource tmpDir "sess-f9" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnce env "sess-f9" "turn one"
        -- Now attach an agent to the session meta to prove turn 2 does NOT recompute.
        setSessionAgent tmpDir "sess-f9" (Just "myagent")
        prov <- sendOnce env "sess-f9" "turn two"
        case prov of
          [_, second] -> _cr_systemPrompt second `shouldBe` Nothing
          _ -> expectationFailure "expected two recorded requests"

    -- F11: turn ≥2 does NOT re-read custom-prompt.md (editing it mid-session
    -- has no effect).
    it "does not re-read custom-prompt.md on turn 2 (F11)" $ do
      withSystemTempDirectory "pureclaw-wu4-f11" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-f11" Nothing (Just "ORIGINAL CUSTOM") []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnce env "sess-f11" "turn one"
        -- Edit custom-prompt.md mid-session.
        TIO.writeFile (tmpDir </> "sess-f11" </> "custom-prompt.md") "EDITED CUSTOM"
        prov <- sendOnce env "sess-f11" "turn two"
        case prov of
          [_, second] -> _cr_systemPrompt second `shouldBe` Just "ORIGINAL CUSTOM"
          _ -> expectationFailure "expected two recorded requests"

    -- F12: the harness send path and behavior are unaffected (regression).
    -- The provider doCompletion change does not touch harness sends; a
    -- provider send with no agent/custom/global still freezes correctly,
    -- proving the change is confined to the provider path.
    it "leaves a plain provider send (no agent) producing a null frozen prompt (F12)" $ do
      withSystemTempDirectory "pureclaw-wu4-f12" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-f12" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnce env "sess-f12" "hello"
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Nothing
          [] -> expectationFailure "expected a recorded CompletionRequest"

  -- -----------------------------------------------------------------------
  -- WU5: per-session model at completion (§9.2)
  -- -----------------------------------------------------------------------

  describe "POST /api/sessions/{sid}/send (per-session model — WU5)" $ do
    -- M1: /send carrying an explicit model uses it; the recorded transcript
    -- _te_model column (and the provider request _cr_model) is that model.
    it "uses the request's model when supplied (M1)" $ do
      withSystemTempDirectory "pureclaw-wu5-m1" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-m1" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnceModel env "sess-m1" "hello" (Just "model-X")
        case prov of
          (creq:_) -> _cr_model creq `shouldBe` ModelId "model-X"
          [] -> expectationFailure "expected a recorded CompletionRequest"
        entries <- readBranchTranscript tmpDir "sess-m1"
        lastRequestModelCol entries `shouldBe` Just "model-X"

    -- M2a: no model in the request, but the transcript already has a prior
    -- _te_model ⇒ fall back to that most-recent transcript model.
    it "falls back to the most-recent transcript _te_model when no model given (M2a)" $ do
      withSystemTempDirectory "pureclaw-wu5-m2a" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        -- Turn 1 records model "prior-model" in the transcript.
        writeBranchSource tmpDir "sess-m2a" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnceModel env "sess-m2a" "turn one" (Just "prior-model")
        -- Turn 2 sends NO model ⇒ should reuse "prior-model".
        prov <- sendOnceModel env "sess-m2a" "turn two" Nothing
        case prov of
          [_, second] -> _cr_model second `shouldBe` ModelId "prior-model"
          _ -> expectationFailure "expected two recorded requests"
        entries <- readBranchTranscript tmpDir "sess-m2a"
        lastRequestModelCol entries `shouldBe` Just "prior-model"

    -- M2b: no model in the request AND no prior _te_model ⇒ fall back to the
    -- global _fe_model IORef (the back-compat path).
    it "falls back to the global model when no model and no transcript model (M2b)" $ do
      withSystemTempDirectory "pureclaw-wu5-m2b" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-m2b" Nothing Nothing []
        -- mkSendEnv seeds the global _fe_model to claude-sonnet-4-20250514.
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnceModel env "sess-m2b" "hello" Nothing
        case prov of
          (creq:_) -> _cr_model creq `shouldBe` ModelId "claude-sonnet-4-20250514"
          [] -> expectationFailure "expected a recorded CompletionRequest"
        entries <- readBranchTranscript tmpDir "sess-m2b"
        lastRequestModelCol entries `shouldBe` Just "claude-sonnet-4-20250514"

    -- M2c: a blank/whitespace request model is treated as absent and falls
    -- through to the global fallback rather than sending an empty model id.
    it "treats a blank request model as absent (M2c)" $ do
      withSystemTempDirectory "pureclaw-wu5-m2c" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-m2c" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnceModel env "sess-m2c" "hello" (Just "   ")
        case prov of
          (creq:_) -> _cr_model creq `shouldBe` ModelId "claude-sonnet-4-20250514"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- M3: a session run with model A then model B records A then B (immutable
    -- per-turn history), and after the B turn a no-model send uses B.
    it "records per-turn model history A then B; next no-model send uses B (M3)" $ do
      withSystemTempDirectory "pureclaw-wu5-m3" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-m3" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnceModel env "sess-m3" "turn one" (Just "model-A")
        _ <- sendOnceModel env "sess-m3" "turn two" (Just "model-B")
        -- Per-turn history in the transcript: A then B.
        entries <- readBranchTranscript tmpDir "sess-m3"
        requestModelCols entries `shouldBe` ["model-A", "model-B"]
        -- A subsequent no-model send uses the most-recent (B).
        prov <- sendOnceModel env "sess-m3" "turn three" Nothing
        case prov of
          [_, _, third] -> _cr_model third `shouldBe` ModelId "model-B"
          _ -> expectationFailure "expected three recorded requests"

    -- M4: the chosen model is written to _te_model and the recorded payload
    -- model agrees with the column.
    it "writes the chosen model to _te_model matching the payload model (M4)" $ do
      withSystemTempDirectory "pureclaw-wu5-m4" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeBranchSource tmpDir "sess-m4" Nothing Nothing []
        env <- mkSendEnv tmpDir agentsDir Nothing
        prov <- sendOnceModel env "sess-m4" "hello" (Just "chosen-model")
        entries <- readBranchTranscript tmpDir "sess-m4"
        -- The provider request payload model and the transcript column agree.
        case prov of
          (creq:_) -> _cr_model creq `shouldBe` ModelId "chosen-model"
          [] -> expectationFailure "expected a recorded CompletionRequest"
        lastRequestModelCol entries `shouldBe` Just "chosen-model"
        lastRequestPayloadModel entries `shouldBe` Just "chosen-model"

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
    , _fe_broker       = Nothing
    , _fe_streamGuard  = Nothing
    , _fe_registry    = emptyRegistry
    , _fe_maxToolIterations = 90
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

-- ---------------------------------------------------------------------------
-- WU1 branch test helpers
-- ---------------------------------------------------------------------------

-- | A plain provider New-tab request body (no branch).
providerNewTabBody :: LBS.ByteString
providerNewTabBody = Aeson.encode $ object
  [ "kind" .= object
      [ "tag" .= ("session" :: Text)
      , "session_kind" .= object
          [ "tag"      .= ("provider" :: Text)
          , "provider" .= ("anthropic" :: Text)
          , "model"    .= ("claude-sonnet-4-20250514" :: Text)
          ]
      ]
  ]

-- | A provider New-tab request body carrying a @branch_from@ spec.
branchBody :: Text -> Text -> LBS.ByteString
branchBody sourceSid entryId = Aeson.encode $ object
  [ "kind" .= object
      [ "tag" .= ("session" :: Text)
      , "session_kind" .= object
          [ "tag"      .= ("provider" :: Text)
          , "provider" .= ("anthropic" :: Text)
          , "model"    .= ("claude-sonnet-4-20250514" :: Text)
          ]
      ]
  , "branch_from" .= object
      [ "session_id"     .= sourceSid
      , "up_to_entry_id" .= entryId
      ]
  ]

-- | Assert that a JSON error body has an @"error"@ string containing the
-- given substring (also forces the error-message expression to evaluate).
expectErrorContains :: LBS.ByteString -> Text -> IO ()
expectErrorContains respBody needle = case Aeson.decode respBody of
  Just (val :: Aeson.Value) -> case lookupKey val "error" of
    Just (Aeson.String msg) ->
      (needle `T.isInfixOf` msg) `shouldBe` True
    _ -> expectationFailure "expected an 'error' string in the body"
  Nothing -> expectationFailure "Could not decode error response JSON"

-- | Decode the @session_id@ from a NewTabResponse body, failing the test
-- if it is missing.
decodeSessionId :: LBS.ByteString -> IO Text
decodeSessionId respBody = case Aeson.decode respBody of
  Just (val :: Aeson.Value) -> case lookupKey val "session_id" of
    Just (Aeson.String s) -> pure s
    _ -> expectationFailure "expected session_id string" >> pure ""
  Nothing -> expectationFailure "Could not decode response JSON" >> pure ""

-- | An Anthropic-shaped provider Request transcript entry whose extracted
-- "new message text" is @msg@.
branchReqEntry :: Text -> Text -> TranscriptEntry
branchReqEntry eid msg = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = epochT
  , _te_harness       = Nothing
  , _te_model         = Just "claude-sonnet-4-20250514"
  , _te_direction     = Request
  , _te_payload       = encodePayload (LBS.toStrict (Aeson.encode (object
                          [ "messages" .= [object ["role" .= ("user" :: Text), "content" .= msg]] ])))
  , _te_durationMs    = Nothing
  , _te_correlationId = "corr"
  , _te_metadata      = Map.empty
  }
  where epochT = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)

-- | A CompletionRequest-shaped provider Request transcript entry carrying a
-- top-level @system_prompt@ (used to exercise the WU4 frozen-prompt replay
-- on a branched prefix).
branchReqEntryWithPrompt :: Text -> Text -> Maybe Text -> TranscriptEntry
branchReqEntryWithPrompt eid msg sp = (branchReqEntry eid msg)
  { _te_payload = encodePayload (LBS.toStrict (Aeson.encode (object
      [ "messages" .= [object ["role" .= ("user" :: Text), "content" .= msg]]
      , "system_prompt" .= sp ]))) }

-- | An Anthropic-shaped provider Response transcript entry whose extracted
-- assistant text is @msg@.
branchRespEntry :: Text -> Text -> TranscriptEntry
branchRespEntry eid msg = TranscriptEntry
  { _te_id            = eid
  , _te_timestamp     = epochT
  , _te_harness       = Nothing
  , _te_model         = Just "claude-sonnet-4-20250514"
  , _te_direction     = Response
  , _te_payload       = encodePayload (LBS.toStrict (Aeson.encode (object
                          [ "content" .= [object ["type" .= ("text" :: Text), "text" .= msg]] ])))
  , _te_durationMs    = Just 1
  , _te_correlationId = "corr"
  , _te_metadata      = Map.empty
  }
  where epochT = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)

-- | Write a provider source session on disk: @session.json@,
-- @transcript.jsonl@ (entries in order), and optional @custom-prompt.md@.
writeBranchSource
  :: FilePath -> Text -> Maybe Text -> Maybe Text -> [TranscriptEntry] -> IO ()
writeBranchSource baseDir sid mAgentText mPrompt entries = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let mAgent = mAgentText >>= \t -> either (const Nothing) Just (mkAgentName t)
      meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = mAgent
        , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "claude-sonnet-4-20250514") (ModelId "claude-sonnet-4-20250514") mAgent)
        , _sm_model             = "claude-sonnet-4-20250514"
        , _sm_channel           = "web"
        , _sm_createdAt         = epochT
        , _sm_lastActive        = epochT
        , _sm_bootstrapConsumed = True
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        }
      epochT = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  LBS.writeFile (dir </> "transcript.jsonl")
    (LBS.intercalate "\n" (map Aeson.encode entries) <> "\n")
  maybe (pure ()) (TIO.writeFile (dir </> "custom-prompt.md")) mPrompt

-- | Write a harness-backed source session on disk (for the D5 harness arm).
writeHarnessBranchSource :: FilePath -> Text -> IO ()
writeHarnessBranchSource baseDir sid = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let hSpec = HarnessSpec (fixedFlavourLookup "claude-code")
        (TbTmux (TmuxConfig "cc" "cc" Nothing)) Nothing []
      meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = Nothing
        , _sm_kind              = SkHarness hSpec
        , _sm_model             = "claude-sonnet-4-20250514"
        , _sm_channel           = "web"
        , _sm_createdAt         = epochT
        , _sm_lastActive        = epochT
        , _sm_bootstrapConsumed = True
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        }
      epochT = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  LBS.writeFile (dir </> "transcript.jsonl") ""

-- ---------------------------------------------------------------------------
-- WU4 frozen-prompt test helpers
-- ---------------------------------------------------------------------------

-- | Write a minimal agent directory under @agentsDir/name@ with a SOUL.md
-- (the @soul@ body; empty string ⇒ no SOUL.md so the agent renders empty)
-- and an optional BOOTSTRAP.md.
writeAgentDir :: FilePath -> Text -> Text -> Maybe Text -> IO ()
writeAgentDir agentsDir name soul mBootstrap = do
  let dir = agentsDir </> T.unpack name
  createDirectoryIfMissing True dir
  if T.null soul
    then pure ()
    else TIO.writeFile (dir </> "SOUL.md") soul
  maybe (pure ()) (TIO.writeFile (dir </> "BOOTSTRAP.md")) mBootstrap

-- | A send-ready environment: the 'FrontendEnv' plus the fake provider it
-- is wired to (so tests can inspect recorded requests).
data SendEnv = SendEnv
  { _se_env  :: FrontendEnv
  , _se_fake :: FakeProvider
  }

-- | Build a send-ready environment: a fake provider with several queued
-- responses, a real sessions dir, an agents dir, and an optional global
-- system prompt.
mkSendEnv :: FilePath -> FilePath -> Maybe Text -> IO SendEnv
mkSendEnv tmpDir agentsDir mGlobal = do
  fakeProv <- newFakeProvider
  -- Queue plenty of responses so multiple /send calls each get one.
  queueResponses fakeProv (replicate 8 CompletionResponse
    { _crsp_content = [TextBlock "ok"]
    , _crsp_model   = ModelId "claude-sonnet-4-20250514"
    , _crsp_usage   = Nothing
    })
  env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
  provRef  <- newIORef (Just (MkProvider fakeProv))
  modelRef <- newIORef (Just (ModelId "claude-sonnet-4-20250514"))
  let env = env0
        { _fe_provider     = provRef
        , _fe_model        = modelRef
        , _fe_agentsDir    = agentsDir
        , _fe_systemPrompt = mGlobal
        }
  pure (SendEnv env fakeProv)

-- | POST one /send and return the recorded CompletionRequests so far
-- (oldest first), asserting a 200.
sendOnce :: SendEnv -> Text -> Text -> IO [CompletionRequest]
sendOnce se sid msg = do
  (st, prov) <- sendOnceStatus se sid msg
  st `shouldBe` HTTP.status200
  pure prov

-- | Like 'sendOnce' but also returns the HTTP status (for the F7 not-500
-- assertion).
sendOnceStatus :: SendEnv -> Text -> Text -> IO (HTTP.Status, [CompletionRequest])
sendOnceStatus se sid msg = do
  (st, _) <- postJSON (_se_env se) ["api", "sessions", sid, "send"]
    (Aeson.encode (object ["message" .= msg]))
  prov <- peekRecorded (_se_fake se)
  pure (st, prov)

-- | Write a provider session whose @_sm_bootstrapConsumed@ is the given
-- value (with an optional agent, no transcript entries, no custom prompt).
writeSessionBootstrap :: FilePath -> Text -> Maybe Text -> Bool -> IO ()
writeSessionBootstrap baseDir sid mAgentText boot = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let mAgent = mAgentText >>= \t -> either (const Nothing) Just (mkAgentName t)
      meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = mAgent
        , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "claude-sonnet-4-20250514") (ModelId "claude-sonnet-4-20250514") mAgent)
        , _sm_model             = "claude-sonnet-4-20250514"
        , _sm_channel           = "web"
        , _sm_createdAt         = epochT
        , _sm_lastActive        = epochT
        , _sm_bootstrapConsumed = boot
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        }
      epochT = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  LBS.writeFile (dir </> "transcript.jsonl") ""

-- | Rewrite a session's @session.json@ to set or clear its agent (used by
-- F9 to prove turn ≥2 does not recompute from a freshly-attached agent).
setSessionAgent :: FilePath -> Text -> Maybe Text -> IO ()
setSessionAgent baseDir sid mAgentText = do
  let metaPath = baseDir </> T.unpack sid </> "session.json"
  raw <- LBS.readFile metaPath
  case Aeson.eitherDecode' raw of
    Right (meta :: SessionMeta) -> do
      let mAgent = mAgentText >>= \t -> either (const Nothing) Just (mkAgentName t)
      LBS.writeFile metaPath (Aeson.encode meta { _sm_agent = mAgent })
    Left e -> expectationFailure ("setSessionAgent: decode failed: " <> e)

-- | Like 'sendOnceStatus' but lets the test attach an optional @model@ field
-- to the @/send@ body (WU5). Asserts a 200 and returns recorded requests.
sendOnceModel :: SendEnv -> Text -> Text -> Maybe Text -> IO [CompletionRequest]
sendOnceModel se sid msg mModel = do
  let body = Aeson.encode $ object $
        ("message" .= msg) : maybe [] (\m -> ["model" .= m]) mModel
  (st, _) <- postJSON (_se_env se) ["api", "sessions", sid, "send"] body
  st `shouldBe` HTTP.status200
  peekRecorded (_se_fake se)

-- | The @_te_model@ column of the last Request-direction transcript entry.
lastRequestModelCol :: [TranscriptEntry] -> Maybe Text
lastRequestModelCol entries =
  case reverse [ e | e <- entries, _te_direction e == Request ] of
    []      -> Nothing
    (e : _) -> _te_model e

-- | The @_te_model@ columns of every Request-direction entry, oldest first
-- (per-turn model history).
requestModelCols :: [TranscriptEntry] -> [Text]
requestModelCols entries =
  [ m | e <- entries, _te_direction e == Request, Just m <- [_te_model e] ]

-- | The top-level @model@ field of the last Request entry's recorded payload.
lastRequestPayloadModel :: [TranscriptEntry] -> Maybe Text
lastRequestPayloadModel entries =
  case reverse [ e | e <- entries, _te_direction e == Request ] of
    []      -> Nothing
    (e : _) -> case Aeson.decode (LBS.fromStrict (TE.encodeUtf8 (_te_payload e))) of
      Just (Aeson.Object o) -> case KM.lookup "model" o of
        Just (Aeson.String t) -> Just t
        _                     -> Nothing
      _ -> Nothing

-- | The top-level @system_prompt@ of the last Request entry, as a
-- @Maybe Text@ (mirrors what 'frozenSystemPrompt' surfaces).
lastRequestSystemPrompt :: [TranscriptEntry] -> Maybe Text
lastRequestSystemPrompt entries =
  case reverse [ e | e <- entries, _te_direction e == Request ] of
    []      -> Nothing
    (e : _) -> case Aeson.decode (LBS.fromStrict (TE.encodeUtf8 (_te_payload e))) of
      Just (Aeson.Object o) -> case KM.lookup "system_prompt" o of
        Just (Aeson.String t) -> Just t
        _                     -> Nothing
      _ -> Nothing

-- | Read and decode a branched session's transcript.jsonl into entries.
readBranchTranscript :: FilePath -> Text -> IO [TranscriptEntry]
readBranchTranscript baseDir sid = do
  raw <- LBS.readFile (baseDir </> T.unpack sid </> "transcript.jsonl")
  let ls = filter (not . LBS.null) (LBS.split 0x0a raw)
  pure (mapMaybe' Aeson.decode' ls)
  where
    mapMaybe' f = foldr (\x acc -> maybe acc (: acc) (f x)) []

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
