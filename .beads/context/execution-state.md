# Execution State — pureclaw-3oy: Harness Registry (Phases 1-3 + adoption-UX-rework COMPLETE)

Last updated: 2026-06-03 — adoption-UX-rework COMPLETE; pushed to PR #75.

## Status
- Phases 1 (.1-.10), 2 (.15-.20), 3 (.21-.28): COMPLETE. Adoption-UX-rework (.29-.31): COMPLETE.
- All adversarially reviewed (per-WU + final comprehensive + security reviews). PR #75 OPEN on feat/harness-registry-p1.
- Gates: cabal build -Wall -Werror clean; cabal test 2534/0; hlint clean; pty-firewall OK; frontend tsc strict + vitest 243/0.

## Adoption-UX-rework (.29-.31) — user-directed
Replaced the Scan-button/Sidebar-Discoverable approach with attach-in-the-New-Tab-form.
- RW-WU1 (.29): consent-only adoption (interactive attaches ANY local session; headless still denied);
  REMOVED the default-deny adoptable-sessions allow-list (security-design-gate PASS); discovery lists all.
- RW-WU2 (.30): removed Scan button + Sidebar Discoverable section.
- RW-WU3 (.31): New Tab form = 3 sections (AI Provider / New Harness / Existing Harness: dropdown+manual -> adopt).

## Open follow-ups (children of pureclaw-3oy / related)
- .11 Backend/Tmux seam · .12 touchSessionLastActive guard · .13 uncorroborated-spawn routing
- .14 harness activity log (append-only ops log; needs its own design gate)
- pureclaw-3q7 spawn-side _tc_window placement
- (optional) legacy tmuxDisplay non-literal send

## Next (TOP PRIORITY)
- **pureclaw-2jj (P0): run `/pr-shepherd 75`** to drive PR #75 to merge — do NOT auto-start; user-initiated (outward-facing + billed). Wait for the user to say go.
- Then follow-ons: pureclaw-3q7, .14, .13, .12, .11.
- Epic core scope (Phases 1-3) + the adoption UX rework are delivered; PR #75 is merge-pending.

---

## Sub-issue pureclaw-3oy.33 — JSONL session-log capture (in-progress on feat/harness-registry-p1)

Plan: `.beads/plans/active-plan.md`. Design: `docs/harness-jsonl-capture.md` (gate 5/5).
Spike: `docs/harness-jsonl-capture-spike.md`. Each WU runs the 4-phase orchestrated
loop: IMPLEMENT (coder) → VALIDATE (orchestrator-run build -Wall -Werror + cabal test
+ hpc coverage + hlint) → ADVERSARIAL REVIEW (fresh reviewer, PASS) → COMMIT.

| WU | Title | Status | Commit |
|----|-------|--------|--------|
| WU0 | Phase-0 spike | COMPLETE | 697477b |
| WU1 | ClaudeSessionUuid validated newtype | COMPLETE | ca10bdb |
| WU4 | pure line-splitter (Offset/Buffer/splitLines) | COMPLETE | 3f0ea8b |
| WU2 | SafeClaudeLogPath | COMPLETE | a13d9fb |
| WU8 | frontend thinking renderer | COMPLETE | 91100ff |
| WU3 | JSONL→TranscriptEntry converter | COMPLETE | 25e9acb |
| WU6 | spawn correlation + persistence | COMPLETE | e4cc958 |
| WU5 | JsonlTailDeps + tailer loop (deps WU2,WU3,WU4 met) | READY | — |
| WU7 | capability + on-demand wiring (deps WU5,WU6) | BLOCKED (WU5) | — |
| WU9 | frontend optional-view control (deps WU7,WU8) | BLOCKED (WU7) | — |
| WU10 | integration + coverage sweep (deps WU1..WU9) | BLOCKED | — |

Next ready: WU5 (the IO tailer loop). Then sequential: WU7 -> WU9 -> WU10.
Full suite now at 2650 examples / 0 failures. New modules ClaudeSession,
JsonlTail, ClaudeLogPath, ClaudeLogConvert all at 100% expr/alt coverage.

Coverage convention: HPC "top-level declarations" is low codebase-wide (derived-instance
artifact; Security.Path 29%, Session.Types 49%); the gate is read against expressions +
alternatives (WU1 97.5%/100%, WU4 100%/100%). WU1+WU4 each also registered their spec in
test/Main.hs (manual spec registry) alongside pureclaw.cabal — required for execution.
