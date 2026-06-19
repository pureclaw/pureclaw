# Harness Output Streaming — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tmux-harness output (Claude Code today) flow reliably into the PureClaw session — on-demand via a `/harness output` command and automatically via a background watcher — with correct working / idle / awaiting-input detection.

**Architecture:** A per-flavour pure `HarnessObserver` (classify activity + extract response + relevant tail) replaces the broken `isIdle`. The reconcile loop (already polling every 2 s) adopts the observer and becomes the sole recorder of harness Response output on working→settle transitions. The harness send path is decoupled from receive. A `_hh_snapshot` handle capability powers the on-demand command.

**Tech Stack:** Haskell (GHC 9.12, `-Wall -Werror`, hspec, TDD); React/TypeScript (vitest) for the status pill.

**Design spec:** `docs/superpowers/specs/2026-06-18-harness-output-streaming-design.md`

## Global Constraints

- Build/test only via Nix: `nix develop . --command cabal build` / `… cabal test`. Never bare `cabal`.
- GHC `-Wall -Werror -Wincomplete-record-updates -Wmissing-export-lists`; hlint clean. Adding a record field means updating ALL construction sites.
- Import style: `qualified as` (no explicit import lists except canonical `import Data.Set (Set)`).
- TDD mandatory: write the failing test, run it red, implement minimally, run green, commit. Commit the failing test separately is encouraged but a single red→green→commit per step is acceptable.
- Coverage gate: `.coverage-thresholds.json` (lines/branches/functions/statements ≥ 95), enforced via `cabal test --enable-coverage`. Blocking before PR.
- Frontend: `cd frontend && npx vitest run` and `npx tsc --noEmit` must pass; no eslint gate.
- `HarnessEntry` does NOT derive Eq/Show (it holds a `HarnessHandle`); do not add deriving.
- AsyncCancelled must always be re-raised in any catch-all (project invariant) — see reconcile loop's `outer` handler.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `src/PureClaw/Harness/Tmux.hs` | tmux capture argv | add `-J` to `captureNamedArgs` |
| `src/PureClaw/Harness/Observer.hs` | **NEW** per-flavour pure detection/extraction seam | create |
| `src/PureClaw/Frontend/Activity/Types.hs` | `HarnessActivity` vocabulary | add `HarnessNeedsInput` |
| `src/PureClaw/Frontend/Stream.hs` | `ActivityKind` + encoding | (no change — encodes via `HarnessActivity`) |
| `src/PureClaw/Harness/Registry.hs` | `Liveness`, `HarnessEntry` | add `LivenessAwaitingInput`, `_he_flavour` |
| `src/PureClaw/Frontend/TabsView.hs` | `livenessToTabStatus` | add `LivenessAwaitingInput` arm |
| `src/PureClaw/Handles/Harness.hs` | `HarnessHandle` | add `_hh_snapshot` |
| `src/PureClaw/Harness/ClaudeCode.hs` | Claude handle + (now thin) marker reuse | wire `_hh_snapshot`; use Observer in `pollUntilIdle` |
| `src/PureClaw/Harness/Reconcile.hs` | activity classification + output watcher | observer-based classify; record on settle |
| `src/PureClaw/Agent/SlashCommands.hs` | `/harness output` | add subcommand + spec + parser + handler |
| `src/PureClaw/Frontend/API.hs` | send path | decouple send from receive |
| `frontend/src/types.ts` | `HarnessActivity` TS type | add `'needs-input'` |
| `frontend/src/components/StatusDot.tsx` | activity → dot class | add `'needs-input'` key |
| `test/fixtures/harness/*.txt` | **NEW** real capture fixtures | create |

## Cascade & construction-site inventory (-Werror)

Adding constructors/fields forces edits at EVERY match/construction site. These are the complete, verified lists; the owning task must edit all of them (file scope includes every file named here).

**Adding `LivenessAwaitingInput` to `Liveness` (Task 3)** — every exhaustive `case` on `Liveness`:
- `src/PureClaw/Harness/Reconcile.hs` `livenessToActivity` → `HarnessNeedsInput` (Task 6 finalizes).
- `src/PureClaw/Frontend/TabsView.hs:105-111` `livenessToTabStatus` → `"running"` (the tab-row status keeps its existing 4-value frontend vocabulary; the awaiting-input distinction is carried by the activity dot, not the tab badge). Add a test asserting this in `test/Frontend/TabsViewSpec.hs` and the `livenessToTabStatus` describe in `test/Frontend/APISpec.hs`.
- Any other `case … of` on `Reg.Liveness` the compiler flags (e.g. `diffLiveness` in Reconcile.hs uses `Eq`, not a case — no change). Build to confirm none remain.

**Adding `HarnessNeedsInput` to `HarnessActivity` (Task 3)** — every exhaustive site:
- `ToJSON HarnessActivity` (Activity/Types.hs) → `"needs-input"`.
- `frontend/src/types.ts` `HarnessActivity` union → add `'needs-input'`.
- `frontend/src/components/StatusDot.tsx` `activityDotClass: Record<HarnessActivity,string>` → add key.
- Confirm no other exhaustive Haskell `case` on `HarnessActivity` (grep: only the `ToJSON` instance).

**Adding `_he_flavour :: !HarnessFlavour` to `HarnessEntry` (Task 6)** — ALL 8 construction sites:
- `src/PureClaw/Harness/ClaudeCode.hs:331`, `:547`
- `src/PureClaw/Harness/Reconcile.hs:545` (boot reconstruct)
- `test/Frontend/TabsViewSpec.hs:62`
- `test/Frontend/APISpec.hs:~4182` (`baseEntry`)
- `test/Harness/RegistrySpec.hs:30` (`mkEntry`) and `:303` (inline)
- `test/Harness/ReconcileSpec.hs:57` (`mkEntry`)
All set `HClaudeCode` (every current harness is Claude Code).

**Adding `_hh_snapshot :: Int -> IO Text` to `HarnessHandle` (Task 4)** — ALL construction sites:
- `src/PureClaw/Handles/Harness.hs:45` (`mkNoOpHarnessHandle`) → `\_ -> pure ""`
- `src/PureClaw/Harness/ClaudeCode.hs:399` (real), `:857` (discovered) → real wiring
- `src/PureClaw/Agent/SlashCommands.hs:~2416` (`mkHandle`) → wire or `\_ -> pure ""`
- `test/Frontend/APISpec.hs:4017,4049,4064`; `test/Tabs/RuntimesSpec.hs:188,428,498` → `\_ -> pure ""`
- Any inline `HarnessHandle{…}` the compiler flags.

**`isIdle` disposition (Task 8)** — `isIdle` (ClaudeCode.hs:782) has call sites at `ClaudeCode.hs:753` and `:918`, is exported (`:23`), and imported by `Reconcile.hs:85`. It is NOT deleted; it is redefined via the observer (see Task 8). The `Reconcile.hs:85` import is dropped in Task 6 (the reconcile path moves to `_ho_classify`). Its direct tests at `test/Harness/ClaudeCodeSpec.hs:444-451` are updated to the corrected expectations in Task 8.

**`classifyLiveness` disposition (Task 6)** — `classifyLiveness` (Reconcile.hs:222) is REPLACED by `classifyFromObserver`. Its direct tests at `test/Harness/ReconcileSpec.hs:171-179` are removed and replaced by the `classifyFromObserver` tests in Task 6.

**`_rd_capture` signature change (Task 6)** — `_rd_capture :: Text -> Text -> IO Bool` (Reconcile.hs:111) becomes `IO (Maybe Text)`. This is a `-Werror` type break at every fake-deps site in `test/Harness/ReconcileSpec.hs`: `:108`, `:116`, `:365`, `:559` (and `defaultReconcileDeps` at Reconcile.hs:143). All must be updated: the production dep returns `Just <raw capture>`/`Nothing`; fakes return `Just "<frame text>"` / `Nothing`. ReconcileSpec is in Task 6 scope.

**`reconcileTick` / `classifyRow` / loop signatures (Tasks 6, 7)** — these change concretely (new prev-capture + prev-response threading); the exact new signatures are given in Tasks 6 and 7. Any test calling `reconcileTick`/`classifyRow` directly (search `test/Harness/ReconcileSpec.hs` for both names) is updated there.

---

### Task 1: Capture joins wrapped lines (`-J`)

**Files:**
- Modify: `src/PureClaw/Harness/Tmux.hs` (`captureNamedArgs`, lines 387-391)
- Test: `test/Harness/TmuxSpec.hs` (add to existing capture-args describe; if none, add a new `describe`)

**Interfaces:**
- Produces: `captureNamedArgs :: Text -> Text -> Int -> [String]` (unchanged signature; argv now contains `-J`).

- [ ] **Step 1: Write the failing test**

```haskell
  describe "captureNamedArgs" $
    it "joins wrapped lines with -J so long lines are not split" $
      captureNamedArgs "sess" "win" 50
        `shouldBe`
        [ "capture-pane", "-t", "sess:win", "-p", "-J", "-S", "-50" ]
```

- [ ] **Step 2: Run red**

Run: `nix develop . --command cabal test --test-options='--match "/captureNamedArgs/"'`
Expected: FAIL — actual list lacks `"-J"`.

- [ ] **Step 3: Implement**

```haskell
captureNamedArgs :: Text -> Text -> Int -> [String]
captureNamedArgs sessionName windowName lineCount =
  [ "capture-pane", "-t", windowTarget sessionName windowName
  , "-p", "-J", "-S", "-" <> show lineCount
  ]
```

- [ ] **Step 4: Run green** — same command, PASS.
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/Tmux.hs test/Harness/TmuxSpec.hs
git commit -m "feat(tmux): join wrapped lines with -J in capture-pane"
```

---

### Task 2: `HarnessObserver` module (per-flavour detection + extraction)

**Files:**
- Create: `src/PureClaw/Harness/Observer.hs`
- Create fixtures: `test/fixtures/harness/claude-working.txt`, `claude-idle.txt`, `claude-approval.txt`, `claude-response.txt`, `claude-menu-cursor.txt`
- Test: `test/Harness/ObserverSpec.hs`
- Modify: `pureclaw.cabal` (add `PureClaw.Harness.Observer` to library `exposed-modules` and `Harness.ObserverSpec` to the test suite `other-modules`)

**Interfaces:**
- Produces:
  ```haskell
  data HarnessActivityState = HasWorking | HasAwaitingInput | HasIdle
    deriving stock (Eq, Show)
  data HarnessObserver = HarnessObserver
    { _ho_classify        :: Text -> HarnessActivityState
    , _ho_extractResponse :: Int -> ByteString -> Text
    , _ho_relevantTail    :: Int -> ByteString -> Text
    }
  observerFor :: HarnessFlavour -> HarnessObserver
  claudeObserver :: HarnessObserver
  genericObserver :: HarnessObserver
  ```
- Consumes: `HarnessFlavour` from `PureClaw.Session.Kind`.

**Fixtures (create from real captures — representative content):**

`test/fixtures/harness/claude-working.txt`:
```
⏺ Reading the file to understand the layout.

  Read 1 file (ctrl+o to expand)

✶ Smooshing… (4m 55s · ↓ 16.6k tokens)
────────────────────────────────────────
❯
────────────────────────────────────────
  arrakis /path [Opus 4.8 | ctx: 77% left]
```

`test/fixtures/harness/claude-idle.txt`:
```
⏺ Done. Applied the fix to foo.ts and ran the tests.

────────────────────────────────────────
❯
────────────────────────────────────────
  arrakis /path [Opus 4.8 | ctx: 77% left]
```

`test/fixtures/harness/claude-approval.txt`:
```
⏺ I'll run the test suite.

  Bash(npm test)
  Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again
  3. No
```

`test/fixtures/harness/claude-response.txt`:
```
❯ fix the bug in foo.ts

⏺ I found the bug in foo.ts:42 — an off-by-one. Here is the fix.

  Read 1 file (ctrl+o to expand)
⏺ Applied the change and the tests pass.
────────────────────────────────────────
❯
────────────────────────────────────────
```

`test/fixtures/harness/claude-menu-cursor.txt` (the `❯ N.` ambiguity — must NOT be idle):
```
⏺ Which layout?
❯ 1. Mobile only
  2. All sizes
```

- [ ] **Step 1: Write failing tests** (`test/Harness/ObserverSpec.hs`)

```haskell
module Harness.ObserverSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           PureClaw.Harness.Observer
import           PureClaw.Session.Kind (HarnessFlavour (..))
import           Test.Hspec

loadFix :: FilePath -> IO BS.ByteString
loadFix name = BS.readFile ("test/fixtures/harness/" <> name)

spec :: Spec
spec = do
  describe "claudeObserver._ho_classify" $ do
    it "HasWorking when a spinner/status line is present" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-working.txt"
      _ho_classify claudeObserver t `shouldBe` HasWorking
    it "HasAwaitingInput on an approval prompt" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-approval.txt"
      _ho_classify claudeObserver t `shouldBe` HasAwaitingInput
    it "HasIdle on a bare prompt with no spinner/approval" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-idle.txt"
      _ho_classify claudeObserver t `shouldBe` HasIdle
    it "is NOT HasIdle when the prompt is a menu cursor (❯ N.)" $ do
      t <- TE.decodeUtf8 <$> loadFix "claude-menu-cursor.txt"
      _ho_classify claudeObserver t `shouldNotBe` HasIdle

  describe "claudeObserver._ho_extractResponse" $ do
    it "returns the last assistant block, marker + chrome stripped" $ do
      cap <- loadFix "claude-response.txt"
      let out = _ho_extractResponse claudeObserver 0 cap
      out `shouldSatisfy` T.isInfixOf "Applied the change and the tests pass."
      out `shouldNotSatisfy` T.isInfixOf "\x23FA"        -- no ⏺ marker
      out `shouldNotSatisfy` T.isInfixOf "ctrl+o"         -- chrome stripped
      out `shouldNotSatisfy` T.isInfixOf "fix the bug"    -- not the user line
    it "returns the prompt text when awaiting input" $ do
      cap <- loadFix "claude-approval.txt"
      _ho_extractResponse claudeObserver 0 cap
        `shouldSatisfy` T.isInfixOf "Do you want to proceed?"

  describe "claudeObserver._ho_relevantTail" $
    it "returns the last N cleaned lines without box-drawing chrome" $ do
      cap <- loadFix "claude-idle.txt"
      let out = _ho_relevantTail claudeObserver 3 cap
      length (T.lines out) `shouldSatisfy` (<= 3)
      out `shouldNotSatisfy` T.isInfixOf "────"

  describe "genericObserver" $ do
    it "classify is always HasIdle (no markers; stability decides in the loop)" $
      _ho_classify genericObserver "anything at all" `shouldBe` HasIdle
    it "relevantTail returns the last N lines" $
      _ho_relevantTail genericObserver 2 (TE.encodeUtf8 "a\nb\nc\nd")
        `shouldBe` "c\nd"

  describe "observerFor" $ do
    it "maps HClaudeCode to the Claude observer" $
      _ho_classify (observerFor HClaudeCode) "✶ Working… (3s · 1k tokens)"
        `shouldBe` HasWorking
    it "maps non-Claude flavours to the generic observer" $
      _ho_classify (observerFor HCodex) "✶ anything" `shouldBe` HasIdle
```

- [ ] **Step 2: Run red**

Run: `nix develop . --command cabal test --test-options='--match "/claudeObserver/"'`
Expected: FAIL — module/functions not defined.

- [ ] **Step 3: Implement `src/PureClaw/Harness/Observer.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Per-flavour, PURE detection and extraction of harness terminal output.
-- Each harness TUI (Claude Code, Codex, …) draws its screen differently, so
-- working/idle/awaiting-input detection and response extraction are
-- flavour-specific. The reconcile loop and the @/harness output@ command both
-- select an observer via 'observerFor'. Heuristics are facts about each tool's
-- terminal output; they were validated against live captures (faryo, MIT, was
-- a reference for the patterns).
module PureClaw.Harness.Observer
  ( HarnessActivityState (..)
  , HarnessObserver (..)
  , observerFor
  , claudeObserver
  , genericObserver
  ) where

import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import           Data.Char (isSpace)
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import           PureClaw.Session.Kind (HarnessFlavour (..))

data HarnessActivityState = HasWorking | HasAwaitingInput | HasIdle
  deriving stock (Eq, Show)

data HarnessObserver = HarnessObserver
  { _ho_classify        :: Text -> HarnessActivityState
  , _ho_extractResponse :: Int -> ByteString -> Text
  , _ho_relevantTail    :: Int -> ByteString -> Text
  }

observerFor :: HarnessFlavour -> HarnessObserver
observerFor HClaudeCode = claudeObserver
observerFor _           = genericObserver

-- ── Claude Code ────────────────────────────────────────────────────────────

-- | Spinner glyphs Claude rotates while working (Dingbats range + a few extras).
claudeSpinnerGlyphs :: [Char]
claudeSpinnerGlyphs = "·✢✱✲✳✴✵✶✷✸✹✺✻✼✽✾✿★"

-- | A working/status line: a spinner glyph followed by a gerund, or an
-- @(Ns · …tokens|thinking)@ counter, or the @esc to interrupt@ hint.
isClaudeWorkingLine :: Text -> Bool
isClaudeWorkingLine raw =
  let l = T.stripStart raw
  in (not (T.null l) && T.head l `elem` claudeSpinnerGlyphs
       && (T.isInfixOf "…" l || T.isInfixOf "..." l))
     || hasTokenCounter l
     || T.isInfixOf "esc to interrupt" (T.toLower l)
  where
    hasTokenCounter t =
      T.isInfixOf "tokens" (T.toLower t)
      && T.isInfixOf "(" t && T.isInfixOf ")" t

-- | An approval/menu prompt: Claude is blocked on the user.
isClaudeApprovalLine :: Text -> Bool
isClaudeApprovalLine raw =
  let l = T.toLower (T.stripStart raw)
  in T.isInfixOf "do you want to proceed?" l
     || T.isInfixOf "yes, and don't ask again" l
     || T.isInfixOf "yes, and don\8217t ask again" l
     || T.isInfixOf "enter to confirm" l
     || T.isInfixOf "esc to cancel" l
     || isNumberedYesNo (T.stripStart raw)

-- | A numbered option line, optionally led by the @❯@ menu cursor: @❯ 1. Yes@.
isNumberedYesNo :: Text -> Bool
isNumberedYesNo l0 =
  let l = T.dropWhile (`elem` ("\10095\8250 " :: String)) l0  -- strip ❯ ›  and spaces
  in case T.span (`elem` ("0123456789" :: String)) l of
       (ds, rest) -> not (T.null ds) && T.isPrefixOf "." rest

-- | The idle input prompt: a bare @❯@/@›@ NOT followed by a number+dot
-- (which would be a menu-selection cursor, not the prompt).
isIdlePromptLine :: Text -> Bool
isIdlePromptLine raw =
  let l = T.stripStart raw
  in (T.isPrefixOf "\10095" l || T.isPrefixOf "\8250" l)  -- ❯ ›
     && not (isNumberedYesNo l)

classifyClaude :: Text -> HarnessActivityState
classifyClaude screen =
  let ls = T.lines screen
  in if any isClaudeWorkingLine ls then HasWorking
     else if any isClaudeApprovalLine ls then HasAwaitingInput
     else HasIdle

-- | True for chrome lines that must never appear in extracted output.
isClaudeChrome :: Text -> Bool
isClaudeChrome raw =
  let l = T.stripStart raw
  in T.null (T.strip l)
     || isClaudeWorkingLine raw
     || (isIdlePromptLine raw && T.null (T.strip (T.drop 1 l)))
     || T.isInfixOf "for shortcuts" (T.toLower l)
     || T.isInfixOf "ctrl+o to expand" (T.toLower l)
     || T.all (\c -> c == '\9472' || c == '\9600' || c == '\9604' || isSpace c) l  -- ─ ▀ ▄

isResponseMarkerLine :: Text -> Bool
isResponseMarkerLine line =
  let l = T.stripStart line
  in T.isPrefixOf "\x23FA" l    -- ⏺
     || T.isPrefixOf "\x25CF" l -- ● (alternate, faryo)
     || T.isPrefixOf "\x2B24" l -- ⬤ (alternate)

stripResponseMarker :: Text -> Text
stripResponseMarker line =
  T.stripStart (T.dropWhile (`elem` ("\x23FA\x25CF\x2B24 " :: String)) (T.stripStart line))

isClaudeUserLine :: Text -> Bool
isClaudeUserLine raw =
  let l = T.stripStart raw
  in (T.isPrefixOf "\10095" l) && not (isNumberedYesNo l)
     && not (T.null (T.strip (T.drop 1 l)))

-- | Extract the latest assistant response. When awaiting input, return the
-- approval/menu prompt block so the user sees the question.
extractClaude :: Int -> ByteString -> Text
extractClaude baseline capture =
  let body = dropBaseline baseline capture
      ls   = T.lines (TE.decodeUtf8Lenient body)
  in if any isClaudeApprovalLine ls
       then T.strip . T.unlines $ dropWhile (not . isClaudeApprovalLine) ls
       else case reverse [ i | (i, l) <- zip [0 :: Int ..] ls, isResponseMarkerLine l ] of
              []      -> ""
              (i : _) ->
                let block   = takeWhile (not . isIdlePromptLine) (drop i ls)
                    cleaned = case block of
                      (h : rest) -> stripResponseMarker h : filter (not . isClaudeChrome) rest
                      []         -> []
                in T.strip (T.intercalate "\n" (filter (not . T.null) cleaned))

relevantTailClaude :: Int -> ByteString -> Text
relevantTailClaude n capture =
  let ls = filter (not . isClaudeChrome) (T.lines (TE.decodeUtf8Lenient capture))
  in T.intercalate "\n" (lastN n ls)

claudeObserver :: HarnessObserver
claudeObserver = HarnessObserver
  { _ho_classify        = classifyClaude
  , _ho_extractResponse = extractClaude
  , _ho_relevantTail    = relevantTailClaude
  }

-- ── Generic fallback (Codex/OpenCode/Hermes/PureClaw/Custom) ─────────────────

genericObserver :: HarnessObserver
genericObserver = HarnessObserver
  { _ho_classify        = const HasIdle   -- stability in the loop is the only signal
  , _ho_extractResponse = \n cap -> T.intercalate "\n" (lastN (max 1 n) (cleanLines cap))
  , _ho_relevantTail    = \n cap -> T.intercalate "\n" (lastN n (cleanLines cap))
  }
  where cleanLines cap = filter (not . T.null . T.strip) (T.lines (TE.decodeUtf8Lenient cap))

-- ── Shared helpers ───────────────────────────────────────────────────────────

dropBaseline :: Int -> ByteString -> ByteString
dropBaseline n cap
  | n <= 0    = cap
  | otherwise = BS.intercalate (BS.singleton 0x0A) (drop n (BS.split 0x0A cap))

lastN :: Int -> [a] -> [a]
lastN n xs = drop (length xs - n) xs
```

Note: the generic `_ho_extractResponse 0` returns the whole cleaned capture (`max 1 0 = 1`? no — fix: use `n` directly with a sensible default). For the watcher, the generic path will pass an explicit line count. Verify against the test `genericObserver relevantTail` returns `"c\nd"`.

- [ ] **Step 4: Run green** — `nix develop . --command cabal test --test-options='--match "/Harness.Observer/"'`. PASS. Adjust glyph/regex details against fixtures until green.
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/Observer.hs test/Harness/ObserverSpec.hs test/fixtures/harness pureclaw.cabal
git commit -m "feat(harness): per-flavour HarnessObserver (classify/extract/tail) with golden fixtures"
```

---

### Task 3: Add `HarnessNeedsInput` to the activity vocabulary (end to end)

**Files:**
- Modify: `src/PureClaw/Frontend/Activity/Types.hs:17-26` (`HarnessActivity` + `ToJSON`)
- Modify: `src/PureClaw/Harness/Registry.hs:110-115` (`Liveness` — add `LivenessAwaitingInput`)
- Modify: `src/PureClaw/Frontend/TabsView.hs:105-111` (`livenessToTabStatus` — add arm → `"running"`)
- Test: `test/Frontend/ActivityTypesSpec.hs` (or existing); `test/Frontend/TabsViewSpec.hs`; `test/Frontend/APISpec.hs` (`livenessToTabStatus` describe); `frontend/src/components/__tests__/StatusDot.test.tsx`
- Modify: `frontend/src/types.ts:13` (`HarnessActivity` union); `frontend/src/components/StatusDot.tsx:10-14`

This task adds BOTH enum constructors and resolves every exhaustive-match site in the Cascade inventory above. After implementing, build under `-Werror` and fix any case the compiler flags.

**Interfaces:**
- Produces: `HarnessActivity` gains `HarnessNeedsInput` (JSON `"needs-input"`); `Liveness` gains `LivenessAwaitingInput`. TS `HarnessActivity` gains `'needs-input'`.

- [ ] **Step 1: Failing Haskell test** (`test/Frontend/ActivityTypesSpec.hs`)

```haskell
    it "encodes HarnessNeedsInput as \"needs-input\"" $
      Aeson.toJSON HarnessNeedsInput `shouldBe` Aeson.String "needs-input"
```

- [ ] **Step 2: Run red** — `nix develop . --command cabal test --test-options='--match "/needs-input/"'`. FAIL (constructor undefined).
- [ ] **Step 3: Implement Haskell**

`Activity/Types.hs`:
```haskell
data HarnessActivity
  = HarnessThinking
  | HarnessIdle
  | HarnessNeedsInput
  | HarnessStopped
  deriving stock (Show, Eq)

instance ToJSON HarnessActivity where
  toJSON HarnessThinking   = Aeson.String "thinking"
  toJSON HarnessIdle       = Aeson.String "idle"
  toJSON HarnessNeedsInput = Aeson.String "needs-input"
  toJSON HarnessStopped    = Aeson.String "stopped"
```

`Registry.hs`:
```haskell
data Liveness
  = LivenessIdle
  | LivenessThinking
  | LivenessAwaitingInput  -- ^ Window present, harness blocked on an approval/menu prompt.
  | LivenessExited
  | LivenessOrphaned
  deriving stock (Eq, Show)
```

- [ ] **Step 4a: Add the `livenessToTabStatus` arm** (`TabsView.hs:105-111`) — required now because the new `Liveness` constructor makes this `case` non-exhaustive under `-Werror`:

```haskell
livenessToTabStatus lv = case lv of
  Registry.LivenessIdle          -> "idle"
  Registry.LivenessThinking      -> "running"
  Registry.LivenessAwaitingInput -> "running"  -- distinct state shown via the activity dot, not the tab badge
  Registry.LivenessExited        -> "exited"
  Registry.LivenessOrphaned      -> "orphaned"
```

Add a test in `test/Frontend/TabsViewSpec.hs` (and the `livenessToTabStatus` describe in `test/Frontend/APISpec.hs`): `livenessToTabStatus Registry.LivenessAwaitingInput \`shouldBe\` "running"`.

- [ ] **Step 4b: Run green** (Haskell). Then fix any remaining non-exhaustive `case` on `Liveness`/`HarnessActivity` the compiler flags under `-Werror` — in particular `livenessToActivity` (Task 6 finalizes it; for now add `LivenessAwaitingInput -> HarnessNeedsInput`).
- [ ] **Step 5: Failing frontend test** (`StatusDot.test.tsx`)

```tsx
import { render } from '@testing-library/react'
import { ActivityDot } from '../StatusDot'

it('renders a needs-input activity with the dot-needs class', () => {
  const { container } = render(<ActivityDot activity={'needs-input'} />)
  expect(container.firstChild).toHaveClass('dot-needs')
})
```

- [ ] **Step 6: Run red** — `cd frontend && npx vitest run src/components/__tests__/StatusDot.test.tsx`. FAIL (type + missing key).
- [ ] **Step 7: Implement frontend**

`types.ts:13`:
```ts
export type HarnessActivity = 'thinking' | 'idle' | 'needs-input' | 'stopped'
```

`StatusDot.tsx:10-14`:
```tsx
const activityDotClass: Record<HarnessActivity, string> = {
  'thinking': 'dot dot-thinking',
  'idle': 'dot dot-idle',
  'needs-input': 'dot dot-needs',
  'stopped': 'dot dot-completed',
}
```

- [ ] **Step 8: Run green** (`npx vitest run` + `npx tsc --noEmit`).
- [ ] **Step 9: Commit**

```bash
git add src/PureClaw/Frontend/Activity/Types.hs src/PureClaw/Harness/Registry.hs \
        src/PureClaw/Frontend/TabsView.hs test/Frontend/ActivityTypesSpec.hs \
        test/Frontend/TabsViewSpec.hs test/Frontend/APISpec.hs frontend/src/types.ts \
        frontend/src/components/StatusDot.tsx frontend/src/components/__tests__/StatusDot.test.tsx
git commit -m "feat(activity): add needs-input / awaiting-input state end to end"
```

---

### Task 4: `HarnessHandle` gains `_hh_snapshot` (non-blocking capture+extract)

**Files:**
- Modify: `src/PureClaw/Handles/Harness.hs:35-42` (add field) + `mkNoOpHarnessHandle:45`
- Modify: `src/PureClaw/Harness/ClaudeCode.hs:399` (real handle) and `:857` (discovered handle) — wire it
- Modify: `src/PureClaw/Agent/SlashCommands.hs:~2416` (`mkHandle`) — `_hh_snapshot = \_ -> pure ""`
- Modify: `test/Frontend/APISpec.hs:4017,4049,4064`, `test/Tabs/RuntimesSpec.hs:188,428,498` — `_hh_snapshot = \_ -> pure ""`
- Test: `test/Harness/ClaudeCodeSpec.hs`

See the Cascade inventory for the complete construction-site list. The `_hh_snapshot` field is added to the record; every site above plus any inline `HarnessHandle{…}` the compiler flags must be updated (`-Werror`).

**Interfaces:**
- Produces: `_hh_snapshot :: Int -> IO Text` on `HarnessHandle` — "capture the pane now and return the latest response (N≤0) or the last N relevant lines (N>0)" via the flavour observer. Non-blocking (single capture; no poll).

- [ ] **Step 1: Failing test** — extend an adopt/handle test to assert a snapshot returns the latest response from a fake capture:

```haskell
    it "_hh_snapshot returns the latest extracted response (no polling)" $
      withSystemTempDirectory "pcl-snap" $ \tmp -> do
        reg <- Reg.newRegistry
        let deps = okDeps
              { _ccd_newId        = pure fixedId
              , _ccd_sweep        = \_ -> pure [adoptableRow 0 "win-snap"]
              , _ccd_panePidOf    = \_ _ -> pure (Just 7)
              , _ccd_captureNamed = \_ _ _ -> pure (Just (TE.encodeUtf8
                  "\x23FA Hello from the harness.\n\10095\n"))
              }
        Right (_, hh) <- adoptExternalWindow deps reg mkNoOpTranscriptHandle tmp mkToken Nothing "win-snap"
        out <- _hh_snapshot hh 0
        out `shouldSatisfy` T.isInfixOf "Hello from the harness."
```

- [ ] **Step 2: Run red** — record-field `_hh_snapshot` undefined. FAIL.
- [ ] **Step 3: Implement field** (`Handles/Harness.hs`)

```haskell
data HarnessHandle = HarnessHandle
  { _hh_send     :: ByteString -> IO ()
  , _hh_receive  :: IO ByteString
  , _hh_snapshot :: Int -> IO Text   -- ^ one-shot capture+extract via the flavour observer
  , _hh_name     :: Text
  , _hh_session  :: Text
  , _hh_status   :: IO HarnessStatus
  , _hh_stop     :: IO ()
  }
```

- [ ] **Step 4: Implement Claude wiring** — in `mkClaudeCodeHandleWithBaseline` (and `mkDiscoveredClaudeCodeHandle`), where `session`, `windowName`/coord resolution, and `baselineRef` are in scope, add:

```haskell
    , _hh_snapshot = \n -> do
        mCoord <- currentCoord reg hid
        case mCoord of
          Nothing -> pure ""
          Just (sess, win) -> do
            raw <- fromMaybe "" <$> _ccd_captureNamed deps sess win (if n <= 0 then 0 else max n 50)
            baseline <- readIORef baselineRef
            let obs = observerFor HClaudeCode
            pure $ if n <= 0
              then _ho_extractResponse obs baseline raw
              else _ho_relevantTail obs n raw
```

(For `mkDiscoveredClaudeCodeHandle`, which has `session`/`windowName` directly and no baseline IORef, pass baseline `0` and capture by name via `captureWindowNamed`.)

- [ ] **Step 5: Update ALL other construction sites** — add `_hh_snapshot = \_ -> pure ""` at each site in the Cascade inventory: `Handles/Harness.hs:45` (`mkNoOpHarnessHandle`), `SlashCommands.hs:~2416` (`mkHandle`), `APISpec.hs:4017,4049,4064`, `RuntimesSpec.hs:188,428,498`, plus any inline `HarnessHandle{…}` the compiler flags. Confirm with: `awk '/HarnessHandle$|HarnessHandle \{|HarnessHandle$/{print FILENAME":"NR}' $(find src test -name '*.hs')`.
- [ ] **Step 6: Run green** — `nix develop . --command cabal test --test-options='--match "/_hh_snapshot/"'`. PASS; `nix develop . --command cabal build` clean under `-Werror`.
- [ ] **Step 7: Commit**

```bash
git add src/PureClaw/Handles/Harness.hs src/PureClaw/Harness/ClaudeCode.hs \
        src/PureClaw/Agent/SlashCommands.hs test/Harness/ClaudeCodeSpec.hs \
        test/Frontend/APISpec.hs test/Tabs/RuntimesSpec.hs
git commit -m "feat(harness): _hh_snapshot one-shot capture+extract on HarnessHandle"
```

---

### Task 5: `/harness output [name] [N]` slash command

**Files:**
- Modify: `src/PureClaw/Agent/SlashCommands.hs` (`HarnessSubCommand`:178-184; `harnessCommandSpecs`:410-416; a new parser; `executeHarnessCommand`:1820)
- Test: `test/Agent/SlashCommandsSpec.hs` (parser); `test/Frontend/APISpec.hs` (web dispatch, optional)

**Interfaces:**
- Consumes: `_hh_snapshot` (Task 4); `_env_harnesses` (`IORef (Map Text HarnessHandle)`).
- Produces: `HarnessSubCommand` gains `HarnessOutput (Maybe Text) Int` (optional name, line count; 0 = latest response).

- [ ] **Step 1: Failing parser test**

```haskell
    it "parses /harness output with optional name and N" $ do
      parseInputCmd "/harness output"          `shouldBe` Just (CmdHarness (HarnessOutput Nothing 0))
      parseInputCmd "/harness output coder"    `shouldBe` Just (CmdHarness (HarnessOutput (Just "coder") 0))
      parseInputCmd "/harness output coder 40" `shouldBe` Just (CmdHarness (HarnessOutput (Just "coder") 40))
```

(Use the project's existing parse entry point used by other harness parser tests.)

- [ ] **Step 2: Run red.** FAIL (constructor + parser missing).
- [ ] **Step 3: Implement constructor + spec + parser**

`HarnessSubCommand` (add):
```haskell
  | HarnessOutput (Maybe Text) Int  -- ^ Show last response (N=0) or last N relevant lines
```

`harnessCommandSpecs` (add):
```haskell
  , CommandSpec "/harness output [name] [N]" "Show recent harness output (last response, or last N lines)" GroupHarness harnessOutputP
```

Parser:
```haskell
harnessOutputP :: Text -> Maybe SlashCommand
harnessOutputP t =
  case T.words t of
    (cmd : "output" : rest) | T.toLower cmd == "/harness" ->
      Just $ CmdHarness $ case rest of
        []        -> HarnessOutput Nothing 0
        [a]       -> case readMaybeInt a of
                       Just n  -> HarnessOutput Nothing n
                       Nothing -> HarnessOutput (Just a) 0
        (a : b : _) -> HarnessOutput (Just a) (maybe 0 id (readMaybeInt b))
    _ -> Nothing
  where readMaybeInt = fmap fst . listToMaybe . reads . T.unpack
```

- [ ] **Step 4: Run green** (parser). PASS.
- [ ] **Step 5: Failing handler test** — in `executeHarnessCommand`, with a fake handle whose `_hh_snapshot` returns a known string, assert the command sends it. Mirror the existing `HarnessList` handler test harness (a captured channel + `_env_harnesses`).

```haskell
    it "HarnessOutput sends the snapshot text for the named harness" $ do
      (env, readOut) <- mkCapturingEnv  -- builds AgentEnv with a capture channel
      let hh = noopHandle { _hh_snapshot = \_ -> pure "latest harness reply" }
      writeIORef (_env_harnesses env) (Map.fromList [("coder", hh)])
      _ <- executeSlashCommand env (CmdHarness (HarnessOutput (Just "coder") 0)) emptyCtx
      out <- readOut
      out `shouldSatisfy` T.isInfixOf "latest harness reply"
```

- [ ] **Step 6: Run red.** FAIL (no handler case).
- [ ] **Step 7: Implement handler** in `executeHarnessCommand` (alongside `HarnessList`):

```haskell
    HarnessOutput mName n -> do
      harnesses <- readIORef (_env_harnesses env)
      let pick = case mName of
            Just nm -> Map.lookup nm harnesses
            Nothing -> case Map.toList harnesses of
                         [(_, hh)] -> Just hh   -- exactly one running → use it
                         _         -> Nothing
      case pick of
        Nothing -> do
          send (case mName of
                  Just nm -> "No running harness named '" <> nm <> "'."
                  Nothing -> "Specify a harness name: /harness output <name> [N].")
          pure ctx
        Just hh -> do
          out <- _hh_snapshot hh n
          send (if T.null (T.strip out) then "(no recent output)" else out)
          pure ctx
```

- [ ] **Step 8: Run green.** PASS.
- [ ] **Step 9: Commit**

```bash
git add src/PureClaw/Agent/SlashCommands.hs test/Agent/SlashCommandsSpec.hs
git commit -m "feat(slash): /harness output [name] [N] shows recent harness output"
```

---

### Task 6: Reconcile classification via the observer (3-state + stability) + `_he_flavour`

**Files:**
- Modify: `src/PureClaw/Harness/Registry.hs` (add `_he_flavour :: !HarnessFlavour` to `HarnessEntry`)
- Modify ALL `_he_flavour` construction sites (Cascade inventory): `ClaudeCode.hs:331,547`; `Reconcile.hs:545`; `test/Frontend/TabsViewSpec.hs:62`; `test/Frontend/APISpec.hs` (`baseEntry`); `test/Harness/RegistrySpec.hs:30,303`; `test/Harness/ReconcileSpec.hs:57` — all set `HClaudeCode`.
- Modify: `src/PureClaw/Harness/Reconcile.hs` (`ReconcileDeps._rd_capture :: Text -> Text -> IO (Maybe Text)`; replace `classifyLiveness` with `classifyFromObserver`; finalize `livenessToActivity`; DROP the now-unused `import PureClaw.Harness.ClaudeCode (isIdle)` at `:85`)
- Test: `test/Harness/ReconcileSpec.hs` — REMOVE the `classifyLiveness` tests at `:171-179`, replaced by the `classifyFromObserver` tests below.

**Interfaces:**
- Consumes: `observerFor`, `HarnessActivityState` (Task 2); `LivenessAwaitingInput`, `HarnessNeedsInput` (Task 3).
- Produces / changes (exact signatures):
  ```haskell
  -- ReconcileDeps field (was: IO Bool)
  _rd_capture :: Text -> Text -> IO (Maybe Text)   -- raw capture; Nothing = capture failed

  classifyFromObserver
    :: HarnessObserver -> Bool {-paneDead-} -> Bool {-harnessAlive-} -> Bool {-stable-} -> Text -> Reg.Liveness

  -- classifyRow now takes the entry's PREVIOUS capture (for the stability gate)
  -- and returns the capture it took this tick (so the loop can carry it forward).
  classifyRow
    :: ReconcileDeps -> Reg.HarnessEntry -> TmuxWindowRow
    -> Maybe Text                       -- previous capture for this entry
    -> IO (Reg.Liveness, Maybe Text)    -- (liveness, capture taken this tick)

  -- reconcileTick takes prev captures (id-text → last raw) and returns, per id,
  -- the observation the loop needs (sessionId, liveness, capture-taken).
  data TickObservation = TickObservation
    { _to_sessionId :: !Text            -- sidOf e (may be the label fallback)
    , _to_liveness  :: !Reg.Liveness
    , _to_capture   :: !(Maybe Text)    -- raw capture this tick, if any
    }
  reconcileTick
    :: ReconcileDeps -> Reg.HarnessRegistry -> LogHandle
    -> Map Text Text                              -- prev captures (id-text → last raw)
    -> IO (Map Text TickObservation, [Text])      -- (per-id observation, evicted sessionIds)
  ```
  The loop (`runReconcileLoopWith`) threads a new `prevCaps :: Map Text Text` alongside the existing prev snapshot, derived from `Map.mapMaybe _to_capture` of the previous tick.

- [ ] **Step 1: Failing test** — observer-based classification with stability:

```haskell
    it "classifies a spinner frame as Thinking regardless of stability" $
      classifyFromObserver claudeObserver False True True spinnerFrame
        `shouldBe` Reg.LivenessThinking
    it "classifies an approval frame as AwaitingInput" $
      classifyFromObserver claudeObserver False True True approvalFrame
        `shouldBe` Reg.LivenessAwaitingInput
    it "an idle-marker frame is Thinking until it is stable across ticks" $ do
      classifyFromObserver claudeObserver False True False idleFrame `shouldBe` Reg.LivenessThinking
      classifyFromObserver claudeObserver False True True  idleFrame `shouldBe` Reg.LivenessIdle
    it "livenessToActivity maps AwaitingInput to needs-input" $
      livenessToActivity Reg.LivenessAwaitingInput `shouldBe` HarnessNeedsInput
```

- [ ] **Step 2: Run red.** FAIL.
- [ ] **Step 3: Implement**

Add `_he_flavour :: !HarnessFlavour` to `HarnessEntry` and set `HClaudeCode` at every site in the Cascade inventory (8 sites). `import qualified PureClaw.Session.Kind as Kind` where needed. REMOVE `classifyLiveness` (Reconcile.hs:222) and its `ReconcileSpec.hs:171-179` tests — they are replaced by `classifyFromObserver` and the tests in Step 1 above.

`Reconcile.hs`:
```haskell
classifyFromObserver
  :: HarnessObserver -> Bool -> Bool -> Bool -> Text -> Reg.Liveness
classifyFromObserver obs paneDead harnessAlive stable screen
  | paneDead || not harnessAlive = Reg.LivenessExited
  | otherwise = case _ho_classify obs screen of
      HasWorking       -> Reg.LivenessThinking
      HasAwaitingInput -> Reg.LivenessAwaitingInput
      HasIdle          -> if stable then Reg.LivenessIdle else Reg.LivenessThinking

livenessToActivity :: Reg.Liveness -> HarnessActivity
livenessToActivity Reg.LivenessIdle          = HarnessIdle
livenessToActivity Reg.LivenessThinking      = HarnessThinking
livenessToActivity Reg.LivenessAwaitingInput = HarnessNeedsInput
livenessToActivity Reg.LivenessExited        = HarnessStopped
livenessToActivity Reg.LivenessOrphaned      = HarnessStopped
```

Change `_rd_capture` to `Text -> Text -> IO (Maybe Text)`: production `defaultReconcileDeps:143` = `\session windowName -> Just . TE.decodeUtf8Lenient <$> captureWindowNamed session windowName 50` (wrap in `try` → `Nothing` on exception); update the four `ReconcileSpec` fake sites (`:108,:116,:365,:559`) to return `Just "<frame>"` / `Nothing`.

Rewrite `classifyRow` to take the previous capture and return `(liveness, capture-taken)`:
```haskell
classifyRow deps e row prevCap
  | _twr_paneDead row = pure (Reg.LivenessExited, Nothing)
  | otherwise = do
      alive <- case (Reg._he_harnessPid e, _twr_panePid row) of
        (Just _, Just shellPid) -> _rd_harnessAlive deps shellPid
        _                       -> pure True
      if not alive
        then pure (Reg.LivenessExited, Nothing)
        else do
          mCap <- _rd_capture deps (Reg._he_session e) (_twr_windowName row)
          let cap    = fromMaybe "" mCap
              stable = Maybe.isJust mCap && mCap == prevCap
              obs    = observerFor (Reg._he_flavour e)
          pure (classifyFromObserver obs False True stable cap, mCap)
```
In `reconcileTick`, add the `prevCaps :: Map Text Text` parameter; in the `(row : _)` corroborated branch use `classifyRow deps e row (Map.lookup idText prevCaps)`, store the returned capture in `_to_capture`, and return `Map Text TickObservation` (the held/orphaned `mkObserved*` paths set `_to_capture = Nothing`; keep `_to_sessionId = sidOf e`, `_to_liveness` as before). In `runReconcileLoopWith`, thread `prevCaps` (init `Map.empty`; `nextCaps = Map.mapMaybe _to_capture obs`) alongside the existing prev snapshot, and build the `Map Text (Text, Reg.Liveness)` the `diffLiveness` publish path expects via `Map.map (\o -> (_to_sessionId o, _to_liveness o)) obs`.

- [ ] **Step 4: Run green.** PASS; whole suite builds (fix `-Werror` exhaustiveness on the new `Liveness` constructor everywhere it is matched — `diffLiveness`, any rendering).
- [ ] **Step 5: Commit**

```bash
git add src/PureClaw/Harness/Registry.hs src/PureClaw/Harness/Reconcile.hs \
        src/PureClaw/Harness/ClaudeCode.hs test/Harness/ReconcileSpec.hs \
        test/Harness/RegistrySpec.hs test/Frontend/TabsViewSpec.hs test/Frontend/APISpec.hs
git commit -m "feat(reconcile): observer-based 3-state harness classification with stability gate"
```

---

### Task 7: Output watcher — record Response on settle (deduped)

**Files:**
- Modify: `src/PureClaw/Harness/Reconcile.hs` (`ReconcileDeps` gains `_rd_recordResponse`; the loop detects settle transitions and records; threads a per-session last-response `Map`)
- Modify: `src/PureClaw/CLI/Commands.hs` (the `runReconcileLoopWith` call site at `:1044` — wire `_rd_recordResponse` using the in-scope `sessionsDir:622` + `broker` + `logger`)
- Test: `test/Harness/ReconcileSpec.hs`

**Interfaces (exact):**
- Consumes: `_hh_snapshot` (Task 4 — capture+extract the latest response per flavour, behind the handle), `_he_sessionId :: Maybe Text`, `_he_handle :: Maybe HarnessHandle`, `Reg.lookupById`, `mkBroadcastingFileTranscriptHandle`.
- Produces:
  ```haskell
  -- New ReconcileDeps field. Records ONE Response entry for a session.
  _rd_recordResponse :: SessionId -> Text -> IO ()
  ```
  The settle recorder reuses `_hh_snapshot` (NOT a new extract in the loop), so flavour/baseline are handled behind the handle and no flavour/baseline threading is needed here. The loop gains a `prevResponses :: Map Text Text` (keyed by id-text → last recorded response); dedup is plain `Text` equality (NO `hashable` — absent from `pureclaw.cabal`).

- [ ] **Step 1: Failing test** — drive a fake harness through working→idle and assert exactly one Response is recorded, and a second idle tick dedups to zero. The fake entry carries a `_he_handle` whose `_hh_snapshot` returns a fixed string and a real `_he_sessionId = Just "sess-1"`:

```haskell
    it "records exactly one Response on a working→idle settle, then dedups" $ do
      recorded <- newIORef ([] :: [(SessionId, Text)])
      let hh   = noopHandle { _hh_snapshot = \_ -> pure "the answer" }
          deps = baseDeps
            { _rd_capture        = scriptedCaptures   -- spinner, spinner, idle, idle
            , _rd_recordResponse = \sid txt -> modifyIORef' recorded ((sid, txt) :)
            }
      -- register one entry: _he_sessionId = Just "sess-1", _he_handle = Just hh
      runTicksWith 4 deps reg
      xs <- readIORef recorded
      length xs `shouldBe` 1
      xs `shouldBe` [(SessionId "sess-1", "the answer")]
    it "records the approval prompt on a working→awaiting-input settle" $ ...  -- snapshot returns prompt text
    it "skips recording when _he_sessionId is Nothing (label-only entry)" $ ...
    it "records output produced with no preceding send (direct-tmux: spinner→idle without a /send)" $ ...
```

- [ ] **Step 2: Run red.** FAIL (`_rd_recordResponse` field + settle logic absent).
- [ ] **Step 3: Implement** — add `_rd_recordResponse :: SessionId -> Text -> IO ()` to `ReconcileDeps` (default/test stub: `\_ _ -> pure ()`). In `runReconcileLoopWith`, after computing the liveness diff for the tick, detect settle transitions directly from `(prevSnap, obs)`: an id whose previous liveness was `LivenessThinking` and whose new `_to_liveness` is `LivenessIdle` or `LivenessAwaitingInput`. For each such id:

```haskell
    settle prevSnap obs prevResponses = do
      newPairs <- forM (settledIds prevSnap obs) $ \idText ->
        case Reg.parseHarnessId idText of
          Nothing  -> pure Nothing
          Just hid -> do
            mEntry <- Reg.lookupById reg hid
            case mEntry of
              Just e
                | Just realSid <- Reg._he_sessionId e   -- real session, not the label fallback
                , Just hh      <- Reg._he_handle e -> do
                    resp <- _hh_snapshot hh 0           -- latest response, full capture, per-flavour
                    let prev = Map.lookup idText prevResponses
                    if not (T.null (T.strip resp)) && prev /= Just resp
                      then do _rd_recordResponse deps (SessionId realSid) resp
                              pure (Just (idText, resp))
                      else pure Nothing
              _ -> pure Nothing
      pure (foldr (\(k,v) -> Map.insert k v) prevResponses (catMaybes newPairs))
```

Thread `prevResponses :: Map Text Text` through the loop (init `Map.empty`; updated by `settle`). `settledIds` compares `Map.lookup id prevSnap` (`(_, Liveness)`) against `_to_liveness` in `obs`. (A harness with no `_he_handle` or no real `_he_sessionId` is skipped — Phase-1 limitation: a boot-discovered entry without an attached handle is not auto-recorded until a handle exists.)

Production `_rd_recordResponse` (wired in `CLI/Commands.hs` where `sessionsDir`, `broker`, `logger` are in scope; `SessionId`/`unSessionId` from the session-id module already imported there):

```haskell
_rd_recordResponse = \sid txt -> do
  let path = sessionsDir </> T.unpack (unSessionId sid) </> "transcript.jsonl"
  bracket (mkBroadcastingFileTranscriptHandle (Just broker) sid logger path)
          (\th -> _th_flush th >> _th_close th)
          (\th -> recordResponseEntry th txt)
```

where `recordResponseEntry th txt` builds and `_th_record`s a `Response` `TranscriptEntry` (mirror the existing `recordHarnessEntry … Response` in API.hs — same field shape).

- [ ] **Step 4: Run green.** PASS.
- [ ] **Step 5: Wire `_rd_recordResponse` at the call site** (`CLI/Commands.hs:1044`, where `runReconcileLoopWith` is started and `sessionsDir:622`/`broker`/`logger` are in scope) — set the production `_rd_recordResponse` per Step 3. Build.
- [ ] **Step 6: Run green** (full suite).
- [ ] **Step 7: Commit**

```bash
git add src/PureClaw/Harness/Reconcile.hs src/PureClaw/CLI/Commands.hs test/Harness/ReconcileSpec.hs
git commit -m "feat(reconcile): record harness Response on settle (deduped) — auto output streaming"
```

---

### Task 8: Decouple send from receive (harness send no longer blocks/records Response)

**Files:**
- Modify: `src/PureClaw/Frontend/API.hs` (`routeViaHandle`:2122-2158 — record Request + send; drop the inline `_hh_receive`/Response recording for the harness path)
- Modify: `src/PureClaw/Harness/ClaudeCode.hs` (`isIdle:782` — redefine via the observer; keep its call sites at `:753` and `:918` working)
- Test: `test/Frontend/APISpec.hs`; `test/Harness/ClaudeCodeSpec.hs` (update `isIdle` tests at `:444-451`)

**Interfaces:**
- Changed: `routeViaHandle` records only the Request and injects keystrokes; the watcher (Task 7) records the Response. `POST /send` returns promptly with `{"kind":"assistant","response":""}` (the reply arrives via WS).

- [ ] **Step 1: Failing test**

```haskell
    it "harness /send records a Request and injects keystrokes but records NO Response inline" $ do
      sent <- newIORef []
      recorded <- newIORef []
      let hh = noopHandle
            { _hh_send    = \bs -> modifyIORef' sent (bs :)
            , _hh_receive = error "receive must not be called on the send path"
            }
      -- wire env with a registry entry carrying hh + a capturing transcript
      (st, _) <- postJSON env ["api","sessions", sid, "send"] (msgBody "hello")
      st `shouldBe` HTTP.status200
      readIORef sent     `shouldReturn` [TE.encodeUtf8 "hello"]
      dirs <- readIORef recorded
      map _te_direction dirs `shouldBe` [Request]   -- no Response inline
```

- [ ] **Step 2: Run red.** FAIL (current code calls `_hh_receive` and records a Response).
- [ ] **Step 3: Implement** — in `routeViaHandle`, replace the inner action:

```haskell
      (\th -> do
        recordHarnessEntry th Request userText
        _hh_send hh (TE.encodeUtf8 userText)
        -- Response is recorded by the reconcile watcher on settle; the send
        -- path no longer blocks on _hh_receive (which mis-fired off the broken
        -- isIdle and double-recorded against the watcher). Reply arrives via WS.
        pure "")
```

and respond with `"response" .= ("" :: Text)`.

Note: the CLI `/msg` path (`SlashCommands.hs:1119-1133`, `CmdMsg`) also does `_hh_send` + blocking `_hh_receive`; this is INTENTIONALLY preserved for the CLI/TUI (non-frontend) flow — after the `isIdle` redefinition it blocks correctly on the observer-driven poll. Do not change it.

- [ ] **Step 4: Run green.** PASS. Update any existing APISpec tests that asserted an inline harness Response from `_hh_receive` — they now assert the Request-only behavior (a Request entry recorded, no Response on the send path).
- [ ] **Step 5: Redefine `isIdle` via the observer** (do NOT delete — it has call sites at `ClaudeCode.hs:753` and `:918`, both `pollUntilIdle`/`discoveredReceive`). Replacing its body keeps both working and corrects the CLI/TUI path:

```haskell
-- | Idle iff the flavour observer classifies the screen as settled (replaces
-- the stale ❯/⠋ heuristic; the input box ❯ is always present, so it can't mean idle).
isIdle :: Text -> Bool
isIdle screen = _ho_classify claudeObserver screen == HasIdle
```

Add `import PureClaw.Harness.Observer (claudeObserver, _ho_classify, HarnessActivityState (..))` to ClaudeCode.hs. (The `Reconcile.hs:85` import of `isIdle` was already dropped in Task 6.)

- [ ] **Step 6: Update the `isIdle` tests** (`ClaudeCodeSpec.hs:444-451`) to the corrected expectations: a bare-prompt idle frame → `True`; a spinner/working frame (`✶ …` / token counter) → `False`; an approval frame → `False`.
- [ ] **Step 7: Run green** (full suite) + `nix develop . --command cabal build` clean under `-Werror`.
- [ ] **Step 8: Commit**

```bash
git add src/PureClaw/Frontend/API.hs src/PureClaw/Harness/ClaudeCode.hs \
        test/Frontend/APISpec.hs test/Harness/ClaudeCodeSpec.hs
git commit -m "refactor(api): decouple harness send from receive; isIdle via observer; watcher owns Response recording"
```

---

## Final verification (after all tasks)

- [ ] `nix develop . --command bash -c "cabal clean && cabal build"` — clean under `-Wall -Werror`.
- [ ] `nix develop . --command cabal test` — full suite green.
- [ ] `nix develop . --command cabal test --enable-coverage` — ≥95% per `.coverage-thresholds.json`.
- [ ] `cd frontend && npx tsc --noEmit && npx vitest run` — green.
- [ ] Manual smoke (live): adopt/spawn a Claude harness, send a message from the web UI, confirm the reply appears via the stream; trigger an approval prompt and confirm the needs-input pill + prompt text; run `/harness output`.

## Self-review notes

- **Spec coverage:** Mechanism 1 → Task 5; Mechanism 2 → Tasks 6–7; observer seam → Task 2; three states + pill → Tasks 3, 6; decouple send/receive → Task 8; `-J` capture → Task 1; generic fallback → Task 2.
- **Known Phase-1 limitation** (last `⏺` block per settle) is inherent to Task 7's extract-on-settle; `/harness output` (Task 5) is the manual workaround. Phase 2 (live-edit) is out of scope.
- **Loop state, not entry widening:** per-entry previous-capture (for the stability gate, `Map HarnessId Text`) and per-session last-response (for dedup, `Map SessionId Text`, plain equality — no `hashable`) live in the reconcile loop's fold state, not on `HarnessEntry`. Task 7's test pins the dedup behavior.
- **Cascade coverage:** every `-Werror`-forced match/construction site for the two new enum constructors (`LivenessAwaitingInput`, `HarnessNeedsInput`) and the two new fields (`_he_flavour`, `_hh_snapshot`) is enumerated in the "Cascade & construction-site inventory" section, and each owning task's file scope and commit list includes those files (incl. `TabsView.hs`, `RuntimesSpec.hs`, `RegistrySpec.hs`, `SlashCommands.hs mkHandle`). `classifyLiveness`/`isIdle` dispositions and their existing tests are explicitly handled (Tasks 6, 8).
