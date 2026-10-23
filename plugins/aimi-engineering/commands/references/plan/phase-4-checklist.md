# Plan: Phase 4: Checklist before Phase 4.5

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Anti-Citation-Bias Reminder

The validator (Phase 4.5) only enforces citation **format** — it does NOT enforce completeness, compositional fidelity, or behavioral coverage. Never let the validator's citation-format surface shape what you choose to encode.

Specific obligations:

- **Compositional obligations** (e.g., "form must contain fields X, Y, and Z") MAY live in a single AC line by chaining citations — one compact line is fine as long as every required element is named.
- **Behavioral obligations** (idempotency, ordering, timeout, retry, failure modes) MUST be encoded even when the spec describes them in prose without a quotable literal — paraphrase the behavior and cite the section heading.
- **Edge cases** enumerated in the spec MUST each map to at least one AC line. An edge case that appears in the spec but has no corresponding AC is a coverage gap, not a citation-format issue.
- When in doubt, encode more not less. Excess AC lines are far cheaper than missing coverage discovered at review time.

### Checklist Before Phase 4.5

- [ ] Every story `id` uses `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — not `US-1`, `S1`, `TASK-1`, or any other format (assigned by story-merge)
- [ ] Each story completable in one agent iteration
- [ ] Stories ordered by capability dependency (capabilities that unlock other capabilities come first; vertical slices, not horizontal layers)
- [ ] Every story asserts the project's own type/syntax check passes as a criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] `dependsOn` arrays are valid: no circular dependencies, no self-references, all referenced IDs exist (validated by story-merge)
- [ ] No story depends on a story that depends on it (DAG validation — performed by story-merge)
- [ ] Every story has `status` initialized to `"pending"`
- [ ] `dependsOn` is `[]` for root stories with no upstream dependencies
- [ ] branchName is valid (alphanumeric, hyphens, slashes)
- [ ] `planPath` is `null`
- [ ] `metadata.baseRef` (if set) is a 40-character lowercase hex commit SHA — and is absent entirely, never `null` and never `""`, when no repository root resolved or `git rev-parse HEAD` failed; on a PROJECT-axis split each file carries its own repository's SHA rather than a shared one; when story-merge was invoked with `--feature` and `--phase` this value is **pre-filled by story-merge** and this item verifies it instead of asserting Phase 4 wrote it
- [ ] `metadata.pluginVersion` (if set) is the version string the running CLI reported for itself (`$AIMI_CLI version`), not one read out of a plugin manifest — and is absent entirely, never `null` and never `""`, when that verb exited non-zero or printed nothing; it is one shared value, byte-identical across every file of a split; when story-merge was invoked with `--feature` and `--phase` it is **pre-filled by story-merge** from that same running CLI and this item verifies it rather than asserting Phase 4 wrote it
- [ ] `metadata.finalize` (if set) is an object carrying all three of `intent` (string), `files` (non-empty array of strings) and `commitSubject` (string) — and is absent entirely, never `null` and never `{}`, when the round declares no end-of-round step; at most one per repository, so on a PROJECT-axis split each entry carries its own and on a SIDE-axis split only the backend file does
- [ ] Every description follows "As a [specific role], I want [feature] so that [benefit]" format — role names the actor, never just "user"
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 5000
- [ ] `schemaVersion` is `"3.3"`
- [ ] `metadata.execution` is exactly `"container"` on every freshly generated flat file and absent entirely on every freshly generated phase-scoped file; when present on any file it is exactly `"container"` or `"inline"`, and never co-occurs with `metadata.phase`
- [ ] `researchDepth` (if set) is one of: `skip`, `quick`, `standard`, `deep`
- [ ] `prototypePaths` (if set) contains only paths that exist on disk and were successfully loaded into `prototypeBlocks`
- [ ] `metadata.designBundle` (if set) — all paths (`root`, `readme`, `chats[]`, `businessSpec`, `designSpec`) that are non-null exist on disk under `AIMI_ROOT`
- [ ] `metadata.designTokens` (if set) is a flat object whose top-level keys match the token categories enumerated in `DesignSpec § 1`
- [ ] When `businessSpecContent` is non-null, every story whose title matches a screen name in `BusinessSpec § 2` (canonical map: `commands/references/spec-section-contract.md`) cites at least one rule ID from `§ 3` (e.g., `RN-01`) or one criterion ID from `§ 9` in its `acceptanceCriteria`
- [ ] Every story has a `wave` number (wave 1 for roots, computed from `dependsOn` for others)
- [ ] Wave numbers are contiguous with no gaps
- [ ] `implementation` (if present) has `files` (string[]), `approach` (string), `verify` (string) with concrete paths and no `cd <project> &&` prefix, per the "verify working directory" rule in the Story JSON shape block above — the executor has already entered the project
- [ ] `verification` (if present) has `strategy` (`test`, `visual`, or `api`) and `status` (`"pending"`)
- [ ] `gate` (if present) has `type` (`verify`, `decision`, or `action`), `status` (`"pending"`), and `prompt`
- [ ] Gates only attached when heuristics clearly match
- [ ] Every story with `verification.strategy == "visual"` and non-empty `metadata.prototypePaths` has at least one `(prototype: ...)` citation in its acceptance criteria (either `(prototype: <path> §<heading>)` or `(prototype: <path>:L<start>-L<end>)`)
- [ ] Rule 19a compliance (when `designSpecContent` is non-null): every visual story's `acceptanceCriteria` wraps each visible-text literal in double quotes followed by a `(DesignSpec § N.N L<line>)` anchor; no paraphrasing, translation, abbreviation, or reordering of the cited text
- [ ] Rolling-wave (when `ROADMAP_MODE=true`, not split): `metadata.roadmapPath` and `metadata.phase.{id,dir}` are present and match the selected phase — both are **pre-filled by story-merge** on a run that passed `--feature` and `--phase`, so this half of the item is a check on that path rather than a re-derivation; `metadata.branchName` matches `type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}` (the dot-slugified id — a decimal phase must read `-phase-5-5-`, never `-phase-5.5-`) and passes `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`; the output file lives at `.aimi/tasks/${featureSlug}/${PHASE_DIR}/${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json` (the **raw** id — this path names a real file that carries the dot); `roadmap.json`'s phase `${SELECTED_PHASE_ID}` status is `planned` only after this checklist and Phase 4.5 both pass
- [ ] Rolling-wave + full-stack split (when `ROADMAP_MODE=true` and `implementationScope == "full-stack"` — outline 13): story-merge was invoked with both `--split full-stack` and `--phase-aware`; every file named by `MERGE_RETURN` lives under `.aimi/tasks/${featureSlug}/${PHASE_DIR}/` with a single `tasks` segment in its basename — not the flat split's double-`tasks` shape (SIDE axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-frontend-tasks.json` / `-backend-tasks.json`; PROJECT axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-<project-slug>-tasks.json` per project); each file's `metadata.branchName` is its phase-suffixed per-file value built from the dot-slugified id (`type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}-frontend` / `-backend` on the SIDE axis, `type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}-<project-slug>` on the PROJECT axis — note the basenames just above keep the **raw** id while these branch names do not) and passes `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`; `roadmap.json`'s phase `${SELECTED_PHASE_ID}` status is `planned` only after this checklist and Phase 4.5 both pass

### Split-File Checks (when `implementationScope` is set)
- [ ] Full-stack: every file named by `MERGE_RETURN` exists on disk, and the count of files patched and validated equals the length of that returned list — N on the PROJECT axis (one per project, 2 or more distinct `.project` values), exactly two (`*-frontend-tasks.json` and `*-backend-tasks.json`) on the SIDE axis (single-repo/monorepo, fewer than 2 distinct `.project` values — the one case that still always yields exactly two files). Never assert a count derived from anything other than the returned list.
- [ ] Full-stack: each returned file has its own `branchName`, distinct from every sibling's and valid against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (SIDE axis: `type/[feature]-frontend` / `-backend`; PROJECT axis: `type/[feature]-<project-slug>` per entry; or their `ROADMAP_MODE=true` phase-suffixed equivalents) — patched in Phase 4
- [ ] Full-stack, PROJECT axis only: each file's `metadata.splitGroup` survived the Phase 4 patch intact — `{project, index, total, siblings[]}`, with `total` equal to the returned list's length and `siblings[]` naming the other N−1 returned paths
- [ ] Full-stack: story IDs are unique across all returned files (no ID collisions) — enforced by story-merge
- [ ] Full-stack: no cross-file `dependsOn` references — each file's graph is self-contained (this invariant is unchanged) — enforced by story-merge; cross-file edges are still dropped, but are now surfaced (not silent) via one aggregated stderr banner plus a `cross-file-dep-dropped` entry in `metadata.smellWarnings` for every affected story
- [ ] Full-stack: wave numbers computed independently per file (roots = wave 1 within each file) — enforced by story-merge
- [ ] Frontend-only: single `*-frontend-tasks.json` with `metadata.frontendOnly: true`
- [ ] Frontend-only: `metadata.backendSpec` contains `endpoints`, `dataModels`, `businessRules`, `businessContext`
- [ ] Full-stack: `metadata.designBundle` (if set) and `metadata.designTokens` (if set) are written to every returned file
- [ ] Full-stack + `ROADMAP_MODE=true`: `--phase-aware` was passed to story-merge and every returned split basename carries a single `tasks` segment (SIDE axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-frontend-tasks.json`, not `...-tasks-frontend-tasks.json`; PROJECT axis: `${featureSlug}-phase-${SELECTED_PHASE_ID}-<project-slug>-tasks.json`)
- [ ] Phase 4.5 validation runs on each returned file independently using `$AIMI_CLI init-session --file <path>`
