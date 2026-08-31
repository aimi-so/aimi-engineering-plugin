#!/usr/bin/env bash
set -uo pipefail

# test-command-size.sh - Byte-budget guard for commands/ (including references/)
#
# WHY THIS EXISTS
#
# commands/*.md files grow prose the same way any file does: one paragraph
# at a time, each addition individually reasonable, none of them ever
# reverted. Nothing in this repo made that growth visible at review time --
# a PR diff shows the lines it adds, not the file's new total size, and
# `git diff --stat` scrolls past a byte count nobody reads. By the time this
# suite was written execute.md had reached 347408 bytes and plan.md 297204,
# both discovered only by deliberately measuring, not by any signal a
# reviewer would have seen along the way.
#
# WHAT IT CHECKS
#
#   1. every commands/**/*.md file is within its recorded budget (the twelve
#      files in command-size-baseline.txt) or the shared DEFAULT_CEILING
#      (everything else) -- against the real tree
#   2. every baseline line still names a file that exists under commands/
#   3. the recursive sweep's file count matches an independent `find`, and
#      actually reaches commands/references/, not just top-level files
#   4. (self-contained, against a throwaway fixture) the same checking
#      function used above discriminates in both ratchet directions: a file
#      that grows past its budget fails, and a file that shrinks below its
#      budget also fails
#
# THE RATCHET IS BIDIRECTIONAL, ON PURPOSE
#
# A budget that only ever caught growth would let a file shrink and then
# leave its old, now-too-generous number on the books -- slack a later,
# unrelated change could spend without anyone reviewing it as growth. So a
# recorded budget is a promise that someone measured that EXACT size: going
# over fails as "over budget", going under fails as "stale budget", and the
# only way to satisfy either is to write the file's real current size into
# command-size-baseline.txt in the same commit. See that file's own header
# for the fuller reasoning; it is not repeated here.
#
# WHY THE BUDGET IS MEASURED PRE-INSTALL, NOT AGAINST install.sh'S OUTPUT
#
# install.sh's translate_command_body() prepends a fixed agent-invocation
# preamble to some command bodies (the ones that reference a Task
# subagent_type) and not others. Measuring the installed OpenCode output
# would blend "this file carries too much prose" with "the installer added
# its own fixed boilerplate", and running install.sh as a prerequisite would
# turn this suite into a build step -- the one property root CLAUDE.md's
# Testing section promises this whole family of suites keeps. The budget is
# measured against the source .md file a PR diff actually shows.
#
# HONEST LIMIT
#
# This suite counts bytes, not tokens, and says nothing about whether a
# file's prose is well organized -- a file under its budget can still be
# poorly structured, and this suite is silent on that. It only makes size
# regressions visible at test time instead of invisible until someone
# happens to measure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$SCRIPT_DIR/../commands"
BASELINE_FILE="$SCRIPT_DIR/command-size-baseline.txt"

# Sits strictly between design/polish.md (15746 bytes, the largest file with
# no baseline entry) and deepen.md (18029 bytes, the smallest grandfathered
# file) -- see command-size-baseline.txt's own header for why these twelve
# files could not simply be shrunk to fit under it instead.
DEFAULT_CEILING=16384

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Test helpers (verbatim from test-command-blocks.sh)
# ---------------------------------------------------------------------------
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

# Reports a check's findings. Empty findings pass; otherwise every finding is
# printed on its own line, since a one-line "Actual:" is useless for a list.
assert_no_findings() {
  local findings="$1"
  local test_name="$2"
  local hint="$3"

  if [ -z "$findings" ]; then
    echo -e "${GREEN}✓${NC} $test_name"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} $test_name"
    echo "  $hint"
    printf '%s\n' "$findings" | sed 's/^/    /'
    ((TESTS_FAILED++))
  fi
}

# ---------------------------------------------------------------------------
# check_budgets(dir, baseline_file, ceiling) -- the one function that gates
# both the real tree and the discrimination fixture below, so the code that
# enforces the rule is the same code that proves it discriminates.
#
# Walks every *.md file under $dir recursively (this is what covers
# references/ for free -- no special-casing needed), measures it with
# `wc -c`, and for each file relative to $dir:
#   - has a recorded budget in $baseline_file:
#       size > budget  -> "over budget"  (the ratchet's growth-fails half)
#       size < budget  -> "stale budget" (the ratchet's shrink-fails half)
#       size == budget -> no finding
#   - no recorded budget:
#       size > ceiling -> "over ceiling"
#       size <= ceiling -> no finding
#
# Prints one finding per line, tab-free (findings themselves may not contain
# a literal newline, since callers print one finding per line).
# ---------------------------------------------------------------------------
check_budgets() {
  local dir="$1" baseline_file="$2" ceiling="$3"
  local -A budget=()
  local relpath amount

  if [ -f "$baseline_file" ]; then
    while IFS=$'\t' read -r relpath amount; do
      [ -n "$relpath" ] || continue
      budget["$relpath"]="$amount"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$baseline_file")
  fi

  local file relp size have findings=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    relp="${file#"$dir"/}"
    size="$(wc -c < "$file" | tr -d ' ')"

    if [ -n "${budget[$relp]+x}" ]; then
      have="${budget[$relp]}"
      if [ "$size" -gt "$have" ]; then
        findings="$findings$relp: over budget ($size bytes > $have recorded -- shrink the file, or raise its baseline entry in the same commit)"$'\n'
      elif [ "$size" -lt "$have" ]; then
        findings="$findings$relp: stale budget ($size bytes < $have recorded -- lower the baseline entry to $size in the same commit that shrank this file)"$'\n'
      fi
    else
      if [ "$size" -gt "$ceiling" ]; then
        findings="$findings$relp: over ceiling ($size bytes > default ceiling $ceiling -- add a grandfathered line to $(basename "$baseline_file"), or shrink the file back under the ceiling)"$'\n'
      fi
    fi
  done < <(find "$dir" -name '*.md' | sort)

  printf '%s' "$findings"
}

# ---------------------------------------------------------------------------
# check_real_tree() -- the "passes today" discrimination criterion: gates
# the actual commands/ tree with the actual baseline and reports zero
# findings.
# ---------------------------------------------------------------------------
check_real_tree() {
  local findings
  findings="$(check_budgets "$COMMANDS_DIR" "$BASELINE_FILE" "$DEFAULT_CEILING")"
  assert_no_findings "$findings" \
    "Every commands/**/*.md file is within its recorded budget or the default ceiling" \
    "See the finding above for which direction the drift went and what to do about it."
}

# ---------------------------------------------------------------------------
# check_baseline_hygiene() -- mirror of test-command-blocks.sh's
# check_baseline_current(). A baseline line naming a file that no longer
# exists under commands/ (renamed or deleted) is a stale entry, not slack --
# it must be removed rather than left as an unclaimed budget nothing checks.
# ---------------------------------------------------------------------------
check_baseline_hygiene() {
  local findings="" relpath amount

  while IFS=$'\t' read -r relpath amount; do
    [ -n "$relpath" ] || continue
    [ -f "$COMMANDS_DIR/$relpath" ] \
      || findings="$findings$relpath: no longer exists under commands/ -- remove this line from $(basename "$BASELINE_FILE")"$'\n'
  done < <(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" 2>/dev/null || true)

  assert_no_findings "$findings" \
    "Baseline hygiene -- every $(basename "$BASELINE_FILE") line names a file that still exists" \
    "A stale entry names a renamed or deleted file. Delete the line, don't leave it as unclaimed slack."
}

# ---------------------------------------------------------------------------
# check_structural_coverage() -- confirms the recursive sweep covers the
# whole commands/**/*.md tree, references/ included, not just the top-level
# command files.
# ---------------------------------------------------------------------------
check_structural_coverage() {
  local total refs

  total="$(find "$COMMANDS_DIR" -name '*.md' | wc -l | tr -d ' ')"
  assert_eq "31" "$total" \
    "commands/**/*.md sweep matches \`find plugins/aimi-engineering/commands -name '*.md' | wc -l\`"

  refs="$(find "$COMMANDS_DIR" -name '*.md' | grep -c '/references/' || true)"
  assert_eq "true" "$([ "${refs:-0}" -gt 0 ] && echo true || echo false)" \
    "The recursive sweep reaches commands/references/, not only top-level command files"
}

# ---------------------------------------------------------------------------
# check_discrimination() -- self-contained proof, against a throwaway
# mktemp -d fixture (never a real commands/ file), that check_budgets()
# actually discriminates in both ratchet directions. Five cases:
#   - unbudgeted file under the ceiling             -> no finding
#   - unbudgeted file over the ceiling               -> "over ceiling"
#   - budgeted file exactly at its budget            -> no finding
#   - budgeted file 1 byte over its budget           -> "over budget"
#   - budgeted file under its budget                 -> "stale budget"
#
# The fixture includes a references/ subdirectory so the same recursive
# coverage the real check relies on is exercised here too.
# ---------------------------------------------------------------------------
check_discrimination() {
  local fixture
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' RETURN

  mkdir -p "$fixture/dir/references"

  printf '%s' "ab"                 > "$fixture/dir/plain.md"              # 2 bytes,  no budget, ceiling=5 -> under ceiling
  printf '%s' "0123456789012345678901234567890123456789012345678" > "$fixture/dir/big.md"  # 51 bytes, no budget, ceiling=5 -> over ceiling
  printf '%s' "12345"               > "$fixture/dir/references/exact.md"  # 5 bytes,  budget=5 -> exact match
  printf '%s' "123456"              > "$fixture/dir/references/over.md"   # 6 bytes,  budget=5 -> 1 byte over
  printf '%s' "12"                  > "$fixture/dir/references/stale.md"  # 2 bytes,  budget=5 -> stale (shrunk)

  cat > "$fixture/baseline.txt" <<'EOF'
# fixture baseline for the discrimination test
references/exact.md	5
references/over.md	5
references/stale.md	5
EOF

  local findings
  findings="$(check_budgets "$fixture/dir" "$fixture/baseline.txt" 5)"

  assert_eq "false" "$(printf '%s\n' "$findings" | grep -q '^plain\.md:' && echo true || echo false)" \
    "Discrimination -- unbudgeted file under the ceiling produces no finding"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^big\.md: over ceiling' && echo true || echo false)" \
    "Discrimination -- unbudgeted file over the ceiling produces an 'over ceiling' finding"

  assert_eq "false" "$(printf '%s\n' "$findings" | grep -q '^references/exact\.md:' && echo true || echo false)" \
    "Discrimination -- file exactly at its recorded budget produces no finding"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^references/over\.md: over budget' && echo true || echo false)" \
    "Discrimination -- file 1 byte over its recorded budget produces an 'over budget' finding (ratchet: growth fails)"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^references/stale\.md: stale budget' && echo true || echo false)" \
    "Discrimination -- file below its recorded budget produces a 'stale budget' finding (ratchet: shrinking also fails)"

  rm -rf "$fixture"
  trap - RETURN
}

main() {
  echo "Measuring commands/**/*.md against command-size-baseline.txt..."
  echo ""

  echo "--- Real Tree ---"
  check_real_tree
  check_baseline_hygiene
  check_structural_coverage

  echo ""
  echo "--- Discrimination (throwaway mktemp -d fixture) ---"
  check_discrimination

  echo ""
  echo "================================================"
  echo -e "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
