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
# On success: cd to the discovered root, rewrite AIMI_DIR and TASKS_DIR to absolute paths.
# On failure (reached /): exit 1 with error to stderr.
find_aimi_root() {
  local dir
  dir=$(pwd)
  while true; do
    if [ -d "$dir/.aimi" ]; then
      cd "$dir"
      AIMI_DIR="$dir/.aimi"
      TASKS_DIR="$AIMI_DIR/tasks"
      return 0
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
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

# Write a value to a state file (flock-protected for parallel safety)
write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  (
    _lock "$AIMI_DIR/.state.lock"
    echo "$value" > "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Clear a single state file (flock-protected for parallel safety)
clear_state_file() {
  local key="$1"
  (
    _lock "$AIMI_DIR/.state.lock"
    rm -f "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Extract version string from an aimi-cli.sh path
# Given: ~/.claude/plugins/cache/foo/aimi-engineering/1.4.0/scripts/aimi-cli.sh
# Returns: 1.4.0
_extract_version_from_path() {
  local path="$1"
  local no_script="${path%/*}"       # strip /aimi-cli.sh -> .../scripts
  local no_scripts="${no_script%/*}" # strip /scripts -> .../1.4.0
  printf '%s\n' "${no_scripts##*/}"  # strip prefix -> 1.4.0
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
    echo "Warning: state file pointed to $stale_path which no longer exists. Using $tasks_file instead." >&2
    write_state "current-tasks" "$tasks_file"
  elif [ -z "$tasks_file" ]; then
    tasks_file=$(ls -t "$TASKS_DIR"/*-tasks.json 2>/dev/null | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
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

# Initialize execution session
cmd_init_session() {
  local tasks_file branch pending

  tasks_file=$(cmd_find_tasks)
  write_state "current-tasks" "$tasks_file"

  # Self-resolve: persist this CLI's absolute path for future sessions
  write_state "cli-path" "$(resolve_path "$0")"

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
    echo "$result" | jq '[.[] | {id, title, priority, dependsOn}]'
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
        ([$s.acceptanceCriteria[] | select(length > 300)] | if length > 0 then ["\($s.id): acceptance criterion exceeds 300 chars"] else [] end) +
        (if ($s.title | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): title contains suspicious content"] else [] end) +
        (if ($s.description | test("ignore previous|system:|INSTRUCTIONS|```|\\$\\(|`"; "i")) then ["\($s.id): description contains suspicious content"] else [] end)
      ) | .[]
    ] |
    if length == 0 then {valid: true, errors: []}
    else {valid: false, errors: .}
    end
  ' "$tasks_file"
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

# Clear all state files (preserves tasks directory)
cmd_clear_state() {
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result" "$AIMI_DIR/cli-path"
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

  # Resolve the latest installed path via glob
  latest_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

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
# Scans ~/.claude/plugins/cache/*/aimi-engineering/*/ for version dirs
# Outputs JSON {"removed":<count>,"kept":"<version>"} to stdout
cmd_cleanup_versions() {
  local latest_path latest_version latest_version_dir
  local removed=0

  # Resolve the latest installed path via glob
  latest_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

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
  for version_dir in ~/.claude/plugins/cache/*/aimi-engineering/*/; do
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

  jq -n --argjson removed "$removed" --arg kept "$latest_version" \
    '{removed: $removed, kept: $kept}'
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
    cascade-skip <id>         Skip all stories depending on failed story
    reset-orphaned            Reset all in_progress stories to failed
    get-branch                Get branchName from metadata
    get-state                 Get all state files as JSON
    clear-state               Clear all state files
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    help                      Show this help message

STATE FILES (.aimi/):
    current-tasks             Path to active tasks file
    current-branch            Current working branch name
    current-story             ID of story being executed
    last-result               Result of last execution (success/failed/skipped)

EXAMPLES:
    # Resolve CLI path first
    AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

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
    init-session)      cmd_init_session ;;
    find-tasks)        cmd_find_tasks ;;
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
    cascade-skip)      cmd_cascade_skip "${2:-}" ;;
    reset-orphaned)    cmd_reset_orphaned ;;
    get-branch)        cmd_get_branch ;;
    get-state)         cmd_get_state ;;
    clear-state)       cmd_clear_state ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
