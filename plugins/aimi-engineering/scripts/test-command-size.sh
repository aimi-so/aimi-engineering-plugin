#!/usr/bin/env bash
set -uo pipefail

# test-command-size.sh - Byte-budget guard for commands/ (including
# references/), for skills/**/SKILL.md, and for agents/**/*.md
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
#   1. every file in the corpus is within its recorded budget (the files
#      listed in command-size-baseline.txt) or the shared DEFAULT_CEILING
#      (everything else) -- against the real tree
#   2. every baseline line still names a file that exists
#   3. the recursive sweep's commands/ half matches an independent `find`,
#      and actually reaches commands/references/, not just top-level files,
#      reaches skills/**/SKILL.md and nothing else under skills/, and reaches
#      agents/**/*.md
#   4. (self-contained, against a throwaway fixture) the same checking
#      function used above discriminates in both ratchet directions: a file
#      that grows past its budget fails, and a file that shrinks into the
#      step below its budget also fails
#
# THE RATCHET IS BIDIRECTIONAL, IN STEPS OF BUDGET_STEP BYTES
#
# A budget is a multiple of BUDGET_STEP (4096), and a file passes when it
# sits inside that step: budget - BUDGET_STEP < size <= budget. Going over
# fails as "over budget"; shrinking into a lower step fails as "stale
# budget", so a budget can never sit a whole step generous after the file
# that earned it got smaller. A budget that is not a multiple of the step
# fails as "malformed budget". The step is what keeps an ordinary
# few-hundred-byte edit from touching the baseline at all: when budgets were
# exact byte counts, this file changed in a third of all commits, nearly
# always to record growth nobody was asked to review as growth. See
# command-size-baseline.txt's own header for the rest of the reasoning.
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
# WHY THE CORPUS IS THE EXTRACTOR'S, NOT A SECOND `find`
#
# A SKILL.md is executed the same way a command file is, so it grows prose
# the same way and needs the same visible ceiling; a Task-spawned agent
# definition under agents/ is executed the same way too. The corpus is
# lib/extract-command-blocks.sh's command_block_files() -- the SAME function
# test-command-blocks.sh's extractor walks -- rather than a `find` written
# again here, because two definitions of "the files we cover" is exactly how
# one suite gains a file the other never sees. Only SKILL.md is taken from
# skills/, never its references/*.md; agents/ takes every *.md recursively,
# references/ included, the same shape commands/ already uses. Both rules
# live in that function, and check_structural_coverage() below asserts this
# suite actually inherited them.
#
# Relpaths keep two roots (three discovery roots, two relpath rules) for one
# reason: not moving the budgets that were already recorded. A commands file
# stays `execute.md`; a skills or agents file arrives plugin-root-relative
# and therefore already prefixed, `skills/story-executor/SKILL.md` or
# `agents/research/aimi-foundation-architect.md`, which is what keeps every
# half distinguishable inside one baseline file.
#
# HONEST LIMIT
#
# This suite counts bytes, not tokens, and says nothing about whether a
# file's prose is well organized -- a file under its budget can still be
# poorly structured, and this suite is silent on that. It only makes size
# regressions visible at test time instead of invisible until someone
# happens to measure.
#
# The skills half inherits that limit and adds its own: create-agent-skills
# gives a line-count guidance for SKILL.md, but this suite measures bytes and
# cannot enforce a line count. A recorded budget here is a ratchet against
# further growth, never a statement that the file is the right size.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$PLUGIN_DIR/commands"
SKILLS_DIR="$PLUGIN_DIR/skills"
AGENTS_DIR="$PLUGIN_DIR/agents"
BASELINE_FILE="$SCRIPT_DIR/command-size-baseline.txt"

# command_block_files() -- the corpus definition this suite shares with
# test-command-blocks.sh rather than restating. See this file's header.
# shellcheck source=lib/extract-command-blocks.sh
source "$SCRIPT_DIR/lib/extract-command-blocks.sh"

# The shared ceiling for every corpus file with no baseline entry. It is
# itself a multiple of BUDGET_STEP, so a grandfathered file that shrinks
# under it drops out of the baseline rather than keeping a budget of its own.
DEFAULT_CEILING=16384
BUDGET_STEP=4096

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
# check_budgets(commands_root, skills_root, agents_root, baseline_file,
# ceiling, step) -- the one function that gates both the real tree and the
# discrimination fixture below, so the code that enforces the rule is the
# same code that proves it discriminates.
#
# Walks command_block_files()'s corpus -- every *.md under $commands_root
# recursively (this is what covers references/ for free -- no special-casing
# needed), every SKILL.md under $skills_root, plus every *.md under
# $agents_root recursively -- measures each with `wc -c`, and for each file,
# keyed by its relpath:
#   - has a recorded budget in $baseline_file:
#       budget not a multiple of step -> "malformed budget"
#       size > budget                 -> "over budget"  (growth fails)
#       size <= budget - step         -> "stale budget" (shrinking a step fails)
#       otherwise                     -> no finding
#   - no recorded budget:
#       size > ceiling -> "over ceiling"
#       size <= ceiling -> no finding
#
# A finding names the budget the file should carry instead: the smallest
# multiple of step that holds it, or "remove the line" when that is within
# the ceiling.
#
# Prints one finding per line, tab-free (findings themselves may not contain
# a literal newline, since callers print one finding per line).
# ---------------------------------------------------------------------------
check_budgets() {
  local commands_root="$1" skills_root="$2" agents_root="$3" baseline_file="$4" ceiling="$5" step="$6"
  local -A budget=()
  local relpath amount plugin_root=""

  # The root a skills or agents file's relpath is reported against, so that
  # it arrives already carrying its `skills/` or `agents/` prefix. Either one
  # is enough to derive it, since both sit directly under the plugin root;
  # empty when this call has neither half at all (the discrimination
  # fixture), in which case nothing is ever compared against it.
  if [ -n "$skills_root" ]; then
    plugin_root="$(cd "$skills_root/.." && pwd)"
  elif [ -n "$agents_root" ]; then
    plugin_root="$(cd "$agents_root/.." && pwd)"
  fi

  if [ -f "$baseline_file" ]; then
    while IFS=$'\t' read -r relpath amount; do
      [ -n "$relpath" ] || continue
      budget["$relpath"]="$amount"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$baseline_file")
  fi

  local file relp size have want fix findings=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    relp="$file"
    if [ "${file#"$commands_root"/}" != "$file" ]; then
      relp="${file#"$commands_root"/}"
    elif [ -n "$plugin_root" ] && [ "${file#"$plugin_root"/}" != "$file" ]; then
      relp="${file#"$plugin_root"/}"
    fi
    size="$(wc -c < "$file" | tr -d ' ')"
    want=$(( (size + step - 1) / step * step ))
    if [ "$want" -le "$ceiling" ]; then
      fix="remove its baseline line, the default ceiling covers it"
    else
      fix="set its baseline entry to $want"
    fi

    if [ -n "${budget[$relp]+x}" ]; then
      have="${budget[$relp]}"
      if ! [[ "$have" =~ ^[0-9]+$ ]] || [ $(( have % step )) -ne 0 ]; then
        findings="$findings$relp: malformed budget ($have is not a multiple of $step -- $fix)"$'\n'
      elif [ "$size" -gt "$have" ]; then
        findings="$findings$relp: over budget ($size bytes > $have recorded -- shrink the file, or $fix in the same commit)"$'\n'
      elif [ "$size" -le $(( have - step )) ]; then
        findings="$findings$relp: stale budget ($size bytes fits a step below $have -- $fix in the same commit that shrank this file)"$'\n'
      fi
    else
      if [ "$size" -gt "$ceiling" ]; then
        findings="$findings$relp: over ceiling ($size bytes > default ceiling $ceiling -- add a grandfathered line to $(basename "$baseline_file"), or shrink the file back under the ceiling)"$'\n'
      fi
    fi
  done < <(command_block_files "$commands_root" "$skills_root" "$agents_root")

  printf '%s' "$findings"
}

# ---------------------------------------------------------------------------
# check_real_tree() -- the "passes today" discrimination criterion: gates
# the actual corpus with the actual baseline and reports zero findings.
# ---------------------------------------------------------------------------
check_real_tree() {
  local findings
  findings="$(check_budgets "$COMMANDS_DIR" "$SKILLS_DIR" "$AGENTS_DIR" "$BASELINE_FILE" "$DEFAULT_CEILING" "$BUDGET_STEP")"
  assert_no_findings "$findings" \
    "Every commands/**/*.md, skills/**/SKILL.md and agents/**/*.md file is within its recorded budget or the default ceiling" \
    "See the finding above for which direction the drift went and what to do about it."
}

# ---------------------------------------------------------------------------
# check_baseline_hygiene() -- mirror of test-command-blocks.sh's
# check_baseline_current(). A baseline line naming a file that no longer
# exists (renamed or deleted) is a stale entry, not slack -- it must be
# removed rather than left as an unclaimed budget nothing checks.
#
# A relpath resolves against whichever root claims it, the same rule
# check_budgets() reports against: `execute.md` under commands/, and a
# `skills/`- or `agents/`-prefixed line under the plugin directory --
# $PLUGIN_DIR covers both without telling them apart, since a stale entry is
# a stale entry regardless of which half it came from.
# ---------------------------------------------------------------------------
check_baseline_hygiene() {
  local findings="" relpath amount

  while IFS=$'\t' read -r relpath amount; do
    [ -n "$relpath" ] || continue
    [ -f "$COMMANDS_DIR/$relpath" ] || [ -f "$PLUGIN_DIR/$relpath" ] \
      || findings="$findings$relpath: no longer exists under commands/ or the plugin root -- remove this line from $(basename "$BASELINE_FILE")"$'\n'
  done < <(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" 2>/dev/null || true)

  assert_no_findings "$findings" \
    "Baseline hygiene -- every $(basename "$BASELINE_FILE") line names a file that still exists" \
    "A stale entry names a renamed or deleted file. Delete the line, don't leave it as unclaimed slack."
}

# ---------------------------------------------------------------------------
# check_structural_coverage() -- confirms the sweep covers the whole
# commands/**/*.md tree, references/ included, not just the top-level command
# files, that it reaches skills/**/SKILL.md while taking nothing else from
# skills/, and that it reaches agents/**/*.md (references/ included, the same
# recursive shape commands/ uses).
#
# The skills half is asserted by shape rather than by a hardcoded count. The
# count would fail on the day someone adds a skill, which is not a regression;
# what IS worth pinning is that the corpus reaches skills/ at all and that it
# stops at SKILL.md -- a widened pattern that swept skills/**/references/*.md
# would drag 190 prose files under a byte budget they were never meant for.
# The agents half is asserted the same shape-not-count way, but with no
# SKILL.md-style narrowing to prove: agents/ takes every *.md recursively, so
# what is worth pinning there is only that the sweep reaches it at all.
# ---------------------------------------------------------------------------
check_structural_coverage() {
  local total swept refs corpus skills strays agents

  corpus="$(command_block_files "$COMMANDS_DIR" "$SKILLS_DIR" "$AGENTS_DIR")"

  # Two independent counts of the same set, compared to each other rather
  # than to a literal: a literal here failed every time someone added a
  # step file, which is not a regression.
  total="$(find "$COMMANDS_DIR" -name '*.md' | wc -l | tr -d ' ')"
  swept="$(printf '%s\n' "$corpus" | grep -cF "$COMMANDS_DIR/" || true)"
  assert_eq "$total" "${swept:-0}" \
    "commands/**/*.md sweep matches \`find plugins/aimi-engineering/commands -name '*.md' | wc -l\`"

  refs="$(printf '%s\n' "$corpus" | grep -F "$COMMANDS_DIR/" | grep -c '/references/' || true)"
  assert_eq "true" "$([ "${refs:-0}" -gt 0 ] && echo true || echo false)" \
    "The recursive sweep reaches commands/references/, not only top-level command files"

  # -F, not an anchored pattern: $SKILLS_DIR/$AGENTS_DIR are real paths and
  # can carry a regex metacharacter (a worktree checkout puts them under
  # `.worktrees/`).
  skills="$(printf '%s\n' "$corpus" | grep -cF "$SKILLS_DIR/" || true)"
  assert_eq "true" "$([ "${skills:-0}" -gt 0 ] && echo true || echo false)" \
    "The sweep reaches skills/**/SKILL.md, not only commands/"

  agents="$(printf '%s\n' "$corpus" | grep -cF "$AGENTS_DIR/" || true)"
  assert_eq "true" "$([ "${agents:-0}" -gt 0 ] && echo true || echo false)" \
    "The sweep reaches agents/**/*.md, not only commands/ and skills/"

  strays="$(printf '%s\n' "$corpus" | grep -F "$SKILLS_DIR/" | grep -v '/SKILL\.md$' || true)"
  assert_no_findings "$strays" \
    "The sweep takes only SKILL.md from skills/, never the references/ prose beside it" \
    "A skills reference file has no byte budget and must not acquire one; narrow command_block_files()."
}

# ---------------------------------------------------------------------------
# check_discrimination() -- self-contained proof, against a throwaway
# mktemp -d fixture (never a real commands/ file), that check_budgets()
# actually discriminates in both ratchet directions. With ceiling=8 and
# step=4 (the real values scaled down), seven cases:
#   - unbudgeted file under the ceiling             -> no finding
#   - unbudgeted file over the ceiling               -> "over ceiling"
#   - budgeted file exactly at its budget            -> no finding
#   - budgeted file inside its step (budget-step < size < budget) -> no finding
#   - budgeted file 1 byte over its budget           -> "over budget"
#   - budgeted file that fits the step below         -> "stale budget"
#   - budget that is not a multiple of the step      -> "malformed budget"
#
# The fixture includes a references/ subdirectory so the same recursive
# coverage the real check relies on is exercised here too. Its skills and
# agents roots are passed EMPTY: the ratchet is one rule over one corpus, and
# proving it discriminates needs neither second nor third root -- the skills
# and agents halves' only distinct behaviour, their relpath prefix, is what
# check_structural_coverage() pins.
# ---------------------------------------------------------------------------
check_discrimination() {
  local fixture
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' RETURN

  mkdir -p "$fixture/dir/references"

  printf '%s' "ab"           > "$fixture/dir/plain.md"                # 2 bytes,  no budget, ceiling=8 -> under ceiling
  printf '%s' "0123456789"   > "$fixture/dir/big.md"                  # 10 bytes, no budget, ceiling=8 -> over ceiling
  printf '%s' "123456789012" > "$fixture/dir/references/exact.md"     # 12 bytes, budget=12 -> top of its step
  printf '%s' "123456789"    > "$fixture/dir/references/inside.md"    # 9 bytes,  budget=12 -> inside (8, 12]
  printf '%s' "1234567890123" > "$fixture/dir/references/over.md"     # 13 bytes, budget=12 -> 1 byte over
  printf '%s' "12345678"     > "$fixture/dir/references/stale.md"     # 8 bytes,  budget=12 -> fits (4, 8]
  printf '%s' "123456789"    > "$fixture/dir/references/malformed.md" # 9 bytes,  budget=11 -> not a multiple of 4

  cat > "$fixture/baseline.txt" <<'EOF'
# fixture baseline for the discrimination test
references/exact.md	12
references/inside.md	12
references/over.md	12
references/stale.md	12
references/malformed.md	11
EOF

  local findings
  findings="$(check_budgets "$fixture/dir" "" "" "$fixture/baseline.txt" 8 4)"

  assert_eq "false" "$(printf '%s\n' "$findings" | grep -q '^plain\.md:' && echo true || echo false)" \
    "Discrimination -- unbudgeted file under the ceiling produces no finding"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^big\.md: over ceiling' && echo true || echo false)" \
    "Discrimination -- unbudgeted file over the ceiling produces an 'over ceiling' finding"

  assert_eq "false" "$(printf '%s\n' "$findings" | grep -q '^references/exact\.md:' && echo true || echo false)" \
    "Discrimination -- file exactly at its recorded budget produces no finding"

  assert_eq "false" "$(printf '%s\n' "$findings" | grep -q '^references/inside\.md:' && echo true || echo false)" \
    "Discrimination -- file inside its budget's step produces no finding"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^references/over\.md: over budget' && echo true || echo false)" \
    "Discrimination -- file 1 byte over its recorded budget produces an 'over budget' finding (ratchet: growth fails)"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^references/stale\.md: stale budget.*remove its baseline line' && echo true || echo false)" \
    "Discrimination -- file that fits the step below produces a 'stale budget' finding (ratchet: shrinking also fails)"

  assert_eq "true" "$(printf '%s\n' "$findings" | grep -q '^references/malformed\.md: malformed budget.*set its baseline entry to 12' && echo true || echo false)" \
    "Discrimination -- a budget that is not a multiple of the step produces a 'malformed budget' finding"

  rm -rf "$fixture"
  trap - RETURN
}

main() {
  echo "Measuring commands/**/*.md and skills/**/SKILL.md against command-size-baseline.txt..."
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
