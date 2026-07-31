#!/usr/bin/env bash
set -uo pipefail

# test-resolve-pr-parallel.sh - Test suite for the resolve-pr-parallel skill
# scripts (get-pr-comments, resolve-pr-thread).
#
# This is the first test coverage either script has ever had -- they live
# under skills/, which test-command-blocks.sh does not scan at all (its
# scope is commands/*.md), leaving them with no other static-analysis
# safety net.
#
# Exercises both scripts against a hermetic stubbed `aimi-cli.sh` on disk
# under a disposable temp dir -- never the real CLI, never gh, never
# network access. Both scripts call $AIMI_CLI, not gh, after their forge-
# verb migration, so stubbing gh here would test nothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GET_PR_COMMENTS="$SCRIPT_DIR/../skills/resolve-pr-parallel/scripts/get-pr-comments"
RESOLVE_PR_THREAD="$SCRIPT_DIR/../skills/resolve-pr-parallel/scripts/resolve-pr-thread"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers (verbatim from test-worktree-manager.sh)
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
# Fixture Helpers
# ============================================================================

# Writes a fake $AIMI_PLUGIN_DIR/scripts/aimi-cli.sh under a disposable temp
# dir. It dispatches on the first argument (forge-repo-info,
# forge-pr-review-threads, forge-resolve-review-thread) and echoes
# pre-seeded JSON from env vars set by each test, plus an exit code from a
# matching *_EXIT env var -- mirroring the real verbs' own always-JSON,
# variable-exit-code contract without touching gh or the network.
setup_stub_cli() {
  FAKE_PLUGIN_DIR=$(mktemp -d)
  mkdir -p "$FAKE_PLUGIN_DIR/scripts"
  cat > "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" << 'STUBCLI'
#!/usr/bin/env bash
set -e
STUB_DEFAULT='{"status":"error","data":null,"message":"stub not configured"}'
case "$1" in
  forge-repo-info)
    printf '%s\n' "${STUB_REPO_INFO:-$STUB_DEFAULT}"
    exit "${STUB_REPO_INFO_EXIT:-0}"
    ;;
  forge-pr-review-threads)
    printf '%s\n' "${STUB_THREADS_RESULT:-$STUB_DEFAULT}"
    exit "${STUB_THREADS_EXIT:-0}"
    ;;
  forge-resolve-review-thread)
    printf '%s\n' "${STUB_RESOLVE_RESULT:-$STUB_DEFAULT}"
    exit "${STUB_RESOLVE_EXIT:-0}"
    ;;
  *)
    echo "aimi-cli-stub: unhandled subcommand: $1" >&2
    exit 1
    ;;
esac
STUBCLI
  chmod +x "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh"
}

# Idempotent: safe to call even when no fixture is active (e.g. from the
# main() EXIT trap as a backstop).
teardown_stub_cli() {
  if [ -n "${FAKE_PLUGIN_DIR:-}" ]; then
    rm -rf "$FAKE_PLUGIN_DIR"
    unset FAKE_PLUGIN_DIR
  fi
}

# Runs get-pr-comments / resolve-pr-thread in a subshell with CLAUDECODE
# unset and AIMI_PLUGIN_DIR pointed at the stub, so _resolve-cli.sh's Layer
# 0 resolves to the stub instead of falling through to any real cache or
# glob on this machine. Captures stdout, stderr, and exit code separately
# into RUN_STDOUT/RUN_STDERR/RUN_RC.
run_script() {
  local script="$1"
  shift
  local out_file err_file rc
  out_file=$(mktemp)
  err_file=$(mktemp)
  (
    unset CLAUDECODE
    export AIMI_PLUGIN_DIR="$FAKE_PLUGIN_DIR"
    bash "$script" "$@"
  ) >"$out_file" 2>"$err_file"
  rc=$?
  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
  RUN_RC=$rc
  rm -f "$out_file" "$err_file"
}

run_get_pr_comments() {
  run_script "$GET_PR_COMMENTS" "$@"
}

run_resolve_pr_thread() {
  run_script "$RESOLVE_PR_THREAD" "$@"
}

# ============================================================================
# get-pr-comments Tests
# ============================================================================

test_get_pr_comments_repo_detect_failure() {
  export STUB_REPO_INFO='{"status":"not_found","data":null,"message":null}'
  run_get_pr_comments 123
  assert_exit_code 1 "$RUN_RC" "get-pr-comments: exits 1 when repository cannot be detected"
  assert_eq "Error: Could not detect repository. Pass OWNER/REPO as second argument." "$RUN_STDOUT" \
    "get-pr-comments: prints byte-for-byte repo-detection error message"
  unset STUB_REPO_INFO
}

test_get_pr_comments_success_with_threads() {
  export STUB_REPO_INFO='{"status":"found","data":{"forge":"github","host":"github.com","owner":"acme","repo":"widgets","nameWithOwner":"acme/widgets","source":"gh"},"message":null}'
  export STUB_THREADS_RESULT='{"status":"found","data":{"pr":{"number":123,"title":"t","url":"u"},"threads":[{"id":"PRRT_1","isResolved":false}],"unsupported_fields":[]},"message":null}'
  run_get_pr_comments 123
  assert_exit_code 0 "$RUN_RC" "get-pr-comments: exits 0 on a successful threads lookup"
  assert_eq '[{"id":"PRRT_1","isResolved":false}]' "$RUN_STDOUT" \
    "get-pr-comments: prints the unwrapped threads array on stdout"
  unset STUB_REPO_INFO STUB_THREADS_RESULT
}

test_get_pr_comments_success_empty_threads() {
  export STUB_REPO_INFO='{"status":"found","data":{"owner":"acme","repo":"widgets"},"message":null}'
  export STUB_THREADS_RESULT='{"status":"found","data":{"pr":{"number":123},"threads":[],"unsupported_fields":[]},"message":null}'
  run_get_pr_comments 123
  assert_exit_code 0 "$RUN_RC" "get-pr-comments: exits 0 on a confirmed zero-threads outcome"
  assert_eq '[]' "$RUN_STDOUT" "get-pr-comments: prints an empty array (not an error) when there are no threads"
  unset STUB_REPO_INFO STUB_THREADS_RESULT
}

test_get_pr_comments_verb_failure() {
  export STUB_REPO_INFO='{"status":"found","data":{"owner":"acme","repo":"widgets"},"message":null}'
  export STUB_THREADS_RESULT='{"status":"error","data":null,"message":"gh api graphql exited 4: authentication required"}'
  run_get_pr_comments 123
  assert_exit_code 1 "$RUN_RC" "get-pr-comments: exits 1 when the verb reports a genuine failure"
  assert_eq "Error: gh api graphql exited 4: authentication required" "$RUN_STDERR" \
    "get-pr-comments: prints the verb's failure message to stderr"
  unset STUB_REPO_INFO STUB_THREADS_RESULT
}

test_get_pr_comments_explicit_owner_repo_skips_detection() {
  # OWNER/REPO passed explicitly as $2 -- forge-repo-info must not even be
  # consulted, so a deliberately broken STUB_REPO_INFO here proves it.
  export STUB_REPO_INFO='{"status":"error","data":null,"message":"should never be read"}'
  export STUB_THREADS_RESULT='{"status":"found","data":{"pr":{"number":9},"threads":[],"unsupported_fields":[]},"message":null}'
  run_get_pr_comments 9 acme/widgets
  assert_exit_code 0 "$RUN_RC" "get-pr-comments: an explicit OWNER/REPO argument bypasses repo detection"
  assert_eq '[]' "$RUN_STDOUT" "get-pr-comments: still returns the threads array with an explicit OWNER/REPO"
  unset STUB_REPO_INFO STUB_THREADS_RESULT
}

# ============================================================================
# resolve-pr-thread Tests
# ============================================================================

test_resolve_pr_thread_success() {
  export STUB_RESOLVE_RESULT='{"status":"found","data":{"resolved":true,"thread":{"id":"PRRT_1","isResolved":true,"path":"a.rb","line":10},"unsupported_fields":[]},"message":null}'
  export STUB_RESOLVE_EXIT=0
  run_resolve_pr_thread PRRT_1
  assert_exit_code 0 "$RUN_RC" "resolve-pr-thread: exits 0 on a genuine success"
  assert_eq "$STUB_RESOLVE_RESULT" "$RUN_STDOUT" "resolve-pr-thread: prints the resolved result on stdout"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

test_resolve_pr_thread_genuine_failure() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"gh api graphql exited 4: authentication required"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 1 "$RUN_RC" "resolve-pr-thread: exits 1 on a genuine tool failure"
  assert_eq "Error: gh api graphql exited 4: authentication required" "$RUN_STDERR" \
    "resolve-pr-thread: prints Error to stderr on a genuine tool failure"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

test_resolve_pr_thread_unsupported_forge() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"forge-resolve-review-thread: no adapter for forge \"gitea\" yet -- GitHub is the only adapter in phase 1."}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 0 "$RUN_RC" \
    "resolve-pr-thread: exits 0 (non-fatal) when the active forge has no resolution adapter"
  assert_contains "Not resolved" "$RUN_STDERR" \
    "resolve-pr-thread: prints a distinct non-fatal message for the capability gap"
  assert_contains "PRRT_1" "$RUN_STDERR" "resolve-pr-thread: identifies the thread id in the non-fatal message"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

# ============================================================================
# Regression: no leftover hand-written GraphQL text in either script
# ============================================================================

test_no_graphql_text_in_scripts() {
  local hits
  hits=$(grep -l "query FetchUnresolvedComments" "$GET_PR_COMMENTS" "$RESOLVE_PR_THREAD" 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$hits" "neither script embeds the old reviewThreads query text"

  hits=$(grep -l "mutation ResolveReviewThread" "$GET_PR_COMMENTS" "$RESOLVE_PR_THREAD" 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$hits" "neither script embeds the old resolveReviewThread mutation text"
}

# ============================================================================
# Main
# ============================================================================

main() {
  echo "================================================"
  echo "  resolve-pr-parallel Script Test Suite"
  echo "================================================"

  setup_stub_cli
  trap 'teardown_stub_cli' EXIT

  echo ""
  echo "--- get-pr-comments Tests ---"
  test_get_pr_comments_repo_detect_failure
  test_get_pr_comments_success_with_threads
  test_get_pr_comments_success_empty_threads
  test_get_pr_comments_verb_failure
  test_get_pr_comments_explicit_owner_repo_skips_detection

  echo ""
  echo "--- resolve-pr-thread Tests ---"
  test_resolve_pr_thread_success
  test_resolve_pr_thread_genuine_failure
  test_resolve_pr_thread_unsupported_forge

  echo ""
  echo "--- Regression Tests ---"
  test_no_graphql_text_in_scripts

  echo ""
  echo "================================================"
  echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
