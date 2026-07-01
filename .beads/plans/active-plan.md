# Active Plan
<!-- approved: 2026-06-22 (design-review 5/5; plan-review 3/3) -->
<!-- user-approved: true (execution: subagent-driven) -->
<!-- status: in-progress -->

## Canonical plan
docs/superpowers/plans/2026-06-22-harness-log-content-source.md
Spec: docs/superpowers/specs/2026-06-21-harness-log-tailing-content-source-design.md
Branch: feat/harness-live-edit

## Goal
Make Claude Code's JSONL log the reliable live source of assistant-PROSE for the
core transcript of spawned claude-code harnesses, feeding the merged stepTurns
loop, with tmux fallback. Prose-only; per-message + guaranteed final; reuse the
merged harness-jsonl-capture modules (WU1-4/6/8).

## Tasks
- [ ] Task 1: splitLinesBounded (DoS-capped line splitter) — JsonlTail
- [ ] Task 2: ClaudeLogProse pure prose fold + deterministic namespaced turn id (+ export ClaudeLogConvert helpers)
- [ ] Task 3: ClaudeLogTail bounded tail step + JsonlTailDeps seam
- [ ] Task 4: turn-content provider seam + minimal stepTurns integration (+ update ReconcileDeps literal test sites)
- [ ] Task 5: disk-seeded recorded-id dedup + Async lifecycle wiring (CLI/Commands)
- [ ] Task 6: integration test + manual verification

## Out of scope (documented)
thinking/tool/Request surfacing; adopted/CLI/non-claude log feed; optional opt-in
view; post-process-restart re-attach (unbound boot-reconstructed harness; dedup
is forward-safe for it).
