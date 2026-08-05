#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli.sh - Test suite for aimi-cli.sh (dispatcher)
#
# The suite used to be one 28,261-line file. It is now four part files plus a
# shared preamble, and this script runs them in series and aggregates their
# counts. Invoking it is unchanged: `bash test-aimi-cli.sh` still runs every
# test, prints the same section/assertion stream, and exits non-zero if any
# assertion failed.
#
# WHY IT IS SPLIT — and what the split does NOT buy. A command substitution
# forks the entire parent shell before it execs, and that fork does cost in
# proportion to the parent script's size: measured here, one substitution costs
# 0.40ms from a 10-line script, 0.55ms from a ~6,700-line part and 0.76ms from
# the 28,267-line monolith (1.25ms with an exec, 2.37ms through a pipe). But at
# ~270us saved per fork over ~3,269 substitutions that is a few seconds, not
# the tens of seconds first predicted — and the serial suite measures the same
# either way (monolith 490.7s/498.5s vs split 500.2s/487.1s). The split is here
# so each part can be run on its own, so a 28,000-line file becomes four
# navigable ones, and so the parts can later run in parallel, which is where
# the actual saving is. Do not cite it as a serial speedup.
#
# ADDING TESTS: put the test function and its main() call in the part that owns
# that concern (each part's header lists its sections), and raise
# EXPECTED_ASSERTIONS below by the number of assertions you added. The
# dispatcher asserts that total explicitly — that check is what proves no test
# was lost, duplicated or silently skipped when the parts moved.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# The assertion-count invariant. It is environment-aware for exactly one
# reason: test_init_session_writes_global_cache emits ONE assertion when the
# CLI under test is worktree-resident (write_global_cli_cache deliberately
# refuses to cache a */.worktrees/* path) and THREE otherwise. The same tree
# therefore reads 3080 from a linked worktree and 3082 from a normal checkout.
EXPECTED_ASSERTIONS=3082
_resolved_cli="$(realpath "$SCRIPT_DIR/aimi-cli.sh" 2>/dev/null || printf '%s' "$SCRIPT_DIR/aimi-cli.sh")"
case "$_resolved_cli" in
  */.worktrees/*) EXPECTED_ASSERTIONS=3080 ;;
esac

RESULT_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULT_DIR"' EXIT

echo "================================================"
echo "  Aimi CLI Test Suite"
echo "================================================"

TOTAL_PASSED=0
TOTAL_FAILED=0
PARTS_BROKEN=0
PART_SUMMARY=""
PART_INDEX=0

for part in "${PARTS[@]}"; do
  PART_INDEX=$((PART_INDEX + 1))
  part_path="$SCRIPT_DIR/$part"

  if [ ! -f "$part_path" ]; then
    echo -e "${RED}✗${NC} missing part file: $part_path"
    PARTS_BROKEN=$((PARTS_BROKEN + 1))
    continue
  fi

  echo ""
  echo ">>> Part $PART_INDEX/${#PARTS[@]}: $part"

  result_file="$RESULT_DIR/part-$PART_INDEX.result"
  AIMI_TEST_PART_RESULT_FILE="$result_file" bash "$part_path"
  part_exit=$?

  part_passed=0
  part_failed=0
  if [ -f "$result_file" ]; then
    read -r part_passed part_failed < "$result_file"
  else
    echo -e "${RED}✗${NC} $part produced no result file (exit $part_exit) — its counts are unknown"
    PARTS_BROKEN=$((PARTS_BROKEN + 1))
  fi

  if [ "$part_exit" -ne 0 ] && [ "$part_failed" -eq 0 ]; then
    echo -e "${RED}✗${NC} $part exited $part_exit with no failed assertion — it aborted early"
    PARTS_BROKEN=$((PARTS_BROKEN + 1))
  fi

  TOTAL_PASSED=$((TOTAL_PASSED + part_passed))
  TOTAL_FAILED=$((TOTAL_FAILED + part_failed))
  PART_SUMMARY="${PART_SUMMARY}    ${part}: $((part_passed + part_failed)) assertions ($part_passed passed, $part_failed failed)"$'\n'
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

if [ "$TOTAL_FAILED" -gt 0 ] || [ "$PARTS_BROKEN" -gt 0 ] || [ "$INVARIANT_OK" -eq 0 ]; then
  exit 1
fi
