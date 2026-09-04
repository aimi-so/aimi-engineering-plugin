#!/usr/bin/env bash
set -euo pipefail

# aimi-cli.sh - Deterministic task file operations for Aimi
#
# This script handles all jq queries and state management for the Aimi
# engineering plugin, preventing AI hallucination of bash commands.
# Operates on v3 task schema exclusively.

AIMI_DIR=".aimi"
TASKS_DIR="$AIMI_DIR/tasks"

# Absolute directory containing THIS script, resolved right here at the top --
# before find_aimi_root (called later, from main()) ever changes the cwd.
#
# ${BASH_SOURCE[0]:-$0} can be a RELATIVE path: a caller inside a nested
# worktree invoking `bash plugins/aimi-engineering/scripts/aimi-cli.sh` hands
# bash that exact relative string. find_aimi_root then walks UP from the cwd
# looking for .aimi/ -- and a worktree deliberately has no .aimi/ of its own
# (see worktree-manager.sh's create_worktree), so the walk does not stop at
# the worktree, it continues past it into the main checkout and cd's there.
# Resolving "$(dirname "$script_path")" AFTER that cd, against the NEW cwd,
# turns a relative BASH_SOURCE into a path rooted at the main checkout instead
# of the worktree the caller actually stood in -- every sibling module this
# script dispatches to would then be the main checkout's copy, silently.
# Capturing the directory here, before find_aimi_root runs, resolves the
# relative path against the invocation directory instead, which is the one
# still guaranteed to be where the caller stood.
#
# `cd ... && pwd` (rather than a bare string join) is what keeps this correct
# when the script is reached through a symlinked directory -- e.g. the plugin
# cache path a Claude Code install resolves through -- since cd follows the
# symlink and pwd then reports the real directory underneath it.
_AIMI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ============================================================================
# Utility Functions
# ============================================================================

# Detect platform capabilities once at startup
_HAS_FLOCK=$(command -v flock &>/dev/null && echo 1 || echo 0)
_HAS_REALPATH=$(command -v realpath &>/dev/null && echo 1 || echo 0)
_HAS_SHA256SUM=$(command -v sha256sum &>/dev/null && echo 1 || echo 0)

# Resolve a path to its absolute form (POSIX-compatible)
resolve_path() {
  local path="$1"
  if [ "$_HAS_REALPATH" -eq 1 ]; then
    realpath "$path"
  else
    (cd "$(dirname "$path")" && echo "$(pwd)/$(basename "$path")")
  fi
}

# Auto-discover the project root containing .aimi/ by walking up the directory tree.
# On success: cd to the discovered root, rewrite AIMI_DIR and TASKS_DIR to absolute paths,
#             and export PROJECT_ROOT for use by other functions.
# On failure (reached /): exit 1 with error to stderr.
find_aimi_root() {
  local dir
  dir=$(pwd)
  # The directory the caller was standing in, captured BEFORE the cd below.
  # verify-probe runs a story's verify segments here rather than at
  # PROJECT_ROOT, because that is where the executor runs the verify itself:
  # step 0c cds to WORKTREE_PATH (or PROJECT_PATH) and step 4 runs the verify
  # from there. Probing at PROJECT_ROOT would measure the main checkout while
  # the real run measures the worktree -- a probe that reports on a different
  # tree than the check it is probing is worse than no probe.
  AIMI_INVOCATION_DIR="$dir"
  while true; do
    if [ -d "$dir/.aimi" ]; then
      cd "$dir"
      AIMI_DIR="$dir/.aimi"
      TASKS_DIR="$AIMI_DIR/tasks"

      # Discover the git repository root and export as PROJECT_ROOT
      local git_root
      git_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || git_root="$dir"
      PROJECT_ROOT=$(resolve_path "$git_root")
      export PROJECT_ROOT

      return 0
    fi
    # Stop at HOME — never scan above the user's home directory
    if [ "$dir" = "$HOME" ]; then
      echo "Error: .aimi/ directory not found (searched up to \$HOME)" >&2
      exit 1
    fi
    local parent
    parent=$(dirname "$dir")
    if [ "$parent" = "$dir" ]; then
      # Reached filesystem root without finding .aimi/
      echo "Error: .aimi/ directory not found in any parent directory" >&2
      exit 1
    fi
    dir="$parent"
  done
}

# Validate that a given path resolves to a location within PROJECT_ROOT.
# Worktree paths (under .worktrees/ inside PROJECT_ROOT) are explicitly allowed.
# Usage: validate_path_in_project "/some/path"
# Returns 0 if path is within PROJECT_ROOT, exits with error otherwise.
validate_path_in_project() {
  local target_path="$1"

  if [ -z "$target_path" ]; then
    echo "Error: validate_path_in_project requires a path argument" >&2
    exit 1
  fi

  if [ -z "$PROJECT_ROOT" ]; then
    echo "Error: PROJECT_ROOT is not set — call find_aimi_root() first" >&2
    exit 1
  fi

  # Resolve the target path to its absolute form
  local resolved_target
  if [ -e "$target_path" ]; then
    resolved_target=$(resolve_path "$target_path")
  else
    # For paths that don't exist yet, resolve the parent directory
    local parent_dir
    parent_dir=$(dirname "$target_path")
    if [ -e "$parent_dir" ]; then
      resolved_target="$(resolve_path "$parent_dir")/$(basename "$target_path")"
    else
      resolved_target="$target_path"
    fi
  fi

  # Check if the resolved path is under PROJECT_ROOT
  case "$resolved_target" in
    "$PROJECT_ROOT"/*) return 0 ;;  # Under project root (includes .worktrees/)
    "$PROJECT_ROOT")   return 0 ;;  # Exactly the project root
    *)
      echo "Error: Path escapes project root — access denied" >&2
      echo "  Path:         $resolved_target" >&2
      echo "  Project root: $PROJECT_ROOT" >&2
      exit 1
      ;;
  esac
}

# Portable exclusive lock (Linux: flock, macOS: mkdir spinlock)
# Usage: call inside a subshell with FD 200 redirect:
#   (_lock "lockfile"; ... ) 200>"lockfile"
# Linux: flock acquires lock on FD 200, auto-releases when subshell exits
# macOS: mkdir creates atomic lock dir, trap EXIT cleans up on subshell exit
_lock() {
  if [ "$_HAS_FLOCK" -eq 1 ]; then
    flock -x 200
  else
    local lockdir="$1.d"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 0.05
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 200 ]; then
        echo "Warning: Breaking stale lock on $1" >&2
        rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir"
        attempts=0
      fi
    done
    trap "rmdir '$lockdir' 2>/dev/null" EXIT
  fi
}

# Ensure jq is available
check_jq() {
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed." >&2
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
  fi
}

# Ensure python3 is available. Mirrors check_jq. Its scope is this SCRIPT, not
# one family of verbs: the roadmap verbs, story-merge, every tasks.json verb and
# the whole models.json surface answer from a module beside this file, and the
# tasks group includes the per-story hot path /aimi:execute runs -- mark-*,
# list-ready, next-story, count-pending and get-story-context, the verb every
# spawned executor runs as its first action. init-session joined that group when
# its three document reads crossed, and detect-models joined it when the
# models.json merge did -- it is the one detect-* verb that needs the
# interpreter. What still runs without python3 is the environment and forge
# half: the four version/cache verbs (version, check-version, cleanup-versions,
# prime-cache), which are what LOCATE this script and therefore must not depend
# on a module that lives beside it; the rest of detect-* (detect-forge,
# detect-default-branch, detect-parent-branch, detect-interactivity,
# detect-design-bundle); forge-*; setup-branch; and estimate-payload. That
# residue is too small to be worth naming as the rule: assume aimi-cli.sh needs
# python3. Three places DEGRADE rather than refuse and so belong to neither
# list -- the four models.json readers (see _models_python3_or_degrade below),
# next-story, and list-archivable. The whole-repo statement, including which
# host the requirement is new on, is in the top-level CLAUDE.md § Testing.
check_python3() {
  if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required by aimi-cli.sh but is not installed." >&2
    echo "Install with: brew install python (macOS) or apt install python3 (Linux)" >&2
    exit 1
  fi
}

# Absolute path to a Python module that sits beside this script -- roadmap.py
# for the roadmap verbs, story_merge.py for story-merge, tasks.py for the
# tasks.json verbs, models.py for the models.json readers and their writer.
#
# Built on $_AIMI_SCRIPT_DIR, captured at the top of this file before
# find_aimi_root can move the cwd -- see that assignment's own comment for why
# resolving ${BASH_SOURCE[0]:-$0} HERE, at call time, would be too late: every
# verb using this helper dispatches after find_aimi_root has already run.
_aimi_script_py() {
  printf '%s/%s\n' "$_AIMI_SCRIPT_DIR" "$1"
}

# The fourteen roadmap call sites name their module through this, so none of
# them had to change when a second module arrived.
_aimi_roadmap_py() {
  _aimi_script_py roadmap.py
}

# Same, for the tasks.json verbs. Built on the shared resolver above
# rather than repeating the BASH_SOURCE idiom, which is the whole reason
# _aimi_script_py was split out of _aimi_roadmap_py in the first place.
_aimi_tasks_py() {
  _aimi_script_py tasks.py
}

# Same, for the four models.json READER verbs.
_aimi_models_py() {
  _aimi_script_py models.py
}

# Same again, for the one SHELL library that sits beside this script:
# lib/extract-command-blocks.sh, the single fence parser measure-command-file
# borrows from test-command-blocks.sh. _aimi_script_py's name says "py" but its
# body only joins this script's own directory to a relative name, and
# re-deriving that directory here is the exact duplication splitting the
# resolver out was meant to stop.
_aimi_blocks_lib() {
  _aimi_script_py lib/extract-command-blocks.sh
}

# python3 for a models READER, or the verb's own documented fallback.
# Usage: if ! _models_python3_or_degrade <verb> <what-it-falls-back-to>; then ...
#
# NOT check_python3, and the difference is the whole point. check_python3 exits
# 1, which is right for a verb that cannot answer without the interpreter and
# whose caller is a command that has already committed to running. resolve-
# models is neither: it runs once per invocation of eight commands and skills,
# and its contract is that it NEVER fails -- stdout is always valid JSON, every
# failure path prints the fallback and returns 0. Under Claude Code python3 is
# already a hard per-Bash-call dependency (hooks/hooks.json wires a .py on
# PreToolUse), but install.sh wires no hooks at all, so on OpenCode nothing
# else guarantees an interpreter. A bare check_python3 here would turn a
# python3-less OpenCode host from "works" into "every command dies at its first
# CLI call" -- a regression against the pure-jq behaviour this port replaces.
#
# So each reader degrades to what it already promises when it cannot read the
# config: all-inherit, all-null, `prompt`, the built-in Anthropic list. One
# line to stderr, and exit 0.
_models_python3_or_degrade() {
  command -v python3 >/dev/null 2>&1 && return 0
  echo "Warning: $1: python3 is required to read models.json and was not found; falling back to $2." >&2
  return 1
}

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$AIMI_DIR"
}

# Read a state file, returns empty string if not exists
read_state() {
  local key="$1"
  local file="$AIMI_DIR/$key"
  validate_path_in_project "$file"
  if [ -f "$file" ]; then
    cat "$file"
  fi
}

# Write a value to a state file (flock-protected for parallel safety)
write_state() {
  local key="$1"
  local value="$2"
  ensure_state_dir
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    echo "$value" > "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Clear a single state file (flock-protected for parallel safety)
clear_state_file() {
  local key="$1"
  validate_path_in_project "$AIMI_DIR/$key"
  (
    _lock "$AIMI_DIR/.state.lock"
    rm -f "$AIMI_DIR/$key"
  ) 200>"$AIMI_DIR/.state.lock"
}

# Extract version string from an aimi-cli.sh path
# Given: <config_dir>/plugins/cache/foo/aimi-engineering/1.4.0/scripts/aimi-cli.sh
# Returns: 1.4.0
_extract_version_from_path() {
  local path="$1"
  local no_script="${path%/*}"       # strip /aimi-cli.sh -> .../scripts
  local no_scripts="${no_script%/*}" # strip /scripts -> .../1.4.0
  printf '%s\n' "${no_scripts##*/}"  # strip prefix -> 1.4.0
}

# Resolve the NEWEST installed path under the Claude Code plugin cache.
#
# THE ONE OWNER of "which installed version is latest". Every site in this file
# that used to spell that question as `ls <cache glob> | tail -1` -- or, at
# _resolve_skills_base_dir, as `ls -d <cache glob> | head -1` -- calls this
# instead, so the rule is stated once and the sites cannot disagree.
#
# Lexicographic order is not a near-miss here, it is wrong in the direction
# that destroys data: `ls` collates 1.121.3 BEFORE 1.9.0 because '1' < '9' at
# the third character, so on a cache holding 1.9.0 next to 1.123.0 `tail -1`
# answers 1.9.0. cmd_cleanup_versions then rm -rf's 1.123.0, keeps 1.9.0 and
# writes 1.9.0's path into the global cli-path cache. This plugin's history
# spans 1.9.0 to 1.123.0, so that pairing is reachable on any long-lived
# install rather than hypothetical.
#
# It is deliberately NOT a plain `sort -V` over the globbed paths, and that
# distinction is most of why this is a function. The cache glob spans TWO
# wildcards -- <config>/plugins/cache/<marketplace-entry>/aimi-engineering/<version>/<suffix>
# -- so sorting whole path strings orders by marketplace-entry directory first
# and by version only within one entry, which reintroduces the same class of
# bug the moment a host holds two marketplace entries. Each candidate is
# therefore prefixed with its own version segment and the sort keys on that.
#
# Usage: _resolve_latest_cache_path <config_dir> <suffix>
#   suffix is the path fragment after the version directory:
#   "scripts/aimi-cli.sh" for the CLI, "skills" for the skills base directory.
#
# ALWAYS RETURNS 0. It prints the newest path, or nothing at all when no version
# is installed, and every caller decides what "nothing" means with a plain
# `[ -z "$var" ]` test it already had.
#
# That is a deliberate contract change, and the reason is that the previous one
# -- return 1 on an empty glob -- was a rule callers had to remember rather than
# a property they could rely on. Under `set -euo pipefail` a bare
# `var=$(_resolve_latest_cache_path ...)` carries the non-zero status and kills
# the script, so cmd_check_version's documented `{status: "unknown"}` branch and
# cmd_cleanup_versions' `{removed: 0, kept: null}` branch sat below an
# unreachable line and had NEVER ONCE been emitted. Two callers remembered to
# append `|| var=""` and survived; two did not and aborted. A helper whose
# safety depends on the caller appending three characters is the defect, so it
# no longer has a failure mode to forget.
#
# The GLOB is a plain Bash array assignment: no `ls`, so there is no exit status
# for `pipefail` to propagate, and no nested `bash -c`, so `$config_dir` is never
# expanded into another shell's program text. Bash leaves an unmatched pattern
# as its own literal text rather than as an empty list, which is what the
# existence test on the first element is for -- `-e` for an ordinary path, `-L`
# so a dangling symlink still counts as the match `ls -d` would have printed.
#
# The ORDERING is otherwise untouched: the same sed/sort -V/tail/cut comparator
# as before, still keyed on each candidate's own version segment rather than on
# the whole path. Every out-of-file copy of that idiom (the --help EXAMPLES
# block, cli-path-resolution.md, review.md, validate-bug.md, resolve-pr-parallel's
# _resolve-cli.sh, and the two literal patterns in hooks/auto-approve-cli.sh
# that must match them) therefore still agrees with this function.
#
# A VERSION SEGMENT ONLY COUNTS WHEN IT LOOKS LIKE A VERSION, and that grep is
# the newest line in the pipeline. `sort -V` is a total order over arbitrary
# strings, not a filter: it happily ranks a directory that is not a version at
# all, and ranks it ABOVE the real ones. Measured against the installed plugin
# before this line existed -- a sibling directory named `1.124.0.bak` beside
# `1.124.0` made check-version answer "latestVersion": "1.124.0.bak", and
# `printf '1.124.0\n1.124.0.bak' | sort -V | tail -1` picks the `.bak` on its
# own; a directory named `zz` beats `1.127.0` outright. Those names are not
# hypothetical: a `cp -a` backup before an upgrade, an editor's leftover, a
# half-extracted download all land right beside the versions in the same cache
# entry. The damage is not only a wrong version STRING -- cmd_cleanup_versions
# rm -rf's every directory this function does not pick, so the backup was kept
# and the real install deleted. Two golden recordings show exactly that
# (cv-versao-malformada-cc, clv-versao-malformada-cc, both now excused by name
# in tests/test_version_cache.py's NUMERIC_VERSION_FILTER).
#
# The shape admitted is deliberately narrow -- three numeric segments and
# nothing else, anchored at the start and terminated by the separator space the
# sed above just inserted, so `1.124.0.bak` fails on the fourth segment rather
# than passing on its first three. This plugin has only ever published plain
# `major.minor.patch`, so nothing real is excluded; a pre-release suffix would
# have to widen this and the six copies of it together.
#
# `grep` exits 1 when nothing matches, which under `set -o pipefail` is exactly
# the empty-glob answer this function already documents: the `|| newest=""`
# below catches it, and a cache holding no version-shaped directory reads as
# "nothing installed" rather than as an abort.
_resolve_latest_cache_path() {
  local config_dir="$1" suffix="$2"
  local -a candidates=()
  candidates=("$config_dir"/plugins/cache/*/aimi-engineering/*/"$suffix")
  if [ ! -e "${candidates[0]:-}" ] && [ ! -L "${candidates[0]:-}" ]; then
    return 0
  fi
  local newest=""
  newest=$(
    printf '%s\n' "${candidates[@]}" \
      | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" \
      | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " \
      | sort -V \
      | tail -1 \
      | cut -d' ' -f2-
  ) || newest=""
  printf '%s\n' "$newest"
}

# Locate a directory-source Claude Code install's plugin directory.
#
# Usage: _directory_source_plugin_dir <config_dir>
#
# A directory-source install has no versioned entry under
# <config_dir>/plugins/cache/ -- the plugin runs straight out of the checkout
# a marketplace was added FROM, so _resolve_latest_cache_path's glob never
# matches it. This is the other way to find that plugin directory: read
# <config_dir>/plugins/known_marketplaces.json for the marketplace's own
# installLocation, then read that install's .claude-plugin/marketplace.json
# for the aimi-engineering entry's own source subpath.
#
# ALWAYS RETURNS 0 -- the same contract _resolve_latest_cache_path documents
# above. It prints one candidate path, or nothing at all, and every caller
# decides what "nothing" means with the same plain `[ -z "$var" ]` test.
# Every jq call is therefore assigned through `var=$(jq ...) || var=""`
# rather than left as a bare command substitution: under `set -euo pipefail`
# the bare form carries jq's parse-failure exit status into the caller and
# kills the script, and a malformed or absent document is exactly the shape
# this helper exists to answer silently rather than propagate. Nothing here
# ever writes to stderr, for the same reason -- jq's own diagnostics are
# always redirected away, never surfaced raw.
#
# TIE-BREAK: known_marketplaces.json can hold more than one directory-source
# entry (two checkouts of this repo registered as separate marketplaces, for
# instance). No field on an entry is a safe ordering signal -- lastUpdated is
# a plain string with no format contract enforced anywhere it is written --
# so the entry is chosen by its own marketplace-name KEY, ascending byte
# order (`to_entries | sort_by(.key)`), which is deterministic and
# independent of on-disk or insertion order.
#
# VALIDATION reuses the "absolute, then exists" idiom _validate_plugin_dir
# applies to AIMI_PLUGIN_DIR (this file, ~line 490 as of this comment) rather
# than calling that function: it takes no argument, reads $AIMI_PLUGIN_DIR
# directly, and exit 1s on a bad value -- three things this always-`return 0`
# helper must never do. The matched plugin's own `.source` subpath gets one
# check the cited idiom does not need: a `..` segment is rejected before it
# is joined onto installLocation, because that idiom validates one whole path
# with no join step of its own.
_directory_source_plugin_dir() {
  local config_dir="$1"
  local km_file="$config_dir/plugins/known_marketplaces.json"

  # One call folds the top-level type-gate, the directory-source filter and
  # the key-order tie-break together: a non-object top level (array, scalar,
  # or a jq parse/open failure) takes the `if type != "object"` branch or
  # aborts the whole expression, either way landing on the `|| install_location=""`
  # fallback below with nothing printed.
  local install_location=""
  install_location=$(jq -r '
      if type != "object" then empty else
        to_entries
        | map(select(.value.source.source == "directory"
                      and (.value.installLocation | type) == "string"))
        | sort_by(.key)
        | .[0].value.installLocation // empty
      end
    ' "$km_file" 2>/dev/null) || install_location=""
  [ -z "$install_location" ] && return 0

  # Same idiom as _validate_plugin_dir: absolute, then exists -- but return 0
  # rather than exit 1 on a bad value, because this helper never aborts.
  [ "${install_location#/}" = "$install_location" ] && return 0
  [ -d "$install_location" ] || return 0
  install_location="${install_location%/}"

  local mp_file="$install_location/.claude-plugin/marketplace.json"

  # Shape gate before the extraction call touches marketplace.json at all --
  # an absent file, an unreadable one or invalid JSON all fall through the
  # `|| mp_type=""` fallback and fail the "object" comparison below.
  local mp_type=""
  mp_type=$(jq -r 'type' "$mp_file" 2>/dev/null) || mp_type=""
  [ "$mp_type" = "object" ] || return 0

  local plugin_source=""
  plugin_source=$(jq -r '
      (.plugins // [])
      | map(select(.name == "aimi-engineering" and (.source | type) == "string"))
      | .[0].source // empty
    ' "$mp_file" 2>/dev/null) || plugin_source=""
  [ -z "$plugin_source" ] && return 0

  # Reject an absolute or traversing source segment before it is ever joined
  # onto installLocation.
  case "$plugin_source" in
    /*) return 0 ;;
  esac
  case "$plugin_source" in
    *..*) return 0 ;;
  esac

  local plugin_dir="${install_location}/${plugin_source#./}"
  [ -d "$plugin_dir" ] || return 0

  printf '%s\n' "$plugin_dir"
}

# Resolve one file under a directory-source install's plugin directory.
#
# Usage: _resolve_directory_source_path <config_dir> <suffix>
#   suffix is the path fragment under the plugin directory: "scripts/aimi-cli.sh"
#   for the CLI, "skills/git-worktree/scripts/worktree-manager.sh" for the
#   worktree manager, "skills" for the skills base directory.
#
# Thin wrapper over _directory_source_plugin_dir: joins its result with
# <suffix> and existence-checks the join, mirroring _resolve_latest_cache_path's
# own `-e`/`-L` existence-check tail above so a dangling symlink still counts
# as present. Calls no jq of its own. ALWAYS RETURNS 0, printing one candidate
# path or nothing.
_resolve_directory_source_path() {
  local config_dir="$1" suffix="$2"
  local plugin_dir=""
  plugin_dir=$(_directory_source_plugin_dir "$config_dir") || plugin_dir=""
  [ -z "$plugin_dir" ] && return 0

  local candidate="$plugin_dir/$suffix"
  if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    return 0
  fi
  printf '%s\n' "$candidate"
}

# Resolve the Claude config directory.
# Honors CLAUDE_CONFIG_DIR env var; falls back to ~/.claude.
# When CLAUDE_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_claude_config_dir() {
  local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  # Validate absolute path when explicitly set
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: CLAUDE_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Validate and resolve AIMI_PLUGIN_DIR when set by compound-plugin converter.
# Returns stripped path on success, empty string when unset; exits 1 on invalid.
_validate_plugin_dir() {
  if [ -z "${AIMI_PLUGIN_DIR:-}" ]; then
    return 0
  fi
  # Must be an absolute path
  if [ "${AIMI_PLUGIN_DIR#/}" = "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR must be an absolute path, got: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Directory must exist
  if [ ! -d "$AIMI_PLUGIN_DIR" ]; then
    echo "Error: AIMI_PLUGIN_DIR directory does not exist: $AIMI_PLUGIN_DIR" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${AIMI_PLUGIN_DIR%/}"
}

# Detect if running inside Claude Code (CLAUDECODE=1 is set by Claude Code in every session)
_is_claude_code_host() {
  [ "${CLAUDECODE:-}" = "1" ]
}

# Validate and resolve AIMI_DEV_DIR -- the LAYER 0 development override, ahead
# of AIMI_PLUGIN_DIR and honored on EVERY host.
#
# Usage: dev_dir=$(_dev_dir_path) || <the value was invalid>
#   Prints the stripped directory when the override is set and valid.
#   Prints nothing and returns 0 when it is unset -- "no override" is a normal
#   answer, not a failure.
#   Prints one diagnostic to stderr and returns 1 when it is set and invalid.
#
# WHY THE CLAUDECODE GATE IS ABSENT, and why that asymmetry with
# AIMI_PLUGIN_DIR is the point rather than an oversight. AIMI_PLUGIN_DIR names
# where the compound-plugin converter INSTALLED the plugin, so inside Claude
# Code -- which has an install of its own under the plugin cache -- honoring it
# would let another host's install win, and _validate_cached_cli_path,
# cmd_check_version, cmd_cleanup_versions and cmd_prime_cache all skip it for
# that reason. AIMI_DEV_DIR names a tree the operator is DELIBERATELY testing.
# A gate would make it work in exactly the host where nobody needs it and do
# nothing in the one where the whole workflow lives, so it has none.
#
# IT NEVER `exit`s, and that is not a style choice: every caller reads it
# through `$( )`, and an `exit` inside a command substitution kills the
# SUBSHELL while the parent carries on with an empty value -- the silent
# shadowing this override exists to make impossible. The refusal travels as an
# exit status the caller must handle instead.
#
# The four validity checks are _validate_plugin_dir's regime, in its order,
# with a fifth that AIMI_PLUGIN_DIR has no need of:
#   1. absolute -- a RELATIVE value makes "$AIMI_DEV_DIR/scripts/aimi-cli.sh"
#      resolve against the caller's CWD, handing execution to any repository
#      that happens to ship an executable scripts/aimi-cli.sh of its own.
#   2. the directory exists.
#   3. scripts/aimi-cli.sh under it is executable -- an override that names a
#      tree with no CLI in it is a typo, and answering "no override" for it
#      would hide the typo behind the installed plugin.
#   4/5. NOT under a `/.worktrees/` segment, checked on the given string and
#      then on its symlink-resolved target -- the same refusal, in the same
#      order and for the same reason, that write_global_cli_cache applies (see
#      its header ~line 730): a worktree copy is ephemeral, and pointing a
#      whole shell session at one leaves every later call at exit 127 once the
#      worktree is cleaned up. The resolved check is what catches the shape
#      that defeated the string check there -- a symlink into a worktree whose
#      own name carries no `.worktrees/` segment -- and is best-effort in the
#      same way: a path that cannot be resolved falls back to the string
#      verdict rather than being refused.
_dev_dir_path() {
  if [ -z "${AIMI_DEV_DIR:-}" ]; then
    return 0
  fi
  if [ "${AIMI_DEV_DIR#/}" = "$AIMI_DEV_DIR" ]; then
    echo "Error: AIMI_DEV_DIR must be an absolute path, got: $AIMI_DEV_DIR" >&2
    return 1
  fi
  if [ ! -d "$AIMI_DEV_DIR" ]; then
    echo "Error: AIMI_DEV_DIR directory does not exist: $AIMI_DEV_DIR" >&2
    return 1
  fi
  local dev_dir="${AIMI_DEV_DIR%/}"
  if [ ! -x "$dev_dir/scripts/aimi-cli.sh" ]; then
    echo "Error: AIMI_DEV_DIR/scripts/aimi-cli.sh is not executable: $dev_dir/scripts/aimi-cli.sh" >&2
    return 1
  fi
  case "$dev_dir" in
    */.worktrees/*)
      echo "Error: AIMI_DEV_DIR must not name a git worktree copy (a path under .worktrees/ vanishes on cleanup): $dev_dir" >&2
      return 1
      ;;
  esac
  local resolved_dev=""
  resolved_dev=$(resolve_path "$dev_dir" 2>/dev/null) || resolved_dev=""
  case "$resolved_dev" in
    */.worktrees/*)
      echo "Error: AIMI_DEV_DIR resolves into a git worktree copy (a path under .worktrees/ vanishes on cleanup): $dev_dir -> $resolved_dev" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$dev_dir"
}

# Resolve the Aimi config directory (XDG-compliant, host-agnostic).
# Honors AIMI_CONFIG_DIR env var; falls back to ${XDG_CONFIG_HOME:-$HOME/.config}/aimi.
# When AIMI_CONFIG_DIR is set, validates it is an absolute path.
# Always returns the path with any trailing slash stripped.
_aimi_config_dir() {
  local dir="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"
  # Validate absolute path when explicitly set
  if [ -n "${AIMI_CONFIG_DIR:-}" ] && [ "${dir#/}" = "$dir" ]; then
    echo "Error: AIMI_CONFIG_DIR must be an absolute path, got: $dir" >&2
    exit 1
  fi
  # Strip trailing slash
  printf '%s\n' "${dir%/}"
}

# Return the legacy global cache file path for aimi-cli.sh (read-fallback only)
_global_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-cli-path"
}

# Return the legacy global cache file path for worktree-manager.sh (read-fallback only)
_global_worktree_cache_path_legacy() {
  local config_dir
  config_dir=$(_claude_config_dir)
  printf '%s\n' "$config_dir/aimi-engineering-worktree-path"
}

# Return the global cache file path for aimi-cli.sh (new XDG location)
_global_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/cli-path"
}

# Return the global cache file path for worktree-manager.sh (new XDG location)
_global_worktree_cache_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/worktree-path"
}

# Return the path to the models config file (XDG location)
_aimi_models_config_path() {
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models.json"
}

# Return the path to the models first-run prompt marker file for the active host.
# The marker is per-host: `models-prompt-seen-claudeCode` or `models-prompt-seen-opencode`.
# This lets a user dismiss the prompt independently on each host — picking
# "Keep the default (inherit)" on Claude Code does not silence the prompt on OpenCode.
# The legacy global `models-prompt-seen` file (no host suffix) is no longer read.
_aimi_models_prompt_marker_path() {
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-prompt-seen-$host"
}

# Return the path to THIS repository's remembered forge account store, as a
# fifth sibling of the four config-path helpers above. Prints exactly one
# absolute path on stdout; returns 1 printing nothing when the current
# directory has no resolvable git identity.
#
# WHY --git-common-dir AND NOT --show-toplevel: `--show-toplevel` answers with
# the WORKTREE path, so every `.worktrees/<branch>` checkout of one repository
# hashes to a different key and gets asked for its account all over again. This
# repository creates worktrees constantly via /aimi:execute, so that is a daily
# regression, not a corner case. `--git-common-dir` answers with the ONE shared
# `.git` directory from both the main checkout and every worktree, which is
# what makes "asks once, never again" true. This is a deliberate, recorded
# deviation from the phase-2 roadmap's success criterion 4, whose literal
# wording says "keyed by a hash of the repository toplevel" -- the roadmap was
# deliberately not amended; see US-001's notes. Everything else criterion 4
# asks for is preserved: hash-keyed, stored outside the repository, never
# committed, per-user.
#
# WHY THE VALUE MUST BE ABSOLUTE BEFORE IT IS HASHED -- load-bearing, not
# defensive: bare `git rev-parse --git-common-dir` returns a RELATIVE path.
# Verified in this repository at git 2.34.1: `.git` from the toplevel and
# `../../../.git` from plugins/aimi-engineering/scripts. Hashing that raw would
# hand EVERY repository on the machine the single shared key hash('.git')
# whenever the CLI runs from a toplevel -- the "scope too coarse" defect
# CHANGELOG 1.93.2 already had to remediate once, when a global
# models-prompt-seen marker had to become per-host -- and would also make one
# repository's key vary by current directory, re-asking from a subdirectory.
# So `--path-format=absolute` (git >= 2.31) is tried first, and the bare form
# is only a fallback that is joined against $PWD and normalized through
# resolve_path. One machine runs one git, so a single invocation never mixes
# the two routes; only the fallback normalizes symlinks, which is why the
# absolute route is the one that must stay primary.
#
# DOCUMENT SHAPE THIS PATH POINTS AT -- READ, MERGE, WRITE; NEVER `jq -n`:
# the file holds a JSON OBJECT KEYED BY FORGE HOST, e.g.
#   {"github.com": {...}, "gitlab.com": {...}}
# It is multi-entry by nature: one repository can carry remotes on more than
# one host, and phases 3 and 4 add glab/tea hosts alongside github.com. Any
# writer MUST read the existing document and merge its own host key into it,
# and MUST NOT rebuild the document with `jq -n`. That exact mistake shipped
# here before: CHANGELOG:487 (1.97.2), where `detect-models` in default mode
# rebuilt models.json with `jq -n` and silently dropped the OTHER host's
# sub-table on every single invocation (regression test
# test_detect_models_default_mode_preserves_other_host). The per-repository
# split into separate files makes sibling repositories structurally unable to
# clobber each other; the per-host merge obligation is what keeps a single
# repository's own hosts from doing it.
#
# MEMOIZES NOTHING, DELIBERATELY: like its four siblings this is a pure stdout
# printer, so every call site reaches it through `$(...)` -- and a memo
# populated inside a command-substitution subshell dies with that subshell, as
# _detect_forge_type's header spells out. Per-invocation memoization of the
# resolved ACCOUNT lives one level up instead, in the
# _forge_account_host_cached / _forge_account_override_slots pair, which uses
# exactly that name-reference discipline: the memo is warmed by a plain
# statement in the write function's own shell, and the `$(...)` lookups that
# follow inherit it.
_forge_account_store_path() {
  local common_dir=""

  # Primary: the absolute answer, straight from git.
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=""

  # Fallback for git < 2.31 (no --path-format): take the bare answer, join a
  # relative one against the current directory, and normalize.
  if [ -z "$common_dir" ] || [ "${common_dir#/}" = "$common_dir" ]; then
    common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir=""
    if [ -n "$common_dir" ]; then
      case "$common_dir" in
        /*) ;;
        *) common_dir="$(pwd)/$common_dir" ;;
      esac
      common_dir=$(resolve_path "$common_dir" 2>/dev/null) || common_dir=""
    fi
  fi

  # Degradation: no git repository, or git could not answer. Return non-zero
  # with empty stdout -- callers read that as "no remembered answer, proceed on
  # the active account", matching _forge_bin_check's optional-mode posture.
  # NEVER fall through to hashing the empty string the way _resolve_default_branch
  # tolerates an empty toplevel: hash('') would become ONE global "no-repo"
  # store every non-repo caller writes into, which is precisely the coarse-scope
  # defect the absolute-path guarantee above exists to prevent. Silent by
  # design -- being outside a repository is an expected condition, not an error.
  if [ -z "$common_dir" ] || [ "${common_dir#/}" = "$common_dir" ]; then
    return 1
  fi

  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/forge-account-$(_default_branch_cache_key "$common_dir").json"
}

# Read the models config JSON, returning empty string when the file is absent.
# Does not validate contents — callers must handle malformed JSON.
read_aimi_models_config() {
  local config_file
  config_file=$(_aimi_models_config_path)
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  cat "$config_file" 2>/dev/null
}

# Atomically write JSON content to the models config file (chmod 0600, mktemp + mv).
# Usage: write_aimi_models_config <json_content>
# Mirrors write_global_cli_cache — interrupted runs never corrupt a pre-existing file.
# chmod is applied BEFORE writing content (create-then-restrict-then-write pattern).
# Temp file is removed on mv failure so no stray files remain.
write_aimi_models_config() {
  local json_content="$1"
  local config_file
  config_file=$(_aimi_models_config_path)
  local config_dir
  config_dir=$(dirname "$config_file")
  if ! mkdir -p "$config_dir" 2>/dev/null; then
    echo "Error: write_aimi_models_config: cannot create directory: $config_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${config_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf '%s\n' "$json_content" > "$tmp_file"
  if ! mv "$tmp_file" "$config_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: write_aimi_models_config: mv failed for $config_file" >&2
    return 1
  fi
}

# Atomically write the CLI path to the global cache file
# Usage: write_global_cli_cache "/path/to/aimi-cli.sh"
# Never persists an ephemeral git-worktree copy: a path under a `.worktrees/`
# segment is invoked from a throwaway checkout (e.g. test-aimi-cli.sh running
# inside a worktree, or an /aimi:execute wave). Caching it globally would point
# every later session at a file that vanishes on worktree cleanup (exit 127).
#
# THE REFUSAL LOOKS AT THE RESOLVED PATH AS WELL AS THE GIVEN ONE. Matching the
# string alone was defeated by exactly the thing the guard exists to catch: a
# plugin-cache entry that is a SYMLINK into a worktree has no `.worktrees/`
# segment in its own name, so it passed and was persisted -- and then produced
# the 127 anyway when the worktree was removed. Recorded from the failing side
# in golden_from_jq.json's cv-fix-simlink-worktrees-cc, clv-simlink-worktrees-cc
# and pc-simlink-worktrees-cc before this line existed.
#
# The string check stays FIRST and answers on its own for the common case, so
# the resolution below is reached only by a path that already looks acceptable.
# It is best-effort by design: a path that cannot be resolved (it may not exist
# yet) falls back to the string verdict rather than refusing, because refusing
# is the branch that silently does nothing.
write_global_cli_cache() {
  local path="$1"
  case "$path" in
    */.worktrees/*)
      # Refuse to cache a worktree-local copy globally; treat as no-op success.
      return 0
      ;;
  esac
  local resolved
  resolved=$(resolve_path "$path" 2>/dev/null) || resolved=""
  case "$resolved" in
    */.worktrees/*)
      # Same refusal, reached through a symlink rather than through the name.
      return 0
      ;;
  esac
  local cache_file
  cache_file=$(_global_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_cli_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_directory_source_identity: admit a cached path only when it is
# BYTE-EQUAL to what _resolve_directory_source_path re-derives for <suffix>
# RIGHT NOW -- never by a shape/pattern match. Shared by
# _validate_cached_cli_path and _validate_cached_worktree_path so a
# directory-source install's cached path can be read back the same way a
# versioned-cache entry already is.
#
# HARD CONSTRAINT: this is not a third case-arm shape pattern (e.g.
# `*/plugins/aimi-engineering/scripts/aimi-cli.sh`) -- a pattern that loose
# would match almost anything a caller cared to name, and this function
# gates a path a later session execs. The only admission path is exact
# string equality against a live re-derivation of TODAY's directory-source
# install.
#
# GATED ON _is_claude_code_host HERE, NOT INSIDE THE RESOLVER: directory-
# source resolution reads known_marketplaces.json, which lives under
# _claude_config_dir and is a Claude Code marketplace concept with no
# OpenCode analogue. Checked against the current source rather than assumed:
# neither _directory_source_plugin_dir nor _resolve_directory_source_path
# gates on the host internally -- on any host, including OpenCode, they just
# answer "no candidate" once they find no known_marketplaces.json under the
# given config_dir. Gating here keeps an OpenCode caller from paying for a
# known_marketplaces.json read (and its jq call) that can never resolve for
# it, and keeps the two validators' intent legible without reading the
# resolver.
#
# ALWAYS RETURNS 0, printing the path or nothing -- the same contract every
# other helper in this family documents. The trailing `return 0` is not
# decorative: under this script's `set -euo pipefail`, a bare failing
# `[ "$cached_path" = "$resolved" ]` as the function's LAST statement would
# otherwise become this function's own exit status, which would corrupt the
# `||` fallback chains read_global_cli_cache and read_global_worktree_cache
# both rely on.
_validate_directory_source_identity() {
  local cached_path="$1" suffix="$2"
  _is_claude_code_host || return 0
  local config_dir
  config_dir=$(_claude_config_dir)
  local resolved=""
  resolved=$(_resolve_directory_source_path "$config_dir" "$suffix") || resolved=""
  if [ -n "$resolved" ] && [ "$cached_path" = "$resolved" ]; then
    printf '%s\n' "$cached_path"
  fi
  return 0
}

# _validate_cached_cli_path: run a path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
#
# THREE admission routes, tried in this order so the common (versioned-cache)
# case costs nothing extra: the OpenCode plugin-dir arm, the versioned-cache
# glob arm, and -- only once neither of those matched, an explicit `return 0`
# in each of their own success paths having already exited otherwise -- a
# fall-through to _validate_directory_source_identity's exact-equality check
# against outline:05's directory-source resolver. See that helper's own
# header for why this is a re-derivation and not a fourth case-arm pattern.
_validate_cached_cli_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/scripts/aimi-cli.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
        return 0
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
      printf '%s\n' "$cached_path"
      return 0
      ;;
  esac
  _validate_directory_source_identity "$cached_path" "scripts/aimi-cli.sh"
}

# Read and validate the cached CLI path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_cli_cache() {
  local cache_file
  cache_file=$(_global_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_cli_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_cli_path "$cached_path"
}

# Atomically write the worktree manager path to the global cache file
# Usage: write_global_worktree_cache "/path/to/worktree-manager.sh"
write_global_worktree_cache() {
  local path="$1"
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  local cache_dir
  cache_dir=$(dirname "$cache_file")
  if ! mkdir -p "$cache_dir" 2>/dev/null; then
    echo "Error: write_global_worktree_cache: cannot create directory: $cache_dir" >&2
    return 1
  fi
  local tmp_file
  tmp_file=$(mktemp "${cache_file}.XXXXXX")
  printf '%s\n' "$path" > "$tmp_file"
  chmod 0600 "$tmp_file"
  mv "$tmp_file" "$cache_file"
}

# _validate_cached_worktree_path: run a worktree path through the whitelist case statement
# Returns the path unchanged if valid, empty string if rejected
#
# Exact twin of _validate_cached_cli_path immediately above -- same three
# admission routes in the same order, same reason the versioned-cache arm's
# own `return 0` must run before _validate_directory_source_identity's
# equality check (and its jq call) ever does.
#
# THE WRITER THIS COMMENT USED TO SAY DID NOT EXIST NOW DOES. It said the
# widening was "symmetry for a reader with no writer yet", and that was true
# for as long as it stood: nothing called write_global_worktree_cache, so the
# worktree-path file on disk existed only where somebody had written it by
# hand -- which is how it came to name a version the cli-path had already
# moved off. _persist_worktree_pointer_for below is the writer, and
# cmd_check_version (on --fix), cmd_cleanup_versions and cmd_prime_cache are
# the three verbs that call it, each one immediately beside its existing
# write_global_cli_cache call so the two pointers cannot name different
# installs.
_validate_cached_worktree_path() {
  local cached_path="$1"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  case "$cached_path" in
    "${plugin_dir}"/skills/git-worktree/scripts/worktree-manager.sh)
      if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
        printf '%s\n' "$cached_path"
        return 0
      fi
      ;;
    */plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh)
      printf '%s\n' "$cached_path"
      return 0
      ;;
  esac
  _validate_directory_source_identity "$cached_path" "skills/git-worktree/scripts/worktree-manager.sh"
}

# Read and validate the cached worktree manager path from the global cache file
# Tries new XDG path first, falls back to legacy path if new is absent.
# Returns the cached path if valid, empty string otherwise.
read_global_worktree_cache() {
  local cache_file
  cache_file=$(_global_worktree_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    local cached_path
    cached_path=$(cat "$cache_file" 2>/dev/null) || return 0
    _validate_cached_worktree_path "$cached_path"
    return 0
  fi
  # Fall back to legacy path
  local legacy_file
  legacy_file=$(_global_worktree_cache_path_legacy)
  if [ ! -f "$legacy_file" ] || [ ! -r "$legacy_file" ]; then
    return 0
  fi
  local cached_path
  cached_path=$(cat "$legacy_file" 2>/dev/null) || return 0
  _validate_cached_worktree_path "$cached_path"
}

# _worktree_manager_beside: the worktree-manager.sh that belongs to a given
# aimi-cli.sh path. Prints it, or prints nothing -- always returns 0, like
# every other helper in this family.
#
# The two scripts are fixed siblings inside one install root:
#   <root>/scripts/aimi-cli.sh
#   <root>/skills/git-worktree/scripts/worktree-manager.sh
# so the manager is a pure function of the CLI path. That is the whole point.
# The two global pointers used to be written by different things at different
# times -- cli-path by this CLI, worktree-path by a human or by
# cli-path-resolution.md's Layer 2 one-liner -- so they could name different
# installs, and did: after a `check-version --fix` the cli-path moved to the
# new version and the worktree-path stayed on the old one. Deriving the second
# from the first at the moment the first is written is what makes that
# impossible rather than unlikely.
#
# THE EXISTENCE TEST IS THE CONTRACT, not politeness. The failure this exists
# to stop is a pointer that outlived the directory it named: the old version
# was pruned, $WORKTREE_MGR became a path to nothing, and every guard around
# it only asked whether the VARIABLE was empty. Refusing to persist a path
# that is not there is the write-side half of that fix; the read-side half is
# the `[ -x ]` check the command call sites now carry beside their `:?` guard.
#
# It also keeps this whole family invisible to an install that has no worktree
# manager beside its CLI -- a fake cache entry in a test fixture, an OpenCode
# plugin dir carrying only scripts/ -- which is why adding these calls changed
# no recording in tests/golden_from_jq.json's version_cache_cases.
_worktree_manager_beside() {
  local cli_path="$1"
  [ -n "$cli_path" ] || return 0
  case "$cli_path" in
    */scripts/aimi-cli.sh) ;;
    *) return 0 ;;
  esac
  local candidate="${cli_path%/scripts/aimi-cli.sh}/skills/git-worktree/scripts/worktree-manager.sh"
  [ -f "$candidate" ] || return 0
  printf '%s\n' "$candidate"
}

# _persist_worktree_pointer_for: write the global worktree-path pointer for the
# install that <cli_path> belongs to. Silent no-op when that install carries no
# manager beside its CLI.
#
# NEVER FAILS ITS CALLER. Each of the three is a verb whose own answer -- the
# JSON object it prints and the exit status it returns -- is a contract, and
# none of them should change because a SECONDARY pointer could not be written.
# So the write's own non-zero (a config dir that cannot be created, a read-only
# aimi-config) is swallowed here, having already printed its own line on
# stderr from write_global_worktree_cache.
#
# The already-current short-circuit reads the raw file rather than calling
# read_global_worktree_cache, and the reason is the same one cmd_prime_cache
# gives for its own raw read: that reader runs _validate_cached_worktree_path's
# whitelist, which answers empty for a path shape it does not admit, so on a
# directory-source install every single run would decide the file was wrong
# and rewrite a value that was already correct.
_persist_worktree_pointer_for() {
  local cli_path="$1"
  local manager
  manager=$(_worktree_manager_beside "$cli_path")
  if [ -z "$manager" ]; then
    return 0
  fi
  local cache_file current=""
  cache_file=$(_global_worktree_cache_path)
  if [ -f "$cache_file" ] && [ -r "$cache_file" ]; then
    current=$(cat "$cache_file" 2>/dev/null) || current=""
  fi
  if [ "$current" = "$manager" ]; then
    return 0
  fi
  write_global_worktree_cache "$manager" || return 0
}

# Validate story ID format (US-NNN or US-NNNa)
validate_story_id() {
  local story_id="$1"
  if ! [[ "$story_id" =~ ^US-[0-9]{3}[a-z]?$ ]]; then
    echo "Error: Invalid story ID format: $story_id (expected US-NNN)" >&2
    exit 1
  fi
}

# Validate a dotted field path before it is concatenated into a jq program.
#
# update-field is the one verb that builds its jq filter out of an argument
# rather than out of a fixed string, so the argument IS program text. Without
# this gate a path shaped to close the filter's own parenthesis could open a
# second one, and the assignment then landed on a field nobody named on the
# command line -- another story, or metadata.branchName, which cmd_init_session
# and cmd_validate_tasks both charset-gate precisely because git and gh consume
# it downstream. Gating the argument is what keeps those two gates meaningful.
#
# The legitimate vocabulary is exactly a dotted chain of identifier segments;
# every recorded call site passes the literal "verification.status". Anything
# else is refused rather than escaped -- update-field is not a general nested
# writer and this does not make it one.
validate_field_path() {
  local field_path="$1"
  if ! [[ "$field_path" =~ ^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$ ]]; then
    echo "Error: Invalid field path: $field_path (expected dotted identifiers, e.g. verification.status)" >&2
    exit 1
  fi
}

# Validate story ID exists in the tasks file
validate_story_exists() {
  local story_id="$1"
  local tasks_file="$2"
  if ! jq -e --arg id "$story_id" '.userStories[] | select(.id == $id)' "$tasks_file" > /dev/null 2>&1; then
    echo "Error: Story $story_id not found in $tasks_file" >&2
    exit 1
  fi
}

# Discover tasks files across both the flat layout (.aimi/tasks/*-tasks.json)
# and the nested phase-folder layout (.aimi/tasks/<feature>/phase-N[.M]-<slug>/
# <feature>-phase-N-tasks.json), sorted by modification time with the most
# recent file first. mindepth 1/maxdepth 3 covers flat files (depth 1) and
# nested phase files (feature dir depth 1, phase dir depth 2, tasks file
# depth 3) in one pass. Shared by cmd_find_tasks, cmd_find_tasks_all, and
# get_tasks_file's stale-state fallback so all three see the same combined
# view instead of a flat-only glob. Prints nothing (not an error) when
# TASKS_DIR is missing or empty.
# NUL-delimited find keeps paths containing spaces intact. A newline-delimited
# `xargs ls -t` word-splits them, which silently emptied discovery for any
# project whose path contains a space (regression vs the pre-phase-layer
# quoted glob). The find output is captured into an array first and ls -t is
# only invoked when that array is non-empty -- xargs runs its command once
# even on empty input, and `ls -t` with no arguments lists the current
# directory rather than nothing (xargs -r is a GNU extension BSD/macOS xargs
# does not support, so this is a structural fix, not a flag).
_find_tasks_files_all() {
  [ -d "$TASKS_DIR" ] || return 0
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$TASKS_DIR" -mindepth 1 -maxdepth 3 -type f -name '*-tasks.json' -print0 2>/dev/null)
  [ ${#files[@]} -gt 0 ] || return 0
  ls -t "${files[@]}" 2>/dev/null || true
}

# Get the tasks file (from state or discover)
get_tasks_file() {
  local tasks_file
  tasks_file=$(read_state "current-tasks")

  if [ -n "$tasks_file" ] && [ ! -f "$tasks_file" ]; then
    local stale_path="$tasks_file"
    tasks_file=$(_find_tasks_files_all | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
    echo "Warning: state file pointed to $stale_path which no longer exists. Using $tasks_file instead." >&2
    write_state "current-tasks" "$tasks_file"
  elif [ -z "$tasks_file" ]; then
    tasks_file=$(_find_tasks_files_all | head -1)
    if [ -z "$tasks_file" ]; then
      echo "No tasks file found in $TASKS_DIR/" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    validate_path_in_project "$tasks_file"
  fi

  echo "$tasks_file"
}

# Positional-preserving --tasks-file extraction for verbs whose existing
# arguments are fixed positionals rather than flags (get-story, mark-*,
# cascade-skip, gate-fail, set-execution-mode, update-field, ...). Walks the
# args by INDEX rather than `shift`, so a legitimate positional value
# beginning with "--" (mark-failed's notes, update-field's value) is never
# misread as an unrecognized flag -- the strict `case ... *) exit 1` idiom
# cmd_verification_report uses would collide with exactly that value.
#
# Sets the caller's two variables by nameref: $1 (tasks_file) to the
# override value, or "" when no --tasks-file was given; $2 (positional) to
# every remaining token, in order. The caller reassigns positional[0],
# positional[1], ... onto its own named locals afterward.
# Usage: _parse_positional_tasks_file tasks_file positional "$@"
_parse_positional_tasks_file() {
  local -n _pptf_tasks_file="$1"
  local -n _pptf_positional="$2"
  shift 2
  _pptf_tasks_file=""
  _pptf_positional=()
  local args=("$@")
  local i=0 n=${#args[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${args[$i]}" = "--tasks-file" ]; then
      i=$((i + 1))
      _pptf_tasks_file="${args[$i]:-}"
    else
      _pptf_positional+=("${args[$i]}")
    fi
    i=$((i + 1))
  done
}

# ============================================================================
# Commands
# ============================================================================

# Find the most recent tasks file (flat or nested phase layout)
cmd_find_tasks() {
  local tasks_file
  tasks_file=$(_find_tasks_files_all | head -1)

  if [ -z "$tasks_file" ]; then
    echo "No tasks file found in $TASKS_DIR/" >&2
    exit 1
  fi

  resolve_path "$tasks_file"
}

# Find all tasks files sorted by modification time (most recent first),
# across both the flat and nested phase layouts.
cmd_find_tasks_all() {
  local files
  files=$(_find_tasks_files_all)

  if [ -z "$files" ]; then
    echo "No tasks files found in $TASKS_DIR/" >&2
    exit 1
  fi

  # Output each file as an absolute path, newline-separated
  while IFS= read -r f; do
    resolve_path "$f"
  done <<< "$files"
}

# Initialize execution session
# Usage: aimi-cli.sh init-session [--file <path>]
cmd_init_session() {
  local tasks_file branch
  local file_flag=""

  # Parse optional --file flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)
        shift
        file_flag="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
      *)
        echo "Error: Unexpected argument: $1" >&2
        echo "Usage: aimi-cli.sh init-session [--file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$file_flag" ]; then
    # Validate the --file path exists
    if [ ! -f "$file_flag" ]; then
      echo "Error: File not found: $file_flag" >&2
      exit 1
    fi
    # Validate it matches *-tasks.json pattern
    local basename
    basename=$(basename "$file_flag")
    if ! [[ "$basename" == *-tasks.json ]]; then
      echo "Error: File does not match *-tasks.json pattern: $file_flag" >&2
      exit 1
    fi
    tasks_file=$(resolve_path "$file_flag")
  else
    tasks_file=$(cmd_find_tasks)
  fi
  write_state "current-tasks" "$tasks_file"

  # Self-resolve: persist this CLI's absolute path for future sessions
  local self_path
  self_path=$(resolve_path "$0")
  write_state "cli-path" "$self_path"
  write_global_cli_cache "$self_path"

  # ---- the seam. Above: WHERE THIS SCRIPT IS. Below: WHAT THE DOCUMENT SAYS.
  # The three lines above never cross into tasks.py and never will: inside it
  # `$0` is the .py file, so persisting that would write a Python module's path
  # into ~/.config/aimi/cli-path and break every later $AIMI_CLI resolution --
  # on the NEXT session, long after the test run that passed.

  # ONE crossing for the three document reads that used to be three jq
  # startups. The charset gate below moved with them and is now tasks.py's,
  # because it tests the value jq PRINTED and a non-string branchName prints
  # over several lines -- see op_init_session, which explains the split and
  # what it guarantees about the first line here. Everything the gate lets
  # through matches ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$, so it carries no newline and
  # the split cannot be fooled.
  check_python3
  local payload
  payload=$(python3 "$(_aimi_tasks_py)" init-session --tasks-file "$tasks_file") || exit $?
  branch=${payload%%$'\n'*}

  write_state "current-branch" "$branch"

  printf '%s\n' "${payload#*$'\n'}"
}

# Get comprehensive status summary
# Flags: --counts-only (return aggregate counts without userStories array)
#        --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_status() {
  local counts_only=false
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --counts-only) counts_only=true; shift ;;
      --tasks-file) shift; tasks_file="${1:-}"; shift || true ;;
      *) break ;;
    esac
  done

  if [ -n "$tasks_file" ]; then
    # An explicit path is a CLI ARGUMENT, so validate_path_in_project is the
    # sole authority over it -- same rule verification-report applies.
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # The two branches used to be two 11-line jq programs whose first ten lines
  # were identical -- including a copy each of the maxConcurrency clamp. Both
  # are now one flag on one crossing; tasks.py's status_view omits one key.
  local counts_args=()
  [ "$counts_only" = true ] && counts_args=(--counts-only)

  check_python3
  python3 "$(_aimi_tasks_py)" status --tasks-file "$tasks_file" "${counts_args[@]}"
}

# Get metadata only
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_metadata() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh metadata [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  check_python3
  python3 "$(_aimi_tasks_py)" metadata --tasks-file "$tasks_file"
}

# Which stories carry a visual verification strategy (each with its own
# project and url already normalized -- see verification_report's docstring),
# and how a malformed (non-object) verification partitions into what
# normalize-verification repairs and what it does not.
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file, unlike
# cmd_status/cmd_metadata above -- the command layer's ten call sites this
# replaces mostly name a PHASE, SPLIT or MAIN tasks file, never the
# session-bound one, so this is the one reader that takes the override
# normalize-verification already established the shape of.)
cmd_verification_report() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh verification-report [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    # An explicit path is a CLI ARGUMENT, so validate_path_in_project is the
    # sole authority over it -- the same rule get_tasks_file applies to its
    # own resolved path below, applied here because this flag bypasses it.
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  check_python3
  python3 "$(_aimi_tasks_py)" verification-report --tasks-file "$tasks_file"
}

# Which project groups a tasks file participates in -- the sorted-unique,
# blank-dropped, "."-defaulted group list five execute.md sites used to
# compute inline with their own `jq -r '.userStories[] | (.project // ".")'`
# plus a `sort -u` and an empty-fallback line, and the non-null-project story
# count a sixth site (the routability guard) asked as a separate question.
# Validates every group other than "." against the same traversal-case-list
# and character-regex pair execute.md Step 0.9 and plan.md Phase 3e already
# apply to the same field, reporting every offender before refusing -- see
# project_groups's own docstring in tasks.py for the full contract and the
# deliberate tightening this introduces (these five sites never validated
# before).
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file, unlike
# cmd_status/cmd_metadata -- every one of the six call sites this replaces
# names an explicit phase, split-member or main tasks file, never the
# session-bound one, same convention verification-report established).
cmd_project_groups() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh project-groups [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    # An explicit path is a CLI ARGUMENT, so validate_path_in_project is the
    # sole authority over it -- same rule verification-report applies at its
    # own equivalent branch.
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  check_python3
  python3 "$(_aimi_tasks_py)" project-groups --tasks-file "$tasks_file"
}

# List stories that are ready to execute
# A story is ready when: status == "pending" AND all dependsOn stories have status "completed" or "skipped"
# Flags: --brief (return only {id, title, priority, dependsOn, project, gate} per story)
#        --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_list_ready() {
  local brief=false
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) brief=true; shift ;;
      --tasks-file) shift; tasks_file="${1:-}"; shift || true ;;
      *) break ;;
    esac
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # The readiness predicate and the --brief projection both live in tasks.py's
  # is_ready and brief_row now, at one crossing. The gate rules and the
  # dependency walk are subtler than they read -- jq's `all` ENDS at the first
  # dependsOn id that matches no story, so a dangling id makes a story ready
  # and leaves the ids after it unchecked -- and there is no longer a second
  # copy of them for next-story to drift from.
  check_python3

  # The two branches differ by one `echo`, and only an EMPTY tasks file can
  # tell: the verb produces no output at all for one (jq read zero values from
  # the stream, and so does read_docs), and the pre-port code then printed a
  # bare newline without --brief -- `result=$(...)` followed by `echo "$result"`
  # -- while --brief piped that newline through a second jq, which read it as
  # no input and printed nothing. Recorded as doc-vazio-ready and
  # doc-vazio-brief, and reproduced rather than evened out: a port is not where
  # a cosmetic difference gets settled, and a truncated tasks file printing one
  # blank line is a hole to rank, not to tidy.
  if [ "$brief" = true ]; then
    python3 "$(_aimi_tasks_py)" list-ready --tasks-file "$tasks_file" --brief
  else
    local result
    result=$(python3 "$(_aimi_tasks_py)" list-ready --tasks-file "$tasks_file")
    echo "$result"
  fi
}

# Get next pending story
cmd_next_story() {
  local story story_id

  # next-story has ALWAYS answered `null` for every failure underneath it, and
  # that is preserved rather than tidied: cmd_list_ready used to run on the left
  # of a pipeline inside this command substitution, so neither its `exit 1` for
  # a missing tasks file nor jq's abort on a malformed one ever reached this
  # frame -- $story simply came back empty and the branch below cleared the
  # pointer and printed null at exit 0. /aimi:next reads that null as "all
  # stories complete" and stops, so turning it into a non-zero exit would turn
  # a clean stop into a failure. `|| story=""` is that swallow, now written
  # down instead of being an accident of pipeline structure (recorded as
  # sem-arquivo-next, us-null-next and doc-malformado-next).
  story=$(_next_story_selection) || story=""

  if [ "$story" = "null" ] || [ -z "$story" ]; then
    clear_state_file "current-story"
    echo "null"
    return
  fi

  story_id=$(echo "$story" | jq -r '.id')
  write_state "current-story" "$story_id"

  echo "$story"
}

# The document half of next-story: which story, if any, is next.
#
# Split out so the swallow above has something to swallow. The ordering rules
# live in tasks.py's next_story -- stable on ties so tasks.json file order
# decides, and null before every number so a story with no priority is picked
# first -- and the state write stays here with every other .aimi/state/ write.
_next_story_selection() {
  local tasks_file
  # Explicit rather than left to `set -e`: this function runs inside an `||`
  # list, which is one of the contexts where bash IGNORES -e, so a bare
  # assignment would carry on and hand an empty path to the crossing.
  tasks_file=$(get_tasks_file) || return 1
  check_python3
  python3 "$(_aimi_tasks_py)" next-story --tasks-file "$tasks_file"
}

# Get currently active story from state
#
# REFUSES --tasks-file (does not honor it): the primary answer comes from
# .aimi/state/current-story, and the tasks file is only a secondary lookup
# keyed by that state -- a per-call file override has no coherent meaning
# here. The scan runs before read_state so the refusal fires even when no
# session state exists yet.
cmd_current_story() {
  local _cs_arg
  for _cs_arg in "$@"; do
    if [ "$_cs_arg" = "--tasks-file" ]; then
      echo "Error: Unknown flag: --tasks-file" >&2
      echo "Usage: aimi-cli.sh current-story" >&2
      exit 1
    fi
  done

  local story_id tasks_file
  story_id=$(read_state "current-story")

  # No pointer at all is answered without opening the tasks file, and stays in
  # bash for that reason: .aimi/state/ is read_state's, not tasks.py's.
  if [ -z "$story_id" ]; then
    echo "null"
    return
  fi

  tasks_file=$(get_tasks_file)
  check_python3
  python3 "$(_aimi_tasks_py)" current-story --tasks-file "$tasks_file" --story-id "$story_id"
}

# Get full story object by ID (read-only)
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_get_story() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  # Both gates stay in bash: the id's format and its existence are questions
  # about the ARGUMENT and about which file is current, not about the document.
  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  check_python3
  python3 "$(_aimi_tasks_py)" get-story --tasks-file "$tasks_file" --story-id "$story_id"
}

# Resolve the skills base directory for the current host.
# Returns the absolute path to the skills/ directory, or empty string when unresolvable.
# Claude Code (CLAUDECODE=1): the NEWEST installed version under
#   ~/.claude/plugins/cache/*/aimi-engineering/*/skills.
# OpenCode (AIMI_PLUGIN_DIR set, CLAUDECODE unset): $AIMI_PLUGIN_DIR/skills.
# Otherwise: empty string — caller emits skills: [] silently.
#
# "Newest" here is a DECISION, not a head-to-tail typo fix, and it changes which
# SKILL.md every spawned agent reads. This used to take the FIRST glob hit while
# CLI-path resolution took the LAST, which on a host with two versions
# co-resident is not a tie-break detail but two different installs answering in
# one session — measured live: skills resolved to .../1.122.0/skills while the
# CLI resolved to .../1.123.0/scripts/aimi-cli.sh. A spawned agent must read the
# SKILL.md belonging to the same install whose CLI is orchestrating it, so both
# sides now ask _resolve_latest_cache_path the same question.
#
# An empty glob leaves this function alive and answering "", never aborting the
# caller -- that is now _resolve_latest_cache_path's own contract rather than
# something this call site has to arrange.
_resolve_skills_base_dir() {
  # Layer 0: AIMI_DEV_DIR, ahead of the host split below and with no
  # CLAUDECODE gate -- see _dev_dir_path's header for why that gate is absent
  # here and present for AIMI_PLUGIN_DIR. This is what makes the override
  # actually useful rather than merely announced: a maintainer testing a
  # branch is usually testing a SKILL.md, and every agent /aimi:execute spawns
  # reads its skills from whatever this function answers. Resolving the CLI
  # from the dev tree while the spawned agents read the installed tree's
  # SKILL.md is the "two different installs answering in one session" defect
  # this function's own header already records, one variable over.
  #
  # The `-d` test is what keeps it honest: a dev tree with no skills/ falls
  # through to the ordinary host resolution rather than answering a path to
  # nothing. An invalid AIMI_DEV_DIR cannot reach here -- main() has already
  # exited 1 on it -- so the `|| dev_dir=""` covers only the re-consultation
  # cost, not a second refusal.
  local dev_dir=""
  dev_dir=$(_dev_dir_path) || dev_dir=""
  if [ -n "$dev_dir" ] && [ -d "$dev_dir/skills" ]; then
    printf '%s\n' "$dev_dir/skills"
    return 0
  fi
  if _is_claude_code_host; then
    local config_dir
    config_dir=$(_claude_config_dir)
    local skills_dir
    skills_dir=$(_resolve_latest_cache_path "$config_dir" "skills")
    if [ -z "$skills_dir" ]; then
      # No versioned cache entry -- a directory-source install has none to
      # find. Fall back to the same resolver the CLI path itself falls back
      # to, so "both sides now ask ... the same question" (see above) holds
      # for a directory-source host too, not only for the versioned-cache one.
      skills_dir=$(_resolve_directory_source_path "$config_dir" "skills")
    fi
    printf '%s\n' "${skills_dir:-}"
    return 0
  fi
  if [ -n "${AIMI_PLUGIN_DIR:-}" ]; then
    local plugin_dir
    plugin_dir=$(_validate_plugin_dir)
    if [ -n "$plugin_dir" ]; then
      printf '%s\n' "$plugin_dir/skills"
      return 0
    fi
  fi
  printf ''
}

# Get story context (story slice + metadata + skills + designContext + skillsDropped)
# by ID — for subagent self-brief.
#
# THE HOTTEST VERB IN THE SYSTEM: every story-executor agent /aimi:execute
# spawns runs this once, as its first action, and parses what comes back. It
# used to be 155 lines here, 8 fixed jq calls plus one per skill, with an
# accumulator that re-serialized every skill body already read on each new one.
# All of it is tasks.py's now; bash keeps only what bash owns.
#
# Four of those five lines are the same gates every other tasks verb runs, and
# _resolve_skills_base_dir is the fifth because it is a HOST question -- glob
# the Claude Code plugin cache, or read $AIMI_PLUGIN_DIR -- and CLAUDECODE is a
# discriminator this file already owns. Python is handed the answer, not the
# question. No lock: a reader takes none, and this one writes nothing at all.
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_get_story_context() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"
  local skills_base_dir

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh get-story-context <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  skills_base_dir=$(_resolve_skills_base_dir)

  check_python3
  python3 "$(_aimi_tasks_py)" get-story-context \
    --tasks-file "$tasks_file" --story-id "$story_id" \
    --project-root "$PROJECT_ROOT" --skills-base-dir "$skills_base_dir"
}

# Probe a story's implementation.verify ONE ASSERTION AT A TIME.
#
# The executor's pre-run answers "does this whole verify already pass before
# the work?". This answers the finer question the `set -e` in front of most
# verifies makes unanswerable: WHICH of its assertions already pass. Prints a
# JSON array of {segment, exit, discriminates, unsatisfiable}; an absent or
# empty verify is an empty array at exit 0.
#
# --previous-file names a PRIOR run's own JSON array -- the executor's
# pre-implementation call to this same verb, on this same story -- so a
# segment non-zero in both runs can be told apart from one that merely has
# not passed yet. It goes through resolve_path/validate_path_in_project like
# --tasks-file, because it too arrives as a CLI argument. Omitted, or naming a
# segment this run's script does not carry, every entry's `unsatisfiable` is
# false: see tasks.py's _match_previous for what the comparison actually does.
#
# The same five gates every other tasks verb runs, and the same one crossing --
# the decomposition, the per-segment run and the shape are tasks.py's. The only
# thing bash adds is the working directory, and it adds it because
# find_aimi_root's cd has already moved the process by the time any verb runs:
# AIMI_INVOCATION_DIR is the caller's own cwd, captured before that cd. It is
# not run through validate_path_in_project, because it is not an argument -- it
# is this process's own starting directory, and find_aimi_root walked UP from
# it to reach a root, so it is a descendant of one by construction.
#
# No lock: this reads the document and writes nothing to it.
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
#        --previous-file <path> (optional; a prior run's own output)
cmd_verify_probe() {
  local tasks_file positional=() previous_file="" remaining=()
  local args=("$@")
  local i=0 n=${#args[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${args[$i]}" = "--previous-file" ]; then
      i=$((i + 1))
      previous_file="${args[$i]:-}"
    else
      remaining+=("${args[$i]}")
    fi
    i=$((i + 1))
  done
  _parse_positional_tasks_file tasks_file positional "${remaining[@]}"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh verify-probe <story-id> [--tasks-file <path>] [--previous-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  local previous_args=()
  if [ -n "$previous_file" ]; then
    previous_file=$(resolve_path "$previous_file")
    validate_path_in_project "$previous_file"
    previous_args=(--previous-file "$previous_file")
  fi

  check_python3
  python3 "$(_aimi_tasks_py)" verify-probe \
    --tasks-file "$tasks_file" --story-id "$story_id" \
    --cwd "${AIMI_INVOCATION_DIR:-$PWD}" "${previous_args[@]}"
}

# List every planning defect a previous executor recorded in .aimi/known-gaps/.
#
# Those files are the only diagnosis this pipeline produces for free, and until
# now nothing read them back: /aimi:plan rediscovered a defect weeks after an
# executor had already written it down. This verb is the reader.
#
# NOT a tasks.json verb despite living in tasks.py: it reads a sibling
# directory of the same .aimi/ root and takes no --tasks-file at all. It is
# there because that is where the .aimi/ document rules live, and putting a
# second parser beside it would be the duplication the port removed.
#
# No lock and no path confinement: --feature and --since are filter strings,
# not paths, and the ONE path involved is "$AIMI_DIR/known-gaps", which is
# find_aimi_root's own export rather than an argument. validate_path_in_project
# rules arguments; there is no argument here for it to rule.
#
# Flags: --feature <name> (exact match), --since <YYYY-MM-DD> (inclusive)
cmd_list_known_gaps() {
  local feature="" since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature)
        shift
        feature="${1:-}"
        ;;
      --since)
        shift
        since="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh list-known-gaps [--feature <name>] [--since <YYYY-MM-DD>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  check_python3
  local args=(list-known-gaps --aimi-dir "$AIMI_DIR")
  [ -n "$feature" ] && args+=(--feature "$feature")
  [ -n "$since" ] && args+=(--since "$since")
  python3 "$(_aimi_tasks_py)" "${args[@]}"
}

# Mark a story as in-progress
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_mark_in_progress() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-in-progress <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  # BEFORE the lock, deliberately, and every mark-* verb keeps it there. Moving
  # it inside would close a TOCTOU window that is ranked and owned elsewhere;
  # closing it here by accident is exactly what test-tasks-concurrency.sh
  # exists to catch.
  validate_story_exists "$story_id" "$tasks_file"

  # One crossing, inside the lock -- read, decide, write and return, all in the
  # single call cmd_roadmap_set_status' comment describes. No stdin payload
  # here, so the two-crossing exemption roadmap-init holds does not apply. The
  # temp file is tasks.py's now (same directory, then os.replace), which is why
  # the mktemp and the mv that used to bracket this block are gone.
  check_python3
  (
    _lock "${tasks_file}.lock"
    python3 "$(_aimi_tasks_py)" mark-in-progress \
      --tasks-file "$tasks_file" --story-id "$story_id"
  ) 200>"${tasks_file}.lock"

  write_state "current-story" "$story_id"

  printf '{"id":"%s","status":"in_progress"}\n' "$story_id"
}

# Mark a story as complete
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_mark_complete() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-complete <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  # Before the lock. See cmd_mark_in_progress for why it stays there.
  validate_story_exists "$story_id" "$tasks_file"

  check_python3
  (
    _lock "${tasks_file}.lock"
    python3 "$(_aimi_tasks_py)" mark-complete \
      --tasks-file "$tasks_file" --story-id "$story_id"
  ) 200>"${tasks_file}.lock"

  clear_state_file "current-story"
  write_state "last-result" "success"

  printf '{"id":"%s","status":"completed"}\n' "$story_id"
}

# Mark a story as failed with notes
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_mark_failed() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"
  local notes="${positional[1]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-failed <story-id> [notes] [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  check_python3
  (
    _lock "${tasks_file}.lock"
    # --notes last: it is the one argument no pattern gates, and tasks.py reads
    # each flag by its FIRST occurrence so a note shaped like a flag cannot
    # answer for one.
    python3 "$(_aimi_tasks_py)" mark-failed \
      --tasks-file "$tasks_file" --story-id "$story_id" --notes "$notes"
  ) 200>"${tasks_file}.lock"

  clear_state_file "current-story"
  write_state "last-result" "failed"

  printf '{"id":"%s","status":"failed","notes":"%s"}\n' "$story_id" "$notes"
}

# Mark a story as skipped
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_mark_skipped() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh mark-skipped <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  check_python3
  (
    _lock "${tasks_file}.lock"
    python3 "$(_aimi_tasks_py)" mark-skipped \
      --tasks-file "$tasks_file" --story-id "$story_id"
  ) 200>"${tasks_file}.lock"

  clear_state_file "current-story"
  write_state "last-result" "skipped"

  printf '{"id":"%s","status":"skipped"}\n' "$story_id"
}

# Persist a --container/--inline override onto metadata.execution.
# execute.md and next.md call this after resolving a session-level override so
# a later re-invocation without the flag continues in the same mode instead of
# silently falling back to the file's original value. Refuses (non-zero exit)
# on a phase-scoped tasks file (metadata.phase present) — a claimed phase
# always runs inside its own phase container, so writing metadata.execution
# there would be the exact dead-data bug this subcommand exists to fix.
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_set_execution_mode() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local mode="${positional[0]:-}"

  if [ -z "$mode" ]; then
    echo "Usage: aimi-cli.sh set-execution-mode <container|inline> [--tasks-file <path>]" >&2
    exit 1
  fi

  if [ "$mode" != "container" ] && [ "$mode" != "inline" ]; then
    echo "Error: Invalid execution mode: $mode (expected container or inline)" >&2
    exit 1
  fi

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # One crossing, inside the lock. The phase guard used to be a jq read taken
  # OUTSIDE this lock, and the assignment a second jq into a bash mktemp file:
  # the two-crossing shape, spelled in jq rather than in python3, which is why
  # the counting test's own filter discarded this wrapper instead of failing
  # it. Guard, decision, write and echo-back are the single call now, and
  # tasks.py's write_docs_atomically owns the temp file -- so the mktemp/mv/
  # `rm -f` dance is DELETED here, not relocated.
  #
  # The invalid-mode refusal above stays in bash on the rule this file already
  # follows: it is reachable without reading the document, so it happens before
  # the lock. The phase-scoped one needs the document and moves into the
  # crossing, where tasks.py's die() writes the same line to stderr and exits 1.
  check_python3
  (
    _lock "${tasks_file}.lock"
    python3 "$(_aimi_tasks_py)" set-execution-mode \
      --tasks-file "$tasks_file" --mode "$mode"
  ) 200>"${tasks_file}.lock"
}

# Count pending stories
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_count_pending() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh count-pending [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  check_python3
  python3 "$(_aimi_tasks_py)" count-pending --tasks-file "$tasks_file"
}

# Validate dependencies in a tasks file
# Checks for: circular dependencies, missing IDs, self-references
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_validate_deps() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh validate-deps [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # A pure reader: no lock, no temp file, one crossing. The exit status is the
  # crossing's own, which is what it was before -- the jq verdict and the
  # `is_valid != "true"` test that used to follow it both live in tasks.py, so
  # the two cannot answer differently.
  check_python3
  python3 "$(_aimi_tasks_py)" validate-deps --tasks-file "$tasks_file"
}

# Validate story content (field lengths, suspicious patterns)
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_validate_stories() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh validate-stories [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # Same shape as cmd_validate_deps above, and the same reason. Every one of
  # this verb's twenty-odd error strings is read by /aimi:plan's Phase 4.5 loop
  # and Phase 3e staging check, so they moved character-for-character rather
  # than being retyped.
  check_python3
  python3 "$(_aimi_tasks_py)" validate-stories --tasks-file "$tasks_file"
}

# Normalize verification fields: rewrite any bare-string verification into object form
cmd_normalize_verification() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-verification <tasks-file-path>" >&2
    exit 1
  fi

  if [ ! -f "$tasks_file" ]; then
    echo "Error: tasks file not found: $tasks_file" >&2
    exit 1
  fi

  if [ ! -r "$tasks_file" ]; then
    echo "Error: tasks file not readable: $tasks_file" >&2
    exit 1
  fi

  # Validate input is valid JSON
  if ! jq empty "$tasks_file" 2>/dev/null; then
    echo "Error: invalid JSON in tasks file: $tasks_file" >&2
    exit 1
  fi

  # One crossing, inside the lock. The count comes back from the same call that
  # performed the write -- it used to be a second jq run after the lock had
  # been released, i.e. a re-read of a document another writer could already
  # have changed. Same value in a single process; one less window.
  check_python3
  local out
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" normalize-verification --tasks-file "$tasks_file"
    ) 200>"${tasks_file}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Normalize status fields: default any story missing the status field to "pending"
cmd_normalize_status() {
  local tasks_file="$1"

  if [ -z "$tasks_file" ]; then
    echo "Usage: aimi-cli.sh normalize-status <tasks-file-path>" >&2
    exit 1
  fi

  if [ ! -f "$tasks_file" ]; then
    echo "Error: tasks file not found: $tasks_file" >&2
    exit 1
  fi

  if [ ! -r "$tasks_file" ]; then
    echo "Error: tasks file not readable: $tasks_file" >&2
    exit 1
  fi

  # Validate input is valid JSON
  if ! jq empty "$tasks_file" 2>/dev/null; then
    echo "Error: invalid JSON in tasks file: $tasks_file" >&2
    exit 1
  fi

  # One crossing, inside the lock. Same shape, and same reason, as
  # cmd_normalize_verification above.
  check_python3
  local out
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" normalize-status --tasks-file "$tasks_file"
    ) 200>"${tasks_file}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Validate all story IDs in the tasks file against the US-NNN format
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_validate_ids() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh validate-ids [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # The regex, the line-at-a-time walk over `jq -r` output and the ASYMMETRIC
  # pass/failure shapes all moved together, because they are one rule: the
  # count exists only on the pass branch and the errors only on the failure
  # one, and /aimi:plan reads them apart.
  check_python3
  python3 "$(_aimi_tasks_py)" validate-ids --tasks-file "$tasks_file"
}

# Cascade skip: given a failed story ID, mark all transitively-dependent stories as skipped
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_cascade_skip() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local failed_id="${positional[0]:-}"

  if [ -z "$failed_id" ]; then
    echo "Usage: aimi-cli.sh cascade-skip <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$failed_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$failed_id" "$tasks_file"

  # BEHAVIOUR CHANGE, and the one this verb existed to get. This used to be
  # two jq calls with the lock around only the second: an UNLOCKED closure
  # computed the skip set, and the locked apply took that precomputed id list
  # on trust -- its inner filter asked `is this id in the list?` and nothing
  # else. The `status != "completed"` test lived only in the unlocked call, so
  # a story that completed inside the window (measured in seconds at 400
  # stories, because the closure was a quadratic `reduce range(length)`) was
  # overwritten with status "skipped" and a note saying it depended on a
  # failure. Real work, lost, 8 times out of 8.
  #
  # One crossing, inside the lock: the closure, both status filters, the write
  # and the {skipped, count} report all happen against the same document. There
  # is nowhere left to put an unlocked read, which is what closes the race.
  # test-tasks-concurrency.sh asserts it; the golden corpus is single-threaded
  # and cannot see it.
  check_python3
  local out
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" cascade-skip \
        --tasks-file "$tasks_file" --failed-id "$failed_id"
    ) 200>"${tasks_file}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Reset orphaned in_progress stories to failed
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_reset_orphaned() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh reset-orphaned [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # A REPORT FIX, and only a report fix. Do not rank it with cascade-skip.
  #
  # The orphan list was read in an unlocked jq here too, but the locked apply
  # re-selected `status == "in_progress"` and ignored that list entirely, so
  # the file on disk was ALREADY correct: a story that stopped being in
  # progress inside the window was never touched. What could be wrong was the
  # printed {count, reset} report, built from the stale read -- a caller
  # trusting stdout over the file believed it had reset a story it had not.
  # No data was ever lost here and none is recovered.
  #
  # One crossing, inside the lock, so the ids printed are the ids written. The
  # empty case still writes nothing; that decision moved inside the lock, the
  # guarantee did not move at all.
  check_python3
  local out
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" reset-orphaned --tasks-file "$tasks_file"
    ) 200>"${tasks_file}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Get branch name
#
# The FAST PATH still opens nothing. read_state answers from .aimi/, and only
# an empty answer reaches the document at all -- a populated session state
# never starts python3, never resolves a tasks file, and is unaffected by what
# the document holds (gb-estado-presente-sem-documento answers with no tasks
# file on disk; gb-estado-presente-documento-hostil answers while the document
# holds a name init-session would refuse).
#
# REFUSES --tasks-file (does not honor it), for the same reason
# cmd_current_story does -- the answer comes from session state and a tasks
# file is only a secondary lookup. The scan runs before the fast path so the
# refusal fires even when the fast path would otherwise answer without ever
# opening a tasks file.
cmd_get_branch() {
  local _gb_arg
  for _gb_arg in "$@"; do
    if [ "$_gb_arg" = "--tasks-file" ]; then
      echo "Error: Unknown flag: --tasks-file" >&2
      echo "Usage: aimi-cli.sh get-branch" >&2
      exit 1
    fi
  done

  local branch
  branch=$(read_state "current-branch")

  if [ -z "$branch" ]; then
    local tasks_file
    tasks_file=$(get_tasks_file)
    check_python3
    branch=$(python3 "$(_aimi_tasks_py)" get-branch --tasks-file "$tasks_file") || exit $?
  fi

  echo "$branch"
}

# Get all state as JSON
#
# The four reads stay here and the VALUES cross, never the paths: read_state
# carries validate_path_in_project and .aimi/state/ has its own .state.lock,
# neither of which tasks.py is allowed to acquire a second opinion about. All
# the op does is the "" -> null mapping that used to be four jq conditionals.
cmd_get_state() {
  local tasks branch story last
  tasks=$(read_state "current-tasks")
  branch=$(read_state "current-branch")
  story=$(read_state "current-story")
  last=$(read_state "last-result")

  check_python3
  python3 "$(_aimi_tasks_py)" get-state \
    --tasks "$tasks" --branch "$branch" --story "$story" --last "$last"
}

# Shared `--project`/git-repository entry guard. Fourteen commands each
# carried a byte-identical copy of this block before it was extracted here:
# cd into the requested project directory when one was given (multi-repo
# layouts, where the AIMI root is not itself a git repo), then require the
# resulting working directory to be a git repository. Exits 1 with the
# unchanged wording on either failure.
#
# An empty argument means "use the invoking CWD" -- which is exactly what an
# omitted --project already resolved to, so no caller needs to special-case it.
# The `cd` intentionally escapes into the caller (a function's cd is not
# scoped), because that is what the fourteen inline copies did.
#
# Deliberately NOT named _forge_*: ten of the fourteen callers are forge verbs,
# but cmd_detect_default_branch, cmd_detect_parent_branch, cmd_setup_branch and
# cmd_resolve_base_branch share this guard by behaviour, not by domain. A forge
# prefix would misdescribe a quarter of its own callers, so the name follows
# this file's other domain-neutral private helpers (_local_has_branch,
# _is_merged_into_default, _file_size_bytes).
#
# Usage: _require_git_repo "$project_dir"
_require_git_repo() {
  local project_dir="$1"
  if [ -n "$project_dir" ]; then
    if [ ! -d "$project_dir" ]; then
      echo "Error: Project directory does not exist: $project_dir" >&2
      exit 1
    fi
    cd "$project_dir"
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository. Use --project <path> to specify the git repo directory." >&2
    exit 1
  fi
}

# Derive a filesystem-safe cache-key suffix for a repository toplevel path,
# so _resolve_default_branch's cache is scoped per repository instead of a
# single shared file under AIMI_ROOT/.aimi/ (which silently leaked one
# repo's resolved branch into every sibling --project call). Mirrors the
# sha256sum/shasum branch shape of _hash_file (aimi-cli.sh:2035-2042) but
# adds an explicit `command -v shasum` probe that helper lacks, and falls
# back to a portable non-sha256 slugification when neither hashing tool is
# available -- the slugification never introduces a `/`, so the returned
# suffix is always safe to use as a flat filename directly inside .aimi/.
# SECOND CALLER since phase 2: _forge_account_store_path hashes the absolute
# git common dir with this same helper. Its behavior is therefore frozen --
# the digest emitted for a given input must stay byte-identical, because
# `.aimi/default-branch-<hash>` files already exist on disk.
# Usage: _default_branch_cache_key <repo-toplevel-path>
# Prints: a filesystem-safe string containing no `/`
_default_branch_cache_key() {
  local toplevel="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    printf '%s' "$toplevel" | sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    printf '%s' "$toplevel" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$toplevel" | tr -c 'A-Za-z0-9' '-'
  fi
}

# Shared default-branch resolution logic: cache read, primary git remote
# show origin parse, offline symbolic-ref fallback, cache write. Assumes the
# caller has already cd'd into the target repo and verified it is a git
# repository (both cmd_detect_default_branch and cmd_detect_parent_branch
# do this themselves before calling here). The cache is keyed per repository
# toplevel (default-branch-<hash>) rather than a single shared
# "default-branch" file, so a sibling repo's --project call cannot inherit
# another repo's cached branch. Returns the branch name on stdout; exits 1
# on total failure.
_resolve_default_branch() {
  local repo_toplevel cache_key
  repo_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || repo_toplevel=""
  cache_key="default-branch-$(_default_branch_cache_key "$repo_toplevel")"

  # Return cached value if available
  local cached
  cached=$(read_state "$cache_key")
  if [ -n "$cached" ]; then
    echo "$cached"
    return 0
  fi

  local branch=""

  # Primary: parse HEAD branch from remote
  branch=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p') || branch=""

  # Fallback: symbolic-ref (works offline)
  if [ -z "$branch" ]; then
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || branch=""
  fi

  if [ -z "$branch" ]; then
    echo "Error: Could not detect default branch" >&2
    exit 1
  fi

  # Cache for session reuse
  write_state "$cache_key" "$branch"
  echo "$branch"
}

# Detect the repository's default branch
# Primary: git remote show origin (requires network)
# Fallback: git symbolic-ref refs/remotes/origin/HEAD (offline)
# Caches result in .aimi/default-branch for session reuse
cmd_detect_default_branch() {
  local project_dir=""

  # Parse --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _resolve_default_branch
}

# ============================================================================
# Forge Detection (detect-forge)
# ============================================================================
# FOUNDATIONAL CONTRACT for every forge-* verb in this phase: the output
# shape {forge, host, remote, remoteUrl, source} is consumed verbatim
# downstream and must not be re-derived. See cmd_help's detect-forge entry
# and this story's acceptance criteria for the full contract.

# Parse a git remote URL's hostname: lowercased, no port, no userinfo, no
# path. Handles three shapes: an explicit ssh://[user[:pass]@]host[:port]/path
# or https://[user[:pass]@]host[:port]/path (strip scheme, then strip
# userinfo up to the LAST "@" within the authority only -- never inside the
# path -- then split a trailing :<digits> port off the authority), and git's
# scp-like [user@]host:path form (no "://" present -- the substring up to the
# FIRST ":" is the host, everything after it is PATH, never a port; this is
# the exact ambiguity an alternate-port ssh://...:2222/... URL must not
# collide with). Prints empty on an unparseable string.
_detect_forge_parse_host() {
  local url host authority rest
  url=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  host=""

  if [[ "$url" == *"://"* ]]; then
    rest="${url#*://}"
    authority="${rest%%/*}"
    if [[ "$authority" == *"@"* ]]; then
      authority="${authority##*@}"
    fi
    if [[ "$authority" =~ ^(.+):([0-9]+)$ ]]; then
      host="${BASH_REMATCH[1]}"
    else
      host="$authority"
    fi
  elif [[ "$url" == *":"* ]]; then
    rest="$url"
    if [[ "$rest" == *"@"* ]]; then
      rest="${rest##*@}"
    fi
    host="${rest%%:*}"
  fi

  printf '%s' "$host"
}

# Exact-or-subdomain classification of a lowercase hostname against the fixed
# known-forge host list, first match wins: github.com -> github; gitlab.com
# -> gitlab; gitea.com, codeberg.org -> gitea. Gitea's own SaaS host and
# codeberg.org (the largest public Forgejo instance) are both recognized
# under the single "gitea" adapter, since Forgejo is a compatibility-
# preserving fork of Gitea and the two are deliberately NOT distinguished
# anywhere in this contract. Any other host -- including a GitHub Enterprise
# Server host on a company-owned domain -- prints "unknown"; never guesses.
_detect_forge_classify_host() {
  local host="$1"
  case "$host" in
    github.com|*.github.com) printf 'github' ;;
    gitlab.com|*.gitlab.com) printf 'gitlab' ;;
    gitea.com|*.gitea.com|codeberg.org|*.codeberg.org) printf 'gitea' ;;
    *) printf 'unknown' ;;
  esac
}

# Implements the remote-precedence rule using only local reads -- `git
# remote` to list configured remote names, `git remote get-url <name>` to
# read a URL -- never `git remote show`, which dials the remote over the
# network (the same lesson _resolve_default_branch already paid for; see its
# "requires network" comment above). Precedence: an `origin` remote always
# wins outright, even when it disagrees with every other configured remote;
# else exactly one remote (any name) wins; else zero remotes is a distinct
# outcome ("no-remote") from two-or-more disagreeing remotes ("ambiguous-
# remotes", forge always unknown) -- never resolved by picking `git remote`'s
# listing order. Emits {remote, remoteUrl, source} as three plain-text lines
# -- remote name, source, remote URL, in that order -- and spawns no jq
# process to move them, so _detect_forge_type below can reach this
# precedence rule for free. The URL is deliberately LAST: a pathological
# remote URL carrying an embedded newline can then only truncate itself,
# never shift the two fields classification actually branches on.
#
# This is the single implementation of the precedence rule.
# _detect_forge_select_remote below is a thin JSON-wrapping shim over it, so
# the jq-free and JSON-emitting paths can never drift into two subtly
# different answers to the same question.
_detect_forge_select_remote_raw() {
  local remotes remote_count remote_name="" remote_url="" source=""
  remotes=$(git remote 2>/dev/null) || remotes=""

  if [ -n "$remotes" ] && printf '%s\n' "$remotes" | grep -qx "origin"; then
    remote_name="origin"
    remote_url=$(git remote get-url origin 2>/dev/null) || remote_url=""
    source="remote"
  else
    remote_count=0
    if [ -n "$remotes" ]; then
      remote_count=$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')
    fi
    if [ "$remote_count" -eq 0 ]; then
      source="no-remote"
    elif [ "$remote_count" -eq 1 ]; then
      remote_name="$remotes"
      remote_url=$(git remote get-url "$remote_name" 2>/dev/null) || remote_url=""
      source="remote"
    else
      source="ambiguous-remotes"
    fi
  fi

  printf '%s\n%s\n%s\n' "$remote_name" "$source" "$remote_url"
}

# Reads _detect_forge_select_remote_raw's three lines back into three
# caller-named variables. A plain `IFS= read` loop rather than `$(...)` plus
# parameter expansion, because command substitution strips trailing
# newlines: an empty remote URL would collapse "third line, empty" into "no
# third line at all" and slide `source` into the URL slot.
#
# Internals are _dsr_-prefixed so a caller's own remote/source/url locals can
# never shadow the name-reference targets -- the same collision
# _forge_capture's _fc_ prefixes exist to prevent.
# Usage: _detect_forge_read_selection <name_var> <source_var> <url_var>
_detect_forge_read_selection() {
  local -n _dsr_name="$1" _dsr_source="$2" _dsr_url="$3"
  _dsr_name=""
  _dsr_source=""
  _dsr_url=""

  local _dsr_line _dsr_i=0
  while IFS= read -r _dsr_line; do
    case "$_dsr_i" in
      0) _dsr_name="$_dsr_line" ;;
      1) _dsr_source="$_dsr_line" ;;
      2) _dsr_url="$_dsr_line" ;;
    esac
    _dsr_i=$((_dsr_i + 1))
  done < <(_detect_forge_select_remote_raw)
}

# Unchanged public contract: the {remote, remoteUrl, source} JSON object
# _detect_forge already consumes, byte-identical to what this function
# emitted before it was split. All it does now is wrap the raw helper's
# three values -- the precedence logic itself lives there.
_detect_forge_select_remote() {
  local remote_name remote_url source
  _detect_forge_read_selection remote_name source remote_url

  jq -nc \
    --arg remote "$remote_name" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Strips embedded userinfo credentials (user:pass@ or user@) from an http(s)
# remote URL's authority before it is echoed back in detect-forge's JSON
# output -- a secret must never round-trip through CLI stdout/logs. No-op on
# any other scheme (in particular ssh://, whose leading "user@" is a literal
# SSH login user such as "git@", never a credential -- the same reason git's
# scp-like [user@]host:path form is left untouched below) and on a URL
# carrying no userinfo at all.
_detect_forge_redact_userinfo() {
  local url="$1" scheme scheme_lc rest authority path
  if [[ "$url" != *"://"* ]]; then
    printf '%s' "$url"
    return 0
  fi

  scheme="${url%%://*}"
  # URL schemes are case-insensitive (RFC 3986 s3.1), so match on a lowered
  # copy -- an "HTTPS://" remote must be redacted exactly like "https://".
  # $scheme itself keeps its original case for the printf below, so
  # redaction never silently rewrites the caller's URL beyond the credential
  # it was asked to strip.
  scheme_lc=$(printf '%s' "$scheme" | tr 'A-Z' 'a-z')
  case "$scheme_lc" in
    http|https) ;;
    *)
      printf '%s' "$url"
      return 0
      ;;
  esac

  rest="${url#*://}"
  if [[ "$rest" == *"/"* ]]; then
    authority="${rest%%/*}"
    path="/${rest#*/}"
  else
    authority="$rest"
    path=""
  fi

  if [[ "$authority" == *"@"* ]]; then
    authority="${authority##*@}"
  fi

  printf '%s://%s%s' "$scheme" "$authority" "$path"
}

# Composes the final {forge, host, remote, remoteUrl, source} object.
# AIMI_FORGE_TYPE (already validated by the caller, cmd_detect_forge) short-
# circuits before any git command runs at all when set and non-empty --
# source=override, host/remote/remoteUrl all null. Otherwise selects a
# remote per _detect_forge_select_remote; only when that selection actually
# chose a URL (source=="remote") does it classify the host and redact
# embedded userinfo before echoing the URL back. detect-forge is per-
# repository and is NEVER cached via read_state/write_state -- a multi-repo
# AIMI_ROOT can legitimately mix a GitHub repo and a self-hosted GitLab repo
# under sibling --project calls, and any cache would go stale the moment a
# remote is repointed.
_detect_forge() {
  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    jq -nc --arg forge "$AIMI_FORGE_TYPE" \
      '{forge: $forge, host: null, remote: null, remoteUrl: null, source: "override"}'
    return 0
  fi

  local selection remote remote_url source forge="unknown" host=""
  selection=$(_detect_forge_select_remote)
  remote=$(printf '%s' "$selection" | jq -r '.remote // ""')
  remote_url=$(printf '%s' "$selection" | jq -r '.remoteUrl // ""')
  source=$(printf '%s' "$selection" | jq -r '.source')

  if [ "$source" = "remote" ] && [ -n "$remote_url" ]; then
    host=$(_detect_forge_parse_host "$remote_url")
    forge=$(_detect_forge_classify_host "$host")
    remote_url=$(_detect_forge_redact_userinfo "$remote_url")
  fi

  jq -nc \
    --arg forge "$forge" \
    --arg host "$host" \
    --arg remote "$remote" \
    --arg remoteUrl "$remote_url" \
    --arg source "$source" \
    '{forge: $forge,
      host: (if $host == "" then null else $host end),
      remote: (if $remote == "" then null else $remote end),
      remoteUrl: (if $remoteUrl == "" then null else $remoteUrl end),
      source: $source}'
}

# Per-process memo behind _detect_forge_type, keyed on the working directory
# each answer was derived in.
#
# KEYED, NOT GLOBAL, AND THAT DISTINCTION IS THE WHOLE POINT: a multi-repo
# AIMI_ROOT is a plain non-git parent holding one git repository per
# subfolder (see CLAUDE.md's Multi-Repo Execution Layout), and those
# siblings can legitimately be a GitHub repo and a GitLab repo. One process
# visiting both must get two answers. A single-slot cache would degrade into
# "whichever repository was classified most recently" and silently report
# github for the gitlab sibling -- the exact leak _detect_forge's own
# "NEVER cached" header comment exists to prevent, reintroduced by the back
# door. That comment is about a PERSISTED cache (read_state/write_state,
# which survives a repointed remote); this memo lives and dies with one
# invocation and is never written to disk.
declare -gA _DETECT_FORGE_TYPE_MEMO

# The forge word alone -- github|gitlab|gitea|unknown -- for the callers
# that need only that and threw the rest of _detect_forge's envelope away.
# No JSON is built or parsed anywhere on this path: it reaches the same
# precedence rule through _detect_forge_select_remote_raw and the
# already-pure-bash _detect_forge_parse_host/_detect_forge_classify_host, so
# a derivation costs the two `git remote` reads and nothing else.
#
# WHO DOES *NOT* USE THIS, AND WHY: _forge_repo_info and _forge_auth_status
# read `host`/`remoteUrl` out of the envelope, and so -- since US-004 grew
# the shared failure classifier -- do _forge_issue_view,
# _forge_pr_review_threads and _forge_resolve_review_thread, each of which
# now hands `host` to _forge_classify_gh_failure_reason. This function
# carries no host, so all five deliberately keep their full _detect_forge
# call. Widening the memo to the whole envelope would serve them too and is
# a reasonable follow-up, but it is a different change from this one.
#
# OUT-PARAMETER, NOT STDOUT, AND THAT IS LOAD-BEARING: a printed answer
# forces every call site into `forge=$(_detect_forge_type)`, whose command
# substitution forks a subshell -- and a memo populated inside a subshell
# dies with it, leaving every call site a full derivation again. Writing
# through a name reference keeps the memo in the ONE process that will reuse
# it. Subshells forked later (`existing=$(cmd_forge_pr_view ...)` inside
# _forge_pr_create) inherit the populated array and read it as a hit, which
# is what collapses a create-a-new-PR run from three derivations to one.
#
# AIMI_FORGE_TYPE short-circuits before the memo as well as before any git
# command: it is already a zero-cost stateless read, and it is deliberately
# NOT validated here, mirroring _detect_forge's own override precedent above
# (cmd_detect_forge validates it once, and internal callers already trust
# the value unvalidated through _detect_forge).
#
# Internals are _dft_-prefixed so a caller's own `forge` local can never
# shadow the name-reference target.
# Usage: _detect_forge_type <forge_var>
_detect_forge_type() {
  local -n _dft_out="$1"

  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    _dft_out="$AIMI_FORGE_TYPE"
    return 0
  fi

  # $PWD, deliberately, rather than a subshelled `pwd -P`: every cmd_forge_*
  # wrapper's --project handling cd's into its final working directory
  # exactly once, before any forge derivation runs, so $PWD is stable and
  # correct for the whole remaining lifetime of the invocation at zero fork
  # cost.
  local _dft_key="$PWD"
  if [ -n "${_DETECT_FORGE_TYPE_MEMO[$_dft_key]+set}" ]; then
    _dft_out="${_DETECT_FORGE_TYPE_MEMO[$_dft_key]}"
    return 0
  fi

  local _dft_name _dft_source _dft_url _dft_forge="unknown"
  _detect_forge_read_selection _dft_name _dft_source _dft_url

  if [ "$_dft_source" = "remote" ] && [ -n "$_dft_url" ]; then
    _dft_forge=$(_detect_forge_classify_host "$(_detect_forge_parse_host "$_dft_url")")
  fi

  _DETECT_FORGE_TYPE_MEMO["$_dft_key"]="$_dft_forge"
  _dft_out="$_dft_forge"
}

# Detect the forge (github|gitlab|gitea|unknown) for the active git remote.
# AIMI_FORGE_TYPE overrides detection entirely and must be one of
# github|gitlab|gitea, validated here -- before _detect_forge ever runs --
# so an invalid value never reaches a git command. Never cached (see
# _detect_forge's header comment: per-repository, per-invocation).
cmd_detect_forge() {
  check_jq

  local project_dir=""

  # Parse --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    case "$AIMI_FORGE_TYPE" in
      github|gitlab|gitea) ;;
      *)
        echo "Error: detect-forge: unrecognized AIMI_FORGE_TYPE value: $AIMI_FORGE_TYPE (expected one of: github, gitlab, gitea)" >&2
        exit 1
        ;;
    esac
  fi

  _detect_forge
}

# Normalize a single %D decoration token for parent-branch detection.
# Pipeline: (1) strip an "X -> Y" arrow decoration, keeping the right-hand
# side (covers "HEAD -> <branch>" and, defensively, "origin/HEAD ->
# origin/<branch>"); (2) drop a bare HEAD token; (3) drop a tag: -prefixed
# token; (4) strip a leading origin/ remote-tracking prefix; (5) re-check
# for a bare HEAD token now that origin/ has been stripped (catches
# "origin/HEAD" -> "HEAD"); (6) drop the token if it is now empty or equals
# the branch being examined exactly -- exact match only, never a substring
# match (this is the DEFECT 3 fix for the old grep -v "$CURRENT_BRANCH").
# Prints the surviving token, or nothing when the token was dropped.
_normalize_decoration_token() {
  local token="$1" branch="$2"

  # (1) Arrow decoration: keep the right-hand side.
  if [[ "$token" == *" -> "* ]]; then
    token="${token#*" -> "}"
  fi

  # (2) Bare HEAD (detached-HEAD marker, or the left side of an
  #     already-stripped arrow that somehow left just HEAD).
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (3) Tag refs are never a parent-branch candidate.
  if [[ "$token" == "tag: "* ]]; then
    return 0
  fi

  # (4) Strip the remote-tracking prefix.
  if [[ "$token" == "origin/"* ]]; then
    token="${token#origin/}"
  fi

  # (5) Re-check for HEAD now that origin/ has been stripped.
  if [ "$token" = "HEAD" ]; then
    return 0
  fi

  # (6) Exact-match-only drop: empty token, or the token IS the branch
  #     we're examining (its own tip decoration). Never a substring check.
  if [ -z "$token" ] || [ "$token" = "$branch" ]; then
    return 0
  fi

  printf '%s' "$token"
}

# Walk branch's --first-parent decoration history (git log --pretty=format:'%D')
# token-by-token, nearest ancestor first, and return the first surviving
# candidate parent-branch name after _normalize_decoration_token. Prints
# nothing when no candidate survives across the whole history.
# Emits EVERY decoration candidate in --first-parent walk order, one per
# line, deduplicated -- not just the first. The caller verifies them in that
# order and takes the first that survives merge-base.
#
# WHY THIS EMITS A LIST RATHER THAN ONE VALUE. It used to return the first
# token that normalized and stop there, with verification happening
# afterwards in the caller. A rejected first candidate therefore ended the
# search: not the next token on the same line, not the next commit, straight
# to the default branch. Reproduced: a leftover story-branch ref pointing at
# the same tip as the branch being resolved is normalized (its name differs),
# then rejected by the caller's own "candidate must not be the branch's own
# tip" rule -- and a genuine parent nine commits further down, carrying a
# valid decoration, was never consulted. detect-parent-branch answered
# `main`/unverified for a branch cut from a feature branch; removing that one
# ref made it answer correctly with nothing else changed. A search that
# discards a candidate without resuming is not a search.
_detect_parent_branch_candidate() {
  local branch="$1"
  local log_output
  log_output=$(git log "$branch" --pretty=format:'%D' --first-parent 2>/dev/null) || true

  local line raw_token normalized seen=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local -a tokens
    local old_ifs="$IFS"
    IFS=','
    read -ra tokens <<< "$line"
    IFS="$old_ifs"

    for raw_token in "${tokens[@]}"; do
      # Decoration tokens are separated by ", " -- trim the leading space.
      raw_token="${raw_token# }"
      normalized=$(_normalize_decoration_token "$raw_token" "$branch")
      [ -n "$normalized" ] || continue
      # Dedupe: the same branch name can decorate more than one commit on the
      # walk, and re-verifying it would cost a git call per repeat.
      case "$seen" in
        *"|${normalized}|"*) continue ;;
      esac
      seen="${seen}|${normalized}|"
      printf '%s\n' "$normalized"
    done
  done <<< "$log_output"
}

# Verify a decoration candidate is a genuine ancestor of branch via
# git merge-base, rejecting a divergent sibling whose ref happens to share
# the candidate's (post-normalization) name. Resolves the candidate against
# a local branch first, falling back to an origin-prefixed remote-tracking
# ref only when no local branch of that name exists.
#
# Prints the candidate's own commit SHA on success (nothing on failure) so
# the caller can tell two verified candidates that happen to sit on the
# SAME commit -- e.g. an integration branch and the default branch that
# have not diverged yet -- apart from two verified candidates at genuinely
# different commits, which is the ordinary nested-branch case, not a tie.
_verify_parent_candidate() {
  local branch="$1" candidate="$2"
  local candidate_ref candidate_commit branch_commit merge_base

  if candidate_commit=$(git rev-parse --verify "${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="$candidate"
  elif candidate_commit=$(git rev-parse --verify "origin/${candidate}^{commit}" 2>/dev/null); then
    candidate_ref="origin/${candidate}"
  else
    return 1
  fi

  branch_commit=$(git rev-parse --verify "${branch}^{commit}" 2>/dev/null) || return 1

  # The candidate must not be the branch's own tip commit.
  if [ "$candidate_commit" = "$branch_commit" ]; then
    return 1
  fi

  # The candidate must be a genuine ancestor of branch (its own commit is
  # the merge base), not a divergent sibling.
  merge_base=$(git merge-base "$branch" "$candidate_ref" 2>/dev/null) || return 1

  if [ "$merge_base" = "$candidate_commit" ]; then
    printf '%s' "$candidate_commit"
    return 0
  fi
  return 1
}

# Detect a branch's parent (base) branch by parsing its --first-parent git
# log decorations token-by-token (replacing the old grep -v line-filtering
# pipeline in commands/open-pr.md, which mishandled "HEAD -> <parent>" and
# substring-alike branch names) and confirming the candidate with
# git merge-base. Falls back to the repository's default branch (unverified)
# when no decoration candidate survives normalization or merge-base
# verification.
#
# Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]
# Output: {"branch":<input>,"base":<resolved>,"verified":<bool>,"source":<source>,"candidates":<candidates>}
#
# `source` takes one of three values, following detect-forge's own
# ambiguous-remotes precedent (this section's comment above _detect_forge's
# builder) rather than inventing a new vocabulary:
#   "decoration"          -- exactly one candidate verified at the nearest
#                            surviving commit. `base` is that candidate,
#                            `verified` is true, `candidates` is null.
#   "ambiguous-decoration" -- two or more candidates verified at the SAME
#                            nearest commit (e.g. an integration branch and
#                            the default branch that have not diverged yet,
#                            with a phase branch cut from either). This verb
#                            cannot pick a winner among them, so it never
#                            asserts one: `base` falls back to the
#                            repository's default branch, `verified` is
#                            false, and `candidates` is the tied names in
#                            walk order -- the shape the caller must branch
#                            on instead of trusting `base` as a confirmed
#                            parent. This is the fix for the regression
#                            commit 4384273 introduced (issue #87): that
#                            topology used to answer verified true with
#                            source "decoration", picking whichever tied
#                            name decoration listing order put first.
#   "default-branch"      -- no candidate survived normalization or
#                            merge-base verification at all. `base` is the
#                            repository's default branch, `verified` is
#                            false, `candidates` is null.
# `branch`, `base` and `verified` keep the names and meanings they had
# before this contract grew a third source value; `candidates` is the
# additive field, null except under "ambiguous-decoration".
cmd_detect_parent_branch() {
  local branch="" project_dir=""

  # Parse positional branch arg + --project flag
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        if [ -z "$branch" ]; then
          branch="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$branch" ]; then
    echo "Usage: aimi-cli.sh detect-parent-branch <branch> [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security) — before any git command uses it
  if ! [[ "$branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch" >&2
    exit 1
  fi

  local raw_candidate
  local base="" verified="false" source="default-branch"
  local -a winners=()
  local winning_commit=""

  # Walk every candidate in nearest-first order (never break early -- see
  # _detect_parent_branch_candidate's header for what breaking on the first
  # rejection used to cost). A candidate that verifies is compared against
  # the FIRST verified candidate's own commit: sharing that exact commit
  # makes it a tie (both are decorations on the same nearest commit, e.g.
  # an integration branch and the default branch that have not diverged
  # yet); a different, farther commit makes it a legitimate but more
  # distant ancestor further up the tree -- not a tie, and not the answer,
  # since the nearest one already wins. Only the first tied group is ever
  # collected: walk order guarantees tied decorations on one commit are
  # adjacent in the candidate stream, so once a verified candidate's commit
  # differs from winning_commit, every candidate at the nearest commit has
  # already been seen.
  while IFS= read -r raw_candidate; do
    [ -n "$raw_candidate" ] || continue
    # Decoration names are repository-supplied -- a hostile upstream you clone,
    # or anyone with push access, can create a ref named `-n` or `--rawfile`
    # (git branch refuses those, git update-ref does not, and git fetch carries
    # them). Until this guard, the ONLY validated value in this function was
    # the caller-supplied $branch, i.e. the one that needed it least. Hold a
    # decoration to the same allowlist a branch name gets everywhere else, so
    # a name that could never be a branch never reaches the JSON, the base, or
    # jq's argument list.
    case "$raw_candidate" in
      *[!a-zA-Z0-9/_-]*|-*|/*) continue ;;
    esac
    local candidate_commit
    if candidate_commit=$(_verify_parent_candidate "$branch" "$raw_candidate"); then
      if [ -z "$winning_commit" ]; then
        winning_commit="$candidate_commit"
        winners=("$raw_candidate")
      elif [ "$candidate_commit" = "$winning_commit" ]; then
        winners+=("$raw_candidate")
      fi
    fi
  done <<< "$(_detect_parent_branch_candidate "$branch")"

  local candidates_json="null"
  if [ "${#winners[@]}" -eq 1 ]; then
    base="${winners[0]}"
    verified="true"
    source="decoration"
  elif [ "${#winners[@]}" -gt 1 ]; then
    base=$(_resolve_default_branch)
    verified="false"
    source="ambiguous-decoration"
    # `--` is required, not decorative: --args does NOT stop jq parsing later
    # arguments as flags, so without it a ref named `-n` is silently swallowed
    # (the candidates array would omit the very name causing the tie) and one
    # named `--rawfile` aborts the verb with no JSON at all. The allowlist in
    # the loop above already rejects both; this is the second lock.
    candidates_json=$(jq -nc --args '$ARGS.positional' -- "${winners[@]}")
  else
    base=$(_resolve_default_branch)
  fi

  jq -nc \
    --arg branch "$branch" \
    --arg base "$base" \
    --argjson verified "$verified" \
    --arg source "$source" \
    --argjson candidates "$candidates_json" \
    '{branch: $branch, base: $base, verified: $verified, source: $source, candidates: $candidates}'
}

# ============================================================================
# Forge Contract — shared builders and degradation helper (US-002)
# ============================================================================
# This section delivers two artifacts this phase's roadmap declares under
# creates[], each named here verbatim on its own line so a text search finds
# the identity intact rather than split across a wrapped comment:
#
# normalized PR and issue field contract
#
# forge degradation contract (missing adapter or missing CLI prints a manual instruction)
#
# Full documentation, including the state-mapping table, capability-gated
# field tables, the review/approval envelope rationale, the three-way status
# convention, and the credential/identity model, lives in
# commands/references/forge-contract.md — this section implements exactly
# what that document specifies, nothing more.
#
# forge-contract.md is the SINGLE ARBITER of the vocabulary below. No later
# forge-* verb may introduce a variant field-name casing (e.g. camelCase
# unsupportedFields) or a second degradation signal (e.g. a degradedReason
# field alongside status) — see that file's opening section for the full
# statement.
#
# This section introduces NO gh/glab/tea invocation, no git-remote parsing,
# and no forge-pr-view/forge-auth-status/forge-repo-info verb body. Those
# belong to later stories in this phase, which call the functions below
# rather than re-deriving the shapes they build.

# Shared jq -nc builder for the normalized PR object (forge-contract.md
# "Normalized PR Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state, --head-ref-name, --base-ref-name) are always
# accepted and null when empty. Capability-gated fields (--files, a JSON
# array; --is-draft, JSON true/false; --mergeable, a raw string — never
# forced to boolean, since GitLab's detailed_merge_status is a 16-value
# enum) are tracked by FLAG PRESENCE, not by value: omitting the flag is
# what marks a field unsupported, regardless of what value would otherwise
# have been passed. Every omitted capability-gated field comes back null
# AND its name is appended to unsupported_fields — never a bare, unmarked
# null. --raw carries the untouched forge-native object alongside the
# normalized shape (JSON object/array/literal, defaults to null).
_forge_build_pr_json() {
  local number="" url="" title="" body="" state="" head_ref="" base_ref=""
  local files_json="null" is_draft_json="null" mergeable="" raw="null"
  local files_set=false is_draft_set=false mergeable_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)         shift; number="${1:-}" ;;
      --url)            shift; url="${1:-}" ;;
      --title)          shift; title="${1:-}" ;;
      --body)           shift; body="${1:-}" ;;
      --state)          shift; state="${1:-}" ;;
      --head-ref-name)  shift; head_ref="${1:-}" ;;
      --base-ref-name)  shift; base_ref="${1:-}" ;;
      --files)          shift; files_json="${1:-null}"; files_set=true ;;
      --is-draft)       shift; is_draft_json="${1:-null}"; is_draft_set=true ;;
      --mergeable)      shift; mergeable="${1:-}"; mergeable_set=true ;;
      --raw)            shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_pr_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$files_set" = true ]     || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["files"]')
  [ "$is_draft_set" = true ]  || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["isDraft"]')
  [ "$mergeable_set" = true ] || unsupported=$(printf '%s' "$unsupported" | jq -c '. + ["mergeable"]')

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --arg headRefName "$head_ref" \
    --arg baseRefName "$base_ref" \
    --argjson files "$files_json" \
    --argjson isDraft "$is_draft_json" \
    --arg mergeable "$mergeable" \
    --argjson mergeableSet "$mergeable_set" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      headRefName: (if $headRefName == "" then null else $headRefName end),
      baseRefName: (if $baseRefName == "" then null else $baseRefName end),
      files: $files,
      isDraft: $isDraft,
      mergeable: (if $mergeableSet and ($mergeable != "") then $mergeable else null end),
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared jq -nc builder for the normalized issue object (forge-contract.md
# "Normalized Issue Field Set"). Portable-core fields (--number, --url,
# --title, --body, --state) are always accepted and null when empty. The
# one capability-gated field (--comments, a JSON int) is tracked by flag
# presence exactly like _forge_build_pr_json's capability-gated fields.
# --raw carries the untouched forge-native object (defaults to null).
_forge_build_issue_json() {
  local number="" url="" title="" body="" state="" raw="null"
  local comments_json="null" comments_set=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)   shift; number="${1:-}" ;;
      --url)      shift; url="${1:-}" ;;
      --title)    shift; title="${1:-}" ;;
      --body)     shift; body="${1:-}" ;;
      --state)    shift; state="${1:-}" ;;
      --comments) shift; comments_json="${1:-null}"; comments_set=true ;;
      --raw)      shift; raw="${1:-null}" ;;
      *)
        echo "Error: _forge_build_issue_json: unknown flag: $1" >&2
        return 1
        ;;
    esac
    shift
  done

  local unsupported='[]'
  [ "$comments_set" = true ] || unsupported='["comments"]'

  jq -nc \
    --arg number "$number" \
    --arg url "$url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg state "$state" \
    --argjson comments "$comments_json" \
    --argjson unsupported "$unsupported" \
    --argjson raw "$raw" \
    '{
      number: (if $number == "" then null else (try ($number | tonumber) catch $number) end),
      url: (if $url == "" then null else $url end),
      title: (if $title == "" then null else $title end),
      body: (if $body == "" then null else $body end),
      state: (if $state == "" then null else $state end),
      comments: $comments,
      unsupported_fields: $unsupported,
      raw: $raw
    }'
}

# Shared three-way status envelope (forge-contract.md "Three-Way Status
# Convention"), modeled directly on roadmap.py's verify_creates_one verdict shape's own
# verified/missing/error trio: found/not_found/error are three genuinely
# distinct outcomes and must never be conflated the way `gh pr view --json
# url` today exits non-zero for both "no PR exists" and "auth/network
# broken". Every later forge lookup verb constructs its result through this
# one function instead of hand-rolling the JSON assembly per verb.
#
# Usage: _forge_emit_status <status> [data-json] [message] [reason]
#   status   found | not_found | error -- anything else is a caller error
#            (unknown status, exit 1) rather than silently coerced.
#   data     JSON value (typically a normalized PR/issue object). Forced to
#            null unless status == "found", so a caller cannot accidentally
#            leak a stale value across the wrong branch of the outcome.
#   message  the human-readable degraded reason -- prose for a log or a
#            person. Forced to null unless status == "error".
#   reason   the MACHINE-readable degraded reason: a fixed, closed enum
#            (no_adapter | cli_missing | not_authenticated | cli_failed,
#            forge-contract.md "Degradation Reason Enum"), so a caller
#            branches on a stable value instead of grepping translatable
#            English out of `message`. Any other non-empty value is a caller
#            error (exit 1) -- the identical discipline `status` above
#            already gets, rather than silently passing an unknown value
#            through to a caller that would then branch on it. Forced to
#            null unless status == "error", exactly like `message`, so a
#            stale reason can never ride along on a found/not_found result.
#            It exists ALONGSIDE `message`, never as a replacement for it.
_forge_emit_status() {
  local status="$1" data_json="${2:-null}" message="${3:-}" reason="${4:-}"

  case "$status" in
    found|not_found|error) ;;
    *)
      echo "Error: _forge_emit_status: status must be found, not_found or error (got: $status)" >&2
      return 1
      ;;
  esac

  case "$reason" in
    ""|no_adapter|cli_missing|not_authenticated|cli_failed) ;;
    *)
      echo "Error: _forge_emit_status: reason must be no_adapter, cli_missing, not_authenticated or cli_failed (got: $reason)" >&2
      return 1
      ;;
  esac

  if [ "$status" != "found" ]; then
    data_json="null"
  fi
  if [ "$status" != "error" ]; then
    message=""
    reason=""
  fi

  jq -nc \
    --arg status "$status" \
    --argjson data "$data_json" \
    --arg message "$message" \
    --arg reason "$reason" \
    '{status: $status,
      data: $data,
      message: (if $message == "" then null else $message end),
      reason: (if $reason == "" then null else $reason end)}'
}

# Shared WRITE-verb status envelope (forge-contract.md "Write-Verb Status
# Convention") -- the exact sibling of _forge_emit_status above: identical
# {status, data, message} field names and identical null-forcing
# discipline, differing ONLY in which three values `status` may take.
#
# A write has no "not found" outcome (nothing was looked up), so forcing
# the read side's found/not_found/error trio onto forge-pr-create/
# forge-pr-edit/forge-issue-create would be a bad fit -- but letting each
# of those three verbs hand-roll its own shape (a bare {url, number,
# created} boolean here, a flat {url, number, status, message} there, a
# status-less {url, number} somewhere else) was worse: a caller then had to
# branch on field presence, on a per-verb vocabulary, or on the exit code
# alone to learn what a write actually did.
#
# Usage: _forge_emit_write_status <status> [data-json] [message]
#   status   created | unchanged | degraded -- anything else is a caller
#            error (exit 1) rather than silently coerced, mirroring
#            _forge_emit_status's own guard.
#              created   -- a new resource identifier was minted.
#              unchanged -- no new identifier was minted. Covers both
#                           forge-pr-create finding an already-open PR and
#                           every successful forge-pr-edit call, which only
#                           ever mutates an existing number.
#              degraded  -- the write could not complete automatically;
#                           `message` carries the reason.
#   data     JSON value (typically {url, number}). Forced to null unless
#            status is "created" or "unchanged", so a caller cannot
#            accidentally leak a stale identifier across a degraded branch.
#   message  the one and only degraded-reason field in this contract.
#            Forced to null unless status == "degraded".
#
# This envelope is an ADDITION to each verb's exit-code contract, never a
# replacement for it: forge-pr-create/forge-pr-edit still exit non-zero on
# every degraded outcome, and forge-issue-create still exits 0 on all of
# them (see the EXIT CONTRACT DIFFERS comment in the pr-write section).
_forge_emit_write_status() {
  local status="$1" data_json="${2:-null}" message="${3:-}"

  case "$status" in
    created|unchanged|degraded) ;;
    *)
      echo "Error: _forge_emit_write_status: status must be created, unchanged or degraded (got: $status)" >&2
      return 1
      ;;
  esac

  if [ "$status" != "created" ] && [ "$status" != "unchanged" ]; then
    data_json="null"
  fi
  if [ "$status" != "degraded" ]; then
    message=""
  fi

  jq -nc \
    --arg status "$status" \
    --argjson data "$data_json" \
    --arg message "$message" \
    '{status: $status, data: $data, message: (if $message == "" then null else $message end)}'
}

# Builds the {url, number} object every write verb nests under the write
# envelope's `data` key. One builder for all three verbs, so their success
# shapes are identical BY CONSTRUCTION rather than by three hand-rolled jq
# expressions that merely happen to agree today.
# Usage: _forge_build_write_data <url> [number]
#   url     empty -> null.
#   number  empty -> null, otherwise a JSON int (never a quoted string).
_forge_build_write_data() {
  local url="${1:-}" number="${2:-}"
  jq -nc \
    --arg url "$url" \
    --arg number "$number" \
    '{url: (if $url == "" then null else $url end),
      number: (if $number == "" then null else ($number | tonumber) end)}'
}

# Shared graceful-degradation gate (forge-contract.md "Degradation
# Contract") for every forge-* verb that shells out to a forge CLI
# (gh/glab/tea). `command -v` is a portable presence check that never
# invokes the binary, so it cannot itself hang, prompt, or leak an
# unguarded 127 -- guarding here is the whole point of this function.
#
# Usage: _forge_bin_check <binary> <quiet|mandatory> <forge-label>
#   Returns 0 when <binary> resolves on PATH, 1 otherwise -- in BOTH modes.
#   quiet mode:     absence produces NO stderr output at all. For a caller
#                   that already has its own fallback path and would only
#                   restate it -- matches review.md's documented row ("gh
#                   CLI not installed -> Fall back to git diff for branch
#                   comparison"), which must not gain a spurious warning it
#                   does not have today.
#   mandatory mode: absence prints exactly ONE stderr warning naming the
#                   missing binary, the forge label the caller passed (from
#                   detect-forge's output -- never a generic placeholder),
#                   and a manual next step -- matches execute.md's existing
#                   `command -v gh` gate at the per-repository PR-creation
#                   step.
_forge_bin_check() {
  local binary="$1" mode="$2" forge_label="$3"

  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$mode" = "mandatory" ]; then
    echo "Warning: $binary not found -- this $forge_label operation cannot run automatically; install $binary or complete it manually." >&2
  fi
  return 1
}

# Runs a command with its stdout, stderr and exit status captured into three
# caller-named variables, guaranteeing the stderr scratch file is removed on
# every return path. Seven gh adapters below each carried their own
# mktemp/capture/cat/rm copy of this, every one of them relying on the next
# editor remembering to keep the `rm -f` as the last line.
#
# Usage -- ALWAYS a plain statement, NEVER inside $(...):
#   _forge_capture <stdout_var> <stderr_var> <rc_var> -- <cmd> [args...] || true
#
# The trailing `|| true` is MANDATORY under this file's `set -e`: this function
# returns the wrapped command's own exit status, so a legitimate non-zero gh
# exit would otherwise abort the whole CLI. The real status is always readable
# from <rc_var>, which is what all seven callers branch on. A `$(...)` wrapper
# would fork a subshell, where a name-reference write cannot reach the caller's
# variables and the exit status is discarded -- hence "plain statement".
#
# The RETURN trap DISARMS ITSELF, and that is load-bearing rather than
# decorative: bash's RETURN trap is a shell-global, not a function-scoped one.
# Left armed it fires a second time on the CALLER's own return, by which point
# $_fc_err_file is out of scope -- a hard `unbound variable` abort under
# `set -u`. Verified empirically both ways; the self-disarming form fires
# exactly once per call, on whichever return path this function takes,
# including a future early return nobody has written yet. It is not inherited
# by nested calls (no `set -T`/functrace in this file), and the one nested
# substitution any caller passes -- `-f query="$(_forge_review_threads_query)"`
# -- is evaluated in the caller's own shell before this function is entered.
#
# Internals are _fc_-prefixed so a caller's own stdout/stderr/stderr_out/rc
# locals can never collide with the name-reference targets.
_forge_capture() {
  local -n _fc_out="$1" _fc_err="$2" _fc_rc="$3"
  shift 3
  if [ "${1:-}" = "--" ]; then shift; fi

  local _fc_err_file
  _fc_err_file=$(mktemp) || exit 1
  trap 'rm -f "$_fc_err_file"; trap - RETURN' RETURN

  _fc_rc=0
  _fc_out=$("$@" 2>"$_fc_err_file") || _fc_rc=$?
  _fc_err=$(cat "$_fc_err_file" 2>/dev/null || true)
  return "$_fc_rc"
}

# Classifies an ALREADY-FAILED gh invocation into forge-contract.md's
# Degradation Reason Enum, printing exactly one of `not_authenticated` or
# `cli_failed`. One shared helper so every adapter below asks the question
# the same way instead of each duplicating its own check.
#
# Usage: _forge_classify_gh_failure_reason <host>
#
# The answer is determined STRUCTURALLY, never by pattern-matching the
# failing command's own stderr text: this calls _forge_auth_status_github
# directly (a function call, never a `$AIMI_CLI forge-auth-status`
# subprocess -- the exact primitive the shipped forge-auth-status verb uses
# to answer this same question) and reads its `.authenticated` field. Note
# that `.authenticated` is the field that answers "is the user logged in";
# _forge_emit_status's own `status` field answers only "did the check run",
# which is a different question and the wrong one to branch on here.
#
# Why structural rather than a stderr match on gh's known auth-failure
# wording ("HTTP 401", "Bad credentials", "gh auth login"): that wording can
# be reworded on any gh release and varies by locale, so a match silently
# stops matching and misclassifies every future auth failure as cli_failed.
# forge-pr-view's not_found detection was made structural for exactly this
# reason; this follows that precedent rather than _forge_issue_view's
# unremediated stderr match.
#
# COST AND ORDERING: the one extra `gh auth status` round trip happens only
# on an already-failed request, and only after the CALLING adapter has
# already confirmed gh is on PATH through its own separate _forge_bin_check
# gate. cli_missing is therefore always ruled out before this ever runs --
# the two reasons can never collide.
#
# Anything short of a definite "authenticated: false" resolves to
# cli_failed, including a call that could not determine an active account at
# all: this classifier only ever narrows an already-known failure, so the
# catch-all is the safe direction.
_forge_classify_gh_failure_reason() {
  local host="${1:-}"
  local auth_json="" authenticated=""

  auth_json=$(_forge_auth_status_github "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""

  if [ "$authenticated" = "false" ]; then
    printf '%s' "not_authenticated"
    return 0
  fi

  printf '%s' "cli_failed"
}

# Prints the gh token this repository's REMEMBERED ACCOUNT should act as for
# ONE forge invocation, or the empty string. Always exits 0. Writes nothing,
# anywhere: no `gh auth switch`, no hosts.yml, no file on disk.
#
# Usage -- ALWAYS a bash PREFIX ASSIGNMENT on the wrapped call, NEVER `env`:
#   GH_TOKEN="$(_forge_account_override GH_TOKEN)" \
#   GH_ENTERPRISE_TOKEN="$(_forge_account_override GH_ENTERPRISE_TOKEN)" \
#     _forge_capture stdout stderr_out rc -- gh pr create --title "$title" ... || true
#
# BOTH SLOTS ARE WRITTEN LITERALLY, AT MOST ONE IS EVER NON-EMPTY. Bash cannot
# prefix-assign a dynamically named variable, so the call site names both and
# passes the name it is filling; this function decides which one gets a value
# and returns empty for the other. gh treats an EMPTY token variable as unset
# (verified, gh 2.94.0), which is why the "always use whichever account is
# active" opt-out and the no-answer case reuse the identical call-site shape
# with no separate branch anywhere.
#
# `export` IS FORBIDDEN; THE OVERRIDE IS A PREFIX ASSIGNMENT ON ONE COMMAND,
# ALWAYS. That rule is load-bearing, not stylistic. Under a process-wide
# GH_TOKEN, `gh auth status` reports the ENV-TOKEN account as
# "Active account: true" -- so _forge_auth_status_github's parser below would
# start reporting the overridden account as the machine's active one, and the
# very before/after check that proves the machine account was left alone would
# become unable to detect a violation. A prefix assignment on a FUNCTION
# invocation is set inside the function, exported into the `gh` grandchild it
# spawns, and unset again the moment the function returns, so _forge_capture
# needs no signature change and nothing survives the call.
#
# NO TOKEN EVER REACHES argv. The `env GH_TOKEN=... gh ...` shape is banned for
# exactly this reason -- env(1)'s own argv carries the value and leaks it
# through `ps`. Nothing here echoes, logs or emits the token either: it is this
# function's stdout value and nothing else. Same bar phase 1 already holds with
# _detect_forge_redact_userinfo, which strips embedded userinfo from a remote
# URL before it can round-trip through this CLI's stdout.
#
# HOST DECIDES THE VARIABLE NAME, AND GETTING IT WRONG FAILS SILENTLY:
# gh honors GH_TOKEN for github.com and *.ghe.com ONLY; a GitHub Enterprise
# Server host on a company domain needs GH_ENTERPRISE_TOKEN instead
# (`gh help environment`). Emitting GH_TOKEN at a GHES host does not error --
# it is ignored, and the write succeeds attributed to the WRONG ACCOUNT, which
# is the worst available outcome. The mapping:
#
#   github.com, *.github.com   -> GH_TOKEN             --hostname <host>
#   ghe.com, *.ghe.com         -> GH_TOKEN             --hostname <host>
#   any other non-empty host   -> GH_ENTERPRISE_TOKEN  --hostname <host>
#   empty / unresolvable host  -> GH_TOKEN             --hostname omitted entirely
#
# The empty-host row is the AIMI_FORGE_TYPE override path, where _detect_forge
# emits host: null and there is no hostname to pass; gh then uses its own
# default host. The host is derived through _forge_account_host_cached below --
# the jq-free _detect_forge_read_selection + _detect_forge_parse_host pair (two
# `git remote` reads on a memo miss, zero jq processes) -- rather than taken
# from the caller, because three of the four write paths reach identity through
# _detect_forge_type, which by its own header comment carries no host at all.
# That pair returns a lowercased
# plain string and can never produce the four-character text "null" the way a
# bare `jq -r '.host'` can -- the defect commit d1b19ca paid for, where "null"
# reached --hostname and its refusal read as a confirmed not-authenticated
# answer. Every jq read below uses `// empty` for the same reason.
#
# COST. The requested-name check happens BEFORE any gh call and before the
# store is read, so the non-matching slot costs nothing at all and one routed
# write costs exactly ONE `gh auth token` process, never two. The opt-out and
# the no-answer case cost zero gh processes.
#
# Precedence, highest first -- the same env-over-stored convention
# AIMI_FORGE_TYPE already sets for detection:
#   1. AIMI_FORGE_IDENTITY, when non-empty
#   2. the account cmd_forge_account_select recorded for this repository
#   3. nothing -- empty override, the machine's active account acts
# The store holds a LOGIN, never a token. Nothing here persists a token; it is
# minted per invocation and dies with the process.
#
# THE LOOKUP RUNS OUTSIDE ANY OVERRIDE, deliberately: `gh auth token` with a
# GH_TOKEN already in the environment returns THAT token rather than the
# keyring's, so an ambient override would make this function resolve to itself.
# Both variables are cleared for its own call.
#
# DEGRADATION IS DELIBERATE. A remembered account that was later
# `gh auth logout`'d makes `gh auth token --user <login>` exit non-zero
# ("no oauth token found for <host> account <login>"). This prints nothing,
# exits 0, and emits exactly ONE stderr warning naming the login and host --
# never the token, and never gh's own stderr verbatim, which can echo token
# prefixes. The write then proceeds as the machine's active account: the same
# warn-and-fall-back posture _forge_bin_check and _forge_emit_write_status
# already established, with the wrong-account attribution made visible rather
# than the write blocked. Because this is evaluated inside a `$( )` in a prefix
# assignment, the warning goes straight to the user's stderr and is never
# captured into _forge_capture's stderr_out, so it cannot contaminate an
# emitted JSON `message`.
#
# CLASSIFIER SEAM, decided rather than discovered later, and now CLOSED:
# _forge_classify_gh_failure_reason above calls _forge_auth_status_github, so
# left outside the override that call would re-check the MACHINE account's auth
# after a write failed as a DIFFERENT account. It SHOULD run under the same
# override, because with the override applied `gh auth status` reports the
# env-token account, which is exactly the account whose failure is being
# classified. Exactly ONE classifier call sits inside a write path: the one in
# _forge_resolve_review_thread (the
# `reason=$(_forge_classify_gh_failure_reason "$host")` line after its
# could-not-resolve-to-a-node match). The other two -- in _forge_issue_view and
# _forge_pr_review_threads_github -- are pure reads outside this phase's write
# set, and _forge_pr_create/_forge_pr_edit/_forge_issue_create never call it.
# The routing pass carried that one prefix assignment to that one CALL SITE;
# the classifier function itself was never edited, which is what kept the two
# stories off the same function. See the ROUTING RULE block below.
#
# Residual, accepted and named rather than defended against: `bash -x` would
# print the token as part of the prefix-assignment expansion. This file never
# enables xtrace (`set -euo pipefail` only), so that is a debugging-time hazard,
# not a shipped leak.
#
# Per-process memo behind _forge_account_host_cached, keyed on the working
# directory each answer was derived in -- the same shape, and keyed for the same
# multi-repo reason, as _DETECT_FORGE_TYPE_MEMO above.
declare -gA _FORGE_ACCOUNT_HOST_MEMO

# The forge host an override is keyed under: a lowercased plain string, or empty
# when there is none. Two `git remote` reads on a miss, zero on a hit.
#
# OUT-PARAMETER, NOT STDOUT, for precisely _detect_forge_type's reason: a memo
# populated inside a `$(...)` subshell dies with that subshell, and
# _forge_account_override below is ALWAYS called inside one (it is a printer,
# used in a prefix assignment). So the memo is warmed by
# _forge_account_override_slots -- a plain statement in the caller's own shell
# -- and the two `$(...)` lookups it then makes inherit the populated array and
# read it as a hit. Without that warming, one routed write would derive the host
# twice, once per slot, to answer the same question.
#
# Internals are _fahc_-prefixed so _detect_forge_read_selection's name-reference
# targets can never collide with a caller's own locals.
# Usage: _forge_account_host_cached <host_var>
_forge_account_host_cached() {
  local -n _fahc_out="$1"
  _fahc_out=""

  # AIMI_FORGE_TYPE short-circuits before the memo as well as before any git
  # command, mirroring _detect_forge's own override arm, which emits host: null
  # on that path -- there is no host to key anything under.
  if [ -n "${AIMI_FORGE_TYPE:-}" ]; then
    return 0
  fi

  local _fahc_key="$PWD"
  if [ -n "${_FORGE_ACCOUNT_HOST_MEMO[$_fahc_key]+set}" ]; then
    _fahc_out="${_FORGE_ACCOUNT_HOST_MEMO[$_fahc_key]}"
    return 0
  fi

  local _fahc_name _fahc_source _fahc_url _fahc_host=""
  _detect_forge_read_selection _fahc_name _fahc_source _fahc_url
  if [ "$_fahc_source" = "remote" ] && [ -n "$_fahc_url" ]; then
    _fahc_host=$(_detect_forge_parse_host "$_fahc_url")
  fi

  _FORGE_ACCOUNT_HOST_MEMO["$_fahc_key"]="$_fahc_host"
  _fahc_out="$_fahc_host"
}

# Internals are _fao_-prefixed so _detect_forge_read_selection's name-reference
# targets can never collide with a caller's own locals.
_forge_account_override() {
  local _fao_want="${1:-}"
  [ -n "$_fao_want" ] || return 0

  # Host first -- it decides both the variable name and the store key.
  local _fao_host=""
  _forge_account_host_cached _fao_host

  local _fao_var="GH_TOKEN"
  case "$_fao_host" in
    ""|github.com|*.github.com|ghe.com|*.ghe.com) _fao_var="GH_TOKEN" ;;
    *) _fao_var="GH_ENTERPRISE_TOKEN" ;;
  esac

  # The slot this host does not use costs nothing: no store read, no gh call.
  [ "$_fao_want" = "$_fao_var" ] || return 0

  local _fao_login=""
  if [ -n "${AIMI_FORGE_IDENTITY:-}" ]; then
    _fao_login="$AIMI_FORGE_IDENTITY"
  elif [ -n "$_fao_host" ]; then
    # An answer is keyed by host, so an unresolvable host has nothing to look
    # up. _forge_account_store_path is documented to be allowed to decline.
    local _fao_store="" _fao_entry=""
    _fao_store=$(_forge_account_store_path) || _fao_store=""
    if [ -n "$_fao_store" ]; then
      # _forge_account_stored_entry already validates the mode discriminator
      # and rejects an empty account string, so `null` covers absent, corrupt
      # and not-an-answer alike. mode "active" is the deliberate opt-out and
      # yields empty here -- a real answer, not a missing one.
      _fao_entry=$(_forge_account_stored_entry "$_fao_store" "$_fao_host")
      if [ "$_fao_entry" != "null" ]; then
        _fao_login=$(printf '%s' "$_fao_entry" | jq -r 'if .mode == "account" then (.account // empty) else empty end')
      fi
    fi
  fi

  [ -n "$_fao_login" ] || return 0

  # gh's absence is not this function's diagnosis to make -- the calling write
  # path already gates on _forge_bin_check and says so once. Warning here too
  # would add a second, wrong explanation ("no token for <login>") for a
  # machine that simply has no gh.
  _forge_bin_check gh quiet github || return 0

  local _fao_token="" _fao_rc=0
  if [ -n "$_fao_host" ]; then
    _fao_token=$(GH_TOKEN= GH_ENTERPRISE_TOKEN= gh auth token --user "$_fao_login" --hostname "$_fao_host" 2>/dev/null) || _fao_rc=$?
  else
    _fao_token=$(GH_TOKEN= GH_ENTERPRISE_TOKEN= gh auth token --user "$_fao_login" 2>/dev/null) || _fao_rc=$?
  fi

  if [ "$_fao_rc" -ne 0 ]; then
    echo "Warning: no gh token for account \"$_fao_login\" on host \"${_fao_host:-default}\" -- it may have been logged out; this operation will proceed as the machine active account." >&2
    return 0
  fi

  printf '%s' "$_fao_token"
}

# Fills the caller's TWO prefix-assignment locals for ONE forge invocation.
# Usage -- ALWAYS a plain statement, never inside $(...):
#   local gh_token_override="" ghe_token_override=""
#   _forge_account_override_slots gh_token_override ghe_token_override
#
# This exists so a write function resolves the account ONCE and then names the
# same two locals at every routed command, instead of paying for the derivation
# at each of the three or four gh-facing steps one write makes. It adds NO
# resolution logic of its own: _forge_account_override above remains the single
# place that decides which slot gets a value and what that value is.
#
# AN EMPTY OVERRIDE MUST NOT BLANK AN INHERITED TOKEN. Empty means "nothing was
# recorded for this repository" or the deliberate "always use whichever account
# is active" opt-out -- and in BOTH cases the acting account is whatever gh
# would have used on its own, which includes a GH_TOKEN the caller exported
# before invoking this CLI. Phase 1's contract (see cmd_forge_issue_create's
# header) promises that inherited value reaches the child gh process untouched,
# and a bare `GH_TOKEN="$empty"` prefix would silently revoke it. Parameter
# expansion rather than an `if`, so the opt-out is not a second code path: a
# recorded account still wins over the ambient value, since a non-empty override
# never reaches the default arm.
#
# Internals are _faos_-prefixed so the caller's own two locals can never collide
# with the name-reference targets.
_forge_account_override_slots() {
  local -n _faos_gh="$1" _faos_ghe="$2"

  # Warm the host memo HERE, in the caller's own shell. The two lookups below
  # are command substitutions, so a memo either of them populated would die
  # with its subshell -- see _forge_account_host_cached's header.
  local _faos_host=""
  _forge_account_host_cached _faos_host

  _faos_gh=$(_forge_account_override GH_TOKEN)
  _faos_ghe=$(_forge_account_override GH_ENTERPRISE_TOKEN)

  _faos_gh="${_faos_gh:-${GH_TOKEN:-}}"
  _faos_ghe="${_faos_ghe:-${GH_ENTERPRISE_TOKEN:-}}"
}

# ----------------------------------------------------------------------------
# ROUTING RULE FOR THE FOUR FORGE WRITE PATHS (US-006)
# ----------------------------------------------------------------------------
# THE OVERRIDE IS A PREFIX ASSIGNMENT ON EXACTLY ONE COMMAND, ALWAYS. It is
# never `export`ed, never assigned at file scope, and never set by a wrapper
# around a whole function body. That rule is load-bearing rather than
# stylistic: with GH_TOKEN set process-wide, `gh auth status` reports the
# env-token account as "Active account: true", which is precisely the marker
# _forge_auth_status_github parses -- an exported override would make
# forge-auth-status report the OVERRIDDEN account as the machine's active one,
# and would leave the very before/after check that proves the machine account
# was left alone structurally unable to detect a violation.
#
# NINE SITES, AND NO OTHERS (US-006's forge-pr-merge added the last two).
# Each write function resolves BOTH slots ONCE into two locals immediately
# after its own _forge_bin_check gate -- at most one is ever non-empty, and
# only the matching one costs a `gh auth token` process -- then names both
# on every routed command:
#
#   _forge_pr_create              gh pr create      the write
#                                 cmd_forge_pr_view idempotency check
#                                 cmd_forge_pr_view post-create re-read
#   _forge_pr_edit                gh pr edit        the write
#                                 cmd_forge_pr_view post-edit re-read
#   _forge_pr_merge               gh pr merge       the write
#                                 cmd_forge_pr_view preflight read
#   _forge_issue_create           gh issue create   the write
#   _forge_resolve_review_thread  gh api graphql    the resolveReviewThread mutation
#
# Resolved ONCE per invocation, not once per site: a single forge-pr-create run
# reaches gh three or four times and must not re-derive the host and re-mint the
# token each time. That is what _forge_account_override_slots is for -- it fills
# the caller's two locals from a plain statement in the caller's own shell, so
# the host memo it warms survives into the `$(...)` lookups that follow. A memo
# populated INSIDE one of those lookups would die with its subshell, exactly as
# _detect_forge_type's own header spells out.
#
# WHY THE IN-OPERATION READS ARE ROUTED TOO -- correctness, not tidiness: on a
# PRIVATE repository the account that creates a PR can see it while a different
# reader account cannot, so a post-create re-read performed as the machine
# account would fail against a PR that was just successfully created. One
# logical operation stays on one identity. This does NOT make forge-pr-view an
# override-applying verb: invoked directly as its own verb it stays a plain
# machine-account read, and only the reads made INSIDE a write inherit anything.
#
# NO BRANCH FOR THE OPT-OUT. When the remembered answer is "always use whichever
# account is active" -- or nothing was ever recorded -- both locals are empty and
# every site keeps the identical shape, because gh treats an empty token
# variable as unset. An `if` here would be a second code path for the commonest
# case of all.
#
# NOT INVOCATIONS, NOT ROUTED: the two `echo` lines in
# _forge_pr_write_print_manual PRINT a `gh pr create` / `gh pr edit` command for
# a human to run. They shell out to nothing.
#
# ONE CLASSIFIER CALL IS ROUTED, the one inside _forge_resolve_review_thread.
# See the CLASSIFIER SEAM paragraph on _forge_account_override above for why;
# the prefix assignment lives at that call site and
# _forge_classify_gh_failure_reason itself is unmodified.
# ----------------------------------------------------------------------------

# ============================================================================
# forge-auth-status / forge-repo-info (US-003)
# ============================================================================
# Both verbs are read-only forge lookups built directly on detect-forge
# (US-001, called here as a function, never as a `$AIMI_CLI detect-forge`
# subprocess) and the shared PR/issue contract, three-way status envelope,
# and degradation helper above (US-002, commands/references/forge-
# contract.md). Every field name and the found/not_found/error vocabulary
# below comes verbatim from that file -- forge-contract.md is the single
# arbiter, and this section introduces no camelCase unsupportedFields, no
# degradation field the contract does not itself define (the `reason` enum
# below is the contract's own, not a per-verb invention), and no gh
# invocation outside the two private *_github helpers below.
#
# forge-auth-status reports whether the active gh session is authenticated
# AND which account it is acting as -- naming the acting account now is what
# lets phase 2's per-repository account selection extend this verb instead
# of retrofitting it. Phase 1 only compares identity (AIMI_FORGE_IDENTITY
# against whichever account gh already reports active); it does not
# implement switching (no `gh auth switch`, no GH_TOKEN override -- that is
# phase 2's job). Identity is read from an environment variable, NEVER a
# CLI flag -- a value that may later carry a credential must never leak
# through ps or shell history (forge-contract.md "Credential/Identity
# Model").
#
# "Not authenticated" and "could not check at all" are different facts and
# must stay distinguishable, the same discipline roadmap.py's verify_creates_one already
# applies by distinguishing a "missing" identity from a git tool failure
# before ever building a verdict:
#   - gh present, ran, reports no active session for this host -> a
#     CONFIRMED negative. status="found", data.authenticated=false,
#     data.account=null, message=null -- forge-contract.md's "found" covers
#     the lookup succeeding and returning real data, and an authenticated-
#     account check that definitively answers "no" is still a successful
#     lookup, not a broken one.
#   - the forge's own CLI absent from PATH, or the resolved forge has no
#     adapter yet (gitea/unknown -- gitlab gained one in phase 3) -> the
#     check itself could not run. status="error", data=null, message names
#     why, naming the binary THAT forge needs (gh or glab, never a generic
#     placeholder). Callers branch on status/message first, never on
#     data.authenticated alone.
# "not_found" is not used by forge-auth-status: there is no "no such auth
# status" outcome the way there is "no such PR" -- the check either runs to
# a definitive true/false answer (found) or cannot run at all (error).

# Runs `gh auth status` against one host, tolerating a non-zero exit under
# `set -e` (gh's own convention: a non-zero exit here IS the confirmed
# "not authenticated" answer, not a tool failure -- gh auth status has no
# third outcome the way `gh pr view` conflates no-PR with broken auth).
# Combines stdout+stderr since gh's own account listing goes to a different
# stream across versions -- this parser only cares about the text, not
# which stream carried it.
# Prints {authenticated, account, accounts} -- account is the login of
# whichever account gh marks "Active account: true" beneath, or the sole
# account found when gh's output carries no explicit marker line at all.
# `accounts` is EVERY login the same output listed, in gh's own print order,
# de-duplicated, [] when none. It comes out of the SAME single parse pass as
# `account`, deliberately: a second `gh auth status` call or a second parser
# could disagree with this one (gh's output is not guaranteed stable between
# two invocations -- an account can be added, removed or switched between
# them), and a list that disagrees with the active account it is supposed to
# contain is worse than no list at all.
_forge_auth_status_github() {
  local host="$1"
  local out="" rc=0
  if [ -n "$host" ]; then
    out=$(gh auth status --hostname "$host" 2>&1) || rc=$?
  else
    out=$(gh auth status 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    jq -nc '{authenticated: false, account: null, accounts: []}'
    return 0
  fi

  local active="" last="" line seen known
  local accounts=()
  while IFS= read -r line; do
    # Requires whitespace immediately after "account", which is exactly what
    # keeps the marker lines out: "Active account: true" has a colon there,
    # so the marker can never be mistaken for a login.
    if [[ "$line" =~ account[[:space:]]+([^[:space:]]+) ]]; then
      last="${BASH_REMATCH[1]}"
      seen=""
      for known in ${accounts[@]+"${accounts[@]}"}; do
        if [ "$known" = "$last" ]; then
          seen="1"
          break
        fi
      done
      [ -n "$seen" ] || accounts+=("$last")
    fi
    if [[ "$line" == *"Active account: true"* ]]; then
      active="$last"
    fi
  done <<< "$out"
  [ -n "$active" ] || active="$last"

  jq -nc --arg account "$active" --args \
    '{authenticated: true,
      account: (if $account == "" then null else $account end),
      accounts: $ARGS.positional}' -- ${accounts[@]+"${accounts[@]}"}
}

# The GitLab arm of the same question _forge_auth_status_github answers, and
# emits the IDENTICAL {authenticated, account, accounts} object so
# _forge_auth_status's own envelope builder below is shared rather than
# forked per adapter.
#
# Runs `glab auth status [--hostname <host>]`, combining stdout+stderr for the
# same reason the github helper does -- glab prints its status block through
# its own LogErrorf (stderr), and this parser only cares about the text.
# A NON-ZERO EXIT IS THE CONFIRMED "not authenticated" ANSWER, not a tool
# failure: glab returns an error when no instance is configured at all, and a
# different one when the requested --hostname was never authenticated
# (internal/commands/auth/status/status.go). That is the same convention
# `gh auth status` follows, which is why both helpers can share one shape.
#
# WHY THE PARSE DIFFERS FROM THE GITHUB ONE. glab has no "Active account:
# true" marker line, because it has no multi-account-per-host model to mark:
# its status block prints one `Logged in to <host> as <username> (<source>)`
# line per authenticated INSTANCE. So the login is read out of that line's
# `as <username>` position, and the first one found is the acting account --
# never a marker line, which does not exist here. `--hostname` is always
# passed when a host is known, so at most one instance block is printed;
# `-a`/`--all` is deliberately never passed.
#
# VERIFICATION CEILING (phase-wide): glab is not installed on the machine
# this was written on. The wording above is read off glab's own docs and
# source, not off an observed binary -- the same declared ceiling
# _forge_map_pr_field_gitlab's header states.
_forge_auth_status_gitlab() {
  local host="$1"
  local out="" rc=0
  if [ -n "$host" ]; then
    out=$(glab auth status --hostname "$host" 2>&1) || rc=$?
  else
    out=$(glab auth status 2>&1) || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    jq -nc '{authenticated: false, account: null, accounts: []}'
    return 0
  fi

  local login="" line seen known
  local accounts=()
  while IFS= read -r line; do
    # Anchored on the literal " as " that separates host from login, so a
    # host whose name happens to contain the word "as" cannot be mistaken
    # for the login. The captured run stops at the first whitespace, which
    # is what keeps the trailing "(<source>)" out.
    if [[ "$line" =~ Logged[[:space:]]+in[[:space:]]+to[[:space:]]+[^[:space:]]+[[:space:]]+as[[:space:]]+([^[:space:]]+) ]]; then
      login="${BASH_REMATCH[1]}"
      seen=""
      for known in ${accounts[@]+"${accounts[@]}"}; do
        if [ "$known" = "$login" ]; then
          seen="1"
          break
        fi
      done
      [ -n "$seen" ] || accounts+=("$login")
    fi
  done <<< "$out"

  jq -nc --arg account "${accounts[0]:-}" --args \
    '{authenticated: true,
      account: (if $account == "" then null else $account end),
      accounts: $ARGS.positional}' -- ${accounts[@]+"${accounts[@]}"}
}

# gitea adapter for forge-auth-status. Same {authenticated, account, accounts}
# contract as its github and gitlab siblings, deliberately kept adjacent so
# the three stay diffable -- and ONE deliberate divergence from the gitlab
# arm, spelled out below because copying that arm by habit is what would
# break this verb.
#
# `tea login list -o json` is an OFFLINE CONFIG READ (cmd/login/list.go,
# modules/print/login.go:34-54): it prints the locally stored login entries
# as an array of all-STRING rows keyed name, url, ssh_host, user, default.
# It never dials the instance. That makes `authenticated: true` here a
# WEAKER claim than gh's validated answer: it proves a login entry for this
# host exists, NOT that its token still works. Recorded so a caller reading
# `authenticated` on a Gitea remote calibrates it correctly rather than
# assuming parity with GitHub's.
#
# WHY NOT `tea whoami`: it makes a network round trip
# (client.Users.GetMyUserInfo, cmd/whoami.go:22-31) and then DISCARDS its own
# error (`user, _, _ :=`) before printing. A probe that throws away the very
# failure it is being asked about cannot answer this question, so no code
# path in this adapter invokes it.
#
# THE ONE DELIBERATE DIVERGENCE FROM _forge_auth_status_gitlab: on a non-zero
# exit, or on stdout jq cannot parse as an array, this returns NON-ZERO
# instead of a clean `{authenticated: false}`. glab's non-zero exit IS its
# confirmed "not authenticated" answer, so folding it into a negative there
# is correct. `tea` exits 1 UNIFORMLY for every error (main.go:18-30 -- there
# is no distinct exit code for anything), so the same reading would
# manufacture a false clean negative out of a broken PATH, a corrupt config
# or a jq-unparseable response. A false negative here is exactly what lets a
# broken session walk into opening a duplicate pull request, which is the
# defect this whole verb exists to prevent. Only an EMPTY match set on a
# cleanly parsed list is a definitive `authenticated: false`.
#
# Entry selection is HOST-FILTERED, never first-wins: `tea login list`
# returns every configured instance, so accepting entry zero would report a
# codeberg.org session as proof of a gitea.com login. The `default` entry
# among the matches wins, else the first match. Comparison is on the URL's
# HOST component (scheme, userinfo, path and port stripped, case-folded), so
# a stored `https://gitea.com/` matches a detected `gitea.com`.
#
# NO CREDENTIAL IS BOUND ANYWHERE IN THIS FUNCTION, and that is a security
# property rather than an omission: `tea` honours GH_TOKEN whenever
# GITEA_INSTANCE_URL is also set (modules/context/context_login.go:15-51), so
# copying the GitHub write path's prefix-assignment habit would hand a GitHub
# token to a Gitea instance. Identity selection on tea is `--login <name>`,
# which names a stored entry and carries no secret; this read verb does not
# need it and does not pass it.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. What the tests prove is WHICH ARGV this function
# emits and HOW it parses a fixture -- never what real `tea` does with them.
# Where that under-verifies is the key NAMES themselves: the stub emits
# whatever the author believed, so a wrong key would pass green on both
# sides. Same declared ceiling _forge_map_pr_field_gitea's header states.
#
# Usage: _forge_auth_status_gitea <host>
#   rc 0 -> {authenticated, account, accounts} on stdout
#   rc 1 -> the check COULD NOT RUN; the caller must report error, never a
#           negative
_forge_auth_status_gitea() {
  local host="${1:-}"
  local out="" rc=0

  # No `--login`, no `-r/--repo`: the login list is instance-wide and this
  # call is the thing that decides WHICH login is active, so scoping it to
  # one would beg the question.
  out=$(tea login list -o json 2>/dev/null) || rc=$?

  if [ "$rc" -ne 0 ]; then
    return 1
  fi

  # A cleanly parsed ARRAY is the precondition for treating an empty match
  # set as a definitive negative. Anything else -- empty stdout, a jq parse
  # error, an object where an array was promised -- proves nothing, so it
  # takes the same could-not-run exit as a non-zero rc above.
  local shape=""
  shape=$(printf '%s' "$out" | jq -r 'type' 2>/dev/null) || shape=""
  if [ "$shape" != "array" ]; then
    return 1
  fi

  jq -nc --arg host "$host" --argjson logins "$out" '
    def hostof:
      ((. // "") | tostring)
      | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
      | sub("^[^/@]*@"; "")
      | sub("/.*$"; "")
      | sub(":[0-9]+$"; "")
      | ascii_downcase;
    [ $logins[]
      | select(type == "object")
      | { user: ((.user // "") | tostring),
          host: (.url | hostof),
          isdefault: (((.default // "") | tostring) | ascii_downcase) } ] as $rows
    | (if $host == "" then $rows
       else [ $rows[] | select(.host == ($host | ascii_downcase)) ] end) as $matched
    | ([ $matched[] | select(.isdefault == "true") ] + $matched) as $ordered
    | { authenticated: (($matched | length) > 0),
        account: (((($ordered[0] // {}).user) // "") | if . == "" then null else . end),
        accounts: (reduce ($matched[] | .user | select(. != "")) as $u
                     ([]; if (index($u) != null) then . else . + [$u] end)) }'
}

# Resolves forge/host via detect-forge's own helper (a direct function call,
# never a `$AIMI_CLI detect-forge` subprocess), dispatches to the adapter the
# detected forge needs -- gh for github, glab for gitlab, tea for gitea --
# when that binary is present (checked via the shared _forge_bin_check above
# in its quiet mode: a missing binary here has no caller-mandated stderr
# banner; the caller decides whether a degraded result is fatal), and
# otherwise reports status=error with a message naming why.
# AIMI_FORGE_IDENTITY, when set, is compared only against the already-active
# account -- never used to invoke `gh auth switch` or set GH_TOKEN.
#
# THIS VERB HAS ONLY TWO OUTCOMES, found and error -- the documented
# exception to forge-contract.md's three-way convention. A CONFIRMED "no,
# you are not logged in" is a SUCCESSFUL lookup and reports found with
# data.authenticated=false; error means the check could not run at all. The
# distinction is load-bearing rather than pedantic: a broken check that read
# as a clean negative is what would let a bad session walk into creating a
# duplicate pull request.
_forge_auth_status() {
  local forge_info forge host
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # `// empty` is load-bearing, not decoration: .host is JSON null whenever
  # AIMI_FORGE_TYPE short-circuits detection, and a bare `jq -r '.host'`
  # renders that null as the 4-character TEXT "null". That string is
  # non-empty, so it survives every downstream emptiness check and reaches
  # `gh auth status --hostname null` -- a host gh has no session for, whose
  # refusal then reads as a confirmed authenticated:false. This is the same
  # guard every other nullable field in this file already reads through.
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  local status="error" message="" data_json="null" reason=""

  # ONE binary name, chosen from the detected forge, then ONE shared body.
  # The adapters differ only in which CLI is asked and how its status text is
  # parsed -- both of which are settled before this point -- so the envelope
  # below is built exactly once rather than copied per forge. Only `unknown`
  # leaves this empty and falls through to the no_adapter branch; gitea was
  # routed to `tea` in phase 4 and no longer reaches it.
  local adapter_bin=""
  case "$forge" in
    github) adapter_bin="gh" ;;
    gitlab) adapter_bin="glab" ;;
    gitea)  adapter_bin="tea" ;;
  esac

  if [ -n "$adapter_bin" ]; then
    if _forge_bin_check "$adapter_bin" quiet "$forge"; then
      local cli_out="" cli_rc=0 authenticated_json account identity_requested identity_honored_json
      # ONE adapter selection, THREE arms, still ONE shared envelope builder
      # below -- the jq call is not copied per forge. Only the gitea arm can
      # report "the check could not run at all": `tea` exits 1 UNIFORMLY for
      # every error, so its adapter refuses to turn a failure into a clean
      # negative and signals that refusal as a non-zero return instead. gh's
      # and glab's non-zero exits ARE their own confirmed negatives, so
      # neither can ever reach cli_rc != 0.
      case "$forge" in
        gitlab) cli_out=$(_forge_auth_status_gitlab "$host") ;;
        gitea)  cli_out=$(_forge_auth_status_gitea "$host") || cli_rc=$? ;;
        *)      cli_out=$(_forge_auth_status_github "$host") ;;
      esac

      if [ "$cli_rc" -ne 0 ]; then
        # The adapter could not answer. That is an ERROR, never a negative:
        # emitting authenticated=false here would manufacture a clean
        # negative out of a tool failure, and it is precisely such a false
        # negative that lets a broken session open a duplicate pull request.
        # `data_json` stays null, so `authenticated` cannot be read at all.
        message="$adapter_bin could not report authentication status -- the check did not run"
        reason="cli_failed"
      else
        authenticated_json=$(printf '%s' "$cli_out" | jq -c '.authenticated')
        account=$(printf '%s' "$cli_out" | jq -r '.account // empty')

        identity_requested="${AIMI_FORGE_IDENTITY:-}"
        identity_honored_json="null"
        if [ -n "$identity_requested" ]; then
          if [ "$identity_requested" = "$account" ]; then
            identity_honored_json="true"
          else
            identity_honored_json="false"
          fi
        fi

        status="found"
        # This builder names every field it emits, one by one -- it never
        # splats $cli_out through. That containment is load-bearing, not
        # incidental: _forge_auth_status_github (and its gitlab sibling) also
        # returns an `accounts` array (the whole login list, for the
        # account-divergence section below), and forge-contract.md fixes this
        # envelope's fields. A `+ $cli_out`-style merge here would leak a field
        # the contract does not define into every forge-auth-status caller.
        #
        # `forge` is $forge verbatim, so a GitLab repository reports
        # "gitlab" here -- open-pr.md Step 1a prints `.data.forge` rather than
        # a hardcoded "GitHub", and that is what makes it render correctly.
        data_json=$(jq -nc \
          --arg forge "$forge" \
          --arg host "$host" \
          --argjson authenticated "$authenticated_json" \
          --arg account "$account" \
          --arg identityRequested "$identity_requested" \
          --argjson identityHonored "$identity_honored_json" \
          '{forge: $forge,
            host: (if $host == "" then null else $host end),
            authenticated: $authenticated,
            account: (if $account == "" then null else $account end),
            identityRequested: (if $identityRequested == "" then null else $identityRequested end),
            identityHonored: $identityHonored}')
      fi
    else
      # Names the binary the DETECTED forge actually needs -- `glab` on a
      # GitLab remote, `tea` on a Gitea one, never `gh`. Telling a GitLab
      # user to install gh is the exact "message names the wrong CLI" defect
      # the phase contract's fourth success criterion exists to prevent.
      message="$adapter_bin not found on PATH -- cannot check authentication status"
      reason="cli_missing"
    fi
  else
    message="no forge adapter for ${forge} -- cannot check authentication status"
    reason="no_adapter"
  fi

  # Note which branch does NOT set a reason: the found branch above, which
  # covers the CONFIRMED negative (data.authenticated=false). A definitive
  # "no, you are not logged in" is a successful lookup, so `reason` stays
  # null there despite that outcome's name resembling not_authenticated --
  # `reason` only ever describes a check that could not run at all.
  _forge_emit_status "$status" "$data_json" "$message" "$reason"
}

# Detects whether the session is authenticated with the active forge and
# which account it is acting as. See the section header above for the full
# found/error contract and the AIMI_FORGE_IDENTITY comparison rules. No
# --identity (or similarly named) flag exists anywhere in this parsing loop
# -- identity selection is env-var-only, by design (see section header).
cmd_forge_auth_status() {
  check_jq

  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-auth-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _forge_auth_status
}

# ============================================================================
# Forge account selection -- divergence detection
# ============================================================================
# Answers exactly ONE question: does this repository's git identity disagree
# with the forge account gh is currently acting as, and is there another
# account available to pick instead? Nothing here asks the human, applies an
# account, or remembers an answer -- those are separate concerns owned
# elsewhere. Concretely this section:
#   - reads `git config user.email` / `user.name` and `gh auth status`, and
#     writes NOTHING. No file under ~/.config/aimi/ or .aimi/ is read or
#     created, so this code has no ordering dependency on the account store.
#   - never runs `gh auth switch`, never sets or exports GH_TOKEN, and never
#     calls `gh auth token`. Applying an account is a different job.
#   - makes NO network call. `gh api user --jq .login` would resolve the
#     active login authoritatively but costs a round trip;
#     _forge_auth_status_github already parses it offline, which is why this
#     section extends that parser rather than reaching for the API.
#
# The verdict is a PRIVATE json object consumed in-process by callers in this
# file -- deliberately NOT a fifth forge result envelope. forge-contract.md
# fixes the envelope count at four and its `reason` at a closed four-value
# enum, so:
#   - `basis` is a field on this private verdict, NEVER the `reason` argument
#     of _forge_emit_status. It reuses the contract's own spellings
#     no_adapter / cli_missing / not_authenticated where it means exactly
#     what the contract means by them, and adds diverged /
#     identity_matches_active / single_account / no_git_identity for outcomes
#     that enum does not model. Passing any of those four into
#     _forge_emit_status would be rejected by that function's own case guard,
#     which is the backstop for this rule.
#   - forge-auth-status's emitted envelope is unchanged by this section.
#
# THE HARD PART is that the comparison crosses two namespaces with no general
# mapping: a git identity is an EMAIL, a forge account is a LOGIN. Only
# GitHub's noreply form encodes the login authoritatively; everything else is
# a heuristic, which is why each derived candidate carries its own
# confidence. The heuristics are deliberately biased toward catching the
# AGREEING cases, because the two failure directions are not symmetric: a
# false "they agree" is silent and unrecoverable by the user, while a false
# "they diverge" costs one question that is answered once.

# Prints {email, name} for the identity git would actually stamp on a commit
# in the current working directory -- repository config where set, global
# otherwise, which is why neither read is qualified with --local.
#
# The `|| ` assignment on each read is REQUIRED, not defensive noise: an
# unset key makes `git config --get` exit 1, and a bare `x=$(git config ...)`
# under this file's `set -euo pipefail` would abort the whole CLI on a
# repository that simply has no user.name configured.
_forge_git_identity() {
  local email="" name=""
  email=$(git config --get user.email 2>/dev/null) || email=""
  name=$(git config --get user.name 2>/dev/null) || name=""

  jq -nc --arg email "$email" --arg name "$name" \
    '{email: (if $email == "" then null else $email end),
      name: (if $name == "" then null else $name end)}'
}

# Derives the GitHub logins an email plus a name could plausibly stand for,
# as [{login, confidence}] in decreasing authority, [] when nothing
# login-shaped can be derived at all.
#
# Usage: _forge_identity_logins <email> <name>
#
#   confidence=noreply   The address is GitHub's own noreply form,
#                        [<numeric-id>+]<login>@users.noreply.github.com,
#                        which ENCODES the login exactly. Authoritative, and
#                        emitted alone -- no heuristic can improve on it.
#   confidence=heuristic A guess: the email local-part (with a leading
#                        <digits>+ stripped, the shape GitHub's own noreply
#                        addresses use), and user.name when it is
#                        login-shaped. The shape test ^[A-Za-z0-9][A-Za-z0-9-]*$
#                        is what rejects the overwhelmingly common
#                        "First Last" value of user.name.
#
# The noreply DOMAIN is compared case-insensitively (mail domains are), but
# only a lowercased COPY of the domain is used for that test so the login the
# local-part carries keeps the casing its owner typed. Callers compare
# case-insensitively anyway, since GitHub logins are.
_forge_identity_logins() {
  local email="$1" name="$2"
  local entries=() local_part domain login

  local_part="${email%@*}"
  domain=$(printf '%s' "${email##*@}" | tr '[:upper:]' '[:lower:]')

  if [ "$domain" = "users.noreply.github.com" ] &&
     [[ "$local_part" =~ ^([0-9]+\+)?([A-Za-z0-9][A-Za-z0-9-]*)$ ]]; then
    login="${BASH_REMATCH[2]}"
    jq -nc --arg login "$login" '[{login: $login, confidence: "noreply"}]'
    return 0
  fi

  local candidate
  candidate="${email%%@*}"
  if [[ "$candidate" =~ ^[0-9]+\+(.*)$ ]]; then
    candidate="${BASH_REMATCH[1]}"
  fi
  if [[ "$candidate" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    entries+=("$(jq -nc --arg login "$candidate" '{login: $login, confidence: "heuristic"}')")
  fi

  if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] &&
     [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')" ]; then
    entries+=("$(jq -nc --arg login "$name" '{login: $login, confidence: "heuristic"}')")
  fi

  if [ ${#entries[@]} -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${entries[@]}" | jq -sc '.'
}

# Prints exactly one verdict object:
#   {decision, basis, forge, host, activeAccount, accounts, identity, match}
#     decision       "ask" | "skip" -- whether the caller should raise the
#                    account question at all. Necessary, not sufficient: a
#                    caller that has already recorded an answer for this
#                    repository combines that with this verdict.
#     basis          why (see the section header -- NOT the contract's reason)
#     forge          the resolved forge, from _detect_forge
#     host           the resolved host, or null
#     activeAccount  the login gh is currently acting as, or null
#     accounts       every login gh reports, in gh's own order, [] when none
#     identity       {email, name} this repository's git identity
#     match          "noreply" | "heuristic" | "none" -- the confidence of
#                    the derived login that MATCHED activeAccount, "none"
#                    when none did or the comparison never ran
#
# The decision table below is evaluated in a fixed order, each rung mutually
# exclusive with the ones above it. Two orderings are deliberate:
#   - identity_matches_active is checked BEFORE single_account, so a
#     one-account repository whose identity genuinely agrees reports the
#     informative basis rather than the incidental one.
#   - single_account SKIPS rather than asks. With one account logged in there
#     is no alternative to offer: account selection resolves logins already
#     in gh's keyring, so a one-account machine has no remedy even when the
#     identity plainly disagrees. Recording the basis is what lets a caller
#     say why it stayed quiet instead of appearing to have no opinion.
_forge_account_divergence() {
  local forge_info forge host
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # `// empty` is load-bearing here for exactly the reason spelled out at
  # _forge_auth_status's own host read above (aimi-cli.sh:2757-2763): .host
  # is JSON null whenever AIMI_FORGE_TYPE short-circuits detection, and a
  # bare `jq -r '.host'` renders that null as the 4-character TEXT "null" --
  # non-empty, so it survives every downstream emptiness check and reaches
  # `gh auth status --hostname null`, whose refusal then reads as a CONFIRMED
  # not-authenticated answer. This read is the only way a host reaches gh
  # from this function, so "" is the only value that can stand for "no host".
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  local identity_json email name
  identity_json=$(_forge_git_identity)
  email=$(printf '%s' "$identity_json" | jq -r '.email // empty')
  name=$(printf '%s' "$identity_json" | jq -r '.name // empty')

  local decision="skip" basis="" active="" accounts_json="[]" match="none"

  if [ "$forge" != "github" ]; then
    basis="no_adapter"
  elif ! _forge_bin_check gh quiet github; then
    basis="cli_missing"
  else
    local gh_out authenticated
    gh_out=$(_forge_auth_status_github "$host")
    authenticated=$(printf '%s' "$gh_out" | jq -r '.authenticated')
    active=$(printf '%s' "$gh_out" | jq -r '.account // empty')
    accounts_json=$(printf '%s' "$gh_out" | jq -c '.accounts')

    if [ "$authenticated" != "true" ]; then
      basis="not_authenticated"
    elif [ -z "$email" ] && [ -z "$name" ]; then
      basis="no_git_identity"
    else
      local logins_json matched
      logins_json=$(_forge_identity_logins "$email" "$name")
      # First candidate that matches wins, and _forge_identity_logins emits
      # the authoritative noreply candidate alone -- so `match` reports the
      # strongest confidence that actually agreed, never a weaker one that
      # happened to be listed first.
      matched=$(printf '%s' "$logins_json" | jq -r --arg active "$active" \
        '($active | ascii_downcase) as $a
         | if $a == "" then empty
           else (map(select((.login | ascii_downcase) == $a)) | .[0] // null
                 | if . == null then empty else .confidence end)
           end')

      if [ -n "$matched" ]; then
        basis="identity_matches_active"
        match="$matched"
      elif [ "$(printf '%s' "$accounts_json" | jq 'length')" -lt 2 ]; then
        basis="single_account"
      else
        decision="ask"
        basis="diverged"
      fi
    fi
  fi

  jq -nc \
    --arg decision "$decision" \
    --arg basis "$basis" \
    --arg forge "$forge" \
    --arg host "$host" \
    --arg activeAccount "$active" \
    --argjson accounts "$accounts_json" \
    --arg email "$email" \
    --arg name "$name" \
    --arg match "$match" \
    '{decision: $decision,
      basis: $basis,
      forge: $forge,
      host: (if $host == "" then null else $host end),
      activeAccount: (if $activeAccount == "" then null else $activeAccount end),
      accounts: $accounts,
      identity: {email: (if $email == "" then null else $email end),
                 name: (if $name == "" then null else $name end)},
      match: $match}'
}

# ============================================================================
# Forge account selection -- the remembered answer
# ============================================================================
# Owns THREE operations on ONE document: record an answer, read it back and
# decide, and revoke it. It does not ask the human. That split is settled repo
# convention, not a choice made here: commands/references/interactivity.md puts
# the question in the COMMAND layer, and the reason is mechanical -- the only
# interactive prompt in this entire file, _prompt_category, is gated on
# `[ -t 0 ]` and reads /dev/tty, which never fires under Claude Code because
# the CLI is invoked through the Bash tool with a non-TTY stdin. A prompt
# implemented here would be silently dead in the only host that matters.
#
# THREE SHIPPED BUGS FROM THIS REPOSITORY'S OWN MODELS FLOW LAND HERE. None is
# hypothetical; each cost a release:
#
#   1. AN ANSWER THAT COULD NOT BE REVOKED (1.93.0, CHANGELOG:615). The models
#      dismissal marker "suppressed the prompt even after the config was
#      deleted, leaving the user silently stuck on all-inherit defaults with no
#      way to re-trigger the prompt short of also deleting the marker." The fix
#      decoupled the two files so deleting the ANSWER always re-triggers. That
#      is why --reselect exists in this verb at all, and why there is no
#      companion marker or sentinel anywhere in this section: THE ANSWER IS THE
#      ONLY STATE. Deleting the store by hand does exactly what --reselect does.
#
#   2. CHECKED BY FILE EXISTENCE RATHER THAN CONTENT (1.93.1, CHANGELOG:604).
#      `models-prompt-check` returned `skip` whenever models.json existed, even
#      when the current host's sub-table was missing or empty. The analogue here
#      is worse than an inconvenience: the store file exists the moment THIS
#      repository first answers, and phases 3/4 add gitlab.com and gitea hosts
#      to the same document, so a check that reads "file exists -> don't ask"
#      would silence every host after the first. --check therefore decides on
#      THIS HOST'S ENTRY, and an absent / empty / malformed store and an entry
#      that does not encode a usable answer ALL yield ask, never a silent skip.
#
#   3. A WRITER THAT CLOBBERED A SIBLING SCOPE (1.97.2, CHANGELOG:487).
#      `detect-models` in default mode "wrote a fresh document via `jq -n`,
#      silently dropping the inactive host's configured models on every
#      invocation." Every write here is read-merge-write through the single
#      _forge_account_store_merge path below, and NO code path in this section
#      reconstructs the document with `jq -n`. --reselect is the trap: writing
#      the file back without the entry is the obvious implementation and it
#      destroys every other host's answer, so it too is a merge (`del`), not a
#      rebuild. _forge_account_store_path's own header states the same
#      obligation from the store's side.
#
# DOCUMENT SHAPE, and why a REBUILD is impossible rather than merely discouraged:
# the store is a JSON object keyed by forge host, one file per repository
# (_forge_account_store_path). This function CANNOT enumerate the hosts a
# repository will ever use -- it only ever learns the ONE host _detect_forge
# resolves from the remote it is standing in front of right now. A rebuild
# would have to invent the other hosts' entries out of nothing, so read-merge-
# write is the only implementation that can be correct, not a stylistic
# preference. Each entry is:
#     {"mode": "active",  "recordedAt": "<ISO 8601 UTC>"}
#     {"mode": "account", "account": "<login>", "recordedAt": "<ISO 8601 UTC>"}
# The `mode` discriminator is what makes "the user chose to always use whichever
# account is active" a FIRST-CLASS persisted answer, distinguishable from "the
# user has not been asked". Encoding the opt-out as an empty account string, or
# by omitting the entry, is rejected on both the write and the read side --
# neither is distinguishable from absent, which is precisely the property the
# opt-out must not have.

# Reads the store document, normalizing every degenerate input to `{}`:
# file absent, file empty, file unreadable, file holding malformed JSON, and
# file holding valid JSON that is not an object (an array or a bare string a
# hand-edit could leave behind). Prints exactly one JSON object on stdout.
#
# Normalizing rather than erroring is bug 2's lesson applied at the read: the
# caller's next step compares THIS HOST'S entry against `{}` and asks when it
# finds nothing, so a corrupt store degrades into "nobody has answered yet"
# and the user gets the question back. The alternative -- treating malformed
# as "already answered" -- is the silent skip that shipped.
_forge_account_store_read() {
  local store="${1:-}" raw=""

  if [ -z "$store" ] || [ ! -f "$store" ]; then
    printf '{}\n'
    return 0
  fi

  raw=$(cat "$store" 2>/dev/null) || raw=""
  if [ -z "$raw" ]; then
    printf '{}\n'
    return 0
  fi

  printf '%s' "$raw" | jq -c 'if type == "object" then . else {} end' 2>/dev/null || printf '{}\n'
}

# THE ONLY WRITE PATH IN THIS SECTION. Read-merge-write, under one lock.
# Usage: _forge_account_store_merge <store_path> <jq_filter> <jq_arg>...
#
# The jq filter is applied to the CURRENT document, read INSIDE the lock, so a
# concurrent writer cannot slip between the read and the write and lose an
# entry -- which is the whole reason the read is not hoisted out to the caller
# where it would be easier to see.
#
# Combines the two precedents this repository already has rather than inventing
# a third: roadmap-init's `( _lock "$f.lock"; ...; mv ) 200>"$f.lock"` subshell
# shape, and write_aimi_models_config's create-then-restrict-then-write
# ordering (mkdir -p, mktemp, chmod 0600 BEFORE any content, mv, temp removed on
# mv failure). The 0600-before-content ordering is load-bearing for a file that
# names accounts: it must never exist, even for the instant between creation and
# the first write, readable by anyone but its owner.
#
# read_state/write_state are deliberately NOT used: their flock +
# validate_path_in_project discipline is scoped to AIMI_ROOT/.aimi/ and does not
# transfer to a path under the aimi config directory.
#
# The `|| rc=$?` makes the subshell the left side of an AND-OR list, the one
# construct `set -e` is defined to exempt, so a lock path that cannot be opened
# is a reportable failure rather than an instant, silent exit. The `200>`
# redirect stays attached to the subshell, before the `||`.
_forge_account_store_merge() {
  local store="$1" filter="$2"
  shift 2

  local dir
  dir=$(dirname "$store")
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "Error: forge-account-select: cannot create directory: $dir" >&2
    return 1
  fi

  local tmp=""
  tmp=$(mktemp "${store}.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$tmp" ]; then
    echo "Error: forge-account-select: cannot create a temp file beside $store" >&2
    return 1
  fi
  chmod 0600 "$tmp"

  local rc=0
  (
    _lock "${store}.lock"
    local current merged
    current=$(_forge_account_store_read "$store")
    merged=$(printf '%s' "$current" | jq -c "$@" "$filter") || exit 1
    printf '%s\n' "$merged" > "$tmp"
    mv "$tmp" "$store"
  ) 200>"${store}.lock" || rc=$?

  rm -f "$tmp" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    echo "Error: forge-account-select: failed to write $store" >&2
    return 1
  fi
}

# Prints the forge host this repository's answer is keyed under, or nothing.
#
# `// empty` is not defensive noise. .host is JSON null whenever AIMI_FORGE_TYPE
# short-circuits _detect_forge, and a bare `jq -r '.host'` renders that null as
# the 4-character TEXT "null" -- non-empty, so it survives every downstream
# emptiness check. Commit d1b19ca is where that exact value reached
# `gh auth status --hostname null` and its refusal read as a CONFIRMED
# not-authenticated answer. Here it would key an entry under the literal host
# "null", which no later invocation resolving a real host would ever find again.
_forge_account_host() {
  local forge_info
  forge_info=$(_detect_forge)
  printf '%s' "$forge_info" | jq -r '.host // empty'
}

# Extracts THIS host's recorded answer from a store document, or `null`.
#
# The mode discriminator is validated here, not merely read: an entry that is
# not an object, carries an unrecognized mode, or encodes mode "account" with a
# missing or empty account is reported as `null` -- i.e. "nobody has answered".
# That is bug 2's content-check discipline pushed one level down from the
# document to the entry, and it is also the read-side half of rejecting the
# empty string as an encoding of the "always use the active account" opt-out.
_forge_account_stored_entry() {
  local store="$1" host="$2"

  if [ -z "$store" ] || [ -z "$host" ]; then
    printf 'null\n'
    return 0
  fi

  _forge_account_store_read "$store" | jq -c --arg host "$host" '
    (.[$host] // null) as $e
    | if ($e | type) != "object" then null
      elif $e.mode == "active" then $e
      elif $e.mode == "account" and ($e.account | type) == "string" and $e.account != "" then $e
      else null
      end'
}

# Usage/mode error. Always exits 1 -- every caller relies on that, so no arm of
# the parsing loop needs its own guard against falling through.
_forge_account_select_usage() {
  if [ -n "${1:-}" ]; then
    echo "Error: forge-account-select: $1" >&2
  fi
  echo "Usage: aimi-cli.sh forge-account-select (--check | --record <login> | --record-active | --reselect) [--project <path>]" >&2
  echo "  Exactly one mode is required:" >&2
  echo "    --check           read this repository's recorded answer back and decide whether the account question is warranted; writes nothing" >&2
  echo "    --record <login>  remember <login> as this repository's forge account" >&2
  echo "    --record-active   remember \"always use whichever account is active\" -- a real answer, not the absence of one" >&2
  echo "    --reselect        forget this repository's answer so the next --check asks again" >&2
  exit 1
}

# --check. Reads and decides; writes NOTHING -- no store file, no config
# directory, no chmod, no mutation of a pre-existing store.
#
# That is not tidiness, it is the mechanical guarantee behind the agent-mode
# rule. interactivity.md requires every question site to auto-select under
# AIMI_AGENT_MODE / CI / --non-interactive, and if that auto-answer were
# persisted, ONE CI run would silently and permanently answer the question for
# every human who touched the repository afterwards. Applied-but-not-persisted
# is enforced by --check writing nothing at all; persisting is always a
# separate, explicit --record* call the command layer makes only after a human
# actually answered.
#
# The rungs below are mutually exclusive and evaluated in a fixed order:
#   identity_override  AIMI_FORGE_IDENTITY names the account to act as, so the
#                      question is moot. Highest precedence, matching this
#                      file's own env-over-stored convention (AIMI_FORGE_TYPE
#                      short-circuits detection entirely).
#   no_repository      no resolvable git identity, so there is nowhere to
#                      remember an answer. Near-unreachable behind
#                      _require_git_repo; kept because _forge_account_store_path
#                      is documented to be allowed to decline.
#   no_host            no forge host resolved (no remote, or AIMI_FORGE_TYPE
#                      overriding detection), so the answer has no key. Asking
#                      a question whose answer cannot be stored is worse than
#                      not asking.
#   answer_recorded    this host already has a usable answer.
#   <divergence basis> otherwise the verdict from _forge_account_divergence is
#                      adopted verbatim, decision and basis together. That
#                      verdict is necessary but not sufficient on its own,
#                      which is exactly what the rungs above supply.
_forge_account_select_check() {
  local store="$1"
  local verdict host stored decision basis

  verdict=$(_forge_account_divergence)
  host=$(printf '%s' "$verdict" | jq -r '.host // empty')
  stored=$(_forge_account_stored_entry "$store" "$host")

  decision="skip"
  if [ -n "${AIMI_FORGE_IDENTITY:-}" ]; then
    basis="identity_override"
  elif [ -z "$store" ]; then
    basis="no_repository"
  elif [ -z "$host" ]; then
    basis="no_host"
  elif [ "$stored" != "null" ]; then
    basis="answer_recorded"
  else
    decision=$(printf '%s' "$verdict" | jq -r '.decision')
    basis=$(printf '%s' "$verdict" | jq -r '.basis')
  fi

  printf '%s' "$verdict" | jq -c \
    --arg decision "$decision" \
    --arg basis "$basis" \
    --argjson stored "$stored" \
    --arg store "$store" \
    '{action: "check"}
     + .
     + {decision: $decision,
        basis: $basis,
        stored: $stored,
        store: (if $store == "" then null else $store end)}'
}

# --record <login> and --record-active. Both persist through the one merge path.
_forge_account_select_record() {
  local store="$1" entry_mode="$2" login="$3"

  if [ -z "$store" ]; then
    echo "Error: forge-account-select: no resolvable git repository here, so there is nowhere to record an answer" >&2
    exit 1
  fi

  local host
  host=$(_forge_account_host)
  if [ -z "$host" ]; then
    echo "Error: forge-account-select: no forge host resolved for this repository -- an answer is keyed by host, so there is nothing to key it under" >&2
    echo "  A host comes from the git remote; AIMI_FORGE_TYPE overrides forge detection and deliberately reports no host." >&2
    exit 1
  fi

  local recorded_at entry
  recorded_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  if [ "$entry_mode" = "active" ]; then
    entry=$(jq -nc --arg at "$recorded_at" '{mode: "active", recordedAt: $at}')
  else
    entry=$(jq -nc --arg account "$login" --arg at "$recorded_at" \
      '{mode: "account", account: $account, recordedAt: $at}')
  fi

  # `.[$host] = $entry` -- assignment into the document that was just read, so
  # every OTHER host's entry survives byte-for-byte. Never `jq -n`.
  _forge_account_store_merge "$store" '.[$host] = $entry' \
    --arg host "$host" --argjson entry "$entry" || exit 1

  jq -nc --arg host "$host" --arg store "$store" --argjson stored "$entry" \
    '{action: "record", host: $host, store: $store, stored: $stored}'
}

# --reselect. Revocation, and the ONLY state involved: there is no companion
# marker to also delete, so this and `rm` on the store file are equivalent.
_forge_account_select_reselect() {
  local store="$1"

  if [ -z "$store" ]; then
    echo "Error: forge-account-select: no resolvable git repository here, so there is no answer to forget" >&2
    exit 1
  fi

  local host
  host=$(_forge_account_host)
  if [ -z "$host" ]; then
    echo "Error: forge-account-select: no forge host resolved for this repository -- an answer is keyed by host, so there is nothing to look up" >&2
    exit 1
  fi

  local had
  had=$(_forge_account_stored_entry "$store" "$host")

  # `del(.[$host])` on the document that was just read. Rewriting the file
  # without the entry is the obvious implementation and it is CHANGELOG:487
  # exactly: every other host's answer would go with it.
  _forge_account_store_merge "$store" 'del(.[$host])' --arg host "$host" || exit 1

  local cleared="false"
  if [ "$had" != "null" ]; then
    cleared="true"
  fi

  jq -nc --arg host "$host" --arg store "$store" --argjson cleared "$cleared" \
    '{action: "reselect", host: $host, store: $store, stored: null, cleared: $cleared}'
}

# Records, reads back and revokes this repository's forge account answer.
#
# Usage: aimi-cli.sh forge-account-select (--check | --record <login> |
#                                          --record-active | --reselect)
#                                         [--project <path>]
#
# RESELECT IS A FLAG, NEVER A SECOND VERB. The phase declares exactly one
# `creates` identity for this work, cmd_forge_account_select, and verify-creates
# greps tracked source for that literal string at phase close; a second verb
# would need a second identity and a roadmap amendment. Revocation was
# originally proposed as its own story and was folded in here precisely to keep
# that contract intact.
#
# NO --token, --identity OR OTHERWISE CREDENTIAL-SHAPED FLAG EXISTS in the
# parsing loop below, and none may be added. cmd_forge_pr_create,
# cmd_forge_pr_edit and cmd_forge_issue_create each carry the same statement:
# an identity reaches a forge CLI only through the environment, never through
# argv, because argv leaks through `ps` and shell history. A LOGIN is not a
# credential, which is why --record takes one -- but the flag namespace stays
# clear of anything a future reader could mistake for a token sink.
cmd_forge_account_select() {
  check_jq

  local mode="" account="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --check)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --check) -- exactly one is allowed"
        fi
        mode="check"
        ;;
      --record)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --record) -- exactly one is allowed"
        fi
        mode="record"
        # Consumes the value only when one is actually there. A bare `shift`
        # on the last argument returns non-zero, and this file runs `set -e`,
        # so `--record` with no login would abort the process before the
        # empty-value check below could print anything at all.
        if [ $# -ge 2 ]; then
          shift
          account="$1"
        fi
        ;;
      --record-active)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --record-active) -- exactly one is allowed"
        fi
        mode="record-active"
        ;;
      --reselect)
        if [ -n "$mode" ]; then
          _forge_account_select_usage "two modes given (--$mode and --reselect) -- exactly one is allowed"
        fi
        mode="reselect"
        ;;
      --project)
        if [ $# -ge 2 ]; then
          shift
          project_dir="$1"
        fi
        ;;
      *)
        _forge_account_select_usage "unknown flag: $1"
        ;;
    esac
    shift
  done

  if [ -z "$mode" ]; then
    _forge_account_select_usage "no mode given"
  fi

  # An empty --record value is refused rather than stored. Storing "" would
  # encode the "always use the active account" opt-out as a value that is
  # indistinguishable from absent -- the one property that answer must not
  # have. A leading dash is refused too: it is a flag the parser swallowed as
  # a value, never a login anyone meant to type.
  if [ "$mode" = "record" ]; then
    if [ -z "$account" ]; then
      _forge_account_select_usage "--record requires a <login>; --record-active is the way to say \"always use whichever account is active\""
    fi
    case "$account" in
      -*)
        _forge_account_select_usage "--record got \"$account\", which looks like a flag rather than a login"
        ;;
    esac
  fi

  _require_git_repo "$project_dir"

  local store=""
  store=$(_forge_account_store_path) || store=""

  case "$mode" in
    check)         _forge_account_select_check "$store" ;;
    record)        _forge_account_select_record "$store" "account" "$account" ;;
    record-active) _forge_account_select_record "$store" "active" "" ;;
    reselect)      _forge_account_select_reselect "$store" ;;
  esac
}

# Requests owner and name from a single `gh repo view` call -- never the two
# separate calls skills/resolve-pr-parallel/scripts/get-pr-comments makes
# today. Prints {owner, repo} on success; returns 1 (no output) on any
# failure so the caller falls back without needing to know why gh failed
# (missing auth, network, or anything else -- mirrors _resolve_default_
# branch's own primary-call-plus-offline-fallback shape, which does not
# distinguish why the primary failed either).
_forge_repo_info_github() {
  local raw="" rc=0
  raw=$(gh repo view --json owner,name 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  printf '%s' "$raw" | jq -c '{owner: .owner.login, repo: .name}' 2>/dev/null || return 1
}

# The GitLab arm of _forge_repo_info_github: one `glab repo view -F json`
# call, printing {owner, repo} on success and returning 1 (no output) on any
# failure so the caller falls through to the same local-parse tier -- exactly
# the contract the github helper above already has.
#
# `-F json`, NOT a gh-style `--json <field-list>`. glab has no field selector
# on any read command: `-F, --output string  Format output as: text, json`
# plus `--jq string  Filter JSON output with a jq expression` is the whole
# interface (docs/source/repo/view.md), so the call asks for the WHOLE
# document and this function picks keys out of it afterwards.
#
# GitLab models ownership as a NAMESPACE PATH, not an owner login, and that
# path can be arbitrarily deep (group/subgroup/subgroup/project). So the
# split is done by the SAME _forge_repo_info_parse_url the local-parse tier
# uses -- it already treats every segment before the last as the owner,
# specifically so a nested subgroup survives intact (see its header). Feeding
# it a bare `group/subgroup/project` path exercises its no-scheme, no-colon
# branch, which is a plain "last segment is the repo" split.
#
# `path_with_namespace` is the primary key; `namespace.full_path` + `path` is
# the equivalent recomposition, kept as a fallback for a response that omits
# the flattened form. Both are go-gitlab *gitlab.Project struct tags
# (`PathWithNamespace json:"path_with_namespace"`, `Path json:"path"`,
# `Namespace json:"namespace"` -> `FullPath json:"full_path"`), which ARE
# glab's JSON keys because glab marshals the struct rather than projecting
# it -- the same evidence chain, and the same declared verification ceiling
# (glab not installed here), that _forge_map_pr_field_gitlab's header states.
_forge_repo_info_gitlab() {
  local raw="" rc=0
  raw=$(glab repo view -F json 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi

  local path=""
  path=$(printf '%s' "$raw" | jq -r '
    if (.path_with_namespace // "") != "" then .path_with_namespace
    elif (.namespace.full_path // "") != "" and (.path // "") != "" then (.namespace.full_path + "/" + .path)
    else "" end' 2>/dev/null) || return 1

  [ -n "$path" ] || return 1

  _forge_repo_info_parse_url "$path"
}

# Parses owner/repo directly out of a git remote URL -- the offline fallback
# used when gh is absent, unauthenticated, or the forge has no adapter yet.
# Every path segment before the last becomes owner (not just the
# second-to-last), so a GitLab-style nested subgroup path
# (group/subgroup/repo) survives intact for the GitLab adapter phase 3 later
# shipped. Prints {owner, repo}, both null when the path never yields at
# least two segments.
_forge_repo_info_parse_url() {
  local url="$1" path=""

  if [[ "$url" == *"://"* ]]; then
    path="${url#*://}"
    path="${path#*/}"
  elif [[ "$url" == *":"* ]]; then
    path="${url#*:}"
  else
    path="$url"
  fi

  path="${path%.git}"
  path="${path#/}"
  path="${path%/}"

  local repo="" owner=""
  if [ -n "$path" ] && [[ "$path" == */* ]]; then
    repo="${path##*/}"
    owner="${path%/*}"
  fi

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    jq -nc '{owner: null, repo: null}'
    return 0
  fi

  jq -nc --arg owner "$owner" --arg repo "$repo" '{owner: $owner, repo: $repo}'
}

# Two-tier resolution mirroring _resolve_default_branch's own shape: a forge
# adapter is the primary path when the detected forge has one AND its CLI is
# present (github -> gh, gitlab -> glab); parsing owner/repo straight out of
# the already-resolved remote URL is the offline fallback, used whenever that
# CLI is missing, unauthenticated, the forge has no adapter, or the primary
# call otherwise fails. AT MOST ONE forge CLI is ever invoked -- the arms are
# an if/elif chain keyed on the detected forge, so a GitLab repository never
# shells out to gh and a GitHub one never shells out to glab. When even
# the fallback yields no usable owner/repo (no origin configured, or a path
# that never splits into two segments), reports status=not_found -- a
# confirmed absence, not a tool error, per forge-contract.md's Three-Way
# Status Convention.
_forge_repo_info() {
  local forge_info forge host remote_url
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  # See _forge_auth_status's note on the same read: a JSON null host must
  # become the empty string, never the text "null". Downstream, this is what
  # makes _forge_pr_write_print_manual's own already-correct
  # `.data.host // empty` fallback fire at all -- the string "null" is truthy
  # in jq, so that fallback was silently dead and printed https://null/... .
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')
  remote_url=$(printf '%s' "$forge_info" | jq -r '.remoteUrl // empty')

  local owner="" repo="" source=""

  # THERE IS NO gitea TIER IN THIS CHAIN, AND ITS ABSENCE IS A DECISION.
  # Recorded here rather than left as a gap, so the next reader meets a
  # reason instead of an oversight:
  #   - `tea` has no "show the current repository as JSON" command at all.
  #   - `tea repos <owner>/<name>` REQUIRES the slug as an argument -- the
  #     very thing a repo-info tier would have to local-parse out of the
  #     remote URL first -- and then calls print.RepoDetails WITHOUT
  #     honouring `--output` (cmd/repos.go:47-65), so there is no JSON to
  #     read back either.
  #   - `tea repos list` lists every accessible repository, not this one.
  # A gitea arm would therefore local-parse the answer, ask tea about it, and
  # learn nothing -- pure cost. gitea falls through to _forge_repo_info_parse_url
  # below and reports source "local-parse", which is a correct answer and the
  # reason this verb already worked for Gitea before any adapter existed.
  # (Read off gitea/tea `main` source on 2026-08-06; `tea` is not installed
  # on the machine this was written on.)
  if [ "$forge" = "github" ] && _forge_bin_check gh quiet github; then
    local gh_json=""
    if gh_json=$(_forge_repo_info_github); then
      owner=$(printf '%s' "$gh_json" | jq -r '.owner // empty')
      repo=$(printf '%s' "$gh_json" | jq -r '.repo // empty')
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        source="gh"
      fi
    fi
  elif [ "$forge" = "gitlab" ] && _forge_bin_check glab quiet gitlab; then
    # `source` distinguishes WHICH tier answered, so a GitLab repository
    # whose glab call succeeded reports "glab" and is no longer indistinguish-
    # able from one that only ever managed the offline remote-URL parse.
    local glab_json=""
    if glab_json=$(_forge_repo_info_gitlab); then
      owner=$(printf '%s' "$glab_json" | jq -r '.owner // empty')
      repo=$(printf '%s' "$glab_json" | jq -r '.repo // empty')
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        source="glab"
      fi
    fi
  fi

  if { [ -z "$owner" ] || [ -z "$repo" ]; } && [ -n "$remote_url" ]; then
    local parsed
    parsed=$(_forge_repo_info_parse_url "$remote_url")
    owner=$(printf '%s' "$parsed" | jq -r '.owner // empty')
    repo=$(printf '%s' "$parsed" | jq -r '.repo // empty')
    if [ -n "$owner" ] && [ -n "$repo" ]; then
      source="local-parse"
    fi
  fi

  local status="not_found" data_json="null"
  if [ -n "$owner" ] && [ -n "$repo" ]; then
    status="found"
    data_json=$(jq -nc \
      --arg forge "$forge" \
      --arg host "$host" \
      --arg owner "$owner" \
      --arg repo "$repo" \
      --arg source "$source" \
      '{forge: $forge,
        host: (if $host == "" then null else $host end),
        owner: $owner,
        repo: $repo,
        nameWithOwner: ($owner + "/" + $repo),
        source: $source}')
  fi

  _forge_emit_status "$status" "$data_json" ""
}

# Resolves the active forge's owner/repo for the current git repository. See
# the section header above for the gh-primary/local-parse-fallback contract.
cmd_forge_repo_info() {
  check_jq

  local project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        shift
        project_dir="${1:-}"
        ;;
      *)
        echo "Error: forge-repo-info: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  _forge_repo_info
}

# ============================================================================
# forge-pr-view (US-004)
# ============================================================================
# Fixes the exact defect commands/open-pr.md carries today:
#   gh pr view "$CURRENT_BRANCH" --json url --jq '.url' 2>/dev/null
# exits non-zero for BOTH "no PR exists for this branch" AND "gh/auth is
# broken" -- a broken token reads as "no PR yet" and open-pr.md proceeds to
# create a duplicate. forge-pr-view adopts the three-way found/not_found/
# error status forge-contract.md publishes so a caller can finally tell the
# two apart, and adds a --include field selector so a caller that only wants
# `url` (open-pr.md's own two call sites) never pays for the expensive
# `files` field the way every current `gh pr view --json` call site does
# today regardless of what it actually asked for.
#
# This verb's envelope is deliberately its OWN shape --
# {status, pr, unsupported_fields, message} -- rather than the generic
# three-way envelope _forge_emit_status builds ({status, data, message,
# reason}): the --include selector requires `pr` to carry exactly the caller's
# requested keys and no others, never the full fixed superset
# _forge_build_pr_json always returns, and a not_found outcome here must
# carry a populated `message` (naming the ref that was searched) rather
# than staying forced-null the way _forge_emit_status's own `message` does
# for every outcome but error -- which forge-contract.md's Three-Way Status
# Convention explicitly permits for not_found ("message is null unless a
# short human-readable note is useful"). The found/not_found/error status
# vocabulary still matches that convention exactly, and the degraded-reason
# field is named `message` here for the same reason: it is the contract's
# own human-readable degradation signal, never a per-verb invention. This
# envelope deliberately does NOT carry the machine-readable `reason` enum
# the shared builder now emits -- forge-contract.md's Degradation Reason
# Enum names forge-pr-view's shape as the one exception `reason` is not
# extended onto.
#
# Field names inside `pr` are the NORMALIZED PR contract's own (number,
# url, title, body, state, headRefName, baseRefName, files, isDraft,
# mergeable) -- never gh's raw vocabulary. gh's response is translated in
# both directions by _forge_map_pr_field_github and normalized through the
# one shared _forge_build_pr_json builder, so GitHub's raw shape never
# leaks past this adapter. On github the two vocabularies happen to be
# identical today, so every current call site's own jq expression (e.g.
# `.files[].path`) survives unchanged.
#
# Phase 3 added the gitlab adapter alongside it (_forge_pr_view_gitlab,
# `glab mr view <ref> -F json`). gitea still has none, and it -- plus a
# missing gh OR a missing glab -- degrades through the quiet
# _forge_bin_check mode, matching review.md's own already-documented git-diff
# fallback for a missing gh so a migration onto this verb introduces no new
# warning banner.

# Emit the forge-pr-view envelope: {status, pr, unsupported_fields, message}.
# status must be found | not_found | error (anything else is a caller error,
# exit 1 -- never silently coerced). pr and unsupported_fields are forced
# null unless status=="found"; message is forced null only when
# status=="found" -- not_found and error both carry a populated message
# string (the searched ref, or gh's own failure text, respectively).
#
# On found, unsupported_fields is ALWAYS a JSON array, never a bare null --
# including an explicitly empty [] when every requested capability-gated
# field was supplied. A bare null there would be a third state alongside
# "empty" and "populated" that no caller can interpret; the array-or-null
# split is driven purely by status, mirroring _forge_emit_status's own
# null-forcing convention.
_forge_pr_view_emit() {
  local status="$1" pr_json="${2:-null}" unsupported_json="${3:-null}" message="${4:-}"

  case "$status" in
    found|not_found|error) ;;
    *)
      echo "Error: _forge_pr_view_emit: status must be found, not_found or error (got: $status)" >&2
      return 1
      ;;
  esac

  if [ "$status" = "found" ]; then
    message=""
    if [ -z "$unsupported_json" ] || [ "$unsupported_json" = "null" ]; then
      unsupported_json="[]"
    fi
  else
    pr_json="null"
    unsupported_json="null"
  fi

  jq -nc \
    --arg status "$status" \
    --argjson pr "$pr_json" \
    --argjson unsupportedFields "$unsupported_json" \
    --arg message "$message" \
    '{status: $status, pr: $pr, unsupported_fields: $unsupportedFields,
      message: (if $message == "" then null else $message end)}'
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the field name GitHub's own
# `gh pr view --json` uses for it. For phase 1 every one of the ten fields
# maps to an identically-spelled gh field, but the table is written out
# EXPLICITLY rather than assumed: it is the single seam a later GitLab or
# Gitea adapter replaces (glab's `description`/`source_branch`/
# `target_branch`, tea's `head`/`base`) without touching the verb body
# around it. An unmapped name prints nothing, so a field this adapter
# cannot express is never silently passed through to gh as-is.
# Usage: _forge_map_pr_field_github <contract-field>
_forge_map_pr_field_github() {
  case "$1" in
    number)      printf 'number' ;;
    url)         printf 'url' ;;
    title)       printf 'title' ;;
    body)        printf 'body' ;;
    state)       printf 'state' ;;
    headRefName) printf 'headRefName' ;;
    baseRefName) printf 'baseRefName' ;;
    files)       printf 'files' ;;
    isDraft)     printf 'isDraft' ;;
    mergeable)   printf 'mergeable' ;;
  esac
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the field name GitLab's own
# `glab mr view <ref> -F json` uses for it. This is the GitLab arm of the
# seam _forge_map_pr_field_github's own header names as "the single seam a
# later GitLab or Gitea adapter replaces"; the two are kept ADJACENT and
# identically case-statement-shaped, ten branches each, so they stay
# diffable side by side.
#
# An unmapped name prints nothing, so a field this adapter cannot express
# is never silently passed through to glab as-is -- the identical
# silent-empty default the github mapper's case statement has.
#
# HOW THIS TABLE IS USED DIFFERS FROM THE GITHUB ONE. gh has a
# `--json <field-list>` selector, so its table names fields to REQUEST.
# glab has no such selector: `-F json` prints the WHOLE marshalled
# document (internal/cmdutils/output_format.go's EnableJSONOutput registers
# `--output`/`-F` over the enum text|json, and
# internal/commands/mr/view/mr_view.go's printJSONMR is literally
# `return opts.io.PrintJSON(mr)` over a *gitlab.MergeRequest), and
# filtering is done afterwards with `--jq`. So every name below is a KEY to
# PICK OUT of that document, never a field to ask for.
#
# `reviews` is deliberately absent and is NOT one of the ten contract
# fields. GitLab merge requests carry `reviewers` -- people ASSIGNED to
# review (BasicMergeRequest.Reviewers, `json:"reviewers"`) -- but have no
# equivalent of GitHub's `reviews` array of SUBMITTED
# APPROVED/CHANGES_REQUESTED verdicts. GitLab models those as approvals, a
# different resource behind its own endpoint
# (MergeRequestsService.GetMergeRequestApprovals). Do not conflate
# reviewers with reviews.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY KEY BELOW, AND NOTE WHAT
# HAS SINCE BEEN LIFTED. glab was NOT installed on the machine this was
# written on, so when this table was authored not one key here had been
# observed coming out of the real binary. The phase-2 github mapper was
# verified against a real gh v2.94.0 before a line of it was written; this
# function could not make that claim at the time.
#
# WHAT WAS LATER OBSERVED, and is therefore no longer under that ceiling: on
# 2026-08-06 every key in this table was checked against a real GitLab CE in
# a container with a real glab 1.112.0. `glab mr view <iid> -F json` returned
# all nine -- iid (a number), web_url, title, description, state,
# source_branch, target_branch, draft (a real boolean) and
# detailed_merge_status -- with the names and types this table asserts, in a
# 64-key document, which is itself the whole-document claim below confirmed.
# `state` came back `opened`, which _forge_map_state already normalizes to
# `open` for gitlab. Nothing in this table needed correcting. (The same run
# against Gitea DID correct a claim there -- see
# _forge_map_pr_field_gitea's header -- so this is a measured result, not a
# rubber stamp.)
#
# WHAT REMAINS UNDER THE CEILING: the review-thread and issue paths, whose
# keys were not exercised. For those the stub still emits whatever its author
# believed, so a wrong key name passes green on both sides.
#
# Every key was originally read off glab's own source and GitLab's API docs: gitlab-org/cli (the glab CLI) and
# gitlab-org/api/client-go (go-gitlab), whose struct tags ARE glab's JSON
# keys precisely because glab marshals *gitlab.MergeRequest directly rather
# than projecting it. Line numbers below are client-go's merge_requests.go
# on main as of 2026-08-05.
#
# number -> iid, NOT id. Both exist on the struct (`ID int64 json:"id"`
# line 81, `IID int64 json:"iid"` line 82). `id` is globally unique across
# the whole GitLab instance; `iid` is the per-project number the user sees
# in the MR URL and types at the CLI. Mapping to `id` would yield a number
# that resolves to a DIFFERENT merge request.
#
# state -> state names the KEY only. GitLab's VALUE vocabulary is its own
# ("opened", not "open"), and normalizing it is _forge_map_state's job --
# it already carries the gitlab arm that folds "opened" to "open".
#
# THE THREE MAPPINGS THAT HAD TO BE DETERMINED RATHER THAN ASSUMED:
#
#   files -> NOTHING, and that is a SETTLED answer rather than an
#     unresolved one: `glab mr view -F json` carries no changed-file list at
#     all, so there is no key to name. Neither MergeRequest nor the
#     BasicMergeRequest it embeds has a Changes field; the only thing close
#     is `ChangesCount string json:"changes_count"` (line 146), a COUNT
#     string, not a file list. A file list requires a SEPARATE call --
#     GetMergeRequestChanges (projects/:id/merge_requests/:iid/changes,
#     merge_requests.go:538) or ListMergeRequestDiffs (.../diffs, line 561)
#     -- and mr_view.go's JSON path issues neither. Emitting nothing is
#     therefore correct, not merely cautious.
#
#   mergeable -> detailed_merge_status. `DetailedMergeStatus string
#     json:"detailed_merge_status"` is on BasicMergeRequest (line 106) and
#     there is NO MergeStatus field on either struct: the single
#     `json:"merge_status"` in the whole file belongs to the unrelated
#     BlockingMergeRequest type (line 1049), so `merge_status` never appears
#     in a `glab mr view -F json` document at all. That settles the older-vs-
#     newer question by absence rather than by preference, and it agrees
#     with GitLab's docs deprecating merge_status in 15.6 in favour of
#     detailed_merge_status. The VALUE is an enum string (e.g. "mergeable",
#     "not_open"), not a boolean -- the same shape GitHub's
#     MERGEABLE/CONFLICTING/UNKNOWN takes, which is why _forge_build_pr_json
#     already carries mergeable as a string.
#
#   isDraft -> draft. BOTH keys are emitted, because glab marshals the whole
#     struct: `Draft bool json:"draft"` on BasicMergeRequest (line 103) and
#     `WorkInProgress bool json:"work_in_progress"` on MergeRequest (line
#     159). The tie is broken by go-gitlab's own comment on the latter,
#     verbatim "// Deprecated: use Draft instead" (line 158), which matches
#     GitLab's API docs ("work_in_progress ... Deprecated. Use draft
#     instead."). So `draft`.
#
# Usage: _forge_map_pr_field_gitlab <contract-field>
_forge_map_pr_field_gitlab() {
  case "$1" in
    number)      printf 'iid' ;;
    url)         printf 'web_url' ;;
    title)       printf 'title' ;;
    body)        printf 'description' ;;
    state)       printf 'state' ;;
    headRefName) printf 'source_branch' ;;
    baseRefName) printf 'target_branch' ;;
    # Deliberately EMPTY, not missing. The branch is kept so the two mappers
    # stay ten-for-ten diffable and a reader meets the omission at the line
    # they look at, rather than only in the header. See the `files` note.
    files)       ;;
    isDraft)     printf 'draft' ;;
    mergeable)   printf 'detailed_merge_status' ;;
  esac
}

# Maps one NORMALIZED PR contract field name (forge-contract.md's
# "Normalized PR Field Set") to the key Gitea's own `tea` CLI uses for it.
# This is the gitea arm of the seam _forge_map_pr_field_github's header names
# as "the single seam a later GitLab or Gitea adapter replaces"; the three
# mappers are kept ADJACENT and identically case-statement-shaped, ten
# branches each, so they stay diffable side by side.
#
# An unmapped name prints nothing, so a field this adapter cannot express is
# never silently passed through to tea as-is -- the identical silent-empty
# default the other two mappers' case statements have.
#
# TEA EMITS TWO DIFFERENT JSON SHAPES FOR THE SAME PULL REQUEST, AND EVERY
# KEY BELOW NAMES THE FIRST ONE. This has no gh or glab analogue and is the
# single most likely way to get this adapter wrong:
#
#   DETAIL -- `tea pulls <index> -o json`. One OBJECT with TYPED values,
#     built from the purpose-built `pullData` struct (cmd/pulls.go:29-52):
#     `index` is a JSON number, `mergeable`/`hasMerged` are real booleans,
#     and `base`/`head` are pr.Base.Ref/pr.Head.Ref -- BARE branch names
#     with no `owner:` prefix (cmd/pulls.go:174-177).
#
#   LIST -- `tea pulls list -o json -f <csv>`. A JSON ARRAY whose keys are
#     the --fields names VERBATIM. An earlier revision of this header said
#     SNAKE-CASED, citing toSnakeCase (modules/print/table.go:175-179). That
#     function exists but never fires: no valid --fields name is camelCase,
#     and the two that carry a hyphen keep it. VERIFIED AGAINST A REAL
#     BINARY: `-f index,author-id,base-commit` against Gitea 1.27.1 with tea
#     0.15.1 returned the keys `index`, `author-id`, `base-commit` unchanged.
#     Values are ALWAYS JSON STRINGS, because
#     orderedRow.MarshalJSON (:187-208) marshals a map[string]string. `index`
#     comes back "42", `mergeable` "true", `head` may carry an `owner:branch`
#     prefix for a cross-fork PR (formatPRHead, modules/print/pull.go:83-93).
#
# THIS ADAPTER READS THE DETAIL PATH. _forge_build_pr_json already tolerates
# a string number (`try ($number | tonumber) catch $number`), so the detail
# document's typed values survive the trip through the builder unharmed.
# Pointing a gitea verb at `tea pulls list` output instead would hand
# _forge_pr_view_build_found an array, whose every has($k) probe fails and
# whose every field is therefore skipped -- a silently all-null pr.
#
# TEA HAS A FIELD SELECTOR, SO DO NOT COPY GLAB'S SHAPE BY HABIT. `--fields,
# -f` is a CSV flag over a fixed allowlist (cmd/flags/generic.go:157,
# FieldsFlag) -- closer to gh's `--json <field-list>` than to glab.
# _forge_pr_view_gitlab fetches the WHOLE marshalled document and picks keys
# out of it afterwards (aimi-cli.sh:4688-4701) only because glab has no
# selector at all; that is a workaround for a missing feature, not a house
# style, and a gitea read verb must not inherit it.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY KEY BELOW, AND NOTE WHAT
# HAS SINCE BEEN LIFTED. Every flag, subcommand and JSON key below was first
# read off `gitea/tea` `main` source on 2026-08-06, file and line cited per
# claim, with no binary present -- the same ceiling phase 3 declared for glab
# at :4380-4389, and for the same reason. The suite still only proves WHICH
# arguments this file emits and HOW it parses a fixture.
#
# WHAT WAS LATER OBSERVED, and is therefore no longer under that ceiling:
# on 2026-08-06 the PR shape was checked against a real Gitea 1.27.1 in a
# container with a real tea 0.15.1. `tea pulls <index> -o json` returned
# exactly the 21 keys named below, with `index` a number, `mergeable` and
# `hasMerged` real booleans, and `base`/`head` bare refs. `tea pulls list`
# returned an array whose values are all JSON strings. That run also
# CORRECTED one claim this header had made -- see the LIST note below on
# key names, which source reading had got wrong.
#
# WHAT REMAINS UNDER THE CEILING: the issue-side key names, the review-comment
# listing and resolve round trip, the `owner:` prefix on a cross-fork head,
# and every glab key. For those the stub still emits whatever its author
# believed, so a wrong key name passes green on both sides.
#
# THE THREE MAPPINGS THAT HAD TO BE DETERMINED RATHER THAN ASSUMED:
#
#   number -> index, NOT id. Both exist on pullData (`id` at cmd/pulls.go:30,
#     `index` at :31). `id` is the Gitea instance's globally unique row id;
#     `index` is the per-repository number the user sees in the PR URL and
#     types at the CLI -- the same id-vs-iid distinction GitLab has. Mapping
#     to `id` would yield a number that resolves to a DIFFERENT pull request.
#
#   files -> NOTHING, settled by absence rather than caution. tea exposes
#     `diff` and `patch` (PullFields, modules/print/pull.go:170-196) but both
#     resolve to x.DiffURL/x.PatchURL (:277-280) -- URLs, and the DETAIL
#     document's `diffUrl` likewise. There is no parsed per-file list in
#     either shape, so there is no key to name. Same answer, same grounds, as
#     _forge_map_pr_field_gitlab's own `files` branch above.
#
#   isDraft -> NOTHING. Gitea models a draft as a TITLE PREFIX, not a field:
#     `tea pulls create --draft` prepends "WIP: " to the title
#     (cmd/pulls/create.go:89-91, utils.AddDraftPrefix). pullData carries no
#     draft key and PullFields has no `draft` entry, so the CLI never
#     surfaces one to read back. Deriving it by string-matching a title
#     prefix would be a guess; reporting it in unsupported_fields is the
#     contract's answer for exactly this case.
#
# `state` names the KEY only, and the gitea VALUE vocabulary needs more than
# a table lookup -- see _forge_map_pr_state_gitea directly below, which is
# where `merged` is derived. This mapper answers `state` so the raw value
# still reaches _forge_pr_view_build_found; the merged derivation reads a
# DIFFERENT key (`hasMerged`) and so cannot live in a one-field-one-key
# table.
#
# THIS ONCE CONTRADICTED commands/references/forge-contract.md, AND NO LONGER
# DOES. That document used to state tea "does not expose a distinct `merged`
# value", that a merged PR "reads as `closed` under tea's own field list", and
# that an adapter "should normalize tea's `closed` straight through". All
# three are falsified by source: formatPRState (modules/print/pull.go:95-100)
# returns "merged" whenever pr.Merged != nil, and the DETAIL path carries
# `hasMerged`/`mergedAt` alongside the raw state (cmd/pulls.go:33,46,47). The
# correct behaviour was implemented here first and the ruling was deleted
# afterwards, so the contract's State Mapping section now describes this code
# rather than misdirecting the next adapter author away from it.
#
# Usage: _forge_map_pr_field_gitea <contract-field>
_forge_map_pr_field_gitea() {
  case "$1" in
    number)      printf 'index' ;;
    url)         printf 'url' ;;
    title)       printf 'title' ;;
    body)        printf 'body' ;;
    state)       printf 'state' ;;
    headRefName) printf 'head' ;;
    baseRefName) printf 'base' ;;
    # Deliberately EMPTY, not missing. The branch is kept so the three mappers
    # stay ten-for-ten diffable and a reader meets the omission at the line
    # they look at, rather than only in the header. `diff`/`patch`/`diffUrl`
    # are URLs, not a per-file list -- see the `files` note.
    files)       ;;
    # Deliberately EMPTY too: Gitea has no draft FIELD at all, only the
    # "WIP: " title prefix `--draft` writes. See the `isDraft` note.
    isDraft)     ;;
    mergeable)   printf 'mergeable' ;;
  esac
}

# Normalizes a `tea pulls <index> -o json` DETAIL document's state into the
# contract vocabulary, printing `merged` for a merged pull request.
#
# This is a SIBLING of _forge_map_pr_field_gitea rather than a branch inside
# it, because the merged answer reads a DIFFERENT key (`hasMerged`) than the
# `state` key, which a one-field-one-key table cannot express. It is also
# deliberately NOT a gitea arm of _forge_map_state: that function maps a raw
# VALUE and knows nothing about documents, and _forge_pr_view_build_found's
# own header promises its body stays forge-independent by construction. So
# the derivation lives here, in the adapter, and _forge_map_state stays
# gitea-free -- the same separation of "name the key" from "normalize the
# value" the build_found body already keeps (:4509-4514).
#
# has("hasMerged") rather than a bare index mirrors _forge_pr_view_build_found's
# own rule (:4474-4477): an absent key must not be collapsed with an explicit
# null, and neither may invent `merged`. A document that carries no hasMerged
# at all passes its raw state through untouched.
#
# Ceiling and source citations: see _forge_map_pr_field_gitea's header above.
# Usage: _forge_map_pr_state_gitea <detail-json>
_forge_map_pr_state_gitea() {
  local doc="${1:-}" merged raw

  merged=$(printf '%s' "$doc" | jq -r \
    'if has("hasMerged") then (.hasMerged | tostring) else "" end' 2>/dev/null) || merged=""
  if [ "$merged" = "true" ]; then
    printf 'merged'
    return 0
  fi

  raw=$(printf '%s' "$doc" | jq -r \
    'if has("state") then (.state | if . == null then "" else tostring end) else "" end' 2>/dev/null) || raw=""
  _forge_map_state gitea "$raw"
}

# THE ONE found-envelope construction, shared by every forge-pr-view adapter.
# Takes a forge label, the adapter's RAW response document, and the caller's
# requested contract-field list, and emits the finished
# {status:"found", pr, unsupported_fields, message:null} envelope.
#
# It exists so the three-way envelope is built once rather than copied per
# adapter. Everything below is forge-independent BY CONSTRUCTION: the only
# per-forge knowledge is the single _forge_map_pr_field_* lookup and the
# _forge_map_state forge label, both selected from $forge here. An adapter
# body therefore never re-derives the projection, the unsupported_fields
# intersection, or the null-vs-absent rule -- it fetches a document and hands
# it over.
#
# A CONTRACT FIELD THE MAPPER ANSWERS EMPTY FOR IS REPORTED ABSENT, NEVER
# GUESSED. The `[ -n "$native" ] || continue` below is that rule: on GitLab
# `files` maps to nothing (the document carries no changed-file list at all),
# so no flag reaches _forge_build_pr_json, which then marks `files` in
# unsupported_fields and leaves its value null. That is a reported absence,
# not an invented value.
#
# has() rather than a bare index keeps "the forge omitted this key entirely"
# (unsupported -- null AND named in unsupported_fields) distinguishable from
# "the forge returned this key with an explicit null" (supported -- null but
# NOT named), which a bare index collapses into one indistinguishable null.
#
# Usage: _forge_pr_view_build_found <forge> <raw-json-document> <fields-csv>
_forge_pr_view_build_found() {
  local forge="$1" doc="$2" fields_csv="$3"

  local -a requested=()
  local old_ifs="$IFS"
  IFS=','
  read -ra requested <<< "$fields_csv"
  IFS="$old_ifs"

  local -a builder_args=()
  local field native present raw_value
  for field in "${requested[@]}"; do
    case "$forge" in
      github) native=$(_forge_map_pr_field_github "$field") ;;
      gitlab) native=$(_forge_map_pr_field_gitlab "$field") ;;
      gitea)  native=$(_forge_map_pr_field_gitea "$field") ;;
      *)      native="" ;;
    esac
    [ -n "$native" ] || continue
    present=$(printf '%s' "$doc" | jq -r --arg k "$native" 'has($k)' 2>/dev/null) || present="false"
    [ "$present" = "true" ] || continue
    case "$field" in
      # Scalars reach the builder as strings. `if . == null` rather than
      # `// ""` deliberately: `//` also swallows a legitimate `false`, which
      # mergeable can genuinely carry on a forge that reports it as a boolean
      # rather than GitHub's MERGEABLE/CONFLICTING/UNKNOWN enum or GitLab's
      # detailed_merge_status enum.
      number|url|title|body|headRefName|baseRefName|mergeable)
        raw_value=$(printf '%s' "$doc" | jq -r --arg k "$native" '.[$k] | if . == null then "" else tostring end')
        ;;
      state)
        raw_value=$(printf '%s' "$doc" | jq -r --arg k "$native" '.[$k] | if . == null then "" else tostring end')
        # The KEY is what the mapper answered; the VALUE vocabulary is a
        # separate job -- this is where GitLab's "opened" becomes "open".
        raw_value=$(_forge_map_state "$forge" "$raw_value")
        ;;
      # JSON-valued fields reach the builder as raw JSON (--argjson on the
      # other side), so an explicit null stays the JSON literal `null`.
      files|isDraft)
        raw_value=$(printf '%s' "$doc" | jq -c --arg k "$native" '.[$k]')
        ;;
    esac
    case "$field" in
      number)      builder_args+=(--number "$raw_value") ;;
      url)         builder_args+=(--url "$raw_value") ;;
      title)       builder_args+=(--title "$raw_value") ;;
      body)        builder_args+=(--body "$raw_value") ;;
      state)       builder_args+=(--state "$raw_value") ;;
      headRefName) builder_args+=(--head-ref-name "$raw_value") ;;
      baseRefName) builder_args+=(--base-ref-name "$raw_value") ;;
      files)       builder_args+=(--files "$raw_value") ;;
      isDraft)     builder_args+=(--is-draft "$raw_value") ;;
      mergeable)   builder_args+=(--mergeable "$raw_value") ;;
    esac
  done

  local pr_full pr_json unsupported_json fields_json
  pr_full=$(_forge_build_pr_json ${builder_args[@]+"${builder_args[@]}"})
  fields_json=$(printf '%s' "$fields_csv" | jq -Rc 'split(",")')

  # Project the builder's fixed ten-key output down to exactly the keys this
  # caller asked for, in the order it asked for them -- the
  # never-pay-for-files-you-did-not-ask-for behavior this verb's --include
  # selector exists for. The builder's superset is never emitted.
  pr_json=$(printf '%s' "$pr_full" | jq -c --argjson keys "$fields_json" '
    . as $src | reduce $keys[] as $k ({}; . + {($k): $src[$k]})
  ')

  # ...and intersect the builder's own unsupported_fields with that same
  # requested list: the builder always flags an unpassed capability-gated
  # flag, but a field the caller never included is simply not part of this
  # answer and must not be reported as unsupported.
  unsupported_json=$(printf '%s' "$pr_full" | jq -c --argjson keys "$fields_json" '
    [.unsupported_fields[] | . as $f | select($keys | index($f))]
  ')

  _forge_pr_view_emit "found" "$pr_json" "$unsupported_json" ""
}

# github adapter for forge-pr-view. <ref> is a PR number or a branch name
# (already validated by cmd_forge_pr_view before this ever runs);
# <fields_csv> is the comma-joined list of NORMALIZED PR contract field
# names (caller's --include set, or the default cheap set) -- never gh's own
# vocabulary. Every crossing of that boundary goes through
# _forge_map_pr_field_github: contract name -> gh name on the way in (to
# build gh's --json list), gh name -> contract name on the way out (to pick
# the value out of gh's response). Captures gh's stdout and stderr on
# separate variables (this file runs under set -euo pipefail -- rc is
# pre-initialized and captured with `|| rc=$?`, mirroring
# roadmap.py's verify_creates_one capture pattern) so a legitimate non-zero gh
# exit never aborts the script.
_forge_pr_view_github() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more PRs -- i.e. existence is a confirmed structural fact, not an
  # inference. Consulted after gh pr view to keep a view failure from being
  # reinterpreted as not_found.
  local list_confirmed_exists=false

  # Translate the caller's contract field names to gh's own BEFORE the
  # --json field list is ever built, so gh never sees a name it does not
  # know and this adapter never assumes the two vocabularies agree.
  local -a requested=() gh_fields=()
  local old_ifs="$IFS"
  IFS=','
  read -ra requested <<< "$fields_csv"
  IFS="$old_ifs"

  local field gh_field
  for field in "${requested[@]}"; do
    gh_field=$(_forge_map_pr_field_github "$field")
    [ -n "$gh_field" ] && gh_fields+=("$gh_field")
  done

  local gh_fields_csv
  gh_fields_csv=$(IFS=','; printf '%s' "${gh_fields[*]:-}")

  # --- structural existence probe, FIRST for a branch ref ----------------
  # `gh pr list --head <branch> --json number` returns `[]` at exit 0 when no
  # PR exists -- a structural fact in JSON rather than a string in a message,
  # so it survives a gh release that rewords its own stderr or a non-English
  # locale. `--state all` so a closed/merged PR still counts as found (gh pr
  # list defaults to open-only, which would otherwise misreport a closed PR's
  # branch as not_found). `--head` takes a branch name, never a PR number, so
  # a NUMERIC ref skips this probe entirely and goes straight to gh pr view
  # plus the stderr tier below -- unchanged in both directions by this
  # reordering.
  #
  # WHY IT RUNS BEFORE gh pr view RATHER THAN AS ITS BACKSTOP: on the "no PR
  # yet" path -- the dominant case in aggregate, since execute.md's per-phase
  # idempotency pre-check runs this exact lookup on every phase close whether
  # or not a PR already exists -- asking view first meant paying a doomed
  # round trip and then paying the probe anyway to confirm what it meant. Two
  # calls to learn "no". Probing first answers that structurally in one, and
  # gh pr view is never invoked at all.
  #
  # The accepted, deliberate trade-off: a FOUND branch-ref lookup now costs
  # two calls (probe, then view for the actual fields) where it used to cost
  # one. That is the price of making absence cheap, and absence is the common
  # case.
  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count=""
    list_out=$(gh pr list --head "$ref" --state all --json number 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      list_count=$(printf '%s' "$list_out" | jq 'length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the same view-plus-stderr
      # path a failed probe takes.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- gh pr view "$ref" --json "$gh_fields_csv" || true

  if [ "$rc" -eq 0 ]; then
    # Normalize gh's raw response through the ONE shared found-envelope
    # builder rather than re-subsetting gh's own JSON here: state is
    # case-folded through the same _forge_map_state call forge-issue-view
    # applies, every capability-gated field is flagged by the builder's own
    # presence rule, and the projection/intersection logic is the same code
    # the gitlab adapter runs.
    _forge_pr_view_build_found "github" "$stdout" "$fields_csv"
    return 0
  fi

  # --- not_found detection ---------------------------------------------
  # THE THREE-WAY STATUS MUST SURVIVE THE REORDER. The probe already said
  # this PR exists, structurally; gh pr view then failed anyway (a transient
  # error, or a race between the two calls). That is a tool failure and
  # nothing else -- reporting not_found here would take the one case where
  # absence has been positively DISPROVEN and report it as absence, which is
  # precisely the conflation this verb exists to prevent. The stderr-text
  # tier below is skipped too: gh pr view's own wording cannot outvote a
  # structural fact, not even when it happens to say "no pull requests
  # found".
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback: gh's own no-pull-requests-found wording. Kept
  # strictly as a backstop for when the structural probe above could not
  # confirm anything (a numeric ref, or the list probe itself failing) --
  # never the primary signal, since a translatable/rewordable string is
  # exactly the fragility this verb exists to avoid.
  if printf '%s' "$stderr" | grep -qi "no pull requests\? found"; then
    _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. evidence carries
  # gh's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# gitlab adapter for forge-pr-view. Same signature and same three outcomes as
# _forge_pr_view_github above, and the two are deliberately kept adjacent and
# structurally parallel so a reader can diff them: probe, view, classify.
#
# THE ONE ASYMMETRY THAT MATTERS, AND THE SINGLE MOST LIKELY WAY TO GET THIS
# ADAPTER WRONG: gh has a `--json <field-list>` SELECTOR, so the github
# adapter above translates the caller's contract fields into gh's vocabulary
# and asks gh for exactly those. glab has NO such selector on any read
# command. Its entire output interface is
#   -F, --output string   Format output as: text, json. (default "text")
#       --jq string       Filter JSON output with a jq expression.
# (docs/source/mr/view.md), and internal/commands/mr/view/mr_view.go's JSON
# path is literally `return opts.io.PrintJSON(mr)` over a
# *gitlab.MergeRequest -- the WHOLE marshalled document, every time.
# Passing a field list to glab as if it were gh would hand it an argument it
# does not define. So this adapter asks for `-F json` and PICKS keys out of
# the returned document afterwards, via _forge_map_pr_field_gitlab. There is
# no per-field cost to save on the request side, so no field list is built.
#
# not_found IS DETECTED STRUCTURALLY FIRST, exactly like the github arm:
# `glab mr list --source-branch <branch> --all -F json` returns `[]` at exit 0
# when no merge request exists for that branch -- a fact in JSON rather than a
# string in a message, so it survives a glab release that rewords its own
# stderr or a non-English locale. `--all` because `glab mr list` defaults to
# opened-only, which would otherwise misreport a merged MR's branch as absent.
# `--source-branch` takes a branch name, never an MR IID, so a NUMERIC ref
# skips the probe entirely -- identical to `--head`'s role above.
#
# CONFLATING not_found WITH error IS THE DEFECT THIS VERB EXISTS TO PREVENT,
# and that holds on GitLab too: when the probe positively CONFIRMED the MR
# exists and `glab mr view` then failed anyway, this reports error, never
# not_found, and does not consult stderr wording at all -- a string cannot
# outvote a structural fact.
#
# VERIFICATION CEILING: glab is not installed on the machine this was written
# on; every flag and key above is read off glab's own docs and source, never
# observed coming out of the real binary. Same declared ceiling as
# _forge_map_pr_field_gitlab's header.
_forge_pr_view_gitlab() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more merge requests -- i.e. existence is a confirmed structural fact, not
  # an inference.
  local list_confirmed_exists=false

  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count=""
    list_out=$(glab mr list --source-branch "$ref" --all -F json 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      list_count=$(printf '%s' "$list_out" | jq 'length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no merge request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the view-plus-stderr path.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- glab mr view "$ref" -F json || true

  if [ "$rc" -eq 0 ]; then
    # The SAME found-envelope builder the github arm calls, differing only in
    # the forge label -- which is what selects _forge_map_pr_field_gitlab for
    # the key lookup and the gitlab arm of _forge_map_state for the value.
    # `files` is the field that mapper answers empty for, so it comes back
    # null AND named in unsupported_fields: reported absent, never guessed.
    _forge_pr_view_build_found "gitlab" "$stdout" "$fields_csv"
    return 0
  fi

  # A structurally CONFIRMED existence outranks any stderr text, including
  # text that happens to say 404. See the header.
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback only: glab surfaces a missing merge request as the
  # API's own 404. Kept strictly as a backstop for when the structural probe
  # could not confirm anything (a numeric ref, or the probe itself failing),
  # never as the primary signal.
  if printf '%s' "$stderr" | grep -qiE '404|not found'; then
    _forge_pr_view_emit "not_found" "null" "null" "no merge request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. The message carries
  # glab's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# gitea adapter for forge-pr-view. Same signature and same three outcomes as
# the github and gitlab arms above, and all three are deliberately kept
# adjacent and structurally parallel so a reader can diff them: probe, view,
# classify.
#
# TWO ASYMMETRIES MAKE `tea` NOT `glab`, AND CARRYING THE GITLAB SHAPE OVER
# BY HABIT IS THE SINGLE MOST LIKELY WAY TO GET THIS ADAPTER WRONG.
#
# (a) `tea` HAS a field selector. `--fields, -f` is a CSV flag over a fixed
# allowlist (cmd/flags/generic.go:157). _forge_pr_view_gitlab fetches the
# whole document and picks keys afterwards ONLY because glab has no selector
# at all; that is not a house style to copy. So the LIST probe below asks for
# exactly the two fields it consumes. But the selector does NOT extend to the
# detail path: `tea pulls <index> -o json` emits a fixed `pullData`
# projection (cmd/pulls.go:29-52, routed at :88-93), so no `-f` belongs on
# that invocation either -- and a gh-style `--json <field-list>` belongs on
# neither, because `tea` defines no such flag anywhere.
#
# (b) `tea` emits TWO DIFFERENT JSON SHAPES for the same resource, chosen by
# whether an index argument was passed. This has no gh or glab analogue.
#   DETAIL -- `tea pulls <index> -o json`: ONE OBJECT with TYPED values
#     (index is a number, mergeable/hasMerged are real booleans), head/base
#     are BARE refs (cmd/pulls.go:174-177).
#   LIST -- `tea pulls list -o json -f <csv>`: a JSON ARRAY whose keys are
#     the --fields names VERBATIM -- NOT snake-cased; see
#     _forge_map_pr_field_gitea's header for the measurement that corrected
#     this -- and whose values are ALWAYS STRINGS
#     (modules/print/table.go:175-208), and whose `head` may carry an
#     `owner:` prefix for a cross-fork pull request (formatPRHead,
#     modules/print/pull.go:83-93).
# This function uses DETAIL for the found path and LIST for the structural
# probe, and must never mix their assumptions.
#
# not_found IS ESTABLISHED STRUCTURALLY, exactly like the two arms above,
# and it has to be: `tea` exits 1 UNIFORMLY for every error (main.go:18-30)
# with no distinct "not found" code at all -- the precise conflation this
# verb exists to defeat. But the probe is HARDER here than on either other
# forge, because `tea pulls list` has NO head/source-branch filter
# (cmd/pulls/list.go:31 carries only --fields plus --state/--page/--limit).
# So the listing is fetched with `--state all` -- a merged or closed pull
# request must still count as found -- and filtered LOCALLY. The local
# comparison is on the SUFFIX after the last `:`, never plain equality: a
# cross-fork row spells its head `contributor:feat-x`, and reporting that as
# absent would invite a duplicate pull request. Git refs cannot contain `:`,
# so the split is unambiguous.
#
# THE PROBE ALSO RESOLVES THE INDEX. `tea pulls <arg>` takes an INDEX, never
# a branch name, so a branch ref could not address the detail call at all
# without this step -- which is why the probe selects `index` alongside
# `head`. A purely numeric ref addresses the pull request directly and skips
# the probe entirely, the same way `--head`/`--source-branch` are skipped
# above.
#
# CONFLATING not_found WITH error IS THE DEFECT THIS VERB EXISTS TO PREVENT:
# when the probe positively CONFIRMED the pull request exists and the detail
# call then failed anyway, this reports error and does not consult stderr
# wording at all -- not even when that wording happens to say 404. A string
# cannot outvote a structural fact.
#
# NO CREDENTIAL IS BOUND ON ANY INVOCATION HERE. `tea` honours GH_TOKEN when
# GITEA_INSTANCE_URL is also set (modules/context/context_login.go:15-51), so
# a prefix assignment copied from the GitHub write path would hand a GitHub
# token to a Gitea instance.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. The tests prove WHICH ARGV this function emits and
# HOW it parses a fixture -- never what real `tea` does with them. Same
# declared ceiling _forge_map_pr_field_gitea's header states.
_forge_pr_view_gitea() {
  local ref="$1" fields_csv="$2"
  local stdout="" stderr="" rc=0
  # Set only when the structural probe below ran cleanly AND reported one or
  # more matching pull requests -- i.e. existence is a confirmed structural
  # fact, not an inference.
  local list_confirmed_exists=false
  # The argument the DETAIL call is addressed with. A numeric ref is already
  # an index; a branch ref becomes one only if the probe resolves it.
  local detail_ref="$ref"

  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    local list_out="" list_rc=0 list_count="" list_index=""
    list_out=$(tea pulls list --state all -f index,head -o json 2>/dev/null) || list_rc=$?
    if [ "$list_rc" -eq 0 ]; then
      # The local head filter, in the LIST vocabulary: every value is a
      # string, and `head` may be `owner:branch`. `sub("^.*:"; "")` is greedy
      # and therefore strips through the LAST colon, leaving a bare ref
      # untouched when there is none.
      list_count=$(printf '%s' "$list_out" | jq --arg ref "$ref" '
        [ .[]
          | select(type == "object")
          | select((((.head // "") | tostring) | sub("^.*:"; "")) == $ref) ] | length' 2>/dev/null) || list_count=""
      if [ "$list_count" = "0" ]; then
        _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
        return 0
      fi
      # A parseable, non-zero count is a confirmed existence fact. An
      # UNPARSEABLE response is not: it proves nothing either way, so it
      # leaves the flag false and falls through to the same detail-plus-
      # stderr path a failed probe takes.
      if [ -n "$list_count" ]; then
        list_confirmed_exists=true
        list_index=$(printf '%s' "$list_out" | jq -r --arg ref "$ref" '
          [ .[]
            | select(type == "object")
            | select((((.head // "") | tostring) | sub("^.*:"; "")) == $ref) ][0].index // "" | tostring' 2>/dev/null) || list_index=""
        [ -n "$list_index" ] && detail_ref="$list_index"
      fi
    fi
  fi

  _forge_capture stdout stderr rc -- tea pulls "$detail_ref" -o json || true

  if [ "$rc" -eq 0 ]; then
    # `merged` is DERIVED here, in the adapter, and nowhere else in this
    # file. tea's DETAIL `state` is `pr.State` raw -- open/closed only
    # (cmd/pulls.go:33) -- while merged-ness lives in the separate
    # `hasMerged` boolean (:46). Reading a second key is exactly what a
    # one-field-one-key mapper cannot express, which is why
    # _forge_map_pr_state_gitea is a sibling of the mapper rather than a
    # branch inside it, and why _forge_map_state stays gitea-free: that
    # function normalizes SPELLING and must not invent a value the source
    # data did not provide. The rewritten document is then handed to the ONE
    # shared found-envelope builder, which does the key lookup through
    # _forge_map_pr_field_gitea -- this arm builds no key table of its own.
    local state_norm normalized
    state_norm=$(_forge_map_pr_state_gitea "$stdout")
    normalized=$(printf '%s' "$stdout" | jq -c --arg state "$state_norm" '
      if (type == "object" and has("state")) then .state = $state else . end' 2>/dev/null) || normalized="$stdout"
    [ -n "$normalized" ] || normalized="$stdout"
    _forge_pr_view_build_found "gitea" "$normalized" "$fields_csv"
    return 0
  fi

  # A structurally CONFIRMED existence outranks any stderr text, including
  # text that happens to say 404. See the header.
  if [ "$list_confirmed_exists" = true ]; then
    _forge_pr_view_emit "error" "null" "null" "$stderr"
    return 0
  fi

  # Secondary fallback only, for when the structural probe could not confirm
  # anything (a numeric ref, or the probe itself failing). `tea` has no
  # not-found exit code, so this reads its prose -- which is exactly the
  # fragility the probe above exists to avoid, hence backstop-only.
  if printf '%s' "$stderr" | grep -qiE '404|not found'; then
    _forge_pr_view_emit "not_found" "null" "null" "no pull request found for ref: $ref"
    return 0
  fi

  # Every other non-zero exit is a genuine tool failure (auth, network,
  # malformed response) -- never folded into not_found. The message carries
  # tea's own stderr text.
  _forge_pr_view_emit "error" "null" "null" "$stderr"
  return 0
}

# Field-selectable, three-way-status PR lookup. See this section's header
# comment for the defect this fixes and why its envelope differs from the
# generic forge-contract.md three-way envelope.
# Usage: aimi-cli.sh forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]
# --include is a comma-separated subset of the TEN normalized PR contract
# fields (forge-contract.md's "Normalized PR Field Set"): number, url,
# title, body, state, headRefName, baseRefName, files, isDraft, mergeable.
# Defaults to the portable core (number,url,title,body,state,headRefName,
# baseRefName) when omitted -- the three capability-gated fields (files,
# isDraft, mergeable) stay opt-in-only so a caller that only wants url never
# triggers the more expensive per-file lookup.
#
# gh-only names with no PR-contract equivalent (reviews, comments) are NOT
# accepted here: this selector runs on the contract's vocabulary, not gh's,
# and a name the contract cannot express would have no meaning on a later
# gitlab/gitea adapter. A verb needing per-reviewer detail consumes the
# forge-native object instead (forge-contract.md's Review/Approval Envelope
# section says so explicitly).
cmd_forge_pr_view() {
  check_jq

  local pr_ref="" include_raw="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)      shift; pr_ref="${1:-}" ;;
      --include) shift; include_raw="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-view: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$pr_ref" ]; then
    echo "Usage: aimi-cli.sh forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]" >&2
    exit 1
  fi

  # Validate --pr before it is ever interpolated into a gh invocation:
  # digits-only (a PR number) or the repo-wide branch-name regex.
  if ! [[ "$pr_ref" =~ ^[0-9]+$ ]] && ! [[ "$pr_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-view: invalid --pr value: $pr_ref" >&2
    exit 1
  fi

  # --include: comma-separated field list (IFS=',' split, matching the
  # decoration-token split at aimi-cli.sh:1727). An unrecognized field name
  # is CLI misuse (exit 1) -- never folded into the substantive result.
  local -a requested_fields=()
  if [ -n "$include_raw" ]; then
    local old_ifs="$IFS"
    IFS=','
    read -ra requested_fields <<< "$include_raw"
    IFS="$old_ifs"
  else
    requested_fields=(number url title body state headRefName baseRefName)
  fi

  local field known
  for field in "${requested_fields[@]}"; do
    known=false
    case "$field" in
      number|url|title|body|state|headRefName|baseRefName|files|isDraft|mergeable) known=true ;;
    esac
    if [ "$known" = false ]; then
      echo "Error: forge-pr-view: unknown --include field: $field" >&2
      exit 1
    fi
  done

  local fields_csv
  fields_csv=$(IFS=','; echo "${requested_fields[*]}")

  local forge=""
  _detect_forge_type forge

  # Each arm gates on the binary THAT forge needs -- gh for github, glab for
  # gitlab, tea for gitea -- through the shared _forge_bin_check in its quiet
  # mode, and its degraded message names that same binary. A GitLab user is
  # never told to install gh, and neither is a Gitea one. The `*)` arm is
  # still reachable, by `unknown`.
  case "$forge" in
    github)
      if _forge_bin_check gh quiet github; then
        _forge_pr_view_github "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "gh not found on PATH -- this github operation cannot run automatically."
      fi
      ;;
    gitlab)
      if _forge_bin_check glab quiet gitlab; then
        _forge_pr_view_gitlab "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "glab not found on PATH -- this gitlab operation cannot run automatically."
      fi
      ;;
    gitea)
      if _forge_bin_check tea quiet gitea; then
        _forge_pr_view_gitea "$pr_ref" "$fields_csv"
      else
        _forge_pr_view_emit "error" "null" "null" "tea not found on PATH -- this gitea operation cannot run automatically."
      fi
      ;;
    *)
      _forge_pr_view_emit "error" "null" "null" "no forge-pr-view adapter for the '$forge' forge yet."
      ;;
  esac
}

# ============================================================================
# forge-pr-create / forge-pr-edit (US-005)
# ============================================================================
# The first WRITE verbs in this phase that create/mutate a pull request.
# Built entirely on US-001's detect-forge, US-002's shared degradation gate
# (_forge_bin_check), and US-004's forge-pr-view -- called here as an
# in-process function, never a `$AIMI_CLI forge-pr-view` subprocess -- for
# both the idempotency check and the post-create structured re-read. Neither
# helper below re-derives detect-forge or forge-pr-view's own lookup logic.
#
# THE DEFECT THIS PAIR EXISTS TO FIX: commands/open-pr.md's `gh pr create`
# call (open-pr.md:355) does not capture its own output, so PR_URL/PR_BODY
# (read later at :465/:479) are assigned by no block in that file --
# grandfathered in scripts/command-blocks-baseline.txt as "read but never
# assigned". forge-pr-create emits forge-contract.md's write-verb envelope
# ({status, data: {url, number}, message}) as compact JSON so a caller in an
# isolated Bash block can capture the created PR's identity by plain
# assignment. Rewriting open-pr.md itself is story 08's job, not this one --
# this section only makes the value available.
#
# EXIT CONTRACT DIFFERS FROM forge-issue-create ON PURPOSE: forge-issue-
# create is a soft-fail verb (exit always 0, caller branches on `status`)
# because a failed backend issue must never block PR creation. Opening or
# editing the PR itself has no such fallback -- execute.md's per-repository
# PR-creation step needs a real non-zero exit so its own per-repository
# failure isolation (report that repository's failure verbatim, move on to
# the next repository) keeps working once it migrates onto this verb. Both
# functions below NEVER retry, NEVER prompt interactively, and NEVER mutate
# any phase/story completed status -- only the caller does that, and only
# after observing the non-zero exit.
#
# IDENTITY: exactly like forge-issue-create, neither cmd_forge_pr_create nor
# cmd_forge_pr_edit accepts a --token (or similarly credential-shaped) flag.
# Any acting-account identity (e.g. AIMI_FORGE_IDENTITY, or a GH_TOKEN a
# caller exported before invoking this CLI) reaches the child gh process
# purely by environment-variable inheritance -- no extra code is needed here
# to pass it along, and neither function ever echoes or logs one verbatim.
# Phase 2's per-repository account selection built on that signature without
# retrofitting it: both functions below now resolve _forge_account_override
# once and apply it as a bash PREFIX ASSIGNMENT on each gh write and on the
# forge-pr-view reads made as part of the same operation. See the ROUTING
# RULE block above the forge-auth-status section for the full statement.

# Prints the MANDATORY manual-fallback instructions (forge-contract.md's
# Degradation Contract, mandatory mode) for every forge-pr-create/forge-pr-
# edit failure path -- an unsupported forge, a missing gh binary, or the gh
# call itself failing all funnel through this one function so the wording
# is identical regardless of WHY automatic create/edit did not happen.
# Always stderr, never stdout, so a caller consuming this verb's JSON result
# on stdout never has to filter prose out of its own data.
#
# mode: create | edit.
#   create -- prints the git push command plus a manual `gh pr create`
#             invocation (AC6's "the git push command"), and, when
#             forge-repo-info can resolve owner/repo (its own local-parse
#             fallback needs only the git remote, not gh -- see US-003),
#             the compare URL a human can open directly (AC6's "the
#             compare-URL ... command").
#   edit   -- prints a manual `gh pr edit` invocation and, when resolvable,
#             the PR's own URL (AC6's "... or edit command").
# repo-info is queried in-process (a direct function call, never a
# subprocess) and is itself best-effort here: when it cannot resolve
# owner/repo (no adapter, gh absent, no origin), the URL line is simply
# omitted rather than guessing a wrong one.
#
# THE EDIT ARMS PRINT ONLY THE FLAGS THE CALLER ACTUALLY SUPPLIED, and that
# is a correctness matter rather than tidiness. forge-pr-edit's --title and
# --body are each independently optional, and each adapter emits only the
# one it was given -- so a printed command that named both would talk a
# human into running `--body ""` on a title-only edit and blanking the very
# description the automatic path was careful not to touch. The two
# provided-ness signals are read differently for the same reason they are
# tracked differently upstream: $title is trusted as its own signal because
# cmd_forge_pr_edit refuses `--title ""` outright, so a non-empty $title and
# "the caller passed --title" are the same fact; $body needs the explicit
# $body_provided, because `--body ""` is a legitimate deliberate clear that
# must still print. CREATE mode always carries a body, which is why
# $body_provided defaults to 1 -- every create call site passes six
# arguments and is unaffected by this parameter existing.
#
# THE DEFAULT IS `${7-1}` AND NOT `${7:-1}`, WHICH IS THE WHOLE MECHANISM.
# The edit call sites forward $body_provided positionally, and its "no
# --body was passed" value IS the empty string -- so a `:-` default would
# read every title-only edit as "body provided" and print the `--body ...`
# line this parameter exists to suppress. Only the colon-less form
# distinguishes "the caller passed nothing" (create, six arguments) from
# "the caller passed empty" (a title-only edit, seven).
_forge_pr_write_print_manual() {
  local mode="$1" forge="$2" base="$3" head_or_number="$4" body="$5" title="${6:-}" body_provided="${7-1}"
  local edit_cmd=""

  local repo_info="" owner="" repo="" host=""
  repo_info=$(_forge_repo_info 2>/dev/null) || repo_info=""
  if [ -n "$repo_info" ] && [ "$(printf '%s' "$repo_info" | jq -r '.status' 2>/dev/null)" = "found" ]; then
    owner=$(printf '%s' "$repo_info" | jq -r '.data.owner // empty')
    repo=$(printf '%s' "$repo_info" | jq -r '.data.repo // empty')
    host=$(printf '%s' "$repo_info" | jq -r '.data.host // empty')
  fi
  if [ -z "$host" ]; then
    # Per-forge default rather than a single github.com constant: on a GitLab
    # repository whose host could not be resolved, printing a github.com URL
    # would be actively misleading rather than merely unhelpful. The same
    # applies to Gitea/Forgejo -- gitea.com is Gitea's own SaaS host, and
    # falling through to github.com here was a live wrong-output bug for every
    # Gitea remote whose host could not be resolved, not a cosmetic default.
    case "$forge" in
      gitlab) host="gitlab.com" ;;
      gitea)  host="gitea.com" ;;
      *)      host="github.com" ;;
    esac
  fi

  {
    if [ "$forge" = "gitlab" ]; then
      # GitLab arm. Three things differ from the github arm below and every
      # one of them is a correctness matter, not a cosmetic one:
      #   - the noun is "merge request", not "pull request";
      #   - the CLI is glab, and the invocation printed here CARRIES -y for
      #     the same reason the automatic one does (see the GitLab write
      #     adapters section) -- a human who copy-pastes this line into an
      #     unattended script must not inherit the hang;
      #   - GitLab's web paths are /-/merge_requests/... , and the "open a new
      #     MR" form is a query-string on /-/merge_requests/new rather than
      #     GitHub's /compare/base...head?expand=1.
      if [ "$mode" = "create" ]; then
        echo "Warning: could not create this gitlab merge request automatically -- create it yourself with:"
        echo "  git push -u origin $head_or_number"
        echo "  glab mr create -y --title \"$title\" --source-branch $head_or_number --target-branch $base --description ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/-/merge_requests/new?merge_request%5Bsource_branch%5D=$head_or_number&merge_request%5Btarget_branch%5D=$base"
        fi
      else
        echo "Warning: could not edit this gitlab merge request automatically -- edit it yourself with:"
        edit_cmd="  glab mr update $head_or_number -y"
        if [ -n "$title" ]; then edit_cmd="$edit_cmd -t \"$title\""; fi
        if [ -n "$body_provided" ]; then edit_cmd="$edit_cmd --description ..."; fi
        echo "$edit_cmd"
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/-/merge_requests/$head_or_number"
        fi
      fi
    elif [ "$forge" = "gitea" ]; then
      # Gitea/Forgejo arm. THE NOUN STAYS "pull request" -- do NOT "fix" this
      # into merge-request wording by symmetry with the gitlab arm above.
      # Gitea calls them pull requests, exactly like GitHub; only GitLab says
      # merge request. Three things do differ from the github arm below, and
      # every one of them is a correctness matter:
      #   - the CLI is tea, and its flag names are tea's own: -t/--title and
      #     -d/--description, never gh's --body, plus --head in its LONG FORM
      #     ONLY (tea gives it no short alias, and -h is urfave/cli's help
      #     flag) and -b/--base. See the Gitea write adapters section header.
      #   - Gitea's compare form is /<owner>/<repo>/compare/<base>...<head>
      #     with no ?expand=1 -- that query parameter is GitHub's.
      #   - Gitea's pull-request path is /<owner>/<repo>/pulls/<number>, with
      #     an "s". GitHub's singular /pull/<number> 404s on a Gitea instance.
      if [ "$mode" = "create" ]; then
        echo "Warning: could not create this gitea pull request automatically -- create it yourself with:"
        echo "  git push -u origin $head_or_number"
        echo "  tea pulls create -t \"$title\" --head $head_or_number -b $base -d ..."
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/compare/$base...$head_or_number"
        fi
      else
        echo "Warning: could not edit this gitea pull request automatically -- edit it yourself with:"
        edit_cmd="  tea pulls edit $head_or_number"
        if [ -n "$title" ]; then edit_cmd="$edit_cmd -t \"$title\""; fi
        if [ -n "$body_provided" ]; then edit_cmd="$edit_cmd -d ..."; fi
        echo "$edit_cmd"
        if [ -n "$owner" ] && [ -n "$repo" ]; then
          echo "  Or open: https://$host/$owner/$repo/pulls/$head_or_number"
        fi
      fi
    elif [ "$mode" = "create" ]; then
      echo "Warning: could not create this $forge pull request automatically -- create it yourself with:"
      echo "  git push -u origin $head_or_number"
      echo "  gh pr create --title \"$title\" --base $base --head $head_or_number --body ..."
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/compare/$base...$head_or_number?expand=1"
      fi
    else
      echo "Warning: could not edit this $forge pull request automatically -- edit it yourself with:"
      edit_cmd="  gh pr edit $head_or_number"
      if [ -n "$title" ]; then edit_cmd="$edit_cmd --title \"$title\""; fi
      if [ -n "$body_provided" ]; then edit_cmd="$edit_cmd --body ..."; fi
      echo "$edit_cmd"
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/pull/$head_or_number"
      fi
    fi
    # Withheld on a title-only edit for the same reason the --body flag is:
    # there is no body to reproduce, and printing an empty block under a
    # "Body:" heading reads as "the body was blanked" to the one reader this
    # output exists for.
    if [ -n "$body_provided" ]; then
      echo "  Body:"
      printf '%s\n' "$body" | sed 's/^/    /'
    fi
  } >&2
}

# ============================================================================
# GitLab write adapters — forge-pr-create, forge-pr-edit, forge-issue-create
# ============================================================================
# The gitlab arms of this file's THREE write verbs, kept together in one
# section rather than scattered into each verb's body so the one rule they
# all obey is stated once and is impossible to read past.
#
# THE RULE: EVERY glab WRITE INVOCATION CARRIES -y (--yes). NO EXCEPTIONS.
#
# `glab mr create`, `glab mr update` and `glab issue create` each PROMPT for
# a submission confirmation unless -y is passed (glab's own flag help:
# "Skip submission confirmation prompt" on mr create, "Skip confirmation
# prompt" on mr update, "Don't prompt for confirmation to submit the issue"
# on issue create). `gh pr create` has no such flag and needs none, so the
# habit carried over from the github adapter next door does NOT produce an
# error here -- it produces a HANG, forever, with no output explaining why,
# in an autonomous run with nobody present to answer. A hang is the single
# hardest failure in this system to diagnose, which is why -y is written
# FIRST on every invocation below, immediately after the subcommand, where
# a reviewer meets it before any other flag.
#
# GLAB'S FLAG NAMES ARE NOT gh'S. Verified against glab's own published
# command reference (docs/source/mr/create.md, docs/source/mr/update.md,
# docs/source/issue/create.md):
#   -t/--title           (same spelling as gh)
#   -d/--description     NOT --body
#   -s/--source-branch   NOT --head
#   -b/--target-branch   NOT --base
#   -y/--yes             no gh equivalent at all
# `glab mr update` takes the merge request as a POSITIONAL argument
# ([<id> | <branch>]) and accepts no --source-branch/--target-branch pair.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY BEHAVIOR BELOW. glab was
# NOT installed on the machine this was written on; that is this phase's
# declared ceiling, not an oversight. Not one invocation here has been
# observed against the real binary. Flag names and prompt behavior come from
# glab's published command reference; the tests drive a fake glab that
# records its argv, so what is actually PROVEN here is which flags this file
# emits -- never what the real binary does with them.
#
# ACCOUNT-OVERRIDE LANDING SITE -- RESOLVED: IT STAYS EMPTY, AND HERE IS WHY.
# The landing site the paragraph below describes was left for a later story
# whose central question -- how glab accepts a per-invocation token, and
# whether it can at all -- was deliberately left open at planning time. That
# question has now been answered, and the answer is no. One line, the whole
# reason:
#
#   glab has no per-account token retrieval: there is no `glab auth token` subcommand at all, and its credential store is keyed by HOST alone (`token`, Scope: ScopePerHost), so there is no per-account token for this file to ask glab for.
#
# EVIDENCE (glab source, gitlab-org/cli @ main, read 2026-08-05 -- glab is
# not installed on this machine, this phase's declared verification ceiling,
# so this is read off the source rather than off an observed binary):
#
#   1. internal/commands/auth/ holds exactly `login`, `logout`, `status`,
#      `credentialhelper`, `docker` and `generate`. There is no `token`
#      subcommand, so `gh auth token --user <login> --hostname <host>` --
#      the ONE call _forge_account_override is built on -- has no glab
#      counterpart to be rewritten into.
#   2. There is no per-account model for such a subcommand to address even
#      if it existed. internal/config/schema.go declares the `token` key as
#      `Scope: ScopePerHost` -- one token per instance -- and
#      internal/commands/auth/status/status.go iterates `cfg.Hosts()` and
#      reads `cfg.GetWithSource(instance, "token", true)`: instances, never
#      logins. `glab auth status --show-token --hostname <host>` therefore
#      returns that host's single token, not a named account's, which is why
#      it is not a workaround either.
#   3. The two remaining subcommands are not a back door: `auth generate` is
#      DPoP proof generation and `auth credentialhelper` is a git credential
#      helper. Neither retrieves a token for a named account.
#
# THIS IS NOT THE HOST-DEPENDENCE PROBLEM, which is worth saying because it
# is the first thing a reader will suspect after the
# GH_TOKEN/GH_ENTERPRISE_TOKEN split next door. glab's token environment
# variables are GITLAB_TOKEN, GITLAB_ACCESS_TOKEN and OAUTH_TOKEN
# (internal/config/schema.go), and EnvKeyEquivalence() -- the function that
# resolves them (internal/config/config_mapping.go) -- takes a config KEY and
# no hostname at all. The same three names therefore apply to gitlab.com and
# to every self-managed instance alike, so there is no GHES-style silent
# mis-attribution to guard against here. The blocker is the missing
# retrieval, not the variable name.
#
# SO THIS PATH DEGRADES, DELIBERATELY: every glab invocation below runs as
# the machine's ACTIVE glab session, exactly as if no account had ever been
# recorded for this repository. Nothing here reads the account store and
# nothing here sets, blanks or exports a token variable -- which is also what
# preserves the one selection mechanism glab does have: an operator who
# exported GITLAB_TOKEN before invoking this CLI still picks the acting
# account, because glab reads that variable itself and this file leaves it
# untouched on its way to the child process.
#
# IF GLAB EVER GAINS PER-ACCOUNT RETRIEVAL, the landing site is still here
# and still costs nothing: every glab invocation below is a SINGLE
# `_forge_capture ... -- glab ...` statement on its own line, so a bash
# PREFIX ASSIGNMENT can be added on the line directly above it --
#
#     GITLAB_TOKEN="$gitlab_token_override" \
#       _forge_capture stdout stderr_out rc -- glab mr create -y ... || true
#
# exactly the shape phase 2 used for GH_TOKEN/GH_ENTERPRISE_TOKEN on the gh
# side. `export` stays forbidden for the same reason it is on the gh side --
# a process-wide token changes what every later auth/identity probe in the
# same process reports, starting with _forge_auth_status_gitlab, whose
# `Logged in to <host> as <username>` parse would then report the overridden
# account as the machine's active one and make the very before/after check
# that proves the machine account was left alone unable to detect anything.
#
# SAME-ACCOUNT INVARIANT: the idempotency check that decides created vs
# unchanged, the write itself, and the post-write re-read are all part of ONE
# operation and must run as ONE account. On a private project the creating
# account can see a merge request its reader account cannot, so a check
# performed as a different account would fail against an MR that was just
# successfully created. Degrading to the active session satisfies that
# invariant for free -- one session, every call -- and it is also why a
# future override would have to be put on EVERY glab call in a given
# function, not only on the one that writes.

# Extracts the merge-request/issue URL from a glab write command's stdout.
#
# Deliberately NOT `tail -n1`, which is what the gh side does. gh pr create
# and gh issue create print the bare URL and nothing else; glab's write
# commands print a short human-readable confirmation around theirs, so the
# URL is not reliably the last line. Scanning for the last http(s) token is
# tolerant of that framing without depending on its exact wording.
#
# Prints the empty string when no URL is present -- callers treat that as a
# degraded outcome rather than guessing one.
# Usage: _forge_glab_write_url <captured-stdout>
_forge_glab_write_url() {
  local out="${1:-}" url=""
  url=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'https?://[^[:space:]]+' | tail -n1) || url=""
  printf '%s' "$url"
}

# gitlab adapter for forge-pr-create. Same contract as the github arm in
# _forge_pr_create: shared write envelope, MANDATORY-PRINT degradation,
# non-zero exit on every degraded branch, never retries, never prompts.
#
# IDEMPOTENCY differs from the github arm in ONE way, and the difference is
# forced rather than chosen. gh has `gh pr list --head <branch> --json number`,
# a structural existence probe that answers "no PR" as `[]` at exit 0, so the
# github arm can treat a FAILED lookup as a hard error and refuse to create.
# glab's equivalent read, `glab mr view <branch> -F json`, exits NON-ZERO both
# when the merge request does not exist and when the lookup itself fails, and
# the two are distinguishable only by matching its stderr prose -- exactly the
# fragility forge-pr-view's own not_found detection was made structural to
# avoid. So a failed lookup here falls through to creation instead of
# degrading. That direction is safe on GitLab specifically: GitLab refuses to
# open a second open merge request for the same source/target branch pair, so
# the worst case of guessing wrong is a loud failure from `glab mr create`,
# not a duplicate merge request. Do not "fix" this into a stderr match.
_forge_pr_create_gitlab() {
  local title="$1" base="$2" head="$3" body="$4"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "glab not found -- this merge request was not created automatically."
    return 1
  fi

  # Existing-MR check, as the same account the create below will run as.
  local existing_out="" existing_err="" existing_rc=0 existing_state="" existing_iid=""
  _forge_capture existing_out existing_err existing_rc -- glab mr view "$head" -F json || true

  if [ "$existing_rc" -eq 0 ]; then
    existing_iid=$(printf '%s' "$existing_out" | jq -r '.iid // empty' 2>/dev/null) || existing_iid=""
    if [ -n "$existing_iid" ]; then
      # GitLab's own state vocabulary ("opened"), folded to the contract's
      # through the same _forge_map_state the read verbs use. Only an OPEN
      # merge request blocks; a closed or merged one falls through to
      # creation exactly as it does on the github side, so a reused branch
      # is never blocked forever by a dead MR.
      existing_state=$(_forge_map_state gitlab "$(printf '%s' "$existing_out" | jq -r '.state // empty' 2>/dev/null || true)")
      if [ "$existing_state" = "open" ]; then
        _forge_emit_write_status unchanged "$(_forge_build_write_data \
          "$(printf '%s' "$existing_out" | jq -r '.web_url // empty')" \
          "$existing_iid")"
        return 0
      fi
    fi
  fi

  # WRITE 1 (gitlab). -y FIRST. See this section's header for why its absence
  # would hang rather than fail, and for the prefix-assignment landing site
  # that belongs on the line directly above this one.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- glab mr create -y -t "$title" -d "$body" -s "$head" -b "$base" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: glab mr create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "glab mr create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local mr_url=""
  mr_url=$(_forge_glab_write_url "$stdout")

  if [ -z "$mr_url" ]; then
    _forge_pr_write_print_manual create gitlab "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: glab mr create succeeded but its output did not contain a parseable merge request URL." >&2
    _forge_emit_write_status degraded "" "glab mr create succeeded but its output did not contain a parseable merge request URL."
    return 1
  fi

  # PAST THIS POINT THE MERGE REQUEST EXISTS AND ITS URL IS IN HAND -- the
  # identical rule the github arm states at length: never discard $mr_url,
  # never print the create-it-yourself instructions again, never downgrade to
  # degraded (which would force data to null and throw the url away). Only the
  # number is unconfirmed, so it comes back null with a Warning, at exit 0.
  local reread_out="" reread_err="" reread_rc=0 mr_number=""
  _forge_capture reread_out reread_err reread_rc -- glab mr view "$head" -F json || true
  if [ "$reread_rc" -eq 0 ]; then
    mr_number=$(printf '%s' "$reread_out" | jq -r '.iid // empty' 2>/dev/null) || mr_number=""
  fi

  if [ -z "$mr_number" ]; then
    echo "Warning: forge-pr-create: the merge request WAS created at $mr_url, but the post-create glab mr view re-read did not confirm its number -- only the number is unconfirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$mr_url" "")"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$mr_url" "$mr_number")"
}

# gitlab adapter for forge-pr-edit. Same contract as the github arm in
# _forge_pr_edit, including its status word: a successful edit reports
# "unchanged", never "created", because editing mints no new identifier.
# The merge request is a POSITIONAL argument to `glab mr update`, unlike
# `gh pr edit <number>`'s otherwise similar shape.
#
# -t/--title is glab's own spelling, already cited in this section's header
# off glab's published command reference (docs/source/mr/update.md). It is
# emitted ONLY when the caller passed --title, and -d ONLY when the caller
# passed --body -- see the three-branch note in _forge_pr_edit.
_forge_pr_edit_gitlab() {
  local number="$1" body="$2" title="${3:-}" body_provided="${4:-}" title_provided="${5:-}"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body" "$title" "$body_provided"
    _forge_emit_write_status degraded "" "glab not found -- this merge request was not edited automatically."
    return 1
  fi

  # WRITE 2 (gitlab). -y FIRST, same rule, same landing site -- on every one
  # of the three branches, which is why they are spelled out rather than
  # assembled into an array (see _forge_pr_edit's note on the same shape).
  local stdout="" stderr_out="" rc=0
  if [ -n "$title_provided" ] && [ -n "$body_provided" ]; then
    _forge_capture stdout stderr_out rc -- glab mr update "$number" -y -t "$title" -d "$body" || true
  elif [ -n "$title_provided" ]; then
    _forge_capture stdout stderr_out rc -- glab mr update "$number" -y -t "$title" || true
  else
    _forge_capture stdout stderr_out rc -- glab mr update "$number" -y -d "$body" || true
  fi

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: glab mr update exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "glab mr update exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Structured re-read, as the same account that just wrote.
  local reread_out="" reread_err="" reread_rc=0 mr_url="" mr_number=""
  _forge_capture reread_out reread_err reread_rc -- glab mr view "$number" -F json || true
  if [ "$reread_rc" -eq 0 ]; then
    mr_url=$(printf '%s' "$reread_out" | jq -r '.web_url // empty' 2>/dev/null) || mr_url=""
    mr_number=$(printf '%s' "$reread_out" | jq -r '.iid // empty' 2>/dev/null) || mr_number=""
  fi

  if [ -z "$mr_number" ]; then
    _forge_pr_write_print_manual edit gitlab "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: glab mr update succeeded but the merge request could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "glab mr update succeeded but the merge request could not be re-read afterward."
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$mr_url" "$mr_number")"
}

# gitlab adapter for forge-issue-create. Keeps the github arm's SOFT-FAIL
# contract byte for byte: ALWAYS returns 0, on every branch including
# degraded, so a failed issue never blocks PR creation (open-pr.md:481). The
# caller branches on the envelope's `status` field, never on an exit code.
# Giving the gitlab branch a different exit-code contract from the github one
# would silently reintroduce exactly the coupling this verb exists to prevent.
_forge_issue_create_gitlab() {
  local title="$1" body="$2"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab not found -- this issue was not created automatically."
    return 0
  fi

  # WRITE 3 (gitlab). -y FIRST, same rule, same landing site.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- glab issue create -y -t "$title" -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab issue create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url="" issue_number=""
  issue_url=$(_forge_glab_write_url "$stdout")
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || true)

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" gitlab
    _forge_emit_write_status degraded "" "glab issue create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# ============================================================================
# Gitea write adapters — forge-pr-create, forge-pr-edit, forge-issue-create
# ============================================================================
# The gitea arms of this file's THREE write verbs, kept together in one
# section for the same reason the GitLab section above is: the one rule they
# all obey is stated once, where a reviewer meets it before any code.
#
# THE RULE: EVERY tea WRITE INVOCATION CARRIES AT LEAST ONE FLAG. NO
# EXCEPTIONS.
#
# This is the gitea analogue of the GitLab section's "-y FIRST" rule, and its
# shape is DIFFERENT and worse if hit -- do not go looking for a -y here.
# `tea` has NO -y/--yes/--confirm flag anywhere; inventing one by analogy with
# glab would just be an unknown flag. What tea has instead is
# cmd/pulls/create.go:75-81:
#
#     if ctx.IsInteractiveMode() { … interact.CreatePull(…) }
#
# and modules/context/context.go:55-59:
#
#     // IsInteractiveMode returns true if the command is running in
#     // interactive mode (no flags provided and stdout is a terminal)
#     func (ctx *TeaContext) IsInteractiveMode() bool {
#         return ctx.Command.NumFlags() == 0
#     }
#
# THE DOC COMMENT CLAIMS A TTY CHECK; THE IMPLEMENTATION PERFORMS NONE. The
# sole condition is NumFlags() == 0, so a zero-flag `tea pulls create` enters
# an interactive survey EVEN WITH A NON-TTY STDIN -- a hang, forever, with no
# output explaining why, in an autonomous run with nobody present to answer.
# Every write below passes -t/-d/--head/-b anyway, so the invariant costs
# nothing; it is written down because the cheapest way to break it is an
# innocent-looking refactor that moves a flag behind a conditional.
#
# ONE WRITE NOW DOES MOVE ITS FLAGS BEHIND A CONDITIONAL, AND STILL HOLDS.
# `tea pulls edit` emits -t only when the caller passed --title and -d only
# when it passed --body, because sending `-d ""` on a title-only edit would
# blank an existing description. What keeps NumFlags() non-zero is not the
# adapter but its wrapper: cmd_forge_pr_edit refuses a call supplying
# NEITHER flag, so every invocation that reaches the adapter carries at
# least one. The three combinations are spelled out as three literal
# invocations rather than assembled from an array precisely so the
# source-level guard below can still read a flag off every emitted line --
# an array expansion would satisfy the runtime invariant while making it
# unverifiable, which is the refactor the paragraph above warns about
# wearing a different hat.
#
# The invariant is asserted from RECORDED ARGV, never from an exit status: a
# fake tea never prompts, so it exits 0 whether or not a flag was passed and
# an exit-status assertion would pass vacuously.
#
# TEA'S FLAG NAMES ARE NEITHER gh'S NOR glab'S. Read off `gitea/tea` `main`
# source on 2026-08-06 (cmd/flags/issue_pr.go:94-118 for the shared
# create/edit set, cmd/pulls/create.go:26-55 for the pull-specific pair):
#   -t/--title           (same spelling as gh and glab)
#   -d/--description     NOT gh's --body -- the same gotcha glab has
#   --head               LONG FORM ONLY. tea gives it no short alias, and -h
#                        is urfave/cli's help flag, so a "-h" here would print
#                        help instead of naming a branch.
#   -b/--base            NOT glab's --target-branch, and note that glab spells
#                        its OWN -b as --target-branch while tea's -b is
#                        --base -- the short letters agree by coincidence.
# `tea pulls edit` takes the pull request as a POSITIONAL argument and reuses
# IssuePREditFlags (cmd/flags/issue_pr.go:179-202), so -d again -- and -t
# too, since IssuePREditFlags ends in `}, issuePRFlags...)` and it is that
# shared base, not IssuePREditFlags's own edit-only fields, that carries the
# title flag. Re-read on 2026-08-13 and unmoved; _forge_pr_edit_gitea's own
# header carries the three-line citation and what tea does with an omitted
# -t.
#
# ⚠️ GH_TOKEN HAZARD -- WHY NO tea CALL BELOW CARRIES A TOKEN PREFIX, AND WHY
# NONE BLANKS ONE EITHER. tea honours GH_TOKEN, not only GITEA_TOKEN
# (modules/context/context_login.go:15-51 reads both and falls back to the
# GitHub one when GITEA_TOKEN is empty). Meanwhile
# _forge_account_override_slots (:2983-2997) deliberately defaults an empty
# slot to the AMBIENT GH_TOKEN. Copying the github arm's prefix-assignment
# shape onto a tea call would therefore hand a GITHUB token to a GITEA
# instance. So no tea invocation below carries a GH_TOKEN= or
# GH_ENTERPRISE_TOKEN= prefix assignment.
#
# Blanking is refused for the OPPOSITE reason: a bare `GITEA_TOKEN=` prefix
# would revoke the one account-selection mechanism a Gitea operator actually
# has, exactly as phase 2's bare TOKEN="" prefix did on the gh side. So this
# path sets nothing and unsets nothing -- an operator-exported GITEA_TOKEN
# reaches tea untouched, and every call runs as the machine's active tea
# session. `export` stays forbidden here for the same process-wide-state
# reason it is forbidden on the gh and glab sides.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY BEHAVIOR BELOW. tea is NOT
# installed on the machine this was written on; that is this phase's declared
# ceiling, not an oversight. Not one invocation here has been observed against
# the real binary. Every flag, subcommand and JSON key was read off
# `gitea/tea` `main` source on 2026-08-06, file and line cited per claim. The
# tests drive a fake tea that records its argv, so what is actually PROVEN is
# WHICH ARGUMENTS THIS FILE EMITS and HOW IT PARSES A FIXTURE -- never what
# real tea does with them.
#
# KNOWN, DELIBERATE DUPLICATE READ PATH -- NOT AN ACCIDENT, AWAITING
# UNIFICATION. _forge_pr_create_gitea's idempotency probe below reads Gitea
# pull requests through its own `tea pulls list --state all -o json` call and
# a local head filter, and does NOT call _forge_pr_view_gitea. That is a
# scheduling fact, not a design preference: _forge_pr_view_gitea lands in the
# SAME wave as this section, so depending on it would make this story
# unbuildable. The result is a second Gitea PR read path in this file --
# recorded here by name so a later reader finds a known debt rather than
# inferring a mistake. It is the same debt the GitLab arm still owes
# (_forge_pr_view_gitlab plus the inline `glab mr view` in
# _forge_pr_create_gitlab), and both should be unified together.
#
# WHY THE PROBE CANNOT ASK THE SERVER, AND WHAT THAT COSTS. `tea pulls list`
# has NO --head / --source-branch filter at all -- its flags are --fields plus
# PRListingFlags (cmd/pulls/list.go:31) = --state (all|open|closed only),
# --page, --limit, --repo, --remote, --login, --output. `gh pr list --head`
# and `glab mr list --source-branch` have no counterpart, so the filter has to
# run locally, and the LIST document it filters differs from the DETAIL
# document in two ways a naive implementation gets wrong:
#
#   (a) EVERY LIST VALUE IS A JSON STRING and every key is snake_cased
#       (modules/print/table.go:175-208 marshals a map[string]string), so
#       `index` arrives as "42", never 42. Comparisons here are therefore
#       string comparisons, and the number reaches _forge_build_write_data as
#       a string it turns into a JSON int with `tonumber`.
#   (b) THE LIST `head` MAY CARRY AN `owner:` PREFIX for a cross-fork pull
#       request (formatPRHead, modules/print/pull.go:83-93), while the DETAIL
#       `head` is a bare ref (cmd/pulls.go:176). So the match cannot be plain
#       equality -- `forkuser:feat-x` must still match the branch `feat-x`.
#
# ONLY AN OPEN PULL REQUEST BLOCKS CREATION. tea's LIST `state` can literally
# be `merged` (formatPRState, modules/print/pull.go:95-100 returns it whenever
# pr.Merged != nil), so a closed or merged pull request on the same branch
# falls through to creation exactly as it does on the github and gitlab arms.
# A reused branch is never blocked forever by a dead pull request.

# Extracts the pull-request/issue URL from a tea write command's stdout.
#
# A SIBLING of _forge_glab_write_url rather than a rename of it, deliberately:
# tea's two write paths have genuinely different framings that this header has
# to state, and renaming the glab one would touch phase 3's shipped gitlab
# arms while sibling stories hold this file open. Duplication over conflict.
#
#   `tea pulls create` ends in print.PullDetails (modules/task/pull_create.go:89)
#   -- a MARKDOWN block whose URL line is appended only when the URL is
#   NON-EMPTY (modules/print/pull.go:76-78), and `--output json` is not
#   consulted on the create path at all. So "created but no parseable URL" is
#   a REAL branch here, not a hypothetical: callers must treat an empty result
#   as a genuine degraded outcome rather than as a parse bug.
#
#   `tea issues create` is friendlier: markdown PLUS a bare `issue.HTMLURL`
#   line (modules/task/issue_create.go:28-30), so a URL is reliably present.
#
# Deliberately NOT `tail -n1` -- both paths wrap the URL in markdown, so the
# URL is not reliably the last LINE. Scanning for the last http(s) TOKEN is
# tolerant of that framing without depending on its exact wording.
#
# Prints the empty string when no URL is present -- callers treat that as a
# degraded outcome rather than guessing one.
# Usage: _forge_tea_write_url <captured-stdout>
_forge_tea_write_url() {
  local out="${1:-}" url=""
  url=$(printf '%s' "$out" | tr -d '\r' | grep -oE 'https?://[^[:space:]]+' | tail -n1) || url=""
  printf '%s' "$url"
}

# gitea adapter for forge-pr-create. Same contract as the github and gitlab
# arms in _forge_pr_create: shared write envelope, MANDATORY-PRINT
# degradation, non-zero exit on every degraded branch, never retries, never
# prompts.
#
# IDEMPOTENCY is structural, like the github arm's and unlike the gitlab
# arm's, but it is built from a LIST-plus-local-filter rather than from a
# server-side head query -- see this section's header for why tea offers no
# such query, for the two ways its LIST document differs from its DETAIL
# document, and for why only an OPEN pull request blocks.
#
# A FAILED LOOKUP FALLS THROUGH TO CREATION rather than degrading, matching
# the gitlab arm. tea has no distinct exit code for "not found" -- main.go:18-30
# prints `Error: %v` and exits 1 for every error alike -- so a failed
# `tea pulls list` is structurally indistinguishable from an empty one, and
# refusing to create on it would strand every run whose listing hiccuped. Do
# not "fix" this into a stderr match; that is exactly the fragility
# forge-pr-view's structural not_found detection exists to avoid.
_forge_pr_create_gitea() {
  local title="$1" base="$2" head="$3" body="$4"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "tea not found -- this pull request was not created automatically."
    return 1
  fi

  # Existing-PR probe, as the same account the create below will run as.
  # --state all, because the local filter -- not the server -- decides which
  # states block, and a merged pull request must be SEEN in order to be
  # deliberately ignored.
  local list_out="" list_err="" list_rc=0 existing_row="" existing_url="" existing_number=""
  _forge_capture list_out list_err list_rc -- tea pulls list --state all -o json || true

  if [ "$list_rc" -eq 0 ]; then
    # The whole local filter, in one jq program:
    #   - tostring on every value, because LIST values are strings already and
    #     a future typed shape must not change the comparison's meaning;
    #   - head matches either exactly or after an `owner:` prefix;
    #   - state must fold to `open` -- `closed` and `merged` fall through.
    existing_row=$(printf '%s' "$list_out" | jq -c --arg h "$head" '
      [ .[]?
        | select(type == "object")
        | select((((.head // "") | tostring) == $h)
                 or (((.head // "") | tostring) | endswith(":" + $h)))
        | select((((.state // "") | tostring) | ascii_downcase) == "open")
      ] | .[0] // empty' 2>/dev/null) || existing_row=""

    if [ -n "$existing_row" ]; then
      existing_url=$(printf '%s' "$existing_row" | jq -r '.url // empty' 2>/dev/null) || existing_url=""
      existing_number=$(printf '%s' "$existing_row" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || existing_number=""
      if [ -n "$existing_number" ]; then
        _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
        return 0
      fi
    fi
  fi

  # WRITE 1 (gitea). Four flags, so NumFlags() is never 0 -- see this
  # section's header for why a zero-flag invocation hangs rather than fails.
  # No token prefix assignment: see the GH_TOKEN hazard in the same header.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea pulls create -t "$title" -d "$body" --head "$head" -b "$base" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: tea pulls create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "tea pulls create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local pr_url=""
  pr_url=$(_forge_tea_write_url "$stdout")

  if [ -z "$pr_url" ]; then
    _forge_pr_write_print_manual create gitea "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: tea pulls create succeeded but its output did not contain a parseable pull request URL." >&2
    _forge_emit_write_status degraded "" "tea pulls create succeeded but its output did not contain a parseable pull request URL."
    return 1
  fi

  # PAST THIS POINT THE PULL REQUEST EXISTS AND ITS URL IS IN HAND -- the same
  # rule the github and gitlab arms state at length: never discard $pr_url,
  # never print the create-it-yourself instructions again, never downgrade to
  # degraded (which would force data to null and throw the created pull
  # request's URL away). Only the number is unconfirmed, so it comes back null
  # with a Warning, at exit 0.
  #
  # The URL's trailing segment is only an ADDRESS for the re-read, never the
  # answer: the number reported below is `index`, read out of the DETAIL
  # document tea returns, so a URL shape this file guessed wrong yields a null
  # number rather than a wrong one.
  local candidate="" reread_out="" reread_err="" reread_rc=0 pr_number=""
  candidate=$(printf '%s' "$pr_url" | grep -oE '[0-9]+$') || candidate=""
  if [ -n "$candidate" ]; then
    _forge_capture reread_out reread_err reread_rc -- tea pulls "$candidate" -o json || true
    if [ "$reread_rc" -eq 0 ]; then
      pr_number=$(printf '%s' "$reread_out" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || pr_number=""
    fi
  fi

  if [ -z "$pr_number" ]; then
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but the post-create tea pulls re-read did not confirm its number -- only the number is unconfirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# gitea adapter for forge-pr-edit. Same contract as the github and gitlab arms
# in _forge_pr_edit, including its status word: a successful edit reports
# "unchanged", never "created", because editing mints no new identifier.
# The pull request is a POSITIONAL argument to `tea pulls edit`, like
# `glab mr update <id>` and unlike `gh pr edit <number>`'s flag-shaped body.
#
# -t IS A REAL `tea pulls edit` FLAG, AND HERE IS THE READ IT COMES FROM.
# Re-confirmed against `gitea/tea` `main` on 2026-08-13, inside this
# section's declared VERIFICATION CEILING -- tea is still not installed
# here, so this is a source reading and not an observation:
#   cmd/pulls/edit.go:66      Flags: append(flags.IssuePREditFlags, ...)
#   cmd/flags/issue_pr.go:202 IssuePREditFlags = append([]cli.Flag{...}, issuePRFlags...)
#   cmd/flags/issue_pr.go:95-98   issuePRFlags carries {Name: "title", Aliases: []string{"t"}}
# So title arrives through the SHARED create/edit base, not through
# IssuePREditFlags's own edit-only fields (set-assignees, add-labels and the
# rest) -- which is the part worth writing down, because reading only
# IssuePREditFlags's literal body would conclude there is no title flag.
# tea's own parser then gates the field on `ctx.IsSet("title")`
# (cmd/flags/issue_pr.go:207-210), so an omitted -t leaves the stored title
# alone -- exactly the semantics the conditional emission below relies on.
_forge_pr_edit_gitea() {
  local number="$1" body="$2" title="${3:-}" body_provided="${4:-}" title_provided="${5:-}"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body" "$title" "$body_provided"
    _forge_emit_write_status degraded "" "tea not found -- this pull request was not edited automatically."
    return 1
  fi

  # WRITE 2 (gitea). Every branch below carries -t, -d, or both, so
  # NumFlags() is never zero and the interactive-survey hang this section's
  # header describes stays unreachable; the wrapper refusing a call that
  # supplies neither flag is what makes that true for all three. Spelling
  # the branches out rather than assembling an array is deliberate -- the
  # header names "an innocent-looking refactor that moves a flag behind a
  # conditional" as the cheapest way to break the invariant, and a literal
  # flag on every emitted line is what keeps the source-level guard able to
  # see it. No token prefix assignment, same GH_TOKEN hazard.
  local stdout="" stderr_out="" rc=0
  if [ -n "$title_provided" ] && [ -n "$body_provided" ]; then
    _forge_capture stdout stderr_out rc -- tea pulls edit "$number" -t "$title" -d "$body" || true
  elif [ -n "$title_provided" ]; then
    _forge_capture stdout stderr_out rc -- tea pulls edit "$number" -t "$title" || true
  else
    _forge_capture stdout stderr_out rc -- tea pulls edit "$number" -d "$body" || true
  fi

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: tea pulls edit exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "tea pulls edit exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Structured re-read, as the same account that just wrote. The DETAIL shape
  # (`tea pulls <index> -o json`), whose `index` is a real JSON int and whose
  # `url` is pr.HTMLURL -- NOT the LIST shape the create probe filters.
  local reread_out="" reread_err="" reread_rc=0 pr_url="" pr_number=""
  _forge_capture reread_out reread_err reread_rc -- tea pulls "$number" -o json || true
  if [ "$reread_rc" -eq 0 ]; then
    pr_url=$(printf '%s' "$reread_out" | jq -r '.url // empty' 2>/dev/null) || pr_url=""
    pr_number=$(printf '%s' "$reread_out" | jq -r 'if has("index") then (.index | tostring) else "" end' 2>/dev/null) || pr_number=""
  fi

  if [ -z "$pr_number" ]; then
    _forge_pr_write_print_manual edit gitea "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: tea pulls edit succeeded but the pull request could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "tea pulls edit succeeded but the pull request could not be re-read afterward."
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# gitea adapter for forge-issue-create. Keeps the github and gitlab arms'
# SOFT-FAIL contract byte for byte: ALWAYS returns 0, on every branch
# including degraded, so a failed issue never blocks PR creation. The caller
# branches on the envelope's `status` field, never on an exit code. Giving the
# gitea branch a different exit-code contract would silently reintroduce
# exactly the coupling this verb exists to prevent.
_forge_issue_create_gitea() {
  local title="$1" body="$2"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea not found -- this issue was not created automatically."
    return 0
  fi

  # WRITE 3 (gitea). Two flags, same invariant, same header. No token prefix
  # assignment, same GH_TOKEN hazard.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea issues create -t "$title" -d "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea issues create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url="" issue_number=""
  issue_url=$(_forge_tea_write_url "$stdout")
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$') || issue_number=""

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" gitea
    _forge_emit_write_status degraded "" "tea issues create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# Shells `gh pr create --title <t> --base <b> --head <h> --body <b>`,
# capturing stdout as the created PR's URL -- gh pr create has NO --json
# flag (confirmed on this machine, exactly like gh issue create: only a
# plain URL reaches stdout on success). The created PR's `number` is NEVER
# derived by regexing that URL (AC3) -- instead, once creation succeeds,
# this function re-queries story 04's forge-pr-view lookup for the same
# --head branch (a structured re-read) and reads `.pr.number`/`.pr.url`
# from ITS normalized output. forge-pr-view's own --pr flag only accepts a
# branch name or a bare PR number (validated against a fixed regex) -- not
# a URL -- so "feeding the URL back through forge-pr-view" is realized here
# as re-querying by the already-validated --head branch, the one identifier
# both the pre-create idempotency check and the post-create confirmation
# can share; this is what keeps the number's origin a structured field
# read, never a trailing-digit regex on a URL string.
#
# RESULT ENVELOPE: every branch below emits forge-contract.md's shared
# write-verb envelope via _forge_emit_write_status -- {status, data,
# message} with status created | unchanged | degraded, the same shape
# forge-pr-edit and forge-issue-create emit. stdout is therefore NEVER
# silent, not even on a failure branch: a caller that reads stdout learns
# what happened from `status` instead of having to infer it from an empty
# capture. This is an ADDITION to the exit-code contract below, never a
# replacement -- every degraded branch here still returns 1.
#
# IDEMPOTENCY (AC2): before ever shelling out to create anything, looks up
# whether an open PR already exists for $head via forge-pr-view, in-process
# (a direct function call, never a `$AIMI_CLI forge-pr-view` subprocess).
# When an OPEN one is found, reports status "unchanged" with that PR's
# {url, number} and returns 0 WITHOUT attempting a second creation --
# open-pr.md's own "PR already exists for this branch" behavior today,
# informational rather than an error. A retried phase in execute.md's
# per-repository loop is exactly why this matters: a retry must never open
# a duplicate PR for the same branch.
# That check branches over ALL THREE of forge-pr-view's statuses:
# only `found` + a normalized state of `open` short-circuits; `not_found`
# and a found-but-closed/merged PR both proceed to creation; `error` (and
# any status this code does not recognize) is a hard failure that NEVER
# reaches `gh pr create`.
#
# MANDATORY-PRINT degrade mode: see this section's header comment above for
# the full statement of why this differs from forge-issue-create's soft-
# fail contract. Every failure path that runs BEFORE `gh pr create` has
# returned a url -- unsupported forge, missing gh, the existing-PR lookup
# erroring, the create call itself failing, an unparseable success response
# -- prints the manual create-it-yourself instructions via
# _forge_pr_write_print_manual, emits a status "degraded" envelope carrying
# the same reason text, and returns 1. Once a url IS in hand the manual
# fallback is never printed again AND the outcome is never downgraded to
# degraded: a post-create re-read failure keeps that url, reports status
# "created" with data {url, number: null} at exit 0, and warns that only
# the number is unconfirmed. Reporting that branch as degraded would force
# `data` to null and throw the created PR's url away -- the exact defect
# the "PAST THIS POINT" comment below exists to prevent. Never retries,
# never prompts interactively.
_forge_pr_create() {
  local title="$1" base="$2" head="$3" body="$4"
  local forge=""
  _detect_forge_type forge

  # Routing, not a github/not-github gate. The `|| gl_rc=$?` capture is
  # mandatory under this file's `set -e`: the gitlab arm returns 1 on every
  # degraded branch by contract, and an uncaptured non-zero return from a
  # plain statement would abort the whole CLI before the envelope reached
  # stdout.
  case "$forge" in
    github) ;;
    gitlab)
      local gl_rc=0
      _forge_pr_create_gitlab "$title" "$base" "$head" "$body" || gl_rc=$?
      return "$gl_rc"
      ;;
    gitea)
      local gt_rc=0
      _forge_pr_create_gitea "$title" "$base" "$head" "$body" || gt_rc=$?
      return "$gt_rc"
      ;;
    *)
      _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
      _forge_emit_write_status degraded "" "forge-pr-create: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 1
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    _forge_emit_write_status degraded "" "gh not found -- this pull request was not created automatically."
    return 1
  fi

  # This repository's remembered account, resolved ONCE for all three gh-facing
  # steps below (the idempotency check, the create itself, the post-create
  # re-read) rather than re-derived at each one. Both slots are named at every
  # site and at most one is ever non-empty; the empty case is the opt-out and
  # needs no branch. Resolved AFTER the gh gate above so a machine with no gh
  # gets one explanation, not two. See the ROUTING RULE block above the
  # forge-auth-status section -- export is forbidden, prefix assignment only.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # Existing-PR check. `state` rides along with url/number precisely because
  # this branch has to tell an OPEN PR (which blocks creation) apart from a
  # closed/merged one (which must not) -- `gh pr view <branch>` is NOT
  # state-filtered, so a branch reused after its prior PR was merged still
  # resolves to that stale PR here.
  # Routed: this lookup is part of the create operation, so it must run as the
  # same account the create will (a private repo can let the creating account
  # see a PR its reader account cannot).
  local existing="" existing_rc=0 existing_status existing_state existing_message
  existing=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$head" --include url,number,state) || existing_rc=$?
  if [ "$existing_rc" -ne 0 ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: forge-pr-view lookup failed while checking for an existing PR (exit $existing_rc)." >&2
    _forge_emit_write_status degraded "" "forge-pr-create: forge-pr-view lookup failed while checking for an existing PR (exit $existing_rc)."
    return 1
  fi

  # Branch over ALL THREE statuses forge-pr-view can return, never just
  # found. forge-pr-view exists specifically so "no PR exists" is
  # distinguishable from "the lookup broke", and it reports the latter as
  # status:"error" INSIDE its envelope at exit 0 -- so the $existing_rc
  # guard above cannot see it. A check that only tested for "found" let
  # error fall through to `gh pr create` and opened a duplicate PR for a
  # branch whose real PR the tool simply could not read (an expired token,
  # a network blip). Creation happens on not_found alone -- plus the
  # explicitly-inspected closed/merged case below.
  existing_status=$(printf '%s' "$existing" | jq -r '.status')
  case "$existing_status" in
    found)
      # Only an OPEN PR blocks -- matching cmd_help's own "existing open PR"
      # wording. A closed or merged PR on this branch falls through to
      # creation exactly like not_found, so a reused branch gets a fresh
      # pull request instead of being blocked forever by a dead one.
      existing_state=$(printf '%s' "$existing" | jq -r '.pr.state // empty')
      if [ "$existing_state" = "open" ]; then
        # "unchanged", not a `created:false` boolean: no new PR number was
        # minted, which is exactly what forge-contract.md's Write-Verb
        # Status Convention names that outcome -- and the same word every
        # successful forge-pr-edit call reports.
        _forge_emit_write_status unchanged "$(_forge_build_write_data \
          "$(printf '%s' "$existing" | jq -r '.pr.url // empty')" \
          "$(printf '%s' "$existing" | jq -r '.pr.number // empty')")"
        return 0
      fi
      ;;
    not_found)
      ;;
    error|*)
      # `error` is named explicitly; `*` makes any future status value fail
      # the same closed way. Neither is a defensible reason to create a PR:
      # a status this code does not understand must never be read as
      # permission to open one. Unreachable in practice today --
      # _forge_pr_view_emit rejects a fourth status before it ever reaches
      # this caller -- but the fall-through it replaces is exactly the class
      # of defect this branch exists to prevent.
      existing_message=$(printf '%s' "$existing" | jq -r '.message // empty')
      _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
      echo "Error: forge-pr-create: forge-pr-view reported an error while checking for an existing PR on $head: ${existing_message:-unknown error}" >&2
      _forge_emit_write_status degraded "" "forge-pr-create: forge-pr-view reported an error while checking for an existing PR on $head: ${existing_message:-unknown error}"
      return 1
      ;;
  esac

  # WRITE 1. The prefix assignment is on the _forge_capture call itself, so the
  # value is set for the duration of that one function call, exported into the
  # `gh` grandchild it spawns, and unset again the moment it returns --
  # _forge_capture's argv-only signature is untouched and the token never
  # becomes an argv element. `env GH_TOKEN=... gh ...` is forbidden for exactly
  # that reason: env(1)'s own argv would carry it into the process table.
  local stdout rc=0 stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh pr create --title "$title" --base "$base" --head "$head" --body "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: gh pr create exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "gh pr create exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  local pr_url
  pr_url=$(printf '%s' "$stdout" | tail -n1 | tr -d '\r')

  if [ -z "$pr_url" ]; then
    _forge_pr_write_print_manual create "$forge" "$base" "$head" "$body" "$title"
    echo "Error: forge-pr-create: gh pr create succeeded but its output did not contain a parseable PR URL." >&2
    _forge_emit_write_status degraded "" "gh pr create succeeded but its output did not contain a parseable PR URL."
    return 1
  fi

  # Structured re-read (AC3) -- never a regex on $pr_url.
  #
  # PAST THIS POINT THE PR EXISTS AND ITS URL IS IN HAND, so neither failure
  # branch below may discard $pr_url, report failure, or print the manual
  # create-it-yourself instructions: a caller following those instructions
  # would open a SECOND pull request for a branch that already has one, and
  # execute.md's per-repository loop would report a successful creation as a
  # failure. Only the number is unconfirmed, so it comes back null with a
  # Warning (not an Error) naming the url, at exit 0.
  #
  # That is also why both branches below stay status "created" rather than
  # "degraded": a new PR number genuinely WAS minted, and `degraded` forces
  # `data` to null by design (forge-contract.md's Write-Verb Status
  # Convention), which would throw the very url this comment exists to
  # protect straight back away.
  # Routed for the same reason the idempotency check above is, and here the
  # consequence is concrete: on a private repository this re-read performed as
  # the machine account would fail against a PR the overridden account has just
  # successfully created.
  local reread="" reread_rc=0 reread_status reread_message pr_number
  reread=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$head" --include url,number) || reread_rc=$?
  if [ "$reread_rc" -ne 0 ]; then
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but the post-create forge-pr-view re-read failed (exit $reread_rc) -- only its number could not be confirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi
  reread_status=$(printf '%s' "$reread" | jq -r '.status')
  if [ "$reread_status" != "found" ]; then
    reread_message=$(printf '%s' "$reread" | jq -r '.message // empty')
    echo "Warning: forge-pr-create: the pull request WAS created at $pr_url, but it could not be re-read afterward (forge-pr-view status: $reread_status${reread_message:+ -- $reread_message}) -- only its number could not be confirmed. Do NOT create it again." >&2
    _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "")"
    return 0
  fi
  pr_number=$(printf '%s' "$reread" | jq -r '.pr.number // empty')

  _forge_emit_write_status created "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# Public wrapper: parses --title/--base/--head/--body/--project (deliberately
# no --token or similarly credential-shaped flag -- see this section's
# header comment and forge-contract.md's Credential/Identity Model),
# applies the three standard guards used by cmd_detect_parent_branch/
# cmd_resolve_base_branch (project cd, git-repository check, branch-name
# validation against the existing ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ pattern for
# BOTH --base and --head, before either is ever interpolated into a git/gh
# invocation), then delegates exactly once to _forge_pr_create.
cmd_forge_pr_create() {
  check_jq

  local title="" base="" head="" body="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title)   shift; title="${1:-}" ;;
      --base)    shift; base="${1:-}" ;;
      --head)    shift; head="${1:-}" ;;
      --body)    shift; body="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-create: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$title" ] || [ -z "$base" ] || [ -z "$head" ]; then
    echo "Usage: aimi-cli.sh forge-pr-create --title <t> --base <branch> --head <branch> [--body <text>] [--project <path>]" >&2
    exit 1
  fi

  # Validate every branch name BEFORE it is ever interpolated into a git/gh
  # invocation (plugins/aimi-engineering/CLAUDE.md Security Requirements).
  if ! [[ "$base" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-create: invalid --base value: $base" >&2
    exit 1
  fi
  if ! [[ "$head" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-create: invalid --head value: $head" >&2
    exit 1
  fi

  _forge_pr_create "$title" "$base" "$head" "$body"
}

# Shells `gh pr edit <number> [--title <t>] [--body <b>]`, then re-reads the edited PR via
# story 04's forge-pr-view lookup (in-process, keyed on the same numeric
# identifier the caller supplied) to confirm and report {url, number} under
# the write envelope's `data` key -- the same structured-field discipline
# _forge_pr_create applies, and now genuinely the same JSON shape, so a
# caller really can treat both verbs' output identically (AC4). It did not
# before: this function used to return a bare {url, number} with no status
# field at all while forge-pr-create returned {url, number, created}, so
# the two shapes never matched despite the comment here claiming they did.
#
# A successful edit reports status "unchanged", never "created": editing a
# PR mutates a number that already existed and mints no new identifier,
# which is precisely what forge-contract.md's Write-Verb Status Convention
# means by that word. The PR's BODY did change -- "unchanged" is about the
# resource identifier, not about the content.
#
# MANDATORY-PRINT degrade mode: identical contract to _forge_pr_create --
# see this section's header comment. Every failure branch also emits a
# status "degraded" envelope on stdout carrying the same reason its stderr
# text states. Never retries, never prompts interactively, exits non-zero
# on every failure path.
#
# EACH FLAG IS EMITTED ONLY WHEN THE CALLER SUPPLIED IT, AND THAT IS THE
# WHOLE REASON THE PROVIDED-NESS SIGNALS ARE THREADED DOWN HERE. --title and
# --body are each independently optional (cmd_forge_pr_edit refuses only a
# call that supplies NEITHER), so an invocation that always named both would
# send `--body ""` alongside a title-only edit -- and `gh pr edit N --body ""`
# blanks a description, which is silent data loss on a pull request the
# caller only wanted to retitle. $body cannot answer this question on its
# own for exactly the reason cmd_forge_pr_edit tracks the flag rather than
# the value: an empty body is a legitimate deliberate clear.
#
# All three adapters therefore spell out the same three branches instead of
# building an argv array. That is not a style choice: the gitea section
# header's always-pass-a-flag invariant, and the two source-level guards
# that enforce it and glab's -y over the whole file, both work by reading
# the emitted line -- an array expansion would hide every flag from them
# while the runtime behaviour looked unchanged.
_forge_pr_edit() {
  local number="$1" body="$2" title="${3:-}" body_provided="${4:-}" title_provided="${5:-}"
  local forge=""
  _detect_forge_type forge

  # Same routing shape and the same `set -e` capture rule as
  # _forge_pr_create above.
  case "$forge" in
    github) ;;
    gitlab)
      local gl_rc=0
      _forge_pr_edit_gitlab "$number" "$body" "$title" "$body_provided" "$title_provided" || gl_rc=$?
      return "$gl_rc"
      ;;
    gitea)
      local gt_rc=0
      _forge_pr_edit_gitea "$number" "$body" "$title" "$body_provided" "$title_provided" || gt_rc=$?
      return "$gt_rc"
      ;;
    *)
      _forge_pr_write_print_manual edit "$forge" "" "$number" "$body" "$title" "$body_provided"
      _forge_emit_write_status degraded "" "forge-pr-edit: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 1
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body" "$title" "$body_provided"
    _forge_emit_write_status degraded "" "gh not found -- this pull request was not edited automatically."
    return 1
  fi

  # Resolved ONCE for both the edit and its post-edit re-read -- see
  # _forge_pr_create's own resolution and the ROUTING RULE block above the
  # forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # This call alone discarded gh's stdout to /dev/null rather than capturing
  # it. It now lands in a local nothing reads, which is behaviourally
  # identical -- neither form ever printed or inspected it.
  #
  # WRITE 2. Identical prefix-assignment shape to WRITE 1: on the
  # _forge_capture call, never inside its argv, never via `env` -- and now
  # on each of the three branches, so the prefix cannot be lost from one of
  # them while the other two keep the assertion green.
  local stdout rc=0 stderr_out
  if [ -n "$title_provided" ] && [ -n "$body_provided" ]; then
    GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
      _forge_capture stdout stderr_out rc -- gh pr edit "$number" --title "$title" --body "$body" || true
  elif [ -n "$title_provided" ]; then
    GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
      _forge_capture stdout stderr_out rc -- gh pr edit "$number" --title "$title" || true
  else
    GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
      _forge_capture stdout stderr_out rc -- gh pr edit "$number" --body "$body" || true
  fi

  if [ "$rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: gh pr edit exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "gh pr edit exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  # Routed: part of the same logical edit, so it reads as the account that
  # just wrote.
  local reread="" reread_rc=0 reread_status pr_url pr_number
  reread=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$number" --include url,number) || reread_rc=$?
  if [ "$reread_rc" -ne 0 ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: gh pr edit succeeded but the post-edit forge-pr-view re-read failed (exit $reread_rc)." >&2
    _forge_emit_write_status degraded "" "gh pr edit succeeded but the post-edit forge-pr-view re-read failed (exit $reread_rc)."
    return 1
  fi
  reread_status=$(printf '%s' "$reread" | jq -r '.status')
  if [ "$reread_status" != "found" ]; then
    _forge_pr_write_print_manual edit "$forge" "" "$number" "$body" "$title" "$body_provided"
    echo "Error: forge-pr-edit: gh pr edit succeeded but the PR could not be re-read afterward." >&2
    _forge_emit_write_status degraded "" "gh pr edit succeeded but the PR could not be re-read afterward."
    return 1
  fi
  pr_url=$(printf '%s' "$reread" | jq -r '.pr.url // empty')
  pr_number=$(printf '%s' "$reread" | jq -r '.pr.number // empty')

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$pr_url" "$pr_number")"
}

# Public wrapper: parses --number/--title/--body/--project (no --token or
# similarly credential-shaped flag -- see this section's header comment),
# applies the same three standard guards as cmd_forge_pr_create (project cd,
# git-repository check, identifier validation before shelling out) --
# --number is validated as numeric-only (^[0-9]+$) rather than the branch-
# name pattern, matching cmd_forge_issue_view's own numeric-identifier guard
# -- then delegates exactly once to _forge_pr_edit.
#
# --title is OPTIONAL, and so is --body: the guard below refuses only a call
# that supplies neither. Making --title mandatory the way --body used to be
# would have broken this verb's one in-tree caller on the spot --
# commands/open-pr.md Step 5c appends a "Related issue: #N" line and passes
# --body alone. Nothing in the plugin passes --title today; forge-pr-create
# has accepted one since it was written, and this is the symmetric ability
# forge-pr-edit simply lacked (GitHub issue #110).
cmd_forge_pr_edit() {
  check_jq

  local number="" body="" title="" project_dir="" body_provided="" title_provided=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)  shift; number="${1:-}" ;;
      # body_provided tracks whether the FLAG was seen, deliberately not
      # whether its value is non-empty: `gh pr edit N --body ""` blanks a
      # description, so "flag omitted entirely" (a caller that forgot it,
      # which must be refused) and "--body ''" (a deliberate clear, which
      # must keep working) have to stay distinguishable. Checking $body for
      # emptiness would collapse them back together.
      --body)    shift; body="${1:-}"; body_provided=1 ;;
      # title_provided follows the SAME flag-seen rule, for a reason that is
      # only half the same. The shared half: now that both flags are
      # optional, each adapter has to know which ones to emit, and a value
      # test cannot answer that. The half that DIVERGES is the verdict on an
      # empty value -- see the refusal below.
      --title)   shift; title="${1:-}"; title_provided=1 ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-edit: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$number" ] || { [ -z "$body_provided" ] && [ -z "$title_provided" ]; }; then
    echo "Usage: aimi-cli.sh forge-pr-edit --number <n> [--title <text>] [--body <text>] [--project <path>]" >&2
    echo "       at least one of --title / --body is required" >&2
    exit 1
  fi

  # DELIBERATELY THE OPPOSITE ANSWER TO --body "". An empty description is a
  # real value on all three forges and clearing one is a thing a caller
  # legitimately asks for, so --body "" is honoured. An empty TITLE is not a
  # legal value on gh, glab or tea -- there is nothing it could mean but a
  # mistake -- so --title gets no "deliberate clear" escape hatch and is
  # refused here, before any forge CLI runs. Its own message, distinct from
  # the usage error above, because the two are different caller mistakes:
  # one forgot to say what to change, the other asked for something no forge
  # will store.
  if [ -n "$title_provided" ] && [ -z "$title" ]; then
    echo "Error: forge-pr-edit: --title must not be empty -- no forge accepts an empty pull/merge request title. Omit --title to leave the title unchanged." >&2
    exit 1
  fi

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-pr-edit: --number must be a positive integer (got: $number)" >&2
    exit 1
  fi

  _forge_pr_edit "$number" "$body" "$title" "$body_provided" "$title_provided"
}

# ============================================================================
# forge-pr-merge (US-006, four-open-issues-remediation)
# ============================================================================
# The third WRITE verb to mutate a pull/merge request, and the first that
# mints no new identifier at all -- a merge changes neither a PR's number nor
# its url, so `status: "created"` is structurally unreachable here and is
# never emitted. Only `unchanged` (the merge succeeded, or the PR/MR was
# already merged/locked) and `degraded` (everything else) are emittable. See
# forge-contract.md's Write-Verb Status Convention.
#
# NORMALIZED CORE ONLY, DELIBERATELY: merge style is explicit and REQUIRED
# (never defaulted), validated against the closed three-value enum
# {merge, squash, rebase} -- never gitea's own fourth `rebase-merge` style.
# No conditional/auto-merge, no approval handling, no branch-deletion flag on
# any forge. That exclusion is what makes the three forges normalizable: tea
# exposes neither branch deletion nor an auto-merge equivalent, while gh and
# glab expose both.
#
# PREFLIGHT REUSES forge-pr-view IN-PROCESS, NEVER A SECOND BESPOKE PROBE.
# Unlike forge-pr-create's gitlab/gitea idempotency checks (which had to
# hand-roll a forge-native inline probe because forge-pr-view's own
# gitlab/gitea adapters postdated forge-pr-create), all three forge-pr-view
# adapters already exist by the time this verb is written, so every one of
# the three merge adapters below resolves `{number, url, state}` through the
# identical `cmd_forge_pr_view --pr <ref> --include number,url,state` call --
# a direct function call, never a `$AIMI_CLI forge-pr-view` subprocess. The
# call appears three times in source (github inline in _forge_pr_merge,
# _forge_pr_merge_gitlab, _forge_pr_merge_gitea) rather than being factored
# above the three-way dispatch, deliberately: that keeps the same
# self-contained-per-adapter shape forge-pr-create/forge-pr-edit already use
# (each adapter does its own everything, callable and testable on its own) at
# the cost of the call appearing three times rather than once. This is NOT
# the file's own "KNOWN, DELIBERATE DUPLICATE READ PATH" debt named in the
# Gitea write adapters section header -- that debt exists because an adapter
# was missing when its caller was written; here nothing is missing.
#
# ENVELOPE MAPPING (forge-pr-view's own found/not_found/error, read via the
# preflight above):
#   error/hard failure of the preflight call itself -> degraded, data null,
#     naming the exit code. Never falls through to a merge attempt.
#   not_found                                        -> degraded, data null,
#     naming the searched ref. There is nothing to merge.
#   found, state == closed (closed, never merged)     -> degraded, data null,
#     BEFORE any merge CLI call runs -- a structural pre-check, not left to
#     whatever gh/glab/tea happen to do when asked to merge a closed PR, the
#     same not-worth-guessing reason forge-pr-view's own not_found detection
#     was made structural.
#   found, state == merged OR locked (GitLab's merged-and-lock-protected
#     value)                                          -> unchanged, data
#     {url, number} taken directly from the preflight, at exit 0, WITHOUT
#     ever invoking gh/glab/tea's merge subcommand. A locked MR is already
#     merged; treating it as a second, undocumented state instead of folding
#     it into the same branch as merged would invent a fifth outcome the
#     decided envelope mapping does not have.
#   found, state == open                              -> the only branch that
#     proceeds to an actual merge attempt.
#   merge call exits 0                                -> unchanged, data
#     {url, number} REUSED from the preflight read, never a second
#     post-merge re-read: a merge changes neither a PR's number nor its url,
#     so the identifiers the preflight already confirmed are still correct
#     and a second forge-pr-view round-trip would be pure waste (unlike
#     forge-pr-create, which mints a brand-new number, or forge-pr-edit,
#     whose re-read reconfirms a title/body that may have changed).
#   merge call exits non-zero                         -> degraded, data null,
#     message carrying that call's own captured stderr verbatim -- covering
#     conflicts, "not mergeable", a draft PR, a protected-branch/missing-
#     approvals/no-permission refusal, and an auth failure alike, with no
#     further classification attempted (matching forge-pr-create/
#     forge-pr-edit's own generic rc-nonzero branches).
#
# EXIT CONTRACT MATCHES forge-pr-create/forge-pr-edit, NOT
# forge-issue-create: every degraded branch exits non-zero, so a caller's own
# per-repository failure isolation can react. Exits 0 only on unchanged.
# Every degraded branch prints MANDATORY manual-fallback instructions to
# stderr first (never stdout) via _forge_pr_merge_print_manual below.
#
# IDENTITY: no --token or credential-shaped flag, matching every other forge
# write verb -- acting identity is read only from the environment
# (AIMI_FORGE_IDENTITY / GH_TOKEN / an operator-exported GITLAB_TOKEN or
# GITEA_TOKEN), never a flag.
#
# `tea`'s interactive-prompt behavior SPECIFICALLY FOR `tea pulls merge` (as
# opposed to the already-documented `tea pulls create` hazard) is UNCONFIRMED
# -- tea is not installed on this machine, matching every other gitea
# adapter's own stated verification ceiling. The defense here is structural
# rather than empirical: --style is required and ALWAYS passed on every code
# path that reaches `tea pulls merge`, never optional and never defaulted, so
# NumFlags() cannot be zero regardless of what tea's own prompt behavior for
# this specific subcommand turns out to be.

# Prints the MANDATORY manual-fallback instructions (forge-contract.md's
# Degradation Contract, mandatory mode) for every forge-pr-merge failure path
# -- an unsupported forge, a missing gh/glab/tea binary, a failed preflight
# lookup, a closed-but-never-merged PR/MR, or the merge call itself failing
# all funnel through this one function so the wording is identical
# regardless of WHY automatic merging did not happen. Always stderr, never
# stdout, matching _forge_pr_write_print_manual's own contract.
#
# A SIBLING of _forge_pr_write_print_manual, not a mode grafted onto it:
# merge has no title/body to conditionally print and does have a required
# style, so the parameter shapes genuinely differ.
#
# repo-info is queried in-process, exactly like the create/edit helper above,
# and is itself best-effort: when it cannot resolve owner/repo, the URL line
# is simply omitted rather than guessing a wrong one.
# Usage: _forge_pr_merge_print_manual <forge> <pr-ref> <style>
_forge_pr_merge_print_manual() {
  local forge="$1" pr_ref="$2" style="$3"

  local repo_info="" owner="" repo="" host=""
  repo_info=$(_forge_repo_info 2>/dev/null) || repo_info=""
  if [ -n "$repo_info" ] && [ "$(printf '%s' "$repo_info" | jq -r '.status' 2>/dev/null)" = "found" ]; then
    owner=$(printf '%s' "$repo_info" | jq -r '.data.owner // empty')
    repo=$(printf '%s' "$repo_info" | jq -r '.data.repo // empty')
    host=$(printf '%s' "$repo_info" | jq -r '.data.host // empty')
  fi
  if [ -z "$host" ]; then
    case "$forge" in
      gitlab) host="gitlab.com" ;;
      gitea)  host="gitea.com" ;;
      *)      host="github.com" ;;
    esac
  fi

  {
    if [ "$forge" = "gitlab" ]; then
      local glab_style_flag=""
      case "$style" in
        squash) glab_style_flag=" -s" ;;
        rebase) glab_style_flag=" -r" ;;
      esac
      echo "Warning: could not merge this gitlab merge request automatically -- merge it yourself with:"
      echo "  glab mr merge $pr_ref -y${glab_style_flag}"
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/-/merge_requests/$pr_ref"
      fi
    elif [ "$forge" = "gitea" ]; then
      echo "Warning: could not merge this gitea pull request automatically -- merge it yourself with:"
      echo "  tea pulls merge $pr_ref --style $style"
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/pulls/$pr_ref"
      fi
    else
      local gh_style_flag=""
      case "$style" in
        merge)  gh_style_flag="-m" ;;
        squash) gh_style_flag="-s" ;;
        rebase) gh_style_flag="-r" ;;
      esac
      echo "Warning: could not merge this $forge pull request automatically -- merge it yourself with:"
      echo "  gh pr merge $pr_ref $gh_style_flag"
      if [ -n "$owner" ] && [ -n "$repo" ]; then
        echo "  Or open: https://$host/$owner/$repo/pull/$pr_ref"
      fi
    fi
  } >&2
}

# gitlab adapter for forge-pr-merge. Preflight via cmd_forge_pr_view
# in-process (see this section's header); short-circuits to unchanged on
# state merged/locked, degrades on not_found/error/closed before any write,
# otherwise shells `glab mr merge <id> -y [-s|-r]` -- -y FIRST, same rule as
# every other glab write call in this file (see "GitLab write adapters"
# section above: glab prompts for a submission confirmation without it, and
# an autonomous run would hang forever). No flag at all for the merge-commit
# default style, matching glab's own default. No token prefix assignment:
# gitlab applies no account override on this verb, exactly as its existing
# create/edit adapters do not (see forge-contract.md's Credential/Identity
# Model, "Which calls are routed").
_forge_pr_merge_gitlab() {
  local pr_ref="$1" style="$2"

  if ! _forge_bin_check glab mandatory gitlab; then
    _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
    _forge_emit_write_status degraded "" "glab not found -- this merge request was not merged automatically."
    return 1
  fi

  local existing="" existing_rc=0
  existing=$(cmd_forge_pr_view --pr "$pr_ref" --include number,url,state) || existing_rc=$?
  if [ "$existing_rc" -ne 0 ]; then
    _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
    echo "Error: forge-pr-merge: forge-pr-view lookup failed while resolving the merge request to merge (exit $existing_rc)." >&2
    _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view lookup failed while resolving the merge request to merge (exit $existing_rc)."
    return 1
  fi

  local existing_status existing_state existing_url existing_number existing_message
  existing_status=$(printf '%s' "$existing" | jq -r '.status')
  case "$existing_status" in
    found)
      existing_state=$(printf '%s' "$existing" | jq -r '.pr.state // empty')
      existing_url=$(printf '%s' "$existing" | jq -r '.pr.url // empty')
      existing_number=$(printf '%s' "$existing" | jq -r '.pr.number // empty')
      case "$existing_state" in
        merged|locked)
          _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
          return 0
          ;;
        closed)
          _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
          echo "Error: forge-pr-merge: merge request $pr_ref is closed and was never merged." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: merge request $pr_ref is closed and was never merged."
          return 1
          ;;
        open) ;;
        *)
          _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
          echo "Error: forge-pr-merge: merge request $pr_ref has an unrecognized state: ${existing_state:-<empty>}." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: merge request $pr_ref has an unrecognized state: ${existing_state:-<empty>}."
          return 1
          ;;
      esac
      ;;
    not_found)
      _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
      echo "Error: forge-pr-merge: no merge request found for ref: $pr_ref" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: no merge request found for ref: $pr_ref"
      return 1
      ;;
    error|*)
      existing_message=$(printf '%s' "$existing" | jq -r '.message // empty')
      _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
      echo "Error: forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}"
      return 1
      ;;
  esac

  # WRITE (gitlab). -y FIRST. No flag for merge-commit style; -s/-r for
  # squash/rebase.
  local style_flag=""
  case "$style" in
    squash) style_flag="-s" ;;
    rebase) style_flag="-r" ;;
  esac

  local stdout="" stderr_out="" rc=0
  if [ -n "$style_flag" ]; then
    _forge_capture stdout stderr_out rc -- glab mr merge "$existing_number" -y "$style_flag" || true
  else
    _forge_capture stdout stderr_out rc -- glab mr merge "$existing_number" -y || true
  fi

  if [ "$rc" -ne 0 ]; then
    _forge_pr_merge_print_manual gitlab "$pr_ref" "$style"
    echo "Error: forge-pr-merge: glab mr merge exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "glab mr merge exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
}

# gitea adapter for forge-pr-merge. Same preflight-then-branch shape as the
# gitlab arm above, then shells `tea pulls merge <index> --style
# <merge|squash|rebase>` -- --style ALWAYS present, never optional, never
# defaulted, so `tea`'s NumFlags()-driven interactive-survey hazard
# (documented in the "Gitea write adapters" section header) cannot fire even
# though tea's own prompt behavior for `pulls merge` specifically remains
# unconfirmed (see this section's own header). No token prefix assignment:
# tea honours GH_TOKEN as well as GITEA_TOKEN, so a github-shaped prefix here
# would hand a GitHub token to a Gitea instance -- the same GH_TOKEN hazard
# every other tea write call in this file avoids.
_forge_pr_merge_gitea() {
  local pr_ref="$1" style="$2"

  if ! _forge_bin_check tea mandatory gitea; then
    _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
    _forge_emit_write_status degraded "" "tea not found -- this pull request was not merged automatically."
    return 1
  fi

  local existing="" existing_rc=0
  existing=$(cmd_forge_pr_view --pr "$pr_ref" --include number,url,state) || existing_rc=$?
  if [ "$existing_rc" -ne 0 ]; then
    _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
    echo "Error: forge-pr-merge: forge-pr-view lookup failed while resolving the pull request to merge (exit $existing_rc)." >&2
    _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view lookup failed while resolving the pull request to merge (exit $existing_rc)."
    return 1
  fi

  local existing_status existing_state existing_url existing_number existing_message
  existing_status=$(printf '%s' "$existing" | jq -r '.status')
  case "$existing_status" in
    found)
      existing_state=$(printf '%s' "$existing" | jq -r '.pr.state // empty')
      existing_url=$(printf '%s' "$existing" | jq -r '.pr.url // empty')
      existing_number=$(printf '%s' "$existing" | jq -r '.pr.number // empty')
      case "$existing_state" in
        merged|locked)
          _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
          return 0
          ;;
        closed)
          _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
          echo "Error: forge-pr-merge: pull request $pr_ref is closed and was never merged." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: pull request $pr_ref is closed and was never merged."
          return 1
          ;;
        open) ;;
        *)
          _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
          echo "Error: forge-pr-merge: pull request $pr_ref has an unrecognized state: ${existing_state:-<empty>}." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: pull request $pr_ref has an unrecognized state: ${existing_state:-<empty>}."
          return 1
          ;;
      esac
      ;;
    not_found)
      _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
      echo "Error: forge-pr-merge: no pull request found for ref: $pr_ref" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: no pull request found for ref: $pr_ref"
      return 1
      ;;
    error|*)
      existing_message=$(printf '%s' "$existing" | jq -r '.message // empty')
      _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
      echo "Error: forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}"
      return 1
      ;;
  esac

  # WRITE (gitea). --style ALWAYS present -- see this section's header.
  local stdout="" stderr_out="" rc=0
  _forge_capture stdout stderr_out rc -- tea pulls merge "$existing_number" --style "$style" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_merge_print_manual gitea "$pr_ref" "$style"
    echo "Error: forge-pr-merge: tea pulls merge exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "tea pulls merge exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
}

# Routing function for forge-pr-merge. Detects the forge, degrades
# no_adapter-style for anything but github/gitlab/gitea, routes gitlab/gitea
# to their self-contained adapters above under this file's usual `set -e`
# capture convention (`|| gl_rc=$?` / `|| gt_rc=$?`, mandatory because both
# adapters return 1 on every degraded branch by contract), and for github
# runs the preflight-then-merge sequence inline -- the same shape
# _forge_pr_create/_forge_pr_edit use for their own github arm.
#
# ROUTED, GITHUB ONLY: both the preflight cmd_forge_pr_view call and the
# `gh pr merge` call are routed under the resolved account-override prefix
# assignment, resolved ONCE for both -- the identical pattern
# _forge_pr_create/_forge_pr_edit already use, and for the identical reason:
# on a private repository the account that merges can see (and act on) a PR
# a different reader account cannot, so a preflight performed as the machine
# account could disagree with the account the merge itself runs as.
_forge_pr_merge() {
  local pr_ref="$1" style="$2"
  local forge=""
  _detect_forge_type forge

  case "$forge" in
    github) ;;
    gitlab)
      local gl_rc=0
      _forge_pr_merge_gitlab "$pr_ref" "$style" || gl_rc=$?
      return "$gl_rc"
      ;;
    gitea)
      local gt_rc=0
      _forge_pr_merge_gitea "$pr_ref" "$style" || gt_rc=$?
      return "$gt_rc"
      ;;
    *)
      _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
      _forge_emit_write_status degraded "" "forge-pr-merge: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 1
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
    _forge_emit_write_status degraded "" "gh not found -- this pull request was not merged automatically."
    return 1
  fi

  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  local existing="" existing_rc=0
  existing=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    cmd_forge_pr_view --pr "$pr_ref" --include number,url,state) || existing_rc=$?
  if [ "$existing_rc" -ne 0 ]; then
    _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
    echo "Error: forge-pr-merge: forge-pr-view lookup failed while resolving the pull request to merge (exit $existing_rc)." >&2
    _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view lookup failed while resolving the pull request to merge (exit $existing_rc)."
    return 1
  fi

  local existing_status existing_state existing_url existing_number existing_message
  existing_status=$(printf '%s' "$existing" | jq -r '.status')
  case "$existing_status" in
    found)
      existing_state=$(printf '%s' "$existing" | jq -r '.pr.state // empty')
      existing_url=$(printf '%s' "$existing" | jq -r '.pr.url // empty')
      existing_number=$(printf '%s' "$existing" | jq -r '.pr.number // empty')
      case "$existing_state" in
        merged|locked)
          _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
          return 0
          ;;
        closed)
          _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
          echo "Error: forge-pr-merge: pull request $pr_ref is closed and was never merged." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: pull request $pr_ref is closed and was never merged."
          return 1
          ;;
        open) ;;
        *)
          _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
          echo "Error: forge-pr-merge: pull request $pr_ref has an unrecognized state: ${existing_state:-<empty>}." >&2
          _forge_emit_write_status degraded "" "forge-pr-merge: pull request $pr_ref has an unrecognized state: ${existing_state:-<empty>}."
          return 1
          ;;
      esac
      ;;
    not_found)
      _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
      echo "Error: forge-pr-merge: no pull request found for ref: $pr_ref" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: no pull request found for ref: $pr_ref"
      return 1
      ;;
    error|*)
      existing_message=$(printf '%s' "$existing" | jq -r '.message // empty')
      _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
      echo "Error: forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}" >&2
      _forge_emit_write_status degraded "" "forge-pr-merge: forge-pr-view reported an error while resolving $pr_ref: ${existing_message:-unknown error}"
      return 1
      ;;
  esac

  # WRITE (github). Flag chosen 1:1 from --style: -m for merge, -s for
  # squash, -r for rebase. Same prefix-assignment shape as every other
  # routed gh write in this file: on the _forge_capture call itself, never
  # inside its argv, never via `env`.
  local style_flag=""
  case "$style" in
    merge)  style_flag="-m" ;;
    squash) style_flag="-s" ;;
    rebase) style_flag="-r" ;;
  esac

  local stdout rc=0 stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh pr merge "$existing_number" "$style_flag" || true

  if [ "$rc" -ne 0 ]; then
    _forge_pr_merge_print_manual "$forge" "$pr_ref" "$style"
    echo "Error: forge-pr-merge: gh pr merge exited $rc: ${stderr_out:-unknown error}" >&2
    _forge_emit_write_status degraded "" "gh pr merge exited $rc: ${stderr_out:-unknown error}"
    return 1
  fi

  _forge_emit_write_status unchanged "$(_forge_build_write_data "$existing_url" "$existing_number")"
}

# Public wrapper: parses --pr/--style/--project (deliberately no --token or
# similarly credential-shaped flag). --pr and --style are BOTH REQUIRED, and
# the usage check for them runs BEFORE _require_git_repo -- a deliberate
# ordering DIFFERENCE from forge-pr-create/forge-pr-edit's own guards (which
# run _require_git_repo first): a merge's identifying flags are cheap to
# check and a caller that forgot one should not pay for a git-repo probe
# first to learn that. --style is validated against the closed
# {merge, squash, rebase} enum and --pr against forge-pr-view's own
# combined numeric-or-branch-name regex, both before _require_git_repo runs
# and before either is ever interpolated into a git/gh/glab/tea invocation.
# Delegates exactly once to _forge_pr_merge.
cmd_forge_pr_merge() {
  check_jq

  local pr_ref="" style="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)      shift; pr_ref="${1:-}" ;;
      --style)   shift; style="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-merge: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -z "$pr_ref" ] || [ -z "$style" ]; then
    echo "Usage: aimi-cli.sh forge-pr-merge --pr <branch-or-number> --style <merge|squash|rebase> [--project <path>]" >&2
    exit 1
  fi

  case "$style" in
    merge|squash|rebase) ;;
    *)
      echo "Error: forge-pr-merge: invalid --style value: $style -- must be merge, squash or rebase." >&2
      exit 1
      ;;
  esac

  # Validate --pr before it is ever interpolated into a git/gh/glab/tea
  # invocation -- the exact combined regex cmd_forge_pr_view already applies
  # to its own --pr flag.
  if ! [[ "$pr_ref" =~ ^[0-9]+$ ]] && ! [[ "$pr_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: forge-pr-merge: invalid --pr value: $pr_ref" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  _forge_pr_merge "$pr_ref" "$style"
}

# ============================================================================
# Forge Issue Verbs — forge-issue-view, forge-issue-create (US-006)
# ============================================================================
# The first forge-* verbs in this phase to actually shell out to a forge
# CLI. Built entirely on US-002's shared builders/degradation gate
# (_forge_build_issue_json, _forge_emit_status, _forge_bin_check) and
# US-001's detect-forge -- neither is re-derived here.
#
# INVARIANT, stated here and again on cmd_forge_issue_create below because
# it is the whole reason this pair exists: a failed or degraded issue
# creation must NEVER be treated by a caller as a reason to block PR
# creation. open-pr.md:481 already documents this in prose ("a warning is
# logged but PR creation is NOT affected -- the backend spec still lives in
# the PR body"); forge-issue-create's JSON `status` field (never its exit
# code, which stays 0 on every syntactically valid call -- see below) is
# what lets a future caller preserve that behavior once it migrates off a
# raw `gh issue create` shell-out.
#
# GitHub was the only adapter in phase 1. Phase 3 added GitLab and phase 4
# added Gitea, to the READ verb (forge-issue-view -> `glab issue view <n> -F
# json` / `tea issues <n> -o json`) AND to forge-issue-create itself
# (_forge_issue_create_gitlab / _forge_issue_create_gitea), so this verb is no
# longer GitHub-only. A detected forge with no adapter still degrades exactly
# like a missing CLI binary rather than attempting a call that could only
# fail.

# Forge-native issue/PR state strings, normalized per forge-contract.md's
# "State Mapping" table. Case-folded first because GitHub's gh CLI returns
# OPEN/CLOSED/MERGED in uppercase while GitLab/Gitea's APIs are lowercase.
# Once case-folded, every cell in that table already agrees across all
# three forges EXCEPT GitLab's "opened", which has no "open"-spelled
# sibling anywhere else -- that is the one and only translation this
# function performs. GitLab's "locked" has no GitHub or Gitea/Forgejo
# equivalent and passes through unchanged rather than being collapsed into
# "merged" (collapsing would silently discard a real GitLab-only signal).
# An unrecognized forge, or a raw value this table does not name, passes
# through case-folded and otherwise untouched -- this function normalizes
# spelling, it never invents a value the source data did not provide.
# Usage: _forge_map_state <forge: github|gitlab|gitea> <raw-state>
_forge_map_state() {
  local forge="$1" raw
  raw=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')

  if [ "$forge" = "gitlab" ] && [ "$raw" = "opened" ]; then
    printf 'open'
    return 0
  fi

  printf '%s' "$raw"
}

# Extracts the trailing issue number from a GitHub issue URL
# (https://github.com/<owner>/<repo>/issues/<n>, optionally followed by a
# path/query/fragment). Prints empty on a non-matching URL rather than
# guessing -- cmd_forge_issue_view treats an empty result as a caller-input
# error, never a silent zero.
_forge_extract_issue_number_from_url() {
  local url="$1"
  if [[ "$url" =~ /issues/([0-9]+)([/?#].*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Shells `gh issue view <n> --json number,title,body,labels,state,url,
# comments`. `comments` is requested in addition to the field list this
# story's own prose quotes, specifically so unsupported_fields comes back
# [] on GitHub: forge-contract.md's issue object treats comments as the
# ONE capability-gated field, and GitHub can supply it cheaply (a comment
# COUNT, derived here from the length of gh's own comments array) -- only
# GitLab's noisier discussion model and tea's uncertain counting semantics
# keep it capability-gated at all. `labels` is not in forge-contract.md's
# issue field table today -- GitHub/GitLab/Gitea all expose it as a
# portable-core concept, so it rides alongside _forge_build_issue_json's
# output via a jq merge rather than waiting on a contract-doc update this
# story does not own.
#
# QUIET degrade mode throughout (forge-contract.md's Degradation
# Contract): a missing gh, an unauthenticated session, and any other gh
# failure all resolve to status "error" with NO stderr output --
# validate-bug.md's free-text-description fallback (the caller this verb
# was built for) must not gain a spurious warning it does not have today.
#
# Not-found is a query result, never a verb failure (mirrors split-detect
# and verify-creates): gh conflates "no such issue" and "tool is broken"
# into the same non-zero exit, so gh's own stderr text is pattern-matched
# here to tell the two apart BEFORE calling _forge_emit_status -- the same
# discipline roadmap.py's verify_creates_one already applies to git's ambiguous exit
# codes. (The AC's "found (boolean)" language maps onto this three-way
# `status` field: status=="found" is the found:true case, status==
# "not_found" is the found:false case -- forge-contract.md's Three-Way
# Status Convention is the single arbiter of this vocabulary and already
# names forge-issue-view as one of its consumers, so no second/variant
# "found" field is introduced alongside it.)
#
# Always returns 0 -- found/not_found/error are three data outcomes, not
# three exit codes. cmd_forge_issue_view (the public wrapper) is the only
# layer that can exit non-zero, and only for a caller-side usage error.
_forge_issue_view() {
  local number="$1"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) purely
  # so the generic-failure branch below can hand it to the shared classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      # Names glab, never gh -- the phase contract's fourth success criterion.
      _forge_emit_status error "" "glab not found -- this issue lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_issue_view_gitlab "$number" "$host"
    return 0
  fi

  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      # Names tea, never gh -- the phase contract's fourth success criterion.
      _forge_emit_status error "" "tea not found -- this issue lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_issue_view_gitea "$number" "$host"
    return 0
  fi

  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-issue-view: no adapter for forge \"$forge\" yet -- github, gitlab and gitea are the adapters available today." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this issue lookup did not run automatically." cli_missing
    return 0
  fi

  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- gh issue view "$number" --json number,title,body,labels,state,url,comments || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json comments_count data
    num=$(printf '%s' "$stdout" | jq -r '.number // empty')
    title_val=$(printf '%s' "$stdout" | jq -r '.title // ""')
    body_val=$(printf '%s' "$stdout" | jq -r '.body // ""')
    url_val=$(printf '%s' "$stdout" | jq -r '.url // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r '.state // ""')
    state_norm=$(_forge_map_state "$forge" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[].name]')
    comments_count=$(printf '%s' "$stdout" | jq -c '(.comments // []) | length')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --comments "$comments_count" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  if printf '%s' "$stderr_out" | grep -qi "Could not resolve to an issue or pull request"; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found stderr match above already failed, so
  # gh genuinely broke. gh's presence was confirmed by the _forge_bin_check
  # gate above, so the classifier only has to separate not_authenticated
  # from cli_failed -- cli_missing is already ruled out.
  local reason
  reason=$(_forge_classify_gh_failure_reason "$host")
  _forge_emit_status error "" "gh issue view exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# gitlab adapter for forge-issue-view. Same three-way found/not_found/error
# envelope (_forge_emit_status), same shared issue builder
# (_forge_build_issue_json), same quiet degrade posture -- only the CLI, the
# key vocabulary and the not-found signal differ.
#
# `-F json`, NOT a gh-style `--json <field-list>`. `glab issue view` offers
# `-F, --output string  Format output as: text, json` plus `--jq string`
# and no field selector at all (docs/source/issue/view.md), and its JSON path
# marshals go-gitlab's *gitlab.Issue whole. So the call asks for the whole
# document and this function picks keys out of it.
#
# THE KEYS COME FROM _forge_map_pr_field_gitlab, NOT FROM A SECOND HAND-
# WRITTEN TABLE HERE. GitLab spells the five portable-core contract fields
# identically on an issue and on a merge request -- `iid`, `web_url`,
# `title`, `description`, `state` are struct tags on BOTH *gitlab.Issue and
# *gitlab.MergeRequest -- so reusing that one table is what keeps this call
# site from hard-coding GitLab key names of its own. That coincidence is not
# left to trust: test-aimi-cli.sh asserts each of the five mapper answers
# against a realistic `glab issue view -F json` document, so a future edit
# that made the MR table diverge fails there rather than silently here. The
# MR-only fields (headRefName/baseRefName/isDraft/mergeable/files) are simply
# never asked for.
#
# `comments` IS DELIBERATELY NOT SUPPLIED, so it comes back null AND named in
# unsupported_fields. forge-contract.md makes `comments` the issue object's
# one capability-gated field precisely because GitLab's discussion model does
# not answer the same question GitHub's flat comment array does; a count
# invented from a differently-shaped resource would be a guess. Reporting it
# absent is the contract's own mechanism for exactly this.
#
# `labels` rides alongside the builder's output via a jq merge, the same way
# the github arm adds it. GitLab returns labels as an array of plain STRINGS
# (go-gitlab `Labels []string json:"labels"`) where GitHub returns objects
# with a `.name`; the expression below accepts either shape rather than
# assuming one, so a label list is never silently dropped.
#
# VERIFICATION CEILING: glab is not installed on the machine this was written
# on. Same declared ceiling as _forge_map_pr_field_gitlab's header.
_forge_issue_view_gitlab() {
  local number="$1" host="${2:-}"
  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- glab issue view "$number" -F json || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json data
    num=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab number)" '.[$k] // empty')
    title_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab title)" '.[$k] // ""')
    body_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab body)" '.[$k] // ""')
    url_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab url)" '.[$k] // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitlab state)" '.[$k] // ""')
    # Key mapping and VALUE normalization are separate jobs: this is where
    # GitLab's "opened" becomes the contract's "open".
    state_norm=$(_forge_map_state "gitlab" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[] | if type == "object" then .name else . end]')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  # not_found is a query RESULT, never a verb failure -- the same distinction
  # the github arm draws. glab surfaces a missing issue as the API's own 404.
  if printf '%s' "$stderr_out" | grep -qiE '404|not found'; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found match above already failed, so glab
  # genuinely broke. glab's presence was confirmed by the caller's own
  # _forge_bin_check gate, so cli_missing is already ruled out and only
  # not_authenticated vs cli_failed remains. Determined STRUCTURALLY, by
  # asking _forge_auth_status_gitlab whether there is a session at all --
  # never by pattern-matching glab's failure wording, which is translatable
  # and rewordable. Anything short of a definite "authenticated: false"
  # resolves to cli_failed, the safe direction for an already-known failure.
  local reason="cli_failed" auth_json authenticated
  auth_json=$(_forge_auth_status_gitlab "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""
  if [ "$authenticated" = "false" ]; then
    reason="not_authenticated"
  fi
  _forge_emit_status error "" "glab issue view exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# gitea adapter for forge-issue-view. Same three-way found/not_found/error
# envelope (_forge_emit_status), same shared issue builder
# (_forge_build_issue_json), same quiet degrade posture -- only the CLI, the
# key vocabulary and the not-found signal differ.
#
# `tea issues <index> -o json` is the DETAIL form (cmd/issues.go's `issueData`
# struct: id, index, title, state, created, labels[], user, body,
# assignees[], url, closedAt, comments[]). No `-f`, and no gh-style
# `--json <field-list>`: tea's `-f` selector lives on the LIST path only, and
# the detail path emits a fixed projection.
#
# THE KEYS COME FROM _forge_map_pr_field_gitea, NOT FROM A SECOND HAND-
# WRITTEN TABLE HERE -- the same reuse _forge_issue_view_gitlab makes, and
# for the same reason. Gitea spells the five portable-core contract fields
# identically on an issue and on a pull request: `index`, `url`, `title`,
# `body` and `state` are struct fields on BOTH `pullData` and `issueData`.
# The PR-only fields (headRefName/baseRefName/isDraft/mergeable/files) are
# simply never asked for.
#
# `comments` IS DELIBERATELY NOT SUPPLIED, so it comes back null AND named in
# unsupported_fields. This is not caution about tea's counting semantics
# alone -- it is a data fact: `issueData.Comments` is an ARRAY that is
# populated ONLY when `--comments` is passed (cmd/issues.go:148-154), and is
# an EMPTY ARRAY otherwise. Deriving a count from its length here would
# report `comments: 0` for every issue in existence. A wrong count is worse
# than a declared absence, and the contract's unsupported_fields array is the
# mechanism for exactly this.
#
# `labels` rides alongside the builder's output via a jq merge, the same way
# the github and gitlab arms add it, and through the same either-shape
# expression: tea's own printer can hand back plain strings while the API
# object carries `{name}`, so accepting either is what keeps a label list
# from being silently dropped.
#
# THERE IS DELIBERATELY NO STRUCTURAL not_found PROBE HERE, unlike
# _forge_pr_view_gitea, and this is a recorded decision rather than an
# oversight so it is not later "improved" into a scan: `tea issues list` is
# PAGINATED (--page/--limit) and has no index filter at all, so a local scan
# of one page could report a real issue as missing. A FALSE not_found is the
# one outcome that must never be invented, and a paginated scan can invent
# it. So absence is claimed only on a POSITIVE 404/not-found stderr match,
# and every other failure resolves to error -- falling through in the SAFE
# direction, which is the same rule the pr-view arm applies to an
# unparseable probe.
#
# NO CREDENTIAL IS BOUND ON ANY INVOCATION HERE -- see
# _forge_auth_status_gitea's header for why a GH_TOKEN prefix assignment on a
# `tea` call would be a real leak rather than a hypothetical one.
#
# VERIFICATION CEILING: `tea` is NOT INSTALLED on the machine this was
# written on. Every flag, subcommand and JSON key above was read off
# `gitea/tea` `main` source on 2026-08-06 and has never been observed coming
# out of the real binary. The tests prove WHICH ARGV this function emits and
# HOW it parses a fixture -- never what real `tea` does with them.
_forge_issue_view_gitea() {
  local number="$1" host="${2:-}"
  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- tea issues "$number" -o json || true

  if [ "$rc" -eq 0 ]; then
    local num title_val body_val url_val state_raw state_norm labels_json data
    num=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea number)" '.[$k] // empty')
    title_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea title)" '.[$k] // ""')
    body_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea body)" '.[$k] // ""')
    url_val=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea url)" '.[$k] // ""')
    state_raw=$(printf '%s' "$stdout" | jq -r --arg k "$(_forge_map_pr_field_gitea state)" '.[$k] // ""')
    # Key mapping and VALUE normalization are separate jobs. There is no
    # hasMerged derivation on this path and there must not be: an ISSUE is
    # never merged, so _forge_map_state's plain case-fold is the whole job.
    state_norm=$(_forge_map_state "gitea" "$state_raw")
    labels_json=$(printf '%s' "$stdout" | jq -c '[(.labels // [])[] | if type == "object" then .name else . end]')
    data=$(_forge_build_issue_json --number "$num" --url "$url_val" --title "$title_val" \
      --body "$body_val" --state "$state_norm" --raw "$stdout")
    data=$(printf '%s' "$data" | jq -c --argjson labels "$labels_json" '. + {labels: $labels}')
    _forge_emit_status found "$data"
    return 0
  fi

  # not_found is a query RESULT, never a verb failure -- the same distinction
  # the github and gitlab arms draw. A POSITIVE match is required; see the
  # header for why nothing weaker may claim absence on this path.
  if printf '%s' "$stderr_out" | grep -qiE '404|not found'; then
    _forge_emit_status not_found
    return 0
  fi

  # Reached only after the not-found match above already failed, so tea
  # genuinely broke. tea's presence was confirmed by the caller's own
  # _forge_bin_check gate, so cli_missing is already ruled out and only
  # not_authenticated vs cli_failed remains. Determined STRUCTURALLY, by
  # asking _forge_auth_status_gitea whether a login entry for this host
  # exists at all -- never by pattern-matching tea's failure wording, which
  # is translatable and rewordable. That adapter returns NON-ZERO when it
  # could not read the login list, which lands here as an empty $auth_json
  # and therefore cli_failed: anything short of a definite
  # "authenticated: false" resolves to cli_failed, the safe direction for an
  # already-known failure.
  local reason="cli_failed" auth_json authenticated
  auth_json=$(_forge_auth_status_gitea "$host" 2>/dev/null) || auth_json=""
  authenticated=$(printf '%s' "$auth_json" | jq -r '.authenticated' 2>/dev/null) || authenticated=""
  if [ "$authenticated" = "false" ]; then
    reason="not_authenticated"
  fi
  _forge_emit_status error "" "tea issues exited $rc: ${stderr_out:-unknown error}" "$reason"
  return 0
}

# Public wrapper: parses --number/--url/--project, validates the numeric
# identifier BEFORE it is ever interpolated into a gh command (mirroring
# the branchName-validation posture in plugins/aimi-engineering/CLAUDE.md's
# Security Requirements), confirms the git-repository guard the same way
# detect-forge/detect-parent-branch/detect-default-branch already do (gh
# infers which repo to query from cwd's remote; there is no --repo flag
# here), then delegates exactly once to _forge_issue_view.
#
# Routing note for the later validate-bug.md migration (recorded here so
# that story does not have to re-derive it): validate-bug.md's plain-
# issue-number branch and its GitHub-issue-URL branch both route to THIS
# verb; its PR-URL branch (validate-bug.md:39) routes to forge-pr-view
# instead, even though it requests an identical field set, because it
# reads a pull request, not an issue.
cmd_forge_issue_view() {
  check_jq

  local number="" url="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --number)  shift; number="${1:-}" ;;
      --url)     shift; url="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-issue-view: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$number" ] && [ -n "$url" ]; then
    number=$(_forge_extract_issue_number_from_url "$url")
    if [ -z "$number" ]; then
      echo "Error: forge-issue-view: could not extract an issue number from --url: $url" >&2
      exit 1
    fi
  fi

  if [ -z "$number" ]; then
    echo "Error: forge-issue-view: --number <n> or --url <issue-url> is required" >&2
    exit 1
  fi

  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-issue-view: --number must be a positive integer (got: $number)" >&2
    exit 1
  fi

  _forge_issue_view "$number"
}

# Prints the MANDATORY manual-fallback instruction (forge-contract.md's
# Degradation Contract, mandatory mode) for every forge-issue-create
# failure path -- missing gh, unauthenticated session, or the create call
# itself failing all funnel through this one function so the instruction
# is worded identically regardless of WHY automatic creation did not
# happen. Always stderr, never stdout, so a caller consuming this verb's
# JSON result on stdout never has to filter prose out of its own data.
_forge_issue_create_print_manual() {
  local title="$1" body="$2" forge="$3"
  {
    echo "Warning: could not create this $forge issue automatically -- create it yourself with:"
    echo "  Title: $title"
    echo "  Body:"
    printf '%s\n' "$body" | sed 's/^/    /'
  } >&2
}

# Shells `gh issue create --title <t> --body <b>`, capturing stdout as the
# created issue's URL -- gh issue create has NO --json flag (confirmed:
# unlike gh issue view/gh pr view, only a plain URL reaches stdout on
# success) -- and deriving the issue number from that URL itself, the same
# grep -oE '[0-9]+$' open-pr.md:464 does today, centralized and tested here
# exactly once so open-pr.md's later migration (story 08) can drop its own
# copy.
#
# MANDATORY-PRINT degrade mode (forge-contract.md's Degradation Contract):
# unlike forge-issue-view's quiet read, this write verb has no fallback
# path of its own, so every failure -- missing gh, unauthenticated
# session, the create call itself failing (permissions denied, issues
# disabled, rate limit), or an unparseable success response -- prints the
# manual "create this yourself" instruction via
# _forge_issue_create_print_manual.
#
# RESULT ENVELOPE: this verb SHARES aimi-cli.sh's one write-verb envelope
# with forge-pr-create and forge-pr-edit -- forge-contract.md's Write-Verb
# Status Convention, built here by the same _forge_emit_write_status
# function those two call, with url and number nested under `data` exactly
# as they are there. It used to maintain a deliberately separate two-value
# (created|degraded) vocabulary with flat sibling url/number keys; there is
# no longer any reason for a caller to learn a second shape to read this
# verb's answer.
#
# What still distinguishes this envelope from forge-contract.md's READ-side
# found/not_found/error trio is unchanged and correct: a write genuinely has
# no "not found" outcome, since nothing was looked up. That is the reason
# the write side has its own three values, not a reason for each write verb
# to have its own.
#
# CONTRACT INVARIANT: printing that instruction is NEVER a hard failure.
# This function always returns 0 -- on EVERY branch, degraded included; its
# JSON result's `status` field is what a caller branches on -- see the
# section header above and cmd_forge_issue_create below for the full
# statement of why (open-pr.md:481's existing soft-fail behavior must
# survive unchanged). Sharing the envelope with forge-pr-create/
# forge-pr-edit deliberately does NOT share their exit-code contract: those
# two exit non-zero on a degraded outcome, this one never does.
_forge_issue_create() {
  local title="$1" body="$2"
  local forge=""
  _detect_forge_type forge

  # Same routing shape as the two pr verbs, with this verb's OWN exit-code
  # contract preserved: the gitlab arm, like everything else here, always
  # returns 0 and reports the outcome in the envelope's `status` field.
  case "$forge" in
    github) ;;
    gitlab)
      _forge_issue_create_gitlab "$title" "$body"
      return 0
      ;;
    gitea)
      _forge_issue_create_gitea "$title" "$body"
      return 0
      ;;
    *)
      _forge_issue_create_print_manual "$title" "$body" "$forge"
      _forge_emit_write_status degraded "" "forge-issue-create: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters."
      return 0
      ;;
  esac

  if ! _forge_bin_check gh mandatory "$forge"; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh not found -- this issue was not created automatically."
    return 0
  fi

  # Resolved once, then applied to the one gh call this verb makes -- this path
  # has no in-operation read (the issue number is parsed from the URL gh
  # itself printed, never re-queried). See the ROUTING RULE block above the
  # forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # WRITE 3. Identical prefix-assignment shape to WRITE 1 and WRITE 2.
  local stdout rc=0
  local stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh issue create --title "$title" --body "$body" || true

  if [ "$rc" -ne 0 ]; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh issue create exited $rc: ${stderr_out:-unknown error}"
    return 0
  fi

  local issue_url issue_number
  issue_url=$(printf '%s' "$stdout" | tail -n1 | tr -d '\r')
  issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || true)

  if [ -z "$issue_url" ] || [ -z "$issue_number" ]; then
    _forge_issue_create_print_manual "$title" "$body" "$forge"
    _forge_emit_write_status degraded "" "gh issue create succeeded but its output did not contain a parseable issue URL: ${issue_url:-<empty>}"
    return 0
  fi

  _forge_emit_write_status created "$(_forge_build_write_data "$issue_url" "$issue_number")"
}

# Public wrapper: parses --title/--body/--project (deliberately no --token
# or similarly credential-shaped flag -- see forge-contract.md's
# Credential/Identity Model), confirms the git-repository guard, then
# delegates exactly once to _forge_issue_create.
#
# HOW THE ACTING ACCOUNT REACHES gh, now that phase 2 has landed: only ever
# through an environment variable, never a flag. A GH_TOKEN a caller exported
# before invoking this CLI is inherited by the child gh process with no code
# here to pass it along; this repository's own remembered account is applied by
# _forge_issue_create as a bash prefix assignment on the single `gh issue
# create` call, which never enters argv and never outlives that call. This
# paragraph used to state the inheritance half as the whole story and point at
# the second half as future work.
#
# INVARIANT (restated from the section header on purpose, not left
# implicit): a degraded or failed issue creation from this verb must NEVER
# be read by a caller as a reason to block PR creation. open-pr.md:481
# already documents this soft-fail behavior in prose; this verb's `status`
# field is what lets a future caller preserve it.
cmd_forge_issue_create() {
  check_jq

  local title="" body="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --title)   shift; title="${1:-}" ;;
      --body)    shift; body="${1:-}" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-issue-create: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$title" ]; then
    echo "Error: forge-issue-create: --title <text> is required" >&2
    exit 1
  fi

  _forge_issue_create "$title" "$body"
}

# ============================================================================
# Forge Review-Thread Verbs — forge-pr-review-threads, forge-resolve-review-thread (US-007)
# ============================================================================
# Ports skills/resolve-pr-parallel/scripts/get-pr-comments's reviewThreads
# query and skills/resolve-pr-parallel/scripts/resolve-pr-thread's
# resolveReviewThread mutation into aimi-cli.sh -- the only two GraphQL call
# sites in this repository. Every identifier these two GraphQL documents
# consume (owner, repo, PR number, thread id) is bound through `gh api
# graphql`'s own -f/-F flags, never interpolated into the query text -- the
# same class of hand-built string this codebase's `jq -nc --arg` convention
# already prevents everywhere else, applied here to gh's own binding
# mechanism instead of jq.
#
# NOTE on the two query/mutation constants below: they are single-quoted
# verbatim ports and DO contain literal `$owner`, `$repo`, `$pr`, `$threadId`
# characters -- that is GraphQL's own variable-reference syntax (declared in
# each operation's signature, e.g. `($owner: String!)`, and bound externally
# by gh via -f/-F), not shell interpolation. Bash never expands anything
# inside a single-quoted string, so those tokens reach gh as inert literal
# text; nothing in this file ever substitutes a shell variable into either
# string. The actual security property enforced here (and asserted by this
# story's own tests) is that neither string ever contains a BASH-style
# expansion (`$(`, a backtick, or `${`) and that the gh invocations below
# bind owner/repo/pr/threadId ONLY via -f/-F flags -- never by building the
# query/mutation text with string concatenation or double-quoted
# interpolation.
#
# Built entirely on US-001's detect-forge (direct function call), US-002's
# shared degradation gate and generic three-way status envelope
# (_forge_bin_check, _forge_emit_status -- forge-contract.md is the single
# arbiter; no variant field-name casing or second degraded-reason field is
# introduced here), and US-003's forge-repo-info (direct function call,
# never a subprocess) for owner/repo auto-detection -- replacing
# get-pr-comments:14-20's own inline OWNER/REPO detection.
#
# forge-pr-review-threads is a READ verb: three-way found/not_found/error,
# QUIET degrade mode throughout (matches forge-issue-view's own posture --
# a caller must not gain a spurious warning it does not have today). A null
# GraphQL `pullRequest` is a confirmed not_found, never folded into error.
#
# forge-resolve-review-thread is a WRITE verb with NO fallback path (there
# is no gh subcommand or REST endpoint for resolving a review thread), so it
# follows forge-issue-create's MANDATORY-PRINT posture, but unlike forge-
# issue-create it distinguishes a CONFIRMED negative (the mutation ran;
# GraphQL says the thread id is invalid or inaccessible) from a
# could-not-attempt negative (gh missing, unsupported forge, or gh itself
# exiting non-zero for auth/network reasons). The confirmed negative reuses
# status="found" with a false `resolved` field -- the same pattern forge-
# auth-status already uses for a confirmed authenticated:false, per forge-
# contract.md's Three-Way Status Convention: a definitive answer is still a
# successful lookup, not an error. status="error" is reserved for the
# could-not-attempt case. _forge_resolve_review_thread itself always stays
# QUIET (JSON only, exit 0) so it is safely testable in isolation;
# cmd_forge_resolve_review_thread (the public wrapper) is the ONLY layer
# that prints the mandatory manual instruction and exits non-zero, driven
# purely by the JSON status field.

# Private helper holding the reviewThreads query, ported verbatim from
# get-pr-comments:27-68 (query body only -- the `gh api graphql -f owner=...
# -f query='` wrapper and the trailing `.data...edges | map(select(...))`
# jq pipeline are NOT part of the query text and live in
# _forge_pr_review_threads_github/_forge_pr_review_threads below instead,
# now expressed as a jq filter over the raw GraphQL response rather than a
# second external jq process piped from gh's own stdout).
_forge_review_threads_query() {
  printf '%s' '
query FetchReviewThreads($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      title
      url
      reviewThreads(first: 100) {
        totalCount
        edges {
          node {
            id
            isResolved
            isOutdated
            isCollapsed
            path
            line
            startLine
            diffSide
            comments(first: 100) {
              totalCount
              nodes {
                id
                author {
                  login
                }
                body
                createdAt
                updatedAt
                url
                outdated
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}'
}

# Private helper holding the resolveReviewThread mutation, ported verbatim
# from resolve-pr-thread:13-23.
_forge_resolve_review_thread_mutation() {
  printf '%s' '
mutation ResolveReviewThread($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      id
      isResolved
      path
      line
    }
  }
}'
}

# github adapter for forge-pr-review-threads. <pr_number>/<owner>/<repo> are
# already validated by cmd_forge_pr_review_threads before this ever runs;
# <all_threads> is the literal string "true"/"false". Binds owner/repo/pr
# via -f/-F only -- see the section header above for why the query text
# still contains literal `$owner`/`$repo`/`$pr` (GraphQL's own variable
# syntax, inert under bash single-quoting).
_forge_pr_review_threads_github() {
  local pr_number="$1" owner="$2" repo="$3" all_threads="$4" host="${5:-}"
  local stdout rc=0
  local stderr_out

  _forge_capture stdout stderr_out rc -- gh api graphql -f owner="$owner" -f repo="$repo" -F pr="$pr_number" \
    -f query="$(_forge_review_threads_query)" || true

  if [ "$rc" -ne 0 ]; then
    # gh's presence was already confirmed by the caller's _forge_bin_check
    # gate, so the classifier only separates not_authenticated from
    # cli_failed -- structurally, never by reading stderr_out's wording.
    local reason
    reason=$(_forge_classify_gh_failure_reason "$host")
    _forge_emit_status error "" "gh api graphql exited $rc: ${stderr_out:-unknown error}" "$reason"
    return 0
  fi

  local pr_present
  pr_present=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest // empty')
  if [ -z "$pr_present" ]; then
    _forge_emit_status not_found
    return 0
  fi

  local title url all_flag_json threads_json
  title=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest.title // ""')
  url=$(printf '%s' "$stdout" | jq -r '.data.repository.pullRequest.url // ""')
  if [ "$all_threads" = "true" ]; then all_flag_json=true; else all_flag_json=false; fi

  # Collapses the edges/node GraphQL wrapper away (it carries no
  # caller-visible data of its own) and, without --all, filters to
  # isResolved==false and isOutdated==false -- matching get-pr-comments:68's
  # existing filter exactly.
  threads_json=$(printf '%s' "$stdout" | jq -c --argjson all "$all_flag_json" '
    [.data.repository.pullRequest.reviewThreads.edges[].node]
    | (if $all then . else map(select(.isResolved == false and .isOutdated == false)) end)
  ')

  local data_json
  data_json=$(jq -nc \
    --arg number "$pr_number" \
    --arg title "$title" \
    --arg url "$url" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber),
           title: (if $title == "" then null else $title end),
           url: (if $url == "" then null else $url end)},
      threads: $threads,
      unsupported_fields: []
    }')
  _forge_emit_status found "$data_json"
}

# gitlab adapter for forge-pr-review-threads (phase 3). <iid> is already
# validated as a positive integer by cmd_forge_pr_review_threads before this
# ever runs; <all_threads> is the literal string "true"/"false".
#
# glab's own documentation marks `glab mr note list` as EXPERIMENTAL and
# possibly unstable ("This feature is an experiment and is not ready for
# production use. It might be unstable or removed at any time.",
# docs/source/mr/note/list.md) -- disclosed here so a caller relying on this
# verb on GitLab knows the upstream tool does not yet consider it settled.
#
# VERIFICATION CEILING: glab was NOT installed on the machine this was
# written on, exactly as _forge_map_pr_field_gitlab's header already records
# for the same phase. Every flag and every JSON key below is read off glab's
# own documentation (docs/source/mr/note/list.md, whose examples pin both the
# array shape -- `glab mr note list -F json | jq '.[].notes[].body'` -- and
# the full-id extraction -- `jq -r '.[].id'`) and GitLab's Discussions API,
# never observed coming out of the real binary.
#
# VOCABULARY BOUNDARY. GitLab calls the unit a DISCUSSION; the normalized
# contract calls it a THREAD. That translation happens here and nowhere
# else: the word `discussion` must never reach the emitted envelope, whose
# key stays `threads` with GitHub's own per-thread field names.
#
# THE FILTER IS SERVER-SIDE, ON PURPOSE. `--state` (all|resolved|
# unresolved) is glab's own resolution-state filter, so the default call
# asks GitLab for the unresolved discussions instead of fetching everything
# and dropping the resolved ones locally. --all maps to `--state all`,
# matching the github adapter's "include what a plain call filters out".
#
# --owner/--repo ARE DELIBERATELY NOT FORWARDED. They are gh's flat
# owner/repo pair; a GitLab project is a nested group path
# (group/subgroup/project) that pair cannot express, and glab's own
# equivalent is a single `-R <full/path>` string. Rather than lossily
# rebuild one from the other, this adapter targets the repository the
# current working directory's remote already points at -- the same
# repository _detect_forge classified to get here.
#
# CAPABILITY GAPS, all reported through unsupported_fields per forge-
# contract.md ("An unpopulated capability-gated field is ALWAYS represented
# as null PLUS its name recorded in unsupported_fields -- never a bare,
# unmarked null"):
#   pr.title / pr.url                   `glab mr note list` returns
#     discussions only; supplying these would cost a SECOND `glab mr view`
#     round trip this verb deliberately does not make.
#   threads[].isOutdated                GitLab has no per-discussion
#     outdated flag at all. This is also why the default call cannot
#     reproduce the github adapter's second `isOutdated == false` filter --
#     there is nothing to filter on.
#   threads[].isCollapsed               a GitHub review-UI concept with no
#     GitLab counterpart.
#   threads[].comments.nodes[].url      GitLab's discussion notes carry no
#     per-note permalink in this payload.
#   threads[].comments.nodes[].outdated same gap as isOutdated, per note.
_forge_pr_review_threads_gitlab() {
  local iid="$1" all_threads="$2"
  local state_filter="unresolved"
  if [ "$all_threads" = "true" ]; then
    state_filter="all"
  fi

  local stdout rc=0
  local stderr_out
  _forge_capture stdout stderr_out rc -- glab mr note list "$iid" -F json --state "$state_filter" || true

  if [ "$rc" -ne 0 ]; then
    # A merge request that does not exist is a confirmed NOT_FOUND, not a
    # tool failure -- the same distinction _forge_issue_view already draws
    # from gh's stderr. The match is on the HTTP status code `404` rather
    # than on any English wording, because a status code is stable across
    # glab releases and locales while prose is neither. Anything else stays
    # cli_failed: misreading a could-not-attempt failure as a confirmed
    # answer is the dangerous direction, so the catch-all points the safe way.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status not_found
      return 0
    fi
    # cli_failed hard-coded rather than classified: _forge_classify_gh_failure_
    # reason is gh-specific (it calls _forge_auth_status_github), and this
    # repository has no glab auth probe to ask instead. Inventing one here
    # would duplicate whatever the phase's own account/auth story lands.
    _forge_emit_status error "" "glab mr note list exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # ZERO UNRESOLVED DISCUSSIONS IS A `found` RESULT CARRYING AN EMPTY LIST,
  # never not_found -- not_found means the MERGE REQUEST itself could not be
  # located. Conflating the two would make a clean review look like a broken
  # lookup. Go marshals an empty slice as `[]` and a nil slice as `null`, and
  # a command that printed nothing at all is the same fact again, so all
  # three collapse to the empty array here rather than to an error.
  local discussions_json=""
  if [ -n "$stdout" ]; then
    discussions_json=$(printf '%s' "$stdout" | jq -c '. // []' 2>/dev/null) || discussions_json=""
    if [ -z "$discussions_json" ]; then
      _forge_emit_status error "" "glab mr note list returned output that is not JSON" cli_failed
      return 0
    fi
  else
    discussions_json='[]'
  fi

  # The one place GitLab's discussion vocabulary becomes the contract's
  # thread vocabulary.
  #
  # `id` is emitted VERBATIM as GitLab's own full 40-character hex discussion
  # id -- never the 8-character prefix glab's TEXT output displays. That is
  # what makes the identifier ROUND TRIP: forge-resolve-review-thread hands
  # this exact string straight back to `glab mr note resolve`, which accepts a
  # full id, an 8+ character prefix, or an integer note id. Emitting a prefix
  # here and resolving by full id (or the reverse) would work against a fake
  # and fail against the real service.
  #
  # isResolved is DERIVED, because GitLab records resolution per NOTE, not per
  # discussion: a discussion counts as resolved when it has at least one
  # resolvable note and every one of them is resolved. A discussion with no
  # resolvable notes (a plain comment thread) is not resolvable, hence false.
  #
  # path/line/diffSide come from the FIRST note's diff position, which is the
  # note that anchored the discussion to the diff; a general (non-diff)
  # discussion has no position and yields nulls for all three. diffSide is
  # derived rather than read: GitLab records new_line for the post-image side
  # and old_line for the pre-image side, which are GitHub's RIGHT and LEFT.
  #
  # Note ids are integers in GitLab and strings in GitHub, so they are cast to
  # string here -- the contract's comment id stays one type across forges.
  local threads_json
  threads_json=$(printf '%s' "$discussions_json" | jq -c '
    [ .[] | {
        id: .id,
        isResolved: (
          [ .notes[]? | select(.resolvable == true) ] as $resolvable
          | if ($resolvable | length) == 0
            then false
            else ($resolvable | all(.resolved == true))
            end
        ),
        isOutdated: null,
        isCollapsed: null,
        path: (.notes[0].position.new_path // .notes[0].position.old_path // null),
        line: (.notes[0].position.new_line // .notes[0].position.old_line // null),
        startLine: (.notes[0].position.line_range.start.new_line
                    // .notes[0].position.line_range.start.old_line // null),
        diffSide: (
          if (.notes[0].position.new_line // null) != null then "RIGHT"
          elif (.notes[0].position.old_line // null) != null then "LEFT"
          else null
          end
        ),
        comments: {
          totalCount: ((.notes // []) | length),
          nodes: [ (.notes // [])[] | {
            id: (.id | tostring),
            author: {login: (.author.username // null)},
            body: (.body // null),
            createdAt: (.created_at // null),
            updatedAt: (.updated_at // null),
            url: null,
            outdated: null
          } ]
        }
      } ]
  ' 2>/dev/null) || threads_json=""

  # A payload that parsed as JSON but is not the ARRAY OF DISCUSSIONS the
  # transform above expects (an error object, say) would otherwise reach
  # `jq --argjson threads ""` below and spill a raw jq error onto stderr --
  # unacceptable on a verb whose degrade mode is QUIET. Caught here instead.
  if [ -z "$threads_json" ]; then
    _forge_emit_status error "" "glab mr note list returned JSON that is not a discussion array" cli_failed
    return 0
  fi

  local data_json
  data_json=$(jq -nc \
    --arg number "$iid" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber), title: null, url: null},
      threads: $threads,
      unsupported_fields: ["pr.title",
                           "pr.url",
                           "threads[].isOutdated",
                           "threads[].isCollapsed",
                           "threads[].comments.nodes[].url",
                           "threads[].comments.nodes[].outdated"]
    }')
  _forge_emit_status found "$data_json"
}

# ----------------------------------------------------------------------------
# GITEA REVIEW-THREAD ADAPTERS (phase 4). This header covers BOTH
# _forge_pr_review_threads_gitea (immediately below) and
# _forge_resolve_review_thread_gitea (beside its gitlab sibling further down),
# because every constraint here applies to the pair.
#
# VERIFICATION CEILING -- READ BEFORE TRUSTING ANY FLAG OR KEY BELOW. `tea` is
# NOT installed on the machine this was written on. Not one subcommand, flag
# or JSON key below has ever been observed coming out of the real binary:
# every one was read off `gitea/tea` `main` source on 2026-08-06, file and
# line cited per claim. This is the same ceiling phase 3 declared for glab
# (:4380) and that this phase's own field mapper already declared for tea
# (:4497). The tests prove WHICH ARGV this file emits and HOW it parses a
# fixture, never what real tea does with either.
#
# The two halves are NOT equally well covered by that, and saying so is the
# point of declaring the ceiling rather than merely noting it. Argv-shape
# assertions are SOUND against a fake -- the defect this adapter can plausibly
# ship on the emitting side is a wrong flag, and a wrong flag is visible in
# the recorded argv. Key names and document shapes are the opposite: the stub
# emits whatever the author believed, so the assertion only confirms the
# author agrees with themselves and a wrong key passes green on both sides.
# tea's output shape is this section's unobservable.
#
# VERSION FLOOR: tea >= v0.14.0. `tea pulls review-comments`, `tea pulls
# resolve` and `tea pulls unresolve` all landed in tea v0.14.0; the current
# release is v0.15.1 (2026-08-02). An older tea answers with an unknown-
# subcommand error, which is a non-zero exit carrying tea's own stderr and is
# therefore reported as cli_failed -- never as a confirmed not_found.
#
# THE LIST PATH MARSHALS EVERY VALUE AS A STRING. tea emits two different JSON
# shapes for the same resource: a purpose-built typed object on the DETAIL
# path (`tea pulls <index> -o json`) and, on the LIST path, an array of rows
# whose keys are snake_cased and whose values are ALWAYS JSON strings
# (orderedRow.MarshalJSON, modules/print/table.go:187-208, marshals a
# map[string]string). `review-comments` is a LIST path. That is why `line` is
# coerced to a number below and why `isResolved` is derived from a STRING
# comparison. _forge_map_pr_field_gitea (:4548) works the DETAIL path; its
# assumptions do not carry across.
#
# NO SERVER-SIDE RESOLUTION FILTER EXISTS, so the filter is LOCAL -- the exact
# opposite of the gitlab arm above, which asks GitLab for `--state
# unresolved` (:6600) and says so in its own header. `tea pulls
# review-comments` carries only flags.AllDefaultFlags plus `--fields`
# (cmd/pulls/review_comments.go:31); there is no `--state` and no other
# resolution-state selector to pass. The default (unresolved-only) view is
# therefore produced by dropping rows whose `resolver` is non-empty AFTER the
# call, and `--all` skips that drop. Reading the returned list can never tell
# a local filter from a server-side one, which is why the accompanying test
# asserts the ABSENCE of `--state` from the recorded argv and drives a fixture
# that carries both a resolved and an unresolved row.
#
# EVERY THREAD IS DEGENERATE: EXACTLY ONE COMMENT. tea lists review COMMENTS,
# flattened across every review (modules/task/pull_review_comment.go:16-44
# iterates the pull request's reviews and concatenates their comments), and
# exposes no thread/conversation object anywhere. So one review comment
# becomes one thread with comments.totalCount == 1. Inventing grouping by
# `path`, by reviewer or by timestamp would fabricate a structure the forge
# does not have; the gap is DECLARED instead, as `threads[].grouping`.
#
# `threads[].grouping` IS EMITTED AS AN EXPLICIT null KEY, not merely named.
# It is the one gap this forge has that neither other forge has, and it names
# a missing STRUCTURE rather than a missing field -- which is exactly why it
# is spelled out as a key: forge-contract.md's rule is "null PLUS its name
# recorded in unsupported_fields, never a bare unmarked null", and a name in
# the array with no key in the payload would be the mirror-image omission. A
# reader who dumps one gitea thread sees `"grouping": null` and can look the
# name up. The key is gitea-only by construction and no consumer reads it.
#
# `threads[].diffSide` IS PERMANENTLY UNRECOVERABLE HERE, and the reason is
# NOT the usual "the forge has no such field". tea prints ONE `line` column,
# collapsing LineNum and OldLineNum into it (modules/print/
# pull_review_comment.go:52-59 falls back from the one to the other), so by
# the time the value reaches this adapter there is nothing left to say whether
# it was the post-image or the pre-image side. The gitlab arm CAN derive
# RIGHT/LEFT because GitLab hands it separate new_line and old_line keys
# (:6680-6685). Do not port that derivation here -- there is no second number
# to branch on, and guessing RIGHT would be a fabricated answer.
#
# NO ACCOUNT OVERRIDE IS APPLIED, AND THAT IS A SAFETY PROPERTY, NOT AN
# OMISSION. tea reads GH_TOKEN as a fallback credential
# (modules/context/context_login.go:15-51: it prefers GITEA_TOKEN and falls
# back to GH_TOKEN when GITEA_TOKEN is empty), while
# _forge_account_override_slots (:2983-2997) deliberately defaults an empty
# override slot to the AMBIENT GH_TOKEN and every routed github write
# prefix-assigns it. Copying that prefix-assignment shape onto a tea
# invocation would hand a GitHub token to a Gitea instance. Neither gitea
# function below assigns or exports GH_TOKEN, GH_ENTERPRISE_TOKEN,
# GITEA_TOKEN or GITEA_INSTANCE_URL, and a test counts those assignments over
# both function bodies to keep it that way.
#
# --owner/--repo ARE NOT FORWARDED, for the same reason the gitlab arm gives:
# they are gh's flat owner/repo pair, and tea addresses the repository through
# the current working directory's remote. Both gitea arms therefore return
# BEFORE _forge_pr_review_threads' gh-specific owner/repo resolution block.
#
# FAILURE CLASSIFICATION. tea exits 1 uniformly for every error (main.go:18-30
# prints `Error: %v` and calls os.Exit(1)) with no distinct not-found code, so
# a `404` in stderr is the ONLY confirmed negative -- matched on the HTTP
# status code rather than on English wording, exactly as the gitlab arms
# above. Every other non-zero exit stays status=error/reason=cli_failed
# carrying tea's own stderr. Misreading a could-not-attempt failure as a
# confirmed answer is the dangerous direction; the catch-all points the safe
# way.
#
# CAPABILITY GAPS, all reported through unsupported_fields per
# forge-contract.md:
#   pr.title / pr.url                   `tea pulls review-comments` returns
#     comments only; supplying these would cost a SECOND `tea pulls <index>`
#     round trip this verb deliberately does not make -- the same argument
#     the gitlab arm makes at :6579-6581.
#   threads[].startLine                 tea has no start-line field at all.
#   threads[].diffSide                  unrecoverable, see above.
#   threads[].isOutdated / isCollapsed  no field; GitHub review-UI concepts.
#   threads[].grouping                  no conversation object, see above.
#   threads[].comments.nodes[].outdated same gap as isOutdated, per comment.
#
# AND ONE FIELD THAT IS *NOT* A GAP HERE, though it is on GitLab:
#   threads[].comments.nodes[].url      tea's review-comment field allowlist
#     carries `url` (modules/print/pull_review_comment.go:13-23), so it is
#     REQUESTED, populated and deliberately absent from unsupported_fields.
#     GitLab lists it as a gap (:6721); copying that array wholesale is the
#     expected mistake, and a test asserts the name appears nowhere in the
#     gitea array.
# ----------------------------------------------------------------------------

# gitea adapter for forge-pr-review-threads. <index> is already validated as a
# positive integer by cmd_forge_pr_review_threads before this ever runs;
# <all_threads> is the literal string "true"/"false". See the GITEA
# REVIEW-THREAD ADAPTERS header directly above for the verification ceiling,
# the tea >= v0.14.0 version floor, and every capability gap named below.
_forge_pr_review_threads_gitea() {
  local index="$1" all_threads="$2"
  local stdout rc=0
  local stderr_out

  # `-f` is tea's OWN field selector (--fields, cmd/flags/generic.go:157), a
  # CSV over a fixed allowlist -- never a gh-style `--json <field-list>`,
  # which tea does not have. `-o json` selects the output format. The list is
  # the full review-comment allowlist (modules/print/
  # pull_review_comment.go:13-23) rather than the subcommand's own narrower
  # default (id,path,line,body,reviewer,resolver), because `created`,
  # `updated` and `url` are all contract fields this verb must populate.
  #
  # No account override, no GH_TOKEN prefix assignment -- see the header.
  _forge_capture stdout stderr_out rc -- tea pulls review-comments "$index" \
    -f id,path,line,body,reviewer,resolver,created,updated,url -o json || true

  if [ "$rc" -ne 0 ]; then
    # tea has ONE exit code for every failure, so `404` in stderr is the only
    # confirmed negative. Everything else is a could-not-attempt.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status not_found
      return 0
    fi
    _forge_emit_status error "" "tea pulls review-comments exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # ZERO REVIEW COMMENTS IS A `found` RESULT CARRYING AN EMPTY LIST, never
  # not_found -- not_found means the PULL REQUEST itself could not be located.
  # Go marshals an empty slice as `[]` and a nil slice as `null`, and a
  # command that printed nothing at all is the same fact again, so all three
  # collapse here rather than to an error.
  local comments_json=""
  if [ -n "$stdout" ]; then
    comments_json=$(printf '%s' "$stdout" | jq -c '. // []' 2>/dev/null) || comments_json=""
    if [ -z "$comments_json" ]; then
      _forge_emit_status error "" "tea pulls review-comments returned output that is not JSON" cli_failed
      return 0
    fi
  else
    comments_json='[]'
  fi

  local all_flag_json
  if [ "$all_threads" = "true" ]; then all_flag_json=true; else all_flag_json=false; fi

  # The one place a tea review COMMENT becomes a contract THREAD.
  #
  # The select() is the LOCAL resolution filter tea offers no server-side
  # equivalent for. `resolver` is a username or the empty string -- there is
  # no boolean anywhere in the payload -- so isResolved is DERIVED from it by
  # the same comparison, and the two can never disagree.
  #
  # `line` is coerced to a NUMBER because the LIST path marshals it as the
  # string tea printed; `tonumber?` yields nothing for a non-numeric value,
  # which `// null` then turns into an honest null rather than a zero.
  # `id` goes the other way and is cast to STRING, so the contract's thread
  # and comment ids stay one type across all three forges.
  #
  # comments.totalCount is the literal 1: tea exposes no conversation object,
  # so one comment is the whole thread. See the header.
  local threads_json
  threads_json=$(printf '%s' "$comments_json" | jq -c --argjson all "$all_flag_json" '
    [ .[]
      | select($all or (((.resolver // "") | tostring) == ""))
      | {
          id: (.id | tostring),
          isResolved: (((.resolver // "") | tostring) != ""),
          isOutdated: null,
          isCollapsed: null,
          grouping: null,
          path: (if ((.path // "") | tostring) == "" then null else (.path | tostring) end),
          line: ((.line | tonumber?) // null),
          startLine: null,
          diffSide: null,
          comments: {
            totalCount: 1,
            nodes: [ {
              id: (.id | tostring),
              author: {login: (if ((.reviewer // "") | tostring) == "" then null else (.reviewer | tostring) end)},
              body: (if ((.body // "") | tostring) == "" then null else (.body | tostring) end),
              createdAt: (if ((.created // "") | tostring) == "" then null else (.created | tostring) end),
              updatedAt: (if ((.updated // "") | tostring) == "" then null else (.updated | tostring) end),
              url: (if ((.url // "") | tostring) == "" then null else (.url | tostring) end),
              outdated: null
            } ]
          }
        } ]
  ' 2>/dev/null) || threads_json=""

  # A payload that parsed as JSON but is not the ARRAY OF COMMENTS the
  # transform above expects (an error object, say) would otherwise reach
  # `jq --argjson threads ""` below and spill a raw jq error onto stderr --
  # unacceptable on a verb whose degrade mode is QUIET. Caught here instead,
  # exactly as the gitlab arm does.
  if [ -z "$threads_json" ]; then
    _forge_emit_status error "" "tea pulls review-comments returned JSON that is not a review-comment array" cli_failed
    return 0
  fi

  local data_json
  data_json=$(jq -nc \
    --arg number "$index" \
    --argjson threads "$threads_json" \
    '{
      pr: {number: ($number | tonumber), title: null, url: null},
      threads: $threads,
      unsupported_fields: ["pr.title",
                           "pr.url",
                           "threads[].startLine",
                           "threads[].diffSide",
                           "threads[].isOutdated",
                           "threads[].isCollapsed",
                           "threads[].grouping",
                           "threads[].comments.nodes[].outdated"]
    }')
  _forge_emit_status found "$data_json"
}

# Resolves forge/owner/repo, routes a forge with no adapter or a missing
# forge CLI to a QUIET status=error result, and otherwise delegates to the
# github, gitlab or gitea adapter. Owner/repo are resolved via US-003's
# _forge_repo_info as a direct function call (never a `$AIMI_CLI
# forge-repo-info` subprocess, never a second private gh-repo-view call)
# whenever --owner/--repo are not both supplied, replacing
# get-pr-comments:14-20's own inline OWNER/REPO detection -- a GITHUB-ONLY
# step, which is why the gitlab arm returns before it (glab addresses the
# repository through the cwd remote, not an owner/repo pair).
_forge_pr_review_threads() {
  local pr_number="$1" owner="$2" repo="$3" all_threads="$4"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) so it
  # can be handed to the github adapter, which passes it to the classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  # GitLab returns HERE, before the owner/repo resolution below: that step is
  # gh-specific and glab needs no owner/repo pair at all. Degradation runs
  # through the SAME shared _forge_bin_check gate the github arm uses, in the
  # same quiet mode, naming `glab` rather than `gh`.
  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      _forge_emit_status error "" "glab not found -- this review-thread lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_pr_review_threads_gitlab "$pr_number" "$all_threads"
    return 0
  fi

  # Gitea returns HERE too, and for the same reason: `tea` addresses the
  # repository through the cwd remote and has no owner/repo pair to be given.
  # Same shared _forge_bin_check gate, same quiet mode, naming `tea`.
  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      _forge_emit_status error "" "tea not found -- this review-thread lookup did not run automatically." cli_missing
      return 0
    fi
    _forge_pr_review_threads_gitea "$pr_number" "$all_threads"
    return 0
  fi

  # Still reachable: `unknown`, the classification _detect_forge_classify_host
  # answers for any host that is not one of the three named adapters. It is
  # now the ONLY forge word that reaches this branch, since AIMI_FORGE_TYPE
  # validates against github|gitlab|gitea (:2130).
  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-pr-review-threads: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this review-thread lookup did not run automatically." cli_missing
    return 0
  fi

  if [ -z "$owner" ] || [ -z "$repo" ]; then
    local repo_info repo_status
    repo_info=$(_forge_repo_info)
    repo_status=$(printf '%s' "$repo_info" | jq -r '.status')
    if [ "$repo_status" = "found" ]; then
      [ -n "$owner" ] || owner=$(printf '%s' "$repo_info" | jq -r '.data.owner')
      [ -n "$repo" ]  || repo=$(printf '%s' "$repo_info" | jq -r '.data.repo')
    fi
  fi

  # cli_failed, NOT a fifth enum value of its own and NOT routed through the
  # classifier: no gh invocation happens on this branch, so there is nothing
  # to re-check auth against, and forge-contract.md's cli_failed already
  # names "an owner/repo that could not be auto-resolved" as one of the
  # catch-all's cases. A fifth value for exactly one call site would be enum
  # proliferation for a single caller-input edge case.
  if [ -z "$owner" ] || [ -z "$repo" ]; then
    _forge_emit_status error "" "forge-pr-review-threads: could not resolve owner/repo -- pass --owner and --repo explicitly." cli_failed
    return 0
  fi

  _forge_pr_review_threads_github "$pr_number" "$owner" "$repo" "$all_threads" "$host"
}

# Read verb: found | not_found | error, per forge-contract.md's Three-Way
# Status Convention. Output: {status, data, message}; data (when found)
# carries {pr: {number, title, url}, threads: [...], unsupported_fields}.
# Each thread carries get-pr-comments' current fields unchanged: id,
# isResolved, isOutdated, isCollapsed, path, line, startLine, diffSide, and
# comments: {totalCount, nodes: [{id, author: {login}, body, createdAt,
# updatedAt, url, outdated}]}.
#
# On GitLab and on Gitea the SHAPE is identical -- same keys, same three-way
# status -- but several fields are capability-gated and come back null with
# their names in `unsupported_fields`; see _forge_pr_review_threads_gitlab's
# and _forge_pr_review_threads_gitea's headers for the list and the reason for
# each. A merge request with zero unresolved discussions, or a Gitea pull
# request with zero unresolved review comments, is `found` with an empty
# `threads` array, NOT `not_found`. Gitea threads additionally carry a
# `grouping` key, always null and always declared in `unsupported_fields`:
# tea exposes no conversation object, so each thread is exactly one comment.
# --owner/--repo are honored on GitHub only.
# Usage: aimi-cli.sh forge-pr-review-threads --pr <number> [--owner <owner>
# --repo <repo>] [--all] [--project <path>]
cmd_forge_pr_review_threads() {
  check_jq

  local pr_number="" owner="" repo="" all_threads="false" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)      shift; pr_number="${1:-}" ;;
      --owner)   shift; owner="${1:-}" ;;
      --repo)    shift; repo="${1:-}" ;;
      --all)     all_threads="true" ;;
      --project) shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-pr-review-threads: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$pr_number" ]; then
    echo "Usage: aimi-cli.sh forge-pr-review-threads --pr <number> [--owner <owner> --repo <repo>] [--all] [--project <path>]" >&2
    exit 1
  fi

  # Fail-fast usage check BEFORE the PR number is ever passed to gh -- the
  # primary injection defense is the -f/-F binding in the github adapter
  # above, not this pattern check.
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "Error: forge-pr-review-threads: --pr must be a positive integer (got: $pr_number)" >&2
    exit 1
  fi

  if [ -n "$owner" ] && ! [[ "$owner" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: forge-pr-review-threads: invalid --owner value: $owner" >&2
    exit 1
  fi

  if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: forge-pr-review-threads: invalid --repo value: $repo" >&2
    exit 1
  fi

  _forge_pr_review_threads "$pr_number" "$owner" "$repo" "$all_threads"
}

# ----------------------------------------------------------------------------
# GITEA CAPABILITY-GAP NOTE -- REWRITTEN IN PHASE 4, BECAUSE ITS FACTUAL
# CLAIM WAS FALSE.
#
# WHAT THIS NOTE USED TO SAY, and what is now retracted: written in phase 1
# as documentation only, it ruled that a Gitea/Forgejo `tea` adapter could
# not resolve a review thread by any means, and that this was a PERMANENT
# capability gap rather than the temporary state an unwritten adapter is in.
# Source falsifies both halves. `tea pulls review-comments <pull index>`
# (cmd/pulls/review_comments.go:24-32) lists a pull request's review
# comments, and `tea pulls resolve <comment id>` / `tea pulls unresolve`
# (cmd/pulls/resolve.go, unresolve.go) mark one resolved or unresolved. All
# three landed in tea v0.14.0; the current release is v0.15.1. Both verbs are
# ROUTED for gitea today -- see the GITEA REVIEW-THREAD ADAPTERS section
# above.
#
# WHAT THE REAL GAP IS: GROUPING, not resolution, and it is both narrower and
# different from the ruling it replaces. tea lists review COMMENTS, flattened
# across every review (modules/task/pull_review_comment.go:16-44), and
# exposes no thread/conversation object at all, so the adapter emits one
# DEGENERATE single-comment thread per review comment. Alongside it,
# `threads[].diffSide` is unrecoverable, and for a reason that is not the
# usual absence: tea collapses LineNum and OldLineNum into one printed
# column (modules/print/pull_review_comment.go:52-59), leaving nothing to
# tell the post-image side from the pre-image one -- unlike GitLab, whose
# separate new_line/old_line keys the gitlab arm above genuinely does derive
# RIGHT/LEFT from. Add `threads[].startLine`, `threads[].isOutdated`,
# `threads[].isCollapsed`, `pr.title` and `pr.url`, and that is the whole
# gap.
#
# WHAT THE ADVICE STILL SAYS, UNCHANGED, because only the factual claim was
# wrong: a PERMANENT capability gap is reported through the
# `unsupported_fields` array naming the thing that is missing, never by
# reusing the generic no-adapter `message` text an unwritten adapter
# produces. "This forge cannot do this at all" and "nobody wrote the adapter
# yet" are two different facts, and collapsing them would make a permanent
# gap look like a temporary one. Applying that advice is what
# `threads[].grouping` in the gitea listing arm's own unsupported_fields is.
#
# WHAT CHANGED IS THE WORKED EXAMPLE. The old note offered an
# unsupported_fields entry naming the resolveReviewThread mutation as the
# value to emit. That is now exactly the WRONG answer: resolution is
# supported on this forge, so naming it as a gap would report a capability
# the adapter has as one it lacks -- the same collapse the advice above
# exists to prevent, pointing the other way.
# ----------------------------------------------------------------------------
# github adapter for forge-resolve-review-thread. <thread_id> is already
# validated by cmd_forge_resolve_review_thread before this ever runs. Binds
# threadId via -f only -- see the section header above for why the mutation
# text still contains a literal `$threadId` (GraphQL's own variable syntax).
# Always QUIET and always returns 0 -- found/error are three data outcomes,
# not exit codes; cmd_forge_resolve_review_thread (the public wrapper) is
# the only layer that prints the MANDATORY manual instruction and exits
# non-zero, driven by this function's JSON `status` field.
# gitlab adapter for forge-resolve-review-thread (phase 3). <thread_id> is
# already validated by cmd_forge_resolve_review_thread before this ever runs.
#
# EXPERIMENTAL UPSTREAM: glab's own documentation marks `glab mr note resolve`
# as an experiment "not ready for production use ... might be unstable or
# removed at any time" (docs/source/mr/note/resolve.md).
#
# That is a DISCLOSURE to whoever relies on this verb, not a reason to skip
# the routing: without it a GitLab caller gets no automatic resolve at all,
# which is strictly worse than an automatic one whose upstream is still
# settling.
#
# RESOLVES ONLY; POSTS NO REPLY. `glab mr note resolve` marks the discussion
# resolved and writes no comment, which is exactly this verb's established
# meaning here -- phase 2's handoff records that forge-resolve-review-thread
# resolves a thread and does not post a comment, and that no reply call site
# exists anywhere in this repository. The two agree, so nothing is
# special-cased: this adapter issues ONE glab invocation and it is not a
# note-creating one.
#
# THE MERGE REQUEST IS NOT NAMED, DELIBERATELY. `glab mr note resolve
# [<id> | <branch>] <discussion-id>` takes the merge request as an OPTIONAL
# leading positional and auto-detects it from the current branch when it is
# omitted -- which is the only form this verb can use, because
# forge-resolve-review-thread's contract carries a thread id and nothing
# else (GitHub's node id is globally unique, so no PR number was ever part
# of the signature).
#
# The id is passed through VERBATIM, byte for byte as
# _forge_pr_review_threads_gitlab emitted it. glab accepts a full 40-char hex
# discussion id, an 8+ character prefix, or an integer note id; the listing
# side emits the full id, so nothing here re-derives, truncates or re-formats
# it. That is the round trip, and it is what stops a fake from making a
# prefix/full-id mismatch look correct.
#
# Always QUIET and always returns 0, same as the github adapter.
_forge_resolve_review_thread_gitlab() {
  local thread_id="$1"
  local stdout rc=0
  local stderr_out

  # No account override is applied on this path. The GH_TOKEN/
  # GH_ENTERPRISE_TOKEN prefix assignment the github arm carries is gh's own
  # mechanism; the equivalent question for glab belongs to this phase's
  # account story and is not answered by guessing at one here.
  _forge_capture stdout stderr_out rc -- glab mr note resolve "$thread_id" || true

  if [ "$rc" -ne 0 ]; then
    # A discussion id GitLab cannot find is a CONFIRMED negative (the call
    # ran; the answer is "no such thread"), reported as status="found" with
    # resolved=false -- byte-identical to the github adapter's own
    # confirmed-invalid-id result, per forge-contract.md's Three-Way Status
    # Convention: a definitive answer is still a successful lookup.
    #
    # Matched on the HTTP status code `404` ONLY, never on English wording:
    # a status code is stable across glab releases and locales. Every other
    # failure -- glab could not auto-detect a merge request for this branch,
    # the network was down, the token expired -- stays status="error", so the
    # wrapper prints its manual instruction and exits non-zero. Reading a
    # could-not-attempt failure as a confirmed answer is the dangerous
    # direction; this narrow match points the safe way.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # cli_failed hard-coded rather than classified, for the same reason
    # _forge_pr_review_threads_gitlab gives: the shared classifier is
    # gh-specific and there is no glab auth probe in this repository.
    _forge_emit_status error "" "glab mr note resolve exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # glab reports success by exit status, not by a JSON document, and it is
  # given no `-F json` flag (its resolve subcommand documents none). So the
  # thread object is rebuilt from what is known for certain: the id that was
  # just resolved, and the fact that it now is. path/line are GitHub's, come
  # from the GraphQL mutation's own response there, and have no counterpart
  # in glab's output -- null plus unsupported_fields, per forge-contract.md.
  _forge_emit_status found "$(jq -nc --arg id "$thread_id" '{
    resolved: true,
    thread: {id: $id, isResolved: true, path: null, line: null},
    unsupported_fields: ["thread.path", "thread.line"]
  }')"
}

# gitea adapter for forge-resolve-review-thread (phase 4). <thread_id> is
# already validated by cmd_forge_resolve_review_thread before this ever runs.
# See the GITEA REVIEW-THREAD ADAPTERS header above _forge_pr_review_threads_
# gitea for the verification ceiling, the tea >= v0.14.0 version floor, and
# the GH_TOKEN hazard that forbids any account override on this path.
#
# RESOLVES ONLY; POSTS NO REPLY. `tea pulls resolve` marks the review comment
# resolved and writes no comment of its own, which is this verb's established
# meaning here -- the same property the gitlab arm above insists on. This
# adapter issues ONE tea invocation and it is not a comment-creating one.
#
# THE PULL REQUEST IS NOT NAMED, because it is not part of the identifier.
# `tea pulls resolve` takes a COMMENT id, which is what makes the round trip
# work: _forge_pr_review_threads_gitea emits tea's own `id` and this hands
# that exact string back (ResolvePullReviewComment consumes the same id,
# modules/task/pull_review_comment.go:47-57). Nothing here re-derives,
# truncates or re-formats it. A numeric id also passes
# cmd_forge_resolve_review_thread's existing ^[A-Za-z0-9+/=_-]+$ guard
# unchanged, so that guard needed no edit for this forge.
#
# Always QUIET and always returns 0, same as the other two adapters.
_forge_resolve_review_thread_gitea() {
  local thread_id="$1"
  local stdout rc=0
  local stderr_out

  # No account override, no GH_TOKEN prefix assignment: tea reads GH_TOKEN as
  # a fallback credential, so the github arm's shape would hand a GitHub token
  # to a Gitea instance. See the section header.
  _forge_capture stdout stderr_out rc -- tea pulls resolve "$thread_id" || true

  if [ "$rc" -ne 0 ]; then
    # A comment id Gitea cannot find is a CONFIRMED negative (the call ran;
    # the answer is "no such comment"), reported as status="found" with
    # resolved=false -- byte-identical to the other two adapters' own
    # confirmed-invalid-id result, per forge-contract.md's Three-Way Status
    # Convention. Matched on the HTTP status code `404` only, never on
    # English wording, and every other failure stays status="error" so the
    # wrapper prints its manual instruction and exits non-zero.
    if printf '%s' "$stderr_out" | grep -q "404"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # cli_failed hard-coded rather than classified, for the same reason the
    # gitlab arm gives: the shared classifier is gh-specific and there is no
    # tea auth probe in this repository.
    _forge_emit_status error "" "tea pulls resolve exited $rc: ${stderr_out:-unknown error}" cli_failed
    return 0
  fi

  # tea reports success by exit status, not by a JSON document: it prints
  # `Comment %d resolved` to stdout (modules/task/pull_review_comment.go:55)
  # and returns nothing structured. So the thread object is rebuilt from what
  # is known for certain -- the id that was just resolved, and the fact that
  # it now is -- reusing the shape `glab mr note resolve` already established
  # directly above. path/line are GitHub's, come from the GraphQL mutation's
  # own response there, and have no counterpart in tea's output: null plus
  # unsupported_fields, per forge-contract.md.
  _forge_emit_status found "$(jq -nc --arg id "$thread_id" '{
    resolved: true,
    thread: {id: $id, isResolved: true, path: null, line: null},
    unsupported_fields: ["thread.path", "thread.line"]
  }')"
}

_forge_resolve_review_thread() {
  local thread_id="$1"
  local forge_info forge host
  # host is resolved alongside forge (this used to read only .forge) purely
  # so the generic-failure branch below can hand it to the shared classifier.
  forge_info=$(_detect_forge)
  forge=$(printf '%s' "$forge_info" | jq -r '.forge')
  host=$(printf '%s' "$forge_info" | jq -r '.host // empty')

  # Same shared _forge_bin_check gate, same quiet mode, naming `glab` rather
  # than `gh`. The wrapper below is still the only layer that prints and
  # exits non-zero, driven purely by the JSON status field -- so a missing
  # glab degrades through exactly the path a missing gh already does.
  if [ "$forge" = "gitlab" ]; then
    if ! _forge_bin_check glab quiet "$forge"; then
      _forge_emit_status error "" "glab not found -- this thread could not be resolved automatically." cli_missing
      return 0
    fi
    _forge_resolve_review_thread_gitlab "$thread_id"
    return 0
  fi

  # Same gate again for gitea, naming `tea`. The wrapper below stays the only
  # layer that prints and exits non-zero, so a missing tea degrades through
  # exactly the path a missing gh already does.
  if [ "$forge" = "gitea" ]; then
    if ! _forge_bin_check tea quiet "$forge"; then
      _forge_emit_status error "" "tea not found -- this thread could not be resolved automatically." cli_missing
      return 0
    fi
    _forge_resolve_review_thread_gitea "$thread_id"
    return 0
  fi

  # Still reachable by `unknown` -- the only forge word left with no adapter.
  if [ "$forge" != "github" ]; then
    _forge_emit_status error "" "forge-resolve-review-thread: no adapter for forge \"$forge\" yet -- GitHub, GitLab and Gitea are the only adapters." no_adapter
    return 0
  fi

  if ! _forge_bin_check gh quiet "$forge"; then
    _forge_emit_status error "" "gh not found -- this thread could not be resolved automatically." cli_missing
    return 0
  fi

  # Resolved once, for the mutation below and for the failure classifier that
  # judges it. See the ROUTING RULE block above the forge-auth-status section.
  local gh_token_override="" ghe_token_override=""
  _forge_account_override_slots gh_token_override ghe_token_override

  # WRITE 4. Same prefix-assignment shape as the other three. The nested
  # `$(_forge_resolve_review_thread_mutation)` substitution is evaluated in this
  # shell BEFORE _forge_capture is entered, so the prefix assignment does not
  # disturb it.
  local stdout rc=0
  local stderr_out
  GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
    _forge_capture stdout stderr_out rc -- gh api graphql -f threadId="$thread_id" \
    -f query="$(_forge_resolve_review_thread_mutation)" || true

  # gh api graphql exits non-zero when the GraphQL response's own `errors`
  # array is non-empty -- a mutation targeting an invalid/inaccessible node
  # id is exactly this case. That non-zero exit is a CONFIRMED negative
  # answer, not a tool failure, so it must not fall into the generic
  # "gh could not attempt this" branch below. GitHub's GraphQL API names
  # this failure mode with the fixed message "Could not resolve to a node
  # with the global id of" regardless of which mutation triggered it -- the
  # same style of stderr pattern-match _forge_issue_view already uses to
  # distinguish "no such issue" from "gh is broken".
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$stderr_out" | grep -qi "could not resolve to a node"; then
      _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
      return 0
    fi
    # Reached only after the confirmed-invalid-id match above already
    # failed, so gh genuinely broke. gh's presence was confirmed by the
    # _forge_bin_check gate above, so the classifier only separates
    # not_authenticated from cli_failed -- structurally, never by reading
    # stderr_out's wording.
    #
    # ROUTED, and this is the ONLY classifier call inside a write path. Left
    # unrouted it would re-check the MACHINE account's auth after a mutation
    # that failed as a DIFFERENT account -- an overridden account whose token
    # expired would be classified against the wrong account entirely. Under the
    # override `gh auth status` reports the env-token account, which is exactly
    # the one whose failure is being classified. The prefix assignment is at
    # this call site; _forge_classify_gh_failure_reason itself is unmodified,
    # and its other two callers are pure reads that stay unrouted.
    local reason
    reason=$(GH_TOKEN="$gh_token_override" GH_ENTERPRISE_TOKEN="$ghe_token_override" \
      _forge_classify_gh_failure_reason "$host")
    _forge_emit_status error "" "gh api graphql exited $rc: ${stderr_out:-unknown error}" "$reason"
    return 0
  fi

  # Defensive fallback for a gh response shape that returns exit 0 with a
  # populated top-level `errors` array instead of a non-zero exit -- the
  # same confirmed-negative outcome, reached by inspecting the body instead
  # of the exit code.
  local errors_count
  errors_count=$(printf '%s' "$stdout" | jq -r '(.errors // []) | length')
  if [ "$errors_count" != "0" ]; then
    _forge_emit_status found "$(jq -nc '{resolved: false, thread: null, unsupported_fields: []}')"
    return 0
  fi

  local thread_json
  thread_json=$(printf '%s' "$stdout" | jq -c '.data.resolveReviewThread.thread // empty')
  # cli_failed hard-coded rather than classified: gh itself exited 0 here,
  # so nothing failed at the tool level and there is no failure to re-check
  # auth against -- only the response shape is unexpected.
  if [ -z "$thread_json" ]; then
    _forge_emit_status error "" "gh api graphql returned no thread and no errors for resolveReviewThread" cli_failed
    return 0
  fi

  local data_json
  data_json=$(printf '%s' "$thread_json" | jq -c '{
    resolved: .isResolved,
    thread: {id: .id, isResolved: .isResolved, path: .path, line: .line},
    unsupported_fields: []
  }')
  _forge_emit_status found "$data_json"
}

# Write verb with NO fallback path -- MANDATORY-PRINT degrade mode.
# Output: {status: "found"|"error", data, message}. status=="found" covers
# BOTH a successful resolve (data.resolved=true) and a confirmed-invalid
# thread id (data.resolved=false, the mutation ran) -- both exit 0, no
# stderr. status=="error" means gh could not even attempt the mutation
# (missing binary, unsupported forge, or gh itself exiting non-zero for a
# reason other than a confirmed GraphQL error) -- prints the manual
# "resolve it yourself" instruction to stderr and exits non-zero, since
# there is no gh subcommand or REST fallback for resolving a review thread.
# Usage: aimi-cli.sh forge-resolve-review-thread --thread-id <id> [--project <path>]
cmd_forge_resolve_review_thread() {
  check_jq

  local thread_id="" project_dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --thread-id) shift; thread_id="${1:-}" ;;
      --project)   shift; project_dir="${1:-}" ;;
      *)
        echo "Error: forge-resolve-review-thread: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _require_git_repo "$project_dir"

  if [ -z "$thread_id" ]; then
    echo "Usage: aimi-cli.sh forge-resolve-review-thread --thread-id <id> [--project <path>]" >&2
    exit 1
  fi

  # Fail-fast usage check BEFORE the thread id is ever passed to gh -- the
  # primary injection defense is the -f binding in the github adapter
  # above, not this pattern check.
  if ! [[ "$thread_id" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
    echo "Error: forge-resolve-review-thread: invalid --thread-id value: $thread_id" >&2
    exit 1
  fi

  local result status message
  result=$(_forge_resolve_review_thread "$thread_id")
  status=$(printf '%s' "$result" | jq -r '.status')

  if [ "$status" = "error" ]; then
    message=$(printf '%s' "$result" | jq -r '.message // "unknown error"')
    {
      echo "Warning: could not resolve this review thread automatically ($message)."
      echo "There is no automatic fallback once the forge CLI itself cannot run this -- resolve it manually in the pull/merge request's diff view (GitHub: Files changed; GitLab: Changes; Gitea/Forgejo: Files changed) and mark the conversation/thread resolved."
    } >&2
    printf '%s\n' "$result"
    exit 1
  fi

  printf '%s\n' "$result"
}

# Detect a Claude Design handoff bundle under a given root (defaults to CWD).
# Scans depth-1 subdirectories for a README.md containing the handoff marker.
# Returns JSON object when found, "null" when not found.
# With --all, returns a JSON array sorted newest-first (by directory mtime).
cmd_detect_design_bundle() {
  local root="" all=false json=false

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) shift; root="${1:-}" ;;
      --all)  all=true ;;
      --json) json=true ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
    shift
  done

  # Resolve scan root (default: CWD)
  local scan_root
  if [ -n "$root" ]; then
    # For relative paths, validate they stay within project boundary (prevents ../.. traversal).
    # Absolute paths are allowed as scan roots since this is a read-only operation.
    case "$root" in
      /*) : ;;  # Absolute path — skip boundary check (read-only scan)
      *)  validate_path_in_project "$root" ;;
    esac
    scan_root="$root"
  else
    scan_root="$(pwd)"
  fi

  if [ ! -d "$scan_root" ]; then
    echo "Error: Scan root does not exist: $scan_root" >&2
    exit 1
  fi

  # The handoff marker (fixed string, case-sensitive)
  local HANDOFF_MARKER='This is a **handoff bundle** from Claude Design (claude.ai/design).'

  # Collect matching bundles: each entry is "<mtime> <abspath>"
  local found_paths=()

  # Pre-check: scan_root may itself be a bundle directory. When its README has
  # the handoff marker, treat it as a single bundle and skip the children scan.
  local root_normalized="${scan_root%/}/"
  local root_readme="${root_normalized}README.md"
  if [ -f "$root_readme" ] && grep -qF "$HANDOFF_MARKER" "$root_readme"; then
    local root_mtime
    if command -v stat >/dev/null 2>&1; then
      root_mtime=$(stat -c '%Y' "$root_normalized" 2>/dev/null || stat -f '%m' "$root_normalized" 2>/dev/null || echo 0)
    else
      root_mtime=0
    fi
    found_paths+=("${root_mtime} ${root_normalized}")
  else
    for subdir in "${scan_root}"/*/; do
      [ -d "$subdir" ] || continue

      local base
      base=$(basename "$subdir")

      # Skip noise directories
      case "$base" in
        .worktrees|node_modules|.aimi|vendor) continue ;;
      esac

      local readme="${subdir}README.md"
      [ -f "$readme" ] || continue

      # Fixed-string, case-sensitive marker check
      grep -qF "$HANDOFF_MARKER" "$readme" || continue

      # Get directory mtime (seconds since epoch) — stat is not POSIX-portable;
      # use date-based approach via ls for mtime sorting, falling back to 0
      local mtime
      if command -v stat >/dev/null 2>&1; then
        # GNU stat (Linux) or BSD stat (macOS)
        mtime=$(stat -c '%Y' "$subdir" 2>/dev/null || stat -f '%m' "$subdir" 2>/dev/null || echo 0)
      else
        mtime=0
      fi

      found_paths+=("${mtime} ${subdir}")
    done
  fi

  # No bundles found
  if [ ${#found_paths[@]} -eq 0 ]; then
    echo "null"
    return 0
  fi

  # Sort found_paths by mtime descending (newest first)
  local sorted_paths
  sorted_paths=$(printf '%s\n' "${found_paths[@]}" | sort -rn)

  # Build JSON for a single bundle directory
  _build_bundle_json() {
    local subdir="$1"
    local base
    base=$(basename "$subdir")

    local readme="${subdir}README.md"
    local readme_rel="${base}/README.md"

    # chats[]: <bundle>/chats/*.md
    local chats_arr=()
    for f in "${subdir}chats/"*.md; do
      [ -f "$f" ] && chats_arr+=("${base}/chats/$(basename "$f")")
    done
    local chats_json
    if [ ${#chats_arr[@]} -gt 0 ]; then
      chats_json=$(printf '%s\n' "${chats_arr[@]}" | jq -R . | jq -s .)
    else
      chats_json="[]"
    fi

    # prototypes[]: <bundle>/project/**/*.html (recursive)
    local protos_arr=()
    if [ -d "${subdir}project" ]; then
      while IFS= read -r f; do
        [ -f "$f" ] && protos_arr+=("${base}/project/${f#${subdir}project/}")
      done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
    fi
    local protos_json
    if [ ${#protos_arr[@]} -gt 0 ]; then
      protos_json=$(printf '%s\n' "${protos_arr[@]}" | jq -R . | jq -s .)
    else
      protos_json="[]"
    fi

    # hasReact / hasTailwind: grep heuristics over prototype HTML and adjacent CSS
    local has_react=false has_tailwind=false
    if [ ${#protos_arr[@]} -gt 0 ]; then
      # Search the actual HTML files (absolute paths needed for grep)
      local abs_protos=()
      if [ -d "${subdir}project" ]; then
        while IFS= read -r f; do
          [ -f "$f" ] && abs_protos+=("$f")
        done < <(find "${subdir}project" -name "*.html" -type f 2>/dev/null)
      fi
      if [ ${#abs_protos[@]} -gt 0 ]; then
        if grep -qliF 'react' "${abs_protos[@]}" 2>/dev/null; then
          has_react=true
        fi
        if grep -qliF 'tailwind' "${abs_protos[@]}" 2>/dev/null; then
          has_tailwind=true
        fi
      fi
    fi

    # businessSpec / designSpec: case-insensitive discovery
    # (Claude Design exports occasionally produce camelCase filenames.)
    local business_spec="" design_spec=""
    local business_spec_file design_spec_file
    business_spec_file=$(find "${subdir}project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
    design_spec_file=$(find   "${subdir}project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
    [ -n "$business_spec_file" ] && business_spec="${base}/project/$(basename "$business_spec_file")"
    [ -n "$design_spec_file"   ] && design_spec="${base}/project/$(basename "$design_spec_file")"

    jq -n \
      --arg   path         "$base" \
      --arg   readme       "$readme_rel" \
      --argjson chats       "$chats_json" \
      --argjson prototypes  "$protos_json" \
      --argjson hasReact    "$has_react" \
      --argjson hasTailwind "$has_tailwind" \
      --arg   businessSpec "$business_spec" \
      --arg   designSpec   "$design_spec" \
      '{
        path:         $path,
        readme:       $readme,
        chats:        $chats,
        prototypes:   $prototypes,
        hasReact:     $hasReact,
        hasTailwind:  $hasTailwind,
        businessSpec: (if $businessSpec == "" then null else $businessSpec end),
        designSpec:   (if $designSpec   == "" then null else $designSpec   end)
      }'
  }

  if [ "$all" = true ]; then
    # Return all bundles as a JSON array, sorted newest-first
    local entries_json="[]"
    while IFS= read -r entry; do
      local subdir="${entry#* }"
      local bundle_json
      bundle_json=$(_build_bundle_json "$subdir")
      entries_json=$(echo "$entries_json" | jq --argjson b "$bundle_json" '. + [$b]')
    done <<< "$sorted_paths"
    echo "$entries_json"
  else
    # Return only the newest bundle
    local newest_entry
    newest_entry=$(echo "$sorted_paths" | head -1)
    local newest_subdir="${newest_entry#* }"
    _build_bundle_json "$newest_subdir"
  fi
}

# ============================================================================
# Bundle Prototype Helpers
# ============================================================================

# Compute a SHA-256 hex digest for a single file.
# Uses sha256sum (Linux) or shasum -a 256 (macOS), honoring _HAS_SHA256SUM.
# Usage: _hash_file <path>
# Prints: 64-char hex string
_hash_file() {
  local path="$1"
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

# Compute a deterministic composite SHA-256 over an ordered list of file paths.
# Sorts the paths before concatenating so the hash is stable across runs.
# Usage: _compute_composite_hash <file1> [<file2> ...]
# Prints: 64-char hex string
_compute_composite_hash() {
  local sorted_paths
  sorted_paths=$(printf "%s\n" "$@" | sort)
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$sorted_paths" | shasum -a 256 | awk '{print $1}'
  fi
}

# Compute a deterministic SHA-256 over all regular files in a directory tree.
# Files are sorted by path before concatenation for determinism.
# Usage: _hash_dir <dir>
# Prints: 64-char hex string, or empty string if dir is empty/missing
_hash_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf ""
    return 0
  fi
  local file_list
  file_list=$(find "$dir" -type f | sort)
  if [ -z "$file_list" ]; then
    printf ""
    return 0
  fi
  if [ "$_HAS_SHA256SUM" -eq 1 ]; then
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | sha256sum | awk '{print $1}'
  else
    while IFS= read -r p; do cat "$p"; done <<< "$file_list" | shasum -a 256 | awk '{print $1}'
  fi
}

# Extract lines from a markdown file under a given top-level section heading.
# Matches /^## <N>\./ as the section start, reads until the next /^## [0-9]+\./ or EOF.
# Usage: _extract_markdown_section <file> <section_number>
# Prints: section body lines (stripped of the heading itself)
_extract_markdown_section() {
  local file="$1"
  local num="$2"
  awk -v n="$num" '
    /^## [0-9]+\./ {
      if (in_section) { exit }
      if ($0 ~ "^## " n "\\.") { in_section=1; next }
    }
    in_section { print }
  ' "$file"
}

# Parse bullet items from a markdown blob and return a JSON array.
# Each bullet (^- , ^* , or ^N. at the top level) is treated as one view entry.
# The view name is the first phrase up to the first colon, dash, or newline.
# Usage: _extract_view_list <markdown_text> <source_section>
# Prints: JSON array of {name, source_section} objects
_extract_view_list() {
  local text="$1"
  local source_section="$2"
  local json_array="[]"
  local name
  while IFS= read -r line; do
    # Match bullet: leading - , * , or digit followed by .
    case "$line" in
      [-*]\ *|[0-9]*.\ *)
        # Strip bullet prefix
        name="${line#[-*] }"
        name="${name#[0-9]*. }"
        # Trim to first colon or em-dash or plain dash
        name="${name%%:*}"
        name="${name%% -*}"
        name="${name%% —*}"
        # Trim leading/trailing whitespace via awk
        name=$(printf "%s" "$name" | awk '{$1=$1; print}')
        if [ -n "$name" ]; then
          json_array=$(printf "%s" "$json_array" | jq --arg n "$name" --arg s "$source_section" \
            '. + [{"name": $n, "source_section": $s}]')
        fi
        ;;
    esac
  done <<< "$text"
  printf "%s" "$json_array"
}

# Check bundle prototype generation status.
# Usage: aimi-cli.sh bundle-prototype-status --bundle <path> --topic <slug> [--force]
# Returns JSON with keys: needs_generation, view_list, view_source, output_path, sidecar_path
cmd_bundle_prototype_status() {
  local bundle_path="" topic_slug="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle) shift; bundle_path="${1:-}" ;;
      --topic)  shift; topic_slug="${1:-}" ;;
      --force)  force=true ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  if [ -z "$bundle_path" ]; then
    printf "Error: --bundle <path> is required\n" >&2; exit 1
  fi
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi

  # Bundle is a read-only input — allow absolute paths outside the project
  # (same pattern as cmd_detect_design_bundle --root).
  # Only the output paths (sidecar, html) must be within the project.
  if [ ! -d "$bundle_path" ]; then
    printf "Error: Bundle path does not exist or is not a directory: %s\n" "$bundle_path" >&2
    exit 1
  fi

  # Locate spec files inside the bundle (prefer bundle/project/ subdir)
  # Uses case-insensitive discovery so camelCase filenames are detected.
  local design_spec_path="" business_spec_path=""
  local _ds_proj _ds_root _bs_proj _bs_root
  _ds_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _ds_root=$(find "${bundle_path}"         -maxdepth 1 -iname "designspec.md"   -print -quit 2>/dev/null || true)
  _bs_proj=$(find "${bundle_path}/project" -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  _bs_root=$(find "${bundle_path}"         -maxdepth 1 -iname "businessspec.md" -print -quit 2>/dev/null || true)
  if [ -n "$_ds_proj" ]; then
    design_spec_path="$_ds_proj"
  elif [ -n "$_ds_root" ]; then
    design_spec_path="$_ds_root"
  fi
  if [ -n "$_bs_proj" ]; then
    business_spec_path="$_bs_proj"
  elif [ -n "$_bs_root" ]; then
    business_spec_path="$_bs_root"
  fi

  # Derive output and sidecar paths — relative to the project root for portability.
  # AIMI_DIR is absolute after find_aimi_root(); strip PROJECT_ROOT prefix to get relative form.
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local output_path="${prototypes_dir}/${topic_slug}-bundle.html"
  local sidecar_path="${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate output paths stay within the project
  validate_path_in_project "${PROJECT_ROOT}/${output_path}"
  validate_path_in_project "${PROJECT_ROOT}/${sidecar_path}"

  # Compute current hashes
  local bundle_hash design_spec_hash business_spec_hash
  bundle_hash=$(_hash_dir "$bundle_path")
  if [ -n "$design_spec_path" ]; then
    design_spec_hash=$(_hash_file "$design_spec_path")
  else
    design_spec_hash=""
  fi
  if [ -n "$business_spec_path" ]; then
    business_spec_hash=$(_hash_file "$business_spec_path")
  else
    business_spec_hash=""
  fi

  # Extract view list: prefer DesignSpec § 4, fallback to BusinessSpec § 5 then § 6
  local view_list_json="[]"
  local view_source="none"

  if [ -n "$design_spec_path" ]; then
    local ds4
    ds4=$(_extract_markdown_section "$design_spec_path" "4")
    if [ -n "$ds4" ]; then
      local parsed
      parsed=$(_extract_view_list "$ds4" "designSpec § 4")
      local count
      count=$(printf "%s" "$parsed" | jq 'length')
      if [ "$count" -gt 0 ]; then
        view_list_json="$parsed"
        view_source="designSpec"
      fi
    fi
  fi

  if [ "$view_source" = "none" ] && [ -n "$business_spec_path" ]; then
    local bs5
    bs5=$(_extract_markdown_section "$business_spec_path" "5")
    if [ -n "$bs5" ]; then
      local parsed5
      parsed5=$(_extract_view_list "$bs5" "businessSpec § 5")
      local count5
      count5=$(printf "%s" "$parsed5" | jq 'length')
      if [ "$count5" -gt 0 ]; then
        view_list_json="$parsed5"
        view_source="businessSpec"
      fi
    fi

    if [ "$view_source" = "none" ]; then
      local bs6
      bs6=$(_extract_markdown_section "$business_spec_path" "6")
      if [ -n "$bs6" ]; then
        local parsed6
        parsed6=$(_extract_view_list "$bs6" "businessSpec § 6")
        local count6
        count6=$(printf "%s" "$parsed6" | jq 'length')
        if [ "$count6" -gt 0 ]; then
          view_list_json="$parsed6"
          view_source="businessSpec"
        fi
      fi
    fi
  fi

  # Determine needs_generation
  local needs_generation=false

  # If both specs are absent, view_source is none — no generation possible
  if [ "$view_source" = "none" ] && [ -z "$design_spec_path" ] && [ -z "$business_spec_path" ]; then
    needs_generation=false
  elif [ "$force" = "true" ]; then
    needs_generation=true
  elif [ ! -f "${PROJECT_ROOT}/${sidecar_path}" ]; then
    needs_generation=true
  else
    # Compare hashes from sidecar
    local sidecar_content
    sidecar_content=$(cat "${PROJECT_ROOT}/${sidecar_path}" 2>/dev/null || printf "{}")
    local sc_bundle sc_design sc_business
    sc_bundle=$(printf "%s" "$sidecar_content" | jq -r '.bundleHash // ""')
    sc_design=$(printf "%s" "$sidecar_content" | jq -r '.designSpecHash // ""')
    sc_business=$(printf "%s" "$sidecar_content" | jq -r '.businessSpecHash // ""')
    if [ "$sc_bundle" != "$bundle_hash" ] || \
       [ "$sc_design" != "$design_spec_hash" ] || \
       [ "$sc_business" != "$business_spec_hash" ]; then
      needs_generation=true
    fi
  fi

  jq -n \
    --argjson needs_generation "$needs_generation" \
    --argjson view_list "$view_list_json" \
    --arg view_source "$view_source" \
    --arg output_path "$output_path" \
    --arg sidecar_path "$sidecar_path" \
    '{
      needs_generation: $needs_generation,
      view_list: $view_list,
      view_source: $view_source,
      output_path: $output_path,
      sidecar_path: $sidecar_path
    }'
}

# Write the bundle-prototype sidecar atomically.
# Usage: aimi-cli.sh bundle-prototype-finalize \
#          --topic <slug> \
#          --bundle-hash <hex> \
#          --design-spec-hash <hex> \
#          --business-spec-hash <hex> \
#          --view-list <json-array> \
#          --source-command <brainstorm|plan>
cmd_bundle_prototype_finalize() {
  local topic_slug="" bundle_hash="" design_spec_hash="" business_spec_hash=""
  local view_list_json="" source_command=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --topic)              shift; topic_slug="${1:-}" ;;
      --bundle-hash)        shift; bundle_hash="${1:-}" ;;
      --design-spec-hash)   shift; design_spec_hash="${1:-}" ;;
      --business-spec-hash) shift; business_spec_hash="${1:-}" ;;
      --view-list)          shift; view_list_json="${1:-}" ;;
      --source-command)     shift; source_command="${1:-}" ;;
      *) printf "Error: Unknown flag: %s\n" "$1" >&2; exit 1 ;;
    esac
    shift
  done

  # Validate required args
  if [ -z "$topic_slug" ]; then
    printf "Error: --topic <slug> is required\n" >&2; exit 1
  fi
  if [ -z "$source_command" ]; then
    printf "Error: --source-command <brainstorm|plan> is required\n" >&2; exit 1
  fi
  # Validate source-command value
  if [ "$source_command" != "brainstorm" ] && [ "$source_command" != "plan" ]; then
    printf "Error: --source-command must be exactly 'brainstorm' or 'plan', got: %s\n" "$source_command" >&2
    exit 1
  fi

  # Validate view-list is valid JSON array
  if [ -z "$view_list_json" ]; then
    view_list_json="[]"
  fi
  if ! printf "%s" "$view_list_json" | jq -e '. | arrays' >/dev/null 2>&1; then
    printf "Error: --view-list must be a valid JSON array\n" >&2; exit 1
  fi

  # Compute sidecar path — AIMI_DIR is absolute after find_aimi_root()
  local aimi_rel="${AIMI_DIR#$PROJECT_ROOT/}"
  local prototypes_dir="${aimi_rel}/brainstorms/prototypes"
  local sidecar_path="${PROJECT_ROOT}/${prototypes_dir}/${topic_slug}-bundle-sidecar.json"

  # Validate path stays within project
  validate_path_in_project "$sidecar_path"

  # Ensure directory exists
  mkdir -p "$(dirname "$sidecar_path")"

  # Compute generatedAt timestamp
  local generated_at
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

  # Build sidecar JSON
  local sidecar_json
  sidecar_json=$(jq -n \
    --arg generatedAt "$generated_at" \
    --arg bundleHash "$bundle_hash" \
    --arg designSpecHash "$design_spec_hash" \
    --arg businessSpecHash "$business_spec_hash" \
    --argjson viewList "$view_list_json" \
    --arg sourceCommand "$source_command" \
    '{
      generatedAt: $generatedAt,
      bundleHash: $bundleHash,
      designSpecHash: $designSpecHash,
      businessSpecHash: $businessSpecHash,
      viewList: $viewList,
      sourceCommand: $sourceCommand
    }')

  # Write atomically: write to tmp then mv
  local tmp_sidecar
  tmp_sidecar=$(mktemp "${sidecar_path}.XXXXXX")
  printf "%s\n" "$sidecar_json" > "$tmp_sidecar"
  chmod 600 "$tmp_sidecar"
  mv "$tmp_sidecar" "$sidecar_path"

  # Output confirmation JSON
  jq -n \
    --arg sidecar_path "$sidecar_path" \
    --arg generatedAt "$generated_at" \
    '{ written: $sidecar_path, generatedAt: $generatedAt }'
}

# Return the path to the OpenCode models validation cache file, keyed by mtime.
# Usage: _oc_models_cache_path <mtime>
# The cache stores the `opencode models` output for a specific models.json mtime.
_oc_models_cache_path() {
  local mtime="$1"
  local aimi_dir
  aimi_dir=$(_aimi_config_dir)
  printf '%s\n' "$aimi_dir/models-oc-cache-${mtime}.txt"
}

# ---------------------------------------------------------------------------
# "Is this model id valid for this host?" — ONE implementation, three parts.
#
# The question used to be answered in four places that disagreed with each
# other (resolve-models' two per-host branches, detect-models' interactive
# prompt, detect-models' flag mode, which answered "yes" to everything), plus a
# fifth representation of the same set in list-models. What is shared is the
# SHAPE, not the answer: normalize the candidate, obtain the host's valid set,
# decide membership, report the same verdict everywhere. The valid set still
# differs per host — Claude Code's three short aliases versus OpenCode's
# runtime `opencode models` output — because that is DATA, not a second
# implementation.
#
# NORMALIZATION IS A SEPARATE STEP APPLIED BEFORE VALIDITY, NOT PART OF IT.
# Two reasons, both load-bearing:
#   1. cmd_list_models needs the normalized SET without any validity question
#      being asked of it, so normalization has to be independently callable.
#   2. Keeping the trim OUT of the predicate means the predicate can never
#      quietly accept a value that was stored untrimmed — a caller that skips
#      normalization gets a refusal, not a silent repair.
# ---------------------------------------------------------------------------

# Normalize one model id: trim LEADING and TRAILING whitespace only, NEVER
# internal. Prints the normalized id; returns non-zero when the result is empty
# ("no id"), printing nothing.
#
# Internal whitespace is deliberately preserved: 'son net' must stay 'son net'
# and be REFUSED, not repaired into the valid alias 'sonnet'. The interactive
# prompt used to do exactly that repair with `tr -d '[:space:]'`.
#
# It also assigns the global _MODEL_ID_NORMALIZED, so a caller normalizing a
# whole list (_host_valid_models, below) can read the result without paying a
# subshell fork per entry. One trim rule, one place — there is no second
# expression of it anywhere in this file.
_normalize_model_id() {
  local _raw="${1-}"
  _MODEL_ID_NORMALIZED="${_raw#"${_raw%%[![:space:]]*}"}"
  _MODEL_ID_NORMALIZED="${_MODEL_ID_NORMALIZED%"${_MODEL_ID_NORMALIZED##*[![:space:]]}"}"
  [ -n "$_MODEL_ID_NORMALIZED" ] || return 1
  printf '%s' "$_MODEL_ID_NORMALIZED"
}

# Print the current host's valid model set, one NORMALIZED id per line.
#   Claude Code — the three short aliases the Task tool accepts, and only those.
#   OpenCode    — `opencode models` output, normalized, empty entries dropped,
#                 cached by models.json mtime exactly as cmd_resolve_models
#                 cached it before this helper existed.
#
# Prints NOTHING when there is no valid set to be had (the opencode binary is
# absent, or it returned nothing). Callers read empty as "no valid set
# available" and preserve the existing fail-safe: the configured value is used
# as-is rather than refused against a set nobody could produce.
_host_valid_models() {
  if _is_claude_code_host; then
    printf 'opus\nsonnet\nhaiku\n'
    return 0
  fi

  command -v opencode >/dev/null 2>&1 || return 0

  local _config_file _mtime _cache_file _raw="" _line _dir
  _config_file=$(_aimi_models_config_path)
  _mtime=$(stat -c '%Y' "$_config_file" 2>/dev/null || stat -f '%m' "$_config_file" 2>/dev/null || echo "0")
  _cache_file=$(_oc_models_cache_path "$_mtime")

  if [ -f "$_cache_file" ]; then
    _raw=$(cat "$_cache_file" 2>/dev/null) || _raw=""
  fi
  if [ -z "$_raw" ]; then
    _raw=$(opencode models 2>/dev/null) || _raw=""
    if [ -n "$_raw" ]; then
      # Write to cache (best-effort; failure is non-fatal)
      _dir=$(_aimi_config_dir)
      mkdir -p "$_dir" 2>/dev/null || true
      printf '%s\n' "$_raw" > "$_cache_file" 2>/dev/null || true
    fi
  fi

  [ -n "$_raw" ] || return 0

  while IFS= read -r _line; do
    _normalize_model_id "$_line" >/dev/null || continue
    printf '%s\n' "$_MODEL_ID_NORMALIZED"
  done <<< "$_raw"
}

# Membership of an ALREADY-NORMALIZED candidate in the host's valid set.
# Usage: _model_id_valid_for_host <normalized-candidate> [<valid-set>]
#
# It never trims — normalization is the caller's separate, earlier step, which
# is what stops this predicate from quietly accepting a value stored untrimmed.
# The valid set defaults to _host_valid_models; a caller that already holds one
# passes it explicitly (cmd_detect_models substitutes a built-in Anthropic list
# when the opencode binary is absent) so that exactly one membership rule runs
# everywhere. An empty valid set means "no valid set available" and yields the
# fail-safe verdict: valid.
_model_id_valid_for_host() {
  local _candidate="${1-}" _valid
  if [ $# -ge 2 ]; then
    _valid="$2"
  else
    _valid=$(_host_valid_models)
  fi
  [ -n "$_valid" ] || return 0
  printf '%s\n' "$_valid" | grep -qxF -- "$_candidate"
}

# Resolve which interactivity mode applies to the current shell.
# Prints exactly one of: picker, agent
#   agent  - AIMI_AGENT_MODE=true or CI=true (explicit overrides), OR no host
#            picker is available and stdin is not a TTY
#   picker - explicit host picker is available (Claude Code or OpenCode), OR
#            stdin is a TTY in a plain terminal
#
# Precedence (first match wins — explicit opt-out only):
#   1. --non-interactive flag → agent
#   2. AIMI_AGENT_MODE=true  → agent
#   3. CI=true               → agent
#   4. otherwise             → picker
#
# The old TTY-test branch ([ -t 0 ]) and the CLAUDECODE/OPENCODE_CONFIG_DIR
# host-check block are removed. A non-TTY shell is NOT a signal for agent mode;
# picker is the safe default so commands always surface Open Questions unless
# explicitly told not to.
cmd_detect_interactivity() {
  local non_interactive=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --non-interactive) non_interactive=1 ;;
    esac
    shift
  done
  if [ "$non_interactive" = "1" ] || [ "${AIMI_AGENT_MODE:-}" = "true" ] || [ "${CI:-}" = "true" ]; then
    echo "agent"
    return
  fi
  echo "picker"
}

# Resolve which configured model for each agent category.
# Reads ~/.config/aimi/models.json (schema v2.0) and maps each of the five
# categories (research, review, design, workflow, executor) to a concrete model ID.
# Schema v2.0 shape: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct one-level lookup: .categories[<host>][<category>] → model id.
# Always emits a single-line compact JSON object with all five keys.
# Unconfigured or fallback entries use the literal string "inherit".
# All warnings go to stderr; stdout is always valid JSON.
#
# v1.0 rejection: if the parsed JSON has a top-level .models key OR
# .schemaVersion is not "2.0", emits a stderr warning containing "schema 1.0"
# and returns the all-inherit fallback. Re-run `aimi-cli detect-models` to
# upgrade the config to v2.0.
#
# The document half — the schema verdict, the per-category lookup, the validity
# question and every warning — is models.py's, at one crossing. What stays here
# is what bash owns anyway: where the file lives, whether it exists, whether it
# is empty, which host this is, the host's valid set (which is where the
# `opencode` shell-out and its mtime-keyed cache live), and the fallback
# literal, which is needed on three paths that never reach python3 at all.
cmd_resolve_models() {
  # check_jq stays, in all three verbs that had it, although none of them runs
  # jq any more. Dropping it would let a jq-less host THROUGH where it is
  # refused today — a behaviour change, and one with no bearing on this port.
  # Retiring the three calls is its own decision and its own commit.
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  # Fallback JSON — all five categories as inherit
  local _fallback='{"research":"inherit","review":"inherit","design":"inherit","workflow":"inherit","executor":"inherit"}'

  # No config file → silent fallback (preserves current behavior)
  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Read config (use read_aimi_models_config for consistent access)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: resolve-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  # Determine host key
  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  # The host's valid set — Claude Code's three aliases, or OpenCode's
  # `opencode models` output — plus the two host-shaped literals its warnings
  # read. An EMPTY set means "no valid set available" (no opencode binary, or
  # one that printed nothing); models.py then skips validation entirely, which
  # is the fail-safe that keeps a configured value usable rather than refusing
  # it against a set nobody could produce.
  #
  # This runs BEFORE the python3 check on purpose: it is what writes the
  # OpenCode cache file, so a host without an interpreter leaves the same
  # files behind as one with it.
  local _valid_models _host_name _host_qualifier
  _valid_models=$(_host_valid_models)
  if _is_claude_code_host; then
    _host_name="Claude Code"
    _host_qualifier="must be exactly opus, sonnet, or haiku; "
  else
    _host_name="OpenCode"
    _host_qualifier=""
  fi

  if ! _models_python3_or_degrade resolve-models all-inherit; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  # One crossing. models.py prints the resolved object, or the fallback it was
  # handed plus the branch's own warning, and returns 0 either way — there is
  # no input left that makes this verb fail. The jq before it had exactly one:
  # a non-string category value aborted it at exit 5 with both streams empty,
  # which is D1 in tests/golden_from_jq.json's _comment_models_read.
  printf '%s' "$config_json" | python3 "$(_aimi_models_py)" resolve \
    --host "$host" \
    --config-file "$config_file" \
    --fallback "$_fallback" \
    --valid "$_valid_models" \
    --host-name "$_host_name" \
    --host-qualifier "$_host_qualifier"
}

# Emit the current per-category model assignments for the active host.
# Shape: {"research": <id|null>, "review": <id|null>, "design": <id|null>,
#         "workflow": <id|null>, "executor": <id|null>}
# Unlike resolve-models, unset entries emit JSON null (not the string "inherit")
# so the /aimi:setup-models picker can distinguish "not configured" from a literal
# "inherit" override and pre-select sensible defaults.
# Schema v1.0 configs are rejected with the same stderr warning resolve-models emits;
# stdout falls back to all-null on rejection or any error.
cmd_get_current_models() {
  check_jq

  local config_file
  config_file=$(_aimi_models_config_path)

  local _fallback='{"research":null,"review":null,"design":null,"workflow":null,"executor":null}'

  if [ ! -f "$config_file" ]; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "Warning: get-current-models: models config file is empty: $config_file" >&2
    printf '%s\n' "$_fallback"
    return 0
  fi

  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  if ! _models_python3_or_degrade get-current-models all-null; then
    printf '%s\n' "$_fallback"
    return 0
  fi

  # One crossing, into the same reader resolve-models uses, differing by the
  # flag it is NOT given: no valid set, so no validation and no warning — this
  # verb hands back what is stored, including a value resolve-models would
  # refuse. The unset value is JSON null here and the string "inherit" there,
  # deliberately: /aimi:setup-models has to tell "not configured" apart from a
  # literal `inherit` override, and only null says the first.
  printf '%s' "$config_json" | python3 "$(_aimi_models_py)" current \
    --host "$host" \
    --config-file "$config_file" \
    --fallback "$_fallback"
}

# List available models for the current host as a JSON array on stdout.
# Claude Code host: the three short aliases opus/sonnet/haiku.
# OpenCode host: the `opencode models` output.
#   Falls back to the built-in default Anthropic list when the opencode binary is absent,
#   printing one warning to stderr.
# stdout is always a valid JSON array; warnings go to stderr.
#
# The set comes from _host_valid_models, so what the picker OFFERS is byte for
# byte the set cmd_resolve_models validates against: entries normalized, empty
# entries dropped. This array can no longer contain "  anthropic/claude-sonnet-4-6  "
# or "". No validity question is asked here — normalization is a separate,
# independently callable step, and this is the caller that needs only that half.
cmd_list_models() {
  check_jq

  # THE CLAUDE CODE BRANCH CROSSES NOTHING. Its answer is a constant — the
  # three short aliases the Task tool accepts — so there is no document to
  # read and no interpreter to need. The same three ids are DATA that
  # _host_valid_models already spells once; this is that data in JSON, and
  # test_list_models_claudecode_matches_the_host_valid_set in part2 runs both
  # and compares them, so the second spelling cannot drift from the first.
  if _is_claude_code_host; then
    printf '[\n  "opus",\n  "sonnet",\n  "haiku"\n]\n'
    return 0
  fi

  local _models_list
  _models_list=$(_host_valid_models)

  if [ -z "${_models_list:-}" ]; then
    echo "Warning: list-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
    _models_list="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
  fi

  if ! _models_python3_or_degrade list-models "the built-in Anthropic model list"; then
    printf '[\n  "anthropic/claude-haiku-4-5",\n  "anthropic/claude-sonnet-4-6",\n  "anthropic/claude-opus-4-7"\n]\n'
    return 0
  fi

  # One crossing, on this branch only: the newline-delimited list to a JSON
  # array, which is all `jq -R . | jq -s .` ever did here.
  printf '%s\n' "$_models_list" | python3 "$(_aimi_models_py)" list
}

# Detect available models on the current host and write ~/.config/aimi/models.json.
# Writes schema v2.0: {schemaVersion:"2.0", categories:{<host>:{<cat>:<modelId>}}}
# Direct category-to-model mapping — no tier indirection.
# On Claude Code (CLAUDECODE=1): fixed set — haiku, sonnet, opus (short aliases required by Task tool).
# On OpenCode: reads `opencode models`; falls back to a built-in default Anthropic list
#   with one warning when the opencode binary is absent.
#
# Flag mode (non-interactive write): when ANY of --research, --review, --design,
#   --workflow, --executor is provided, build and write models.json with the given
#   category-to-model assignments directly, skipping the TTY prompt. Preserves the
#   other host's categories sub-table when a pre-existing file exists.
#   --research <model>  Model id for the research category
#   --review <model>    Model id for the review category
#   --design <model>    Model id for the design category
#   --workflow <model>  Model id for the workflow category
#   --executor <model>  Model id for the executor category
#   All five flags must be supplied together.
#
# Interactive (stdin is a TTY, no category flags): prompts once per category for a
#   concrete model id, validated against the host's available-model list.
# Non-interactive (no flags, stdin is not TTY): writes sensible defaults without prompting.
# Writes atomically via write_aimi_models_config (mktemp + chmod 0600 + mv).
# NOTE: Only the current host's sub-table is written. Re-run on the other host to
#       populate both claudeCode and opencode tables.
cmd_detect_models() {
  check_jq
  # python3 owns this verb's document half, and unlike the four READERS beside
  # it there is no degrade a writer may take. Writing the current host's five
  # values alone is the 1.97.2 regression; writing nothing and returning 0
  # tells /aimi:setup-models the config was saved when it was not. So this
  # refuses at exit 1 BEFORE a prompt is shown, a cache is written or a flag is
  # judged — which is exactly what setup-models.md already promises its reader:
  # "if detect-models exits non-zero, report the error verbatim and STOP — the
  # config file was not written."
  check_python3

  # ---- Parse category flags --------------------------------------------------
  local _flag_research="" _flag_review="" _flag_design="" _flag_workflow="" _flag_executor=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --research)
        shift
        _flag_research="${1:-}"
        ;;
      --review)
        shift
        _flag_review="${1:-}"
        ;;
      --design)
        shift
        _flag_design="${1:-}"
        ;;
      --workflow)
        shift
        _flag_workflow="${1:-}"
        ;;
      --executor)
        shift
        _flag_executor="${1:-}"
        ;;
      -*)
        echo "Error: detect-models: unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  # ---- Determine host key for models table ----------------------------------
  local _host_key
  if _is_claude_code_host; then
    _host_key="claudeCode"
  else
    _host_key="opencode"
  fi

  # The five values the document gets, however they were arrived at. Both modes
  # fill these in and then STOP: the read, the merge, the write and the two
  # notes below are one tail serving both, where they used to be two verbatim
  # copies of the same forty lines.
  local _model_research _model_review _model_design _model_workflow _model_executor

  if [ -n "$_flag_research" ] || [ -n "$_flag_review" ] || [ -n "$_flag_design" ] || [ -n "$_flag_workflow" ] || [ -n "$_flag_executor" ]; then
    # ---- Flag mode: category flags provided → non-interactive write ---------
    # Require all five categories when using flag mode
    if [ -z "$_flag_research" ] || [ -z "$_flag_review" ] || [ -z "$_flag_design" ] || [ -z "$_flag_workflow" ] || [ -z "$_flag_executor" ]; then
      echo "Error: detect-models: when using category flags, all five must be provided: --research, --review, --design, --workflow, --executor" >&2
      exit 1
    fi

    # Route every flag value through the one normalizer and the one predicate
    # before writing. Two deliberate boundaries here:
    #
    #   - A merely-invalid id WARNS and is still written. Flag mode does not
    #     gain a new non-zero exit for it: /aimi:setup-models writes through
    #     this path (its picker offers a free-form "Other"), and this CLI's
    #     discipline is that validation happens at READ time — cmd_resolve_models
    #     is where an id is refused, and it says so with the same shape of
    #     message this warning uses.
    #   - A value that is non-empty but normalizes to EMPTY (whitespace only) is
    #     an argument error, not an invalid id, and takes the same hard-error
    #     path as the "all five must be provided" check directly above.
    local _flag_valid_set _flag_host_name
    _flag_valid_set=$(_host_valid_models)
    if _is_claude_code_host; then _flag_host_name="Claude Code"; else _flag_host_name="OpenCode"; fi

    _check_flag_model() {
      local _cat="$1" _raw="$2"
      if ! _normalize_model_id "$_raw" >/dev/null; then
        echo "Error: detect-models: --$_cat value is whitespace only, which is not a model id" >&2
        exit 1
      fi
      if ! _model_id_valid_for_host "$_MODEL_ID_NORMALIZED" "$_flag_valid_set"; then
        echo "Warning: detect-models: model '$_MODEL_ID_NORMALIZED' is not valid for $_flag_host_name host (category: $_cat); writing it anyway — resolve-models will fall back to inherit when it reads this file" >&2
      fi
    }

    _check_flag_model research "$_flag_research"; _model_research="$_MODEL_ID_NORMALIZED"
    _check_flag_model review   "$_flag_review";   _model_review="$_MODEL_ID_NORMALIZED"
    _check_flag_model design   "$_flag_design";   _model_design="$_MODEL_ID_NORMALIZED"
    _check_flag_model workflow "$_flag_workflow"; _model_workflow="$_MODEL_ID_NORMALIZED"
    _check_flag_model executor "$_flag_executor"; _model_executor="$_MODEL_ID_NORMALIZED"
  else
    # ---- Available model sets per host --------------------------------------
    local _available_models
    local _oc_absent=0

    # The host's valid set, normalized, from the one producer — the same set
    # cmd_list_models offers and cmd_resolve_models validates against.
    _available_models=$(_host_valid_models)
    if [ -z "${_available_models:-}" ]; then
      # Only reachable on OpenCode: _host_valid_models prints nothing when the
      # opencode binary is absent or returned nothing.
      _oc_absent=1
      echo "Warning: detect-models: opencode binary not found or returned no models; using built-in Anthropic model list." >&2
      _available_models="anthropic/claude-haiku-4-5
anthropic/claude-sonnet-4-6
anthropic/claude-opus-4-7"
    fi

    # ---- Build per-category model defaults ----------------------------------
    # research → fast (haiku), review → powerful (opus),
    # design/workflow/executor → balanced (sonnet)
    local _fast_model _balanced_model _powerful_model

    # `|| _x=""` is what makes the three fallbacks below REACHABLE. A grep that
    # matches nothing exits 1; `pipefail` hands that status to the whole
    # pipeline, and a BARE assignment to an already-declared local hands it to
    # `set -e`, which killed the verb here — exit 1, empty stdout, empty
    # stderr, nothing written — the moment the host's model list contained no
    # "haiku". Every `[ -z ... ] &&` line after it was dead code documenting a
    # behaviour that could not happen. The `||` makes "no match" an empty
    # string instead of a fatal status, which is what the next line already
    # assumed it was.
    _fast_model=$(printf '%s\n' "$_available_models" | grep -i "haiku" | head -1) || _fast_model=""
    [ -z "$_fast_model" ] && _fast_model=$(printf '%s\n' "$_available_models" | head -1)

    _balanced_model=$(printf '%s\n' "$_available_models" | grep -i "sonnet" | head -1) || _balanced_model=""
    [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | sed -n '2p')
    [ -z "$_balanced_model" ] && _balanced_model=$(printf '%s\n' "$_available_models" | head -1)

    _powerful_model=$(printf '%s\n' "$_available_models" | grep -i "opus" | head -1) || _powerful_model=""
    [ -z "$_powerful_model" ] && _powerful_model=$(printf '%s\n' "$_available_models" | tail -1)

    # Per-category defaults: research=fast, review=powerful, design/workflow/executor=balanced
    local _default_research="$_fast_model"
    local _default_review="$_powerful_model"
    local _default_design="$_balanced_model"
    local _default_workflow="$_balanced_model"
    local _default_executor="$_balanced_model"

    # ---- Per-category model assignment --------------------------------------
    _model_research="$_default_research"
    _model_review="$_default_review"
    _model_design="$_default_design"
    _model_workflow="$_default_workflow"
    _model_executor="$_default_executor"

    if [ -t 0 ]; then
      # stdin is a TTY — prompt once per category for a concrete model id
      local _prompt_models
      _prompt_models=$(printf '%s\n' "$_available_models" | tr '\n' '|' | sed 's/|$//')

      _prompt_category() {
        local cat="$1"
        local default="$2"
        local answer
        printf 'Category %s — model [%s] (default: %s): ' "$cat" "$_prompt_models" "$default" >&2
        read -r answer </dev/tty
        # Normalize FIRST, as its own step: trim the ends only. This used to be
        # `tr -d '[:space:]'`, which deleted INTERNAL whitespace too and so
        # silently rewrote the typo 'son net' into the valid alias 'sonnet'.
        # Then ask the shared predicate — no second membership test lives here.
        # Fall back to the category default on empty or invalid input, unchanged.
        #
        # EOF at the prompt lands in that same fallback and always did, which is
        # why no `|| answer=""` was ever needed: bash CLEARS `set -e` inside a
        # command substitution when not in POSIX mode, so the failing `read`
        # takes nothing down and this function's status is the printf's. A
        # pty-driven test says so out loud (test_models.py), because reading it
        # off the source is exactly how it got recorded as a defect.
        if ! _normalize_model_id "$answer" >/dev/null; then
          printf '%s' "$default"
        elif _model_id_valid_for_host "$_MODEL_ID_NORMALIZED" "$_available_models"; then
          printf '%s' "$_MODEL_ID_NORMALIZED"
        else
          printf '%s' "$default"
        fi
      }

      _model_research=$(_prompt_category "research" "$_default_research")
      _model_review=$(_prompt_category "review"    "$_default_review")
      _model_design=$(_prompt_category "design"    "$_default_design")
      _model_workflow=$(_prompt_category "workflow"  "$_default_workflow")
      _model_executor=$(_prompt_category "executor"  "$_default_executor")
    fi
  fi

  # ---- Assemble the models.json document (v2.0 schema) ----------------------
  # Read the existing config FIRST so the OTHER host's sub-table survives.
  # Without that merge, an unflagged detect-models invocation (e.g. the
  # /aimi:plan automatic resolve at the top of every command) overwrites the
  # file with only the current host's block, silently dropping the inactive
  # host's configured models — which is exactly what shipped as 1.97.2 and was
  # fixed by copying the flag branch's merge over the default branch. That copy
  # is why this assembly existed twice, verbatim; merge_models_document in
  # models.py is the one place it lives now, and it takes the existing document
  # as a PARAMETER so a rebuild cannot be written there by accident.
  local _existing_json
  _existing_json=$(read_aimi_models_config) || _existing_json=""

  # One crossing. The document arrives on stdin and comes back merged on
  # stdout; nothing in models.py opens or writes a file, so the mktemp + chmod
  # 0600 + mv discipline stays in write_aimi_models_config, which already owns
  # it and whose failure text is asserted.
  local _models_json
  _models_json=$(printf '%s' "$_existing_json" | python3 "$(_aimi_models_py)" detect \
    --host-key "$_host_key" \
    --research "$_model_research" \
    --review   "$_model_review" \
    --design   "$_model_design" \
    --workflow "$_model_workflow" \
    --executor "$_model_executor")

  # ---- Atomic write ---------------------------------------------------------
  write_aimi_models_config "$_models_json"

  local _config_path
  _config_path=$(_aimi_models_config_path)
  printf 'detect-models: wrote %s table to %s\n' "$_host_key" "$_config_path" >&2
  printf 'detect-models: re-run on the other host to populate both claudeCode and opencode tables\n' >&2
  printf '%s\n' "$_models_json"
}

# Check whether the first-run model-selection prompt should be shown.
# Echoes exactly one token to stdout:
#   skip   — models.json already exists OR the marker file already exists
#   prompt — neither file exists (first run, not yet configured)
# The file questions are answered here; the document's own half — the v1.0
# verdict and "is this host configured at all" — is one crossing into models.py.
cmd_models_prompt_check() {
  local config_file
  config_file=$(_aimi_models_config_path)

  # Missing config → prompt
  if [ ! -f "$config_file" ]; then
    echo "prompt"
    return 0
  fi

  # Empty/unreadable file → prompt (user should re-configure)
  local config_json
  config_json=$(read_aimi_models_config) || config_json=""
  if [ -z "$config_json" ]; then
    echo "prompt"
    return 0
  fi

  local host
  if _is_claude_code_host; then
    host="claudeCode"
  else
    host="opencode"
  fi

  if ! _models_python3_or_degrade models-prompt-check prompt; then
    echo "prompt"
    return 0
  fi

  # The per-host dismissal marker is a FILE question, so it is answered here
  # and handed across as a flag rather than read twice. It only matters when
  # the config file is present but says nothing about this host: a missing
  # file always re-prompts (above), whatever the marker says.
  local marker_file marker=0
  marker_file=$(_aimi_models_prompt_marker_path)
  if [ -f "$marker_file" ]; then
    marker=1
  fi

  # One crossing: the v1.0 verdict and the "is this host configured at all"
  # question, both over the same parse.
  printf '%s' "$config_json" | python3 "$(_aimi_models_py)" prompt-check \
    --host "$host" \
    --marker "$marker"
}

# Atomically create the models first-run prompt marker file.
# Idempotent — safe to call when the marker already exists.
# Content: current date or a short sentinel line.
cmd_models_prompt_dismiss() {
  local marker_file
  marker_file=$(_aimi_models_prompt_marker_path)
  local marker_dir
  marker_dir=$(dirname "$marker_file")

  if ! mkdir -p "$marker_dir" 2>/dev/null; then
    echo "Error: models-prompt-dismiss: cannot create directory: $marker_dir" >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${marker_file}.XXXXXX")
  chmod 0600 "$tmp_file"
  printf 'models-prompt-seen: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')" > "$tmp_file"
  if ! mv "$tmp_file" "$marker_file"; then
    rm -f "$tmp_file" 2>/dev/null
    echo "Error: models-prompt-dismiss: mv failed for $marker_file" >&2
    return 1
  fi
  echo "models-prompt-dismiss: marker written to $marker_file"
}

# Setup branch: deterministic branch creation/checkout logic
# Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]
cmd_setup_branch() {
  local branch_name="" default_branch="" project_dir="" base_override=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --base)
        shift
        base_override="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh setup-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security)
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch_name" >&2
    exit 1
  fi

  # Validate default branch name (security)
  if ! [[ "$default_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid default branch name: $default_branch" >&2
    exit 1
  fi

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid base branch name: $base_override" >&2
    exit 1
  fi

  # Get current branch (empty string means detached HEAD)
  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")

  # Case 1: Already on target branch
  if [ "$current_branch" = "$branch_name" ]; then
    printf '{"branch":"%s","action":"already-on-branch"}\n' "$branch_name"
    return 0
  fi

  # Case 2: Target branch exists locally
  if git branch --list "$branch_name" | grep -q "$branch_name"; then
    git checkout "$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-local"}\n' "$branch_name"
    return 0
  fi

  # Case 3: Target branch exists on remote only
  if git ls-remote --heads origin "$branch_name" 2>/dev/null | grep -q "$branch_name"; then
    git checkout -b "$branch_name" "origin/$branch_name" >/dev/null 2>&1
    printf '{"branch":"%s","action":"checked-out-remote"}\n' "$branch_name"
    return 0
  fi

  # Case --base override: Branch is new and caller provided an explicit base.
  # The existence check stays here rather than in the shared resolver so this
  # hard failure keeps its exact stderr text and exit code regardless of how
  # the resolver's own "explicit-base" resolution behaves.
  if [ -n "$base_override" ]; then
    if ! git ls-remote --heads origin "$base_override" 2>/dev/null | grep -q "$base_override" && \
       ! git branch --list "$base_override" | grep -q "$base_override"; then
      echo "Error: Base branch does not exist: $base_override" >&2
      exit 1
    fi
  fi

  # Case 4/5: Branch is new — delegate the base decision to the shared
  # resolver (_resolve_branch_base) so this path can never drift from the
  # container path's resolve-base-branch. The mapping from reason to action
  # is total: explicit-base -> created-from-base, default-branch ->
  # created-from-default, detached-head and stacked-on-current both ->
  # created-from-current. target-exists is unreachable here — Case 1-3 above
  # already short-circuited on an existing target before the resolver runs.
  local resolution reason base
  resolution=$(_resolve_branch_base "$branch_name" "$default_branch" "$base_override")
  reason=$(echo "$resolution" | jq -r '.reason')
  base=$(echo "$resolution" | jq -r '.base')

  case "$reason" in
    explicit-base)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-base","base":"%s"}\n' "$branch_name" "$base_override"
      ;;
    default-branch)
      git checkout -b "$branch_name" "$base" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-default"}\n' "$branch_name"
      ;;
    detached-head|stacked-on-current)
      # Create from current HEAD (detached or carrying unmerged work) without
      # an explicit ref, matching the pre-existing behavior exactly.
      git checkout -b "$branch_name" >/dev/null 2>&1
      printf '{"branch":"%s","action":"created-from-current"}\n' "$branch_name"
      ;;
    *)
      echo "Error: Unexpected base-resolution reason: $reason" >&2
      exit 1
      ;;
  esac
  return 0
}

# Decide what branch a new branch or container should be cut from, without
# performing any git mutation. Single source of truth shared by the inline
# (cmd_setup_branch) and container (execute.md) paths so an empty/unset base
# can never mean "stack on current" on one path and "use the default branch"
# on the other. Assumes branch_name/default_branch/base_override are already
# validated and CWD is inside the target git repository.
#
# Resolution order (first match wins):
#   1. base_override given                                -> explicit-base
#   2. branch_name already exists locally or on origin     -> target-exists
#   3. HEAD is detached                                     -> detached-head
#   4. current branch IS default, or merged into origin/default -> default-branch
#   5. otherwise (current branch carries unmerged work)     -> stacked-on-current
#
# The emitted "base" prefers the origin/<name> remote-tracking ref over the
# bare local name, so a container is never cut from a stale local ref after a
# successful fetch -- mirroring how cmd_setup_branch already checks out
# origin/$default_branch for created-from-default. Two reasons opt out:
#
#   stacked-on-current -- the candidate is the caller's own checkout, and
#     inheriting its local tip is what stacking means. Preferring origin here
#     drops every commit made since the last push.
#   detached-head      -- base is the raw HEAD sha; there is no branch name to
#     prefer a remote ref for.
#
# promptNeeded is true only when reason resolves to stacked-on-current --
# the same four-condition gate execute.md Step 1.6 computes inline today
# (target absent locally and on origin, current branch not default, current
# branch not merged into origin/default), now computed once per repo here.
# Exact ref predicates. Every one of these answers a yes/no question about a
# single, fully-qualified ref -- never a pattern plus a substring grep.
#
# `git branch --list X | grep -q X` and `git ls-remote --heads origin X` both
# match loosely: ls-remote patterns match on trailing path components, so a
# probe for `main` reports refs/heads/team/main and the caller then emits an
# origin/main that does not resolve, killing worktree creation in any repo
# that happens to carry a scoped branch of the same leaf name.
_local_has_branch() {
  git show-ref --verify --quiet "refs/heads/$1"
}

_origin_has_branch() {
  git ls-remote --heads origin "refs/heads/$1" 2>/dev/null \
    | grep -q "[[:space:]]refs/heads/${1}$"
}

# Is <branch> already merged into origin/<default>?
#
# --format strips the "[* ] " column git normally prints, and -qxF matches the
# whole line literally. A regex match here is unsafe: git permits `.` in ref
# names, so a branch named feat.x matches a merged feat/x and its real
# unmerged work is discarded with no prompt -- the exact failure issue #78 is
# about, reached through a different door.
_is_merged_into_default() {
  git branch --format='%(refname:short)' --merged "origin/$2" 2>/dev/null \
    | grep -qxF "$1"
}

_resolve_branch_base() {
  local branch_name="$1" default_branch="$2" base_override="$3"
  local current_branch reason base candidate prompt_needed
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  base=""
  candidate=""
  prompt_needed=false

  if [ -n "$base_override" ]; then
    reason="explicit-base"
    candidate="$base_override"
  elif _local_has_branch "$branch_name" || _origin_has_branch "$branch_name"; then
    reason="target-exists"
    candidate="$branch_name"
  elif [ -z "$current_branch" ]; then
    reason="detached-head"
    base=$(git rev-parse HEAD 2>/dev/null || echo "")
  elif [ "$current_branch" = "$default_branch" ] || _is_merged_into_default "$current_branch" "$default_branch"; then
    reason="default-branch"
    candidate="$default_branch"
  else
    reason="stacked-on-current"
    candidate="$current_branch"
    prompt_needed=true
  fi

  # Origin preference, scoped by reason: prefer the origin/<name>
  # remote-tracking ref for a reference point the caller did not author, so a
  # container is never cut from a stale local ref after a successful fetch.
  #
  # stacked-on-current is deliberately excluded. There the candidate IS the
  # caller's own checkout, and inheriting its local tip is the entire point of
  # stacking -- preferring origin would silently drop every commit made since
  # the last push, which is the common state of an autonomous run. That would
  # also put this path back in disagreement with cmd_setup_branch, whose
  # stacked-on-current arm checks out from local HEAD.
  if [ -n "$candidate" ]; then
    if [ "$reason" != "stacked-on-current" ] && _origin_has_branch "$candidate"; then
      base="origin/$candidate"
    else
      base="$candidate"
    fi
  fi

  printf '{"base":"%s","reason":"%s","currentBranch":"%s","defaultBranch":"%s","promptNeeded":%s}\n' \
    "$base" "$reason" "$current_branch" "$default_branch" "$prompt_needed"
}

# CLI wrapper for _resolve_branch_base(): arg-parsing, --project cd and the
# three branch-name validations, mirroring cmd_setup_branch's shape exactly.
cmd_resolve_base_branch() {
  local branch_name="" default_branch="" project_dir="" base_override=""

  # Parse arguments (positional + flags)
  while [ $# -gt 0 ]; do
    case "$1" in
      --default-branch)
        shift
        default_branch="${1:-}"
        ;;
      --base)
        shift
        base_override="${1:-}"
        ;;
      --project)
        shift
        project_dir="${1:-}"
        ;;
      -*)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
        exit 1
        ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate required arguments
  if [ -z "$branch_name" ] || [ -z "$default_branch" ]; then
    echo "Usage: aimi-cli.sh resolve-base-branch <branchName> --default-branch <defaultBranch> [--base <baseBranch>] [--project <path>]" >&2
    exit 1
  fi

  _require_git_repo "$project_dir"

  # Validate branch name (security)
  if ! [[ "$branch_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $branch_name" >&2
    exit 1
  fi

  # Validate default branch name (security)
  if ! [[ "$default_branch" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $default_branch" >&2
    exit 1
  fi

  # Validate base override branch name (security)
  if [ -n "$base_override" ] && ! [[ "$base_override" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Error: Invalid branch name: $base_override" >&2
    exit 1
  fi

  _resolve_branch_base "$branch_name" "$default_branch" "$base_override"
}

# Clear all state files (preserves tasks directory)
cmd_clear_state() {
  rm -f "$AIMI_DIR/current-tasks" "$AIMI_DIR/current-branch" "$AIMI_DIR/current-story" "$AIMI_DIR/last-result" "$AIMI_DIR/cli-path"
  rm -f "$AIMI_DIR"/default-branch-* 2>/dev/null
  rm -f "$AIMI_DIR"/.state.lock "$AIMI_DIR"/*.lock 2>/dev/null
  rmdir "$AIMI_DIR"/*.lock.d 2>/dev/null || true
  echo "State cleared."
}

# Print the plugin version from plugin.json
# Print the installed plugin version.
#
# The only guard used to be that plugin.json EXISTS, and `jq -r '.version'`
# answers something for almost anything below that bar: the literal string
# `null` at exit 0 for a document with no version key, a JSON object
# pretty-printed across four lines at exit 0 when the key is not a string, and
# jq's own parse error at exit 4 for malformed JSON. This is the CLI identity
# probe -- a caller comparing its output against a version, or a human reading
# it, is entitled to a version string or an explanation, not `null` dressed as
# one. All three shapes are recorded in golden_from_jq.json's ver-* cases as
# they were.
cmd_version() {
  local script_path plugin_json version
  script_path="${BASH_SOURCE[0]:-$0}"
  plugin_json="$(cd "$(dirname "$script_path")/.." && pwd)/.claude-plugin/plugin.json"
  if [ ! -f "$plugin_json" ]; then
    echo "Error: plugin.json not found" >&2
    exit 1
  fi
  # `jq -e` exits non-zero when the filter produces no output, which is what
  # `empty` yields for a missing or non-string key -- so one expression covers
  # both, and a parse failure lands in the same branch.
  if ! version=$(jq -er 'if (.version | type) == "string" then .version else empty end' \
      "$plugin_json" 2>/dev/null); then
    echo "Error: plugin.json declares no string \"version\": $plugin_json" >&2
    exit 1
  fi
  printf '%s\n' "$version"
}

# Resolve a directory-source install's OWN version from the same two
# documents _directory_source_plugin_dir reads -- <config_dir>/plugins/
# known_marketplaces.json for the marketplace's installLocation, then that
# install's own .claude-plugin/marketplace.json for the aimi-engineering
# entry's version.
#
# Usage: _directory_source_installed_version <config_dir>
#
# cmd_check_version is the only caller. A directory-source path carries no
# version-numbered path segment for _extract_version_from_path to read -- it
# is measured to return the literal string "aimi-engineering" for one -- so
# this is check-version's own guarded lookup, following the same discipline
# _directory_source_plugin_dir documents: existence/type-checked before every
# jq call, degrading to empty on a missing or malformed document rather than
# letting `set -euo pipefail` abort the script. It duplicates
# _directory_source_plugin_dir's own installLocation selection (same
# directory-source filter, same ascending-key tie-break) rather than reusing
# it, because that function returns the joined PLUGIN directory, not the
# marketplace root the version lives under, and there is no general way to
# strip an arbitrary `.source` subpath back off of it.
#
# ALWAYS RETURNS 0, printing one version string or nothing -- the same
# contract _directory_source_plugin_dir and _resolve_latest_cache_path
# document.
_directory_source_installed_version() {
  local config_dir="$1"
  local km_file="$config_dir/plugins/known_marketplaces.json"

  local install_location=""
  install_location=$(jq -r '
      if type != "object" then empty else
        to_entries
        | map(select(.value.source.source == "directory"
                      and (.value.installLocation | type) == "string"))
        | sort_by(.key)
        | .[0].value.installLocation // empty
      end
    ' "$km_file" 2>/dev/null) || install_location=""
  [ -z "$install_location" ] && return 0

  [ "${install_location#/}" = "$install_location" ] && return 0
  [ -d "$install_location" ] || return 0
  install_location="${install_location%/}"

  local mp_file="$install_location/.claude-plugin/marketplace.json"
  local mp_type=""
  mp_type=$(jq -r 'type' "$mp_file" 2>/dev/null) || mp_type=""
  [ "$mp_type" = "object" ] || return 0

  local version=""
  version=$(jq -r '
      (.plugins // [])
      | map(select(.name == "aimi-engineering" and (.version | type) == "string"))
      | .[0].version // empty
    ' "$mp_file" 2>/dev/null) || version=""
  [ -z "$version" ] && return 0

  printf '%s\n' "$version"
}

# Resolve the version string for a cli-path that may be either shape
# cmd_check_version now handles: a versioned plugin-cache copy (the shape
# _extract_version_from_path was written for) or a directory-source install
# (no version segment in the path at all).
#
# Usage: _check_version_resolve_version <config_dir> <path>
#
# <path> is trusted as directory-source only when it EQUALS the path
# _resolve_directory_source_path itself resolves right now for <config_dir> --
# not merely for failing to match the cache-glob pattern. That equality check
# is what keeps this safe for an unrelated stale path (a leftover fake or
# pre-cache-era value that happens not to look like a cache-glob path either):
# without it, ANY non-glob-shaped stored path would borrow the CURRENT
# directory-source install's version by nothing more than config_dir
# proximity, which is wrong whenever the stored path names something else
# entirely. With it, the `current`, `stale` and `fixed` branches report a
# directory-source install's real semver instead of the literal string
# "aimi-engineering" exactly when the path in hand IS that install, and fall
# through to _extract_version_from_path's own (unchanged) answer otherwise --
# which is what every case that never seeds known_marketplaces.json already
# exercises today.
_check_version_resolve_version() {
  local config_dir="$1" path="$2"
  case "$path" in
    */plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh)
      _extract_version_from_path "$path"
      return 0
      ;;
  esac

  local ds_path=""
  ds_path=$(_resolve_directory_source_path "$config_dir" "scripts/aimi-cli.sh")
  if [ -n "$ds_path" ] && [ "$path" = "$ds_path" ]; then
    local ds_version=""
    ds_version=$(_directory_source_installed_version "$config_dir")
    if [ -n "$ds_version" ]; then
      printf '%s\n' "$ds_version"
      return 0
    fi
  fi

  _extract_version_from_path "$path"
}

# Check CLI version staleness
# Compares stored cli-path against the glob-resolved latest path
# Flags: --quiet (suppress stderr), --fix (auto-fix stale detection)
cmd_check_version() {
  local quiet=false fix=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=true ;;
      --fix)   fix=true ;;
      *)       break ;;
    esac
    shift
  done

  local stored_path latest_path stored_version latest_version
  local config_dir
  config_dir=$(_claude_config_dir)

  # ---- Layer 0 first: under AIMI_DEV_DIR this verb reports and stops.
  #
  # A STATUS OF ITS OWN, and NO --fix, and the second half is the reason the
  # first half exists. commands/references/cli-path-resolution.md has every
  # command call `check-version --quiet --fix` immediately after resolving a
  # path, so --fix is not a rare maintenance gesture -- it runs constantly.
  # What it does is write the resolved install into `.aimi/cli-path` AND into
  # the GLOBAL cli-path cache, which is read by every later session in every
  # project on this machine. Under a dev override the install in hand is a
  # development tree, so a --fix here would persist that tree globally: the
  # override would stop being a per-shell experiment and become the machine's
  # plugin, outliving the shell that set the variable. That is exactly the
  # damage this override exists to avoid, so the answer is reported and
  # nothing is written.
  #
  # Placed above the converter branch and above every resolution below, so no
  # stale/fixed/current comparison is even computed: those compare the STORED
  # pointer against the INSTALLED one, and under an override neither is the
  # tree actually running. Exit 0 -- callers treat non-zero from this verb as
  # "stale, act on it", and there is nothing here for them to act on. The
  # notice naming the path was already printed by main().
  #
  # _dev_dir_path is re-consulted rather than memoized because a command
  # substitution runs in a subshell: a global that main() set inside one would
  # not survive back into this process. The checks are a handful of test
  # builtins and at most one realpath, on a verb that already runs jq.
  local dev_dir=""
  dev_dir=$(_dev_dir_path) || dev_dir=""
  if [ -n "$dev_dir" ]; then
    jq -n --arg path "$dev_dir/scripts/aimi-cli.sh" \
      '{status: "dev-override", path: $path, message: "AIMI_DEV_DIR is set; staleness is not meaningful against a development tree and --fix would persist it into the global cache"}'
    return 0
  fi

  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
    printf '{"status":"ok","path":"%s/scripts/aimi-cli.sh","message":"managed by compound-plugin converter"}\n' "$plugin_dir"
    return 0
  fi

  # Resolve the latest installed path (newest VERSION -- see
  # _resolve_latest_cache_path). An empty glob now answers with the empty string
  # instead of aborting the script, which is what makes the branch below
  # reachable for the first time.
  #
  # A host running from a directory-source (locally-added marketplace) install
  # never has a versioned entry under the cache glob, so an empty result here
  # falls back to _resolve_directory_source_path before this verb gives up --
  # same shape as the glob-then-fallback order every other caller of that
  # helper follows. Only when BOTH come up empty does the documented `unknown`
  # branch below fire.
  latest_path=$(_resolve_latest_cache_path "$config_dir" "scripts/aimi-cli.sh")
  if [ -z "$latest_path" ]; then
    latest_path=$(_resolve_directory_source_path "$config_dir" "scripts/aimi-cli.sh")
  fi

  # ---- The SECOND pointer, healed here rather than in the fix branch below.
  #
  # This verb is what commands/references/cli-path-resolution.md calls right
  # after every path resolution, so --fix is the curation entry point for the
  # whole pointer family -- not only for the one pointer whose staleness this
  # verb reports. It sits ABOVE the `unknown` early return and outside the
  # stored-vs-latest comparison on purpose: worktree-path can be missing or
  # stale while cli-path is already `current`, and healing it only in the
  # `fixed` branch would leave exactly the divergence this exists to close.
  # _persist_worktree_pointer_for is idempotent and reads one file when there
  # is nothing to do, so paying for it on every --fix is cheaper than being
  # wrong about when it is needed.
  #
  # THE FALLBACK IS THE RUNNING SCRIPT, and only when nothing is installed.
  # An empty latest_path means both the versioned-cache glob and the
  # directory-source resolver came up empty -- there is no install to derive a
  # sibling from -- but this script is nonetheless executing from somewhere,
  # and on a host running the plugin straight out of a checkout that somewhere
  # has the manager beside it. Restricting the fallback to the empty case is
  # what keeps a RESOLVED-but-manager-less install (a fake cache entry, an
  # OpenCode plugin dir with only scripts/) writing nothing at all, rather
  # than silently pointing the pointer at whatever tree this process happens
  # to have been launched from.
  if [ "$fix" = true ]; then
    local worktree_source="$latest_path"
    if [ -z "$worktree_source" ]; then
      worktree_source=$(resolve_path "$0" 2>/dev/null) || worktree_source=""
    fi
    _persist_worktree_pointer_for "$worktree_source"
  fi

  # Case: glob AND directory-source fallback both returned empty — no
  # installed version found.
  # CALLER-VISIBLE: this branch is documented but was dead code until the
  # glob helper stopped returning non-zero. A caller that read "check-version
  # aborts" as its no-plugin signal now gets this JSON at exit 0 instead.
  if [ -z "$latest_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No installed aimi-cli.sh found via glob." >&2
    fi
    jq -n '{status: "unknown", message: "No installed version found"}'
    return 0
  fi

  latest_version=$(_check_version_resolve_version "$config_dir" "$latest_path")

  # Read stored path from state
  stored_path=$(read_state "cli-path")

  # Case: .aimi/cli-path does not exist — missing is not stale
  if [ -z "$stored_path" ]; then
    if [ "$quiet" = false ]; then
      echo "Warning: No stored cli-path found. Run init-session to persist." >&2
    fi
    jq -n --arg ver "$latest_version" --arg path "$latest_path" \
      '{status: "missing", latestVersion: $ver, latestPath: $path}'
    return 0
  fi

  stored_version=$(_check_version_resolve_version "$config_dir" "$stored_path")

  # Case: stored path matches latest — current
  if [ "$stored_path" = "$latest_path" ]; then
    jq -nc --arg v "$stored_version" '{status:"current",version:$v}'
    return 0
  fi

  # Case: stored path differs — stale
  if [ "$fix" = true ]; then
    write_state "cli-path" "$latest_path"
    write_global_cli_cache "$latest_path"
    jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
      '{status: "fixed", storedVersion: $sv, latestVersion: $lv}'
    return 0
  fi

  if [ "$quiet" = false ]; then
    echo "Warning: CLI version is stale. Stored: $stored_version, Latest: $latest_version" >&2
  fi
  jq -n --arg sv "$stored_version" --arg lv "$latest_version" \
       --arg sp "$stored_path" --arg lp "$latest_path" \
    '{status: "stale", storedVersion: $sv, latestVersion: $lv, storedPath: $sp, latestPath: $lp}'
  return 1
}

# Remove old cached plugin version directories, keeping only the latest
# Scans <config_dir>/plugins/cache/*/aimi-engineering/*/ for version dirs
# Outputs JSON {"removed":<count>,"kept":"<version>"} to stdout
cmd_cleanup_versions() {
  # When AIMI_PLUGIN_DIR is set and NOT inside Claude Code, the converter manages the lifecycle
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)
  if [ -n "$plugin_dir" ] && ! _is_claude_code_host; then
    printf '{"removed":0,"skipped":true,"message":"converter manages lifecycle"}\n'
    return 0
  fi

  local latest_path latest_version latest_version_dir
  local removed=0
  local config_dir
  config_dir=$(_claude_config_dir)

  # Resolve the latest installed path. This verb rm -rf's every version
  # directory it does NOT pick, so "latest" has to mean newest version rather
  # than lexicographically last -- see _resolve_latest_cache_path.
  latest_path=$(_resolve_latest_cache_path "$config_dir" "scripts/aimi-cli.sh")

  # No installed versions found. CALLER-VISIBLE: dead code until the helper
  # stopped returning non-zero on an empty glob. Note it returns BEFORE
  # write_global_cli_cache, so an empty cache still writes no cli-path.
  if [ -z "$latest_path" ]; then
    jq -n '{removed: 0, kept: null}'
    return 0
  fi

  latest_version=$(_extract_version_from_path "$latest_path")
  # .../aimi-engineering/1.4.0/scripts/aimi-cli.sh -> .../aimi-engineering/1.4.0
  latest_version_dir=$(dirname "$(dirname "$latest_path")")

  # STANDING INVARIANT: no resolver may ever hand latest_version_dir (built
  # above; used only as the skip comparison below and the two writes after
  # this loop) a path outside <config_dir>/plugins/cache/. Today the loop
  # immediately below is version_dir's ONLY source, so that invariant holds by
  # construction and this rm -rf cannot reach anything outside the cache.
  # That is an accident of the glob, not a property this function asserts --
  # if a future edit ever widens where version_dir comes from (e.g. giving
  # this verb the same directory-source fallback prime-cache uses), the
  # confinement check immediately before the rm -rf below is what makes
  # REFUSING that safe, rather than silently deleting every directory this
  # loop walks.
  local resolved_cache_root
  resolved_cache_root=$(resolve_path "$config_dir/plugins/cache" 2>/dev/null) || resolved_cache_root=""

  # Iterate all version directories under all marketplace cache entries
  local version_dir
  for version_dir in "$config_dir"/plugins/cache/*/aimi-engineering/*/; do
    # Strip trailing slash for clean comparison
    version_dir="${version_dir%/}"

    # Skip if this is the latest version directory
    if [ "$version_dir" = "$latest_version_dir" ]; then
      continue
    fi

    # Skip if not actually a directory (glob might not expand)
    if [ ! -d "$version_dir" ]; then
      continue
    fi

    # Confinement check: refuse to delete anything whose resolved path is not
    # inside the resolved cache root, regardless of how version_dir got here.
    local resolved_target
    resolved_target=$(resolve_path "$version_dir" 2>/dev/null) || resolved_target=""
    if [ -z "$resolved_cache_root" ] || [ -z "$resolved_target" ]; then
      echo "Warning: refusing to remove $version_dir (could not resolve cache root)" >&2
      continue
    fi
    case "$resolved_target" in
      "$resolved_cache_root"/*) ;;
      *)
        echo "Warning: refusing to remove $version_dir (outside $resolved_cache_root)" >&2
        continue
        ;;
    esac

    # Attempt removal; log warning and continue on failure
    if rm -rf "$version_dir" 2>/dev/null; then
      removed=$((removed + 1))
    else
      echo "Warning: Failed to remove $version_dir" >&2
    fi
  done

  # Update cli-path state to point to the latest version
  write_state "cli-path" "$latest_path"
  write_global_cli_cache "$latest_path"
  # And the worktree pointer with it. This verb is where the divergence was
  # actually PRODUCED: the rm -rf loop above has just deleted every version
  # directory it did not keep, so any worktree-path still naming one of them
  # is now a path to nothing. Re-pointing it at the kept version in the same
  # breath as the cli-path is the difference between a stale pointer and a
  # dangling one.
  _persist_worktree_pointer_for "$latest_path"

  jq -n --argjson removed "$removed" --arg kept "$latest_version" \
    '{removed: $removed, kept: $kept}'
}

# Prime the global CLI path cache explicitly.
# Used by install hooks and slash commands to populate the cache without relying
# on the lazy-resolution layers.
#
# ---------------------------------------------------------------------------
# WHY THIS VERB, AND THE THREE AROUND IT, STAY BASH + jq
#
# The normative statement for the version/cache family lives here because this
# is the verb with the hardest constraint. `version`, `check-version`,
# `cleanup-versions` and `prime-cache` DO NOT CROSS INTO PYTHON, and that is a
# decision rather than an omission.
#
# These verbs, with the helper family beside them (read_global_cli_cache,
# write_global_cli_cache, read_global_worktree_cache, _claude_config_dir,
# _extract_version_from_path, _validate_plugin_dir), are what LOCATE
# aimi-cli.sh. tasks.py, roadmap.py, models.py and story_merge.py live in the
# same directory as the CLI being located, so a check_python3 gate here would
# make finding the CLI depend on having found it. Concretely: install.sh calls
# `prime-cache` DURING the OpenCode install, and commands/references/
# cli-path-resolution.md calls `check-version --quiet --fix` immediately after
# every path resolution -- both would start requiring an interpreter on hosts
# that today need only Bash and jq. `version` is the CLI identity probe and has
# the same problem for the same reason.
#
# `cleanup-versions` is the one verb off that hot path, and it stays Bash on
# different grounds: the pure-Bash comparator that decides which install it
# keeps landed six commits earlier in this same branch, and porting the verb
# here would delete that comparator inside the branch that added it.
#
# The jq calls stay too. Rewriting four `jq -n` constructors as printf would
# reproduce, not remove, the unescaped printf-built JSON already standing in
# cmd_check_version.
# ---------------------------------------------------------------------------
#
# JSON output: {status, path, host, version, message}
#   status: 'ok' | 'already_current' | 'not_found' | 'error'
#   path:   absolute path written (or null)
#   host:   'claude_code' | 'opencode'
#   version: semver extracted from path (or null)
#   message: optional human-readable string
#
# Exit codes: 0 for ok/already_current/not_found, 1 for error
cmd_prime_cache() {
  local host_label
  local resolved_path=""
  # Which of the two Claude Code sources answered resolved_path: "cache" (the
  # versioned plugin-cache glob, the pre-existing behaviour) or "directory" (a
  # directory-source install found only when that glob was empty). Nothing
  # downstream keys behaviour off _is_claude_code_host for this choice — see
  # the fallback site below for why not — so this is the one flag that decides
  # both which version-resolution path runs and whether the message field
  # gets a directory-source note. Stays "cache" on the OpenCode branch, which
  # this story does not touch.
  local resolved_source="cache"
  local plugin_dir
  plugin_dir=$(_validate_plugin_dir)

  # Determine host
  if _is_claude_code_host; then
    host_label="claude_code"
  elif [ -n "$plugin_dir" ]; then
    host_label="opencode"
  else
    # Neither CLAUDECODE=1 nor AIMI_PLUGIN_DIR set — try Claude Code glob anyway
    host_label="claude_code"
  fi

  # ---- Resolve path ----
  if [ "$host_label" = "opencode" ]; then
    # OpenCode branch: AIMI_PLUGIN_DIR is set and CLAUDECODE is unset.
    #
    # There is no traversal check here, and its absence is deliberate. One used
    # to stand below: `if [ "$candidate" != "$plugin_dir/scripts/aimi-cli.sh" ]`
    # -- compared against the expression `candidate` had been assigned from four
    # lines earlier, so it was tautologically false and its error branch could
    # not execute. Deleted rather than made real, because there is nothing here
    # for it to reject: `candidate` is CONSTRUCTED from $plugin_dir and no
    # caller-supplied component enters the string. What could genuinely be
    # wrong -- a $plugin_dir that is relative, absent, or full of `..` -- is
    # _validate_plugin_dir's job and it has already run; what the cache must not
    # later ACCEPT is _validate_cached_cli_path's, and it re-checks on read. An
    # unreachable branch left standing is worse than no branch, because it reads
    # like an assurance that traversal is handled at this point.
    local candidate="$plugin_dir/scripts/aimi-cli.sh"
    if [ ! -x "$candidate" ]; then
      jq -n --arg msg "AIMI_PLUGIN_DIR/scripts/aimi-cli.sh is not executable: $candidate" \
        '{status:"error",path:null,host:"opencode",version:null,message:$msg}'
      return 1
    fi
    resolved_path="$candidate"
  else
    # Claude Code branch: newest installed version (see
    # _resolve_latest_cache_path). This verb needed a `|| resolved_path=""` here
    # to survive an empty glob and reach its own not_found branch; the helper no
    # longer has a failure mode, so the guard is gone rather than left standing
    # as a hint that one exists.
    local config_dir
    config_dir=$(_claude_config_dir)
    resolved_path=$(_resolve_latest_cache_path "$config_dir" "scripts/aimi-cli.sh")

    # An empty glob means nothing is installed, and that is the whole test. It
    # used to be nested inside a second `[ -z "${AIMI_PLUGIN_DIR:-}" ]`, which
    # is a variable this branch has already decided not to honour -- Layer 0 is
    # skipped whenever CLAUDECODE is set (commands/references/
    # cli-path-resolution.md), and _is_claude_code_host above has already won
    # the host decision by the time we are here. Its only effect was to divert a
    # host carrying BOTH variables away from this return and into the pattern
    # check below, which refused the empty string for not matching a pattern the
    # empty string could never match -- a refusal whose message named a path
    # that had never been resolved. cmd_check_version and cmd_cleanup_versions
    # consult AIMI_PLUGIN_DIR once each, at the top, as part of host selection;
    # this was the one place in the file that re-consulted it inside the branch
    # CLAUDECODE had already decided.
    # Directory-source fallback. The versioned cache glob above is empty, but
    # this host may still be running the plugin straight out of a
    # directory-source (dev-mode) Claude Code install -- a marketplace added
    # FROM a checkout rather than installed as a versioned cache entry, so
    # _resolve_latest_cache_path's glob can never match it (see
    # _directory_source_plugin_dir's own header). Deliberately NOT gated on
    # _is_claude_code_host: this branch is already entered whenever
    # CLAUDECODE=1 OR neither discriminator is set ("try Claude Code glob
    # anyway" above), and the one flow a directory-source user actually has is
    # running this CLI by absolute path from a bare terminal with CLAUDECODE
    # unset. _resolve_directory_source_path ALWAYS returns 0 and prints one
    # candidate path or nothing, so this cannot abort the empty-glob case
    # under set -euo pipefail and cannot introduce a not_found regression: the
    # answer below is reached, unchanged, only when BOTH sources miss.
    if [ -z "$resolved_path" ]; then
      local dir_source_path=""
      dir_source_path=$(_resolve_directory_source_path "$config_dir" "scripts/aimi-cli.sh") || dir_source_path=""
      if [ -n "$dir_source_path" ]; then
        resolved_path="$dir_source_path"
        resolved_source="directory"
      fi
    fi

    if [ -z "$resolved_path" ]; then
      jq -n '{status:"not_found",path:null,host:"claude_code",version:null,message:"Plugin not installed. Run /plugin install aimi-engineering first."}'
      return 0
    fi

    # There is no cache-pattern check here, and its absence is deliberate. One
    # used to stand between the return above and the executable test below,
    # refusing any resolved_path outside */plugins/cache/*/aimi-engineering/*/
    # scripts/aimi-cli.sh. Deleted rather than kept, because nothing it could
    # reach was ever able to fail it: _resolve_latest_cache_path returns either
    # the empty string -- answered above, and the only input that gate ever
    # actually saw -- or one of its OWN glob's matches, and that glob
    # ("$config_dir"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh) is
    # the same shape as the pattern, so a match satisfies it by construction.
    # What the cache must not later ACCEPT is _validate_cached_cli_path's job,
    # and it re-checks on read. An unreachable branch left standing is worse
    # than no branch, because it reads like an assurance that shape is verified
    # at this point.

    # Verify executable
    if [ ! -x "$resolved_path" ]; then
      jq -n '{status:"error",path:null,host:"claude_code",version:null,message:"Resolved path is not executable"}'
      return 1
    fi
  fi

  # ---- Resolve version ----
  # _extract_version_from_path assumes a version-numbered path segment
  # (.../aimi-engineering/<version>/scripts/aimi-cli.sh) -- on a
  # directory-source path (.../<plugin_dir>/scripts/aimi-cli.sh, no such
  # segment) it returns the literal string "aimi-engineering" (measured),
  # which reads as a plausible version and is not one. resolved_source ==
  # "directory" routes here instead: re-derive plugin_dir from resolved_path
  # and read version the same way `version` does -- prefer the resolved
  # marketplace entry's own plugins[].version, else plugin_dir's own
  # plugin.json .version, else leave it empty (encoded as JSON null below).
  # This duplicates part of _directory_source_plugin_dir's own source-subpath
  # validation rather than calling it, because that helper answers "where is
  # THE directory-source plugin" and this needs "which known_marketplaces.json
  # ENTRY produced THIS resolved_path" -- a different question, and
  # known_marketplaces.json can hold more than one directory-source entry (see
  # that helper's own TIE-BREAK comment). Every jq call here is guarded the
  # same way that helper's are: `2>/dev/null` plus `|| var=""`, so a missing or
  # malformed marketplace.json degrades to silence under set -euo pipefail
  # rather than aborting -- this is what keeps the four named golden cases
  # (which carry no known_marketplaces.json at all) byte-identical, since none
  # of them ever reach this block with resolved_source == "directory".
  local resolved_version=""
  if [ "$resolved_source" = "directory" ]; then
    local dsv_plugin_dir="${resolved_path%/scripts/aimi-cli.sh}"
    local dsv_km_file="$config_dir/plugins/known_marketplaces.json"
    local dsv_mp_version=""
    if [ -f "$dsv_km_file" ]; then
      local dsv_install_loc dsv_mp_file dsv_src dsv_candidate_dir
      while IFS= read -r dsv_install_loc; do
        [ -z "$dsv_install_loc" ] && continue
        case "$dsv_install_loc" in
          /*) ;;
          *) continue ;;
        esac
        dsv_install_loc="${dsv_install_loc%/}"
        dsv_mp_file="$dsv_install_loc/.claude-plugin/marketplace.json"
        [ -f "$dsv_mp_file" ] || continue
        dsv_src=$(jq -r '(.plugins // []) | map(select(.name == "aimi-engineering" and (.source | type) == "string")) | .[0].source // empty' "$dsv_mp_file" 2>/dev/null) || dsv_src=""
        [ -z "$dsv_src" ] && continue
        case "$dsv_src" in
          /*) continue ;;
        esac
        case "$dsv_src" in
          *..*) continue ;;
        esac
        dsv_candidate_dir="${dsv_install_loc}/${dsv_src#./}"
        if [ "$dsv_candidate_dir" = "$dsv_plugin_dir" ]; then
          dsv_mp_version=$(jq -r '(.plugins // []) | map(select(.name == "aimi-engineering" and (.version | type) == "string")) | .[0].version // empty' "$dsv_mp_file" 2>/dev/null) || dsv_mp_version=""
          break
        fi
      done < <(jq -r 'if type != "object" then empty else to_entries[] | select(.value.source.source == "directory" and (.value.installLocation | type) == "string") | .value.installLocation end' "$dsv_km_file" 2>/dev/null)
    fi
    if [ -n "$dsv_mp_version" ]; then
      resolved_version="$dsv_mp_version"
    else
      local dsv_pj_file="$dsv_plugin_dir/.claude-plugin/plugin.json"
      if [ -f "$dsv_pj_file" ]; then
        resolved_version=$(jq -r 'if (.version | type) == "string" then .version else empty end' "$dsv_pj_file" 2>/dev/null) || resolved_version=""
      fi
    fi
  else
    resolved_version=$(_extract_version_from_path "$resolved_path")
  fi

  # message note for the directory-source origin -- the ONLY place that origin
  # is communicated (no fifth status, no new top-level key).
  local origin_note=""
  [ "$resolved_source" = "directory" ] && origin_note=" (directory-source install)"

  # ---- Already-current check ----
  #
  # KNOWN GAP, declared rather than fixed: read_global_cli_cache runs every
  # candidate through _validate_cached_cli_path's whitelist, which recognizes
  # only the AIMI_PLUGIN_DIR shape and the versioned-cache-glob shape -- never
  # a directory-source path. So existing_cache is always empty for one, this
  # branch never fires for resolved_source == "directory", and a second
  # consecutive run re-answers "ok" rather than "already_current". Both are
  # documented outcomes of this verb's contract; widening that whitelist
  # reaches outside cmd_prime_cache, which is this story's declared scope.
  local existing_cache
  existing_cache=$(read_global_cli_cache)
  if [ -n "$existing_cache" ] && [ "$existing_cache" = "$resolved_path" ]; then
    # already_current is about the CLI pointer alone. The worktree pointer can
    # be absent or stale while this one is right -- that asymmetry is exactly
    # what this story is about -- so prime it here too, before the early
    # return, rather than only on the path that writes.
    _persist_worktree_pointer_for "$resolved_path"
    jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$resolved_version" --arg note "$origin_note" \
      '{status:"already_current",path:$path,host:$host,version:(if $ver == "" then null else $ver end),message:("Cache already points to this path" + $note)}'
    return 0
  fi

  # ---- Write cache ----
  local write_error
  if ! write_error=$(write_global_cli_cache "$resolved_path" 2>&1); then
    jq -n --arg host "$host_label" --arg msg "write_global_cli_cache failed: $write_error" \
      '{status:"error",path:null,host:$host,version:null,message:$msg}'
    return 1
  fi

  # write_global_cli_cache (~line 730) silently no-ops -- returns 0, writes
  # nothing -- when resolved_path, or its symlink-resolved target, carries a
  # `/.worktrees/` segment. That refusal is indistinguishable from a
  # successful write at the call above: both return 0 with empty stdout. A
  # directory-source resolution can legitimately land here (a maintainer
  # running this CLI straight out of a worktree checkout of THIS repo), so
  # read the cache file back and compare its RAW content against resolved_path
  # before answering ok. This reads _global_cache_path's file directly rather
  # than through read_global_cli_cache/_validate_cached_cli_path, whose
  # whitelist (see the Already-current comment above) would reject a
  # directory-source path outright and turn every successful directory-source
  # write into a false "error" here too.
  local cache_file_after persisted_path=""
  cache_file_after=$(_global_cache_path)
  if [ -f "$cache_file_after" ] && [ -r "$cache_file_after" ]; then
    persisted_path=$(cat "$cache_file_after" 2>/dev/null) || persisted_path=""
  fi
  if [ "$persisted_path" != "$resolved_path" ]; then
    jq -n --arg host "$host_label" --arg path "$resolved_path" \
      --arg msg "write_global_cli_cache did not persist $resolved_path (likely refused a /.worktrees/ segment); global cache not updated" \
      '{status:"error",path:null,host:$host,version:null,message:$msg}'
    return 1
  fi

  # The cli-path is persisted and verified; give the worktree pointer the same
  # install in the same call. Placed after the read-back above so a resolution
  # that write_global_cli_cache declined has already answered error and
  # returned -- the two pointers are never left naming different installs, not
  # even for the length of one failed run.
  _persist_worktree_pointer_for "$resolved_path"

  jq -n --arg path "$resolved_path" --arg host "$host_label" --arg ver "$resolved_version" --arg note "$origin_note" \
    '{status:"ok",path:$path,host:$host,version:(if $ver == "" then null else $ver end),message:("Cache primed successfully" + $note)}'
  return 0
}

# Pass a gate on a story
# Usage: gate-pass US-NNN [--option 'value'] [--tasks-file <path>]
#
# --tasks-file is DELIBERATELY RE-CLASSIFIED here, not a pre-existing branch:
# before this flag was recognized, it fell into the `*)` catch-all below and
# was refused only as a side effect of being unknown. This adds an explicit
# case so gate-pass HONORS it, matching every other mark-*/gate-* write verb.
cmd_gate_pass() {
  local story_id="$1"
  shift || true
  local option="" tasks_file_override=""

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-pass <story-id> [--option 'value'] [--tasks-file <path>]" >&2
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --option)
        option="${2:-}"
        if [ -z "$option" ]; then
          echo '{"valid":false,"errors":["--option requires a value"]}'
          exit 1
        fi
        shift 2
        ;;
      --tasks-file)
        tasks_file_override="${2:-}"
        shift
        shift || true
        ;;
      *)
        echo "{\"valid\":false,\"errors\":[\"Unknown flag: $1\"]}"
        exit 1
        ;;
    esac
  done

  validate_story_id "$story_id"

  local tasks_file
  if [ -n "$tasks_file_override" ]; then
    # An explicit path is a CLI ARGUMENT, so validate_path_in_project is the
    # sole authority over it -- same rule verification-report applies.
    tasks_file=$(resolve_path "$tasks_file_override")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  # BEHAVIOUR CHANGE. The gate-present precondition was read in an unlocked jq
  # and the {id, gate} echo-back re-read the file after the lock had been
  # released -- three crossings with the lock around only the middle one. If
  # the gate was removed in between, nothing re-asked: the write is a merge
  # into `.gate`, and in jq `null + {status: "passed"}` is `{status:
  # "passed"}`, so the verb did not refuse, it CREATED a gate on a story that
  # no longer had one.
  #
  # One crossing, inside the lock: precondition, write and echo-back all decide
  # against the same document. The refusal object and the exit status are
  # unchanged -- it is only WHEN the question is asked that moved.
  check_python3
  local option_args=()
  [ -n "$option" ] && option_args=(--option "$option")

  local out rc=0
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" gate-pass \
        --tasks-file "$tasks_file" --story-id "$story_id" "${option_args[@]}"
    ) 200>"${tasks_file}.lock"
  ) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || exit "$rc"
}

# Fail a gate on a story
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_gate_fail() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"

  if [ -z "$story_id" ]; then
    echo "Usage: aimi-cli.sh gate-fail <story-id> [--tasks-file <path>]" >&2
    exit 1
  fi

  validate_story_id "$story_id"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  # Same three crossings, same behaviour change, same single call. See
  # cmd_gate_pass above -- the guard these two carried was byte-identical, and
  # it is one implementation now rather than two copies that could drift.
  check_python3
  local out rc=0
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" gate-fail \
        --tasks-file "$tasks_file" --story-id "$story_id"
    ) 200>"${tasks_file}.lock"
  ) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || exit "$rc"
}

# Update a nested field on a story
# Usage: update-field US-NNN field.path value [--tasks-file <path>]
# field.path is a dotted chain of identifier segments, e.g. "verification.status"
cmd_update_field() {
  local tasks_file positional=()
  _parse_positional_tasks_file tasks_file positional "$@"
  local story_id="${positional[0]:-}"
  local field_path="${positional[1]:-}"
  local value="${positional[2]:-}"

  if [ -z "$story_id" ] || [ -z "$field_path" ] || [ -z "$value" ]; then
    echo "Usage: aimi-cli.sh update-field <story-id> <field.path> <value> [--tasks-file <path>]" >&2
    echo "  <field.path> is a dotted chain of identifier segments, e.g. verification.status" >&2
    exit 1
  fi

  validate_story_id "$story_id"
  # The gate that used to stand between the caller's argument and a jq program
  # built out of it. There is no such program any more -- tasks.py splits the
  # path and indexes a dict with the segments -- so this is now the SOLE gate
  # on the field path, and it stays exactly where it was, ahead of every reader
  # of that argument.
  validate_field_path "$field_path"

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi
  validate_story_exists "$story_id" "$tasks_file"

  # One crossing, inside the lock. The assignment and the {id, <top-segment>}
  # echo-back were two jq programs over the same file, the second re-reading
  # what the first had just written; they are one call now, and the payload
  # comes back from it. --value goes last -- see the note in cmd_mark_failed.
  #
  # No `|| exit $?`, and the two normalizers keep theirs, because that is the
  # shape each verb already had. It is not a difference in behaviour: `set -euo
  # pipefail` ends the script on the failing assignment either way, at the same
  # status and before the payload is printed. update-field-lock-inutilizavel
  # and update-field-intermediario-nao-objeto record both halves of that.
  check_python3
  local out
  out=$(
    (
      _lock "${tasks_file}.lock"
      python3 "$(_aimi_tasks_py)" update-field \
        --tasks-file "$tasks_file" --story-id "$story_id" \
        --field-path "$field_path" --value "$value"
    ) 200>"${tasks_file}.lock"
  )
  printf '%s\n' "$out"
}

# Validate waves: compute waves from dependsOn, compare to stored wave, report mismatches
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_validate_waves() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh validate-waves [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  # NO exit-status handling, and that is not an omission to tidy up. This body
  # ended at its jq call before the port and ends at the crossing now, so an
  # invalid verdict still exits 0 -- the verdict is in `.valid`, never in `$?`.
  # test-aimi-cli-part1-core.sh asserts the 0 against a wave-mismatch fixture.
  check_python3
  python3 "$(_aimi_tasks_py)" validate-waves --tasks-file "$tasks_file"
}

# Validate tasks file citation fields
# For schemaVersion >= 3.3: validates DesignSpec verbatim citations for visual
# stories and BusinessSpec field citations for a frontend-only file's endpoints,
# plus the metadata.execution enum, the execution/phase exclusivity, the
# branchName charset and every story's verification.url charset.
# For schemaVersion < 3.3: emits skip-info to stderr and exits 0
# stdout: {valid, errors[]} JSON; exits non-zero when invalid
#
# ONE crossing, and NO lock: this is a pure reader, same as the four validators
# beside it. What used to stand here read eight scalar metadata fields out of
# one packed jq line, and carried three pieces of scaffolding to make that
# packing safe -- a non-whitespace delimiter, an alternative operator that had
# to emit a field rather than none, and a sentinel variable with no field to
# receive it. All three are gone: tasks.py parses the document once and asks
# eight ordinary questions of a dict. The section comment above
# validate_tasks_metadata there says what each piece was defending and why a
# single parse leaves nothing for any of them to do.
#
# PROJECT_ROOT is passed as a flag because it is bash's: find_aimi_root exports
# it and get_tasks_file has already been gated against it. The two spec paths
# cannot be confined out here -- they are read out of metadata.designBundle,
# which is only visible after the crossing.
# Flags: --tasks-file <path> (optional; falls back to get_tasks_file)
cmd_validate_tasks() {
  local tasks_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tasks-file)
        shift
        tasks_file="${1:-}"
        ;;
      *)
        echo "Error: Unknown flag: $1" >&2
        echo "Usage: aimi-cli.sh validate-tasks [--tasks-file <path>]" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -n "$tasks_file" ]; then
    tasks_file=$(resolve_path "$tasks_file")
    validate_path_in_project "$tasks_file"
  else
    tasks_file=$(get_tasks_file)
  fi

  check_python3
  python3 "$(_aimi_tasks_py)" validate-tasks \
    --tasks-file "$tasks_file" --project-root "$PROJECT_ROOT"
}

# Check whether a tasks file's stories are ALL terminal (completed or skipped)
# and non-empty. Echoes nothing; return code only (0 = archivable-as-a-file).
#
# ONE crossing where there were two jq programs over the same file, and the
# contract is unchanged: it says nothing, it returns 1 for a missing, malformed,
# non-list or empty document, and it NEVER takes the command down. Both of those
# properties still come from the same two places -- `2>/dev/null` swallows the
# diagnostic, and every caller invokes this in a condition context where `set -e`
# is suspended -- so a document tasks.py refuses is simply not archivable.
#
# ITS NON-EMPTY CLAUSE IS DELIBERATELY NOT op_archive_task's. The two rules
# disagree about `userStories: []` -- refused here, archived there -- and the
# disagreement predates any port; both sides are pinned in golden_from_jq.json
# (la-zero-historias and archive-userstories-vazio). op_archivable_file_is_terminal
# says at length why they share no helper.
_archivable_file_is_terminal() {
  local tasks_file="$1"
  local verdict
  verdict=$( { check_python3 && python3 "$(_aimi_tasks_py)" \
    archivable-file-is-terminal --tasks-file "$tasks_file"; } 2>/dev/null ) || return 1
  [ "$verdict" = "true" ] || return 1
  return 0
}

# List task files where all stories have terminal status (completed or skipped).
# Discovers both the flat layout (.aimi/tasks/*-tasks.json) and the nested
# phase-folder layout (.aimi/tasks/<feature>/phase-N-slug/<feature>-phase-N-
# tasks.json) via the shared discovery helper. A feature folder's nested
# phase tasks files surface together as a single unit -- only when every
# phase tasks file discovered under that feature is all-terminal AND the
# feature's roadmap.json (read through roadmap.py's own list-archivable-phases
# op, which owns roadmap.json's document logic; NOT through a roadmap-lifecycle
# subcommand, whose wrapper wants a feature slug where this walks paths) marks
# every phase completed -- rather than piecemeal as each phase happens to
# finish. "completed" is the only terminal phase status (see the roadmap
# status enum in cmd_roadmap_set_status); there is no "deferred" status. A
# phase stuck in verification_failed therefore excludes its feature from the
# result same as any other non-completed status, but is never a *silent*
# dead end: it's called out on stderr each time, naming the feature and the
# blocked phase ids, so the block stays discoverable instead of an
# unexplained permanent absence from the list. A feature folder with no
# roadmap.json (or a malformed one) falls back to the flat per-file terminal
# check, so stray nested files created without roadmap-init are still
# individually archivable.
# Returns a JSON array of file paths (stdout shape unchanged by the above).
cmd_list_archivable() {
  local all_files
  all_files=$(_find_tasks_files_all)

  local result="["
  local first=true

  _archivable_append() {
    local resolved
    resolved=$(resolve_path "$1")
    if [ "$first" = true ]; then
      first=false
    else
      result="$result,"
    fi
    result="$result$(printf '"%s"' "$resolved")"
  }

  # Split discovered files into flat (direct child of TASKS_DIR) vs nested
  # (feature/phase-slug/file, two directories below TASKS_DIR).
  local flat_files=() nested_files=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$(dirname "$f")" = "$TASKS_DIR" ]; then
      flat_files+=("$f")
    else
      nested_files+=("$f")
    fi
  done <<< "$all_files"

  for f in "${flat_files[@]+"${flat_files[@]}"}"; do
    [ -f "$f" ] || continue
    _archivable_file_is_terminal "$f" && _archivable_append "$f"
  done

  # Group nested files by feature folder (two directories above each file)
  # and evaluate the whole feature as a unit.
  local -A feature_seen
  for f in "${nested_files[@]+"${nested_files[@]}"}"; do
    local feature_dir
    feature_dir=$(dirname "$(dirname "$f")")
    [ -n "${feature_seen[$feature_dir]:-}" ] && continue
    feature_seen[$feature_dir]=1

    local feature_files=()
    local ff
    for ff in "${nested_files[@]+"${nested_files[@]}"}"; do
      if [ "$(dirname "$(dirname "$ff")")" = "$feature_dir" ]; then
        feature_files+=("$ff")
      fi
    done

    local all_terminal=true
    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      if [ ! -f "$ff" ] || ! _archivable_file_is_terminal "$ff"; then
        all_terminal=false
        break
      fi
    done
    [ "$all_terminal" = true ] || continue

    # ---- the seam with the tasks.json half. Above this line every file has
    # been through _archivable_file_is_terminal, which is tasks.py's; below it
    # the FEATURE is judged by what its roadmap.json says, which is roadmap.py's.
    # Neither reads the other's document and the two rules stay separate.
    #
    # ONE crossing per roadmap, where there were three jq programs over the same
    # file -- the `jq -e .` validity probe, the non-completed count and the
    # verification_failed collect-and-join. Which statuses are terminal and
    # which are stuck is roadmap.py's to say now; what survives here is bash's
    # own control flow over the answer, unchanged line for line, plus the
    # sentence, which stays here because it names $feature_dir.
    #
    # THE FOUR-FIELD SPLIT IS PARAMETER EXPANSION AND NOT jq, the way
    # cmd_init_session splits its own first line off. op_list_archivable_phases
    # documents the stream: usable, the count, the stuck ids raw (which may be
    # empty, and may be several lines, because a phase id is whatever someone
    # typed), and the whole verdict compact on the LAST line -- one line
    # guaranteed, so a hostile id cannot shift the fields above it.
    #
    # `usable` carries what `jq -e .` used to decide: a malformed roadmap.json,
    # or one whose value is null or false, is not readable and the feature is
    # INCLUDED anyway by the fall-through below. An EMPTY file is the third
    # state and still the only input that reaches the `-z` arm: jq exited 0
    # over zero documents and printed no count, so the feature is EXCLUDED with
    # nothing said. And a `.phases` that cannot be iterated still ends the whole
    # command -- the assignment is a bare command under `set -euo pipefail`,
    # exactly as the jq it replaced was -- except that roadmap.py now says which
    # file and which shape instead of dying silently at jq's own status.
    #
    # No check_python3 here on purpose: an interpreter-less host never reaches
    # this line, because _archivable_file_is_terminal has already answered "not
    # terminal" for every file in the feature and the loop continued above. The
    # verb's documented degrade -- an empty list rather than a broken command --
    # is the predicate's, and this crossing does not take it away.
    local roadmap_path="$feature_dir/roadmap.json"
    if [ -f "$roadmap_path" ]; then
      local verdict rest usable non_terminal_phases stuck_ids
      verdict=$(python3 "$(_aimi_roadmap_py)" list-archivable-phases --roadmap "$roadmap_path")
      usable=${verdict%%$'\n'*};           rest=${verdict#*$'\n'}
      non_terminal_phases=${rest%%$'\n'*}; rest=${rest#*$'\n'}
      stuck_ids=${rest%$'\n'*}
      if [ "$usable" = true ]; then
        [ -z "$non_terminal_phases" ] && continue
        if [ "$non_terminal_phases" -ne 0 ]; then
          # A stuck (verification_failed) phase is excluded the same as any
          # other non-completed status, but never silently -- name it and the
          # feature on stderr every run so the block stays visible instead of
          # becoming an unexplained permanent absence from the result.
          if [ -n "$stuck_ids" ]; then
            echo "Warning: list-archivable: $feature_dir not archivable -- phase(s) $stuck_ids stuck in verification_failed (re-verify via roadmap-set-status, or resolve manually)" >&2
          fi
          continue
        fi
      fi
    fi
    # No roadmap.json (or malformed): every discovered phase file already
    # passed the per-file terminal check above, so fall back to including them.

    for ff in "${feature_files[@]+"${feature_files[@]}"}"; do
      _archivable_append "$ff"
    done
  done

  result="$result]"
  echo "$result"
}

# Archive a task file (and linked brainstorm) to .aimi/archive/
# Usage: archive-task <path>
#
# THE ONLY VERB IN THIS FILE THAT DELETES A USER'S FILES, and the split of
# responsibility reflects it. Bash keeps the <path> ARGUMENT: it exists before
# the document is read, so validate_path_in_project stays the sole authority
# over it and refuses an escaping argument without python3 ever starting.
# tasks.py owns the paths that come OUT of the document -- brainstormPath,
# researchPaths[], prototypePaths[] -- because those exist only after the
# crossing, and routing them back here would mean reading the file twice.
# require_in_project over there is an exact port of validate_path_in_project,
# refusal message and exit status included.
cmd_archive_task() {
  local task_path="$1"

  if [ -z "$task_path" ]; then
    echo "Usage: aimi-cli.sh archive-task <path>" >&2
    exit 1
  fi

  # Resolve and validate path
  if [ ! -f "$task_path" ]; then
    echo "Error: Task file not found: $task_path" >&2
    exit 1
  fi

  local resolved_task
  resolved_task=$(resolve_path "$task_path")
  validate_path_in_project "$resolved_task"

  check_python3
  python3 "$(_aimi_tasks_py)" archive-task \
    --tasks-file "$resolved_task" \
    --project-root "$PROJECT_ROOT" \
    --archive-dir "$AIMI_DIR/archive"
}

# Usage: research-lookup [--ignore-missing-cited-paths] <path>
# Check whether a research file is fresh relative to its cited source paths.
# Freshness: research-file mtime >= newest mtime among existing cited source paths.
# A cited path that does not exist -> stale (logs a warning to stderr).
#   With --ignore-missing-cited-paths: missing cited paths log a warning but do NOT mark stale.
# No '## File References' section -> stale.
# Fresh: prints the research path + exits 0.
# Stale/undecidable: prints nothing + exits 1.
# Missing argument: usage on stderr + exits 1.
cmd_research_lookup() {
  local ignore_missing=0
  local research_path=""

  # Parse flag in either position relative to the positional path arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignore-missing-cited-paths)
        ignore_missing=1
        shift
        ;;
      -*)
        echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
        exit 1
        ;;
      *)
        research_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$research_path" ]; then
    echo "Usage: aimi-cli.sh research-lookup [--ignore-missing-cited-paths] <path>" >&2
    exit 1
  fi

  if [ ! -f "$research_path" ]; then
    echo "Error: Research file not found: $research_path" >&2
    exit 1
  fi

  # Resolve and validate the research file path
  local resolved_research
  resolved_research=$(resolve_path "$research_path")
  validate_path_in_project "$resolved_research"

  # Get the mtime (seconds since epoch) of the research file
  local research_mtime
  research_mtime=$(stat -c '%Y' "$resolved_research" 2>/dev/null || stat -f '%m' "$resolved_research" 2>/dev/null)
  if [ -z "$research_mtime" ]; then
    echo "Error: Cannot stat research file: $resolved_research" >&2
    exit 1
  fi

  # Extract the '## File References' section: lines between the h2 header and the next h2/EOF
  # Parse bullet list entries (lines starting with - or *)
  local file_refs_section
  file_refs_section=$(awk '
    /^## File References/ { in_section=1; next }
    /^## / && in_section { exit }
    in_section { print }
  ' "$resolved_research")

  # If no File References section found -> stale
  if [ -z "$file_refs_section" ]; then
    exit 1
  fi

  # Parse bullet list: lines starting with optional whitespace then - or *
  # Extract the path portion (strip leading bullet marker and whitespace)
  local cited_paths
  cited_paths=$(printf '%s\n' "$file_refs_section" | grep -E '^\s*[-*]\s+' | sed 's/^\s*[-*]\s\+//')

  # If section exists but has no bullet entries -> stale
  if [ -z "$cited_paths" ]; then
    exit 1
  fi

  local newest_source_mtime=0
  local stale=0

  while IFS= read -r cited_path; do
    [ -z "$cited_path" ] && continue

    # Reject absolute paths outright
    if [ "${cited_path#/}" != "$cited_path" ]; then
      echo "Warning: Absolute path rejected in File References: $cited_path" >&2
      stale=1
      continue
    fi

    # Resolve relative to PROJECT_ROOT, canonicalizing any .. traversals
    local abs_cited_path
    if [ "$_HAS_REALPATH" -eq 1 ]; then
      # realpath -m normalizes .. without requiring the path to exist
      abs_cited_path=$(realpath -m "$PROJECT_ROOT/$cited_path" 2>/dev/null) || abs_cited_path="$PROJECT_ROOT/$cited_path"
    else
      abs_cited_path="$PROJECT_ROOT/$cited_path"
    fi

    # Validate stays within project (exit on escape attempt)
    validate_path_in_project "$abs_cited_path"

    # Check existence
    if [ ! -e "$abs_cited_path" ]; then
      echo "Warning: Cited source path does not exist (stale): $cited_path" >&2
      if [ "$ignore_missing" -eq 0 ]; then
        stale=1
      fi
      continue
    fi

    # Get mtime of the source file
    local src_mtime
    src_mtime=$(stat -c '%Y' "$abs_cited_path" 2>/dev/null || stat -f '%m' "$abs_cited_path" 2>/dev/null)
    if [ -z "$src_mtime" ]; then
      echo "Warning: Cannot stat cited path (stale): $abs_cited_path" >&2
      stale=1
      continue
    fi

    if [ "$src_mtime" -gt "$newest_source_mtime" ]; then
      newest_source_mtime=$src_mtime
    fi
  done <<< "$cited_paths"

  # If any cited path was missing or unreadable -> stale
  if [ "$stale" -ne 0 ]; then
    exit 1
  fi

  # Freshness check: research mtime must be >= newest source mtime
  if [ "$research_mtime" -ge "$newest_source_mtime" ]; then
    printf '%s\n' "$resolved_research"
    exit 0
  else
    exit 1
  fi
}

# Usage: extract-sections <file> --anchors "<heading titles, newline-separated>"
# Print only the requested '## '/'### ' sections of a research .md file, concatenated
# verbatim in the order the anchors were requested.
# Each section spans from its matching heading line up to (but not including) the next
# heading of the same-or-higher level, or EOF -- so an h2 anchor includes its nested h3s
# and stops at the next h2 (or h1); an h3 anchor stops at the next h3/h2 (or h1).
# Anchor text is matched case-insensitively against the heading text (leading #s and
# surrounding whitespace stripped). An anchor with no matching heading is skipped (not
# a fatal error) but is named in a "no section matched anchor" warning on stderr; a run
# whose anchors match nothing prints empty output, still exit 0.
# Anchors containing shell metacharacters ($ ` " \) are rejected with a warning on
# stderr and skipped -- defense in depth, since anchor text originates from untrusted
# research-file heading content.
# Path confinement mirrors research-lookup: resolve_path + validate_path_in_project.
# Missing file -> error + exit 1. Missing <file>/--anchors arg -> usage + exit 1.
cmd_extract_sections() {
  local file_path=""
  local anchors_raw=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --anchors)
        if [ $# -lt 2 ]; then
          echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
          exit 1
        fi
        anchors_raw="$2"
        shift 2
        ;;
      -*)
        echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
        exit 1
        ;;
      *)
        file_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$file_path" ] || [ -z "$anchors_raw" ]; then
    echo "Usage: aimi-cli.sh extract-sections <file> --anchors \"<heading titles>\"" >&2
    exit 1
  fi

  if [ ! -f "$file_path" ]; then
    echo "Error: File not found: $file_path" >&2
    exit 1
  fi

  # Resolve and validate the target file path
  local resolved_file
  resolved_file=$(resolve_path "$file_path")
  validate_path_in_project "$resolved_file"

  # Split --anchors on newlines only (comma is valid heading-text punctuation and must
  # NOT be treated as a delimiter); trim and lowercase each entry; skip blanks.
  # Extract each anchor's section (first matching heading only) in request order.
  local anchor anchor_lc unmatched_anchors=""
  while IFS= read -r anchor; do
    anchor=$(printf '%s' "$anchor" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "$anchor" ] && continue

    # Defense in depth: anchors originate from untrusted research-file heading text.
    # The orchestrator sanitizes before interpolating, but this CLI must not rely on
    # that. Reject only characters dangerous inside a double-quoted shell argument --
    # &, comma, parens, colon, slash, hyphen, underscore, period, and single-quote are
    # all legitimate heading punctuation and MUST keep working.
    case "$anchor" in
      *'$'*|*'`'*|*'"'*|*'\'*)
        echo "Warning: anchor rejected (shell metacharacter): $anchor" >&2
        continue ;;
    esac

    anchor_lc=$(printf '%s' "$anchor" | tr '[:upper:]' '[:lower:]')

    # awk streams matched section lines straight to stdout (byte-for-byte, blank
    # lines and all) and reports match status via its own exit code -- this avoids
    # a $(...) capture, which would silently swallow trailing blank lines.
    if awk -v target="$anchor_lc" '
      BEGIN { in_section = 0; match_level = 0; matched_done = 0; in_fence = 0 }
      {
        if ($0 ~ /^[[:space:]]*(```|~~~)/) { in_fence = !in_fence }
        level = 0
        if (!in_fence && $0 ~ /^#+[[:space:]]/) {
          line_copy = $0
          while (substr(line_copy, 1, 1) == "#") {
            level++
            line_copy = substr(line_copy, 2)
          }
        }

        # Close the active section at the next heading of same-or-higher level
        # (a lower heading level number outranks a higher one, e.g. h2 outranks h3).
        if (in_section && level > 0 && level <= match_level) {
          in_section = 0
        }

        # Only ## / ### headings are matchable anchors; first match wins.
        if (!in_section && !matched_done && (level == 2 || level == 3)) {
          heading_text = substr($0, level + 1)
          gsub(/^[[:space:]]+/, "", heading_text)
          gsub(/[[:space:]]+$/, "", heading_text)
          if (tolower(heading_text) == target) {
            in_section = 1
            matched_done = 1
            match_level = level
          }
        }

        if (in_section) {
          print
        }
      }
      END { exit (matched_done ? 0 : 1) }
    ' "$resolved_file"; then
      :
    else
      unmatched_anchors="$unmatched_anchors
$anchor"
    fi
  done < <(printf '%s\n' "$anchors_raw")

  if [ -n "$unmatched_anchors" ]; then
    while IFS= read -r anchor; do
      [ -z "$anchor" ] && continue
      echo "Warning: no section matched anchor: $anchor" >&2
    done <<< "$unmatched_anchors"
  fi

  return 0
}

# Usage: research-gc
# Garbage-collect orphaned research files from .aimi/research/*.md.
# A file is deleted only when BOTH conditions are true:
#   1. It is NOT referenced by any active .aimi/tasks/*.json metadata.researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter researchPaths,
#      AND is NOT referenced by any .aimi/brainstorms/*.md frontmatter foundationProposalPath.
#   2. Its mtime is older than 30 days.
# .aimi/archive is ignored entirely.
# Prints "Cleaned <N> orphaned research files (>30 days)" when N>0; silent when N=0.
cmd_research_gc() {
  local research_dir="$AIMI_DIR/research"

  # Nothing to do if research dir doesn't exist
  if [ ! -d "$research_dir" ]; then
    return 0
  fi

  # Build the referenced-set: union of researchPaths across all active tasks/*.json
  # plus researchPaths from all brainstorms/*.md frontmatter.
  local referenced_set=""

  # --- Source 1: .aimi/tasks/*.json metadata.researchPaths ---
  #
  # ONE crossing for the whole directory, where there was one jq startup per
  # file. The GLOB STAYS HERE and its expansion is handed over as arguments,
  # because which file is read first decides what survives an abort and the
  # shell's collation is the order that was recorded. check_python3 is called
  # OUTSIDE the process substitution on purpose: an interpreter that failed to
  # start inside it would end the subshell, leave the referenced-set empty, and
  # the sweep below would then collect every live research file as an orphan.
  local tasks_dir="$AIMI_DIR/tasks"
  if [ -d "$tasks_dir" ]; then
    check_python3
    while IFS= read -r rpath; do
      [ -z "$rpath" ] && continue
      # Normalize: strip leading ./ and collapse to a canonical relative path
      rpath="${rpath#./}"
      referenced_set="$referenced_set
$rpath"
    done < <(python3 "$(_aimi_tasks_py)" research-paths "$tasks_dir"/*.json 2>/dev/null)
  fi

  # --- Source 2: .aimi/brainstorms/*.md frontmatter researchPaths ---
  # --- Source 3: .aimi/brainstorms/*.md frontmatter foundationProposalPath (scalar) ---
  local brainstorms_dir="$AIMI_DIR/brainstorms"
  if [ -d "$brainstorms_dir" ]; then
    for bfile in "$brainstorms_dir"/*.md; do
      [ -f "$bfile" ] || continue
      # Extract YAML frontmatter (lines between opening and closing ---)
      # Parse researchPaths: list entries (lines starting with - under that key)
      # and foundationProposalPath: as a single scalar value, independent of order.
      local in_front=0 past_open=0 in_rp=0
      while IFS= read -r line; do
        if [ "$past_open" -eq 0 ] && [ "$line" = "---" ]; then
          past_open=1
          in_front=1
          continue
        fi
        if [ "$in_front" -eq 1 ] && [ "$line" = "---" ]; then
          break
        fi
        if [ "$in_front" -eq 0 ]; then
          # First non-frontmatter line without opening --- means no frontmatter
          break
        fi
        # Inside frontmatter
        if printf '%s\n' "$line" | grep -qE '^researchPaths\s*:'; then
          in_rp=1
          continue
        fi
        if printf '%s\n' "$line" | grep -qE '^foundationProposalPath[[:space:]]*:'; then
          # New top-level key: exit any in-progress researchPaths list scan first,
          # regardless of whether foundationProposalPath appears before or after it.
          in_rp=0
          local fp_entry
          # POSIX [[:space:]] (not \s — GNU-only in sed); then normalize the
          # extracted scalar so a YAML-quoted value or a trailing comment cannot
          # defeat the referenced-set match (which would delete a live artifact):
          #   1. strip a trailing " #comment" (space-hash onward)
          #   2. strip one pair of surrounding double or single quotes
          #   3. strip a leading ./
          fp_entry=$(printf '%s\n' "$line" | sed 's/^foundationProposalPath[[:space:]]*:[[:space:]]*//')
          fp_entry=$(printf '%s\n' "$fp_entry" | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//')
          case "$fp_entry" in
            \"*\") fp_entry="${fp_entry#\"}"; fp_entry="${fp_entry%\"}" ;;
            \'*\') fp_entry="${fp_entry#\'}"; fp_entry="${fp_entry%\'}" ;;
          esac
          fp_entry="${fp_entry#./}"
          referenced_set="$referenced_set
$fp_entry"
          continue
        fi
        if [ "$in_rp" -eq 1 ]; then
          # List item: lines starting with optional spaces then - followed by space
          if printf '%s\n' "$line" | grep -qE '^\s*-\s+'; then
            local rp_entry
            rp_entry=$(printf '%s\n' "$line" | sed 's/^\s*-\s\+//')
            rp_entry="${rp_entry#./}"
            referenced_set="$referenced_set
$rp_entry"
          elif printf '%s\n' "$line" | grep -qE '^\s*[a-zA-Z]'; then
            # A new key — exit researchPaths block
            in_rp=0
          fi
        fi
      done < "$bfile"
    done
  fi

  # Compute threshold: now - 30 days in seconds
  local now threshold
  now=$(date +%s)
  threshold=$((now - 30 * 86400))

  local cleaned=0

  # Iterate .aimi/research/*.md
  for rfile in "$research_dir"/*.md; do
    [ -f "$rfile" ] || continue

    # Compute relative path from PROJECT_ROOT (for set membership check)
    local rel_path
    if [ "${rfile#/}" = "$rfile" ]; then
      # Relative path already — but canonicalize via PROJECT_ROOT
      rel_path="$AIMI_DIR/research/$(basename "$rfile")"
    else
      # Absolute — make relative to PROJECT_ROOT
      rel_path="${rfile#"$PROJECT_ROOT/"}"
    fi
    rel_path="${rel_path#./}"

    # Check if this file is in the referenced-set
    local is_referenced=0
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      ref_norm="${ref#./}"
      if [ "$ref_norm" = "$rel_path" ]; then
        is_referenced=1
        break
      fi
    done <<< "$referenced_set"

    if [ "$is_referenced" -eq 1 ]; then
      continue
    fi

    # Check mtime: only delete if older than threshold
    local file_mtime
    file_mtime=$(stat -c '%Y' "$rfile" 2>/dev/null || stat -f '%m' "$rfile" 2>/dev/null)
    if [ -z "$file_mtime" ]; then
      continue
    fi

    if [ "$file_mtime" -lt "$threshold" ]; then
      rm -f "$rfile"
      cleaned=$((cleaned + 1))
    fi
  done

  if [ "$cleaned" -gt 0 ]; then
    echo "Cleaned $cleaned orphaned research files (>30 days)"
  fi
}

# ============================================================================
# story-merge: Consolidate staging files into a validated tasks.json
# Usage: aimi-cli.sh story-merge --staging-dir <dir> --output <path>
#           [--split legacy|full-stack] [--agent-mode] [--phase-aware]
#           [--foundation <NN>|<project>:NN]...
# ============================================================================
#
# Everything from "read the staging directory" to "the files are on disk" lives
# in story_merge.py, which owns the merge, both split axes and the writes. What
# stays here is the shell-shaped half: flag parsing, path confinement, and the
# --phase-aware basename precondition, which is pure string manipulation on
# --output and has to run before the writers so both of their `${base%-tasks}`
# strips stay byte-identical.
#
# The locking moved with the writers rather than staying here the way the
# roadmap verbs' does. It had to: on the PROJECT axis the output paths are
# derived from the stories themselves, and bash cannot hold a lock on a name it
# has not computed yet.
cmd_story_merge() {
  local staging_dir="" output_path="" split_mode="legacy" agent_mode=false phase_aware=false
  # --foundation is the one REPEATABLE flag here: injection is per project
  # group, so a multi-repo plan names one foundation per repo. Collected, never
  # deduplicated in bash -- story_merge.py's own dedup is the single source of
  # truth for what an exact repeat means.
  local foundation_vals=()

  # --- Parse flags ---
  while [ $# -gt 0 ]; do
    case "$1" in
      --staging-dir)
        shift
        staging_dir="${1:-}"
        ;;
      --output)
        shift
        output_path="${1:-}"
        ;;
      --split)
        shift
        split_mode="${1:-legacy}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      --phase-aware)
        phase_aware=true
        ;;
      --foundation)
        shift
        foundation_vals+=("${1:-}")
        ;;
      *)
        echo "Error: story-merge: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  # --- Validate required flags ---
  if [ -z "$staging_dir" ]; then
    echo "Error: story-merge: --staging-dir <path> is required" >&2
    exit 1
  fi
  if [ -z "$output_path" ]; then
    echo "Error: story-merge: --output <path> is required" >&2
    exit 1
  fi
  if [ "$split_mode" != "legacy" ] && [ "$split_mode" != "full-stack" ]; then
    echo "Error: story-merge: --split must be 'legacy' or 'full-stack', got: $split_mode" >&2
    exit 1
  fi
  # SHAPE only, one value at a time: is this a bare two-digit index, or a
  # <project>:NN qualified one? The qualifier portion loosely mirrors .project's
  # own grammar so an obviously malformed value dies before python3 starts;
  # story_merge.py stays the authority on .project itself, and on both of the
  # checks this deliberately does NOT make -- the bare-only-when-sole-value
  # arity rule and the qualifier-vs-actual-project checksum are cross-value or
  # staging-file-dependent, and belong to its own Gates 0 and 2.
  #
  # Two wordings, one refusal, and the split is not cosmetic: golden_from_jq's
  # fundacao-formato-invalido and fundacao-formato-nao-numerico are the frozen
  # recording of the bare-form line, so a value carrying no ':' keeps it byte
  # for byte. A value that reached for the qualified form is told about both.
  local _fv
  for _fv in "${foundation_vals[@]+"${foundation_vals[@]}"}"; do
    if ! [[ "$_fv" =~ ^([a-zA-Z0-9][a-zA-Z0-9/_.@-]*:)?[0-9]{2}$ ]]; then
      case "$_fv" in
        *:*)
          echo "Error: story-merge: --foundation must be a two-digit index (e.g. 01) or <project>:NN (e.g. apps/web:01), got: $_fv" >&2
          ;;
        *)
          echo "Error: story-merge: --foundation must be a two-digit index (e.g. 01), got: $_fv" >&2
          ;;
      esac
      exit 1
    fi
  done
  # --phase-aware strips ONE trailing "-tasks" segment from the --output
  # basename. Both writers do that strip with the same expansion, and on a
  # basename that is exactly "tasks" the strip is a no-op while on "-tasks" it
  # collapses to the empty string -- either way the derived name degenerates
  # (".../-frontend-tasks.json", ".../-<slug>-tasks.json": a basename starting
  # with "-", which every downstream tool reads as a flag). Guarding inside the
  # writers would mean either fixing one axis and leaving the other, or changing
  # SIDE-axis behavior; refusing the input here leaves both strips
  # byte-identical and costs the caller one well-named error.
  # The derivation below mirrors the writers' exactly (basename, strip the
  # extension after the LAST dot) so the precondition can never drift from the
  # expansion it protects.
  if [ "$phase_aware" = true ]; then
    local pa_base pa_ext pa_no_ext
    pa_base=$(basename "$output_path")
    pa_ext="${pa_base##*.}"
    pa_no_ext="${pa_base%.$pa_ext}"
    case "$pa_no_ext" in
      # ?* before "-tasks": at least one character must survive the strip.
      ?*-tasks) ;;
      *)
        echo "Error: story-merge: --phase-aware requires an --output basename ending in \"-tasks\"" >&2
        echo "(phase-scoped form, e.g. <feature>-phase-<N>-tasks.json); got: $pa_base" >&2
        exit 1
        ;;
    esac
  fi

  # --- Validate paths are inside project ---
  validate_path_in_project "$staging_dir"
  local output_parent
  output_parent=$(dirname "$output_path")
  # output_path may not exist yet; validate parent dir or the path itself
  if [ -e "$output_path" ]; then
    validate_path_in_project "$output_path"
  elif [ -e "$output_parent" ]; then
    validate_path_in_project "$output_parent"
  fi

  # --- Staging dir must exist ---
  if [ ! -d "$staging_dir" ]; then
    echo "Error: story-merge: staging directory does not exist: $staging_dir" >&2
    exit 1
  fi

  check_python3
  # $_ROADMAP_BRANCH_REGEX goes over as an argument rather than being restated
  # in Python: the PROJECT axis validates every branchName it derives against
  # it and quotes it back in the refusal, and one constant with two definitions
  # is how the two drift apart.
  local sm_args=(
    --staging-dir "$staging_dir"
    --output "$output_path"
    --split "$split_mode"
    --branch-regex "$_ROADMAP_BRANCH_REGEX"
  )
  if [ "$agent_mode" = true ]; then
    sm_args+=(--agent-mode)
  fi
  if [ "$phase_aware" = true ]; then
    sm_args+=(--phase-aware)
  fi
  # One --foundation pair per collected value, in the order given. Never joined
  # into one value and never deduplicated here.
  for _fv in "${foundation_vals[@]+"${foundation_vals[@]}"}"; do
    sm_args+=(--foundation "$_fv")
  done
  python3 "$(_aimi_script_py story_merge.py)" "${sm_args[@]}"
}

# ============================================================================
# split-detect — the read side of metadata.splitGroup
# ============================================================================
#
# _story_merge_write_project_split (above) stamps every file it emits with a
# self-describing metadata.splitGroup marker. This is the consumer: given a
# scope, it answers "do the tasks files here form ONE group that must execute
# together, and which members still have work?".
#
# It lives here rather than in /aimi:execute's markdown because every rule it
# encodes -- anchor selection, sibling resolution, total validation, active
# filtering, legacy-pair fallback -- is pure, deterministic, file-only logic.
# Written as executable prose it was unreachable by both Bash test suites, and
# it drifted into two divergent copies (flat flow vs. phase mode). Here one
# copy serves both scopes and every rule is a test case.
#
# It is a QUERY, not a gate: every outcome, including "single" and "none",
# exits 0. Non-zero is reserved for real errors (bad argument, unreadable dir).

# A story is pending when its status is neither "completed" nor "skipped" --
# the terminal pair. NORMATIVE HOME: roadmap.py's TERMINAL_STORY_STATUSES,
# which tasks.py's _dep_status_done and roadmap.py's ground_truth both import.
# This copy cannot: it is a jq program and imports nothing. It is therefore the
# one site that can drift again without the other two noticing, which is
# exactly what happened -- see the paragraph below. Change it only together
# with that constant. Exactly one definition, used for every
# count this verb reports. The prose it replaces had two that disagreed --
# `!= "completed"` for the active filter and `== "pending"` for the phase
# completion count -- so an in_progress story was counted by one and not the
# other, which let a phase close with work still in flight.
#
# "skipped" joined the terminal side later than the other two sites, and its
# absence here was issue #112 surviving in exactly one place: ground_truth had
# been taught that a completed-or-skipped phase is finished, while this copy
# kept answering the old way about the very same tasks file. A split member
# whose remaining stories were all deliberately skipped therefore stayed
# active forever -- drawing a worktree, a branch, a dev server and a spawned
# Task on every run -- and the phase-completion gate never reached zero. Three
# implementations of one sentence is the standing hazard; see the note above
# _dep_status_done before adding a fourth.
_SPLIT_DETECT_DESCRIBE_JQ='
  (if type == "object" then . else {} end) as $doc
| (if ($doc.metadata | type) == "object" then $doc.metadata else {} end) as $m
| (if ($m.splitGroup | type) == "object" then $m.splitGroup else {} end) as $sg
| {
    path: $path,
    project: (if ($sg.project | type) == "string" then $sg.project else "." end),
    branchName: (if ($m.branchName | type) == "string" then $m.branchName else null end),
    storyCount: (if ($doc.userStories | type) == "array"
                 then ($doc.userStories | length) else 0 end),
    pendingCount: (if ($doc.userStories | type) == "array"
                   then ([$doc.userStories[]
                          | select((.status? // "pending")
                                   | . != "completed" and . != "skipped")] | length)
                   else 0 end),
    hasMarker: (($sg.total | type) == "number" and ($sg.siblings | type) == "array"),
    declaredTotal: (if ($sg.total | type) == "number" then ($sg.total | tostring) else "" end),
    siblings: (if ($sg.siblings | type) == "array"
               then [$sg.siblings[] | tostring] else [] end)
  }
| . + {active: (.pendingCount > 0)}
'

# Emit one compact JSON descriptor for a candidate tasks file.
# A file that is unreadable or not valid JSON yields an inert descriptor
# (no marker, no stories) instead of aborting: one corrupt file sitting in
# .aimi/tasks/ must not take detection down for every other feature.
_split_detect_describe() {
  local file="$1"
  local desc=""
  desc=$(jq -c --arg path "$file" "$_SPLIT_DETECT_DESCRIBE_JQ" "$file" 2>/dev/null) || desc=""
  if [ -z "$desc" ]; then
    desc=$(jq -nc --arg path "$file" '{path: $path, project: ".", branchName: null,
      storyCount: 0, pendingCount: 0, hasMarker: false, declaredTotal: "",
      siblings: [], active: false}')
  fi
  printf '%s' "$desc"
}

# List *-tasks.json files directly inside <dir> (depth 1 only), newest mtime
# first. NUL-delimited find keeps paths containing spaces intact, the same
# hardening _find_tasks_files_all carries; a newline-delimited `xargs ls -t`
# word-splits them and silently returns nothing. The find output is captured
# into an array first and ls -t is only invoked when that array is
# non-empty -- xargs runs its command once even on empty input, and `ls -t`
# with no arguments lists the current directory (PROJECT_ROOT, not <dir>)
# rather than nothing. Same restructuring as _find_tasks_files_all.
_split_detect_list_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*-tasks.json' -print0 2>/dev/null)
  [ ${#files[@]} -gt 0 ] || return 0
  ls -t "${files[@]}" 2>/dev/null || true
}

# Derive the phase's own governing tasks file from a phase directory, so it can
# be excluded from the split candidate pool. Layout is
# .aimi/tasks/<feature>/phase-<N>[.<M>][-<slug>]/<feature>-phase-<N>-tasks.json.
# Prints nothing when <dir> is not shaped like a phase directory (nothing to
# exclude then, which is the safe direction: an extra candidate is still
# filtered by the marker and pair rules below).
_split_detect_phase_main_file() {
  local dir="$1"
  local dir_base feature phase_id
  dir_base=$(basename "$dir")
  case "$dir_base" in
    phase-[0-9]*) ;;
    *) return 0 ;;
  esac
  phase_id=${dir_base#phase-}
  phase_id=${phase_id%%-*}
  case "$phase_id" in
    ''|*[!0-9.]*) return 0 ;;
  esac
  feature=$(basename "$(dirname "$dir")")
  [ -n "$feature" ] || return 0
  printf '%s/%s-phase-%s-tasks.json' "$dir" "$feature" "$phase_id"
}

cmd_split_detect() {
  local scope_dir=""
  local dir_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Error: split-detect: --dir requires a directory path" >&2
          exit 1
        fi
        scope_dir="$2"
        dir_mode=true
        shift 2
        ;;
      *)
        echo "Error: split-detect: unknown argument: $1" >&2
        exit 1
        ;;
    esac
  done

  # ------------------------------------------------------------------
  # 1. Build the candidate pool, newest mtime first
  # ------------------------------------------------------------------
  local candidates=""
  local exclude_file=""
  if [ "$dir_mode" = true ]; then
    if [ ! -d "$scope_dir" ]; then
      echo "Error: split-detect: --dir is not a directory: $scope_dir" >&2
      exit 1
    fi
    scope_dir=$(resolve_path "$scope_dir")
    validate_path_in_project "$scope_dir"
    exclude_file=$(_split_detect_phase_main_file "$scope_dir")
    candidates=$(_split_detect_list_dir "$scope_dir")
  else
    # Flat scope is depth 1 ONLY: candidates are the *-tasks.json files whose
    # parent directory is $TASKS_DIR itself. _find_tasks_files_all globs depth
    # 1-3, which includes every phase directory -- and that is exactly how a
    # phase's split files used to be captured by the flat flow and executed as
    # a flat split, leaving the phase unclaimed and nothing merged into the
    # phase branch. The filter below is the fix, and it is load-bearing.
    local all_files=""
    all_files=$(_find_tasks_files_all)
    if [ -n "$all_files" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$(dirname "$f")" = "$TASKS_DIR" ] || continue
        candidates="${candidates}${f}"$'\n'
      done <<< "$all_files"
    fi
  fi

  local pool="[]"
  if [ -n "$candidates" ]; then
    local cand desc
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      [ -n "$exclude_file" ] && [ "$cand" = "$exclude_file" ] && continue
      desc=$(_split_detect_describe "$cand")
      pool=$(printf '%s' "$pool" | jq -c --argjson d "$desc" '. + [$d]')
    done <<< "$candidates"
  fi

  local started_empty=false
  [ "$(printf '%s' "$pool" | jq 'length')" -eq 0 ] && started_empty=true

  # ------------------------------------------------------------------
  # 2. Resolve the group
  # ------------------------------------------------------------------
  # "Newest wins": the anchor is the newest candidate, not the first
  # marker-carrying file in mtime order. The old rule let a stale marked split
  # from a past feature preempt today's plan whenever today's files carried no
  # marker of their own.
  local mode="none"
  local anchor="null"
  local members="[]"
  local declared_total="0"
  local degraded_reason=""

  # AIMI_ROOT-is-a-git-repo check, computed once. find_aimi_root() already cd'd
  # the process to AIMI_ROOT before cmd_split_detect ever runs (dispatch at
  # line ~9167 happens after the find_aimi_root call at ~9116), and --dir only
  # narrows the candidate pool below -- it never changes CWD. So $PWD here is
  # AIMI_ROOT in both flat and --dir scope, and this is the identical check
  # commands/execute.md documents as the canonical AIMI_ROOT_IS_GIT_REPO rule.
  local aimi_root_is_git=true
  git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1 || aimi_root_is_git=false

  while :; do
    local pool_len=0
    pool_len=$(printf '%s' "$pool" | jq 'length')
    if [ "$pool_len" -eq 0 ]; then
      mode="none"
      if [ "$started_empty" != true ] && [ -z "$degraded_reason" ]; then
        degraded_reason="every candidate group is already fully completed"
      fi
      break
    fi

    local newest newest_path newest_dir newest_marker
    newest=$(printf '%s' "$pool" | jq -c '.[0]')
    newest_path=$(printf '%s' "$newest" | jq -r '.path')
    newest_dir=$(dirname "$newest_path")
    newest_marker=$(printf '%s' "$newest" | jq -r '.hasMarker')

    local group="[]"
    local group_mode=""
    local group_total="0"

    if [ "$newest_marker" = "true" ]; then
      # -- Marked group: the members are the anchor plus its OWN declared
      #    siblings. Nothing else in the pool participates, however similar
      #    its basename. Each sibling resolves BY BASENAME against the
      #    anchor's own directory, which is what renders a traversal-shaped
      #    sibling entry inert: "../../etc/passwd" becomes "<anchor-dir>/passwd",
      #    which does not exist, and the group is voided.
      local anchor_total="" resolve_ok=true bad_detail=""
      anchor_total=$(printf '%s' "$newest" | jq -r '.declaredTotal')
      group="[$newest]"

      case "$anchor_total" in
        ''|*[!0-9]*)
          resolve_ok=false
          bad_detail="declared total is not a whole number: \"${anchor_total}\""
          ;;
      esac

      if [ "$resolve_ok" = true ]; then
        local sib sib_path sib_desc dup
        while IFS= read -r sib; do
          [ -n "$sib" ] || continue
          sib_path="$newest_dir/$(basename "$sib")"
          if [ ! -f "$sib_path" ]; then
            resolve_ok=false
            bad_detail="declared sibling not found in the anchor's directory: $sib_path"
            break
          fi
          dup=$(printf '%s' "$group" | jq -r --arg p "$sib_path" '[.[] | select(.path == $p)] | length')
          if [ "$dup" -ne 0 ]; then
            resolve_ok=false
            bad_detail="declared sibling resolves to a member already in the group: $sib_path"
            break
          fi
          sib_desc=$(_split_detect_describe "$sib_path")
          group=$(printf '%s' "$group" | jq -c --argjson d "$sib_desc" '. + [$d]')
        done <<< "$(printf '%s' "$newest" | jq -r '.siblings[]')"
      fi

      local resolved=0
      resolved=$(printf '%s' "$group" | jq 'length')
      if [ "$resolve_ok" != true ] || [ "$resolved" -ne "$anchor_total" ] || [ "$resolved" -lt 2 ]; then
        # A group that fails validation degrades to single-file execution and
        # is TERMINAL -- it deliberately does not fall through to the legacy
        # pair rule. This scope was planned by the project-split writer, so any
        # -frontend-/-backend-tasks.json sitting beside it is stale, and running
        # it would execute the wrong work.
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        degraded_reason="split group anchored at ${newest_path} is unusable (declared total ${anchor_total:-?}, resolved ${resolved}"
        if [ -n "$bad_detail" ]; then
          degraded_reason="${degraded_reason}; ${bad_detail}"
        fi
        degraded_reason="${degraded_reason}) — degraded to single-file execution, legacy pair not considered"
        break
      fi

      group_mode="project-split"
      group_total="$anchor_total"
    else
      # -- No marker on the newest candidate: try the legacy
      #    -frontend-tasks.json / -backend-tasks.json pair rule over the pool.
      #    The counterpart must be in the pool, not merely on disk, so the
      #    scope (flat depth 1, or this one phase directory) still bounds it.
      local newest_base prefix fe_path be_path
      newest_base=$(basename "$newest_path")
      prefix=""
      fe_path=""
      be_path=""
      case "$newest_base" in
        *-frontend-tasks.json)
          prefix="${newest_base%-frontend-tasks.json}"
          fe_path="$newest_path"
          be_path="$newest_dir/${prefix}-backend-tasks.json"
          ;;
        *-backend-tasks.json)
          prefix="${newest_base%-backend-tasks.json}"
          be_path="$newest_path"
          fe_path="$newest_dir/${prefix}-frontend-tasks.json"
          ;;
      esac

      local counterpart=""
      if [ -n "$prefix" ]; then
        if [ "$fe_path" = "$newest_path" ]; then counterpart="$be_path"; else counterpart="$fe_path"; fi
        local in_pool
        in_pool=$(printf '%s' "$pool" | jq -r --arg p "$counterpart" '[.[] | select(.path == $p)] | length')
        [ "$in_pool" -eq 0 ] && counterpart=""
      fi

      if [ -n "$counterpart" ]; then
        if [ "$aimi_root_is_git" != true ]; then
          # A legacy frontend/backend pair with no metadata.splitGroup marker
          # resolves to the root routing key "." (_SPLIT_DETECT_DESCRIBE_JQ's
          # default at 6459) -- fine in a single-repo layout, but AIMI_ROOT
          # here is not a git repository at all: a parent folder holding
          # multiple git repos as subfolders, with no repository underneath
          # "." to execute in. Refuse instead of binding to it. Reuses the
          # same mode=none-plus-degradedReason shape as the exhausted-pool
          # case above -- no new mode value, no new emitted field.
          mode="none"
          anchor="null"
          members="[]"
          declared_total="0"
          degraded_reason="AIMI_ROOT (${PWD}) is not a git repository — this is a multi-repo layout, a parent folder holding multiple git repositories as subfolders. The legacy pair ${fe_path} / ${be_path} has no metadata.splitGroup marker and would route to the root group \".\", which has no repository to execute in. Re-plan with --split full-stack so every story carries its own project, then re-run."
          break
        fi
        # Frontend first, backend second — the order the two-file writer and
        # every downstream report already assume.
        group=$(printf '%s' "$pool" | jq -c --arg fe "$fe_path" --arg be "$be_path" \
          '[(.[] | select(.path == $fe)), (.[] | select(.path == $be))]')
        group_mode="paired-split"
        group_total="2"
      else
        mode="single"
        anchor=$(printf '%s' "$newest" | jq -c '.path')
        members="[$newest]"
        declared_total="1"
        break
      fi
    fi

    # A group with nothing left to do is not this run's work. Drop ALL of its
    # members from the pool and look again, rather than letting a completed
    # stale split route today's real work to a single-file fallback.
    local group_active=0
    group_active=$(printf '%s' "$group" | jq '[.[] | select(.active)] | length')
    if [ "$group_active" -eq 0 ]; then
      pool=$(printf '%s\n%s' "$pool" "$group" | jq -sc '
        .[1] as $g | [.[0][] | select(.path as $p | ($g | map(.path) | index($p)) == null)]')
      continue
    fi

    mode="$group_mode"
    anchor=$(printf '%s' "$newest" | jq -c '.path')
    members="$group"
    declared_total="$group_total"
    break
  done

  # ------------------------------------------------------------------
  # 3. Emit
  # ------------------------------------------------------------------
  printf '%s' "$members" | jq \
    --arg mode "$mode" \
    --argjson anchor "$anchor" \
    --argjson total "$declared_total" \
    --arg reason "$degraded_reason" \
    '{
      mode: $mode,
      anchor: $anchor,
      members: [.[] | {path, project, branchName, storyCount, pendingCount, active}],
      activeCount: ([.[] | select(.active)] | length),
      total: $total,
      degradedReason: (if ($reason | length) > 0 then $reason else null end)
    }'
}

# ============================================================================
# Roadmap Lifecycle Subcommands (Phase/Milestone layer for large-scope features)
# ============================================================================
#
# roadmap.json lives at .aimi/tasks/<feature>/roadmap.json and tracks phase
# lifecycle state (pending -> planned -> in_progress -> completed, or ->
# verification_failed) plus PID-alive claims so parallel /aimi:execute
# sessions can safely claim independent phases without hallucinated bash.
# Every write is a locked read-modify-write (mkdir-then-lock-then-tmpfile-
# then-move), mirroring _story_merge_write_legacy. flock is held only for
# the duration of each atomic operation -- never across separate CLI calls.

# Single-path-component pattern for a phase's dir field: phase-N[.M][-slug]
_ROADMAP_DIR_REGEX='^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$'
# Single-path-component pattern for the --feature slug (no slash, no dotdot)
_ROADMAP_FEATURE_REGEX='^[a-zA-Z0-9][a-zA-Z0-9_-]*$'
# Reused branchName convention (see plugins/aimi-engineering/CLAUDE.md)
_ROADMAP_BRANCH_REGEX='^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'

# The stored roadmap.json shape every contract READER in this file requires.
#
# It tracks the shape of one creates/needs entry and nothing else -- not the
# CLI version, not the plugin version, not any other roadmap.json field. "1.0"
# means an entry is the single string "identity (description)"; "2.0" means it
# is {identity, description}, two fields judged by two different rules. Bump it
# only when that entry shape changes again, and ship the normalize-contracts
# migration in the same commit.
_ROADMAP_CONTRACT_VERSION="2.0"

# Validate --feature is present and a safe single path component.
# $2 is the optional verb label used to prefix the error; it defaults to the
# historical "roadmap" so every pre-existing caller's message is byte-identical.
_roadmap_validate_feature() {
  local feature="$1"
  local label="${2:-roadmap}"
  if [ -z "$feature" ]; then
    echo "Error: $label: --feature <slug> is required" >&2
    exit 1
  fi
  if ! [[ "$feature" =~ $_ROADMAP_FEATURE_REGEX ]]; then
    echo "Error: $label: --feature must be a single path component matching $_ROADMAP_FEATURE_REGEX, got: $feature" >&2
    exit 1
  fi
}

# Compute the roadmap.json path for a feature (absolute, under TASKS_DIR).
_roadmap_path() {
  local feature="$1"
  printf '%s/%s/roadmap.json\n' "$TASKS_DIR" "$feature"
}

# Shared roadmap-verb preamble: resolve the path, validate it's in-project,
# and fail with a verb-prefixed message if the roadmap is missing or malformed.
# Echoes the resolved path on success. Usage:
#   roadmap_path=$(_roadmap_require <verb> <feature> [not-found-suffix] [--skip-malformed])
# not-found-suffix is appended verbatim to the "roadmap not found" message
# (e.g. " (run roadmap-init first)"); pass "" to omit it.
# --skip-malformed omits the malformed-json check (roadmap-release-claim never
# had one; preserved as-is rather than newly introduced here).
# Several callers re-check malformed-ness a second time inside their _lock
# subshell -- that inner check is deliberate (it re-reads under the lock to
# catch a file that turns malformed between this call and lock acquisition)
# and is not replaced by this helper.
_roadmap_require() {
  local verb="$1" feature="$2" suffix="${3:-}" skip_malformed="${4:-}"
  local path
  path=$(_roadmap_path "$feature")
  validate_path_in_project "$path"
  if [ ! -f "$path" ]; then
    echo "Error: $verb: roadmap not found: $path${suffix}" >&2
    exit 1
  fi
  if [ "$skip_malformed" != "--skip-malformed" ]; then
    if ! jq -e . "$path" >/dev/null 2>&1; then
      echo "Error: $verb: malformed roadmap.json: $path" >&2
      exit 1
    fi
  fi
  printf '%s\n' "$path"
}

# Refuse a roadmap whose stored creates/needs entries pre-date
# $_ROADMAP_CONTRACT_VERSION.
#   _roadmap_require_contracts <verb> <roadmap_path> <feature>
#
# IT REFUSES, IT DOES NOT SKIP, and that is the whole design of this helper.
# The tempting alternative -- treat an old roadmap as "nothing to check" and
# carry on -- makes validate-contracts answer valid:true about a document it
# never parsed. A gate that reports success for an unread file is worse than
# no gate: the caller acts on the verdict either way, and only one of the two
# outcomes tells them the truth is unknown.
#
# WHO CALLS IT, AND WHO DELIBERATELY DOES NOT. Every verb that reads or writes
# a creates/needs entry: validate-contracts, verify-creates, roadmap-sweep,
# roadmap-write-handoff, roadmap-amend-phase, and roadmap-init --sync (which
# would otherwise merge a 2.0 phase into a 1.0 document and leave one file
# holding both shapes -- measured: that mixture drops an identity a later phase
# still cites and only surfaces a whole phase later).
#
# The five LIFECYCLE verbs -- roadmap-get, roadmap-set-status, roadmap-claim,
# roadmap-release-claim, roadmap-reconcile -- are ungated on purpose. None of
# them reads an entry; they move status and claims. Gating them would mean a
# session already in flight when the migration lands could not release its own
# claim or record the phase it just finished, which is a worse failure than the
# one this gate exists to prevent. normalize-contracts is ungated for the
# obvious reason: it is the migration.
#
# phase-overlap is ungated too, and that is a judgement rather than an
# oversight: it reads `dir` from roadmap.json and then two tasks files'
# implementation.files. Its verdict does not depend on a contract entry, so
# refusing it would strand a caller for a reason its answer never touched.
#
# The comparison is the sort -V idiom cmd_validate_tasks already uses for
# schemaVersion, with a "0" floor so an absent or null roadmapVersion sorts
# below every real one and is refused rather than silently accepted. A version
# ABOVE the required one passes: this CLI can read a document a newer CLI
# wrote for as long as the entry shape is compatible, and refusing it here
# would strand a user mid-upgrade for no gain.
_roadmap_require_contracts() {
  local verb="$1" roadmap_path="$2" feature="$3"
  local stored
  stored=$(jq -r '.roadmapVersion // "0"' "$roadmap_path" 2>/dev/null) || stored="0"
  if [ -z "$stored" ] || [ "$stored" = "null" ]; then
    stored="0"
  fi
  if [ "$(printf '%s\n' "$stored" "$_ROADMAP_CONTRACT_VERSION" | sort -V | head -n1)" != "$_ROADMAP_CONTRACT_VERSION" ]; then
    echo "Error: $verb: this roadmap stores creates/needs in the pre-$_ROADMAP_CONTRACT_VERSION form, where one entry is the single string \"identity (description)\". Nothing was read and nothing was checked. Migrate it once, in place:" >&2
    echo "    aimi-cli.sh normalize-contracts --feature $feature" >&2
    echo "The migration is idempotent and computes each identity with the same function every reader used before, so no identity changes by a byte. (found roadmapVersion $stored, need $_ROADMAP_CONTRACT_VERSION)" >&2
    exit 1
  fi
}

# Validate --phase is present and a bare numeric id (int or one-decimal-place).
#
# The integer half refuses a LEADING ZERO on purpose: every --phase consumer
# hands the id to roadmap.py, which parses it with json.loads(), and JSON has
# no "02". Admitting it here bought a 12-line uncaught JSONDecodeError instead
# of the one readable line below. "0" itself is still a legal id -- the
# alternation spells that out rather than leaving it to a lucky quantifier.
# The decimal half is deliberately untouched: it is the only thing separating
# 2.1 from 2.10, and both must keep passing (they are the same number, and the
# Python side normalizes them to one).
_roadmap_validate_phase_id() {
  local phase_id="$1"
  local label="$2"
  if [ -z "$phase_id" ] || ! [[ "$phase_id" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then
    echo "Error: $label: --phase <id> must be a numeric phase id" >&2
    exit 1
  fi
}

# Read a phases JSON array on stdin; print one human-readable error line per
# creates[]/needs[] entry whose *identity* can never name a real artifact.
#
# The rule is deliberately narrow -- exactly six shapes are rejected, judged
# over the identity FIELD and nothing else:
#   (a) empty
#   (b) a ".." PATH SEGMENT, i.e. (^|/)\.\.($|/) -- not any byte pair "..",
#       so an identity like services/foo..bar is untouched
#   (c) a leading "/" anchored at position 0 -- the Endpoint kind
#       ("POST /api/notifications") contains a slash but does not begin with
#       one, so anchoring matters or every endpoint phase becomes unwritable
#   (d) whitespace in the token verify-creates will actually SEARCH, judged
#       after the same METHOD-space-slash strip verify-creates step 2 performs
#       (see _roadmap_reject_unfindable_identity below)
#   (e) a shell metacharacter from _SHELL_CLASS -- the class [$`;|&] that
#       validate-contracts reads through cv_shell_char -- so the writer and
#       the reader consult one table rather than two that overlap by accident
#   (f) more than 500 characters. This one is a REFUSAL where every other
#       roadmap free-text field truncates, and the asymmetry is the point: a
#       truncated goal is still the goal, while a truncated identity is a name
#       verify-creates would grep for and never find. Nothing rewrites an
#       identity, so nothing may shorten one either.
# Identity *strength* is explicitly not judged: at declaration time research has
# not run, so a bare Table name ("notifications") or a bare directory
# ("db/migrations") must pass -- guessing a path here fails at phase close for a
# reason nobody can debug.
#
# Why (d) is whitespace and not something richer. verify-creates has exactly two
# ways to find an artifact: a tracked pathspec, and a fixed-string `git grep -F`
# over tracked non-doc non-test source. A token carrying an interior space can
# only match source that literally holds that space-separated phrase.
# Identifiers, paths, table names and route literals never do. The only thing
# that CAN hold it is prose -- a comment or a string -- and documentation is
# already excluded, so a whitespace-bearing identity is either unfindable or,
# worse, findable only in a comment. That is not a heuristic about English; it
# is a statement about what the search can return.
#
# The two things (d) deliberately does NOT catch, so nobody reads it as a
# guarantee of verifiability:
#   * a hyphen-joined prose phrase ("forge-command-surface-in-aimi-cli") --
#     an author who wants to write prose can defeat the rule trivially;
#   * a single token that will simply never exist ("cmd_forge_nonexistent").
# Existence cannot be checked at declaration time -- the artifact has not been
# built yet. The rule proves the identity is the KIND of string a search can
# resolve, never that it will resolve.
#
# The accepted false positive: an honest artifact whose name contains a space
# ("src/My Component.tsx"). It is refusable and the author's only workaround is
# to rename the file. That is the deliberate trade -- see
# commands/references/scope-contexts.md, which teaches the rule and its limit.
#
# Why (e) judges the IDENTITY and not both fields. Before it existed the two
# sides disagreed twice over. The writer let ";" "|" "&" and a lone "$" through
# untouched while validate-contracts refused that whole class, so roadmap-init
# wrote phases its own contract gate then hard-failed; and the reader judged the
# whole entry, so a semicolon anywhere in the human description killed an
# identity that was itself clean ("cmd_clean", "does x; then y").
# Both sides now judge the same text -- the identity carries the class ban and
# the description does not -- which is also what verify-creates has always done:
# it searches by identity alone, so a check scoped to anything wider was talking
# about a different string than the search it guards.
#
# The description nevertheless KEEPS validate-contracts' injection half
# (ignore previous / system: / INSTRUCTIONS / code fences / "$("), because it is
# not human-only prose: /aimi:plan collects every completed phase's handoff.md
# into phaseHandoffBlocks (grep that symbol in commands/plan.md) and threads it verbatim
# into every story-expander sub-agent prompt (grep phaseHandoffBlocks in
# commands/plan.md; line numbers there drift). Freeing the description of the
# character class is a legibility fix; freeing it of the injection patterns
# would reopen a prompt-injection path that is closed today.
#
# ALL FIVE class characters reach (e), the backtick included. That is new. It
# used to be unreachable: a splitting sanitizer ran over the entry first and its
# marker half unwrapped a backticked span, so no backtick survived into a stored
# identity. Nothing sanitizes an identity now, so a backticked name arrives here
# intact and is refused by name -- which is the outcome the unwrap was
# approximating, reached by saying so instead of by rewriting.
#
# "$(" is NOT a sixth class member and never was: it is a two-character
# SEQUENCE, and the class member it starts with, "$", reaches this rule like any
# other. Counting it as a member is what made an earlier draft of this comment
# say "two of the five", which is wrong by one and reads as though a "$" were
# somehow exempt. It is not.
#
# RETROACTIVITY IS THE CALLER'S PROPERTY, NOT THIS HELPER'S. Nothing here scopes
# anything; this judges every phase object it is handed. Existing roadmaps stay
# readable only because every caller hands over just the phases IT writes:
# roadmap-init passes the whole payload in creation mode but only filtered_new
# under --sync (phases whose ids are not already on disk), and
# cmd_roadmap_amend_phase passes the id plus only the lists that call amends.
# A caller that hands over a stored phase wholesale would retroactively refuse
# roadmaps already written -- this repository's own phases 2, 3 and 4 carry
# whitespace-bearing creates today.
#
# creates[] and needs[] go through the same predicate in the same pass on
# purpose: _cv_creates_in_scope matches a need against a provider's creates by
# exact byte equality, so a rule applied to one list alone lets a roadmap hold
# two shapes at once -- validate-contracts then reports a permanently unmet
# need, which halts /aimi:plan, and agent mode never demotes an unmet need.
#
# The guard and validate-contracts read the same cv_identity in roadmap.py, so
# they agree on what an identity is; a second copy of it would drift.
cmd_roadmap_init() {
  local feature="" file="" sync_mode=false brainstorm_path="" integration_branch=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      --sync) sync_mode=true ;;
      --brainstorm-path) shift; brainstorm_path="${1:-}" ;;
      --integration-branch) shift; integration_branch="${1:-}" ;;
      *)
        echo "Error: roadmap-init: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_path "$feature")
  validate_path_in_project "$roadmap_path"

  # --- Read the phases array from --file or stdin ---
  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-init: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  # --- Everything that must be judged BEFORE the lock ---------------------
  # The split is not cosmetic: today an invalid payload never reaches the
  # mkdir -p below, so a refusal creates no feature directory. Validating
  # inside the lock would create one as a side effect of saying no.
  check_python3
  local new_phases
  new_phases=$(printf '%s' "$input_json" | python3 "$(_aimi_roadmap_py)" init-validate \
    --integration-branch "$integration_branch") || exit $?

  # A --sync merges 2.0 phases into whatever is already there. Into a pre-2.0
  # document that produces one file holding both entry shapes, which is worse
  # than either shape alone: the readers see a list they cannot judge uniformly.
  # Gated only when the file exists, because a fresh roadmap-init has nothing to
  # be old, and only under --sync, because without it the "already exists; pass
  # --sync" refusal below is the more actionable message.
  if [ "$sync_mode" = true ] && [ -f "$roadmap_path" ]; then
    _roadmap_require_contracts "roadmap-init" "$roadmap_path" "$feature"
  fi

  mkdir -p "$(dirname "$roadmap_path")"

  # --- Locked read-modify-write: existence/--sync check, additive merge, atomic write ---
  local sync_flag=""
  [ "$sync_mode" = true ] && sync_flag="--sync"
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      printf '%s' "$new_phases" | python3 "$(_aimi_roadmap_py)" init-write \
        --roadmap "$roadmap_path" --feature "$feature" \
        --brainstorm-path "$brainstorm_path" --integration-branch "$integration_branch" $sync_flag
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# roadmap-amend-phase — correct an existing phase's contract after the fact
# ============================================================================
#
# roadmap-init writes a phase's contract exactly once, at creation, and --sync's
# anti-clobber guarantee leaves an existing phase byte-for-byte alone. That is
# deliberate, and it leaves a phase whose creates/needs/goal/successCriteria/
# areas/branch turn out wrong with no sanctioned writer at all -- while
# guard-runtime-state.py intercepts a Write/Edit on roadmap.json and redirects
# the caller to "the roadmap-* verbs". This verb is what makes that redirect
# truthful.
#
cmd_roadmap_amend_phase() {
  local feature="" phase_id="" file="" goal_flag="" branch_flag=""
  local have_goal=false have_branch=false
  local retarget_pairs='[]'
  local pair pair_old pair_new

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      --goal) shift; goal_flag="${1:-}"; have_goal=true ;;
      --branch) shift; branch_flag="${1:-}"; have_branch=true ;;
      --retarget-needs)
        shift
        pair="${1:-}"
        case "$pair" in
          *=*) ;;
          *)
            echo "Error: roadmap-amend-phase: --retarget-needs expects \"<old identity>=<new identity>\", got: $pair" >&2
            exit 1
            ;;
        esac
        # Split on the FIRST "=" only: an identity may legitimately contain one.
        pair_old="${pair%%=*}"
        pair_new="${pair#*=}"
        if [ -z "$pair_old" ] || [ -z "$pair_new" ]; then
          echo "Error: roadmap-amend-phase: --retarget-needs requires a non-empty identity on both sides of the first \"=\", got: $pair" >&2
          exit 1
        fi
        retarget_pairs=$(printf '%s' "$retarget_pairs" | jq -c --arg o "$pair_old" --arg n "$pair_new" '. + [{old: $o, new: $n}]')
        ;;
      *)
        echo "Error: roadmap-amend-phase: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature" "roadmap-amend-phase"
  _roadmap_validate_phase_id "$phase_id" "roadmap-amend-phase"

  # --- Resolve the amendment payload -------------------------------------
  # --file wins. Otherwise stdin is read only when no scalar flag was given, so
  # `--goal <text>` on its own never blocks waiting for an EOF nobody will send.
  local payload='{}'
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-amend-phase: --file not found: $file" >&2
      exit 1
    fi
    payload=$(cat "$file")
  elif [ "$have_goal" != true ] && [ "$have_branch" != true ]; then
    payload=$(cat)
  fi

  if [ -z "${payload//[[:space:]]/}" ]; then
    payload='{}'
  fi

  # --- Everything judged BEFORE the lock ----------------------------------
  # Same split, and for the same reason, as roadmap-init: a refusal must not
  # take the lock and must not touch the file.
  check_python3
  local goal_args=() branch_args=()
  [ "$have_goal" = true ] && goal_args=(--goal "$goal_flag")
  [ "$have_branch" = true ] && branch_args=(--branch "$branch_flag")
  local sanitized
  sanitized=$(printf '%s' "$payload" | python3 "$(_aimi_roadmap_py)" amend-validate \
    "${goal_args[@]}" "${branch_args[@]}") || exit $?

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-amend-phase" "$feature")
  _roadmap_require_contracts "roadmap-amend-phase" "$roadmap_path" "$feature"

  # --- Locked read-modify-write ------------------------------------------
  # Bash holds the lock; roadmap.py does the whole read-modify-write inside it.
  # Every refusal still happens before the file is touched, so a refused
  # amendment leaves roadmap.json byte-for-byte unchanged.
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      printf '%s' "$sanitized" | python3 "$(_aimi_roadmap_py)" amend-write \
        --roadmap "$roadmap_path" --feature "$feature" --phase "$phase_id" \
        --retargets "$retarget_pairs"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# The only lifecycle verb that takes no lock: it reads and reports, so there is
# nothing for a lock to protect. That is also why it never clears a stale
# dead-PID claim the way roadmap-claim does -- inferring liveness is a decision
# that belongs where the lock is, and a phase held by a dead session therefore
# stays claimable by roadmap-claim and invisible here, exactly as before.
cmd_roadmap_get() {
  local feature="" phase_id="" next_eligible=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --next-eligible) next_eligible=true ;;
      *)
        echo "Error: roadmap-get: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-get" "$feature")

  local phase_args=() next_args=()
  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "roadmap-get"
    phase_args=(--phase "$phase_id")
  fi
  [ "$next_eligible" = true ] && next_args=(--next-eligible)

  check_python3
  python3 "$(_aimi_roadmap_py)" roadmap-get \
    --roadmap "$roadmap_path" --feature "$feature" "${phase_args[@]}" "${next_args[@]}"
}

# Which phases may be expanded, and for each of the rest, what is holding it.
#
# Structurally cmd_roadmap_get, and that is the whole decision: no
# _roadmap_require_contracts. Eligibility reads id, status, claim and dependsOn,
# not one creates/needs entry, so the 2.0 contract gate would refuse a
# pre-migration roadmap over a shape this verb never looks at -- and refusing
# here means /aimi:plan cannot expand any phase of it. The five lifecycle verbs
# are ungated for the same reason, spelled out at _roadmap_require_contracts.
#
# It takes no lock (nothing to protect, it only reads) and passes no --feature
# to roadmap.py: unlike roadmap-get --next-eligible it reads no per-phase tasks
# file, which is what makes its answer depend on roadmap.json alone while a
# concurrent /aimi:execute rewrites those files.
cmd_roadmap_eligible() {
  local feature="" statuses=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --statuses) shift; statuses="${1:-}" ;;
      *)
        echo "Error: roadmap-eligible: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature" "roadmap-eligible"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-eligible" "$feature")

  local status_args=()
  [ -n "$statuses" ] && status_args=(--statuses "$statuses")

  check_python3
  python3 "$(_aimi_roadmap_py)" roadmap-eligible \
    --roadmap "$roadmap_path" "${status_args[@]}"
}

cmd_roadmap_set_status() {
  local feature="" phase_id="" new_status="" force=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --status) shift; new_status="${1:-}" ;;
      --force) force=true ;;
      *)
        echo "Error: roadmap-set-status: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-set-status"

  case "$new_status" in
    pending|planned|in_progress|completed|verification_failed) ;;
    *)
      echo "Error: roadmap-set-status: --status must be one of pending|planned|in_progress|completed|verification_failed, got: $new_status" >&2
      exit 1
      ;;
  esac

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-set-status" "$feature")

  # One crossing, not the two roadmap-init and roadmap-amend-phase make. Their
  # split exists because a payload arrives on stdin and can be refused without
  # reading roadmap.json at all -- refusing inside the lock would create the
  # feature directory as a side effect of saying no. This verb has no payload:
  # every refusal it can reach without the document (feature, phase id, status
  # enum) has already happened above, and every remaining one needs the file, so
  # a second call could only re-read what the first one holds.
  check_python3
  local force_args=()
  [ "$force" = true ] && force_args=(--force)

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" set-status \
        --roadmap "$roadmap_path" --phase "$phase_id" --status "$new_status" \
        "${force_args[@]}"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_claim() {
  local feature="" session_id="" session_pid="" phase_override=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --session-id) shift; session_id="${1:-}" ;;
      --session-pid) shift; session_pid="${1:-}" ;;
      --phase) shift; phase_override="${1:-}" ;;
      *)
        echo "Error: roadmap-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -z "$session_id" ]; then
    echo "Error: roadmap-claim: --session-id <id> is required" >&2
    exit 1
  fi
  if ! [[ "$session_pid" =~ ^[0-9]+$ ]]; then
    echo "Error: roadmap-claim: --session-pid <pid> must be a positive integer" >&2
    exit 1
  fi
  if [ -n "$phase_override" ]; then
    _roadmap_validate_phase_id "$phase_override" "roadmap-claim"
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-claim" "$feature" " (run roadmap-init first)")

  # The session id is sanitized on the far side, by rm_sanitize in
  # scripts/sanitize.py -- the same function every other free-text roadmap
  # field goes through -- before it is ever written to roadmap.json.
  #
  # The exit statuses are the contract, not a detail: execute.md branches on 4
  # ("there is nothing left to claim") and 3 ("there is, and you cannot have
  # it"), so they travel out of the subshell through `|| exit $?` unchanged.
  check_python3
  local phase_args=()
  [ -n "$phase_override" ] && phase_args=(--phase "$phase_override")

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" claim \
        --roadmap "$roadmap_path" --feature "$feature" \
        --session-id "$session_id" --session-pid "$session_pid" "${phase_args[@]}"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_release_claim() {
  local feature="" phase_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      *)
        echo "Error: roadmap-release-claim: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-release-claim"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-release-claim" "$feature" "" --skip-malformed)

  check_python3
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" release-claim \
        --roadmap "$roadmap_path" --phase "$phase_id"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

cmd_roadmap_reconcile() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      *)
        echo "Error: roadmap-reconcile: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-reconcile" "$feature")

  check_python3
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" reconcile \
        --roadmap "$roadmap_path" --feature "$feature"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# Write a phase's handoff.md through a guard-protected CLI call (see outline
# 11). guard-runtime-state.py blocks any direct Write/Edit tool call whose
# target is .aimi/tasks/<feature>/phase-N/handoff.md and points the caller
# back at this verb -- this is the only path that may create or overwrite
# that file. Reads a JSON object from --file or stdin with five optional
# array-of-string fields (decisions, artifacts, deviations, deferred,
# contracts); each entry is sanitized and length-capped by rm_sanitize in
# scripts/sanitize.py, the same regime every other free-text roadmap field
# goes through. Always emits
# exactly five "## " headings in the fixed order
# "Decisions Made" / "Artifacts Created" / "Deviations" / "Deferred Items" /
# "Contracts Delivered" -- the order roadmap-set-status's completed-requires-
# handoff precondition and handoff_lists_artifact's "Artifacts Created"
# lookup both depend on. Overwrites any existing handoff.md at that path
# (idempotent retry after a verification_failed -> completed re-run).
cmd_roadmap_write_handoff() {
  local feature="" phase_id="" file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      --file) shift; file="${1:-}" ;;
      *)
        echo "Error: roadmap-write-handoff: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "roadmap-write-handoff"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-write-handoff" "$feature")
  _roadmap_require_contracts "roadmap-write-handoff" "$roadmap_path" "$feature"

  # The one roadmap read that stays here: the handoff path is built from this
  # phase's stored dir, and validate_path_in_project below is a bash rule about
  # where this process may write. Resolving the dir in roadmap.py would mean
  # either a second call just to learn the path, or moving path confinement into
  # a file that has no business owning it.
  local phase_dir
  phase_dir=$(jq -r --argjson pid "$phase_id" '(.phases[] | select(.id == $pid) | .dir) // empty' "$roadmap_path")
  if [ -z "$phase_dir" ]; then
    echo "Error: roadmap-write-handoff: phase $phase_id not found in $roadmap_path" >&2
    exit 1
  fi

  local input_json
  if [ -n "$file" ]; then
    validate_path_in_project "$file"
    if [ ! -f "$file" ]; then
      echo "Error: roadmap-write-handoff: --file not found: $file" >&2
      exit 1
    fi
    input_json=$(cat "$file")
  else
    input_json=$(cat)
  fi

  # Payload validation, the declared-identity lookup, the render and the
  # lost-identity tripwire are one call: they are all judgements about the same
  # document and the tripwire needs the rendered body to make its own.
  check_python3
  local body
  body=$(printf '%s' "$input_json" | python3 "$(_aimi_roadmap_py)" write-handoff \
    --roadmap "$roadmap_path" --phase "$phase_id") || exit $?

  local feature_dir handoff_path
  feature_dir=$(dirname "$roadmap_path")
  handoff_path="$feature_dir/$phase_dir/handoff.md"
  validate_path_in_project "$handoff_path"

  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      mkdir -p "$(dirname "$handoff_path")"
      tmp_file=$(mktemp "${handoff_path}.XXXXXX")
      printf '%s\n' "$body" > "$tmp_file" && mv "$tmp_file" "$handoff_path"
      jq -n --arg path "$handoff_path" '{handoff: $path}'
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# write-review — persist a phase's design review to disk
# ============================================================================
# A review that exists only in the transcript of the session that produced it
# is not a review: the next session, the next reader and the PR that cites it
# all arrive after that transcript is gone. This verb is the one path that puts
# one on disk, at .aimi/reviews/<feature>-phase-<N>.md.
#
# Three deliberate differences from roadmap-write-handoff, its nearest sibling:
#
#   1. It requires no roadmap.json. A review is written ABOUT a phase, not
#      derived FROM one -- nothing here reads a stored phase -- so demanding a
#      roadmap would refuse the flat single-scope-context layout for no gain.
#      --feature and --phase are validated as a filename would be (the same two
#      helpers every roadmap verb uses), and that is the whole of what they are.
#   2. The body is written VERBATIM, not through rm_sanitize. The handoff's
#      fields are bullets re-read as structured contract text; a review is a
#      markdown document, and backticks and code fences are its content rather
#      than an injection vector to strip. "Write in one invocation, read in
#      another, get the same content back" is this verb's entire contract, and a
#      sanitizer would quietly break it for exactly the reviews worth keeping.
#   3. It takes no lock. mktemp-then-mv is what makes a concurrent reader see
#      one whole document or the other, never half of one -- the same reasoning
#      write_aimi_models_config states for models.json, and for the same reason:
#      nothing else writes this file.
#
# The path is confined by validate_path_in_project, the standing authority over
# every path arriving as a CLI ARGUMENT -- no second check is invented here.
cmd_write_review() {
  local feature="" phase_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase) shift; phase_id="${1:-}" ;;
      *)
        echo "Error: write-review: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature" "write-review"
  _roadmap_validate_phase_id "$phase_id" "write-review"

  local reviews_dir review_path
  reviews_dir="$AIMI_DIR/reviews"
  review_path="$reviews_dir/${feature}-phase-${phase_id}.md"
  validate_path_in_project "$review_path"

  local body
  body=$(cat)
  if [ -z "$body" ]; then
    # Refusing beats writing an empty file: a zero-byte review reads on disk
    # exactly like a review that was never written, and the caller who piped
    # nothing here would never learn which of the two happened.
    echo "Error: write-review: nothing was read from stdin — refusing to write an empty review" >&2
    exit 1
  fi

  mkdir -p "$reviews_dir"
  local tmp_file
  tmp_file=$(mktemp "${review_path}.XXXXXX")
  printf '%s\n' "$body" > "$tmp_file" && mv "$tmp_file" "$review_path"

  jq -n --arg path "$review_path" '{review: $path}'
}

# ============================================================================
# Contract Validation Subcommands (validate-contracts, roadmap-sweep)
# ============================================================================
# Cross-check a feature's roadmap.json creates[]/needs[] contracts: an unmet
# need (no phase in the needing phase's dependsOn closure creates it) and a
# duplicate creates (the same artifact identity declared by two or more
# phases). Artifact identity is a creates/needs entry's own `identity` field
# (see outline 01's shared scope-context reference); both verbs refuse a
# pre-2.0 roadmap outright rather than reporting on entries they cannot read.
#
# Both verbs are argument parsing here and one call into roadmap.py; the shared
# contract vocabulary they used to read through -- what an identity is, which
# characters it may not hold, what makes an entry suspicious -- moved there with
# them, so there is one definition and no bash copy left to drift from it.

# ============================================================================
# normalize-contracts — migrate stored creates/needs from 1.0 to 2.0
# ============================================================================
#
# 1.0 stores one entry as the string "identity (description)"; 2.0 stores
# {identity, description}. This verb is the only writer of that transition, and
# it exists rather than "just regenerate the roadmap" because roadmaps live
# outside this repository too -- a phases array is authored once, by hand or by
# /aimi:brainstorm, and re-deriving one loses every amendment made since.
#
# THE CORRECTNESS ARGUMENT IS THAT IT CALLS cv_identity, NOT A COPY OF IT.
# Every reader in this file has always computed the identity as
# `sub("\\(.*"; "")` then trim. A migration that re-derived that split with its
# own regex would be a fourth ruler, and any disagreement -- even on one entry
# in one roadmap -- silently repoints a downstream needs at nothing, because
# needs are matched against creates by exact byte equality. Reusing the
# function makes the migrated identity byte-identical to what the pre-migration
# readers saw, by construction rather than by testing.
#
# It therefore does NOT judge. A whitespace-bearing prose identity the current
# writer would refuse migrates unchanged; the reader gate is what surfaces it
# afterwards, in a diagnostic that names the entry. Repairing on the way past
# would silently change what a phase promises.
#
# nc_description is the exact inverse of cv_identity's cut: everything from
# the first "(" on, minus one leading "(" and one trailing ")". An entry with
# no "(" at all yields "" -- absent description, not null, so no reader needs a
# string-or-null branch.
cmd_normalize_contracts() {
  local feature=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature)
        feature="${2:-}"
        shift 2
        ;;
      *)
        echo "Error: normalize-contracts: unknown argument: $1" >&2
        echo "Usage: aimi-cli.sh normalize-contracts --feature <slug>" >&2
        exit 1
        ;;
    esac
  done

  _roadmap_validate_feature "$feature" "normalize-contracts"
  local roadmap_path
  roadmap_path=$(_roadmap_require normalize-contracts "$feature" " (run roadmap-init first)")

  check_python3
  # Bash holds the lock; roadmap.py does the whole read-modify-write inside it,
  # including the re-read that catches a file which turned malformed between
  # _roadmap_require's check and lock acquisition. One crossing, not four.
  local out
  out=$(
    (
      _lock "${roadmap_path}.lock"
      python3 "$(_aimi_roadmap_py)" normalize-contracts --roadmap "$roadmap_path"
    ) 200>"${roadmap_path}.lock"
  ) || exit $?
  printf '%s\n' "$out"
}

# ============================================================================
# verify-creates — prove a phase's creates[] exist in code, not in prose
# ============================================================================
#
# The whole rule lives in roadmap.py: the ':(glob)' pathspec, the 27-entry
# exclusion list, the endpoint-prefix strip, the TODO/FIXME marker rejection and
# the git exit-code ladder that separates "the phase did not build it" from "we
# could not look". It moved there because every one of those pathspecs carries
# ':', '*' and '(' -- characters a shell is free to reinterpret -- and the
# pathspec defect this verb was fixed for came from exactly that. An argument
# list has no quoting layer to get wrong.
#
# Verified against 24 captured cases before the jq was deleted: every documented
# identity kind, the doc and test exclusions, the marker rejection, an empty
# repository, and the three pathspec-magic forms. 72 of 72 field comparisons
# identical. tests/golden_from_jq.json keeps them.

cmd_verify_creates() {
  local feature="" phase_id="" dir=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --feature) shift; feature="${1:-}" ;;
      --phase)   shift; phase_id="${1:-}" ;;
      --dir)     shift; dir="${1:-}" ;;
      *)
        echo "Error: verify-creates: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_id" "verify-creates"

  local roadmap_path
  roadmap_path=$(_roadmap_require "verify-creates" "$feature")
  _roadmap_require_contracts "verify-creates" "$roadmap_path" "$feature"

  # No phase-exists check here: roadmap.py's verify_creates owns it and prints
  # the same bytes through die(msg, code=1). Keeping a bash copy meant two
  # readers of .phases[].id, and only one of them normalized the number.
  #
  # It follows that the phase check now runs AFTER the three guards below --
  # the --dir directory test, validate_path_in_project, and check_python3 --
  # so a bad --dir or a host with no python3 is reported first. That is the
  # intended order: those three are statements about this process's own
  # environment, and none of them can be answered by reading the roadmap.

  # --dir is the phase container's absolute path. It defaults to PROJECT_ROOT
  # rather than erroring, so the only --dir failure is a path that is not a
  # directory (or escapes the project).
  if [ -z "$dir" ]; then
    dir="$PROJECT_ROOT"
  fi
  if [ ! -d "$dir" ]; then
    echo "Error: verify-creates: --dir is not a directory: $dir" >&2
    exit 1
  fi
  dir=$(resolve_path "$dir")
  validate_path_in_project "$dir"

  check_python3
  python3 "$(_aimi_roadmap_py)" verify-creates \
    --roadmap "$roadmap_path" --phase "$phase_id" --dir "$dir"
}

cmd_validate_contracts() {
  local feature="" phase_id="" agent_mode=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --phase)
        shift; phase_id="${1:-}"
        ;;
      --agent-mode)
        agent_mode=true
        ;;
      -*)
        echo "Usage: aimi-cli.sh validate-contracts <feature> [--phase <id>] [--agent-mode]" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"
  if [ -n "$phase_id" ]; then
    _roadmap_validate_phase_id "$phase_id" "validate-contracts"
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "validate-contracts" "$feature")
  # Before the phase-exists check, so a pre-2.0 roadmap is named as such rather
  # than reported as a missing phase. The check itself now lives in roadmap.py's
  # validate_contracts, which prints the same bytes through die(msg, code=1) --
  # but this call must stay ABOVE the python3 hand-off for the same reason it
  # was written above the deleted jq block.
  _roadmap_require_contracts "validate-contracts" "$roadmap_path" "$feature"

  check_python3
  local phase_args=()
  [ -n "$phase_id" ] && phase_args=(--phase "$phase_id")
  local agent_args=()
  [ "$agent_mode" = "true" ] && agent_args=(--agent-mode)
  python3 "$(_aimi_roadmap_py)" validate-contracts \
    --roadmap "$roadmap_path" "${phase_args[@]}" "${agent_args[@]}"
}

# phase-overlap <feature> <phase-a> <phase-b>
# Stage 2 of the sibling-phase overlap guard (execute.md calls this only after
# its own stage-1 roadmap.json `areas` comparison finds a non-empty coarse
# intersection). Loads both phases' already-expanded tasks.json files, unions
# each phase's userStories[].implementation.files, and prints the sorted,
# deduplicated intersection as {"overlapping_files": [...]}.
cmd_phase_overlap() {
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
        exit 1
        ;;
      *)
        positional+=("$1")
        ;;
    esac
    shift
  done

  if [ "${#positional[@]}" -ne 3 ]; then
    echo "Usage: aimi-cli.sh phase-overlap <feature> <phase-a> <phase-b>" >&2
    exit 1
  fi

  local feature="${positional[0]}" phase_a="${positional[1]}" phase_b="${positional[2]}"

  _roadmap_validate_feature "$feature"
  _roadmap_validate_phase_id "$phase_a" "phase-overlap"
  _roadmap_validate_phase_id "$phase_b" "phase-overlap"

  if [ "$phase_a" = "$phase_b" ]; then
    echo "Error: phase-overlap: phase-a and phase-b must differ, got $phase_a twice" >&2
    exit 1
  fi

  local roadmap_path
  roadmap_path=$(_roadmap_require "phase-overlap" "$feature" " (run roadmap-init first)")

  # Phase directory resolution, the two tasks-file paths and the intersection
  # itself all live in roadmap.py -- the ids go over as the strings the caller
  # typed, because every refusal quotes them back and the filename is built from
  # them.
  check_python3
  python3 "$(_aimi_roadmap_py)" phase-overlap \
    --roadmap "$roadmap_path" --feature "$feature" --phase-a "$phase_a" --phase-b "$phase_b"
}

cmd_roadmap_sweep() {
  local feature=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh roadmap-sweep <feature>" >&2
        exit 1
        ;;
      *)
        feature="$1"
        ;;
    esac
    shift
  done

  _roadmap_validate_feature "$feature"

  local roadmap_path
  roadmap_path=$(_roadmap_require "roadmap-sweep" "$feature")
  # The one non-zero exit this advisory verb has. "Advisory" is about what it
  # does with a finding, not a licence to report a clean roadmap it never read.
  _roadmap_require_contracts "roadmap-sweep" "$roadmap_path" "$feature"

  # Single-pass, advisory-only computation: never exits non-zero for a roadmap
  # it could read. The drop-and-report rule, and why the drop must be reported
  # rather than silent, live with the code in roadmap.py's roadmap-sweep section.
  check_python3
  python3 "$(_aimi_roadmap_py)" sweep --roadmap "$roadmap_path"

  exit 0
}

# ============================================================================
# Payload Budget Estimation (advisory; Phase/Milestone Roadmap Layer)
# ============================================================================
#
# estimate-payload is purely advisory per the brainstorm's "budget as
# validator, not cutting criterion" decision: it never blocks planning and
# never trims content itself. Its only job is to print a clear warning with
# an actionable next step when a phase's context payload risks overflowing
# the sub-agent context window.

# Portable byte-size lookup (GNU stat -c%s, BSD/macOS stat -f%z fallback).
_file_size_bytes() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

# Resolve the effective payload budget in bytes plus the fraction it
# represents of the 400000-byte reference sub-agent window. --budget-bytes
# is a manual debug escape hatch (no caller passes it; plan.md's only
# caller uses the default); everything else defaults to 50% of the
# reference window.
# Usage: _estimate_payload_resolve_budget <flag_bytes>
# Prints "<budgetBytes> <budgetFraction>" (space-separated) on stdout.
_estimate_payload_resolve_budget() {
  local flag_bytes="$1"
  local reference_window=400000

  local bytes="" fraction=""

  if [ -n "$flag_bytes" ]; then
    bytes="$flag_bytes"
  else
    fraction="0.5"
  fi

  if [ -n "$bytes" ]; then
    fraction=$(jq -n --argjson b "$bytes" --argjson r "$reference_window" '$b / $r')
  else
    bytes=$(jq -n --argjson f "$fraction" --argjson r "$reference_window" '(($r * $f) | floor)')
  fi

  printf '%s %s\n' "$bytes" "$fraction"
}

# Sum the byte sizes of --outline (required) plus every repeated --research,
# --spec, and --prototype path, and report whether the total fits within the
# effective budget. Always exits 0 for valid input (advisory only); exits 1
# only on usage errors (missing --outline, a given path that does not exist).
cmd_estimate_payload() {
  local outline="" budget_bytes_flag=""
  local research_paths=() spec_paths=() prototype_paths=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --outline) shift; outline="${1:-}" ;;
      --research) shift; research_paths+=("${1:-}") ;;
      --spec) shift; spec_paths+=("${1:-}") ;;
      --prototype) shift; prototype_paths+=("${1:-}") ;;
      --budget-bytes) shift; budget_bytes_flag="${1:-}" ;;
      *)
        echo "Error: estimate-payload: unknown flag: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -z "$outline" ]; then
    echo "Error: estimate-payload: --outline <path> is required" >&2
    echo "Usage: aimi-cli.sh estimate-payload --outline <path> [--research <path>]... [--spec <path>]... [--prototype <path>]... [--budget-bytes <n>]" >&2
    exit 1
  fi
  if [ ! -f "$outline" ]; then
    echo "Error: estimate-payload: File not found: $outline" >&2
    exit 1
  fi

  local outline_bytes research_bytes=0 spec_bytes=0 prototype_bytes=0
  outline_bytes=$(_file_size_bytes "$outline")

  local p
  for p in "${research_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    research_bytes=$((research_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${spec_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    spec_bytes=$((spec_bytes + $(_file_size_bytes "$p")))
  done
  for p in "${prototype_paths[@]}"; do
    if [ ! -f "$p" ]; then
      echo "Error: estimate-payload: File not found: $p" >&2
      exit 1
    fi
    prototype_bytes=$((prototype_bytes + $(_file_size_bytes "$p")))
  done

  local total_bytes=$((outline_bytes + research_bytes + spec_bytes + prototype_bytes))

  local budget_line budget_bytes budget_fraction
  budget_line=$(_estimate_payload_resolve_budget "$budget_bytes_flag")
  budget_bytes=$(printf '%s' "$budget_line" | cut -d' ' -f1)
  budget_fraction=$(printf '%s' "$budget_line" | cut -d' ' -f2)

  local over_budget=false
  local warning="null"
  if [ "$total_bytes" -gt "$budget_bytes" ]; then
    over_budget=true
    warning='"Payload exceeds budget -- split the phase along a semantic seam in the roadmap, or trim research/prototype scope."'
  fi

  jq -n \
    --argjson total "$total_bytes" \
    --argjson outline "$outline_bytes" \
    --argjson research "$research_bytes" \
    --argjson specs "$spec_bytes" \
    --argjson prototypes "$prototype_bytes" \
    --argjson budgetBytes "$budget_bytes" \
    --argjson budgetFraction "$budget_fraction" \
    --argjson overBudget "$over_budget" \
    --argjson warning "$warning" \
    '{
      totalBytes: $total,
      breakdown: {outline: $outline, research: $research, specs: $specs, prototypes: $prototypes},
      budgetBytes: $budgetBytes,
      budgetFraction: $budgetFraction,
      overBudget: $overBudget,
      warning: $warning
    }'
}

# Usage: measure-command-file <path>
#
# Report one markdown file's structural size as JSON: how many bytes and lines
# it has, how many of those bytes are prose and how many are inside a fence,
# and how many fences there are — in total, and of those how many are ```bash.
#
#   {bytes, lines, prose_bytes, fence_bytes, bash_fence_bytes, fences, bash_fences}
#
# NOTHING HERE PARSES A FENCE. The parse is lib/extract-command-blocks.sh's
# extract_blocks() in its listing form — the same awk test-command-blocks.sh
# and capture-command-block-jq.sh already run — and this function only adds up
# what it reports. That reuse is the entire point of the verb rather than an
# implementation detail of it: the measurement this replaces was an awk written
# on the spot for a roadmap, never reviewed and never tested, and because it
# was anchored at the start of the line it silently skipped every INDENTED
# fence and reported 45 bash blocks in plan.md where the shared parser finds
# 50. A wrong number that becomes a planning input is worse than no number. A
# second fence parser in this tree is how that comes back, so there is not one.
#
# The file need not live under commands/. The measurement is structural and
# nothing in it reads the directory the path is in.
#
# `fences` counts TOP-LEVEL fences: a fence opened inside another fence is
# content of the outer one, the same rule that keeps a ```bash nested in
# execute.md's pseudo-code fence out of the extracted blocks. `bash_fences` is
# the subset whose info string is exactly `bash`, `bash_fence_bytes` likewise a
# subset of `fence_bytes`, and `prose_bytes + fence_bytes == bytes` always —
# including for a file whose last line carries no trailing newline, which the
# extractor's two tail flags exist to let this reconcile.
cmd_measure_command_file() {
  local file_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -*)
        echo "Usage: aimi-cli.sh measure-command-file <path>" >&2
        exit 1
        ;;
      *)
        if [ -n "$file_path" ]; then
          echo "Error: measure-command-file: one path at a time (unexpected: $1)" >&2
          exit 1
        fi
        file_path="$1"
        shift
        ;;
    esac
  done

  if [ -z "$file_path" ]; then
    echo "Usage: aimi-cli.sh measure-command-file <path>" >&2
    exit 1
  fi

  # Confinement FIRST, before this path is stat'd, opened or handed to awk.
  # It arrived as a CLI ARGUMENT, which makes validate_path_in_project the sole
  # authority over it — no second check is written beside it, here or anywhere.
  validate_path_in_project "$file_path"

  if [ ! -f "$file_path" ]; then
    echo "Error: measure-command-file: File not found: $file_path" >&2
    exit 1
  fi

  local blocks_lib
  blocks_lib=$(_aimi_blocks_lib)
  if [ ! -f "$blocks_lib" ]; then
    echo "Error: measure-command-file: block-extraction library not found: $blocks_lib" >&2
    exit 1
  fi
  # shellcheck source=lib/extract-command-blocks.sh
  . "$blocks_lib"

  local summary
  summary=$(extract_blocks "$file_path" | grep '^SUMMARY' | head -1) || summary=""
  if [ -z "$summary" ]; then
    echo "Error: measure-command-file: the extractor reported no summary for $file_path" >&2
    exit 1
  fi

  # Nine integers separated by spaces, so the default IFS reads them and this
  # function reassigns nothing. That is the extractor's side of the same rule
  # test_no_delimiter_survives_anywhere pins for the models readers: a record
  # crossing a process boundary is a string, and a delimiter that any field
  # could contain is a truncation waiting to happen. Numbers cannot contain a
  # space; a markdown heading can, which is why the BLOCK lines this ignores
  # are tab-separated and this one is not.
  local tag bytes lines prose fence bash_fence fences bash_fences last_fence last_bash
  read -r tag bytes lines prose fence bash_fence fences bash_fences \
    last_fence last_bash <<< "$summary"

  # awk charges every record one newline, so a file whose last line carries
  # none measures exactly one byte over. Reconcile against the real size and
  # put the difference back in the bucket that last line was counted in, so
  # prose_bytes + fence_bytes == bytes survives a file with no final newline
  # rather than reporting a partition that does not add up.
  local real_bytes residue
  real_bytes=$(_file_size_bytes "$file_path")
  residue=$((real_bytes - bytes))
  if [ "$residue" -ne 0 ] && [ "$last_fence" = "1" ]; then
    fence=$((fence + residue))
    [ "$last_bash" = "1" ] && bash_fence=$((bash_fence + residue))
  fi
  prose=$((real_bytes - fence))

  jq -n \
    --argjson bytes "$real_bytes" \
    --argjson lines "$lines" \
    --argjson prose "$prose" \
    --argjson fence "$fence" \
    --argjson bashFence "$bash_fence" \
    --argjson fences "$fences" \
    --argjson bashFences "$bash_fences" \
    '{
      bytes: $bytes,
      lines: $lines,
      prose_bytes: $prose,
      fence_bytes: $fence,
      bash_fence_bytes: $bashFence,
      fences: $fences,
      bash_fences: $bashFences
    }'
}

# Display help
cmd_help() {
  cat << 'EOF'
aimi-cli.sh - Deterministic task file operations for Aimi

USAGE:
    aimi-cli.sh <command> [args]

COMMANDS:
    init-session              Initialize execution session, save state
    find-tasks                Find most recent tasks file
    status [--counts-only] [--tasks-file <path>]
                              Get status summary as JSON
                              --counts-only  Return aggregate counts without userStories array
    metadata [--tasks-file <path>]
                              Get metadata only
    verification-report [--tasks-file <path>]
                              Visual stories (id/project/url) plus the malformed-verification
                              partition (repairable/unrepairable). Defaults to get_tasks_file.
    project-groups [--tasks-file <path>]
                              {groups, projectStoryCount}: sorted-unique project groups this
                              tasks file participates in, plus the count of stories carrying a
                              non-null project. Validates each group and refuses (all offenders
                              named) on an invalid one. Defaults to get_tasks_file.
    next-story                Get next pending story, save to state
    current-story             Get currently active story from state
                              Refuses --tasks-file: answers from session state, not a file.
    list-ready [--brief] [--tasks-file <path>]
                              List stories ready to execute (dependency-aware)
                              --brief  Return only {id, title, priority, dependsOn} per story
    mark-in-progress <id> [--tasks-file <path>]
                              Mark story as in_progress (returns {id, status} JSON)
    mark-complete <id> [--tasks-file <path>]
                              Mark story as completed (returns {id, status} JSON)
    mark-failed <id> [notes] [--tasks-file <path>]
                              Mark story as failed (returns {id, status, notes} JSON)
    mark-skipped <id> [--tasks-file <path>]
                              Mark story as skipped (returns {id, status} JSON)
    set-execution-mode <container|inline> [--tasks-file <path>]
                              Persist a --container/--inline override onto metadata.execution
                              (returns {execution} JSON). Refuses with non-zero exit on a
                              phase-scoped tasks file (metadata.phase present).
    count-pending [--tasks-file <path>]
                              Count pending stories
    validate-deps [--tasks-file <path>]
                              Validate dependency graph (no cycles, no missing refs)
    validate-stories [--tasks-file <path>]
                              Validate story content (length, suspicious patterns)
    normalize-verification <file>
                              Rewrite any story whose verification is a bare string S
                              into {strategy: S, status: "pending", url: null, expect: null}.
                              Already-object verifications are left unchanged.
                              Writes atomically (tmp + mv). Exits 0 on success.
    normalize-status <file>   Default any story missing the status field to "pending".
                              Already-set status values are preserved (uses //= operator).
                              Writes atomically (tmp + mv). Exits 0 on success.
                              Reports count of stories with status field after heal.
    validate-ids [--tasks-file <path>]
                              Validate all story IDs match US-NNN format
    gate-pass <id> [--option 'value'] [--tasks-file <path>]
                              Pass a gate on a story; optionally store selected option
    gate-fail <id> [--tasks-file <path>]
                              Fail a gate on a story
    update-field <id> <field.path> <value> [--tasks-file <path>]
                              Update a nested field on a story (e.g., verification.status passed).
                              <field.path> must be a dotted chain of identifier segments
                              ([A-Za-z_][A-Za-z0-9_]* joined by '.'); anything else is refused.
    validate-waves [--tasks-file <path>]
                              Compute waves from dependsOn, compare to stored wave, report mismatches
    validate-tasks [--tasks-file <path>]
                              Validate tasks file citation fields (schemaVersion guard, no checks yet)
    cascade-skip <id> [--tasks-file <path>]
                              Skip all stories depending on failed story
    reset-orphaned [--tasks-file <path>]
                              Reset all in_progress stories to failed
    get-branch                Get branchName from metadata
                              Refuses --tasks-file: answers from session state, not a file.
    get-story <id> [--tasks-file <path>]
                              Get full story object by ID (read-only)
    get-story-context <id> [--tasks-file <path>]
                              Get story slice + metadata + skills[] + designContext + skillsDropped[] as JSON
                              (for subagent self-brief). Output keys: story, metadata, skills,
                              designContext. skills[] contains {name, path, content} per
                              declared skill. designContext contains {decisions, bundleGuidance}.
    verify-probe <id> [--tasks-file <path>] [--previous-file <path>]
                              Run a story's implementation.verify ONE ASSERTION AT A TIME and
                              report which ones already pass. Output: a JSON array of
                              {segment, exit, discriminates, unsatisfiable}; discriminates is
                              false for an assertion that passed, i.e. one that does not tell
                              the before-state from the after-state. --previous-file names a
                              prior run's own output (e.g. the pre-implementation call to this
                              same verb); a segment non-zero in both runs gets
                              unsatisfiable:true plus a note pointing at the harness, not the
                              code -- omitted or unmatched, unsatisfiable is false. Segments
                              run in the CALLER's directory, in order, carrying the verify's
                              own variable assignments; `set` lines, comments and assignments
                              are not reported. An absent or empty verify is [] at exit 0.
    list-known-gaps [--feature <name>] [--since <YYYY-MM-DD>]
                              Read every planning defect a previous executor recorded in
                              .aimi/known-gaps/ and print them as a JSON array of
                              {date, storyId, feature, text, file}. Needs no frontmatter:
                              a `KNOWN-GAP:` line, a `KNOWN-GAP (US-NNN):` line and a file
                              of bare prose all parse, and EVERY file yields at least one
                              entry. feature comes from the file name's slug, else from the
                              tasks file planned on the same date, else null -- never
                              dropped. Both filters are exact; --since drops a dated-less
                              entry.
    get-state                 Get all state files as JSON
    detect-default-branch [--project <path>]
                              Detect and cache the repository's default branch
    detect-parent-branch <branch> [--project <path>]
                              Detect branch's parent (base) branch by token-aware
                              git log decoration parsing + git merge-base verification.
                              Output: {branch, base, verified, source
                              ("decoration"|"ambiguous-decoration"|"default-branch"),
                              candidates}. Falls back to the default branch
                              (unverified) when no decoration candidate survives
                              normalization or merge-base check, or when two or
                              more candidates verify at the same nearest commit
                              (source "ambiguous-decoration", candidates lists the
                              tied names instead of asserting a winner).
    detect-forge [--project <path>]
                              Classify the active git remote's hostname into
                              github|gitlab|gitea|unknown (exact-or-subdomain,
                              port-aware). Output: {forge, host, remote,
                              remoteUrl, source ("override"|"remote"|
                              "no-remote"|"ambiguous-remotes")}. Set
                              AIMI_FORGE_TYPE=github|gitlab|gitea to override
                              detection entirely (source=override, no git
                              remote read runs); any other value exits 1.
                              Never cached -- re-derived on every invocation.
    forge-auth-status [--project <path>]
                              Report whether the active forge session is authenticated
                              and which account it is acting as. Output:
                              {status ("found"|"error"), data, message}. data (when
                              found) carries {forge, host, authenticated, account,
                              identityRequested, identityHonored}. authenticated:false
                              with status="found" is a confirmed logged-out session;
                              status="error" means the check itself could not run --
                              the binary the DETECTED forge needs is missing (gh,
                              glab or tea), or it ran and could not answer, or the
                              forge has no adapter at all. Set
                              AIMI_FORGE_IDENTITY=<login> (env var only, never a flag)
                              to compare against the active account -- this does not
                              switch accounts.
    forge-account-select (--check | --record <login> | --record-active | --reselect) [--project <path>]
                              Record, read back and revoke THIS repository's
                              remembered forge account -- the ask-once store.
                              Exactly one mode is required; giving two, or
                              none, exits 1 naming the valid modes. Reselect
                              is a FLAG on this verb, never a second verb.
                              --check reads the answer back and decides:
                              {action: "check", decision ("ask"|"skip"),
                              basis, stored, store, ...} plus every field of
                              the internal divergence verdict (forge, host,
                              activeAccount, accounts, identity, match).
                              basis is identity_override (AIMI_FORGE_IDENTITY
                              names the account, so the question is moot),
                              no_repository, no_host, answer_recorded, or the
                              divergence verdict's own basis. --check WRITES
                              NOTHING -- not the store, not the config
                              directory -- which is what keeps an agent-mode
                              or CI auto-answer applied-but-not-persisted, so
                              one CI run cannot permanently answer for every
                              human afterwards.
                              --record <login> remembers a named account;
                              --record-active remembers "always use whichever
                              account is active" as a first-class answer,
                              distinct from having no answer. An empty
                              --record value is refused, since it would be
                              indistinguishable from absent.
                              --reselect forgets this repository's answer so
                              the next --check asks again; deleting the store
                              file by hand does the same, because the answer
                              is the ONLY state -- there is no companion
                              marker to also delete.
                              The store is one JSON document per repository
                              (keyed on the repository's git common dir, so
                              every worktree shares it) holding one entry per
                              forge host. Every write is read-merge-write, so
                              recording or revoking one host never touches
                              another's entry.
                              No credential-shaped flag exists on this verb,
                              by design -- an acting identity is env-var-only
                              (AIMI_FORGE_IDENTITY / GH_TOKEN), never a flag.
    forge-repo-info [--project <path>]
                              Resolve the active forge's owner/repo via a single
                              forge-CLI call -- `gh repo view` on github, `glab
                              repo view -F json` on gitlab -- falling back to
                              parsing the git remote URL whenever that CLI is
                              unavailable or the forge has no such tier. gitea
                              always takes the fallback, by decision: tea has no
                              "show THIS repository as JSON" command to call.
                              Output: {status ("found"|"not_found"), data,
                              message}. data (when found) carries {forge, host,
                              owner, repo, nameWithOwner,
                              source ("gh"|"glab"|"local-parse")}.
    forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]
                              Field-selectable PR lookup with a three-way
                              found|not_found|error status, fixing the
                              exit-code conflation `gh pr view --json url`
                              carries today (a broken token reads as "no PR
                              yet"). Output: {status, pr, unsupported_fields,
                              message}. --include is a comma-separated
                              subset of: number, url, title, body, state,
                              headRefName, baseRefName, files, isDraft,
                              mergeable -- defaults to the portable core
                              (excludes files/isDraft/mergeable) when
                              omitted. Any other name exits 1. github,
                              gitlab and gitea each have an adapter; only
                              `unknown`, or a missing gh/glab/tea binary,
                              degrades to status=error with no stderr
                              output.
    forge-pr-create --title <t> --base <branch> --head <branch> [--body <text>] [--project <path>]
                              Write verb -- shells gh pr create (no --json
                              flag exists on it; the URL is captured and the
                              number is derived via a structured forge-pr-
                              view re-read, never a regex on the URL).
                              Idempotent: checks forge-pr-view for an
                              existing open PR on --head first and reports
                              it as status "unchanged" instead of opening a
                              duplicate. Output: {status: "created"|
                              "unchanged"|"degraded", data: {url, number},
                              message} (forge-contract.md's Write-Verb
                              Status Convention -- the same envelope
                              forge-pr-edit and forge-issue-create emit).
                              Unlike forge-issue-create, a missing
                              gh binary or an unsupported forge prints the
                              manual git-push + PR-creation instructions to
                              stderr (MANDATORY-PRINT degrade mode) and
                              EXITS NON-ZERO -- a hard failure, so a
                              caller's own per-repository failure isolation
                              can react. github, gitlab and gitea each have
                              an adapter. Identity, when needed, is read from
                              an env var (e.g. AIMI_FORGE_IDENTITY /
                              GH_TOKEN), never a flag.
    forge-pr-edit --number <n> [--title <text>] [--body <text>] [--project <path>]
                              Write verb -- shells gh pr edit <number> with
                              --title and/or --body, then re-reads the PR via
                              forge-pr-view to confirm and report
                              {url, number} under the same write envelope
                              forge-pr-create emits. A successful edit reports
                              status "unchanged": it mutates an existing
                              number and mints no new identifier. --title and
                              --body are each optional but at least one is
                              required, and each is sent ONLY when supplied --
                              a title-only edit passes no --body, because an
                              empty one would blank the description. --body ""
                              is honoured as a deliberate clear; --title "" is
                              refused, since no forge stores an empty title.
                              Same guards, degrade contract, and
                              non-zero-exit-on-failure as forge-pr-create.
                              github, gitlab and gitea each have an adapter
                              (glab mr update -t/-d, tea pulls edit -t/-d).
    forge-pr-merge --pr <branch-or-number> --style <merge|squash|rebase> [--project <path>]
                              Write verb -- resolves the PR/MR's
                              {number, url, state} via an in-process
                              forge-pr-view preflight, then shells gh pr
                              merge/glab mr merge/tea pulls merge. --pr and
                              --style are BOTH REQUIRED; --style is
                              validated against the closed enum
                              {merge, squash, rebase} (never gitea's own
                              fourth rebase-merge style, which this verb
                              deliberately does not expose). Output:
                              {status: "unchanged"|"degraded", data:
                              {url, number}, message} -- "created" is
                              structurally unreachable (a merge mints no new
                              identifier) and is never emitted. An
                              already-merged or GitLab-locked PR/MR
                              short-circuits to "unchanged" with no merge
                              attempted; a closed-but-never-merged one
                              degrades before any merge call runs. A
                              successful merge reuses the preflight's own
                              {url, number} rather than re-reading. Same
                              guards, degrade contract, and
                              non-zero-exit-on-failure as forge-pr-create --
                              a missing gh/glab/tea binary or an unsupported
                              forge prints manual merge-it-yourself
                              instructions to stderr (MANDATORY-PRINT
                              degrade mode) and EXITS NON-ZERO. github,
                              gitlab and gitea each have an adapter (glab mr
                              merge -y [-s|-r], tea pulls merge --style,
                              --style ALWAYS passed on the gitea call). No
                              conditional/auto-merge and no branch-deletion
                              flag on any forge. Identity, when needed, is
                              read from an env var, never a flag.
    forge-issue-view (--number <n> | --url <issue-url>) [--project <path>]
                              Read verb -- shells gh issue view, normalized to
                              {status: "found"|"not_found"|"error", data, message}
                              (forge-contract.md's Three-Way Status Convention).
                              data carries {number, url, title, body, state,
                              labels, comments, unsupported_fields, raw} on
                              found. QUIET degrade mode: a missing or
                              unauthenticated forge CLI yields status "error"
                              with no stderr output. github, gitlab and gitea
                              each have an adapter.
    forge-issue-create --title <t> --body <b> [--project <path>]
                              Write verb -- shells gh issue create (no --json
                              flag exists on it; the URL/number are captured
                              and derived here). Output: the same write
                              envelope the two PR write verbs emit --
                              {status: "created"|"degraded", data: {url,
                              number}, message} (forge-contract.md's
                              Write-Verb Status Convention; "unchanged"
                              never occurs here, since this verb only ever
                              mints a new issue). A
                              degraded/failed create is NEVER a hard failure
                              (exit stays 0) -- it prints a manual "create
                              this yourself" instruction to stderr
                              (MANDATORY-PRINT degrade mode) and lets the
                              caller branch on status instead. github, gitlab
                              and gitea each have an adapter.
    forge-pr-review-threads --pr <number> [--owner <owner> --repo <repo>] [--all] [--project <path>]
                              Read verb -- ports get-pr-comments' reviewThreads
                              GraphQL query verbatim; owner, repo and the PR
                              number are bound via gh api graphql's own -f/-F
                              flags, never interpolated into the query text.
                              Output: {status: "found"|"not_found"|"error",
                              data, message} (forge-contract.md's Three-Way
                              Status Convention). data carries {pr: {number,
                              title, url}, threads: [...], unsupported_fields}.
                              Each thread carries {id, isResolved, isOutdated,
                              isCollapsed, path, line, startLine, diffSide,
                              comments: {totalCount, nodes}}. Without --all,
                              threads is filtered to isResolved==false and
                              isOutdated==false, matching get-pr-comments'
                              existing filter; --all returns every thread.
                              Owner/repo auto-detected via forge-repo-info
                              when not both supplied. QUIET degrade mode: a
                              missing forge CLI, unsupported forge, or CLI
                              failure yields status=error with no stderr.
                              github, gitlab and gitea each have an adapter.
    forge-resolve-review-thread --thread-id <id> [--project <path>]
                              Write verb -- ports resolve-pr-thread's
                              resolveReviewThread GraphQL mutation verbatim;
                              the thread id is bound via gh api graphql's own
                              -f flag, never interpolated. Output: {status:
                              "found"|"error", data, message}. status="found"
                              covers both a successful resolve
                              (data.resolved=true) and a confirmed-invalid
                              thread id (data.resolved=false, the mutation
                              ran) -- both exit 0, no stderr. status="error"
                              means gh could not attempt the mutation at all
                              (missing binary, unsupported forge, or a
                              genuine gh failure) -- MANDATORY-PRINT: prints a
                              manual "resolve it yourself in the PR's Files
                              changed tab" instruction to stderr and exits
                              non-zero, since there is no gh subcommand or
                              REST fallback for resolving a review thread.
                              github, gitlab and gitea each have an adapter.
    detect-interactivity [--non-interactive]
                              Print resolved interactivity mode (picker|agent)
                              Returns picker by default; returns agent only when
                              --non-interactive is passed, AIMI_AGENT_MODE=true, or CI=true
    list-models               List available models for the current host as a JSON array.
                              Claude Code: ["opus","sonnet","haiku"].
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              Entries are normalized (ends trimmed, empties dropped), so
                              every id offered here is one resolve-models accepts.
                              stdout is always a valid JSON array; warnings go to stderr.
    resolve-models            Resolve configured model for each agent category.
                              Reads ~/.config/aimi/models.json (schema v2.0) and emits
                              a single-line JSON object with keys research, review,
                              design, workflow, executor.
                              Schema v2.0 shape: categories.<host>.<category> = model id.
                              Unconfigured or fallback entries use the literal "inherit".
                              v1.0 configs (top-level .models key or schemaVersion != "2.0")
                              are rejected with a stderr warning; all-inherit returned.
                              Warnings go to stderr; stdout is always valid JSON.
    get-current-models        Emit current per-category model assignments for the
                              active host as a JSON object with keys research, review,
                              design, workflow, executor. Unset entries emit JSON null
                              (not the string "inherit" returned by resolve-models) so
                              picker UIs can pre-select sensible defaults and distinguish
                              "not configured" from an explicit "inherit" override.
                              v1.0 configs rejected identically to resolve-models.
    detect-models [--research <model>] [--review <model>] [--design <model>] [--workflow <model>] [--executor <model>]
                              Detect available models on the current host and write
                              ~/.config/aimi/models.json (schema v2.0).
                              Claude Code: fixed set (opus, sonnet, haiku).
                              OpenCode: reads `opencode models`; falls back to built-in
                              Anthropic list with one warning when opencode is absent.
                              Category flags (--research/--review/--design/--workflow/--executor):
                              non-interactive write mode — writes the given
                              category-to-model assignments directly. Preserves the
                              other host's categories sub-table when a file already exists.
                              All five category flags must be supplied together.
                              Each value is normalized (ends trimmed) before it is
                              written; an id that is not valid for the host draws a
                              stderr warning and is still written (validation happens at
                              read, in resolve-models), while a value that is non-empty
                              but normalizes to empty is an error and writes nothing.
                              Interactive (stdin TTY, no flags): prompts per category,
                              validates answer against available-model list.
                              Non-interactive (no flags, stdin not TTY): default mapping
                              (research=fast/haiku, review=powerful/opus,
                              design+workflow+executor=balanced/sonnet).
                              Emits the written JSON on stdout.
    models-prompt-check       Check whether the model-selection prompt should be shown.
                              Per-host decision:
                              - prompt when the config file is missing entirely (always
                                re-trigger after deletion, regardless of any marker)
                              - skip when the current host (claudeCode or opencode) has
                                at least one non-null category
                              - skip when the file is present, the current host is
                                unconfigured, AND the per-host dismissal marker exists
                                (~/.config/aimi/models-prompt-seen-<host>)
                              - prompt otherwise (file present, host unconfigured, no
                                marker) — including v1.0 configs and empty/malformed files
    models-prompt-dismiss     Atomically create the per-host first-run prompt marker file
                              (~/.config/aimi/models-prompt-seen-<host> where <host> is
                              claudeCode or opencode based on CLAUDECODE). Idempotent.
                              Run after the user responds to the prompt on this host
                              (regardless of their choice) so the prompt is not re-shown
                              when the host stays unconfigured. Re-deleting models.json
                              still re-triggers the prompt — the marker only suppresses
                              when the file exists but the host has no config.
    setup-branch <name> --default-branch <branch> [--project <path>]
                              Create or checkout branch with deterministic logic
    resolve-base-branch <name> --default-branch <branch> [--base <branch>] [--project <path>]
                              Decide what branch a new branch or container should be cut
                              from -- no checkout is performed. Prints a single JSON object:
                              {"base","reason","currentBranch","defaultBranch","promptNeeded"}.
                              reason is exactly one of: explicit-base, target-exists,
                              stacked-on-current, default-branch, detached-head.
                              base prefers the origin/<name> remote-tracking ref when it
                              exists, falling back to the bare local name otherwise --
                              except for stacked-on-current, which always keeps the bare
                              local ref, since stacking exists to inherit the local tip.
                              --base "" is treated exactly like an omitted --base, so a
                              caller may pass an unset variable through unconditionally.
                              promptNeeded is true only when the target does not exist
                              (locally or on origin), the current branch is not the
                              default branch, and it is not merged into origin/<default>.
    clear-state               Clear all state files
    version                   Print the plugin version
    check-version [--quiet] [--fix]
                              Check if stored CLI version matches latest installed
                              --quiet  Suppress stderr warnings
                              --fix    Auto-update cli-path on stale detection (exits 0)
    cleanup-versions          Remove old cached plugin versions, keep latest only
    list-archivable           List task files where all stories are completed/skipped (JSON array)
    archive-task <path>       Move completed task file (and linked brainstorm) to .aimi/archive/
    research-lookup [--ignore-missing-cited-paths] <path>
                              Check whether a research .md file is fresh relative to cited source
                              paths listed under its '## File References' h2 bullet section.
                              Freshness: research mtime >= newest mtime of cited source paths.
                              Fresh: prints the resolved research path, exits 0.
                              Stale/undecidable: prints nothing, exits 1.
                              Cited path not found -> stale + stderr warning.
                              --ignore-missing-cited-paths: a missing cited path logs a warning
                                but does NOT mark the file stale (mtime staleness is unaffected).
                                Use when cited sources include to-be-created files.
                              Absolute or outside-root path -> rejected (exit 1).
                              Flag accepted in either position relative to the path arg.
    extract-sections <file> --anchors "<titles>"
                              Print only the requested '## '/'### ' sections of a
                              research .md file, concatenated verbatim in request order.
                              Each section spans its matching heading up to the next
                              heading of the same-or-higher level (or EOF) -- an h2
                              anchor includes nested h3s and stops at the next h2/h1;
                              an h3 anchor stops at the next h3/h2/h1.
                              --anchors accepts comma- or newline-separated heading
                              titles; matching is case-insensitive on heading text.
                              An anchor with no matching heading is skipped (not an
                              error); anchors matching nothing -> empty output, exit 0.
                              Path confinement mirrors research-lookup (resolve_path +
                              validate_path_in_project); missing file or missing
                              <file>/--anchors arg -> error/usage on stderr, exit 1.
    research-gc               Delete orphaned .aimi/research/*.md files not referenced by any
                              active .aimi/tasks/*.json metadata.researchPaths or any
                              .aimi/brainstorms/*.md frontmatter researchPaths, AND older than
                              30 days. .aimi/archive is ignored. Silent when nothing cleaned.
    detect-design-bundle [--root <path>] [--all] [--json]
                              Detect a Claude Design handoff bundle. --root may
                              point at a bundle directory directly, or at a
                              parent dir whose immediate children include bundle
                              dirs (depth-1 scan in that case). Returns JSON
                              {path,readme,chats[],prototypes[],hasReact,
                              hasTailwind,businessSpec,designSpec} or null when
                              no bundle found.
                              --root   Scan <path> (bundle or parent) instead of CWD
                              --all    Return all matching bundles as JSON array
                              --json   Alias; output is always JSON
    bundle-prototype-status --bundle <path> --topic <slug> [--force]
                              Check whether a bundle prototype needs (re-)generation.
                              Returns JSON with keys: needs_generation (bool),
                              view_list (array of {name,source_section}),
                              view_source ('designSpec'|'businessSpec'|'none'),
                              output_path, sidecar_path.
                              view_list is extracted from DesignSpec § 4 first,
                              falling back to BusinessSpec § 5 then § 6.
                              --force  Always set needs_generation to true
    bundle-prototype-finalize --topic <slug> --bundle-hash <hex>
                              --design-spec-hash <hex> --business-spec-hash <hex>
                              --view-list <json> --source-command <brainstorm|plan>
                              Write the bundle-prototype sidecar atomically.
                              Sidecar path: .aimi/brainstorms/prototypes/<slug>-bundle-sidecar.json
                              chmod 600 applied; writes are atomic (tmp + mv).
                              --source-command must be exactly 'brainstorm' or 'plan'.
    story-merge --staging-dir <dir> --output <path>
                              [--split legacy|full-stack] [--agent-mode]
                              [--phase-aware]
                              [--foundation <NN>|<project>:NN]...
                              Consolidate per-story staging *.json files into a
                              validated tasks.json. Steps: glob+validate JSON,
                              assign US-NNN IDs by lex order, remap outline:NN
                              tokens in dependsOn, DAG cycle detection, wave
                              computation, Rule 22 mock-sync AC routing, Phase
                              3.1 inventory verdict check, Phase 4.1 coverage
                              ratio (ac_anchors >= floor(proto_elements * 0.6)),
                              Phase 4.2 orphan-symbol smell (heuristic scan of
                              sibling-story prose for symbols a story introduces
                              that no other story references; not codebase
                              dead-code detection — always a warning, never a
                              hard block; skipped for single-story merges).
                              --split full-stack additionally detects
                              cross-file-dep-dropped smells: a dependsOn edge
                              that crosses an output-file boundary (a repo
                              boundary on the PROJECT axis, the
                              frontend/backend boundary on the SIDE axis) is
                              still dropped (each file's graph stays
                              self-contained) but is now surfaced via one
                              aggregated stderr banner plus a
                              metadata.smellWarnings entry per affected story
                              in EVERY output file the split produced (keyed by
                              .project on the PROJECT axis, .side on the SIDE
                              axis).
                              Writes atomically via _lock (tmp+mv). Deletes
                              staging dir on success; preserves on error.
                              --split full-stack picks its axis by counting
                              distinct normalized .project values (trim, strip
                              one trailing slash, blank/absent = null).
                              >= 2 -> PROJECT axis (multi-repo): one output
                              file per project, <base>-<project-slug>-tasks.json,
                              no frontend/backend decision at all; each file
                              carries metadata.splitGroup + its own branchName.
                              A multi-repo plan requires EVERY story to carry a
                              project: once any story is tagged, a project-less
                              story is refused (no files written) rather than
                              routed anywhere. A story belonging to the root
                              repository says so explicitly with "." — an absent
                              project is not the root, it is unrouteable.
                              < 2 -> SIDE axis (single-repo/monorepo, incl. no
                              .project at all): two output files,
                              <base>-frontend-tasks.json and
                              <base>-backend-tasks.json, each story classified
                              by its own file-pattern/title heuristic verdict.
                              Both axes assign unique IDs, rebuild dependsOn,
                              and recompute wave numbers per file.
                              Derived slugs/paths/branch names are length-bounded
                              and REFUSED (never truncated) when over: slug 64,
                              output basename 248, full path 4000, branchName
                              100. Truncation would manufacture a basename
                              collision between two distinct long project values.
                              --phase-aware (only meaningful with --split
                              full-stack): strip one trailing "-tasks" segment
                              from the --output basename before deriving the
                              split basenames. Pure string manipulation on the
                              basename, independent of the axis: on SIDE it
                              yields <base>-frontend-tasks.json /
                              <base>-backend-tasks.json, on PROJECT it yields
                              <base>-<project-slug>-tasks.json — in both cases
                              with a single "tasks" segment instead of the
                              doubled legacy form. Requires an --output basename
                              ending in "-tasks" with at least one character
                              before it (the phase-scoped form, e.g.
                              "<feature>-phase-<N>-tasks.json"); anything else
                              (e.g. "tasks.json") is refused up front, because
                              the strip would otherwise leave an empty or
                              "-"-leading basename. Omitted: unchanged legacy
                              derivation (double "-tasks-frontend-tasks.json").
                              --foundation <NN>|<project>:NN, REPEATABLE.
                              NN is a two-digit 1-based outline position
                              (resolved against the same outline-position map as
                              outline:NN, not a literal staging-filename digit).
                              Appends that story's assigned US-NNN to the
                              dependsOn of every OTHER story sharing its OWN
                              normalized .project group, deduplicated, after the
                              outline:NN remap and before cycle detection and
                              wave computation, so injected edges participate in
                              both. Injection is PER PROJECT GROUP: a group no
                              --foundation value names receives no injected edge
                              at all — a normal, silent outcome, whether it has
                              no foundation story or its own Foundation Gate
                              resolved Skip. A bare NN is accepted only when it
                              is the SOLE --foundation value, whatever project
                              it resolves to; two or more values require EVERY
                              one of them to use the qualified <project>:NN
                              form, since a bare value alongside another names
                              no project. The qualifier is a CHECKSUM, not a
                              second source of truth: routing always comes from
                              the resolved story's own .project, and a stated
                              project disagreeing with it refuses the merge
                              before any write, naming both. Also refused before
                              any write: an index present among no staging file,
                              a foundation whose own dependsOn is non-empty, and
                              two values resolving into the same project group.
                              On the PROJECT axis droppedDeps[].foundationEdge
                              is true only for a dropped edge targeting a
                              --foundation story in ANOTHER group — necessarily
                              hand-authored, since an injected edge never leaves
                              its own group and so is never dropped — with its
                              own stderr note separate from the ordinary
                              drop-count banner. The SIDE axis emits no
                              foundationEdge field.
                              --agent-mode demotes Phase 3.1 and Phase 4.1
                              hard rejects to warnings and proceeds.
    split-detect [--dir <phase-dir>]
                              Read side of metadata.splitGroup: decide whether
                              the tasks files in scope form ONE split group that
                              must execute together, and report which members
                              still have pending work. A query, never a gate —
                              every outcome, including "single" and "none",
                              exits 0; non-zero is a real error (bad argument,
                              unreadable --dir).
                              Scope. Without --dir: FLAT — *-tasks.json whose
                              parent directory is .aimi/tasks itself, depth 1
                              only. The depth restriction is load-bearing:
                              find-tasks-all globs depth 1-3, which includes
                              phase directories, so without it a phase's split
                              files are captured by the flat flow and run as a
                              flat split — the phase never gets claimed and
                              nothing merges into the phase branch. With --dir:
                              that directory's *-tasks.json, minus the phase's
                              own <feature>-phase-<N>-tasks.json.
                              Algorithm. The anchor is the NEWEST candidate by
                              mtime, not the first marker-carrying file in mtime
                              order — the latter let a stale marked split from a
                              past feature preempt today's plan whenever today's
                              files carried no marker. If the anchor carries a
                              well-formed metadata.splitGroup (total a number,
                              siblings an array), siblings resolve BY BASENAME
                              against the anchor's own directory (which renders
                              a traversal-shaped sibling entry inert) and the
                              resolved count must equal total and be >= 2.
                              A group whose members are ALL completed is dropped
                              whole from the pool and the search repeats, so a
                              finished stale split cannot route today's real work
                              to a single-file fallback. A marker present but
                              failing validation degrades and is terminal — it
                              does NOT fall through to the legacy pair, because
                              any -frontend-/-backend-tasks.json beside a
                              project-split marker is stale work. When the newest
                              candidate carries no marker, the legacy
                              -frontend-tasks.json/-backend-tasks.json pair rule
                              is tried over the pool (counterpart must be in the
                              pool, not merely on disk). Otherwise: single.
                              Pending is (.status // "pending") != "completed" —
                              one definition for every count reported, so an
                              in_progress story is pending everywhere.
                              Output. One JSON object: {mode: "project-split"|
                              "paired-split"|"single"|"none", anchor, members:
                              [{path,project,branchName,storyCount,pendingCount,
                              active}], activeCount, total, degradedReason}.
                              degradedReason explains any fall-back so the caller
                              can report it without re-deriving why.
    verify-creates --feature <slug> --phase <id> [--dir <container-path>]
                              Prove a phase's declared creates[] exist in code.
                              Prints a JSON array, one object per creates[]
                              entry: {identity, status, method, evidence,
                              gitStatus}. status is verified|missing|error;
                              method is "path" (matched a tracked path),
                              "text" (matched tracked source) or null.
                              --dir is the phase container's absolute path;
                              it defaults to the project root.
                              A query, never a gate — producing a verdict array
                              exits 0, including one where every entry is
                              missing. Non-zero is a real error only: unknown
                              flag, absent/non-numeric --phase, absent or
                              malformed roadmap.json, --dir not a directory.
                              Four steps per identity: (1) tracked path via
                              git ls-files, matching a directory as well as a
                              file; (2) strip a leading GET/POST/PUT/PATCH/
                              DELETE/HEAD/OPTIONS token so "POST /api/x" is
                              searched as "/api/x"; (3) git grep -F over
                              tracked source excluding docs and tests, bypassed
                              when the identity is itself documentation;
                              (4) drop hits that are only a TODO/FIXME/XXX/HACK
                              comment. A missing entry's evidence names the
                              rejected location and line, and states that git
                              sees tracked files only. git exiting above 1 is
                              status "error" carrying the code — never
                              "missing": a tool failure is not an absent
                              artifact.
    roadmap-init --feature <slug> [--file <path>] [--sync] [--brainstorm-path <path>]
                              [--integration-branch <name>]
                              Read a sanitized phases array (stdin or --file) and
                              atomically create/append to .aimi/tasks/<slug>/roadmap.json.
                              Without --sync, an existing roadmap.json is a hard error.
                              With --sync, only phases whose id is not already present
                              are appended; existing phases are left byte-for-byte
                              unchanged, and so is an already-stored integrationBranch --
                              --integration-branch is read only when materializing a
                              fresh roadmap.json, never to update one that already
                              exists (hand-edit the file for that, per issue #87's
                              direction 1). --integration-branch must match the same
                              ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ pattern a phase's own
                              --branch does, or the whole call is refused before any
                              write; omitted or empty means "not declared" and writes
                              no such field value (stored null).
                              Rejects (before any write) phases with a
                              missing id/name/goal, a dangling dependsOn reference,
                              or a computed dir that fails ^phase-[0-9]+(\.[0-9]+)?
                              (-[a-z0-9][a-z0-9-]*)?$. Free-text fields are sanitized
                              and length-capped per commands/references/sanitization.md.
                              A creates/needs entry is {identity, description};
                              an entry that is not that object, or that carries
                              any other key, is rejected naming the key. Also
                              rejects, per entry, an IDENTITY that is empty,
                              carries whitespace, a ".." segment, a leading "/",
                              one of [$`;|&], runs past 500 characters, or matches
                              an injection pattern -- and an areas[] glob that is
                              absolute or traverses. The identity is what
                              verify-creates greps for literally and is stored
                              exactly as submitted; the description is judged only
                              for injection patterns, may hold the rest, and is
                              the half the prose sanitizer applies to. Full rules
                              and rationale: commands/references/scope-contexts.md
                              section "Creates/Needs Contracts".
    roadmap-amend-phase --feature <slug> --phase <id> [--goal <text>] [--branch <name>]
                              [--file <path>] [--retarget-needs "<old>=<new>"]...
                              Correct an EXISTING phase's contract in place --
                              the one writer for a phase roadmap-init already
                              created, since --sync leaves an existing phase
                              byte-for-byte alone. Locked read-modify-write with
                              the same mktemp-then-mv atomic swap.
                              Amendable fields are exactly six: goal,
                              successCriteria, creates, needs, areas, branch.
                              They arrive as scalar flags (--goal/--branch) or as
                              a JSON object on stdin or --file; stdin is read only
                              when neither scalar flag is given. Merge is partial
                              by key presence -- a key present replaces that field
                              wholesale, a key absent leaves the stored value
                              byte-for-byte unchanged. Every other phase, the
                              document metadata, and this phase's own id, dir,
                              slug, name, dependsOn, status and claim are
                              untouched.
                              branch is amendable because nothing else writes it
                              for an existing phase (that is why a decimal phase's
                              null branch could not be filled). status and claim
                              are NOT: roadmap-set-status and roadmap-claim /
                              roadmap-release-claim already own them, and both keys
                              are rejected by name pointing at their owner.
                              Caveat: amending branch rewrites the roadmap field
                              only -- it does not move a worktree or git branch an
                              in_progress phase has already created.
                              Values pass roadmap-init's own gates: the same
                              sanitizer and caps, the same creates/needs identity
                              guard, and the same branch pattern.
                              Dropping or renaming a creates identity a later
                              phase cites in needs is REFUSED by default; the error
                              names every downstream phase and identity and prints
                              the --retarget-needs line that would authorize it.
                              --retarget-needs "<old identity>=<new identity>"
                              (repeatable, split on the first "=") authorizes it:
                              the same write replaces every matching downstream
                              needs entry with the amended phase's new creates
                              entry verbatim. Identity comparison is exact
                              equality, never substring. A pair whose old identity
                              is not actually dropped exits 1.
                              Also refused: an amendment that would duplicate a
                              creates identity another phase declares. Advisory
                              only (exit 0): a completed phase whose handoff.md
                              omits a newly introduced identity.
                              Prints {roadmap, phase, amended[], retargeted[]}.
    normalize-contracts --feature <slug>
                              Migrate a roadmap's stored creates/needs entries from
                              the 1.0 form -- one string, "identity (description)" --
                              to the 2.0 form {identity, description}, in place,
                              under the same lock and mktemp-then-mv swap every
                              other roadmap writer uses.
                              Each identity is computed by the SAME function every
                              reader used before the migration, so no identity
                              changes by a byte and no downstream needs is
                              repointed. An entry with no "(" gets description ""
                              (never null). An entry already in object form is left
                              untouched, which is what makes a second run a no-op.
                              It does not judge: a prose or whitespace-bearing
                              identity the current writer would refuse migrates
                              unchanged, and the reader reports it afterwards by
                              name. Repairing silently would change what a phase
                              promises.
                              Prints {roadmap, converted, roadmapVersion}, where
                              converted counts entries that were strings BEFORE
                              this run -- so a second run prints 0.
    roadmap-get --feature <slug> [--phase <id>] [--next-eligible]
                              Read-only. Bare: print the full roadmap.json.
                              --phase <id>: print one phase object.
                              --next-eligible: print the next claimable phase in
                              pending/planned status, unclaimed, whose dependsOn
                              phases are all completed. Ordered by remaining work
                              first and numeric id second -- a phase whose own
                              tasks file shows every story completed is reported
                              last, not first. Exits 1 if none. Does not clear
                              stale dead-PID claims (roadmap-claim does that,
                              under its lock); reads one tasks file per phase.
    roadmap-eligible --feature <slug> [--statuses <a,b>]
                              Read-only. Print ONE JSON object naming every
                              phase in roadmap order --
                              {id, name, status, claim, eligible, unmet[]} --
                              plus the ordered ids of the eligible ones and
                              their count: {phases, eligible, eligibleCount}.
                              A phase is eligible when its status is in the
                              requested set, it carries no claim, and every
                              dependsOn phase is completed; each unmet entry is
                              {id, status}. Structured fields only, no prose --
                              the caller composes the wording.
                              Zero eligible is a normal answer, not an error:
                              it exits 0 with an empty list, so a command
                              substitution can tell "no phase ready" apart from
                              a broken CLI.
                              --statuses defaults to pending,planned; an
                              unknown name is refused by name rather than
                              silently returning nothing.
                              Reads no tasks file, so its answer depends on
                              roadmap.json alone and is ordered by numeric id.
    roadmap-set-status --feature <slug> --phase <id> --status <status> [--force]
                              Locked read-modify-write. Enforces the guarded order
                              pending -> planned -> in_progress -> completed, plus
                              verification_failed -> completed (retry path); any
                              status may move to verification_failed. Other
                              transitions require --force. Transitioning to
                              completed always requires handoff.md to already
                              exist on disk at the phase's dir (write it first
                              with roadmap-write-handoff) -- this precondition
                              is NOT overridable by --force. A completed
                              transition also clears the phase's claim in the
                              same atomic write.
    roadmap-write-handoff --feature <slug> --phase <id> [--file <path>]
                              Read a JSON object (stdin or --file) with five
                              optional array-of-string fields -- decisions,
                              artifacts, deviations, deferred, contracts --
                              sanitize each entry, and atomically write
                              phase-<dir>/handoff.md with exactly five "## "
                              headings in that fixed order: Decisions Made,
                              Artifacts Created, Deviations, Deferred Items,
                              Contracts Delivered. This is the only path that
                              may create or overwrite that file -- direct
                              Write/Edit tool calls on it are blocked by
                              guard-runtime-state.py.
    write-review --feature <slug> --phase <N>
                              Read a phase's design review as markdown on stdin
                              and atomically write it to
                              .aimi/reviews/<slug>-phase-<N>.md, so the review
                              outlives the session that produced it. The body is
                              stored verbatim -- backticks and code fences are a
                              review's content, not something to strip -- and an
                              empty stdin is refused rather than written. Needs
                              no roadmap.json: a review is written about a phase,
                              not derived from one. Re-running replaces the file.
                              This is the only path that may create or overwrite
                              it -- direct Write/Edit tool calls on anything under
                              .aimi/reviews/ are blocked by guard-runtime-state.py.
    roadmap-claim --feature <slug> --session-id <id> --session-pid <pid> [--phase <id>]
                              Atomic locked read-modify-write. Auto-releases any
                              claim whose recorded pid fails a signal-zero liveness
                              probe. Self-reclaim: if this session already owns an
                              unreleased claim on a still-active phase (matching
                              --phase when given), returns that same phase again
                              instead of erroring or re-running eligibility.
                              Without --phase: claims the next phase that is
                              pending/planned/in_progress/verification_failed,
                              unclaimed, and dependency-complete -- ordered by
                              remaining work first and numeric id second, so a
                              stuck phase with nothing left to run is demoted
                              behind any phase that still has work but is still
                              claimed once it is the only candidate. With
                              --phase <id>: claims that phase only if eligible,
                              with no ranking applied; never falls through to a
                              different phase.
                              Exit 0 with the claimed phase JSON on success.
                              Exit 3 (all-blocked / phase not claimable): pending/
                              planned phases remain but none (or the named --phase)
                              are currently claimable (stderr lists why).
                              Exit 4 (none-eligible / phase not found): no phase
                              remains pending/planned, or --phase names an id that
                              does not exist in the roadmap.
                              roadmap.json is left unmodified on exit 3 or 4.
    roadmap-release-claim --feature <slug> --phase <id>
                              Locked read-modify-write. Clears claimedBy/claimedAt/
                              claimedPid on the named phase without touching status.
                              No-op success when the phase already has no claim.
    roadmap-reconcile --feature <slug>
                              Locked read-modify-write. For each phase with an
                              existing phase-<dir>/tasks.json, derives ground-truth
                              status from userStories statuses (all completed ->
                              completed; any failed -> verification_failed; else
                              in_progress) and corrects any divergent phase status.
                              Prints {corrections:[{id,from,to}...]}.
    phase-overlap <feature> <phase-a> <phase-b>
                              Deterministic stage-2 check for the sibling-phase
                              overlap guard. Loads both phases' already-expanded
                              phase-<dir>/<feature>-phase-<id>-tasks.json files,
                              collects userStories[].implementation.files across
                              all stories in each, and prints the sorted,
                              deduplicated intersection as {"overlapping_files":[...]}.
                              Exits non-zero with a clear error (not a jq stack
                              trace) when either phase's tasks.json is missing --
                              both phases must already be rolling-wave expanded.
    estimate-payload --outline <path> [--research <path>]... [--spec <path>]...
                              [--prototype <path>]... [--budget-bytes <n>]
                              Advisory only -- never blocks, never trims content.
                              Sums the byte sizes of --outline (required) plus every
                              repeated --research/--spec/--prototype path and compares
                              against an effective budget: --budget-bytes (manual debug
                              escape hatch; no caller passes it) if given, else 50% of a
                              400000-byte reference sub-agent window.
                              Prints {totalBytes, breakdown{outline,research,specs,prototypes},
                              budgetBytes, budgetFraction, overBudget, warning}.
                              warning is null under budget; otherwise names splitting the
                              phase along a semantic seam in the roadmap or trimming scope.
                              Exits 0 for any valid input (even over budget); exits 1 only
                              when --outline is missing or a given path does not exist.
    measure-command-file <path>
                              Structural size of one markdown file, as
                              {bytes, lines, prose_bytes, fence_bytes, bash_fence_bytes,
                               fences, bash_fences}.
                              The fence parse is lib/extract-command-blocks.sh's
                              extract_blocks() -- the same one test-command-blocks.sh
                              runs -- so a measurement written here can never disagree
                              with the blocks that suite sees. fences counts top-level
                              fences (one nested inside another is content of the outer);
                              bash_fences is the subset whose info string is exactly bash;
                              prose_bytes + fence_bytes == bytes.
                              Works on any markdown file, not only commands/ -- the
                              measurement is structural. Path confinement is the same
                              validate_path_in_project every path ARGUMENT crosses, run
                              before the file is opened. Exits 1 on a missing path
                              argument, a file that does not exist, or a path outside
                              the project root.
    help                      Show this help message

ENVIRONMENT:
    PROJECT_ROOT              Exported by find_aimi_root(); git repository root path
                              All file operations are validated to stay within this boundary
                              Worktree paths (.worktrees/ inside git root) are allowed

STATE FILES (.aimi/):
    current-tasks             Path to active tasks file
    current-branch            Current working branch name
    current-story             ID of story being executed
    last-result               Result of last execution (success/failed/skipped)
    default-branch            Cached default branch name (e.g., main, master)

ENVIRONMENT:
    CLAUDE_CONFIG_DIR  Override Claude config directory (default: ~/.claude)
                       Must be an absolute path when set.
    AIMI_PLUGIN_DIR    Plugin install directory set by compound-plugin converter;
                       bypasses Claude cache resolution. SKIPPED inside Claude
                       Code (CLAUDECODE=1), so the Claude cache wins there.
    AIMI_DEV_DIR       Layer 0 development override: a plugin checkout to run
                       instead of the installed copy. Honored on EVERY host --
                       no CLAUDECODE gate, unlike AIMI_PLUGIN_DIR above. Must be
                       an absolute path to an existing directory whose
                       scripts/aimi-cli.sh is executable, and must not sit under
                       a .worktrees/ segment. Every invocation prints one
                       unconditional stderr notice naming the path, and
                       check-version answers status "dev-override" without
                       attempting --fix, so the global cli-path cache is never
                       repointed at a development tree.

EXAMPLES:
    # Layer 0 first: the development override, honored on any host.
    if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi

    # Otherwise resolve the installed CLI path (honors CLAUDE_CONFIG_DIR).
    # Sort on the VERSION segment, never on the whole path and never plain `ls`:
    # `ls` collates 1.121.3 before 1.9.0, and a whole-path sort orders by
    # marketplace-entry directory first. The grep is not decoration: sort -V
    # ranks a non-version directory too, and ranks it ABOVE the real ones --
    # a sibling named 1.124.0.bak wins without it. Canonical rule:
    # _resolve_latest_cache_path.
    CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    AIMI_CLI=$(ls "$CONFIG_DIR"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d' ' -f2-)

    # Initialize a new session
    $AIMI_CLI init-session

    # Get next story to work on (dependency-aware)
    $AIMI_CLI next-story

    # List all ready stories (for parallel execution)
    $AIMI_CLI list-ready

    # Mark story in progress
    $AIMI_CLI mark-in-progress US-001

    # Mark story as complete
    $AIMI_CLI mark-complete US-001

    # Validate dependency graph
    $AIMI_CLI validate-deps

    # Fetch a specific story by ID
    $AIMI_CLI get-story US-003

    # Fetch story slice + metadata + skills + designContext (for subagent self-brief)
    # Output: {story, metadata, skills[{name,path,content}], designContext{decisions,bundleGuidance}}
    $AIMI_CLI get-story-context US-003

    # Cascade skip after failure
    $AIMI_CLI cascade-skip US-003

    # Check progress
    $AIMI_CLI status

    # Resume after /clear
    $AIMI_CLI get-state
EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  # ---- Layer 0: the AIMI_DEV_DIR announcement, before anything is dispatched.
  #
  # UNCONDITIONAL, and that word is the whole requirement rather than a
  # stylistic preference. The defect this override closes is a real install
  # silently SHADOWED by a development tree: a maintainer exports AIMI_DEV_DIR
  # for one experiment, forgets it in a shell profile, and every later session
  # runs code that is not what is installed while every diagnostic keeps
  # naming the version the installed plugin reports. So the line is printed on
  # the SUCCESS path, on every verb, once per process -- not only when
  # something goes wrong, because nothing going wrong is precisely the failure
  # mode.
  #
  # It sits above the skip-list case rather than inside a verb, so `version`,
  # `help` and the forge verbs -- which return before find_aimi_root ever runs
  # -- carry it too. stderr, never stdout: every verb below has a stdout
  # contract a caller parses, and this must not enter one of them.
  #
  # A value that is set but invalid is fatal HERE, at exit 1, rather than
  # falling through to the installed plugin. Falling through would be the
  # silent shadowing again with the sign flipped -- the operator asked for the
  # dev tree and would get the install without being told.
  local _dev_dir=""
  if ! _dev_dir=$(_dev_dir_path); then
    exit 1
  fi
  if [ -n "$_dev_dir" ]; then
    echo "Notice: AIMI_DEV_DIR override is active; aimi resolution points at $_dev_dir/scripts/aimi-cli.sh (development tree, shadowing any installed plugin)." >&2
  fi

  # Skip auto-discovery for commands that don't touch .aimi/
  case "${1:-help}" in
    help|--help|-h) cmd_help; return ;;
    version) cmd_version; return ;;
    detect-interactivity) shift; cmd_detect_interactivity "$@"; return ;;
    list-models) cmd_list_models; return ;;
    resolve-models) shift; cmd_resolve_models "$@"; return ;;
    get-current-models) cmd_get_current_models; return ;;
    detect-models) shift; cmd_detect_models "$@"; return ;;
    models-prompt-check) cmd_models_prompt_check; return ;;
    models-prompt-dismiss) cmd_models_prompt_dismiss; return ;;
    prime-cache) cmd_prime_cache; return ;;
    # Forge verbs: git + an optional forge CLI + jq, and nothing else. None of
    # them reads or writes .aimi/ state, so requiring a project would be pure
    # cost -- and find_aimi_root's cd side effect is actively wrong for them:
    # in a multi-repo layout it moves the process out of the git repository the
    # caller is standing in and into the non-git .aimi/ parent. Dispatching
    # here leaves the process in the invoking CWD, which is what an omitted
    # --project must resolve to. Each verb calls check_jq itself, since the
    # one below runs too late to cover them.
    detect-forge) shift; cmd_detect_forge "$@"; return ;;
    forge-auth-status) shift; cmd_forge_auth_status "$@"; return ;;
    forge-account-select) shift; cmd_forge_account_select "$@"; return ;;
    forge-repo-info) shift; cmd_forge_repo_info "$@"; return ;;
    forge-pr-view) shift; cmd_forge_pr_view "$@"; return ;;
    forge-pr-create) shift; cmd_forge_pr_create "$@"; return ;;
    forge-pr-edit) shift; cmd_forge_pr_edit "$@"; return ;;
    forge-pr-merge) shift; cmd_forge_pr_merge "$@"; return ;;
    forge-issue-view) shift; cmd_forge_issue_view "$@"; return ;;
    forge-issue-create) shift; cmd_forge_issue_create "$@"; return ;;
    forge-pr-review-threads) shift; cmd_forge_pr_review_threads "$@"; return ;;
    forge-resolve-review-thread) shift; cmd_forge_resolve_review_thread "$@"; return ;;
  esac

  # Universal --help/-h: any subcommand with --help or -h anywhere in its args
  # short-circuits to the top-level help doc. Runs before find_aimi_root so
  # help works outside .aimi/ projects, and before any side-effect subcommand
  # mutates state.
  for arg in "$@"; do
    case "$arg" in
      --help|-h) cmd_help; return ;;
    esac
  done

  find_aimi_root
  check_jq

  case "${1:-help}" in
    init-session)      shift; cmd_init_session "$@" ;;
    find-tasks)        cmd_find_tasks ;;
    find-tasks-all)    cmd_find_tasks_all ;;
    status)            shift; cmd_status "$@" ;;
    metadata)          shift; cmd_metadata "$@" ;;
    verification-report) shift; cmd_verification_report "$@" ;;
    project-groups)     shift; cmd_project_groups "$@" ;;
    next-story)        cmd_next_story ;;
    current-story)     shift; cmd_current_story "$@" ;;
    list-ready)        shift; cmd_list_ready "$@" ;;
    mark-in-progress)  shift; cmd_mark_in_progress "$@" ;;
    mark-complete)     shift; cmd_mark_complete "$@" ;;
    mark-failed)       shift; cmd_mark_failed "$@" ;;
    mark-skipped)      shift; cmd_mark_skipped "$@" ;;
    set-execution-mode) shift; cmd_set_execution_mode "$@" ;;
    count-pending)     shift; cmd_count_pending "$@" ;;
    validate-deps)            shift; cmd_validate_deps "$@" ;;
    validate-stories)         shift; cmd_validate_stories "$@" ;;
    normalize-verification)   cmd_normalize_verification "${2:-}" ;;
    normalize-status)         cmd_normalize_status "${2:-}" ;;
    validate-ids)             shift; cmd_validate_ids "$@" ;;
    gate-pass)         shift; cmd_gate_pass "$@" ;;
    gate-fail)         shift; cmd_gate_fail "$@" ;;
    update-field)      shift; cmd_update_field "$@" ;;
    validate-waves)    shift; cmd_validate_waves "$@" ;;
    validate-tasks)    shift; cmd_validate_tasks "$@" ;;
    cascade-skip)      shift; cmd_cascade_skip "$@" ;;
    reset-orphaned)    shift; cmd_reset_orphaned "$@" ;;
    get-branch)        shift; cmd_get_branch "$@" ;;
    get-story)         shift; cmd_get_story "$@" ;;
    get-story-context) shift; cmd_get_story_context "$@" ;;
    verify-probe)      shift; cmd_verify_probe "$@" ;;
    list-known-gaps)   shift; cmd_list_known_gaps "$@" ;;
    get-state)         cmd_get_state ;;
    detect-default-branch) shift; cmd_detect_default_branch "$@" ;;
    detect-parent-branch) shift; cmd_detect_parent_branch "$@" ;;
    # detect-forge and every forge-* verb are dispatched in the skip-list case
    # block above, before find_aimi_root -- never here.
    setup-branch)      shift; cmd_setup_branch "$@" ;;
    resolve-base-branch) shift; cmd_resolve_base_branch "$@" ;;
    clear-state)       cmd_clear_state ;;
    version)           cmd_version ;;
    check-version)     shift; cmd_check_version "$@" ;;
    cleanup-versions)  cmd_cleanup_versions ;;
    prime-cache)       cmd_prime_cache ;;
    list-archivable)   cmd_list_archivable ;;
    archive-task)      cmd_archive_task "${2:-}" ;;
    research-lookup)   shift; cmd_research_lookup "$@" ;;
    research-gc)       cmd_research_gc ;;
    extract-sections)  shift; cmd_extract_sections "$@" ;;
    detect-design-bundle) shift; cmd_detect_design_bundle "$@" ;;
    bundle-prototype-status)   shift; cmd_bundle_prototype_status "$@" ;;
    bundle-prototype-finalize) shift; cmd_bundle_prototype_finalize "$@" ;;
    story-merge)       shift; cmd_story_merge "$@" ;;
    split-detect)      shift; cmd_split_detect "$@" ;;
    roadmap-init)          shift; cmd_roadmap_init "$@" ;;
    roadmap-amend-phase)   shift; cmd_roadmap_amend_phase "$@" ;;
    normalize-contracts)   shift; cmd_normalize_contracts "$@" ;;
    roadmap-get)           shift; cmd_roadmap_get "$@" ;;
    roadmap-eligible)      shift; cmd_roadmap_eligible "$@" ;;
    roadmap-set-status)    shift; cmd_roadmap_set_status "$@" ;;
    roadmap-claim)         shift; cmd_roadmap_claim "$@" ;;
    roadmap-release-claim) shift; cmd_roadmap_release_claim "$@" ;;
    roadmap-reconcile)     shift; cmd_roadmap_reconcile "$@" ;;
    roadmap-write-handoff) shift; cmd_roadmap_write_handoff "$@" ;;
    write-review)         shift; cmd_write_review "$@" ;;
    validate-contracts)    shift; cmd_validate_contracts "$@" ;;
    verify-creates)        shift; cmd_verify_creates "$@" ;;
    phase-overlap)         shift; cmd_phase_overlap "$@" ;;
    roadmap-sweep)         shift; cmd_roadmap_sweep "$@" ;;
    estimate-payload)      shift; cmd_estimate_payload "$@" ;;
    measure-command-file)  shift; cmd_measure_command_file "$@" ;;
    help|--help|-h)    cmd_help ;;
    *)
      echo "Unknown command: $1" >&2
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
