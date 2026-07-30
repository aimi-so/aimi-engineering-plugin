# Validation Checklist

Apply before writing tasks.json.

## Sizing and Content
- [ ] Each story completable in one agent iteration
- [ ] Each story is a vertical slice: bundles schema + backend + UI to deliver one user-observable capability (no horizontal layer-only stories)
- [ ] Stories ordered by capability dependency (capabilities that unlock other capabilities come first)
- [ ] Every story has at least one user-observable, end-to-end acceptance criterion listed first
- [ ] No orphan UI: all UI components are wired to real backend actions (no storybook-only or dev-preview-route verification)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] branchName is valid (alphanumeric, hyphens, slashes)
- [ ] `planPath` is `null`
- [ ] Every description follows "As a [specific role], I want [feature] so that [benefit]" format — role names the actor, never just "user"
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 5000

## v3.3 Schema Validations
- [ ] `schemaVersion` is `"3.3"`
- [ ] Every story `id` follows `US-NNN` format (e.g., `US-001`, `US-002`) — not `S1`, `F1`, `TASK-1`, or any other format
- [ ] Every story has `status` initialized to `"pending"`
- [ ] Every story has a `dependsOn` array (even if empty `[]`)
- [ ] No circular dependencies in `dependsOn` (graph must be a DAG)
- [ ] All IDs referenced in `dependsOn` exist as story IDs in the file
- [ ] No self-references (no story lists its own ID in `dependsOn`)
- [ ] `priority` values are sequential integers, consistent with dependency depth
- [ ] `maxConcurrency` (if set) is a positive integer
- [ ] `project` (if present) is a relative path with no `..` components, matching `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`
- [ ] `project` is omitted only when the plan tags fewer than two distinct projects (single-repo/monorepo, or every story targets the CWD repo). In a multi-repo plan — two or more distinct `project` values — **every** story needs one, and a story belonging to the root repository must say so explicitly with `"."`; an absent or blank `project` is unrouteable and makes `story-merge` refuse the whole merge before any file is written
- [ ] Every story has a `tasks[]` array with 3–15 ordered mechanical sub-steps in verb-object phrasing; whenever a story's `implementation.files` lists a path that also appears in another story's `implementation.files`, there is at least one explicit integration task ("Wire [component] into [owning file]")
- [ ] `tasks[]` (if present) is a non-empty string array, each entry ≤ 5000 chars, max 50 entries; field is omitted when empty
- [ ] `researchDepth` (if set) is one of: `skip`, `quick`, `standard`, `deep`
- [ ] Every story has a `wave` number (wave 1 for roots, computed from `dependsOn` for others)
- [ ] Wave numbers are contiguous with no gaps
- [ ] `implementation` (if present) has `files` (string[]), `approach` (string), `verify` (string)
- [ ] `implementation.files` uses concrete paths from research, not placeholders
- [ ] `verification` (if present) has `strategy` (`test`, `visual`, or `api`) and `status` (`"pending"`)
- [ ] `gate` (if present) has `type` (`verify`, `decision`, or `action`), `status` (`"pending"`), and `prompt`
- [ ] Gates only attached when heuristics clearly match; most stories have no gate

## Split-File Validations (when `implementationScope` is set)

Full-stack split is executed by `aimi-cli.sh story-merge --split full-stack` (functions `_story_merge_write_project_split` and `_story_merge_write_split`), invoked by `/aimi:plan` Phase 3e; the checks below describe what that command's output must satisfy, not an independently derivable split algorithm.

story-merge picks its split **axis** from the merged array itself, by counting distinct normalized `.project` values: **2 or more → PROJECT axis** (multi-repo), one output file per project, N files, no frontend/backend decision at all; **fewer than 2 → SIDE axis** (single-repo/monorepo), the unchanged two-file frontend/backend writer. The file list to check always comes from `MERGE_RETURN` — the stdout `/aimi:plan` Phase 3e captured from story-merge — never from string-concatenating the `--output` base, because on the PROJECT axis the surviving projects, their basename slugs, and their count are runtime data computed inside story-merge.

- [ ] Full-stack: every file named by `MERGE_RETURN` exists on disk, and the count of files validated equals the length of that returned list — N on the PROJECT axis (one per project, 2 or more distinct `.project` values), exactly two (`*-frontend-tasks.json` and `*-backend-tasks.json`) on the SIDE axis (fewer than 2 distinct `.project` values — the one case that still always yields exactly two files). Never assert a count derived from anything other than the returned list.
- [ ] Full-stack: each returned file has its own `branchName`, distinct from every sibling's and valid against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (SIDE axis: `type/[feature]-frontend` / `type/[feature]-backend`; PROJECT axis: `type/[feature]-<project-slug>`, one per returned entry; or their `ROADMAP_MODE=true` phase-suffixed equivalents)
- [ ] Full-stack, PROJECT axis only: each file carries `metadata.splitGroup` = `{project, index, total, siblings[]}` — its own project routing key, its 1-based `index`, `total` equal to the returned list's length, and `siblings[]` naming the other N−1 returned paths — and it survived the `/aimi:plan` Phase 4 metadata patch verbatim. SIDE-axis, legacy, and frontend-only files have no `splitGroup` key and none should be invented for them.
- [ ] Full-stack: story IDs are unique across all returned files (no ID collisions)
- [ ] Full-stack: cross-file `dependsOn` references are removed (each file's graph is self-contained) — but not silently: story-merge emits an aggregated stderr banner (dropped-edge count + affected-story count) and records one `cross-file-dep-dropped` entry per affected story in `metadata.smellWarnings` of every output file. Each entry is keyed by `project` on the PROJECT axis and by `side` on the SIDE axis (mutually exclusive).
- [ ] Full-stack: wave numbers computed independently per file (roots = wave 1 within each file)
- [ ] Frontend-only: single `*-frontend-tasks.json` with `metadata.frontendOnly: true`
- [ ] Frontend-only: `metadata.backendSpec` contains `endpoints`, `dataModels`, `businessRules`, `businessContext`
- [ ] Full-stack + `ROADMAP_MODE=true`: `--phase-aware` was passed to story-merge and every returned split basename carries a single `tasks` segment (SIDE axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-frontend-tasks.json`, not `...-tasks-frontend-tasks.json`; PROJECT axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-<project-slug>-tasks.json`)
- [ ] Phase 4.5 validation runs on each returned file independently using `$AIMI_CLI init-session --file <path>`
