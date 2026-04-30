module CLI.ImportSpec (spec) where

import Data.Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.CLI.Import

spec :: Spec
spec = do
  describe "stripJson5" $ do
    it "passes through valid JSON unchanged" $ do
      let input = "{\"key\": \"value\"}"
      stripJson5 input `shouldBe` input

    it "strips // line comments" $ do
      let input = "{\n  // this is a comment\n  \"key\": \"value\"\n}"
      let expected = "{\n  \n  \"key\": \"value\"\n}"
      stripJson5 input `shouldBe` expected

    it "does not strip // inside strings" $ do
      let input = "{\"url\": \"https://example.com\"}"
      stripJson5 input `shouldBe` input

    it "strips trailing commas before }" $ do
      let input = "{\"a\": 1, \"b\": 2,}"
      stripJson5 input `shouldBe` "{\"a\": 1, \"b\": 2}"

    it "strips trailing commas before ]" $ do
      let input = "[1, 2, 3,]"
      stripJson5 input `shouldBe` "[1, 2, 3]"

    it "strips trailing commas with whitespace" $ do
      let input = "{\"a\": 1,\n  }"
      stripJson5 input `shouldBe` "{\"a\": 1}"

    it "does not strip commas before values" $ do
      let input = "{\"a\": 1, \"b\": 2}"
      stripJson5 input `shouldBe` input

    it "handles escaped quotes in strings" $ do
      let input = "{\"key\": \"value with \\\"quotes\\\"\"}"
      stripJson5 input `shouldBe` input

    it "strips trailing commas followed by comments on the same line" $ do
      let input = "{\"a\": 1, // comment\n}"
      stripJson5 input `shouldBe` "{\"a\": 1}"

    it "strips trailing commas in arrays followed by comments" $ do
      let input = "[1, 2, // comment\n]"
      stripJson5 input `shouldBe` "[1, 2]"

  describe "parseOpenClawConfig" $ do
    it "parses a basic config with model and agents" $ do
      let json = object
            [ "agents" .= object
                [ "defaults" .= object
                    [ "model" .= object ["primary" .= ("anthropic/claude-sonnet-4-6" :: Text)]
                    , "workspace" .= ("~/Projects" :: Text)
                    ]
                , "list" .=
                    [ object
                        [ "id" .= ("coder" :: Text)
                        , "systemPrompt" .= ("Write clean code." :: Text)
                        , "model" .= object ["primary" .= ("anthropic/claude-sonnet-4-6" :: Text)]
                        , "tools" .= object ["profile" .= ("coding" :: Text)]
                        ]
                    ]
                ]
            ]
      case parseOpenClawConfig json of
        Left err -> expectationFailure err
        Right oc -> do
          _oc_defaultModel oc `shouldBe` Just "anthropic/claude-sonnet-4-6"
          _oc_workspace oc `shouldBe` Just "~/Projects"
          case _oc_agents oc of
            [agent] -> _oca_id agent `shouldBe` "coder"
            other   -> expectationFailure $ "expected 1 agent, got " <> show (length other)

    it "parses Signal channel config" $ do
      let json = object
            [ "channels" .= object
                [ "signal" .= object
                    [ "account" .= ("+15555550123" :: Text)
                    , "dmPolicy" .= ("allowlist" :: Text)
                    , "allowFrom" .= ["+1555" :: Text, "+1666"]
                    ]
                ]
            ]
      case parseOpenClawConfig json of
        Left err -> expectationFailure err
        Right oc -> do
          case _oc_signal oc of
            Nothing -> expectationFailure "expected signal config"
            Just sig -> do
              _ocs_account sig `shouldBe` Just "+15555550123"
              _ocs_dmPolicy sig `shouldBe` Just "allowlist"
              _ocs_allowFrom sig `shouldBe` Just ["+1555", "+1666"]

    it "parses Telegram channel config" $ do
      let json = object
            [ "channels" .= object
                [ "telegram" .= object
                    [ "botToken" .= ("123:ABC" :: Text)
                    , "dmPolicy" .= ("pairing" :: Text)
                    ]
                ]
            ]
      case parseOpenClawConfig json of
        Left err -> expectationFailure err
        Right oc -> do
          case _oc_telegram oc of
            Nothing -> expectationFailure "expected telegram config"
            Just tg -> do
              _oct_botToken tg `shouldBe` Just "123:ABC"
              _oct_dmPolicy tg `shouldBe` Just "pairing"

    it "handles model as a plain string" $ do
      let json = object
            [ "agents" .= object
                [ "defaults" .= object
                    [ "model" .= ("anthropic/claude-opus-4-6" :: Text) ]
                ]
            ]
      case parseOpenClawConfig json of
        Left err -> expectationFailure err
        Right oc -> _oc_defaultModel oc `shouldBe` Just "anthropic/claude-opus-4-6"

    it "handles empty config" $ do
      case parseOpenClawConfig (object []) of
        Left err -> expectationFailure err
        Right oc -> do
          _oc_defaultModel oc `shouldBe` Nothing
          _oc_agents oc `shouldBe` []
          _oc_signal oc `shouldBe` Nothing

  describe "importOpenClawConfig" $ do
    it "imports a basic config and writes files" $
      withSystemTempDirectory "pureclaw-import-test" $ \tmpDir -> do
        let ocPath = tmpDir </> "openclaw.json"
        TIO.writeFile ocPath $ T.unlines
          [ "{"
          , "  // Test config"
          , "  \"agents\": {"
          , "    \"defaults\": {"
          , "      \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" },"
          , "      \"workspace\": \"~/Projects\","
          , "    },"
          , "    \"list\": ["
          , "      {"
          , "        \"id\": \"coder\","
          , "        \"systemPrompt\": \"You are a coding assistant.\","
          , "        \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" },"
          , "        \"tools\": { \"profile\": \"coding\" },"
          , "      },"
          , "    ],"
          , "  },"
          , "  \"channels\": {"
          , "    \"signal\": {"
          , "      \"account\": \"+15555550123\","
          , "      \"dmPolicy\": \"allowlist\","
          , "    },"
          , "  },"
          , "}"
          ]
        let configDir = tmpDir </> "config"
        result <- importOpenClawConfig ocPath configDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right ir -> do
            _ir_configWritten ir `shouldBe` True
            _ir_agentsWritten ir `shouldBe` ["coder"]

            -- config.toml should exist
            configExists <- doesFileExist (configDir </> "config.toml")
            configExists `shouldBe` True
            configContent <- TIO.readFile (configDir </> "config.toml")
            T.unpack configContent `shouldContain` "anthropic/claude-sonnet-4-6"
            T.unpack configContent `shouldContain` "[signal]"
            T.unpack configContent `shouldContain` "+15555550123"

            -- Agent file should exist
            agentExists <- doesFileExist (configDir </> "agents" </> "coder" </> "AGENTS.md")
            agentExists `shouldBe` True
            agentContent <- TIO.readFile (configDir </> "agents" </> "coder" </> "AGENTS.md")
            T.unpack agentContent `shouldContain` "coding assistant"
            T.unpack agentContent `shouldContain` "model: anthropic/claude-sonnet-4-6"
            T.unpack agentContent `shouldContain` "tool_profile: coding"

            -- Default agent should exist
            defaultExists <- doesFileExist (configDir </> "agents" </> "default" </> "AGENTS.md")
            defaultExists `shouldBe` True

    it "handles $include directives" $
      withSystemTempDirectory "pureclaw-import-test" $ \tmpDir -> do
        -- Write the main config with $include
        let ocPath = tmpDir </> "openclaw.json"
        TIO.writeFile ocPath $ T.unlines
          [ "{"
          , "  \"agents\": { \"$include\": \"./agents.json\" },"
          , "  \"channels\": { \"signal\": { \"account\": \"+1234\" } }"
          , "}"
          ]
        -- Write the included file
        TIO.writeFile (tmpDir </> "agents.json") $ T.unlines
          [ "{"
          , "  \"defaults\": { \"model\": \"anthropic/claude-opus-4-6\" },"
          , "  \"list\": [{ \"id\": \"helper\", \"systemPrompt\": \"Help users.\" }]"
          , "}"
          ]
        let configDir = tmpDir </> "config"
        result <- importOpenClawConfig ocPath configDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right ir -> do
            _ir_agentsWritten ir `shouldBe` ["helper"]
            agentContent <- TIO.readFile (configDir </> "agents" </> "helper" </> "AGENTS.md")
            T.unpack agentContent `shouldContain` "Help users."

  describe "camelToSnake" $ do
    it "converts camelCase to snake_case" $
      camelToSnake "allowList" `shouldBe` "allow_list"

    it "leaves lowercase unchanged" $
      camelToSnake "pairing" `shouldBe` "pairing"

    it "handles leading uppercase" $
      camelToSnake "AllowAll" `shouldBe` "_allow_all"

  describe "mapThinkingDefault" $ do
    it "maps always/high to high" $ do
      mapThinkingDefault "always" `shouldBe` "high"
      mapThinkingDefault "high" `shouldBe` "high"

    it "maps auto/medium to medium" $ do
      mapThinkingDefault "auto" `shouldBe` "medium"
      mapThinkingDefault "medium" `shouldBe` "medium"

    it "maps off/low/none/minimal to low" $ do
      mapThinkingDefault "off" `shouldBe` "low"
      mapThinkingDefault "low" `shouldBe` "low"
      mapThinkingDefault "none" `shouldBe` "low"
      mapThinkingDefault "minimal" `shouldBe` "low"

    it "is case-insensitive" $
      mapThinkingDefault "Always" `shouldBe` "high"

  describe "computeMaxTurns" $ do
    it "divides by 10" $
      computeMaxTurns 900 `shouldBe` 90

    it "caps at 200" $
      computeMaxTurns 5000 `shouldBe` 200

    it "handles small values" $
      computeMaxTurns 30 `shouldBe` 3

    it "clamps to minimum of 1" $ do
      computeMaxTurns 0 `shouldBe` 1
      computeMaxTurns 5 `shouldBe` 1

  describe "resolveImportOptions" $ do
    it "uses positional directory arg as --from" $
      withSystemTempDirectory "pureclaw-import-test" $ \tmpDir -> do
        let posDir = tmpDir </> "myopenclaw"
        createDirectory posDir
        (fromDir, _toDir) <- resolveImportOptions (ImportOptions Nothing Nothing) (Just posDir)
        fromDir `shouldBe` posDir

    it "uses dirname of positional .json file as --from" $ do
      (fromDir, _toDir) <- resolveImportOptions (ImportOptions Nothing Nothing) (Just "/home/user/.openclaw/openclaw.json")
      fromDir `shouldBe` "/home/user/.openclaw"

    it "prefers --from over positional arg" $ do
      (fromDir, _toDir) <- resolveImportOptions (ImportOptions (Just "/custom/from") Nothing) Nothing
      fromDir `shouldBe` "/custom/from"

    it "uses --to when specified" $ do
      (_fromDir, toDir) <- resolveImportOptions (ImportOptions Nothing (Just "/custom/to")) Nothing
      toDir `shouldBe` "/custom/to"

  describe "importOpenClawDir" $ do
    it "imports a full OpenClaw state directory" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"
        setupOpenClawDir fromDir
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            -- Config was written
            _ir_configWritten (_dir_configResult dir) `shouldBe` True

            -- Credentials were imported
            _dir_credentialsOk dir `shouldBe` True
            credsExists <- doesFileExist (toDir </> "credentials.json")
            credsExists `shouldBe` True
            credsContent <- LBS.readFile (toDir </> "credentials.json")
            case decode @Value credsContent of
              Just (Object _) -> pure ()
              _ -> expectationFailure "credentials.json should be a valid JSON object"

            -- Device ID was extracted
            _dir_deviceId dir `shouldBe` Just "test-device-123"

            -- Workspace path points to PureClaw copy (not original)
            _dir_workspacePath dir `shouldBe` Just (toDir </> "workspace")

            -- Config.toml has workspace and identity sections
            let configDir = toDir </> "config"
            configContent <- TIO.readFile (configDir </> "config.toml")
            T.unpack configContent `shouldContain` "[workspace]"
            T.unpack configContent `shouldContain` (toDir </> "workspace")
            T.unpack configContent `shouldContain` "[identity]"
            T.unpack configContent `shouldContain` "test-device-123"

    it "handles missing auth-profiles gracefully" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"
        -- Only create the minimum required file
        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") "{}"
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            _dir_credentialsOk dir `shouldBe` False
            _dir_deviceId dir `shouldBe` Nothing
            _dir_workspacePath dir `shouldBe` Nothing
            length (_dir_warnings dir) `shouldSatisfy` (> 0)

    it "fails when openclaw.json is missing" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
        createDirectoryIfMissing True fromDir
        -- No openclaw.json
        result <- importOpenClawDir fromDir (tmpDir </> "pureclaw")
        case result of
          Left err -> T.unpack err `shouldContain` "No openclaw.json"
          Right _  -> expectationFailure "Should have failed without openclaw.json"

    it "detects cron jobs without importing them" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"
        setupOpenClawDir fromDir
        -- Add cron jobs
        createDirectoryIfMissing True (fromDir </> "cron")
        TIO.writeFile (fromDir </> "cron" </> "jobs.json") "{\"jobs\":[]}"
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> _dir_cronSkipped dir `shouldBe` True

    it "imports models.json" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"
        setupOpenClawDir fromDir
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            _dir_modelsImported dir `shouldBe` True
            modelsExists <- doesFileExist (toDir </> "models.json")
            modelsExists `shouldBe` True

    it "finds extra workspace-* directories" $
      withSystemTempDirectory "pureclaw-dir-import-test" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"
        setupOpenClawDir fromDir
        -- Add extra workspaces
        createDirectoryIfMissing True (fromDir </> "workspace-dev")
        createDirectoryIfMissing True (fromDir </> "workspace-staging")
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            length (_dir_extraWorkspaces dir) `shouldBe` 2
            -- Config should mention them as comments
            configContent <- TIO.readFile (toDir </> "config" </> "config.toml")
            T.unpack configContent `shouldContain` "workspace-"

-- | Set up a realistic OpenClaw directory structure for testing.
setupOpenClawDir :: FilePath -> IO ()
setupOpenClawDir dir = do
  createDirectoryIfMissing True dir

  -- openclaw.json
  TIO.writeFile (dir </> "openclaw.json") $ T.unlines
    [ "{"
    , "  \"agents\": {"
    , "    \"defaults\": {"
    , "      \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" }"
    , "    },"
    , "    \"list\": ["
    , "      { \"id\": \"main\", \"systemPrompt\": \"You are helpful.\" }"
    , "    ]"
    , "  }"
    , "}"
    ]

  -- auth-profiles.json
  let authDir = dir </> "agents" </> "main" </> "agent"
  createDirectoryIfMissing True authDir
  TIO.writeFile (authDir </> "auth-profiles.json") $ T.unlines
    [ "{"
    , "  \"version\": 1,"
    , "  \"profiles\": {"
    , "    \"anthropic:default\": {"
    , "      \"type\": \"token\","
    , "      \"provider\": \"anthropic\","
    , "      \"token\": \"sk-ant-test-key-123\""
    , "    }"
    , "  },"
    , "  \"lastGood\": { \"anthropic\": \"anthropic:default\" }"
    , "}"
    ]

  -- models.json
  TIO.writeFile (authDir </> "models.json") $ T.unlines
    [ "{"
    , "  \"overrides\": {"
    , "    \"fast\": \"anthropic/claude-haiku-4-5\""
    , "  }"
    , "}"
    ]

  -- device.json
  let identityDir = dir </> "identity"
  createDirectoryIfMissing True identityDir
  TIO.writeFile (identityDir </> "device.json") $ T.unlines
    [ "{"
    , "  \"deviceId\": \"test-device-123\","
    , "  \"publicKeyPem\": \"-----BEGIN PUBLIC KEY-----\","
    , "  \"privateKeyPem\": \"-----BEGIN PRIVATE KEY-----\""
    , "}"
    ]

  -- workspace directory
  let workspaceDir = dir </> "workspace"
  createDirectoryIfMissing True workspaceDir
