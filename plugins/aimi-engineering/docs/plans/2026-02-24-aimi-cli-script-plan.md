# Implementation Plan: Aimi CLI Script

**Date:** 2026-02-24
**Brainstorm:** [docs/brainstorms/2026-02-24-aimi-cli-script-brainstorm.md](../brainstorms/2026-02-24-aimi-cli-script-brainstorm.md)

## Overview

Create a single `aimi-cli.sh` bash script that handles all deterministic task file operations. This prevents AI hallucination when interpreting jq queries and enables story-by-story execution with context resets.

## Goals

1. Eliminate AI hallucination in bash command interpretation
2. Enable story-by-story execution with `/clear` between stories
3. Maintain state across context resets via `.aimi/` directory
4. Simplify command files by delegating to CLI script

## User Stories

### US-001: Create Core Script Structure

**Priority:** 1

**Description:** Create the base `scripts/aimi-cli.sh` with subcommand routing, help system, and jq dependency check.

**Acceptance Criteria:**
- [x] Script at `scripts/aimi-cli.sh` with executable permissions
- [x] Subcommand routing via case statement
- [x] Help command showing all available commands
- [x] jq dependency check with helpful error message
- [x] Exit codes: 0=success, 1=error
- [x] Error messages to stderr

**Implementation:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi

AIMI_DIR=".aimi"
TASKS_DIR="docs/tasks"

# Ensure jq is available
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed." >&2
    exit 1
  fi
}

# Main command router
main() {
  check_jq

  case "${1:-help}" in
    init-session)  cmd_init_session ;;
    find-tasks)    cmd_find_tasks ;;
    status)        cmd_status ;;
    metadata)      cmd_metadata ;;
    next-story)    cmd_next_story ;;
    current-story) cmd_current_story ;;
    mark-complete) cmd_mark_complete "${2:-}" ;;
    mark-failed)   cmd_mark_failed "${2:-}" "${3:-}" ;;
    mark-skipped)  cmd_mark_skipped "${2:-}" ;;
    count-pending) cmd_count_pending ;;
    get-branch)    cmd_get_branch ;;
    get-state)     cmd_get_state ;;
    clear-state)   cmd_clear_state ;;
    help|--help|-h) cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
```

---

### US-002: Implement State Management

**Priority:** 2

**Description:** Create functions to manage state files in `.aimi/` directory.

**Acceptance Criteria:**
- [ ] `ensure_state_dir()` creates `.aimi/` if not exists
- [ ] `read_state(key)` reads from `.aimi/$key` (returns empty if not exists)
- [ ] `write_state(key, value)` writes to `.aimi/$key`
- [ ] `clear_state()` removes all state files
- [ ] `.aimi/` added to `.gitignore` check (warn if not ignored)

**State Files:**
- `current-tasks` - Path to active tasks file
- `current-branch` - Current working branch name
- `current-story` - ID of story being executed
- `last-result` - Result of last execution (success/failed/skipped)

**Implementation:**

```bash
ensure_state_dir() {
  mkdir -p "$AIMI_DIR"
}

read_state() {
  local key="$1"
  local file="$AIMI_DIR/$key"
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  echo "$value" > "$AIMI_DIR/$key"
}

clear_state_file() {
  local key="$1"
  rm -f "$AIMI_DIR/$key"
}
```

---

### US-003: Implement find-tasks Command

**Priority:** 3

**Description:** Find the most recent tasks file in `docs/tasks/`.

**Acceptance Criteria:**
- [ ] Returns path to most recent `*-tasks.json` file
- [ ] Returns error (exit 1) if no tasks file found
- [ ] Outputs path to stdout on success

**Implementation:**

```bash
cmd_find_tasks() {
  local tasks_file
  tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)

  if [ -z "$tasks_file" ]; then
    echo "No tasks file found in $TASKS_DIR/" >&2
    exit 1
  fi

  echo "$tasks_file"
}
```

---

### US-004: Implement init-session Command

**Priority:** 4

**Description:** Initialize execution session by discovering tasks file and saving state.

**Acceptance Criteria:**
- [ ] Finds tasks file (or errors if none)
- [ ] Saves tasks file path to `.aimi/current-tasks`
- [ ] Extracts and saves branchName to `.aimi/current-branch`
- [ ] Outputs JSON with session info: `{tasks, branch, pending}`
- [ ] Validates branchName matches `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`

**Implementation:**

```bash
cmd_init_session() {
  local tasks_file branch pending

  tasks_file=$(cmd_find_tasks)
  write_state "current-tasks" "$tasks_file"

  branch=$(jq -r '.metadata.branchName' "$tasks_file")

  # Validate branch name
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  write_state "current-branch" "$branch"

  pending=$(jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file")

  jq -n --arg tasks "$tasks_file" --arg branch "$branch" --argjson pending "$pending" \
    '{tasks: $tasks, branch: $branch, pending: $pending}'
}
```

---

### US-005: Implement status Command

**Priority:** 5

**Description:** Get comprehensive status summary as JSON.

**Acceptance Criteria:**
- [ ] Uses cached tasks file from state (or discovers if no state)
- [ ] Returns JSON with: `{title, pending, completed, skipped, total, stories: [{id, title, passes, skipped}]}`
- [ ] Pending stories sorted by priority

**Implementation:**

```bash
cmd_status() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  jq '{
    title: .metadata.title,
    branch: .metadata.branchName,
    pending: [.userStories[] | select(.passes == false and .skipped != true)] | length,
    completed: [.userStories[] | select(.passes == true)] | length,
    skipped: [.userStories[] | select(.skipped == true)] | length,
    total: .userStories | length,
    stories: [.userStories[] | {id, title, passes, skipped: (.skipped // false), notes}]
  }' "$tasks_file"
}
```

---

### US-006: Implement next-story Command

**Priority:** 6

**Description:** Get the next pending story and save to state.

**Acceptance Criteria:**
- [ ] Returns next pending story (lowest priority, not passed, not skipped)
- [ ] Saves story ID to `.aimi/current-story`
- [ ] Returns `null` if no pending stories
- [ ] Full story JSON output (id, title, description, acceptanceCriteria, priority)

**Implementation:**

```bash
cmd_next_story() {
  local tasks_file story story_id
  tasks_file=$(get_tasks_file)

  story=$(jq '[.userStories[] | select(.passes == false and .skipped != true)] | sort_by(.priority) | .[0]' "$tasks_file")

  if [ "$story" = "null" ]; then
    clear_state_file "current-story"
    echo "null"
    return
  fi

  story_id=$(echo "$story" | jq -r '.id')
  write_state "current-story" "$story_id"

  echo "$story"
}
```

---

### US-007: Implement current-story Command

**Priority:** 7

**Description:** Get the currently active story from state.

**Acceptance Criteria:**
- [ ] Reads story ID from `.aimi/current-story`
- [ ] Returns full story JSON from tasks file
- [ ] Returns `null` if no current story

**Implementation:**

```bash
cmd_current_story() {
  local story_id tasks_file
  story_id=$(read_state "current-story")

  if [ -z "$story_id" ]; then
    echo "null"
    return
  fi

  tasks_file=$(get_tasks_file)
  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}
```

---

### US-008: Implement mark-complete Command

**Priority:** 8

**Description:** Mark a story as passed and update state.

**Acceptance Criteria:**
- [ ] Sets `passes: true` for specified story ID
- [ ] Clears `.aimi/current-story`
- [ ] Sets `.aimi/last-result` to "success"
- [ ] Uses atomic file update (temp + mv)
- [ ] Outputs updated story JSON

**Implementation:**

```bash
cmd_mark_complete() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  # Atomic update
  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" \
    '(.userStories[] | select(.id == $id)) |= . + {passes: true}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "success"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}
```

---

### US-009: Implement mark-failed and mark-skipped Commands

**Priority:** 9

**Description:** Mark stories as failed (with notes) or skipped.

**Acceptance Criteria:**
- [ ] `mark-failed <id> <notes>` - adds notes to story, sets last-result to "failed"
- [ ] `mark-skipped <id>` - sets `skipped: true`, last-result to "skipped"
- [ ] Both clear current-story state
- [ ] Both use atomic file updates

**Implementation:**

```bash
cmd_mark_failed() {
  local story_id="$1"
  local notes="$2"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-failed <story-id> <notes>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" --arg notes "$notes" \
    '(.userStories[] | select(.id == $id)) |= . + {notes: $notes}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "failed"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

cmd_mark_skipped() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" \
    '(.userStories[] | select(.id == $id)) |= . + {skipped: true}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}
```

---

### US-010: Implement Helper Commands

**Priority:** 10

**Description:** Implement remaining utility commands.

**Acceptance Criteria:**
- [ ] `metadata` - returns only metadata object from tasks file
- [ ] `count-pending` - returns number of pending stories
- [ ] `get-branch` - returns branchName string
- [ ] `get-state` - returns all state as JSON object
- [ ] `clear-state` - removes all files in `.aimi/`

**Implementation:**

```bash
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata' "$tasks_file"
}

cmd_count_pending() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file"
}

cmd_get_branch() {
  local branch
  branch=$(read_state "current-branch")

  if [ -z "$branch" ]; then
    local tasks_file
    tasks_file=$(get_tasks_file)
    branch=$(jq -r '.metadata.branchName' "$tasks_file")
  fi

  echo "$branch"
}

cmd_get_state() {
  jq -n \
    --arg tasks "$(read_state current-tasks)" \
    --arg branch "$(read_state current-branch)" \
    --arg story "$(read_state current-story)" \
    --arg last "$(read_state last-result)" \
    '{tasks: $tasks, branch: $branch, story: ($story | if . == "" then null else . end), last: ($last | if . == "" then null else . end)}'
}

cmd_clear_state() {
  rm -rf "$AIMI_DIR"
  echo "State cleared."
}

cmd_help() {
  cat << 'EOF'
aimi-cli.sh - Deterministic task file operations for Aimi

USAGE:
    aimi-cli.sh <command> [args]

COMMANDS:
    init-session        Initialize execution session, save state
    find-tasks          Find most recent tasks file
    status              Get status summary as JSON
    metadata            Get metadata only
    next-story          Get next pending story, save to state
    current-story       Get currently active story from state
    mark-complete <id>  Mark story as passed
    mark-failed <id> <notes>  Mark story with failure notes
    mark-skipped <id>   Mark story as skipped
    count-pending       Count pending stories
    get-branch          Get branchName from metadata
    get-state           Get all state files as JSON
    clear-state         Clear all state files
    help                Show this help message

STATE FILES (.aimi/):
    current-tasks       Path to active tasks file
    current-branch      Current working branch name
    current-story       ID of story being executed
    last-result         Result of last execution (success/failed/skipped)
EOF
}
```

---

### US-011: Update execute.md to Use CLI

**Priority:** 11

**Description:** Update `/aimi:execute` command to use `aimi-cli.sh` instead of inline jq.

**Acceptance Criteria:**
- [ ] Replace inline jq with CLI calls
- [ ] Use `init-session` for setup
- [ ] Use `count-pending` and `status` for progress checks
- [ ] Use `get-state` for resumption after `/clear`
- [ ] Simplified, less error-prone command file

**Changes:**

```markdown
## Step 1: Initialize Session

```bash
./scripts/aimi-cli.sh init-session
```

Returns: `{tasks, branch, pending}`

## Step 2: Check Pending Count

```bash
./scripts/aimi-cli.sh count-pending
```

If 0, all stories complete.

## Step 3: Execution Loop

while pending > 0:
    1. Call /aimi:next
    2. Check result
    3. ./scripts/aimi-cli.sh count-pending
```

---

### US-012: Update next.md to Use CLI

**Priority:** 12

**Description:** Update `/aimi:next` command to use `aimi-cli.sh` for story retrieval and state updates.

**Acceptance Criteria:**
- [ ] Use `next-story` to get next pending story
- [ ] Use `mark-complete` on success
- [ ] Use `mark-failed` on failure
- [ ] Use `mark-skipped` when user skips
- [ ] Cleaner prompt generation (no inline jq)

**Changes:**

```markdown
## Step 1: Get Next Story

```bash
./scripts/aimi-cli.sh next-story
```

Returns full story JSON or `null`.

## Step 5: Handle Result

### On success:
```bash
./scripts/aimi-cli.sh mark-complete [STORY_ID]
```

### On failure:
```bash
./scripts/aimi-cli.sh mark-failed [STORY_ID] "Error message"
```

### On skip:
```bash
./scripts/aimi-cli.sh mark-skipped [STORY_ID]
```
```

---

### US-013: Update status.md to Use CLI

**Priority:** 13

**Description:** Update `/aimi:status` command to use `aimi-cli.sh status`.

**Acceptance Criteria:**
- [ ] Single CLI call replaces all jq logic
- [ ] Parse JSON output for display formatting
- [ ] Simpler, more maintainable command

---

### US-014: Add .gitignore Entry

**Priority:** 14

**Description:** Ensure `.aimi/` is gitignored.

**Acceptance Criteria:**
- [ ] Add `.aimi/` to project's `.gitignore`
- [ ] CLI warns if `.aimi/` is not gitignored

---

### US-015: Create Test Script

**Priority:** 15

**Description:** Create a test script that validates CLI functionality.

**Acceptance Criteria:**
- [ ] `scripts/test-aimi-cli.sh` exercises all commands
- [ ] Creates temporary tasks file for testing
- [ ] Validates output format and exit codes
- [ ] Cleans up after test

---

## Implementation Order

1. **US-001**: Core script structure (foundation)
2. **US-002**: State management (needed by most commands)
3. **US-003**: find-tasks (needed by init-session)
4. **US-004**: init-session (entry point)
5. **US-005**: status (display command)
6. **US-006**: next-story (core workflow)
7. **US-007**: current-story (state query)
8. **US-008**: mark-complete (success path)
9. **US-009**: mark-failed/skipped (failure paths)
10. **US-010**: Helper commands
11. **US-011**: Update execute.md
12. **US-012**: Update next.md
13. **US-013**: Update status.md
14. **US-014**: .gitignore
15. **US-015**: Test script

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `scripts/aimi-cli.sh` | Create | Main CLI script |
| `scripts/test-aimi-cli.sh` | Create | Test script |
| `commands/execute.md` | Update | Use CLI instead of jq |
| `commands/next.md` | Update | Use CLI instead of jq |
| `commands/status.md` | Update | Use CLI instead of jq |
| `.gitignore` | Update | Add `.aimi/` entry |

## Risk Mitigation

1. **jq dependency** - Script checks for jq and provides clear error
2. **Atomic updates** - temp file + mv pattern prevents corruption
3. **State corruption** - clear-state command for recovery
4. **Backward compatibility** - Commands still work, just delegating to script

## Success Metrics

1. AI no longer needs to interpret jq queries
2. Story execution works with `/clear` between stories
3. State persists across context resets
4. Commands are simpler and less error-prone
