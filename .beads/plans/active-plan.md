# Active Plan
<!-- approved: 2026-06-21 (plan-review 3/3, iteration 2) -->
<!-- user-approved: true (execution: subagent-driven) -->
<!-- status: complete (WU1 d04dfd6, WU2 9b657c8; final review READY TO MERGE; suite green 2829/0) -->

## Canonical plan
docs/superpowers/plans/2026-06-21-harness-output-streaming-reliability.md
Branch: feat/harness-live-edit
RED test committed: d944fbd (test/Harness/ReconcileSpec.hs — "records a fast turn the watcher only ever samples as Idle")

## Goal
Make automatic harness output reliable by driving streaming + finalize off
turn-content change/stabilization instead of the ephemeral Thinking→settle
liveness edge (root cause; reproduced by the committed RED test).

## Work units
- [x] WU1: Content-driven watcher — replace publishUpdates/settle with a single
      stepTurns pass over a richer TurnState (stable id, last text, stable-tick
      counter, active flag). Stream on growth; finalize when idle/awaiting +
      stable ≥ defaultSettleStableTicks(=1); finalize active turns on terminal
      transition (Exited/Orphaned/absent) from last streamed text; dedup
      unchanged content; new id per new turn. Preserve resilience + same-id
      frontend contract. Files: src/PureClaw/Harness/Reconcile.hs,
      test/Harness/ReconcileSpec.hs. DoD #1-8 in the canonical plan.
- [x] WU2: Widen _hh_snapshotTurn capture extent from -S -0 (visible only) to a
      named scrollback-inclusive constant (~200) at both handle sites. Files:
      src/PureClaw/Harness/ClaudeCode.hs (+ test/Harness/ClaudeCodeSpec.hs).

## Out of scope (documented in canonical plan)
- CLI/TUI _he_sessionId=Nothing (by design; frontend backfills, symptom unaffected)
- Prose-less / tool-only turns (pre-existing extractTurnClaude behavior)

## Gates
- TDD throughout (RED already committed for the core case).
- .coverage-thresholds.json 100% (lines/branches/functions/statements) — blocking.
- Full suite green: nix develop . --command cabal test
