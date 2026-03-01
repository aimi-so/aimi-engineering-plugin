#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.
# Operates on v3 task schema exclusively.

AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"
SWARM_STATE_FILE="$AIMI_DIR/swarm-state.json"

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
cmd_status() {
  local tasks_file
  tasks_file=$(get_tasks_file)

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
}

# Get metadata only
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata | .maxConcurrency = ((.maxConcurrency // 4) | if . <= 0 then 4 else . end)' "$tasks_file"
}

# List stories that are ready to execute
# A story is ready when: status == "pending" AND all dependsOn stories have status "completed" or "skipped"
cmd_list_ready() {
  local tasks_file
  tasks_file=$(get_tasks_file)

  jq '
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
  ' "$tasks_file"
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

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
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
    status                    Get status summary as JSON
    metadata                  Get metadata only
    next-story                Get next pending story, save to state
    current-story             Get currently active story from state
    list-ready                List stories ready to execute (dependency-aware)
    mark-in-progress <id>     Mark story as in_progress
    mark-complete <id>        Mark story as completed
    mark-failed <id> [notes]  Mark story as failed with notes
    mark-skipped <id>         Mark story as skipped
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

  Swarm Management:
    swarm-init [--force]      Initialize swarm state (creates .aimi/swarm-state.json)
    swarm-add <cid> <name> <taskFile> <branch>
                              Add container entry to swarm state
    swarm-update <name> --status <s> [--pr-url <url>] [--story-progress <json>] [--acp-pid <pid>]
                              Update container fields by name (flock-protected)
    swarm-remove <name>       Remove container entry by name
    swarm-status              Output current swarm state as formatted JSON
    swarm-list                List container names and statuses (TSV)
    swarm-cleanup             Remove completed/failed container entries

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

    # --- Swarm management ---
    # Initialize a new swarm
    $AIMI_CLI swarm-init

    # Add a container to the swarm
    $AIMI_CLI swarm-add abc123def456 aimi-sandbox-US-001 .aimi/tasks/2026-03-01-feature-tasks.json feat/feature

    # Update container status and progress
    $AIMI_CLI swarm-update aimi-sandbox-US-001 --status running --story-progress '{"total":5,"completed":2,"failed":0,"inProgress":1,"pending":2}'

    # List all containers
    $AIMI_CLI swarm-list

    # Clean up finished containers
    $AIMI_CLI swarm-cleanup
EOF
}

# ============================================================================
# Swarm State Management Commands
# ============================================================================

# Portable UUID v4 generator (no external dependencies)
_generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: generate from /dev/urandom
    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    # Format as UUID v4: set version (4) and variant (8-b) bits
    printf '%s-%s-4%s-%s%s-%s\n' \
      "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
      "$(printf '%x' $(( 0x${hex:16:2} & 0x3f | 0x80 )))" \
      "${hex:18:2}" "${hex:20:12}"
  fi
}

# Get current ISO 8601 timestamp
_iso_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Validate container name format: ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$
# Harmonized with sandbox-manager.sh validate_container_name
_validate_container_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "Error: Container name is required." >&2
    exit 1
  fi
  if ! [[ "$name" =~ ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "Error: Invalid container name: $name (must match ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*\$)" >&2
    exit 1
  fi
}

# Validate container ID format: ^[0-9a-f]{12,64}$
_validate_container_id() {
  local cid="$1"
  if [ -z "$cid" ]; then
    echo "Error: Container ID is required." >&2
    exit 1
  fi
  if ! [[ "$cid" =~ ^[0-9a-f]{12,64}$ ]]; then
    echo "Error: Invalid container ID: $cid (must be 12-64 hex chars)" >&2
    exit 1
  fi
}

# Validate container status: pending|running|completed|failed|stopped
_validate_container_status() {
  local status="$1"
  case "$status" in
    pending|running|completed|failed|stopped) ;;
    *)
      echo "Error: Invalid container status: $status (must be pending|running|completed|failed|stopped)" >&2
      exit 1
      ;;
  esac
}

# Validate branch name: ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
_validate_branch_name() {
  local branch="$1"
  if [ -z "$branch" ]; then
    echo "Error: Branch name is required." >&2
    exit 1
  fi
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi
}

# Validate swarm state file exists
_require_swarm_state() {
  if [ ! -f "$SWARM_STATE_FILE" ]; then
    echo "Error: No active swarm. Run 'swarm-init' first." >&2
    exit 1
  fi
}

# Validate container name exists in swarm state
_require_container_exists() {
  local name="$1"
  if ! jq -e --arg name "$name" '.containers[] | select(.containerName == $name)' "$SWARM_STATE_FILE" > /dev/null 2>&1; then
    echo "Error: Container '$name' not found in swarm state." >&2
    exit 1
  fi
}

# Initialize a new swarm state file
# Usage: aimi-cli.sh swarm-init [--force]
cmd_swarm_init() {
  local force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  ensure_state_dir

  # Check for existing active swarm
  if [ -f "$SWARM_STATE_FILE" ] && [ "$force" -eq 0 ]; then
    # Check if there are any non-terminal containers
    local active_count
    active_count=$(jq '[.containers[] | select(.status == "pending" or .status == "running")] | length' "$SWARM_STATE_FILE" 2>/dev/null || echo 0)
    if [ "$active_count" -gt 0 ]; then
      echo "Error: Active swarm exists with $active_count running/pending containers. Use --force to overwrite." >&2
      exit 1
    fi
  fi

  local swarm_id now
  swarm_id=$(_generate_uuid)
  now=$(_iso_timestamp)

  # Atomic write using flock
  local tmp_file
  tmp_file=$(mktemp "${SWARM_STATE_FILE}.XXXXXX")
  (
    _lock "${SWARM_STATE_FILE}.lock"
    jq -n --arg swarmId "$swarm_id" --arg now "$now" \
      '{
        swarmId: $swarmId,
        createdAt: $now,
        updatedAt: $now,
        containers: []
      }' > "$tmp_file" && mv "$tmp_file" "$SWARM_STATE_FILE"
  ) 200>"${SWARM_STATE_FILE}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq '.' "$SWARM_STATE_FILE"
}

# Add a container entry to swarm state
# Usage: aimi-cli.sh swarm-add <containerId> <containerName> <taskFilePath> <branchName>
cmd_swarm_add() {
  local container_id="${1:-}"
  local container_name="${2:-}"
  local task_file_path="${3:-}"
  local branch_name="${4:-}"

  if [ -z "$container_id" ] || [ -z "$container_name" ] || [ -z "$task_file_path" ] || [ -z "$branch_name" ]; then
    echo "Usage: aimi-cli.sh swarm-add <containerId> <containerName> <taskFilePath> <branchName>" >&2
    exit 1
  fi

  _require_swarm_state
  _validate_container_id "$container_id"
  _validate_container_name "$container_name"
  _validate_branch_name "$branch_name"

  # Check for duplicate container name
  if jq -e --arg name "$container_name" '.containers[] | select(.containerName == $name)' "$SWARM_STATE_FILE" > /dev/null 2>&1; then
    echo "Error: Container '$container_name' already exists in swarm state." >&2
    exit 1
  fi

  local now
  now=$(_iso_timestamp)

  # Atomic update using flock
  local tmp_file
  tmp_file=$(mktemp "${SWARM_STATE_FILE}.XXXXXX")
  (
    _lock "${SWARM_STATE_FILE}.lock"
    jq --arg cid "$container_id" \
       --arg cname "$container_name" \
       --arg tfp "$task_file_path" \
       --arg branch "$branch_name" \
       --arg now "$now" \
      '.updatedAt = $now |
       .containers += [{
         containerId: $cid,
         containerName: $cname,
         taskFilePath: $tfp,
         branchName: $branch,
         status: "pending",
         prUrl: null,
         storyProgress: {total: 0, completed: 0, failed: 0, inProgress: 0, pending: 0},
         createdAt: $now,
         updatedAt: $now,
         acpPid: null
       }]' "$SWARM_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$SWARM_STATE_FILE"
  ) 200>"${SWARM_STATE_FILE}.lock"
  rm -f "$tmp_file" 2>/dev/null

  # Output the added container entry
  jq --arg name "$container_name" '.containers[] | select(.containerName == $name)' "$SWARM_STATE_FILE"
}

# Update a container's status and optional fields
# Usage: aimi-cli.sh swarm-update <containerName> --status <status> [--pr-url <url>] [--story-progress <json>] [--acp-pid <pid>]
cmd_swarm_update() {
  local container_name="${1:-}"

  if [ -z "$container_name" ]; then
    echo "Usage: aimi-cli.sh swarm-update <containerName> --status <status> [--pr-url <url>] [--story-progress <json>] [--acp-pid <pid>]" >&2
    exit 1
  fi
  shift

  _require_swarm_state
  _validate_container_name "$container_name"
  _require_container_exists "$container_name"

  # Parse optional arguments
  local status="" pr_url="" story_progress="" acp_pid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --status)
        status="$2"; shift 2
        _validate_container_status "$status"
        ;;
      --pr-url)
        pr_url="$2"; shift 2 ;;
      --story-progress)
        story_progress="$2"; shift 2
        # Validate JSON structure
        if ! echo "$story_progress" | jq -e '.total and .completed != null and .failed != null and .inProgress != null and .pending != null' > /dev/null 2>&1; then
          echo "Error: --story-progress must be JSON with fields: total, completed, failed, inProgress, pending" >&2
          exit 1
        fi
        ;;
      --acp-pid)
        acp_pid="$2"; shift 2
        if [ "$acp_pid" != "null" ] && ! [[ "$acp_pid" =~ ^[0-9]+$ ]]; then
          echo "Error: --acp-pid must be a positive integer or 'null'" >&2
          exit 1
        fi
        ;;
      *)
        echo "Error: Unknown option: $1" >&2
        echo "Usage: aimi-cli.sh swarm-update <containerName> --status <status> [--pr-url <url>] [--story-progress <json>] [--acp-pid <pid>]" >&2
        exit 1
        ;;
    esac
  done

  # At least one field must be provided
  if [ -z "$status" ] && [ -z "$pr_url" ] && [ -z "$story_progress" ] && [ -z "$acp_pid" ]; then
    echo "Error: At least one update field is required (--status, --pr-url, --story-progress, --acp-pid)" >&2
    exit 1
  fi

  local now
  now=$(_iso_timestamp)

  # Build jq update expression dynamically
  local jq_expr='.updatedAt = $now | (.containers[] | select(.containerName == $name)) |= (. + {updatedAt: $now}'
  local jq_args=(--arg name "$container_name" --arg now "$now")

  if [ -n "$status" ]; then
    jq_expr="$jq_expr | .status = \$new_status"
    jq_args+=(--arg new_status "$status")
  fi

  if [ -n "$pr_url" ]; then
    jq_expr="$jq_expr | .prUrl = \$new_pr_url"
    jq_args+=(--arg new_pr_url "$pr_url")
  fi

  if [ -n "$story_progress" ]; then
    jq_expr="$jq_expr | .storyProgress = \$new_progress"
    jq_args+=(--argjson new_progress "$story_progress")
  fi

  if [ -n "$acp_pid" ]; then
    if [ "$acp_pid" = "null" ]; then
      jq_expr="$jq_expr | .acpPid = null"
    else
      jq_expr="$jq_expr | .acpPid = \$new_pid"
      jq_args+=(--argjson new_pid "$acp_pid")
    fi
  fi

  jq_expr="$jq_expr)"

  # Atomic update using flock
  local tmp_file
  tmp_file=$(mktemp "${SWARM_STATE_FILE}.XXXXXX")
  (
    _lock "${SWARM_STATE_FILE}.lock"
    jq "${jq_args[@]}" "$jq_expr" "$SWARM_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$SWARM_STATE_FILE"
  ) 200>"${SWARM_STATE_FILE}.lock"
  rm -f "$tmp_file" 2>/dev/null

  # Output the updated container entry
  jq --arg name "$container_name" '.containers[] | select(.containerName == $name)' "$SWARM_STATE_FILE"
}

# Remove a container entry by name
# Usage: aimi-cli.sh swarm-remove <containerName>
cmd_swarm_remove() {
  local container_name="${1:-}"

  if [ -z "$container_name" ]; then
    echo "Usage: aimi-cli.sh swarm-remove <containerName>" >&2
    exit 1
  fi

  _require_swarm_state
  _validate_container_name "$container_name"
  _require_container_exists "$container_name"

  local now
  now=$(_iso_timestamp)

  # Atomic update using flock
  local tmp_file
  tmp_file=$(mktemp "${SWARM_STATE_FILE}.XXXXXX")
  (
    _lock "${SWARM_STATE_FILE}.lock"
    jq --arg name "$container_name" --arg now "$now" \
      '.updatedAt = $now | .containers = [.containers[] | select(.containerName != $name)]' \
      "$SWARM_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$SWARM_STATE_FILE"
  ) 200>"${SWARM_STATE_FILE}.lock"
  rm -f "$tmp_file" 2>/dev/null

  echo "Removed container: $container_name"
}

# Output current swarm state as formatted JSON
# Usage: aimi-cli.sh swarm-status
cmd_swarm_status() {
  _require_swarm_state
  jq '.' "$SWARM_STATE_FILE"
}

# Output container names and statuses as tab-separated values
# Usage: aimi-cli.sh swarm-list
cmd_swarm_list() {
  _require_swarm_state
  jq -r '.containers[] | [.containerName, .status] | @tsv' "$SWARM_STATE_FILE"
}

# Remove all entries with terminal status (completed, failed, stopped)
# Usage: aimi-cli.sh swarm-cleanup
cmd_swarm_cleanup() {
  _require_swarm_state

  local removed_count
  removed_count=$(jq '[.containers[] | select(.status == "completed" or .status == "failed" or .status == "stopped")] | length' "$SWARM_STATE_FILE")

  if [ "$removed_count" -eq 0 ]; then
    echo "No completed, failed, or stopped containers to clean up."
    return
  fi

  local now
  now=$(_iso_timestamp)

  # Atomic update using flock
  local tmp_file
  tmp_file=$(mktemp "${SWARM_STATE_FILE}.XXXXXX")
  (
    _lock "${SWARM_STATE_FILE}.lock"
    jq --arg now "$now" \
      '.updatedAt = $now | .containers = [.containers[] | select(.status != "completed" and .status != "failed" and .status != "stopped")]' \
      "$SWARM_STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$SWARM_STATE_FILE"
  ) 200>"${SWARM_STATE_FILE}.lock"
  rm -f "$tmp_file" 2>/dev/null

  jq -n --argjson count "$removed_count" '{removed: $count}'
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  check_jq

  case "${1:-help}" in
    init-session)      cmd_init_session ;;
    find-tasks)        cmd_find_tasks ;;
    status)            cmd_status ;;
    metadata)          cmd_metadata ;;
    next-story)        cmd_next_story ;;
    current-story)     cmd_current_story ;;
    list-ready)        cmd_list_ready ;;
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
    swarm-init)        shift; cmd_swarm_init "$@" ;;
    swarm-add)         cmd_swarm_add "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
    swarm-update)      shift; cmd_swarm_update "$@" ;;
    swarm-remove)      cmd_swarm_remove "${2:-}" ;;
    swarm-status)      cmd_swarm_status ;;
    swarm-list)        cmd_swarm_list ;;
    swarm-cleanup)     cmd_swarm_cleanup ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
