# Harness Claude-Log Core Content Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude Code's on-disk JSONL log the reliable live source of assistant-prose content for the CORE transcript of spawned claude-code harnesses, feeding the merged `stepTurns` loop, with a fail-safe fallback to today's tmux path.

**Architecture:** A per-harness *turn-content provider* selects between a new Claude-log provider (tail the JSONL via `SafeClaudeLogPath` + a bounded `JsonlTail` loop, fold assistant `text` blocks into the current turn) and the existing tmux `_hh_snapshotTurn`. `stepTurns` is minimally modified to read the provider's turn text, use a JSONL-derived stable turn id, and honor an event-based finalize. Idempotency across crash/restart is guaranteed by a recorded-id set seeded from the on-disk transcript at startup. Liveness stays 100% tmux.

**Tech Stack:** Haskell (GHC 9.12, GHC2021), `bytestring`, `aeson`, `uuid`, `unix`, `async`; Nix flake (`nix develop . --command cabal ...`); hspec tests.

**Spec:** `docs/superpowers/specs/2026-06-21-harness-log-tailing-content-source-design.md` (design-review gate 5/5).

## Global Constraints

- Build/test only via `nix develop . --command cabal build` / `... cabal test`.
- TDD mandatory: failing test first (commit separately), then minimal code.
- `-Wall -Werror -Wincomplete-record-updates -Wmissing-export-lists`; hlint clean.
- Coverage meets `.coverage-thresholds.json` (95% lines/branches/functions/statements; `stagedWaivers` exists but add NO new waiver — keep logic pure + inject IO).
- Imports: `qualified as` (no explicit import lists except canonical `import Data.Set (Set)`).
- All harness output surfaced to a human MUST pass `PureClaw.Handles.Harness.sanitizeHarnessOutput :: Text -> Text`.
- Async loops: re-raise `SomeAsyncException` (not only `AsyncCancelled`) on teardown; bound test teardown with `System.Timeout.timeout`.
- Claude-log file access ONLY via `SafeClaudeLogPath` (`mkSafeClaudeLogPath`); never a raw `FilePath`.
- DoS caps (normative): backfill ≤ 32 MiB, single line ≤ 1 MiB, buffered partial ≤ 1 MiB → loud "log unavailable" fallback, never silent partial read.
- Scope: spawned claude-code harness with a minted `ClaudeSessionUuid` only; everything else uses the tmux path verbatim. Prose-only (assistant `text` blocks); no thinking/tool_use/tool_result/Request from the log.

## Reused merged modules (do NOT reimplement)

- `PureClaw.Harness.JsonlTail`: `Offset (Offset Integer)`, `Buffer`, `emptyBuffer`, `unBuffer`, `CompleteLine`/`unCompleteLine`, `splitLines :: ByteString -> Buffer -> ([CompleteLine], Buffer)`.
- `PureClaw.Harness.ClaudeLogPath`: `SafeClaudeLogPath`, `getSafeClaudeLogPath :: SafeClaudeLogPath -> FilePath`, `ClaudeBase`, `resolveClaudeBase :: IO ClaudeBase`, `mkClaudeBase`, and `mkSafeClaudeLogPath :: ClaudeBase -> ClaudeSessionUuid -> Maybe FilePath -> IO (Either ClaudeLogPathError SafeClaudeLogPath)` (uuid-glob + containment + `O_NOFOLLOW` + owner/mode). NOTE the real arity: a `Left ClaudeLogPathError` (or the absence of a uuid) → tmux fallback for that harness.
- `PureClaw.Harness.ClaudeSession`: `ClaudeSessionUuid`, `unClaudeSessionUuid :: ClaudeSessionUuid -> Text`, `mkClaudeSessionUuid :: Text -> Either ClaudeSessionUuidError ClaudeSessionUuid`.
- `PureClaw.Harness.ClaudeLogConvert` total JSONL helpers — currently module-internal; **export** `decodeObject :: ByteString -> Maybe (KeyMap Value)`, `lookupText :: Text -> KeyMap Value -> Maybe Text`, `lookupObject :: Text -> KeyMap Value -> Maybe (KeyMap Value)`, `sanitizeBlock :: Value -> Value` (Task 2) and reuse them in `ClaudeLogProse` so the two paths cannot drift on JSON shape / sanitization.
- `PureClaw.Handles.Harness.sanitizeHarnessOutput :: Text -> Text`.
- `PureClaw.Handles.Transcript`: `_th_query :: TranscriptFilter -> IO [TranscriptEntry]`, `_th_record`.
- `PureClaw.Transcript.Types`: `TranscriptEntry` (`_te_id`, `_te_direction`, `_te_correlationId`, …), `Direction (Request | Response)`.
- `PureClaw.Harness.Reconcile`: `mkTurnEntry :: Text -> UTCTime -> Text -> TranscriptEntry`, `ReconcileDeps` (`_rd_recordResponse`, `_rd_publishUpdate`, `_rd_mintTurn`, …), `stepTurns`/`stepLiveEntry`/`startTurn`, `runReconcileLoopWith`.
- Persisted spec fields (`PureClaw.Session.Kind`): `_h_claudeSessionUuid :: Maybe Text`, `_h_canonicalCwd :: Maybe Text`.

---

## File Structure

- Create `src/PureClaw/Harness/ClaudeLogProse.hs` — pure prose fold + deterministic turn-id derivation.
- Modify `src/PureClaw/Harness/JsonlTail.hs` — add `splitLinesBounded` (pure, capped).
- Create `src/PureClaw/Harness/ClaudeLogTail.hs` — `JsonlTailDeps` seam + the IO tail loop (caps, offset persistence, async discipline).
- Create `src/PureClaw/Harness/LogProvider.hs` — the turn-content provider record + tmux-default + log-provider construction; the recorded-id dedup helper.
- Modify `src/PureClaw/Harness/Reconcile.hs` — thread the provider into `stepTurns` (read text, derived id, finalize signal).
- Modify `src/PureClaw/CLI/Commands.hs` — seed recorded-id IORef; sidecar `Async` lifecycle; select+start the log provider for spawned-claude-with-uuid.
- Tests: `test/Harness/JsonlTailSpec.hs` (extend), `test/Harness/ClaudeLogProseSpec.hs`, `test/Harness/ClaudeLogTailSpec.hs`, `test/Harness/LogProviderSpec.hs`, `test/Harness/ReconcileSpec.hs` (extend), `test/Integration/ClaudeLogContentSpec.hs`.

---

## Task 1: Bounded line splitter (`splitLinesBounded`)

**Files:**
- Modify: `src/PureClaw/Harness/JsonlTail.hs`
- Test: `test/Harness/JsonlTailSpec.hs`

**Interfaces:**
- Consumes: existing `Buffer`, `CompleteLine`, `splitLines`.
- Produces: `data SplitCap = OverCap` ; `splitLinesBounded :: Int -> ByteString -> Buffer -> Either SplitCap ([CompleteLine], Buffer)` — caps the buffered partial-line length at `maxBuffer` bytes; returns `Left OverCap` if `pending <> chunk` would exceed the cap with no terminating LF (checked BEFORE concatenation/split so no transient over-cap allocation).

- [ ] **Step 1: Write failing tests**

```haskell
-- test/Harness/JsonlTailSpec.hs (add to the describe block)
it "splitLinesBounded passes complete lines through under the cap" $ do
  let (Right (ls, buf)) = splitLinesBounded 1024 "a\nb\n" emptyBuffer
  map unCompleteLine ls `shouldBe` ["a", "b"]
  unBuffer buf `shouldBe` ""

it "splitLinesBounded buffers a partial trailing line under the cap" $ do
  let (Right (ls, buf)) = splitLinesBounded 1024 "a\npart" emptyBuffer
  map unCompleteLine ls `shouldBe` ["a"]
  unBuffer buf `shouldBe` "part"

it "splitLinesBounded rejects a no-LF line exceeding the cap (OverCap, no growth)" $ do
  let big = BS.replicate 2048 0x61   -- 2048 'a', no newline
  splitLinesBounded 1024 big emptyBuffer `shouldBe` Left OverCap

it "splitLinesBounded rejects when pending+chunk exceeds cap with no LF" $ do
  let (Right (_, buf)) = splitLinesBounded 4096 "head" emptyBuffer
  splitLinesBounded 8 "morebytes_overflow" buf `shouldBe` Left OverCap
```

- [ ] **Step 2: Run, verify FAIL** — `nix develop . --command cabal test --test-options='--match "/JsonlTail/splitLinesBounded/"'` → `Variable not in scope: splitLinesBounded`.

- [ ] **Step 3: Implement** (add to `JsonlTail.hs`, export `splitLinesBounded`, `SplitCap (..)`):

```haskell
data SplitCap = OverCap deriving stock (Eq, Show)

-- | Like 'splitLines', but fails closed if the residual partial line would
-- exceed @maxBuffer@ bytes (a no-LF flood). The cap is checked BEFORE the split
-- so an over-cap chunk never transiently allocates the concatenation.
splitLinesBounded :: Int -> ByteString -> Buffer -> Either SplitCap ([CompleteLine], Buffer)
splitLinesBounded maxBuffer chunk buf@(Buffer pending)
  -- If there is no LF anywhere in pending<>chunk and it already exceeds the cap,
  -- reject without building the full residual.
  | not (0x0A `BS.elem` chunk)
  , BS.length pending + BS.length chunk > maxBuffer = Left OverCap
  | otherwise =
      let (ls, resid@(Buffer r)) = splitLines chunk buf
      in if BS.length r > maxBuffer then Left OverCap else Right (ls, resid)
```

- [ ] **Step 4: Run, verify PASS** — same command → PASS; then `nix develop . --command cabal test` full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/JsonlTail.hs test/Harness/JsonlTailSpec.hs
git commit -m "feat(jsonltail): splitLinesBounded — capped partial-line buffer (DoS guard)"
```

---

## Task 2: Pure prose fold + deterministic turn id (`ClaudeLogProse`)

**Files:**
- Create: `src/PureClaw/Harness/ClaudeLogProse.hs`
- Test: `test/Harness/ClaudeLogProseSpec.hs` (fixtures: `test/fixtures/claude-jsonl/`)

**Interfaces:**
- Produces:
  - `data ProseState` (opaque; `emptyProseState :: ProseState`) — carries the current turn's accumulated sanitized prose, the pinned first-assistant `uuid`, and a `finalized` flag.
  - `data ProseTurn = ProseTurn { _pt_sourceUuid :: !Text, _pt_text :: !Text, _pt_finalized :: !Bool }`
  - `foldProseLine :: ByteString -> ProseState -> (ProseState, Maybe ProseTurn)` — total; on each complete JSONL line updates state and, when a turn's prose changed or finalized, yields the current `ProseTurn`. Never throws.
  - `currentProseTurn :: ProseState -> Maybe ProseTurn`
  - `deriveTurnId :: Text -> Text -> Text` — `deriveTurnId sessionId firstAssistantUuid`, a UUIDv5 over the namespaced bytes (stable, collision-free across sessions).

**Fold rules (prose-only):** a real `user` event (content not solely `tool_result`) ENDS the current turn (mark prior `finalized=True` if it had content) and starts a fresh empty turn; an `assistant` event appends its `text` blocks (sanitized) to the current turn and pins `_pt_sourceUuid` to the FIRST assistant line's `uuid` (do not change on later lines); a terminal `stop_reason` (`end_turn`/`stop_sequence`/`max_tokens`, NOT `tool_use`) on an assistant event sets `finalized=True`; `thinking`/`tool_use`/`tool_result` blocks and unknown/malformed/meta lines are ignored (state unchanged, never throws).

- [ ] **Step 1: Write failing tests** (use real fixture lines; representative cases):

```haskell
-- test/Harness/ClaudeLogProseSpec.hs
spec :: Spec
spec = describe "ClaudeLogProse" $ do
  let asst t sr = "{\"type\":\"assistant\",\"uuid\":\"u1\",\"message\":{\"role\":\"assistant\""
                <> ",\"content\":[{\"type\":\"text\",\"text\":\"" <> t <> "\"}]"
                <> maybe "" (\s -> ",\"stop_reason\":\"" <> s <> "\"") sr <> "}}"
      usr = "{\"type\":\"user\",\"uuid\":\"u0\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}"

  it "accumulates assistant text across lines under one pinned source uuid" $ do
    let (s1, _) = foldProseLine (asst "Hello" Nothing) emptyProseState
        (_,  m) = foldProseLine (asst " world" Nothing) s1
    fmap _pt_text m `shouldBe` Just "Hello world"
    fmap _pt_sourceUuid m `shouldBe` Just "u1"
    fmap _pt_finalized m `shouldBe` Just False

  it "finalizes on a terminal stop_reason" $ do
    let (_, m) = foldProseLine (asst "Done." (Just "end_turn")) emptyProseState
    fmap _pt_finalized m `shouldBe` Just True

  it "does NOT finalize on stop_reason tool_use" $ do
    let (_, m) = foldProseLine (asst "calling" (Just "tool_use")) emptyProseState
    fmap _pt_finalized m `shouldBe` Just False

  it "a new user event ends the prior turn and starts fresh" $ do
    let (s1, _) = foldProseLine (asst "answer" Nothing) emptyProseState
        (s2, _) = foldProseLine usr s1
    currentProseTurn s2 `shouldBe` Nothing   -- fresh empty turn

  it "ignores malformed and meta lines without throwing" $ do
    let (s1, m1) = foldProseLine "{ not json" emptyProseState
        (_,  m2) = foldProseLine "{\"type\":\"mode\"}" s1
    m1 `shouldBe` Nothing
    m2 `shouldBe` Nothing

  it "deriveTurnId is deterministic and namespaced by session" $ do
    deriveTurnId "sessA" "u1" `shouldBe` deriveTurnId "sessA" "u1"
    deriveTurnId "sessA" "u1" `shouldNotBe` deriveTurnId "sessB" "u1"
```

- [ ] **Step 2: Run, verify FAIL** — `... --match "/ClaudeLogProse/"` → module/symbol not found.

- [ ] **Step 3a: Export the shared helpers from `ClaudeLogConvert`.** Add `decodeObject`, `lookupText`, `lookupObject`, `sanitizeBlock` to `ClaudeLogConvert`'s export list (they exist module-internal at `ClaudeLogConvert.hs:159/198/205/212`). No behavior change; `cabal build` stays green. Commit separately: `refactor(claudelog): export total JSONL lookup/sanitize helpers for reuse`.
- [ ] **Step 3b: Implement** `ClaudeLogProse.hs` REUSING those helpers (do NOT re-derive JSON parsing) + `sanitizeHarnessOutput` for the text. Extract `"type"`/`"uuid"` and the `message.content[]` `text` blocks via `decodeObject`/`lookupText`/`lookupObject`. `deriveTurnId sessionId firstUuid = UUID.toText (V5.generateNamed UUID.namespaceDNS (BS.unpack (TE.encodeUtf8 (sessionId <> ":" <> firstUuid))))` (`Data.UUID.V5`; `uuid` is already a build-dep). Keep every code path total (no partial functions); a missing/malformed field yields the unchanged state + `Nothing`.

- [ ] **Step 4: Run, verify PASS** — `--match "/ClaudeLogProse/"` PASS; full suite green; confirm prose passes through `sanitizeHarnessOutput` (add an assertion with an ANSI-laden fixture line).

- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/ClaudeLogProse.hs test/Harness/ClaudeLogProseSpec.hs
git commit -m "feat(claudelog): pure prose fold + deterministic namespaced turn id"
```

---

## Task 3: Tailer IO loop (`ClaudeLogTail` + `JsonlTailDeps`)

**Files:**
- Create: `src/PureClaw/Harness/ClaudeLogTail.hs`
- Test: `test/Harness/ClaudeLogTailSpec.hs`

**Interfaces:**
- Produces:
  - `data JsonlTailDeps = JsonlTailDeps { _jt_size :: SafeClaudeLogPath -> IO Integer, _jt_readFrom :: SafeClaudeLogPath -> Offset -> Int -> IO (ByteString, Offset), _jt_now :: IO UTCTime }` — injectable IO seam; production reads via `O_NOFOLLOW`, bounded to the `maxChunk` 3rd arg.
  - `data TailCaps = TailCaps { _tc_backfill :: Int, _tc_line :: Int, _tc_buffer :: Int, _tc_chunk :: Int }`; `defaultTailCaps = TailCaps (32*1024*1024) (1024*1024) (1024*1024) (256*1024)`.
  - `data TailEvent = TailProse !ProseTurn | TailUnavailable` ; `tailStep :: JsonlTailDeps -> TailCaps -> SafeClaudeLogPath -> (Offset, Buffer, ProseState) -> IO ((Offset, Buffer, ProseState), [TailEvent])` — one bounded read+fold step (pure-ish over injected deps). Over any cap → `[TailUnavailable]` and stops advancing.
  - `seekStart :: JsonlTailDeps -> SafeClaudeLogPath -> Maybe Offset -> IO Offset` — resume from persisted offset; missing/`Nothing` → EOF (size), never 0 for a non-empty file. (Caller persists the offset; see Task 5.)

- [ ] **Step 1: Write failing tests** over a fake `JsonlTailDeps` backed by an `IORef ByteString` (no real FS):

```haskell
-- test/Harness/ClaudeLogTailSpec.hs — fake deps over an IORef of the file bytes
it "tailStep emits prose for newly appended complete lines and advances offset" $ do
  -- seed file with one complete assistant line; tailStep yields a ProseTurn,
  -- offset advances to end-of-consumed-bytes
  ...
  evs `shouldSatisfy` any isTailProse
  newOffset `shouldNotBe` startOffset

it "tailStep buffers a partial line until its newline arrives" $ do
  -- append "{...partial" (no LF): no ProseTurn yet; then append "rest}\n": ProseTurn
  ...

it "tailStep over the line cap yields TailUnavailable and does not advance" $ do
  -- a 2 MiB no-LF chunk with _tc_line/_tc_buffer = 1 MiB
  evs `shouldBe` [TailUnavailable]

it "seekStart with no persisted offset seeks to EOF (records nothing historical)" $ do
  off <- seekStart deps path Nothing
  off `shouldBe` Offset <fileSize>

it "tailStep resets to re-read on shrink (size < offset)" $ do
  -- shrink the file; next tailStep detects size<offset and re-reads from 0
  ...
```

- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** `ClaudeLogTail.hs`: `tailStep` probes size; if `size < offset` reset `(Offset 0, emptyBuffer, emptyProseState)`; else read `min(size-offset, _tc_chunk)` bytes via `_jt_readFrom`; `splitLinesBounded _tc_buffer` (→ `TailUnavailable` on `Left OverCap`); enforce `_tc_line` per complete line; fold each via `foldProseLine`; collect `TailProse` for each yielded `ProseTurn`. `seekStart`: `maybe (Offset <$> _jt_size) pure mPersisted`, but if the persisted offset exceeds current size, fall back to size. NO loop here yet — `tailStep` is one step; the driving loop + async lives in Task 5's wiring (kept there so this module stays pure-over-deps and fully unit-coverable).
- [ ] **Step 4: Run, verify PASS; full suite green.**
- [ ] **Step 5: Commit** `feat(claudelog): bounded JSONL tail step + JsonlTailDeps seam (caps, shrink-reset, seek-EOF)`.

---

## Task 4: Content-provider seam + `stepTurns` integration

**Files:**
- Create: `src/PureClaw/Harness/LogProvider.hs`
- Modify: `src/PureClaw/Harness/Reconcile.hs`
- Test: `test/Harness/LogProviderSpec.hs`, extend `test/Harness/ReconcileSpec.hs`

**Interfaces:**
- Produces (`LogProvider.hs`):
  - `data TurnProvider = TurnProvider { _tp_snapshot :: IO (Text, Bool), _tp_turnId :: IO (Maybe (Text, UTCTime)) }` — `_tp_snapshot` returns `(currentTurnText, finalized?)`; `_tp_turnId` returns `Just (derivedId, ts)` for the log provider (id + the JSONL event timestamp, pinned once per turn) or `Nothing` to fall back to `_rd_mintTurn :: IO (Text, UTCTime)`. (Carrying the timestamp avoids needing a second clock call — `mkTurnEntry` needs both id AND `UTCTime`.)
  - `tmuxProvider :: HarnessHandle -> TurnProvider` — `_tp_snapshot = (,) <$> _hh_snapshotTurn hh <*> pure False`; `_tp_turnId = pure Nothing` (preserves today's behavior verbatim).
  - `nullProvider :: TurnProvider` — `_tp_snapshot = pure ("", False)`; `_tp_turnId = pure Nothing` (for a handle-less entry).
- Modifies `stepTurns`/`stepLiveEntry`/`startTurn` (`Reconcile.hs`) to consume a per-entry provider via a new `ReconcileDeps` field `_rd_providerFor :: Reg.HarnessEntry -> IO TurnProvider` (default `\e -> pure (maybe nullProvider tmuxProvider (Reg._he_handle e))`): read turn text from `_tp_snapshot`; at `startTurn` use `_tp_turnId`'s `(id, ts)` if `Just` else `_rd_mintTurn`; treat `finalized==True` as an authoritative finalize that bypasses the idle-stability guard. Add `_rd_providerFor` to `defaultReconcileDeps` so the production override site (`CLI/Commands.hs`) and `ActivityProbe` (which delegate to the default) need no change.

- [ ] **Step 1: Write failing tests.**

```haskell
-- ReconcileSpec.hs (extend) — over an injected provider selector
it "log provider: streams prose growth then finalizes on the finalized flag (one record, derived id)" $ do
  -- selector returns a TurnProvider whose _tp_snapshot yields ("A",False),("AB",False),("AB",True)
  -- and _tp_turnId = pure (Just "derived-1"); assert: >=1 EntryUpdated, exactly one
  -- recorded Response with _te_id == "derived-1" and text "AB"
  ...
it "log provider finalize is NOT gated on tmux idle liveness" $ do
  -- liveness frames stay 'Thinking' the whole time; finalized flag still records
  ...
-- LogProviderSpec.hs
it "tmuxProvider preserves _hh_snapshotTurn text and never finalizes/derives id" $ do
  (txt, fin) <- _tp_snapshot (tmuxProvider hh)
  mid <- _tp_turnId (tmuxProvider hh)
  (txt, fin, mid) `shouldBe` ("snapshot", False, Nothing)
-- Regression: the merged tmux DoD tests still pass unchanged (run existing suite).
```

- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** `LogProvider.hs` + the minimal `stepTurns` changes. Keep the tmux path byte-identical (default selector → `tmuxProvider`). Add `_rd_providerFor` to `ReconcileDeps` AND to `defaultReconcileDeps`. Latch: once a turn is active under a provider, do not switch providers until the turn finalizes (track in `TurnState`).
- [ ] **Step 3b: Update every full-literal `ReconcileDeps { … }` construction site (REQUIRED — `-Werror -Wmissing-fields` will otherwise fail the build).** Add `_rd_providerFor = \e -> pure (maybe nullProvider tmuxProvider (Reg._he_handle e))` to each literal in `test/Harness/ReconcileSpec.hs` (sites at approximately lines 134, 377, 574, 621, 873, 913, 950, 1019, 1107 — grep `ReconcileDeps {` / `ReconcileDeps$` to find all). Production `CLI/Commands.hs` uses `defaultReconcileDeps { … }` and needs no field here; `ActivityProbe` delegates to the default. Run `nix develop . --command cabal build` to confirm ZERO `-Wmissing-fields` errors before proceeding.
- [ ] **Step 4: Run, verify PASS.** Confirm the merged "output watcher" DoD tests (`#3` once-only, `#4` distinct ids, awaiting-input, Finding-1) still pass verbatim.
- [ ] **Step 5: Commit** `feat(reconcile): turn-content provider seam (tmux default + log finalize/derived-id)`.

---

## Task 5: Recorded-id dedup + lifecycle wiring (`CLI/Commands`)

**Files:**
- Modify: `src/PureClaw/CLI/Commands.hs`
- Add helper(s) to `src/PureClaw/Harness/LogProvider.hs` (selection + tailer driver)
- Test: extend `test/Harness/LogProviderSpec.hs`; `test/Integration/ClaudeLogContentSpec.hs` (Task 6)

**Interfaces:**
- Produces:
  - `seedRecordedIds :: TranscriptHandle -> IO (Set Text)` = `Set.fromList . map _te_id <$> _th_query emptyFilter` (UNTRIMMED; not `loadRecentMessages`).
  - `recordOnce :: IORef (Set Text) -> (SessionId -> TranscriptEntry -> IO ()) -> SessionId -> TranscriptEntry -> IO ()` — skip if `_te_id ∈ set`, else record + insert.
  - `runLogTailer :: JsonlTailDeps -> TailCaps -> SafeClaudeLogPath -> (ProseTurn -> IO ()) -> IO ()` — the driving loop around `tailStep` (poll interval; persist offset write-then-rename after each step; re-raise `SomeAsyncException`; loud-WARN + stop on `TailUnavailable`).

- [ ] **Step 1: Write failing tests.**

```haskell
-- LogProviderSpec.hs
it "recordOnce skips a _te_id already in the seeded set (crash/restart idempotency)" $ do
  ref <- newIORef (Set.fromList ["derived-1"])     -- seeded from disk
  recorded <- newIORef []
  let rec sid e = modifyIORef' recorded ((sid,e):)
  recordOnce ref rec sid (mkTurnEntry "derived-1" t "AB")  -- already present → skip
  recordOnce ref rec sid (mkTurnEntry "derived-2" t "CD")  -- new → record
  map (_te_id . snd) <$> readIORef recorded `shouldReturn` ["derived-2"]

it "seedRecordedIds reads ids via the untrimmed query" $ do
  -- a fake TranscriptHandle whose _th_query returns 3 entries → set of 3 ids
  ...
```

- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement.** In `CLI/Commands.hs` where `reconcileDeps` is built (`~996`):
  1. Create `recordedIds <- newIORef Set.empty` (an IORef captured in the closure, OUTSIDE the per-call `bracket`).
  2. Wrap `_rd_recordResponse` with `recordOnce recordedIds` around the existing append.
  3. Add `_rd_providerFor` selecting the log provider for an entry iff **`_he_flavour == HClaudeCode && a `ClaudeSessionUuid` resolves`** — gate on **uuid-resolvability, NOT origin**. (Rationale: a PureClaw-spawned harness is boot-reconstructed as `OriginDiscovered` after a restart — `Reconcile.hs:870` — so gating on `OriginSpawned` would wrongly route the restart case to tmux and defeat restart-idempotency. Only spawned-with-uuid harnesses persist `_h_claudeSessionUuid`; adopted/CLI/non-claude lack it, so uuid-presence is the correct capability signal across both `OriginSpawned` and `OriginDiscovered`.) Resolution, done ONCE then cached per `HarnessId`: `_he_sessionId → session.json HarnessSpec._h_claudeSessionUuid → mkClaudeSessionUuid` (validate); `base <- resolveClaudeBase`; `mkSafeClaudeLogPath base uuid (_h_canonicalCwd)` → on `Left _` (or no uuid), the provider is `tmuxProvider`/`nullProvider` (fallback, WARN once); on `Right safePath`, seed `recordedIds` from that session's transcript (`seedRecordedIds`), start `runLogTailer` under `Async.withAsync`, store the `Async` in a sidecar `IORef (Map HarnessId (Async ()))`, and cache the resulting log `TurnProvider`. On reconcile-detected exit (reuse the `_rd_evict`/terminal signal), cancel + remove the `Async`.
  4. The tailer's `ProseTurn` sink updates the provider's current `(text, finalized, derivedId)` state (an `IORef` the `TurnProvider` reads).
- [ ] **Step 4: Run, verify PASS; full suite green; coverage check (`--enable-coverage`) — no new waiver.**
- [ ] **Step 5: Commit** `feat(cli): log-tailer lifecycle + disk-seeded recorded-id dedup wiring`.

---

## Task 6: Integration test + manual verification

**Files:**
- Create: `test/Integration/ClaudeLogContentSpec.hs`
- Fixtures: reuse `test/fixtures/claude-jsonl/`

- [ ] **Step 1: Write the integration test** (drives the real wiring with a temp `~/.claude`-style dir + a fixture `<uuid>.jsonl`, asserting the assistant prose lands in the session transcript exactly once, and a second run with the same file re-emits nothing — exercising `seedRecordedIds`).
- [ ] **Step 2: Run, verify FAIL → implement any missing glue → PASS.**
- [ ] **Step 3:** Manual verification (record results in the PR):
  1. Frontend-spawn a claude harness; send a prompt whose output scrolls past the visible pane → full prose streams per-message + final recorded WITHOUT `/harness output`.
  2. Confirm the liveness glyph still tracks thinking/idle (tmux unchanged).
  3. Restart PureClaw mid-session → no duplicated transcript turns.
- [ ] **Step 4: Commit** `test(integration): claude-log core content source end-to-end + restart idempotency`.

---

## Self-review notes

- Spec coverage: bounded read/caps (Task 1,3), prose-only fold + sanitization + finalize (Task 2), tailer mechanics + seek-EOF + shrink-reset + async (Task 3), provider seam + minimal stepTurns + tmux-verbatim + latch + finalize-authority (Task 4), disk-seeded dedup + lifecycle + single-writer (Task 5), end-to-end + restart idempotency (Task 6). Security (SafeClaudeLogPath, O_NOFOLLOW, caps, sanitize) is satisfied by reuse + caps in Tasks 1/3/5.
- Out of scope (no tasks, intentional): thinking/tool/Request surfacing; adopted/CLI/non-claude log feed; optional opt-in view.
- Type consistency: `TurnProvider`, `ProseTurn`, `JsonlTailDeps`, `TailCaps`, `splitLinesBounded`, `deriveTurnId`, `recordOnce`, `seedRecordedIds` used consistently across tasks.
