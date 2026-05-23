# Git Workflow

Conventions for branching, commits, PRs, and merging on the PureClaw repository.

The 3-way merge rule in §"Resolving Merge Conflicts" below is **mandatory** and is also stated in [`CLAUDE.md`](../CLAUDE.md) under "Workflow Enforcement (MANDATORY) → Resolving Merge Conflicts (MANDATORY 3-way)". This document is the authoritative procedure with worked examples.

## Branching

- Feature branches: `feat/<short-slug>` cut from `main`.
- Bugfix branches: `fix/<short-slug>` cut from `main`.
- Long-lived release branches (if any): `release/<version>` cut from `main`.

## Commit cadence

- One commit per logical change. Within a TDD red-then-green pair, keep both commits.
- Commit messages follow `<type>: <description> (#<issue>)` — types include `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `WU<n>:` for work-unit checkpoints inside an orchestrated execution flow.
- End each commit message with the `Co-Authored-By:` trailer documented in the session-start hook when authored via an agent session.

## Pre-push

The pre-push hook runs the test suite under `nix develop . --command cabal test` plus hlint. Do not bypass it (`--no-verify` is forbidden in `CLAUDE.md`).

## Pushing & PRs

- Push the branch with `-u origin <branch>` on the first push.
- Open draft PRs for in-progress work; flip to ready-for-review only after the pre-PR `/self-reflect` step has captured learnings.
- Never force-push to `main` (or any branch with a published PR) without explicit user approval.

---

## Resolving Merge Conflicts (MANDATORY 3-way)

### The rule

**Every conflict resolution in this repo uses 3-way diffs, never 2-way.**

A 2-way diff shows you HEAD vs the other branch. A 3-way diff also shows you the merge base. The base is what lets you tell "main added X" apart from "HEAD removed X" — and from "HEAD refactored X into Y" apart from "main moved X to a new location". Without the base, you are reasoning from end-states alone; with it, you are reasoning from each side's intent against a shared starting point.

### Why this matters

The risk profile of 2-way merging:

- **Refactor blindness.** If `main` renamed `foo` to `bar` and your branch added a call to `foo`, a 2-way merge will look like "your branch has `foo`, main has `bar`" and you might pick one or the other. 3-way reveals that main applied a refactor — so your `foo` call must become a `bar` call.
- **Adjacent-region confusion.** When both sides modified the same file at near-overlapping lines, 2-way merge tools highlight a single block. 3-way separately shows what each side added to the base, making it clear which lines compose vs which conflict.
- **Type/signature changes.** If one side changes a function signature or a record field set, downstream call sites and constructors need updates that aren't visible until you build. 3-way prompts you to look for those because you can see the signature change as a discrete edit against the base.

### The procedure

For every conflicted file (any file that `git status` reports as `UU` or `AA`):

#### 1. Extract the three stages

`git` keeps all three versions accessible during a merge. Use:

```bash
git show :1:<file>   # the merge base (common ancestor)
git show :2:<file>   # HEAD's version (your branch's tip)
git show :3:<file>   # MERGE_HEAD's version (the other branch's tip)
```

A quick helper:

```bash
for s in 1 2 3; do
  git show :$s:path/to/conflict.hs > /tmp/c-s$s
done
```

If `git show :1:<file>` fails ("path is unmerged"), the file is **both-added** (no common base); see §"Both-added files" below.

#### 2. Run two separate diffs

```bash
diff /tmp/c-s1 /tmp/c-s2   # base → HEAD : what your branch changed
diff /tmp/c-s1 /tmp/c-s3   # base → main : what the other branch changed
```

Each diff is a story of one side's intent. The merged file should reflect both.

#### 3. Reason about overlap

- **No overlap.** Both sides added lines in different regions. Trivial merge: include both.
- **Both added (overlapping)** — both sides added related code at the same site. Compose: read both contributions, decide if they're complementary (combine), redundant (pick the better-named version), or genuinely incompatible (escalate to the user).
- **One side refactored what the other side touched.** This is the case 2-way misses most often. Read the refactor (base → main say), then re-apply HEAD's edit on top of the refactored shape — do not preserve the pre-refactor form.

#### 4. Refactor adaptation

If `git show :3:<file>` reveals a structural change — function rename, signature change, type replacement, file move — your branch's edits must adapt to the new shape:

- **Function rename:** rewrite your branch's call sites against the new name.
- **Signature change:** thread the new parameter through your branch's call sites (the compiler will tell you which sites you missed).
- **Type replacement** (e.g., `RuntimeType` → `SessionKind`): rewrite your branch's constructors against the new type. Also update any record literals — even ones outside the conflict marker — because the field set may have changed.
- **File move:** decide whether your branch's edit logically belongs at the new location or the old one (it may need to be ported entirely).

#### 5. Both-added files

When `git show :1:<file>` reports "unmerged" — typical when both branches independently created a file at the same path — apply the same discipline to the structure inside:

- Read `git show :2:<file>` and `git show :3:<file>` end-to-end.
- Decide: do they overlap structurally (same module, same test target) or merely share a path?
- If structural overlap: pick one canonical version (usually the more complete one), then layer the other's unique additions in.
- If they're independently valid: rename one (or both) and update consumers.

#### 6. Compile + run before staging

After resolving every conflict in a file:

```bash
nix develop . --command cabal build all
nix develop . --command cabal test
```

The compiler catches 3-way mistakes the eye misses — missing record fields after a type refactor, broken imports after a module move, unused imports after a downstream edit was dropped. **Do not `git add` a resolved file until the build and the relevant tests pass.**

#### 7. Commit the merge with a methodology note

The merge commit body should:

- List the non-trivial conflicts and how they were resolved (one bullet per file).
- Name any refactors on one side that drove resolution choices.
- Document any test/build adaptations the merge required (e.g., new test fixtures, new field initializers).
- State that 3-way diffs were used.

---

## Worked example: the merge that prompted this guide

During PR #57 (live transcript streaming), `main` picked up the Session/Tab Unification work mid-flight. The merge had 11 conflicted files. A 2-way pass through the first few worked by luck — `package.json`, `vitest.config.ts`, the App.tsx imports were all "main added X, HEAD added Y, take both". The risky files were the ones where main refactored adjacent surfaces:

- **`Sidebar.tsx`**: 2-way showed HEAD's `SessionRow` with `displayName = session.agent ?? session.id` and main's `SessionRow` with `displayName = sessionDisplayTitle(session)`. A 2-way pick would have lost the `sessionDisplayTitle` helper main introduced. 3-way revealed main as a refactor; the merged file uses `sessionDisplayTitle(session)` and `activity?.lastEntryAt ?? session.lastActive` together.
- **`Session.Types`**: main replaced `RuntimeType`/`RTProvider` with `SessionKind`/`SkProvider (ProviderSpec ...)` and added three new fields (`_sm_archived`, `_sm_description`, `_sm_autoSummary`). HEAD had test fixtures still using `RuntimeType`. 2-way only flagged the import-line conflict; 3-way revealed that **every `SessionMeta` constructor on HEAD's side needed updating**, including in test files outside the conflict marker. The compiler caught one I missed — invaluable feedback.
- **`Frontend/API.hs`**: main deprecated `POST /api/sessions/new` to 410 Gone and introduced `POST /api/tabs/new`. HEAD had a `D18` test that published `SaSessionCreated` from the old endpoint. The 3-way-correct resolution moved HEAD's broker-publish into main's `handleNewTab` (TkSession branch) — the new home for session creation. The test was rewritten to POST to `/api/tabs/new` with a `TkSession {provider}` body.
- **`test/Frontend/APISpec.hs`** ("both added"): two branches independently created an APISpec. HEAD's tested the legacy endpoints; main's tested the new tab endpoints. Main's was kept wholesale because the legacy endpoints either changed shape (`GET /api/sessions/recent` now filters by active-tab) or were deprecated (`POST /api/sessions/new` → 410). HEAD's tests against the deprecated endpoints would have failed.

The merge commit (`ce12553`) documents each of these resolutions with file-level reasoning.

---

## Tooling

- **Difftools.** `git mergetool` with a 3-way-capable tool (kdiff3, opendiff, p4merge, vimdiff with `:diffsplit` × 3) automates step 1-2. Per-file, command-line `git show :1: / :2: / :3:` works fine and is what most agents will use.
- **`git rerere`.** If you anticipate repeated merges of the same long-lived branch into many feature branches, enabling `git config rerere.enabled true` lets git replay your resolution for identical future conflicts. Use sparingly — it's easy to record a bad resolution.
- **Conflict markers.** The standard `<<<<<<<` / `=======` / `>>>>>>>` markers are useful for *locating* the conflict but are 2-way by construction. Use `git show :1:<file>` for the base before reasoning about the resolution.

## Anti-patterns

- **Accepting `main` wholesale.** "Just take main's version" loses your branch's intent. Even for files where main heavily restructured, your branch's additions usually compose.
- **Accepting HEAD wholesale.** Symmetric mistake: discards refactors and bug-fixes from main.
- **Resolving by eye from the conflict markers.** The markers are 2-way visualization. Without `git show :1:<file>`, you cannot see the merge base.
- **Skipping the build step.** A resolved file that "looks right" can have missing record fields, wrong call signatures, dead imports. Build before staging.
- **Force-pushing after a merge to avoid conflict commits.** Don't rewrite history on a branch with an open PR; create a new commit instead.
