# Plan: Phase 3e: story-merge Invocation

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 3e: story-merge Invocation

Invoke `aimi-cli story-merge` to consolidate all staging files into a single validated tasks.json. story-merge performs DAG validation, `outline:NN` → `US-NNN` remapping, Rule 22 (mock-sync AC routing), Phase 3.1 (Reference Element Inventory), and Phase 4.1 (Coverage Self-Check) as post-merge sweeps.

### Project Path Gate (runs first — before `story-merge`)

Every `.project` value in `RUN_DIR` is sub-agent-authored free text, and Phase 4 hands it to `detect-default-branch --project`, which `cd`s into `$AIMI_ROOT/$PROJECT_PATH`. Validate the whole set **here**, before `story-merge` is invoked: this is the last point at which `RUN_DIR` still exists and nothing has been written. A refusal raised later — in Phase 4 — fires after `story-merge` has already deleted the staging directory, so the run dies with its Pass 2 expansion work destroyed and no way to retry.

Run this gate on every path, split or not. It reads the staging files directly rather than trusting `story-merge`'s output, so it does not depend on the CLI's internals.

```bash
BAD_PROJECTS=0
STAGED_PROJECTS=$(find "$RUN_DIR" -maxdepth 1 -type f -name '*.json' \
  ! -name '*outline*.json' ! -name 'metadata.json' ! -name 'audit-result.json' \
  | sort \
  | while IFS= read -r f; do
      jq -r 'if type == "array" then .[] else . end | .project // empty' "$f"
    done \
  | sort -u)
while IFS= read -r PROJECT_PATH; do
  [ -n "$PROJECT_PATH" ] || continue
  [ "$PROJECT_PATH" = "." ] && continue
  case "$PROJECT_PATH" in
    /*|..|../*|*/..|*/../*)
      echo "Invalid project in staging: $PROJECT_PATH" >&2
      BAD_PROJECTS=1
      continue
      ;;
  esac
  if ! [[ "$PROJECT_PATH" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
    echo "Invalid project in staging: $PROJECT_PATH" >&2
    BAD_PROJECTS=1
  fi
done <<< "$STAGED_PROJECTS"
[ "$BAD_PROJECTS" -eq 0 ] || exit 1
```

The `case` list and the regex are the same two checks `commands/execute.md` applies to `metadata.splitGroup.project` in its Step 0.9 split loop (`execute.md`, Invalid splitGroup.project) — keep them byte-identical so the two sites stay diffable. `"."` is the root group's own routing key and is always allowed; a blank or absent `.project` never reaches the loop.

**On failure:** report every offending value and **STOP**. Do not invoke `story-merge`, do not call `roadmap-set-status`, and do not delete `RUN_DIR` — the staging files are intact and the run is retryable once the offending `project` values are corrected.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
MERGE_RETURN=$($AIMI_CLI story-merge \
  --staging-dir "$RUN_DIR" \
  --output "$TASKS_PATH" \
  [--split full-stack  when implementationScope == "full-stack"] \
  [--phase-aware        when ROADMAP_MODE == true AND implementationScope == "full-stack"] \
  [--feature "$featureSlug"        when ROADMAP_MODE == true AND implementationScope != "full-stack"] \
  [--phase "$SELECTED_PHASE_ID"    when ROADMAP_MODE == true AND implementationScope != "full-stack"] \
  [--agent-mode        when INTERACTIVE_MODE == "agent"] \
  [--foundation <value>  once per foundation outline entry, see Flag rules])
MERGE_EXIT=$?
```

**Capture the stdout — never discard it.** `MERGE_RETURN` is story-merge's **return contract**: the authoritative list of the file(s) it actually wrote. Phase 4 and Phase 4.5 read their file list from this value; they never re-derive output filenames by string-concatenating `$TASKS_PATH`. On the PROJECT axis the surviving projects, their basename slugs, and their order are runtime data computed inside story-merge from the merged stories — Phase 3e cannot know them at call time, so the returned payload is the only correct source. Store `MERGE_RETURN` in working memory alongside `TASKS_PATH`.

**Flag rules:**
- `--split full-stack`: pass when `implementationScope == "full-stack"`. story-merge then picks its split **axis** from the merged array itself (see `plugins/aimi-engineering/CLAUDE.md`'s aimi-cli.sh Story Lifecycle Subcommands section) by counting distinct normalized `.project` values: **2 or more → PROJECT axis**, one output file per project (N files, no frontend/backend decision at all); **fewer than 2 → SIDE axis**, the unchanged two-file `*-frontend-tasks.json` / `*-backend-tasks.json` writer for single-repo and monorepo layouts. Which axis ran is not knowable before the call — read it off `MERGE_RETURN` (see the return contract below).
- `--phase-aware`: pass when **both** `ROADMAP_MODE == true` and `implementationScope == "full-stack"` — the composed phase+split case (see outline 13). `$TASKS_PATH` in that case already ends in `-tasks.json` (the phase-scoped form derived above), so story-merge strips the trailing `-tasks` segment once before appending its per-file suffix, keeping a single `tasks` segment in each split basename (`-frontend-tasks.json`/`-backend-tasks.json` on the SIDE axis, `-<project-slug>-tasks.json` on the PROJECT axis). The strip is pure basename manipulation, independent of the axis, so it composes at any N. Never pass this flag when `--split full-stack` is absent, or when `ROADMAP_MODE == false` (flat full-stack split keeps its existing double-`tasks` basename unchanged).
- `--feature <slug>` / `--phase <id>`: pass **both or neither**, and only when `ROADMAP_MODE == true` **and** `implementationScope != "full-stack"` — story-merge refuses half a pair. `<slug>` is `$featureSlug`, `<id>` is the **raw** `SELECTED_PHASE_ID`, never the dot-slugified `SELECTED_PHASE_ID_SLUG`: the raw id names the phase's own tasks file on disk and matches `roadmap.json`'s numeric id, and only branch names slugify the dot (Phase 4's `- **branchName**` bullet is where that rule is stated in full). **What the pair buys:** story-merge derives `metadata.roadmapPath`, `metadata.phase` (`{id, dir}`, with `dir` taken verbatim off the selected phase's own roadmap entry), `metadata.baseRef` and `metadata.pluginVersion` itself, so those four **arrive pre-filled in Phase 4** and are verified there rather than composed there — see Phase 4's `### Derive and Patch Metadata Fields`, which reads the same split from the other side. **What it does not buy:** `metadata.branchName` stays fully authored in Phase 4, because its prefix is `metadata.type` and this command does not decide `type` until Phase 4 — after this call — so Phase 3e has no branch name to hand over; `title`, `type`, `issues`, `finalize`, `decisions` and `researchPaths` stay authored there too. **Never together with `--split full-stack`**: story-merge refuses that combination, because a split run's `branchName` and `baseRef` resolve per repository and it cannot answer them for N repositories at once. That refusal covers the composed phase+split case — `ROADMAP_MODE == true` with `implementationScope == "full-stack"`, the one case `--phase-aware` above is passed FOR — so read the two lines together rather than as a contradiction: there the pair is not passed at all, and all four fields stay hand-patched in Phase 4 exactly as today.
- `--agent-mode`: pass when `INTERACTIVE_MODE == "agent"`. Demotes Phase 3.1 and Phase 4.1 hard blocks to warnings inside story-merge.
- `--foundation <value>`: **repeatable — one occurrence per outline entry whose own `foundationEntry` field is `true`, in outline order.** Let `M` be the number of such entries in the approved outline (Phase 3b's Foundation-first rule, as Phase 3c's carve-out left it). When `M` is 0, omit the flag entirely — unchanged from today's not-accepted case. Read each `<idx>` off the entry's own `idx` field rather than assuming it: the foundation entries occupy `"01"`…`"0M"` because Phase 3b puts them first and Phase 3c pins them there, but the value passed is the entry's own index.
  - **`M == 1` — a single bare occurrence, `--foundation <idx>`.** A sole bare value is valid **whatever project it resolves to**, root or not: story-merge exempts a lone bare value from the project checksum by definition. This is the byte-for-byte flag a single-repo run has always emitted, and it stays correct for the one accepted repository of a multi-repo layout too.
  - **`M >= 2` — one qualified occurrence each, `--foundation <project>:<idx>`,** repeated in outline order, where `<project>` is that entry's own `foundationProject`. Two or more bare values are refused before any index is resolved: with two bare indices nothing says which repository each one is for. Never mix the forms — a bare value alongside any other occurrence is the same refusal.
  - **The qualifier is a checksum, not a second source of truth.** story-merge always routes injection from the resolved story's own `.project`, and compares the stated `<project>` against it, aborting the merge on a mismatch. That comparison is the one thing in the pipeline that catches this command's per-project bookkeeping disagreeing with what a staging file actually says — which is why the per-entry `project` line in the Phase 3d spawn template above must carry the same routing key this flag states.
  - **Injection is per project group.** Each named foundation gains an edge from every other story sharing its own normalized `.project`, never from a story in another repository; a group no value names simply receives no injected edge, a normal and silent outcome whether it has no foundation story or its own Foundation Gate resolved Skip. story-merge aborts before any write if a named foundation story's own `dependsOn` is non-empty, or if two values resolve into the same project group.
  - The flag and its grammar belong to `story-merge` (outline entry 03 of this feature — see `plugins/aimi-engineering/CLAUDE.md`'s aimi-cli.sh Story Lifecycle Subcommands section); `aimi-cli.sh` shape-checks each value against `^([a-zA-Z0-9][a-zA-Z0-9/_.@-]*:)?[0-9]{2}$` and forwards one `--foundation` argument per collected value, in the order given.
- `--split legacy` (default): no flag needed; story-merge uses legacy mode when `--split` is omitted.

On **success**: story-merge writes the output file(s), deletes `RUN_DIR`, exits 0, and prints one JSON object or array on stdout — captured above as `MERGE_RETURN`.

### Return Contract (`MERGE_RETURN`)

Three shapes, discriminated by JSON type and (for objects) by which keys are present:

| Case | Shape | Meaning |
|------|-------|---------|
| Legacy (no `--split`) | `{merged, stories}` | `merged` is the single written path; `stories` is its story count. |
| `--split full-stack`, **SIDE axis** (fewer than 2 distinct `.project` values) | `{frontend, backend, frontend_stories, backend_stories}` | `frontend`/`backend` are the two written paths — unchanged from today. |
| `--split full-stack`, **PROJECT axis** (2 or more distinct `.project` values) | `[{path, project, branchName, storyCount}, ...]` | One element per written file, in the same lexicographic-by-project order story-merge assigned its `US-NNN` blocks. `branchName` is story-merge's placeholder (`feat/merged-<slug>`), overwritten in Phase 4. This axis returns **always the placeholder** — including on a run that named `--feature` and `--phase`, because the CLI refuses that pair together with `--split full-stack`, so no derived name can reach this axis by construction. |

Derive the axis and the file list once, and reuse both in Phase 4 and Phase 4.5:

```bash
SPLIT_AXIS=$(printf '%s' "$MERGE_RETURN" | jq -r 'if type == "array" then "project" elif has("frontend") then "side" else "legacy" end')
SPLIT_FILES=$(printf '%s' "$MERGE_RETURN" | jq -r 'if type == "array" then .[].path elif has("frontend") then .frontend, .backend else .merged end')
```

`SPLIT_FILES` is a newline-separated list of every file story-merge wrote — exactly 1 on the legacy path, exactly 2 on the SIDE axis, N on the PROJECT axis. Every downstream per-file step iterates this list; none of them reconstructs a filename from `$TASKS_PATH`.

Each PROJECT-axis file also carries a self-describing marker written by story-merge itself: `metadata.splitGroup` = `{project, index, total, siblings[]}` — its own project routing key, its 1-based position, the total file count, and every sibling file's path. `/aimi:execute` Step 0.9 reads `metadata.splitGroup.project` to root each split's worktree/container at the right repo, so Phase 4 must preserve it verbatim (see Phase 4 below). SIDE-axis and legacy files have no `splitGroup` key.

**When `ROADMAP_MODE=true`, immediately after confirming story-merge's exit 0** (never before — a failed expansion must leave the phase's roadmap status unchanged):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$featureSlug" --phase "$SELECTED_PHASE_ID" --status planned
```

`pending → planned` is an allowed transition; this call only ever runs once story-merge has already succeeded, so a story-merge failure (see below) never reaches this line and the phase's roadmap status stays `pending` for the next `/aimi:plan` (or `/aimi:plan --phase [SELECTED_PHASE_ID]`) retry.

Proceed to Phase 4.

On **failure** (non-zero exit): do NOT proceed, and do NOT call `roadmap-set-status`. Surface the error to the user. The staging directory is preserved for inspection. Do not attempt to write tasks.json manually.
