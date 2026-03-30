---
name: aimi:swarm
description: "Execute multiple tasks.json files in parallel using Team orchestration, git worktrees, and simplified Docker containers"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Bash(docker:*), Bash(git:*), Bash(id:*), Bash(jq:*), Bash(ls:*), Bash(test:*), Bash(echo:*), Bash(timeout:*), Task, TeamCreate, TeamDelete, SendMessage, Glob, AskUserQuestion
---

# Aimi Swarm

Execute multiple tasks.json files in parallel. Each task file gets its own git worktree and Team worker that runs Claude Code inside a Docker container (`docker run --rm`). No Sysbox, no ACP protocol, no persistent containers.

```
User runs /aimi:swarm
         |
         v
    Team Lead (this agent, runs on host)
         |  TeamCreate + worktree per task file
         |
    Worker 1    Worker 2    Worker 3
         |          |          |
    docker run  docker run  docker run
    --rm -v     --rm -v     --rm -v
    (volume-mounts worktree)
```

## Step 0: Resolve Tool Paths

### AIMI CLI

Resolve `$AIMI_CLI` path using the three-layer strategy below. Each command is a separate Bash call (no compound operators).

**Layer 1 — Global cache (fast path):**
```bash
AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null)
```

**Layer 1 validation:**
```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2 — Glob fallback (zsh-safe, only if Layer 1 failed):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

**Layer 2 cache update:**
```bash
if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"; fi
```

**Layer 3 — Per-project fallback (last resort):**
```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

**Version check:**
```bash
$AIMI_CLI check-version --quiet --fix
```

### Worktree Manager

```bash
WORKTREE_MGR=$(ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | tail -1)
```

If empty, report: "worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

**Use `$AIMI_CLI` and `$WORKTREE_MGR` for ALL subsequent script calls.**

## Step 1: Handle Subcommands

Check if `$ARGUMENTS` contains a subcommand:

### `status`

If arguments start with `status`:

1. Read all task files from `.aimi/tasks/*-tasks.json`
2. For each file, report story progress using `jq`:
   ```bash
   jq -r '.metadata | "\(.branchName) — \(.title)"' <file>
   jq '[.userStories[] | select(.status == "completed")] | length' <file>
   jq '.userStories | length' <file>
   ```
3. Check for any active aimi-* worktrees:
   ```bash
   git worktree list --porcelain | grep -c "aimi-"
   ```
4. Report:
   ```
   ## Swarm Status

   | # | Task File | Branch | Progress |
   |---|-----------|--------|----------|
   | 1 | .aimi/tasks/auth-tasks.json | feat/auth | 5/5 |
   | 2 | .aimi/tasks/ui-tasks.json | feat/ui | 2/3 |

   Active worktrees: 0
   ```
5. STOP.

### `cleanup`

If arguments start with `cleanup`:

1. Remove all aimi-* worktrees:
   ```bash
   $WORKTREE_MGR list
   ```
   For each worktree matching `aimi-*`:
   ```bash
   $WORKTREE_MGR remove <worktree_name>
   ```

2. Remove any leftover Docker containers:
   ```bash
   docker container ls -a --filter "name=aimi-swarm-" --format '{{.Names}}' | while read name; do
     docker rm -f "$name" 2>/dev/null
   done
   ```

3. Prune stopped containers (safety net):
   ```bash
   docker container prune -f --filter "label=aimi-swarm" 2>/dev/null
   ```

4. Report:
   ```
   ## Swarm Cleanup Complete

   Worktrees removed: [N]
   Docker containers removed: [N]
   ```
5. STOP.

### Default (no subcommand)

Proceed to Step 2.

## Step 2: Discover Task Files

### Single file mode (`--file` flag)
If `$ARGUMENTS` contains `--file <path>`:
- Validate the file exists and ends with `.json`
- Use that single file as the selection
- Skip to Step 3

### Multi-file flags

1. **`--all` flag**: Select all discovered files automatically.
2. **`--files <path1>,<path2>`**: Select specified files (comma-separated).
3. **No flag**: Fall through to interactive selection.

### Discovery

```bash
ls -t .aimi/tasks/*-tasks.json 2>/dev/null
```

If no files found:
```
No task files found in .aimi/tasks/. Run /aimi:plan to create a task list first.
```
STOP.

For each file, extract metadata:
```bash
jq -r '.metadata | "\(.branchName) — \(.title)"' <file>
jq '[.userStories[] | select(.status == "pending")] | length' <file>
```

### Interactive selection (default)

Present files to user:
```
Found [N] task file(s):

  1. .aimi/tasks/2026-03-01-feature-auth-tasks.json (feat/auth, 5 stories)
  2. .aimi/tasks/2026-03-01-feature-ui-tasks.json (feat/ui, 3 stories)

Select files to execute (comma-separated numbers, or "all"):
```

Use `AskUserQuestion` to get the selection. Store as `SELECTED_TASK_FILES`.

## Step 3: Docker Availability Check

```bash
docker version --format '{{.Server.Version}}' 2>/dev/null
```

If Docker is not available (non-zero exit), report:
```
Docker is not available.

The swarm command requires Docker to isolate each task file in its own container.
Install Docker: https://docs.docker.com/get-docker/

Alternative: Use /aimi:execute to run a single task file without Docker.
```
STOP.

## Step 4: Detect Credentials

**CRITICAL:** Detect credentials BEFORE provisioning any containers. Fail fast if no authentication method exists.

### ANTHROPIC_API_KEY

```bash
echo "${ANTHROPIC_API_KEY:0:8}..." 2>/dev/null
```

If not set, STOP:
```
ANTHROPIC_API_KEY not set. Docker containers need this to run Claude Code.

Export it: export ANTHROPIC_API_KEY=sk-ant-...
```

### GITHUB_TOKEN (optional)

```bash
echo "${GITHUB_TOKEN:0:8}..." 2>/dev/null
```

If not set, try `gh auth token`:
```bash
DETECTED_GH_TOKEN=$(timeout 5 gh auth token 2>/dev/null)
```

If found, export it:
```bash
export GITHUB_TOKEN="$DETECTED_GH_TOKEN"
```

### SSH_AUTH_SOCK (optional)

```bash
test -S "${SSH_AUTH_SOCK:-}" 2>/dev/null && echo "SSH agent available"
```

### Credential summary

```
Credentials:
  ANTHROPIC_API_KEY : found (sk-ant-a...)
  GITHUB_TOKEN      : found (ghp_Ax7f...) | not set
  SSH_AUTH_SOCK     : available | not available
```

## Step 5: Create Team and Spawn Workers

### Read Docker image preference

For each task file, check metadata for a custom image:
```bash
jq -r '.metadata.dockerImage // "node:22-slim"' <file>
```

Default: `node:22-slim`.

### Create team

```
TeamCreate({ team_name: "aimi-swarm" })
```

### For each task file in SELECTED_TASK_FILES

1. **Read the task file content** — the team lead reads the full file and extracts all story data. Workers receive story details in their prompt (the task file may be gitignored from the worktree).

2. **Extract metadata**:
   ```bash
   jq -r '.metadata.branchName' <file>
   ```
   Store as `BRANCH`.

3. **Derive worker name** from the task file:
   - Extract slug from filename (e.g., `2026-03-01-feature-auth-tasks.json` -> `feature-auth`)
   - Worker name: `worker-<slug>`

4. **Create worktree**:
   ```bash
   $WORKTREE_MGR create aimi-<slug> --from <BRANCH>
   ```
   Parse the worktree path from output. Store as `WORKTREE_PATH`.

5. **Build the Docker command** that will run inside the worker Task:

   ```bash
   CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
   docker run --rm \
     --label aimi-swarm \
     --name aimi-swarm-<slug> \
     --user $(id -u):$(id -g) \
     -v <WORKTREE_PATH>:/workspace \
     -v $CLAUDE_DIR:/home/user/.claude:ro \
     -e ANTHROPIC_API_KEY \
     -e GITHUB_TOKEN \
     -w /workspace \
     <DOCKER_IMAGE> \
     npx claude --dangerously-skip-permissions \
       -p "<WORKER_PROMPT>"
   ```

   If `SSH_AUTH_SOCK` is available, add:
   ```
   -v ${SSH_AUTH_SOCK}:/tmp/ssh-agent.sock -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
   ```

6. **Build the worker prompt** (passed to Claude Code inside the container):

   ```
   You are executing stories from a task file inside a Docker container.

   ## PROJECT GUIDELINES

   Read /workspace/CLAUDE.md for project conventions before starting.

   ## Task File Content

   [Inline the full JSON content of the task file here]

   ## Execution Instructions

   Execute ALL pending stories sequentially, in order of their ID.
   For each story:
   1. Read the story's description and acceptance criteria
   2. Implement the requirements
   3. Verify acceptance criteria are met
   4. Run typecheck if applicable (npx tsc --noEmit)
   5. Commit with: "feat(<scope>): <Story title>"

   Skip stories with status "completed", "failed", or "skipped".
   If a story fails, note the error and continue with the next story.

   After all stories are done, report a summary:
   - Which stories completed successfully
   - Which stories failed (with error details)
   - Total commits made
   ```

7. **Spawn a Team worker** that runs the Docker command:

   In a SINGLE tool-call turn, emit ALL Task calls for all task files:

   ```
   Task(
     team_name: "aimi-swarm",
     name: "worker-<slug>",
     subagent_type: "general-purpose",
     description: "Swarm worker: <slug> executing <taskFile>",
     prompt: """
   You are a swarm worker managing a Docker container for task execution.

   ## Your Job

   Run this Docker command and monitor it to completion:

   ```bash
   <DOCKER_COMMAND>
   ```

   ## Instructions

   1. Run the docker command above using Bash
   2. Wait for it to complete (docker run --rm is foreground, blocks until done)
   3. When it exits:
      - Exit code 0: report SUCCESS
      - Exit code non-zero: capture last 30 lines of output, report FAILURE

   4. Report your result:

   SWARM_WORKER_RESULT:
   taskFile: <taskFile>
   branch: <BRANCH>
   worktree: aimi-<slug>
   status: [completed|failed]
   exitCode: [code]
   summary: [last few lines of output or success message]

   Do NOT modify any files outside the Docker command. Just run it and report.
   """,
     run_in_background: true
   )
   ```

### Monitor workers

After spawning all workers, the team lead monitors progress:

1. Workers send messages when they complete (automatic via Team system)
2. For each worker completion message, parse the `SWARM_WORKER_RESULT` block
3. Track results: `succeeded_workers`, `failed_workers`

Wait for all workers to finish (all teammates go idle with results).

## Step 6: Merge Worktrees

After ALL workers complete:

### Merge successful worktrees

For workers that reported `status: completed`:

```bash
$WORKTREE_MGR merge-all [succeeded_worktree_names...] --into <mainBranch>
```

Where `mainBranch` is the current branch (or a shared integration branch).

**If merge conflict** (non-zero exit):
```
MERGE CONFLICT during swarm merge.

Conflicting files:
[conflict output from merge-all]

Resolve conflicts on the current branch and re-run merges manually.
Worktrees preserved for inspection:
  - aimi-<slug1>: <WORKTREE_PATH1>
  - aimi-<slug2>: <WORKTREE_PATH2>
```
STOP (do NOT remove worktrees so user can inspect).

### Handle failed workers

For workers that reported `status: failed`:
- Log the failure details
- Do NOT attempt to merge their worktree

## Step 7: Cleanup

After successful merges:

1. **Remove all worktrees**:
   ```bash
   for each worktree in aimi-<slug>:
     $WORKTREE_MGR remove <worktree_name>
   ```

2. **Prune Docker containers** (safety net — `--rm` should have handled it):
   ```bash
   docker container prune -f --filter "label=aimi-swarm" 2>/dev/null
   ```

3. **Delete team**:
   ```
   TeamDelete()
   ```

## Step 8: Report Summary

```
## Swarm Execution Complete

### Results

| # | Task File | Branch | Status | Stories |
|---|-----------|--------|--------|---------|
| 1 | .aimi/tasks/auth-tasks.json | feat/auth | completed | 5/5 |
| 2 | .aimi/tasks/ui-tasks.json | feat/ui | failed | 2/3 |

### Summary
- Total: [N] task files
- Completed: [N]
- Failed: [N]
- Merges: [N] successful

### Failed Workers
[For each failed worker, show error summary]

### Next Steps
- Review changes on the current branch
- Run /aimi:review for code review
- Fix failed task files and re-run: /aimi:swarm --file <path>
- Clean up leftovers: /aimi:swarm cleanup
```

## Error Recovery

### Docker not available
The swarm requires Docker. Use `/aimi:execute` for single-file execution without Docker.

### Worker failure
Successful workers merge independently. Failed workers are reported. The user can:
- Fix the issue in the task file
- Re-run: `/aimi:swarm --file <path>`

### Merge conflict
Worktrees are preserved for manual inspection. The user resolves conflicts and re-runs.

### Interrupted swarm
If interrupted mid-execution:
- Docker containers with `--rm` self-clean on exit
- Worktrees persist until cleanup: `/aimi:swarm cleanup`
- Task file state is preserved — re-run picks up where it left off
