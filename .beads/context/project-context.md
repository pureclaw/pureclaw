# Project Context (Orchestrator-maintained) — pureclaw-3oy: Harness Registry Phase 1

Last updated: 2026-06-01 (orchestration start)

Epic: **pureclaw-3oy**. Branch: **feat/harness-registry-p1**. Plan: `.beads/plans/harness-registry-phase1-plan.md`. Design: `docs/harness-registry.md`.

## Tooling (Haskell / Nix flake)
- **All** cabal/hlint commands MUST be prefixed: `nix develop . --command <...>`
- Build / typecheck: `nix develop . --command cabal build` (GHC 9.12.1, GHC2021, `-Wall -Werror`, `-Wincomplete-record-updates`, `-Wmissing-export-lists`)
- Lint: `nix develop . --command hlint src/ test/ app/` (must be clean)
- Test: `nix develop . --command cabal test` — HSpec via **hand-rolled `test/Main.hs`** (NOT hspec-discover).
  **New spec modules MUST be registered in BOTH `test/Main.hs` AND the `pureclaw.cabal` test stanza** (`other-modules`).
- Coverage: `nix develop . --command cabal test --enable-coverage` — **95%** (lines/branches/functions/statements) per `.coverage-thresholds.json` (source of truth, NOT 100%). Staged-waiver mechanism exists but new Phase-1 code is fully exercisable (no waiver expected).
- PTY firewall (pre-push): `bash scripts/check-pty-firewall.sh`
- Stale build fix: `nix develop . --command bash -c "cabal clean && cabal build"`
- Binary: `dist-newstyle/build/aarch64-osx/ghc-9.12.1/pureclaw-0.1.0.0/x/pureclaw/build/pureclaw/pureclaw`

## Conventions
- Import style: `qualified as` (no explicit import lists except canonical `import Data.Set (Set)`)
- Handle pattern (records of IO actions, field prefix `_handleName_*`); no effect systems; `ReaderT AppEnv IO` + explicit handles
- Security types: smart constructors, value constructors NOT exported (`SafePath`, `AuthorizedCommand`, `ApiKey`)
- `IORef` unless `TVar`/`MVar` is required for concurrency (registry IS a `TVar` per design)
- New record fields must be added at ALL construction sites (`-Werror` enforces)
- Hand-written Aeson codec with `.:?`/`.!=` tolerant decode + emit-when-Just (precedent: SessionMeta `_sm_agent`)
- Coding agents load the `haskell` skill (haskell-coder); review agents load haskell-reviewer
- TDD mandatory: failing test first (red), then implement (green), then refactor

## Orchestrator decisions (binding for this execution)
- **D-ADD-1: WU1 is ADDITIVE.** Changing existing Tmux.hs signatures (`captureWindow`,
  `sendToWindow`, `startTmuxSession`, `stopHarnessWindow`, `renameWindow`) would break callers in
  ClaudeCode.hs / ActivityProbe.hs / API.hs / SlashCommands.hs / CLI/Commands.hs, migrated only in
  WU4/WU5. To keep every WU green (`-Wall -Werror`), WU1 ADDS new identity + name-targeting ops
  alongside the existing index-based functions. Existing functions stay until later WUs migrate callers.
  Any dead index-based ops are removed in WU9 cleanup.
- **D-ADD-2: registry is additive** (per plan): new `_env_harnessRegistry`/`_fe_harnessRegistry` fields;
  legacy `_env_harnesses`/`_fe_harnesses :: IORef (Map Text HarnessHandle)` and `_env_nextWindowIdx`
  KEPT and maintained as synced derived views. No legacy consumer logic changes except frontend routing (WU6).
- **D-SCOPE-WU6: WU6 touches ONLY persistence + frontend routing.** The plan's locked additive
  decision (plan lines 38–50, user-chosen) says `Loop.TargetHarness`, `Core.Types`, `/status`/`/target`/`/msg`,
  `Tab/Harness.lookupHarness`, `Session/Handle.resolveResumedTarget` and their tests stay UNCHANGED —
  full legacy cutover is DEFERRED. This overrides the WU6 file-list's mention of `Core/Types.hs`/
  `Agent/Loop.hs`. So WU6 = `Session/Kind.hs` (additive `_h_harnessId`) + `Frontend/API.hs`
  (`harnessKeyFromKind`/`sendToHarness` → id-primary with NAME-fallback + PID-corroboration refusal) + tests.
  The registry is EMPTY until WU4/WU5/WU7 populate it, so frontend id-routing MUST fall back to the
  legacy name-keyed `_fe_harnesses` map — preserving PR #74's working first-prompt routing.

## Work Units (beads ids) — execution order respects the DAG
| WU | beads | Title | Deps |
|----|-------|-------|------|
| WU1 | pureclaw-3oy.1 | Tmux.hs identity ops + name targeting + capability check | — |
| WU2 | pureclaw-3oy.2 | Harness.Registry module (HarnessId/HarnessEntry/TVar) | — |
| WU2b | pureclaw-3oy.3 | _env/_fe_harnessRegistry field (additive, mechanical) | WU2 |
| WU3 | pureclaw-3oy.4 | tmux auth seam (authorizeTmuxCommand) | WU1 |
| WU4 | pureclaw-3oy.5 | ClaudeCode + SlashCommands harness-start: session/id/PIDs | WU1,WU2,WU2b,WU3 |
| WU5 | pureclaw-3oy.6 | Reconcile loop + boot reconstruction | WU1,WU2,WU2b,WU4,WU6 |
| WU6 | pureclaw-3oy.7 | Persistence + routing key migration | WU2,WU2b |
| WU7 | pureclaw-3oy.8 | _fe_startHarness/createTab use registry + _tc_session | WU2b,WU4,WU6 |
| WU8 | pureclaw-3oy.9 | Minimal Active-Tabs slice (user symptom) | WU2,WU2b,WU7 |
| WU9 | pureclaw-3oy.10 | Coverage + integration sweep + dead-code cleanup | WU1..WU8 |

Topological execution: (WU1‖WU2) → (WU2b‖WU3) → (WU6, then WU4) → (WU5‖WU7) → WU8 → WU9.

## Completed Work Units
| WU | Title | Key Files | Notes |
|----|-------|-----------|-------|
| (none yet) | | | |

## Established Patterns (this codebase)
- Hand-written Aeson codec, tolerant `.:?`/`.!=` decode, emit-when-Just (SessionMeta `_sm_agent`).
- Set-once `atomicModifyIORef'` + save-iff-changed (`markBootstrapConsumed`, Session/Handle.hs).
- Flat-string sum encoding (`flavourToText`, Session/Types.hs).
- tmux server-sweep parsing via `tmux ... -F` format strings + tab-split (`listSessionWindows`).
