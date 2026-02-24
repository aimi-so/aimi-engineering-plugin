#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.

AIMI_DIR=".aimi"
TASKS_DIR="docs/tasks"

# ============================================================================
# Utility Functions
# ============================================================================

# Ensure jq is available
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
  fi
}

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$AIMI_DIR"
}

# Read a state file, returns empty string if not exists
read_state() {
  local key="$1"
  local file="$AIMI_DIR/$key"
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

# Write a value to a state file
write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  echo "$value" > "$AIMI_DIR/$key"
}

# Clear a single state file
clear_state_file() {
  local key="$1"
  rm -f "$AIMI_DIR/$key"
}

# Get the tasks file (from state or discover)
get_tasks_file() {
  local tasks_file
  tasks_file=$(read_state "current-tasks")

  if [ -z "$tasks_file" ] || [ ! -f "$tasks_file" ]; then
    tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
  fi

  echo "$tasks_file"
}

# ============================================================================
# Commands
# ============================================================================

# Find the most recent tasks file
cmd_find_tasks() {
  local tasks_file
  tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)

  if [ -z "$tasks_file" ]; then
    echo "No tasks file found in $TASKS_DIR/" >&2
    exit 1
  fi

  echo "$tasks_file"
}

# Initialize execution session
cmd_init_session() {
  local tasks_file branch pending

  tasks_file=$(cmd_find_tasks)
  write_state "current-tasks" "$tasks_file"

  branch=$(jq -r '.metadata.branchName' "$tasks_file")

  # Validate branch name (security)
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  write_state "current-branch" "$branch"

  pending=$(jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file")

  jq -n --arg tasks "$tasks_file" --arg branch "$branch" --argjson pending "$pending" \
    '{tasks: $tasks, branch: $branch, pending: $pending}'
}

# Get comprehensive status summary
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

# Get metadata only
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata' "$tasks_file"
}

# Get next pending story
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

# Get currently active story from state
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

# Mark a story as complete
cmd_mark_complete() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" \
    '(.userStories[] | select(.id == $id)) |= . + {passes: true}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "success"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as failed with notes
cmd_mark_failed() {
  local story_id="$1"
  local notes="${2:-}"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-failed <story-id> [notes]" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" --arg notes "$notes" \
    '(.userStories[] | select(.id == $id)) |= . + {notes: $notes}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "failed"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as skipped
cmd_mark_skipped() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" \
    '(.userStories[] | select(.id == $id)) |= . + {skipped: true}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Count pending stories
cmd_count_pending() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file"
}

# Get branch name
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

# Get all state as JSON
cmd_get_state() {
  local tasks branch story last
  tasks=$(read_state "current-tasks")
  branch=$(read_state "current-branch")
  story=$(read_state "current-story")
  last=$(read_state "last-result")

  jq -n \
    --arg tasks "$tasks" \
    --arg branch "$branch" \
    --arg story "$story" \
    --arg last "$last" \
    '{
      tasks: (if $tasks == "" then null else $tasks end),
      branch: (if $branch == "" then null else $branch end),
      story: (if $story == "" then null else $story end),
      last: (if $last == "" then null else $last end)
    }'
}

# Clear all state files
cmd_clear_state() {
  rm -rf "$AIMI_DIR"
  echo "State cleared."
}

# Display help
cmd_help() {
  cat << 'EOF'
aimi-cli.sh - Deterministic task file operations for Aimi

USAGE:
    aimi-cli.sh <command> [args]

COMMANDS:
    init-session            Initialize execution session, save state
    find-tasks              Find most recent tasks file
    status                  Get status summary as JSON
    metadata                Get metadata only
    next-story              Get next pending story, save to state
    current-story           Get currently active story from state
    mark-complete <id>      Mark story as passed
    mark-failed <id> [notes] Mark story with failure notes
    mark-skipped <id>       Mark story as skipped
    count-pending           Count pending stories
    get-branch              Get branchName from metadata
    get-state               Get all state files as JSON
    clear-state             Clear all state files
    help                    Show this help message

STATE FILES (.aimi/):
    current-tasks           Path to active tasks file
    current-branch          Current working branch name
    current-story           ID of story being executed
    last-result             Result of last execution (success/failed/skipped)

EXAMPLES:
    # Initialize a new session
    ./scripts/aimi-cli.sh init-session

    # Get next story to work on
    ./scripts/aimi-cli.sh next-story

    # Mark story as complete
    ./scripts/aimi-cli.sh mark-complete US-001

    # Check progress
    ./scripts/aimi-cli.sh status

    # Resume after /clear
    ./scripts/aimi-cli.sh get-state
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

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
