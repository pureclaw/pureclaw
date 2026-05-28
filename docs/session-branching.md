# Session Branching — Design & Implementation Plan

**GitHub issue:** [#63](https://github.com/pureclaw/pureclaw/issues/63) — "Allow any historical partial session to be able to be used as the starting point of a new session"
**Beads epic:** `pureclaw-o4l`
**Status:** draft round 3 — Feasibility PASS, Scope & Alignment PASS (round 2); round 3 addresses remaining Completeness gaps (read-only prefix non-sendability, agent-present/absent + custom-prompt-present/absent arms, latest-wins re-click, WU3 file scope, no-CSS).

---

## 1. Problem

A user reviewing a session transcript wants to take the conversation *up to a particular point* and continue it down a different path, without disturbing the original session. Today the only way to start a new session is the "New tab" button, which begins from an empty history.

## 2. Product decisions (confirmed with the user)

| Decision | Choice |
|---|---|
| **Branch boundary** | Copy transcript entries from the start **up to and including** the clicked entry. |
| **Affordance / label** | A **branch** icon button next to the existing "raw JSON" button; tooltip + `aria-label` **"branch session from here"**. Terminology is *branch*, not *fork*. |
| **Post-action UX** | Open **and switch to** a new tab that already shows the transcript prefix (read-only). The backend session is created **lazily on first send**, mirroring the "New tab" button — no session/dir is created on click. |
| **Harness sessions** | **Hide** the branch button entirely (external-CLI sessions have no replayable history). |

## 3. Key architectural facts (verified against current code)

- **Conversation history is reconstructed from `transcript.jsonl` on every turn.** `doCompletion` (`src/PureClaw/Frontend/API.hs:948`) calls `loadRecentMessages` (`src/PureClaw/Session/Handle.hs:562`), which replays the transcript into provider `Message`s. There is **no separate conversation-state file**. So a branch == *a new session directory whose `transcript.jsonl` begins with a copy of the source prefix*; the next turn replays it automatically.
- **The system prompt is NOT carried by the transcript.** `loadRecentMessages` → `extractNewMessageText` (`Session/Handle.hs:624`) keeps only the last message text per request entry and **discards** the `system_prompt` field. The prompt actually used at completion comes from `doCompletion` (`API.hs:966-968`): the per-session `custom-prompt.md` file in the session dir if present, else the global `_fe_systemPrompt env`. **Therefore a branch must copy the source session's `custom-prompt.md` (if any)** for prompt fidelity.
- **Provider/model at completion time are global, not per-session.** `handleSend`/`doCompletion` read `_fe_provider` / `_fe_model` IORefs (`API.hs:925-926`); `createTab` records `_sm_model` from the global `_fe_model` IORef (`API.hs:789`). Per-session model selection is *not* honored at completion today — this is existing behavior and **out of scope to change**. For a branch we make the *recorded metadata* faithful by inheriting `_sm_kind` / `_sm_model` / `_sm_agent` from the **source `session.json`** (see §5.1), so the branch's sidebar row matches its parent; the actual first completion uses the global provider/model exactly as a New-tab session does.
- **Lazy "New tab" creation** is purely a frontend concern: clicking New tab sets `selectedId = null` (compose mode, `App.tsx:564`) and renders `NewTabComposer` + a first-message input. The backend session is created by `handleComposerSend` (`App.tsx:573`) on first send: `POST /api/tabs/new` → switch `selectedId` → `POST /api/sessions/{id}/send`. `createTab` (`API.hs:780`) persists `SessionMeta` + dir + empty `transcript.jsonl` immediately when called. Note `handleComposerSend` silently `return`s on a non-OK new-tab POST (`App.tsx:581`) — the branch flow must add a visible error path (see §5.3).
- **Transcript handle API:** `TranscriptHandle._th_record :: TranscriptEntry -> IO ()` appends one entry; `_th_query :: TranscriptFilter -> IO [TranscriptEntry]` reads all (`src/PureClaw/Handles/Transcript.hs:40-41`). Copying = query source, slice prefix, `_th_record` each into the new handle. `_th_record` writes the entry verbatim (the `touchLastActive` wrapper only mutates `_sm_lastActive`), so `_te_id` and all fields are preserved on replay.
- **Entry → message mapping** (`transcriptToMessages`, `App.tsx:91`): a `request` entry may emit a synthesized **System** row (`id = e.id + '-sys'`, no standalone branch point), then either a **user** row (`id = e.id + '-user'`, emitted only when `textParts` is non-empty) or an **assistant** row (`id = e.id + '-asst'`); a `response` entry emits an **assistant** row (`id = e.id`). The frontend `TranscriptEntry.id` (`types.ts:76`) is the raw `_te_id`. The branch boundary key is the raw `_te_id`, so each branchable `Message` must carry `entryId = e.id` explicitly (do **not** derive it by stripping `-user`/`-asst`/`-sys` suffixes). A request entry that produced no text row (e.g. a tool-result-only continuation) has no branchable message — acceptable; the user branches from an adjacent text row.
- **Harness sessions** (`SkHarness`, `Session/Kind.hs:51-53`) record plain-text exchanges, not provider request/response envelopes, and the external process owns its state — not replayable. Branch is provider-only.
- **Path-traversal guard** already exists: `isValidSessionId` (`API.hs:179`) rejects empty / `..` / `/`.
- **Tab-count gate:** `createTab` bumps `_fe_tabCount` unconditionally (`API.hs:784`) with **no decrement on error**. Branch validation must therefore run *before* `createTab` is called (in `handleNewTab`, which already holds the count check) so a failed branch never consumes a tab slot.

## 4. Scope

**In scope**
- Backend: extend `POST /api/tabs/new` to accept an optional `branch_from` spec; validate it in `handleNewTab` *before* creating anything; for branches, seed the new session's transcript with a verbatim copy of the source prefix, copy the source `custom-prompt.md`, and inherit `_sm_kind`/`_sm_model`/`_sm_agent` from the source meta.
- Frontend: branch button on provider-session transcript entries; a "branch draft" compose mode that shows the prefix read-only, defers creation to first send, surfaces backend errors, and switches to the new session on success.

**Out of scope**
- Forking harness sessions.
- Persisting an explicit parent/child lineage in `SessionMeta` (possible follow-up; not required by the issue). *Consequence:* a branch is otherwise indistinguishable from a fresh session and has no provenance UI — acceptable for #63.
- Editing/trimming history within the branch before sending.
- Changing `loadRecentMessages` / compaction, or making provider/model per-session at completion time.

## 5. Design

### 5.1 Backend — `branch_from` seeded session creation

`NewTabRequest` (currently a `newtype`, `API.hs:714`) becomes a 2-field `data`. **Both** existing construction sites change: the `FromJSON` constructor (`API.hs:722`) and the pattern match in `handleNewTab` (`API.hs:771`). A grep confirms these are the only two sites in `src/` and `test/`.

```haskell
data BranchSpec = BranchSpec
  { _bs_sourceSessionId :: Text
  , _bs_upToEntryId     :: Text
  }

data NewTabRequest = NewTabRequest
  { _ntr_kind       :: TabKind
  , _ntr_branchFrom :: Maybe BranchSpec   -- new; parsed via `o .:? "branch_from"`; absent ⇒ Nothing
  }
```

Wire envelope (sibling of `kind`):
```jsonc
{
  "kind": { "tag": "session", "session_kind": { "tag": "provider", ... } },
  "branch_from": { "session_id": "<source-sid>", "up_to_entry_id": "<_te_id>" }   // optional
}
```

**A `Session/Handle.hs` helper** resolves the branch seed (pure-ish, unit-testable, returns a typed error mirroring the existing `ResumeError` style):

```haskell
-- Constructors carry diagnostic payloads for parity with the existing ResumeError style.
data BranchError
  = BranchInvalidSourceId Text
  | BranchSourceMissing FilePath
  | BranchSourceNotProvider
  | BranchEntryNotFound Text

data BranchSeed = BranchSeed
  { _bseed_prefix       :: [TranscriptEntry]  -- [0..boundary] inclusive
  , _bseed_sourceMeta   :: SessionMeta        -- to inherit kind/model/agent
  , _bseed_customPrompt :: Maybe Text         -- source custom-prompt.md contents, if any
  }

resolveBranchSeed :: FilePath -> BranchSpec -> IO (Either BranchError BranchSeed)
```

**`handleNewTab` flow when `_ntr_branchFrom = Just bs`:**
1. The request `TabKind` must be `TkSession (SkProvider _)` ⇒ else `400` (consistency check; the actual kind is inherited from source, see step 5).
2. `resolveBranchSeed`:
   - `isValidSessionId sourceId` ⇒ else `BranchInvalidSourceId` → `400`.
   - source `session.json` exists + decodes ⇒ else `BranchSourceMissing` → `404`.
   - source `_sm_kind` is `SkProvider` ⇒ else `BranchSourceNotProvider` → `400`.
   - read source `transcript.jsonl`; find entry with `_te_id == upToEntryId`; slice `[0..idx]` ⇒ else `BranchEntryNotFound` → `404`.
   - read `custom-prompt.md` if present.
3. All of the above happens **before** the `_fe_tabCount` bump and before `mkSessionHandle`, so any error short-circuits with no tab-count change and no directory created.
4. Pass `Just seed` into `createTab`.

**`createTab` signature changes** (the one caller in `handleNewTab` updates accordingly; any test call sites too):
```haskell
createTab :: FrontendEnv -> TabKind -> Maybe BranchSeed -> (Response -> IO ResponseReceived) -> IO ResponseReceived
```
- `Nothing` ⇒ identical to today.
- `Just seed` ⇒ build the new `SessionMeta` inheriting `_sm_kind`/`_sm_model`/`_sm_agent` from `_bseed_sourceMeta`. The literal must populate **all 11 `SessionMeta` fields** (`-Werror`): inherited `_sm_kind`/`_sm_model`/`_sm_agent`; fresh `_sm_id` + `_sm_createdAt`/`_sm_lastActive` (now); `_sm_channel = "web"`, `_sm_bootstrapConsumed = True`, `_sm_archived = False`, `_sm_description = Nothing`, `_sm_autoSummary = Nothing` (matching the current `createTab` body at `API.hs:806/809`). After `mkSessionHandle` + `_sh_save`, `_th_record` each `_bseed_prefix` entry in order, write `custom-prompt.md` if `_bseed_customPrompt` is `Just`, then publish the usual `ActivityChanged`/`broadcastLists` signals and respond.

**Security:** the prefix is copied from the **on-disk source transcript**, never from client-supplied payloads — the client only names `session_id` + `up_to_entry_id`. `isValidSessionId` guards traversal. This prevents history injection.

### 5.2 Frontend — branch button + entry-id plumbing

- `Message` (`types.ts:109`) gains `entryId?: string`. `transcriptToMessages` (`App.tsx:93`) sets `entryId = e.id` on every user row and assistant row (both the `-asst` and `response` shapes). The synthesized System row gets none.
- `ChatArea` accepts an optional `onBranch?: (entryId: string) => void`. `ChatMessage` (`ChatArea.tsx:626`) currently receives only `{ message }`; it must additionally receive `onBranch` and `sending`, threaded through the `messages.map` at `ChatArea.tsx:1048`. `ChatMessage` renders a new `BranchButton` (inline branch SVG, class `icon-btn`, `title` + `aria-label` = "branch session from here", matching `JsonButton` at `ChatArea.tsx:227`) next to `JsonButton` **iff** `onBranch` is defined **and** `message.entryId` is defined. The button is disabled while a send is in flight (the existing `sending` prop), so a branch can't race an in-flight completion.
- `App.tsx` passes `onBranch` to `ChatArea` **only when the focused session is a persisted provider session** — predicate: `selectedSession?.runtime === 'provider'`, where `runtime` is the backend `_si_runtime` value carried through `useApi.ts` (`"provider"` for `SkProvider`, `"harness:<flavour>"` for harness). In compose/branch-draft mode `selectedId === null` so `selectedSession` is undefined ⇒ `onBranch` is undefined ⇒ **the read-only prefix rows in a branch draft render no branch button** (you cannot branch a not-yet-created branch). This implements both "hide for harness" and "branch only on persisted sessions".

### 5.3 Frontend — branch draft compose flow

- `App` adds `branchDraft: BranchDraft | null` where
  `BranchDraft = { sourceSessionId: string; upToEntryId: string; prefixMessages: Message[] }`.
- `handleBranch(entryId)`:
  1. slice the currently-displayed `messages` up to & including the message whose `entryId === entryId` → `prefixMessages`;
  2. set `branchDraft` (overwriting any existing draft — a second branch click before sending replaces the boundary, latest wins), enter compose mode (`setSelectedId(null)`), bump `newTabFocusTick`, push URL `/`. (Composer config selectors may be visually suppressed for a branch draft since the backend inherits config from source; functionally the request body's `kind` is ignored for branches.)
- `ChatArea` in compose mode: when `branchDraft` is set, render `prefixMessages` **read-only** above the composer so the user sees the inherited history. The prefix region is non-interactive: its rows carry no `onBranch` (see §5.2) and no send affordance — the only send path is the composer first-send, so the prefix cannot trigger a duplicate `POST /send`.
- `handleComposerSend` (add `branchDraft` to its dependency array to avoid a stale-closure capture): when `branchDraft` is set, merge `branch_from: { session_id, up_to_entry_id }` into the `POST /api/tabs/new` body (merged in `handleComposerSend`, not in `buildBody`, whose deps don't include branch state). On non-OK response, **surface a visible error** (inline composer error/toast) and **retain** `branchDraft` so the user can retry — do not silently `return`. On success clear `branchDraft` and follow the existing create-then-send + switch-to-new-session path.
- Cancelling (clicking New tab, selecting another session) clears `branchDraft`.

## 6. Work-unit decomposition

> Strict sequence **WU1 → WU2 → WU3** (WU2/WU3 both edit `App.tsx`+`ChatArea.tsx`; WU3 depends on WU1's wire contract). No parallelism.

### WU1 — Backend: `branch_from` seeded session creation
**Files:** `src/PureClaw/Frontend/API.hs`, `src/PureClaw/Session/Handle.hs`, tests in `test/Frontend/APISpec.hs` (+ a `Session/Handle` spec).
**DoD**
- **D1** `NewTabRequest` becomes `data` with `_ntr_branchFrom :: Maybe BranchSpec`, parsed via `o .:? "branch_from"`. **Both** construction sites updated (`FromJSON` `API.hs:722`, pattern `API.hs:771`). A non-branch POST behaves byte-for-byte as today (regression test).
- **D2** `resolveBranchSeed` returns the prefix `[0..boundary]` inclusive + source meta + optional custom-prompt, or the correct `BranchError` for: invalid source id, missing source meta, harness source, missing entry id. (unit tests per arm — each arm exercised for branch coverage)
- **D3** `createTab` gains `Maybe BranchSeed`; with `Just seed` it creates a new provider session whose `transcript.jsonl` equals the source prefix (entries identical incl. `_te_id`, order preserved), whose `_sm_kind`/`_sm_model` are inherited from the source meta, and whose `SessionMeta` literal compiles with all 11 fields populated. The one call site in `handleNewTab` is updated.
  - **D3a** Source with `_sm_agent = Just a` ⇒ branch's `_sm_agent = Just a`.
  - **D3b** Source with `_sm_agent = Nothing` ⇒ branch's `_sm_agent = Nothing`.
- **D4** Branch requested with a non-provider target `TabKind` ⇒ `400`.
- **D5** Error mapping: invalid/traversal source id ⇒ `400`; harness source ⇒ `400`; unknown source ⇒ `404`; unknown entry id ⇒ `404`. On **every** error path: **no** new session directory is created **and** `_fe_tabCount` is unchanged (regression test: repeated failing branch POSTs do not consume tab slots).
- **D6** *Integration:* a branched session of a source that **has** a `custom-prompt.md`, on first `POST /send`, has `loadRecentMessages` replay the copied prefix (assert the provider request context contains the prefixed turns) and uses the copied custom prompt.
  - **D6b** A branch of a source with **no** `custom-prompt.md` creates none, and its first completion falls back to the global `_fe_systemPrompt` (regression assert — mirror of D6).
- **D7** Coverage on touched Haskell modules meets `.coverage-thresholds.json` (95% lines/branches/functions/statements), via `nix develop . --command cabal test --enable-coverage`.

### WU2 — Frontend: entry-id plumbing + branch button
**Files:** `frontend/src/types.ts`, `frontend/src/App.tsx` (`transcriptToMessages`), `frontend/src/components/ChatArea.tsx`, tests `frontend/src/components/__tests__/ChatArea.test.tsx`.
**DoD**
- **D8** `Message.entryId` is set to the raw `_te_id` for user rows and assistant rows (both `-asst` and `response` shapes) by `transcriptToMessages`; the System row has none. (unit test)
- **D9** `BranchButton` renders next to `JsonButton` when `onBranch` + `entryId` are present; `title` and `aria-label` are both "branch session from here"; clicking calls `onBranch(entryId)`; the System row shows no branch button while its adjacent user row does. (component test, queried by accessible name)
- **D10** When `onBranch` is undefined (harness session), no branch button renders; the branch button is disabled while `sending` is true. (component test)
- **D11** Frontend tests pass via `npm --prefix frontend test` (`vitest run`). *(See §7 — frontend logic is outside the Haskell coverage gate, so these tests are the substitute quality gate and are blocking for WU2/WU3.)*

### WU3 — Frontend: branch draft compose flow (lazy create, error path, switch)
**Files:** `frontend/src/App.tsx`, `frontend/src/components/ChatArea.tsx`, tests `frontend/src/components/__tests__/ChatArea.test.tsx` **and a new `frontend/src/__tests__/App.test.tsx`** (App has no test today; if `App` proves untestable as-is, extract `handleBranch`/branch-send logic into a tested hook instead). *No new CSS — `BranchButton` reuses `icon-btn` and prefix rows reuse the existing message styles. `useApi.ts`'s `NewTabResponse` is unchanged; the `branch_from` field is merged into the request body in `handleComposerSend`, not in `useNewTabSpec.buildBody`.*
**DoD**
- **D12** Clicking branch on a provider session enters compose mode showing the prefix messages read-only above the composer and focuses the input. **No** `/api/tabs/new` call is made on click (lazy). (App-level test asserts fetch not called on click)
- **D12a** Prefix rows in branch-draft mode are non-interactive: they render no branch button and offer no send affordance; no duplicate `POST /send` can originate from the prefix region. (test)
- **D12b** In branch-draft compose mode, `branchDraft.prefixMessages` are threaded into `ChatArea` (via the `messages` prop or a dedicated `prefixMessages` prop — implementer's choice) and each prefix row renders; a test asserts the prefix message text is present in the DOM while `selectedId === null`. (Today `messages` derives only from `currentSessionId`'s transcript at `App.tsx:473`, which is empty in compose mode, so the prefix must be supplied explicitly.)
- **D13** First send issues `POST /api/tabs/new` with `branch_from {session_id, up_to_entry_id}`, then `POST /send`, then switches `selectedId` to the new session. (App-level test asserts request bodies + ordering + switch)
- **D14** A 400/404 from the branch POST shows a user-visible error and **retains** `branchDraft` (no silent drop). (test the stale/deleted-entry 404 path; this also covers branching from an entry not yet flushed to disk)
- **D15** `onBranch` is wired `App → ChatArea` only for persisted provider sessions (undefined in compose mode and for harness sessions); selecting another session or clicking New tab clears `branchDraft`. (tests)
- **D15a** A second branch click before sending replaces the draft (latest boundary wins); the prefix updates to the new boundary. (test)
- **D16** Frontend tests pass via `npm --prefix frontend test`.

## 7. Testing strategy

- **Backend:** Hspec against `resolveBranchSeed`, `createTab`, `handleNewTab` with a temp sessions dir; build source sessions on disk via existing helpers, branch, assert new transcript contents + `custom-prompt.md` + metadata + error codes + tab-count invariance. TDD: red test first per DoD; every `BranchError` arm exercised for HPC branch coverage.
- **Frontend:** vitest + @testing-library/react, following `ChatArea.test.tsx` / `useApi.test.ts` patterns; mock `fetch`; query buttons by accessible name. A new App-level test covers the branch draft flow (the create→send→switch sequence and the lazy/no-fetch-on-click invariant).
- **Coverage gate reality:** the enforced gate (`.coverage-thresholds.json`) runs `cabal test --enable-coverage` — **Haskell only**. The frontend branch flow (D8–D16) is therefore *not* covered by the blocking gate. The substitute gate is `npm --prefix frontend test` passing, made an explicit DoD (D11, D16). This is called out so the orchestrator does not mistake a green Haskell gate for full coverage.

## 8. Risks / edge cases

- **System-prompt fidelity:** handled by copying `custom-prompt.md` (§5.1); without it the branch would silently use the global default (the bug the Completeness reviewer caught).
- **Compaction inside the prefix:** copying entries verbatim preserves any compaction-boundary entry, so `loadRecentMessages`'s `trimToLastCompaction` behaves identically in the branch — no special handling.
- **Empty/first-entry branch:** branching from the first entry copies exactly that entry; semantics still "up to & including".
- **Tool-result-only turn:** produced no text message row, so it has no `entryId` and no branch button — the user branches from an adjacent text row. Defined, not an error.
- **Concurrent source mutation / stale boundary:** the boundary is resolved by `_te_id` against the *current* on-disk source at send time, so a stale display index can't select the wrong entry; a vanished id ⇒ `404` surfaced to the user (D14).
- **Branch during in-flight send:** branch button disabled while `sending` (D10), avoiding a race with the optimistic pending pair.
- **Tab-count limit (A8):** branch goes through the same `_fe_maxTabs` gate; failed branches leave the count untouched (D5).
- **Model/provider provenance:** the branch's *recorded* model/agent/kind are inherited from the source meta; the actual first completion uses the global provider/model exactly as any New-tab session does (existing behavior, not changed here).
