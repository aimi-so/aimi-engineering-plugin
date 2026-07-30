#!/usr/bin/env bash
set -uo pipefail

# test-worktree-manager.sh - Test suite for worktree-manager.sh
#
# Exercises create/remove/serve/install-deps against isolated, disposable git
# fixtures under a temp dir. Never touches the repo's own .aimi/ state and
# never depends on a real package manager, node, or network access — the
# three serve tests launch python3's stdlib http.server through a hermetic
# stubbed `npm` on PATH instead of a real dev server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WTM="$SCRIPT_DIR/../skills/git-worktree/scripts/worktree-manager.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helpers (verbatim from test-aimi-cli.sh)
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
# Fixture Helpers
# ============================================================================

# Creates an isolated local git repo (no remote — worktree-manager.sh never
# pushes or fetches) with one commit on main and a .aimi/tasks/ dir so
# find_aimi_root succeeds, then pushd's into it. Sets WTM_FIXTURE_REPO.
# worktree-manager.sh recomputes GIT_ROOT fresh on every invocation via
# `git rev-parse --show-toplevel`, so every $WTM call in a test must run
# with CWD already inside this fixture.
setup_wtm_fixture() {
  WTM_FIXTURE_REPO=$(mktemp -d)
  pushd "$WTM_FIXTURE_REPO" >/dev/null
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git checkout -q -b main
  echo "init" > README.md
  git add README.md
  git commit -q -m "Initial commit"
  mkdir -p .aimi/tasks
}

# Idempotent: safe to call even when no fixture is active (e.g. from the
# main() EXIT trap as a backstop).
teardown_wtm_fixture() {
  if [[ -n "${WTM_FIXTURE_REPO:-}" ]]; then
    popd >/dev/null 2>&1 || true
    rm -rf "$WTM_FIXTURE_REPO"
    unset WTM_FIXTURE_REPO
  fi
}

# A hermetic `npm` stub for the serve tests only: implements exactly
# `npm run <script>` by reading .scripts[<script>] out of ./package.json via
# jq and exec'ing it through bash -c — no real npm, no node, no network.
# Prepends its own bin dir to PATH so worktree-manager.sh's `pm_cmd=(npm run
# dev)` branch resolves to this instead of a real package manager.
setup_npm_stub() {
  WTM_NPM_STUB_DIR=$(mktemp -d)
  cat > "$WTM_NPM_STUB_DIR/npm" << 'NPMSTUB'
#!/bin/bash
if [[ "$1" == "run" ]] && [[ -n "${2:-}" ]]; then
  script_cmd=$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)
  if [[ -z "$script_cmd" ]]; then
    echo "npm-stub: no script named '$2' in package.json" >&2
    exit 1
  fi
  exec bash -c "$script_cmd"
fi
echo "npm-stub: unsupported invocation: $*" >&2
exit 1
NPMSTUB
  chmod +x "$WTM_NPM_STUB_DIR/npm"
  WTM_OLD_PATH="$PATH"
  export PATH="$WTM_NPM_STUB_DIR:$PATH"
}

teardown_npm_stub() {
  if [[ -n "${WTM_NPM_STUB_DIR:-}" ]]; then
    export PATH="$WTM_OLD_PATH"
    rm -rf "$WTM_NPM_STUB_DIR"
    unset WTM_NPM_STUB_DIR WTM_OLD_PATH
  fi
}

# ============================================================================
# Create / Remove Tests
# ============================================================================

# The single highest-value assertion in this suite (finding B3): proves
# create_worktree's "branch exists and is free" case (the reuse check +
# `git worktree add`, not `-b`) succeeds instead of aborting on git's fatal
# "A branch named X already exists".
test_create_remove_recreate_with_keep_branch() {
  echo ""
  echo "=== Testing create -> remove --keep-branch -> create round trip ==="

  setup_wtm_fixture

  local branch="round-trip-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1
  local first_create_rc=$?
  assert_exit_code "0" "$first_create_rc" "create/remove/create: first create — exit code"

  bash "$WTM" remove "$branch" --keep-branch >/dev/null 2>&1

  assert_eq "false" "$([[ -d "$worktree_path" ]] && echo true || echo false)" \
    "create/remove/create: remove --keep-branch — worktree dir gone"

  local branch_count_after_remove
  branch_count_after_remove=$(git branch --list "$branch" | wc -l | tr -d ' ')
  assert_eq "1" "$branch_count_after_remove" \
    "create/remove/create: remove --keep-branch — branch preserved"

  local second_create_rc
  bash "$WTM" create "$branch" >/dev/null 2>&1
  second_create_rc=$?
  assert_exit_code "0" "$second_create_rc" \
    "create/remove/create: second create (same name) — exit code, does not abort on 'branch already exists'"

  assert_eq "true" "$([[ -d "$worktree_path" ]] && echo true || echo false)" \
    "create/remove/create: second create — worktree dir exists"

  local head_branch
  head_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
  assert_eq "$branch" "$head_branch" \
    "create/remove/create: second create — HEAD resolves to the branch"

  local branch_count
  branch_count=$(git branch --list "$branch" | wc -l | tr -d ' ')
  assert_eq "1" "$branch_count" \
    "create/remove/create: second create — exactly one branch of that name"

  teardown_wtm_fixture
}

# Proves the no-flag default is unchanged by the --keep-branch feature.
test_create_remove_default_removes_branch() {
  echo ""
  echo "=== Testing create -> remove (no flag) removes worktree and branch ==="

  setup_wtm_fixture

  local branch="default-remove-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1
  bash "$WTM" remove "$branch" >/dev/null 2>&1
  local remove_rc=$?
  assert_exit_code "0" "$remove_rc" "create/remove (default): remove — exit code"

  assert_eq "false" "$([[ -d "$worktree_path" ]] && echo true || echo false)" \
    "create/remove (default): worktree dir gone"

  local branch_count
  branch_count=$(git branch --list "$branch" | wc -l | tr -d ' ')
  assert_eq "0" "$branch_count" "create/remove (default): branch also gone"

  teardown_wtm_fixture
}

# ============================================================================
# Serve Status Tests
# ============================================================================
#
# All three assert the exact key set (running, port, pid) and nothing added
# or renamed, per worktree-manager.sh's own comment calling this shape a
# contract. test_serve_status_running deliberately leaves its server running
# and stashes fixture state in _SERVE_FIXTURE_* globals so
# test_serve_status_stale_after_external_kill can reuse it directly, instead
# of paying for a second worktree + server just to kill it.

test_serve_status_never_started() {
  echo ""
  echo "=== Testing serve status — never started ==="

  setup_wtm_fixture

  local branch="never-started-branch"
  bash "$WTM" create "$branch" >/dev/null 2>&1

  local status_out status_rc
  status_out=$(bash "$WTM" serve status "$branch" 2>/dev/null)
  status_rc=$?

  # NOTE: as of this writing, serve status crashes here instead of returning
  # this contract — `set -e` plus jq's non-zero exit on a missing
  # dev-server.json (the file only comes into existence once serve start has
  # run once, which is exactly the case this test exercises) aborts the
  # whole script before it reaches its own jq -n fallback. This assertion
  # intentionally targets the documented contract in worktree-manager.sh's
  # serve_status comment, not today's behavior — see this story's report.
  assert_eq '{"running":false,"port":null,"pid":null}' "$status_out" \
    "serve status: never started — JSON shape"
  assert_exit_code "0" "$status_rc" "serve status: never started — exit code"

  teardown_wtm_fixture
}

test_serve_status_running() {
  echo ""
  echo "=== Testing serve status — running ==="

  setup_wtm_fixture
  setup_npm_stub

  _SERVE_FIXTURE_BRANCH="serve-running-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$_SERVE_FIXTURE_BRANCH"

  bash "$WTM" create "$_SERVE_FIXTURE_BRANCH" >/dev/null 2>&1

  # dev script binds loopback-only and answers HTTP almost instantly — no
  # real framework, no node, no network.
  cat > "$worktree_path/package.json" << 'EOF'
{
  "name": "wtm-serve-fixture",
  "scripts": {
    "dev": "exec python3 -m http.server \"$PORT\" --bind 127.0.0.1"
  }
}
EOF

  # http.server binds in well under a second; a short bound keeps a failure
  # fast instead of waiting out the real 90s default.
  export DEV_SERVER_READY_TIMEOUT=10

  local start_out start_rc
  start_out=$(bash "$WTM" serve start "$_SERVE_FIXTURE_BRANCH" 2>/dev/null)
  start_rc=$?
  assert_exit_code "0" "$start_rc" "serve status: running — serve start exit code"
  assert_contains "http://127.0.0.1:" "$start_out" \
    "serve status: running — serve start prints the raw URL on stdout"

  local status_out status_rc running port pid
  status_out=$(bash "$WTM" serve status "$_SERVE_FIXTURE_BRANCH" 2>/dev/null)
  status_rc=$?
  running=$(printf '%s' "$status_out" | jq -r '.running')
  port=$(printf '%s' "$status_out" | jq -r '.port')
  pid=$(printf '%s' "$status_out" | jq -r '.pid')

  assert_exit_code "0" "$status_rc" "serve status: running — exit code"
  assert_eq "true" "$running" "serve status: running — .running is true"
  assert_eq "${start_out##*:}" "$port" \
    "serve status: running — .port matches the port serve start reported"

  local pid_is_positive_int="false"
  [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && pid_is_positive_int="true"
  assert_eq "true" "$pid_is_positive_int" "serve status: running — .pid is a positive integer"

  # Stash fixture state for test_serve_status_stale_after_external_kill,
  # which reuses this exact running fixture. Not torn down here.
  _SERVE_FIXTURE_PID="$pid"
  _SERVE_FIXTURE_STATE_FILE="$WTM_FIXTURE_REPO/.aimi/state/dev-server.json"
}

test_serve_status_stale_after_external_kill() {
  echo ""
  echo "=== Testing serve status — stale after external kill ==="

  if [[ -z "${_SERVE_FIXTURE_PID:-}" ]]; then
    echo -e "${RED}✗${NC} serve status: stale after kill — running fixture missing (did test_serve_status_running run first?)"
    ((TESTS_FAILED++))
    return
  fi

  local keys_before
  keys_before=$(jq 'keys | length' "$_SERVE_FIXTURE_STATE_FILE" 2>/dev/null)

  # Simulate a process that died without going through `serve stop`.
  kill -9 "$_SERVE_FIXTURE_PID" 2>/dev/null || true
  local waited=0
  while kill -0 "$_SERVE_FIXTURE_PID" 2>/dev/null && [[ "$waited" -lt 20 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  local status_out status_rc
  status_out=$(bash "$WTM" serve status "$_SERVE_FIXTURE_BRANCH" 2>/dev/null)
  status_rc=$?

  assert_eq '{"running":false,"port":null,"pid":null}' "$status_out" \
    "serve status: stale after kill — JSON shape (not running)"
  assert_exit_code "0" "$status_rc" "serve status: stale after kill — exit code"

  # Post-fix contract (US-012): status is a true read-only verb. The stale
  # entry must still be present afterward — cleanup happens only via serve
  # start's own reuse path or serve stop, never as a side effect of status.
  # Keyed by resolved absolute path (US-009), not the branch/worktree name,
  # so we count keys and match a path suffix rather than assuming the key
  # literally equals the branch name.
  local keys_after
  keys_after=$(jq 'keys | length' "$_SERVE_FIXTURE_STATE_FILE" 2>/dev/null)
  assert_eq "$keys_before" "$keys_after" \
    "serve status: stale after kill — entry count unchanged (status never deletes)"

  local entry_still_present
  entry_still_present=$(jq --arg suffix "/.worktrees/$_SERVE_FIXTURE_BRANCH" \
    '[to_entries[] | select(.key | endswith($suffix))] | length' \
    "$_SERVE_FIXTURE_STATE_FILE" 2>/dev/null)
  assert_eq "1" "$entry_still_present" \
    "serve status: stale after kill — stale entry still present, matched by key suffix"

  unset _SERVE_FIXTURE_PID _SERVE_FIXTURE_STATE_FILE _SERVE_FIXTURE_BRANCH
  teardown_npm_stub
  teardown_wtm_fixture
}

# ============================================================================
# Install Deps Tests
# ============================================================================

test_install_deps_skips_without_package_json() {
  echo ""
  echo "=== Testing install-deps — no package.json ==="

  setup_wtm_fixture

  local branch="no-pkg-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"
  bash "$WTM" create "$branch" >/dev/null 2>&1

  local out rc
  out=$(bash "$WTM" install-deps "$branch" 2>&1)
  rc=$?

  assert_exit_code "0" "$rc" "install-deps: no package.json — exit code"
  assert_contains "No package.json in worktree, skipping dependency install" "$out" \
    "install-deps: no package.json — informational message"
  assert_eq "false" "$([[ -d "$worktree_path/node_modules" ]] && echo true || echo false)" \
    "install-deps: no package.json — no node_modules created"

  teardown_wtm_fixture
}

# ============================================================================
# Branch Name Validation Tests
# ============================================================================

# Regression guard for finding B2: the hardened regex (dot removed from the
# character class, per root CLAUDE.md's ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$) rejects
# a `..` traversal segment mid-string, unlike the old dot-inclusive class
# (whose leading-character rule alone didn't stop it).
test_validate_branch_name_rejects_traversal() {
  echo ""
  echo "=== Testing validate_branch_name — traversal rejection ==="

  setup_wtm_fixture

  local stderr_file out rc stderr_output
  stderr_file=$(mktemp)
  out=$(bash "$WTM" create 'feat/foo/../../../../outside' 2>"$stderr_file")
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "1" "$rc" "validate_branch_name: traversal string — exit code"
  assert_stderr_contains "Invalid branch name" "$stderr_output" \
    "validate_branch_name: traversal string — stderr message"

  teardown_wtm_fixture
}

# ============================================================================
# Main
# ============================================================================

main() {
  echo "================================================"
  echo "  Worktree Manager Test Suite"
  echo "================================================"

  # Backstop cleanup on exit/abort — normal test flow already tears down
  # after itself; both teardown functions are no-ops when nothing is active.
  trap 'teardown_wtm_fixture; teardown_npm_stub' EXIT

  echo ""
  echo "--- Create/Remove Tests ---"
  test_create_remove_recreate_with_keep_branch
  test_create_remove_default_removes_branch

  echo ""
  echo "--- Serve Status Tests ---"
  test_serve_status_never_started
  test_serve_status_running
  test_serve_status_stale_after_external_kill

  echo ""
  echo "--- Install Deps Tests ---"
  test_install_deps_skips_without_package_json

  echo ""
  echo "--- Branch Name Validation Tests ---"
  test_validate_branch_name_rejects_traversal

  echo ""
  echo "================================================"
  echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
