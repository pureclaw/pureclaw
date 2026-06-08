# Design — Harness Registry & Lifecycle (v2)

**Epic:** `pureclaw-3oy` (expanded) · **Status:** APPROVED by design-review-gate (PM/Designer/Security/CTO r2 + Architect r3, 2026-06-01)
**Supersedes-as-component:** the paused per-harness-session-name plan (`.beads/plans/tmux-session-name-plan.md`)
**Merges:** the deferred attach work `pureclaw-jlc`
**Date:** 2026-06-01

## 0. Decisions locked (this revision)

| # | Decision | Source |
|---|---|---|
| K1 | **tmux substrate: the user's shared default server** (not a private `-L` socket). PureClaw's harnesses coexist with the user's own windows; adoption of external windows is frictionless. We accept the reconciliation + security tax this implies. | user |
| K2 | **Identity = UUID anchored by multiple signals, with PID-provenance as the trust anchor.** Track the **shell PID** (`#{pane_pid}`) AND the **harness process PID** (the `claude`/`codex`/`opencode` process running inside the window). The `@pcl_id` tmux marker is a *re-find hint only* (attacker-writable on a shared server — §3, §8). | user + Security C4 |
| K2b | Registry state lives in a **`TVar`** (STM), not `IORef` — a background reconcile loop does compound read-modify-write concurrently with HTTP handlers. | Architect F3 / CTO |
| K3 | Handles use **cached coordinate + revalidation**, not a per-I/O `@pcl_id` sweep (the receive path polls every 500 ms). | Architect F4 |
| K4 | `HarnessId` is an **optional, additive** `session.json` field; `_tc_window` is **dual-written** for one release for back-out; legacy rows lazily migrate. | Architect F6 / CTO |
| K5 | A **de-risking spike precedes Phase 1** (validate `@pcl_id`/PID behavior across rename/move/restart/kill-server; measure sweep cost). | CTO |
| K6 | **Land PR #74 first**, then branch Phase 1 from it (it touches the same `createTab`/`harnessKeyFromKind` this design changes). | CTO |
| K7 | `ExternallyModified` and `Unknown` are **not liveness states** — the former is an orthogonal *flag*, the latter means *hold last-known state*. Liveness is `Idle`/`Thinking`/`Exited`/`Orphaned`. | Designer B1 / PM S1 |
| K8 | Phase 1 includes a **minimal Active-Tabs slice** (wire `_fe_listTabs` to the registry) so the user's reported symptom is fixed and Phase 1 is user-validatable. | PM B1 |

> **Module-path note (Architect N2 / Security):** unqualified `Tmux.hs` in this doc means
> `src/PureClaw/Harness/Tmux.hs` (the actively-used harness tmux ops) — **distinct from**
> `src/PureClaw/Backend/Tmux.hs` (the raw-shell abstraction, which already carries an `AuthorizedCommand`).
> `Commands.hs` means `src/PureClaw/CLI/Commands.hs`. The §8 B1 auth seam targets `Harness/Tmux.hs` +
> the `ClaudeCode.hs` capture/launch sites, NOT `Backend/Tmux.hs`.

## 1. Problem & motivation

(unchanged from v1) A frontend-created harness shows only in **Recent Sessions**, never **Active Tabs**
(`_fe_listTabs = pure []`, `Commands.hs:748`); identity is the mutable tmux **window name** (`_tc_window`)
which breaks under user rename/kill/move; health is a shallow 2 s probe over the in-memory map with no
reconciliation against tmux reality and no disappearance event (`ActivityProbe.hs:117`). Goal: PureClaw as
a *manager* of tmux-backed agents — durable identity, continuous reconciliation, live Active Tabs with
health, survival across PureClaw restarts and out-of-band mutation, and adoption of external tmux windows.

## 2. Non-goals

- Replacing tmux; multi-host/remote (SSH backend); **auto-restart** of dead harnesses (we detect + reserve
  a manual Restart affordance, §7; implementation deferred).

## 3. Identity model

A harness's identity is a PureClaw-assigned `HarnessId` (UUID), anchored by layered signals. **No tmux
attribute is trustworthy on a shared server**, so trust derives from **process provenance we recorded at
spawn**, not from any tmux-settable field.

| Signal | Set / read | Survives rename? | Survives PCL restart? | Survives tmux-server restart? | Role |
|---|---|---|---|---|---|
| `HarnessId` UUID | PCL-generated at spawn | — | persisted in session.json (K4) | persisted | canonical key |
| **shell PID** `#{pane_pid}` | captured at spawn; re-read each tick | yes | yes (while alive) | **no** (server gone) | liveness + provenance |
| **harness PID** (the agent process) | derived by **recursive descent of the pane process subtree**, not a one-level child — the launch wrapper is `env … script -q /dev/null <binary>` (`Harness/Tmux.hs:104-113`), so the real tree is `shell(#{pane_pid}) → env → script → [Linux: sh -c] → <binary>`. Walk descendants of `#{pane_pid}` and match the flavour binary by `comm`/`cmdline`. **`#{pane_current_command}` is an unreliable hint here** (it usually reports `script`, which owns the PTY), so it is NOT used as the harness signal. | yes | yes (while alive) | **no** | precise liveness (harness dead vs shell dead) + **trust anchor** |
| `@pcl_id` window user-option | `set-option -w @pcl_id <uuid>`; `#{@pcl_id}` | yes | **yes** (tmux server holds it) | **no** | re-find **hint only** — attacker-writable, NOT authenticity |
| window name | `claude-code-<shortid>` | no (user editable) | yes | n/a | **display only**, never a key |
| (session, window-index) | runtime coordinate | no | no | no | ephemeral target; cached + revalidated (K3) |

**Harness-PID mechanism (portable):** there is no `/proc` on macOS, so the subtree walk uses a
`ps -axo pid,ppid,comm,command`-based descendant traversal (works on both BSD/macOS and Linux), matching
the flavour binary; `comm` is truncated to 15 chars on Linux (fine for `claude`/`codex`/`opencode`) so
`command`/`cmdline` is the tiebreaker. **If the spike (Phase 0) finds the binary PID can't be reliably
isolated through the `env`/`script` wrapper across both platforms, the fallback is to make the binary a
determinate process** — either `exec` the binary as the last wrapper step (so `script`'s child IS the
binary) or have the launch write a PID sentinel — decided by the spike, not assumed.

**Re-identification (reconcile):** find candidate windows by `@pcl_id`; then **corroborate** against the
recorded shell+harness PIDs before treating the window as the genuine managed harness. A flavour-name /
`comm` match alone NEVER promotes a window to "ours" — it must combine with a recorded PID (Security N2). PID-only matching
(for legacy/adopted windows lacking provenance) must be corroborated by a second signal (window-name prefix
or `#{pane_start_time}`) to defend against **PID reuse**. A window whose `@pcl_id` matches but whose
recorded PIDs are gone/different → **Exited/ExternallyModified**, not silently Idle (defends the
`kill-pane`-and-run-something-else case).

**`@pcl_id` is spoofable** on a shared server (any user can `set-option @pcl_id`). Therefore: for `Spawned`
harnesses, routing/capture trust requires PID-provenance corroboration; a marker collision or a marker on a
window with no matching recorded PID is treated as **not ours** (logged, never routed to). See §8 C4.

**tmux-server restart / reboot:** the tmux server dies → all `@pcl_id` markers and PIDs vanish → every
persisted harness reconstructs as **Orphaned** from `session.json` (no live window). This is the same as
"PCL never spawned them"; surfaced as Orphaned, not silently re-found. (Architect F1.)

## 4. The registry (`TVar`)

`HarnessRegistry = TVar (Map HarnessId HarnessEntry)` replaces the shared `IORef (Map Text HarnessHandle)`
(`_env_harnesses`==`_fe_harnesses`, the same ref wired at `Commands.hs:680,735`).

```
HarnessEntry { _he_id, _he_flavour, _he_session, _he_windowName,
               _he_shellPid :: Maybe Int, _he_harnessPid :: Maybe Int,
               _he_origin :: Spawned | Adopted | Discovered,
               _he_liveness :: Idle | Thinking | Exited | Orphaned,
               _he_extModified :: Bool,        -- orthogonal flag (K7)
               _he_stale :: Bool,              -- last sweep failed (Unknown → hold)
               _he_coord :: Maybe (Text,Int),  -- cached (session,index); revalidated by reconcile (K3)
               _he_sessionId :: Maybe SessionId, _he_handle :: HarnessHandle }
```

`HarnessHandle` send/receive/stop read `_he_coord` from the entry at call time (cached); on a tmux
"target not found" they trigger an on-demand `@pcl_id`+PID re-resolve and update the cache. This requires
refactoring `mkClaudeCodeHarness` so the handle no longer closes over a frozen `windowIdx` (`ClaudeCode.hs:106`).
Reconcile is the single owner that refreshes `_he_coord` (one server sweep per 2 s, not per I/O).

**Concurrency:** one `atomically` diff-and-merge per reconcile tick merges tmux-observed fields into existing
entries **by key**, preserving entries inserted concurrently by HTTP/slash handlers (no lost-update clobber).

## 5. Health & reconciliation

Generalize the `ActivityProbe` loop into a reconcile loop (default 2 s; same broker surface). Each tick:
one server-wide `list-windows -a -F '#{session_name}\t#{window_index}\t#{window_name}\t#{@pcl_id}\t#{pane_pid}\t#{pane_current_command}\t#{pane_dead}'`.
**The continuous sweep only acts on rows whose `@pcl_id` is one of ours** (corroborated by PID); all other
rows are discarded immediately and **never `capture-pane`d** (§8 B4/C1). Adoption *discovery* (scanning
unmarked windows) is a **separate, on-demand, user-invoked** action — not part of the continuous loop.

Diff is a **symmetric** map diff (not one-way `differenceWith`) so **disappearance** emits an event
(fixing `ActivityProbe.hs:117`); first-tick "emit nothing" baseline (DoD D17) is preserved.

Liveness (per entry): `Idle` / `Thinking` (screen capture, existing `isIdle`) / `Exited` (harness PID gone
or `pane_dead`, window present) / `Orphaned` (no live window+PID for this id). **`Exited` is only observable
if PureClaw sets `remain-on-exit on` on its harness windows** — the spike (§11 E3) found that by default the
window vanishes the instant the harness dies, collapsing `Exited` into `Orphaned`; Phase 1 sets it per
harness window. `_he_extModified` is set when a matched window's name/session changed (flag, not a state).
`_he_stale` is set when the sweep/capture failed this tick — **hold last-known liveness, don't repaint** (K7).

**Loop resilience:** unlike today's probe (dies on any non-cancel exception), the reconcile loop **tolerates
transient sweep failures** (mark entries `_he_stale`, continue); it only exits on cancellation. tmux
absent/too-old is detected up front via a capability check on `requireTmux`/`findTmux` (`Tmux.hs:55,73`);
without the needed format vars the registry degrades to name-keyed best-effort with a loud warning.

**Eviction:** Phase 1 ships *detection* of `Orphaned`; the retention/grace-window policy (retain greyed vs
evict; effect on `session.json`) is **deferred to Phase 2** where it has a UI consumer (CTO rec; §10 Q2).

## 6. Adopting external tmux (Phase 3)

Discover (on-demand, gated): list unmarked windows via metadata only (`list-windows -F`, **never**
`capture-pane`). Adopt (explicit per-window user action, security-gated §8): record shell+harness PIDs,
stamp `@pcl_id`, link/create `session.json`, **begin scrollback capture from the adoption point forward**
(not the pre-existing backlog — §8 B3). Release: remove `@pcl_id`, stop management, **does not kill the
window**; transcript-retention on release is specified in §8 C2.

## 7. Session ↔ harness join & frontend

- **Join:** `session.json` stores `HarnessId` (additive/optional, K4); `harnessKeyFromKind` becomes
  "resolve `HarnessId` → entry", with a legacy `_tc_window`-name fallback until migrated. `_tc_window` is
  dual-written for one release. `TargetHarness` (CLI routing, `Loop.hs:163`) keeps carrying a **label**,
  resolved to `HarnessId` at lookup (no UUIDs in the CLI surface; Architect F5).
- **Active Tabs** ← live registry snapshot via wired `_fe_listTabs` (Phase 1 minimal slice, K8).
- **Recent Sessions** ← persisted history minus active (the existing `activeTabSids` exclusion at
  `API.hs:450` now works). A harness appears in exactly one section.
- **Discovered/adoptable** ← collapsed-by-default section (modeled on the existing `ArchivedSection`),
  counted, hidden when empty; populated only by an on-demand discovery scan.
- **State→visual mapping (Designer B1)** — reuse the existing 3-icon vocabulary + one flag, not six glyphs:

  | Liveness/flag | UI |
  |---|---|
  | Thinking | existing thinking shimmer + `ActivityDot` |
  | Idle | ● running |
  | Exited | ✕ crashed + **[Restart] (reserved)** / **[Dismiss]** |
  | Orphaned | ✕ + greyed row + **[Dismiss]** |
  | ExternallyModified (flag) | small ⚠ "edited" pill on whatever liveness applies + **[Acknowledge]** |
  | stale (Unknown) | hold last icon; subtle dimmed/“stale” cue; no distinct glyph |

- **Actions (Designer B2/B5, PM B2/B3):** every live row exposes its **attach command**
  (`tmux attach -t <session>` + window, copyable — PM S4/Designer B3); Exited/Orphaned → **Dismiss**
  (removes the live row; session stays in Recent Sessions); ExternallyModified → **Acknowledge** (clears
  flag, "name X→Y" tooltip); Exited → **Restart** affordance reserved (label present, impl deferred — PM B3);
  Adopted rows → **Release** (distinct from Close; never kills the window); Discovered rows → **Adopt**
  (with a consent confirmation naming the trust consequence). Origin shown via a pill (Spawned/Adopted).
- **Connection state:** when the WS is `reconnecting`/`closed`, dim the registry view + banner (health
  glyphs are stale during a gateway restart). Loading: "Scanning tmux…" skeleton on first boot sweep.
- **PCL-side naming (PM S3):** users can name a harness in PureClaw (stored on the entry/session,
  independent of the tmux window name).

## 8. Security (rewritten — shared-server model keeps all of this in scope)

- **B1 — tmux is NOT currently gated.** `runTmux`/`runTmuxSilent` (`Tmux.hs:82-97`) call `P.proc` directly,
  **bypassing `SecurityPolicy`/`authorize`** (`Security/Command.hs:41`). v1's claim that sweeps "go through
  the authorized-command path" was false. **Phase 1** routes all tmux invocations through an explicit
  authorization seam (or a documented dedicated tmux gate), so the manager's own tmux use is policy-governed.
  The Phase-1 plan MUST enumerate every raw `P.proc tmux*` call site so none slips the seam, **including**:
  `runTmux`/`runTmuxSilent` (`Harness/Tmux.hs:82-97`), `captureWindow` (`Harness/Tmux.hs:242`),
  `listSessionWindows` (`Harness/Tmux.hs:304-320`), `captureFullScrollback` (`ClaudeCode.hs:205-219`),
  and `checkWithTmux` (`ClaudeCode.hs:287`, reached via the `_hh_status` check). (List is non-exhaustive;
  the plan does its own sweep for `P.proc tmux`.)
  The seam governs the tmux **invocation**; the in-pane harness command is a deliberately shell-interpreted
  string (`stealthShellCommand`) whose safety rests separately on `shellEscape`/`escapeForShell` — distinct
  boundaries the plan must treat separately. **§10(b) decision (tmux: new gate vs reuse `AuthorizedCommand`)
  must be made before Phase 1 implementation, not during it** (CTO).
- **B2 — adoption gate is typed + consent-only.** Adoption yields an `AdoptedHarness` constructible only via
  an explicit consent check (mirroring `AuthorizedCommand`/`SafePath`); the value constructor stays
  unexported, so downstream adopt code is type-forced through the gate. **The allow-list was deliberately
  dropped (adoption-UX-rework WU1, an explicit security-model relaxation):** in the interactive path the user
  *picking a session in the foreground New-Tab form IS the consent*, so `authorizeAdoption ConsentInteractive
  <session>` succeeds for ANY session. The single, load-bearing remaining control is **headless-deny**:
  `ConsentHeadless` (gateway/bot server, import, cron/daemon/RemoteTrigger, any non-interactive run) →
  `Left AdoptNoConsentChannel` — those runs **cannot adopt** (fail-closed; no human at the confirm dialog).
  All other Phase-3 controls remain: capture-from-adoption-point (B3), `send-keys -l --` input hygiene +
  `validateTmuxIdent` (C3), and the metadata-only discovery guarantee (C1). The adopt MECHANISM (not the
  gate) still validates the session/window identifiers, so a malicious session string minted into a token
  is refused at `adoptExternalWindow`.
- **B3 — scrollback exfiltration.** Adopted-harness output flows to `transcript.jsonl` and is **broadcast to
  WS subscribers**. On adoption, capture **from the adoption point forward**, not the pre-existing backlog,
  so a window's prior secrets don't cross into the transcript/broadcast. Documented that the broker audience
  is the adopting principal.
- **B4 — bounded enumeration.** The continuous sweep reads server-wide metadata but **only retains/acts on
  our `@pcl_id` windows**; it never captures other sessions. Adoption *discovery* is on-demand and now
  **lists ALL sessions' unmarked, live windows** (the allow-list scope was dropped — see B2; consent gates
  adoption, not discovery). Discovery stays metadata-only (C1): it never captures a pane, only enumerates
  candidates for the user to pick.
- **C1 — discovered = metadata-only, type-enforced.** A `Discovered` entry carries **no capture capability**
  (cannot call `capture-pane`); liveness for unadopted windows is PID/`pane_dead` only, never screen capture.
- **C2 — Release retention.** Release is a tmux-marker op; captured transcript/`session.json` **persist** by
  default, with an explicit option to **purge/redact** the transcript of an *adopted* harness on release.
- **C3 — input hygiene.** Send content via `send-keys -l -- <literal>` (literal; `Enter` as a separate key)
  so adopted-target input can't inject tmux key tokens (`C-c`, etc.). Validate/normalize adopted
  session/window identifiers (reject/`--`-terminate leading-`-` to avoid tmux option-injection). Document
  that **argv-style `P.proc` is the injection defense** (not `ShellQuote`), and must be preserved.
- **C4 — `@pcl_id` is spoofable, not authentic.** It is attacker-writable on a shared server, so it is only
  a re-find hint; **PID-provenance recorded at spawn is the trust signal** for `Spawned` harnesses. On
  `@pcl_id` collision or a marker without matching recorded PIDs → treat as **not ours**, log, never route.

## 9. Phasing

- **Phase 0 — Spike (K5):** validate on tmux 3.5a that `@pcl_id` + shell/harness PID survive rename / move /
  index-renumber / PCL restart, what happens on `tmux kill-server`, and measure `list-windows -a` cost at
  ~50/200 windows. **CRITICAL spike deliverable (Architect N1 / CTO):** confirm the **harness-PID
  derivation through the `env`→`script`→[`sh -c`]→binary wrapper** works on **both macOS (BSD `script`)
  and Linux (util-linux `script`)** — i.e. the `ps`-based subtree walk actually isolates the flavour
  binary's PID and `#{pane_current_command}` is confirmed unreliable. If it doesn't, adopt the
  determinate-process fallback (`exec` the binary / PID sentinel, §3) — this is the load-bearing trust
  anchor, so a failure here forces an identity-model rethink, which the spike must surface cheaply.
  Half-day; retires the substrate risk before the TDD/coverage build.
- **Phase 1 — Registry + identity + reconcile + tmux-gate + minimal Active Tabs.** `HarnessId` + `@pcl_id` +
  shell/harness-PID capture; `TVar` registry; cached-coordinate handles (`mkClaudeCodeHarness` refactor);
  reconcile loop (symmetric diff, resilient, capability-checked); route tmux through the auth seam (§8 B1);
  persist `HarnessId` (additive + dual-write `_tc_window`); **wire `_fe_listTabs` so a spawned harness
  appears in Active Tabs** (K8). Folds in the session-name plan's **session-threading core** (per-harness
  `_he_session`); defers the frontend window-input removal to Phase 2. Delete `extractWindowIdx` name-parsing
  (Architect F5). Backend + the minimal Active-Tabs wiring.
- **Phase 2 — Active Tabs health UX + orphan policy.** Full state→visual mapping (§7), Dismiss/Acknowledge/
  Restart-reserved actions, attach-command surfacing, Recent-Sessions exclusion, orphan retention/grace
  policy (deferred here from Phase 1), drop the frontend window input.
- **Phase 3 — Adopt external tmux.** On-demand discovery, Adopt/Release UX + the typed default-deny gate
  (§8 B2), capture-from-adoption-point (§8 B3). Delivers `pureclaw-jlc`.

Each phase plans separately through the plan-review-gate. Phase 1 leaves no broken intermediate state and is
user-validatable (Active Tabs shows the harness).

## 10. Open questions resolved / remaining

- Q1 identity — **resolved** (UUID + `@pcl_id` hint + shell&harness PID provenance, §3).
- Q2 eviction/orphan grace — **deferred to Phase 2** (detection in Phase 1).
- Q3 source of truth — **tmux is ground truth; registry is a reconciled cache + the PCL-session join.**
- Q4 Active Tabs vs Sessions API — wire the existing `_fe_listTabs`/`TabSnapshot` in Phase 1; revisit a
  richer `/api/harnesses` only if the snapshot proves insufficient.
- Q5 adoption security — **resolved** (typed default-deny gate, headless-deny, capture-from-adoption,
  bounded discovery; §8).
- Q6 concurrency — **resolved: `TVar`/STM** (§4).
- Q7 scope — **resolved:** Phase 1 absorbs the session-threading core only; window-input removal → Phase 2.
- **Remaining for the gate:** (a) exact tmux capability-check fallback behavior when `@pcl_id` unsupported;
  (b) whether the tmux auth seam (§8 B1) is a new gate vs reusing `AuthorizedCommand`; (c) harness-PID
  derivation portability (Linux/macOS process-tree walk).

## 11. Phase 0 spike results (2026-06-01, tmux 3.5a / macOS)

Validated on the real tmux server. Outcome: **core assumptions hold; proceed to Phase 1** with two refinements.

- **E1 `@pcl_id`:** survives window rename and move-across-sessions; always locatable by marker
  (`list-windows -a -F '#{@pcl_id}'`). Confirms the §3 re-find anchor. (tmux-server kill → lost →
  Orphaned, as §3 states.)
- **E2 harness PID:** the `env … script -q /dev/null <binary>` wrapper **exec-collapses** so the pane
  process *is* `script` and the harness binary is its **DIRECT CHILD** (one level), not the feared
  `shell→env→script→sh-c→binary` chain. Derivation = descend from `pane_pid`, match `comm` — simpler than
  §3 assumed (recursive descent still correct/robust, esp. for Linux). `#{pane_current_command}` = `script`,
  **not** the binary — confirms it is unusable as the harness signal.
- **METHOD:** never identify the harness by a global `ps | grep <args>` — it matches unrelated processes
  (it matched this spike's own argv and killed the shell). Always descend from the known `pane_pid`.
- **E3 liveness REFINEMENT (new):** with default `remain-on-exit off`, harness death makes `script` exit and
  the **window disappears** → indistinguishable Orphaned, never observable as `Exited`. **Decision: PureClaw
  must set `remain-on-exit on` on its harness windows** (so a dead harness leaves a `#{pane_dead}=1` pane in
  place → `Exited` is observable, distinct from `Orphaned`=window-gone). Add to Phase 1.
- **E4 sweep cost:** `list-windows -a` (full reconcile format) over 64 windows = **26 ms**. The 2 s cadence
  is negligible even at a few hundred windows.
- **STILL TO VALIDATE IN CI (Linux):** util-linux `script -qc "<cmd>"` interposes a `sh -c` (tree may be
  `script→sh-c→binary`, 2 levels) — the recursive descent handles it, but confirm the binary is isolable and
  that `remain-on-exit` behaves identically. This is the remaining half of the §9 Phase-0 spike deliverable.
