# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.89.0] - 2026-05-21

### Added

- `--non-interactive` flag for `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish`. Pass `--non-interactive` to skip all interactive prompts and auto-defer every Open Question (agent/CI mode). Interactive (`picker`) mode is now the default for all three commands.

### Changed

- `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish` default to **interactive mode** (`INTERACTIVE_MODE=picker`). Previously these commands could silently fall through to `agent` mode when running in a non-TTY shell (e.g. inside OpenCode's bash tool calls), suppressing all user-facing questions. The bare-TTY fallback in `detect-interactivity` has been removed so a hostless non-TTY shell no longer triggers agent mode.
- `cmd_detect_interactivity` in `aimi-cli.sh` now returns `picker` as the default. Agent mode is reached only through explicit opt-out: `--non-interactive` flag, `AIMI_AGENT_MODE=true`, or `CI=true`.

### Fixed

- OpenCode agent-mode misclassification: `detect-interactivity` previously returned `agent` for OpenCode sessions because OpenCode runs bash tool calls in a non-TTY shell and does not export `OPENCODE_CONFIG_DIR` in that context, causing the TTY fallback (step 6) to fire. Removing the bare-TTY fallback ensures the command correctly defaults to `picker` on OpenCode.

## [1.88.0] - 2026-05-21

### Removed

- `aimi-every-style-editor` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-ankane-readme-writer` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-lint` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-pr-comment-resolver` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-figma-design-sync` agent — out-of-scope / orphaned; no active command consumer.

### Added

- `/aimi:validate-bug` command (`commands/validate-bug.md`): reproduces and validates bug reports by delegating to the `aimi-bug-reproduction-validator` agent. Accepts a free-form bug description, runs a structured reproduction workflow, and reports whether the bug is confirmed, cannot be reproduced, or is a user error.

### Changed

- `aimi-bug-reproduction-validator` agent generalized: Rails-specific bias removed from its Investigation Techniques section so the agent operates effectively across all languages and frameworks.
- `/aimi:design:polish` now optionally delegates to `aimi-design-iterator` for a multi-cycle visual iteration pass (screenshot → analyze → improve loop) in addition to the existing inline polish workflow.

## [1.87.1] - 2026-05-20

### Fixed
- `cmd_update_field` was dropping the final segment of a dotted path (e.g., `verification.status` built `.verification` instead of `.verification.status`) because `printf '%s' | sed | while read -r` skips the loop body for the last unterminated segment. Replaced the pipe chain with an `IFS=. read -ra` herestring split that is trailing-newline-safe, so `update-field US-NNN verification.status passed` now patches only the leaf field and preserves all sibling fields on the parent object.

## [1.87.0] - 2026-05-15

### Added
- XDG-compliant cache location at `~/.config/aimi/cli-path` and `~/.config/aimi/worktree-path` for storing the resolved CLI and worktree paths. The location can be overridden via the new `AIMI_CONFIG_DIR` environment variable (e.g., `AIMI_CONFIG_DIR=/custom/path`), which governs cache file placement only — Layer 2 plugin discovery continues to use `CLAUDE_CONFIG_DIR`.
- New `_aimi_config_dir()` helper in `aimi-cli.sh` encapsulates the `AIMI_CONFIG_DIR`-or-XDG-default resolution, making all cache read/write call sites consistent.
- "Per-Call Resolution" section in `commands/references/cli-path-resolution.md` documenting the shell-isolation hazard and the required per-call `cat` re-read pattern with explicit precondition (Step 0 full resolution must have run first to prime the new path).

### Changed
- `plan.md`, `execute.md`, `brainstorm.md`, `skills/story-executor/SKILL.md`, and `skills/task-planner/SKILL.md` migrated to per-call CLI re-read: each Bash call that needs `$AIMI_CLI` now resolves it inline via `cat ~/.config/aimi/cli-path` rather than relying on a shell variable from a prior call.
- `auto-approve-cli.sh` hook updated to recognize the new XDG paths (`~/.config/aimi/cli-path`, `~/.config/aimi/worktree-path`) alongside the legacy `~/.claude/aimi-engineering-{cli,worktree}-path` paths, so CLI cache reads and writes do not trigger unexpected permission prompts during the migration window.
- Hard-coded legacy `~/.claude/aimi-engineering-cli-path` references in `commands/init.md`, `CLAUDE.md`, `install.sh`, and `settings.local.json` updated to reflect the new XDG location.

### Fixed
- Shell-isolation hazard where `$AIMI_CLI` resolved correctly in one Bash call but expanded to empty in every subsequent call (each Claude Code Bash invocation runs in an isolated subshell), causing silent "command not found: `<subcommand>`" failures throughout plan, execute, and brainstorm workflows.

### Compatibility
- Legacy `~/.claude/aimi-engineering-cli-path` and `~/.claude/aimi-engineering-worktree-path` files remain supported via a read-both fallback: `aimi-cli.sh` tries the new XDG location first and falls back to the legacy path if the new file is absent. **No user action is required.** The legacy read-both fallback is planned for removal in the next MAJOR version bump.

## [1.86.7] - 2026-05-13

### Changed
- Trimmed the Pre-Save Checklist in `brainstorm.md` Phase 4 by removing the eight items marked `(advisory/non-blocking)` that restate rules already enforced in the document body (Design Decisions section presence, Personas/View Modes/Layout Variation subsections, Specs and Prototypes section presence, generated-bundle YAML key ordering, researchPaths emission). Added a one-line preamble directing readers to the body rules as the source of truth. The Pre-Save Blocking Gate — Open Questions section (with `[resolved: ...]` / `[deferred: ...]` sentinels, bundle-source clarification, and agent-mode auto-defer fallback) is preserved verbatim. Behavior unchanged.

## [1.86.6] - 2026-05-13

### Changed
- Consolidated the `AIMI_ROOT_IS_GIT_REPO` branching rule, the per-story project-grouping pattern (absolute-path resolution, path-validation regex, no-leading-./, no-.. rules), and the per-project cleanup rule into one "Multi-Repo Handling" section at the top of `execute.md` (placed between Step 0 and Step 0.5). Each call site now carries a one-line pointer to the section while keeping the decision pseudocode inline — no per-run Read cost. The wave-loop group_key/project_roots/base_sha/all_worktrees pseudocode, setup-branch invocations, PROJECT_GUIDELINES_MAP build, merge-per-project logic, and cleanup iteration are all preserved verbatim.

## [1.86.5] - 2026-05-13

### Changed
- Folded the four near-identical inline "check flag → emit once → set true" blocks for `echoedBundleEarlyExit`, `echoedBrowserUnavailable`, `echoedSessionLost`, and `echoedPickerUnavailable` in `brainstorm.md` into one "Once-per-session echo helper" rule documented near Step 0b. Each call site now invokes the helper with its flag name and message. Flag names, message texts, working-memory initialization, and surrounding contextual prose are preserved verbatim.

## [1.86.4] - 2026-05-13

### Changed
- Consolidated the visual-follow lifecycle (detection, session-open, reuse-within-wave, keep-open-on-completion) from the four scattered sites in `execute.md` (Step 0.7, Step 3.3, Step 4 wave loop, Post-Loop) into one "Visual Follow Lifecycle" section placed before Step 0.7. Each call site now points at the consolidated section. Behavior preserved verbatim — MALFORMED_VERIF abort, per-story screenshot+compare logic, session name `visual-follow`, and the "Visual follow session still open" completion message all remain inline at their original sites.

## [1.86.3] - 2026-05-13

### Changed
- Collapsed the three near-identical "How `<flag>` works at runtime" subsections in `brainstorm.md` Override Keywords section (`show variants`, `vary ui`, `render bundle`) into one parameterized rule table (columns: trigger phrase, flag name, activation log line, scope/clear condition, precedence over Step 0a) and a single co-occurrence statement covering all pairwise and triple-overlap semantics. The user-facing summary table is preserved verbatim. Behavior unchanged — every flag name, log line, scope, clear condition, and precedence-over-Step-0a rule is identical.

## [1.86.2] - 2026-05-13

### Changed
- Extracted input-sanitization rules and topic-slug derivation algorithm from `brainstorm.md` and `execute.md` into `commands/references/sanitization.md` and `commands/references/topic-slug.md`. Both commands now cite the new reference files instead of restating the rules inline, eliminating the stale line-number citation in `execute.md` Step 3.4. Behavior is preserved verbatim — pure prose deduplication.

## [1.86.1] - 2026-05-13

### Fixed
- `detect-interactivity` no longer returns `agent` inside Claude Code or OpenCode when stdin is not a TTY. Both hosts run command bash bodies in non-TTY subshells, so the previous `[ ! -t 0 ]` check misclassified every interactive session as agent mode — causing Phase 0.5 / Phase 1.8 / Phase 2.5 OQ gates in `/aimi:plan` to silently auto-defer every open question instead of prompting the user. The check now treats `CLAUDECODE=1` and a set `OPENCODE_CONFIG_DIR` as picker-available regardless of TTY state. `AIMI_AGENT_MODE=true` and `CI=true` still force agent mode as before.

## [1.86.0] - 2026-05-13

### Added
- Phase 1.8 (Post-Research Open Questions Gate) in /aimi:plan — surfaces every researcher's `## Open Questions` and `[PROMOTE-TO-OPEN-QUESTIONS]` entries via AskUserQuestion before story decomposition; auto-defers under AIMI_AGENT_MODE.
- Phase 2.5 (Spec-Flow Gap Gate) in /aimi:plan — surfaces the spec-flow analyzer's `### Missing Elements & Gaps` and `### Critical Questions Requiring Clarification` entries before story decomposition; auto-defers under AIMI_AGENT_MODE.

### Changed
- metadata.decisions[].source schema extended with three new forms: `researchFile:<basename>:OQ<n>`, `specFlow:CriticalQ<n>`, `specFlow:Gap<n>`.

## [1.85.0] - 2026-05-12

### Changed
- Subagent spawn prompts now use pointer-only context handoff: each spawned agent receives only the story ID in a `task_pointer` block and fetches its full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action, keeping the orchestrator's working memory slim across waves and eliminating inlined story bodies and prototype HTML from spawn prompts.
- New `get-story-context` CLI subcommand added to `aimi-cli.sh`: given a story ID, emits the full story JSON (including acceptance criteria, implementation block, verification, and gate fields) so subagents can self-bootstrap without relying on orchestrator-inlined payloads.

## [1.84.0] - 2026-05-12

### Added
- `normalize-verification` CLI subcommand: rewrites bare-string verification fields into the object form `{strategy, status, url, expect}` with atomic tmp+mv write.
- Visual Source-of-Truth Protocol (V1/V2/V3) in story-executor SKILL.md: pre-implementation enumeration rail for visual stories, gated on `verification.strategy == "visual"` or non-empty PROTOTYPE_CONTEXT.
- Per-element PASS/DIVERGES/KNOWN-GAP table requirement in the Reference-Artifact Parity Pass (visual stories only).
- `KNOWN-GAP:` trailer persistence: execute.md captures trailers from worker commits into `.aimi/known-gaps/YYYY-MM-DD-<storyId>.md` and aggregates them in the Step 5 final report under `## Known Gaps`.
- Auto-spawned `aimi-design-implementation-reviewer` after each visual story merges; review output captured in the Step 5 final report under `## Design Review`.

### Changed
- `validate-stories` now rejects any story whose `verification` is a bare string (must be an object with a `strategy` key).
- `/aimi:plan` Phase 4.5 invokes `normalize-verification` before validators, auto-migrating planner-emitted string verifications in place.
- `/aimi:execute` Step 0.7 now aborts (non-zero exit) on malformed verifications instead of warning and continuing; abort message lists offending story IDs and points at `normalize-verification` for remediation.
- Gap-trailer token renamed from `KNOWN GAP:` (with space) to `KNOWN-GAP:` (hyphenated) in story-executor SKILL.md and the verdict-table label, enabling clean `grep -E '^KNOWN-GAP:'` parsing.

## [1.83.0] - 2026-05-12

### Added
- `/aimi:plan` Phase 0.5 now scans BusinessSpec/DesignSpec content for marker-style Open Questions (`[a confirmar]`, `[TBD]`, `[to confirm]`, `[to be confirmed]`, `[to be defined]`) and surfaces each via AskUserQuestion with source+anchor. Spec-marker resolutions are recorded in working-memory `oqDecisions[]` only; spec files are never written back to. Aggregate cap of 20 entries.
- `/aimi:plan` Phase 1 now spawns `aimi-design-bundle-researcher` when invoked directly against a Claude Design handoff bundle (no prior brainstorm). Restores parity with the brainstorm-to-plan flow; resulting Open Questions merge into the Phase 0.5 list before continuing to Phase 1.5.

### Fixed
- `aimi-cli detect-design-bundle` now uses case-insensitive `find -iname` for spec file discovery, so bundles with camelCase filenames (`businessSpec.md`, `designSpec.md`) are detected correctly. Returned paths preserve actual on-disk casing.

### Changed
- Schema v3.3 documentation in `plan.md` now includes a `responseShape contract (frontend-only mode)` block explaining the flat-key constraint and why dotted keys like `portfolio.totalUsinas` are rejected by `validate-tasks`.

## [1.82.0] - 2026-05-12

### Added

- **Plan command: Phase 3.1 Reference Element Inventory (BLOCKING when triggered):** New `### Phase 3.1: Reference Element Inventory (BLOCKING when triggered)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 3 section, before `dependsOn` Inference Rules). When any story declares a reference artifact (`prototypeAnchor`, `specSection`, `referenceCommand`, `referenceFixture`, `migrationDiff`, `referenceUrl`, etc.), opens the artifact and enumerates every addressable element in the cited region using kind-specific vocabulary (HTML/UI, OpenAPI/JSON Schema, CLI man page, SQL/migration diff, business rules table). Records findings as an `Element | Locator | Verdict | AC anchor` table; every row must be marked `encoded` or `excluded` with a written reason before story JSON is emitted. Block Phase 4 until all rows are verdicted; agent-mode fallback auto-marks unverdicted rows as `deferred`. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Phase 4.1 Coverage Self-Check (BLOCKING):** New `### Phase 4.1: Coverage Self-Check (BLOCKING)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 4 Derive Metadata section, before Write File). For each story with a Phase 3.1 inventory, computes `ac_anchors / proto_elements` ratio; if `ac_anchors < floor(proto_elements * 0.6)`, returns to Phase 3.1 to add AC lines or upgrade rows to `excluded`. Blocks Write File until the ratio is satisfied for every affected story; agent-mode fallback emits a structured deficit warning and proceeds. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Anti-Citation-Bias Reminder:** New `### Anti-Citation-Bias Reminder` block inserted into `plugins/aimi-engineering/commands/plan.md` (after Schema v3.3 Structure, before Checklist Before Writing). Clarifies that the validator only enforces citation format — not completeness, compositional fidelity, or behavioral coverage. Explicitly requires encoding of behavioral obligations and edge cases even without quotable literals, and recommends chaining citations for compositional obligations. Not labeled BLOCKING (worldview reminder, not a gate).
- **Researcher agents: `## Contracts` quoting requirement:** New `## Contracts` section inserted into both `plugins/aimi-engineering/agents/research/aimi-codebase-researcher.md` and `plugins/aimi-engineering/agents/research/aimi-framework-docs-researcher.md`. Requires verbatim quoting of every consumed contract (typed signatures, REST/RPC shapes, CLI flag lists, DB schema, SDK public APIs) into the research file body with `file:line` citation — one fenced block per contract, no invention or inference of shapes.
- **Story executor: Reference-Artifact Parity Pass (BLOCKING when triggered):** New `## Reference-Artifact Parity Pass (BLOCKING when triggered)` named section inserted into `plugins/aimi-engineering/skills/story-executor/SKILL.md` (before Prompt Template). Fires when a story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Procedure: load reference → enumerate addressable elements in cited region → cross-check against implementation → per-element verdict (`Implemented` or `KNOWN GAP: <element> — <reason>` appended to commit body). Silent drops are not acceptable. Blocks commit until every element has a verdict; agent-mode fallback logs `Parity pass skipped — reference not readable: <path>` and proceeds. Also added as step 3.5 in the canonical prompt template `<execution_flow>` and as a one-sentence extension to the compact template `<execution_flow>`.

### Changed

- **Plan command: Phase 1.7 Research File Ingestion trigger extended to `quick` tier:** The `## Phase 1.7: Research File Ingestion` trigger in `plugins/aimi-engineering/commands/plan.md` now fires for `researchDepth` `quick`, `standard`, or `deep` (previously `standard` or `deep` only). The no-op case shrinks to `skip` or unset. Mirrored in `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.81.0] - 2026-05-12

### Added

- **Plan command: Phase 1.7 Research File Ingestion (US-001):** New `## Phase 1.7: Research File Ingestion` section inserted between Phase 1.6 and Phase 2 in `plugins/aimi-engineering/commands/plan.md`. When `researchDepth` is `standard` or `deep`, reads the full on-disk content of every path in `metadata.researchPaths`, deduped against `reusedCodebasePath` and `reusedBestPracticesPath` (already loaded by Phase 1.6). Missing files are silently skipped; no per-file or aggregate size cap is applied. Each loaded file is wrapped as `<research_file path="...">` with light HTML-entity escape on literal wrapper-tag sequences (analogous to the `prototype_html` escape pattern). Collected blocks are stored in `researchFileBlocks` and threaded into Phase 3 alongside `prototypeBlocks` so acceptance-criteria authoring draws on complete on-disk research detail rather than capped summary returns. `quick`, `skip`, and unset tiers preserve previous summary-only behavior bit-for-bit. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.80.0] - 2026-05-11

### Added

- **Pre-Save Blocking Gate for Open Questions in `/aimi:brainstorm` (US-001):** The Pre-Save Checklist at `plugins/aimi-engineering/commands/brainstorm.md` is strengthened with a `### Pre-Save Blocking Gate — Open Questions` block that counts entries under `## Open Questions` lacking a `[resolved: <choice>]` or `[deferred: <reason>]` sentinel suffix, loops `AskUserQuestion` until every OQ carries one, and writes the sentinel back to the OQ line as the idempotency marker. Bundle-sourced OQs (lines originating from `BusinessSpec § 11` or `DesignSpec § 8`) are NOT exempt — `bundleAddressedTopics` covers chat-question categories, not spec pendencies. Agent-mode fallback auto-marks every unresolved OQ as `[deferred: agent-mode auto-defer]` before save.
- **Defensive Phase 0.5 Open Questions Resolution Gate in `/aimi:plan` (US-002):** New `### Phase 0.5: Open Questions Resolution Gate` section inserted between Phase 0 and Phase 1 of `plugins/aimi-engineering/commands/plan.md`. Parses the brainstorm `## Open Questions` section; for each line without a `[resolved: ...]` or `[deferred: ...]` sentinel, calls `AskUserQuestion`, appends the sentinel via `Edit`, records the choice in working memory `oqDecisions: { <oqId>: <choice> }` for use in Phase 4 `metadata.decisions[]`, and blocks Phase 1 until every OQ is sentinelled. Agent-mode fallback: auto-defer (do not block). Catches stale brainstorms that bypassed the upstream save-gate.
- **`validate-stories` gate-schema enforcement in `aimi-cli.sh` (US-003):** `cmd_validate_stories` now rejects the plural `gates` field with `<id>: gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)` and validates the singular `gate` object shape by requiring `type`, `status`, and `prompt` keys (emits `<id>: gate: missing required field <name>` per missing key). Errors flow through the existing `{valid, errors[]}` output channel — no `ERROR:` prefix, no exit-per-error. Three new fixtures registered in `test-aimi-cli.sh` (`test_validate_stories_gate_field`): plural `gates` (fail), singular `gate` missing `type` (fail), well-formed singular `gate` (pass).

### Changed

- **`/aimi:plan` Phase 4.5 validator note extended (US-004):** The existing note around `validate-stories (US-001) catches malformed skills[]` is extended to also document the new gate-schema enforcement — both `gates` plural rejection and singular `gate` shape validation.

## [1.79.0] - 2026-05-11

### Added

- **`validate-tasks` subcommand in `aimi-cli.sh` (US-006, gap-analysis case 6):** New CLI subcommand that mechanically enforces citation contracts in a tasks.json file before execution. Reads `acceptanceCriteria[]` entries flagged as visual and verifies each contains at least one verbatim DesignSpec citation anchored as `"<literal>" (DesignSpec § N.N L<line>)`. Exits non-zero with a structured error report on first violation, preventing story execution from proceeding with uncited visual ACs.
- **Rule 19a in `/aimi:plan` Phase 3 (US-001, US-002, US-003, gap-analysis cases 1, 2, 3):** Verbatim DesignSpec citation requirement for visual acceptance criteria. Any AC that describes a visual element (layout, copy, label, badge, header, footer, column header, KPI label, button text, subtitle) must embed the exact literal string from the DesignSpec section followed by a citation anchor in the form `"<literal>" (DesignSpec § N.N L<line>)`. Applies to H1 text, subtitles, KPI labels, column headers, button labels, footer text, and badge copy. Planner must resolve the section number and line number from the attached DesignSpec before emitting the story.
- **`source` field requirement on `backendSpec.endpoints[]` and `responseShape` (US-007, gap-analysis case 7):** Every entry in `backendSpec.endpoints[]` must carry a `source` field citing the spec document and section that mandates the endpoint (e.g., `"source": "BusinessSpec § 3.2"`). Every `responseShape` field in frontend-only plans must likewise declare its provenance. A `derived:` escape hatch is available for legitimately computed shapes whose structure is not directly specified in any spec document (e.g., `"source": "derived: aggregated from /users and /roles responses"`).
- Gap-analysis cases 4, 5, 8 are deferred to v1.80.

## [1.78.0] - 2026-05-11

### Added

- **`aimi-bundle-prototype-author` agent (US-002):** New research-category agent (`plugins/aimi-engineering/agents/research/aimi-bundle-prototype-author.md`) that generates self-contained bundle prototype HTML files from a design bundle and brainstorm context. Reads BusinessSpec/DesignSpec, applies design tokens, and emits a fully styled interactive prototype.
- **`bundle-prototype-status` CLI subcommand (US-003):** New `aimi-cli.sh` subcommand that reads `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json` and reports the current generation status (pending, in-progress, complete) for a given topic slug.
- **`bundle-prototype-finalize` CLI subcommand (US-004):** New `aimi-cli.sh` subcommand that marks a bundle prototype sidecar as finalized and records the output HTML path, enabling downstream commands to locate the generated prototype.
- **`/aimi:brainstorm` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty in the tasks metadata, brainstorm automatically invokes `aimi-bundle-prototype-author` to generate bundle prototype HTML before surfacing questions to the user.
- **`/aimi:plan` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty, plan auto-generates bundle prototype HTML via `aimi-bundle-prototype-author` during the research phase, then passes the generated path as a prototype anchor for visual story decomposition.
- **"render bundle" override keyword:** Both `/aimi:brainstorm` and `/aimi:plan` recognize a case-insensitive `render bundle` substring in the feature description as a one-shot override that forces bundle prototype generation even when `prototypes[]` is already populated.
- **Sidecar idempotency at `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json`:** Bundle prototype generation is idempotent — if a sidecar file already exists at the canonical path for a given topic slug, the author agent skips re-generation and returns the existing output HTML path.

## [1.77.0] - 2026-05-08

### Changed

- **Per-entry character cap raised from 600 to 5000:** Applies to `acceptanceCriteria[]` and `tasks[]` entries. Loosens the previous limit that was forcing truncation of detailed criteria and recipe steps. `title` (200) and `description` (500) caps unchanged.
- **`tasks[]` array length cap raised from 20 to 50:** Allows richer mechanical recipes for complex stories. Soft target of 3–15 entries remains as planner guidance.

## [1.76.0] - 2026-05-08

### Added

- **`/aimi:plan` now populates `tasks[]` on every user story (US-001):** Phase 3 Story Decomposition step 9.6 generates a horizontal mechanical breakdown of 3–15 concrete sub-steps per vertical story in verb-object phrasing. Integration steps (`"Wire <X> into <Y>"`) are mandatory whenever `implementation.files` lists a path shared with another story, closing the planning gap that caused orphaned tabs and missing routes in parallel-worktree executions.

## [1.75.0] - 2026-05-08

### Added

- **Optional `tasks[]` free-form sub-step checklist on userStories (US-001):** Stories may now include a `tasks` array (max 20 items, each ≤600 chars) of free-form sub-step strings displayed to executors as a checklist. The field is optional and additive; existing tasks.json files are unaffected.
- **Tasks-file schema bumped from 3.2 to 3.3 (US-002):** `schemaVersion` advances to `"3.3"`. The bump is additive — `validate-stories` accepts the new `tasks[]` field and enforces string elements.

### Changed

- **`/aimi:plan` now produces vertical-slice deliverables instead of layer-atomic stories (US-003):** Story decomposition targets end-to-end feature slices (each story delivers user-visible value across all layers) rather than horizontal layer boundaries. Decomposition guidance in `task-planner` updated accordingly.

## [1.74.0] - 2026-05-06

### Added

- **`researchPaths` frontmatter in brainstorm output (US-001):** `/aimi:brainstorm` now records the absolute paths of every research file it produced (`*-codebase.md`, `*-best-practices.md`, etc.) in the brainstorm document's YAML frontmatter so downstream commands can reuse them.
- **`paths` scope parameter on aimi-codebase-researcher (US-003):** The codebase researcher now accepts an optional `paths:` parameter that scopes its `Glob`/`Grep` searches to the listed directories or files instead of globbing the whole repo.
- **Path-hint extraction in brainstorm and plan (US-004):** Both commands now extract path-like tokens from the feature description (`$ARGUMENTS`) and forward them to the codebase researcher as the `paths:` scope when present.

### Changed

- **`/aimi:plan` reuses brainstorm research (US-002):** When a matched brainstorm exposes `researchPaths` and the files exist on disk with mtime ≤14 days, plan skips spawning `aimi-codebase-researcher` and `aimi-best-practices-researcher` and reads the existing files instead. Phase 5 reports `Research reused: [N] file(s) from brainstorm` when reuse occurs. Legacy brainstorms without `researchPaths` are unaffected.
- **Default `researchDepth` lowered from `standard` to `quick` (US-005):** Across `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, and `aimi-framework-docs-researcher`. Reduces default summary cap and shrinks per-research token cost when callers do not specify a depth.

## [1.73.1] - 2026-05-05

### Fixed

- **`aimi-cli (detect-design-bundle):`** `--root <path>` now also matches when `<path>` itself is a bundle directory, not only when it's a parent containing bundles. Previously returned `null` when callers pointed `--root` at the bundle itself.
- **`aimi-cli (help):`** `<subcommand> --help` and `<subcommand> -h` now print the full help doc instead of returning "Unknown flag" and exit 1 from strict subcommand parsers (`init-session`, `detect-design-bundle`, `setup-branch`, `gate-pass`) or being misinterpreted as positional input by other subcommands.

## [1.73.0] - 2026-05-05

### Fixed

- **`commands (US-001):`** Plan and brainstorm now read the `prototypes` key from design-bundle metadata and pass `--root` instead of the non-existent `--bundle` flag, so prototype HTML actually loads.
- **`commands (US-008):`** Executor's PROTOTYPE_CONTEXT builder validates `prototypeAnchor` and AC-cited paths against AIMI_ROOT before loading, preventing path-traversal escapes.

### Added

- **`brainstorm (US-002):`** Brainstorm emits bundle-discovered prototype paths in the frontmatter `prototype:` key and a `## Prototypes` body section with Path/Source/Question Category columns; plan parses both.
- **`plan (US-003):`** Phase 3 rule 19 requires every visual-layout AC to cite a prototype region using `(prototype: path §heading)` or line-range fallback `(prototype: path:Lstart-Lend)`. Plan canonicalizes prototype HTML for layout; spec for tokens, types, and states.
- **`design-bundle-researcher (US-004):`** New §16.5 `Spec-Prototype Coverage Gaps` section surfaces regions present in prototype HTML but missing or partial in DesignSpec.md, with high-confidence-missing markers for Open Questions promotion.
- **`plan (US-005):`** Phase 3 rule 20 auto-injects a mock-sync AC onto stories whose `implementation.files` match schema/types/zod path globs, with idempotency guard for re-plan and graceful degradation when no mocks/ directory exists.
- **`design-reviewer (US-006):`** `aimi-design-implementation-reviewer` now accepts polymorphic prototype source (Figma URL, prototype HTML path, or screenshot) with advisory degradation when no source is provided.
- **`review (US-007):`** `/aimi:review` automatically invokes the design-implementation-reviewer once per visual story when `metadata.prototypePaths` is non-empty, with graceful skip when `agent-browser` is not installed.
- **`plan,execute,executor (US-008):`** Plan emits `implementation.prototypeAnchor` for visual stories citing a single prototype; executor pins that anchor as label A in PROTOTYPE_CONTEXT, falling back to AC-parse when the field is absent.
- **`plan (US-009):`** Phase 3 rule 22 routes the rule-20 mock-sync AC onto consumer stories that mention the new field by name (with CamelCase entity-name fuzzy fallback), moving rather than copying when a consumer matches.

## [1.72.0] - 2026-05-05

### Added

- **`detect-design-bundle` CLI subcommand (US-001):** New `aimi-cli.sh` subcommand that detects whether a project contains a BusinessSpec and/or DesignSpec file, emitting structured JSON output consumed by brainstorm, plan, and story-executor workflows.
- **test-aimi-cli.sh bundle detection tests (US-002):** Test coverage for `detect-design-bundle` — presence, absence, and partial-match cases added to the CLI test suite.
- **`aimi-design-bundle-researcher` agent (US-003):** New 16-section structured passthrough agent that reads BusinessSpec and DesignSpec files and emits a compressed research summary for downstream brainstorm and plan consumers.
- **brainstorm bundle-aware research consolidation (US-004):** Brainstorm now invokes `aimi-design-bundle-researcher` when a bundle is detected, merging spec insights into the question-selection and variant-axis stages before surfacing them to the user.
- **bundle-aware token probe in visual-variants.md (US-005):** `visual-variants.md` reference now includes a token probe step that reads `metadata.designTokens` when a design bundle is present, feeding spec-extracted tokens into the variant axis decision tree.
- **brainstorm short-circuits visual variants when bundle present (US-006):** When a DesignSpec is detected, brainstorm skips the token-extraction fallback path and uses spec-defined tokens directly, preventing redundant extraction work.
- **spec-aware brainstorm document (US-007):** Brainstorm output document gains Personas, View Modes, Layout, and Specs sections populated from bundle research when a BusinessSpec or DesignSpec is present.
- **plan ingests bundle into tasks.json `metadata.designBundle` (US-008):** `/aimi:plan` populates `metadata.designBundle` and `metadata.designTokens` fields in the generated `tasks.json` when a design bundle is detected at planning time.
- **story-executor design-bundle fidelity guidance (US-009):** Story-executor reads `metadata.designBundle` and `metadata.designTokens` from `tasks.json` and surfaces spec-aware read order with rule-ID citation in its implementation guidance.
- **`/aimi:deepen` spec cross-reference (US-011):** `/aimi:deepen` now cross-references BusinessSpec and DesignSpec when enriching story acceptance criteria, citing spec rule IDs in the enriched output.

## [1.71.0] - 2026-04-29

### Added

- **`vary ui` override keyword (US-005):** Typing `vary ui` in a brainstorm visual question opts into UI-token variation for the next variant axis selection, activating color, typography, radii, and surface axes even when project tokens are present.

### Changed

- **brainstorm visual variants (US-005):** When project design tokens are present, variant axes now default to UX-branch axes (layout, hierarchy, flow) instead of UI-branch axes. UI-branch axes (color, typography, radii, surface) activate only on full token-extraction fallback or explicit `vary ui` override. This preserves prior behavior for projects without tokens while improving consistency for token-backed design systems.

## [1.70.0] - 2026-04-29

### Added

- **design references (US-001–US-009):** 12 new reference documents ported from Anthropic Impeccable v3.0.5 into `skills/frontend-design/references/`: `brand.md`, `product.md`, `color-and-contrast.md`, `typography.md`, `spatial-design.md`, `motion-design.md`, `responsive-design.md`, `ux-writing.md`, `interaction-design.md`, `cognitive-load.md`, `heuristics-scoring.md`, `personas.md`.
- **design references index:** `skills/frontend-design/references/index.md` — registry mapping each reference slug to its file and canonical trigger phrase for use by brainstorm lazy-load hooks.
- **commands (`/aimi:design:shape`, `/aimi:design:craft`, `/aimi:design:critique`, `/aimi:design:audit`, `/aimi:design:polish`):** 5 new design slash commands under `commands/design/` covering idea shaping, component crafting, design critique, accessibility/heuristics audit, and visual polish workflows.
- **brainstorm lazy-load hooks:** `loaded_design_refs[]` working memory array plus 4 hook points in `skills/frontend-design/SKILL.md` enabling on-demand reference loading during brainstorm sessions without pre-loading all 12 documents.

### Changed

- **skill (`frontend-design` SKILL.md):** Full rewrite — 42 lines expanded to ~161 lines. Integrates shared design laws (Gestalt, Fitts, Hick, aesthetic-usability effect), absolute bans list, and AI-slop detection test. Now references the 12 ported design documents via the lazy-load hook system.

### Security

- Design reference content ported under Apache-2.0 license from Anthropic Impeccable v3.0.5. License attribution preserved in reference file headers.

### Notes

- US-012: CLI test suite (325 tests), YAML frontmatter smoke checks (SKILL.md + 5 commands/design/*.md), and references/ token budget (1657/3000 lines) all verified prior to release. Fixed invalid YAML frontmatter in `commands/design/craft.md` and `commands/design/shape.md` (unquoted `description` values containing `: ` sequences).

## [1.69.1] - 2026-04-29

### Fixed

- **installer (install.sh — US-010):** `install_commands()` now translates subdirectory commands (e.g., `commands/design/*.md`) in addition to top-level `commands/*.md`. Previously only flat files were processed; `commands/design/{shape,craft,critique,audit,polish}.md` were silently dropped during OpenCode install. Subdirectory commands are flattened to `aimi/design-<name>.md` using colon-to-hyphen normalisation of the `name:` frontmatter field. The `references/` subdirectory is skipped (it holds shared reference docs, not commands). Dry-run mode now lists all translated commands, including subdirectory ones.

## [1.69.0] - 2026-04-29

### Changed

- execute: every story now runs in its own git worktree — single-story waves no longer skip worktree creation; the N=1 fast-path was deleted so the multi-story flow handles all wave sizes uniformly
- Default metadata.maxConcurrency raised from 4 to 5; selection within a wave remains deterministic (tasks.json file order via $AIMI_CLI list-ready)

## [1.68.3] - 2026-04-28

### Fixed

- **commands (CLI path resolution):** Replaced the CWD-relative `Read \`references/cli-path-resolution.md\`` loader with the absolute `Read \`${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md\`` form across the seven commands that resolve `$AIMI_CLI` (init, brainstorm, plan, execute — both CLI and Worktree Manager reads — next, open-pr, status). The relative form failed when commands ran from a project CWD outside the plugin tree, causing the agent to glob the project for `cli-path-resolution.md`.
- **command (`/aimi:init`):** Widened `allowed-tools` from the scoped `Read(references/cli-path-resolution.md)` to bare `Read`, matching the pattern used by the other six commands. The scoped form prevented the new absolute-path read from being authorized.
- **install (OpenCode):** `install.sh translate_command_body()` now rewrites `${CLAUDE_PLUGIN_ROOT}` to `${AIMI_PLUGIN_DIR}` so translated commands resolve under OpenCode's plugin layout (where `CLAUDE_PLUGIN_ROOT` is undefined). Mirrors the existing `CLAUDE_CONFIG_DIR` rewrite.

## [1.68.2] - 2026-04-27

### Removed

- **docs (README):** Dropped the `## Version History` section and its TOC entry. CHANGELOG.md is now the single source of truth for version history; the README links to it from a one-line pointer at the end of Troubleshooting.

## [1.68.1] - 2026-04-27

### Added

- **docs (README):** New Troubleshooting subsection "Inspecting an agent-browser headed session" documenting how to attach Chrome DevTools to a running `agent-browser --headed` session via `--remote-debugging-port=9222` and `chrome://inspect/#devices`. Useful for debugging Visual Follow sessions launched by `/aimi:execute`.

## [1.68.0] - 2026-04-27

### Removed

- **command (`/aimi:swarm`):** Deleted `/aimi:swarm` and its `plugins/aimi-engineering/commands/swarm.md` body. Parallel execution is now handled exclusively by `/aimi:execute` via git worktrees (no Docker dependency).
- **skill (`orchestrating-swarms`):** Deleted the entire `plugins/aimi-engineering/skills/orchestrating-swarms/` directory (7 files). The skill was only referenced by `/aimi:swarm` and was already labeled "Disabled (Reference Only)" in the README.
- **hook patterns:** Removed Docker auto-approve patterns (13–18) from `plugins/aimi-engineering/hooks/auto-approve-cli.sh` — they exclusively approved `aimi-swarm-*` and `aimi-*` container commands.
- **OpenCode install:** `install.sh` no longer grants Docker permissions in `opencode.json` (the swarm-only Docker allow rules are removed from `install_permissions`).

### Migration

Users running `/aimi:swarm <args>` should switch to `/aimi:execute`, which now provides the same parallel-wave execution via worktrees without needing Docker or `ANTHROPIC_API_KEY` in environment.

## [1.67.1] - 2026-04-27

### Changed

- **docs (AGENTS.md):** Extended AGENTS.md output compression with caveman-derived rules (Guzik 2026 benchmark; expected 10-20% reduction on spawned-agent summary returns). New blocks: article-elision (drop a/an/the in bullet leads), sentence-pattern compression (convert passive constructions to active telegraphic form), short-synonyms substitution table, and scope-guard (suppresses rules when user requests verbose output or full prose).

## [1.67.0] - 2026-04-22

### Added

- **tasks schema (US-001):** New optional `skills[]` field on user story objects. The validator accepts an array of skill-name strings (e.g. `["dhh-rails-style", "frontend-design"]`); stories without `skills[]` are valid and behave identically to pre-1.67. Stories can now declare skills they need (e.g. dhh-rails-style, frontend-design) — the executor injects SKILL.md contents into the worker prompt, keeping the base template lean while giving each story targeted conventions.
- **command (aimi:execute — US-002):** Executor skill injection. When a story carries a non-empty `skills[]` array, `/aimi:execute` resolves each named skill's `SKILL.md` from the plugin's `skills/` directory and injects its contents into the Task agent prompt ahead of the story body. Skills that cannot be resolved are logged as warnings and skipped; execution continues.

### Changed

- **command (aimi:plan — US-003):** `plan.md` heuristic auto-populates `skills[]` from file patterns detected in the story's `implementation.files` list. Rails/Ruby paths → `dhh-rails-style`; React/Next.js/CSS/Tailwind paths → `frontend-design`. The field is omitted when no patterns match, preserving backwards compatibility.

## [1.66.0] - 2026-04-22

### Added

- **cli (aimi-cli.sh):** New `--base <branch>` flag on the `setup-branch` subcommand. Callers can now specify an explicit base branch (e.g., `aimi-cli.sh setup-branch --base main`) instead of relying solely on automatic default-branch detection. When omitted, behavior is identical to pre-1.66: the default branch is detected via `detect-default-branch`. Enables `/aimi:execute` to thread the user's chosen base branch all the way down to the worktree creation call.

### Changed

- **command (aimi:execute):** Interactive base-branch selection at Step 1.6. When the current branch has unmerged work, `/aimi:execute` now asks whether to stack on the current branch or start fresh from the default branch. Previously auto-stacked. In agent mode (`AIMI_AGENT_MODE=true`, `CI=true`, or no TTY) the pre-1.66 automatic stacking behavior is preserved — no prompt is emitted and the current branch is used as-is.

## [1.65.0] - 2026-04-22

### Added

- **command (aimi:init):** New `/aimi:init` slash command that primes the global CLI path cache (`~/.claude/aimi-engineering-cli-path`) on demand. After priming, subsequent `/aimi:*` commands skip the Layer 2 glob in `references/cli-path-resolution.md` until the cache goes stale. Users can re-run it anytime to repair a broken cache.
- **cli (aimi-cli.sh):** New `prime-cache` subcommand that actively populates the global CLI path cache with a structured JSON contract `{status, path, host, version, message}`. Under Claude Code it globs `~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`, validates the resolved path against the same pattern used by `read_global_cli_cache`, and writes atomically. Under OpenCode it writes `$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh` after verifying the script is executable — diverging from `cmd_check_version`'s short-circuit because the whole point of `prime-cache` is to populate the cache, not defer to the converter. Status values: `ok`, `already_current`, `not_found`, `error`. Exempt from `find_aimi_root()` so it runs from any directory, including fresh installs with no `.aimi/`.

### Changed

- **installer (install.sh):** `install.sh --to opencode` now primes the global CLI path cache post-install by invoking `aimi-cli.sh prime-cache` after the shell-profile env var is set. This writes `~/.claude/aimi-engineering-cli-path` at install time so the first `/aimi:*` command after install skips the Layer 2 glob entirely. Failure is non-fatal — the installer warns and continues. `./install.sh --uninstall --from opencode` now removes the global cache file via `rm -f` (best-effort; dry-run logs `Would remove ...` only when the file exists).

### Notes

- The global cache file `~/.claude/aimi-engineering-cli-path` is now written at install time (OpenCode via `install.sh`) or on demand (Claude Code via `/aimi:init`). Layer 2 glob-and-cache-update logic in `references/cli-path-resolution.md` remains as a rescue fallback when the cache is missing or stale — no change to the 4-layer resolution contract.

## [1.64.0] - 2026-04-21

### Added

- **command (aimi:brainstorm — US-002):** Pre-flight browser availability check with chat output. Before the first visual question, `/aimi:brainstorm` runs `command -v agent-browser` plus a `DISPLAY`/`CI` heuristic once and echoes `Visual preview: ready` or `Visual preview: disabled (<reason>)` to chat. Result is cached in working memory so subsequent visual questions do not re-check.
- **command (aimi:brainstorm — US-004):** `AIMI_BRAINSTORM_DEBUG=1` environment variable support. When set, emits `[brainstorm-debug] <context>: <value>` diagnostic lines to chat at four decision points (topic slug, category classification, browser attempt, variant choice). A new "Environment Variables" section in `brainstorm.md` documents the flag alongside `AIMI_AGENT_MODE`.
- **command (aimi:brainstorm — US-005):** `show variants` override keyword. Typing the phrase in a brainstorm topic or reply forces the next question to render HTML variants regardless of its category classification. Echoes `Visual override active — rendering variants for next question` to chat once per trigger.
- **command (aimi:brainstorm — US-003):** Chat-surfacing for browser skip/degradation events. `agent-browser unavailable`, `agent-browser session lost`, and `agent-mode: picker unavailable — auto-selected variant A` are now echoed to chat once per session (guarded by `echoedBrowserUnavailable`, `echoedSessionLost`, `echoedPickerUnavailable` flags), in addition to being logged to the brainstorm document.

### Changed

- **command (aimi:brainstorm — US-001):** Step 4 retry logic improved. A failed session reload now retries once with a `-2` session-name suffix before degrading to text-only, matching the canonical flow in `references/visual-variants.md` "Fallback: mid-session crash" section. Previously degraded on first failure.

## [1.63.0] - 2026-04-20

### Added

- **cli (aimi-cli.sh):** New `detect-interactivity` subcommand that resolves the active interactivity mode from environment: prints `agent` when `AIMI_AGENT_MODE=true`, `CI=true`, or stdin is not a TTY; prints `picker` otherwise. Exempt from `find_aimi_root()` since it reads only env vars — usable by commands before any `.aimi/` state exists. Documented in `cmd_help` usage.
- **reference (interactivity.md):** New `commands/references/interactivity.md` defines the two-mode contract (`picker`, `agent`), the picker option-format rules (lettered labels, escape hatch on last option, 2–6 options cap), the agent auto-pick log-line format (`agent-mode: <site-id> auto-<action>`), and a 3-step checklist for adding new question sites. Single source of truth for all commands that ask the user questions.
- **command (aimi:brainstorm):** New Step 0 (Resolve CLI Path) + Step 0.5 (Resolve Interactivity Mode) preamble sets `INTERACTIVE_MODE` once per invocation via `$AIMI_CLI detect-interactivity`. Phase 2 main batch questions now branch on `INTERACTIVE_MODE`: `picker` emits one `AskUserQuestion` call per question with lettered options + `Other` free-form escape (replaces the former single prose block with shorthand parser); `agent` auto-selects option A and logs one line per question. Agent-mode fallback notes added to the remaining 3 picker sites (Phase 0 plan-redirect auto-proceeds to `/aimi:plan`; Phase 3 approach auto-picks option A; Phase 4 open questions defer to a `Deferred Questions` section). Combined with the existing visual-variant fallback (L335) and the new Phase 2 branch, all 7 user-facing question sites now have deterministic agent-mode behavior.

### Changed

- **installer (install.sh):** AskUserQuestion translation no longer degrades to prose-in-chat. OpenCode ships a native `question` tool ([docs/tools](https://opencode.ai/docs/tools/)) with header + lettered options + custom-text input; the translator now maps `Use **AskUserQuestion**` → `Use the **question** tool`, `Use AskUserQuestion` → `Use the question tool`, `via AskUserQuestion` → `via the question tool`, and the bare `AskUserQuestion` fallback → `the question tool`. OpenCode users get the same picker UX as Claude Code users across every command that uses the pattern (brainstorm, swarm, plan, task-planner). Permission-gated by `"question"` in `opencode.json` (default: `"ask"`).

### Fixed

- **command (aimi:brainstorm):** Shorthand answer parser (`"1A, 2C, 3B"`) removed from Phase 2 — it was a workaround for the missing picker on the main batch and no longer applies when every question is a picker call. Pre-existing visual-variant fallback log line changed from `agent-mode: AskUserQuestion unavailable` to `agent-mode: picker unavailable` so it stays grammatical after OpenCode translation.

### Tests

- **test-aimi-cli.sh:** Three new tests covering `detect-interactivity`: `test_detect_interactivity_agent_mode_env` (AIMI_AGENT_MODE=true overrides), `test_detect_interactivity_ci_env` (CI=true triggers agent mode), `test_detect_interactivity_non_tty` (no TTY on stdin triggers agent mode). Baseline raised from 283/0 to 286/0.

## [1.62.0] - 2026-04-20

### Added

- **schema (tasks.json):** New optional `metadata.prototypePaths[]` field — a deduplicated array of relative paths to prototype HTML variants and the `<topic-slug>-tokens.json` sidecar. Schema version stays at `3.2` (additive optional field, follows the `researchPaths[]` precedent).
- **command (aimi:plan):** Phase 0 Prototype Context now collects successfully loaded prototype paths (non-dropped after the 200 KB aggregate cap, non-missing on disk) into `resolvedPrototypePaths`; Phase 4 Derive Metadata persists them as `metadata.prototypePaths[]`. Full-stack split writes the same array to both frontend and backend tasks.json files. The Aimi-branded report surfaces `Prototypes: [N] variant file(s) registered` when non-empty.
- **command (aimi:execute):** New Step 3.5 Load Prototype Context reads `metadata.prototypePaths[]` and builds `PROTOTYPE_CONTEXT` — `.html` files wrap as `<prototype_html label="X" path="...">` blocks with tag-breakout escape, `.json` sidecars wrap as `<prototype_tokens>` blocks. Re-applies the 200 KB aggregate cap at execute time; skips missing files with a warning line. `PROTOTYPE_CONTEXT` is injected into all three worker-prompt assembly sites (single-story wave, multi-story parallel wave, paired-split sub-Tasks) immediately after `DESIGN_CONTEXT`, omitted when empty. Start report surfaces `Prototype context: [N] variant(s) loaded` when variants are present.
- **skill (story-executor):** Prompt Template and Compact Template both define a `<prototype_context>` XML section (after `<design_context>`) so spawned workers know how to consume prototype variants when threaded.
- **cli (aimi-cli.sh — archive-task):** Cleans `metadata.prototypePaths[]` files alongside `researchPaths[]` using an identical loop (relative-path resolution from PROJECT_ROOT, `validate_path_in_project` gate, `[ -e ]` missing-file tolerance, `rm -f`). Output JSON gains a `prototypeCleaned` counter field on the existing single `jq -n` call.
- **tests (test-aimi-cli.sh):** Four new archive-task tests covering prototype cleanup: `test_archive_task_with_prototype_paths`, `test_archive_task_without_prototype_paths`, `test_archive_task_missing_prototype_files`, and `test_archive_task_both_research_and_prototype_paths`.

### Security

- **command (aimi:plan):** Phase 0 Prototype Context now validates that each resolved absolute path stays within AIMI_ROOT before reading — paths escaping via `../` or symlink targets are rejected with `prototype <path> rejected — path outside project root` and skipped (plan does not abort for a bad path). Prevents a malicious brainstorm with a `prototype: ../../etc/passwd` frontmatter key from injecting arbitrary file contents into the planning context.

## [1.61.1] - 2026-04-17

### Changed

- **command (aimi:deepen):** Research file naming standardized to the `brainstorm` and `plan` canonical shape `.aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-<story.id>-codebase.md`. Deepen now derives `TOPIC_SLUG` from `metadata.branchName` (stripping the `type/` prefix), generates a single `RUN_TS` via `date +%H%M%S` and reuses it across every parallel researcher, and passes the path via a structured `outputPath:` field so researcher agents write to the exact canonical location (the researcher Output Contract honors caller-supplied `outputPath:`). Same-run grouping now matches brainstorm/plan.

### Fixed

- **command (aimi:deepen):** Step 4.5 appends every written research path to `metadata.researchPaths[]` (deduplicated). Previously deepen's research files leaked — `$AIMI_CLI archive-task` reads `researchPaths[]` to clean up, but deepen never wrote into the array, so its files persisted across archive cycles.

## [1.61.0] - 2026-04-17

### Added

- **reference (visual-variants.md):** New `commands/references/visual-variants.md` — Alpine.js switcher skeleton with topic-slug sanitization and HTML-escape rules (including JS-context escaping note for future `x-data` embeddings), Tailwind CDN offline behavior, 2–4 variants-per-question constraint, and append semantics for multi-question sessions.
- **reference (visual-variants.md — Token Extraction):** 6-source precedence list for design-token resolution: `tailwind.config.{js,ts}` → `theme.{ts,js,tsx,jsx}` → CSS custom properties → `_variables.scss` → MUI `createTheme` → Chakra `extendTheme`. **Eight token families** covered: colors, fonts, radii, spacing, shadows, transitions, screens (breakpoints), and dark-mode. Per-family independent resolution, Tailwind CDN defaults fallback with in-document warning, parse errors silently skip the source and never abort brainstorm.
- **reference (visual-variants.md — Token Sidecar JSON):** Extraction writes a machine-readable `<topic-slug>-tokens.json` alongside the HTML variants file, recording resolved values, per-family source attribution, and fallback list. Consumed by `/aimi:plan` (implementation context) and `/aimi:review` (fidelity checks).
- **reference (visual-variants.md — Structural Guidance):** Canonical-shape taxonomy (form/card/nav/hero/modal/table/layout-with-sidebar). Variants in the same question share shape, density, and primary-action copy; direction varies via typography, color, radius, shadow, and density. Tokens emitted as CSS custom properties on `:root` (plus `.dark :root` for dark-mode strategy `class`) and referenced via Tailwind arbitrary-value syntax.
- **reference (visual-variants.md — Browser Session Lifecycle):** Lazy open, reuse-with-reload (idempotent on re-runs), close-on-completion; missing-skill / missing-display / CI fallback degrades to text-only.
- **command (aimi:brainstorm — Phase 2):** Visual Variant Rendering phase with optional Component-Shell Scan (samples 2–3 representative component files to surface wrapper-tag and class-recipe idioms for Structural Guidance). Variant Selection sub-step offers `AskUserQuestion` options; **agent-mode fallback** auto-selects Variant A when `AskUserQuestion` is unavailable (non-interactive hosts). Variant Persistence stores `chosen_variant_slug` and records `selectedVariants` in brainstorm frontmatter. Non-visual categories remain text-only throughout.
- **command (aimi:brainstorm — Phase 5):** Cleanup step prunes the scratch prototype file after clean session completion; standalone variant files and the tokens sidecar are preserved.
- **command (aimi:plan — Phase 0):** Prototype Context sub-step — parses brainstorm `prototype:` frontmatter and `## Prototype` section; loads the `<topic-slug>-tokens.json` sidecar; sanitizes embedded `</prototype_html>` sequences before wrapping; **200 KB aggregate cap** across all loaded blocks (drops in reverse label order with warning); injects `<prototype_html>` block and tokens JSON into researcher and decomposition prompts so implementation agents inherit the visual intent.
- **command (aimi:review):** Prototype Design Context sub-step — when a PR's branch has a matching brainstorm, loads the prototype HTML and tokens JSON and threads them into architecture, simplicity, and language-specific reviewers so fidelity against the chosen variant and target-project tokens can be verified.

### Changed

- **install.sh:** `install_plugin_source` dry-run branch simplified — removed the per-file enumeration of `commands/references/` (cosmetic only; `cp -R` already copies the directory).

## [1.60.3] - 2026-04-16

### Changed

- **skill (story-executor):** Worker prompt template (both full and compact variants) now explicitly instructs the spawned agent to apply output compression rules from `AGENTS.md`. Previously the rules were only loaded passively through project guidelines; the new `<output_rules>` section in the full template and the appended sentence in the compact template ensure the directive reaches the agent even when `AGENTS.md` is missing or in edge-case multi-repo scenarios.
- **docs (plugin CLAUDE.md):** Hedge unverified token-reduction claims (~33% inline-story savings, ~60% compact-template savings) — replaced with qualitative descriptions noting the savings have not been benchmarked. Applies to both `plugins/aimi-engineering/CLAUDE.md` Performance Guidelines and the Compact Template blockquote in `skills/story-executor/SKILL.md`.

## [1.60.2] - 2026-04-16

### Removed

- **plugin manifest:** Remove local-only `penpot` MCP server entry from `mcpServers` (pointed at `http://localhost:4401/mcp`, not suitable for distribution).

## [1.60.1] - 2026-04-16

### Changed

- **command (aimi:open-pr):** Document that the command does not read `CLAUDE.md`/`AGENTS.md` and point users to `.github/pull_request_template.md` for project-specific PR structure (honored automatically by `gh pr create`). No behavior change.

## [1.60.0] - 2026-04-16

### Changed

- **command (aimi:open-pr):** PR title and body are now derived from git commits and the diff against the base branch instead of `tasks.json`. Title comes from the first commit subject on the branch (fallback: current branch name). Body replaces the former `Problem`/`Solution`/`Stories Completed`/`Testing` sections with `Summary` (aggregated commit bodies), `Changes` (commit subjects as bullets), and `Files Changed` (git diff --stat). `tasks.json` is only read inside the conditional `Backend Implementation Spec` block (requires `metadata.frontendOnly` AND `metadata.backendSpec`); when no tasks file is present or metadata lookup fails, that block is silently skipped and PR creation still succeeds.

## [1.59.1] - 2026-04-15

### Fixed

- **cli**: Context-aware CLI path resolution — Layer 0 (`AIMI_PLUGIN_DIR`) is now skipped when running inside Claude Code (`CLAUDECODE=1`), ensuring the Claude Code cache directory is always used instead of the stale OpenCode install path
- **cli**: `check-version --fix` and `cleanup-versions` no longer bail early with "managed by converter" when inside Claude Code, enabling self-heal after plugin updates
- **cli**: `read_global_cli_cache` and `read_global_worktree_cache` reject OpenCode-style cached paths when inside Claude Code, preventing split-brain version resolution

## [1.59.0] - 2026-04-15

### Changed

- **agents (aimi-lint, aimi-learnings-researcher):** Remove hardcoded model: haiku; both agents now inherit model from calling context

## [1.58.2] - 2026-04-15

### Added

- **cli**: `archive-task` now deletes research files listed in `metadata.researchPaths` — reads each path, resolves relative paths from `PROJECT_ROOT`, validates with `validate_path_in_project`, checks existence, and deletes with `rm -f`; missing files are silently skipped
- **cli**: JSON output of `archive-task` now always includes `researchCleaned` integer field (0 when no research files were present or none existed)
- **tests**: Three new tests for archive-task research cleanup: with researchPaths, without researchPaths (researchCleaned 0), and with missing research files (silent skip)

## [1.58.1] - 2026-04-15

### Added

- **schema**: Add `researchPaths` (string[]) metadata field to task-format-v3.md — tracks research files generated during planning so archive-task can clean them up; omitted when `researchDepth` is `skip` or no files written
- **planner**: Phase 4 Derive Metadata now includes `researchPaths` bullet instructing the orchestrator to collect paths from Phase 1 and Phase 1.5b research agents
- **docs**: CLAUDE.md key fields summary updated with `researchPaths[](optional)` after `maxConcurrency`

## [1.58.0] - 2026-04-15

### Changed

- **research**: Unify research file naming with run discriminator — all four research agents (codebase, learnings, best-practices, framework-docs) now use `YYYY-MM-DD-<topicSlug>-<HHmmss>-<short-name>.md` pattern
- **planner**: Generate `RUN_TS=$(date +%H%M%S)` once in plan.md Phase 1 and pass it to all agent `outputPath` parameters so same-day re-runs produce separate files
- **brainstorm**: Phase 1b now generates `RUN_TS` and specifies explicit `outputPath` for each research agent instead of relying on agent Output Contract defaults
- **task-planner**: SKILL.md and pipeline-phases.md agent prompts updated to use `outputPath` with the new `YYYY-MM-DD-[topicSlug]-[RUN_TS]-<short-name>.md` pattern
- **research agents**: Output Contract updated to document that caller-specified `outputPath` takes precedence over agent-derived slug/timestamp; short names in frontmatter updated to `codebase`, `learnings`, `best-practices`, `framework-docs`

## [1.57.0] - 2026-04-15

### Added

- **cli**: Add `version` subcommand that prints the plugin version from plugin.json
- **tests**: Add version command test validating semver output

## [1.56.0] - 2026-04-15

### Fixed

- **tests**: Unset `AIMI_PLUGIN_DIR` before version staleness and global cache tests to prevent compound-plugin converter from short-circuiting test assertions

## [1.55.0] - 2026-04-15

### Fixed

- **cli**: Add `--project` flag to `setup-branch` and `detect-default-branch` commands for multi-repo layouts where AIMI root is not a git repository
- **cli**: Add git-repo guard to both commands with clear error message instead of cryptic `fatal: not a git repository`
- **execute**: Detect multi-repo layout (AIMI root is not a git repo) and skip main repo branch setup, handling branch creation per-project instead
- **planner**: Defer default branch detection to per-project when AIMI root is not a git repo

### Added

- **tests**: Add `--project` flag and non-git-repo error tests for `setup-branch`

## [1.54.0] - 2026-04-14

### Fixed

- **planner**: Add missing auto-scan for git repos step in plan.md Phase 1, syncing with SKILL.md
- **planner**: Promote `project` field assignment to explicit numbered step 6 in Phase 3, preventing model from skipping multi-repo project assignment

## [1.53.0] - 2026-04-14

### Changed

- **brainstorm**: Structured consolidation schema in Phase 1.6 with adaptive return caps tied to researchDepth
- **deepen**: Research agents write findings to `.aimi/research/` files instead of returning bulk text inline
- **deepen**: Adaptive return caps tied to researchDepth — lower depths produce shorter agent output
- **planner**: Default researchDepth inherited through planning pipeline
- **review**: Protected artifacts updated for `.aimi/research/` output path

## [1.52.0] - 2026-04-14

### Added

- **agents**: AGENTS.md with context-adaptive compression rules for spawned agent output

### Changed

- **cli**: Deduplicated CLI path resolution to eliminate redundant path computations
- **story-executor**: XML tags in story executor prompts for structured content boundaries
- **story-executor**: Compact prompt pattern — subsequent stories use condensed static sections (~60% token reduction)
- **git-worktree**: Progressive disclosure — worktree skill surfaces details on demand instead of upfront
- **task-planner**: Progressive disclosure — planner skill surfaces details on demand instead of upfront

## [1.51.0] - 2026-04-14

### Fixed

- **execute**: Visual verification for worktree stories now runs post-merge instead of inside isolated worktrees where dev server cannot see changes

## [1.50.0] - 2026-04-14

### Added

- **brainstorm**: Design-thinking integration for visual features — auto-detect UI keywords in feature descriptions, inject Aesthetic Direction and Differentiation topic categories into Phase 2, conditional Design Decisions section in brainstorm document template, design context passed to story executors
- **planner**: Auto-skip implementation scope question for non-app features (plugin changes, refactors, CLI tools, docs) — uses keyword detection with conflicting-signals precedence

## [1.49.0] - 2026-04-14

### Fixed

- **execute**: Visual-follow browser detection now type-guards `verification` field — prevents silent failure when verification is a string instead of object, warns about malformed fields
- **planner**: Added explicit "verification MUST be an object" warnings with JSON examples to all planner instruction files (SKILL.md, plan.md, pipeline-phases.md, story-decomposition.md)

### Changed

- **schema**: `backendSpec.businessContext` expanded from string to structured object with `summary`, `userRoles[]`, `constraints[]`, `assumptions[]`, `successCriteria[]` sub-fields
- **open-pr**: Backend Implementation Spec "Business Context" section now renders structured sub-sections (User Roles, Constraints, Assumptions, Success Criteria) with legacy string fallback
- **planner**: Phase 4 businessContext generation guidance updated with explicit extraction instructions for each sub-field

## [1.48.0] - 2026-04-14

### Added

- **open-pr**: GitHub issue creation with backend spec for frontend-only PRs — after PR creation, attempts `gh issue create` with Backend Implementation Spec body, links issue to PR via `gh pr edit`, graceful degradation on failure (warning only, PR unaffected)

## [1.47.0] - 2026-04-14

### Added

- **execute**: Multi-file auto-detection (Step 0.9) — uses `find-tasks-all` to discover all task files, auto-detects paired `*-frontend-tasks.json` and `*-backend-tasks.json` with matching date+feature prefix, spawns two parallel foreground Tasks with worktree isolation and `init-session --file`, aggregated completion report showing per-file results
- **open-pr**: Backend Implementation Spec section in PR body for frontend-only prototypes — when `frontendOnly` is true and `backendSpec` exists, appends Endpoints, Data Models, Business Rules, and Business Context subsections after Testing (deterministic rendering, no LLM generation)

## [1.46.0] - 2026-04-14

### Added

- **planner**: Split task file generation — full-stack scope produces separate `*-frontend-tasks.json` and `*-backend-tasks.json` with independent branch names, dependency graphs, and wave numbers
- **planner**: `backendSpec` metadata generation — frontend-only scope synthesizes `endpoints`, `dataModels`, `businessRules`, and `businessContext` from story analysis
- **planner**: Per-file Phase 4.5 validation using `init-session --file` for independent validation of each split file

## [1.45.0] - 2026-04-14

### Added

- **cli**: `find-tasks-all` subcommand — returns newline-separated list of all *-tasks.json files sorted by modification time for multi-file discovery
- **cli**: `--file <path>` flag for `init-session` — allows specifying a tasks file directly instead of auto-detecting the most recent one, with existence and pattern validation
- **story-executor**: Headed mode context and visual-follow session reuse — adds `[HEADED_MODE]` placeholder, conditional visual verification branches for headed (session reuse, no close) vs headless (executor-owned lifecycle) modes

## [1.44.0] - 2026-04-14

### Added

- **execute**: Visual-follow session prompt (Step 0.7) — detects frontend stories with `verification.strategy == "visual"`, prompts user to follow implementation in a headed browser, manages `agent-browser` session lifecycle around the wave loop

## [1.43.1] - 2026-04-09

### Fixed

- **cli**: Improved `setup-branch` comment clarity — distinguish "on default branch" vs "merged into default" cases

### Changed

- **test**: Added test for merged-but-not-on-default branch scenario in `setup-branch`, updated test descriptions for accuracy

## [1.43.0] - 2026-04-09

### Added

- **cli**: `setup-branch` subcommand — deterministic branch creation/checkout with JSON output, supports local/remote/new branch detection with merge-status-aware base selection
- **hooks**: `setup-branch` added to auto-approve whitelist in `auto-approve-cli.sh`

## [1.42.0] - 2026-04-08

### Changed

- **execute**: Branch creation from `origin/[DEFAULT_BRANCH]` is now conditional — only when the current branch has been merged into the default branch; otherwise creates from current HEAD

## [1.41.0] - 2026-04-08

### Added

- **cli**: `detect-default-branch` subcommand — dynamically detects repository default branch with `git remote show origin` primary and `git symbolic-ref` fallback, cached in `.aimi/default-branch`
- **cli**: `list-archivable` subcommand — returns JSON array of task files where all stories are completed or skipped
- **cli**: `archive-task` subcommand — moves completed task file + linked brainstorm to `.aimi/archive/` with collision handling
- **execute**: Archival prompt at entry point (Step 0.5) — checks for completed task files via `list-archivable` and offers to archive them before starting execution
- **execute**: Branch freshness check (Step 1.5) — fetches origin and detects default branch via `$AIMI_CLI detect-default-branch` before branch setup
- **plan**: Branch freshness check — fetches origin before Phase 0 to ensure local refs are current, with offline warning fallback
- **plan**: CLI path resolution using 4-layer strategy and `detect-default-branch` for dynamic default branch detection
- **review**: Dynamic default branch detection using `git symbolic-ref`, replacing hardcoded `main`

### Changed

- **execute**: New branches now created from `origin/[DEFAULT_BRANCH]` instead of current HEAD, ensuring fresh base
- **execute**: Commit counting in Step 5 uses dynamically detected default branch instead of hardcoded `main`
- **cli**: `clear-state` now also removes `default-branch` cache file

## [1.40.0] - 2026-04-08

### Changed

- **branding**: Updated author to "Aimi — Autonomous Code Companion" in plugin.json and marketplace.json

## [1.39.0] - 2026-04-07

### Added

- **story-executor**: Visual verification section in prompt template — conditional agent-browser flow for stories with `verification.strategy: visual` and `verification.url`, advisory only (failures do not block commits)

## [1.38.0] - 2026-04-07

### Added

- **execute**: Commit verification after Task execution — captures HEAD SHA before each Task spawn and compares after success; stories with no commit are marked as failed with cascade-skip instead of silently completing
- **execute**: Parallel worktree commit verification — captures base SHA per project group before worktree creation, filters out no-commit stories before merge step

## [1.37.0] - 2026-04-06

### Added

- **commands**: `/aimi:open-pr` command for opening pull requests from executed task branches with structured PR descriptions

## [1.36.0] - 2026-04-02

### Added

- **schema**: `researchDepth` metadata field for controlling research thoroughness (quick, standard, deep)
- **schema**: `wave` field on stories for explicit wave assignment and parallel execution grouping
- **schema**: `implementation` object on stories with `files`, `approach`, and `verify` fields for structured implementation guidance
- **schema**: `verification` object on stories with `strategy`, `status`, `url`, and `expect` fields for post-execution verification
- **schema**: `gate` object on stories with `type`, `status`, `prompt`, and `options` fields for decision/action/verify gates
- **aimi-cli**: `gate-pass` command to resolve a gate as passed
- **aimi-cli**: `gate-fail` command to resolve a gate as failed
- **aimi-cli**: `validate-waves` validator for checking wave assignment consistency and dependency ordering
- **aimi-cli**: `update-field` command for updating nested story fields (e.g., `verification.status`)
- **execute**: Gate handling in wave execution loop — decision gates block story start with log message, action gates log post-completion with dependent pause, verify gates log as non-blocking
- **execute**: Gate-blocked story detection — differentiates gate-blocked from true deadlocks when no stories are ready
- **execute**: Wave summary includes gate status counts (action/verify gates pending)
- **execute**: Completion summary includes pending gate inventory with resolution instructions
- **execute**: Executor updates `verification.status` to `passed` when story-executor reports verification success

### Changed

- **schema**: Schema version bumped from 3.1 to 3.2
- **execute**: `list-ready` gate filtering — stories with pending gates excluded from ready list
- **story-executor**: Prompt template now includes `implementation.files` (Key Files), `implementation.approach` (Approach), `implementation.verify` (Verification Command), and `verification.strategy`/`verification.expect` (Verification) sections when present in v3.2 story data
- **story-executor**: Story format summary in SKILL.md updated with `implementation` and `verification` field descriptions
- **story-executor**: execution-rules.md inline JSON example updated with `implementation` and `verification` objects

## [1.35.0] - 2026-04-02

### Added

- **brainstorm**: Parallel best-practices research in Phase 1 — spawns aimi-best-practices-researcher alongside aimi-codebase-researcher
- **brainstorm**: Decoupled specificity-skip logic — codebase and best-practices researchers assessed independently with distinct skip criteria
- **brainstorm**: Research Consolidation step (1c) merges internal patterns and external best practices, surfaces conflicts as candidate Phase 2 questions
- **brainstorm**: Graceful degradation for all 4 research permutations (both succeed, either fails/skipped, both fail)
- **brainstorm**: Approach-in-questions integration — Phase 2 includes approach selection questions when research reveals multiple valid approaches, with tradeoff hints per option
- **brainstorm**: Phase 3 Resolve Approach fallback — lightweight approach resolution only when not addressed in Phase 2, with skip conditions for already-resolved or single-obvious-approach cases
- **brainstorm**: Progressive quality gates — Research Adequacy gate (Phase 1→2), Topic Coverage gate (Phase 2→3/4), and Pre-Save Checklist (Phase 4) with conversational nudges and user override support
- **brainstorm**: Document template "Why This Approach" guidance updated for 3 resolution paths (Phase 2 questions, Phase 3 fallback, single obvious approach with justification)
- **brainstorm**: Error handling table expanded with quality gate failure scenarios and research agent failure combinations

## [1.34.0] - 2026-03-31

### Added

- **install.sh**: Full OpenCode command body translation — agent invocations rewritten for OpenCode Task tool compatibility
- **install.sh**: Skills installation (`install_skills()`) — copies SKILL.md and references to OpenCode skills directory
- **install.sh**: Nested command directories — commands installed as `commands/aimi/plan.md` for `/aimi:plan` naming
- **install.sh**: Bash permission auto-approval (`install_permissions()`) — configures opencode.json for autonomous execution
- **install.sh**: CLI path resolution rewriting — `CLAUDE_CONFIG_DIR` references replaced with `OPENCODE_CONFIG_DIR`
- **install.sh**: Error message rewriting — recovery instructions point to `./install.sh --to opencode`
- **install.sh**: AskUserQuestion fallback — replaced with natural conversation prompts
- **install.sh**: `disable-model-invocation` workaround — side-effect warning prepended to command bodies
- **install.sh**: Agent model field preservation — `model: haiku` preserved in translated agents

### Fixed

- **install.sh**: Python3 MCP fallback now uses `type: remote` instead of `type: http`

## [1.33.0] - 2026-03-30

### Added

- **install.sh**: Self-contained installer script for OpenCode cross-platform installation (no external dependencies)
- **install.sh**: Translates Claude Code commands and agents to OpenCode-native format
- **install.sh**: Automatic context7 MCP configuration in opencode.json
- **install.sh**: Uninstall support with `--uninstall` flag

### Changed

- **README.md**: Replaced compound-plugin converter instructions with install.sh usage

## [1.32.0] - 2026-03-30

### Added

- **cross-platform**: Cross-platform installation via compound-plugin converter for OpenCode, Codex, Copilot, and auto-detect
- **AIMI_PLUGIN_DIR**: Environment variable support for custom plugin directory resolution in all CLI commands
- **Layer 0**: CLI path resolution in all commands using AIMI_PLUGIN_DIR as Layer 0
- **auto-approve**: Hook patterns for Layer 0 resolution
- **tests**: Coverage for AIMI_PLUGIN_DIR paths

## [1.31.0] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — removes dependency on SKILL.md and reference files
- **brainstorm.md**: Conditional codebase research — skip research phase when no codebase context is available, reducing latency for greenfield brainstorms

### Removed

- **question-patterns.md**: Delete unused reference file from brainstorm skill — content was already inlined into brainstorm.md
- **SKILL.md (brainstorm)**: Remove reference to deleted question-patterns.md; add deprecation notice — skill is retained for reference only

## [1.30.3] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — response parsing table, formatting constraints, contextual question rules, topic addressed signals, input sanitization, pre-save checklist, and incremental validation guidance. Removes all references to the brainstorm skill, reducing token usage per session.

## [1.30.2] - 2026-03-30

### Fixed

- **execute.md, next.md, status.md, swarm.md**: Inline CLI path resolution logic — removes broken `See commands/references/cli-path-resolution.md` references that fail when plugin is installed outside the repo
- **status.md**: Remove broken `See task-format-v3.md` reference
- **SKILL.md (story-executor)**: Remove broken `See task-format-v3.md in ../task-planner/references/` reference — inline key fields with constraints instead
- **CLAUDE.md**: Remove broken `See task-format-v3.md` reference — inline schema version and key fields

## [1.30.1] - 2026-03-27

### Fixed

- **plan.md**: Inline schema v3 structure and dependsOn inference rules — planner agent no longer fails to find reference files when running outside the plugin repo
- **plan.md**: Add `validate-stories` to Phase 4.5 validation step
- **SKILL.md (task-planner)**: Remove broken relative path references to `references/task-format-v3.md`, `references/pipeline-phases.md`, and `references/story-decomposition.md` — inline essential content instead
- **SKILL.md (task-planner)**: Inline git repo auto-scan bash command (previously only in pipeline-phases.md)

## [1.30.0] - 2026-03-26

### Added

- **task-format-v3.md**: Optional per-story `project` field added to task schema v3 — specifies the relative path from AIMI_ROOT to the target git repository for multi-repo story execution
- **aimi-cli.sh**: Project field validation in `cmd_validate_stories()` — rejects absolute paths, path traversal (`..`), and shell metacharacters (`$`, `` ` ``, `;`, `|`, `&`); accepts valid relative paths; backwards compatible when project is absent
- **aimi-cli.sh**: Project field included in `cmd_list_ready --brief` output (`{id, title, priority, dependsOn, project}`)
- **next.md**: Per-story project path resolution — when a story has a `project` field, resolves PROJECT_PATH relative to AIMI_ROOT and passes it to the worker agent prompt; loads CLAUDE.md from PROJECT_PATH when set; backwards compatible when project field is absent
- **execute.md**: Per-project worktree grouping for multi-repo execution — wave stories are grouped by `project` field before worktree creation, worktrees are created within each project's git repo, merge-all runs per-project group
- **execute.md**: Per-project branch setup — creates/checks out the feature branch in each unique project's git repo when stories target different repos
- **execute.md**: Per-project guidelines loading — builds `PROJECT_GUIDELINES_MAP` from each project's CLAUDE.md/AGENTS.md
- **execute.md**: Single-story waves pass `PROJECT_PATH` to worker prompt when story has `project` field
- **execute.md**: Post-loop cleanup handles per-project worktree removal
- **plan.md / story-decomposition.md**: Multi-repo project assignment rules — planner auto-scans subfolders for git repos and assigns `project` field to stories targeting specific repositories
- **test-aimi-cli.sh**: Updated `--brief` key count assertion to include project field

## [1.29.0] - 2026-03-06

### Changed

- **cli-path-resolution.md**: Rewrite CLI resolution with three-layer strategy — global cache, zsh-safe glob fallback, per-project fallback — for reliable path discovery across shells and plugin updates
- **cli-path-resolution.md**: Add equivalent WORKTREE_MGR three-layer resolution section
- **cli-path-resolution.md**: Structure resolution as sequential commands (no compound `&&` or `||`) for auto-approve hook compatibility

### Added

- **aimi-cli.sh**: Global cache functions (`_cache_path`, `_read_cache`, `_write_cache`) for persistent CLI and worktree manager path storage across sessions
- **auto-approve-cli.sh**: Auto-approve patterns for three-layer CLI resolution commands (cache read via `cat`, Layer 1 validation, Layer 2 `bash -c` glob fallback, Layer 2 cache write via `printf`/`mv`/`chmod`, Layer 3 per-project fallback)
- **aimi-cli.sh / worktree-manager.sh**: Tests for global cache read/write/invalidation functions

## [1.28.2] - 2026-03-04

### Fixed

- **plan.md**: Add explicit US-NNN ID format step to Phase 3 story decomposition and checklist — LLM now sees the format requirement before generating IDs, not just in reference docs
- **task-planner/SKILL.md**: Add US-NNN ID format step to Phase 3 between dependency assignment and description writing
- **pipeline-phases.md**: Add US-NNN ID format to Phase 3 and Phase 4 metadata derivation
- **story-decomposition.md**: Strengthen ID format with explicit zero-padding language, regex pattern, and negative examples (US-1, story-1, S1, F1)

### Added

- **aimi-cli.sh**: New `validate-ids` command — validates all story IDs in a tasks file match `^US-[0-9]{3}[a-z]?$` regex, returns JSON with valid/count or errors array
- **plan.md**: Phase 4.5 post-generation validation step — runs `validate-ids` and `validate-deps` after writing tasks.json, with fix-and-rewrite loop if validation fails
- **task-planner/SKILL.md**: Matching Phase 4.5 post-generation validation step

## [1.28.1] - 2026-03-03

### Fixed

- **task-format-v3.md**: Enforce specific role in user story descriptions — `[user]` replaced with `[specific role]` with examples (e.g., "store admin", "developer"), preventing generic "As a user" descriptions
- **story-decomposition.md**: Add "Description Format" section with required format, good/bad examples, and 500-char limit
- **task-planner/SKILL.md**: Add description format step to Phase 3 story decomposition and checklist validation
- **plan.md**: Add description format step to Phase 3 story decomposition and checklist validation

## [1.28.0] - 2026-03-03

### Added

- **aimi-cli.sh**: New `_claude_config_dir()` helper that resolves the Claude config directory from `CLAUDE_CONFIG_DIR` env var, falling back to `~/.claude` -- validates the path is absolute when set, and strips trailing slashes
- **aimi-cli.sh**: All hardcoded `~/.claude/plugins/cache/` glob patterns in `cmd_check_version()`, `cmd_cleanup_versions()`, and help text examples now use the resolved config dir variable, enabling custom config directory support
- **test-aimi-cli.sh**: New test cases for `CLAUDE_CONFIG_DIR` support — validates custom config dir resolution, absolute path enforcement, and trailing slash stripping

### Changed

- **auto-approve-cli.sh**: Dynamic config dir resolution using `CONFIG_DIR_RE` alternation — auto-approve patterns now match both `~/.claude` and custom `CLAUDE_CONFIG_DIR` paths
- **cli-path-resolution.md**: Parameterized CLI resolution example to use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` instead of hardcoded `~/.claude`
- **execute.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`
- **swarm.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`

### Security

- **aimi-cli.sh**: Add `PROJECT_ROOT` export to `find_aimi_root()` — discovers git repository root and exports it for use by other functions
- **aimi-cli.sh**: Add `validate_path_in_project()` function — validates resolved paths are under `PROJECT_ROOT` using realpath comparison, exits with clear error if path escapes project root
- **aimi-cli.sh**: Add path validation to file operation functions (`read_state`, `write_state`, `clear_state_file`, `get_tasks_file`) — prevents directory traversal attacks
- **story-executor/SKILL.md**: Add explicit project-root boundary guardrails — agents must not read or modify files outside the git repository root, worktree paths are explicitly allowed

## [1.27.4] - 2026-03-03

### Fixed

- **execute.md**: Use task branch name as worktree branch prefix instead of hardcoded `aimi-` — worktree branches are now named `[branchName]-[storyId]` (e.g., `feat/feature-name-US-001`) for clearer branch association

## [1.27.3] - 2026-03-03

### Fixed

- **task-format-v3.md**: Add explicit validation rule requiring story `id` fields to match `^US-\d{3}[a-z]?$` format — previously only `dependsOn` references were validated, allowing LLMs to generate invalid IDs like `S1` or `F1` that are rejected by aimi-cli.sh at runtime
- **task-planner/SKILL.md**: Add checklist item enforcing US-NNN format for story IDs in the v3 Schema Validations section

## [1.27.2] - 2026-03-03

### Added

- **react-best-practices skill**: Add AGENTS.md compiled guide with all React and Next.js rules expanded
- **react-native-skills skill**: Add AGENTS.md compiled guide and move rule files into skill's own rules/ directory

### Fixed

- **marketplace.json**: Sync version to match plugin.json

## [1.27.1] - 2026-03-02

### Added

- **react-best-practices skill**: Vercel React and Next.js performance optimization guidelines — 58 rules across 8 categories covering waterfalls, bundle size, server-side performance, and client-side data fetching
- **react-native-skills skill**: React Native and Expo best practices — rules for list performance, animations with Reanimated, UI patterns, image handling, navigation, monorepo configuration, and platform-specific optimizations

## [1.27.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `get-story <id>` command for on-demand story fetching — returns full story JSON for a single story by ID, enabling lazy loading instead of bulk extraction

### Changed

- **execute.md**: Two-phase story loading — wave selection uses `list-ready --brief` (returns `{id, title, priority, dependsOn}` stubs), full story data fetched via `get-story <id>` per story after `mark-in-progress` (claim-then-fetch pattern)
- **execute.md**: Single-story wave path now follows: `list-ready --brief` -> `mark-in-progress` -> `get-story` -> build prompt -> Task
- **execute.md**: Multi-story wave path now follows: `list-ready --brief` -> select -> `mark-in-progress` all -> `get-story` each -> create worktrees -> spawn Tasks
- **execute.md**: Error handling for `get-story` failures: marks story failed, cascade-skips dependents, continues with remaining stories in wave
- **execute.md**: Multi-story wave gracefully degrades — if fetch failures reduce to 1 story, falls back to single-story path (no worktree overhead)

## [1.26.2] - 2026-03-02

### Fixed

- **execute.md**: Added `subagent_type` guard (`IMPORTANT: Do NOT change subagent_type`) to Task spawn ensuring agents never substitute `story-executor` as an agent type
- **next.md**: Added `subagent_type` guard comments to both Task spawn locations (line 86 and retry at line 122), matching the pattern in execute.md — prevents agents from substituting `story-executor` as an agent type

### Added

- **story-executor SKILL.md**: Added Tools section documenting available capabilities (Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Task) for agents spawned within story execution

## [1.26.1] - 2026-03-02

### Changed

- **Acceptance criterion limit increased from 300 to 600 chars** across CLI validation, schema docs, skill references, and command checklists (aimi-cli.sh, task-format-v3.md, story-decomposition.md, SKILL.md, plan.md, CLAUDE.md, README.md)

## [1.26.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `--brief` flag on `list-ready` command — outputs a summary line (count + story IDs) instead of full JSON story objects, reducing output for wave orchestration
- **aimi-cli.sh**: `--counts-only` flag on `status` command — returns aggregate counts (`pending`, `in_progress`, `completed`, `failed`, `skipped`, `total`) without the `userStories` array, enabling lightweight progress checks in wave loops
- **aimi-cli.sh**: `status` dispatch updated to `shift; cmd_status "$@"` pattern for flag forwarding

### Changed

- **aimi-cli.sh**: `mark-in-progress`, `mark-completed`, `mark-failed`, `mark-skipped` commands now return minimal `{id, status}` JSON confirmation instead of the full story object, reducing output noise in agent loops

## [1.25.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `find_aimi_root()` auto-discovery — CLI walks up the directory tree from CWD to find `.aimi/`, eliminating silent failures when invoked from subdirectories
- **test-aimi-cli.sh**: Test isolation via `cd "$TEST_DIR"` and `trap` cleanup; new auto-discovery tests (subdirectory + not-found)
- **cli-path-resolution.md**: CWD Auto-Discovery section documenting the new behavior
- **CLAUDE.md**: CWD contract documented in both root and plugin CLAUDE.md files

## [1.24.1] - 2026-03-02

### Added

- **auto-approve-cli.sh**: Docker auto-approve patterns (5–10) for `/aimi:swarm` commands
  - Pattern 5: `docker version` availability check
  - Pattern 6: `docker run --rm` with `--name aimi-swarm-*` and `--label aimi-swarm` (worker containers)
  - Pattern 7: `docker container ls` with `--filter name=aimi-swarm-` (container listing)
  - Pattern 8: `docker rm -f` with validated `aimi-swarm-*` container names (cleanup)
  - Pattern 9: `docker container prune -f --filter label=aimi-swarm` (safety net)
  - Pattern 10: `docker ps --filter name=aimi-*` (status/cleanup checks)
- All Docker patterns enforce aimi- prefix on container names and reject shell metacharacters

## [1.24.0] - 2026-03-02

### Changed

- **swarm.md**: Complete rewrite — replace Docker/ACP/Sysbox architecture with Team orchestration + git worktrees + simplified `docker run --rm` containers
- **swarm.md**: New frontmatter with Team/Docker/Worktree allowed-tools (removed SANDBOX_MGR, BUILD_IMG)
- **swarm.md**: Step 0 resolves only $AIMI_CLI and $WORKTREE_MGR (no SANDBOX_MGR or BUILD_IMG)
- **swarm.md**: Workers run `docker run --rm` with volume-mounted worktrees and `npx claude` inside generic `node:22-slim` image
- **swarm.md**: Team lead reads task file content and passes it in worker prompt (no reliance on task file in worktree)
- **swarm.md**: `status` subcommand reads task files directly (no swarm-state.json)
- **swarm.md**: `cleanup` subcommand removes aimi-* worktrees and Docker containers
- **swarm.md**: Merge conflict handling preserves worktrees for manual inspection

### Removed

- **docker-sandbox skill**: Removed entire skill (sandbox-manager.sh, build-project-image.sh, acp-adapter.py, Dockerfile.base)
- **swarm.md**: All references to Sysbox runtime, ACP protocol, sandbox-manager, build-project-image
- **swarm.md**: swarm-state.json state management (replaced by Team task list)
- **swarm.md**: `resume` subcommand (Team workers are foreground, no detached containers to resume)
- **swarm.md**: State reconciliation subroutine (no persistent container state to reconcile)
- **swarm.md**: Container provisioning with Sysbox-isolated containers
- **swarm.md**: ACP adapter invocation via docker exec/docker cp

## [1.23.2] - 2026-03-02

### Removed

- **auto-approve-cli.sh**: Remove swarm-* entries from CLI subcommand whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Remove Pattern 5 (SANDBOX_MGR= assignment) and Pattern 6 ($SANDBOX_MGR invocation)
- **auto-approve-cli.sh**: Remove Pattern 7 (BUILD_IMG= assignment) and Pattern 8 ($BUILD_IMG invocation)
- **auto-approve-cli.sh**: Remove Pattern 9 (docker exec aimi-* for ACP adapter)
- **auto-approve-cli.sh**: Remove Pattern 10 (docker cp for ACP payload files)

## [1.23.1] - 2026-03-02

### Changed

- **commands**: Extract CLI path resolution boilerplate to shared reference at `commands/references/cli-path-resolution.md`
- **execute.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **status.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **next.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **swarm.md**: Replace AIMI CLI resolution block in Step 0 with pointer to shared reference

## [1.23.0] - 2026-03-01

### Added

- **swarm.md**: Subscription auth detection in Step 2.5 — checks for `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
- **swarm.md**: `CLAUDE_AUTH=subscription` variable set when subscription credentials found
- **swarm.md**: `--mount-claude-config` flag passthrough to `sandbox-manager.sh create` when subscription auth detected
- **swarm.md**: Credential summary now displays `Claude` field showing subscription auth status

### Changed

- **swarm.md**: `ANTHROPIC_API_KEY` check is now a warning (not hard stop) when subscription auth is available
- **swarm.md**: Hard stop message updated to mention both `ANTHROPIC_API_KEY` and Claude config directory options
- **swarm.md**: Resume subcommand container recreation now passes `--mount-claude-config` when subscription auth detected
- **swarm.md**: Resume fan-out re-detection now includes `CLAUDE_AUTH` alongside `AUTH_METHOD`

## [1.22.0] - 2026-03-01

### Added

- **Dockerfile.base**: Pre-populate SSH known_hosts for GitHub, GitLab, and Bitbucket during image build
- **sandbox-manager.sh**: New `--ssh-agent` flag to forward host SSH_AUTH_SOCK into containers
- **acp-adapter.py**: SSH clone support with protocol detection (git@/ssh:// vs https://)
- **swarm.md**: Credential auto-detection step (Step 2.5) — detects ANTHROPIC_API_KEY, GITHUB_TOKEN via env/gh-cli/SSH agent
- **swarm.md**: Git remote fallback chain — tries origin, upstream, then first available remote
- **swarm.md**: AUTH_METHOD-to-protocol mismatch warnings (SSH auth with HTTPS remote, and vice versa)
- **swarm.md**: `--ssh-agent` flag passthrough in container provisioning when SSH auth detected
- **swarm.md**: Container creation command logging for debugging
- **swarm.md**: Resume subcommand now uses the same fallback chain and credential detection

### Fixed

- **swarm.md**: No longer hard-fails when `origin` remote is missing — falls back to other remotes
- **swarm.md**: Resume subcommand no longer hard-codes `git remote get-url origin`
- **acp-adapter.py**: SSH URLs no longer attempt HTTPS credential helper setup

## [1.21.0] - 2026-03-01

### Changed

- **README.md**: Added Skills section documenting all 17 skills (4 core, 6 development/style, 4 tooling/automation, 3 disabled/reference)
- **README.md**: Added Agents section documenting all 28 agents with descriptions per category
- **README.md**: Updated Components table from 4 skills to 17 skills
- **README.md**: Updated Table of Contents with Skills and Agents links
- **orchestrating-swarms SKILL.md**: Replaced all `compound-engineering:*` agent type references with `aimi-engineering:*` equivalents
- **orchestrating-swarms SKILL.md**: Updated agent lists to match actual aimi-engineering agents (removed non-existent `git-history-analyzer`, `repo-research-analyst`)

### Fixed

- **README.md**: Fixed stale `/aimi:plan-to-tasks` reference in troubleshooting → `/aimi:plan`
- **README.md**: Fixed "Check both plugins" → "Check plugin" in installation verification

### Removed

- **orchestrating-swarms SKILL.md**: All `compound-engineering` references eliminated — zero remaining in active plugin code

## [1.20.0] - 2026-03-01

### Changed

- **`check-version` CLI subcommand**: `_extract_version_from_path()` now uses bash parameter expansion (`${path%/*}`, `${no_scripts##*/}`) instead of `dirname`/`basename` forks — eliminates 3 subshell spawns per call
- **`check-version` CLI subcommand**: `current` status path uses `printf` instead of `jq -n` for JSON output — eliminates 1 jq fork on the happy path
- **`check-version` `--quiet` flag**: Suppresses all stderr warnings (e.g., stale/missing cli-path) for clean machine-readable output
- **`check-version` `--fix` flag**: Auto-updates `cli-path` via `write_state` on stale detection and outputs `{"status":"fixed",...}` with exit 0 instead of `{"status":"stale",...}` with exit 1
- **`check-version` dispatch table**: Now passes `"$@"` to `cmd_check_version` for flag forwarding
- **Command version-check blocks**: Consolidated multi-line `check-version` + jq parsing + `init-session` re-stamp in `execute.md`, `status.md`, `next.md`, and `swarm.md` into single `$AIMI_CLI check-version --quiet --fix` call — eliminates `2>/dev/null`, `VERSION_CHECK`, `VERSION_EXIT`, `STORED_VER`, `LATEST_VER` variables and jq dependency from version-check sections

### Added

- **`check-version` `--quiet` and `--fix` tests**: Tests for `--quiet` flag (suppressed stderr), `--fix` flag (auto-update on stale), combined `--quiet --fix` flags, and backward compatibility (no-flags behavior unchanged)

### Fixed

- **CHANGELOG.md**: Removed redundant `[1.18.1]` entry that duplicated content from `[1.18.0]`
- **auto-approve-cli.sh path traversal regex**: Version segments in plugin path now require digit-first pattern (`[0-9][0-9.]*`) — prevents crafted directory names from bypassing path validation

### Security

- **auto-approve-cli.sh `has_metacharacters()`**: Added `[<>]` character class to the first grep pattern — now blocks `>`, `>>`, `<`, `<<` redirection operators in addition to existing `;`, `&&`, `||`, backtick, and `$()` patterns

## [1.19.0] - 2026-03-01

### Added

- **`check-version` CLI subcommand**: Compares running plugin version against installed version on disk — returns JSON `{running, installed, match}` result; warns user on mismatch and triggers `init-session` to refresh `cli-path`
- **`cleanup-versions` CLI subcommand**: Finds and removes stale plugin versions from `~/.claude/plugins/cache/` — keeps only the latest installed version, returns JSON `{kept, removed: [paths]}` result
- **Step 0 version check integration**: All four execution commands (`execute.md`, `status.md`, `next.md`, `swarm.md`) now call `$AIMI_CLI check-version` after glob resolution — warns user on version mismatch and auto-updates `cli-path` via `init-session`; does NOT call `cleanup-versions` (cleanup is manual-only)
- **auto-approve-cli.sh whitelist**: Added `check-version` and `cleanup-versions` to the permitted subcommand list for auto-approval during task execution
- **test-aimi-cli.sh**: New tests covering `check-version` (match and mismatch scenarios) and `cleanup-versions` (no stale versions, stale version removal)

## [1.18.0] - 2026-03-01

### Added

- **Dockerfile.base**: COPY `acp-adapter.py` into base image at `/opt/aimi/acp-adapter.py` — containers now have the ACP adapter available for `docker exec` invocation
- **acp-adapter.py `provision_repo()`**: Repository cloning and branch checkout inside containers — clones `repoUrl`, configures GITHUB_TOKEN credential helper, checks out target branch (with fallback for new branches), verifies task file exists
- **acp-adapter.py `--input` flag**: File-based alternative to stdin for receiving task-request payloads — enables auto-approve-compatible `docker cp` + `docker exec --input` pattern
- **acp-adapter.py env var value sanitization**: `validate_env_var_value()` rejects values containing newlines, null bytes, or shell metacharacters (`;`, `&&`, `||`, backticks, `$(`)
- **acp-adapter.py progress throttling**: Progress emissions throttled to at most once every 2 seconds (time-based), reducing NDJSON volume by 90%+ with final line always emitted
- **acp-adapter.py concurrent stderr drain**: `threading.Thread` drains stderr concurrently while streaming stdout, preventing 64KB pipe buffer deadlock
- **sandbox-manager.sh `--container-id` and `--swarm-id`**: Optional flags for `cmd_create` to pass identity env vars into containers for ACP message envelopes
- **sandbox-manager.sh advisory disk limit**: Attempts `--storage-opt size=` and falls back gracefully with warning if storage driver doesn't support it
- **swarm.md non-interactive flags**: `--all`, `--files`, `--force`, `--append` flags skip AskUserQuestion prompts for fully autonomous agent-to-agent orchestration
- **auto-approve-cli.sh Pattern 9/10**: `docker exec` with optional `--input` flag and `docker cp` for ACP payload delivery — restricted to `aimi-` prefixed containers
- **SKILL.md total resource table**: Shows CPU, RAM, and swap consumption at 2, 4, and 8 containers with host sizing guidance (2x container RAM recommended)

### Fixed

- **auto-approve-cli.sh path regex**: Changed `skills/sandbox/` to `skills/docker-sandbox/` in `SANDBOX_MGR` and `BUILD_IMG` patterns to match actual plugin directory structure
- **sandbox-manager.sh swap default**: Changed `AIMI_SANDBOX_SWAP` from `4g` to `8g` — Docker's `--memory-swap` is total (memory + swap), so `4g` with `4g` memory meant zero actual swap
- **sandbox-manager.sh consolidated inspect**: Replaced 5 separate `docker inspect` calls in `cmd_status` with a single call using combined Go template format string
- **aimi-cli.sh swarm-cleanup**: Updated jq filter to also exclude `stopped` status (was only excluding `completed` and `failed`)
- **aimi-cli.sh `_validate_container_name`**: Harmonized with `sandbox-manager.sh` — now requires `aimi-` prefix and same character set (`^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`)
- **swarm.md Step 5 ACP invocation**: Changed from piped `echo | docker exec -i` to file-based `docker cp` + `docker exec --input` pattern — works with auto-approve hooks

## [1.17.1] - 2026-03-01

### Fixed

- **auto-approve-cli.sh**: Fixed `SANDBOX_MGR` and `BUILD_IMG` path validation regex patterns — changed `skills/sandbox/` to `skills/docker-sandbox/` to match actual plugin directory structure and the glob patterns used in swarm.md Step 0

## [1.17.0] - 2026-03-01

### Changed

- **`/aimi:swarm` status subcommand**: Now runs automatic state reconciliation before displaying status table — detects zombie entries (containers in state but missing from Docker), silent completions, silent failures, unexpected stops, and already-started containers
- **`/aimi:swarm` resume subcommand**: Enhanced with full crash recovery — reconciles state first, identifies resumable containers, recreates failed containers for retry, skips running/completed containers, fans out only pending containers
- **`/aimi:swarm` cleanup subcommand**: Enhanced with per-container removal reporting (removed vs already gone), proper state entry cleanup count, and graceful handling of missing swarms

### Added

- **State reconciliation subroutine** in swarm.md: Shared procedure that runs before `status` display and `resume` operations, comparing `swarm-state.json` entries against actual Docker daemon state via `sandbox-manager.sh status`
- **Zombie detection documentation**: New "State Reconciliation" reference section documenting detection scenarios (zombie, silent completion/failure, unexpected stop, already started), zombie causes, and idempotency guarantees

### Security

- **auto-approve-cli.sh**: Added `SANDBOX_MGR` patterns with path validation and subcommand whitelist (create, remove, list, status, cleanup, check-runtime)
- **auto-approve-cli.sh**: Added `BUILD_IMG` patterns with path validation for build-project-image.sh invocation
- **auto-approve-cli.sh**: Added swarm subcommands to `$AIMI_CLI` whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Added `docker exec -i aimi-*` pattern for ACP adapter communication — restricted to `aimi-` prefixed containers running `python3 /opt/aimi/acp-adapter.py` only (no wildcard Docker approvals)

## [1.16.0] - 2026-03-01

### Added

- **`/aimi:swarm` command**: Multi-task Docker sandbox orchestration for parallel feature execution
  - Discovers `.aimi/tasks/*-tasks.json` files, presents multi-select list to user
  - Supports `--file <path>` flag for single-file execution
  - Provisions Sysbox-isolated Docker containers via `sandbox-manager.sh` for each task file
  - Builds per-project images via `build-project-image.sh` with checksum-based rebuild skipping
  - Fans out parallel Task agents, each communicating with its container via ACP adapter (`docker exec -i`)
  - Tracks execution via `swarm-state.json` using CLI swarm-* subcommands
  - Configurable `maxContainers` limit (default 4, override with `--max <N>`)
  - Subcommands: `status` (view swarm state), `resume` (restart pending containers), `cleanup` (remove containers and state)
  - Handles partial failure: failed containers marked in state, successful ones continue independently
  - Reports summary with per-container status, branch names, and PR URLs

## [1.15.0] - 2026-03-01

### Changed

- **execute.md parallel execution rewrite**: Replaced Team/SendMessage swarm orchestration with foreground fan-out using `run_in_background` Task agents — eliminates Team lifecycle complexity, reduces token overhead, and runs parallel workers directly from the orchestrator's context
- **execute.md Team/SendMessage dependency removed**: Parallel story execution no longer requires TeamCreate, SendMessage, or teammate coordination — workers are spawned as background tasks and polled for completion

### Fixed

- **worktree-manager.sh merge stderr suppression**: Removed `2>/dev/null` from `git checkout` and `git merge` commands in `merge_worktree()` and `merge_all_worktrees()` functions — merge conflicts and failures are now visible in stderr for proper diagnosis

## [1.14.0] - 2026-02-28

### Changed

- **aimi-cli.sh portable `_lock()` function**: Replaces direct `flock` calls with cross-platform locking — Linux uses `flock`, macOS uses atomic `mkdir` spinlock with 10s stale-lock timeout and `trap EXIT` cleanup
- **aimi-cli.sh platform detection at startup**: Caches `_HAS_FLOCK` and `_HAS_REALPATH` to avoid per-call `command -v` overhead
- **aimi-cli.sh `cmd_clear_state`**: Also removes `*.lock.d` directories (mkdir-based lock cleanup)
- **execute.md CLI resolution**: Glob first (always finds latest version), cli-path as fallback only — prevents stale cached path from using old plugin version
- **status.md + next.md CLI resolution**: Consistent with execute.md — glob first, cli-path fallback (was glob-only, no fallback)

## [1.13.0] - 2026-02-27

### Added

- **aimi-cli.sh `resolve_path()` helper**: POSIX-compatible path resolution (uses `realpath` when available, falls back to `cd`+`pwd`+`basename` for macOS)
- **aimi-cli.sh `reset-orphaned` subcommand**: Atomically marks all `in_progress` stories as `failed`, returns `{count, reset: [ids]}` — replaces fragile `status | jq` pipeline
- **aimi-cli.sh `validate_story_exists()` function**: Verifies story ID exists in tasks file before mutation; all `mark-*` and `cascade-skip` commands now exit 1 with clear error for non-existent IDs
- **aimi-cli.sh `cli-path` state file**: `init-session` writes CLI's absolute path to `.aimi/cli-path` for reliable resolution across shell sessions
- **aimi-cli.sh stale state warning**: `get_tasks_file()` prints stderr warning when `current-tasks` points to a deleted file, auto-updates state with discovered alternative
- **test-aimi-cli.sh**: 16 new tests (65 total) covering: resolve_path, cli-path, userStories key, story ID existence validation, reset-orphaned (empty + with orphans), stale state warning
- **test-aimi-cli.sh `assert_stderr_contains` helper**: New test helper for validating stderr output

### Changed

- **aimi-cli.sh `cmd_status` output**: Renamed `.stories` key to `.userStories` for consistency with schema v3.0 source field name
- **aimi-cli.sh state files**: `init-session` and `get_tasks_file()` now store absolute paths in `.aimi/current-tasks` (resolves cwd-dependency bugs)
- **aimi-cli.sh `write_state()` and `clear_state_file()`**: Now use `flock` with `$AIMI_DIR/.state.lock` for parallel execution safety
- **aimi-cli.sh `cmd_clear_state`**: Also removes `.state.lock`, `cli-path`, and all `.lock` files under `.aimi/`
- **execute.md Step 0**: CLI resolution now tries `cat .aimi/cli-path` first, falls back to `ls` glob if missing or invalid
- **execute.md orphaned recovery**: Replaced `status | jq` pipeline with `$AIMI_CLI reset-orphaned` subcommand
- **status.md**: Updated example output to use `userStories` key
- **auto-approve-cli.sh**: Added `reset-orphaned` to subcommand whitelist

## [1.12.0] - 2026-02-27

### Added

- **worktree-manager.sh `remove` command**: New `remove <worktree-name>` subcommand for non-interactive worktree cleanup (`git worktree remove --force` + `git branch -D`)
- **worktree-manager.sh `--from` flag**: `create` now supports `create name --from branch` (and positional backward compat)
- **worktree-manager.sh input validation**: `validate_branch_name()` with regex `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`, path containment check via `realpath -m`
- **aimi-cli.sh flock-based file locking**: All 5 mutation functions use `flock -x` advisory locking with unique `mktemp` temp files
- **aimi-cli.sh `validate_story_id()`**: Regex `^US-[0-9]{3}[a-z]?$` validated on all mark-* commands
- **aimi-cli.sh `validate-stories` command**: Checks field lengths (title: 200, description: 500, criterion: 300) and suspicious content patterns for prompt injection defense
- **aimi-cli.sh `maxConcurrency` guard**: Values <= 0 default to 4 in status and metadata commands
- **execute.md orphaned recovery**: Step 1 detects stories stuck in `in_progress` from interrupted runs, resets to `failed`
- **execute.md content validation**: Step 1 calls `validate-stories` before any execution
- **execute.md agent-driven merge conflict resolution**: On merge conflict, spawns a Task agent to attempt resolution before falling back to manual
- **execute.md worker timeout**: Configurable timeout (default 15 min); non-responding workers marked as failed

### Changed

- **worktree-manager.sh**: Removed all interactive `read -r` prompts — create reuses existing worktrees silently, cleanup proceeds without confirmation
- **worktree-manager.sh**: Removed unnecessary `git checkout`/`git pull` from create (worktree add works without checkout)
- **worktree-manager.sh**: `chmod 600` applied to all copied .env files; git commands use `--` separator before branch arguments
- **story-executor SKILL.md**: Fixed contradiction (agents report results, callers handle status via CLI), removed duplicated sections (compact prompt, JS examples, default rules), added `story.notes` placeholder, declared as canonical prompt template
- **execute.md**: Moved `validate-deps` from parallel-only path to shared Step 3.1 — both sequential and parallel validate dependency graph
- **execute.md**: Worker prompt includes `## PREVIOUS NOTES` section with `story.notes` (omitted when empty)
- **execute.md + next.md**: Replaced duplicated inline worker prompts with references to story-executor SKILL.md canonical template (net -96 lines)
- **execute.md + next.md**: Replaced duplicated guideline loading sections with references to story-executor discovery order

### Security

- **auto-approve-cli.sh**: Replaced permissive `$AIMI_CLI` pattern with explicit subcommand whitelist (19 commands) and shell metacharacter rejection
- **auto-approve-cli.sh**: `AIMI_CLI=` assignment now validates path matches expected plugin install directory
- **auto-approve-cli.sh**: Added `WORKTREE_MGR` patterns with path validation and subcommand whitelist (create, remove, merge, list, help)

## [1.11.0] - 2026-02-27

### Removed

- **v2.2 backward compatibility**: All v2.2 schema support removed — v3.0 is now the only supported format
- **plan-to-tasks skill**: Deleted entire `skills/plan-to-tasks/` directory (v2.2-only task generator)
- **detect-schema CLI command**: Removed `detect-schema` command and all dual-schema detection logic from aimi-cli.sh
- **v2.2 code paths in CLI**: Removed `detect_schema()`, `is_v3()`, `cmd_detect_schema()` functions and all if/else version branching
- **v2.2 test fixtures**: Rewrote test suite to v3-only (49 tests, all passing)
- **v2.2 references in docs**: Cleaned all v2.2 mentions from commands (deepen, next, status, execute), execution-rules, task-format-v3, story-decomposition, and CLAUDE.md files

## [1.10.0] - 2026-02-27

### Fixed

- **Plugin CLAUDE.md**: Updated schema example from v2.1 to v3 (status, dependsOn, maxConcurrency)
- **story-executor**: Removed direct tasks file mutation instructions — agents now delegate to CLI for all status updates
- **execution-rules.md**: Updated with v3 status enum and dual-schema documentation
- **deepen.md**: Made schema-aware — detects v3 status field instead of v2.2 passes boolean
- **next.md**: Updated CLI output example with both v3 and v2.2 variants
- **pipeline-phases.md**: Fixed output report from "Schema: 2.2" to "Schema: 3.0"
- **story-decomposition.md**: Fixed conversion rule from `passes: false` to `status: "pending"`

### Changed

- **aimi-cli.sh**: Removed dead code (abandoned jq blocks, duplicated ready-story logic); DRYed cmd_next_story to reuse cmd_list_ready
- **plan-to-tasks**: Added deprecation notice (generates v2.2 only; use task-planner for v3)

### Added

- **test-aimi-cli.sh**: 31 new v3 test cases covering detect-schema, list-ready, mark-in-progress, validate-deps, cascade-skip, dependency resolution, and circular dependency detection (65 total tests)

## [1.9.0] - 2026-02-27

### Added

- **Schema v3 (`task-format-v3.md`)**: New tasks.json schema with dependency graph and parallel execution support
  - `dependsOn` (string[]) for explicit inter-story dependency graphs (DAG)
  - `status` enum (`pending`, `in_progress`, `completed`, `failed`, `skipped`) replacing `passes` boolean
  - `maxConcurrency` metadata field (default 4) for parallel story execution
  - `priority` retained as tiebreaker for stories at same dependency depth
  - Status state machine with valid transitions documented
  - `dependsOn` validation rules: no circular deps, no self-refs, all referenced IDs must exist
  - Backward compatibility with v2.2: auto-detection and fallback behavior
  - Migration guide: v2.2 to v3 conversion rules with priority-layer inference for `dependsOn`

- **Parallel execution in `/aimi:execute`**: Automatic detection and execution of independent stories in parallel
  - Wave-based execution: independent stories run concurrently within waves
  - Team/swarm orchestration for parallel workers using Claude Code Teams
  - Adaptive concurrency: `min(ready stories, maxConcurrency)`
  - Cascade-skip on failure: dependent stories automatically skipped when a dependency fails
  - v2.2 fallback: sequential execution preserved for older schema files
  - v3 with linear deps: runs sequentially without Team/worktree overhead

- **Worktree merge commands** in `worktree-manager.sh`
  - `merge <worktree-name> [--into <branch>]` — merge worktree branch into target
  - `merge-all <branch1> <branch2> ... [--into <branch>]` — sequential multi-merge
  - Merge conflict detection with conflicting file listing
  - Stop-on-conflict behavior for merge-all

- **CLI extensions** for v3 schema support in `aimi-cli.sh`
  - `detect-schema` — returns schema version (`2.2` or `3.0`)
  - `list-ready` — dependency-aware ready story detection (v3)
  - `mark-in-progress` — sets `status: "in_progress"` for a story (v3)
  - `validate-deps` — DAG validation for dependency graph (cycles, missing refs, self-refs)
  - `cascade-skip` — transitive skip on failure for dependent stories

### Changed

- **`/aimi:execute` command**: Rewritten for smart parallel/sequential execution based on schema version and dependency graph shape
- **`story-decomposition.md`**: Updated with `dependsOn` generation rules, layer-based inference, and parallel grouping examples
- **`task-planner` SKILL.md**: Phase 3 and Phase 4 updated for v3 output with `dependsOn` arrays and `status` field
- **`plan.md` command**: Output format updated to v3 schema with `dependsOn` and `status` fields
- **`story-executor` skill**: Added optional `WORKTREE_PATH` variable for parallel worker context; workers report status instead of writing tasks.json directly
- **`/aimi:status` command**: v3 display with status values, dependency info, and wave grouping; v2.2 display unchanged
- **CLI dual-version support**: `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `next-story` all updated for v2.2/v3 compatibility

## [1.8.0] - 2026-02-27

### Added

- **`brainstorm` skill**: Standalone process knowledge for brainstorming sessions
  - `skills/brainstorm/SKILL.md` (229 lines) — hybrid question flow, Ralph-style batched multiple-choice, adaptive exit, YAGNI, design document template
  - `skills/brainstorm/references/question-patterns.md` (240 lines) — formatting rules, scenario batches, response parsing, contextual question generation

### Changed

- **`/aimi:brainstorm` command**: Full rewrite as standalone (no longer wraps compound-engineering)
  - Phase 0: Assess requirements clarity
  - Phase 1: Codebase research via `aimi-codebase-researcher` agent
  - Phase 2: Batched 3-5 multiple-choice questions with "1A, 2C, 3B" shorthand
  - Phase 3: Conditional approaches (only when multiple valid paths exist)
  - Phase 4: Design document capture with slug derivation, collision handling, open questions enforcement
  - Phase 5: Aimi-branded handoff
- **compound-engineering dependency fully eliminated**: All commands and skills are now standalone. Zero external plugin dependencies required.
- **CLAUDE.md**: Dependencies section updated to reflect full independence
- **`aimi-code-simplicity-reviewer` agent**: Updated pipeline artifacts reference
- **`aimi-best-practices-researcher` agent**: Removed `compound-docs` from skill mapping

## [1.7.0] - 2026-02-26

### Added

- **PermissionRequest hook**: Auto-approves `$AIMI_CLI` and `AIMI_CLI=` Bash commands during task execution, eliminating manual permission prompts for CLI operations
  - `hooks/hooks.json` — hook configuration
  - `hooks/auto-approve-cli.sh` — approval script matching only AIMI CLI patterns

## [1.6.0] - 2026-02-25

### Changed

- **Output directory**: All document output paths moved from `docs/` to `.aimi/`
  - `docs/tasks/` → `.aimi/tasks/`
  - `docs/brainstorms/` → `.aimi/brainstorms/`
  - `docs/plans/` → `.aimi/plans/`
  - `docs/solutions/` → `.aimi/solutions/`
- **`aimi-cli.sh`**: `TASKS_DIR` now derived from `$AIMI_DIR` variable (`$AIMI_DIR/tasks`)
- All commands, skills, and agents updated with new paths

## [1.5.2] - 2026-02-25

### Changed

- **`/aimi:plan` command**: Inlined full task-planner pipeline directly into plan.md to fix double skill loading issue (both `plan` command and `task-planner` skill were loading into context)
- **`task-planner` skill**: Set to `user-invocable: false` since pipeline is now embedded in `/aimi:plan`

## [1.5.1] - 2026-02-25

### Added

- **Context7 MCP server**: Registered `context7` HTTP MCP server directly in plugin.json so `aimi-best-practices-researcher` and `aimi-framework-docs-researcher` can access documentation without compound-engineering installed

## [1.5.0] - 2026-02-25

### Added

- **28 aimi-native agents**: Standalone agents that eliminate compound-engineering dependency for plan, review, and deepen workflows
  - 4 research agents: `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`
  - 15 review agents: `aimi-architecture-strategist`, `aimi-security-sentinel`, `aimi-code-simplicity-reviewer`, `aimi-performance-oracle`, `aimi-agent-native-reviewer`, `aimi-data-integrity-guardian`, `aimi-data-migration-expert`, `aimi-deployment-verification-agent`, `aimi-schema-drift-detector`, `aimi-pattern-recognition-specialist`, `aimi-dhh-rails-reviewer`, `aimi-kieran-rails-reviewer`, `aimi-kieran-typescript-reviewer`, `aimi-kieran-python-reviewer`, `aimi-julik-frontend-races-reviewer`
  - 3 design agents: `aimi-design-implementation-reviewer`, `aimi-design-iterator`, `aimi-figma-design-sync`
  - 1 docs agent: `aimi-ankane-readme-writer`
  - 5 workflow agents: `aimi-spec-flow-analyzer`, `aimi-bug-reproduction-validator`, `aimi-every-style-editor`, `aimi-lint`, `aimi-pr-comment-resolver`

### Changed

- **`task-planner` skill**: All agent references updated from `compound-engineering:*` to `aimi-engineering:*`
- **`/aimi:deepen` command**: Now uses `aimi-engineering:research:aimi-codebase-researcher` instead of compound agent
- **`/aimi:review` command**: Fully rewritten as standalone multi-agent review command. No longer wraps `/workflows:review`. Invokes parallel aimi-native review agents with default agents (architecture, security, simplicity, performance, agent-native), conditional migration agents, language-specific reviewers, and findings synthesis with severity categorization.
- **Reduced compound-engineering dependency**: Only `/aimi:brainstorm` still requires compound-engineering. Plan, deepen, and review are now fully standalone.

## [1.4.0] - 2026-02-25

### Added

- **`task-planner` skill**: New skill that generates `tasks.json` directly from a feature description. Full pipeline: brainstorm detection, local/external research (parallel), spec-flow analysis, story decomposition, and direct JSON output — no intermediate markdown plan.
  - `skills/task-planner/SKILL.md` (160 lines) — orchestration overview and agent invocation syntax
  - `skills/task-planner/references/pipeline-phases.md` — detailed phase-by-phase instructions
  - `skills/task-planner/references/story-decomposition.md` — sizing, ordering, validation rules

### Changed

- **`/aimi:plan` command**: No longer wraps compound-engineering `/workflows:plan`. Now invokes the `task-planner` skill directly, producing `tasks.json` without an intermediate plan markdown file.
- **`/aimi:deepen` command**: No longer wraps compound-engineering `/deepen-plan`. Now enriches `tasks.json` directly — spawns research agents per pending story, improves acceptance criteria, splits oversized stories, preserves completed story state. Accepts optional path argument; auto-discovers most recent tasks.json if omitted.
- **Schema version**: Bumped from 2.1 to 2.2
  - `metadata.planPath` is now optional/nullable (`null` when generated by task-planner)
  - `metadata.brainstormPath` documented as optional context reference
  - Backward compatible with v2.1 — existing files work without modification
- **`plan-to-tasks` skill**: Updated to output schema v2.2. Added note directing users to `task-planner` for direct generation. Remains functional as standalone converter for external markdown plans.

## [1.3.1] - 2026-02-25

### Fixed

- **`/aimi:plan` not loading `plan-to-tasks` skill**: Step 4 used ambiguous pseudo-syntax (`Skill: plan-to-tasks`) inside a code block, which Claude interpreted as descriptive text instead of an actionable tool invocation
  - Replaced with explicit instructions to call the Skill tool with `skill: "aimi-engineering:plan-to-tasks"`
  - Added "Do NOT generate tasks.json from memory or inline" guardrail
  - Added fallback: read `SKILL.md` directly if Skill tool is unavailable
  - Updated Step 5 to clarify the skill handles output writing

## [1.3.0] - 2026-02-24

### Fixed

- **CLI script path resolution**: Commands now resolve `aimi-cli.sh` from plugin install directory (`~/.claude/plugins/cache/*/aimi-engineering/*/scripts/`) instead of using `./scripts/` relative path which fails when cwd is the user's project
  - Updated `execute.md`, `next.md`, `status.md` with Step 0: Resolve CLI Path
  - Added `$AIMI_CLI` variable pattern (matches compound-engineering's plugin path convention)
  - Updated `allowed-tools` frontmatter to permit `$AIMI_CLI` execution
  - Updated README architecture section and CLI help examples

## [1.2.2] - 2026-02-24

### Fixed

- **Schema structure divergences** across 7 files:
  - `commands/plan.md`: Schema version output said "2.0" instead of "2.1"
  - `README.md`: jq example referenced non-existent top-level `project`/`branchName` fields (now uses `metadata.*`)
  - `README.md`: Removed stale `steps`/`taskType` from field length limits table (fields removed in v2.1)
  - `README.md`: Updated intro text (removed references to removed `steps`/`qualityChecks` fields)
  - `README.md`: Added missing Root Fields table, moved `schemaVersion` out of Metadata table
  - `README.md`: Added missing `brainstormPath` to Metadata Fields table
  - Root `CLAUDE.md`: Replaced obsolete pre-v2.0 schema (missing `schemaVersion`, `metadata` wrapper) with current v2.1 structure
  - `marketplace.json`: Synced version from "0.2.0" to "1.2.2" (matching plugin.json)

## [1.2.1] - 2026-02-24

### Changed

- **Schema version bump**: `schemaVersion` updated from "2.0" to "2.1" across all files
  - README.md, CLAUDE.md, SKILL.md, task-format.md, test-aimi-cli.sh

## [1.2.0] - 2026-02-24

### Added

- **aimi-cli.sh**: Single bash script for deterministic task file operations
  - 13 subcommands: `init-session`, `find-tasks`, `status`, `metadata`, `next-story`, `current-story`, `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `get-branch`, `get-state`, `clear-state`
  - State management via `.aimi/` directory (persists across `/clear`)
  - Atomic file updates using temp file + mv pattern
  - Comprehensive test suite (33 tests)
- **Story-by-story execution**: Execute one story at a time with `/clear` between stories
- `.gitignore` entry for `.aimi/` state directory

### Changed

- **Commands updated to use CLI instead of inline jq**:
  - `/aimi:execute` - Uses `init-session`, `count-pending`, `get-state`
  - `/aimi:next` - Uses `next-story`, `mark-complete`, `mark-failed`, `mark-skipped`
  - `/aimi:status` - Uses `status` command
- Simplified command files (less error-prone, no jq interpretation by AI)

### Fixed

- AI hallucination when interpreting bash commands embedded in markdown
  - Variable substitution errors
  - Command sequence errors
  - jq query modifications
  - Path/filename errors

## [1.1.0] - 2026-02-17

### Changed

- Restored v2.0 tasks.json schema with task-specific fields
  - Re-added `taskType`, `steps`, `relevantFiles`, `qualityChecks` to story schema
  - `schemaVersion` changed from "3.0" to "2.0"
  - Improved agent execution with domain-specific guidance
  - All story `steps` start with "Read CLAUDE.md and AGENTS.md for project conventions"

### Added

- Automated taskType detection via keyword matching (7 types)
  - `prisma_schema` - Database schema/migration changes
  - `server_action` - Server-side logic and actions
  - `react_component` - React/UI component work
  - `api_route` - API endpoint implementation
  - `utility` - Helper functions and services
  - `test` - Test implementation
  - `other` - Fallback for unclassified tasks
- Predefined step templates for each taskType
- `relevantFiles` inference from story content + taskType defaults
- `qualityChecks` assignment based on taskType
- New placeholders in prompt template: `[TASK_TYPE]`, `[STEPS_ENUMERATED]`, `[RELEVANT_FILES_BULLETED]`, `[QUALITY_CHECKS_BULLETED]`

### Removed

- v3.0 schema (minimal field set without task-specific guidance)

### Migration

Existing v3.0 tasks.json files must be regenerated:

```bash
/aimi:plan [feature]
```

## [1.0.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v3.0 with Ralph-style flat stories
  - Flat story structure (no nested `tasks[]` array)
  - Story IDs changed from `story-0` to `US-001` format
  - Added `priority` field for explicit execution order
  - Simple `passes: true/false` state tracking (no per-task status)
  - Per-story `acceptanceCriteria` array (moved from root level)
  - Required "Typecheck passes" in every story's acceptance criteria
  - `successMetrics` at root level for tracking improvements

### Added

- **Priority-based execution**: `/aimi:next` uses jq `sort_by(.priority)` to select next story
- **Project guidelines loading**: CLAUDE.md/AGENTS.md loaded before implementation
- **Aimi default rules**: Fallback commit format and quality checks when no project guidelines exist
- Brainstorm document: `docs/brainstorms/2026-02-16-ralph-style-tasks-brainstorm.md`

### Updated

- `plan-to-tasks` skill updated for flat story conversion
- `task-format.md` reference rewritten for v3.0 schema
- `story-executor` skill simplified for flat structure
- `execution-rules.md` updated with "Read Project Guidelines" as Step 1
- `/aimi:next` loads guidelines before building Task prompt
- `/aimi:execute` derives branch name from metadata title
- `/aimi:status` shows priority in story list

### Removed

- Nested `tasks[]` array structure
- `estimatedEffort` field (agent determines pace from story scope)
- `taskType`, `steps`, `relevantFiles`, `patternsToFollow` fields
- Root-level `acceptanceCriteria` (now per-story)
- `deploymentOrder` field

### Migration

Existing tasks.json files need to be regenerated:

```bash
/aimi:plan-to-tasks docs/plans/your-plan.md
```

## [0.9.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v2.0 with nested tasks structure
  - Stories contain nested `tasks[]` array with task objects
  - Added `metadata` object with `title`, `type`, `createdAt`, `planPath`, `brainstormPath`
  - Added `successMetrics` object for tracking improvements
  - Tasks have `id`, `title`, `description`, `file`, `action`, `status` fields
  - Added `estimatedEffort` field to stories

### Updated

- `plan-to-tasks` skill updated for new schema structure
- `task-format.md` reference rewritten for v2.0 schema
- `story-executor` skill updated to work with nested tasks
- `execution-rules.md` updated for task-based execution flow

### Removed

- Old schema fields: `taskType`, `steps`, `relevantFiles`, `patternsToFollow`, `qualityChecks` (per-story)

## [0.8.0] - 2026-02-16

### Fixed

- **Aimi-Branded Messaging**: All commands now show only Aimi commands in next steps
  - Commands still execute compound-engineering workflows under the hood
  - Post-completion options are intercepted and replaced with Aimi equivalents
  - Command mapping: `/workflows:plan` → `/aimi:plan`, `/deepen-plan` → `/aimi:deepen`, etc.

### Changed

- `/aimi:brainstorm` - Added Step 2 with Aimi-branded next steps override
- `/aimi:plan` - Added Step 6 with Aimi-branded report override
- `/aimi:deepen` - Added Step 6 with Aimi-branded report override
- `/aimi:review` - Added Step 2 with Aimi-branded summary override
- All commands include "NEVER mention" guidance to prevent compound-engineering leakage

## [0.7.0] - 2026-02-16

### Added

- **Project Guidelines Injection**: CLAUDE.md/AGENTS.md content injected into Task prompts
  - Discovery order: CLAUDE.md (root) → AGENTS.md (directory) → Aimi defaults
  - Small files (<2KB) inlined, larger files referenced
- **Aimi Default Commit/PR Rules**: Fallback rules when project lacks CLAUDE.md/AGENTS.md
  - `default-rules.md` reference file with commit format, behavior, and PR guidelines
  - Always applied if project files lack commit/PR section
- **Fresh Context Per Story**: Each Task agent starts with clean context (no memory carryover)

### Changed

- **BREAKING:** Renamed `[PATTERNS_CONTENT]` placeholder to `[PROJECT_GUIDELINES]`
- Story-executor now uses `get_project_guidelines()` instead of `get_patterns_content()`
- Execution rules Step 1 now reads CLAUDE.md/AGENTS.md instead of progress.md
- Learnings stored in CLAUDE.md (project-wide) or AGENTS.md (module-specific)

### Removed

- `patternsToFollow` field is now optional (guidelines discovery is automatic)

## [0.6.0] - 2026-02-16

### Changed

- **BREAKING:** Removed `progress.md` - all state now in `tasks.json`
  - No more progress.md initialization in `/aimi:plan`
  - No more progress entry appending in `/aimi:next`
  - No more CODEBASE_PATTERNS from progress.md
- Simplified prompt template (removed progress.md references)
- Simplified interpolation function signature

### Removed

- `progress.md` file and all references
- CODEBASE_PATTERNS placeholder
- `Bash(grep:*)`, `Bash(cat:*)`, `Bash(tail:*)` from allowed-tools (no longer needed)

## [0.5.1] - 2026-02-16

### Fixed

- `/aimi:next` now ensures `progress.md` is always updated after task completion
  - Step 5a: Verify tasks.json updated, fallback update via jq if not
  - Step 5b: Check if progress entry exists, append if missing
- `/aimi:status` now uses jq for minimal context usage
- `/aimi:status` shows skipped stories with `✗` indicator
- `/aimi:status` displays recent activity from progress.md

### Added

- `Bash(grep:*)`, `Bash(cat:*)` to `/aimi:next` allowed-tools
- `Bash(tail:*)` to `/aimi:status` allowed-tools

## [0.5.0] - 2026-02-16

### Added

- **jq-based task extraction**: Only load ONE story into context at a time
  - `/aimi:execute` extracts only metadata (project, branchName, counts)
  - `/aimi:next` extracts only the next pending story
- **`skipped` field**: Prevents infinite loop on failed tasks
  - When user says "skip", sets `skipped: true` on the story
  - jq query filters: `passes == false AND skipped != true`

### Changed

- `/aimi:execute` now shows separate counts for pending, completed, and skipped
- `/aimi:next` uses jq instead of reading full tasks.json
- Added `Bash(jq:*)` to allowed-tools for both commands

### Fixed

- Infinite loop when a task keeps failing (now properly excluded after skip)

## [0.4.2] - 2026-02-16

### Fixed

- `/aimi:plan` now properly runs compound-engineering's `/workflows:plan` first, then automatically converts to tasks.json
- Added explicit two-phase execution flow with no user prompts between phases
- Added `Skill(compound-engineering:workflows:plan)` to allowed-tools

### Added

- Error handling section in `/aimi:plan` for failed or cancelled operations

## [0.4.1] - 2026-02-16

### Security

- **Path Traversal Prevention**: Added comprehensive path validation for `relevantFiles` and `patternsToFollow`
  - Blocks `..` sequences, absolute paths, protocol prefixes, null bytes
  - Blocks access to sensitive paths (`.git/`, `.env`, `.ssh/`)
- **Expanded Command Injection Blocklist**: Now blocks `&&`, `||`, `>`, `>>`, `<`, newlines, and more
- **Strengthened Prompt Injection Defenses**: Added patterns for role manipulation, system prompt extraction, and boundary breaking

### Added

- **Schema Versioning**: `schemaVersion` field in tasks.json (v2.0 for task-specific steps)
- **qualityChecks Field**: Explicit verification commands per story (typecheck, test, lint)
- **AGENTS.md Content Injection**: Small AGENTS.md files (< 2KB) are inlined directly in prompts
- **Placeholder Interpolation Documentation**: Complete reference for prompt template placeholders
- **Pattern Matching Tie-Breaking Rules**: Deterministic selection when multiple patterns match

### Changed

- **Naming Consistency**: Renamed `file_patterns` to `filePatterns` (camelCase) in pattern library
- **Simplified Error Messages**: Consistent format: `Error: Story [ID] - [field]: [issue]. Fix: [action].`
- **Consolidated Validation Rules**: task-format.md is now the single source of truth
- **Removed Duplicate Prompt Example**: Task Tool Invocation section now references the main template

### Fixed

- Pattern files now use consistent camelCase for `filePatterns` field

## [0.4.0] - 2026-02-16

### Added

- **Task-Specific Step Generation**: Each story now includes pre-computed, domain-aware execution steps
- **Pattern Library** (`docs/patterns/`): Workflow templates for common task types
  - `prisma-schema.md` - Database schema changes with Prisma
  - `server-action.md` - Next.js server actions
  - `react-component.md` - React component creation
  - `api-route.md` - API endpoint implementation
- **AGENTS.md Discovery**: Automatic discovery and matching of AGENTS.md files to tasks
- **TaskType Inference**: Keyword-based pattern matching with LLM fallback

### Changed

- **BREAKING:** tasks.json schema now requires four new fields per story:
  - `taskType` (string, snake_case, max 50 chars) - Domain classification
  - `steps` (array, 1-10 items, each max 500 chars) - Task-specific execution steps
  - `relevantFiles` (array, max 20 items) - Files to read first
  - `patternsToFollow` (string) - AGENTS.md path or "none"
- `/aimi:next` now validates required fields before execution
- `/aimi:next` prompt template uses story.steps instead of generic execution flow
- `story-executor` skill updated with STEPS, RELEVANT FILES, and PATTERNS sections
- `plan-to-tasks` skill now generates task-specific fields during conversion

### Migration

Existing tasks.json files will fail validation. To migrate:

```bash
# Regenerate tasks.json from your plan file
/aimi:plan-to-tasks docs/plans/your-plan.md
```

Or manually add the required fields to each story in tasks.json.

## [0.3.0] - 2026-02-15

### Changed

- **BREAKING:** Rename `completed` field to `passes` in tasks.json schema
  - Better reflects acceptance criteria validation semantics (pass/fail)
  - Aligns with testing vocabulary
  - Updated all commands: deepen, execute, next, status
  - Updated all skills: plan-to-tasks, story-executor
  - Existing tasks.json files need field renamed from `completed` to `passes`

## [0.2.1] - 2026-02-15

### Added

- AGENTS.md update instructions in story-executor (mirrors Ralph's prompt.md pattern)
- Step 10 in execution-rules.md for updating AGENTS.md files with reusable patterns
- AGENTS.md guidance in compact prompt template

### Changed

- Execution flow now includes AGENTS.md check before committing (Step 5 in SKILL.md)

## [0.2.0] - 2026-02-15

### Security

- **BREAKING:** Add branchName validation in `/aimi:execute` to prevent command injection
- Add input sanitization for story content before prompt interpolation (prevents prompt injection)
- Restrict Bash permissions in `/aimi:next` to specific command prefixes (git, npm, bun, yarn, tsc, eslint, prettier)

### Changed

- **BREAKING:** Introduced `completed` field in tasks.json schema (now renamed to `passes` in v0.3.0)
- Inline story data in Task prompts (reduces file I/O by ~33%)
- Extract only Codebase Patterns from progress.md (reduces context usage)
- Add structured error format with type classification for programmatic handling

### Added

- JSON schema validation requirements in task-format.md
- Available Capabilities section in story-executor (agents know their tools)
- Compact prompt template for subsequent stories (~60% token reduction)
- Progress rotation guidelines (archive when exceeding 50KB)
- Error type classification: typecheck_failure, test_failure, lint_failure, runtime_error, dependency_missing, unknown

### Removed

- Duplicate plugin.json at root level (keep only in plugins/aimi-engineering/)

## [0.1.0] - 2026-02-15

### Added

#### Commands
- `/aimi:brainstorm` - Explore ideas through guided brainstorming (wraps compound-engineering)
- `/aimi:plan` - Create implementation plan and convert to tasks.json
- `/aimi:deepen` - Enhance plan with research and update tasks.json
- `/aimi:review` - Code review using compound-engineering workflows
- `/aimi:status` - Show current task execution progress
- `/aimi:next` - Execute the next pending story with retry logic
- `/aimi:execute` - Run all stories autonomously in a loop

#### Skills
- `plan-to-tasks` - Convert markdown implementation plans to structured tasks.json format
- `story-executor` - Provides prompt template for Task-spawned agents executing stories

#### Documentation
- Task format reference with JSON schema and sizing rules
- Execution rules reference with 9-step execution flow
- Complete README with workflow guide and troubleshooting

### Dependencies

This plugin requires **compound-engineering-plugin** for brainstorm, plan, and review workflows.
