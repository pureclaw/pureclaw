{-# OPTIONS_GHC -Wno-x-partial #-}
{- HLINT ignore "Use head" -}
module Frontend.APISpec (spec) where

import Control.Concurrent.STM (atomically, readTBQueue)
import Control.Exception (throwIO)
import System.Timeout (timeout)
import Data.Aeson qualified as Aeson
import Data.Aeson (object, (.=))
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Builder qualified
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Internal (ResponseReceived (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Agent.AgentDef (mkAgentName, unAgentName)
import PureClaw.Core.Types (ChannelKind (..), ConversationId (..), ModelId (..), SessionId (..), ToolCallId (..), UserId (..), mkMessageSource)
import PureClaw.Frontend.API
import PureClaw.Frontend.StreamBroker
  ( BrokerEvent (..)
  , SessionActivity (..)
  , Subscription (..)
  , defaultBrokerConfig
  , mkInProcessBroker
  , _streamBroker_subscribe
  )
import PureClaw.Session.Handle (setDescription)
import PureClaw.Handles.Harness
  ( HarnessError (..)
  , HarnessHandle (..)
  , HarnessStatus (..)
  , mkNoOpHarnessHandle
  )
import PureClaw.Harness.Registry qualified as Registry
import PureClaw.Harness.Tmux (TmuxWindowRow (..))
import Data.ByteString (ByteString)
import PureClaw.Security.Adoption (AdoptedHarness, ConsentChannel (..))
import PureClaw.Security.Command (CommandError (..))
import PureClaw.Handles.Log (LogHandle (..), mkNoOpLogHandle)
import PureClaw.Handles.Transcript (TranscriptHandle, mkNoOpTranscriptHandle)
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
  , HarnessFlavour (..)
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
import Support.AgentEnv (mkTestAgentEnv)
import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Handles.Tab (mkTabIndex, unTabIndex)
import PureClaw.Tabs (TabRegistry, newTabRegistry, readTabs, registryAppend, registryLookupSlot)
import PureClaw.Tabs.Exec (newExec)
import PureClaw.Tabs.Types (Tab (..), TabRef (..), emptyCursors, toList)
import PureClaw.Tabs.Wiring qualified as Wiring
import PureClaw.Routing.TabDispatch (mkRunTabCommandSeam)

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
  -- WU2 — POST /api/tabs/new spawns the harness (createTab SkHarness path)
  -- -----------------------------------------------------------------------

  describe "POST /api/tabs/new (harness spawn — WU2)" $ do
    -- D2.1: a harness POST actually calls _fe_startHarness, which registers
    -- the live handle in _fe_harnesses under the returned key.
    it "spawns the harness and registers its handle (D2.1)" $ do
      withSystemTempDirectory "pureclaw-wu2-d21" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0 { _fe_startHarness = fakeStartHarness (_fe_harnesses env0) "claude-code-0" }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        harnesses <- readIORef (_fe_harnesses env)
        Map.member "claude-code-0" harnesses `shouldBe` True

    -- D2.2: the persisted session.json carries the real tmux coordinates
    -- from the StartedHarness, not the placeholder backend in the request.
    it "persists the tmux coordinates into _sm_kind (D2.2)" $ do
      withSystemTempDirectory "pureclaw-wu2-d22" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0 { _fe_startHarness = fakeStartHarness (_fe_harnesses env0) "claude-code-0" }
        (st, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        meta <- readSessionMeta tmpDir newSid
        case _sm_kind meta of
          SkHarness hs -> do
            let tc = _h_tmux hs
            _tc_session tc `shouldBe` "pureclaw"
            _tc_window tc  `shouldBe` "claude-code-0"
          other -> expectationFailure ("expected SkHarness kind, got " <> show other)

    -- WU6 (D6.2/D6.3): the claudeSessionUuid + canonicalCwd the spawn returns
    -- in its StartedHarness are persisted additively into the session's
    -- _sm_kind HarnessSpec, so a restart can re-derive the JSONL log path. The
    -- fake spawn returns a KNOWN uuid; we read it back from session.json. This
    -- proves the persisted uuid is exactly the value the spawn surfaced (which,
    -- in production, is the SAME value injected as --session-id).
    it "persists claudeSessionUuid and canonicalCwd into _sm_kind (WU6 D6.2/D6.3)" $ do
      withSystemTempDirectory "pureclaw-wu6-persist" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let knownUuid = "0badf00d-1234-4abc-8abc-0badf00dface"
            knownCwd  = "/canon/spawn/cwd"
            env = env0
              { _fe_startHarness =
                  fakeStartHarnessUuid (_fe_harnesses env0) "claude-code-0"
                    (Just knownUuid) (Just knownCwd) }
        (st, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        meta <- readSessionMeta tmpDir newSid
        case _sm_kind meta of
          SkHarness hs -> do
            _h_claudeSessionUuid hs `shouldBe` Just knownUuid
            _h_canonicalCwd hs `shouldBe` Just knownCwd
          other -> expectationFailure ("expected SkHarness kind, got " <> show other)

    -- WU6 (back-compat): when the spawn returns Nothing for both new fields
    -- (e.g. an adopted/non-claude-code harness), the persisted spec carries
    -- Nothing — no spurious correlation.
    it "persists Nothing when the spawn yields no claudeSessionUuid (WU6)" $ do
      withSystemTempDirectory "pureclaw-wu6-none" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  fakeStartHarnessUuid (_fe_harnesses env0) "claude-code-0"
                    Nothing Nothing }
        (st, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        meta <- readSessionMeta tmpDir newSid
        case _sm_kind meta of
          SkHarness hs -> do
            _h_claudeSessionUuid hs `shouldBe` Nothing
            _h_canonicalCwd hs `shouldBe` Nothing
          other -> expectationFailure ("expected SkHarness kind, got " <> show other)

    -- D2.3: a failing spawn must not consume a tab slot and must remove the
    -- just-created session dir. 503 for tmux/binary errors; 403 for authz.
    it "maps HarnessTmuxNotAvailable to 503, keeps tab count, removes dir (D2.3)" $ do
      withSystemTempDirectory "pureclaw-wu2-d23a" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  \_ _ -> pure (Left (HarnessTmuxNotAvailable "tmux not found")) }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status503
        tabCountOf env `shouldReturn` 0
        -- No leftover session directory survives a failed spawn.
        entries <- listSessionDirs tmpDir
        entries `shouldBe` []

    it "maps HarnessBinaryNotFound to 503 (D2.3)" $ do
      withSystemTempDirectory "pureclaw-wu2-d23b" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  \_ _ -> pure (Left (HarnessBinaryNotFound "claude not on PATH")) }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status503
        tabCountOf env `shouldReturn` 0

    it "maps HarnessNotAuthorized to 403, keeps tab count (D2.3)" $ do
      withSystemTempDirectory "pureclaw-wu2-d23c" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  \_ _ -> pure (Left (HarnessNotAuthorized (CommandNotAllowed "claude"))) }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status403
        tabCountOf env `shouldReturn` 0

    -- D2.4: a successful harness spawn bumps the tab count exactly once.
    it "bumps _fe_tabCount on a successful harness spawn (D2.4)" $ do
      withSystemTempDirectory "pureclaw-wu2-d24" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0 { _fe_startHarness = fakeStartHarness (_fe_harnesses env0) "claude-code-0" }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        tabCountOf env `shouldReturn` 1

    -- D2.4 (regression): a provider POST behaves exactly as before — 200,
    -- session.json on disk, tab count bumped — without ever calling
    -- _fe_startHarness (which would Left-fail if it did).
    it "provider POST is unchanged and never spawns a harness (D2.4)" $ do
      withSystemTempDirectory "pureclaw-wu2-prov" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"] providerNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        doesFileExist (tmpDir </> T.unpack newSid </> "session.json")
          `shouldReturn` True
        tabCountOf env `shouldReturn` 1
        -- The provider path leaves the harness map empty.
        harnesses <- readIORef (_fe_harnesses env)
        Map.null harnesses `shouldBe` True

  -- -----------------------------------------------------------------------
  -- WU4 — POST /api/tabs/new publishes the POST-spawn meta to the broker
  -- -----------------------------------------------------------------------

  describe "POST /api/tabs/new (harness spawn — WU4 broker publish)" $
    -- D4: a successful harness spawn publishes exactly one
    -- ActivityChanged (SaSessionCreated meta) event whose meta carries the
    -- REAL spawned tmux coordinates (the spawn's window), not the
    -- placeholder tmux coords in the request. This covers the
    -- @Just broker -> _streamBroker_publish ...@ arm of createHarnessTab
    -- and validates the post-spawn-meta fix.
    it "publishes the post-spawn meta carrying the real tmux coordinates (D4)" $ do
      withSystemTempDirectory "pureclaw-wu4-d4" $ \tmpDir -> do
        broker <- mkInProcessBroker defaultBrokerConfig
        eSub   <- _streamBroker_subscribe broker
        sub    <- either (\e -> error ("subscribe: " <> show e)) pure eSub
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_broker       = Just broker
              , _fe_startHarness = fakeStartHarness (_fe_harnesses env0) "claude-code-0"
              }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        evs <- drainBrokerQueue 500000 sub
        let created = [ m | ActivityChanged _ (SaSessionCreated m) <- evs ]
        case created of
          [m] -> case _sm_kind m of
            SkHarness hs -> _tc_window (_h_tmux hs) `shouldBe` "claude-code-0"
            other -> expectationFailure
              ("expected SkHarness kind in published meta, got " <> show other)
          other -> expectationFailure
            ("expected exactly one SaSessionCreated event, got "
              <> show (length other))

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
        tabCountOf env `shouldReturn` 1

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

    -- R3: a fork of a source that HAS a custom-prompt.md must NOT copy it
    -- (the frozen prompt rides in the transcript, §9.4), while still
    -- inheriting the source's agent identity (_sm_agent).
    it "does not copy custom-prompt.md and keeps the source agent (R3)" $ do
      withSystemTempDirectory "pureclaw-branch-r3" $ \tmpDir -> do
        writeBranchSource tmpDir "src-r3" (Just "helper") (Just "you are a branch")
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-r3" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        -- No custom-prompt.md is written into the fork.
        let promptPath = tmpDir </> T.unpack newSid </> "custom-prompt.md"
        doesFileExist promptPath `shouldReturn` False
        -- The fork still inherits the source's agent.
        Right meta <- Aeson.eitherDecodeFileStrict'
          (tmpDir </> T.unpack newSid </> "session.json")
          :: IO (Either String SessionMeta)
        fmap unAgentName (_sm_agent meta) `shouldBe` Just "helper"

    -- R3 (no-source-prompt regression): a fork of a source WITHOUT a
    -- custom-prompt.md likewise creates none.
    it "creates no custom-prompt.md when the source has none (R3)" $ do
      withSystemTempDirectory "pureclaw-branch-r3b" $ \tmpDir -> do
        writeBranchSource tmpDir "src-r3b" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-r3b" "e1")
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
        tabCountOf env `shouldReturn` 0

    -- D5: error mapping + tab-count invariance.
    it "maps an invalid/traversal source id to 400 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5a" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "../evil" "e1")
        st `shouldBe` HTTP.status400
        expectErrorContains respBody "invalid branch source id"
        tabCountOf env `shouldReturn` 0

    it "maps an unknown source session to 404 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5b" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "ghost" "e1")
        st `shouldBe` HTTP.status404
        expectErrorContains respBody "branch source session not found"
        tabCountOf env `shouldReturn` 0

    it "maps a harness source to 400 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5c" $ \tmpDir -> do
        writeHarnessBranchSource tmpDir "src-harness"
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-harness" "e1")
        st `shouldBe` HTTP.status400
        expectErrorContains respBody "not a provider session"
        tabCountOf env `shouldReturn` 0

    it "maps an unknown entry id to 404 (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5d" $ \tmpDir -> do
        writeBranchSource tmpDir "src-d5d" Nothing Nothing
          [ branchReqEntry "e1" "q1" ]
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-d5d" "nope")
        st `shouldBe` HTTP.status404
        expectErrorContains respBody "branch source entry not found"
        tabCountOf env `shouldReturn` 0

    -- D5: repeated failing branch POSTs do not consume tab slots.
    it "leaves _fe_tabCount unchanged after repeated failing branches (D5)" $ do
      withSystemTempDirectory "pureclaw-branch-d5e" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let post = postJSON env ["api", "tabs", "new"] (branchBody "ghost" "e1")
        (s1, _) <- post
        (s2, _) <- post
        (s3, _) <- post
        [s1, s2, s3] `shouldBe` [HTTP.status404, HTTP.status404, HTTP.status404]
        tabCountOf env `shouldReturn` 0

    -- R1 + R2: a fork's first /send replays the copied prefix and (R1)
    -- freezes the system_prompt recorded in the copied prefix's last Request
    -- entry rather than recomputing it, and (R2) uses the prefix's last
    -- _te_model as its first model (WU5's transcript-_te_model fallback),
    -- with no model in the /send body. The global prompt and a distinct
    -- global model are both set and must be ignored.
    it "first send replays the prefix, freezes the prompt, and uses the prefix model (R1, R2)" $ do
      withSystemTempDirectory "pureclaw-branch-r1r2-send" $ \tmpDir -> do
        writeBranchSource tmpDir "src-send" Nothing Nothing
          [ (branchReqEntryWithPrompt "e1" "q1" (Just "frozen prefix prompt"))
              { _te_model = Just "prefix-model" }
          , branchRespEntry "e2" "a1"
          ]
        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "ok"]
          , _crsp_model   = ModelId "prefix-model"
          , _crsp_usage   = Nothing
          }
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "global-model-IGNORED"))
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
            -- R1: the frozen prompt comes from the copied transcript, not the
            -- global fallback.
            _cr_systemPrompt creq `shouldBe` Just "frozen prefix prompt"
            -- The replayed prefix turns are present in the context.
            let blob = T.intercalate "\n"
                  [ t | Message _ blocks <- _cr_messages creq
                      , TextBlock t <- blocks ]
            (("q1" `T.isInfixOf` blob) && ("a1" `T.isInfixOf` blob))
              `shouldBe` True
          [] -> expectationFailure "expected a recorded CompletionRequest"
        -- R2: the fork's first recorded _te_model is the prefix's last
        -- Request _te_model, NOT the global IORef model.
        entries <- readBranchTranscript tmpDir newSid
        lastRequestModelCol entries `shouldBe` Just "prefix-model"

    -- R1 (frozen-null): a fork whose copied prefix's last Request recorded a
    -- null/absent system_prompt freezes null — it does NOT recompute from the
    -- inherited _sm_agent or the global prompt.
    it "first send freezes a null prefix prompt as null, not recomputed (R1)" $ do
      withSystemTempDirectory "pureclaw-branch-r1null-send" $ \tmpDir -> do
        -- Source HAS an agent; the frozen-null prompt must still win.
        writeBranchSource tmpDir "src-send-b" (Just "helper") Nothing
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

    -- R5: a fork whose copied prefix has NO Request entry (only a Response)
    -- has no frozen prompt and no transcript _te_model to inherit, so its
    -- first /send falls back to the global model and recomputes the prompt
    -- from the global default. (The inherited agent would render under the
    -- fork's own _sm_bootstrapConsumed = True; here there is no agent, so the
    -- global prompt is used.)
    it "first send on a Request-less prefix falls back to global model + recomputed prompt (R5)" $ do
      withSystemTempDirectory "pureclaw-branch-r5-send" $ \tmpDir -> do
        -- Prefix is a single Response entry: no Request ⇒ no frozen prompt,
        -- no transcript _te_model.
        writeBranchSource tmpDir "src-send-r5" Nothing Nothing
          [ branchRespEntry "e1" "a1" ]
        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "ok"]
          , _crsp_model   = ModelId "global-model"
          , _crsp_usage   = Nothing
          }
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "global-model"))
        let env = env0
              { _fe_provider = provRef
              , _fe_model = modelRef
              , _fe_systemPrompt = Just "GLOBAL DEFAULT PROMPT"
              }
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (branchBody "src-send-r5" "e1")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        (sendSt, _) <- postJSON env ["api", "sessions", newSid, "send"]
          (Aeson.encode (object ["message" .= ("continue" :: T.Text)]))
        sendSt `shouldBe` HTTP.status200
        recorded <- peekRecorded fakeProv
        case recorded of
          (creq:_) ->
            -- Recomputed from the global default (no frozen prompt to reuse).
            _cr_systemPrompt creq `shouldBe` Just "GLOBAL DEFAULT PROMPT"
          [] -> expectationFailure "expected a recorded CompletionRequest"
        -- The first recorded _te_model is the global model fallback.
        entries <- readBranchTranscript tmpDir newSid
        lastRequestModelCol entries `shouldBe` Just "global-model"

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
        tabCountOf env `shouldReturn` 0

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
        tabCountOf env `shouldReturn` 0

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

  describe "GET /api/harnesses (registry-backed — WU5)" $ do
    it "returns an empty list when the registry is empty" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- getJSON env ["api", "harnesses"]
      st `shouldBe` HTTP.status200
      respBody `shouldBe` Aeson.encode ([] :: [Aeson.Value])

    it "reports each registry entry's reconciled liveness (not a live capture)" $ do
      env <- mkTestFrontendEnv
      let hidA = mustParseHid "11111111-1111-4111-8111-111111111111"
          hidB = mustParseHid "22222222-2222-4222-8222-222222222222"
      -- Two entries with DIFFERENT cached liveness; the handler must read the
      -- registry's reconciled state, not perform a tmux capture.
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry hidA "claude-code-0" Nothing)
          { Registry._he_liveness = Registry.LivenessThinking }
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry hidB "claude-code-1" Nothing)
          { Registry._he_liveness = Registry.LivenessOrphaned }
      (st, respBody) <- getJSON env ["api", "harnesses"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody :: Maybe [Aeson.Value] of
        Just arr -> do
          let pairs =
                [ (n, a)
                | v <- arr
                , Just (Aeson.String n) <- [lookupKey v "name"]
                , Just (Aeson.String a) <- [lookupKey v "activity"]
                ]
          -- Orphaned collapses to "stopped"; Thinking → "thinking".
          lookup "claude-code-0" pairs `shouldBe` Just "thinking"
          lookup "claude-code-1" pairs `shouldBe` Just "stopped"
        Nothing -> expectationFailure "harnesses response was not a JSON array"

  describe "GET /api/tabs" $ do
    it "returns an empty list when no tabs are open" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      respBody `shouldBe` Aeson.encode ([] :: [Aeson.Value])

    it "returns tab list with correct kind/status/session_id (registry-backed WU6)" $ do
      -- Populate via the real TabRegistry:
      --   slot 0: provider session (Live → "idle")
      --   slot 1: harness        (LivenessThinking → "running")
      --   slot 2: harness        (LivenessExited → "exited")
      env <- mkTestFrontendEnv
      let hid1 = mustParseHid "11111111-1111-4111-8111-111111111111"
          hid2 = mustParseHid "22222222-2222-4222-8222-222222222222"
          sid  = SessionId "session-001"
      -- Slot 0: provider session
      _ <- registryAppend (_fe_tabRegistry env) (BoundSession sid)
      -- Slots 1 & 2: harness tabs (also insert into harness registry)
      seedHarnessTab env
        (baseEntry hid1 "thinking-win" Nothing)
          { Registry._he_label    = "claude-running"
          , Registry._he_liveness = Registry.LivenessThinking
          }
      seedHarnessTab env
        (baseEntry hid2 "exited-win" Nothing)
          { Registry._he_label    = "claude-exited"
          , Registry._he_liveness = Registry.LivenessExited
          }
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just (Aeson.Array arr) -> do
          let items = toList' arr
          length items `shouldBe` 3
          -- slot 0: provider tab — kind="provider", status="idle", session_id present
          let t0 = head items
          lookupKey t0 "index"      `shouldBe` Just (Aeson.Number 0)
          lookupKey t0 "kind"       `shouldBe` Just (Aeson.String "provider")
          -- Tabs no longer carry a per-tab "name"; provider tabs emit a null
          -- "label" (the title derives from the session via session_id).
          lookupKey t0 "name"       `shouldBe` Nothing
          lookupKey t0 "label"      `shouldBe` Just Aeson.Null
          lookupKey t0 "status"     `shouldBe` Just (Aeson.String "idle")
          lookupKey t0 "session_id" `shouldBe` Just (Aeson.String "session-001")
          -- slot 1: harness "running"
          let t1 = items !! 1
          lookupKey t1 "kind"   `shouldBe` Just (Aeson.String "harness")
          lookupKey t1 "status" `shouldBe` Just (Aeson.String "running")
          -- slot 2: harness "exited"
          let t2 = items !! 2
          lookupKey t2 "kind"   `shouldBe` Just (Aeson.String "harness")
          lookupKey t2 "status" `shouldBe` Just (Aeson.String "exited")
        Just _ -> expectationFailure "Expected JSON array"

  describe "POST /api/discovery/scan (list-all metadata-only scan — allow-list dropped)" $ do
    it "D2.5 returns a 200 JSON array" $ do
      -- Discovery now LISTS ALL tmux sessions (consent gates at adopt time, not
      -- here). The endpoint wires the real tmux IO ('scanDiscoverableIO'); with
      -- no tmux server reachable it returns an empty array, so the contract we
      -- assert is "200 + JSON array" regardless of the host's tmux state. The
      -- list-all filtering itself is unit-tested in Harness.DiscoverySpec.
      env <- mkTestFrontendEnv
      (st, respBody) <- postJSON env ["api", "discovery", "scan"] ""
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Just (Aeson.Array _) -> pure ()
        _ -> expectationFailure "Expected a JSON array body"

  describe "POST /api/adopt (Phase 3 WU4 — typed default-deny consent gate, SEC-1)" $ do
    -- The adopt body always confirms consent; the differentiator across tests
    -- is the consent CHANNEL ('_fe_consentChannel'), which is the SOLE remaining
    -- gate now that the allow-list is dropped.
    let adoptBody s w = Aeson.encode $ object
          [ "session"           .= (s :: Text)
          , "window"            .= (w :: Text)
          , "consent_confirmed" .= True
          ]

    it "W1.5 (SEC-1) returns 403 for a ConsentHeadless env EVEN with consent_confirmed:true, and calls _fe_adopt ZERO times (no tmux mutation)" $ do
      env0 <- mkTestFrontendEnv
      adoptCalls <- newIORef (0 :: Int)
      let env = env0
            { _fe_consentChannel = ConsentHeadless  -- the ONLY denial cause
            , _fe_adopt          = \_ _ _ -> do
                modifyIORef' adoptCalls (+ 1)
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "scratch" "win-0")
      st `shouldBe` HTTP.status403
      -- No tmux mutation on denial: the adopt mechanism was never invoked, so
      -- nothing was stamped (@pcl_id) and no entry could be created.
      calls <- readIORef adoptCalls
      calls `shouldBe` 0
      -- And the registry remains empty.
      entries <- Registry.snapshot (_fe_harnessRegistry env)
      length entries `shouldBe` 0

    it "W1.5 ConsentInteractive adopts ANY session (no allow-list) — calls _fe_adopt once and returns 200" $ do
      -- The allow-list is gone: a session the OLD default-deny policy would have
      -- rejected is now adopted under interactive consent.
      env0 <- mkTestFrontendEnv
      adoptCalls <- newIORef (0 :: Int)
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \_ _ _ -> do
                modifyIORef' adoptCalls (+ 1)
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "any-arbitrary-session" "win-0")
      st `shouldBe` HTTP.status200
      calls <- readIORef adoptCalls
      calls `shouldBe` 1

    it "ConsentWeb (the gateway/web UI) adopts the selected session — calls _fe_adopt once and returns 200" $ do
      -- The web "Existing Harness" flow: the gateway runs ConsentWeb, and the
      -- browser's window selection (consent_confirmed:true) is the consent, so
      -- adoption succeeds — it is NOT denied like a truly-headless run.
      env0 <- mkTestFrontendEnv
      adoptCalls <- newIORef (0 :: Int)
      let env = env0
            { _fe_consentChannel = ConsentWeb
            , _fe_adopt          = \_ _ _ -> do
                modifyIORef' adoptCalls (+ 1)
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "an-existing-harness" "win-3")
      st `shouldBe` HTTP.status200
      calls <- readIORef adoptCalls
      calls `shouldBe` 1

    it "surfaces the created session_id in the response (for the composer's first-message send)" $ do
      env0 <- mkTestFrontendEnv
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
          env = env0
            { _fe_consentChannel = ConsentWeb
            , _fe_adopt          = \_ _ _ -> do
                -- Mirror the real adopt mechanism: register an OriginAdopted entry
                -- carrying the created PureClaw session id.
                Registry.insertEntry (_fe_harnessRegistry env0)
                  ((baseEntry hid "adopted-x" (Just mkNoOpHarnessHandle))
                    { Registry._he_origin    = Registry.OriginAdopted
                    , Registry._he_sessionId = Just "20240101-000000-001" })
                pure (Right (hid, mkNoOpHarnessHandle))
            }
      (st, respBody) <- postJSON env ["api", "adopt"] (adoptBody "an-existing-harness" "win-3")
      st `shouldBe` HTTP.status200
      lookupKey' respBody "session_id" `shouldBe` Just (Aeson.String "20240101-000000-001")

    it "returns 400 when consent_confirmed is false/absent, and calls _fe_adopt ZERO times" $ do
      env0 <- mkTestFrontendEnv
      adoptCalls <- newIORef (0 :: Int)
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \_ _ _ -> do
                modifyIORef' adoptCalls (+ 1)
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
          noConsent = Aeson.encode $ object
            [ "session" .= ("scratch" :: Text), "window" .= ("win-0" :: Text) ]
      (st, _) <- postJSON env ["api", "adopt"] noConsent
      st `shouldBe` HTTP.status400
      calls <- readIORef adoptCalls
      calls `shouldBe` 0

    it "the gate token is type-enforced: _fe_adopt is reachable ONLY on Right (interactive + consent_confirmed)" $ do
      -- D4.3 mirror at the endpoint layer: _fe_adopt receives an AdoptedHarness
      -- argument and is invoked EXACTLY ONCE only on the allow path, with the
      -- requested window. (The mechanism's own type-enforcement is asserted in
      -- Harness.ClaudeCodeSpec — there is no token-free adopt path.)
      env0 <- mkTestFrontendEnv
      gotWindow <- newIORef Nothing
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \(_tok :: AdoptedHarness) _idx w -> do
                writeIORef gotWindow (Just w)
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "scratch" "win-7")
      st `shouldBe` HTTP.status200
      readIORef gotWindow `shouldReturn` Just "win-7"

    it "forwards the window_index (unique within a session) to _fe_adopt when the picker supplies it" $ do
      -- The detected-windows picker disambiguates same-named windows by INDEX.
      -- The endpoint must hand that index to the adopt mechanism so it targets
      -- the picked window, not the first name match.
      env0 <- mkTestFrontendEnv
      gotIndex <- newIORef (Just (-1))  -- sentinel distinct from Nothing / Just 2
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \_ mIdx _ -> do
                writeIORef gotIndex mIdx
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
          body = Aeson.encode $ object
            [ "session"           .= ("scratch" :: Text)
            , "window"            .= ("zsh" :: Text)
            , "window_index"      .= (2 :: Int)
            , "consent_confirmed" .= True
            ]
      (st, _) <- postJSON env ["api", "adopt"] body
      st `shouldBe` HTTP.status200
      readIORef gotIndex `shouldReturn` Just 2

    it "passes Nothing to _fe_adopt when no window_index is supplied (manual entry → name fallback)" $ do
      env0 <- mkTestFrontendEnv
      gotIndex <- newIORef (Just 7)  -- sentinel: must be overwritten with Nothing
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \_ mIdx _ -> do
                writeIORef gotIndex mIdx
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "scratch" "zsh")
      st `shouldBe` HTTP.status200
      readIORef gotIndex `shouldReturn` Nothing

    it "syncs the legacy _fe_harnesses map on a successful adopt (D-ADD-2)" $ do
      env0 <- mkTestFrontendEnv
      let env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \_ _ _ ->
                pure (Right (mustParseHid "11111111-1111-4111-8111-111111111111", mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "scratch" "win-9")
      st `shouldBe` HTTP.status200
      handles <- readIORef (_fe_harnesses env)
      Map.member "win-9" handles `shouldBe` True

    it "D4.4 a freshly-adopted window appears in GET /api/tabs with origin=\"adopted\" + an attach_command" $ do
      -- End-to-end at the endpoint: a real registry, a _fe_adopt that inserts an
      -- OriginAdopted entry (as the production mechanism does) AND appends to the
      -- TabRegistry (WU6). After POST /api/adopt the tab list shows the adopted row.
      env0 <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
          reg = _fe_harnessRegistry env0
          env = env0
            { _fe_consentChannel = ConsentInteractive
            , _fe_adopt          = \tok _idx w -> do
                Registry.insertEntry reg
                  ((baseEntry hid w (Just mkNoOpHarnessHandle))
                    { Registry._he_session    = "scratch"
                    , Registry._he_windowName = w
                    , Registry._he_label      = w
                    , Registry._he_origin     = Registry.OriginAdopted
                    , Registry._he_shellPid   = Just 4242  -- corroborated
                    })
                -- WU6: also bind the tab in the TabRegistry so GET /api/tabs sees it.
                _ <- registryAppend (_fe_tabRegistry env0) (BoundHarness hid)
                _ <- pure (tok :: AdoptedHarness)
                pure (Right (hid, mkNoOpHarnessHandle))
            }
      (st, _) <- postJSON env ["api", "adopt"] (adoptBody "scratch" "win-adopted")
      st `shouldBe` HTTP.status200
      (tabSt, tabBody) <- getJSON env ["api", "tabs"]
      tabSt `shouldBe` HTTP.status200
      case Aeson.decode tabBody of
        Just (Aeson.Array items) -> case toList' items of
          [t] -> do
            lookupKey t "origin" `shouldBe` Just (Aeson.String "adopted")
            lookupKey t "attach_command"
              `shouldBe` Just (Aeson.String "tmux attach -t scratch:win-adopted")
          other -> expectationFailure ("expected one tab, got " <> show (length other))
        _ -> expectationFailure "expected a JSON array of tabs"

  -- -----------------------------------------------------------------------
  -- WU8: registry-backed Active-Tabs slice (the reported symptom)
  -- -----------------------------------------------------------------------

  describe "livenessToTabStatus (WU8 → P2-WU1 — status vocabulary)" $ do
    it "maps LivenessIdle to \"idle\"" $
      livenessToTabStatus Registry.LivenessIdle `shouldBe` "idle"
    it "maps LivenessThinking to \"running\"" $
      livenessToTabStatus Registry.LivenessThinking `shouldBe` "running"
    -- P2-WU1 D1.1: Exited and Orphaned no longer collapse to "crashed";
    -- they map to distinct status strings so the frontend can render the
    -- §7 state→visual split (Exited: ✕ crashed + [Restart] [Dismiss];
    -- Orphaned: ✕ greyed + [Dismiss]).
    it "maps LivenessExited to \"exited\"" $
      livenessToTabStatus Registry.LivenessExited `shouldBe` "exited"
    it "maps LivenessOrphaned to \"orphaned\"" $
      livenessToTabStatus Registry.LivenessOrphaned `shouldBe` "orphaned"
    it "gives Exited and Orphaned distinct status strings (no longer collapsed)" $
      livenessToTabStatus Registry.LivenessExited
        `shouldNotBe` livenessToTabStatus Registry.LivenessOrphaned
    -- Task 3: LivenessAwaitingInput → "running" (distinct state shown via activity dot)
    it "maps LivenessAwaitingInput to \"running\"" $
      livenessToTabStatus Registry.LivenessAwaitingInput `shouldBe` "running"

  describe "harnessOriginToText (P2-WU1 — origin pill mapping)" $ do
    it "maps OriginSpawned to \"spawned\"" $
      harnessOriginToText Registry.OriginSpawned `shouldBe` "spawned"
    it "maps OriginDiscovered to \"discovered\"" $
      harnessOriginToText Registry.OriginDiscovered `shouldBe` "discovered"
    it "maps OriginAdopted to \"adopted\"" $
      harnessOriginToText Registry.OriginAdopted `shouldBe` "adopted"

  describe "harnessEntriesToTabs (WU8 — pure mapping)" $ do
    it "returns an empty list for no entries" $
      harnessEntriesToTabs [] `shouldBe` []

    it "maps an entry's fields onto a harness TabSnapshot" $ do
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
          e   = (baseEntry hid "claude-code-0" Nothing)
                  { Registry._he_label     = "claude-code"
                  , Registry._he_liveness  = Registry.LivenessThinking
                  , Registry._he_sessionId = Just "session-xyz"
                  }
      case harnessEntriesToTabs [e] of
        [t] -> do
          _ts_kind t      `shouldBe` "harness"
          _ts_label t     `shouldBe` Just "claude-code"
          _ts_status t    `shouldBe` "running"
          _ts_sessionId t `shouldBe` Just "session-xyz"
          _ts_index t     `shouldBe` 0
        other -> expectationFailure ("expected one tab, got " <> show (length other))

    it "populates extModified, stale, origin, and the attach command (P2-WU1 D1.2)" $ do
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
          e   = (baseEntry hid "claude-code-3" Nothing)
                  { Registry._he_session     = "pureclaw"
                  , Registry._he_windowName  = "claude-code-3"
                  , Registry._he_extModified = True
                  , Registry._he_stale       = True
                  , Registry._he_origin      = Registry.OriginDiscovered
                  }
      case harnessEntriesToTabs [e] of
        [t] -> do
          _ts_extModified t   `shouldBe` True
          _ts_stale t         `shouldBe` True
          _ts_origin t        `shouldBe` "discovered"
          _ts_attachCommand t `shouldBe` Just "tmux attach -t pureclaw:claude-code-3"
        other -> expectationFailure ("expected one tab, got " <> show (length other))

    it "assigns stable indices by sorting on (label, id) and enumerating from 0" $ do
      -- Insert in a non-sorted order; the indices must reflect the
      -- deterministic (label, id) ordering, not insertion order.
      let hidA = mustParseHid "33333333-3333-4333-8333-333333333333"
          hidB = mustParseHid "11111111-1111-4111-8111-111111111111"
          mk lbl hid = (baseEntry hid "win" Nothing) { Registry._he_label = lbl }
          -- "bravo" sorts after "alpha"; "alpha" entries tie-break on id text.
          es = [ mk "bravo" hidA          -- label bravo
               , mk "alpha" hidA          -- label alpha, id "3333..."
               , mk "alpha" hidB          -- label alpha, id "1111..." (sorts first)
               ]
      let tabs = harnessEntriesToTabs es
      map _ts_index tabs `shouldBe` [0, 1, 2]
      -- The first two are the "alpha" entries, id "1111..." before "3333...".
      map (\t -> (_ts_index t, _ts_label t)) tabs
        `shouldBe` [(0, Just "alpha"), (1, Just "alpha"), (2, Just "bravo")]

  describe "GET /api/tabs (registry-wired — WU8 D8.1/D8.2)" $ do
    it "is empty when the registry has no harnesses" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      respBody `shouldBe` Aeson.encode ([] :: [Aeson.Value])

    it "shows a spawned harness as a harness tab (the reported symptom fixed)" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
      seedHarnessTab env
        (baseEntry hid "claude-code-0" Nothing)
          { Registry._he_label    = "claude-code"
          , Registry._he_liveness = Registry.LivenessIdle
          }
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Just (Aeson.Array arr) -> do
          let items = toList' arr
          length items `shouldBe` 1
          let t0 = head items
          lookupKey t0 "kind"  `shouldBe` Just (Aeson.String "harness")
          lookupKey t0 "label" `shouldBe` Just (Aeson.String "claude-code")
        _ -> expectationFailure "Expected JSON array with one harness tab"

    it "reflects each entry's liveness as the documented status string" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hidI = mustParseHid "11111111-1111-4111-8111-111111111111"
          hidT = mustParseHid "22222222-2222-4222-8222-222222222222"
          hidE = mustParseHid "33333333-3333-4333-8333-333333333333"
          hidO = mustParseHid "44444444-4444-4444-8444-444444444444"
          seed lbl hid lv = seedHarnessTab env
            (baseEntry hid "win" Nothing)
              { Registry._he_label = lbl, Registry._he_liveness = lv }
      seed "a-idle"     hidI Registry.LivenessIdle
      seed "b-thinking" hidT Registry.LivenessThinking
      seed "c-exited"   hidE Registry.LivenessExited
      seed "d-orphaned" hidO Registry.LivenessOrphaned
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Just (Aeson.Array arr) -> do
          let pairs =
                [ (n, s)
                | v <- toList' arr
                , Just (Aeson.String n) <- [lookupKey v "label"]
                , Just (Aeson.String s) <- [lookupKey v "status"]
                ]
          lookup "a-idle"     pairs `shouldBe` Just "idle"
          lookup "b-thinking" pairs `shouldBe` Just "running"
          -- P2-WU1 D1.1: distinct status strings end-to-end through /api/tabs.
          lookup "c-exited"   pairs `shouldBe` Just "exited"
          lookup "d-orphaned" pairs `shouldBe` Just "orphaned"
        _ -> expectationFailure "Expected JSON array"

    it "surfaces ext_modified, stale, origin, and attach_command in the JSON (P2-WU1 D1.2)" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
      seedHarnessTab env
        (baseEntry hid "claude-code-0" Nothing)
          { Registry._he_label      = "claude-code"
          , Registry._he_session    = "pureclaw"
          , Registry._he_windowName = "claude-code-0"
          , Registry._he_liveness   = Registry.LivenessIdle
          , Registry._he_extModified = True
          , Registry._he_stale       = True
          , Registry._he_origin      = Registry.OriginAdopted
          }
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Just (Aeson.Array arr) -> do
          let t0 = head (toList' arr)
          lookupKey t0 "ext_modified"   `shouldBe` Just (Aeson.Bool True)
          lookupKey t0 "stale"          `shouldBe` Just (Aeson.Bool True)
          lookupKey t0 "origin"         `shouldBe` Just (Aeson.String "adopted")
          lookupKey t0 "attach_command"
            `shouldBe` Just (Aeson.String "tmux attach -t pureclaw:claude-code-0")
        _ -> expectationFailure "Expected JSON array with one harness tab"

    it "keeps the existing keys (name replaced by label) for a harness tab" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
      seedHarnessTab env
        (baseEntry hid "claude-code-0" Nothing)
          { Registry._he_label    = "claude-code"
          , Registry._he_liveness = Registry.LivenessIdle
          , Registry._he_sessionId = Just "session-abc"
          }
      (st, respBody) <- getJSON env ["api", "tabs"]
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Just (Aeson.Array arr) -> do
          let t0 = head (toList' arr)
          -- The per-tab "name" key is GONE; a harness tab carries its label as
          -- the "label" fallback. The other keys are unchanged.
          lookupKey t0 "index"      `shouldBe` Just (Aeson.Number 0)
          lookupKey t0 "kind"       `shouldBe` Just (Aeson.String "harness")
          lookupKey t0 "name"       `shouldBe` Nothing
          lookupKey t0 "label"      `shouldBe` Just (Aeson.String "claude-code")
          lookupKey t0 "status"     `shouldBe` Just (Aeson.String "idle")
          lookupKey t0 "session_id" `shouldBe` Just (Aeson.String "session-abc")
        _ -> expectationFailure "Expected JSON array with one harness tab"

  -- -----------------------------------------------------------------------
  -- P2-WU3: per-row action endpoints (Dismiss / Acknowledge / Restart)
  -- -----------------------------------------------------------------------

  describe "POST /api/tabs/{index}/dismiss (P2-WU3 D3.1)" $ do
    it "removes the entry from BOTH the registry and the legacy map, leaving session.json intact" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-001"
        writeTestSession tmpDir sid False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        let env = env0 { _fe_sessionsDir = tmpDir }
            hid = mustParseHid "11111111-1111-4111-8111-111111111111"
        -- Seed a registry entry whose label is ALSO present in the legacy map.
        Registry.insertEntry (_fe_harnessRegistry env)
          (baseEntry hid "claude-code-0" Nothing)
            { Registry._he_label     = "claude-code"
            , Registry._he_liveness  = Registry.LivenessExited
            , Registry._he_sessionId = Just sid
            }
        tabBindHarness env hid  -- WU7: bind the slot the action resolves against
        modifyIORef' (_fe_harnesses env)
          (Map.insert "claude-code" mkNoOpHarnessHandle)
        (st, respBody) <- postJSON env ["api", "tabs", "0", "dismiss"] "{}"
        st `shouldBe` HTTP.status200
        lookupKey' respBody "dismissed" `shouldBe` Just (Aeson.Bool True)
        -- Gone from the registry...
        gone <- Registry.lookupById (_fe_harnessRegistry env) hid
        (Registry._he_id <$> gone) `shouldBe` Nothing
        -- ...and gone from the legacy map...
        legacy <- readIORef (_fe_harnesses env)
        Map.member "claude-code" legacy `shouldBe` False
        -- ...but session.json is untouched, so the sid still loads in Recent.
        (rst, recentBody) <- getJSON env ["api", "sessions", "recent"]
        rst `shouldBe` HTTP.status200
        case Aeson.decode recentBody of
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` elem sid
          _ -> expectationFailure "Expected JSON array"

    it "returns 404 for an out-of-range index" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry hid "claude-code-0" Nothing)
      (st, respBody) <- postJSON env ["api", "tabs", "5", "dismiss"] "{}"
      st `shouldBe` HTTP.status404
      lookupKey' respBody "dismissed" `shouldBe` Nothing
      -- The entry was NOT removed by an out-of-range request.
      still <- Registry.lookupById (_fe_harnessRegistry env) hid
      (Registry._he_id <$> still) `shouldBe` Just hid

    it "returns 400 for a non-numeric index" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      (st, _) <- postJSON env ["api", "tabs", "notanint", "dismiss"] "{}"
      st `shouldBe` HTTP.status400

  -- =========================================================================
  -- Phase 3 WU5 — POST /api/tabs/{index}/release (never kills; SEC-3)
  -- =========================================================================
  describe "pickLiveMarker (Phase 3 WU5 — pure live-@pcl_id lookup)" $ do
    let row name pclId = TmuxWindowRow
          { _twr_windowIndex = 0
          , _twr_windowName  = name
          , _twr_pclId       = pclId
          , _twr_panePid     = Just 100
          , _twr_paneDead    = False
          }
    it "returns the non-empty @pcl_id of the matching window" $
      pickLiveMarker "win-a" [row "win-x" "id-x", row "win-a" "id-a"]
        `shouldBe` Just "id-a"
    it "returns Nothing when the window is absent" $
      pickLiveMarker "win-z" [row "win-a" "id-a"] `shouldBe` Nothing
    it "treats an empty marker as no marker (window present but unmarked)" $
      pickLiveMarker "win-a" [row "win-a" ""] `shouldBe` Nothing
    it "returns Nothing for an empty sweep" $
      pickLiveMarker "win-a" [] `shouldBe` Nothing

  describe "POST /api/tabs/{index}/release (Phase 3 WU5)" $ do
    let adoptedHid = mustParseHid "33333333-3333-4333-8333-333333333333"
        -- An OriginAdopted entry whose live @pcl_id WILL match its id text.
        adoptedEntry hid window =
          (corroboratedEntry hid window (Just mkNoOpHarnessHandle))
            { Registry._he_session    = "scratch"
            , Registry._he_windowName = window
            , Registry._he_label      = window
            , Registry._he_origin     = Registry.OriginAdopted
            }
        -- A ReleaseTmux that records every (session, window) the handler asks it
        -- to clear, and answers the live-marker probe from a fixed map.
        recordingReleaseTmux liveRef clearedRef =
          ReleaseTmux
            { _rt_liveMarker  = \s w -> do
                m <- readIORef liveRef
                pure (Map.lookup (s, w) m)
            , _rt_clearMarker = \s w ->
                modifyIORef' clearedRef (++ [(s, w)])
            , _rt_renameWindow = \_ _ _ -> pure ()
            }

    it "D5.1 corroborated adopted entry: clears @pcl_id (set-option -wu via seam), removes from registry+legacy map, NO kill issued" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      clearedRef <- newIORef []
      -- The live marker matches the entry's id text → corroborated.
      liveRef <- newIORef
        (Map.singleton ("scratch", "win-adopted")
                       (Registry.harnessIdToText adoptedHid))
      let env = env0 { _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef }
      Registry.insertEntry (_fe_harnessRegistry env)
        (adoptedEntry adoptedHid "win-adopted")
      tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
      modifyIORef' (_fe_harnesses env)
        (Map.insert "win-adopted" mkNoOpHarnessHandle)
      (st, respBody) <- postJSON env ["api", "tabs", "0", "release"] "{}"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "released" `shouldBe` Just (Aeson.Bool True)
      -- The ONLY tmux mutation was the unmark, targeting our window — no kill.
      cleared <- readIORef clearedRef
      cleared `shouldBe` [("scratch", "win-adopted")]
      -- Gone from the registry...
      gone <- Registry.lookupById (_fe_harnessRegistry env) adoptedHid
      (Registry._he_id <$> gone) `shouldBe` Nothing
      -- ...and gone from the legacy map.
      legacy <- readIORef (_fe_harnesses env)
      Map.member "win-adopted" legacy `shouldBe` False

    it "D5.2 (SEC-3) STALE entry (live @pcl_id mismatch): deregisters WITHOUT any tmux set-option, and logs a refusal" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      logRef <- newIORef []
      clearedRef <- newIORef []
      -- The live marker is a DIFFERENT id (the window was replaced / PID reuse).
      liveRef <- newIORef
        (Map.singleton ("scratch", "win-adopted")
                       "99999999-9999-4999-8999-999999999999")
      let env = env0
            { _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef
            , _fe_logger      = captureWarnLogger logRef
            }
      Registry.insertEntry (_fe_harnessRegistry env)
        (adoptedEntry adoptedHid "win-adopted")
      tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
      modifyIORef' (_fe_harnesses env)
        (Map.insert "win-adopted" mkNoOpHarnessHandle)
      (st, respBody) <- postJSON env ["api", "tabs", "0", "release"] "{}"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "released" `shouldBe` Just (Aeson.Bool True)
      -- The invariant: NO window op (clearMarker NEVER called) on a stale entry.
      cleared <- readIORef clearedRef
      cleared `shouldBe` []
      -- A refusal was logged.
      warns <- readIORef logRef
      warns `shouldSatisfy` any ("no longer corroborated" `T.isInfixOf`)
      -- Still deregistered from BOTH stores (we stop managing it either way).
      gone <- Registry.lookupById (_fe_harnessRegistry env) adoptedHid
      (Registry._he_id <$> gone) `shouldBe` Nothing
      legacy <- readIORef (_fe_harnesses env)
      Map.member "win-adopted" legacy `shouldBe` False

    it "D5.2 (SEC-3) window gone (no live marker): deregisters WITHOUT any tmux set-option, and logs" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      logRef <- newIORef []
      clearedRef <- newIORef []
      liveRef <- newIORef Map.empty  -- the window is gone → Nothing
      let env = env0
            { _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef
            , _fe_logger      = captureWarnLogger logRef
            }
      Registry.insertEntry (_fe_harnessRegistry env)
        (adoptedEntry adoptedHid "win-adopted")
      tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
      (st, _) <- postJSON env ["api", "tabs", "0", "release"] "{}"
      st `shouldBe` HTTP.status200
      cleared <- readIORef clearedRef
      cleared `shouldBe` []
      -- The refusal log names the missing marker ("<none>") and is forced here.
      warns <- readIORef logRef
      warns `shouldSatisfy` any (\w -> "no longer corroborated" `T.isInfixOf` w
                                       && "<none>" `T.isInfixOf` w)
      gone <- Registry.lookupById (_fe_harnessRegistry env) adoptedHid
      (Registry._he_id <$> gone) `shouldBe` Nothing

    it "releases a SPAWNED harness too (corroborated): clears @pcl_id, retitles the window '(released)', deregisters, 200" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      clearedRef <- newIORef []
      renamedRef <- newIORef []
      -- A corroborating live marker is present; origin is Spawned (baseEntry
      -- default) — release now applies to ANY origin, gated only by corroboration.
      liveRef <- newIORef
        (Map.singleton ("pureclaw", "claude-code-0")
                       (Registry.harnessIdToText adoptedHid))
      let rt = ReleaseTmux
            { _rt_liveMarker   = \s w -> Map.lookup (s, w) <$> readIORef liveRef
            , _rt_clearMarker  = \s w -> modifyIORef' clearedRef (++ [(s, w)])
            , _rt_renameWindow = \s w n -> modifyIORef' renamedRef (++ [(s, w, n)])
            }
          env = env0 { _fe_releaseTmux = rt }
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry adoptedHid "claude-code-0" (Just mkNoOpHarnessHandle))
      tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
      (st, respBody) <- postJSON env ["api", "tabs", "0", "release"] "{}"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "released" `shouldBe` Just (Aeson.Bool True)
      -- The window was unmarked AND retitled to show PureClaw detached — but
      -- never killed.
      cleared <- readIORef clearedRef
      cleared `shouldBe` [("pureclaw", "claude-code-0")]
      renamed <- readIORef renamedRef
      renamed `shouldBe` [("pureclaw", "claude-code-0", "claude-code-0 (released)")]
      -- Deregistered (PureClaw stops managing it); window left running.
      gone <- Registry.lookupById (_fe_harnessRegistry env) adoptedHid
      (Registry._he_id <$> gone) `shouldBe` Nothing

    it "returns 404 for an out-of-range index (no tmux op)" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      clearedRef <- newIORef []
      liveRef <- newIORef Map.empty
      let env = env0 { _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef }
      Registry.insertEntry (_fe_harnessRegistry env)
        (adoptedEntry adoptedHid "win-adopted")
      (st, _) <- postJSON env ["api", "tabs", "5", "release"] "{}"
      st `shouldBe` HTTP.status404
      cleared <- readIORef clearedRef
      cleared `shouldBe` []

    it "returns 400 for a non-numeric index" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      (st, _) <- postJSON env ["api", "tabs", "notanint", "release"] "{}"
      st `shouldBe` HTTP.status400

    it "tolerates a non-JSON body (purge defaults to false): still releases a corroborated entry" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      clearedRef <- newIORef []
      liveRef <- newIORef
        (Map.singleton ("scratch", "win-adopted")
                       (Registry.harnessIdToText adoptedHid))
      let env = env0 { _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef }
      Registry.insertEntry (_fe_harnessRegistry env)
        (adoptedEntry adoptedHid "win-adopted")
      tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
      (st, respBody) <- postJSON env ["api", "tabs", "0", "release"] "not json at all"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "released" `shouldBe` Just (Aeson.Bool True)
      cleared <- readIORef clearedRef
      cleared `shouldBe` [("scratch", "win-adopted")]

    it "D5.3 retention: transcript/session.json persist after release — the sid still loads in Recent" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-007"
        writeTestSession tmpDir sid False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        clearedRef <- newIORef []
        liveRef <- newIORef
          (Map.singleton ("scratch", "win-adopted")
                         (Registry.harnessIdToText adoptedHid))
        let env = env0
              { _fe_sessionsDir = tmpDir
              , _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef
              }
        Registry.insertEntry (_fe_harnessRegistry env)
          ((adoptedEntry adoptedHid "win-adopted")
            { Registry._he_sessionId = Just sid })
        tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
        (st, _) <- postJSON env ["api", "tabs", "0", "release"] "{}"
        st `shouldBe` HTTP.status200
        -- The session.json was NOT deleted → it reappears in Recent Sessions.
        (rst, recentBody) <- getJSON env ["api", "sessions", "recent"]
        rst `shouldBe` HTTP.status200
        case Aeson.decode recentBody of
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` elem sid
          _ -> expectationFailure "Expected JSON array"

    it "D5.4 the purge flag is accepted but reserved (documented no-op): session.json is NOT deleted" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-008"
        writeTestSession tmpDir sid False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        clearedRef <- newIORef []
        infoRef <- newIORef []
        liveRef <- newIORef
          (Map.singleton ("scratch", "win-adopted")
                         (Registry.harnessIdToText adoptedHid))
        let env = env0
              { _fe_sessionsDir = tmpDir
              , _fe_releaseTmux = recordingReleaseTmux liveRef clearedRef
              , _fe_logger      = captureInfoLogger infoRef
              }
        Registry.insertEntry (_fe_harnessRegistry env)
          ((adoptedEntry adoptedHid "win-adopted")
            { Registry._he_sessionId = Just sid })
        tabBindHarness env adoptedHid  -- WU7: bind the slot the action resolves against
        -- Body explicitly requests purge:true — which is RESERVED (no-op).
        (st, respBody) <- postJSON env ["api", "tabs", "0", "release"]
          (Aeson.encode (object ["purge" .= True]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "released" `shouldBe` Just (Aeson.Bool True)
        -- The reserved-purge no-op is logged (auditable) but NOT acted upon.
        infos <- readIORef infoRef
        infos `shouldSatisfy` any ("purge requested but RESERVED" `T.isInfixOf`)
        -- The session dir is still on disk (purge did NOT delete it).
        stillThere <- doesDirectoryExist (tmpDir </> T.unpack sid)
        stillThere `shouldBe` True

  -- =========================================================================
  -- POST /api/tabs/{index}/destroy — terminates the harness (kill-window),
  -- archives its session (transcript retained), deregisters from both stores.
  -- Adopted harnesses require an explicit confirm_adopted (server-enforced).
  -- Kill is corroborated-before-mutate (SEC-3): never kill a window we cannot
  -- confirm is ours.
  -- =========================================================================
  describe "POST /api/tabs/{index}/destroy" $ do
    let destroyHid = mustParseHid "55555555-5555-4555-8555-555555555555"
        -- A recording kill seam: records every (session, window) it is asked
        -- to kill. A corroborating ReleaseTmux supplies the live @pcl_id probe.
        recordingKill killedRef s w = modifyIORef' killedRef (++ [(s, w)])
        liveMatching hid s w =
          newIORef (Map.singleton (s, w) (Registry.harnessIdToText hid))

    it "spawned + corroborated: kills the window, archives the session, deregisters from both stores" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-001"
        writeTestSession tmpDir sid False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        killedRef <- newIORef []
        liveRef <- liveMatching destroyHid "pureclaw" "claude-code-0"
        let env = env0
              { _fe_sessionsDir = tmpDir
              , _fe_killWindow   = recordingKill killedRef
              , _fe_releaseTmux  = ReleaseTmux
                  { _rt_liveMarker  = \s w -> Map.lookup (s, w) <$> readIORef liveRef
                  , _rt_clearMarker = \_ _ -> pure ()
                  , _rt_renameWindow = \_ _ _ -> pure ()
                  }
              }
        Registry.insertEntry (_fe_harnessRegistry env)
          (baseEntry destroyHid "claude-code-0" (Just mkNoOpHarnessHandle))
            { Registry._he_label      = "claude-code-0"
            , Registry._he_session    = "pureclaw"
            , Registry._he_windowName = "claude-code-0"
            , Registry._he_origin     = Registry.OriginSpawned
            , Registry._he_sessionId  = Just sid
            }
        tabBindHarness env destroyHid  -- WU7: bind the slot the action resolves against
        modifyIORef' (_fe_harnesses env) (Map.insert "claude-code-0" mkNoOpHarnessHandle)
        (st, respBody) <- postJSON env ["api", "tabs", "0", "destroy"] "{}"
        st `shouldBe` HTTP.status200
        lookupKey' respBody "destroyed" `shouldBe` Just (Aeson.Bool True)
        -- The window was killed exactly once, at the right coordinate.
        killed <- readIORef killedRef
        killed `shouldBe` [("pureclaw", "claude-code-0")]
        -- Gone from the registry and the legacy map.
        gone <- Registry.lookupById (_fe_harnessRegistry env) destroyHid
        (Registry._he_id <$> gone) `shouldBe` Nothing
        legacy <- readIORef (_fe_harnesses env)
        Map.member "claude-code-0" legacy `shouldBe` False
        -- The session was ARCHIVED (transcript retained): it is no longer in
        -- Recent, but it IS in Archived.
        (_, recentBody) <- getJSON env ["api", "sessions", "recent"]
        case Aeson.decode recentBody of
          Just (Aeson.Array arr) ->
            [ t | v <- toList' arr, Just (Aeson.String t) <- [lookupKey v "id"] ]
              `shouldNotSatisfy` elem sid
          _ -> expectationFailure "Expected JSON array"
        (_, archBody) <- getJSON env ["api", "sessions", "archived"]
        case Aeson.decode archBody of
          Just (Aeson.Array arr) ->
            [ t | v <- toList' arr, Just (Aeson.String t) <- [lookupKey v "id"] ]
              `shouldSatisfy` elem sid
          _ -> expectationFailure "Expected JSON array"

    it "SEC-3 stale entry (live @pcl_id mismatch): deregisters and archives WITHOUT killing, logs a refusal" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid = "test-20240101-120000-002"
        writeTestSession tmpDir sid False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        killedRef <- newIORef []
        logRef <- newIORef []
        liveRef <- newIORef
          (Map.singleton ("pureclaw", "claude-code-0")
                         "99999999-9999-4999-8999-999999999999")
        let env = env0
              { _fe_sessionsDir = tmpDir
              , _fe_killWindow   = recordingKill killedRef
              , _fe_logger       = captureWarnLogger logRef
              , _fe_releaseTmux  = ReleaseTmux
                  { _rt_liveMarker  = \s w -> Map.lookup (s, w) <$> readIORef liveRef
                  , _rt_clearMarker = \_ _ -> pure ()
                  , _rt_renameWindow = \_ _ _ -> pure ()
                  }
              }
        Registry.insertEntry (_fe_harnessRegistry env)
          (baseEntry destroyHid "claude-code-0" (Just mkNoOpHarnessHandle))
            { Registry._he_session    = "pureclaw"
            , Registry._he_windowName = "claude-code-0"
            , Registry._he_origin     = Registry.OriginSpawned
            , Registry._he_sessionId  = Just sid
            }
        tabBindHarness env destroyHid  -- WU7: bind the slot the action resolves against
        (st, respBody) <- postJSON env ["api", "tabs", "0", "destroy"] "{}"
        st `shouldBe` HTTP.status200
        lookupKey' respBody "destroyed" `shouldBe` Just (Aeson.Bool True)
        -- The invariant: we never killed a window we could not confirm is ours.
        killed <- readIORef killedRef
        killed `shouldBe` []
        warns <- readIORef logRef
        warns `shouldSatisfy` any ("no longer corroborated" `T.isInfixOf`)
        -- Still deregistered (we stop managing it either way).
        gone <- Registry.lookupById (_fe_harnessRegistry env) destroyHid
        (Registry._he_id <$> gone) `shouldBe` Nothing

    it "adopted WITHOUT confirm_adopted: 409, no kill, still registered" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      killedRef <- newIORef []
      liveRef <- liveMatching destroyHid "scratch" "win-adopted"
      let env = env0
            { _fe_killWindow  = recordingKill killedRef
            , _fe_releaseTmux = ReleaseTmux
                { _rt_liveMarker  = \s w -> Map.lookup (s, w) <$> readIORef liveRef
                , _rt_clearMarker = \_ _ -> pure ()
                , _rt_renameWindow = \_ _ _ -> pure ()
                }
            }
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry destroyHid "win-adopted" (Just mkNoOpHarnessHandle))
          { Registry._he_session    = "scratch"
          , Registry._he_windowName = "win-adopted"
          , Registry._he_origin     = Registry.OriginAdopted
          }
      tabBindHarness env destroyHid  -- WU7: bind the slot the action resolves against
      (st, respBody) <- postJSON env ["api", "tabs", "0", "destroy"] "{}"
      st `shouldBe` HTTP.status409
      lookupKey' respBody "destroyed" `shouldBe` Nothing
      killed <- readIORef killedRef
      killed `shouldBe` []
      still <- Registry.lookupById (_fe_harnessRegistry env) destroyHid
      (Registry._he_id <$> still) `shouldBe` Just destroyHid

    it "adopted WITH confirm_adopted=true + corroborated: kills the window and deregisters" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      killedRef <- newIORef []
      liveRef <- liveMatching destroyHid "scratch" "win-adopted"
      let env = env0
            { _fe_killWindow  = recordingKill killedRef
            , _fe_releaseTmux = ReleaseTmux
                { _rt_liveMarker  = \s w -> Map.lookup (s, w) <$> readIORef liveRef
                , _rt_clearMarker = \_ _ -> pure ()
                , _rt_renameWindow = \_ _ _ -> pure ()
                }
            }
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry destroyHid "win-adopted" (Just mkNoOpHarnessHandle))
          { Registry._he_session    = "scratch"
          , Registry._he_windowName = "win-adopted"
          , Registry._he_origin     = Registry.OriginAdopted
          }
      tabBindHarness env destroyHid  -- WU7: bind the slot the action resolves against
      (st, respBody) <- postJSON env ["api", "tabs", "0", "destroy"]
                          "{\"confirm_adopted\":true}"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "destroyed" `shouldBe` Just (Aeson.Bool True)
      killed <- readIORef killedRef
      killed `shouldBe` [("scratch", "win-adopted")]
      gone <- Registry.lookupById (_fe_harnessRegistry env) destroyHid
      (Registry._he_id <$> gone) `shouldBe` Nothing

    it "returns 404 for an out-of-range index (no kill)" $ do
      env0 <- mkTestFrontendEnvWithRegistryTabs
      killedRef <- newIORef []
      let env = env0 { _fe_killWindow = recordingKill killedRef }
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry destroyHid "claude-code-0" Nothing)
      (st, _) <- postJSON env ["api", "tabs", "5", "destroy"] "{}"
      st `shouldBe` HTTP.status404
      killed <- readIORef killedRef
      killed `shouldBe` []

    it "returns 400 for a non-numeric index" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      (st, _) <- postJSON env ["api", "tabs", "notanint", "destroy"] "{}"
      st `shouldBe` HTTP.status400

  describe "POST /api/tabs/{index}/acknowledge (P2-WU3 D3.2)" $ do
    it "clears the ext_modified flag (verified via a follow-up /api/tabs)" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
      seedHarnessTab env
        (baseEntry hid "claude-code-0" Nothing)
          { Registry._he_label       = "claude-code"
          , Registry._he_extModified = True
          }
      (st, respBody) <- postJSON env ["api", "tabs", "0", "acknowledge"] "{}"
      st `shouldBe` HTTP.status200
      lookupKey' respBody "acknowledged" `shouldBe` Just (Aeson.Bool True)
      -- A follow-up /api/tabs snapshot shows ext_modified == false.
      (tst, tabsBody) <- getJSON env ["api", "tabs"]
      tst `shouldBe` HTTP.status200
      case Aeson.decode tabsBody of
        Just (Aeson.Array arr) -> do
          let t0 = head (toList' arr)
          lookupKey t0 "ext_modified" `shouldBe` Just (Aeson.Bool False)
        _ -> expectationFailure "Expected JSON array with one harness tab"

    it "returns 404 for an out-of-range index" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry (mustParseHid "11111111-1111-4111-8111-111111111111")
                   "claude-code-0" Nothing)
      (st, _) <- postJSON env ["api", "tabs", "7", "acknowledge"] "{}"
      st `shouldBe` HTTP.status404

  describe "POST /api/tabs/{index}/restart (P2-WU3 D3.3)" $
    it "returns 501 with the reserved not-implemented error body" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      Registry.insertEntry (_fe_harnessRegistry env)
        (baseEntry (mustParseHid "11111111-1111-4111-8111-111111111111")
                   "claude-code-0" Nothing)
      (st, respBody) <- postJSON env ["api", "tabs", "0", "restart"] "{}"
      st `shouldBe` HTTP.status501
      lookupKey' respBody "error"
        `shouldBe` Just (Aeson.String "restart not yet implemented")

  describe "index->entry resolution matches /api/tabs ordering (P2-WU3 D3.4)" $
    it "dismissing index N removes exactly the row /api/tabs shows at N" $ do
      env <- mkTestFrontendEnvWithRegistryTabs
      -- Two entries with labels that sort deterministically: "alpha" < "bravo".
      -- Insert in alphabetical order so TabRegistry slot order agrees with
      -- 'sortedHarnessEntries' order used by the action endpoints.
      let hidA = mustParseHid "11111111-1111-4111-8111-111111111111"
          hidB = mustParseHid "22222222-2222-4222-8222-222222222222"
      seedHarnessTab env
        (baseEntry hidA "alpha" Nothing) { Registry._he_label = "alpha" }
      seedHarnessTab env
        (baseEntry hidB "bravo" Nothing) { Registry._he_label = "bravo" }
      -- Discover which label /api/tabs shows at index 1 BEFORE dismissing.
      (_, tabsBody) <- getJSON env ["api", "tabs"]
      let nameAt n = case Aeson.decode tabsBody of
            Just (Aeson.Array arr) ->
              listToMaybe' [ nm | v <- toList' arr
                                , Just (Aeson.Number i) <- [lookupKey v "index"]
                                , round i == (n :: Int)
                                , Just (Aeson.String nm) <- [lookupKey v "label"] ]
            _ -> Nothing
      nameAt 1 `shouldBe` Just "bravo"  -- "alpha" at slot 0, "bravo" at slot 1
      -- Dismiss index 1; exactly the "bravo" row (hidB) must be removed
      -- (action endpoints still use sortedHarnessEntries ordering: alpha=0, bravo=1).
      (st, _) <- postJSON env ["api", "tabs", "1", "dismiss"] "{}"
      st `shouldBe` HTTP.status200
      goneB <- Registry.lookupById (_fe_harnessRegistry env) hidB
      keptA <- Registry.lookupById (_fe_harnessRegistry env) hidA
      (Registry._he_id <$> goneB) `shouldBe` Nothing
      (Registry._he_id <$> keptA) `shouldBe` Just hidA

  describe "GET /api/sessions/recent (registry-wired exclusion — WU8 D8.3)" $ do
    it "lists the session held by a harness tab in recents (harness sessions stay reachable)" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sid1 = "test-20240101-120000-001"
            sid2 = "test-20240101-120000-002"
        writeTestSession tmpDir sid1 False
        writeTestSession tmpDir sid2 False
        env0 <- mkTestFrontendEnvWithRegistryTabs
        let env = env0 { _fe_sessionsDir = tmpDir }
        -- Seed a harness entry that holds sid1 into BOTH registries (WU6). A
        -- harness tab's session is NOT de-duped out of recents (unlike a
        -- provider/raw-shell tab): the harness keeps its controls entry under
        -- "Running Harnesses" AND its conversation is reachable as a Recent
        -- Sessions row.
        let hid = mustParseHid "11111111-1111-4111-8111-111111111111"
        seedHarnessTab env
          (baseEntry hid "claude-code-0" Nothing)
            { Registry._he_label = "claude-code", Registry._he_sessionId = Just sid1 }
        (st, respBody) <- getJSON env ["api", "sessions", "recent"]
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr
                          , Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` elem sid1
            ids `shouldSatisfy` elem sid2
          _ -> expectationFailure "Expected JSON array"

    it "lists a harness session with an EMPTY transcript in recents (freshly-adopted harness stays reachable)" $
      withSystemTempDirectory "pureclaw-test" $ \tmpDir -> do
        let sidH = "test-20240101-120000-010"   -- harness-backed, EMPTY transcript
            sidP = "test-20240101-120000-011"    -- unrelated session, EMPTY transcript
        writeTestSession tmpDir sidH False
        writeTestSession tmpDir sidP False
        -- Empty BOTH transcripts. A freshly-adopted harness has no transcript
        -- until its first turn; it must STILL be reachable (the only entry point
        -- to its conversation), whereas a plain empty session stays filtered out.
        LBS.writeFile (tmpDir </> T.unpack sidH </> "transcript.jsonl") ""
        LBS.writeFile (tmpDir </> T.unpack sidP </> "transcript.jsonl") ""
        env0 <- mkTestFrontendEnvWithRegistryTabs
        let env = env0 { _fe_sessionsDir = tmpDir }
            hid = mustParseHid "22222222-2222-4222-8222-222222222222"
        -- WU6: seed into BOTH registries so the harness carve-out applies
        -- (harness sessions bypass the empty-transcript filter).
        seedHarnessTab env
          (baseEntry hid "claude-code-0" Nothing)
            { Registry._he_label = "claude-code", Registry._he_sessionId = Just sidH }
        (st, respBody) <- getJSON env ["api", "sessions", "recent"]
        st `shouldBe` HTTP.status200
        case Aeson.decode respBody of
          Just (Aeson.Array arr) -> do
            let ids = [ t | v <- toList' arr, Just (Aeson.String t) <- [lookupKey v "id"] ]
            ids `shouldSatisfy` elem sidH      -- empty-transcript harness session IS reachable
            ids `shouldSatisfy` notElem sidP   -- a plain empty session is still hidden
          _ -> expectationFailure "Expected JSON array"

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
        -- Bind sid1 as a provider (non-harness) tab in the TabRegistry; WU6
        -- excludes non-harness active-tab sessions from recent.
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        _ <- registryAppend
               (_fe_tabRegistry env)
               (BoundSession (SessionId sid1))
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
  -- WU6: computeListsSnapshot — BoundSession tab deduplication
  -- -----------------------------------------------------------------------

  describe "computeListsSnapshot (WU6 — active-tab deduplication)" $ do
    it "a BoundSession tab appears in tabs and its sid is excluded from BOTH recent and archived" $
      withSystemTempDirectory "pureclaw-wu6-dedup" $ \tmpDir -> do
        let sid = "test-20240101-120000-wu6a"
        -- Create the session on disk and mark it ARCHIVED so it would normally
        -- appear in archivedSessions; the BoundSession tab binding must suppress it.
        writeTestSession tmpDir sid True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Append the session as a non-harness tab (BoundSession).
        _ <- registryAppend
               (_fe_tabRegistry env)
               (BoundSession (SessionId sid))
        snap <- computeListsSnapshot env
        let lookupArr key v = case v of
              Aeson.Object km -> case KM.lookup (AesonKey.fromText key) km of
                Just (Aeson.Array arr) -> toList' arr
                _                      -> []
              _ -> []
        -- The session appears in the "tabs" array.
        let tabIds = [ t | v <- lookupArr "tabs" snap
                         , Just (Aeson.String t) <- [lookupKey v "session_id"] ]
        tabIds `shouldSatisfy` elem sid
        -- The sid is NOT in recentSessions.
        let recentIds = [ t | v <- lookupArr "recentSessions" snap
                             , Just (Aeson.String t) <- [lookupKey v "id"] ]
        recentIds `shouldSatisfy` notElem sid
        -- The sid is NOT in archivedSessions.
        let archIds = [ t | v <- lookupArr "archivedSessions" snap
                           , Just (Aeson.String t) <- [lookupKey v "id"] ]
        archIds `shouldSatisfy` notElem sid

    it "a harness-tab session stays dual-listed in recentSessions" $
      withSystemTempDirectory "pureclaw-wu6-harness" $ \tmpDir -> do
        let sid = "test-20240101-120000-wu6b"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let hid = mustParseHid "55555555-5555-4555-8555-555555555555"
        -- Bind the session as a BoundHarness tab (kind="harness"); the harness
        -- carve-out means the session MUST still appear in recentSessions.
        seedHarnessTab env
          (baseEntry hid "wu6-win" Nothing)
            { Registry._he_label     = "wu6-harness"
            , Registry._he_sessionId = Just sid
            }
        snap <- computeListsSnapshot env
        let lookupArr key v = case v of
              Aeson.Object km -> case KM.lookup (AesonKey.fromText key) km of
                Just (Aeson.Array arr) -> toList' arr
                _                      -> []
              _ -> []
        let recentIds = [ t | v <- lookupArr "recentSessions" snap
                             , Just (Aeson.String t) <- [lookupKey v "id"] ]
        recentIds `shouldSatisfy` elem sid

    -- Task 7 (item 3): a description set via PUT /api/sessions/{sid}/description
    -- is REFLECTED in the broadcast 'lists' snapshot's session list. The tab
    -- label join is client-side, so the cross-surface parity rests on the
    -- backend exposing the session's canonical description in the very payload
    -- the frontend renders for Recent Sessions; this is the server half of the
    -- "tab reads identically to its Recent Sessions row" guarantee.
    it "a PUT description is reflected in the lists snapshot's recentSessions for that sid" $
      withSystemTempDirectory "pureclaw-task7-desc-snap" $ \tmpDir -> do
        let sid = "test-20240101-120000-task7"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Set the canonical description through the production endpoint.
        (st, _) <- putJSON env ["api", "sessions", sid, "description"]
          (Aeson.encode (object ["description" .= ("Renamed Title" :: Text)]))
        st `shouldBe` HTTP.status200
        snap <- computeListsSnapshot env
        let lookupArr key v = case v of
              Aeson.Object km -> case KM.lookup (AesonKey.fromText key) km of
                Just (Aeson.Array arr) -> toList' arr
                _                      -> []
              _ -> []
        -- The recentSessions payload for this sid carries the new description.
        let descsForSid =
              [ d
              | v <- lookupArr "recentSessions" snap
              , lookupKey v "id" == Just (Aeson.String sid)
              , Just d <- [lookupKey v "description"]
              ]
        descsForSid `shouldBe` [Aeson.String "Renamed Title"]

    -- After the "unify tab name = session name" refactor, an ACTIVE TAB's
    -- backing SessionInfo is deduped out of recentSessions AND the tab snapshot
    -- is meta-free, so the frontend can join NOWHERE to resolve the tab's
    -- session (chat-header pencil + renamed title vanish). The fix carries the
    -- full SessionInfo for active-tab-backed sessions in a NEW "tabSessions"
    -- array, while preserving the recentSessions dedup.
    it "an active-tab session's SessionInfo appears in tabSessions (not recentSessions), carrying its description" $
      withSystemTempDirectory "pureclaw-tabsessions" $ \tmpDir -> do
        let sid = "test-20240101-120000-tabsess"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Give the session a canonical description through the production endpoint.
        (st, _) <- putJSON env ["api", "sessions", sid, "description"]
          (Aeson.encode (object ["description" .= ("Renamed" :: Text)]))
        st `shouldBe` HTTP.status200
        -- Bind it as a non-harness (BoundSession) active tab.
        _ <- registryAppend (_fe_tabRegistry env) (BoundSession (SessionId sid))
        snap <- computeListsSnapshot env
        let lookupArr key v = case v of
              Aeson.Object km -> case KM.lookup (AesonKey.fromText key) km of
                Just (Aeson.Array arr) -> toList' arr
                _                      -> []
              _ -> []
        -- (a) The session's SessionInfo IS present in tabSessions, with its
        --     id AND its description.
        let tabDescsForSid =
              [ d
              | v <- lookupArr "tabSessions" snap
              , lookupKey v "id" == Just (Aeson.String sid)
              , Just d <- [lookupKey v "description"]
              ]
        tabDescsForSid `shouldBe` [Aeson.String "Renamed"]
        -- (b) The dedup is preserved: the sid is NOT in recentSessions.
        let recentIds = [ t | v <- lookupArr "recentSessions" snap
                             , Just (Aeson.String t) <- [lookupKey v "id"] ]
        recentIds `shouldSatisfy` notElem sid

  -- -----------------------------------------------------------------------
  -- Task 7 (item 3): the web-seam /tab rename round-trip is reflected in BOTH
  -- session.json (proven by "Task D" above) AND, end to end, the GET /api/tabs
  -- snapshot carries the matching session_id for the renamed slot. The tab
  -- label is a CLIENT-SIDE join over (tab.session_id -> session.description), so
  -- the backend's job is to expose the session_id on the tab snapshot and the
  -- description on the session — these two facts together let the client render
  -- a tab label identical to the Recent Sessions row.
  -- -----------------------------------------------------------------------

  describe "web /tab rename round-trip (Task 7 — tab snapshot carries the session_id)" $
    it "after /tab rename, session.json holds the description AND GET /api/tabs reports the matching session_id at slot 0" $
      withSystemTempDirectory "pureclaw-task7-tab-sid" $ \tmpDir -> do
        let sid = "20240101-000000-777"
        writeTestSession tmpDir sid False
        (env, tabReg) <- mkWebTabSeamEnv tmpDir
        _ <- registryAppend tabReg (BoundSession (SessionId sid))
        -- Drive the rename through the production HTTP send seam.
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/tab rename 0 RoundTripName" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        -- (a) session.json now carries the canonical description.
        Right onDisk <- Aeson.eitherDecodeFileStrict'
          (tmpDir </> T.unpack sid </> "session.json")
            :: IO (Either String SessionMeta)
        _sm_description onDisk `shouldBe` Just "RoundTripName"
        -- (b) The tab snapshot carries the matching session_id so the client can
        -- join the renamed description onto the tab's label.
        (stT, tabsBody) <- getJSON env ["api", "tabs"]
        stT `shouldBe` HTTP.status200
        case Aeson.decode tabsBody of
          Just (Aeson.Array arr) -> do
            let sids = [ s | v <- toList' arr
                           , Just (Aeson.String s) <- [lookupKey v "session_id"] ]
            sids `shouldSatisfy` elem sid
          _ -> expectationFailure "Expected GET /api/tabs to return a JSON array"

  -- -----------------------------------------------------------------------
  -- #67 follow-up: SessionInfo exposes channel name + channel user id
  -- (so the transcript header can show channel:userId instead of the model)
  -- -----------------------------------------------------------------------

  describe "toSessionInfo (channel + user id — #67)" $ do
    let epoch = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
        baseMeta src = SessionMeta
          { _sm_id                = SessionId "s1"
          , _sm_agent             = Nothing
          , _sm_kind              = SkProvider (ProviderSpec (inferProviderId "claude-sonnet-4-20250514") (ModelId "claude-sonnet-4-20250514") Nothing)
          , _sm_model             = "claude-sonnet-4-20250514"
          , _sm_channel           = "web"
          , _sm_createdAt         = epoch
          , _sm_lastActive        = epoch
          , _sm_bootstrapConsumed = True
          , _sm_archived          = False
          , _sm_description       = Nothing
          , _sm_autoSummary       = Nothing
          , _sm_source            = src
          }
    it "exposes channel name and user id from the session source" $ do
      let src = mkMessageSource CkSignal (ConversationId "+15551234567") (Just (UserId "+15551234567")) mempty
          si  = toSessionInfo (baseMeta (Just src)) Nothing
      _si_channel si `shouldBe` Just "signal"
      _si_channelUserId si `shouldBe` Just "+15551234567"
    it "yields no channel user id when the source has no user id (e.g. tui/cli)" $ do
      let src = mkMessageSource CkCli (ConversationId "cli") Nothing mempty
          si  = toSessionInfo (baseMeta (Just src)) Nothing
      _si_channel si `shouldBe` Just "cli"
      _si_channelUserId si `shouldBe` Nothing
    it "yields no channel or user id when there is no source" $ do
      let si = toSessionInfo (baseMeta Nothing) Nothing
      _si_channel si `shouldBe` Nothing
      _si_channelUserId si `shouldBe` Nothing
    it "serializes channel and channelUserId into the SessionInfo JSON" $ do
      let src = mkMessageSource CkSignal (ConversationId "+15551234567") (Just (UserId "+15551234567")) mempty
          v   = Aeson.toJSON (toSessionInfo (baseMeta (Just src)) Nothing)
      lookupKey v "channel" `shouldBe` Just (Aeson.String "signal")
      lookupKey v "channelUserId" `shouldBe` Just (Aeson.String "+15551234567")

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

    -- The sidebar's "age" pill reads _sm_lastActive. The gateway records
    -- transcript entries through a raw broadcasting handle (not a
    -- SessionHandle), so the touchLastActive bump never fires here — a
    -- completed /send must still advance _sm_lastActive past _sm_createdAt
    -- on disk, otherwise every session's pill is frozen at its start time.
    it "bumps _sm_lastActive on disk after a completion" $ do
      withSystemTempDirectory "pureclaw-send-lastactive" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeSessionBootstrap tmpDir "sess-la" Nothing True
        metaBefore <- readSessionMeta tmpDir "sess-la"
        env <- mkSendEnv tmpDir agentsDir Nothing
        _ <- sendOnce env "sess-la" "hello"
        metaAfter <- readSessionMeta tmpDir "sess-la"
        -- createdAt is untouched; lastActive advances past it.
        _sm_createdAt metaAfter `shouldBe` _sm_createdAt metaBefore
        (_sm_lastActive metaAfter > _sm_createdAt metaAfter) `shouldBe` True

  -- -----------------------------------------------------------------------
  -- POST /api/sessions/{sid}/send — harness routing (WU3, defect #2)
  -- -----------------------------------------------------------------------

  describe "POST /api/sessions/{sid}/send (harness routing — WU3)" $ do
    -- D3.1: an SkHarness session with a live handle registered under its
    -- key routes the message to the handle (not the provider) and returns
    -- the handle's sanitized output as the response.
    it "routes a harness session to its live tmux handle, not the provider" $ do
      withSystemTempDirectory "pureclaw-hsend-d31" $ \tmpDir -> do
        let sid = "sess-harness-1"
            key = "claude-code-0"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        fakeProv <- newFakeProvider
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "should-not-be-used"))
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "harness says hi"))
        let env = env0 { _fe_provider = provRef, _fe_model = modelRef }
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("ping" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "harness says hi")
        -- The harness handle received the bytes …
        sent <- readIORef sentRef
        sent `shouldBe` ["ping"]
        -- … and the provider was NOT invoked.
        recorded <- peekRecorded fakeProv
        recorded `shouldBe` []

    -- D3.2: regression — a provider session still hits the provider/model
    -- guard and runs doCompletion.
    it "still routes a provider session through doCompletion" $ do
      withSystemTempDirectory "pureclaw-hsend-d32" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeSessionBootstrap tmpDir "sess-prov" Nothing True
        se <- mkSendEnv tmpDir agentsDir Nothing
        recorded <- sendOnce se "sess-prov" "hello"
        length recorded `shouldBe` 1

    -- D3.3: an SkHarness session with NO handle registered returns a clear
    -- 503 "not running" — not a provider completion, not a 500.
    it "returns a clear 503 when the harness is not running" $ do
      withSystemTempDirectory "pureclaw-hsend-d33" $ \tmpDir -> do
        let sid = "sess-harness-down"
            key = "claude-code-7"
        writeHarnessSession tmpDir sid key
        fakeProv <- newFakeProvider
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "m"))
        let env = env0 { _fe_provider = provRef, _fe_model = modelRef }
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("ping" :: Text)]))
        st `shouldBe` HTTP.status503
        case lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "error" of
          Just (Aeson.String msg) ->
            msg `shouldSatisfy` T.isInfixOf "not running"
          _ -> expectationFailure "expected a string 'error' field"
        recorded <- peekRecorded fakeProv
        recorded `shouldBe` []

    -- D3.4: restart simulation — the persisted _tc_window key is recomputed
    -- and used to find the rediscovered handle.
    it "routes by the persisted tmux window key after a restart" $ do
      withSystemTempDirectory "pureclaw-hsend-d34" $ \tmpDir -> do
        let sid = "sess-harness-restart"
            key = "claude-code-3"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Simulate discoverHarnesses re-registering under the persisted key.
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "reconnected"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("after restart" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "reconnected")
        sent <- readIORef sentRef
        sent `shouldBe` ["after restart"]

    -- D3.5: a successful harness send records exactly one Request and one
    -- Response entry to the SESSION transcript (no duplicates).
    it "records exactly one Request and one Response entry per send" $ do
      withSystemTempDirectory "pureclaw-hsend-d35" $ \tmpDir -> do
        let sid = "sess-harness-tx"
            key = "claude-code-1"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "the reply"))
        (st, _) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("hi there" :: Text)]))
        st `shouldBe` HTTP.status200
        entries <- readSessionTranscript tmpDir sid
        let reqs  = [ e | e <- entries, _te_direction e == Request ]
            resps = [ e | e <- entries, _te_direction e == Response ]
        length reqs  `shouldBe` 1
        length resps `shouldBe` 1
        _te_payload (head reqs)  `shouldBe` "hi there"
        _te_payload (head resps) `shouldBe` "the reply"

    -- D3.5b (restart hardening): a restart-discovered handle records to its
    -- OWN (CLI) transcript — a different file. Prove the SESSION transcript
    -- still gets exactly one Request + one Response (handleSend is the sole
    -- writer of the session transcript; no cross-file duplication).
    it "keeps the session transcript at 1+1 when the handle records elsewhere" $ do
      withSystemTempDirectory "pureclaw-hsend-d35b" $ \tmpDir -> do
        let sid = "sess-harness-restart"
            key = "claude-code-7"
            cliTranscript = tmpDir </> "cli-transcript.jsonl"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkRecordingFakeHarnessHandle cliTranscript sentRef "restart reply"))
        (st, _) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("after restart" :: Text)]))
        st `shouldBe` HTTP.status200
        -- Session transcript: exactly one Request + one Response.
        entries <- readSessionTranscript tmpDir sid
        length [ e | e <- entries, _te_direction e == Request ]  `shouldBe` 1
        length [ e | e <- entries, _te_direction e == Response ] `shouldBe` 1
        -- The handle's own (separate) transcript received its 2 lines —
        -- proving the second recorder writes to a DIFFERENT file, not the
        -- session transcript.
        cliRaw <- LBS.readFile cliTranscript
        length (filter (not . LBS.null) (LBS.split 0x0a cliRaw)) `shouldBe` 2

    -- D3.6: harness routing must work even when no provider/model are
    -- configured (the provider guard must not pre-empt the kind branch).
    it "routes a harness session with no provider/model configured" $ do
      withSystemTempDirectory "pureclaw-hsend-d36" $ \tmpDir -> do
        let sid = "sess-harness-noprov"
            key = "claude-code-2"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- _fe_provider and _fe_model are Nothing by default in the test env.
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "no-provider reply"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("hello" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "no-provider reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["hello"]

    -- D3.7: a blank/whitespace harness reply yields 200 {"response":""}
    -- with NO Response entry written (only the Request entry).
    it "writes no Response entry when the harness reply is blank" $ do
      withSystemTempDirectory "pureclaw-hsend-d37" $ \tmpDir -> do
        let sid = "sess-harness-blank"
            key = "claude-code-4"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "   \n  "))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("anyone there?" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "")
        entries <- readSessionTranscript tmpDir sid
        let reqs  = [ e | e <- entries, _te_direction e == Request ]
            resps = [ e | e <- entries, _te_direction e == Response ]
        length reqs  `shouldBe` 1
        resps `shouldBe` []

    -- D3.8 (WU4 coverage): when the harness handle throws during
    -- send/receive (e.g. tmux IO failure), 'sendToHarness' catches it,
    -- logs, and responds 500 {"error":"Harness send failed"} — never a
    -- crash, never a silent provider fallback.
    it "responds 500 when the harness handle throws during send/receive" $ do
      withSystemTempDirectory "pureclaw-hsend-d38" $ \tmpDir -> do
        let sid = "sess-harness-throw"
            key = "claude-code-9"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkThrowingHarnessHandle sentRef))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("will throw" :: Text)]))
        st `shouldBe` HTTP.status500
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "error"
          `shouldBe` Just (Aeson.String "Harness send failed")
        -- The send was attempted (bytes reached the handle) before the throw.
        sent <- readIORef sentRef
        sent `shouldBe` ["will throw"]

  -- -----------------------------------------------------------------------
  -- Task 7: slash-command short-circuit in handleSend
  -- -----------------------------------------------------------------------
  describe "POST /api/sessions/{sid}/send (slash short-circuit — Task 7)" $ do
    -- 1. /help is handled by the shared slash dispatch: kind "slash", a
    --    non-empty response, the provider is NEVER called, and no Request/
    --    Response transcript entries are appended.
    it "handles /help without calling the provider or touching the transcript" $ do
      withSystemTempDirectory "pureclaw-slash-help" $ \tmpDir -> do
        let sid = "sess-slash-help"
        writeTestSession tmpDir sid False
        linesBefore <- transcriptLineCount tmpDir sid
        fakeProv <- newFakeProvider
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "should-not-be-used"))
        let env = env0 { _fe_provider = provRef, _fe_model = modelRef }
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/help" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        case lookupKey' respBody "response" of
          Just (Aeson.String txt) -> T.null txt `shouldBe` False
          _ -> expectationFailure "expected a string 'response' field"
        -- The provider was never invoked.
        recorded <- peekRecorded fakeProv
        recorded `shouldBe` []
        -- No transcript entries were appended.
        linesAfter <- transcriptLineCount tmpDir sid
        linesAfter `shouldBe` linesBefore

    -- 2. /status short-circuits even when no provider/model is configured on
    --    the shared base env — the dispatch precedes the provider guard, so
    --    there is no 503.
    it "handles /status without a 503 even when no provider is configured" $ do
      withSystemTempDirectory "pureclaw-slash-status" $ \tmpDir -> do
        let sid = "sess-slash-status"
        writeTestSession tmpDir sid False
        -- _fe_provider / _fe_model AND the shared _fe_agentEnv default to
        -- Nothing in the test env, so a 503 would mean the guard ran first.
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/status" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")

    -- 3. A plain message reaches the provider and is tagged kind "assistant".
    it "routes a plain message to the provider and tags it kind assistant" $ do
      withSystemTempDirectory "pureclaw-slash-plain" $ \tmpDir -> do
        let sid = "sess-slash-plain"
        writeTestSession tmpDir sid False
        fakeProv <- newFakeProvider
        queueResponse fakeProv CompletionResponse
          { _crsp_content = [TextBlock "canned answer"]
          , _crsp_model   = ModelId "claude-sonnet-4-20250514"
          , _crsp_usage   = Nothing
          }
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "claude-sonnet-4-20250514"))
        let env = env0 { _fe_provider = provRef, _fe_model = modelRef }
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("hello" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "assistant")
        lookupKey' respBody "response" `shouldBe` Just (Aeson.String "canned answer")
        recorded <- peekRecorded fakeProv
        length recorded `shouldBe` 1

    -- 4. A harness session + /help: the slash dispatch short-circuits BEFORE
    --    the harness branch, so the response is the slash help text and NO
    --    keystrokes are relayed to the harness handle.
    it "handles /help on a harness session without relaying keystrokes" $ do
      withSystemTempDirectory "pureclaw-slash-harness" $ \tmpDir -> do
        let sid = "sess-slash-harness"
            key = "claude-code-0"
        writeHarnessSession tmpDir sid key
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert key (mkFakeHarnessHandle sentRef "harness echo"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/help" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        -- It is the slash help text, NOT the harness echo.
        lookupKey' respBody "response"
          `shouldNotBe` Just (Aeson.String "harness echo")
        -- No keystrokes reached the harness handle.
        sent <- readIORef sentRef
        sent `shouldBe` []

    -- 5. Unknown / unrecognised slash forms short-circuit with kind "slash"
    --    and never call the provider.
    it "short-circuits /0 and /foo with kind slash and no provider call" $ do
      withSystemTempDirectory "pureclaw-slash-unknown" $ \tmpDir -> do
        let sid = "sess-slash-unknown"
        writeTestSession tmpDir sid False
        fakeProv <- newFakeProvider
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        provRef  <- newIORef (Just (MkProvider fakeProv))
        modelRef <- newIORef (Just (ModelId "should-not-be-used"))
        let env = env0 { _fe_provider = provRef, _fe_model = modelRef }
        let postSlash raw = postJSON env ["api", "sessions", sid, "send"]
              (Aeson.encode (object ["message" .= (raw :: Text)]))
        (st0, body0) <- postSlash "/0"
        st0 `shouldBe` HTTP.status200
        lookupKey' body0 "kind" `shouldBe` Just (Aeson.String "slash")
        (stF, bodyF) <- postSlash "/foo"
        stF `shouldBe` HTTP.status200
        lookupKey' bodyF "kind" `shouldBe` Just (Aeson.String "slash")
        recorded <- peekRecorded fakeProv
        recorded `shouldBe` []

    -- 6. /vault setup is a recognised command that needs interactive input;
    --    against the capture channel it surfaces the deferral message
    --    containing both "interactive" and the tracking "/issues/" URL.
    it "defers /vault setup with an interactive-unsupported message" $ do
      withSystemTempDirectory "pureclaw-slash-vault" $ \tmpDir -> do
        let sid = "sess-slash-vault"
        writeTestSession tmpDir sid False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/vault setup" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        case lookupKey' respBody "response" of
          Just (Aeson.String txt) -> do
            ("interactive" `T.isInfixOf` txt) `shouldBe` True
            ("/issues/" `T.isInfixOf` txt) `shouldBe` True
          _ -> expectationFailure "expected a string 'response' field"

    -- 7. Two distinct sessions each get their own freshly-scoped session ref
    --    per request: /status to each responds independently with kind "slash".
    it "scopes the session per request across two distinct sids" $ do
      withSystemTempDirectory "pureclaw-slash-iso" $ \tmpDir -> do
        let sidA = "sess-slash-a"
            sidB = "sess-slash-b"
        writeTestSession tmpDir sidA False
        writeTestSession tmpDir sidB False
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (stA, bodyA) <- postJSON env ["api", "sessions", sidA, "send"]
          (Aeson.encode (object ["message" .= ("/status" :: Text)]))
        stA `shouldBe` HTTP.status200
        lookupKey' bodyA "kind" `shouldBe` Just (Aeson.String "slash")
        (stB, bodyB) <- postJSON env ["api", "sessions", sidB, "send"]
          (Aeson.encode (object ["message" .= ("/status" :: Text)]))
        stB `shouldBe` HTTP.status200
        lookupKey' bodyB "kind" `shouldBe` Just (Aeson.String "slash")

  -- -----------------------------------------------------------------------
  -- Task D: a web @/tab@ command, sent over the HTTP send endpoint, mutates
  -- the SHARED 'TabRegistry' end to end. This closes the gap left by the
  -- earlier tasks: those proved the dispatcher seam was wired into
  -- 'executeSlashCommand', but no test exercised the PRODUCTION-equivalent
  -- wiring ('mkRunTabCommandSeam' over deps whose '_td_tabs' is the registry
  -- the frontend exposes) all the way from the HTTP body to a registry
  -- mutation + the captured dispatcher reply.
  --
  -- The shared default test env wires '_env_runTabCommand = noRunTabCommand'
  -- (a no-op), so each test here builds a bespoke env whose '_fe_agentEnv'
  -- shares ONE 'TabRegistry'/cursors/exec with the 'FrontendEnv' and whose
  -- '_env_runTabCommand' is the real 'mkRunTabCommandSeam' over deps built on
  -- that same env (exactly how "PureClaw.CLI.Commands" wires production).
  describe "POST /api/sessions/{sid}/send (web /tab mutates the shared registry — Task D)" $ do
    it "renames slot 0 in the shared TabRegistry and returns the dispatcher reply" $ do
      withSystemTempDirectory "pureclaw-webtab-rename" $ \tmpDir -> do
        let sid = "20240101-000000-001"
        writeTestSession tmpDir sid False
        (env, tabReg) <- mkWebTabSeamEnv tmpDir
        -- Seed a tab at slot 0 in the SHARED registry, bound to the on-disk
        -- session so the rename's description write is observable.
        _ <- registryAppend tabReg (BoundSession (SessionId sid))
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/tab rename 0 newname" :: Text)]))
        st `shouldBe` HTTP.status200
        -- (a) The slash short-circuit fired and surfaced the dispatcher reply.
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        case lookupKey' respBody "response" of
          Just (Aeson.String txt) -> ("renamed" `T.isInfixOf` txt) `shouldBe` True
          _ -> expectationFailure "expected a string 'response' field"
        -- (b) Rename now sets the SESSION's canonical description (cross-process).
        -- Tabs carry no label of their own, so the tab is untouched (its binding
        -- is unchanged) and session.json now carries the new description.
        slot0 <- registryLookupSlot tabReg
                   (fromMaybe (error "mkTabIndex 0") (mkTabIndex 0))
        fmap _tab_ref slot0 `shouldBe` Just (BoundSession (SessionId sid))
        Right onDisk <- Aeson.eitherDecodeFileStrict'
          (tmpDir </> T.unpack sid </> "session.json")
            :: IO (Either String SessionMeta)
        _sm_description onDisk `shouldBe` Just "newname"

    it "closes slot 0 in the shared TabRegistry and returns the dispatcher reply" $ do
      withSystemTempDirectory "pureclaw-webtab-close" $ \tmpDir -> do
        let sid = "20240101-000000-002"
        writeTestSession tmpDir sid False
        (env, tabReg) <- mkWebTabSeamEnv tmpDir
        _ <- registryAppend tabReg (BoundSession (SessionId "s-doomed"))
        -- Sanity: the seeded tab is present before the command.
        seeded <- readTabs tabReg
        length (toList seeded) `shouldBe` 1
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("/tab close 0" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey' respBody "kind" `shouldBe` Just (Aeson.String "slash")
        case lookupKey' respBody "response" of
          Just (Aeson.String txt) -> ("closed" `T.isInfixOf` txt) `shouldBe` True
          _ -> expectationFailure "expected a string 'response' field"
        -- The slot is gone from the SHARED registry.
        slot0 <- registryLookupSlot tabReg
                   (fromMaybe (error "mkTabIndex 0") (mkTabIndex 0))
        slot0 `shouldBe` Nothing
        remaining <- readTabs tabReg
        length (toList remaining) `shouldBe` 0

  -- -----------------------------------------------------------------------
  -- WU6: id-primary routing with name fallback + PID-corroboration refusal
  -- -----------------------------------------------------------------------
  describe "POST /api/sessions/{sid}/send (id-primary routing — WU6)" $ do
    -- D6.3: a session persisting a HarnessId routes by id to a corroborated
    -- registry entry's handle (not via the name-keyed map).
    it "routes by HarnessId to a corroborated registry entry's handle (D6.3)" $ do
      withSystemTempDirectory "pureclaw-wu6-d63" $ \tmpDir -> do
        let sid    = "sess-id-route"
            hidTxt = "66666666-6666-4666-8666-666666666666"
            hid    = mustParseHid hidTxt
            window = "claude-code-0"
        writeHarnessSessionWithId tmpDir sid window (Just hidTxt)
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- A corroborated entry (recorded harness PID) with a live handle, keyed
        -- by the id. The legacy name map is EMPTY so a pass means id-routing.
        Registry.insertEntry (_fe_harnessRegistry env0)
          (corroboratedEntry hid window
            (Just (mkFakeHarnessHandle sentRef "id-routed reply")))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("ping" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "id-routed reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["ping"]

    -- WU8 Part B (WU4-review): an ADOPTED harness's output must flow exactly like
    -- a SPAWNED one. 'harnessKeyFromKind' returns the adopted entry's id;
    -- 'sendToHarness' routes by id to the PID-corroborated OriginAdopted entry's
    -- handle; and 'routeViaHandle' is the SOLE recorder of the session
    -- transcript (the adopted handle, like the spawned one, was given a no-op
    -- transcript). This proves a send to an adopted harness records exactly one
    -- Request + one Response to the SESSION transcript — adoption is consistent
    -- with the spawn-via-frontend path.
    it "records a send to an ADOPTED harness to the session transcript (WU8 Part B)" $ do
      withSystemTempDirectory "pureclaw-wu8-partb" $ \tmpDir -> do
        let sid    = "sess-adopted-route"
            hidTxt = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
            hid    = mustParseHid hidTxt
            window = "adopted-window-0"
        writeHarnessSessionWithId tmpDir sid window (Just hidTxt)
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- An OriginAdopted, PID-corroborated entry with a live handle, keyed by
        -- id. The legacy name map is EMPTY so a pass means id-routing to the
        -- adopted entry (not a name-fallback).
        Registry.insertEntry (_fe_harnessRegistry env0)
          (adoptedCorroboratedEntry hid window
            (Just (mkFakeHarnessHandle sentRef "adopted reply")))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("hello adopted" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "adopted reply")
        -- The keystrokes reached the adopted handle.
        sent <- readIORef sentRef
        sent `shouldBe` ["hello adopted"]
        -- handleSend recorded exactly one Request + one Response to the SESSION
        -- transcript (sole recorder — no double-write from the adopted handle,
        -- whose own transcript is a no-op, mirroring the spawn path).
        entries <- readSessionTranscript tmpDir sid
        let reqs  = [ e | e <- entries, _te_direction e == Request ]
            resps = [ e | e <- entries, _te_direction e == Response ]
        length reqs  `shouldBe` 1
        length resps `shouldBe` 1
        _te_payload (head reqs)  `shouldBe` "hello adopted"
        _te_payload (head resps) `shouldBe` "adopted reply"

    -- D6.4: id not in the registry -> falls back to the legacy name-keyed
    -- _fe_harnesses map (the PR #74 path). Proves the name fallback survives.
    it "falls back to the name-keyed map when the id is unregistered (D6.4)" $ do
      withSystemTempDirectory "pureclaw-wu6-d64" $ \tmpDir -> do
        let sid    = "sess-id-fallback"
            hidTxt = "77777777-7777-4777-8777-777777777777"
            window = "claude-code-1"
        writeHarnessSessionWithId tmpDir sid window (Just hidTxt)
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Registry is EMPTY for this id; register a live handle under the
        -- window NAME (the legacy PR #74 wiring).
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "name-fallback reply"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("hi" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "name-fallback reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["hi"]

    -- D6.4b: a fully-legacy session (no harnessId at all) routes via the name
    -- map exactly as in PR #74. This is the dominant case until WU4/5/7 land.
    it "routes a legacy (no-id) session via the name map unchanged (D6.4)" $ do
      withSystemTempDirectory "pureclaw-wu6-d64b" $ \tmpDir -> do
        let sid    = "sess-legacy"
            window = "claude-code-2"
        writeHarnessSessionWithId tmpDir sid window Nothing
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "legacy reply"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("legacy hi" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "legacy reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["legacy hi"]

    -- D6.6 (§8 C4): the id resolves to a registry entry that is NOT
    -- PID-corroborated (a spoofed/uncorroborated marker). sendToHarness must
    -- REFUSE — respond 503, log a refusal, and NEVER send keystrokes. It must
    -- NOT silently fall back to the name map for this spoof case.
    it "refuses to route to an uncorroborated registry entry (D6.6)" $ do
      withSystemTempDirectory "pureclaw-wu6-d66" $ \tmpDir -> do
        let sid    = "sess-spoof"
            hidTxt = "88888888-8888-4888-8888-888888888888"
            hid    = mustParseHid hidTxt
            window = "claude-code-3"
        writeHarnessSessionWithId tmpDir sid window (Just hidTxt)
        sentRef <- newIORef []
        logRef  <- newIORef ([] :: [Text])
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- Uncorroborated entry: NO recorded PIDs, but it DOES carry a (would-be
        -- spoofed) live handle. A registered handle under the NAME must NOT
        -- rescue it — the spoof path refuses outright.
        Registry.insertEntry (_fe_harnessRegistry env0)
          (uncorroboratedEntry hid window
            (Just (mkFakeHarnessHandle sentRef "SHOULD NOT SEND")))
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "SHOULD NOT NAME-FALLBACK"))
        let env = env0 { _fe_logger = captureErrorLogger logRef }
        (st, respBody) <- postJSON env ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("spoofed" :: Text)]))
        st `shouldBe` HTTP.status503
        -- No keystrokes reached any handle.
        sent <- readIORef logRef >> readIORef sentRef
        sent `shouldBe` []
        -- A refusal was logged.
        logs <- readIORef logRef
        any (T.isInfixOf "corroborat") logs `shouldBe` True
        -- The error body mentions a refusal, not "not running".
        case lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "error" of
          Just (Aeson.String msg) ->
            (T.isInfixOf "corroborat" msg || T.isInfixOf "refus" msg) `shouldBe` True
          _ -> expectationFailure "expected a string 'error' field"

    -- D6.6b: a corroborated entry whose handle is Nothing (e.g. boot-discovered
    -- but not yet attached) falls through to the name path rather than refusing.
    it "falls through to name path when a corroborated entry has no handle (D6.5/D6.6)" $ do
      withSystemTempDirectory "pureclaw-wu6-d66b" $ \tmpDir -> do
        let sid    = "sess-nohandle"
            hidTxt = "99999999-9999-4999-8999-999999999999"
            hid    = mustParseHid hidTxt
            window = "claude-code-4"
        writeHarnessSessionWithId tmpDir sid window (Just hidTxt)
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        Registry.insertEntry (_fe_harnessRegistry env0)
          (corroboratedEntry hid window Nothing)  -- corroborated, no handle
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "name-path reply"))
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("fallthrough" :: Text)]))
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "name-path reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["fallthrough"]

    -- D6.5: lazy back-fill. A legacy (no-id) session whose window name matches
    -- a corroborated registry entry by label persists that entry's HarnessId
    -- into session.json on first matched send.
    it "back-fills the HarnessId into session.json on first legacy match (D6.5)" $ do
      withSystemTempDirectory "pureclaw-wu6-d65" $ \tmpDir -> do
        let sid    = "sess-backfill"
            hidTxt = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            hid    = mustParseHid hidTxt
            window = "claude-code-5"
        writeHarnessSessionWithId tmpDir sid window Nothing  -- legacy, no id
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- A corroborated entry whose LABEL matches the window name.
        Registry.insertEntry (_fe_harnessRegistry env0)
          (corroboratedEntry hid window
            (Just (mkFakeHarnessHandle sentRef "matched")))
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "matched"))
        (st, _) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("first" :: Text)]))
        st `shouldBe` HTTP.status200
        -- session.json now carries the back-filled HarnessId.
        reloaded <- tryLoadMetaJson tmpDir sid
        harnessIdOfMeta reloaded `shouldBe` Just hidTxt

    -- D6.5(c): the lazy back-fill is best-effort and must NEVER fail a send.
    -- Here the back-fill's atomic write is forced to throw: we pre-create the
    -- back-fill's tmp target (@session.json.backfill.tmp@) as a DIRECTORY, so
    -- the back-fill's @LBS.writeFile@ into it fails with an IO error. The
    -- harness send itself still succeeds, so the request MUST return 200 with
    -- the harness reply and the keystrokes MUST have been delivered. Against
    -- the unguarded implementation the back-fill exception propagates out of
    -- 'handleSend' and aborts the send before any assertion can hold.
    --
    -- Note the tmp target is deliberately distinct from the
    -- @session.json.tmp@ used by 'touchSessionLastActive', so this fault
    -- isolates the back-fill and does not perturb the unrelated last-active
    -- mutator (which runs in the same success branch).
    it "never fails the send when the back-fill write throws (D6.5c)" $ do
      withSystemTempDirectory "pureclaw-wu6-d65c" $ \tmpDir -> do
        let sid    = "sess-backfill-fail"
            hidTxt = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            hid    = mustParseHid hidTxt
            window = "claude-code-6"
            sessDir = tmpDir </> T.unpack sid
        writeHarnessSessionWithId tmpDir sid window Nothing  -- legacy, no id
        sentRef <- newIORef []
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        -- A corroborated entry whose LABEL matches the window name, so the
        -- back-fill is attempted (read succeeds; the subsequent write throws).
        Registry.insertEntry (_fe_harnessRegistry env0)
          (corroboratedEntry hid window
            (Just (mkFakeHarnessHandle sentRef "matched")))
        modifyIORef' (_fe_harnesses env0)
          (Map.insert window (mkFakeHarnessHandle sentRef "matched"))
        -- Occupy the back-fill's tmp target with a DIRECTORY so its
        -- @LBS.writeFile session.json.backfill.tmp@ throws.
        createDirectoryIfMissing True (sessDir </> "session.json.backfill.tmp")
        (st, respBody) <- postJSON env0 ["api", "sessions", sid, "send"]
          (Aeson.encode (object ["message" .= ("first" :: Text)]))
        -- The send succeeded despite the throwing back-fill.
        st `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode respBody)) "response"
          `shouldBe` Just (Aeson.String "matched")
        -- The keystrokes were delivered.
        sent <- readIORef sentRef
        sent `shouldBe` ["first"]
        -- The id was NOT back-filled (the write threw), but the session.json
        -- is intact (the failing tmp write left the original in place).
        reloaded <- tryLoadMetaJson tmpDir sid
        harnessIdOfMeta reloaded `shouldBe` Nothing

  -- -----------------------------------------------------------------------
  -- WU7: _fe_startHarness honors _tc_session; createHarnessTab persists the id
  -- -----------------------------------------------------------------------

  describe "resolveHarnessSession (WU7 — D7.3)" $ do
    -- D7.3: a spec with an empty tmux session (the New-Harness composer omits
    -- the session when the user leaves it blank) resolves to the default
    -- "pureclaw".
    it "defaults to \"pureclaw\" when the spec has no tmux session (D7.3)" $
      resolveHarnessSession (harnessSpecWithTmux (TmuxConfig "" "" Nothing))
        `shouldBe` "pureclaw"

    -- D7.3: an empty _tc_session is treated as unspecified -> default.
    it "treats an empty _tc_session as unspecified (D7.3)" $
      resolveHarnessSession
        (harnessSpecWithTmux (TmuxConfig "" "w" Nothing))
        `shouldBe` "pureclaw"

    -- D7.3: a spec specifying a non-empty _tc_session is honored verbatim.
    it "honors a non-empty _tc_session (D7.3)" $
      resolveHarnessSession
        (harnessSpecWithTmux (TmuxConfig "my-proj" "w" Nothing))
        `shouldBe` "my-proj"

  describe "POST /api/tabs/new (harness id persistence — WU7)" $ do
    -- D7.1: a frontend-created harness registers a HarnessId entry in the shared
    -- registry. The fake _fe_startHarness seeds a corroborated entry keyed by the
    -- id (as the real spawn path does via startHarnessByName); we assert the
    -- registry carries it after the create flows end-to-end through createHarnessTab.
    it "registers a HarnessId entry in the shared registry (D7.1)" $ do
      withSystemTempDirectory "pureclaw-wu7-d71" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        sentRef <- newIORef []
        let env = env0
              { _fe_startHarness =
                  fakeStartHarnessWith (_fe_harnesses env0) "claude-code-0"
                    fakeStartedHid (Just (_fe_harnessRegistry env0, sentRef)) }
        (st, _) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        mEntry <- Registry.lookupById (_fe_harnessRegistry env) fakeStartedHid
        case mEntry of
          Just _  -> pure ()
          Nothing -> expectationFailure
            "expected the frontend-created harness id in the registry"

    -- Bugfix: a harness created via the web form gets its own session, but the
    -- low-level spawn (startHarnessByName) inserts the registry entry with
    -- _he_sessionId = Nothing. createHarnessTab must link the entry back to the
    -- session it created (as the adopt path already does), otherwise the tab's
    -- session_id is null and the right pane shows "No session associated yet".
    it "links the spawned harness registry entry to the created session" $ do
      withSystemTempDirectory "pureclaw-link-sess" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        sentRef <- newIORef []
        let env = env0
              { _fe_startHarness =
                  fakeStartHarnessWith (_fe_harnesses env0) "claude-code-0"
                    fakeStartedHid (Just (_fe_harnessRegistry env0, sentRef)) }
        (st, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        mEntry <- Registry.lookupById (_fe_harnessRegistry env) fakeStartedHid
        case mEntry of
          Just e  -> Registry._he_sessionId e `shouldBe` Just newSid
          Nothing -> expectationFailure
            "expected the spawned harness entry in the registry"

    -- D7.2: the persisted session.json carries BOTH the harnessId (Just) AND
    -- the resolved _tc_session. Read both back from disk and assert.
    it "persists BOTH harnessId and _tc_session into session.json (D7.2)" $ do
      withSystemTempDirectory "pureclaw-wu7-d72" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  fakeStartHarness (_fe_harnesses env0) "claude-code-0" }
        (st, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        -- harnessId read back from the raw persisted JSON.
        rawMeta <- tryLoadMetaJson tmpDir newSid
        harnessIdOfMeta rawMeta
          `shouldBe` Just (Registry.harnessIdToText fakeStartedHid)
        -- _tc_session read back from the decoded meta (default "pureclaw").
        meta <- readSessionMeta tmpDir newSid
        case _sm_kind meta of
          SkHarness hs -> do
            _h_harnessId hs `shouldBe` Just fakeStartedHid
            _tc_session (_h_tmux hs) `shouldBe` "pureclaw"
          other -> expectationFailure ("expected SkHarness, got " <> show other)

    -- D7.3 (end-to-end): a request specifying a custom _tc_session is honored —
    -- the persisted session.json carries that session, not the default.
    it "honors a request-specified _tc_session end-to-end (D7.3)" $ do
      withSystemTempDirectory "pureclaw-wu7-d73e" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        let env = env0
              { _fe_startHarness =
                  fakeStartHarness (_fe_harnesses env0) "claude-code-0" }
        (st, respBody) <- postJSON env ["api", "tabs", "new"]
          (harnessNewTabBodyWithSession "my-proj")
        st `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        meta <- readSessionMeta tmpDir newSid
        case _sm_kind meta of
          SkHarness hs -> _tc_session (_h_tmux hs) `shouldBe` "my-proj"
          other -> expectationFailure ("expected SkHarness, got " <> show other)

    -- D7.4: first-prompt routing still works via the persisted id. After
    -- createHarnessTab persists the id and registers a corroborated registry
    -- entry, a POST /api/sessions/<sid>/send resolves the persisted id through
    -- the registry to the corroborated entry's handle (keystrokes reach it).
    it "routes a post-create send via the persisted id through the registry (D7.4)" $ do
      withSystemTempDirectory "pureclaw-wu7-d74" $ \tmpDir -> do
        env0 <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        sentRef <- newIORef []
        -- The legacy name map is EMPTY; the only live handle is the registry
        -- entry keyed by the id. A successful send therefore PROVES id-routing.
        let env = env0
              { _fe_startHarness =
                  fakeStartHarnessWith (_fe_harnesses env0) "claude-code-0"
                    fakeStartedHid (Just (_fe_harnessRegistry env0, sentRef)) }
        (stCreate, respBody) <- postJSON env ["api", "tabs", "new"] harnessNewTabBody
        stCreate `shouldBe` HTTP.status200
        newSid <- decodeSessionId respBody
        (stSend, sendResp) <- postJSON env ["api", "sessions", newSid, "send"]
          (Aeson.encode (object ["message" .= ("first prompt" :: Text)]))
        stSend `shouldBe` HTTP.status200
        lookupKey (fromMaybe Aeson.Null (Aeson.decode sendResp)) "response"
          `shouldBe` Just (Aeson.String "id-routed reply")
        sent <- readIORef sentRef
        sent `shouldBe` ["first prompt"]

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
    it "closes a BoundSession tab at the slot and removes it (WU7)" $ do
      env <- mkTestFrontendEnv
      let sid = SessionId "test-20240101-120000-c01"
      _ <- registryAppend (_fe_tabRegistry env) (BoundSession sid)
      (st, respBody) <- postJSON env ["api", "tabs", "0", "close"] ""
      st `shouldBe` HTTP.status200
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "closed" `shouldBe` Just (Aeson.Bool True)
      tabs <- toList <$> readTabs (_fe_tabRegistry env)
      [ t | t <- tabs, _tab_ref t == BoundSession sid ] `shouldBe` []

    it "returns 404 when no tab occupies the slot (WU7)" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- postJSON env ["api", "tabs", "5", "close"] ""
      st `shouldBe` HTTP.status404
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "error" `shouldBe` Just (Aeson.String "No tab at index 5")

    it "returns 400 for non-numeric tab index" $ do
      env <- mkTestFrontendEnv
      (st, respBody) <- postJSON env ["api", "tabs", "abc", "close"] ""
      st `shouldBe` HTTP.status400
      case Aeson.decode respBody of
        Nothing -> expectationFailure "Could not decode response JSON"
        Just val -> lookupKey val "error" `shouldBe` Just (Aeson.String "Invalid tab index")

    it "closing a BoundHarness tab deregisters it without killing the window (WU7)" $ do
      killedRef <- newIORef (False :: Bool)
      env0 <- mkTestFrontendEnv
      let env = env0 { _fe_killWindow = \_ _ -> writeIORef killedRef True }
          hid = mustParseHid "33333333-3333-4333-8333-333333333333"
      seedHarnessTab env (baseEntry hid "claude-code-0" Nothing)
      (st, _) <- postJSON env ["api", "tabs", "0", "close"] ""
      st `shouldBe` HTTP.status200
      -- The tab is gone and the harness entry was deregistered.
      tabs <- toList <$> readTabs (_fe_tabRegistry env)
      tabs `shouldBe` []
      gone <- Registry.lookupById (_fe_harnessRegistry env) hid
      (Registry._he_id <$> gone) `shouldBe` Nothing
      -- Close never kills the window.
      readIORef killedRef `shouldReturn` False

  -- -----------------------------------------------------------------------
  -- WU7 — frontend tab endpoints drive the TabRegistry
  -- -----------------------------------------------------------------------
  describe "WU7 — frontend tab endpoints drive the TabRegistry" $ do
    it "handleNewTab (provider) appends a BoundSession to the registry and returns its slot+sid" $
      withSystemTempDirectory "pureclaw-wu7-newtab" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, respBody) <- postJSON env ["api", "tabs", "new"] providerNewTabBody
        st `shouldBe` HTTP.status200
        slot <- case lookupKey' respBody "tab_index" of
          Just (Aeson.Number n) -> pure (round n :: Int)
          _ -> expectationFailure "expected tab_index number" >> pure (-1)
        sid <- case lookupKey' respBody "session_id" of
          Just (Aeson.String s) -> pure s
          _ -> expectationFailure "expected session_id string" >> pure ""
        -- The registry now holds a BoundSession tab at the returned slot.
        tabs <- toList <$> readTabs (_fe_tabRegistry env)
        case [ t | t <- tabs, _tab_ref t == BoundSession (SessionId sid) ] of
          [t] -> unTabIndex (_tab_slot t) `shouldBe` slot
          _   -> expectationFailure "expected exactly one BoundSession tab for the new sid"

    it "close resolves the registry slot and removes the tab (any kind)" $ do
      env <- mkTestFrontendEnv
      let sid = SessionId "test-20240101-120000-777"
      _ <- registryAppend (_fe_tabRegistry env) (BoundSession sid)
      -- Slot 0 now holds the BoundSession tab.
      (st, _) <- postJSON env ["api", "tabs", "0", "close"] ""
      st `shouldBe` HTTP.status200
      tabs <- toList <$> readTabs (_fe_tabRegistry env)
      [ t | t <- tabs, _tab_ref t == BoundSession sid ] `shouldBe` []

    it "dismiss on a BoundSession (non-harness) tab returns 4xx 'not a harness tab'" $ do
      env <- mkTestFrontendEnv
      let sid = SessionId "test-20240101-120000-888"
      _ <- registryAppend (_fe_tabRegistry env) (BoundSession sid)
      (st, respBody) <- postJSON env ["api", "tabs", "0", "dismiss"] "{}"
      HTTP.statusCode st `shouldSatisfy` (\c -> c >= 400 && c < 500)
      lookupKey' respBody "error" `shouldBe` Just (Aeson.String "not a harness tab")

    it "create beyond _fe_maxTabs returns the cap 4xx and does not append" $ do
      env <- mkTestFrontendEnvWith 1   -- maxTabs = 1
      -- Fill the single slot.
      _ <- registryAppend (_fe_tabRegistry env)
             (BoundSession (SessionId "test-20240101-120000-aaa"))
      lenBefore <- length . toList <$> readTabs (_fe_tabRegistry env)
      (st, respBody) <- postJSON env ["api", "tabs", "new"] providerNewTabBody
      HTTP.statusCode st `shouldSatisfy` (\c -> c >= 400 && c < 500)
      lookupKey' respBody "error" `shouldBe` Just (Aeson.String "maximum tab count reached")
      lenAfter <- length . toList <$> readTabs (_fe_tabRegistry env)
      lenAfter `shouldBe` lenBefore

  describe "PUT /api/sessions/{sid}/prompt (custom-prompt ⊕ agent — WU6)" $ do
    -- C1: after set-prompt, session.json has _sm_agent == Nothing.
    it "clears _sm_agent when a custom prompt is set (C1)" $ do
      withSystemTempDirectory "pureclaw-wu6-c1" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-c1" (Just "myagent") True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-c1", "prompt"]
          (Aeson.encode (object ["prompt" .= ("MY CUSTOM PROMPT" :: Text)]))
        st `shouldBe` HTTP.status200
        meta <- readSessionMeta tmpDir "sess-c1"
        _sm_agent meta `shouldBe` Nothing
        -- And the prompt file was written.
        prompt <- TIO.readFile (tmpDir </> "sess-c1" </> "custom-prompt.md")
        prompt `shouldBe` "MY CUSTOM PROMPT"

    -- C2: a provided name lands in _sm_description (NOT as the agent).
    it "stores a provided name in _sm_description, not as the agent (C2)" $ do
      withSystemTempDirectory "pureclaw-wu6-c2" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-c2" (Just "oldagent") True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-c2", "prompt"]
          (Aeson.encode (object
            [ "prompt" .= ("CUSTOM" :: Text)
            , "name"   .= ("My Friendly Title" :: Text)
            ]))
        st `shouldBe` HTTP.status200
        meta <- readSessionMeta tmpDir "sess-c2"
        _sm_description meta `shouldBe` Just "My Friendly Title"
        _sm_agent meta `shouldBe` Nothing

    -- C3: non-prompt metadata fields are unchanged by set-prompt.
    it "leaves non-prompt metadata fields unchanged (C3)" $ do
      withSystemTempDirectory "pureclaw-wu6-c3" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-c3" (Just "myagent") True
        metaBefore <- readSessionMeta tmpDir "sess-c3"
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-c3", "prompt"]
          (Aeson.encode (object ["prompt" .= ("CUSTOM" :: Text)]))
        st `shouldBe` HTTP.status200
        metaAfter <- readSessionMeta tmpDir "sess-c3"
        _sm_id metaAfter                `shouldBe` _sm_id metaBefore
        _sm_kind metaAfter              `shouldBe` _sm_kind metaBefore
        _sm_model metaAfter             `shouldBe` _sm_model metaBefore
        _sm_channel metaAfter           `shouldBe` _sm_channel metaBefore
        _sm_createdAt metaAfter         `shouldBe` _sm_createdAt metaBefore
        _sm_lastActive metaAfter        `shouldBe` _sm_lastActive metaBefore
        _sm_bootstrapConsumed metaAfter `shouldBe` _sm_bootstrapConsumed metaBefore
        _sm_archived metaAfter          `shouldBe` _sm_archived metaBefore
        _sm_autoSummary metaAfter       `shouldBe` _sm_autoSummary metaBefore

    -- C4: a legacy session with BOTH an agent and a custom-prompt.md resolves
    -- deterministically on its next first-uncomputed completion — custom-prompt
    -- wins per §9.1 precedence (does NOT render the agent).
    it "a legacy agent+custom-prompt session resolves with custom-prompt winning (C4)" $ do
      withSystemTempDirectory "pureclaw-wu6-c4" $ \tmpDir -> do
        let agentsDir = tmpDir </> "agents"
        writeAgentDir agentsDir "myagent" "AGENT SOUL" Nothing
        -- A pre-existing (legacy) session that has BOTH an agent and a
        -- custom-prompt.md on disk — no migration, written directly.
        writeBranchSource tmpDir "sess-c4" (Just "myagent")
          (Just "CUSTOM PROMPT WINS") []
        env <- mkSendEnv tmpDir agentsDir (Just "GLOBAL PROMPT")
        prov <- sendOnce env "sess-c4" "hello"
        case prov of
          (creq:_) -> _cr_systemPrompt creq `shouldBe` Just "CUSTOM PROMPT WINS"
          [] -> expectationFailure "expected a recorded CompletionRequest"

    -- C5: a meta read/decode failure does NOT leave the agent⊕prompt
    -- contradiction — no custom-prompt.md is written and the (malformed)
    -- session.json is untouched.
    it "does not write custom-prompt.md when session.json fails to decode (C5)" $ do
      withSystemTempDirectory "pureclaw-wu6-c5" $ \tmpDir -> do
        let dir = tmpDir </> "sess-c5"
        createDirectoryIfMissing True dir
        -- Malformed session.json that cannot decode as SessionMeta.
        TIO.writeFile (dir </> "session.json") "{ not valid json at all"
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-c5", "prompt"]
          (Aeson.encode (object ["prompt" .= ("SHOULD NOT BE WRITTEN" :: Text)]))
        st `shouldBe` HTTP.status500
        -- The prompt file must NOT have been written (no contradiction).
        promptExists <- doesFileExist (dir </> "custom-prompt.md")
        promptExists `shouldBe` False

    -- A whitespace-only name clears the agent but stores no description.
    it "treats a whitespace-only name as no description (C2 edge)" $ do
      withSystemTempDirectory "pureclaw-wu6-ws" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-ws" (Just "myagent") True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-ws", "prompt"]
          (Aeson.encode (object
            [ "prompt" .= ("CUSTOM" :: Text)
            , "name"   .= ("   " :: Text)
            ]))
        st `shouldBe` HTTP.status200
        meta <- readSessionMeta tmpDir "sess-ws"
        _sm_description meta `shouldBe` Nothing
        _sm_agent meta `shouldBe` Nothing

    -- Missing session.json ⇒ 404, and no custom-prompt.md is written.
    it "returns 404 when session.json does not exist" $ do
      withSystemTempDirectory "pureclaw-wu6-404" $ \tmpDir -> do
        let dir = tmpDir </> "sess-404"
        createDirectoryIfMissing True dir
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-404", "prompt"]
          (Aeson.encode (object ["prompt" .= ("X" :: Text)]))
        st `shouldBe` HTTP.status404
        promptExists <- doesFileExist (dir </> "custom-prompt.md")
        promptExists `shouldBe` False

    -- Invalid session id ⇒ 400.
    it "rejects an invalid session id with 400" $ do
      withSystemTempDirectory "pureclaw-wu6-badid" $ \tmpDir -> do
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "bad/../id", "prompt"]
          (Aeson.encode (object ["prompt" .= ("X" :: Text)]))
        st `shouldBe` HTTP.status400

    -- Malformed request JSON ⇒ 400.
    it "rejects a malformed request body with 400" $ do
      withSystemTempDirectory "pureclaw-wu6-badjson" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-bj" Nothing True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-bj", "prompt"]
          "{ not json"
        st `shouldBe` HTTP.status400

    -- Missing 'prompt' field ⇒ 400.
    it "rejects a body missing the 'prompt' field with 400" $ do
      withSystemTempDirectory "pureclaw-wu6-noprompt" $ \tmpDir -> do
        writeSessionBootstrap tmpDir "sess-np" Nothing True
        env <- mkTestFrontendEnvWithTabsAndDir [] tmpDir
        (st, _) <- putJSON env ["api", "sessions", "sess-np", "prompt"]
          (Aeson.encode (object ["notprompt" .= ("X" :: Text)]))
        st `shouldBe` HTTP.status400

  describe "harnessKeyFromKind (WU1/WU6)" $ do
    it "returns Just the tmux window for a legacy tmux harness (no id)" $
      harnessKeyFromKind
        (SkHarness (HarnessSpec (fixedFlavourLookup "claude-code")
          (TmuxConfig "pureclaw" "claude-code-2" Nothing) Nothing [] Nothing Nothing Nothing))
        `shouldBe` Just "claude-code-2"

    -- WU6: when a HarnessId is present, harnessKeyFromKind returns the durable
    -- id text (not the window name) — the id-primary routing key.
    it "returns the HarnessId text when present (id-primary, WU6)" $ do
      let hid = Registry.parseHarnessId "44444444-4444-4444-8444-444444444444"
      harnessKeyFromKind
        (SkHarness (HarnessSpec (fixedFlavourLookup "claude-code")
          (TmuxConfig "pureclaw" "claude-code-2" Nothing) Nothing [] hid Nothing Nothing))
        `shouldBe` (Registry.harnessIdToText <$> hid)

    it "returns Nothing for a provider session" $
      harnessKeyFromKind
        (SkProvider (ProviderSpec (inferProviderId "claude-3-5") (ModelId "claude-3-5") Nothing))
        `shouldBe` Nothing

  describe "shouldRouteToHarness (WU1)" $ do
    it "is True for a harness (harnesses always run in tmux)" $
      shouldRouteToHarness
        (SkHarness (HarnessSpec (fixedFlavourLookup "claude-code")
          (TmuxConfig "pureclaw" "claude-code-2" Nothing) Nothing [] Nothing Nothing Nothing))
        `shouldBe` True

    it "is True for a harness that carries a HarnessId (WU6)" $ do
      let hid = Registry.parseHarnessId "55555555-5555-4555-8555-555555555555"
      shouldRouteToHarness
        (SkHarness (HarnessSpec (fixedFlavourLookup "claude-code")
          (TmuxConfig "pureclaw" "claude-code-2" Nothing) Nothing [] hid Nothing Nothing))
        `shouldBe` True

    it "is False for a provider session" $
      shouldRouteToHarness
        (SkProvider (ProviderSpec (inferProviderId "claude-3-5") (ModelId "claude-3-5") Nothing))
        `shouldBe` False

  describe "_fe_startHarness default stub (WU1)" $
    it "returns Left for the unwired test FrontendEnv" $ do
      env <- mkTestFrontendEnv
      let spec' = HarnessSpec (fixedFlavourLookup "claude-code") (TmuxConfig "" "" Nothing) Nothing [] Nothing Nothing Nothing
      result <- _fe_startHarness env spec' mkNoOpTranscriptHandle
      case result of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected default stub to return Left"


-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | The number of open tabs, read from the first-class 'TabRegistry' (WU7 —
-- the registry replaced the dropped '_fe_tabCount' counter as the source of
-- truth for the open-tab count).
tabCountOf :: FrontendEnv -> IO Int
tabCountOf env = length . toList <$> readTabs (_fe_tabRegistry env)

-- | Build a minimal FrontendEnv for testing.
mkTestFrontendEnv :: IO FrontendEnv
mkTestFrontendEnv = mkTestFrontendEnvWith 36

mkTestFrontendEnvWith :: Int -> IO FrontendEnv
mkTestFrontendEnvWith maxTabs = do
  harnessRef  <- newIORef Map.empty
  harnessReg  <- Registry.newRegistry
  provRef     <- newIORef Nothing
  modelRef    <- newIORef Nothing
  let logger  = mkNoOpLogHandle
  tabReg      <- newTabRegistry
  cursorsRef  <- newIORef emptyCursors
  exec        <- newExec
  agentEnv    <- mkTestAgentEnv
  pure FrontendEnv
    { _fe_harnesses    = harnessRef
    , _fe_harnessRegistry = harnessReg
    , _fe_consentChannel = ConsentHeadless  -- fail-closed default; adopt tests override
    , _fe_adopt        = \_ _ _ -> pure (Left (HarnessBinaryNotFound "adopt not wired in test"))
    , _fe_releaseTmux  = ReleaseTmux (\_ _ -> pure Nothing) (\_ _ -> pure ()) (\_ _ _ -> pure ())
    , _fe_killWindow   = \_ _ -> pure ()
    , _fe_sessionsDir  = "/tmp/pureclaw-test-sessions"
    , _fe_recentLimit  = 20
    , _fe_provider     = provRef
    , _fe_model        = modelRef
    , _fe_systemPrompt = Nothing
    , _fe_logger       = logger
    , _fe_agentsDir    = "/tmp/pureclaw-test-agents"
    , _fe_defaultAgent = Nothing
    , _fe_maxTabs      = maxTabs
    , _fe_tabRegistry  = tabReg
    , _fe_cursors      = cursorsRef
    , _fe_exec         = exec
    , _fe_closeTab     = \_ -> pure (Left "not wired in test")
    , _fe_startHarness = \_ _ -> pure (Left (HarnessBinaryNotFound "harness start not wired"))
    , _fe_listModels   = \_ -> pure []
    , _fe_listProviders = pure ([] :: [ProviderInfo])
    , _fe_broker       = Nothing
    , _fe_streamGuard  = Nothing
    , _fe_registry    = emptyRegistry
    , _fe_maxToolIterations = 90
    , _fe_agentEnv     = agentEnv
    }

-- | Build a FrontendEnv with a real sessions directory.
-- The tab list is always driven by '_fe_tabRegistry' (WU6): callers that
-- need tabs visible in GET /api/tabs should call 'registryAppend' or
-- 'seedHarnessTab' on the returned env.
mkTestFrontendEnvWithTabsAndDir :: [TabSnapshot] -> FilePath -> IO FrontendEnv
mkTestFrontendEnvWithTabsAndDir _tabs dir = do
  env <- mkTestFrontendEnv
  pure env { _fe_sessionsDir = dir }

-- | Build a FrontendEnv whose tab list is driven by the live tab
-- registry (WU6). Use 'registryAppend' / 'seedHarnessTab' to populate it.
-- Replaces the old @_fe_listTabs@-wired variant.
mkTestFrontendEnvWithRegistryTabs :: IO FrontendEnv
mkTestFrontendEnvWithRegistryTabs = mkTestFrontendEnv

-- | Build a 'FrontendEnv' whose '_fe_agentEnv' has its '_env_runTabCommand'
-- wired to the PRODUCTION seam ('mkRunTabCommandSeam') over a 'TabDispatchDeps'
-- built on that SAME agent env — mirroring how "PureClaw.CLI.Commands" wires
-- the web @/tab@ path. The returned 'TabRegistry' is the single shared registry
-- that both the deps ('_td_tabs') and the agent env ('_env_tabRegistry') point
-- at, so a test can seed it before the request and assert on it afterwards.
--
-- The base test 'AgentEnv' (which has its own private tab subsystem) is
-- overridden so its tab fields point at a freshly-allocated registry/cursors/
-- exec; the deps + seam are then built over that overridden env. The web
-- placeholder conversation key matches production: @(CkWeb, "web")@.
mkWebTabSeamEnv :: FilePath -> IO (FrontendEnv, TabRegistry)
mkWebTabSeamEnv dir = do
  base       <- mkTestFrontendEnvWithTabsAndDir [] dir
  tabReg     <- newTabRegistry
  cursorsRef <- newIORef emptyCursors
  exec       <- newExec
  store      <- newIORef Map.empty
  agentBase  <- mkTestAgentEnv
  -- Share ONE tab subsystem between the deps and the seam's agent env.
  let agentShared = agentBase
        { _env_tabRegistry = tabReg
        , _env_cursors     = cursorsRef
        , _env_exec        = exec
        }
      execDeps = Wiring.mkExecDeps agentShared store
      -- The session-description seam, wired to the real on-disk writer rooted at
      -- @dir@ (mirroring the production 'ServeFrontend' closure), so a web @/tab
      -- rename@ updates the bound session's canonical description and a test can
      -- assert on @session.json@.
      deps     = Wiring.mkTabDispatchDeps agentShared execDeps store
                   (\sid mDesc -> either (Left . T.pack . show) Right
                                    <$> setDescription dir sid mDesc)
      webKey   = (CkWeb, ConversationId "web")
      agentEnv = agentShared
        { _env_runTabCommand = mkRunTabCommandSeam deps webKey }
      env = base
        { _fe_tabRegistry = tabReg
        , _fe_cursors     = cursorsRef
        , _fe_exec        = exec
        , _fe_agentEnv    = agentEnv
        }
  pure (env, tabReg)

-- | Insert a harness registry entry AND the corresponding 'BoundHarness'
-- slot into '_fe_tabRegistry', so the entry appears in GET /api/tabs (WU6).
-- Ignores slot-full / already-bound errors — tests should not overflow the
-- 36-slot cap or re-seed the same 'HarnessId'.
seedHarnessTab :: FrontendEnv -> Registry.HarnessEntry -> IO ()
seedHarnessTab env e = do
  Registry.insertEntry (_fe_harnessRegistry env) e
  _ <- registryAppend
         (_fe_tabRegistry env)
         (BoundHarness (Registry._he_id e))
  pure ()

-- | Bind a 'BoundHarness' tab for @hid@ into '_fe_tabRegistry' at the next
-- free slot (WU7). Used by the harness-action tests (dismiss\/release\/
-- destroy\/acknowledge) that build + insert their harness entry inline into
-- the harness registry and then need a corresponding tab so the slot resolves.
-- The label is cosmetic (action resolution is by slot). Slot-full\/already-
-- bound errors are ignored — the action tests never overflow the cap.
tabBindHarness :: FrontendEnv -> Registry.HarnessId -> IO ()
tabBindHarness env hid = do
  _ <- registryAppend (_fe_tabRegistry env) (BoundHarness hid)
  pure ()

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
        , _sm_source            = Nothing
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

-- | A harness New-tab request body. The request carries placeholder tmux
-- coordinates (empty session\/window — the New-Harness composer leaves them
-- blank); the spawn replaces them with the real 'TmuxConfig' from the
-- 'StartedHarness'. A harness always runs in tmux, so the coords live under
-- the @tmux@ key (not the tool-call @backend@ key).
harnessNewTabBody :: LBS.ByteString
harnessNewTabBody = Aeson.encode $ object
  [ "kind" .= object
      [ "tag" .= ("session" :: Text)
      , "session_kind" .= object
          [ "tag"     .= ("harness" :: Text)
          , "flavour" .= ("claude-code" :: Text)
          , "tmux"    .= object [ "window" .= ("" :: Text) ]
          ]
      ]
  ]

-- | A harness New-tab request body that specifies tmux coordinates with an
-- explicit @session@ (WU7, D7.3). The window is a placeholder the spawn path
-- overrides; only the session is honored for placement.
harnessNewTabBodyWithSession :: Text -> LBS.ByteString
harnessNewTabBodyWithSession session = Aeson.encode $ object
  [ "kind" .= object
      [ "tag" .= ("session" :: Text)
      , "session_kind" .= object
          [ "tag"     .= ("harness" :: Text)
          , "flavour" .= ("claude-code" :: Text)
          , "tmux"    .= object
              [ "session" .= session
              , "window"  .= ("requested-window" :: Text)
              ]
          ]
      ]
  ]

-- | A minimal 'HarnessSpec' carrying the given tmux coordinates (WU7 unit tests
-- for 'resolveHarnessSession'). All other fields are inert defaults.
harnessSpecWithTmux :: TmuxConfig -> HarnessSpec
harnessSpecWithTmux tmux = HarnessSpec
  { _h_flavour   = HClaudeCode
  , _h_tmux      = tmux
  , _h_cwd       = Nothing
  , _h_args      = []
  , _h_harnessId = Nothing
  , _h_claudeSessionUuid = Nothing
  , _h_canonicalCwd      = Nothing
  }

-- | A fake '_fe_startHarness' that registers a no-op 'HarnessHandle' under
-- the given key and returns a 'StartedHarness' whose tmux window matches
-- that key. Mirrors the dispatcher's real contract closely enough for the
-- API layer's behaviour (registration + coordinate persistence) to be
-- exercised without spawning a real process. The harness map ref is the
-- same '_fe_harnesses' the env carries, so registration is observable.
fakeStartHarness
  :: IORef (Map.Map Text HarnessHandle)
  -> Text
  -> (HarnessSpec -> TranscriptHandle -> IO (Either HarnessError StartedHarness))
fakeStartHarness harnessRef key =
  fakeStartHarnessWith harnessRef key fakeStartedHid Nothing

-- | A fake '_fe_startHarness' (WU6) that returns a configurable
-- claudeSessionUuid + canonicalCwd on its 'StartedHarness', so a test can
-- assert that 'createHarnessTab' persists those two additive fields into the
-- session's @_sm_kind@. Registers a no-op handle under @key@ like
-- 'fakeStartHarness'.
fakeStartHarnessUuid
  :: IORef (Map.Map Text HarnessHandle)
  -> Text             -- ^ window/map key
  -> Maybe Text       -- ^ claudeSessionUuid to surface
  -> Maybe Text       -- ^ canonicalCwd to surface
  -> (HarnessSpec -> TranscriptHandle -> IO (Either HarnessError StartedHarness))
fakeStartHarnessUuid harnessRef key mUuid mCwd reqSpec _ = do
  let session = resolveHarnessSession reqSpec
  modifyIORef' harnessRef (Map.insert key mkNoOpHarnessHandle)
  pure $ Right $ StartedHarness
    { _shh_key  = key
    , _shh_tmux = TmuxConfig { _tc_session = session, _tc_window = key, _tc_pane = Nothing }
    , _shh_id   = fakeStartedHid
    , _shh_claudeSessionUuid = mUuid
    , _shh_canonicalCwd      = mCwd
    }

-- | The canonical 'Registry.HarnessId' a 'fakeStartHarness' stamps onto its
-- 'StartedHarness' result (WU7). Tests that assert id persistence read this
-- back from the persisted @session.json@.
fakeStartedHid :: Registry.HarnessId
fakeStartedHid = mustParseHid "abcdef00-0000-4000-8000-000000000001"

-- | A configurable fake '_fe_startHarness' (WU7). Mirrors the real
-- dispatcher's WU7 contract: it resolves the tmux session from the requested
-- spec via 'resolveHarnessSession' (honoring '_tc_session', default
-- @"pureclaw"@), and returns a 'StartedHarness' carrying the injected
-- 'Registry.HarnessId' plus the resolved 'TmuxConfig'. When @mReg@ is 'Nothing'
-- it registers a live no-op handle under @key@ in the legacy '_fe_harnesses'
-- map (the WU2 contract). When @mReg@ is @Just (reg, sentRef)@ it instead seeds
-- a corroborated registry entry keyed by the id, whose handle records sends
-- into @sentRef@ — letting a test prove a post-'createHarnessTab' send routes
-- by the persisted id through the registry (D7.4).
fakeStartHarnessWith
  :: IORef (Map.Map Text HarnessHandle)
  -> Text                              -- ^ window/map key
  -> Registry.HarnessId                -- ^ id to stamp on the result
  -> Maybe (Registry.HarnessRegistry, IORef [ByteString])
                                       -- ^ optional: seed a corroborated entry
  -> (HarnessSpec -> TranscriptHandle -> IO (Either HarnessError StartedHarness))
fakeStartHarnessWith harnessRef key hid mReg reqSpec _ = do
  let session = resolveHarnessSession reqSpec
  case mReg of
    Just (reg, sentRef) ->
      Registry.insertEntry reg
        (corroboratedEntry hid key
          (Just (mkFakeHarnessHandle sentRef "id-routed reply")))
    Nothing ->
      modifyIORef' harnessRef (Map.insert key mkNoOpHarnessHandle)
  pure $ Right $ StartedHarness
    { _shh_key  = key
    , _shh_tmux = TmuxConfig { _tc_session = session, _tc_window = key, _tc_pane = Nothing }
    , _shh_id   = hid
    , _shh_claudeSessionUuid = Nothing
    , _shh_canonicalCwd      = Nothing
    }

-- | A fake 'HarnessHandle' for the WU3 send-routing tests. It captures the
-- bytes written via '_hh_send' into the supplied 'IORef' (newest last) and
-- returns the canned bytes from '_hh_receive'. Lets a test assert both that
-- the send was routed to the harness and that the route's response was
-- surfaced — without spawning a real tmux process.
mkFakeHarnessHandle :: IORef [ByteString] -> ByteString -> HarnessHandle
mkFakeHarnessHandle sentRef canned = HarnessHandle
  { _hh_send    = \bs -> modifyIORef' sentRef (++ [bs])
  , _hh_receive = pure canned
  , _hh_name    = "fake-harness"
  , _hh_session = "pureclaw"
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = pure ()
  }

-- | Read every event currently in a broker 'Subscription' queue, waiting up
-- to @budgetMicros@ for the first arrival. Returns the accumulated list in
-- publish order. Mirrors the drain helper in "Frontend.ActivityProbeSpec".
drainBrokerQueue :: Int -> Subscription -> IO [BrokerEvent]
drainBrokerQueue budgetMicros sub = do
  first <- timeout budgetMicros $ atomically (readTBQueue (_sub_queue sub))
  case first of
    Nothing  -> pure []
    Just ev0 -> (ev0 :) <$> drainNonBlocking
  where
    drainNonBlocking :: IO [BrokerEvent]
    drainNonBlocking = do
      mEv <- timeout 10000 $ atomically (readTBQueue (_sub_queue sub))
      case mEv of
        Nothing -> pure []
        Just ev -> (ev :) <$> drainNonBlocking

-- | A fake 'HarnessHandle' whose '_hh_receive' throws, exercising the
-- exception path in 'sendToHarness' (the @try \@SomeException@ around the
-- '_hh_send'\/'_hh_receive' interaction). It records the send like
-- 'mkFakeHarnessHandle' so the test can confirm the send happened before
-- the throw, then surfaces a 500.
mkThrowingHarnessHandle :: IORef [ByteString] -> HarnessHandle
mkThrowingHarnessHandle sentRef = HarnessHandle
  { _hh_send    = \bs -> modifyIORef' sentRef (++ [bs])
  , _hh_receive = throwIO (userError "boom")
  , _hh_name    = "fake-throwing-harness"
  , _hh_session = "pureclaw"
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = pure ()
  }

-- | A fake handle that, like a restart-discovered REAL handle, ALSO records
-- to its OWN (separate) transcript file — simulating how
-- 'discoverHarnesses' wires the CLI's own session transcript into the
-- rediscovered handle. Used to prove 'sendToHarness' does not duplicate
-- entries in the *session* transcript when the handle records elsewhere.
mkRecordingFakeHarnessHandle :: FilePath -> IORef [ByteString] -> ByteString -> HarnessHandle
mkRecordingFakeHarnessHandle ownTranscript sentRef canned = HarnessHandle
  { _hh_send    = \bs -> do
      modifyIORef' sentRef (++ [bs])
      LBS.appendFile ownTranscript (LBS.fromStrict bs <> "\n")
  , _hh_receive = do
      LBS.appendFile ownTranscript (LBS.fromStrict canned <> "\n")
      pure canned
  , _hh_name    = "fake-recording-harness"
  , _hh_session = "pureclaw"
  , _hh_status  = pure HarnessRunning
  , _hh_stop    = pure ()
  }

-- | Write a harness-backed session to disk: @session.json@ whose
-- @_sm_kind@ is 'SkHarness' over a 'TmuxConfig' with the given window
-- name (the harness map key), plus an empty (but present) transcript so
-- the @/send@ handler's 404 existence check passes.
writeHarnessSession :: FilePath -> Text -> Text -> IO ()
writeHarnessSession baseDir sid windowKey = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let hSpecRec = HarnessSpec
        { _h_flavour = HClaudeCode
        , _h_tmux = TmuxConfig
            { _tc_session = "pureclaw"
            , _tc_window  = windowKey
            , _tc_pane    = Nothing
            }
        , _h_cwd       = Nothing
        , _h_args      = []
        , _h_harnessId = Nothing
        , _h_claudeSessionUuid = Nothing
        , _h_canonicalCwd      = Nothing
        }
      meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = Nothing
        , _sm_kind              = SkHarness hSpecRec
        , _sm_model             = ""
        , _sm_channel           = "web"
        , _sm_createdAt         = epochH
        , _sm_lastActive        = epochH
        , _sm_bootstrapConsumed = True
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        , _sm_source            = Nothing
        }
      epochH = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  LBS.writeFile (dir </> "transcript.jsonl") ""

-- | Like 'writeHarnessSession', but also persists an optional 'HarnessId' on
-- the 'HarnessSpec' (WU6). When @Just hid@, the spec carries BOTH the id and
-- the dual-written tmux window name.
writeHarnessSessionWithId :: FilePath -> Text -> Text -> Maybe Text -> IO ()
writeHarnessSessionWithId baseDir sid windowKey mHidTxt = do
  let dir = baseDir </> T.unpack sid
  createDirectoryIfMissing True dir
  let hSpecRec = HarnessSpec
        { _h_flavour = HClaudeCode
        , _h_tmux = TmuxConfig
            { _tc_session = "pureclaw"
            , _tc_window  = windowKey
            , _tc_pane    = Nothing
            }
        , _h_cwd       = Nothing
        , _h_args      = []
        , _h_harnessId = mHidTxt >>= Registry.parseHarnessId
        , _h_claudeSessionUuid = Nothing
        , _h_canonicalCwd      = Nothing
        }
      meta = SessionMeta
        { _sm_id                = SessionId sid
        , _sm_agent             = Nothing
        , _sm_kind              = SkHarness hSpecRec
        , _sm_model             = ""
        , _sm_channel           = "web"
        , _sm_createdAt         = epochH
        , _sm_lastActive        = epochH
        , _sm_bootstrapConsumed = True
        , _sm_archived          = False
        , _sm_description       = Nothing
        , _sm_autoSummary       = Nothing
        , _sm_source            = Nothing
        }
      epochH = UTCTime (fromGregorian 2024 1 1) (secondsToDiffTime 0)
  LBS.writeFile (dir </> "session.json") (Aeson.encode meta)
  LBS.writeFile (dir </> "transcript.jsonl") ""


-- | Force-parse a 'Registry.HarnessId' from canonical UUID text (test-only).
mustParseHid :: Text -> Registry.HarnessId
mustParseHid t = case Registry.parseHarnessId t of
  Just h  -> h
  Nothing -> error ("mustParseHid: not a UUID: " <> T.unpack t)

-- | A PID-corroborated registry entry (a recorded harness PID is evidence the
-- entry is ours) with the given id, label (= window name) and optional handle.
corroboratedEntry :: Registry.HarnessId -> Text -> Maybe HarnessHandle -> Registry.HarnessEntry
corroboratedEntry hid window mHandle = (baseEntry hid window mHandle)
  { Registry._he_harnessPid = Just 4242 }

-- | A PID-corroborated, OriginAdopted registry entry (WU8 Part B). Mirrors what
-- 'adoptExternalWindow' registers: an adopted window with recorded PID
-- provenance and an attached handle whose own transcript is a NO-OP (so
-- 'handleSend'/'routeViaHandle' remains the SOLE recorder, exactly as on the
-- spawn path).
adoptedCorroboratedEntry :: Registry.HarnessId -> Text -> Maybe HarnessHandle -> Registry.HarnessEntry
adoptedCorroboratedEntry hid window mHandle = (corroboratedEntry hid window mHandle)
  { Registry._he_origin = Registry.OriginAdopted }

-- | An UNcorroborated entry: a bare (spoofable) marker with NO recorded PIDs.
uncorroboratedEntry :: Registry.HarnessId -> Text -> Maybe HarnessHandle -> Registry.HarnessEntry
uncorroboratedEntry = baseEntry

-- | Shared 'HarnessEntry' skeleton for the routing tests.
baseEntry :: Registry.HarnessId -> Text -> Maybe HarnessHandle -> Registry.HarnessEntry
baseEntry hid window mHandle = Registry.HarnessEntry
  { Registry._he_id          = hid
  , Registry._he_session     = "pureclaw"
  , Registry._he_windowName  = window
  , Registry._he_shellPid    = Nothing
  , Registry._he_harnessPid  = Nothing
  , Registry._he_origin      = Registry.OriginSpawned
  , Registry._he_liveness    = Registry.LivenessIdle
  , Registry._he_extModified = False
  , Registry._he_stale       = False
  , Registry._he_sessionId   = Nothing
  , Registry._he_label       = window
  , Registry._he_orphanedTicks = 0
  , Registry._he_handle      = mHandle
  }

-- | A 'LogHandle' that captures every error-level message into the 'IORef'.
captureErrorLogger :: IORef [Text] -> LogHandle
captureErrorLogger ref = mkNoOpLogHandle
  { _lh_logError = \msg -> modifyIORef' ref (++ [msg]) }

-- | A 'LogHandle' that captures every warn-level message into the 'IORef'.
-- Used by the Release SEC-3 tests to assert the deregister-only refusal is
-- logged.
captureWarnLogger :: IORef [Text] -> LogHandle
captureWarnLogger ref = mkNoOpLogHandle
  { _lh_logWarn = \msg -> modifyIORef' ref (++ [msg]) }

-- | A 'LogHandle' that captures every info-level message into the 'IORef'.
-- Used by the Release D5.4 test to assert the reserved-purge no-op is logged.
captureInfoLogger :: IORef [Text] -> LogHandle
captureInfoLogger ref = mkNoOpLogHandle
  { _lh_logInfo = \msg -> modifyIORef' ref (++ [msg]) }

-- | Reload a session's @session.json@ as raw JSON (test-only).
tryLoadMetaJson :: FilePath -> Text -> IO (Maybe Aeson.Value)
tryLoadMetaJson baseDir sid = do
  let p = baseDir </> T.unpack sid </> "session.json"
  ok <- doesFileExist p
  if not ok then pure Nothing else Aeson.decode <$> LBS.readFile p

-- | Extract @kind.harnessId@ from a decoded @session.json@ value (test-only).
harnessIdOfMeta :: Maybe Aeson.Value -> Maybe Text
harnessIdOfMeta mv = do
  v <- mv
  kind <- lookupKey v "kind"
  hid  <- lookupKey kind "harnessId"
  case hid of
    Aeson.String s -> Just s
    _              -> Nothing

-- | Read and decode a session's @transcript.jsonl@ into entries (oldest
-- first), tolerating a missing or empty file (returns @[]@).
readSessionTranscript :: FilePath -> Text -> IO [TranscriptEntry]
readSessionTranscript baseDir sid = do
  let p = baseDir </> T.unpack sid </> "transcript.jsonl"
  ok <- doesFileExist p
  if not ok then pure [] else do
    raw <- LBS.readFile p
    let ls = filter (not . LBS.null) (LBS.split 0x0a raw)
    pure (foldr (\x acc -> maybe acc (: acc) (Aeson.decode' x)) [] ls)

-- | Count the non-empty lines in a session's @transcript.jsonl@. Used by the
-- slash short-circuit tests to assert a handled command appended nothing.
transcriptLineCount :: FilePath -> Text -> IO Int
transcriptLineCount baseDir sid = do
  let p = baseDir </> T.unpack sid </> "transcript.jsonl"
  ok <- doesFileExist p
  if not ok then pure 0 else do
    raw <- LBS.readFile p
    pure (length (filter (not . LBS.null) (LBS.split 0x0a raw)))

-- | List the entries under a sessions base dir, ignoring a missing base
-- dir. Used to assert a failed harness spawn left no session directory
-- behind.
listSessionDirs :: FilePath -> IO [FilePath]
listSessionDirs baseDir = do
  exists <- doesDirectoryExist baseDir
  if not exists then pure [] else listDirectory baseDir

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
        , _sm_source            = Nothing
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
        (TmuxConfig "cc" "cc" Nothing) Nothing [] Nothing Nothing Nothing
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
        , _sm_source            = Nothing
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
        , _sm_source            = Nothing
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

-- | PUT a JSON body to the apiApp and return (status, response body).
putJSON :: FrontendEnv -> [Text] -> LBS.ByteString
        -> IO (HTTP.Status, LBS.ByteString)
putJSON env pathParts body = do
  ref <- newIORef (Nothing :: Maybe Wai.Response)
  bodyRef <- newIORef (LBS.toChunks body)
  let getChunk = do
        chunks <- readIORef bodyRef
        case chunks of
          []     -> pure mempty
          (c:cs) -> writeIORef bodyRef cs >> pure c
      req = Wai.setRequestBodyChunks getChunk
          $ Wai.defaultRequest
        { Wai.requestMethod  = "PUT"
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

-- | Read and decode a session's @session.json@ as 'SessionMeta', failing
-- the test if it is missing or undecodable.
readSessionMeta :: FilePath -> Text -> IO SessionMeta
readSessionMeta baseDir sid = do
  raw <- LBS.readFile (baseDir </> T.unpack sid </> "session.json")
  case Aeson.eitherDecode' raw of
    Right meta -> pure meta
    Left e     -> expectationFailure ("readSessionMeta: decode failed: " <> e)
                    >> error "unreachable"

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

-- | Decode a response body to a JSON object and look up a top-level key.
lookupKey' :: LBS.ByteString -> Text -> Maybe Aeson.Value
lookupKey' body k = Aeson.decode body >>= (`lookupKey` k)

-- | Safe head for the @D3.4@ ordering assertion.
listToMaybe' :: [a] -> Maybe a
listToMaybe' []      = Nothing
listToMaybe' (x : _) = Just x

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
