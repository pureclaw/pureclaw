# Plan — Verbatim transcript line in "View raw JSON (message)"

**Issue:** pureclaw-1xd
**Type:** bug (faithfulness gap) — small, full-stack
**Revision:** 2 (addresses plan-review-gate findings: privacy-test inversion, golden fixture, frontend constructors, capPayload/DoD-2)

## Governing principle (user directive — document prominently)

> **PureClaw always makes EVERYTHING visible to the user.** Transcript/raw-data views must
> never silently hide fields. When a value cannot be shown in full at a given moment
> (e.g. a size-capped live broadcast), the omission must be *explicitly marked* and the
> full value must remain reachable (e.g. on reload).

This principle is the *reason* for this change and overrides the earlier `_te_metadata`
privacy projection. It must be recorded as: (a) a code comment at `encodeEntryRaw` and at
the rewritten privacy tests, (b) a short note in the design docs, (c) the issue/plan, and
(d) project memory.

## Requirement (spec)

Clicking **View raw JSON (message)** must show the **full, verbatim `transcript.jsonl` line**
for that entry — all 9 `_te_*` fields including `_te_metadata` — byte-identical to the
on-disk line (modulo trailing `\n`).

User decisions (locked):
- **Verbatim line** rendering (payload stays an escaped JSON string), not pretty/nested.
- **Full, including `_te_metadata`** — the prior privacy boundary that dropped it
  (`pureclaw-6nr`) is *intentionally inverted* per the governing principle; the frontend
  sits behind VPN-style network auth.

## Root cause (verified)

1. **Backend** `API.hs` — `toTranscriptEntryInfo` (1340) projects 9→6 renamed fields,
   dropping `_te_durationMs`/`_te_correlationId`/`_te_metadata`; mirrored in `toEntryInfo`
   (`Stream.hs:161`) for the live WS path.
2. **Frontend** `App.tsx:126` — `const rawJson = e.payload` feeds the modal payload-only.

Modal (`frontend/src/components/ChatArea.tsx:270` `prettyJsonOrRaw`) is fine — it
`JSON.parse`s + pretty-prints whatever string it gets.

## Key enabling fact

On-disk line is *defined* as `Aeson.encode entry` (`Handles/Transcript.hs:73`). Re-encoding a
decoded `TranscriptEntry` via `Aeson.encode` is **byte-identical to the file line by
construction** (confirmed by Feasibility review: aeson 2.2.3.0 `ordered-keymap=True` makes
`_te_metadata :: Map Text Value` ordering canonical; `Maybe`→`null` stable; UTF-8 always
valid). No need to thread raw disk bytes; REST-reload and live-stream paths agree for free.

## Approach

Add `_tei_raw :: Text` to `TranscriptEntryInfo` carrying `encodeEntryRaw e`; serve it; the
frontend uses it as `rawJson`.

### WU1 — Backend

**Code:**
- New helper in `PureClaw.Transcript.Types` (next to `encodePayload`):
  `encodeEntryRaw :: TranscriptEntry -> Text`
  `encodeEntryRaw = TE.decodeUtf8Lenient . LBS.toStrict . Aeson.encode`
  (use **`decodeUtf8Lenient`** to match `encodePayload`'s style; add `Data.ByteString.Lazy
  qualified as LBS` + `Data.Aeson (encode)` imports; export the symbol).
  Comment: state the governing principle and that this is the byte-faithful disk line.
- `API.hs:1319` — add field `_tei_raw :: Text` to `TranscriptEntryInfo`.
- `API.hs:1329` — add `"raw" .= _tei_raw e` to the hand-written `ToJSON` (existing 6 keys
  unchanged — the frontend still uses them to *build* messages).
- Populate `_tei_raw = encodeEntryRaw e` at **both** construction sites:
  `toTranscriptEntryInfo` (API.hs:1340) and `toEntryInfo` (Stream.hs:161). `-Werror` forces
  both. (No third site — grep-confirmed.)

**capPayload / live-vs-disk consistency (DoD #2, scoped honestly):**
- The live path broadcasts `capPayload`-truncated entries (`BroadcastingTranscript.hs:82,
  117-127`): for entries over `_bc_maxEventBytes`, `_te_payload` is truncated and
  `_te_metadata["truncated"]=true` is injected, while **disk keeps the original**. So
  `toEntryInfo` receives the *truncated* entry and its `_tei_raw` is the truncated line.
- This is **correct under the governing principle**: the live raw view shows the truncated
  line *with `"truncated": true` plainly visible*, and reload (REST → disk) shows the full
  line. Nothing is hidden silently.
- DoD #2 restated: REST `raw` is byte-identical to disk; live `raw` equals disk **for
  under-cap entries**, and for over-cap entries equals the broadcast (truncated) entry with
  the `truncated` marker present. Reload always yields the full line.

**Tests (red first):**
- `encodeEntryRaw e == TE.decodeUtf8Lenient (LBS.toStrict (Aeson.encode e))` and
  `decode (encodeEntryRaw e) == Just e` (round-trip / disk-format identity).
- `toTranscriptEntryInfo e` and `toEntryInfo e` yield the **same** `_tei_raw` for an
  under-cap entry (REST==live).
- ToJSON of `TranscriptEntryInfo` includes `"raw"` whose parse has all 9 `_te_*` fields incl.
  a **populated** `_te_metadata` (entry with a `"source"` key).
- **Truncated case:** for an over-cap entry, `toEntryInfo`'s `raw` parses to `truncated=true`
  and a shortened payload; the disk/REST `raw` (from the original) is full and lacks
  `truncated`. Asserts the principle (marker visible, full reachable).
- `/api/sessions/:id/transcript` entries each carry `raw`.

**Existing tests to UPDATE (were pinning the inverted invariant — gate findings):**
- `test/Frontend/BroadcastingTranscriptSpec.hs:437-456` ("WU4 source omitted…"): both
  assertions currently require `senderId` **absent** from `toEntryInfo`/`toTranscriptEntryInfo`
  encodings. With `raw` they MUST flip: assert `senderId` **present** in the `raw`-bearing
  encoding (deliberate exposure). Rewrite the suite header comment to document the inversion
  per the governing principle + `pureclaw-6nr`. (Note: this file has no `TranscriptEntryInfo`
  record literal; it calls the projection fns — so the edit is the assertions, not a
  constructor.)
- `test/Frontend/StreamGoldensSpec.hs:140` + `test/Frontend/fixtures/stream-events/entry.json`:
  the golden `entry` event gains a `"raw"` key → **regenerate `entry.json`** to include it.
  (This fixture is shared with the frontend — see WU2.)

### WU2 — Frontend

**Code:**
- `frontend/src/types.ts:116` — add `raw: string` (required) to `TranscriptEntry`.
  (`EntryEvent.entry` in `frontend/src/types/stream.ts:20` reuses this type — no edit needed
  there; the field propagates automatically.)
- `frontend/src/App.tsx:126` — `const rawJson = e.raw` (verbatim line) instead of `e.payload`.
  **Preserve** the System-prompt synthesized row omitting `rawJson` (~132) — unchanged.

**Existing constructors/fixtures to UPDATE (required-field → `tsc` break, gate finding):**
- `frontend/src/__tests__/App.test.tsx` literals at ~179 (`request`) and ~191 (`response`).
- `frontend/src/components/__tests__/ChatArea.test.tsx` literals at ~431, ~442, ~460, ~834.
- `frontend/src/hooks/__tests__/useTranscriptStream.test.ts` — `mkEntry` helper (~7-16,
  explicit `: TranscriptEntry` return) and the inline `reconcileEntries` arg literal (~324).
  (Note: `streamClient.test.ts` literals are typed `unknown` and `formatTimestamp.test.ts`
  uses `as TranscriptEntry` casts — neither breaks `tsc`, no edit needed.)
- `test/Frontend/fixtures/stream-events/entry.json` (same file as WU1) — consumed by
  `frontend/src/types/__tests__/stream.test.ts:32` as `EntryEvent`; the added `raw` satisfies
  the now-required field. One fixture edit covers backend golden + frontend type test.

**Tests (red first):**
- `transcriptToMessages` sets `rawJson` to `e.raw` (full line) on user/assistant/non-JSON
  rows; System row still has no `rawJson`.
- ChatArea raw-JSON modal, given an entry whose `raw` contains
  `_te_metadata`/`_te_correlationId`/`_te_durationMs`, displays those fields (and the escaped
  `_te_payload`).

### WU3 — Documentation (governing principle)

- Code comments at `encodeEntryRaw` and the rewritten privacy tests stating the principle.
- A short note in the transcript/frontend design doc (e.g. `docs/`): "Everything visible —
  raw views are byte-faithful; size-caps are marked, never silent." Cross-reference
  `pureclaw-6nr`.
- Project memory entry capturing the principle (done as part of this task).

## Definition of Done

1. Modal shows the full verbatim line (all 9 `_te_*` incl. `_te_metadata`), byte-identical to
   disk on reload.
2. REST `raw` byte-identical to disk; live `raw` equals disk for under-cap entries and the
   marked-truncated entry otherwise (full always reachable on reload).
3. System-prompt synthesized row still omits `rawJson`.
4. `-Wall -Werror` + hlint clean; frontend `tsc` + `eslint` clean.
5. 100% coverage per `.coverage-thresholds.json` (backend + frontend); all updated/added
   tests green.
6. Governing principle documented (code comments + design doc + memory).
7. `frontend/dist` NOT committed (`frontend/.gitignore` ignores it; `git ls-files` empty) —
   no rebuild-commit step needed.

## Alternatives considered / rejected

- **Echo raw disk bytes from `readTranscriptFile`**: rejected — asymmetric with the live path
  (no disk line at broadcast time) and redundant since disk format *is* `Aeson.encode`.
- **Broadcast full payload in live `raw`** (ignore cap): rejected — defeats the WS size cap;
  the marked-truncation + reload path satisfies the principle without unbounded events.
- **Pretty/nested payload**; **drop `_te_metadata`**: rejected by user.

## Risks

- Re-encode differs from raw bytes only if a line was written by something other than
  `Aeson.encode` (hand-edit/external tool). Acceptable: all in-process writers use it.
- Exposing `_te_metadata` surfaces `"source"` (sender) + `error`/compaction flags to the
  frontend — accepted per principle + VPN-auth; note for `pureclaw-brh` (endpoint hardening).
