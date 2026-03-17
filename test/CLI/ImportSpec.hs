module CLI.ImportSpec (spec) where

import Data.Aeson
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
      stripJson5 input `shouldBe` "{\"a\": 1\n  }"

    it "does not strip commas before values" $ do
      let input = "{\"a\": 1, \"b\": 2}"
      stripJson5 input `shouldBe` input

    it "handles escaped quotes in strings" $ do
      let input = "{\"key\": \"value with \\\"quotes\\\"\"}"
      stripJson5 input `shouldBe` input

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
