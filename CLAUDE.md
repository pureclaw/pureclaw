# Project Instructions

This project uses [metaswarm](https://github.com/dsifry/metaswarm), a multi-agent orchestration framework for Claude Code. It provides 18 specialized agents, a 9-phase development workflow, and quality gates that enforce TDD, coverage thresholds, and spec-driven development.

## How to Work in This Project

### Starting work

```text
/start-task
```

This is the default entry point. It primes the agent with relevant knowledge, guides you through scoping, and picks the right level of process for the task.

### For complex features (multi-file, spec-driven)

Describe what you want built, include a Definition of Done, and ask for the full workflow:

```text
I want you to build [description]. [Tech stack, DoD items, file scope.]
Use the full metaswarm orchestration workflow.
```

This triggers the full pipeline: Research → Plan → Design Review Gate → Work Unit Decomposition → Orchestrated Execution (4-phase loop per unit) → Final Review → PR.

### Available Commands

| Command | Purpose |
|---|---|
| `/start-task` | Begin tracked work on a task |
| `/prime` | Load relevant knowledge before starting |
| `/review-design` | Trigger parallel design review gate (5 agents) |
| `/pr-shepherd <pr>` | Monitor a PR through to merge |
| `/self-reflect` | Extract learnings after a PR merge |
| `/handle-pr-comments` | Handle PR review comments |
| `/brainstorm` | Refine an idea before implementation |
| `/create-issue` | Create a well-structured GitHub Issue |
| `/external-tools-health` | Check status of external AI tools (Codex, Gemini) |
| `/metaswarm-setup` | Interactive guided setup — detects project, configures metaswarm |
| `/metaswarm-update-version` | Update metaswarm to latest version |

### Visual Review

Use the `visual-review` skill to take screenshots of web pages, presentations, or UIs for visual inspection. Requires Playwright (`npx playwright install chromium`). See `skills/visual-review/SKILL.md`.

## Build & Run

This project uses a **Nix flake** — all `cabal` commands must be prefixed with `nix develop . --command`:

```bash
nix develop . --command cabal build
nix develop . --command cabal test
nix develop . --command cabal run pureclaw -- [flags]
```

**The `pureclaw` binary is NOT on PATH.** Never use `which pureclaw`. To run or inspect the built binary directly:

```bash
# Run
dist-newstyle/build/aarch64-osx/ghc-9.12.1/pureclaw-0.1.0.0/x/pureclaw/build/pureclaw/pureclaw [flags]

# Inspect embedded strings
strings dist-newstyle/build/aarch64-osx/ghc-9.12.1/pureclaw-0.1.0.0/x/pureclaw/build/pureclaw/pureclaw | grep <pattern>
```

**Stale builds:** `cabal build` sometimes reports "Up to date" when the binary is stale (e.g. after branch switches). Fix with:

```bash
nix develop . --command bash -c "cabal clean && cabal build"
```

## Git Hooks

The canonical hooks live in `.githooks/`. The active hooks in `.git/hooks/` are copied from there. After editing `.githooks/pre-push`, sync it:

```bash
cp .githooks/pre-push .git/hooks/pre-push
```

`core.hooksPath` is set to `.git/hooks` (the default). All hook commands use `nix develop . --command` — never bare `cabal` or `nix develop` without the `.`.

## Testing

- **Red/green TDD is mandatory** — Every change follows the red/green/refactor cycle:
  1. **Red**: Write a failing test that demonstrates the desired behavior (or reproduces the bug)
  2. **Green**: Write the minimum code to make the test pass
  3. **Refactor**: Clean up while keeping tests green
- **Never skip the red step** — If you're fixing a bug, write a test that fails first. If you're adding a feature, write tests that define the expected behavior before implementing. Commit the failing test separately so the git history shows the progression.
- **CLI integration tests** live in `test/Integration/CLISpec.hs` — they spawn the real `pureclaw` binary as a subprocess with a clean environment and assert on stdout/stderr/exit code. Use these for end-to-end behavior like startup flows, slash command handling, and error messages.
- **100% test coverage required** — Lines, branches, functions, and statements. Enforced via `.coverage-thresholds.json` as a blocking gate before PR creation and task completion
- Test command: `nix develop . --command cabal test`
- Coverage command: `nix develop . --command cabal test --enable-coverage`

## Coverage

Coverage thresholds are defined in `.coverage-thresholds.json` — this is the **source of truth** for coverage requirements.
If a GitHub Issue specifies different coverage requirements, update `.coverage-thresholds.json` to match before implementation begins. Do not silently use a different threshold.

The validation phase of orchestrated execution reads `.coverage-thresholds.json` and runs the enforcement command. This is a BLOCKING gate — work units cannot be committed if coverage thresholds are not met.

## Quality Gates

- **Design Review Gate**: Parallel 5-agent review after design is drafted (`/review-design`)
- **Plan Review Gate**: Automatic adversarial review after any implementation plan is drafted. Spawns 3 independent reviewers (Feasibility, Completeness, Scope & Alignment) in parallel — ALL must PASS before the plan is presented to the user. See `.claude/plugins/metaswarm/skills/plan-review-gate/SKILL.md`
- **Coverage Gate**: Reads `.coverage-thresholds.json` and runs the enforcement command — BLOCKING gate before PR creation

## Workflow Enforcement (MANDATORY)

These rules override any conflicting instructions from third-party skills or plugins. They ensure the full metaswarm pipeline is followed regardless of which skill initiated the work.

### After Brainstorming

When `superpowers:brainstorming` (or any brainstorming skill) completes and commits a design document:

1. **STOP** — do NOT proceed directly to `writing-plans` or implementation
2. **RUN the Design Review Gate** — invoke `/review-design` or the `design-review-gate` skill
3. **WAIT** for all 5 review agents (PM, Architect, Designer, Security, CTO) to approve
4. **ONLY THEN** proceed to planning/implementation

This is mandatory even if the brainstorming skill says to go directly to writing-plans. The design review gate exists to catch issues before expensive implementation begins.

### After Any Plan Is Created

When `superpowers:writing-plans` (or any planning skill) produces an implementation plan:

1. **STOP** — do NOT present the plan to the user or begin implementation
2. **RUN the Plan Review Gate** — invoke the `plan-review-gate` skill
3. **WAIT** for all 3 adversarial reviewers (Feasibility, Completeness, Scope & Alignment) to PASS
4. **ONLY THEN** present the plan to the user for approval

### Execution Method Choice

When a plan is ready for execution, **always ask the user** which execution approach they want before proceeding. Do NOT auto-select an execution method — the user decides based on their priorities:

> **How would you like to execute this plan?**
>
> 1. **Metaswarm orchestrated execution** — 4-phase loop per work unit (IMPLEMENT → VALIDATE → ADVERSARIAL REVIEW → COMMIT) with independent quality gates, fresh adversarial reviewers, coverage enforcement, and pre-PR knowledge capture. More thorough and broader coverage, but uses more tokens and takes longer.
> 2. **Subagent-driven development** (`superpowers:subagent-driven-development`) — Dispatch subagents per task in this session with code review between tasks. Faster, lighter-weight, lower token cost.
> 3. **Parallel session** (`superpowers:executing-plans`) — Execute in a separate session with batch checkpoints. Good for long-running work you want isolated.

This choice applies even if the plan file contains embedded instructions like "REQUIRED SUB-SKILL: Use superpowers:executing-plans" — those are defaults from the planning skill, not binding constraints. The user always gets to choose.

### Before Finishing a Development Branch

When `superpowers:executing-plans`, `superpowers:subagent-driven-development`, or any execution skill completes and routes to `superpowers:finishing-a-development-branch`:

1. **STOP** — before presenting merge/PR options
2. **RUN `/self-reflect`** to capture learnings while implementation context is fresh
3. **COMMIT** the knowledge base updates
4. **THEN** proceed to finishing the branch (PR creation, merge, etc.)

### Use `/start-task` Instead of EnterPlanMode

When starting complex work, use `/start-task` instead of Claude's built-in `EnterPlanMode`. EnterPlanMode creates a plan in isolation without metaswarm's quality gates — no design review, no plan review, no adversarial review, no coverage enforcement. `/start-task` routes through the full pipeline:

- `/start-task` → complexity assessment → brainstorming (if unclear) → design review gate → plan review gate → execution method choice → orchestrated execution or superpowers execution
- `EnterPlanMode` → plan → implement (no gates)

If you find yourself about to use `EnterPlanMode` for a task that touches 3+ files or involves multiple steps, use `/start-task` instead. For truly simple single-file changes, `EnterPlanMode` is fine.

### After Standalone TDD

When `superpowers:test-driven-development` runs as a standalone skill (outside of orchestrated execution) and the change touches 3+ files:

1. **Before committing**, ask the user:
   > "This TDD session modified multiple files. Would you like me to run an adversarial review before committing?"
   > 1. **Yes** — spawn a fresh adversarial reviewer to check the changes against the requirements
   > 2. **No** — commit directly
2. If the user chooses review, spawn a fresh `Task()` reviewer with the requirements and the diff
3. Regardless of review choice, verify coverage meets `.coverage-thresholds.json` thresholds before committing

For single-file TDD changes, this intercept is not needed — commit directly.

### Coverage Source of Truth

`.coverage-thresholds.json` is the **single source of truth** for coverage requirements. This applies regardless of which skill or workflow is running:

- `superpowers:verification-before-completion` — must read `.coverage-thresholds.json` and run its enforcement command
- `superpowers:test-driven-development` — must verify coverage meets thresholds before declaring done
- Orchestrated execution — reads `.coverage-thresholds.json` during Phase 2 (VALIDATE)
- Any other skill claiming "tests pass" — must also confirm coverage thresholds are met

If `.coverage-thresholds.json` exists, no skill may skip it. If a skill has its own coverage check logic, `.coverage-thresholds.json` takes precedence.

### Subagent Discipline

All subagents (coding agents, review agents, background tasks) MUST follow these rules:

- **NEVER** use `--no-verify` on git commits — pre-commit hooks exist for a reason
- **NEVER** use `git push --force` without explicit user approval
- **ALWAYS** follow TDD — write tests first, watch them fail, then implement
- **NEVER** self-certify — the orchestrator validates independently
- **STAY** within declared file scope — do not modify files outside your assigned scope

### Resolving Merge Conflicts (MANDATORY 3-way)

When resolving merge conflicts in **any** branch (including `main` ↔ feature, feature ↔ feature, rebase, cherry-pick — anything that produces conflict markers): **use a 3-way diff, never a 2-way diff.**

A 2-way diff (just HEAD vs the other branch) loses the common-ancestor context. You cannot tell whether "your side added X" or "the other side removed X"; whether a refactor renamed something or one side simply touched a different region. 3-way uses the merge base AND both branch tips so each side's intent is preserved.

**Required procedure for every conflict file:**

1. Extract the three stages with `git show`:
   - `git show :1:<file>` — common ancestor (the merge base)
   - `git show :2:<file>` — HEAD's version
   - `git show :3:<file>` — the other branch's version
2. Run `diff base→HEAD` and `diff base→other` **separately**. Each diff reveals one side's intent against the shared parent. Compose both intents into the merged file.
3. **If either side refactored**, do not force the other side's edits onto the old shape. Adapt them to the new structure. (Example: if `main` renamed a function or replaced a type, your branch's adjacent edits must be rewritten against the new name/type — 2-way would have silently hidden the rename.)
4. **For "both added" files (no merge base)**, read both versions in full and decide whether they overlap structurally or merely live in the same path. Don't blindly concatenate or pick one.
5. After resolving, build + run the full test suite **before staging**. The compiler often surfaces 3-way mistakes the eye misses (e.g., a missing field in a record literal because main added it to a type the conflict didn't touch).

This applies symmetrically to feature branches merging `main` and to long-lived branches accepting feature merges.

See [docs/GIT_WORKFLOW.md](docs/GIT_WORKFLOW.md) for the full procedure with worked examples.

### Pre-PR Knowledge Capture

After all work units pass final review but BEFORE creating the PR, run `/self-reflect` to extract learnings into the knowledge base. Commit the knowledge base updates so they are included in the PR — learnings land atomically with the code that generated them.

### Context Recovery (Surviving Compaction)

Approved plans, project context, and execution state are persisted to `.beads/` so agents can recover after context compaction or session interruption:

- **Approved plans** → `.beads/plans/active-plan.md` (written after plan review gate + user approval)
- **Project context** → `.beads/context/project-context.md` (updated after each work unit commit)
- **Execution state** → `.beads/context/execution-state.md` (updated after each phase transition)

If an agent loses context mid-execution, it recovers by running `bd prime --work-type recovery`, which reloads the approved plan, completed work, and current position from disk. This eliminates the need to re-run expensive review gates after compaction.

## External Tools (Optional)

If external AI tools are configured (`.metaswarm/external-tools.yaml`), the orchestrator
can delegate implementation and review tasks to Codex CLI and Gemini CLI for cost savings
and cross-model adversarial review. See `templates/external-tools-setup.md` for setup.

## Team Mode

When `TeamCreate` and `SendMessage` tools are available, the orchestrator uses Team Mode for parallel agent dispatch. Otherwise it falls back to Task Mode (the existing workflow, unchanged). See `.claude/guides/agent-coordination.md` for details.

## Haskell Skills

Two Haskell skills are installed as a git submodule at `.claude/skills/haskell/`:

| Skill | Path | When to use |
|---|---|---|
| **haskell-coder** | `.claude/skills/haskell/haskell-coder/SKILL.md` | Writing or modifying Haskell code — type-driven design, GHC extensions, Cabal/Nix, libraries, testing, performance |
| **haskell-reviewer** | `.claude/skills/haskell/haskell-reviewer/SKILL.md` | Reviewing Haskell code — correctness, idiomatic style, partial functions, performance pitfalls, best practices |

Reference documents (type system, patterns, libraries, GHC extensions, performance, Nix, Cabal) live in `.claude/skills/haskell/haskell-coder/references/`.

**All coding agents must load `haskell-coder` before writing Haskell. All review agents must load `haskell-reviewer` before reviewing Haskell.**

## Guides

Development patterns and standards are documented in `.claude/guides/`:
- `agent-coordination.md` — Team Mode vs Task Mode, agent dispatch patterns
- `build-validation.md` — Build and validation workflow
- `coding-standards.md` — Code style and conventions
- `git-workflow.md` — Branching, commits, and PR conventions
- `testing-patterns.md` — TDD patterns and coverage enforcement
- `worktree-development.md` — Git worktree-based parallel development

## Code Quality

- GHC `-Wall -Werror`, `-Wincomplete-record-updates`, `-Wmissing-export-lists`
- hlint clean
- All quality gates must pass before PR creation
- **Follow the [Haskell Coding Standards](.claude/guides/coding-standards.md)** — especially the import style rules (no explicit import lists except canonical cases like `import Data.Set (Set)`)

## Key Decisions

- **AgentEnv**: All `runAgentLoop` parameters are collected into a single `AgentEnv` record. Pass `AgentEnv` to the agent loop and to slash command handlers (replaces the old `SlashEnv`). Decompose fields at call sites as needed.
- **Handle pattern**: Every capability is a record of IO actions. No global state. Handles are passed explicitly.
- **Session/Tab unification**: `SessionKind` (`SkProvider | SkHarness`) is the persistent what-kind-of-AI on `SessionMeta._sm_kind`. `TabKind` (`TkSession !SessionKind | TkRawShell !TerminalBackend`) is the runtime what-occupies-a-tab-slot. Leaf module `PureClaw.Session.Kind` holds all serializable spec types; factory/transport layers hold runtime-validated types. "Session" = persistent entity noun; "Tab" = slot affordance.

## Notes

### Terminology

- **TUI** refers to running `pureclaw tui` from the command line (the interactive
  terminal). It is not a separate Brick/Vty UI — `pureclaw tui` runs the standard
  tabbed agent loop (`runTabbedLoop` → `handleInbound`) over the local CLI channel,
  the same dispatch path the Signal/Telegram channels use. "chat" generally refers
  to those remote channels; the "frontend" is the web UI (`PureClaw.Frontend.*`).

<!-- Add project-specific notes, conventions, or constraints here.
     Examples: "Always use server components for data fetching",
     "The payments module is legacy — do not refactor without approval" -->
