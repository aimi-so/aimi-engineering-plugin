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

# Return the path to the models config file (XDG location)
_aimi_models_config_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models.json"
}

# Return the path to the models first-run prompt marker file for the active host.
# The marker is per-host: `models-prompt-seen-claudeCode` or `models-prompt-seen-opencode`.
# This lets a user dismiss the prompt independently on each host — picking
# "Keep the default (inherit)" on Claude Code does not silence the prompt on OpenCode.
# The legacy global `models-prompt-seen` file (no host suffix) is no longer read.
_aimi_models_prompt_marker_path() {
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-prompt-seen-$host"
}

# Read the models config JSON, returning empty string when the file is absent.
# Does not validate contents — callers must handle malformed JSON.
read_aimi_models_config() {
  local config_file
  config_file=$(_aimi_models_config_path)
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  cat "$config_file" 2>/dev/null
}

# Atomically write JSON content to the models config file (chmod 0600, mktemp + mv).
# Usage: write_aimi_models_config <json_content>
# Mirrors write_global_cli_cache — interrupted runs never corrupt a pre-existing file.
# chmod is applied BEFORE writing content (create-then-restrict-then-write pattern).
# Temp file is removed on mv failure so no stray files remain.
write_aimi_models_config() {
  local json_content="$1"
  local config_file
  config_file=$(_aimi_models_config_path)
  local config_dir
  config_dir=$(dirname "$config_file")
  if ! mkdir -p "$config_dir" 2>/dev/null; then
    echo "Error: write_aimi_models_config: cannot create directory: $config_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${config_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf '%s\n' "$json_content" > "$tmp_file"
  if ! mv "$tmp_file" "$config_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: write_aimi_models_config: mv failed for $config_file" >&2
    return 1
  fi
}

# Atomically write the CLI path to the global cache file
# Usage: write_global_cli_cache "/path/to/aimi-cli.sh"
# Never persists an ephemeral git-worktree copy: a path under a `.worktrees/`
# segment is invoked from a throwaway checkout (e.g. test-aimi-cli.sh running
# inside a worktree, or an /aimi:execute wave). Caching it globally would point
# every later session at a file that vanishes on worktree cleanup (exit 127).
write_global_cli_cache() {
  local path="$1"
  case "$path" in
    */.worktrees/*)
      # Refuse to cache a worktree-local copy globally; treat as no-op success.
      return 0
      ;;
  esac
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

# Discover tasks files across both the flat layout (.aimi/tasks/*-tasks.json)
# and the nested phase-folder layout (.aimi/tasks/<feature>/phase-N[.M]-<slug>/
# <feature>-phase-N-tasks.json), sorted by modification time with the most
# recent file first. mindepth 1/maxdepth 3 covers flat files (depth 1) and
# nested phase files (feature dir depth 1, phase dir depth 2, tasks file
# depth 3) in one pass. Shared by cmd_find_tasks, cmd_find_tasks_all, and
# get_tasks_file's stale-state fallback so all three see the same combined
# view instead of a flat-only glob. Prints nothing (not an error) when
# TASKS_DIR is missing or empty.
# NUL-delimited find -> xargs -0 keeps paths containing spaces intact. A
# newline-delimited `xargs ls -t` word-splits them, which silently emptied
# discovery for any project whose path contains a space (regression vs the
# pre-phase-layer quoted glob).
_find_tasks_files_all() {
  [ -d "$TASKS_DIR" ] || return 0
  find "$TASKS_DIR" -mindepth 1 -maxdepth 3 -type f -name '*-tasks.json' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null || true
}

# Get the tasks file (from state or discover)
get_tasks_file() {
  local tasks_file
  tasks_file=$(read_state "current-tasks")

  if [ -n "$tasks_file" ] && [ ! -f "$tasks_file" ]; then
    local stale_path="$tasks_file"
    tasks_file=$(_find_tasks_files_all | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
    echo "Warning: state file pointed to $stale_path which no longer exists. Using $tasks_file instead." >&2
    write_state "current-tasks" "$tasks_file"
  elif [ -z "$tasks_file" ]; then
    tasks_file=$(_find_tasks_files_all | head -1)
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

# Find the most recent tasks file (flat or nested phase layout)
cmd_find_tasks() {
  local tasks_file
  tasks_file=$(_find_tasks_files_all | head -1)

  if [ -z "$tasks_file" ]; then
    echo "No tasks file found in $TASKS_DIR/" >&2
    exit 1
  fi

  resolve_path "$tasks_file"
}

# Find all tasks files sorted by modification time (most recent first),
# across both the flat and nested phase layouts.
cmd_find_tasks_all() {
  local files
  files=$(_find_tasks_files_all)

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
      maxConcurrency: ((.metadata.maxConcurrency // 20) | if . <= 0 then 20 else . end),
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
      maxConcurrency: ((.metadata.maxConcurrency // 20) | if . <= 0 then 20 else . end),
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
  jq '.metadata | .maxConcurrency = ((.maxConcurrency // 20) | if . <= 0 then 20 else . end)' "$tasks_file"
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

# Resolve the skills base directory for the current host.
# Returns the absolute path to the skills/ directory, or empty string when unresolvable.
# Claude Code (CLAUDECODE=1): glob ~/.claude/plugins/cache/*/aimi-engineering/*/skills, take first.
# OpenCode (AIMI_PLUGIN_DIR set, CLAUDECODE unset): $AIMI_PLUGIN_DIR/skills.
# Otherwise: empty string — caller emits skills: [] silently.
_resolve_skills_base_dir() {
  if _is_claude_code_host; then
    local config_dir
    config_dir=$(_claude_config_dir)
    local skills_dir
    skills_dir=$(bash -c "ls -d \"$config_dir\"/plugins/cache/*/aimi-engineering/*/skills 2>/dev/null | head -1")
    printf '%s\n' "${skills_dir:-}"
    return 0
  fi
  if [ -n "${AIMI_PLUGIN_DIR:-}" ]; then
    local plugin_dir
    plugin_dir=$(_validate_plugin_dir)
    if [ -n "$plugin_dir" ]; then
      printf '%s\n' "$plugin_dir/skills"
      return 0
    fi
  fi
  printf ''
}

# Get story context (story slice + metadata + skills + designContext) by ID — for subagent self-brief
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

  # ---- Resolve skills ----
  local skills_base_dir
  skills_base_dir=$(_resolve_skills_base_dir)

  # Read skill names declared by this story
  local skill_names_json
  skill_names_json=$(jq -r --arg id "$story_id" \
    '(.userStories[] | select(.id == $id) | .skills // []) | @json' "$tasks_file")

  # Build skills array: name, path, content
  # We accumulate in a bash array of jq --arg entries, then assemble with jq.
  local skill_names_arr
  mapfile -t skill_names_arr < <(echo "$skill_names_json" | jq -r '.[]' 2>/dev/null)

  # Collect valid skill entries and track aggregate char count
  local skill_names_collected=()
  local skill_contents_collected=()
  local skill_aggregate_chars=0

  local skill_name
  for skill_name in "${skill_names_arr[@]+"${skill_names_arr[@]}"}"; do
    local skill_rel_path="skills/${skill_name}/SKILL.md"
    if [ -z "$skills_base_dir" ]; then
      # No resolution — skip silently (aggregate will be empty)
      continue
    fi
    local skill_abs_path="${skills_base_dir}/${skill_name}/SKILL.md"
    if [ ! -f "$skill_abs_path" ]; then
      # OpenCode installs skills under an `aimi-` prefix (install.sh install_skills:
      # dst="$skill_dir/aimi-$skillname"), while stories declare the bare skill
      # name. Claude Code's cache dir is unprefixed, so the bare path already
      # resolved above there. Fall back to the prefixed dir so OpenCode hydration
      # is not silently skipped. Host-agnostic: on Claude Code this fallback path
      # simply does not exist and the warning below still fires for a genuinely
      # missing skill.
      local skill_prefixed_path="${skills_base_dir}/aimi-${skill_name}/SKILL.md"
      if [ -f "$skill_prefixed_path" ]; then
        skill_abs_path="$skill_prefixed_path"
      else
        echo "skill ${skill_name} not found at ${skill_rel_path} — skipped" >&2
        continue
      fi
    fi
    # Read content and apply tag-breakout escapes before jq ingestion
    local skill_content
    skill_content=$(sed \
      -e 's|</required_skills|\&lt;/required_skills|g' \
      -e 's|<required_skills|\&lt;required_skills|g' \
      "$skill_abs_path")
    skill_names_collected+=("$skill_name")
    skill_contents_collected+=("$skill_content")
    (( skill_aggregate_chars += ${#skill_content} ))
  done

  # Apply 100KB aggregate cap: pop in reverse-of-insertion order until aggregate <= 102400
  local cap=102400
  while [ "${skill_aggregate_chars}" -gt "${cap}" ] && [ "${#skill_names_collected[@]}" -gt 0 ]; do
    local last_idx=$(( ${#skill_names_collected[@]} - 1 ))
    local dropped_name="${skill_names_collected[$last_idx]}"
    local dropped_len="${#skill_contents_collected[$last_idx]}"
    echo "skill ${dropped_name} dropped — aggregate skills context exceeded 100KB" >&2
    unset 'skill_names_collected[$last_idx]'
    unset 'skill_contents_collected[$last_idx]'
    skill_names_collected=("${skill_names_collected[@]+"${skill_names_collected[@]}"}")
    skill_contents_collected=("${skill_contents_collected[@]+"${skill_contents_collected[@]}"}")
    (( skill_aggregate_chars -= dropped_len ))
  done

  # Build skills JSON array using jq with null input
  local skills_json='[]'
  local i
  for (( i=0; i<${#skill_names_collected[@]}; i++ )); do
    local sname="${skill_names_collected[$i]}"
    local scontent="${skill_contents_collected[$i]}"
    local spath="skills/${sname}/SKILL.md"
    skills_json=$(jq -n \
      --argjson existing "$skills_json" \
      --arg name "$sname" \
      --arg path "$spath" \
      --arg content "$scontent" \
      '$existing + [{name: $name, path: $path, content: $content}]')
  done

  # ---- Resolve designContext ----
  local brainstorm_path_rel decisions_text=""
  brainstorm_path_rel=$(jq -r --arg id "$story_id" '.metadata.brainstormPath // empty' "$tasks_file")

  if [ -n "$brainstorm_path_rel" ]; then
    # Resolve relative to PROJECT_ROOT (absolute if already absolute)
    local brainstorm_abs
    if [ "${brainstorm_path_rel#/}" = "$brainstorm_path_rel" ]; then
      brainstorm_abs="${PROJECT_ROOT}/${brainstorm_path_rel}"
    else
      brainstorm_abs="$brainstorm_path_rel"
    fi
    if [ -f "$brainstorm_abs" ]; then
      # Extract the ## Design Decisions section: text from that heading up to (but not
      # including) the next ## heading (or end of file).
      decisions_text=$(awk '
        /^## Design Decisions/ { in_section=1; next }
        in_section && /^## / { exit }
        in_section { print }
      ' "$brainstorm_abs" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | \
        awk 'NF || (prev_nf) {print; prev_nf=NF}' | \
        sed '/^$/d' | head -c 65536)
    fi
  fi

  # bundleGuidance
  local bundle_guidance=""
  local design_bundle_json
  design_bundle_json=$(jq -r '.metadata.designBundle // empty' "$tasks_file" 2>/dev/null)
  if [ -n "$design_bundle_json" ]; then
    local bundle_root design_spec business_spec
    bundle_root=$(jq -r '.metadata.designBundle.root // "(none)"' "$tasks_file")
    design_spec=$(jq -r '.metadata.designBundle.designSpec // "(none)"' "$tasks_file")
    business_spec=$(jq -r '.metadata.designBundle.businessSpec // "(none)"' "$tasks_file")
    bundle_guidance="Apply design bundle fidelity rules. Read the spec files cited below using the Read tool before authoring implementation code.

Bundle root: ${bundle_root}
DesignSpec: ${design_spec}
BusinessSpec: ${business_spec}"
  fi

  # ---- Emit final JSON ----
  jq -n \
    --arg id "$story_id" \
    --argjson skills "$skills_json" \
    --arg decisions "$decisions_text" \
    --arg bundleGuidance "$bundle_guidance" \
    --slurpfile tf "$tasks_file" \
    '{
      story: ($tf[0].userStories[] | select(.id == $id)),
      metadata: $tf[0].metadata,
      skills: $skills,
      designContext: {
        decisions: $decisions,
        bundleGuidance: $bundleGuidance
      }
    }'
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

# Persist a --container/--inline override onto metadata.execution.
# execute.md and next.md call this after resolving a session-level override so
# a later re-invocation without the flag continues in the same mode instead of
# silently falling back to the file's original value. Refuses (non-zero exit)
# on a phase-scoped tasks file (metadata.phase present) — a claimed phase
# always runs inside its own phase container, so writing metadata.execution
# there would be the exact dead-data bug this subcommand exists to fix.
cmd_set_execution_mode() {
  local mode="$1"
  local tasks_file

  if [ -z "$mode" ]; then
    echo "Usage: aimi-cli.sh set-execution-mode <container|inline>" >&2
    exit 1
  fi

  if [ "$mode" != "container" ] && [ "$mode" != "inline" ]; then
    echo "Error: Invalid execution mode: $mode (expected container or inline)" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  local has_phase
  has_phase=$(jq -r 'if (.metadata.phase // null) != null then "true" else "false" end' "$tasks_file")
  if [ "$has_phase" = "true" ]; then
    echo "Error: Cannot set metadata.execution on a phase-scoped tasks file (metadata.phase is present): $tasks_file" >&2
    exit 1
  fi

  # Atomic update using flock and unique temp file
  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg mode "$mode" \
      '.metadata.execution = $mode' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  # Cleanup temp file on failure
  rm -f "$tmp_file" 2>/dev/null

  printf '{"execution":"%s"}\n' "$mode"
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
        (if ($s.title | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\("; "i")) then ["\($s.id): title contains suspicious content"] else [] end) +
        (if ($s.description | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\("; "i")) then ["\($s.id): description contains suspicious content"] else [] end) +
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
             [$s.tasks[] | select(type == "string" and test("ignore previous|system:|INSTRUCTIONS|```|\\$\\("; "i")) | "\($s.id): tasks[] entry contains suspicious content"]
           end)
         else [] end) +
        (if has("gates") then ["\($s.id): gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)"] else [] end) +
        (if ($s.gate != null) then
          (["type","status","prompt"] | map(. as $k | if ($s.gate | has($k) | not) then ["\($s.id): gate: missing required field \($k)"] else [] end) | add // [])
         else [] end) +
        (if ($s.verification != null and ($s.verification | type) == "string") then
          ["\($s.id): verification must be an object {strategy, status, url, expect}; found bare string — run normalize-verification to fix"]
         else [] end) +
        (if (has("status") | not) then
          ["\($s.id): missing required field: status — run normalize-status to fix"]
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

# Normalize status fields: default any story missing the status field to "pending"
cmd_normalize_status() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-status <tasks-file-path>" >&2
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
      .userStories |= map(.status //= "pending")
    ' "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  [ $exit_code -ne 0 ] && exit $exit_code

  # Report how many stories were healed (now have status field)
  local healed_count
  healed_count=$(jq '[.userStories[] | select(has("status"))] | length' "$tasks_file")
  jq -n --argjson count "$healed_count" '{normalized: $count}'
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

# Derive a filesystem-safe cache-key suffix for a repository toplevel path,
# so _resolve_default_branch's cache is scoped per repository instead of a
# single shared file under AIMI_ROOT/.aimi/ (which silently leaked one
# repo's resolved branch into every sibling --project call). Mirrors the
# sha256sum/shasum branch shape of _hash_file (aimi-cli.sh:2035-2042) but
# adds an explicit `command -v shasum` probe that helper lacks, and falls
# back to a portable non-sha256 slugification when neither hashing tool is
# available -- the slugification never introduces a `/`, so the returned
# suffix is always safe to use as a flat filename directly inside .aimi/.
# Usage: _default_branch_cache_key <repo-toplevel-path>
# Prints: a filesystem-safe string containing no `/`
_default_branch_cache_key() {
  local toplevel="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    printf '%s' "$toplevel" | sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    printf '%s' "$toplevel" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$toplevel" | tr -c 'A-Za-z0-9' '-'
  fi
}

# Shared default-branch resolution logic: cache read, primary git remote
# show origin parse, offline symbolic-ref fallback, cache write. Assumes the
# caller has already cd'd into the target repo and verified it is a git
# repository (both cmd_detect_default_branch and cmd_detect_parent_branch
# do this themselves before calling here). The cache is keyed per repository
# toplevel (default-branch-<hash>) rather than a single shared
# "default-branch" file, so a sibling repo's --project call cannot inherit
# another repo's cached branch. Returns the branch name on stdout; exits 1
# on total failure.
_resolve_default_branch() {
  local repo_toplevel cache_key
  repo_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || repo_toplevel=""
  cache_key="default-branch-$(_default_branch_cache_key "$repo_toplevel")"

  # Return cached value if available
  local cached
  cached=$(read_state "$cache_key")
  if [ -n "$cached" ]; then
    echo "$cached"
    return 0
  fi

  local branch=""

  # Primary: parse HEAD branch from remote
  branch=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p') || branch=""

  # Fallback: symbolic-ref (works offline)
  if [ -z "$branch" ]; then
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || branch=""
  fi

  if [ -z "$branch" ]; then
    echo "Error: Could not detect default branch" >&2
    exit 1
  fi

  # Cache for session reuse
  write_state "$cache_key" "$branch"
  echo "$branch"
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

  _resolve_default_branch
}

# ============================================================================
# Forge Detection (detect-forge)
# ============================================================================
# FOUNDATIONAL CONTRACT for every forge-* verb in this phase: the output
# shape {forge, host, remote, remoteUrl, source} is consumed verbatim
# downstream and must not be re-derived. See cmd_help's detect-forge entry
# and this story's acceptance criteria for the full contract.

# Parse a git remote URL's hostname: lowercased, no port, no userinfo, no
# path. Handles three shapes: an explicit ssh://[user[:pass]@]host[:port]/path
# or https://[user[:pass]@]host[:port]/path (strip scheme, then strip
# userinfo up to the LAST "@" within the authority only -- never inside the
# path -- then split a trailing :<digits> port off the authority), and git's
# scp-like [user@]host:path form (no "://" present -- the substring up to the
# FIRST ":" is the host, everything after it is PATH, never a port; this is
# the exact ambiguity an alternate-port ssh://...:2222/... URL must not
# collide with). Prints empty on an unparseable string.
_detect_forge_parse_host() {
  local url host authority rest
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  host=""

  if [[ "$url" == *"://"* ]]; then
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$authority" == *"@"* ]]; then
      authority="${authority##*@}"
    fi
    if [[ "$authority" =~ ^(.+):([0-9]+)$ ]]; then
      host="${BASH_REMATCH[1]}"
    else
      host="$authority"
    fi
  elif [[ "$url" == *":"* ]]; then
    rest="$url"
    if [[ "$rest" == *"@"* ]]; then
      rest="${rest##*@}"
    fi
    host="${rest%%:*}"
  fi

  printf '%s' "$host"
}

# Exact-or-subdomain classification of a lowercase hostname against the fixed
# known-forge host list, first match wins: github.com -> github; gitlab.com
# -> gitlab; gitea.com, codeberg.org -> gitea. Gitea's own SaaS host and
# codeberg.org (the largest public Forgejo instance) are both recognized
# under the single "gitea" adapter, since Forgejo is a compatibility-
# preserving fork of Gitea and the two are deliberately NOT distinguished
# anywhere in this contract. Any other host -- including a GitHub Enterprise
# Server host on a company-owned domain -- prints "unknown"; never guesses.
_detect_forge_classify_host() {
  local host="$1"
  case "$host" in
    github.com|*.github.com) printf 'github' ;;
    gitlab.com|*.gitlab.com) printf 'gitlab' ;;
    gitea.com|*.gitea.com|codeberg.org|*.codeberg.org) printf 'gitea' ;;
    *) printf 'unknown' ;;
  esac
}

# Implements the remote-precedence rule using only local reads -- `git
# remote` to list configured remote names, `git remote get-url <name>` to
# read a URL -- never `git remote show`, which dials the remote over the
# network (the same lesson _resolve_default_branch already paid for; see its
# "requires network" comment above). Precedence: an `origin` remote always
# wins outright, even when it disagrees with every other configured remote;
# else exactly one remote (any name) wins; else zero remotes is a distinct
# outcome ("no-remote") from two-or-more disagreeing remotes ("ambiguous-
# remotes", forge always unknown) -- never resolved by picking `git remote`'s
# listing order. Emits {remote, remoteUrl, source} via jq -nc.
_detect_forge_select_remote() {
  local remotes remote_count remote_name="" remote_url="" source=""
  remotes=$(git remote 2>/dev/null) || remotes=""

  if [ -n "$remotes" ] && printf '%s\n' "$remotes" | grep -qx "origin"; then
    remote_name="origin"
    remote_url=$(git remote get-url origin 2>/dev/null) || remote_url=""
    source="remote"
  else
    remote_count=0
    if [ -n "$remotes" ]; then
      remote_count=$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')
    fi
    if [ "$remote_count" -eq 0 ]; then
      source="no-remote"
    elif [ "$remote_count" -eq 1 ]; then
      remote_name="$remotes"
      remote_url=$(git remote get-url "$remote_name" 2>/dev/null) || remote_url=""
      source="remote"
    else
      source="ambiguous-remotes"
    fi
  fi

  jq -nc \
    --arg remote "$remote_name" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Strips embedded userinfo credentials (user:pass@ or user@) from an http(s)
# remote URL's authority before it is echoed back in detect-forge's JSON
# output -- a secret must never round-trip through CLI stdout/logs. No-op on
# any other scheme (in particular ssh://, whose leading "user@" is a literal
# SSH login user such as "git@", never a credential -- the same reason git's
# scp-like [user@]host:path form is left untouched below) and on a URL
# carrying no userinfo at all.
_detect_forge_redact_userinfo() {
  local url="$1" scheme rest authority path
  if [[ "$url" != *"://"* ]]; then
    printf '%s' "$url"
    return 0
  fi

  scheme="${url%%://*}"
  case "$scheme" in
    http|https) ;;
    *)
      printf '%s' "$url"
      return 0
      ;;
  esac

  rest="${url#*://}"
  if [[ "$rest" == *"/"* ]]; then
    authority="${rest%%/*}"
    path="/${rest#*/}"
  else
    authority="$rest"
    path=""
  fi

  if [[ "$authority" == *"@"* ]]; then
    authority="${authority##*@}"
  fi

  printf '%s://%s%s' "$scheme" "$authority" "$path"
}

# Composes the final {forge, host, remote, remoteUrl, source} object.
# AIMI_FORGE_TYPE (already validated by the caller, cmd_detect_forge) short-
# circuits before any git command runs at all when set and non-empty --
# source=override, host/remote/remoteUrl all null. Otherwise selects a
# remote per _detect_forge_select_remote; only when that selection actually
# chose a URL (source=="remote") does it classify the host and redact
# embedded userinfo before echoing the URL back. detect-forge is per-
# repository and is NEVER cached via read_state/write_state -- a multi-repo
# AIMI_ROOT can legitimately mix a GitHub repo and a self-hosted GitLab repo
# under sibling --project calls, and any cache would go stale the moment a
# remote is repointed.
_detect_forge() {
  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    jq -nc --arg forge "$AIMI_FORGE_TYPE" \
      '{forge: $forge, host: null, remote: null, remoteUrl: null, source: "override"}'
    return 0
  fi

  local selection remote remote_url source forge="unknown" host=""
  selection=$(_detect_forge_select_remote)
  remote=$(printf '%s' "$selection" | jq -r '.remote // ""')
  remote_url=$(printf '%s' "$selection" | jq -r '.remoteUrl // ""')
  source=$(printf '%s' "$selection" | jq -r '.source')

  if [ "$source" = "remote" ] && [ -n "$remote_url" ]; then
    host=$(_detect_forge_parse_host "$remote_url")
    forge=$(_detect_forge_classify_host "$host")
    remote_url=$(_detect_forge_redact_userinfo "$remote_url")
  fi

  jq -nc \
    --arg forge "$forge" \
    --arg host "$host" \
    --arg remote "$remote" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{forge: $forge,
      host: (if $host == "" then null else $host end),
      remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Detect the forge (github|gitlab|gitea|unknown) for the active git remote.
# AIMI_FORGE_TYPE overrides detection entirely and must be one of
# github|gitlab|gitea, validated here -- before _detect_forge ever runs --
# so an invalid value never reaches a git command. Never cached (see
# _detect_forge's header comment: per-repository, per-invocation).
cmd_detect_forge() {
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

  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    case "$AIMI_FORGE_TYPE" in
      github|gitlab|gitea) ;;
      *)
        echo "Error: detect-forge: unrecognized AIMI_FORGE_TYPE value: $AIMI_FORGE_TYPE (expected one of: github, gitlab, gitea)" >&2
        exit 1
        ;;
    esac
  fi

  _detect_forge
}

# Normalize a single %D decoration token for parent-branch detection.
# Pipeline: (1) strip an "X -> Y" arrow decoration, keeping the right-hand
# side (covers "HEAD -> <branch>" and, defensively, "origin/HEAD ->
# origin/<branch>"); (2) drop a bare HEAD token; (3) drop a tag: -prefixed
# token; (4) strip a leading origin/ remote-tracking prefix; (5) re-check
# for a bare HEAD token now that origin/ has been stripped (catches
# "origin/HEAD" -> "HEAD"); (6) drop the token if it is now empty or equals
# the branch being examined exactly -- exact match only, never a substring
# match (this is the DEFECT 3 fix for the old grep -v "$CURRENT_BRANCH").
# Prints the surviving token, or nothing when the token was dropped.
_normalize_decoration_token() {
  local token="$1" branch="$2"

  # (1) Arrow decoration: keep the right-hand side.
  if [[ "$token" == *" -> "* ]]; then
    token="${token#*" -> "}"
  fi

  # (2) Bare HEAD (detached-HEAD marker, or the left side of an
  #     already-stripped arrow that somehow left just HEAD).
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (3) Tag refs are never a parent-branch candidate.
  if [[ "$token" == "tag: "* ]]; then
    return 0
  fi

  # (4) Strip the remote-tracking prefix.
  if [[ "$token" == "origin/"* ]]; then
    token="${token#origin/}"
  fi

  # (5) Re-check for HEAD now that origin/ has been stripped.
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (6) Exact-match-only drop: empty token, or the token IS the branch
  #     we're examining (its own tip decoration). Never a substring check.
  if [ -z "$token" ] || [ "$token" = "$branch" ]; then
    return 0
  fi

  printf '%s' "$token"
}

# Walk branch's --first-parent decoration history (git log --pretty=format:'%D')
# token-by-token, nearest ancestor first, and return the first surviving
# candidate parent-branch name after _normalize_decoration_token. Prints
# nothing when no candidate survives across the whole history.
_detect_parent_branch_candidate() {
  local branch="$1"
  local log_output
  log_output=$(git log "$branch" --pretty=format:'%D' --first-parent 2>/dev/null) || true

  local line raw_token normalized candidate=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local -a tokens
    local old_ifs="$IFS"
    IFS=','
    read -ra tokens <<< "$line"
    IFS="$old_ifs"

    for raw_token in "${tokens[@]}"; do
      # Decoration tokens are separated by ", " -- trim the leading space.
      raw_token="${raw_token# }"
      normalized=$(_normalize_decoration_token "$raw_token" "$branch")
      if [ -n "$normalized" ]; then
        candidate="$normalized"
        break 2
      fi
    done
  done <<< "$log_output"

  printf '%s' "$candidate"
}

# Verify a decoration candidate is a genuine ancestor of branch via
# git merge-base, rejecting a divergent sibling whose ref happens to share
# the candidate's (post-normalization) name. Resolves the candidate against
# a local branch first, falling back to an origin-prefixed remote-tracking
# ref only when no local branch of that name exists.
_verify_parent_candidate() {
  local branch="$1" candidate="$2"
  local candidate_ref candidate_commit branch_commit merge_base

  if candidate_commit=$(git rev-parse --verify "${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="$candidate"
  elif candidate_commit=$(git rev-parse --verify "origin/${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="origin/${candidate}"
  else
    return 1
  fi

  branch_commit=$(git rev-parse --verify "${branch}^{commit}" 2>/dev/null) || return 1

  # The candidate must not be the branch's own tip commit.
  if [ "$candidate_commit" = "$branch_commit" ]; then
    return 1
  fi

  # The candidate must be a genuine ancestor of branch (its own commit is
  # the merge base), not a divergent sibling.
  merge_base=$(git merge-base "$branch" "$candidate_ref" 2>/dev/null) || return 1

  [ "$merge_base" = "$candidate_commit" ]
}

# Detect a branch's parent (base) branch by parsing its --first-parent git
# log decorations token-by-token (replacing the old grep -v line-filtering
# pipeline in commands/open-pr.md, which mishandled "HEAD -> <parent>" and
# substring-alike branch names) and confirming the candidate with
# git merge-base. Falls back to the repository's default branch (unverified)
# when no decoration candidate survives normalization or merge-base
# verification.
# Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]
# Output: {"branch":<input>,"base":<resolved>,"verified":<bool>,"source":"decoration"|"default-branch"}
cmd_detect_parent_branch() {
  local branch="" project_dir=""

  # Parse positional branch arg + --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        if [ -z "$branch" ]; then
          branch="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$branch" ]; then
    echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
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

  # Validate branch name (security) — before any git command uses it
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  local raw_candidate
  raw_candidate=$(_detect_parent_branch_candidate "$branch")

  local base="" verified="false" source="default-branch"

  if [ -n "$raw_candidate" ] && _verify_parent_candidate "$branch" "$raw_candidate"; then
    base="$raw_candidate"
    verified="true"
    source="decoration"
  else
    base=$(_resolve_default_branch)
  fi

  jq -nc \
    --arg branch "$branch" \
    --arg base "$base" \
    --argjson verified "$verified" \
    --arg source "$source" \
    '{branch: $branch, base: $base, verified: $verified, source: $source}'
}

# ============================================================================
# Forge Contract — shared builders and degradation helper (US-002)
# ============================================================================
# This section delivers two artifacts this phase's roadmap declares under
# creates[], each named here verbatim on its own line so a text search finds
# the identity intact rather than split across a wrapped comment:
#
# normalized PR and issue field contract
#
# forge degradation contract (missing adapter or missing CLI prints a manual instruction)
#
# Full documentation, including the state-mapping table, capability-gated
# field tables, the review/approval envelope rationale, the three-way status
# convention, and the credential/identity model, lives in
# commands/references/forge-contract.md — this section implements exactly
# what that document specifies, nothing more.
#
# forge-contract.md is the SINGLE ARBITER of the vocabulary below. No later
# forge-* verb may introduce a variant field-name casing (e.g. camelCase
# unsupportedFields) or a second degradation signal (e.g. a degradedReason
# field alongside status) — see that file's opening section for the full
# statement.
#
# This section introduces NO gh/glab/tea invocation, no git-remote parsing,
# and no forge-pr-view/forge-auth-status/forge-repo-info verb body. Those
# belong to later stories in this phase, which call the functions below
# rather than re-deriving the shapes they build.

# Shared jq -nc builder for the normalized PR object (forge-contract.md
# "Normalized PR Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state, --head-ref-name, --base-ref-name) are always
# accepted and null when empty. Capability-gated fields (--files, a JSON
# array; --is-draft, JSON true/false; --mergeable, a raw string — never
# forced to boolean, since GitLab's detailed_merge_status is a 16-value
# enum) are tracked by FLAG PRESENCE, not by value: omitting the flag is
# what marks a field unsupported, regardless of what value would otherwise
# have been passed. Every omitted capability-gated field comes back null
# AND its name is appended to unsupported_fields — never a bare, unmarked
# null. --raw carries the untouched forge-native object alongside the
# normalized shape (JSON object/array/literal, defaults to null).
_forge_build_pr_json() {
  local number="" url="" title="" body="" state="" head_ref="" base_ref=""
  local files_json="null" is_draft_json="null" mergeable="" raw="null"
  local files_set=false is_draft_set=false mergeable_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)         shift; number="${1:-}" ;;
      --url)            shift; url="${1:-}" ;;
      --title)          shift; title="${1:-}" ;;
      --body)           shift; body="${1:-}" ;;
      --state)          shift; state="${1:-}" ;;
      --head-ref-name)  shift; head_ref="${1:-}" ;;
      --base-ref-name)  shift; base_ref="${1:-}" ;;
      --files)          shift; files_json="${1:-null}"; files_set=true ;;
      --is-draft)       shift; is_draft_json="${1:-null}"; is_draft_set=true ;;
      --mergeable)      shift; mergeable="${1:-}"; mergeable_set=true ;;
      --raw)            shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_pr_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$files_set" = true ]     || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["files"]')
  [ "$is_draft_set" = true ]  || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["isDraft"]')
  [ "$mergeable_set" = true ] || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["mergeable"]')

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --arg headRefName "$head_ref" \
    --arg baseRefName "$base_ref" \
    --argjson files "$files_json" \
    --argjson isDraft "$is_draft_json" \
    --arg mergeable "$mergeable" \
    --argjson mergeableSet "$mergeable_set" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      headRefName: (if $headRefName == "" then null else $headRefName end),
      baseRefName: (if $baseRefName == "" then null else $baseRefName end),
      files: $files,
      isDraft: $isDraft,
      mergeable: (if $mergeableSet and ($mergeable != "") then $mergeable else null end),
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared jq -nc builder for the normalized issue object (forge-contract.md
# "Normalized Issue Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state) are always accepted and null when empty. The
# one capability-gated field (--comments, a JSON int) is tracked by flag
# presence exactly like _forge_build_pr_json's capability-gated fields.
# --raw carries the untouched forge-native object (defaults to null).
_forge_build_issue_json() {
  local number="" url="" title="" body="" state="" raw="null"
  local comments_json="null" comments_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)   shift; number="${1:-}" ;;
      --url)      shift; url="${1:-}" ;;
      --title)    shift; title="${1:-}" ;;
      --body)     shift; body="${1:-}" ;;
      --state)    shift; state="${1:-}" ;;
      --comments) shift; comments_json="${1:-null}"; comments_set=true ;;
      --raw)      shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_issue_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$comments_set" = true ] || unsupported='["comments"]'

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --argjson comments "$comments_json" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      comments: $comments,
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared jq -nc builder for the review/approval envelope (forge-contract.md
# "Review/Approval Envelope"). Unlike the PR/issue objects, all three
# fields (--approved, --changes-requested JSON true/false; --approvals-
# count, a JSON int) are capability-gated — any of them can be absent
# depending on forge and plan tier, most notably GitLab's changes_requested,
# which has no concept behind it at all. Tracked by flag presence, exactly
# like the other two builders. --raw carries the untouched forge-native
# review/approval payload (defaults to null).
_forge_build_review_envelope_json() {
  local approved_json="null" changes_requested_json="null" approvals_count_json="null" raw="null"
  local approved_set=false changes_requested_set=false approvals_count_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --approved)           shift; approved_json="${1:-null}"; approved_set=true ;;
      --changes-requested)  shift; changes_requested_json="${1:-null}"; changes_requested_set=true ;;
      --approvals-count)    shift; approvals_count_json="${1:-null}"; approvals_count_set=true ;;
      --raw)                shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_review_envelope_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$approved_set" = true ]          || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["approved"]')
  [ "$changes_requested_set" = true ] || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["changes_requested"]')
  [ "$approvals_count_set" = true ]   || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["approvals_count"]')

  jq -nc \
    --argjson approved "$approved_json" \
    --argjson changesRequested "$changes_requested_json" \
    --argjson approvalsCount "$approvals_count_json" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      approved: $approved,
      changes_requested: $changesRequested,
      approvals_count: $approvalsCount,
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared three-way status envelope (forge-contract.md "Three-Way Status
# Convention"), modeled directly on _verify_creates_emit's own
# verified/missing/error trio: found/not_found/error are three genuinely
# distinct outcomes and must never be conflated the way `gh pr view --json
# url` today exits non-zero for both "no PR exists" and "auth/network
# broken". Every later forge lookup verb constructs its result through this
# one function instead of hand-rolling the JSON assembly per verb.
#
# Usage: _forge_emit_status <status> [data-json] [message]
#   status   found | not_found | error -- anything else is a caller error
#            (unknown status, exit 1) rather than silently coerced.
#   data     JSON value (typically a normalized PR/issue object). Forced to
#            null unless status == "found", so a caller cannot accidentally
#            leak a stale value across the wrong branch of the outcome.
#   message  the one and only degraded-reason field in this contract.
#            Forced to null unless status == "error".
_forge_emit_status() {
  local status="$1" data_json="${2:-null}" message="${3:-}"

  case "$status" in
    found|not_found|error) ;;
    *)
      echo "Error: _forge_emit_status: status must be found, not_found or error (got: $status)" >&2
      return 1
      ;;
  esac

  if [ "$status" != "found" ]; then
    data_json="null"
  fi
  if [ "$status" != "error" ]; then
    message=""
  fi

  jq -nc \
    --arg status "$status" \
    --argjson data "$data_json" \
    --arg message "$message" \
    '{status: $status, data: $data, message: (if $message == "" then null else $message end)}'
}

# Shared graceful-degradation gate (forge-contract.md "Degradation
# Contract") for every forge-* verb that shells out to a forge CLI
# (gh/glab/tea). `command -v` is a portable presence check that never
# invokes the binary, so it cannot itself hang, prompt, or leak an
# unguarded 127 -- guarding here is the whole point of this function.
#
# Usage: _forge_bin_check <binary> <quiet|mandatory> <forge-label>
#   Returns 0 when <binary> resolves on PATH, 1 otherwise -- in BOTH modes.
#   quiet mode:     absence produces NO stderr output at all. For a caller
#                   that already has its own fallback path and would only
#                   restate it -- matches review.md's documented row ("gh
#                   CLI not installed -> Fall back to git diff for branch
#                   comparison"), which must not gain a spurious warning it
#                   does not have today.
#   mandatory mode: absence prints exactly ONE stderr warning naming the
#                   missing binary, the forge label the caller passed (from
#                   detect-forge's output -- never a generic placeholder),
#                   and a manual next step -- matches execute.md's existing
#                   `command -v gh` gate at the per-repository PR-creation
#                   step.
_forge_bin_check() {
  local binary="$1" mode="$2" forge_label="$3"

  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$mode" = "mandatory" ]; then
    echo "Warning: $binary not found -- this $forge_label operation cannot run automatically; install $binary or complete it manually." >&2
  fi
  return 1
}

# ============================================================================
# forge-auth-status / forge-repo-info (US-003)
# ============================================================================
# Both verbs are read-only forge lookups built directly on detect-forge
# (US-001, called here as a function, never as a `$AIMI_CLI detect-forge`
# subprocess) and the shared PR/issue contract, three-way status envelope,
# and degradation helper above (US-002, commands/references/forge-
# contract.md). Every field name and the found/not_found/error vocabulary
# below comes verbatim from that file -- forge-contract.md is the single
# arbiter, and this section introduces no camelCase unsupportedFields, no
# second degraded-reason field alongside status/message, and no gh
# invocation outside the two private *_github helpers below.
#
# forge-auth-status reports whether the active gh session is authenticated
# AND which account it is acting as -- naming the acting account now is what
# lets phase 2's per-repository account selection extend this verb instead
# of retrofitting it. Phase 1 only compares identity (AIMI_FORGE_IDENTITY
# against whichever account gh already reports active); it does not
# implement switching (no `gh auth switch`, no GH_TOKEN override -- that is
# phase 2's job). Identity is read from an environment variable, NEVER a
# CLI flag -- a value that may later carry a credential must never leak
# through ps or shell history (forge-contract.md "Credential/Identity
# Model").
#
# "Not authenticated" and "could not check at all" are different facts and
# must stay distinguishable, the same discipline _verify_creates_one already
# applies by distinguishing a "missing" identity from a git tool failure
# before ever calling _verify_creates_emit:
#   - gh present, ran, reports no active session for this host -> a
#     CONFIRMED negative. status="found", data.authenticated=false,
#     data.account=null, message=null -- forge-contract.md's "found" covers
#     the lookup succeeding and returning real data, and an authenticated-
#     account check that definitively answers "no" is still a successful
#     lookup, not a broken one.
#   - gh absent from PATH, or the resolved forge has no adapter yet
#     (gitlab/gitea/unknown) -> the check itself could not run.
#     status="error", data=null, message names why. Callers branch on
#     status/message first, never on data.authenticated alone.
# "not_found" is not used by forge-auth-status: there is no "no such auth
# status" outcome the way there is "no such PR" -- the check either runs to
# a definitive true/false answer (found) or cannot run at all (error).

# Runs `gh auth status` against one host, tolerating a non-zero exit under
# `set -e` (gh's own convention: a non-zero exit here IS the confirmed
# "not authenticated" answer, not a tool failure -- gh auth status has no
# third outcome the way `gh pr view` conflates no-PR with broken auth).
# Combines stdout+stderr since gh's own account listing goes to a different
# stream across versions -- this parser only cares about the text, not
# which stream carried it.
# Prints {authenticated, account} -- account is the login of whichever
# account gh marks "Active account: true" beneath, or the sole account
# found when gh's output carries no explicit marker line at all.
_forge_auth_status_github() {
  local host="$1"
  local out="" rc=0
  if [ -n "$host" ]; then
    out=$(gh auth status --hostname "$host" 2>&1) || rc=$?
  else
    out=$(gh auth status 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    jq -nc '{authenticated: false, account: null}'
    return 0
  fi

  local active="" last="" line
  while IFS= read -r line; do
    if [[ "$line" =~ account[[:space:]]+([^[:space:]]+) ]]; then
      last="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" == *"Active account: true"* ]]; then
      active="$last"
    fi
  done <<< "$out"
  [ -n "$active" ] || active="$last"

  jq -nc --arg account "$active" \
    '{authenticated: true, account: (if $account == "" then null else $account end)}'
}

# Resolves forge/host via detect-forge's own helper (a direct function call,
# never a `$AIMI_CLI detect-forge` subprocess), dispatches to the github
# adapter when the forge is github and gh is present (checked via the
# shared _forge_bin_check above in its quiet mode -- a missing binary here
# has no caller-mandated stderr banner; the caller decides whether a
# degraded result is fatal), and otherwise reports status=error with a
# message naming why. AIMI_FORGE_IDENTITY, when set, is compared only
# against the already-active account -- never used to invoke
# `gh auth switch` or set GH_TOKEN.
_forge_auth_status() {
  local forge_info forge host
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host')

  local status="error" message="" data_json="null"

  if [ "$forge" = "github" ]; then
    if _forge_bin_check gh quiet github; then
      local gh_out authenticated_json account identity_requested identity_honored_json
      gh_out=$(_forge_auth_status_github "$host")
      authenticated_json=$(printf '%s' "$gh_out" | jq -c '.authenticated')
      account=$(printf '%s' "$gh_out" | jq -r '.account // empty')

      identity_requested="${AIMI_FORGE_IDENTITY:-}"
      identity_honored_json="null"
      if [ -n "$identity_requested" ]; then
        if [ "$identity_requested" = "$account" ]; then
          identity_honored_json="true"
        else
          identity_honored_json="false"
        fi
      fi

      status="found"
      data_json=$(jq -nc \
        --arg forge "$forge" \
        --arg host "$host" \
        --argjson authenticated "$authenticated_json" \
        --arg account "$account" \
        --arg identityRequested "$identity_requested" \
        --argjson identityHonored "$identity_honored_json" \
        '{forge: $forge,
          host: (if $host == "" then null else $host end),
          authenticated: $authenticated,
          account: (if $account == "" then null else $account end),
          identityRequested: (if $identityRequested == "" then null else $identityRequested end),
          identityHonored: $identityHonored}')
    else
      message="gh not found on PATH -- cannot check authentication status"
    fi
  else
    message="no forge adapter for ${forge} -- cannot check authentication status"
  fi

  _forge_emit_status "$status" "$data_json" "$message"
}

# Detects whether the session is authenticated with the active forge and
# which account it is acting as. See the section header above for the full
# found/error contract and the AIMI_FORGE_IDENTITY comparison rules. No
# --identity (or similarly named) flag exists anywhere in this parsing loop
# -- identity selection is env-var-only, by design (see section header).
cmd_forge_auth_status() {
  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-auth-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi

  _forge_auth_status
}

# Requests owner and name from a single `gh repo view` call -- never the two
# separate calls skills/resolve-pr-parallel/scripts/get-pr-comments makes
# today. Prints {owner, repo} on success; returns 1 (no output) on any
# failure so the caller falls back without needing to know why gh failed
# (missing auth, network, or anything else -- mirrors _resolve_default_
# branch's own primary-call-plus-offline-fallback shape, which does not
# distinguish why the primary failed either).
_forge_repo_info_github() {
  local raw="" rc=0
  raw=$(gh repo view --json owner,name 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  printf '%s' "$raw" | jq -c '{owner: .owner.login, repo: .name}' 2>/dev/null || return 1
}

# Parses owner/repo directly out of a git remote URL -- the offline fallback
# used when gh is absent, unauthenticated, or the forge has no adapter yet.
# Every path segment before the last becomes owner (not just the
# second-to-last), so a GitLab-style nested subgroup path
# (group/subgroup/repo) survives intact for a future GitLab adapter, even
# though phase 1 ships GitHub only. Prints {owner, repo}, both null when the
# path never yields at least two segments.
_forge_repo_info_parse_url() {
  local url="$1" path=""

  if [[ "$url" == *"://"* ]]; then
    path="${url#*://}"
    path="${path#*/}"
  elif [[ "$url" == *":"* ]]; then
    path="${url#*:}"
  else
    path="$url"
  fi

  path="${path%.git}"
  path="${path#/}"
  path="${path%/}"

  local repo="" owner=""
  if [ -n "$path" ] && [[ "$path" == */* ]]; then
    repo="${path##*/}"
    owner="${path%/*}"
  fi

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    jq -nc '{owner: null, repo: null}'
    return 0
  fi

  jq -nc --arg owner "$owner" --arg repo "$repo" '{owner: $owner, repo: $repo}'
}

# Two-tier resolution mirroring _resolve_default_branch's own shape: the
# github adapter is the primary path when the forge is github and gh is
# present; parsing owner/repo straight out of the already-resolved remote
# URL is the offline fallback, used whenever gh is missing, unauthenticated,
# the forge has no adapter, or the primary call otherwise fails. When even
# the fallback yields no usable owner/repo (no origin configured, or a path
# that never splits into two segments), reports status=not_found -- a
# confirmed absence, not a tool error, per forge-contract.md's Three-Way
# Status Convention.
_forge_repo_info() {
  local forge_info forge host remote_url
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host')
  remote_url=$(printf '%s' "$forge_info" | jq -r '.remoteUrl // empty')

  local owner="" repo="" source=""

  if [ "$forge" = "github" ] && _forge_bin_check gh quiet github; then
    local gh_json=""
    if gh_json=$(_forge_repo_info_github); then
      owner=$(printf '%s' "$gh_json" | jq -r '.owner // empty')
      repo=$(printf '%s' "$gh_json" | jq -r '.repo // empty')
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        source="gh"
      fi
    fi
  fi

  if { [ -z "$owner" ] || [ -z "$repo" ]; } && [ -n "$remote_url" ]; then
    local parsed
    parsed=$(_forge_repo_info_parse_url "$remote_url")
    owner=$(printf '%s' "$parsed" | jq -r '.owner // empty')
    repo=$(printf '%s' "$parsed" | jq -r '.repo // empty')
    if [ -n "$owner" ] && [ -n "$repo" ]; then
      source="local-parse"
    fi
  fi

  local status="not_found" data_json="null"
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    status="found"
    data_json=$(jq -nc \
      --arg forge "$forge" \
      --arg host "$host" \
      --arg owner "$owner" \
      --arg repo "$repo" \
      --arg source "$source" \
      '{forge: $forge,
        host: (if $host == "" then null else $host end),
        owner: $owner,
        repo: $repo,
        nameWithOwner: ($owner + "/" + $repo),
        source: $source}')
  fi

  _forge_emit_status "$status" "$data_json" ""
}

# Resolves the active forge's owner/repo for the current git repository. See
# the section header above for the gh-primary/local-parse-fallback contract.
cmd_forge_repo_info() {
  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-repo-info: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi

  _forge_repo_info
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

# Return the path to the OpenCode models validation cache file, keyed by mtime.
# Usage: _oc_models_cache_path <mtime>
# The cache stores the `opencode models` output for a specific models.json mtime.
_oc_models_cache_path() {
  local mtime="$1"
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-oc-cache-${mtime}.txt"
}

# Resolve which interactivity mode applies to the current shell.
# Prints exactly one of: picker, agent
#   agent  - AIMI_AGENT_MODE=true or CI=true (explicit overrides), OR no host
#            picker is available and stdin is not a TTY
#   picker - explicit host picker is available (Claude Code or OpenCode), OR
#            stdin is a TTY in a plain terminal
#
# Precedence (first match wins — explicit opt-out only):
#   1. --non-interactive flag → agent
#   2. AIMI_AGENT_MODE=true  → agent
#   3. CI=true               → agent
#   4. otherwise             → picker
#
# The old TTY-test branch ([ -t 0 ]) and the CLAUDECODE/OPENCODE_CONFIG_DIR
# host-check block are removed. A non-TTY shell is NOT a signal for agent mode;
# picker is the safe default so commands always surface Open Questions unless
# explicitly told not to.
cmd_detect_interactivity() {
  local non_interactive=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) non_interactive=1 ;;
    esac
    shift
  done
  if [ "$non_interactive" = "1" ] || [ "${AIMI_AGENT_MODE:-}" = "true" ] || [ "${CI:-}" = "true" ]; then
    echo "agent"
    return
  fi
  echo "picker"
}

# Resolve which configured model for each agent category.
# Reads ~/.config/aimi/models.json (schema v2.0) and maps each of the five
# categories (research, review, design, workflow, executor) to a concrete model ID.
# Schema v2.0 shape: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct one-level lookup: .categories[<host>][<category>] → model id.
# Always emits a single-line compact JSON object with all five keys.
# Unconfigured or fallback entries use the literal string "inherit".
# All warnings go to stderr; stdout is always valid JSON.
#
# v1.0 rejection: if the parsed JSON has a top-level .models key OR
# .schemaVersion is not "2.0", emits a stderr warning containing "schema 1.0"
# and returns the all-inherit fallback. Re-run `aimi-cli detect-models` to
# upgrade the config to v2.0.
#
# Performance notes:
#   - The standalone jq-empty validation pass is omitted; the resolution jq
#     error handler already catches malformed JSON.
#   - Multi-pass INVALID tagging is merged into a single jq invocation per host.
#   - OpenCode: `opencode models` output is cached by models.json mtime so
#     repeated calls within the same models.json state skip the shell-out.
cmd_resolve_models() {
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  # Fallback JSON — all five categories as inherit
  local _fallback='{"research":"inherit","review":"inherit","design":"inherit","workflow":"inherit","executor":"inherit"}'

  # No config file → silent fallback (preserves current behavior)
  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Read config (use read_aimi_models_config for consistent access)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: resolve-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # v1.0 rejection guard: reject any config that has a top-level .models key OR
  # whose .schemaVersion is not exactly "2.0". Both are signs of the old schema.
  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "Warning: resolve-models: schema 1.0 obsoleto — re-rode aimi-cli detect-models" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Determine host key
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  # Resolve each category via single-step lookup: .categories[$host][$cat] → model_id
  # Missing category or null value → inherit
  # The error handler catches malformed JSON (no separate jq empty pass needed).
  local _result
  _result=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    def resolve_cat($cat):
      ((.categories[$host][$cat] // null) | if . == null or . == "" then null else . end) as $model |
      if $model == null then "inherit" else $model end;
    {
      research: resolve_cat("research"),
      review:   resolve_cat("review"),
      design:   resolve_cat("design"),
      workflow: resolve_cat("workflow"),
      executor: resolve_cat("executor")
    } | @json
  ' 2>/dev/null) || {
    echo "Warning: resolve-models: models config file is malformed JSON or failed to parse: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  }

  if [ -z "$_result" ]; then
    echo "Warning: resolve-models: empty result from models config: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Validate resolved model IDs per host in a single jq pass:
  #   - invalid entries get value "INVALID\t<original>" (tab-delimited to handle = in model names)
  #   - warnings emitted via tab-delimited IFS read loop
  #   - validated result has INVALID entries replaced with "inherit"
  if _is_claude_code_host; then
    # Claude Code: exact-match against the set {opus, sonnet, haiku}.
    # The Task tool only accepts these short aliases — no version suffixes.
    local _tagged
    _tagged=$(printf '%s' "$_result" | jq -r '
      to_entries | map(
        .key as $cat |
        .value as $model |
        if $model == "inherit" then {key: $cat, value: "inherit"}
        elif ($model == "opus" or $model == "sonnet" or $model == "haiku") then
          {key: $cat, value: $model}
        else {key: $cat, value: ("INVALID\t" + $model)}
        end
      ) | from_entries | @json
    ' 2>/dev/null)

    # Emit warnings and build clean result in one pass
    local _validated
    _validated=$(printf '%s' "$_tagged" | jq -r '
      to_entries | map(
        if (.value | startswith("INVALID\t")) then {key: .key, value: "inherit"}
        else .
        end
      ) | from_entries | @json
    ' 2>/dev/null)

    # Print warnings for invalid entries (tab delimiter avoids = truncation)
    while IFS=$'\t' read -r _cat _val; do
      [ -n "$_cat" ] || continue
      echo "Warning: resolve-models: model '$_val' is not valid for Claude Code host (must be exactly opus, sonnet, or haiku; category: $_cat), falling back to inherit" >&2
    done < <(printf '%s' "$_tagged" | jq -r 'to_entries[] | select(.value | startswith("INVALID\t")) | .key + "\t" + (.value | ltrimstr("INVALID\t"))' 2>/dev/null)

    _result="$_validated"
  else
    # OpenCode: validate against `opencode models` output; skip validation when binary absent.
    # Cache the models list by models.json mtime to avoid shelling out on every call.
    if command -v opencode >/dev/null 2>&1; then
      local _config_mtime
      _config_mtime=$(stat -c '%Y' "$config_file" 2>/dev/null || stat -f '%m' "$config_file" 2>/dev/null || echo "0")
      local _oc_cache_file
      _oc_cache_file=$(_oc_models_cache_path "$_config_mtime")

      local _oc_models=""
      if [ -f "$_oc_cache_file" ]; then
        _oc_models=$(cat "$_oc_cache_file" 2>/dev/null) || _oc_models=""
      fi

      if [ -z "$_oc_models" ]; then
        _oc_models=$(opencode models 2>/dev/null) || _oc_models=""
        if [ -n "$_oc_models" ]; then
          # Write to cache (best-effort; failure is non-fatal)
          local _oc_aimi_dir
          _oc_aimi_dir=$(_aimi_config_dir)
          mkdir -p "$_oc_aimi_dir" 2>/dev/null || true
          printf '%s\n' "$_oc_models" > "$_oc_cache_file" 2>/dev/null || true
        fi
      fi

      if [ -n "$_oc_models" ]; then
        # Single jq pass: tag invalid entries with INVALID\t prefix
        local _oc_tagged
        _oc_tagged=$(printf '%s' "$_result" | jq -r --arg ocmodels "$_oc_models" '
          ($ocmodels | split("\n") | map(select(. != "")) | map(ltrimstr(" ") | rtrimstr(" "))) as $valid_list |
          to_entries | map(
            .key as $cat |
            .value as $model |
            if $model == "inherit" then {key: $cat, value: "inherit"}
            elif ($valid_list | index($model)) != null then {key: $cat, value: $model}
            else {key: $cat, value: ("INVALID\t" + $model)}
            end
          ) | from_entries | @json
        ' 2>/dev/null)

        local _oc_validated
        _oc_validated=$(printf '%s' "$_oc_tagged" | jq -r '
          to_entries | map(
            if (.value | startswith("INVALID\t")) then {key: .key, value: "inherit"}
            else .
            end
          ) | from_entries | @json
        ' 2>/dev/null)

        while IFS=$'\t' read -r _cat _val; do
          [ -n "$_cat" ] || continue
          echo "Warning: resolve-models: model '$_val' is not valid for OpenCode host (category: $_cat), falling back to inherit" >&2
        done < <(printf '%s' "$_oc_tagged" | jq -r 'to_entries[] | select(.value | startswith("INVALID\t")) | .key + "\t" + (.value | ltrimstr("INVALID\t"))' 2>/dev/null)

        _result="$_oc_validated"
      fi
      # If opencode models output is empty, skip validation and use configured values
    fi
    # If opencode binary is absent, skip validation (fail-safe: use configured value as-is)
  fi

  printf '%s\n' "$_result"
}

# Emit the current per-category model assignments for the active host.
# Shape: {"research": <id|null>, "review": <id|null>, "design": <id|null>,
#         "workflow": <id|null>, "executor": <id|null>}
# Unlike resolve-models, unset entries emit JSON null (not the string "inherit")
# so the /aimi:setup-models picker can distinguish "not configured" from a literal
# "inherit" override and pre-select sensible defaults.
# Schema v1.0 configs are rejected with the same stderr warning resolve-models emits;
# stdout falls back to all-null on rejection or any error.
cmd_get_current_models() {
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  local _fallback='{"research":null,"review":null,"design":null,"workflow":null,"executor":null}'

  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: get-current-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "Warning: get-current-models: schema 1.0 obsoleto — re-rode aimi-cli detect-models" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  local _result
  _result=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    def get_cat($cat):
      ((.categories[$host][$cat] // null) | if . == null or . == "" then null else . end);
    {
      research: get_cat("research"),
      review:   get_cat("review"),
      design:   get_cat("design"),
      workflow: get_cat("workflow"),
      executor: get_cat("executor")
    } | @json
  ' 2>/dev/null) || {
    echo "Warning: get-current-models: models config file is malformed JSON or failed to parse: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  }

  if [ -z "$_result" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  printf '%s\n' "$_result"
}

# List available models for the current host as a JSON array on stdout.
# Claude Code host: fixed array ["opus","sonnet","haiku"].
# OpenCode host: runs `opencode models` and parses its output into a JSON array.
#   Falls back to the built-in default Anthropic list when the opencode binary is absent,
#   printing one warning to stderr.
# stdout is always a valid JSON array; warnings go to stderr.
cmd_list_models() {
  check_jq

  local _models_list
  if _is_claude_code_host; then
    # Claude Code: short aliases only — the Task tool only accepts haiku/sonnet/opus
    printf '["opus","sonnet","haiku"]\n'
    return 0
  fi

  # OpenCode: query `opencode models`
  _models_list=""
  if command -v opencode >/dev/null 2>&1; then
    _models_list=$(opencode models 2>/dev/null) || _models_list=""
  fi

  if [ -z "${_models_list:-}" ]; then
    echo "Warning: list-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
    _models_list="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
  fi

  # Convert newline-delimited list to a JSON array
  printf '%s\n' "$_models_list" | jq -R . | jq -s .
}

# Detect available models on the current host and write ~/.config/aimi/models.json.
# Writes schema v2.0: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct category-to-model mapping — no tier indirection.
# On Claude Code (CLAUDECODE=1): fixed set — haiku, sonnet, opus (short aliases required by Task tool).
# On OpenCode: reads `opencode models`; falls back to a built-in default Anthropic list
#   with one warning when the opencode binary is absent.
#
# Flag mode (non-interactive write): when ANY of --research, --review, --design,
#   --workflow, --executor is provided, build and write models.json with the given
#   category-to-model assignments directly, skipping the TTY prompt. Preserves the
#   other host's categories sub-table when a pre-existing file exists.
#   --research <model>  Model id for the research category
#   --review <model>    Model id for the review category
#   --design <model>    Model id for the design category
#   --workflow <model>  Model id for the workflow category
#   --executor <model>  Model id for the executor category
#   All five flags must be supplied together.
#
# Interactive (stdin is a TTY, no category flags): prompts once per category for a
#   concrete model id, validated against the host's available-model list.
# Non-interactive (no flags, stdin is not TTY): writes sensible defaults without prompting.
# Writes atomically via write_aimi_models_config (mktemp + chmod 0600 + mv).
# NOTE: Only the current host's sub-table is written. Re-run on the other host to
#       populate both claudeCode and opencode tables.
cmd_detect_models() {
  check_jq

  # ---- Parse category flags --------------------------------------------------
  local _flag_research="" _flag_review="" _flag_design="" _flag_workflow="" _flag_executor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --research)
        shift
        _flag_research="${1:-}"
        ;;
      --review)
        shift
        _flag_review="${1:-}"
        ;;
      --design)
        shift
        _flag_design="${1:-}"
        ;;
      --workflow)
        shift
        _flag_workflow="${1:-}"
        ;;
      --executor)
        shift
        _flag_executor="${1:-}"
        ;;
      -*)
        echo "Error: detect-models: unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  # ---- Determine host key for models table ----------------------------------
  local _host_key
  if _is_claude_code_host; then
    _host_key="claudeCode"
  else
    _host_key="opencode"
  fi

  # ---- Flag mode: category flags provided → non-interactive write -----------
  if [ -n "$_flag_research" ] || [ -n "$_flag_review" ] || [ -n "$_flag_design" ] || [ -n "$_flag_workflow" ] || [ -n "$_flag_executor" ]; then
    # Require all five categories when using flag mode
    if [ -z "$_flag_research" ] || [ -z "$_flag_review" ] || [ -z "$_flag_design" ] || [ -z "$_flag_workflow" ] || [ -z "$_flag_executor" ]; then
      echo "Error: detect-models: when using category flags, all five must be provided: --research, --review, --design, --workflow, --executor" >&2
      exit 1
    fi

    # Read existing config to preserve the other host's categories sub-table
    local _existing_json
    _existing_json=$(read_aimi_models_config) || _existing_json=""

    local _models_json
    if [ -n "$_existing_json" ] && printf '%s' "$_existing_json" | jq empty 2>/dev/null; then
      # Merge: preserve other host's categories block, replace current host's block
      _models_json=$(printf '%s' "$_existing_json" | jq \
        --arg host_key  "$_host_key" \
        --arg research  "$_flag_research" \
        --arg review    "$_flag_review" \
        --arg design    "$_flag_design" \
        --arg workflow  "$_flag_workflow" \
        --arg executor  "$_flag_executor" \
        '{
          schemaVersion: "2.0",
          categories: ((.categories // {}) + {
            ($host_key): {
              research: $research,
              review:   $review,
              design:   $design,
              workflow: $workflow,
              executor: $executor
            }
          })
        }')
    else
      # No existing config or malformed — create fresh
      _models_json=$(jq -n \
        --arg host_key  "$_host_key" \
        --arg research  "$_flag_research" \
        --arg review    "$_flag_review" \
        --arg design    "$_flag_design" \
        --arg workflow  "$_flag_workflow" \
        --arg executor  "$_flag_executor" \
        '{
          schemaVersion: "2.0",
          categories: {
            ($host_key): {
              research: $research,
              review:   $review,
              design:   $design,
              workflow: $workflow,
              executor: $executor
            }
          }
        }')
    fi

    write_aimi_models_config "$_models_json"

    local _config_path
    _config_path=$(_aimi_models_config_path)
    printf 'detect-models: wrote %s table to %s\n' "$_host_key" "$_config_path" >&2
    printf 'detect-models: re-run on the other host to populate both claudeCode and opencode tables\n' >&2
    printf '%s\n' "$_models_json"
    return 0
  fi

  # ---- Available model sets per host ----------------------------------------
  local _available_models
  local _oc_absent=0

  if _is_claude_code_host; then
    # Claude Code: short aliases only — the Task tool only accepts haiku/sonnet/opus
    _available_models="haiku
sonnet
opus"
  else
    # OpenCode: query `opencode models`; fall back to built-in list if absent
    if command -v opencode >/dev/null 2>&1; then
      _available_models=$(opencode models 2>/dev/null) || _available_models=""
    fi
    if [ -z "${_available_models:-}" ]; then
      _oc_absent=1
      echo "Warning: detect-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
      _available_models="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
    fi
  fi

  # ---- Build per-category model defaults ------------------------------------
  # research → fast (haiku), review → powerful (opus),
  # design/workflow/executor → balanced (sonnet)
  local _fast_model _balanced_model _powerful_model

  _fast_model=$(printf '%s\n' "$_available_models" | grep -i "haiku" | head -1)
  [ -z "$_fast_model" ] && _fast_model=$(printf '%s\n' "$_available_models" | head -1)

  _balanced_model=$(printf '%s\n' "$_available_models" | grep -i "sonnet" | head -1)
  [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | sed -n '2p')
  [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | head -1)

  _powerful_model=$(printf '%s\n' "$_available_models" | grep -i "opus" | head -1)
  [ -z "$_powerful_model" ] && _powerful_model=$(printf '%s\n' "$_available_models" | tail -1)

  # Per-category defaults: research=fast, review=powerful, design/workflow/executor=balanced
  local _default_research="$_fast_model"
  local _default_review="$_powerful_model"
  local _default_design="$_balanced_model"
  local _default_workflow="$_balanced_model"
  local _default_executor="$_balanced_model"

  # ---- Per-category model assignment ----------------------------------------
  local _model_research="$_default_research"
  local _model_review="$_default_review"
  local _model_design="$_default_design"
  local _model_workflow="$_default_workflow"
  local _model_executor="$_default_executor"

  if [ -t 0 ]; then
    # stdin is a TTY — prompt once per category for a concrete model id
    local _prompt_models
    _prompt_models=$(printf '%s\n' "$_available_models" | tr '\n' '|' | sed 's/|$//')

    _prompt_category() {
      local cat="$1"
      local default="$2"
      local answer
      printf 'Category %s — model [%s] (default: %s): ' "$cat" "$_prompt_models" "$default" >&2
      read -r answer </dev/tty
      answer=$(printf '%s' "$answer" | tr -d '[:space:]')
      # Validate against available models; fall back to default on empty or invalid input
      if [ -z "$answer" ]; then
        printf '%s' "$default"
      elif printf '%s\n' "$_available_models" | grep -qxF "$answer"; then
        printf '%s' "$answer"
      else
        printf '%s' "$default"
      fi
    }

    _model_research=$(_prompt_category "research" "$_default_research")
    _model_review=$(_prompt_category "review"    "$_default_review")
    _model_design=$(_prompt_category "design"    "$_default_design")
    _model_workflow=$(_prompt_category "workflow"  "$_default_workflow")
    _model_executor=$(_prompt_category "executor"  "$_default_executor")
  fi

  # ---- Assemble the models.json document (v2.0 schema) ----------------------
  # Read the existing config FIRST so we preserve the other host's sub-table.
  # Without this merge, an unflagged detect-models invocation (e.g., the
  # /aimi:plan automatic resolve at the top of every command) overwrites the
  # file with only the current host's block, silently dropping the inactive
  # host's configured models. This is the same merge pattern the flag-mode
  # branch above uses (lines 2477-2502).
  local _existing_json
  _existing_json=$(read_aimi_models_config) || _existing_json=""

  local _models_json
  if [ -n "$_existing_json" ] && printf '%s' "$_existing_json" | jq empty 2>/dev/null; then
    # Merge: preserve other host's categories block, replace current host's block
    _models_json=$(printf '%s' "$_existing_json" | jq \
      --arg host_key  "$_host_key" \
      --arg research  "$_model_research" \
      --arg review    "$_model_review" \
      --arg design    "$_model_design" \
      --arg workflow  "$_model_workflow" \
      --arg executor  "$_model_executor" \
      '{
        schemaVersion: "2.0",
        categories: ((.categories // {}) + {
          ($host_key): {
            research: $research,
            review:   $review,
            design:   $design,
            workflow: $workflow,
            executor: $executor
          }
        })
      }')
  else
    # No existing config or malformed — create fresh
    _models_json=$(jq -n \
      --arg host_key  "$_host_key" \
      --arg research  "$_model_research" \
      --arg review    "$_model_review" \
      --arg design    "$_model_design" \
      --arg workflow  "$_model_workflow" \
      --arg executor  "$_model_executor" \
      '{
        schemaVersion: "2.0",
        categories: {
          ($host_key): {
            research: $research,
            review:   $review,
            design:   $design,
            workflow: $workflow,
            executor: $executor
          }
        }
      }')
  fi

  # ---- Atomic write ---------------------------------------------------------
  write_aimi_models_config "$_models_json"

  local _config_path
  _config_path=$(_aimi_models_config_path)
  printf 'detect-models: wrote %s table to %s\n' "$_host_key" "$_config_path" >&2
  printf 'detect-models: re-run on the other host to populate both claudeCode and opencode tables\n' >&2
  printf '%s\n' "$_models_json"
}

# Check whether the first-run model-selection prompt should be shown.
# Echoes exactly one token to stdout:
#   skip   — models.json already exists OR the marker file already exists
#   prompt — neither file exists (first run, not yet configured)
# No jq needed — pure file-existence checks.
cmd_models_prompt_check() {
  local config_file
  config_file=$(_aimi_models_config_path)

  # Missing config → prompt
  if [ ! -f "$config_file" ]; then
    echo "prompt"
    return 0
  fi

  # Empty/unreadable file → prompt (user should re-configure)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "prompt"
    return 0
  fi

  # v1.0 schema (has top-level .models OR schemaVersion != "2.0") → prompt
  # The picker re-writes the file in v2.0 shape on next configure.
  local _schema_ok
  _schema_ok=$(printf '%s' "$config_json" | jq -r '
    if (has("models") or (.schemaVersion // "") != "2.0") then "reject" else "ok" end
  ' 2>/dev/null) || _schema_ok="reject"
  if [ "$_schema_ok" = "reject" ]; then
    echo "prompt"
    return 0
  fi

  # v2.0 with current host configured (at least one category non-null) → skip.
  # Aligns with get-current-models: if the picker would pre-fill nothing for
  # this host, ask the user instead of silently falling back to all-inherit.
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  local _has_config
  _has_config=$(printf '%s' "$config_json" | jq -r --arg host "$host" '
    (.categories[$host] // {}) as $h |
    [($h.research // null), ($h.review // null), ($h.design // null),
     ($h.workflow // null), ($h.executor // null)]
    | map(select(. != null and . != ""))
    | (length > 0)
  ' 2>/dev/null) || _has_config="false"

  if [ "$_has_config" = "true" ]; then
    echo "skip"
    return 0
  fi

  # Host not configured but config file is present — honor the per-host
  # dismissal marker if it exists. File-missing always re-prompts (above);
  # this branch only matters when the user kept some config but explicitly
  # opted out for this host.
  local marker_file
  marker_file=$(_aimi_models_prompt_marker_path)
  if [ -f "$marker_file" ]; then
    echo "skip"
  else
    echo "prompt"
  fi
}

# Atomically create the models first-run prompt marker file.
# Idempotent — safe to call when the marker already exists.
# Content: current date or a short sentinel line.
cmd_models_prompt_dismiss() {
  local marker_file
  marker_file=$(_aimi_models_prompt_marker_path)
  local marker_dir
  marker_dir=$(dirname "$marker_file")

  if ! mkdir -p "$marker_dir" 2>/dev/null; then
    echo "Error: models-prompt-dismiss: cannot create directory: $marker_dir" >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${marker_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf 'models-prompt-seen: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp_file"
  if ! mv "$tmp_file" "$marker_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: models-prompt-dismiss: mv failed for $marker_file" >&2
    return 1
  fi
  echo "models-prompt-dismiss: marker written to $marker_file"
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

  # Case --base override: Branch is new and caller provided an explicit base.
  # The existence check stays here rather than in the shared resolver so this
  # hard failure keeps its exact stderr text and exit code regardless of how
  # the resolver's own "explicit-base" resolution behaves.
  if [ -n "$base_override" ]; then
    if ! git ls-remote --heads origin "$base_override" 2>/dev/null | grep -q "$base_override" && \
       ! git branch --list "$base_override" | grep -q "$base_override"; then
      echo "Error: Base branch does not exist: $base_override" >&2
      exit 1
    fi
  fi

  # Case 4/5: Branch is new — delegate the base decision to the shared
  # resolver (_resolve_branch_base) so this path can never drift from the
  # container path's resolve-base-branch. The mapping from reason to action
  # is total: explicit-base -> created-from-base, default-branch ->
  # created-from-default, detached-head and stacked-on-current both ->
  # created-from-current. target-exists is unreachable here — Case 1-3 above
  # already short-circuited on an existing target before the resolver runs.
  local resolution reason base
  resolution=$(_resolve_branch_base "$branch_name" "$default_branch" "$base_override")
  reason=$(echo "$resolution" | jq -r '.reason')
  base=$(echo "$resolution" | jq -r '.base')

  case "$reason" in
    explicit-base)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-base","base":"%s"}\n' "$branch_name" "$base_override"
      ;;
    default-branch)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-default"}\n' "$branch_name"
      ;;
    detached-head|stacked-on-current)
      # Create from current HEAD (detached or carrying unmerged work) without
      # an explicit ref, matching the pre-existing behavior exactly.
      git checkout -b "$branch_name" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-current"}\n' "$branch_name"
      ;;
    *)
      echo "Error: Unexpected base-resolution reason: $reason" >&2
      exit 1
      ;;
  esac
  return 0
}

# Decide what branch a new branch or container should be cut from, without
# performing any git mutation. Single source of truth shared by the inline
# (cmd_setup_branch) and container (execute.md) paths so an empty/unset base
# can never mean "stack on current" on one path and "use the default branch"
# on the other. Assumes branch_name/default_branch/base_override are already
# validated and CWD is inside the target git repository.
#
# Resolution order (first match wins):
#   1. base_override given                                -> explicit-base
#   2. branch_name already exists locally or on origin     -> target-exists
#   3. HEAD is detached                                     -> detached-head
#   4. current branch IS default, or merged into origin/default -> default-branch
#   5. otherwise (current branch carries unmerged work)     -> stacked-on-current
#
# The emitted "base" prefers the origin/<name> remote-tracking ref over the
# bare local name, so a container is never cut from a stale local ref after a
# successful fetch -- mirroring how cmd_setup_branch already checks out
# origin/$default_branch for created-from-default. Two reasons opt out:
#
#   stacked-on-current -- the candidate is the caller's own checkout, and
#     inheriting its local tip is what stacking means. Preferring origin here
#     drops every commit made since the last push.
#   detached-head      -- base is the raw HEAD sha; there is no branch name to
#     prefer a remote ref for.
#
# promptNeeded is true only when reason resolves to stacked-on-current --
# the same four-condition gate execute.md Step 1.6 computes inline today
# (target absent locally and on origin, current branch not default, current
# branch not merged into origin/default), now computed once per repo here.
# Exact ref predicates. Every one of these answers a yes/no question about a
# single, fully-qualified ref -- never a pattern plus a substring grep.
#
# `git branch --list X | grep -q X` and `git ls-remote --heads origin X` both
# match loosely: ls-remote patterns match on trailing path components, so a
# probe for `main` reports refs/heads/team/main and the caller then emits an
# origin/main that does not resolve, killing worktree creation in any repo
# that happens to carry a scoped branch of the same leaf name.
_local_has_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

_origin_has_branch() {
  git ls-remote --heads origin "refs/heads/$1" 2>/dev/null \
    | grep -q "[[:space:]]refs/heads/${1}$"
}

# Is <branch> already merged into origin/<default>?
#
# --format strips the "[* ] " column git normally prints, and -qxF matches the
# whole line literally. A regex match here is unsafe: git permits `.` in ref
# names, so a branch named feat.x matches a merged feat/x and its real
# unmerged work is discarded with no prompt -- the exact failure issue #78 is
# about, reached through a different door.
_is_merged_into_default() {
  git branch --format='%(refname:short)' --merged "origin/$2" 2>/dev/null \
    | grep -qxF "$1"
}

_resolve_branch_base() {
  local branch_name="$1" default_branch="$2" base_override="$3"
  local current_branch reason base candidate prompt_needed
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  base=""
  candidate=""
  prompt_needed=false

  if [ -n "$base_override" ]; then
    reason="explicit-base"
    candidate="$base_override"
  elif _local_has_branch "$branch_name" || _origin_has_branch "$branch_name"; then
    reason="target-exists"
    candidate="$branch_name"
  elif [ -z "$current_branch" ]; then
    reason="detached-head"
    base=$(git rev-parse HEAD 2>/dev/null || echo "")
  elif [ "$current_branch" = "$default_branch" ] || _is_merged_into_default "$current_branch" "$default_branch"; then
    reason="default-branch"
    candidate="$default_branch"
  else
    reason="stacked-on-current"
    candidate="$current_branch"
    prompt_needed=true
  fi

  # Origin preference, scoped by reason: prefer the origin/<name>
  # remote-tracking ref for a reference point the caller did not author, so a
  # container is never cut from a stale local ref after a successful fetch.
  #
  # stacked-on-current is deliberately excluded. There the candidate IS the
  # caller's own checkout, and inheriting its local tip is the entire point of
  # stacking -- preferring origin would silently drop every commit made since
  # the last push, which is the common state of an autonomous run. That would
  # also put this path back in disagreement with cmd_setup_branch, whose
  # stacked-on-current arm checks out from local HEAD.
  if [ -n "$candidate" ]; then
    if [ "$reason" != "stacked-on-current" ] && _origin_has_branch "$candidate"; then
      base="origin/$candidate"
    else
      base="$candidate"
    fi
  fi

  printf '{"base":"%s","reason":"%s","currentBranch":"%s","defaultBranch":"%s","promptNeeded":%s}\n' \
    "$base" "$reason" "$current_branch" "$default_branch" "$prompt_needed"
}

# CLI wrapper for _resolve_branch_base(): arg-parsing, --project cd and the
# three branch-name validations, mirroring cmd_setup_branch's shape exactly.
cmd_resolve_base_branch() {
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
        echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
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
    echo "Error: Invalid branch name: $default_branch" >&2
    exit 1
  fi

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $base_override" >&2
    exit 1
  fi

  _resolve_branch_base "$branch_name" "$default_branch" "$base_override"
}

# Clear all state files (preserves tasks directory)
cmd_clear_state() {
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result" "$AIMI_DIR/cli-path"
  rm -f "$AIMI_DIR"/default-branch-* 2>/dev/null
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
  # IFS-split on a herestring is trailing-newline-safe; avoids read returning non-zero
  # on the final unterminated segment when piping through sed, which dropped the leaf.
  local jq_path _parts _p
  IFS=. read -ra _parts <<< "$field_path"
  jq_path=''
  for _p in "${_parts[@]}"; do
    jq_path+=".$_p"
  done

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

  # metadata.execution validation: optional discriminator, must be exactly
  # "container" or "inline" when present. Absent is valid (defaults to inline
  # for backward compatibility with every tasks.json written before this field
  # existed) — see commands/references/execution-mode.md for the read contract.
  local execution_mode
  execution_mode=$(jq -r '.metadata.execution // empty' "$tasks_file" 2>/dev/null)

  if [ -n "$execution_mode" ] && [ "$execution_mode" != "container" ] && [ "$execution_mode" != "inline" ]; then
    errors+=("${tasks_file}: metadata.execution has invalid value \"${execution_mode}\" (expected \"container\" or \"inline\")")
  fi

  # metadata.execution / metadata.phase mutual exclusivity: a phase-scoped
  # file (metadata.phase present) always executes inside its own phase
  # container, so metadata.execution would be dead data there — the exact
  # confusion US-006 corrects. /aimi:plan never writes both; this rule
  # catches a hand-edited or stale file that carries both anyway.
  local has_phase
  has_phase=$(jq -r 'if (.metadata.phase // null) != null then "true" else "false" end' "$tasks_file" 2>/dev/null)

  if [ "$has_phase" = "true" ] && [ -n "$execution_mode" ]; then
    errors+=("${tasks_file}: metadata.execution and metadata.phase cannot both be present (phase-scoped files never carry metadata.execution)")
  fi

  # metadata.branchName validation: must match the same mandated pattern
  # already enforced by cmd_init_session and open-pr.md (see CLAUDE.md's
  # Security Requirements) — branchName is interpolated into git/gh commands
  # downstream, so a value outside this charset is a command-injection vector.
  # An absent/empty value also fails, since the pattern requires a leading
  # alphanumeric character.
  local branch_name
  branch_name=$(jq -r '.metadata.branchName // empty' "$tasks_file" 2>/dev/null)

  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    errors+=("${tasks_file}: metadata.branchName \"${branch_name}\" does not match the required pattern ^[a-zA-Z0-9][a-zA-Z0-9/_-]*\$")
  fi

  # verification.url charset validation: a conservative allowlist (letters,
  # digits, and :/?#@!&*+,._~%=- , first character alphanumeric or /) that
  # excludes backtick, $, quotes, ;, |, <, >, and whitespace — the characters
  # needed for shell command injection when a URL is later interpolated into
  # a quoted string (see I10 review finding). Stories without a verification
  # object, or with a null/empty/non-string url, are ignored — same tolerance
  # the metadata.execution check above gives to an absent field.
  local url_charset_re='^[A-Za-z0-9/][A-Za-z0-9:/?#@!&*+,._~%=-]*$'
  local bad_urls
  bad_urls=$(jq -r --arg re "$url_charset_re" '
    .userStories[] |
    select(.verification | type == "object") |
    select((.verification.url | type == "string") and (.verification.url != "")) |
    select((.verification.url | test($re)) | not) |
    [.id, .verification.url] | @tsv
  ' "$tasks_file" 2>/dev/null)

  if [ -n "$bad_urls" ]; then
    while IFS=$'\t' read -r story_id bad_url; do
      [ -z "$story_id" ] && continue
      errors+=("${tasks_file}: ${story_id} verification.url \"${bad_url}\" contains characters outside the allowed charset")
    done <<< "$bad_urls"
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

# Check whether a tasks file's stories are ALL terminal (completed or skipped)
# and non-empty. Echoes nothing; return code only (0 = archivable-as-a-file).
_archivable_file_is_terminal() {
  local tasks_file="$1"
  local non_terminal
  non_terminal=$(jq '[.userStories[] | select(.status != "completed" and .status != "skipped")] | length' "$tasks_file" 2>/dev/null)
  [ -z "$non_terminal" ] && return 1
  [ "$non_terminal" -ne 0 ] && return 1

  local total
  total=$(jq '.userStories | length' "$tasks_file" 2>/dev/null)
  [ -z "$total" ] && return 1
  [ "$total" -eq 0 ] && return 1
  return 0
}

# List task files where all stories have terminal status (completed or skipped).
# Discovers both the flat layout (.aimi/tasks/*-tasks.json) and the nested
# phase-folder layout (.aimi/tasks/<feature>/phase-N-slug/<feature>-phase-N-
# tasks.json) via the shared discovery helper. A feature folder's nested
# phase tasks files surface together as a single unit -- only when every
# phase tasks file discovered under that feature is all-terminal AND the
# feature's roadmap.json (read directly via jq, not a roadmap-lifecycle
# subcommand, to avoid coupling to its still-evolving CLI surface) marks
# every phase completed -- rather than piecemeal as each phase happens to
# finish. "completed" is the only terminal phase status (see the roadmap
# status enum in cmd_roadmap_set_status); there is no "deferred" status. A
# phase stuck in verification_failed therefore excludes its feature from the
# result same as any other non-completed status, but is never a *silent*
# dead end: it's called out on stderr each time, naming the feature and the
# blocked phase ids, so the block stays discoverable instead of an
# unexplained permanent absence from the list. A feature folder with no
# roadmap.json (or a malformed one) falls back to the flat per-file terminal
# check, so stray nested files created without roadmap-init are still
# individually archivable.
# Returns a JSON array of file paths (stdout shape unchanged by the above).
cmd_list_archivable() {
  local all_files
  all_files=$(_find_tasks_files_all)

  local result="["
  local first=true

  _archivable_append() {
    local resolved
    resolved=$(resolve_path "$1")
    if [ "$first" = true ]; then
      first=false
    else
      result="$result,"
    fi
    result="$result$(printf '"%s"' "$resolved")"
  }

  # Split discovered files into flat (direct child of TASKS_DIR) vs nested
  # (feature/phase-slug/file, two directories below TASKS_DIR).
  local flat_files=() nested_files=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$(dirname "$f")" = "$TASKS_DIR" ]; then
      flat_files+=("$f")
    else
      nested_files+=("$f")
    fi
  done <<< "$all_files"

  for f in "${flat_files[@]+"${flat_files[@]}"}"; do
    [ -f "$f" ] || continue
    _archivable_file_is_terminal "$f" && _archivable_append "$f"
  done

  # Group nested files by feature folder (two directories above each file)
  # and evaluate the whole feature as a unit.
  local -A feature_seen
  for f in "${nested_files[@]+"${nested_files[@]}"}"; do
    local feature_dir
    feature_dir=$(dirname "$(dirname "$f")")
    [ -n "${feature_seen[$feature_dir]:-}" ] && continue
    feature_seen[$feature_dir]=1

    local feature_files=()
    local ff
    for ff in "${nested_files[@]+"${nested_files[@]}"}"; do
      if [ "$(dirname "$(dirname "$ff")")" = "$feature_dir" ]; then
        feature_files+=("$ff")
      fi
    done

    local all_terminal=true
    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      if [ ! -f "$ff" ] || ! _archivable_file_is_terminal "$ff"; then
        all_terminal=false
        break
      fi
    done
    [ "$all_terminal" = true ] || continue

    local roadmap_path="$feature_dir/roadmap.json"
    if [ -f "$roadmap_path" ] && jq -e . "$roadmap_path" >/dev/null 2>&1; then
      local non_terminal_phases
      non_terminal_phases=$(jq '[.phases[] | select(.status != "completed")] | length' "$roadmap_path" 2>/dev/null)
      [ -z "$non_terminal_phases" ] && continue
      if [ "$non_terminal_phases" -ne 0 ]; then
        # A stuck (verification_failed) phase is excluded the same as any
        # other non-completed status, but never silently -- name it and the
        # feature on stderr every run so the block stays visible instead of
        # becoming an unexplained permanent absence from the result.
        local stuck_ids
        stuck_ids=$(jq -r '[.phases[] | select(.status == "verification_failed") | (.id|tostring)] | join(", ")' "$roadmap_path" 2>/dev/null)
        if [ -n "$stuck_ids" ]; then
          echo "Warning: list-archivable: $feature_dir not archivable -- phase(s) $stuck_ids stuck in verification_failed (re-verify via roadmap-set-status, or resolve manually)" >&2
        fi
        continue
      fi
    fi
    # No roadmap.json (or malformed): every discovered phase file already
    # passed the per-file terminal check above, so fall back to including them.

    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      _archivable_append "$ff"
    done
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

# Usage: research-lookup [--ignore-missing-cited-paths] <path>
# Check whether a research file is fresh relative to its cited source paths.
# Freshness: research-file mtime >= newest mtime among existing cited source paths.
# A cited path that does not exist -> stale (logs a warning to stderr).
#   With --ignore-missing-cited-paths: missing cited paths log a warning but do NOT mark stale.
# No '## File References' section -> stale.
# Fresh: prints the research path + exits 0.
# Stale/undecidable: prints nothing + exits 1.
# Missing argument: usage on stderr + exits 1.
cmd_research_lookup() {
  local ignore_missing=0
  local research_path=""

  # Parse flag in either position relative to the positional path arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignore-missing-cited-paths)
        ignore_missing=1
        shift
        ;;
      -*)
        echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
        exit 1
        ;;
      *)
        research_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$research_path" ]; then
    echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
    exit 1
  fi

  if [ ! -f "$research_path" ]; then
    echo "Error: Research file not found: $research_path" >&2
    exit 1
  fi

  # Resolve and validate the research file path
  local resolved_research
  resolved_research=$(resolve_path "$research_path")
  validate_path_in_project "$resolved_research"

  # Get the mtime (seconds since epoch) of the research file
  local research_mtime
  research_mtime=$(stat -c '%Y' "$resolved_research" 2>/dev/null || stat -f '%m' "$resolved_research" 2>/dev/null)
  if [ -z "$research_mtime" ]; then
    echo "Error: Cannot stat research file: $resolved_research" >&2
    exit 1
  fi

  # Extract the '## File References' section: lines between the h2 header and the next h2/EOF
  # Parse bullet list entries (lines starting with - or *)
  local file_refs_section
  file_refs_section=$(awk '
    /^## File References/ { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$resolved_research")

  # If no File References section found -> stale
  if [ -z "$file_refs_section" ]; then
    exit 1
  fi

  # Parse bullet list: lines starting with optional whitespace then - or *
  # Extract the path portion (strip leading bullet marker and whitespace)
  local cited_paths
  cited_paths=$(printf '%s\n' "$file_refs_section" | grep -E '^\s*[-*]\s+' | sed 's/^\s*[-*]\s\+//')

  # If section exists but has no bullet entries -> stale
  if [ -z "$cited_paths" ]; then
    exit 1
  fi

  local newest_source_mtime=0
  local stale=0

  while IFS= read -r cited_path; do
    [ -z "$cited_path" ] && continue

    # Reject absolute paths outright
    if [ "${cited_path#/}" != "$cited_path" ]; then
      echo "Warning: Absolute path rejected in File References: $cited_path" >&2
      stale=1
      continue
    fi

    # Resolve relative to PROJECT_ROOT, canonicalizing any .. traversals
    local abs_cited_path
    if [ "$_HAS_REALPATH" -eq 1 ]; then
      # realpath -m normalizes .. without requiring the path to exist
      abs_cited_path=$(realpath -m "$PROJECT_ROOT/$cited_path" 2>/dev/null) || abs_cited_path="$PROJECT_ROOT/$cited_path"
    else
      abs_cited_path="$PROJECT_ROOT/$cited_path"
    fi

    # Validate stays within project (exit on escape attempt)
    validate_path_in_project "$abs_cited_path"

    # Check existence
    if [ ! -e "$abs_cited_path" ]; then
      echo "Warning: Cited source path does not exist (stale): $cited_path" >&2
      if [ "$ignore_missing" -eq 0 ]; then
        stale=1
      fi
      continue
    fi

    # Get mtime of the source file
    local src_mtime
    src_mtime=$(stat -c '%Y' "$abs_cited_path" 2>/dev/null || stat -f '%m' "$abs_cited_path" 2>/dev/null)
    if [ -z "$src_mtime" ]; then
      echo "Warning: Cannot stat cited path (stale): $abs_cited_path" >&2
      stale=1
      continue
    fi

    if [ "$src_mtime" -gt "$newest_source_mtime" ]; then
      newest_source_mtime=$src_mtime
    fi
  done <<< "$cited_paths"

  # If any cited path was missing or unreadable -> stale
  if [ "$stale" -ne 0 ]; then
    exit 1
  fi

  # Freshness check: research mtime must be >= newest source mtime
  if [ "$research_mtime" -ge "$newest_source_mtime" ]; then
    printf '%s\n' "$resolved_research"
    exit 0
  else
    exit 1
  fi
}

# Usage: extract-sections <file> --anchors "<heading titles, newline-separated>"
# Print only the requested '## '/'### ' sections of a research .md file, concatenated
# verbatim in the order the anchors were requested.
# Each section spans from its matching heading line up to (but not including) the next
# heading of the same-or-higher level, or EOF -- so an h2 anchor includes its nested h3s
# and stops at the next h2 (or h1); an h3 anchor stops at the next h3/h2 (or h1).
# Anchor text is matched case-insensitively against the heading text (leading #s and
# surrounding whitespace stripped). An anchor with no matching heading is skipped (not
# a fatal error) but is named in a "no section matched anchor" warning on stderr; a run
# whose anchors match nothing prints empty output, still exit 0.
# Anchors containing shell metacharacters ($ ` " \) are rejected with a warning on
# stderr and skipped -- defense in depth, since anchor text originates from untrusted
# research-file heading content.
# Path confinement mirrors research-lookup: resolve_path + validate_path_in_project.
# Missing file -> error + exit 1. Missing <file>/--anchors arg -> usage + exit 1.
cmd_extract_sections() {
  local file_path=""
  local anchors_raw=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --anchors)
        if [ $# -lt 2 ]; then
          echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
          exit 1
        fi
        anchors_raw="$2"
        shift 2
        ;;
      -*)
        echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
        exit 1
        ;;
      *)
        file_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$file_path" ] || [ -z "$anchors_raw" ]; then
    echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
    exit 1
  fi

  if [ ! -f "$file_path" ]; then
    echo "Error: File not found: $file_path" >&2
    exit 1
  fi

  # Resolve and validate the target file path
  local resolved_file
  resolved_file=$(resolve_path "$file_path")
  validate_path_in_project "$resolved_file"

  # Split --anchors on newlines only (comma is valid heading-text punctuation and must
  # NOT be treated as a delimiter); trim and lowercase each entry; skip blanks.
  # Extract each anchor's section (first matching heading only) in request order.
  local anchor anchor_lc unmatched_anchors=""
  while IFS= read -r anchor; do
    anchor=$(printf '%s' "$anchor" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$anchor" ] && continue

    # Defense in depth: anchors originate from untrusted research-file heading text.
    # The orchestrator sanitizes before interpolating, but this CLI must not rely on
    # that. Reject only characters dangerous inside a double-quoted shell argument --
    # &, comma, parens, colon, slash, hyphen, underscore, period, and single-quote are
    # all legitimate heading punctuation and MUST keep working.
    case "$anchor" in
      *'$'*|*'`'*|*'"'*|*'\'*)
        echo "Warning: anchor rejected (shell metacharacter): $anchor" >&2
        continue ;;
    esac

    anchor_lc=$(printf '%s' "$anchor" | tr '[:upper:]' '[:lower:]')

    # awk streams matched section lines straight to stdout (byte-for-byte, blank
    # lines and all) and reports match status via its own exit code -- this avoids
    # a $(...) capture, which would silently swallow trailing blank lines.
    if awk -v target="$anchor_lc" '
      BEGIN { in_section = 0; match_level = 0; matched_done = 0; in_fence = 0 }
      {
        if ($0 ~ /^[[:space:]]*(```|~~~)/) { in_fence = !in_fence }
        level = 0
        if (!in_fence && $0 ~ /^#+[[:space:]]/) {
          line_copy = $0
          while (substr(line_copy, 1, 1) == "#") {
            level++
            line_copy = substr(line_copy, 2)
          }
        }

        # Close the active section at the next heading of same-or-higher level
        # (a lower heading level number outranks a higher one, e.g. h2 outranks h3).
        if (in_section && level > 0 && level <= match_level) {
          in_section = 0
        }

        # Only ## / ### headings are matchable anchors; first match wins.
        if (!in_section && !matched_done && (level == 2 || level == 3)) {
          heading_text = substr($0, level + 1)
          gsub(/^[[:space:]]+/, "", heading_text)
          gsub(/[[:space:]]+$/, "", heading_text)
          if (tolower(heading_text) == target) {
            in_section = 1
            matched_done = 1
            match_level = level
          }
        }

        if (in_section) {
          print
        }
      }
      END { exit (matched_done ? 0 : 1) }
    ' "$resolved_file"; then
      :
    else
      unmatched_anchors="$unmatched_anchors
$anchor"
    fi
  done < <(printf '%s\n' "$anchors_raw")

  if [ -n "$unmatched_anchors" ]; then
    while IFS= read -r anchor; do
      [ -z "$anchor" ] && continue
      echo "Warning: no section matched anchor: $anchor" >&2
    done <<< "$unmatched_anchors"
  fi

  return 0
}

# Usage: research-gc
# Garbage-collect orphaned research files from .aimi/research/*.md.
# A file is deleted only when BOTH conditions are true:
#   1. It is NOT referenced by any active .aimi/tasks/*.json metadata.researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter foundationProposalPath.
#   2. Its mtime is older than 30 days.
# .aimi/archive is ignored entirely.
# Prints "Cleaned <N> orphaned research files (>30 days)" when N>0; silent when N=0.
cmd_research_gc() {
  local research_dir="$AIMI_DIR/research"

  # Nothing to do if research dir doesn't exist
  if [ ! -d "$research_dir" ]; then
    return 0
  fi

  # Build the referenced-set: union of researchPaths across all active tasks/*.json
  # plus researchPaths from all brainstorms/*.md frontmatter.
  local referenced_set=""

  # --- Source 1: .aimi/tasks/*.json metadata.researchPaths ---
  local tasks_dir="$AIMI_DIR/tasks"
  if [ -d "$tasks_dir" ]; then
    while IFS= read -r rpath; do
      [ -z "$rpath" ] && continue
      # Normalize: strip leading ./ and collapse to a canonical relative path
      rpath="${rpath#./}"
      referenced_set="$referenced_set
$rpath"
    done < <(
      for f in "$tasks_dir"/*.json; do
        [ -f "$f" ] || continue
        jq -r '.metadata.researchPaths[]? // empty' "$f" 2>/dev/null
      done
    )
  fi

  # --- Source 2: .aimi/brainstorms/*.md frontmatter researchPaths ---
  # --- Source 3: .aimi/brainstorms/*.md frontmatter foundationProposalPath (scalar) ---
  local brainstorms_dir="$AIMI_DIR/brainstorms"
  if [ -d "$brainstorms_dir" ]; then
    for bfile in "$brainstorms_dir"/*.md; do
      [ -f "$bfile" ] || continue
      # Extract YAML frontmatter (lines between opening and closing ---)
      # Parse researchPaths: list entries (lines starting with - under that key)
      # and foundationProposalPath: as a single scalar value, independent of order.
      local in_front=0 past_open=0 in_rp=0
      while IFS= read -r line; do
        if [ "$past_open" -eq 0 ] && [ "$line" = "---" ]; then
          past_open=1
          in_front=1
          continue
        fi
        if [ "$in_front" -eq 1 ] && [ "$line" = "---" ]; then
          break
        fi
        if [ "$in_front" -eq 0 ]; then
          # First non-frontmatter line without opening --- means no frontmatter
          break
        fi
        # Inside frontmatter
        if printf '%s\n' "$line" | grep -qE '^researchPaths\s*:'; then
          in_rp=1
          continue
        fi
        if printf '%s\n' "$line" | grep -qE '^foundationProposalPath[[:space:]]*:'; then
          # New top-level key: exit any in-progress researchPaths list scan first,
          # regardless of whether foundationProposalPath appears before or after it.
          in_rp=0
          local fp_entry
          # POSIX [[:space:]] (not \s — GNU-only in sed); then normalize the
          # extracted scalar so a YAML-quoted value or a trailing comment cannot
          # defeat the referenced-set match (which would delete a live artifact):
          #   1. strip a trailing " #comment" (space-hash onward)
          #   2. strip one pair of surrounding double or single quotes
          #   3. strip a leading ./
          fp_entry=$(printf '%s\n' "$line" | sed 's/^foundationProposalPath[[:space:]]*:[[:space:]]*//')
          fp_entry=$(printf '%s\n' "$fp_entry" | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//')
          case "$fp_entry" in
            \"*\") fp_entry="${fp_entry#\"}"; fp_entry="${fp_entry%\"}" ;;
            \'*\') fp_entry="${fp_entry#\'}"; fp_entry="${fp_entry%\'}" ;;
          esac
          fp_entry="${fp_entry#./}"
          referenced_set="$referenced_set
$fp_entry"
          continue
        fi
        if [ "$in_rp" -eq 1 ]; then
          # List item: lines starting with optional spaces then - followed by space
          if printf '%s\n' "$line" | grep -qE '^\s*-\s+'; then
            local rp_entry
            rp_entry=$(printf '%s\n' "$line" | sed 's/^\s*-\s\+//')
            rp_entry="${rp_entry#./}"
            referenced_set="$referenced_set
$rp_entry"
          elif printf '%s\n' "$line" | grep -qE '^\s*[a-zA-Z]'; then
            # A new key — exit researchPaths block
            in_rp=0
          fi
        fi
      done < "$bfile"
    done
  fi

  # Compute threshold: now - 30 days in seconds
  local now threshold
  now=$(date +%s)
  threshold=$((now - 30 * 86400))

  local cleaned=0

  # Iterate .aimi/research/*.md
  for rfile in "$research_dir"/*.md; do
    [ -f "$rfile" ] || continue

    # Compute relative path from PROJECT_ROOT (for set membership check)
    local rel_path
    if [ "${rfile#/}" = "$rfile" ]; then
      # Relative path already — but canonicalize via PROJECT_ROOT
      rel_path="$AIMI_DIR/research/$(basename "$rfile")"
    else
      # Absolute — make relative to PROJECT_ROOT
      rel_path="${rfile#"$PROJECT_ROOT/"}"
    fi
    rel_path="${rel_path#./}"

    # Check if this file is in the referenced-set
    local is_referenced=0
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      ref_norm="${ref#./}"
      if [ "$ref_norm" = "$rel_path" ]; then
        is_referenced=1
        break
      fi
    done <<< "$referenced_set"

    if [ "$is_referenced" -eq 1 ]; then
      continue
    fi

    # Check mtime: only delete if older than threshold
    local file_mtime
    file_mtime=$(stat -c '%Y' "$rfile" 2>/dev/null || stat -f '%m' "$rfile" 2>/dev/null)
    if [ -z "$file_mtime" ]; then
      continue
    fi

    if [ "$file_mtime" -lt "$threshold" ]; then
      rm -f "$rfile"
      cleaned=$((cleaned + 1))
    fi
  done

  if [ "$cleaned" -gt 0 ]; then
    echo "Cleaned $cleaned orphaned research files (>30 days)"
  fi
}

# ============================================================================
# story-merge: Consolidate staging files into a validated tasks.json
# Usage: aimi-cli.sh story-merge --staging-dir <dir> --output <path>
#           [--split legacy|full-stack] [--agent-mode] [--phase-aware]
#           [--foundation <NN>]
# ============================================================================

# _story_merge_assign_ids: given a JSON array of story objects (already loaded),
# assign sequential US-NNN IDs by lexicographic order of their source filename.
# The $1 array has objects with a synthetic "srcFile" key attached before this call.
# Returns the array with id fields populated.

cmd_story_merge() {
  local staging_dir="" output_path="" split_mode="legacy" agent_mode=false phase_aware=false foundation_idx=""
  # Resolved by the --foundation injection sweep below and consumed (only) by
  # the PROJECT-axis writer, which flags cross-group edges onto it distinctly.
  # Stays "" whenever --foundation was omitted, so no real id can match it.
  local foundation_id=""

  # --- Parse flags ---
  while [ $# -gt 0 ]; do
    case "$1" in
      --staging-dir)
        shift
        staging_dir="${1:-}"
        ;;
      --output)
        shift
        output_path="${1:-}"
        ;;
      --split)
        shift
        split_mode="${1:-legacy}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      --phase-aware)
        phase_aware=true
        ;;
      --foundation)
        shift
        foundation_idx="${1:-}"
        ;;
      *)
        echo "Error: story-merge: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  # --- Validate required flags ---
  if [ -z "$staging_dir" ]; then
    echo "Error: story-merge: --staging-dir <path> is required" >&2
    exit 1
  fi
  if [ -z "$output_path" ]; then
    echo "Error: story-merge: --output <path> is required" >&2
    exit 1
  fi
  if [ "$split_mode" != "legacy" ] && [ "$split_mode" != "full-stack" ]; then
    echo "Error: story-merge: --split must be 'legacy' or 'full-stack', got: $split_mode" >&2
    exit 1
  fi
  if [ -n "$foundation_idx" ] && ! [[ "$foundation_idx" =~ ^[0-9]{2}$ ]]; then
    echo "Error: story-merge: --foundation must be a two-digit index (e.g. 01), got: $foundation_idx" >&2
    exit 1
  fi
  # --phase-aware strips ONE trailing "-tasks" segment from the --output
  # basename. Both writers do that strip with the same `${base_no_ext%-tasks}`
  # expansion, and on a basename that is exactly "tasks" the strip is a no-op
  # while on "-tasks" it collapses to the empty string -- either way the
  # derived name degenerates (".../-frontend-tasks.json", ".../-<slug>-tasks.json":
  # a basename starting with "-", which every downstream tool reads as a flag).
  # Guarding inside the writers would mean either fixing one axis and leaving
  # the other, or changing SIDE-axis behavior; refusing the input here leaves
  # both strips byte-identical and costs the caller one well-named error.
  # The derivation below mirrors the writers' exactly (basename, strip the
  # extension after the LAST dot) so the precondition can never drift from the
  # expansion it protects.
  if [ "$phase_aware" = true ]; then
    local pa_base pa_ext pa_no_ext
    pa_base=$(basename "$output_path")
    pa_ext="${pa_base##*.}"
    pa_no_ext="${pa_base%.$pa_ext}"
    case "$pa_no_ext" in
      # ?* before "-tasks": at least one character must survive the strip.
      ?*-tasks) ;;
      *)
        echo "Error: story-merge: --phase-aware requires an --output basename ending in \"-tasks\"" >&2
        echo "(phase-scoped form, e.g. <feature>-phase-<N>-tasks.json); got: $pa_base" >&2
        exit 1
        ;;
    esac
  fi

  # --- Validate paths are inside project ---
  validate_path_in_project "$staging_dir"
  local output_parent
  output_parent=$(dirname "$output_path")
  # output_path may not exist yet; validate parent dir or the path itself
  if [ -e "$output_path" ]; then
    validate_path_in_project "$output_path"
  elif [ -e "$output_parent" ]; then
    validate_path_in_project "$output_parent"
  fi

  # --- Staging dir must exist ---
  if [ ! -d "$staging_dir" ]; then
    echo "Error: story-merge: staging directory does not exist: $staging_dir" >&2
    exit 1
  fi

  # --- Glob *.json files, sorted lexicographically ---
  # Skip non-story sidecars written by plan.md Phase 3b (outline.json) and any
  # future *outline*.json metadata files — they have a different shape and would
  # be mis-merged as bogus stories.
  local staging_files=()
  while IFS= read -r f; do
    local fbase
    fbase=$(basename "$f")
    case "$fbase" in
      outline.json|*outline*.json|metadata.json|audit-result.json) continue ;;
    esac
    staging_files+=("$f")
  done < <(find "$staging_dir" -maxdepth 1 -name '*.json' -type f | sort)

  if [ ${#staging_files[@]} -eq 0 ]; then
    echo "Error: story-merge: no *.json files found in $staging_dir" >&2
    exit 1
  fi

  # --- Validate each file is valid JSON and extract numeric index prefix ---
  # Also detect duplicate numeric index prefixes
  local -A seen_indices
  local files_ordered=()
  for f in "${staging_files[@]}"; do
    local base
    base=$(basename "$f")
    # Validate JSON
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "Error: story-merge: malformed JSON in file: $base" >&2
      exit 1
    fi
    # Extract numeric prefix (leading digits up to first non-digit)
    local idx
    idx=$(printf '%s' "$base" | sed 's/^\([0-9]*\).*/\1/')
    if [ -n "$idx" ]; then
      if [ -n "${seen_indices[$idx]+_}" ]; then
        echo "Error: story-merge: duplicate index '$idx' in files: ${seen_indices[$idx]} and $base" >&2
        exit 1
      fi
      seen_indices[$idx]="$base"
    fi
    files_ordered+=("$f")
  done

  # --- Load all staging story objects, attaching a _srcIdx field (0-based) ---
  # Build a single merged JSON array from all files.
  # Each staging file should be either a single story object or an array of stories.
  local merged_array="[]"
  local story_idx=0
  for f in "${files_ordered[@]}"; do
    local content
    content=$(cat "$f")
    # Detect if top-level is array or object
    local kind
    kind=$(printf '%s' "$content" | jq -r 'if type == "array" then "array" else "object" end')
    if [ "$kind" = "array" ]; then
      # Flatten array entries, attaching _srcIdx to each
      local base
      base=$(basename "$f")
      merged_array=$(printf '%s\n%s' "$merged_array" "$content" | jq -s \
        --arg base "$base" \
        '.[0] as $acc | .[1] as $arr |
         $acc + ($arr | map(. + {_srcIdx: ('$story_idx' + (. | path) | if . == null then 0 else . end)}))
        ' 2>/dev/null) || true
      # Simpler approach: just append with sequential indices
      local arr_len
      arr_len=$(printf '%s' "$content" | jq 'length')
      local i
      for (( i=0; i<arr_len; i++ )); do
        local story_obj
        story_obj=$(printf '%s' "$content" | jq ".[$i]")
        merged_array=$(printf '%s' "$merged_array" | jq \
          --argjson s "$story_obj" \
          --argjson idx "$story_idx" \
          '. + [$s + {_srcIdx: $idx}]')
        story_idx=$((story_idx + 1))
      done
      merged_array=$(printf '%s' "$merged_array" | jq '.')
    else
      # Single story object
      merged_array=$(printf '%s' "$merged_array" | jq \
        --argjson s "$content" \
        --argjson idx "$story_idx" \
        '. + [$s + {_srcIdx: $idx}]')
      story_idx=$((story_idx + 1))
    fi
  done

  local total_stories
  total_stories=$(printf '%s' "$merged_array" | jq 'length')

  # --- Assign US-NNN IDs by source index (lex order of files, order within file) ---
  merged_array=$(printf '%s' "$merged_array" | jq '
    to_entries | map(
      .value + {id: ("US-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}
    )
  ')

  # Also build index→id map (srcIdx → US-NNN) for outline:NN remap
  local idx_to_id
  idx_to_id=$(printf '%s' "$merged_array" | jq '[
    .[] | {key: (.._srcIdx | tostring), value: .id} | select(.key != null)
  ] | from_entries' 2>/dev/null || echo '{}')
  # Simpler: build map as array of [srcIdx, id]
  idx_to_id=$(printf '%s' "$merged_array" | jq '[.[] | {srcIdx: ._srcIdx, id: .id}]')

  # --- Remap outline:NN tokens in dependsOn arrays ---
  # "outline:02" → US-NNN where srcIdx == 2 (zero-padded 2 = index 1? no: outline index is 1-based per decision)
  # Decision: "Sub-agents emit dependsOn entries as 'outline:NN' (zero-padded, matching the outline order)"
  # The outline order matches file lex order → outline:01 = first story (srcIdx=0) → US-001
  # So outline:NN (1-based) → srcIdx = NN - 1 → look up US-NNN
  merged_array=$(printf '%s\n%s' "$merged_array" "$idx_to_id" | jq -s '
    .[0] as $stories |
    .[1] as $idx_map |

    # Build outline-index → US-NNN map: outline:01 means 1-based index = srcIdx 0
    ($stories | to_entries | map({key: (.key + 1 | tostring | if length == 1 then "0" + . else . end), value: .value.id}) | from_entries) as $outline_map |

    $stories | map(
      .dependsOn = [
        (.dependsOn // [])[] |
        if startswith("outline:") then
          (ltrimstr("outline:")) as $nn |
          if $outline_map[$nn] != null then $outline_map[$nn]
          else "UNRESOLVED_OUTLINE:" + $nn
          end
        else
          .
        end
      ]
    )
  ')

  # Check for unresolved outline refs
  local unresolved
  unresolved=$(printf '%s' "$merged_array" | jq -r '
    [.[] | .id as $sid | (.dependsOn // [])[] | select(startswith("UNRESOLVED_OUTLINE:")) | $sid + ": " + .] | .[]
  ')
  if [ -n "$unresolved" ]; then
    echo "Error: story-merge: unresolved outline reference(s):" >&2
    printf '%s\n' "$unresolved" >&2
    exit 1
  fi

  # --- Remove synthetic _srcIdx field before further processing ---
  merged_array=$(printf '%s' "$merged_array" | jq '[.[] | del(._srcIdx)]')

  # --- Resolve the split axis (and refuse unrouteable .project values) ---
  # Earliest point at which every story carries its final US-NNN id, and still
  # ahead of --foundation, cycle detection, and the Phase 3.1/4.1/4.2 sweeps:
  # a refusal here costs nothing and cannot emit a warning about a plan that
  # was never going to be written. The axis is decided ONCE, here, and the
  # writers below only read the answer.
  local split_axis
  split_axis=$(_story_merge_resolve_axis "$merged_array" "$split_mode") || exit 1

  # --- Foundation dependsOn injection sweep (--foundation NN) ---
  # Runs after the outline:NN remap and _srcIdx strip, and before both the
  # Kahn's-algorithm cycle detection and wave computation below, so injected
  # edges are naturally included in both without touching either block.
  # foundation_idx is an outline position (1-based, same convention as
  # outline:NN tokens) — resolved against the array's own position, not
  # against a literal staging-filename digit.
  # Cycle-safe by construction: the foundation's own dependsOn is asserted
  # empty before any edge is added, and injection only ever adds edges
  # pointing toward the foundation (never away from it), so no new cycle can
  # be introduced; the Kahn's-algorithm check below still runs unmodified.
  if [ -n "$foundation_idx" ]; then
    foundation_id=$(printf '%s' "$merged_array" | jq -r --arg nn "$foundation_idx" '
      (to_entries | map({key: (.key + 1 | tostring | if length == 1 then "0" + . else . end), value: .value.id}) | from_entries) as $outline_map |
      $outline_map[$nn] // ""
    ')
    if [ -z "$foundation_id" ]; then
      echo "Error: story-merge: --foundation $foundation_idx not present among staging files" >&2
      exit 1
    fi

    local foundation_depends_on
    foundation_depends_on=$(printf '%s' "$merged_array" | jq -c --arg fid "$foundation_id" '[.[] | select(.id == $fid)][0].dependsOn // []')
    if [ "$foundation_depends_on" != "[]" ]; then
      echo "Error: story-merge: foundation story $foundation_id has non-empty dependsOn" >&2
      exit 1
    fi

    merged_array=$(printf '%s' "$merged_array" | jq --arg fid "$foundation_id" '
      map(
        if .id == $fid then
          .
        else
          .dependsOn = (
            (.dependsOn // []) as $d |
            if ($d | index($fid)) != null then $d else $d + [$fid] end
          )
        end
      )
    ')
  fi

  # --- DAG cycle detection via topological sort (Kahn's algorithm in jq) ---
  local cycle_result
  cycle_result=$(printf '%s' "$merged_array" | jq '
    . as $stories |
    ($stories | map(.id)) as $all_ids |

    # Build adjacency: dependsOn edges (dep → story means story depends on dep)
    # For cycle detection, we want to find if any node is reachable from itself
    # via Kahn topological sort: if remaining nodes exist after sort, there is a cycle

    # Compute in-degree for each node
    (reduce $stories[] as $s (
      {};
      . + {($s.id): (($s.dependsOn // []) | length)}
    )) as $in_degree |

    # Compute adjacency list: adj[dep_id] = [story_ids that depend on dep_id]
    (reduce $stories[] as $s (
      {};
      reduce ($s.dependsOn // [])[] as $dep (
        .;
        .[$dep] = (.[$dep] // []) + [$s.id]
      )
    )) as $adj |

    # Kahn: start with zero in-degree nodes
    ([$stories[] | select((($in_degree[.id]) // 0) == 0) | .id]) as $initial_queue |

    # Iterate using fixed accumulator variable binding
    (reduce range($stories | length) as $_ (
      {queue: $initial_queue, deg: $in_degree, visited: []};
      if (.queue | length) == 0 then .
      else
        .queue[0] as $node |
        .deg as $cur_deg |
        .visited as $cur_vis |
        .queue[1:] as $rest_q |
        ($adj[$node] // []) as $neighbors |
        (reduce $neighbors[] as $n ($cur_deg; .[$n] = ((.[$n] // 1) - 1))) as $new_deg |
        {
          queue: ($rest_q + [$neighbors[] | . as $n | select(($new_deg[$n] // 0) == 0)]),
          deg: $new_deg,
          visited: ($cur_vis + [$node])
        }
      end
    )) as $result |

    if ($result.visited | length) == ($stories | length) then
      {cycle: false, stories_in_cycle: []}
    else
      {
        cycle: true,
        stories_in_cycle: [$stories[] | .id | select(. as $id | ($result.visited | index($id)) == null)]
      }
    end
  ')

  local has_cycle
  has_cycle=$(printf '%s' "$cycle_result" | jq -r '.cycle')
  if [ "$has_cycle" = "true" ]; then
    local cycle_stories
    cycle_stories=$(printf '%s' "$cycle_result" | jq -r '.stories_in_cycle | join(", ")')
    echo "Error: story-merge: circular dependency detected among stories: $cycle_stories" >&2
    exit 1
  fi

  # --- Wave computation: roots = wave 1, others = max(dep waves) + 1 ---
  merged_array=$(printf '%s' "$merged_array" | jq '
    . as $stories |
    # Iterative wave assignment: repeat until stable (max N iterations)
    reduce range($stories | length) as $_ (
      ($stories | map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)}));
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')

  # --- Rule 22: Mock-sync AC routing ---
  # Process each schema-extending story: route mock-sync ACs to consumer stories.
  # We implement this as a shell loop to avoid complex nested jq.
  local schema_ids
  schema_ids=$(printf '%s' "$merged_array" | jq -r '
    .[] | select(
      (.implementation.files // []) | any(
        test("schemas/.*\\.(ts|js|py|rb)$") or
        test("types/.*\\.(ts|js)$") or
        test("zod/.*\\.(ts|js)$") or
        test("\\.schema\\.ts$") or
        test("\\.types\\.ts$")
      )
    ) | .id
  ')

  local schema_id
  for schema_id in $schema_ids; do
    # Check if schema story has a mock-sync AC
    local has_mock
    has_mock=$(printf '%s' "$merged_array" | jq -r \
      --arg sid "$schema_id" \
      '.[] | select(.id == $sid) | .acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; ""))) | length > 0')
    [ "$has_mock" = "true" ] || continue

    # Extract schema story text for field-name extraction
    local schema_text
    schema_text=$(printf '%s' "$merged_array" | jq -r \
      --arg sid "$schema_id" \
      '.[] | select(.id == $sid) | [.title, (.description // "")] + (.acceptanceCriteria // []) | join(" ")')

    # Step 1: Extract camelCase field names (lowercase-starting)
    local field_names
    field_names=$(printf '%s' "$schema_text" | jq -rR \
      '[scan("[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*|[a-z][a-z0-9_]*_[a-z][a-z0-9_]*")] | map(select(length > 3)) | .[]' 2>/dev/null || true)

    # Step 2: Find consumers via field-name literal match
    local consumer_ids=""
    if [ -n "$field_names" ]; then
      consumer_ids=$(printf '%s' "$merged_array" | jq -r \
        --arg sid "$schema_id" \
        --arg fields "$field_names" \
        '
        ($fields | split("\n") | map(select(length > 0))) as $fn_list |
        .[] | select(.id != $sid) |
        . as $c |
        ([$c.title, ($c.description // "")] + ($c.acceptanceCriteria // []) | join(" ")) as $ctext |
        select($fn_list | any(. as $fn | ($ctext | test($fn; "")))) |
        .id
        ' 2>/dev/null || true)
    fi

    # Step 3: CamelCase entity-name fuzzy fallback
    if [ -z "$consumer_ids" ]; then
      local schema_title
      schema_title=$(printf '%s' "$merged_array" | jq -r --arg sid "$schema_id" '.[] | select(.id == $sid) | .title')
      local word_parts
      word_parts=$(printf '%s' "$schema_title" | jq -rR '[scan("[A-Z][a-z]+")] | .[]' 2>/dev/null || true)
      if [ -n "$word_parts" ]; then
        consumer_ids=$(printf '%s' "$merged_array" | jq -r \
          --arg sid "$schema_id" \
          --arg words "$word_parts" \
          '
          ($words | split("\n") | map(select(length > 0))) as $wp_list |
          .[] | select(.id != $sid) |
          . as $c |
          ([$c.title, ($c.description // "")] + ($c.acceptanceCriteria // []) | join(" ")) as $ctext |
          select($wp_list | any(. as $wp | ($ctext | test($wp; "i")))) |
          .id
          ' 2>/dev/null || true)
      fi
    fi

    [ -n "$consumer_ids" ] || continue

    # Route: move mock-sync AC from schema story to each consumer
    merged_array=$(printf '%s' "$merged_array" | jq \
      --arg sid "$schema_id" \
      --arg consumer_list "$consumer_ids" \
      '
      ($consumer_list | split("\n") | map(select(length > 0))) as $cids |

      # Extract mock-sync ACs from schema story
      ((.[] | select(.id == $sid)).acceptanceCriteria // [] |
        map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; "")))) as $mock_acs |

      map(
        . as $s |
        if $s.id == $sid then
          $s + {acceptanceCriteria: ($s.acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; "") | not)))}
        elif ($cids | index($s.id)) != null then
          ($s.acceptanceCriteria // [] | map(select(test("[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"; ""))) | length == 0) as $no_mock |
          if $no_mock then
            $s + {acceptanceCriteria: (($s.acceptanceCriteria // []) + $mock_acs)}
          else $s
          end
        else $s
        end
      )
      ')
  done

  # --- Phase 3.1: Reference Element Inventory verdict check ---
  # Check for any story that has an inventory with unverdicted rows
  local inventory_errors=""
  local inventory_warnings=""
  local inv_check
  inv_check=$(printf '%s' "$merged_array" | jq '
    [.[] |
      . as $s |
      select(
        (.referenceInventory != null) and
        (.referenceInventory | type) == "array" and
        (.referenceInventory | length) > 0
      ) |
      . as $s |
      [.referenceInventory[] | select(
        (.verdict == null or .verdict == "" or (.verdict | test("^(encoded|excluded|deferred)$") | not))
      )] as $unverdicted |
      select(($unverdicted | length) > 0) |
      {id: $s.id, unverdicted_count: ($unverdicted | length), elements: ($unverdicted | map(.element // "unknown"))}
    ]
  ')
  local inv_violations
  inv_violations=$(printf '%s' "$inv_check" | jq 'length')
  if [ "$inv_violations" -gt 0 ]; then
    local inv_msg
    inv_msg=$(printf '%s' "$inv_check" | jq -r '.[] | "  Story \(.id): \(.unverdicted_count) unverdicted inventory row(s): \(.elements | join(", "))"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 3.1 inventory verdict incomplete (--agent-mode: proceeding):" >&2
      printf '%s\n' "$inv_msg" >&2
    else
      echo "Error: story-merge: Phase 3.1 Reference Element Inventory has unverdicted rows:" >&2
      printf '%s\n' "$inv_msg" >&2
      exit 1
    fi
  fi

  # --- Phase 4.1: Coverage Self-Check ---
  # For each story with a referenceInventory, check ac_anchors >= floor(proto_elements * 0.6)
  local coverage_check
  coverage_check=$(printf '%s' "$merged_array" | jq '
    [.[] |
      select(
        (.referenceInventory != null) and
        (.referenceInventory | type) == "array" and
        (.referenceInventory | length) > 0
      ) |
      . as $s |
      (.referenceInventory | length) as $proto_elements |
      ($s.ac_anchors // (.acceptanceCriteria // [] | length)) as $ac_anchors |
      ($proto_elements * 0.6 | floor) as $threshold |
      select($ac_anchors < $threshold) |
      {id: $s.id, ac_anchors: $ac_anchors, proto_elements: $proto_elements, threshold: $threshold}
    ]
  ')
  local coverage_violations
  coverage_violations=$(printf '%s' "$coverage_check" | jq 'length')
  if [ "$coverage_violations" -gt 0 ]; then
    local cov_msg
    cov_msg=$(printf '%s' "$coverage_check" | jq -r '.[] | "  Story \(.id): ac_anchors=\(.ac_anchors) < floor(\(.proto_elements) * 0.6)=\(.threshold)"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 4.1 coverage ratio not met (--agent-mode: proceeding):" >&2
      printf '%s\n' "$cov_msg" >&2
    else
      echo "Error: story-merge: Phase 4.1 Coverage Self-Check failed:" >&2
      printf '%s\n' "$cov_msg" >&2
      exit 1
    fi
  fi

  # --- Phase 4.2: Cross-Story Orphan-Symbol Smell ---
  # Heuristic, WARNING-ONLY (never a hard block). NOT codebase dead-code
  # detection: it scans only sibling STORY PROSE, not the codebase. It flags a
  # story whose every extracted symbol (camelCase / PascalCase / snake_case,
  # length >= 4) from implementation.approach appears in NO other story's text
  # corpus (title + description + ACs + approach + files). Signal: a symbol the
  # plan introduces that no sibling story mentions may be an orphan addition.
  #
  # Known limits (text vs. semantics; sibling-prose vs. call graph):
  #   - Cannot prove a symbol is dead — that depends on existing callers in the
  #     actual codebase, which this check does not inspect.
  #   - False positives: legitimate leaf symbols (CLI entry points, webhook /
  #     cron handlers) have no sibling-story mention by design.
  #   - False negatives: a referencing story using a different name (alias,
  #     import rename, dynamic dispatch) is invisible to a text scan.
  # Skipped for single-story merges (no sibling corpus → every symbol would be
  # trivially flagged). Mirrors Phase 4.1's agent-mode warn-vs-emit convention.
  local _sm_story_count orphan_sym_check
  _sm_story_count=$(printf '%s' "$merged_array" | jq 'length')
  if [ "${_sm_story_count:-0}" -lt 2 ]; then
    orphan_sym_check='[]'
  else
    orphan_sym_check=$(printf '%s' "$merged_array" | jq '
      . as $all |
      [.[] |
        . as $s |
        select(
          (.implementation.approach != null) and
          ((.implementation.approach | type) == "string") and
          ((.implementation.approach | length) > 0)
        ) |
        (.implementation.approach) as $approach |
        # camelCase / PascalCase / snake_case identifiers, length >= 4;
        # single-case plain words are excluded to reduce noise.
        ($approach | [scan("[A-Za-z][A-Za-z0-9_]*")] |
          map(select(
            length >= 4 and
            (
              test("^[a-z].*[A-Z]") or
              test("^[A-Z][a-z]+[A-Z]") or
              test("_[a-z]")
            )
          ))
        ) as $symbols |
        select(($symbols | length) > 0) |
        ([$all[] |
            select(.id != $s.id) |
            [
              (.title // ""),
              (.description // ""),
              ((.acceptanceCriteria // []) | join(" ")),
              (.implementation.approach // ""),
              ((.implementation.files // []) | join(" "))
            ] | join(" ")
          ] | join(" ")
        ) as $other_corpus |
        # Word-boundary match: `userId` is NOT treated as referenced by an
        # unrelated `userIdentifier`. Symbols are [A-Za-z0-9_]+, so no regex
        # metacharacter can reach test().
        ($symbols | map(select(. as $sym | ($other_corpus | test("\\b" + $sym + "\\b")) | not))) as $unreferenced |
        select(($unreferenced | length) == ($symbols | length)) |
        {id: $s.id, symbols: $symbols}
      ]
    ')
  fi
  local orphan_sym_violations
  orphan_sym_violations=$(printf '%s' "$orphan_sym_check" | jq 'length')
  if [ "$orphan_sym_violations" -gt 0 ]; then
    local orphan_msg
    orphan_msg=$(printf '%s' "$orphan_sym_check" | jq -r \
      '.[] | "  Story \(.id): introduces symbols no other story references: \(.symbols | join(", "))"')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (--agent-mode: proceeding):" >&2
      printf '%s\n' "$orphan_msg" >&2
    else
      echo "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (heuristic; verify before proceeding):" >&2
      printf '%s\n' "$orphan_msg" >&2
    fi
  fi

  # ============================================================
  # Phase 4.2 → smellWarnings metadata field
  # ============================================================
  # Surface orphan-symbol findings to the orchestrator's Step 5 report by
  # embedding them in metadata.smellWarnings. The writers below inject this
  # field only when non-empty; absent otherwise.
  local smell_warnings
  if [ "${orphan_sym_violations:-0}" -gt 0 ]; then
    smell_warnings=$(printf '%s' "$orphan_sym_check" | jq '[.[] | {type: "orphan-symbol", storyId: .id, symbols: .symbols, message: "introduces symbols no sibling story references"}]')
  else
    smell_warnings='[]'
  fi

  # ============================================================
  # Branch on split mode
  # ============================================================
  # The split AXIS was decided by _story_merge_resolve_axis immediately after
  # id assignment, before any of the sweeps above ran. Nothing is recomputed
  # here -- this block only dispatches on the answer, so there is no second
  # partition rule that could disagree with the one the writer groups by.
  if [ "$split_mode" = "full-stack" ]; then
    if [ "$split_axis" = "project" ]; then
      # foundation_id is threaded into the PROJECT writer ONLY. --foundation
      # injects one edge onto the foundation story from every other story; in
      # a multi-repo split every group that does not host the foundation loses
      # that edge and would otherwise look like an ordinary hand-authored
      # missing dependency. The SIDE writer keeps its byte-identical signature.
      _story_merge_write_project_split "$merged_array" "$output_path" "$staging_dir" "$smell_warnings" "$phase_aware" "$foundation_id"
    else
      _story_merge_write_split "$merged_array" "$output_path" "$staging_dir" "$smell_warnings" "$phase_aware"
    fi
  else
    _story_merge_write_legacy "$merged_array" "$output_path" "$staging_dir" "$smell_warnings"
  fi
}

# jq `def`s spliced into every program that needs a story's .project either
# classified or reduced to a stable grouping key. Shared by
# _story_merge_resolve_axis and _story_merge_write_project_split so the two can
# never drift apart -- an axis chosen from one rule and a group built from
# another is exactly how issue #72 came back (one branch, two repositories).
#
# Grouping/counting/classification ONLY -- neither the normalized nor the
# classified form is ever written back onto a story; .project must survive
# verbatim into the output files.
#
#   norm_project  -- trims surrounding whitespace, strips one trailing slash,
#                    and treats blank/whitespace-only (and absent) as null.
#   project_state -- validates the RAW value against the grammar execute.md
#                    publishes for .project, returning exactly one of
#                    "untagged" / "tagged" / "invalid". Deliberately inspects
#                    the raw string, not the trimmed one: " apps/web " is
#                    invalid rather than being quietly trimmed into a value
#                    whose raw form is what a downstream command would cd into.
#                    Only a fully blank string counts as untagged.
#   group_key     -- the single routing key. Both the axis decision and the
#                    grouping pass go through this and nothing else.
_STORY_MERGE_NORM_PROJECT_JQ='
def norm_project:
  if . == null then null
  else
    (. | gsub("^\\s+|\\s+$"; "")) as $t |
    if $t == "" then null
    elif ($t | endswith("/")) then $t[0:-1]
    else $t
    end
  end;

def project_state:
  if . == null then "untagged"
  elif (type != "string") then "invalid"
  elif ((. | gsub("^\\s+|\\s+$"; "")) == "") then "untagged"
  elif . == "." then "tagged"
  elif (test("^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*$")
        and ((split("/") | index("..")) == null)
        and ((test("//")) | not)) then "tagged"
  else "invalid"
  end;

def group_key: norm_project;
'

# Resolve the split AXIS from the merged array, refusing anything the axis
# cannot route unambiguously. Echoes exactly "project" or "side"; returns 1
# after printing a named refusal otherwise.
#
# Called once, early -- before --foundation, cycle detection, and the Phase
# 3.1/4.1/4.2 sweeps -- so a refusal costs nothing and emits no warnings about
# a plan that was never going to be written.
#
# Decision table (counts computed here, ONCE, and nowhere else):
#   any story with an invalid .project     -> refuse, in EVERY --split mode
#   distinct >= 1 AND untagged > 0         -> refuse (--split full-stack only)
#   distinct >= 2                          -> "project"  (multi-repo)
#   otherwise                              -> "side"     (single-repo/monorepo)
#
# The untagged rule tests distinct >= 1, not >= 2, deliberately: the failure
# this exists to stop is ONE tagged repo plus untagged stories, which counts as
# a single distinct project and would otherwise take the SIDE axis -- one file,
# one branch, two repositories.
#
# _rm_sanitize is applied HERE and only here. These lines print values that
# already failed validation and are therefore unbounded; on every success path
# .project is a routing key that must stay byte-identical between the key that
# groups and the key that is written.
_story_merge_resolve_axis() {
  local merged_array="$1"
  local split_mode="$2"

  # Malformed .project is refused in EVERY --split mode, legacy included: the
  # value is a repository path a downstream command will cd into, so
  # "../sibling-repo" must not reach a tasks file by any route.
  local invalid_stories
  invalid_stories=$(printf '%s' "$merged_array" | jq -r "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
    [.[] | . as $s | select(($s.project | project_state) == "invalid")] | .[] |
    "  " + .id + " (" + (.title | _rm_sanitize(200)) + "): invalid project " + (.project | tostring | _rm_sanitize(120))
  ')
  if [ -n "$invalid_stories" ]; then
    echo "Error: story-merge: story .project must match ^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*\$ with no \"..\" component, no \"//\", no surrounding whitespace, and no leading \"./\" (use \".\" for the root repository); no files were written:" >&2
    printf '%s\n' "$invalid_stories" >&2
    return 1
  fi

  if [ "$split_mode" != "full-stack" ]; then
    printf '%s' "side"
    return 0
  fi

  local axis_counts distinct_count untagged_count
  axis_counts=$(printf '%s' "$merged_array" | jq -c "$_STORY_MERGE_NORM_PROJECT_JQ"'
    [.[] | . as $s | {state: ($s.project | project_state), key: ($s.project | group_key)}] as $st |
    {
      distinct: ([$st[] | select(.state == "tagged") | .key] | unique | length),
      untagged: ([$st[] | select(.state == "untagged")] | length)
    }
  ')
  distinct_count=$(printf '%s' "$axis_counts" | jq -r '.distinct')
  untagged_count=$(printf '%s' "$axis_counts" | jq -r '.untagged')

  if [ "${distinct_count:-0}" -ge 1 ] && [ "${untagged_count:-0}" -gt 0 ]; then
    local untagged_stories
    untagged_stories=$(printf '%s' "$merged_array" | jq -r "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
      [.[] | . as $s | select(($s.project | project_state) == "untagged")] | .[] |
      "  " + .id + " (" + (.title | _rm_sanitize(200)) + "): no project"
    ')
    echo "Error: story-merge: --split full-stack: this plan tags $distinct_count project(s), so it is a multi-repo plan and EVERY story needs a project. A story that belongs to the root repository must say so explicitly with \".\" -- an absent project is not the root, it is unrouteable. No files were written; the staging dir was kept. Stories missing a project:" >&2
    printf '%s\n' "$untagged_stories" >&2
    return 1
  fi

  if [ "${distinct_count:-0}" -ge 2 ]; then
    printf '%s' "project"
  else
    printf '%s' "side"
  fi
  return 0
}

# Write a single merged tasks.json (legacy mode)
_story_merge_write_legacy() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"

  # Build the final tasks.json structure
  # Metadata is minimal; the caller (plan command) fills in the full metadata.
  # story-merge only provides structure; metadata.title, branchName, etc. come from
  # the staging context or are set to sensible defaults.
  # smellWarnings is injected only when non-empty so absent-by-default stays the norm.
  local tasks_json
  tasks_json=$(printf '%s\n%s' "$merged_array" "$smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks",
          type: "feat",
          branchName: "feat/merged",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | (.status //= "pending")]
    }
  ')

  # Ensure output directory exists
  mkdir -p "$(dirname "$output_path")"

  # Atomic write via _lock
  local tmp_file
  tmp_file=$(mktemp "${output_path}.XXXXXX")
  (
    _lock "${output_path}.lock"
    printf '%s\n' "$tasks_json" > "$tmp_file"
    mv "$tmp_file" "$output_path"
  ) 200>"${output_path}.lock"
  local exit_code=$?
  rm -f "$tmp_file" 2>/dev/null
  if [ $exit_code -ne 0 ]; then
    echo "Error: story-merge: failed to write output file: $output_path" >&2
    exit 1
  fi

  # On success: delete the staging dir
  rm -rf "$staging_dir"

  local story_count
  story_count=$(printf '%s' "$merged_array" | jq 'length')
  jq -n \
    --arg output "$output_path" \
    --argjson stories "$story_count" \
    '{merged: $output, stories: $stories}'
}

# Write two split tasks files (full-stack mode, SIDE axis: frontend/backend).
# Chosen by cmd_story_merge for single-repo/monorepo layouts only -- fewer than
# 2 distinct normalized .project values across the merged array.
_story_merge_write_split() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"
  local phase_aware="${5:-false}"

  # Partition by the per-story frontend heuristic, unconditionally.
  #
  # This writer only ever sees a single-repo/monorepo merge: cmd_story_merge
  # routes every layout carrying >= 2 distinct normalized .project values to
  # _story_merge_write_project_split instead, so there is no project group to
  # vote on here and no project-aware branch. Every story is classified by its
  # own file-pattern/title verdict (implementation.files matching tsx/jsx/
  # components//pages//frontend//ui//client/, OR title+description matching the
  # UI/Frontend/Component/Page/View/React/Tailwind keyword set) -- byte-
  # identical to what the old monorepo-guard fallback produced, which covers
  # both "no story has .project" and "every story shares exactly one project".
  local tagged_stories
  tagged_stories=$(printf '%s' "$merged_array" | jq '
    def fe_heuristic:
      ((.implementation.files // []) | any(
        test("\\.(tsx|jsx)$") or test("components?/") or test("pages?/") or
        test("frontend/") or test("ui/") or test("client/")
      )) or
      ((.title + " " + (.description // "")) | test("\\b(UI|Frontend|Component|Page|View|React|Tailwind)\\b"; "i"));
    [.[] | . + {_fe: fe_heuristic}] | map(. + {_side: ._fe})
  ')

  # Bipartition: two select() passes over the single tagged-and-sided array,
  # so every story id structurally lands in exactly one output (never lost,
  # never duplicated) rather than incidentally so.
  local frontend_stories backend_stories
  frontend_stories=$(printf '%s' "$tagged_stories" | jq '[.[] | select(._side == true)]')
  backend_stories=$(printf '%s' "$tagged_stories" | jq '[.[] | select(._side == false)]')

  # Re-assign unique IDs: frontend US-001 ... US-N, backend US-(N+1) ... US-M
  local fe_count be_count
  fe_count=$(printf '%s' "$frontend_stories" | jq 'length')
  be_count=$(printf '%s' "$backend_stories" | jq 'length')

  # An empty split side still writes its (empty userStories) file below --
  # traced, does not crash downstream -- but is surfaced with a named warning
  # rather than failing silently.
  if [ "$fe_count" -eq 0 ]; then
    echo "Warning: story-merge: frontend split produced zero stories" >&2
  fi
  if [ "$be_count" -eq 0 ]; then
    echo "Warning: story-merge: backend split produced zero stories" >&2
  fi

  # Build ID remapping for frontend
  local fe_id_map="{}"
  fe_id_map=$(printf '%s' "$frontend_stories" | jq '
    to_entries | map({key: .value.id, value: ("US-" + ((.key + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}) | from_entries
  ')

  # Build ID remapping for backend (offset by frontend count)
  local fe_count_n
  fe_count_n=$(printf '%s' "$frontend_stories" | jq 'length')
  local be_id_map="{}"
  be_id_map=$(printf '%s' "$backend_stories" | jq \
    --argjson offset "$fe_count_n" \
    'to_entries | map({key: .value.id, value: ("US-" + ((.key + $offset + 1) | tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end))}) | from_entries')

  # Global pre-remap-id -> {newId, side, title} lookup map, built from BOTH
  # sides' stories + id maps BEFORE either dependsOn-remap block below runs.
  # A pre-remap id would exist in neither output file, so naming a dropped
  # cross-file target usefully requires resolving it against this map now.
  local global_id_map
  global_id_map=$(printf '%s\n%s\n%s\n%s' "$frontend_stories" "$fe_id_map" "$backend_stories" "$be_id_map" | jq -s '
    .[0] as $fe | .[1] as $fe_map | .[2] as $be | .[3] as $be_map |
    ([$fe[] | {key: .id, value: {newId: ($fe_map[.id] // .id), side: "frontend", title: .title}}]
     + [$be[] | {key: .id, value: {newId: ($be_map[.id] // .id), side: "backend", title: .title}}])
    | from_entries
  ')

  # Apply ID remap and rebuild dependsOn (remove cross-file refs) for frontend.
  # Alongside the existing remap, capture the pre-remap dep ids that did NOT
  # resolve against the LOCAL id_map (i.e. cross-file) as __droppedDeps, and
  # flag __becameRoot when the story had a non-empty dependsOn that is now
  # entirely gone as a direct result of the drop.
  frontend_stories=$(printf '%s\n%s' "$frontend_stories" "$fe_id_map" | jq -s '
    .[0] as $stories | .[1] as $id_map |
    $stories | map(
      . as $story |
      ($story.dependsOn // []) as $pre |
      ($pre | length > 0) as $had_deps |
      ([$pre[] | select(($id_map[.] // null) == null)]) as $dropped_ids |
      $story
      | .id = ($id_map[.id] // .id)
      | .dependsOn = [$pre[] | . as $dep | ($id_map[$dep] // null) | select(. != null)]
      | .__droppedDeps = $dropped_ids
      | .__becameRoot = ($had_deps and (.dependsOn == []))
    )
  ')

  # Apply ID remap and rebuild dependsOn for backend (same cross-file capture).
  backend_stories=$(printf '%s\n%s' "$backend_stories" "$be_id_map" | jq -s '
    .[0] as $stories | .[1] as $id_map |
    $stories | map(
      . as $story |
      ($story.dependsOn // []) as $pre |
      ($pre | length > 0) as $had_deps |
      ([$pre[] | select(($id_map[.] // null) == null)]) as $dropped_ids |
      $story
      | .id = ($id_map[.id] // .id)
      | .dependsOn = [$pre[] | . as $dep | ($id_map[$dep] // null) | select(. != null)]
      | .__droppedDeps = $dropped_ids
      | .__becameRoot = ($had_deps and (.dependsOn == []))
    )
  ')

  # ============================================================
  # Cross-file dependsOn: audible drop surfacing
  # ============================================================
  # Every dependsOn entry that failed local resolution above is, by
  # construction, resolvable in the OTHER side's global_id_map -- the
  # earlier outline:NN remap + unresolved-outline check (before this
  # function runs) guarantees every dependsOn entry reaching this point
  # names a real story somewhere in the merged array. Build one
  # smellWarnings entry per affected story (both sides combined), with
  # every title sanitized via _rm_sanitize before it enters JSON or stderr.
  local cross_file_warnings
  cross_file_warnings=$(printf '%s\n%s\n%s' "$frontend_stories" "$backend_stories" "$global_id_map" | jq -s "$_ROADMAP_SANITIZE_JQ"'
    .[0] as $fe | .[1] as $be | .[2] as $gmap |
    ( [$fe[] | . + {__side: "frontend"}] + [$be[] | . + {__side: "backend"}] ) as $all |
    [
      $all[] | select((.__droppedDeps // []) | length > 0) |
      . as $story |
      (
        [
          ($story.__droppedDeps // [])[] | . as $old |
          ($gmap[$old] // {newId: $old, side: "unknown", title: ""}) |
          {id: .newId, side: .side, title: (.title | _rm_sanitize(200))}
        ]
      ) as $dd |
      {
        type: "cross-file-dep-dropped",
        storyId: $story.id,
        side: $story.__side,
        becameRoot: $story.__becameRoot,
        droppedDeps: $dd,
        message: (
          ($dd | length | tostring) + " cross-file dependsOn edge(s) dropped targeting: " +
          ($dd | map(.title) | join("; ")) +
          (if $story.__becameRoot then " (story became a false wave-1 root)" else "" end)
        )
      }
    ]
  ')

  # Merge into the Phase 4.2 smell_warnings param BEFORE it is threaded into
  # either output file build below, so both files carry the same combined set.
  local combined_smell_warnings
  combined_smell_warnings=$(printf '%s\n%s' "$smell_warnings" "$cross_file_warnings" | jq -s '.[0] + .[1]')

  # Aggregated stderr banner (never per-edge -- legitimate FE<->API edges and
  # --foundation's one-injected-edge-per-story would otherwise flood every
  # normal full-stack plan). One summary line with total dropped-edge count
  # and distinct-affected-story count (both sides combined), followed by one
  # enumeration line per FALSE-ROOT story only.
  local total_dropped affected_count
  total_dropped=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps | length] | add // 0')
  affected_count=$(printf '%s' "$cross_file_warnings" | jq 'length')
  if [ "$affected_count" -gt 0 ]; then
    echo "Warning: story-merge: ${total_dropped} cross-file dependsOn edge(s) dropped across ${affected_count} affected stories (--split full-stack; see metadata.smellWarnings)" >&2
    local false_root_lines
    false_root_lines=$(printf '%s' "$cross_file_warnings" | jq -r '
      .[] | select(.becameRoot == true) |
      (.storyId + " (" + .side + "): became a false wave-1 root -- its cross-file dependsOn target(s) " +
       ([.droppedDeps[] | (.id + " (" + .side + ")")] | join(", ")) + " were dropped")
    ')
    if [ -n "$false_root_lines" ]; then
      printf '%s\n' "$false_root_lines" >&2
    fi
  fi

  # Recompute waves independently per file
  frontend_stories=$(printf '%s' "$frontend_stories" | jq '
    reduce range(length) as $_ (
      map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')
  backend_stories=$(printf '%s' "$backend_stories" | jq '
    reduce range(length) as $_ (
      map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
      . as $current |
      map(
        if .wave > 0 then .
        else
          . as $story |
          ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
          if ($dep_waves | all(. > 0)) then
            . + {wave: (($dep_waves | max) + 1)}
          else
            .
          end
        end
      )
    )
  ')

  # Derive output paths
  local base_name ext fe_path be_path
  base_name=$(basename "$output_path")
  ext="${base_name##*.}"
  local base_no_ext="${base_name%.$ext}"
  # --phase-aware: the output basename for a phase-scoped invocation already
  # ends in "-tasks" (e.g. "<feature>-phase-<N>-tasks.json"). Strip that single
  # trailing "-tasks" segment once before appending "-frontend-tasks.json" /
  # "-backend-tasks.json" so the split basenames keep a single "tasks" segment
  # ("<feature>-phase-<N>-frontend-tasks.json") instead of doubling it. Default
  # (unflagged) derivation is untouched -- it keeps appending directly to the
  # full ".json"-stripped basename, preserving the existing double-"tasks"
  # legacy basename (e.g. "<slug>-tasks-frontend-tasks.json").
  if [ "$phase_aware" = true ]; then
    base_no_ext="${base_no_ext%-tasks}"
  fi
  local dir_part
  dir_part=$(dirname "$output_path")
  fe_path="${dir_part}/${base_no_ext}-frontend-tasks.json"
  be_path="${dir_part}/${base_no_ext}-backend-tasks.json"

  # Ensure output directory exists
  mkdir -p "$dir_part"

  # Build and write frontend tasks.json atomically
  # smellWarnings is injected only when non-empty; written to BOTH split files
  # (combined_smell_warnings = Phase 4.2 orphan-symbol + cross-file-dep-dropped)
  # so reviewers see the same full smell surface regardless of which file they
  # inspect first.
  local fe_json
  fe_json=$(printf '%s\n%s' "$frontend_stories" "$combined_smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks (frontend)",
          type: "feat",
          branchName: "feat/merged-frontend",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
    }
  ')
  local tmp_fe
  tmp_fe=$(mktemp "${fe_path}.XXXXXX")
  (
    _lock "${fe_path}.lock"
    printf '%s\n' "$fe_json" > "$tmp_fe"
    mv "$tmp_fe" "$fe_path"
  ) 200>"${fe_path}.lock"
  local fe_exit=$?
  rm -f "$tmp_fe" 2>/dev/null
  if [ $fe_exit -ne 0 ]; then
    echo "Error: story-merge: failed to write frontend output: $fe_path" >&2
    exit 1
  fi

  # Build and write backend tasks.json atomically
  local be_json
  be_json=$(printf '%s\n%s' "$backend_stories" "$combined_smell_warnings" | jq -s '
    .[0] as $stories | .[1] as $smells |
    {
      schemaVersion: "3.3",
      metadata: (
        {
          title: "feat: merged tasks (backend)",
          type: "feat",
          branchName: "feat/merged-backend",
          createdAt: (now | strftime("%Y-%m-%d")),
          planPath: null
        } +
        (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
      ),
      userStories: [$stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
    }
  ')
  local tmp_be
  tmp_be=$(mktemp "${be_path}.XXXXXX")
  (
    _lock "${be_path}.lock"
    printf '%s\n' "$be_json" > "$tmp_be"
    mv "$tmp_be" "$be_path"
  ) 200>"${be_path}.lock"
  local be_exit=$?
  rm -f "$tmp_be" 2>/dev/null
  if [ $be_exit -ne 0 ]; then
    echo "Error: story-merge: failed to write backend output: $be_path" >&2
    exit 1
  fi

  # On success: delete the staging dir
  rm -rf "$staging_dir"

  local fe_count_out be_count_out
  fe_count_out=$(printf '%s' "$frontend_stories" | jq 'length')
  be_count_out=$(printf '%s' "$backend_stories" | jq 'length')
  jq -n \
    --arg fe "$fe_path" \
    --arg be "$be_path" \
    --argjson fe_count "$fe_count_out" \
    --argjson be_count "$be_count_out" \
    '{frontend: $fe, backend: $be, frontend_stories: $fe_count, backend_stories: $be_count}'
}

# Write N split tasks files (full-stack mode, PROJECT axis: one file per repo).
#
# Chosen by cmd_story_merge when the merged array carries >= 2 distinct
# normalized .project values -- a multi-repo layout. There is no
# frontend/backend side decision on this path at all: the split axis IS the
# project, so every repo named by a story gets its own valid, non-colliding
# tasks file instead of being force-fit into two side files.
#
# All-or-nothing contract: every output path, slug, and branchName is derived
# and validated BEFORE the first write, so a collision or an invalid branch
# name lands zero files. Once the write loop starts, a mid-loop failure names
# the files already on disk and keeps the staging dir so a retry is unambiguous.
_story_merge_write_project_split() {
  local merged_array="$1"
  local output_path="$2"
  local staging_dir="$3"
  local smell_warnings="${4:-[]}"
  local phase_aware="${5:-false}"
  # Pre-remap id of the --foundation story, or "" when the flag was omitted.
  # Compared against the PRE-remap dropped-dep ids below (the same namespace),
  # so an empty value can never match a real story.
  local foundation_id="${6:-}"

  # ============================================================
  # 1. Route every story to a project group
  # ============================================================
  # Group key = group_key, the same def _story_merge_resolve_axis chose the
  # axis with. There is no fallback for a null key and there must not be one:
  # this writer is only ever reached on the PROJECT axis, which the resolver
  # enters only when every story is tagged, so group_key is non-null by
  # construction. A `// "."` here would be a second normalization rule one
  # function away from the first -- exactly the divergence that produced one
  # file and one branch for two repositories (issue #72).
  # Groups are emitted in lexicographic order by normalized project path
  # (jq's `unique` sorts by codepoint), never staging-glob or first-encountered
  # order.
  local group_keys
  group_keys=$(printf '%s' "$merged_array" | jq -c "$_STORY_MERGE_NORM_PROJECT_JQ"'
    [.[] | . as $s | ($s.project | group_key)] | unique
  ')

  # ============================================================
  # 2. Per-group id assignment + cross-group dependsOn sweep
  # ============================================================
  # Ids are reassigned US-001..US-M in group order, each group taking a
  # contiguous block (mirrors the frontend-then-backend offset scheme of
  # _story_merge_write_split), so ids stay unique across the whole N-file set.
  # A dependsOn edge that crosses a group boundary cannot survive -- its target
  # lives in another file -- so it is dropped and captured as __droppedDeps,
  # with __becameRoot flagging a story whose entire dependsOn list vanished.
  #
  # Every select()/map() pass binds its story via `. as $s` first: piping a
  # story into map/has() rebinds `.` away from the story object, which has
  # already broken a prior fix to this function.
  local prepared
  prepared=$(printf '%s\n%s' "$merged_array" "$group_keys" | jq -s \
    --arg foundation_id "$foundation_id" \
    "$_STORY_MERGE_NORM_PROJECT_JQ$_ROADMAP_SANITIZE_JQ"'
    def pad3: tostring | if length == 1 then "00" + . elif length == 2 then "0" + . else . end;
    def recompute_waves:
      reduce range(length) as $_ (
        map(. + {wave: (if (.dependsOn // []) == [] then 1 else 0 end)});
        . as $current |
        map(
          if .wave > 0 then .
          else
            . as $story |
            ([$story.dependsOn[] | . as $dep_id | ($current[] | select(.id == $dep_id) | .wave)] | if length == 0 then [0] else . end) as $dep_waves |
            if ($dep_waves | all(. > 0)) then
              . + {wave: (($dep_waves | max) + 1)}
            else
              .
            end
          end
        )
      );
    .[0] as $stories | .[1] as $keys |
    # Stories bucketed per group, preserving merged (outline) order inside
    # each bucket.
    [ $keys[] | . as $g |
      {project: $g, stories: [$stories[] | . as $s | select(($s.project | group_key) == $g)]}
    ] as $buckets |
    # Running offset -> contiguous US-NNN block per group, in group order.
    (reduce range($buckets | length) as $i ({offset: 0, out: []};
      .offset as $off |
      ($buckets[$i].stories) as $bs |
      {
        offset: ($off + ($bs | length)),
        out: (.out + [{
          project: $buckets[$i].project,
          idmap: ([$bs | to_entries[] | . as $e | {key: $e.value.id, value: ("US-" + (($off + $e.key + 1) | pad3))}] | from_entries),
          stories: $bs
        }])
      }
    ) | .out) as $blocks |
    # Global pre-remap-id -> {newId, project, title} map, built across EVERY
    # group before any dependsOn remap runs, so a dropped cross-group target
    # can still be named usefully (it exists in no single output file).
    ([$blocks[] | . as $b | ($b.stories[] | . as $s |
       {key: $s.id, value: {newId: ($b.idmap[$s.id] // $s.id), project: $b.project, title: $s.title}})]
     | from_entries) as $gmap |
    [$blocks[] | . as $b |
      {
        project: $b.project,
        stories: ([$b.stories[] | . as $s |
          ($s.dependsOn // []) as $pre |
          (($pre | length) > 0) as $had_deps |
          ([$pre[] | . as $d | select(($b.idmap[$d] // null) == null)]) as $dropped_ids |
          $s
          | .id = ($b.idmap[$s.id] // $s.id)
          | .dependsOn = [$pre[] | . as $dep | ($b.idmap[$dep] // null) | select(. != null)]
          | .__droppedDeps = $dropped_ids
          | .__becameRoot = ($had_deps and (.dependsOn == []))
        ] | recompute_waves)
      }
    ] as $remapped |
    # One cross-group dependsOn smellWarnings entry per affected story, every
    # title sanitized before it enters JSON or stderr.
    #
    # This axis keys every entry by `project` -- the routing key of the group
    # that owns it -- at BOTH the top level and in every droppedDeps[]. There is
    # no frontend/backend verdict on this path, so there is no `side` field to
    # emit; `side` remains exclusive to _story_merge_write_split. The two keys
    # are mutually exclusive per axis, which is what lets the Step 5 renderer
    # pick whichever one an entry actually carries.
    #
    # foundationEdge marks a dropped edge that --foundation itself injected
    # into every non-foundation story. In a multi-repo split the foundation
    # lives in exactly one group, so every OTHER group loses that edge and
    # would otherwise be indistinguishable from a hand-authored missing
    # dependency. $foundation_id is the PRE-remap id (same namespace as
    # $old), and is "" when --foundation was omitted -- no real id matches it.
    [$remapped[] | . as $b | ($b.stories[] | . as $s |
      select(($s.__droppedDeps // []) | length > 0) |
      ([($s.__droppedDeps // [])[] | . as $old |
         ($gmap[$old] // {newId: $old, project: "unknown", title: ""}) |
         {id: .newId, project: .project, title: (.title | _rm_sanitize(200)),
          foundationEdge: (($foundation_id != "") and ($old == $foundation_id))}]) as $dd |
      ($dd | map(select(.foundationEdge == true)) | length) as $fcount |
      {
        type: "cross-file-dep-dropped",
        storyId: $s.id,
        project: $b.project,
        becameRoot: $s.__becameRoot,
        droppedDeps: $dd,
        message: (
          ($dd | length | tostring) + " cross-file dependsOn edge(s) dropped targeting: " +
          ($dd | map(.title) | join("; ")) +
          (if $fcount > 0 then
             " -- " + ($fcount | tostring) + " of these targets the shared --foundation story (" +
             ($dd | map(select(.foundationEdge == true))
                  | map(.id + " in project \"" + .project + "\"") | join(", ")) +
             "), an edge --foundation injected into every story rather than a hand-authored dependency"
           else "" end) +
          (if $s.__becameRoot then " (story became a false wave-1 root)" else "" end)
        )
      })
    ] as $cross_warnings |
    {blocks: $remapped, crossWarnings: $cross_warnings}
  ')

  # Merge into the Phase 4.2 smell_warnings param BEFORE any file is built, so
  # every one of the N files carries the same combined set.
  local cross_file_warnings combined_smell_warnings
  cross_file_warnings=$(printf '%s' "$prepared" | jq -c '.crossWarnings')
  combined_smell_warnings=$(printf '%s\n%s' "$smell_warnings" "$cross_file_warnings" | jq -s '.[0] + .[1]')

  # Aggregated stderr banner (never per-edge), mirroring the SIDE writer: one
  # summary line, then one enumeration line per FALSE-ROOT story only.
  local total_dropped affected_count
  total_dropped=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps | length] | add // 0')
  affected_count=$(printf '%s' "$cross_file_warnings" | jq 'length')
  if [ "$affected_count" -gt 0 ]; then
    echo "Warning: story-merge: ${total_dropped} cross-project dependsOn edge(s) dropped across ${affected_count} affected stories (--split full-stack, project axis; see metadata.smellWarnings)" >&2

    # --foundation note: separate from the drop-count banner above, because
    # these edges are structurally different -- the merge itself injected
    # them, so every non-foundation project group losing one is expected
    # fallout of combining --foundation with a multi-repo split, not a sign of
    # a hand-authored dependency that went missing.
    local foundation_edge_count foundation_story_count
    foundation_edge_count=$(printf '%s' "$cross_file_warnings" | jq '[.[].droppedDeps[] | select(.foundationEdge == true)] | length')
    foundation_story_count=$(printf '%s' "$cross_file_warnings" | jq '[.[] | select((.droppedDeps // []) | any(.foundationEdge == true))] | length')
    if [ "${foundation_edge_count:-0}" -gt 0 ]; then
      echo "Note: story-merge: ${foundation_edge_count} of those edge(s), across ${foundation_story_count} stories, target the shared --foundation story, which lives in only one project group; --foundation injected them, so their loss is expected on a multi-repo split (see droppedDeps[].foundationEdge)" >&2
    fi

    local false_root_lines
    false_root_lines=$(printf '%s' "$cross_file_warnings" | jq -r '
      .[] | select(.becameRoot == true) |
      (.storyId + " (" + .project + "): became a false wave-1 root -- its cross-project dependsOn target(s) " +
       ([.droppedDeps[] | (.id + " (" + .project + ")")] | join(", ")) + " were dropped")
    ')
    if [ -n "$false_root_lines" ]; then
      printf '%s\n' "$false_root_lines" >&2
    fi
  fi

  # ============================================================
  # 3. Derive every output path / slug / branchName up front
  # ============================================================
  local base_name ext base_no_ext dir_part
  base_name=$(basename "$output_path")
  ext="${base_name##*.}"
  base_no_ext="${base_name%.$ext}"
  # --phase-aware: identical single-"tasks"-segment collapse the SIDE writer
  # applies. Pure string manipulation on the --output basename, independent of
  # the split axis, so it composes unchanged at any N.
  if [ "$phase_aware" = true ]; then
    base_no_ext="${base_no_ext%-tasks}"
  fi
  dir_part=$(dirname "$output_path")

  # slugify: a project path is NEVER interpolated raw into a filename. Every
  # character outside [A-Za-z0-9_-] (notably "/" and ".") becomes "-", runs
  # collapse, and leading/trailing "-" are trimmed; a value that flattens to
  # nothing (e.g. ".") becomes "root".
  local plan
  plan=$(printf '%s' "$prepared" | jq -c \
    --arg dir "$dir_part" \
    --arg base "$base_no_ext" '
    def slugify:
      (gsub("[^A-Za-z0-9_-]"; "-") | gsub("-+"; "-") | gsub("^-+|-+$"; "")) as $s |
      if $s == "" then "root" else $s end;
    .blocks | to_entries | map(
      . as $e | $e.value as $b | ($b.project | slugify) as $slug |
      {
        index: ($e.key + 1),
        # .project is carried through verbatim, never sanitized: it is the
        # routing key, and a lossy transform would make the key that groups
        # differ from the key that is written. Malformed values are refused
        # outright by _story_merge_resolve_axis, before this writer is reached.
        project: $b.project,
        slug: $slug,
        path: ($dir + "/" + $base + "-" + $slug + "-tasks.json"),
        branchName: ("feat/merged-" + $slug),
        storyCount: ($b.stories | length)
      }
    )
  ')

  # Basename collision: two distinct project values that flatten to the same
  # slug would silently overwrite each other. Hard-fail the WHOLE merge here,
  # before the first write, so zero output files land.
  local slug_collisions
  slug_collisions=$(printf '%s' "$plan" | jq -r '
    group_by(.slug) | map(select(length > 1)) | .[] |
    "  basename slug \"" + .[0].slug + "\" is shared by projects: " + (map(.project) | join(", "))
  ')
  if [ -n "$slug_collisions" ]; then
    echo "Error: story-merge: --split full-stack: distinct project values collide on the same output basename; no files were written:" >&2
    printf '%s\n' "$slug_collisions" >&2
    exit 1
  fi

  # Derived-name validation: every invariant the derived slug / path /
  # branchName must satisfy before a single file is opened. Abort the whole
  # merge on the first failure -- no partial write, no mangled fallback name.
  #
  # REFUSE, never truncate. Truncating two long project values to a common
  # prefix manufactures a slug collision, which the guard above would then
  # report as a basename conflict between projects that do not actually
  # conflict -- a wrong diagnosis for a limit the caller can fix directly.
  #
  # Legs, and why each limit is where it is:
  #   branchName regex  -- the invariant plan.md enforces before any git
  #                        operation. Currently unreachable given slugify's
  #                        output; kept because it costs one test() and is the
  #                        only thing standing between a future slugify edit
  #                        and a branch name handed to git unchecked.
  #   slug <= 64        -- plan.md rewrites branchName to a ~87-char prefix in
  #                        phase mode; 87 + 64 stays inside every downstream
  #                        limit.
  #   basename <= 248   -- NAME_MAX (255) minus the 7 bytes mktemp appends for
  #                        ".XXXXXX". This is the leg that actually prevents a
  #                        mid-loop mktemp death, and it has to be checked on
  #                        the basename rather than the slug because most of
  #                        that basename comes from --output, not from .project.
  #   path <= 4000      -- PATH_MAX (4096) with headroom for the lock/tmp
  #                        suffixes appended to it.
  #   branchName <= 100 -- worktree-manager places a worktree as a single
  #                        directory component, so branchName feeds a
  #                        NAME_MAX-bounded name downstream.
  local bad_derived
  bad_derived=$(printf '%s' "$plan" | jq -r --arg re "$_ROADMAP_BRANCH_REGEX" '
    .[] | . as $g |
    ($g.path | split("/") | last) as $base |
    [
      (if ($g.branchName | test($re)) then empty
       else "derived branchName failed validation against " + $re + ": " + $g.branchName end),
      (if ($g.slug | length) > 64 then
         "derived basename slug is " + (($g.slug | length) | tostring) + " chars (limit 64): " + $g.slug
       else empty end),
      (if ($base | length) > 248 then
         "derived output basename is " + (($base | length) | tostring) +
         " chars (limit 248 = NAME_MAX 255 minus the 7-char mktemp suffix): " + $base
       else empty end),
      (if ($g.path | length) > 4000 then
         "derived output path is " + (($g.path | length) | tostring) + " chars (limit 4000)"
       else empty end),
      (if ($g.branchName | length) > 100 then
         "derived branchName is " + (($g.branchName | length) | tostring) + " chars (limit 100): " + $g.branchName
       else empty end)
    ] | .[] | "  project \"" + $g.project + "\": " + .
  ')
  if [ -n "$bad_derived" ]; then
    echo "Error: story-merge: --split full-stack: derived output name(s) failed validation; no files were written (shorten the offending project value -- names are refused, never truncated, because truncation would manufacture a basename collision between two distinct projects):" >&2
    printf '%s\n' "$bad_derived" >&2
    exit 1
  fi

  # ============================================================
  # 4. Write every group's file atomically
  # ============================================================
  mkdir -p "$dir_part"

  local group_total
  group_total=$(printf '%s' "$plan" | jq 'length')

  local written_paths=""
  local idx=0
  while [ "$idx" -lt "$group_total" ]; do
    # tmp_group and write_exit are declared at their use site below, where the
    # initialization they need is part of the same statement.
    local group_path group_json
    group_path=$(printf '%s' "$plan" | jq -r --argjson i "$idx" '.[$i].path')

    # metadata.splitGroup is the self-describing marker for this file's place
    # in the N-way split: its own project, its 1-based index, the total, and
    # every sibling file's path. Downstream consumers discover the full set
    # from it instead of re-deriving it from filename string conventions.
    group_json=$(printf '%s\n%s\n%s' "$prepared" "$plan" "$combined_smell_warnings" | jq -s --argjson i "$idx" '
      .[0] as $prep | .[1] as $plan | .[2] as $smells |
      $plan[$i] as $g |
      $prep.blocks[$i] as $b |
      {
        schemaVersion: "3.3",
        metadata: (
          {
            title: ("feat: merged tasks (" + $g.slug + ")"),
            type: "feat",
            branchName: $g.branchName,
            createdAt: (now | strftime("%Y-%m-%d")),
            planPath: null,
            splitGroup: {
              project: $g.project,
              index: $g.index,
              total: ($plan | length),
              siblings: [$plan[] | . as $sib | select($sib.index != $g.index) | $sib.path]
            }
          } +
          (if ($smells | length) > 0 then {smellWarnings: $smells} else {} end)
        ),
        userStories: [$b.stories[] | del(.referenceInventory) | del(.ac_anchors) | del(._fe) | del(._side) | del(.__droppedDeps) | del(.__becameRoot) | (.status //= "pending")]
      }
    ')

    # This script runs `set -euo pipefail`. A bare failing compound command
    # exits the shell immediately, so a `write_exit=$?` on the NEXT line is
    # unreachable and the whole error branch below with it -- which is exactly
    # how a failed group write used to leave one file on disk advertising
    # `total: 3` with two siblings that do not exist, an orphaned mktemp file,
    # and no message at all.
    #
    # Three details keep this reachable, and all three are load-bearing:
    #   1. `write_exit=0` is a real initialization. `-u` is on, and a bare
    #      `local write_exit` leaves it declared-but-unset, which makes
    #      `[ "$write_exit" -ne 0 ]` an unbound-variable error rather than a
    #      false. It is also never `local write_exit=$?`: `local` is a builtin
    #      and its own exit status overwrites `$?` before the assignment reads it.
    #   2. The `|| write_exit=$?` makes the subshell the left side of an AND-OR
    #      list, the one construct `set -e` is defined to exempt. The `200>`
    #      redirect stays attached to the subshell, BEFORE the `||`, so a lock
    #      path that cannot be opened (e.g. a directory) is a failure of the
    #      exempted command rather than of the list.
    #   3. mktemp gets the same treatment. It fails on ENOSPC/EACCES, and a
    #      bare failing assignment is just as fatal under `set -e`.
    local tmp_group=""
    tmp_group=$(mktemp "${group_path}.XXXXXX" 2>/dev/null) || tmp_group=""
    local write_exit=0
    if [ -z "$tmp_group" ]; then
      write_exit=1
    else
      (
        _lock "${group_path}.lock"
        printf '%s\n' "$group_json" > "$tmp_group"
        mv "$tmp_group" "$group_path"
      ) 200>"${group_path}.lock" || write_exit=$?
      [ -n "$tmp_group" ] && rm -f "$tmp_group" 2>/dev/null || true
    fi
    if [ "$write_exit" -ne 0 ]; then
      # Enumerate all THREE sets. The surviving files are the actionable part:
      # each one advertises a splitGroup.total and a siblings[] list describing
      # a complete N-way split that does not exist on disk, so the reader needs
      # to know precisely which of those siblings landed and which never will.
      local not_attempted remaining
      remaining=$((group_total - idx - 1))
      echo "Error: story-merge: failed to write project split output: $group_path" >&2
      echo "  Written before this failure (${idx}):" >&2
      if [ -n "$written_paths" ]; then
        printf '%s\n' "$written_paths" >&2
      else
        echo "    (none)" >&2
      fi
      echo "  Failed:" >&2
      echo "    $group_path" >&2
      echo "  Not attempted (${remaining}):" >&2
      if [ "$remaining" -gt 0 ]; then
        not_attempted=$(printf '%s' "$plan" | jq -r --argjson i "$idx" '.[($i + 1):][] | "    " + .path')
        printf '%s\n' "$not_attempted" >&2
      else
        echo "    (none)" >&2
      fi
      echo "  Staging dir preserved for retry:" >&2
      echo "    $staging_dir" >&2
      exit 1
    fi
    if [ -n "$written_paths" ]; then
      written_paths="${written_paths}"$'\n'"    ${group_path}"
    else
      written_paths="    ${group_path}"
    fi
    idx=$((idx + 1))
  done

  # On success (all N writes landed): delete the staging dir
  rm -rf "$staging_dir"

  printf '%s' "$plan" | jq '[.[] | {path, project, branchName, storyCount}]'
}

# ============================================================================
# split-detect — the read side of metadata.splitGroup
# ============================================================================
#
# _story_merge_write_project_split (above) stamps every file it emits with a
# self-describing metadata.splitGroup marker. This is the consumer: given a
# scope, it answers "do the tasks files here form ONE group that must execute
# together, and which members still have work?".
#
# It lives here rather than in /aimi:execute's markdown because every rule it
# encodes -- anchor selection, sibling resolution, total validation, active
# filtering, legacy-pair fallback -- is pure, deterministic, file-only logic.
# Written as executable prose it was unreachable by both Bash test suites, and
# it drifted into two divergent copies (flat flow vs. phase mode). Here one
# copy serves both scopes and every rule is a test case.
#
# It is a QUERY, not a gate: every outcome, including "single" and "none",
# exits 0. Non-zero is reserved for real errors (bad argument, unreadable dir).

# A story is pending when its status is anything other than "completed".
# Exactly one definition, used for every count this verb reports. The prose
# it replaces had two that disagreed -- `!= "completed"` for the active filter
# and `== "pending"` for the phase completion count -- so an in_progress story
# was counted by one and not the other, which let a phase close with work
# still in flight.
_SPLIT_DETECT_DESCRIBE_JQ='
  (if type == "object" then . else {} end) as $doc
| (if ($doc.metadata | type) == "object" then $doc.metadata else {} end) as $m
| (if ($m.splitGroup | type) == "object" then $m.splitGroup else {} end) as $sg
| {
    path: $path,
    project: (if ($sg.project | type) == "string" then $sg.project else "." end),
    branchName: (if ($m.branchName | type) == "string" then $m.branchName else null end),
    storyCount: (if ($doc.userStories | type) == "array"
                 then ($doc.userStories | length) else 0 end),
    pendingCount: (if ($doc.userStories | type) == "array"
                   then ([$doc.userStories[]
                          | select((.status? // "pending") != "completed")] | length)
                   else 0 end),
    hasMarker: (($sg.total | type) == "number" and ($sg.siblings | type) == "array"),
    declaredTotal: (if ($sg.total | type) == "number" then ($sg.total | tostring) else "" end),
    siblings: (if ($sg.siblings | type) == "array"
               then [$sg.siblings[] | tostring] else [] end)
  }
| . + {active: (.pendingCount > 0)}
'

# Emit one compact JSON descriptor for a candidate tasks file.
# A file that is unreadable or not valid JSON yields an inert descriptor
# (no marker, no stories) instead of aborting: one corrupt file sitting in
# .aimi/tasks/ must not take detection down for every other feature.
_split_detect_describe() {
  local file="$1"
  local desc=""
  desc=$(jq -c --arg path "$file" "$_SPLIT_DETECT_DESCRIBE_JQ" "$file" 2>/dev/null) || desc=""
  if [ -z "$desc" ]; then
    desc=$(jq -nc --arg path "$file" '{path: $path, project: ".", branchName: null,
      storyCount: 0, pendingCount: 0, hasMarker: false, declaredTotal: "",
      siblings: [], active: false}')
  fi
  printf '%s' "$desc"
}

# List *-tasks.json files directly inside <dir> (depth 1 only), newest mtime
# first. NUL-delimited find -> xargs -0 keeps paths containing spaces intact,
# the same hardening _find_tasks_files_all carries; a newline-delimited
# `xargs ls -t` word-splits them and silently returns nothing.
_split_detect_list_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*-tasks.json' -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null || true
}

# Derive the phase's own governing tasks file from a phase directory, so it can
# be excluded from the split candidate pool. Layout is
# .aimi/tasks/<feature>/phase-<N>[.<M>][-<slug>]/<feature>-phase-<N>-tasks.json.
# Prints nothing when <dir> is not shaped like a phase directory (nothing to
# exclude then, which is the safe direction: an extra candidate is still
# filtered by the marker and pair rules below).
_split_detect_phase_main_file() {
  local dir="$1"
  local dir_base feature phase_id
  dir_base=$(basename "$dir")
  case "$dir_base" in
    phase-[0-9]*) ;;
    *) return 0 ;;
  esac
  phase_id=${dir_base#phase-}
  phase_id=${phase_id%%-*}
  case "$phase_id" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  feature=$(basename "$(dirname "$dir")")
  [ -n "$feature" ] || return 0
  printf '%s/%s-phase-%s-tasks.json' "$dir" "$feature" "$phase_id"
}

cmd_split_detect() {
  local scope_dir=""
  local dir_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Error: split-detect: --dir requires a directory path" >&2
          exit 1
        fi
        scope_dir="$2"
        dir_mode=true
        shift 2
        ;;
      *)
        echo "Error: split-detect: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # 1. Build the candidate pool, newest mtime first
  # ------------------------------------------------------------------
  local candidates=""
  local exclude_file=""
  if [ "$dir_mode" = true ]; then
    if [ ! -d "$scope_dir" ]; then
      echo "Error: split-detect: --dir is not a directory: $scope_dir" >&2
      exit 1
    fi
    scope_dir=$(resolve_path "$scope_dir")
    validate_path_in_project "$scope_dir"
    exclude_file=$(_split_detect_phase_main_file "$scope_dir")
    candidates=$(_split_detect_list_dir "$scope_dir")
  else
    # Flat scope is depth 1 ONLY: candidates are the *-tasks.json files whose
    # parent directory is $TASKS_DIR itself. _find_tasks_files_all globs depth
    # 1-3, which includes every phase directory -- and that is exactly how a
    # phase's split files used to be captured by the flat flow and executed as
    # a flat split, leaving the phase unclaimed and nothing merged into the
    # phase branch. The filter below is the fix, and it is load-bearing.
    local all_files=""
    all_files=$(_find_tasks_files_all)
    if [ -n "$all_files" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$(dirname "$f")" = "$TASKS_DIR" ] || continue
        candidates="${candidates}${f}"$'\n'
      done <<< "$all_files"
    fi
  fi

  local pool="[]"
  if [ -n "$candidates" ]; then
    local cand desc
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ -n "$exclude_file" ] && [ "$cand" = "$exclude_file" ] && continue
      desc=$(_split_detect_describe "$cand")
      pool=$(printf '%s' "$pool" | jq -c --argjson d "$desc" '. + [$d]')
    done <<< "$candidates"
  fi

  local started_empty=false
  [ "$(printf '%s' "$pool" | jq 'length')" -eq 0 ] && started_empty=true

  # ------------------------------------------------------------------
  # 2. Resolve the group
  # ------------------------------------------------------------------
  # "Newest wins": the anchor is the newest candidate, not the first
  # marker-carrying file in mtime order. The old rule let a stale marked split
  # from a past feature preempt today's plan whenever today's files carried no
  # marker of their own.
  local mode="none"
  local anchor="null"
  local members="[]"
  local declared_total="0"
  local degraded_reason=""

  # AIMI_ROOT-is-a-git-repo check, computed once. find_aimi_root() already cd'd
  # the process to AIMI_ROOT before cmd_split_detect ever runs (dispatch at
  # line ~9167 happens after the find_aimi_root call at ~9116), and --dir only
  # narrows the candidate pool below -- it never changes CWD. So $PWD here is
  # AIMI_ROOT in both flat and --dir scope, and this is the identical check
  # commands/execute.md documents as the canonical AIMI_ROOT_IS_GIT_REPO rule.
  local aimi_root_is_git=true
  git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1 || aimi_root_is_git=false

  while :; do
    local pool_len=0
    pool_len=$(printf '%s' "$pool" | jq 'length')
    if [ "$pool_len" -eq 0 ]; then
      mode="none"
      if [ "$started_empty" != true ] && [ -z "$degraded_reason" ]; then
        degraded_reason="every candidate group is already fully completed"
      fi
      break
    fi

    local newest newest_path newest_dir newest_marker
    newest=$(printf '%s' "$pool" | jq -c '.[0]')
    newest_path=$(printf '%s' "$newest" | jq -r '.path')
    newest_dir=$(dirname "$newest_path")
    newest_marker=$(printf '%s' "$newest" | jq -r '.hasMarker')

    local group="[]"
    local group_mode=""
    local group_total="0"

    if [ "$newest_marker" = "true" ]; then
      # -- Marked group: the members are the anchor plus its OWN declared
      #    siblings. Nothing else in the pool participates, however similar
      #    its basename. Each sibling resolves BY BASENAME against the
      #    anchor's own directory, which is what renders a traversal-shaped
      #    sibling entry inert: "../../etc/passwd" becomes "<anchor-dir>/passwd",
      #    which does not exist, and the group is voided.
      local anchor_total="" resolve_ok=true bad_detail=""
      anchor_total=$(printf '%s' "$newest" | jq -r '.declaredTotal')
      group="[$newest]"

      case "$anchor_total" in
        ''|*[!0-9]*)
          resolve_ok=false
          bad_detail="declared total is not a whole number: \"${anchor_total}\""
          ;;
      esac

      if [ "$resolve_ok" = true ]; then
        local sib sib_path sib_desc dup
        while IFS= read -r sib; do
          [ -n "$sib" ] || continue
          sib_path="$newest_dir/$(basename "$sib")"
          if [ ! -f "$sib_path" ]; then
            resolve_ok=false
            bad_detail="declared sibling not found in the anchor's directory: $sib_path"
            break
          fi
          dup=$(printf '%s' "$group" | jq -r --arg p "$sib_path" '[.[] | select(.path == $p)] | length')
          if [ "$dup" -ne 0 ]; then
            resolve_ok=false
            bad_detail="declared sibling resolves to a member already in the group: $sib_path"
            break
          fi
          sib_desc=$(_split_detect_describe "$sib_path")
          group=$(printf '%s' "$group" | jq -c --argjson d "$sib_desc" '. + [$d]')
        done <<< "$(printf '%s' "$newest" | jq -r '.siblings[]')"
      fi

      local resolved=0
      resolved=$(printf '%s' "$group" | jq 'length')
      if [ "$resolve_ok" != true ] || [ "$resolved" -ne "$anchor_total" ] || [ "$resolved" -lt 2 ]; then
        # A group that fails validation degrades to single-file execution and
        # is TERMINAL -- it deliberately does not fall through to the legacy
        # pair rule. This scope was planned by the project-split writer, so any
        # -frontend-/-backend-tasks.json sitting beside it is stale, and running
        # it would execute the wrong work.
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        degraded_reason="split group anchored at ${newest_path} is unusable (declared total ${anchor_total:-?}, resolved ${resolved}"
        if [ -n "$bad_detail" ]; then
          degraded_reason="${degraded_reason}; ${bad_detail}"
        fi
        degraded_reason="${degraded_reason}) — degraded to single-file execution, legacy pair not considered"
        break
      fi

      group_mode="project-split"
      group_total="$anchor_total"
    else
      # -- No marker on the newest candidate: try the legacy
      #    -frontend-tasks.json / -backend-tasks.json pair rule over the pool.
      #    The counterpart must be in the pool, not merely on disk, so the
      #    scope (flat depth 1, or this one phase directory) still bounds it.
      local newest_base prefix fe_path be_path
      newest_base=$(basename "$newest_path")
      prefix=""
      fe_path=""
      be_path=""
      case "$newest_base" in
        *-frontend-tasks.json)
          prefix="${newest_base%-frontend-tasks.json}"
          fe_path="$newest_path"
          be_path="$newest_dir/${prefix}-backend-tasks.json"
          ;;
        *-backend-tasks.json)
          prefix="${newest_base%-backend-tasks.json}"
          be_path="$newest_path"
          fe_path="$newest_dir/${prefix}-frontend-tasks.json"
          ;;
      esac

      local counterpart=""
      if [ -n "$prefix" ]; then
        if [ "$fe_path" = "$newest_path" ]; then counterpart="$be_path"; else counterpart="$fe_path"; fi
        local in_pool
        in_pool=$(printf '%s' "$pool" | jq -r --arg p "$counterpart" '[.[] | select(.path == $p)] | length')
        [ "$in_pool" -eq 0 ] && counterpart=""
      fi

      if [ -n "$counterpart" ]; then
        if [ "$aimi_root_is_git" != true ]; then
          # A legacy frontend/backend pair with no metadata.splitGroup marker
          # resolves to the root routing key "." (_SPLIT_DETECT_DESCRIBE_JQ's
          # default at 6459) -- fine in a single-repo layout, but AIMI_ROOT
          # here is not a git repository at all: a parent folder holding
          # multiple git repos as subfolders, with no repository underneath
          # "." to execute in. Refuse instead of binding to it. Reuses the
          # same mode=none-plus-degradedReason shape as the exhausted-pool
          # case above -- no new mode value, no new emitted field.
          mode="none"
          anchor="null"
          members="[]"
          declared_total="0"
          degraded_reason="AIMI_ROOT (${PWD}) is not a git repository — this is a multi-repo layout, a parent folder holding multiple git repositories as subfolders. The legacy pair ${fe_path} / ${be_path} has no metadata.splitGroup marker and would route to the root group \".\", which has no repository to execute in. Re-plan with --split full-stack so every story carries its own project, then re-run."
          break
        fi
        # Frontend first, backend second — the order the two-file writer and
        # every downstream report already assume.
        group=$(printf '%s' "$pool" | jq -c --arg fe "$fe_path" --arg be "$be_path" \
          '[(.[] | select(.path == $fe)), (.[] | select(.path == $be))]')
        group_mode="paired-split"
        group_total="2"
      else
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        break
      fi
    fi

    # A group with nothing left to do is not this run's work. Drop ALL of its
    # members from the pool and look again, rather than letting a completed
    # stale split route today's real work to a single-file fallback.
    local group_active=0
    group_active=$(printf '%s' "$group" | jq '[.[] | select(.active)] | length')
    if [ "$group_active" -eq 0 ]; then
      pool=$(printf '%s\n%s' "$pool" "$group" | jq -sc '
        .[1] as $g | [.[0][] | select(.path as $p | ($g | map(.path) | index($p)) == null)]')
      continue
    fi

    mode="$group_mode"
    anchor=$(printf '%s' "$newest" | jq -c '.path')
    members="$group"
    declared_total="$group_total"
    break
  done

  # ------------------------------------------------------------------
  # 3. Emit
  # ------------------------------------------------------------------
  printf '%s' "$members" | jq \
    --arg mode "$mode" \
    --argjson anchor "$anchor" \
    --argjson total "$declared_total" \
    --arg reason "$degraded_reason" \
    '{
      mode: $mode,
      anchor: $anchor,
      members: [.[] | {path, project, branchName, storyCount, pendingCount, active}],
      activeCount: ([.[] | select(.active)] | length),
      total: $total,
      degradedReason: (if ($reason | length) > 0 then $reason else null end)
    }'
}

# ============================================================================
# Roadmap Lifecycle Subcommands (Phase/Milestone layer for large-scope features)
# ============================================================================
#
# roadmap.json lives at .aimi/tasks/<feature>/roadmap.json and tracks phase
# lifecycle state (pending -> planned -> in_progress -> completed, or ->
# verification_failed) plus PID-alive claims so parallel /aimi:execute
# sessions can safely claim independent phases without hallucinated bash.
# Every write is a locked read-modify-write (mkdir-then-lock-then-tmpfile-
# then-move), mirroring _story_merge_write_legacy. flock is held only for
# the duration of each atomic operation -- never across separate CLI calls.

# Single-path-component pattern for a phase's dir field: phase-N[.M][-slug]
_ROADMAP_DIR_REGEX='^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$'
# Single-path-component pattern for the --feature slug (no slash, no dotdot)
_ROADMAP_FEATURE_REGEX='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
# Reused branchName convention (see plugins/aimi-engineering/CLAUDE.md)
_ROADMAP_BRANCH_REGEX='^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'

# jq `def` spliced into programs that sanitize free-text roadmap fields
# (name, goal, successCriteria entries, notes, branch, brainstormPath).
# Strips code fences/backtick content, newlines, "$(" command-substitution
# openers, HTML/XML tags, and common instruction-override phrases, then
# truncates to maxlen. Mirrors commands/references/sanitization.md plus the
# explicit newline/dollar-paren stripping called for in this story's notes.
_ROADMAP_SANITIZE_JQ='
def _rm_sanitize(maxlen):
  if . == null then null else
  ( .
    | gsub("```[\\s\\S]*?```"; "")
    | gsub("`[^`\n]*`"; "")
    | gsub("`"; "")
    | gsub("\r\n|\r|\n"; " ")
    | gsub("\\$\\("; "")
    | gsub("<[^>]*>"; "")
    | gsub("ignore previous( instructions)?"; ""; "i")
    | gsub("you are now"; ""; "i")
    | gsub("system\\s*:"; ""; "i")
    | if (length > maxlen) then .[0:maxlen] else . end
  ) end;
'

# Process-liveness probe, ported from guard-runtime-state.py is_alive() (lines 26-34):
# signal-zero kill probe. "No such process" -> not alive. "Exists, no permission
# to signal" -> alive (mirrors ProcessLookupError=False / PermissionError=True).
_is_pid_alive() {
  local pid="$1"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 0 ]; then
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local err
  err=$(kill -0 "$pid" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qi "not permitted"; then
    return 0
  fi
  return 1
}

# Validate --feature is present and a safe single path component.
_roadmap_validate_feature() {
  local feature="$1"
  if [ -z "$feature" ]; then
    echo "Error: roadmap: --feature <slug> is required" >&2
    exit 1
  fi
  if ! [[ "$feature" =~ $_ROADMAP_FEATURE_REGEX ]]; then
    echo "Error: roadmap: --feature must be a single path component matching $_ROADMAP_FEATURE_REGEX, got: $feature" >&2
    exit 1
  fi
}

# Compute the roadmap.json path for a feature (absolute, under TASKS_DIR).
_roadmap_path() {
  local feature="$1"
  printf '%s/%s/roadmap.json\n' "$TASKS_DIR" "$feature"
}

# Shared roadmap-verb preamble: resolve the path, validate it's in-project,
# and fail with a verb-prefixed message if the roadmap is missing or malformed.
# Echoes the resolved path on success. Usage:
#   roadmap_path=$(_roadmap_require <verb> <feature> [not-found-suffix] [--skip-malformed])
# not-found-suffix is appended verbatim to the "roadmap not found" message
# (e.g. " (run roadmap-init first)"); pass "" to omit it.
# --skip-malformed omits the malformed-json check (roadmap-release-claim never
# had one; preserved as-is rather than newly introduced here).
# Several callers re-check malformed-ness a second time inside their _lock
# subshell -- that inner check is deliberate (it re-reads under the lock to
# catch a file that turns malformed between this call and lock acquisition)
# and is not replaced by this helper.
_roadmap_require() {
  local verb="$1" feature="$2" suffix="${3:-}" skip_malformed="${4:-}"
  local path
  path=$(_roadmap_path "$feature")
  validate_path_in_project "$path"
  if [ ! -f "$path" ]; then
    echo "Error: $verb: roadmap not found: $path${suffix}" >&2
    exit 1
  fi
  if [ "$skip_malformed" != "--skip-malformed" ]; then
    if ! jq -e . "$path" >/dev/null 2>&1; then
      echo "Error: $verb: malformed roadmap.json: $path" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$path"
}

# Validate --phase is present and a bare numeric id (int or one-decimal-place).
_roadmap_validate_phase_id() {
  local phase_id="$1"
  local label="$2"
  if [ -z "$phase_id" ] || ! [[ "$phase_id" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: $label: --phase <id> must be a numeric phase id" >&2
    exit 1
  fi
}

# Read a phases JSON array on stdin; print one human-readable error line per
# creates[]/needs[] entry whose *identity* can never name a real artifact.
#
# The rule is deliberately narrow -- exactly three shapes are rejected, judged
# over the identity (text before the first "(", trimmed) and nothing else:
#   (a) empty after _cv_identity
#   (b) a ".." PATH SEGMENT, i.e. (^|/)\.\.($|/) -- not any byte pair "..",
#       so an identity like services/foo..bar is untouched
#   (c) a leading "/" anchored at position 0 -- the Endpoint kind
#       ("POST /api/notifications") contains a slash but does not begin with
#       one, so anchoring matters or every endpoint phase becomes unwritable
# Identity *strength* is explicitly not judged: at declaration time research has
# not run, so a bare Table name ("notifications") or a bare directory
# ("db/migrations") must pass -- guessing a path here fails at phase close for a
# reason nobody can debug.
#
# creates[] and needs[] go through the same predicate in the same pass on
# purpose: _cv_creates_in_scope matches a need against a provider's creates by
# exact byte equality, so a rule applied to one list alone lets a roadmap hold
# two shapes at once -- validate-contracts then reports a permanently unmet
# need, which halts /aimi:plan, and agent mode never demotes an unmet need.
#
# Reuses $_CONTRACT_JQ_DEFS so the guard and validate-contracts agree on what an
# identity is; a second copy of _cv_identity would drift.
_roadmap_identity_errors() {
  jq -r "$_CONTRACT_JQ_DEFS"'
    [ .[]
      | . as $p
      | (["creates", "needs"][]) as $list
      | (($p[$list] // [])[]) as $raw
      | ($raw | if type == "string" then . else "" end) as $entry
      | ($entry | _cv_identity) as $ident
      | (
          if ($ident | length) == 0 then "empty once the description is stripped"
          elif ($ident | test("(^|/)\\.\\.($|/)")) then "contains a \"..\" path segment"
          elif ($ident | test("^/")) then "begins with \"/\""
          else empty end
        ) as $reason
      | "phase " + ($p.id|tostring) + ": " + $list + " entry \"" + $entry + "\" is not a usable artifact identity: " + $reason
    ] | .[]
  '
}

cmd_roadmap_init() {
  local feature="" file="" sync_mode=false brainstorm_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      --sync) sync_mode=true ;;
      --brainstorm-path) shift; brainstorm_path="${1:-}" ;;
      *)
        echo "Error: roadmap-init: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_path "$feature")
  validate_path_in_project "$roadmap_path"

  # --- Read the phases array from --file or stdin ---
  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-init: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  if ! printf '%s' "$input_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Error: roadmap-init: phases payload must be a JSON array" >&2
    exit 1
  fi

  # --- Structural validation (payload-only; no I/O yet). Dangling dependsOn refs
  # are checked later, inside the lock, against existing-file ids unioned with
  # this payload's ids -- so a --sync phase may legitimately depend on a phase
  # materialized by an earlier roadmap-init call. ---
  local validation_errors
  validation_errors=$(printf '%s' "$input_json" | jq -r '
    . as $phases |
    ([$phases[] | .id]) as $ids |
    ([$ids | group_by(.) | map(select(length > 1)) | map(.[0])[]]) as $dup_ids |
    [
      ($dup_ids[] | "duplicate phase id: " + (.|tostring)),
      ($phases[] | . as $p | if ($p.id == null or ($p.id|type) != "number") then "phase " + ($p.id|tostring) + ": id must be a number" else empty end),
      ($phases[] | . as $p | if ($p.name == null or ($p.name|type) != "string" or ($p.name|length) == 0) then "phase " + ($p.id|tostring) + ": name is required" else empty end),
      ($phases[] | . as $p | if ($p.goal == null or ($p.goal|type) != "string" or ($p.goal|length) == 0) then "phase " + ($p.id|tostring) + ": goal is required" else empty end),
      ($phases[] | . as $p | if ($p.dependsOn != null and ($p.dependsOn|type) != "array") then "phase " + ($p.id|tostring) + ": dependsOn must be an array" else empty end),
      ($phases[] | . as $p | (($p.dependsOn // [])[] | select(type != "number") | "phase " + ($p.id|tostring) + ": dependsOn entries must be numbers"))
    ] | .[]
  ')
  if [ -n "$validation_errors" ]; then
    echo "Error: roadmap-init: invalid phase payload:" >&2
    printf '%s\n' "$validation_errors" >&2
    exit 1
  fi

  # --- Sanitize free-text fields, compute dir, validate dir + branch patterns ---
  local new_phases
  new_phases=$(printf '%s' "$input_json" | jq "$_ROADMAP_SANITIZE_JQ"'
    map(
      .name = (.name | _rm_sanitize(200)) |
      .goal = (.goal | _rm_sanitize(2000)) |
      .slug = ((.slug // "") | _rm_sanitize(100)) |
      .notes = (if .notes != null then (.notes | _rm_sanitize(5000)) else null end) |
      .successCriteria = ((.successCriteria // []) | map(_rm_sanitize(2000))) |
      .creates = ((.creates // []) | map(_rm_sanitize(500))) |
      .needs = ((.needs // []) | map(_rm_sanitize(500))) |
      .areas = ((.areas // []) | map(_rm_sanitize(500))) |
      .dependsOn = (.dependsOn // []) |
      .branch = (if .branch != null then (.branch | _rm_sanitize(200)) else null end) |
      .dir = ("phase-" + (.id|tostring) + (if (.slug|length) > 0 then "-" + .slug else "" end)) |
      .status = "pending" |
      .claim = null
    )
  ')

  local dir_errors
  dir_errors=$(printf '%s' "$new_phases" | jq -r --arg re "$_ROADMAP_DIR_REGEX" '
    [.[] | select((.dir | test($re)) | not) | "phase " + (.id|tostring) + ": computed dir \"" + .dir + "\" fails required pattern"] | .[]
  ')
  if [ -n "$dir_errors" ]; then
    echo "Error: roadmap-init: invalid phase directory slug(s):" >&2
    printf '%s\n' "$dir_errors" >&2
    exit 1
  fi

  local branch_errors
  branch_errors=$(printf '%s' "$new_phases" | jq -r --arg re "$_ROADMAP_BRANCH_REGEX" '
    [.[] | select(.branch != null and ((.branch | test($re)) | not)) | "phase " + (.id|tostring) + ": branch \"" + .branch + "\" contains invalid characters"] | .[]
  ')
  if [ -n "$branch_errors" ]; then
    echo "Error: roadmap-init: invalid branch name(s):" >&2
    printf '%s\n' "$branch_errors" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$roadmap_path")"

  # --- Locked read-modify-write: existence/--sync check, additive merge, atomic write ---
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if [ -f "$roadmap_path" ]; then
        if [ "$sync_mode" != true ]; then
          echo "Error: roadmap-init: $roadmap_path already exists; pass --sync to merge additively" >&2
          exit 1
        fi
        if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
          echo "Error: roadmap-init: existing roadmap.json is malformed: $roadmap_path" >&2
          exit 1
        fi

        existing_meta=$(jq '{roadmapVersion, feature, createdAt, brainstormPath}' "$roadmap_path")
        filtered_new=$(jq --argjson new "$new_phases" '
          [.phases[].id] as $eids | [$new[] | select((.id as $i | $eids | index($i)) == null)]
        ' "$roadmap_path")

        # Dangling dependsOn check: allowed ids are existing-file ids unioned with
        # this payload's own ids (covers both already-materialized phases and
        # sibling phases introduced in this same call).
        dangling=$(jq --argjson new "$new_phases" --argjson add "$filtered_new" -r '
          ([.phases[].id] + [$new[].id] | unique) as $ids |
          [$add[] | . as $p | ($p.dependsOn // [])[] | select((. as $d | $ids | index($d)) == null) | "phase " + ($p.id|tostring) + ": dependsOn references unknown phase id " + (.|tostring)] | .[]
        ' "$roadmap_path")
        if [ -n "$dangling" ]; then
          echo "Error: roadmap-init: dangling dependsOn reference(s):" >&2
          printf '%s\n' "$dangling" >&2
          exit 1
        fi

        # Identity well-formedness, over filtered_new ONLY -- the phases this
        # call actually writes. Never over the whole payload: plan.md always
        # submits the full phase array and both call sites downgrade a
        # roadmap-init failure to a warning, so a check that fired on a legacy
        # phase would silently drop the new one instead of reporting anything.
        identity_errors=""
        identity_errors=$(printf '%s' "$filtered_new" | _roadmap_identity_errors)
        if [ -n "$identity_errors" ]; then
          echo "Error: roadmap-init: malformed creates/needs identity in new phase(s):" >&2
          printf '%s\n' "$identity_errors" >&2
          exit 1
        fi

        merged_phases=$(jq --argjson add "$filtered_new" '
          (.phases + $add) | sort_by(.id)
        ' "$roadmap_path")
        roadmap_doc=$(printf '%s' "$existing_meta" | jq --argjson phases "$merged_phases" '. + {phases: $phases}')
        added_count=$(printf '%s' "$filtered_new" | jq 'length')
      else
        dangling=$(printf '%s' "$new_phases" | jq -r '
          ([.[].id] | unique) as $ids |
          [.[] | . as $p | ($p.dependsOn // [])[] | select((. as $d | $ids | index($d)) == null) | "phase " + ($p.id|tostring) + ": dependsOn references unknown phase id " + (.|tostring)] | .[]
        ')
        if [ -n "$dangling" ]; then
          echo "Error: roadmap-init: dangling dependsOn reference(s):" >&2
          printf '%s\n' "$dangling" >&2
          exit 1
        fi

        # Creation mode: every phase in new_phases is by definition new, so the
        # same guard applies to the whole array here.
        identity_errors=""
        identity_errors=$(printf '%s' "$new_phases" | _roadmap_identity_errors)
        if [ -n "$identity_errors" ]; then
          echo "Error: roadmap-init: malformed creates/needs identity in new phase(s):" >&2
          printf '%s\n' "$identity_errors" >&2
          exit 1
        fi

        merged_phases=$(printf '%s' "$new_phases" | jq 'sort_by(.id)')
        roadmap_doc=$(jq -n --arg feature "$feature" --arg bp "$brainstorm_path" --argjson phases "$merged_phases" "$_ROADMAP_SANITIZE_JQ"'
          {
            roadmapVersion: "1.0",
            feature: $feature,
            createdAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            brainstormPath: (if ($bp|length) == 0 then null else ($bp | _rm_sanitize(500)) end),
            phases: $phases
          }
        ')
        added_count=$(printf '%s' "$merged_phases" | jq 'length')
      fi

      tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
      printf '%s\n' "$roadmap_doc" > "$tmp_file"
      mv "$tmp_file" "$roadmap_path"

      jq -n --arg path "$roadmap_path" --argjson added "$added_count" --argjson total "$(printf '%s' "$merged_phases" | jq 'length')" \
        '{roadmap: $path, added: $added, phases: $total}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_get() {
  local feature="" phase_id="" next_eligible=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --next-eligible) next_eligible=true ;;
      *)
        echo "Error: roadmap-get: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-get" "$feature")

  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "roadmap-get"
    if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
      echo "Error: roadmap-get: phase $phase_id not found in $roadmap_path" >&2
      exit 1
    fi
    jq --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path"
    return 0
  fi

  if [ "$next_eligible" = true ]; then
    local eligible
    eligible=$(jq '
      (reduce .phases[] as $p ({}; . + {($p.id|tostring): $p.status})) as $status_by_id |
      [.phases[] | select(
        (.status == "pending" or .status == "planned") and
        (.claim == null) and
        ((.dependsOn // []) | all(. as $d | $status_by_id[$d|tostring] == "completed"))
      )] | sort_by(.id) | (.[0] // null)
    ' "$roadmap_path")
    if [ "$eligible" = "null" ]; then
      echo "Error: roadmap-get: no eligible phase found" >&2
      exit 1
    fi
    printf '%s\n' "$eligible"
    return 0
  fi

  cat "$roadmap_path"
}

cmd_roadmap_set_status() {
  local feature="" phase_id="" new_status="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --status) shift; new_status="${1:-}" ;;
      --force) force=true ;;
      *)
        echo "Error: roadmap-set-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-set-status"

  case "$new_status" in
    pending|planned|in_progress|completed|verification_failed) ;;
    *)
      echo "Error: roadmap-set-status: --status must be one of pending|planned|in_progress|completed|verification_failed, got: $new_status" >&2
      exit 1
      ;;
  esac

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-set-status" "$feature")

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-set-status: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      current_status=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .status) // empty' "$roadmap_path")
      if [ -z "$current_status" ]; then
        echo "Error: roadmap-set-status: phase $phase_id not found in $roadmap_path" >&2
        exit 1
      fi

      # verification_failed is reachable from any non-terminal state (execute
      # sets it when creates-verification fails). The rest of the graph:
      #   pending -> planned            plan expands the phase
      #   pending -> in_progress        execute claims a phase whose planned
      #                                 transition was lost (plan aborted after
      #                                 writing tasks.json but before setting
      #                                 planned) -- allowing it makes execute
      #                                 self-healing instead of silently
      #                                 diverging from roadmap.json
      #   planned -> in_progress        normal start
      #   in_progress -> in_progress    idempotent resume of a crashed session
      #   verification_failed -> in_progress   re-verify retry
      #   in_progress|verification_failed -> completed
      allowed=false
      if [ "$new_status" = "verification_failed" ]; then
        allowed=true
      else
        case "$current_status:$new_status" in
          pending:planned|pending:in_progress|planned:in_progress|in_progress:in_progress|verification_failed:in_progress|in_progress:completed|verification_failed:completed) allowed=true ;;
        esac
      fi

      if [ "$allowed" != true ] && [ "$force" != true ]; then
        echo "Error: roadmap-set-status: transition $current_status -> $new_status is not allowed without --force" >&2
        exit 1
      fi

      # Hard rule, not an --force-able ordering convention: a phase can never
      # reach "completed" without handoff.md already on disk at its phase dir
      # (see outline 11). handoff.md is written only via roadmap-write-handoff,
      # which is the guard-protected path guard-runtime-state.py points callers
      # at. This check runs even when --force is set -- --force overrides
      # transition *order*, never this physical artifact precondition.
      if [ "$new_status" = "completed" ]; then
        phase_dir=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
        feature_dir=$(dirname "$roadmap_path")
        if [ ! -f "$feature_dir/$phase_dir/handoff.md" ]; then
          echo "Error: roadmap-set-status: phase $phase_id cannot transition to completed -- no handoff.md found at $feature_dir/$phase_dir/handoff.md. Write it first with roadmap-write-handoff." >&2
          exit 1
        fi
      fi

      # Completing a phase also releases its claim in the same atomic write --
      # no window where status reads completed while the phase still shows
      # claimed (see outline 11; mirrors cmd_mark_complete's single-write pattern).
      if [ "$new_status" = "completed" ]; then
        roadmap_doc=$(jq --argjson pid "$phase_id" --arg status "$new_status" '
          .phases |= map(if .id == $pid then .status = $status | .claim = null else . end)
        ' "$roadmap_path")
      else
        roadmap_doc=$(jq --argjson pid "$phase_id" --arg status "$new_status" '
          .phases |= map(if .id == $pid then .status = $status else . end)
        ' "$roadmap_path")
      fi

      tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
      printf '%s\n' "$roadmap_doc" > "$tmp_file"
      mv "$tmp_file" "$roadmap_path"

      jq -n --argjson pid "$phase_id" --arg from "$current_status" --arg to "$new_status" '{phase: $pid, from: $from, to: $to}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_claim() {
  local feature="" session_id="" session_pid="" phase_override=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --session-id) shift; session_id="${1:-}" ;;
      --session-pid) shift; session_pid="${1:-}" ;;
      --phase) shift; phase_override="${1:-}" ;;
      *)
        echo "Error: roadmap-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -z "$session_id" ]; then
    echo "Error: roadmap-claim: --session-id <id> is required" >&2
    exit 1
  fi
  if ! [[ "$session_pid" =~ ^[0-9]+$ ]]; then
    echo "Error: roadmap-claim: --session-pid <pid> must be a positive integer" >&2
    exit 1
  fi
  if [ -n "$phase_override" ]; then
    _roadmap_validate_phase_id "$phase_override" "roadmap-claim"
  fi
  # Sanitize the caller-supplied session id before it is ever written to roadmap.json.
  session_id=$(printf '%s' "$session_id" | jq -Rr "$_ROADMAP_SANITIZE_JQ"'_rm_sanitize(200)')

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-claim" "$feature" " (run roadmap-init first)")

  # --phase is a bare numeric id at this point (validated above); pass it through
  # to jq as a number, or JSON null when no override was given.
  local phase_override_json="null"
  [ -n "$phase_override" ] && phase_override_json="$phase_override"

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-claim: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      # Identify stale claims (claimedPid no longer alive) inside this locked pass.
      # sessionId travels alongside pid here so the release report line below
      # ("released stale claim on phase <id> (session <sid> pid <pid> not
      # alive)") can be built without a second read of roadmap.json.
      # _is_pid_alive is a bash kill(2) probe, not something jq can do, so
      # the loop itself stays bash -- but it only accumulates plain phase-id
      # lines while the lock is held, then converts them to a JSON array in
      # one jq pass at the end, instead of spawning one jq process per stale
      # claim to grow the array incrementally.
      claimed_pids=$(jq -c '[.phases[] | select(.claim != null) | {id: .id, pid: .claim.claimedPid, sessionId: .claim.claimedBy}]' "$roadmap_path")
      stale_id_lines=""
      while IFS=$'\t' read -r pid_phase_id pid_val; do
        [ -z "$pid_phase_id" ] && continue
        if ! _is_pid_alive "$pid_val"; then
          stale_id_lines="${stale_id_lines}${pid_phase_id}"$'\n'
        fi
      done < <(printf '%s' "$claimed_pids" | jq -r '.[] | [(.id|tostring), (.pid|tostring)] | @tsv')
      stale_ids=$(printf '%s' "$stale_id_lines" | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)')
      stale_released=$(printf '%s' "$claimed_pids" | jq --argjson stale_ids "$stale_ids" '
        [.[] | select((.id) as $id | ($stale_ids | index($id)) != null)]
      ')

      now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      result=$(jq -n \
        --slurpfile cur "$roadmap_path" \
        --argjson stale_ids "$stale_ids" \
        --argjson stale_released "$stale_released" \
        --arg session_id "$session_id" \
        --arg now "$now" \
        --argjson session_pid "$session_pid" \
        --argjson phase_override "$phase_override_json" \
        '
          ($cur[0]) as $current |
          ($current.phases | map(if ((.id) as $id | ($stale_ids | index($id)) != null) then .claim = null else . end)) as $cleared_phases |
          (reduce $cleared_phases[] as $p ({}; . + {($p.id|tostring): $p.status})) as $status_by_id |
          # Self-reclaim: this exact session already owns an unreleased claim on a
          # still-active phase (matching the requested --phase when given). Return
          # it again instead of erroring or re-running eligibility -- this is what
          # makes re-running /aimi:execute on an already-claimed phase idempotent.
          ($cleared_phases | map(select(
            .claim != null and .claim.claimedBy == $session_id and
            (.status == "pending" or .status == "planned" or .status == "in_progress") and
            ($phase_override == null or .id == $phase_override)
          ))) as $self_claimed |
          (if ($self_claimed | length) > 0 then
            ($self_claimed | sort_by(.id) | .[0]) as $mine |
            {claimed: true, phase: $mine, phases: $cleared_phases}
          elif $phase_override != null then
            ($cleared_phases | map(select(.id == $phase_override))) as $target_arr |
            if ($target_arr | length) == 0 then
              {claimed: false, reason: "phase-not-found", phases: null}
            else
              ($target_arr[0]) as $target |
              if ((["pending","planned","in_progress","verification_failed"] | index($target.status)) == null) then
                {claimed: false, reason: "not-claimable", detail: ("phase status is " + $target.status), phases: null}
              elif $target.claim != null then
                {claimed: false, reason: "claimed", detail: "claimed by a live session", phases: null}
              elif ((($target.dependsOn // []) | all(. as $d | $status_by_id[$d|tostring] == "completed")) | not) then
                {claimed: false, reason: "blocked", detail: ("depends on incomplete phase(s): " + ((($target.dependsOn // []) | map(select($status_by_id[(.|tostring)] != "completed")) | map(tostring) | join(", ")))), phases: null}
              else
                ($cleared_phases | map(if .id == $target.id then . + {claim: {claimedBy: $session_id, claimedAt: $now, claimedPid: $session_pid}} else . end)) as $final_phases |
                {claimed: true, phase: ($final_phases[] | select(.id == $target.id)), phases: $final_phases}
              end
            end
          else
            # Resumable = not yet terminal AND carrying no live claim. Stale
            # claims were already cleared above, so an unclaimed in_progress
            # phase is leftover from a crashed session and verification_failed
            # is awaiting a re-verify run -- both must be re-claimable or crash
            # recovery and verification retry are dead ends, which is exactly
            # what execute.md tells the user to recover by re-running.
            ($cleared_phases | map(select((.status == "pending" or .status == "planned" or .status == "in_progress" or .status == "verification_failed") and .claim == null))) as $candidates0 |
            ($candidates0 | map(select( ((.dependsOn // []) | all(. as $d | $status_by_id[$d|tostring] == "completed")) ))) as $eligible |
            if ($eligible | length) > 0 then
              ($eligible | sort_by(.id) | .[0]) as $chosen |
              ($cleared_phases | map(if .id == $chosen.id then . + {claim: {claimedBy: $session_id, claimedAt: $now, claimedPid: $session_pid}} else . end)) as $final_phases |
              {claimed: true, phase: ($final_phases[] | select(.id == $chosen.id)), phases: $final_phases}
            else
              ($cleared_phases | map(select(.status == "pending" or .status == "planned" or .status == "in_progress" or .status == "verification_failed"))) as $remaining |
              if ($remaining | length) == 0 then
                {claimed: false, reason: "none-eligible", phases: null}
              else
                ($remaining | map(
                  if .claim != null then
                    {id: .id, reason: ("claimed by session " + .claim.claimedBy)}
                  else
                    {id: .id, reason: ("depends on incomplete phase(s): " + (((.dependsOn // []) | map(select($status_by_id[(.|tostring)] != "completed")) | map(tostring) | join(", "))))}
                  end
                )) as $blocked_reasons |
                {claimed: false, reason: "all-blocked", blocked: $blocked_reasons, phases: null}
              end
            end
          end) as $outcome |
          $outcome + {staleReleased: $stale_released}
        ')

      claimed=$(printf '%s' "$result" | jq -r '.claimed')

      if [ "$claimed" = "true" ]; then
        new_phases_out=$(printf '%s' "$result" | jq '.phases')
        roadmap_doc=$(jq --argjson phases "$new_phases_out" '.phases = $phases' "$roadmap_path")

        tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
        printf '%s\n' "$roadmap_doc" > "$tmp_file"
        mv "$tmp_file" "$roadmap_path"

        printf '%s' "$result" | jq '.phase + {staleReleased: .staleReleased}'
        exit 0
      fi

      reason=$(printf '%s' "$result" | jq -r '.reason')
      case "$reason" in
        none-eligible)
          echo "Error: roadmap-claim: no phase remains in pending or planned status" >&2
          exit 4
          ;;
        phase-not-found)
          echo "Error: roadmap-claim: phase $phase_override not found in $roadmap_path" >&2
          exit 4
          ;;
        not-claimable|claimed|blocked)
          detail=$(printf '%s' "$result" | jq -r '.detail')
          echo "Error: roadmap-claim: phase $phase_override is not claimable: $detail" >&2
          exit 3
          ;;
        *)
          echo "Error: roadmap-claim: all remaining pending/planned phases are blocked:" >&2
          printf '%s' "$result" | jq -r '.blocked[] | "  phase " + (.id|tostring) + ": " + .reason' >&2
          exit 3
          ;;
      esac
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_release_claim() {
  local feature="" phase_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      *)
        echo "Error: roadmap-release-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-release-claim"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-release-claim" "$feature" "" --skip-malformed)

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-release-claim: phase $phase_id not found in $roadmap_path" >&2
        exit 1
      fi

      roadmap_doc=$(jq --argjson pid "$phase_id" '
        .phases |= map(if .id == $pid then .claim = null else . end)
      ' "$roadmap_path")

      tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
      printf '%s\n' "$roadmap_doc" > "$tmp_file"
      mv "$tmp_file" "$roadmap_path"

      jq -n --argjson pid "$phase_id" '{released: $pid}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_reconcile() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      *)
        echo "Error: roadmap-reconcile: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-reconcile" "$feature")

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"

      if ! jq -e . "$roadmap_path" >/dev/null 2>&1; then
        echo "Error: roadmap-reconcile: malformed roadmap.json: $roadmap_path" >&2
        exit 1
      fi

      phase_dirs=$(jq -c '[.phases[] | {id: .id, dir: .dir, status: .status}]' "$roadmap_path")
      corrections='[]'

      blocked='[]'

      while IFS=$'\t' read -r rc_id rc_dir rc_status; do
        [ -z "$rc_id" ] && continue
        # Phase tasks files follow <feature>-phase-<id>-tasks.json (the same
        # convention phase-overlap, execute.md Step 1.7, plan.md Phase 3e and
        # status.md use). Reading a bare tasks.json here made every lookup miss,
        # so reconcile silently reported zero corrections.
        rc_tasks_file="$feature_dir/$rc_dir/$feature-phase-$rc_id-tasks.json"
        if [ ! -f "$rc_tasks_file" ]; then
          continue
        fi
        if ! jq -e . "$rc_tasks_file" >/dev/null 2>&1; then
          continue
        fi
        ground_truth=$(jq -r '
          [.userStories[].status] as $statuses |
          if ($statuses | length) == 0 then "unknown"
          elif ($statuses | all(. == "completed")) then "completed"
          elif ($statuses | any(. == "failed")) then "verification_failed"
          else "in_progress"
          end
        ' "$rc_tasks_file")
        if [ "$ground_truth" != "unknown" ] && [ "$ground_truth" != "$rc_status" ]; then
          # Same hard precondition roadmap-set-status enforces: a phase never
          # reaches "completed" without handoff.md on disk. Reconcile must not
          # be a second write path with weaker invariants -- an otherwise-valid
          # completed correction is reported as blocked instead of applied, so
          # the divergence stays visible rather than silently healed wrong.
          if [ "$ground_truth" = "completed" ] && [ ! -f "$feature_dir/$rc_dir/handoff.md" ]; then
            blocked=$(printf '%s' "$blocked" | jq --argjson id "$rc_id" --arg from "$rc_status" --arg to "$ground_truth" \
              '. + [{id: $id, from: $from, to: $to, reason: "no handoff.md -- write it with roadmap-write-handoff, then re-run"}]')
          else
            corrections=$(printf '%s' "$corrections" | jq --argjson id "$rc_id" --arg from "$rc_status" --arg to "$ground_truth" '. + [{id: $id, from: $from, to: $to}]')
          fi
        fi
      done < <(printf '%s' "$phase_dirs" | jq -r '.[] | [(.id|tostring), .dir, .status] | @tsv')

      if [ "$(printf '%s' "$corrections" | jq 'length')" -gt 0 ]; then
        # Reaching "completed" also releases the claim in the same atomic write,
        # mirroring roadmap-set-status -- otherwise a reconciled phase reads as
        # done while still showing claimed by a dead session.
        roadmap_doc=$(jq --argjson corr "$corrections" '
          .phases |= map(
            . as $p |
            (($corr | map(select(.id == $p.id)) | .[0]) // null) as $c |
            if $c != null then
              ($p + {status: $c.to} | if $c.to == "completed" then .claim = null else . end)
            else $p end
          )
        ' "$roadmap_path")

        tmp_file=$(mktemp "${roadmap_path}.XXXXXX")
        printf '%s\n' "$roadmap_doc" > "$tmp_file"
        mv "$tmp_file" "$roadmap_path"
      fi

      jq -n --argjson corr "$corrections" --argjson blocked "$blocked" '{corrections: $corr, blocked: $blocked}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Write a phase's handoff.md through a guard-protected CLI call (see outline
# 11). guard-runtime-state.py blocks any direct Write/Edit tool call whose
# target is .aimi/tasks/<feature>/phase-N/handoff.md and points the caller
# back at this verb -- this is the only path that may create or overwrite
# that file. Reads a JSON object from --file or stdin with five optional
# array-of-string fields (decisions, artifacts, deviations, deferred,
# contracts); each entry is sanitized and length-capped with the same
# _rm_sanitize regime as every other free-text roadmap field. Always emits
# exactly five "## " headings in the fixed order
# "Decisions Made" / "Artifacts Created" / "Deviations" / "Deferred Items" /
# "Contracts Delivered" -- the order roadmap-set-status's completed-requires-
# handoff precondition and _cv_handoff_lists_artifact's "Artifacts Created"
# lookup both depend on. Overwrites any existing handoff.md at that path
# (idempotent retry after a verification_failed -> completed re-run).
cmd_roadmap_write_handoff() {
  local feature="" phase_id="" file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      *)
        echo "Error: roadmap-write-handoff: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-write-handoff"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-write-handoff" "$feature")

  local phase_dir
  phase_dir=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
  if [ -z "$phase_dir" ]; then
    echo "Error: roadmap-write-handoff: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-write-handoff: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  if ! printf '%s' "$input_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "Error: roadmap-write-handoff: payload must be a JSON object" >&2
    exit 1
  fi

  local key
  for key in decisions artifacts deviations deferred contracts; do
    if ! printf '%s' "$input_json" | jq -e --arg k "$key" '(.[$k] // []) as $v | ($v|type) == "array" and ($v | all(type == "string"))' >/dev/null 2>&1; then
      echo "Error: roadmap-write-handoff: field '$key' must be an array of strings" >&2
      exit 1
    fi
  done

  local body
  body=$(printf '%s' "$input_json" | jq -r "$_ROADMAP_SANITIZE_JQ"'
    def clean: map(_rm_sanitize(2000));
    def section(title; items):
      "## " + title + "\n\n" +
      (if (items | length) == 0 then "_None._\n" else ((items | map("- " + .)) | join("\n")) + "\n" end);
    {
      decisions: ((.decisions // []) | clean),
      artifacts: ((.artifacts // []) | clean),
      deviations: ((.deviations // []) | clean),
      deferred: ((.deferred // []) | clean),
      contracts: ((.contracts // []) | clean)
    } as $s |
    section("Decisions Made"; $s.decisions) + "\n" +
    section("Artifacts Created"; $s.artifacts) + "\n" +
    section("Deviations"; $s.deviations) + "\n" +
    section("Deferred Items"; $s.deferred) + "\n" +
    section("Contracts Delivered"; $s.contracts)
  ')

  local feature_dir handoff_path
  feature_dir=$(dirname "$roadmap_path")
  handoff_path="$feature_dir/$phase_dir/handoff.md"
  validate_path_in_project "$handoff_path"

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      mkdir -p "$(dirname "$handoff_path")"
      tmp_file=$(mktemp "${handoff_path}.XXXXXX")
      printf '%s\n' "$body" > "$tmp_file" && mv "$tmp_file" "$handoff_path"
      jq -n --arg path "$handoff_path" '{handoff: $path}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# Contract Validation Subcommands (validate-contracts, roadmap-sweep)
# ============================================================================
# Cross-check a feature's roadmap.json creates[]/needs[] contracts: an unmet
# need (no phase in the needing phase's dependsOn closure creates it) and a
# duplicate creates (the same artifact identity declared by two or more
# phases). Artifact identity is the substring before a creates/needs entry's
# first "(", trimmed of surrounding whitespace (see outline 01's shared
# scope-context reference).
#
# Schema note: the roadmap phase status enum is pending/planned/in_progress/
# completed/verification_failed (see cmd_roadmap_set_status above) -- there
# is no "deferred" status. roadmap-sweep's deferredNeeds check substitutes
# the existing "provider resolved but status != completed" signal for the
# undefined "deferred" status value, per this story's authoritative notes
# reconciling the schema gap against outline 02/outline 14.

# jq `def`s shared by validate-contracts and roadmap-sweep.
_CONTRACT_JQ_DEFS='
def _cv_identity: sub("\\(.*"; "") | gsub("^[ \t]+|[ \t]+$"; "");
def _cv_suspicious: test("ignore previous|system:|INSTRUCTIONS|```|\\$\\("; "i") or test("[$`;|&]");
'

# Print newline-separated phase ids reachable via transitive dependsOn
# closure from $2 (excluding $2 itself). $1 = roadmap_path.
_cv_reachable_ids() {
  local roadmap_path="$1" start_id="$2"
  jq -r --argjson start "$start_id" '
    (reduce .phases[] as $p ({}; . + {($p.id|tostring): ($p.dependsOn // [])})) as $deps |
    def _cv_expand($cur): ($cur + ($cur | map($deps[(.|tostring)] // []) | add // [])) | unique;
    ([$start] | until(_cv_expand(.) == .; _cv_expand(.))) - [$start] | .[]
  ' "$roadmap_path"
}

# Print "id<TAB>identity<TAB>status<TAB>dir" for every creates[] entry of
# every phase whose id is in the given newline-separated id list ($2),
# sorted by phase id ascending (deterministic first-match order for
# provider lookup). $1 = roadmap_path.
_cv_creates_in_scope() {
  local roadmap_path="$1" ids_input="$2"
  local ids_json='[]'
  if [ -n "$ids_input" ]; then
    ids_json=$(printf '%s\n' "$ids_input" | jq -R 'select(length > 0) | tonumber' | jq -s '.')
  fi
  jq -r --argjson ids "$ids_json" "$_CONTRACT_JQ_DEFS"'
    [.phases[] | select(.id as $i | $ids | index($i) != null)] | sort_by(.id) | .[] |
    . as $p | ((.creates // [])[]? | _cv_identity) as $ident |
    "\($p.id)\t\($ident)\t\($p.status)\t\($p.dir // "")"
  ' "$roadmap_path"
}

# True (exit 0) when handoff.md at $1 lists artifact identity $2 under an
# "Artifacts Created" section (any heading level). Fixed-string match (-F)
# so an identity containing regex metacharacters cannot alter the search.
_cv_handoff_lists_artifact() {
  local handoff_path="$1" identity="$2"
  [ -f "$handoff_path" ] || return 1
  awk '
    /^#+[ \t]+Artifacts Created/ { flag=1; next }
    /^#+[ \t]/ { flag=0 }
    flag { print }
  ' "$handoff_path" | grep -qF -- "$identity"
}

# ============================================================================
# verify-creates — prove a phase's creates[] exist in code, not in prose
# ============================================================================
#
# Creates verification used to live as executable prose in /aimi:execute's
# "Creates Verification" section: an orchestrator read a numbered procedure and
# ran `[ -f "$PHASE_CONTAINER_PATH/$identity" ]`, then a bare `git grep -l -F`.
# No Bash suite could reach it, and the procedure was wrong in three ways a
# test would have caught the day it shipped:
#
#   * `[ -f ]` is false for a directory, so a creates entry naming one
#     ("db/migrations") could never verify by path.
#   * The text search carried no exclusions, so an identity mentioned once in
#     docs/plano.md, in a test file, or in a `// TODO:` comment closed the
#     phase — a phase could pass on a mention of the work instead of the work.
#   * An endpoint identity is written "POST /api/notifications" (see the
#     Creates/Needs Contracts table in commands/references/scope-contexts.md),
#     but source code holds the path, not the method-plus-path literal, so a
#     delivered endpoint read as missing while its documentation read as done.
#
# This is the move split-detect already made (see its header above): pure,
# deterministic, file-only logic belongs where both Bash suites can reach it,
# in exactly one copy, with every rule a test case.
#
# It is a QUERY, not a gate. Producing a verdict array exits 0 — including an
# array where every entry is "missing". Non-zero is reserved for real errors
# (unknown flag, absent/non-numeric --phase, absent/malformed roadmap.json,
# --dir that is not a directory), which is what lets the caller loop over the
# result instead of branching on the exit status.
#
# Deliberately NOT kind-aware: it does not try to map a table identity to a
# migration file or an endpoint identity to a route file. Every identity runs
# the same four steps; the kind column in scope-contexts.md stays a naming
# convention, not a dispatch table.

# Paths whose content is a MENTION of an artifact rather than the artifact:
# documentation and tests.
#
# Every pattern uses the LONG ":(exclude)" form. The short "!" form is not
# interchangeable — git reads the character after the colon as pathspec magic,
# so ':!__tests__/*' aborts the whole invocation with
#   fatal: Unimplemented pathspec magic '_' in ':!__tests__/*'
# and exit 128, which would turn every artifact of every phase into "missing".
# Long form only, for all patterns, so no future edit reintroduces the short
# form by copying a neighbour.
#
# Default pathspec matching is fnmatch without FNM_PATHNAME — "*" crosses "/"
# — so "*.md" excludes .md files at any depth, while "docs/*" is anchored at
# the search root and needs the "*/docs/*" companion for nested copies.
#
# .aimi/* is excluded for a specific reason: roadmap.json holds the creates[]
# strings themselves, so without it every identity would find itself in the
# very file that declared it.
_VERIFY_CREATES_EXCLUDES=(
  ':(exclude)*.md'
  ':(exclude)*.mdx'
  ':(exclude)*.rst'
  ':(exclude)*.adoc'
  ':(exclude)*.txt'
  ':(exclude)docs/*'
  ':(exclude)doc/*'
  ':(exclude)documentation/*'
  ':(exclude)*/docs/*'
  ':(exclude)*/doc/*'
  ':(exclude)*/documentation/*'
  ':(exclude)README*'
  ':(exclude)CHANGELOG*'
  ':(exclude)CONTRIBUTING*'
  ':(exclude).aimi/*'
  ':(exclude)*_test.*'
  ':(exclude)*.test.*'
  ':(exclude)*_spec.*'
  ':(exclude)*.spec.*'
  ':(exclude)test/*'
  ':(exclude)tests/*'
  ':(exclude)spec/*'
  ':(exclude)__tests__/*'
  ':(exclude)*/test/*'
  ':(exclude)*/tests/*'
  ':(exclude)*/spec/*'
  ':(exclude)*/__tests__/*'
)

# The tracked-files caveat, stated in every "missing" verdict so the caller
# reports the limit instead of silently owning it.
_VERIFY_CREATES_TRACKED_NOTE='Note: git ls-files and git grep see tracked (committed) files only, so uncommitted work reads as missing.'

# True (exit 0) when the identity names documentation itself. For those, a hit
# under docs/ IS the artifact rather than a mention of it, so the exclusion
# list is bypassed for that one entry.
_verify_creates_is_doc_identity() {
  local identity="$1"
  case "$identity" in
    docs/*|doc/*|*/docs/*|*/doc/*|*.md|*.rst|*.adoc|*.txt) return 0 ;;
  esac
  return 1
}

# True (exit 0) when a matched line is nothing but a TODO/FIXME/XXX/HACK
# marker inside a comment — a note that the work is still owed, which must
# never count as the work being done.
_verify_creates_is_marker_line() {
  local content="$1"
  grep -Eq '^[[:space:]]*(//+|#+|--+|\*+|/\*+|<!--)[[:space:]]*(TODO|FIXME|XXX|HACK)([^A-Za-z0-9_]|$)' <<< "$content"
}

# Verify ONE creates identity against <dir>'s tracked files.
# Prints one compact JSON object: {identity, status, method, evidence, gitStatus}.
#   status    verified | missing | error
#   method    "path" (step 1) | "text" (step 3) | null (not verified)
#   gitStatus the highest exit status any git invocation returned for this
#             entry — 0 or 1 in normal operation, above 1 only on tool failure.
# Always returns 0: a verdict of "missing" or "error" is data, not failure.
_verify_creates_one() {
  local dir="$1" identity="$2"
  local status="missing" method="" evidence=""
  local git_max=0 rc=0

  if [ -z "$identity" ]; then
    _verify_creates_emit "$identity" "missing" "" \
      "Malformed creates entry: empty artifact identity (expected \"<artifact-name> (<description>)\"). $_VERIFY_CREATES_TRACKED_NOTE" 0
    return 0
  fi

  # --- Step 1: tracked path ------------------------------------------------
  # Matches a FILE and a DIRECTORY alike. `[ -f ]`, which this replaces, is
  # false on a directory, so a directory identity could only ever verify by
  # text search — and usually did not verify at all.
  # An absolute or traversing identity is never handed to git as a pathspec
  # (same escape-prevention posture validate_path_in_project enforces); it
  # falls through to the content search instead, which cannot leave the repo.
  local path_safe=true
  case "$identity" in
    /*|../*|*/../*|*/..) path_safe=false ;;
  esac
  if [ "$path_safe" = true ]; then
    local ls_out=""
    rc=0
    ls_out=$(git -C "$dir" ls-files -- "$identity" "$identity/*" 2>/dev/null) || rc=$?
    if [ "$rc" -gt "$git_max" ]; then git_max=$rc; fi
    if [ "$rc" -gt 1 ]; then
      _verify_creates_emit "$identity" "error" "" \
        "git ls-files exited $rc under $dir — tool failure, not an absent artifact." "$git_max"
      return 0
    fi
    if [ -n "$ls_out" ]; then
      local first_path="${ls_out%%$'\n'*}"
      _verify_creates_emit "$identity" "verified" "path" \
        "tracked path: $first_path" "$git_max"
      return 0
    fi
  fi

  # --- Step 2: endpoint path extraction -----------------------------------
  # Load-bearing, not a nicety. In a repository that genuinely serves the
  # route, the literal "POST /api/notifications" was found in docs/plano.md
  # and nowhere else — real code writes router.post('/api/notifications', …).
  # Excluding documentation without this step turns every endpoint-kind phase
  # into verification_failed, and the only way to unblock it would be to write
  # the literal into a comment: exactly the hole this verb closes.
  #
  # Only a leading HTTP method token followed by a space and a "/" is
  # stripped. Every other identity reaches the search untouched — "DELETE
  # user_sessions" is a table-shaped identity, not an endpoint, and searching
  # it for "user_sessions" alone would weaken the check.
  local search="$identity"
  case "$identity" in
    'GET /'*|'POST /'*|'PUT /'*|'PATCH /'*|'DELETE /'*|'HEAD /'*|'OPTIONS /'*)
      search="${identity#* }"
      ;;
  esac
  local searched_note=""
  if [ "$search" != "$identity" ]; then
    searched_note=" (searched \"$search\")"
  fi

  # --- Step 3: text search over tracked source ----------------------------
  # rc is pre-initialized and captured with `|| rc=$?` because this script
  # runs under `set -euo pipefail` (line 2) and git grep exits 1 on a
  # legitimate no-match. `local rc=$?` would mask the status behind local's
  # own success and is used nowhere here.
  local grep_out=""
  rc=0
  if _verify_creates_is_doc_identity "$identity"; then
    grep_out=$(git -C "$dir" grep -n -I -F -e "$search" 2>/dev/null) || rc=$?
  else
    grep_out=$(git -C "$dir" grep -n -I -F -e "$search" -- "${_VERIFY_CREATES_EXCLUDES[@]}" 2>/dev/null) || rc=$?
  fi
  if [ "$rc" -gt "$git_max" ]; then git_max=$rc; fi
  if [ "$rc" -gt 1 ]; then
    _verify_creates_emit "$identity" "error" "" \
      "git grep exited $rc under $dir — tool failure, not an absent artifact." "$git_max"
    return 0
  fi

  # --- Step 4: drop marker-only comment lines -----------------------------
  local kept="" first_marker=""
  if [ -n "$grep_out" ]; then
    local gline rest hit_file hit_num hit_content
    while IFS= read -r gline; do
      [ -n "$gline" ] || continue
      hit_file="${gline%%:*}"
      rest="${gline#*:}"
      hit_num="${rest%%:*}"
      hit_content="${rest#*:}"
      if _verify_creates_is_marker_line "$hit_content"; then
        if [ -z "$first_marker" ]; then first_marker="$hit_file:$hit_num"; fi
        continue
      fi
      kept="$hit_file:$hit_num"
      break
    done <<< "$grep_out"
  fi

  if [ -n "$kept" ]; then
    _verify_creates_emit "$identity" "verified" "text" \
      "tracked source: ${kept}${searched_note}" "$git_max"
    return 0
  fi

  # --- Missing: name what was found and rejected, not just "not found" ----
  local rejected=""
  if [ -n "$first_marker" ]; then
    rejected=" Found and rejected at $first_marker: TODO/FIXME marker comment, not an implementation."
  else
    local all_out=""
    rc=0
    all_out=$(git -C "$dir" grep -n -I -F -e "$search" 2>/dev/null) || rc=$?
    if [ "$rc" -gt "$git_max" ]; then git_max=$rc; fi
    if [ "$rc" -gt 1 ]; then
      _verify_creates_emit "$identity" "error" "" \
        "git grep exited $rc under $dir — tool failure, not an absent artifact." "$git_max"
      return 0
    fi
    if [ -n "$all_out" ]; then
      local aline afile arest anum acontent
      aline="${all_out%%$'\n'*}"
      afile="${aline%%:*}"
      arest="${aline#*:}"
      anum="${arest%%:*}"
      acontent="${arest#*:}"
      if _verify_creates_is_marker_line "$acontent"; then
        rejected=" Found and rejected at $afile:$anum: TODO/FIXME marker comment, not an implementation."
      else
        rejected=" Found and rejected at $afile:$anum: documentation or test path, excluded from the source search."
      fi
    fi
  fi

  status="missing"
  method=""
  evidence="No tracked artifact for \"$identity\" under ${dir}${searched_note}.${rejected} $_VERIFY_CREATES_TRACKED_NOTE"
  _verify_creates_emit "$identity" "$status" "$method" "$evidence" "$git_max"
  return 0
}

# Emit one verdict object. jq builds it so an identity carrying quotes,
# spaces or backslashes cannot break the array.
_verify_creates_emit() {
  jq -nc \
    --arg identity "$1" \
    --arg status "$2" \
    --arg method "$3" \
    --arg evidence "$4" \
    --argjson gitStatus "$5" \
    '{identity: $identity, status: $status,
      method: (if $method == "" then null else $method end),
      evidence: $evidence, gitStatus: $gitStatus}'
}

cmd_verify_creates() {
  local feature="" phase_id="" dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase)   shift; phase_id="${1:-}" ;;
      --dir)     shift; dir="${1:-}" ;;
      *)
        echo "Error: verify-creates: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "verify-creates"

  local roadmap_path
  roadmap_path=$(_roadmap_require "verify-creates" "$feature")

  if ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
    echo "Error: verify-creates: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  # --dir is the phase container's absolute path. It defaults to PROJECT_ROOT
  # rather than erroring, so the only --dir failure is a path that is not a
  # directory (or escapes the project).
  if [ -z "$dir" ]; then
    dir="$PROJECT_ROOT"
  fi
  if [ ! -d "$dir" ]; then
    echo "Error: verify-creates: --dir is not a directory: $dir" >&2
    exit 1
  fi
  dir=$(resolve_path "$dir")
  validate_path_in_project "$dir"

  # Identities come from the one existing definition (_cv_identity), never a
  # second copy: the substring before the first "(", trimmed.
  local creates_raw
  creates_raw=$(jq -r --argjson pid "$phase_id" "$_CONTRACT_JQ_DEFS"'
    .phases[] | select(.id == $pid) | (.creates // [])[] | _cv_identity
  ' "$roadmap_path")

  local result='[]'
  if [ -n "$creates_raw" ]; then
    local identity entry
    while IFS= read -r identity; do
      entry=$(_verify_creates_one "$dir" "$identity")
      result=$(printf '%s' "$result" | jq -c --argjson e "$entry" '. + [$e]')
    done <<< "$creates_raw"
  fi

  printf '%s' "$result" | jq '.'
}

cmd_validate_contracts() {
  local feature="" phase_id="" agent_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        shift; phase_id="${1:-}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      -*)
        echo "Usage: aimi-cli.sh validate-contracts <feature> [--phase <id>] [--agent-mode]" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "validate-contracts"
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "validate-contracts" "$feature")
  if [ -n "$phase_id" ] && ! jq -e --argjson pid "$phase_id" '.phases[] | select(.id == $pid)' "$roadmap_path" >/dev/null 2>&1; then
    echo "Error: validate-contracts: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  # --- Sanitization pass: always blocks; never demoted by --agent-mode ---
  # (a duplicate-creates finding is the only check this story demotes)
  local sanitize_hits
  sanitize_hits=$(jq -r "$_CONTRACT_JQ_DEFS"'
    [.phases[] | . as $p |
      ("creates","needs") as $field |
      select(($p[$field] // []) | any(_cv_suspicious)) |
      {phase: $p.id, field: $field}
    ] | unique_by([.phase,.field]) | .[] | "\(.phase)\t\(.field)"
  ' "$roadmap_path")
  if [ -n "$sanitize_hits" ]; then
    while IFS=$'\t' read -r hit_phase hit_field; do
      [ -z "$hit_phase" ] && continue
      echo "Error: validate-contracts: phase $hit_phase field '$hit_field' contains suspicious content" >&2
    done <<< "$sanitize_hits"
    exit 1
  fi

  # --- Duplicate-creates collision check (across all phases, any status) ---
  local dup_check dup_count
  dup_check=$(jq "$_CONTRACT_JQ_DEFS"'
    [.phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident | {identity: $ident, phase: $p.id}]
    | group_by(.identity)
    | map(select(length > 1))
    | map({identity: .[0].identity, phases: ([.[].phase] | unique | sort)})
  ' "$roadmap_path")
  dup_count=$(printf '%s' "$dup_check" | jq 'length')

  if [ "$dup_count" -gt 0 ]; then
    local dup_msg
    dup_msg=$(printf '%s' "$dup_check" | jq -r '
      .[] | "  phase " + (.phases | map(tostring) | join(" and phase ")) +
      ": both declare \"" + .identity + "\" -- convert the collision into a" +
      " creates/needs contract between the two phases or promote the" +
      " artifact to a shared foundation phase"
    ')
    if [ "$agent_mode" = "true" ]; then
      echo "Warning: validate-contracts: duplicate creates (--agent-mode: proceeding):" >&2
      printf '%s\n' "$dup_msg" >&2
    else
      echo "Error: validate-contracts: duplicate creates:" >&2
      printf '%s\n' "$dup_msg" >&2
      exit 1
    fi
  fi

  # --- Needs resolution: scope is --phase (if given) or every phase ---
  local scope_ids
  if [ -n "$phase_id" ]; then
    scope_ids=$(jq --argjson pid "$phase_id" -r '.phases[] | select(.id == $pid) | .id' "$roadmap_path")
  else
    scope_ids=$(jq -r '.phases[].id' "$roadmap_path")
  fi

  local missing_json='[]'
  local providers_json='{}'

  local sid
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue

    local reach_ids creates_tsv
    reach_ids=$(_cv_reachable_ids "$roadmap_path" "$sid")
    creates_tsv=$(_cv_creates_in_scope "$roadmap_path" "$reach_ids")

    local need_ident
    while IFS= read -r need_ident; do
      [ -z "$need_ident" ] && continue

      local prov_line
      prov_line=$(printf '%s\n' "$creates_tsv" | awk -F'\t' -v want="$need_ident" '$2 == want { print; exit }')

      if [ -z "$prov_line" ]; then
        missing_json=$(printf '%s' "$missing_json" | jq --argjson pid "$sid" --arg need "$need_ident" '. + [{phase: $pid, need: $need, reason: "no-provider"}]')
        continue
      fi

      local prov_id prov_status prov_dir
      IFS=$'\t' read -r prov_id _ prov_status prov_dir <<< "$prov_line"

      if [ -z "$phase_id" ]; then
        # Unscoped run: identity resolution within the dependsOn closure is
        # sufficient; the completed+handoff delivery gate only applies when
        # --phase pins the check to one phase's execution readiness.
        providers_json=$(printf '%s' "$providers_json" | jq --arg k "$need_ident" --argjson v "$prov_id" '. + {($k): $v}')
        continue
      fi

      local delivered=false
      if [ "$prov_status" = "completed" ] && _cv_handoff_lists_artifact "$feature_dir/$prov_dir/handoff.md" "$need_ident"; then
        delivered=true
      fi

      if [ "$delivered" = "true" ]; then
        providers_json=$(printf '%s' "$providers_json" | jq --arg k "$need_ident" --argjson v "$prov_id" '. + {($k): $v}')
      else
        missing_json=$(printf '%s' "$missing_json" | jq --argjson pid "$sid" --arg need "$need_ident" '. + [{phase: $pid, need: $need, reason: "not-delivered"}]')
      fi
    done < <(jq -r --argjson pid "$sid" "$_CONTRACT_JQ_DEFS"'.phases[] | select(.id == $pid) | (.needs // [])[] | _cv_identity' "$roadmap_path")
  done < <(printf '%s\n' "$scope_ids")

  local valid_bool="true"
  if [ "$(printf '%s' "$missing_json" | jq 'length')" -gt 0 ]; then
    valid_bool="false"
  fi

  if [ "$dup_count" -gt 0 ] && [ "$agent_mode" = "true" ]; then
    jq -n --argjson valid "$valid_bool" --argjson missing "$missing_json" --argjson providers "$providers_json" --argjson dupw "$dup_check" \
      '{valid: $valid, missing: $missing, providers: $providers, duplicateWarnings: $dupw}'
  else
    jq -n --argjson valid "$valid_bool" --argjson missing "$missing_json" --argjson providers "$providers_json" \
      '{valid: $valid, missing: $missing, providers: $providers}'
  fi

  if [ "$valid_bool" = "false" ]; then
    exit 1
  fi
  exit 0
}

# phase-overlap <feature> <phase-a> <phase-b>
# Stage 2 of the sibling-phase overlap guard (execute.md calls this only after
# its own stage-1 roadmap.json `areas` comparison finds a non-empty coarse
# intersection). Loads both phases' already-expanded tasks.json files, unions
# each phase's userStories[].implementation.files, and prints the sorted,
# deduplicated intersection as {"overlapping_files": [...]}.
cmd_phase_overlap() {
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if [ "${#positional[@]}" -ne 3 ]; then
    echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
    exit 1
  fi

  local feature="${positional[0]}" phase_a="${positional[1]}" phase_b="${positional[2]}"

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_a" "phase-overlap"
  _roadmap_validate_phase_id "$phase_b" "phase-overlap"

  if [ "$phase_a" = "$phase_b" ]; then
    echo "Error: phase-overlap: phase-a and phase-b must differ, got $phase_a twice" >&2
    exit 1
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "phase-overlap" "$feature" " (run roadmap-init first)")

  local feature_dir
  feature_dir=$(dirname "$roadmap_path")

  local dir_a dir_b
  dir_a=$(jq -r --argjson pid "$phase_a" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
  dir_b=$(jq -r --argjson pid "$phase_b" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")

  if [ -z "$dir_a" ]; then
    echo "Error: phase-overlap: phase $phase_a not found in $roadmap_path" >&2
    exit 1
  fi
  if [ -z "$dir_b" ]; then
    echo "Error: phase-overlap: phase $phase_b not found in $roadmap_path" >&2
    exit 1
  fi

  # Mirrors execute.md Step 1.7's PHASE_TASKS_PATH convention:
  # <feature_dir>/<phase_dir>/<feature>-phase-<id>-tasks.json
  local tasks_a tasks_b
  tasks_a="$feature_dir/$dir_a/$feature-phase-$phase_a-tasks.json"
  tasks_b="$feature_dir/$dir_b/$feature-phase-$phase_b-tasks.json"

  if [ ! -f "$tasks_a" ]; then
    echo "Error: phase-overlap: phase $phase_a has no tasks file yet ($tasks_a) -- run /aimi:plan --phase $phase_a to materialize it first" >&2
    exit 1
  fi
  if [ ! -f "$tasks_b" ]; then
    echo "Error: phase-overlap: phase $phase_b has no tasks file yet ($tasks_b) -- run /aimi:plan --phase $phase_b to materialize it first" >&2
    exit 1
  fi
  if ! jq -e . "$tasks_a" >/dev/null 2>&1; then
    echo "Error: phase-overlap: malformed tasks file: $tasks_a" >&2
    exit 1
  fi
  if ! jq -e . "$tasks_b" >/dev/null 2>&1; then
    echo "Error: phase-overlap: malformed tasks file: $tasks_b" >&2
    exit 1
  fi

  jq -n --slurpfile a "$tasks_a" --slurpfile b "$tasks_b" '
    ([$a[0].userStories[]?.implementation.files[]?] | unique) as $files_a |
    ([$b[0].userStories[]?.implementation.files[]?] | unique) as $files_b |
    {overlapping_files: ([$files_a[] | select(. as $f | $files_b | index($f) != null)] | unique | sort)}
  '
}

cmd_roadmap_sweep() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh roadmap-sweep <feature>" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-sweep" "$feature")

  # Single-pass, advisory-only computation: never exits non-zero. Suspicious
  # creates/needs entries are dropped from $clean_phases before orphan/deferred
  # computation so a flagged entry can never leak into any other output field
  # -- only its owning phase id and field name are reported, via $warnings.
  jq "$_CONTRACT_JQ_DEFS"'
    (
      [.phases[] | . as $p |
        ("creates","needs") as $field |
        select(($p[$field] // []) | any(_cv_suspicious)) |
        {phase: $p.id, field: $field, message: "contains suspicious content"}
      ] | unique_by([.phase,.field])
    ) as $warnings |

    (.phases | map(
      .creates = ((.creates // []) | map(select(_cv_suspicious | not))) |
      .needs = ((.needs // []) | map(select(_cv_suspicious | not)))
    )) as $clean_phases |

    ([$clean_phases[] | (.needs // [])[] | _cv_identity] | unique) as $need_idents |
    ([$clean_phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident |
      select(($need_idents | index($ident)) == null) |
      {phase: $p.id, creates: $ident}
    ]) as $orphan_creates |

    ([$clean_phases[] | . as $p | (($p.creates // [])[] | _cv_identity) as $ident | {identity: $ident, phase: $p.id, status: $p.status}]) as $providers_flat |
    ([$clean_phases[] | . as $np | (($np.needs // [])[] | _cv_identity) as $ident |
      ([$providers_flat[] | select(.identity == $ident)] | sort_by(.phase) | .[0]) as $prov |
      select($prov != null and $prov.status != "completed") |
      {phase: $np.id, need: $ident, deferred: $prov.phase}
    ]) as $deferred_needs |

    {orphanCreates: $orphan_creates, deferredNeeds: $deferred_needs, warnings: $warnings}
  ' "$roadmap_path"

  exit 0
}

# ============================================================================
# Payload Budget Estimation (advisory; Phase/Milestone Roadmap Layer)
# ============================================================================
#
# estimate-payload is purely advisory per the brainstorm's "budget as
# validator, not cutting criterion" decision: it never blocks planning and
# never trims content itself. Its only job is to print a clear warning with
# an actionable next step when a phase's context payload risks overflowing
# the sub-agent context window.

# Portable byte-size lookup (GNU stat -c%s, BSD/macOS stat -f%z fallback).
_file_size_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

# Resolve the effective payload budget in bytes plus the fraction it
# represents of the 400000-byte reference sub-agent window. --budget-bytes
# is a manual debug escape hatch (no caller passes it; plan.md's only
# caller uses the default); everything else defaults to 50% of the
# reference window.
# Usage: _estimate_payload_resolve_budget <flag_bytes>
# Prints "<budgetBytes> <budgetFraction>" (space-separated) on stdout.
_estimate_payload_resolve_budget() {
  local flag_bytes="$1"
  local reference_window=400000

  local bytes="" fraction=""

  if [ -n "$flag_bytes" ]; then
    bytes="$flag_bytes"
  else
    fraction="0.5"
  fi

  if [ -n "$bytes" ]; then
    fraction=$(jq -n --argjson b "$bytes" --argjson r "$reference_window" '$b / $r')
  else
    bytes=$(jq -n --argjson f "$fraction" --argjson r "$reference_window" '(($r * $f) | floor)')
  fi

  printf '%s %s\n' "$bytes" "$fraction"
}

# Sum the byte sizes of --outline (required) plus every repeated --research,
# --spec, and --prototype path, and report whether the total fits within the
# effective budget. Always exits 0 for valid input (advisory only); exits 1
# only on usage errors (missing --outline, a given path that does not exist).
cmd_estimate_payload() {
  local outline="" budget_bytes_flag=""
  local research_paths=() spec_paths=() prototype_paths=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --outline) shift; outline="${1:-}" ;;
      --research) shift; research_paths+=("${1:-}") ;;
      --spec) shift; spec_paths+=("${1:-}") ;;
      --prototype) shift; prototype_paths+=("${1:-}") ;;
      --budget-bytes) shift; budget_bytes_flag="${1:-}" ;;
      *)
        echo "Error: estimate-payload: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -z "$outline" ]; then
    echo "Error: estimate-payload: --outline <path> is required" >&2
    echo "Usage: aimi-cli.sh estimate-payload --outline <path> [--research <path>]... [--spec <path>]... [--prototype <path>]... [--budget-bytes <n>]" >&2
    exit 1
  fi
  if [ ! -f "$outline" ]; then
    echo "Error: estimate-payload: File not found: $outline" >&2
    exit 1
  fi

  local outline_bytes research_bytes=0 spec_bytes=0 prototype_bytes=0
  outline_bytes=$(_file_size_bytes "$outline")

  local p
  for p in "${research_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    research_bytes=$((research_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${spec_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    spec_bytes=$((spec_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${prototype_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    prototype_bytes=$((prototype_bytes + $(_file_size_bytes "$p")))
  done

  local total_bytes=$((outline_bytes + research_bytes + spec_bytes + prototype_bytes))

  local budget_line budget_bytes budget_fraction
  budget_line=$(_estimate_payload_resolve_budget "$budget_bytes_flag")
  budget_bytes=$(printf '%s' "$budget_line" | cut -d' ' -f1)
  budget_fraction=$(printf '%s' "$budget_line" | cut -d' ' -f2)

  local over_budget=false
  local warning="null"
  if [ "$total_bytes" -gt "$budget_bytes" ]; then
    over_budget=true
    warning='"Payload exceeds budget -- split the phase along a semantic seam in the roadmap, or trim research/prototype scope."'
  fi

  jq -n \
    --argjson total "$total_bytes" \
    --argjson outline "$outline_bytes" \
    --argjson research "$research_bytes" \
    --argjson specs "$spec_bytes" \
    --argjson prototypes "$prototype_bytes" \
    --argjson budgetBytes "$budget_bytes" \
    --argjson budgetFraction "$budget_fraction" \
    --argjson overBudget "$over_budget" \
    --argjson warning "$warning" \
    '{
      totalBytes: $total,
      breakdown: {outline: $outline, research: $research, specs: $specs, prototypes: $prototypes},
      budgetBytes: $budgetBytes,
      budgetFraction: $budgetFraction,
      overBudget: $overBudget,
      warning: $warning
    }'
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
    set-execution-mode <container|inline>
                              Persist a --container/--inline override onto metadata.execution
                              (returns {execution} JSON). Refuses with non-zero exit on a
                              phase-scoped tasks file (metadata.phase present).
    count-pending             Count pending stories
    validate-deps             Validate dependency graph (no cycles, no missing refs)
    validate-stories          Validate story content (length, suspicious patterns)
    normalize-verification <file>
                              Rewrite any story whose verification is a bare string S
                              into {strategy: S, status: "pending", url: null, expect: null}.
                              Already-object verifications are left unchanged.
                              Writes atomically (tmp + mv). Exits 0 on success.
    normalize-status <file>   Default any story missing the status field to "pending".
                              Already-set status values are preserved (uses //= operator).
                              Writes atomically (tmp + mv). Exits 0 on success.
                              Reports count of stories with status field after heal.
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
    get-story-context <id>    Get story slice + metadata + skills[] + designContext as JSON
                              (for subagent self-brief). Output keys: story, metadata, skills,
                              designContext. skills[] contains {name, path, content} per
                              declared skill. designContext contains {decisions, bundleGuidance}.
    get-state                 Get all state files as JSON
    detect-default-branch [--project <path>]
                              Detect and cache the repository's default branch
    detect-parent-branch <branch> [--project <path>]
                              Detect branch's parent (base) branch by token-aware
                              git log decoration parsing + git merge-base verification.
                              Output: {branch, base, verified, source
                              ("decoration"|"default-branch")}. Falls back to the
                              default branch (unverified) when no decoration
                              candidate survives normalization or merge-base check.
    detect-forge [--project <path>]
                              Classify the active git remote's hostname into
                              github|gitlab|gitea|unknown (exact-or-subdomain,
                              port-aware). Output: {forge, host, remote,
                              remoteUrl, source ("override"|"remote"|
                              "no-remote"|"ambiguous-remotes")}. Set
                              AIMI_FORGE_TYPE=github|gitlab|gitea to override
                              detection entirely (source=override, no git
                              remote read runs); any other value exits 1.
                              Never cached -- re-derived on every invocation.
    forge-auth-status [--project <path>]
                              Report whether the active forge session is authenticated
                              and which account it is acting as. Output:
                              {status ("found"|"error"), data, message}. data (when
                              found) carries {forge, host, authenticated, account,
                              identityRequested, identityHonored}. authenticated:false
                              with status="found" is a confirmed logged-out session;
                              status="error" means the check itself could not run (gh
                              missing, or the forge has no adapter). Set
                              AIMI_FORGE_IDENTITY=<login> (env var only, never a flag)
                              to compare against the active account -- this does not
                              switch accounts.
    forge-repo-info [--project <path>]
                              Resolve the active forge's owner/repo via a single
                              `gh repo view` call, falling back to parsing the git
                              remote URL when gh is unavailable. Output:
                              {status ("found"|"not_found"), data, message}. data
                              (when found) carries {forge, host, owner, repo,
                              nameWithOwner, source ("gh"|"local-parse")}.
    detect-interactivity [--non-interactive]
                              Print resolved interactivity mode (picker|agent)
                              Returns picker by default; returns agent only when
                              --non-interactive is passed, AIMI_AGENT_MODE=true, or CI=true
    list-models               List available models for the current host as a JSON array.
                              Claude Code: ["opus","sonnet","haiku"].
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              stdout is always a valid JSON array; warnings go to stderr.
    resolve-models            Resolve configured model for each agent category.
                              Reads ~/.config/aimi/models.json (schema v2.0) and emits
                              a single-line JSON object with keys research, review,
                              design, workflow, executor.
                              Schema v2.0 shape: categories.<host>.<category> = model id.
                              Unconfigured or fallback entries use the literal "inherit".
                              v1.0 configs (top-level .models key or schemaVersion != "2.0")
                              are rejected with a stderr warning; all-inherit returned.
                              Warnings go to stderr; stdout is always valid JSON.
    get-current-models        Emit current per-category model assignments for the
                              active host as a JSON object with keys research, review,
                              design, workflow, executor. Unset entries emit JSON null
                              (not the string "inherit" returned by resolve-models) so
                              picker UIs can pre-select sensible defaults and distinguish
                              "not configured" from an explicit "inherit" override.
                              v1.0 configs rejected identically to resolve-models.
    detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]
                              Detect available models on the current host and write
                              ~/.config/aimi/models.json (schema v2.0).
                              Claude Code: fixed set (opus, sonnet, haiku).
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              Category flags (--research/--review/--design/--workflow/--executor):
                              non-interactive write mode — writes the given
                              category-to-model assignments directly. Preserves the
                              other host's categories sub-table when a file already exists.
                              All five category flags must be supplied together.
                              Interactive (stdin TTY, no flags): prompts per category,
                              validates answer against available-model list.
                              Non-interactive (no flags, stdin not TTY): default mapping
                              (research=fast/haiku, review=powerful/opus,
                              design+workflow+executor=balanced/sonnet).
                              Emits the written JSON on stdout.
    models-prompt-check       Check whether the model-selection prompt should be shown.
                              Per-host decision:
                              - prompt when the config file is missing entirely (always
                                re-trigger after deletion, regardless of any marker)
                              - skip when the current host (claudeCode or opencode) has
                                at least one non-null category
                              - skip when the file is present, the current host is
                                unconfigured, AND the per-host dismissal marker exists
                                (~/.config/aimi/models-prompt-seen-<host>)
                              - prompt otherwise (file present, host unconfigured, no
                                marker) — including v1.0 configs and empty/malformed files
    models-prompt-dismiss     Atomically create the per-host first-run prompt marker file
                              (~/.config/aimi/models-prompt-seen-<host> where <host> is
                              claudeCode or opencode based on CLAUDECODE). Idempotent.
                              Run after the user responds to the prompt on this host
                              (regardless of their choice) so the prompt is not re-shown
                              when the host stays unconfigured. Re-deleting models.json
                              still re-triggers the prompt — the marker only suppresses
                              when the file exists but the host has no config.
    setup-branch <name> --default-branch <branch> [--project <path>]
                              Create or checkout branch with deterministic logic
    resolve-base-branch <name> --default-branch <branch> [--base <branch>] [--project <path>]
                              Decide what branch a new branch or container should be cut
                              from -- no checkout is performed. Prints a single JSON object:
                              {"base","reason","currentBranch","defaultBranch","promptNeeded"}.
                              reason is exactly one of: explicit-base, target-exists,
                              stacked-on-current, default-branch, detached-head.
                              base prefers the origin/<name> remote-tracking ref when it
                              exists, falling back to the bare local name otherwise --
                              except for stacked-on-current, which always keeps the bare
                              local ref, since stacking exists to inherit the local tip.
                              --base "" is treated exactly like an omitted --base, so a
                              caller may pass an unset variable through unconditionally.
                              promptNeeded is true only when the target does not exist
                              (locally or on origin), the current branch is not the
                              default branch, and it is not merged into origin/<default>.
    clear-state               Clear all state files
    version                   Print the plugin version
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    list-archivable           List task files where all stories are completed/skipped (JSON array)
    archive-task <path>       Move completed task file (and linked brainstorm) to .aimi/archive/
    research-lookup [--ignore-missing-cited-paths] <path>
                              Check whether a research .md file is fresh relative to cited source
                              paths listed under its '## File References' h2 bullet section.
                              Freshness: research mtime >= newest mtime of cited source paths.
                              Fresh: prints the resolved research path, exits 0.
                              Stale/undecidable: prints nothing, exits 1.
                              Cited path not found -> stale + stderr warning.
                              --ignore-missing-cited-paths: a missing cited path logs a warning
                                but does NOT mark the file stale (mtime staleness is unaffected).
                                Use when cited sources include to-be-created files.
                              Absolute or outside-root path -> rejected (exit 1).
                              Flag accepted in either position relative to the path arg.
    extract-sections <file> --anchors "<titles>"
                              Print only the requested '## '/'### ' sections of a
                              research .md file, concatenated verbatim in request order.
                              Each section spans its matching heading up to the next
                              heading of the same-or-higher level (or EOF) -- an h2
                              anchor includes nested h3s and stops at the next h2/h1;
                              an h3 anchor stops at the next h3/h2/h1.
                              --anchors accepts comma- or newline-separated heading
                              titles; matching is case-insensitive on heading text.
                              An anchor with no matching heading is skipped (not an
                              error); anchors matching nothing -> empty output, exit 0.
                              Path confinement mirrors research-lookup (resolve_path +
                              validate_path_in_project); missing file or missing
                              <file>/--anchors arg -> error/usage on stderr, exit 1.
    research-gc               Delete orphaned .aimi/research/*.md files not referenced by any
                              active .aimi/tasks/*.json metadata.researchPaths or any
                              .aimi/brainstorms/*.md frontmatter researchPaths, AND older than
                              30 days. .aimi/archive is ignored. Silent when nothing cleaned.
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
    story-merge --staging-dir <dir> --output <path>
                              [--split legacy|full-stack] [--agent-mode]
                              [--phase-aware] [--foundation <NN>]
                              Consolidate per-story staging *.json files into a
                              validated tasks.json. Steps: glob+validate JSON,
                              assign US-NNN IDs by lex order, remap outline:NN
                              tokens in dependsOn, DAG cycle detection, wave
                              computation, Rule 22 mock-sync AC routing, Phase
                              3.1 inventory verdict check, Phase 4.1 coverage
                              ratio (ac_anchors >= floor(proto_elements * 0.6)),
                              Phase 4.2 orphan-symbol smell (heuristic scan of
                              sibling-story prose for symbols a story introduces
                              that no other story references; not codebase
                              dead-code detection — always a warning, never a
                              hard block; skipped for single-story merges).
                              --split full-stack additionally detects
                              cross-file-dep-dropped smells: a dependsOn edge
                              that crosses an output-file boundary (a repo
                              boundary on the PROJECT axis, the
                              frontend/backend boundary on the SIDE axis) is
                              still dropped (each file's graph stays
                              self-contained) but is now surfaced via one
                              aggregated stderr banner plus a
                              metadata.smellWarnings entry per affected story
                              in EVERY output file the split produced (keyed by
                              .project on the PROJECT axis, .side on the SIDE
                              axis).
                              Writes atomically via _lock (tmp+mv). Deletes
                              staging dir on success; preserves on error.
                              --split full-stack picks its axis by counting
                              distinct normalized .project values (trim, strip
                              one trailing slash, blank/absent = null).
                              >= 2 -> PROJECT axis (multi-repo): one output
                              file per project, <base>-<project-slug>-tasks.json,
                              no frontend/backend decision at all; each file
                              carries metadata.splitGroup + its own branchName.
                              A multi-repo plan requires EVERY story to carry a
                              project: once any story is tagged, a project-less
                              story is refused (no files written) rather than
                              routed anywhere. A story belonging to the root
                              repository says so explicitly with "." — an absent
                              project is not the root, it is unrouteable.
                              < 2 -> SIDE axis (single-repo/monorepo, incl. no
                              .project at all): two output files,
                              <base>-frontend-tasks.json and
                              <base>-backend-tasks.json, each story classified
                              by its own file-pattern/title heuristic verdict.
                              Both axes assign unique IDs, rebuild dependsOn,
                              and recompute wave numbers per file.
                              Derived slugs/paths/branch names are length-bounded
                              and REFUSED (never truncated) when over: slug 64,
                              output basename 248, full path 4000, branchName
                              100. Truncation would manufacture a basename
                              collision between two distinct long project values.
                              --phase-aware (only meaningful with --split
                              full-stack): strip one trailing "-tasks" segment
                              from the --output basename before deriving the
                              split basenames. Pure string manipulation on the
                              basename, independent of the axis: on SIDE it
                              yields <base>-frontend-tasks.json /
                              <base>-backend-tasks.json, on PROJECT it yields
                              <base>-<project-slug>-tasks.json — in both cases
                              with a single "tasks" segment instead of the
                              doubled legacy form. Requires an --output basename
                              ending in "-tasks" with at least one character
                              before it (the phase-scoped form, e.g.
                              "<feature>-phase-<N>-tasks.json"); anything else
                              (e.g. "tasks.json") is refused up front, because
                              the strip would otherwise leave an empty or
                              "-"-leading basename. Omitted: unchanged legacy
                              derivation (double "-tasks-frontend-tasks.json").
                              --foundation <NN> two-digit 1-based outline
                              position of the shared foundation story (resolved
                              against the same outline-position map as
                              outline:NN, not a literal staging-filename digit).
                              Appends the foundation's assigned US-NNN to every
                              OTHER story's dependsOn, deduplicated, after the
                              outline:NN remap and before cycle detection and
                              wave computation, so injected edges participate in
                              both. Refuses the whole merge when the foundation
                              story's own dependsOn is non-empty. On the PROJECT
                              axis the foundation lives in exactly one group, so
                              every other group's injected edge is dropped and
                              flagged droppedDeps[].foundationEdge: true, with
                              its own stderr note separate from the ordinary
                              drop-count banner — that loss is expected fallout
                              of --foundation + multi-repo, not a hand-authored
                              dependency that went missing. The SIDE axis emits
                              no foundationEdge field.
                              --agent-mode demotes Phase 3.1 and Phase 4.1
                              hard rejects to warnings and proceeds.
    split-detect [--dir <phase-dir>]
                              Read side of metadata.splitGroup: decide whether
                              the tasks files in scope form ONE split group that
                              must execute together, and report which members
                              still have pending work. A query, never a gate —
                              every outcome, including "single" and "none",
                              exits 0; non-zero is a real error (bad argument,
                              unreadable --dir).
                              Scope. Without --dir: FLAT — *-tasks.json whose
                              parent directory is .aimi/tasks itself, depth 1
                              only. The depth restriction is load-bearing:
                              find-tasks-all globs depth 1-3, which includes
                              phase directories, so without it a phase's split
                              files are captured by the flat flow and run as a
                              flat split — the phase never gets claimed and
                              nothing merges into the phase branch. With --dir:
                              that directory's *-tasks.json, minus the phase's
                              own <feature>-phase-<N>-tasks.json.
                              Algorithm. The anchor is the NEWEST candidate by
                              mtime, not the first marker-carrying file in mtime
                              order — the latter let a stale marked split from a
                              past feature preempt today's plan whenever today's
                              files carried no marker. If the anchor carries a
                              well-formed metadata.splitGroup (total a number,
                              siblings an array), siblings resolve BY BASENAME
                              against the anchor's own directory (which renders
                              a traversal-shaped sibling entry inert) and the
                              resolved count must equal total and be >= 2.
                              A group whose members are ALL completed is dropped
                              whole from the pool and the search repeats, so a
                              finished stale split cannot route today's real work
                              to a single-file fallback. A marker present but
                              failing validation degrades and is terminal — it
                              does NOT fall through to the legacy pair, because
                              any -frontend-/-backend-tasks.json beside a
                              project-split marker is stale work. When the newest
                              candidate carries no marker, the legacy
                              -frontend-tasks.json/-backend-tasks.json pair rule
                              is tried over the pool (counterpart must be in the
                              pool, not merely on disk). Otherwise: single.
                              Pending is (.status // "pending") != "completed" —
                              one definition for every count reported, so an
                              in_progress story is pending everywhere.
                              Output. One JSON object: {mode: "project-split"|
                              "paired-split"|"single"|"none", anchor, members:
                              [{path,project,branchName,storyCount,pendingCount,
                              active}], activeCount, total, degradedReason}.
                              degradedReason explains any fall-back so the caller
                              can report it without re-deriving why.
    verify-creates --feature <slug> --phase <id> [--dir <container-path>]
                              Prove a phase's declared creates[] exist in code.
                              Prints a JSON array, one object per creates[]
                              entry: {identity, status, method, evidence,
                              gitStatus}. status is verified|missing|error;
                              method is "path" (matched a tracked path),
                              "text" (matched tracked source) or null.
                              --dir is the phase container's absolute path;
                              it defaults to the project root.
                              A query, never a gate — producing a verdict array
                              exits 0, including one where every entry is
                              missing. Non-zero is a real error only: unknown
                              flag, absent/non-numeric --phase, absent or
                              malformed roadmap.json, --dir not a directory.
                              Four steps per identity: (1) tracked path via
                              git ls-files, matching a directory as well as a
                              file; (2) strip a leading GET/POST/PUT/PATCH/
                              DELETE/HEAD/OPTIONS token so "POST /api/x" is
                              searched as "/api/x"; (3) git grep -F over
                              tracked source excluding docs and tests, bypassed
                              when the identity is itself documentation;
                              (4) drop hits that are only a TODO/FIXME/XXX/HACK
                              comment. A missing entry's evidence names the
                              rejected location and line, and states that git
                              sees tracked files only. git exiting above 1 is
                              status "error" carrying the code — never
                              "missing": a tool failure is not an absent
                              artifact.
    roadmap-init --feature <slug> [--file <path>] [--sync] [--brainstorm-path <path>]
                              Read a sanitized phases array (stdin or --file) and
                              atomically create/append to .aimi/tasks/<slug>/roadmap.json.
                              Without --sync, an existing roadmap.json is a hard error.
                              With --sync, only phases whose id is not already present
                              are appended; existing phases are left byte-for-byte
                              unchanged. Rejects (before any write) phases with a
                              missing id/name/goal, a dangling dependsOn reference,
                              or a computed dir that fails ^phase-[0-9]+(\.[0-9]+)?
                              (-[a-z0-9][a-z0-9-]*)?$. Free-text fields are sanitized
                              and length-capped per commands/references/sanitization.md.
    roadmap-get --feature <slug> [--phase <id>] [--next-eligible]
                              Read-only. Bare: print the full roadmap.json.
                              --phase <id>: print one phase object.
                              --next-eligible: print the lowest numeric-id phase
                              in pending/planned status, unclaimed, whose dependsOn
                              phases are all completed; exits 1 if none.
    roadmap-set-status --feature <slug> --phase <id> --status <status> [--force]
                              Locked read-modify-write. Enforces the guarded order
                              pending -> planned -> in_progress -> completed, plus
                              verification_failed -> completed (retry path); any
                              status may move to verification_failed. Other
                              transitions require --force. Transitioning to
                              completed always requires handoff.md to already
                              exist on disk at the phase's dir (write it first
                              with roadmap-write-handoff) -- this precondition
                              is NOT overridable by --force. A completed
                              transition also clears the phase's claim in the
                              same atomic write.
    roadmap-write-handoff --feature <slug> --phase <id> [--file <path>]
                              Read a JSON object (stdin or --file) with five
                              optional array-of-string fields -- decisions,
                              artifacts, deviations, deferred, contracts --
                              sanitize each entry, and atomically write
                              phase-<dir>/handoff.md with exactly five "## "
                              headings in that fixed order: Decisions Made,
                              Artifacts Created, Deviations, Deferred Items,
                              Contracts Delivered. This is the only path that
                              may create or overwrite that file -- direct
                              Write/Edit tool calls on it are blocked by
                              guard-runtime-state.py.
    roadmap-claim --feature <slug> --session-id <id> --session-pid <pid> [--phase <id>]
                              Atomic locked read-modify-write. Auto-releases any
                              claim whose recorded pid fails a signal-zero liveness
                              probe. Self-reclaim: if this session already owns an
                              unreleased claim on a still-active phase (matching
                              --phase when given), returns that same phase again
                              instead of erroring or re-running eligibility.
                              Without --phase: claims the lowest numeric-id phase
                              that is pending/planned, unclaimed, and dependency-
                              complete. With --phase <id>: claims that phase only
                              if eligible; never falls through to a different phase.
                              Exit 0 with the claimed phase JSON on success.
                              Exit 3 (all-blocked / phase not claimable): pending/
                              planned phases remain but none (or the named --phase)
                              are currently claimable (stderr lists why).
                              Exit 4 (none-eligible / phase not found): no phase
                              remains pending/planned, or --phase names an id that
                              does not exist in the roadmap.
                              roadmap.json is left unmodified on exit 3 or 4.
    roadmap-release-claim --feature <slug> --phase <id>
                              Locked read-modify-write. Clears claimedBy/claimedAt/
                              claimedPid on the named phase without touching status.
                              No-op success when the phase already has no claim.
    roadmap-reconcile --feature <slug>
                              Locked read-modify-write. For each phase with an
                              existing phase-<dir>/tasks.json, derives ground-truth
                              status from userStories statuses (all completed ->
                              completed; any failed -> verification_failed; else
                              in_progress) and corrects any divergent phase status.
                              Prints {corrections:[{id,from,to}...]}.
    phase-overlap <feature> <phase-a> <phase-b>
                              Deterministic stage-2 check for the sibling-phase
                              overlap guard. Loads both phases' already-expanded
                              phase-<dir>/<feature>-phase-<id>-tasks.json files,
                              collects userStories[].implementation.files across
                              all stories in each, and prints the sorted,
                              deduplicated intersection as {"overlapping_files":[...]}.
                              Exits non-zero with a clear error (not a jq stack
                              trace) when either phase's tasks.json is missing --
                              both phases must already be rolling-wave expanded.
    estimate-payload --outline <path> [--research <path>]... [--spec <path>]...
                              [--prototype <path>]... [--budget-bytes <n>]
                              Advisory only -- never blocks, never trims content.
                              Sums the byte sizes of --outline (required) plus every
                              repeated --research/--spec/--prototype path and compares
                              against an effective budget: --budget-bytes (manual debug
                              escape hatch; no caller passes it) if given, else 50% of a
                              400000-byte reference sub-agent window.
                              Prints {totalBytes, breakdown{outline,research,specs,prototypes},
                              budgetBytes, budgetFraction, overBudget, warning}.
                              warning is null under budget; otherwise names splitting the
                              phase along a semantic seam in the roadmap or trimming scope.
                              Exits 0 for any valid input (even over budget); exits 1 only
                              when --outline is missing or a given path does not exist.
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

    # Fetch story slice + metadata + skills + designContext (for subagent self-brief)
    # Output: {story, metadata, skills[{name,path,content}], designContext{decisions,bundleGuidance}}
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
    detect-interactivity) shift; cmd_detect_interactivity "$@"; return ;;
    list-models) cmd_list_models; return ;;
    resolve-models) shift; cmd_resolve_models "$@"; return ;;
    get-current-models) cmd_get_current_models; return ;;
    detect-models) shift; cmd_detect_models "$@"; return ;;
    models-prompt-check) cmd_models_prompt_check; return ;;
    models-prompt-dismiss) cmd_models_prompt_dismiss; return ;;
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
    set-execution-mode) cmd_set_execution_mode "${2:-}" ;;
    count-pending)     cmd_count_pending ;;
    validate-deps)            cmd_validate_deps ;;
    validate-stories)         cmd_validate_stories ;;
    normalize-verification)   cmd_normalize_verification "${2:-}" ;;
    normalize-status)         cmd_normalize_status "${2:-}" ;;
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
    detect-parent-branch) shift; cmd_detect_parent_branch "$@" ;;
    detect-forge) shift; cmd_detect_forge "$@" ;;
    forge-auth-status) shift; cmd_forge_auth_status "$@" ;;
    forge-repo-info)   shift; cmd_forge_repo_info "$@" ;;
    setup-branch)      shift; cmd_setup_branch "$@" ;;
    resolve-base-branch) shift; cmd_resolve_base_branch "$@" ;;
    clear-state)       cmd_clear_state ;;
    version)           cmd_version ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    prime-cache)       cmd_prime_cache ;;
    list-archivable)   cmd_list_archivable ;;
    archive-task)      cmd_archive_task "${2:-}" ;;
    research-lookup)   shift; cmd_research_lookup "$@" ;;
    research-gc)       cmd_research_gc ;;
    extract-sections)  shift; cmd_extract_sections "$@" ;;
    detect-design-bundle) shift; cmd_detect_design_bundle "$@" ;;
    bundle-prototype-status)   shift; cmd_bundle_prototype_status "$@" ;;
    bundle-prototype-finalize) shift; cmd_bundle_prototype_finalize "$@" ;;
    story-merge)       shift; cmd_story_merge "$@" ;;
    split-detect)      shift; cmd_split_detect "$@" ;;
    roadmap-init)          shift; cmd_roadmap_init "$@" ;;
    roadmap-get)           shift; cmd_roadmap_get "$@" ;;
    roadmap-set-status)    shift; cmd_roadmap_set_status "$@" ;;
    roadmap-claim)         shift; cmd_roadmap_claim "$@" ;;
    roadmap-release-claim) shift; cmd_roadmap_release_claim "$@" ;;
    roadmap-reconcile)     shift; cmd_roadmap_reconcile "$@" ;;
    roadmap-write-handoff) shift; cmd_roadmap_write_handoff "$@" ;;
    validate-contracts)    shift; cmd_validate_contracts "$@" ;;
    verify-creates)        shift; cmd_verify_creates "$@" ;;
    phase-overlap)         shift; cmd_phase_overlap "$@" ;;
    roadmap-sweep)         shift; cmd_roadmap_sweep "$@" ;;
    estimate-payload)      shift; cmd_estimate_payload "$@" ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
