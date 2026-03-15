# PureClaw Sprint Plan — "Ship the Console"

**Date:** 2026-03-09 (revised 2026-03-10)
**Goal:** Ship a minimum viable console UI that Mighty can actually use. Then improve on OpenClaw.
**Principle:** Working software first. Better software second. Don't gold-plate what doesn't exist yet.

---

## Phase 1: Minimum Viable Console

**Goal:** A single-agent PureClaw that Mighty can open a terminal, connect to Signal, and do real work in. Feature-for-feature parity with daily OpenClaw usage — nothing more.

### Sprint 1: "It Works"
Core tools needed to do anything useful in a session:

1. **`edit` tool** — string replacement in files. Used 50+ times per session. Can't work without it.
2. **`process` tool** — background exec management (list, poll, kill, write stdin). Without this, any command >10s blocks everything.
3. **`web_search`** — Brave Search API. Single HTTP GET, parse JSON. ~50 lines.
4. **`message` tool** — proactive send to Signal. Needed for cron results and alerts.

**Done when:** Mighty can start PureClaw, connect via Signal, edit files, run background commands, search the web, and receive cron alerts.

### Sprint 2: "It Survives"
The session doesn't fall over after 30 minutes of real use:

5. **Context tracking** — count tokens, know the limit, expose to agent and user.
6. **Compaction** — summarize and compress when context is high. (`/compact`)
7. **`cron` as agent tool** — agent can create/modify/delete cron jobs (scheduler exists, needs tool interface).
8. **Slash commands** — `/new`, `/reset`, `/status`, `/compact`. Basic session lifecycle.

**Done when:** Mighty can have a multi-hour session without hitting context walls or losing state.

### Sprint 3: "It's Complete"
Remaining single-agent features for full daily-driver parity:

9. **`image` tool** — vision model integration (screenshots, diagrams).
10. **Telegram channel** — verify parity with what's implemented.
11. **Streaming improvements** — chunked responses.
12. **Integration tests** — end-to-end: Signal message → agent response.

**Done when:** Mighty can run his entire daily workflow on PureClaw with zero fallback to OpenClaw for single-agent work.

---

### Phase 1 Definition of Done
- [ ] Signal channel works end-to-end
- [ ] All Tier 1 & 2 tools functional
- [ ] Mighty can do a full day's work without touching OpenClaw
- [ ] Mighty says "this works"

---

## Phase 2: Better Than OpenClaw

**Goal:** Sub-agent UX that's *obviously better* than OpenClaw. This is where PureClaw becomes worth switching to — not just equivalent, but superior.

**Prerequisite:** Phase 1 complete. Mighty is daily-driving PureClaw for single-agent work.

### The Problem We're Solving

OpenClaw sub-agent UX failures Mighty experiences today:

1. **Discoverability is zero.** Mighty didn't know `/subagents list` existed after a month of daily use.
2. **No visibility.** Spawned sub-agents are black boxes until they finish or you explicitly ask.
3. **Steer/kill reliability is unclear.** Does `/steer` actually interrupt mid-turn? Feedback is ambiguous.
4. **Results arrive as system messages.** Completed output is a `[System Message]` that I rewrite. User can't see raw vs editorialized.
5. **No pause/resume.** Kill or steer, but no "hold that thought."
6. **Timeout handling is blunt.** Single value, no extension, no warning.
7. **No cost/resource visibility per sub-agent.**
8. **Control plane and data plane are conflated.** Agent management commands and conversation flow through the same channel.

### Sprint 4: "Multi-Agent Core"
14. **Isolated sessions** — each sub-agent gets its own workspace, memory, conversation.
15. **`sessions_spawn`** — create sub-agent with task, model, timeout.
16. **`subagents` tool** — list, steer, kill, inspect.
17. **`sessions_list` / `sessions_history` / `sessions_send`** — cross-session inspection and messaging.
18. **Agent routing** — config-driven: sender → agent, keyword → agent.

### Sprint 5: "Multi-Agent UX"
Mighty designs these — the features that make PureClaw *better*:

19. **Slash commands for sub-agent control** — `/subagents`, `/kill`, `/steer`, `/tell`.
20. **Real-time progress/status** for running sub-agents (push, not poll).
21. **Structured result delivery** — typed data, not text blobs rewritten by parent agent.
22. **Pause/resume** with state persistence.
23. **Per-agent cost/token tracking** visible to user.
24. **Resource budgets** — "this sub-agent can use at most N tokens / $X / Y minutes." Enforced.

### Sprint 6: "Polish"
25. **WhatsApp channel** — if Envoy resumes.
26. **Progressive disclosure** — surface sub-agent commands contextually, not buried in docs.
27. **Clear visual separation** of control plane vs conversation.

---

### Phase 2 Definition of Done
- [ ] At least one CEO agent running on PureClaw
- [ ] Sub-agent control is demonstrably better than OpenClaw
- [ ] Mighty says "I prefer this"

---

## Architecture Notes (for Phase 2)

- **Explicit state machine per sub-agent:** Created → Running → Paused → Completed/Failed/Killed. Every state visible, every transition user-controllable.
- **Event stream, not polling:** Progress pushes to user. Lightweight event bus the chat interface subscribes to.
- **Structured results:** Sub-agent output is typed data (JSON/structured). User sees raw OR summarized.
- **Resource budgets enforced, not advisory.**
- **First-class in the UI:** Sub-agents as visible and controllable as files in a file manager.
