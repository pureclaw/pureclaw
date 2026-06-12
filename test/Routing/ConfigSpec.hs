-- |
-- Module      : Routing.ConfigSpec
-- Description : Coverage-focused tests for PureClaw.Routing.Config (WU3).
--
-- Exercises the TOML loader paths (missing file, malformed TOML,
-- top-level keys, [routing] sub-table, partial overlay onto defaults)
-- and the round-tripping codec, satisfying the 95% coverage threshold
-- for 'PureClaw.Routing.Config'.
module Routing.ConfigSpec (spec) where

import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Toml qualified

import PureClaw.Core.Types (ModelId (..), ProviderId (..))
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.Routing.Config
import PureClaw.Session.Kind qualified as SK
import PureClaw.Routing.Types

spec :: Spec
spec = do
  describe "defaultRoutingConfig" $ do
    it "uses the documented field values" $ do
      let c = defaultRoutingConfig
      _rc_defaultKind c         `shouldBe`
        Tab.TkSession (SK.SkProvider (SK.ProviderSpec
          (ProviderId "anthropic")
          (ModelId "claude-sonnet-4-5")
          Nothing))
      _aid_providerId (_rc_defaultAi c) `shouldBe` ProviderId "anthropic"
      _aid_modelId    (_rc_defaultAi c) `shouldBe` ModelId "claude-sonnet-4-5"
      _sd_command     (_rc_defaultShell c) `shouldBe` "bash"
      _rc_switchRecap c         `shouldBe` 3
      _rc_maxTabs c             `shouldBe` 36
      _rc_inputQueueBound c     `shouldBe` 64
      _rc_channelOutQBound c    `shouldBe` 1024
      _rc_spawnRateLimit c      `shouldBe` 10
      _rc_maxConcurrentActive c `shouldBe` 4
      _rc_maxNameLen c          `shouldBe` 32
      _rc_sshIdentityKey c      `shouldBe` "default-ssh-key"
      _rc_maxPureClawDepth c    `shouldBe` 2
      _rc_pureClawDepth c       `shouldBe` 0

  describe "loadRoutingConfigFromFile" $ do
    it "returns defaultRoutingConfig when the file is missing" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "absent.toml"
        cfg <- loadRoutingConfigFromFile path
        cfg `shouldBe` defaultRoutingConfig

    it "returns defaultRoutingConfig when the TOML is unparseable" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "bad.toml"
        TIO.writeFile path "this is not valid TOML ((("
        cfg <- loadRoutingConfigFromFile path
        cfg `shouldBe` defaultRoutingConfig

    it "loads a [routing] sub-table with all fields populated" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "full.toml"
        TIO.writeFile path $ T.unlines
          [ "[routing]"
          , "default_kind = \"shell\""
          , "switch_recap = 7"
          , "max_tabs = 12"
          , "input_queue_bound = 128"
          , "channel_out_q_bound = 2048"
          , "spawn_rate_limit = 25"
          , "max_concurrent_active = 8"
          , "max_name_len = 64"
          , "ssh_identity_key = \"prod-ssh\""
          , ""
          , "[routing.default_ai]"
          , "provider = \"openai\""
          , "model    = \"gpt-4\""
          , ""
          , "[routing.default_shell]"
          , "command = \"zsh\""
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg         `shouldBe` Tab.KindShell
        _rc_switchRecap cfg         `shouldBe` 7
        _rc_maxTabs cfg             `shouldBe` 12
        _rc_inputQueueBound cfg     `shouldBe` 128
        _rc_channelOutQBound cfg    `shouldBe` 2048
        _rc_spawnRateLimit cfg      `shouldBe` 25
        _rc_maxConcurrentActive cfg `shouldBe` 8
        _rc_maxNameLen cfg          `shouldBe` 64
        _rc_sshIdentityKey cfg      `shouldBe` "prod-ssh"
        _aid_providerId (_rc_defaultAi cfg) `shouldBe` ProviderId "openai"
        _aid_modelId    (_rc_defaultAi cfg) `shouldBe` ModelId "gpt-4"
        _sd_command     (_rc_defaultShell cfg) `shouldBe` "zsh"

    it "loads a partial [routing] section and fills the rest from defaults" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "partial.toml"
        TIO.writeFile path $ T.unlines
          [ "[routing]"
          , "max_tabs = 5"
          , "default_kind = \"shell\""
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_maxTabs cfg     `shouldBe` 5
        _rc_defaultKind cfg `shouldBe` Tab.TkRawShell SK.TbLocal
        -- Untouched fields fall back to defaults.
        _rc_inputQueueBound cfg     `shouldBe` _rc_inputQueueBound defaultRoutingConfig
        _rc_channelOutQBound cfg    `shouldBe` _rc_channelOutQBound defaultRoutingConfig
        _rc_defaultAi cfg           `shouldBe` _rc_defaultAi defaultRoutingConfig
        _rc_defaultShell cfg        `shouldBe` _rc_defaultShell defaultRoutingConfig
        -- WU-9: depth fields fall through to defaults when absent in TOML
        _rc_maxPureClawDepth cfg    `shouldBe` _rc_maxPureClawDepth defaultRoutingConfig
        _rc_pureClawDepth cfg       `shouldBe` 0

    it "rejects unsupported kinds (harness/ssh/tmux) and falls back to defaults" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "harness.toml"
        TIO.writeFile path "[routing]\ndefault_kind = \"harness\"\n"
        cfg1 <- loadRoutingConfigFromFile path
        cfg1 `shouldBe` defaultRoutingConfig

        TIO.writeFile path "[routing]\ndefault_kind = \"ssh\"\n"
        cfg2 <- loadRoutingConfigFromFile path
        cfg2 `shouldBe` defaultRoutingConfig

        TIO.writeFile path "[routing]\ndefault_kind = \"tmux\"\n"
        cfg3 <- loadRoutingConfigFromFile path
        cfg3 `shouldBe` defaultRoutingConfig

    it "loads max_pureclaw_depth from TOML" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "depth.toml"
        TIO.writeFile path $ T.unlines
          [ "[routing]"
          , "max_pureclaw_depth = 5"
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_maxPureClawDepth cfg `shouldBe` 5
        -- pureClawDepth is CLI-only and always 0 from TOML
        _rc_pureClawDepth cfg    `shouldBe` 0

    it "accepts a [routing]-less document with top-level keys" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "toplevel.toml"
        TIO.writeFile path $ T.unlines
          [ "default_kind = \"shell\""
          , "max_tabs = 3"
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg `shouldBe` Tab.TkRawShell SK.TbLocal
        _rc_maxTabs cfg     `shouldBe` 3

    it "ai and shell round-trip through the TOML codec" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "kind.toml"
        -- "ai" round-trips; the ProviderSpec comes from defaultAiDefaults.
        TIO.writeFile path "[routing]\ndefault_kind = \"ai\"\n"
        cfg1 <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg1 `shouldBe`
          Tab.TkSession (SK.SkProvider (SK.ProviderSpec
            (ProviderId "anthropic")
            (ModelId "claude-sonnet-4-5")
            Nothing))

        -- "shell" round-trips exactly.
        TIO.writeFile path "[routing]\ndefault_kind = \"shell\"\n"
        cfg2 <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg2 `shouldBe` Tab.TkRawShell SK.TbLocal

    it "rejects an unknown tab kind by falling back to defaults" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "unknown.toml"
        TIO.writeFile path "[routing]\ndefault_kind = \"nonsense\"\n"
        cfg <- loadRoutingConfigFromFile path
        cfg `shouldBe` defaultRoutingConfig

  describe "loadRoutingConfig (default location)" $ do
    it "treats a non-existent pureclawDir/config.toml as missing" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        cfg <- loadRoutingConfig tmp
        cfg `shouldBe` defaultRoutingConfig

    it "reads pureclawDir/config.toml when present" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        TIO.writeFile (tmp </> "config.toml") $ T.unlines
          [ "[routing]"
          , "max_tabs = 99"
          ]
        cfg <- loadRoutingConfig tmp
        _rc_maxTabs cfg `shouldBe` 99

  describe "routingConfigCodec round-trip" $ do
    it "encode . decode == id on defaultRoutingConfig" $ do
      let encoded = Toml.encode routingConfigCodec defaultRoutingConfig
      case Toml.decode routingConfigCodec encoded of
        Right back -> back `shouldBe` defaultRoutingConfig
        Left errs -> expectationFailure
          ("decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors errs))

    it "encodes ai and shell TabKind round-trip via the codec" $ do
      -- Only "ai" and "shell" can round-trip through the TOML codec.
      -- Harness/ssh/tmux require structured payloads that cannot be
      -- represented as a single TOML string.
      let tripExact k = do
            let cfg = defaultRoutingConfig { _rc_defaultKind = k }
                encoded = Toml.encode routingConfigCodec cfg
            case Toml.decode routingConfigCodec encoded of
              Right back -> _rc_defaultKind back `shouldBe` k
              Left errs ->
                expectationFailure
                  ("decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors errs))
      -- "shell" round-trips exactly.
      tripExact (Tab.TkRawShell SK.TbLocal)
      -- "ai" round-trip normalizes ProviderSpec to the config default.
      let aiCfg = defaultRoutingConfig
            { _rc_defaultKind =
                Tab.TkSession (SK.SkProvider (SK.ProviderSpec
                  (ProviderId "anthropic")
                  (ModelId "claude-sonnet-4-5")
                  Nothing))
            }
          encoded = Toml.encode routingConfigCodec aiCfg
      case Toml.decode routingConfigCodec encoded of
        Right back -> _rc_defaultKind back `shouldBe`
          Tab.TkSession (SK.SkProvider (SK.ProviderSpec
            (ProviderId "anthropic")
            (ModelId "claude-sonnet-4-5")
            Nothing))
        Left errs ->
          expectationFailure
            ("ai decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors errs))

    it "showKind encodes all TabKind variants to the correct string" $ do
      -- Exercises all branches of showKind for coverage, including kinds
      -- that cannot round-trip through parseKind.
      let encodeKind k =
            let cfg = defaultRoutingConfig { _rc_defaultKind = k }
            in Toml.encode routingConfigCodec cfg
          containsKindStr expected encoded =
            T.isInfixOf ("\"" <> expected <> "\"") encoded
              `shouldBe` True
      containsKindStr "ai"
        (encodeKind (Tab.TkSession (SK.SkProvider (SK.ProviderSpec
          (ProviderId "anthropic") (ModelId "claude-sonnet-4-5") Nothing))))
      containsKindStr "harness"
        (encodeKind (Tab.TkSession (SK.SkHarness (SK.HarnessSpec
          SK.HClaudeCode SK.TbLocal Nothing [] Nothing Nothing Nothing))))
      containsKindStr "shell"
        (encodeKind (Tab.TkRawShell SK.TbLocal))
      containsKindStr "ssh"
        (encodeKind (Tab.TkRawShell (SK.TbSsh (SK.SshConfig "" "" Nothing))))
      containsKindStr "tmux"
        (encodeKind (Tab.TkRawShell (SK.TbTmux (SK.TmuxConfig "" "" Nothing))))
      case SK.mkContainerTarget "test-container" of
        Right ct -> containsKindStr "container"
          (encodeKind (Tab.TkRawShell (SK.TbContainer
            (SK.ContainerSpec SK.Docker ct))))
        Left _ -> expectationFailure "mkContainerTarget failed on valid input"
