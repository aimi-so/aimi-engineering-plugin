---
name: aimi:swarm
description: "Execute multiple tasks.json files in parallel Docker sandboxes"
disable-model-invocation: true
allowed-tools: Read, Bash(SANDBOX_MGR=*), Bash($SANDBOX_MGR:*), Bash(BUILD_IMG=*), Bash($BUILD_IMG:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(docker:*), Bash(git:*), Task, Glob, AskUserQuestion
---

# Aimi Swarm

Execute multiple tasks.json files in parallel Docker sandboxes. Each task file runs inside its own Sysbox-isolated container with a full Claude Code agent executing the story-executor flow.

## Step 0: Resolve Tool Paths

**CRITICAL:** Resolve all tool paths from the plugin install directory first.

```bash
# CLI script
AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then
  AIMI_CLI=$(cat .aimi/cli-path)
fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

```bash
# Sandbox manager
SANDBOX_MGR=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/skills/docker-sandbox/scripts/sandbox-manager.sh 2>/dev/null | tail -1)
```

If empty, report: "sandbox-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

```bash
# Build image script
BUILD_IMG=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/skills/docker-sandbox/scripts/build-project-image.sh 2>/dev/null | tail -1)
```

If empty, report: "build-project-image.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

**Use `$AIMI_CLI`, `$SANDBOX_MGR`, and `$BUILD_IMG` for ALL subsequent script calls.**

## Step 1: Handle Subcommands

Check if `$ARGUMENTS` contains a subcommand:

### State Reconciliation (shared subroutine)

**This reconciliation runs automatically before `status` display and at the start of `resume`.** It detects zombie entries (containers that exist in `swarm-state.json` but no longer exist as Docker containers) and corrects stale state.

Reconciliation procedure:

1. Load the current swarm state:
   ```bash
   $AIMI_CLI swarm-status
   ```
   If no active swarm exists, skip reconciliation.

2. For each container entry in the state (parse the JSON output to get the list of containers with their `containerName` and `status`):

   a. **Skip terminal entries:** If `status` is `completed`, `failed`, or `stopped`, skip this container (no reconciliation needed for already-terminal entries).

   b. **Query actual Docker state:**
      ```bash
      $SANDBOX_MGR status <containerName>
      ```
      Parse the JSON output. Key fields: `exists` (boolean), `swarmState` (string), `exitCode` (integer).

   c. **Zombie detection — container gone from Docker:**
      If `exists` is `false` (container no longer exists on Docker daemon but state says `pending` or `running`):
      - This is a **zombie entry**. The container was removed or crashed without updating swarm state.
      - Update the swarm state to `failed`:
        ```bash
        $AIMI_CLI swarm-update <containerName> --status failed
        ```
      - Record this zombie for reporting: `"<containerName>: zombie (container not found, was <originalStatus>)"`

   d. **State drift — Docker state disagrees with swarm state:**
      If `exists` is `true` but `swarmState` from Docker differs from the recorded `status`:

      - If Docker says `completed` (exit code 0) but state says `running` or `pending`:
        ```bash
        $AIMI_CLI swarm-update <containerName> --status completed
        ```

      - If Docker says `failed` (exit code non-zero) but state says `running` or `pending`:
        ```bash
        $AIMI_CLI swarm-update <containerName> --status failed
        ```

      - If Docker says `stopped` (paused/removing) but state says `running`:
        ```bash
        $AIMI_CLI swarm-update <containerName> --status stopped
        ```

      - If Docker says `running` but state says `pending`:
        ```bash
        $AIMI_CLI swarm-update <containerName> --status running
        ```

      - Record any state drift for reporting: `"<containerName>: state corrected <oldStatus> -> <newStatus>"`

3. If any zombies or drift were detected, report them:
   ```
   State reconciliation:
     - aimi-swarm-auth: zombie (container not found, was running)
     - aimi-swarm-ui: state corrected running -> completed
   ```
   If no issues found, report: `"State reconciliation: all entries consistent."`

### `status`
If arguments start with `status`:

1. **Run state reconciliation** (see subroutine above). This ensures the displayed state reflects reality.

2. Re-read the reconciled swarm state:
   ```bash
   $AIMI_CLI swarm-status
   ```

3. Format the output as a summary table:
   ```
   ## Swarm Status

   Swarm ID: <swarmId>
   Updated: <updatedAt>

   | # | Container | Task File | Branch | Status | Progress |
   |---|-----------|-----------|--------|--------|----------|
   | 1 | aimi-swarm-auth | .aimi/tasks/auth-tasks.json | feat/auth | completed | 5/5 |
   | 2 | aimi-swarm-ui | .aimi/tasks/ui-tasks.json | feat/ui | running | 2/3 |
   | 3 | aimi-swarm-api | .aimi/tasks/api-tasks.json | feat/api | failed | 0/4 |

   Summary: 1 completed, 1 running, 1 failed (3 total)
   ```

   The Progress column is derived from `storyProgress`: `<completed>/<total>`.

4. STOP.

### `resume`
If arguments start with `resume`:

1. **Run state reconciliation** (see subroutine above). This corrects zombies and stale state before making resume decisions.

2. Re-read the reconciled swarm state:
   ```bash
   $AIMI_CLI swarm-status
   ```
   Parse the containers list. Classify each container by its (now-reconciled) status.

3. **Identify resumable containers:**
   - `pending` containers: Need ACP adapter invocation (were never started or were added after a crash).
   - `failed` containers: May be retried. Check if they are still present as Docker containers:
     ```bash
     $SANDBOX_MGR status <containerName>
     ```
     - If the Docker container exists and is stopped/exited, it can be removed and recreated.
     - If the Docker container does not exist, it needs to be recreated from scratch.

4. **Handle running containers:**
   For containers still showing `running` after reconciliation (Docker confirms they are actually running):
   - Report: `"<containerName>: still running in Docker, skipping"`
   - Do NOT re-invoke the ACP adapter for these.

5. **Handle completed containers:**
   For containers with status `completed`:
   - Report: `"<containerName>: already completed"`
   - Check if a PR URL exists in the state. If so, include it in the report.
   - Skip these containers.

6. **Recreate failed containers for retry:**
   For each `failed` container that should be retried:
   a. Remove the old Docker container if it still exists:
      ```bash
      $SANDBOX_MGR remove <containerName>
      ```
   b. Read the task file path and branch from the swarm state entry.
   c. Verify the task file still exists on disk. If not, report error and skip this container.
   d. Recreate the container (follows same pattern as Step 4 in the main flow):
      ```bash
      $SANDBOX_MGR create <containerName> --image <PROJECT_IMAGE> --task-file <taskFile> --branch <BRANCH>
      ```
      **Note:** `PROJECT_IMAGE` must be resolved. Run `$BUILD_IMG` to build/reuse the project image if not already available.
   e. Parse the new `containerId` from the JSON output.
   f. Update the swarm state with the new container ID and reset status to `pending`:
      ```bash
      $AIMI_CLI swarm-update <containerName> --status pending
      ```

7. **Fan out pending containers:**
   If there are containers with status `pending` (either originally pending or reset from failed):
   - Resolve `REPO_URL` from `git remote get-url origin` if not already known.
   - Proceed to Step 5 (fan-out) for these pending containers only.
   - After fan-out and result collection, proceed to Step 6 for state update and reporting.

8. **All terminal — nothing to resume:**
   If all containers are in terminal states (`completed`, `failed`, `stopped`) and there are no `pending` containers after the retry logic:
   ```
   All containers are in terminal state. Nothing to resume.

   | Container | Status | PR |
   |-----------|--------|----|
   | aimi-swarm-auth | completed | https://github.com/org/repo/pull/42 |
   | aimi-swarm-api | failed | - |

   To retry failed containers, fix the underlying issues and run `/aimi:swarm --file <taskFile>`.
   To clean up: `/aimi:swarm cleanup`
   ```
   STOP.

### `cleanup`
If arguments start with `cleanup`:

1. Load the current swarm state:
   ```bash
   $AIMI_CLI swarm-status
   ```
   If no active swarm exists, report: `"No active swarm to clean up."` and STOP.

2. Parse the containers list from the state JSON.

3. **Remove Docker containers:**
   For each container entry, regardless of status:
   ```bash
   $SANDBOX_MGR remove <containerName>
   ```
   The `remove` command is idempotent — it handles containers that no longer exist gracefully.

   Track results:
   - Removed: containers that existed and were removed
   - Already gone: containers that did not exist in Docker

4. **Clean swarm state:**
   ```bash
   $AIMI_CLI swarm-cleanup
   ```
   This removes terminal (`completed`, `failed`, `stopped`) entries from swarm-state.json.

5. **Report cleanup results:**
   ```
   ## Swarm Cleanup Complete

   Docker containers:
     - aimi-swarm-auth: removed
     - aimi-swarm-ui: removed
     - aimi-swarm-api: already gone (not found in Docker)

   State entries cleaned: 3
   Remaining active entries: 0
   ```

6. STOP.

### Default (no subcommand or `--file`)
Proceed to Step 2.

## Step 2: Discover Task Files

### Single file mode (`--file` flag)
If `$ARGUMENTS` contains `--file <path>`:
- Validate the file exists and ends with `.json`
- Use that single file as the selection
- Skip to Step 3

### Multi-select discovery mode
Glob for task files:
```bash
ls -t .aimi/tasks/*-tasks.json 2>/dev/null
```

If no files found:
```
No task files found in .aimi/tasks/. Run /aimi:plan to create a task list first.
```
STOP.

Present the discovered files to the user:
```
Found [N] task file(s):

  1. .aimi/tasks/2026-03-01-feature-auth-tasks.json (feat/auth, 5 stories)
  2. .aimi/tasks/2026-03-01-feature-ui-tasks.json (feat/ui, 3 stories)
  3. .aimi/tasks/2026-03-01-bugfix-login-tasks.json (bug/login, 2 stories)

Select files to execute (comma-separated numbers, or "all"):
```

For each file, extract metadata with:
```bash
jq -r '.metadata | "\(.branchName) — \(.title)"' <file>
```

And count stories:
```bash
jq '[.userStories[] | select(.status == "pending")] | length' <file>
```

Use `AskUserQuestion` to get the selection. Parse the response:
- `all` -> select all files
- `1,3` -> select files 1 and 3
- `1` -> select file 1

Validate the selection. If invalid, ask again.

Store the selected files as `SELECTED_TASK_FILES`.

### Max containers limit

Read `maxContainers` from context. Default: **4**.

If the user provides `--max <N>` in arguments, use that value instead.

If `len(SELECTED_TASK_FILES) > maxContainers`:
```
Selected [N] task files but maxContainers is [maxContainers].
Only the first [maxContainers] will be executed. Remaining files can be run with /aimi:swarm resume.
```

Truncate `SELECTED_TASK_FILES` to `maxContainers`.

## Step 3: Initialize Swarm State

### Check for existing active swarm
```bash
$AIMI_CLI swarm-status 2>/dev/null
```

If an active swarm exists with running/pending containers, ask the user:
```
An active swarm exists with [N] running/pending containers.

Options:
  1. Resume existing swarm (add new tasks alongside)
  2. Force reinitialize (stops existing containers)
  3. Cancel

Select option:
```

- Option 1: Proceed without reinitializing, add new containers to existing state
- Option 2: Run cleanup first, then reinitialize
- Option 3: STOP

### Initialize new swarm state
```bash
$AIMI_CLI swarm-init
```

If using `--force` (option 2 above):
```bash
$AIMI_CLI swarm-init --force
```

Store the returned `swarmId`.

### Resolve git remote URL
```bash
git remote get-url origin
```

Store as `REPO_URL`. If no remote, report error and STOP:
```
No git remote 'origin' found. The swarm needs a remote URL so containers can clone the repo.
Set one with: git remote add origin <url>
```

Report:
```
Swarm initialized: [swarmId]
Task files: [count]
Max containers: [maxContainers]
```

## Step 4: Provision Containers

### Check Sysbox runtime
```bash
$SANDBOX_MGR check-runtime
```

If Sysbox is not available, report the error and STOP.

### Build project image
```bash
$BUILD_IMG
```

This builds (or reuses) `aimi-sandbox-<project-slug>:latest`. Store the image tag from the output.

Parse the image tag from the build output. The script logs `Image tag    : <tag>` or `Done. Image: <tag>`. Extract the tag value and store as `PROJECT_IMAGE`.

### Create containers sequentially

For each task file in `SELECTED_TASK_FILES`:
1. Read metadata:
   ```bash
   jq -r '.metadata.branchName' <taskFile>
   ```
   Store as `BRANCH`.

2. Derive container name from the task file:
   - Extract the feature slug from the filename (e.g., `2026-03-01-feature-auth-tasks.json` -> `feature-auth`)
   - Container name: `aimi-swarm-<slug>` (must match `^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`)

3. Create the container:
   ```bash
   $SANDBOX_MGR create <containerName> --image <PROJECT_IMAGE> --task-file <taskFile> --branch <BRANCH>
   ```

4. Parse the JSON output to get `containerId`.

5. Register in swarm state:
   ```bash
   $AIMI_CLI swarm-add <containerId> <containerName> <taskFile> <BRANCH>
   ```

6. Count stories for progress tracking:
   ```bash
   jq '.userStories | length' <taskFile>
   ```
   Update initial story progress:
   ```bash
   $AIMI_CLI swarm-update <containerName> --status pending --story-progress '{"total":<N>,"completed":0,"failed":0,"inProgress":0,"pending":<N>}'
   ```

Report container creation:
```
Provisioned [N] containers:
  - [containerName]: [taskFile] ([branch])
  ...
```

If any container creation fails, mark it as `failed` in swarm state and continue with the rest. Report which containers failed.

## Step 5: Fan Out — Parallel ACP Adapter Invocations

**CRITICAL:** This step spawns one Task agent per container. All Task calls MUST be emitted in a SINGLE tool-call turn so they execute concurrently.

For each container with status `pending` in the swarm state:

1. First, update its status to `running`:
   ```bash
   $AIMI_CLI swarm-update <containerName> --status running
   ```

2. Build the ACP task-request payload:
   ```json
   {
     "type": "task-request",
     "timestamp": "<ISO 8601 now>",
     "swarmId": "<swarmId>",
     "containerId": "<containerId>",
     "payload": {
       "taskFilePath": "<taskFile>",
       "branchName": "<branch>",
       "repoUrl": "<REPO_URL>"
     }
   }
   ```

3. Spawn a Task agent for this container. In a SINGLE tool-call turn, emit ALL Task calls:

```
Task(
    subagent_type: "general-purpose",
    description: "Swarm worker: [containerName] executing [taskFile]",
    prompt: """
You are a swarm worker agent managing a Docker sandbox container.

## Container Info
- Name: [containerName]
- Container ID: [containerId]
- Task File: [taskFile]
- Branch: [branch]
- Swarm ID: [swarmId]

## Your Job

1. Send the task-request payload to the ACP adapter inside the container via docker exec:

```bash
echo '<task-request-json>' | docker exec -i [containerName] python3 /opt/aimi/acp-adapter.py
```

2. Read the NDJSON output lines from stdout. Each line is a JSON message.

3. For each message received:
   - **progress-update**: Log the story ID and status. If you can parse story progress counts, report them.
   - **completion**: Record the final status and PR URL (if any). This is the last message.
   - **error**: Record the error code and message. The container may exit after this.

4. When the process exits (docker exec returns):
   - If exit code 0 and last message was completion with status "completed": report SUCCESS
   - If exit code non-zero or last message was error/failed: report FAILURE with details
   - Capture the last 20 lines of output for the summary

5. Report your result as a structured summary:
```
SWARM_WORKER_RESULT:
container: [containerName]
taskFile: [taskFile]
branch: [branch]
status: [completed|failed|stopped]
prUrl: [url or null]
errors: [list or empty]
```

Do NOT modify the tasks.json file. Do NOT modify swarm-state.json. Just run the docker exec and report results.
"""
)
```

**All Task calls must be in ONE tool-call turn.** Wait for all to return.

## Step 6: Collect Results and Update State

After ALL Task agents return, process each result:

### Parse results

For each Task agent result, look for the `SWARM_WORKER_RESULT:` block and parse:
- `container`: container name
- `status`: completed, failed, or stopped
- `prUrl`: PR URL or null
- `errors`: error list

### Update swarm state

For each result:

```bash
$AIMI_CLI swarm-update <containerName> --status <status>
```

If a PR URL was returned:
```bash
$AIMI_CLI swarm-update <containerName> --status <status> --pr-url <prUrl>
```

### Remove containers

For each container (success or failure):
```bash
$SANDBOX_MGR remove <containerName>
```

### Report summary

```
## Swarm Execution Complete

Swarm ID: [swarmId]
Duration: [estimated from timestamps]

### Results

| Container | Task File | Branch | Status | PR |
|-----------|-----------|--------|--------|-----|
| [name] | [file] | [branch] | completed | [PR URL] |
| [name] | [file] | [branch] | failed | - |
...

### Summary
- Total: [N] containers
- Completed: [N]
- Failed: [N]

### Failed Containers
[For each failed container, show error details]

### Next Steps
- Review PRs: [list PR URLs]
- Check failures: `/aimi:swarm status`
- Clean up: `/aimi:swarm cleanup`
```

## Error Recovery

### Container creation failure
If `$SANDBOX_MGR create` fails for a specific container:
- Mark it as `failed` in swarm state
- Continue with remaining containers
- Report the failure in the summary

### ACP adapter failure
If `docker exec` fails or returns non-zero:
- Parse any error messages from the output
- Mark the container as `failed` in swarm state
- Continue processing other containers

### Partial failure
Successful containers proceed independently. Failed containers are marked in state. The user can:
- Review failures: `/aimi:swarm status`
- Fix and retry individual task files: `/aimi:swarm --file <path>`
- Clean up: `/aimi:swarm cleanup`

### Interrupted swarm
If the swarm is interrupted (e.g., user stops the command):
- Containers continue running in Docker (they are detached)
- User can resume: `/aimi:swarm resume`
- User can check status: `/aimi:swarm status`
- User can clean up: `/aimi:swarm cleanup`

## State Reconciliation

State reconciliation detects and corrects inconsistencies between `swarm-state.json` and actual Docker daemon state. It runs automatically:

- **Before every `status` display** — so the user always sees accurate state
- **At the start of every `resume`** — so resume decisions are based on reality

### What It Detects

| Scenario | Detection | Action |
|----------|-----------|--------|
| **Zombie entry** | Container ID in state but container does not exist in Docker | Mark as `failed` |
| **Silent completion** | Docker says exited with code 0 but state says `running` | Mark as `completed` |
| **Silent failure** | Docker says exited with non-zero code but state says `running` | Mark as `failed` |
| **Unexpected stop** | Docker says paused/removing but state says `running` | Mark as `stopped` |
| **Already started** | Docker says running but state says `pending` | Mark as `running` |

### How Zombies Happen

Zombies occur when:
- The host machine crashes while containers are running
- Docker daemon restarts and auto-removes containers
- A user manually runs `docker rm` on a container
- The ACP adapter process crashes and the container self-terminates

### Reconciliation Is Idempotent

Running reconciliation multiple times produces the same result. Terminal entries (`completed`, `failed`, `stopped`) are never re-reconciled.

## Resuming Execution

Running `/aimi:swarm resume`:
1. **Reconciles state** — detects zombies and corrects stale entries (see State Reconciliation above)
2. **Identifies resumable containers** — `pending` containers need ACP invocation, `failed` containers can be retried (removed and recreated)
3. **Skips running containers** — if Docker confirms they are still active
4. **Skips completed containers** — reports their PR URLs
5. **Recreates failed containers** — removes old container, rebuilds, resets to `pending`
6. **Fans out pending containers** — spawns ACP adapter tasks for all pending containers
7. **Reports summary** when all containers reach terminal state
