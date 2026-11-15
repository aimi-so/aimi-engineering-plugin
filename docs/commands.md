# Commands

Every command in detail. For the one-line summary of each, see the table in the [README](../README.md#commands).

---

## `/aimi:brainstorm`

Explores what to build before deciding how. Runs codebase research, then asks batched multiple-choice questions until the shape of the feature is clear. Writes a design document to `.aimi/brainstorms/`.

```bash
/aimi:brainstorm Add social login with Google and GitHub
/aimi:brainstorm Add social login --non-interactive
```

`--non-interactive` skips every prompt and auto-defers open questions. Use it in CI or when another agent is driving.

---

## `/aimi:plan`

Turns a feature description into `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json`.

The pipeline runs brainstorm detection, parallel research, optional external research, spec-flow analysis, and story decomposition. Stories come out as vertical slices — each one delivers something a user can see, cutting through every layer it needs, rather than being split by layer.

```bash
/aimi:plan Add user registration flow
/aimi:plan Add user registration flow --non-interactive
```

Interactive by default. `--non-interactive` auto-defers every open question.

---

## `/aimi:deepen`

Enriches an existing plan with research insights. Completion state of finished stories is preserved.

```bash
/aimi:deepen .aimi/tasks/2026-02-16-user-auth-tasks.json
```

---

## `/aimi:status`

Shows progress. Uses `jq` so it costs almost no context.

```
Aimi Status: user-auth (feature/user-auth)

Stories: 3/7 complete

✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
✗ US-003: Add login UI                 (skipped: auth middleware issue)
→ US-004: Add registration UI          (next)
○ US-005: Add session middleware       (pending)
○ US-006: Add logout endpoint          (pending)
○ US-007: Add dashboard                (pending)

Next: US-004 - Add registration UI
```

---

## `/aimi:next`

Runs the next pending story, one at a time. Extracts only that story so the context stays clean.

- Validates required fields before starting
- Retries once automatically on failure
- Asks whether to skip, retry, or stop when a story keeps failing

### Container mode (single story)

When the tasks file has `metadata.execution` set to `"container"`, the story runs inside a git worktree at `.worktrees/<branchName>` instead of your current working tree. The container is created on first use and reused afterward. The story commits there, on the feature branch.

When `metadata.execution` is absent or `"inline"`, nothing changes from the original behavior: no container, no isolation, the story runs directly against your working tree.

Pass `--container` or `--inline` to override for one run. They are mutually exclusive. If the override changes the mode, it is written back to `metadata.execution`, so the next plain `/aimi:next` continues the same way.

`metadata.execution` applies only to flat tasks files. On a phase-scoped file — one with `metadata.phase` — `/aimi:next` refuses to run and points you at `/aimi:execute`, because it has no phase-claim logic and cannot resolve a phase's container base.

Pass `--base <branch>` to name the container's base outright instead of being asked or having it inferred from your current checkout.

---

## `/aimi:execute`

Runs every pending story autonomously. Reads the schema version, the shape of the dependency graph, and `metadata.execution` to pick a strategy.

### When stories can run in parallel

1. Validates the branch name and the dependency graph
2. Creates or checks out the feature branch
3. Builds execution waves from the dependency graph
4. Runs each wave — independent stories in parallel, each in its own worktree
5. Merges each wave's results before starting the next
6. Cascade-skips anything that depended on a story that failed
7. Reports wave progress and commit count

### When dependencies are linear

Falls back to running stories one after another through `/aimi:next`, handling skip/retry/stop decisions along the way.

### Container mode (full run)

With `metadata.execution: "container"`, the whole run happens inside a git worktree at `.worktrees/<branchName>` rather than on your current checkout.

1. Creates or reuses the container. **Your main working tree is never checked out during the run.** The one exception is `.gitignore`: on a project's first container run, a `.worktrees` entry is appended automatically when that file is untracked or already has uncommitted changes. When it is tracked and clean, the run warns and leaves it alone — add the entry and commit it yourself in that case.
2. Installs dependencies inside the container once, using whichever package manager the lockfile indicates (bun, pnpm, yarn, or npm).
3. Starts a dev server inside the container before the wave loop — but only when some story needs visual verification.
4. Runs the wave loop inside the container.
5. On completion, stops the dev server and removes the container while keeping the branch.

Publishing is a decision of its own, asked on every `/aimi:execute` path and not only this one. Before the branch reaches `origin`, and before any pull request is opened, you are asked once: a container run offers push or skip, a phase run offers push and open the pull request, push only, or neither. Anything that is not an explicit approval — a dismissed prompt, an unreadable answer, no answer at all — publishes nothing. An unattended run (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`) never publishes, and there is no flag that re-enables it. Declining is a normal outcome, not a failure: nothing is retried, and no story or phase status is rolled back. A multi-repo phase is asked once for the whole phase, not once per repository.

Every ending names `/aimi:open-pr`, whether the run published or not — `/aimi:open-pr --branch <branchName>` when the container has been removed and the branch is checked out nowhere, and the bare `/aimi:open-pr` after an inline run, where the branch is still under your feet and the command's own uncommitted-changes check still applies. It is safe to suggest in every case because it pushes the named branch itself before opening anything. `/aimi:review <branchName>` sits alongside it as before. `/aimi:next` publishes nothing at all: when its last story completes it removes the container, keeps the branch, and points you at the same command.

**Only publication moved behind that question.** Everything that delivers the work is untouched: each story worktree is still merged into the feature branch locally — a `git merge`, never a push — and the commits, the branch ref, the container teardown that keeps the branch (`--keep-branch`), and story and phase status all behave exactly as before. A run you decline to publish has lost nothing; the branch is complete on your machine, waiting for `/aimi:open-pr`.

### Usage validation

When a run delivers something a person or an agent can use, `/aimi:execute` uses it before calling the work done: after the Phase Visual Gate in phase mode, and after Finalize in a flat run, a validator agent walks each acceptance criterion through the running product and saves proof for what it finds. It brings the product up from the **usage recipe** you confirmed once during `/aimi:plan` (recorded per project with `usage-recipe-record`); a surface with no recipe is skipped as `unable-to-evaluate`, never passed.

- A major or catastrophic finding that stays open leaves the phase `verification_failed`, or records a flat run as failing, and the push and pull request are not offered until it is resolved. Clear bugs are fixed and re-checked for up to two rounds; anything that needs a decision is asked of you, and an unattended run never accepts one.
- **Re-validation on a re-run:** the re-validation is automatic: running `/aimi:execute` again on a failing phase or flat run validates again, and findings you already accepted are not asked twice.
- **Off switch:** set `AIMI_USAGE_VALIDATION=off` to skip the gate; it records `disabled-by-operator` with a reason rather than a pass.

### Choosing the mode

`/aimi:plan` writes `metadata.execution: "container"` into every new flat tasks file, so new plans run in container mode by default. Files created before that change have no `execution` key and keep running inline exactly as before.

`--inline` opts a single run back into the inline flow; `--container` forces container mode. They are mutually exclusive, and a change is persisted back to `metadata.execution`.

On a phase-scoped tasks file the flags are ignored with a warning — a claimed phase always runs in its own phase container, and `metadata.execution` never applied there.

Pass `--base <branch>` to cut every container from this branch outright, instead of asking or inferring it from your current checkout — including every repository in a multi-repo or full-stack split run.

### What container mode does not handle

- Stacks without a `package.json` `dev` script get no managed dev server. Visual verification degrades to `skipped`; it is not treated as a failure.
- Ports hardcoded in application config — OAuth redirect URIs, CORS allowlists — are not remapped when the dev server binds to a different free port.
- A full-stack split run gets one dev server per sibling container with no proxy between them, so one container's visual check cannot reach the other's API.
- Uncommitted edits in your main working tree do not reach a container. `git worktree add` branches from committed history only, so commit first.

---

## `/aimi:review`

Multi-agent code review. Reads what you ask for in plain words, a pull request or branch plus a focus ("bugs and security") and a scope ("only the diff"), and runs the reviewers that fit: correctness, security, performance and maintainability by default, plus project-standards, frontend, agent-native, data-migration and deployment reviewers when the change touches their subject. The report says why each reviewer ran or did not. It checks each serious finding, and the premise it rests on, against the code before reporting it, and sorts the findings by severity. A changed file of 100 lines or more that no reviewer read gets a second correctness pass, and whatever stays unread is named in the report. Several pull request URLs, one per repository of a multi-repo layout, are each reviewed in the local folder whose `origin` points at that repository.

```bash
/aimi:review                                       # current branch
/aimi:review 42                                    # pull request #42
/aimi:review feat/auth                             # a specific branch
/aimi:review 42 focus on bugs, only the diff       # a focus and a scope, in plain words
/aimi:review <api PR URL> <web PR URL>             # one PR per repository of a multi-repo layout
```

Detects which forge your remote points at rather than assuming GitHub — GitHub and GitLab are the only adapters today; any other host gets manual steps.

---

## `/aimi:open-pr`

Opens a pull request from the current task branch. Detects the parent branch, builds the title and body from the commits and the diff, and creates the PR.

```bash
/aimi:open-pr
/aimi:open-pr --branch feat/user-auth
```

Detects which forge your remote points at rather than assuming GitHub — GitHub and GitLab are the only adapters today; any other host gets manual steps.

---

## `/aimi:validate-bug`

Reproduces a bug report and confirms whether the described behavior is real, using the bug-reproduction-validator agent.

```bash
/aimi:validate-bug Login fails silently when the email has a plus sign
```

When given an issue or PR reference, detects which forge your remote points at rather than assuming GitHub — GitHub and GitLab are the only adapters today; any other host gets manual steps.

---

## `/aimi:init`

Primes the global CLI path cache so later `/aimi:*` commands skip a slow filesystem glob. Run it once after installing; run it again if commands start resolving slowly.

```bash
/aimi:init
```

---

## `/aimi:setup-models`

Configures which Claude model handles each agent category, interactively.

Shows the current values for the active host, then asks five questions — research, review, design, workflow, executor — with the current values pre-selected. Writes `~/.config/aimi/models.json` and preserves the other host's settings.

```bash
/aimi:setup-models
```

Use it to change assignments after first run, or to rebuild the config if the file was deleted.

### Effort

After the five model questions the command asks one gate question, `Adjust effort as well?`. Answer yes and it asks five effort questions, one per category, with the current values pre-selected. Answer no and the stored efforts stay as they are.

What an effort is depends on the host:

- **Claude Code**: a reasoning level, one of `low`, `medium`, `high`, `xhigh` or `max`, passed as the `effort` parameter on each spawn of an agent in that category. Requires Claude Code 2.1.292 or newer, the first version with a per-spawn effort parameter.
- **OpenCode**: a variant of the category's model, forwarded by the `aimi-task` tool as `opencode run --variant <name>`. Only the variants the chosen model defines are offered, read from `opencode models --verbose`. A category whose model is `inherit` has no variant to pick, so its effort is `inherit` too, and changing a category's model drops a stored variant the new model does not define.

Unset means `inherit`: the spawn carries no effort and behaves as before. A `models.json` written before this setting existed changes nothing, and every category starts at `inherit`.

Setting `max` on review or research multiplies cost, because those categories fan out to many agents at once and each one reasons at that level.

If the environment variable `CLAUDE_CODE_EFFORT_LEVEL` is set, Claude Code applies it to every spawn and it overrides every per-category effort; the command prints a line saying so when it is set. Run `aimi-cli resolve-efforts` to see what each category resolves to right now.
