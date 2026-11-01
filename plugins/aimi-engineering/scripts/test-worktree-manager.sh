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
# Colour only when stdout is a terminal, and held as a real ESC byte. The
# three-line form this replaces carried two separate defects. First,
# '\033[0;32m' is four ordinary characters, not an escape, so a plain `echo`
# (no -e) printed them verbatim -- several suites here use plain echo, and
# their result line read "\033[0;32m87 passed\033[0m" on a terminal that was
# perfectly capable of colour. $'...' stores the byte itself, so `echo` and
# `echo -e` finally agree. Second, nothing asked where stdout was going, so a
# captured or piped run carried ANSI into whatever read it next: an assertion
# grepping for "41 passed, 0 failed" could then never match, against any tree,
# and one story's verify failed for exactly that reason while its work was
# sound. Empty on a pipe is what keeps this output greppable.
# AIMI_TEST_COLOR forces colour back on for a caller that captures a stream it
# will replay to a terminal itself -- test-aimi-cli.sh sets it for its parts.
if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ -n "${AIMI_TEST_COLOR:-}" ]; }; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  NC=''
fi

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

# No counterpart in test-aimi-cli.sh: the ensure_gitignore and merge-all
# tests below need to prove a warning is ABSENT (the linked-worktree guard
# must not fire in a main checkout; an empty conflict list must not print a
# "Conflicting files:" heading with nothing under it).
assert_not_contains() {
  local unexpected="$1"
  local actual="$2"
  local test_name="$3"

  if [[ "$actual" != *"$unexpected"* ]]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  Expected NOT to contain: $unexpected"
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

# Defect D1's discriminator: a removal git REFUSED must not print a checkmark.
# Locking the worktree is the cheapest way to make `git worktree remove --force`
# fail for a real, git-stated reason (exit 128, `fatal: cannot remove a locked
# working tree`) without mocking git. Against the pre-fix tree this fails on
# every count at once: the success line printed, the exit status was 0, and
# git's own words never reached the transcript — while the directory, the
# registration and the branch all survived.
test_remove_reports_failure_when_removal_did_not_happen() {
  echo ""
  echo "=== Testing remove reports failure when git could not remove the worktree ==="

  setup_wtm_fixture

  local branch="locked-remove-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1
  git worktree lock "$worktree_path"

  local out rc
  out=$(bash "$WTM" remove "$branch" 2>&1)
  rc=$?

  assert_exit_code "1" "$rc" "remove failure: exit code is non-zero"

  local success_lines
  success_lines=$(printf '%s\n' "$out" | grep -cF '✓ Removed worktree: ' || true)
  assert_eq "0" "$success_lines" "remove failure: no success line is printed"

  # Diagnosable from a transcript alone: the REFUTED container-nesting cause
  # produces a similar-looking symptom ("the worktree is still there
  # afterwards"), and only git's own wording separates the two.
  assert_contains "fatal: cannot remove a locked working tree" "$out" \
    "remove failure: git's own message reaches the transcript"

  # The failure report matches the state on disk — nothing was removed, and
  # the branch ref the next `create` would silently reuse is still there.
  local still_registered still_on_disk branch_count
  still_registered=$(git worktree list | grep -cF "/.worktrees/$branch" || true)
  still_on_disk=$([[ -d "$worktree_path" ]] && echo present || echo gone)
  branch_count=$(git branch --list "$branch" | wc -l | tr -d ' ')
  assert_eq "registered=1 dir=present branches=1" \
    "registered=$still_registered dir=$still_on_disk branches=$branch_count" \
    "remove failure: the worktree and its branch really did survive"

  # Teardown needs no unlock: the fixture is an mktemp -d tree removed
  # wholesale, and `git worktree lock` writes only inside it.
  teardown_wtm_fixture
}

# GUARD-RAIL 2's missing coverage. Research §1.5 measured that both round-trip
# tests above discard stdout (`>/dev/null 2>&1`), so no assertion in the tree
# pins the success path's bytes — gating that path on a post-state check could
# have reworded or duplicated the line with nothing to notice.
test_remove_success_output_is_unchanged() {
  echo ""
  echo "=== Testing a successful remove still prints exactly its success line ==="

  setup_wtm_fixture

  local branch="success-output-branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1

  local out rc
  out=$(bash "$WTM" remove "$branch" 2>&1)
  rc=$?

  assert_exit_code "0" "$rc" "remove success: exit code stays 0"

  assert_contains "✓ Removed worktree: $branch" "$out" \
    "remove success: the success line is byte-identical"

  local success_lines
  success_lines=$(printf '%s\n' "$out" | grep -cF '✓ Removed worktree: ' || true)
  assert_eq "1" "$success_lines" "remove success: printed exactly once"

  teardown_wtm_fixture
}

# remove_worktree now calls _prune_empty_worktree_parents, closing the drift
# against its sibling. Every story branch this plugin creates carries a slash,
# so `.worktrees/feat` is the residue the pre-fix `remove` always left behind —
# and that one directory is what kept the `rmdir "$WORKTREE_DIR"` at the tail of
# remove_worktree from ever firing, making it dead code for every real name.
test_remove_prunes_empty_parent_of_slash_named_worktree() {
  echo ""
  echo "=== Testing remove prunes the empty parent of a slash-named worktree ==="

  setup_wtm_fixture

  bash "$WTM" create feat/x-US-001 >/dev/null 2>&1
  bash "$WTM" remove feat/x-US-001 >/dev/null 2>&1
  local remove_rc=$?

  assert_exit_code "0" "$remove_rc" "remove prune: remove — exit code"

  local parent_dir wt_dir
  parent_dir=$([[ -d "$WTM_FIXTURE_REPO/.worktrees/feat" ]] && echo present || echo gone)
  wt_dir=$([[ -d "$WTM_FIXTURE_REPO/.worktrees" ]] && echo present || echo gone)
  assert_eq "gone gone" "$parent_dir $wt_dir" \
    "remove prune: no empty parent dir left under .worktrees"

  teardown_wtm_fixture
}

# The known-gap fixture, reproduced: a container at `.worktrees/bug/cont` with a
# story worktree nested at `.worktrees/bug/cont/.worktrees/bug/cont-US-001`.
# Called from the OUTER root, the composed path `.worktrees/bug/cont-US-001` is
# one level above the real one, so the pre-fix remove printed "may already be
# removed" and exited 0 while the worktree was registered AND on disk. Resolving
# from the register instead makes this the one case that becomes a NEW failure —
# every other unmatched name keeps its benign exit 0, which fifteen call sites
# in commands/ depend on.
test_remove_refuses_a_name_registered_only_inside_a_nested_container() {
  echo ""
  echo "=== Testing remove refuses a name registered only inside a nested container ==="

  setup_wtm_fixture

  local container_path="$WTM_FIXTURE_REPO/.worktrees/bug/cont"
  local story_path="$container_path/.worktrees/bug/cont-US-001"

  bash "$WTM" create bug/cont --from main >/dev/null 2>&1
  ( cd "$container_path" && bash "$WTM" create bug/cont-US-001 --from bug/cont ) >/dev/null 2>&1
  local nested_rc=$?
  assert_exit_code "0" "$nested_rc" "remove nested: nested create — exit code"

  local out rc
  out=$(bash "$WTM" remove bug/cont-US-001 2>&1)
  rc=$?

  # Three claims in one, the way test_cleanup_removes_worktree_on_slash_branch
  # collapses its own: the pre-fix tree fails all three together — it exits 0,
  # it calls the worktree already removed, and it leaves it registered.
  local benign_line still_registered
  benign_line=$(printf '%s\n' "$out" | grep -cF 'may already be removed' || true)
  still_registered=$(git worktree list | grep -cF '/.worktrees/bug/cont/.worktrees/bug/cont-US-001' || true)
  assert_eq "rc=1 benign=0 registered=1" \
    "rc=$rc benign=$benign_line registered=$still_registered" \
    "remove nested: refused loudly instead of reported as already removed"

  # Named by its registered path, not by the composed one — that is the only
  # text that tells the operator where the worktree actually is. Asserted on
  # the tail rather than the absolute path, which git reports resolved.
  assert_contains "/.worktrees/bug/cont/.worktrees/bug/cont-US-001" "$out" \
    "remove nested: names the registered path this root cannot reach"

  assert_eq "present" "$([[ -d "$story_path" ]] && echo present || echo absent)" \
    "remove nested: the nested worktree is left untouched"

  teardown_wtm_fixture
}

# ============================================================================
# List / Cleanup Tests
# ============================================================================
#
# Issue #149: every branch this plugin creates carries a slash — bug/…,
# feat/…, and every story branch <base>-US-NNN nested under it — so the
# worktree for one lands a directory deeper than `.worktrees/<name>`.
# list_worktrees and cleanup_worktrees each walked `"$WORKTREE_DIR"/*` under
# a byte-identical `[[ -d … && -e …/.git ]]` guard, so the glob stopped at
# `.worktrees/bug`, which is a directory with no `.git`, and neither function
# ever saw the worktree. The damage is asymmetric and that is why the two are
# tested together: a blind `list` reports wrong, a blind `cleanup` does not
# clean. The six `nested branch:` assertions below are the discriminators —
# every one of them fails against the pre-fix tree; the two `flat branch:`
# ones are guard-rails and pass either side of the fix.

test_list_sees_worktree_on_slash_branch() {
  echo ""
  echo "=== Testing list sees a worktree created from a tipo/nome branch ==="

  setup_wtm_fixture

  bash "$WTM" create bug/issue-149-pr-body >/dev/null 2>&1
  bash "$WTM" create flatname >/dev/null 2>&1

  local out
  out=$(bash "$WTM" list 2>&1)

  local nested_entries
  nested_entries=$(printf '%s\n' "$out" | grep -cF 'bug/issue-149-pr-body → branch:' || true)
  assert_eq "1" "$nested_entries" \
    "list nested branch: the slash-named worktree is listed"

  # The displayed name is the path relative to .worktrees/, never the bare
  # basename: switch_worktree reopens "$WORKTREE_DIR/$name" and the serve
  # state key is realpath -m of that same join, so a truncated name would be
  # one nothing else in this script can resolve.
  assert_contains "  bug/issue-149-pr-body → branch: bug/issue-149-pr-body" "$out" \
    "list nested branch: named by its path under .worktrees"

  assert_contains "Total: 2 worktree(s)" "$out" \
    "list nested branch: total counts nested and flat together"

  # GUARD-RAIL (passes before and after): two-space indent, U+2192, no ANSI —
  # this branch of the echo -e carries no colour. The fix changes WHICH
  # entries the two functions see, never HOW one is printed.
  assert_contains "  flatname → branch: flatname" "$out" \
    "list flat branch: line format unchanged (guard-rail)"

  teardown_wtm_fixture
}

test_cleanup_removes_worktree_on_slash_branch() {
  echo ""
  echo "=== Testing cleanup removes a worktree created from a tipo/nome branch ==="

  setup_wtm_fixture

  bash "$WTM" create bug/issue-149-pr-body >/dev/null 2>&1
  bash "$WTM" create flatname >/dev/null 2>&1

  local cleanup_out
  cleanup_out=$(bash "$WTM" cleanup 2>&1)

  # Three claims in one, because the pre-fix tree fails all three the same
  # way — the entry is never enumerated, so it is never offered as a
  # candidate, never reported as removed, and stays registered with git.
  local nested_registered candidate_line removed_line
  nested_registered=$(git worktree list | grep -cF '/.worktrees/bug/issue-149-pr-body' || true)
  candidate_line=$(printf '%s\n' "$cleanup_out" | grep -cF '• bug/issue-149-pr-body' || true)
  removed_line=$(printf '%s\n' "$cleanup_out" | grep -cF '✓ Removed: bug/issue-149-pr-body' || true)
  assert_eq "registered=0 candidate=1 removed=1" \
    "registered=$nested_registered candidate=$candidate_line removed=$removed_line" \
    "cleanup nested branch: the slash-named worktree is removed"

  # The consequence the basename hid: against the branch bug/issue-149-pr-body,
  # `git branch -D issue-149-pr-body` answers "branch not found" and exits 1,
  # and the real call swallows that with `2>/dev/null || true`. Fixing only
  # the enumeration would remove the worktree and leave the branch behind in
  # silence, which is why the display name is data here and not decoration.
  local nested_branches
  nested_branches=$(git branch --list 'bug/issue-149-pr-body' | wc -l | tr -d ' ')
  assert_eq "0" "$nested_branches" \
    "cleanup nested branch: its branch is deleted too"

  # `git worktree remove` deletes the leaf and keeps `.worktrees/bug`; that
  # residue is exactly what stops the rmdir cleanup_worktrees already attempts
  # from collecting `.worktrees` itself. Both must be gone.
  local parent_dir wt_dir
  parent_dir=$([[ -d "$WTM_FIXTURE_REPO/.worktrees/bug" ]] && echo present || echo gone)
  wt_dir=$([[ -d "$WTM_FIXTURE_REPO/.worktrees" ]] && echo present || echo gone)
  assert_eq "gone gone" "$parent_dir $wt_dir" \
    "cleanup nested branch: no empty parent dir left under .worktrees"

  # GUARD-RAIL (passes before and after): the flat-named worktree was always
  # cleaned up, branch included, and still is.
  local flat_registered flat_branches
  flat_registered=$(git worktree list | grep -cF '/.worktrees/flatname' || true)
  flat_branches=$(git branch --list 'flatname' | wc -l | tr -d ' ')
  assert_eq "registered=0 branches=0" \
    "registered=$flat_registered branches=$flat_branches" \
    "cleanup flat branch: still removed as before (guard-rail)"

  teardown_wtm_fixture
}

# ============================================================================
# Environment Files Tests
# ============================================================================
#
# Issue #142: copy_env_files used to glob exactly ".env*", so a project whose
# runtime reads .dev.vars (wrangler/Cloudflare Workers' own convention) got a
# worktree that could not run its own gate. These three prove the fix's
# discriminating claims: .dev.vars now copies, AIMI_WORKTREE_ENV_GLOBS
# replaces the default rather than adding to it, and *.example stays
# excluded once .dev.vars* is globbed too.

test_create_copies_dev_vars_glob() {
  echo ""
  echo "=== Testing create copies .dev.vars alongside .env ==="

  setup_wtm_fixture

  printf 'SECRET=1\n' > .dev.vars
  printf 'SECRET=1\n' > .env

  local branch="dev-vars-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1

  assert_eq "true" "$([[ -f "$worktree_path/.dev.vars" ]] && echo true || echo false)"     "env files: .dev.vars is copied to the worktree"
  assert_eq "true" "$([[ -f "$worktree_path/.env" ]] && echo true || echo false)"     "env files: .env is still copied to the worktree"

  local mode
  mode=$(stat -c '%a' "$worktree_path/.dev.vars" 2>/dev/null || stat -f '%Lp' "$worktree_path/.dev.vars")
  assert_eq "600" "$mode" "env files: .dev.vars is chmod 600"

  teardown_wtm_fixture
}

test_create_env_globs_env_var_replaces_default() {
  echo ""
  echo "=== Testing AIMI_WORKTREE_ENV_GLOBS replaces (not adds to) the default ==="

  setup_wtm_fixture

  printf 'SECRET=1\n' > .segredos
  printf 'SECRET=1\n' > .env

  local branch="env-globs-override-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  AIMI_WORKTREE_ENV_GLOBS='.segredos*' bash "$WTM" create "$branch" >/dev/null 2>&1

  assert_eq "true" "$([[ -f "$worktree_path/.segredos" ]] && echo true || echo false)"     "env files: AIMI_WORKTREE_ENV_GLOBS glob (.segredos) is honored"
  assert_eq "false" "$([[ -f "$worktree_path/.env" ]] && echo true || echo false)"     "env files: AIMI_WORKTREE_ENV_GLOBS replaces the default — .env is NOT copied"

  teardown_wtm_fixture
}

test_create_excludes_example_files_generalized() {
  echo ""
  echo "=== Testing *.example exclusion generalizes beyond .env.example ==="

  setup_wtm_fixture

  printf 'SECRET=1\n' > .env
  printf 'SECRET=1\n' > .env.example
  printf 'SECRET=1\n' > .dev.vars.example

  local branch="example-exclusion-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1

  assert_eq "true" "$([[ -f "$worktree_path/.env" ]] && echo true || echo false)"     "env files: .env is still copied"
  assert_eq "false" "$([[ -f "$worktree_path/.env.example" ]] && echo true || echo false)"     "env files: .env.example is excluded"
  assert_eq "false" "$([[ -f "$worktree_path/.dev.vars.example" ]] && echo true || echo false)"     "env files: .dev.vars.example is excluded — the exclusion generalized beyond .env.example"

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
# Serve Deps Tests
# ============================================================================
# serve start's pre-launch path: the install marker, the borrowed-dependency
# walk, the subfolder pick and --dir. The dev script appends $PWD to a witness
# file outside the worktree, so "launched nothing" is an absent line rather
# than an inference. The gate is also called directly by sourcing the script.

sd_setup() {
  setup_wtm_fixture
  setup_npm_stub
  SD_NAME="${1:-sd-branch}"
  SD_WT="$WTM_FIXTURE_REPO/.worktrees/$SD_NAME"
  SD_WITNESS=$(mktemp)
  rm -f "$SD_WITNESS"
  export SD_WITNESS
  export DEV_SERVER_READY_TIMEOUT=10
  bash "$WTM" create "$SD_NAME" >/dev/null 2>&1
}

sd_teardown() {
  bash "$WTM" serve stop "$SD_NAME" >/dev/null 2>&1 || true
  rm -f "$SD_WITNESS"
  unset SD_WITNESS
  teardown_npm_stub
  teardown_wtm_fixture
}

# $1 target directory: writes a package.json whose dev script records $PWD.
sd_package() {
  mkdir -p "$1"
  cat > "$1/package.json" << 'PKG'
{
  "name": "wtm-serve-deps",
  "scripts": {
    "dev": "echo \"$PWD\" >> \"$SD_WITNESS\"; exec python3 -m http.server \"$PORT\" --bind 127.0.0.1"
  }
}
PKG
}

sd_marker() {
  local m
  m=$(bash -c 'source "$1"; _deps_marker_path "$2"' _ "$WTM" "$SD_WT")
  printf '%s\n' "$1" > "$m"
}

# Sets SD_OUT (stdout), SD_ERR (stderr) and SD_RC of `serve start`.
sd_start() {
  local errf
  errf=$(mktemp)
  SD_OUT=$(bash "$WTM" serve start "$SD_NAME" "$@" 2>"$errf")
  SD_RC=$?
  SD_ERR=$(cat "$errf")
  rm -f "$errf"
}

# Prints "<rc>|<reason>" of _serve_deps_gate <SD_WT> <dir>.
sd_gate() {
  bash -c 'source "$1"; set +e; out=$(_serve_deps_gate "$2" "$3"); rc=$?; printf "%s|%s" "$rc" "$out"' _ "$WTM" "$SD_WT" "$1"
}

sd_launched() {
  if [[ -s "$SD_WITNESS" ]]; then echo true; else echo false; fi
}

test_serve_deps_marker_refuses() {
  echo ""
  echo "=== Testing serve deps — marker failed / needs-recipe ==="
  sd_setup sd-marker
  sd_package "$SD_WT"
  mkdir -p "$WTM_FIXTURE_REPO/node_modules"

  sd_marker '{"status":"failed","directories":[{"dir":".","status":"failed","command":"npm ci","lockfileHash":""}]}'
  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: failed marker — exit code"
  assert_eq "" "$SD_OUT" "serve deps: failed marker — nothing on stdout"
  assert_stderr_contains "install failed" "$SD_ERR" "serve deps: failed marker — names the failed install"
  assert_eq "false" "$(sd_launched)" "serve deps: failed marker — no dev server launched"

  sd_marker '{"status":"needs-recipe","directories":[{"dir":".","status":"needs-recipe","command":"","lockfileHash":""}]}'
  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: needs-recipe marker — exit code"
  assert_eq "" "$SD_OUT" "serve deps: needs-recipe marker — nothing on stdout"
  assert_stderr_contains "no install command is known" "$SD_ERR" "serve deps: needs-recipe marker — says no command is known"
  assert_eq "false" "$(sd_launched)" "serve deps: needs-recipe marker — no dev server launched"

  sd_marker '{"status":"ok","directories":[{"dir":".","status":"ok","command":"npm ci","lockfileHash":""}]}'
  sd_start
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: ok marker — starts although an ancestor holds node_modules"
  assert_eq "true" "$(sd_launched)" "serve deps: ok marker — dev server launched"

  sd_teardown
}

test_serve_deps_registered_server_kept() {
  echo ""
  echo "=== Testing serve deps — registered server is neither reused nor stopped ==="
  sd_setup sd-kept
  sd_package "$SD_WT"

  sd_start
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: registered — first start serves"

  sd_marker '{"status":"failed","directories":[{"dir":".","status":"failed","command":"npm ci","lockfileHash":""}]}'
  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: registered — refusal exit code"
  assert_eq "" "$SD_OUT" "serve deps: registered — refusal prints no URL (no reuse)"
  assert_stderr_contains "install failed" "$SD_ERR" "serve deps: registered — refusal names the failed install"
  assert_eq "true" "$(bash "$WTM" serve status "$SD_NAME" 2>/dev/null | jq -r '.running')" \
    "serve deps: registered — server still running"

  sd_teardown
}

test_serve_deps_gate_contract() {
  echo ""
  echo "=== Testing serve deps — _serve_deps_gate return contract ==="
  sd_setup sd-gate
  mkdir -p "$SD_WT/web" "$SD_WT/api"

  assert_eq "0|" "$(sd_gate .)" "serve deps: gate — no marker, no dependencies anywhere allows"

  sd_marker '{"status":"failed","directories":[{"dir":".","status":"failed"},{"dir":"web","status":"ok"},{"dir":"api","status":"needs-recipe"}]}'
  local g
  g=$(sd_gate .)
  assert_eq "1" "${g%%|*}" "serve deps: gate — failed entry returns 1"
  assert_eq "1" "$(printf '%s' "${g#*|}" | wc -l | tr -d ' ' | awk '{print ($1<=1)?1:0}')" "serve deps: gate — one reason line"
  assert_contains "failed" "${g#*|}" "serve deps: gate — failed reason says failed"
  assert_eq "0|" "$(sd_gate web)" "serve deps: gate — ok sibling is not blocked by a failed directory"
  g=$(sd_gate api)
  assert_eq "1" "${g%%|*}" "serve deps: gate — needs-recipe entry returns 1"
  assert_contains "no install command" "${g#*|}" "serve deps: gate — needs-recipe reason"

  sd_marker 'not json {'
  mkdir -p "$WTM_FIXTURE_REPO/node_modules"
  g=$(sd_gate .)
  assert_eq "1" "${g%%|*}" "serve deps: gate — unparseable marker falls through to the dependency rule"
  assert_contains "$WTM_FIXTURE_REPO" "${g#*|}" "serve deps: gate — the ancestor is named"

  sd_marker '{"status":"ok","directories":[{"dir":"web","status":"ok"}]}'
  g=$(sd_gate .)
  assert_eq "1" "${g%%|*}" "serve deps: gate — entry-less marker falls through to the dependency rule"

  sd_marker '{"status":"ok","directories":[{"dir":"./web","status":"ok"}]}'
  assert_eq "0|" "$(sd_gate web)" "serve deps: gate — a ./-prefixed marker dir matches"

  rm -f "$(bash -c 'source "$1"; _deps_marker_path "$2"' _ "$WTM" "$SD_WT")"
  mkdir -p "$SD_WT/web/node_modules"
  assert_eq "0|" "$(sd_gate web)" "serve deps: gate — node_modules in the served directory allows"
  assert_eq "1" "$(sd_gate api | cut -d'|' -f1)" "serve deps: gate — a sibling's node_modules does not cover the served directory"

  rm -rf "$SD_WT/web/node_modules"
  mkdir -p "$SD_WT/node_modules"
  assert_eq "0|" "$(sd_gate web)" "serve deps: gate — node_modules hoisted at the worktree root allows"
  rm -rf "$SD_WT/node_modules"
  : > "$SD_WT/.pnp.cjs"
  assert_eq "0|" "$(sd_gate web)" "serve deps: gate — .pnp.cjs at the worktree root allows (yarn berry)"
  rm -f "$SD_WT/.pnp.cjs"
  assert_eq "1" "$(sd_gate web | cut -d'|' -f1)" "serve deps: gate — only an ancestor's node_modules refuses"

  sd_teardown
}

test_serve_deps_borrowed() {
  echo ""
  echo "=== Testing serve deps — borrowed dependencies ==="
  sd_setup sd-borrow
  sd_package "$SD_WT"
  mkdir -p "$WTM_FIXTURE_REPO/node_modules"

  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: borrowed — exit code"
  assert_eq "" "$SD_OUT" "serve deps: borrowed — no URL"
  assert_stderr_contains "$WTM_FIXTURE_REPO" "$SD_ERR" "serve deps: borrowed — stderr names the ancestor"
  assert_eq "false" "$(sd_launched)" "serve deps: borrowed — nothing launched"

  mkdir -p "$SD_WT/node_modules"
  sd_start
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: own node_modules — starts"
  bash "$WTM" serve stop "$SD_NAME" >/dev/null 2>&1
  rm -rf "$SD_WT/node_modules" "$SD_WITNESS"

  : > "$SD_WT/.pnp.cjs"
  sd_start
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: yarn berry .pnp.cjs without node_modules — starts"
  bash "$WTM" serve stop "$SD_NAME" >/dev/null 2>&1

  sd_teardown

  sd_setup sd-clean
  sd_package "$SD_WT"
  sd_start
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: no dependency directory anywhere — starts as before"
  sd_teardown
}

test_serve_deps_subfolder_pick() {
  echo ""
  echo "=== Testing serve deps — subfolder pick ==="
  sd_setup sd-pick
  sd_package "$SD_WT/web"
  mkdir -p "$SD_WT/docs" "$SD_WT/.hidden" "$SD_WT/vendor" "$SD_WT/dist" "$SD_WT/build" "$SD_WT/node_modules/pkg"
  printf '{"name":"docs"}\n' > "$SD_WT/docs/package.json"
  for d in .hidden vendor dist build node_modules/pkg; do sd_package "$SD_WT/$d"; done

  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: pick — exit code"
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: pick — serves the only candidate"
  assert_stderr_contains "web" "$SD_ERR" "serve deps: pick — names the subfolder on stderr"
  assert_eq "$(cd "$SD_WT/web" && pwd -P)" "$(head -n 1 "$SD_WITNESS" | xargs -I{} sh -c 'cd "{}" && pwd -P')" \
    "serve deps: pick — the dev command ran from inside the subfolder"
  assert_eq "web" "$(jq -r 'to_entries[0].value.dir' "$WTM_FIXTURE_REPO/.aimi/state/dev-server.json")" \
    "serve deps: pick — registry entry records dir"
  bash "$WTM" serve stop "$SD_NAME" >/dev/null 2>&1
  rm -f "$SD_WITNESS"

  sd_package "$SD_WT/admin"
  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: several candidates — exit code"
  assert_eq "" "$SD_OUT" "serve deps: several candidates — no URL"
  assert_stderr_contains "admin, web" "$SD_ERR" "serve deps: several candidates — names them"
  assert_stderr_contains "--dir" "$SD_ERR" "serve deps: several candidates — names --dir"
  assert_eq "false" "$(sd_launched)" "serve deps: several candidates — nothing launched"
  sd_teardown

  sd_setup sd-none
  mkdir -p "$SD_WT/docs"
  printf '{"name":"docs"}\n' > "$SD_WT/docs/package.json"
  sd_start
  assert_exit_code "0" "$SD_RC" "serve deps: no candidate — clean skip exit code"
  assert_eq "" "$SD_OUT" "serve deps: no candidate — clean skip prints nothing"
  sd_teardown
}

test_serve_deps_dir_option() {
  echo ""
  echo "=== Testing serve deps — --dir ==="
  sd_setup sd-dir
  sd_package "$SD_WT/web"
  sd_package "$SD_WT/api"
  mkdir -p "$SD_WT/empty" "$SD_WT/.hid" "$SD_WT/node_modules" "$WTM_FIXTURE_REPO/outside"
  ln -s "$WTM_FIXTURE_REPO/outside" "$SD_WT/escape"

  local bad
  for bad in "" "web/x" ".." ".hid" "node_modules" "nope" "escape"; do
    sd_start --dir "$bad"
    assert_eq "1::true" "$SD_RC:$SD_OUT:$([[ "$SD_ERR" == *"--dir"* ]] && echo true || echo false)" \
      "serve deps: --dir '${bad}' is a usage error naming --dir"
  done
  sd_start --bogus
  assert_eq "1:" "$SD_RC:$SD_OUT" "serve deps: unknown option is a usage error"
  sd_start web
  assert_eq "1:" "$SD_RC:$SD_OUT" "serve deps: a second positional argument is a usage error"
  sd_start --dir
  assert_eq "1:" "$SD_RC:$SD_OUT" "serve deps: --dir with no value is a usage error"

  sd_start --dir empty
  assert_eq "0:" "$SD_RC:$SD_OUT" "serve deps: --dir on a folder without package.json is a clean skip"

  sd_start --dir web
  assert_contains "http://127.0.0.1:" "$SD_OUT" "serve deps: --dir web serves web"
  local url_web="$SD_OUT"
  assert_eq "web" "$(jq -r 'to_entries[0].value.dir' "$WTM_FIXTURE_REPO/.aimi/state/dev-server.json")" \
    "serve deps: registry entry carries dir=web"

  sd_start --dir api
  assert_exit_code "0" "$SD_RC" "serve deps: other directory — exit code"
  assert_eq "" "$SD_OUT" "serve deps: other directory — no URL"
  assert_stderr_contains "web" "$SD_ERR" "serve deps: other directory — names the registered directory"
  assert_stderr_contains "serve stop" "$SD_ERR" "serve deps: other directory — names serve stop"
  assert_eq "true" "$(bash "$WTM" serve status "$SD_NAME" 2>/dev/null | jq -r '.running')" \
    "serve deps: other directory — registered server left running"

  sd_start --dir web
  assert_eq "$url_web" "$SD_OUT" "serve deps: same directory — reused"
  sd_teardown

  sd_setup sd-dir-root
  sd_package "$SD_WT"
  sd_package "$SD_WT/web"
  sd_start --dir web
  assert_eq "1:" "$SD_RC:$SD_OUT" "serve deps: --dir with a root package.json is a usage error"
  sd_start
  assert_eq "." "$(jq -r 'to_entries[0].value.dir' "$WTM_FIXTURE_REPO/.aimi/state/dev-server.json")" \
    "serve deps: root server registers dir=."
  local root_url="$SD_OUT"
  local state="$WTM_FIXTURE_REPO/.aimi/state/dev-server.json"
  jq 'map_values(del(.dir))' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  sd_start
  assert_eq "$root_url" "$SD_OUT" "serve deps: an entry without dir counts as ."
  jq 'map_values(.dir = "web")' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
  sd_start
  assert_eq "" "$SD_OUT" "serve deps: a server registered for web is not reused for ."
  assert_eq "true" "$(bash "$WTM" serve status "$SD_NAME" 2>/dev/null | jq -r '.running')" \
    "serve deps: status keyed by worktree, still running"
  sd_teardown
}

test_serve_deps_docs() {
  echo ""
  echo "=== Testing serve deps — usage text ==="
  assert_contains "[--dir <subfolder>]" "$(bash "$WTM" help 2>&1)" "serve deps: help documents serve start --dir"
  assert_contains "borrowed" "$(bash "$WTM" help 2>&1)" "serve deps: help documents the borrowed-dependency refusal"
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
  assert_eq "DEPS_STATUS=nothing-to-install" "$(printf '%s\n' "$out" | tail -n 1)" \
    "install-deps: no package.json — status line"
  local marker
  marker=$(bash -c 'source "$1"; _deps_marker_path "$2"' _ "$WTM" "$worktree_path")
  assert_eq "nothing-to-install" "$(jq -r .status "$marker")" \
    "install-deps: no package.json — marker status"
  assert_eq "0" "$(jq -r '.directories | length' "$marker")" \
    "install-deps: no package.json — marker directories empty"

  teardown_wtm_fixture
}

# ----------------------------------------------------------------------------
# Install engine tests. Stubs for bun, npm, pnpm and yarn log
# "<tool>|<cwd>|<args>" to $DE_LOG, create node_modules/ (and, for `npm
# install`, a package-lock.json), and fail in any directory holding a
# .stub-fail file. No real package manager and no network run.
# ----------------------------------------------------------------------------

de_setup() {
  setup_wtm_fixture
  DE_STUB_DIR=$(mktemp -d)
  DE_LOG="$DE_STUB_DIR/log"
  : > "$DE_LOG"
  local t
  for t in bun npm pnpm yarn mytool; do
    cat > "$DE_STUB_DIR/$t" << 'STUB'
#!/bin/bash
printf '%s|%s|%s\n' "$(basename "$0")" "$PWD" "$*" >> "$DE_LOG"
if [[ -e "$PWD/.stub-fail" ]]; then exit 1; fi
mkdir -p node_modules
if [[ "$(basename "$0")" == "npm" && "${1:-}" == "install" ]]; then echo '{}' > package-lock.json; fi
exit 0
STUB
    chmod +x "$DE_STUB_DIR/$t"
  done
  DE_OLD_PATH="$PATH"
  export PATH="$DE_STUB_DIR:$PATH"
  export DE_LOG
}

de_teardown() {
  export PATH="$DE_OLD_PATH"
  rm -rf "$DE_STUB_DIR"
  unset DE_STUB_DIR DE_OLD_PATH DE_LOG
  teardown_wtm_fixture
}

# $1 branch: create the worktree, set DE_WT; then run install-deps -> DE_OUT/DE_RC
de_make_wt() {
  bash "$WTM" create "$1" >/dev/null 2>&1
  DE_WT="$WTM_FIXTURE_REPO/.worktrees/$1"
}

de_run() {
  DE_OUT=$(bash "$WTM" install-deps "$1" 2>&1)
  DE_RC=$?
}

de_last_line() { printf '%s\n' "$DE_OUT" | tail -n 1; }

test_deps_engine_frozen_bun_only() {
  echo ""
  echo "=== Testing install-deps engine — bun.lock runs the frozen command only ==="
  de_setup
  de_make_wt eng-bun
  echo '{"name":"x"}' > "$DE_WT/package.json"
  echo 'lock' > "$DE_WT/bun.lock"
  de_run eng-bun
  assert_exit_code "0" "$DE_RC" "engine bun: exit code"
  assert_eq "DEPS_STATUS=ok" "$(de_last_line)" "engine bun: last line"
  assert_eq "1" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine bun: one command ran"
  assert_contains "bun|" "$(cat "$DE_LOG")" "engine bun: bun ran"
  assert_contains "|install --frozen-lockfile" "$(cat "$DE_LOG")" "engine bun: frozen argv"
  assert_eq "false" "$([[ -e "$DE_WT/package-lock.json" ]] && echo true || echo false)" "engine bun: no package-lock.json"
  assert_eq "true" "$([[ -f "$DE_WT/bun.lock" ]] && echo true || echo false)" "engine bun: existing lockfile kept"
  local marker; marker=$(bash -c 'source "$1"; _deps_marker_path "$2"' _ "$WTM" "$DE_WT")
  assert_eq "ok" "$(jq -r .status "$marker")" "engine bun: marker status"
  assert_eq "." "$(jq -r '.directories[0].dir' "$marker")" "engine bun: marker dir"
  assert_eq "bun install --frozen-lockfile" "$(jq -r '.directories[0].command' "$marker")" "engine bun: marker command"
  assert_not_contains "aimi-deps" "$(git -C "$DE_WT" status --porcelain)" "engine bun: marker not in git status"
  de_teardown
}

test_deps_engine_failure_has_no_fallback() {
  echo ""
  echo "=== Testing install-deps engine — failed npm ci runs nothing afterwards ==="
  de_setup
  de_make_wt eng-fail
  echo '{"name":"x"}' > "$DE_WT/package.json"
  echo '{}' > "$DE_WT/package-lock.json"
  touch "$DE_WT/.stub-fail"
  de_run eng-fail
  assert_exit_code "1" "$DE_RC" "engine fail: exit code"
  assert_eq "DEPS_STATUS=failed" "$(de_last_line)" "engine fail: last line"
  assert_eq "1" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine fail: only one command ran"
  assert_contains "npm|" "$(cat "$DE_LOG")" "engine fail: it was npm"
  assert_contains "|ci" "$(cat "$DE_LOG")" "engine fail: npm ci"
  de_teardown
}

test_deps_engine_refuses_metacharacters_and_missing_word() {
  echo ""
  echo "=== Testing install-deps engine — argv guard ==="
  de_setup
  local rc out
  out=$(bash -c 'source "$1"; _deps_run_command "$2" "$3"' _ "$WTM" "$WTM_FIXTURE_REPO" 'mytool install; mytool again' 2>&1); rc=$?
  assert_eq "1" "$rc" "engine guard: metacharacter command fails"
  assert_eq "0" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine guard: metacharacter command ran nothing"
  out=$(bash -c 'source "$1"; _deps_run_command "$2" "$3"' _ "$WTM" "$WTM_FIXTURE_REPO" 'mytool install $(id)' 2>&1); rc=$?
  assert_eq "1" "$rc" "engine guard: substitution refused"
  out=$(bash -c 'source "$1"; _deps_run_command "$2" "$3"' _ "$WTM" "$WTM_FIXTURE_REPO" 'no-such-tool-xyz install' 2>&1); rc=$?
  assert_eq "1" "$rc" "engine guard: missing first word fails"
  assert_contains "no-such-tool-xyz" "$out" "engine guard: missing first word is named"
  assert_eq "0" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine guard: nothing ran"

  # A configured recipe with a metacharacter never reaches the guard: the
  # detector answers needs-recipe and nothing is installed.
  de_make_wt eng-recipe
  echo '{"name":"x"}' > "$DE_WT/package.json"
  mkdir -p "$WTM_FIXTURE_REPO/.aimi"
  echo '{"dependencies":{"install":{".":"mytool install; mytool again"}}}' > "$WTM_FIXTURE_REPO/.aimi/config.json"
  de_run eng-recipe
  assert_exit_code "0" "$DE_RC" "engine recipe: needs-recipe exits 0"
  assert_eq "DEPS_STATUS=needs-recipe" "$(de_last_line)" "engine recipe: status line"
  assert_eq "0" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine recipe: no installer ran"
  de_teardown
}

test_deps_engine_unpinned_install_cleans_lockfile() {
  echo ""
  echo "=== Testing install-deps engine — no lockfile ==="
  de_setup
  de_make_wt eng-nolock
  echo '{"name":"x"}' > "$DE_WT/package.json"
  de_run eng-nolock
  assert_exit_code "0" "$DE_RC" "engine nolock: exit code"
  assert_contains "not pinned" "$DE_OUT" "engine nolock: warns versions are not pinned"
  assert_contains "|install" "$(cat "$DE_LOG")" "engine nolock: npm install ran"
  assert_eq "false" "$([[ -e "$DE_WT/package-lock.json" ]] && echo true || echo false)" "engine nolock: created lockfile deleted"
  assert_eq "DEPS_STATUS=ok" "$(de_last_line)" "engine nolock: status"
  de_teardown
}

test_deps_engine_subfolders() {
  echo ""
  echo "=== Testing install-deps engine — first-level subfolders ==="
  de_setup
  de_make_wt eng-sub
  local d
  for d in b-api a-web c-lib .hidden node_modules vendor dist build; do
    mkdir -p "$DE_WT/$d"
    echo '{"name":"x"}' > "$DE_WT/$d/package.json"
    echo 'l' > "$DE_WT/$d/pnpm-lock.yaml"
  done
  touch "$DE_WT/b-api/.stub-fail"
  de_run eng-sub
  assert_exit_code "1" "$DE_RC" "engine sub: a failing subfolder exits 1"
  assert_eq "DEPS_STATUS=failed" "$(de_last_line)" "engine sub: status line"
  assert_eq "3" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine sub: every eligible subfolder attempted"
  assert_eq "a-web b-api c-lib" "$(cut -d'|' -f2 "$DE_LOG" | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')" "engine sub: sorted order"
  local marker; marker=$(bash -c 'source "$1"; _deps_marker_path "$2"' _ "$WTM" "$DE_WT")
  assert_eq "ok failed ok" "$(jq -r '[.directories[].status] | join(" ")' "$marker")" "engine sub: per-directory status"
  assert_eq "a-web b-api c-lib" "$(jq -r '[.directories[].dir] | join(" ")' "$marker")" "engine sub: per-directory name"
  de_teardown
}

test_deps_engine_rerun_uses_marker() {
  echo ""
  echo "=== Testing install-deps engine — marker re-run ==="
  de_setup
  de_make_wt eng-rerun
  echo '{"name":"x"}' > "$DE_WT/package.json"
  echo 'one' > "$DE_WT/bun.lock"
  de_run eng-rerun
  assert_eq "1" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine rerun: first run installs"
  de_run eng-rerun
  assert_eq "1" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine rerun: same lockfile installs nothing"
  assert_eq "DEPS_STATUS=ok" "$(de_last_line)" "engine rerun: status ok"
  echo 'two' > "$DE_WT/bun.lock"
  de_run eng-rerun
  assert_eq "2" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine rerun: changed lockfile installs again"
  rm -rf "$DE_WT/node_modules"
  de_run eng-rerun
  assert_eq "3" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine rerun: missing node_modules installs again"
  touch "$DE_WT/.stub-fail"
  echo 'three' > "$DE_WT/bun.lock"
  de_run eng-rerun
  assert_eq "DEPS_STATUS=failed" "$(de_last_line)" "engine rerun: failure recorded"
  rm -f "$DE_WT/.stub-fail"
  de_run eng-rerun
  assert_eq "5" "$(wc -l < "$DE_LOG" | tr -d ' ')" "engine rerun: recorded failure installs again"
  assert_eq "DEPS_STATUS=ok" "$(de_last_line)" "engine rerun: recovers"
  de_teardown
}

test_deps_engine_project_key_of_child_repository() {
  echo ""
  echo "=== Testing install-deps engine — child repository of a non-git .aimi parent ==="
  local parent child old_pwd="$PWD"
  parent=$(mktemp -d)
  child="$parent/svc-api"
  mkdir -p "$parent/.aimi" "$child"
  echo '{"dependencies":{"install":{"svc-api":"mytool run setup"}}}' > "$parent/.aimi/config.json"
  DE_STUB_DIR=$(mktemp -d); DE_LOG="$DE_STUB_DIR/log"; : > "$DE_LOG"; export DE_LOG
  cat > "$DE_STUB_DIR/mytool" << 'STUB'
#!/bin/bash
printf '%s|%s|%s\n' "$(basename "$0")" "$PWD" "$*" >> "$DE_LOG"
STUB
  chmod +x "$DE_STUB_DIR/mytool"
  DE_OLD_PATH="$PATH"; export PATH="$DE_STUB_DIR:$PATH"
  ( cd "$child" && git init -q && git config user.email t@example.com && git config user.name T \
    && git checkout -q -b main && echo i > README.md && git add README.md && git commit -q -m init )
  cd "$child"
  bash "$WTM" create eng-key >/dev/null 2>&1
  echo '{"name":"x"}' > "$child/.worktrees/eng-key/package.json"
  local out rc
  out=$(bash "$WTM" install-deps eng-key 2>&1); rc=$?
  cd "$old_pwd"
  assert_exit_code "0" "$rc" "engine key: exit code"
  assert_contains "mytool|" "$(cat "$DE_LOG")" "engine key: recipe under the child's own key ran"
  assert_contains "|run setup" "$(cat "$DE_LOG")" "engine key: recipe argv"
  assert_eq "DEPS_STATUS=ok" "$(printf '%s\n' "$out" | tail -n 1)" "engine key: status"
  export PATH="$DE_OLD_PATH"
  rm -rf "$parent" "$DE_STUB_DIR"
  unset DE_STUB_DIR DE_OLD_PATH DE_LOG
}

# ============================================================================
# Dependency Installer Detection Tests
# ============================================================================

# Run _detect_dependency_installer in a fresh shell that sources the manager.
# $1 dir under test, $2 project key (optional), $3 cwd (default: fixture repo),
# $4 PATH shim dir (optional, put ahead of PATH after sourcing).
dd_detect() {
  local dir="$1" key="${2:-.}" cwd="${3:-$WTM_FIXTURE_REPO}" shim="${4:-}"
  ( cd "$WTM_FIXTURE_REPO" && bash -c '
      source "$1" || exit 99
      cd "$4" || exit 98
      if [ -n "$5" ]; then PATH="$5:$PATH"; fi
      _detect_dependency_installer "$2" "$3"
      echo "rc=$?" >&2
    ' _ "$WTM" "$dir" "$key" "$cwd" "$shim" 2>/dev/null )
}

dd_field() { printf '%s' "$1" | jq -r ".$2"; }

dd_check() {
  # $1 label, $2 json, $3 status, $4 manager, $5 command, $6 lockfile
  assert_eq "$3|$4|$5|$6" \
    "$(dd_field "$2" status)|$(dd_field "$2" manager)|$(dd_field "$2" command)|$(dd_field "$2" lockfile)" \
    "detect deps: $1"
}

test_detect_deps_lockfiles() {
  echo ""
  echo "=== Testing dependency installer detection — lockfiles ==="
  setup_wtm_fixture
  local d out
  d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/bun.lock"
  out=$(dd_detect "$d")
  assert_eq "{\"status\":\"ready\",\"manager\":\"bun\",\"command\":\"bun install --frozen-lockfile\",\"lockfile\":\"bun.lock\",\"source\":\"repository\",\"reason\":\"\"}" "$out" \
    "detect deps: bun.lock only gives the exact one-line answer"
  assert_eq "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "detect deps: answer is a single line"
  assert_eq "bun.lock package.json" "$(ls -A "$d" | tr '\n' ' ' | sed 's/ $//')" "detect deps: detector writes no file"
  rm -rf "$d"

  d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/bun.lockb"
  dd_check "bun.lockb" "$(dd_detect "$d")" ready bun "bun install --frozen-lockfile" bun.lockb
  rm -rf "$d"; d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/pnpm-lock.yaml"
  dd_check "pnpm-lock.yaml" "$(dd_detect "$d")" ready pnpm "pnpm install --frozen-lockfile" pnpm-lock.yaml
  rm -rf "$d"; d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/package-lock.json"
  dd_check "package-lock.json" "$(dd_detect "$d")" ready npm "npm ci" package-lock.json
  touch "$d/npm-shrinkwrap.json"
  dd_check "shrinkwrap reported beside package-lock" "$(dd_detect "$d")" ready npm "npm ci" npm-shrinkwrap.json
  rm -rf "$d"; d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/bun.lock" "$d/bun.lockb"
  dd_check "bun.lock beside bun.lockb is one manager" "$(dd_detect "$d")" ready bun "bun install --frozen-lockfile" bun.lock
  rm -rf "$d"
  teardown_wtm_fixture
}

test_detect_deps_yarn_generation() {
  echo ""
  echo "=== Testing dependency installer detection — yarn generation ==="
  setup_wtm_fixture
  local d
  d=$(mktemp -d); echo '{}' > "$d/package.json"; printf '# yarn lockfile v1\n' > "$d/yarn.lock"
  dd_check "yarn classic by header" "$(dd_detect "$d")" ready yarn "yarn install --frozen-lockfile" yarn.lock
  printf '__metadata:\n  version: 6\n' > "$d/yarn.lock"
  dd_check "yarn berry by __metadata" "$(dd_detect "$d")" ready yarn "yarn install --immutable" yarn.lock
  printf '# yarn lockfile v1\n' > "$d/yarn.lock"; echo '{"packageManager":"yarn@4.1.0"}' > "$d/package.json"
  dd_check "packageManager major beats the header" "$(dd_detect "$d")" ready yarn "yarn install --immutable" yarn.lock
  echo '{"packageManager":"yarn@1.22.19"}' > "$d/package.json"; printf '__metadata:\n' > "$d/yarn.lock"
  dd_check "packageManager major 1 is classic" "$(dd_detect "$d")" ready yarn "yarn install --frozen-lockfile" yarn.lock
  echo '{}' > "$d/package.json"; : > "$d/yarn.lock"
  dd_check "yarn undecided needs a recipe" "$(dd_detect "$d")" needs-recipe "" "" ""
  echo 'nodeLinker: node-modules' > "$d/.yarnrc.yml"
  dd_check "yarn berry by .yarnrc.yml" "$(dd_detect "$d")" ready yarn "yarn install --immutable" yarn.lock
  rm -rf "$d"
  teardown_wtm_fixture
}

test_detect_deps_declared_manager() {
  echo ""
  echo "=== Testing dependency installer detection — declared manager ==="
  setup_wtm_fixture
  local d out
  d=$(mktemp -d); echo '{"packageManager":"pnpm@9.1.0"}' > "$d/package.json"; touch "$d/pnpm-lock.yaml" "$d/yarn.lock"
  dd_check "declared pnpm wins over a yarn.lock beside it" "$(dd_detect "$d")" ready pnpm "pnpm install --frozen-lockfile" pnpm-lock.yaml
  rm -rf "$d"; d=$(mktemp -d); echo '{"packageManager":"bun@1.1.0"}' > "$d/package.json"
  out=$(dd_detect "$d")
  dd_check "declared bun with no lockfile is plain install" "$out" ready bun "bun install" ""
  assert_eq "no lockfile: versions are not pinned" "$(dd_field "$out" reason)" "detect deps: unpinned reason is the fixed phrase"
  rm -rf "$d"; d=$(mktemp -d); echo '{}' > "$d/package.json"
  dd_check "undeclared package.json without lockfile is npm install" "$(dd_detect "$d")" ready npm "npm install" ""
  echo '{"devEngines":{"packageManager":{"name":"pnpm"}}}' > "$d/package.json"; touch "$d/pnpm-lock.yaml"
  dd_check "devEngines object" "$(dd_detect "$d")" ready pnpm "pnpm install --frozen-lockfile" pnpm-lock.yaml
  echo '{"devEngines":{"packageManager":[{"name":"pnpm"}]}}' > "$d/package.json"
  dd_check "devEngines array of one" "$(dd_detect "$d")" ready pnpm "pnpm install --frozen-lockfile" pnpm-lock.yaml
  rm -rf "$d"
  teardown_wtm_fixture
}

test_detect_deps_needs_recipe() {
  echo ""
  echo "=== Testing dependency installer detection — refusals to guess ==="
  setup_wtm_fixture
  local d out
  d=$(mktemp -d); echo '{"packageManager":"bun@1.1.0"}' > "$d/package.json"; touch "$d/package-lock.json"
  dd_check "declared manager without its lockfile, another present" "$(dd_detect "$d")" needs-recipe "" "" ""
  rm -rf "$d"; d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/bun.lock" "$d/pnpm-lock.yaml"
  dd_check "two managers' lockfiles, nothing declared" "$(dd_detect "$d")" needs-recipe "" "" ""
  rm -rf "$d"; d=$(mktemp -d); echo '{"packageManager":"pnpm@9.0.0","devEngines":{"packageManager":{"name":"bun"}}}' > "$d/package.json"
  dd_check "packageManager and devEngines disagree" "$(dd_detect "$d")" needs-recipe "" "" ""
  echo '{"devEngines":{"packageManager":[{"name":"bun"},{"name":"npm"}]}}' > "$d/package.json"
  dd_check "devEngines array naming two managers" "$(dd_detect "$d")" needs-recipe "" "" ""
  echo '{"packageManager":"evil$(touch x)@1.0.0"}' > "$d/package.json"
  out=$(dd_detect "$d")
  dd_check "unknown declared manager" "$out" needs-recipe "" "" ""
  assert_not_contains "evil" "$out" "detect deps: reason never echoes package.json text"
  echo '{not json' > "$d/package.json"
  dd_check "unparseable package.json" "$(dd_detect "$d")" needs-recipe "" "" ""
  rm -rf "$d"
  teardown_wtm_fixture
}

test_detect_deps_config_recipe() {
  echo ""
  echo "=== Testing dependency installer detection — config recipe ==="
  setup_wtm_fixture
  local d out cfg="$WTM_FIXTURE_REPO/.aimi/config.json"
  d=$(mktemp -d)
  printf '{"dependencies":{"install":{".":"  make deps  ","web":"npm ci --prefix web"}}}' > "$cfg"
  out=$(dd_detect "$d")
  assert_eq "ready|config||make deps|" "$(dd_field "$out" status)|$(dd_field "$out" source)|$(dd_field "$out" manager)|$(dd_field "$out" command)|$(dd_field "$out" lockfile)" \
    "detect deps: recipe beats everything, even with no manifest, and is trimmed"
  assert_eq "npm ci --prefix web" "$(dd_field "$(dd_detect "$d" web)" command)" "detect deps: recipe is keyed by project"
  echo '{}' > "$d/package.json"; touch "$d/bun.lock"
  assert_eq "config" "$(dd_field "$(dd_detect "$d")" source)" "detect deps: recipe beats a bun.lock repository"
  local bad bad_n=0
  for bad in 'a;b' 'a|b' 'a&b' 'a$b' 'a<b' 'a>b' 'a`b`' 'a\nb'; do
    printf '{"dependencies":{"install":{".":"%s"}}}' "$bad" > "$cfg"
    bad_n=$((bad_n + 1))
    out=$(dd_detect "$d")
    assert_eq "needs-recipe|config|" "$(dd_field "$out" status)|$(dd_field "$out" source)|$(dd_field "$out" command)" \
      "detect deps: recipe refused for forbidden character #$bad_n of 8"
  done
  printf '{"dependencies":{"install":{".":"   "}}}' > "$cfg"
  assert_eq "needs-recipe" "$(dd_field "$(dd_detect "$d")" status)" "detect deps: blank recipe refused"
  printf '{"dependencies":{"install":{".":5}}}' > "$cfg"
  assert_eq "needs-recipe" "$(dd_field "$(dd_detect "$d")" status)" "detect deps: non-string recipe refused"
  printf 'not json' > "$cfg"
  assert_eq "bun" "$(dd_field "$(dd_detect "$d")" manager)" "detect deps: invalid config JSON behaves as {}"
  printf '{"dependencies":{"install":{"other":"x"}}}' > "$cfg"
  assert_eq "bun" "$(dd_field "$(dd_detect "$d")" manager)" "detect deps: config without the key behaves as {}"

  printf '{"dependencies":{"install":{".":"make deps"}}}' > "$cfg"
  git -C "$WTM_FIXTURE_REPO" add -f .aimi/config.json >/dev/null 2>&1
  out=$(dd_detect "$d")
  assert_eq "needs-recipe|config|" "$(dd_field "$out" status)|$(dd_field "$out" source)|$(dd_field "$out" command)" \
    "detect deps: recipe in a git-tracked config refused"
  git -C "$WTM_FIXTURE_REPO" rm -q --cached .aimi/config.json >/dev/null 2>&1

  local shim
  shim=$(mktemp -d)
  printf '#!/bin/sh\necho "fatal: detected dubious ownership in repository" >&2\nexit 128\n' > "$shim/git"
  chmod +x "$shim/git"
  out=$(dd_detect "$d" "." "$WTM_FIXTURE_REPO" "$shim")
  assert_eq "needs-recipe" "$(dd_field "$out" status)" "detect deps: a git that cannot answer reads as tracked"
  rm -rf "$shim"

  local multi
  multi=$(mktemp -d); mkdir -p "$multi/.aimi"
  printf '{"dependencies":{"install":{".":"make deps"}}}' > "$multi/.aimi/config.json"
  out=$(dd_detect "$d" "." "$multi")
  assert_eq "ready|make deps" "$(dd_field "$out" status)|$(dd_field "$out" command)" \
    "detect deps: config under a non-git root is trusted"
  rm -rf "$multi" "$d"
  teardown_wtm_fixture
}

test_detect_deps_other_manifests() {
  echo ""
  echo "=== Testing dependency installer detection — other manifests ==="
  setup_wtm_fixture
  local d m out
  for m in pyproject.toml requirements.txt Gemfile build.gradle; do
    d=$(mktemp -d); touch "$d/$m"
    out=$(dd_detect "$d")
    assert_eq "needs-recipe" "$(dd_field "$out" status)" "detect deps: $m needs a recipe"
    assert_contains "$m" "$out" "detect deps: reason for $m names it"
    rm -rf "$d"
  done
  d=$(mktemp -d); touch "$d/Gemfile" "$d/pyproject.toml"
  assert_contains "pyproject.toml" "$(dd_detect "$d")" "detect deps: first manifest in the fixed order is named"
  rm -rf "$d"; d=$(mktemp -d); touch "$d/go.mod" "$d/Cargo.toml"
  assert_eq "nothing-to-install" "$(dd_field "$(dd_detect "$d")" status)" "detect deps: go.mod and Cargo.toml need nothing"
  rm -rf "$d"; d=$(mktemp -d)
  assert_eq "nothing-to-install" "$(dd_field "$(dd_detect "$d")" status)" "detect deps: empty directory needs nothing"
  echo '{}' > "$d/package.json"; touch "$d/pyproject.toml"
  assert_eq "npm" "$(dd_field "$(dd_detect "$d")" manager)" "detect deps: package.json beside another manifest wins"
  rm -rf "$d"
  teardown_wtm_fixture
}

test_detect_deps_package_manager_follows() {
  echo ""
  echo "=== Testing _detect_package_manager follows the detector ==="
  setup_wtm_fixture
  local d out
  d=$(mktemp -d); echo '{}' > "$d/package.json"; touch "$d/bun.lock"
  out=$(bash -c 'source "$1"; _detect_package_manager "$2"; echo END' _ "$WTM" "$d" 2>/dev/null)
  assert_eq "bunEND" "$out" "detect deps: bun.lock-only worktree gives bun with no trailing newline"
  rm -f "$d/bun.lock"; touch "$d/yarn.lock" "$d/package-lock.json"
  out=$(bash -c 'source "$1"; _detect_package_manager "$2"' _ "$WTM" "$d" 2>/dev/null)
  assert_eq "yarn" "$out" "detect deps: ambiguous lockfiles keep the old order"
  rm -f "$d/yarn.lock" "$d/package-lock.json"
  out=$(bash -c 'source "$1"; _detect_package_manager "$2"' _ "$WTM" "$d" 2>/dev/null)
  assert_eq "npm" "$out" "detect deps: nothing at all is npm"
  rm -rf "$d"
  out=$(bash -c 'source "$1"; echo sourced' _ "$WTM" 2>&1)
  assert_eq "sourced" "$out" "detect deps: sourcing defines functions and does not run main"
  out=$(bash -s -- help < "$WTM" 2>&1 | head -3)
  assert_contains "Git Worktree Manager" "$out" "detect deps: piped execution still runs main"
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
# Ensure Gitignore Tests
# ============================================================================
#
# ensure_gitignore() had no coverage at all before this section, and it has
# four distinct outcomes: the HEAD-already-has-the-entry early return, the
# linked-worktree skip (issue #127), the tracked-and-clean warning, and the
# append. All four are reached through `create`, which is the only caller.
#
# The linked-worktree discriminator compares `git rev-parse --git-dir`
# against `--git-common-dir`. Those two can come back in DIFFERENT FORMS for
# the same directory — on git 2.34.1, run from a subdirectory of a main
# checkout, --git-dir answers an absolute `/abs/.git` while --git-common-dir
# answers a relative `../../.git` — so the guard normalizes both against
# GIT_ROOT and compares with -ef. test_ensure_gitignore_writes_from_main_checkout_subdirectory
# is the regression guard for exactly that: a raw string comparison would
# make the guard fire on an ordinary repository and disable the append path
# entirely.

# The pre-existing repository-root write path, which had no test before.
# Guards against the linked-worktree skip being widened until it swallows
# the ordinary case.
test_ensure_gitignore_writes_at_repository_root() {
  echo ""
  echo "=== Testing ensure_gitignore — writes at the repository root ==="

  setup_wtm_fixture

  local stderr_file rc stderr_output
  stderr_file=$(mktemp)
  bash "$WTM" create root-write-branch >/dev/null 2>"$stderr_file"
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$rc" "ensure_gitignore (repo root): create — exit code"

  # grep -c prints 0 and exits 1 on no match, and prints nothing at all when
  # the file is missing — normalize both into a plain count.
  local worktrees_lines
  worktrees_lines=$(grep -c '^\.worktrees$' "$WTM_FIXTURE_REPO/.gitignore" 2>/dev/null || true)
  assert_eq "1" "${worktrees_lines:-0}" \
    "ensure_gitignore (repo root): .gitignore written with exactly one .worktrees line"

  # The append branch is only taken because the file is untracked — assert
  # that precondition held, so a future change that starts tracking the
  # fixture's .gitignore can't make this test pass for the wrong reason.
  local tracked
  tracked=$(git -C "$WTM_FIXTURE_REPO" ls-files --error-unmatch .gitignore >/dev/null 2>&1 && echo true || echo false)
  assert_eq "false" "$tracked" \
    "ensure_gitignore (repo root): the written .gitignore is untracked"

  assert_not_contains "Warning:" "$stderr_output" \
    "ensure_gitignore (repo root): no warning on stderr"

  teardown_wtm_fixture
}

# Regression guard for the normalization inside the linked-worktree
# discriminator: run from a SUBDIRECTORY of a main checkout, git answers
# --git-dir and --git-common-dir in different forms for the same directory.
# Comparing them as raw strings would fire the guard here and stop
# ensure_gitignore writing anything in an ordinary repository.
test_ensure_gitignore_writes_from_main_checkout_subdirectory() {
  echo ""
  echo "=== Testing ensure_gitignore — main checkout, invoked from a subdirectory ==="

  setup_wtm_fixture

  mkdir -p "$WTM_FIXTURE_REPO/pkg/deep"

  # Assert the hazard itself, in a form no git version can invalidate: the
  # two answers name the SAME directory even when their spellings differ.
  local raw_git_dir raw_common_dir same_dir
  raw_git_dir=$(cd "$WTM_FIXTURE_REPO/pkg/deep" && git rev-parse --git-dir)
  raw_common_dir=$(cd "$WTM_FIXTURE_REPO/pkg/deep" && git rev-parse --git-common-dir)
  case "$raw_git_dir" in /*) ;; *) raw_git_dir="$WTM_FIXTURE_REPO/pkg/deep/$raw_git_dir" ;; esac
  case "$raw_common_dir" in /*) ;; *) raw_common_dir="$WTM_FIXTURE_REPO/pkg/deep/$raw_common_dir" ;; esac
  same_dir=$([[ "$raw_git_dir" -ef "$raw_common_dir" ]] && echo true || echo false)
  assert_eq "true" "$same_dir" \
    "ensure_gitignore (subdirectory): --git-dir and --git-common-dir name the same dir in a main checkout"

  local stderr_file rc stderr_output
  stderr_file=$(mktemp)
  ( cd "$WTM_FIXTURE_REPO/pkg/deep" && bash "$WTM" create subdir-invoked-branch ) >/dev/null 2>"$stderr_file"
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$rc" "ensure_gitignore (subdirectory): create — exit code"

  local worktrees_lines
  worktrees_lines=$(grep -c '^\.worktrees$' "$WTM_FIXTURE_REPO/.gitignore" 2>/dev/null || true)
  assert_eq "1" "${worktrees_lines:-0}" \
    "ensure_gitignore (subdirectory): .gitignore still written at the repository root"

  assert_not_contains "linked worktree" "$stderr_output" \
    "ensure_gitignore (subdirectory): linked-worktree guard does NOT fire in a main checkout"

  teardown_wtm_fixture
}

# Issue #127: container/phase mode runs `create` with CWD inside a linked
# worktree, so GIT_ROOT is the container's own top level. Appending there
# leaves an untracked .gitignore that a later merge-all aborts on.
test_ensure_gitignore_skips_in_linked_worktree() {
  echo ""
  echo "=== Testing ensure_gitignore — skips inside a linked worktree ==="

  setup_wtm_fixture

  local container_path="$WTM_FIXTURE_REPO/.worktrees/phase-branch"

  bash "$WTM" create phase-branch --from main >/dev/null 2>&1

  # `git worktree add` checks out tracked files only, and the root .gitignore
  # written by the create above is untracked — so the container starts with
  # no .gitignore of its own. That is the "before" state the assertions below
  # require to stay unchanged.
  local container_gitignore_before
  container_gitignore_before=$([[ -e "$container_path/.gitignore" ]] && echo present || echo absent)
  assert_eq "absent" "$container_gitignore_before" \
    "ensure_gitignore (linked worktree): container starts with no .gitignore"

  local stderr_file rc stderr_output
  stderr_file=$(mktemp)
  ( cd "$container_path" && bash "$WTM" create phase-branch-US-001 --from phase-branch ) >/dev/null 2>"$stderr_file"
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$rc" "ensure_gitignore (linked worktree): nested create — exit code"

  local container_gitignore_after
  container_gitignore_after=$([[ -e "$container_path/.gitignore" ]] && echo present || echo absent)
  assert_eq "absent" "$container_gitignore_after" \
    "ensure_gitignore (linked worktree): container .gitignore left exactly as it was (never written)"

  assert_stderr_contains "running inside a linked worktree" "$stderr_output" \
    "ensure_gitignore (linked worktree): warns instead of writing"

  teardown_wtm_fixture
}

# The one case container mode must never silently dirty.
test_ensure_gitignore_warns_on_tracked_clean_gitignore() {
  echo ""
  echo "=== Testing ensure_gitignore — tracked and clean, missing entry ==="

  setup_wtm_fixture

  printf 'node_modules\n' > "$WTM_FIXTURE_REPO/.gitignore"
  git -C "$WTM_FIXTURE_REPO" add .gitignore
  git -C "$WTM_FIXTURE_REPO" commit -q -m "Add .gitignore without a .worktrees entry"

  local before after
  before=$(cksum < "$WTM_FIXTURE_REPO/.gitignore")

  local stderr_file rc stderr_output
  stderr_file=$(mktemp)
  bash "$WTM" create tracked-clean-branch >/dev/null 2>"$stderr_file"
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$rc" "ensure_gitignore (tracked+clean): create — exit code"

  assert_stderr_contains "is tracked and clean but missing a .worktrees entry" "$stderr_output" \
    "ensure_gitignore (tracked+clean): warning on stderr"

  after=$(cksum < "$WTM_FIXTURE_REPO/.gitignore")
  assert_eq "$before" "$after" \
    "ensure_gitignore (tracked+clean): .gitignore byte-for-byte unchanged"

  teardown_wtm_fixture
}

# Committed truth wins: nothing is appended on top of an entry HEAD already
# carries, so no duplicate line accumulates across repeated creates.
test_ensure_gitignore_early_return_when_entry_present() {
  echo ""
  echo "=== Testing ensure_gitignore — entry already in HEAD ==="

  setup_wtm_fixture

  printf '.worktrees\nnode_modules\n' > "$WTM_FIXTURE_REPO/.gitignore"
  git -C "$WTM_FIXTURE_REPO" add .gitignore
  git -C "$WTM_FIXTURE_REPO" commit -q -m "Add .gitignore with a .worktrees entry"

  local before after
  before=$(cksum < "$WTM_FIXTURE_REPO/.gitignore")

  local stderr_file rc stderr_output
  stderr_file=$(mktemp)
  bash "$WTM" create has-entry-branch >/dev/null 2>"$stderr_file"
  rc=$?
  stderr_output=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$rc" "ensure_gitignore (entry present): create — exit code"

  after=$(cksum < "$WTM_FIXTURE_REPO/.gitignore")
  assert_eq "$before" "$after" \
    "ensure_gitignore (entry present): .gitignore byte-for-byte unchanged"

  local worktrees_lines
  worktrees_lines=$(grep -c '^\.worktrees$' "$WTM_FIXTURE_REPO/.gitignore" 2>/dev/null || true)
  assert_eq "1" "${worktrees_lines:-0}" \
    "ensure_gitignore (entry present): no duplicate .worktrees line appended"

  assert_not_contains "Warning:" "$stderr_output" \
    "ensure_gitignore (entry present): no warning on stderr"

  teardown_wtm_fixture
}

# ============================================================================
# Merge-All Tests
# ============================================================================
#
# merge_all_worktrees' reporting branch had no coverage either. Two of the
# three tests below turn on the same fact: `git diff --name-only
# --diff-filter=U` lists files with unmerged INDEX entries, and a merge that
# git refuses BEFORE it starts creates none — so the old
# "Conflicting files:" heading printed nothing at all and named no cause.

# The end-to-end shape from the issue #127 report: container worktree, story
# worktree created from inside it, story commits its own .gitignore, merge-all
# run from the container. Before the fix this aborted with "The following
# untracked working tree files would be overwritten by merge".
test_merge_all_succeeds_with_container_and_story_worktree_gitignores() {
  echo ""
  echo "=== Testing merge-all — container + story worktree .gitignore ==="

  setup_wtm_fixture

  local container_path="$WTM_FIXTURE_REPO/.worktrees/phase-branch"
  local story_path="$container_path/.worktrees/phase-branch-US-001"

  bash "$WTM" create phase-branch --from main >/dev/null 2>&1

  local nested_rc
  ( cd "$container_path" && bash "$WTM" create phase-branch-US-001 --from phase-branch ) >/dev/null 2>&1
  nested_rc=$?
  assert_exit_code "0" "$nested_rc" "merge-all (container): nested create — exit code"

  assert_eq "absent" "$([[ -e "$container_path/.gitignore" ]] && echo present || echo absent)" \
    "merge-all (container): no untracked .gitignore left in the container to collide with"

  # The story worktree commits the .gitignore a foundation story would.
  printf '.worktrees\nnode_modules\n' > "$story_path/.gitignore"
  git -C "$story_path" add .gitignore
  git -C "$story_path" commit -q -m "Add .gitignore from the story worktree"

  local stdout_file stderr_file merge_rc stdout_output stderr_output
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  ( cd "$container_path" && bash "$WTM" merge-all phase-branch-US-001 --into phase-branch ) \
    >"$stdout_file" 2>"$stderr_file"
  merge_rc=$?
  stdout_output=$(cat "$stdout_file")
  stderr_output=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  assert_exit_code "0" "$merge_rc" "merge-all (container): merge-all — exit code"
  assert_contains "merged successfully into 'phase-branch'" "$stdout_output" \
    "merge-all (container): reports success"
  assert_not_contains "would be overwritten by merge" "$stderr_output" \
    "merge-all (container): no untracked-overwrite abort"

  assert_eq "present" "$([[ -e "$container_path/.gitignore" ]] && echo present || echo absent)" \
    "merge-all (container): the story's .gitignore landed in the container"

  teardown_wtm_fixture
}

# A pre-merge abort reached through a DIFFERENT condition than the untracked
# .gitignore the fix removes: a local uncommitted change to a tracked file
# the incoming branch also touches. git refuses before entering a conflicted
# state, so --diff-filter=U is empty and only git's own stderr says why.
test_merge_all_reports_stderr_on_empty_conflict_list() {
  echo ""
  echo "=== Testing merge-all — empty conflict list reports git's own stderr ==="

  setup_wtm_fixture

  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/incoming-branch"
  bash "$WTM" create incoming-branch >/dev/null 2>&1

  echo "incoming change" >> "$worktree_path/README.md"
  git -C "$worktree_path" add README.md
  git -C "$worktree_path" commit -q -m "Change README on the incoming branch"

  # Local uncommitted modification to the same tracked file.
  echo "local uncommitted change" >> "$WTM_FIXTURE_REPO/README.md"

  local stdout_file stderr_file rc stdout_output stderr_output
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  bash "$WTM" merge-all incoming-branch --into main >"$stdout_file" 2>"$stderr_file"
  rc=$?
  stdout_output=$(cat "$stdout_file")
  stderr_output=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  assert_exit_code "1" "$rc" "merge-all (empty conflict list): exit code"
  assert_contains "Merge did not start. git reported:" "$stdout_output" \
    "merge-all (empty conflict list): says the merge never started"
  assert_not_contains "Conflicting files:" "$stdout_output" \
    "merge-all (empty conflict list): does not print an empty 'Conflicting files:' listing"
  assert_stderr_contains "would be overwritten by merge" "$stderr_output" \
    "merge-all (empty conflict list): git's own reason reaches the user"

  teardown_wtm_fixture
}

# Neither story specified success-path behaviour, so pin it: capturing git
# merge's stderr must not swallow it when the merge SUCCEEDS. An ambiguous
# refname (a tag sharing the branch's name) makes git warn on stderr while
# still fast-forwarding. The branch deliberately has no worktree, because
# merge_all_worktrees resolves a worktree-backed branch through
# `rev-parse --abbrev-ref HEAD`, which disambiguates the name for us.
test_merge_all_replays_stderr_on_successful_merge() {
  echo ""
  echo "=== Testing merge-all — successful merge still shows git's stderr ==="

  setup_wtm_fixture

  git -C "$WTM_FIXTURE_REPO" checkout -q -b ambig-branch
  echo "incoming change" >> "$WTM_FIXTURE_REPO/README.md"
  git -C "$WTM_FIXTURE_REPO" add README.md
  git -C "$WTM_FIXTURE_REPO" commit -q -m "Change README on the ambiguous branch"
  git -C "$WTM_FIXTURE_REPO" checkout -q main
  git -C "$WTM_FIXTURE_REPO" tag ambig-branch refs/heads/ambig-branch

  local stdout_file stderr_file rc stdout_output stderr_output
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  bash "$WTM" merge-all ambig-branch --into main >"$stdout_file" 2>"$stderr_file"
  rc=$?
  stdout_output=$(cat "$stdout_file")
  stderr_output=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  assert_exit_code "0" "$rc" "merge-all (success path): exit code"
  assert_contains "merged successfully into 'main'" "$stdout_output" \
    "merge-all (success path): reports success"
  assert_stderr_contains "refname 'ambig-branch' is ambiguous" "$stderr_output" \
    "merge-all (success path): git's stderr is replayed, not swallowed"

  teardown_wtm_fixture
}

# ============================================================================
# Merge Subject Tests
# ============================================================================
#
# A merge commit needs diverged history, so every case first puts a commit on
# main touching a second file, then a commit on the branch being merged.
# Assertion names start with "merge subject (".

# diverge <branch> <file>: branch off main with a commit on <file>, then add a
# commit to main so the merge cannot fast-forward.
_subject_diverge() {
  local branch="$1" file="$2"
  git -C "$WTM_FIXTURE_REPO" checkout -q -b "$branch" main
  echo "$branch" > "$WTM_FIXTURE_REPO/$file"
  git -C "$WTM_FIXTURE_REPO" add "$file"
  git -C "$WTM_FIXTURE_REPO" commit -q -m "Work on $branch [US-009]"
  git -C "$WTM_FIXTURE_REPO" checkout -q main
  echo "$branch main side" > "$WTM_FIXTURE_REPO/main-$file"
  git -C "$WTM_FIXTURE_REPO" add "main-$file"
  git -C "$WTM_FIXTURE_REPO" commit -q -m "Main side for $branch"
}

_subject_head() { git -C "$WTM_FIXTURE_REPO" log -1 --format=%s main; }
_subject_head_full() { git -C "$WTM_FIXTURE_REPO" log -1 --format=%B main; }

test_merge_subject() {
  echo ""
  echo "=== Testing merge subjects ==="

  setup_wtm_fixture
  local rc out

  # merge --subject
  _subject_diverge feat-one-US-001 one.txt
  bash "$WTM" merge feat-one-US-001 --into main --subject 'Merge story: Add login' >/dev/null 2>&1
  assert_eq "Merge story: Add login" "$(_subject_head)" "merge subject (merge): explicit subject becomes the commit subject"
  assert_not_contains "US-001" "$(_subject_head_full)" "merge subject (merge): body carries no story id"
  assert_not_contains "feat-one" "$(_subject_head_full)" "merge subject (merge): body carries no branch name"

  # merge-all --subject-for, with a sanitizing case
  _subject_diverge feat-two-US-002 two.txt
  bash "$WTM" merge-all feat-two-US-002 --into main --subject-for feat-two-US-002 'Merge story: [US-002] Fix US-002 thing' >/dev/null 2>&1
  assert_eq "Merge story: Fix thing" "$(_subject_head)" "merge subject (merge-all): US-NNN tokens and bracket groups are removed"

  # literal storage of shell syntax
  _subject_diverge feat-three-US-003 three.txt
  local nasty='Merge "x" $(touch /tmp/wtm-subject-pwn) `id`'
  rm -f /tmp/wtm-subject-pwn
  bash "$WTM" merge-all feat-three-US-003 --into main --subject-for feat-three-US-003 "$nasty" >/dev/null 2>&1
  assert_eq "$nasty" "$(_subject_head)" "merge subject (literal): quotes and command substitution stored literally"
  assert_eq "no" "$([ -e /tmp/wtm-subject-pwn ] && echo yes || echo no)" "merge subject (literal): nothing was executed"

  # leading dash
  _subject_diverge feat-four-US-004 four.txt
  bash "$WTM" merge-all feat-four-US-004 --into main --subject-for feat-four-US-004 '-n dash first' >/dev/null 2>&1
  assert_eq "-n dash first" "$(_subject_head)" "merge subject (dash): leading dash stored literally"

  # default for a -US-NNN branch, with no subject supplied
  _subject_diverge feat-five-US-005 five.txt
  bash "$WTM" merge-all feat-five-US-005 --into main >/dev/null 2>&1
  assert_eq "Merge story into main" "$(_subject_head)" "merge subject (default): -US-NNN branch gets the generic subject"

  # any other name keeps git's own default
  _subject_diverge plain-branch six.txt
  bash "$WTM" merge-all plain-branch --into main >/dev/null 2>&1
  assert_contains "Merge branch 'plain-branch'" "$(_subject_head)" "merge subject (default): other names keep git's message"

  # subject empty after sanitizing counts as not supplied
  _subject_diverge feat-seven-US-007 seven.txt
  bash "$WTM" merge-all feat-seven-US-007 --into main --subject-for feat-seven-US-007 '[US-007] US-007' >/dev/null 2>&1
  assert_eq "Merge story into main" "$(_subject_head)" "merge subject (empty): empty after sanitizing falls back to the default"

  # length cap and CR/LF
  _subject_diverge feat-eight-US-008 eight.txt
  local long
  long=$(printf 'a%.0s' $(seq 1 300))
  bash "$WTM" merge-all feat-eight-US-008 --into main --subject-for feat-eight-US-008 "$long" >/dev/null 2>&1
  assert_eq "200" "$(_subject_head | tr -d '\n' | wc -c | tr -d ' ')" "merge subject (cap): cut to 200 characters"
  _subject_diverge feat-nine-US-010 nine.txt
  bash "$WTM" merge-all feat-nine-US-010 --into main --subject-for feat-nine-US-010 $'Line one\r\nLine two' >/dev/null 2>&1
  assert_eq "Line one Line two" "$(_subject_head)" "merge subject (newline): CR and LF removed"

  # --no-log beats a configured merge.log
  git -C "$WTM_FIXTURE_REPO" config merge.log true
  _subject_diverge feat-ten-US-011 ten.txt
  bash "$WTM" merge-all feat-ten-US-011 --into main --subject-for feat-ten-US-011 'Merge story: Ten' >/dev/null 2>&1
  assert_not_contains "US-009" "$(_subject_head_full)" "merge subject (no-log): merge.log shortlog is not appended"
  git -C "$WTM_FIXTURE_REPO" config --unset merge.log

  # fast-forward unchanged: no commit, target at the branch tip
  git -C "$WTM_FIXTURE_REPO" checkout -q -b feat-ff-US-012 main
  echo ff > "$WTM_FIXTURE_REPO/ff.txt"
  git -C "$WTM_FIXTURE_REPO" add ff.txt
  git -C "$WTM_FIXTURE_REPO" commit -q -m "ff work"
  local tip
  tip=$(git -C "$WTM_FIXTURE_REPO" rev-parse HEAD)
  git -C "$WTM_FIXTURE_REPO" checkout -q main
  bash "$WTM" merge-all feat-ff-US-012 --into main --subject-for feat-ff-US-012 'Merge story: ff' >/dev/null 2>&1
  assert_eq "$tip" "$(git -C "$WTM_FIXTURE_REPO" rev-parse main)" "merge subject (fast-forward): target stays at the branch tip"

  # refusals before any git operation
  local before
  before=$(git -C "$WTM_FIXTURE_REPO" rev-parse main)
  out=$(bash "$WTM" merge-all plain-branch --into main --subject-for not-listed 'x' 2>&1); rc=$?
  assert_exit_code "1" "$rc" "merge subject (unknown name): exit code"
  assert_contains "not-listed" "$out" "merge subject (unknown name): names the offender"
  out=$(bash "$WTM" merge-all plain-branch --subject-for plain-branch 2>&1); rc=$?
  assert_exit_code "1" "$rc" "merge subject (missing value): merge-all exit code"
  out=$(bash "$WTM" merge plain-branch --subject 2>&1); rc=$?
  assert_exit_code "1" "$rc" "merge subject (missing value): merge exit code"
  assert_eq "$before" "$(git -C "$WTM_FIXTURE_REPO" rev-parse main)" "merge subject (refusal): target untouched"

  teardown_wtm_fixture
}

# ============================================================================
# Create Sentinel / Base Derivation Tests
# ============================================================================
#
# create_worktree prints two different things on its two branches: the reuse
# branch prints the bare path, the creation branch prints an indented
# "  Path:" and an ANSI-wrapped `cd`. Neither branch ever stated the BASE.
# These tests assert the machine-readable pair on BOTH branches, and assert
# BEHAVIOUR (what the command emits, what the tree stands on) rather than the
# presence of a string in the source file.

# Both branches must emit exactly one WORKTREE_PATH= and one WORKTREE_BASE=,
# and the base must be the real sha of the tree, identical across a create
# and the reuse that follows it.
test_create_emits_sentinels_on_both_branches() {
  echo ""
  echo "=== Testing create emits WORKTREE_PATH=/WORKTREE_BASE= on both branches ==="

  setup_wtm_fixture

  local branch="sentinel-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  local fresh_out reuse_out
  fresh_out=$(bash "$WTM" create "$branch" 2>&1)
  reuse_out=$(bash "$WTM" create "$branch" 2>&1)

  assert_eq "1" "$(printf '%s\n' "$fresh_out" | grep -c '^WORKTREE_PATH=')" \
    "create sentinels: creation branch emits exactly one WORKTREE_PATH= line"
  assert_eq "1" "$(printf '%s\n' "$fresh_out" | grep -c '^WORKTREE_BASE=')" \
    "create sentinels: creation branch emits exactly one WORKTREE_BASE= line"
  assert_eq "1" "$(printf '%s\n' "$reuse_out" | grep -c '^WORKTREE_PATH=')" \
    "create sentinels: reuse branch emits exactly one WORKTREE_PATH= line"
  assert_eq "1" "$(printf '%s\n' "$reuse_out" | grep -c '^WORKTREE_BASE=')" \
    "create sentinels: reuse branch emits exactly one WORKTREE_BASE= line"

  # The path is absolute and is the worktree that actually got created.
  assert_eq "$worktree_path" \
    "$(printf '%s\n' "$fresh_out" | sed -n 's/^WORKTREE_PATH=//p')" \
    "create sentinels: creation branch reports the absolute worktree path"
  assert_eq "$worktree_path" \
    "$(printf '%s\n' "$reuse_out" | sed -n 's/^WORKTREE_PATH=//p')" \
    "create sentinels: reuse branch reports the same absolute worktree path"

  # The base is the FULL sha the worktree actually stands on -- the fact a
  # wrong-base-at-a-right-path failure needs and a path alone cannot give.
  local real_head fresh_base reuse_base
  real_head=$(git -C "$worktree_path" rev-parse HEAD)
  fresh_base=$(printf '%s\n' "$fresh_out" | sed -n 's/^WORKTREE_BASE=//p')
  reuse_base=$(printf '%s\n' "$reuse_out" | sed -n 's/^WORKTREE_BASE=//p')

  assert_eq "$real_head" "$fresh_base" \
    "create sentinels: creation branch reports the sha the worktree stands on"
  assert_eq "$real_head" "$reuse_base" \
    "create sentinels: reuse branch reports the same sha"
  assert_eq "40" "${#fresh_base}" \
    "create sentinels: the sha is full-length, not abbreviated"

  # Existing human output is unchanged -- the sentinels are pure addition.
  assert_contains "Worktree already exists at: $worktree_path" "$reuse_out" \
    "create sentinels: reuse branch keeps its existing human line"
  assert_contains "Path: $worktree_path" "$fresh_out" \
    "create sentinels: creation branch keeps its existing indented Path line"

  teardown_wtm_fixture
}

# The default base is the branch `create` is invoked on, never the literal
# "main". This is the regression under test: a story worktree cut from main
# instead of from its phase branch is correct by path and wrong by content,
# and nothing downstream notices until a verb that exists on the intended
# base answers "Unknown command".
test_create_defaults_from_current_branch() {
  echo ""
  echo "=== Testing create defaults its base to the current branch, not main ==="

  setup_wtm_fixture

  # A second commit on a non-main branch, so "current branch" and "main"
  # resolve to genuinely different shas.
  git checkout -q -b phase-base
  echo "phase work" > phase.txt
  git add phase.txt
  git commit -q -m "phase-only commit"

  local main_sha phase_sha
  main_sha=$(git rev-parse main)
  phase_sha=$(git rev-parse phase-base)
  assert_eq "false" "$([[ "$main_sha" == "$phase_sha" ]] && echo true || echo false)" \
    "create default base: fixture really has two distinct shas"

  local out
  out=$(bash "$WTM" create derived-branch 2>&1)

  assert_contains "From: phase-base" "$out" \
    "create default base: reports the current branch as the base it used"
  assert_not_contains "From: main" "$out" \
    "create default base: does not fall back to the literal main"

  local emitted_base
  emitted_base=$(printf '%s\n' "$out" | sed -n 's/^WORKTREE_BASE=//p')
  assert_eq "$phase_sha" "$emitted_base" \
    "create default base: the new worktree stands on the current branch's sha"

  # An explicit --from still wins over the derived default.
  local explicit_out explicit_base
  explicit_out=$(bash "$WTM" create explicit-branch --from main 2>&1)
  explicit_base=$(printf '%s\n' "$explicit_out" | sed -n 's/^WORKTREE_BASE=//p')
  assert_eq "$main_sha" "$explicit_base" \
    "create default base: an explicit --from still overrides the derived default"
  assert_contains "From: main" "$explicit_out" \
    "create default base: --from is what gets reported when given"

  teardown_wtm_fixture
}

# The absence of .aimi/ IS the assertion. find_aimi_root stops at the first
# directory containing .aimi/, so a worktree that has one becomes PROJECT_ROOT
# instead of the main repository -- and the tasks file, which lives in the
# main repository, is then outside that root, so validate_path_in_project
# refuses the get-story-context every story executor runs as its first action.
test_create_does_not_create_aimi_in_worktree() {
  echo ""
  echo "=== Testing create leaves no .aimi/ inside the worktree ==="

  setup_wtm_fixture

  local branch="no-aimi-branch"
  local worktree_path="$WTM_FIXTURE_REPO/.worktrees/$branch"

  bash "$WTM" create "$branch" >/dev/null 2>&1

  assert_eq "true" "$([[ -d "$worktree_path" ]] && echo true || echo false)" \
    "no .aimi in worktree: the worktree itself was created"
  assert_eq "false" "$([[ -d "$worktree_path/.aimi" ]] && echo true || echo false)" \
    "no .aimi in worktree: create left no .aimi/ behind"

  # The fixture's main repo DOES have .aimi/tasks -- so this proves create
  # declined to make one, not that the fixture simply has none anywhere.
  assert_eq "true" "$([[ -d "$WTM_FIXTURE_REPO/.aimi" ]] && echo true || echo false)" \
    "no .aimi in worktree: the main repository still has its own .aimi/"

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
  test_remove_reports_failure_when_removal_did_not_happen
  test_remove_success_output_is_unchanged
  test_remove_prunes_empty_parent_of_slash_named_worktree
  test_remove_refuses_a_name_registered_only_inside_a_nested_container
  test_create_emits_sentinels_on_both_branches
  test_create_defaults_from_current_branch
  test_create_does_not_create_aimi_in_worktree

  echo ""
  echo "--- List/Cleanup Tests ---"
  test_list_sees_worktree_on_slash_branch
  test_cleanup_removes_worktree_on_slash_branch

  echo ""
  echo "--- Environment Files Tests ---"
  test_create_copies_dev_vars_glob
  test_create_env_globs_env_var_replaces_default
  test_create_excludes_example_files_generalized

  echo ""
  echo "--- Serve Status Tests ---"
  test_serve_status_never_started
  test_serve_status_running
  test_serve_status_stale_after_external_kill

  echo ""
  echo "--- Serve Deps Tests ---"
  test_serve_deps_marker_refuses
  test_serve_deps_registered_server_kept
  test_serve_deps_gate_contract
  test_serve_deps_borrowed
  test_serve_deps_subfolder_pick
  test_serve_deps_dir_option
  test_serve_deps_docs

  echo ""
  echo "--- Install Deps Tests ---"
  test_install_deps_skips_without_package_json
  test_deps_engine_frozen_bun_only
  test_deps_engine_failure_has_no_fallback
  test_deps_engine_refuses_metacharacters_and_missing_word
  test_deps_engine_unpinned_install_cleans_lockfile
  test_deps_engine_subfolders
  test_deps_engine_rerun_uses_marker
  test_deps_engine_project_key_of_child_repository

  echo ""
  echo "--- Dependency Installer Detection Tests ---"
  test_detect_deps_lockfiles
  test_detect_deps_yarn_generation
  test_detect_deps_declared_manager
  test_detect_deps_needs_recipe
  test_detect_deps_config_recipe
  test_detect_deps_other_manifests
  test_detect_deps_package_manager_follows

  echo ""
  echo "--- Branch Name Validation Tests ---"
  test_validate_branch_name_rejects_traversal

  echo ""
  echo "--- Ensure Gitignore Tests ---"
  test_ensure_gitignore_writes_at_repository_root
  test_ensure_gitignore_writes_from_main_checkout_subdirectory
  test_ensure_gitignore_skips_in_linked_worktree
  test_ensure_gitignore_warns_on_tracked_clean_gitignore
  test_ensure_gitignore_early_return_when_entry_present

  echo ""
  echo "--- Merge-All Tests ---"
  test_merge_all_succeeds_with_container_and_story_worktree_gitignores
  test_merge_all_reports_stderr_on_empty_conflict_list
  test_merge_all_replays_stderr_on_successful_merge
  test_merge_subject

  echo ""
  echo "================================================"
  echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
