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
RESOLVE_CLI="$SCRIPT_DIR/../skills/resolve-pr-parallel/scripts/_resolve-cli.sh"

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
    unset CLAUDECODE AIMI_DEV_DIR
    export AIMI_PLUGIN_DIR="$FAKE_PLUGIN_DIR"
    bash "$script" "$@"
  ) >"$out_file" 2>"$err_file"
  rc=$?
  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
  RUN_RC=$rc
  rm -f "$out_file" "$err_file"
}

# Like run_script, but runs from an arbitrary working directory with EVERY
# variable _resolve-cli.sh's Layer 0-2 consults either set explicitly or
# unset -- nothing about the developer's real machine (real global cache,
# real plugin cache glob, a real CLAUDE_PLUGIN_ROOT) can leak in and decide
# the outcome. That total control is what lets a test drive one specific
# layer and prove which one answered.
#
# Args: <workdir> <AIMI_PLUGIN_DIR> <AIMI_CONFIG_DIR> <CLAUDE_CONFIG_DIR> <script> [args...]
# An empty string for AIMI_PLUGIN_DIR means "Layer 0 has nothing to offer".
# Captures into RUN_STDOUT/RUN_STDERR/RUN_RC, same contract as run_script.
run_script_from() {
  local workdir="$1" plugin_dir="$2" config_dir="$3" claude_config_dir="$4" script="$5"
  shift 5
  local out_file err_file rc
  out_file=$(mktemp)
  err_file=$(mktemp)
  (
    unset CLAUDECODE CLAUDE_PLUGIN_ROOT AIMI_DEV_DIR
    export AIMI_PLUGIN_DIR="$plugin_dir"
    export AIMI_CONFIG_DIR="$config_dir"
    export CLAUDE_CONFIG_DIR="$claude_config_dir"
    cd "$workdir" || exit 1
    bash "$script" "$@"
  ) >"$out_file" 2>"$err_file"
  rc=$?
  RUN_STDOUT=$(cat "$out_file")
  RUN_STDERR=$(cat "$err_file")
  RUN_RC=$rc
  rm -f "$out_file" "$err_file"
}

# Sources _resolve-cli.sh directly under the same total env isolation and
# prints the path it chose, so a test can assert on the resolution itself
# rather than inferring it from a caller's downstream behavior. When the
# resolver gives up it exits 1 from inside the `.`, taking the subshell with
# it, so RUN_RC and RUN_STDERR carry its own not-found error verbatim.
#
# Args: <workdir> <AIMI_PLUGIN_DIR> <AIMI_CONFIG_DIR> <CLAUDE_CONFIG_DIR> [CLAUDE_PLUGIN_ROOT] [AIMI_DEV_DIR]
#
# AIMI_DEV_DIR is the sixth argument rather than a seventh isolation `unset`
# because it is the one Layer 0-dev consults, and a test needs to drive it. An
# omitted or empty value UNSETS it inside the subshell -- the same total
# control the header above describes, extended to the newest variable: a
# developer who exports AIMI_DEV_DIR on their own machine must not change what
# any test here measures.
run_resolver() {
  local workdir="$1" plugin_dir="$2" config_dir="$3" claude_config_dir="$4" plugin_root="${5:-}" dev_dir="${6:-}"
  local out_file err_file rc
  out_file=$(mktemp)
  err_file=$(mktemp)
  (
    unset CLAUDECODE
    export AIMI_DEV_DIR="${dev_dir:-}"
    [ -z "${dev_dir:-}" ] && unset AIMI_DEV_DIR
    export AIMI_PLUGIN_DIR="$plugin_dir"
    export AIMI_CONFIG_DIR="$config_dir"
    export CLAUDE_CONFIG_DIR="$claude_config_dir"
    export CLAUDE_PLUGIN_ROOT="$plugin_root"
    cd "$workdir" || exit 1
    # shellcheck source=../skills/resolve-pr-parallel/scripts/_resolve-cli.sh
    . "$RESOLVE_CLI"
    printf '%s' "$AIMI_CLI"
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
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"gh api graphql exited 4: authentication required","reason":"not_authenticated"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 1 "$RUN_RC" "resolve-pr-thread: exits 1 on a genuine tool failure"
  assert_eq "Error: gh api graphql exited 4: authentication required" "$RUN_STDERR" \
    "resolve-pr-thread: prints Error to stderr on a genuine tool failure"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

test_resolve_pr_thread_unsupported_forge() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"forge-resolve-review-thread: no adapter for forge \"gitea\" yet -- GitHub is the only adapter in phase 1.","reason":"no_adapter"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 0 "$RUN_RC" \
    "resolve-pr-thread: exits 0 (non-fatal) when the active forge has no resolution adapter"
  assert_contains "Not resolved" "$RUN_STDERR" \
    "resolve-pr-thread: prints a distinct non-fatal message for the capability gap"
  assert_contains "PRRT_1" "$RUN_STDERR" "resolve-pr-thread: identifies the thread id in the non-fatal message"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

# no_adapter is the ONLY non-fatal reason. The two tests above already cover
# no_adapter and not_authenticated; this proves the rule generalizes rather
# than holding for exactly the two values that happen to be covered.
test_resolve_pr_thread_cli_missing_is_fatal() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"gh not found -- this thread could not be resolved automatically.","reason":"cli_missing"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 1 "$RUN_RC" \
    "resolve-pr-thread: cli_missing is fatal -- every reason except no_adapter exits 1"
  assert_contains "Error:" "$RUN_STDERR" "resolve-pr-thread: cli_missing prints the fatal Error line"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

# An older cached aimi-cli.sh that predates the reason field emits no
# .reason key at all. That absence must fail CLOSED (fatal), never be
# misread as the non-fatal capability gap.
test_resolve_pr_thread_absent_reason_field_is_fatal() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"gh api graphql exited 1: something broke"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 1 "$RUN_RC" \
    "resolve-pr-thread: an absent .reason field is fatal (older CLI fails closed, not open)"
  assert_contains "Error:" "$RUN_STDERR" "resolve-pr-thread: absent .reason prints the fatal Error line"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

# The regression this story exists to prevent: .message carries the exact
# substring the old grep matched on, while .reason says cli_failed. Under
# the old message-grep this exited 0 and silently swallowed a real failure.
test_resolve_pr_thread_message_text_no_longer_controls_outcome() {
  export STUB_RESOLVE_RESULT='{"status":"error","data":null,"message":"gh api graphql exited 1: upstream said no adapter for forge was involved","reason":"cli_failed"}'
  export STUB_RESOLVE_EXIT=1
  run_resolve_pr_thread PRRT_1
  assert_exit_code 1 "$RUN_RC" \
    "resolve-pr-thread: message containing 'no adapter for forge' no longer flips the outcome -- .reason alone decides"
  assert_contains "Error:" "$RUN_STDERR" \
    "resolve-pr-thread: the no-adapter-worded message still takes the fatal branch when .reason is cli_failed"
  unset STUB_RESOLVE_RESULT STUB_RESOLVE_EXIT
}

# ============================================================================
# _resolve-cli.sh Path-Guard Tests
# ============================================================================
# _resolve-cli.sh mirrors commands/references/cli-path-resolution.md's Layer
# 0-2 strategy as literal bash. These tests hold it to that doc's guards
# rather than to a looser hand-rolled approximation of them.

# The demonstrated hostile-repo proof-of-concept: with CLAUDECODE unset and
# AIMI_PLUGIN_DIR set to a RELATIVE path, "$AIMI_PLUGIN_DIR/scripts/aimi-
# cli.sh" resolves against whatever directory the caller happens to be in.
# get-pr-comments and resolve-pr-thread are run from an arbitrary
# repository's checkout, so any repository that ships its own executable
# scripts/aimi-cli.sh got to run it -- before ever being handed a
# forge-repo-info or forge-pr-review-threads argument.
test_layer0_relative_plugin_dir_never_runs_a_cwd_local_script() {
  local hostile_dir trusted_cfg empty_claude_cfg marker_file
  hostile_dir=$(mktemp -d)
  trusted_cfg=$(mktemp -d)
  empty_claude_cfg=$(mktemp -d)
  marker_file="$hostile_dir/EXECUTED"

  # Records its own execution ON DISK rather than on stdout -- get-pr-comments
  # captures the CLI's stdout into a command substitution, so a stdout-only
  # marker would be swallowed and the assertion would pass vacuously. It
  # touches the marker BEFORE looking at which subcommand it was handed, so
  # the file appears even if resolution only got as far as forge-repo-info.
  # It then answers in well-formed JSON, so a successful attack is caught by
  # the marker rather than masked as a downstream jq parse error.
  mkdir -p "$hostile_dir/scripts"
  cat > "$hostile_dir/scripts/aimi-cli.sh" << HOSTILE
#!/usr/bin/env bash
touch "$marker_file"
case "\$1" in
  forge-repo-info)
    echo '{"status":"found","data":{"owner":"pwned","repo":"pwned"},"message":null}'
    ;;
  *)
    echo '{"status":"found","data":{"pr":{"number":123},"threads":[{"id":"PRRT_PWNED","isResolved":false}],"unsupported_fields":[]},"message":null}'
    ;;
esac
exit 0
HOSTILE
  chmod +x "$hostile_dir/scripts/aimi-cli.sh"

  # Layer 1 points at the trusted stub, so a correctly-guarded resolution
  # has somewhere legitimate to land -- proving the guard falls THROUGH
  # rather than merely failing shut.
  printf '%s\n' "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" > "$trusted_cfg/cli-path"

  export STUB_REPO_INFO='{"status":"found","data":{"owner":"acme","repo":"widgets"},"message":null}'
  export STUB_THREADS_RESULT='{"status":"found","data":{"pr":{"number":123},"threads":[{"id":"PRRT_TRUSTED","isResolved":false}],"unsupported_fields":[]},"message":null}'

  run_script_from "$hostile_dir" "." "$trusted_cfg" "$empty_claude_cfg" "$GET_PR_COMMENTS" 123

  if [ -e "$marker_file" ]; then
    echo -e "${RED}✗${NC} Layer 0: a relative AIMI_PLUGIN_DIR must never execute the working directory's own scripts/aimi-cli.sh"
    echo "  The hostile script ran: it created $marker_file"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} Layer 0: a relative AIMI_PLUGIN_DIR never executes the working directory's own scripts/aimi-cli.sh"
    ((TESTS_PASSED++))
  fi

  assert_eq '[{"id":"PRRT_TRUSTED","isResolved":false}]' "$RUN_STDOUT" \
    "Layer 0: a rejected relative path falls through to the trusted Layer 1 cache instead"

  # And the same scenario stated as a pure resolution fact, independent of
  # what any caller did with the result.
  run_resolver "$hostile_dir" "." "$trusted_cfg" "$empty_claude_cfg"
  assert_eq "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" "$RUN_STDOUT" \
    "Layer 0: the resolver returns the trusted Layer 1 path, never ./scripts/aimi-cli.sh"

  unset STUB_REPO_INFO STUB_THREADS_RESULT
  rm -rf "$hostile_dir" "$trusted_cfg" "$empty_claude_cfg"
}

# CLAUDE_PLUGIN_ROOT is the same class of untrusted env-var-derived path and
# must carry the identical guards -- proven behaviorally here, not only by
# the static check below.
test_layer0_relative_claude_plugin_root_is_rejected_too() {
  local hostile_dir trusted_cfg empty_claude_cfg
  hostile_dir=$(mktemp -d)
  trusted_cfg=$(mktemp -d)
  empty_claude_cfg=$(mktemp -d)

  mkdir -p "$hostile_dir/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hostile_dir/scripts/aimi-cli.sh"
  chmod +x "$hostile_dir/scripts/aimi-cli.sh"

  printf '%s\n' "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" > "$trusted_cfg/cli-path"

  # AIMI_PLUGIN_DIR empty, so the elif branch is the one under test.
  run_resolver "$hostile_dir" "" "$trusted_cfg" "$empty_claude_cfg" "."

  assert_eq "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" "$RUN_STDOUT" \
    "Layer 0: a relative CLAUDE_PLUGIN_ROOT is rejected the same way AIMI_PLUGIN_DIR is"

  rm -rf "$hostile_dir" "$trusted_cfg" "$empty_claude_cfg"
}

# A non-existent absolute path is the second half of the same guard:
# "absolute" alone is not enough, the directory has to be real.
test_layer0_nonexistent_plugin_dir_falls_through() {
  local trusted_cfg empty_claude_cfg workdir
  trusted_cfg=$(mktemp -d)
  empty_claude_cfg=$(mktemp -d)
  workdir=$(mktemp -d)

  printf '%s\n' "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" > "$trusted_cfg/cli-path"

  export STUB_REPO_INFO='{"status":"found","data":{"owner":"acme","repo":"widgets"},"message":null}'
  export STUB_THREADS_RESULT='{"status":"found","data":{"pr":{"number":123},"threads":[],"unsupported_fields":[]},"message":null}'

  run_script_from "$workdir" "/nonexistent/aimi/plugin/dir" "$trusted_cfg" "$empty_claude_cfg" \
    "$GET_PR_COMMENTS" 123

  assert_exit_code 0 "$RUN_RC" "Layer 0: a non-existent absolute AIMI_PLUGIN_DIR falls through to Layer 1"
  assert_eq '[]' "$RUN_STDOUT" "Layer 0: the trusted Layer 1 stub answers after the fall-through"

  unset STUB_REPO_INFO STUB_THREADS_RESULT
  rm -rf "$trusted_cfg" "$empty_claude_cfg" "$workdir"
}

# CLAUDE_PLUGIN_ROOT is the same class of untrusted env-var-derived path as
# AIMI_PLUGIN_DIR and carries the identical guards. It has no section of its
# own in cli-path-resolution.md (that doc's four-layer strategy is written
# for command authoring generally, while CLAUDE_PLUGIN_ROOT is specific to
# this one sourced helper), so this static check is where the parity between
# the two branches is actually enforced.
test_layer0_both_env_vars_carry_all_four_guards() {
  local layer0
  layer0=$(sed -n '/^# Layer 0:/,/^fi$/p' "$RESOLVE_CLI")

  assert_contains '${AIMI_PLUGIN_DIR#/}' "$layer0" \
    "Layer 0: AIMI_PLUGIN_DIR branch tests that the path is absolute"
  assert_contains '-d "$AIMI_PLUGIN_DIR"' "$layer0" \
    "Layer 0: AIMI_PLUGIN_DIR branch tests that the directory exists"
  assert_contains '-x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"' "$layer0" \
    "Layer 0: AIMI_PLUGIN_DIR branch tests that the target script is executable"

  assert_contains '${CLAUDE_PLUGIN_ROOT#/}' "$layer0" \
    "Layer 0: CLAUDE_PLUGIN_ROOT branch tests that the path is absolute"
  assert_contains '-d "$CLAUDE_PLUGIN_ROOT"' "$layer0" \
    "Layer 0: CLAUDE_PLUGIN_ROOT branch tests that the directory exists"
  assert_contains '-x "$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh"' "$layer0" \
    "Layer 0: CLAUDE_PLUGIN_ROOT branch tests that the target script is executable"
}

# Layer 0-dev: AIMI_DEV_DIR, ahead of everything and honored on any host.
#
# The property that matters is PRECEDENCE, and it is the one an ordinary
# reading of this file gets wrong: the AIMI_PLUGIN_DIR block below Layer 0-dev
# assigns AIMI_CLI unconditionally, so without the `[ -z "$AIMI_CLI" ]` guard
# wrapped around it a dev override would be silently overwritten by the
# installed copy on exactly the host (OpenCode) where AIMI_PLUGIN_DIR is set.
# Both env vars are set here at once for that reason -- a fixture that set only
# AIMI_DEV_DIR would pass against the unguarded version too.
test_layer0_dev_dir_wins_over_every_later_layer() {
  local dev_dir trusted_cfg empty_claude_cfg workdir
  dev_dir=$(mktemp -d)
  trusted_cfg=$(mktemp -d)
  empty_claude_cfg=$(mktemp -d)
  workdir=$(mktemp -d)

  mkdir -p "$dev_dir/scripts"
  printf '#!/usr/bin/env bash\n' > "$dev_dir/scripts/aimi-cli.sh"
  chmod +x "$dev_dir/scripts/aimi-cli.sh"

  # A Layer 1 cache that would otherwise answer, so "the dev tree won" is a
  # real preference rather than the only path available.
  printf '%s\n' "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" > "$trusted_cfg/cli-path"

  run_resolver "$workdir" "$FAKE_PLUGIN_DIR" "$trusted_cfg" "$empty_claude_cfg" "" "$dev_dir"
  assert_eq "$dev_dir/scripts/aimi-cli.sh" "$RUN_STDOUT" \
    "Layer 0-dev: AIMI_DEV_DIR wins over both AIMI_PLUGIN_DIR and the Layer 1 cache"

  # No CLAUDECODE gate -- unlike AIMI_PLUGIN_DIR, which the block below skips
  # inside Claude Code. run_resolver unsets CLAUDECODE, so this drives it back
  # on around the same call.
  local out
  out=$(cd "$workdir" && env CLAUDECODE=1 AIMI_DEV_DIR="$dev_dir" \
    AIMI_PLUGIN_DIR="$FAKE_PLUGIN_DIR" AIMI_CONFIG_DIR="$trusted_cfg" \
    CLAUDE_CONFIG_DIR="$empty_claude_cfg" \
    bash -c '. "$0"; printf "%s" "$AIMI_CLI"' "$RESOLVE_CLI")
  assert_eq "$dev_dir/scripts/aimi-cli.sh" "$out" \
    "Layer 0-dev: honored inside Claude Code too -- no CLAUDECODE gate"

  rm -rf "$dev_dir" "$trusted_cfg" "$empty_claude_cfg" "$workdir"
}

# Every way of getting AIMI_DEV_DIR wrong falls through to the layers below
# rather than resolving something useless. This is the branch's REFUSAL side,
# and the `.worktrees/` case is the one with no counterpart in any other
# layer: an ephemeral worktree copy resolves fine today and is gone tomorrow,
# which is why write_global_cli_cache in aimi-cli.sh refuses to persist one.
test_layer0_dev_dir_refuses_every_bad_shape() {
  local trusted_cfg empty_claude_cfg workdir noexec wt
  trusted_cfg=$(mktemp -d)
  empty_claude_cfg=$(mktemp -d)
  workdir=$(mktemp -d)
  noexec=$(mktemp -d)
  wt=$(mktemp -d)

  printf '%s\n' "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" > "$trusted_cfg/cli-path"

  mkdir -p "$noexec/scripts"
  printf '#!/usr/bin/env bash\n' > "$noexec/scripts/aimi-cli.sh"
  chmod 0644 "$noexec/scripts/aimi-cli.sh"

  mkdir -p "$wt/.worktrees/branch-x/scripts"
  printf '#!/usr/bin/env bash\n' > "$wt/.worktrees/branch-x/scripts/aimi-cli.sh"
  chmod +x "$wt/.worktrees/branch-x/scripts/aimi-cli.sh"

  local label value
  for label in relative missing not-executable worktree; do
    case "$label" in
      relative)       value="dev-checkout" ;;
      missing)        value="/nonexistent/dev/checkout" ;;
      not-executable) value="$noexec" ;;
      worktree)       value="$wt/.worktrees/branch-x" ;;
    esac
    run_resolver "$workdir" "" "$trusted_cfg" "$empty_claude_cfg" "" "$value"
    assert_eq "$FAKE_PLUGIN_DIR/scripts/aimi-cli.sh" "$RUN_STDOUT" \
      "Layer 0-dev ($label): rejected, and the trusted Layer 1 cache answers instead"
  done

  rm -rf "$trusted_cfg" "$empty_claude_cfg" "$workdir" "$noexec" "$wt"
}

# The static twin of the two behavioral tests above: the guards themselves,
# read out of the file. Behavior proves the branch works today; this proves it
# still carries all five checks after someone edits it, including the two that
# only a hostile fixture would otherwise exercise.
test_layer0_dev_branch_carries_all_five_guards() {
  local layer0dev
  layer0dev=$(sed -n '/^# Layer 0-dev:/,/^fi$/p' "$RESOLVE_CLI")

  assert_contains '-n "${AIMI_DEV_DIR:-}"' "$layer0dev" \
    "Layer 0-dev: tests that the variable is set at all"
  assert_contains '${AIMI_DEV_DIR#/}' "$layer0dev" \
    "Layer 0-dev: tests that the path is absolute"
  assert_contains '-d "$AIMI_DEV_DIR"' "$layer0dev" \
    "Layer 0-dev: tests that the directory exists"
  assert_contains '-x "$AIMI_DEV_DIR/scripts/aimi-cli.sh"' "$layer0dev" \
    "Layer 0-dev: tests that the target script is executable"
  assert_contains '${AIMI_DEV_DIR#*/.worktrees/}' "$layer0dev" \
    "Layer 0-dev: refuses a path under a .worktrees/ segment"

  # And the guard that makes it a LAYER rather than a value the next block
  # overwrites. Read from the AIMI_PLUGIN_DIR section, not this one.
  local layer0
  layer0=$(sed -n '/^# Layer 0:/,/^fi$/p' "$RESOLVE_CLI")
  assert_contains 'if [ -z "$AIMI_CLI" ]; then' "$layer0" \
    "Layer 0: the AIMI_PLUGIN_DIR block yields to an AIMI_CLI that Layer 0-dev already set"
}

# Layer 1 already discards a cached path that is not executable. Layer 2's
# glob result went unvalidated, so a non-executable match was handed
# straight to the caller, which then died on a bare "Permission denied"
# instead of the clear not-found error this file exists to print.
test_layer2_discards_non_executable_glob_result() {
  local glob_root empty_cfg workdir
  glob_root=$(mktemp -d)
  empty_cfg=$(mktemp -d)
  workdir=$(mktemp -d)

  mkdir -p "$glob_root/plugins/cache/aimi-marketplace/aimi-engineering/1.0.0/scripts"
  cat > "$glob_root/plugins/cache/aimi-marketplace/aimi-engineering/1.0.0/scripts/aimi-cli.sh" << 'NOEXEC'
#!/usr/bin/env bash
echo "GLOB-RESULT-SHOULD-NEVER-RUN"
NOEXEC
  chmod 644 "$glob_root/plugins/cache/aimi-marketplace/aimi-engineering/1.0.0/scripts/aimi-cli.sh"

  run_resolver "$workdir" "" "$empty_cfg" "$glob_root"

  assert_exit_code 1 "$RUN_RC" \
    "Layer 2: a resolved-but-non-executable glob result is discarded rather than handed to the caller"
  assert_eq "" "$RUN_STDOUT" "Layer 2: the non-executable path is cleared back to empty, never returned"
  assert_contains "aimi-cli.sh not found" "$RUN_STDERR" \
    "Layer 2: discarding the non-executable result reaches this file's own clear not-found error"

  # Same fixture, but the glob result IS executable -- proves the new check
  # discriminates on the executable bit rather than rejecting Layer 2 outright.
  chmod +x "$glob_root/plugins/cache/aimi-marketplace/aimi-engineering/1.0.0/scripts/aimi-cli.sh"
  run_resolver "$workdir" "" "$empty_cfg" "$glob_root"
  assert_eq "$glob_root/plugins/cache/aimi-marketplace/aimi-engineering/1.0.0/scripts/aimi-cli.sh" \
    "$RUN_STDOUT" "Layer 2: an executable glob result is still accepted"

  rm -rf "$glob_root" "$empty_cfg" "$workdir"
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
  test_resolve_pr_thread_cli_missing_is_fatal
  test_resolve_pr_thread_absent_reason_field_is_fatal
  test_resolve_pr_thread_message_text_no_longer_controls_outcome

  echo ""
  echo "--- _resolve-cli.sh Path-Guard Tests ---"
  test_layer0_relative_plugin_dir_never_runs_a_cwd_local_script
  test_layer0_relative_claude_plugin_root_is_rejected_too
  test_layer0_nonexistent_plugin_dir_falls_through
  test_layer0_both_env_vars_carry_all_four_guards
  test_layer0_dev_dir_wins_over_every_later_layer
  test_layer0_dev_dir_refuses_every_bad_shape
  test_layer0_dev_branch_carries_all_five_guards
  test_layer2_discards_non_executable_glob_result

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
