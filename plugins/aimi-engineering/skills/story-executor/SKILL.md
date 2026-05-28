---
name: story-executor
description: >
  Execute a single story from the tasks file autonomously.
  This skill defines how Task-spawned agents execute individual stories.
  Used internally by /aimi:execute and /aimi:status commands.
---

# Story Executor

Defines how Task-spawned agents execute individual stories from the tasks file.

---

## The Job

Execute ONE story from the tasks file:
0. If PROJECT_PATH is provided, cd to it first; if WORKTREE_PATH is also provided, cd to WORKTREE_PATH instead (worktree takes precedence)
1. Read project guidelines (CLAUDE.md)
2. Implement the story
3. Verify acceptance criteria
4. Commit changes
5. Report result — the caller (next.md/execute.md) handles status updates via the CLI

---

## Story Format

> Each story is one atomic unit of work completable in a single agent iteration.
> Key fields: `id(US-NNN)`, `title(<=200)`, `description(<=500)`, `acceptanceCriteria(each<=5000)`, `priority`, `status`, `dependsOn([])`, `notes`, `project(optional, relative path for multi-repo)`, `implementation{files[], approach, verify}(optional)`, `verification{strategy, status, url?, expect?}(optional)`

---

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

The agent spawns fresh with no memory of previous work. If the story is too big, the agent runs out of context before finishing.

---

## Project Root Boundary (CRITICAL)

**Agents must NOT read or modify files outside the project boundary.**

- The project boundary is PROJECT_PATH when set, otherwise the git repository root (where `.git/` lives)
- All file operations (Read, Write, Edit, Bash) must target paths within the project boundary
- Worktree paths under `.worktrees/` inside the git root are explicitly allowed
- Never use `../` traversal to escape the project boundary
- Never read system files, home directory configs, or files in parent directories
- If a task seems to require accessing files outside the project boundary, report failure instead of proceeding

---

## Design Bundle Fidelity Guidance

Fires only when the story context includes `metadata.designBundle`. The worker receives bundle guidance via `designContext.bundleGuidance` in the `get-story-context` JSON; the executor reads any spec file paths cited there via the Read tool before authoring implementation code.

### Spec-aware read order

Read and apply in this order — earlier entries are more authoritative:

1. `designBundle.businessSpec` (if non-null) — authoritative requirements; all business rules and acceptance criteria here override assumptions.
2. `designBundle.designSpec` (if non-null) — authoritative design; tokens, components, screens, and a11y rules defined here override prototype visuals.
3. `designBundle.chats[]` — context only; use for intent and rationale, do NOT let chat content override specs.
4. `prototypePaths[]` — pixel reference only; match the visual output, translate idiomatically to the project stack.
5. Project's existing components per `DesignSpec § 6` mapping — reuse before creating.

### Translate-not-copy rule

Do NOT copy CDN React (`<script src="...react...cdn...">`), Babel-standalone (`<script src="...babel...">`), Alpine.js attributes (`x-data`, `x-show`, `@click`), or inline `<style>` blocks from prototype HTML into production code.
Translate prototype DOM structure to the project's stack idiom (React/Vue/native) and use the project's design-token system — do NOT reproduce inline styles.

### Match-visual-output rule

Match the visual output of the prototype — colors, spacing, layout, typography — but do NOT mirror prototype internal structure when it conflicts with the project's component conventions.
When `DesignSpec § 6` (Mapeamento para `@/components/ui`) maps a desired component to an existing project component, use the existing component and do not create a duplicate.

### designTokens passthrough rule

When `metadata.designTokens` is present, use those token values directly — do NOT re-parse `DesignSpec § 1` or extract values from prototype CSS.

### Rule-ID citation rule

When the implementation enforces or relies on a business rule from `BusinessSpec § 3`, cite the rule ID (e.g., `RN-04`) in the commit message and PR description.
When the implementation satisfies a criterion from `BusinessSpec § 9`, cite the criterion ID in the same way.

### Component-mapping rule

Before creating a new component, check `metadata.designBundle.designSpec` (or `designBundle` if spec absent).
If `DesignSpec § 6` maps the desired component to an existing project component, reuse the existing one — do NOT create a duplicate.

---

## Visual Source-of-Truth Protocol

Applies when `story.verification.strategy == "visual"` OR `metadata.prototypePaths` is non-empty OR `story.implementation.prototypeAnchor` is set. Skip entirely for non-visual stories.

### V1 — Enumerate Visible Elements

Before writing any implementation code, list every visible element in the prototype as a numbered enumeration. Cover:
- Layout regions (header, body, footer; sidebar; modal/overlay)
- Every distinct text label and its typography role (heading, subheading, body, caption)
- Every interactive control (buttons, inputs, toggles, tabs)
- Every icon, glyph, or decorative element
- Distinct spacing or typography zones that differ from the surrounding region

Numbered list format: `1. <element> — <distinguishing detail>`. Do NOT proceed to V2 until V1 is complete.

### V2 — Map Elements to Acceptance Criteria

For each numbered V1 element, identify the matching acceptance criterion (or assert "no AC match"). Use a paired list or two-column table:
- `V1.1 → AC #2 — "header shows org name"`
- `V1.5 → no AC match (candidate KNOWN-GAP)`

### V3 — Escalate Prototype-Only Elements

Any V1 element flagged "no AC match" in V2 is a KNOWN-GAP candidate. Add it to the implementation queue ONLY if it is a trivial visual detail (icon, spacing token). For non-trivial gaps, emit a `KNOWN-GAP:` trailer line in the commit body (one per element) with brief rationale. NEVER silently drop a prototype-visible element.

---

## Reference-Artifact Parity Pass (BLOCKING when triggered)

**Trigger:** Fire this pass when any of the following is true for the story being executed:
- The story JSON declares any reference artifact field (`prototypeAnchor`, `specSection`, `referenceCommand`, `referenceFixture`, `migrationDiff`, `referenceUrl`, or equivalent)
- Any `acceptanceCriteria` line contains a prototype or spec citation (e.g., a file path, URL, or section identifier)
- `verification.strategy` implies a reference artifact (`visual`, `api`, `cli`, `migration`, or `sdk`)

**Procedure:**

1. **Load reference** — read the artifact at the cited path or URL into working context.
2. **Enumerate addressable elements** in the cited region (all text nodes, attributes, fields, flags, columns, rows, etc. visible in that region).
3. **Cross-check against implementation** — for each enumerated element, determine whether the implementation addresses it.
4. **Verdict per element:**
   - `Implemented` — the element is handled by the implementation
   - `KNOWN-GAP: <element> — <reason>` — the element is not handled; append one line per gap to the commit message body

Silent drops are NOT acceptable — every enumerated element must receive an explicit verdict before the commit is written.

**Block commit until every element has a verdict.**

Agent-mode fallback: if the reference artifact is not readable from disk or network, log `Parity pass skipped — reference not readable: <path>` as a commit trailer and proceed without blocking.

### Per-Element Verdict Table (required for visual stories)

When `verification.strategy == "visual"`, append the following table to the commit body, with one row per V1-enumerated element:

| Element | Verdict | Notes |
| --- | --- | --- |
| <element from V1> | PASS \| DIVERGES \| KNOWN-GAP | <brief detail> |

Verdict values: `PASS` (implementation matches prototype), `DIVERGES` (implementation differs and that difference is intentional or unavoidable — explain in Notes), `KNOWN-GAP` (implementation does not cover this element — pair with a `KNOWN-GAP:` trailer line). The table is required only for visual stories; omit entirely for non-visual stories.

---

## Prompt Template

> This is the canonical worker prompt template. execute.md and next.md should reference this skill rather than duplicating the prompt inline.

When spawning a Task agent to execute a story:

```
You are executing a single story from the tasks file.

<project_guidelines>

[CLAUDE.md content or default rules]

</project_guidelines>

<output_rules>

Apply output compression rules from `AGENTS.md` (spawned-agent status updates: fragments over sentences, drop filler, preserve safety escapes).

</output_rules>

<project_context>

[PROJECT_PATH]   ← optional, resolved absolute path to the target project

If PROJECT_PATH is provided:
- cd to PROJECT_PATH before any work
- Load CLAUDE.md from PROJECT_PATH root
- All file operations stay within PROJECT_PATH

</project_context>

<worktree_context>

[WORKTREE_PATH]  ← optional, provided by execute.md parallel mode

If both PROJECT_PATH and WORKTREE_PATH are provided:
- cd to WORKTREE_PATH (worktree takes precedence; it is inside the project repo)
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If only WORKTREE_PATH is provided:
- cd to WORKTREE_PATH before any work
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If neither is provided:
- Work in current directory (standard sequential behavior)
- Report result — the caller (next.md/execute.md) handles status updates via the CLI

</worktree_context>

<headed_mode_context>

[HEADED_MODE]   ← optional, true when visual-follow is active

If HEADED_MODE is true:
- A headed browser session named `visual-follow` is already running (opened by execute.md)
- Use `--session visual-follow` for all agent-browser commands (do NOT pass --headed; the session inherits it)
- The session lifecycle is managed by execute.md — do NOT close it
- Navigate to verification.url at story start (step 0) for live preview

If HEADED_MODE is false or absent:
- Standard headless mode — executor owns the full browser lifecycle (open → use → close)

</headed_mode_context>

<task_pointer>

STORY_ID: [STORY_ID]

Your first action is to resolve the CLI path, then fetch full story context.

**Step 0 — Resolve CLI Path** (see [cli-path-resolution.md](../commands/references/cli-path-resolution.md) for full Layer 0–3 strategy).
Each Bash call is an isolated shell — `$AIMI_CLI` is never inherited. Re-read from cache at the top of every Bash call that needs it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-story-context [STORY_ID]
```
Parse the returned JSON for four top-level fields:
- `story` — contains `id`, `title`, `description`, `acceptanceCriteria`, `notes`, `tasks`, `implementation`, `verification`, `gate`
- `metadata` — contains `prototypePaths`, `prototypeAnchor`, `branchName`, and other session metadata
- `skills` — array of required skill blocks; treat each `.content` as additional project conventions
- `designContext` — contains `.decisions` (design intent) and `.bundleGuidance` (may cite spec file paths)

Use all four keys for subsequent steps. If the command fails, report failure immediately and stop.

</task_pointer>

<visual_verification>

Visual verification is **advisory** — failures do NOT block the story commit.

<headed_mode_visual>

0. **Navigate to verification URL at story start (before implementation):**
   `agent-browser --session visual-follow open [verification.url]`
   This gives the user a live preview in the headed browser while implementation proceeds.

1. **Check agent-browser availability:**
   Run `command -v agent-browser`. If not found, note "visual verification skipped — agent-browser not installed" in your report and proceed to commit.

2. **Navigate to verification URL:**
   `agent-browser --session visual-follow open [verification.url]`

3. **Take screenshot:**
   `agent-browser --session visual-follow screenshot /tmp/verify-[STORY_ID].png`

4. **Evaluate screenshot against expected outcome:**
   Use the Read tool to view `/tmp/verify-[STORY_ID].png`.
   Compare what you see against `verification.expect` (natural language description).
   Record whether the visual matches expectations (pass/fail + reasoning).

5. **Cleanup — SKIP:** Session lifecycle is managed by execute.md. Do NOT run `agent-browser close`.

6. **Report result:**
   - If visual check passes: note "visual verification passed" in your report.
   - If visual check fails or errors: note "visual verification failed — [reason]" in your report so the caller can set `verification.status` to `failed`. Do NOT fail the story — proceed to commit.
   - If agent-browser was not installed: note "visual verification skipped" so the caller can set `verification.status` to `skipped`.

</headed_mode_visual>

<headless_mode_visual>

1. **Check agent-browser availability:**
   Run `command -v agent-browser`. If not found, note "visual verification skipped — agent-browser not installed" in your report and proceed to commit.

2. **Open the page:**
   `agent-browser open [verification.url]`

3. **Take screenshot:**
   `agent-browser screenshot /tmp/verify-[STORY_ID].png`

4. **Evaluate screenshot against expected outcome:**
   Use the Read tool to view `/tmp/verify-[STORY_ID].png`.
   Compare what you see against `verification.expect` (natural language description).
   Record whether the visual matches expectations (pass/fail + reasoning).

5. **Cleanup:**
   `agent-browser close`

6. **Report result:**
   - If visual check passes: note "visual verification passed" in your report.
   - If visual check fails or errors: note "visual verification failed — [reason]" in your report so the caller can set `verification.status` to `failed`. Do NOT fail the story — proceed to commit.
   - If agent-browser was not installed: note "visual verification skipped" so the caller can set `verification.status` to `skipped`.

</headless_mode_visual>

</visual_verification>

<previous_notes>

[story.notes]

</previous_notes>

<prototype_context>

When `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, read each prototype file yourself using the Read tool.

- For each path in `metadata.prototypePaths[]` (and `story.implementation.prototypeAnchor` if set), resolve the absolute path as `$AIMI_ROOT/<path>` and read it.
- If a prototype file does not exist at the resolved path, log: `prototype <path> missing — skipped` and continue.
- `.html` files are pixel-reference prototypes; `.json` files are design-token sidecars.
- Read all available prototypes before writing any implementation code.

</prototype_context>

<tools>

Use built-in tools directly: Read, Write, Edit, Bash, Grep, Glob.
Do NOT invoke these via the Skill tool — "write" is a Write tool, not a skill.

</tools>

<project_root_boundary>

All file operations MUST stay within the project boundary: PROJECT_PATH when set, otherwise the git repository root.
- Do NOT read or modify files outside the project boundary
- Worktree paths (.worktrees/ inside git root) are allowed
- Never use ../ traversal to escape the project boundary
- If a task requires accessing external files, report failure instead

</project_root_boundary>

<execution_flow>

0a. **Bootstrap (FIRST ACTION):** Re-read `$AIMI_CLI` from cache (per-call re-read — see `<task_pointer>` Step 0 above), then run `$AIMI_CLI get-story-context $STORY_ID` and parse the returned JSON. Extract:
    - `story` — full story object (`id`, `title`, `description`, `acceptanceCriteria`, `notes`, `tasks`, `implementation`, `verification`, `gate`)
    - `metadata` — session metadata (`prototypePaths`, `prototypeAnchor`, `branchName`, etc.)
    - `skills` — array of required skill blocks; for each entry, read its `.content` verbatim as additional project conventions (treat each as a required SKILL.md conventions block, in addition to project CLAUDE.md)
    - `designContext` — read `.decisions` as design intent for any UI-touching work; if `.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code
    If this command fails, report failure immediately and stop.
0b. If `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, read each prototype file with the Read tool:
    - Resolve path as `$AIMI_ROOT/<path>` for each entry in `metadata.prototypePaths[]` and for `story.implementation.prototypeAnchor` when set
    - If a file does not exist at the resolved path, log: `prototype <path> missing — skipped` and continue
0c. If PROJECT_PATH is set, cd to PROJECT_PATH; if WORKTREE_PATH is also set, cd to WORKTREE_PATH instead (takes precedence)
1. Read CLAUDE.md for project conventions (from PROJECT_PATH root when set)
2. Implement the story requirements. When `story.tasks[]` is present, follow it as the ordered recipe (creation → integration wiring → local verification) — pay particular attention to any `"Wire <X> into <Y>"` entries, which encode cross-story file wiring that AC alone cannot enforce. `tasks[]` is planner guidance; `acceptanceCriteria` remains the completion gate.
3. Verify ALL acceptance criteria are met
3.5. If `story.verification.strategy == "visual"` OR `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set: run the Visual Source-of-Truth Protocol (V1/V2/V3 enumeration → mapping → escalation) BEFORE writing code, then proceed to the Reference-Artifact Parity Pass.
3.6. Run Reference-Artifact Parity Pass (see full procedure in the named section above) if the story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Block commit until every element has a verdict; on unreadable reference, log `Parity pass skipped — reference not readable: <path>` as a commit trailer and proceed.
4. Run typecheck: npx tsc --noEmit
5. If all checks pass, commit:
   a. Stage only story-related files: `git add [changed files]` (never use `-A` or `.` — avoid staging unrelated files)
   b. Commit with conventional format: `git commit -m "type(scope): Story title"`
      Commit types: **feat** | fix | refactor | docs | test | chore
   c. Verify the commit landed: `git log -1 --oneline`

   **FAIL FAST — Commit failure:**
   If `git commit` exits non-zero OR `git log -1 --oneline` does not show the expected commit:
   - Do NOT retry or attempt to fix
   - Report failure immediately with the error output
   - The caller will handle recovery

6. If WORKTREE_PATH is set: do NOT update tasks file — return result report instead
   If no WORKTREE_PATH: do NOT update tasks file directly — the caller (next.md/execute.md) handles status updates via the CLI

</execution_flow>

<on_failure>

If you cannot complete the story:

1. Do NOT update the tasks file (the caller handles status via CLI)
2. Return with clear failure report including error details
3. The caller will mark the story as failed and handle dependent stories

</on_failure>
```

---

## Compact Template

> Condensed variant for subsequent stories in a wave session. Each Task agent gets fresh context (no memory carryover), so static sections are condensed to one-line summaries — NOT omitted. Story-specific and context-varying sections remain in full. Reduces prompt size by collapsing static sections; actual savings vary with story content and have not been benchmarked.

When spawning a Task agent for subsequent stories (after the first story in a session):

```
You are executing a single story from the tasks file.

<project_guidelines>
Follow project guidelines from CLAUDE.md/AGENTS.md. Apply output compression rules from AGENTS.md.
</project_guidelines>

<project_context>

[PROJECT_PATH]   ← optional, resolved absolute path to the target project

If PROJECT_PATH is provided:
- cd to PROJECT_PATH before any work
- Load CLAUDE.md from PROJECT_PATH root
- All file operations stay within PROJECT_PATH

</project_context>

<worktree_context>

[WORKTREE_PATH]  ← optional, provided by execute.md parallel mode

If both PROJECT_PATH and WORKTREE_PATH are provided:
- cd to WORKTREE_PATH (worktree takes precedence; it is inside the project repo)
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If only WORKTREE_PATH is provided:
- cd to WORKTREE_PATH before any work
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If neither is provided:
- Work in current directory (standard sequential behavior)
- Report result — the caller (next.md/execute.md) handles status updates via the CLI

</worktree_context>

<headed_mode_context>

[HEADED_MODE]   ← optional, true when visual-follow is active

If HEADED_MODE is true:
- A headed browser session named `visual-follow` is already running (opened by execute.md)
- Use `--session visual-follow` for all agent-browser commands (do NOT pass --headed; the session inherits it)
- The session lifecycle is managed by execute.md — do NOT close it
- Navigate to verification.url at story start (step 0) for live preview

If HEADED_MODE is false or absent:
- Standard headless mode — executor owns the full browser lifecycle (open → use → close)

</headed_mode_context>

<task_pointer>
STORY_ID: [STORY_ID]

First action — re-read `$AIMI_CLI` from cache, then fetch story context:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-story-context [STORY_ID]
```

Parse `{story, metadata, skills, designContext}` from the returned JSON. For each entry in `skills[]`, read its `.content` verbatim as additional project conventions. Read `designContext.decisions` as design intent for UI-touching work. If `designContext.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code. If the command fails, report failure and stop.
</task_pointer>

<prototype_context>
When `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, read each prototype file with the Read tool (resolve as `$AIMI_ROOT/<path>`). Log `prototype <path> missing — skipped` for any missing file and continue. Read all available prototypes before writing implementation code.
</prototype_context>

<tools>
Use standard tools: Read, Write, Edit, Bash, Grep, Glob. Do NOT invoke these via the Skill tool.
</tools>

<project_root_boundary>
CRITICAL: Stay within project root. Never read/write outside project boundary. Worktree paths (.worktrees/) are allowed. Never use ../ traversal to escape. If external access is needed, report failure.
</project_root_boundary>

<execution_flow>
Bootstrap: re-read `$AIMI_CLI` from cache (per-call re-read one-liner — see `<task_pointer>` above), run `$AIMI_CLI get-story-context $STORY_ID`, parse `{story, metadata, skills, designContext}`. For each entry in `skills[]`, read its `.content` verbatim as additional project conventions (in addition to CLAUDE.md). Read `designContext.decisions` as design intent for UI-touching work; if `designContext.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code. Read prototype files from `metadata.prototypePaths[]` and `story.implementation.prototypeAnchor` via Read tool (log missing, skip). Then follow standard execution flow: read criteria → implement (follow `story.tasks[]` as the ordered recipe when present; treat `"Wire <X> into <Y>"` entries as mandatory cross-story integration steps; AC remains the completion gate) → test → commit. If `story.verification.strategy == "visual"` OR `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, run the Visual Source-of-Truth Protocol (V1/V2/V3) before writing code. Stage only story-related files (never `-A` or `.`). Commit format: `git commit -m "type(scope): Story title"`. Verify with `git log -1 --oneline`. On commit failure: report immediately, do not retry. Do NOT update tasks file — caller handles status. When a reference artifact is declared, run the Reference-Artifact Parity Pass before committing (see full named section above).
</execution_flow>

<on_failure>
On failure: do NOT update the tasks file. Return clear failure report with error details. The caller handles status and dependent stories.
</on_failure>
```

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** update the tasks file — the caller (next.md or execute.md leader) handles all status changes via CLI
2. **Do NOT** run cascade-skip — the caller handles dependent story skipping
3. **Return** a clear failure report with:
   - Story ID
   - Error description
   - Any partial work committed (or not)
4. The caller will mark the story as failed and handle dependent stories

---

## Checklist

Before completing a story:

- [ ] All file operations stayed within project root (no parent directory access)
- [ ] All acceptance criteria verified
- [ ] Typecheck passes (`npx tsc --noEmit`)
- [ ] Changes committed with proper format (one commit per story, never skip hooks)
- [ ] Commit verified via `git log -1 --oneline`
- [ ] Result report returned to caller (do NOT update tasks file directly — caller handles via CLI)
