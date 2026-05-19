-- |
-- Module      : PureClaw.Routing.Onboarding
-- Description : User-facing onboarding for Tabbed Chat
--               (Issue #51, WU11, O-series).
--
-- Owns the user-discoverable surface area introduced by Tabbed Chat:
--
--   * @\/start@ handler ('handleStart') — Telegram's onboarding
--     convention. Emits a single-message orientation that names the
--     three principal slash-prefix surfaces users need to know about:
--     @\/0@ (the first tab once spawned), @\/tab new shell@ (allocate
--     a shell tab at the next free slot), and @\/tabs@ (dashboard).
--     The message is sent via 'ChannelHandle' @_ch_send@ which works
--     on every channel implementation (CLI, Signal, Telegram).
--     Non-Telegram channels degrade gracefully — they receive the same
--     orientation text even though they have no BotFather autocomplete
--     behind the @\/start@ keyword (O1).
--
--   * @\/help@ \"Tab commands\" subsection ('helpTabSection') — pure
--     text appended by @executeSlashCommand env CmdHelp@ in
--     "PureClaw.Agent.SlashCommands" so users see the new vocabulary
--     enumerated alongside the existing slash commands (O2). The
--     subsection is intentionally lightweight; the full per-command
--     reference still lives in the existing command-spec table.
--
--   * BotFather command registration list ('botFatherCommandList') —
--     the @(command, description)@ tuples Telegram's @setMyCommands@
--     API consumes at channel-startup time. Pinning this as a top-
--     level pure binding lets the O3 test compare it against the
--     golden enumeration in @docs\/tabbed-chat.md@ without spinning
--     up a live channel (O3).
--
-- == Design constraints (per WU11 spec)
--
--   * The module imports only 'AgentEnv', 'ChannelHandle', and 'Text'
--     so it can be imported safely by 'PureClaw.Agent.SlashCommands'
--     (which owns 'CmdStart' and the @\/help@ renderer) without
--     dragging in the dispatcher or any tab factory.
--   * 'handleStart' is non-blocking and has no side effects beyond
--     a single channel emit. It does NOT spawn a tab, mutate
--     '_env_focus', or touch '_env_tabs' — those flows are owned by
--     'PureClaw.Routing.Dispatcher' \/ 'PureClaw.Routing.AutoSpawn'
--     and trigger automatically on the user's next slash command.
--   * No 'forkIO'. The handler runs synchronously on the caller's
--     thread (the dispatcher thread when invoked via
--     'PureClaw.Routing.Dispatcher.dispatchSlash', or whatever thread
--     "PureClaw.Agent.SlashCommands" runs on for the legacy single-
--     tab execution path).
--
-- See @docs\/tabbed-chat.md@ §\"Onboarding (O-series)\" for the
-- normative DoDs (O1, O2, O3).
module PureClaw.Routing.Onboarding
  ( -- * @\/start@ handler
    handleStart
  , onboardingMessage
    -- * @\/help@ subsection (consumed by Agent.SlashCommands)
  , helpTabSection
    -- * BotFather command registration (consumed by Channels.Telegram)
  , botFatherCommandList
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import PureClaw.Agent.Env (AgentEnv (..))
import PureClaw.Handles.Channel (ChannelHandle (..), OutgoingMessage (..))


-- ---------------------------------------------------------------------------
-- /start handler (O1)
-- ---------------------------------------------------------------------------

-- | Handle the @\/start@ slash command. Emits the orientation message
-- ('onboardingMessage') via the channel's @_ch_send@ once.
--
-- O1 requires the response to include:
--
--   * a one-line value prop,
--   * @\/0@ (the first tab once spawned),
--   * @\/tab new shell@ (the shell-tab allocation form),
--   * @\/tabs@ (the dashboard alias).
--
-- All four are baked into 'onboardingMessage' so the @\/start@ output
-- is a fixed, golden-comparable string the test can assert verbatim
-- substrings against.
--
-- == Channel portability
--
-- Per the WU11 spec, non-Telegram channels @degrade gracefully@: they
-- still receive the orientation text. The implementation uses only
-- 'ChannelHandle' @_ch_send@ which every channel implements, so
-- nothing special is required for CLI \/ Signal — the user just sees
-- the same help text Telegram users see, minus the BotFather
-- autocomplete affordance.
handleStart :: AgentEnv -> IO ()
handleStart env =
  _ch_send (_env_channel env) (OutgoingMessage onboardingMessage)

-- | The fixed orientation message delivered by 'handleStart'.
--
-- Authored as a single 'Text' so the O1 test can assert against
-- specific substrings without re-deriving them from a builder.
-- Mentions all three slash-prefix surfaces explicitly (value prop,
-- @\/0@, @\/tab new shell@, @\/tabs@). The @\/N@ shortcut accepts
-- any single digit @0-9@ or lowercase letter @a-z@ (36 tabs total).
--
-- Tabs follow a tmux-style packing model: they always occupy the
-- lowest slots, so the first tab is always at @\/0@ and closing tab N
-- renumbers the rest. The orientation copy mentions this so users
-- don't expect to pick a slot themselves.
onboardingMessage :: Text
onboardingMessage = T.intercalate "\n"
  [ "Welcome to PureClaw."
  , ""
  , "Tabbed Chat lets you drive multiple agents from one chat thread."
  , ""
  , "Quick start:"
  , "  hello there        \x2014 just type to talk (an AI tab is auto-spawned)"
  , "  /tab new shell     \x2014 open a shell tab at the next free slot"
  , "  /0                 \x2014 switch focus to tab 0 (must already exist)"
  , "  /tabs              \x2014 list your tabs"
  , ""
  , "Tabs are always packed in the lowest slots; closing tab N"
  , "renumbers the rest (tmux-style)."
  , ""
  , "Tab shortcut /N accepts any digit 0-9 or lowercase letter a-z"
  , "(36 tabs total). /N only works for tabs that already exist \x2014"
  , "use /tab new to create one."
  , ""
  , "See /help for the full command reference."
  ]


-- ---------------------------------------------------------------------------
-- /help "Tab commands" subsection (O2)
-- ---------------------------------------------------------------------------

-- | The @Tab commands@ subsection appended to @\/help@ output by
-- 'PureClaw.Agent.SlashCommands.renderHelpText'. Pure text so the O2
-- assertion can pin the literal substrings @\"Tab commands\"@ and
-- @\"\/tabs\"@ verbatim.
--
-- The format mirrors the existing @\/help@ group layout — two-space
-- indented heading followed by a four-space-indented body — so the
-- subsection visually merges with the surrounding renderer output.
--
-- All Tab-Chat verbs enumerated per O2: @\/N@, @\/N \<payload\>@,
-- @\/tabs@, @\/tab new@, @\/tab close@, @\/tab focus@, @\/tab resume@,
-- @\/tab rename@.
--
-- The leading-line note documents the @\/N@ grammar (single char,
-- digit @0-9@ or lowercase letter @a-z@; 36 tabs maximum).
helpTabSection :: Text
helpTabSection = T.intercalate "\n"
  [ ""
  , "  Tab commands (N is one char: digit 0-9 or letter a-z; 36 tabs max):"
  , "  Tabs are tmux-style packed: they always occupy the lowest slots;"
  , "  closing tab N renumbers the rest down by one."
  , "    /N                          Switch focus to tab N (error if missing)"
  , "    /N <payload>                Direct-inject payload to tab N (focus unchanged)"
  , "    /tabs                       List all tabs (alias of /tab list)"
  , "    /tab new [<kind>]           Open a new tab at the next free slot (kinds: ai, harness, shell, ssh, tmux)"
  , "    /tab close <N> [--force]    Close tab N (--force skips archive on AI tabs); remaining tabs renumber"
  , "    /tab focus <N>              Switch focus to tab N (alias of /N)"
  , "    /tab resume <session-id>    Resume an archived session into a new tab"
  , "    /tab rename <N> <name>      Rename tab N (input is sanitized)"
  ]


-- ---------------------------------------------------------------------------
-- BotFather command registration list (O3)
-- ---------------------------------------------------------------------------

-- | The @(command, description)@ tuples PureClaw's Telegram channel
-- registers with BotFather (via the Telegram @setMyCommands@ API) at
-- channel-startup time.
--
-- Pinning this as a top-level pure value lets the O3 test compare it
-- against the golden enumeration in
-- @docs\/tabbed-chat.md@ §\"Channel autocomplete (Telegram-specific)\"
-- without spinning up a live channel.
--
-- The 36 single-char tab-switch shortcuts (@\/0@..@\/9@, @\/a@..@\/z@)
-- are emitted in their full glory because Telegram's
-- @setMyCommands@ API permits up to 100 entries per bot and visible
-- autocomplete on mobile is the primary discovery affordance for the
-- @\/N@ grammar. The 36 + 3 long-form entries fit comfortably under
-- the limit (39 total).
--
-- Per O3 the descriptions are:
--
--   * @\/0@..@\/9@, @\/a@..@\/z@ → @\"Switch to tab N\"@
--   * @\/tab@      → @\"Tabs: new, list, close, focus, resume, rename\"@
--   * @\/tabs@     → @\"List all tabs\"@
--   * @\/start@    → @\"Tabbed Chat \x2014 see \/help for tab commands\"@
--
-- The tuples are recorded in declaration order so the test asserts a
-- stable list (rather than a set) — the user-visible BotFather
-- ordering is part of the contract.
botFatherCommandList :: [(Text, Text)]
botFatherCommandList =
  [ (cmd, "Switch to tab N")
  | n <- [0 .. 9 :: Int]
  , let cmd = T.pack ('/' : show n)
  ]
  ++
  [ (T.pack ['/', c], "Switch to tab N")
  | c <- ['a' .. 'z']
  ]
  ++
  [ ("/tab",   "Tabs: new, list, close, focus, resume, rename")
  , ("/tabs",  "List all tabs")
  , ("/start", "Tabbed Chat \x2014 see /help for tab commands")
  ]
