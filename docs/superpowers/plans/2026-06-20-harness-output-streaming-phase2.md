# Harness Output Streaming — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single harness transcript message that visibly grows in place each reconcile tick (the whole accumulating turn) and finalizes once on settle, with a streaming indicator.

**Architecture:** Extend the Phase-1 reconcile watcher to publish an *ephemeral* `EntryUpdated` (WS-only, never persisted) under a *stable per-turn entry id* each working tick, and persist once on settle (same id). The frontend `reconcileEntries` replaces on matching id (reverses Phase 1's skip), and a `streaming` flag (derived from the wire event type) drives a growing-message indicator that clears on the final entry.

**Tech Stack:** Haskell (GHC 9.12, `-Wall -Werror`, hspec, TDD via Nix); React/TypeScript (vitest).

**Design spec:** `docs/superpowers/specs/2026-06-20-harness-output-streaming-phase2-design.md`
**Builds on:** Phase 1 (`feat/harness-output-streaming`, PR #94) — this branch is based on its tip.

## Global Constraints

- Build/test only via Nix: `nix develop . --command cabal build` / `… cabal test`. Never bare `cabal`.
- GHC `-Wall -Werror -Wincomplete-record-updates -Wmissing-export-lists`; hlint clean. Adding a record field means updating ALL construction sites.
- Import style: `qualified as` (no explicit import lists except canonical `import Data.Set (Set)`).
- TDD: failing test first (RED), minimal implementation (GREEN), commit. Pristine test output.
- Coverage gate: `.coverage-thresholds.json` (≥95%), enforced via `cabal test --enable-coverage`. Production IO closures (broker publish / transcript write) are waiver-eligible like Phase 1's `_rd_recordResponse`; decision logic must be unit-tested via the injected seams.
- Frontend: `cd frontend && npx tsc --noEmit` and `npx vitest run` must pass.
- GIT HYGIENE: stage only the files you change BY NAME; never `git add -A`/`git add .` (untracked artifacts — `frontend/coverage/`, `*.tix`, `*.sh`, `metaswarm-*.jsonl` — must not be committed).
- AsyncCancelled must always be re-raised in any catch-all (project invariant; the reconcile loop's `outer` handler does this).
- Live updates are EPHEMERAL: `EntryUpdated` is published directly to the broker and is NEVER written to `transcript.jsonl`. Only the settle `Response` is persisted (once).

## Cascade & construction-site inventory (-Werror / TS exhaustiveness)

- **`_ho_extractTurn` added to `HarnessObserver`** (Observer.hs) — update both constructions: `claudeObserver` (Observer.hs:180), `genericObserver` (Observer.hs:191). No other `HarnessObserver` literals exist (grep to confirm).
- **`_hh_snapshotTurn` added to `HarnessHandle`** (Handles/Harness.hs) — update ALL construction sites (same set Phase 1 touched for `_hh_snapshot`): `Handles/Harness.hs` (`mkNoOpHarnessHandle`), `ClaudeCode.hs` real + discovered handles, `test/Frontend/APISpec.hs` (3 fake handles), `test/Tabs/RuntimesSpec.hs` (3 inline handles). Confirm: `awk '/HarnessHandle$|HarnessHandle \{/{print FILENAME":"NR}' $(find src test -name '*.hs')`.
- **`_rd_publishUpdate`, `_rd_mintTurn` added + `_rd_recordResponse` signature changed** on `ReconcileDeps` (Reconcile.hs) — update `defaultReconcileDeps` and EVERY `ReconcileDeps` fake/override in `test/Harness/ReconcileSpec.hs` (the `_rd_recordResponse` stubs change from `\_ _ -> …` to taking a `TranscriptEntry`), plus the production wiring in `CLI/Commands.hs`.
- **`EntryUpdated` added to `BrokerEvent`** (StreamBroker.hs) — every exhaustive `case` on `BrokerEvent`: the writer-loop `handleEvent` (Stream.hs ~:733) and any other matcher (grep `case .* of` / `\case` over `BrokerEvent`; `publishEvent`/`publishOne` treat it generically — verify).
- **`SeEntryUpdate` added to `ServerEvent`** (Stream.hs) — every exhaustive `case`: `encodeServerEvent` (Stream.hs:186). Grep for other `ServerEvent` matchers.
- **TS `ServerEvent` union** gains an `entry-update` member (`frontend/src/types/stream.ts`); `handleMessage` switch (`streamClient.ts:204`) gains a `case 'entry-update'`. `TranscriptEntry` (`frontend/src/types.ts:150`) gains `streaming?: boolean`.

---

### Task 1: `_ho_extractTurn` — whole-turn extraction

**Files:**
- Modify: `src/PureClaw/Harness/Observer.hs` (add `_ho_extractTurn` to the record + Claude + generic impls + `isClaudeUserLine` + export)
- Create fixtures: `test/fixtures/harness/claude-turn-multi.txt`, `claude-turn-single.txt`, `claude-turn-empty.txt`
- Test: `test/Harness/ObserverSpec.hs`

**Interfaces:**
- Produces: `_ho_extractTurn :: Int -> ByteString -> Text` on `HarnessObserver` (baseline → capture → whole assistant turn since the last user prompt; "" if none). `isClaudeUserLine :: Text -> Bool` (a `❯`/`›` line with non-empty text that is not a numbered menu).

**Fixtures** (a working turn shows the user's submitted `❯ <text>` line, then `⏺` blocks; the live input box is a bare `❯`):

`test/fixtures/harness/claude-turn-multi.txt`:
```
❯ refactor the auth module

⏺ Looking at the auth module to understand the flow.

  Read 1 file (ctrl+o to expand)
⏺ Found the bug at auth.ts:42 — an off-by-one in the token slice.
  Update(auth.ts)
⏺ Applied the fix; the tests pass.
────────────────────────────────────────
❯
```

`test/fixtures/harness/claude-turn-single.txt`:
```
❯ what does foo do?

⏺ foo validates the session token and returns the user id.
❯
```

`test/fixtures/harness/claude-turn-empty.txt` (user line, no assistant reply yet, working):
```
❯ start the build

✳ Flummoxing… (4s · ↓ 1.2k tokens)
❯
```

- [ ] **Step 1: Write failing tests** (`test/Harness/ObserverSpec.hs`)

```haskell
  describe "claudeObserver._ho_extractTurn" $ do
    it "returns ALL assistant blocks since the last user prompt (chrome/tool stripped)" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-multi.txt"
      let out = _ho_extractTurn claudeObserver 0 cap
      out `shouldSatisfy` T.isInfixOf "Looking at the auth module"
      out `shouldSatisfy` T.isInfixOf "Found the bug at auth.ts:42"
      out `shouldSatisfy` T.isInfixOf "Applied the fix; the tests pass."
      out `shouldNotSatisfy` T.isInfixOf "refactor the auth module"  -- not the user line
      out `shouldNotSatisfy` T.isInfixOf "\x23FA"                     -- markers stripped
      out `shouldNotSatisfy` T.isInfixOf "ctrl+o"                     -- chrome stripped
      out `shouldNotSatisfy` T.isInfixOf "Update(auth.ts)"           -- tool line stripped
      out `shouldNotSatisfy` T.isInfixOf "\x2500\x2500"              -- rule stripped
    it "single block: returns just that block's text" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-single.txt"
      _ho_extractTurn claudeObserver 0 cap `shouldBe` "foo validates the session token and returns the user id."
    it "no assistant content yet: returns empty" $ do
      cap <- BS.readFile "test/fixtures/harness/claude-turn-empty.txt"
      T.strip (_ho_extractTurn claudeObserver 0 cap) `shouldBe` ""

  describe "isClaudeUserLine" $ do
    it "a ❯ line WITH text is a user line" $
      isClaudeUserLine "\10095 refactor the auth module" `shouldBe` True
    it "a bare ❯ (idle input box) is NOT a user line" $
      isClaudeUserLine "\10095" `shouldBe` False
    it "a numbered menu cursor ❯ 1. is NOT a user line" $
      isClaudeUserLine "\10095 1. Yes" `shouldBe` False

  describe "genericObserver._ho_extractTurn" $
    it "falls back to the cleaned tail (no user-boundary detection)" $
      _ho_extractTurn genericObserver 0 (TE.encodeUtf8 "a\nb\nc") `shouldSatisfy` T.isInfixOf "c"
```

- [ ] **Step 2: Run red** — `nix develop . --command cabal test --test-options='--match "/_ho_extractTurn/"'`. FAIL (field/functions undefined).
- [ ] **Step 3: Implement** (`Observer.hs`)

Add to the record + export list:
```haskell
  , _ho_extractTurn    :: Int -> ByteString -> Text
```

```haskell
-- | A user-submitted message line: ❯/› with non-empty text, NOT a numbered
-- menu (❯ 1.) and NOT the bare idle input box (❯ alone).
isClaudeUserLine :: Text -> Bool
isClaudeUserLine raw =
  let l = T.stripStart raw
  in (T.isPrefixOf "\10095" l || T.isPrefixOf "\8250" l)   -- ❯ ›
     && not (isNumberedYesNo l)
     && not (T.null (T.strip (T.drop 1 l)))

-- | The whole assistant turn since the last user prompt: drop everything up to
-- and including the last user line, then keep the response blocks (markers
-- stripped) and drop chrome + tool/process lines.
extractTurnClaude :: Int -> ByteString -> Text
extractTurnClaude baseline capture =
  let ls   = T.lines (TE.decodeUtf8Lenient (dropBaseline baseline capture))
      turn = case reverse [ i | (i, l) <- zip [0 :: Int ..] ls, isClaudeUserLine l ] of
               (i : _) -> drop (i + 1) ls
               []      -> ls
  in if any isClaudeApprovalLine turn
       then T.strip (T.unlines (dropWhile (not . isClaudeApprovalLine) turn))
       else
         let kept =
               [ if isResponseMarkerLine l then stripResponseMarker l else l
               | l <- turn
               , not (isClaudeChrome l)
               , not (isClaudeToolLine l)
               ]
         in T.strip (T.intercalate "\n" (filter (not . T.null . T.strip) kept))

-- | Tool/process activity lines the TUI shows inside a turn (not assistant prose).
isClaudeToolLine :: Text -> Bool
isClaudeToolLine raw =
  let l = T.stripStart raw
  in T.isPrefixOf "\x239C" l   -- ⎜ (rare)
     || T.isPrefixOf "\x23BD" l
     || T.isPrefixOf "\x2514" l || T.isPrefixOf "\x251C" l   -- └ ├ tree
     || T.isPrefixOf "\x2387" l                              -- ⎇
     || (not (isResponseMarkerLine l)
         && any (`T.isPrefixOf` l)
              [ "Update(","Edit(","Write(","Create(","MultiEdit("
              , "Read(","Bash(","Grep(","Glob(","LS(","Task(","TodoWrite(" ])
     || T.isPrefixOf "\x23BF" l   -- ⎿ result line
```
Wire `_ho_extractTurn = extractTurnClaude` in `claudeObserver`; in `genericObserver` set `_ho_extractTurn = \n cap -> if n <= 0 then T.intercalate "\n" (cleanLines cap) else T.intercalate "\n" (lastN n (cleanLines cap))` (reuse `cleanLines`). The implementer should iterate the `isClaudeToolLine` / chrome predicates against the fixtures until green (these are heuristics; the fixtures pin the contract). Reuse existing `isNumberedYesNo`, `isResponseMarkerLine`, `stripResponseMarker`, `isClaudeChrome`, `isClaudeApprovalLine`, `dropBaseline`, `lastN`.

- [ ] **Step 4: Run green** — `--match "/Harness.Observer/"` all pass; adjust predicates against fixtures as needed.
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/Observer.hs test/Harness/ObserverSpec.hs test/fixtures/harness/claude-turn-multi.txt test/fixtures/harness/claude-turn-single.txt test/fixtures/harness/claude-turn-empty.txt
git commit -m "feat(harness): _ho_extractTurn — whole assistant turn since last user prompt"
```

---

### Task 2: `_hh_snapshotTurn` on `HarnessHandle`

**Files:**
- Modify: `src/PureClaw/Handles/Harness.hs` (add field + `mkNoOpHarnessHandle`)
- Modify: `src/PureClaw/Harness/ClaudeCode.hs` (real + discovered handles — wire via `_ho_extractTurn`)
- Modify: `test/Frontend/APISpec.hs`, `test/Tabs/RuntimesSpec.hs` (test handles → `\_ -> pure ""`-style — note this field takes NO arg; see below)
- Test: `test/Harness/ClaudeCodeSpec.hs`

**Interfaces:**
- Consumes: `_ho_extractTurn` (Task 1).
- Produces: `_hh_snapshotTurn :: IO Text` on `HarnessHandle` — one-shot full capture → whole-turn extraction via the flavour observer. (No `Int` arg; always whole-turn.)

- [ ] **Step 1: Failing test** (`test/Harness/ClaudeCodeSpec.hs`) — mirror the Phase-1 `_hh_snapshot` test; a fake `_ccd_captureNamed` returns a `❯ <user>\n⏺ A\n⏺ B\n❯` frame; assert `_hh_snapshotTurn hh` contains both A and B (whole turn), not the user line:

```haskell
    it "_hh_snapshotTurn returns the whole turn (all blocks since the user line)" $
      withSystemTempDirectory "pcl-snapturn" $ \tmp -> do
        reg <- Reg.newRegistry
        let frame = TE.encodeUtf8 "\10095 do it\n\x23FA First step.\n\x23FA Second step.\n\10095\n"
            deps = okDeps { _ccd_newId = pure fixedId, _ccd_sweep = \_ -> pure [adoptableRow 0 "win-t"]
                          , _ccd_panePidOf = \_ _ -> pure (Just 7), _ccd_captureNamed = \_ _ _ -> pure (Just frame) }
        Right (_, hh) <- adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp mkToken Nothing "win-t"
        out <- _hh_snapshotTurn hh
        out `shouldSatisfy` T.isInfixOf "First step."
        out `shouldSatisfy` T.isInfixOf "Second step."
        out `shouldNotSatisfy` T.isInfixOf "do it"
```

- [ ] **Step 2: Run red.** FAIL (field undefined).
- [ ] **Step 3: Implement field + wiring.** `Handles/Harness.hs`:
```haskell
  , _hh_snapshotTurn :: IO Text   -- ^ one-shot capture → whole-turn extract (flavour observer)
```
`mkNoOpHarnessHandle`: `_hh_snapshotTurn = pure ""`. ClaudeCode real handle (`mkClaudeCodeHandleWithBaseline`, has `reg`/`hid`/`baselineRef`/`deps`):
```haskell
    , _hh_snapshotTurn = do
        mCoord <- currentCoord reg hid
        case mCoord of
          Nothing -> pure ""
          Just (sess, win) -> do
            raw <- fromMaybe "" <$> _ccd_captureNamed deps sess win 0
            baseline <- readIORef baselineRef
            pure (Obs._ho_extractTurn (Obs.observerFor HClaudeCode) baseline (TE.encodeUtf8 raw))
```
Discovered handle (`mkDiscoveredClaudeCodeHandle`, has `session`/`windowName`, no deps/baseline): capture via `captureWindowNamed session windowName 0`, baseline `0`, same observer call. Test handles in APISpec/RuntimesSpec: `_hh_snapshotTurn = pure ""`. (`Obs` = the qualified Observer import already present in ClaudeCode.hs from Phase 1.)
- [ ] **Step 4: Run green** — `--match "/_hh_snapshotTurn/"`; full build clean under `-Werror` (all construction sites updated).
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Handles/Harness.hs src/PureClaw/Harness/ClaudeCode.hs test/Harness/ClaudeCodeSpec.hs test/Frontend/APISpec.hs test/Tabs/RuntimesSpec.hs
git commit -m "feat(harness): _hh_snapshotTurn — whole-turn one-shot snapshot on HarnessHandle"
```

---

### Task 3: Broker `EntryUpdated` + wire `SeEntryUpdate`

**Files:**
- Modify: `src/PureClaw/Frontend/StreamBroker.hs` (`BrokerEvent` + `EntryUpdated`)
- Modify: `src/PureClaw/Frontend/Stream.hs` (`ServerEvent` + `SeEntryUpdate`; `encodeServerEvent`; writer-loop `handleEvent`)
- Test: `test/Frontend/StreamSpec.hs` (encode + dispatch)

**Interfaces:**
- Produces: `EntryUpdated !SessionId !TranscriptEntry` (`BrokerEvent`); `SeEntryUpdate !SessionId !TranscriptEntry` (`ServerEvent`) encoding to `{type:"entry-update", sessionId, entry: toEntryInfo entry}`. The `streaming` distinction is the EVENT TYPE — `SeEntryUpdate` ⇒ streaming; `SeEntry` ⇒ final. (No `streaming` field on the Haskell `TranscriptEntry`; the frontend infers it from the event.)

- [ ] **Step 1: Failing test** (`test/Frontend/StreamSpec.hs`)

```haskell
    it "encodes SeEntryUpdate as type=entry-update with the entry" $ do
      let v = encodeServerEvent (SeEntryUpdate (SessionId "s1") sampleEntry)
      lookupKey v "type" `shouldBe` Just (Aeson.String "entry-update")
      lookupKey v "sessionId" `shouldBe` Just (Aeson.String "s1")
      -- entry object present, same shape as SeEntry
      (lookupKey v "entry" >>= \e -> lookupKey e "id") `shouldBe` Just (Aeson.String (_te_id sampleEntry))
```
(plus a `handleEvent`-level test if the spec file has a harness for it: an `EntryUpdated` for the focused session sends `SeEntryUpdate`; for a non-focused session sends nothing.)

- [ ] **Step 2: Run red.** FAIL (constructors undefined).
- [ ] **Step 3: Implement.** `StreamBroker.hs`:
```haskell
data BrokerEvent
  = EntryRecorded   !SessionId !TranscriptEntry
  | EntryUpdated    !SessionId !TranscriptEntry
  | ActivityChanged !SessionId !SessionActivity
  | ListsSnapshot   !Value
  deriving stock (Show, Eq)
```
`Stream.hs` `ServerEvent`: add `SeEntryUpdate !SessionId !TranscriptEntry`. `encodeServerEvent`:
```haskell
encodeServerEvent (SeEntryUpdate sid entry) = object
  [ "type"      .= ("entry-update" :: Text)
  , "sessionId" .= unSessionId sid
  , "entry"     .= toEntryInfo entry
  ]
```
Writer-loop `handleEvent` — add (mirror `EntryRecorded` focus-gating, but updates are ephemeral so DROP during replay of that session rather than buffer):
```haskell
    handleEvent (EntryUpdated sid entry) = do
      replaying <- readIORef (_conn_replayMode cs)
      focus     <- readIORef (_conn_focus cs)
      case () of
        _ | Just sid == fmap Just focus' -> pure ()  -- see note
      -- concretely:
      case focus of
        Just fsid | fsid == sid -> case replaying of
          Just rsid | rsid == sid -> pure ()      -- drop during this session's replay; re-sent next tick
          _                       -> sendEvent conn (SeEntryUpdate sid entry)
        _ -> pure ()
```
(Resolve the focus/replay binding names against the real `handleEvent` for `EntryRecorded`.) Any other exhaustive `BrokerEvent`/`ServerEvent` `case` flagged by `-Werror` gets the new arm.
- [ ] **Step 4: Run green.** Build clean; `--match "/entry-update/"` pass.
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Frontend/StreamBroker.hs src/PureClaw/Frontend/Stream.hs test/Frontend/StreamSpec.hs
git commit -m "feat(stream): EntryUpdated broker event + SeEntryUpdate wire event (ephemeral)"
```

---

### Task 4: Frontend — entry-update event, streaming flag, replace-on-id

**Files:**
- Modify: `frontend/src/types/stream.ts` (ServerEvent union + EntryUpdate event)
- Modify: `frontend/src/types.ts` (`TranscriptEntry` gains `streaming?: boolean`)
- Modify: `frontend/src/lib/streamClient.ts` (`handleMessage` `case 'entry-update'`)
- Modify: `frontend/src/hooks/useTranscriptStream.ts` (`reconcileEntries` replace-on-id)
- Test: `frontend/src/hooks/__tests__/useTranscriptStream.test.ts` (+ a streamClient test if present)

**Interfaces:**
- Consumes: the `entry-update` wire event (Task 3).
- Produces: `reconcileEntries` replaces an entry with a matching id (was: skip); `TranscriptEntry.streaming?: boolean` set true for entry-update deliveries, false/undefined for `entry`.

- [ ] **Step 1: Failing tests** (`useTranscriptStream.test.ts`)

```ts
it('reconcileEntries REPLACES an existing entry with the same id (was skip)', () => {
  const a = { id: 'x', timestamp: '2026-06-20T00:00:00Z', direction: 'response', payload: 'one', harness: 'harness', model: null, raw: '' } as TranscriptEntry
  const b = { ...a, payload: 'one two', streaming: true }
  const out = reconcileEntries([a], b)
  expect(out).toHaveLength(1)
  expect(out[0]!.payload).toBe('one two')
  expect(out[0]!.streaming).toBe(true)
})
it('reconcileEntries keeps sort position when replacing (stable timestamp)', () => {
  const e1 = mk('a', '2026-06-20T00:00:01Z'); const e2 = mk('b', '2026-06-20T00:00:02Z')
  const out = reconcileEntries([e1, e2], { ...e1, payload: 'grown' })
  expect(out.map(e => e.id)).toEqual(['a', 'b'])
  expect(out[0]!.payload).toBe('grown')
})
```
(and a streamClient test: an `entry-update` message for the focused session delivers an entry with `streaming===true` to entry listeners; an `entry` message delivers `streaming` falsy.)

- [ ] **Step 2: Run red** — `cd frontend && npx vitest run src/hooks/__tests__/useTranscriptStream.test.ts`. FAIL.
- [ ] **Step 3: Implement.**
`reconcileEntries` (replace instead of skip):
```ts
export function reconcileEntries(existing: TranscriptEntry[], incoming: TranscriptEntry): TranscriptEntry[] {
  for (let i = 0; i < existing.length; i++) {
    if (existing[i]!.id === incoming.id) {
      const next = existing.slice()
      next[i] = incoming           // replace in place (stable timestamp keeps order)
      return next
    }
  }
  // …unchanged insertion-by-timestamp for new ids…
}
```
`types/stream.ts`: add `export interface EntryUpdateEvent { type: 'entry-update'; sessionId: string; entry: TranscriptEntry }` and add it to the `ServerEvent` union.
`types.ts`: `TranscriptEntry` gains `streaming?: boolean`.
`streamClient.ts` `handleMessage`: in `case 'entry'` deliver `{ ...event.entry, streaming: false }` (or leave as-is — undefined is falsy); add:
```ts
      case 'entry-update': {
        if (this.focusState.kind === 'focused' && this.focusState.sessionId === event.sessionId) {
          for (const cb of this.entryListeners) cb({ ...event.entry, streaming: true })
        }
        break
      }
```
- [ ] **Step 4: Run green** — vitest + `npx tsc --noEmit`.
- [ ] **Step 5: Commit**

```bash
git add frontend/src/types/stream.ts frontend/src/types.ts frontend/src/lib/streamClient.ts frontend/src/hooks/useTranscriptStream.ts frontend/src/hooks/__tests__/useTranscriptStream.test.ts
git commit -m "feat(frontend): entry-update stream event, streaming flag, reconcileEntries replace-on-id"
```

---

### Task 5: Frontend — growing-message indicator

**Files:**
- Modify: `frontend/src/App.tsx` (entry→Message mapping: carry `streaming` onto the derived message's `isGenerating`)
- Modify: `frontend/src/components/ChatArea.tsx` (render the indicator on a streaming message — reuse `TypingIndicator`/`isGenerating`)
- Test: `frontend/src/components/__tests__/ChatArea.test.tsx` (or App test)

**Interfaces:**
- Consumes: `TranscriptEntry.streaming` (Task 4).
- Produces: a streaming entry renders the existing `TypingIndicator`; a non-streaming (final) entry does not.

- [ ] **Step 1: Failing test** — render a transcript that includes a `streaming:true` response entry; assert a typing/streaming indicator is present on that message; render the same entry with `streaming:false`; assert the indicator is gone. (Locate where entries become `Message`s — `App.tsx` derive logic — and set `isGenerating` from `streaming`.)
- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement** — in the entry→Message mapping (App.tsx), set the message's `isGenerating` (or a dedicated `streaming`) from `entry.streaming`; `ChatArea`'s `ChatMessage` already renders `{message.isGenerating && <TypingIndicator />}` (line ~799) — confirm a streaming response message flows through that. If `isGenerating` is overloaded for optimistic local state, add a distinct `message.streaming` field rendered the same way to avoid conflating.
- [ ] **Step 4: Run green** — vitest + tsc.
- [ ] **Step 5: Commit**

```bash
git add frontend/src/App.tsx frontend/src/components/ChatArea.tsx frontend/src/components/__tests__/ChatArea.test.tsx
git commit -m "feat(frontend): growing-message indicator for streaming harness entries"
```

---

### Task 6: Watcher — turn state, live updates, finalize (same id)

**Files:**
- Modify: `src/PureClaw/Harness/Reconcile.hs` (`ReconcileDeps`: change `_rd_recordResponse`, add `_rd_publishUpdate`, `_rd_mintTurn`; `mkTurnEntry`; per-tick update + settle-finalize; turn-state threading)
- Modify: `src/PureClaw/CLI/Commands.hs` (production wiring: `_rd_recordResponse` takes an entry; add `_rd_publishUpdate`, `_rd_mintTurn`)
- Test: `test/Harness/ReconcileSpec.hs`

**Interfaces:**
- Consumes: `_hh_snapshotTurn` (Task 2), `EntryUpdated` (Task 3).
- Produces (exact):
  ```haskell
  -- ReconcileDeps changes:
  _rd_recordResponse :: SessionId -> TranscriptEntry -> IO ()   -- was: SessionId -> Text -> IO ()
  _rd_publishUpdate  :: SessionId -> TranscriptEntry -> IO ()    -- new (ephemeral broker publish)
  _rd_mintTurn       :: IO (Text, UTCTime)                       -- new (fresh turn id + start ts)
  -- pure helper in Reconcile.hs:
  mkTurnEntry :: Text {-turnId-} -> UTCTime -> Text {-payload-} -> TranscriptEntry
  ```
  Loop state gains a turn map `Map Text (Text, UTCTime, Text)` keyed by harness id-text → `(turnId, startTs, lastPushedText)`.

- [ ] **Step 1: Failing tests** (`test/Harness/ReconcileSpec.hs`). **Use the Phase-1 "output watcher" tests (added in Phase 1 Task 7, in this same file) as the EXACT harness**: they drive `runReconcileLoopWith Reconcile.defaultTickMicros deps reg broker logger` under `Async.withAsync`, register one entry with `_he_sessionId = Just "sess-1"` + `_he_handle = Just hh`, script `_rd_capture` to return busy/idle frames across ticks, and capture recorded responses in an `IORef` via the `_rd_recordResponse` stub. Extend that harness: the fake handle's `_hh_snapshotTurn` returns a growing turn across ticks; `_rd_publishUpdate` and `_rd_recordResponse` stubs push the received `TranscriptEntry` into separate `IORef [(SessionId, TranscriptEntry)]`s; `_rd_mintTurn = pure ("turn-1", fixedTs)`. Decode an entry's payload with `decodePayload (_te_payload e)` (the inverse of `encodePayload`, from `PureClaw.Transcript.Types`). Tests:

Write these as FULL `it` blocks with concrete assertions (NOT `pending` — a committed `pending`/`xit` asserts nothing and is a plan failure here; the RED step must be a genuine assertion/compile failure). A payload decodes via `T.decodeUtf8 <$> decodePayload (_te_payload e)` (`decodePayload :: Text -> Maybe ByteString`, exported from `PureClaw.Transcript.Types`). Each test reuses the Phase-1 watcher harness verbatim and adds the recording stubs + fixed `_rd_mintTurn`:

1. **`stable id as the turn grows, then one final on settle`** — `_hh_snapshotTurn` returns `"A"` then `"A\nB"` across two working ticks; capture frames `busy, busy, idle`; `_rd_mintTurn = pure ("turn-1", fixedTs)`. Assert: every captured update entry has `_te_id == "turn-1"`; the decoded update payloads are `["A", "A\nB"]`; exactly ONE captured final entry, `_te_id == "turn-1"`, decoded payload `"A\nB"`.
2. **`unchanged turn published once`** — `_hh_snapshotTurn` returns `"A"` on two consecutive working ticks → assert exactly ONE update captured.
3. **`turn id retired at settle`** — after a turn settles, a SECOND turn (frames `idle, busy, idle` with `_rd_mintTurn` yielding `"turn-2"` on its second call) produces a final with `_te_id == "turn-2"` (fresh id, not `"turn-1"`). (Make `_rd_mintTurn` a counter-backed `IORef` stub returning `turn-1` then `turn-2`.)
4. **`skips unbound harness`** — an entry with `_he_sessionId == Nothing` (or `_he_handle == Nothing`) produces NO updates and NO final.
5. **`loop survives a throwing _rd_publishUpdate`** — the stub throws a non-async `IOException` for harness A on its working tick; assert the loop keeps running and a SECOND healthy harness B still gets its update/final (proves the per-entry `try` + AsyncCancelled re-raise).

Each `it` ends with real `shouldBe`/`shouldSatisfy` on the captured `IORef`s.

- [ ] **Step 2: Run red.** FAIL.
- [ ] **Step 3: Implement.**
`mkTurnEntry` (pure; mirrors the old `recordResponseEntry` fields but parameterised):
```haskell
mkTurnEntry :: Text -> UTCTime -> Text -> TranscriptEntry
mkTurnEntry turnId ts payload = TranscriptEntry
  { _te_id = turnId, _te_timestamp = ts, _te_harness = Just "harness", _te_model = Nothing
  , _te_direction = Response, _te_payload = encodePayload (TE.encodeUtf8 payload)
  , _te_durationMs = Nothing, _te_correlationId = turnId, _te_metadata = Map.empty }
```
`ReconcileDeps`: change `_rd_recordResponse :: SessionId -> TranscriptEntry -> IO ()`; add `_rd_publishUpdate :: SessionId -> TranscriptEntry -> IO ()` and `_rd_mintTurn :: IO (Text, UTCTime)`. `defaultReconcileDeps`: `_rd_publishUpdate = \_ _ -> pure ()`, `_rd_mintTurn = (,) <$> (UUID.toText <$> UUID.nextRandom) <*> getCurrentTime`, `_rd_recordResponse = \_ _ -> pure ()`.
**Loop state: replace Phase-1's `prevResponses` with a single `turnMap :: Map Text (Text, UTCTime, Text)`** (id-text → `(turnId, startTs, lastPushedTurnText)`). The Phase-1 settle path (which used `_hh_snapshot hh 0` = LAST BLOCK + the `prevResponses` content-dedup) is REMOVED and replaced by the turn-based settle below — so there is exactly ONE dedup state (`turnMap`), all keyed on whole-turn text, and the final's content comes from the SAME whole-turn extraction as the updates (resolves the dual-state + final-content ambiguities). `_hh_snapshot` (last-block) is no longer called by the watcher; it remains for `/harness output`. Thread `turnMap` as the loop's third argument in place of `prevResponses` (init `Map.empty`). Per tick, after the existing classify/diff/eviction:

- **Updates** — for each id whose `_to_liveness == LivenessThinking` and entry is bound (`Just realSid <- _he_sessionId`, `Just hh <- _he_handle`): inside `try @SomeException` (AsyncCancelled re-raised, other errors logged + skipped): `turn <- _hh_snapshotTurn hh`; when `not (T.null (T.strip turn))`: look up `turnMap[id]`; if absent, `(turnId, ts) <- _rd_mintTurn`; if present reuse its `(turnId, ts)`; when `turn /= lastPushed` (or no prior): `_rd_publishUpdate (SessionId realSid) (mkTurnEntry turnId ts turn)` and set `turnMap[id] = (turnId, ts, turn)`.
- **Settle** (the existing `settledIds`: prev `Thinking` → now `Idle`/`AwaitingInput`), for a bound id: inside `try @SomeException`:
  - **If `id ∈ turnMap`** (the normal case — the turn streamed): `_rd_recordResponse (SessionId realSid) (mkTurnEntry turnId ts lastPushed)` using the SAME `(turnId, ts)` and the **whole-turn `lastPushed`** text (NOT a re-snapshot, NOT last-block); then DELETE `id` from `turnMap`.
  - **Else** (a turn that settled before any working tick was observed — fast turn): `turn <- _hh_snapshotTurn hh` (whole-turn, NOT `_hh_snapshot`); if non-empty: `(turnId, ts) <- _rd_mintTurn`; `_rd_recordResponse (SessionId realSid) (mkTurnEntry turnId ts turn)`. (Nothing to delete; never entered `turnMap`.)
  - Dedup/no-double-record is structural: `settledIds` fires only on the `Thinking→Idle` EDGE (once per turn), and the turn id is retired from `turnMap` at settle — there is no `prevResponses` content-comparison anymore. Two distinct turns get distinct minted ids (correct — they are different messages).

Production wiring (`CLI/Commands.hs`): `_rd_recordResponse = \sid entry -> bracket (mkBroadcastingFileTranscriptHandle (Just broker) sid logger (sessionsDir </> T.unpack (unSessionId sid) </> "transcript.jsonl")) (\rth -> _th_flush rth >> _th_close rth) (\rth -> _th_record rth entry)`; `_rd_publishUpdate = \sid entry -> _streamBroker_publish broker (EntryUpdated sid entry)`; `_rd_mintTurn = (,) <$> (UUID.toText <$> UUID.nextRandom) <*> getCurrentTime`. DELETE the old `recordResponseEntry` text-builder (superseded by `mkTurnEntry`; confirm no other caller via grep). Add the needed imports to `Reconcile.hs` for `defaultReconcileDeps._rd_mintTurn` (`Data.UUID.V4`/`Data.UUID` and `Data.Time` — both already in `pureclaw.cabal`). NOTE: the discovered-handle capture in Task 2 uses the local alias `realCaptureNamed` (what the existing discovered `_hh_snapshot` uses), not `captureWindowNamed`.
- [ ] **Step 4: Run green** — `--match "/Reconcile/"`, then full suite; build clean under `-Werror` (all `_rd_recordResponse` fakes in ReconcileSpec updated to the entry signature).
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/Reconcile.hs src/PureClaw/CLI/Commands.hs test/Harness/ReconcileSpec.hs
git commit -m "feat(reconcile): live in-place turn updates (stable id) + finalize on settle"
```

---

## Final verification (after all tasks)

- [ ] `nix develop . --command bash -c "cabal clean && cabal build"` — clean under `-Wall -Werror`.
- [ ] `nix develop . --command cabal test` — full suite green.
- [ ] `nix develop . --command cabal test --enable-coverage` — ≥95% per `.coverage-thresholds.json`.
- [ ] `cd frontend && npx tsc --noEmit && npx vitest run` — green.
- [ ] No vacuous tests: `git diff main..HEAD` contains no committed `pending`, `xit`, or `xdescribe` (every planned test asserts real behavior).
- [ ] Manual smoke (live, on a real Claude harness): send a multi-step request from the web UI; confirm a single message grows in place across ~2s ticks with a streaming indicator, then finalizes (indicator clears) and persists once (one entry in the transcript, no duplicate).

## Self-review notes

- **Spec coverage:** whole-turn extraction → Task 1; `_hh_snapshotTurn` → Task 2; `EntryUpdated`/`SeEntryUpdate` ephemeral wire → Task 3; `reconcileEntries` replace + streaming flag → Task 4; growing-message indicator → Task 5; stable-id live updates + finalize-once → Task 6.
- **Streaming flag derivation:** refined from the spec's "field on the wire entry" to "derived from the event type" (`entry-update` ⇒ streaming) — simpler, keeps the Haskell `TranscriptEntry` unpolluted (never persists a streaming flag). Functionally identical to the spec's intent.
- **Turn-boundary:** confirmed empirically — Claude renders the submitted user message as a `❯ <text>` line; `isClaudeUserLine` is reliable (Task 1).
- **Single dedup state:** Phase-1's `prevResponses` (last-block) is REPLACED by the whole-turn `turnMap`; the settle finalizes from `turnMap`'s `lastPushed` whole-turn text (same `turnId`/`ts` as the updates), so the persisted final IS the last live state — no duplicate, no truncation, no dual-state. `_hh_snapshot` (last-block) is no longer called by the watcher (still used by `/harness output`). Turn-id retirement at settle is the only dedup needed (settle fires once per Thinking→Idle edge).
- **No vacuous tests:** Task 6 tests are full `it` blocks with concrete assertions (no `pending`), and Final Verification greps the diff to enforce it.
- **Loop state** lives in the loop fold (not on `HarnessEntry`), like Phase 1's prevCaps.
- **Known Phase-2 limits (carried from spec):** reconnect mid-turn shows the last persisted state and re-streams within a tick; server restart mid-turn risks one content-deduped duplicate; provider/LLM path untouched.
