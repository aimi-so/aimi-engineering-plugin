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

Fires only when the inlined story payload includes `metadata.designBundle`. The caller (execute.md) injects the `[DESIGN_BUNDLE_CONTEXT]` XML block; the executor does not test for `designBundle` itself.

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
   - `KNOWN GAP: <element> — <reason>` — the element is not handled; append one line per gap to the commit message body

Silent drops are NOT acceptable — every enumerated element must receive an explicit verdict before the commit is written.

**Block commit until every element has a verdict.**

Agent-mode fallback: if the reference artifact is not readable from disk or network, log `Parity pass skipped — reference not readable: <path>` as a commit trailer and proceed without blocking.

---

## Prompt Template

> This is the canonical worker prompt template. execute.md and next.md should reference this skill rather than duplicating the prompt inline.

When spawning a Task agent to execute a story:

```
You are executing a single story from the tasks file.

<project_guidelines>

[CLAUDE.md content or default rules]

</project_guidelines>

<required_skills>

Apply these skill conventions in addition to project guidelines. (Section omitted when no skills are declared for this story.)

[REQUIRED_SKILLS]

</required_skills>

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

<your_story>

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

</your_story>

<acceptance_criteria>

[ACCEPTANCE_CRITERIA_BULLETED]

</acceptance_criteria>

<tasks>

Mechanical sub-steps (planner guidance only — not acceptance criteria; complete the deliverable as a whole)

[TASKS_NUMBERED_LIST]

</tasks>

(Omit the <tasks> block above when story.tasks is absent or empty.)

<key_files>

[implementation.files — bulleted list of file paths the story is expected to touch]

</key_files>

<approach>

[implementation.approach — brief description of the implementation approach]

</approach>

<verification_command>

[implementation.verify — command or instruction to verify the implementation]

</verification_command>

<verification>

Strategy: [verification.strategy]
Expected: [verification.expect — omit line if absent]

</verification>

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

<design_context>

[DESIGN_CONTEXT]

</design_context>

<prototype_context>

Prototype HTML variants and optional tokens JSON loaded from `metadata.prototypePaths[]`. Each `.html` file is wrapped in `<prototype_html label="X" path="...">` tags (labels A, B, C…); each `.json` sidecar is wrapped in `<prototype_tokens path="...">` tags. Reference these variants when implementing UI stories — prefer the labelled variant that best matches the story's design intent. When a story has a single clearly relevant prototype, label A is pinned to that prototype so it receives highest attention via load order. Omit this section when empty.

[PROTOTYPE_CONTEXT]

</prototype_context>

<design_bundle_context>

Design bundle fidelity guidance — spec-aware read order, translate-not-copy, match-visual-output, designTokens passthrough, component-mapping, and rule-ID citation rules (see `## Design Bundle Fidelity Guidance`). Omit when `metadata.designBundle` is absent.

[DESIGN_BUNDLE_CONTEXT]

</design_bundle_context>

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

0. If PROJECT_PATH is set, cd to PROJECT_PATH; if WORKTREE_PATH is also set, cd to WORKTREE_PATH instead (takes precedence)
1. Read CLAUDE.md for project conventions (from PROJECT_PATH root when set)
2. Implement the story requirements
3. Verify ALL acceptance criteria are met
3.5. Run Reference-Artifact Parity Pass (see full procedure in the named section above) if the story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Block commit until every element has a verdict; on unreadable reference, log `Parity pass skipped — reference not readable: <path>` as a commit trailer and proceed.
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

<required_skills>
Apply these skill conventions in addition to project guidelines. (Section omitted when no skills are declared for this story.)

[REQUIRED_SKILLS]
</required_skills>

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

<your_story>

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

</your_story>

<acceptance_criteria>

[ACCEPTANCE_CRITERIA_BULLETED]

</acceptance_criteria>

<tasks>
Mechanical sub-steps (planner guidance only — not acceptance criteria; complete the deliverable as a whole)

[TASKS_NUMBERED_LIST]
</tasks>

(Omit the <tasks> block above when story.tasks is absent or empty.)

<key_files>

[implementation.files — bulleted list of file paths the story is expected to touch]

</key_files>

<approach>

[implementation.approach — brief description of the implementation approach]

</approach>

<verification_command>

[implementation.verify — command or instruction to verify the implementation]

</verification_command>

<verification>

Strategy: [verification.strategy]
Expected: [verification.expect — omit line if absent]

</verification>

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

<design_context>

[DESIGN_CONTEXT]

</design_context>

<prototype_context>
Prototype HTML variants and optional tokens JSON from `metadata.prototypePaths[]`. `.html` files wrapped as `<prototype_html label="X" path="...">`, `.json` sidecars as `<prototype_tokens path="...">`. Use the best-matching variant for UI implementation. Label A is pinned to the story's most-relevant prototype when one is identified via `implementation.prototypeAnchor` or AC citation. Omit when empty.

[PROTOTYPE_CONTEXT]
</prototype_context>

<design_bundle_context>
Design bundle fidelity: spec-aware read order (businessSpec → designSpec → chats → prototypes → existing components), translate-not-copy (no CDN React/Babel/Alpine/inline styles), match-visual-output, designTokens passthrough, component-mapping, rule-ID citation. Omit when `metadata.designBundle` absent.

[DESIGN_BUNDLE_CONTEXT]
</design_bundle_context>

<tools>
Use standard tools: Read, Write, Edit, Bash, Grep, Glob. Do NOT invoke these via the Skill tool.
</tools>

<project_root_boundary>
CRITICAL: Stay within project root. Never read/write outside project boundary. Worktree paths (.worktrees/) are allowed. Never use ../ traversal to escape. If external access is needed, report failure.
</project_root_boundary>

<execution_flow>
Follow standard execution flow: read criteria → implement → test → commit. Stage only story-related files (never `-A` or `.`). Commit format: `git commit -m "type(scope): Story title"`. Verify with `git log -1 --oneline`. On commit failure: report immediately, do not retry. Do NOT update tasks file — caller handles status. When a reference artifact is declared, run the Reference-Artifact Parity Pass before committing (see full named section above).
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
