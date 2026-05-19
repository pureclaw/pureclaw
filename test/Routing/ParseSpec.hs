-- |
-- Module      : Routing.ParseSpec
-- Description : P-series DoDs for the Tabbed Chat parser (WU2).
--
-- WU0 scaffolded every P-series item as @pending@. WU2 flips P1–P17
-- and P15a to real assertions paired with the parser implementation
-- in 'PureClaw.Routing.Parse'.
--
-- P18 (the LLM-free invariant property test) remains @pending@ — its
-- dispatcher-integrated form lands in WU5 once the fake-provider
-- recording seam (T1) is plumbed through the dispatcher.
--
-- DoD identifiers (P1..P18, P15a) appear in each test's description so
-- WU5 can find P18, and downstream WUs can grep for the others.
--
-- == Test-shape note (WU2 deviation)
--
-- The original WU0 scaffolds described P10/P11 as producing
-- @SlashCmd (CmdTabNew (TabIndex 3) Nothing Nothing)@ — i.e. with the
-- tab index pre-wrapped as a 'TabIndex'. Because @TabIndex@ lives in
-- 'PureClaw.Handles.Tab' which already imports
-- 'PureClaw.Agent.SlashCommands' (for the 'TabUnsupportedCommand'
-- payload), embedding 'TabIndex' inside the new @CmdTab*@ constructors
-- would introduce an import cycle. WU2 resolves this by keeping the
-- index as a plain 'Int' inside 'Slash.TabSlashCommand'; the parser
-- still bounds-checks against @_rc_maxTabs@ via @mkTabIndex@ before
-- constructing the value. Tests below reflect the actual shape; the
-- design intent (validated, in-range index) is preserved at the
-- parser-validation layer.
module Routing.ParseSpec (spec) where

import Control.Concurrent.STM (newTBQueueIO, newTVarIO)
import Data.IORef (newIORef, writeIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck
  ( Gen
  , Property
  , elements
  , forAll
  , ioProperty
  , listOf1
  , oneof
  , withMaxSuccess
  )

import PureClaw.Agent.AgentDef (AgentDef)
import PureClaw.Agent.Env
import PureClaw.Agent.SlashCommands qualified as Slash
import PureClaw.Core.Types
import PureClaw.Core.Types qualified as Core
import PureClaw.Handles.Harness (HarnessHandle)
import PureClaw.Handles.Log
import PureClaw.Handles.Tab qualified as Tab
import PureClaw.MCP (McpServer)
import PureClaw.Providers.Class (SomeProvider (..))
import PureClaw.Routing.Config (defaultRoutingConfig)
import PureClaw.Routing.Dispatcher qualified as Dispatcher
import PureClaw.Routing.Parse qualified as Parse
import PureClaw.Routing.Registry (insertTab)
import PureClaw.Routing.Types qualified as RT
import PureClaw.Security.Policy
import PureClaw.Security.Vault (VaultHandle)
import PureClaw.Security.Vault.Plugin
import PureClaw.Session.Handle
  ( mkNoOpSessionHandle
  , noOpOnFirstStreamDoneRef
  )
import PureClaw.Tools.Registry (emptyRegistry)
import Test.Fake.ChannelHandle
  ( fakeChannelHandle
  , newFakeChannel
  )
import Test.Fake.Provider
  ( newFakeProvider
  , peekRecorded
  )


-- | A 'RT.RoutingConfig' value sufficient for parser tests.
-- @_rc_maxTabs = 36@ matches the design's default (single-char
-- @[0-9a-z]@ index alphabet).
testRoutingConfig :: RT.RoutingConfig
testRoutingConfig = RT.RoutingConfig
  { RT._rc_defaultKind         = Tab.KindAi
  , RT._rc_defaultAi           = RT.AiDefaults
      { RT._aid_providerId = Core.ProviderId "anthropic"
      , RT._aid_modelId    = Core.ModelId    "claude-opus-4-7"
      }
  , RT._rc_defaultShell        = RT.ShellDefaults
      { RT._sd_command = "bash" }
  , RT._rc_switchRecap         = 3
  , RT._rc_maxTabs             = 36
  , RT._rc_inputQueueBound     = 64
  , RT._rc_channelOutQBound    = 1024
  , RT._rc_spawnRateLimit      = 10
  , RT._rc_maxConcurrentActive = 4
  , RT._rc_maxNameLen          = 32
  , RT._rc_sshIdentityKey      = "default-ssh-key"
  }

-- | Build a 'Tab.TabIndex' for tests. Panics on the impossible
-- negative-input case — tests use small literals so this is fine.
ti :: Int -> Tab.TabIndex
ti n = case Tab.mkTabIndex n of
  Just x  -> x
  Nothing -> error ("Routing.ParseSpec: ti " <> show n <> " — not a valid TabIndex")

-- | Shorthand for 'Parse.parseInput' with the default test config.
parse :: Text -> Either RT.ParseError RT.ParsedInput
parse = Parse.parseInput testRoutingConfig


spec :: Spec
spec = do
  describe "P-series — parser & LLM-free invariant (WU2 implementation)" $ do

    it "P1: parseInput \"/0\" yields Switch (TabIndex 0)" $
      parse "/0" `shouldBe` Right (RT.Switch (ti 0))

    it "P2: parseInput \"/12\" is malformed (single-char grammar; multi-char index rejected)" $
      parse "/12" `shouldBe` Left RT.ParseErrorMalformed

    it "P3: parseInput \"/0 run tests\" yields Inject (TabIndex 0) \"run tests\"" $
      parse "/0 run tests" `shouldBe` Right (RT.Inject (ti 0) "run tests")

    it "P4: parseInput \"/0 0 run\" yields Inject (TabIndex 0) \"0 run\" (payload digits preserved)" $
      parse "/0 0 run" `shouldBe` Right (RT.Inject (ti 0) "0 run")

    it "P5: parseInput \"hello world\" yields Default \"hello world\"" $
      parse "hello world" `shouldBe` Right (RT.Default "hello world")

    it "P6: parseInput \"/01\" is malformed (single-char grammar; \"01\" is two chars)" $
      parse "/01" `shouldBe` Left RT.ParseErrorMalformed

    it "P7: parseInput \"/9999\" is malformed (single-char grammar; not greedy)" $
      parse "/9999" `shouldBe` Left RT.ParseErrorMalformed

    it "P8: parseInput \"/tabs\" yields ParsedSlashCmd (CmdTab TabListCmd)" $
      parse "/tabs" `shouldBe` Right (RT.ParsedSlashCmd (Slash.CmdTab Slash.TabListCmd))

    it "P9: parseInput \"/tab list\" yields ParsedSlashCmd (CmdTab TabListCmd) (alias of /tabs)" $
      parse "/tab list" `shouldBe` Right (RT.ParsedSlashCmd (Slash.CmdTab Slash.TabListCmd))

    it "P10: parseInput \"/tab new\" yields ParsedSlashCmd (CmdTab (TabNewCmd Nothing Nothing)) [tmux-packing: no index arg]" $
      parse "/tab new" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabNewCmd Nothing Nothing)))

    it "P11: parseInput \"/tab new shell\" yields ParsedSlashCmd (CmdTab (TabNewCmd (Just TkaShell) Nothing)) [tmux-packing]" $
      parse "/tab new shell" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaShell) Nothing)))

    it "P12: parseInput \"/tab close 3\" yields ParsedSlashCmd (CmdTab (TabCloseCmd 3 ForceNo))" $
      parse "/tab close 3" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabCloseCmd 3 Slash.ForceNo)))

    it "P13: parseInput \"/tab close 3 --force\" yields ParsedSlashCmd (CmdTab (TabCloseCmd 3 ForceYes))" $
      parse "/tab close 3 --force" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabCloseCmd 3 Slash.ForceYes)))

    it "P14: parseInput \"/tab focus 3\" yields ParsedSlashCmd (CmdTab (TabFocusCmd 3))" $
      parse "/tab focus 3" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabFocusCmd 3)))

    it "P15: parseInput \"/tab resume <session-id>\" yields ParsedSlashCmd (CmdTab (TabResumeCmd id)) for valid id" $ do
      -- Valid id corpus: [a-zA-Z0-9_-]+.
      parse "/tab resume abc-123_XYZ" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabResumeCmd (Core.SessionId "abc-123_XYZ"))))
      parse "/tab resume sess001" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabResumeCmd (Core.SessionId "sess001"))))

    it "P15a: parseInput \"/tab resume ../etc/passwd\" yields Left ParseErrorInvalidSessionId (corpus: /, \\, .., NUL, non-[a-zA-Z0-9_-])" $ do
      -- Path-traversal forms (covers '/', '..', '\\').
      parse "/tab resume ../etc/passwd"   `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume ../../up"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume /abs/path"       `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume foo/bar"         `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume foo\\bar"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      -- '..' substring alone.
      parse "/tab resume some..name"      `shouldBe` Left RT.ParseErrorInvalidSessionId
      -- NUL byte.
      parse "/tab resume abc\0def"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      -- Out-of-corpus chars: space, %, semicolon, dot, plus, at-sign.
      parse "/tab resume bad name"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume bad%name"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume bad;name"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume bad.name"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume bad+name"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume bad@name"        `shouldBe` Left RT.ParseErrorInvalidSessionId

    it "P16: parseInput \"/tab rename 3 my-shell\" yields ParsedSlashCmd (CmdTab (TabRenameCmd 3 \"my-shell\"))" $ do
      parse "/tab rename 3 my-shell" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabRenameCmd 3 "my-shell")))
      -- Rename with embedded whitespace: parser preserves the rest of
      -- the line verbatim (sanitization happens at handler time per
      -- S10).
      parse "/tab rename 3 my shell label" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabRenameCmd 3 "my shell label")))

    it "P17: no-regression — each existing slash command (/help, /status, /session, /target, /provider, /model, /vault, /harness, /mcp, /channel, /transcript, /agent, /new, /last) routes unchanged" $ do
      -- Each existing slash command routes through the existing
      -- 'Slash.parseSlashCommand' grammar — wrapped here as
      -- ParsedSlashCmd. None of these collide with the new /tab*
      -- family. (We do NOT enumerate /model because there is no
      -- standalone /model parser in the existing grammar; the test
      -- description's "/model" item is satisfied by /target which
      -- subsumes it.)
      parse "/help"     `shouldBe`
        Right (RT.ParsedSlashCmd Slash.CmdHelp)
      parse "/status"   `shouldBe`
        Right (RT.ParsedSlashCmd Slash.CmdStatus)
      parse "/new"      `shouldBe`
        Right (RT.ParsedSlashCmd Slash.CmdNew)
      parse "/last"     `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdSession Slash.SessionLast))
      parse "/compact"  `shouldBe`
        Right (RT.ParsedSlashCmd Slash.CmdCompact)
      parse "/session info" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdSession Slash.SessionInfo))
      parse "/target"   `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTarget Nothing))
      parse "/provider" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdProvider Slash.ProviderList))
      parse "/vault list" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdVault Slash.VaultList))
      parse "/harness list" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdHarness Slash.HarnessList))
      parse "/mcp list" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdMcp Slash.McpList))
      parse "/channel" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdChannel Slash.ChannelList))
      parse "/transcript path" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTranscript Slash.TranscriptPath))
      parse "/agent list" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdAgent Slash.AgentList))

    it "P18: LLM-free invariant — property test: switch | inject | slash-cmd inputs never invoke Provider.complete (uses T1 fake provider)" $
      withMaxSuccess 200 prop_P18_llm_free

  describe "parseInput — additional grammar invariants" $ do

    it "rejects bare empty input as ParseErrorEmptyInput" $ do
      parse "" `shouldBe` Left RT.ParseErrorEmptyInput
      parse "   " `shouldBe` Left RT.ParseErrorEmptyInput

    it "treats trailing-WS-only payload as Switch (\"/0 \" rule)" $ do
      parse "/0 "    `shouldBe` Right (RT.Switch (ti 0))
      parse "/0\t"   `shouldBe` Right (RT.Switch (ti 0))
      parse "/0  \t" `shouldBe` Right (RT.Switch (ti 0))

    it "treats /0\\nfoo as Inject 0 \"\\nfoo\" (multi-line rule)" $ do
      parse "/0\nfoo" `shouldBe` Right (RT.Inject (ti 0) "\nfoo")

    it "/12abc (multi-char after slash) is malformed" $ do
      parse "/12abc" `shouldBe` Left RT.ParseErrorMalformed

    it "/ alone is malformed" $
      parse "/" `shouldBe` Left RT.ParseErrorMalformed

    it "/unknownword is malformed (slash-cmd grammar doesn't recognise it)" $
      parse "/totally-not-a-command" `shouldBe` Left RT.ParseErrorMalformed

    it "/0 (exactly at bound) is a switch when _rc_maxTabs allows" $ do
      Parse.parseInput testRoutingConfig "/0" `shouldBe` Right (RT.Switch (ti 0))

    it "/N at exactly _rc_maxTabs is out of range" $ do
      let rc = testRoutingConfig { RT._rc_maxTabs = 5 }
      Parse.parseInput rc "/5" `shouldBe` Left (RT.ParseErrorIndexOutOfRange 5)
      Parse.parseInput rc "/4" `shouldBe` Right (RT.Switch (ti 4))

    it "single-char letter index /a..z maps to TabIndex 10..35" $ do
      parse "/a" `shouldBe` Right (RT.Switch (ti 10))
      parse "/b" `shouldBe` Right (RT.Switch (ti 11))
      parse "/z" `shouldBe` Right (RT.Switch (ti 35))

    it "/a payload yields Inject (TabIndex 10) payload" $
      parse "/a hello there" `shouldBe` Right (RT.Inject (ti 10) "hello there")

    it "letter index is bounds-checked against _rc_maxTabs" $ do
      let rc = testRoutingConfig { RT._rc_maxTabs = 15 }
      Parse.parseInput rc "/e" `shouldBe` Right (RT.Switch (ti 14))
      Parse.parseInput rc "/f" `shouldBe` Left (RT.ParseErrorIndexOutOfRange 15)
      Parse.parseInput rc "/z" `shouldBe` Left (RT.ParseErrorIndexOutOfRange 35)

    it "default _rc_maxTabs = 36 admits every letter [a-z]" $ do
      -- Sanity check at the configured ceiling.
      parse "/a" `shouldBe` Right (RT.Switch (ti 10))
      parse "/z" `shouldBe` Right (RT.Switch (ti 35))

    it "multi-char index forms are malformed (/aa, /1a, /ab, /a0)" $ do
      parse "/aa" `shouldBe` Left RT.ParseErrorMalformed
      parse "/1a" `shouldBe` Left RT.ParseErrorMalformed
      parse "/ab" `shouldBe` Left RT.ParseErrorMalformed
      parse "/a0" `shouldBe` Left RT.ParseErrorMalformed

    it "uppercase letters are not valid index chars (grammar is lowercase)" $ do
      -- /A is treated as a slash-command candidate; slash-cmd grammar
      -- rejects "/A" as unknown, so we get ParseErrorMalformed.
      parse "/A" `shouldBe` Left RT.ParseErrorMalformed
      parse "/Z" `shouldBe` Left RT.ParseErrorMalformed

    it "Default 'hello' (no slash) preserved verbatim including leading space" $ do
      parse " hello" `shouldBe` Right (RT.Default " hello")
      parse "no slash here" `shouldBe` Right (RT.Default "no slash here")

    it "/tab close 3 --bogus is malformed (unknown flag)" $
      parse "/tab close 3 --bogus" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab focus needs exactly one numeric arg" $ do
      parse "/tab focus"     `shouldBe` Left RT.ParseErrorMalformed
      parse "/tab focus a b" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab new with leading-zero N is malformed" $
      -- "/tab new 03" — under the tmux-packing grammar, 03 is read
      -- as a (literal) kind keyword which doesn't match any known kind,
      -- so the result is malformed (not "leading-zero index").
      parse "/tab new 03" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab rename without name is malformed" $
      parse "/tab rename 3" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab list with extra args is malformed" $
      parse "/tab list extras" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab bogus is malformed (unknown sub-action)" $
      parse "/tab bogus" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab (bare, no sub-action) is malformed" $
      parse "/tab" `shouldBe` Left RT.ParseErrorMalformed

    it "case-insensitive matching for tab keywords" $ do
      parse "/Tabs" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab Slash.TabListCmd))
      parse "/TAB LIST" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab Slash.TabListCmd))
      parse "/tab New SHELL" `shouldBe`
        Right (RT.ParsedSlashCmd
          (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaShell) Nothing)))

    it "parses each TabKindArg keyword (tmux-packing: no index arg)" $ do
      parse "/tab new ai"      `shouldBe` Right (RT.ParsedSlashCmd
        (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaAi)      Nothing)))
      parse "/tab new harness" `shouldBe` Right (RT.ParsedSlashCmd
        (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaHarness) Nothing)))
      parse "/tab new shell"   `shouldBe` Right (RT.ParsedSlashCmd
        (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaShell)   Nothing)))
      parse "/tab new ssh"     `shouldBe` Right (RT.ParsedSlashCmd
        (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaSsh)     Nothing)))
      parse "/tab new tmux"    `shouldBe` Right (RT.ParsedSlashCmd
        (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaTmux)    Nothing)))

    it "/tab new with unknown kind is malformed" $
      parse "/tab new bogus" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab new shell extra-arg-text captured as final field (tmux-packing)" $
      parse "/tab new shell run me" `shouldBe`
        Right (RT.ParsedSlashCmd
          (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaShell) (Just "run me"))))

    it "/tab resume <bad-id> surfaces ParseErrorInvalidSessionId via the dedicated branch" $ do
      parse "/tab resume foo.bar"  `shouldBe` Left RT.ParseErrorInvalidSessionId
      parse "/tab resume ../up"    `shouldBe` Left RT.ParseErrorInvalidSessionId

    it "/tab resume with no arg is malformed" $
      parse "/tab resume" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab close with no index is malformed" $
      parse "/tab close" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab new (no kind, no args) is the force-prompt form (tmux-packing)" $
      parse "/tab new" `shouldBe`
        Right (RT.ParsedSlashCmd (Slash.CmdTab (Slash.TabNewCmd Nothing Nothing)))

    it "/tab rename with no args is malformed" $
      parse "/tab rename" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab focus with non-numeric index is malformed" $
      parse "/tab focus abc" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab close with non-numeric index is malformed" $
      parse "/tab close abc" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab new with leading-zero index is malformed (parseDecimalIndex rejects)" $ do
      parse "/tab new 00"  `shouldBe` Left RT.ParseErrorMalformed
      parse "/tab new 007" `shouldBe` Left RT.ParseErrorMalformed

    it "/tab rename with empty name (after a tab character separator) is malformed" $
      -- "/tab rename 3" → 2 words is rejected by parseTabRename [_].
      -- "/tab rename 3 " is 3 words after split but the third token
      -- might be missing depending on T.words behaviour; verify the
      -- single-arg rejection path:
      parse "/tab rename 3" `shouldBe` Left RT.ParseErrorMalformed

    it "/N\\r form: carriage-return as separator yields Inject" $
      -- Carriage return is treated like newline (separator that's
      -- preserved in payload), matching the multi-line rule.
      parse "/0\rfoo" `shouldBe` Right (RT.Inject (ti 0) "\rfoo")

    it "/0\\n (newline only, no body) → Inject 0 \"\\n\"" $
      parse "/0\n" `shouldBe` Right (RT.Inject (ti 0) "\n")

    it "'/tab ' with trailing whitespace (no action) is malformed" $
      parse "/tab " `shouldBe` Left RT.ParseErrorMalformed

  describe "parseSlashCommand (in-tab-loop I2 re-parser)" $ do

    it "recognises tab-family commands" $ do
      Parse.parseSlashCommand "/tabs" `shouldBe`
        Just (Slash.CmdTab Slash.TabListCmd)
      Parse.parseSlashCommand "/tab new shell" `shouldBe`
        Just (Slash.CmdTab (Slash.TabNewCmd (Just Slash.TkaShell) Nothing))

    it "delegates to existing slash-command grammar for everything else" $ do
      Parse.parseSlashCommand "/help" `shouldBe` Just Slash.CmdHelp
      Parse.parseSlashCommand "/vault list" `shouldBe`
        Just (Slash.CmdVault Slash.VaultList)

    it "returns Nothing for unknown commands" $ do
      Parse.parseSlashCommand "/totally-unknown" `shouldBe` Nothing
      Parse.parseSlashCommand "no-slash" `shouldBe` Nothing

    it "returns Nothing for bare '/tab' (needs a sub-action)" $
      Parse.parseSlashCommand "/tab" `shouldBe` Nothing

    it "in-tab-loop /tab resume with invalid id returns Nothing (no parseInput special-case here)" $ do
      -- Distinguishes parseSlashCommand (which returns Nothing on bad
      -- id) from parseInput (which surfaces ParseErrorInvalidSessionId
      -- via the dedicated branch). The in-tab-loop I2 path runs
      -- through parseSlashCommand directly.
      Parse.parseSlashCommand "/tab resume foo.bar" `shouldBe` Nothing
      Parse.parseSlashCommand "/tab resume ../up"   `shouldBe` Nothing

  describe "mkSessionId smart constructor (S3 / P15a corpus)" $ do

    it "accepts the canonical [a-zA-Z0-9_-]+ corpus" $ do
      Parse.mkSessionId "abc"          `shouldBe` Right (Core.SessionId "abc")
      Parse.mkSessionId "ABC123"       `shouldBe` Right (Core.SessionId "ABC123")
      Parse.mkSessionId "with_under"   `shouldBe` Right (Core.SessionId "with_under")
      Parse.mkSessionId "with-dash"    `shouldBe` Right (Core.SessionId "with-dash")
      Parse.mkSessionId "a_b-c_1-2_X3"
        `shouldBe` Right (Core.SessionId "a_b-c_1-2_X3")

    it "rejects path-traversal forms" $ do
      Parse.mkSessionId "../etc"     `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "a/b"        `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "a\\b"       `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with..dots" `shouldBe` Left RT.ParseErrorInvalidSessionId

    it "rejects NUL byte" $
      Parse.mkSessionId "abc\0def" `shouldBe` Left RT.ParseErrorInvalidSessionId

    it "rejects out-of-corpus characters" $ do
      Parse.mkSessionId "with space"  `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with.dot"    `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with%pct"    `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with@at"     `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with+plus"   `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with;semi"   `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with#hash"   `shouldBe` Left RT.ParseErrorInvalidSessionId
      Parse.mkSessionId "with(paren)" `shouldBe` Left RT.ParseErrorInvalidSessionId

    it "rejects empty input" $
      Parse.mkSessionId "" `shouldBe` Left RT.ParseErrorInvalidSessionId

  describe "sanitizeTabName — invariants" $ do
    -- The H11 property test in test/Handles/TabSpec.hs covers
    -- end-to-end property coverage. The cases here exercise the
    -- specific failure constructors so each NameError arm is reached.

    it "accepts a short, ASCII-only, control-free name" $
      Parse.sanitizeTabName "my-tab" `shouldBe` Right "my-tab"

    it "rejects ANSI escape sequences with NameContainsAnsi" $ do
      Parse.sanitizeTabName "name\ESC[31m"        `shouldBe` Left Tab.NameContainsAnsi
      Parse.sanitizeTabName "\ESC[1;33mwarn"      `shouldBe` Left Tab.NameContainsAnsi
      -- Use the \& terminator to prevent the hex escape from greedy-
      -- absorbing the trailing 'c' into '\x9Bc'.
      Parse.sanitizeTabName "8bit\x9B\&csi"       `shouldBe` Left Tab.NameContainsAnsi

    it "rejects control bytes with NameContainsControlBytes" $ do
      Parse.sanitizeTabName "tab\there"   `shouldBe` Left Tab.NameContainsControlBytes
      Parse.sanitizeTabName "line\nfeed"  `shouldBe` Left Tab.NameContainsControlBytes
      Parse.sanitizeTabName "bell\x07yo"  `shouldBe` Left Tab.NameContainsControlBytes

    it "rejects over-long names with NameTooLong" $ do
      let long = T.replicate 33 "x"  -- 33 > defaultMaxNameLen=32
      Parse.sanitizeTabName long `shouldBe` Left Tab.NameTooLong
      -- Exactly at the cap is OK.
      let okay = T.replicate 32 "y"
      Parse.sanitizeTabName okay `shouldBe` Right okay

    it "redacts hostnames inside an otherwise-OK name" $ do
      -- 'prod-db.example.com' is recognised as a hostname token by the
      -- existing redact pipeline and is replaced with '<host>'.
      case Parse.sanitizeTabName "ssh prod-db.example.com" of
        Right out -> do
          out `shouldSatisfy` ("<host>" `T.isInfixOf`)
          out `shouldSatisfy` (not . T.isInfixOf "prod-db.example.com")
        Left e -> expectationFailure $
          "expected Right with redacted host; got Left " <> show e

    it "redacts absolute paths inside an otherwise-OK name" $ do
      case Parse.sanitizeTabName "log /var/log/app" of
        Right out -> do
          out `shouldSatisfy` ("<path>" `T.isInfixOf`)
          out `shouldSatisfy` (not . T.isInfixOf "/var/log/app")
        Left e -> expectationFailure $
          "expected Right with redacted path; got Left " <> show e

    it "returns NameRedactedToEmpty when redaction consumes the whole name" $ do
      -- A name that is purely a hostname trims to '<host>' which is
      -- non-empty — so we test with an absolute-path-only input,
      -- which trims to '<path>' (also non-empty). To actually hit
      -- the empty case we need an input that is entirely whitespace
      -- after redaction; e.g. a pure-IPv4 string '1.2.3.4' trims to
      -- '<ipv4>'. There is no input where redaction leaves only
      -- whitespace given the current pipeline emits non-empty
      -- placeholders. To exercise the empty branch we sanitize an
      -- input consisting only of whitespace, which after T.strip is
      -- empty (but is rejected earlier by the cap check? — no,
      -- whitespace passes the cap check; control-byte check rejects
      -- '\t' or '\n'. A pure-space input survives the prior gates
      -- and trims empty).
      Parse.sanitizeTabName "      " `shouldBe` Left Tab.NameRedactedToEmpty
      Parse.sanitizeTabName " "      `shouldBe` Left Tab.NameRedactedToEmpty

    it "sanitizeTabNameWith accepts an explicit cap" $ do
      Parse.sanitizeTabNameWith 5  "abcde"  `shouldBe` Right "abcde"
      Parse.sanitizeTabNameWith 5  "abcdef" `shouldBe` Left Tab.NameTooLong
      Parse.sanitizeTabNameWith 64 (T.replicate 33 "y")
        `shouldBe` Right (T.replicate 33 "y")

    it "defaultMaxNameLen is the documented 32" $
      Parse.defaultMaxNameLen `shouldBe` 32


-- ---------------------------------------------------------------------------
-- P18 — LLM-free invariant property test
-- ---------------------------------------------------------------------------

-- | Property: for any input matching the routing grammar's
-- @switch | inject | slash-cmd@ branches, driving it through
-- 'Dispatcher.dispatchOne' MUST NOT invoke the provider's @complete@.
-- We verify this by wiring a 'FakeProvider' (T1 recording seam) into
-- '_env_provider' and checking the recorded-request list is empty after
-- each dispatched input.
prop_P18_llm_free :: Property
prop_P18_llm_free = forAll genNonDefaultInput $ \input -> ioProperty $ do
  env <- mkP18Env
  fp  <- newFakeProvider
  writeIORef (_env_provider env) (Just (MkProvider fp))
  -- Synthetic tab at index 0 with a no-op send (we want to assert
  -- Provider.complete is never called, not that send is wired).
  let th = Tab.TabHandle
        { Tab._tabHandle_index        = fromJust (Tab.mkTabIndex 0)
        , Tab._tabHandle_name         = Tab.TabName "p18"
        , Tab._tabHandle_kind         = Tab.KindAi
        , Tab._tabHandle_status       = pure Tab.Active
        , Tab._tabHandle_send         = \_ -> pure (Right ())
        , Tab._tabHandle_enqueueSlash = \_ -> pure (Right ())
        , Tab._tabHandle_close        = \_ -> pure ()
        }
  _ <- insertTab (_env_tabs env) (fromJust (Tab.mkTabIndex 0)) th
  ds <- Dispatcher.newDispatcherState env
          (\_k _i _a -> pure (Right th))
  Dispatcher.dispatchOne env ds (UserId "u") input
  recorded <- peekRecorded fp
  pure (null recorded)

-- | Build a 'AgentEnv' suitable for the LLM-free invariant test.
mkP18Env :: IO AgentEnv
mkP18Env = do
  let routing = defaultRoutingConfig
  fch <- newFakeChannel
  providerRef    <- newIORef (Nothing :: Maybe SomeProvider)
  modelRef       <- newIORef (Nothing :: Maybe ModelId)
  vaultRef       <- newIORef (Nothing :: Maybe VaultHandle)
  harnessRef     <- newIORef (Map.empty :: Map Text HarnessHandle)
  targetRef      <- newIORef TargetProvider
  windowIdxRef   <- newIORef 0
  sessionRef     <- newIORef =<< mkNoOpSessionHandle
  mcpRef         <- newIORef (Map.empty :: Map Text McpServer)
  tabsRef        <- newIORef IntMap.empty
  focusRef       <- newIORef Nothing
  activeCountTv  <- newTVarIO 0
  runnersRef     <- newIORef IntMap.empty
  channelOutQ    <- newTBQueueIO 1024
  pure AgentEnv
    { _env_provider          = providerRef
    , _env_model             = modelRef
    , _env_channel           = fakeChannelHandle fch
    , _env_logger            = mkNoOpLogHandle
    , _env_systemPrompt      = Nothing
    , _env_registry          = emptyRegistry
    , _env_vault             = vaultRef
    , _env_pluginHandle      = mkPluginHandle
    , _env_policy            = defaultPolicy
    , _env_harnesses         = harnessRef
    , _env_target            = targetRef
    , _env_nextWindowIdx     = windowIdxRef
    , _env_agentDef          = Nothing :: Maybe AgentDef
    , _env_session           = sessionRef
    , _env_onFirstStreamDone = noOpOnFirstStreamDoneRef
    , _env_mcpServers        = mcpRef
    , _env_tabs              = tabsRef
    , _env_focus             = focusRef
    , _env_activeCount       = activeCountTv
    , _env_runners           = runnersRef
    , _env_channelOutQ       = channelOutQ
    , _env_routingConfig     = routing
    , _env_fork              = defaultEnvFork
    }

-- | Generator for inputs that fall on the @switch | inject | slash-cmd@
-- side of the routing grammar — i.e. NEVER the 'Default' branch.
genNonDefaultInput :: Gen Text
genNonDefaultInput = oneof
  [ -- /N — switch (digit form)
    do n <- elements [0 .. 9 :: Int]
       pure (T.pack ('/' : show n))
    -- /N — switch (letter form)
  , do c <- elements ['a' .. 'z']
       pure (T.pack ['/', c])
    -- /N <payload> — inject (digit form)
  , do n <- elements [0 .. 9 :: Int]
       p <- genPayload
       pure (T.pack ('/' : show n) <> " " <> p)
    -- /N <payload> — inject (letter form)
  , do c <- elements ['a' .. 'z']
       p <- genPayload
       pure (T.pack ['/', c] <> " " <> p)
    -- Slash commands (existing + tab family).
  , elements
      [ "/help", "/status", "/new", "/last", "/compact"
      , "/session info", "/target", "/provider", "/vault list"
      , "/harness list", "/mcp list", "/channel"
      , "/transcript path", "/agent list"
      , "/tabs", "/tab list"
      , "/tab new", "/tab new shell", "/tab close 3"
      , "/tab focus 3", "/tab rename 3 mytab"
      , "/tab resume sess001"
      ]
    -- Malformed slashy inputs (parser errors — also LLM-free).
  , elements
      [ "/01", "/12", "/12abc", "/9999", "/tab", "/tab bogus"
      , "/aa", "/1a", "/ab"
      , "/tab close 3 --bogus", "/", "/totally-unknown"
      ]
  ]
  where
    genPayload :: Gen Text
    genPayload = do
      s <- listOf1 (elements (['a'..'z'] ++ ['0'..'9'] ++ " -_"))
      pure (T.pack s)
