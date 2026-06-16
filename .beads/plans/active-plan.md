# Active Plan
<!-- approved: 2026-06-16 (design-review 5/5; plan-review 3/3) -->
<!-- user-approved: true (execution: subagent-driven) -->
<!-- status: in-progress -->

## Canonical plan
docs/superpowers/plans/2026-06-16-unify-tab-and-session-name.md
Spec: docs/superpowers/specs/2026-06-16-unify-tab-and-session-name-design.md
Branch: feat/web-frontend-slash-dispatch

## Goal
Make the displayed name a single SESSION property (override -> first-message default),
identical in Active Tabs and Recent Sessions and across TUI/web; remove _tab_name.

## Tasks
- [ ] Task 1: Shared PureClaw.Session.Title (sessionTitle + moved firstMessageSnippet)
- [ ] Task 2: TUI parity (recentSessions -> sessionTitle)
- [ ] Task 3: _td_setSessionDescription seam (threaded param, not AgentEnv field) + /tab rename re-target + ServerMode closure + description cap (120)
- [ ] Task 4: Remove _tab_name + _ts_name; add _ts_label; tab labels from session; tabs.json back-compat
- [ ] Task 5: Frontend join across 3 consumers (ActiveTabs/HarnessControls/deriveAgent) + never-blank fallback
- [ ] Task 6: Always-visible rename pencil (CSS)
- [ ] Task 7: Cross-surface parity tests + coverage + verification
