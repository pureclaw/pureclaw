# WU0 Phase-0 Spike Findings — claude-code JSONL session log

**Issue:** `pureclaw-3oy.33` · **Plan:** `.beads/plans/harness-jsonl-capture-plan.md`
**Date:** 2026-06-04 · empirically verified against the installed `claude` CLI on this machine.

These findings gate WU2 (path derivation) and WU3 (converter). Fixtures captured under
`test/fixtures/claude-jsonl/`.

## D0.1 — file creation (CONFIRMED)

`claude --session-id <uuid> -p "…"` run with cwd `/Users/zoe/pcl-spike-test-a` created exactly:

```
~/.claude/projects/-Users-zoe-pcl-spike-test-a/<uuid>.jsonl   (mode 0600, owner-only)
```

Mode `0600` validates the design's `owner == geteuid()` / no group-other access check (§G).

## D0.3 — cwd → directory-name sanitization (CONFIRMED; rule is NOT `/`→`-`)

Evidence (cwd → actual created project-dir name):

| cwd | naive `/`→`-` | **actual** |
|---|---|---|
| `/Users/zoe/pcl-spike-nest/sub/dir` | `-Users-zoe-pcl-spike-nest-sub-dir` | `-Users-zoe-pcl-spike-nest-sub-dir` |
| `/tmp/pcl-spike-sym` (symlink → `/private/tmp`) | `-tmp-pcl-spike-sym` | **`-private-tmp-pcl-spike-sym`** |
| `/Users/zoe/pcl spike space` | `-Users-zoe-pcl spike space` | **`-Users-zoe-pcl-spike-space`** |
| `/Users/zoe/pcl.spike.dot` | `-Users-zoe-pcl.spike.dot` | **`-Users-zoe-pcl-spike-dot`** |

**Rule:** claude **canonicalizes** the cwd (resolves symlinks: `/tmp` → `/private/tmp`),
then replaces **every non-alphanumeric** character with `-` (space and `.` both become `-`),
not just `/`.

### ⇒ Design refinement (important): locate by uuid-glob, not by reconstructing the name

The sanitization rule is version-fragile (an undocumented claude-code internal). Since PureClaw
**mints a globally-unique `<uuid>`**, the robust derivation for WU2 is:

1. Glob `~/.claude/projects/*/<uuid>.jsonl` (the uuid is unique → at most one hit). Base dir
   from `CLAUDE_CONFIG_DIR` if set, else `~/.claude`.
2. `canonicalizePath` the hit and enforce containment under the canonical `…/projects` root
   (+ `O_NOFOLLOW`, owner check) via `SafeClaudeLogPath`.

This **sidesteps reproducing the fragile sanitize rule entirely** while keeping the security
containment guarantee. WU2's DoD should derive-by-uuid-glob, then validate. (We still persist
the canonical cwd per §B as a sanity cross-check / fallback.)

## D0.2 — resume appends to the same file (CONFIRMED; no fork)

After the initial `--session-id <uuid>` run, `claude --resume <uuid> -p "…"` (same cwd) appended
the new turn to the **same** `<uuid>.jsonl` (the dir still held exactly one `.jsonl`; the file
grew and contained the new turn's text). Resume does **not** fork a new file. So a restarted
PureClaw harness re-launches `claude --resume <uuid>` and re-tails the same path.

## D0.4 — append-only (CONFIRMED across resume; compaction not observed)

The file only grew across the resume (no truncation/rewrite seen). In-place compaction was not
observed in these short tests. The design already degrades gracefully: every view-open backfills
from offset 0, so even if compaction occurs the open-time read is always correct; only the live
byte-offset tail would need a re-read (WU5 D5.5 handles file-shrink/disappear).

## D0.5 — event shapes (CAPTURED → `test/fixtures/claude-jsonl/events.jsonl`)

One JSON object per line; `type` discriminates. Relevant shapes (verified against a real log):

- **user (text):** `{type:"user", uuid, parentUuid, sessionId, timestamp, cwd, message:{role:"user", content:<str | block[]>}}`
- **assistant:** `{type:"assistant", uuid, parentUuid, requestId, timestamp, message:{role:"assistant", model, usage, stop_reason, content:[block…]}}`
  - **text block:** `{type:"text", text}`
  - **thinking block:** `{type:"thinking", thinking, signature}`  ← WU8 data source
  - **tool_use block:** `{type:"tool_use", id, name, input, caller}`
- **tool_result:** a **`user`-type** event whose `message.content[]` holds
  `{type:"tool_result", tool_use_id, content:<str>, is_error}` (also a top-level `toolUseResult`).
- **metadata types to ignore:** `mode`, `permission-mode`, `last-prompt`, `attachment`,
  `file-history-snapshot`, `ai-title`, `system`, `queue-operation`.

### Converter (WU3) mapping consequences

- `assistant` → Response entry: `message.content` → top-level `content`; `message.usage` →
  top-level `usage`; `message.model` → `_te_model` column. (Matches `App.tsx` Response parser.)
- `user` (role user, text/string content) → Request entry: `{messages:[{role:"user", content}]}`.
- `tool_result` user event → Request entry carrying the `tool_result` block in
  `messages[].content[]` (so `App.tsx buildToolResultIndex` joins it by `tool_use_id`).
- `thinking` block → carried through so WU8's new renderer can show it (collapsed).
- unknown `type` / malformed line → `Nothing` (skipped). The fixture includes a metadata line
  and an intentionally-malformed line to exercise this.

## Cleanup

Spike temp cwds and their `~/.claude/projects/-Users-zoe-pcl-spike-*` log dirs are removed after
capture; no spike artifacts remain outside the committed `test/fixtures/`.
