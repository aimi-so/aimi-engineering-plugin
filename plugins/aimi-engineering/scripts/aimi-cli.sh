#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.
# Supports both v2.2 and v3 task schemas.

AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"

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

# Detect schema version from tasks file
# Returns "2.2" or "3.0"
detect_schema() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq -r '.schemaVersion // "2.2"' "$tasks_file"
}

# Check if current schema is v3
is_v3() {
  local version
  version=$(detect_schema)
  [ "$version" = "3.0" ]
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

# Detect and print schema version
cmd_detect_schema() {
  detect_schema
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

  local version
  version=$(jq -r '.schemaVersion // "2.2"' "$tasks_file")

  if [ "$version" = "3.0" ]; then
    pending=$(jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file")
  else
    pending=$(jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file")
  fi

  jq -n --arg tasks "$tasks_file" --arg branch "$branch" --argjson pending "$pending" --arg version "$version" \
    '{tasks: $tasks, branch: $branch, pending: $pending, schemaVersion: $version}'
}

# Get comprehensive status summary
cmd_status() {
  local tasks_file version
  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" = "3.0" ]; then
    jq '{
      schemaVersion: .schemaVersion,
      title: .metadata.title,
      branch: .metadata.branchName,
      maxConcurrency: (.metadata.maxConcurrency // 4),
      pending: [.userStories[] | select(.status == "pending")] | length,
      in_progress: [.userStories[] | select(.status == "in_progress")] | length,
      completed: [.userStories[] | select(.status == "completed")] | length,
      failed: [.userStories[] | select(.status == "failed")] | length,
      skipped: [.userStories[] | select(.status == "skipped")] | length,
      total: .userStories | length,
      stories: [.userStories[] | {id, title, status, dependsOn: (.dependsOn // []), priority, notes}]
    }' "$tasks_file"
  else
    jq '{
      schemaVersion: (.schemaVersion // "2.2"),
      title: .metadata.title,
      branch: .metadata.branchName,
      pending: [.userStories[] | select(.passes == false and .skipped != true)] | length,
      completed: [.userStories[] | select(.passes == true)] | length,
      skipped: [.userStories[] | select(.skipped == true)] | length,
      total: .userStories | length,
      stories: [.userStories[] | {id, title, passes, skipped: (.skipped // false), notes}]
    }' "$tasks_file"
  fi
}

# Get metadata only
cmd_metadata() {
  local tasks_file
  tasks_file=$(get_tasks_file)
  jq '.metadata' "$tasks_file"
}

# List stories that are ready to execute (v3 only)
# A story is ready when: status == "pending" AND all dependsOn stories have status "completed" or "skipped"
cmd_list_ready() {
  local tasks_file version
  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" != "3.0" ]; then
    echo "Error: list-ready is only available for v3 schema files" >&2
    exit 1
  fi

  jq '[
    .userStories[] |
    select(.status == "pending") |
    . as $story |
    if (($story.dependsOn // []) | length) == 0 then
      $story
    else
      # Check that all dependencies are completed or skipped
      ($story.dependsOn // []) as $deps |
      [input_filename] |  # dummy to access root
      $story |
      select(
        # We need to check deps against all stories
        true
      )
    end
  ]' "$tasks_file" > /dev/null 2>&1 || true

  # Use a more straightforward approach: build the ready list with proper root access
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
  local tasks_file story story_id version
  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" = "3.0" ]; then
    # v3: use dependency-aware ready logic, then sort by priority as tiebreaker
    story=$(jq '
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
      ] | sort_by(.priority) | .[0]
    ' "$tasks_file")
  else
    # v2.2: sort by priority, pick first non-completed non-skipped
    story=$(jq '[.userStories[] | select(.passes == false and .skipped != true)] | sort_by(.priority) | .[0]' "$tasks_file")
  fi

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

# Mark a story as in-progress (v3 only)
cmd_mark_in_progress() {
  local story_id="$1"
  local tasks_file version

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-in-progress <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" != "3.0" ]; then
    echo "Error: mark-in-progress is only available for v3 schema files" >&2
    exit 1
  fi

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"
  jq --arg id "$story_id" \
    '(.userStories[] | select(.id == $id)) |= . + {status: "in_progress"}' \
    "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"

  write_state "current-story" "$story_id"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as complete
cmd_mark_complete() {
  local story_id="$1"
  local tasks_file version

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"

  if [ "$version" = "3.0" ]; then
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "completed"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  else
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {passes: true}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  fi

  clear_state_file "current-story"
  write_state "last-result" "success"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as failed with notes
cmd_mark_failed() {
  local story_id="$1"
  local notes="${2:-}"
  local tasks_file version

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-failed <story-id> [notes]" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"

  if [ "$version" = "3.0" ]; then
    jq --arg id "$story_id" --arg notes "$notes" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "failed", notes: $notes}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  else
    jq --arg id "$story_id" --arg notes "$notes" \
      '(.userStories[] | select(.id == $id)) |= . + {notes: $notes}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  fi

  clear_state_file "current-story"
  write_state "last-result" "failed"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Mark a story as skipped
cmd_mark_skipped() {
  local story_id="$1"
  local tasks_file version

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  # Atomic update using temp file
  local tmp_file="${tasks_file}.tmp"

  if [ "$version" = "3.0" ]; then
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {status: "skipped"}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  else
    jq --arg id "$story_id" \
      '(.userStories[] | select(.id == $id)) |= . + {skipped: true}' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  fi

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  jq --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file"
}

# Count pending stories
cmd_count_pending() {
  local tasks_file version
  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" = "3.0" ]; then
    jq '[.userStories[] | select(.status == "pending")] | length' "$tasks_file"
  else
    jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' "$tasks_file"
  fi
}

# Validate dependencies in a v3 tasks file
# Checks for: circular dependencies, missing IDs, self-references
cmd_validate_deps() {
  local tasks_file version
  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" != "3.0" ]; then
    echo "Error: validate-deps is only available for v3 schema files" >&2
    exit 1
  fi

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

# Cascade skip: given a failed story ID, mark all transitively-dependent stories as skipped
cmd_cascade_skip() {
  local failed_id="$1"
  local tasks_file version

  if [ -z "$failed_id" ]; then
    echo "Usage: aimi-cli.sh cascade-skip <story-id>" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)
  version=$(detect_schema)

  if [ "$version" != "3.0" ]; then
    echo "Error: cascade-skip is only available for v3 schema files" >&2
    exit 1
  fi

  # Find all stories that transitively depend on the failed story and mark them as skipped
  local tmp_file="${tasks_file}.tmp"
  jq --arg failed_id "$failed_id" '
    # Iteratively find all transitive dependents
    . as $root |

    # Start with direct dependents of the failed story
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
    ) as $all_skip_ids |

    # Remove the original failed story from skip list (it should stay as failed)
    ($all_skip_ids | map(select(. != $failed_id))) as $to_skip |

    # Update stories
    .userStories |= [
      .[] |
      if (.id as $sid | $to_skip | any(. == $sid)) then
        . + {status: "skipped", notes: ("Skipped: depends on failed story " + $failed_id)}
      else
        .
      end
    ] |

    # Return the list of skipped story IDs
    . as $updated |
    {
      skipped: $to_skip,
      count: ($to_skip | length),
      tasks_file_updated: true
    }
  ' "$tasks_file" > "$tmp_file"

  # The jq above outputs the result JSON but also transforms the file
  # We need a different approach: update file in place and output separately

  # Re-do: first compute which IDs to skip, then update the file
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

  # Update the file
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

  # Clean up the other tmp file if it exists
  rm -f "${tasks_file}.tmp"

  # Output result
  local count
  count=$(echo "$to_skip" | jq 'length')
  jq -n --argjson skipped "$to_skip" --argjson count "$count" \
    '{skipped: $skipped, count: $count}'
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
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result"
  echo "State cleared."
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
    detect-schema             Detect schema version (returns '2.2' or '3.0')
    status                    Get status summary as JSON
    metadata                  Get metadata only
    next-story                Get next pending story, save to state
    current-story             Get currently active story from state
    list-ready                List stories ready to execute (v3 only, dependency-aware)
    mark-in-progress <id>     Mark story as in_progress (v3 only)
    mark-complete <id>        Mark story as passed/completed
    mark-failed <id> [notes]  Mark story with failure notes/status
    mark-skipped <id>         Mark story as skipped
    count-pending             Count pending stories
    validate-deps             Validate dependency graph (v3 only)
    cascade-skip <id>         Skip all stories depending on failed story (v3 only)
    get-branch                Get branchName from metadata
    get-state                 Get all state files as JSON
    clear-state               Clear all state files
    help                      Show this help message

SCHEMA SUPPORT:
    v2.2 - Original schema with passes boolean, priority-based ordering
    v3.0 - New schema with status field, dependsOn arrays, parallel execution

    Commands automatically detect schema version and adapt behavior.
    v3-only commands (list-ready, mark-in-progress, validate-deps, cascade-skip)
    will error when used with v2.2 files.

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

    # Check schema version
    $AIMI_CLI detect-schema

    # Get next story to work on (dependency-aware for v3)
    $AIMI_CLI next-story

    # List all ready stories (v3 parallel execution)
    $AIMI_CLI list-ready

    # Mark story in progress (v3)
    $AIMI_CLI mark-in-progress US-001

    # Mark story as complete
    $AIMI_CLI mark-complete US-001

    # Validate dependency graph (v3)
    $AIMI_CLI validate-deps

    # Cascade skip after failure (v3)
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
  check_jq

  case "${1:-help}" in
    init-session)      cmd_init_session ;;
    find-tasks)        cmd_find_tasks ;;
    detect-schema)     cmd_detect_schema ;;
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
    cascade-skip)      cmd_cascade_skip "${2:-}" ;;
    get-branch)        cmd_get_branch ;;
    get-state)         cmd_get_state ;;
    clear-state)       cmd_clear_state ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
