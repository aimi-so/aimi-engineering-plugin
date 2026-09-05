#!/usr/bin/env bash
set -uo pipefail

# test-tasks-concurrency.sh - what the tasks.json verbs do when two of them
# run at once.
#
# THE ASSERTIONS IN THIS FILE HAVE INVERTED, AND THAT INVERSION IS THE POINT.
#
# As first written this suite was green against four KNOWN DEFECTS: each of
# these verbs read a precondition in an unlocked jq and then acted on that
# answer under the lock, so a concurrent writer could invalidate it in between.
# The commit that moved the four onto one crossing into scripts/tasks.py —
# read, decide and write all inside the lock — closed three of those races and
# fixed the fourth's report, and the diff of THIS FILE is the statement of what
# changed and when. `assert_eq "skipped"` became `assert_eq "completed"`; the
# gate tests now expect a refusal where they expected an invented gate.
#
# A reviewer can read the inverted assertions and know exactly what moved
# without reasoning about concurrency from source. And the inversion happened
# in ONE labelled commit: this suite stayed green, un-inverted, through every
# pure-port slice before it, which is the evidence those slices were pure. If a
# later change closes or reopens one of these races by accident, this file goes
# red where it happened.
#
# THE GOLDEN CORPUS COVERS NONE OF THIS, AND CANNOT. scripts/tests/
# golden_from_jq.json is single-threaded by construction — one CLI invocation
# per recorded case, comparing stdout, exit status and the resulting document.
# No recording of a single process can observe a lost update. This suite is the
# separate artifact that covers what the golden cannot; a reviewer who assumes
# the golden covers concurrency is wrong.
#
# THE SCHEDULE IS PRODUCED EXACTLY, NOT APPROXIMATED, AND NEEDS NO SLEEP.
# This suite takes the tasks file's own lock itself, launches the verb under
# test (which now blocks, because its only read is inside that lock), mutates
# the document underneath it, and only then releases. The verb therefore reads
# what the mutation left behind — not because the timing worked out, but
# because the lock orders it. Every test that races a verb against a CHANGING
# document uses that one helper; the single-writer control does not, and is the
# poorer for nothing.
#
# The two tests at the bottom of this file race two verbs against EACH OTHER
# instead, over a document nothing else touches, and they take the lock for a
# different job: as a starting gate that holds both until both are queued, with
# no mutation to apply. Same lock, same reason it needs no sleep, second helper
# — run_two_against_a_held_gate, beside the first.
#
# It did not always: the cascade-skip test used to sleep 0.10s into a window
# measured in seconds, which is what an UNLOCKED quadratic `reduce
# range(length)` closure cost at 400 stories (~37ms at 50, ~337ms at 200,
# ~2826ms at 400 on a 16-core host with jq-1.6). That window is gone — there is
# no unlocked read left to sleep into — so the test now produces its
# interleaving the same way the other three always did. The fan-shaped fixture
# stays: every story depending on one root is still the shape that exercises
# the closure hardest.
#
# WHAT KEEPS THESE TESTS FROM PASSING VACUOUSLY, AND WHY THE PROBE HAS TWO
# ARMS. Holding the lock guarantees a one-crossing verb cannot observe the
# pre-mutation document. It guarantees nothing about the verbs these tests were
# written against: those read BEFORE taking the lock, so a mutation that lands
# early is one they read normally, and every assertion here would go green
# against the defect it was written to catch. Verified, not assumed — with a
# probe that only proved the verb was running, this whole file passed against
# the unported jq.
#
# So the lock holder waits for `verb_past_its_read_point`, which is true once
# EITHER the verb has created its pre-lock `mktemp` sibling (proof an unlocked
# read already happened) OR some process is blocked waiting for the lock this
# suite holds (proof a locked read has not happened yet, and cannot until the
# release). One predicate, both shapes, and the mutation lands on the correct
# side of each. Run this file against a tree without the fix and it goes red;
# that is the property that makes the inversion a proof rather than a claim.
#
# SERIAL ONLY, AND DELIBERATELY NOT IN test-aimi-cli.sh's PARTS ARRAY. Every
# test here spawns background processes that contend for one lock and one
# document. The standing precedent is test-worktree-manager.sh: also not
# parallel-safe (its five `serve` assertions collide on a fixed port), also
# deliberately left out of the dispatcher, also documented in the root
# CLAUDE.md as its own entry point. This suite follows that shape exactly —
# own SCRIPT_DIR, own counters, own fixtures under `mktemp -d`, its own
# passed/failed totals on exit, and a non-zero status if anything failed.
#
# The cost of staying out is that these assertions do not roll into the
# dispatcher's EXPECTED_ASSERTIONS invariant. That is paid for by printing the
# totals below and by the root CLAUDE.md naming this file beside the other
# suites, so no reviewer has to discover it.
#
# DETERMINISM AS MEASURED, NOT AS CLAIMED. A test that passes once and flakes
# later is worse than no test at all here, because the whole point of this file
# is what its assertions say about behaviour, and nobody can read a noisy suite
# as proof. Twelve consecutive runs were the bar against the jq; eight
# consecutive runs were the bar against the port, all of them 18 passed, 0
# failed, exit 0.
#
# Those figures are the record of what was measured then, and they are left as
# found. The mark-complete and update-field tests took the count from 18 to 29
# and paid the same bar for it: eight consecutive runs, all of them 29 passed,
# 0 failed, exit 0. A run reporting any other total is reporting a change to
# this file, not noise.
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
# is the shape that exercises cascade-skip's transitive closure hardest, and
# it is what made that closure expensive enough to race against back when it
# ran outside the lock. See the header.
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
# A verb that reads its precondition OUTSIDE the lock does its read FIRST, then
# mktemp, then blocks on the lock — so the sibling appearing is a happens-after
# proof that the unlocked read is already done. Globbed by `find` rather than
# by the shell so no shell's no-match behaviour (bash's literal-pattern, zsh's
# hard error) can leak in. The six-character suffix cannot collide with
# "${tasks_file}.lock" (four) or with this suite's own
# "${tasks_file}.holdertmp" (nine).
#
# No verb here has such a sibling any more: each makes one crossing into
# tasks.py inside the lock, and the temp file tasks.py writes is created there.
# The predicate is kept, and is still the half of verb_past_its_read_point that
# discriminates — see that comment.
tmp_sibling_exists() {
  local tasks_file="$1"
  find "$(dirname "$tasks_file")" -maxdepth 1 -name "$(basename "$tasks_file").??????" -print 2>/dev/null | grep -q .
}

# True once some process is BLOCKED waiting for the lock on $1.
#
# Which is the shape a one-crossing verb has: taking the lock is its first
# file action, so it never reaches a read to be caught mid-way through. Linux
# lists blocked lock requests in /proc/locks with a `->` marker and the target
# inode in decimal; where that file is unreadable this returns false and the
# poll below falls back to the sibling alone, which costs a timeout rather than
# an answer.
verb_waits_for_lock() {
  local lock_file="$1"
  [ -r /proc/locks ] || return 1
  local inode
  inode=$(stat -c '%i' "$lock_file" 2>/dev/null) || return 1
  [ -n "$inode" ] || return 1
  grep -q -- "-> FLOCK .*:${inode} " /proc/locks 2>/dev/null
}

# True once the verb has demonstrably passed the point where a pre-lock read
# would have happened. THIS IS THE PREDICATE THAT MAKES THE INVERSION MEAN
# SOMETHING, and it has to answer for both shapes at once:
#
#   * a verb that reads outside the lock announces itself with the mktemp
#     sibling, and the mutation must land AFTER that read or the defect is
#     never exercised and the test passes vacuously;
#   * a verb that reads inside the lock announces itself by blocking on that
#     lock, and the mutation must land BEFORE it is granted.
#
# Waiting for either is what lets one suite discriminate between them. Drop the
# first arm and these tests go green against the very jq they were written to
# catch; drop the second and every one of them burns wait_for's whole timeout.
verb_past_its_read_point() {
  local tasks_file="$1"
  tmp_sibling_exists "$tasks_file" || verb_waits_for_lock "$tasks_file.lock"
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

# Runs `$CLI <verb> <args...>` against a fixture while this suite holds the
# tasks.json lock, and applies `$mutation` (a jq program) to the file before
# releasing it. The verb blocks on the lock, so what it goes on to read is
# what the mutation left behind — ordered by the lock, not by timing.
#
# All four of the mutation tests use this now, which is why it lives here
# beside the other fixture helpers rather than under one test's banner. The
# cascade-skip test used to sleep into an unlocked window instead; there is no
# unlocked window left to sleep into. The two two-verb tests at the bottom of
# the file do not mutate anything and use run_two_against_a_held_gate below.
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
    if wait_for verb_past_its_read_point "$tasks_file"; then
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


# How many processes are BLOCKED waiting for the lock on $1 — the counting
# form of verb_waits_for_lock.
#
# The tests below queue TWO verbs behind one gate rather than one, and
# "somebody is waiting" cannot tell a pair that collided from a pair that ran
# one after the other. A test that cannot tell those apart proves nothing about
# concurrency, which is the same failure mode the header's probe paragraph is
# about. Same /proc/locks source and the same unreadable-file fallback: 0,
# which the poll reads as "not yet" and pays for with a timeout rather than
# with a wrong answer.
lock_waiter_count() {
  local lock_file="$1"
  [ -r /proc/locks ] || { printf '0\n'; return 0; }
  local inode
  inode=$(stat -c '%i' "$lock_file" 2>/dev/null) || { printf '0\n'; return 0; }
  [ -n "$inode" ] || { printf '0\n'; return 0; }
  local n
  n=$(grep -c -- "-> FLOCK .*:${inode} " /proc/locks 2>/dev/null) || n=0
  printf '%s\n' "$n"
}

# The counting form of tmp_sibling_exists, for the same reason and over the
# same glob.
tmp_sibling_count() {
  local tasks_file="$1"
  find "$(dirname "$tasks_file")" -maxdepth 1 -name "$(basename "$tasks_file").??????" -print 2>/dev/null | wc -l | tr -d ' '
}

# True once BOTH verbs have demonstrably passed the point where a pre-lock read
# would have happened. The two-verb form of verb_past_its_read_point, and it
# keeps both of that predicate's arms for exactly the reasons stated there: the
# sibling arm answers for a verb that reads outside the lock, the waiter arm
# for one that reads inside it, and dropping either costs the same thing here
# as it costs there.
both_verbs_past_their_read_point() {
  local tasks_file="$1"
  [ "$(tmp_sibling_count "$tasks_file")" -ge 2 ] ||
    [ "$(lock_waiter_count "$tasks_file.lock")" -ge 2 ]
}

# Runs TWO $CLI invocations against one document, released together from a gate
# this suite holds. The gate mutates nothing: what is under test here is what
# the two verbs do to EACH OTHER, not what one of them does to a document
# changed underneath it, so there is no mutation to apply and the lock is a
# starting line rather than an interleaving.
#
# The two arguments are FUNCTION NAMES, one per invocation. The suite's own
# portability rules forbid indexing an array by number, and two verbs with
# differently shaped argument lists cannot share one flat "$@" without it. A
# named function per side also puts each invocation next to the test that
# depends on it, spelled the way it would be typed.
#
# Both are launched only once the gate is genuinely held, and the gate is only
# released once both are demonstrably queued behind it — the premise every test
# below asserts rather than assumes, in the same shape as HELD_LOCK_MARKED.
run_two_against_a_held_gate() {
  local tasks_file="$1"
  local first="$2"
  local second="$3"

  local ready="$tasks_file.ready"
  local queued="$tasks_file.queued"
  rm -f "$ready" "$queued"

  (
    flock -x 9
    : > "$ready"
    if wait_for both_verbs_past_their_read_point "$tasks_file"; then
      : > "$queued"
    fi
  ) 9>"$tasks_file.lock" &
  local holder=$!

  # Same reason as run_against_a_held_lock: launching before the gate is held
  # lets a verb sail straight through and test nothing.
  wait_for file_exists "$ready"

  local rc1=0 rc2=0
  "$first" > "$tasks_file.out1" 2>&1 &
  local pid1=$!
  "$second" > "$tasks_file.out2" 2>&1 &
  local pid2=$!

  wait "$holder"
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?

  HELD_GATE_RC1="$rc1"
  HELD_GATE_RC2="$rc2"
  HELD_GATE_QUEUED=0
  [ -e "$queued" ] && HELD_GATE_QUEUED=1
  HELD_GATE_OUT1="$tasks_file.out1"
  HELD_GATE_OUT2="$tasks_file.out2"
}

# ============================================================================
# cascade-skip: the lost-completion race, now closed
# ============================================================================

# THE ASSERTIONS BELOW INVERTED, AND THAT INVERSION IS THE REVIEWABLE PROOF
# THAT THE BEHAVIOUR CHANGED. They read `assert_eq "skipped"` when this suite
# was written; they read `assert_eq "completed"` now.
#
# What they used to assert, precisely:
#
#   cmd_cascade_skip computed its skip set in an UNLOCKED jq call, and that
#   call was the ONLY place `status != "completed"` was ever tested. The locked
#   apply that followed asked a different and weaker question — its inner
#   filter was `if (.id as $sid | $to_skip | any(. == $sid)) then` — membership
#   in a list of ids computed some seconds ago, with no re-read of status.
#
#   So a story that COMPLETED during that window was overwritten with
#   `status: "skipped"` and a note claiming it depended on a failed story. The
#   completion was lost, and the note that replaced it was false: the story did
#   not fail and was not skipped, it finished. Eight times out of eight.
#
# The verb now makes one crossing into tasks.py inside the lock: the closure,
# both status filters, the write and the report all run against the same
# document. A completion that lands before the lock is granted is therefore
# SEEN, and the story it belongs to is never added to the skip set.
#
# This was data loss, and it is the reason this suite exists. It was NOT the
# same class of bug as the reset-orphaned divergence at the bottom of this file
# — see the comment there.
test_cascade_skip_keeps_a_concurrent_completion() {
  echo ""
  echo "=== cascade-skip: a completion that lands before the lock is kept ==="

  local dir="$TEST_DIR/cascade-race"
  local tasks_file
  tasks_file=$(build_fan_fixture "$dir" 400)

  cd "$dir" || return

  # US-001 is the fan root; every other story depends on it, so the skip set
  # would be US-002..US-400. US-200 completes while cascade-skip is in flight
  # and waiting for the lock this suite holds.
  run_against_a_held_lock "$tasks_file" \
    '(.userStories[] | select(.id == "US-200")) |= . + {status: "completed"}' \
    cascade-skip US-001

  # The premise, asserted rather than assumed. If cascade-skip were ever to
  # finish before the completion landed, THIS assertion fails loudly instead of
  # the test quietly proving nothing.
  assert_eq "1" "$HELD_LOCK_MARKED" \
    "cascade-skip race: the completion landed while cascade-skip was in flight"
  assert_exit_code "0" "$HELD_LOCK_RC" "cascade-skip race: cascade-skip exits 0"

  local final_status final_notes
  final_status=$(jq -r '.userStories[] | select(.id == "US-200") | .status' "$tasks_file")
  final_notes=$(jq -r '.userStories[] | select(.id == "US-200") | .notes' "$tasks_file")

  # INVERTED — this expected "skipped" when the closure ran outside the lock.
  assert_eq "completed" "$final_status" \
    "cascade-skip race: the completed story keeps its status"
  # INVERTED — this expected the "depends on failed story" note.
  assert_eq "" "$final_notes" \
    "cascade-skip race: and keeps its own notes rather than a note about a failure"

  # The printed report agrees with the file, as it always did — what changed is
  # that the file is now right, so agreeing with it is worth something.
  local reported
  reported=$(jq -r '[.skipped[] | select(. == "US-200")] | length' "$HELD_LOCK_OUT")
  # INVERTED — this expected 1.
  assert_eq "0" "$reported" \
    "cascade-skip race: and the report does not claim US-200 among the skipped"
}

# The control. Same verb, same fixture shape, no concurrent writer: a story
# already completed BEFORE cascade-skip starts is left alone. It was green
# before the fix too — the closure could always see a completion that predated
# it — which is what isolated the defect above to the window rather than to
# the rule, and is why it does not invert.
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
# gate-pass / gate-fail: the precondition, now read under the lock
# ============================================================================

# INVERTED. cmd_gate_pass used to read "does this story have a gate?" in an
# unlocked jq, then take the lock and write. Between those two crossings the
# answer could change and nothing re-asked it. The write is
# `(.userStories[] | select(.id == $id) | .gate) |= . + {status: "passed"}`,
# and in jq `null + {status: "passed"}` is `{status: "passed"}` — so the verb
# did not fail, it CREATED a gate on a story that no longer had one.
#
# The precondition is now decided inside the same crossing that writes, so the
# verb refuses with the object its pre-lock guard already knew how to print,
# and writes nothing. Ranked with cascade-skip, not with reset-orphaned: the
# file was wrong afterwards. It was narrower only because the window was a lock
# wait rather than seconds of computation.
test_gate_pass_refuses_a_gate_that_was_removed_under_it() {
  echo ""
  echo "=== gate-pass: precondition read under the lock ==="

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
    "gate-pass race: the gate was removed while gate-pass was in flight"
  # INVERTED — this expected 0, on the ground that the no-gate guard had
  # already run outside the lock and could not run again.
  assert_exit_code "1" "$HELD_LOCK_RC" \
    "gate-pass race: exits 1 — the no-gate guard runs where the write happens"

  local on_disk
  on_disk=$(jq -c '.userStories[] | select(.id == "US-001") | .gate' "$tasks_file")
  # INVERTED — this expected {"status":"passed"}.
  assert_eq "null" "$on_disk" \
    "gate-pass race: no gate is invented on a story that has none"

  local echoed
  echoed=$(cat "$HELD_LOCK_OUT")
  # INVERTED — this read `jq -c '.gate'` off an echo-back that reported the
  # invented gate as a real one. There is no echo-back to read: the verb
  # refuses, with the object it has always printed for a story with no gate.
  assert_eq '{"valid":false,"errors":["Story US-001 has no gate defined"]}' "$echoed" \
    "gate-pass race: and refuses with the same object the pre-lock guard printed"
}

# The same crossing in cmd_gate_fail, which carried a byte-identical guard and
# is now one implementation rather than two copies. INVERTED with gate-pass.
test_gate_fail_refuses_a_gate_that_was_removed_under_it() {
  echo ""
  echo "=== gate-fail: precondition read under the lock ==="

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

  # INVERTED — this expected 0.
  assert_exit_code "1" "$HELD_LOCK_RC" \
    "gate-fail race: exits 1 — the no-gate guard runs where the write happens"

  local on_disk
  on_disk=$(jq -c '.userStories[] | select(.id == "US-001") | .gate' "$tasks_file")
  # INVERTED — this expected {"status":"failed"}.
  assert_eq "null" "$on_disk" \
    "gate-fail race: no gate is invented on a story that has none"
}

# ============================================================================
# reset-orphaned: report-only staleness
# ============================================================================

# COSMETIC. NOT DATA LOSS. DO NOT RANK THIS WITH cascade-skip, AND DO NOT READ
# ITS FIX AS RECOVERING ANYTHING.
#
# cmd_reset_orphaned read the orphan list in an unlocked jq, exactly like
# cascade-skip read its skip set. The difference was what the locked write did
# with it: cascade-skip's apply filtered by id alone, but reset-orphaned's
# apply re-selected `status == "in_progress"` and ignored the precomputed list
# entirely. So THE FILE WAS ALREADY CORRECT — a story that stopped being
# in_progress during the window was never touched, then or now.
#
# What could be wrong was the printed `{count, reset}` report, built from the
# stale unlocked read. A caller that trusted stdout over the file believed it
# had reset a story it had not. That is a report bug, and pricing it as data
# loss would over-price the fix.
#
# This test asserts BOTH halves. Only the first inverted: the report is now
# produced by the same locked call that writes, so it names what was written.
# The two file assertions did not invert, because they were never wrong.
test_reset_orphaned_report_is_what_was_written() {
  echo ""
  echo "=== reset-orphaned: the report is what was written (cosmetic fix) ==="

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

  # Half one: the report names only what it reset.
  local reported
  reported=$(jq -c '{count, reset}' "$HELD_LOCK_OUT")
  # INVERTED — this expected {"count":2,"reset":["US-001","US-002"]}, the
  # stale list the unlocked read produced.
  assert_eq '{"count":1,"reset":["US-001"]}' "$reported" \
    "reset-orphaned race: the report no longer names US-002"

  # Half two: the file, which was right all along. These two assertions did NOT
  # invert — they are what makes this cosmetic, and they keep holding.
  local us1 us2
  us1=$(jq -r '.userStories[] | select(.id == "US-001") | .status' "$tasks_file")
  us2=$(jq -r '.userStories[] | select(.id == "US-002") | .status' "$tasks_file")
  assert_eq "failed" "$us1" "reset-orphaned race: the genuinely orphaned story is reset on disk"
  assert_eq "completed" "$us2" \
    "reset-orphaned race: the story that completed under the lock is NOT clobbered on disk"
}

# ============================================================================
# mark-complete: two executors finishing at once
# ============================================================================

# NOTHING BELOW THIS BANNER INVERTED, AND NOTHING BELOW IT SHOULD EVER NEED TO.
# Everything above records a race that was open and is now closed, and its
# assertions changed value in the commit that closed it. These two record a
# guarantee that must not open, so the day one of them changes value is the day
# something broke.
#
# They are here because the scenario is not hypothetical: wave 1 of phase 2 ran
# four story executors against one tasks.json, each calling mark-complete on
# its own story as it finished. Four writers, one document, no coordination
# between them beyond the lock.
#
# The guarantee is read-modify-write atomicity, and it is a property of the
# whole DOCUMENT rather than of one story's field. tasks.py reads the entire
# file, mutates the one story in memory and writes the whole thing back — so
# two of those overlapping with a read taken outside the lock is a lost update
# by construction: the second writer's in-memory document never contained the
# first's completion, the write puts it back on disk without it, and the
# executor whose completion was erased is told it succeeded. Nothing else in
# the tree would notice; the story simply looks unfinished the next time
# somebody asks.
#
# What prevents it is the one-crossing-inside-the-lock shape stated as an
# invariant in plugins/aimi-engineering/CLAUDE.md. That invariant is checked
# structurally by test_every_locked_tasks_verb_crosses_into_python_exactly_once
# in scripts/tests/test_tasks.py, which counts crossings; this test is the
# behavioural half, and it is the one that answers "and what does that buy?".
#
# IT DISCRIMINATES, AND THAT WAS MEASURED RATHER THAN ASSUMED — the same bar
# the header sets for the inverted tests. Run these five assertions against a
# stand-in mark-complete whose read happens before the lock and whose write
# happens inside it (the two-crossing shape the invariant forbids) and four of
# them still pass: the gate premise holds, and BOTH verbs exit 0. The one that
# goes red is the loser's status on disk — still "in_progress", the value the
# fixture started at, because the winner's write put back a document that never
# saw it. That is the whole shape of a lost update, and it is why the exit-code
# assertions are not the ones carrying the weight here.
test_two_mark_completes_both_land() {
  echo ""
  echo "=== mark-complete: two stories completed at once, neither write lost ==="

  local dir="$TEST_DIR/mark-complete-race"
  local tasks_file
  tasks_file=$(build_small_fixture "$dir" <<'EOF'
{
  "schemaVersion": "3.2",
  "metadata": {"title": "ref: mark-complete race", "type": "ref", "branchName": "ref/mark-complete-race", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 4},
  "userStories": [
    {"id": "US-001", "title": "Story one", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 1, "status": "in_progress", "dependsOn": [], "notes": ""},
    {"id": "US-002", "title": "Story two", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 2, "status": "in_progress", "dependsOn": [], "notes": ""}
  ]
}
EOF
  )

  cd "$dir" || return

  run_two_against_a_held_gate "$tasks_file" \
    race_mark_complete_first race_mark_complete_second

  # The premise, asserted rather than assumed — exactly as the tests above
  # assert HELD_LOCK_MARKED. Two marks that happened to run one after the other
  # would satisfy every assertion below while exercising nothing.
  assert_eq "1" "$HELD_GATE_QUEUED" \
    "mark-complete race: both marks were in flight against the same document"
  assert_exit_code "0" "$HELD_GATE_RC1" "mark-complete race: the first mark exits 0"
  assert_exit_code "0" "$HELD_GATE_RC2" "mark-complete race: the second mark exits 0"

  local us1 us2
  us1=$(jq -r '.userStories[] | select(.id == "US-001") | .status' "$tasks_file")
  us2=$(jq -r '.userStories[] | select(.id == "US-002") | .status' "$tasks_file")
  assert_eq "completed" "$us1" \
    "mark-complete race: the first story is completed on disk"
  assert_eq "completed" "$us2" \
    "mark-complete race: and so is the second — neither write is lost"
}

# One invocation each, named so run_two_against_a_held_gate can launch them.
# They inherit the fixture directory the test cd'd into, which is what
# get_tasks_file resolves against.
race_mark_complete_first() { "$CLI" mark-complete US-001; }
race_mark_complete_second() { "$CLI" mark-complete US-002; }

# ============================================================================
# update-field: two writers, one field
# ============================================================================

# THE WEAKER GUARANTEE, AND IT IS WEAKER ON PURPOSE. Two mark-completes touch
# different stories, so "both survive" is the whole of what correctness means
# there. Two update-fields writing the SAME field of the SAME story are asking
# for incompatible things, and no lock can grant both: one of the two values
# has to be the one on disk afterwards.
#
# So this test asserts the pair of properties that ARE owed. The field holds
# one of the two values WHOLE — an arbitrary winner is fine, a blend of the two
# is not — and the document is still parseable, with the rest of the story
# intact. Both are properties of the atomic write (tasks.py writes a temp file
# and renames it) rather than of the ordering, and both are what a reader
# concurrent with either writer depends on.
#
# Do not tighten this into "the second invocation wins". Which invocation the
# kernel grants the lock to first is not this suite's to decide, and asserting
# an order it does not control is how a deterministic suite becomes a flaky
# one.
test_two_update_fields_leave_one_winner() {
  echo ""
  echo "=== update-field: two writers on one field, one whole winner ==="

  local dir="$TEST_DIR/update-field-race"
  local tasks_file
  tasks_file=$(build_small_fixture "$dir" <<'EOF'
{
  "schemaVersion": "3.2",
  "metadata": {"title": "ref: update-field race", "type": "ref", "branchName": "ref/update-field-race", "createdAt": "9999-99-99", "planPath": null, "maxConcurrency": 2},
  "userStories": [
    {"id": "US-001", "title": "Contended story", "description": "d", "acceptanceCriteria": ["Passes"], "priority": 1, "status": "in_progress", "dependsOn": [], "notes": ""}
  ]
}
EOF
  )

  cd "$dir" || return

  run_two_against_a_held_gate "$tasks_file" \
    race_update_notes_first race_update_notes_second

  assert_eq "1" "$HELD_GATE_QUEUED" \
    "update-field race: both writers were in flight against the same field"
  assert_exit_code "0" "$HELD_GATE_RC1" "update-field race: the first write exits 0"
  assert_exit_code "0" "$HELD_GATE_RC2" "update-field race: the second write exits 0"

  local parse_rc=0
  jq empty "$tasks_file" > /dev/null 2>&1 || parse_rc=$?
  assert_exit_code "0" "$parse_rc" \
    "update-field race: the document on disk is still valid JSON"

  local notes whole="no"
  notes=$(jq -r '.userStories[] | select(.id == "US-001") | .notes' "$tasks_file")
  case "$notes" in
    first-writer | second-writer) whole="yes" ;;
  esac
  assert_eq "yes" "$whole" \
    "update-field race: the field holds one of the two values whole, not a blend"

  local title
  title=$(jq -r '.userStories[] | select(.id == "US-001") | .title' "$tasks_file")
  assert_eq "Contended story" "$title" \
    "update-field race: and the rest of the story survives the losing write"
}

race_update_notes_first() { "$CLI" update-field US-001 notes first-writer; }
race_update_notes_second() { "$CLI" update-field US-001 notes second-writer; }

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
  test_cascade_skip_keeps_a_concurrent_completion
  test_cascade_skip_respects_a_completion_it_can_see

  echo ""
  echo "--- gate-pass / gate-fail Tests ---"
  test_gate_pass_refuses_a_gate_that_was_removed_under_it
  test_gate_fail_refuses_a_gate_that_was_removed_under_it

  echo ""
  echo "--- reset-orphaned Tests ---"
  test_reset_orphaned_report_is_what_was_written

  echo ""
  echo "--- mark-complete / update-field Tests ---"
  test_two_mark_completes_both_land
  test_two_update_fields_leave_one_winner

  echo ""
  echo "================================================"
  echo -e "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
