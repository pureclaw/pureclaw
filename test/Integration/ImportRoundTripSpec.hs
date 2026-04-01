module Integration.ImportRoundTripSpec (spec) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import PureClaw.Agent.Identity
import PureClaw.CLI.Config
import PureClaw.CLI.Import

spec :: Spec
spec = do
  describe "E2E import round-trip" $ do

    it "Test 1: minimal agent — model and system prompt survive round-trip" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"

        -- Create minimal OpenClaw directory
        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"agents\": {"
          , "    \"defaults\": {"
          , "      \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" }"
          , "    },"
          , "    \"list\": ["
          , "      {"
          , "        \"id\": \"coder\","
          , "        \"systemPrompt\": \"You are a coding assistant. Write clean, tested code.\","
          , "        \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" },"
          , "        \"tools\": { \"profile\": \"coding\" }"
          , "      }"
          , "    ]"
          , "  }"
          , "}"
          ]

        -- Run the importer
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right _dir -> do
            -- Phase A: Load config.toml through PureClaw's TOML pipeline (not raw string)
            let configPath = toDir </> "config" </> "config.toml"
            diag <- loadFileConfigDiag configPath
            case diag of
              ConfigLoaded _ fc ->
                _fc_model fc `shouldBe` Just "anthropic/claude-sonnet-4-6"
              ConfigParseError _ err ->
                expectationFailure ("config.toml parse error: " <> T.unpack err)
              other ->
                expectationFailure ("Unexpected config load result: " <> show other)

            -- Phase B: Load the agent's AGENTS.md and verify system prompt
            -- TODO: Once PureClaw has an agent-loading pipeline, replace raw
            -- file reads with the structured loader (like Phase A does for config.toml).
            let agentPath = toDir </> "config" </> "agents" </> "coder" </> "AGENTS.md"
            agentExists <- doesFileExist agentPath
            agentExists `shouldBe` True
            agentContent <- T.unpack <$> TIO.readFile agentPath
            -- The system prompt text must survive the round-trip verbatim
            agentContent `shouldContain` "You are a coding assistant. Write clean, tested code."
            -- Verify the agent frontmatter has the right model and tool profile
            agentContent `shouldContain` "model: anthropic/claude-sonnet-4-6"
            agentContent `shouldContain` "tool_profile: coding"

    it "Test 2: SOUL.md identity survives import and produces correct system prompt" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"

        -- Create OpenClaw directory with SOUL.md in workspace
        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"agents\": {"
          , "    \"defaults\": {"
          , "      \"model\": \"anthropic/claude-opus-4-6\""
          , "    }"
          , "  }"
          , "}"
          ]
        let workspaceDir = fromDir </> "workspace"
        createDirectoryIfMissing True workspaceDir
        TIO.writeFile (workspaceDir </> "SOUL.md") $ T.unlines
          [ "# Name"
          , "Atlas"
          , ""
          , "# Description"
          , "A research assistant specializing in scientific literature."
          , ""
          , "# Instructions"
          , "Always cite your sources. Prefer peer-reviewed papers."
          , ""
          , "# Constraints"
          , "- Never fabricate citations"
          , "- Always indicate uncertainty"
          ]

        -- Run the importer
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            -- The importer should record the PureClaw workspace path (copy, not original)
            let expectedWs = toDir </> "workspace"
            _dir_workspacePath dir `shouldBe` Just expectedWs

            -- Load SOUL.md through PureClaw's identity pipeline from the copied location
            let soulPath = expectedWs </> "SOUL.md"
            ident <- loadIdentity soulPath
            ident `shouldNotBe` defaultIdentity

            -- Verify structured fields
            _ai_name ident `shouldBe` "Atlas"
            _ai_description ident `shouldBe` "A research assistant specializing in scientific literature."
            _ai_constraints ident `shouldBe` ["Never fabricate citations", "Always indicate uncertainty"]

            -- Verify the system prompt that would be sent to the LLM
            let sysPrompt = identitySystemPrompt ident
            T.unpack sysPrompt `shouldContain` "You are Atlas."
            T.unpack sysPrompt `shouldContain` "scientific literature"
            T.unpack sysPrompt `shouldContain` "cite your sources"
            T.unpack sysPrompt `shouldContain` "- Never fabricate citations"
            T.unpack sysPrompt `shouldContain` "- Always indicate uncertainty"

    it "Test 3: JSON5 + $include produces same LLM inputs as plain JSON" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        -- Directory A: plain JSON (reference)
        let fromA = tmpDir </> "openclaw-plain"
            toA   = tmpDir </> "pureclaw-plain"
        createDirectoryIfMissing True fromA
        TIO.writeFile (fromA </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"agents\": {"
          , "    \"defaults\": {"
          , "      \"model\": \"anthropic/claude-sonnet-4-6\""
          , "    },"
          , "    \"list\": ["
          , "      {"
          , "        \"id\": \"helper\","
          , "        \"systemPrompt\": \"You help with tasks.\","
          , "        \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" }"
          , "      }"
          , "    ]"
          , "  },"
          , "  \"channels\": {"
          , "    \"signal\": {"
          , "      \"account\": \"+15550001234\","
          , "      \"dmPolicy\": \"allowlist\","
          , "      \"allowFrom\": [\"+15559999999\"]"
          , "    }"
          , "  }"
          , "}"
          ]

        -- Directory B: JSON5 with comments, trailing commas, and $include
        let fromB = tmpDir </> "openclaw-json5"
            toB   = tmpDir </> "pureclaw-json5"
        createDirectoryIfMissing True fromB
        TIO.writeFile (fromB </> "openclaw.json") $ T.unlines
          [ "{"
          , "  // Main OpenClaw config with JSON5 features"
          , "  \"agents\": { \"$include\": \"./agents.json\" },"
          , "  \"channels\": {"
          , "    // Signal channel config"
          , "    \"signal\": {"
          , "      \"account\": \"+15550001234\","
          , "      \"dmPolicy\": \"allowlist\","
          , "      \"allowFrom\": [\"+15559999999\",]"
          , "    }"
          , "  }"
          , "}"
          ]
        TIO.writeFile (fromB </> "agents.json") $ T.unlines
          [ "{"
          , "  // Agent definitions split into separate file"
          , "  \"defaults\": {"
          , "    \"model\": \"anthropic/claude-sonnet-4-6\","
          , "  },"
          , "  \"list\": ["
          , "    {"
          , "      \"id\": \"helper\","
          , "      \"systemPrompt\": \"You help with tasks.\","
          , "      \"model\": { \"primary\": \"anthropic/claude-sonnet-4-6\" },"
          , "    },"
          , "  ]"
          , "}"
          ]

        -- Import both
        resultA <- importOpenClawDir fromA toA
        resultB <- importOpenClawDir fromB toB

        case (resultA, resultB) of
          (Left err, _) -> expectationFailure ("Plain import failed: " <> T.unpack err)
          (_, Left err) -> expectationFailure ("JSON5 import failed: " <> T.unpack err)
          (Right _, Right _) -> do
            -- Load both configs through PureClaw's TOML pipeline
            diagA <- loadFileConfigDiag (toA </> "config" </> "config.toml")
            diagB <- loadFileConfigDiag (toB </> "config" </> "config.toml")
            case (diagA, diagB) of
              (ConfigLoaded _ fcA, ConfigLoaded _ fcB) -> do
                -- Model must match
                _fc_model fcA `shouldBe` Just "anthropic/claude-sonnet-4-6"
                _fc_model fcB `shouldBe` _fc_model fcA

                -- Signal config must match
                let sigA = _fc_signal fcA
                    sigB = _fc_signal fcB
                sigA `shouldNotBe` Nothing
                sigA `shouldBe` sigB

                -- Agent files must match
                agentA <- TIO.readFile (toA </> "config" </> "agents" </> "helper" </> "AGENTS.md")
                agentB <- TIO.readFile (toB </> "config" </> "agents" </> "helper" </> "AGENTS.md")
                agentA `shouldBe` agentB
              (ConfigParseError _ err, _) ->
                expectationFailure ("Plain config.toml parse error: " <> T.unpack err)
              (_, ConfigParseError _ err) ->
                expectationFailure ("JSON5 config.toml parse error: " <> T.unpack err)
              (a, b) ->
                expectationFailure ("Unexpected results: " <> show a <> " / " <> show b)

    it "Test 4: Signal channel config round-trips through TOML pipeline" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"

        -- OpenClaw config with signal channel (camelCase keys)
        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"channels\": {"
          , "    \"signal\": {"
          , "      \"account\": \"+15550009876\","
          , "      \"dmPolicy\": \"allowlist\","
          , "      \"allowFrom\": [\"+15551111111\", \"+15552222222\"]"
          , "    }"
          , "  }"
          , "}"
          ]

        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right _ -> do
            -- Load through PureClaw's TOML pipeline — the real config loader
            diag <- loadFileConfigDiag (toDir </> "config" </> "config.toml")
            case diag of
              ConfigLoaded _ fc -> do
                let sig = _fc_signal fc
                sig `shouldNotBe` Nothing
                case sig of
                  Nothing -> expectationFailure "signal config missing"
                  Just s -> do
                    -- camelCase → snake_case applied by importer, then parsed by TOML codec
                    _fsc_account s `shouldBe` Just "+15550009876"
                    _fsc_dmPolicy s `shouldBe` Just "allowlist"
                    _fsc_allowFrom s `shouldBe` Just ["+15551111111", "+15552222222"]
              ConfigParseError _ err ->
                expectationFailure ("config.toml parse error: " <> T.unpack err)
              other ->
                expectationFailure ("Unexpected config load result: " <> show other)

    it "Test 5: multi-agent with different models produces distinct agent files" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"

        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"agents\": {"
          , "    \"defaults\": {"
          , "      \"model\": \"anthropic/claude-sonnet-4-6\""
          , "    },"
          , "    \"list\": ["
          , "      {"
          , "        \"id\": \"fast\","
          , "        \"systemPrompt\": \"Be brief and fast.\","
          , "        \"model\": { \"primary\": \"anthropic/claude-haiku-4-5\" },"
          , "        \"tools\": { \"profile\": \"minimal\" }"
          , "      },"
          , "      {"
          , "        \"id\": \"deep\","
          , "        \"systemPrompt\": \"Think carefully and thoroughly.\","
          , "        \"model\": { \"primary\": \"anthropic/claude-opus-4-6\" },"
          , "        \"tools\": { \"profile\": \"full\" }"
          , "      }"
          , "    ]"
          , "  }"
          , "}"
          ]

        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            -- Both agents should be listed in the result
            _ir_agentsWritten (_dir_configResult dir) `shouldBe` ["fast", "deep"]

            -- Load each agent's AGENTS.md and verify they are distinct
            let agentsDir = toDir </> "config" </> "agents"
            fastContent <- T.unpack <$> TIO.readFile (agentsDir </> "fast" </> "AGENTS.md")
            deepContent <- T.unpack <$> TIO.readFile (agentsDir </> "deep" </> "AGENTS.md")

            -- Agent files must be different
            fastContent `shouldNotBe` deepContent

            -- Fast agent: haiku model, minimal tools, brief prompt
            fastContent `shouldContain` "model: anthropic/claude-haiku-4-5"
            fastContent `shouldContain` "tool_profile: minimal"
            fastContent `shouldContain` "Be brief and fast."

            -- Deep agent: opus model, full tools, thorough prompt
            deepContent `shouldContain` "model: anthropic/claude-opus-4-6"
            deepContent `shouldContain` "tool_profile: full"
            deepContent `shouldContain` "Think carefully and thoroughly."

            -- Neither agent should contain the other's model or prompt
            fastContent `shouldNotContain` "opus"
            fastContent `shouldNotContain` "Think carefully and thoroughly."
            deepContent `shouldNotContain` "haiku"
            deepContent `shouldNotContain` "Be brief and fast."

    it "Test 6: workspace files are copied and loadable from PureClaw directory" $
      withSystemTempDirectory "pureclaw-e2e" $ \tmpDir -> do
        let fromDir = tmpDir </> "openclaw"
            toDir   = tmpDir </> "pureclaw"

        -- Create OpenClaw directory with workspace files
        createDirectoryIfMissing True fromDir
        TIO.writeFile (fromDir </> "openclaw.json") $ T.unlines
          [ "{"
          , "  \"agents\": {"
          , "    \"defaults\": { \"model\": \"anthropic/claude-sonnet-4-6\" }"
          , "  }"
          , "}"
          ]
        let wsDir = fromDir </> "workspace"
        createDirectoryIfMissing True wsDir
        TIO.writeFile (wsDir </> "SOUL.md") $ T.unlines
          [ "# Name"
          , "Rover"
          , ""
          , "# Description"
          , "A loyal coding companion."
          ]
        TIO.writeFile (wsDir </> "AGENTS.md") "Follow the project conventions.\n"
        TIO.writeFile (wsDir </> "MEMORY.md") "The user prefers Haskell.\n"
        TIO.writeFile (wsDir </> "USER.md") "Senior engineer, 10 years experience.\n"

        -- Run the importer
        result <- importOpenClawDir fromDir toDir
        case result of
          Left err -> expectationFailure (T.unpack err)
          Right dir -> do
            -- Workspace path should point to the PureClaw copy, not the original
            let expectedWs = toDir </> "workspace"
            _dir_workspacePath dir `shouldBe` Just expectedWs

            -- All four workspace files should exist in the PureClaw directory
            soulExists <- doesFileExist (expectedWs </> "SOUL.md")
            soulExists `shouldBe` True
            agentsExists <- doesFileExist (expectedWs </> "AGENTS.md")
            agentsExists `shouldBe` True
            memoryExists <- doesFileExist (expectedWs </> "MEMORY.md")
            memoryExists `shouldBe` True
            userExists <- doesFileExist (expectedWs </> "USER.md")
            userExists `shouldBe` True

            -- SOUL.md should be loadable through the identity pipeline from the new location
            ident <- loadIdentity (expectedWs </> "SOUL.md")
            ident `shouldNotBe` defaultIdentity
            _ai_name ident `shouldBe` "Rover"
            _ai_description ident `shouldBe` "A loyal coding companion."

            -- Other workspace files should have correct content
            agentsContent <- TIO.readFile (expectedWs </> "AGENTS.md")
            agentsContent `shouldBe` "Follow the project conventions.\n"
            memoryContent <- TIO.readFile (expectedWs </> "MEMORY.md")
            memoryContent `shouldBe` "The user prefers Haskell.\n"

            -- config.toml should reference the PureClaw workspace path
            configContent <- T.unpack <$> TIO.readFile (toDir </> "config" </> "config.toml")
            configContent `shouldContain` expectedWs
