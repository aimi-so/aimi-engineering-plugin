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
_HAS_SHA256SUM=$(command -v sha256sum &>/dev/null && echo 1 || echo 0)

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

# Detect if running inside Claude Code (CLAUDECODE=1 is set by Claude Code in every session)
_is_claude_code_host() {
  [ "${CLAUDECODE:-}" = "1" ]
}

# Resolve the Aimi config directory (XDG-compliant, host-agnostic).
# Honors AIMI_CONFIG_DIR env var; falls back to ${XDG_CONFIG_HOME:-$HOME/.config}/aimi.
# When AIMI_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_aimi_config_dir() {
  local dir="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"
  # Validate absolute path when explicitly set
  if [ -n "${AIMI_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: AIMI_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Return the legacy global cache file path for aimi-cli.sh (read-fallback only)
_global_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-cli-path"
}

# Return the legacy global cache file path for worktree-manager.sh (read-fallback only)
_global_worktree_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-worktree-path"
}

# Return the global cache file path for aimi-cli.sh (new XDG location)
_global_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/cli-path"
}

# Return the global cache file path for worktree-manager.sh (new XDG location)
_global_worktree_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/worktree-path"
}

# Atomically write the CLI path to the global cache file
# Usage: write_global_cli_cache "/path/to/aimi-cli.sh"
write_global_cli_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_cli_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_cached_cli_path: run a path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
_validate_cached_cli_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/scripts/aimi-cli.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Read and validate the cached CLI path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_cli_cache() {
  local cache_file
  cache_file=$(_global_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_cli_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_cli_path "$cached_path"
}

# Atomically write the worktree manager path to the global cache file
# Usage: write_global_worktree_cache "/path/to/worktree-manager.sh"
write_global_worktree_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_worktree_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_cached_worktree_path: run a worktree path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
_validate_cached_worktree_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/skills/git-worktree/scripts/worktree-manager.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh)
      printf '%s\n' "$cached_path"
      ;;
  esac
}

# Read and validate the cached worktree manager path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_worktree_cache() {
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_worktree_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_worktree_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_worktree_path "$cached_path"
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
      maxConcurrency: ((.metadata.maxConcurrency // 5) | if . <= 0 then 5 else . end),
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
      maxConcurrency: ((.metadata.maxConcurrency // 5) | if . <= 0 then 5 else . end),
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
  jq '.metadata | .maxConcurrency = ((.maxConcurrency // 5) | if . <= 0 then 5 else . end)' "$tasks_file"
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

# Get story context (story slice + metadata) by ID — for subagent self-brief
cmd_get_story_context() {
  local story_id="$1"
  local tasks_file

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story-context <story-id>" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  tasks_file=$(get_tasks_file)
  validate_story_exists "$story_id" "$tasks_file"

  jq --arg id "$story_id" '{story: (.userStories[] | select(.id == $id)), metadata: .metadata}' "$tasks_file"
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

  local result
  result=$(jq '
    .userStories as $stories |
    [
      $stories[] |
      . as $s |
      (
        (if ($s.title | length) > 200 then ["\($s.id): title exceeds 200 chars"] else [] end) +
        (if ($s.description | length) > 500 then ["\($s.id): description exceeds 500 chars"] else [] end) +
        ([$s.acceptanceCriteria[] | select(length > 5000)] | if length > 0 then ["\($s.id): acceptance criterion exceeds 5000 chars"] else [] end) +
        (if ($s.title | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): title contains suspicious content"] else [] end) +
        (if ($s.description | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): description contains suspicious content"] else [] end) +
        (if ($s.project != null) then
          (if ($s.project | test("^/")) then ["\($s.id): project must not be an absolute path"]
           elif ($s.project | test("\\.\\.")) then ["\($s.id): project must not contain path traversal (..)"]
           elif ($s.project | test("[\\$`;|&]")) then ["\($s.id): project contains shell metacharacters"]
           elif ($s.project | test("^[a-zA-Z0-9_.][a-zA-Z0-9_./@-]*$") | not) then ["\($s.id): project contains invalid characters"]
           else [] end)
         else [] end) +
        (if ($s.skills != null) then
          (if ($s.skills | type) != "array" then ["\($s.id): skills must be an array"]
           else
             (if ($s.skills | length) > 10 then ["\($s.id): skills array exceeds 10 entries"] else [] end) +
             [$s.skills[] | select(test("^[a-zA-Z0-9][a-zA-Z0-9_-]*$") | not) | "\($s.id): skills[" + (. | tostring) + "] contains invalid characters"] +
             [$s.skills[] | select(test("\\.\\.") or test("/") or test("[\\$`;|&]")) | "\($s.id): skills[" + (. | tostring) + "] must not contain path components"] +
             (if ($s.skills | unique | length) != ($s.skills | length) then
               [$s.skills | group_by(.) | .[] | select(length > 1) | .[0] | "\($s.id): skills contains duplicate entry \(.)"]
             else [] end)
           end)
         else [] end) +
        (if ($s.tasks != null) then
          (if ($s.tasks | type) != "array" then ["\($s.id): tasks must be an array"]
           elif ($s.tasks | length) == 0 then ["\($s.id): tasks must be omitted when empty"]
           else
             (if ($s.tasks | length) > 50 then ["\($s.id): tasks array exceeds 50 entries"] else [] end) +
             [$s.tasks[] | select(type != "string") | "\($s.id): tasks[] element must be a string"] +
             [$s.tasks[] | select(type == "string" and length > 5000) | "\($s.id): tasks[] entry exceeds 5000 chars"] +
             [$s.tasks[] | select(type == "string" and test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) | "\($s.id): tasks[] entry contains suspicious content"]
           end)
         else [] end) +
        (if has("gates") then ["\($s.id): gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)"] else [] end) +
        (if ($s.gate != null) then
          (["type","status","prompt"] | map(. as $k | if ($s.gate | has($k) | not) then ["\($s.id): gate: missing required field \($k)"] else [] end) | add // [])
         else [] end) +
        (if ($s.verification != null and ($s.verification | type) == "string") then
          ["\($s.id): verification must be an object {strategy, status, url, expect}; found bare string — run normalize-verification to fix"]
         else [] end)
      ) | .[]
    ] |
    if length == 0 then {valid: true, errors: []}
    else {valid: false, errors: .}
    end
  ' "$tasks_file")
  local jq_exit=$?
  echo "$result"
  [ $jq_exit -ne 0 ] && return $jq_exit
  # Return exit 1 when validation found errors
  if echo "$result" | jq -e '.valid == false' > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Normalize verification fields: rewrite any bare-string verification into object form
cmd_normalize_verification() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-verification <tasks-file-path>" >&2
    exit 1
  fi

  if [ ! -f "$tasks_file" ]; then
    echo "Error: tasks file not found: $tasks_file" >&2
    exit 1
  fi

  if [ ! -r "$tasks_file" ]; then
    echo "Error: tasks file not readable: $tasks_file" >&2
    exit 1
  fi

  # Validate input is valid JSON
  if ! jq empty "$tasks_file" 2>/dev/null; then
    echo "Error: invalid JSON in tasks file: $tasks_file" >&2
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq '
      .userStories |= map(
        if (.verification != null and (.verification | type) == "string") then
          .verification = {strategy: .verification, status: "pending", url: null, expect: null}
        else
          .
        end
      )
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  [ $exit_code -ne 0 ] && exit $exit_code

  # Report how many stories were normalized
  local normalized_count
  normalized_count=$(jq '[.userStories[] | select(.verification != null and (.verification | type) == "object")] | length' "$tasks_file")
  jq -n --argjson count "$normalized_count" '{normalized: $count}'
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

# Detect a Claude Design handoff bundle under a given root (defaults to CWD).
# Scans depth-1 subdirectories for a README.md containing the handoff marker.
# Returns JSON object when found, "null" when not found.
# With --all, returns a JSON array sorted newest-first (by directory mtime).
cmd_detect_design_bundle() {
  local root="" all=false json=false

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) shift; root="${1:-}" ;;
      --all)  all=true ;;
      --json) json=true ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
  done

  # Resolve scan root (default: CWD)
  local scan_root
  if [ -n "$root" ]; then
    # For relative paths, validate they stay within project boundary (prevents ../.. traversal).
    # Absolute paths are allowed as scan roots since this is a read-only operation.
    case "$root" in
      /*) : ;;  # Absolute path — skip boundary check (read-only scan)
      *)  validate_path_in_project "$root" ;;
    esac
    scan_root="$root"
  else
    scan_root="$(pwd)"
  fi

  if [ ! -d "$scan_root" ]; then
    echo "Error: Scan root does not exist: $scan_root" >&2
    exit 1
  fi

  # The handoff marker (fixed string, case-sensitive)
  local HANDOFF_MARKER='This is a **handoff bundle** from Claude Design (claude.ai/design).'

  # Collect matching bundles: each entry is "<mtime> <abspath>"
  local found_paths=()

  # Pre-check: scan_root may itself be a bundle directory. When its README has
  # the handoff marker, treat it as a single bundle and skip the children scan.
  local root_normalized="${scan_root%/}/"
  local root_readme="${root_normalized}README.md"
  if [ -f "$root_readme" ] && grep -qF "$HANDOFF_MARKER" "$root_readme"; then
    local root_mtime
    if command -v stat >/dev/null 2>&1; then
      root_mtime=$(stat -c '%Y' "$root_normalized" 2>/dev/null || stat -f '%m' "$root_normalized" 2>/dev/null || echo 0)
    else
      root_mtime=0
    fi
    found_paths+=("${root_mtime} ${root_normalized}")
  else
    for subdir in "${scan_root}"/*/; do
      [ -d "$subdir" ] || continue

      local base
      base=$(basename "$subdir")

      # Skip noise directories
      case "$base" in
        .worktrees|node_modules|.aimi|vendor) continue ;;
      esac

      local readme="${subdir}README.md"
      [ -f "$readme" ] || continue

      # Fixed-string, case-sensitive marker check
      grep -qF "$HANDOFF_MARKER" "$readme" || continue

      # Get directory mtime (seconds since epoch) — stat is not POSIX-portable;
      # use date-based approach via ls for mtime sorting, falling back to 0
      local mtime
      if command -v stat >/dev/null 2>&1; then
        # GNU stat (Linux) or BSD stat (macOS)
        mtime=$(stat -c '%Y' "$subdir" 2>/dev/null || stat -f '%m' "$subdir" 2>/dev/null || echo 0)
      else
        mtime=0
      fi

      found_paths+=("${mtime} ${subdir}")
    done
  fi

  # No bundles found
  if [ ${#found_paths[@]} -eq 0 ]; then
    echo "null"
    return 0
  fi

  # Sort found_paths by mtime descending (newest first)
  local sorted_paths
  sorted_paths=$(printf '%s\n' "${found_paths[@]}" | sort -rn)

  # Build JSON for a single bundle directory
  _build_bundle_json() {
    local subdir="$1"
    local base
    base=$(basename "$subdir")

    local readme="${subdir}README.md"
    local readme_rel="${base}/README.md"

    # chats[]: <bundle>/chats/*.md
    local chats_arr=()
    for f in "${subdir}chats/"*.md; do
      [ -f "$f" ] && chats_arr+=("${base}/chats/$(basename "$f")")
    done
    local chats_json
    if [ ${#chats_arr[@]} -gt 0 ]; then
      chats_json=$(printf '%s\n' "${chats_arr[@]}" | jq -R . | jq -s .)
    else
      chats_json="[]"
    fi

    # prototypes[]: <bundle>/project/**/*.html (recursive)
    local protos_arr=()
    if [ -d "${subdir}project" ]; then
      while IFS= read -r f; do
        [ -f "$f" ] && protos_arr+=("${base}/project/${f#${subdir}project/}")
      done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
    fi
    local protos_json
    if [ ${#protos_arr[@]} -gt 0 ]; then
      protos_json=$(printf '%s\n' "${protos_arr[@]}" | jq -R . | jq -s .)
    else
      protos_json="[]"
    fi

    # hasReact / hasTailwind: grep heuristics over prototype HTML and adjacent CSS
    local has_react=false has_tailwind=false
    if [ ${#protos_arr[@]} -gt 0 ]; then
      # Search the actual HTML files (absolute paths needed for grep)
      local abs_protos=()
      if [ -d "${subdir}project" ]; then
        while IFS= read -r f; do
          [ -f "$f" ] && abs_protos+=("$f")
        done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
      fi
      if [ ${#abs_protos[@]} -gt 0 ]; then
        if grep -qliF 'react' "${abs_protos[@]}" 2>/dev/null; then
          has_react=true
        fi
        if grep -qliF 'tailwind' "${abs_protos[@]}" 2>/dev/null; then
          has_tailwind=true
        fi
      fi
    fi

    # businessSpec / designSpec: case-insensitive discovery
    # (Claude Design exports occasionally produce camelCase filenames.)
    local business_spec="" design_spec=""
    local business_spec_file design_spec_file
    business_spec_file=$(find "${subdir}project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
    design_spec_file=$(find   "${subdir}project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
    [ -n "$business_spec_file" ] && business_spec="${base}/project/$(basename "$business_spec_file")"
    [ -n "$design_spec_file"   ] && design_spec="${base}/project/$(basename "$design_spec_file")"

    jq -n \
      --arg   path         "$base" \
      --arg   readme       "$readme_rel" \
      --argjson chats       "$chats_json" \
      --argjson prototypes  "$protos_json" \
      --argjson hasReact    "$has_react" \
      --argjson hasTailwind "$has_tailwind" \
      --arg   businessSpec "$business_spec" \
      --arg   designSpec   "$design_spec" \
      '{
        path:         $path,
        readme:       $readme,
        chats:        $chats,
        prototypes:   $prototypes,
        hasReact:     $hasReact,
        hasTailwind:  $hasTailwind,
        businessSpec: (if $businessSpec == "" then null else $businessSpec end),
        designSpec:   (if $designSpec   == "" then null else $designSpec   end)
      }'
  }

  if [ "$all" = true ]; then
    # Return all bundles as a JSON array, sorted newest-first
    local entries_json="[]"
    while IFS= read -r entry; do
      local subdir="${entry#* }"
      local bundle_json
      bundle_json=$(_build_bundle_json "$subdir")
      entries_json=$(echo "$entries_json" | jq --argjson b "$bundle_json" '. + [$b]')
    done <<< "$sorted_paths"
    echo "$entries_json"
  else
    # Return only the newest bundle
    local newest_entry
    newest_entry=$(echo "$sorted_paths" | head -1)
    local newest_subdir="${newest_entry#* }"
    _build_bundle_json "$newest_subdir"
  fi
}

# ============================================================================
# Bundle Prototype Helpers
# ============================================================================

# Compute a SHA-256 hex digest for a single file.
# Uses sha256sum (Linux) or shasum -a 256 (macOS), honoring _HAS_SHA256SUM.
# Usage: _hash_file <path>
# Prints: 64-char hex string
_hash_file() {
  local path="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

# Compute a deterministic composite SHA-256 over an ordered list of file paths.
# Sorts the paths before concatenating so the hash is stable across runs.
# Usage: _compute_composite_hash <file1> [<file2> ...]
# Prints: 64-char hex string
_compute_composite_hash() {
  local sorted_paths
  sorted_paths=$(printf "%s\n" "$@" | sort)
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | shasum -a 256 | awk '{print $1}'
  fi
}

# Compute a deterministic SHA-256 over all regular files in a directory tree.
# Files are sorted by path before concatenation for determinism.
# Usage: _hash_dir <dir>
# Prints: 64-char hex string, or empty string if dir is empty/missing
_hash_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf ""
    return 0
  fi
  local file_list
  file_list=$(find "$dir" -type f | sort)
  if [ -z "$file_list" ]; then
    printf ""
    return 0
  fi
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | shasum -a 256 | awk '{print $1}'
  fi
}

# Extract lines from a markdown file under a given top-level section heading.
# Matches /^## <N>\./ as the section start, reads until the next /^## [0-9]+\./ or EOF.
# Usage: _extract_markdown_section <file> <section_number>
# Prints: section body lines (stripped of the heading itself)
_extract_markdown_section() {
  local file="$1"
  local num="$2"
  awk -v n="$num" '
    /^## [0-9]+\./ {
      if (in_section) { exit }
      if ($0 ~ "^## " n "\\.") { in_section=1; next }
    }
    in_section { print }
  ' "$file"
}

# Parse bullet items from a markdown blob and return a JSON array.
# Each bullet (^- , ^* , or ^N. at the top level) is treated as one view entry.
# The view name is the first phrase up to the first colon, dash, or newline.
# Usage: _extract_view_list <markdown_text> <source_section>
# Prints: JSON array of {name, source_section} objects
_extract_view_list() {
  local text="$1"
  local source_section="$2"
  local json_array="[]"
  local name
  while IFS= read -r line; do
    # Match bullet: leading - , * , or digit followed by .
    case "$line" in
      [-*]\ *|[0-9]*.\ *)
        # Strip bullet prefix
        name="${line#[-*] }"
        name="${name#[0-9]*. }"
        # Trim to first colon or em-dash or plain dash
        name="${name%%:*}"
        name="${name%% -*}"
        name="${name%% —*}"
        # Trim leading/trailing whitespace via awk
        name=$(printf "%s" "$name" | awk '{$1=$1; print}')
        if [ -n "$name" ]; then
          json_array=$(printf "%s" "$json_array" | jq --arg n "$name" --arg s "$source_section" \
            '. + [{"name": $n, "source_section": $s}]')
        fi
        ;;
    esac
  done <<< "$text"
  printf "%s" "$json_array"
}

# Check bundle prototype generation status.
# Usage: aimi-cli.sh bundle-prototype-status --bundle <path> --topic <slug> [--force]
# Returns JSON with keys: needs_generation, view_list, view_source, output_path, sidecar_path
cmd_bundle_prototype_status() {
  local bundle_path="" topic_slug="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle) shift; bundle_path="${1:-}" ;;
      --topic)  shift; topic_slug="${1:-}" ;;
      --force)  force=true ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  if [ -z "$bundle_path" ]; then
    printf "Error: --bundle <path> is required\n" >&2; exit 1
  fi
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi

  # Bundle is a read-only input — allow absolute paths outside the project
  # (same pattern as cmd_detect_design_bundle --root).
  # Only the output paths (sidecar, html) must be within the project.
  if [ ! -d "$bundle_path" ]; then
    printf "Error: Bundle path does not exist or is not a directory: %s\n" "$bundle_path" >&2
    exit 1
  fi

  # Locate spec files inside the bundle (prefer bundle/project/ subdir)
  # Uses case-insensitive discovery so camelCase filenames are detected.
  local design_spec_path="" business_spec_path=""
  local _ds_proj _ds_root _bs_proj _bs_root
  _ds_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _ds_root=$(find "${bundle_path}"         -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _bs_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  _bs_root=$(find "${bundle_path}"         -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  if [ -n "$_ds_proj" ]; then
    design_spec_path="$_ds_proj"
  elif [ -n "$_ds_root" ]; then
    design_spec_path="$_ds_root"
  fi
  if [ -n "$_bs_proj" ]; then
    business_spec_path="$_bs_proj"
  elif [ -n "$_bs_root" ]; then
    business_spec_path="$_bs_root"
  fi

  # Derive output and sidecar paths — relative to the project root for portability.
  # AIMI_DIR is absolute after find_aimi_root(); strip PROJECT_ROOT prefix to get relative form.
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local output_path="${prototypes_dir}/${topic_slug}-bundle.html"
  local sidecar_path="${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate output paths stay within the project
  validate_path_in_project "${PROJECT_ROOT}/${output_path}"
  validate_path_in_project "${PROJECT_ROOT}/${sidecar_path}"

  # Compute current hashes
  local bundle_hash design_spec_hash business_spec_hash
  bundle_hash=$(_hash_dir "$bundle_path")
  if [ -n "$design_spec_path" ]; then
    design_spec_hash=$(_hash_file "$design_spec_path")
  else
    design_spec_hash=""
  fi
  if [ -n "$business_spec_path" ]; then
    business_spec_hash=$(_hash_file "$business_spec_path")
  else
    business_spec_hash=""
  fi

  # Extract view list: prefer DesignSpec § 4, fallback to BusinessSpec § 5 then § 6
  local view_list_json="[]"
  local view_source="none"

  if [ -n "$design_spec_path" ]; then
    local ds4
    ds4=$(_extract_markdown_section "$design_spec_path" "4")
    if [ -n "$ds4" ]; then
      local parsed
      parsed=$(_extract_view_list "$ds4" "designSpec § 4")
      local count
      count=$(printf "%s" "$parsed" | jq 'length')
      if [ "$count" -gt 0 ]; then
        view_list_json="$parsed"
        view_source="designSpec"
      fi
    fi
  fi

  if [ "$view_source" = "none" ] && [ -n "$business_spec_path" ]; then
    local bs5
    bs5=$(_extract_markdown_section "$business_spec_path" "5")
    if [ -n "$bs5" ]; then
      local parsed5
      parsed5=$(_extract_view_list "$bs5" "businessSpec § 5")
      local count5
      count5=$(printf "%s" "$parsed5" | jq 'length')
      if [ "$count5" -gt 0 ]; then
        view_list_json="$parsed5"
        view_source="businessSpec"
      fi
    fi

    if [ "$view_source" = "none" ]; then
      local bs6
      bs6=$(_extract_markdown_section "$business_spec_path" "6")
      if [ -n "$bs6" ]; then
        local parsed6
        parsed6=$(_extract_view_list "$bs6" "businessSpec § 6")
        local count6
        count6=$(printf "%s" "$parsed6" | jq 'length')
        if [ "$count6" -gt 0 ]; then
          view_list_json="$parsed6"
          view_source="businessSpec"
        fi
      fi
    fi
  fi

  # Determine needs_generation
  local needs_generation=false

  # If both specs are absent, view_source is none — no generation possible
  if [ "$view_source" = "none" ] && [ -z "$design_spec_path" ] && [ -z "$business_spec_path" ]; then
    needs_generation=false
  elif [ "$force" = "true" ]; then
    needs_generation=true
  elif [ ! -f "${PROJECT_ROOT}/${sidecar_path}" ]; then
    needs_generation=true
  else
    # Compare hashes from sidecar
    local sidecar_content
    sidecar_content=$(cat "${PROJECT_ROOT}/${sidecar_path}" 2>/dev/null || printf "{}")
    local sc_bundle sc_design sc_business
    sc_bundle=$(printf "%s" "$sidecar_content" | jq -r '.bundleHash // ""')
    sc_design=$(printf "%s" "$sidecar_content" | jq -r '.designSpecHash // ""')
    sc_business=$(printf "%s" "$sidecar_content" | jq -r '.businessSpecHash // ""')
    if [ "$sc_bundle" != "$bundle_hash" ] || \
       [ "$sc_design" != "$design_spec_hash" ] || \
       [ "$sc_business" != "$business_spec_hash" ]; then
      needs_generation=true
    fi
  fi

  jq -n \
    --argjson needs_generation "$needs_generation" \
    --argjson view_list "$view_list_json" \
    --arg view_source "$view_source" \
    --arg output_path "$output_path" \
    --arg sidecar_path "$sidecar_path" \
    '{
      needs_generation: $needs_generation,
      view_list: $view_list,
      view_source: $view_source,
      output_path: $output_path,
      sidecar_path: $sidecar_path
    }'
}

# Write the bundle-prototype sidecar atomically.
# Usage: aimi-cli.sh bundle-prototype-finalize \
#          --topic <slug> \
#          --bundle-hash <hex> \
#          --design-spec-hash <hex> \
#          --business-spec-hash <hex> \
#          --view-list <json-array> \
#          --source-command <brainstorm|plan>
cmd_bundle_prototype_finalize() {
  local topic_slug="" bundle_hash="" design_spec_hash="" business_spec_hash=""
  local view_list_json="" source_command=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --topic)              shift; topic_slug="${1:-}" ;;
      --bundle-hash)        shift; bundle_hash="${1:-}" ;;
      --design-spec-hash)   shift; design_spec_hash="${1:-}" ;;
      --business-spec-hash) shift; business_spec_hash="${1:-}" ;;
      --view-list)          shift; view_list_json="${1:-}" ;;
      --source-command)     shift; source_command="${1:-}" ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  # Validate required args
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi
  if [ -z "$source_command" ]; then
    printf "Error: --source-command <brainstorm|plan> is required\n" >&2; exit 1
  fi
  # Validate source-command value
  if [ "$source_command" != "brainstorm" ] && [ "$source_command" != "plan" ]; then
    printf "Error: --source-command must be exactly 'brainstorm' or 'plan', got: %s\n" "$source_command" >&2
    exit 1
  fi

  # Validate view-list is valid JSON array
  if [ -z "$view_list_json" ]; then
    view_list_json="[]"
  fi
  if ! printf "%s" "$view_list_json" | jq -e '. | arrays' >/dev/null 2>&1; then
    printf "Error: --view-list must be a valid JSON array\n" >&2; exit 1
  fi

  # Compute sidecar path — AIMI_DIR is absolute after find_aimi_root()
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local sidecar_path="${PROJECT_ROOT}/${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate path stays within project
  validate_path_in_project "$sidecar_path"

  # Ensure directory exists
  mkdir -p "$(dirname "$sidecar_path")"

  # Compute generatedAt timestamp
  local generated_at
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  # Build sidecar JSON
  local sidecar_json
  sidecar_json=$(jq -n \
    --arg generatedAt "$generated_at" \
    --arg bundleHash "$bundle_hash" \
    --arg designSpecHash "$design_spec_hash" \
    --arg businessSpecHash "$business_spec_hash" \
    --argjson viewList "$view_list_json" \
    --arg sourceCommand "$source_command" \
    '{
      generatedAt: $generatedAt,
      bundleHash: $bundleHash,
      designSpecHash: $designSpecHash,
      businessSpecHash: $businessSpecHash,
      viewList: $viewList,
      sourceCommand: $sourceCommand
    }')

  # Write atomically: write to tmp then mv
  local tmp_sidecar
  tmp_sidecar=$(mktemp "${sidecar_path}.XXXXXX")
  printf "%s\n" "$sidecar_json" > "$tmp_sidecar"
  chmod 600 "$tmp_sidecar"
  mv "$tmp_sidecar" "$sidecar_path"

  # Output confirmation JSON
  jq -n \
    --arg sidecar_path "$sidecar_path" \
    --arg generatedAt "$generated_at" \
    '{ written: $sidecar_path, generatedAt: $generatedAt }'
}

# Resolve which interactivity mode applies to the current shell.
# Prints exactly one of: picker, agent
#   agent  - AIMI_AGENT_MODE=true or CI=true (explicit overrides), OR no host
#            picker is available and stdin is not a TTY
#   picker - explicit host picker is available (Claude Code or OpenCode), OR
#            stdin is a TTY in a plain terminal
#
# Precedence (first match wins):
#   1. AIMI_AGENT_MODE=true → agent  (explicit opt-out always wins)
#   2. CI=true              → agent
#   3. CLAUDECODE=1         → picker (AskUserQuestion is available)
#   4. OPENCODE_CONFIG_DIR  → picker (OpenCode `question` tool is available)
#   5. stdin is a TTY       → picker
#   6. otherwise            → agent
#
# Hosts 3 and 4 deliberately ignore TTY state: their Bash tools run without a
# controlling terminal, but a host-level picker is fully available.
cmd_detect_interactivity() {
  if [ "${AIMI_AGENT_MODE:-}" = "true" ] || [ "${CI:-}" = "true" ]; then
    echo "agent"
    return
  fi
  if [ "${CLAUDECODE:-}" = "1" ] || [ -n "${OPENCODE_CONFIG_DIR:-}" ]; then
    echo "picker"
    return
  fi
  if [ -t 0 ]; then
    echo "picker"
  else
    echo "agent"
  fi
}

# Setup branch: deterministic branch creation/checkout logic
# Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]
cmd_setup_branch() {
  local branch_name="" default_branch="" project_dir="" base_override=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --base)
        shift
        base_override="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
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

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid base branch name: $base_override" >&2
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

  # Case --base override: Branch is new and caller provided an explicit base
  if [ -n "$base_override" ]; then
    local resolved_base
    if git ls-remote --heads origin "$base_override" 2>/dev/null | grep -q "$base_override"; then
      resolved_base="origin/$base_override"
    elif git branch --list "$base_override" | grep -q "$base_override"; then
      resolved_base="$base_override"
    else
      echo "Error: Base branch does not exist: $base_override" >&2
      exit 1
    fi
    git checkout -b "$branch_name" "$resolved_base" >/dev/null 2>&1
    printf '{"branch":"%s","action":"created-from-base","base":"%s"}\n' "$branch_name" "$base_override"
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

# Print the plugin version from plugin.json
cmd_version() {
  local script_path plugin_json
  script_path="${BASH_SOURCE[0]:-$0}"
  plugin_json="$(cd "$(dirname "$script_path")/.." && pwd)/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo "Error: plugin.json not found" >&2
    exit 1
  fi
  jq -r '.version' "$plugin_json"
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

  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
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
  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
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

# Prime the global CLI path cache explicitly.
# Used by install hooks and slash commands to populate the cache without relying
# on the lazy-resolution layers.
#
# JSON output: {status, path, host, version, message}
#   status: 'ok' | 'already_current' | 'not_found' | 'error'
#   path:   absolute path written (or null)
#   host:   'claude_code' | 'opencode'
#   version: semver extracted from path (or null)
#   message: optional human-readable string
#
# Exit codes: 0 for ok/already_current/not_found, 1 for error
cmd_prime_cache() {
  local host_label
  local resolved_path=""
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)

  # Determine host
  if _is_claude_code_host; then
    host_label="claude_code"
  elif [ -n "$plugin_dir" ]; then
    host_label="opencode"
  else
    # Neither CLAUDECODE=1 nor AIMI_PLUGIN_DIR set — try Claude Code glob anyway
    host_label="claude_code"
  fi

  # ---- Resolve path ----
  if [ "$host_label" = "opencode" ]; then
    # OpenCode branch: AIMI_PLUGIN_DIR is set and CLAUDECODE is unset
    local candidate="$plugin_dir/scripts/aimi-cli.sh"
    if [ ! -x "$candidate" ]; then
      jq -n --arg msg "AIMI_PLUGIN_DIR/scripts/aimi-cli.sh is not executable: $candidate" \
        '{status:"error",path:null,host:"opencode",version:null,message:$msg}'
      return 1
    fi
    # Validate: must be exactly $plugin_dir/scripts/aimi-cli.sh (no traversal)
    if [ "$candidate" != "$plugin_dir/scripts/aimi-cli.sh" ]; then
      jq -n --arg msg "Path rejected: does not match expected OpenCode pattern" \
        '{status:"error",path:null,host:"opencode",version:null,message:$msg}'
      return 1
    fi
    resolved_path="$candidate"
  else
    # Claude Code branch: glob for latest installed path
    local config_dir
    config_dir=$(_claude_config_dir)
    resolved_path=$(bash -c "ls \"$config_dir\"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1")

    if [ -z "$resolved_path" ]; then
      if [ -z "${AIMI_PLUGIN_DIR:-}" ]; then
        jq -n '{status:"not_found",path:null,host:"claude_code",version:null,message:"Plugin not installed. Run /plugin install aimi-engineering first."}'
        return 0
      fi
    fi

    # Validate path matches expected pattern
    case "$resolved_path" in
      */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
        : # valid
        ;;
      *)
        jq -n --arg path "$resolved_path" \
          '{status:"error",path:null,host:"claude_code",version:null,message:"Resolved path rejected: does not match expected cache pattern"}'
        return 1
        ;;
    esac

    # Verify executable
    if [ ! -x "$resolved_path" ]; then
      jq -n --arg path "$resolved_path" \
        '{status:"error",path:null,host:"claude_code",version:null,message:"Resolved path is not executable"}'
      return 1
    fi
  fi

  # ---- Already-current check ----
  local existing_cache
  existing_cache=$(read_global_cli_cache)
  if [ -n "$existing_cache" ] && [ "$existing_cache" = "$resolved_path" ]; then
    local ver
    ver=$(_extract_version_from_path "$resolved_path")
    jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$ver" \
      '{status:"already_current",path:$path,host:$host,version:$ver,message:"Cache already points to this path"}'
    return 0
  fi

  # ---- Write cache ----
  local write_error
  if ! write_error=$(write_global_cli_cache "$resolved_path" 2>&1); then
    jq -n --arg host "$host_label" --arg msg "write_global_cli_cache failed: $write_error" \
      '{status:"error",path:null,host:$host,version:null,message:$msg}'
    return 1
  fi

  local ver
  ver=$(_extract_version_from_path "$resolved_path")
  jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$ver" \
    '{status:"ok",path:$path,host:$host,version:$ver,message:"Cache primed successfully"}'
  return 0
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

# Validate tasks file citation fields
# For schemaVersion >= 3.3: validates DesignSpec verbatim citations for visual stories
# For schemaVersion < 3.3: emits skip-info to stderr and exits 0
# stdout: {valid, errors[]} JSON; exits non-zero when invalid
cmd_validate_tasks() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  local schema_version
  schema_version=$(jq -r '.metadata.schemaVersion // .schemaVersion // "0"' "$tasks_file" 2>/dev/null)

  # Compare versions: below 3.3 → skip with info message
  # Use sort -V to determine version ordering
  if [ "$(printf '%s\n' "$schema_version" "3.3" | sort -V | head -n1)" != "3.3" ]; then
    echo "skipping citation validation (schemaVersion ${schema_version} pre-dates citation enforcement)" >&2
    return 0
  fi

  # Collect errors as a bash array
  local errors=()

  # DesignSpec scan: only when metadata.designBundle.designSpec is non-null
  # AND metadata.prototypePaths is non-empty
  local design_spec_rel
  design_spec_rel=$(jq -r '.metadata.designBundle.designSpec // empty' "$tasks_file" 2>/dev/null)

  local prototype_count
  prototype_count=$(jq '.metadata.prototypePaths | if type == "array" then length else 0 end' "$tasks_file" 2>/dev/null)
  prototype_count="${prototype_count:-0}"

  if [ -n "$design_spec_rel" ] && [ "$prototype_count" -gt 0 ]; then
    # Resolve DesignSpec path relative to PROJECT_ROOT
    local design_spec_path
    design_spec_path="${PROJECT_ROOT}/${design_spec_rel}"

    if [ ! -f "$design_spec_path" ]; then
      errors+=("${tasks_file}: DesignSpec file not found: ${design_spec_rel}")
    else
      # Extract visual stories: id + acceptanceCriteria entries as TSV lines
      # Format: <story_id>\t<ac_index>\t<ac_text>
      local visual_ac_data
      visual_ac_data=$(jq -r '
        .userStories[] |
        select(.verification.strategy == "visual") |
        . as $s |
        .acceptanceCriteria | to_entries[] |
        [$s.id, (.key | tostring), .value] | @tsv
      ' "$tasks_file" 2>/dev/null)

      if [ -n "$visual_ac_data" ]; then
        # Process each AC entry
        while IFS=$'\t' read -r story_id ac_index ac_text; do
          [ -z "$story_id" ] && continue

          # Extract all "literal" (DesignSpec § N.N L<line>) patterns from the AC
          # Pattern: "some literal" (DesignSpec § N.N L<line>)
          # Use grep to find all matches in the ac_text
          local matches
          matches=$(printf '%s' "$ac_text" | grep -oE '"[^"]+" \(DesignSpec § [0-9]+\.[0-9]+ L[0-9]+\)' 2>/dev/null || true)

          [ -z "$matches" ] && continue

          while IFS= read -r match; do
            [ -z "$match" ] && continue

            # Extract the literal string (between double quotes)
            local literal section line_num
            literal=$(printf '%s' "$match" | sed 's/^"\(.*\)" (DesignSpec § .*)$/\1/')
            section=$(printf '%s' "$match" | grep -oE '§ [0-9]+\.[0-9]+' | sed 's/§ //')
            line_num=$(printf '%s' "$match" | grep -oE 'L[0-9]+' | head -1 | sed 's/L//')

            # Locate subsection in DesignSpec and check verbatim presence
            if ! _validate_designspec_citation "$design_spec_path" "$literal" "$section"; then
              errors+=("${tasks_file}: ${story_id} AC[${ac_index}]: missing DesignSpec citation for \"${literal}\" in section § ${section}")
            fi
          done <<< "$matches"
        done <<< "$visual_ac_data"
      fi
    fi
  fi

  # BusinessSpec scan: only when metadata.frontendOnly is true AND metadata.designBundle.businessSpec is non-null
  local frontend_only
  frontend_only=$(jq -r '.metadata.frontendOnly // false' "$tasks_file" 2>/dev/null)

  local business_spec_rel
  business_spec_rel=$(jq -r '.metadata.designBundle.businessSpec // empty' "$tasks_file" 2>/dev/null)

  if [ "$frontend_only" = "true" ] && [ -n "$business_spec_rel" ]; then
    # Resolve BusinessSpec path relative to PROJECT_ROOT
    local business_spec_path
    business_spec_path="${PROJECT_ROOT}/${business_spec_rel}"

    if [ ! -f "$business_spec_path" ]; then
      errors+=("${tasks_file}: BusinessSpec file not found: ${business_spec_rel}")
    else
      # Iterate every endpoints[] entry
      local endpoint_count
      endpoint_count=$(jq '.metadata.backendSpec.endpoints | if type == "array" then length else 0 end' "$tasks_file" 2>/dev/null)
      endpoint_count="${endpoint_count:-0}"

      local ep_index=0
      while [ "$ep_index" -lt "$endpoint_count" ]; do
        # Get source value for this endpoint
        local ep_source
        ep_source=$(jq -r --argjson idx "$ep_index" '.metadata.backendSpec.endpoints[$idx].source // empty' "$tasks_file" 2>/dev/null)

        if [ -z "$ep_source" ]; then
          errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}]: missing source field")
          ep_index=$((ep_index + 1))
          continue
        fi

        # Check if source uses derived: prefix
        if printf '%s' "$ep_source" | grep -q '^derived:'; then
          # Warn to stderr, do not add to errors
          printf '%s: backendSpec.endpoints[%s]: derived source — manual review required\n' \
            "$tasks_file" "$ep_index" >&2
          ep_index=$((ep_index + 1))
          continue
        fi

        # Validate literal source format: "BusinessSpec § N[.N] L<line>"
        if ! printf '%s' "$ep_source" | grep -qE '^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$'; then
          errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}]: malformed source \"${ep_source}\" (expected 'BusinessSpec § N[.N] L<line>' or 'derived: ...')")
          ep_index=$((ep_index + 1))
          continue
        fi

        # Extract section from source
        local ep_section
        ep_section=$(printf '%s' "$ep_source" | grep -oE '§ [0-9]+(\.[0-9]+)?' | sed 's/§ //')

        # Iterate every field in responseShape
        local field_names
        field_names=$(jq -r --argjson idx "$ep_index" \
          '.metadata.backendSpec.endpoints[$idx].responseShape | if type == "object" then keys[] else empty end' \
          "$tasks_file" 2>/dev/null)

        while IFS= read -r field_name; do
          [ -z "$field_name" ] && continue

          # Get per-field source if it exists (responseShape field can be {type, source} or a scalar)
          local field_source
          field_source=$(jq -r --argjson idx "$ep_index" --arg fn "$field_name" \
            '.metadata.backendSpec.endpoints[$idx].responseShape[$fn] | if type == "object" then .source // empty else empty end' \
            "$tasks_file" 2>/dev/null)

          # If field has its own source, validate it too
          if [ -n "$field_source" ]; then
            if printf '%s' "$field_source" | grep -q '^derived:'; then
              printf '%s: backendSpec.endpoints[%s].responseShape.%s: derived source — manual review required\n' \
                "$tasks_file" "$ep_index" "$field_name" >&2
              continue
            fi
            if ! printf '%s' "$field_source" | grep -qE '^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$'; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: malformed source \"${field_source}\"")
              continue
            fi
            # Use the field-level section for subsection lookup
            local field_section
            field_section=$(printf '%s' "$field_source" | grep -oE '§ [0-9]+(\.[0-9]+)?' | sed 's/§ //')
            if ! _validate_businessspec_field "$business_spec_path" "$field_name" "$field_section"; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: field name not found in BusinessSpec § ${field_section}")
            fi
          else
            # No per-field source: check field name against the endpoint-level cited section
            if ! _validate_businessspec_field "$business_spec_path" "$field_name" "$ep_section"; then
              errors+=("${tasks_file}: backendSpec.endpoints[${ep_index}].responseShape.${field_name}: field name not found in BusinessSpec § ${ep_section}")
            fi
          fi
        done <<< "$field_names"

        ep_index=$((ep_index + 1))
      done
    fi
  fi

  # Emit result JSON
  if [ ${#errors[@]} -eq 0 ]; then
    echo '{"valid": true, "errors": []}'
    return 0
  else
    # Build JSON errors array
    local errors_json
    errors_json=$(printf '%s\n' "${errors[@]}" | jq -R . | jq -s .)
    printf '{"valid": false, "errors": %s}\n' "$errors_json"
    return 1
  fi
}

# Helper: validate that a literal string appears verbatim in the cited DesignSpec subsection.
# Subsection boundary: lines from "## N.N <heading>" (or "### N.N") to next heading of equal/higher level.
# Normalizes Unicode quotes, em-dashes, non-breaking spaces, and HTML entities on both sides.
# Usage: _validate_designspec_citation <spec_file> <literal> <section>
# Returns 0 if found, 1 if not found.
_validate_designspec_citation() {
  local spec_file="$1"
  local literal="$2"
  local section="$3"

  # Normalize a string: Unicode quotes → ASCII, em-dash → hyphen,
  # non-breaking space → space, HTML entities to literal chars.
  _normalize_text() {
    local text="$1"
    # Curly double quotes → straight double quote
    text=$(printf '%s' "$text" | sed \
      -e 's/\xe2\x80\x9c/"/g' \
      -e 's/\xe2\x80\x9d/"/g' \
      -e "s/\xe2\x80\x98/'/g" \
      -e "s/\xe2\x80\x99/'/g" \
      -e 's/\xe2\x80\x94/-/g' \
      -e 's/\xc2\xa0/ /g' \
      -e 's/&amp;/\&/g' \
      -e 's/&nbsp;/ /g' \
      -e 's/&lt;/</g' \
      -e 's/&gt;/>/g' \
      -e 's/&quot;/"/g')
    printf '%s' "$text"
  }

  # Determine heading level for section N.N (always "##" — subsection level)
  # Section like "3.1" is a sub-heading; we look for "## 3.1" or "### 3.1" etc.
  # We scan for the section heading and collect lines until the next equal/higher heading.

  local normalized_literal
  normalized_literal=$(_normalize_text "$literal")

  # Extract subsection body from the spec file
  # Strategy: use awk to find the heading containing the section number,
  # then collect lines until a heading of equal or higher level.
  local subsection_body
  subsection_body=$(awk -v section="$section" '
    BEGIN { in_section = 0; heading_level = 0 }
    {
      # Detect markdown headings: count leading # characters
      if (/^#+[[:space:]]/) {
        level = 0
        line_copy = $0
        while (substr(line_copy, 1, 1) == "#") {
          level++
          line_copy = substr(line_copy, 2)
        }
        # Check if this heading contains the section number
        if (!in_section) {
          # Look for pattern like "§ N.N" or "N.N " at start of heading text
          heading_text = substr($0, level + 1)
          # Strip leading spaces
          gsub(/^[[:space:]]+/, "", heading_text)
          if (heading_text ~ ("^(§[[:space:]]*)?" section "([[:space:]]|$)") || \
              heading_text ~ ("§[[:space:]]*" section "([[:space:]]|$)")) {
            in_section = 1
            heading_level = level
            next
          }
        } else {
          # We are in the section — stop at equal or higher level heading
          if (level <= heading_level) {
            exit
          }
        }
      }
      if (in_section) {
        print $0
      }
    }
  ' "$spec_file")

  if [ -z "$subsection_body" ]; then
    # Section not found in spec — treat as missing
    return 1
  fi

  # Normalize the subsection body
  local normalized_body
  normalized_body=$(_normalize_text "$subsection_body")

  # Check if normalized literal is a substring of normalized body
  if printf '%s' "$normalized_body" | grep -qF "$normalized_literal"; then
    return 0
  fi
  return 1
}

# Helper: validate that a field name appears as a literal substring in the cited BusinessSpec subsection.
# Reuses the same subsection-boundary algorithm as _validate_designspec_citation.
# Usage: _validate_businessspec_field <spec_file> <field_name> <section>
# Returns 0 if found, 1 if not found.
_validate_businessspec_field() {
  local spec_file="$1"
  local field_name="$2"
  local section="$3"

  # Extract subsection body from the spec file using the same awk strategy
  local subsection_body
  subsection_body=$(awk -v section="$section" '
    BEGIN { in_section = 0; heading_level = 0 }
    {
      if (/^#+[[:space:]]/) {
        level = 0
        line_copy = $0
        while (substr(line_copy, 1, 1) == "#") {
          level++
          line_copy = substr(line_copy, 2)
        }
        if (!in_section) {
          heading_text = substr($0, level + 1)
          gsub(/^[[:space:]]+/, "", heading_text)
          if (heading_text ~ ("^(§[[:space:]]*)?" section "([[:space:]]|$)") || \
              heading_text ~ ("§[[:space:]]*" section "([[:space:]]|$)")) {
            in_section = 1
            heading_level = level
            next
          }
        } else {
          if (level <= heading_level) {
            exit
          }
        }
      }
      if (in_section) {
        print $0
      }
    }
  ' "$spec_file")

  if [ -z "$subsection_body" ]; then
    return 1
  fi

  # Check if field name appears as a literal substring in the subsection body
  if printf '%s' "$subsection_body" | grep -qF "$field_name"; then
    return 0
  fi
  return 1
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

  # Delete linked research files (ephemeral — rm -f, not archived)
  local research_cleaned=0
  while IFS= read -r rpath; do
    [ -z "$rpath" ] && continue
    local resolved_research
    if [ "${rpath#/}" = "$rpath" ]; then
      # Relative path — resolve from project root
      resolved_research="$PROJECT_ROOT/$rpath"
    else
      resolved_research="$rpath"
    fi
    validate_path_in_project "$resolved_research"
    if [ -e "$resolved_research" ]; then
      rm -f "$resolved_research"
      research_cleaned=$((research_cleaned + 1))
    fi
  done < <(jq -r '.metadata.researchPaths[]? // empty' "$archived_task" 2>/dev/null)

  # Delete linked prototype files (ephemeral — rm -f, not archived)
  local prototype_cleaned=0
  while IFS= read -r ppath; do
    [ -z "$ppath" ] && continue
    local resolved_prototype
    if [ "${ppath#/}" = "$ppath" ]; then
      # Relative path — resolve from project root
      resolved_prototype="$PROJECT_ROOT/$ppath"
    else
      resolved_prototype="$ppath"
    fi
    validate_path_in_project "$resolved_prototype"
    if [ -e "$resolved_prototype" ]; then
      rm -f "$resolved_prototype"
      prototype_cleaned=$((prototype_cleaned + 1))
    fi
  done < <(jq -r '.metadata.prototypePaths[]? // empty' "$archived_task" 2>/dev/null)

  # Output result as JSON
  jq -n --arg task "$archived_task" \
    --arg brainstorm "${archived_brainstorm:-}" \
    --argjson researchCleaned "$research_cleaned" \
    --argjson prototypeCleaned "$prototype_cleaned" \
    '{archived: {task: $task, brainstorm: (if $brainstorm == "" then null else $brainstorm end), researchCleaned: $researchCleaned, prototypeCleaned: $prototypeCleaned}}'
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
    normalize-verification <file>
                              Rewrite any story whose verification is a bare string S
                              into {strategy: S, status: "pending", url: null, expect: null}.
                              Already-object verifications are left unchanged.
                              Writes atomically (tmp + mv). Exits 0 on success.
    validate-ids              Validate all story IDs match US-NNN format
    gate-pass <id> [--option 'value']
                              Pass a gate on a story; optionally store selected option
    gate-fail <id>            Fail a gate on a story
    update-field <id> <field.path> <value>
                              Update a nested field on a story (e.g., verification.status passed)
    validate-waves            Compute waves from dependsOn, compare to stored wave, report mismatches
    validate-tasks            Validate tasks file citation fields (schemaVersion guard, no checks yet)
    cascade-skip <id>         Skip all stories depending on failed story
    reset-orphaned            Reset all in_progress stories to failed
    get-branch                Get branchName from metadata
    get-story <id>            Get full story object by ID (read-only)
    get-story-context <id>    Get story slice + metadata block as JSON (for subagent self-brief)
    get-state                 Get all state files as JSON
    detect-default-branch [--project <path>]
                              Detect and cache the repository's default branch
    detect-interactivity      Print resolved interactivity mode (picker|agent)
                              Reads AIMI_AGENT_MODE, CI, and TTY status; used by
                              commands to branch picker vs. auto-pick-first behavior
    setup-branch <name> --default-branch <branch> [--project <path>]
                              Create or checkout branch with deterministic logic
    clear-state               Clear all state files
    version                   Print the plugin version
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    list-archivable           List task files where all stories are completed/skipped (JSON array)
    archive-task <path>       Move completed task file (and linked brainstorm) to .aimi/archive/
    detect-design-bundle [--root <path>] [--all] [--json]
                              Detect a Claude Design handoff bundle. --root may
                              point at a bundle directory directly, or at a
                              parent dir whose immediate children include bundle
                              dirs (depth-1 scan in that case). Returns JSON
                              {path,readme,chats[],prototypes[],hasReact,
                              hasTailwind,businessSpec,designSpec} or null when
                              no bundle found.
                              --root   Scan <path> (bundle or parent) instead of CWD
                              --all    Return all matching bundles as JSON array
                              --json   Alias; output is always JSON
    bundle-prototype-status --bundle <path> --topic <slug> [--force]
                              Check whether a bundle prototype needs (re-)generation.
                              Returns JSON with keys: needs_generation (bool),
                              view_list (array of {name,source_section}),
                              view_source ('designSpec'|'businessSpec'|'none'),
                              output_path, sidecar_path.
                              view_list is extracted from DesignSpec § 4 first,
                              falling back to BusinessSpec § 5 then § 6.
                              --force  Always set needs_generation to true
    bundle-prototype-finalize --topic <slug> --bundle-hash <hex>
                              --design-spec-hash <hex> --business-spec-hash <hex>
                              --view-list <json> --source-command <brainstorm|plan>
                              Write the bundle-prototype sidecar atomically.
                              Sidecar path: .aimi/brainstorms/prototypes/<slug>-bundle-sidecar.json
                              chmod 600 applied; writes are atomic (tmp + mv).
                              --source-command must be exactly 'brainstorm' or 'plan'.
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

    # Fetch story slice + metadata block (for subagent self-brief)
    $AIMI_CLI get-story-context US-003

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
  # Skip auto-discovery for commands that don't touch .aimi/
  case "${1:-help}" in
    help|--help|-h) cmd_help; return ;;
    version) cmd_version; return ;;
    detect-interactivity) cmd_detect_interactivity; return ;;
    prime-cache) cmd_prime_cache; return ;;
  esac

  # Universal --help/-h: any subcommand with --help or -h anywhere in its args
  # short-circuits to the top-level help doc. Runs before find_aimi_root so
  # help works outside .aimi/ projects, and before any side-effect subcommand
  # mutates state.
  for arg in "$@"; do
    case "$arg" in
      --help|-h) cmd_help; return ;;
    esac
  done

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
    validate-deps)            cmd_validate_deps ;;
    validate-stories)         cmd_validate_stories ;;
    normalize-verification)   cmd_normalize_verification "${2:-}" ;;
    validate-ids)             cmd_validate_ids ;;
    gate-pass)         shift; cmd_gate_pass "$@" ;;
    gate-fail)         cmd_gate_fail "${2:-}" ;;
    update-field)      cmd_update_field "${2:-}" "${3:-}" "${4:-}" ;;
    validate-waves)    cmd_validate_waves ;;
    validate-tasks)    cmd_validate_tasks ;;
    cascade-skip)      cmd_cascade_skip "${2:-}" ;;
    reset-orphaned)    cmd_reset_orphaned ;;
    get-branch)        cmd_get_branch ;;
    get-story)         cmd_get_story "${2:-}" ;;
    get-story-context) cmd_get_story_context "${2:-}" ;;
    get-state)         cmd_get_state ;;
    detect-default-branch) shift; cmd_detect_default_branch "$@" ;;
    setup-branch)      shift; cmd_setup_branch "$@" ;;
    clear-state)       cmd_clear_state ;;
    version)           cmd_version ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    prime-cache)       cmd_prime_cache ;;
    list-archivable)   cmd_list_archivable ;;
    archive-task)      cmd_archive_task "${2:-}" ;;
    detect-design-bundle) shift; cmd_detect_design_bundle "$@" ;;
    bundle-prototype-status)   shift; cmd_bundle_prototype_status "$@" ;;
    bundle-prototype-finalize) shift; cmd_bundle_prototype_finalize "$@" ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
