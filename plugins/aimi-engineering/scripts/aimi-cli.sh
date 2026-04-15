#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.
# Operates on v3 task schema exclusively.

AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"

# ============================================================================
# Utility Functions
# ============================================================================

# Detect platform capabilities once at startup
_HAS_FLOCK=$(command -v flock &>/dev/null && echo 1 || echo 0)
_HAS_REALPATH=$(command -v realpath &>/dev/null && echo 1 || echo 0)

# Resolve a path to its absolute form (POSIX-compatible)
resolve_path() {
  local path="$1"
  if [ "$_HAS_REALPATH" -eq 1 ]; then
    realpath "$path"
  else
    (cd "$(dirname "$path")" && echo "$(pwd)/$(basename "$path")")
  fi
}

# Auto-discover the project root containing .aimi/ by walking up the directory tree.
# On success: cd to the discovered root, rewrite AIMI_DIR and TASKS_DIR to absolute paths,
#             and export PROJECT_ROOT for use by other functions.
# On failure (reached /): exit 1 with error to stderr.
find_aimi_root() {
  local dir
  dir=$(pwd)
  while true; do
    if [ -d "$dir/.aimi" ]; then
      cd "$dir"
      AIMI_DIR="$dir/.aimi"
      TASKS_DIR="$AIMI_DIR/tasks"

      # Discover the git repository root and export as PROJECT_ROOT
      local git_root
      git_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || git_root="$dir"
      PROJECT_ROOT=$(resolve_path "$git_root")
      export PROJECT_ROOT

      return 0
    fi
    # Stop at HOME — never scan above the user's home directory
    if [ "$dir" = "$HOME" ]; then
      echo "Error: .aimi/ directory not found (searched up to \$HOME)" >&2
      exit 1
    fi
    local parent
    parent=$(dirname "$dir")
    if [ "$parent" = "$dir" ]; then
      # Reached filesystem root without finding .aimi/
      echo "Error: .aimi/ directory not found in any parent directory" >&2
      exit 1
    fi
    dir="$parent"
  done
}

# Validate that a given path resolves to a location within PROJECT_ROOT.
# Worktree paths (under .worktrees/ inside PROJECT_ROOT) are explicitly allowed.
# Usage: validate_path_in_project "/some/path"
# Returns 0 if path is within PROJECT_ROOT, exits with error otherwise.
validate_path_in_project() {
  local target_path="$1"

  if [ -z "$target_path" ]; then
    echo "Error: validate_path_in_project requires a path argument" >&2
    exit 1
  fi

  if [ -z "$PROJECT_ROOT" ]; then
    echo "Error: PROJECT_ROOT is not set — call find_aimi_root() first" >&2
    exit 1
  fi

  # Resolve the target path to its absolute form
  local resolved_target
  if [ -e "$target_path" ]; then
    resolved_target=$(resolve_path "$target_path")
  else
    # For paths that don't exist yet, resolve the parent directory
    local parent_dir
    parent_dir=$(dirname "$target_path")
    if [ -e "$parent_dir" ]; then
      resolved_target="$(resolve_path "$parent_dir")/$(basename "$target_path")"
    else
      resolved_target="$target_path"
    fi
  fi

  # Check if the resolved path is under PROJECT_ROOT
  case "$resolved_target" in
    "$PROJECT_ROOT"/*) return 0 ;;  # Under project root (includes .worktrees/)
    "$PROJECT_ROOT")   return 0 ;;  # Exactly the project root
    *)
      echo "Error: Path escapes project root — access denied" >&2
      echo "  Path:         $resolved_target" >&2
      echo "  Project root: $PROJECT_ROOT" >&2
      exit 1
      ;;
  esac
}

# Portable exclusive lock (Linux: flock, macOS: mkdir spinlock)
# Usage: call inside a subshell with FD 200 redirect:
#   (_lock "lockfile"; ... ) 200>"lockfile"
# Linux: flock acquires lock on FD 200, auto-releases when subshell exits
# macOS: mkdir creates atomic lock dir, trap EXIT cleans up on subshell exit
_lock() {
  if [ "$_HAS_FLOCK" -eq 1 ]; then
    flock -x 200
  else
    local lockdir="$1.d"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 0.05
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 200 ]; then
        echo "Warning: Breaking stale lock on $1" >&2
        rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir"
        attempts=0
      fi
    done
    trap "rmdir '$lockdir' 2>/dev/null" EXIT
  fi
}

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
  validate_path_in_project "$file"
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

# Write a value to a state file (flock-protected for parallel safety)
write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    echo "$value" > "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Clear a single state file (flock-protected for parallel safety)
clear_state_file() {
  local key="$1"
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    rm -f "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Extract version string from an aimi-cli.sh path
# Given: <config_dir>/plugins/cache/foo/aimi-engineering/1.4.0/scripts/aimi-cli.sh
# Returns: 1.4.0
_extract_version_from_path() {
  local path="$1"
  local no_script="${path%/*}"       # strip /aimi-cli.sh -> .../scripts
  local no_scripts="${no_script%/*}" # strip /scripts -> .../1.4.0
  printf '%s\n' "${no_scripts##*/}"  # strip prefix -> 1.4.0
}

# Resolve the Claude config directory.
# Honors CLAUDE_CONFIG_DIR env var; falls back to ~/.claude.
# When CLAUDE_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_claude_config_dir() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # Validate absolute path when explicitly set
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: CLAUDE_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Validate and resolve AIMI_PLUGIN_DIR when set by compound-plugin converter.
# Returns stripped path on success, empty string when unset; exits 1 on invalid.
_validate_plugin_dir() {
  if [ -z "${AIMI_PLUGIN_DIR:-}" ]; then
    return 0
  fi
  # Must be an absolute path
  if [ "${AIMI_PLUGIN_DIR#/}" = "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR must be an absolute path, got: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Directory must exist
  if [ ! -d "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR directory does not exist: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${AIMI_PLUGIN_DIR%/}"
}

# Return the global cache file path for aimi-cli.sh
_global_cache_path() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-cli-path"
}

# Return the global cache file path for worktree-manager.sh
_global_worktree_cache_path() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-worktree-path"
}

# Atomically write the CLI path to the global cache file
# Usage: write_global_cli_cache "/path/to/aimi-cli.sh"
write_global_cli_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_cache_path)
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# Read and validate the cached CLI path from the global cache file
# Returns the cached path if valid, empty string otherwise
read_global_cli_cache() {
  local cache_file
  cache_file=$(_global_cache_path)
  if [ ! -f "$cache_file" ] || [ ! -r "$cache_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
  # Validate path matches expected pattern
  # Expected: */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh
  # Or: $AIMI_PLUGIN_DIR/scripts/aimi-cli.sh (compound-plugin converter)
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/scripts/aimi-cli.sh)
      if [ -n "$plugin_dir" ]; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Atomically write the worktree manager path to the global cache file
# Usage: write_global_worktree_cache "/path/to/worktree-manager.sh"
write_global_worktree_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# Read and validate the cached worktree manager path from the global cache file
# Returns the cached path if valid, empty string otherwise
read_global_worktree_cache() {
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  if [ ! -f "$cache_file" ] || [ ! -r "$cache_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
  # Validate path matches expected pattern
  # Expected: */plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh
  # Or: $AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh (compound-plugin converter)
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/skills/git-worktree/scripts/worktree-manager.sh)
      if [ -n "$plugin_dir" ]; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Validate story ID format (US-NNN or US-NNNa)
validate_story_id() {
  local story_id="$1"
  if ! [[ "$story_id" =~ ^US-[0-9]{3}[a-z]?$ ]]; then
    echo "Error: Invalid story ID format: $story_id (expected US-NNN)" >&2
    exit 1
  fi
}

# Validate story ID exists in the tasks file
validate_story_exists() {
  local story_id="$1"
  local tasks_file="$2"
  if ! jq -e --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file" > /dev/null 2>&1; then
    echo "Error: Story $story_id not found in $tasks_file" >&2
    exit 1
  fi
}

# Get the tasks file (from state or discover)
get_tasks_file() {
  local tasks_file
  tasks_file=$(read_state "current-tasks")

  if [ -n "$tasks_file" ] && [ ! -f "$tasks_file" ]; then
    local stale_path="$tasks_file"
    tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
    echo "Warning: state file pointed to $stale_path which no longer exists. Using $tasks_file instead." >&2
    write_state "current-tasks" "$tasks_file"
  elif [ -z "$tasks_file" ]; then
    tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    validate_path_in_project "$tasks_file"
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

  resolve_path "$tasks_file"
}

# Find all tasks files sorted by modification time (most recent first)
cmd_find_tasks_all() {
  local files
  files=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null)

  if [ -z "$files" ]; then
    echo "No tasks files found in $TASKS_DIR/" >&2
    exit 1
  fi

  # Output each file as an absolute path, newline-separated
  while IFS= read -r f; do
    resolve_path "$f"
  done <<< "$files"
}

# Initialize execution session
# Usage: aimi-cli.sh init-session [--file <path>]
cmd_init_session() {
  local tasks_file branch pending
  local file_flag=""

  # Parse optional --file flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)
        shift
        file_flag="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
      *)
        echo "Error: Unexpected argument: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$file_flag" ]; then
    # Validate the --file path exists
    if [ ! -f "$file_flag" ]; then
      echo "Error: File not found: $file_flag" >&2
      exit 1
    fi
    # Validate it matches *-tasks.json pattern
    local basename
    basename=$(basename "$file_flag")
    if ! [[ "$basename" == *-tasks.json ]]; then
      echo "Error: File does not match *-tasks.json pattern: $file_flag" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$file_flag")
  else
    tasks_file=$(cmd_find_tasks)
  fi
  write_state "current-tasks" "$tasks_file"

  # Self-resolve: persist this CLI's absolute path for future sessions
  local self_path
  self_path=$(resolve_path "$0")
  write_state "cli-path" "$self_path"
  write_global_cli_cache "$self_path"

  branch=$(jq -r '.metadata.branchName' "$tasks_file")

  # Validate branch name (security)
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  write_state "current-branch" "$branch"

  pending=$(jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file")

  local version
  version=$(jq -r '.schemaVersion' "$tasks_file")

  jq -n --arg tasks "$tasks_file" --arg branch "$branch" --argjson pending "$pending" --arg version "$version" \
    '{tasks: $tasks, branch: $branch, pending: $pending, schemaVersion: $version}'
}

# Get comprehensive status summary
# Flags: --counts-only (return aggregate counts without userStories array)
cmd_status() {
  local counts_only=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --counts-only) counts_only=true; shift ;;
      *) break ;;
    esac
  done

  local tasks_file
  tasks_file=$(get_tasks_file)

  if [ "$counts_only" = true ]; then
    jq '{
      schemaVersion: .schemaVersion,
      title: .metadata.title,
      branch: .metadata.branchName,
      maxConcurrency: ((.metadata.maxConcurrency // 4) | if . <= 0 then 4 else . end),
      pending: [.userStories[] | select(.status == "pending")] | length,
      in_progress: [.userStories[] | select(.status == "in_progress")] | length,
      completed: [.userStories[] | select(.status == "completed")] | length,
      failed: [.userStories[] | select(.status == "failed")] | length,
      skipped: [.userStories[] | select(.status == "skipped")] | length,
      total: .userStories | length
    }' "$tasks_file"
  else
    jq '{
      schemaVersion: .schemaVersion,
      title: .metadata.title,
      branch: .metadata.branchName,
      maxConcurrency: ((.metadata.maxConcurrency // 4) | if . <= 0 then 4 else . end),
      pending: [.userStories[] | select(.status == "pending")] | length,
      in_progress: [.userStories[] | select(.status == "in_progress")] | length,
      completed: [.userStories[] | select(.status == "completed")] | length,
      failed: [.userStories[] | select(.status == "failed")] | length,
      skipped: [.userStories[] | select(.status == "skipped")] | length,
      total: .userStories | length,
      userStories: [.userStories[] | {id, title, status, dependsOn: (.dependsOn // []), priority, notes}]
    }' "$tasks_file"
  fi
}

# Get metadata only
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata | .maxConcurrency = ((.maxConcurrency // 4) | if . <= 0 then 4 else . end)' "$tasks_file"
}

# List stories that are ready to execute
# A story is ready when: status == "pending" AND all dependsOn stories have status "completed" or "skipped"
# Flags: --brief (return only {id, title, priority, dependsOn} per story)
cmd_list_ready() {
  local brief=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) brief=true; shift ;;
      *) break ;;
    esac
  done

  local tasks_file
  tasks_file=$(get_tasks_file)

  local result
  result=$(jq '
    . as $root |
    [
      .userStories[] |
      select(.status == "pending") |
      . as $story |
      # Gate filtering: exclude stories with pending decision gates
      select(
        (.gate.type != "decision") or (.gate.status != "pending")
      ) |
      # Gate filtering: exclude stories where any dependency has a pending action gate
      select(
        (($story.dependsOn // []) | length == 0) or
        (($story.dependsOn // []) | all(. as $dep_id |
          $root.userStories[] | select(.id == $dep_id) |
          ((.gate.type != "action") or (.gate.status != "pending"))
        ))
      ) |
      . as $story |
      (
        ($story.dependsOn // []) | length == 0
      ) or (
        ($story.dependsOn // []) |
        all(. as $dep_id |
          ($root.userStories[] | select(.id == $dep_id) | .status) as $dep_status |
          ($dep_status == "completed" or $dep_status == "skipped")
        )
      )
    | if . then $story else empty end
    ]
  ' "$tasks_file")

  if [ "$brief" = true ]; then
    echo "$result" | jq '[.[] | {id, title, priority, dependsOn, project, gate}]'
  else
    echo "$result"
  fi
}

# Get next pending story
cmd_next_story() {
  local story story_id

  # Use list-ready logic, then pick first by priority
  story=$(cmd_list_ready | jq 'sort_by(.priority) | .[0]')

  if [ "$story" = "null" ] || [ -z "$story" ]; then
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

# Get full story object by ID (read-only)
cmd_get_story() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as in-progress
cmd_mark_in_progress() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-in-progress <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "in_progress"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  write_state "current-story" "$story_id"

  printf '{"id":"%s","status":"in_progress"}\n' "$story_id"
}

# Mark a story as complete
cmd_mark_complete() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "completed"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "success"

  printf '{"id":"%s","status":"completed"}\n' "$story_id"
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

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" --arg notes "$notes" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "failed", notes: $notes}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "failed"

  printf '{"id":"%s","status":"failed","notes":"%s"}\n' "$story_id" "$notes"
}

# Mark a story as skipped
cmd_mark_skipped() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "skipped"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  printf '{"id":"%s","status":"skipped"}\n' "$story_id"
}

# Count pending stories
cmd_count_pending() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file"
}

# Validate dependencies in a tasks file
# Checks for: circular dependencies, missing IDs, self-references
cmd_validate_deps() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local errors
  errors=$(jq '
    . as $root |
    ($root.userStories | map(.id)) as $all_ids |

    # Check self-references
    (
      [
        $root.userStories[] |
        . as $story |
        select(($story.dependsOn // []) | any(. == $story.id)) |
        "Self-reference: \($story.id) depends on itself"
      ]
    ) as $self_refs |

    # Check missing references
    (
      [
        $root.userStories[] |
        . as $story |
        ($story.dependsOn // [])[] |
        . as $dep |
        select(($all_ids | index($dep)) == null) |
        "Missing ID: \($story.id) depends on \($dep) which does not exist"
      ]
    ) as $missing_refs |

    # Check circular dependencies using iterative reachability
    # For each story, walk its dependency graph and check if it reaches itself
    (
      [
        $root.userStories[] |
        . as $start |
        $start.id as $start_id |
        # Build reachability: iterate N times where N = number of stories
        (
          [$start_id] as $initial |
          reduce range($root.userStories | length) as $_ (
            ($start.dependsOn // []);
            . as $current |
            ($current + [
              $root.userStories[] |
              select((.id) as $sid | $current | any(. == $sid)) |
              (.dependsOn // [])[]
            ]) | unique
          )
        ) |
        if any(. == $start_id) then
          "Circular dependency: \($start_id) is part of a dependency cycle"
        else
          empty
        end
      ]
    ) as $cycles |

    ($self_refs + $missing_refs + $cycles) |
    if length == 0 then
      {valid: true, errors: []}
    else
      {valid: false, errors: .}
    end
  ' "$tasks_file")

  echo "$errors"

  # Return non-zero exit code if invalid
  local is_valid
  is_valid=$(echo "$errors" | jq -r '.valid')
  if [ "$is_valid" != "true" ]; then
    return 1
  fi
}

# Validate story content (field lengths, suspicious patterns)
cmd_validate_stories() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  jq '
    .userStories as $stories |
    [
      $stories[] |
      . as $s |
      (
        (if ($s.title | length) > 200 then ["\($s.id): title exceeds 200 chars"] else [] end) +
        (if ($s.description | length) > 500 then ["\($s.id): description exceeds 500 chars"] else [] end) +
        ([$s.acceptanceCriteria[] | select(length > 600)] | if length > 0 then ["\($s.id): acceptance criterion exceeds 600 chars"] else [] end) +
        (if ($s.title | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): title contains suspicious content"] else [] end) +
        (if ($s.description | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): description contains suspicious content"] else [] end) +
        (if ($s.project != null) then
          (if ($s.project | test("^/")) then ["\($s.id): project must not be an absolute path"]
           elif ($s.project | test("\\.\\.")) then ["\($s.id): project must not contain path traversal (..)"]
           elif ($s.project | test("[\\$`;|&]")) then ["\($s.id): project contains shell metacharacters"]
           elif ($s.project | test("^[a-zA-Z0-9_.][a-zA-Z0-9_./@-]*$") | not) then ["\($s.id): project contains invalid characters"]
           else [] end)
         else [] end)
      ) | .[]
    ] |
    if length == 0 then {valid: true, errors: []}
    else {valid: false, errors: .}
    end
  ' "$tasks_file"
}

# Validate all story IDs in the tasks file against the US-NNN format
cmd_validate_ids() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local ids errors=() count=0
  ids=$(jq -r '.userStories[].id' "$tasks_file")

  while IFS= read -r id; do
    [ -z "$id" ] && continue
    count=$((count + 1))
    if ! [[ "$id" =~ ^US-[0-9]{3}[a-z]?$ ]]; then
      errors+=("Invalid story ID: $id (expected US-NNN)")
    fi
  done <<< "$ids"

  if [ ${#errors[@]} -eq 0 ]; then
    jq -n --argjson count "$count" '{valid: true, count: $count}'
    return 0
  else
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
    jq -n --argjson errors "$errors_json" '{valid: false, errors: $errors}'
    return 1
  fi
}

# Cascade skip: given a failed story ID, mark all transitively-dependent stories as skipped
cmd_cascade_skip() {
  local failed_id="$1"
  local tasks_file

  if [ -z "$failed_id" ]; then
    echo "Usage: aimi-cli.sh cascade-skip <story-id>" >&2
    exit 1
  fi

  validate_story_id "$failed_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$failed_id" "$tasks_file"

  # Find all stories that transitively depend on the failed story and mark them as skipped

  # First compute which IDs to skip
  local to_skip
  to_skip=$(jq --arg failed_id "$failed_id" '
    . as $root |
    (
      reduce range($root.userStories | length) as $_ (
        [$failed_id];
        . as $skip_ids |
        ($skip_ids + [
          $root.userStories[] |
          select(
            (.status != "completed") and
            (.status != "skipped") and
            ((.dependsOn // []) | any(. as $d | $skip_ids | any(. == $d)))
          ) |
          .id
        ]) | unique
      )
    ) | map(select(. != $failed_id))
  ' "$tasks_file")

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg failed_id "$failed_id" --argjson to_skip "$to_skip" '
      .userStories |= [
        .[] |
        if (.id as $sid | $to_skip | any(. == $sid)) then
          . + {status: "skipped", notes: ("Skipped: depends on failed story " + $failed_id)}
        else
          .
        end
      ]
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  # Output result
  local count
  count=$(echo "$to_skip" | jq 'length')
  jq -n --argjson skipped "$to_skip" --argjson count "$count" \
    '{skipped: $skipped, count: $count}'
}

# Reset orphaned in_progress stories to failed
cmd_reset_orphaned() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  # Find all in_progress story IDs
  local orphaned
  orphaned=$(jq '[.userStories[] | select(.status == "in_progress") | .id]' "$tasks_file")

  local count
  count=$(echo "$orphaned" | jq 'length')

  if [ "$count" -eq 0 ]; then
    jq -n '{count: 0, reset: []}'
    return
  fi

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq '(.userStories[] | select(.status == "in_progress")) |= . + {status: "failed", notes: "Reset: orphaned from previous session"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq -n --argjson reset "$orphaned" --argjson count "$count" \
    '{count: $count, reset: $reset}'
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

# Detect the repository's default branch
# Primary: git remote show origin (requires network)
# Fallback: git symbolic-ref refs/remotes/origin/HEAD (offline)
# Caches result in .aimi/default-branch for session reuse
cmd_detect_default_branch() {
  local project_dir=""

  # Parse --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
    esac
    shift
  done

  # cd into project dir if specified (supports multi-repo layouts where AIMI root is not a git repo)
  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  # Guard: must be inside a git repository
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi

  # Return cached value if available
  local cached
  cached=$(read_state "default-branch")
  if [ -n "$cached" ]; then
    echo "$cached"
    return 0
  fi

  local branch=""

  # Primary: parse HEAD branch from remote
  branch=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')

  # Fallback: symbolic-ref (works offline)
  if [ -z "$branch" ]; then
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  fi

  if [ -z "$branch" ]; then
    echo "Error: Could not detect default branch" >&2
    exit 1
  fi

  # Cache for session reuse
  write_state "default-branch" "$branch"
  echo "$branch"
}

# Setup branch: deterministic branch creation/checkout logic
# Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--project <path>]
cmd_setup_branch() {
  local branch_name="" default_branch="" project_dir=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--project <path>]" >&2
    exit 1
  fi

  # cd into project dir if specified (supports multi-repo layouts where AIMI root is not a git repo)
  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  # Guard: must be inside a git repository
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi

  # Validate branch name (security)
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch_name" >&2
    exit 1
  fi

  # Validate default branch name (security)
  if ! [[ "$default_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid default branch name: $default_branch" >&2
    exit 1
  fi

  # Get current branch (empty string means detached HEAD)
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")

  # Case 1: Already on target branch
  if [ "$current_branch" = "$branch_name" ]; then
    printf '{"branch":"%s","action":"already-on-branch"}\n' "$branch_name"
    return 0
  fi

  # Case 2: Target branch exists locally
  if git branch --list "$branch_name" | grep -q "$branch_name"; then
    git checkout "$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-local"}\n' "$branch_name"
    return 0
  fi

  # Case 3: Target branch exists on remote only
  if git ls-remote --heads origin "$branch_name" 2>/dev/null | grep -q "$branch_name"; then
    git checkout -b "$branch_name" "origin/$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-remote"}\n' "$branch_name"
    return 0
  fi

  # Case 4/5: Branch is new — decide base
  # Detached HEAD is treated as 'not merged'
  if [ -z "$current_branch" ]; then
    # Detached HEAD — create from current HEAD
    git checkout -b "$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"created-from-current"}\n' "$branch_name"
    return 0
  fi

  # Check if current branch IS the default branch OR is fully merged into default
  if [ "$current_branch" = "$default_branch" ] || \
     git branch --merged "origin/$default_branch" 2>/dev/null | grep -q "^[* ] *${current_branch}$"; then
    git checkout -b "$branch_name" "origin/$default_branch" >/dev/null 2>&1
    printf '{"branch":"%s","action":"created-from-default"}\n' "$branch_name"
    return 0
  fi

  # Current branch has unmerged work — create from current HEAD (stacking intent)
  git checkout -b "$branch_name" >/dev/null 2>&1
  printf '{"branch":"%s","action":"created-from-current"}\n' "$branch_name"
  return 0
}

# Clear all state files (preserves tasks directory)
cmd_clear_state() {
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result" "$AIMI_DIR/cli-path" "$AIMI_DIR/default-branch"
  rm -f "$AIMI_DIR"/.state.lock "$AIMI_DIR"/*.lock 2>/dev/null
  rmdir "$AIMI_DIR"/*.lock.d 2>/dev/null || true
  echo "State cleared."
}

# Check CLI version staleness
# Compares stored cli-path against the glob-resolved latest path
# Flags: --quiet (suppress stderr), --fix (auto-fix stale detection)
cmd_check_version() {
  local quiet=false fix=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=true ;;
      --fix)   fix=true ;;
      *)       break ;;
    esac
    shift
  done

  local stored_path latest_path stored_version latest_version
  local config_dir
  config_dir=$(_claude_config_dir)

  # When AIMI_PLUGIN_DIR is set, the converter manages the lifecycle — skip glob
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ]; then
    printf '{"status":"ok","path":"%s/scripts/aimi-cli.sh","message":"managed by compound-plugin converter"}\n' "$plugin_dir"
    return 0
  fi

  # Resolve the latest installed path via glob
  latest_path=$(ls "$config_dir"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  # Case: glob returns empty — no installed version found
  if [ -z "$latest_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No installed aimi-cli.sh found via glob." >&2
    fi
    jq -n '{status: "unknown", message: "No installed version found"}'
    return 0
  fi

  latest_version=$(_extract_version_from_path "$latest_path")

  # Read stored path from state
  stored_path=$(read_state "cli-path")

  # Case: .aimi/cli-path does not exist — missing is not stale
  if [ -z "$stored_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No stored cli-path found. Run init-session to persist." >&2
    fi
    jq -n --arg ver "$latest_version" --arg path "$latest_path" \
      '{status: "missing", latestVersion: $ver, latestPath: $path}'
    return 0
  fi

  stored_version=$(_extract_version_from_path "$stored_path")

  # Case: stored path matches latest — current
  if [ "$stored_path" = "$latest_path" ]; then
    printf '{"status":"current","version":"%s"}\n' "$stored_version"
    return 0
  fi

  # Case: stored path differs — stale
  if [ "$fix" = true ]; then
    write_state "cli-path" "$latest_path"
    write_global_cli_cache "$latest_path"
    jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
      '{status: "fixed", storedVersion: $sv, latestVersion: $lv}'
    return 0
  fi

  if [ "$quiet" = false ]; then
    echo "Warning: CLI version is stale. Stored: $stored_version, Latest: $latest_version" >&2
  fi
  jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
       --arg sp "$stored_path" --arg lp "$latest_path" \
    '{status: "stale", storedVersion: $sv, latestVersion: $lv, storedPath: $sp, latestPath: $lp}'
  return 1
}

# Remove old cached plugin version directories, keeping only the latest
# Scans <config_dir>/plugins/cache/*/aimi-engineering/*/ for version dirs
# Outputs JSON {"removed":<count>,"kept":"<version>"} to stdout
cmd_cleanup_versions() {
  # When AIMI_PLUGIN_DIR is set, the converter manages the lifecycle — skip cleanup
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ]; then
    printf '{"removed":0,"skipped":true,"message":"converter manages lifecycle"}\n'
    return 0
  fi

  local latest_path latest_version latest_version_dir
  local removed=0
  local config_dir
  config_dir=$(_claude_config_dir)

  # Resolve the latest installed path via glob
  latest_path=$(ls "$config_dir"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  # No installed versions found
  if [ -z "$latest_path" ]; then
    jq -n '{removed: 0, kept: null}'
    return 0
  fi

  latest_version=$(_extract_version_from_path "$latest_path")
  # .../aimi-engineering/1.4.0/scripts/aimi-cli.sh -> .../aimi-engineering/1.4.0
  latest_version_dir=$(dirname "$(dirname "$latest_path")")

  # Iterate all version directories under all marketplace cache entries
  local version_dir
  for version_dir in "$config_dir"/plugins/cache/*/aimi-engineering/*/; do
    # Strip trailing slash for clean comparison
    version_dir="${version_dir%/}"

    # Skip if this is the latest version directory
    if [ "$version_dir" = "$latest_version_dir" ]; then
      continue
    fi

    # Skip if not actually a directory (glob might not expand)
    if [ ! -d "$version_dir" ]; then
      continue
    fi

    # Attempt removal; log warning and continue on failure
    if rm -rf "$version_dir" 2>/dev/null; then
      removed=$((removed + 1))
    else
      echo "Warning: Failed to remove $version_dir" >&2
    fi
  done

  # Update cli-path state to point to the latest version
  write_state "cli-path" "$latest_path"
  write_global_cli_cache "$latest_path"

  jq -n --argjson removed "$removed" --arg kept "$latest_version" \
    '{removed: $removed, kept: $kept}'
}

# Pass a gate on a story
# Usage: gate-pass US-NNN [--option 'value']
cmd_gate_pass() {
  local story_id="$1"
  shift || true
  local option=""

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-pass <story-id> [--option 'value']" >&2
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --option)
        option="${2:-}"
        if [ -z "$option" ]; then
          echo '{"valid":false,"errors":["--option requires a value"]}'
          exit 1
        fi
        shift 2
        ;;
      *)
        echo "{\"valid\":false,\"errors\":[\"Unknown flag: $1\"]}"
        exit 1
        ;;
    esac
  done

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Verify story has a gate field
  local has_gate
  has_gate=$(jq --arg id "$story_id" '[.userStories[] | select(.id == $id) | .gate] | length' "$tasks_file")
  if [ "$has_gate" -eq 0 ] || [ "$(jq --arg id "$story_id" '.userStories[] | select(.id == $id) | .gate' "$tasks_file")" = "null" ]; then
    echo '{"valid":false,"errors":["Story '"$story_id"' has no gate defined"]}'
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    if [ -n "$option" ]; then
      jq --arg id "$story_id" --arg option "$option" \
        '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed", selectedOption: $option}' \
        "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
    else
      jq --arg id "$story_id" \
        '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed"}' \
        "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
    fi
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" '.userStories[] | select(.id == $id) | {id, gate}' "$tasks_file"
}

# Fail a gate on a story
cmd_gate_fail() {
  local story_id="$1"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-fail <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Verify story has a gate field
  local has_gate
  has_gate=$(jq --arg id "$story_id" '[.userStories[] | select(.id == $id) | .gate] | length' "$tasks_file")
  if [ "$has_gate" -eq 0 ] || [ "$(jq --arg id "$story_id" '.userStories[] | select(.id == $id) | .gate' "$tasks_file")" = "null" ]; then
    echo '{"valid":false,"errors":["Story '"$story_id"' has no gate defined"]}'
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id) | .gate) |= . + {status: "failed"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" '.userStories[] | select(.id == $id) | {id, gate}' "$tasks_file"
}

# Update a nested field on a story
# Usage: update-field US-NNN field.path value
# Supports dotted paths like "verification.status"
cmd_update_field() {
  local story_id="$1"
  local field_path="$2"
  local value="$3"

  if [ -z "$story_id" ] || [ -z "$field_path" ] || [ -z "$value" ]; then
    echo "Usage: aimi-cli.sh update-field <story-id> <field.path> <value>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  local tasks_file
  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  # Build jq path from dotted notation (e.g., "verification.status" -> .verification.status)
  local jq_path
  jq_path=$(printf '%s' "$field_path" | sed 's/\./\n/g' | while read -r part; do printf '.%s' "$part"; done)

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg id "$story_id" --arg val "$value" \
      "(.userStories[] | select(.id == \$id) | ${jq_path}) = \$val" \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq --arg id "$story_id" ".userStories[] | select(.id == \$id) | {id, ${field_path%%.*}}" "$tasks_file"
}

# Validate waves: compute waves from dependsOn, compare to stored wave, report mismatches
cmd_validate_waves() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  jq '
    . as $root |
    ($root.userStories | map({(.id): (.dependsOn // [])}) | add // {}) as $deps |
    ($root.userStories | map(.id)) as $all_ids |

    # Compute waves iteratively
    # Wave 0: stories with no dependencies
    # Wave N: stories whose deps are all in waves < N
    (
      reduce range($all_ids | length) as $iteration (
        {};
        . as $assigned |
        ($all_ids | map(select(. as $id | $assigned | has($id) | not))) as $remaining |
        reduce $remaining[] as $id (
          $assigned;
          . as $current |
          if (($deps[$id] // []) | length == 0) then
            $current + {($id): 0}
          elif (($deps[$id] // []) | all(. as $d | $current | has($d))) then
            (($deps[$id] // []) | map($current[.]) | max + 1) as $wave |
            $current + {($id): $wave}
          else
            $current
          end
        )
      )
    ) as $computed |

    # Compare computed waves against stored wave fields
    [
      $root.userStories[] |
      . as $story |
      ($computed[$story.id] // null) as $computed_wave |
      ($story.wave // null) as $stored_wave |
      select(
        ($computed_wave != null and $stored_wave != null and $computed_wave != $stored_wave) or
        ($computed_wave != null and $stored_wave == null)
      ) |
      {
        id: $story.id,
        storedWave: $stored_wave,
        computedWave: $computed_wave
      }
    ] as $mismatches |

    if ($mismatches | length) == 0 then
      {valid: true, errors: []}
    else
      {valid: false, errors: [$mismatches[] | "Wave mismatch: \(.id) stored=\(.storedWave) computed=\(.computedWave)"]}
    end
  ' "$tasks_file"
}

# List task files where all stories have terminal status (completed or skipped)
# Returns a JSON array of file paths
cmd_list_archivable() {
  local result="["
  local first=true

  for tasks_file in "$TASKS_DIR"/*-tasks.json; do
    # Skip if glob didn't expand
    [ -f "$tasks_file" ] || continue

    # Check if ALL stories have terminal status (completed or skipped)
    local non_terminal
    non_terminal=$(jq '[.userStories[] | select(.status != "completed" and .status != "skipped")] | length' "$tasks_file" 2>/dev/null)

    # Skip files that aren't valid JSON or have non-terminal stories
    [ -z "$non_terminal" ] && continue
    [ "$non_terminal" -ne 0 ] && continue

    # Also skip files with zero stories (empty array)
    local total
    total=$(jq '.userStories | length' "$tasks_file" 2>/dev/null)
    [ -z "$total" ] && continue
    [ "$total" -eq 0 ] && continue

    local resolved
    resolved=$(resolve_path "$tasks_file")
    if [ "$first" = true ]; then
      first=false
    else
      result="$result,"
    fi
    result="$result$(printf '"%s"' "$resolved")"
  done

  result="$result]"
  echo "$result"
}

# Archive a task file (and linked brainstorm) to .aimi/archive/
# Usage: archive-task <path>
cmd_archive_task() {
  local task_path="$1"

  if [ -z "$task_path" ]; then
    echo "Usage: aimi-cli.sh archive-task <path>" >&2
    exit 1
  fi

  # Resolve and validate path
  if [ ! -f "$task_path" ]; then
    echo "Error: Task file not found: $task_path" >&2
    exit 1
  fi

  local resolved_task
  resolved_task=$(resolve_path "$task_path")
  validate_path_in_project "$resolved_task"

  # Verify all stories are terminal
  local non_terminal
  non_terminal=$(jq '[.userStories[] | select(.status != "completed" and .status != "skipped")] | length' "$resolved_task" 2>/dev/null)
  if [ -z "$non_terminal" ] || [ "$non_terminal" -ne 0 ]; then
    echo "Error: Task file has non-terminal stories — cannot archive" >&2
    exit 1
  fi

  # Create archive directory
  local archive_dir="$AIMI_DIR/archive"
  mkdir -p "$archive_dir"

  # Helper: move a file to archive with collision handling
  # Usage: _archive_move <source_path>
  # Outputs the destination path
  _archive_move() {
    local src="$1"
    local basename
    basename=$(basename "$src")
    local dest="$archive_dir/$basename"

    if [ ! -e "$dest" ]; then
      mv "$src" "$dest"
      printf '%s' "$dest"
      return
    fi

    # Handle collision: append -N suffix before extension
    local name_no_ext ext
    # Split on first dot for files like foo-tasks.json
    name_no_ext="${basename%%.*}"
    ext="${basename#"$name_no_ext"}"  # includes leading dot(s)

    local n=2
    while true; do
      dest="$archive_dir/${name_no_ext}-${n}${ext}"
      if [ ! -e "$dest" ]; then
        mv "$src" "$dest"
        printf '%s' "$dest"
        return
      fi
      n=$((n + 1))
    done
  }

  # Move the task file
  local archived_task
  archived_task=$(_archive_move "$resolved_task")

  # Move companion .lock file if it exists
  if [ -f "${resolved_task}.lock" ]; then
    _archive_move "${resolved_task}.lock" > /dev/null
  fi

  # Move linked brainstorm if specified in metadata
  local brainstorm_path archived_brainstorm=""
  brainstorm_path=$(jq -r '.metadata.brainstormPath // empty' "$archived_task" 2>/dev/null)

  if [ -n "$brainstorm_path" ]; then
    # Resolve relative to project root
    local resolved_brainstorm
    if [ "${brainstorm_path#/}" = "$brainstorm_path" ]; then
      # Relative path — resolve from project root
      resolved_brainstorm="$PROJECT_ROOT/$brainstorm_path"
    else
      resolved_brainstorm="$brainstorm_path"
    fi

    # Validate brainstorm path stays within project root
    if [ -e "$resolved_brainstorm" ]; then
      validate_path_in_project "$resolved_brainstorm"
      archived_brainstorm=$(_archive_move "$resolved_brainstorm")
    fi
  fi

  # Output result as JSON
  if [ -n "$archived_brainstorm" ]; then
    jq -n --arg task "$archived_task" --arg brainstorm "$archived_brainstorm" \
      '{archived: {task: $task, brainstorm: $brainstorm}}'
  else
    jq -n --arg task "$archived_task" \
      '{archived: {task: $task, brainstorm: null}}'
  fi
}

# Display help
cmd_help() {
  cat << 'EOF'
aimi-cli.sh - Deterministic task file operations for Aimi

USAGE:
    aimi-cli.sh <command> [args]

COMMANDS:
    init-session              Initialize execution session, save state
    find-tasks                Find most recent tasks file
    status [--counts-only]    Get status summary as JSON
                              --counts-only  Return aggregate counts without userStories array
    metadata                  Get metadata only
    next-story                Get next pending story, save to state
    current-story             Get currently active story from state
    list-ready [--brief]      List stories ready to execute (dependency-aware)
                              --brief  Return only {id, title, priority, dependsOn} per story
    mark-in-progress <id>     Mark story as in_progress (returns {id, status} JSON)
    mark-complete <id>        Mark story as completed (returns {id, status} JSON)
    mark-failed <id> [notes]  Mark story as failed (returns {id, status, notes} JSON)
    mark-skipped <id>         Mark story as skipped (returns {id, status} JSON)
    count-pending             Count pending stories
    validate-deps             Validate dependency graph (no cycles, no missing refs)
    validate-stories          Validate story content (length, suspicious patterns)
    validate-ids              Validate all story IDs match US-NNN format
    gate-pass <id> [--option 'value']
                              Pass a gate on a story; optionally store selected option
    gate-fail <id>            Fail a gate on a story
    update-field <id> <field.path> <value>
                              Update a nested field on a story (e.g., verification.status passed)
    validate-waves            Compute waves from dependsOn, compare to stored wave, report mismatches
    cascade-skip <id>         Skip all stories depending on failed story
    reset-orphaned            Reset all in_progress stories to failed
    get-branch                Get branchName from metadata
    get-story <id>            Get full story object by ID (read-only)
    get-state                 Get all state files as JSON
    detect-default-branch [--project <path>]
                              Detect and cache the repository's default branch
    setup-branch <name> --default-branch <branch> [--project <path>]
                              Create or checkout branch with deterministic logic
    clear-state               Clear all state files
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    list-archivable           List task files where all stories are completed/skipped (JSON array)
    archive-task <path>       Move completed task file (and linked brainstorm) to .aimi/archive/
    help                      Show this help message

ENVIRONMENT:
    PROJECT_ROOT              Exported by find_aimi_root(); git repository root path
                              All file operations are validated to stay within this boundary
                              Worktree paths (.worktrees/ inside git root) are allowed

STATE FILES (.aimi/):
    current-tasks             Path to active tasks file
    current-branch            Current working branch name
    current-story             ID of story being executed
    last-result               Result of last execution (success/failed/skipped)
    default-branch            Cached default branch name (e.g., main, master)

ENVIRONMENT:
    CLAUDE_CONFIG_DIR  Override Claude config directory (default: ~/.claude)
                       Must be an absolute path when set.
    AIMI_PLUGIN_DIR    Plugin install directory set by compound-plugin converter;
                       bypasses Claude cache resolution.

EXAMPLES:
    # Resolve CLI path first (honors CLAUDE_CONFIG_DIR)
    CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    AIMI_CLI=$(ls "$CONFIG_DIR"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

    # Initialize a new session
    $AIMI_CLI init-session

    # Get next story to work on (dependency-aware)
    $AIMI_CLI next-story

    # List all ready stories (for parallel execution)
    $AIMI_CLI list-ready

    # Mark story in progress
    $AIMI_CLI mark-in-progress US-001

    # Mark story as complete
    $AIMI_CLI mark-complete US-001

    # Validate dependency graph
    $AIMI_CLI validate-deps

    # Fetch a specific story by ID
    $AIMI_CLI get-story US-003

    # Cascade skip after failure
    $AIMI_CLI cascade-skip US-003

    # Check progress
    $AIMI_CLI status

    # Resume after /clear
    $AIMI_CLI get-state
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  # Skip auto-discovery for help command (works without .aimi/ present)
  case "${1:-help}" in
    help|--help|-h) cmd_help; return ;;
  esac

  find_aimi_root
  check_jq

  case "${1:-help}" in
    init-session)      shift; cmd_init_session "$@" ;;
    find-tasks)        cmd_find_tasks ;;
    find-tasks-all)    cmd_find_tasks_all ;;
    status)            shift; cmd_status "$@" ;;
    metadata)          cmd_metadata ;;
    next-story)        cmd_next_story ;;
    current-story)     cmd_current_story ;;
    list-ready)        shift; cmd_list_ready "$@" ;;
    mark-in-progress)  cmd_mark_in_progress "${2:-}" ;;
    mark-complete)     cmd_mark_complete "${2:-}" ;;
    mark-failed)       cmd_mark_failed "${2:-}" "${3:-}" ;;
    mark-skipped)      cmd_mark_skipped "${2:-}" ;;
    count-pending)     cmd_count_pending ;;
    validate-deps)     cmd_validate_deps ;;
    validate-stories)  cmd_validate_stories ;;
    validate-ids)      cmd_validate_ids ;;
    gate-pass)         shift; cmd_gate_pass "$@" ;;
    gate-fail)         cmd_gate_fail "${2:-}" ;;
    update-field)      cmd_update_field "${2:-}" "${3:-}" "${4:-}" ;;
    validate-waves)    cmd_validate_waves ;;
    cascade-skip)      cmd_cascade_skip "${2:-}" ;;
    reset-orphaned)    cmd_reset_orphaned ;;
    get-branch)        cmd_get_branch ;;
    get-story)         cmd_get_story "${2:-}" ;;
    get-state)         cmd_get_state ;;
    detect-default-branch) shift; cmd_detect_default_branch "$@" ;;
    setup-branch)      shift; cmd_setup_branch "$@" ;;
    clear-state)       cmd_clear_state ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    list-archivable)   cmd_list_archivable ;;
    archive-task)      cmd_archive_task "${2:-}" ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
