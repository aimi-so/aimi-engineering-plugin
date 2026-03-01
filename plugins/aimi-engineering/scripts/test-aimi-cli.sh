#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli.sh - Test suite for aimi-cli.sh
#
# Creates a temporary v3 tasks file, exercises all CLI commands,
# validates outputs, and cleans up.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/aimi-cli.sh"
TEST_DIR="$(mktemp -d)"
AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

TASKS_FILE="$TASKS_DIR/9999-99-99-test-tasks.json"

# Setup test environment
setup() {
  echo "Setting up test environment..."
  mkdir -p "$TASKS_DIR"

  # Remove any existing test files
  rm -f "$TASKS_DIR/9999-99-99-test-tasks.json"
  rm -f "$TASKS_DIR/9999-99-98-test-v3-tasks.json"

  # Create v3 test tasks file
  cat > "$TASKS_FILE" << 'EOF'
{
  "schemaVersion": "3.0",
  "metadata": {
    "title": "feat: Test feature",
    "type": "feat",
    "branchName": "feat/test-feature",
    "createdAt": "2026-02-27",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 4
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Schema story (root)",
      "description": "Independent root story",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 1,
      "status": "pending",
      "dependsOn": [],
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Another root story",
      "description": "Independent root story 2",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 2,
      "status": "pending",
      "dependsOn": [],
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Backend depends on US-001",
      "description": "Depends on schema",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 3,
      "status": "pending",
      "dependsOn": ["US-001"],
      "notes": ""
    },
    {
      "id": "US-004",
      "title": "UI depends on US-002 and US-003",
      "description": "Diamond convergence",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 4,
      "status": "pending",
      "dependsOn": ["US-002", "US-003"],
      "notes": ""
    }
  ]
}
EOF

  # Clear any existing state files
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result"
}

# Cleanup test environment
cleanup() {
  echo "Cleaning up..."
  rm -f "$TASKS_FILE"
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result"
}

# Test helper
assert_eq() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  Expected: $expected"
    echo "  Actual: $actual"
    ((TESTS_FAILED++))
  fi
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  if [[ "$actual" == *"$expected"* ]]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  Expected to contain: $expected"
    echo "  Actual: $actual"
    ((TESTS_FAILED++))
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"

  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  Expected exit code: $expected"
    echo "  Actual exit code: $actual"
    ((TESTS_FAILED++))
  fi
}

assert_stderr_contains() {
  local expected="$1"
  local stderr_output="$2"
  local test_name="$3"

  if [[ "$stderr_output" == *"$expected"* ]]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  Expected stderr to contain: $expected"
    echo "  Actual stderr: $stderr_output"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# General Tests
# ============================================================================

test_help() {
  echo ""
  echo "=== Testing help command ==="

  local output
  output=$("$CLI" help)

  assert_contains "aimi-cli.sh" "$output" "help shows script name"
  assert_contains "init-session" "$output" "help shows init-session"
  assert_contains "mark-complete" "$output" "help shows mark-complete"
}

test_find_tasks() {
  echo ""
  echo "=== Testing find-tasks command ==="

  local output
  output=$("$CLI" find-tasks)

  assert_contains "9999-99-99-test-tasks.json" "$output" "find-tasks returns correct file"
}

test_metadata() {
  echo ""
  echo "=== Testing metadata command ==="

  local output
  output=$("$CLI" metadata)

  assert_contains '"title": "feat: Test feature"' "$output" "metadata returns title"
  assert_contains '"branchName": "feat/test-feature"' "$output" "metadata returns branch"
}

test_current_story() {
  echo ""
  echo "=== Testing current-story command ==="

  # First set a current story
  "$CLI" next-story > /dev/null

  local output
  output=$("$CLI" current-story)

  assert_contains '"id": "US-001"' "$output" "current-story returns correct story"
}

test_get_branch() {
  echo ""
  echo "=== Testing get-branch command ==="

  local output
  output=$("$CLI" get-branch)

  assert_eq "feat/test-feature" "$output" "get-branch returns correct branch"
}

test_get_state() {
  echo ""
  echo "=== Testing get-state command ==="

  local output
  output=$("$CLI" get-state)

  assert_contains '"branch": "feat/test-feature"' "$output" "get-state returns branch"
}

test_clear_state() {
  echo ""
  echo "=== Testing clear-state command ==="

  local output
  output=$("$CLI" clear-state)

  assert_contains "State cleared" "$output" "clear-state reports success"

  # Check state files removed (tasks dir preserved)
  [ ! -f "$AIMI_DIR/current-tasks" ] && assert_eq "1" "1" "current-tasks state file removed" || assert_eq "1" "0" "current-tasks state file removed"
  [ ! -f "$AIMI_DIR/current-branch" ] && assert_eq "1" "1" "current-branch state file removed" || assert_eq "1" "0" "current-branch state file removed"
}

test_error_handling() {
  echo ""
  echo "=== Testing error handling ==="

  # Test unknown command
  local exit_code
  "$CLI" unknown-command > /dev/null 2>&1 && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "unknown command returns exit code 1"

  # Test mark-complete without ID
  "$CLI" mark-complete > /dev/null 2>&1 && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "mark-complete without ID returns exit code 1"
}

# ============================================================================
# V3 Schema Tests
# ============================================================================

test_init_session() {
  echo ""
  echo "=== Testing init-session ==="

  local output
  output=$("$CLI" init-session)

  assert_contains '"pending": 4' "$output" "init-session counts pending by status"
  assert_contains '"schemaVersion": "3.0"' "$output" "init-session returns schema version"
  assert_contains "feat/test-feature" "$output" "init-session returns branch"

  # Check state files created
  [ -f "$AIMI_DIR/current-tasks" ] && assert_eq "1" "1" "current-tasks state file created" || assert_eq "1" "0" "current-tasks state file created"
  [ -f "$AIMI_DIR/current-branch" ] && assert_eq "1" "1" "current-branch state file created" || assert_eq "1" "0" "current-branch state file created"
}

test_count_pending() {
  echo ""
  echo "=== Testing count-pending ==="

  local output
  output=$("$CLI" count-pending)
  assert_eq "4" "$output" "count-pending counts stories with status pending"
}

test_list_ready() {
  echo ""
  echo "=== Testing list-ready ==="

  local output
  output=$("$CLI" list-ready)

  # US-001 and US-002 have no dependencies, should be ready
  assert_contains '"US-001"' "$output" "list-ready includes US-001 (no deps)"
  assert_contains '"US-002"' "$output" "list-ready includes US-002 (no deps)"

  # US-003 depends on US-001 (pending), should NOT be ready
  local us003_present
  us003_present=$(echo "$output" | jq '[.[] | select(.id == "US-003")] | length')
  assert_eq "0" "$us003_present" "list-ready excludes US-003 (dep US-001 pending)"

  # US-004 depends on US-002 and US-003, should NOT be ready
  local us004_present
  us004_present=$(echo "$output" | jq '[.[] | select(.id == "US-004")] | length')
  assert_eq "0" "$us004_present" "list-ready excludes US-004 (deps pending)"
}

test_next_story() {
  echo ""
  echo "=== Testing next-story ==="

  local output
  output=$("$CLI" next-story)

  # Should return US-001 (ready, lowest priority)
  assert_contains '"id": "US-001"' "$output" "next-story returns first ready by priority"
}

test_mark_in_progress() {
  echo ""
  echo "=== Testing mark-in-progress ==="

  local output
  output=$("$CLI" mark-in-progress US-001)

  assert_contains '"status": "in_progress"' "$output" "mark-in-progress sets status to in_progress"
}

test_mark_complete() {
  echo ""
  echo "=== Testing mark-complete ==="

  local output
  output=$("$CLI" mark-complete US-001)

  assert_contains '"status": "completed"' "$output" "mark-complete sets status to completed"

  # Check last-result state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "success" "$last" "last-result set to success"

  # Check current-story cleared
  local current
  current=$(cat "$AIMI_DIR/current-story" 2>/dev/null || echo "")
  assert_eq "" "$current" "current-story cleared"
}

test_list_ready_after_complete() {
  echo ""
  echo "=== Testing list-ready after completing US-001 ==="

  local output
  output=$("$CLI" list-ready)

  # US-002 still ready (no deps)
  assert_contains '"US-002"' "$output" "list-ready still includes US-002"

  # US-003 depends on US-001 which is now completed, should be ready
  local us003_present
  us003_present=$(echo "$output" | jq '[.[] | select(.id == "US-003")] | length')
  assert_eq "1" "$us003_present" "list-ready now includes US-003 (dep US-001 completed)"

  # US-004 depends on US-002 (pending) and US-003 (pending), still NOT ready
  local us004_present
  us004_present=$(echo "$output" | jq '[.[] | select(.id == "US-004")] | length')
  assert_eq "0" "$us004_present" "list-ready still excludes US-004 (US-002 pending)"
}

test_mark_failed() {
  echo ""
  echo "=== Testing mark-failed ==="

  local output
  output=$("$CLI" mark-failed US-002 "Build error in module X")

  assert_contains '"status": "failed"' "$output" "mark-failed sets status to failed"
  assert_contains '"notes": "Build error in module X"' "$output" "mark-failed sets notes"

  # Check state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "failed" "$last" "last-result state set to failed"
}

test_cascade_skip() {
  echo ""
  echo "=== Testing cascade-skip ==="

  local output
  output=$("$CLI" cascade-skip US-002)

  # US-004 depends on US-002 (failed), should be skipped
  assert_contains '"US-004"' "$output" "cascade-skip includes US-004 (depends on failed US-002)"

  # Verify US-004 is now skipped in the file
  local us004_status
  us004_status=$(jq -r '.userStories[] | select(.id == "US-004") | .status' "$TASKS_FILE")
  assert_eq "skipped" "$us004_status" "US-004 status is skipped in file"

  # US-003 does NOT depend on US-002, should not be skipped
  local us003_status
  us003_status=$(jq -r '.userStories[] | select(.id == "US-003") | .status' "$TASKS_FILE")
  assert_eq "pending" "$us003_status" "US-003 status still pending (no dep on US-002)"
}

test_mark_skipped() {
  echo ""
  echo "=== Testing mark-skipped ==="

  local output
  output=$("$CLI" mark-skipped US-003)

  assert_contains '"status": "skipped"' "$output" "mark-skipped sets status to skipped"

  # Check state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "skipped" "$last" "last-result state set to skipped"
}

test_validate_deps() {
  echo ""
  echo "=== Testing validate-deps ==="

  local output exit_code
  output=$("$CLI" validate-deps) && exit_code=0 || exit_code=$?

  assert_contains '"valid": true' "$output" "validate-deps passes for valid dependency graph"
  assert_exit_code "0" "$exit_code" "validate-deps exits 0 for valid graph"
}

test_validate_deps_circular() {
  echo ""
  echo "=== Testing validate-deps with circular dependency ==="

  # Create a file with circular deps
  local circular_file="$TASKS_DIR/9999-99-97-circular-tasks.json"
  cat > "$circular_file" << 'EOF'
{
  "schemaVersion": "3.0",
  "metadata": {
    "title": "feat: Circular test",
    "type": "feat",
    "branchName": "feat/circular",
    "createdAt": "2026-02-27",
    "planPath": null,
    "maxConcurrency": 4
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Story A",
      "description": "Depends on B",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 1,
      "status": "pending",
      "dependsOn": ["US-002"],
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Story B",
      "description": "Depends on A",
      "acceptanceCriteria": ["Typecheck passes"],
      "priority": 2,
      "status": "pending",
      "dependsOn": ["US-001"],
      "notes": ""
    }
  ]
}
EOF

  # Point CLI at circular file
  echo "$circular_file" > "$AIMI_DIR/current-tasks"

  local output exit_code
  output=$("$CLI" validate-deps) && exit_code=0 || exit_code=$?

  assert_contains '"valid": false' "$output" "validate-deps fails for circular dependency"
  assert_contains "Circular dependency" "$output" "validate-deps reports circular dependency"
  assert_exit_code "1" "$exit_code" "validate-deps exits 1 for invalid graph"

  rm -f "$circular_file"

  # Restore pointer to test file
  echo "$TASKS_FILE" > "$AIMI_DIR/current-tasks"
}

test_status() {
  echo ""
  echo "=== Testing status command ==="

  local output
  output=$("$CLI" status)

  assert_contains '"schemaVersion": "3.0"' "$output" "status shows schema version"
  assert_contains '"maxConcurrency": 4' "$output" "status shows maxConcurrency"
  assert_contains '"dependsOn"' "$output" "status includes dependsOn in stories"
}

test_count_pending_final() {
  echo ""
  echo "=== Testing count-pending (final state) ==="

  local output
  output=$("$CLI" count-pending)

  # US-001 completed, US-002 failed, US-003 skipped, US-004 skipped = 0 pending
  assert_eq "0" "$output" "count-pending returns 0 after all stories resolved"
}

# ============================================================================
# New Feature Tests (v1.13.0)
# ============================================================================

test_resolve_path() {
  echo ""
  echo "=== Testing resolve_path ==="

  # resolve_path is internal, test via init-session output (tasks path should be absolute)
  "$CLI" clear-state > /dev/null
  local output
  output=$("$CLI" init-session)

  local tasks_path
  tasks_path=$(echo "$output" | jq -r '.tasks')

  # Absolute paths start with /
  if [[ "$tasks_path" == /* ]]; then
    echo -e "${GREEN}✓${NC} init-session returns absolute tasks path"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} init-session returns absolute tasks path"
    echo "  Path: $tasks_path (expected absolute)"
    ((TESTS_FAILED++))
  fi
}

test_cli_path() {
  echo ""
  echo "=== Testing cli-path state file ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  local cli_path
  cli_path=$(cat "$AIMI_DIR/cli-path" 2>/dev/null)

  # cli-path should exist and be absolute
  if [ -n "$cli_path" ] && [[ "$cli_path" == /* ]]; then
    echo -e "${GREEN}✓${NC} cli-path contains absolute path"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} cli-path contains absolute path"
    echo "  Path: $cli_path"
    ((TESTS_FAILED++))
  fi

  # cli-path should point to an executable
  if [ -x "$cli_path" ]; then
    echo -e "${GREEN}✓${NC} cli-path points to executable file"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} cli-path points to executable file"
    ((TESTS_FAILED++))
  fi
}

test_status_uses_user_stories_key() {
  echo ""
  echo "=== Testing status output key name ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null
  local output
  output=$("$CLI" status)

  # Should contain userStories, not stories as top-level key
  assert_contains '"userStories"' "$output" "status output uses userStories key"

  # Verify the key works with jq
  local count
  count=$(echo "$output" | jq '.userStories | length')
  if [ "$count" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} userStories key is iterable (count: $count)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} userStories key is iterable"
    ((TESTS_FAILED++))
  fi
}

test_story_id_not_found() {
  echo ""
  echo "=== Testing story ID existence validation ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  # mark-complete with non-existent ID should fail
  local stderr_output exit_code
  stderr_output=$("$CLI" mark-complete US-999 2>&1) || exit_code=$?
  assert_exit_code "1" "${exit_code:-0}" "mark-complete US-999 returns exit code 1"
  assert_stderr_contains "not found" "$stderr_output" "mark-complete US-999 shows not found error"

  # mark-in-progress with non-existent ID should fail
  stderr_output=$("$CLI" mark-in-progress US-999 2>&1) || exit_code=$?
  assert_exit_code "1" "${exit_code:-0}" "mark-in-progress US-999 returns exit code 1"
  assert_stderr_contains "not found" "$stderr_output" "mark-in-progress US-999 shows not found error"
}

test_reset_orphaned_empty() {
  echo ""
  echo "=== Testing reset-orphaned with no orphans ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  local output
  output=$("$CLI" reset-orphaned)

  local count
  count=$(echo "$output" | jq '.count')
  assert_eq "0" "$count" "reset-orphaned returns count 0 when no orphans"

  local reset_len
  reset_len=$(echo "$output" | jq '.reset | length')
  assert_eq "0" "$reset_len" "reset-orphaned returns empty reset array"
}

test_reset_orphaned_with_orphans() {
  echo ""
  echo "=== Testing reset-orphaned with orphaned stories ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  # Mark two stories as in_progress
  "$CLI" mark-in-progress US-001 > /dev/null
  "$CLI" mark-in-progress US-002 > /dev/null

  local output
  output=$("$CLI" reset-orphaned)

  local count
  count=$(echo "$output" | jq '.count')
  assert_eq "2" "$count" "reset-orphaned resets 2 orphaned stories"

  # Verify both IDs are in the reset array
  assert_contains "US-001" "$output" "reset-orphaned includes US-001"
  assert_contains "US-002" "$output" "reset-orphaned includes US-002"

  # Verify the stories are now failed in the file
  local status_output us1_status
  status_output=$("$CLI" status)
  us1_status=$(echo "$status_output" | jq -r '.userStories[] | select(.id == "US-001") | .status')
  assert_eq "failed" "$us1_status" "US-001 status is failed after reset-orphaned"
}

test_stale_state_warning() {
  echo ""
  echo "=== Testing stale state fallback warning ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  # Point current-tasks at a non-existent file
  echo "/tmp/nonexistent-tasks.json" > "$AIMI_DIR/current-tasks"

  # Call status and capture stderr
  local stderr_output
  stderr_output=$("$CLI" status 2>&1 >/dev/null) || true

  assert_stderr_contains "no longer exists" "$stderr_output" "stale state produces warning on stderr"
}

# ============================================================================
# Version Staleness Tests
# ============================================================================

test_check_version() {
  echo ""
  echo "=== Testing check-version ==="

  "$CLI" clear-state > /dev/null

  # --- Test 1: Current version (stored cli-path matches glob-resolved latest) ---
  # Write cli-path to exactly match what the glob resolves, so check-version sees "current"
  local latest_glob_path
  latest_glob_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  local output exit_code

  if [ -n "$latest_glob_path" ]; then
    # Force cli-path to the glob-resolved latest so stored == latest
    "$CLI" init-session > /dev/null
    echo "$latest_glob_path" > "$AIMI_DIR/cli-path"

    output=$("$CLI" check-version 2>/dev/null) && exit_code=0 || exit_code=$?

    assert_contains '"status":"current"' "$output" "check-version: current version returns status current"
    assert_exit_code "0" "$exit_code" "check-version: current version exits 0"
  else
    # No installed version found — check-version returns "unknown", skip "current" test
    echo "  (skipping current-version test: no installed version in cache)"
  fi

  # --- Test 2: Missing cli-path (no .aimi/cli-path file) ---
  "$CLI" clear-state > /dev/null

  # Do NOT call init-session, so cli-path state file is absent
  output=$("$CLI" check-version 2>/dev/null) && exit_code=0 || exit_code=$?

  assert_contains '"status": "missing"' "$output" "check-version: missing cli-path returns status missing"
  assert_exit_code "0" "$exit_code" "check-version: missing cli-path exits 0"
}

test_check_version_quiet() {
  echo ""
  echo "=== Testing check-version --quiet flag ==="

  "$CLI" clear-state > /dev/null

  # With --quiet, stderr should be empty even for the "missing" case
  # (no cli-path state file => "missing" status, which normally emits a warning)
  local stderr_output stdout_output exit_code
  stderr_output=$(mktemp)
  stdout_output=$("$CLI" check-version --quiet 2>"$stderr_output") && exit_code=0 || exit_code=$?
  local stderr_content
  stderr_content=$(cat "$stderr_output")
  rm -f "$stderr_output"

  assert_eq "" "$stderr_content" "check-version --quiet: stderr is empty for missing cli-path"
  assert_contains '"status": "missing"' "$stdout_output" "check-version --quiet: still returns missing status on stdout"
  assert_exit_code "0" "$exit_code" "check-version --quiet: exits 0 for missing"
}

test_check_version_fix() {
  echo ""
  echo "=== Testing check-version --fix flag ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  local latest_glob_path
  latest_glob_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  if [ -z "$latest_glob_path" ]; then
    echo "  (skipping --fix test: no installed version in cache)"
    return
  fi

  # Write a fake stale cli-path pointing to a non-existent old version
  echo "/fake/old/1.0.0/scripts/aimi-cli.sh" > "$AIMI_DIR/cli-path"

  # Confirm cli-path is stale before fix
  local pre_check
  pre_check=$(cat "$AIMI_DIR/cli-path" 2>/dev/null)
  assert_eq "/fake/old/1.0.0/scripts/aimi-cli.sh" "$pre_check" "check-version --fix: cli-path is stale before fix"

  local output exit_code
  output=$("$CLI" check-version --fix 2>/dev/null) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "check-version --fix: exits 0 after fix"
  assert_contains '"status": "fixed"' "$output" "check-version --fix: returns fixed status"

  # Verify cli-path was updated to the latest
  local updated_path
  updated_path=$(cat "$AIMI_DIR/cli-path" 2>/dev/null)
  assert_eq "$latest_glob_path" "$updated_path" "check-version --fix: cli-path updated to latest"
}

test_check_version_quiet_fix() {
  echo ""
  echo "=== Testing check-version --quiet --fix combined ==="

  "$CLI" clear-state > /dev/null
  "$CLI" init-session > /dev/null

  local latest_glob_path
  latest_glob_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  if [ -z "$latest_glob_path" ]; then
    echo "  (skipping --quiet --fix test: no installed version in cache)"
    return
  fi

  # Write a fake stale cli-path again
  echo "/fake/old/1.0.0/scripts/aimi-cli.sh" > "$AIMI_DIR/cli-path"

  local stderr_output_file stdout_output exit_code
  stderr_output_file=$(mktemp)
  stdout_output=$("$CLI" check-version --quiet --fix 2>"$stderr_output_file") && exit_code=0 || exit_code=$?
  local stderr_content
  stderr_content=$(cat "$stderr_output_file")
  rm -f "$stderr_output_file"

  assert_eq "" "$stderr_content" "check-version --quiet --fix: stderr is empty"
  assert_exit_code "0" "$exit_code" "check-version --quiet --fix: exits 0"
  assert_contains '"status": "fixed"' "$stdout_output" "check-version --quiet --fix: returns fixed status"

  # Verify cli-path was updated
  local updated_path
  updated_path=$(cat "$AIMI_DIR/cli-path" 2>/dev/null)
  assert_eq "$latest_glob_path" "$updated_path" "check-version --quiet --fix: cli-path updated to latest"
}

test_check_version_backward_compat() {
  echo ""
  echo "=== Testing check-version backward compatibility (no flags) ==="

  "$CLI" clear-state > /dev/null

  # Test 1: No flags, missing cli-path => "missing" status with stderr warning
  local stderr_output_file stdout_output exit_code
  stderr_output_file=$(mktemp)
  stdout_output=$("$CLI" check-version 2>"$stderr_output_file") && exit_code=0 || exit_code=$?
  local stderr_content
  stderr_content=$(cat "$stderr_output_file")
  rm -f "$stderr_output_file"

  assert_contains '"status": "missing"' "$stdout_output" "check-version (no flags): returns missing status"
  assert_exit_code "0" "$exit_code" "check-version (no flags): exits 0 for missing"
  # Without --quiet, stderr should contain a warning
  assert_contains "No stored cli-path" "$stderr_content" "check-version (no flags): stderr contains warning"

  # Test 2: No flags, current version => "current" status
  local latest_glob_path
  latest_glob_path=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

  if [ -n "$latest_glob_path" ]; then
    "$CLI" init-session > /dev/null
    echo "$latest_glob_path" > "$AIMI_DIR/cli-path"

    stdout_output=$("$CLI" check-version 2>/dev/null) && exit_code=0 || exit_code=$?
    assert_contains '"status":"current"' "$stdout_output" "check-version (no flags): current version returns status current"
    assert_exit_code "0" "$exit_code" "check-version (no flags): current version exits 0"
  fi

  # Test 3: No flags, stale version => "stale" status with exit code 1
  if [ -n "$latest_glob_path" ]; then
    echo "/fake/old/1.0.0/scripts/aimi-cli.sh" > "$AIMI_DIR/cli-path"

    stderr_output_file=$(mktemp)
    stdout_output=$("$CLI" check-version 2>"$stderr_output_file") && exit_code=0 || exit_code=$?
    stderr_content=$(cat "$stderr_output_file")
    rm -f "$stderr_output_file"

    assert_contains '"status": "stale"' "$stdout_output" "check-version (no flags): stale returns stale status"
    assert_exit_code "1" "$exit_code" "check-version (no flags): stale exits 1"
    assert_contains "CLI version is stale" "$stderr_content" "check-version (no flags): stale emits warning"
  fi
}

test_cleanup_versions() {
  echo ""
  echo "=== Testing cleanup-versions ==="

  "$CLI" clear-state > /dev/null

  # First run may or may not remove old versions depending on environment.
  # Run once to reach a clean state, then run again to verify the
  # idempotent "no old versions" path returns removed:0.
  "$CLI" cleanup-versions > /dev/null 2>&1

  # Second run: only the latest version remains, so removed must be 0
  local output
  output=$("$CLI" cleanup-versions 2>/dev/null)

  local removed
  removed=$(echo "$output" | jq '.removed')
  assert_eq "0" "$removed" "cleanup-versions: no old versions returns removed:0"

  # Validate JSON output format has both keys
  assert_contains '"removed"' "$output" "cleanup-versions: output contains removed key"
  assert_contains '"kept"' "$output" "cleanup-versions: output contains kept key"
}

# ============================================================================
# Main
# ============================================================================

main() {
  echo "================================================"
  echo "  Aimi CLI Test Suite"
  echo "================================================"

  setup

  # General tests
  echo ""
  echo "--- General Tests ---"
  test_help
  test_find_tasks
  test_init_session
  test_metadata
  test_current_story
  test_get_branch
  test_get_state
  test_clear_state
  test_error_handling

  # Re-init session after clear-state
  "$CLI" init-session > /dev/null

  # Lifecycle tests (order matters — they modify state progressively)
  echo ""
  echo "--- Lifecycle Tests ---"
  test_count_pending
  test_list_ready
  test_next_story
  test_mark_in_progress
  test_mark_complete
  test_list_ready_after_complete
  test_mark_failed
  test_cascade_skip
  test_mark_skipped
  test_validate_deps_circular
  test_validate_deps
  test_status
  test_count_pending_final

  # New feature tests (v1.13.0) — run with fresh state
  echo ""
  echo "--- New Feature Tests (v1.13.0) ---"
  test_resolve_path
  test_cli_path
  test_status_uses_user_stories_key
  test_story_id_not_found
  test_reset_orphaned_empty
  test_reset_orphaned_with_orphans
  test_stale_state_warning

  # Version staleness tests — run with fresh state
  echo ""
  echo "--- Version Staleness Tests ---"
  test_check_version
  test_check_version_quiet
  test_check_version_fix
  test_check_version_quiet_fix
  test_check_version_backward_compat
  test_cleanup_versions

  cleanup

  echo ""
  echo "================================================"
  echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
