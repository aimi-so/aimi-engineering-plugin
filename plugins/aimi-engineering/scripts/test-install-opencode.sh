#!/usr/bin/env bash
set -uo pipefail

# test-install-opencode.sh - install.sh --to opencode, reference translation
#
# WHAT IT CHECKS
#
# install.sh translates command bodies for OpenCode, and (since the reference
# allowlist) a named subset of commands/references/ as well. This suite is the
# first one that runs install.sh at all. It installs into throwaway HOME and
# XDG roots with AIMI_CONFIG_DIR and CLAUDE_CONFIG_DIR unset, so it can never
# touch the operator's real OpenCode config, and asserts:
#
#   real tree
#     - the install exits 0
#     - the four doc references (cli-path-resolution.md, container-execution.md,
#       user-communication.md, dependency-setup.md) carry no AskUserQuestion literal and no
#       `Task subagent_type="aimi-engineering:` literal
#     - cli-path-resolution.md still documents the Claude Code cache path
#     - interactivity.md is byte-identical to the source (it documents the
#       strings the rewrite targets, so it is excluded on purpose)
#     - the installed aimi/plan.md body still starts with the OpenCode Agent
#       Invocation preamble and carries no AskUserQuestion literal
#   effort forwarding (real tree)
#     - the installed preamble's Step 0 fences, run in bash against stub CLIs,
#       give the configured effort per category, and `inherit` for every
#       category when resolve-efforts prints nothing, a long help text or a JSON
#       value that is not an object, or when the CLI cannot be run
#     - the effort annotations of aimi/review.md and the execute wave loop
#       survive the translation, the AGENT_EFFORTS echo line of
#       cli-path-resolution.md is kept, and tools/aimi-task.ts is byte-identical
#   fixture plugin tree (plan/x.md and execute/y.md carrying the literals)
#     - the plan/*.md and execute/*.md globs are translated, config-dir rewrite
#       included, with no agent-invocation preamble and no general-purpose ->
#       general swap, and the install reports both files
#   fixture plugin tree with no references/execute/ directory
#     - installs with exit 0 and translates the plan files only
#     - a reference outside the allowlist stays byte-identical
#     - the dry run lists the translated files and creates nothing
#     - uninstall removes the translated references
#     - a repeat install over an existing one yields the same content
#
# Standalone, like test-command-size.sh: not part of test-aimi-cli.sh's PARTS.
# The fixture copies install.sh next to itself because install.sh resolves its
# plugin source from its own directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
SRC_PLUGIN="$REPO_ROOT/plugins/aimi-engineering"

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

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ${GREEN}PASS${NC} $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ${RED}FAIL${NC} $1"; [ -n "${2:-}" ] && echo "       $2"; return 0; }

assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected '$1', got '$2'"; fi
}
assert_file_lacks() { # file literal label
  if grep -qF -- "$2" "$1"; then fail "$3" "'$2' still present in $1"; else pass "$3"; fi
}
assert_file_has() { # file literal label
  if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3" "'$2' missing from $1"; fi
}
assert_same_file() { # a b label
  if cmp -s "$1" "$2"; then pass "$3"; else fail "$3" "$1 differs from $2"; fi
}

TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]+"${TMPDIRS[@]}"}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

new_tmp() {
  local d
  d=$(mktemp -d)
  TMPDIRS+=("$d")
  mkdir -p "$d/home"
  : > "$d/home/.bashrc"
  printf '%s\n' "$d"
}

# run_install <install.sh path> <root> [args...] -- sets OUT and RC
run_install() {
  local script="$1" root="$2"
  shift 2
  OUT=$(env -u AIMI_CONFIG_DIR -u CLAUDE_CONFIG_DIR -u CLAUDECODE \
    HOME="$root/home" XDG_CONFIG_HOME="$root/xdg" \
    bash "$script" --to opencode "$@" 2>&1)
  RC=$?
}

# ---------------------------------------------------------------------------
echo "== real tree: install into a throwaway root"
# ---------------------------------------------------------------------------
REAL=$(new_tmp)
run_install "$INSTALL_SH" "$REAL"
assert_eq "0" "$RC" "real tree: install exits 0"

REFS="$REAL/xdg/opencode/plugins/aimi-engineering/commands/references"
for doc in cli-path-resolution.md container-execution.md user-communication.md dependency-setup.md; do
  assert_file_lacks "$REFS/$doc" "AskUserQuestion" "real tree: $doc has no AskUserQuestion literal"
  assert_file_lacks "$REFS/$doc" 'Task subagent_type="aimi-engineering:' "real tree: $doc has no Task subagent_type literal"
done
assert_file_has "$REFS/cli-path-resolution.md" '${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/' \
  "real tree: cli-path-resolution.md keeps the Claude Code cache path"
assert_file_has "$SRC_PLUGIN/commands/references/dependency-setup.md" "AskUserQuestion" \
  "real tree: dependency-setup.md source names the picker"
assert_file_has "$REFS/dependency-setup.md" "deps-recipe-record" \
  "real tree: dependency-setup.md is installed"
assert_same_file "$SRC_PLUGIN/commands/references/interactivity.md" "$REFS/interactivity.md" \
  "real tree: interactivity.md is byte-identical to the source"
assert_file_has "$REFS/interactivity.md" "AskUserQuestion" \
  "real tree: interactivity.md still names AskUserQuestion"

PLAN_INSTALLED="$REAL/xdg/opencode/commands/aimi/plan.md"
# The preamble opens the body, i.e. the line right after the frontmatter block.
assert_eq "## OpenCode Agent Invocation" "$(sed -n 4p "$PLAN_INSTALLED")" \
  "real tree: aimi/plan.md body still starts with the agent-invocation preamble"
assert_file_lacks "$PLAN_INSTALLED" "AskUserQuestion" "real tree: aimi/plan.md has no AskUserQuestion literal"

# ---------------------------------------------------------------------------
echo "== effort forwarding: preamble Step 0 and annotation survival"
# ---------------------------------------------------------------------------
# Step 0's fences (everything between "### Step 0" and "#### First-run"),
# concatenated, then the five model and five effort variables printed.
STEP0="$REAL/step0.sh"
awk '/^### Step 0/ { on = 1; next } /^#### First-run/ { on = 0 } on && /^```/ { infence = !infence; next } on && infence { print }' \
  "$PLAN_INSTALLED" > "$STEP0"
assert_eq "yes" "$([ -s "$STEP0" ] && echo yes || echo no)" "effort: Step 0 fences extracted from aimi/plan.md"
cat >> "$STEP0" <<'EOS'
for v in RESEARCH REVIEW DESIGN WORKFLOW EXECUTOR; do
  eval "m=\$${v}_MODEL e=\$${v}_EFFORT"
  printf '%s_MODEL=%s %s_EFFORT=%s\n' "$v" "$m" "$v" "$e"
done
EOS

# run_step0 <file holding the resolve-efforts branch body> -- sets OUT
run_step0() {
  local d stub
  d=$(new_tmp)
  stub="$d/aimi-cli.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$1" in\n'
    printf '  resolve-models) printf "%%s\\n" '"'"'{"research":"m1","review":"m2","design":"inherit","workflow":"m4","executor":"m5"}'"'"' ;;\n'
    printf '  resolve-efforts) %s ;;\n' "$1"
    printf 'esac\n'
  } > "$stub"
  chmod +x "$stub"
  OUT=$(AIMI_CLI="$stub" bash "$STEP0" 2>&1)
}
ALL_INH="RESEARCH_MODEL=m1 RESEARCH_EFFORT=inherit
REVIEW_MODEL=m2 REVIEW_EFFORT=inherit
DESIGN_MODEL=inherit DESIGN_EFFORT=inherit
WORKFLOW_MODEL=m4 WORKFLOW_EFFORT=inherit
EXECUTOR_MODEL=m5 EXECUTOR_EFFORT=inherit"
run_step0 "echo '{\"research\":\"low\",\"review\":\"high\",\"design\":\"inherit\",\"workflow\":\"medium\",\"executor\":\"max\"}'"
assert_eq "RESEARCH_MODEL=m1 RESEARCH_EFFORT=low
REVIEW_MODEL=m2 REVIEW_EFFORT=high
DESIGN_MODEL=inherit DESIGN_EFFORT=inherit
WORKFLOW_MODEL=m4 WORKFLOW_EFFORT=medium
EXECUTOR_MODEL=m5 EXECUTOR_EFFORT=max" "$OUT" "effort: a configured category gives its value, the others inherit"
run_step0 ":"
assert_eq "$ALL_INH" "$OUT" "effort: resolve-efforts printing nothing gives inherit everywhere"
run_step0 'for i in $(seq 1 300); do echo "help line $i"; done'
assert_eq "$ALL_INH" "$OUT" "effort: a long help text gives inherit everywhere"
run_step0 "echo '[\"high\"]'"
assert_eq "$ALL_INH" "$OUT" "effort: a JSON array gives inherit everywhere"
run_step0 "echo '\"high\"'"
assert_eq "$ALL_INH" "$OUT" "effort: a JSON string gives inherit everywhere"
OUT=$(AIMI_CLI="$REAL/does-not-exist" bash "$STEP0" 2>/dev/null)
assert_eq "5" "$(printf '%s\n' "$OUT" | grep -c '_EFFORT=inherit$')" \
  "effort: a CLI that cannot be run gives inherit everywhere"

assert_file_has "$PLAN_INSTALLED" 'RESOLVED_EFFORTS=$($AIMI_CLI resolve-efforts 2>/dev/null | head -n 1)' \
  "effort: preamble resolves RESOLVED_EFFORTS through head -n 1"
assert_file_has "$PLAN_INSTALLED" 'variant="[$EXECUTOR_EFFORT' "effort: the aimi-task example carries variant="

# effort annotations survive the translation, in order
effort_tokens() { grep -o 'effort: <AGENT_EFFORTS\.[a-z]* when not "inherit">' "$1"; }
INST_PLUGIN="$REAL/xdg/opencode/plugins/aimi-engineering"
for pair in "$SRC_PLUGIN/commands/review.md:$REAL/xdg/opencode/commands/aimi/review.md" \
            "$SRC_PLUGIN/commands/references/execute/step-4-wave-execution-loop.md:$INST_PLUGIN/commands/references/execute/step-4-wave-execution-loop.md"; do
  src="${pair%%:*}"; dst="${pair#*:}"
  n=$(effort_tokens "$src" | wc -l | tr -d ' ')
  assert_eq "yes" "$([ "$n" -ge 1 ] && echo yes || echo no)" "effort: $(basename "$src") source has effort tokens"
  assert_eq "$(effort_tokens "$src")" "$(effort_tokens "$dst")" "effort: $(basename "$src") tokens survive in order"
done
assert_file_has "$REFS/cli-path-resolution.md" 'echo "AGENT_EFFORTS=$($AIMI_CLI resolve-efforts | head -n 1)"' \
  "effort: cli-path-resolution.md keeps the AGENT_EFFORTS echo line"
assert_same_file "$SRC_PLUGIN/tools/aimi-task.ts" "$REAL/xdg/opencode/tools/aimi-task.ts" \
  "effort: installed aimi-task.ts is byte-identical to the source"

# ---------------------------------------------------------------------------
echo "== fixture plugin tree: glob mode, dry run, uninstall, repeat install"
# ---------------------------------------------------------------------------
FIX=$(new_tmp)
FP="$FIX/repo/plugins/aimi-engineering"
mkdir -p "$FP/.claude-plugin" "$FP/scripts" "$FP/commands/references/plan" "$FP/commands/references/execute"
cp "$INSTALL_SH" "$FIX/repo/install.sh"
printf '{"name":"aimi-engineering","version":"0.0.1"}\n' > "$FP/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "{}\\n"\n' > "$FP/scripts/aimi-cli.sh"
chmod +x "$FP/scripts/aimi-cli.sh"
printf -- '---\ndescription: fixture\n---\nBody\n' > "$FP/commands/fixture.md"

# Trailing newline count matters: the rewrite must keep it exactly.
printf 'Ask with AskUserQuestion here.\nSpawn: Task subagent_type="aimi-engineering:research:x" with general-purpose.\nCLI dir: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts\nRoot: ${CLAUDE_PLUGIN_ROOT}/scripts\n\n\n' \
  > "$FP/commands/references/plan/x.md"
cp "$FP/commands/references/plan/x.md" "$FP/commands/references/execute/y.md"
printf 'Outside the allowlist: AskUserQuestion and ${CLAUDE_CONFIG_DIR:-$HOME/.claude} stay.\n' \
  > "$FP/commands/references/not-allowlisted.md"

# dry run first: lists the match, creates nothing under the target root
run_install "$FIX/repo/install.sh" "$FIX" --dry-run
assert_eq "0" "$RC" "fixture: dry run exits 0"
case "$OUT" in
  *"Would translate reference: plan/x.md"*) pass "fixture: dry run lists plan/x.md" ;;
  *) fail "fixture: dry run lists plan/x.md" "$OUT" ;;
esac
case "$OUT" in
  *"Would translate reference: execute/y.md"*) pass "fixture: dry run lists execute/y.md" ;;
  *) fail "fixture: dry run lists execute/y.md" "$OUT" ;;
esac
case "$OUT" in
  *"Would translate reference: not-allowlisted.md"*) fail "fixture: dry run must not list not-allowlisted.md" ;;
  *) pass "fixture: dry run does not list not-allowlisted.md" ;;
esac
if [ -e "$FIX/xdg" ]; then fail "fixture: dry run creates nothing under the XDG root"; else pass "fixture: dry run creates nothing under the XDG root"; fi

# real dry run against the shipped tree: at least the three doc references
DRY=$(new_tmp)
run_install "$INSTALL_SH" "$DRY" --dry-run
assert_eq "0" "$RC" "real tree: dry run exits 0"
assert_eq "yes" "$([ "$(printf '%s\n' "$OUT" | grep -c 'Would translate reference')" -ge 3 ] && echo yes || echo no)" \
  "real tree: dry run lists at least three references"
if [ -e "$DRY/xdg" ]; then fail "real tree: dry run creates nothing under the XDG root"; else pass "real tree: dry run creates nothing under the XDG root"; fi

# install
run_install "$FIX/repo/install.sh" "$FIX"
assert_eq "0" "$RC" "fixture: install exits 0"
case "$OUT" in
  *"Translated 2 reference file(s)"*) pass "fixture: install reports Translated 2 reference file(s)" ;;
  *) fail "fixture: install reports Translated 2 reference file(s)" "$OUT" ;;
esac
FREFS="$FIX/xdg/opencode/plugins/aimi-engineering/commands/references"
X="$FREFS/plan/x.md"
assert_file_lacks "$X" "AskUserQuestion" "fixture: plan/x.md has no AskUserQuestion literal"
assert_file_lacks "$X" 'Task subagent_type="aimi-engineering:' "fixture: plan/x.md has no Task subagent_type literal"
assert_file_has "$X" 'aimi-task subagent_type="aimi-engineering:research:x"' "fixture: plan/x.md spawn rewritten to aimi-task"
assert_file_has "$X" '${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/scripts' "fixture: plan/x.md carries the config-dir rewrite"
assert_file_lacks "$X" 'CLAUDE_CONFIG_DIR' "fixture: plan/x.md has no CLAUDE_CONFIG_DIR token left"
assert_file_has "$X" '${AIMI_PLUGIN_DIR}/scripts' "fixture: plan/x.md plugin root rewritten"
assert_file_lacks "$X" "OpenCode Agent Invocation" "fixture: plan/x.md has no agent-invocation preamble"
assert_file_has "$X" "general-purpose" "fixture: plan/x.md keeps general-purpose (no swap)"
assert_eq "Ask with the question tool here." "$(sed -n 1p "$X")" "fixture: plan/x.md first line is the translated picker sentence"
assert_eq "6" "$(wc -l < "$X" | tr -d ' ')" "fixture: plan/x.md keeps its trailing newlines"
Y="$FREFS/execute/y.md"
assert_file_lacks "$Y" "AskUserQuestion" "fixture: execute/y.md has no AskUserQuestion literal"
assert_file_lacks "$Y" 'Task subagent_type="aimi-engineering:' "fixture: execute/y.md has no Task subagent_type literal"
assert_file_has "$Y" 'aimi-task subagent_type="aimi-engineering:research:x"' "fixture: execute/y.md spawn rewritten to aimi-task"
assert_file_has "$Y" '${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}/scripts' "fixture: execute/y.md carries the config-dir rewrite"
assert_file_lacks "$Y" 'CLAUDE_CONFIG_DIR' "fixture: execute/y.md has no CLAUDE_CONFIG_DIR token left"
assert_file_has "$Y" '${AIMI_PLUGIN_DIR}/scripts' "fixture: execute/y.md plugin root rewritten"
assert_file_lacks "$Y" "OpenCode Agent Invocation" "fixture: execute/y.md has no agent-invocation preamble"
assert_file_has "$Y" "general-purpose" "fixture: execute/y.md keeps general-purpose (no swap)"
assert_same_file "$FP/commands/references/not-allowlisted.md" "$FREFS/not-allowlisted.md" \
  "fixture: a reference outside the allowlist is byte-identical"

# repeat install: same translated content
cp "$X" "$FIX/x.first"
run_install "$FIX/repo/install.sh" "$FIX"
assert_eq "0" "$RC" "fixture: repeat install exits 0"
assert_same_file "$FIX/x.first" "$X" "fixture: repeat install yields the same translated content"

# uninstall removes the translated references
run_install "$FIX/repo/install.sh" "$FIX" --uninstall --from opencode
if [ "$RC" -ne 0 ]; then
  # --uninstall takes no --to; retry in the documented form
  OUT=$(env -u AIMI_CONFIG_DIR -u CLAUDE_CONFIG_DIR -u CLAUDECODE \
    HOME="$FIX/home" XDG_CONFIG_HOME="$FIX/xdg" \
    bash "$FIX/repo/install.sh" --uninstall --from opencode 2>&1)
  RC=$?
fi
assert_eq "0" "$RC" "fixture: uninstall exits 0"
if [ -e "$X" ] || [ -d "$FIX/xdg/opencode/plugins/aimi-engineering" ]; then
  fail "fixture: uninstall removes the translated references"
else
  pass "fixture: uninstall removes the translated references"
fi

# ---------------------------------------------------------------------------
echo "== fixture plugin tree with no references/execute/ directory"
# ---------------------------------------------------------------------------
NX=$(new_tmp)
NP="$NX/repo/plugins/aimi-engineering"
mkdir -p "$NP/.claude-plugin" "$NP/scripts" "$NP/commands/references/plan"
cp "$INSTALL_SH" "$NX/repo/install.sh"
printf '{"name":"aimi-engineering","version":"0.0.1"}\n' > "$NP/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "{}\\n"\n' > "$NP/scripts/aimi-cli.sh"
chmod +x "$NP/scripts/aimi-cli.sh"
printf -- '---\ndescription: fixture\n---\nBody\n' > "$NP/commands/fixture.md"
cp "$FP/commands/references/plan/x.md" "$NP/commands/references/plan/x.md"
run_install "$NX/repo/install.sh" "$NX"
assert_eq "0" "$RC" "no-execute fixture: install exits 0"
case "$OUT" in
  *"Translated 1 reference file(s)"*) pass "no-execute fixture: install reports Translated 1 reference file(s)" ;;
  *) fail "no-execute fixture: install reports Translated 1 reference file(s)" "$OUT" ;;
esac

# ---------------------------------------------------------------------------
echo "== agent permission blocks"
# ---------------------------------------------------------------------------
AGENTS_DIR="$REAL/xdg/opencode/agents"
OC_NAMES="read grep glob bash edit webfetch websearch task todowrite skill"

# perm_get <agent file> <key> -- the allow/deny value of a permission key
perm_get() {
  awk -v k="$2" '
    /^---$/ { fm++; next }
    fm == 1 && /^permission:/ { inperm = 1; next }
    fm == 1 && inperm && /^  [a-z]+: / { gsub(/^  /, ""); split($0, a, ": "); if (a[1] == k) { print a[2]; exit } next }
    fm == 1 && inperm { inperm = 0 }
  ' "$1"
}

# Every source agent that declares a tools line: its installed twin carries an
# explicit allow or deny for all ten names.
WITH_TOOLS=0
for src in "$SRC_PLUGIN"/agents/*/*.md; do
  grep -q '^tools:' "$src" || continue
  WITH_TOOLS=$((WITH_TOOLS + 1))
  base=$(basename "$src")
  inst="$AGENTS_DIR/$base"
  ok=yes
  for n in $OC_NAMES; do
    v=$(perm_get "$inst" "$n")
    case "$v" in allow|deny) ;; *) ok=no ;; esac
  done
  assert_eq "yes" "$ok" "real tree: $base carries an explicit permission for all ten names"
done
assert_eq "20" "$WITH_TOOLS" "real tree: twenty agent sources declare a tools line"

AUD="$AGENTS_DIR/aimi-cross-story-auditor.md"
assert_eq "allow" "$(perm_get "$AUD" read)" "real tree: auditor read is allow"
assert_eq "allow" "$(perm_get "$AUD" edit)" "real tree: auditor edit is allow (it writes audit-result.json)"
assert_eq "deny" "$(perm_get "$AUD" bash)" "real tree: auditor bash is deny"
VER="$AGENTS_DIR/aimi-scope-negative-verifier.md"
assert_eq "deny" "$(perm_get "$VER" edit)" "real tree: scope verifier edit is deny"
for n in read grep bash; do
  assert_eq "allow" "$(perm_get "$VER" "$n")" "real tree: scope verifier $n is allow"
done
for rev in aimi-correctness-reviewer aimi-security-reviewer aimi-performance-reviewer aimi-maintainability-reviewer aimi-project-standards-reviewer aimi-frontend-races-reviewer aimi-agent-native-reviewer aimi-data-migration-reviewer aimi-deployment-verification-agent; do
  assert_eq "deny" "$(perm_get "$AGENTS_DIR/$rev.md" edit)" "real tree: $rev edit is deny"
  assert_eq "allow" "$(perm_get "$AGENTS_DIR/$rev.md" bash)" "real tree: $rev bash is allow (it may run a check)"
done
RES="$AGENTS_DIR/aimi-codebase-researcher.md"
assert_eq "allow" "$(perm_get "$RES" edit)" "real tree: codebase researcher edit is allow"
assert_eq "allow" "$(perm_get "$RES" bash)" "real tree: codebase researcher bash is allow"

# No installed agent carries a tools or allowed-tools key.
LEAK=0
for f in "$AGENTS_DIR"/*.md; do
  if awk '/^---$/ { fm++; next } fm == 1 && /^(tools|allowed-tools):/ { found = 1 } END { exit !found }' "$f"; then
    LEAK=$((LEAK + 1))
  fi
done
assert_eq "0" "$LEAK" "real tree: no installed agent carries a tools or allowed-tools key"

# An agent with no tools line has no permission block.
NOTOOLS=""
for src in "$SRC_PLUGIN"/agents/*/*.md; do
  grep -q '^tools:' "$src" || { NOTOOLS="$AGENTS_DIR/$(basename "$src")"; break; }
done
assert_eq "yes" "$([ -f "$NOTOOLS" ] && echo yes || echo no)" "real tree: found an agent source without a tools line"
assert_file_lacks "$NOTOOLS" "permission:" "real tree: an agent without a tools line has no permission block"

# Fixture: unmapped tool fails the install and writes nothing for that agent;
# an mcp__ pattern is skipped with a warning; a YAML list is accepted.
AX=$(new_tmp)
AP="$AX/repo/plugins/aimi-engineering"
mkdir -p "$AP/.claude-plugin" "$AP/scripts" "$AP/commands" "$AP/agents/review"
cp "$INSTALL_SH" "$AX/repo/install.sh"
printf '{"name":"aimi-engineering","version":"0.0.1"}\n' > "$AP/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "{}\\n"\n' > "$AP/scripts/aimi-cli.sh"
chmod +x "$AP/scripts/aimi-cli.sh"
printf -- '---\ndescription: fixture\n---\nBody\n' > "$AP/commands/fixture.md"
printf -- '---\nname: fx\ndescription: listed\ntools:\n  - Read\n  - mcp__x__*\n---\nBody\n' > "$AP/agents/review/aimi-fx-list.md"
run_install "$AX/repo/install.sh" "$AX"
assert_eq "0" "$RC" "agent fixture: YAML list and mcp__ pattern install exits 0"
case "$OUT" in
  *"mcp__x__*"*) pass "agent fixture: mcp__ pattern warns" ;;
  *) fail "agent fixture: mcp__ pattern warns" "$OUT" ;;
esac
FXL="$AX/xdg/opencode/agents/aimi-fx-list.md"
assert_eq "allow" "$(perm_get "$FXL" read)" "agent fixture: YAML list read is allow"
assert_eq "deny" "$(perm_get "$FXL" edit)" "agent fixture: YAML list edit is deny"

BAD=$(new_tmp)
BP="$BAD/repo/plugins/aimi-engineering"
mkdir -p "$BP/.claude-plugin" "$BP/scripts" "$BP/commands" "$BP/agents/review"
cp "$INSTALL_SH" "$BAD/repo/install.sh"
cp "$AP/.claude-plugin/plugin.json" "$BP/.claude-plugin/plugin.json"
cp "$AP/scripts/aimi-cli.sh" "$BP/scripts/aimi-cli.sh"
cp "$AP/commands/fixture.md" "$BP/commands/fixture.md"
printf -- '---\nname: bad\ndescription: bad\ntools: Read, Frobnicate\n---\nBody\n' > "$BP/agents/review/aimi-bad.md"
run_install "$BAD/repo/install.sh" "$BAD"
if [ "$RC" -ne 0 ]; then pass "agent fixture: unmapped tool fails the install"; else fail "agent fixture: unmapped tool fails the install" "$OUT"; fi
case "$OUT" in
  *"aimi-bad.md"*"Frobnicate"*) pass "agent fixture: failure names the agent file and the tool" ;;
  *) fail "agent fixture: failure names the agent file and the tool" "$OUT" ;;
esac
if [ -e "$BAD/xdg/opencode/agents/aimi-bad.md" ]; then
  fail "agent fixture: no destination file written for the failing agent"
else
  pass "agent fixture: no destination file written for the failing agent"
fi

# ---------------------------------------------------------------------------
echo "== upgrade: agents and skills the plugin dropped leave the destination"
# ---------------------------------------------------------------------------
# The installer used to only add files, so a release that removed or renamed an
# agent or a skill left the old one installed and offered to the model.
UP=$(new_tmp)
run_install "$INSTALL_SH" "$UP"
assert_eq "0" "$RC" "upgrade: first install exits 0"
AG="$UP/xdg/opencode/agents"
SK="$UP/xdg/opencode/skills"
PL="$UP/xdg/opencode/plugins/aimi-engineering"
printf -- '---\ndescription: retired\n---\nold\n' > "$AG/aimi-kieran-rails-reviewer.md"
mkdir -p "$SK/aimi-rclone" "$PL/skills/rclone" "$PL/agents/review"
printf 'old\n' > "$SK/aimi-rclone/SKILL.md"
printf 'old\n' > "$PL/skills/rclone/SKILL.md"
printf 'old\n' > "$PL/agents/review/aimi-kieran-rails-reviewer.md"
printf 'mine\n' > "$AG/my-own-agent.md"

run_install "$INSTALL_SH" "$UP" --dry-run
assert_eq "0" "$RC" "upgrade: dry run exits 0"
case "$OUT" in
  *"Would remove retired agent: aimi-kieran-rails-reviewer.md"*"Would remove retired skill: aimi-rclone"*) pass "upgrade: dry run names the retired agent and skill" ;;
  *) fail "upgrade: dry run names the retired agent and skill" "$OUT" ;;
esac
if [ -e "$AG/aimi-kieran-rails-reviewer.md" ] && [ -d "$SK/aimi-rclone" ]; then
  pass "upgrade: dry run removes nothing"
else
  fail "upgrade: dry run removes nothing"
fi

run_install "$INSTALL_SH" "$UP"
assert_eq "0" "$RC" "upgrade: second install exits 0"
for gone in "$AG/aimi-kieran-rails-reviewer.md" "$SK/aimi-rclone" "$PL/skills/rclone" "$PL/agents/review/aimi-kieran-rails-reviewer.md"; do
  if [ -e "$gone" ]; then fail "upgrade: retired path is gone: ${gone#$UP/}"; else pass "upgrade: retired path is gone: ${gone#$UP/}"; fi
done
if [ -f "$AG/my-own-agent.md" ] && [ -f "$AG/aimi-correctness-reviewer.md" ] && [ -f "$SK/aimi-git-worktree/SKILL.md" ]; then
  pass "upgrade: a file of the user's and the current agents and skills stay"
else
  fail "upgrade: a file of the user's and the current agents and skills stay"
fi

echo
echo "Results: ${GREEN}${TESTS_PASSED} passed${NC}, ${RED}${TESTS_FAILED} failed${NC}"
[ "$TESTS_FAILED" -eq 0 ]
