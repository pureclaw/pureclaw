---
status: in-progress
issue: 79
spec: docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md
plan: docs/superpowers/plans/2026-06-08-tabs-as-view-refactor.md
design_review_gate: PASSED (2026-06-08)
plan_review_gate: PASSED (2026-06-08, feasibility round 5)
branch: feat/tabs-as-view-refactor
execution_method: metaswarm-orchestrated (chosen 2026-06-08)
---

# Approved: Tabs-as-View Refactor (GitHub #79)

Full plan: docs/superpowers/plans/2026-06-08-tabs-as-view-refactor.md (11 work units).
Spec: docs/superpowers/specs/2026-06-08-tabs-as-view-refactor-design.md.

Strategy: WU1-7 additive new modules; WU8 incremental migrate-first/delete-last
cutover with -Werror locally relaxed (gitignored cabal.project.local -Wwarn);
WU9 harness death; WU10 config+WARN+docs; WU11 restore -Werror + integration + gate.
Trust model: single trusted operator. /new resets active tab; /nt new tab.
