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

### Container mode

When the tasks file has `metadata.execution` set to `"container"`, the story runs inside a git worktree at `.worktrees/<branchName>` instead of your current working tree. The container is created on first use and reused afterward. The story commits there, on the feature branch.

When `metadata.execution` is absent or `"inline"`, nothing changes from the original behavior: no container, no isolation, the story runs directly against your working tree.

Pass `--container` or `--inline` to override for one run. They are mutually exclusive. If the override changes the mode, it is written back to `metadata.execution`, so the next plain `/aimi:next` continues the same way.

`metadata.execution` applies only to flat tasks files. On a phase-scoped file — one with `metadata.phase` — `/aimi:next` refuses to run and points you at `/aimi:execute`, because it has no phase-claim logic and cannot resolve a phase's container base.

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

### Container mode

With `metadata.execution: "container"`, the whole run happens inside a git worktree at `.worktrees/<branchName>` rather than on your current checkout.

1. Creates or reuses the container. **Your main working tree is never checked out during the run.** The one exception is `.gitignore`: on a project's first container run, a `.worktrees` entry is appended automatically when that file is untracked or already has uncommitted changes. When it is tracked and clean, the run warns and leaves it alone — add the entry and commit it yourself in that case.
2. Installs dependencies inside the container once, using whichever package manager the lockfile indicates (bun, pnpm, yarn, or npm).
3. Starts a dev server inside the container before the wave loop — but only when some story needs visual verification.
4. Runs the wave loop inside the container.
5. On completion, stops the dev server and removes the container while keeping the branch.

Pushing the branch to `origin` needs confirmation. An interactive session is asked; an unattended one pushes only when `--push` was passed. Because nothing is left checked out locally afterward, the final report suggests `/aimi:open-pr --branch <branchName>` and `/aimi:review <branchName>` rather than the usual `gh pr create`.

### Choosing the mode

`/aimi:plan` writes `metadata.execution: "container"` into every new flat tasks file, so new plans run in container mode by default. Files created before that change have no `execution` key and keep running inline exactly as before.

`--inline` opts a single run back into the inline flow; `--container` forces container mode. They are mutually exclusive, and a change is persisted back to `metadata.execution`.

On a phase-scoped tasks file the flags are ignored with a warning — a claimed phase always runs in its own phase container, and `metadata.execution` never applied there.

### What container mode does not handle

- Stacks without a `package.json` `dev` script get no managed dev server. Visual verification degrades to `skipped`; it is not treated as a failure.
- Ports hardcoded in application config — OAuth redirect URIs, CORS allowlists — are not remapped when the dev server binds to a different free port.
- A full-stack split run gets one dev server per sibling container with no proxy between them, so one container's visual check cannot reach the other's API.
- Uncommitted edits in your main working tree do not reach a container. `git worktree add` branches from committed history only, so commit first.

---

## `/aimi:review`

Multi-agent code review. Runs architecture, security, simplicity, performance, and agent-native reviewers in parallel, plus migration and language-specific reviewers when relevant. Synthesizes the findings and sorts them by severity.

```bash
/aimi:review            # current branch
/aimi:review 42         # pull request #42
/aimi:review feat/auth  # a specific branch
```

---

## `/aimi:open-pr`

Opens a pull request from the current task branch. Detects the parent branch, builds the title and body from the commits and the diff, and creates the PR.

```bash
/aimi:open-pr
/aimi:open-pr --branch feat/user-auth
```

---

## `/aimi:validate-bug`

Reproduces a bug report and confirms whether the described behavior is real, using the bug-reproduction-validator agent.

```bash
/aimi:validate-bug Login fails silently when the email has a plus sign
```

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

---

## `/aimi:learnings`

Triages the friction queue that the plugin's hooks collect while you work — repeated failures, workarounds, surprises — and drafts proposals for turning them into durable project conventions.

```bash
/aimi:learnings
```
