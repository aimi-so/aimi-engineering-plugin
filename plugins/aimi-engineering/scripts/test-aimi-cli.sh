#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli.sh - Test suite for aimi-cli.sh (dispatcher)
#
# The suite used to be one 28,261-line file. It is now four part files plus a
# shared preamble, and this script runs them CONCURRENTLY and aggregates their
# counts. Invoking it is unchanged: `bash test-aimi-cli.sh` still runs every
# test, still prints each part's stream under its own ">>> Part N" header in
# part order, and still exits non-zero if any assertion failed.
#
# RUNNING SERIALLY — the escape hatch. Concurrency is the default. To put the
# parts back on one core, one after another:
#
#     bash test-aimi-cli.sh --serial          # or -s
#     AIMI_TEST_SERIAL=1 bash test-aimi-cli.sh
#
# Serial mode streams each part's output live instead of buffering it, which is
# what you want when bisecting an intermittent failure, when a part hangs and
# you need to see how far it got, or on a host where four concurrent parts
# would thrash. `--parallel` (`-p`) forces concurrency back on when
# AIMI_TEST_SERIAL is already set in the environment. Nothing else differs
# between the two modes: same parts, same counts, same invariant, same exit
# status — only wall time and whether output is buffered.
#
# HOW THE CONCURRENT RUN STAYS HONEST. A parallel runner that reports green
# while something is broken is worse than a serial one, so three specific
# failure modes are guarded rather than assumed away:
#   - Counts never come from stdout. Each part writes its own
#     "<passed> <failed>" line to its own $AIMI_TEST_PART_RESULT_FILE, and the
#     aggregate is summed from those files, so interleaving cannot corrupt it.
#   - Exit status never comes from a bare `wait`. Each part's status is
#     recorded to its own file by the wrapper that ran it and read back per
#     part below; a part that produced no status file at all counts as broken,
#     never as a pass.
#   - Output never interleaves. Each part's stdout and stderr go to its own
#     file and are replayed in part order once every part has finished, so a
#     bare failure line still sits under the header of the part that produced
#     it. The cost is that a concurrent run prints no assertions until every
#     part has finished; use --serial when you need to watch it live.
#
# WHY IT IS SPLIT — and what the split alone did NOT buy. A command
# substitution forks the entire parent shell before it execs, and that fork
# does cost in proportion to the parent script's size: measured here, one
# substitution costs 0.40ms from a 10-line script, 0.55ms from a ~6,700-line
# part and 0.76ms from the 28,267-line monolith (1.25ms with an exec, 2.37ms
# through a pipe). But at ~270us saved per fork over ~3,269 substitutions that
# is a few seconds, not the tens of seconds first predicted — and the serial
# suite measures the same either way (monolith 490.7s/498.5s vs split
# 500.2s/487.1s). The split is here so each part can be run on its own, so a
# 28,000-line file becomes four navigable ones, and so the parts can run
# concurrently — which is where the actual saving is. Do not cite the split
# itself as a serial speedup; cite the concurrency.
#
# WHAT CONCURRENCY BUYS, AND WHY IT IS ~2.2x RATHER THAN 4x. Measured A/B/A/B
# in a linked worktree on this 16-core host — alternated, never A-once-then-
# B-once, so that a busy machine cannot masquerade as a code win. Serial:
# 382s (first run, cold page cache), 278s, 287s, 278s, 405s. Concurrent: 128s,
# 129s, 130s, 129s, 128s, 129s, 129s, 152s. The absolute times drift with
# whatever else the host is doing; the pairwise ratio drifts much less — five
# back-to-back serial/concurrent pairs gave 2.98x, 2.15x, 2.22x, 2.15x and
# 2.66x. Quote the ratio, ~2.2x and roughly 150s off a run, rather than either
# absolute number.
#
# Four parts on 16 cores does not give 4x, and this script's own per-part
# column says why: a concurrent run finishes when its SLOWEST part does, and
# the parts are nothing like quarters. One pair measured both sides directly —
# serial 54s + 88s + 162s + 101s for a 405s wall, concurrent 42s/72s/152s/104s
# for a 152s wall, which is exactly part 3's own runtime. That equality is not
# a coincidence of one run: across every concurrent run measured here the wall
# clock came out at part 3's time to the second (173s/125s/129s on three
# consecutive runs, against part 3's 173s/125s/129s). Part 3 (roadmap-forge)
# is 40-46% of the serial total, and 1/0.43 is about the ratio observed. The
# suite cannot go below part 3 however many cores are added, so more
# parallelism buys nothing here; the next real speedup is moving tests out of
# part 3.
#
# PARALLEL SAFETY — all four parts are cleared to run concurrently. Audited by
# resource class, not by counting mktemp calls (worktree-manager has 132 of
# those and is still unsafe — its five `serve` assertions collide on a fixed
# port, giving 22/5 under two concurrent runs against 27/0 serially, so
# test-worktree-manager.sh stays serial and is deliberately not touched by this
# runner): no part binds or connects a port; every fixed /tmp literal is a
# value handed to a pure resolver or written as file content, never a path
# created on disk; every git fixture is its own mktemp -d and nothing writes
# git config --global; and the one file all four parts really did write — the
# global cli-path cache, via write_global_cli_cache inside init-session and
# check-version --fix — is now redirected per part by
# test-aimi-cli-common.sh's AIMI_CONFIG_DIR default. Measured: five serial and
# eleven concurrent runs all agree at 522/636/951/971 with zero failures, and a
# deliberately planted cross-part collision was confirmed to pass serially and
# fail concurrently before that clean result was accepted. One caveat that this machine cannot
# reproduce: test_roadmap_claim_stale_release depends on a killed PID still
# reading as dead, and concurrency burns PID space about four times faster, so
# a host with a small /proc/sys/kernel/pid_max is the first suspect if that
# single assertion ever goes intermittent — re-run with --serial to confirm.
#
# WHAT IT COSTS. The last thing every run prints is a fixed-shape `suite-cost`
# line — CLI size, test-corpus size, assertion count, wall seconds, and the
# mode and frame those were measured in. `grep suite-cost` two transcripts and
# the trend is a diff rather than an investigation. See the comment above the
# emit at the bottom of this file for why that is worth a line of output.
#
# ADDING TESTS: put the test function and its main() call in the part that owns
# that concern (each part's header lists its sections), and raise
# EXPECTED_ASSERTIONS below by the number of assertions you added. The
# dispatcher asserts that total explicitly — that check is what proves no test
# was lost, duplicated or silently skipped when the parts moved, and it is
# equally what proves concurrency changed only WHEN tests run, never WHICH.
#
# PORTABILITY: no `mapfile`, no `readarray`, no associative arrays, and no
# indexing into an array by number — none of those behave the same under zsh
# and the bash 3.2 that ships on macOS, and where they are missing the read
# silently produces an empty result instead of an error. Per-part state lives
# in per-part files keyed by the part's index, which needs none of them.

# "${BASH_SOURCE[0]:-$0}" and not "${BASH_SOURCE[0]}": zsh has no BASH_SOURCE,
# and under `set -u` the bare form aborts the expansion, leaving SCRIPT_DIR
# pointing at the caller's cwd and every part reported as a missing file. The
# :- default keeps bash's sourced-file case working and gives zsh $0, which is
# the same path here because this dispatcher is only ever executed.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

PARTS=(
  "test-aimi-cli-part1-core.sh"
  "test-aimi-cli-part2-planning.sh"
  "test-aimi-cli-part3-roadmap-forge.sh"
  "test-aimi-cli-part4-forge-verbs.sh"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

usage() {
  echo "usage: bash test-aimi-cli.sh [--serial|-s] [--parallel|-p]"
  echo ""
  echo "  --serial, -s     run the parts one at a time, streaming their output"
  echo "  --parallel, -p   run the parts concurrently (default)"
  echo ""
  echo "  AIMI_TEST_SERIAL=1 in the environment is equivalent to --serial."
}

RUN_SERIAL=0
case "${AIMI_TEST_SERIAL:-}" in
  ""|0|no|false) ;;
  *) RUN_SERIAL=1 ;;
esac

for arg in "$@"; do
  case "$arg" in
    --serial|-s) RUN_SERIAL=1 ;;
    --parallel|-p) RUN_SERIAL=0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "test-aimi-cli.sh: unknown argument: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# The assertion-count invariant. It is environment-aware for exactly one
# reason: test_init_session_writes_global_cache emits ONE assertion when the
# CLI under test is worktree-resident (write_global_cli_cache deliberately
# refuses to cache a */.worktrees/* path) and THREE otherwise. RUN_FRAME names
# which of the two this run is, so the suite-cost line at the bottom can say so
# out loud rather than leaving the reader to work it out.
#
# ONE literal, and the worktree frame is DERIVED from it. It used to be two, and
# they drifted: three consecutive commits moved both numbers and left the
# sentence above them naming a third pair, eleven behind. Two numbers that must
# differ by a fixed amount are one number and an arithmetic rule -- write the
# rule down and the pair cannot disagree. A commit that adds assertions now
# edits exactly one line here.
_WORKTREE_FRAME_DELTA=2   # 3 assertions minus the 1 a worktree-resident CLI emits
EXPECTED_ASSERTIONS=4002
RUN_FRAME=checkout
_resolved_cli="$(realpath "$SCRIPT_DIR/aimi-cli.sh" 2>/dev/null || printf '%s' "$SCRIPT_DIR/aimi-cli.sh")"
case "$_resolved_cli" in
  */.worktrees/*)
    EXPECTED_ASSERTIONS=$((EXPECTED_ASSERTIONS - _WORKTREE_FRAME_DELTA))
    RUN_FRAME=worktree
    ;;
esac

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

# Run one part in the background. Its stdout and stderr are buffered to a file
# of its own and its exit status is written to another, both keyed by the
# part's index — nothing in here touches the terminal, so concurrent parts
# cannot shred each other's output, and the status survives the bare `wait`
# that reaps them.
launch_part() {
  local idx="$1"
  local part="$2"
  local started rc
  {
    started="$(date +%s)"
    AIMI_TEST_PART_RESULT_FILE="$RESULT_DIR/part-$idx.result" \
      bash "$SCRIPT_DIR/$part" > "$RESULT_DIR/part-$idx.out" 2>&1
    rc=$?
    printf '%s\n' "$rc" > "$RESULT_DIR/part-$idx.exit"
    printf '%s\n' "$(( $(date +%s) - started ))" > "$RESULT_DIR/part-$idx.time"
  } &
}

# Run one part in the foreground, streaming its output. Records its exit status
# to the same per-part file the concurrent path uses, so the collection loop
# below is identical for both modes.
run_part_serially() {
  local idx="$1"
  local part="$2"
  local started rc
  started="$(date +%s)"
  AIMI_TEST_PART_RESULT_FILE="$RESULT_DIR/part-$idx.result" bash "$SCRIPT_DIR/$part"
  rc=$?
  printf '%s\n' "$rc" > "$RESULT_DIR/part-$idx.exit"
  printf '%s\n' "$(( $(date +%s) - started ))" > "$RESULT_DIR/part-$idx.time"
}

START_TS="$(date +%s)"

echo "================================================"
echo "  Aimi CLI Test Suite"
echo "================================================"

PART_INDEX=0

if [ "$RUN_SERIAL" -eq 1 ]; then
  MODE_LABEL="serial"
  echo "  mode: serial — one part at a time, output streamed live"

  for part in "${PARTS[@]}"; do
    PART_INDEX=$((PART_INDEX + 1))
    [ -f "$SCRIPT_DIR/$part" ] || continue
    echo ""
    echo ">>> Part $PART_INDEX/${#PARTS[@]}: $part"
    run_part_serially "$PART_INDEX" "$part"
  done
else
  MODE_LABEL="concurrent"
  echo "  mode: concurrent — ${#PARTS[@]} parts at once. Each part's output is"
  echo "        buffered and replayed in part order once every part has"
  echo "        finished; re-run with --serial to stream it live."

  for part in "${PARTS[@]}"; do
    PART_INDEX=$((PART_INDEX + 1))
    [ -f "$SCRIPT_DIR/$part" ] || continue
    echo "  launched part $PART_INDEX/${#PARTS[@]}: $part"
    launch_part "$PART_INDEX" "$part"
  done

  wait
fi

ELAPSED=$(( $(date +%s) - START_TS ))

TOTAL_PASSED=0
TOTAL_FAILED=0
PARTS_BROKEN=0
PART_SUMMARY=""
PART_INDEX=0

for part in "${PARTS[@]}"; do
  PART_INDEX=$((PART_INDEX + 1))
  part_path="$SCRIPT_DIR/$part"
  out_file="$RESULT_DIR/part-$PART_INDEX.out"
  result_file="$RESULT_DIR/part-$PART_INDEX.result"
  exit_file="$RESULT_DIR/part-$PART_INDEX.exit"
  time_file="$RESULT_DIR/part-$PART_INDEX.time"

  if [ ! -f "$part_path" ]; then
    echo -e "${RED}✗${NC} missing part file: $part_path"
    PARTS_BROKEN=$((PARTS_BROKEN + 1))
    continue
  fi

  # The concurrent path buffered this part's stream; replay it under its own
  # header so the transcript reads exactly like the serial one.
  if [ "$RUN_SERIAL" -eq 0 ]; then
    echo ""
    echo ">>> Part $PART_INDEX/${#PARTS[@]}: $part"
    if [ -f "$out_file" ]; then
      cat "$out_file"
    fi
  fi

  part_broken=0

  part_exit=""
  if [ -f "$exit_file" ]; then
    read -r part_exit < "$exit_file"
  fi
  case "$part_exit" in
    ''|*[!0-9]*)
      echo -e "${RED}✗${NC} $part recorded no usable exit status — it died before it could report one"
      part_broken=1
      part_exit=1
      ;;
  esac

  part_passed=0
  part_failed=0
  if [ -f "$result_file" ]; then
    read -r part_passed part_failed < "$result_file"
  else
    echo -e "${RED}✗${NC} $part produced no result file (exit $part_exit) — its counts are unknown"
    part_broken=1
  fi
  case "$part_passed" in
    ''|*[!0-9]*) part_passed=0; part_broken=1 ;;
  esac
  case "$part_failed" in
    ''|*[!0-9]*) part_failed=0; part_broken=1 ;;
  esac

  if [ "$part_exit" -ne 0 ] && [ "$part_failed" -eq 0 ]; then
    echo -e "${RED}✗${NC} $part exited $part_exit with no failed assertion — it aborted early"
    part_broken=1
  fi

  if [ "$part_failed" -gt 0 ]; then
    echo -e "${RED}✗${NC} $part: $part_failed failed assertion(s) — they are in the Part $PART_INDEX block above"
  fi

  # Per-part wall time. Concurrently the run cannot finish before its slowest
  # part does, so this column is where an unbalanced split shows up: if one
  # part's time is close to the whole run's, moving tests out of it is the only
  # thing that will make the suite faster.
  part_secs=""
  if [ -f "$time_file" ]; then
    read -r part_secs < "$time_file"
  fi
  case "$part_secs" in
    ''|*[!0-9]*) part_time_note="" ;;
    *) part_time_note=" in ${part_secs}s" ;;
  esac

  PARTS_BROKEN=$((PARTS_BROKEN + part_broken))
  TOTAL_PASSED=$((TOTAL_PASSED + part_passed))
  TOTAL_FAILED=$((TOTAL_FAILED + part_failed))
  PART_SUMMARY="${PART_SUMMARY}    ${part}: $((part_passed + part_failed)) assertions ($part_passed passed, $part_failed failed)${part_time_note}"$'\n'
done

TOTAL_ASSERTIONS=$((TOTAL_PASSED + TOTAL_FAILED))

echo ""
echo "================================================"
echo "  Results: ${GREEN}$TOTAL_PASSED passed${NC}, ${RED}$TOTAL_FAILED failed${NC}"
echo "================================================"
echo ""
echo "  Assertions per part:"
printf '%s' "$PART_SUMMARY"

if [ "$TOTAL_ASSERTIONS" -eq "$EXPECTED_ASSERTIONS" ]; then
  INVARIANT_OK=1
  echo -e "  ${GREEN}✓${NC} invariant: the ${#PARTS[@]} parts sum to $TOTAL_ASSERTIONS assertions (expected $EXPECTED_ASSERTIONS)"
else
  INVARIANT_OK=0
  echo -e "  ${RED}✗${NC} invariant: the ${#PARTS[@]} parts sum to $TOTAL_ASSERTIONS assertions, expected $EXPECTED_ASSERTIONS"
  echo "    Either a part lost, duplicated or silently skipped tests, or you added"
  echo "    tests and must raise EXPECTED_ASSERTIONS in this file to match."
fi

printf '  wall clock: %dm%02ds (%s)\n' "$((ELAPSED / 60))" "$((ELAPSED % 60))" "$MODE_LABEL"

# THE SUITE'S OWN COST POSITION. This one line exists because the cost of this
# suite compounds and is invisible: phase 3 of forge-abstraction added ~5,900
# lines to aimi-cli.sh and ~11,000 to the test corpus, and that made the 1,544
# assertions that already existed ~9% slower — 148.75ms to 162.08ms each — for
# tests with no relationship to the code that was added. Nobody noticed until
# somebody asked why the suite was slow, and answering that took hours; printed
# every run, the same regression is visible on the day it lands instead.
#
# It costs two line counts and one clock read, which is why it is on by default
# and why there is deliberately NO calibration or benchmark loop here — a
# per-run benchmark would itself be the sort of cost this line exists to expose.
#
# The field order is fixed on purpose: `grep suite-cost` two transcripts and
# diff them mechanically rather than by eye. `mode` and `frame` are on the line
# because two of the numbers are only comparable within their own environment —
# wall_seconds is not comparable across mode=serial and mode=concurrent, and
# assertions is 2 lower under frame=worktree (see EXPECTED_ASSERTIONS above).
COST_FILES=(
  "$SCRIPT_DIR/test-aimi-cli.sh"
  "$SCRIPT_DIR/test-aimi-cli-common.sh"
  "$SCRIPT_DIR/test-aimi-cli-fixtures.sh"
)
for cost_part in "${PARTS[@]}"; do
  COST_FILES+=("$SCRIPT_DIR/$cost_part")
done

# `wc -l` over the whole set in one call, reading its trailing `total` row; with
# a single surviving file wc prints no total row and awk's END still holds that
# file's own count, and with none it holds nothing and `+ 0` yields 0. Reading
# through awk rather than `wc -l <file` also drops the leading padding that BSD
# wc emits and GNU wc does not.
CLI_LINES="$(wc -l < "$SCRIPT_DIR/aimi-cli.sh" 2>/dev/null | awk 'END { print $1 + 0 }')"
TEST_LINES="$(wc -l "${COST_FILES[@]}" 2>/dev/null | awk 'END { print $1 + 0 }')"

printf '  suite-cost cli_lines=%s test_lines=%s assertions=%s wall_seconds=%s mode=%s frame=%s\n' \
  "$CLI_LINES" "$TEST_LINES" "$TOTAL_ASSERTIONS" "$ELAPSED" "$MODE_LABEL" "$RUN_FRAME"
echo "    frame=worktree legitimately scores 2 FEWER assertions than frame=checkout on the"
echo "    same tree (worktree-resident CLI: 1 assertion where a checkout emits 3), so compare"
echo "    a container run against a container run — two tests did not vanish."

if [ "$TOTAL_FAILED" -gt 0 ] || [ "$PARTS_BROKEN" -gt 0 ] || [ "$INVARIANT_OK" -eq 0 ]; then
  exit 1
fi
