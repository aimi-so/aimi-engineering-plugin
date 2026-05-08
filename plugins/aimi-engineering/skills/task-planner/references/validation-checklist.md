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
- [ ] `project` is omitted when only one repo exists or story targets CWD repo
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
- [ ] Full-stack: two files generated (`*-frontend-tasks.json` and `*-backend-tasks.json`)
- [ ] Full-stack: each file has its own `branchName` (`type/[feature]-frontend`, `type/[feature]-backend`)
- [ ] Full-stack: story IDs are unique across both files (no ID collisions)
- [ ] Full-stack: no cross-file `dependsOn` references — each file's graph is self-contained
- [ ] Full-stack: wave numbers computed independently per file (roots = wave 1 within each file)
- [ ] Frontend-only: single `*-frontend-tasks.json` with `metadata.frontendOnly: true`
- [ ] Frontend-only: `metadata.backendSpec` contains `endpoints`, `dataModels`, `businessRules`, `businessContext`
- [ ] Phase 4.5 validation runs on each file independently using `$AIMI_CLI init-session --file <path>`
