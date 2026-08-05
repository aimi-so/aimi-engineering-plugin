#!/usr/bin/env bash
# test-aimi-cli-common.sh - shared preamble for the test-aimi-cli.sh part files.
#
# Sourced by every test-aimi-cli-part*.sh. Deliberately tiny: each part is a
# separate process, so every line in here is loaded four times per run and
# every command substitution in a part forks a shell whose cost scales with
# the size of what was loaded. Put fixtures in test-aimi-cli-fixtures.sh (or
# in the single part that needs them) rather than here.
#
# SCRIPT_DIR and CLI are set by the sourcing part, relative to that part's own
# location, before this file is sourced.

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
  "schemaVersion": "3.2",
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

# Helper: resolve the Claude config directory exactly as the CLI does.
# Honors CLAUDE_CONFIG_DIR, falls back to $HOME/.claude, strips trailing slash.
_test_claude_config_dir() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  printf '%s\n' "${dir%/}"
}

# ============================================================================
# General Tests
# ============================================================================
