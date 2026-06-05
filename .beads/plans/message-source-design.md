# Design: Persist Message Source / Origin (beads pureclaw-dte)

> **Status:** Design Review Gate PASSED with corrections folded in (this is v3).
> Round-1 verdicts: PM ✅ APPROVE · Designer ✅ APPROVE · Security ✅ APPROVE ·
> Architect ⚠️ REQUEST_CHANGES · CTO ⚠️ REQUEST_CHANGES. All Architect/CTO blockers were
> accuracy/blast-radius corrections (caller counts, site counts, coverage target,
> `completeStream` path) — now incorporated below, with Security's broadcast/normalization
> corrections. A fresh session should re-confirm Architect+CTO on this v3, then proceed to
> the Plan Review Gate. Issue id is **pureclaw-dte**.

## Problem

Session transcripts don't record **where a message came from**. Channels already extract a
sender at the boundary (`IncomingMessage._im_userId :: UserId`,
`src/PureClaw/Handles/Channel.hs:20`), but the agent loop (`src/PureClaw/Agent/Loop.hs:186`,
`stripped = T.strip (_im_content msg)`) keeps only the content and discards the sender. For
Signal/Telegram DMs — the common case — we want the channel's user id (phone / UUID /
Telegram id) recorded, future-proof for channels that carry significantly more data.

## User decisions (gathered up front)

- **Storage:** BOTH — `session.json` (session origin, DM case) and `transcript.jsonl`
  (per-message sender).
- **Model:** Structured + future-proof — must hold "whatever the channel needs."
- **Future channels:** Extensible now — typed tag for known channels + open escape hatch.

## Core type — in `PureClaw.Core.Types` (NOT a new module)

`Core.Types` already imports `Data.Aeson` (line 27) and exports `UserId` (line 46); it is a
leaf module everyone already imports, so no cycle with `Session.Types` / `Transcript.Types`
/ `Channels.*`, and no new cabal/test stanza. Add `import Data.Map.Strict (Map)`.

```haskell
data ChannelKind
  = CkCli | CkWeb | CkSignal | CkTelegram | CkBackground
  | CkOther !Text
  deriving stock (Show, Eq, Generic)

data MessageSource = MessageSource
  { _ms_channel :: !ChannelKind
  , _ms_userId  :: !(Maybe UserId)
  , _ms_fields  :: !(Map Text Aeson.Value)   -- extensible; nested JSON allowed
  } deriving stock (Show, Eq, Generic)
```

**Exports:** add `ChannelKind(..)`, `MessageSource(..)`, `mkMessageSource`,
`channelKindToText`, `channelKindFromText`, `maxSourceLen` to the explicit `Core.Types`
export list (the module has one; `-Wmissing-export-lists` is NOT actually in the cabal flags
despite CLAUDE.md, so don't rely on it to catch a forgotten export).

### ChannelKind JSON — uniform flat string (mirrors `flavourToText`)

Mirrors the `flavourToText`/`HCustom n = n` precedent (`Session/Types.hs:121-129`). Encode as
a plain string, never a string/object union:

```haskell
channelKindToText   :: ChannelKind -> Text   -- CkSignal -> "signal", CkOther n -> n
channelKindFromText :: Text -> ChannelKind   -- "signal" -> CkSignal, else CkOther t
```

`channelKindFromText` maps known names to constructors, all else to `CkOther` — so
`CkOther "signal"` can't round-trip into existence (shadowing guard).

### MessageSource JSON — snake_case keys, hand-written codec

```json
{ "channel": "signal", "user_id": "+15551234567", "fields": { "uuid": "..." } }
```

snake_case keys (`channel`/`user_id`/`fields`); `user_id`/`fields` omitted when
`Nothing`/empty (tolerant `.:?` decode). Write `ToJSON`/`FromJSON` by hand (do NOT derive
Generic — `Maybe`/`Map` omission + flat-string encoding need manual `.:?`/`.!=`; serialize
`_ms_userId` via `unUserId`, like `SessionMeta` hand-writes `AgentName`). The **same codec**
is reused in `session.json` and `transcript.jsonl` metadata — one parser for both.

### Smart constructor — normalize attacker-controlled input

```haskell
mkMessageSource :: ChannelKind -> Maybe UserId -> Map Text Aeson.Value -> MessageSource
```

Normalizes: strips ASCII control chars / newlines and bounds length (`maxSourceLen = 512`)
on the user id **and on every string value inside `_ms_fields`** (Telegram `username`/
`first_name` are attacker-controlled free text, `Telegram.hs:185`), and folds
`CkOther "signal"` → `CkSignal`. Aeson already escapes on encode (JSONL integrity does not
depend on this — it's defense-in-depth for non-Aeson paths, `/status`, and logs). Channels
construct via `mkMessageSource`, never the raw record.

### Invariants

- `_ms_fields` MUST NOT duplicate `_ms_userId` (supplementary data only).
- `_ms_fields` MUST NEVER contain credentials/secrets (persisted to disk verbatim).
- `MessageSource` derives normal `Show` (user ids are PII, not secrets — consistent with
  `UserId`) but MUST NOT be embedded in **any error value surfaced to a channel or WS
  client** — broader than just `PublicError` (covers `sendSignalError` `show`,
  `Signal.hs:148`, and the WS `escapeHandler` `show`, `Stream.hs:510-515`).
- `_sm_source` / `metadata.source` is **unauthenticated, attacker-asserted provenance** and
  MUST NOT feed any access-control / trust decision. Routing keeps keying on `imUserId`
  against the allow-list (`Dispatcher.hs:1077`), unchanged.

## Change 1 — capture the source at the channel boundary (WU2)

Add `_im_source :: MessageSource` to `IncomingMessage` (`Handles/Channel.hs:19`). Populate
each channel via `mkMessageSource`:

- **CLI:** `CkCli`, `Just (UserId "cli-user")`.
- **Signal:** `CkSignal`, userId = `_se_source`; `fields += {"uuid": …}` when
  `_se_sourceUuid` present.
- **Telegram:** `CkTelegram`, userId = numeric id; `fields += {"chat_id": …}` (and
  `username` when present).
- **noOp** (`Channel.hs:67`): `CkOther "noop"`, `Nothing`.
- **Web / background:** `CkWeb` / `CkBackground`, `Nothing` (no channel user — explicitly
  valid `Nothing` + fields shape).

`_im_userId :: UserId` is **replaced** by `_im_source`. **Reader audit (corrected):**
`Loop.hs` never reads `_im_userId` (it reads only `_im_content`); the **sole src reader is
`Routing/Dispatcher.hs:1077`** (`dispatchOne … (_im_userId msg) …`). Preserve it with an
accessor:

```haskell
imUserId :: IncomingMessage -> UserId   -- fromMaybe (UserId "") (_ms_userId (_im_source m))
```

Note `imUserId` returns the `UserId ""` sentinel for `_ms_userId = Nothing` — the same value
noOp produced before, so dispatcher behavior is preserved (confirm an empty `UserId` never
matches a populated allow-list entry in `dispatchOne`). **Blast radius (WU2):**
`Handles/Channel.hs` (def + noOp), `Channels/CLI.hs:34`, `Channels/Signal.hs:132`,
`Channels/Telegram.hs:94`, `Routing/Dispatcher.hs:1077`, and tests:
`Handles/ChannelSpec.hs:14,34`, `Channels/ClassSpec.hs:28,36`, `Channels/SignalSpec.hs:43`,
`Channels/TelegramSpec.hs:44`, `Agent/LoopSpec.hs:529`, `Agent/SlashCommandsSpec.hs:119,130`,
`Routing/DispatcherSpec.hs:391,641`, and `Test/Fake/ChannelHandle.hs:100`
(`feedIncomingFromUser` constructs `IncomingMessage uid t` positionally).

## Change 2 — session-level origin in `session.json` (WU3)

Add `_sm_source :: Maybe MessageSource` to `SessionMeta` (`Session/Types.hs:139`).

- ToJSON emits `"source"` only when `Just` (append `<> case _sm_source s of Just src ->
  ["source" .= src]; Nothing -> []`, mirroring `_sm_agent` at line 185). FromJSON reads
  `o .:? "source"` → `Nothing` for legacy files. Backward + forward compatible.
- **Population — set-once, in `Agent/Loop.hs` right after `_ch_receive` succeeds** (the
  `Right msg` arm, ~line 107), before the slash/harness/`/bg`/provider branches — covering
  all inbound paths **of the single-tab loop**. **Scoping note:** the tabbed *dispatcher*
  runtime (`Routing/Dispatcher.hs:1075-1078`) is a separate inbound entry point that does
  NOT go through `Agent/Loop.go`; dispatcher-path origin capture is **out of scope** for this
  PR (track separately if needed). Capture on the empty-message branch too (origin is about
  the sender, not content) — make this explicit in the test.
- **Atomicity** — one helper in `Session/Handle.hs` (export it):

  ```haskell
  setSourceIfAbsent :: SessionHandle -> MessageSource -> IO ()
  ```

  `atomicModifyIORef'` on `_sh_meta` returning a changed-flag (set `_sm_source` only when
  `Nothing`); iff changed, one `_sh_save`. Same pattern as `markBootstrapConsumed`
  (`Handle.hs:602`) and `touchLastActive` (`Handle.hs:211`); introduces no new race class
  (`saveMeta` re-reads the IORef, `Handle.hs:197-204`).
- **All `SessionMeta` construction sites get `_sm_source = Nothing`** (`-Werror` enforces).
  Corrected count ≈ **18**: 6 in src (`Frontend/API.hs:864`, `Agent/Loop.hs:353`,
  `Agent/SlashCommands.hs:2323`, `CLI/Commands.hs:586`, `Session/Handle.hs:266` noOpMeta,
  `Session/Types.hs:203` the FromJSON `pure SessionMeta`) + 12 in test
  (`BroadcastingTranscriptSpec:93`, `StreamGoldensSpec:102`, `StreamIntegrationSpec:159`,
  `APISpec:1413/1535/1561/1648`, `Integration/CLISpec:383/445`, `LoopSpec:160`,
  `TypesSpec:96/206/228`, `HandleSpec:86`). `_sm_channel` (coarse label) retained unchanged.

### Surface it — `/status` (`Agent/SlashCommands.hs`, `CmdStatus`)

When `_sm_source` is `Just`, add a line `Source: <id> (<channel>)` via `channelKindToText`.
Define the fallback when `_ms_userId = Nothing` but `_ms_fields` carries identity (render
`(channel)` or a chosen field). Pin exact format in the test, including a `CkOther` case
(e.g. `(matrix)`).

## Change 3 — per-message sender in `transcript.jsonl` (WU4)

Change `mkTranscriptProvider`'s signature:

```haskell
mkTranscriptProvider :: TranscriptHandle -> Text -> Maybe MessageSource -> SomeProvider -> SomeProvider
```

Write the source into the existing `_te_metadata :: Map Text Value` under key `"source"`
(shared codec) on **Request** entries only. **There are TWO Request-construction paths** in
`Transcript/Provider.hs` — `complete` (lines 35-45) and `completeStream` (lines 75-85);
**both** must be tagged or `completeStream` silently drops the source. Response entries
(lines 63, 110) stay untouched (source describes the inbound message, not the reply).

**Caller audit (corrected — three production callers, not one):**
- `Agent/Loop.hs:184` — foreground provider turn; `msg` in scope → pass
  `Just (_im_source msg)`.
- `Agent/Loop.hs:335` — `runBackgroundSession` (`/bg`); no inbound msg → pass `Nothing`
  (decision: `/bg` turns get no per-message source).
- `Frontend/API.hs:1104` — `doCompletion` web turn; no `IncomingMessage` → pass `Nothing`.
- ~16 test sites in `Transcript/ProviderSpec.hs` + `Frontend/BroadcastingTranscriptSpec.hs`
  add the new argument. `-Werror` forces all of these.

### Dual-storage authority model

- `session.json` `_sm_source` = session **origin/owner**, set once (first sender).
- `transcript.jsonl` `metadata.source` = **per-message truth** (each inbound turn).
- Identical for a DM; the per-message copy is forward-insurance for the deferred group-chat
  case. They legitimately diverge on a resumed session with a new sender — trust
  `_sm_source` for "whose session," the transcript for "who sent this." Do not reconcile.

## Security / privacy posture (corrected)

- **On disk:** `session.json` mode `0600`, `transcript.jsonl` in the `0700` session dir —
  consistent with already storing conversation content. Acceptable.
- **NOT broadcast (corrected).** `_te_metadata` is **dropped** by the `TranscriptEntryInfo`
  projection on BOTH the WS path (`toEntryInfo`, `Stream.hs:158-168`) and the HTTP path
  (`toTranscriptEntryInfo` / `ToJSON TranscriptEntryInfo`, `API.hs:611-640`) — those carry
  only id/timestamp/direction/payload/harness/model. So the sender id written to
  `metadata.source` is **persisted to disk, server-side only — never broadcast**. (The
  v1/v2 "marginal incremental broadcast PII" rationale was wrong, in the safe direction.)
  **WU4 MUST write `source` into `_te_metadata` only and MUST NOT add a metadata field to
  `TranscriptEntryInfo`/`toEntryInfo`.** Add a test asserting the WS `entry` event and
  `GET /transcript` response omit the sender id.
- The pre-existing unauthenticated broadcast of message *payloads* (frontend binds all
  interfaces, no auth) is real but pre-existing — separate hardening issue.
- **In-scope mitigation:** `mkMessageSource` normalization (above). Note it does NOT cover
  the pre-existing verbatim Signal blocked-sender log (`Signal.hs:104-106`) — out of scope.
- **Provenance, not identity:** the sender id is attacker-asserted; never use it for authz
  (invariant above).

## Backward compatibility

Old `session.json` (no `"source"`) → `Nothing`. Old `transcript.jsonl` (no
`metadata.source`) → absent. New writes readable by old readers (extra key ignored). No
backfill of historical sessions (out of scope) — `/status` may render "Source: unknown" for
legacy sessions so absence reads as intentional.

## Testing (TDD; coverage target **95%** per `.coverage-thresholds.json`, NOT 100%)

- `Core/TypesSpec`: `ChannelKind` text round-trip (all kinds + `CkOther`); shadowing guard
  (`"signal"` never → `CkOther "signal"`). `MessageSource` JSON round-trip (empty vs
  non-empty fields; tolerant decode; snake_case keys; omission). `mkMessageSource`
  normalization on **userId AND a field string value**; length bound; `CkOther "signal"` →
  `CkSignal`.
- `Session/TypesSpec`: `SessionMeta` ± `_sm_source` round-trip; legacy decode → `Nothing`;
  write omits `"source"` when `Nothing`.
- `Session/HandleSpec`: `setSourceIfAbsent` sets when `Nothing`; on already-`Just`, value
  unchanged **and `_sh_save` NOT called** (assert via a save-counter fake — covers the "iff
  changed" optimization); persists to disk.
- `Transcript/ProviderSpec`: source tag present on Request via **both `complete` and
  `completeStream`**; `Nothing` ⇒ no key; Response never tagged.
- `Frontend` (WS + HTTP): assert the broadcast `entry` event and `GET /transcript` response
  **omit** the sender id (metadata stays server-side).
- Channel specs (`CLISpec`/`SignalSpec`/`TelegramSpec`/`ChannelSpec`/`ClassSpec`):
  `_im_source` populated correctly; `imUserId` preserves old behavior incl. `UserId ""`.
- `Routing/DispatcherSpec`: dispatch still keys on sender via `imUserId`.
- `Agent/LoopSpec`: origin captured for all single-tab inbound paths (slash/harness/empty/
  provider); set-once (second different sender does NOT overwrite `_sm_source` but IS
  recorded per-message); `/bg` passes `Nothing`.
- `Agent/SlashCommandsSpec`: `/status` exact render incl. a `CkOther` channel.
- `Integration/SignalFlowSpec`: Signal DM → phone/uuid in both `session.json` and
  `transcript.jsonl`.

## Work units

1. **WU1** — Core type + smart constructor + JSON codec + exports; `Core/TypesSpec`.
2. **WU2** — `_im_source` on `IncomingMessage`, `imUserId`, 3 channels + noOp + dispatcher +
   test fakes/specs.
3. **WU3** — `_sm_source` + JSON + `setSourceIfAbsent` + Loop capture hook + all ~18
   construction sites + `/status`.
4. **WU4** — `mkTranscriptProvider` source param (both paths) + 3 production callers
   (`Nothing` for `/bg` + web) + ~16 test sites + WS/HTTP omit-source tests.
5. **WU5** — integration test + coverage check vs `.coverage-thresholds.json` (95%).

## Out of scope (follow-ups tracked as separate beads issues)

- Frontend auth / localhost-bind hardening (pre-existing).
- Frontend session-list source display (fast-follow; `/status` covers this PR).
- Dispatcher-path (`Routing/Dispatcher.hs:1075-1078`) session-origin capture.
- Pre-existing verbatim Signal blocked-sender log normalization.
- Changing `_sm_channel` semantics; dedicated inbound transcript entry type; backfill.
