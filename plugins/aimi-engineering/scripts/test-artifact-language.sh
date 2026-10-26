#!/usr/bin/env bash
set -uo pipefail

# test-artifact-language.sh - Ratchet guard for the Artifact Language Rule
# (commands/references/user-communication.md § Artifact Language Rule).
#
# WHY THIS EXISTS
#
# The rule says a plugin-owned artifact under `.aimi/` is written in
# English. Stating the rule once does not reach a new writer that forgets
# it -- a maintainer adding a seventh research agent, or a new command that
# composes a story's `notes` field, has no signal at review time that this
# rule applies at all. This suite derives the writer set from the tree on
# every run and refuses to be green while any derived candidate carries
# neither the anchor nor a reasoned exemption, so the rule reaches the next
# writer instead of the fifth one that happens to remember it.
#
# WHAT IT CHECKS
#
#   1. the declared anchor-ref resolves to an existing file, and that file
#      carries a heading matching the declared anchor-section (skipped
#      against a --corpus-root fixture, which has no rule home)
#   2. every derived candidate -- command_block_files()'s corpus, filtered
#      to files matching predicate arm (a) or arm (b) below -- carries the
#      anchor (Form R or Form S) or a baseline exemption, against the real
#      tree
#   3. every artifact-language-baseline.txt non-artifact-root and exempt
#      entry carries a reason, and no exempt entry is stale (see below)
#   4. (self-contained, against a throwaway fixture) the same scan_corpus()
#      used above discriminates: an arm-(a)-only unanchored file is
#      flagged, an arm-(b)-only unanchored file is flagged, a file whose
#      only artifact-language content is the bare word "language" in prose
#      is flagged, while a file carrying Form S alone and a file carrying
#      Form R alone are both left unflagged
#
# THE CANDIDATE PREDICATE (union of two arms, never a hand-written list)
#
#   Arm (a): the file contains a `.aimi/<root>/` (or `~/.aimi/<root>/`)
#   path literal whose <root> is not declared `non-artifact-root` in the
#   baseline. Misses a writer whose output path arrives from the caller
#   (a prototype author agent told outputPath by its caller) with no
#   `.aimi/` literal of its own.
#
#   Arm (b): the file's frontmatter `tools:` (or legacy `allowed-tools:`) line
#   names `Write`. Misses a writer with no `tools` key at all
#   (a research agent whose frontmatter is name/description/model only).
#
#   Neither arm alone is sufficient -- each misses real writers the other
#   catches -- so the candidate set is their union, and check_discrimination
#   below proves both arms are load-bearing rather than assumed to be.
#
# THE TWO ANCHOR FORMS, AND WHY NEITHER ALONE IS ADMITTED
#
#   Form R (reference): the file contains the declared anchor-ref path
#   literal. Works for any writer free to open a reference file at run
#   time.
#
#   Form S (statement): the file contains a markdown heading, at any
#   level, whose text is EXACTLY the declared anchor-section literal --
#   matched as a whole line (`^#{1,6}[[:space:]]*<section>[[:space:]]*$`),
#   never a substring. Some writers are told, by their own "what you do
#   NOT do" section, that they may not open an arbitrary reference file at
#   run time -- for those, the rule must be stated inline.
#
#   Matching is against these two DECLARED LITERALS only, never against the
#   bare word "language": measured before this suite existed, several
#   genuine candidates already contain that word in ordinary prose (a
#   sentence about keeping "the same language throughout" a document), and
#   a word-level match would report them anchored for the wrong reason,
#   on the day this ratchet first runs, over exactly the files most likely
#   to need it. check_discrimination's word-only case exists to keep this
#   from regressing silently.
#
# THE BASELINE IS A RATCHET IN BOTH DIRECTIONS, ON PURPOSE
#
# artifact-language-baseline.txt's `exempt` entries follow the same
# bidirectional rule command-size-baseline.txt applies to its byte
# budgets: an entry naming a file that no longer matches the candidate
# predicate, or that now carries the anchor, fails as STALE. A baseline
# that only ever grew would let an exemption outlive the reason it was
# written for, and nothing would ever say so.
#
# WHY THE CORPUS IS THE EXTRACTOR'S, NOT A FOURTH `find`
#
# command_block_files() in lib/extract-command-blocks.sh is already shared
# by test-command-blocks.sh, test-command-size.sh and
# capture-command-block-jq.sh. A fourth definition of "the files this
# analysis covers" is exactly how one suite gains a candidate the others
# never see.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$PLUGIN_DIR/commands"
SKILLS_DIR="$PLUGIN_DIR/skills"
AGENTS_DIR="$PLUGIN_DIR/agents"
BASELINE_FILE="$SCRIPT_DIR/artifact-language-baseline.txt"

# command_block_files() -- the corpus definition this suite shares with
# test-command-blocks.sh and test-command-size.sh rather than restating.
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
# Test helpers (verbatim from test-command-size.sh / test-command-blocks.sh)
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
# Argument parsing -- --anchor-ref / --anchor-section / --corpus-root /
# --baseline let a caller point this suite at a throwaway fixture instead
# of the real tree. --corpus-root is what triggers fixture mode (the
# rule-home cross-check is skipped): it replaces $COMMANDS_DIR/$SKILLS_DIR/
# $AGENTS_DIR with <root>/commands, <root>/skills, <root>/agents.
# ---------------------------------------------------------------------------
CORPUS_ROOT=""
BASELINE_OVERRIDE=""
ANCHOR_REF_FLAG=""
ANCHOR_SECTION_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --anchor-ref) ANCHOR_REF_FLAG="${2:-}"; shift 2 ;;
    --anchor-section) ANCHOR_SECTION_FLAG="${2:-}"; shift 2 ;;
    --corpus-root) CORPUS_ROOT="${2:-}"; shift 2 ;;
    --baseline) BASELINE_OVERRIDE="${2:-}"; shift 2 ;;
    *) echo "test-artifact-language.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

FIXTURE_MODE=0
if [ -n "$CORPUS_ROOT" ]; then
  FIXTURE_MODE=1
  COMMANDS_DIR="$CORPUS_ROOT/commands"
  SKILLS_DIR="$CORPUS_ROOT/skills"
  AGENTS_DIR="$CORPUS_ROOT/agents"
fi
if [ -n "$BASELINE_OVERRIDE" ]; then
  BASELINE_FILE="$BASELINE_OVERRIDE"
fi

# ---------------------------------------------------------------------------
# Baseline loading. Populates NON_ARTIFACT_ROOTS[]/NON_ARTIFACT_ROOT_REASON{},
# EXEMPT_REASON{}, and the anchor-ref/anchor-section defaults (overridable
# by the flags above).
# ---------------------------------------------------------------------------
declare -a NON_ARTIFACT_ROOTS=()
declare -A NON_ARTIFACT_ROOT_REASON=()
declare -A EXEMPT_REASON=()
BASELINE_ANCHOR_REF=""
BASELINE_ANCHOR_SECTION=""

_load_baseline() {
  local file="$1" kind value reason
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r kind value reason; do
    [ -n "$kind" ] || continue
    case "$kind" in
      "anchor-ref") BASELINE_ANCHOR_REF="$value" ;;
      "anchor-section") BASELINE_ANCHOR_SECTION="$value" ;;
      "non-artifact-root")
        NON_ARTIFACT_ROOTS+=("$value")
        NON_ARTIFACT_ROOT_REASON["$value"]="$reason"
        ;;
      "exempt")
        EXEMPT_REASON["$value"]="$reason"
        ;;
      *) : ;; # unknown kind -- ignored, not a fatal error
    esac
  done < <(grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null || true)
}

_load_baseline "$BASELINE_FILE"

ANCHOR_REF="${ANCHOR_REF_FLAG:-$BASELINE_ANCHOR_REF}"
ANCHOR_SECTION="${ANCHOR_SECTION_FLAG:-$BASELINE_ANCHOR_SECTION}"
: "${ANCHOR_REF:?no anchor-ref: pass --anchor-ref or declare 'anchor-ref' in $BASELINE_FILE}"
: "${ANCHOR_SECTION:?no anchor-section: pass --anchor-section or declare 'anchor-section' in $BASELINE_FILE}"

# ERE-escape a literal for safe use inside grep -E. Wide enough for the
# metacharacters that matter here; the two literals this suite ships with
# contain none of them.
_re_escape() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|}]/\\&/g'
}
ANCHOR_SECTION_RE="$(_re_escape "$ANCHOR_SECTION")"

_strip_reason() {
  local r="${1#\#}"
  r="${r# }"
  printf '%s' "$r"
}

# ---------------------------------------------------------------------------
# Predicate arm (a): a `.aimi/<root>/` path literal whose root is not
# declared non-artifact.
# ---------------------------------------------------------------------------
_non_artifact_root() {
  local root="$1" r
  for r in "${NON_ARTIFACT_ROOTS[@]}"; do
    [ "$r" = "$root" ] && return 0
  done
  return 1
}

_is_arm_a() {
  local file="$1" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    _non_artifact_root "$root" || return 0
  done < <(grep -oE '\.aimi/[a-z-]+/' "$file" 2>/dev/null | sed -E 's#\.aimi/([a-z-]+)/#\1#' | sort -u)
  return 1
}

# ---------------------------------------------------------------------------
# Predicate arm (b): frontmatter `tools:` (or legacy `allowed-tools:`) names `Write`.
# ---------------------------------------------------------------------------
_frontmatter() {
  awk 'NR==1{if($0!="---"){exit}; infm=1; next} infm && /^---[[:space:]]*$/{exit} infm{print}' "$1" 2>/dev/null
}

_is_arm_b() {
  _frontmatter "$1" | grep -E '^(allowed-tools|tools):' | grep -qw 'Write'
}

# ---------------------------------------------------------------------------
# Anchor detection: Form R (path literal) or Form S (whole-line heading
# matching the declared section, never a substring).
# ---------------------------------------------------------------------------
_anchor_form() {
  local file="$1" r=0 s=0
  grep -qF -- "$ANCHOR_REF" "$file" 2>/dev/null && r=1
  grep -qE "^#{1,6}[[:space:]]*${ANCHOR_SECTION_RE}[[:space:]]*\$" "$file" 2>/dev/null && s=1
  if [ "$r" = 1 ] && [ "$s" = 1 ]; then echo "R+S"
  elif [ "$r" = 1 ]; then echo "R"
  elif [ "$s" = 1 ]; then echo "S"
  fi
}

# ---------------------------------------------------------------------------
# scan_corpus(commands_root, skills_root, agents_root) -- the one function
# that walks the corpus and classifies every candidate. Emits one
# tab-separated line per CANDIDATE only (a non-candidate is silently
# skipped, same as check_budgets skips a file with nothing to report):
#
#   ANCHORED	<relpath>	<form>
#   EXEMPTED	<relpath>	<reason>
#   UNANCHORED	<relpath>	arm_a=<0|1> arm_b=<0|1>
#
# Both the real-tree check and the discrimination fixture call this same
# function, so the code that enforces the rule is the code that is shown
# to discriminate.
# ---------------------------------------------------------------------------
scan_corpus() {
  local commands_root="$1" skills_root="$2" agents_root="$3"
  local plugin_root=""
  if [ -n "$skills_root" ]; then
    plugin_root="$(cd "$skills_root/.." 2>/dev/null && pwd)"
  fi
  if [ -z "$plugin_root" ] && [ -n "$agents_root" ]; then
    plugin_root="$(cd "$agents_root/.." 2>/dev/null && pwd)"
  fi

  local file relp arm_a arm_b form reason reason_stripped
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    relp="$file"
    if [ -n "$commands_root" ] && [ "${file#"$commands_root"/}" != "$file" ]; then
      relp="${file#"$commands_root"/}"
    elif [ -n "$plugin_root" ] && [ "${file#"$plugin_root"/}" != "$file" ]; then
      relp="${file#"$plugin_root"/}"
    fi

    arm_a=0; arm_b=0
    _is_arm_a "$file" && arm_a=1
    _is_arm_b "$file" && arm_b=1
    [ "$arm_a" = 1 ] || [ "$arm_b" = 1 ] || continue

    form="$(_anchor_form "$file")"
    if [ -n "$form" ]; then
      printf 'ANCHORED\t%s\t%s\n' "$relp" "$form"
      continue
    fi

    reason="${EXEMPT_REASON[$relp]:-}"
    reason_stripped="$(_strip_reason "$reason")"
    if [ -n "$reason_stripped" ]; then
      printf 'EXEMPTED\t%s\t%s\n' "$relp" "$reason_stripped"
    else
      printf 'UNANCHORED\t%s\tarm_a=%s arm_b=%s\n' "$relp" "$arm_a" "$arm_b"
    fi
  done < <(command_block_files "$commands_root" "$skills_root" "$agents_root")
}

# ---------------------------------------------------------------------------
# check_rule_home() -- cross-checks the declared anchor-ref/anchor-section
# against the rule's own home file. Skipped in fixture mode: a throwaway
# --corpus-root fixture has no rule home to check.
# ---------------------------------------------------------------------------
check_rule_home() {
  if [ "$FIXTURE_MODE" = "1" ]; then
    echo "(fixture mode: --corpus-root given -- rule-home cross-check skipped, a fixture has no rule home)"
    return
  fi
  local home="$PLUGIN_DIR/$ANCHOR_REF" ok="true"
  if [ ! -f "$home" ]; then
    ok="false"
  elif ! grep -qE "^#{1,6}[[:space:]]*${ANCHOR_SECTION_RE}[[:space:]]*\$" "$home"; then
    ok="false"
  fi
  assert_eq "true" "$ok" \
    "anchor-ref ($ANCHOR_REF) resolves to a file carrying a heading matching anchor-section ('$ANCHOR_SECTION')"
}

# ---------------------------------------------------------------------------
# check_real_tree() -- runs scan_corpus() over the real (or fixture) corpus,
# prints the per-candidate census AC1 requires, and fails naming every
# UNANCHORED candidate.
# ---------------------------------------------------------------------------
check_real_tree() {
  local report findings census count
  report="$(scan_corpus "$COMMANDS_DIR" "$SKILLS_DIR" "$AGENTS_DIR")"
  count="$(printf '%s\n' "$report" | grep -c . || true)"

  census="$(printf '%s\n' "$report" | awk -F'\t' '
    $1=="ANCHORED"  { print $2": anchored (Form "$3")" }
    $1=="EXEMPTED"  { print $2": exempted -- "$3 }
    $1=="UNANCHORED"{ print $2": UNANCHORED -- neither the anchor nor a baseline exemption ("$3")" }
  ' | sort)"

  echo "--- Candidate Census ($count candidates) ---"
  printf '%s\n' "$census"
  echo ""

  findings="$(printf '%s\n' "$report" | awk -F'\t' '$1=="UNANCHORED"{print $2": neither the anchor nor a baseline exemption -- "$3}')"
  assert_no_findings "$findings" \
    "Every derived candidate carries the artifact-language anchor (Form R or Form S) or a baseline exemption" \
    "Anchor the rule (cite $ANCHOR_REF, or state the '$ANCHOR_SECTION' heading verbatim) or add a reasoned exemption to $(basename "$BASELINE_FILE")."
}

# ---------------------------------------------------------------------------
# check_baseline_hygiene() -- every non-artifact-root and exempt entry
# carries a reason, and no exempt entry is stale (names a file that no
# longer matches the predicate, no longer exists, or now carries the
# anchor).
# ---------------------------------------------------------------------------
check_baseline_hygiene() {
  local findings="" root relp reason reason_stripped path form

  for root in "${NON_ARTIFACT_ROOTS[@]}"; do
    reason_stripped="$(_strip_reason "${NON_ARTIFACT_ROOT_REASON[$root]:-}")"
    [ -n "$reason_stripped" ] || findings="${findings}non-artifact-root '$root' has no reason -- add one"$'\n'
  done

  for relp in "${!EXEMPT_REASON[@]}"; do
    reason="${EXEMPT_REASON[$relp]}"
    reason_stripped="$(_strip_reason "$reason")"
    if [ -z "$reason_stripped" ]; then
      findings="${findings}exempt '$relp' has no reason -- add one"$'\n'
      continue
    fi

    path=""
    if [ -f "$COMMANDS_DIR/$relp" ]; then
      path="$COMMANDS_DIR/$relp"
    elif [ -f "$PLUGIN_DIR/$relp" ]; then
      path="$PLUGIN_DIR/$relp"
    fi

    if [ -z "$path" ]; then
      findings="${findings}exempt '$relp': file no longer exists -- remove this stale line"$'\n'
      continue
    fi

    if ! { _is_arm_a "$path" || _is_arm_b "$path"; }; then
      findings="${findings}exempt '$relp': no longer matches the candidate predicate -- remove this stale exemption"$'\n'
      continue
    fi

    form="$(_anchor_form "$path")"
    if [ -n "$form" ]; then
      findings="${findings}exempt '$relp': now carries the anchor (Form $form) -- remove this stale exemption"$'\n'
    fi
  done

  assert_no_findings "$findings" \
    "Baseline hygiene -- every non-artifact-root/exempt entry carries a reason, and no exempt entry is stale" \
    "See the finding above."
}

# ---------------------------------------------------------------------------
# check_discrimination() -- self-contained proof, against a throwaway
# mktemp -d fixture, that scan_corpus() discriminates as designed. Five
# cases, matching the ones this suite's own header documents:
#   - arm-(a)-only, unanchored          -> flagged
#   - arm-(b)-only, unanchored          -> flagged
#   - word-only ("language" in prose)   -> flagged
#   - Form S alone                      -> not flagged
#   - Form R alone                      -> not flagged
# Plus a sixth: an `exempt` entry correctly suppresses a finding, and a
# stale `exempt` entry (naming a now-anchored file) is caught by
# check_baseline_hygiene's own logic.
# ---------------------------------------------------------------------------
check_discrimination() {
  local fixture
  fixture="$(mktemp -d)"
  trap 'rm -rf "$fixture"' RETURN

  mkdir -p "$fixture/commands" "$fixture/agents"

  printf 'Write to `.aimi/research/a.md`.\n' > "$fixture/commands/arm-a-only.md"
  printf -- '---\nname: x\ntools: Read, Write\n---\n\nAuthor and save.\n' > "$fixture/agents/arm-b-only.md"
  printf 'Write to `.aimi/research/w.md`. Keep the language the same language throughout.\n' > "$fixture/commands/word-only.md"
  printf 'Write to `.aimi/research/s.md`.\n\n## Test Anchor Section\n\nStated inline.\n' > "$fixture/commands/form-s.md"
  printf 'Write to `.aimi/research/r.md`. See test/home.md for the rule.\n' > "$fixture/commands/form-r.md"
  printf 'Write to `.aimi/research/e.md`. Exempted on purpose.\n' > "$fixture/commands/exempted.md"

  # Save globals scan_corpus() reads, so this fixture run cannot leak into
  # the real-tree checks that ran (or will run) around it.
  local saved_roots=("${NON_ARTIFACT_ROOTS[@]}")
  local -A saved_exempt=()
  local k
  for k in "${!EXEMPT_REASON[@]}"; do saved_exempt["$k"]="${EXEMPT_REASON[$k]}"; done
  local saved_ref="$ANCHOR_REF" saved_section="$ANCHOR_SECTION" saved_section_re="$ANCHOR_SECTION_RE"

  NON_ARTIFACT_ROOTS=()
  EXEMPT_REASON=()
  EXEMPT_REASON["exempted.md"]="# proves an exemption suppresses a finding"
  ANCHOR_REF="test/home.md"
  ANCHOR_SECTION="Test Anchor Section"
  ANCHOR_SECTION_RE="$(_re_escape "$ANCHOR_SECTION")"

  local report findings=""
  report="$(scan_corpus "$fixture/commands" "" "$fixture/agents")"

  local f
  for f in arm-a-only.md agents/arm-b-only.md word-only.md; do
    printf '%s\n' "$report" | awk -F'\t' -v f="$f" '$1=="UNANCHORED" && $2==f{found=1} END{exit !found}' \
      || findings="${findings}$f: expected UNANCHORED, was not flagged"$'\n'
  done
  for f in form-s.md form-r.md; do
    if printf '%s\n' "$report" | awk -F'\t' -v f="$f" '$1=="UNANCHORED" && $2==f{found=1} END{exit !found}'; then
      findings="${findings}$f: expected anchored (Form S / Form R alone), was flagged UNANCHORED"$'\n'
    fi
  done
  if printf '%s\n' "$report" | awk -F'\t' -v f="exempted.md" '$1=="UNANCHORED" && $2==f{found=1} END{exit !found}'; then
    findings="${findings}exempted.md: expected the exemption to suppress this finding, was flagged UNANCHORED"$'\n'
  fi

  # Sixth case: a stale exempt entry (naming a file that in fact carries
  # the anchor) must be caught by the same hygiene logic check_baseline_hygiene
  # runs against the real baseline.
  EXEMPT_REASON=()
  EXEMPT_REASON["form-r.md"]="# stale on purpose: this fixture file is actually anchored"
  local stale_findings="" relp reason_stripped path form
  for relp in "${!EXEMPT_REASON[@]}"; do
    reason_stripped="$(_strip_reason "${EXEMPT_REASON[$relp]}")"
    path="$fixture/commands/$relp"
    [ -f "$path" ] || { stale_findings="${stale_findings}$relp missing"$'\n'; continue; }
    form="$(_anchor_form "$path")"
    [ -n "$form" ] && stale_findings="${stale_findings}$relp: correctly detected as stale (now carries Form $form)"$'\n'
  done
  if [ -z "$stale_findings" ]; then
    findings="${findings}stale-exemption case: expected form-r.md's exemption to be detected as stale, was not"$'\n'
  fi

  # Restore globals.
  NON_ARTIFACT_ROOTS=("${saved_roots[@]}")
  EXEMPT_REASON=()
  for k in "${!saved_exempt[@]}"; do EXEMPT_REASON["$k"]="${saved_exempt[$k]}"; done
  ANCHOR_REF="$saved_ref"
  ANCHOR_SECTION="$saved_section"
  ANCHOR_SECTION_RE="$saved_section_re"

  assert_no_findings "$findings" \
    "Discrimination -- unanchored arm(a)/arm(b)/word-only fail; Form S alone and Form R alone pass; an exemption suppresses a finding; a stale exemption is caught" \
    "See the finding above."

  rm -rf "$fixture"
  trap - RETURN
}

main() {
  echo "Deriving artifact-language candidates from the tree and checking each is anchored or exempted..."
  echo ""

  echo "--- Rule Home ---"
  check_rule_home

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
