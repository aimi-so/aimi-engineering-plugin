#!/usr/bin/env bash
set -uo pipefail

# test-command-blocks.sh - Static checker for the executable prose in commands/
#
# WHY THIS EXISTS
#
# commands/*.md are not documentation. An agent reads them and executes their
# ```bash blocks literally, each in its own isolated shell. The other two
# suites (test-aimi-cli.sh, test-worktree-manager.sh) exercise shell scripts
# and cannot reach these files at all. Three stories on fix/split-by-project
# changed only command prose and all three shipped runtime bugs — a loop that
# was written as prose instead of code, a `mapfile` that dies outside bash, and
# a variable assigned only in an English sentence. Reviewers found them by
# extracting the blocks and running them. Nothing in this repo would have.
#
# WHAT IT CHECKS  (see each check_* function for its measured yield)
#
#   1. bash -n on every extracted block
#   2. portability denylist (blocks may run under zsh, not just bash)
#   3. loop-scope escape — assigned only inside a loop, read at loop depth 0
#   4. read but never assigned anywhere in the same file
#   5. $ARGUMENTS validated in the same block that interpolates it
#   6. execute.md's phase-branch derivation, EXECUTED against fixtures
#   7. execute.md's verification_failed re-verify branch, structurally
#   8. plan.md's branchName derivations use the dot-slugified phase id
#   9. the forge-account picker records ONLY from a human answer, never in
#      agent mode
#  10. the phase-completion publish gate: execute.md asks before the phase
#      branch reaches origin, fails closed, and names /aimi:open-pr on decline
#  11. the flat-container push confirmation lives in the command body, and
#      container-execution.md's agent branch publishes nothing
#  12. --push is removed loudly: gone from the argument-hint, PUSH_FLAG gone
#      from commands/, every surviving literal inside the refusal branch
#  13. no completion report in execute.md or next.md recommends a raw
#      `gh pr create`, and next.md publishes nothing at all
#  14. no picker markup survives under commands/references/
#
# Checks 1-5 are static. Check 6 is the first one that RUNS a block: it pulls
# execute.md's phase-branch derivation out of the extracted set and executes it
# against known inputs, asserting the exact branch name it produces. A static
# check could not have caught the defect it guards — the block always parsed,
# was always portable, and read nothing unassigned; it simply produced a value
# the very next paragraph rejects.
#
# ADDRESSING
#
# Blocks are addressed by their enclosing markdown heading, never by a marker
# inside the file. install.sh's translate_command_body() rewrites command
# bodies for OpenCode by pure string substitution and never parses fences, so
# any annotation added to a fence info-string or an HTML comment would flow
# verbatim into the installed OpenCode command files.
#
# HONEST LIMIT — READ THIS BEFORE TRUSTING A GREEN RUN
#
# No static check can see a variable that a *prose sentence* reads. One of the
# reviewed defects had `HAS_VISUAL_STORY` assigned inside a loop and consumed
# by an English instruction telling the agent what to do with it; no block ever
# reads it, so no block-level analysis can find it. Prose-to-prose data flow is
# unanalyzable in principle, and this suite is silent on it by construction.
# A green run means "the bash that is written down is internally consistent",
# not "this command works". The durable mitigation for that class is moving
# logic out of the prose and into aimi-cli.sh, where the other suite can reach
# it — not adding more linting to the prose.
#
# Checks 10-14 sit squarely inside that limit and say so at their own section
# header: they pin the confirm-before-publishing contract TEXTUALLY — the
# question is written above the push, the gate normalizes to "publish nothing",
# the removed flag fails loudly — and none of them can execute a gate and
# observe a refusal. Read that block before quoting a green run as evidence
# that anything asked before it published.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$SCRIPT_DIR/../commands"
BASELINE_FILE="$SCRIPT_DIR/command-blocks-baseline.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

WORK_DIR="$(mktemp -d)"
BLOCKS_DIR="$WORK_DIR/blocks"
INDEX="$WORK_DIR/index.tsv"     # id \t relpath \t startline \t heading
EVENTS="$WORK_DIR/events.tsv"   # A|R \t var \t loopdepth \t blockline \t id

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# Process-environment names. These are read by design and assigned by the host,
# never by the prose, so check 4 would otherwise report every one of them in
# every file that resolves the CLI path. Repo-owned variables are NOT listed
# here — those belong in the baseline, where they stay visible.
ENV_ALLOWLIST='^(HOME|PWD|PPID|USER|PATH|SHELL|TMPDIR|TMP|IFS|RANDOM|OSTYPE|HOSTNAME|UID|EUID|TERM|EDITOR|LANG|LC_ALL|ARGUMENTS|CLAUDECODE|CLAUDE_CONFIG_DIR|CLAUDE_PLUGIN_ROOT|CLAUDE_SESSION_ID|XDG_CONFIG_HOME|AIMI_CONFIG_DIR|AIMI_PLUGIN_DIR|OPENCODE_CONFIG_DIR)$'

# ---------------------------------------------------------------------------
# Test helpers (verbatim from test-aimi-cli.sh)
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
# Baseline
#
# Format, one finding per line, tab-separated:
#   <check> \t <relative command path> \t <key>
# where <check> is syntax|portability|loop-scope|unassigned and <key> is the
# enclosing heading (syntax, portability) or the variable name (loop-scope,
# unassigned). Lines starting with # and blank lines are ignored.
# ---------------------------------------------------------------------------
BASELINE_KEYS=""

load_baseline() {
  [ -f "$BASELINE_FILE" ] || return 0
  BASELINE_KEYS="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE_FILE" || true)"
}

is_baselined() { case $'\n'"$BASELINE_KEYS"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# Findings arrive as "<key>\t<human readable location>"; emit only the ones the
# baseline does not already know about, and record which baseline lines matched.
MATCHED_BASELINE="$WORK_DIR/matched.txt"

filter_baseline() {
  local check="$1" line file item rest key
  while IFS=$'\t' read -r file item rest; do
    [ -n "$file" ] || continue
    key="$check	$file	$item"
    if is_baselined "$key"; then
      printf '%s\n' "$key" >> "$MATCHED_BASELINE"
    else
      printf '%s\n' "$rest"
    fi
  done
}

# ---------------------------------------------------------------------------
# Extraction
#
# A closing fence must carry no info string (CommonMark) and must not be
# indented deeper than its opener. Both rules are load-bearing here: execute.md
# nests ```bash fences inside a plain pseudo-code fence, and a naive open/close
# toggle desynchronises there and starts extracting pseudo-code as bash.
# ---------------------------------------------------------------------------
extract_blocks() {
  mkdir -p "$BLOCKS_DIR"
  cat > "$WORK_DIR/extract.awk" <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
BEGIN { nblk = 0 }
FNR == 1 {
  infence = 0; isbash = 0; heading = "(preamble)"; delete hseen
  rel = FILENAME; sub(ROOT "/", "", rel)
}
{
  probe = $0; sub(/^[ \t]+/, "", probe)
  if (probe ~ /^```/) {
    ind = match($0, /[^ \t]/) - 1
    info = probe; sub(/^`+/, "", info); info = trim(info)
    if (infence == 0) {
      infence = 1; openind = ind; isbash = (info == "bash")
      if (isbash) {
        nblk++; id = sprintf("%04d", nblk); hseen[heading]++
        outf = OUTDIR "/" id ".sh"
        printf "%s\t%s\t%d\t%s (block %d)\n", id, rel, FNR + 1, heading, hseen[heading]
        printf "" > outf
      }
      next
    }
    if (info == "" && ind <= openind) {
      infence = 0; if (isbash) close(outf); isbash = 0; next
    }
  }
  if (infence == 1) { if (isbash) print $0 >> outf; next }
  if (probe ~ /^#{1,6}[ \t]/) { h = probe; sub(/^#+[ \t]*/, "", h); heading = trim(h) }
}
END { if (infence == 1) printf "warning: unclosed fence in %s\n", rel > "/dev/stderr" }
AWK

  # shellcheck disable=SC2046
  awk -v OUTDIR="$BLOCKS_DIR" -v ROOT="$COMMANDS_DIR" -f "$WORK_DIR/extract.awk" \
    $(find "$COMMANDS_DIR" -name '*.md' | sort) > "$INDEX"
}


# ---------------------------------------------------------------------------
# Variable event scan
#
# Reads are found with a character walk rather than a regex so that $refs
# inside single-quoted jq programs, awk scripts and sed expressions are not
# mistaken for shell expansions — they are not expansions, and counting them
# added 15 false positives to check 4 before this was fixed.
#
# Loop depth is tracked by the `do`/`done` word tokens. A `for NAME in` head
# and a `read NAME` inside a while/until head are recorded at depth+1: both
# bind a name that only exists for the duration of the loop body.
# ---------------------------------------------------------------------------
scan_blocks() {
  cat > "$WORK_DIR/scan.awk" <<'AWK'
function isname(t) { return t ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }
function emit(kind, v, d) { print kind "\t" v "\t" d "\t" FNR "\t" id }
function reads(line,   i, ch, nx, q, L, v) {
  L = length(line); q = 0
  for (i = 1; i <= L; i++) {
    ch = substr(line, i, 1)
    if (q == 1) { if (ch == "'") q = 0; continue }
    if (ch == "\\") { i++; continue }
    if (q == 2) { if (ch == "\"") q = 0 }
    else if (ch == "'") { q = 1; continue }
    else if (ch == "\"") { q = 2; continue }
    if (ch != "$") continue
    nx = substr(line, i + 1)
    if (nx ~ /^'/) {                     # $'...' ANSI-C quoting: skip whole
      i++
      for (i = i + 1; i <= L; i++) {
        ch = substr(line, i, 1)
        if (ch == "\\") { i++; continue }
        if (ch == "'") break
      }
      continue
    }
    if (match(nx, /^\{?[#!]?[A-Za-z_][A-Za-z0-9_]*/) == 0) continue
    v = substr(nx, 1, RLENGTH); sub(/^\{?[#!]?/, "", v); i += RLENGTH
    if (v != "_") emit("R", v, depth)
  }
}
FNR == 1 { depth = 0; id = FILENAME; sub(/.*\//, "", id); sub(/\.sh$/, "", id) }
{
  reads($0)
  c = $0; sub(/(^|[ \t])#.*$/, "", c); gsub(/[;()&|{}]/, " ", c)
  n = split(c, T, /[ \t]+/)
  inloophdr = 0
  for (i = 1; i <= n; i++) {
    t = T[i]
    if (t == "while" || t == "until" || t == "for") inloophdr = 1
    if (t == "do")   { depth++; continue }
    if (t == "done") { if (depth > 0) depth--; continue }
    if (t == "for" && (i + 1) <= n && isname(T[i+1])) { emit("A", T[i+1], depth + 1); continue }
    if (t == "read") {
      d = inloophdr ? depth + 1 : depth
      for (j = i + 1; j <= n; j++) {
        u = T[j]
        if (u ~ /^-/) { if (u ~ /^-[dnNtupia]$/) j++; continue }
        if (u == "" || u == "do" || u == "then" || u ~ /^[<>]/) break
        if (!isname(u)) break
        emit("A", u, d)
      }
      continue
    }
    if (t == "printf") {
      for (j = i + 1; j <= n; j++) if (T[j] == "-v" && isname(T[j+1])) { emit("A", T[j+1], depth); break }
    }
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=/) { v = t; sub(/\+?=.*$/, "", v); emit("A", v, depth) }
  }
}
AWK
  # shellcheck disable=SC2046
  awk -f "$WORK_DIR/scan.awk" $(find "$BLOCKS_DIR" -name '*.sh' | sort) > "$EVENTS"
}

# ---------------------------------------------------------------------------
# Check 1 — bash -n on every block.
#
# Measured yield on the tree this was written against: 4 hits, all of them
# pre-existing prose conventions rather than defects (three blocks use
# <angle-bracket> placeholders, which bash parses as redirections; one bash
# block contains a heredoc that itself contains ``` fences, so extraction
# truncates it). All four are baselined, so this check reports nothing new
# today and is NOT coverage — it is a floor. Verified to be a live one: adding
# an unterminated `if` to a block does fail it.
#
# Note the [BRACKET] placeholder convention is *not* a problem here, and needs
# no special-casing anywhere in this file: brackets are not $-prefixed so the
# variable scan ignores them, bash -n parses them as ordinary words, and where
# one stands in for a value it is syntactically an assignment. Verified by
# measurement, not assumed. <angle> placeholders are the ones that break.
# ---------------------------------------------------------------------------
check_syntax() {
  local findings id rel start heading err
  findings="$(
    while IFS=$'\t' read -r id rel start heading; do
      # 2>file rather than "$(... 2>&1)" — one fork per block instead of two,
      # and the message is only read for the handful that actually fail.
      bash -n "$BLOCKS_DIR/$id.sh" 2>"$WORK_DIR/syntax.err" && continue
      # Drop bash's "<tmpfile>: line N: " prefix — the heading already addresses it.
      err="$(sed -e "s|$BLOCKS_DIR/[0-9]*\.sh: ||g" "$WORK_DIR/syntax.err" | tail -1)"
      printf '%s\t%s\t%s:%s (%s) -- %s\n' "$rel" "$heading" "$rel" "$start" "$heading" "$err"
    done < "$INDEX" | filter_baseline syntax
  )"
  assert_no_findings "$findings" \
    "Check 1 — every bash-fenced block parses (bash -n)" \
    "Block does not parse. Fix it, or add a 'syntax' line to $(basename "$BASELINE_FILE")."
}

# ---------------------------------------------------------------------------
# Check 2 — portability denylist.
#
# Measured yield: 1 hit on the pre-fix tree (the `mapfile` in execute.md's
# phase-split merge), 0 on the fixed tree, 0 false positives on either.
#
# This is the check with the sharpest real-world payoff. Command blocks are
# executed by whatever shell the session runs, which is not necessarily bash —
# the session that shipped the mapfile bug ran zsh. Worse, the arity guard
# immediately below that mapfile turned the failure into a silent no-op, so
# the phase-split merge was skipped with no error at all.
# ---------------------------------------------------------------------------
DENYLIST='mapfile|readarray|shopt|declare[[:space:]]+-A|typeset|compgen|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^|\$\{[A-Za-z_][A-Za-z0-9_]*,,|BASH_REMATCH'

check_portability() {
  local findings
  # One grep over every block at once (-H for the id), then join with the index
  # for the source file, absolute line and heading.
  findings="$(
    grep -HnE "$DENYLIST" "$BLOCKS_DIR"/*.sh 2>/dev/null \
      | sed -e "s|^$BLOCKS_DIR/||" -e 's|\.sh:|\t|' -e 's|:|\t|' \
      | awk -F'\t' -v OFS='\t' '
          NR == FNR { rel[$1] = $2; s[$1] = $3; h[$1] = $4; next }
          {
            hit = $3; sub(/^[[:space:]]+/, "", hit)
            printf "%s\t%s\t%s:%s (%s) -- %s\n", rel[$1], h[$1], rel[$1], ($2 + s[$1] - 1), h[$1], hit
          }
        ' "$INDEX" - \
      | sort | filter_baseline portability
  )"
  assert_no_findings "$findings" \
    "Check 2 — no bash-only constructs (blocks may run under zsh)" \
    "Use the portable pattern the other loops in these files already use."
}

# ---------------------------------------------------------------------------
# Check 3 — loop-scope escape.
#
# A variable whose every assignment sits inside a while/for body, but which is
# read at loop depth 0. Scope is the whole file, because cross-block carry is
# this repo's documented norm and the defect is precisely a block that consumes
# a loop's variable without being a loop.
#
# Measured yield: 1 hit on the pre-fix tree (`split_file` at execute.md:418 —
# blocking finding B3, the "the loop is prose, not code" bug), 0 false
# positives. On the fixed tree it finds 2 more of the same shape — see the
# loop-scope section of the baseline; those are suspected live defects, listed
# so the check can be enforcing today rather than accepted as noise.
#
# This check is self-reinforcing: once a block becomes a real loop its outputs
# become loop-scoped too, so downstream loop-less consumers start failing as
# well. plan.md's PROJECT_PATH moved from check 4 to check 3 for exactly that
# reason when the Phase 3e validation loop was added above it.
# ---------------------------------------------------------------------------
check_loop_scope() {
  local findings
  findings="$(
    awk -F'\t' '
      NR == FNR { f[$1] = $2; s[$1] = $3; h[$1] = $4; next }
      {
        file = f[$5]; var = $2; d = $3 + 0; line = $4 + s[$5] - 1
        if ($1 == "A") { seen[file SUBSEP var] = 1; if (d == 0) shallow[file SUBSEP var] = 1 }
        else if (d == 0 && !((file SUBSEP var) in firstread)) {
          firstread[file SUBSEP var] = line; head[file SUBSEP var] = h[$5]
        }
      }
      END {
        for (k in firstread) {
          if (!((k) in seen) || (k) in shallow) continue
          split(k, p, SUBSEP)
          printf "%s\t%s\t%s:%s (%s) -- $%s is only ever assigned inside a loop\n", \
            p[1], p[2], p[1], firstread[k], head[k], p[2]
        }
      }
    ' "$INDEX" "$EVENTS" | sort | filter_baseline loop-scope
  )"
  assert_no_findings "$findings" \
    "Check 3 — no variable read outside the loop that is its only assignment" \
    "Either make this block a real loop, or resolve the value inside the block."
}

# ---------------------------------------------------------------------------
# Check 4 — read but never assigned anywhere in the same file.
#
# Measured yield: 103 hits on the pre-fix tree, 100 on the fixed tree; after
# dropping process-environment names (ENV_ALLOWLIST above) 40 and 37. Exactly
# one of the pre-fix hits was the real bug — AIMI_ROOT_IS_GIT_REPO at
# execute.md:1040, blocking finding B10, assigned only by an English sentence.
# SPLIT_BRANCH_ARGS, the variable the `mapfile` failed to populate, was a
# second true positive it happened to catch.
#
# At that signal-to-noise ratio the check is unusable as a bare gate, so it
# ships behind the checked-in baseline: the known names are grandfathered and
# only a NEW unassigned name fails. The baseline shrinking is the point — it
# is how AIMI_ROOT_IS_GIT_REPO would have been noticed leaving.
#
# DELIBERATELY NOT IMPLEMENTED: "assigned in one block, read in another".
# Measured at 254 hits. Cross-block carry is this repo's documented norm
# (execute.md says so explicitly: "Carry each active split file's resolved
# tuple forward"), so that check is theatre as a gate. shellcheck is not
# installed here and there is no package manager to install it with; it would
# flood with the same 254-shaped signal for the same reason.
# ---------------------------------------------------------------------------
check_unassigned() {
  local findings
  findings="$(
    awk -F'\t' '
      NR == FNR { f[$1] = $2; s[$1] = $3; h[$1] = $4; next }
      {
        file = f[$5]; var = $2; line = $4 + s[$5] - 1
        if ($1 == "A") { assigned[file SUBSEP var] = 1 }
        else if (!((file SUBSEP var) in firstread)) {
          firstread[file SUBSEP var] = line; head[file SUBSEP var] = h[$5]
        }
      }
      END {
        for (k in firstread) {
          if ((k) in assigned) continue
          split(k, p, SUBSEP)
          printf "%s\t%s\t%s:%s (%s) -- $%s is read but never assigned in this file\n", \
            p[1], p[2], p[1], firstread[k], head[k], p[2]
        }
      }
    ' "$INDEX" "$EVENTS" \
      | awk -F'\t' -v RE="$ENV_ALLOWLIST" '$2 !~ RE' \
      | sort | filter_baseline unassigned
  )"
  assert_no_findings "$findings" \
    "Check 4 — no newly unassigned variable (known names grandfathered)" \
    "Assign it in the same block that reads it, or add an 'unassigned' line to $(basename "$BASELINE_FILE")."
}

# ---------------------------------------------------------------------------
# Same-block validation of $ARGUMENTS.
#
# $ARGUMENTS is raw user input, textually substituted into a block before the
# shell ever sees it. Blocks are EXECUTED, each in its own isolated shell, so
# a gate sitting in an EARLIER block cannot protect a later one: its `exit 1`
# ends only its own shell, and the later block still runs. Any block that
# interpolates $ARGUMENTS into a command line must therefore carry its own
# gate, in that same block, above the use.
#
# A `case` gate is what this check wants for a numeric identifier: `grep -qE
# '^[0-9]+$'` matches line by line, so it accepts a multi-line value whose
# FIRST line is digits, while a `case` pattern tests the whole string. The
# branch-name form (`grep -qE '^[a-zA-Z0-9]...`) is accepted too — it is the
# established pattern for that field and is validated again downstream.
# ---------------------------------------------------------------------------
check_argument_gate_same_block() {
  local findings="" id rel line heading body
  while IFS=$'\t' read -r id rel line heading; do
    [ -n "$id" ] || continue
    body="$(cat "$BLOCKS_DIR/$id.sh" 2>/dev/null)"

    case "$body" in
      *'"$ARGUMENTS"'*) ;;
      *) continue ;;
    esac

    case "$body" in
      *'*[!0-9]*'*)          continue ;;
      *"grep -qE '^[0-9]"*)  continue ;;
      *"grep -qE '^[a-zA-Z"*) continue ;;
    esac

    findings="$findings$rel	$heading	$rel:$line — $heading"$'\n'
  done < "$INDEX"

  assert_no_findings "$(printf '%s' "$findings" | filter_baseline argument-gate)" \
    "Check 5 — every block interpolating \$ARGUMENTS validates it in that same block" \
    "Each block runs in its own shell, so a gate in a different block cannot stop this one. Add the gate above the use, in the same block."
}

# ---------------------------------------------------------------------------
# Check 6 — execute.md's phase-branch derivation, executed against fixtures.
#
# Measured yield: 3 hits on the pre-fix tree (both decimal fixtures' exact
# strings, plus the aggregate regex assert naming both), 0 on the fixed tree,
# 0 false positives on either. Demonstrated by reverting only the derivation.
#
# WHY THIS ONE RUNS THE BLOCK
#
# execute.md derives PHASE_BRANCH from the phase id, then validates the result
# against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` seven lines later. That regex has no
# dot; phase ids are legitimately decimal. So a phase like 5.5 whose roadmap
# `.branch` is null derived `feat/x-phase-5.5-slug`, failed the file's OWN
# validation, released the claim and STOPped — unexecutable, with nothing in
# any suite able to see it. The block parses, is portable, and reads nothing
# unassigned; only its VALUE was wrong. Hence: execute it.
#
# The block is located by matching its body, never by a hardcoded index or
# heading, so renaming the heading or adding a sibling block cannot silently
# disable this check — it asserts it found exactly one.
#
# The confinement assert is the other half. The slugified id must reach the
# branch name and NOTHING else: `$FEATURE-phase-$PHASE_ID-tasks.json` names
# real files that carry the dot, and `--phase "$PHASE_ID"` must match
# roadmap.json's own numeric id. Both keep the raw id.
# ---------------------------------------------------------------------------
PHASE_BRANCH_REGEX='^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'

# Runs the located block in its own shell with the fixture pre-set, and echoes
# whatever PHASE_BRANCH ends up as. PHASE_BRANCH starts empty on purpose — that
# is the "roadmap .branch is null" case, the only one the block acts on.
derive_phase_branch() {
  local block="$1" phase_id="$2" phase_slug="$3"
  PHASE_BRANCH="" FEATURE_TYPE="feat" FEATURE="caic-nestjs-port" \
  PHASE_ID="$phase_id" PHASE_SLUG="$phase_slug" \
    bash -c '. "$0"; printf "%s" "$PHASE_BRANCH"' "$block" 2>/dev/null
}

check_phase_branch_derivation() {
  local id rel start heading body matches="" block actual expected findings=""
  local fixture fid fslug

  while IFS=$'\t' read -r id rel start heading; do
    [ -n "$id" ] || continue
    body="$(cat "$BLOCKS_DIR/$id.sh" 2>/dev/null)"
    case "$body" in
      *'PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-'*) matches="$matches$id " ;;
    esac
  done < "$INDEX"

  assert_eq "1" "$(printf '%s' "$matches" | wc -w | tr -d ' ')" \
    "Check 6a — exactly one block derives PHASE_BRANCH from FEATURE_TYPE/FEATURE"

  block="$BLOCKS_DIR/$(printf '%s' "$matches" | awk '{print $1}').sh"
  [ -f "$block" ] || return 0

  # id|slug|expected branch. Decimal rows first — those are the regressions.
  # The delimiter must NOT be a tab: tab is an IFS whitespace character, so
  # bash collapses the two adjacent tabs of an empty-slug row into one and the
  # row silently loses a field. That skipped both empty-slug fixtures when this
  # was first written, and the check still reported green.
  while IFS='|' read -r fid fslug expected; do
    [ -n "$expected" ] || continue
    fixture="id=$fid slug=${fslug:-<empty>}"
    actual="$(derive_phase_branch "$block" "$fid" "$fslug")"
    assert_eq "$expected" "$actual" "Check 6 — derivation for $fixture"
    printf '%s' "$actual" | grep -qE "$PHASE_BRANCH_REGEX" \
      || findings="$findings$fixture -> '$actual' fails ${PHASE_BRANCH_REGEX}"$'\n'
  done <<'FIXTURES'
5.5|identificacao-no-painel|feat/caic-nestjs-port-phase-5-5-identificacao-no-painel
5.5||feat/caic-nestjs-port-phase-5-5
5|identificacao-no-painel|feat/caic-nestjs-port-phase-5-identificacao-no-painel
5||feat/caic-nestjs-port-phase-5
FIXTURES

  assert_no_findings "$(printf '%s' "$findings")" \
    "Check 6 — every derived branch matches the regex execute.md validates against" \
    "execute.md rejects this value itself seven lines below the derivation, releases the claim and STOPs."

  # The slugified id is for the branch name only. Anywhere it touches a tasks
  # file path or a --phase argument, the raw dot-bearing id was needed instead.
  local leaks
  leaks="$(
    grep -n 'PHASE_ID_SLUG' "$COMMANDS_DIR/execute.md" 2>/dev/null \
      | grep -E -- '-tasks\.json|--phase' \
      | sed 's/^/execute.md:/'
    # Outside the derivation block entirely (prose, or another block).
    in_block="$(grep -c 'PHASE_ID_SLUG' "$block" 2>/dev/null || echo 0)"
    in_file="$(grep -c 'PHASE_ID_SLUG' "$COMMANDS_DIR/execute.md" 2>/dev/null || echo 0)"
    [ "$in_block" = "$in_file" ] \
      || printf 'PHASE_ID_SLUG appears %s time(s) in execute.md but only %s inside the derivation block\n' \
           "$in_file" "$in_block"
  )"
  assert_no_findings "$leaks" \
    "Check 6 — the slugified phase id stays inside the derivation block" \
    "Filesystem paths and --phase arguments must keep the raw \$PHASE_ID; only the branch name is slugified."
}

# ---------------------------------------------------------------------------
# Check 7 — execute.md's verification_failed re-verify branch (issue #90).
#
# Measured yield: 4 of the 6 assertions fail on the pre-fix tree (7a, 7b, 7c
# and 7d — 7c naming 5 of its 7 missing tokens), 0 on the fixed tree.
# Demonstrated by reverting only execute.md. 7e and 7f are invariants that
# hold on both trees by design: they exist to catch a *future* edit that adds
# a claim release to the new branch, drops the one the STOP still needs, or
# rewords away the re-run instruction the branch was written to honor.
#
# WHY THIS ONE IS STATIC PROSE MATCHING, NOT AN EXECUTED BLOCK
#
# The defect is a missing *control-flow branch* written in prose, not a wrong
# value produced by a block. A phase that reaches verification_failed has zero
# pending stories by construction, so Step 3's zero-pending case released the
# claim, printed "All stories already complete!" and STOPped ~900 lines before
# Phase Completion — the only place creates verification re-runs. The phase
# stayed stuck forever and every dependent phase stayed blocked, while the
# verification-failure report told the user to re-run /aimi:execute to
# re-verify, which is exactly what could not work. Nothing executable was
# wrong; a decision the file never made was missing. So this check asserts the
# branch's *structure*: that the entry status is captured where it is still
# recoverable, that the gate is decided before the release-and-STOP, and that
# the branch adds no claim release of its own.
#
# The claim-release count is the load-bearing half. Step 3 sits on the path
# every /aimi:execute run takes, and the new branch is NOT a STOP: Phase
# Completion owns the release on both of its outcomes. A release added here
# would hand the phase to a racing session mid-verification, and a release
# removed from the existing STOP would leak a claim on every already-complete
# phase-mode run. Exactly one, below the gate, is the whole contract.
# ---------------------------------------------------------------------------
check_reverify_branch() {
  local md="$COMMANDS_DIR/execute.md"
  local id rel start heading body matches="" block findings=""

  # --- The capture: Step 1.7's on-success extraction block ------------------
  # PHASE_ENTRY_STATUS must be read off the claim JSON there, because Step 1.7
  # transitions the phase to in_progress within the same step — after that, no
  # roadmap-get can recover the status the phase was claimed in.
  while IFS=$'\t' read -r id rel start heading; do
    [ -n "$id" ] || continue
    [ "$rel" = "execute.md" ] || continue
    body="$(cat "$BLOCKS_DIR/$id.sh" 2>/dev/null)"
    case "$body" in
      *'PHASE_ENTRY_STATUS='*) matches="$matches$id " ;;
    esac
  done < "$INDEX"

  assert_eq "1" "$(printf '%s' "$matches" | wc -w | tr -d ' ')" \
    "Check 7a — exactly one block in execute.md assigns PHASE_ENTRY_STATUS"

  block="$BLOCKS_DIR/$(printf '%s' "$matches" | awk '{print $1}').sh"
  if [ -f "$block" ]; then
    [ "$(grep -cF 'PHASE_ENTRY_STATUS=' "$block")" = "1" ] \
      || findings="$findings assigned more than once inside its own block"$'\n'
    grep -qF 'PHASE_BRANCH=' "$block" && grep -qF 'PHASE_DIR=' "$block" \
      || findings="$findings not in Step 1.7's claim-JSON extraction block (no PHASE_DIR/PHASE_BRANCH beside it)"$'\n'
    grep -F 'PHASE_ENTRY_STATUS=' "$block" | grep -qF 'CLAIM_JSON' \
      || findings="$findings not read from CLAIM_JSON — a later roadmap-get reports in_progress, not the entry status"$'\n'
    grep -F 'PHASE_ENTRY_STATUS=' "$block" | grep -q '\.status // ""' \
      || findings="$findings missing the .status // \"\" default — a status-less phase would yield the string null"$'\n'
  else
    findings="$findings PHASE_ENTRY_STATUS is never assigned in any bash block"$'\n'
  fi

  assert_no_findings "$(printf '%s' "$findings")" \
    "Check 7b — PHASE_ENTRY_STATUS is captured once, from the claim JSON, in Step 1.7" \
    "Step 1.7's own in_progress transition destroys the entry status; this block is the only place it can be read."

  # --- The branch: Step 3's zero-pending case -------------------------------
  local slice start_line gate_line rel_line msg_line rel_count gate_region
  slice="$(awk '
    /^## Step 3: Check for Pending Stories$/ { inside = 1 }
    inside                                   { print }
    inside && /^### Validate Dependencies$/  { exit }
  ' "$md")"

  start_line="$(printf '%s\n' "$slice" | grep -n 'If result is' | head -1 | cut -d: -f1)"
  gate_line="$(printf '%s\n' "$slice" | grep -nF 'PHASE_ENTRY_STATUS' | head -1 | cut -d: -f1)"
  rel_line="$(printf '%s\n' "$slice" | grep -nF 'roadmap-release-claim' | head -1 | cut -d: -f1)"
  # -x: the report line itself, not the prose above it that quotes the string.
  msg_line="$(printf '%s\n' "$slice" | grep -nxF 'All stories already complete!' | head -1 | cut -d: -f1)"
  rel_count="$(printf '%s\n' "$slice" | grep -cF 'roadmap-release-claim')"

  gate_region=""
  if [ -n "$start_line" ] && [ -n "$rel_line" ] && [ "$rel_line" -gt "$start_line" ]; then
    gate_region="$(printf '%s\n' "$slice" | sed -n "${start_line},$((rel_line - 1))p")"
  fi

  # The gate is a five-condition conjunction; dropping any one of them either
  # re-breaks a working path or fires the branch where it must not.
  local tok gate_findings=""
  for tok in 'count-pending' 'PHASE_MODE' 'PHASE_ID' 'PHASE_SPLIT_MODE' \
             'PHASE_ENTRY_STATUS' 'verification_failed' 'Phase Completion'; do
    printf '%s\n' "$gate_region" | grep -qF "$tok" \
      || gate_findings="$gate_findings the re-verify branch never names $tok"$'\n'
  done
  assert_no_findings "$(printf '%s' "$gate_findings")" \
    "Check 7c — the re-verify branch states its full gate and where it continues to" \
    "All five conditions plus the Phase Completion destination must be written down above the release-and-STOP."

  local ordering="false"
  if [ -n "$gate_line" ] && [ -n "$rel_line" ] && [ -n "$msg_line" ] \
     && [ "$gate_line" -lt "$rel_line" ] && [ "$rel_line" -lt "$msg_line" ]; then
    ordering="true"
  fi
  assert_eq "true" "$ordering" \
    "Check 7d — the re-verify branch is decided before Step 3's release-and-STOP"

  assert_eq "1" "$rel_count" \
    "Check 7e — Step 3's zero-pending case releases the claim exactly once (the re-verify branch adds none)"

  # The failure report tells the user to re-run to re-verify. That sentence is
  # what the branch above makes true; if it is ever reworded away, the branch
  # has lost the instruction it exists to honor.
  local sentence_finding=""
  grep -qF 'then re-run /aimi:execute to re-verify — creates verification re-runs' "$md" \
    || sentence_finding="the verification-failed report no longer tells the user to re-run /aimi:execute to re-verify"
  assert_no_findings "$sentence_finding" \
    "Check 7f — the verification-failed report's re-run instruction is intact" \
    "Step 3's re-verify branch exists to make that sentence true; keep them in sync."
}

# Check 8 — plan.md's branchName derivations use the dot-slugified phase id.
#
# Measured yield: 2 hits on the pre-fix tree (the branch-context raw-id leg
# reporting all 6 occurrences, and the three-shapes leg reporting all 3
# missing), 0 on the fixed tree, 0 false positives on either.
#
# WHY THIS IS WEAKER THAN CHECK 6, AND WHY IT IS STILL THE RIGHT SHAPE HERE
#
# plan.md has the same defect check 6 guards in execute.md: it built
# metadata.branchName from the raw ${SELECTED_PHASE_ID}, then validated the
# result against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` -- no dot -- and its own Phase 4
# failure row says "report the invalid branch name and STOP". So a decimal
# phase could not be planned, one command upstream of the execute.md failure.
#
# But check 6's approach is UNAVAILABLE here, and that is a fact about the
# file, not a shortcut. All six of plan.md's branchName derivations are PROSE
# instructing the agent what to compute -- verified by running plan.md through
# this file's own fence-state machine: every one reports PROSE, none is inside
# a ```bash fence. There is no block to extract and execute, so this check
# asserts what the INSTRUCTION SAYS, not what the code DOES. It cannot catch an
# agent that reads correct prose and computes the wrong thing. Do not read a
# green run here as the guarantee check 6 provides.
#
# The discriminator between a branch and a path is the `type/` prefix: a branch
# reads `type/${featureSlug}-phase-...`, a tasks-file path reads
# `${featureSlug}-phase-...-tasks.json` with no `type/`. That is what keeps leg
# 1 off plan.md's legitimate raw-id path at the TASKS_PATH assignment, which is
# a real bash block and must keep the dot.
# ---------------------------------------------------------------------------
check_plan_branchname_slugified() {
  local plan="$COMMANDS_DIR/plan.md"
  local raw_branch missing shape kept widened

  if [ ! -f "$plan" ]; then
    assert_eq "found" "missing" "Check 8 — plan.md is readable"
    return 0
  fi

  # Leg 1 -- no branchName derivation may interpolate the RAW id. The `type/`
  # prefix is what makes an occurrence a branch rather than a filesystem path.
  raw_branch="$(grep -nF 'type/${featureSlug}-phase-${SELECTED_PHASE_ID}' "$plan" \
    | cut -c1-160 | sed 's/^/plan.md:/')"
  assert_no_findings "$raw_branch" \
    "Check 8 — no plan.md branchName derivation interpolates the raw phase id" \
    "A decimal phase id yields '...-phase-5.5-...', which plan.md's own Phase 4 rule rejects and STOPs on. Use \${SELECTED_PHASE_ID_SLUG}."

  # Leg 2 -- all three derivation shapes must carry the slugified symbol, so a
  # partial fix (flat done, splits missed) fails instead of passing quietly.
  missing=""
  while IFS='|' read -r shape pattern; do
    [ -n "$pattern" ] || continue
    grep -qF "$pattern" "$plan" \
      || missing="$missing$shape shape not found with the slugified id: $pattern"$'\n'
  done <<'SHAPES'
non-split|type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}`
SIDE-axis|type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}-frontend
PROJECT-axis|type/${featureSlug}-phase-${SELECTED_PHASE_ID_SLUG}-${PHASE_SLUG}-<project-slug>
SHAPES
  assert_no_findings "$(printf '%s' "$missing")" \
    "Check 8 — all three branchName shapes (non-split, SIDE, PROJECT) use the slugified id" \
    "Every shape must be fixed; a decimal phase reaches the split shapes too."

  # Leg 3 -- the mirror of check 6's confinement assert. Filesystem paths must
  # KEEP the raw id: execute.md reads these exact basenames with the dot, so
  # slugifying them here would silently break the pair.
  kept=""
  for pattern in \
    '${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json' \
    '${featureSlug}-phase-${SELECTED_PHASE_ID}-frontend-tasks.json' \
    '${featureSlug}-phase-${SELECTED_PHASE_ID}-<project-slug>-tasks.json'
  do
    grep -qF "$pattern" "$plan" \
      || kept="$kept tasks-file path lost its raw id: $pattern"$'\n'
  done
  assert_no_findings "$(printf '%s' "$kept")" \
    "Check 8 — plan.md's tasks-file paths still carry the raw phase id" \
    "These name real on-disk files that carry the dot, and execute.md reads them with the raw id."

  # Leg 4 -- the fix conforms the value; it must never widen the regex.
  widened="$(grep -nE '"branchName".*regex:.*\[a-zA-Z0-9[^]]*\\?\.' "$plan" | cut -c1-160)"
  assert_no_findings "$widened" \
    "Check 8 — plan.md's branchName regex was not widened to admit a dot" \
    "Conform the derived value instead; this regex is shared with execute.md and aimi-cli.sh's _ROADMAP_BRANCH_REGEX."
}

# ---------------------------------------------------------------------------
# Check 9 — the forge-account picker persists ONLY a human's answer.
#
# WHY THIS IS A CHECK AND NOT A CODE COMMENT
#
# interactivity.md requires every question site to auto-select the first
# non-escape option under agent mode (--non-interactive / AIMI_AGENT_MODE / CI).
# At this site that option is "always use the active account" — which is ALSO
# the question's permanent opt-out: recording it is precisely what stops the
# question ever being raised again. So persisting the agent-mode auto-answer
# would let ONE unattended CI run silently and permanently answer the question
# for every human who touches that repository afterwards. They would never be
# asked, and would have no way to discover why.
#
# That defect is invisible until it has already happened to someone: nothing
# fails, nothing is logged, the picker simply never appears again. The repo has
# shipped this exact shape once already (1.93.0's unrevocable dismissal). So the
# rule is pinned structurally, the way check 7 pins a prose control-flow branch:
# every `$AIMI_CLI forge-account-select --record*` INVOCATION in an ask site
# must sit above that site's agent-mode branch. Prose that merely NAMES the
# flags is not an invocation and is deliberately not matched — invocations go
# through $AIMI_CLI, and the agent-mode paragraph's own "make no
# `forge-account-select --record` ... call at all" sentence must not trip it.
# ---------------------------------------------------------------------------
FORGE_ACCOUNT_SITES='open-pr.md|#### Select the acting forge account for this repository
execute.md|#### Select the acting forge account per repository'

# Prints the ask site's region: the heading line through the line before the
# next markdown heading, each line prefixed with its 1-based number in the file.
forge_account_region() {
  awk -v H="$2" '
    { n = n + 1 }
    !inside && index($0, H) == 1 { inside = 1; print n "\t" $0; next }
    inside && /^#+ / { exit }
    inside { print n "\t" $0 }
  ' "$1"
}

check_forge_account_picker() {
  local file heading region path
  local missing="" persist="" contract=""

  while IFS='|' read -r file heading; do
    [ -n "$heading" ] || continue
    path="$COMMANDS_DIR/$file"
    if [ ! -f "$path" ]; then
      missing="$missing$file is not readable"$'\n'
      continue
    fi
    region="$(forge_account_region "$path" "$heading")"
    if [ -z "$region" ]; then
      missing="$missing$file has no '$heading' section"$'\n'
      continue
    fi

    # The picker itself, in the exact literal install.sh matches on.
    printf '%s\n' "$region" | grep -qF 'Use **AskUserQuestion**' \
      || missing="$missing$file: the ask site never writes the literal 'Use **AskUserQuestion**'"$'\n'

    # The agent-mode branch, and the log line that makes non-persistence
    # observable in the transcript rather than merely asserted here.
    printf '%s\n' "$region" | grep -qF 'agent-mode: forge-account auto-selected active account (not recorded)' \
      || missing="$missing$file: the agent-mode log line no longer states '(not recorded)'"$'\n'
    printf '%s\n' "$region" | grep -qF 'Agent-mode fallback:' \
      || missing="$missing$file: the ask site has no agent-mode fallback sentence (interactivity.md requires one)"$'\n'

    # --- the property -----------------------------------------------------
    local records last_record agent_line nrecords
    records="$(printf '%s\n' "$region" | grep -F '$AIMI_CLI forge-account-select --record' | cut -f1)"
    nrecords="$(printf '%s' "$records" | grep -c . || true)"
    agent_line="$(printf '%s\n' "$region" | grep -nF '**When `INTERACTIVE_MODE=agent`**' | head -1 | cut -d: -f1)"
    agent_line="$(printf '%s\n' "$region" | sed -n "${agent_line:-0}p" | cut -f1)"
    last_record="$(printf '%s\n' "$records" | tail -1)"

    if [ "$nrecords" != "2" ]; then
      persist="$persist$file: expected exactly 2 forge-account-select --record* invocations (--record-active and --record <login>, both in the one picker-mode fence), found $nrecords"$'\n'
    fi
    if [ -z "$agent_line" ]; then
      persist="$persist$file: the ask site never opens an agent-mode branch, so nothing bounds where a record call may appear"$'\n'
    elif [ -n "$last_record" ] && [ "$last_record" -ge "$agent_line" ]; then
      persist="$persist$file:$last_record — a forge-account-select --record* invocation sits at or below the agent-mode branch ($file:$agent_line)"$'\n'
    fi
  done <<EOF
$FORGE_ACCOUNT_SITES
EOF

  assert_no_findings "$(printf '%s' "$missing")" \
    "Check 9 — both forge-account ask sites carry the picker, the agent-mode branch and the (not recorded) log line" \
    "interactivity.md requires the exact 'Use **AskUserQuestion**' literal, a fallback sentence, and one log line per site."

  assert_no_findings "$(printf '%s' "$persist")" \
    "Check 9 — every forge-account record call sits above the agent-mode branch (agent mode persists nothing)" \
    "Option A is also the permanent opt-out: a record call reachable from agent mode lets one CI run answer the question forever for every human."

  # The picker literal must NOT reach a reference file: references are copied
  # verbatim by install.sh and skipped by both command-install loops, so one
  # written here arrives in OpenCode naming a tool that host does not have.
  contract="$(grep -n 'AskUserQuestion' "$COMMANDS_DIR/references/forge-contract.md" 2>/dev/null | cut -c1-160 | sed 's/^/forge-contract.md:/')"
  assert_no_findings "$contract" \
    "Check 9 — forge-contract.md carries the account contract with no AskUserQuestion literal" \
    "commands/references/ is never run through install.sh's translate_command_body. Put the picker in a command body instead."
}

# ===========================================================================
# Checks 10-14 — confirm before publishing.
#
# WHAT THESE COVER, AND WHAT THEY CANNOT
#
# The phase these were written for has six success criteria. Read this before
# reading a green run as proof of any of them:
#
#   1. "asks before pushing and before opening a PR, publishes only when
#      approved"           — PARTIAL, textual only. Checks 10 and 11 prove the
#      question is WRITTEN DOWN above the push, that the gate normalizes
#      anything that is not an explicit approval to "publish nothing", and that
#      the push sits below the decline branch. They cannot prove the agent
#      obeys any of it.
#   2. "the confirmation covers the push itself, not only the PR"
#                          — TEXTUAL. Check 10c pins the push-only option and
#      the decline branch that returns before `git push` is ever reached.
#   3. "agent mode never publishes, and no flag re-enables it"
#                          — TEXTUAL. Checks 11b and 12a.
#   4. "--push is removed, and passing it FAILS"
#                          — TEXTUAL. Check 12 (argument-hint, PUSH_FLAG,
#      refusal-branch confinement, non-zero exit, message naming the
#      replacement).
#   5. "every completion path names /aimi:open-pr"
#                          — TEXTUAL. Check 13.
#   6. "the suites would fail if any of the above regressed"
#                          — this is what checks 10-14 are. Each was verified
#      to FAIL against the phase's base commit, not merely to pass here.
#
# NOT COVERED BY ANY OF THEM: no static check can execute the gate and observe
# a refusal. The whole gate is prose plus a picker literal; the agent, not the
# shell, decides. This suite's HONEST LIMIT above applies with full force —
# `PHASE_PUBLISH` and `SKIP_PUSH` are both set by an English sentence telling
# the model what to substitute, and per the repo's CLAUDE.md a variable a prose
# sentence reads is invisible to this suite by construction. Checks 10 and 11
# assert that the right sentences are present and in the right ORDER. They
# assert nothing about what happens at runtime, and a green run here is not
# evidence that a phase ever declined to publish. The durable fix for that
# class is the same one the header names: move the decision into aimi-cli.sh,
# where test-aimi-cli.sh can execute it.
# ===========================================================================

# Prints a markdown section: the heading line through the line before the next
# heading at the same or SHALLOWER level, each line prefixed with its 1-based
# number in the file.
#
# Two differences from check 9's forge_account_region, both load-bearing here.
# It stops at the next same-or-shallower heading rather than at the very next
# heading of any level, because the publish gate spans several #### subsections
# under one ### and the ordering property below needs the whole subtree. And it
# tracks fences with the same rule extract_blocks uses (a closing fence carries
# no info string and is not indented deeper than its opener), because these
# command files print report templates containing literal `##` lines inside
# fenced blocks — a fence-blind scan ends the section on the first one and the
# check then fails for a reason that has nothing to do with publishing.
md_section() {
  awk -v H="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      n = n + 1
      probe = $0; sub(/^[ \t]+/, "", probe)
      if (probe ~ /^```/) {
        ind = match($0, /[^ \t]/) - 1
        info = probe; sub(/^`+/, "", info); info = trim(info)
        if (infence == 0)                              { infence = 1; openind = ind }
        else if (info == "" && ind <= openind)         { infence = 0 }
        if (inside) print n "\t" $0
        next
      }
      if (infence == 1) { if (inside) print n "\t" $0; next }
      if (!inside && index($0, H) == 1) {
        inside = 1; lvl = 0
        while (substr(probe, lvl + 1, 1) == "#") lvl++
        print n "\t" $0; next
      }
      if (inside && probe ~ /^#{1,6}[ \t]/) {
        l = 0; while (substr(probe, l + 1, 1) == "#") l++
        if (l <= lvl) exit
      }
      if (inside) print n "\t" $0
    }
  ' "$1"
}

# Translates the first region line matching a literal into the FILE line number
# that region line carries in its first field. Empty in, empty out: `sed -n 0p`
# is an error rather than a no-op, so the offset is tested before it is used —
# every caller here can legitimately find nothing.
region_lineno() {
  local region="$1" pattern="$2" off
  off="$(printf '%s\n' "$region" | grep -nF "$pattern" | head -1 | cut -d: -f1)"
  [ -n "$off" ] || return 0
  printf '%s\n' "$region" | sed -n "${off}p" | cut -f1
}

# Line numbers of the region lines that INVOKE git push, as opposed to naming
# it. The discriminator is the command position: an invocation starts the line,
# a recovery instruction the loop prints for the user is an argument to `echo`,
# and prose mentions it mid-sentence. All three shapes are live in the region
# this is pointed at, which is why a bare `grep 'git push'` is wrong here.
region_push_invocations() {
  awk -F'\t' '
    {
      num = $0; sub(/\t.*$/, "", num)
      line = $0; sub(/^[0-9]+\t/, "", line)
      if (line ~ /^[ \t]*git([ \t]+-C[ \t]+[^ \t]+)?[ \t]+push([ \t]|$)/) print num
    }
  '
}

# ---------------------------------------------------------------------------
# Check 10 — execute.md's phase-completion publish gate.
#
# Measured yield: 3 of its 3 assertions fail against the phase base commit
# (3bde8f6), 0 here. On that tree Phase Completion pushed every participating
# repository's branch and opened its PR with no question asked anywhere — the
# `#### Confirm before publishing this phase` subsection did not exist, so 10a
# reports every required literal missing, 10b reports the push sitting in a
# section with no gate above it, and 10c reports the fail-closed normalization
# and the decline branch both absent.
#
# WHY THE ORDERING PROPERTY IS THE LOAD-BEARING HALF
#
# Same reason check 9's is. Every literal 10a looks for could be present and
# the gate still be worthless if the push ran above it: a question asked after
# the branch is already on origin is not a confirmation, it is a notification.
# So the property asserted is positional — every `git push` INVOCATION in
# `### Offer a Pull Request` must sit BELOW the gate's heading, and below the
# decline branch that returns before reaching it. Moving the push up, dropping
# the `*) PHASE_PUBLISH="none" ;;` default, or deleting the early `continue`
# each fail it independently.
#
# Fail-closed is asserted explicitly rather than assumed: the gate's inputs are
# a human answer and an orchestrator substitution, and both can go missing.
# `PHASE_PUBLISH` arriving unsubstituted must decline, never publish.
# ---------------------------------------------------------------------------
PHASE_PUBLISH_SECTION='### Offer a Pull Request'
PHASE_PUBLISH_GATE='#### Confirm before publishing this phase'

check_phase_publish_gate() {
  local md="$COMMANDS_DIR/execute.md"
  local region gate_line decline_line pushes p
  local missing="" ordering="" closed=""
  local literal why

  region="$(md_section "$md" "$PHASE_PUBLISH_SECTION")"
  if [ -z "$region" ]; then
    assert_no_findings "execute.md has no '$PHASE_PUBLISH_SECTION' section" \
      "Check 10 — the phase-completion publish gate is present" \
      "The gate is addressed by that heading; renaming it silently disables checks 10a-10c."
    return 0
  fi

  # --- 10a: the gate says what publish-confirmation.md requires of a call site
  while IFS='|' read -r literal why; do
    [ -n "$literal" ] || continue
    printf '%s\n' "$region" | grep -qF "$literal" \
      || missing="$missing execute.md: the publish gate never writes '$literal' — $why"$'\n'
  done <<'GATE_LITERALS'
#### Confirm before publishing this phase|there is no per-phase confirmation subsection at all
Use **AskUserQuestion**|interactivity.md's exact picker literal, and the string install.sh rewrites for OpenCode
PHASE_PUBLISH|the single variable the publish loop reads
INTERACTIVE_MODE=agent|an unattended run must have a branch of its own that cannot publish
publish-confirmation.md|the gate must cite the contract rather than restate it
/aimi:open-pr|every outcome, including the decline, must name the command that publishes later
GATE_LITERALS

  assert_no_findings "$(printf '%s' "$missing")" \
    "Check 10a — the phase publish gate asks, branches on agent mode, and names /aimi:open-pr" \
    "publish-confirmation.md requires a question, an agent-mode branch that declines, and the follow-up command on every path."

  # --- 10b: the push sits below the gate, not above it ----------------------
  gate_line="$(region_lineno "$region" "$PHASE_PUBLISH_GATE")"
  pushes="$(printf '%s\n' "$region" | region_push_invocations)"

  if [ -z "$gate_line" ]; then
    ordering="$ordering execute.md: '$PHASE_PUBLISH_SECTION' opens no confirmation subsection, so nothing bounds where a push may appear"$'\n'
  fi
  if [ -z "$(printf '%s' "$pushes" | grep -c . || true)" ] || [ "$(printf '%s' "$pushes" | grep -c . || true)" = "0" ]; then
    ordering="$ordering execute.md: no git push invocation found in '$PHASE_PUBLISH_SECTION' — the publish loop was moved or renamed and this check no longer guards it"$'\n'
  fi
  for p in $pushes; do
    [ -n "$gate_line" ] || break
    [ "$p" -gt "$gate_line" ] \
      || ordering="$ordering execute.md:$p — a git push invocation sits at or above the publish gate (execute.md:$gate_line); a question asked after the branch reaches origin is a notification, not a confirmation"$'\n'
  done

  assert_no_findings "$(printf '%s' "$ordering")" \
    "Check 10b — every phase-completion push sits below the confirmation gate" \
    "Move the push back under '$PHASE_PUBLISH_GATE', or the gate is decorative."

  # --- 10c: fail closed, and the decline returns before the push ------------
  printf '%s\n' "$region" | grep -qF '*) PHASE_PUBLISH="none" ;;' \
    || closed="$closed execute.md: the publish loop has no catch-all normalizing PHASE_PUBLISH to none — an unsubstituted value would fall through to the push"$'\n'
  printf '%s\n' "$region" | grep -qF 'if [ "$PHASE_PUBLISH" = "push" ]' \
    || closed="$closed execute.md: no push-only branch — the confirmation would cover the pull request but not the push it depends on"$'\n'

  decline_line="$(region_lineno "$region" 'if [ "$PHASE_PUBLISH" = "none" ]')"
  if [ -z "$decline_line" ]; then
    closed="$closed execute.md: the publish loop has no PHASE_PUBLISH=none branch, so declining still reaches the forge and the push"$'\n'
  else
    for p in $pushes; do
      [ "$p" -gt "$decline_line" ] \
        || closed="$closed execute.md:$p — a git push invocation sits at or above the decline branch (execute.md:$decline_line)"$'\n'
    done
  fi

  assert_no_findings "$(printf '%s' "$closed")" \
    "Check 10c — the publish gate fails closed and the decline returns before any push" \
    "Anything that is not an explicit approval must normalize to none, and none must exit the iteration above the push."
}

# ---------------------------------------------------------------------------
# Check 11 — the flat-container push confirmation.
#
# Measured yield: both assertions fail against 3bde8f6, 0 here. There the
# picker lived in container-execution.md and its agent branch pushed whenever
# `--push` had been passed, so 11a reports Step 5 carrying no question at all
# and 11b reports the reference still holding the picker and still gating on a
# flag.
#
# WHY THE PICKER'S FILE MATTERS AS MUCH AS ITS CONTENT
#
# `commands/references/` is delivered to OpenCode by install.sh's verbatim
# whole-tree copy, and both of its command-install loops skip that subdirectory
# by name — so translate_command_body(), which is what rewrites the picker's
# tool name for that host, never sees a reference file. A picker written there
# reaches OpenCode naming a tool that host does not have. That is why story 05
# moved this one question up into the command body, and why 11a asserts it is
# in execute.md while check 14 asserts it is nowhere under references/.
#
# 11b's other half is criterion 3: the reference's agent-mode branch must set
# SKIP_PUSH unconditionally. "Unconditionally" is the whole claim — the branch
# it replaced was one `if` away from publishing.
# ---------------------------------------------------------------------------
CONTAINER_PUSH_SECTION='### If all stories complete:'
CONTAINER_PUSH_REF_SECTION='## Container Mode: Push the Branch'

check_container_push_confirmation() {
  local md="$COMMANDS_DIR/execute.md"
  local ref="$COMMANDS_DIR/references/container-execution.md"
  local region literal why body="" refs=""

  region="$(md_section "$md" "$CONTAINER_PUSH_SECTION")"
  if [ -z "$region" ]; then
    body="execute.md has no '$CONTAINER_PUSH_SECTION' section"$'\n'
  else
    while IFS='|' read -r literal why; do
      [ -n "$literal" ] || continue
      printf '%s\n' "$region" | grep -qF "$literal" \
        || body="$body execute.md: Step 5's completion branch never writes '$literal' — $why"$'\n'
    done <<'CONTAINER_LITERALS'
Use **AskUserQuestion**|the container push question must live in a command body, where install.sh translates it
SKIP_PUSH=true|the decline must set the same variable container-execution.md's push block gates on
publish-confirmation.md|the question must cite the contract rather than restate it
/aimi:open-pr|a declined push still has to name the command that publishes later
CONTAINER_LITERALS
  fi

  assert_no_findings "$(printf '%s' "$body")" \
    "Check 11a — the flat-container push question lives in execute.md's completion branch" \
    "A picker written into commands/references/ is never translated by install.sh and reaches OpenCode naming a tool that host does not have."

  region="$(md_section "$ref" "$CONTAINER_PUSH_REF_SECTION")"
  if [ -z "$region" ]; then
    refs="container-execution.md has no '$CONTAINER_PUSH_REF_SECTION' section"$'\n'
  else
    printf '%s\n' "$region" | grep -qF 'Set `SKIP_PUSH=true` unconditionally' \
      || refs="$refs container-execution.md: the agent-mode branch no longer sets SKIP_PUSH unconditionally — an unattended run must have no path to origin"$'\n'
    printf '%s\n' "$region" | grep -qF 'the picker markup itself lives there, in that command body, never in this file' \
      || refs="$refs container-execution.md: the section no longer records that the picker belongs in the command body, which is the reason it is not written here"$'\n'
  fi

  assert_no_findings "$(printf '%s' "$refs")" \
    "Check 11b — container-execution.md's agent branch publishes nothing and hosts no picker" \
    "Agent mode has no consent to give and no flag may stand in for it; the question belongs in the command body."
}

# ---------------------------------------------------------------------------
# Check 12 — --push is removed, and its removal is loud.
#
# Measured yield: 3 of its 3 assertions fail against 3bde8f6, 0 here. There the
# frontmatter advertised `[--push]`, `PUSH_FLAG` was parsed in execute.md and
# consumed in container-execution.md, and no refusal branch existed — so 12c
# reports every one of the four surviving literals as unconfined.
#
# WHY SILENCE WOULD HAVE BEEN THE WORSE OUTCOME
#
# A pipeline that passed `--push` to the previous version got a published
# branch out of it. Accepting the flag and quietly doing nothing hands that
# same pipeline silence — the one failure mode nobody notices. So the check
# does not merely assert the flag is gone; it asserts the refusal EXITS
# NON-ZERO and that its message names the replacement, because a refusal that
# does neither is indistinguishable from the silent no-op it replaced.
#
# The `--push` literal is confined to execute.md's refusal branch, not banned
# from commands/ outright: publish-confirmation.md names `--push`-style
# arguments when explaining why no argument can carry consent, which is the
# rule being stated rather than an acceptance of the flag.
# ---------------------------------------------------------------------------
PUSH_REFUSAL_SECTION='### Refuse --push'

check_push_flag_removed() {
  local md="$COMMANDS_DIR/execute.md"
  local region first last hint hits n stray="" loud="" flag=""

  # --- 12a: the flag's variable is gone from every command file -------------
  flag="$(grep -rn 'PUSH_FLAG' "$COMMANDS_DIR" 2>/dev/null | sed -e "s|^$COMMANDS_DIR/||" | cut -c1-160)"
  assert_no_findings "$flag" \
    "Check 12a — PUSH_FLAG appears nowhere under commands/" \
    "The flag is removed, not deprecated. Nothing may read it, in a command body or a reference."

  # --- 12b: the frontmatter no longer advertises it ------------------------
  hint="$(grep -n '^argument-hint:' "$md" | grep -F -- '--push' | sed 's|^|execute.md:|' | cut -c1-160)"
  assert_no_findings "$hint" \
    "Check 12b — execute.md's argument-hint no longer advertises --push" \
    "Autocomplete would keep offering a flag whose only remaining behavior is to fail the run."

  # --- 12c: every surviving literal sits inside the refusal branch ----------
  region="$(md_section "$md" "$PUSH_REFUSAL_SECTION")"
  if [ -z "$region" ]; then
    # Both legs must report. A missing section leaves 12d with nothing to grep,
    # and an assertion that passes because it found nowhere to look is not
    # coverage — it is the exact shape this check exists to reject elsewhere.
    stray="execute.md has no '$PUSH_REFUSAL_SECTION' section, so nothing confines the flag's remaining literals"$'\n'
    loud="execute.md has no '$PUSH_REFUSAL_SECTION' section, so there is no refusal to exit non-zero or to name a replacement"$'\n'
  else
    first="$(printf '%s\n' "$region" | head -1 | cut -f1)"
    last="$(printf '%s\n' "$region" | tail -1 | cut -f1)"
    hits="$(grep -n -- '--push' "$md" | cut -d: -f1)"
    for n in $hits; do
      { [ "$n" -ge "$first" ] && [ "$n" -le "$last" ]; } \
        || stray="$stray execute.md:$n — a --push literal sits outside the refusal branch (execute.md:$first-$last)"$'\n'
    done

    printf '%s\n' "$region" | grep -qF 'exit 1' \
      || loud="$loud execute.md: the refusal branch does not exit non-zero — a pipeline that used to get a push would get silence instead"$'\n'
    printf '%s\n' "$region" | grep -qF '/aimi:open-pr' \
      || loud="$loud execute.md: the refusal message never names /aimi:open-pr, so it says what stopped working without saying what replaced it"$'\n'
    printf '%s\n' "$region" | grep -qF 'no flag re-enables it' \
      || loud="$loud execute.md: the refusal message no longer states that no flag re-enables publishing"$'\n'
  fi

  assert_no_findings "$(printf '%s' "$stray")" \
    "Check 12c — every surviving --push literal in execute.md sits inside the refusal branch" \
    "A literal outside it means the flag is still parsed, hinted at, or documented as usable somewhere."

  assert_no_findings "$(printf '%s' "$loud")" \
    "Check 12d — the refusal exits non-zero and its message names the replacement behavior" \
    "A refusal that matches the token but emits no actionable message is the silent no-op this phase removed."
}

# ---------------------------------------------------------------------------
# Check 13 — completion reports name /aimi:open-pr, and next.md publishes
# nothing.
#
# Measured yield: 2 of its 3 assertions fail against 3bde8f6 (13a on execute.md
# lines 555, 3729 and 3946; 13c on next.md's `git push -u origin` at 352), 0
# here. 13b holds on both trees by design — it exists so that a future edit
# cannot swap an /aimi:open-pr recommendation back to a raw forge command
# without tripping something.
#
# THE EXEMPTIONS ARE THE DELICATE PART
#
# `gh pr create` is banned as a RECOMMENDATION, not as a string. It is the
# GitHub adapter's own implementation in commands/references/forge-contract.md
# and the call open-pr.md documents, and both are correct there — so the scan
# is deliberately scoped to the two files that address the user at the end of a
# run, rather than written as a directory sweep with a denylist. Widening it
# later means widening the file list, not loosening the pattern.
# ---------------------------------------------------------------------------
COMPLETION_REPORT_FILES='execute.md next.md'

check_completion_names_open_pr() {
  local f path raw="" recs="" pushes=""
  local line

  # --- 13a: no raw forge command is recommended to the user ----------------
  raw="$(
    for f in $COMPLETION_REPORT_FILES; do
      grep -n 'gh pr create' "$COMMANDS_DIR/$f" 2>/dev/null | cut -c1-160 | sed "s|^|$f:|"
    done
  )"
  assert_no_findings "$raw" \
    "Check 13a — no completion path in execute.md or next.md recommends a raw gh pr create" \
    "/aimi:open-pr is the only publish entry point; a raw forge command bypasses the confirmation and works on exactly one forge."

  # --- 13b: every PR recommendation names the command instead --------------
  for f in $COMPLETION_REPORT_FILES; do
    path="$COMMANDS_DIR/$f"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        *'/aimi:open-pr'*) ;;
        *) recs="$recs $f:$line"$'\n' ;;
      esac
    done <<EOF
$(grep -nE '^[[:space:]]*(-[[:space:]]+)?(Open|Create) (a )?PRs?([ :])' "$path" 2>/dev/null | cut -c1-160)
EOF
  done
  assert_no_findings "$(printf '%s' "$recs")" \
    "Check 13b — every pull-request recommendation in those files names /aimi:open-pr" \
    "Write the short /aimi:open-pr form; publish-confirmation.md § Always Name /aimi:open-pr requires it on every completion path."

  # --- 13c: next.md publishes nothing at all -------------------------------
  pushes="$(grep -n 'git push' "$COMMANDS_DIR/next.md" 2>/dev/null \
    | grep -vF 'never pushes' | cut -c1-160 | sed 's|^|next.md:|')"
  assert_no_findings "$pushes" \
    "Check 13c — next.md contains no git push at all" \
    "/aimi:next completes stories; publishing is /aimi:open-pr's job and needs a confirmation next.md does not raise."
}

# ---------------------------------------------------------------------------
# Check 14 — no picker markup under commands/references/.
#
# Measured yield: 1 hit against 3bde8f6 (container-execution.md's own
# `use **AskUserQuestion**` at :160), 0 here. This generalizes check 9's
# forge-contract.md-only assertion to the whole directory, so a reference file
# added later is covered without a code change.
#
# SCOPED TO WHAT IS ACTUALLY TRUE, DELIBERATELY
#
# The banned token is the BOLD picker-invocation form, which is the exact
# string interactivity.md mandates for a call site and the first pattern
# install.sh's rewriter keys on. `interactivity.md` itself is exempt: it is the
# contract that DEFINES that literal and has to quote it to do so.
#
# Bare, unbolded `AskUserQuestion` mentions are NOT banned here and several
# survive: user-communication.md and interactivity.md discuss the tool by name,
# and container-execution.md's agent branch says "skip AskUserQuestion", which
# is a statement that no question is asked. One genuine exception is recorded
# rather than papered over — cli-path-resolution.md:211-226 instructs a real
# picker inside a reference file, predating this phase and untouched by it.
# This check does not cover that, and a green run here is not a claim that the
# directory is free of untranslated pickers.
# ---------------------------------------------------------------------------
PICKER_LITERAL_EXEMPT='interactivity.md'

check_references_carry_no_picker() {
  local findings f rel
  findings="$(
    find "$COMMANDS_DIR/references" -name '*.md' | sort | while IFS= read -r f; do
      rel="${f##*/}"
      [ "$rel" = "$PICKER_LITERAL_EXEMPT" ] && continue
      grep -nF '**AskUserQuestion**' "$f" 2>/dev/null | cut -c1-160 | sed "s|^|references/$rel:|"
    done
  )"
  assert_no_findings "$findings" \
    "Check 14 — no reference file carries picker markup (interactivity.md defines the literal and is exempt)" \
    "install.sh copies commands/references/ verbatim and never runs translate_command_body over it, so this picker reaches OpenCode naming a tool that host does not have. Move it into a command body."
}

# ---------------------------------------------------------------------------
# The baseline is only honest if it shrinks. An entry that no longer matches
# anything means the underlying issue was fixed (or a heading was renamed) and
# the line must go, otherwise the baseline slowly becomes a permanent excuse.
# ---------------------------------------------------------------------------
check_baseline_current() {
  local stale
  stale="$(
    printf '%s\n' "$BASELINE_KEYS" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF "$line" "$MATCHED_BASELINE" 2>/dev/null || printf '%s\n' "$line"
    done
  )"
  assert_no_findings "$stale" \
    "Baseline is current — every grandfathered entry still matches something" \
    "These no longer fire. Delete them from $(basename "$BASELINE_FILE")."
}

main() {
  echo "Extracting bash-fenced blocks from commands/..."
  extract_blocks
  scan_blocks
  load_baseline
  : > "$MATCHED_BASELINE"

  local nblocks nfiles
  nblocks="$(wc -l < "$INDEX" | tr -d ' ')"
  nfiles="$(cut -f2 "$INDEX" | sort -u | wc -l | tr -d ' ')"
  echo "  $nblocks blocks across $nfiles command files"
  echo ""

  echo "--- Extraction Sanity ---"
  assert_eq "true" "$([ "$nblocks" -gt 200 ] && echo true || echo false)" \
    "Extractor found the expected order of magnitude of blocks (>200)"
  assert_eq "true" "$([ -f "$BASELINE_FILE" ] && echo true || echo false)" \
    "Baseline file exists at scripts/$(basename "$BASELINE_FILE")"

  echo ""
  echo "--- Block Checks ---"
  check_syntax
  check_portability
  check_loop_scope
  check_unassigned
  check_argument_gate_same_block
  check_phase_branch_derivation
  check_reverify_branch
  check_plan_branchname_slugified
  check_forge_account_picker
  check_phase_publish_gate
  check_container_push_confirmation
  check_push_flag_removed
  check_completion_names_open_pr
  check_references_carry_no_picker

  echo ""
  echo "--- Baseline Hygiene ---"
  check_baseline_current

  echo ""
  echo "================================================"
  echo -e "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "================================================"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
