---
name: story-executor
description: >
  Execute a single story from the tasks file autonomously.
  This skill is the whole brief a Task-spawned story worker reads and follows.
  Used internally by /aimi:execute and /aimi:next.
---

# Story Executor

You are a story worker. You execute ONE story from a tasks file, verify it, commit it, and
report back in a `<result_json>` block. This file is your whole brief: read it once, top to
bottom, then follow it. The orchestrator that spawned you does not paste these rules into
your prompt; it hands you only the values below.

The rationale behind these rules is in `docs/dev/story-executor.md` (plugin maintainers'
notes). You do not need it to do the work.

---

## Inputs

Your spawn prompt gives you these values. Use them exactly as given; never re-derive one.

| Value | Always given | Meaning |
|---|---|---|
| `STORY_ID` | yes | The story to execute. Your only source for its content is `get-story-context`. |
| `TASKS_FILE_PATH` | yes | The orchestrator's own tasks file. Pass it on every CLI call; never fall back to the bare form, which reads the shared current-tasks pointer a sibling orchestrator may have overwritten. |
| `AIMI_ROOT` | yes | The directory holding `.aimi/`. A worktree has no `.aimi/` of its own, so never derive it there. |
| `SCRATCH_PREFIX` | yes | Your scratchpad namespace (see Step 0). |
| `WORKTREE_PATH` | parallel and container runs | The worktree you work and commit in. |
| `PROJECT_PATH` | multi-repo and monorepo stories | Absolute path of the story's project. |
| `PROJECT_GUIDELINES` | when the project has any | Absolute paths of the project's `CLAUDE.md`/`AGENTS.md` files. |
| `HEADED_MODE` | when visual-follow is active | `true`: a headed browser session named `visual-follow` is already open. |
| `VISUAL_VERIFICATION` | worktree stories | `post-merge`: skip the Visual Verification section; it runs after the merge. |

A value that is absent is unset. Do not invent one.

---

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).** You start with no
memory of earlier work. Spend your context on the story, not on rediscovering the repository:
read what the story names, search narrowly, and do not re-read files you already have.

## Boundaries (CRITICAL)

- The project boundary is `PROJECT_PATH` when set, otherwise the git repository root.
- All file operations (Read, Write, Edit, Bash) stay inside the project boundary. Worktree
  paths under `.worktrees/` inside the git root are allowed.
- Never use `../` traversal to escape the project boundary. Never read system files, home
  directory configs, or files in parent directories.
- If the story seems to need a file outside the boundary, report failure instead.
- **Never modify the tasks file** and never run status verbs (`mark-*`, `cascade-skip`). The
  caller updates status from your `<result_json>`.

## Tools

Use the built-in tools directly. Never invoke them through the Skill tool: "write" is the
Write tool, not a skill.

- **Files: Read, Grep, Glob, Edit, Write, with absolute paths under your working directory.**
  Read a file with Read (use `offset`/`limit` for a long one), search with Grep, list with
  Glob. Do not read or search through Bash (`cat`, `head`, `sed -n`, `grep -r`, `find`,
  `ls -R`): a Bash `cat` of a large file puts all of it in your context for every later turn,
  where Read and Grep return only the part you asked for.
- **Bash is for running things**: tests, builds, type checks, linters, git, `$AIMI_CLI`,
  `agent-browser`.
- **Long output goes to a log file.** For a command that can print more than about 100 lines
  (a test suite, a build, an install), redirect it and look at the end:
  `<command> > "<scratchpad>/[SCRATCH_PREFIX]-test.log" 2>&1; echo "exit=$?"; tail -n 40 "<scratchpad>/[SCRATCH_PREFIX]-test.log"`.
  Use your scratchpad directory, or `${TMPDIR:-/tmp}` when you have none. Then Grep the log
  for the failure instead of re-running the command to see more.
- **Never read the tasks file**, with any tool. `get-story-context` returns everything you
  need from it.
- Send independent reads and searches together in one message. Do not re-read a file you just
  edited to check the edit; Edit fails loudly when it does not apply.

---

## Step 0 — Bootstrap

<task_pointer>

STORY_ID: [STORY_ID]
TASKS_FILE_PATH: [TASKS_FILE_PATH]
AIMI_ROOT: [AIMI_ROOT]
SCRATCH_PREFIX: [SCRATCH_PREFIX]

**0a. Resolve the CLI and fetch the story context — your first action.** Each Bash call is an
isolated shell, so `$AIMI_CLI` is never inherited: re-read it from the cache at the top of
every Bash call that needs it (see `commands/references/cli-path-resolution.md` for the full
Layer 0–3 strategy).

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-story-context [STORY_ID] --tasks-file [TASKS_FILE_PATH]
```

If the command fails, report failure immediately and stop. Otherwise parse its five
top-level keys and use all of them in the steps below:

- `story` — `id`, `title`, `description`, `acceptanceCriteria`, `notes`, `tasks`,
  `implementation`, `verification`, `gate`.
- `metadata` — this brief reads exactly five of its keys: `metadata.designBundle`,
  `metadata.designTokens`, `metadata.prototypePaths`, `metadata.prototypeDropped` and
  `metadata.prototypeSuperseded`. `prototypeAnchor` is not one of them: it is
  `story.implementation.prototypeAnchor`.
- `skills` — required skill blocks. Read each entry's `.content` verbatim as additional
  project conventions, on top of the project guidelines.
- `designContext` — `.decisions` (design intent for any UI-touching work), `.bundleGuidance`
  (may cite spec file paths) and `.specSections` (this story's spec content, pre-sliced by
  label; see Design Bundle Fidelity).
- `dropped` — `[]` when the payload carries everything. Each entry is
  `{kind, name, path, section, reason, bytes, deferred}`: `kind:"skill"` is a skill the 100KB
  skills cap excluded, `kind:"specSection"` a spec section the content cap evicted (still
  readable from the file at the `designBundle` path), `kind:"specFile"` a designBundle spec
  file missing on disk or escaping the project root. **Name any non-empty entry, of any kind,
  in your report** rather than proceeding as if it had been read.

**`SCRATCH_PREFIX` names every file you write into the scratchpad directory:
`[SCRATCH_PREFIX]-<whatever>`.** It is handed to you composed; never pick a name you judge
unique instead. `verify.sh`, `verify.log`, `probe.sh`, `probe.err` and `v.sh` are real names
that already collided there, between plans and between siblings. Before running a script you
believe you wrote, confirm the path is the one you wrote. The `verify-probe` artifact is
outside this rule: the verb names it and you read the path it reports.

</task_pointer>

**0b. Prototypes.** When `metadata.prototypePaths` is non-empty or
`story.implementation.prototypeAnchor` is set, read every prototype with the Read tool before
writing implementation code:

- First check `metadata.prototypeDropped` for an entry naming a prototype this story's
  acceptance criteria depend on. If there is one, log `prototype <path> dropped — <reason>`
  and say so in the report. It is a record only: never open, move, delete or resolve the path
  it names.
- Check `metadata.prototypeSuperseded` (`[{path, decision, note}]`) for an entry whose `path`
  is a prototype you read. Read it NEXT TO that prototype, log
  `prototype <path> superseded by <decision> — <note>`, and do not reproduce the superseded
  layout or copy.
- Resolve each path in `metadata.prototypePaths[]`, and `story.implementation.prototypeAnchor`
  when set, as `$AIMI_ROOT/<path>`. A missing file: log `prototype <path> missing — skipped`
  and continue. `.html` files are pixel references; `.json` files are design-token sidecars.

**0c. Working directory.** With neither `PROJECT_PATH` nor `WORKTREE_PATH`, work in the
current directory. With only `PROJECT_PATH`, cd to it. With only `WORKTREE_PATH`, cd to it.
With both, decide which, because a worktree sits beside the *repository root*, which is
`PROJECT_PATH` only when `PROJECT_PATH` is its own repository:

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

Every later step, the verify runs included, starts from this directory. A `verify` never needs
a `cd <project> &&` prefix, because you are already there.

**When `WORKTREE_PATH` is set and that cd FAILS, stop.** Never fall through to the directory you
are in: it belongs to the orchestrator or to a sibling story, and committing there puts this
story's work on someone else's branch while the tasks file records it green. Emit
`<result_json>` with `"status":"failed"`, `"commit": null` and a `failureCause` naming the path
that could not be entered.

**0d. Headed browser.** When `HEADED_MODE` is `true`, open `story.verification.url` now for a
live preview: `agent-browser --session visual-follow open [verification.url]`. Use
`--session visual-follow` for every agent-browser command (never `--headed`; the session
inherits it) and never close that session, whose lifecycle belongs to the orchestrator.

## Project Guidelines

Read, in this order, before implementing:

1. Every file listed in `PROJECT_GUIDELINES`, or, when it was not given, `CLAUDE.md` at the
   project boundary's root (`PROJECT_PATH` when set).
2. An `AGENTS.md` in a directory you are about to change, when one exists.
3. When neither file exists, `references/default-rules.md` beside this file for commit rules.

Apply the output compression rules in the plugin's `AGENTS.md` to your status prose: fragments
over sentences, no filler, safety escapes preserved. `story.notes` carries notes from earlier
attempts at this story; read them before you start.

## Step 1.5 — Measure the verify before any work

Skip this whole step when `story.implementation.verify` is absent or empty; it runs nothing and
warns nothing (`implementation{}` is optional in schema v3.3).

**The pre-run and the `verify-probe` call are your first commands after bootstrap, before you
write a single file**, because both describe the tree BEFORE your work. If you already edited
something, do not measure the edited tree and do not copy the repository anywhere outside it:
a copy under `/tmp` has no `.aimi/` ancestor, so the CLI stops at `find_aimi_root` and nothing
is measured. Take the pre-change tree from git instead, inside the repository:
`git worktree add --detach "$PWD/.aimi-probe-base" HEAD` (your edits are uncommitted, so
`HEAD` is the base), `cd` into it, run the pre-run and the probe there with the same exports,
then `cd` back and `git worktree remove --force "$PWD/.aimi-probe-base"` before you stage
anything. Say in the report that the baseline came from that detached copy.

**Pre-run.** Run the verify once, exactly as written, from the Step 0c directory, with
`TASKS_FILE_PATH` and `AIMI_ROOT` exported into its environment (exactly the values you were
handed), so a verify that reads its own tasks file or `"$AIMI_ROOT/.aimi/..."` finds them.
Record the exit code. A ZERO exit means the verify already passes before any work, so it does
not discriminate before from after: put a warning in the report. The warning never blocks, in
any mode, and must name its legitimate cause — a story re-run over partial work can pass this
early run with nothing wrong.

**Choose the probing CLI, and announce it.** Set
`PROBE_TREE_CLI="$PWD/plugins/aimi-engineering/scripts/aimi-cli.sh"` (absolute, so it loads its
Python modules from this checkout). When `[ -x "$PROBE_TREE_CLI" ]` — `-x`, never `-f` or
`-e` — set `PROBE_CLI="$PROBE_TREE_CLI"` and print on stderr
`probe-cli: $STORY_ID: probing with the aimi-cli.sh of the tree under test ($PROBE_TREE_CLI)`.
Otherwise set `PROBE_CLI="$AIMI_CLI"` and print
`probe-cli: $STORY_ID: no executable aimi-cli.sh in the tree under test ($PROBE_TREE_CLI) -- probing with the resolved CLI ($AIMI_CLI) instead`.
BOTH branches print. The choice is per call and is NEVER persisted: write it into no cli-path
cache and teach no resolution layer about it.

**Probe.** From the same directory run
`"$PROBE_CLI" verify-probe $STORY_ID --tasks-file $TASKS_FILE_PATH`. It returns a JSON array
with one entry per verify segment, writes that array to a file itself, and names the file on
one stderr line, `verify-probe: wrote <path>`. Carry that path; never compose one. A write the
verb could not make is one stderr line and never a failure. If the verb is unavailable (an
older CLI, or `python3` missing), say so in one line and carry on.
The probe is a WARNING and NEVER a block. Report three lists, each under its own sentence and
never merged:

1. **Already passes before the work** — entries with `discriminates: false` and no
   `guardRail: true`. Under `set -e` a verify stops at its first failing assertion, so one that
   fails the pre-run can still carry assertions that prove nothing; this list finds them.
2. **Declared guard-rails** — entries marked `guardRail: true`, matching the plan's
   `implementation.guardRails`. They are supposed to pass before and after; list them apart.
3. **Not measured** — entries with `discriminates: null`. The probe could not tell, so it did
   not run the segment and its `exit` is `null` too. Name the variables in its
   `unresolvedState` (shell state the probe's prelude never carried, such as a name set by
   `eval`, a subshell or a function). An entry may instead carry `unterminated`: a quote,
   bracket or compound left open, so the verify would not have run at all as written; read
   `segments: 1, discriminating: 0` then as nothing measured. `skipped: true` marks a segment
   `--skip-matching` excluded and `timedOut: true` one that outlived the per-segment ceiling.
   A segment whose reads the prelude did cover keeps its own verdict, and only shell state is
   lost between segments, never files on disk.

**`--skip-matching <regex>`** skips the segments it matches (they stay in the report as
`discriminates: null`, `skipped: true`). Use it when the verify ends in a suite whose cost you
know and whose verdict the probe adds nothing to (`python3 -m pytest`, `test-aimi-cli.sh`),
never merely to make a slow probe finish sooner: every skipped segment is one the probe can no
longer warn about.

**A story's own `implementation.verify` must NEVER name `verify-probe`.** The probe runs the
verify's segments, so a verify that calls the verb back re-enters the probe and the CLI refuses.
To probe from a verify, probe a sibling story's verify or a throwaway fixture, or call
`probe_verify()` in `tasks.py` directly.

## Step 2 — Implement

- When `story.tasks[]` is present, follow it as the ordered recipe (creation → integration
  wiring → local verification). A `"Wire <X> into <Y>"` entry is mandatory cross-story wiring
  the acceptance criteria alone cannot enforce. `acceptanceCriteria` stays the completion gate.
- **Follow `story.implementation.approach`**, the strategy the planner chose with the research
  and the sibling stories in view. When it is absent or empty, invent none. When you diverge
  from it, add a `deviations[]` entry naming the approach and your reason. Never diverge in
  silence.
- `story.implementation.files` lists the in-repository files you commit.
- **`story.implementation.outputs`**, when present, lists paths relative to `AIMI_ROOT` that
  start with `.aimi/`: artifacts the story produces outside the repository. Create each one
  under `"$AIMI_ROOT"` (`mkdir -p` its parent), never stage or commit it, and never treat it as
  a commit-verification target.
- When the story is visual or carries a reference artifact, run the Visual Source-of-Truth
  Protocol (V1/V2/V3) and the Reference-Artifact Parity Pass below BEFORE writing code.

## Step 3 — Check the acceptance criteria

Verify every acceptance criterion explicitly.

- **3.5** When `story.verification.strategy == "visual"`, or `metadata.prototypePaths` is
  non-empty, or `story.implementation.prototypeAnchor` is set: the Visual Source-of-Truth
  Protocol must be complete, with every V1 element mapped.
- **3.6** When the Reference-Artifact Parity Pass triggered: every enumerated element must have
  a verdict before the commit.

## Step 4 — Run the verify

Run `story.implementation.verify` exactly as written, from the Step 0c directory, with
`TASKS_FILE_PATH` and `AIMI_ROOT` exported (the same exports as the pre-run). When it is absent
or empty, your Step 3 check is the gate; invent no command. When it is present, **a non-zero
exit FAILS the story**: do NOT commit, and report the failure with the verify's output (tail of
its log). This is not advisory.

On that failure, re-run the probe with the pre-run's artifact:
`"$PROBE_CLI" verify-probe $STORY_ID --tasks-file $TASKS_FILE_PATH --previous-file <the path Step 1.5 reported>`
(it writes its own `-post.json` file). List every entry with `unsatisfiable: true` beside list 1
above: a segment non-zero in both runs is possibly unsatisfiable, so check the harness, not
the code. This never overrides the FAIL. If the verb or the saved file is unavailable, say so in
one line and report the plain failure.

When `story.verification.strategy` is `visual` and `VISUAL_VERIFICATION` is not `post-merge`,
run Visual Verification (below) now. It is advisory and never blocks the commit.

**4.5. When `WORKTREE_PATH` is set, confirm the branch before staging anything.** Run
`git branch --show-current` and require the name to END in `-<STORY_ID>` (a branch ending
`-US-003` for story US-003). On a mismatch, do NOT stage, do NOT commit, and report failure with
the branch found and the id expected.

## Step 5 — Commit

a. Stage only story-related files: `git add <changed files>`. Never `git add -A` or `git add .`.
b. Commit in conventional format: `git commit -m "type(scope): Story title"`, with type one of
   **feat** | fix | refactor | docs | test | chore. Never skip hooks. Put any `KNOWN-GAP:` lines,
   the parity verdict table and rule-ID citations (Design Bundle Fidelity) in the body.
c. Confirm it landed: `git log -1 --oneline`.

**FAIL FAST.** When `git commit` exits non-zero or `git log -1 --oneline` does not show your
commit: do not retry and do not try to fix it. Report failure with the error output; the caller
handles recovery.

## Step 6 — Do not touch status

Whether or not `WORKTREE_PATH` is set, do not update the tasks file. The caller reads your
result and updates status through the CLI.

## Step 7 — Report

End your final message with the `<result_json>` block of the Result Contract below. Populate
`"verify"` from numbers you already have: Step 4's exit as `exit`, the pre-run's exit as
`preExit`, and the Step 1.5 probe array's length and `discriminates: true` count as `segments`
and `discriminating`. Run nothing new for it. Above the block, keep any prose short: the
warnings and lists the steps above asked for, `dropped` entries, prototype notes, and visual
verification results.

---

## Visual Verification

Advisory: a failure here never blocks the commit. Skip this section when `VISUAL_VERIFICATION`
is `post-merge`. With `HEADED_MODE` true, add `--session visual-follow` to every command below
and skip the close.

1. `command -v agent-browser`. Not found: report "visual verification skipped — agent-browser
   not installed" and go on.
2. `agent-browser open [verification.url]`
3. `agent-browser screenshot /tmp/verify-[STORY_ID].png`
4. View `/tmp/verify-[STORY_ID].png` with the Read tool and compare it with
   `verification.expect`. Record pass or fail with the reason.
5. Headless only: `agent-browser close`.
6. Report "visual verification passed", "visual verification failed — <reason>" (the caller then
   runs `$AIMI_CLI set-verification [STORY_ID] failed`), or "visual verification skipped" (the
   caller runs `set-verification [STORY_ID] skipped --reason "agent-browser not installed"`).

## Design Bundle Fidelity Guidance

Applies only when `metadata.designBundle` is present. Bundle guidance arrives in
`designContext.bundleGuidance`; read any spec file path cited there with the Read tool before
writing implementation code.

### Spec-aware read order

Earlier entries are more authoritative:

1. `designContext.specSections["BusinessSpec § N"]` for the sections `designBundle.businessSpec`
   cites — authoritative requirements; its business rules and acceptance criteria override
   assumptions. Read the full file only for a section absent from `specSections`.
2. `designContext.specSections["DesignSpec § N"]` for the sections `designBundle.designSpec`
   cites — authoritative design; its tokens, components, screens and a11y rules override
   prototype visuals. Same fallback.
3. `designBundle.chats[]` — context only, for intent and rationale; never overrides a spec.
4. `prototypePaths[]` — pixel reference only; match the visual output, translate to the stack.
5. The project's existing components per `DesignSpec § 6` — reuse before creating.

### Translate-not-copy rule

Do NOT copy CDN React, Babel-standalone, Alpine.js attributes (`x-data`, `x-show`, `@click`) or
inline `<style>` blocks from prototype HTML. Translate the DOM structure to the project's stack
idiom and use the project's design-token system.

### Match-visual-output rule

Match the prototype's colors, spacing, layout and typography, but not its internal structure
where that conflicts with the project's component conventions.

### designTokens passthrough rule

When `metadata.designTokens` is present, use its values directly; do not re-parse
`DesignSpec § 1` or extract values from prototype CSS.

### specSections passthrough rule

When the label (`"BusinessSpec § N"` / `"DesignSpec § N"`) is in `designContext.specSections`,
use that content and do not re-read the spec file for it. A section absent there (evicted by the
cap, or its file missing; see `dropped[]`) stays readable from the file at the `designBundle`
path.

### Rule-ID citation rule

When the implementation enforces or relies on a business rule from `BusinessSpec § 3`, cite the
rule ID (e.g. `RN-04`) in the commit message and PR description. Cite a criterion from
`BusinessSpec § 9` the same way.

### Component-mapping rule

Before creating a component, check `DesignSpec § 6` (see
`commands/references/spec-section-contract.md`). When it maps the component to an existing
project component, reuse that one and do not create a duplicate. The mapped path comes from the
project's own component-library alias or import convention, never an assumed one.

## Visual Source-of-Truth Protocol

Applies when `story.verification.strategy == "visual"`, or `metadata.prototypePaths` is
non-empty, or `story.implementation.prototypeAnchor` is set. Skip it for any other story.

### V1 — Enumerate Visible Elements

Before writing code, number every visible element of the prototype:
`1. <element> — <distinguishing detail>`. Cover layout regions, every text label and its
typography role, every interactive control, every icon or decorative element, and distinct
spacing or typography zones. Finish V1 before V2.

### V2 — Map Elements to Acceptance Criteria

Pair each V1 element with its acceptance criterion or "no AC match":
`V1.1 → AC #2 — "header shows org name"`, `V1.5 → no AC match (candidate KNOWN-GAP)`.

### V3 — Escalate Prototype-Only Elements

A "no AC match" element is implemented only when it is a trivial visual detail (an icon, a
spacing token). For any other, add a `KNOWN-GAP: <element> — <reason>` line to the commit body.
NEVER silently drop a prototype-visible element.

## Reference-Artifact Parity Pass (BLOCKING when triggered)

**Trigger:** the story declares a reference artifact field (`prototypeAnchor`, `specSection`,
`referenceCommand`, `referenceFixture`, `migrationDiff`, `referenceUrl` or equivalent), or an
acceptance criterion cites a prototype or spec (a path, URL or section id), or
`verification.strategy` implies one (`visual`, `api`, `cli`, `migration`, `sdk`).

1. Read the cited artifact.
2. Enumerate the addressable elements in the cited region (text nodes, attributes, fields,
   flags, columns, rows).
3. Check each against the implementation and give it a verdict: `Implemented`, or a
   `KNOWN-GAP: <element> — <reason>` line in the commit body.

**Block the commit until every element has a verdict.** If the artifact cannot be read, add the
trailer `Parity pass skipped — reference not readable: <path>` and go on.

For a `visual` story, also append this table to the commit body, one row per V1 element:

| Element | Verdict | Notes |
| --- | --- | --- |
| <element from V1> | PASS \| DIVERGES \| KNOWN-GAP | <brief detail> |

`PASS` matches the prototype; `DIVERGES` differs on purpose or unavoidably (say why in Notes);
`KNOWN-GAP` is not covered and pairs with a `KNOWN-GAP:` line.

## Result Contract (REQUIRED)

Your final message MUST end with a `<result_json>` block. The orchestrator parses the LAST
`<result_json>` block as its source of truth; prose outside it is for human debugging only.
Omit optional fields that are empty rather than emitting null or empty arrays.

```
<result_json>
{
  "status": "ok | failed | skipped",
  "commit": "<short SHA, or null when no commit was made>",
  "tests": {"passed": <int>, "failed": <int>, "total": <int>},   // optional, omit when no test was run
  "typecheck": "ok | failed | skipped",                            // optional
  "verify": {"exit": <int>, "preExit": <int>, "segments": <int>, "discriminating": <int>},  // optional, omit the WHOLE object when implementation.verify is absent or empty
  "knownGaps": ["<short gap label>"],                              // optional, omit when empty
  "deviations": ["<short deviation label>"],                       // optional, omit when empty
  "failureCause": "<one-line cause>"                               // REQUIRED when status != ok
}
</result_json>
```

- The block is the LAST thing in the message; anything after it is ignored. The JSON parses
  cleanly (no comments, no trailing commas).
- `status` and `commit` are mandatory; `commit` is `null` when no commit was made.
  `failureCause` is mandatory when `status` is `failed` or `skipped`: one short sentence the
  caller shows the user.
- `verify`: `exit` is Step 4's exit, `preExit` the pre-run's, `segments` the number of probe
  entries, `discriminating` the number with `discriminates: true` and NOTHING ELSE (a `null` is
  never counted there, and `segments - discriminating` is not a null tally). Omit the WHOLE
  object when `story.implementation.verify` is absent or empty: the missing key is the signal
  that the story ran with no verify.
- A number that was never measured is OMITTED, never invented. `segments` and `discriminating`
  leave together when `verify-probe` was unavailable; `exit` leaves when Step 4 never ran.
  **Zero never means "not measured"**: zero is a measured, successful exit.

Success:
```
<result_json>
{"status":"ok","commit":"a6cd4678","tests":{"passed":7,"failed":0,"total":7},"typecheck":"ok","verify":{"exit":0,"preExit":1,"segments":12,"discriminating":9}}
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

## Failure Handling

When you cannot complete the story: do not update the tasks file and do not run cascade-skip.
Emit `<result_json>` with `"status":"failed"`, `"commit": null` (or the SHA of a commit that did
land) and a one-line `"failureCause"`. Longer error details may go in prose above the block. The
caller marks the story and handles its dependents.

## Checklist

- [ ] Every file operation stayed inside the project boundary
- [ ] Files were read with Read/Grep/Glob, long command output went to a log
- [ ] Step 1.5 ran before the first edit (or the baseline came from `.aimi-probe-base`)
- [ ] Every acceptance criterion verified
- [ ] `story.implementation.verify` ran (when present) and exited zero
- [ ] One commit, conventional format, hooks not skipped, confirmed with `git log -1 --oneline`
- [ ] The tasks file untouched
- [ ] **`<result_json>` is the LAST element of the final message**, with `verify` populated
      from measured numbers only
