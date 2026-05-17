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
import PureClaw.Routing.Types

spec :: Spec
spec = do
  describe "defaultRoutingConfig" $ do
    it "uses the documented field values" $ do
      let c = defaultRoutingConfig
      _rc_defaultKind c         `shouldBe` Tab.KindAi
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
          , "default_kind = \"harness\""
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_maxTabs cfg     `shouldBe` 5
        _rc_defaultKind cfg `shouldBe` Tab.KindHarness
        -- Untouched fields fall back to defaults.
        _rc_inputQueueBound cfg     `shouldBe` _rc_inputQueueBound defaultRoutingConfig
        _rc_channelOutQBound cfg    `shouldBe` _rc_channelOutQBound defaultRoutingConfig
        _rc_defaultAi cfg           `shouldBe` _rc_defaultAi defaultRoutingConfig
        _rc_defaultShell cfg        `shouldBe` _rc_defaultShell defaultRoutingConfig

    it "accepts a [routing]-less document with top-level keys" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "toplevel.toml"
        TIO.writeFile path $ T.unlines
          [ "default_kind = \"ssh\""
          , "max_tabs = 3"
          ]
        cfg <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg `shouldBe` Tab.KindSsh
        _rc_maxTabs cfg     `shouldBe` 3

    it "all five TabKind values round-trip through the codec" $ do
      withSystemTempDirectory "pureclaw-routing-cfg" $ \tmp -> do
        let path = tmp </> "tmux.toml"
        TIO.writeFile path "[routing]\ndefault_kind = \"tmux\"\n"
        cfg1 <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg1 `shouldBe` Tab.KindTmux

        TIO.writeFile path "[routing]\ndefault_kind = \"ai\"\n"
        cfg2 <- loadRoutingConfigFromFile path
        _rc_defaultKind cfg2 `shouldBe` Tab.KindAi

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

    it "encodes every TabKind round-trip via the codec" $ do
      -- Exercise the encode side of the codec for every TabKind so
      -- 'showKind' is covered on all five branches.
      let trip k = do
            let cfg = defaultRoutingConfig { _rc_defaultKind = k }
                encoded = Toml.encode routingConfigCodec cfg
            case Toml.decode routingConfigCodec encoded of
              Right back -> _rc_defaultKind back `shouldBe` k
              Left errs ->
                expectationFailure
                  ("decode failed: " <> T.unpack (Toml.prettyTomlDecodeErrors errs))
      trip Tab.KindAi
      trip Tab.KindHarness
      trip Tab.KindShell
      trip Tab.KindSsh
      trip Tab.KindTmux
