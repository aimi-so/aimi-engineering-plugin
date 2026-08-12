#!/usr/bin/env bash
# test-aimi-cli-fixtures.sh - fixtures needed by more than one part file.
#
# Sourced only by the parts that use them. A helper belongs here when two or
# more parts call it; a helper used by exactly one part lives in that part.

# shellcheck shell=bash

# ---------------------------------------------------------------------------
# creates/needs entry constructors -- THE ONLY PLACE THE TEST CORPUS KNOWS WHAT
# A CONTRACT ENTRY LOOKS LIKE.
#
# That is the whole reason they exist, and it is worth stating plainly because
# the temptation to inline `"name (desc)"` is constant: there are 146 such
# literals in part 3 today, and they are why 3,875 green assertions failed to
# notice that an identity was being rewritten between roadmap.json and
# handoff.md. A test that pins the SHAPE cannot catch a change of shape.
#
# Route every fixture through these two and the wire format becomes one function
# body. Callers pass the pieces and consume the result with --argjson; never
# concatenate an entry by hand, and never split one apart to recover an identity
# (part 3 already grew three independent paren-splitters that disagree with the
# CLI's own on inputs none of them is tested against).
#
# THIS FILE IS WHERE THE FORMAT CHANGED, AND IT COST ONE FUNCTION BODY. The wire
# format was the single string "<identity> (<description>)"; it is now the object
# {identity, description}. Every fixture that had already been routed through
# these two moved with them and needed no edit of its own -- which is the whole
# argument for their existence, made concrete.

# aimi_contract_entry <identity> [description]  -> one JSON value on stdout
#
# An omitted description is "", never null and never an absent key: a reader that
# had to branch on which of the three it got would be the disjunction this schema
# exists to remove.
aimi_contract_entry() {
  local identity="$1" description="${2:-}"
  jq -n --arg i "$identity" --arg d "$description" '{identity: $i, description: $d}'
}

# aimi_contract_list "<identity>|<description>" ...  -> a JSON array on stdout
#
# "|" separates the two halves because "|" is in the shell class an identity may
# never contain, so no legal identity can split a row by accident. A row with no
# "|" is an identity with no description.
aimi_contract_list() {
  local row identity description out='[]'
  for row in "$@"; do
    identity="${row%%|*}"
    if [ "$row" = "$identity" ]; then description=""; else description="${row#*|}"; fi
    out=$(printf '%s' "$out" | jq -c --argjson e "$(aimi_contract_entry "$identity" "$description")" '. + [$e]')
  done
  printf '%s' "$out"
}

# Source the global cache functions from aimi-cli.sh for direct testing.
# We extract the needed functions using sed so we can call them directly.
source_cache_functions() {
  eval "$(sed -n '/^_claude_config_dir()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_aimi_config_dir()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_validate_plugin_dir()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_is_claude_code_host()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_global_cache_path_legacy()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_global_worktree_cache_path_legacy()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_global_cache_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_global_worktree_cache_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_extract_version_from_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_resolve_latest_cache_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_validate_cached_cli_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_validate_cached_worktree_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^write_global_cli_cache()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^read_global_cli_cache()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^write_global_worktree_cache()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^read_global_worktree_cache()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^cmd_prime_cache()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_aimi_models_config_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_aimi_models_prompt_marker_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^read_aimi_models_config()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^write_aimi_models_config()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^cmd_models_prompt_check()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^cmd_models_prompt_dismiss()/,/^}/p' "$CLI")"
}

# ============================================================================
# _forge_account_store_path Tests
# ============================================================================
#
# _forge_account_store_path is the fifth config-dir path helper, which is why
# its tests live beside the other config-path tests rather than down in the
# forge section: it shells out to `git rev-parse` and to nothing else, needs no
# `gh` and no network, and shares _aimi_config_dir with _global_cache_path.

# Sources the helpers _forge_account_store_path needs, in the same sed+eval
# style as source_cache_functions above and source_forge_issue_functions below.
#
# The two bare assignments are NOT optional and NOT copy-paste noise:
# _HAS_REALPATH and _HAS_SHA256SUM are plain TOP-LEVEL assignments in
# aimi-cli.sh (:19-20), not functions, so a `sed '/^name()/,/^}/p'` extraction
# cannot reach them. Without them the eval'd _default_branch_cache_key blows up
# at `[ "$_HAS_SHA256SUM" -eq 1 ]` under this suite's `set -u`. They are
# recomputed here exactly as aimi-cli.sh computes them, so the digest the test
# sees is the digest the real CLI produces on the same machine.
source_forge_account_store_functions() {
  _HAS_REALPATH=$(command -v realpath &>/dev/null && echo 1 || echo 0)
  _HAS_SHA256SUM=$(command -v sha256sum &>/dev/null && echo 1 || echo 0)
  eval "$(sed -n '/^resolve_path()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_aimi_config_dir()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_default_branch_cache_key()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_account_store_path()/,/^}/p' "$CLI")"
}

# Removes temporary directories created by setup_git_fixture
teardown_git_fixture() {
  rm -rf "$GIT_FIXTURE_REMOTE" "$GIT_FIXTURE_LOCAL"
  unset GIT_FIXTURE_REMOTE
  unset GIT_FIXTURE_LOCAL
}

# ============================================================================
# Per-Repo Default-Branch Cache Scoping Fixture
# ============================================================================

# Creates a non-git AIMI_ROOT directory (own temp dir, with .aimi/tasks so
# find_aimi_root succeeds) containing two sibling child git repos: repo-a
# (bare remote HEAD -> refs/heads/main) and repo-b (bare remote HEAD ->
# refs/heads/master). Mirrors setup_parent_branch_fixture's bare-remote +
# local-clone technique (a fresh --bare init defaults to master, which is
# never pushed, leaving "HEAD branch: (unknown)" otherwise) so `git remote
# show origin` resolves a real default branch for each repo without any
# network access. Exercises _resolve_default_branch's per-repo cache-key
# scoping (aimi-cli.sh:1570+) across --project calls that share one AIMI_DIR.
setup_multi_repo_default_branch_fixture() {
  MULTI_REPO_FIXTURE_ROOT=$(mktemp -d)
  mkdir -p "$MULTI_REPO_FIXTURE_ROOT/.aimi/tasks"

  MULTI_REPO_FIXTURE_REMOTE_A=$(mktemp -d)
  MULTI_REPO_FIXTURE_REMOTE_B=$(mktemp -d)
  MULTI_REPO_FIXTURE_A="$MULTI_REPO_FIXTURE_ROOT/repo-a"
  MULTI_REPO_FIXTURE_B="$MULTI_REPO_FIXTURE_ROOT/repo-b"

  git init --bare "$MULTI_REPO_FIXTURE_REMOTE_A" >/dev/null 2>&1
  git --git-dir="$MULTI_REPO_FIXTURE_REMOTE_A" symbolic-ref HEAD refs/heads/main
  git init --bare "$MULTI_REPO_FIXTURE_REMOTE_B" >/dev/null 2>&1
  git --git-dir="$MULTI_REPO_FIXTURE_REMOTE_B" symbolic-ref HEAD refs/heads/master

  git clone "$MULTI_REPO_FIXTURE_REMOTE_A" "$MULTI_REPO_FIXTURE_A" >/dev/null 2>&1
  pushd "$MULTI_REPO_FIXTURE_A" >/dev/null
  git checkout -b main >/dev/null 2>&1
  echo "a" > README.md && git add README.md && git commit -m "repo-a initial commit" >/dev/null 2>&1
  git push -u origin main >/dev/null 2>&1
  popd >/dev/null

  git clone "$MULTI_REPO_FIXTURE_REMOTE_B" "$MULTI_REPO_FIXTURE_B" >/dev/null 2>&1
  pushd "$MULTI_REPO_FIXTURE_B" >/dev/null
  git checkout -b master >/dev/null 2>&1
  echo "b" > README.md && git add README.md && git commit -m "repo-b initial commit" >/dev/null 2>&1
  git push -u origin master >/dev/null 2>&1
  popd >/dev/null
}

# Removes the temp directories created by setup_multi_repo_default_branch_fixture
teardown_multi_repo_default_branch_fixture() {
  rm -rf "$MULTI_REPO_FIXTURE_ROOT" "$MULTI_REPO_FIXTURE_REMOTE_A" "$MULTI_REPO_FIXTURE_REMOTE_B"
  unset MULTI_REPO_FIXTURE_ROOT MULTI_REPO_FIXTURE_A MULTI_REPO_FIXTURE_B MULTI_REPO_FIXTURE_REMOTE_A MULTI_REPO_FIXTURE_REMOTE_B
}

# ============================================================================
# Detect Forge Tests (US-001)
# ============================================================================
# detect-forge is the FOUNDATIONAL CONTRACT every later forge-* verb in this
# phase calls -- its output shape {forge, host, remote, remoteUrl, source}
# is consumed verbatim downstream. Every fixture here is fully offline (no
# bare repo, no clone, no push, no `git remote show`) following the
# setup_default_branch_offline_fixture precedent (test-aimi-cli.sh:6412):
# `git remote add` never dials the URL it is given.

# Creates an isolated git repo (own temp dir) with a single commit and zero
# remotes, then adds one remote per name/url pair passed as arguments
# (name1 url1 [name2 url2 ...]) via `git remote add` -- never dialed, so
# this fixture is fast and fully offline. Sets DETECT_FORGE_FIXTURE_DIR and
# pushd's into it; caller must popd + teardown_detect_forge_fixture.
setup_detect_forge_fixture() {
  DETECT_FORGE_FIXTURE_DIR=$(mktemp -d)

  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null
  git init >/dev/null 2>&1
  git checkout -b main >/dev/null 2>&1
  echo "init" > README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1

  while [ $# -ge 2 ]; do
    git remote add "$1" "$2"
    shift 2
  done

  # Create .aimi/ directory so find_aimi_root succeeds
  mkdir -p .aimi/tasks

  popd >/dev/null
}

# Removes the temp directory created by setup_detect_forge_fixture
teardown_detect_forge_fixture() {
  rm -rf "$DETECT_FORGE_FIXTURE_DIR"
  unset DETECT_FORGE_FIXTURE_DIR
}

# Creates a non-git AIMI_ROOT directory (own temp dir, with its own
# .aimi/tasks so find_aimi_root succeeds) containing two sibling child git
# repos, repo-a (origin -> github.com) and repo-b (origin -> gitlab.com) --
# mirrors the documented Multi-Repo Execution Layout (AIMI_ROOT is a plain
# non-git parent folder holding one git repository per subfolder). Used to
# prove --project resolves each repo's own forge without requiring the
# caller's cwd to already be inside it, and without leaking one repo's
# result into the other's (aimi-cli.sh:1636-1659's --project support).
setup_detect_forge_multirepo_fixture() {
  DETECT_FORGE_MULTIREPO_DIR=$(mktemp -d)
  mkdir -p "$DETECT_FORGE_MULTIREPO_DIR/.aimi/tasks"

  local repo
  for repo in repo-a repo-b; do
    mkdir -p "$DETECT_FORGE_MULTIREPO_DIR/$repo"
    pushd "$DETECT_FORGE_MULTIREPO_DIR/$repo" >/dev/null
    git init >/dev/null 2>&1
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1
    popd >/dev/null
  done

  git -C "$DETECT_FORGE_MULTIREPO_DIR/repo-a" remote add origin https://github.com/a/repo.git
  git -C "$DETECT_FORGE_MULTIREPO_DIR/repo-b" remote add origin https://gitlab.com/b/repo.git
}

# Removes the temp directory created by setup_detect_forge_multirepo_fixture
teardown_detect_forge_multirepo_fixture() {
  rm -rf "$DETECT_FORGE_MULTIREPO_DIR"
  unset DETECT_FORGE_MULTIREPO_DIR
}

# ============================================================================
# forge-auth-status / forge-repo-info Tests (US-003)
# ============================================================================
# Offline test fixtures: a reusable fake-`gh` PATH stub (setup_fake_gh_
# fixture/teardown_fake_gh_fixture) so every scenario below -- and any
# sibling forge-* verb story later in this phase that also shells out to gh
# -- shares ONE stub rather than a private copy per story, per the fake-
# opencode PATH-stub precedent already used by resolve-models' mtime-cache
# test (test-aimi-cli.sh:8510-8583). Every git remote used below is local
# (a bare repo, a nonexistent local path, or a literal remote URL string);
# no test in this section makes a real network call or depends on real gh
# credentials.

# Writes a fake `gh` executable to a fresh temp dir and prepends nothing to
# PATH itself -- callers do `PATH="$FAKE_GH_DIR:$PATH" ...` per invocation,
# same as the fake-opencode precedent. Behavior is controlled entirely by
# FAKE_GH_* environment variables so one stub covers every scenario,
# including the forge-pr-view (US-004) `gh pr view`/`gh pr list` scenarios in
# the section below -- exactly the sibling-story reuse this fixture was
# built for:
#   FAKE_GH_AUTH_STATUS_MODE   single (default) | multi | none
#   FAKE_GH_AUTH_HOST          hostname echoed in the fake account block (default github.com)
#   FAKE_GH_AUTH_ACCOUNT       the (single, or active-in-multi) account login (default octocat)
#   FAKE_GH_AUTH_OTHER_ACCOUNT the non-active login in multi mode (default monalisa)
#   FAKE_GH_REPO_OWNER         owner login `gh repo view` reports (default octocat)
#   FAKE_GH_REPO_NAME          repo name `gh repo view` reports (default hello-world)
#   FAKE_GH_REPO_VIEW_FAIL     "1" forces `gh repo view` to exit non-zero (simulates
#                              missing auth / network failure, not absence of gh itself)
#   FAKE_GH_CALL_COUNTER       optional path to a counter file incremented once per
#                              `gh repo view` invocation, letting a test prove exactly
#                              one call was made rather than the old two-call shape
#   FAKE_GH_VIEW_EXIT / FAKE_GH_VIEW_STDERR -- `gh pr view` exit code + stderr
#   FAKE_GH_PR_JSON                          -- `gh pr view` stdout on exit 0 (default '{}')
#   FAKE_GH_LIST_EXIT / FAKE_GH_LIST_STDERR -- `gh pr list` exit code + stderr
#   FAKE_GH_LIST_JSON                        -- `gh pr list` stdout on exit 0 (default '[]')
#   FAKE_GH_LOG                              -- optional file; every invocation's args appended, one per line
#   FAKE_GH_AUTH_STRICT_HOSTNAME "1" makes `gh auth status --hostname X` exit 1 for any X
#                              other than FAKE_GH_AUTH_HOST, the way real gh does. Off by
#                              default so the flag is ignored (pre-existing behavior); set
#                              it only in a test that is specifically about hostname handling.
#                              It applies to `gh auth token --hostname X` too.
#   FAKE_GH_AUTH_TOKEN         the token `gh auth token` prints (default a gho_-shaped fake)
#   FAKE_GH_AUTH_TOKEN_FAIL    "1" forces `gh auth token` to exit 1 with real gh's
#                              "no oauth token found for <host> account <user>" wording,
#                              simulating a remembered account that was later logged out
#   FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN
#                              "1" makes `gh auth status` report the ENV-TOKEN account as
#                              "Active account: true" when GH_TOKEN/GH_ENTERPRISE_TOKEN is
#                              set, which is what real gh does. OPT-IN, and that matters:
#                              the developer's own shell may legitimately export GH_TOKEN,
#                              and turning this on by default would change the answer every
#                              pre-existing test gets. Same opt-in posture as
#                              FAKE_GH_AUTH_STRICT_HOSTNAME above.
#   FAKE_GH_ENV_TOKEN_ACCOUNT  the login reported under that env-token block
#                              (default env-token-account)
setup_fake_gh_fixture() {
  FAKE_GH_DIR=$(mktemp -d)
  cat > "$FAKE_GH_DIR/gh" << 'FAKE_GH_SCRIPT'
#!/usr/bin/env bash
if [ -n "$FAKE_GH_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_LOG"
fi

case "$1 $2" in
  "auth status")
    # Opt-in faithfulness: real gh REJECTS a --hostname it has no session
    # for, which is how a bogus hostname turns into a confirmed-looking
    # "not authenticated" answer. The default stays lenient (ignores the
    # flag entirely) so every pre-existing test keeps its old behavior;
    # only a test that is specifically about hostname handling sets this.
    if [ "${FAKE_GH_AUTH_STRICT_HOSTNAME:-0}" = "1" ]; then
      want_host="${FAKE_GH_AUTH_HOST:-github.com}"
      expect_value=""
      for arg in "$@"; do
        if [ -n "$expect_value" ]; then
          if [ "$arg" != "$want_host" ]; then
            echo "You are not logged into any hosts on $arg" >&2
            exit 1
          fi
          expect_value=""
          continue
        fi
        [ "$arg" = "--hostname" ] && expect_value=1
      done
    fi
    # Opt-in faithfulness, part two: with a token in the environment real gh
    # reports THAT account as the active one and demotes the keyring account
    # to "Active account: false". This is the landmine behind the
    # export-is-forbidden rule -- an override that leaked process-wide would
    # make forge-auth-status report the overridden account as machine-active,
    # and a before/after check would lose the ability to see the violation.
    # Off by default because a developer's own shell may export GH_TOKEN.
    if [ "${FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN:-0}" = "1" ] &&
       { [ -n "${GH_TOKEN:-}" ] || [ -n "${GH_ENTERPRISE_TOKEN:-}" ]; }; then
      host="${FAKE_GH_AUTH_HOST:-github.com}"
      account="${FAKE_GH_AUTH_ACCOUNT:-octocat}"
      echo "$host"
      echo "  Logged in to $host account ${FAKE_GH_ENV_TOKEN_ACCOUNT:-env-token-account} (GH_TOKEN)"
      echo "  - Active account: true"
      echo "  Logged in to $host account $account (keyring)"
      echo "  - Active account: false"
      exit 0
    fi
    case "${FAKE_GH_AUTH_STATUS_MODE:-single}" in
      single)
        host="${FAKE_GH_AUTH_HOST:-github.com}"
        account="${FAKE_GH_AUTH_ACCOUNT:-octocat}"
        echo "$host"
        echo "  Logged in to $host account $account (keyring)"
        echo "  - Active account: true"
        exit 0
        ;;
      multi)
        host="${FAKE_GH_AUTH_HOST:-github.com}"
        active="${FAKE_GH_AUTH_ACCOUNT:-octocat}"
        other="${FAKE_GH_AUTH_OTHER_ACCOUNT:-monalisa}"
        echo "$host"
        echo "  Logged in to $host account $other (keyring)"
        echo "  - Active account: false"
        echo "  Logged in to $host account $active (keyring)"
        echo "  - Active account: true"
        exit 0
        ;;
      none)
        echo "You are not logged into any GitHub hosts." >&2
        exit 1
        ;;
    esac
    ;;
  "auth token")
    # Real gh returns the ENVIRONMENT token whenever one is set, which is
    # precisely why _forge_account_override has to clear GH_TOKEN and
    # GH_ENTERPRISE_TOKEN for its own lookup or it resolves to itself instead
    # of to the keyring. Emulated here unconditionally -- deliberately
    # stricter than real gh, whose precedence alongside an explicit --user is
    # less clear-cut -- so a test can prove the clearing DECISIVELY (the
    # ambient value comes back only if the clearing is missing) rather than
    # by inference from a token that would have looked the same either way.
    if [ -n "${GH_TOKEN:-}" ]; then
      printf '%s\n' "$GH_TOKEN"
      exit 0
    fi
    if [ -n "${GH_ENTERPRISE_TOKEN:-}" ]; then
      printf '%s\n' "$GH_ENTERPRISE_TOKEN"
      exit 0
    fi
    # Long flags only (--user/--hostname); the code under test never uses the
    # -u/-h short forms and honoring `-h` here would collide with help.
    want_user=""
    want_host=""
    expect=""
    for arg in "$@"; do
      if [ "$expect" = "user" ]; then
        want_user="$arg"
        expect=""
        continue
      fi
      if [ "$expect" = "host" ]; then
        want_host="$arg"
        expect=""
        continue
      fi
      case "$arg" in
        --user) expect="user" ;;
        --hostname) expect="host" ;;
      esac
    done
    host="${FAKE_GH_AUTH_HOST:-github.com}"
    if [ "${FAKE_GH_AUTH_STRICT_HOSTNAME:-0}" = "1" ] && [ -n "$want_host" ] && [ "$want_host" != "$host" ]; then
      echo "no oauth token found for $want_host account ${want_user:-<active>}" >&2
      exit 1
    fi
    if [ "${FAKE_GH_AUTH_TOKEN_FAIL:-0}" = "1" ]; then
      echo "no oauth token found for ${want_host:-$host} account ${want_user:-<active>}" >&2
      exit 1
    fi
    # The fixture's account set, mode by mode -- a login outside it fails the
    # way real gh fails for an account that was logged out.
    case "${FAKE_GH_AUTH_STATUS_MODE:-single}" in
      single) known="${FAKE_GH_AUTH_ACCOUNT:-octocat}" ;;
      multi)  known="${FAKE_GH_AUTH_ACCOUNT:-octocat} ${FAKE_GH_AUTH_OTHER_ACCOUNT:-monalisa}" ;;
      *)      known="" ;;
    esac
    if [ -n "$want_user" ]; then
      found=0
      for acct in $known; do
        if [ "$acct" = "$want_user" ]; then
          found=1
        fi
      done
      if [ "$found" != "1" ]; then
        echo "no oauth token found for ${want_host:-$host} account $want_user" >&2
        exit 1
      fi
    fi
    printf '%s\n' "${FAKE_GH_AUTH_TOKEN:-gho_faketoken0000000000000000000000000000}"
    exit 0
    ;;
  "repo view")
    if [ -n "${FAKE_GH_CALL_COUNTER:-}" ]; then
      count=$(cat "$FAKE_GH_CALL_COUNTER" 2>/dev/null || echo 0)
      count=$((count + 1))
      printf '%s\n' "$count" > "$FAKE_GH_CALL_COUNTER"
    fi
    if [ "${FAKE_GH_REPO_VIEW_FAIL:-0}" = "1" ]; then
      echo "error: could not determine repository" >&2
      exit 1
    fi
    owner="${FAKE_GH_REPO_OWNER:-octocat}"
    name="${FAKE_GH_REPO_NAME:-hello-world}"
    printf '{"owner":{"login":"%s"},"name":"%s"}\n' "$owner" "$name"
    exit 0
    ;;
  "pr view")
    exit_code="${FAKE_GH_VIEW_EXIT:-0}"
    if [ "$exit_code" = "0" ]; then
      body="${FAKE_GH_PR_JSON:-}"
      [ -z "$body" ] && body='{}'
      printf '%s' "$body"
      exit 0
    fi
    printf '%s' "${FAKE_GH_VIEW_STDERR:-}" >&2
    exit "$exit_code"
    ;;
  "pr list")
    exit_code="${FAKE_GH_LIST_EXIT:-0}"
    if [ "$exit_code" = "0" ]; then
      body="${FAKE_GH_LIST_JSON:-}"
      [ -z "$body" ] && body='[]'
      printf '%s' "$body"
      exit 0
    fi
    printf '%s' "${FAKE_GH_LIST_STDERR:-}" >&2
    exit "$exit_code"
    ;;
  *)
    echo "fake-gh: unhandled invocation: $*" >&2
    exit 127
    ;;
esac
FAKE_GH_SCRIPT
  chmod +x "$FAKE_GH_DIR/gh"
}

# Removes the fake-gh temp dir and every FAKE_GH_* control variable, so a
# stray export never leaks into an unrelated later test.
teardown_fake_gh_fixture() {
  rm -rf "$FAKE_GH_DIR"
  unset FAKE_GH_DIR FAKE_GH_AUTH_STATUS_MODE FAKE_GH_AUTH_HOST FAKE_GH_AUTH_ACCOUNT \
    FAKE_GH_AUTH_OTHER_ACCOUNT FAKE_GH_REPO_OWNER FAKE_GH_REPO_NAME FAKE_GH_REPO_VIEW_FAIL \
    FAKE_GH_CALL_COUNTER FAKE_GH_VIEW_EXIT FAKE_GH_VIEW_STDERR FAKE_GH_PR_JSON \
    FAKE_GH_LIST_EXIT FAKE_GH_LIST_STDERR FAKE_GH_LIST_JSON FAKE_GH_LOG \
    FAKE_GH_AUTH_STRICT_HOSTNAME FAKE_GH_AUTH_TOKEN FAKE_GH_AUTH_TOKEN_FAIL \
    FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN FAKE_GH_ENV_TOKEN_ACCOUNT
}

# Prints a PATH value with every occurrence of <binary> made unresolvable,
# while every OTHER tool aimi-cli.sh depends on remains reachable under its
# real name. A naive "strip every PATH directory containing <binary>"
# approach is unsafe here: on a machine where gh happens to live in
# /usr/bin alongside bash/jq/git/sed/..., stripping that directory would
# also hide the interpreter and break the whole suite. Instead this mirrors
# ONLY the fixed set of tools aimi-cli.sh actually shells out to (resolved
# via `command -v` against the CALLER's real PATH, first match wins) into a
# fresh directory, deliberately omitting <binary> -- so PATH="$(_path_
# without_binary gh)" simulates gh being entirely absent, not merely
# shadowed, without disturbing bash/jq/git/etc. Reusable by name for any
# later story that needs the same "binary genuinely absent" scenario.
_path_without_binary() {
  local exclude="$1" shim_dir tool real
  shim_dir=$(mktemp -d)
  local tools=(env bash jq git sed grep awk mktemp wc tr basename dirname stat sha256sum shasum flock date cut find sort xargs cat head tail realpath printf)
  for tool in "${tools[@]}"; do
    [ "$tool" = "$exclude" ] && continue
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$real" "$shim_dir/$tool" 2>/dev/null
  done
  printf '%s' "$shim_dir"
}

# The single "gh is genuinely absent from PATH" fixture, shared by every test
# that needs that scenario. It wraps _path_without_binary rather than scanning
# /usr/local/bin://usr/bin://bin for a file named `gh`, which is how a second,
# independently written copy of this fixture used to do it -- both proved the
# same narrow thing, so the directory-scanning pair was deleted in favour of
# this one. Keeps the NO_GH_PATH_DIR name that pair already exported, and adds
# the cleanup the tests that called _path_without_binary directly never did.
#
# NOT to be confused with setup_forge_cli_sandbox: that one is a broader
# offline sandbox (a different, smaller tool allowlist plus a
# command-v-then-/usr/bin-then-/bin fallback) whose 20+ callers mostly drop
# their own scripted fake `gh` into it afterwards -- "gh present but scripted",
# not "gh absent". Merging the two would have to either widen its allowlist or
# narrow this one, changing what one set of tests actually proves, so it is
# deliberately left alone.
setup_forge_no_gh_fixture() {
  NO_GH_PATH_DIR=$(_path_without_binary gh)
}

teardown_forge_no_gh_fixture() {
  rm -rf "$NO_GH_PATH_DIR"
  unset NO_GH_PATH_DIR
}

# Builds a minimal, hermetic PATH sandbox containing exactly the external
# binaries this code path needs (bash, so the `#!/usr/bin/env bash`
# shebang resolves via env; jq; git; mktemp; cat; rm; grep; sed; tr; tail;
# dirname; basename -- find_aimi_root's resolve_path fallback needs the
# last two whenever `realpath` is unavailable) -- and deliberately does
# NOT include `gh`, so `command -v gh` genuinely fails inside the sandbox
# exactly like a machine that never installed the GitHub CLI. This is
# stronger than the `PATH="/usr/bin:/bin"` shortcut cmd_detect_models's
# tests use for opencode absence (test-aimi-cli.sh:8834) -- that shortcut
# only works because opencode is not preinstalled at /usr/bin on the test
# machine, whereas `gh` IS very often preinstalled there (this repo's own
# dev environment has /usr/bin/gh), so hiding it needs an explicit
# allowlist sandbox instead of hoping the real PATH happens to lack it.
#
# A caller that wants a "gh present" scenario writes its own executable
# <sandbox>/gh script afterward (a plain heredoc -- see the test functions
# below), then invokes the CLI with `PATH="<sandbox>" "$CLI" ...` -- the
# sandbox alone, no fallback to the real PATH, is what keeps the real gh
# hidden for the "gh absent" tests.
setup_forge_cli_sandbox() {
  local sandbox
  sandbox=$(mktemp -d)

  # sha256sum/shasum/awk joined the list for the phase-2 account store.
  # _forge_account_store_path names its file after
  # _default_branch_cache_key's digest of the repository's git common dir, and
  # that helper falls back to a portable `tr -c` slugification when NEITHER
  # hashing tool is on PATH (awk is what reads the digest out of either one's
  # output). Without all three the sandbox would compute a DIFFERENT store
  # filename than production and than any test that seeded the store from the
  # real PATH -- so a routed write would silently find no recorded answer and
  # the assertion would pass for the wrong reason.
  local tool resolved candidate
  for tool in bash jq git mktemp cat rm grep sed tr tail dirname basename sha256sum shasum awk; do
    resolved=$(command -v "$tool" 2>/dev/null) || resolved=""
    if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
      for candidate in "/usr/bin/$tool" "/bin/$tool"; do
        if [ -x "$candidate" ]; then
          resolved="$candidate"
          break
        fi
      done
    fi
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      ln -sf "$resolved" "$sandbox/$tool"
    fi
  done

  printf '%s' "$sandbox"
}
