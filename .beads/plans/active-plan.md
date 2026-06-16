# Active Plan
<!-- approved: 2026-06-16 -->
<!-- gate-iterations: 3 (all blockers fixed; Feasibility+Scope PASS every round) -->
<!-- user-approved: true (execution: subagent-driven-development) -->
<!-- status: in-progress -->
<!-- design-review-gate: PASSED (5/5) -->

## Canonical plan
Full implementation plan (10 tasks, TDD steps):
  docs/superpowers/plans/2026-06-16-web-frontend-slash-dispatch.md
Spec:
  docs/superpowers/specs/2026-06-15-web-frontend-slash-dispatch-design.md
Branch: feat/web-frontend-slash-dispatch

## Goal
Route the web frontend's handleSend through the same pre-inference slash-command
classification + short-circuit the TUI/channels use, so /-commands never reach the
LLM, with full command parity and a default-localhost trust boundary.

## Task checklist
- [ ] Task 1: Capture channel + InteractiveUnsupported (Handles/Channel.hs; append to existing ChannelSpec)
- [ ] Task 2: Pure classifyInput (new Agent/SlashDispatch.hs)
- [ ] Task 3: runSlashInput IO seam (capture + interactive deferral)
- [ ] Task 4: Default-localhost bind + CORS-follows-host + fail-loud WARN (Server.hs; update existing ServerSpec)
- [ ] Task 5: --bind CLI flag
- [ ] Task 6: _fe_agentEnv field + shared mkTestAgentEnv (all 4 FrontendEnv sites)
- [ ] Task 7: handleSend short-circuit + kind envelope (integration tests)
- [ ] Task 8: Frontend kind-keyed transient bubble across ALL three send sites
- [ ] Task 9: File interactive-commands GitHub issue + wire URL
- [ ] Task 10: Coverage gate (cabal test --enable-coverage, 95% thresholds) + self-reflect + PR

## Coverage
.coverage-thresholds.json is source of truth: command `cabal test --enable-coverage`,
thresholds 95 (lines/branches/functions/statements). Frontend.API is a staged waiver;
new SlashDispatch + capture-channel modules must meet 95%.
