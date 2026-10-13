#!/usr/bin/env bash
set -uo pipefail

# test-spec-section-contract.sh - Ratchet guard for the Spec Section Contract
# (commands/references/spec-section-contract.md).
#
# WHY THIS EXISTS
#
# Several commands, agents and one script already parse a Claude Design
# handoff bundle's BusinessSpec.md/DesignSpec.md by section NUMBER, and that
# numbering is now written down once, in spec-section-contract.md's own
# table. Stating the contract once does not reach a maintainer who adds a
# ninth citation next month and never re-reads the table it is supposed to
# extend. This suite derives every cited section number from the tree on
# every run and refuses to be green while any derived citation is neither
# enumerated in the contract nor a reasoned exemption, so a citation can
# never silently drift from the documented numbering.
#
# WHAT IT CHECKS
#
#   1. the declared contract-path resolves to an existing file (skipped
#      against a --corpus-root fixture, which has no contract home)
#   2. every derived candidate -- one per distinct (file, citation) pair,
#      over command_block_files()'s corpus, excluding the contract file
#      itself -- has its citation string appear, as a literal substring, in
#      the contract file, or carries a baseline exemption, against the real
#      tree
#   3. every spec-section-contract-baseline.txt exempt entry carries a
#      reason, and no exempt entry is stale (see below)
#   4. (self-contained, against a throwaway fixture) the same scan_corpus()
#      used above discriminates: a citation the fixture contract does not
#      enumerate is flagged UNCOVERED, one it does enumerate is not, and an
#      exemption suppresses a finding the way it would on the real tree
#
# THE CANDIDATE PREDICATE (derived from the tree, never a hand-written list)
#
#   For every file in command_block_files()'s corpus -- commands/, agents/
#   and skills/*/SKILL.md -- grep the file's FULL TEXT (never only its bash
#   blocks: a citation lives in ordinary prose) for
#   `(BusinessSpec|DesignSpec) § [0-9]+(\.[0-9]+)?`, and take one candidate
#   per distinct (file, citation) pair. The contract file itself is excluded
#   by identity (a `-ef` comparison against the resolved contract file, never
#   a hardcoded relpath string), the same self-reference exclusion
#   spec-section-contract.md's own "Re-measuring This Contract" section
#   applies when it names itself out of its own re-derivation.
#
# COVERAGE IS A LITERAL SUBSTRING MATCH, THE SAME FIDELITY THE CONTRACT'S OWN
# RE-MEASUREMENT USES
#
#   A citation is COVERED when it appears, as a fixed string (`grep -qF`),
#   anywhere in the contract file's text -- never a structural table-row
#   parse. This is the same fidelity test-artifact-language.sh's own Form R
#   matching uses, and it carries the same known, accepted limitation: a
#   citation that happens to appear in the contract's own explanatory prose
#   (rather than its table) reads as covered. It also means a bare citation
#   is covered by a longer one that contains it as a prefix -- `DesignSpec §
#   2` is a substring of a table row citing `DesignSpec § 2.2` -- which is
#   intentional, not a gap: the contract's own table documents `§ 2.2` as the
#   numbered subsection a bare `§ 2` citation is shorthand for.
#
# THE BASELINE IS A RATCHET IN BOTH DIRECTIONS, ON PURPOSE
#
# spec-section-contract-baseline.txt's `exempt` entries follow the same
# bidirectional rule command-size-baseline.txt applies to its byte budgets:
# an entry naming a (file, citation) pair that no longer appears in that
# file, or that the contract now enumerates, fails as STALE. A baseline that
# only ever grew would let an exemption outlive the reason it was written
# for, and nothing would ever say so.
#
# WHY THE CORPUS IS THE EXTRACTOR'S, NOT A FOURTH `find`
#
# command_block_files() in lib/extract-command-blocks.sh is already shared by
# test-command-blocks.sh, test-command-size.sh, test-artifact-language.sh and
# capture-command-block-jq.sh. A fourth definition of "the files this
# analysis covers" is exactly how one suite gains a candidate the others
# never see.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$PLUGIN_DIR/commands"
SKILLS_DIR="$PLUGIN_DIR/skills"
AGENTS_DIR="$PLUGIN_DIR/agents"
BASELINE_FILE="$SCRIPT_DIR/spec-section-contract-baseline.txt"

# command_block_files() -- the corpus definition this suite shares with
# test-command-blocks.sh, test-command-size.sh and test-artifact-language.sh
# rather than restating.
# shellcheck source=lib/extract-command-blocks.sh
source "$SCRIPT_DIR/lib/extract-command-blocks.sh"

# Colour only when stdout is a terminal (see test-command-size.sh's header
# for why this is a real ESC byte in $'...' rather than a four-character
# literal, and why NO_COLOR/AIMI_TEST_COLOR both apply).
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
# Test helpers (verbatim from test-command-size.sh / test-artifact-language.sh)
# ---------------------------------------------------------------------------
assert_eq() {
  local expected="$1" actual="$2" test_name="$3"
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

assert_no_findings() {
  local findings="$1" test_name="$2" hint="$3"
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
# Argument parsing -- --contract-path / --corpus-root / --baseline let a
# caller point this suite at a throwaway fixture instead of the real tree.
# --corpus-root is what triggers fixture mode (the contract-home cross-check
# is skipped): it replaces $COMMANDS_DIR/$SKILLS_DIR/$AGENTS_DIR with
# <root>/commands, <root>/skills, <root>/agents.
# ---------------------------------------------------------------------------
CORPUS_ROOT=""
BASELINE_OVERRIDE=""
CONTRACT_PATH_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --contract-path) CONTRACT_PATH_FLAG="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --baseline) BASELINE_OVERRIDE="${2:-}"; shift 2 ;;
    *) echo "test-spec-section-contract.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

FIXTURE_MODE=0
FIXTURE_ROOT_FOR_CONTRACT="$PLUGIN_DIR"
if [ -n "$CORPUS_ROOT" ]; then
  FIXTURE_MODE=1
  COMMANDS_DIR="$CORPUS_ROOT/commands"
  SKILLS_DIR="$CORPUS_ROOT/skills"
  AGENTS_DIR="$CORPUS_ROOT/agents"
  FIXTURE_ROOT_FOR_CONTRACT="$CORPUS_ROOT"
fi
if [ -n "$BASELINE_OVERRIDE" ]; then
  BASELINE_FILE="$BASELINE_OVERRIDE"
fi

# ---------------------------------------------------------------------------
# Baseline loading. Populates EXEMPT_REASON{} (keyed "<relpath>#<citation>")
# and the contract-path default (overridable by --contract-path).
# ---------------------------------------------------------------------------
declare -A EXEMPT_REASON=()
BASELINE_CONTRACT_PATH=""

_load_baseline() {
  local file="$1" kind value reason
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r kind value reason; do
    [ -n "$kind" ] || continue
    case "$kind" in
      "contract-path") BASELINE_CONTRACT_PATH="$value" ;;
      "exempt") EXEMPT_REASON["$value"]="$reason" ;;
      *) : ;; # unknown kind -- ignored, not a fatal error
    esac
  done < <(grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null || true)
}

_load_baseline "$BASELINE_FILE"

CONTRACT_PATH="${CONTRACT_PATH_FLAG:-$BASELINE_CONTRACT_PATH}"
: "${CONTRACT_PATH:?no contract-path: pass --contract-path or declare 'contract-path' in $BASELINE_FILE}"

if [ "${CONTRACT_PATH#/}" != "$CONTRACT_PATH" ]; then
  CONTRACT_FILE="$CONTRACT_PATH"
else
  CONTRACT_FILE="$FIXTURE_ROOT_FOR_CONTRACT/$CONTRACT_PATH"
fi

_strip_reason() {
  local r="${1#\#}"
  r="${r# }"
  printf '%s' "$r"
}

# ---------------------------------------------------------------------------
# scan_corpus(commands_root, skills_root, agents_root, contract_file) -- the
# one function that walks the corpus and classifies every candidate. Emits
# one tab-separated line per CANDIDATE only (a file with no citation is
# silently skipped, same as a non-candidate in the sibling suites):
#
#   COVERED	<relpath>	<citation>
#   EXEMPTED	<relpath>	<citation>	<reason>
#   UNCOVERED	<relpath>	<citation>
#
# Both the real-tree check and the discrimination fixture call this same
# function, so the code that enforces the rule is the code that is shown to
# discriminate.
# ---------------------------------------------------------------------------
scan_corpus() {
  local commands_root="$1" skills_root="$2" agents_root="$3" contract_file="$4"
  local plugin_root=""
  if [ -n "$skills_root" ]; then
    plugin_root="$(cd "$skills_root/.." 2>/dev/null && pwd)"
  fi
  if [ -z "$plugin_root" ] && [ -n "$agents_root" ]; then
    plugin_root="$(cd "$agents_root/.." 2>/dev/null && pwd)"
  fi

  local file relp citation reason reason_stripped key
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -f "$contract_file" ] && [ "$file" -ef "$contract_file" ] 2>/dev/null && continue

    relp="$file"
    if [ -n "$commands_root" ] && [ "${file#"$commands_root"/}" != "$file" ]; then
      relp="${file#"$commands_root"/}"
    elif [ -n "$plugin_root" ] && [ "${file#"$plugin_root"/}" != "$file" ]; then
      relp="${file#"$plugin_root"/}"
    fi

    while IFS= read -r citation; do
      [ -n "$citation" ] || continue
      key="${relp}#${citation}"

      if [ -f "$contract_file" ] && grep -qF -- "$citation" "$contract_file" 2>/dev/null; then
        printf 'COVERED\t%s\t%s\n' "$relp" "$citation"
        continue
      fi

      reason="${EXEMPT_REASON[$key]:-}"
      reason_stripped="$(_strip_reason "$reason")"
      if [ -n "$reason_stripped" ]; then
        printf 'EXEMPTED\t%s\t%s\t%s\n' "$relp" "$citation" "$reason_stripped"
      else
        printf 'UNCOVERED\t%s\t%s\n' "$relp" "$citation"
      fi
    done < <(grep -oE '(BusinessSpec|DesignSpec) § [0-9]+(\.[0-9]+)?' "$file" 2>/dev/null | sort -u)
  done < <(command_block_files "$commands_root" "$skills_root" "$agents_root")
}

# ---------------------------------------------------------------------------
# check_contract_home() -- cross-checks the declared contract-path against an
# existing file. Skipped in fixture mode: a throwaway --corpus-root fixture
# has no contract home to check.
# ---------------------------------------------------------------------------
check_contract_home() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    echo "(fixture mode: --corpus-root given -- contract-home cross-check skipped, a fixture has no contract home)"
    return
  fi
  local ok="true"
  [ -f "$CONTRACT_FILE" ] || ok="false"
  assert_eq "true" "$ok" \
    "contract-path ($CONTRACT_PATH) resolves to an existing file"
}

# ---------------------------------------------------------------------------
# check_real_tree() -- runs scan_corpus() over the real (or fixture) corpus,
# prints the per-candidate census AC2 requires, and fails naming every
# UNCOVERED candidate (both the citing file and the exact citation string).
# ---------------------------------------------------------------------------
check_real_tree() {
  local report findings census count
  report="$(scan_corpus "$COMMANDS_DIR" "$SKILLS_DIR" "$AGENTS_DIR" "$CONTRACT_FILE")"
  count="$(printf '%s\n' "$report" | grep -c . || true)"

  census="$(printf '%s\n' "$report" | awk -F'\t' '
    $1=="COVERED"   { print $2": "$3": covered" }
    $1=="EXEMPTED"  { print $2": "$3": exempted -- "$4 }
    $1=="UNCOVERED" { print $2": "$3": UNCOVERED -- neither the contract nor a baseline exemption" }
  ' | sort)"

  echo "--- Candidate Census ($count candidates) ---"
  printf '%s\n' "$census"
  echo ""

  findings="$(printf '%s\n' "$report" | awk -F'\t' '$1=="UNCOVERED"{print $2": "$3}')"
  assert_no_findings "$findings" \
    "Every derived citation appears in the contract file or carries a baseline exemption" \
    "Add the citation as a row to $(basename "$CONTRACT_FILE"), or add a reasoned exemption to $(basename "$BASELINE_FILE")."
}

# ---------------------------------------------------------------------------
# check_baseline_hygiene() -- every exempt entry carries a reason, and no
# exempt entry is stale (names a citation that no longer appears in its
# file, that its file no longer exists, or that the contract now covers).
# ---------------------------------------------------------------------------
check_baseline_hygiene() {
  local findings="" key relp citation reason reason_stripped path

  for key in "${!EXEMPT_REASON[@]}"; do
    reason="${EXEMPT_REASON[$key]}"
    reason_stripped="$(_strip_reason "$reason")"
    if [ -z "$reason_stripped" ]; then
      findings="${findings}exempt '$key' has no reason -- add one"$'\n'
      continue
    fi

    relp="${key%%#*}"
    citation="${key#*#}"

    path=""
    if [ -f "$COMMANDS_DIR/$relp" ]; then
      path="$COMMANDS_DIR/$relp"
    elif [ -f "$PLUGIN_DIR/$relp" ]; then
      path="$PLUGIN_DIR/$relp"
    fi

    if [ -z "$path" ]; then
      findings="${findings}exempt '$key': file no longer exists -- remove this stale line"$'\n'
      continue
    fi

    if ! grep -qF -- "$citation" "$path" 2>/dev/null; then
      findings="${findings}exempt '$key': citation no longer appears in this file -- remove this stale exemption"$'\n'
      continue
    fi

    if [ -f "$CONTRACT_FILE" ] && grep -qF -- "$citation" "$CONTRACT_FILE" 2>/dev/null; then
      findings="${findings}exempt '$key': the contract now enumerates this citation -- remove this stale exemption"$'\n'
    fi
  done

  assert_no_findings "$findings" \
    "Baseline hygiene -- every exempt entry carries a reason, and no exempt entry is stale" \
    "See the finding above."
}

# ---------------------------------------------------------------------------
# check_discrimination() -- self-contained proof, against a throwaway
# mktemp -d fixture, that scan_corpus() discriminates as designed. Three
# cases, matching AC1's own description:
#   - a citation the fixture contract enumerates      -> covered, not flagged
#   - a citation the fixture contract does not         -> flagged UNCOVERED
#   - an exempted citation the fixture contract lacks  -> suppressed, not flagged
# Plus a fourth: a stale `exempt` entry (naming a citation the fixture
# contract in fact covers) is caught by check_baseline_hygiene's own logic.
# ---------------------------------------------------------------------------
check_discrimination() {
  local fixture
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' RETURN

  mkdir -p "$fixture/commands"

  printf 'See `BusinessSpec § 1` for the overview.\n' > "$fixture/commands/covered.md"
  printf 'See `BusinessSpec § 99` for a section nothing enumerates.\n' > "$fixture/commands/uncovered.md"
  printf 'See `DesignSpec § 42` for a section exempted on purpose.\n' > "$fixture/commands/exempted.md"
  printf 'The fixture contract.\n\n| Section | Backs |\n| --- | --- |\n| `BusinessSpec § 1` | Overview |\n' > "$fixture/contract.md"

  # Save globals scan_corpus() reads, so this fixture run cannot leak into
  # the real-tree checks that ran (or will run) around it.
  local -A saved_exempt=()
  local k
  for k in "${!EXEMPT_REASON[@]}"; do saved_exempt["$k"]="${EXEMPT_REASON[$k]}"; done

  EXEMPT_REASON=()
  EXEMPT_REASON["exempted.md#DesignSpec § 42"]="# proves an exemption suppresses a finding"

  local report findings=""
  report="$(scan_corpus "$fixture/commands" "" "" "$fixture/contract.md")"

  if ! printf '%s\n' "$report" | awk -F'\t' '$1=="COVERED" && $2=="covered.md" && $3=="BusinessSpec § 1"{found=1} END{exit !found}'; then
    findings="${findings}covered.md: expected BusinessSpec § 1 covered, was not"$'\n'
  fi
  if ! printf '%s\n' "$report" | awk -F'\t' '$1=="UNCOVERED" && $2=="uncovered.md" && $3=="BusinessSpec § 99"{found=1} END{exit !found}'; then
    findings="${findings}uncovered.md: expected BusinessSpec § 99 UNCOVERED, was not flagged"$'\n'
  fi
  if ! printf '%s\n' "$report" | awk -F'\t' '$1=="EXEMPTED" && $2=="exempted.md" && $3=="DesignSpec § 42"{found=1} END{exit !found}'; then
    findings="${findings}exempted.md: expected the exemption to suppress this finding, was flagged UNCOVERED"$'\n'
  fi

  # Fourth case: a stale exempt entry (naming a citation the fixture
  # contract in fact covers) must be caught by the same hygiene logic
  # check_baseline_hygiene runs against the real baseline.
  EXEMPT_REASON=()
  EXEMPT_REASON["covered.md#BusinessSpec § 1"]="# stale on purpose: this fixture citation is actually covered"
  local stale_findings="" key relp citation path
  for key in "${!EXEMPT_REASON[@]}"; do
    relp="${key%%#*}"
    citation="${key#*#}"
    path="$fixture/commands/$relp"
    if [ ! -f "$path" ]; then
      stale_findings="${stale_findings}$key: file missing"$'\n'
      continue
    fi
    if grep -qF -- "$citation" "$path" 2>/dev/null && grep -qF -- "$citation" "$fixture/contract.md" 2>/dev/null; then
      stale_findings="${stale_findings}$key: correctly detected as stale (now covered by the contract)"$'\n'
    fi
  done
  if [ -z "$stale_findings" ]; then
    findings="${findings}stale-exemption case: expected covered.md's exemption to be detected as stale, was not"$'\n'
  fi

  # Restore globals.
  EXEMPT_REASON=()
  for k in "${!saved_exempt[@]}"; do EXEMPT_REASON["$k"]="${saved_exempt[$k]}"; done

  assert_no_findings "$findings" \
    "Discrimination -- an unlisted citation fails, a listed one passes, an exemption suppresses a finding, and a stale exemption is caught" \
    "See the finding above."

  rm -rf "$fixture"
  trap - RETURN
}

main() {
  echo "Deriving spec-section-contract citations from the tree and checking each is covered or exempted..."
  echo ""

  echo "--- Contract Home ---"
  check_contract_home

  echo ""
  echo "--- Real Tree ---"
  check_real_tree
  check_baseline_hygiene

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

main
