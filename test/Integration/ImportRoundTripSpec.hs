module Integration.ImportRoundTripSpec (spec) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

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
