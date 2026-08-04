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
