#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli.sh - Test suite for aimi-cli.sh
#
# Creates a temporary tasks file, exercises all CLI commands,
# validates outputs, and cleans up.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/aimi-cli.sh"
TEST_DIR="$(mktemp -d)"
TASKS_DIR="docs/tasks"
AIMI_DIR=".aimi"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Setup test environment
setup() {
  echo "Setting up test environment..."
  mkdir -p "$TASKS_DIR"

  # Remove any existing test file first
  rm -f "$TASKS_DIR/9999-99-99-test-tasks.json"

  # Create test tasks file with future date to ensure it's found first
  cat > "$TASKS_DIR/9999-99-99-test-tasks.json" << 'EOF'
{
  "schemaVersion": "2.1",
  "metadata": {
    "title": "feat: Test feature",
    "type": "feat",
    "branchName": "feat/test-feature",
    "createdAt": "2026-02-24",
    "planPath": "docs/plans/test-plan.md"
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "First story",
      "description": "Test story 1",
      "acceptanceCriteria": ["Criterion 1"],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Second story",
      "description": "Test story 2",
      "acceptanceCriteria": ["Criterion 2"],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Third story",
      "description": "Test story 3",
      "acceptanceCriteria": ["Criterion 3"],
      "priority": 3,
      "passes": false,
      "notes": ""
    }
  ]
}
EOF

  # Clear any existing state
  rm -rf "$AIMI_DIR"
}

# Cleanup test environment
cleanup() {
  echo "Cleaning up..."
  rm -rf "$AIMI_DIR"
  rm -f "$TASKS_DIR/9999-99-99-test-tasks.json"
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

# ============================================================================
# Tests
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

test_init_session() {
  echo ""
  echo "=== Testing init-session command ==="

  local output
  output=$("$CLI" init-session)

  assert_contains "feat/test-feature" "$output" "init-session returns branch name"
  assert_contains '"pending": 3' "$output" "init-session returns pending count"

  # Check state files created
  [ -f "$AIMI_DIR/current-tasks" ] && assert_eq "1" "1" "current-tasks state file created" || assert_eq "1" "0" "current-tasks state file created"
  [ -f "$AIMI_DIR/current-branch" ] && assert_eq "1" "1" "current-branch state file created" || assert_eq "1" "0" "current-branch state file created"
}

test_status() {
  echo ""
  echo "=== Testing status command ==="

  local output
  output=$("$CLI" status)

  assert_contains '"title": "feat: Test feature"' "$output" "status returns title"
  assert_contains '"pending": 3' "$output" "status returns pending count"
  assert_contains '"completed": 0' "$output" "status returns completed count"
  assert_contains '"total": 3' "$output" "status returns total count"
}

test_metadata() {
  echo ""
  echo "=== Testing metadata command ==="

  local output
  output=$("$CLI" metadata)

  assert_contains '"title": "feat: Test feature"' "$output" "metadata returns title"
  assert_contains '"branchName": "feat/test-feature"' "$output" "metadata returns branch"
}

test_next_story() {
  echo ""
  echo "=== Testing next-story command ==="

  local output
  output=$("$CLI" next-story)

  assert_contains '"id": "US-001"' "$output" "next-story returns first story by priority"
  assert_contains '"title": "First story"' "$output" "next-story returns story title"

  # Check state file
  local current
  current=$(cat "$AIMI_DIR/current-story" 2>/dev/null || echo "")
  assert_eq "US-001" "$current" "current-story state set"
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

test_mark_complete() {
  echo ""
  echo "=== Testing mark-complete command ==="

  # First set a current story
  "$CLI" next-story > /dev/null

  local output
  output=$("$CLI" mark-complete US-001)

  assert_contains '"passes": true' "$output" "mark-complete sets passes to true"

  # Check state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "success" "$last" "last-result state set to success"

  # Check current-story cleared
  local current
  current=$(cat "$AIMI_DIR/current-story" 2>/dev/null || echo "")
  assert_eq "" "$current" "current-story cleared"
}

test_mark_failed() {
  echo ""
  echo "=== Testing mark-failed command ==="

  # Get next story (should be US-002 now)
  "$CLI" next-story > /dev/null

  local output
  output=$("$CLI" mark-failed US-002 "Test failure notes")

  assert_contains '"notes": "Test failure notes"' "$output" "mark-failed sets notes"

  # Check state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "failed" "$last" "last-result state set to failed"
}

test_mark_skipped() {
  echo ""
  echo "=== Testing mark-skipped command ==="

  local output
  output=$("$CLI" mark-skipped US-002)

  assert_contains '"skipped": true' "$output" "mark-skipped sets skipped to true"

  # Check state
  local last
  last=$(cat "$AIMI_DIR/last-result" 2>/dev/null || echo "")
  assert_eq "skipped" "$last" "last-result state set to skipped"
}

test_count_pending() {
  echo ""
  echo "=== Testing count-pending command ==="

  local output
  output=$("$CLI" count-pending)

  # US-001 is complete, US-002 is skipped, US-003 is pending
  assert_eq "1" "$output" "count-pending returns correct count"
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
  assert_contains '"last": "skipped"' "$output" "get-state returns last result"
}

test_clear_state() {
  echo ""
  echo "=== Testing clear-state command ==="

  local output
  output=$("$CLI" clear-state)

  assert_contains "State cleared" "$output" "clear-state reports success"

  # Check state directory removed
  [ ! -d "$AIMI_DIR" ] && assert_eq "1" "1" ".aimi directory removed" || assert_eq "1" "0" ".aimi directory removed"
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
# Main
# ============================================================================

main() {
  echo "================================================"
  echo "  Aimi CLI Test Suite"
  echo "================================================"

  setup

  # Run tests in order (some depend on previous state)
  test_help
  test_find_tasks
  test_init_session
  test_status
  test_metadata
  test_next_story
  test_current_story
  test_mark_complete
  test_mark_failed
  test_mark_skipped
  test_count_pending
  test_get_branch
  test_get_state
  test_clear_state
  test_error_handling

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
