# Execution State (updated 2026-06-09)
## CUTOVER COMPLETE: new tab system is the live path; legacy deleted; build green; suite passes (2486)
| Stage | Commit |
|-------|--------|
| WU1-7 infra | ad3a1c9..14cc2a8 |
| 8a prep | 466c1f5 |
| spike +review | d2a86d6,9bbdb54 |
| 8b.1 relay widen | 6bd0536 |
| 8b.2 runTurnWithTools | 68307cb |
| 8b.3a RelayWriter | 530352a |
| 8b.3b Exec | 3451538 |
| 8b.4 TabDispatch | ab8cb01 |
| 8c.1 Runtimes | dc01435 |
| 8c.2 wiring flip (runTabbedLoop live) | 7dfb943 |
| 8c.3 delete legacy + slim Handles.Tab | 6fdd7d4 |
## CAVEAT: cutover COMPILES + unit-tests pass, but END-TO-END behavior not yet validated (that's 8d CLISpec)
## Remaining
- 8d: (a) end-to-end CLISpec (does the app actually work: /new, chat turn, /nt, /tab, /close, /N, /relay);
      (b) rewrite Routing.ParseSpec (unwired in 8c.3); (c) DONE — see "8d.c DONE" below;
      (d) decide cold-start UX (auto-create a CLI tab vs the "no active tab" hint); (e) close 8c.2 stubs
      (noOutputHarness/openSessionFromDisk/detach); (f) DONE (folded into 8d.c — Tabs.WiringSpec now covers
      runTabbedLoop); (g) COMPREHENSIVE ADVERSARIAL REVIEW of whole cutover.
- WU9 harness death two-phase removal; WU10 config+WARN+docs;
- WU11 restore -Werror (remove dead AgentEnv fields _env_focus/_env_tabs/_env_runners/_env_activeCount/
  _env_channelOutQ + the now-dead _env_onFirstStreamDone + benign warnings; sweep stale runAgentLoop
  doc-comments in Turn.hs/Env.hs/SlashCommands.hs) + final coverage gate + self-reflect + PR.

## 8d.c DONE (2026-06-10) — migrate LoopSpec/SignalFlowSpec to the new path + delete the dead loop
bd pureclaw-2q9. Plan-review-gate APPROVED (iter 2). Subagent-driven, 2-stage review per step. Suite 2475 green.
| step | what | commit |
|------|------|--------|
| c.1 | sanitizeHarnessOutput tests -> HarnessSpec (true home) | f6a9029 |
| c.2 | live runBackgroundTurn /bg tests -> Agent.BackgroundSpec | 1980e56 |
| c.3 | NEW Tabs.WiringSpec: first runTabbedLoop coverage (+8); _sm_source set-once, EOF, /bg ack | f3c306a |
| c.4a | FIX pureclaw-opr provenance regression (RED 65b6385 / GREEN d2ea526) | d2ea526 |
| c.4b | repoint 4 Signal e2e tests -> runTabbedLoop (active-tab /nt + chunk recording) | 2735910 |
| c.5 | delete legacy test/Agent/LoopSpec.hs (18 tests covered/classified) + unregister | 8759021 |
| c.6 | delete dead runAgentLoop/runAgentLoopWith/handleCompletion + noProvider/noModelMessage; trim exports | 8858f21 |

## RESOLVED — the original "8d END-TO-END FINDING" silent-swallow bug was fixed pre-8d.c (commit 8f63c5c).
## NEW REGRESSION found+fixed during 8d.c (bd pureclaw-opr, CLOSED): the 8c cutover captured the inbound
## MessageSource on _env_session (foreground) not the active tab's BOUND session, and wrapped the per-tab
## transcript provider with source=Nothing (Wiring.hs:219) — so phone+uuid were dropped from BOTH the bound
## session's session.json AND transcript.jsonl. Fix (d2ea526, Wiring-localized): runTabbedLoop now captures
## the source set-once onto the conversation's active bound session (cursor->ref->store), and startProvider's
## transcript wrapper reads that session's _sm_source per-request. Restores legacy (Just (_im_source msg)).
## CUTOVER DELTAS classified (not regressions): no `model> ` reply prefix (relay name-first ping replaces it);
## ambient `_env_target=TargetHarness` IRC-prefixed routing superseded by tab-based BoundHarness routing.

## 8d END-TO-END FINDING (2026-06-09) — REAL BUG
Manual binary run: command/tab layer WORKS (/new->"new tab /0", /nt, /tabs lists "/0 session live",
/relay->exact §14 copy, switching). BUT a chat turn produces NO streamed reply, NO error log (only
[INFO]); process exits ~5s before stdin EOF. Likely: provider turn throws inside the runtime worker and
runTurnWithTools SILENTLY swallows it (catches SomeException -> TurnEnd -> return) => no output, no error.
Suspect mkExecDeps/mkProviderRuntime provider wiring OR a forked worker/relay-writer thread exception
killing the process. NEEDS: (1) deterministic integration repro with a controllable/fake provider;
(2) instrument the silent-swallow path (log provider errors via _turn_record/logger or surface to channel);
(3) verify thread linking (relay-writer fork). This is the top 8d task before ParseSpec/LoopSpec rewrites.
