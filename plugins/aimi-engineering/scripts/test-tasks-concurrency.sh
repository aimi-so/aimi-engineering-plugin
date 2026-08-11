#!/usr/bin/env bash
set -uo pipefail

# test-tasks-concurrency.sh - what the tasks.json verbs do when two of them
# run at once.
#
# SERIAL ONLY, AND DELIBERATELY NOT IN test-aimi-cli.sh's PARTS ARRAY. Every
# assertion in here depends on a timing window, and two of the three windows
# only exist because a jq program is slow. Four concurrent parts contending
# for the same cores compress that window by an amount nobody can predict,
# which is precisely how a deterministic test becomes a flaky one. The
# standing precedent is test-worktree-manager.sh: also not parallel-safe (its
# five `serve` assertions collide on a fixed port), also deliberately left out
# of the dispatcher, also documented in the root CLAUDE.md as its own entry
# point. This suite follows that shape exactly — own SCRIPT_DIR, own counters,
# own fixtures under `mktemp -d`, its own passed/failed totals on exit, and a
# non-zero status if anything failed.
#
# The cost of staying out is that these assertions do not roll into the
# dispatcher's EXPECTED_ASSERTIONS invariant. That is paid for by printing the
# totals below and by the root CLAUDE.md naming this file beside the other
# suites, so no reviewer has to discover it.
#
# WHY THE WINDOW IS WIDE ENOUGH TO BE DETERMINISTIC. cmd_cascade_skip computes
# its transitive skip set in an UNLOCKED jq whose body is a
# `reduce range(length)` closure — quadratic in the story count before the
# per-iteration `unique` is counted. Measured here (16 cores, jq-1.6) against
# the fan-shaped fixture this suite builds:
#
#     stories   unlocked closure
#          50   ~37ms
#         200   ~337ms
#         400   ~2826ms
#
# (Planning measured ~185ms / ~1129ms / ~3739ms on a different host. Same
# shape, same order of magnitude; the ratio is what matters, not the absolute.)
# A linear dependency CHAIN is far slower still — ~32s at 400 stories, because
# every story's dependency sits in the middle of the sorted skip list instead
# of at its head — which is why the fixture fans out from one root rather than
# chaining. It buys a window measured in seconds while keeping this suite's
# whole runtime in the same seconds.
#
# So the cascade-skip test sleeps 0.10s into a ~2.8s window: a ~28x margin,
# and the test asserts the margin held rather than assuming it. Five
# consecutive runs are the acceptance bar, not one.
#
# DETERMINISM AS MEASURED, NOT AS CLAIMED. A test that passes once and flakes
# later is worse than no test at all here, because the whole point of this
# file is that its cascade-skip assertions INVERT when the defect is fixed —
# an inversion nobody can read as proof if the suite is noisy. On first
# authoring it was run twelve consecutive times on a 16-core host, jq-1.6,
# against the unmodified jq cmd_cascade_skip with no Python implementation of
# any tasks.json verb in the tree. Every run: 18 passed, 0 failed, exit 0. No
# sleep window and no fixture size needed raising. Whole-suite wall clock
# ~11s, nearly all of it the 400-story closure the cascade test races against.
# If a future run disagrees, raise the fixture size (which widens the window
# quadratically) rather than the sleep, and re-record the count here.
#
# THE OTHER TWO TESTS NEED NO SLEEP AT ALL. gate-pass, gate-fail and
# reset-orphaned read their precondition outside the lock and then write
# inside it, so the interleaving that matters is "another writer holds the
# lock while this verb waits for it" — a schedule this suite can produce
# exactly rather than approximately. It takes the flock itself, waits for the
# verb under test to create its `mktemp` sibling (which happens after the
# unlocked read and before the lock, so its existence PROVES the unlocked read
# has already happened), mutates the file, and only then releases. No sleep,
# no guessing.
#
# PORTABILITY: no `mapfile`, no `readarray`, no associative arrays, no
# indexing into an array by number — same rules the dispatcher header states,
# for the same reason.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLI="$SCRIPT_DIR/aimi-cli.sh"

# Sourced, not copied: the assert_* family, the counters and the colours all
# live in the shared preamble already. It also points AIMI_CONFIG_DIR at a
# private directory, which keeps this suite off the developer's real
# ~/.config/aimi. setup()/cleanup() are NOT called — every test here builds
# its own fixture.
# shellcheck source=./test-aimi-cli-common.sh
. "$SCRIPT_DIR/test-aimi-cli-common.sh"

# ============================================================================
# Fixture Helpers
# ============================================================================

# Each test gets its own directory holding its own .aimi/tasks/, so
# find_aimi_root() discovers that fixture and nothing else. Echoes the tasks
# file path.
#
# The fan shape — every story but the root depending directly on the root —
# is what makes cascade-skip's unlocked closure expensive enough to race
# against. See the header for the measurements and for why a chain is the
# wrong shape here.
build_fan_fixture() {
  local dir="$1"
  local count="$2"
  local tasks_file="$dir/.aimi/tasks/9999-99-99-race-tasks.json"

  mkdir -p "$dir/.aimi/tasks"

  {
    printf '{\n'
    printf '  "schemaVersion": "3.2",\n'
    printf '  "metadata": {"title": "ref: concurrency fixture", "type": "ref", "branchName": "ref/concurrency", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 4},\n'
    printf '  "userStories": [\n'
    local i=1 id deps sep
    while [ "$i" -le "$count" ]; do
      id=$(printf 'US-%03d' "$i")
      if [ "$i" -eq 1 ]; then deps='[]'; else deps='["US-001"]'; fi
      sep=','
      [ "$i" -eq "$count" ] && sep=''
      printf '    {"id": "%s", "title": "Story %s", "description": "d", "acceptanceCriteria": ["Passes"], "priority": %s, "status": "pending", "dependsOn": %s, "notes": ""}%s\n' \
        "$id" "$id" "$i" "$deps" "$sep"
      i=$((i + 1))
    done
    printf '  ]\n'
    printf '}\n'
  } > "$tasks_file"

  printf '%s\n' "$tasks_file"
}

# Writes an arbitrary small tasks.json into its own fixture directory and
# echoes the path. The body arrives on stdin.
build_small_fixture() {
  local dir="$1"
  local tasks_file="$dir/.aimi/tasks/9999-99-99-race-tasks.json"
  mkdir -p "$dir/.aimi/tasks"
  cat > "$tasks_file"
  printf '%s\n' "$tasks_file"
}

# True once a `mktemp "${tasks_file}.XXXXXX"` sibling exists.
#
# This is the whole reason the lock-holding tests need no sleep. Every verb
# here does its unlocked read FIRST, then mktemp, then blocks on the lock — so
# the sibling appearing is a happens-after proof that the unlocked read is
# already done. Globbed by `find` rather than by the shell so no shell's
# no-match behaviour (bash's literal-pattern, zsh's hard error) can leak in.
# The six-character suffix cannot collide with "${tasks_file}.lock" (four) or
# with this suite's own "${tasks_file}.holdertmp" (nine).
tmp_sibling_exists() {
  local tasks_file="$1"
  find "$(dirname "$tasks_file")" -maxdepth 1 -name "$(basename "$tasks_file").??????" -print 2>/dev/null | grep -q .
}

# Bounded poll. Returns 0 when the predicate held, 1 on timeout — a timeout is
# never silently tolerated; the caller asserts on it.
wait_for() {
  local attempts=0
  while [ "$attempts" -lt 500 ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

file_exists() { [ -e "$1" ]; }

# ============================================================================
# cascade-skip: the lost-completion race
# ============================================================================

# KNOWN DEFECT — ASSERTED GREEN AGAINST TODAY'S jq. THE ASSERTIONS BELOW
# INVERT IN outline:06, AND THAT INVERSION IS THE REVIEWABLE PROOF THAT THE
# BEHAVIOUR CHANGED.
#
# The defect, precisely:
#
#   cmd_cascade_skip computes its skip set in an UNLOCKED jq call, and that
#   call is the ONLY place `status != "completed"` is ever tested. The locked
#   apply that follows asks a different and weaker question — its inner filter
#   is `if (.id as $sid | $to_skip | any(. == $sid)) then` — membership in a
#   list of ids computed some seconds ago, with no re-read of status at all.
#
#   So a story that COMPLETES during that window is overwritten with
#   `status: "skipped"` and a note claiming it depends on a failed story. The
#   completion is lost, and the note that replaces it is false: the story did
#   not fail and was not skipped, it finished.
#
# This is data loss, and it is the reason this suite exists. It is NOT the same
# class of bug as the reset-orphaned divergence at the bottom of this file —
# see the comment there.
#
# Every port slice between here and outline:06 claims "delta zero". An
# accidental fix in any of them turns THIS test red, which is exactly what it
# is for.
test_cascade_skip_loses_a_concurrent_completion() {
  echo ""
  echo "=== cascade-skip: a completion inside the unlocked window is lost (KNOWN DEFECT) ==="

  local dir="$TEST_DIR/cascade-race"
  local tasks_file
  tasks_file=$(build_fan_fixture "$dir" 400)

  cd "$dir" || return

  local cs_out="$dir/cascade.out"
  local cs_rc=0

  # US-001 is the fan root; every other story depends on it, so the skip set
  # is US-002..US-400 and the closure has 400 iterations of work to do first.
  "$CLI" cascade-skip US-001 > "$cs_out" 2>&1 &
  local cs_pid=$!

  sleep 0.10
  "$CLI" mark-complete US-200 > /dev/null 2>&1

  # The premise, asserted rather than assumed. If the window ever closes early
  # enough that mark-complete lands after the apply, THIS assertion fails
  # loudly instead of the test quietly proving nothing.
  local mid_status
  mid_status=$(jq -r '.userStories[] | select(.id == "US-200") | .status' "$tasks_file")
  assert_eq "completed" "$mid_status" \
    "cascade-skip race: mark-complete landed inside the unlocked window"

  wait "$cs_pid" || cs_rc=$?
  assert_exit_code "0" "$cs_rc" "cascade-skip race: cascade-skip exits 0"

  local final_status final_notes
  final_status=$(jq -r '.userStories[] | select(.id == "US-200") | .status' "$tasks_file")
  final_notes=$(jq -r '.userStories[] | select(.id == "US-200") | .notes' "$tasks_file")

  # INVERTS IN outline:06 — expected becomes "completed".
  assert_eq "skipped" "$final_status" \
    "cascade-skip race: KNOWN DEFECT — the completed story is overwritten with skipped"
  # INVERTS IN outline:06 — expected becomes the empty note the story carried.
  assert_eq "Skipped: depends on failed story US-001" "$final_notes" \
    "cascade-skip race: KNOWN DEFECT — and given a note saying it depended on a failure"

  # The printed report agrees with the file, so a caller reading stdout gets
  # no hint that anything was lost.
  local reported
  reported=$(jq -r '[.skipped[] | select(. == "US-200")] | length' "$cs_out")
  assert_eq "1" "$reported" \
    "cascade-skip race: KNOWN DEFECT — the report claims US-200 among the skipped"
}

# The control. Same verb, same fixture shape, no concurrent writer: a story
# already completed BEFORE cascade-skip starts is correctly left alone,
# because the unlocked closure CAN see its status. That is what isolates the
# defect above to the window rather than to the rule.
test_cascade_skip_respects_a_completion_it_can_see() {
  echo ""
  echo "=== cascade-skip: a completion visible to the closure is respected ==="

  local dir="$TEST_DIR/cascade-control"
  local tasks_file
  tasks_file=$(build_fan_fixture "$dir" 50)

  cd "$dir" || return

  "$CLI" mark-complete US-020 > /dev/null 2>&1

  local out rc=0
  out=$("$CLI" cascade-skip US-001 2>&1) || rc=$?
  assert_exit_code "0" "$rc" "cascade-skip control: exits 0"

  local status
  status=$(jq -r '.userStories[] | select(.id == "US-020") | .status' "$tasks_file")
  assert_eq "completed" "$status" \
    "cascade-skip control: the pre-completed story keeps its status on disk"

  local reported
  reported=$(printf '%s' "$out" | jq -r '[.skipped[] | select(. == "US-020")] | length')
  assert_eq "0" "$reported" \
    "cascade-skip control: the pre-completed story is absent from the skip list"
}

# ============================================================================
# gate-pass / gate-fail: the precondition read outside the lock
# ============================================================================

# Runs `$CLI <verb> <args...>` against a fixture while this suite holds the
# tasks.json lock, and applies `$mutation` (a jq program) to the file in the
# window between the verb's unlocked precondition read and its locked write.
#
# The interleaving is produced exactly, not approximated — see tmp_sibling_exists.
run_against_a_held_lock() {
  local tasks_file="$1"
  local mutation="$2"
  shift 2

  local ready="$tasks_file.ready"
  local marked="$tasks_file.marked"
  rm -f "$ready" "$marked"

  (
    flock -x 9
    : > "$ready"
    if wait_for tmp_sibling_exists "$tasks_file"; then
      : > "$marked"
    fi
    jq "$mutation" "$tasks_file" > "$tasks_file.holdertmp" && mv "$tasks_file.holdertmp" "$tasks_file"
  ) 9>"$tasks_file.lock" &
  local holder=$!

  # Do not launch the verb until the lock is genuinely held, or it would sail
  # straight through and test nothing.
  wait_for file_exists "$ready"

  local rc=0
  "$CLI" "$@" > "$tasks_file.verbout" 2>&1 &
  local verb=$!

  wait "$holder"
  wait "$verb" || rc=$?

  HELD_LOCK_RC="$rc"
  HELD_LOCK_MARKED=0
  [ -e "$marked" ] && HELD_LOCK_MARKED=1
  HELD_LOCK_OUT="$tasks_file.verbout"
}

# KNOWN DEFECT — cmd_gate_pass reads "does this story have a gate?" in an
# unlocked jq, then takes the lock and writes. Between those two crossings the
# answer can change, and nothing re-asks it. The write is
# `(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed"}`,
# and in jq `null + {status: "passed"}` is `{status: "passed"}` — so the verb
# does not fail, it CREATES a gate on a story that no longer has one.
#
# Ranked with cascade-skip, not with reset-orphaned: the file is wrong
# afterwards. It is narrower only because the window is a lock wait rather
# than seconds of computation.
#
# INVERTS IN outline:06.
test_gate_pass_writes_a_gate_that_was_removed_under_it() {
  echo ""
  echo "=== gate-pass: precondition read outside the lock (KNOWN DEFECT) ==="

  local dir="$TEST_DIR/gate-pass-race"
  local tasks_file
  tasks_file=$(build_small_fixture "$dir" <<'EOF'
{
  "schemaVersion": "3.2",
  "metadata": {"title": "ref: gate race", "type": "ref", "branchName": "ref/gate-race", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 2},
  "userStories": [
    {"id": "US-001", "title": "Gated story", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 1, "status": "pending", "dependsOn": [], "notes": "",
     "gate": {"type": "decision", "status": "pending", "prompt": "Pick one", "options": ["A", "B"]}}
  ]
}
EOF
  )

  cd "$dir" || return

  run_against_a_held_lock "$tasks_file" \
    'del(.userStories[] | select(.id == "US-001") | .gate)' \
    gate-pass US-001

  assert_eq "1" "$HELD_LOCK_MARKED" \
    "gate-pass race: the verb reached its locked write with the gate already gone"
  assert_exit_code "0" "$HELD_LOCK_RC" \
    "gate-pass race: exits 0 — the no-gate guard already ran and cannot run again"

  local on_disk
  on_disk=$(jq -c '.userStories[] | select(.id == "US-001") | .gate' "$tasks_file")
  # INVERTS IN outline:06 — expected becomes null, and the verb is expected to
  # refuse with the "has no gate defined" error the guard already knows how to
  # produce.
  assert_eq '{"status":"passed"}' "$on_disk" \
    "gate-pass race: KNOWN DEFECT — a gate is created on a story that has none"

  local echoed
  echoed=$(jq -c '.gate' "$HELD_LOCK_OUT")
  assert_eq '{"status":"passed"}' "$echoed" \
    "gate-pass race: KNOWN DEFECT — and the echo-back reports it as a real gate"
}

# The same crossing in cmd_gate_fail, which carries a byte-identical guard.
# INVERTS IN outline:06.
test_gate_fail_writes_a_gate_that_was_removed_under_it() {
  echo ""
  echo "=== gate-fail: precondition read outside the lock (KNOWN DEFECT) ==="

  local dir="$TEST_DIR/gate-fail-race"
  local tasks_file
  tasks_file=$(build_small_fixture "$dir" <<'EOF'
{
  "schemaVersion": "3.2",
  "metadata": {"title": "ref: gate race", "type": "ref", "branchName": "ref/gate-race", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 2},
  "userStories": [
    {"id": "US-001", "title": "Gated story", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 1, "status": "pending", "dependsOn": [], "notes": "",
     "gate": {"type": "decision", "status": "pending", "prompt": "Pick one", "options": ["A", "B"]}}
  ]
}
EOF
  )

  cd "$dir" || return

  run_against_a_held_lock "$tasks_file" \
    'del(.userStories[] | select(.id == "US-001") | .gate)' \
    gate-fail US-001

  assert_exit_code "0" "$HELD_LOCK_RC" \
    "gate-fail race: exits 0 — the no-gate guard already ran and cannot run again"

  local on_disk
  on_disk=$(jq -c '.userStories[] | select(.id == "US-001") | .gate' "$tasks_file")
  # INVERTS IN outline:06 — expected becomes null.
  assert_eq '{"status":"failed"}' "$on_disk" \
    "gate-fail race: KNOWN DEFECT — a gate is created on a story that has none"
}

# ============================================================================
# reset-orphaned: report-only staleness
# ============================================================================

# COSMETIC. NOT DATA LOSS. DO NOT RANK THIS WITH cascade-skip.
#
# cmd_reset_orphaned reads the orphan list in an unlocked jq, exactly like
# cascade-skip reads its skip set. The difference is what the locked write
# does with it: cascade-skip's apply filters by id alone, but reset-orphaned's
# apply re-selects `status == "in_progress"` and ignores the precomputed list
# entirely. So the FILE IS ALREADY CORRECT — a story that stopped being
# in_progress during the window is not touched.
#
# What can be wrong is the printed `{count, reset}` report, which is built
# from the stale unlocked read. A caller that trusts stdout over the file will
# believe it reset a story it did not reset. That is a report bug, and pricing
# it as data loss would over-price the fix.
#
# This test therefore asserts BOTH halves: the report is stale AND the file is
# right. outline:06 changes only the first half.
test_reset_orphaned_report_can_be_stale_but_the_file_is_not() {
  echo ""
  echo "=== reset-orphaned: stale report, correct file (cosmetic) ==="

  local dir="$TEST_DIR/reset-orphaned-race"
  local tasks_file
  tasks_file=$(build_small_fixture "$dir" <<'EOF'
{
  "schemaVersion": "3.2",
  "metadata": {"title": "ref: orphan race", "type": "ref", "branchName": "ref/orphan-race", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 2},
  "userStories": [
    {"id": "US-001", "title": "Orphan A", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 1, "status": "in_progress", "dependsOn": [], "notes": ""},
    {"id": "US-002", "title": "Orphan B", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 2, "status": "in_progress", "dependsOn": [], "notes": ""}
  ]
}
EOF
  )

  cd "$dir" || return

  # US-002 finishes while reset-orphaned waits for the lock.
  run_against_a_held_lock "$tasks_file" \
    '(.userStories[] | select(.id == "US-002")) |= . + {status: "completed"}' \
    reset-orphaned

  assert_exit_code "0" "$HELD_LOCK_RC" "reset-orphaned race: exits 0"

  # Half one: the report is stale.
  local reported
  reported=$(jq -c '{count, reset}' "$HELD_LOCK_OUT")
  # INVERTS IN outline:06 — expected becomes {"count":1,"reset":["US-001"]}.
  assert_eq '{"count":2,"reset":["US-001","US-002"]}' "$reported" \
    "reset-orphaned race: KNOWN DEFECT (cosmetic) — the report still names US-002"

  # Half two: the file is not. These two assertions do NOT invert — they are
  # what makes this cosmetic, and they must keep holding after outline:06.
  local us1 us2
  us1=$(jq -r '.userStories[] | select(.id == "US-001") | .status' "$tasks_file")
  us2=$(jq -r '.userStories[] | select(.id == "US-002") | .status' "$tasks_file")
  assert_eq "failed" "$us1" "reset-orphaned race: the genuinely orphaned story is reset on disk"
  assert_eq "completed" "$us2" \
    "reset-orphaned race: the story that completed under the lock is NOT clobbered on disk"
}

# ============================================================================
# Main
# ============================================================================

main() {
  echo "================================================"
  echo "  tasks.json Concurrency Test Suite"
  echo "================================================"
  echo ""
  echo "  Serial only. Not run by test-aimi-cli.sh — see this file's header."

  trap 'rm -rf "$TEST_DIR"' EXIT

  if ! command -v flock > /dev/null 2>&1; then
    echo ""
    echo "  flock(1) not found — the lock-holding tests cannot produce their"
    echo "  interleaving without it. Install util-linux and re-run."
    exit 1
  fi

  echo ""
  echo "--- cascade-skip Tests ---"
  test_cascade_skip_loses_a_concurrent_completion
  test_cascade_skip_respects_a_completion_it_can_see

  echo ""
  echo "--- gate-pass / gate-fail Tests ---"
  test_gate_pass_writes_a_gate_that_was_removed_under_it
  test_gate_fail_writes_a_gate_that_was_removed_under_it

  echo ""
  echo "--- reset-orphaned Tests ---"
  test_reset_orphaned_report_can_be_stale_but_the_file_is_not

  echo ""
  echo "================================================"
  echo -e "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
