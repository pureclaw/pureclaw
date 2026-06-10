# Plan — WU-8d.c: delete the dead legacy loop, migrate its coverage (merges item f)

Bead: pureclaw-2q9 · Branch: feat/tabs-as-view-refactor · GitHub #79

## Goal
Production is fully on `runTabbedLoop` (Tabs/Wiring.hs) + `TabDispatch` + `runTurnWithTools`.
`runAgentLoop` / `runAgentLoopWith` / `handleCompletion` (Agent/Loop.hs) are dead in
production — kept alive only by `test/Agent/LoopSpec.hs` (640L) and
`test/Integration/SignalFlowSpec.hs` (374L). Delete the dead code, migrating every
still-valuable test behavior onto the new path. Unblocks WU11 `-Werror` restore.

KEEP (live): `runBackgroundTurn` + all background helpers (Wiring.runBg = Loop.runBackgroundTurn),
`sanitizeHarnessOutput` (re-export of Handles.Harness).

## Verified facts (investigation)
- `runTabbedLoop` ALREADY captures `_sm_source` set-once (Wiring.hs:158-159) — provenance
  invariant is implemented on the new path, but **Wiring/runTabbedLoop has ZERO test coverage**
  (this is also execution-state item f).
- `sanitizeHarnessOutput` lives in Handles/Harness.hs; `test/Handles/HarnessSpec.hs` covers only
  ~4 cases vs LoopSpec's 27 → the thorough cases must be MOVED to HarnessSpec, not deleted.
- `runBackgroundTurn` is LIVE → its `/bg` LoopSpec tests must be PRESERVED (moved), not deleted.
- New path emits NO `model> ` prefix (legacy did). Confirmed cutover delta (WU7 relay name-first
  ping replaces it). Legacy "model prefix" assertions test dead behavior → delete; SignalFlowSpec
  expectations adjusted on repoint.

### CONFIRMED CUTOVER DELTAS (must be CLASSIFIED, not silently dropped)
- **Ambient `_env_target = TargetHarness` routing + IRC `name> ` prefix** (LoopSpec:422):
  `runTabbedLoop` never reads `_env_target`; harness output is emitted as `FullMsg placeholderSlot
  (sanitize txt)` (Runtimes.hs:256) and rendered RAW by RelayWriter (RelayWriter.hs:162) — NO
  `prefixHarnessOutput`. This is a SUPERSEDED legacy single-tab affordance: "target a harness" is
  replaced by tab-based `BoundHarness` routing (you switch to the harness tab and type). The
  per-line `name> ` prefix is dropped for the same reason as `model> ` — the tab identifies the
  harness. DELETE the test in c.5 with this classification stated; record the delta in
  project-context.md; flag the prefix-drop UX to the item-(g) adversarial review / WU11 (do NOT
  re-add the prefix here).
- **`/msg <harness>` IRC prefix** (LoopSpec:443): coverage is PRESERVED on the new path —
  `Slash.executeSlashCommand (CmdMsg …)` applies `prefixHarnessOutput` (SlashCommands.hs:1200,1214)
  and is tested by SlashCommandsSpec:953 (prefixed output), :1015 (nonexistent harness), :1067
  (global-target unchanged). DELETE the LoopSpec copy in c.5, CITING these specs as the equivalent.

### Test-harness prerequisite (Feasibility note)
`mkTestEnv` in LoopSpec and the AgentEnv builder in SignalFlowSpec stub the seven tab-subsystem
fields (`_env_tabRegistry`, `_env_cursors`, `_env_exec`, `_env_relayWriter`, `_env_sinks`,
`_env_wizard`, `_env_tabOutQ`) with `error "8c.2 stub…"`. `runTabbedLoop` FORCES these
(Wiring.hs:128-138,155,355-357), so c.3 and c.4 MUST first populate them via the real
`newTabSubsystem :: Int -> IO TabSubsystem` (Env.hs:252) before driving `runTabbedLoop`. Without
this a bare repoint hits a bottom thunk and crashes. Mechanical, but a required first step.
(`newTabSubsystem` lives in `src/PureClaw/Agent/Env.hs:252`.)

## Coverage-preserving order (ADD new coverage BEFORE deleting old — never an untested window)

### c.1 — Move thorough sanitize cases into HarnessSpec
Move the ~24 extra `sanitizeHarnessOutput` cases (CSI+params, OSC BEL/ST, DCS, cursor moves,
charset designators, C0 controls, DEL, CRLF/CR normalization, escape-only input) from LoopSpec's
`describe "sanitizeHarnessOutput"` into `test/Handles/HarnessSpec.hs`. Suite green.

### c.2 — Extract live /bg tests → test/Agent/BackgroundSpec.hs
Move the `runBackgroundTurn` tests (execution+result, on-disk transcript visibility,
blank→"(no response)", no-provider message, provider-failure redaction) from LoopSpec.
Register in Main.hs + cabal. Suite green.

### c.3 — NEW test/Tabs/WiringSpec.hs (first runTabbedLoop coverage; closes item f)
FIRST build a tabbed test env (populate the 7 tab-subsystem fields via `newTabSubsystem`, per the
Test-harness prerequisite above). Then drive `runTabbedLoop` with fakes (bounded fake channel that
yields scripted inbound messages then EOF; recording sink; no/fake provider; counting fork).
Cover behaviors runTabbedLoop now owns:
- `_sm_source` set-once: captured from first inbound; captured even when content empty; NOT
  overwritten by a later different-sender message (the 3 provenance invariants, repointed).
- **multi-message loop iteration**: the script MUST drive >= 2 inbound messages before EOF, so the
  loop's repeated-receive behavior (LoopSpec:200 "processes multiple messages") is retained.
- EOF / IOException from `_ch_receive` -> "Session ended", clean exit (bounded test).
- empty / whitespace-only inbound handled without provider call.
- `/bg` foreground ack via `fallthrough` ("running in the background..." + fork) — replaces LoopSpec test 16.
- inbound conversation sink registered (registerSink).
Tests must terminate: feed a finite script + EOF; ensure the forked relay-writer thread does not
leak — wrap the loop in `async` and `cancel`/`timeout` (the SignalFlowSpec.hs:122 pattern).
Characterization of existing behavior is acceptable (migrating coverage layer).
Register `Tabs.WiringSpec` in test/Main.hs + pureclaw.cabal `other-modules`.

### c.4 — Repoint SignalFlowSpec: runAgentLoop -> runTabbedLoop
All 5 Signal e2e tests switch entry point. runTabbedLoop reads `_env_channel` and captures
`_sm_source` identically -> the flow holds; preserve the security-critical dual-storage test
(phone+uuid -> session.json + transcript.jsonl). Adjust any expectation for confirmed deltas
(no `model> ` prefix; tabbed relay framing). Suite green.

### c.5 — Delete redundant legacy LoopSpec tests
Remove each runAgentLoop test, with its justification (every block accounted for):
- turn / stream / tool-cycle / provider-error → TurnSpec (single-turn emission :170; stream-throw
  + no-StreamDone return-ctx :345/:360; tool cycle :237).
- slash interception + unknown-cmd + context isolation + `/new` clears context → TabDispatchSpec
  (slash routing / fallthrough) + SlashCommandsSpec (:372 /new, unknown-cmd).
- model-prefix assertions (L193/L395/L410) → dead behavior (cutover delta; relay name-first ping).
- ambient `TargetHarness` IRC prefix (L422) → SUPERSEDED affordance; delete with the cutover-delta
  classification recorded above (NOT silently).
- `/msg` IRC prefix (L443) → covered by SlashCommandsSpec:953/:1015/:1067 (cite in the commit).
- `_env_onFirstStreamDone` one-shot (L207/L224) → legacy-only; never fired on the new path
  (Turn.hs has only a doc comment, no invocation). Delete the tests; DEFER field removal to WU11.
After this LoopSpec references nothing from the legacy loop.

### c.6 — Delete dead production code
Agent/Loop.hs: remove `runAgentLoop`, `runAgentLoopWith` (+ where helpers go/effectiveRegistry/
handleCompletion/executeCall/partsToText) and now-orphaned `noProviderMessage`/`noModelMessage`;
trim export list to `runBackgroundTurn`, `sanitizeHarnessOutput`. Delete `test/Agent/LoopSpec.hs`
(now empty) + unregister. Update Main.hs + pureclaw.cabal. Build clean, full suite green, coverage gate.

## Open checks (resolve during execution; do NOT expand scope)
- `_env_onFirstStreamDone`: does the new path fire it at all? If dead, note for WU11 (don't remove the
  field here — that's the WU11 -Werror dead-field sweep).
- Confirm RuntimesSpec/RelayWriterSpec actually cover runtime emission + relay framing before deleting
  the corresponding legacy assertions in c.5.
- Record the `model> ` prefix drop as a cutover behavior delta in project-context.md.

## Risks
- WiringSpec must bound the `forever` relay-writer fork (no thread leak; deterministic teardown).
- Deleting test coverage of a security invariant (`_sm_source`, dual-storage) is only safe because
  c.3/c.4 add the equivalent on the new path FIRST — order is load-bearing.
