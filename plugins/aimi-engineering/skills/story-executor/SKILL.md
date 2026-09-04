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
0. Establish the working directory — see `<worktree_context>` below for the exact rule. In short: WORKTREE_PATH wins when given, but when PROJECT_PATH names a *subdirectory* of the repo rather than its own repository, the destination is that subdirectory **inside** the worktree, not the worktree root
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

## Result Contract (REQUIRED for all workers)

Every worker MUST end its final message with a `<result_json>` block. The orchestrator parses this block as its source of truth — anything outside the block is debugging prose that the leader does NOT consume in the happy path.

Required shape (omit optional fields when empty rather than emitting null/empty arrays):

```
<result_json>
{
  "status": "ok | failed | skipped",
  "commit": "<short SHA, or null when no commit was made>",
  "tests": {"passed": <int>, "failed": <int>, "total": <int>},   // optional, omit when no test was run
  "typecheck": "ok | failed | skipped",                            // optional
  "knownGaps": ["<short gap label>"],                              // optional, omit when empty
  "deviations": ["<short deviation label>"],                       // optional, omit when empty
  "failureCause": "<one-line cause>"                               // REQUIRED when status != ok
}
</result_json>
```

Rules:

- The block MUST be the LAST thing in the worker's final message. Anything after it is ignored by the orchestrator.
- The JSON inside MUST parse cleanly (no trailing commas, no comments).
- `status` is mandatory. `commit` is mandatory but may be `null` when intentionally no commit was created.
- `failureCause` is mandatory when `status` is `failed` or `skipped` — one short sentence the leader will surface to the user.
- Prose OUTSIDE the block is for human debugging only. Keep it short; the orchestrator does not need it.
- Examples — success:
  ```
  <result_json>
  {"status":"ok","commit":"a6cd4678","tests":{"passed":7,"failed":0,"total":7},"typecheck":"ok"}
  </result_json>
  ```
  Failure:
  ```
  <result_json>
  {"status":"failed","commit":null,"failureCause":"Pre-commit hook failed: tsc not in PATH"}
  </result_json>
  ```
  Skipped (gate blocked):
  ```
  <result_json>
  {"status":"skipped","commit":null,"failureCause":"Decision gate pending: choose OAuth provider"}
  </result_json>
  ```

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

If both PROJECT_PATH and WORKTREE_PATH are provided, the destination depends on whether PROJECT_PATH is its own repository or a subdirectory of one. `worktree-manager.sh` creates every worktree under `$(git rev-parse --show-toplevel)/.worktrees`, so a worktree sits beside the *repository root* — which is the same place as PROJECT_PATH only when PROJECT_PATH is itself that root. Decide it rather than assume it:

```bash
PROJECT_TOPLEVEL=$(git -C "$PROJECT_PATH" rev-parse --show-toplevel)
if [ "$PROJECT_TOPLEVEL" = "$PROJECT_PATH" ]; then
  # PROJECT_PATH is its own repository (multi-repo sibling layout):
  # the worktree already IS the project.
  cd "$WORKTREE_PATH"
else
  # PROJECT_PATH is a subdirectory of a larger repository (monorepo layout):
  # the worktree is the repo root, and the project sits at the same
  # relative path inside it.
  cd "$WORKTREE_PATH/${PROJECT_PATH#"$PROJECT_TOPLEVEL"/}"
fi
```

Getting this wrong is issue #105: a monorepo story ran from the repository root while its `implementation.verify` was written for the project directory, so a bare `bun run typecheck` failed for want of a `package.json` one level down. The fix belongs here, in the cd — never in what a story author writes. A `verify` must not carry a `cd <project> &&` prefix; by the time it runs you are already there.

Then, in either case:
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
TASKS_FILE_PATH: [TASKS_FILE_PATH]

Your first action is to resolve the CLI path, then fetch full story context.

**Step 0 — Resolve CLI Path** (see [cli-path-resolution.md](../commands/references/cli-path-resolution.md) for full Layer 0–3 strategy).
Each Bash call is an isolated shell — `$AIMI_CLI` is never inherited. Re-read from cache at the top of every Bash call that needs it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-story-context [STORY_ID] --tasks-file [TASKS_FILE_PATH]
```

`--tasks-file [TASKS_FILE_PATH]` is the orchestrator's own already-resolved tasks file, threaded through explicitly so this call reads it even when a sibling split orchestrator's `init-session` last overwrote the shared current-tasks pointer — never fall back to the bare form.

Parse the returned JSON for five top-level fields:
- `story` — contains `id`, `title`, `description`, `acceptanceCriteria`, `notes`, `tasks`, `implementation`, `verification`, `gate`
- `metadata` — session metadata. This file reads exactly three of its keys: `designBundle`, `designTokens` and `prototypePaths`. `prototypeAnchor` is NOT one of them — it is `story.implementation.prototypeAnchor`, and every step below reads it from there.
- `skills` — array of required skill blocks; treat each `.content` as additional project conventions
- `designContext` — contains `.decisions` (design intent) and `.bundleGuidance` (may cite spec file paths)
- `skillsDropped` — array of `{name, bytes, reason}` for skills the 100KB aggregate cap excluded; `[]` when nothing was dropped, so the key is always present and always safe to read. A non-empty entry means a skill the story declared is NOT in `skills[]` — say so in the completion report rather than proceeding as if it had been read.

Use all five keys for subsequent steps. If the command fails, report failure immediately and stop.

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

0a. **Bootstrap (FIRST ACTION):** Re-read `$AIMI_CLI` from cache (per-call re-read — see `<task_pointer>` Step 0 above), then run `$AIMI_CLI get-story-context $STORY_ID --tasks-file $TASKS_FILE_PATH` and parse the returned JSON. Extract:
    - `story` — full story object (`id`, `title`, `description`, `acceptanceCriteria`, `notes`, `tasks`, `implementation`, `verification`, `gate`)
    - `metadata` — session metadata; the keys this flow reads are `designBundle`, `designTokens` and `prototypePaths` (`prototypeAnchor` is not among them — it lives at `story.implementation.prototypeAnchor`)
    - `skills` — array of required skill blocks; for each entry, read its `.content` verbatim as additional project conventions (treat each as a required SKILL.md conventions block, in addition to project CLAUDE.md)
    - `designContext` — read `.decisions` as design intent for any UI-touching work; if `.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code
    - `skillsDropped` — `[]` when every declared skill was hydrated; a non-empty `{name, bytes, reason}` entry names a skill that is NOT in `skills[]` because the 100KB cap excluded it. Report it rather than proceeding as if that skill had been read.
    If this command fails, report failure immediately and stop.
0b. If `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, read each prototype file with the Read tool:
    - Resolve path as `$AIMI_ROOT/<path>` for each entry in `metadata.prototypePaths[]` and for `story.implementation.prototypeAnchor` when set
    - If a file does not exist at the resolved path, log: `prototype <path> missing — skipped` and continue
0c. If PROJECT_PATH is set, cd to PROJECT_PATH; if WORKTREE_PATH is also set, cd to WORKTREE_PATH instead (takes precedence).

    **When WORKTREE_PATH is set and that cd FAILS, stop and report — never fall through to whatever directory you happen to be in.** Until now this step had no failure branch at all for the worktree path, which is what made the bad outcome silent rather than loud. There is nothing to recover here and nowhere safe to continue from: the directory the orchestrator named does not exist or cannot be entered, so the CWD you are still holding belongs to someone else's tree — the orchestrator's own checkout, or a sibling story's worktree. Carrying on writes this story's commit into that tree, and the damage is invisible from both ends: the tasks file records a green story while the branch that was supposed to carry it stays empty, and a second story's branch acquires a change nobody wrote for it. Emit `<result_json>` with `"status":"failed"`, `"commit": null`, and a `failureCause` naming the exact path that could not be entered.
1. Read CLAUDE.md for project conventions (from PROJECT_PATH root when set)
1.5. **Pre-run `story.implementation.verify` once, before implementing anything, and record the result.** Skip this step entirely when `implementation.verify` is absent or empty — it does not run and warns nothing, the same treatment step 4 gives the absent case (`implementation{}` is optional in schema v3.3). When present, run it exactly as written, from the working directory established in step 0c, with `TASKS_FILE_PATH` exported into its environment — a `verify` that needs its own tasks file (e.g. to read `metadata.baseRef`) can then resolve it directly rather than falling back to the shared `current-tasks` pointer a sibling split orchestrator's `init-session` may have since overwritten. If this pre-run exits ZERO — the verify already passes before any work exists — emit a warning, carried in the completion report, that the check does not discriminate the before-state from the after-state: a verify that passes both before and after proves nothing about what was done. This warning NEVER blocks, in any mode. Name its legitimate cause rather than accusing the verify of being broken: a story re-executed over partial work already done can genuinely pass this early run with nothing wrong — a warning that accuses wrongly gets ignored the third time it fires. Running the verify twice per story is a deliberate trade-off, accepted on purpose even though it doubles the run time of a story whose verify is a long suite: a verify that always passes reports success, and discovering that later costs more than the second run.

    In the same step, run `$AIMI_CLI verify-probe $STORY_ID --tasks-file $TASKS_FILE_PATH` from that same working directory and list, in the completion report, every returned entry whose `discriminates` is `false` — under the sentence that these assertions already pass before the work. The pre-run above is at the granularity of the whole SCRIPT; this is at the granularity of the ASSERTION, and the two answer different questions. Under the `set -e` most verifies open with, the script stops at its first failing assertion and every assertion after it never runs at all — so a verify that exits non-zero here can still be carrying assertions that would have passed before a line was written, and the script-level pre-run says nothing about them. This listing is a WARNING and NEVER a block, exactly like the pre-run: a non-discriminating assertion is not automatically wrong. Some are guardrails by design — an assertion that a prior story's behaviour has not regressed is *supposed* to pass before and after, and it belongs in the report as one. What the list is for is the other kind, the assertion that asserts nothing about this story, which no one can see while it hides behind the first clause that fails. If the verb is unavailable (an older CLI, or `python3` missing), say so in one line and carry on — its absence never fails a story.
2. Implement the story requirements. When `story.tasks[]` is present, follow it as the ordered recipe (creation → integration wiring → local verification) — pay particular attention to any `"Wire <X> into <Y>"` entries, which encode cross-story file wiring that AC alone cannot enforce. `tasks[]` is planner guidance; `acceptanceCriteria` remains the completion gate.

    **Read `story.implementation.approach` first: it is the strategy the planner chose, and it is yours to follow.** It is optional in schema v3.3 — when it is absent or empty, do nothing here and invent no strategy of your own, the same treatment step 4 gives an absent `verify`. When it is present and non-empty, it is not one opinion to weigh against your own first idea: the planner wrote it holding the research, the outline and the sibling stories, and you hold one story. Follow it, or diverge and say so — a `deviations[]` entry in the completion report naming the approach and the reason you went another way. The one thing that is never acceptable is diverging in silence, which leaves the plan and the code disagreeing with no one able to see it.

    Why this field has a reader at all, since the record says otherwise: audit finding #4 observed that `implementation.approach` had no reader in the executor and concluded it should be retired. That observation was right and the conclusion was wrong, and measurement is what inverted it. As of 2026-09-03, **nine** files across `agents/`, `commands/`, `skills/` and `scripts/` read or write the field — `aimi-cross-story-auditor.md`, `aimi-story-expander.md`, `deepen.md`, `execute.md`, `next.md`, `plan.md`, `story_merge.py`, `architecture-foundation/SKILL.md`, `typescript-node-conventions/SKILL.md` (`deepen.md` is the one that does not match a literal `implementation.approach` grep — it writes `approach` as a key under `implementation`). `/aimi:deepen` writes it, `next.md` renders it to the user, and four of the cross-story auditor's six concerns derive from it. The executor was the single place with no reader; retiring the field would have silently disabled the other nine to fix that one. So the missing reader was added instead — this step. Anyone re-reading finding #4 will reach the retire conclusion again unless they read this paragraph first.
3. Verify ALL acceptance criteria are met
3.5. If `story.verification.strategy == "visual"` OR `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set: run the Visual Source-of-Truth Protocol (V1/V2/V3 enumeration → mapping → escalation) BEFORE writing code, then proceed to the Reference-Artifact Parity Pass.
3.6. Run Reference-Artifact Parity Pass (see full procedure in the named section above) if the story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Block commit until every element has a verdict; on unreadable reference, log `Parity pass skipped — reference not readable: <path>` as a commit trailer and proceed.
4. Run `story.implementation.verify` exactly as written, from the working directory established in step 0c, with `TASKS_FILE_PATH` exported into its environment (same export as the step 1.5 pre-run). `implementation` is optional in schema v3.3 — when it or `verify` is absent or empty, do exactly what you already do (step 3's acceptance-criteria check) and invent no command. When `verify` is present, a non-zero exit FAILS the story: report the failure (include the verify's output) and do NOT commit — this is not advisory.
4.5. **When WORKTREE_PATH is set, confirm the checked-out branch is THIS story's before staging anything.** Run `git branch --show-current` and require the name to END in this story's id (`-<STORY_ID>` — e.g. a branch ending `-US-003` for story US-003). On a mismatch, stop: do NOT stage, do NOT commit, and report failure with both the branch actually found and the id expected. A worktree whose branch is not this story's is a worktree this story was never handed, and committing into it puts one story's work onto another story's branch — where the wave that merges them interleaves two unrelated changes with nothing marking the seam. This is the last moment at which that stays cheap to catch: once the commit lands, undoing it means rewriting a branch that belongs to someone else.
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
7. **Emit the `<result_json>` block as the LAST element of your final message** (see "Result Contract" section above). The orchestrator parses this block as source of truth — prose outside the block is debugging only and is NOT consumed by the leader.

</execution_flow>

<on_failure>

If you cannot complete the story:

1. Do NOT update the tasks file (the caller handles status via CLI)
2. Emit `<result_json>` with `"status":"failed"` and a one-line `"failureCause"` — the leader reads this to decide cascade-skip and report to the user.
3. Optional prose (above the block) may include longer error details for human debugging.

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

If both PROJECT_PATH and WORKTREE_PATH are provided, the destination depends on whether PROJECT_PATH is its own repository or a subdirectory of one. `worktree-manager.sh` creates every worktree under `$(git rev-parse --show-toplevel)/.worktrees`, so a worktree sits beside the *repository root* — which is the same place as PROJECT_PATH only when PROJECT_PATH is itself that root. Decide it rather than assume it:

```bash
PROJECT_TOPLEVEL=$(git -C "$PROJECT_PATH" rev-parse --show-toplevel)
if [ "$PROJECT_TOPLEVEL" = "$PROJECT_PATH" ]; then
  # PROJECT_PATH is its own repository (multi-repo sibling layout):
  # the worktree already IS the project.
  cd "$WORKTREE_PATH"
else
  # PROJECT_PATH is a subdirectory of a larger repository (monorepo layout):
  # the worktree is the repo root, and the project sits at the same
  # relative path inside it.
  cd "$WORKTREE_PATH/${PROJECT_PATH#"$PROJECT_TOPLEVEL"/}"
fi
```

Getting this wrong is issue #105: a monorepo story ran from the repository root while its `implementation.verify` was written for the project directory, so a bare `bun run typecheck` failed for want of a `package.json` one level down. The fix belongs here, in the cd — never in what a story author writes. A `verify` must not carry a `cd <project> &&` prefix; by the time it runs you are already there.

Then, in either case:
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
TASKS_FILE_PATH: [TASKS_FILE_PATH]

First action — re-read `$AIMI_CLI` from cache, then fetch story context:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-story-context [STORY_ID] --tasks-file [TASKS_FILE_PATH]
```

`--tasks-file [TASKS_FILE_PATH]` is the orchestrator's own already-resolved tasks file — pass it explicitly rather than the bare form, which would fall back to whichever sibling split orchestrator's `init-session` call last wrote the shared current-tasks pointer.

Parse `{story, metadata, skills, designContext, skillsDropped}` from the returned JSON. For each entry in `skills[]`, read its `.content` verbatim as additional project conventions; a non-empty `skillsDropped[]` names a declared skill the 100KB cap excluded, and belongs in the completion report. Read `designContext.decisions` as design intent for UI-touching work. If `designContext.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code. If the command fails, report failure and stop.
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
Bootstrap: re-read `$AIMI_CLI` from cache (per-call re-read one-liner — see `<task_pointer>` above), run `$AIMI_CLI get-story-context $STORY_ID --tasks-file $TASKS_FILE_PATH`, parse `{story, metadata, skills, designContext, skillsDropped}`. For each entry in `skills[]`, read its `.content` verbatim as additional project conventions (in addition to CLAUDE.md); a non-empty `skillsDropped[]` names a declared skill the 100KB cap excluded, and belongs in the completion report. Read `designContext.decisions` as design intent for UI-touching work; if `designContext.bundleGuidance` cites spec file paths (DesignSpec / BusinessSpec), use the Read tool to load those files before authoring implementation code. Read prototype files from `metadata.prototypePaths[]` and `story.implementation.prototypeAnchor` via Read tool (log missing, skip). **cd to the working directory `<worktree_context>` establishes; when WORKTREE_PATH is set and that cd fails, STOP and report `"status":"failed"` with the unenterable path in `failureCause` — never fall through to the directory you are already in, which belongs to the orchestrator or to a sibling story and would take this story's commit silently.** Then follow standard execution flow: read criteria → **pre-run `story.implementation.verify` once, before implementing anything, with `TASKS_FILE_PATH` exported into its environment** (skipped entirely when absent or empty; a ZERO exit here means the check does not discriminate before from after — warn in the completion report, NEVER block, and see step 1.5 above for the legitimate cause it must name, why the second run is worth its cost, and why the export matters — a `verify` may need to resolve its own tasks file rather than the shared `current-tasks` pointer) → **in the same step run `$AIMI_CLI verify-probe $STORY_ID --tasks-file $TASKS_FILE_PATH`** from the same directory and list every entry whose `discriminates` is `false` as assertions that already pass before the work (the pre-run above only sees the whole script; under `set -e` the script stops at its first failure and hides every assertion after it, so a verify that FAILS here can still be full of ones that prove nothing — warning only, never a block, and a guardrail assertion legitimately shows up in this list; an unavailable verb is one reported line, never a failure) → implement (follow `story.tasks[]` as the ordered recipe when present; treat `"Wire <X> into <Y>"` entries as mandatory cross-story integration steps; AC remains the completion gate; **follow `story.implementation.approach` as the strategy the planner chose — optional in schema v3.3, so absent or empty means invent none, and a divergence from a present one goes in the report's `deviations[]` with its reason, never unsaid**) → run `story.implementation.verify` exactly as written from the working directory established above, `TASKS_FILE_PATH` still exported (optional in schema v3.3 — absent/empty means do exactly what you already do and invent no command; a non-zero exit FAILS the story, report and do NOT commit) → **when WORKTREE_PATH is set, check `git branch --show-current` ENDS in this story's id (`-<STORY_ID>`) before staging anything; a mismatch is a failure, not a warning — do not stage, do not commit, and report the branch found beside the id expected** → commit. If `story.verification.strategy == "visual"` OR `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set, run the Visual Source-of-Truth Protocol (V1/V2/V3) before writing code. Stage only story-related files (never `-A` or `.`). Commit format: `git commit -m "type(scope): Story title"`. Verify with `git log -1 --oneline`. On commit failure: report immediately, do not retry. Do NOT update tasks file — caller handles status. When a reference artifact is declared, run the Reference-Artifact Parity Pass before committing (see full named section above). **End your final message with the `<result_json>` block per the Result Contract section — the orchestrator parses ONLY that block; prose outside is debugging only.**
</execution_flow>

<on_failure>
On failure: do NOT update the tasks file. Emit `<result_json>` with `"status":"failed"` and a one-line `"failureCause"` as the LAST element of your message — that field is what the leader reads to decide cascade-skip and surface to the user. Optional prose above the block may include longer error details.
</on_failure>
```

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** update the tasks file — the caller (next.md or execute.md leader) handles all status changes via CLI
2. **Do NOT** run cascade-skip — the caller handles dependent story skipping
3. **Emit `<result_json>` with `"status":"failed"`** as the LAST element of your final message. Include `"commit": null` (or partial commit SHA if one landed) and `"failureCause": "<one-line cause>"` so the leader can surface it to the user without parsing prose.
4. Optional prose above the block may include longer error details for human debugging.
5. The caller will mark the story as failed and handle dependent stories based on `result_json`.

---

## Checklist

Before completing a story:

- [ ] All file operations stayed within project root (no parent directory access)
- [ ] All acceptance criteria verified
- [ ] `story.implementation.verify` ran (when present) and exited zero
- [ ] Changes committed with proper format (one commit per story, never skip hooks)
- [ ] Commit verified via `git log -1 --oneline`
- [ ] **`<result_json>` block emitted as the LAST element of the final message** (Result Contract section above)
- [ ] Result report returned to caller (do NOT update tasks file directly — caller handles via CLI)
