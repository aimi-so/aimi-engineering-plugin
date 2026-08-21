#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli-part2-planning.sh - part 2 of 4 of the aimi-cli.sh test suite.
#
# Covers branch detection, archiving, research lookup/GC, interactivity,
# model resolution, story-merge and split-detect.
#
# Run it directly for a fast focused loop, or via test-aimi-cli.sh (the
# dispatcher) to run all four parts and get the aggregate count. The parts are
# separate processes so they can eventually run in parallel; the serial run is
# NOT measurably faster than the single 28k-line file was (see CHANGELOG --
# fork cost does scale with script size, but only by ~270us per fork, which is
# a few seconds across the whole suite and below the run-to-run noise floor).
#
# Sections, in the order the single-file suite ran them:
#   - Detect Default Branch Tests
#   - Detect Parent Branch Tests
#   - Archive Task Tests
#   - Research Lookup Tests
#   - Extract Sections Tests
#   - Research GC Tests
#   - Interactivity Mode Detection Tests
#   - resolve-models Tests
#   - get-current-models Tests
#   - list-models Tests
#   - detect-models Tests
#   - Model-Validity Predicate Tests (the four disagreeing validity sites)
#   - models-prompt-check / models-prompt-dismiss Tests
#   - story-merge Tests
#   - split-detect Tests (TC36-TC46, TC50-TC53)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/aimi-cli.sh"

# shellcheck source=./test-aimi-cli-common.sh
. "$SCRIPT_DIR/test-aimi-cli-common.sh"
# shellcheck source=./test-aimi-cli-fixtures.sh
. "$SCRIPT_DIR/test-aimi-cli-fixtures.sh"

# ============================================================================
# Detect Default Branch Fixture Helpers
# ============================================================================

# Creates an isolated git repo (own temp dir) with a single commit, an origin
# remote pointing at a nonexistent local path, and refs/remotes/origin/HEAD
# manually set via update-ref + symbolic-ref -- simulating a real clone whose
# remote later became unreachable. `git remote show origin` against a
# nonexistent local path exits 128 in ~0.004s (no network wait), so this
# fixture is fast and offline-safe. Exercises _resolve_default_branch's
# offline symbolic-ref fallback (aimi-cli.sh:1586).
setup_default_branch_offline_fixture() {
  DEFAULT_BRANCH_FIXTURE_DIR=$(mktemp -d)

  pushd "$DEFAULT_BRANCH_FIXTURE_DIR" >/dev/null
  git init >/dev/null 2>&1
  git checkout -b main >/dev/null 2>&1
  echo "init" > README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1

  git remote add origin /nonexistent/path/that/does/not/exist
  local sha
  sha=$(git rev-parse HEAD)
  git update-ref refs/remotes/origin/main "$sha"
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  # Create .aimi/ directory so find_aimi_root succeeds
  mkdir -p .aimi/tasks

  popd >/dev/null
}

# Creates an isolated git repo (own temp dir) with a single commit and NO
# origin remote at all (and thus no refs/remotes/origin/HEAD) -- exercises
# _resolve_default_branch's error path (aimi-cli.sh:1589-1592).
setup_default_branch_no_origin_fixture() {
  DEFAULT_BRANCH_FIXTURE_DIR=$(mktemp -d)

  pushd "$DEFAULT_BRANCH_FIXTURE_DIR" >/dev/null
  git init >/dev/null 2>&1
  git checkout -b main >/dev/null 2>&1
  echo "init" > README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1

  # Create .aimi/ directory so find_aimi_root succeeds
  mkdir -p .aimi/tasks

  popd >/dev/null
}

# Removes the temp directory created by either default-branch fixture helper
teardown_default_branch_fixture() {
  rm -rf "$DEFAULT_BRANCH_FIXTURE_DIR"
  unset DEFAULT_BRANCH_FIXTURE_DIR
}

# ============================================================================
# Detect Default Branch Tests
# ============================================================================

test_detect_default_branch() {
  echo ""
  echo "=== Testing detect-default-branch command ==="

  local stdout stderr_file stderr_output exit_code

  # --- Offline fallback: origin unreachable, refs/remotes/origin/HEAD
  #     present -- must reach the symbolic-ref fallback at aimi-cli.sh:1586
  #     instead of dying under set -euo pipefail at line 1582.
  #     Invoked from inside the fixture (like setup_parent_branch_fixture's
  #     callers) so find_aimi_root's cwd-based auto-discovery lands on the
  #     fixture's own isolated .aimi/ instead of the enclosing real repo's --
  #     otherwise the cached default-branch state used by _resolve_default_
  #     branch's cache read (aimi-cli.sh:1573) would be the enclosing repo's
  #     shared cache, not this fixture's, defeating isolation between test
  #     cases. --project is still passed to match the documented repro
  #     command shape; it is a same-directory no-op here. ---
  setup_default_branch_offline_fixture
  pushd "$DEFAULT_BRANCH_FIXTURE_DIR" >/dev/null

  stderr_file=$(mktemp)
  stdout=$("$CLI" detect-default-branch --project "$DEFAULT_BRANCH_FIXTURE_DIR" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_output=$(cat "$stderr_file")
  assert_exit_code "0" "$exit_code" "detect-default-branch: offline fallback -- exit code"
  assert_eq "main" "$stdout" "detect-default-branch: offline fallback -- stdout is main"
  assert_eq "" "$stderr_output" "detect-default-branch: offline fallback -- stderr empty"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_default_branch_fixture

  # --- No-origin error path: no remote, no refs/remotes/origin/HEAD -- both
  #     pipelines return empty, must reach the documented error at
  #     aimi-cli.sh:1589-1592 (exit 1) instead of dying under pipefail.
  #     Invoked from inside this (separate, freshly-created) fixture for the
  #     same cache-isolation reason as above. ---
  setup_default_branch_no_origin_fixture
  pushd "$DEFAULT_BRANCH_FIXTURE_DIR" >/dev/null

  stderr_file=$(mktemp)
  stdout=$("$CLI" detect-default-branch --project "$DEFAULT_BRANCH_FIXTURE_DIR" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_output=$(cat "$stderr_file")
  assert_exit_code "1" "$exit_code" "detect-default-branch: no-origin error path -- exit code"
  assert_stderr_contains "Error: Could not detect default branch" "$stderr_output" "detect-default-branch: no-origin error path -- stderr message"
  assert_eq "" "$stdout" "detect-default-branch: no-origin error path -- stdout empty"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_default_branch_fixture

  # --- detect-parent-branch inherits the fix: an orphan branch (zero
  #     decoration candidates anywhere in its --first-parent history) forces
  #     cmd_detect_parent_branch (aimi-cli.sh:1815) to fall back through
  #     _resolve_default_branch against the offline-fallback fixture. Must
  #     complete (base = default branch, source = default-branch) instead of
  #     aborting with exit 128 the way it does today. Stays pushd'd into the
  #     fixture for the CLI invocation for the same isolation reason. ---
  setup_default_branch_offline_fixture
  pushd "$DEFAULT_BRANCH_FIXTURE_DIR" >/dev/null
  git checkout --orphan feat/no-decoration >/dev/null 2>&1
  echo "o1" > o1.txt && git add o1.txt && git commit -m "orphan commit" >/dev/null 2>&1

  local base_out source_out
  stdout=$("$CLI" detect-parent-branch feat/no-decoration) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch: offline fallback inherited -- exit code (no abort)"
  assert_eq "main" "$base_out" "detect-parent-branch: offline fallback inherited -- base falls back to default branch"
  assert_eq "default-branch" "$source_out" "detect-parent-branch: offline fallback inherited -- source is default-branch"

  popd >/dev/null
  teardown_default_branch_fixture
}

test_detect_default_branch_per_repo_scoping() {
  echo ""
  echo "=== Testing detect-default-branch: per-repo cache scoping ==="

  local stdout1 stdout2 stdout3 stdout4 exit_code

  # Invoked from inside MULTI_REPO_FIXTURE_ROOT (which owns the .aimi/ dir)
  # so find_aimi_root's cwd-based auto-discovery lands on this fixture's own
  # isolated AIMI_DIR, matching the documented repro command shape where the
  # orchestrator's cwd is the multi-repo AIMI_ROOT.
  setup_multi_repo_default_branch_fixture
  pushd "$MULTI_REPO_FIXTURE_ROOT" >/dev/null

  stdout1=$("$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_A") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch per-repo scoping: repo-a first call -- exit code"
  assert_eq "main" "$stdout1" "detect-default-branch per-repo scoping: repo-a first call resolves main"

  stdout2=$("$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_B") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch per-repo scoping: repo-b call -- exit code"
  assert_eq "master" "$stdout2" "detect-default-branch per-repo scoping: repo-b resolves master, not contaminated by repo-a's cached main"

  stdout3=$("$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_A") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch per-repo scoping: repo-a second call -- exit code"
  assert_eq "main" "$stdout3" "detect-default-branch per-repo scoping: repo-a second call still resolves main"

  # Reproduces the downstream failure the old contamination caused: repo-b's
  # resolved branch (master) must genuinely exist there, and repo-b must NOT
  # have a "main" branch -- the exact mismatch that made
  # `worktree-manager.sh create feat/x-backend --from main` abort with
  # "fatal: Not a valid object name: 'main'" when the stale cached value
  # leaked into the master repo.
  local verify_master_rc verify_main_rc
  (cd "$MULTI_REPO_FIXTURE_B" && git rev-parse --verify master >/dev/null 2>&1) && verify_master_rc=0 || verify_master_rc=$?
  (cd "$MULTI_REPO_FIXTURE_B" && git rev-parse --verify main >/dev/null 2>&1) && verify_main_rc=0 || verify_main_rc=$?
  assert_exit_code "0" "$verify_master_rc" "detect-default-branch per-repo scoping: repo-b's resolved branch (master) verifies inside repo-b"
  [ "$verify_main_rc" != "0" ] && assert_eq "1" "1" "detect-default-branch per-repo scoping: main does NOT exist in repo-b (contamination would have hidden this)" || assert_eq "1" "0" "detect-default-branch per-repo scoping: main does NOT exist in repo-b (contamination would have hidden this)"

  # The per-repo cache is a real cache, not merely correct: remove repo-b's
  # origin remote and confirm the second repo-b call still returns master
  # from the cached per-repo file instead of erroring.
  (cd "$MULTI_REPO_FIXTURE_B" && git remote remove origin)
  stdout4=$("$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_B") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch per-repo scoping: repo-b cached call survives origin removal -- exit code"
  assert_eq "master" "$stdout4" "detect-default-branch per-repo scoping: repo-b cached call survives origin removal -- stdout"

  # The derived cache key never introduces a subdirectory under .aimi/: two
  # flat default-branch-* files exist directly inside AIMI_DIR.
  local cache_file_count
  cache_file_count=$(find "$MULTI_REPO_FIXTURE_ROOT/.aimi" -maxdepth 1 -type f -name "default-branch-*" | wc -l | tr -d ' ')
  assert_eq "2" "$cache_file_count" "detect-default-branch per-repo scoping: two flat per-repo cache files exist directly inside .aimi/"

  popd >/dev/null
  teardown_multi_repo_default_branch_fixture
}

test_clear_state_removes_per_repo_default_branch_cache() {
  echo ""
  echo "=== Testing clear-state: removes per-repo default-branch cache files ==="

  setup_multi_repo_default_branch_fixture
  pushd "$MULTI_REPO_FIXTURE_ROOT" >/dev/null

  "$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_A" >/dev/null
  "$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_B" >/dev/null

  local before_count
  before_count=$(find "$MULTI_REPO_FIXTURE_ROOT/.aimi" -maxdepth 1 -name "default-branch-*" | wc -l | tr -d ' ')
  assert_eq "2" "$before_count" "clear-state per-repo cache: two per-repo default-branch cache files exist before clear-state"

  local output
  output=$("$CLI" clear-state)
  assert_contains "State cleared" "$output" "clear-state per-repo cache: reports success"

  local after_count
  after_count=$(find "$MULTI_REPO_FIXTURE_ROOT/.aimi" -maxdepth 1 -name "default-branch-*" | wc -l | tr -d ' ')
  assert_eq "0" "$after_count" "clear-state per-repo cache: zero default-branch-* files remain after clear-state"

  popd >/dev/null
  teardown_multi_repo_default_branch_fixture
}

test_detect_default_branch_classic_single_repo_regression() {
  echo ""
  echo "=== Testing detect-default-branch: classic single-repo layout regression ==="

  local stdout1 stdout2 exit_code

  # Classic layout: AIMI_ROOT IS the git repository, no --project passed.
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  stdout1=$("$CLI" detect-default-branch) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch classic single-repo: first call -- exit code"
  assert_eq "main" "$stdout1" "detect-default-branch classic single-repo: first call resolves main"

  # Remove origin between calls -- the second call must still succeed,
  # proving it was served from cache rather than hitting git again.
  git remote remove origin

  stdout2=$("$CLI" detect-default-branch) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "detect-default-branch classic single-repo: second call after origin removal -- exit code"
  assert_eq "main" "$stdout2" "detect-default-branch classic single-repo: second call served from cache after origin removal"

  popd >/dev/null
  teardown_git_fixture
}

# ============================================================================
# Detect Parent Branch Fixture Helper
# ============================================================================

# Creates a minimal bare remote + local clone with a single commit on main,
# with the bare remote's HEAD pointed at refs/heads/main so `git remote show
# origin` can resolve a default branch (a fresh --bare init defaults to
# master, which is never pushed here, leaving "HEAD branch: (unknown)"
# otherwise). Reuses setup_git_fixture's globals (GIT_FIXTURE_REMOTE /
# GIT_FIXTURE_LOCAL) so the existing teardown_git_fixture applies unchanged.
# Kept separate from setup_git_fixture because detect-parent-branch tests
# need precise, uncluttered control over decoration history --
# setup_git_fixture's merged/unmerged branches would add unrelated decorated
# commits to every ancestry chain.
setup_parent_branch_fixture() {
  GIT_FIXTURE_REMOTE=$(mktemp -d)
  GIT_FIXTURE_LOCAL=$(mktemp -d)

  git init --bare "$GIT_FIXTURE_REMOTE" >/dev/null 2>&1
  git --git-dir="$GIT_FIXTURE_REMOTE" symbolic-ref HEAD refs/heads/main

  git clone "$GIT_FIXTURE_REMOTE" "$GIT_FIXTURE_LOCAL" >/dev/null 2>&1

  pushd "$GIT_FIXTURE_LOCAL" >/dev/null
  git checkout -b main >/dev/null 2>&1
  echo "init" > README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1
  git push -u origin main >/dev/null 2>&1

  # Create .aimi/ directory so find_aimi_root succeeds
  mkdir -p .aimi/tasks

  popd >/dev/null
}

# ============================================================================
# Detect Parent Branch Tests
# ============================================================================

test_detect_parent_branch() {
  echo ""
  echo "=== Testing detect-parent-branch command ==="

  local stdout stderr_file stderr_output exit_code
  local base_out verified_out source_out branch_out

  # --- Case (a): DEFECT 1 fix — parent is the currently checked-out branch,
  #     decorated "HEAD -> <parent>, origin/<parent>" on the first ancestor
  #     commit. Must resolve to the parent, not some further ancestor. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout -b feat/parent >/dev/null 2>&1
  echo "p" > p.txt && git add p.txt && git commit -m "parent work" >/dev/null 2>&1
  git push origin feat/parent >/dev/null 2>&1
  git checkout -b feat/child >/dev/null 2>&1
  echo "c" > c.txt && git add c.txt && git commit -m "child work" >/dev/null 2>&1
  git checkout feat/parent >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/child) && exit_code=0 || exit_code=$?
  branch_out=$(echo "$stdout" | jq -r '.branch')
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (a) checked-out-parent decoration: exit code"
  assert_eq "feat/child" "$branch_out" "detect-parent-branch (a): branch echoed"
  assert_eq "feat/parent" "$base_out" "detect-parent-branch (a): base is the checked-out parent, not a further ancestor"
  assert_eq "true" "$verified_out" "detect-parent-branch (a): verified true"
  assert_eq "decoration" "$source_out" "detect-parent-branch (a): source is decoration"

  popd >/dev/null
  teardown_git_fixture

  # --- Case (b): DEFECT 3 fix — parent branch name (feat/auth-base)
  #     contains the current branch name (feat/auth) as a substring. The old
  #     unanchored grep -v "feat/auth" would have dropped this line. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout -b feat/auth-base >/dev/null 2>&1
  echo "b" > b.txt && git add b.txt && git commit -m "auth base work" >/dev/null 2>&1
  git checkout -b feat/auth >/dev/null 2>&1
  echo "a" > a.txt && git add a.txt && git commit -m "auth work" >/dev/null 2>&1
  git checkout feat/auth-base >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/auth) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (b) substring-alike sibling: exit code"
  assert_eq "feat/auth-base" "$base_out" "detect-parent-branch (b): base survives despite containing branch name as substring"
  assert_eq "true" "$verified_out" "detect-parent-branch (b): verified true"
  assert_eq "decoration" "$source_out" "detect-parent-branch (b): source is decoration"

  popd >/dev/null
  teardown_git_fixture

  # --- Case (c): detached-HEAD decoration — token list is exactly
  #     "HEAD, feat/foo" (bare HEAD token, no arrow). The bare HEAD token
  #     must be skipped and the real branch token used. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout -b feat/foo >/dev/null 2>&1
  echo "f" > f.txt && git add f.txt && git commit -m "foo work" >/dev/null 2>&1
  git checkout -b feat/target >/dev/null 2>&1
  echo "t" > t.txt && git add t.txt && git commit -m "target work" >/dev/null 2>&1
  git checkout "$(git rev-parse feat/foo)" >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/target) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (c) detached-HEAD decoration: exit code"
  assert_eq "feat/foo" "$base_out" "detect-parent-branch (c): bare HEAD token skipped, real branch token used"
  assert_eq "true" "$verified_out" "detect-parent-branch (c): verified true"
  assert_eq "decoration" "$source_out" "detect-parent-branch (c): source is decoration"

  popd >/dev/null
  teardown_git_fixture

  # --- Case (d): own-tip decoration is skipped — target's own tip commit is
  #     decorated "origin/<branch>, <branch>"; both tokens must drop (exact
  #     match, never substring) and the walk continues to the next ancestor
  #     rather than returning the branch as its own parent. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout -b feat/lonely >/dev/null 2>&1
  echo "l" > l.txt && git add l.txt && git commit -m "lonely work" >/dev/null 2>&1
  git push origin feat/lonely >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/lonely) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (d) own-tip decoration skip: exit code"
  assert_eq "main" "$base_out" "detect-parent-branch (d): never returns branch as its own parent -- walk continues to real ancestor"
  assert_eq "true" "$verified_out" "detect-parent-branch (d): verified true"
  assert_eq "decoration" "$source_out" "detect-parent-branch (d): source is decoration"

  popd >/dev/null
  teardown_git_fixture

  # --- Case (e): no-decoration fallback — an orphan branch whose entire
  #     first-parent history has zero non-empty/non-HEAD/non-tag/non-self
  #     decoration tokens anywhere. Must fall back to the default branch,
  #     unverified. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout --orphan feat/no-decoration >/dev/null 2>&1
  echo "o1" > o1.txt && git add o1.txt && git commit -m "orphan commit 1" >/dev/null 2>&1
  echo "o2" > o2.txt && git add o2.txt && git commit -m "orphan commit 2" >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/no-decoration) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (e) no-decoration fallback: exit code"
  assert_eq "main" "$base_out" "detect-parent-branch (e): falls back to the shared default-branch resolution"
  assert_eq "false" "$verified_out" "detect-parent-branch (e): verified false on fallback"
  assert_eq "default-branch" "$source_out" "detect-parent-branch (e): source is default-branch"

  popd >/dev/null
  teardown_git_fixture

  # --- Case (f): merge-base rejection — a decoration token survives
  #     normalization (origin/feat/sibling -> feat/sibling) but a LOCAL
  #     branch of that same normalized name points to an unrelated,
  #     divergent commit not on the target's first-parent lineage.
  #     merge-base must reject it.
  #
  #     WHAT HAPPENS AFTER THE REJECTION CHANGED, AND WHY THIS CASE NOW
  #     EXPECTS decoration/true. The rejected candidate used to end the
  #     search outright -- the verb took the first normalized token, and a
  #     merge-base rejection sent it straight to the default branch,
  #     reporting verified:false because it had genuinely not verified
  #     anything. It now keeps walking, and `main` decorates a real ancestor
  #     of feat/fbranch, so it verifies THAT.
  #
  #     The base is `main` either way -- the load-bearing assertion below is
  #     unchanged. What moved is only the provenance, and it moved toward the
  #     truth: `main` IS a verifiable ancestor here, and the old answer said
  #     "could not verify, using the default" about a branch it could have
  #     verified had it looked. open-pr.md warns whenever verified is not
  #     true, so this stops emitting a warning about a guess it is no longer
  #     making. See _detect_parent_branch_candidate's header for the defect
  #     this fixed and how it was reproduced. ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  git checkout -b feat/sibling >/dev/null 2>&1
  echo "s" > s.txt && git add s.txt && git commit -m "sibling original work" >/dev/null 2>&1
  git push origin feat/sibling >/dev/null 2>&1
  git checkout -b feat/fbranch >/dev/null 2>&1
  echo "fb" > fb.txt && git add fb.txt && git commit -m "fbranch work" >/dev/null 2>&1
  # Delete the local feat/sibling (origin/feat/sibling still decorates the
  # ancestor commit) and recreate it pointing at unrelated, divergent work.
  git branch -D feat/sibling >/dev/null 2>&1
  git checkout main >/dev/null 2>&1
  git checkout -b feat/sibling >/dev/null 2>&1
  echo "unrelated" > unrelated.txt && git add unrelated.txt && git commit -m "unrelated sibling work" >/dev/null 2>&1
  git checkout main >/dev/null 2>&1

  stdout=$("$CLI" detect-parent-branch feat/fbranch) && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  verified_out=$(echo "$stdout" | jq -r '.verified')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch (f) merge-base rejection: exit code"
  assert_eq "main" "$base_out" "detect-parent-branch (f): rejected candidate falls back to default branch"
  assert_eq "true" "$verified_out" "detect-parent-branch (f): verified true -- the walk continues past the rejected candidate and verifies main, rather than reporting an unverified fallback it never attempted"
  assert_eq "decoration" "$source_out" "detect-parent-branch (f): source is decoration -- main was found by walking, not by falling back"

  popd >/dev/null
  teardown_git_fixture

  # --- Error path: invalid branch argument ---
  setup_parent_branch_fixture
  pushd "$GIT_FIXTURE_LOCAL" >/dev/null

  stderr_file=$(mktemp)
  stdout=$("$CLI" detect-parent-branch '../bad' 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_output=$(cat "$stderr_file")
  assert_exit_code "1" "$exit_code" "detect-parent-branch: invalid branch name — exit code"
  assert_stderr_contains "Invalid branch name" "$stderr_output" "detect-parent-branch: invalid branch name — stderr message"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_git_fixture

  # --- Error path: not a git repository ---
  local non_git_dir
  non_git_dir=$(mktemp -d)
  mkdir -p "$non_git_dir/.aimi"

  stderr_file=$(mktemp)
  stdout=$("$CLI" detect-parent-branch feat/test --project "$non_git_dir" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_output=$(cat "$stderr_file")
  assert_exit_code "1" "$exit_code" "detect-parent-branch: not a git repo — exit code"
  assert_stderr_contains "Not a git repository" "$stderr_output" "detect-parent-branch: not a git repo — stderr message"
  rm -f "$stderr_file"
  rm -rf "$non_git_dir"
}

test_detect_parent_branch_per_repo_scoping() {
  echo ""
  echo "=== Testing detect-parent-branch: per-repo default-branch fallback scoping ==="

  local stdout base_out source_out exit_code

  setup_multi_repo_default_branch_fixture
  pushd "$MULTI_REPO_FIXTURE_ROOT" >/dev/null

  # Prime the per-repo cache for repo-a first (resolves main) in the same
  # session, proving repo-b's fallback below doesn't inherit it.
  "$CLI" detect-default-branch --project "$MULTI_REPO_FIXTURE_A" >/dev/null

  # Orphan branch on repo-b with zero decoration candidates anywhere in its
  # --first-parent history forces cmd_detect_parent_branch's fallback at
  # aimi-cli.sh:1815 through the same _resolve_default_branch this story
  # re-keys.
  pushd "$MULTI_REPO_FIXTURE_B" >/dev/null
  git checkout --orphan feat/no-decoration >/dev/null 2>&1
  echo "o1" > o1.txt && git add o1.txt && git commit -m "orphan commit" >/dev/null 2>&1
  popd >/dev/null

  stdout=$("$CLI" detect-parent-branch feat/no-decoration --project "$MULTI_REPO_FIXTURE_B") && exit_code=0 || exit_code=$?
  base_out=$(echo "$stdout" | jq -r '.base')
  source_out=$(echo "$stdout" | jq -r '.source')
  assert_exit_code "0" "$exit_code" "detect-parent-branch per-repo scoping: repo-b fallback -- exit code"
  assert_eq "master" "$base_out" "detect-parent-branch per-repo scoping: repo-b fallback resolves master, not repo-a's cached main"
  assert_eq "default-branch" "$source_out" "detect-parent-branch per-repo scoping: repo-b fallback source is default-branch"

  popd >/dev/null
  teardown_multi_repo_default_branch_fixture
}

# ============================================================================
# Archive Task Tests
# ============================================================================

# Build a project root under mktemp holding a terminal task file, the three
# decoys every archive test needs -- an unlisted sibling research file, a file
# already in .aimi/archive/, and a file outside .aimi/ entirely -- and a
# companion .lock. Echoes the root. Callers rm -rf it.
_archive_fixture() {
  local basename="$1"
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/.aimi/tasks" "$dir/.aimi/research" "$dir/.aimi/archive"
  printf 'decoy: never named in metadata\n' > "$dir/.aimi/research/nao-listado.md"
  printf 'decoy: already in the archive\n' > "$dir/.aimi/archive/ja-arquivado.md"
  printf 'decoy: outside .aimi entirely\n' > "$dir/fora-do-aimi.txt"
  printf '' > "$dir/.aimi/tasks/$basename.lock"
  cat > "$dir/.aimi/tasks/$basename" << 'TASKEOF'
{
  "schemaVersion": "3.3",
  "metadata": {
    "title": "feat: Archive collision",
    "type": "feat",
    "branchName": "feat/archive-collision",
    "maxConcurrency": 1,
    "researchPaths": [".aimi/research/listado.md"]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "status": "completed",
      "dependsOn": []
    }
  ]
}
TASKEOF
  printf 'listado\n' > "$dir/.aimi/research/listado.md"
  echo "$dir"
}

test_archive_task_collision_suffix() {
  echo ""
  echo "=== Testing archive-task: -N collision suffix, and its split on the first dot ==="

  local stdout exit_code archived kept arch_dir

  # A destination that is already taken, with the companion lock taken too.
  arch_dir=$(_archive_fixture "2026-02-01-collide-tasks.json")
  printf 'ja estava aqui\n' > "$arch_dir/.aimi/archive/2026-02-01-collide-tasks.json"
  printf '' > "$arch_dir/.aimi/archive/2026-02-01-collide-tasks.json.lock"

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task .aimi/tasks/2026-02-01-collide-tasks.json 2>/dev/null) \
    && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task collision: exit code"
  archived=$(printf '%s' "$stdout" | jq -r '.archived.task')
  assert_eq "2026-02-01-collide-tasks-2.json" "$(basename "$archived")" \
    "archive-task collision: the task lands on the -2 suffix"

  # The file that was already there keeps its own bytes -- the suffix exists so
  # that an archive is never overwritten.
  kept=$(cat "$arch_dir/.aimi/archive/2026-02-01-collide-tasks.json")
  assert_eq "ja estava aqui" "$kept" "archive-task collision: the occupant is not overwritten"

  # The companion lock is MOVED into the archive rather than left behind, and
  # finds its own free slot independently of the task's.
  local lock_moved="no"
  [ -f "$arch_dir/.aimi/archive/2026-02-01-collide-tasks-2.json.lock" ] && lock_moved="yes"
  assert_eq "yes" "$lock_moved" "archive-task collision: the companion lock moves into the archive"

  local lock_left="yes"
  [ -e "$arch_dir/.aimi/tasks/2026-02-01-collide-tasks.json.lock" ] || lock_left="no"
  assert_eq "no" "$lock_left" "archive-task collision: and nothing is left in .aimi/tasks/"

  rm -rf "$arch_dir"

  # The suffix splits the basename on the FIRST dot, so everything from that
  # dot onward counts as the extension.
  arch_dir=$(_archive_fixture "collide.v2-tasks.json")
  printf 'ja estava aqui\n' > "$arch_dir/.aimi/archive/collide.v2-tasks.json"

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task .aimi/tasks/collide.v2-tasks.json 2>/dev/null) \
    && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task collision (early dot): exit code"
  archived=$(printf '%s' "$stdout" | jq -r '.archived.task')
  assert_eq "collide-2.v2-tasks.json" "$(basename "$archived")" \
    "archive-task collision (early dot): the suffix goes before the FIRST dot"

  rm -rf "$arch_dir"
}

test_archive_task_survivors() {
  echo ""
  echo "=== Testing archive-task: what SURVIVES, as a set rather than a spot check ==="

  local stdout exit_code research_cleaned survivors arch_dir

  arch_dir=$(_archive_fixture "2026-02-02-survivors-tasks.json")

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task .aimi/tasks/2026-02-02-survivors-tasks.json 2>/dev/null) \
    && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task survivors: exit code"

  research_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.researchCleaned')
  assert_eq "1" "$research_cleaned" \
    "archive-task survivors: only the file metadata named is counted"

  # Set equality, decoys included. A delete that reached one directory too far
  # would show up here and nowhere else in this file.
  survivors=$(cd "$arch_dir" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
  assert_eq ".aimi .aimi/archive .aimi/archive/2026-02-02-survivors-tasks.json \
.aimi/archive/2026-02-02-survivors-tasks.json.lock .aimi/archive/ja-arquivado.md \
.aimi/research .aimi/research/nao-listado.md .aimi/tasks fora-do-aimi.txt " \
    "$survivors" "archive-task survivors: the exact surviving tree"

  rm -rf "$arch_dir"
}

test_archive_task_with_research_paths() {
  echo ""
  echo "=== Testing archive-task: deletes research files and reports count ==="

  local stdout exit_code research_cleaned

  # Create a dedicated temp dir for this test (needs its own .aimi/)
  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks" "$arch_dir/.aimi/research"

  # Create two research files
  local r1="$arch_dir/.aimi/research/research-us001.md"
  local r2="$arch_dir/.aimi/research/research-us002.md"
  printf 'research 1' > "$r1"
  printf 'research 2' > "$r2"

  # Create a task file with all stories completed and researchPaths
  local task_file="$arch_dir/.aimi/tasks/2026-01-01-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test",
    "type": "feat",
    "branchName": "feat/archive-test",
    "createdAt": "2026-01-01",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "researchPaths": [
      ".aimi/research/research-us001.md",
      ".aimi/research/research-us002.md"
    ]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task with researchPaths: exit code"

  research_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.researchCleaned')
  assert_eq "2" "$research_cleaned" "archive-task with researchPaths: researchCleaned count"

  # Research files must be gone
  local r1_exists="no" r2_exists="no"
  [ -e "$r1" ] && r1_exists="yes"
  [ -e "$r2" ] && r2_exists="yes"
  assert_eq "no" "$r1_exists" "archive-task with researchPaths: research file 1 deleted"
  assert_eq "no" "$r2_exists" "archive-task with researchPaths: research file 2 deleted"

  rm -rf "$arch_dir"
}

test_archive_task_without_research_paths() {
  echo ""
  echo "=== Testing archive-task: no researchPaths produces researchCleaned 0 ==="

  local stdout exit_code research_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks"

  local task_file="$arch_dir/.aimi/tasks/2026-01-02-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test no research",
    "type": "feat",
    "branchName": "feat/archive-no-research",
    "createdAt": "2026-01-02",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task without researchPaths: exit code"

  research_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.researchCleaned')
  assert_eq "0" "$research_cleaned" "archive-task without researchPaths: researchCleaned is 0"

  rm -rf "$arch_dir"
}

test_archive_task_missing_research_files() {
  echo ""
  echo "=== Testing archive-task: missing research files skipped silently ==="

  local stdout exit_code research_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks" "$arch_dir/.aimi/research"

  # Create only one of the two research files referenced
  local r1="$arch_dir/.aimi/research/research-exists.md"
  printf 'exists' > "$r1"
  # research-missing.md intentionally NOT created

  local task_file="$arch_dir/.aimi/tasks/2026-01-03-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test missing research",
    "type": "feat",
    "branchName": "feat/archive-missing-research",
    "createdAt": "2026-01-03",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "researchPaths": [
      ".aimi/research/research-exists.md",
      ".aimi/research/research-missing.md"
    ]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task missing research files: exit code"

  # Only the existing file is counted
  research_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.researchCleaned')
  assert_eq "1" "$research_cleaned" "archive-task missing research files: researchCleaned counts only existing"

  # The existing file must be gone
  local r1_exists="no"
  [ -e "$r1" ] && r1_exists="yes"
  assert_eq "no" "$r1_exists" "archive-task missing research files: existing file deleted"

  rm -rf "$arch_dir"
}

test_archive_task_with_prototype_paths() {
  echo ""
  echo "=== Testing archive-task: deletes prototype files and reports count ==="

  local stdout exit_code prototype_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks" "$arch_dir/.aimi/brainstorms/prototypes"

  # Create two prototype files
  local p1="$arch_dir/.aimi/brainstorms/prototypes/prototype-us001.html"
  local p2="$arch_dir/.aimi/brainstorms/prototypes/prototype-us002.html"
  printf '<html>prototype 1</html>' > "$p1"
  printf '<html>prototype 2</html>' > "$p2"

  local task_file="$arch_dir/.aimi/tasks/2026-01-04-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test prototypes",
    "type": "feat",
    "branchName": "feat/archive-prototype-test",
    "createdAt": "2026-01-04",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "prototypePaths": [
      ".aimi/brainstorms/prototypes/prototype-us001.html",
      ".aimi/brainstorms/prototypes/prototype-us002.html"
    ]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task with prototypePaths: exit code"

  prototype_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.prototypeCleaned')
  assert_eq "2" "$prototype_cleaned" "archive-task with prototypePaths: prototypeCleaned count"

  # Prototype files must be gone
  local p1_exists="no" p2_exists="no"
  [ -e "$p1" ] && p1_exists="yes"
  [ -e "$p2" ] && p2_exists="yes"
  assert_eq "no" "$p1_exists" "archive-task with prototypePaths: prototype file 1 deleted"
  assert_eq "no" "$p2_exists" "archive-task with prototypePaths: prototype file 2 deleted"

  rm -rf "$arch_dir"
}

test_archive_task_without_prototype_paths() {
  echo ""
  echo "=== Testing archive-task: no prototypePaths produces prototypeCleaned 0 ==="

  local stdout exit_code prototype_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks"

  local task_file="$arch_dir/.aimi/tasks/2026-01-05-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test no prototypes",
    "type": "feat",
    "branchName": "feat/archive-no-prototype",
    "createdAt": "2026-01-05",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task without prototypePaths: exit code"

  prototype_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.prototypeCleaned')
  assert_eq "0" "$prototype_cleaned" "archive-task without prototypePaths: prototypeCleaned is 0"

  rm -rf "$arch_dir"
}

test_archive_task_missing_prototype_files() {
  echo ""
  echo "=== Testing archive-task: missing prototype files skipped silently ==="

  local stdout exit_code prototype_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks" "$arch_dir/.aimi/brainstorms/prototypes"

  # Create only one of the two prototype files referenced
  local p1="$arch_dir/.aimi/brainstorms/prototypes/prototype-exists.html"
  printf '<html>exists</html>' > "$p1"
  # prototype-missing.html intentionally NOT created

  local task_file="$arch_dir/.aimi/tasks/2026-01-06-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test missing prototypes",
    "type": "feat",
    "branchName": "feat/archive-missing-prototype",
    "createdAt": "2026-01-06",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "prototypePaths": [
      ".aimi/brainstorms/prototypes/prototype-exists.html",
      ".aimi/brainstorms/prototypes/prototype-missing.html"
    ]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task missing prototype files: exit code"

  # Only the existing file is counted
  prototype_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.prototypeCleaned')
  assert_eq "1" "$prototype_cleaned" "archive-task missing prototype files: prototypeCleaned counts only existing"

  # The existing file must be gone
  local p1_exists="no"
  [ -e "$p1" ] && p1_exists="yes"
  assert_eq "no" "$p1_exists" "archive-task missing prototype files: existing file deleted"

  rm -rf "$arch_dir"
}

test_archive_task_both_research_and_prototype_paths() {
  echo ""
  echo "=== Testing archive-task: both researchPaths and prototypePaths cleaned correctly ==="

  local stdout exit_code research_cleaned prototype_cleaned

  local arch_dir
  arch_dir=$(mktemp -d)
  mkdir -p "$arch_dir/.aimi/tasks" "$arch_dir/.aimi/research" "$arch_dir/.aimi/brainstorms/prototypes"

  # Create research files
  local r1="$arch_dir/.aimi/research/research-combined.md"
  printf 'research combined' > "$r1"

  # Create prototype files
  local p1="$arch_dir/.aimi/brainstorms/prototypes/prototype-combined.html"
  local p2="$arch_dir/.aimi/brainstorms/prototypes/tokens-combined.json"
  printf '<html>prototype combined</html>' > "$p1"
  printf '{"tokens": true}' > "$p2"

  local task_file="$arch_dir/.aimi/tasks/2026-01-07-test-archive-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "feat: Archive test both paths",
    "type": "feat",
    "branchName": "feat/archive-both-paths",
    "createdAt": "2026-01-07",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "researchPaths": [
      ".aimi/research/research-combined.md"
    ],
    "prototypePaths": [
      ".aimi/brainstorms/prototypes/prototype-combined.html",
      ".aimi/brainstorms/prototypes/tokens-combined.json"
    ]
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Done story",
      "description": "Completed",
      "acceptanceCriteria": ["Done"],
      "priority": 1,
      "status": "completed",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
TASKEOF

  pushd "$arch_dir" >/dev/null
  stdout=$("$CLI" archive-task "$task_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "archive-task both paths: exit code"

  research_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.researchCleaned')
  assert_eq "1" "$research_cleaned" "archive-task both paths: researchCleaned count"

  prototype_cleaned=$(printf '%s' "$stdout" | jq -r '.archived.prototypeCleaned')
  assert_eq "2" "$prototype_cleaned" "archive-task both paths: prototypeCleaned count"

  # All files must be gone
  local r1_exists="no" p1_exists="no" p2_exists="no"
  [ -e "$r1" ] && r1_exists="yes"
  [ -e "$p1" ] && p1_exists="yes"
  [ -e "$p2" ] && p2_exists="yes"
  assert_eq "no" "$r1_exists" "archive-task both paths: research file deleted"
  assert_eq "no" "$p1_exists" "archive-task both paths: prototype file 1 deleted"
  assert_eq "no" "$p2_exists" "archive-task both paths: prototype file 2 deleted"

  rm -rf "$arch_dir"
}

test_research_lookup() {
  echo ""
  echo "=== Testing research-lookup subcommand ==="

  local rl_dir
  rl_dir=$(mktemp -d)
  mkdir -p "$rl_dir/.aimi" "$rl_dir/src"

  # Create two source files
  local src1="$rl_dir/src/foo.sh"
  local src2="$rl_dir/src/bar.sh"
  printf 'echo foo\n' > "$src1"
  printf 'echo bar\n' > "$src2"

  # Create a research file citing those source paths
  local research_file="$rl_dir/.aimi/research.md"
  cat > "$research_file" << 'RESEOF'
# My Research

## Summary
Some summary text.

## File References
- src/foo.sh
- src/bar.sh

## Open Questions
None.
RESEOF

  # --- Test 1: fresh (research file written after source files) ---
  # Set source files to a known old time, research file to a newer time
  touch -t 202001010000.00 "$src1" "$src2"
  touch -t 202001020000.00 "$research_file"

  local stdout exit_code
  pushd "$rl_dir" >/dev/null
  stdout=$("$CLI" research-lookup "$research_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "research-lookup: fresh file exits 0"
  assert_contains ".aimi/research.md" "$stdout" "research-lookup: fresh file prints research path"

  # --- Test 2: stale (source file newer than research) ---
  # Set source file to a newer time than the research file
  touch -t 202001030000.00 "$src1"

  pushd "$rl_dir" >/dev/null
  stdout=$("$CLI" research-lookup "$research_file" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: stale (source newer) exits 1"
  assert_eq "" "$stdout" "research-lookup: stale produces empty stdout"

  # Restore research file freshness for next tests
  touch -t 202001040000.00 "$research_file"

  # --- Test 3: missing cited path -> stale ---
  local research_missing="$rl_dir/.aimi/research-missing.md"
  cat > "$research_missing" << 'RESEOF'
## File References
- src/foo.sh
- src/does-not-exist.sh
RESEOF
  touch -t 202001040000.00 "$research_missing"

  local stderr_out
  pushd "$rl_dir" >/dev/null
  stderr_out=$("$CLI" research-lookup "$research_missing" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: missing cited path exits 1 (stale)"
  assert_contains "does-not-exist.sh" "$stderr_out" "research-lookup: missing cited path logs warning"

  # --- Test 3a: --ignore-missing-cited-paths on missing cited path -> exit 0 (not stale) ---
  # research_missing already set up above: cites src/foo.sh (exists) and src/does-not-exist.sh (missing)
  # research_missing mtime is 2020-01-04, src/foo.sh mtime is 2020-01-01 (older) -> fresh aside from missing path
  # Reset src1 back to old time in case Test 2 changed it
  touch -t 202001010000.00 "$src1"
  local stderr_3a
  pushd "$rl_dir" >/dev/null
  stderr_3a=$("$CLI" research-lookup --ignore-missing-cited-paths "$research_missing" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "research-lookup: --ignore-missing-cited-paths on missing path exits 0 (not stale)"
  assert_contains "does-not-exist.sh" "$stderr_3a" "research-lookup: --ignore-missing-cited-paths still logs warning for missing path"

  # --- Test 3b: --ignore-missing-cited-paths does NOT suppress mtime staleness ---
  # Make src/foo.sh newer than research_missing so mtime check fails
  touch -t 202001050000.00 "$src1"
  local stderr_3b
  pushd "$rl_dir" >/dev/null
  stderr_3b=$("$CLI" research-lookup --ignore-missing-cited-paths "$research_missing" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: --ignore-missing-cited-paths still exits 1 when mtime stale"

  # Restore src1 to original time for subsequent tests
  touch -t 202001010000.00 "$src1"

  # --- Test 4: no File References section -> stale ---
  local research_norefs="$rl_dir/.aimi/research-norefs.md"
  cat > "$research_norefs" << 'RESEOF'
# Research Without File References

## Summary
No file refs here.
RESEOF

  pushd "$rl_dir" >/dev/null
  stdout=$("$CLI" research-lookup "$research_norefs" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: no File References section exits 1"
  assert_eq "" "$stdout" "research-lookup: no File References section produces empty stdout"

  # --- Test 5: path outside project root -> rejected ---
  local research_escape="$rl_dir/.aimi/research-escape.md"
  cat > "$research_escape" << 'RESEOF'
## File References
- ../../etc/passwd
RESEOF

  pushd "$rl_dir" >/dev/null
  stderr_out=$("$CLI" research-lookup "$research_escape" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: outside-root path rejected (exit 1)"
  assert_contains "escapes project root" "$stderr_out" "research-lookup: outside-root path error on stderr"

  # --- Test 6: missing argument -> usage on stderr, exit 1 ---
  pushd "$rl_dir" >/dev/null
  stderr_out=$("$CLI" research-lookup 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "research-lookup: missing arg exits 1"
  assert_contains "Usage:" "$stderr_out" "research-lookup: missing arg shows usage on stderr"

  rm -rf "$rl_dir"
}

test_extract_sections() {
  echo ""
  echo "=== Testing extract-sections subcommand ==="

  local es_dir
  es_dir=$(mktemp -d)
  mkdir -p "$es_dir/.aimi"

  local research_file="$es_dir/.aimi/research.md"
  cat > "$research_file" << 'RESEOF'
# My Research

## Repository Research Summary
Top-level summary text.
More summary detail.

## File References
- src/foo.sh

### Nested Detail
Nested h3 content under File References.

## Open Questions
- Q1
- Q2

## Testing, Linting, and CI
Comma heading body line.

## Fenced Section
Intro line before fence.

```bash
# This looks like a heading but is inside a fence
echo "still in section"
```

Content after the fence, still part of the same section.
RESEOF

  local stdout exit_code

  # --- Test 1: single-anchor match ---
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "Open Questions" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: single anchor exits 0"
  assert_contains "## Open Questions" "$stdout" "extract-sections: single anchor includes heading"
  assert_contains "- Q1" "$stdout" "extract-sections: single anchor includes body"
  local single_bleed="yes"
  [[ "$stdout" == *"Repository Research Summary"* ]] || single_bleed="no"
  assert_eq "no" "$single_bleed" "extract-sections: single anchor excludes unrelated sections"

  # --- Test 2: multi-anchor match, concatenated in request order ---
  # Anchors are newline-separated (not comma-separated -- commas are valid heading
  # punctuation, see Test 8 below).
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "$(printf 'Open Questions\nRepository Research Summary')" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: multi-anchor exits 0"
  local oq_pos summary_pos
  oq_pos=$(printf '%s' "$stdout" | grep -n '^## Open Questions' | head -1 | cut -d: -f1)
  summary_pos=$(printf '%s' "$stdout" | grep -n '^## Repository Research Summary' | head -1 | cut -d: -f1)
  assert_contains "## Open Questions" "$stdout" "extract-sections: multi-anchor includes first requested section"
  assert_contains "## Repository Research Summary" "$stdout" "extract-sections: multi-anchor includes second requested section"
  local order_ok="no"
  [ -n "$oq_pos" ] && [ -n "$summary_pos" ] && [ "$oq_pos" -lt "$summary_pos" ] && order_ok="yes"
  assert_eq "yes" "$order_ok" "extract-sections: multi-anchor preserves request order"

  # --- Test 3: anchor not found -> skipped, empty output, exit 0 ---
  local stderr_out
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "Nonexistent Heading" 2>"$es_dir/.aimi/stderr3.out") && exit_code=0 || exit_code=$?
  popd >/dev/null
  stderr_out=$(cat "$es_dir/.aimi/stderr3.out"); rm -f "$es_dir/.aimi/stderr3.out"

  assert_exit_code "0" "$exit_code" "extract-sections: anchor not found exits 0"
  assert_eq "" "$stdout" "extract-sections: anchor not found produces empty stdout"
  assert_contains "no section matched anchor: Nonexistent Heading" "$stderr_out" "extract-sections: anchor not found warns on stderr naming the anchor"

  # --- Test 4: missing file -> error on stderr, exit non-zero ---
  pushd "$es_dir" >/dev/null
  stderr_out=$("$CLI" extract-sections "$es_dir/.aimi/does-not-exist.md" --anchors "X" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "extract-sections: missing file exits non-zero"
  assert_contains "not found" "$stderr_out" "extract-sections: missing file logs error on stderr"

  # --- Test 5: traversal path (../x) rejected ---
  local parent_dir="$(dirname "$es_dir")"
  local outside_file="$parent_dir/es-outside-$$.md"
  cat > "$outside_file" << 'RESEOF'
## Outside Section
Outside content.
RESEOF

  pushd "$es_dir" >/dev/null
  stderr_out=$("$CLI" extract-sections "../$(basename "$outside_file")" --anchors "Outside Section" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "extract-sections: traversal path rejected (exit non-zero)"
  assert_contains "escapes project root" "$stderr_out" "extract-sections: traversal path error on stderr"
  rm -f "$outside_file"

  # --- Test 6: heading-boundary correctness ---
  # h2 anchor: includes nested h3 (Nested Detail), stops before the next h2 (Open Questions)
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "File References" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: h2-boundary anchor exits 0"
  assert_contains "## File References" "$stdout" "extract-sections: h2 anchor includes its own heading"
  assert_contains "### Nested Detail" "$stdout" "extract-sections: h2 anchor includes nested h3"
  local h2_bleed="yes"
  [[ "$stdout" == *"Open Questions"* ]] || h2_bleed="no"
  assert_eq "no" "$h2_bleed" "extract-sections: h2 anchor stops before the next h2"

  # h3 anchor: returns only that subsection, not the parent h2's other content
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "Nested Detail" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: h3 anchor exits 0"
  assert_contains "### Nested Detail" "$stdout" "extract-sections: h3 anchor includes its own heading"
  assert_contains "Nested h3 content" "$stdout" "extract-sections: h3 anchor includes its body"
  local h3_bleed="yes"
  [[ "$stdout" == *"src/foo.sh"* ]] || h3_bleed="no"
  assert_eq "no" "$h3_bleed" "extract-sections: h3 anchor excludes the parent h2's other content"

  # --- Test 7: case-insensitive anchor matching ---
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "open questions" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: case-insensitive anchor exits 0"
  assert_contains "## Open Questions" "$stdout" "extract-sections: case-insensitive anchor matches heading"

  # --- Test 8: fence-aware heading detection (FIX 2 regression) ---
  # A '#' comment inside a fenced code block must NOT be parsed as a heading -- the
  # bug closed the section early and emitted an unterminated fence.
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "Fenced Section" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: fenced section exits 0"
  assert_contains "## Fenced Section" "$stdout" "extract-sections: fenced section includes its own heading"
  assert_contains "# This looks like a heading but is inside a fence" "$stdout" "extract-sections: fenced section includes the in-fence comment line verbatim"
  assert_contains "Content after the fence, still part of the same section." "$stdout" "extract-sections: fenced section survives past the in-fence comment"
  local fence_marker_count
  fence_marker_count=$(printf '%s\n' "$stdout" | grep -c '^```')
  assert_eq "2" "$fence_marker_count" "extract-sections: fenced section emits a balanced open+close fence, not an unterminated one"

  # --- Test 9: heading containing commas matches and returns its content (FIX 3) ---
  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "Testing, Linting, and CI" 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "extract-sections: comma-containing heading exits 0"
  assert_contains "## Testing, Linting, and CI" "$stdout" "extract-sections: comma-containing heading matches its full text as a single anchor"
  assert_contains "Comma heading body line." "$stdout" "extract-sections: comma-containing heading includes its body"

  # --- Test 10: anchors with shell metacharacters are rejected; other anchors in the
  # same run still process (FIX 1 regression) ---
  local metachar_anchors metachar_stderr_file
  metachar_anchors=$(printf 'Open Questions\n$(evil)\nbad`tick\nbad"quote\nbad\\slash')
  metachar_stderr_file="$es_dir/.aimi/stderr10.out"

  pushd "$es_dir" >/dev/null
  stdout=$("$CLI" extract-sections "$research_file" --anchors "$metachar_anchors" 2>"$metachar_stderr_file") && exit_code=0 || exit_code=$?
  popd >/dev/null
  stderr_out=$(cat "$metachar_stderr_file"); rm -f "$metachar_stderr_file"

  assert_exit_code "0" "$exit_code" "extract-sections: run with rejected metachar anchors still exits 0"
  assert_contains "## Open Questions" "$stdout" "extract-sections: valid anchor still processed alongside rejected ones"
  local rejected_count
  rejected_count=$(printf '%s' "$stderr_out" | grep -c "anchor rejected (shell metacharacter)")
  assert_eq "4" "$rejected_count" "extract-sections: all four dangerous-metacharacter anchors rejected with a warning"
  assert_contains '$(evil)' "$stderr_out" "extract-sections: rejected-anchor warning names the \$( anchor"
  assert_contains 'bad`tick' "$stderr_out" "extract-sections: rejected-anchor warning names the backtick anchor"
  assert_contains 'bad"quote' "$stderr_out" "extract-sections: rejected-anchor warning names the double-quote anchor"
  assert_contains 'bad\slash' "$stderr_out" "extract-sections: rejected-anchor warning names the backslash anchor"

  # --- Test 11: absolute path outside project root rejected ---
  local abs_outside_file="$parent_dir/es-abs-outside-$$.md"
  cat > "$abs_outside_file" << 'RESEOF'
## Abs Outside Section
Abs outside content.
RESEOF

  pushd "$es_dir" >/dev/null
  stderr_out=$("$CLI" extract-sections "$abs_outside_file" --anchors "Abs Outside Section" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "extract-sections: absolute path outside project root rejected (exit non-zero)"
  assert_contains "escapes project root" "$stderr_out" "extract-sections: absolute path outside project root error on stderr"
  rm -f "$abs_outside_file"

  # --- Test 12: symlink inside the project pointing outside is rejected ---
  local symlink_target="$parent_dir/es-symlink-target-$$.md"
  cat > "$symlink_target" << 'RESEOF'
## Symlink Target Section
Symlink target content.
RESEOF
  local symlink_path="$es_dir/.aimi/escape-link.md"
  ln -s "$symlink_target" "$symlink_path"

  pushd "$es_dir" >/dev/null
  stderr_out=$("$CLI" extract-sections "$symlink_path" --anchors "Symlink Target Section" 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "1" "$exit_code" "extract-sections: symlink inside project pointing outside rejected (exit non-zero)"
  assert_contains "escapes project root" "$stderr_out" "extract-sections: symlink escape error on stderr"
  rm -f "$symlink_target" "$symlink_path"

  rm -rf "$es_dir"
}

# The archivable predicate and research-gc's referenced-set walk, whose jq left
# aimi-cli.sh in the same commit.
#
# Static half: retargeted greps, aimi-cli.sh for the deleted programs and
# tasks.py for what replaced them, -F because the deleted text is jq source.
# The bash FUNCTION _archivable_file_is_terminal survives -- only its two jq
# calls went -- so it is asserted present rather than absent.
#
# Behavioural half covers the predicate's two properties a corpus replay would
# not make obvious to a reader: it NEVER speaks and never aborts, and it still
# disagrees with archive-task about an empty document. That disagreement is
# deliberate and pinned from both sides in golden_from_jq.json; story 09 moves
# list-archivable and must consume this predicate rather than re-derive its
# non-empty clause, or the disagreement reconciles by accident.
test_archivable_predicate_and_research_walk_crossed() {
  echo ""
  echo "=== Testing tasks.py boundary: the archivable predicate and research-gc ==="

  local tasks_py
  tasks_py="$(dirname "$CLI")/tasks.py"

  assert_eq "0" \
    "$(grep -cF 'select(.status != "completed" and .status != "skipped")' "$CLI" || true)" \
    "archivable: no jq copy of the non-terminal count survives in aimi-cli.sh"
  assert_eq "0" "$(grep -cF "jq '.userStories | length'" "$CLI" || true)" \
    "archivable: no jq copy of the total count survives in aimi-cli.sh"
  assert_eq "0" "$(grep -cF '.metadata.researchPaths[]?' "$CLI" || true)" \
    "research-gc: no jq read of researchPaths survives in aimi-cli.sh"
  assert_eq "1" "$(grep -c '^def op_archivable_file_is_terminal(' "$tasks_py" || true)" \
    "archivable: exactly one op_archivable_file_is_terminal definition in tasks.py"
  assert_eq "1" "$(grep -c '^def research_path_lines(' "$tasks_py" || true)" \
    "research-gc: exactly one research_path_lines definition in tasks.py"
  assert_eq "1" "$(grep -c '^_archivable_file_is_terminal()' "$CLI" || true)" \
    "archivable: the bash predicate stays -- only the two jq programs inside it went"

  local pred_dir
  pred_dir=$(mktemp -d)
  mkdir -p "$pred_dir/.aimi/tasks"

  # (a) every story terminal, and non-empty: listed
  cat > "$pred_dir/.aimi/tasks/2020-01-01-terminal-tasks.json" << 'TERMEOF'
{"schemaVersion":"3.3","metadata":{"branchName":"feat/t"},
 "userStories":[{"id":"US-001","status":"completed"},{"id":"US-002","status":"skipped"}]}
TERMEOF
  local output
  output=$(cd "$pred_dir" && "$CLI" list-archivable)
  assert_eq "1" "$(printf '%s' "$output" | jq 'length')" \
    "list-archivable: an all-terminal file is listed"
  rm -f "$pred_dir/.aimi/tasks/2020-01-01-terminal-tasks.json"

  # (b) userStories: [] -- REFUSED here, while archive-task archives the same
  # document. One rule, two implementations, disagreeing on purpose.
  printf '%s\n' '{"schemaVersion":"3.3","metadata":{"branchName":"feat/t"},"userStories":[]}' \
    > "$pred_dir/.aimi/tasks/2020-01-02-vazio-tasks.json"
  output=$(cd "$pred_dir" && "$CLI" list-archivable)
  assert_eq "[]" "$output" \
    "list-archivable: an empty userStories is NOT archivable (archive-task disagrees, on purpose)"
  rm -f "$pred_dir/.aimi/tasks/2020-01-02-vazio-tasks.json"

  # (c) a document the predicate cannot read: not archivable, and SILENT. Its
  # whole contract is that it echoes nothing and never takes the command down.
  printf 'NOT JSON AT ALL\n' > "$pred_dir/.aimi/tasks/2020-01-03-mal-tasks.json"
  local stderr_file exit_code=0
  stderr_file=$(mktemp)
  output=$(cd "$pred_dir" && "$CLI" list-archivable 2>"$stderr_file") || exit_code=$?
  assert_exit_code "0" "$exit_code" \
    "list-archivable: a malformed tasks file does not take the command down"
  assert_eq "[]" "$output" "list-archivable: a malformed tasks file is not archivable"
  assert_eq "" "$(cat "$stderr_file")" \
    "list-archivable: the predicate says nothing about a document it cannot read"

  rm -rf "$pred_dir" "$stderr_file"
}

# The list-archivable half of the xargs empty-input defect
# (_find_tasks_files_all, aimi-cli.sh). An empty .aimi/tasks/ plus a decoy
# file in the project root makes _find_tasks_files_all return the decoy
# instead of nothing. Today that bogus path lands in cmd_list_archivable's
# nested_files branch (its dirname is not TASKS_DIR), _archivable_file_is_terminal
# fails to parse it as JSON, the failure is swallowed by the predicate's own
# silent contract (case (c) above), and the file is excluded -- so
# list-archivable already answers [] here, by accident rather than by
# design. This test pins that externally observed [] answer so the fix
# (which removes the underlying bogus candidate) does not change it.
test_list_archivable_empty_dir_with_decoy() {
  echo ""
  echo "=== Testing list-archivable: empty tasks dir with a project-root decoy ==="

  local d; d=$(mktemp -d)
  mkdir -p "$d/.aimi/tasks"
  echo "not a tasks file" > "$d/DECOY.md"

  local stderr_file exit_code=0 output
  stderr_file=$(mktemp)
  output=$(cd "$d" && "$CLI" list-archivable 2>"$stderr_file") || exit_code=$?

  assert_exit_code "0" "$exit_code" "list-archivable: empty dir with decoy does not take the command down"
  assert_eq "[]" "$output" "list-archivable: empty dir with decoy still answers []"
  assert_eq "" "$(cat "$stderr_file")" "list-archivable: empty dir with decoy — empty stderr"

  rm -rf "$d" "$stderr_file"
}

test_research_gc() {
  echo ""
  echo "=== Testing research-gc subcommand ==="

  local gc_dir
  gc_dir=$(mktemp -d)
  mkdir -p "$gc_dir/.aimi/research" "$gc_dir/.aimi/tasks" "$gc_dir/.aimi/brainstorms" "$gc_dir/.aimi/archive"

  # --- Setup: fixed timestamps ---
  # old_time: >30 days ago (2020-01-01)
  # recent_time: <30 days ago (use a far-future date to guarantee "recent")
  local old_time="202001010000.00"
  local recent_time="209901010000.00"

  # Research files
  local orphan_old="$gc_dir/.aimi/research/orphan-old.md"
  local orphan_recent="$gc_dir/.aimi/research/orphan-recent.md"
  local ref_by_task="$gc_dir/.aimi/research/ref-by-task.md"
  local ref_by_brainstorm="$gc_dir/.aimi/research/ref-by-brainstorm.md"
  local ref_by_archive="$gc_dir/.aimi/research/ref-by-archive.md"
  local ref_by_foundation_path="$gc_dir/.aimi/research/ref-by-foundation-path-foundation.md"
  local orphan_foundation_named="$gc_dir/.aimi/research/unreferenced-foundation.md"
  local ref_by_quoted="$gc_dir/.aimi/research/ref-by-quoted-foundation.md"
  local ref_by_comment="$gc_dir/.aimi/research/ref-by-comment-foundation.md"
  local ref_by_prekey="$gc_dir/.aimi/research/ref-by-prekey-foundation.md"
  local ref_by_postlist="$gc_dir/.aimi/research/ref-by-postlist.md"

  printf '# Orphan old\n' > "$orphan_old"
  printf '# Orphan recent\n' > "$orphan_recent"
  printf '# Referenced by task\n' > "$ref_by_task"
  printf '# Referenced by brainstorm\n' > "$ref_by_brainstorm"
  printf '# Referenced by archive (ignored)\n' > "$ref_by_archive"
  printf '# Referenced only via foundationProposalPath\n' > "$ref_by_foundation_path"
  printf '# Unreferenced but foundation-named\n' > "$orphan_foundation_named"
  printf '# Referenced via double-quoted foundationProposalPath\n' > "$ref_by_quoted"
  printf '# Referenced via single-quoted foundationProposalPath with trailing comment\n' > "$ref_by_comment"
  printf '# Referenced via foundationProposalPath placed BEFORE researchPaths\n' > "$ref_by_prekey"
  printf '# Referenced via researchPaths list that FOLLOWS the scalar key\n' > "$ref_by_postlist"

  # Set mtimes: all old except orphan_recent
  touch -t "$old_time" "$orphan_old" "$ref_by_task" "$ref_by_brainstorm" "$ref_by_archive" \
    "$ref_by_foundation_path" "$orphan_foundation_named" \
    "$ref_by_quoted" "$ref_by_comment" "$ref_by_prekey" "$ref_by_postlist"
  touch -t "$recent_time" "$orphan_recent"

  # Active task file referencing ref_by_task
  local task_file="$gc_dir/.aimi/tasks/2020-01-01-gc-test-tasks.json"
  cat > "$task_file" << 'TASKEOF'
{
  "schemaVersion": "3.3",
  "metadata": {
    "title": "feat: GC test",
    "type": "feat",
    "branchName": "feat/gc-test",
    "createdAt": "2020-01-01",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "researchPaths": [
      ".aimi/research/ref-by-task.md"
    ]
  },
  "userStories": []
}
TASKEOF

  # Brainstorm file with frontmatter referencing ref_by_brainstorm via researchPaths:
  # (a list) and ref_by_foundation_path via foundationProposalPath: (a scalar),
  # with the scalar positioned AFTER the list to exercise the key-ordering
  # interaction: encountering foundationProposalPath: must exit the in-progress
  # researchPaths: list scan rather than being misread as a list item.
  local brainstorm_file="$gc_dir/.aimi/brainstorms/2020-01-01-gc-brainstorm.md"
  cat > "$brainstorm_file" << 'BSEOF'
---
researchPaths:
  - .aimi/research/ref-by-brainstorm.md
foundationProposalPath: .aimi/research/ref-by-foundation-path-foundation.md
---

# GC test brainstorm
BSEOF

  # Second brainstorm: YAML double-quoted scalar value. The quotes must be
  # stripped during extraction or the referenced-set match fails and the LIVE
  # artifact gets deleted (the data-loss regression found in review).
  cat > "$gc_dir/.aimi/brainstorms/2020-01-02-gc-quoted.md" << 'BSEOF'
---
topic: gc-quoted
foundationProposalPath: ".aimi/research/ref-by-quoted-foundation.md"
---

# GC quoted-value brainstorm
BSEOF

  # Third brainstorm: single-quoted scalar WITH a trailing comment. Both the
  # quotes and the " #..." tail must be stripped for the match to hold.
  cat > "$gc_dir/.aimi/brainstorms/2020-01-03-gc-comment.md" << 'BSEOF'
---
topic: gc-comment
foundationProposalPath: '.aimi/research/ref-by-comment-foundation.md' # authored by Phase 3.7
---

# GC comment-value brainstorm
BSEOF

  # Fourth brainstorm: foundationProposalPath BEFORE researchPaths — the
  # opposite ordering from the first brainstorm above. Both keys must still be
  # extracted (the scalar must not swallow the list that follows it).
  cat > "$gc_dir/.aimi/brainstorms/2020-01-04-gc-prekey.md" << 'BSEOF'
---
topic: gc-prekey
foundationProposalPath: .aimi/research/ref-by-prekey-foundation.md
researchPaths:
  - .aimi/research/ref-by-postlist.md
---

# GC prekey-ordering brainstorm
BSEOF

  # Archive task referencing ref_by_archive (should be IGNORED)
  # We put this in .aimi/archive — GC must not read it
  mkdir -p "$gc_dir/.aimi/archive"
  cat > "$gc_dir/.aimi/archive/2020-01-01-archived-tasks.json" << 'ARCHEOF'
{
  "schemaVersion": "3.3",
  "metadata": {
    "title": "feat: Archived",
    "type": "feat",
    "branchName": "feat/archived",
    "createdAt": "2020-01-01",
    "planPath": null,
    "brainstormPath": null,
    "maxConcurrency": 1,
    "researchPaths": [
      ".aimi/research/ref-by-archive.md"
    ]
  },
  "userStories": []
}
ARCHEOF

  # Run research-gc from gc_dir
  local stdout exit_code
  pushd "$gc_dir" >/dev/null
  stdout=$("$CLI" research-gc 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "research-gc: exits 0"

  # --- Case 1: orphan >30d should be deleted ---
  local orphan_old_exists="yes"
  [ -e "$orphan_old" ] || orphan_old_exists="no"
  assert_eq "no" "$orphan_old_exists" "research-gc: orphan >30d deleted"

  # --- Case 2: orphan <30d (recent) should be preserved ---
  local orphan_recent_exists="no"
  [ -e "$orphan_recent" ] && orphan_recent_exists="yes"
  assert_eq "yes" "$orphan_recent_exists" "research-gc: orphan <30d preserved"

  # --- Case 3: referenced by active task should be preserved (even though old) ---
  local ref_task_exists="no"
  [ -e "$ref_by_task" ] && ref_task_exists="yes"
  assert_eq "yes" "$ref_task_exists" "research-gc: referenced-by-task preserved"

  # --- Case 4: referenced by brainstorm should be preserved (even though old) ---
  local ref_brainstorm_exists="no"
  [ -e "$ref_by_brainstorm" ] && ref_brainstorm_exists="yes"
  assert_eq "yes" "$ref_brainstorm_exists" "research-gc: referenced-by-brainstorm preserved"

  # --- Case 5: archive-referenced file not in active refs; since archive is ignored,
  #     ref_by_archive is NOT in the referenced-set, and it IS old -> should be deleted ---
  local ref_archive_exists="yes"
  [ -e "$ref_by_archive" ] || ref_archive_exists="no"
  assert_eq "no" "$ref_archive_exists" "research-gc: archive-referenced (but not active) file deleted"

  # --- Case 6: referenced ONLY via brainstorm foundationProposalPath: scalar should be
  #     preserved (even though old) -- this is the regression this story fixes ---
  local ref_foundation_path_exists="no"
  [ -e "$ref_by_foundation_path" ] && ref_foundation_path_exists="yes"
  assert_eq "yes" "$ref_foundation_path_exists" "research-gc: referenced-by-foundationProposalPath preserved"

  # --- Case 7: unreferenced file whose name merely CONTAINS "foundation" (old, no
  #     referencing key of any kind) must still be deleted -- proves the new source
  #     is a real reference check, not a filename heuristic ---
  local orphan_foundation_named_exists="yes"
  [ -e "$orphan_foundation_named" ] || orphan_foundation_named_exists="no"
  assert_eq "no" "$orphan_foundation_named_exists" "research-gc: unreferenced foundation-named file deleted"

  # --- Case 7b: double-quoted scalar value -- quotes stripped, file preserved ---
  local ref_quoted_exists="no"
  [ -e "$ref_by_quoted" ] && ref_quoted_exists="yes"
  assert_eq "yes" "$ref_quoted_exists" "research-gc: double-quoted foundationProposalPath value preserved"

  # --- Case 7c: single-quoted scalar with trailing comment -- both stripped, preserved ---
  local ref_comment_exists="no"
  [ -e "$ref_by_comment" ] && ref_comment_exists="yes"
  assert_eq "yes" "$ref_comment_exists" "research-gc: quoted+commented foundationProposalPath value preserved"

  # --- Case 7d: foundationProposalPath BEFORE researchPaths -- scalar extracted ---
  local ref_prekey_exists="no"
  [ -e "$ref_by_prekey" ] && ref_prekey_exists="yes"
  assert_eq "yes" "$ref_prekey_exists" "research-gc: foundationProposalPath-before-researchPaths scalar preserved"

  # --- Case 7e: the researchPaths list FOLLOWING the scalar key still parses ---
  local ref_postlist_exists="no"
  [ -e "$ref_by_postlist" ] && ref_postlist_exists="yes"
  assert_eq "yes" "$ref_postlist_exists" "research-gc: researchPaths list after scalar key still parsed"

  # --- Case 8: stdout contains cleaned count
  #     (1 old orphan + 1 archive-ref + 1 unreferenced foundation-named = 3) ---
  assert_contains "Cleaned 3 orphaned research files (>30 days)" "$stdout" "research-gc: prints cleaned count"

  # --- Case 9: running again on empty dir is silent (N=0) ---
  pushd "$gc_dir" >/dev/null
  stdout=$("$CLI" research-gc 2>/dev/null) && exit_code=0 || exit_code=$?
  popd >/dev/null

  assert_exit_code "0" "$exit_code" "research-gc: idempotent second run exits 0"
  assert_eq "" "$stdout" "research-gc: silent when nothing to clean"

  rm -rf "$gc_dir"
}

test_detect_interactivity_agent_mode_env() {
  echo ""
  echo "=== Testing detect-interactivity with AIMI_AGENT_MODE=true ==="

  local output
  output=$(AIMI_AGENT_MODE=true CI= CLAUDECODE= OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "agent" "$output" "detect-interactivity returns 'agent' when AIMI_AGENT_MODE=true"
}

test_detect_interactivity_agent_mode_overrides_host() {
  echo ""
  echo "=== Testing detect-interactivity: AIMI_AGENT_MODE=true overrides CLAUDECODE=1 ==="

  local output
  output=$(AIMI_AGENT_MODE=true CI= CLAUDECODE=1 OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "agent" "$output" "detect-interactivity returns 'agent' when AIMI_AGENT_MODE=true even with CLAUDECODE=1"
}

test_detect_interactivity_ci_env() {
  echo ""
  echo "=== Testing detect-interactivity with CI=true ==="

  local output
  output=$(AIMI_AGENT_MODE= CI=true CLAUDECODE= OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "agent" "$output" "detect-interactivity returns 'agent' when CI=true"
}

test_detect_interactivity_non_tty() {
  echo ""
  echo "=== Testing detect-interactivity with non-TTY stdin and no host indicators ==="

  # No host indicators, non-TTY stdin. With the TTY fallback removed, the
  # function should now return picker (safe default).
  local output
  output=$(AIMI_AGENT_MODE= CI= CLAUDECODE= OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "picker" "$output" "detect-interactivity returns 'picker' when stdin is not a TTY and no host indicators are set (picker-by-default)"
}

test_detect_interactivity_non_interactive_flag() {
  echo ""
  echo "=== Testing detect-interactivity --non-interactive flag ==="

  local output
  output=$(AIMI_AGENT_MODE= CI= CLAUDECODE= OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity --non-interactive </dev/null)

  assert_eq "agent" "$output" "detect-interactivity returns 'agent' when --non-interactive flag is passed"
}

test_detect_interactivity_opencode_shell_sim() {
  echo ""
  echo "=== Testing detect-interactivity: OpenCode shell simulation (no host env vars, non-TTY) ==="

  # Reproduces the exact OpenCode bash-tool condition: no CLAUDECODE, no
  # OPENCODE_CONFIG_DIR, no CI, no AIMI_AGENT_MODE, stdin is not a TTY.
  # Previously the bare-TTY fallback returned agent here; now it must return picker.
  local output
  output=$(AIMI_AGENT_MODE= CI= CLAUDECODE= OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "picker" "$output" "detect-interactivity returns 'picker' in OpenCode shell simulation (no host env vars, non-TTY stdin)"
}

test_detect_interactivity_claudecode_host() {
  echo ""
  echo "=== Testing detect-interactivity: CLAUDECODE=1 forces picker despite non-TTY stdin ==="

  local output
  output=$(AIMI_AGENT_MODE= CI= CLAUDECODE=1 OPENCODE_CONFIG_DIR= "$CLI" detect-interactivity </dev/null)

  assert_eq "picker" "$output" "detect-interactivity returns 'picker' when CLAUDECODE=1 (AskUserQuestion available) regardless of TTY state"
}

test_detect_interactivity_opencode_host() {
  echo ""
  echo "=== Testing detect-interactivity: OPENCODE_CONFIG_DIR forces picker despite non-TTY stdin ==="

  local output
  output=$(AIMI_AGENT_MODE= CI= CLAUDECODE= OPENCODE_CONFIG_DIR=/tmp/opencode-test "$CLI" detect-interactivity </dev/null)

  assert_eq "picker" "$output" "detect-interactivity returns 'picker' when OPENCODE_CONFIG_DIR is set (OpenCode question tool available) regardless of TTY state"
}

# ============================================================================
# resolve-models Tests
# ============================================================================

# Helper: create an isolated temp dir with a custom AIMI_CONFIG_DIR for models tests.
_setup_models_env() {
  local tmpdir
  tmpdir=$(mktemp -d)
  printf '%s\n' "$tmpdir"
}

test_resolve_models_no_config() {
  echo ""
  echo "=== Testing resolve-models with no config file ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # Expect all five keys with inherit
  local research review design workflow executor
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s' "$output" | jq -r '.review' 2>/dev/null)
  design=$(printf '%s' "$output" | jq -r '.design' 2>/dev/null)
  workflow=$(printf '%s' "$output" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$output" | jq -r '.executor' 2>/dev/null)

  assert_eq "inherit" "$research" "resolve-models no-config: research=inherit"
  assert_eq "inherit" "$review"   "resolve-models no-config: review=inherit"
  assert_eq "inherit" "$design"   "resolve-models no-config: design=inherit"
  assert_eq "inherit" "$workflow" "resolve-models no-config: workflow=inherit"
  assert_eq "inherit" "$executor" "resolve-models no-config: executor=inherit"
}

test_resolve_models_malformed_config() {
  echo ""
  echo "=== Testing resolve-models with malformed JSON config ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  printf 'this is not json\n' > "$tmpdir/models.json"

  local stdout stderr
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # stderr must contain a warning
  if printf '%s' "$stderr" | grep -qi "warning"; then
    echo -e "${GREEN}✓${NC} resolve-models malformed-config: warning sent to stderr"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models malformed-config: expected warning on stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi

  # stdout must be valid JSON with all five inherit keys
  local research executor
  research=$(printf '%s' "$stdout" | jq -r '.research' 2>/dev/null)
  executor=$(printf '%s' "$stdout" | jq -r '.executor' 2>/dev/null)
  assert_eq "inherit" "$research" "resolve-models malformed-config: stdout is valid JSON with research=inherit"
  assert_eq "inherit" "$executor" "resolve-models malformed-config: stdout includes executor=inherit"
}

test_resolve_models_partial_config() {
  echo ""
  echo "=== Testing resolve-models with partial config (missing categories) ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # v2.0 schema: only configure research; leave others absent.
  # Direct lookup: .categories.claudeCode.research = "sonnet"
  printf '%s\n' '{"schemaVersion":"2.0","categories":{"claudeCode":{"research":"sonnet"}}}' \
    > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  local research review design workflow executor
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s' "$output" | jq -r '.review' 2>/dev/null)
  design=$(printf '%s' "$output" | jq -r '.design' 2>/dev/null)
  workflow=$(printf '%s' "$output" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$output" | jq -r '.executor' 2>/dev/null)

  assert_eq "sonnet"  "$research" "resolve-models partial-config: configured category resolves correctly"
  assert_eq "inherit" "$review"   "resolve-models partial-config: missing category=inherit"
  assert_eq "inherit" "$design"   "resolve-models partial-config: missing category=inherit"
  assert_eq "inherit" "$workflow" "resolve-models partial-config: missing category=inherit"
  assert_eq "inherit" "$executor" "resolve-models partial-config: missing executor=inherit"
}

test_resolve_models_host_detection_claudecode() {
  echo ""
  echo "=== Testing resolve-models host detection: CLAUDECODE=1 uses claudeCode table ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # v2.0 schema: claudeCode and opencode have separate categories sub-tables.
  # Only claudeCode has research; opencode has a different value so we can confirm host selection.
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "claudeCode": {
        "research": "sonnet",
        "review":   "sonnet",
        "design":   "sonnet",
        "workflow":  "sonnet",
        "executor":  "sonnet"
      },
      "opencode": {
        "research": "opencode-model-xyz",
        "review":   "opencode-model-xyz",
        "design":   "opencode-model-xyz",
        "workflow":  "opencode-model-xyz",
        "executor":  "opencode-model-xyz"
      }
    }
  }' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  local research
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)

  assert_eq "sonnet" "$research" "resolve-models host-detection: CLAUDECODE=1 reads claudeCode table"
}

test_resolve_models_host_detection_opencode() {
  echo ""
  echo "=== Testing resolve-models host detection: no CLAUDECODE uses opencode table ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # Detect a valid OpenCode model to use in the config (or use a known fallback)
  local oc_model="anthropic/claude-sonnet-4-6"
  if command -v opencode >/dev/null 2>&1; then
    local first_oc_model
    first_oc_model=$(opencode models 2>/dev/null | head -1)
    if [ -n "$first_oc_model" ]; then
      oc_model="$first_oc_model"
    fi
  fi

  # v2.0 schema: opencode and claudeCode have separate categories sub-tables.
  printf '%s\n' "{
    \"schemaVersion\": \"2.0\",
    \"categories\": {
      \"claudeCode\": {
        \"research\": \"sonnet\",
        \"review\":   \"sonnet\",
        \"design\":   \"sonnet\",
        \"workflow\":  \"sonnet\",
        \"executor\":  \"sonnet\"
      },
      \"opencode\": {
        \"research\": \"$oc_model\",
        \"review\":   \"$oc_model\",
        \"design\":   \"$oc_model\",
        \"workflow\":  \"$oc_model\",
        \"executor\":  \"$oc_model\"
      }
    }
  }" > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" resolve-models 2>/dev/null)

  local research claudecode_research
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  # Also verify Claude Code host returns the claudeCode model (different from opencode)
  claudecode_research=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null | jq -r '.research' 2>/dev/null)

  assert_eq "$oc_model" "$research" "resolve-models host-detection: no CLAUDECODE reads opencode table"

  # When oc_model != "sonnet", verify the hosts return different values
  if [ "$oc_model" != "sonnet" ]; then
    if [ "$research" != "$claudecode_research" ]; then
      echo -e "${GREEN}✓${NC} resolve-models host-detection: CLAUDECODE=1 and no CLAUDECODE read different tables"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} resolve-models host-detection: expected different results per host (research=$research, claudecode=$claudecode_research)"
      ((TESTS_FAILED++))
    fi
  fi
}

test_resolve_models_invalid_model_claudecode() {
  echo ""
  echo "=== Testing resolve-models: invalid model for Claude Code falls back to inherit ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # v2.0 schema: direct category-to-model mapping.
  # research has an invalid model; review has a valid exact alias "sonnet".
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "claudeCode": {
        "research":  "totally-invalid-model-xyz",
        "review":    "sonnet",
        "design":    "sonnet",
        "workflow":  "sonnet",
        "executor":  "sonnet"
      }
    }
  }' > "$tmpdir/models.json"

  local stdout stderr
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # Invalid model should produce a warning on stderr
  if printf '%s' "$stderr" | grep -qi "warning"; then
    echo -e "${GREEN}✓${NC} resolve-models invalid-model-claudecode: warning sent to stderr"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models invalid-model-claudecode: expected warning on stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi

  # Invalid category should fall back to inherit
  local research
  research=$(printf '%s' "$stdout" | jq -r '.research' 2>/dev/null)
  assert_eq "inherit" "$research" "resolve-models invalid-model-claudecode: invalid model falls back to inherit"

  # Valid category should still resolve (exact alias "sonnet" passes)
  local review
  review=$(printf '%s' "$stdout" | jq -r '.review' 2>/dev/null)
  assert_eq "sonnet" "$review" "resolve-models invalid-model-claudecode: valid exact-alias model still resolves"
}

test_resolve_models_all_keys_always_present() {
  echo ""
  echo "=== Testing resolve-models: output always has all five keys ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # Empty config dir — no models.json
  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  local keys
  keys=$(printf '%s' "$output" | jq -r 'keys | sort | join(",")' 2>/dev/null)

  assert_eq "design,executor,research,review,workflow" "$keys" "resolve-models: output always contains all five keys"
}

test_resolve_models_stdout_always_valid_json() {
  echo ""
  echo "=== Testing resolve-models: stdout is always valid JSON ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # Write malformed JSON
  printf 'not json at all\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  if printf '%s' "$output" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} resolve-models stdout-valid-json: malformed config still produces valid JSON stdout"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models stdout-valid-json: stdout is not valid JSON: $output"
    ((TESTS_FAILED++))
  fi
}

test_resolve_models_exact_match_validation() {
  echo ""
  echo "=== Testing resolve-models: Claude Code exact-match rejects version-suffixed models ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # v2.0 schema: direct category mapping.
  # "claude-haiku-4-5" / "claude-sonnet-4-6" / "claude-opus-4-7" contain keywords but are NOT
  # exact aliases — they must be rejected under the exact-match rule.
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "claudeCode": {
        "research":  "claude-haiku-4-5",
        "review":    "claude-sonnet-4-6",
        "design":    "claude-opus-4-7",
        "workflow":  "claude-haiku-4-5",
        "executor":  "claude-sonnet-4-6"
      }
    }
  }' > "$tmpdir/models.json"

  local stdout stderr
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # All five should be rejected → inherit (no version suffix allowed)
  local research review design workflow executor
  research=$(printf '%s' "$stdout" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s' "$stdout" | jq -r '.review' 2>/dev/null)
  design=$(printf '%s' "$stdout" | jq -r '.design' 2>/dev/null)
  workflow=$(printf '%s' "$stdout" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$stdout" | jq -r '.executor' 2>/dev/null)

  assert_eq "inherit" "$research" "resolve-models exact-match: claude-haiku-4-5 rejected → inherit (research)"
  assert_eq "inherit" "$review"   "resolve-models exact-match: claude-sonnet-4-6 rejected → inherit (review)"
  assert_eq "inherit" "$design"   "resolve-models exact-match: claude-opus-4-7 rejected → inherit (design)"
  assert_eq "inherit" "$workflow" "resolve-models exact-match: claude-haiku-4-5 rejected → inherit (workflow)"
  assert_eq "inherit" "$executor" "resolve-models exact-match: claude-sonnet-4-6 rejected → inherit (executor)"

  # Warnings must be emitted (one per invalid category — at least 3)
  local warn_count
  warn_count=$(printf '%s' "$stderr" | grep -c -i "warning" 2>/dev/null || echo "0")
  if [ "$warn_count" -ge 3 ]; then
    echo -e "${GREEN}✓${NC} resolve-models exact-match: warnings emitted for each invalid model ($warn_count)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models exact-match: expected >=3 warnings, got $warn_count; stderr=$stderr"
    ((TESTS_FAILED++))
  fi
}

test_resolve_models_exact_aliases_accepted() {
  echo ""
  echo "=== Testing resolve-models: Claude Code exact aliases haiku/sonnet/opus are accepted ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # v2.0 schema: direct category-to-model mapping using exact aliases.
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "claudeCode": {
        "research":  "haiku",
        "review":    "sonnet",
        "design":    "opus",
        "workflow":  "haiku",
        "executor":  "sonnet"
      }
    }
  }' > "$tmpdir/models.json"

  local stdout stderr
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  local research review design workflow executor
  research=$(printf '%s' "$stdout" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s' "$stdout" | jq -r '.review' 2>/dev/null)
  design=$(printf '%s' "$stdout" | jq -r '.design' 2>/dev/null)
  workflow=$(printf '%s' "$stdout" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$stdout" | jq -r '.executor' 2>/dev/null)

  assert_eq "haiku"  "$research" "resolve-models exact-match: haiku alias accepted (research)"
  assert_eq "sonnet" "$review"   "resolve-models exact-match: sonnet alias accepted (review)"
  assert_eq "opus"   "$design"   "resolve-models exact-match: opus alias accepted (design)"
  assert_eq "haiku"  "$workflow" "resolve-models exact-match: haiku alias accepted (workflow)"
  assert_eq "sonnet" "$executor" "resolve-models exact-match: sonnet alias accepted (executor)"

  # No warnings should be emitted for valid models
  if [ -z "$stderr" ]; then
    echo -e "${GREEN}✓${NC} resolve-models exact-match: no warnings for valid exact aliases"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models exact-match: unexpected warnings: $stderr"
    ((TESTS_FAILED++))
  fi
}

test_resolve_models_v1_rejected() {
  echo ""
  echo "=== Testing resolve-models: v1.0-shaped config is rejected with warning and all-inherit fallback ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # Write a v1.0-shaped config (has top-level .models key and schemaVersion "1.0")
  printf '%s\n' '{
    "schemaVersion": "1.0",
    "categories": {
      "research": "fast"
    },
    "models": {
      "claudeCode": {
        "fast": "haiku"
      }
    }
  }' > "$tmpdir/models.json"

  local stdout stderr
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # stderr must contain "schema 1.0" (case-sensitive)
  if printf '%s' "$stderr" | grep -q "schema 1.0"; then
    echo -e "${GREEN}✓${NC} resolve-models v1-rejected: stderr contains 'schema 1.0'"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models v1-rejected: expected 'schema 1.0' in stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi

  # stdout must be the all-inherit JSON on all five keys
  local research review design workflow executor
  research=$(printf '%s' "$stdout" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s' "$stdout" | jq -r '.review' 2>/dev/null)
  design=$(printf '%s' "$stdout" | jq -r '.design' 2>/dev/null)
  workflow=$(printf '%s' "$stdout" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$stdout" | jq -r '.executor' 2>/dev/null)

  assert_eq "inherit" "$research" "resolve-models v1-rejected: research=inherit"
  assert_eq "inherit" "$review"   "resolve-models v1-rejected: review=inherit"
  assert_eq "inherit" "$design"   "resolve-models v1-rejected: design=inherit"
  assert_eq "inherit" "$workflow" "resolve-models v1-rejected: workflow=inherit"
  assert_eq "inherit" "$executor" "resolve-models v1-rejected: executor=inherit"
}

test_resolve_models_opencode_mtime_cache() {
  echo ""
  echo "=== Testing resolve-models: OpenCode mtime cache avoids repeated opencode shell-out ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Create a fake opencode script that records invocation count via a counter file
  local fake_oc_dir
  fake_oc_dir=$(mktemp -d)
  trap "rm -rf '$fake_oc_dir'" RETURN

  local counter_file="$fake_oc_dir/call_count"
  printf '0\n' > "$counter_file"

  cat > "$fake_oc_dir/opencode" << 'FAKE_OC'
#!/usr/bin/env bash
counter_file="COUNTER_PLACEHOLDER"
count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
printf 'anthropic/claude-sonnet-4-6\nanthropic/claude-haiku-4-5\n'
FAKE_OC
  sed -i "s|COUNTER_PLACEHOLDER|$counter_file|" "$fake_oc_dir/opencode"
  chmod +x "$fake_oc_dir/opencode"

  # Write a v2.0 models.json that references a valid OpenCode model
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "opencode": {
        "research":  "anthropic/claude-sonnet-4-6",
        "review":    "anthropic/claude-sonnet-4-6",
        "design":    "anthropic/claude-sonnet-4-6",
        "workflow":  "anthropic/claude-sonnet-4-6",
        "executor":  "anthropic/claude-sonnet-4-6"
      }
    }
  }' > "$tmpdir/models.json"

  # First call: opencode should be invoked once to populate the cache
  PATH="$fake_oc_dir:$PATH" AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" resolve-models 2>/dev/null
  local count_after_first
  count_after_first=$(cat "$counter_file" 2>/dev/null || echo 0)

  # Second call: cache should be hit — opencode must NOT be invoked again
  PATH="$fake_oc_dir:$PATH" AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" resolve-models 2>/dev/null
  local count_after_second
  count_after_second=$(cat "$counter_file" 2>/dev/null || echo 0)

  if [ "$count_after_first" -eq 1 ]; then
    echo -e "${GREEN}✓${NC} resolve-models opencode mtime-cache: first call invokes opencode once"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models opencode mtime-cache: expected 1 call after first invoke, got $count_after_first"
    ((TESTS_FAILED++))
  fi

  if [ "$count_after_second" -eq 1 ]; then
    echo -e "${GREEN}✓${NC} resolve-models opencode mtime-cache: second call uses cache (opencode not called again)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} resolve-models opencode mtime-cache: expected 1 total calls after second invoke, got $count_after_second"
    ((TESTS_FAILED++))
  fi

  # Verify the second call still produces correct output
  local second_output
  second_output=$(PATH="$fake_oc_dir:$PATH" AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" resolve-models 2>/dev/null)
  local research
  research=$(printf '%s' "$second_output" | jq -r '.research' 2>/dev/null)
  assert_eq "anthropic/claude-sonnet-4-6" "$research" "resolve-models opencode mtime-cache: cached result is correct"
}

# ============================================================================
# get-current-models Tests
# ============================================================================

test_get_current_models_no_config() {
  echo ""
  echo "=== Testing get-current-models with no config file (all null) ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" get-current-models 2>/dev/null)

  # Verify all five keys are JSON null (not the string "null", not "inherit")
  local research_null review_null design_null workflow_null executor_null
  research_null=$(printf '%s' "$output" | jq '.research == null' 2>/dev/null)
  review_null=$(printf '%s' "$output"   | jq '.review == null'   2>/dev/null)
  design_null=$(printf '%s' "$output"   | jq '.design == null'   2>/dev/null)
  workflow_null=$(printf '%s' "$output" | jq '.workflow == null' 2>/dev/null)
  executor_null=$(printf '%s' "$output" | jq '.executor == null' 2>/dev/null)

  assert_eq "true" "$research_null" "get-current-models no-config: research is JSON null"
  assert_eq "true" "$review_null"   "get-current-models no-config: review is JSON null"
  assert_eq "true" "$design_null"   "get-current-models no-config: design is JSON null"
  assert_eq "true" "$workflow_null" "get-current-models no-config: workflow is JSON null"
  assert_eq "true" "$executor_null" "get-current-models no-config: executor is JSON null"
}

test_get_current_models_v2_full_config_claudecode() {
  echo ""
  echo "=== Testing get-current-models v2.0 full config (claudeCode host) ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN
  _write_full_models_config "$tmpdir"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" get-current-models 2>/dev/null)

  local research review design workflow executor
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s'   "$output" | jq -r '.review'   2>/dev/null)
  design=$(printf '%s'   "$output" | jq -r '.design'   2>/dev/null)
  workflow=$(printf '%s' "$output" | jq -r '.workflow' 2>/dev/null)
  executor=$(printf '%s' "$output" | jq -r '.executor' 2>/dev/null)

  assert_eq "sonnet" "$research" "get-current-models v2.0 claudeCode: research=sonnet"
  assert_eq "opus"   "$review"   "get-current-models v2.0 claudeCode: review=opus"
  assert_eq "sonnet" "$design"   "get-current-models v2.0 claudeCode: design=sonnet"
  assert_eq "haiku"  "$workflow" "get-current-models v2.0 claudeCode: workflow=haiku"
  assert_eq "haiku"  "$executor" "get-current-models v2.0 claudeCode: executor=haiku"
}

test_get_current_models_host_branch_opencode() {
  echo ""
  echo "=== Testing get-current-models host branch (opencode host) ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN
  _write_full_models_config "$tmpdir"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" get-current-models 2>/dev/null)

  local research executor
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  executor=$(printf '%s' "$output" | jq -r '.executor' 2>/dev/null)

  assert_eq "anthropic/claude-sonnet-4-6" "$research" "get-current-models opencode: research id from opencode sub-table"
  assert_eq "anthropic/claude-haiku-4-5"  "$executor" "get-current-models opencode: executor id from opencode sub-table"
}

test_get_current_models_partial_config_emits_null_for_unset() {
  echo ""
  echo "=== Testing get-current-models with partial config (unset categories emit null) ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  # Only research and review configured for claudeCode; the other three should be null.
  printf '{
  "schemaVersion": "2.0",
  "categories": {
    "claudeCode": {
      "research": "sonnet",
      "review":   "opus"
    }
  }
}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" get-current-models 2>/dev/null)

  local research review design_null workflow_null executor_null
  research=$(printf '%s' "$output" | jq -r '.research' 2>/dev/null)
  review=$(printf '%s'   "$output" | jq -r '.review'   2>/dev/null)
  design_null=$(printf '%s'   "$output" | jq '.design == null'   2>/dev/null)
  workflow_null=$(printf '%s' "$output" | jq '.workflow == null' 2>/dev/null)
  executor_null=$(printf '%s' "$output" | jq '.executor == null' 2>/dev/null)

  assert_eq "sonnet" "$research" "get-current-models partial: research has configured value"
  assert_eq "opus"   "$review"   "get-current-models partial: review has configured value"
  assert_eq "true"   "$design_null"   "get-current-models partial: design is JSON null"
  assert_eq "true"   "$workflow_null" "get-current-models partial: workflow is JSON null"
  assert_eq "true"   "$executor_null" "get-current-models partial: executor is JSON null"
}

test_get_current_models_v1_config_rejected() {
  echo ""
  echo "=== Testing get-current-models rejects v1.0 config with stderr warning ==="

  local tmpdir
  tmpdir=$(_setup_models_env)
  trap "rm -rf '$tmpdir'" RETURN

  printf '{"schemaVersion":"1.0","models":{"claudeCode":{"fast":"haiku"}}}\n' > "$tmpdir/models.json"

  local stdout stderr
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" get-current-models 2>/dev/null)
  stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" get-current-models 2>&1 1>/dev/null)

  if printf '%s' "$stderr" | grep -q 'schema 1.0'; then
    echo -e "${GREEN}✓${NC} get-current-models v1.0: stderr contains 'schema 1.0' warning"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} get-current-models v1.0: expected 'schema 1.0' on stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi

  local research_null executor_null
  research_null=$(printf '%s' "$stdout" | jq '.research == null' 2>/dev/null)
  executor_null=$(printf '%s' "$stdout" | jq '.executor == null' 2>/dev/null)
  assert_eq "true" "$research_null" "get-current-models v1.0: stdout has research as JSON null"
  assert_eq "true" "$executor_null" "get-current-models v1.0: stdout has executor as JSON null"
}

# ============================================================================
# detect-models Tests
# ============================================================================

# Helper: write a valid full v2.0 models.json for round-trip tests.
# claudeCode categories use short aliases (haiku/sonnet/opus) as required by the Task tool.
# opencode categories use provider/model-id format.
_write_full_models_config() {
  local dir="$1"
  printf '{
  "schemaVersion": "2.0",
  "categories": {
    "claudeCode": {
      "research":  "sonnet",
      "review":    "opus",
      "design":    "sonnet",
      "workflow":  "haiku",
      "executor":  "haiku"
    },
    "opencode": {
      "research":  "anthropic/claude-sonnet-4-6",
      "review":    "anthropic/claude-opus-4-7",
      "design":    "anthropic/claude-sonnet-4-6",
      "workflow":  "anthropic/claude-haiku-4-5",
      "executor":  "anthropic/claude-haiku-4-5"
    }
  }
}\n' > "$dir/models.json"
}

test_detect_models_claudecode_generates_config() {
  echo ""
  echo "=== Testing detect-models on Claude Code host generates valid models.json ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Run detect-models as Claude Code host (non-interactive, stdin is not a TTY in tests)
  local stdout
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" detect-models 2>/dev/null </dev/null)

  # models.json must exist
  if [ -f "$tmpdir/models.json" ]; then
    echo -e "${GREEN}✓${NC} detect-models claudecode: models.json written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models claudecode: models.json not found in $tmpdir"
    ((TESTS_FAILED++))
  fi

  # stdout must be valid JSON
  if printf '%s' "$stdout" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models claudecode: stdout is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models claudecode: stdout is not valid JSON: $stdout"
    ((TESTS_FAILED++))
  fi

  # schemaVersion must be "2.0"
  local schema_ver
  schema_ver=$(printf '%s' "$stdout" | jq -r '.schemaVersion // empty' 2>/dev/null)
  assert_eq "2.0" "$schema_ver" "detect-models claudecode: schemaVersion is 2.0"

  # categories.claudeCode must have all five keys
  local cat_keys
  cat_keys=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode | keys | sort | join(",")' 2>/dev/null)
  assert_eq "design,executor,research,review,workflow" "$cat_keys" "detect-models claudecode: categories.claudeCode has all five keys"

  # categories.claudeCode must have claudeCode key (no top-level .models key in v2.0)
  local has_cc_cats
  has_cc_cats=$(printf '%s' "$stdout" | jq -r '(.categories | has("claudeCode")) | tostring' 2>/dev/null)
  assert_eq "true" "$has_cc_cats" "detect-models claudecode: categories has claudeCode sub-table"

  # All five categories must be present with valid exact short aliases: haiku/sonnet/opus
  local research_model review_model design_model workflow_model executor_model
  research_model=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.research // empty' 2>/dev/null)
  review_model=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.review // empty' 2>/dev/null)
  design_model=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.design // empty' 2>/dev/null)
  workflow_model=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.workflow // empty' 2>/dev/null)
  executor_model=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.executor // empty' 2>/dev/null)

  # Each must be one of the valid aliases (haiku/sonnet/opus)
  local valid_aliases="haiku sonnet opus"
  for _cat_name in research review design workflow executor; do
    local _val
    eval "_val=\$${_cat_name}_model"
    if printf '%s' "$valid_aliases" | grep -qw "$_val"; then
      echo -e "${GREEN}✓${NC} detect-models claudecode: ${_cat_name} is a valid alias (${_val})"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} detect-models claudecode: ${_cat_name} expected valid alias, got '${_val}'"
      ((TESTS_FAILED++))
    fi
  done
}

test_detect_models_opencode_absent_fallback() {
  echo ""
  echo "=== Testing detect-models on OpenCode host with opencode binary absent — fallback with warning ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Run detect-models without CLAUDECODE, PATH stripped of opencode
  local stdout stderr
  stderr=$(PATH="/usr/bin:/bin" AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" detect-models 2>&1 1>/dev/null </dev/null)
  stdout=$(PATH="/usr/bin:/bin" AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" detect-models 2>/dev/null </dev/null)

  # models.json must be written
  if [ -f "$tmpdir/models.json" ]; then
    echo -e "${GREEN}✓${NC} detect-models opencode-absent: models.json written despite absent binary"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models opencode-absent: models.json not found in $tmpdir"
    ((TESTS_FAILED++))
  fi

  # Exactly one warning must go to stderr
  if printf '%s' "$stderr" | grep -q "Warning: detect-models: opencode binary not found"; then
    echo -e "${GREEN}✓${NC} detect-models opencode-absent: one warning on stderr"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models opencode-absent: expected warning on stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi

  # stdout must still be valid JSON
  if printf '%s' "$stdout" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models opencode-absent: stdout is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models opencode-absent: stdout is not valid JSON: $stdout"
    ((TESTS_FAILED++))
  fi

  # categories must have opencode key (not claudeCode) for OpenCode host — v2.0 schema
  local has_oc
  has_oc=$(printf '%s' "$stdout" | jq -r '(.categories | has("opencode")) | tostring' 2>/dev/null)
  assert_eq "true" "$has_oc" "detect-models opencode-absent: categories has opencode sub-table"
}

test_detect_models_atomic_write_no_corruption() {
  echo ""
  echo "=== Testing detect-models atomic write: pre-existing valid config is never partially overwritten ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Write a known-good pre-existing models.json
  _write_full_models_config "$tmpdir"
  local original_content
  original_content=$(cat "$tmpdir/models.json")

  # Run detect-models normally — it should overwrite atomically
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" detect-models 2>/dev/null </dev/null

  # Result must still be valid JSON
  local new_content
  new_content=$(cat "$tmpdir/models.json" 2>/dev/null)
  if printf '%s' "$new_content" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models atomic-write: post-run models.json is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models atomic-write: post-run models.json is not valid JSON: $new_content"
    ((TESTS_FAILED++))
  fi

  # No leftover temp file must exist (mktemp + mv atomicity guarantee)
  local leftover_count
  leftover_count=$(find "$tmpdir" -name 'models.json.*' | wc -l)
  if [ "$leftover_count" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} detect-models atomic-write: no leftover temp files"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models atomic-write: found $leftover_count leftover temp files"
    ((TESTS_FAILED++))
  fi

  # File must have permission 0600
  local perms
  perms=$(stat -c '%a' "$tmpdir/models.json" 2>/dev/null || stat -f '%Lp' "$tmpdir/models.json" 2>/dev/null)
  assert_eq "600" "$perms" "detect-models atomic-write: models.json permission is 0600"
}

test_detect_models_roundtrip_with_resolve_models() {
  echo ""
  echo "=== Testing detect-models output round-trips correctly through resolve-models ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # detect-models writes the config
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" detect-models 2>/dev/null </dev/null

  # resolve-models must consume it without warnings
  local resolve_stdout resolve_stderr
  resolve_stderr=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>&1 1>/dev/null)
  resolve_stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" resolve-models 2>/dev/null)

  # stdout must be valid JSON
  if printf '%s' "$resolve_stdout" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models roundtrip: resolve-models produces valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models roundtrip: resolve-models stdout is not valid JSON: $resolve_stdout"
    ((TESTS_FAILED++))
  fi

  # No warnings on stderr from resolve-models
  if [ -z "$resolve_stderr" ]; then
    echo -e "${GREEN}✓${NC} detect-models roundtrip: resolve-models produced no warnings"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models roundtrip: resolve-models warnings: $resolve_stderr"
    ((TESTS_FAILED++))
  fi

  # All five keys must be present in resolve-models output
  local keys
  keys=$(printf '%s' "$resolve_stdout" | jq -r 'keys | sort | join(",")' 2>/dev/null)
  assert_eq "design,executor,research,review,workflow" "$keys" "detect-models roundtrip: all five category keys present"
}

test_write_aimi_models_config() {
  echo ""
  echo "=== Testing write_aimi_models_config atomic write helper ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  source_cache_functions

  local test_json='{"schemaVersion":"1.0","categories":{"research":"balanced"},"models":{}}'
  AIMI_CONFIG_DIR="$tmpdir" write_aimi_models_config "$test_json"

  local config_file="$tmpdir/models.json"

  # File must exist
  if [ -f "$config_file" ]; then
    echo -e "${GREEN}✓${NC} write_aimi_models_config: file written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} write_aimi_models_config: file not found at $config_file"
    ((TESTS_FAILED++))
  fi

  # Content must match
  local content
  content=$(cat "$config_file" 2>/dev/null | tr -d '\n')
  if printf '%s' "$content" | grep -q '"schemaVersion":"1.0"'; then
    echo -e "${GREEN}✓${NC} write_aimi_models_config: content matches"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} write_aimi_models_config: content mismatch: $content"
    ((TESTS_FAILED++))
  fi

  # Permission must be 0600
  local perms
  perms=$(stat -c '%a' "$config_file" 2>/dev/null || stat -f '%Lp' "$config_file" 2>/dev/null)
  assert_eq "600" "$perms" "write_aimi_models_config: permission is 0600"

  # No leftover temp files
  local leftover
  leftover=$(find "$tmpdir" -name 'models.json.*' | wc -l)
  if [ "$leftover" -eq 0 ]; then
    echo -e "${GREEN}✓${NC} write_aimi_models_config: no leftover temp files"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} write_aimi_models_config: $leftover leftover temp files"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# models-prompt-check / models-prompt-dismiss Tests
# ============================================================================

test_models_prompt_check_returns_prompt() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when neither file exists ==="

  local tmpdir
  tmpdir=$(mktemp -d)

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: returns 'prompt' when neither models.json nor marker exists"

  rm -rf "$tmpdir"
}

test_models_prompt_check_skip_when_current_host_configured() {
  echo ""
  echo "=== Testing models-prompt-check returns 'skip' when current host has at least one configured category ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # v2.0 config with claudeCode host configured; CLAUDECODE=1 in the call.
  printf '{"schemaVersion":"2.0","categories":{"claudeCode":{"research":"haiku"}}}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "skip" "$output" "models-prompt-check: returns 'skip' when current host (claudeCode) has a configured category"

  rm -rf "$tmpdir"
}

test_models_prompt_check_prompt_when_other_host_only_configured() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when only the other host is configured ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # opencode configured; CLAUDECODE=1 means current host is claudeCode (absent).
  printf '{"schemaVersion":"2.0","categories":{"opencode":{"research":"anthropic/claude-haiku-4-5"}}}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: returns 'prompt' when only the other host is configured"

  rm -rf "$tmpdir"
}

test_models_prompt_check_prompt_when_current_host_all_null() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when current host has all-null categories ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  printf '{"schemaVersion":"2.0","categories":{"claudeCode":{"research":null,"review":null,"design":null,"workflow":null,"executor":null}}}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: returns 'prompt' when current host has all-null categories"

  rm -rf "$tmpdir"
}

test_models_prompt_check_prompt_when_v1_config() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when config is v1.0 (treated as obsolete) ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  printf '{"schemaVersion":"1.0","models":{"claudeCode":{"fast":"haiku"}}}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: returns 'prompt' on v1.0 config (treat as unconfigured)"

  rm -rf "$tmpdir"
}

test_models_prompt_check_prompt_when_file_missing_even_with_per_host_marker() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when models.json is missing, even with per-host marker ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Per-host marker present, no models.json. File-missing always wins.
  printf 'models-prompt-seen: 2026-01-01T00:00:00Z\n' > "$tmpdir/models-prompt-seen-claudeCode"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: file-missing re-prompts even with per-host marker present"

  rm -rf "$tmpdir"
}

test_models_prompt_check_skip_when_per_host_marker_dismisses() {
  echo ""
  echo "=== Testing models-prompt-check returns 'skip' when host unconfigured but per-host marker present ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Config file present with only the OTHER host configured; current host (claudeCode)
  # is unconfigured BUT has a dismissal marker — should skip.
  printf '{"schemaVersion":"2.0","categories":{"opencode":{"research":"anthropic/claude-haiku-4-5"}}}\n' > "$tmpdir/models.json"
  printf 'dismissed on 2026-01-01\n' > "$tmpdir/models-prompt-seen-claudeCode"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "skip" "$output" "models-prompt-check: per-host marker suppresses prompt when host unconfigured + file present"

  rm -rf "$tmpdir"
}

test_models_prompt_check_per_host_marker_isolation() {
  echo ""
  echo "=== Testing models-prompt-check: other host's marker does NOT suppress prompt on this host ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Config file present, current host (claudeCode) unconfigured, but only OPENCODE
  # marker is present — claudeCode prompt should still fire.
  printf '{"schemaVersion":"2.0","categories":{"opencode":{"research":"x"}}}\n' > "$tmpdir/models.json"
  printf 'dismissed on opencode\n' > "$tmpdir/models-prompt-seen-opencode"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: opencode marker does not silence claudeCode prompt"

  rm -rf "$tmpdir"
}

test_models_prompt_check_legacy_global_marker_ignored() {
  echo ""
  echo "=== Testing models-prompt-check: legacy global marker (no host suffix) is NOT honored ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Config file present, current host unconfigured, only the legacy global marker exists.
  # New code ignores the legacy file — should prompt.
  printf '{"schemaVersion":"2.0","categories":{"opencode":{"research":"x"}}}\n' > "$tmpdir/models.json"
  printf 'legacy global marker from pre-1.93.2\n' > "$tmpdir/models-prompt-seen"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: legacy global marker is ignored (must migrate to per-host)"

  rm -rf "$tmpdir"
}

test_models_prompt_check_skip_when_current_host_configured_with_marker() {
  echo ""
  echo "=== Testing models-prompt-check returns 'skip' when current host configured (marker irrelevant) ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Both config (with current host configured) AND per-host marker present.
  # The check short-circuits at "host configured" — marker is not consulted.
  printf '{"schemaVersion":"2.0","categories":{"claudeCode":{"research":"haiku","review":"opus","design":"sonnet","workflow":"sonnet","executor":"sonnet"}}}\n' > "$tmpdir/models.json"
  printf 'models-prompt-seen: 2026-01-01T00:00:00Z\n' > "$tmpdir/models-prompt-seen-claudeCode"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "skip" "$output" "models-prompt-check: returns 'skip' when current host configured; marker is irrelevant"

  rm -rf "$tmpdir"
}

test_models_prompt_check_prompt_when_categories_empty_object() {
  echo ""
  echo "=== Testing models-prompt-check returns 'prompt' when categories is empty {} ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  printf '{"schemaVersion":"2.0","categories":{}}\n' > "$tmpdir/models.json"

  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)

  assert_eq "prompt" "$output" "models-prompt-check: returns 'prompt' when categories is empty {} (no host configured)"

  rm -rf "$tmpdir"
}

test_models_prompt_dismiss_creates_per_host_marker_claudecode() {
  echo ""
  echo "=== Testing models-prompt-dismiss writes per-host marker for claudeCode ==="

  local tmpdir
  tmpdir=$(mktemp -d)

  # Before dismiss: should prompt
  local before
  before=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)
  assert_eq "prompt" "$before" "models-prompt-dismiss claudeCode: check returns 'prompt' before dismiss"

  # Dismiss on claudeCode
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-dismiss > /dev/null

  # Per-host marker file should exist
  if [ -f "$tmpdir/models-prompt-seen-claudeCode" ]; then
    echo -e "${GREEN}✓${NC} models-prompt-dismiss claudeCode: per-host marker file exists at models-prompt-seen-claudeCode"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} models-prompt-dismiss claudeCode: per-host marker file not found"
    ((TESTS_FAILED++))
  fi

  # Per-host marker should have 0600 permissions
  local perms
  perms=$(stat -c '%a' "$tmpdir/models-prompt-seen-claudeCode" 2>/dev/null || stat -f '%Lp' "$tmpdir/models-prompt-seen-claudeCode" 2>/dev/null)
  assert_eq "600" "$perms" "models-prompt-dismiss claudeCode: per-host marker has 0600 permissions"

  # Opencode marker should NOT exist (per-host isolation)
  if [ ! -f "$tmpdir/models-prompt-seen-opencode" ]; then
    echo -e "${GREEN}✓${NC} models-prompt-dismiss claudeCode: opencode marker NOT created (per-host isolation)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} models-prompt-dismiss claudeCode: opencode marker leaked"
    ((TESTS_FAILED++))
  fi

  # After dismiss (models.json still missing): check still returns 'prompt' — file-missing wins over marker
  local after
  after=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)
  assert_eq "prompt" "$after" "models-prompt-dismiss claudeCode: check returns 'prompt' when models.json missing (marker does not override file-missing)"

  rm -rf "$tmpdir"
}

test_models_prompt_dismiss_creates_per_host_marker_opencode() {
  echo ""
  echo "=== Testing models-prompt-dismiss writes per-host marker for opencode ==="

  local tmpdir
  tmpdir=$(mktemp -d)

  # Dismiss on opencode (no CLAUDECODE)
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE= "$CLI" models-prompt-dismiss > /dev/null

  # Per-host marker file should exist with opencode suffix
  if [ -f "$tmpdir/models-prompt-seen-opencode" ]; then
    echo -e "${GREEN}✓${NC} models-prompt-dismiss opencode: per-host marker file exists at models-prompt-seen-opencode"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} models-prompt-dismiss opencode: per-host marker file not found"
    ((TESTS_FAILED++))
  fi

  # ClaudeCode marker should NOT exist
  if [ ! -f "$tmpdir/models-prompt-seen-claudeCode" ]; then
    echo -e "${GREEN}✓${NC} models-prompt-dismiss opencode: claudeCode marker NOT created"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} models-prompt-dismiss opencode: claudeCode marker leaked"
    ((TESTS_FAILED++))
  fi

  rm -rf "$tmpdir"
}

test_models_prompt_dismiss_then_check_skips_when_file_present() {
  echo ""
  echo "=== Testing dismiss + file present + host unconfigured → check returns 'skip' (full UX flow) ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  # Simulate: user already configured opencode; opens Claude Code; picks "Keep the default";
  # next session on same host should not re-prompt.
  printf '{"schemaVersion":"2.0","categories":{"opencode":{"research":"x"}}}\n' > "$tmpdir/models.json"

  # First check (no marker yet): prompt
  local before
  before=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)
  assert_eq "prompt" "$before" "dismiss-flow: pre-dismiss check returns 'prompt' (host unconfigured, no marker)"

  # User picks "Keep the default" → models-prompt-dismiss
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-dismiss > /dev/null

  # Subsequent check: skip (dismissal honored)
  local after
  after=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)
  assert_eq "skip" "$after" "dismiss-flow: post-dismiss check returns 'skip' (per-host marker suppresses)"

  rm -rf "$tmpdir"
}

test_models_prompt_dismiss_idempotent() {
  echo ""
  echo "=== Testing models-prompt-dismiss is idempotent (calling twice does not error) ==="

  local tmpdir
  tmpdir=$(mktemp -d)

  # First call
  local exit1
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-dismiss > /dev/null
  exit1=$?
  assert_eq "0" "$exit1" "models-prompt-dismiss idempotent: first call exits 0"

  # Second call (marker already exists)
  local exit2
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-dismiss > /dev/null
  exit2=$?
  assert_eq "0" "$exit2" "models-prompt-dismiss idempotent: second call exits 0"

  # Check still returns 'prompt' (models.json still missing — file-missing wins over marker)
  local output
  output=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" models-prompt-check)
  assert_eq "prompt" "$output" "models-prompt-dismiss idempotent: check returns 'prompt' when models.json missing (marker does not override file-missing)"

  rm -rf "$tmpdir"
}

# ============================================================================
# list-models Tests
# ============================================================================

test_list_models_claudecode_returns_three_aliases() {
  echo ""
  echo "=== Testing list-models on Claude Code host returns [opus,sonnet,haiku] ==="

  local output
  output=$(CLAUDECODE=1 "$CLI" list-models 2>/dev/null)

  # Output must be a valid JSON array
  if printf '%s' "$output" | jq -e 'type == "array"' > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} list-models claudecode: output is a JSON array"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} list-models claudecode: output is not a JSON array: $output"
    ((TESTS_FAILED++))
  fi

  # Must contain exactly 3 elements
  local length
  length=$(printf '%s' "$output" | jq 'length' 2>/dev/null)
  assert_eq "3" "$length" "list-models claudecode: array has exactly 3 elements"

  # Must contain opus, sonnet, haiku
  local has_opus has_sonnet has_haiku
  has_opus=$(printf '%s' "$output" | jq -r 'index("opus") != null | tostring' 2>/dev/null)
  has_sonnet=$(printf '%s' "$output" | jq -r 'index("sonnet") != null | tostring' 2>/dev/null)
  has_haiku=$(printf '%s' "$output" | jq -r 'index("haiku") != null | tostring' 2>/dev/null)
  assert_eq "true" "$has_opus"   "list-models claudecode: array contains 'opus'"
  assert_eq "true" "$has_sonnet" "list-models claudecode: array contains 'sonnet'"
  assert_eq "true" "$has_haiku"  "list-models claudecode: array contains 'haiku'"
}

# The Claude Code branch of list-models answers with a literal JSON array and
# crosses into nothing -- its answer is a constant, so there is no document to
# read and no interpreter to need, which is what keeps `list-models` working on
# a host with no python3. The price is that the three aliases are spelled
# twice: once as data in _host_valid_models, once as JSON here. This runs both
# and compares them, so the second spelling cannot drift from the first without
# a test saying so.
test_list_models_claudecode_matches_the_host_valid_set() {
  echo ""
  echo "=== Testing list-models' Claude Code literal against _host_valid_models ==="

  local from_helper from_verb
  from_helper=$(
    eval "$(sed -n '/^_is_claude_code_host() {$/,/^}$/p' "$CLI")"
    eval "$(sed -n '/^_normalize_model_id() {$/,/^}$/p' "$CLI")"
    eval "$(sed -n '/^_host_valid_models() {$/,/^}$/p' "$CLI")"
    CLAUDECODE=1 _host_valid_models | jq -R . | jq -cs .
  )
  from_verb=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 "$CLI" list-models 2>/dev/null | jq -c .)

  assert_eq "$from_helper" "$from_verb" \
    "list-models claudecode: the literal array is _host_valid_models' set, in its order"
}

test_list_models_opencode_absent_fallback() {
  echo ""
  echo "=== Testing list-models on OpenCode host with opencode binary absent — fallback with warning ==="

  local stdout stderr
  stderr=$(PATH="/usr/bin:/bin" CLAUDECODE= "$CLI" list-models 2>&1 1>/dev/null)
  stdout=$(PATH="/usr/bin:/bin" CLAUDECODE= "$CLI" list-models 2>/dev/null)

  # stdout must be a valid JSON array
  if printf '%s' "$stdout" | jq -e 'type == "array"' > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} list-models opencode-absent: output is a JSON array"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} list-models opencode-absent: output is not a JSON array: $stdout"
    ((TESTS_FAILED++))
  fi

  # Must contain the 3 built-in fallback Anthropic models
  local length
  length=$(printf '%s' "$stdout" | jq 'length' 2>/dev/null)
  assert_eq "3" "$length" "list-models opencode-absent: fallback array has 3 elements"

  # Warning must be sent to stderr
  if printf '%s' "$stderr" | grep -q "Warning: list-models"; then
    echo -e "${GREEN}✓${NC} list-models opencode-absent: warning sent to stderr"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} list-models opencode-absent: expected warning on stderr, got: $stderr"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# detect-models tier-flag Tests
# ============================================================================

test_detect_models_tier_flags_claudecode() {
  echo ""
  echo "=== Testing detect-models category flags (--research/--review/--design/--workflow/--executor) on Claude Code host ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  local stdout
  stdout=$(AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" detect-models \
    --research haiku --review opus --design sonnet --workflow haiku --executor sonnet 2>/dev/null)

  # models.json must be written
  if [ -f "$tmpdir/models.json" ]; then
    echo -e "${GREEN}✓${NC} detect-models tier-flags claudecode: models.json written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models tier-flags claudecode: models.json not found in $tmpdir"
    ((TESTS_FAILED++))
  fi

  # stdout must be valid JSON
  if printf '%s' "$stdout" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models tier-flags claudecode: stdout is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models tier-flags claudecode: stdout is not valid JSON: $stdout"
    ((TESTS_FAILED++))
  fi

  # schemaVersion must be "2.0"
  local schema_ver
  schema_ver=$(printf '%s' "$stdout" | jq -r '.schemaVersion // empty' 2>/dev/null)
  assert_eq "2.0" "$schema_ver" "detect-models tier-flags claudecode: schemaVersion is 2.0"

  # on-disk file must also contain schemaVersion 2.0
  local disk_schema
  disk_schema=$(jq -r '.schemaVersion // empty' "$tmpdir/models.json" 2>/dev/null)
  assert_eq "2.0" "$disk_schema" "detect-models tier-flags claudecode: on-disk schemaVersion is 2.0"

  # categories.claudeCode must have all five keys populated from the flag values
  local research_val review_val design_val workflow_val executor_val
  research_val=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.research // empty' 2>/dev/null)
  review_val=$(printf '%s' "$stdout"   | jq -r '.categories.claudeCode.review   // empty' 2>/dev/null)
  design_val=$(printf '%s' "$stdout"   | jq -r '.categories.claudeCode.design   // empty' 2>/dev/null)
  workflow_val=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.workflow  // empty' 2>/dev/null)
  executor_val=$(printf '%s' "$stdout" | jq -r '.categories.claudeCode.executor  // empty' 2>/dev/null)
  assert_eq "haiku"  "$research_val"  "detect-models tier-flags claudecode: research=haiku"
  assert_eq "opus"   "$review_val"    "detect-models tier-flags claudecode: review=opus"
  assert_eq "sonnet" "$design_val"    "detect-models tier-flags claudecode: design=sonnet"
  assert_eq "haiku"  "$workflow_val"  "detect-models tier-flags claudecode: workflow=haiku"
  assert_eq "sonnet" "$executor_val"  "detect-models tier-flags claudecode: executor=sonnet"
}

test_detect_models_tier_flags_preserve_other_host() {
  echo ""
  echo "=== Testing detect-models category flags preserve the other host's categories sub-table ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Pre-populate with a v2.0 opencode categories block
  printf '%s\n' '{
    "schemaVersion": "2.0",
    "categories": {
      "opencode": {
        "research":  "anthropic/claude-sonnet-4-6",
        "review":    "anthropic/claude-opus-4-7",
        "design":    "anthropic/claude-sonnet-4-6",
        "workflow":  "anthropic/claude-haiku-4-5",
        "executor":  "anthropic/claude-haiku-4-5"
      }
    }
  }' > "$tmpdir/models.json"

  # Run detect-models with category flags as Claude Code host
  AIMI_CONFIG_DIR="$tmpdir" CLAUDECODE=1 "$CLI" detect-models \
    --research haiku --review opus --design sonnet --workflow haiku --executor sonnet 2>/dev/null

  local result
  result=$(cat "$tmpdir/models.json" 2>/dev/null)

  # Overall result must be valid JSON
  if printf '%s' "$result" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models tier-flags preserve: merged models.json is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models tier-flags preserve: merged models.json is not valid JSON: $result"
    ((TESTS_FAILED++))
  fi

  # schemaVersion must be "2.0"
  local schema_ver
  schema_ver=$(printf '%s' "$result" | jq -r '.schemaVersion // empty' 2>/dev/null)
  assert_eq "2.0" "$schema_ver" "detect-models tier-flags preserve: schemaVersion is 2.0"

  # The opencode categories block must still be present with original values
  local oc_research oc_review oc_design oc_workflow oc_executor
  oc_research=$(printf '%s' "$result" | jq -r '.categories.opencode.research // empty' 2>/dev/null)
  oc_review=$(printf '%s' "$result"   | jq -r '.categories.opencode.review   // empty' 2>/dev/null)
  oc_design=$(printf '%s' "$result"   | jq -r '.categories.opencode.design   // empty' 2>/dev/null)
  oc_workflow=$(printf '%s' "$result" | jq -r '.categories.opencode.workflow  // empty' 2>/dev/null)
  oc_executor=$(printf '%s' "$result" | jq -r '.categories.opencode.executor  // empty' 2>/dev/null)
  assert_eq "anthropic/claude-sonnet-4-6" "$oc_research"  "detect-models tier-flags preserve: opencode.research preserved"
  assert_eq "anthropic/claude-opus-4-7"   "$oc_review"    "detect-models tier-flags preserve: opencode.review preserved"
  assert_eq "anthropic/claude-sonnet-4-6" "$oc_design"    "detect-models tier-flags preserve: opencode.design preserved"
  assert_eq "anthropic/claude-haiku-4-5"  "$oc_workflow"  "detect-models tier-flags preserve: opencode.workflow preserved"
  assert_eq "anthropic/claude-haiku-4-5"  "$oc_executor"  "detect-models tier-flags preserve: opencode.executor preserved"

  # The claudeCode categories block must reflect the new flag values
  local cc_research cc_review cc_design cc_workflow cc_executor
  cc_research=$(printf '%s' "$result" | jq -r '.categories.claudeCode.research // empty' 2>/dev/null)
  cc_review=$(printf '%s' "$result"   | jq -r '.categories.claudeCode.review   // empty' 2>/dev/null)
  cc_design=$(printf '%s' "$result"   | jq -r '.categories.claudeCode.design   // empty' 2>/dev/null)
  cc_workflow=$(printf '%s' "$result" | jq -r '.categories.claudeCode.workflow  // empty' 2>/dev/null)
  cc_executor=$(printf '%s' "$result" | jq -r '.categories.claudeCode.executor  // empty' 2>/dev/null)
  assert_eq "haiku"  "$cc_research"  "detect-models tier-flags preserve: claudeCode.research written"
  assert_eq "opus"   "$cc_review"    "detect-models tier-flags preserve: claudeCode.review written"
  assert_eq "sonnet" "$cc_design"    "detect-models tier-flags preserve: claudeCode.design written"
  assert_eq "haiku"  "$cc_workflow"  "detect-models tier-flags preserve: claudeCode.workflow written"
  assert_eq "sonnet" "$cc_executor"  "detect-models tier-flags preserve: claudeCode.executor written"
}

test_detect_models_preserves_other_host() {
  echo ""
  echo "=== Testing detect-models (OpenCode host) preserves existing claudeCode categories block ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Prime models.json with a complete v2.0 claudeCode block
  local primed_cc_block='{"research":"haiku","review":"opus","design":"sonnet","workflow":"haiku","executor":"sonnet"}'
  printf '%s\n' "{
    \"schemaVersion\": \"2.0\",
    \"categories\": {
      \"claudeCode\": $primed_cc_block
    }
  }" > "$tmpdir/models.json"

  # Capture the claudeCode block before the run (compact form for byte-identical comparison)
  local before_cc
  before_cc=$(jq -c '.categories.claudeCode' "$tmpdir/models.json" 2>/dev/null)

  # Run detect-models on the OpenCode host (unset CLAUDECODE) with all five category flags
  CLAUDECODE= AIMI_CONFIG_DIR="$tmpdir" "$CLI" detect-models \
    --research "anthropic/claude-sonnet-4-6" \
    --review   "anthropic/claude-opus-4-7" \
    --design   "anthropic/claude-sonnet-4-6" \
    --workflow  "anthropic/claude-haiku-4-5" \
    --executor  "anthropic/claude-haiku-4-5" 2>/dev/null

  local result
  result=$(cat "$tmpdir/models.json" 2>/dev/null)

  # The claudeCode block must be byte-identical to the primed value
  local after_cc
  after_cc=$(printf '%s' "$result" | jq -c '.categories.claudeCode' 2>/dev/null)

  if [ "$before_cc" = "$after_cc" ]; then
    echo -e "${GREEN}✓${NC} detect-models preserves-other-host: claudeCode block unchanged"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models preserves-other-host: claudeCode block changed (before=$before_cc, after=$after_cc)"
    ((TESTS_FAILED++))
  fi

  # The new opencode block must reflect the flag values passed to the run
  local oc_research oc_review oc_design oc_workflow oc_executor
  oc_research=$(printf '%s' "$result" | jq -r '.categories.opencode.research // empty' 2>/dev/null)
  oc_review=$(printf '%s' "$result"   | jq -r '.categories.opencode.review   // empty' 2>/dev/null)
  oc_design=$(printf '%s' "$result"   | jq -r '.categories.opencode.design   // empty' 2>/dev/null)
  oc_workflow=$(printf '%s' "$result" | jq -r '.categories.opencode.workflow  // empty' 2>/dev/null)
  oc_executor=$(printf '%s' "$result" | jq -r '.categories.opencode.executor  // empty' 2>/dev/null)
  assert_eq "anthropic/claude-sonnet-4-6" "$oc_research"  "detect-models preserves-other-host: opencode.research written"
  assert_eq "anthropic/claude-opus-4-7"   "$oc_review"    "detect-models preserves-other-host: opencode.review written"
  assert_eq "anthropic/claude-sonnet-4-6" "$oc_design"    "detect-models preserves-other-host: opencode.design written"
  assert_eq "anthropic/claude-haiku-4-5"  "$oc_workflow"  "detect-models preserves-other-host: opencode.workflow written"
  assert_eq "anthropic/claude-haiku-4-5"  "$oc_executor"  "detect-models preserves-other-host: opencode.executor written"

  # Overall result must be valid JSON
  if printf '%s' "$result" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models preserves-other-host: merged models.json is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models preserves-other-host: merged models.json is not valid JSON: $result"
    ((TESTS_FAILED++))
  fi
}

# detect-models (DEFAULT mode, no flags) must also preserve the OTHER host's
# sub-table. Previously only the FLAG-mode branch merged; the no-flag branch
# wrote a fresh {schemaVersion, categories:{<current host>:{...}}} and silently
# dropped the inactive host's configured models on every invocation.
# Regression coverage for that bug.
test_detect_models_default_mode_preserves_other_host() {
  echo ""
  echo "=== Testing detect-models (DEFAULT mode, no flags) preserves the other host's block ==="

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  # Prime models.json with both hosts populated — opencode block carries
  # provider-specific model IDs that the test will assert survive untouched.
  local primed_oc_block='{"research":"deepseek/deepseek-v4-flash","review":"zai-coding-plan/glm-5.1","design":"zai-coding-plan/glm-5.1","workflow":"deepseek/deepseek-v4-flash","executor":"deepseek/deepseek-v4-pro"}'
  printf '%s\n' "{
    \"schemaVersion\": \"2.0\",
    \"categories\": {
      \"claudeCode\": {\"research\":\"haiku\",\"review\":\"opus\",\"design\":\"sonnet\",\"workflow\":\"sonnet\",\"executor\":\"sonnet\"},
      \"opencode\": $primed_oc_block
    }
  }" > "$tmpdir/models.json"

  local before_oc
  before_oc=$(jq -c '.categories.opencode' "$tmpdir/models.json" 2>/dev/null)

  # Run detect-models on the Claude Code host with NO flags (default mode).
  # Stdin is not a TTY here, so the prompt loop is skipped and the run uses
  # the default haiku/opus/sonnet selections for claudeCode.
  CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" "$CLI" detect-models </dev/null >/dev/null 2>&1

  local result
  result=$(cat "$tmpdir/models.json" 2>/dev/null)

  # The opencode block must be byte-identical to the primed value
  local after_oc
  after_oc=$(printf '%s' "$result" | jq -c '.categories.opencode' 2>/dev/null)

  if [ "$before_oc" = "$after_oc" ]; then
    echo -e "${GREEN}✓${NC} detect-models default-mode-preserves: opencode block unchanged"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models default-mode-preserves: opencode block changed"
    echo "  before: $before_oc"
    echo "  after:  $after_oc"
    ((TESTS_FAILED++))
  fi

  # The claudeCode block must be present (with the default model selections)
  local cc_count
  cc_count=$(printf '%s' "$result" | jq '.categories.claudeCode | keys | length' 2>/dev/null)
  assert_eq "5" "$cc_count" "detect-models default-mode-preserves: claudeCode block has all five categories"

  if printf '%s' "$result" | jq empty 2>/dev/null; then
    echo -e "${GREEN}✓${NC} detect-models default-mode-preserves: merged models.json is valid JSON"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} detect-models default-mode-preserves: merged models.json is not valid JSON: $result"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Model-validity predicate comparison
# ============================================================================
#
# aimi-cli.sh answers "is this model id valid?" in FOUR places, and they do not
# agree with each other:
#
#   P1  cmd_resolve_models, Claude Code branch -- exact match against the set
#       {opus, sonnet, haiku}.
#   P2  cmd_resolve_models, OpenCode branch -- membership in the `opencode
#       models` list. The LIST entries are trimmed with jq's ltrimstr(" ") /
#       rtrimstr(" "), which strip ONE space each rather than all of them, and
#       the candidate id is never trimmed at all.
#   P3  cmd_detect_models flag mode -- no validation whatsoever; whatever the
#       flag carries is written into models.json verbatim.
#   P4  cmd_detect_models' nested _prompt_category -- `tr -d '[:space:]'` over
#       the answer (which deletes INTERNAL whitespace too, not just the ends),
#       then `grep -qxF` against the host's available-model list.
#
# The matrix below drives ONE table of ids through all four and asserts every
# cell, so story 04's collapse into a single predicate has a recorded
# before-state to be judged against. Where two sites disagree about one id,
# both answers are asserted rather than one averaged claim.
#
# Every predicate here gets at least one id it ACCEPTS and one it REJECTS. P3's
# rejections are not in the matrix because P3 accepts every id there is -- its
# only rejections are argument-shaped, and they are asserted with their exact
# stderr and exit status in test_detect_models_flag_mode_rejections below.
#
# ---- STORY 04 LANDED, AND THIS MATRIX IS WHERE IT IS READ OFF ---------------
# The four sites now share one shape: _normalize_model_id (trim the ends only,
# never internal), _host_valid_models (the per-host set -- DATA, not a second
# predicate), _model_id_valid_for_host (membership, no trimming of its own).
# The paragraph above is left standing as the before-state it described. Three
# cells inverted, and each is annotated beside the row it lives on:
#   P2 on the padded id  reject -> accept  (the headline fix)
#   P3 on the padded id  accept -> reject  (flag mode writes the NORMALIZED id,
#                                           so the padded string is no longer
#                                           what lands in models.json)
#   P4 on 'son net'      accept -> reject  (the second, smaller behaviour change
#                                           riding along: internal whitespace is
#                                           no longer deleted, so a typo is a
#                                           typo again rather than a repair)
# ----------------------------------------------------------------------------

# The `opencode` stub the OpenCode-branch predicate is measured against. Two
# ids, neither padded: the padding in the table is on the CANDIDATE side, which
# is where P2's asymmetry lives.
_make_opencode_stub() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/opencode" << 'OC_STUB'
#!/usr/bin/env bash
printf 'anthropic/claude-sonnet-4-6\nanthropic/claude-haiku-4-5\n'
OC_STUB
  chmod +x "$dir/opencode"
  printf '%s\n' "$dir"
}

# Lift _prompt_category out of cmd_detect_models. It is a nested function, so
# the extraction cannot key on column 0, and the `</dev/tty` redirect is
# rewritten away so the predicate can be driven without a pty. The indent is
# matched rather than counted: it was four spaces until the two assembly
# branches collapsed into one shared tail, which moved the interactive branch a
# level deeper, and a test that has to be edited for that is a test that says
# something about layout instead of about behaviour. Deleting the function
# still fails everything below, because eval of nothing leaves the calls
# unresolved. The lines the predicate actually IS are lifted from aimi-cli.sh
# untouched -- since story 04 those are the _normalize_model_id call and the
# _model_id_valid_for_host call, so the two shared helpers are lifted alongside
# it, by the same means and equally untouched.
source_prompt_category() {
  eval "$(sed -n '/^[[:space:]]*_prompt_category() {$/,/^[[:space:]]*}$/p' "$CLI" | sed 's#</dev/tty##')"
  eval "$(sed -n '/^_normalize_model_id() {$/,/^}$/p' "$CLI")"
  eval "$(sed -n '/^_model_id_valid_for_host() {$/,/^}$/p' "$CLI")"
}

# P1: resolve-models on a Claude Code host.
#
# STORY 04 changed what "accept" has to mean here. The resolver now emits the
# NORMALIZED id, so "reached stdout unchanged" would read a padded-but-accepted
# id as a rejection. The verdict is taken from the user-visible property the
# story is actually about instead: did this category silently degrade to
# "inherit"? No id in the table is the literal string "inherit", so the reading
# is unambiguous. For every unpadded id in the table the two definitions give
# the same answer -- only the padded row can tell them apart.
_predicate_p1_resolve_models_claude_code() {
  local model="$1" tmpdir out
  tmpdir=$(mktemp -d)
  jq -n --arg m "$model" '{schemaVersion:"2.0",categories:{claudeCode:{
    research:$m,review:"sonnet",design:"sonnet",workflow:"sonnet",executor:"sonnet"}}}' \
    > "$tmpdir/models.json"
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" resolve-models 2>/dev/null | jq -r '.research')
  rm -rf "$tmpdir"
  if [ "$out" = "inherit" ]; then printf 'reject\n'; else printf 'accept\n'; fi
}

# P2: resolve-models on an OpenCode host, against the stub in _OC_STUB_DIR.
# Same "did it degrade to inherit?" reading as P1, for the same reason.
_predicate_p2_resolve_models_opencode() {
  local model="$1" tmpdir out
  tmpdir=$(mktemp -d)
  jq -n --arg m "$model" '{schemaVersion:"2.0",categories:{opencode:{
    research:$m,review:"anthropic/claude-haiku-4-5",design:"anthropic/claude-haiku-4-5",
    workflow:"anthropic/claude-haiku-4-5",executor:"anthropic/claude-haiku-4-5"}}}' \
    > "$tmpdir/models.json"
  out=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$_OC_STUB_DIR:$PATH" \
    AIMI_CONFIG_DIR="$tmpdir" bash "$CLI" resolve-models 2>/dev/null | jq -r '.research')
  rm -rf "$tmpdir"
  if [ "$out" = "inherit" ]; then printf 'reject\n'; else printf 'accept\n'; fi
}

# P3: detect-models flag mode. "accept" means the id reached models.json verbatim.
_predicate_p3_detect_models_flag() {
  local model="$1" tmpdir written
  tmpdir=$(mktemp -d)
  env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --research "$model" --review opus --design sonnet \
      --workflow sonnet --executor sonnet > /dev/null 2>&1 < /dev/null
  written=$(jq -r '.categories.claudeCode.research // "<absent>"' "$tmpdir/models.json" 2>/dev/null)
  rm -rf "$tmpdir"
  if [ "$written" = "$model" ]; then printf 'accept\n'; else printf 'reject\n'; fi
}

# P4: _prompt_category. The default is "opus" and no id in the table normalises
# to it, so "came back as the default" is an unambiguous reading of "rejected".
_predicate_p4_prompt_category() {
  local model="$1" out
  out=$(printf '%s\n' "$model" | _prompt_category research opus 2>/dev/null)
  if [ "$out" = "opus" ]; then printf 'reject\n'; else printf 'accept\n'; fi
}

# One table row through all four sites. Spaces in the id are rendered as U+2423
# in the assertion label so a padded id and its trimmed twin stay tellable apart
# in the transcript.
_assert_predicate_row() {
  local id="$1" want_p1="$2" want_p2="$3" want_p3="$4" want_p4="$5"
  local label
  label=$(printf '%s' "$id" | sed 's/ /␣/g')

  assert_eq "$want_p1" "$(_predicate_p1_resolve_models_claude_code "$id")" \
    "predicate P1 (resolve-models, Claude Code exact-match) on [$label]"
  assert_eq "$want_p2" "$(_predicate_p2_resolve_models_opencode "$id")" \
    "predicate P2 (resolve-models, OpenCode list-membership) on [$label]"
  assert_eq "$want_p3" "$(_predicate_p3_detect_models_flag "$id")" \
    "predicate P3 (detect-models flag mode, unvalidated) on [$label]"
  assert_eq "$want_p4" "$(_predicate_p4_prompt_category "$id")" \
    "predicate P4 (_prompt_category, whitespace-deleted grep -qxF) on [$label]"
}

test_model_validity_predicate_matrix() {
  echo ""
  echo "=== Testing the four model-validity predicates against one shared id table ==="

  _OC_STUB_DIR=$(_make_opencode_stub)
  source_prompt_category
  # Claude Code's available-model list, exactly as cmd_detect_models builds it.
  # Since story 04 that set comes from _host_valid_models, which is also what
  # list-models offers -- hence the opus/sonnet/haiku order rather than the
  # haiku/sonnet/opus one detect-models used to build for itself.
  _available_models=$'opus\nsonnet\nhaiku'
  _prompt_models="opus|sonnet|haiku"

  #                    id                                  P1     P2     P3     P4
  _assert_predicate_row "sonnet"                          accept reject accept accept
  _assert_predicate_row "anthropic/claude-sonnet-4-6"     reject accept accept reject
  # INVERTED BY STORY 04, two cells on this row. P2: the padded id is now
  # normalized before the membership question and accepted -- this is the
  # headline fix, and the reason nothing the picker offers is refused any more.
  # P3: flag mode writes the NORMALIZED id, so the padded string itself no
  # longer reaches models.json verbatim, which is what P3 calls "accept".
  _assert_predicate_row "  anthropic/claude-sonnet-4-6  " reject accept reject reject
  # INVERTED BY STORY 04, one cell. P4: _prompt_category trims the ends only
  # now, so 'son net' stays 'son net' and is refused instead of being silently
  # repaired into the valid alias 'sonnet' by `tr -d '[:space:]'`.
  _assert_predicate_row "son net"                         reject reject accept reject

  # The P3/P1 disagreement end to end, in one config file: detect-models writes
  # an id that resolve-models -- same host, same file, one command later --
  # refuses. Story 04 did NOT close this one, deliberately: flag mode keeps
  # writing an id the resolver will refuse, because /aimi:setup-models offers a
  # free-form "Other" and validation in this CLI happens at READ time. What
  # story 04 added is that flag mode now SAYS SO at write time.
  local rt rt_err rt_out rt_write_err
  rt=$(mktemp -d)
  rt_write_err=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$rt" bash "$CLI" detect-models \
    --research anthropic/claude-sonnet-4-6 --review opus --design sonnet \
    --workflow sonnet --executor sonnet 2>&1 1>/dev/null < /dev/null)

  assert_eq "anthropic/claude-sonnet-4-6" \
    "$(jq -r '.categories.claudeCode.research' "$rt/models.json" 2>/dev/null)" \
    "predicate round-trip: detect-models writes the id into models.json anyway"
  assert_stderr_contains "Warning: detect-models: model 'anthropic/claude-sonnet-4-6' is not valid for Claude Code host (category: research); writing it anyway — resolve-models will fall back to inherit when it reads this file" \
    "$rt_write_err" "predicate round-trip: but warns at write time about the refusal to come"

  rt_err=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$rt" \
    bash "$CLI" resolve-models 2>&1 1>/dev/null)
  rt_out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$rt" \
    bash "$CLI" resolve-models 2>/dev/null | jq -r '.research')

  assert_eq "inherit" "$rt_out" \
    "predicate round-trip: resolve-models drops that same id to inherit one command later"
  assert_stderr_contains "Warning: resolve-models: model 'anthropic/claude-sonnet-4-6' is not valid for Claude Code host (must be exactly opus, sonnet, or haiku; category: research), falling back to inherit" \
    "$rt_err" "predicate round-trip: with the exact rejection warning"

  rm -rf "$rt" "$_OC_STUB_DIR"
}

test_prompt_category_predicate_edges() {
  echo ""
  echo "=== Testing _prompt_category: whitespace deletion, then exact membership ==="

  source_prompt_category
  # The set and its order come from _host_valid_models since story 04 -- see
  # the note in test_model_validity_predicate_matrix.
  _available_models=$'opus\nsonnet\nhaiku'
  _prompt_models="opus|sonnet|haiku"

  local err out ec
  err=$(mktemp)

  # ACCEPT: the exact alias.
  out=$(printf 'sonnet\n' | _prompt_category research opus 2>"$err") && ec=0 || ec=$?
  assert_eq "sonnet" "$out" "_prompt_category: accepts the exact alias 'sonnet'"
  assert_exit_code "0" "$ec" "_prompt_category: an accepted answer exits 0"
  assert_stderr_contains "Category research — model [opus|sonnet|haiku] (default: opus): " \
    "$(cat "$err")" "_prompt_category: prompts on stderr with the available list and the default"

  # ACCEPT: a padded alias. Same verdict as before story 04, different reason --
  # it used to survive because `tr -d '[:space:]'` deleted every space, and it
  # survives now because the shared normalizer trims the ENDS. The next
  # assertion is where those two rules stop agreeing.
  assert_eq "sonnet" "$(printf '  sonnet  \n' | _prompt_category research opus 2>/dev/null)" \
    "_prompt_category: accepts a padded 'sonnet' that resolve-models rejects verbatim"
  # INVERTED BY STORY 04. The normalizer never touches internal whitespace, so
  # 'son net' is a typo again: it is refused and the category default comes
  # back, where `tr -d '[:space:]'` used to rewrite it into the valid 'sonnet'.
  assert_eq "opus" "$(printf 'son net\n' | _prompt_category research opus 2>/dev/null)" \
    "_prompt_category: refuses 'son net' -- internal whitespace is preserved, not deleted"

  # REJECT: a fully-qualified id, which is exactly what list-models offers on
  # the other host.
  out=$(printf 'anthropic/claude-sonnet-4-6\n' | _prompt_category research opus 2>"$err") && ec=0 || ec=$?
  assert_eq "opus" "$out" "_prompt_category: rejects a fully-qualified id and returns the default"
  assert_exit_code "0" "$ec" "_prompt_category: a rejected answer still exits 0 -- there is no error channel"
  assert_stderr_contains "Category research — model [opus|sonnet|haiku] (default: opus): " \
    "$(cat "$err")" "_prompt_category: the rejection is silent; the prompt is the only stderr"

  # REJECT: an empty answer.
  assert_eq "opus" "$(printf '\n' | _prompt_category research opus 2>/dev/null)" \
    "_prompt_category: an empty answer falls back to the default"

  rm -f "$err"
}

# ----------------------------------------------------------------------------
# list-models offers ids that resolve-models then rejects.
#
# THIS IS A REAL USER-FACING BUG, pinned rather than fixed: /aimi:setup-models
# lists the choices with list-models and stores them for resolve-models to read
# back, so a user can pick an offered id and silently get "inherit". STORY 04
# OWNS THE FIX -- it collapses the four predicates into one, and this test is
# what proves the fix reached the user-visible symptom.
# ----------------------------------------------------------------------------
test_list_models_offers_ids_resolve_models_rejects() {
  echo ""
  echo "=== Testing the user-visible disagreement: list-models offers, resolve-models rejects ==="

  # --- Direction 1: the OpenCode fallback list, driven into a Claude Code host.
  local offered
  offered=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="/usr/bin:/bin" \
    bash "$CLI" list-models 2>/dev/null | jq -r '.[1]')
  assert_eq "anthropic/claude-sonnet-4-6" "$offered" \
    "list-models: the OpenCode fallback offers anthropic/claude-sonnet-4-6"

  local tmpdir stderr stdout ec
  tmpdir=$(mktemp -d)
  jq -n --arg m "$offered" '{schemaVersion:"2.0",categories:{claudeCode:{
    research:$m,review:"sonnet",design:"sonnet",workflow:"sonnet",executor:"sonnet"}}}' \
    > "$tmpdir/models.json"

  stderr=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" resolve-models 2>/dev/null) && ec=0 || ec=$?

  assert_stderr_contains "Warning: resolve-models: model 'anthropic/claude-sonnet-4-6' is not valid for Claude Code host (must be exactly opus, sonnet, or haiku; category: research), falling back to inherit" \
    "$stderr" "cross-host: resolve-models rejects the id list-models offered, with the exact warning"
  assert_exit_code "0" "$ec" \
    "cross-host: the rejection is not an error -- resolve-models still exits 0"
  assert_eq "inherit" "$(printf '%s' "$stdout" | jq -r '.research')" \
    "cross-host: the offered id silently becomes inherit"
  rm -rf "$tmpdir"

  # --- Direction 2: a padded id from a real `opencode models`.
  # This half INVERTED IN STORY 04, all four assertions, and the inversion is
  # the reviewable statement of what that story changed. It used to read:
  # cmd_list_models piped the list through `jq -R .` with no trimming and
  # offered the padding verbatim, while cmd_resolve_models trimmed the LIST
  # with jq's ltrimstr(" ")/rtrimstr(" ") -- one space each, not all -- and
  # never trimmed the candidate, so BOTH the offered id and its fully-trimmed
  # form were refused and nothing the user could copy out of the list was
  # acceptable. Both sides now normalize through the one helper: list-models
  # offers the TRIMMED id, and resolve-models accepts it -- and accepts the
  # padded form too, since normalization runs before the membership question.
  local stub padded
  stub=$(mktemp -d)
  cat > "$stub/opencode" << 'OC_PAD'
#!/usr/bin/env bash
printf '  anthropic/claude-sonnet-4-6  \nanthropic/claude-haiku-4-5\n'
OC_PAD
  chmod +x "$stub/opencode"

  padded=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$stub" bash "$CLI" list-models 2>/dev/null | jq -r '.[0]')
  assert_eq "anthropic/claude-sonnet-4-6" "$padded" \
    "list-models: offers the opencode id trimmed, not with its padding intact"

  local pad_dir trim_dir
  pad_dir=$(mktemp -d)
  jq -n '{schemaVersion:"2.0",categories:{opencode:{
    research:"  anthropic/claude-sonnet-4-6  ",review:"anthropic/claude-haiku-4-5",
    design:"anthropic/claude-haiku-4-5",workflow:"anthropic/claude-haiku-4-5",
    executor:"anthropic/claude-haiku-4-5"}}}' > "$pad_dir/models.json"
  stderr=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$pad_dir" bash "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$pad_dir" bash "$CLI" resolve-models 2>/dev/null)
  assert_eq "" "$(printf '%s' "$stderr" | grep 'is not valid for OpenCode host' || true)" \
    "padded id: resolve-models no longer rejects a padded id stored by hand"
  assert_eq "anthropic/claude-sonnet-4-6" "$(printf '%s' "$stdout" | jq -r '.research')" \
    "padded id: it resolves to the trimmed id instead of becoming inherit"

  trim_dir=$(mktemp -d)
  jq -n '{schemaVersion:"2.0",categories:{opencode:{
    research:"anthropic/claude-sonnet-4-6",review:"anthropic/claude-haiku-4-5",
    design:"anthropic/claude-haiku-4-5",workflow:"anthropic/claude-haiku-4-5",
    executor:"anthropic/claude-haiku-4-5"}}}' > "$trim_dir/models.json"
  stderr=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$trim_dir" bash "$CLI" resolve-models 2>&1 1>/dev/null)
  stdout=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$trim_dir" bash "$CLI" resolve-models 2>/dev/null)
  assert_eq "" "$(printf '%s' "$stderr" | grep 'is not valid for OpenCode host' || true)" \
    "trimmed id: accepted too, because the LIST is normalized by the same rule as the candidate"
  assert_eq "anthropic/claude-sonnet-4-6" "$(printf '%s' "$stdout" | jq -r '.research')" \
    "trimmed id: what the user copies out of the offered list is what the resolver keeps"

  rm -rf "$stub" "$pad_dir" "$trim_dir"
}

# ----------------------------------------------------------------------------
# STORY 04's user-visible outcome, as one regression: every id list-models
# offers is an id resolve-models accepts.
#
# The stub emits the four lines the research reproduced, because that is a
# shape `opencode models` output genuinely has: a plain id, an id padded with
# two spaces on each side, an EMPTY line, and a second plain id. Before story
# 04, cmd_list_models piped that straight through `jq -R . | jq -s .` -- which
# neither trims nor filters -- so the picker offered the padded entry AND the
# empty string, and cmd_resolve_models then refused both the padded id and its
# fully trimmed twin: its list-side trim was jq's ltrimstr(" ")/rtrimstr(" "),
# one space each rather than all, and it never trimmed the candidate at all.
# Nothing the user could copy out of the offered list was acceptable.
#
# This is the regression guard, not scaffolding to delete once green: it stays
# green only while both sides keep asking the one shared question.
# ----------------------------------------------------------------------------
test_list_models_and_resolve_models_agree_on_every_offered_id() {
  echo ""
  echo "=== Testing that every id list-models offers is an id resolve-models accepts ==="

  local stub root offered n i id cfg stderr resolved pad
  stub=$(mktemp -d)
  cat > "$stub/opencode" << 'OC_RESEARCH'
#!/usr/bin/env bash
printf 'anthropic/claude-opus-4-7\n  anthropic/claude-sonnet-4-6  \n\nanthropic/claude-haiku-4-5\n'
OC_RESEARCH
  chmod +x "$stub/opencode"

  # Throwaway root: AIMI_CONFIG_DIR and CLAUDE_CONFIG_DIR both point at it, so
  # nothing here can reach the developer's real ~/.config/aimi/models.json or
  # ~/.claude/plugins/cache/. The stub lives on a test-local PATH only.
  root=$(mktemp -d)
  offered=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$root" CLAUDE_CONFIG_DIR="$root" bash "$CLI" list-models 2>/dev/null)

  assert_eq "3" "$(printf '%s' "$offered" | jq -r 'length')" \
    "offered set: the empty line is dropped, leaving three ids"
  assert_eq "0" "$(printf '%s' "$offered" | jq -r '[.[] | select(test("^\\s|\\s$"))] | length')" \
    "offered set: no entry carries leading or trailing whitespace"
  assert_eq "0" "$(printf '%s' "$offered" | jq -r '[.[] | select(. == "")] | length')" \
    "offered set: no entry is the empty string"
  assert_eq "anthropic/claude-opus-4-7 anthropic/claude-sonnet-4-6 anthropic/claude-haiku-4-5" \
    "$(printf '%s' "$offered" | jq -r 'join(" ")')" \
    "offered set: the three ids, in the order opencode printed them"

  # Each offered id, stored exactly as /aimi:setup-models would store it.
  n=$(printf '%s' "$offered" | jq -r 'length')
  i=0
  while [ "$i" -lt "$n" ]; do
    id=$(printf '%s' "$offered" | jq -r --argjson i "$i" '.[$i]')
    cfg=$(mktemp -d)
    jq -n --arg m "$id" '{schemaVersion:"2.0",categories:{opencode:{
      research:$m,review:$m,design:$m,workflow:$m,executor:$m}}}' > "$cfg/models.json"
    stderr=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
      AIMI_CONFIG_DIR="$cfg" CLAUDE_CONFIG_DIR="$cfg" bash "$CLI" resolve-models 2>&1 1>/dev/null)
    resolved=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
      AIMI_CONFIG_DIR="$cfg" CLAUDE_CONFIG_DIR="$cfg" bash "$CLI" resolve-models 2>/dev/null \
      | jq -r '.research')
    assert_eq "$id" "$resolved" \
      "offered id [$id]: resolve-models keeps it -- no silent degrade to inherit"
    assert_eq "" "$(printf '%s' "$stderr" | grep 'is not valid for OpenCode host' || true)" \
      "offered id [$id]: resolve-models emits no not-valid warning"
    rm -rf "$cfg"
    i=$((i + 1))
  done

  # models.json is hand-edited, so a padded id can reach the resolver without
  # ever passing through list-models. Normalization is a step applied BEFORE
  # validity, so the trimmed twin is both what gets judged and what gets
  # emitted -- a downstream consumer never receives a padded model id.
  pad=$(mktemp -d)
  jq -n '{schemaVersion:"2.0",categories:{opencode:{
    research:"  anthropic/claude-sonnet-4-6  ",review:"anthropic/claude-haiku-4-5",
    design:"anthropic/claude-haiku-4-5",workflow:"anthropic/claude-haiku-4-5",
    executor:"anthropic/claude-haiku-4-5"}}}' > "$pad/models.json"
  stderr=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$pad" CLAUDE_CONFIG_DIR="$pad" bash "$CLI" resolve-models 2>&1 1>/dev/null)
  resolved=$(env -u AIMI_PLUGIN_DIR -u CLAUDECODE PATH="$stub:$PATH" \
    AIMI_CONFIG_DIR="$pad" CLAUDE_CONFIG_DIR="$pad" bash "$CLI" resolve-models 2>/dev/null \
    | jq -r '.research')
  assert_eq "anthropic/claude-sonnet-4-6" "$resolved" \
    "hand-padded id: accepted, and emitted trimmed rather than as stored"
  assert_eq "" "$(printf '%s' "$stderr" | grep 'is not valid for OpenCode host' || true)" \
    "hand-padded id: no not-valid warning"

  rm -rf "$stub" "$root" "$pad"
}

# ----------------------------------------------------------------------------
# resolve-models' warnings, driven with hostile model ids.
#
# WHAT THIS USED TO BE MEASURING. cmd_resolve_models marked an invalid entry by
# prefixing the literal string "INVALID\t" onto the model id inside jq, then
# split that tagged value back apart in a `while IFS=$'\t' read -r _cat _val`
# loop. The tab was chosen so a model id containing "=" could not truncate the
# message -- the comment beside it recorded that the delimiter had ALREADY been
# changed once for exactly that reason. But a tab is only one of the characters
# that survives into a value, and NEWLINE was the one that broke the frame: the
# read loop is line-oriented, so a two-line model id produced TWO iterations,
# and the second reported a category that does not exist while claiming an
# empty model id.
#
# ---- STORY 05 LANDED, AND THE SCAFFOLDING IS WHERE IT IS READ OFF -----------
# There is no delimiter now. models.py parses the config once and answers the
# three questions the tag used to carry between processes -- which entries are
# invalid, what the clean result is, what to warn about -- as three expressions
# over one list of (category, model, valid) tuples. The tab, backslash and
# space rows below did NOT move: the first two are values a delimiter never
# had to survive in the first place, and the third is the normalizer's, not the
# delimiter's. THREE ASSERTIONS ON THE NEWLINE ROW INVERTED, and each is
# annotated where it stands:
#   warning count   2 -> 1  (one invalid id is one warning)
#   the message     first line only -> the WHOLE id, newline included
#   the second line fabricated 'category: opus' -> gone, and asserted absent
# Reproducing the fabricated line would have meant re-implementing the
# tab-split loop, which is the thing this story exists to delete. It is a
# named divergence, not an accident: KNOWN_DIVERGENCES in tests/test_models.py
# carries it by corpus label with what it costs.
# ----------------------------------------------------------------------------

# Run resolve-models on a Claude Code host with `model` in the research slot and
# return only its stderr.
_invalid_tag_stderr() {
  local model="$1" tmpdir out
  tmpdir=$(mktemp -d)
  jq -n --arg m "$model" '{schemaVersion:"2.0",categories:{claudeCode:{
    research:$m,review:"sonnet",design:"sonnet",workflow:"sonnet",executor:"sonnet"}}}' \
    > "$tmpdir/models.json"
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" resolve-models 2>&1 1>/dev/null)
  rm -rf "$tmpdir"
  printf '%s' "$out"
}

test_resolve_models_invalid_tag_hostile_ids() {
  echo ""
  echo "=== Testing the INVALID<TAB> tagging against hostile model ids ==="

  local suffix="is not valid for Claude Code host (must be exactly opus, sonnet, or haiku; category: research), falling back to inherit"

  # A literal TAB inside the id. `read -r _cat _val` gives the remainder of the
  # line to the last variable, so the embedded tab survives into the message.
  assert_stderr_contains "$(printf "Warning: resolve-models: model 'son\tnet' %s" "$suffix")" \
    "$(_invalid_tag_stderr "$(printf 'son\tnet')")" \
    "INVALID<TAB> edge: an id containing a tab keeps the tab in its warning"

  # INVERTED BY STORY 04, both assertions. Leading and trailing spaces used to
  # be preserved verbatim -- nothing trimmed the id on this branch, so '  sonnet'
  # and 'sonnet  ' were each tagged INVALID and warned about. The shared
  # normalizer trims the ends before the membership question is asked, so both
  # are now the alias 'sonnet' and neither reaches the INVALID<TAB> path at all.
  # The tab and backslash cases above and the newline case below did NOT invert:
  # that whitespace is INTERNAL, and the normalizer never touches internal
  # whitespace.
  assert_eq "" "$(_invalid_tag_stderr "  sonnet")" \
    "INVALID<TAB> edge: a leading space is trimmed, so 'sonnet' stays valid and nothing warns"
  assert_eq "" "$(_invalid_tag_stderr "sonnet  ")" \
    "INVALID<TAB> edge: a trailing space is trimmed, so 'sonnet' stays valid and nothing warns"

  # A backslash reaches the message uninterpreted -- neither jq's "INVALID\t"
  # construction nor the read loop re-escapes it.
  assert_stderr_contains 'Warning: resolve-models: model '"'"'son\net'"'"' '"$suffix" \
    "$(_invalid_tag_stderr 'son\net')" \
    "INVALID<TAB> edge: a backslash in the id survives uninterpreted"

  # THE NEWLINE CASE, all three assertions INVERTED BY STORY 05. The read loop
  # used to consume 'sonnet' from line 1 and then read line 2 -- 'opus', the
  # tail of the model id -- as a CATEGORY NAME with an empty model id, so one
  # invalid id produced two warnings and the second named a category that has
  # never existed. Nothing splits on lines now: one invalid category is one
  # warning, and it carries the id it was given.
  local nl_stderr nl_stdout nl_count nl_ec
  nl_stderr=$(_invalid_tag_stderr "$(printf 'sonnet\nopus')")
  nl_count=$(printf '%s\n' "$nl_stderr" | grep -c 'Warning: resolve-models')
  assert_eq "1" "$nl_count" \
    "hostile-id newline edge: ONE invalid id produces ONE warning"
  assert_stderr_contains "$(printf "Warning: resolve-models: model 'sonnet\nopus' %s" "$suffix")" \
    "$nl_stderr" \
    "hostile-id newline edge: the warning carries the WHOLE id, newline included"
  assert_eq "" "$(printf '%s\n' "$nl_stderr" | grep 'category: opus' || true)" \
    "hostile-id newline edge: no fabricated warning names a category that does not exist"

  local nl_dir
  nl_dir=$(mktemp -d)
  jq -n --arg m "$(printf 'sonnet\nopus')" '{schemaVersion:"2.0",categories:{claudeCode:{
    research:$m,review:"sonnet",design:"sonnet",workflow:"sonnet",executor:"sonnet"}}}' \
    > "$nl_dir/models.json"
  nl_stdout=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$nl_dir" \
    bash "$CLI" resolve-models 2>/dev/null) && nl_ec=0 || nl_ec=$?

  assert_eq "design executor research review workflow" \
    "$(printf '%s' "$nl_stdout" | jq -r 'keys | join(" ")')" \
    "INVALID<TAB> newline edge: stdout still carries the five real categories -- 'opus' is not one"
  assert_eq "inherit" "$(printf '%s' "$nl_stdout" | jq -r '.research')" \
    "INVALID<TAB> newline edge: the multi-line id falls back to inherit"
  assert_exit_code "0" "$nl_ec" \
    "INVALID<TAB> newline edge: the fabricated warning does not change the exit status"

  rm -rf "$nl_dir"
}

# ----------------------------------------------------------------------------
# detect-models' argument rejections.
#
# The writer path itself is covered by test_detect_models_tier_flags_claudecode
# (schema-v2.0 write of all five categories) and
# test_detect_models_tier_flags_preserve_other_host (the other host's sub-table
# survives a re-run). What neither reaches is the refusal: this verb WRITES the
# file every later command reads, so what it declines to write matters.
# ----------------------------------------------------------------------------
test_detect_models_flag_mode_rejections() {
  echo ""
  echo "=== Testing detect-models: partial flag set and unknown flag are both refused ==="

  local tmpdir err out ec
  tmpdir=$(mktemp -d)
  err="$tmpdir/stderr"

  # Partial flag set: two of the five.
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --research haiku --review opus 2>"$err" < /dev/null) \
    && ec=0 || ec=$?

  assert_exit_code "1" "$ec" "detect-models (partial flags): exits 1"
  assert_stderr_contains "Error: detect-models: when using category flags, all five must be provided: --research, --review, --design, --workflow, --executor" \
    "$(cat "$err")" "detect-models (partial flags): exact error on stderr"
  assert_eq "" "$out" "detect-models (partial flags): stdout stays empty"
  assert_eq "no" "$([ -e "$tmpdir/models.json" ] && echo yes || echo no)" \
    "detect-models (partial flags): models.json is not written"

  # Unknown flag.
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --bogus x 2>"$err" < /dev/null) && ec=0 || ec=$?

  assert_exit_code "1" "$ec" "detect-models (unknown flag): exits 1"
  assert_stderr_contains "Error: detect-models: unknown flag: --bogus" \
    "$(cat "$err")" "detect-models (unknown flag): exact error on stderr"
  assert_stderr_contains "Usage: aimi-cli.sh detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]" \
    "$(cat "$err")" "detect-models (unknown flag): exact usage line on stderr"
  assert_eq "no" "$([ -e "$tmpdir/models.json" ] && echo yes || echo no)" \
    "detect-models (unknown flag): models.json is not written"

  rm -rf "$tmpdir"
}

# ----------------------------------------------------------------------------
# detect-models flag mode after story 04: it validates, and it says so.
#
# The boundary this test draws is deliberate and is stated in story 04's commit:
# a merely-INVALID id still WRITES and still exits 0, because /aimi:setup-models
# writes through this path (its picker offers a free-form "Other") and this
# CLI's discipline is that an id is refused at READ time, by resolve-models.
# What flag mode gains is the warning, so the refusal one command later is no
# longer a surprise. The ONE new hard error is the case that is an argument
# mistake rather than a wrong id: a value that is non-empty but normalizes to
# empty, which takes the same path as the pre-existing "all five must be
# provided" check above.
# ----------------------------------------------------------------------------
test_detect_models_flag_mode_normalizes_and_warns() {
  echo ""
  echo "=== Testing detect-models flag mode: normalizes what it writes, warns on an invalid id ==="

  local tmpdir err out ec

  # A padded but valid id: the NORMALIZED id is what lands in models.json, and
  # nothing warns -- it is a valid id, merely typed with padding.
  tmpdir=$(mktemp -d)
  err="$tmpdir/stderr"
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --research "  sonnet  " --review opus --design sonnet \
      --workflow sonnet --executor sonnet 2>"$err" < /dev/null) && ec=0 || ec=$?

  assert_exit_code "0" "$ec" "detect-models (padded valid id): exits 0"
  assert_eq "sonnet" "$(jq -r '.categories.claudeCode.research' "$tmpdir/models.json" 2>/dev/null)" \
    "detect-models (padded valid id): writes the trimmed id, not the padded one"
  assert_eq "sonnet" "$(printf '%s' "$out" | jq -r '.categories.claudeCode.research')" \
    "detect-models (padded valid id): its stdout reports the trimmed id too"
  assert_eq "" "$(grep 'is not valid for' "$err" || true)" \
    "detect-models (padded valid id): a valid id typed with padding draws no warning"
  rm -rf "$tmpdir"

  # An id that is not valid for this host: warned about, written anyway, exit 0.
  tmpdir=$(mktemp -d)
  err="$tmpdir/stderr"
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --research anthropic/claude-sonnet-4-6 --review opus \
      --design sonnet --workflow sonnet --executor sonnet 2>"$err" < /dev/null) && ec=0 || ec=$?

  assert_exit_code "0" "$ec" \
    "detect-models (invalid id): exits 0 -- an invalid id is not a new failure mode here"
  assert_stderr_contains "Warning: detect-models: model 'anthropic/claude-sonnet-4-6' is not valid for Claude Code host (category: research); writing it anyway — resolve-models will fall back to inherit when it reads this file" \
    "$(cat "$err")" "detect-models (invalid id): exact warning on stderr"
  assert_eq "anthropic/claude-sonnet-4-6" \
    "$(jq -r '.categories.claudeCode.research' "$tmpdir/models.json" 2>/dev/null)" \
    "detect-models (invalid id): written anyway -- validation stays a read-time concern"
  rm -rf "$tmpdir"

  # Whitespace only: the one NEW hard error. It passes the "all five provided"
  # check (the string is non-empty) and fails on normalizing to nothing.
  tmpdir=$(mktemp -d)
  err="$tmpdir/stderr"
  out=$(env -u AIMI_PLUGIN_DIR CLAUDECODE=1 AIMI_CONFIG_DIR="$tmpdir" \
    bash "$CLI" detect-models --research "   " --review opus --design sonnet \
      --workflow sonnet --executor sonnet 2>"$err" < /dev/null) && ec=0 || ec=$?

  assert_exit_code "1" "$ec" "detect-models (whitespace-only value): exits 1"
  assert_stderr_contains "Error: detect-models: --research value is whitespace only, which is not a model id" \
    "$(cat "$err")" "detect-models (whitespace-only value): exact error on stderr"
  assert_eq "" "$out" "detect-models (whitespace-only value): stdout stays empty"
  assert_eq "no" "$([ -e "$tmpdir/models.json" ] && echo yes || echo no)" \
    "detect-models (whitespace-only value): models.json is not written"
  rm -rf "$tmpdir"
}

# ============================================================================
# story-merge Tests
# ============================================================================

# Helper: create a minimal staging story JSON file
_sm_make_story() {
  local path="$1"
  local title="${2:-Story}"
  local depends="${3:-[]}"
  cat > "$path" << EOF
{
  "title": "$title",
  "description": "As a developer, I want $title so that it works.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": $depends,
  "notes": ""
}
EOF
}

# TC1: Happy path — three staging files produce US-001..003 with contiguous waves
test_story_merge_happy_path() {
  echo ""
  echo "=== TC1: story-merge happy path ==="

  # Use paths inside the project (TEST_DIR == cwd after main cd "$TEST_DIR")
  local stg=".aimi/.tasks-staging-tc1"
  local out_file=".aimi/tasks/sm-tc1-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Create 3 staging files in lex order: 01, 02, 03
  _sm_make_story "$stg/01-setup.json"   "Setup story"
  _sm_make_story "$stg/02-core.json"    "Core story"  '["outline:01"]'
  _sm_make_story "$stg/03-ui.json"      "UI story"    '["outline:02"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC1: story-merge happy path exits 0"

  # Output file must exist
  if [ -f "$out_file" ]; then
    echo -e "${GREEN}✓${NC} TC1: output file written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC1: output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  # IDs should be US-001, US-002, US-003
  if [ -f "$out_file" ]; then
    local ids
    ids=$(jq -r '[.userStories[].id] | join(",")' "$out_file" 2>/dev/null)
    assert_eq "US-001,US-002,US-003" "$ids" "TC1: IDs are US-001,US-002,US-003"

    # Waves: US-001 wave 1, US-002 wave 2, US-003 wave 3
    local waves
    waves=$(jq -r '[.userStories[].wave] | join(",")' "$out_file" 2>/dev/null)
    assert_eq "1,2,3" "$waves" "TC1: waves are 1,2,3 (contiguous)"

    # dependsOn remapped from outline:NN to US-NNN
    local dep2
    dep2=$(jq -r '.userStories[] | select(.id == "US-002") | .dependsOn[0]' "$out_file" 2>/dev/null)
    assert_eq "US-001" "$dep2" "TC1: outline:01 remapped to US-001"
  fi

  # Staging dir should be deleted on success
  if [ ! -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC1: staging dir deleted on success"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC1: staging dir NOT deleted on success"
    ((TESTS_FAILED++))
    rm -rf "$stg"
  fi

  rm -f "$out_file"
}

# TC2: Missing staging dir → non-zero exit
test_story_merge_missing_dir() {
  echo ""
  echo "=== TC2: story-merge missing staging dir ==="

  # Use a staging dir that doesn't exist but has a path inside project
  local stg=".aimi/.tasks-staging-nonexistent-tc2-$$"
  local out_file=".aimi/tasks/sm-tc2-tasks.json"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC2: missing staging dir exits 1"
  assert_contains "does not exist" "$output" "TC2: error mentions 'does not exist'"
}

# TC3: Malformed JSON in staging file → non-zero exit with filename in error
test_story_merge_malformed_json() {
  echo ""
  echo "=== TC3: story-merge malformed JSON ==="

  local stg=".aimi/.tasks-staging-tc3"
  local out_file=".aimi/tasks/sm-tc3-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-good.json" "Good story"
  printf '{ "title": "Bad, unclosed' > "$stg/02-bad.json"  # malformed JSON

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC3: malformed JSON exits 1"
  assert_contains "02-bad.json" "$output" "TC3: offending filename in error"

  # Staging dir preserved on error
  if [ -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC3: staging dir preserved on error"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC3: staging dir should be preserved on error"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg"
}

# TC4: Duplicate numeric index prefix → non-zero exit
test_story_merge_duplicate_index() {
  echo ""
  echo "=== TC4: story-merge duplicate index prefix ==="

  local stg=".aimi/.tasks-staging-tc4"
  local out_file=".aimi/tasks/sm-tc4-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-alpha.json" "Alpha"
  _sm_make_story "$stg/01-beta.json"  "Beta"   # same '01' prefix

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC4: duplicate index exits 1"
  assert_contains "duplicate index" "$output" "TC4: error mentions 'duplicate index'"

  rm -rf "$stg"
}

# TC5: Circular dependsOn cycle → non-zero exit naming cycle stories
test_story_merge_cycle() {
  echo ""
  echo "=== TC5: story-merge DAG cycle ==="

  local stg=".aimi/.tasks-staging-tc5"
  local out_file=".aimi/tasks/sm-tc5-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Create two stories that depend on each other via outline tokens
  _sm_make_story "$stg/01-a.json" "Story A" '["outline:02"]'
  _sm_make_story "$stg/02-b.json" "Story B" '["outline:01"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC5: cycle exits 1"
  assert_contains "circular" "$output" "TC5: error mentions 'circular'"

  rm -rf "$stg"
}

# TC6: Dangling outline reference → non-zero exit naming missing reference
test_story_merge_dangling_ref() {
  echo ""
  echo "=== TC6: story-merge dangling outline ref ==="

  local stg=".aimi/.tasks-staging-tc6"
  local out_file=".aimi/tasks/sm-tc6-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # outline:99 doesn't exist (only 1 story at index 01)
  _sm_make_story "$stg/01-story.json" "Story A" '["outline:99"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC6: dangling ref exits 1"
  assert_contains "unresolved outline" "$output" "TC6: error mentions unresolved outline reference"

  rm -rf "$stg"
}

# TC7: Rule 22 mock-sync AC routing — schema story with consumer
test_story_merge_rule22_routing() {
  echo ""
  echo "=== TC7: story-merge Rule 22 mock-sync AC routing ==="

  local stg=".aimi/.tasks-staging-tc7"
  local out_file=".aimi/tasks/sm-tc7-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Story 1: schema-extending (matches schema glob via .schema.ts)
  cat > "$stg/01-schema.json" << 'EOF'
{
  "title": "Add UserProfile schema",
  "description": "As a developer, I want a UserProfile schema so that user data is typed.",
  "acceptanceCriteria": [
    "Typecheck passes",
    "Update mock data in matching **/mocks/** path to populate new fields (or document why mocks are intentionally unchanged)."
  ],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/types/UserProfile.schema.ts"],
    "approach": "Add UserProfile type",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Story 2: consumer — references "UserProfile" in description
  cat > "$stg/02-consumer.json" << 'EOF'
{
  "title": "UserProfile display page",
  "description": "As a user, I want to view my UserProfile so that I can see my data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "notes": ""
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC7: Rule 22 routing exits 0"

  if [ -f "$out_file" ]; then
    # The mock-sync AC should be on the consumer (US-002), not the schema story (US-001)
    local consumer_has_mock schema_has_mock
    local mock_pattern="[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"
    consumer_has_mock=$(jq -r --arg p "$mock_pattern" '.userStories[] | select(.id == "US-002") | .acceptanceCriteria[] | select(test($p; ""))' "$out_file" 2>/dev/null)
    schema_has_mock=$(jq -r --arg p "$mock_pattern" '.userStories[] | select(.id == "US-001") | .acceptanceCriteria[] | select(test($p; ""))' "$out_file" 2>/dev/null)

    if [ -n "$consumer_has_mock" ]; then
      echo -e "${GREEN}✓${NC} TC7: mock-sync AC routed to consumer"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC7: mock-sync AC NOT on consumer"
      echo "  consumer ACs: $(jq -r '.userStories[] | select(.id == "US-002") | .acceptanceCriteria[]' "$out_file" 2>/dev/null)"
      ((TESTS_FAILED++))
    fi

    if [ -z "$schema_has_mock" ]; then
      echo -e "${GREEN}✓${NC} TC7: mock-sync AC removed from schema story"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC7: mock-sync AC still on schema story (should have been moved)"
      ((TESTS_FAILED++))
    fi
  fi

  rm -f "$out_file"
}

# TC8: Full-stack split — two output files with unique IDs and independent waves
test_story_merge_full_stack_split() {
  echo ""
  echo "=== TC8: story-merge --split full-stack ==="

  local stg=".aimi/.tasks-staging-tc8"
  local out_file=".aimi/tasks/sm-tc8-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Frontend story
  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Backend story
  cat > "$stg/02-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC8: full-stack split exits 0"

  local fe_file=".aimi/tasks/sm-tc8-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc8-tasks-backend-tasks.json"

  # Both output files must exist
  if [ -f "$fe_file" ]; then
    echo -e "${GREEN}✓${NC} TC8: frontend tasks file written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC8: frontend tasks file missing ($fe_file)"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if [ -f "$be_file" ]; then
    echo -e "${GREEN}✓${NC} TC8: backend tasks file written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC8: backend tasks file missing ($be_file)"
    ((TESTS_FAILED++))
  fi

  if [ -f "$fe_file" ] && [ -f "$be_file" ]; then
    # IDs unique across both files
    local fe_ids be_ids
    fe_ids=$(jq -r '[.userStories[].id] | .[]' "$fe_file" 2>/dev/null)
    be_ids=$(jq -r '[.userStories[].id] | .[]' "$be_file" 2>/dev/null)

    # No ID should appear in both files
    local collision
    collision=$(printf '%s\n%s\n' "$fe_ids" "$be_ids" | sort | uniq -d)
    if [ -z "$collision" ]; then
      echo -e "${GREEN}✓${NC} TC8: no ID collisions across frontend/backend files"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC8: ID collision found: $collision"
      ((TESTS_FAILED++))
    fi

    # Each file has wave 1 for its roots
    local fe_wave1 be_wave1
    fe_wave1=$(jq '[.userStories[] | select(.dependsOn == []) | .wave] | all(. == 1)' "$fe_file" 2>/dev/null)
    be_wave1=$(jq '[.userStories[] | select(.dependsOn == []) | .wave] | all(. == 1)' "$be_file" 2>/dev/null)
    assert_eq "true" "$fe_wave1" "TC8: frontend root stories have wave 1"
    assert_eq "true" "$be_wave1" "TC8: backend root stories have wave 1"
  fi

  # Staging dir deleted on success
  if [ ! -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC8: staging dir deleted on success"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC8: staging dir NOT deleted on success"
    ((TESTS_FAILED++))
    rm -rf "$stg"
  fi

  rm -f "$fe_file" "$be_file" "$out_file"
}

# TC12: Full-stack split + --phase-aware — phase-scoped output path collapses
# the split basenames to a single "tasks" segment instead of TC8's legacy
# double-"tasks" form (US-013).
test_story_merge_phase_aware_split() {
  echo ""
  echo "=== TC12: story-merge --split full-stack --phase-aware ==="

  local stg=".aimi/.tasks-staging-tc12"
  local phase_dir=".aimi/tasks/tc12-feature/phase-2-slug"
  local out_file="${phase_dir}/tc12-feature-phase-2-tasks.json"
  rm -rf "$stg" "$phase_dir"
  mkdir -p "$stg" "$phase_dir"

  # Frontend story
  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Backend story
  cat > "$stg/02-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack --phase-aware 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC12: full-stack split --phase-aware exits 0"

  local fe_file="${phase_dir}/tc12-feature-phase-2-frontend-tasks.json"
  local be_file="${phase_dir}/tc12-feature-phase-2-backend-tasks.json"
  local fe_file_legacy_shape="${phase_dir}/tc12-feature-phase-2-tasks-frontend-tasks.json"
  local be_file_legacy_shape="${phase_dir}/tc12-feature-phase-2-tasks-backend-tasks.json"

  # Single-"tasks"-segment basenames must exist
  if [ -f "$fe_file" ]; then
    echo -e "${GREEN}✓${NC} TC12: frontend tasks file written with single-'tasks' basename ($fe_file)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC12: frontend tasks file missing ($fe_file)"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if [ -f "$be_file" ]; then
    echo -e "${GREEN}✓${NC} TC12: backend tasks file written with single-'tasks' basename ($be_file)"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC12: backend tasks file missing ($be_file)"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  # The legacy double-"tasks" basename must NOT be produced when --phase-aware is set
  if [ ! -f "$fe_file_legacy_shape" ] && [ ! -f "$be_file_legacy_shape" ]; then
    echo -e "${GREEN}✓${NC} TC12: --phase-aware suppresses the legacy double-'tasks' basename"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC12: legacy double-'tasks' basename was produced despite --phase-aware ($fe_file_legacy_shape)"
    ((TESTS_FAILED++))
  fi

  if [ -f "$fe_file" ] && [ -f "$be_file" ]; then
    local fe_ids be_ids collision
    fe_ids=$(jq -r '[.userStories[].id] | .[]' "$fe_file" 2>/dev/null)
    be_ids=$(jq -r '[.userStories[].id] | .[]' "$be_file" 2>/dev/null)
    collision=$(printf '%s\n%s\n' "$fe_ids" "$be_ids" | sort | uniq -d)
    if [ -z "$collision" ]; then
      echo -e "${GREEN}✓${NC} TC12: no ID collisions across frontend/backend files"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC12: ID collision found: $collision"
      ((TESTS_FAILED++))
    fi
  fi

  rm -rf "$stg" "${phase_dir%/*}"
}

# TC9: outline.json sidecar in staging dir is ignored (Phase 3b artifact)
test_story_merge_outline_sidecar_ignored() {
  echo ""
  echo "=== TC9: story-merge ignores outline.json sidecar ==="

  local stg=".aimi/.tasks-staging-tc9"
  local out_file=".aimi/tasks/sm-tc9-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Two real stories
  _sm_make_story "$stg/01-setup.json" "Setup story"
  _sm_make_story "$stg/02-core.json"  "Core story" '["outline:01"]'

  # Phase 3b sidecar (NOT a story — would crash story-merge if not filtered)
  cat > "$stg/outline.json" << 'EOF'
[
  {"idx": "01", "title": "Setup story", "summary": "scaffold things"},
  {"idx": "02", "title": "Core story",  "summary": "do work"}
]
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC9: outline.json sidecar does not crash story-merge"

  # Only two real stories merged (outline.json must be ignored)
  if [ -f "$out_file" ]; then
    local count
    count=$(jq -r '.userStories | length' "$out_file" 2>/dev/null)
    assert_eq "2" "$count" "TC9: only 2 real stories merged (outline.json filtered)"

    local ids
    ids=$(jq -r '[.userStories[].id] | join(",")' "$out_file" 2>/dev/null)
    assert_eq "US-001,US-002" "$ids" "TC9: IDs are US-001,US-002 (no phantom US-003 from outline.json)"
  fi

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC10: Phase 4.2 orphan-symbol smell — positive: story adds orphanHelper (camelCase)
# not referenced by any other story → warning emitted, exit 0
test_story_merge_dead_code_positive() {
  echo ""
  echo "=== TC10: story-merge Phase 4.2 orphan-symbol smell (positive — symbol flagged) ==="

  local stg=".aimi/.tasks-staging-tc10"
  local out_file=".aimi/tasks/sm-tc10-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Story 1: adds orphanHelper — nobody else mentions it
  cat > "$stg/01-orphan.json" << 'EOF'
{
  "title": "Add orphan utility",
  "description": "As a developer, I want a utility so that it exists.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/utils.ts"],
    "approach": "Add orphanHelper function to compute graph metrics",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Story 2: unrelated — does not mention orphanHelper
  cat > "$stg/02-unrelated.json" << 'EOF'
{
  "title": "Setup scaffolding",
  "description": "As a developer, I want scaffolding so that the project compiles.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/index.ts"],
    "approach": "Bootstrap the project entry point",
    "verify": "tsc --noEmit"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC10: dead-code positive — exits 0 (warning only)"
  assert_contains "Phase 4.2" "$output" "TC10: dead-code positive — Phase 4.2 warning emitted"
  assert_contains "orphanHelper" "$output" "TC10: dead-code positive — orphanHelper flagged in warning"

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC11: Phase 4.2 orphan-symbol smell — negative: story adds fetchUserProfile (camelCase)
# that IS referenced by another story → no warning emitted
test_story_merge_dead_code_negative() {
  echo ""
  echo "=== TC11: story-merge Phase 4.2 orphan-symbol smell (negative — symbol has caller, not flagged) ==="

  local stg=".aimi/.tasks-staging-tc11"
  local out_file=".aimi/tasks/sm-tc11-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Story 1: defines fetchUserProfile
  cat > "$stg/01-fetch.json" << 'EOF'
{
  "title": "Add fetchUserProfile helper",
  "description": "As a developer, I want a helper so that profile data is fetched.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/api/userProfile.ts"],
    "approach": "Add fetchUserProfile function to retrieve user data from the API",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Story 2: explicitly calls fetchUserProfile in its approach → not dead code
  cat > "$stg/02-consumer.json" << 'EOF'
{
  "title": "Display user profile page",
  "description": "As a user, I want to view my profile so that I can see my data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/pages/ProfilePage.tsx"],
    "approach": "Use fetchUserProfile to load data and render the profile view",
    "verify": "tsc --noEmit"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC11: dead-code negative — exits 0"

  # No Phase 4.2 warning should appear when the symbol has a referencing story
  if echo "$output" | grep -q "Phase 4.2"; then
    echo -e "${RED}✗${NC} TC11: dead-code negative — unexpected Phase 4.2 warning emitted"
    echo "  output: $output"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC11: dead-code negative — no Phase 4.2 warning (symbol has caller)"
    ((TESTS_PASSED++))
  fi

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC13: --foundation injects the foundation US-ID into every non-foundation
# story's dependsOn and waves are recomputed against the augmented graph
# (foundation wave 1, direct dependents wave 2, transitive dependents wave 3+)
test_story_merge_foundation_injection() {
  echo ""
  echo "=== TC13: story-merge --foundation injection + wave recompute ==="

  local stg=".aimi/.tasks-staging-tc13"
  local out_file=".aimi/tasks/sm-tc13-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # 01 = foundation (empty dependsOn); 02 = no prior dep; 03 = depends on 02
  _sm_make_story "$stg/01-foundation.json" "Foundation story"
  _sm_make_story "$stg/02-second.json"     "Second story"
  _sm_make_story "$stg/03-third.json"      "Third story"   '["outline:02"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --foundation 01 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC13: --foundation injection exits 0"

  if [ -f "$out_file" ]; then
    local dep1_len dep2 dep3_has1 dep3_has2
    dep1_len=$(jq -r '.userStories[] | select(.id == "US-001") | .dependsOn | length' "$out_file")
    assert_eq "0" "$dep1_len" "TC13: foundation's own dependsOn stays empty"

    dep2=$(jq -r '.userStories[] | select(.id == "US-002") | .dependsOn | join(",")' "$out_file")
    assert_eq "US-001" "$dep2" "TC13: story with no prior dep gets foundation injected"

    dep3_has1=$(jq -r '.userStories[] | select(.id == "US-003") | (.dependsOn | index("US-001") != null)' "$out_file")
    dep3_has2=$(jq -r '.userStories[] | select(.id == "US-003") | (.dependsOn | index("US-002") != null)' "$out_file")
    assert_eq "true" "$dep3_has1" "TC13: transitive dependent also gets foundation injected"
    assert_eq "true" "$dep3_has2" "TC13: transitive dependent keeps its pre-existing dependency"

    local wave1 wave2 wave3
    wave1=$(jq -r '.userStories[] | select(.id == "US-001") | .wave' "$out_file")
    wave2=$(jq -r '.userStories[] | select(.id == "US-002") | .wave' "$out_file")
    wave3=$(jq -r '.userStories[] | select(.id == "US-003") | .wave' "$out_file")
    assert_eq "1" "$wave1" "TC13: foundation is wave 1"
    assert_eq "2" "$wave2" "TC13: direct dependent is wave 2"
    assert_eq "3" "$wave3" "TC13: transitive dependent is wave 3 (max(dep waves)+1 on augmented graph)"
  else
    echo -e "${RED}✗${NC} TC13: output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC14: --foundation omitted is a true no-op — no injection, no wave changes,
# no foundation-related stderr, for the same staging inputs as TC13.
test_story_merge_foundation_omitted_noop() {
  echo ""
  echo "=== TC14: story-merge --foundation omitted is a no-op ==="

  local stg=".aimi/.tasks-staging-tc14"
  local out_file=".aimi/tasks/sm-tc14-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-foundation.json" "Foundation story"
  _sm_make_story "$stg/02-second.json"     "Second story"
  _sm_make_story "$stg/03-third.json"      "Third story"   '["outline:02"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC14: story-merge without --foundation exits 0"

  if [ -f "$out_file" ]; then
    local dep1 dep2 dep3 wave1 wave2 wave3
    dep1=$(jq -r '.userStories[] | select(.id == "US-001") | .dependsOn | join(",")' "$out_file")
    dep2=$(jq -r '.userStories[] | select(.id == "US-002") | .dependsOn | join(",")' "$out_file")
    dep3=$(jq -r '.userStories[] | select(.id == "US-003") | .dependsOn | join(",")' "$out_file")
    assert_eq "" "$dep1" "TC14: US-001 dependsOn untouched (empty)"
    assert_eq "" "$dep2" "TC14: US-002 dependsOn untouched (empty, no injection)"
    assert_eq "US-002" "$dep3" "TC14: US-003 dependsOn untouched (only its original reference)"

    wave1=$(jq -r '.userStories[] | select(.id == "US-001") | .wave' "$out_file")
    wave2=$(jq -r '.userStories[] | select(.id == "US-002") | .wave' "$out_file")
    wave3=$(jq -r '.userStories[] | select(.id == "US-003") | .wave' "$out_file")
    assert_eq "1" "$wave1" "TC14: US-001 wave unchanged (1)"
    assert_eq "1" "$wave2" "TC14: US-002 wave unchanged (1, no injected dependency)"
    assert_eq "2" "$wave3" "TC14: US-003 wave unchanged (2)"
  else
    echo -e "${RED}✗${NC} TC14: output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if echo "$output" | grep -qi "foundation"; then
    echo -e "${RED}✗${NC} TC14: unexpected foundation-related stderr when flag omitted"
    echo "  output: $output"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC14: no foundation-related stderr when flag omitted"
    ((TESTS_PASSED++))
  fi

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC15: a story that already depends on the foundation via its own outline:NN
# token gets no duplicate entry (dedup on pre-existing reference).
test_story_merge_foundation_dedup() {
  echo ""
  echo "=== TC15: story-merge --foundation dedup on pre-existing reference ==="

  local stg=".aimi/.tasks-staging-tc15"
  local out_file=".aimi/tasks/sm-tc15-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-foundation.json" "Foundation story"
  _sm_make_story "$stg/02-explicit.json"   "Explicit dependent" '["outline:01"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --foundation 01 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC15: --foundation dedup case exits 0"

  if [ -f "$out_file" ]; then
    local dep_len dep_val
    dep_len=$(jq -r '.userStories[] | select(.id == "US-002") | .dependsOn | length' "$out_file")
    dep_val=$(jq -r '.userStories[] | select(.id == "US-002") | .dependsOn | join(",")' "$out_file")
    assert_eq "1" "$dep_len" "TC15: dependsOn length unchanged (no duplicate entry)"
    assert_eq "US-001" "$dep_val" "TC15: dependsOn still contains exactly one foundation reference"
  else
    echo -e "${RED}✗${NC} TC15: output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  rm -f "$out_file"
  rm -rf "$stg"
}

# TC16: a malformed --foundation value and a well-formed-but-nonexistent one
# each exit non-zero and leave no output file.
test_story_merge_foundation_invalid_idx() {
  echo ""
  echo "=== TC16: story-merge --foundation malformed / nonexistent index ==="

  local stg=".aimi/.tasks-staging-tc16"
  local out_file=".aimi/tasks/sm-tc16-tasks.json"
  rm -rf "$stg" "$out_file"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-foundation.json" "Foundation story"
  _sm_make_story "$stg/02-second.json"     "Second story"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --foundation 1 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC16: malformed --foundation value exits 1"
  assert_contains "must be a two-digit index" "$output" "TC16: error mentions 'must be a two-digit index'"
  if [ ! -f "$out_file" ]; then
    echo -e "${GREEN}✓${NC} TC16: no output file written for malformed index"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC16: output file written despite malformed index"
    ((TESTS_FAILED++))
  fi

  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --foundation 99 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC16: well-formed-but-nonexistent --foundation value exits 1"
  assert_contains "not present among staging files" "$output" "TC16: error mentions 'not present among staging files'"
  if [ ! -f "$out_file" ]; then
    echo -e "${GREEN}✓${NC} TC16: no output file written for nonexistent index"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC16: output file written despite nonexistent index"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$out_file"
}

# TC17: a foundation staging file with a non-empty dependsOn exits non-zero
# and leaves no output file.
test_story_merge_foundation_nonempty_dependson() {
  echo ""
  echo "=== TC17: story-merge --foundation rejects non-empty foundation dependsOn ==="

  local stg=".aimi/.tasks-staging-tc17"
  local out_file=".aimi/tasks/sm-tc17-tasks.json"
  rm -rf "$stg" "$out_file"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-foundation.json" "Foundation story" '["outline:02"]'
  _sm_make_story "$stg/02-other.json"      "Other story"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --foundation 01 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC17: foundation with non-empty dependsOn exits 1"
  assert_contains "non-empty dependsOn" "$output" "TC17: error mentions 'non-empty dependsOn'"
  assert_contains "US-001" "$output" "TC17: error identifies the foundation story's assigned id"

  if [ ! -f "$out_file" ]; then
    echo -e "${GREEN}✓${NC} TC17: no output file written"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC17: output file written despite non-empty foundation dependsOn"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$out_file"
}

# TC18: per-project partition — the 2-distinct-project fixture (web-app: React
# UserProfile page + docs-only story + React SettingsPanel = 3 stories;
# api-service: UserProfile API endpoint = 1 story) produces ONE output file per
# project under the N-file PROJECT-axis writer. The web-app file carries all 3
# of its repo's stories (the docs-only one included, because it names that
# repo — not because anything voted for it) and the api-service file carries 1.
# No frontend/backend heuristic verdict is consulted anywhere on this path.
#
# SUPERSEDED, NOT BROKEN — do not read this diff as a regression being papered
# over. This case used to assert the "project-aware majority vote": the group's
# output file was chosen by strict majority vote of its members' own
# file-pattern/keyword heuristic verdicts (ties going to backend), so the
# docs-only story rode its two frontend siblings' majority into
# frontend-tasks.json (FE=3 / BE=1) despite failing the heuristic on its own.
# US-001 deleted that majority vote outright — a merge carrying >= 2 distinct
# normalized .project values now routes to _story_merge_write_project_split,
# which splits by project with no side decision at all, so there is no vote
# left to pin. Removal is recorded in CHANGELOG 1.116.0. The staging fixture
# below is byte-for-byte the old one; only the expected output shape moved from
# two side-named files to one file per project.
test_story_merge_project_axis_partition() {
  echo ""
  echo "=== TC18: story-merge --split full-stack per-project partition ==="

  local stg=".aimi/.tasks-staging-tc18"
  local out_file=".aimi/tasks/sm-tc18-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/02-docs.json" << 'EOF'
{
  "title": "Update project documentation",
  "description": "As a maintainer, I want documentation updated so that contributors stay informed.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["AGENTS.md", "CLAUDE.md", "docs/setup.md"],
    "approach": "Edit docs",
    "verify": "manual review"
  }
}
EOF

  cat > "$stg/03-ui2.json" << 'EOF'
{
  "title": "React SettingsPanel component",
  "description": "As a user, I want a settings panel so that I can adjust preferences.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 3,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["src/components/SettingsPanel.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/04-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 4,
  "status": "pending",
  "dependsOn": [],
  "project": "api-service",
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC18: full-stack split exits 0"

  # One file per distinct normalized project; basenames are the slugified
  # project values, not side names.
  local web_file=".aimi/tasks/sm-tc18-tasks-web-app-tasks.json"
  local api_file=".aimi/tasks/sm-tc18-tasks-api-service-tasks.json"
  local fe_file=".aimi/tasks/sm-tc18-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc18-tasks-backend-tasks.json"

  if [ -f "$web_file" ] && [ -f "$api_file" ]; then
    local web_count api_count
    web_count=$(jq '.userStories | length' "$web_file" 2>/dev/null)
    api_count=$(jq '.userStories | length' "$api_file" 2>/dev/null)
    assert_eq "3" "$web_count" "TC18: web-app file has exactly 3 userStories (every story naming that repo)"
    assert_eq "1" "$api_count" "TC18: api-service file has exactly 1 userStory"
  else
    echo -e "${RED}✗${NC} TC18: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  # The docs-only story stays with its own repo because of its .project value
  # alone — no heuristic verdict, no group decision, nothing to override.
  local docs_home
  docs_home=$(jq -r '[.userStories[] | select(.title == "Update project documentation")] | length' "$web_file" 2>/dev/null)
  assert_eq "1" "$docs_home" "TC18: docs-only story lands in its own project's file on .project alone"

  if [ ! -f "$fe_file" ] && [ ! -f "$be_file" ]; then
    echo -e "${GREEN}✓${NC} TC18: no frontend/backend side file produced on the project axis"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC18: side-axis files were written on a multi-repo layout"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$web_file" "$api_file" "$fe_file" "$be_file" "$out_file"
  rm -f .aimi/tasks/sm-tc18-*.lock
}

# TC19: monorepo guard — every story shares the same normalized .project
# value, so the split falls back to pure per-story heuristic classification
# (unchanged from pre-fix behavior) rather than a per-group majority vote.
test_story_merge_project_monorepo_guard() {
  echo ""
  echo "=== TC19: story-merge --split full-stack monorepo guard (single project) ==="

  local stg=".aimi/.tasks-staging-tc19"
  local out_file=".aimi/tasks/sm-tc19-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "project": ".",
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/02-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "project": ".",
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  cat > "$stg/03-migration.json" << 'EOF'
{
  "title": "Database migration for user profiles",
  "description": "As a developer, I want a migration so that the schema supports profiles.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 3,
  "status": "pending",
  "dependsOn": [],
  "project": ".",
  "notes": "",
  "implementation": {
    "files": ["db/migrate/001_add_profiles.rb"],
    "approach": "Add migration",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC19: full-stack split exits 0"

  local fe_file=".aimi/tasks/sm-tc19-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc19-tasks-backend-tasks.json"

  if [ -f "$fe_file" ] && [ -f "$be_file" ]; then
    local fe_count be_count
    fe_count=$(jq '.userStories | length' "$fe_file" 2>/dev/null)
    be_count=$(jq '.userStories | length' "$be_file" 2>/dev/null)
    # A single shared .project value is below the 2-distinct-projects
    # threshold, so majority voting never engages: the React story lands
    # frontend and both backend-shaped stories land backend, exactly as
    # pure per-story heuristic classification would (not majority-voted
    # into a single group, which would have sent all 3 to backend).
    assert_eq "1" "$fe_count" "TC19: frontend-tasks.json has 1 userStory (per-story heuristic fallback)"
    assert_eq "2" "$be_count" "TC19: backend-tasks.json has 2 userStories (per-story heuristic fallback)"
  else
    echo -e "${RED}✗${NC} TC19: expected output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# TC20: N-way partition invariant — every one of the 4 input story titles
# appears exactly once across the union of ALL per-project output files, and
# the per-file userStories counts sum to the full input count (no story lost,
# no story duplicated across repos). Same 2-distinct-project fixture as TC18.
# The union is read back off the writer's own return value so the exactly-once
# check is arity-agnostic, but the ARITY ITSELF is pinned separately, by name:
# at N=1 (every story forced into one group) exactly-once coverage is trivially
# true, and a return value read in a circle would confirm it.
#
# SUPERSEDED, NOT BROKEN — do not read this diff as a regression being papered
# over. This case used to assert a two-file BIPARTITION over
# frontend-tasks.json + backend-tasks.json, the fixed pair of files the deleted
# project-group majority vote (strict majority of the group's members'
# heuristic verdicts, ties going to backend) always produced. US-001 deleted
# that majority vote and replaced the two-file writer with a per-project N-file
# one, so the same property — exactly-once coverage of every input story — is
# now generalized from 2 files to N. Only the arity changed; the invariant is
# the same one. Removal is recorded in CHANGELOG 1.116.0. Fixture unchanged.
test_story_merge_nway_partition_invariant() {
  echo ""
  echo "=== TC20: story-merge --split full-stack N-way partition invariant ==="

  local stg=".aimi/.tasks-staging-tc20"
  local out_file=".aimi/tasks/sm-tc20-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/02-docs.json" << 'EOF'
{
  "title": "Update project documentation",
  "description": "As a maintainer, I want documentation updated so that contributors stay informed.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["AGENTS.md", "CLAUDE.md", "docs/setup.md"],
    "approach": "Edit docs",
    "verify": "manual review"
  }
}
EOF

  cat > "$stg/03-ui2.json" << 'EOF'
{
  "title": "React SettingsPanel component",
  "description": "As a user, I want a settings panel so that I can adjust preferences.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 3,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["src/components/SettingsPanel.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/04-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 4,
  "status": "pending",
  "dependsOn": [],
  "project": "api-service",
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC20: full-stack split exits 0"

  # Discover the N output paths from the writer's own return value
  # ([{path, project, branchName, storyCount}, ...]) instead of hardcoding a
  # file count, so the invariant is arity-agnostic.
  local split_paths
  split_paths=$(printf '%s' "$output" | jq -r '.[].path' 2>/dev/null)

  local -a split_files=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    split_files+=("$p")
  done <<< "$split_paths"

  local missing_files=""
  local f
  for f in ${split_files[@]+"${split_files[@]}"}; do
    [ -f "$f" ] || missing_files="$missing_files $f"
  done

  # Arity floor. The fixture holds exactly 2 distinct projects, so exactly 2
  # files must exist and they must be THESE two — named here rather than
  # inherited from the return value, which is the same source the union below
  # is built from and therefore cannot contradict it.
  local web_file=".aimi/tasks/sm-tc20-tasks-web-app-tasks.json"
  local api_file=".aimi/tasks/sm-tc20-tasks-api-service-tasks.json"
  assert_eq "2" "${#split_files[@]}" "TC20: 2 distinct projects produce exactly 2 split files"
  if [ -f "$web_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC20: both expected per-project files exist by name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC20: expected per-project files missing by name ($web_file / $api_file)"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if [ "${#split_files[@]}" -gt 0 ] && [ -z "$missing_files" ]; then
    local total
    total=$(jq -r '.userStories | length' "${split_files[@]}" 2>/dev/null | awk '{s += $1} END {print s + 0}')
    assert_eq "4" "$total" "TC20: per-project userStories counts sum to the full input count"

    local expected_titles all_titles dup_titles missing_titles
    expected_titles=$(printf '%s\n' \
      "React UserProfile page" \
      "Update project documentation" \
      "React SettingsPanel component" \
      "UserProfile API endpoint" | sort)
    all_titles=$(jq -r '.userStories[].title' "${split_files[@]}" 2>/dev/null | sort)
    dup_titles=$(printf '%s\n' "$all_titles" | uniq -d)
    missing_titles=$(comm -23 <(printf '%s\n' "$expected_titles") <(printf '%s\n' "$all_titles" | sort -u))

    if [ -z "$dup_titles" ] && [ -z "$missing_titles" ]; then
      echo -e "${GREEN}✓${NC} TC20: every input story title appears exactly once across all per-project outputs"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC20: N-way partition invariant violated (dup: '$dup_titles' missing: '$missing_titles')"
      ((TESTS_FAILED++))
    fi
  else
    echo -e "${RED}✗${NC} TC20: expected per-project output files missing:$missing_files"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$out_file"
  rm -f .aimi/tasks/sm-tc20-*.json .aimi/tasks/sm-tc20-*.lock
}

# TC21: .project is preserved verbatim on every userStory object in every
# per-project output file, while the working keys this axis actually computes —
# __droppedDeps and __becameRoot, added by _story_merge_write_project_split's
# cross-group dependsOn sweep and del()'d in the same writer's userStories
# projection — never leak into any of them.
#
# SUPERSEDED, NOT BROKEN — do not read this diff as a regression being papered
# over. This case used to check .project survival and _fe/_side stripping on
# frontend-tasks.json + backend-tasks.json, the two files the deleted
# project-group majority vote (strict majority of members' heuristic verdicts,
# ties going to backend) produced. US-001 deleted that majority vote and its
# two-file output. Removal is recorded in CHANGELOG 1.116.0. Fixture unchanged;
# only the files the assertions read moved from side-named to project-named.
#
# The _fe / _side leak legs are gone rather than retargeted at the new files.
# Neither key is computed anywhere on the PROJECT path — the fe_heuristic that
# produces them lives in _story_merge_write_split, which a multi-repo merge
# never reaches — so asserting their absence here could not fail for any edit
# to this writer. Their SIDE-axis home still covers them where they exist.
test_story_merge_project_preserved_working_keys_stripped() {
  echo ""
  echo "=== TC21: story-merge --split full-stack preserves .project, strips working keys ==="

  local stg=".aimi/.tasks-staging-tc21"
  local out_file=".aimi/tasks/sm-tc21-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "project": "web-app",
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/02-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "project": "api-service",
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC21: full-stack split exits 0"

  local web_file=".aimi/tasks/sm-tc21-tasks-web-app-tasks.json"
  local api_file=".aimi/tasks/sm-tc21-tasks-api-service-tasks.json"

  if [ -f "$web_file" ] && [ -f "$api_file" ]; then
    # .project verbatim on EVERY userStory of EVERY per-project file — the
    # normalized grouping key is never written back onto a story.
    local web_projects api_projects
    web_projects=$(jq -r '[.userStories[].project] | join(",")' "$web_file" 2>/dev/null)
    api_projects=$(jq -r '[.userStories[].project] | join(",")' "$api_file" 2>/dev/null)
    assert_eq "web-app" "$web_projects" "TC21: web-app file preserves .project verbatim on every userStory"
    assert_eq "api-service" "$api_projects" "TC21: api-service file preserves .project verbatim on every userStory"

    # Working keys the per-project axis itself introduces (cross-group
    # dependsOn sweep), read off _story_merge_write_project_split rather than
    # guessed at.
    local axis_key_leaks
    axis_key_leaks=$(jq -r '[.userStories[] | select(has("__droppedDeps") or has("__becameRoot"))] | length' "$web_file" "$api_file" 2>/dev/null | awk '{s += $1} END {print s + 0}')
    assert_eq "0" "$axis_key_leaks" "TC21: __droppedDeps/__becameRoot never leak into any per-project output file"
  else
    echo -e "${RED}✗${NC} TC21: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$web_file" "$api_file" "$out_file"
  rm -f .aimi/tasks/sm-tc21-*.lock
}

# TC22: .project normalization boundary — "apps/web" and "apps/web/" (trailing
# slash) are treated as the SAME project group. Two Pass-2 sub-agents authoring
# the same logical repo with/without a trailing slash must land in ONE
# per-project output file (2 userStories), each story keeping its own verbatim
# .project spelling, with a separate api-service group alongside it so the
# merge is genuinely on the multi-repo PROJECT axis and not the monorepo
# fallback TC19 pins.
#
# SUPERSEDED, NOT BROKEN — do not read this diff as a regression being papered
# over. This case used to assert "tie -> backend": the two-member apps/web
# group produced a 1-1 split of member heuristic verdicts, the deleted majority
# vote found no strict majority, and its tie-goes-to-backend bias sent BOTH
# stories to backend-tasks.json (FE=0 / BE=3). US-001 deleted that majority
# vote and its tie-break, so a tie is no longer a thing that can happen — there
# is no vote to tie. Removal is recorded in CHANGELOG 1.116.0.
#
# The FIXTURE is deliberately kept rather than discarded: mis-grouping
# trailing-slash variants is a real failure the new axis can still commit
# (two groups would collide on the same "apps-web" output basename and hard-
# fail the whole merge), unlike the tie-break, which has no equivalent left to
# test. So the tie assertion is replaced by a normalization-boundary assertion
# on the same inputs.
test_story_merge_project_trailing_slash_normalization() {
  echo ""
  echo "=== TC22: story-merge --split full-stack .project trailing-slash normalization ==="

  local stg=".aimi/.tasks-staging-tc22"
  local out_file=".aimi/tasks/sm-tc22-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Frontend-heuristic-passing story tagged "apps/web" (no trailing slash)
  cat > "$stg/01-ui.json" << 'EOF'
{
  "title": "React UserProfile page",
  "description": "As a user, I want a React page so that I can view data.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "project": "apps/web",
  "notes": "",
  "implementation": {
    "files": ["src/components/UserProfile.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  # Docs-only story (fails the heuristic alone) tagged "apps/web/" (trailing
  # slash) by a different Pass-2 sub-agent authoring the same logical project.
  cat > "$stg/02-docs.json" << 'EOF'
{
  "title": "Update project documentation",
  "description": "As a maintainer, I want documentation updated so that contributors stay informed.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": [],
  "project": "apps/web/",
  "notes": "",
  "implementation": {
    "files": ["AGENTS.md", "CLAUDE.md", "docs/setup.md"],
    "approach": "Edit docs",
    "verify": "manual review"
  }
}
EOF

  # Distinct second project so the merge crosses the 2-distinct-project
  # threshold that selects the PROJECT axis (isolates the grouping
  # normalization behavior from the monorepo SIDE fallback exercised by TC19).
  cat > "$stg/03-api.json" << 'EOF'
{
  "title": "UserProfile API endpoint",
  "description": "As a developer, I want a backend endpoint so that data is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 3,
  "status": "pending",
  "dependsOn": [],
  "project": "api-service",
  "notes": "",
  "implementation": {
    "files": ["app/controllers/user_profiles_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC22: full-stack split exits 0"

  # Both spellings normalize to "apps/web", so exactly TWO groups exist and the
  # apps/web one owns both stories. Had normalization failed, "apps/web" and
  # "apps/web/" would have become two groups sharing the "apps-web" basename
  # slug and the merge would have hard-failed on the collision guard instead of
  # exiting 0.
  local group_count group_projects
  group_count=$(printf '%s' "$output" | jq 'length' 2>/dev/null)
  group_projects=$(printf '%s' "$output" | jq -r '[.[].project] | join(",")' 2>/dev/null)
  assert_eq "2" "$group_count" "TC22: trailing-slash variant does NOT open a third project group"
  assert_eq "api-service,apps/web" "$group_projects" "TC22: both spellings collapse to the single normalized 'apps/web' routing key"

  local web_file=".aimi/tasks/sm-tc22-tasks-apps-web-tasks.json"
  local api_file=".aimi/tasks/sm-tc22-tasks-api-service-tasks.json"

  if [ -f "$web_file" ] && [ -f "$api_file" ]; then
    local web_count api_count
    web_count=$(jq '.userStories | length' "$web_file" 2>/dev/null)
    api_count=$(jq '.userStories | length' "$api_file" 2>/dev/null)
    assert_eq "2" "$web_count" "TC22: the apps/web group file holds BOTH trailing-slash variants"
    assert_eq "1" "$api_count" "TC22: the api-service group file holds its single story"

    # Grouping is normalization-only: each story keeps its own raw spelling.
    local react_project docs_project
    react_project=$(jq -r '.userStories[] | select(.title == "React UserProfile page") | .project' "$web_file" 2>/dev/null)
    docs_project=$(jq -r '.userStories[] | select(.title == "Update project documentation") | .project' "$web_file" 2>/dev/null)
    assert_eq "apps/web" "$react_project" "TC22: 'apps/web' story kept its verbatim .project inside the shared group"
    assert_eq "apps/web/" "$docs_project" "TC22: 'apps/web/' story kept its verbatim .project inside the shared group"
  else
    echo -e "${RED}✗${NC} TC22: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$web_file" "$api_file" "$out_file"
  rm -f .aimi/tasks/sm-tc22-*.lock
}

# TC23: cross-file dependsOn drop — positive banner + smellWarnings entry.
# 03-ui2 (frontend) depends on both 01-ui (frontend, kept) and 02-api
# (backend, dropped) -- a PARTIAL loss, so becameRoot stays false and no
# false-root enumeration line is expected (that distinction is TC24's job).
# This test just proves the aggregated banner and the smellWarnings entry
# shape/side/ids appear, identically, in BOTH output files.
test_story_merge_cross_file_dep_dropped_banner() {
  echo ""
  echo "=== TC23: story-merge --split full-stack cross-file dependsOn drop (banner + smellWarnings) ==="

  local stg=".aimi/.tasks-staging-tc23"
  local out_file=".aimi/tasks/sm-tc23-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-ui.json" "React UserProfile page" '[]'
  jq '. + {implementation: {files: ["src/components/UserProfile.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/01-ui.json" > "$stg/01-ui.json.tmp" && mv "$stg/01-ui.json.tmp" "$stg/01-ui.json"

  _sm_make_story "$stg/02-api.json" "UserProfile API endpoint" '[]'
  jq '. + {implementation: {files: ["app/controllers/user_profiles_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/02-api.json" > "$stg/02-api.json.tmp" && mv "$stg/02-api.json.tmp" "$stg/02-api.json"

  _sm_make_story "$stg/03-ui2.json" "React SettingsPanel component" '["outline:01", "outline:02"]'
  jq '. + {implementation: {files: ["src/components/SettingsPanel.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/03-ui2.json" > "$stg/03-ui2.json.tmp" && mv "$stg/03-ui2.json.tmp" "$stg/03-ui2.json"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC23: exits 0 (warning only)"
  assert_contains "cross-file dependsOn edge(s) dropped" "$output" "TC23: aggregated stderr banner emitted"

  local fe_file=".aimi/tasks/sm-tc23-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc23-tasks-backend-tasks.json"

  if [ -f "$fe_file" ] && [ -f "$be_file" ]; then
    local fe_smells be_smells
    fe_smells=$(jq -c '.metadata.smellWarnings // []' "$fe_file")
    be_smells=$(jq -c '.metadata.smellWarnings // []' "$be_file")
    assert_eq "$fe_smells" "$be_smells" "TC23: both output files carry the identical smellWarnings set"

    local entry
    entry=$(printf '%s' "$fe_smells" | jq -c '.[] | select(.type == "cross-file-dep-dropped")')
    assert_contains '"storyId":"US-002"' "$entry" "TC23: entry storyId is the post-remap frontend id"
    assert_contains '"side":"frontend"' "$entry" "TC23: entry side is frontend"
    assert_contains '"becameRoot":false' "$entry" "TC23: becameRoot false (dep on US-001 stayed in-file)"
    assert_contains '"id":"US-003"' "$entry" "TC23: droppedDeps target is the post-remap backend id"
    assert_contains '"side":"backend"' "$entry" "TC23: droppedDeps target side is backend"

    if grep -q '"__droppedDeps"\|"__becameRoot"' "$fe_file" "$be_file" 2>/dev/null; then
      echo -e "${RED}✗${NC} TC23: internal __droppedDeps/__becameRoot fields leaked into userStories"
      ((TESTS_FAILED++))
    else
      echo -e "${GREEN}✓${NC} TC23: internal __droppedDeps/__becameRoot fields absent from output"
      ((TESTS_PASSED++))
    fi
  else
    echo -e "${RED}✗${NC} TC23: expected output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# TC24: false-root callout vs partial-loss non-callout. 03-ui2 loses its ONLY
# dependsOn entry (cross-file) -> becameRoot:true -> enumerated on stderr.
# 04-api2 loses ONE of two dependsOn entries (the other stays in-file) ->
# becameRoot:false -> must NOT be enumerated on stderr.
test_story_merge_cross_file_false_root_vs_partial_loss() {
  echo ""
  echo "=== TC24: story-merge cross-file drop — false-root callout vs partial-loss non-callout ==="

  local stg=".aimi/.tasks-staging-tc24"
  local out_file=".aimi/tasks/sm-tc24-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-ui.json" "React UserProfile page" '[]'
  jq '. + {implementation: {files: ["src/components/UserProfile.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/01-ui.json" > "$stg/01-ui.json.tmp" && mv "$stg/01-ui.json.tmp" "$stg/01-ui.json"

  _sm_make_story "$stg/02-api.json" "UserProfile API endpoint" '[]'
  jq '. + {implementation: {files: ["app/controllers/user_profiles_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/02-api.json" > "$stg/02-api.json.tmp" && mv "$stg/02-api.json.tmp" "$stg/02-api.json"

  # Only dep is cross-file (outline:02 -> backend) -> becomes a false root.
  _sm_make_story "$stg/03-ui2.json" "React SettingsPanel component" '["outline:02"]'
  jq '. + {implementation: {files: ["src/components/SettingsPanel.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/03-ui2.json" > "$stg/03-ui2.json.tmp" && mv "$stg/03-ui2.json.tmp" "$stg/03-ui2.json"

  # One dep cross-file (outline:01 -> frontend, dropped), one in-file
  # (outline:02 -> backend, kept) -> partial loss, NOT a root.
  _sm_make_story "$stg/04-api2.json" "Update settings API endpoint" '["outline:01", "outline:02"]'
  jq '. + {implementation: {files: ["app/controllers/settings_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/04-api2.json" > "$stg/04-api2.json.tmp" && mv "$stg/04-api2.json.tmp" "$stg/04-api2.json"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC24: exits 0 (warning only)"
  assert_contains "US-002 (frontend): became a false wave-1 root" "$output" "TC24: false-root story IS enumerated on stderr"

  if echo "$output" | grep -q "US-004 (backend): became a false wave-1 root"; then
    echo -e "${RED}✗${NC} TC24: partial-loss story US-004 was WRONGLY enumerated as a false root"
    echo "  output: $output"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC24: partial-loss story US-004 is NOT enumerated on stderr"
    ((TESTS_PASSED++))
  fi

  local fe_file=".aimi/tasks/sm-tc24-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc24-tasks-backend-tasks.json"
  if [ -f "$fe_file" ]; then
    local root_flag partial_flag
    root_flag=$(jq -r '.metadata.smellWarnings[] | select(.storyId == "US-002") | .becameRoot' "$fe_file")
    partial_flag=$(jq -r '.metadata.smellWarnings[] | select(.storyId == "US-004") | .becameRoot' "$fe_file")
    assert_eq "true" "$root_flag" "TC24: US-002 (false root) becameRoot is true in metadata.smellWarnings"
    assert_eq "false" "$partial_flag" "TC24: US-004 (partial loss) becameRoot is false in metadata.smellWarnings"
  else
    echo -e "${RED}✗${NC} TC24: expected output file missing"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# TC25: negative — every dependsOn edge stays on the SAME side as its owner.
# No cross-file drop should be detected: no smellWarnings entry, no banner.
# Mirrors TC11's negative-check pattern.
test_story_merge_cross_file_dep_dropped_negative() {
  echo ""
  echo "=== TC25: story-merge cross-file drop — negative (same-side-only dependsOn) ==="

  local stg=".aimi/.tasks-staging-tc25"
  local out_file=".aimi/tasks/sm-tc25-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-ui.json" "React UserProfile page" '[]'
  jq '. + {implementation: {files: ["src/components/UserProfile.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/01-ui.json" > "$stg/01-ui.json.tmp" && mv "$stg/01-ui.json.tmp" "$stg/01-ui.json"

  # Same side (frontend) as its dep -> resolves locally, no drop.
  _sm_make_story "$stg/02-ui2.json" "React SettingsPanel component" '["outline:01"]'
  jq '. + {implementation: {files: ["src/components/SettingsPanel.tsx"], approach: "Build React component", verify: "tsc --noEmit"}}' "$stg/02-ui2.json" > "$stg/02-ui2.json.tmp" && mv "$stg/02-ui2.json.tmp" "$stg/02-ui2.json"

  _sm_make_story "$stg/03-api.json" "UserProfile API endpoint" '[]'
  jq '. + {implementation: {files: ["app/controllers/user_profiles_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/03-api.json" > "$stg/03-api.json.tmp" && mv "$stg/03-api.json.tmp" "$stg/03-api.json"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC25: exits 0"

  if echo "$output" | grep -qE "cross-file-dep-dropped|cross-file dependsOn edge\(s\) dropped"; then
    echo -e "${RED}✗${NC} TC25: unexpected cross-file-dep-dropped signal in output"
    echo "  output: $output"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC25: no cross-file-dep-dropped signal (all dependsOn stayed in-file)"
    ((TESTS_PASSED++))
  fi

  local fe_file=".aimi/tasks/sm-tc25-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc25-tasks-backend-tasks.json"
  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# TC26: a title containing an embedded newline AND a backtick, used as the
# dropped-edge target, must not forge a second Warning:/Error: line on
# stderr, and must not leak the raw newline/backtick into
# metadata.smellWarnings[].droppedDeps[].title in either output file.
test_story_merge_cross_file_dep_dropped_title_sanitized() {
  echo ""
  echo "=== TC26: story-merge cross-file drop — dropped-target title sanitization ==="

  local stg=".aimi/.tasks-staging-tc26"
  local out_file=".aimi/tasks/sm-tc26-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  cat > "$stg/01-weird.json" << 'EOF'
{
  "title": "Fix widget\nWarning: forged line`rm -rf /`",
  "description": "As a user, I want a widget so that it works.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "implementation": {
    "files": ["src/components/Weird.tsx"],
    "approach": "Build React component",
    "verify": "tsc --noEmit"
  }
}
EOF

  cat > "$stg/02-consumer.json" << 'EOF'
{
  "title": "Consume weird widget endpoint",
  "description": "As a developer, I want an endpoint so that the widget is served.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 2,
  "status": "pending",
  "dependsOn": ["outline:01"],
  "notes": "",
  "implementation": {
    "files": ["app/controllers/weird_controller.rb"],
    "approach": "Rails controller",
    "verify": "rspec"
  }
}
EOF

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC26: exits 0"

  local warn_err_lines
  warn_err_lines=$(printf '%s\n' "$output" | grep -cE '^(Warning|Error):')
  assert_eq "1" "$warn_err_lines" "TC26: exactly one Warning:/Error:-prefixed stderr line (no forged second line)"

  local fe_file=".aimi/tasks/sm-tc26-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc26-tasks-backend-tasks.json"
  if [ -f "$be_file" ]; then
    local title_val
    title_val=$(jq -r '.metadata.smellWarnings[0].droppedDeps[0].title' "$be_file")
    local title_lines
    title_lines=$(printf '%s' "$title_val" | wc -l)
    if [ "$title_lines" -eq 0 ] && [[ "$title_val" != *'`'* ]]; then
      echo -e "${GREEN}✓${NC} TC26: droppedDeps[].title has no raw newline or backtick"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} TC26: droppedDeps[].title leaked unsanitized content: $title_val"
      ((TESTS_FAILED++))
    fi
  else
    echo -e "${RED}✗${NC} TC26: expected output file missing"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# TC27: every staging story partitions to the SAME side (backend here) --
# both split files must still be written (frontend with userStories: []),
# the command must still exit 0, and stderr must name the empty side.
test_story_merge_split_empty_side_warning() {
  echo ""
  echo "=== TC27: story-merge --split full-stack empty-side warning ==="

  local stg=".aimi/.tasks-staging-tc27"
  local out_file=".aimi/tasks/sm-tc27-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_story "$stg/01-api.json" "Persist user record" '[]'
  jq '. + {implementation: {files: ["app/controllers/users_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/01-api.json" > "$stg/01-api.json.tmp" && mv "$stg/01-api.json.tmp" "$stg/01-api.json"

  _sm_make_story "$stg/02-api2.json" "Fetch user record" '[]'
  jq '. + {implementation: {files: ["app/controllers/fetch_controller.rb"], approach: "Rails controller", verify: "rspec"}}' "$stg/02-api2.json" > "$stg/02-api2.json.tmp" && mv "$stg/02-api2.json.tmp" "$stg/02-api2.json"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC27: exits 0 despite one side being empty"
  assert_contains "frontend split produced zero stories" "$output" "TC27: stderr names the empty (frontend) side"

  local fe_file=".aimi/tasks/sm-tc27-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc27-tasks-backend-tasks.json"
  if [ -f "$fe_file" ] && [ -f "$be_file" ]; then
    local fe_count be_count
    fe_count=$(jq '.userStories | length' "$fe_file")
    be_count=$(jq '.userStories | length' "$be_file")
    assert_eq "0" "$fe_count" "TC27: frontend-tasks.json still written with userStories: []"
    assert_eq "2" "$be_count" "TC27: backend-tasks.json carries both stories"
  else
    echo -e "${RED}✗${NC} TC27: expected output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg" "$fe_file" "$be_file" "$out_file"
}

# ----------------------------------------------------------------------------
# Project-axis split (N files, one per repo) — TC28..TC33
#
# These pin the multi-repo path: >= 2 distinct normalized .project values route
# to _story_merge_write_project_split, which writes one file per project rather
# than force-fitting every repo into two frontend/backend files.
# ----------------------------------------------------------------------------

# Helper: staging story carrying an explicit .project (multi-repo fixtures)
_sm_make_project_story() {
  local path="$1"
  local title="$2"
  local project="$3"
  local files="$4"
  local depends="${5:-[]}"
  cat > "$path" << EOF
{
  "title": "$title",
  "description": "As a developer, I want $title so that it works.",
  "acceptanceCriteria": ["Typecheck passes"],
  "priority": 1,
  "status": "pending",
  "dependsOn": $depends,
  "project": "$project",
  "notes": "",
  "implementation": {
    "files": ["$files"],
    "approach": "Implement $title",
    "verify": "test"
  }
}
EOF
}

# TC28: three distinct projects produce three files, in lexicographic order by
# normalized project path, each with its own branchName and a self-describing
# metadata.splitGroup marker. No frontend/backend file is produced at all, and
# every input story lands exactly once across the N files.
test_story_merge_project_split_three_projects() {
  echo ""
  echo "=== TC28: story-merge --split full-stack project axis (3 distinct projects) ==="

  local stg=".aimi/.tasks-staging-tc28"
  local out_file=".aimi/tasks/sm-tc28-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # Deliberately NOT in lexicographic order on disk: services/api sorts last
  # but is staged first, so glob order and group order disagree.
  _sm_make_project_story "$stg/01-api.json"    "UserProfile API endpoint"  "services/api" "app/controllers/u.rb"
  _sm_make_project_story "$stg/02-web.json"    "React UserProfile page"    "apps/web"     "src/components/UserProfile.tsx"
  _sm_make_project_story "$stg/03-mobile.json" "Mobile profile screen"     "apps/mobile"  "lib/profile.dart"
  _sm_make_project_story "$stg/04-web2.json"   "React SettingsPanel"       "apps/web/"    "src/components/Settings.tsx"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC28: project-axis split exits 0"

  local mobile_file=".aimi/tasks/sm-tc28-tasks-apps-mobile-tasks.json"
  local web_file=".aimi/tasks/sm-tc28-tasks-apps-web-tasks.json"
  local api_file=".aimi/tasks/sm-tc28-tasks-services-api-tasks.json"
  local fe_file=".aimi/tasks/sm-tc28-tasks-frontend-tasks.json"
  local be_file=".aimi/tasks/sm-tc28-tasks-backend-tasks.json"

  if [ -f "$mobile_file" ] && [ -f "$web_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC28: one tasks file written per distinct project"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC28: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if [ ! -f "$fe_file" ] && [ ! -f "$be_file" ]; then
    echo -e "${GREEN}✓${NC} TC28: no frontend/backend side files produced on the project axis"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC28: side-axis files were written on a multi-repo layout"
    ((TESTS_FAILED++))
  fi

  # Return value: N-element array of {path, project, branchName, storyCount},
  # ordered lexicographically by normalized project path.
  local ret_projects ret_len ret_branches ret_counts
  ret_len=$(printf '%s' "$output" | jq 'length' 2>/dev/null)
  ret_projects=$(printf '%s' "$output" | jq -r '[.[].project] | join(",")' 2>/dev/null)
  ret_branches=$(printf '%s' "$output" | jq -r '[.[].branchName] | join(",")' 2>/dev/null)
  ret_counts=$(printf '%s' "$output" | jq -r '[.[].storyCount] | join(",")' 2>/dev/null)
  assert_eq "3" "$ret_len" "TC28: return value is a 3-element array"
  assert_eq "apps/mobile,apps/web,services/api" "$ret_projects" "TC28: groups ordered lexicographically by normalized project"
  assert_eq "feat/merged-apps-mobile,feat/merged-apps-web,feat/merged-services-api" "$ret_branches" "TC28: each group carries its own derived branchName"
  assert_eq "1,2,1" "$ret_counts" "TC28: trailing-slash project normalizes into the apps/web group (2 stories)"

  # No story lost, no story duplicated, ids unique and contiguous across files.
  local all_ids
  all_ids=$(jq -r '.userStories[].id' "$mobile_file" "$web_file" "$api_file" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
  assert_eq "US-001,US-002,US-003,US-004" "$all_ids" "TC28: ids unique and contiguous across the whole N-file set"

  # Exactly once, not merely "all four are present somewhere". A distinct-title
  # count collapses duplicates -- it reads 4 whether a title appears once or
  # five times -- so duplicates are detected with `uniq -d` on the un-deduped
  # union and absences with `comm`, the way TC20 does it.
  local expected_titles all_titles dup_titles missing_titles
  expected_titles=$(printf '%s\n' \
    "UserProfile API endpoint" \
    "React UserProfile page" \
    "Mobile profile screen" \
    "React SettingsPanel" | sort)
  all_titles=$(jq -r '.userStories[].title' "$mobile_file" "$web_file" "$api_file" 2>/dev/null | sort)
  dup_titles=$(printf '%s\n' "$all_titles" | uniq -d)
  missing_titles=$(comm -23 <(printf '%s\n' "$expected_titles") <(printf '%s\n' "$all_titles" | sort -u))
  if [ -z "$dup_titles" ] && [ -z "$missing_titles" ]; then
    echo -e "${GREEN}✓${NC} TC28: all 4 input stories land exactly once across the split"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC28: exactly-once coverage violated (dup: '$dup_titles' missing: '$missing_titles')"
    ((TESTS_FAILED++))
  fi

  # .project survives verbatim (the trailing-slash form is NOT rewritten).
  local raw_projects
  raw_projects=$(jq -r '.userStories[].project' "$web_file" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
  assert_eq "apps/web,apps/web/" "$raw_projects" "TC28: .project preserved verbatim (normalization is grouping-only)"

  # metadata.splitGroup marker: own project, 1-based index, total, sibling paths.
  local sg_project sg_index sg_total sg_siblings sg_branch
  sg_project=$(jq -r '.metadata.splitGroup.project' "$web_file" 2>/dev/null)
  sg_index=$(jq -r '.metadata.splitGroup.index' "$web_file" 2>/dev/null)
  sg_total=$(jq -r '.metadata.splitGroup.total' "$web_file" 2>/dev/null)
  sg_siblings=$(jq -r '[.metadata.splitGroup.siblings[]] | sort | join(",")' "$web_file" 2>/dev/null)
  sg_branch=$(jq -r '.metadata.branchName' "$web_file" 2>/dev/null)
  assert_eq "apps/web" "$sg_project" "TC28: splitGroup.project names the file's own project"
  assert_eq "2" "$sg_index" "TC28: splitGroup.index is the 1-based lexicographic position"
  assert_eq "3" "$sg_total" "TC28: splitGroup.total is the N-way split size"
  assert_eq "$mobile_file,$api_file" "$sg_siblings" "TC28: splitGroup.siblings lists the other files' paths"
  assert_eq "feat/merged-apps-web" "$sg_branch" "TC28: file's metadata.branchName matches its group"

  # Working keys stripped from every output story. Only the two this axis
  # actually computes are checked: _fe/_side come from the SIDE writer's
  # fe_heuristic, which a multi-repo merge never runs, so watching for them
  # here would be a check no edit to this writer could fail.
  local leaked
  leaked=$(jq -r '[.userStories[] | select(has("__droppedDeps") or has("__becameRoot"))] | length' "$web_file" "$api_file" "$mobile_file" 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
  assert_eq "0" "$leaked" "TC28: __droppedDeps/__becameRoot stripped from output"

  # Every story here is a dependency-free root, so every one of them must carry
  # wave 1 -- the split files are what the executor schedules from, and a story
  # it never reaches in wave 1 is a story it never runs.
  local waves
  waves=$(jq -r '.userStories[].wave' "$mobile_file" "$web_file" "$api_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
  assert_eq "1" "$waves" "TC28: every dependency-free story carries wave 1 in its project file"

  if [ ! -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC28: staging dir deleted after all N writes succeeded"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC28: staging dir NOT deleted"
    ((TESTS_FAILED++))
    rm -rf "$stg"
  fi

  rm -f "$mobile_file" "$web_file" "$api_file" "$out_file" .aimi/tasks/sm-tc28-*.lock
}

# TC29: a story with no .project at all in a multi-repo merge is REFUSED, not
# routed. Once a plan tags a repository, "absent" stops being a defaultable
# value: there is no safe home to invent for a story that named none, so the
# whole merge aborts before any writer runs — zero files, staging dir kept.
#
# SUPERSEDED, NOT BROKEN — do not read this diff as a regression being papered
# over. This case used to assert the exact opposite outcome on this same
# fixture: two tagged repos plus one untagged story were expected to exit 0,
# with the untagged story collected into an IMPLICIT "." root group, producing
# three files. The axis resolver now refuses that shape, because the implicit
# root group was unexecutable in the very layout that created it — execute.md
# maps "." to AIMI_ROOT, and in a multi-repo checkout AIMI_ROOT is not a git
# repository, so the group could never be branched or merged. The "." group
# itself survives as a contract; it just has to be asked for by name now, which
# is what TC47 pins. The staging fixture below is byte-for-byte the old one;
# only the expected outcome inverted, from three files to none.
#
# The old "no spurious empty-project-group warning" leg is dropped rather than
# adapted: the zero-story-group guard it watched was deleted as unreachable
# (group_keys is `unique` over the keys of stories that exist, so no group can
# come out empty), and a merge that refuses before the writer emits no
# per-group warning of any kind.
test_story_merge_project_split_untagged_story_refused() {
  echo ""
  echo "=== TC29: story-merge project axis — an untagged story refuses the merge ==="

  local stg=".aimi/.tasks-staging-tc29"
  local out_file=".aimi/tasks/sm-tc29-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -f .aimi/tasks/sm-tc29-*

  _sm_make_project_story "$stg/01-web.json" "React dashboard page" "apps/web"     "src/pages/Dashboard.tsx"
  _sm_make_project_story "$stg/02-api.json" "Dashboard API"        "services/api" "app/controllers/d.rb"
  # No .project at all — _sm_make_story emits no project key.
  _sm_make_story "$stg/03-root.json" "Repo-wide tooling update" '[]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC29: an untagged story in a multi-repo plan exits 1"

  # The offending story is named individually — a reader has to know WHICH
  # story to tag, not merely that one of them is untagged.
  assert_contains "US-003 (Repo-wide tooling update): no project" "$output" \
    "TC29: the untagged story is named on stderr"
  assert_contains "EVERY story needs a project" "$output" \
    "TC29: the refusal states the multi-repo rule it is enforcing"
  assert_contains "must say so explicitly with \".\"" "$output" \
    "TC29: the refusal points at the explicit root spelling as the fix"

  # Refusal is total: the resolver runs before either writer, so not one of the
  # three groups it would have produced reaches disk.
  local written
  written=$(find .aimi/tasks -maxdepth 1 -name 'sm-tc29-*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$written" "TC29: zero output files land when a story is untagged"

  if [ -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC29: staging dir preserved so the tag can be added and the merge retried"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC29: staging dir deleted despite the merge being refused"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg"
  rm -f .aimi/tasks/sm-tc29-*
}

# TC47: the contract TC29's refusal leaves standing. "." is a legitimate
# project value — the root repository, spelled the way execute.md spells it —
# and a story that asks for it by name gets its own root group alongside the
# other repos. Three groups, three files, the root one slugged to "root"
# because "." carries no [A-Za-z0-9_-] character to keep.
#
# This is the half of the old TC29 that survives the inversion: after TC29
# flipped to asserting a refusal, nothing else covered an explicit "." group at
# all, and "." is the one project value whose slug comes from the fallback
# branch rather than from its own characters.
test_story_merge_project_split_explicit_root_group() {
  echo ""
  echo "=== TC47: story-merge project axis — an explicit '.' forms the root group ==="

  local stg=".aimi/.tasks-staging-tc47"
  local out_file=".aimi/tasks/sm-tc47-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -f .aimi/tasks/sm-tc47-*

  _sm_make_project_story "$stg/01-web.json"  "React dashboard page"     "apps/web"     "src/pages/Dashboard.tsx"
  _sm_make_project_story "$stg/02-api.json"  "Dashboard API"            "services/api" "app/controllers/d.rb"
  _sm_make_project_story "$stg/03-root.json" "Repo-wide tooling update" "."            "Makefile"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC47: an explicitly-rooted story merges cleanly"

  local root_file=".aimi/tasks/sm-tc47-tasks-root-tasks.json"
  local web_file=".aimi/tasks/sm-tc47-tasks-apps-web-tasks.json"
  local api_file=".aimi/tasks/sm-tc47-tasks-services-api-tasks.json"

  local ret_projects
  ret_projects=$(printf '%s' "$output" | jq -r '[.[].project] | join(",")' 2>/dev/null)
  assert_eq ".,apps/web,services/api" "$ret_projects" "TC47: '.' is a group of its own, sorted first"

  if [ -f "$root_file" ] && [ -f "$web_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC47: one file per group, root group included"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC47: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  local root_count root_branch root_project root_title
  root_count=$(jq '.userStories | length' "$root_file" 2>/dev/null)
  root_branch=$(jq -r '.metadata.branchName' "$root_file" 2>/dev/null)
  root_project=$(jq -r '.metadata.splitGroup.project' "$root_file" 2>/dev/null)
  root_title=$(jq -r '.userStories[0].title' "$root_file" 2>/dev/null)
  assert_eq "1" "$root_count" "TC47: the root group file carries its one story"
  assert_eq "Repo-wide tooling update" "$root_title" "TC47: the root group holds the story that asked for '.'"
  assert_eq "feat/merged-root" "$root_branch" "TC47: '.' slugs to a filesystem-safe 'root' branch"
  assert_eq "." "$root_project" "TC47: splitGroup.project keeps the routing key verbatim as '.'"

  # .project survives verbatim on the story too — "." is never rewritten into
  # the "root" slug anywhere but the derived filename and branch.
  local root_story_project
  root_story_project=$(jq -r '[.userStories[].project] | join(",")' "$root_file" 2>/dev/null)
  assert_eq "." "$root_story_project" "TC47: the story keeps .project as '.', not as its slug"

  # Every planned group's file exists and holds exactly the story count the
  # return value advertises — the return value is the plan the executor reads.
  local mismatch=0 i=0 total
  total=$(printf '%s' "$output" | jq 'length' 2>/dev/null)
  while [ "$i" -lt "${total:-0}" ]; do
    local p c actual
    p=$(printf '%s' "$output" | jq -r --argjson i "$i" '.[$i].path')
    c=$(printf '%s' "$output" | jq -r --argjson i "$i" '.[$i].storyCount')
    actual=$(jq '.userStories | length' "$p" 2>/dev/null || echo "MISSING")
    [ "$actual" = "$c" ] || mismatch=1
    i=$((i + 1))
  done
  assert_eq "0" "$mismatch" "TC47: every group's file exists with exactly its advertised storyCount"

  rm -rf "$stg"
  rm -f .aimi/tasks/sm-tc47-*
}

# TC30: a singleton project group (exactly one story) still gets its own file
# instead of being folded into a larger neighbour by any majority rule.
test_story_merge_project_split_singleton_group() {
  echo ""
  echo "=== TC30: story-merge project axis — singleton project group ==="

  local stg=".aimi/.tasks-staging-tc30"
  local out_file=".aimi/tasks/sm-tc30-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  # web-app is the 3-story majority and api-service the lone singleton.
  #
  # This singleton was NOT swallowed before the change -- verified by running
  # the pre-change CLI (3f26992) on this exact fixture: the vote sent web-app's
  # three stories to frontend-tasks.json and the api-service story to
  # backend-tasks.json, one story to itself. What was broken was the FILE SET,
  # not the grouping: two repositories were force-fitted into two side-named
  # files, and it only looked right here because N happened to be 2 and the two
  # groups' majorities happened to disagree. A third repo, or two repos whose
  # majorities agreed, collapsed distinct repositories into one file and one
  # branch -- issue #72. So what this case pins is that a singleton group gets
  # a file of its OWN, named for its project, at any N.
  _sm_make_project_story "$stg/01-ui.json"   "React UserProfile page"      "web-app"     "src/components/UserProfile.tsx"
  _sm_make_project_story "$stg/02-docs.json" "Update documentation"        "web-app"     "docs/setup.md"
  _sm_make_project_story "$stg/03-ui2.json"  "React SettingsPanel"         "web-app"     "src/components/Settings.tsx"
  _sm_make_project_story "$stg/04-api.json"  "UserProfile API endpoint"    "api-service" "app/controllers/u.rb"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC30: singleton-group merge exits 0"

  local api_file=".aimi/tasks/sm-tc30-tasks-api-service-tasks.json"
  local web_file=".aimi/tasks/sm-tc30-tasks-web-app-tasks.json"

  if [ -f "$api_file" ] && [ -f "$web_file" ]; then
    local api_count web_count api_title
    api_count=$(jq '.userStories | length' "$api_file" 2>/dev/null)
    web_count=$(jq '.userStories | length' "$web_file" 2>/dev/null)
    api_title=$(jq -r '.userStories[0].title' "$api_file" 2>/dev/null)
    assert_eq "1" "$api_count" "TC30: singleton group keeps its own file (never absorbed by the majority)"
    assert_eq "3" "$web_count" "TC30: majority group keeps all 3 of its stories"
    assert_eq "UserProfile API endpoint" "$api_title" "TC30: the singleton story is the api-service one"
  else
    echo -e "${RED}✗${NC} TC30: expected per-project files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
    ((TESTS_FAILED++))
  fi

  # The docs-only story rides its project, not a heuristic side verdict.
  local docs_home
  docs_home=$(jq -r '[.userStories[] | select(.title == "Update documentation")] | length' "$web_file" 2>/dev/null)
  assert_eq "1" "$docs_home" "TC30: docs-only story stays with its own project group"

  rm -rf "$stg"
  rm -f "$api_file" "$web_file" "$out_file" .aimi/tasks/sm-tc30-*.lock
}

# TC31: a project value containing "/" is transliterated into a filesystem-safe
# basename slug — never passed through raw — and its derived branchName still
# satisfies the ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ invariant.
test_story_merge_project_split_slash_project_slug() {
  echo ""
  echo "=== TC31: story-merge project axis — project value containing '/' ==="

  local stg=".aimi/.tasks-staging-tc31"
  local out_file=".aimi/tasks/sm-tc31-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_project_story "$stg/01-ui.json"  "Shared UI kit"  "packages/ui/components" "packages/ui/components/Button.tsx"
  _sm_make_project_story "$stg/02-api.json" "Billing API"    "services/billing"       "app/controllers/b.rb"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC31: slash-bearing project merge exits 0"

  local ui_file=".aimi/tasks/sm-tc31-tasks-packages-ui-components-tasks.json"
  local billing_file=".aimi/tasks/sm-tc31-tasks-services-billing-tasks.json"

  if [ -f "$ui_file" ]; then
    echo -e "${GREEN}✓${NC} TC31: 'packages/ui/components' flattened to a single-component basename"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC31: slash-flattened output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  # The "no .aimi/tasks/packages directory was created" leg is deliberately
  # absent. mkdir -p is called on dirname($output_path) and on nothing else, so
  # no project value -- raw or slugged -- can reach a directory component; the
  # check could not fail for any edit to this writer. The property it was
  # reaching for is the one the file-by-name assertion above already carries:
  # the slug lands as a single basename component, not as a path.

  local ui_branch verbatim_project
  ui_branch=$(jq -r '.metadata.branchName' "$ui_file" 2>/dev/null)
  verbatim_project=$(jq -r '.metadata.splitGroup.project' "$ui_file" 2>/dev/null)
  assert_eq "feat/merged-packages-ui-components" "$ui_branch" "TC31: branchName derived from the slug, not the raw path"
  assert_eq "packages/ui/components" "$verbatim_project" "TC31: splitGroup.project keeps the routing key verbatim"

  if [[ "$ui_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo -e "${GREEN}✓${NC} TC31: derived branchName satisfies the branch-name invariant"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC31: derived branchName violates the branch-name invariant: $ui_branch"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg"
  rm -f "$ui_file" "$billing_file" "$out_file" .aimi/tasks/sm-tc31-*.lock
}

# TC32: a project value containing "." is transliterated too, so nothing can
# inject an extra extension segment or a ".." component into the output path.
test_story_merge_project_split_dot_project_slug() {
  echo ""
  echo "=== TC32: story-merge project axis — project value containing '.' ==="

  local stg=".aimi/.tasks-staging-tc32"
  local out_file=".aimi/tasks/sm-tc32-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"

  _sm_make_project_story "$stg/01-core.json" "Core utils refactor" "libs/core.utils" "libs/core.utils/index.ts"
  _sm_make_project_story "$stg/02-api.json"  "Reports API"         "services/reports" "app/controllers/r.rb"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC32: dot-bearing project merge exits 0"

  local core_file=".aimi/tasks/sm-tc32-tasks-libs-core-utils-tasks.json"
  local reports_file=".aimi/tasks/sm-tc32-tasks-services-reports-tasks.json"

  if [ -f "$core_file" ]; then
    echo -e "${GREEN}✓${NC} TC32: 'libs/core.utils' dot transliterated into the basename slug"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC32: dot-transliterated output file missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  local ret_path core_branch
  ret_path=$(printf '%s' "$output" | jq -r '.[] | select(.project == "libs/core.utils") | .path' 2>/dev/null)
  core_branch=$(jq -r '.metadata.branchName' "$core_file" 2>/dev/null)
  assert_eq "$core_file" "$ret_path" "TC32: return value reports the slugged path"
  assert_eq "feat/merged-libs-core-utils" "$core_branch" "TC32: dots never reach the derived branchName"

  rm -rf "$stg"
  rm -f "$core_file" "$reports_file" "$out_file" .aimi/tasks/sm-tc32-*.lock
}

# TC33: two distinct project values that flatten to the same basename slug are
# a hard failure BEFORE any write — zero output files land and the error names
# both colliding project values.
test_story_merge_project_split_basename_collision() {
  echo ""
  echo "=== TC33: story-merge project axis — colliding basename slugs hard-fail ==="

  local stg=".aimi/.tasks-staging-tc33"
  local out_file=".aimi/tasks/sm-tc33-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -f .aimi/tasks/sm-tc33-*

  # "apps/web" and "apps.web" both slugify to "apps-web".
  _sm_make_project_story "$stg/01-a.json" "Slash flavored"  "apps/web" "src/a.ts"
  _sm_make_project_story "$stg/02-b.json" "Dot flavored"    "apps.web" "src/b.ts"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC33: basename collision exits 1"
  assert_contains "collide on the same output basename" "$output" "TC33: error names the collision"
  assert_contains "apps/web" "$output" "TC33: error names the first colliding project value"
  assert_contains "apps.web" "$output" "TC33: error names the second colliding project value"

  local written
  written=$(find .aimi/tasks -maxdepth 1 -name 'sm-tc33-*' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$written" "TC33: zero output files land when the collision is detected"

  if [ -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC33: staging dir preserved for an unambiguous retry"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC33: staging dir deleted despite the merge failing"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg"
  rm -f .aimi/tasks/sm-tc33-*
}

# TC34: on the PROJECT axis, every cross-file-dep-dropped smellWarnings entry is
# keyed by `project` (the owning group's routing key) at BOTH the top level and
# inside every droppedDeps[] entry — never by `side`, which stays exclusive to
# the SIDE-axis writer. The combined set spans all 3 project groups and is
# written identically into all 3 output files. Without --foundation, every
# droppedDeps[].foundationEdge is false and the foundation note line is silent.
test_story_merge_project_split_project_keyed_warnings() {
  echo ""
  echo "=== TC34: story-merge project axis — cross-group drops keyed by project, not side ==="

  local stg=".aimi/.tasks-staging-tc34"
  local out_file=".aimi/tasks/sm-tc34-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -f .aimi/tasks/sm-tc34-*

  # 3 distinct projects. Two cross-group edges (both onto the api story) and
  # one same-group edge that must survive untouched.
  _sm_make_project_story "$stg/01-api.json"    "UserProfile API endpoint" "services/api" "app/controllers/u.rb"
  _sm_make_project_story "$stg/02-web.json"    "React UserProfile page"   "apps/web"     "src/components/UserProfile.tsx" '["outline:01"]'
  _sm_make_project_story "$stg/03-mobile.json" "Mobile profile screen"    "apps/mobile"  "lib/profile.dart"               '["outline:01"]'
  _sm_make_project_story "$stg/04-web2.json"   "React SettingsPanel"      "apps/web"     "src/components/Settings.tsx"    '["outline:02"]'

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC34: project-axis cross-group drop exits 0 (warning only)"
  assert_contains "cross-project dependsOn edge(s) dropped" "$output" "TC34: aggregated stderr banner emitted"

  local mobile_file=".aimi/tasks/sm-tc34-tasks-apps-mobile-tasks.json"
  local web_file=".aimi/tasks/sm-tc34-tasks-apps-web-tasks.json"
  local api_file=".aimi/tasks/sm-tc34-tasks-services-api-tasks.json"

  # File existence is ONE assertion, and the body below runs unconditionally.
  # Holding the body inside a guard whose else recorded a single failure made a
  # missing file cost one reported failure instead of one per assertion it
  # actually skipped. Every read below goes through jq with stderr discarded,
  # so a missing file surfaces as an empty value and each assertion fails on
  # its own terms.
  if [ -f "$mobile_file" ] && [ -f "$web_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC34: one tasks file written per distinct project"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC34: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  # The same combined set lands in every one of the N files. Each set's SIZE is
  # pinned first: comparing two values pulled from one run says nothing when
  # both are [], and an empty set is exactly what a writer that stopped
  # recording drops would produce. 3 entries, not 2 -- the combined set is the
  # Phase 4.2 array plus the cross-group drops, so this also pins that the two
  # sources really are merged into every file rather than one replacing the
  # other.
  local mobile_smells web_smells api_smells
  mobile_smells=$(jq -c '.metadata.smellWarnings // []' "$mobile_file" 2>/dev/null)
  web_smells=$(jq -c '.metadata.smellWarnings // []' "$web_file" 2>/dev/null)
  api_smells=$(jq -c '.metadata.smellWarnings // []' "$api_file" 2>/dev/null)
  assert_eq "3" "$(printf '%s' "$mobile_smells" | jq 'length' 2>/dev/null)" "TC34: the mobile file carries all 3 combined smellWarnings entries"
  assert_eq "3" "$(printf '%s' "$web_smells" | jq 'length' 2>/dev/null)" "TC34: the web file carries all 3 combined smellWarnings entries"
  assert_eq "3" "$(printf '%s' "$api_smells" | jq 'length' 2>/dev/null)" "TC34: the api file carries all 3 combined smellWarnings entries"
  assert_eq "$mobile_smells" "$web_smells" "TC34: mobile and web files carry the identical smellWarnings set"
  assert_eq "$web_smells" "$api_smells" "TC34: web and api files carry the identical smellWarnings set"

  # The union spans all N groups, not just two: one entry per affected story,
  # and the affected stories live in two different project groups.
  local entry_count entry_projects
  entry_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped")] | length' "$web_file" 2>/dev/null)
  entry_projects=$(jq -r '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .project] | sort | join(",")' "$web_file" 2>/dev/null)
  assert_eq "2" "$entry_count" "TC34: one cross-file-dep-dropped entry per affected story"
  assert_eq "apps/mobile,apps/web" "$entry_projects" "TC34: entries keyed by their own project group across the N-way union"

  # `project` replaces `side` at BOTH levels — `side` must not appear at all.
  local top_side_count dep_side_count dep_project_count
  top_side_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | select(has("side"))] | length' "$web_file" 2>/dev/null)
  dep_side_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .droppedDeps[] | select(has("side"))] | length' "$web_file" 2>/dev/null)
  dep_project_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .droppedDeps[] | select(has("project"))] | length' "$web_file" 2>/dev/null)
  assert_eq "0" "$top_side_count" "TC34: no entry carries a top-level side key on the project axis"
  assert_eq "0" "$dep_side_count" "TC34: no droppedDeps entry carries a side key on the project axis"
  assert_eq "2" "$dep_project_count" "TC34: every droppedDeps entry carries a project key"

  # The dropped target resolves to its post-remap id in its OWN project group.
  local web_entry
  web_entry=$(jq -c '.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | select(.project == "apps/web")' "$web_file" 2>/dev/null)
  assert_contains '"storyId":"US-002"' "$web_entry" "TC34: entry storyId is the post-remap id in its own group"
  assert_contains '"becameRoot":true' "$web_entry" "TC34: the story lost its only dependsOn edge and became a false root"
  assert_contains '"id":"US-004"' "$web_entry" "TC34: droppedDeps target is the post-remap id in the api group"
  assert_contains '"project":"services/api"' "$web_entry" "TC34: droppedDeps target is keyed by the target's project"

  # No --foundation on this run: every edge is an ordinary drop.
  local foundation_true_count
  foundation_true_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .droppedDeps[] | select(.foundationEdge == true)] | length' "$web_file" 2>/dev/null)
  assert_eq "0" "$foundation_true_count" "TC34: no foundationEdge is true when --foundation was not passed"

  # The same-group edge survived: US-003 still depends on US-002 in-file.
  local kept_dep
  kept_dep=$(jq -r '.userStories[] | select(.id == "US-003") | .dependsOn | join(",")' "$web_file" 2>/dev/null)
  assert_eq "US-002" "$kept_dep" "TC34: the same-group dependsOn edge is untouched"

  # Waves are recomputed PER GROUP, after the cross-group edges are dropped.
  # This is the scenario that makes it matter: US-002 and US-001 were wave 2 in
  # the whole-plan graph purely because they depended on the api story, and
  # that dependency is gone from their files. Shipping them at wave 2 leaves
  # the executor's first wave with nothing to schedule in either repo, and
  # US-003 -- which really does wait on an in-file sibling -- must still land
  # one wave behind it rather than at the plan-wide 3.
  local web_wave_002 web_wave_003 mobile_wave api_wave
  web_wave_002=$(jq -r '.userStories[] | select(.id == "US-002") | .wave' "$web_file" 2>/dev/null)
  web_wave_003=$(jq -r '.userStories[] | select(.id == "US-003") | .wave' "$web_file" 2>/dev/null)
  mobile_wave=$(jq -r '.userStories[] | select(.id == "US-001") | .wave' "$mobile_file" 2>/dev/null)
  api_wave=$(jq -r '.userStories[] | select(.id == "US-004") | .wave' "$api_file" 2>/dev/null)
  assert_eq "1" "$web_wave_002" "TC34: the false-root story is rebased to wave 1 in its own file"
  assert_eq "1" "$mobile_wave" "TC34: the mobile false root is rebased to wave 1 too"
  assert_eq "2" "$web_wave_003" "TC34: the story depending on that false root follows at wave 2"
  assert_eq "1" "$api_wave" "TC34: the untouched api root stays at wave 1"

  # The false-root enumeration lines name the project, not a side literal.
  assert_contains "US-002 (apps/web): became a false wave-1 root" "$output" "TC34: false-root stderr line names the owning project"

  if echo "$output" | grep -q "shared --foundation story"; then
    echo -e "${RED}✗${NC} TC34: foundation note line fired without --foundation"
    echo "  output: $output"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC34: foundation note line silent without --foundation"
    ((TESTS_PASSED++))
  fi

  rm -rf "$stg"
  rm -f .aimi/tasks/sm-tc34-*
}

# TC35: --foundation combined with a multi-repo split. The foundation story
# lives in exactly one project group, so every OTHER group's injected edge onto
# it is dropped — recorded with foundationEdge:true, a message that names the
# shared foundation story, and one stderr note line distinct from the ordinary
# drop-count banner.
test_story_merge_project_split_foundation_edge() {
  echo ""
  echo "=== TC35: story-merge project axis — --foundation cross-group edges flagged distinctly ==="

  local stg=".aimi/.tasks-staging-tc35"
  local out_file=".aimi/tasks/sm-tc35-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -f .aimi/tasks/sm-tc35-*

  # outline:01 is the foundation and lives in packages/core; the other two
  # stories live in different repos and carry no hand-authored dependency.
  _sm_make_project_story "$stg/01-core.json" "Shared core contracts" "packages/core" "src/contracts.ts"
  _sm_make_project_story "$stg/02-web.json"  "React UserProfile page" "apps/web"     "src/components/UserProfile.tsx"
  _sm_make_project_story "$stg/03-api.json"  "UserProfile API endpoint" "services/api" "app/controllers/u.rb"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack --foundation 01 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC35: --foundation + multi-repo split exits 0 (warning only)"

  # Two lines, not one: the ordinary drop-count banner AND a separate note.
  assert_contains "cross-project dependsOn edge(s) dropped" "$output" "TC35: ordinary drop-count banner still emitted"
  assert_contains "target the shared --foundation story" "$output" "TC35: distinct foundation note line emitted"

  local note_line banner_line
  note_line=$(printf '%s\n' "$output" | grep -c "target the shared --foundation story" || true)
  banner_line=$(printf '%s\n' "$output" | grep -c "cross-project dependsOn edge(s) dropped across" || true)
  assert_eq "1" "$note_line" "TC35: exactly one foundation note line"
  assert_eq "1" "$banner_line" "TC35: the note is separate from the single drop-count banner"

  if printf '%s\n' "$output" | grep "cross-project dependsOn edge(s) dropped across" | grep -q -- "--foundation"; then
    echo -e "${RED}✗${NC} TC35: foundation wording leaked into the ordinary drop-count banner"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC35: the drop-count banner stays free of foundation wording"
    ((TESTS_PASSED++))
  fi

  local web_file=".aimi/tasks/sm-tc35-tasks-apps-web-tasks.json"
  local core_file=".aimi/tasks/sm-tc35-tasks-packages-core-tasks.json"
  local api_file=".aimi/tasks/sm-tc35-tasks-services-api-tasks.json"

  # File existence is ONE assertion, and the body below runs unconditionally,
  # so a missing file costs one reported failure per assertion it skips rather
  # than one for all of them. Every read discards jq's stderr, so a missing
  # file yields an empty value and each assertion fails on its own terms.
  if [ -f "$web_file" ] && [ -f "$core_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC35: one tasks file written per distinct project"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC35: expected per-project output files missing"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  local foundation_true_count total_dep_count
  foundation_true_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .droppedDeps[] | select(.foundationEdge == true)] | length' "$web_file" 2>/dev/null)
  total_dep_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | .droppedDeps[]] | length' "$web_file" 2>/dev/null)
  assert_eq "2" "$foundation_true_count" "TC35: both non-foundation groups record a foundationEdge:true entry"
  assert_eq "2" "$total_dep_count" "TC35: every dropped edge on this run is a foundation edge"

  local web_entry
  web_entry=$(jq -c '.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | select(.project == "apps/web")' "$web_file" 2>/dev/null)
  assert_contains '"foundationEdge":true' "$web_entry" "TC35: the web group's dropped edge is flagged as a foundation edge"
  assert_contains '"project":"packages/core"' "$web_entry" "TC35: the dropped target is attributed to the foundation's own project"
  assert_contains "shared --foundation story" "$web_entry" "TC35: the story-level message names the shared foundation story"
  assert_contains '"becameRoot":true' "$web_entry" "TC35: the injected edge loss makes the story a false wave-1 root"

  # The foundation's own group has no dropped edge at all.
  local core_entry_count
  core_entry_count=$(jq '[.metadata.smellWarnings[] | select(.type == "cross-file-dep-dropped") | select(.project == "packages/core")] | length' "$core_file" 2>/dev/null)
  assert_eq "0" "$core_entry_count" "TC35: the group hosting the foundation records no dropped edge"

  # Internal working keys never leak.
  local leaked
  leaked=$(jq '[.userStories[] | select(has("__droppedDeps") or has("__becameRoot"))] | length' "$web_file" 2>/dev/null)
  assert_eq "0" "$leaked" "TC35: internal __droppedDeps/__becameRoot absent from output"

  # --foundation put every non-foundation story one wave behind the foundation
  # plan-wide; each of them then lost that edge to the split. Their files must
  # say wave 1, not the plan-wide 2 -- otherwise the executor opens on an empty
  # wave in both of the two repos that have no foundation story to run.
  local web_wave core_wave api_wave
  web_wave=$(jq -r '.userStories[0].wave' "$web_file" 2>/dev/null)
  core_wave=$(jq -r '.userStories[0].wave' "$core_file" 2>/dev/null)
  api_wave=$(jq -r '.userStories[0].wave' "$api_file" 2>/dev/null)
  assert_eq "1" "$web_wave" "TC35: the web story is rebased to wave 1 after losing the foundation edge"
  assert_eq "1" "$api_wave" "TC35: the api story is rebased to wave 1 after losing the foundation edge"
  assert_eq "1" "$core_wave" "TC35: the foundation story itself stays at wave 1"

  rm -rf "$stg"
  rm -f .aimi/tasks/sm-tc35-*
}

# TC48: --phase-aware crossed with the PROJECT axis. Both writers strip one
# trailing "-tasks" segment from the --output basename, but only the SIDE one
# was ever covered: TC12's fixture carries no .project at all, so it can only
# reach _story_merge_write_split. The PROJECT writer's own copy of the strip
# went unexercised, and deleting it produced exactly the double-"tasks"
# basename TC12 forbids -- on files no case looked at.
#
# A phase-scoped output path must collapse here too:
#   <feature>-phase-N-<slug>-tasks.json, never <feature>-phase-N-tasks-<slug>-tasks.json
test_story_merge_project_split_phase_aware() {
  echo ""
  echo "=== TC48: story-merge project axis + --phase-aware ==="

  local stg=".aimi/.tasks-staging-tc48"
  local phase_dir=".aimi/tasks/tc48-feature/phase-3-slug"
  local out_file="${phase_dir}/tc48-feature-phase-3-tasks.json"
  rm -rf "$stg" ".aimi/tasks/tc48-feature"
  mkdir -p "$stg" "$phase_dir"

  _sm_make_project_story "$stg/01-web.json" "React UserProfile page"   "apps/web"     "src/components/UserProfile.tsx"
  _sm_make_project_story "$stg/02-api.json" "UserProfile API endpoint" "services/api" "app/controllers/u.rb"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack --phase-aware 2>/dev/null) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC48: project-axis split --phase-aware exits 0"

  local web_file="${phase_dir}/tc48-feature-phase-3-apps-web-tasks.json"
  local api_file="${phase_dir}/tc48-feature-phase-3-services-api-tasks.json"
  local web_double="${phase_dir}/tc48-feature-phase-3-tasks-apps-web-tasks.json"
  local api_double="${phase_dir}/tc48-feature-phase-3-tasks-services-api-tasks.json"

  if [ -f "$web_file" ] && [ -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC48: per-project files written with single-'tasks' basenames"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC48: single-'tasks' per-project basenames missing ($web_file / $api_file)"
    echo "  CLI output: $output"
    ((TESTS_FAILED++))
  fi

  if [ ! -f "$web_double" ] && [ ! -f "$api_double" ]; then
    echo -e "${GREEN}✓${NC} TC48: --phase-aware suppresses the double-'tasks' basename on the project axis"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC48: double-'tasks' basename produced despite --phase-aware ($web_double)"
    ((TESTS_FAILED++))
  fi

  # The return value and the splitGroup marker must name the same collapsed
  # paths the files actually landed at -- a marker pointing at the double-tasks
  # spelling would send every downstream consumer to a file that is not there.
  local ret_paths sibling_of_web
  ret_paths=$(printf '%s' "$output" | jq -r '[.[].path] | sort | join(",")' 2>/dev/null)
  sibling_of_web=$(jq -r '[.metadata.splitGroup.siblings[]] | join(",")' "$web_file" 2>/dev/null)
  assert_eq "$web_file,$api_file" "$ret_paths" "TC48: the return value reports the collapsed paths"
  assert_eq "$api_file" "$sibling_of_web" "TC48: splitGroup.siblings points at the collapsed sibling path"

  rm -rf "$stg" ".aimi/tasks/tc48-feature"
}

# TC49: a mid-loop write failure. The N-file writer is not atomic across the
# set -- it writes group by group -- so when group k fails, groups 1..k-1 are
# already on disk, each advertising a splitGroup.total and a siblings[] list
# describing a complete split that does not exist. The handler's whole job is
# to name all three sets so the reader knows which of those advertised siblings
# landed and which never will.
#
# Until recently this was dead code: `set -euo pipefail` killed the script at
# the failing write, before the `write_exit` check could run, leaving exactly
# that half-written set with no message at all. Nothing exercised it.
#
# The failure is induced by putting a DIRECTORY where the middle group's lock
# file goes, which makes the `200>` redirect fail without touching anything
# else -- the earlier group still writes normally and the later one is never
# reached.
test_story_merge_project_split_partial_write_failure() {
  echo ""
  echo "=== TC49: story-merge project axis — mid-loop write failure names all three sets ==="

  local stg=".aimi/.tasks-staging-tc49"
  local out_file=".aimi/tasks/sm-tc49-tasks.json"
  rm -rf "$stg"
  mkdir -p "$stg"
  rm -rf .aimi/tasks/sm-tc49-*

  # Three groups, lexicographic: apps/mobile (writes), apps/web (fails),
  # services/api (never attempted).
  _sm_make_project_story "$stg/01-mobile.json" "Mobile profile screen"    "apps/mobile"  "lib/profile.dart"
  _sm_make_project_story "$stg/02-web.json"    "React UserProfile page"   "apps/web"     "src/components/UserProfile.tsx"
  _sm_make_project_story "$stg/03-api.json"    "UserProfile API endpoint" "services/api" "app/controllers/u.rb"

  local mobile_file=".aimi/tasks/sm-tc49-tasks-apps-mobile-tasks.json"
  local web_file=".aimi/tasks/sm-tc49-tasks-apps-web-tasks.json"
  local api_file=".aimi/tasks/sm-tc49-tasks-services-api-tasks.json"

  mkdir -p "${web_file}.lock"

  local output exit_code
  output=$("$CLI" story-merge --staging-dir "$stg" --output "$out_file" --split full-stack 2>&1) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC49: a failed group write exits 1"

  # All three sets, each named explicitly.
  assert_contains "failed to write project split output: $web_file" "$output" "TC49: the failing path is named"
  assert_contains "Written before this failure (1):" "$output" "TC49: the written set is counted"
  assert_contains "    $mobile_file" "$output" "TC49: the written set names the group already on disk"
  assert_contains "Not attempted (1):" "$output" "TC49: the not-attempted set is counted"
  assert_contains "    $api_file" "$output" "TC49: the not-attempted set names the group never reached"
  assert_contains "Staging dir preserved for retry:" "$output" "TC49: the report points at the preserved staging dir"

  # The report has to match the disk, or it is worse than no report.
  if [ -f "$mobile_file" ]; then
    echo -e "${GREEN}✓${NC} TC49: the group written before the failure is still on disk"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC49: the earlier group is reported as written but is not on disk"
    ((TESTS_FAILED++))
  fi

  if [ ! -f "$web_file" ] && [ ! -f "$api_file" ]; then
    echo -e "${GREEN}✓${NC} TC49: neither the failed nor the not-attempted group left a file"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC49: a group reported as failed or not attempted has a file on disk"
    ((TESTS_FAILED++))
  fi

  # The mktemp scratch file for the failed group is cleaned up on the way out.
  local orphans
  orphans=$(find .aimi/tasks -maxdepth 1 -name 'sm-tc49-*.json.??????' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$orphans" "TC49: no orphaned mktemp file survives the failed write"

  if [ -d "$stg" ]; then
    echo -e "${GREEN}✓${NC} TC49: staging dir preserved so the write can be retried"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} TC49: staging dir deleted despite a group failing to write"
    ((TESTS_FAILED++))
  fi

  rm -rf "$stg"
  rm -rf .aimi/tasks/sm-tc49-*
}

# ============================================================================
# split-detect Tests (TC36-TC46, TC50-TC53)
# ============================================================================
# The read side of metadata.splitGroup. Every rule here used to live only in
# execute.md's executable prose — twice, in two already-divergent copies — where
# no Bash suite could reach it.
#
# Each case builds its OWN isolated project directory. split-detect's flat scope
# is every *-tasks.json sitting directly in .aimi/tasks, so the shared TEST_DIR
# fixture would otherwise join the candidate pool and change the answer.
#
# Relative mtimes are set with `touch -t` rather than `sleep`, because "newest
# wins" is the rule under test and it must be pinned exactly, not raced.

_SD_OLD_MTIME="202001010000"
_SD_NEW_MTIME="202601010000"

# _sd_stories <status>... -> JSON array of minimal user stories, one per status.
# Zero arguments yields [], the empty-group file the N-file writer legitimately
# emits for a project that ended up with no stories.
_sd_stories() {
  local out="[]" i=1 st
  for st in "$@"; do
    out=$(printf '%s' "$out" | jq -c \
      --arg id "US-$(printf '%03d' "$i")" --arg s "$st" \
      '. + [{id: $id, title: "s", description: "d", acceptanceCriteria: [],
             status: $s, dependsOn: [],
             implementation: {files: [], approach: "a", verify: "v"}}]')
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# _sd_write <path> <branchName> <stories-json> [<splitGroup-json>]
_sd_write() {
  local path="$1" branch="$2" stories="$3" marker="${4:-}"
  local meta
  if [ -n "$marker" ]; then
    meta=$(jq -nc --arg b "$branch" --argjson sg "$marker" \
      '{title: "feat: t", type: "feat", branchName: $b, splitGroup: $sg}')
  else
    meta=$(jq -nc --arg b "$branch" '{title: "feat: t", type: "feat", branchName: $b}')
  fi
  jq -nc --argjson m "$meta" --argjson s "$stories" \
    '{schemaVersion: "3.3", metadata: $m, userStories: $s}' > "$path"
}

# _sd_run <project-dir> [args...] -> split-detect stdout, stderr discarded
_sd_run() {
  local dir="$1"; shift
  ( cd "$dir" && "$CLI" split-detect "$@" 2>/dev/null )
}

# Basenames of the reported members, in reported order, comma-joined.
_sd_member_names() {
  printf '%s' "$1" | jq -r '[.members[].path | split("/") | last] | join(",")'
}

# TC36: the happy path — a 3-member project split whose members are all active
# is reported whole, anchor first, siblings in the anchor's declared order.
test_split_detect_project_split_three_members() {
  echo ""
  echo "=== TC36: split-detect — 3-member project split, all active ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-billing-apps-web-tasks.json" "feat/billing-apps-web" \
    "$(_sd_stories pending)" \
    '{"project":"apps/web","index":1,"total":3,"siblings":[".aimi/tasks/2026-07-27-billing-services-api-tasks.json",".aimi/tasks/2026-07-27-billing-packages-core-tasks.json"]}'
  _sd_write "$t/2026-07-27-billing-services-api-tasks.json" "feat/billing-services-api" \
    "$(_sd_stories pending pending)" \
    '{"project":"services/api","index":2,"total":3,"siblings":[".aimi/tasks/2026-07-27-billing-apps-web-tasks.json",".aimi/tasks/2026-07-27-billing-packages-core-tasks.json"]}'
  _sd_write "$t/2026-07-27-billing-packages-core-tasks.json" "feat/billing-packages-core" \
    "$(_sd_stories pending)" \
    '{"project":"packages/core","index":3,"total":3,"siblings":[".aimi/tasks/2026-07-27-billing-apps-web-tasks.json",".aimi/tasks/2026-07-27-billing-services-api-tasks.json"]}'
  touch -t "$_SD_OLD_MTIME" "$t"/*.json
  touch -t "$_SD_NEW_MTIME" "$t/2026-07-27-billing-apps-web-tasks.json"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC36: split-detect exits 0"
  assert_eq "project-split" "$(printf '%s' "$out" | jq -r '.mode')" "TC36: mode is project-split"
  assert_eq "3" "$(printf '%s' "$out" | jq -r '.total')" "TC36: total is the declared 3"
  assert_eq "3" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC36: all three members are active"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.degradedReason')" "TC36: nothing degraded"
  assert_contains "2026-07-27-billing-apps-web-tasks.json" \
    "$(printf '%s' "$out" | jq -r '.anchor')" "TC36: the newest file is the anchor"
  assert_eq \
    "2026-07-27-billing-apps-web-tasks.json,2026-07-27-billing-services-api-tasks.json,2026-07-27-billing-packages-core-tasks.json" \
    "$(_sd_member_names "$out")" "TC36: anchor first, then siblings in declared order"
  assert_eq "apps/web,services/api,packages/core" \
    "$(printf '%s' "$out" | jq -r '[.members[].project] | join(",")')" \
    "TC36: each member reports its own splitGroup.project"
  assert_eq "feat/billing-apps-web,feat/billing-services-api,feat/billing-packages-core" \
    "$(printf '%s' "$out" | jq -r '[.members[].branchName] | join(",")')" \
    "TC36: each member reports its own metadata.branchName"
  assert_eq "1,2,1" "$(printf '%s' "$out" | jq -r '[.members[].storyCount] | join(",")')" \
    "TC36: per-member storyCount"
  assert_eq "1,2,1" "$(printf '%s' "$out" | jq -r '[.members[].pendingCount] | join(",")')" \
    "TC36: per-member pendingCount"

  rm -rf "$d"
}

# TC37: THE DEFECT THIS VERB EXISTS TO CLOSE. find-tasks-all globs depth 1-3,
# which includes phase directories — so a PROJECT-axis phase's split files were
# captured by the flat flow and executed as a flat split, leaving the phase
# unclaimed and nothing merged into the phase branch. Flat scope is depth 1.
test_split_detect_flat_scope_excludes_phase_dir() {
  echo ""
  echo "=== TC37: split-detect — a phase directory's split is NOT visible to the flat scope ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks/myfeat/phase-2-auth"
  local p="$d/.aimi/tasks/myfeat/phase-2-auth"

  _sd_write "$p/myfeat-phase-2-tasks.json" "feat/myfeat-phase-2" "$(_sd_stories pending)"
  _sd_write "$p/myfeat-phase-2-apps-web-tasks.json" "feat/myfeat-phase-2-apps-web" \
    "$(_sd_stories pending)" \
    '{"project":"apps/web","index":1,"total":2,"siblings":["myfeat-phase-2-services-api-tasks.json"]}'
  _sd_write "$p/myfeat-phase-2-services-api-tasks.json" "feat/myfeat-phase-2-services-api" \
    "$(_sd_stories pending)" \
    '{"project":"services/api","index":2,"total":2,"siblings":["myfeat-phase-2-apps-web-tasks.json"]}'

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC37: flat query over a phase-only layout still exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC37: the phase's split is not matched by the flat scope"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.members | length')" \
    "TC37: no phase file leaks into the flat member list"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.total')" "TC37: total is 0"

  rm -rf "$d"
}

# TC38: the same directory, queried with --dir, IS matched — and the phase's own
# governing <feature>-phase-<N>-tasks.json is excluded from the candidate pool.
test_split_detect_dir_scope_matches_phase_split() {
  echo ""
  echo "=== TC38: split-detect --dir — the same phase split IS matched ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks/myfeat/phase-2-auth"
  local p="$d/.aimi/tasks/myfeat/phase-2-auth"

  _sd_write "$p/myfeat-phase-2-tasks.json" "feat/myfeat-phase-2" "$(_sd_stories pending)"
  _sd_write "$p/myfeat-phase-2-apps-web-tasks.json" "feat/myfeat-phase-2-apps-web" \
    "$(_sd_stories pending)" \
    '{"project":"apps/web","index":1,"total":2,"siblings":["myfeat-phase-2-services-api-tasks.json"]}'
  _sd_write "$p/myfeat-phase-2-services-api-tasks.json" "feat/myfeat-phase-2-services-api" \
    "$(_sd_stories pending)" \
    '{"project":"services/api","index":2,"total":2,"siblings":["myfeat-phase-2-apps-web-tasks.json"]}'
  # Make the phase's own governing file the newest, so an anchor picked without
  # the exclusion would land on it.
  touch -t "$_SD_OLD_MTIME" "$p"/*.json
  touch -t "$_SD_NEW_MTIME" "$p/myfeat-phase-2-tasks.json"

  local out exit_code
  out=$(_sd_run "$d" --dir "$p") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC38: --dir query exits 0"
  assert_eq "project-split" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC38: --dir scope matches the phase's project split"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.total')" "TC38: total is 2"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC38: both members active"
  local names; names=$(_sd_member_names "$out")
  assert_contains "myfeat-phase-2-apps-web-tasks.json" "$names" "TC38: web member present"
  assert_contains "myfeat-phase-2-services-api-tasks.json" "$names" "TC38: api member present"
  assert_eq "0" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select((.path | split("/") | last) == "myfeat-phase-2-tasks.json")] | length')" \
    "TC38: the phase's own governing tasks file is excluded from the pool"

  rm -rf "$d"
}

# TC39: a completed stale split must not route today's real work to a
# single-file fallback. Its members are dropped whole and the search repeats,
# so the fresh legacy pair beside it wins.
test_split_detect_completed_stale_group_yields_to_fresh_pair() {
  echo ""
  echo "=== TC39: split-detect — a fully completed stale split yields to the fresh legacy pair ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  git init -q "$d" >/dev/null 2>&1
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-01-01-old-a-tasks.json" "feat/old-a" "$(_sd_stories completed)" \
    '{"project":"a","index":1,"total":2,"siblings":["2026-01-01-old-b-tasks.json"]}'
  _sd_write "$t/2026-01-01-old-b-tasks.json" "feat/old-b" "$(_sd_stories completed)" \
    '{"project":"b","index":2,"total":2,"siblings":["2026-01-01-old-a-tasks.json"]}'
  _sd_write "$t/2026-07-27-live-frontend-tasks.json" "feat/live-frontend" "$(_sd_stories pending)"
  _sd_write "$t/2026-07-27-live-backend-tasks.json" "feat/live-backend" "$(_sd_stories pending)"
  # The STALE group is the newest on disk — without the drop-and-repeat rule
  # "newest wins" would hand back the finished split.
  touch -t "$_SD_OLD_MTIME" "$t"/2026-07-27-live-*.json
  touch -t "$_SD_NEW_MTIME" "$t"/2026-01-01-old-*.json

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC39: exits 0"
  assert_eq "paired-split" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC39: the fresh legacy pair wins, not the completed stale group"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC39: both pair members active"
  assert_eq "2026-07-27-live-frontend-tasks.json,2026-07-27-live-backend-tasks.json" \
    "$(_sd_member_names "$out")" "TC39: frontend first, backend second"
  assert_eq "0" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("old-"))] | length')" \
    "TC39: no member of the stale group survives into the answer"

  rm -rf "$d"
}

# TC40: "newest wins" replaces "first marker-carrying file in mtime order".
# A stale marked split with PENDING members must not preempt today's plan just
# because today's files carry no marker of their own.
test_split_detect_newest_wins_over_older_marked_group() {
  echo ""
  echo "=== TC40: split-detect — a newer unmarked pair beats an older marked group with pending work ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  git init -q "$d" >/dev/null 2>&1
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-01-01-old-a-tasks.json" "feat/old-a" "$(_sd_stories pending)" \
    '{"project":"a","index":1,"total":2,"siblings":["2026-01-01-old-b-tasks.json"]}'
  _sd_write "$t/2026-01-01-old-b-tasks.json" "feat/old-b" "$(_sd_stories pending)" \
    '{"project":"b","index":2,"total":2,"siblings":["2026-01-01-old-a-tasks.json"]}'
  _sd_write "$t/2026-07-27-live-frontend-tasks.json" "feat/live-frontend" "$(_sd_stories pending)"
  _sd_write "$t/2026-07-27-live-backend-tasks.json" "feat/live-backend" "$(_sd_stories pending)"
  touch -t "$_SD_OLD_MTIME" "$t"/2026-01-01-old-*.json
  touch -t "$_SD_NEW_MTIME" "$t"/2026-07-27-live-*.json

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC40: exits 0"
  assert_eq "paired-split" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC40: the newest candidate decides, so the unmarked pair wins"
  assert_eq "2026-07-27-live-frontend-tasks.json,2026-07-27-live-backend-tasks.json" \
    "$(_sd_member_names "$out")" "TC40: the pair is the reported group"
  assert_eq "0" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("old-"))] | length')" \
    "TC40: the older marked group does not preempt today's plan"

  rm -rf "$d"
}

# TC41: a marker whose declared total disagrees with the resolved count degrades
# to single-file — and the degradation is TERMINAL. Falling through to the
# legacy pair would run stale work: this scope was planned by the project-split
# writer, so any -frontend-/-backend-tasks.json beside it predates the plan.
test_split_detect_total_mismatch_degrades_terminally() {
  echo ""
  echo "=== TC41: split-detect — total mismatch degrades and does not fall through to the legacy pair ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  # The anchor is itself named -frontend-tasks.json and a real -backend sibling
  # sits beside it, so a fall-through would visibly produce paired-split.
  _sd_write "$t/2026-07-27-x-frontend-tasks.json" "feat/x-fe" "$(_sd_stories pending)" \
    '{"project":"a","index":1,"total":3,"siblings":["2026-07-27-x-backend-tasks.json"]}'
  _sd_write "$t/2026-07-27-x-backend-tasks.json" "feat/x-be" "$(_sd_stories pending)"
  touch -t "$_SD_OLD_MTIME" "$t"/*.json
  touch -t "$_SD_NEW_MTIME" "$t/2026-07-27-x-frontend-tasks.json"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC41: a degraded group is still a query, not a gate — exits 0"
  assert_eq "single" "$(printf '%s' "$out" | jq -r '.mode')" "TC41: degrades to single"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.total')" "TC41: total collapses to 1"
  assert_eq "2026-07-27-x-frontend-tasks.json" "$(_sd_member_names "$out")" \
    "TC41: only the anchor is reported"
  local reason; reason=$(printf '%s' "$out" | jq -r '.degradedReason')
  assert_contains "declared total 3, resolved 2" "$reason" \
    "TC41: degradedReason carries both counts so the caller need not re-derive them"
  assert_contains "legacy pair not considered" "$reason" \
    "TC41: degradedReason says the legacy pair was deliberately skipped"

  rm -rf "$d"
}

# TC42: a traversal-shaped sibling entry is inert. Siblings resolve BY BASENAME
# against the anchor's own directory, so "../../etc/passwd" becomes
# "<anchor-dir>/passwd", which does not exist — and the group is voided rather
# than silently executed one member short.
test_split_detect_traversal_sibling_is_inert() {
  echo ""
  echo "=== TC42: split-detect — a traversal-shaped sibling resolves by basename and voids the group ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-y-tasks.json" "feat/y" "$(_sd_stories pending)" \
    '{"project":"a","index":1,"total":2,"siblings":["../../etc/passwd"]}'

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC42: exits 0"
  assert_eq "single" "$(printf '%s' "$out" | jq -r '.mode')" "TC42: the group is voided"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.members | length')" "TC42: only the anchor remains"
  local reason; reason=$(printf '%s' "$out" | jq -r '.degradedReason')
  assert_contains "$t/passwd" "$reason" \
    "TC42: the sibling was looked up by basename inside the anchor's own directory"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("/etc/passwd"))] | length')" \
    "TC42: nothing outside the anchor directory reaches the member list"

  rm -rf "$d"
}

# TC43: pending is (.status // "pending") != "completed" — ONE definition for
# every count reported. execute.md carried two that disagreed: the active
# filter used != "completed" while the phase completion count used
# == "pending", so an in_progress story was counted by one and not the other,
# letting a phase close with work still in flight.
test_split_detect_in_progress_counts_as_pending() {
  echo ""
  echo "=== TC43: split-detect — an in_progress story counts as pending ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-z-a-tasks.json" "feat/z-a" "$(_sd_stories in_progress)" \
    '{"project":"a","index":1,"total":2,"siblings":["2026-07-27-z-b-tasks.json"]}'
  _sd_write "$t/2026-07-27-z-b-tasks.json" "feat/z-b" "$(_sd_stories completed)" \
    '{"project":"b","index":2,"total":2,"siblings":["2026-07-27-z-a-tasks.json"]}'
  touch -t "$_SD_OLD_MTIME" "$t"/*.json
  touch -t "$_SD_NEW_MTIME" "$t/2026-07-27-z-a-tasks.json"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC43: exits 0"
  assert_eq "project-split" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC43: the group is not dropped — in_progress keeps it alive"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.activeCount')" \
    "TC43: exactly the in_progress member is active"
  assert_eq "1" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("z-a"))] | .[0].pendingCount')" \
    "TC43: the in_progress story is counted as pending"
  assert_eq "true" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("z-a"))] | .[0].active')" \
    "TC43: the in_progress member is active"
  assert_eq "false" \
    "$(printf '%s' "$out" | jq -r '[.members[] | select(.path | test("z-b"))] | .[0].active')" \
    "TC43: the completed member is not active"

  rm -rf "$d"
}

# TC44: files predating the project-split writer carry no marker, so the legacy
# -frontend-tasks.json/-backend-tasks.json pair rule is what groups them. They
# resolve to project "." — the flat flow's execution root.
test_split_detect_legacy_pair_without_marker() {
  echo ""
  echo "=== TC44: split-detect — an unmarked frontend/backend pair is a paired-split ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  git init -q "$d" >/dev/null 2>&1
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-04-10-live-preview-frontend-tasks.json" "feat/live-preview-frontend" \
    "$(_sd_stories pending pending)"
  _sd_write "$t/2026-04-10-live-preview-backend-tasks.json" "feat/live-preview-backend" \
    "$(_sd_stories pending)"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC44: exits 0"
  assert_eq "paired-split" "$(printf '%s' "$out" | jq -r '.mode')" "TC44: mode is paired-split"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.total')" "TC44: total is 2"
  assert_eq "2026-04-10-live-preview-frontend-tasks.json,2026-04-10-live-preview-backend-tasks.json" \
    "$(_sd_member_names "$out")" "TC44: frontend first, backend second"
  assert_eq ".,." "$(printf '%s' "$out" | jq -r '[.members[].project] | join(",")')" \
    "TC44: unmarked pair members resolve to the root project"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.degradedReason')" "TC44: nothing degraded"

  # A lone half of the pair is not a pair.
  rm -f "$t/2026-04-10-live-preview-backend-tasks.json"
  local solo; solo=$(_sd_run "$d")
  assert_eq "single" "$(printf '%s' "$solo" | jq -r '.mode')" \
    "TC44: a frontend file with no backend counterpart is not a pair"

  rm -rf "$d"
}

# TC45: one file, no marker — the single-file flow, named explicitly so the
# caller can pass it to init-session instead of re-running mtime auto-discovery.
test_split_detect_single_file() {
  echo ""
  echo "=== TC45: split-detect — a single unmarked file ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-solo-tasks.json" "feat/solo" "$(_sd_stories pending completed)"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC45: single is an outcome, not a failure — exits 0"
  assert_eq "single" "$(printf '%s' "$out" | jq -r '.mode')" "TC45: mode is single"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.total')" "TC45: total is 1"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC45: activeCount is 1"
  assert_contains "2026-07-27-solo-tasks.json" "$(printf '%s' "$out" | jq -r '.anchor')" \
    "TC45: the anchor names the file to execute"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.members[0].storyCount')" "TC45: storyCount is 2"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.members[0].pendingCount')" "TC45: pendingCount is 1"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.degradedReason')" "TC45: nothing degraded"

  rm -rf "$d"
}

# TC46: exit-code discipline. Every detection outcome is 0; non-zero is reserved
# for real errors. Also pins that a malformed candidate is inert rather than
# fatal — one corrupt file must not take detection down for every other feature.
test_split_detect_exit_codes_and_bad_input() {
  echo ""
  echo "=== TC46: split-detect — query exit codes, argument errors, malformed candidates ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  # Empty .aimi/tasks -> none, exit 0
  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC46: an empty tasks dir exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" "TC46: mode is none"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.anchor')" "TC46: anchor is null"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC46: activeCount is 0"

  # A fully completed group with nothing behind it -> none, with a reason
  _sd_write "$t/2026-07-27-done-a-tasks.json" "feat/done-a" "$(_sd_stories completed)" \
    '{"project":"a","index":1,"total":2,"siblings":["2026-07-27-done-b-tasks.json"]}'
  _sd_write "$t/2026-07-27-done-b-tasks.json" "feat/done-b" "$(_sd_stories completed)" \
    '{"project":"b","index":2,"total":2,"siblings":["2026-07-27-done-a-tasks.json"]}'
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC46: an exhausted pool exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" "TC46: exhausted pool reports none"
  assert_contains "fully completed" "$(printf '%s' "$out" | jq -r '.degradedReason')" \
    "TC46: degradedReason distinguishes 'exhausted' from 'nothing was ever here'"
  rm -f "$t"/2026-07-27-done-*.json

  # Malformed JSON beside a healthy file is inert, not fatal
  printf '{not json' > "$t/2026-07-27-broken-tasks.json"
  _sd_write "$t/2026-07-27-healthy-tasks.json" "feat/healthy" "$(_sd_stories pending)"
  touch -t "$_SD_OLD_MTIME" "$t/2026-07-27-broken-tasks.json"
  touch -t "$_SD_NEW_MTIME" "$t/2026-07-27-healthy-tasks.json"
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "TC46: a malformed candidate does not abort detection"
  assert_eq "single" "$(printf '%s' "$out" | jq -r '.mode')" "TC46: the healthy file still resolves"
  rm -f "$t"/2026-07-27-*.json

  # Argument errors are real errors
  ( cd "$d" && "$CLI" split-detect --dir >/dev/null 2>&1 ) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC46: --dir with no value exits 1"

  ( cd "$d" && "$CLI" split-detect --bogus >/dev/null 2>&1 ) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC46: an unknown argument exits 1"

  ( cd "$d" && "$CLI" split-detect --dir "$d/nope" >/dev/null 2>&1 ) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC46: --dir pointing at a nonexistent directory exits 1"

  local err
  err=$( cd "$d" && "$CLI" split-detect --dir /etc 2>&1 >/dev/null ) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "TC46: --dir escaping the project root exits 1"
  assert_contains "escapes project root" "$err" "TC46: --dir is path-confined by validate_path_in_project"

  rm -rf "$d"
}

# TC50: an unmarked frontend/backend pair resolves to project "." (the root
# routing key) -- fine when AIMI_ROOT is a git repository (TC44), but AIMI_ROOT
# here is a bare, non-git mktemp -d: a multi-repo layout with no repository
# underneath "." to execute in. split-detect must refuse the pair rather than
# binding to a parent folder with nothing to run, while staying a query: exit
# 0, mode "none", empty pool shape, and a degradedReason naming the condition
# and the --split full-stack re-plan instruction.
# Numbered TC50 (not TC47) to stay globally unique -- TC47-TC49 are already
# used by the story-merge project-axis tests earlier in this file.
test_split_detect_refuses_unrooted_pair_in_non_git_aimi_root() {
  echo ""
  echo "=== TC50: split-detect — an unmarked pair is refused when AIMI_ROOT is not a git repository ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-live-frontend-tasks.json" "feat/live-frontend" "$(_sd_stories pending)"
  _sd_write "$t/2026-07-27-live-backend-tasks.json" "feat/live-backend" "$(_sd_stories pending)"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC50: refusal is still a query, not a gate — exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" "TC50: mode degrades to none, not single"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.anchor')" "TC50: anchor is null"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.members | length')" "TC50: members is empty"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC50: activeCount is 0"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.total')" "TC50: total is 0"
  local reason; reason=$(printf '%s' "$out" | jq -r '.degradedReason')
  assert_contains "git repository" "$reason" \
    "TC50: degradedReason names the non-git AIMI_ROOT condition"
  assert_contains "--split full-stack" "$reason" \
    "TC50: degradedReason instructs the reader to re-plan with --split full-stack"

  rm -rf "$d"
}

# TC51: the refusal in TC50 is scoped to the unmarked/legacy resolution branch
# only. A group carrying a real metadata.splitGroup marker must resolve
# UNCHANGED to project-split, with its declared per-member project values
# intact and degradedReason null, regardless of AIMI_ROOT's git status.
test_split_detect_marked_group_unaffected_by_non_git_aimi_root() {
  echo ""
  echo "=== TC51: split-detect — a marked project-split group is unaffected by a non-git AIMI_ROOT ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks"
  local t="$d/.aimi/tasks"

  _sd_write "$t/2026-07-27-app-frontend-repo-tasks.json" "feat/app-frontend-repo" \
    "$(_sd_stories pending)" \
    '{"project":"frontend-repo","index":1,"total":2,"siblings":["2026-07-27-app-backend-repo-tasks.json"]}'
  _sd_write "$t/2026-07-27-app-backend-repo-tasks.json" "feat/app-backend-repo" \
    "$(_sd_stories pending)" \
    '{"project":"backend-repo","index":2,"total":2,"siblings":["2026-07-27-app-frontend-repo-tasks.json"]}'
  touch -t "$_SD_OLD_MTIME" "$t"/*.json
  touch -t "$_SD_NEW_MTIME" "$t/2026-07-27-app-frontend-repo-tasks.json"

  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC51: exits 0"
  assert_eq "project-split" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC51: a marked group still resolves to project-split under a non-git AIMI_ROOT"
  assert_eq "frontend-repo,backend-repo" \
    "$(printf '%s' "$out" | jq -r '[.members[].project] | join(",")')" \
    "TC51: per-member project values are preserved"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.degradedReason')" "TC51: nothing degraded"

  rm -rf "$d"
}

# TC52: the AIMI_ROOT-is-a-git-repository check reads the process's own
# working directory, not the --dir scope -- --dir only narrows the candidate
# pool (aimi-cli.sh's _split_detect_list_dir/_split_detect_phase_main_file).
# The same refusal from TC50 must fire identically when queried through --dir
# against a phase directory holding the same unmarked pair.
test_split_detect_dir_scope_refusal_matches_flat_scope() {
  echo ""
  echo "=== TC52: split-detect --dir — the non-git AIMI_ROOT refusal matches flat scope ==="

  local d; d=$(mktemp -d); mkdir -p "$d/.aimi/tasks/myfeat/phase-2-auth"
  local p="$d/.aimi/tasks/myfeat/phase-2-auth"

  _sd_write "$p/myfeat-phase-2-frontend-tasks.json" "feat/myfeat-phase-2-frontend" \
    "$(_sd_stories pending)"
  _sd_write "$p/myfeat-phase-2-backend-tasks.json" "feat/myfeat-phase-2-backend" \
    "$(_sd_stories pending)"

  local out exit_code
  out=$(_sd_run "$d" --dir "$p") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC52: --dir query exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" \
    "TC52: --dir scope reports the identical refused mode"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.members | length')" "TC52: members is empty"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC52: activeCount is 0"
  local reason; reason=$(printf '%s' "$out" | jq -r '.degradedReason')
  assert_contains "git repository" "$reason" "TC52: degradedReason names the condition under --dir too"
  assert_contains "--split full-stack" "$reason" "TC52: degradedReason instructs re-plan under --dir too"

  rm -rf "$d"
}

# TC53: the split-detect half of the xargs empty-input defect
# (_find_tasks_files_all / _split_detect_list_dir, aimi-cli.sh). TC46's own
# empty-tasks-dir case above never plants a decoy, so it never actually
# exercises xargs running `ls -t` with no arguments -- `ls -t` with no
# arguments lists PROJECT_ROOT (find_aimi_root has already cd'd there), so
# the decoy that matters is a visible top-level file in the project root,
# regardless of which subdirectory a --dir query targets.
#
# Flat scope filters its candidate pool to direct children of TASKS_DIR
# before ever printing an answer (cmd_split_detect's dirname check), so a
# project-root decoy is excluded on its own merit -- flat scope already
# answers none/empty today, before the fix. This case pins that answer
# rather than discriminating on it, the same accidental-correctness shape as
# list-archivable's decoy case above.
#
# --dir scope has no such filter: _split_detect_list_dir hands its raw
# answer straight into the candidate pool, and today that "raw answer" is
# whatever `ls -t` finds in PROJECT_ROOT -- not the --dir target directory --
# because xargs ran it with zero arguments. Placing the decoy INSIDE the
# --dir target directory does NOT reproduce the defect (ls -t never looks
# there); it must sit in the project root, same as the flat case. That is
# the case that actually goes red before the fix (mode "single", a bogus
# DECOY.md member) and green after (mode "none") -- proving the --dir code
# path is fixed independently of the flat one.
test_split_detect_empty_dir_with_decoy() {
  echo ""
  echo "=== TC53: split-detect — empty tasks dir with a project-root decoy ==="

  local d; d=$(mktemp -d)
  mkdir -p "$d/.aimi/tasks/myfeat/phase-2-auth"
  echo "not a tasks file" > "$d/DECOY.md"

  # --- flat scope ---
  local out exit_code
  out=$(_sd_run "$d") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC53: flat scope, empty dir with decoy exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" "TC53: flat scope mode is none"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.anchor')" "TC53: flat scope anchor is null"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.members | length')" "TC53: flat scope members is empty"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC53: flat scope activeCount is 0"
  if [[ "$out" == *"DECOY.md"* ]]; then
    echo -e "${RED}✗${NC} TC53: flat scope — the decoy never appears as a candidate"
    echo "  Actual: $out"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC53: flat scope — the decoy never appears as a candidate"
    ((TESTS_PASSED++))
  fi

  # --- --dir scope, targeting an otherwise-empty phase directory ---
  out=$(_sd_run "$d" --dir "$d/.aimi/tasks/myfeat/phase-2-auth") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "TC53: --dir scope, empty phase dir with decoy exits 0"
  assert_eq "none" "$(printf '%s' "$out" | jq -r '.mode')" "TC53: --dir scope mode is none"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.anchor')" "TC53: --dir scope anchor is null"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.members | length')" "TC53: --dir scope members is empty"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.activeCount')" "TC53: --dir scope activeCount is 0"
  if [[ "$out" == *"DECOY.md"* ]]; then
    echo -e "${RED}✗${NC} TC53: --dir scope — the decoy never appears as a candidate"
    echo "  Actual: $out"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} TC53: --dir scope — the decoy never appears as a candidate"
    ((TESTS_PASSED++))
  fi

  rm -rf "$d"
}

# ============================================================================
# Main
# ============================================================================

main() {
  if [ -z "${AIMI_TEST_PART_RESULT_FILE:-}" ]; then
    echo "================================================"
    echo "  Aimi CLI Test Suite - part2-planning"
    echo "================================================"
  fi

  # Ensure cleanup on exit/abort
  trap 'rm -rf "$TEST_DIR"' EXIT

  # Run inside isolated temp directory so find_aimi_root() discovers
  # the test .aimi/ instead of the real project .aimi/
  cd "$TEST_DIR"

  setup

  # The single-file suite reached this point with a session already
  # initialised by the General/Lifecycle sections that now live in part 1.
  # Each part gets its own TEST_DIR, so re-establish that precondition.
  "$CLI" init-session > /dev/null

  # Detect-default-branch tests — uses own git fixture (independent of TEST_DIR)
  echo ""
  echo "--- Detect Default Branch Tests ---"
  test_detect_default_branch
  test_detect_default_branch_per_repo_scoping
  test_detect_default_branch_classic_single_repo_regression
  test_clear_state_removes_per_repo_default_branch_cache

  # Detect-parent-branch tests — uses own git fixture (independent of TEST_DIR)
  echo ""
  echo "--- Detect Parent Branch Tests ---"
  test_detect_parent_branch
  test_detect_parent_branch_per_repo_scoping

  # Archive-task tests — each creates its own isolated temp dir
  echo ""
  echo "--- Archive Task Tests ---"
  test_archive_task_collision_suffix
  test_archive_task_survivors
  test_archive_task_with_research_paths
  test_archive_task_without_research_paths
  test_archive_task_missing_research_files
  test_archive_task_with_prototype_paths
  test_archive_task_without_prototype_paths
  test_archive_task_missing_prototype_files
  test_archive_task_both_research_and_prototype_paths

  # Research-lookup tests — each creates its own isolated temp dir
  echo ""
  echo "--- Research Lookup Tests ---"
  test_research_lookup

  # Extract-sections tests — each creates its own isolated temp dir
  echo ""
  echo "--- Extract Sections Tests ---"
  test_extract_sections

  # Research-gc tests — each creates its own isolated temp dir
  echo ""
  echo "--- Research GC Tests ---"
  test_archivable_predicate_and_research_walk_crossed
  test_list_archivable_empty_dir_with_decoy
  test_research_gc

  # Interactivity mode detection tests
  echo ""
  echo "--- Interactivity Mode Detection Tests ---"
  test_detect_interactivity_agent_mode_env
  test_detect_interactivity_agent_mode_overrides_host
  test_detect_interactivity_ci_env
  test_detect_interactivity_non_tty
  test_detect_interactivity_claudecode_host
  test_detect_interactivity_opencode_host
  test_detect_interactivity_non_interactive_flag
  test_detect_interactivity_opencode_shell_sim

  # resolve-models tests
  echo ""
  echo "--- resolve-models Tests ---"
  test_resolve_models_no_config
  test_resolve_models_malformed_config
  test_resolve_models_partial_config
  test_resolve_models_host_detection_claudecode
  test_resolve_models_host_detection_opencode
  test_resolve_models_invalid_model_claudecode
  test_resolve_models_all_keys_always_present
  test_resolve_models_stdout_always_valid_json
  test_resolve_models_exact_match_validation
  test_resolve_models_exact_aliases_accepted
  test_resolve_models_v1_rejected
  test_resolve_models_opencode_mtime_cache

  # get-current-models tests
  echo ""
  echo "--- get-current-models Tests ---"
  test_get_current_models_no_config
  test_get_current_models_v2_full_config_claudecode
  test_get_current_models_host_branch_opencode
  test_get_current_models_partial_config_emits_null_for_unset
  test_get_current_models_v1_config_rejected

  # list-models tests
  echo ""
  echo "--- list-models Tests ---"
  test_list_models_claudecode_returns_three_aliases
  test_list_models_claudecode_matches_the_host_valid_set
  test_list_models_opencode_absent_fallback

  # detect-models tests
  echo ""
  echo "--- detect-models Tests ---"
  test_write_aimi_models_config
  test_detect_models_claudecode_generates_config
  test_detect_models_opencode_absent_fallback
  test_detect_models_atomic_write_no_corruption
  test_detect_models_roundtrip_with_resolve_models
  test_detect_models_tier_flags_claudecode
  test_detect_models_tier_flags_preserve_other_host
  test_detect_models_preserves_other_host
  test_detect_models_default_mode_preserves_other_host
  test_detect_models_flag_mode_rejections
  test_detect_models_flag_mode_normalizes_and_warns

  # model-validity predicate comparison
  echo ""
  echo "--- Model-Validity Predicate Tests ---"
  test_model_validity_predicate_matrix
  test_prompt_category_predicate_edges
  test_list_models_offers_ids_resolve_models_rejects
  test_list_models_and_resolve_models_agree_on_every_offered_id
  test_resolve_models_invalid_tag_hostile_ids

  # models-prompt-check / models-prompt-dismiss tests
  echo ""
  echo "--- models-prompt-check / models-prompt-dismiss Tests ---"
  test_models_prompt_check_returns_prompt
  test_models_prompt_check_skip_when_current_host_configured
  test_models_prompt_check_prompt_when_other_host_only_configured
  test_models_prompt_check_prompt_when_current_host_all_null
  test_models_prompt_check_prompt_when_v1_config
  test_models_prompt_check_prompt_when_file_missing_even_with_per_host_marker
  test_models_prompt_check_skip_when_per_host_marker_dismisses
  test_models_prompt_check_per_host_marker_isolation
  test_models_prompt_check_legacy_global_marker_ignored
  test_models_prompt_check_skip_when_current_host_configured_with_marker
  test_models_prompt_check_prompt_when_categories_empty_object
  test_models_prompt_dismiss_creates_per_host_marker_claudecode
  test_models_prompt_dismiss_creates_per_host_marker_opencode
  test_models_prompt_dismiss_then_check_skips_when_file_present
  test_models_prompt_dismiss_idempotent

  # story-merge tests — each creates its own isolated staging/output dirs
  echo ""
  echo "--- story-merge Tests ---"
  test_story_merge_happy_path
  test_story_merge_missing_dir
  test_story_merge_malformed_json
  test_story_merge_duplicate_index
  test_story_merge_cycle
  test_story_merge_dangling_ref
  test_story_merge_rule22_routing
  test_story_merge_full_stack_split
  test_story_merge_phase_aware_split
  test_story_merge_outline_sidecar_ignored
  test_story_merge_dead_code_positive
  test_story_merge_dead_code_negative
  test_story_merge_foundation_injection
  test_story_merge_foundation_omitted_noop
  test_story_merge_foundation_dedup
  test_story_merge_foundation_invalid_idx
  test_story_merge_foundation_nonempty_dependson
  test_story_merge_project_axis_partition
  test_story_merge_project_monorepo_guard
  test_story_merge_nway_partition_invariant
  test_story_merge_project_preserved_working_keys_stripped
  test_story_merge_project_trailing_slash_normalization
  test_story_merge_cross_file_dep_dropped_banner
  test_story_merge_cross_file_false_root_vs_partial_loss
  test_story_merge_cross_file_dep_dropped_negative
  test_story_merge_cross_file_dep_dropped_title_sanitized
  test_story_merge_split_empty_side_warning
  test_story_merge_project_split_three_projects
  test_story_merge_project_split_untagged_story_refused
  test_story_merge_project_split_explicit_root_group
  test_story_merge_project_split_singleton_group
  test_story_merge_project_split_slash_project_slug
  test_story_merge_project_split_dot_project_slug
  test_story_merge_project_split_basename_collision
  test_story_merge_project_split_project_keyed_warnings
  test_story_merge_project_split_foundation_edge
  test_story_merge_project_split_phase_aware
  test_story_merge_project_split_partial_write_failure

  # split-detect tests (TC36-TC46, TC50-TC53) — each builds its own isolated
  # project dir. TC47-TC49 are used by the story-merge project-axis tests
  # above, not by split-detect.
  echo ""
  echo "--- split-detect Tests (TC36-TC46, TC50-TC53) ---"
  test_split_detect_project_split_three_members
  test_split_detect_flat_scope_excludes_phase_dir
  test_split_detect_dir_scope_matches_phase_split
  test_split_detect_completed_stale_group_yields_to_fresh_pair
  test_split_detect_newest_wins_over_older_marked_group
  test_split_detect_total_mismatch_degrades_terminally
  test_split_detect_traversal_sibling_is_inert
  test_split_detect_in_progress_counts_as_pending
  test_split_detect_legacy_pair_without_marker
  test_split_detect_single_file
  test_split_detect_exit_codes_and_bad_input
  test_split_detect_refuses_unrooted_pair_in_non_git_aimi_root
  test_split_detect_marked_group_unaffected_by_non_git_aimi_root
  test_split_detect_dir_scope_refusal_matches_flat_scope
  test_split_detect_empty_dir_with_decoy

  cleanup

  if [ -n "${AIMI_TEST_PART_RESULT_FILE:-}" ]; then
    printf '%s %s\n' "$TESTS_PASSED" "$TESTS_FAILED" > "$AIMI_TEST_PART_RESULT_FILE"
  else
    echo ""
    echo "================================================"
    echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "================================================"
  fi

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
