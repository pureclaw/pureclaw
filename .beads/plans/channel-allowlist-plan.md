---
title: Channel allow-list enforcement + open-allow-list warning
status: draft round 2 — pending plan-review-gate
date_drafted: 2026-05-31
scope_channels: [Signal, Telegram]
---

# Implementation Plan — Channel allow-list enforcement + "no allow-list" warning (round 2)

**Round 1 → 2 changes** (addressing all three FAIL verdicts):
- Pure helpers move to `Core.Types` (alongside `AllowList`/`isAllowed`); only the
  IO emit shim lives in the new `PureClaw.Channels.AllowList` module. *(Scope #2)*
- Telegram warning moves OUT of `mkTelegramChannel` into a new `withTelegramChannel`
  boot wrapper mirroring `withSignalChannel` — no test-construction noise. *(Scope #1, Completeness #2)*
- Banner → **stdout** (matches the existing `PureClaw 0.1.0` startup banner via `putStrLn`);
  WARN log line → stderr via `_lh_logWarn`. *(Scope #3)*
- Exact Signal wiring point specified; `import PureClaw.Channels.Telegram` added to Commands.hs. *(Feasibility #2,#4)*
- `receiveUpdate` semantics pinned: blocked updates consumed+discarded, `_tch_lastChat`
  updated ONLY after auth passes. *(Feasibility #5, Completeness #5)*
- Username matching explicitly OUT of scope (numeric IDs only); config comment fixed. *(Completeness #4)*
- Added unit tests for `resolveSignalConfig` (3 AllowAll sub-cases) + `resolveTelegramConfig`. *(Feasibility #3, Completeness #3,#6)*
- Construction-site count corrected to **7**. *(Feasibility #1)*
- Docs update added (`docs/SECURITY_PRACTICES.md`). *(Completeness #7)*

## Problem

Every remote communications channel must let the user restrict which sender
user/chat IDs it accepts messages from. When a channel has **no** allow-list
configured it must still accept messages but display a **prominent startup
warning** — a visually distinct multi-line banner to the console **and** a
WARN-level log line.

Current state:
- **Signal** carries `_sc_allowFrom :: AllowList UserId` and enforces it in
  `readerLoop` (drop + WARN). But the AllowAll case (missing/empty `allow_from`,
  or `dm_policy="open"`) is silent — no warning.
- **Telegram** parses `allow_from`/`dm_policy` into `FileTelegramConfig` but never
  enforces them; `TelegramConfig` has no allow-list field.
- **Telegram has no live CLI boot path**: `effectiveChannel` (Commands.hs:754)
  handles only `"signal"`/`"cli"`. Telegram receives via external webhook push to
  its inbox; wiring that (gateway) is out of scope per product decision. Therefore
  Telegram enforcement + warning are implemented at the channel's activation
  boundary so they are correct and tested, and a future gateway boot path inherits
  them. **This is an explicit, accepted limitation (see Out of scope).**

## Product decisions (confirmed with user)
1. Scope: **Signal + Telegram only** (CLI local/trusted; gateway webhook out of scope).
2. No allow-list → **warn but still accept** (do not fail closed).
3. Warning surface → **multi-line banner to console (stdout) AND a WARN log line (stderr)**.

## Design

### Pure helpers — added to `PureClaw.Core.Types` (next to `AllowList`/`isAllowed`)
```haskell
-- | True when the list permits every sender (no restriction configured).
allowListOpen :: AllowList a -> Bool
allowListOpen AllowAll      = True
allowListOpen (AllowList _) = False

-- | Banner lines + WARN log line for an OPEN allow-list on the named channel,
--   or Nothing when senders are restricted. Pure ⇒ fully unit-testable.
allowListWarning :: Text -> AllowList a -> Maybe ([Text], Text)
```
No new imports in Core.Types (Text already in scope). Kept pure: no `LogHandle`/IO,
so Core.Types stays a leaf domain module.

### IO shim — new module `PureClaw.Channels.AllowList`
Imports `Core.Types` (pure helpers) + `Handles.Log`. Houses ONLY the IO emit:
```haskell
-- | When the list is open: write banner lines to @h@ and emit the WARN log line.
--   No-op otherwise. @h@ injectable so tests capture to a temp-file Handle
--   (no `System.IO.Silently` dependency).
emitAllowListWarning :: Handle -> LogHandle -> Text -> AllowList a -> IO ()
emitAllowListWarning h lh name al = case allowListWarning name al of
  Nothing               -> pure ()
  Just (banner, logMsg) -> do mapM_ (TIO.hPutStrLn h) banner; _lh_logWarn lh logMsg

-- | Convenience for live call sites: banner to stdout (matches the existing
--   `PureClaw 0.1.0` startup banner), log to stderr via the LogHandle.
warnIfOpenAllowList :: LogHandle -> Text -> AllowList a -> IO ()
warnIfOpenAllowList = emitAllowListWarning stdout
```
*Rationale (for reviewers):* the IO shim is deliberately NOT in Core.Types (keeps
Core.Types free of IO/LogHandle) and NOT a Handle record (so not under Handles/).
It is a shared **channel-startup** concern used by both the Signal boot wiring and
`withTelegramChannel`, hence `Channels/`.

Banner copy (exact text finalized in impl):
```
============================================================
  ⚠  SECURITY WARNING: <Channel> has NO allow-list configured
  It will accept messages from ANY sender.
  Add `allow_from = ["<id>", ...]` under [<channel>] in
  config.toml to restrict who may message this agent.
============================================================
```

### Telegram enforcement (`Channels/Telegram.hs`)
- Add `_tc_allowFrom :: AllowList UserId` to `TelegramConfig`. New field ⇒
  `-Wincomplete-record-updates`/`-Werror` forces updating **all 7** construction
  sites in `test/Channels/TelegramSpec.hs` (lines 27, 102, 125, 164, 180, 195, 208).
  Set each to a closed `AllowList` matching that test's sender so existing receive
  tests still pass. `mkTelegramChannel` stays warning-free (no test noise).
- New `withTelegramChannel :: TelegramConfig -> NetworkHandle -> LogHandle ->
  (ChannelHandle -> IO a) -> IO a`, mirroring `withSignalChannel`:
  emits `warnIfOpenAllowList lh "Telegram" (_tc_allowFrom config)` then
  `mkTelegramChannel … >>= \tc -> action (toHandle tc)`. **This is the warning's
  single home** — fires whenever Telegram is activated; a future gateway boot
  routes through it.
- `receiveUpdate` becomes a filter loop:
  - Read one update (blocking `readTQueue` — consumes it from the inbox).
  - `userId = show (from.id)`, `chatId = chat.id`. Allowed iff
    `isAllowed policy (UserId userId) || isAllowed policy (UserId (show chatId))`
    (dual user/chat check; **numeric IDs only — usernames unsupported**).
  - **Type-reuse note (Scope #5):** chat IDs are matched by wrapping them in the
    `UserId` newtype, the same way Signal wraps both phone number and UUID. This is
    an *intentional conflation for access-control matching* — the allow-list gates
    "may this message in?" against any sender-or-conversation identifier, not "who
    exactly is this". A code comment at the check site and the `_ftc_allowFrom` config
    comment will state this explicitly (a numeric `allow_from` entry matches whether it
    is a user ID or a chat ID — acceptable, the goal is gating not disambiguation). No
    separate `ChatId` newtype is introduced (would add scope without changing behavior).
  - Allowed → update `_tch_lastChat`, return the `IncomingMessage`.
  - Not allowed → `_lh_logWarn` "Blocked message from unauthorized sender
    (telegram user <id>, chat <id>)", do **NOT** touch `_tch_lastChat`, **recurse**
    to read the next update. The blocked update is consumed and discarded
    (mirrors Signal's drop-and-log). `AllowAll` ⇒ everyone passes.

### Config (`CLI/Config.hs`)
- Fix `_ftc_allowFrom` doc comment: "Allowed **numeric user IDs or chat IDs**
  (usernames not supported)". No code change to the codec.

### Config resolution + Signal wiring (`CLI/Commands.hs`)
- Add `import PureClaw.Channels.Telegram` (TelegramConfig currently not imported).
- `resolveTelegramConfig :: FileConfig -> TelegramConfig`, mirroring
  `resolveSignalConfig`: `dm_policy="open"` → `AllowAll`; missing/empty
  `allow_from` → `AllowAll`; else `AllowList (Set.fromList (map UserId users))`.
  `_tc_apiBase = "https://api.telegram.org"`, `_tc_botToken` from `_ftc_botToken`
  (default `""`).
- Signal warning wiring: in the `"signal"` branch, **immediately after**
  `let sigCfg = resolveSignalConfig fileCfg` (Commands.hs:756) and **before** the
  signal-cli `try` block (line 758), insert:
  `warnIfOpenAllowList logger "Signal" (_sc_allowFrom sigCfg)`.
  Fires regardless of whether signal-cli is installed.

## Work units (TDD; red→green→refactor each; commit failing test first)

**WU1 — pure helpers + IO shim**
- RED: `test/Channels/AllowListSpec.hs` — `allowListOpen` both cases;
  `allowListWarning` open→`Just` (banner non-empty; log line contains channel
  name + "allow-list") and closed→`Nothing`; `emitAllowListWarning` open→writes
  banner to a temp-file Handle (read back + assert) and logs WARN (recording
  LogHandle), closed→no output, no log.
- GREEN: add pure helpers to `Core.Types` (+ export list); create
  `Channels/AllowList.hs` (+ export list); register both modules in `pureclaw.cabal`.

**WU2 — Telegram enforcement + boot wrapper**
- RED: `test/Channels/TelegramSpec.hs` — allowed-by-user passes; allowed-by-chat
  passes; unauthorized dropped+logged and a following authorized update is the one
  returned (loop); `AllowAll` passes everyone; unauthorized does NOT change
  `lastChat` (assert send targets the last *authorized* chat); `withTelegramChannel`
  with open list writes banner (temp Handle via `emitAllowListWarning`) + WARN,
  closed list silent, handle usable.
- GREEN: add `_tc_allowFrom`; update all 7 construction sites; implement
  `receiveUpdate` filter loop; add `withTelegramChannel` (export it).

**WU3 — config resolution + Signal live warning + docs**
- RED: `test/CLI/CommandsSpec.hs` — `resolveTelegramConfig` (open / missing
  table / missing allow_from / empty list / populated list) and `resolveSignalConfig`
  (the 3 AllowAll sub-cases: `dm_policy="open"`, missing `allow_from`, empty list;
  plus populated list). `test/Integration/CLISpec.hs` — starting with a Signal
  config lacking `allow_from` prints the banner on **stdout** and a WARN on
  **stderr** (signal-cli absent in CI ⇒ branch still runs the warning).
- GREEN: add **both** `import PureClaw.Channels.Telegram` (for `TelegramConfig`) **and
  `import PureClaw.Channels.AllowList`** (for `warnIfOpenAllowList`) to Commands.hs;
  implement `resolveTelegramConfig`; insert the `warnIfOpenAllowList` call at
  Commands.hs:757; fix `_ftc_allowFrom` comment; add an `allow_from` example +
  warning explanation to `docs/SECURITY_PRACTICES.md`.

## Coverage strategy (100% lines/branches/functions/statements)
- `allowListOpen`, `allowListWarning`, `resolveTelegramConfig`, `resolveSignalConfig`
  — every branch via direct unit tests.
- `emitAllowListWarning` — both branches via temp-file Handle + recording LogHandle.
- `warnIfOpenAllowList` (stdout partial application) — CLISpec Signal integration test.
- `withTelegramChannel` — open + closed paths via unit test.
- `receiveUpdate` loop — allowed-user / allowed-chat / dropped-then-allowed /
  AllowAll / lastChat-not-updated-on-block.

## Production-dormant code — accepted trade-off (Scope #6, Option B)

`withTelegramChannel` and `resolveTelegramConfig` have **no production caller** in
this change because Telegram has no live boot path (it receives via webhook, and
gateway wiring is out of scope per the user's decision). The plan-review-gate flagged
this as YAGNI. We deliberately choose **Option B (build the seams now, justified)**
rather than dropping Telegram, because:
- The user **explicitly confirmed scope = Signal + Telegram** for *both* requirements
  (allow-list configurability AND the no-list warning). Dropping Telegram contradicts
  that decision; a warning that can never be displayed contradicts the requirement.
- The two additions are **minimal seams**, not heavy infrastructure: `withTelegramChannel`
  is ~5 lines mirroring `withSignalChannel`; `resolveTelegramConfig` is ~10 lines
  mirroring `resolveSignalConfig`. They are the exact, idiomatic points the future
  gateway boot path will call — building them now avoids rework and keeps the
  enforcement + warning **correct, tested, and ready** the moment Telegram is wired.
- They are **fully unit-tested** (not untested dead code): `withTelegramChannel` open/closed
  paths and `resolveTelegramConfig` branches are exercised directly, satisfying 100% coverage.
- Both are exported (`-Wmissing-export-lists`); their tests are the public consumers, so
  no `-Wunused-top-binds` warning arises.

This is the unavoidable consequence of the user's own "include Telegram, gateway out of
scope" decision and is surfaced to the user when the plan is presented.

## Out of scope (explicitly accepted)
- CLI channel allow-list (local/trusted operator).
- Gateway `/webhook` userId enforcement.
- Building a live Telegram runtime / webhook→inbox routing → consequently the
  Telegram warning + enforcement are exercised by tests and ready at the
  `withTelegramChannel` boundary but have **no production caller until the gateway
  boot path is built**. resolveTelegramConfig likewise has no production caller yet.
- Telegram **username** allow-listing (numeric user/chat IDs only). `from.username`
  is not currently parsed; matching it would require extending `TelegramUser`/JSON.

## Files touched
- `src/PureClaw/Core/Types.hs` — pure helpers + exports
- NEW `src/PureClaw/Channels/AllowList.hs` — IO emit shim
- `src/PureClaw/Channels/Telegram.hs` — `_tc_allowFrom`, `withTelegramChannel`, `receiveUpdate` filter
- `src/PureClaw/CLI/Config.hs` — `_ftc_allowFrom` comment fix
- `src/PureClaw/CLI/Commands.hs` — import Telegram, `resolveTelegramConfig`, Signal warning wiring
- `pureclaw.cabal` — register `Channels.AllowList` (lib) + `AllowListSpec` (test)
- `docs/SECURITY_PRACTICES.md` — allow_from examples + warning behavior
- NEW `test/Channels/AllowListSpec.hs`
- `test/Channels/TelegramSpec.hs`, `test/CLI/CommandsSpec.hs`, `test/Integration/CLISpec.hs`
