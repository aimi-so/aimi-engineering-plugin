#!/usr/bin/env bash
set -uo pipefail

# test-aimi-cli-part4-forge-verbs.sh - part 4 of 4 of the aimi-cli.sh test suite.
#
# Covers the forge and GitLab verb surface: PR view/create/edit, issue
# verbs, review threads, dispatch order and derivation memo.
#
# Run it directly for a fast focused loop, or via test-aimi-cli.sh (the
# dispatcher) to run all four parts and get the aggregate count. The parts are
# separate processes so they can eventually run in parallel; the serial run is
# NOT measurably faster than the single 28k-line file was (see CHANGELOG --
# fork cost does scale with script size, but only by ~270us per fork, which is
# a few seconds across the whole suite and below the run-to-run noise floor).
#
# Sections, in the order the single-file suite ran them:
#   - Forge Account Override Tests (phase 2 US-005)
#   - Forge PR View Tests (US-004)
#   - Forge PR Create/Edit Tests (US-005)
#   - GitLab Write-Verb Tests (phase 3)
#   - GitLab Account-Selection Tests (phase 3)
#   - Forge Issue Verb Tests (US-006)
#   - Forge Review-Thread Verb Tests (US-007)
#   - GitLab Review-Thread Routing Tests (phase 3 US-004)
#   - Forge Dispatch-Order Tests (phase 1.1 US-006)
#   - Forge Derivation Memo + PR-View Probe-Order Tests (phase 1.1 US-010)
#   - GitLab PR-field Mapping Tests (phase 3 US-001)
#   - Gitea PR-field Mapping Tests (phase 4 outline:01)
#   - GitLab READ-verb Routing Tests (phase 3 US-002)
#   - Gitea READ-verb Routing Tests (phase 4 outline:02)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/aimi-cli.sh"

# shellcheck source=./test-aimi-cli-common.sh
. "$SCRIPT_DIR/test-aimi-cli-common.sh"
# shellcheck source=./test-aimi-cli-fixtures.sh
. "$SCRIPT_DIR/test-aimi-cli-fixtures.sh"

# ---------------------------------------------------------------------------
# Fake `glab` PATH stub (phase 3 US-001)
# ---------------------------------------------------------------------------
# Deliberately a SEPARATE stub from setup_fake_gh_fixture rather than a mode
# added to it: the two CLIs share no subcommand vocabulary and no output
# shape, so folding glab into the gh stub would mean one script whose every
# branch is reachable by only one of the two callers.
#
# glab is NOT installed on the machine this was written on -- that is the
# phase's declared verification ceiling, not an oversight -- so this stub is
# the ONLY glab any test here ever sees. Its payloads are modelled on
# go-gitlab's *gitlab.MergeRequest struct tags (the keys glab emits, because
# `glab mr view -F json` marshals that struct whole), never on a captured
# real-binary response.
#
# Same shape as the fake gh: written to a fresh temp dir, prepends nothing to
# PATH itself (callers do `PATH="$FAKE_GLAB_DIR:$PATH" ...` per invocation),
# and is driven entirely by FAKE_GLAB_* environment variables:
#   FAKE_GLAB_LOG             optional file; every invocation's argv appended, one
#                             line per call -- lets an assertion prove WHICH flags
#                             were passed (`-F json`, never a gh-style --json list)
#   FAKE_GLAB_MR_JSON         `glab mr view` stdout on exit 0 (default '{}')
#   FAKE_GLAB_MR_JSON_SECOND  when set (together with FAKE_GLAB_CALL_COUNTER),
#                             stdout for the SECOND and every later `mr view`
#                             call. This is what lets one fixture report
#                             DIFFERING output across two calls, so a
#                             before/after comparison is proven able to move
#                             rather than passing vacuously.
#   FAKE_GLAB_CALL_COUNTER    path to a counter file incremented once per
#                             `mr view`; required for MR_JSON_SECOND to fire
#   FAKE_GLAB_VIEW_EXIT       `glab mr view` exit code (default 0)
#   FAKE_GLAB_VIEW_STDERR     stderr emitted when VIEW_EXIT is non-zero
setup_fake_glab_fixture() {
  FAKE_GLAB_DIR=$(mktemp -d)
  cat > "$FAKE_GLAB_DIR/glab" << 'FAKE_GLAB_SCRIPT'
#!/usr/bin/env bash
if [ -n "$FAKE_GLAB_LOG" ]; then
  printf '%s\n' "$*" >> "$FAKE_GLAB_LOG"
fi

case "$1 $2" in
  "mr view")
    call=1
    if [ -n "$FAKE_GLAB_CALL_COUNTER" ]; then
      call=$(cat "$FAKE_GLAB_CALL_COUNTER" 2>/dev/null || echo 0)
      call=$((call + 1))
      printf '%s\n' "$call" > "$FAKE_GLAB_CALL_COUNTER"
    fi
    exit_code="${FAKE_GLAB_VIEW_EXIT:-0}"
    if [ "$exit_code" != "0" ]; then
      printf '%s' "${FAKE_GLAB_VIEW_STDERR:-}" >&2
      exit "$exit_code"
    fi
    body="${FAKE_GLAB_MR_JSON:-}"
    if [ "$call" -gt 1 ] && [ -n "${FAKE_GLAB_MR_JSON_SECOND:-}" ]; then
      body="$FAKE_GLAB_MR_JSON_SECOND"
    fi
    [ -z "$body" ] && body='{}'
    printf '%s' "$body"
    exit 0
    ;;
  *)
    echo "fake-glab: unhandled invocation: $*" >&2
    exit 127
    ;;
esac
FAKE_GLAB_SCRIPT
  chmod +x "$FAKE_GLAB_DIR/glab"
}

# Removes the fake-glab temp dir and every FAKE_GLAB_* control variable, so a
# stray export never leaks into an unrelated later test.
teardown_fake_glab_fixture() {
  rm -rf "$FAKE_GLAB_DIR"
  unset FAKE_GLAB_DIR FAKE_GLAB_LOG FAKE_GLAB_MR_JSON FAKE_GLAB_MR_JSON_SECOND \
    FAKE_GLAB_CALL_COUNTER FAKE_GLAB_VIEW_EXIT FAKE_GLAB_VIEW_STDERR
}

# Sources the GitLab field mapper plus the two functions the assertions below
# reach through it: the github mapper (to cross-check that both answer for the
# SAME ten contract fields) and _forge_map_state (to show that mapping the
# KEY `state` and normalizing GitLab's VALUE "opened" are separate jobs).
# Same "eval every helper the code under test reaches" rule
# source_cache_functions follows.
source_forge_gitlab_map_functions() {
  eval "$(sed -n '/^_forge_map_pr_field_gitlab()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_pr_field_github()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_state()/,/^}/p' "$CLI")"
}

# One realistic `glab mr view <ref> -F json` document, built from go-gitlab's
# own struct tags. Three properties matter and are load-bearing for the
# assertions below, so do not "tidy" them away:
#   - `id` (98765) DIFFERS from `iid` (42), so mapping number->id instead of
#     number->iid produces a visibly wrong number rather than an accident that
#     happens to pass.
#   - BOTH `draft` and `work_in_progress` are present, because glab marshals
#     the whole struct and really does emit both; the mapper's job is to pick
#     the non-deprecated one.
#   - There is NO file list and NO `merge_status` -- exactly as the real
#     document has neither. `changes_count` is present because the real struct
#     carries it, and it is a COUNT string, not something `files` could map to.
_fake_glab_mr_fixture_json() {
  printf '%s' '{
    "id": 98765,
    "iid": 42,
    "project_id": 321,
    "target_branch": "main",
    "source_branch": "feat/gitlab-adapter",
    "title": "Add the GitLab adapter",
    "state": "opened",
    "description": "Body text of the merge request.",
    "draft": true,
    "work_in_progress": true,
    "detailed_merge_status": "not_open",
    "web_url": "https://gitlab.com/acme/widgets/-/merge_requests/42",
    "has_conflicts": false,
    "changes_count": "3",
    "author": {"username": "octocat"},
    "reviewers": [{"username": "monalisa"}]
  }'
}

# RUNS BEFORE ANY OTHER GLAB ASSERTION, ON PURPOSE. An assertion that passes
# regardless of the code under test is not evidence, and that exact defect
# class is why phase 2's machine-account check had to be rebuilt. So before a
# single mapping assertion trusts this stub, prove the stub can turn a test
# RED: drive the identical pipeline (fake glab payload -> mapper key -> jq
# pick -> compare) twice with two different iids and show the verdict moves.
test_fake_glab_stub_can_produce_a_failing_result() {
  echo ""
  echo "=== fake glab: the stub CAN produce a failing result (falsifiability proof, runs first) ==="

  source_forge_gitlab_map_functions
  setup_fake_glab_fixture

  local key matching differing would_have_gone_red
  key=$(_forge_map_pr_field_gitlab number)

  # Payload whose iid IS the expected 42 -- the green case.
  matching=$(FAKE_GLAB_MR_JSON='{"iid":42,"id":98765}' PATH="$FAKE_GLAB_DIR:$PATH" \
    glab mr view 42 -F json | jq -r --arg k "$key" '.[$k]')

  # SAME code path, SAME mapper key, payload whose iid DIFFERS. If the
  # pipeline were insensitive to the stub's output, these two would be equal.
  differing=$(FAKE_GLAB_MR_JSON='{"iid":7,"id":98765}' PATH="$FAKE_GLAB_DIR:$PATH" \
    glab mr view 42 -F json | jq -r --arg k "$key" '.[$k]')

  assert_eq "42" "$matching" "fake glab falsifiability: the matching payload yields the expected iid (green case)"
  assert_eq "7" "$differing" "fake glab falsifiability: the differing payload yields the OTHER iid, so output really does track the fixture"

  # The proof stated as a check rather than left as a comment: had `differing`
  # been asserted against 42, assert_eq would have gone red. Written this way
  # so a future edit that makes the stub ignore FAKE_GLAB_MR_JSON fails HERE,
  # loudly, instead of quietly making every mapping assertion below vacuous.
  would_have_gone_red=no
  if [ "$differing" != "42" ]; then
    would_have_gone_red=yes
  fi
  assert_eq "yes" "$would_have_gone_red" "fake glab falsifiability: asserting the differing payload against 42 WOULD have gone red -- the stub is not a rubber stamp"

  teardown_fake_glab_fixture
}

# The stub records argv (so an assertion can prove which flags were passed,
# not merely that a call happened) and can report DIFFERING output across two
# calls (so a before/after comparison is proven able to move).
test_fake_glab_records_argv_and_can_differ_across_calls() {
  echo ""
  echo "=== fake glab: argv recording, and differing output across two calls ==="

  setup_fake_glab_fixture

  local log counter first second logged
  log=$(mktemp)
  counter=$(mktemp)
  printf '0\n' > "$counter"

  first=$(FAKE_GLAB_LOG="$log" FAKE_GLAB_CALL_COUNTER="$counter" \
    FAKE_GLAB_MR_JSON='{"iid":42}' FAKE_GLAB_MR_JSON_SECOND='{"iid":99}' \
    PATH="$FAKE_GLAB_DIR:$PATH" glab mr view 42 -F json)
  second=$(FAKE_GLAB_LOG="$log" FAKE_GLAB_CALL_COUNTER="$counter" \
    FAKE_GLAB_MR_JSON='{"iid":42}' FAKE_GLAB_MR_JSON_SECOND='{"iid":99}' \
    PATH="$FAKE_GLAB_DIR:$PATH" glab mr view 42 -F json)

  assert_eq '{"iid":42}' "$first" "fake glab two-call: first call serves FAKE_GLAB_MR_JSON"
  assert_eq '{"iid":99}' "$second" "fake glab two-call: second call serves FAKE_GLAB_MR_JSON_SECOND -- output can differ across calls"
  assert_eq "2" "$(cat "$counter")" "fake glab two-call: the counter recorded exactly two mr view invocations"

  logged=$(head -1 "$log")
  assert_eq "mr view 42 -F json" "$logged" "fake glab argv: the exact argv is recorded, proving which flags were passed"

  # glab has no gh-style `--json <field-list>` selector; `-F json` prints the
  # whole document and filtering is `--jq`. Pin that so a later story does not
  # port gh's request-a-field-list habit across by reflex.
  assert_eq "0" "$(grep -c -- '--json' "$log")" "fake glab argv: no gh-style --json field-list selector was passed (glab has none)"
  assert_eq "2" "$(grep -c -- '-F json' "$log")" "fake glab argv: both calls used glab's own -F json whole-document form"

  rm -f "$log" "$counter"
  teardown_fake_glab_fixture
}

# The mapping table itself: one assertion per contract field naming the exact
# GitLab key, plus the unmappable-field-yields-empty rule. Every key is then
# resolved against a realistic `glab mr view -F json` document served by the
# stub, so a wrong key fails twice -- once on its name, once because it picks
# nothing (or the wrong value) out of a real-shaped payload.
test_forge_map_pr_field_gitlab() {
  echo ""
  echo "=== _forge_map_pr_field_gitlab: the ten contract fields -> GitLab's own vocabulary ==="

  source_forge_gitlab_map_functions
  setup_fake_glab_fixture

  local doc out field
  doc=$(_fake_glab_mr_fixture_json)
  # Serve that fixture through the stub, so the values below are picked out of
  # something a `glab mr view -F json` call actually produced rather than out
  # of a local string the mapper never met.
  out=$(FAKE_GLAB_MR_JSON="$doc" PATH="$FAKE_GLAB_DIR:$PATH" glab mr view 42 -F json)

  # --- the exact GitLab key, one assertion per contract field --------------
  assert_eq "iid"                   "$(_forge_map_pr_field_gitlab number)"      "gitlab map: number -> iid"
  assert_eq "web_url"               "$(_forge_map_pr_field_gitlab url)"         "gitlab map: url -> web_url"
  assert_eq "title"                 "$(_forge_map_pr_field_gitlab title)"       "gitlab map: title -> title"
  assert_eq "description"           "$(_forge_map_pr_field_gitlab body)"        "gitlab map: body -> description"
  assert_eq "state"                 "$(_forge_map_pr_field_gitlab state)"       "gitlab map: state -> state"
  assert_eq "source_branch"         "$(_forge_map_pr_field_gitlab headRefName)" "gitlab map: headRefName -> source_branch"
  assert_eq "target_branch"         "$(_forge_map_pr_field_gitlab baseRefName)" "gitlab map: baseRefName -> target_branch"
  assert_eq "draft"                 "$(_forge_map_pr_field_gitlab isDraft)"     "gitlab map: isDraft -> draft (not the deprecated work_in_progress)"
  assert_eq "detailed_merge_status" "$(_forge_map_pr_field_gitlab mergeable)"   "gitlab map: mergeable -> detailed_merge_status (not the 15.6-deprecated merge_status)"

  # --- each mapped key resolves the right VALUE out of a real-shaped doc ---
  assert_eq "42"                  "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab number)" '.[$k]')"      "gitlab map: the number key picks 42 out of a glab document"
  assert_eq "https://gitlab.com/acme/widgets/-/merge_requests/42" \
                                  "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab url)" '.[$k]')"         "gitlab map: the url key picks the web URL"
  assert_eq "Add the GitLab adapter" \
                                  "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab title)" '.[$k]')"       "gitlab map: the title key picks the title"
  assert_eq "Body text of the merge request." \
                                  "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab body)" '.[$k]')"        "gitlab map: the body key picks description, not a body key GitLab does not have"
  assert_eq "opened"              "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab state)" '.[$k]')"       "gitlab map: the state key picks GitLab's raw 'opened'"
  assert_eq "feat/gitlab-adapter" "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab headRefName)" '.[$k]')" "gitlab map: the headRefName key picks source_branch"
  assert_eq "main"                "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab baseRefName)" '.[$k]')" "gitlab map: the baseRefName key picks target_branch"
  assert_eq "true"                "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab isDraft)" '.[$k]')"     "gitlab map: the isDraft key picks the draft boolean"
  assert_eq "not_open"            "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitlab mergeable)" '.[$k]')"   "gitlab map: the mergeable key picks the detailed_merge_status enum string"

  # --- an unmappable field emits NOTHING -----------------------------------
  assert_eq "" "$(_forge_map_pr_field_gitlab files)" "gitlab map: files emits nothing -- glab mr view -F json carries no changed-file list at all"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("files")')"   "gitlab map: and the document indeed has no files key that could have been mapped"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("changes")')" "gitlab map: nor a changes key -- a file list needs the separate /changes or /diffs endpoint"
  assert_eq "3" "$(printf '%s' "$out" | jq -r '.changes_count')"     "gitlab map: changes_count exists but is a COUNT string, which is why files maps to nothing rather than to it"

  assert_eq "" "$(_forge_map_pr_field_gitlab bogusField)" "gitlab map: an unknown field name emits nothing, never a pass-through to glab"
  assert_eq "" "$(_forge_map_pr_field_gitlab '')"         "gitlab map: an empty field name emits nothing"

  # `reviews` is NOT one of the ten contract fields and this story must not add
  # it. GitLab has `reviewers` (assigned) but no submitted-verdict array; that
  # is approvals, a different resource. Pin both halves.
  assert_eq "" "$(_forge_map_pr_field_gitlab reviews)" "gitlab map: reviews emits nothing -- it is not a contract field and GitLab has no submitted-verdict array"
  assert_eq "" "$(_forge_map_pr_field_github reviews)" "gitlab map: the github mapper does not answer for reviews either -- the ten-field contract is unchanged"
  assert_eq "monalisa" "$(printf '%s' "$out" | jq -r '.reviewers[0].username')" "gitlab map: the document does carry reviewers (assigned people) -- proving reviewers and reviews are genuinely different things"

  # --- the two distinctions a wrong-but-plausible key would have blurred ----
  assert_eq "98765" "$(printf '%s' "$out" | jq -r '.id')" "gitlab map: id is present and DIFFERS from iid, so number -> id would resolve to another MR"
  assert_eq "true"  "$(printf '%s' "$out" | jq -r '.id != .iid')" "gitlab map: id and iid are not interchangeable in this document"
  assert_eq "true"  "$(printf '%s' "$out" | jq -r 'has("work_in_progress")')" "gitlab map: work_in_progress IS emitted too (glab marshals the whole struct) -- draft is chosen deliberately, not by absence"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("merge_status")')" "gitlab map: merge_status is absent from the document, settling mergeable -> detailed_merge_status by absence, not preference"

  # --- key mapping and VALUE normalization are separate jobs ---------------
  assert_eq "open" "$(_forge_map_state gitlab "$(printf '%s' "$out" | jq -r '.state')")" "gitlab map: _forge_map_state folds GitLab's 'opened' value to 'open' -- the mapper names the key, not the value"

  # --- both mappers answer for exactly the same ten contract fields ---------
  local gh_field gl_field covered=0
  for field in number url title body state headRefName baseRefName files isDraft mergeable; do
    gh_field=$(_forge_map_pr_field_github "$field")
    if [ -n "$gh_field" ]; then
      covered=$((covered + 1))
    fi
  done
  assert_eq "10" "$covered" "gitlab map: the github mapper answers for all ten contract fields (the set this table had to cover)"

  covered=0
  for field in number url title body state headRefName baseRefName files isDraft mergeable; do
    gl_field=$(_forge_map_pr_field_gitlab "$field")
    if [ -n "$gl_field" ]; then
      covered=$((covered + 1))
    fi
  done
  assert_eq "9" "$covered" "gitlab map: the gitlab mapper answers for nine of the ten -- files alone is silently empty, by determination not omission"

  teardown_fake_glab_fixture
}

# ============================================================================
# Gitea PR-field Mapping Tests (phase 4 outline:01)
# ============================================================================
# Covers the gitea arm of the _forge_map_pr_field_* seam, the sibling
# _forge_map_pr_state_gitea derivation, and the `gitea)` arm added to
# _forge_pr_view_build_found.
#
# EVERY function and control variable this section introduces is prefixed
# `gtm_`/`GTM_` (Gitea Map). That is not decoration. Sibling stories in this
# same phase are editing this same file for the read verbs, the write verbs
# and the review threads, on branches none of us can see, and bash silently
# keeps the LAST definition of a duplicated function -- so three
# individually-green branches can merge into a red one. The phase-2 founding
# incident: two wave-1 stories both defined source_forge_account_functions
# and six assertions failed with exit 127 only on the merge. `gtm_` is
# verified disjoint from the existing `gla_`, `glr_`, `glt_`, `glw_` and
# `run_` prefixes here, and the siblings have reserved `gtr_`, `gtw_`, `gtt_`.
#
# tea is genuinely NOT INSTALLED on this machine. That is the phase's declared
# verification ceiling, the same one phase 3 declared for glab: the stub below
# is the only tea these tests ever see, and its payloads are modelled on
# `gitea/tea` `main` source read on 2026-08-06 rather than on a captured
# real-binary response. These tests prove WHICH arguments the adapter emits
# and HOW it parses a fixture -- never what real tea does with them.
#
# The gitea) arm added to _forge_pr_view_build_found has no production caller
# until outline:02 routes cmd_forge_pr_view, which is why every test here
# calls the functions directly rather than through the CLI, and why the
# existing `no adapter for forge "gitea"` control assertions stay green.

# A fake `tea` covering the two pull-request invocations this story needs:
# the DETAIL form `tea pulls <index> -o json` and the LIST form
# `tea pulls list ... -f <csv> -o json`. They serve from SEPARATE control
# variables on purpose -- the whole point of AC2 is that the two shapes are
# genuinely different documents, which a single shared payload variable would
# quietly erase.
#
# Written to its own `mktemp -d` and prepends nothing to PATH itself --
# callers do `PATH="$GTM_TEA_DIR:$PATH" tea …` per invocation, the same
# pattern all four fake-glab stubs above follow. Driven entirely by GTM_TEA_*
# environment variables:
#   GTM_TEA_LOG             optional file; every invocation's argv appended,
#                           one line per call -- lets an assertion prove WHICH
#                           flags were passed (`-o json` and tea's own `-f`
#                           selector, never a gh-style `--json <field-list>`)
#   GTM_TEA_DETAIL_JSON     `tea pulls <index> -o json` stdout (default '{}')
#   GTM_TEA_DETAIL_JSON_SECOND  when set together with GTM_TEA_CALL_COUNTER,
#                           stdout for the SECOND and every later detail call,
#                           so one fixture can report DIFFERING output across
#                           two calls and a before/after comparison is proven
#                           able to move rather than passing vacuously
#   GTM_TEA_CALL_COUNTER    path to a counter file incremented once per detail
#                           call; required for DETAIL_JSON_SECOND to fire
#   GTM_TEA_DETAIL_EXIT     detail-call exit code (default 0)
#   GTM_TEA_DETAIL_STDERR   stderr emitted when that exit is non-zero
#   GTM_TEA_LIST_JSON       `tea pulls list … -o json` stdout (default '[]')
gtm_setup_fake_tea_fixture() {
  GTM_TEA_DIR=$(mktemp -d)
  cat > "$GTM_TEA_DIR/tea" << 'GTM_FAKE_TEA_SCRIPT'
#!/usr/bin/env bash
if [ -n "${GTM_TEA_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GTM_TEA_LOG"
fi

case "$1" in
  pulls)
    case "$2" in
      list)
        body="${GTM_TEA_LIST_JSON:-}"
        [ -z "$body" ] && body='[]'
        printf '%s' "$body"
        exit 0
        ;;
      *)
        call=1
        if [ -n "${GTM_TEA_CALL_COUNTER:-}" ]; then
          call=$(cat "$GTM_TEA_CALL_COUNTER" 2>/dev/null || echo 0)
          call=$((call + 1))
          printf '%s\n' "$call" > "$GTM_TEA_CALL_COUNTER"
        fi
        code="${GTM_TEA_DETAIL_EXIT:-0}"
        if [ "$code" != "0" ]; then
          printf '%s' "${GTM_TEA_DETAIL_STDERR:-}" >&2
          exit "$code"
        fi
        body="${GTM_TEA_DETAIL_JSON:-}"
        if [ "$call" -gt 1 ] && [ -n "${GTM_TEA_DETAIL_JSON_SECOND:-}" ]; then
          body="$GTM_TEA_DETAIL_JSON_SECOND"
        fi
        [ -z "$body" ] && body='{}'
        printf '%s' "$body"
        exit 0
        ;;
    esac
    ;;
  *)
    echo "fake-tea: unhandled invocation: $*" >&2
    exit 127
    ;;
esac
GTM_FAKE_TEA_SCRIPT
  chmod +x "$GTM_TEA_DIR/tea"
}

# Removes the fake-tea temp dir and every GTM_TEA_* control variable, so a
# stray export never leaks into an unrelated later test. It deliberately does
# NOT unset AIMI_CONFIG_DIR: this section never sets it, and unsetting it here
# would hand the rest of part 4 back to the real ~/.config/aimi.
gtm_teardown_fake_tea_fixture() {
  rm -rf "$GTM_TEA_DIR"
  unset GTM_TEA_DIR GTM_TEA_LOG GTM_TEA_DETAIL_JSON GTM_TEA_DETAIL_JSON_SECOND \
    GTM_TEA_CALL_COUNTER GTM_TEA_DETAIL_EXIT GTM_TEA_DETAIL_STDERR GTM_TEA_LIST_JSON
}

# The DETAIL shape: `tea pulls <index> -o json` emits ONE OBJECT with TYPED
# values, built from cmd/pulls.go:29-52's purpose-built `pullData` struct.
# Four properties are load-bearing for the assertions below, so do not "tidy"
# them away:
#   - `id` (98765) DIFFERS from `index` (42), so mapping number -> id instead
#     of number -> index produces a visibly wrong number rather than an
#     accident that happens to pass.
#   - `index` is a JSON NUMBER and `mergeable`/`hasMerged` are real BOOLEANS
#     -- the typed half of the detail-vs-list split.
#   - `head` and `base` are BARE branch names with no `owner:` prefix
#     (cmd/pulls.go:174-177 uses pr.Head.Ref/pr.Base.Ref directly).
#   - There is NO `draft` key and NO per-file list anywhere in the document,
#     which is what settles isDraft/files mapping to nothing by ABSENCE in
#     the data rather than by the author's preference. `diffUrl` is present
#     because the real struct carries it, and it is a URL -- not something
#     `files` could have mapped to.
gtm_fake_tea_pull_detail_json() {
  printf '%s' '{
    "id": 98765,
    "index": 42,
    "title": "Add the Gitea adapter",
    "state": "open",
    "created": "2026-08-01T09:00:00Z",
    "updated": "2026-08-02T09:00:00Z",
    "labels": [],
    "user": "octocat",
    "body": "Body text of the pull request.",
    "assignees": [],
    "url": "https://gitea.com/acme/widgets/pulls/42",
    "base": "main",
    "head": "feat/gitea-adapter",
    "headSha": "deadbeefcafe1234567890abcdefdeadbeefcafe",
    "diffUrl": "https://gitea.com/acme/widgets/pulls/42.diff",
    "mergeable": true,
    "hasMerged": false,
    "mergedAt": null,
    "closedAt": null,
    "reviews": [],
    "comments": []
  }'
}

# The LIST shape, for the SAME pull request: `tea pulls list -o json -f <csv>`
# emits a JSON ARRAY whose keys are the --fields names SNAKE-CASED
# (modules/print/table.go:175-179) and whose every value is a JSON STRING,
# because orderedRow.MarshalJSON (:187-208) marshals a map[string]string.
# Three differences from the detail fixture above are the whole point:
#   - `"index": "42"` is a STRING where the detail document has a number, and
#     `"mergeable": "true"` a STRING where the detail document has a boolean.
#   - `head` carries an `owner:branch` prefix (formatPRHead,
#     modules/print/pull.go:83-93, prefixes the owner for a cross-fork PR).
#   - `state` is literally "merged", which the detail path never prints --
#     formatPRState (:95-100) returns it whenever pr.Merged != nil, while
#     cmd/pulls.go:33 hands back pr.State raw.
# It exists so AC2's "the adapter reads the DETAIL path" is a TEST rather
# than a comment.
gtm_fake_tea_pull_list_json() {
  printf '%s' '[
    {
      "index": "42",
      "title": "Add the Gitea adapter",
      "state": "merged",
      "url": "https://gitea.com/acme/widgets/pulls/42",
      "body": "Body text of the pull request.",
      "mergeable": "true",
      "base": "main",
      "head": "contributor:feat/gitea-adapter",
      "author": "octocat",
      "updated": "2026-08-02T09:00:00Z"
    }
  ]'
}

# Sources the gitea field mapper plus every helper the assertions below reach
# through it: the state derivation and _forge_map_state it delegates to, the
# two sibling mappers (to cross-check that all three answer over the SAME ten
# contract fields), and the whole _forge_pr_view_build_found ->
# _forge_build_pr_json -> _forge_pr_view_emit chain the envelope assertions
# drive. Same "eval every helper the code under test reaches" rule
# source_cache_functions follows -- a missing eval here surfaces as exit 127
# inside a subshell, which reads as a wrong VALUE rather than a missing
# function.
gtm_source_forge_gitea_map_functions() {
  eval "$(sed -n '/^_forge_map_pr_field_gitea()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_pr_field_gitlab()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_pr_field_github()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_pr_state_gitea()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_map_state()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_pr_view_build_found()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_build_pr_json()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_pr_view_emit()/,/^}/p' "$CLI")"
}

# RUNS BEFORE ANY OTHER GITEA ASSERTION, ON PURPOSE. An assertion that passes
# regardless of the code under test is not evidence, and this repository has
# shipped that exact defect twice. So before a single mapping assertion trusts
# this stub, prove it can turn a test RED: drive the identical pipeline (fake
# tea payload -> mapper key -> jq pick -> compare) twice with two different
# index values and show the verdict moves.
gtm_test_fake_tea_stub_can_produce_a_failing_result() {
  echo ""
  echo "=== fake tea: the stub CAN produce a failing result (falsifiability proof, runs first) ==="

  gtm_source_forge_gitea_map_functions
  gtm_setup_fake_tea_fixture

  local key matching differing would_have_gone_red
  key=$(_forge_map_pr_field_gitea number)

  # Payload whose index IS the expected 42 -- the green case.
  matching=$(GTM_TEA_DETAIL_JSON='{"index":42,"id":98765}' PATH="$GTM_TEA_DIR:$PATH" \
    tea pulls 42 -o json | jq -r --arg k "$key" '.[$k]')

  # SAME code path, SAME mapper key, payload whose index DIFFERS. If the
  # pipeline were insensitive to the stub's output, these two would be equal.
  differing=$(GTM_TEA_DETAIL_JSON='{"index":7,"id":98765}' PATH="$GTM_TEA_DIR:$PATH" \
    tea pulls 42 -o json | jq -r --arg k "$key" '.[$k]')

  assert_eq "42" "$matching" "fake tea falsifiability: the matching payload yields the expected index (green case)"
  assert_eq "7" "$differing" "fake tea falsifiability: the differing payload yields the OTHER index, so output really does track the fixture"

  # The proof stated as a check rather than left as a comment: had `differing`
  # been asserted against 42, assert_eq would have gone red. Written this way
  # so a future edit that makes the stub ignore GTM_TEA_DETAIL_JSON fails
  # HERE, loudly, instead of quietly making every assertion below vacuous.
  would_have_gone_red=no
  if [ "$differing" != "42" ]; then
    would_have_gone_red=yes
  fi
  assert_eq "yes" "$would_have_gone_red" "fake tea falsifiability: asserting the differing payload against 42 WOULD have gone red -- the stub is not a rubber stamp"

  gtm_teardown_fake_tea_fixture
}

# The mapping table itself: one assertion per contract field naming the exact
# tea key, plus the unmappable-field-yields-empty rule. Every key is then
# resolved against a real-shaped `tea pulls <index> -o json` DETAIL document
# served through the stub, so a wrong key fails twice -- once on its name,
# once because it picks nothing (or the wrong value) out of a real-shaped
# payload.
gtm_test_forge_map_pr_field_gitea() {
  echo ""
  echo "=== _forge_map_pr_field_gitea: the ten contract fields -> tea's own DETAIL vocabulary ==="

  gtm_source_forge_gitea_map_functions
  gtm_setup_fake_tea_fixture

  local doc out field
  doc=$(gtm_fake_tea_pull_detail_json)
  # Serve that fixture through the stub, so the values below are picked out of
  # something a `tea pulls 42 -o json` call actually produced rather than out
  # of a local string the mapper never met.
  out=$(GTM_TEA_DETAIL_JSON="$doc" PATH="$GTM_TEA_DIR:$PATH" tea pulls 42 -o json)

  # --- the exact tea key, one assertion per contract field -----------------
  assert_eq "index"     "$(_forge_map_pr_field_gitea number)"      "gitea map: number -> index (the per-repo number, not the instance-wide id)"
  assert_eq "url"       "$(_forge_map_pr_field_gitea url)"         "gitea map: url -> url"
  assert_eq "title"     "$(_forge_map_pr_field_gitea title)"       "gitea map: title -> title"
  assert_eq "body"      "$(_forge_map_pr_field_gitea body)"        "gitea map: body -> body (tea spells it body, unlike glab's description)"
  assert_eq "state"     "$(_forge_map_pr_field_gitea state)"       "gitea map: state -> state"
  assert_eq "head"      "$(_forge_map_pr_field_gitea headRefName)" "gitea map: headRefName -> head"
  assert_eq "base"      "$(_forge_map_pr_field_gitea baseRefName)" "gitea map: baseRefName -> base"
  assert_eq "mergeable" "$(_forge_map_pr_field_gitea mergeable)"   "gitea map: mergeable -> mergeable"

  # --- each mapped key resolves the right VALUE out of a real-shaped doc ---
  assert_eq "42" "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea number)" '.[$k]')" \
    "gitea map: the number key picks 42 out of a tea DETAIL document"
  assert_eq "https://gitea.com/acme/widgets/pulls/42" \
    "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea url)" '.[$k]')" \
    "gitea map: the url key picks the HTML URL"
  assert_eq "Add the Gitea adapter" \
    "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea title)" '.[$k]')" \
    "gitea map: the title key picks the title"
  assert_eq "Body text of the pull request." \
    "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea body)" '.[$k]')" \
    "gitea map: the body key picks body, not a description key tea does not have"
  assert_eq "open" "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea state)" '.[$k]')" \
    "gitea map: the state key picks tea's raw DETAIL state"
  assert_eq "feat/gitea-adapter" \
    "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea headRefName)" '.[$k]')" \
    "gitea map: the headRefName key picks head"
  assert_eq "main" "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea baseRefName)" '.[$k]')" \
    "gitea map: the baseRefName key picks base"
  assert_eq "true" "$(printf '%s' "$out" | jq -r --arg k "$(_forge_map_pr_field_gitea mergeable)" '.[$k]')" \
    "gitea map: the mergeable key picks the mergeable boolean"

  # --- the two capability-gated fields emit NOTHING, settled by absence ----
  assert_eq "" "$(_forge_map_pr_field_gitea files)" \
    "gitea map: files emits nothing -- diff/patch/diffUrl are URLs, not a parsed per-file list"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("files")')" \
    "gitea map: and the DETAIL document indeed has no files key that could have been mapped"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("changedFiles")')" \
    "gitea map: nor a changedFiles key -- the omission is settled by the data, not by preference"
  assert_eq "https://gitea.com/acme/widgets/pulls/42.diff" "$(printf '%s' "$out" | jq -r '.diffUrl')" \
    "gitea map: diffUrl exists but is a URL, which is exactly why files maps to nothing rather than to it"

  assert_eq "" "$(_forge_map_pr_field_gitea isDraft)" \
    "gitea map: isDraft emits nothing -- Gitea models a draft as a 'WIP: ' title prefix, not a field"
  assert_eq "false" "$(printf '%s' "$out" | jq -r 'has("draft")')" \
    "gitea map: and the DETAIL document carries no draft key at all"

  assert_eq "" "$(_forge_map_pr_field_gitea bogusField)" "gitea map: an unknown field name emits nothing, never a pass-through to tea"
  assert_eq "" "$(_forge_map_pr_field_gitea '')"         "gitea map: an empty field name emits nothing"

  # --- the distinctions a wrong-but-plausible key would have blurred -------
  assert_eq "98765" "$(printf '%s' "$out" | jq -r '.id')" \
    "gitea map: id is present and DIFFERS from index, so number -> id would resolve to another pull request"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.id != .index')" \
    "gitea map: id and index are not interchangeable in this document"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.head | contains(":")')" \
    "gitea map: the DETAIL head is a BARE branch name -- no owner: prefix, unlike the list shape"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.base | contains(":")')" \
    "gitea map: the DETAIL base is a bare branch name too"

  # --- all three mappers, measured over the same ten contract fields -------
  # Asserted together in ONE test so a later edit that quietly widens or
  # narrows the gitea table goes red against its two siblings rather than
  # drifting alone.
  local covered=0
  for field in number url title body state headRefName baseRefName files isDraft mergeable; do
    if [ -n "$(_forge_map_pr_field_github "$field")" ]; then
      covered=$((covered + 1))
    fi
  done
  assert_eq "10" "$covered" "gitea map: the github mapper answers for all ten contract fields (the set this table had to cover)"

  covered=0
  for field in number url title body state headRefName baseRefName files isDraft mergeable; do
    if [ -n "$(_forge_map_pr_field_gitlab "$field")" ]; then
      covered=$((covered + 1))
    fi
  done
  assert_eq "9" "$covered" "gitea map: the gitlab mapper answers for nine of the ten -- files alone is silently empty there"

  covered=0
  for field in number url title body state headRefName baseRefName files isDraft mergeable; do
    if [ -n "$(_forge_map_pr_field_gitea "$field")" ]; then
      covered=$((covered + 1))
    fi
  done
  assert_eq "8" "$covered" "gitea map: the gitea mapper answers for exactly eight of the ten -- files AND isDraft are silently empty, by determination not omission"

  gtm_teardown_fake_tea_fixture
}

# AC2: the detail-vs-list JSON split, pinned by test rather than only by the
# mapper's header comment. Two fixtures for the SAME pull request, proven to
# be genuinely different shapes, and then fed to the same adapter entry point
# so an implementation that pointed a gitea verb at `tea pulls list` output
# is caught here rather than shipped.
gtm_test_tea_detail_and_list_shapes_differ() {
  echo ""
  echo "=== tea DETAIL vs LIST: two shapes for one pull request, and the adapter reads DETAIL ==="

  gtm_source_forge_gitea_map_functions
  gtm_setup_fake_tea_fixture

  local log detail_doc list_doc detail_out list_out fields probe_rc
  log=$(mktemp)
  detail_doc=$(gtm_fake_tea_pull_detail_json)
  list_doc=$(gtm_fake_tea_pull_list_json)

  detail_out=$(GTM_TEA_LOG="$log" GTM_TEA_DETAIL_JSON="$detail_doc" PATH="$GTM_TEA_DIR:$PATH" \
    tea pulls 42 -o json)
  list_out=$(GTM_TEA_LOG="$log" GTM_TEA_LIST_JSON="$list_doc" PATH="$GTM_TEA_DIR:$PATH" \
    tea pulls list --state all -f index,title,state,url,body,mergeable,base,head -o json)

  # --- the two shapes are genuinely different documents --------------------
  assert_eq "object" "$(printf '%s' "$detail_out" | jq -r 'type')" "tea shapes: the DETAIL response is one object"
  assert_eq "array"  "$(printf '%s' "$list_out" | jq -r 'type')"   "tea shapes: the LIST response is an array"
  assert_eq "number" "$(printf '%s' "$detail_out" | jq -r '.index | type')"    "tea shapes: DETAIL .index is a JSON number"
  assert_eq "string" "$(printf '%s' "$list_out" | jq -r '.[0].index | type')"  "tea shapes: LIST .index is a JSON string -- every list value is stringified"
  assert_eq "boolean" "$(printf '%s' "$detail_out" | jq -r '.mergeable | type')"   "tea shapes: DETAIL .mergeable is a real boolean"
  assert_eq "string"  "$(printf '%s' "$list_out" | jq -r '.[0].mergeable | type')" "tea shapes: LIST .mergeable is the string \"true\""
  assert_eq "false" "$(printf '%s' "$detail_out" | jq -r '.head | contains(":")')"   "tea shapes: DETAIL .head carries no owner: prefix"
  assert_eq "true"  "$(printf '%s' "$list_out" | jq -r '.[0].head | contains(":")')" "tea shapes: LIST .head DOES carry an owner: prefix (formatPRHead)"
  assert_eq "open"   "$(printf '%s' "$detail_out" | jq -r '.state')"   "tea shapes: DETAIL .state is pr.State raw -- open/closed only"
  assert_eq "merged" "$(printf '%s' "$list_out" | jq -r '.[0].state')" "tea shapes: LIST .state can literally be 'merged' (formatPRState), which DETAIL never prints"

  # --- has() on an array really does fail, which is what makes the LIST
  # --- document produce an all-null pr rather than a wrong-value one -------
  probe_rc=0
  printf '%s' "$list_out" | jq -r --arg k index 'has($k)' >/dev/null 2>&1 || probe_rc=$?
  assert_eq "5" "$probe_rc" "tea shapes: jq has(\"index\") on an ARRAY exits 5 -- build_found's 2>/dev/null || present=false turns that into skip-this-field"

  # --- the adapter reads DETAIL: same call, two documents, opposite results
  fields="number,url,title,body,state,headRefName,baseRefName,files,isDraft,mergeable"
  local from_detail from_list
  from_detail=$(_forge_pr_view_build_found gitea "$detail_out" "$fields")
  from_list=$(_forge_pr_view_build_found gitea "$list_out" "$fields")

  assert_eq "0" "$(printf '%s' "$from_list" | jq -r '[.pr[] | select(. != null)] | length')" \
    "tea shapes: feeding the LIST array to build_found yields a pr whose EVERY key is null"
  assert_eq "null" "$(printf '%s' "$from_list" | jq -r '.pr.number')" "tea shapes: LIST -> .pr.number is null, not the string 42"
  assert_eq "null" "$(printf '%s' "$from_list" | jq -r '.pr.headRefName')" "tea shapes: LIST -> .pr.headRefName is null, not an owner:branch string"
  assert_eq '["files","isDraft","mergeable"]' "$(printf '%s' "$from_list" | jq -c '.unsupported_fields | sort')" \
    "tea shapes: LIST -> even mergeable is reported unsupported, because no field was resolvable at all"

  assert_eq "8" "$(printf '%s' "$from_detail" | jq -r '[.pr[] | select(. != null)] | length')" \
    "tea shapes: the DETAIL object populates eight of the ten keys -- the same call, the other shape"
  assert_eq "42" "$(printf '%s' "$from_detail" | jq -r '.pr.number')" "tea shapes: DETAIL -> .pr.number is 42"
  assert_eq "feat/gitea-adapter" "$(printf '%s' "$from_detail" | jq -r '.pr.headRefName')" "tea shapes: DETAIL -> .pr.headRefName is the bare ref"

  # --- argv: the adapter's own vocabulary reached the stub -----------------
  # The control assertion comes FIRST and MUST match, so the zero below is a
  # measurement rather than a grep that silently matched nothing.
  assert_eq "2" "$(grep -c -- '-o json' "$log")" "tea argv control: both calls carried tea's own -o json (this MUST match, so the zero below is trustworthy)"
  assert_eq "1" "$(grep -c -- ' -f index,' "$log")" "tea argv: the list call carried tea's own -f field selector"
  assert_eq "0" "$(grep -c -- '--json' "$log")" "tea argv: no gh-style --json field-list flag was passed anywhere (tea has none)"
  assert_eq "pulls 42 -o json" "$(head -1 "$log")" "tea argv: the DETAIL call is the bare index form -- tea pulls 42 -o json, no field list"

  rm -f "$log"
  gtm_teardown_fake_tea_fixture
}

# AC3: `merged` is DERIVED in the gitea adapter from hasMerged, and
# _forge_map_state gains no gitea branch for it.
gtm_test_forge_map_pr_state_gitea() {
  echo ""
  echo "=== _forge_map_pr_state_gitea: merged comes from hasMerged, never from an invented state ==="

  gtm_source_forge_gitea_map_functions

  assert_eq "merged" "$(_forge_map_pr_state_gitea '{"state":"closed","hasMerged":true,"mergedAt":"2026-08-01T10:00:00Z"}')" \
    "gitea state: hasMerged true -> merged, even though tea's own DETAIL state says closed"
  assert_eq "closed" "$(_forge_map_pr_state_gitea '{"state":"closed","hasMerged":false}')" \
    "gitea state: hasMerged false -> the raw closed, never merged"
  assert_eq "open" "$(_forge_map_pr_state_gitea '{"state":"open","hasMerged":false}')" \
    "gitea state: an open pull request passes through as open"
  assert_eq "open" "$(_forge_map_pr_state_gitea '{"state":"OPEN","hasMerged":false}')" \
    "gitea state: case-folding still comes from _forge_map_state, not from a second hand-rolled tr"
  assert_eq "closed" "$(_forge_map_pr_state_gitea '{"state":"closed"}')" \
    "gitea state: a document with NO hasMerged key passes its raw state through -- absence never becomes merged"

  # --- _forge_map_state itself is untouched by this story ------------------
  # Counting form, not `grep -q` inside an if: a fail-open guard that silently
  # matches nothing reports success. The gitlab control runs alongside and
  # MUST be non-zero, which is what makes the gitea zero a measurement.
  local state_body gitea_hits gitlab_hits
  state_body=$(mktemp)
  declare -f _forge_map_state > "$state_body"

  gitea_hits=$(grep -v '^[[:space:]]*#' "$state_body" | grep -cE 'gitea') || gitea_hits=0
  gitlab_hits=$(grep -v '^[[:space:]]*#' "$state_body" | grep -cE 'gitlab') || gitlab_hits=0

  assert_eq "1" "$gitlab_hits" "gitea state control: the identical query DOES find _forge_map_state's gitlab arm, so the zero below is a measurement"
  assert_eq "0" "$gitea_hits"  "gitea state: _forge_map_state's body contains ZERO occurrences of gitea -- the derivation lives in the adapter"

  assert_eq "closed" "$(_forge_map_state gitea closed)" "gitea state: _forge_map_state still passes gitea's closed straight through"
  assert_eq "merged" "$(_forge_map_state gitea merged)" "gitea state: _forge_map_state still passes gitea's merged straight through, case-folded and untouched"

  rm -f "$state_body"
}

# AC4: the gitea arm of _forge_pr_view_build_found produces a contract-shaped
# found envelope, with the two capability gaps REPORTED rather than guessed.
gtm_test_forge_pr_view_build_found_gitea() {
  echo ""
  echo "=== _forge_pr_view_build_found gitea: the found envelope, with capability gaps reported ==="

  gtm_source_forge_gitea_map_functions
  gtm_setup_fake_tea_fixture

  local doc out full subset
  doc=$(gtm_fake_tea_pull_detail_json)
  out=$(GTM_TEA_DETAIL_JSON="$doc" PATH="$GTM_TEA_DIR:$PATH" tea pulls 42 -o json)

  full=$(_forge_pr_view_build_found gitea "$out" \
    "number,url,title,body,state,headRefName,baseRefName,files,isDraft,mergeable")

  assert_eq "found" "$(printf '%s' "$full" | jq -r '.status')" "gitea envelope: status is found"
  assert_eq '["number","url","title","body","state","headRefName","baseRefName","files","isDraft","mergeable"]' \
    "$(printf '%s' "$full" | jq -c '.pr | keys_unsorted')" \
    "gitea envelope: pr carries exactly the ten requested names, in the order they were requested"

  assert_eq "42" "$(printf '%s' "$full" | jq -r '.pr.number')" "gitea envelope: number is 42"
  assert_eq "number" "$(printf '%s' "$full" | jq -r '.pr.number | type')" \
    "gitea envelope: number is a JSON NUMBER even though the detail value passes through tostring on the way to the builder"
  assert_eq "https://gitea.com/acme/widgets/pulls/42" "$(printf '%s' "$full" | jq -r '.pr.url')" "gitea envelope: url is tea's HTML url"
  assert_eq "open" "$(printf '%s' "$full" | jq -r '.pr.state')" "gitea envelope: state normalized through _forge_map_state gitea"
  assert_eq "feat/gitea-adapter" "$(printf '%s' "$full" | jq -r '.pr.headRefName')" "gitea envelope: headRefName is tea's bare head ref"
  assert_eq "main" "$(printf '%s' "$full" | jq -r '.pr.baseRefName')" "gitea envelope: baseRefName is tea's bare base ref"
  assert_eq "true" "$(printf '%s' "$full" | jq -r '.pr.mergeable')" "gitea envelope: mergeable is carried"
  assert_eq "string" "$(printf '%s' "$full" | jq -r '.pr.mergeable | type')" \
    "gitea envelope: mergeable is a JSON STRING (_forge_build_pr_json's --mergeable is --arg) -- a boolean here would be a contract break"

  assert_eq "null" "$(printf '%s' "$full" | jq -r '.pr.files')"   "gitea envelope: files is null"
  assert_eq "null" "$(printf '%s' "$full" | jq -r '.pr.isDraft')" "gitea envelope: isDraft is null"
  assert_eq '["files","isDraft"]' "$(printf '%s' "$full" | jq -c '.unsupported_fields | sort')" \
    "gitea envelope: the two null fields are NAMED in unsupported_fields -- never a bare unmarked null"
  assert_eq "2" "$(printf '%s' "$full" | jq -r '.unsupported_fields | length')" "gitea envelope: exactly two fields are reported unsupported"
  assert_eq "false" "$(printf '%s' "$full" | jq -r '.unsupported_fields | index("mergeable") != null')" \
    "gitea envelope: mergeable is NOT among them -- tea does expose it"

  # --- an --include-style subset still narrows correctly for gitea ---------
  subset=$(_forge_pr_view_build_found gitea "$out" "number,url,state")

  assert_eq '["number","url","state"]' "$(printf '%s' "$subset" | jq -c '.pr | keys_unsorted')" \
    "gitea envelope subset: pr carries exactly the three requested keys"
  assert_eq "[]" "$(printf '%s' "$subset" | jq -c '.unsupported_fields')" \
    "gitea envelope subset: unsupported_fields is empty -- a field the caller never asked for is not reported unsupported"
  assert_eq "array" "$(printf '%s' "$subset" | jq -r '.unsupported_fields | type')" \
    "gitea envelope subset: and it is an ARRAY, never a bare null"

  gtm_teardown_fake_tea_fixture
}

# ============================================================================
# GitLab READ-verb Routing Tests (phase 3 US-002)
# ============================================================================
# Covers exactly four verbs -- forge-pr-view, forge-issue-view,
# forge-repo-info, forge-auth-status -- routing to `glab` when _detect_forge
# reports gitlab.
#
# EVERY helper this section introduces is prefixed `glr_` (GitLab Read).
# That is not decoration. Sibling stories in this same wave are editing this
# same file for the WRITE verbs and the REVIEW-THREAD verbs, on branches none
# of us can see, and bash silently keeps the LAST definition of a duplicated
# function -- so three individually-green branches can merge into a red one.
# The prefix, plus a private `GLR_GLAB_*` control-variable namespace and a
# PRIVATE fake-glab stub rather than an edit to the shared one, is what makes
# that collision structurally impossible rather than merely unlikely.
#
# DETECTION IS NOT UNDER TEST HERE AND IS NOT MODIFIED BY THIS STORY.
# _detect_forge_classify_host (aimi-cli.sh:1836) already answers `gitlab` for
# gitlab.com and *.gitlab.com; the assertion below cites that rather than
# re-implementing it, and every fixture in this section simply relies on it.
#
# glab is genuinely NOT INSTALLED on this machine. That is the phase's
# declared verification ceiling: the stub below is the only glab these tests
# ever see, and its payloads are modelled on go-gitlab's struct tags (the
# keys glab emits, because its `-F json` path marshals the struct whole)
# rather than on a captured real-binary response. The one criterion that IS
# testable against reality here is the missing-binary degrade, and
# glr_test_gitlab_read_verbs_name_glab_when_binary_absent tests it.

# A fake `glab` covering the five invocations the four READ verbs make:
# `mr view`, `mr list`, `issue view`, `repo view`, `auth status`.
#
# DELIBERATELY SEPARATE from setup_fake_glab_fixture (phase 3 US-001), which
# serves `mr view` only. Extending that shared stub would put this story's
# edits on the same lines two sibling stories are editing right now; a
# private stub in a private variable namespace cannot collide with either.
#
# Written to a fresh temp dir and prepends nothing to PATH itself -- callers
# do `PATH="$GLR_GLAB_DIR:$PATH" ...` per invocation. Driven entirely by
# GLR_GLAB_* environment variables:
#   GLR_GLAB_LOG              optional file; every invocation's argv appended,
#                             one line per call -- lets an assertion prove
#                             WHICH flags were passed (`-F json`, never a
#                             gh-style `--json <field-list>`, which glab has
#                             no such flag for)
#   GLR_GLAB_MR_JSON          `glab mr view` stdout on exit 0 (default '{}')
#   GLR_GLAB_MR_VIEW_EXIT     `glab mr view` exit code (default 0)
#   GLR_GLAB_MR_VIEW_STDERR   stderr emitted when that exit is non-zero
#   GLR_GLAB_MR_VIEW_COUNTER  path to a counter file incremented once per
#                             `mr view` -- proves a call did or did NOT happen
#   GLR_GLAB_MR_LIST_JSON     `glab mr list` stdout on exit 0 (default '[]')
#   GLR_GLAB_MR_LIST_EXIT     `glab mr list` exit code (default 0)
#   GLR_GLAB_MR_LIST_STDERR   stderr emitted when that exit is non-zero
#   GLR_GLAB_MR_LIST_COUNTER  path to a counter file incremented once per
#                             `mr list`
#   GLR_GLAB_ISSUE_JSON       `glab issue view` stdout on exit 0 (default '{}')
#   GLR_GLAB_ISSUE_EXIT       `glab issue view` exit code (default 0)
#   GLR_GLAB_ISSUE_STDERR     stderr emitted when that exit is non-zero
#   GLR_GLAB_REPO_JSON        `glab repo view` stdout on exit 0 (default '{}')
#   GLR_GLAB_REPO_EXIT        `glab repo view` exit code (default 0)
#   GLR_GLAB_AUTH_EXIT        `glab auth status` exit code (default 0). A
#                             NON-ZERO exit is real glab's confirmed
#                             "not authenticated" answer, not a tool failure.
#   GLR_GLAB_AUTH_USER        login printed in the `as <username>` position
#   GLR_GLAB_AUTH_HOST        host printed in the status block
glr_setup_fake_glab_read_fixture() {
  GLR_GLAB_DIR=$(mktemp -d)
  cat > "$GLR_GLAB_DIR/glab" << 'GLR_FAKE_GLAB_SCRIPT'
#!/usr/bin/env bash
if [ -n "${GLR_GLAB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GLR_GLAB_LOG"
fi

glr_bump() {
  local file="$1" n
  [ -n "$file" ] || return 0
  n=$(cat "$file" 2>/dev/null || echo 0)
  printf '%s\n' "$((n + 1))" > "$file"
}

case "$1 $2" in
  "mr view")
    glr_bump "${GLR_GLAB_MR_VIEW_COUNTER:-}"
    code="${GLR_GLAB_MR_VIEW_EXIT:-0}"
    if [ "$code" != "0" ]; then
      printf '%s' "${GLR_GLAB_MR_VIEW_STDERR:-}" >&2
      exit "$code"
    fi
    body="${GLR_GLAB_MR_JSON:-}"
    [ -z "$body" ] && body='{}'
    printf '%s' "$body"
    exit 0
    ;;
  "mr list")
    glr_bump "${GLR_GLAB_MR_LIST_COUNTER:-}"
    code="${GLR_GLAB_MR_LIST_EXIT:-0}"
    if [ "$code" != "0" ]; then
      printf '%s' "${GLR_GLAB_MR_LIST_STDERR:-}" >&2
      exit "$code"
    fi
    body="${GLR_GLAB_MR_LIST_JSON:-}"
    [ -z "$body" ] && body='[]'
    printf '%s' "$body"
    exit 0
    ;;
  "issue view")
    code="${GLR_GLAB_ISSUE_EXIT:-0}"
    if [ "$code" != "0" ]; then
      printf '%s' "${GLR_GLAB_ISSUE_STDERR:-}" >&2
      exit "$code"
    fi
    body="${GLR_GLAB_ISSUE_JSON:-}"
    [ -z "$body" ] && body='{}'
    printf '%s' "$body"
    exit 0
    ;;
  "repo view")
    code="${GLR_GLAB_REPO_EXIT:-0}"
    if [ "$code" != "0" ]; then
      echo "GET https://gitlab.com/api/v4/projects/...: 404 {message: 404 Project Not Found}" >&2
      exit "$code"
    fi
    body="${GLR_GLAB_REPO_JSON:-}"
    [ -z "$body" ] && body='{}'
    printf '%s' "$body"
    exit 0
    ;;
  "auth status")
    code="${GLR_GLAB_AUTH_EXIT:-0}"
    if [ "$code" != "0" ]; then
      echo "no GitLab instances have been authenticated with glab; run 'glab auth login' to authenticate" >&2
      exit "$code"
    fi
    # Real glab prints this block through its own LogErrorf, i.e. on STDERR,
    # and has no "Active account" marker line: one instance, one login,
    # spelled `Logged in to <host> as <username> (<source>)`.
    host="${GLR_GLAB_AUTH_HOST:-gitlab.com}"
    user="${GLR_GLAB_AUTH_USER:-octogitlab}"
    {
      printf '%s\n' "$host"
      printf '  - Logged in to %s as %s (/home/u/.config/glab-cli/config.yml)\n' "$host" "$user"
      printf '  - Git operations for %s configured to use https protocol.\n' "$host"
      printf '  - Token: **************************\n'
    } >&2
    exit 0
    ;;
  *)
    echo "glr-fake-glab: unhandled invocation: $*" >&2
    exit 127
    ;;
esac
GLR_FAKE_GLAB_SCRIPT
  chmod +x "$GLR_GLAB_DIR/glab"
}

# Removes the private fake-glab temp dir and every GLR_GLAB_* control
# variable, so a stray value never leaks into an unrelated later test.
glr_teardown_fake_glab_read_fixture() {
  rm -rf "$GLR_GLAB_DIR"
  unset GLR_GLAB_DIR GLR_GLAB_LOG \
    GLR_GLAB_MR_JSON GLR_GLAB_MR_VIEW_EXIT GLR_GLAB_MR_VIEW_STDERR GLR_GLAB_MR_VIEW_COUNTER \
    GLR_GLAB_MR_LIST_JSON GLR_GLAB_MR_LIST_EXIT GLR_GLAB_MR_LIST_STDERR GLR_GLAB_MR_LIST_COUNTER \
    GLR_GLAB_ISSUE_JSON GLR_GLAB_ISSUE_EXIT GLR_GLAB_ISSUE_STDERR \
    GLR_GLAB_REPO_JSON GLR_GLAB_REPO_EXIT \
    GLR_GLAB_AUTH_EXIT GLR_GLAB_AUTH_USER GLR_GLAB_AUTH_HOST
}

# A realistic `glab mr view <ref> -F json` document. Three properties are
# load-bearing and must not be "tidied" away:
#   - `id` (98765) DIFFERS from `iid` (42), so number -> id would produce a
#     visibly wrong number instead of an accident that happens to pass.
#   - `state` is GitLab's own "opened", so the envelope's "open" can only come
#     from _forge_map_state and never from the raw document.
#   - There is NO file list and NO `merge_status`. `changes_count` is a COUNT
#     string, which is exactly why `files` maps to nothing.
glr_glab_mr_doc() {
  printf '%s' '{
    "id": 98765,
    "iid": 42,
    "project_id": 321,
    "target_branch": "main",
    "source_branch": "feat/gitlab-adapter",
    "title": "Add the GitLab adapter",
    "state": "opened",
    "description": "Body text of the merge request.",
    "draft": true,
    "work_in_progress": true,
    "detailed_merge_status": "not_open",
    "web_url": "https://gitlab.com/acme/widgets/-/merge_requests/42",
    "changes_count": "3"
  }'
}

# A realistic `glab issue view <n> -F json` document (go-gitlab *gitlab.Issue
# struct tags). `id` again differs from `iid`; `labels` is an array of plain
# STRINGS, which is how GitLab returns them and where GitHub returns objects
# carrying a `.name`.
glr_glab_issue_doc() {
  printf '%s' '{
    "id": 55501,
    "iid": 7,
    "title": "Login button does nothing",
    "description": "Steps to reproduce: click it.",
    "state": "opened",
    "web_url": "https://gitlab.com/acme/widgets/-/issues/7",
    "labels": ["bug", "frontend"],
    "user_notes_count": 4
  }'
}

# A realistic `glab repo view -F json` document (go-gitlab *gitlab.Project
# struct tags). The namespace path is deliberately NESTED (acme/tools), which
# GitHub has no equivalent of, so the owner split is exercised on the shape
# that would break a naive second-to-last-segment rule.
glr_glab_project_doc() {
  printf '%s' '{
    "id": 321,
    "name": "Widgets",
    "path": "widgets",
    "path_with_namespace": "acme/tools/widgets",
    "namespace": {"id": 9, "path": "tools", "full_path": "acme/tools"},
    "web_url": "https://gitlab.com/acme/tools/widgets"
  }'
}

# Writes a copy of aimi-cli.sh to <dest> with ONE full line replaced, and
# prints "changed" or "unchanged" so a caller can PROVE the mutation actually
# landed. A mutation test whose patch silently missed is worse than no
# mutation test: it passes for the wrong reason.
#
# Exact full-line comparison (awk `$0 == a`), never a regex, so a mutation
# cannot accidentally match a second, unrelated site.
# Usage: glr_mutate_cli <exact-line> <replacement-line> <dest>
glr_mutate_cli() {
  local anchor="$1" replacement="$2" dest="$3"
  awk -v a="$anchor" -v r="$replacement" '$0 == a { print r; next } { print }' "$CLI" > "$dest"
  chmod +x "$dest"
  if cmp -s "$CLI" "$dest"; then
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

# RUNS BEFORE ANY OTHER ASSERTION IN THIS SECTION, ON PURPOSE.
#
# An assertion that passes regardless of what the code under test does is not
# evidence. So before a single routing assertion trusts this stub, drive all
# FOUR routed verbs end to end -- real CLI, real dispatch, private fake glab
# -- twice each, with a second payload that SHOULD turn that verb's assertion
# red, and show the verdict actually moves. Each verb then records a
# would_have_gone_red flag, so a future edit that makes the stub ignore its
# own fixture fails HERE, loudly, rather than quietly making every assertion
# below vacuous.
glr_test_gitlab_read_stub_can_produce_a_failing_result() {
  echo ""
  echo "=== gitlab read verbs: the stub CAN produce a failing result, per verb (falsifiability proof, runs first) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local green red flag

  # --- forge-pr-view -------------------------------------------------------
  green=$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON='{"iid":42,"web_url":"https://gitlab.com/acme/widgets/-/merge_requests/42"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number | jq -r '.pr.number')
  red=$(GLR_GLAB_MR_LIST_JSON='[{"iid":7}]' GLR_GLAB_MR_JSON='{"iid":7,"web_url":"https://gitlab.com/acme/widgets/-/merge_requests/7"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number | jq -r '.pr.number')
  assert_eq "42" "$green" "glr falsifiability pr-view: the matching payload yields the expected number"
  assert_eq "7" "$red" "glr falsifiability pr-view: the differing payload yields the OTHER number, so the envelope really tracks glab's output"
  flag=no; [ "$red" != "42" ] && flag=yes
  assert_eq "yes" "$flag" "glr falsifiability pr-view: asserting the differing payload against 42 WOULD have gone red"

  # --- forge-issue-view ----------------------------------------------------
  green=$(GLR_GLAB_ISSUE_JSON='{"iid":7,"title":"Real title"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.data.title')
  red=$(GLR_GLAB_ISSUE_JSON='{"iid":7,"title":"Some other title"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.data.title')
  assert_eq "Real title" "$green" "glr falsifiability issue-view: the matching payload yields the expected title"
  assert_eq "Some other title" "$red" "glr falsifiability issue-view: the differing payload yields the OTHER title"
  flag=no; [ "$red" != "Real title" ] && flag=yes
  assert_eq "yes" "$flag" "glr falsifiability issue-view: asserting the differing payload against the first title WOULD have gone red"

  # --- forge-repo-info -----------------------------------------------------
  green=$(GLR_GLAB_REPO_JSON='{"path_with_namespace":"acme/tools/widgets"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info | jq -r '.data.nameWithOwner')
  red=$(GLR_GLAB_REPO_JSON='{"path_with_namespace":"other/group/gadgets"}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info | jq -r '.data.nameWithOwner')
  assert_eq "acme/tools/widgets" "$green" "glr falsifiability repo-info: the matching payload yields the expected nameWithOwner"
  assert_eq "other/group/gadgets" "$red" "glr falsifiability repo-info: the differing payload yields the OTHER nameWithOwner"
  flag=no; [ "$red" != "acme/tools/widgets" ] && flag=yes
  assert_eq "yes" "$flag" "glr falsifiability repo-info: asserting the differing payload against the first path WOULD have gone red"

  # --- forge-auth-status ---------------------------------------------------
  green=$(GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.account')
  red=$(GLR_GLAB_AUTH_USER=someone-else PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.account')
  assert_eq "octogitlab" "$green" "glr falsifiability auth-status: the matching payload yields the expected account"
  assert_eq "someone-else" "$red" "glr falsifiability auth-status: the differing payload yields the OTHER account"
  flag=no; [ "$red" != "octogitlab" ] && flag=yes
  assert_eq "yes" "$flag" "glr falsifiability auth-status: asserting the differing payload against the first account WOULD have gone red"

  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

# Detection is CITED, not re-implemented and not modified. This story changes
# no line of _detect_forge_classify_host; the assertion below simply proves
# the classification it already performs is what routes these four verbs.
glr_test_gitlab_detection_is_preexisting_and_unmodified() {
  echo ""
  echo "=== gitlab routing: detection is _detect_forge_classify_host's existing answer, unchanged by this story ==="

  eval "$(sed -n '/^_detect_forge_classify_host()/,/^}/p' "$CLI")"

  assert_eq "gitlab" "$(_detect_forge_classify_host gitlab.com)" "glr detection: gitlab.com already classifies as gitlab (aimi-cli.sh:1836), no change required by this story"
  assert_eq "gitlab" "$(_detect_forge_classify_host gitlab.example.gitlab.com)" "glr detection: a *.gitlab.com subdomain already classifies as gitlab too"
  # The CLASSIFICATION claim is unchanged and still true; only the assertion's
  # own wording was stale. Phase 4 outline:04 routed gitea's review-thread
  # verbs, so gitea is no longer "the control for every no_adapter assertion
  # in this file" -- that role passed to an unrecognized host, which is what
  # _detect_forge_classify_host answers `unknown` for.
  assert_eq "gitea" "$(_detect_forge_classify_host gitea.com)" "glr detection: gitea.com already classifies as gitea, unchanged by this story"
  assert_eq "unknown" "$(_detect_forge_classify_host git.example.com)" "glr detection: an unrecognized host classifies as unknown -- the only stand-in left for a forge with no adapter"

  # ...and the same answer arrives through the real verb, on a real fixture.
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null
  assert_eq "gitlab" "$("$CLI" detect-forge | jq -r '.forge')" "glr detection: detect-forge reports gitlab for the fixture every test below uses"
  popd >/dev/null
  teardown_detect_forge_fixture
}

glr_test_forge_pr_view_gitlab_found() {
  echo ""
  echo "=== forge-pr-view: gitlab routes to glab mr view -F json and returns the found envelope (AC1, AC2, AC3) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local doc log out
  doc=$(glr_glab_mr_doc)
  log=$(mktemp)

  # Default --include: the seven-field portable core. Exact envelope,
  # literal for literal -- the same shape the GitHub path emits, with
  # GitLab's own keys resolved through _forge_map_pr_field_gitlab and
  # GitLab's "opened" folded to "open" by _forge_map_state.
  out=$(GLR_GLAB_LOG="$log" GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON="$doc" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x)
  assert_eq '{"status":"found","pr":{"number":42,"url":"https://gitlab.com/acme/widgets/-/merge_requests/42","title":"Add the GitLab adapter","body":"Body text of the merge request.","state":"open","headRefName":"feat/gitlab-adapter","baseRefName":"main"},"unsupported_fields":[],"message":null}' \
    "$out" "gitlab pr-view: an existing merge request resolves to status=found with the exact envelope"

  # number came from iid, NOT id -- the document's id is 98765 and would have
  # resolved to a different merge request entirely.
  assert_eq "42" "$(printf '%s' "$out" | jq -r '.pr.number')" "gitlab pr-view: number is the per-project iid"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.pr.number == 98765')" "gitlab pr-view: number is NOT the instance-wide id the document also carries"
  assert_eq "open" "$(printf '%s' "$out" | jq -r '.pr.state')" "gitlab pr-view: GitLab's raw 'opened' is normalized to the contract's 'open'"

  # THE ARGV PROOF. glab has no gh-style `--json <field-list>` selector: its
  # whole output interface is `-F json` plus `--jq`. Passing gh's field list
  # to glab is the single most likely way to get this adapter wrong, so pin
  # both halves -- the flag that must be there, and the one that must not.
  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitlab pr-view argv: no gh-style --json field-list selector was passed (glab has none)"
  assert_eq "1" "$(grep -c '^mr view feat-x -F json$' "$log")" "gitlab pr-view argv: the view call is exactly 'mr view <ref> -F json', the whole-document form"
  assert_eq "1" "$(grep -c '^mr list --source-branch feat-x --all -F json$' "$log")" "gitlab pr-view argv: the existence probe is 'mr list --source-branch <ref> --all -F json'"
  assert_eq "0" "$(grep -c -- '--head ' "$log")" "gitlab pr-view argv: gh's --head flag never leaks into a glab invocation"

  # --include of the three capability-gated fields. `files` is the one the
  # gitlab mapper answers EMPTY for, and the contract's mechanism for that is
  # to report it ABSENT -- null value AND named in unsupported_fields --
  # never a guessed value.
  out=$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON="$doc" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files,isDraft,mergeable)
  assert_eq '{"status":"found","pr":{"files":null,"isDraft":true,"mergeable":"not_open"},"unsupported_fields":["files"],"message":null}' \
    "$out" "gitlab pr-view: files is reported ABSENT (null + named in unsupported_fields), isDraft and mergeable are answered"
  assert_eq "not_open" "$(printf '%s' "$out" | jq -r '.pr.mergeable')" "gitlab pr-view: mergeable carries detailed_merge_status's enum STRING, not a boolean"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.pr.isDraft')" "gitlab pr-view: isDraft comes from draft, the non-deprecated key"

  # A NUMERIC ref addresses the merge request directly, so the branch probe
  # is skipped entirely -- `--source-branch` takes a branch name, never an iid.
  local view_counter list_counter
  view_counter=$(mktemp); list_counter=$(mktemp)
  printf '0\n' > "$view_counter"; printf '0\n' > "$list_counter"
  out=$(GLR_GLAB_MR_VIEW_COUNTER="$view_counter" GLR_GLAB_MR_LIST_COUNTER="$list_counter" \
    GLR_GLAB_MR_JSON="$doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number)
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitlab pr-view numeric ref: resolves found"
  assert_eq "0" "$(cat "$list_counter")" "gitlab pr-view numeric ref: the mr list probe is skipped entirely"
  assert_eq "1" "$(cat "$view_counter")" "gitlab pr-view numeric ref: exactly one mr view call"

  rm -f "$log" "$view_counter" "$list_counter"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

glr_test_forge_pr_view_gitlab_not_found_and_error_never_conflated() {
  echo ""
  echo "=== forge-pr-view: on gitlab, a missing MR is not_found and a broken glab is error -- never conflated (AC4) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local ref="feat-x" view_counter not_found_out error_out not_found_status error_status
  view_counter=$(mktemp); printf '0\n' > "$view_counter"

  # Run 1: no merge request exists. The structural probe returns [] at exit 0
  # -- a fact in JSON, not a string in a message.
  not_found_out=$(GLR_GLAB_MR_VIEW_COUNTER="$view_counter" GLR_GLAB_MR_LIST_JSON='[]' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  # Run 2: SAME ref -- glab itself is broken (auth-shaped failure on both
  # calls). This must resolve to error. Reading it as not_found is exactly
  # the defect that lets a broken check report "no PR yet" and open a
  # duplicate.
  error_out=$(GLR_GLAB_MR_LIST_EXIT=1 GLR_GLAB_MR_LIST_STDERR="authentication failed, run glab auth login" \
    GLR_GLAB_MR_VIEW_EXIT=1 GLR_GLAB_MR_VIEW_STDERR="authentication failed, run glab auth login" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  not_found_status=$(printf '%s' "$not_found_out" | jq -r '.status')
  error_status=$(printf '%s' "$error_out" | jq -r '.status')

  assert_eq "not_found" "$not_found_status" "gitlab pr-view conflation guard: run 1 (no MR) resolves to not_found"
  assert_eq "error" "$error_status" "gitlab pr-view conflation guard: run 2 (broken glab) resolves to error"

  if [ "$not_found_status" != "$error_status" ]; then
    echo -e "${GREEN}✓${NC} gitlab pr-view conflation guard: not_found and error produce different status literals for the same ref"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} gitlab pr-view conflation guard: not_found and error produced the SAME status literal ($not_found_status) -- the exact conflation this verb exists to prevent"
    ((TESTS_FAILED++))
  fi

  assert_eq "null" "$(printf '%s' "$not_found_out" | jq -r '.pr')" "gitlab pr-view conflation guard: not_found -- pr is null"
  assert_contains "$ref" "$(printf '%s' "$not_found_out" | jq -r '.message')" "gitlab pr-view conflation guard: not_found -- message names the searched ref"
  assert_contains "merge request" "$(printf '%s' "$not_found_out" | jq -r '.message')" "gitlab pr-view conflation guard: not_found -- message uses GitLab's own vocabulary"
  assert_eq "0" "$(cat "$view_counter")" "gitlab pr-view conflation guard: a structural [] answers absence WITHOUT paying for a doomed mr view call"
  assert_contains "authentication failed" "$(printf '%s' "$error_out" | jq -r '.message')" "gitlab pr-view conflation guard: error -- message carries glab's own failure text"

  # The 404 backstop, used ONLY when the structural probe could not confirm
  # anything (here: a numeric ref, which never probes).
  local numeric_out
  numeric_out=$(GLR_GLAB_MR_VIEW_EXIT=1 GLR_GLAB_MR_VIEW_STDERR="GET .../merge_requests/999: 404 {message: 404 Not found}" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr 999)
  assert_eq "not_found" "$(printf '%s' "$numeric_out" | jq -r '.status')" "gitlab pr-view: a numeric ref glab answers 404 for resolves to not_found via the stderr backstop"

  # ...and a structurally CONFIRMED existence outranks that backstop. The
  # probe said the MR exists; mr view then failed with 404-shaped text
  # anyway. Absence has been positively DISPROVEN, so this is error.
  local confirmed_out
  confirmed_out=$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' \
    GLR_GLAB_MR_VIEW_EXIT=1 GLR_GLAB_MR_VIEW_STDERR="GET .../merge_requests/42: 404 {message: 404 Not found}" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")
  assert_eq "error" "$(printf '%s' "$confirmed_out" | jq -r '.status')" "gitlab pr-view: a probe-confirmed MR whose view fails is error, even when the stderr says 404 -- a string cannot outvote a structural fact"

  rm -f "$view_counter"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

glr_test_forge_issue_view_gitlab() {
  echo ""
  echo "=== forge-issue-view: gitlab routes to glab issue view -F json, same three-way envelope (AC5) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local doc log out
  doc=$(glr_glab_issue_doc)
  log=$(mktemp)

  out=$(GLR_GLAB_LOG="$log" GLR_GLAB_ISSUE_JSON="$doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7)

  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitlab issue-view: an existing issue resolves to status=found"
  assert_eq "7" "$(printf '%s' "$out" | jq -r '.data.number')" "gitlab issue-view: number is the per-project iid, not the instance-wide id (55501)"
  assert_eq "Login button does nothing" "$(printf '%s' "$out" | jq -r '.data.title')" "gitlab issue-view: title"
  assert_eq "Steps to reproduce: click it." "$(printf '%s' "$out" | jq -r '.data.body')" "gitlab issue-view: body comes from description, a key GitHub does not have"
  assert_eq "https://gitlab.com/acme/widgets/-/issues/7" "$(printf '%s' "$out" | jq -r '.data.url')" "gitlab issue-view: url comes from web_url"
  assert_eq "open" "$(printf '%s' "$out" | jq -r '.data.state')" "gitlab issue-view: GitLab's 'opened' is normalized to 'open'"
  assert_eq '["bug","frontend"]' "$(printf '%s' "$out" | jq -c '.data.labels')" "gitlab issue-view: labels survive GitLab's plain-string array shape"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "gitlab issue-view: found carries no message"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "gitlab issue-view: found carries no reason"

  # comments is the issue object's one capability-gated field, and GitLab's
  # discussion model does not answer the same question GitHub's flat comment
  # array does. It is reported ABSENT rather than guessed from a
  # differently-shaped resource.
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.comments')" "gitlab issue-view: comments is null"
  assert_eq '["comments"]' "$(printf '%s' "$out" | jq -c '.data.unsupported_fields')" "gitlab issue-view: ...and named in unsupported_fields -- reported absent, never guessed"

  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitlab issue-view argv: no gh-style --json field-list selector (glab has none)"
  assert_eq "1" "$(grep -c '^issue view 7 -F json$' "$log")" "gitlab issue-view argv: exactly 'issue view <n> -F json'"

  # The five contract fields this call site resolves are read out of
  # _forge_map_pr_field_gitlab rather than hard-coded here. That reuse is only
  # legitimate because GitLab spells them identically on an Issue and on a
  # MergeRequest -- pinned here so a future divergence fails loudly.
  eval "$(sed -n '/^_forge_map_pr_field_gitlab()/,/^}/p' "$CLI")"
  assert_eq "7" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitlab number)" '.[$k]')" "gitlab issue-view mapper reuse: the number key (iid) resolves on an ISSUE document too"
  assert_eq "Login button does nothing" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitlab title)" '.[$k]')" "gitlab issue-view mapper reuse: the title key resolves on an issue document"
  assert_eq "Steps to reproduce: click it." "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitlab body)" '.[$k]')" "gitlab issue-view mapper reuse: the body key (description) resolves on an issue document"
  assert_eq "https://gitlab.com/acme/widgets/-/issues/7" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitlab url)" '.[$k]')" "gitlab issue-view mapper reuse: the url key (web_url) resolves on an issue document"
  assert_eq "opened" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitlab state)" '.[$k]')" "gitlab issue-view mapper reuse: the state key resolves on an issue document"

  # not_found is a query RESULT, never a verb failure.
  local nf_out
  nf_out=$(GLR_GLAB_ISSUE_EXIT=1 GLR_GLAB_ISSUE_STDERR="GET .../issues/4242: 404 {message: 404 Not found}" \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 4242)
  assert_eq "not_found" "$(printf '%s' "$nf_out" | jq -r '.status')" "gitlab issue-view: a 404 resolves to not_found, not error"
  assert_eq "null" "$(printf '%s' "$nf_out" | jq -r '.data')" "gitlab issue-view not_found: data is null"
  assert_eq "null" "$(printf '%s' "$nf_out" | jq -r '.reason')" "gitlab issue-view not_found: reason stays null -- not_found is a result, not a degradation"

  # A genuine tool failure is classified STRUCTURALLY, by asking whether
  # there is a glab session at all -- never by matching glab's failure text.
  local unauth_out broken_out
  unauth_out=$(GLR_GLAB_ISSUE_EXIT=1 GLR_GLAB_ISSUE_STDERR="GET ...: 401 {message: 401 Unauthorized}" GLR_GLAB_AUTH_EXIT=1 \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7)
  assert_eq "error" "$(printf '%s' "$unauth_out" | jq -r '.status')" "gitlab issue-view: a non-404 failure resolves to error"
  assert_eq "not_authenticated" "$(printf '%s' "$unauth_out" | jq -r '.reason')" "gitlab issue-view: with no glab session, the reason is not_authenticated"
  assert_contains "glab issue view exited" "$(printf '%s' "$unauth_out" | jq -r '.message')" "gitlab issue-view: the message names glab, never gh"

  broken_out=$(GLR_GLAB_ISSUE_EXIT=1 GLR_GLAB_ISSUE_STDERR="dial tcp: lookup gitlab.com: no such host" GLR_GLAB_AUTH_EXIT=0 \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7)
  assert_eq "cli_failed" "$(printf '%s' "$broken_out" | jq -r '.reason')" "gitlab issue-view: WITH a valid glab session, the same shape of failure is cli_failed -- the classifier is structural, not textual"

  rm -f "$log"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

glr_test_forge_repo_info_gitlab() {
  echo ""
  echo "=== forge-repo-info: gitlab answers through glab repo view, with the local-parse tier still behind it (AC6) ==="

  glr_setup_fake_glab_read_fixture
  # The remote deliberately DISAGREES with what glab reports, so an assertion
  # on the glab tier cannot pass by accidentally matching the local parse.
  setup_detect_forge_fixture origin https://gitlab.com/remote-owner/remote-repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local doc log out
  doc=$(glr_glab_project_doc)
  log=$(mktemp)

  out=$(GLR_GLAB_LOG="$log" GLR_GLAB_REPO_JSON="$doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info)

  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitlab repo-info: status is found"
  assert_eq "glab" "$(printf '%s' "$out" | jq -r '.data.source')" "gitlab repo-info: data.source is glab -- the adapter answered, not the offline fallback"
  assert_eq "gitlab" "$(printf '%s' "$out" | jq -r '.data.forge')" "gitlab repo-info: data.forge names gitlab"
  assert_eq "gitlab.com" "$(printf '%s' "$out" | jq -r '.data.host')" "gitlab repo-info: data.host is the detected host"
  assert_eq "acme/tools" "$(printf '%s' "$out" | jq -r '.data.owner')" "gitlab repo-info: a NESTED subgroup path survives intact as the owner"
  assert_eq "widgets" "$(printf '%s' "$out" | jq -r '.data.repo')" "gitlab repo-info: repo is the last path segment"
  assert_eq "acme/tools/widgets" "$(printf '%s' "$out" | jq -r '.data.nameWithOwner')" "gitlab repo-info: nameWithOwner recomposes the full namespace path"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.owner == "remote-owner"')" "gitlab repo-info: the answer is NOT the remote-URL parse -- proving which tier actually answered"

  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitlab repo-info argv: no gh-style --json field-list selector (glab has none)"
  assert_eq "1" "$(grep -c '^repo view -F json$' "$log")" "gitlab repo-info argv: exactly 'repo view -F json'"

  # namespace.full_path + path is the equivalent recomposition, used when the
  # flattened key is absent.
  out=$(GLR_GLAB_REPO_JSON='{"path":"widgets","namespace":{"full_path":"acme/tools"}}' \
    PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info)
  assert_eq "acme/tools/widgets" "$(printf '%s' "$out" | jq -r '.data.nameWithOwner')" "gitlab repo-info: namespace.full_path + path is the equivalent fallback within the glab tier"

  # A failing glab call falls through to the offline remote-URL parse rather
  # than degrading -- the same two-tier shape the github arm has.
  out=$(GLR_GLAB_REPO_EXIT=1 PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info)
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitlab repo-info: a failing glab call still resolves found"
  assert_eq "local-parse" "$(printf '%s' "$out" | jq -r '.data.source')" "gitlab repo-info: ...through the local-parse tier"
  assert_eq "remote-owner/remote-repo" "$(printf '%s' "$out" | jq -r '.data.nameWithOwner')" "gitlab repo-info: the fallback answer comes from the remote URL"
  assert_eq "gitlab" "$(printf '%s' "$out" | jq -r '.data.forge')" "gitlab repo-info: the fallback still names gitlab as the forge"

  # A GitLab repository never shells out to gh, and vice versa.
  assert_eq "0" "$(grep -c '^repo view --json owner,name$' "$log")" "gitlab repo-info: gh's own 'repo view --json owner,name' argv never reaches glab"

  rm -f "$log"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

glr_test_forge_auth_status_gitlab() {
  echo ""
  echo "=== forge-auth-status: gitlab answers through glab auth status -- found or error, never not_found (AC6) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log out exit_code
  log=$(mktemp)

  out=$(GLR_GLAB_LOG="$log" GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "gitlab auth-status: exits 0"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitlab auth-status: the check ran, so status is found"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.authenticated')" "gitlab auth-status: data.authenticated is true"
  assert_eq "octogitlab" "$(printf '%s' "$out" | jq -r '.data.account')" "gitlab auth-status: the acting account is read from glab's 'as <username>' position"
  assert_eq "gitlab" "$(printf '%s' "$out" | jq -r '.data.forge')" "gitlab auth-status: data.forge names gitlab, so a caller printing .data.forge (open-pr.md Step 1a) renders it correctly"
  assert_eq "gitlab.com" "$(printf '%s' "$out" | jq -r '.data.host')" "gitlab auth-status: data.host is the detected host"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "gitlab auth-status: a successful check carries no reason"
  assert_eq "1" "$(grep -c '^auth status --hostname gitlab.com$' "$log")" "gitlab auth-status argv: the host is passed through --hostname, and -a/--all never is"
  assert_eq "0" "$(grep -c -- '--all' "$log")" "gitlab auth-status argv: --all is never passed (it would print every configured instance)"

  # A CONFIRMED negative is still a successful lookup: found, with
  # authenticated=false. It is NOT not_found -- forge-auth-status has no such
  # outcome, and it is not error either, because the check itself ran.
  local neg_out
  neg_out=$(GLR_GLAB_AUTH_EXIT=1 PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "found" "$(printf '%s' "$neg_out" | jq -r '.status')" "gitlab auth-status: a confirmed 'not logged in' is still status=found -- the lookup succeeded"
  assert_eq "false" "$(printf '%s' "$neg_out" | jq -r '.data.authenticated')" "gitlab auth-status: ...with data.authenticated false"
  assert_eq "null" "$(printf '%s' "$neg_out" | jq -r '.data.account')" "gitlab auth-status: ...and no acting account"
  assert_eq "null" "$(printf '%s' "$neg_out" | jq -r '.reason')" "gitlab auth-status: a confirmed negative is not a degradation, so reason stays null"

  # Its contract permits exactly two statuses. Sweep every path this verb can
  # take on gitlab and prove not_found is unreachable on all of them.
  local scenario statuses=""
  for scenario in ok unauth missing; do
    case "$scenario" in
      ok)      statuses="$statuses $(GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      unauth)  statuses="$statuses $(GLR_GLAB_AUTH_EXIT=1 PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      missing) statuses="$statuses $(PATH="$(_path_without_binary glab)" "$CLI" forge-auth-status | jq -r '.status')" ;;
    esac
  done
  assert_eq "0" "$(printf '%s' "$statuses" | grep -c 'not_found')" "gitlab auth-status: not_found never appears on ANY of its gitlab paths (its contract is found-or-error only)"
  assert_eq " found found error" "$statuses" "gitlab auth-status: the three gitlab paths are exactly found / found / error"

  rm -f "$log"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

# THE ONE CRITERION IN THIS PHASE TESTABLE AGAINST REALITY ON THIS MACHINE:
# glab genuinely is not installed, so "the binary is absent" needs no stub at
# all. _path_without_binary is used anyway so this still holds on a machine
# where a developer HAS installed glab.
glr_test_gitlab_read_verbs_name_glab_when_binary_absent() {
  echo ""
  echo "=== gitlab read verbs: with glab absent, each degrades naming glab -- never gh (AC7, phase criterion 4) ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local no_glab stderr_file="/tmp/glr_no_glab_stderr.$$"
  no_glab=$(_path_without_binary glab)

  # Sanity guard: prove the scenario is real before anything is read into it.
  # Without this, a PATH that still resolved glab would make every assertion
  # below pass for the wrong reason.
  assert_eq "no" "$(PATH="$no_glab" command -v glab >/dev/null 2>&1 && echo yes || echo no)" "glab-absent fixture: glab is genuinely unresolvable on this PATH"

  local out exit_code

  out=$(PATH="$no_glab" "$CLI" forge-pr-view --pr feat-x 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "glab absent, pr-view: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glab absent, pr-view: status is error"
  assert_contains "glab not found on PATH" "$(printf '%s' "$out" | jq -r '.message')" "glab absent, pr-view: the message names glab"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "glab absent, pr-view: the message does NOT tell a GitLab user to install gh"
  assert_eq "" "$(cat "$stderr_file")" "glab absent, pr-view: quiet degrade -- no stderr banner"

  out=$(PATH="$no_glab" "$CLI" forge-issue-view --number 7 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "glab absent, issue-view: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glab absent, issue-view: status is error"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "glab absent, issue-view: reason is cli_missing, not no_adapter -- the adapter exists, the binary does not"
  assert_contains "glab not found" "$(printf '%s' "$out" | jq -r '.message')" "glab absent, issue-view: the message names glab"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "glab absent, issue-view: the message does NOT name gh"
  assert_eq "" "$(cat "$stderr_file")" "glab absent, issue-view: quiet degrade -- no stderr banner"

  out=$(PATH="$no_glab" "$CLI" forge-auth-status 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "glab absent, auth-status: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glab absent, auth-status: status is error (the check could not run)"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "glab absent, auth-status: reason is cli_missing"
  assert_contains "glab not found on PATH" "$(printf '%s' "$out" | jq -r '.message')" "glab absent, auth-status: the message names glab"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "glab absent, auth-status: the message does NOT name gh"

  # repo-info has an offline tier, so a missing glab is not a degradation for
  # it at all -- it still answers, through local-parse.
  out=$(PATH="$no_glab" "$CLI" forge-repo-info 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "glab absent, repo-info: exits 0"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "glab absent, repo-info: still answers found -- its offline tier needs no CLI"
  assert_eq "local-parse" "$(printf '%s' "$out" | jq -r '.data.source')" "glab absent, repo-info: ...and says so through data.source"
  assert_eq "gitlab" "$(printf '%s' "$out" | jq -r '.data.forge')" "glab absent, repo-info: data.forge still names gitlab"
  assert_eq "" "$(cat "$stderr_file")" "glab absent, repo-info: quiet degrade -- no stderr banner"

  rm -f "$stderr_file"
  rm -rf "$no_glab"
  popd >/dev/null
  teardown_detect_forge_fixture
}

# ONE MUTATION PER ROUTED VERB (AC9). For each of the four, a copy of
# aimi-cli.sh has that verb's gitlab arm UNROUTED -- restoring the pre-story
# behavior in which gitlab fell through to the no-adapter / offline path --
# and a SPECIFIC, NAMED assertion is shown to go red. Four verbs, four
# distinct named assertions.
#
# Each mutation also asserts that the patch actually landed ("changed"),
# because a mutation test whose sed silently missed passes for the wrong
# reason -- the worst possible failure mode for this particular check.
glr_test_gitlab_read_verbs_mutation_matrix() {
  echo ""
  echo "=== gitlab read verbs: unrouting each verb in turn turns a specific named assertion RED (AC9) ==="

  glr_setup_fake_glab_read_fixture
  setup_detect_forge_fixture origin https://gitlab.com/remote-owner/remote-repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local mut_dir mut mr_doc issue_doc project_doc live mutant
  mut_dir=$(mktemp -d)
  mut="$mut_dir/aimi-cli.sh"
  mr_doc=$(glr_glab_mr_doc)
  issue_doc=$(glr_glab_issue_doc)
  project_doc=$(glr_glab_project_doc)

  # --- 1/4: forge-pr-view --------------------------------------------------
  # Named assertion under test:
  #   "gitlab pr-view: an existing merge request resolves to status=found"
  assert_eq "changed" "$(glr_mutate_cli '    gitlab)' '    gitlab-unrouted)' "$mut")" "MUTATION 1/4 forge-pr-view: the unroute patch landed (guards against a vacuous mutation test)"
  live=$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON="$mr_doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x | jq -r '.status')
  mutant=$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON="$mr_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-pr-view --pr feat-x | jq -r '.status')
  assert_eq "found" "$live" "MUTATION 1/4 forge-pr-view: routed, the named assertion 'an existing merge request resolves to status=found' is GREEN"
  assert_eq "error" "$mutant" "MUTATION 1/4 forge-pr-view: UNROUTED, that same named assertion goes RED -- status is error, not found"
  assert_contains "no forge-pr-view adapter" "$(GLR_GLAB_MR_LIST_JSON='[{"iid":42}]' GLR_GLAB_MR_JSON="$mr_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-pr-view --pr feat-x | jq -r '.message')" "MUTATION 1/4 forge-pr-view: the unrouted build reverts to the no-adapter message"

  # --- 2/4: forge-issue-view -----------------------------------------------
  # Named assertion under test:
  #   "gitlab issue-view: an existing issue resolves to status=found"
  assert_eq "changed" "$(glr_mutate_cli '  if [ "$forge" = "gitlab" ]; then' '  if [ "$forge" = "gitlab-unrouted" ]; then' "$mut")" "MUTATION 2/4 forge-issue-view: the unroute patch landed"
  live=$(GLR_GLAB_ISSUE_JSON="$issue_doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.status')
  mutant=$(GLR_GLAB_ISSUE_JSON="$issue_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-issue-view --number 7 | jq -r '.status')
  assert_eq "found" "$live" "MUTATION 2/4 forge-issue-view: routed, the named assertion 'an existing issue resolves to status=found' is GREEN"
  assert_eq "error" "$mutant" "MUTATION 2/4 forge-issue-view: UNROUTED, that same named assertion goes RED -- status is error, not found"
  assert_eq "no_adapter" "$(GLR_GLAB_ISSUE_JSON="$issue_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-issue-view --number 7 | jq -r '.reason')" "MUTATION 2/4 forge-issue-view: the unrouted build reverts to reason=no_adapter"

  # --- 3/4: forge-repo-info ------------------------------------------------
  # Named assertion under test:
  #   "gitlab repo-info: data.source is glab -- the adapter answered"
  assert_eq "changed" "$(glr_mutate_cli '  elif [ "$forge" = "gitlab" ] && _forge_bin_check glab quiet gitlab; then' '  elif [ "$forge" = "gitlab-unrouted" ] && _forge_bin_check glab quiet gitlab; then' "$mut")" "MUTATION 3/4 forge-repo-info: the unroute patch landed"
  live=$(GLR_GLAB_REPO_JSON="$project_doc" PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-repo-info | jq -r '.data.source')
  mutant=$(GLR_GLAB_REPO_JSON="$project_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-repo-info | jq -r '.data.source')
  assert_eq "glab" "$live" "MUTATION 3/4 forge-repo-info: routed, the named assertion 'data.source is glab' is GREEN"
  assert_eq "local-parse" "$mutant" "MUTATION 3/4 forge-repo-info: UNROUTED, that same named assertion goes RED -- data.source falls back to local-parse"
  assert_eq "remote-owner/remote-repo" "$(GLR_GLAB_REPO_JSON="$project_doc" PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-repo-info | jq -r '.data.nameWithOwner')" "MUTATION 3/4 forge-repo-info: the unrouted build answers from the remote URL, not from glab"

  # --- 4/4: forge-auth-status ----------------------------------------------
  # Named assertion under test:
  #   "gitlab auth-status: data.authenticated is true"
  assert_eq "changed" "$(glr_mutate_cli '    gitlab) adapter_bin="glab" ;;' '    gitlab-unrouted) adapter_bin="glab" ;;' "$mut")" "MUTATION 4/4 forge-auth-status: the unroute patch landed"
  live=$(GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.authenticated')
  mutant=$(GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-auth-status | jq -r '.data.authenticated')
  assert_eq "true" "$live" "MUTATION 4/4 forge-auth-status: routed, the named assertion 'data.authenticated is true' is GREEN"
  assert_eq "null" "$mutant" "MUTATION 4/4 forge-auth-status: UNROUTED, that same named assertion goes RED -- data is null, so authenticated cannot be read at all"
  assert_eq "no_adapter" "$(GLR_GLAB_AUTH_USER=octogitlab PATH="$GLR_GLAB_DIR:$PATH" bash "$mut" forge-auth-status | jq -r '.reason')" "MUTATION 4/4 forge-auth-status: the unrouted build reverts to reason=no_adapter"

  rm -rf "$mut_dir"
  popd >/dev/null
  teardown_detect_forge_fixture
  glr_teardown_fake_glab_read_fixture
}

# Pins the one guarantee _forge_capture's RETURN trap exists to make: the
# stderr scratch file it opens internally outlives NO return path -- not the
# success path, and not the failure path either. The seven gh adapters it
# replaced each cleaned up with an `rm -f` on the line after their `cat`, which
# held only for the single straight-line path each one happened to take.
#
# _forge_capture unlinks the file before it returns, so the only way to observe
# the path is to shim `mktemp` and record what it hands out. The shim records
# to a FILE rather than a variable because _forge_capture calls mktemp inside a
# command substitution, and that subshell cannot write back into this shell.
test_forge_capture_scratch_file_never_survives() {
  echo ""
  echo "=== _forge_capture: stderr scratch file survives no return path, success or failure ==="

  eval "$(sed -n '/^_forge_capture()/,/^}/p' "$CLI")"

  local scratch_log
  scratch_log=$(mktemp)
  mktemp() {
    local p
    p=$(command mktemp "$@")
    printf '%s\n' "$p" >> "$scratch_log"
    printf '%s' "$p"
  }

  # --- success path ---
  local out="" err="" rc=1 scratch first_scratch
  _forge_capture out err rc -- printf 'ok-stdout' || true
  scratch=$(tail -n1 "$scratch_log")
  first_scratch="$scratch"
  assert_eq "0" "$rc" "capture success: rc var receives the command's own exit status"
  assert_eq "ok-stdout" "$out" "capture success: stdout reaches the caller's own variable"
  assert_eq "" "$err" "capture success: stderr var is empty when the command wrote none"
  assert_eq "yes" "$([ -n "$scratch" ] && echo yes || echo no)" "capture success: the mktemp shim observed a real scratch path (guards the next assertion from passing on an empty path)"
  assert_eq "gone" "$([ -e "$scratch" ] && echo present || echo gone)" "capture success: scratch file does not survive the call"

  # --- failure path ---
  out=""; err=""; rc=0
  _forge_capture out err rc -- sh -c 'echo o; echo boom >&2; exit 7' || true
  scratch=$(tail -n1 "$scratch_log")
  assert_eq "7" "$rc" "capture failure: rc var receives the failing command's own exit status"
  assert_eq "boom" "$err" "capture failure: stderr reaches the caller's own variable"
  assert_eq "yes" "$([ -n "$scratch" ] && [ "$scratch" != "$first_scratch" ] && echo yes || echo no)" "capture failure: this call opened its own distinct scratch path, so the check below is not re-testing the first one"
  assert_eq "gone" "$([ -e "$scratch" ] && echo present || echo gone)" "capture failure: scratch file does not survive the call"

  # The RETURN trap must be gone once _forge_capture returns. bash's RETURN
  # trap is a shell-global, not a function-scoped one: a non-self-disarming one
  # stays armed and fires AGAIN on the caller's own return, where the scratch
  # path is out of scope -- a hard `unbound variable` abort under aimi-cli.sh's
  # own `set -u`. This assertion pins the self-disarm, not merely the fact that
  # today's two paths happen to clean up.
  assert_eq "" "$(trap -p RETURN)" "capture: leaves no armed RETURN trap to fire a second time on the caller's own return"

  unset -f mktemp
  rm -f "$scratch_log"
}

# ============================================================================
# _forge_account_override -- the per-invocation account override (US-005)
# ============================================================================
# The helper is a private printer, not a verb, so these tests reach it by
# sed+eval like source_forge_contract_functions does. The sourcing helper below
# is named source_forge_account_OVERRIDE_functions on purpose: this phase
# already lost a merge to a sourcing-helper NAME COLLISION -- US-001 and US-002
# each defined `source_forge_account_functions`, bash kept the last definition,
# and six assertions failed with exit 127 on the merge even though each branch
# was green alone. Both that name and `source_forge_account_store_functions`
# are already taken in this file; this one adds a third distinct name rather
# than a third definition of an existing one, and reuses the store helper
# instead of re-eval'ing what it already provides.
#
# Every scenario is offline -- throwaway local git repositories, the shared
# fake-gh PATH stub, and an AIMI_CONFIG_DIR pointed at a mktemp -d, so the real
# ~/.config/aimi/ is never read or written and no real gh credential is ever
# touched. Every assertion is unconditional, so the totals are identical
# whether or not the suite runs from a worktree.

source_forge_account_override_functions() {
  # Brings resolve_path, _aimi_config_dir, _default_branch_cache_key,
  # _forge_account_store_path and the _HAS_* globals they need.
  source_forge_account_store_functions
  eval "$(sed -n '/^_detect_forge_parse_host()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_detect_forge_select_remote_raw()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_detect_forge_read_selection()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_account_store_read()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_account_stored_entry()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_bin_check()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_auth_status_github()/,/^}/p' "$CLI")"
  # The host memo and its reader, plus the slot filler that warms it. The
  # `declare -gA` line is eval'd straight out of the CLI (the same technique
  # test_detect_forge_type_memo_is_per_directory uses for
  # _DETECT_FORGE_TYPE_MEMO) -- without it the memo lookup is an unbound-array
  # reference under `set -u`.
  eval "$(grep '^declare -gA _FORGE_ACCOUNT_HOST_MEMO' "$CLI")"
  eval "$(sed -n '/^_forge_account_host_cached()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_account_override()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_account_override_slots()/,/^}/p' "$CLI")"
}

# Creates a throwaway repository whose `origin` points at <remote-url>, plus an
# isolated config dir holding a store that already records <mode>/<login> for
# <host>. Written directly rather than through the CLI so a scenario can seed a
# host the fixture repo could not otherwise reach; the round trip through the
# real recorder is asserted separately by
# test_forge_account_override_reads_what_the_recorder_wrote.
# Usage: setup_forge_override_env <remote-url> [store-host] [mode] [login]
setup_forge_override_env() {
  local remote_url="$1" store_host="${2:-}" mode="${3:-account}" login="${4:-monalisa}"
  FORGE_OVERRIDE_TMPDIR=$(mktemp -d)
  FORGE_OVERRIDE_CONFIG="$FORGE_OVERRIDE_TMPDIR/aimi-config"
  FORGE_OVERRIDE_REPO="$FORGE_OVERRIDE_TMPDIR/repo"
  FORGE_OVERRIDE_LOG="$FORGE_OVERRIDE_TMPDIR/gh.log"
  mkdir -p "$FORGE_OVERRIDE_REPO" "$FORGE_OVERRIDE_CONFIG"
  # Created empty up front so count_override_lookups can report a real 0
  # instead of grep's "no such file" empty string.
  : > "$FORGE_OVERRIDE_LOG"
  git -C "$FORGE_OVERRIDE_REPO" init >/dev/null 2>&1
  git -C "$FORGE_OVERRIDE_REPO" remote add origin "$remote_url" >/dev/null 2>&1

  if [ -n "$store_host" ]; then
    local store
    store=$(
      cd "$FORGE_OVERRIDE_REPO" || exit 1
      export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
      _forge_account_store_path
    )
    if [ "$mode" = "active" ]; then
      jq -nc --arg host "$store_host" \
        '{($host): {mode: "active", recordedAt: "2026-01-01T00:00:00Z"}}' > "$store"
    else
      jq -nc --arg host "$store_host" --arg account "$login" \
        '{($host): {mode: "account", account: $account, recordedAt: "2026-01-01T00:00:00Z"}}' > "$store"
    fi
  fi
}

teardown_forge_override_env() {
  rm -rf "$FORGE_OVERRIDE_TMPDIR"
  unset FORGE_OVERRIDE_TMPDIR FORGE_OVERRIDE_CONFIG FORGE_OVERRIDE_REPO FORGE_OVERRIDE_LOG
}

# Evaluates `_forge_account_override <VAR>` inside the scenario repository, in a
# subshell so nothing it sets survives into the next assertion. GH_TOKEN and
# GH_ENTERPRISE_TOKEN are cleared first unless the caller passed its own -- the
# developer's real shell may export either, and an inherited one would silently
# change what the fake returns.
# Usage: run_forge_override <VAR_NAME> [VAR=value]...
run_forge_override() {
  local var="$1"
  shift
  (
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_LOG="$FORGE_OVERRIDE_LOG"
    for pair in "$@"; do
      export "$pair"
    done
    _forge_account_override "$var"
  )
}

# Counts `gh auth token` invocations recorded in the scenario's shared log.
count_override_lookups() {
  grep -c '^auth token' "$FORGE_OVERRIDE_LOG" 2>/dev/null || true
}

FAKE_TOKEN_VALUE="gho_faketoken0000000000000000000000000000"

# AC3. The mapping is not stylistic: gh honors GH_TOKEN for github.com and
# *.ghe.com only, and emitting it against a GitHub Enterprise Server host does
# not error -- it is ignored and the write succeeds attributed to the WRONG
# account. Each host below asserts BOTH slots, because "the right one carries
# the token" and "the wrong one stays empty" are two different failures.
test_forge_account_override_host_selects_the_variable() {
  echo ""
  echo "=== _forge_account_override: the host picks the variable name (GH_TOKEN vs GH_ENTERPRISE_TOKEN) ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture

  # github.com -- the ordinary case.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=github.com)" \
    "host github.com: GH_TOKEN carries the token"
  assert_eq "" \
    "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=github.com)" \
    "host github.com: GH_ENTERPRISE_TOKEN stays empty"
  assert_contains "auth token --user monalisa --hostname github.com" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "host github.com: the lookup passes --user and --hostname"
  teardown_forge_override_env

  # *.ghe.com -- GitHub Enterprise Cloud with data residency. GH_TOKEN, NOT
  # GH_ENTERPRISE_TOKEN, per `gh help environment`.
  setup_forge_override_env "https://acme.ghe.com/owner/repo.git" "acme.ghe.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=acme.ghe.com)" \
    "host acme.ghe.com: GH_TOKEN carries the token"
  assert_eq "" \
    "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=acme.ghe.com)" \
    "host acme.ghe.com: GH_ENTERPRISE_TOKEN stays empty"
  teardown_forge_override_env

  # A GitHub Enterprise SERVER host on a company domain -- the silent-failure
  # case. GH_ENTERPRISE_TOKEN is the only variable gh reads here.
  setup_forge_override_env "https://github.acme.example/owner/repo.git" "github.acme.example" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=github.acme.example)" \
    "GHES host: GH_ENTERPRISE_TOKEN carries the token"
  assert_eq "" \
    "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=github.acme.example)" \
    "GHES host: GH_TOKEN stays empty -- emitting it here would be ignored and misattribute the write"
  assert_contains "auth token --user monalisa --hostname github.acme.example" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "GHES host: the lookup still passes the real --hostname"
  teardown_forge_override_env

  # The host is lowercased before matching -- _detect_forge_parse_host already
  # does it, and an uppercase remote must not fall through to the GHES arm.
  setup_forge_override_env "https://GitHub.COM/owner/repo.git" "github.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STRICT_HOSTNAME=1 FAKE_GH_AUTH_HOST=github.com)" \
    "uppercase remote host: still classified as github.com, so GH_TOKEN carries the token"
  teardown_forge_override_env

  # Empty/unresolvable host -- the AIMI_FORGE_TYPE override path, where
  # _detect_forge emits host: null. GH_TOKEN, and --hostname omitted ENTIRELY
  # rather than passed as the four-character string "null".
  setup_forge_override_env "https://github.com/owner/repo.git"
  local no_host_out
  no_host_out=$(run_forge_override GH_TOKEN AIMI_FORGE_TYPE=github AIMI_FORGE_IDENTITY=monalisa FAKE_GH_AUTH_STATUS_MODE=multi)
  assert_eq "$FAKE_TOKEN_VALUE" "$no_host_out" "empty host: GH_TOKEN carries the token"
  assert_eq "auth token --user monalisa" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "empty host: --hostname is omitted entirely, and the literal string null never reaches gh"
  assert_eq "" \
    "$(run_forge_override GH_ENTERPRISE_TOKEN AIMI_FORGE_TYPE=github AIMI_FORGE_IDENTITY=monalisa FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "empty host: GH_ENTERPRISE_TOKEN stays empty"
  teardown_forge_override_env

  teardown_fake_gh_fixture
}

# AC7. One routed write must cost exactly ONE `gh auth token` process, and the
# opt-out must cost none at all -- both counted from the fake's own log rather
# than inferred.
test_forge_account_override_costs_nothing_when_it_has_nothing_to_do() {
  echo ""
  echo "=== _forge_account_override: zero-cost non-matching slot, zero-cost opt-out ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture

  # The slot this host does not use must return empty BEFORE any gh call.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa
  assert_eq "" "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "non-matching slot: empty"
  assert_eq "0" "$(count_override_lookups)" "non-matching slot: zero gh auth token invocations"
  assert_eq "$FAKE_TOKEN_VALUE" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "matching slot: token"
  assert_eq "1" "$(count_override_lookups)" "matching slot: exactly ONE gh auth token invocation, never two"
  teardown_forge_override_env

  # mode "active" is a real recorded answer -- deliberately use the machine
  # account -- not the absence of one. Both slots empty, no gh call at all.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" active
  assert_eq "" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "opt-out (mode active): GH_TOKEN empty -- the same call-site shape, no separate branch"
  assert_eq "" "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "opt-out (mode active): GH_ENTERPRISE_TOKEN empty"
  assert_eq "0" "$(count_override_lookups)" "opt-out (mode active): zero gh auth token invocations"
  teardown_forge_override_env

  # No answer recorded at all.
  setup_forge_override_env "https://github.com/owner/repo.git"
  assert_eq "" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "no answer recorded: GH_TOKEN empty"
  assert_eq "" "$(run_forge_override GH_ENTERPRISE_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "no answer recorded: GH_ENTERPRISE_TOKEN empty"
  assert_eq "0" "$(count_override_lookups)" "no answer recorded: zero gh auth token invocations"
  teardown_forge_override_env

  # A store entry that does not ENCODE an answer -- the rejected empty-account
  # string. Treated as "nobody answered", never as a login of "".
  setup_forge_override_env "https://github.com/owner/repo.git"
  local store
  store=$(cd "$FORGE_OVERRIDE_REPO" && AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG" _forge_account_store_path)
  printf '%s\n' '{"github.com":{"mode":"account","account":""}}' > "$store"
  assert_eq "" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "empty account string: empty override, not a lookup for the login \"\""
  assert_eq "0" "$(count_override_lookups)" "empty account string: zero gh auth token invocations"
  teardown_forge_override_env

  teardown_fake_gh_fixture
}

# AC8. Env beats store beats nothing -- the same env-over-stored convention
# AIMI_FORGE_TYPE already sets for detection.
test_forge_account_override_precedence() {
  echo ""
  echo "=== _forge_account_override: AIMI_FORGE_IDENTITY outranks the stored answer ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture

  # Env set AND store set -- env wins, and the log proves WHICH login was
  # looked up rather than just that a token came back.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_TOKEN AIMI_FORGE_IDENTITY=octocat FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "env + store: a token comes back"
  assert_eq "auth token --user octocat --hostname github.com" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "env + store: AIMI_FORGE_IDENTITY's login is the one looked up, not the stored one"
  teardown_forge_override_env

  # Env unset, store set -- the store answers.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "store only: a token comes back"
  assert_eq "auth token --user monalisa --hostname github.com" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "store only: the stored login is the one looked up"
  teardown_forge_override_env

  # Neither -- empty, and nothing is asked of gh.
  setup_forge_override_env "https://github.com/owner/repo.git"
  assert_eq "" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "neither env nor store: empty override, the machine active account acts"
  assert_eq "0" "$(count_override_lookups)" "neither env nor store: zero gh auth token invocations"
  teardown_forge_override_env

  teardown_fake_gh_fixture
}

# AC6. `gh auth token` returns the ENVIRONMENT token when one is set, so a
# lookup that inherited an ambient override would resolve to itself instead of
# to the keyring. The fake emulates that precedence, which makes this decisive:
# the ambient value comes back if and only if the clearing is missing.
test_forge_account_override_lookup_ignores_an_ambient_override() {
  echo ""
  echo "=== _forge_account_override: the lookup runs outside any ambient GH_TOKEN ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture

  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_TOKEN GH_TOKEN=ambient-token-must-not-win FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "ambient GH_TOKEN: the keyring token comes back, not the ambient value"
  teardown_forge_override_env

  setup_forge_override_env "https://github.acme.example/owner/repo.git" "github.acme.example" account monalisa
  assert_eq "$FAKE_TOKEN_VALUE" \
    "$(run_forge_override GH_ENTERPRISE_TOKEN GH_ENTERPRISE_TOKEN=ambient-enterprise-must-not-win FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "ambient GH_ENTERPRISE_TOKEN: the keyring token comes back, not the ambient value"
  teardown_forge_override_env

  teardown_fake_gh_fixture
}

# AC9. A remembered account that was later `gh auth logout`'d. The write is not
# blocked -- the same warn-and-fall-back posture _forge_bin_check established --
# but the wrong-account attribution is made visible.
test_forge_account_override_degrades_when_the_account_is_gone() {
  echo ""
  echo "=== _forge_account_override: a logged-out remembered account degrades with one visible warning ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture

  # A login the fixture's account set does not contain, which is exactly how
  # real gh answers for an account that was logged out.
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account ghost-account
  local stderr_file out rc=0
  stderr_file=$(mktemp)
  out=$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi 2>"$stderr_file") || rc=$?

  assert_eq "0" "$rc" "logged-out account: exits 0 -- the write is not blocked"
  assert_eq "" "$out" "logged-out account: prints the empty string"
  assert_eq "1" "$(wc -l < "$stderr_file" | tr -d ' ')" "logged-out account: exactly ONE stderr warning line"
  assert_contains "ghost-account" "$(cat "$stderr_file")" "logged-out account: the warning names the login"
  assert_contains "github.com" "$(cat "$stderr_file")" "logged-out account: the warning names the host"
  assert_contains "machine active account" "$(cat "$stderr_file")" \
    "logged-out account: the warning says the operation proceeds as the machine active account"

  # gh's own auth-failure stderr can echo token prefixes, so it is never
  # forwarded verbatim.
  local warning_leaks="no"
  if grep -qE 'gho_|ghp_|no oauth token found' "$stderr_file"; then
    warning_leaks="yes"
  fi
  assert_eq "no" "$warning_leaks" "logged-out account: the warning carries no token and does not forward gh's raw stderr"

  rm -f "$stderr_file"
  teardown_forge_override_env
  teardown_fake_gh_fixture
}

# AC4 + AC5. The three independent guarantees, asserted rather than argued:
# the token never reaches argv, `gh auth switch` is never invoked, and the
# machine's active account reads back byte-identical afterwards.
test_forge_account_override_leaks_nothing_and_switches_nothing() {
  echo ""
  echo "=== _forge_account_override: no token in argv, no auth switch, machine account unchanged ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture
  setup_forge_override_env "https://github.com/owner/repo.git" "github.com" account monalisa

  # The AC2 call-site shape, exercised end to end against a fake gh that
  # refuses any credential-shaped argv element -- the same scan
  # test_forge_pr_create_credential_via_env_not_argv uses, with the literal
  # `auth token` subcommand allowed through because that word IS the gh verb
  # the override itself has to call.
  cat > "$FAKE_GH_DIR/argv-scan" << 'ARGV_SCAN'
#!/usr/bin/env bash
# Logged into the same file the fake gh writes, so the argv-leak assertion
# below covers BOTH the override's own lookup and this wrapped write.
if [ -n "${FAKE_GH_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FAKE_GH_LOG"
fi
for arg in "$@"; do
  case "$arg" in
    --token|ghp_*|gho_*|*TOKEN=*) echo "credential leaked into argv: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not inherited from environment" >&2
  exit 3
fi
printf '%s' "$GH_TOKEN"
exit 0
ARGV_SCAN
  chmod +x "$FAKE_GH_DIR/argv-scan"

  local scanned rc=0
  scanned=$(
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_LOG="$FORGE_OVERRIDE_LOG"
    export FAKE_GH_AUTH_STATUS_MODE=multi
    GH_TOKEN="$(_forge_account_override GH_TOKEN)" \
    GH_ENTERPRISE_TOKEN="$(_forge_account_override GH_ENTERPRISE_TOKEN)" \
      argv-scan pr create --title "T" --base main --head feat --body "B"
  ) || rc=$?

  assert_exit_code "0" "$rc" "call-site shape: the wrapped command sees GH_TOKEN inherited and no credential in its argv"
  assert_eq "$FAKE_TOKEN_VALUE" "$scanned" "call-site shape: the wrapped command acts as the remembered account's token"

  # The single most direct statement of AC4: FAKE_GH_LOG records every gh
  # invocation's argv, so a token that reached argv ANYWHERE -- the override's
  # own lookup or the wrapped write -- would be sitting in this file.
  local argv_leak="no"
  if grep -qE 'gho_|ghp_' "$FORGE_OVERRIDE_LOG"; then
    argv_leak="yes"
  fi
  assert_eq "no" "$argv_leak" "argv scan: the token value appears in no logged argv line at all"

  # AC5.1 -- the one thing that would rewrite hosts.yml globally.
  local switched="no"
  if grep -q '^auth switch' "$FORGE_OVERRIDE_LOG"; then
    switched="yes"
  fi
  assert_eq "no" "$switched" "auth switch: never invoked"

  # AC5.2 -- structural. An export would survive the prefix assignment and be
  # visible to every later command in the same process.
  #
  # COUNTED with `grep -c`, never `grep -v ... | grep -q ...`. This suite runs
  # under `set -o pipefail`, and `grep -q` exits the instant it matches, which
  # SIGPIPEs the `grep -v` feeding it and turns the whole pipeline non-zero --
  # so the `if` reads a REAL HIT as "no hit" and the guard fails OPEN, which is
  # exactly what phase 2 found when it planted a deliberate `export` and this
  # shape stayed green. `grep -c` consumes all of its input and cannot fire
  # early; `|| hits=0` absorbs grep's exit 1 on zero matches. The whole-file
  # counterpart of this check, and its own falsifiability proof, live in
  # gla_count_token_exports / test_gla_export_guard_counts_rather_than_short_circuits.
  local override_body export_hits
  override_body=$(sed -n '/^_forge_account_override()/,/^}/p' "$CLI")
  export_hits=$(printf '%s\n' "$override_body" | grep -v '^[[:space:]]*#' | grep -cE '(export|declare -x)[[:space:]]+(GH|GITLAB|OAUTH)_') || export_hits=0
  assert_eq "0" "$export_hits" "export rule: the helper never exports a token variable process-wide"

  # AC5.3 -- before/after, in ONE shell so an export WOULD be detectable, with
  # the fake reporting the env-token account as active the way real gh does.
  local before after
  before=$(
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN=1
    _forge_auth_status_github github.com | jq -r '.account'
  )
  after=$(
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN=1
    # Prefix assignment on a FUNCTION invocation, exactly the shape story 06
    # applies to _forge_capture -- set inside, gone the moment it returns.
    _probe_wrapped_call() { :; }
    GH_TOKEN="$(_forge_account_override GH_TOKEN)" \
    GH_ENTERPRISE_TOKEN="$(_forge_account_override GH_ENTERPRISE_TOKEN)" \
      _probe_wrapped_call
    _forge_auth_status_github github.com | jq -r '.account'
  )
  assert_eq "octocat" "$before" "machine account: the keyring's active account before"
  assert_eq "$before" "$after" "machine account: byte-identical after the override was applied"

  # And the guarantee that gives that comparison teeth: with a token actually
  # in the environment the fake DOES report a different active account, so the
  # equality above is a real observation, not a fixture that cannot fail.
  local under_override
  under_override=$(
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    unset AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE GH_ENTERPRISE_TOKEN
    export PATH="$FAKE_GH_DIR:$PATH"
    export FAKE_GH_AUTH_STATUS_MODE=multi FAKE_GH_AUTH_STATUS_HONORS_ENV_TOKEN=1
    GH_TOKEN="$FAKE_TOKEN_VALUE" _forge_auth_status_github github.com | jq -r '.account'
  )
  assert_eq "env-token-account" "$under_override" \
    "machine account: the fixture CAN report a different active account under a leaked token -- the before/after check is not vacuous"

  teardown_forge_override_env
  teardown_fake_gh_fixture
}

# The store key must match on both sides. The recorder keys by
# _forge_account_host (a jq read of _detect_forge's envelope); the override
# derives the host jq-free through _detect_forge_read_selection +
# _detect_forge_parse_host. They are the same string today, and this asserts it
# end to end rather than by reading both implementations.
test_forge_account_override_reads_what_the_recorder_wrote() {
  echo ""
  echo "=== _forge_account_override: reads back exactly what forge-account-select recorded ==="

  source_forge_account_override_functions
  setup_fake_gh_fixture
  setup_forge_override_env "https://github.com/owner/repo.git"

  # Recorded through the real verb, as a subprocess -- no hand-written store.
  local recorded
  recorded=$(
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH" FAKE_GH_AUTH_STATUS_MODE=multi
    "$CLI" forge-account-select --record monalisa | jq -r '.stored.account'
  )
  assert_eq "monalisa" "$recorded" "round trip: the verb recorded the login"
  assert_eq "$FAKE_TOKEN_VALUE" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "round trip: the override finds that answer under the same host key"
  assert_contains "auth token --user monalisa" "$(cat "$FORGE_OVERRIDE_LOG")" \
    "round trip: the login the override looked up is the one the verb recorded"

  # And revoking it puts the override back to empty, with no gh call.
  : > "$FORGE_OVERRIDE_LOG"
  (
    cd "$FORGE_OVERRIDE_REPO" || exit 1
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export AIMI_CONFIG_DIR="$FORGE_OVERRIDE_CONFIG"
    export PATH="$FAKE_GH_DIR:$PATH" FAKE_GH_AUTH_STATUS_MODE=multi
    "$CLI" forge-account-select --reselect >/dev/null
  )
  assert_eq "" "$(run_forge_override GH_TOKEN FAKE_GH_AUTH_STATUS_MODE=multi)" \
    "round trip: after --reselect the override is empty again"
  assert_eq "0" "$(count_override_lookups)" "round trip: after --reselect no gh auth token invocation happens"

  teardown_forge_override_env
  teardown_fake_gh_fixture
}

# ============================================================================
# Routing the four forge write paths through the account override (US-006)
# ============================================================================
# These drive the REAL CLI as a subprocess, one write verb per run, rather than
# sed+eval'ing the write functions into this shell. Two reasons, both learned in
# this phase: a fourth sourcing helper would be a fourth chance at the name
# collision that already cost US-001/US-002 six assertions, and a subprocess run
# additionally exercises the dispatcher arm that reaches each verb.
#
# Every scenario is offline: a throwaway local git repository, an AIMI_CONFIG_DIR
# pointed at a mktemp -d so the real ~/.config/aimi/ is never touched, and a
# hermetic PATH sandbox whose only `gh` is the heredoc written below.

# One scenario: repo + isolated config dir + PATH sandbox + a gh log.
setup_forge_routing_env() {
  FORGE_ROUTING_TMPDIR=$(mktemp -d)
  FORGE_ROUTING_CONFIG="$FORGE_ROUTING_TMPDIR/aimi-config"
  FORGE_ROUTING_REPO="$FORGE_ROUTING_TMPDIR/repo"
  FORGE_ROUTING_LOG="$FORGE_ROUTING_TMPDIR/gh.log"
  FORGE_ROUTING_SANDBOX=$(setup_forge_cli_sandbox)
  mkdir -p "$FORGE_ROUTING_REPO" "$FORGE_ROUTING_CONFIG"
  # Created empty up front so a "no such line" assertion reads a real empty
  # file rather than grep's file-missing error.
  : > "$FORGE_ROUTING_LOG"
  git -C "$FORGE_ROUTING_REPO" init >/dev/null 2>&1
  git -C "$FORGE_ROUTING_REPO" remote add origin "${1:-https://github.com/owner/repo.git}" >/dev/null 2>&1
  write_forge_routing_fake_gh
}

teardown_forge_routing_env() {
  teardown_forge_cli_sandbox "$FORGE_ROUTING_SANDBOX"
  rm -rf "$FORGE_ROUTING_TMPDIR"
  unset FORGE_ROUTING_TMPDIR FORGE_ROUTING_CONFIG FORGE_ROUTING_REPO FORGE_ROUTING_LOG \
    FORGE_ROUTING_SANDBOX
}

FORGE_ROUTING_TOKEN="gho_routingfake000000000000000000000000"

# The one fake `gh` every scenario below shares. Its defining behavior is the
# log line it writes on EVERY invocation: "<verb> <subverb> <the token that
# actually arrived>". That is what turns "the override reached this call site"
# from an argument into an observation, per call site, including the ones a
# write makes indirectly through forge-pr-view.
#
# `auth status` reads its answer from a STATE FILE and `auth switch` is the only
# arm that rewrites it -- the same division real gh has, and the reason the
# machine-account before/after check below is not vacuous. It also reports the
# ENV-TOKEN account as active whenever a token is in the environment, which is
# what real gh does and what would expose a process-wide export.
write_forge_routing_fake_gh() {
  cat > "$FORGE_ROUTING_SANDBOX/gh" << 'ROUTING_FAKE_GH'
#!/usr/bin/env bash
HERE="$(dirname "$0")"
STATE="$HERE/gh-active-account"
CREATED_FLAG="$HERE/pr-created.flag"

if [ -n "${FORGE_ROUTING_LOG:-}" ]; then
  printf '%s %s %s\n' "$1" "$2" "${GH_TOKEN:-<unset>}" >> "$FORGE_ROUTING_LOG"
fi

active="octocat"
if [ -f "$STATE" ]; then
  active=$(cat "$STATE")
fi

case "$1 $2" in
  "auth token")
    # Real gh hands back the ENVIRONMENT token when one is set, which is exactly
    # why _forge_account_override clears both slots for its own lookup. Emulated
    # so a missing clear would be visible rather than inferred.
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s\n' "$GH_TOKEN"; exit 0; fi
    if [ -n "${GH_ENTERPRISE_TOKEN:-}" ]; then printf '%s\n' "$GH_ENTERPRISE_TOKEN"; exit 0; fi
    printf '%s\n' "gho_routingfake000000000000000000000000"
    exit 0
    ;;
  "auth switch")
    # Present ONLY so the before/after check can be shown to be capable of
    # failing. Nothing in aimi-cli.sh may ever reach this arm.
    want=""
    expect=""
    for arg in "$@"; do
      if [ "$expect" = "user" ]; then want="$arg"; expect=""; continue; fi
      [ "$arg" = "--user" ] && expect="user"
    done
    printf '%s' "${want:-octocat}" > "$STATE"
    exit 0
    ;;
  "auth status")
    if [ -n "${GH_TOKEN:-}" ] || [ -n "${GH_ENTERPRISE_TOKEN:-}" ]; then
      echo "github.com"
      echo "  Logged in to github.com account env-token-account (GH_TOKEN)"
      echo "  - Active account: true"
      echo "  Logged in to github.com account $active (keyring)"
      echo "  - Active account: false"
      exit 0
    fi
    echo "github.com"
    echo "  Logged in to github.com account monalisa (keyring)"
    echo "  - Active account: false"
    echo "  Logged in to github.com account $active (keyring)"
    echo "  - Active account: true"
    exit 0
    ;;
  "pr list")
    if [ -f "$CREATED_FLAG" ]; then echo '[{"number":101}]'; else echo '[]'; fi
    exit 0
    ;;
  "pr view")
    echo '{"url":"https://github.com/owner/repo/pull/101","number":101}'
    exit 0
    ;;
  "pr create")
    : > "$CREATED_FLAG"
    echo "https://github.com/owner/repo/pull/101"
    exit 0
    ;;
  "pr edit")
    exit 0
    ;;
  "issue create")
    echo "https://github.com/owner/repo/issues/77"
    exit 0
    ;;
  "api graphql")
    echo '{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_1","isResolved":true,"path":"a.txt","line":1}}}}'
    exit 0
    ;;
esac
echo "routing fake gh: unhandled invocation: $*" >&2
exit 99
ROUTING_FAKE_GH
  chmod +x "$FORGE_ROUTING_SANDBOX/gh"
}

# Runs the real CLI inside the scenario repo, on the sandbox PATH ALONE, with
# every ambient forge variable cleared. Extra VAR=value pairs are exported first.
# Usage: run_forge_routing_cli [VAR=value]... -- <cli args>...
run_forge_routing_cli() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift
  (
    cd "$FORGE_ROUTING_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export AIMI_CONFIG_DIR="$FORGE_ROUTING_CONFIG"
    export FORGE_ROUTING_LOG="$FORGE_ROUTING_LOG"
    export PATH="$FORGE_ROUTING_SANDBOX"
    local pair
    for pair in ${envs[@]+"${envs[@]}"}; do
      export "$pair"
    done
    "$CLI" "$@"
  )
}

# Records this repository's answer through the REAL verb -- never a hand-written
# store file -- so the routing tests read back exactly what the recorder wrote,
# under whatever store key the recorder chose.
#
# The ONE step that runs with the sandbox PREPENDED to the real PATH rather than
# replacing it: the store's write path needs date/mkdir/chmod/mv/flock, and
# widening the shared sandbox allowlist to cover a write path no forge verb
# takes would change what its twenty-odd other callers exercise. The fake gh
# still wins (the sandbox comes first), and the store FILENAME is identical
# either way -- _default_branch_cache_key hashes with sha256sum on both sides,
# which is exactly why sha256sum/shasum/awk had to join the allowlist.
# Usage: record_forge_routing_account (--record <login> | --record-active)
record_forge_routing_account() {
  (
    cd "$FORGE_ROUTING_REPO" || exit 1
    unset GH_TOKEN GH_ENTERPRISE_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export AIMI_CONFIG_DIR="$FORGE_ROUTING_CONFIG"
    export FORGE_ROUTING_LOG="$FORGE_ROUTING_LOG"
    export PATH="$FORGE_ROUTING_SANDBOX:$PATH"
    "$CLI" forge-account-select "$@"
  ) >/dev/null
}

# The token recorded on each logged line for <verb> <subverb>, one per line.
# Usage: forge_routing_tokens_for "pr create"
forge_routing_tokens_for() {
  grep "^$1 " "$FORGE_ROUTING_LOG" | sed "s/^$1 //" | tr '\n' ',' | sed 's/,$//'
}

# AC1/AC2/AC3/AC4 + the in-operation reads: every one of the seven routed sites
# is asserted by the token that actually arrived at gh, verb by verb, from a log
# the fake writes itself. A site that silently stopped being routed shows up
# here as <unset>, not as a passing test.
test_forge_write_paths_route_the_recorded_account() {
  echo ""
  echo "=== forge writes: all four write paths and their in-operation reads run as the recorded account ==="

  setup_forge_routing_env
  record_forge_routing_account --record monalisa

  local tok="$FORGE_ROUTING_TOKEN"

  # --- WRITE 1: create PR, plus its idempotency check and post-create re-read.
  : > "$FORGE_ROUTING_LOG"
  local out exit_code
  out=$(run_forge_routing_cli -- forge-pr-create --title "T" --base main --head feat-x --body "B") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "routed pr-create: exit 0"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "routed pr-create: really took the create-succeeds path"
  assert_eq "$tok" "$(forge_routing_tokens_for 'pr create')" "routed pr-create: the WRITE itself carried the recorded account's token"
  assert_eq "$tok,$tok" "$(forge_routing_tokens_for 'pr list')" "routed pr-create: BOTH in-operation pr list probes carried it -- the idempotency check and the post-create re-read"
  assert_eq "$tok" "$(forge_routing_tokens_for 'pr view')" "routed pr-create: the post-create structured re-read carried it too (a private repo would 404 this read on the machine account)"
  # The lookup that MINTS the token must not itself run under one, or it
  # resolves to whatever was already in the environment instead of the keyring.
  assert_eq "<unset>" "$(forge_routing_tokens_for 'auth token')" "routed pr-create: the override's own lookup ran with both slots cleared"

  # --- WRITE 2: edit PR, plus its post-edit re-read.
  : > "$FORGE_ROUTING_LOG"
  out=$(run_forge_routing_cli -- forge-pr-edit --number 101 --body "new body") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "routed pr-edit: exit 0"
  assert_eq "$tok" "$(forge_routing_tokens_for 'pr edit')" "routed pr-edit: the WRITE itself carried the recorded account's token"
  assert_eq "$tok" "$(forge_routing_tokens_for 'pr view')" "routed pr-edit: the post-edit re-read carried it"

  # --- WRITE 3: create issue.
  : > "$FORGE_ROUTING_LOG"
  out=$(run_forge_routing_cli -- forge-issue-create --title "T" --body "B") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "routed issue-create: exit 0 (soft-fail verb, always 0)"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "routed issue-create: really created"
  assert_eq "$tok" "$(forge_routing_tokens_for 'issue create')" "routed issue-create: the WRITE carried the recorded account's token"

  # --- WRITE 4: resolve review thread.
  : > "$FORGE_ROUTING_LOG"
  out=$(run_forge_routing_cli -- forge-resolve-review-thread --thread-id PRRT_kwDOABC123) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "routed resolve-review-thread: exit 0"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.resolved')" "routed resolve-review-thread: the mutation really ran"
  assert_eq "$tok" "$(forge_routing_tokens_for 'api graphql')" "routed resolve-review-thread: the resolveReviewThread mutation carried the recorded account's token"

  # --- NEGATIVE SCOPE: forge-pr-view invoked directly as its OWN verb stays a
  # plain machine-account read. Only the reads made INSIDE a write inherit
  # anything, and this is the assertion that keeps that distinction honest.
  : > "$FORGE_ROUTING_LOG"
  out=$(run_forge_routing_cli -- forge-pr-view --pr feat-x --include url,number) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "unrouted pr-view verb: exit 0"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "unrouted pr-view verb: really performed the lookup"
  assert_eq "<unset>" "$(forge_routing_tokens_for 'pr list')" "unrouted pr-view verb: the list probe carried no token -- the verb is still a pure reader"
  assert_eq "<unset>" "$(forge_routing_tokens_for 'pr view')" "unrouted pr-view verb: the view call carried no token either"
  assert_eq "" "$(forge_routing_tokens_for 'auth token')" "unrouted pr-view verb: no account lookup happened at all, so the store was never even read"

  teardown_forge_routing_env
}

# Criterion 6, end to end and NOT vacuous: the machine's active account is read
# before and after, from the same persisted place real gh keeps it, and the
# fixture is shown to be capable of reporting a change.
test_forge_writes_leave_the_machine_account_unchanged() {
  echo ""
  echo "=== forge writes: the machine's active account is byte-identical before and after, and no auth switch is ever called ==="

  setup_forge_routing_env
  record_forge_routing_account --record monalisa

  local before after
  before=$(run_forge_routing_cli -- forge-auth-status | jq -r '.data.account')
  assert_eq "octocat" "$before" "machine account before: the keyring's active account, read with no override in effect"

  : > "$FORGE_ROUTING_LOG"
  run_forge_routing_cli -- forge-pr-create --title T --base main --head feat-x --body B >/dev/null
  run_forge_routing_cli -- forge-pr-edit --number 101 --body B2 >/dev/null
  run_forge_routing_cli -- forge-issue-create --title T --body B >/dev/null
  run_forge_routing_cli -- forge-resolve-review-thread --thread-id PRRT_kwDOABC123 >/dev/null

  after=$(run_forge_routing_cli -- forge-auth-status | jq -r '.data.account')
  assert_eq "$before" "$after" "machine account after: byte-identical once all four write verbs have run under a DIFFERENT recorded account"

  # `gh auth switch` is the only command that rewrites gh's active-account
  # pointer, and this phase must never call it.
  local switched="no"
  if grep -q '^auth switch' "$FORGE_ROUTING_LOG"; then switched="yes"; fi
  assert_eq "no" "$switched" "machine account: no write path invoked gh auth switch"

  # THE PROOF THAT THE COMPARISON CAN FAIL. Without this the assertion above
  # would pass against a fixture with no active-account state at all.
  ( cd "$FORGE_ROUTING_REPO" && PATH="$FORGE_ROUTING_SANDBOX" gh auth switch --user monalisa >/dev/null )
  local after_switch
  after_switch=$(run_forge_routing_cli -- forge-auth-status | jq -r '.data.account')
  assert_eq "monalisa" "$after_switch" "machine account: the fixture DOES report a different account once something actually switches it -- the before/after check is not vacuous"

  # And the second half of the same guarantee: a token that leaked into the
  # environment process-wide makes the very same read report the env-token
  # account, which is what `export` would have caused.
  local under_leak
  under_leak=$(run_forge_routing_cli "GH_TOKEN=$FORGE_ROUTING_TOKEN" -- forge-auth-status | jq -r '.data.account')
  assert_eq "env-token-account" "$under_leak" "machine account: a process-wide token WOULD be visible to forge-auth-status -- which is why the override is only ever a prefix assignment"

  teardown_forge_routing_env
}

# The "always use whichever account is active" answer is a real recorded answer,
# and it must flow through the identical call-site shape with no branch of its
# own -- and, critically, must not BLANK a token the caller exported.
test_forge_writes_active_account_answer_needs_no_branch() {
  echo ""
  echo "=== forge writes: the active-account answer and an inherited GH_TOKEN both flow through the identical shape ==="

  setup_forge_routing_env
  record_forge_routing_account --record-active

  : > "$FORGE_ROUTING_LOG"
  local out exit_code
  out=$(run_forge_routing_cli -- forge-pr-create --title T --base main --head feat-x --body B) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "active-account answer: forge-pr-create still succeeds"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "active-account answer: the write really happened"
  assert_eq "<unset>" "$(forge_routing_tokens_for 'pr create')" "active-account answer: no token is emitted, so gh acts as the machine's active account"
  assert_eq "" "$(forge_routing_tokens_for 'auth token')" "active-account answer: zero gh auth token invocations -- the opt-out costs nothing"

  # An inherited GH_TOKEN is how gh decides the acting account when this
  # repository has no answer of its own. The empty override must not revoke it:
  # a bare GH_TOKEN="$empty" prefix would, silently.
  #
  # The flag the run above dropped is cleared first so this second create takes
  # the same no-existing-PR path rather than the idempotent short-circuit.
  rm -f "$FORGE_ROUTING_SANDBOX/pr-created.flag"
  : > "$FORGE_ROUTING_LOG"
  out=$(run_forge_routing_cli "GH_TOKEN=caller-exported-token" -- forge-pr-create --title T --base main --head feat-y --body B) && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "inherited token: forge-pr-create still succeeds"
  assert_eq "caller-exported-token" "$(forge_routing_tokens_for 'pr create')" "inherited token: an empty override leaves a caller-exported GH_TOKEN reaching gh untouched, never blanked"

  # Structural half of the same criterion: the shape is literally identical at
  # every routed site, so there is no empty-override special case to drift.
  local routed_sites
  routed_sites=$(grep -c 'GH_TOKEN="\$gh_token_override" GH_ENTERPRISE_TOKEN="\$ghe_token_override"' "$CLI") || routed_sites=0
  assert_eq "8" "$routed_sites" "identical shape: exactly 8 prefix-assignment sites -- 4 writes, 3 in-operation reads, 1 in-write failure classifier"

  # And no process-wide export of either variable anywhere in the file, not
  # merely inside the override helper.
  #
  # COUNTED, NEVER `grep -q`, and that is not a style choice: this suite runs
  # under `set -o pipefail`, and `grep -v ... | grep -q ...` makes the right
  # half exit the instant it matches, which SIGPIPEs the left half and turns
  # the whole pipeline non-zero -- so an `if` on it reads a real hit as "no
  # hit" and the guard fails OPEN. Verified by mutation: an `export
  # GH_TOKEN="$gh_token_override"` planted in _forge_pr_create left the
  # `grep -q` form entirely green. `grep -c` consumes all of its input, so it
  # cannot fire early, and `|| hits=0` absorbs grep's exit 1 on zero matches.
  local export_hits
  export_hits=$(grep -v '^[[:space:]]*#' "$CLI" | grep -cE '(export|declare -x)[[:space:]]+GH_(TOKEN|ENTERPRISE_TOKEN)') || export_hits=0
  assert_eq "0" "$export_hits" "export rule: aimi-cli.sh never exports GH_TOKEN or GH_ENTERPRISE_TOKEN process-wide, anywhere -- a prefix assignment is the only permitted form"

  teardown_forge_routing_env
}

# The classifier seam US-005 recorded and left for the routing pass. Exactly one
# _forge_classify_gh_failure_reason call sits inside a write path; left unrouted
# it would re-check the MACHINE account after a mutation failed as a DIFFERENT
# one.
test_forge_resolve_review_thread_classifier_runs_under_the_override() {
  echo ""
  echo "=== forge-resolve-review-thread: the in-write failure classifier re-checks the account that actually failed ==="

  setup_forge_routing_env
  record_forge_routing_account --record monalisa

  # The mutation breaks in a way that is NOT the confirmed-invalid-node case, so
  # the generic branch runs and the classifier is reached.
  cat > "$FORGE_ROUTING_SANDBOX/gh" << 'CLASSIFIER_FAKE_GH'
#!/usr/bin/env bash
if [ -n "${FORGE_ROUTING_LOG:-}" ]; then
  printf '%s %s %s\n' "$1" "$2" "${GH_TOKEN:-<unset>}" >> "$FORGE_ROUTING_LOG"
fi
case "$1 $2" in
  "auth token")
    if [ -n "${GH_TOKEN:-}" ]; then printf '%s\n' "$GH_TOKEN"; exit 0; fi
    printf '%s\n' "gho_routingfake000000000000000000000000"
    exit 0
    ;;
  "api graphql")
    echo "gh: connection refused" >&2
    exit 1
    ;;
  "auth status")
    echo "github.com"
    echo "  Logged in to github.com account octocat (keyring)"
    echo "  - Active account: true"
    exit 0
    ;;
esac
exit 99
CLASSIFIER_FAKE_GH
  chmod +x "$FORGE_ROUTING_SANDBOX/gh"

  : > "$FORGE_ROUTING_LOG"
  local out exit_code
  out=$(run_forge_routing_cli -- forge-resolve-review-thread --thread-id PRRT_kwDOABC123 2>/dev/null) && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "classifier seam: the verb still exits non-zero on a broken mutation"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "classifier seam: the reason enum is unchanged by routing -- no new value, same catch-all"
  assert_eq "$FORGE_ROUTING_TOKEN" "$(forge_routing_tokens_for 'auth status')" \
    "classifier seam: the auth re-check ran as the account whose write failed, not as the machine account"

  teardown_forge_routing_env
}

# AC5's argv scan, extended to the two write verbs that lacked one. The fake
# refuses any credential-shaped argv element AND refuses to run without the
# environment variable, so one run proves both halves at once.
test_forge_pr_edit_credential_via_env_not_argv() {
  echo ""
  echo "=== forge-pr-edit: credential reaches gh via the environment, never argv ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *token*|*TOKEN*|--token|ghp_*|gho_*) echo "credential leaked into argv: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not inherited from environment" >&2
  exit 3
fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/404","number":404}'
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(GH_TOKEN="secret-value-xyz" PATH="$sandbox" "$CLI" forge-pr-edit --number 404 --body "B") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-edit credential: exit 0 (GH_TOKEN inherited, nothing credential-shaped in argv)"
  assert_eq "unchanged" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit credential: status unchanged"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_credential_via_env_not_argv() {
  echo ""
  echo "=== forge-resolve-review-thread: credential reaches gh via the environment, never argv ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # The mutation text itself is bound through -f query=..., so it IS an argv
  # element -- and it legitimately contains neither `token` nor a gh_-prefixed
  # value. The scan below is therefore a real constraint on this verb, not one
  # its own payload would trip.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *token*|*TOKEN*|--token|ghp_*|gho_*) echo "credential leaked into argv: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not inherited from environment" >&2
  exit 3
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo '{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_1","isResolved":true,"path":"a.txt","line":1}}}}'
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(GH_TOKEN="secret-value-xyz" PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id PRRT_kwDOABC123) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-resolve-review-thread credential: exit 0 (GH_TOKEN inherited, nothing credential-shaped in argv)"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.resolved')" "forge-resolve-review-thread credential: the mutation really ran"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# Forge PR View Tests (US-004)
# ============================================================================
# forge-pr-view is the first forge-* verb that actually shells out to a real
# forge CLI (gh). Every fixture here is fully offline: `setup_detect_forge_
# fixture` (test-aimi-cli.sh:16179) gives a github-shaped `git remote add`
# that is never dialed, and a fake `gh` binary prepended to PATH -- mirroring
# the fake-opencode-binary fixture `test_resolve_models_opencode_mtime_cache`
# already uses (test-aimi-cli.sh:8518-8535) -- stands in for the real gh so
# no test ever touches the network.

# setup_fake_gh_fixture/teardown_fake_gh_fixture are the same shared fixture
# defined in the forge-auth-status / forge-repo-info (US-003) section above
# -- extended there to also serve `gh pr view`/`gh pr list`, per the
# FAKE_GH_VIEW_*/FAKE_GH_PR_JSON/FAKE_GH_LIST_*/FAKE_GH_LOG vars documented
# alongside it, exactly the sibling-story reuse it was built for.
#
# FIXTURE NOTE (phase 1.1 US-010): every test below that models a FOUND PR
# for a BRANCH-NAME ref now sets FAKE_GH_LIST_JSON to a populated array
# alongside its FAKE_GH_PR_JSON. Since US-010 the `gh pr list --head <ref>`
# probe is the PRIMARY existence signal for a branch ref rather than a
# not-found-confirming backstop, and the shared fixture's unconfigured
# default for that var is the EMPTY array -- so a found-PR scenario that
# configures only gh pr view's response now resolves to not_found before gh
# pr view is ever reached. Every such test's expected status, envelope and
# exit code is unchanged; only its gh pr list configuration is. A NUMERIC
# ref never probes and needs no such pairing.

test_forge_pr_view_found_single_field() {
  echo ""
  echo "=== forge-pr-view: found status, single --include field, exact envelope shape (AC1) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out exit_code
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"https://github.com/o/r/pull/7"}' PATH="$FAKE_GH_DIR:$PATH" \
    "$CLI" forge-pr-view --pr feat-x --include url) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-view found: exit 0"
  assert_eq '{"status":"found","pr":{"url":"https://github.com/o/r/pull/7"},"unsupported_fields":[],"message":null}' \
    "$out" "forge-pr-view found: exact envelope shape, literal-for-literal (AC1)"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_include_field_sets() {
  echo ""
  echo "=== forge-pr-view: --include selects exactly the requested keys and no others (AC4) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # review.md's five-field call site (review.md:36).
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"title":"T","body":"B","files":[{"path":"a.txt"}],"headRefName":"feat","baseRefName":"main"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include title,body,files,headRefName,baseRefName)
  assert_eq '{"status":"found","pr":{"title":"T","body":"B","files":[{"path":"a.txt"}],"headRefName":"feat","baseRefName":"main"},"unsupported_fields":[],"message":null}' \
    "$out" "forge-pr-view include: five-field review.md set returns exactly those keys"

  # review.md's files-only call site (review.md:99).
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"files":[{"path":"b.txt","additions":3,"deletions":1}]}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files)
  assert_eq '{"status":"found","pr":{"files":[{"path":"b.txt","additions":3,"deletions":1}]},"unsupported_fields":[],"message":null}' \
    "$out" "forge-pr-view include: files-only returns exactly files"

  # The two capability-gated PR contract fields that were never reachable
  # through --include before this story (they replace the gh-only
  # reviews/comments pair, which the contract cannot express and which had
  # no caller outside this suite).
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"isDraft":true,"mergeable":"MERGEABLE"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include isDraft,mergeable)
  assert_eq '{"status":"found","pr":{"isDraft":true,"mergeable":"MERGEABLE"},"unsupported_fields":[],"message":null}' \
    "$out" "forge-pr-view include: isDraft,mergeable returns exactly those keys"

  # Omitted --include -- default portable core, excludes files/isDraft/
  # mergeable (open-pr.md's own two call sites only ever want url). gh
  # reports state in uppercase; the envelope must carry it normalized.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"number":1,"url":"u","title":"t","body":"b","state":"OPEN","headRefName":"h","baseRefName":"m"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x)
  assert_eq '{"status":"found","pr":{"number":1,"url":"u","title":"t","body":"b","state":"open","headRefName":"h","baseRefName":"m"},"unsupported_fields":[],"message":null}' \
    "$out" "forge-pr-view include: omitted defaults to the seven-field portable core"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_not_found_and_error_never_conflated() {
  echo ""
  echo "=== forge-pr-view: not_found and error are never conflated for the same --pr ref (AC3, highest risk) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local ref="feat-x"

  # Run 1: no PR exists -- gh pr view fails with its own not-found wording,
  # gh pr list confirms via the structural [] signal.
  local not_found_out
  not_found_out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="no pull requests found for branch \"$ref\"" \
    FAKE_GH_LIST_EXIT=0 FAKE_GH_LIST_JSON='[]' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  # Run 2: same ref -- gh itself is broken (authentication-failure-shaped
  # stderr instead of gh's own no-pull-requests-found wording), and the list
  # probe fails too -- must resolve to error, never not_found. This is the
  # exact defect open-pr.md's current `gh pr view --json url` exit-code
  # check carries today: a broken token reads as "no PR yet".
  local error_out
  error_out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="authentication required, please run gh auth login" \
    FAKE_GH_LIST_EXIT=1 FAKE_GH_LIST_STDERR="authentication required, please run gh auth login" \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  local not_found_status error_status
  not_found_status=$(printf '%s' "$not_found_out" | jq -r '.status')
  error_status=$(printf '%s' "$error_out" | jq -r '.status')

  assert_eq "not_found" "$not_found_status" "forge-pr-view conflation guard: run 1 (no PR) resolves to not_found"
  assert_eq "error" "$error_status" "forge-pr-view conflation guard: run 2 (broken auth) resolves to error"

  if [ "$not_found_status" != "$error_status" ]; then
    echo -e "${GREEN}✓${NC} forge-pr-view conflation guard: not_found and error produce different status literals for the same ref"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} forge-pr-view conflation guard: not_found and error produced the SAME status literal ($not_found_status) -- this is exactly the open-pr.md defect this verb exists to fix"
    ((TESTS_FAILED++))
  fi

  assert_eq "null" "$(printf '%s' "$not_found_out" | jq -r '.pr')" "forge-pr-view conflation guard: not_found -- pr is null"
  assert_contains "$ref" "$(printf '%s' "$not_found_out" | jq -r '.message')" "forge-pr-view conflation guard: not_found -- message names the searched ref"
  assert_eq "null" "$(printf '%s' "$error_out" | jq -r '.pr')" "forge-pr-view conflation guard: error -- pr is null"
  assert_contains "authentication required" "$(printf '%s' "$error_out" | jq -r '.message')" "forge-pr-view conflation guard: error -- message carries gh's own failure text"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_not_found_prefers_structural_list_probe_over_stderr_text() {
  echo ""
  echo "=== forge-pr-view: not_found detection prefers the structural gh-pr-list-returns-[] probe over stderr wording (orchestrator note) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  # gh pr view's stderr deliberately does NOT contain "no pull requests
  # found" wording -- simulating a reworded gh release or a non-English
  # locale -- proving the structural `gh pr list --head <branch> --json
  # number` returning [] at exit 0 is what actually drives not_found here,
  # never stderr pattern-matching.
  local out
  out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="HTTP 404: no encontro ninguna solicitud" \
    FAKE_GH_LIST_EXIT=0 FAKE_GH_LIST_JSON='[]' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x)

  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" \
    "forge-pr-view structural probe: reworded/non-English stderr still resolves to not_found via the list probe"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_not_found_secondary_stderr_fallback() {
  echo ""
  echo "=== forge-pr-view: falls back to gh's stderr wording only when the structural list probe itself cannot confirm not_found ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out
  out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR='no pull requests found for branch "feat-x"' \
    FAKE_GH_LIST_EXIT=1 FAKE_GH_LIST_STDERR="transient failure" \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x)

  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" \
    "forge-pr-view stderr fallback: list probe failure falls back to gh's own not-found wording"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_numeric_ref_skips_list_probe() {
  echo ""
  echo "=== forge-pr-view: a numeric --pr (PR number) never invokes gh pr list -- --head takes a branch name, not a number ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log_file="$FAKE_GH_DIR/call.log"
  local out
  out=$(FAKE_GH_LOG="$log_file" FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="no pull requests found for PR #42" \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr 42)

  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-view numeric ref: still resolves to not_found via the stderr fallback"
  assert_contains "42" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-view numeric ref: message names the numeric ref"

  if [ -f "$log_file" ] && grep -q "^pr list" "$log_file"; then
    echo -e "${RED}✗${NC} forge-pr-view numeric ref: gh pr list was invoked despite a numeric ref"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-view numeric ref: gh pr list was never invoked"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_unknown_include_field_rejected() {
  echo ""
  echo "=== forge-pr-view: an unrecognized --include field is CLI misuse, exit 1, never a substantive outcome (AC5) ==="

  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local stderr_file="/tmp/forge_pr_view_bad_include_stderr.$$"
  local exit_code
  "$CLI" forge-pr-view --pr feat-x --include bogus >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-view bad --include: exits 1"
  assert_stderr_contains "Error: forge-pr-view: unknown --include field: bogus" "$(cat "$stderr_file")" "forge-pr-view bad --include: stderr names the bad field"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_view_missing_gh_binary_quiet_degrade() {
  echo ""
  echo "=== forge-pr-view: gh absent from PATH degrades to status=error with no stderr banner (quiet mode, AC6) ==="

  setup_forge_no_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local stderr_file="/tmp/forge_pr_view_no_gh_stderr.$$"
  local out exit_code
  out=$(PATH="$NO_GH_PATH_DIR" "$CLI" forge-pr-view --pr feat-x 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-view gh-absent: exits 0 (never a caller error)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-view gh-absent: status is error"
  assert_contains "gh" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-view gh-absent: message names the missing binary"
  assert_eq "" "$(cat "$stderr_file")" "forge-pr-view gh-absent: no stderr banner (quiet degrade mode, matching review.md's undocumented-warning-free fallback)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_forge_no_gh_fixture
}

test_forge_pr_view_non_github_forge_quiet_degrade() {
  echo ""
  echo "=== forge-pr-view: a forge with no adapter (unknown) degrades to status=error with no stderr banner (quiet mode, AC6) ==="

  # `unknown`, not gitea: phase 4 outline:02 routed gitea to tea, so this test
  # -- which is about the adapter-less branch -- moves again to the forge that
  # still reaches it. RETARGETED, never deleted: the no_adapter path must stay
  # covered. This is the END of the line, because AIMI_FORGE_TYPE validates
  # only github|gitlab|gitea (aimi-cli.sh:2130) and all three now have
  # adapters -- `unknown`, reachable solely through an unrecognized remote
  # host, is the only control left.
  setup_detect_forge_fixture origin https://git.example.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local stderr_file="/tmp/forge_pr_view_no_adapter_stderr.$$"
  local out exit_code
  out=$("$CLI" forge-pr-view --pr feat-x 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-view non-github forge: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-view non-github forge: status is error"
  assert_contains "unknown" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-view non-github forge: message names the detected forge"
  assert_contains "no forge-pr-view adapter" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-view non-github forge: message is the no-adapter one, not a missing-binary one"
  assert_eq "" "$(cat "$stderr_file")" "forge-pr-view non-github forge: no stderr banner (quiet degrade mode)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_view_state_normalization_matches_issue_view() {
  echo ""
  echo "=== forge-pr-view: --include state normalizes gh's OPEN/CLOSED/MERGED exactly like forge-issue-view already does ==="

  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # One fake gh answering BOTH verbs off the same raw state literal, so the
  # parity assertion below compares the two verbs' normalization and nothing
  # else.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '{"state":"%s"}' "$FAKE_RAW_STATE"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf '{"number":1,"title":"t","body":"b","state":"%s","url":"u","labels":[],"comments":[]}' "$FAKE_RAW_STATE"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local raw expected pr_state issue_state
  for raw in OPEN CLOSED MERGED; do
    expected=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    pr_state=$(FAKE_RAW_STATE="$raw" PATH="$sandbox" "$CLI" forge-pr-view --pr feat-x --include state | jq -r '.pr.state')
    issue_state=$(FAKE_RAW_STATE="$raw" PATH="$sandbox" "$CLI" forge-issue-view --number 1 | jq -r '.data.state')
    assert_eq "$expected" "$pr_state" "forge-pr-view state: gh's $raw normalizes to $expected"
    assert_eq "$pr_state" "$issue_state" "state parity: forge-pr-view and forge-issue-view agree on $raw"
  done

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_view_unsupported_fields_is_always_an_array_on_found() {
  echo ""
  echo "=== forge-pr-view: unsupported_fields is an array on found (never bare null) and forced null on not_found/error ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # Every requested capability-gated field supplied -> explicitly empty [].
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"files":[],"isDraft":false,"mergeable":"MERGEABLE"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files,isDraft,mergeable)
  assert_eq "array" "$(printf '%s' "$out" | jq -r '.unsupported_fields | type')" "unsupported_fields: found, everything supplied -- type is array"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "unsupported_fields: found, everything supplied -- explicitly empty, never bare null"

  # A requested capability-gated field gh did not return -> named in the array.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url,files)
  assert_eq '["files"]' "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "unsupported_fields: found, gated field absent -- names it"

  # not_found / error keep it forced null alongside pr, mirroring
  # _forge_emit_status's own null-forcing convention.
  out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR='no pull requests found for branch "feat-x"' \
    FAKE_GH_LIST_EXIT=0 FAKE_GH_LIST_JSON='[]' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files)
  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "unsupported_fields: not_found precondition"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.unsupported_fields')" "unsupported_fields: not_found -- forced null, matching pr"

  out=$(FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="authentication required, please run gh auth login" \
    FAKE_GH_LIST_EXIT=1 FAKE_GH_LIST_STDERR="authentication required, please run gh auth login" \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files)
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "unsupported_fields: error precondition"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.unsupported_fields')" "unsupported_fields: error -- forced null, matching pr"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_unsupported_fields_intersect_requested_only() {
  echo ""
  echo "=== forge-pr-view: unsupported_fields is intersected with --include -- a gated field never requested never appears ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # _forge_build_pr_json ALWAYS flags all three unpassed gated fields. This
  # request names only one of them, so files and mergeable -- never asked
  # for -- must not be reported as unsupported, and pr must carry exactly
  # the two requested keys rather than the builder's ten-key superset.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url,isDraft)
  assert_eq '["isDraft"]' "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "intersection: only the requested gated field is reported unsupported"
  assert_eq '{"url":"u","isDraft":null}' "$(printf '%s' "$out" | jq -c '.pr')" "intersection: pr carries exactly the requested keys, never the builder's superset"

  # Two of the three requested, both absent from gh's response.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url,files,mergeable)
  assert_eq '["files","mergeable"]' "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "intersection: both requested gated fields reported, isDraft (unrequested) omitted"

  # None of the three requested -> nothing to report at all.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"number":1,"url":"u"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number,url)
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "intersection: no gated field requested -- empty array, not all three"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_absent_key_vs_explicit_null_are_distinguishable() {
  echo ""
  echo "=== forge-pr-view: a key gh omits reads as unsupported; the same key returned as an explicit null does not ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # Case 1 -- gh's response omits `files` entirely.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url,files)
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.pr | has("files")')" "absent key: files is still a key in pr (requested keys are never dropped)"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.pr.files')" "absent key: files reads null"
  assert_eq '["files"]' "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "absent key: files IS recorded in unsupported_fields"

  # Case 2 -- gh's response includes `files` with an explicit JSON null.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u","files":null}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url,files)
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.pr | has("files")')" "explicit null: files is a key in pr"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.pr.files')" "explicit null: files reads null (same value as the absent case)"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.unsupported_fields')" "explicit null: files is NOT recorded in unsupported_fields -- the two cases are no longer indistinguishable"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_include_accepts_contract_fields_and_rejects_gh_only_names() {
  echo ""
  echo "=== forge-pr-view: --include accepts the ten contract fields (isDraft/mergeable included) and rejects gh-only reviews/comments ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # isDraft and mergeable are PR contract fields that were never selectable
  # through --include before this story; each must now return exactly its
  # own key when requested alone.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"isDraft":true}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include isDraft)
  assert_eq '{"isDraft":true}' "$(printf '%s' "$out" | jq -c '.pr')" "contract fields: isDraft alone returns exactly isDraft"

  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"mergeable":"CONFLICTING"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include mergeable)
  assert_eq '{"mergeable":"CONFLICTING"}' "$(printf '%s' "$out" | jq -c '.pr')" "contract fields: mergeable alone returns exactly mergeable"

  # reviews/comments are gh-only names with no PR-contract equivalent and no
  # caller anywhere in commands/ or skills/ -- now rejected as unknown.
  local stderr_file="/tmp/forge_pr_view_gh_only_stderr.$$"
  local name exit_code
  for name in reviews comments; do
    exit_code=0
    "$CLI" forge-pr-view --pr feat-x --include "$name" >/dev/null 2>"$stderr_file" || exit_code=$?
    assert_exit_code "1" "$exit_code" "contract fields: gh-only --include $name exits 1"
    assert_stderr_contains "unknown --include field: $name" "$(cat "$stderr_file")" "contract fields: stderr names the rejected gh-only field $name"
  done
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_registered_in_help_and_dispatcher() {
  echo ""
  echo "=== forge-pr-view: listed in help with its flags and routed by the dispatcher (AC7) ==="

  local help_out
  help_out=$("$CLI" help 2>&1)
  assert_contains "forge-pr-view --pr <branch-or-number> [--include <fields>] [--project <path>]" "$help_out" "help: lists forge-pr-view with its three flags"

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local dispatch_out
  dispatch_out=$(FAKE_GH_LIST_JSON='[{"number":7}]' FAKE_GH_PR_JSON='{"url":"u"}' PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url 2>&1)

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture

  if printf '%s' "$dispatch_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-pr-view is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-pr-view is routed"
    ((TESTS_PASSED++))
  fi
}

# ============================================================================
# Forge PR Create/Edit Tests (US-005)
# ============================================================================
# forge-pr-create / forge-pr-edit are the first WRITE verbs that mutate a
# pull request. Both need `gh pr view`/`gh pr list` (the idempotency check
# and post-write structured re-read, via forge-pr-view) AND `gh pr create`/
# `gh pr edit` in the SAME invocation, with call-order-dependent behavior
# (not found -> create -> found) that the shared setup_fake_gh_fixture
# above cannot express with its static FAKE_GH_* env vars. Reusing
# setup_forge_cli_sandbox/teardown_forge_cli_sandbox instead (the US-006
# fixture, whose own doc comment above already earmarks "forge-pr-view/
# forge-pr-create ... need the identical technique") -- each test below
# writes its own small `gh` heredoc script, using a marker file dropped
# next to the fake `gh` binary itself to track state across the multiple
# gh invocations one forge-pr-create/forge-pr-edit call makes.

test_forge_pr_create_new_pr() {
  echo ""
  echo "=== forge-pr-create: no existing PR -- creates one, derives number via a structured forge-pr-view re-read, never a URL regex (AC1/AC3) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
FLAG="$(dirname "$0")/pr_created.flag"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -f "$FLAG" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/101","number":101}'
    exit 0
  fi
  echo "no pull requests found for branch" >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  # Mirrors $FLAG exactly like the `pr view` handler above. Since phase 1.1
  # US-010 this probe is forge-pr-view's PRIMARY existence signal for a
  # branch ref, so a handler that always echoed the empty array would force
  # the post-create re-read to not_found before gh pr view was ever reached
  # -- silently turning this test's post-create path into an assertion about
  # the wrong branch of the code.
  if [ -f "$FLAG" ]; then
    echo '[{"number":101}]'
  else
    echo '[]'
  fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$FLAG"
  echo "https://github.com/owner/repo/pull/101"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create new PR: exit 0"
  assert_eq '{"status":"created","data":{"url":"https://github.com/owner/repo/pull/101","number":101},"message":null}' \
    "$out" "forge-pr-create new PR: status created with {url, number} nested under data, derived from the structured re-read (AC1)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_existing_pr_is_idempotent() {
  echo ""
  echo "=== forge-pr-create: an open PR already exists for --head -- returns it unchanged, never calls gh pr create (AC2) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # "state":"OPEN" is load-bearing: the existing-PR check requests
  # url,number,state and only short-circuits on a normalized state of
  # `open`, so a fixture without one would be treated as non-blocking and
  # this test would silently invert into asserting the opposite.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/55","number":55,"state":"OPEN"}'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  # Added in phase 1.1 US-010. Before it, this script had no `pr list` arm at
  # all: the probe hit the catch-all below, exited 99, and forge-pr-view fell
  # back to the `pr view` handler -- so this scenario passed through the
  # probe-unavailable FALLBACK path rather than the intended primary one. A
  # populated array is the response consistent with the open PR the `pr view`
  # handler above already reports.
  echo '[{"number":55}]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  echo "gh pr create should never have been invoked for an already-existing PR: $*" >&2
  exit 66
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create idempotent: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://github.com/owner/repo/pull/55","number":55},"message":null}' \
    "$out" "forge-pr-create idempotent: reports status unchanged with the existing PR under data, no duplicate opened (AC2)"
  assert_eq "unchanged" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create idempotent: status is the literal 'unchanged' -- not 'created', and not a bare absent field"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_lookup_error_never_falls_through_to_create() {
  echo ""
  echo "=== forge-pr-create: forge-pr-view reports status error while checking for an existing PR -- NEVER opens a duplicate, exits 1 ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # Both halves of forge-pr-view's github lookup fail with gh's own
  # authentication wording -- `gh pr view` AND the `gh pr list` structural
  # not_found probe -- so forge-pr-view reports status:"error" at EXIT 0.
  # That exit-0-with-an-error-envelope is precisely what a bare
  # `if [ "$existing_rc" -ne 0 ]` guard cannot see and what a bare
  # `if [ "$existing_status" = "found" ]` check falls straight through,
  # landing on `gh pr create` and opening a duplicate PR.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && { [ "$2" = "view" ] || [ "$2" = "list" ]; }; then
  echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2
  exit 4
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$(dirname "$0")/pr_create_invoked.flag"
  echo "gh pr create must never run when the existing-PR lookup itself failed: $*" >&2
  exit 66
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_pr_create_lookup_error_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create lookup error: exits 1"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create lookup error: stdout carries a degraded envelope (in-band signal ON TOP of the exit code, never instead of it)"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-pr-create lookup error: data is null on degraded"
  assert_contains "forge-pr-view reported an error" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-create lookup error: message echoes the same reason stderr states"
  if [ -f "$sandbox/pr_create_invoked.flag" ]; then
    echo -e "${RED}✗${NC} forge-pr-create lookup error: gh pr create WAS invoked -- a duplicate PR would have been opened"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create lookup error: gh pr create was never invoked"
    ((TESTS_PASSED++))
  fi
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create lookup error: manual fallback printed (MANDATORY-PRINT)"
  assert_stderr_contains "forge-pr-view reported an error" "$(cat "$stderr_file")" "forge-pr-create lookup error: stderr names forge-pr-view as the failing lookup"
  assert_stderr_contains "gh auth login" "$(cat "$stderr_file")" "forge-pr-create lookup error: stderr carries forge-pr-view's own message text"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_closed_or_merged_existing_pr_does_not_block() {
  echo ""
  echo "=== forge-pr-create: an existing CLOSED/MERGED PR on --head does not block -- a fresh PR is created and only its own identity is returned ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # `gh pr view <branch>` is NOT state-filtered (verified against real gh
  # 2.94.0 on this repository's own merged PR #84 and closed PR #6), so a
  # branch whose prior PR was merged or closed still resolves to that stale
  # PR here. FAKE_EXISTING_STATE stays unexpanded inside this quoted
  # heredoc and is read by the fake gh at run time, so one script covers
  # both the MERGED and the CLOSED variant.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
FLAG="$(dirname "$0")/pr_created.flag"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -f "$FLAG" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/91","number":91}'
    exit 0
  fi
  echo "{\"url\":\"https://github.com/owner/repo/pull/12\",\"number\":12,\"state\":\"${FAKE_EXISTING_STATE:-MERGED}\"}"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$FLAG"
  echo "https://github.com/owner/repo/pull/91"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stale_state out exit_code
  for stale_state in MERGED CLOSED; do
    rm -f "$sandbox/pr_created.flag"
    out=$(FAKE_EXISTING_STATE="$stale_state" PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

    assert_exit_code "0" "$exit_code" "forge-pr-create $stale_state existing PR: exit 0"
    if [ -f "$sandbox/pr_created.flag" ]; then
      echo -e "${GREEN}✓${NC} forge-pr-create $stale_state existing PR: gh pr create WAS invoked (a $stale_state PR must not block a new one)"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} forge-pr-create $stale_state existing PR: gh pr create was never invoked -- the $stale_state PR blocks creation forever"
      ((TESTS_FAILED++))
    fi
    assert_eq '{"status":"created","data":{"url":"https://github.com/owner/repo/pull/91","number":91},"message":null}' \
      "$out" "forge-pr-create $stale_state existing PR: reports status created with the NEW PR's own url/number -- the stale PR's identity never leaks"
  done

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_post_create_reread_failure_keeps_created_url() {
  echo ""
  echo "=== forge-pr-create: gh pr create succeeds but the post-create re-read fails -- keeps the captured url, exit 0, Warning not create-it-yourself ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # Before the flag: a clean not_found (gh pr view fails with gh's own
  # no-pull-requests wording, gh pr list confirms []). After creation: both
  # fail with an authentication-style message instead, so the re-read comes
  # back status:"error" -- a genuine failure, NOT a not_found. The PR
  # nonetheless exists and its url is already in hand.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
FLAG="$(dirname "$0")/pr_created.flag"
if [ "$1" = "pr" ] && { [ "$2" = "view" ] || [ "$2" = "list" ]; }; then
  if [ -f "$FLAG" ]; then
    echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2
    exit 4
  fi
  if [ "$2" = "list" ]; then
    echo '[]'
    exit 0
  fi
  echo "no pull requests found for branch" >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$FLAG"
  echo "https://github.com/owner/repo/pull/404"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_pr_create_reread_fail_stderr.$$"
  local out exit_code stderr_text
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$exit_code" "forge-pr-create re-read failure: exit 0 -- the PR really was created"
  assert_eq '{"status":"created","data":{"url":"https://github.com/owner/repo/pull/404","number":null},"message":null}' \
    "$out" "forge-pr-create re-read failure: the captured url survives under data with number:null, status stays created"
  # NOT degraded: degraded forces data to null by contract, which would throw
  # the created PR's url away and lead a caller to open a second PR for a
  # branch that already has one.
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create re-read failure: status is created, never degraded -- a degraded envelope would null out the url this branch exists to preserve"
  assert_stderr_contains "Warning:" "$stderr_text" "forge-pr-create re-read failure: stderr warns rather than erroring"
  assert_stderr_contains "https://github.com/owner/repo/pull/404" "$stderr_text" "forge-pr-create re-read failure: the Warning names the created PR's url"
  if printf '%s' "$stderr_text" | grep -qE "create it yourself|git push -u origin"; then
    echo -e "${RED}✗${NC} forge-pr-create re-read failure: the create-it-yourself fallback was printed for a PR that already exists -- following it would open a duplicate"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create re-read failure: the create-it-yourself fallback is never printed once a url has been captured"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_missing_gh_mandatory_print_nonzero_exit() {
  echo ""
  echo "=== forge-pr-create: gh absent -- MANDATORY-PRINT degrade, EXIT NON-ZERO (differs from forge-issue-create's soft-fail) (AC6) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- simulates "gh not installed".

  local stderr_file="/tmp/forge_pr_create_no_gh_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create gh-absent: EXITS NON-ZERO (a hard failure, unlike forge-issue-create's soft-fail exit 0)"
  assert_eq '{"status":"degraded","data":null,"message":"gh not found -- this pull request was not created automatically."}' \
    "$out" "forge-pr-create gh-absent: stdout carries the degraded envelope -- no longer silent, while the exit code above stays 1"
  assert_stderr_contains "gh not found" "$(cat "$stderr_file")" "forge-pr-create gh-absent: _forge_bin_check's mandatory warning names gh"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create gh-absent: manual instruction printed (MANDATORY-PRINT)"
  assert_stderr_contains "git push -u origin feat-x" "$(cat "$stderr_file")" "forge-pr-create gh-absent: manual instruction includes the git push command (AC6)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# RETARGETED TWICE, NEVER DELETED -- and this is the end of the line.
#
# The remote here was gitlab.com until phase 3 gave GitLab a real adapter, and
# then codeberg.org (-> `gitea`) until phase 4 outline:03 gave Gitea one. Each
# time, routing that forge turned this test's own premise ("this forge has no
# adapter") false and made it assert the wrong thing. Deleting it instead
# would have left the no-adapter arm untested for this verb entirely.
#
# git.example.invalid falls to _detect_forge_classify_host's `*)` arm and
# classifies as `unknown`, which is the ONLY stand-in left: AIMI_FORGE_TYPE
# validates its value against github|gitlab|gitea and nothing else, so after
# phase 4 there is no forge WORD still lacking an adapter -- only an
# unrecognized remote host. The GitLab and Gitea equivalents of this test --
# the adapter exists but its binary is absent -- are
# test_glw_forge_pr_create_gitlab_missing_glab_prints_mr_url and
# gtw_test_forge_pr_create_gitea_missing_tea_prints_manual.
test_forge_pr_create_non_github_forge_mandatory_print() {
  echo ""
  echo "=== forge-pr-create: non-github forge (no adapter) -- MANDATORY-PRINT degrade, never shells to gh, exit non-zero ==="

  setup_detect_forge_fixture origin https://git.example.invalid/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
echo "gh should never be invoked for a non-github forge: $*" >&2
exit 77
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_pr_create_gitlab_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create non-github forge: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create non-github forge: stdout carries the degraded envelope while the exit code stays 1"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-pr-create non-github forge: data is null on degraded"
  assert_contains "no adapter for forge \"unknown\"" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-create non-github forge: message names the unsupported forge"
  assert_stderr_contains "unknown" "$(cat "$stderr_file")" "forge-pr-create non-github forge: manual instruction names the detected forge"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create non-github forge: manual instruction printed"
  if grep -q "gh should never be invoked" "$stderr_file"; then
    echo -e "${RED}✗${NC} forge-pr-create non-github forge: gh was invoked despite having no adapter for this forge"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create non-github forge: gh was never invoked"
    ((TESTS_PASSED++))
  fi
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_guard_failures() {
  echo ""
  echo "=== forge-pr-create: invalid --head/--base and missing required flags are caller errors, exit 1, before any gh call (AC1 guard) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local stderr_file="/tmp/forge_pr_create_guard_stderr.$$" exit_code

  "$CLI" forge-pr-create --title T --base main --head "bad;head" --body B >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-pr-create invalid --head: exit 1"
  assert_stderr_contains "invalid --head value" "$(cat "$stderr_file")" "forge-pr-create invalid --head: stderr names the bad value"

  "$CLI" forge-pr-create --title T --base "bad;base" --head feat-x --body B >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-pr-create invalid --base: exit 1"
  assert_stderr_contains "invalid --base value" "$(cat "$stderr_file")" "forge-pr-create invalid --base: stderr names the bad value"

  "$CLI" forge-pr-create --base main --head feat-x --body B >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-pr-create missing --title: exit 1"
  assert_stderr_contains "Usage: aimi-cli.sh forge-pr-create" "$(cat "$stderr_file")" "forge-pr-create missing --title: stderr prints usage"

  rm -f "$stderr_file"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_credential_via_env_not_argv() {
  echo ""
  echo "=== forge-pr-create: credential reaches gh via inherited env var, never argv or a --token flag (AC5) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *token*|*TOKEN*|--token|ghp_*|gho_*) echo "credential leaked into argv: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not inherited from environment" >&2
  exit 3
fi
FLAG="$(dirname "$0")/pr_created.flag"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -f "$FLAG" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/202","number":202}'
    exit 0
  fi
  echo "no pull requests found" >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  echo '[]'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$FLAG"
  echo "https://github.com/owner/repo/pull/202"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(GH_TOKEN="secret-value-xyz" PATH="$sandbox" "$CLI" forge-pr-create --title T --base main --head feat-y --body B) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create credential: exit 0 (GH_TOKEN inherited correctly, no argv leak, no --token flag)"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create credential: status created"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_edit_success() {
  echo ""
  echo "=== forge-pr-edit: successful body update -- status unchanged with {url, number} under data, via a structured forge-pr-view re-read (AC4) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/303","number":303}'
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-edit success: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://github.com/owner/repo/pull/303","number":303},"message":null}' \
    "$out" "forge-pr-edit success: the same write envelope forge-pr-create emits, genuinely identical this time (AC4)"
  # An edit mutates a number that already existed and mints no new
  # identifier -- forge-contract.md's Write-Verb Status Convention calls that
  # unchanged, even though the PR's BODY did change.
  assert_eq "unchanged" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit success: status is unchanged -- never created, and never a bare absent field the way it was before"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_edit_missing_gh_mandatory_print_nonzero_exit() {
  echo ""
  echo "=== forge-pr-edit: gh absent -- MANDATORY-PRINT degrade, EXIT NON-ZERO (AC6) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- simulates "gh not installed".

  local stderr_file="/tmp/forge_pr_edit_no_gh_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit gh-absent: exits non-zero"
  assert_eq '{"status":"degraded","data":null,"message":"gh not found -- this pull request was not edited automatically."}' \
    "$out" "forge-pr-edit gh-absent: stdout carries the degraded envelope -- no longer silent, while the exit code above stays 1"
  assert_stderr_contains "gh not found" "$(cat "$stderr_file")" "forge-pr-edit gh-absent: _forge_bin_check's mandatory warning names gh"
  assert_stderr_contains "edit it yourself" "$(cat "$stderr_file")" "forge-pr-edit gh-absent: manual instruction printed (MANDATORY-PRINT, AC6)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_edit_gh_failure_prints_manual_nonzero_exit() {
  echo ""
  echo "=== forge-pr-edit: gh pr edit itself fails -- manual instruction printed, exit non-zero ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  echo "HTTP 404: Not Found" >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_pr_edit_fail_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit gh-failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit gh-failure: stdout carries the degraded envelope while the exit code stays 1"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-pr-edit gh-failure: data is null on degraded"
  assert_contains "gh pr edit exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-edit gh-failure: message echoes the same gh exit-code text stderr states"
  assert_stderr_contains "gh pr edit exited 1" "$(cat "$stderr_file")" "forge-pr-edit gh-failure: error names the gh exit code"
  assert_stderr_contains "edit it yourself" "$(cat "$stderr_file")" "forge-pr-edit gh-failure: manual instruction printed"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# Omitting --body used to be indistinguishable from passing an empty one:
# both left $body as "", and `gh pr edit N --body ""` BLANKS the description.
# A caller that simply forgot the flag silently destroyed the PR body.
test_forge_pr_edit_omitted_body_is_rejected() {
  echo ""
  echo "=== forge-pr-edit: --body omitted entirely -- rejected before gh runs, so a description is never blanked by omission ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local gh_log="$sandbox/gh-invocations.log"
  cat > "$sandbox/gh" << FAKE_GH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_log"
if [ "\$1" = "pr" ] && [ "\$2" = "edit" ]; then
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/303","number":303}'
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_pr_edit_no_body_stderr.$$"
  local exit_code
  PATH="$sandbox" "$CLI" forge-pr-edit --number 303 >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit omitted --body: exit 1"
  assert_stderr_contains "Usage: aimi-cli.sh forge-pr-edit" "$(cat "$stderr_file")" \
    "forge-pr-edit omitted --body: reuses the existing Usage message rather than inventing a second one"

  local gh_calls=""
  [ -f "$gh_log" ] && gh_calls=$(cat "$gh_log")
  assert_eq "" "$gh_calls" \
    "forge-pr-edit omitted --body: gh is never invoked at all -- the PR body cannot be blanked"

  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# The other half of the same distinction: an EXPLICIT --body "" is a
# deliberate way to clear a description and must keep working. The rejection
# above keys on whether the flag was SEEN, never on whether its value is
# non-empty -- these two tests only both pass under that reading.
test_forge_pr_edit_explicit_empty_body_still_clears() {
  echo ""
  echo "=== forge-pr-edit: an explicit --body \"\" is a deliberate clear and still succeeds ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local gh_log="$sandbox/gh-invocations.log"
  cat > "$sandbox/gh" << FAKE_GH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_log"
if [ "\$1" = "pr" ] && [ "\$2" = "edit" ]; then
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/303","number":303}'
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-edit explicit empty --body: exit 0 -- a deliberate clear is still allowed"
  assert_eq "unchanged" "$(printf '%s' "$out" | jq -r '.status')" \
    "forge-pr-edit explicit empty --body: reports the normal unchanged write envelope"
  assert_contains "pr edit 303 --body" "$(cat "$gh_log")" \
    "forge-pr-edit explicit empty --body: gh IS invoked -- the clear actually reaches the forge"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_edit_invalid_number_guard() {
  echo ""
  echo "=== forge-pr-edit: --number must be numeric-only before it is ever interpolated into a gh command (AC4 guard) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local stderr_file="/tmp/forge_pr_edit_bad_number_stderr.$$"
  local exit_code
  "$CLI" forge-pr-edit --number "abc" --body B >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit invalid --number: exit 1"
  assert_stderr_contains "--number must be a positive integer" "$(cat "$stderr_file")" "forge-pr-edit invalid --number: stderr names the bad value"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_write_verbs_share_one_data_shape() {
  echo ""
  echo "=== forge-pr-create created / forge-pr-create unchanged / forge-pr-edit unchanged: all three nest an IDENTICAL {url, number} under data (AC3) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # One fake gh, three scenarios selected by FAKE_SCENARIO so the three
  # outcomes below are produced by the real verb bodies rather than by three
  # different fixtures that could drift apart.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
FLAG="$(dirname "$0")/pr_created.flag"
case "${FAKE_SCENARIO:-}" in
  create)
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      if [ -f "$FLAG" ]; then
        echo '{"url":"https://github.com/owner/repo/pull/700","number":700}'
        exit 0
      fi
      echo "no pull requests found for branch" >&2
      exit 1
    fi
    # Mirrors $FLAG like the `pr view` arm above -- see the same note on
    # test_forge_pr_create_new_pr's script for why a permanently-empty list
    # response would send the post-create re-read to not_found.
    if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
      if [ -f "$FLAG" ]; then echo '[{"number":700}]'; else echo '[]'; fi
      exit 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
      : > "$FLAG"
      echo "https://github.com/owner/repo/pull/700"
      exit 0
    fi
    ;;
  existing)
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      echo '{"url":"https://github.com/owner/repo/pull/701","number":701,"state":"OPEN"}'
      exit 0
    fi
    if [ "$1" = "pr" ] && [ "$2" = "list" ]; then echo '[{"number":701}]'; exit 0; fi
    ;;
  edit)
    if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then exit 0; fi
    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      echo '{"url":"https://github.com/owner/repo/pull/702","number":702}'
      exit 0
    fi
    ;;
esac
echo "unexpected gh invocation ($FAKE_SCENARIO): $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local created_out existing_out edit_out
  rm -f "$sandbox/pr_created.flag"
  created_out=$(FAKE_SCENARIO=create PATH="$sandbox" "$CLI" forge-pr-create --title T --base main --head feat-x --body B)
  existing_out=$(FAKE_SCENARIO=existing PATH="$sandbox" "$CLI" forge-pr-create --title T --base main --head feat-x --body B)
  edit_out=$(FAKE_SCENARIO=edit PATH="$sandbox" "$CLI" forge-pr-edit --number 702 --body B)

  assert_eq "created"   "$(printf '%s' "$created_out"  | jq -r '.status')" "write-shape parity: forge-pr-create's fresh-creation branch reports created"
  assert_eq "unchanged" "$(printf '%s' "$existing_out" | jq -r '.status')" "write-shape parity: forge-pr-create's idempotent branch reports unchanged"
  assert_eq "unchanged" "$(printf '%s' "$edit_out"     | jq -r '.status')" "write-shape parity: forge-pr-edit's success path reports unchanged"

  # The whole point of the shared envelope: one caller code path reads all
  # three outcomes. Same envelope keys, same data keys, same value types.
  local envelope_keys='["data","message","status"]' data_keys='["number","url"]'
  assert_eq "$envelope_keys" "$(printf '%s' "$created_out"  | jq -c 'keys')" "write-shape parity: created envelope keys"
  assert_eq "$envelope_keys" "$(printf '%s' "$existing_out" | jq -c 'keys')" "write-shape parity: unchanged (idempotent create) envelope keys"
  assert_eq "$envelope_keys" "$(printf '%s' "$edit_out"     | jq -c 'keys')" "write-shape parity: unchanged (edit) envelope keys"
  assert_eq "$data_keys" "$(printf '%s' "$created_out"  | jq -c '.data | keys')" "write-shape parity: created data keys are exactly {url, number}"
  assert_eq "$data_keys" "$(printf '%s' "$existing_out" | jq -c '.data | keys')" "write-shape parity: unchanged (idempotent create) data keys are exactly {url, number}"
  assert_eq "$data_keys" "$(printf '%s' "$edit_out"     | jq -c '.data | keys')" "write-shape parity: unchanged (edit) data keys are exactly {url, number}"

  assert_eq "700" "$(printf '%s' "$created_out"  | jq -r '.data.number')" "write-shape parity: created data.number readable through one path"
  assert_eq "701" "$(printf '%s' "$existing_out" | jq -r '.data.number')" "write-shape parity: unchanged (idempotent create) data.number readable through the SAME path"
  assert_eq "702" "$(printf '%s' "$edit_out"     | jq -r '.data.number')" "write-shape parity: unchanged (edit) data.number readable through the SAME path"

  local shape
  for shape in "$created_out" "$existing_out" "$edit_out"; do
    assert_eq "number" "$(printf '%s' "$shape" | jq -r '.data.number | type')" "write-shape parity: data.number is an int in every outcome"
    assert_eq "string" "$(printf '%s' "$shape" | jq -r '.data.url | type')" "write-shape parity: data.url is a string in every outcome"
  done

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_write_verbs_degraded_exit_code_split() {
  echo ""
  echo "=== degraded on all three write verbs: SAME envelope, deliberately DIFFERENT exit codes (hard-fail vs soft-fail) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- one identical trigger for all three verbs, so the
  # only variable left is each verb's own exit-code contract.

  local create_out edit_out issue_out create_rc edit_rc issue_rc
  create_out=$(PATH="$sandbox" "$CLI" forge-pr-create --title T --base main --head feat-x --body B 2>/dev/null) && create_rc=0 || create_rc=$?
  edit_out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 9 --body B 2>/dev/null) && edit_rc=0 || edit_rc=$?
  issue_out=$(PATH="$sandbox" "$CLI" forge-issue-create --title T --body B 2>/dev/null) && issue_rc=0 || issue_rc=$?

  # Same in-band signal on all three.
  assert_eq "degraded" "$(printf '%s' "$create_out" | jq -r '.status')" "exit split: forge-pr-create reports status degraded"
  assert_eq "degraded" "$(printf '%s' "$edit_out"   | jq -r '.status')" "exit split: forge-pr-edit reports status degraded"
  assert_eq "degraded" "$(printf '%s' "$issue_out"  | jq -r '.status')" "exit split: forge-issue-create reports status degraded"

  # Deliberately different exit codes -- this story adds the envelope ON TOP
  # of the exit-code contract, it does not replace it.
  assert_exit_code "1" "$create_rc" "exit split: forge-pr-create degraded EXITS 1 (hard-fail -- opening a PR has no fallback)"
  assert_exit_code "1" "$edit_rc"   "exit split: forge-pr-edit degraded EXITS 1 (hard-fail, same contract as forge-pr-create)"
  assert_exit_code "0" "$issue_rc"  "exit split: forge-issue-create degraded EXITS 0 (soft-fail -- open-pr.md's contract that a failed backend issue never blocks PR creation)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_create_and_edit_registered_in_help_and_dispatcher() {
  echo ""
  echo "=== forge-pr-create / forge-pr-edit: listed in help with their flags and routed by the dispatcher ==="

  local help_out
  help_out=$("$CLI" help 2>&1)
  assert_contains "forge-pr-create --title <t> --base <branch> --head <branch> [--body <text>] [--project <path>]" "$help_out" "help: lists forge-pr-create with its flags"
  assert_contains "forge-pr-edit --number <n> --body <text> [--project <path>]" "$help_out" "help: lists forge-pr-edit with its flags"

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo '{"url":"https://github.com/owner/repo/pull/1","number":1}'
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "edit" ]; then
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local create_out edit_out
  create_out=$(PATH="$sandbox" "$CLI" forge-pr-create --title t --base main --head feat-x --body b 2>&1)
  edit_out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 1 --body b 2>&1)

  popd >/dev/null
  teardown_detect_forge_fixture

  if printf '%s' "$create_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-pr-create is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-pr-create is routed"
    ((TESTS_PASSED++))
  fi

  if printf '%s' "$edit_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-pr-edit is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-pr-edit is routed"
    ((TESTS_PASSED++))
  fi
}

# ============================================================================
# GitLab WRITE-verb tests (phase 3) — forge-pr-create / forge-pr-edit /
# forge-issue-create routed to glab
# ============================================================================
# EVERY helper introduced by this section is `glw_`-prefixed (GitLab Write).
# That is an orchestration constraint, not a style preference: sibling stories
# are adding GitLab READ-verb and review-thread helpers to THIS SAME FILE in
# parallel, and bash silently keeps the LAST definition of a duplicated
# function name. Three individually-green branches whose helper names collide
# produce a red container after the merge -- the exact failure that cost this
# programme a wave-1 merge one phase ago. Grep before naming, and prefix
# anyway.
#
# The section deliberately does NOT extend setup_fake_glab_fixture (the READ-
# side stub a sibling story owns) with write subcommands, for the same
# reason: an edit inside that shared function is a merge conflict waiting to
# happen. glw_install_fake_glab below is a separate, self-contained stub.
#
# WHAT THESE TESTS ACTUALLY PROVE, AND WHAT THEY CANNOT. glab is not
# installed on this machine (this phase's declared verification ceiling), so
# every assertion here is about WHICH ARGV aimi-cli.sh emits, never about what
# the real binary does with it. That is the right thing to pin regardless:
# the defect this story exists to prevent is a MISSING FLAG, and a missing
# flag is visible in argv.
#
# WHY -y IS ASSERTED ON RECORDED ARGV AND NEVER ON AN EXIT STATUS. `glab mr
# create`, `glab mr update` and `glab issue create` PROMPT for confirmation
# unless passed -y (`--yes`). `gh pr create` has no such flag, so the habit
# carried over from the github adapter does not produce an error -- it
# produces a HANG, forever, with no output explaining why, in an autonomous
# run with nobody there to answer. A fake glab never prompts, so it exits 0
# whether or not -y was passed: an exit-status assertion would pass vacuously
# and prove exactly nothing. glw_argv_carries_yes below therefore reads the
# stub's argv log, and test_glw_yes_flag_detector_can_go_red proves that
# reader can return "no" before anything trusts it returning "yes".

# Writes a fake `glab` into an existing setup_forge_cli_sandbox directory.
# Records every invocation's argv (one line per call) to $GLW_GLAB_LOG, which
# is what every -y assertion below reads.
#
# The `mr view` arm's not-found shape is load-bearing and modelled on glab
# rather than on gh: glab has no `--head`-style structural existence probe
# that answers "no merge request" as `[]` at exit 0, so absence arrives as a
# NON-ZERO exit with prose on stderr -- indistinguishable, structurally, from
# a lookup that genuinely failed. That is precisely why the adapter falls
# through to creation on a failed lookup instead of degrading, and a stub that
# modelled absence as gh does would hide the very asymmetry these tests exist
# to lock in.
glw_install_fake_glab() {
  local sandbox="$1"
  cat > "$sandbox/glab" << 'GLW_FAKE_GLAB'
#!/usr/bin/env bash
if [ -n "${GLW_GLAB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GLW_GLAB_LOG"
fi

FLAG="$(dirname "$0")/glw_mr_created.flag"

case "$1 $2" in
  "mr view")
    if [ -f "$FLAG" ] && [ -n "${GLW_MR_VIEW_AFTER_JSON:-}" ]; then
      printf '%s' "$GLW_MR_VIEW_AFTER_JSON"
      exit 0
    fi
    if [ -n "${GLW_MR_VIEW_JSON:-}" ]; then
      printf '%s' "$GLW_MR_VIEW_JSON"
      exit 0
    fi
    echo "404 Not Found" >&2
    exit 1
    ;;
  "mr create")
    : > "$FLAG"
    if [ "${GLW_MR_CREATE_EXIT:-0}" != "0" ]; then
      printf '%s\n' "${GLW_MR_CREATE_STDERR:-glab: something went wrong}" >&2
      exit "${GLW_MR_CREATE_EXIT}"
    fi
    printf '%s\n' "${GLW_MR_CREATE_STDOUT:-}"
    exit 0
    ;;
  "mr update")
    if [ "${GLW_MR_UPDATE_EXIT:-0}" != "0" ]; then
      printf '%s\n' "${GLW_MR_UPDATE_STDERR:-glab: something went wrong}" >&2
      exit "${GLW_MR_UPDATE_EXIT}"
    fi
    printf '%s\n' "${GLW_MR_UPDATE_STDOUT:-}"
    exit 0
    ;;
  "issue create")
    if [ "${GLW_ISSUE_CREATE_EXIT:-0}" != "0" ]; then
      printf '%s\n' "${GLW_ISSUE_CREATE_STDERR:-glab: something went wrong}" >&2
      exit "${GLW_ISSUE_CREATE_EXIT}"
    fi
    printf '%s\n' "${GLW_ISSUE_CREATE_STDOUT:-}"
    exit 0
    ;;
esac
echo "fake-glab (write): unhandled invocation: $*" >&2
exit 99
GLW_FAKE_GLAB
  chmod +x "$sandbox/glab"
}

# Answers, from the RECORDED ARGV alone, whether a given glab write
# subcommand carried -y. Prints "yes" or "no".
#
# Never consults an exit status -- see this section's header for why that
# would be a vacuous assertion. `-y` is matched with explicit boundaries on
# both sides so a `-yes`-shaped or `--yes-really`-shaped token can never be
# mistaken for it.
# Usage: glw_argv_carries_yes <log-file> <subcommand, e.g. "mr create">
glw_argv_carries_yes() {
  local log="$1" subcommand="$2"
  if grep -qE "^${subcommand}( .*)? -y( |$)" "$log" 2>/dev/null; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Prints the one recorded argv line for a given glab subcommand, so an
# assertion can pin the ENTIRE invocation -- flag names, flag order and -y --
# in a single comparison rather than three loose greps.
# Usage: glw_argv_line <log-file> <subcommand>
glw_argv_line() {
  local log="$1" subcommand="$2"
  grep -E "^${subcommand}( |$)" "$log" 2>/dev/null | head -1 || true
}

# Counts recorded invocations of a glab subcommand. Used to prove a call was
# NEVER made (the idempotency assertion), which no output comparison can show.
# Usage: glw_argv_count <log-file> <subcommand>
glw_argv_count() {
  local log="$1" subcommand="$2"
  grep -cE "^${subcommand}( |$)" "$log" 2>/dev/null || true
}

# Extracts one function body out of aimi-cli.sh for the static assertions
# below -- same sed technique source_cache_functions/source_forge_gitlab_map_
# functions use, but printing rather than eval'ing.
# Usage: glw_fn_body <function-name>
glw_fn_body() {
  sed -n "/^$1()/,/^}/p" "$CLI"
}

# eval's the pure GitLab write helpers for direct, in-process testing.
glw_source_write_helpers() {
  eval "$(sed -n '/^_forge_glab_write_url()/,/^}/p' "$CLI")"
}

# RUNS BEFORE EVERY OTHER ASSERTION IN THIS SECTION, ON PURPOSE. The whole
# story turns on one predicate -- "did this invocation carry -y" -- so that
# predicate must be shown able to answer NO before a single test trusts it
# answering YES. Without this, a glw_argv_carries_yes that always printed
# "yes" would make every -y assertion below pass while the real defect (a
# forever-hang in production) shipped untouched.
test_glw_yes_flag_detector_can_go_red() {
  echo ""
  echo "=== glab write: the -y detector CAN answer 'no' (falsifiability proof, runs first) ==="

  local log
  log=$(mktemp)
  {
    printf '%s\n' 'mr create -t My MR -d the body -s feat-x -b main'
    printf '%s\n' 'mr update 42 -d the body'
    printf '%s\n' 'issue create -t My issue -d the body'
  } > "$log"

  assert_eq "no" "$(glw_argv_carries_yes "$log" "mr create")"    "-y detector: a recorded 'mr create' WITHOUT -y answers no"
  assert_eq "no" "$(glw_argv_carries_yes "$log" "mr update")"    "-y detector: a recorded 'mr update' WITHOUT -y answers no"
  assert_eq "no" "$(glw_argv_carries_yes "$log" "issue create")" "-y detector: a recorded 'issue create' WITHOUT -y answers no"

  # ...and the same reader answers yes once -y really is there, so the two
  # verdicts are proven to move rather than being constant.
  {
    printf '%s\n' 'mr create -y -t My MR -d the body -s feat-x -b main'
    printf '%s\n' 'mr update 42 -y -d the body'
    printf '%s\n' 'issue create -y -t My issue -d the body'
  } > "$log"

  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr create")"    "-y detector: a recorded 'mr create' WITH -y answers yes"
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr update")"    "-y detector: a recorded 'mr update' WITH -y answers yes"
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "issue create")" "-y detector: a recorded 'issue create' WITH -y answers yes"

  # A flag that merely STARTS with -y is not -y. Without the boundary match
  # this reader would rubber-stamp an invocation that never skipped the
  # prompt.
  printf '%s\n' 'mr create -yolo -t My MR' > "$log"
  assert_eq "no" "$(glw_argv_carries_yes "$log" "mr create")" "-y detector: a '-yolo'-shaped token is NOT counted as -y"

  rm -f "$log"
}

test_glw_forge_pr_create_gitlab_creates_mr_with_yes_flag() {
  echo ""
  echo "=== forge-pr-create (gitlab): opens an MR via glab mr create -- -y present, glab's own flag names, number from a structured re-read ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"
  rm -f "$sandbox/glw_mr_created.flag"

  local out exit_code
  out=$(GLW_GLAB_LOG="$log" \
    GLW_MR_CREATE_STDOUT='!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42' \
    GLW_MR_VIEW_AFTER_JSON='{"iid":42,"id":98765,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/42"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create gitlab: exit 0"
  assert_eq '{"status":"created","data":{"url":"https://gitlab.com/acme/widgets/-/merge_requests/42","number":42},"message":null}' \
    "$out" "forge-pr-create gitlab: the SHARED write envelope, status created, number 42 from the re-read's iid (not its id 98765)"

  # THE ASSERTION THIS STORY EXISTS FOR. Recorded argv, never exit status.
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr create")" \
    "forge-pr-create gitlab: the recorded argv carries -y -- without it glab prompts and an autonomous run hangs forever"

  # The whole invocation pinned in one comparison: -y first, then glab's own
  # flag names in order. A gh-shaped --body/--head/--base would fail here.
  assert_eq 'mr create -y -t My MR -d the body -s feat-x -b main' "$(glw_argv_line "$log" "mr create")" \
    "forge-pr-create gitlab: exact argv -- -y, -t/--title, -d/--description, -s/--source-branch, -b/--target-branch"

  local log_text
  log_text=$(cat "$log")
  assert_eq "0" "$(grep -c -- '--body' "$log" || true)"  "forge-pr-create gitlab: gh's --body never reaches glab (glab calls it --description)"
  assert_eq "0" "$(grep -c -- '--head' "$log" || true)"  "forge-pr-create gitlab: gh's --head never reaches glab (glab calls it --source-branch)"
  assert_eq "0" "$(grep -c -- '--base' "$log" || true)"  "forge-pr-create gitlab: gh's --base never reaches glab (glab calls it --target-branch)"
  assert_contains "mr view feat-x -F json" "$log_text" "forge-pr-create gitlab: the idempotency check and the re-read both go through glab mr view -F json"
  assert_eq "2" "$(glw_argv_count "$log" "mr view")" "forge-pr-create gitlab: exactly two mr view calls -- the pre-create check and the post-create structured re-read"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_create_gitlab_existing_open_mr_is_unchanged() {
  echo ""
  echo "=== forge-pr-create (gitlab): an OPEN merge request already exists for --head -- reports unchanged, never calls glab mr create ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"
  rm -f "$sandbox/glw_mr_created.flag"

  # "opened" (GitLab's own spelling), not "open": the adapter must fold it
  # through _forge_map_state. A fixture spelling it "open" would let a missing
  # fold pass unnoticed.
  local out exit_code
  out=$(GLW_GLAB_LOG="$log" \
    GLW_MR_VIEW_JSON='{"iid":55,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/55"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create gitlab idempotent: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://gitlab.com/acme/widgets/-/merge_requests/55","number":55},"message":null}' \
    "$out" "forge-pr-create gitlab idempotent: status unchanged with the EXISTING MR under data -- no duplicate opened"
  assert_eq "0" "$(glw_argv_count "$log" "mr create")" \
    "forge-pr-create gitlab idempotent: glab mr create was NEVER invoked (a retried phase must not open a second MR)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_create_gitlab_stale_mr_does_not_block() {
  echo ""
  echo "=== forge-pr-create (gitlab): a CLOSED/MERGED merge request on --head does not block -- a fresh one is opened ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log" stale out exit_code
  for stale in closed merged locked; do
    : > "$log"
    rm -f "$sandbox/glw_mr_created.flag"

    out=$(GLW_GLAB_LOG="$log" \
      GLW_MR_VIEW_JSON="{\"iid\":12,\"state\":\"$stale\",\"web_url\":\"https://gitlab.com/acme/widgets/-/merge_requests/12\"}" \
      GLW_MR_CREATE_STDOUT='!91 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/91' \
      GLW_MR_VIEW_AFTER_JSON='{"iid":91,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/91"}' \
      PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

    assert_exit_code "0" "$exit_code" "forge-pr-create gitlab $stale MR: exit 0"
    assert_eq "1" "$(glw_argv_count "$log" "mr create")" "forge-pr-create gitlab $stale MR: glab mr create WAS invoked -- a $stale MR must not block a new one forever"
    assert_eq '{"status":"created","data":{"url":"https://gitlab.com/acme/widgets/-/merge_requests/91","number":91},"message":null}' \
      "$out" "forge-pr-create gitlab $stale MR: only the NEW merge request's identity is reported -- the stale one never leaks"
    assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr create")" "forge-pr-create gitlab $stale MR: the create still carried -y"
  done

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_create_gitlab_missing_glab_prints_mr_url() {
  echo ""
  echo "=== forge-pr-create (gitlab): glab absent -- MANDATORY-PRINT degrade that names the merge-request URL a human can open, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No glab written into the sandbox -- simulates "glab not installed", the
  # phase contract's fourth success criterion. Opening an MR has no other
  # fallback, so the instruction must ALWAYS reach the operator.

  local stderr_file="/tmp/glw_pr_create_no_glab_stderr.$$"
  local out exit_code stderr_text
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "1" "$exit_code" "forge-pr-create gitlab glab-absent: exits non-zero (hard-fail, same contract as the github arm)"
  assert_eq '{"status":"degraded","data":null,"message":"glab not found -- this merge request was not created automatically."}' \
    "$out" "forge-pr-create gitlab glab-absent: degraded envelope naming glab, not gh"
  assert_stderr_contains "glab not found" "$stderr_text" "forge-pr-create gitlab glab-absent: _forge_bin_check's mandatory warning names glab"
  assert_stderr_contains "create it yourself" "$stderr_text" "forge-pr-create gitlab glab-absent: manual instruction printed (MANDATORY-PRINT)"
  assert_stderr_contains "merge request" "$stderr_text" "forge-pr-create gitlab glab-absent: the noun is merge request, not pull request"
  # THE URL a human can open by hand -- the phase contract's fourth success
  # criterion. GitLab's new-MR form, not GitHub's /compare/base...head.
  assert_stderr_contains "https://gitlab.com/acme/widgets/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat-x&merge_request%5Btarget_branch%5D=main" \
    "$stderr_text" "forge-pr-create gitlab glab-absent: stderr prints the merge-request URL the user can open by hand"
  # The copy-pasteable command carries -y too: a human who pastes it into an
  # unattended script must not inherit the hang this story exists to prevent.
  assert_stderr_contains "glab mr create -y" "$stderr_text" "forge-pr-create gitlab glab-absent: the printed manual command itself carries -y"
  if printf '%s' "$stderr_text" | grep -q "gh pr create"; then
    echo -e "${RED}✗${NC} forge-pr-create gitlab glab-absent: the manual instruction told a GitLab user to run gh"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create gitlab glab-absent: the manual instruction never mentions gh"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_create_gitlab_create_failure_degrades() {
  echo ""
  echo "=== forge-pr-create (gitlab): glab mr create itself fails -- degraded envelope, manual instruction, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"
  rm -f "$sandbox/glw_mr_created.flag"

  local stderr_file="/tmp/glw_pr_create_fail_stderr.$$"
  local out exit_code
  out=$(GLW_GLAB_LOG="$log" GLW_MR_CREATE_EXIT=1 \
    GLW_MR_CREATE_STDERR="POST https://gitlab.com/api/v4/projects/1/merge_requests: 409 {message: Another open merge request already exists}" \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create gitlab create-failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create gitlab create-failure: degraded envelope"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-pr-create gitlab create-failure: data is null on degraded"
  assert_contains "glab mr create exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-create gitlab create-failure: message names the glab exit code"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create gitlab create-failure: manual instruction printed"
  # Even the failing call carried -y: this branch is a genuine glab failure,
  # never a prompt the run silently sat on.
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr create")" "forge-pr-create gitlab create-failure: the failing invocation still carried -y"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_create_gitlab_reread_failure_keeps_created_url() {
  echo ""
  echo "=== forge-pr-create (gitlab): the MR was created but the re-read cannot confirm its number -- keeps the url, status created, exit 0 ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"
  rm -f "$sandbox/glw_mr_created.flag"

  # GLW_MR_VIEW_AFTER_JSON deliberately unset, so the post-create re-read
  # falls to the stub's non-zero not-found arm.
  local stderr_file="/tmp/glw_pr_create_reread_stderr.$$"
  local out exit_code stderr_text
  out=$(GLW_GLAB_LOG="$log" \
    GLW_MR_CREATE_STDOUT='!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$exit_code" "forge-pr-create gitlab re-read failure: exit 0 -- the merge request really was created"
  assert_eq '{"status":"created","data":{"url":"https://gitlab.com/acme/widgets/-/merge_requests/42","number":null},"message":null}' \
    "$out" "forge-pr-create gitlab re-read failure: the url survives under data with number:null, status stays created"
  assert_stderr_contains "Warning:" "$stderr_text" "forge-pr-create gitlab re-read failure: warns rather than erroring"
  assert_stderr_contains "https://gitlab.com/acme/widgets/-/merge_requests/42" "$stderr_text" "forge-pr-create gitlab re-read failure: the Warning names the created MR's url"
  if printf '%s' "$stderr_text" | grep -qE "create it yourself|git push -u origin"; then
    echo -e "${RED}✗${NC} forge-pr-create gitlab re-read failure: the create-it-yourself fallback was printed for an MR that already exists -- following it would open a duplicate"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create gitlab re-read failure: the create-it-yourself fallback is never printed once a url is in hand"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_edit_gitlab_updates_with_yes_flag() {
  echo ""
  echo "=== forge-pr-edit (gitlab): updates an MR via glab mr update -- -y present, -d not --body, status unchanged ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"
  rm -f "$sandbox/glw_mr_created.flag"

  local out exit_code
  out=$(GLW_GLAB_LOG="$log" \
    GLW_MR_VIEW_JSON='{"iid":303,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/303"}' \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-edit gitlab: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://gitlab.com/acme/widgets/-/merge_requests/303","number":303},"message":null}' \
    "$out" "forge-pr-edit gitlab: status unchanged (the identifier already existed) with {url, number} from the structured re-read"

  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr update")" \
    "forge-pr-edit gitlab: the recorded argv carries -y -- glab mr update prompts without it and the run hangs"
  # The merge request is a POSITIONAL argument here, unlike gh pr edit's
  # otherwise similar shape, and the body flag is -d.
  assert_eq 'mr update 303 -y -d updated body' "$(glw_argv_line "$log" "mr update")" \
    "forge-pr-edit gitlab: exact argv -- positional id, then -y, then -d/--description"
  assert_eq "0" "$(grep -c -- '--body' "$log" || true)" "forge-pr-edit gitlab: gh's --body never reaches glab"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_edit_gitlab_missing_glab_prints_mr_url() {
  echo ""
  echo "=== forge-pr-edit (gitlab): glab absent -- MANDATORY-PRINT degrade naming the MR's own URL, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No glab in the sandbox.

  local stderr_file="/tmp/glw_pr_edit_no_glab_stderr.$$"
  local out exit_code stderr_text
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "1" "$exit_code" "forge-pr-edit gitlab glab-absent: exits non-zero"
  assert_eq '{"status":"degraded","data":null,"message":"glab not found -- this merge request was not edited automatically."}' \
    "$out" "forge-pr-edit gitlab glab-absent: degraded envelope naming glab"
  assert_stderr_contains "edit it yourself" "$stderr_text" "forge-pr-edit gitlab glab-absent: manual instruction printed"
  assert_stderr_contains "https://gitlab.com/acme/widgets/-/merge_requests/303" "$stderr_text" \
    "forge-pr-edit gitlab glab-absent: stderr prints the merge-request URL the user can open by hand"
  assert_stderr_contains "glab mr update 303 -y" "$stderr_text" "forge-pr-edit gitlab glab-absent: the printed manual command itself carries -y"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_pr_edit_gitlab_update_failure_degrades() {
  echo ""
  echo "=== forge-pr-edit (gitlab): glab mr update itself fails -- degraded envelope, manual instruction, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"

  local stderr_file="/tmp/glw_pr_edit_fail_stderr.$$"
  local out exit_code
  out=$(GLW_GLAB_LOG="$log" GLW_MR_UPDATE_EXIT=1 GLW_MR_UPDATE_STDERR="404 Not Found" \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit gitlab update-failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit gitlab update-failure: degraded envelope"
  assert_contains "glab mr update exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-edit gitlab update-failure: message names the glab exit code"
  assert_stderr_contains "edit it yourself" "$(cat "$stderr_file")" "forge-pr-edit gitlab update-failure: manual instruction printed"
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "mr update")" "forge-pr-edit gitlab update-failure: the failing invocation still carried -y"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_forge_issue_create_gitlab_soft_fails_and_carries_yes() {
  echo ""
  echo "=== forge-issue-create (gitlab): glab issue create -y -- and the always-exit-0 soft-fail contract survives on the gitlab branch ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  glw_install_fake_glab "$sandbox"

  local log="$sandbox/glab.log"
  : > "$log"

  local out exit_code
  out=$(GLW_GLAB_LOG="$log" \
    GLW_ISSUE_CREATE_STDOUT='#7 Backend spec (acme/widgets)
 https://gitlab.com/acme/widgets/-/issues/7' \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create gitlab: exit 0"
  assert_eq '{"status":"created","data":{"url":"https://gitlab.com/acme/widgets/-/issues/7","number":7},"message":null}' \
    "$out" "forge-issue-create gitlab: the SHARED write envelope, status created, number parsed from the issue URL"

  assert_eq "yes" "$(glw_argv_carries_yes "$log" "issue create")" \
    "forge-issue-create gitlab: the recorded argv carries -y -- glab issue create prompts without it"
  assert_eq 'issue create -y -t Backend spec -d the body' "$(glw_argv_line "$log" "issue create")" \
    "forge-issue-create gitlab: exact argv -- -y, -t/--title, -d/--description"
  assert_eq "0" "$(grep -c -- '--body' "$log" || true)" "forge-issue-create gitlab: gh's --body never reaches glab"

  # SOFT-FAIL, both ways it can be reached. A failed issue must NEVER block PR
  # creation, so the gitlab branch may not acquire a different exit-code
  # contract from the github one.
  local fail_out fail_rc absent_out absent_rc
  : > "$log"
  fail_out=$(GLW_GLAB_LOG="$log" GLW_ISSUE_CREATE_EXIT=1 GLW_ISSUE_CREATE_STDERR="403 Forbidden" \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && fail_rc=0 || fail_rc=$?
  assert_exit_code "0" "$fail_rc" "forge-issue-create gitlab glab-failure: EXITS 0 (soft-fail preserved -- a failed issue never blocks a PR)"
  assert_eq "degraded" "$(printf '%s' "$fail_out" | jq -r '.status')" "forge-issue-create gitlab glab-failure: the outcome is reported in status, not in the exit code"
  assert_contains "glab issue create exited 1" "$(printf '%s' "$fail_out" | jq -r '.message')" "forge-issue-create gitlab glab-failure: message names the glab exit code"
  assert_eq "yes" "$(glw_argv_carries_yes "$log" "issue create")" "forge-issue-create gitlab glab-failure: the failing invocation still carried -y"

  rm -f "$sandbox/glab"
  absent_out=$(PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && absent_rc=0 || absent_rc=$?
  assert_exit_code "0" "$absent_rc" "forge-issue-create gitlab glab-absent: EXITS 0 (soft-fail preserved)"
  assert_eq '{"status":"degraded","data":null,"message":"glab not found -- this issue was not created automatically."}' \
    "$absent_out" "forge-issue-create gitlab glab-absent: degraded envelope naming glab, not gh"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# A SOURCE-LEVEL guard on top of the runtime ones. The runtime assertions
# above prove the three code paths the tests happen to drive carry -y; this
# one proves EVERY glab write invocation in the file does, including one a
# future edit adds without a test. It is also the assertion that goes red
# fastest under the mutation check this story was required to perform
# (delete -y from any one write path).
test_glw_every_glab_write_invocation_carries_yes_in_source() {
  echo ""
  echo "=== source guard: every glab WRITE invocation in aimi-cli.sh carries -y, and no gh flag name leaks into a glab call ==="

  local write_lines missing=0 total=0 line
  # Only the three WRITE subcommands. `glab mr view` is a read and has no
  # confirmation prompt, so requiring -y there would be wrong, not stricter.
  # Comment lines are dropped: the section header carries a worked example of
  # the call shape, and counting it would make `total` report four write
  # invocations where the file has three.
  write_lines=$(grep -nE '_forge_capture .* -- glab (mr create|mr update|issue create)' "$CLI" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    if ! printf '%s' "$line" | grep -qE ' -y( |$)'; then
      missing=$((missing + 1))
      echo -e "${RED}✗${NC} source guard: a glab write invocation is MISSING -y: $line"
    fi
  done <<< "$write_lines"

  assert_eq "3" "$total"   "source guard: all three glab write invocations are present (mr create, mr update, issue create)"
  assert_eq "0" "$missing" "source guard: every glab write invocation carries -y -- without it the run hangs on a confirmation prompt"

  # Each verb named individually, so a red result says WHICH one regressed.
  local verb
  for verb in "mr create" "mr update" "issue create"; do
    if printf '%s' "$write_lines" | grep -qE "glab ${verb} .*-y( |$)|glab ${verb} -y( |$)"; then
      echo -e "${GREEN}✓${NC} source guard: glab $verb carries -y"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} source guard: glab $verb does NOT carry -y"
      ((TESTS_FAILED++))
    fi
  done

  # gh's flag vocabulary must never appear inside a glab invocation.
  local glab_calls
  glab_calls=$(grep -E '_forge_capture .* -- glab ' "$CLI" || true)
  assert_eq "0" "$(printf '%s' "$glab_calls" | grep -c -- '--body' || true)" "source guard: no glab invocation passes gh's --body"
  assert_eq "0" "$(printf '%s' "$glab_calls" | grep -c -- '--head' || true)"  "source guard: no glab invocation passes gh's --head"
  assert_eq "0" "$(printf '%s' "$glab_calls" | grep -c -- '--base' || true)"  "source guard: no glab invocation passes gh's --base"
}

# The account override is a LATER story's subject and is deliberately absent
# here. What this story owes it is a landing site: every glab call written as
# a single `_forge_capture ... -- glab ...` statement, so a bash prefix
# assignment can be added on the line above without restructuring anything.
# This test pins that shape so a future edit cannot quietly remove it.
test_glw_gitlab_write_call_sites_are_prefix_assignment_ready() {
  echo ""
  echo "=== landing site: every glab call is a single _forge_capture statement a prefix assignment can sit above ==="

  local fn body glab_lines shaped=0 unshaped=0 line
  for fn in _forge_pr_create_gitlab _forge_pr_edit_gitlab _forge_issue_create_gitlab; do
    body=$(glw_fn_body "$fn")
    if [ -z "$body" ]; then
      echo -e "${RED}✗${NC} landing site: $fn is not defined in aimi-cli.sh"
      ((TESTS_FAILED++))
      continue
    fi
    # An INVOCATION is `glab` followed by one of its subcommands. Comments and
    # double-quoted strings are stripped first so the many error/warning
    # messages that legitimately mention "glab mr create" in prose are not
    # mistaken for calls -- the naive grep counted seventeen of them.
    glab_lines=$(printf '%s\n' "$body" \
      | sed 's/"[^"]*"//g; s/#.*//' \
      | grep -E 'glab (mr|issue) ' || true)
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if printf '%s' "$line" | grep -qE '_forge_capture [a-z_]+ [a-z_]+ [a-z_]+ -- glab '; then
        shaped=$((shaped + 1))
      else
        unshaped=$((unshaped + 1))
        echo -e "${RED}✗${NC} landing site: a glab call in $fn is not a plain _forge_capture statement: $line"
      fi
    done <<< "$glab_lines"
  done

  assert_eq "0" "$unshaped" "landing site: every glab call in the three gitlab write adapters is a plain _forge_capture statement"
  # 2 in pr-create (idempotency check + re-read) + 1 create, 1 update + 1
  # re-read in pr-edit, 1 in issue-create.
  assert_eq "6" "$shaped" "landing site: all six glab calls across the three adapters are shaped for a prefix assignment"

  # `export` is forbidden on this path for the same reason it is on the gh
  # side: a process-wide token changes what every later identity probe in the
  # same process reports.
  local all_bodies
  all_bodies=$(glw_fn_body _forge_pr_create_gitlab; glw_fn_body _forge_pr_edit_gitlab; glw_fn_body _forge_issue_create_gitlab)
  assert_eq "0" "$(printf '%s' "$all_bodies" | grep -cE '^\s*export ' || true)" "landing site: no gitlab write adapter exports a credential into the process environment"

  # And the section header says so in words, so the later story finds a
  # landing site rather than having to infer one from shape alone.
  local header
  header=$(sed -n '/^# GitLab write adapters/,/^_forge_glab_write_url()/p' "$CLI")
  assert_contains "ACCOUNT-OVERRIDE LANDING SITE" "$header" "landing site: the section header names the landing site explicitly for the account-override story"
  assert_contains "PREFIX ASSIGNMENT" "$header" "landing site: the header states the mechanism (prefix assignment, never export)"
}

# ============================================================================
# GitLab ACCOUNT selection (gla_) -- the DEGRADED branch, and its proof
# ============================================================================
# Phase 2 gave gh writes a remembered-account override built on exactly one
# call: `gh auth token --user <login> --hostname <host>`. This story asked
# whether glab has a counterpart, and the answer -- read off gitlab-org/cli's
# own source, since glab is not installed here (this phase's declared
# verification ceiling) -- is NO:
#
#   * internal/commands/auth/ holds login, logout, status, credentialhelper,
#     docker and generate. There is no `token` subcommand.
#   * internal/config/schema.go declares `token` as Scope: ScopePerHost, and
#     internal/commands/auth/status/status.go iterates cfg.Hosts() reading
#     cfg.GetWithSource(instance, "token", true) -- instances, never logins.
#     There is no per-account credential to retrieve in the first place.
#
# So the gitlab write path degrades to the machine's active glab session, and
# what these tests police is that the degradation is HONEST: the account glab
# reports as active is byte-identical before and after a routed write, no
# token variable is ever exported, and the one selection mechanism glab does
# have -- an operator-exported GITLAB_TOKEN -- still reaches the child.
#
# WHY THE FIXTURE READS ITS ENVIRONMENT, AND WHY THAT IS THE WHOLE STORY. A
# before/after comparison against a fake that always prints the same account
# passes no matter what the code under test does -- including when a token
# leaks process-wide, which is the exact violation the comparison exists to
# catch. Phase 2 shipped that tautology. So this fixture models glab's real
# precedence (env token over stored token, empty variables skipped) and
# test_gla_fake_glab_can_report_a_differing_active_account PROVES it can
# print a different account -- twice, by two independent levers -- before a
# single before/after assertion below trusts it printing the same one.

# Writes a fake `glab` into an existing setup_forge_cli_sandbox directory that
# answers `auth status` as well as the `mr view`/`mr create` pair, so ONE stub
# can serve both halves of a before/write/after sequence.
#
# Driven entirely by environment, exactly like the real binary:
#   GLA_GLAB_LOG              optional; every invocation's argv, one line each
#   GLA_GLAB_TOKEN_LOG        optional; "<verb> <subverb> <token-or-<unset>>"
#                             per call, on its OWN channel -- never argv, so
#                             the "no token reached argv" scan stays honest
#   GLA_GLAB_CONFIG_ACCOUNT   account the STORED per-host token belongs to
#                             (default "machine-account") -- lever 1
#   GLA_GLAB_ENV_TOKEN_ACCOUNT account an ENV token belongs to
#                             (default "env-token-account") -- lever 2
#   GLA_MR_VIEW_JSON          `mr view` stdout on exit 0; absent means 404
#   GLA_MR_VIEW_AFTER_JSON    `mr view` stdout once `mr create` has run
#   GLA_MR_CREATE_STDOUT      `mr create` stdout
#
# The status line is printed to STDERR and worded `Logged in to <host> as
# <username> (<source>)` because that is what glab does -- it logs the status
# block through LogErrorf, and _forge_auth_status_gitlab merges 2>&1 for that
# reason. A stub that printed to stdout, or that emitted gh's "Active
# account: true" marker, would exercise a parser this file does not have.
gla_install_fake_glab_auth() {
  local sandbox="$1"
  cat > "$sandbox/glab" << 'GLA_FAKE_GLAB'
#!/usr/bin/env bash
if [ -n "${GLA_GLAB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GLA_GLAB_LOG"
fi

# Real glab resolves a token from the environment first and falls back to the
# per-host config entry: GetFromEnvWithSource walks GITLAB_TOKEN,
# GITLAB_ACCESS_TOKEN, OAUTH_TOKEN in that order and SKIPS an empty value
# (`if val := os.Getenv(e); val != ""`). Modelled exactly -- the empty-skip
# included -- because "an empty variable is not a token" is precisely the
# distinction a blanking bug would blur.
gla_tok=""
for gla_candidate in "${GITLAB_TOKEN:-}" "${GITLAB_ACCESS_TOKEN:-}" "${OAUTH_TOKEN:-}"; do
  if [ -n "$gla_candidate" ]; then
    gla_tok="$gla_candidate"
    break
  fi
done

if [ -n "${GLA_GLAB_TOKEN_LOG:-}" ]; then
  printf '%s %s\n' "$1 $2" "${gla_tok:-<unset>}" >> "$GLA_GLAB_TOKEN_LOG"
fi

# THE LINE THAT MAKES THE BEFORE/AFTER CHECK ABLE TO FAIL: whichever token is
# actually in force decides which account is reported as logged in. A token
# that leaked into the environment therefore CHANGES this answer.
gla_account="${GLA_GLAB_CONFIG_ACCOUNT:-machine-account}"
gla_source="the configuration file"
if [ -n "$gla_tok" ]; then
  gla_account="${GLA_GLAB_ENV_TOKEN_ACCOUNT:-env-token-account}"
  gla_source="environment variable GITLAB_TOKEN"
fi

gla_host="gitlab.com"
if [ "${3:-}" = "--hostname" ] && [ -n "${4:-}" ]; then
  gla_host="$4"
fi

gla_flag="$(dirname "$0")/gla_mr_created.flag"

case "$1 $2" in
  "auth status")
    printf 'Logged in to %s as %s (%s)\n' "$gla_host" "$gla_account" "$gla_source" >&2
    exit 0
    ;;
  "mr view")
    if [ -f "$gla_flag" ] && [ -n "${GLA_MR_VIEW_AFTER_JSON:-}" ]; then
      printf '%s' "$GLA_MR_VIEW_AFTER_JSON"
      exit 0
    fi
    if [ -n "${GLA_MR_VIEW_JSON:-}" ]; then
      printf '%s' "$GLA_MR_VIEW_JSON"
      exit 0
    fi
    echo "404 Not Found" >&2
    exit 1
    ;;
  "mr create")
    : > "$gla_flag"
    printf '%s\n' "${GLA_MR_CREATE_STDOUT:-}"
    exit 0
    ;;
esac
echo "fake-glab (account): unhandled invocation: $*" >&2
exit 99
GLA_FAKE_GLAB
  chmod +x "$sandbox/glab"
}

# The account `forge-auth-status` reports as active for this repository, read
# through the PRODUCTION parser (_forge_auth_status_gitlab) rather than by
# re-reading the stub's own output -- a comparison against a parser the test
# wrote itself would prove nothing about the file under test.
# Usage: gla_active_account <sandbox> [VAR=value ...]
gla_active_account() {
  local sandbox="$1"
  shift
  env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    "$@" PATH="$sandbox" "$CLI" forge-auth-status 2>/dev/null | jq -r '.data.account // "<none>"'
}

# Counts `export`/`declare -x` of any forge token variable in a given file.
#
# COUNTED WITH `grep -c`, AND THAT IS NOT A STYLE CHOICE. This suite runs
# under `set -o pipefail`. In the `grep -v ... | grep -q ...` shape, the right
# half exits the instant it matches, SIGPIPEs the left half, and the pipeline
# reports FAILURE -- so an `if` on it reads a real hit as "no hit" and the
# guard fails OPEN. Phase 2 found exactly that: a deliberately planted
# `export GH_TOKEN=...` passed straight through the `grep -q` form.
# `grep -c` consumes all of its input and cannot fire early, and the trailing
# `|| count=0` absorbs grep's exit 1 on zero matches rather than aborting.
#
# Both glab's names and gh's are covered. GITLAB_ACCESS_TOKEN and OAUTH_TOKEN
# are in the pattern because glab honors all three (internal/config/schema.go
# lists EnvVars {GITLAB_TOKEN, GITLAB_ACCESS_TOKEN, OAUTH_TOKEN} for the
# `token` key), so exporting the second or third would leak exactly as far as
# exporting the first.
# Usage: gla_count_token_exports <file>
gla_count_token_exports() {
  local file="$1" count
  count=$(grep -v '^[[:space:]]*#' "$file" | grep -cE '(export|declare -x)[[:space:]]+(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITLAB_TOKEN|GITLAB_ACCESS_TOKEN|OAUTH_TOKEN)') || count=0
  printf '%s' "$count"
}

# The GitLab write-adapter section header, which is where a reader meets the
# account question and must find it answered.
gla_write_header() {
  sed -n '/^# GitLab write adapters/,/^_forge_glab_write_url()/p' "$CLI"
}

# RUNS BEFORE EVERY BEFORE/AFTER ASSERTION IN THIS SECTION, ON PURPOSE. The
# machine-account-unchanged claim is a comparison of two readings, and a fake
# that cannot report anything but one account makes that comparison pass
# unconditionally -- even while a token leaks process-wide. So the stub is
# shown able to report a DIFFERENT active account by two independent levers
# before anything trusts it reporting the same one.
test_gla_fake_glab_can_report_a_differing_active_account() {
  echo ""
  echo "=== glab account fixture: the stub CAN report a different active account (falsifiability proof, runs first) ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gla_install_fake_glab_auth "$sandbox"

  # Baseline: the stored per-host session.
  assert_eq "machine-account" "$(gla_active_account "$sandbox")" \
    "fixture proof: with no env token the stub reports the machine's stored session account"

  # LEVER 1 -- a different stored session. Proves the reported account is not
  # a constant baked into the stub.
  assert_eq "someone-else" "$(gla_active_account "$sandbox" GLA_GLAB_CONFIG_ACCOUNT=someone-else)" \
    "fixture proof #1: a different stored session makes the stub report a DIFFERENT active account"

  # LEVER 2 -- a token in the environment. This is the one that matters: it is
  # the exact mechanism by which an exported override would corrupt the
  # after-reading, so the fixture must be shown to notice it.
  assert_eq "octocat-gl" \
    "$(env GITLAB_TOKEN=glpat-leaked GLA_GLAB_ENV_TOKEN_ACCOUNT=octocat-gl PATH="$sandbox" "$CLI" forge-auth-status 2>/dev/null | jq -r '.data.account')" \
    "fixture proof #2: a GITLAB_TOKEN in the environment makes the stub report the ENV token's account -- so a leaked override would be visible"

  # ...and each of glab's other two token variables moves it too, which is why
  # the export guard's pattern covers all three rather than GITLAB_TOKEN alone.
  assert_eq "octocat-gl" \
    "$(env GITLAB_ACCESS_TOKEN=glpat-leaked GLA_GLAB_ENV_TOKEN_ACCOUNT=octocat-gl PATH="$sandbox" "$CLI" forge-auth-status 2>/dev/null | jq -r '.data.account')" \
    "fixture proof: GITLAB_ACCESS_TOKEN moves the reported account too (glab honors all three names)"

  # An EMPTY variable is not a token -- glab skips it (GetFromEnvWithSource:
  # `if val := os.Getenv(e); val != ""`). Without this the fixture could not
  # tell "no override" apart from "override blanked the inherited value".
  assert_eq "machine-account" \
    "$(env GITLAB_TOKEN= PATH="$sandbox" "$CLI" forge-auth-status 2>/dev/null | jq -r '.data.account')" \
    "fixture proof: an EMPTY GITLAB_TOKEN is skipped, not honored -- the stored session still wins"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# eval's the gitlab pr-create path and its dependencies into the CURRENT shell,
# alongside the auth-status parser that reads the machine account back.
#
# Sourced rather than driven through `$CLI` for one reason, and it is the whole
# reason the before/after check below means anything: a separate `$CLI` process
# per reading makes a process-wide `export` UNDETECTABLE, because the export
# dies with the process that made it. Three subprocesses would compare equal no
# matter what the write did in its own address space -- the exact tautology
# phase 2 shipped. In one shell, an export survives from the write into the
# after-reading, so the comparison can actually fail. Mirrors
# source_forge_account_override_functions' technique and phase 2's own AC5.3.
gla_source_gitlab_write_path() {
  local fn
  for fn in _forge_bin_check _forge_capture _forge_map_state \
            _forge_build_write_data _forge_emit_write_status \
            _forge_pr_write_print_manual _forge_glab_write_url \
            _forge_auth_status_gitlab _forge_pr_create_gitlab; do
    eval "$(sed -n "/^${fn}()/,/^}/p" "$CLI")"
  done
}

# Success criterion 3's degraded half, asserted end to end: a routed GitLab
# write leaves the machine's active glab account byte-identical.
test_gla_gitlab_write_leaves_the_machine_account_untouched() {
  echo ""
  echo "=== gitlab writes: the machine's active glab account is byte-identical before and after a routed write ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gla_install_fake_glab_auth "$sandbox"

  gla_source_gitlab_write_path

  local log="$sandbox/glab.log" toklog="$sandbox/glab-token.log"
  : > "$log"
  : > "$toklog"
  rm -f "$sandbox/gla_mr_created.flag"

  # ONE shell: before-reading, the real write, after-reading. Emitted as three
  # tab-separated fields so a single subshell carries all of them out.
  #
  # THE WRITE IS A PLAIN STATEMENT REDIRECTED TO A FILE, never `s=$(...)`, and
  # that is the difference between a probe with teeth and a probe without one.
  # A command substitution is its own subshell: an `export` the function made
  # inside it would die with that subshell, and the after-reading in the parent
  # would be clean no matter what -- the tautology all over again, just moved
  # one level in. Verified by mutation: with the write wrapped in `$(...)`, a
  # planted `export GITLAB_TOKEN` in _forge_pr_create_gitlab left this whole
  # test green. Run as a statement, the same plant turns it red.
  local probe before after status writeout
  writeout=$(mktemp)
  probe=$(
    unset GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export PATH="$sandbox:$PATH"
    export GLA_GLAB_LOG="$log" GLA_GLAB_TOKEN_LOG="$toklog"
    export GLA_MR_CREATE_STDOUT='!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42'
    export GLA_MR_VIEW_AFTER_JSON='{"iid":42,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/42"}'

    local b a s
    b=$(_forge_auth_status_gitlab gitlab.com | jq -r '.account')
    _forge_pr_create_gitlab "My MR" main feat-x "the body" > "$writeout" 2>/dev/null || true
    s=$(jq -r '.status' < "$writeout" 2>/dev/null) || s="<unparseable>"
    a=$(_forge_auth_status_gitlab gitlab.com | jq -r '.account')
    printf '%s\t%s\t%s' "$b" "$s" "$a"
  )
  rm -f "$writeout"
  before=$(printf '%s' "$probe" | cut -f1)
  status=$(printf '%s' "$probe" | cut -f2)
  after=$(printf '%s' "$probe" | cut -f3)

  assert_eq "machine-account" "$before" "machine account: the before-reading is the stored session, as the fixture proof established"
  assert_eq "created" "$status" "machine account: the write really happened, so the after-reading is not vacuous"
  assert_eq "$before" "$after" "machine account: byte-identical before and after, read in the SAME shell the write ran in -- an export would have been visible here"
  assert_eq "machine-account" "$after" "machine account: and it is still the stored session, not an override's account"

  # THE TEETH. The identical probe with a deliberate process-wide export in the
  # middle DOES move the after-reading, so the equality above is a real
  # observation of the code under test rather than a fixture that cannot fail.
  # Without this, an assertion that two readings match is indistinguishable
  # from an assertion that nothing was ever read.
  local leaked_after
  leaked_after=$(
    unset GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export PATH="$sandbox:$PATH"
    export GLA_GLAB_ENV_TOKEN_ACCOUNT=leaked-override-account
    _forge_auth_status_gitlab gitlab.com >/dev/null
    export GITLAB_TOKEN="glpat-leaked-into-the-process"
    _forge_auth_status_gitlab gitlab.com | jq -r '.account'
  )
  assert_eq "leaked-override-account" "$leaked_after" \
    "machine account: a process-wide export between two readings DOES change the second one -- the before/after comparison is capable of going red"

  # The direct statement of the degradation: glab was handed no token at all,
  # on any call, so it acted as its own active session throughout.
  local tokens
  tokens=$(grep -c '<unset>' "$toklog") || tokens=0
  assert_eq "5" "$tokens" "degrades to the active session: every glab call in the probe -- the two auth-status readings plus the three write calls -- ran with NO token supplied by this CLI"
  assert_eq "0" "$(grep -cv '<unset>' "$toklog")" "degrades to the active session: not one glab call received a token from this CLI"

  # And nothing leaked into argv either -- the rule that outlives the branch.
  assert_eq "0" "$(grep -cE 'glpat-|GITLAB_TOKEN' "$log")" "argv scan: no token and no token variable appears in any recorded glab argv line"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# The other half of "degrades by using the machine's active glab session":
# glab's ONE real selection mechanism is an operator-exported token, and this
# path must not revoke it. Phase 2 shipped a bare `TOKEN=""` prefix that did
# exactly that; the gitlab path avoids it by setting nothing at all, and this
# pins that outcome rather than the absence of a line of code.
test_gla_inherited_gitlab_token_reaches_glab_untouched() {
  echo ""
  echo "=== gitlab writes: an operator-exported GITLAB_TOKEN reaches glab untouched -- never blanked ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gla_install_fake_glab_auth "$sandbox"

  local log="$sandbox/glab.log" toklog="$sandbox/glab-token.log"
  : > "$log"
  : > "$toklog"
  rm -f "$sandbox/gla_mr_created.flag"

  local out exit_code
  out=$(env GITLAB_TOKEN=caller-exported-token \
    GLA_GLAB_LOG="$log" GLA_GLAB_TOKEN_LOG="$toklog" \
    GLA_MR_CREATE_STDOUT='!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42' \
    GLA_MR_VIEW_AFTER_JSON='{"iid":42,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/42"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "inherited token: forge-pr-create still succeeds"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "inherited token: the write really happened"

  # EVERY call, not merely the writing one: the idempotency check, the create
  # and the re-read are one operation and must run as one account.
  assert_eq "3" "$(grep -c 'caller-exported-token' "$toklog")" \
    "inherited token: all three glab calls received the caller's exported GITLAB_TOKEN untouched -- never blanked, and never on only some of them"
  assert_eq "0" "$(grep -c '<unset>' "$toklog")" \
    "inherited token: not one glab call had the inherited token stripped from its environment"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# The export guard, hardened, plus the proof that the hardening was necessary.
test_gla_export_guard_counts_rather_than_short_circuits() {
  echo ""
  echo "=== export guard: no token variable is exported anywhere in aimi-cli.sh, counted so the guard cannot fail open ==="

  assert_eq "0" "$(gla_count_token_exports "$CLI")" \
    "export rule: aimi-cli.sh exports no GH_TOKEN, GH_ENTERPRISE_TOKEN, GITLAB_TOKEN, GITLAB_ACCESS_TOKEN or OAUTH_TOKEN anywhere -- a prefix assignment is the only permitted form"

  # FALSIFIABILITY. A guard asserting "zero" against a file that has zero is
  # indistinguishable from a guard that always prints zero, so the counter is
  # shown to move on a copy with a deliberately planted export.
  local planted
  planted=$(mktemp)
  cp "$CLI" "$planted"
  printf '%s\n' 'export GITLAB_TOKEN="$gitlab_token_override"' >> "$planted"
  assert_eq "1" "$(gla_count_token_exports "$planted")" \
    'export guard proof: a planted "export GITLAB_TOKEN" is COUNTED -- the guard can go red'

  printf '%s\n' 'export GH_TOKEN="$gh_token_override"' >> "$planted"
  assert_eq "2" "$(gla_count_token_exports "$planted")" \
    "export guard proof: a second planted export raises the count to 2 -- every hit is seen, not just the first"

  # AND WHY `grep -c` RATHER THAN `grep -v | grep -q`, demonstrated rather than
  # asserted: under pipefail the -q form exits the instant it matches, which
  # SIGPIPEs the `grep -v` still feeding it and makes the whole pipeline
  # non-zero -- so an `if` on it reads a real hit as "no hit".
  #
  # The planted export goes at the TOP of this copy, not the bottom, and that
  # placement is the experiment rather than a detail: `grep -q` must exit while
  # the left half still has thousands of lines left to write, or there is
  # nothing left to SIGPIPE and the demonstration would be timing-dependent.
  # aimi-cli.sh is far larger than a pipe buffer, so a first-line match makes
  # the race deterministic in the direction being shown.
  local early
  early=$(mktemp)
  printf '%s\n' 'export GITLAB_TOKEN="$gitlab_token_override"' > "$early"
  cat "$CLI" >> "$early"

  assert_eq "1" "$(gla_count_token_exports "$early")" \
    "export guard proof: the counting form sees the export on line 1 of a 28k-line file"

  local short_circuit_verdict="absent"
  if (set -o pipefail; grep -v '^[[:space:]]*#' "$early" | grep -qE '(export|declare -x)[[:space:]]+GITLAB_TOKEN') >/dev/null 2>&1; then
    short_circuit_verdict="present"
  fi
  assert_eq "absent" "$short_circuit_verdict" \
    'export guard proof: the discarded "grep -v | grep -q" shape reports ABSENT on that same file -- fail-open, which is why this guard counts instead'

  # A comment mentioning the forbidden form is not a violation of it. The
  # header this story rewrote says `export` several times, on purpose.
  local commented
  commented=$(mktemp)
  cp "$CLI" "$commented"
  printf '%s\n' '#   export GITLAB_TOKEN="..."   <- never do this' >> "$commented"
  assert_eq "0" "$(gla_count_token_exports "$commented")" \
    "export guard: a commented-out export is not counted, so the section header can name the forbidden form in prose"

  rm -f "$planted" "$commented" "$early"
}

# The header is where a reader meets the question, so the answer has to be
# there and has to be concrete.
test_gla_gitlab_write_header_records_the_determination() {
  echo ""
  echo "=== gitlab write header: records WHY the account override is not wired, in one concrete line ==="

  local header
  header=$(gla_write_header)

  # The reason is ONE line. A paragraph is a place to hide a hedge; a single
  # line has to commit.
  local reason_line reason_count
  reason_line=$(printf '%s\n' "$header" | grep -F 'glab has no per-account token retrieval' || true)
  reason_count=$(printf '%s\n' "$header" | grep -cF 'glab has no per-account token retrieval') || reason_count=0
  assert_eq "1" "$reason_count" "determination: the header states the reason on exactly ONE line"

  # It names the MISSING CAPABILITY concretely -- the specific call that does
  # not exist and the specific reason there is nothing for it to return --
  # rather than the useless "not supported".
  assert_contains "glab auth token" "$reason_line" "determination: the one line names the missing subcommand by name"
  assert_contains "ScopePerHost" "$reason_line" "determination: the one line names the concrete reason there is no per-account credential -- the store is keyed by host"

  # The evidence is recorded alongside it, so the next reader can re-check the
  # finding instead of re-litigating it.
  assert_contains "internal/commands/auth/" "$header" "determination: the header cites the glab source path the subcommand list was read from"
  assert_contains "internal/config/schema.go" "$header" "determination: the header cites the schema that keys the token store by host"
  assert_contains "status.go" "$header" "determination: the header cites the auth-status source that iterates instances rather than logins"

  # The host-dependence question was ASKED and answered, because the
  # GH_TOKEN/GH_ENTERPRISE_TOKEN split next door makes it the first thing a
  # reader will suspect -- and getting it wrong on the gh side fails silently.
  assert_contains "EnvKeyEquivalence" "$header" "determination: the header records that glab's token env resolution takes no hostname, so there is no GHES-style host split here"
  assert_contains "GITLAB_ACCESS_TOKEN" "$header" "determination: the header names all three token variables glab honors, not GITLAB_TOKEN alone"

  # And it states the behavior that follows, in the reader's terms.
  assert_contains "ACTIVE glab session" "$header" "determination: the header says what the path does instead -- degrade to the machine's active session"

  # The escape hatch that survives the degradation is documented too: it is
  # the only account-selection mechanism a GitLab user still has here.
  assert_contains "exported GITLAB_TOKEN" "$header" "determination: the header records the one selection mechanism that still works -- an operator-exported GITLAB_TOKEN"
}

# interactivity.md's agent-mode rule, unchanged from phase 2: an auto-answer is
# applied for the invocation and NEVER persisted, because one CI run must not
# silently answer the question forever for every human afterwards. On this path
# the auto-answer is "use the active account" -- which is what every gitlab
# write already does -- so applied-for-this-invocation and changed-nothing are
# the same operation, and the observable is that no store file appears.
test_gla_agent_mode_persists_no_gitlab_account_answer() {
  echo ""
  echo "=== agent mode: a routed gitlab write records no account answer -- applied for the invocation, never persisted ==="

  setup_detect_forge_fixture origin https://gitlab.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox config
  sandbox=$(setup_forge_cli_sandbox)
  config=$(mktemp -d)
  trap "teardown_forge_cli_sandbox '$sandbox'; rm -rf '$config'" RETURN
  gla_install_fake_glab_auth "$sandbox"

  rm -f "$sandbox/gla_mr_created.flag"

  # The store lives at $AIMI_CONFIG_DIR/forge-account-<digest>.json, so an
  # empty config dir before and after is the whole assertion.
  assert_eq "0" "$(find "$config" -name 'forge-account-*.json' | wc -l | tr -d ' ')" \
    "agent mode: no account store exists before the write (baseline, so the after-count means something)"

  local out exit_code
  out=$(env -u GITLAB_TOKEN -u GITLAB_ACCESS_TOKEN -u OAUTH_TOKEN \
    AIMI_AGENT_MODE=true AIMI_CONFIG_DIR="$config" \
    GLA_MR_CREATE_STDOUT='!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42' \
    GLA_MR_VIEW_AFTER_JSON='{"iid":42,"state":"opened","web_url":"https://gitlab.com/acme/widgets/-/merge_requests/42"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My MR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "agent mode: the write succeeded, so the no-persistence claim is about a real invocation"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "agent mode: the merge request was really created"

  assert_eq "0" "$(find "$config" -name 'forge-account-*.json' | wc -l | tr -d ' ')" \
    "agent mode: still no account store after the write -- the auto-answer was applied for this invocation and persisted nowhere"

  # Stronger than a file count: the gitlab write path does not read the store
  # either, so there is no answer for it to have recorded in the first place.
  local bodies
  bodies=$(glw_fn_body _forge_pr_create_gitlab; glw_fn_body _forge_pr_edit_gitlab; glw_fn_body _forge_issue_create_gitlab)
  assert_eq "0" "$(printf '%s\n' "$bodies" | grep -cE '_forge_account_(override|store_path|stored_entry|select)')" \
    "agent mode: no gitlab write adapter touches the account store at all -- nothing to persist, by construction"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_glw_glab_write_url_extraction() {
  echo ""
  echo "=== _forge_glab_write_url: finds the URL inside glab's framed confirmation output, empty when there is none ==="

  glw_source_write_helpers

  assert_eq "https://gitlab.com/acme/widgets/-/merge_requests/42" \
    "$(_forge_glab_write_url '!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42')" \
    "glab url: picks the URL out of glab's two-line create confirmation"

  # Deliberately NOT `tail -n1`, which is what the gh side does: gh prints the
  # bare URL and nothing else, glab frames it. A trailing line after the URL
  # would defeat the tail habit; this proves it does not defeat this one.
  assert_eq "https://gitlab.com/acme/widgets/-/merge_requests/42" \
    "$(_forge_glab_write_url '!42 My MR (feat-x)
 https://gitlab.com/acme/widgets/-/merge_requests/42
Draft: this merge request is a draft.')" \
    "glab url: a trailing line after the URL does not hide it"

  assert_eq "https://gitlab.com/acme/widgets/-/issues/7" \
    "$(_forge_glab_write_url ' https://gitlab.com/acme/widgets/-/issues/7')" \
    "glab url: an issue URL is found the same way"

  assert_eq "" "$(_forge_glab_write_url 'no url here at all')" "glab url: output with no URL yields the empty string, never a guess"
  assert_eq "" "$(_forge_glab_write_url '')" "glab url: empty output yields the empty string"
}

# ============================================================================
# Gitea WRITE-verb tests (phase 4 outline:03) — forge-pr-create /
# forge-pr-edit / forge-issue-create routed to tea
# ============================================================================
# EVERY helper introduced by this section is `gtw_`-prefixed (Gitea Write) and
# every control variable is `GTW_*`. That is an orchestration constraint, not
# a style preference: sibling stories are adding gitea READ-verb (`gtr_`) and
# review-thread (`gtt_`) helpers to THIS SAME FILE in parallel, outline:01 has
# already landed `gtm_`, and bash silently keeps the LAST definition of a
# duplicated function name. Three individually-green branches whose helper
# names collide produce a red container after the merge -- the exact failure
# that cost this programme a wave-1 merge two phases ago. Grep before naming,
# and prefix anyway.
#
# The section deliberately does NOT extend gtm_setup_fake_tea_fixture (the
# read-side stub outline:01 owns) with write subcommands, and does not touch
# any of the five fake-glab installers either: an edit inside a shared stub's
# case statement is a merge conflict waiting to happen. gtw_install_fake_tea
# below is a separate, self-contained stub. Duplication over conflict -- the
# same call phase 3 made when it accepted five near-identical fake glabs.
#
# WHAT THESE TESTS ACTUALLY PROVE, AND WHAT THEY CANNOT. tea is NOT installed
# on this machine -- this phase's declared verification ceiling, stated in
# aimi-cli.sh's own Gitea write adapters header as well -- so every assertion
# here is about WHICH ARGV aimi-cli.sh emits and HOW IT PARSES A FIXTURE,
# never about what the real binary does with either. That is the right thing
# to pin regardless: the defects this story exists to prevent are a WRONG FLAG
# NAME and a MISSING FLAG, and both are visible in argv.
#
# WHY THE FLAG COUNT IS READ OFF RECORDED ARGV AND NEVER OFF AN EXIT STATUS.
# `tea pulls create` enters an interactive survey whenever
# ctx.Command.NumFlags() == 0 (modules/context/context.go:55-59), and that
# check performs NO TTY test despite its own doc comment claiming one -- so a
# zero-flag invocation hangs even with a non-TTY stdin, in an autonomous run
# with nobody present to answer. A fake tea never prompts, so it exits 0
# whether or not a flag was passed: an exit-status assertion would pass
# vacuously and prove exactly nothing. gtw_argv_flag_count below therefore
# reads the stub's argv log, and gtw_test_flag_count_reader_can_go_red proves
# that reader can answer "no flags" before anything trusts it answering "has
# flags".

# Writes a fake `tea` into an existing setup_forge_cli_sandbox directory.
#
# THE CASE IS NESTED, AND THAT IS LOAD-BEARING RATHER THAN TIDY. glw_install_
# fake_glab dispatches on "$1 $2" because every glab invocation it models is a
# two-word subcommand. tea OVERLOADS THE `pulls` NOUN: `pulls create`,
# `pulls edit` and `pulls list` are subcommands, but `tea pulls 42 -o json` is
# a DETAIL READ whose second argument is an INDEX (cmd/pulls.go:88-93 routes
# to runPullDetail when Args().Len() == 1). A flat "$1 $2" dispatch would send
# every post-write re-read into the unhandled arm, and the re-read is exactly
# what supplies the number these tests assert on.
#
# It emits tea's TWO DISTINCT JSON SHAPES, which are genuinely different
# documents rather than two renderings of one:
#   DETAIL  one tab-indented object with TYPED values -- `index` an int,
#           `mergeable`/`hasMerged` real booleans (cmd/pulls.go:29-52).
#   LIST    an ARRAY of all-STRING, snake_cased rows, because
#           orderedRow.MarshalJSON marshals a map[string]string
#           (modules/print/table.go:187-208).
# The failure form is uniform because tea's is: main.go:18-30 prints
# `Error: %v` to stderr and exits 1 for EVERY error alike -- there is no
# distinct exit code for "not found", which is precisely why the adapter's
# not_found detection is structural.
#
# Records every invocation's argv (one line per call) to $GTW_TEA_LOG, and --
# on a SEPARATE channel, never argv -- what each child process actually saw
# for GH_TOKEN and GITEA_TOKEN to $GTW_TEA_TOKEN_LOG. Separate channels keep
# the "no token reached argv" scan honest. The token log uses ${VAR-<unset>}
# rather than ${VAR:-<unset>} on purpose: an explicitly BLANKED variable must
# stay distinguishable from an absent one, since blanking is its own defect
# here (it would revoke an operator's own GITEA_TOKEN selection).
#
# Control variables, all optional:
#   GTW_TEA_LOG                  argv log file
#   GTW_TEA_TOKEN_LOG            token-visibility log file
#   GTW_PULLS_LIST_JSON          `pulls list` stdout (default '[]')
#   GTW_PULLS_LIST_EXIT/_STDERR  make the listing fail
#   GTW_PULLS_CREATE_STDOUT      `pulls create` stdout
#   GTW_PULLS_CREATE_EXIT/_STDERR
#   GTW_PULLS_EDIT_STDOUT        `pulls edit` stdout
#   GTW_PULLS_EDIT_EXIT/_STDERR
#   GTW_PULLS_DETAIL_JSON        `pulls <index> -o json` stdout
#   GTW_PULLS_DETAIL_AFTER_JSON  same, but only once `pulls create` has run
#   GTW_ISSUES_CREATE_STDOUT     `issues create` stdout
#   GTW_ISSUES_CREATE_EXIT/_STDERR
gtw_install_fake_tea() {
  local sandbox="$1"
  cat > "$sandbox/tea" << 'GTW_FAKE_TEA'
#!/usr/bin/env bash
if [ -n "${GTW_TEA_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GTW_TEA_LOG"
fi
if [ -n "${GTW_TEA_TOKEN_LOG:-}" ]; then
  printf '%s %s|GH_TOKEN=%s|GITEA_TOKEN=%s\n' "${1:-}" "${2:-}" "${GH_TOKEN-<unset>}" "${GITEA_TOKEN-<unset>}" >> "$GTW_TEA_TOKEN_LOG"
fi

GTW_CREATED_FLAG="$(dirname "$0")/gtw_pull_created.flag"

case "$1" in
  pulls)
    case "$2" in
      create)
        : > "$GTW_CREATED_FLAG"
        if [ "${GTW_PULLS_CREATE_EXIT:-0}" != "0" ]; then
          printf 'Error: %s\n' "${GTW_PULLS_CREATE_STDERR:-something went wrong}" >&2
          exit "${GTW_PULLS_CREATE_EXIT}"
        fi
        printf '%s\n' "${GTW_PULLS_CREATE_STDOUT:-}"
        exit 0
        ;;
      edit)
        if [ "${GTW_PULLS_EDIT_EXIT:-0}" != "0" ]; then
          printf 'Error: %s\n' "${GTW_PULLS_EDIT_STDERR:-something went wrong}" >&2
          exit "${GTW_PULLS_EDIT_EXIT}"
        fi
        printf '%s\n' "${GTW_PULLS_EDIT_STDOUT:-}"
        exit 0
        ;;
      list)
        if [ "${GTW_PULLS_LIST_EXIT:-0}" != "0" ]; then
          printf 'Error: %s\n' "${GTW_PULLS_LIST_STDERR:-could not list pull requests}" >&2
          exit "${GTW_PULLS_LIST_EXIT}"
        fi
        printf '%s' "${GTW_PULLS_LIST_JSON:-[]}"
        exit 0
        ;;
      *)
        # DETAIL read: `tea pulls <index> -o json`. "$2" is an INDEX here, not
        # a subcommand -- the whole reason this case is nested.
        if [ -f "$GTW_CREATED_FLAG" ] && [ -n "${GTW_PULLS_DETAIL_AFTER_JSON:-}" ]; then
          printf '%s' "$GTW_PULLS_DETAIL_AFTER_JSON"
          exit 0
        fi
        if [ -n "${GTW_PULLS_DETAIL_JSON:-}" ]; then
          printf '%s' "$GTW_PULLS_DETAIL_JSON"
          exit 0
        fi
        printf 'Error: pull request does not exist [index: %s]\n' "${2:-}" >&2
        exit 1
        ;;
    esac
    ;;
  issues)
    case "$2" in
      create)
        if [ "${GTW_ISSUES_CREATE_EXIT:-0}" != "0" ]; then
          printf 'Error: %s\n' "${GTW_ISSUES_CREATE_STDERR:-something went wrong}" >&2
          exit "${GTW_ISSUES_CREATE_EXIT}"
        fi
        printf '%s\n' "${GTW_ISSUES_CREATE_STDOUT:-}"
        exit 0
        ;;
    esac
    ;;
esac
printf 'Error: fake-tea (write): unhandled invocation: %s\n' "$*" >&2
exit 1
GTW_FAKE_TEA
  chmod +x "$sandbox/tea"
}

# Prints the one recorded argv line whose text starts with <prefix>, so an
# assertion can pin the ENTIRE invocation -- flag names, flag order and the
# positional argument -- in a single comparison rather than three loose greps.
# A wrong spelling (`--body` for `-d`, a short `-h` for `--head`) then fails
# outright instead of being absorbed by a grep that never looked.
# Usage: gtw_argv_line <log-file> <prefix, e.g. "pulls create">
gtw_argv_line() {
  local log="$1" prefix="$2"
  grep -E "^${prefix}( |$)" "$log" 2>/dev/null | head -1 || true
}

# Counts recorded invocations whose text starts with <prefix>. Used to prove a
# call was NEVER made -- the idempotency assertion, which no output comparison
# can show.
# Usage: gtw_argv_count <log-file> <prefix>
gtw_argv_count() {
  local log="$1" prefix="$2"
  grep -cE "^${prefix}( |$)" "$log" 2>/dev/null || true
}

# Counts recorded DETAIL reads -- `pulls <index> ...`, where the second token
# is a number rather than a subcommand. Needs its own reader precisely because
# tea overloads the `pulls` noun.
gtw_argv_detail_count() {
  local log="$1"
  grep -cE '^pulls [0-9]+( |$)' "$log" 2>/dev/null || true
}

# THE READER THE ALWAYS-PASS-A-FLAG INVARIANT RESTS ON. Counts the flag tokens
# on the recorded argv line for <prefix>, reading argv and never an exit
# status -- see this section's header for why an exit-status form would pass
# vacuously against a fake that cannot prompt.
#
# The prefix (the subcommand, plus nothing else) is stripped first, so the
# `--` separator _forge_capture uses and any positional argument cannot be
# mistaken for a flag. A token counts only as `-x` or `--xyz` -- one or two
# dashes followed by a LETTER -- so a negative number, and a bare `--`, never
# inflate the count. The letter is load-bearing: `^-[A-Za-z-]` would accept
# `--` as a flag, because the trailing hyphen inside the bracket class is a
# literal one.
# Usage: gtw_argv_flag_count <log-file> <prefix>
gtw_argv_flag_count() {
  local log="$1" prefix="$2" line rest count
  line=$(gtw_argv_line "$log" "$prefix")
  if [ -z "$line" ]; then
    printf '%s' "0"
    return 0
  fi
  rest="${line#"$prefix"}"
  count=$(printf '%s' "$rest" | tr ' ' '\n' | grep -cE '^--?[A-Za-z]') || count=0
  printf '%s' "$count"
}

# Extracts one function body out of aimi-cli.sh for the static assertions
# below -- same sed technique glw_fn_body uses, kept private under this
# section's prefix so a sibling branch renaming its own copy cannot break
# this one.
# Usage: gtw_fn_body <function-name>
gtw_fn_body() {
  sed -n "/^$1()/,/^}/p" "$CLI"
}

# The Gitea write-adapter section header, which is where a reader meets the
# interactivity hazard, the flag spellings, the GH_TOKEN hazard, the declared
# ceiling and the known duplicate read path, and must find all five answered.
gtw_write_header() {
  sed -n '/^# Gitea write adapters/,/^_forge_tea_write_url()/p' "$CLI"
}

# eval's the pure Gitea write helper for direct, in-process testing.
gtw_source_write_helpers() {
  eval "$(sed -n '/^_forge_tea_write_url()/,/^}/p' "$CLI")"
}

# Counts `export`/`declare -x` of any variable tea would honour as a
# credential, in a given file.
#
# COUNTED WITH `grep -c`, AND THAT IS NOT A STYLE CHOICE. This suite runs
# under `set -o pipefail`. In the `grep -v ... | grep -q ...` shape, the right
# half exits the instant it matches, SIGPIPEs the left half, and the pipeline
# reports FAILURE -- so an `if` on it reads a real hit as "no hit" and the
# guard fails OPEN. Seven guards of that shape already exist in this suite;
# this story adds no eighth. `grep -c` consumes all of its input and cannot
# fire early, and the trailing `|| count=0` absorbs grep's exit 1 on zero
# matches rather than aborting.
#
# GH_TOKEN is in the pattern, not only GITEA_TOKEN, because that is the whole
# hazard: tea reads GH_TOKEN too (modules/context/context_login.go:15-51), so
# exporting the GitHub one leaks a GitHub credential to a Gitea instance.
# Usage: gtw_count_token_exports <file>
gtw_count_token_exports() {
  local file="$1" count
  count=$(grep -v '^[[:space:]]*#' "$file" | grep -cE '(export|declare -x)[[:space:]]+(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)') || count=0
  printf '%s' "$count"
}

# Counts `tea` invocations carrying a token PREFIX ASSIGNMENT, in the same
# counting form and for the same reason. This catches the specific mistake the
# section header warns about: copying the github arm's
# `GH_TOKEN="$gh_token_override" _forge_capture ... -- gh ...` shape onto a tea
# call. It also catches a BLANKING prefix (`GITEA_TOKEN= ... tea ...`), which
# is the opposite defect and equally forbidden -- it would revoke an
# operator's own account selection.
# Usage: gtw_count_token_prefixed_tea_calls <file>
gtw_count_token_prefixed_tea_calls() {
  local file="$1" count
  count=$(grep -v '^[[:space:]]*#' "$file" | grep -cE '(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN)=.*[[:space:]]tea[[:space:]]') || count=0
  printf '%s' "$count"
}

# Writes a copy of aimi-cli.sh to <dest> with ONE verb's `gitea)` routing arm
# renamed so it can never match, and prints "changed" or "unchanged" so the
# caller can PROVE the mutation landed. A mutation test whose patch silently
# missed is worse than no mutation test: it passes for the wrong reason.
#
# The arm is identified by its FOLLOWING line rather than by its own text,
# because all three verbs spell the arm identically (`    gitea)`) -- a plain
# full-line replacement would unroute all three at once and destroy the
# per-verb isolation the matrix exists to provide. The marker is compared for
# exact full-line equality, never as a regex, and is looked for at either of
# the next two lines so a verb that declares a local first is still reachable.
# Usage: gtw_mutate_unroute <exact-marker-line> <dest>
gtw_mutate_unroute() {
  local marker="$1" dest="$2"
  awk -v m="$marker" '
    { l[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (l[i] == "    gitea)" && (l[i+1] == m || l[i+2] == m)) {
          print "    gitea-unrouted)"
        } else {
          print l[i]
        }
      }
    }' "$CLI" > "$dest"
  chmod +x "$dest"
  if cmp -s "$CLI" "$dest"; then
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

# Writes a copy of aimi-cli.sh to <dest> with a deliberate process-wide
# `export GH_TOKEN` planted as the FIRST statement of _forge_pr_create_gitea.
# This is the teeth behind the live token probe: without it, an assertion that
# the environment is unchanged before and after a write is indistinguishable
# from an assertion that nothing was ever read.
# Usage: gtw_plant_export_in_gitea_create <dest>
gtw_plant_export_in_gitea_create() {
  local dest="$1"
  awk '
    { print }
    $0 == "_forge_pr_create_gitea() {" { print "  export GH_TOKEN=\"planted-into-the-process\"" }
  ' "$CLI" > "$dest"
  chmod +x "$dest"
  if cmp -s "$CLI" "$dest"; then
    printf 'unchanged'
  else
    printf 'changed'
  fi
}

# eval's the gitea pr-create path and its dependencies into the CURRENT shell,
# out of <source-file> (aimi-cli.sh by default, or a planted copy).
#
# Sourced rather than driven through `$CLI` for one reason, and it is the
# whole reason the before/after check below means anything: a separate `$CLI`
# process per reading makes a process-wide `export` UNDETECTABLE, because the
# export dies with the process that made it. Phase 3's US-005 shipped that
# exact tautology -- twice over, since it also ran the write inside `$( )`,
# which is its own subshell. In one shell, with the write as a plain statement
# redirected to a file, an export survives from the write into the
# after-reading and the comparison can actually fail.
# Usage: gtw_source_gitea_write_path [source-file]
gtw_source_gitea_write_path() {
  local src="${1:-$CLI}" fn
  for fn in _forge_bin_check _forge_capture _forge_build_write_data \
            _forge_emit_write_status _forge_tea_write_url _forge_pr_create_gitea; do
    eval "$(sed -n "/^${fn}()/,/^}/p" "$src")"
  done
}

# RUNS BEFORE EVERY OTHER ASSERTION IN THIS SECTION, ON PURPOSE. The
# always-pass-a-flag invariant turns on one predicate -- "how many flags did
# this invocation carry" -- so that predicate must be shown able to answer
# ZERO before a single test trusts it answering more. Without this, a
# gtw_argv_flag_count that always returned a positive number would make every
# invariant assertion below pass while the real defect (a forever-hang in
# production, on a code path with no TTY check to save it) shipped untouched.
gtw_test_flag_count_reader_can_go_red() {
  echo ""
  echo "=== gitea write: the flag-count reader CAN answer 'no flags' (falsifiability proof, runs first) ==="

  local log
  log=$(mktemp)

  # Hand-written ZERO-FLAG argv lines -- exactly the shape that makes
  # tea's NumFlags() == 0 fire and the run hang.
  {
    printf '%s\n' 'pulls create'
    printf '%s\n' 'pulls edit 303'
    printf '%s\n' 'issues create'
  } > "$log"

  assert_eq "0" "$(gtw_argv_flag_count "$log" "pulls create")"  "flag-count reader: a recorded zero-flag 'pulls create' answers 0 -- the hang shape is visible"
  assert_eq "0" "$(gtw_argv_flag_count "$log" "pulls edit")"    "flag-count reader: a recorded 'pulls edit 303' with only a positional answers 0 -- a positional is not a flag"
  assert_eq "0" "$(gtw_argv_flag_count "$log" "issues create")" "flag-count reader: a recorded zero-flag 'issues create' answers 0"

  # ...and the SAME lines with flags move the verdict, so both answers are
  # shown to be reachable rather than one of them being a constant.
  {
    printf '%s\n' 'pulls create -t My PR -d the body --head feat-x -b main'
    printf '%s\n' 'pulls edit 303 -d updated body'
    printf '%s\n' 'issues create -t Backend spec -d the body'
  } > "$log"

  assert_eq "4" "$(gtw_argv_flag_count "$log" "pulls create")"  "flag-count reader: the same 'pulls create' WITH -t/-d/--head/-b answers 4"
  assert_eq "1" "$(gtw_argv_flag_count "$log" "pulls edit")"    "flag-count reader: 'pulls edit 303 -d ...' answers 1 -- one flag is all the invariant needs"
  assert_eq "2" "$(gtw_argv_flag_count "$log" "issues create")" "flag-count reader: 'issues create -t ... -d ...' answers 2"

  # A bare `--` separator and a numeric argument are not flags. Without these
  # boundaries the reader would rubber-stamp an invocation that really did
  # reach tea with NumFlags() == 0.
  printf '%s\n' 'pulls create -- 42' > "$log"
  assert_eq "0" "$(gtw_argv_flag_count "$log" "pulls create")" "flag-count reader: a bare '--' and a number are NOT counted as flags"

  # An invocation that never happened must not read as "carried flags".
  assert_eq "0" "$(gtw_argv_flag_count "$log" "issues create")" "flag-count reader: a subcommand with no recorded invocation answers 0, never a stale count"

  rm -f "$log"
}

gtw_test_tea_write_url_extraction() {
  echo ""
  echo "=== _forge_tea_write_url: finds the URL inside tea's markdown write output, empty when there is none ==="

  gtw_source_write_helpers

  # `tea issues create` prints markdown PLUS a bare HTMLURL line
  # (modules/task/issue_create.go:28-30) -- the friendly case.
  assert_eq "https://gitea.com/acme/widgets/issues/7" \
    "$(_forge_tea_write_url '# #7 Backend spec
Body text.
https://gitea.com/acme/widgets/issues/7')" \
    "tea url: picks the URL out of issues create's markdown-plus-bare-URL output"

  # `tea pulls create` ends in print.PullDetails -- a markdown block whose URL
  # line is appended only when non-empty. Deliberately NOT tail -n1: a
  # trailing markdown line after the URL would defeat that habit.
  assert_eq "https://gitea.com/acme/widgets/pulls/42" \
    "$(_forge_tea_write_url '# #42 Add the Gitea adapter (open)
@octocat created 2026-08-06

https://gitea.com/acme/widgets/pulls/42')" \
    "tea url: picks the URL out of pulls create's markdown block"

  assert_eq "https://gitea.com/acme/widgets/pulls/42" \
    "$(_forge_tea_write_url '# #42 Add the Gitea adapter
https://gitea.com/acme/widgets/pulls/42
---')" \
    "tea url: a trailing line after the URL does not hide it"

  # THE BRANCH THAT MAKES "created but no parseable URL" REAL RATHER THAN
  # HYPOTHETICAL: print.PullDetails appends the URL line ONLY when the URL is
  # non-empty (modules/print/pull.go:76-78), and --output json is not
  # consulted on the create path at all.
  assert_eq "" "$(_forge_tea_write_url '# #42 Add the Gitea adapter (open)
@octocat created 2026-08-06')" \
    "tea url: a PullDetails block with no URL line yields the empty string -- a real degraded outcome, never a guess"
  assert_eq "" "$(_forge_tea_write_url '')" "tea url: empty output yields the empty string"
}

gtw_test_forge_pr_create_gitea_creates_pr() {
  echo ""
  echo "=== forge-pr-create (gitea): opens a PR via tea pulls create -- tea's own flag names, number from a structured DETAIL re-read ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_CREATE_STDOUT='# #42 Add the Gitea adapter (open)
@octocat created 2026-08-06

https://gitea.com/acme/widgets/pulls/42' \
    GTW_PULLS_DETAIL_AFTER_JSON='{"id":98765,"index":42,"state":"open","url":"https://gitea.com/acme/widgets/pulls/42","head":"feat-x","base":"main","mergeable":true,"hasMerged":false}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create gitea: exit 0"
  assert_eq '{"status":"created","data":{"url":"https://gitea.com/acme/widgets/pulls/42","number":42},"message":null}' \
    "$out" "forge-pr-create gitea: the SHARED write envelope, status created, number 42 from the re-read's index (not its id 98765)"

  # THE WHOLE INVOCATION PINNED IN ONE COMPARISON. A gh-shaped --body, a
  # glab-shaped -s/--source-branch, or a short -h for --head all fail here
  # outright rather than slipping past a loose grep.
  assert_eq 'pulls create -t My PR -d the body --head feat-x -b main' "$(gtw_argv_line "$log" "pulls create")" \
    "forge-pr-create gitea: exact argv -- -t/--title, -d/--description, --head in LONG FORM, -b/--base"

  # THE INVARIANT THIS SECTION EXISTS FOR. Recorded argv, never exit status.
  assert_eq "4" "$(gtw_argv_flag_count "$log" "pulls create")" \
    "forge-pr-create gitea: the recorded argv carries 4 flags -- with zero, tea's NumFlags()==0 opens an interactive survey and the run hangs forever"

  assert_eq "0" "$(grep -c -- '--body' "$log" || true)"          "forge-pr-create gitea: gh's --body never reaches tea (tea calls it -d/--description)"
  assert_eq "0" "$(grep -c -- '--source-branch' "$log" || true)" "forge-pr-create gitea: glab's --source-branch never reaches tea (tea calls it --head)"
  assert_eq "0" "$(grep -c -- '--target-branch' "$log" || true)" "forge-pr-create gitea: glab's --target-branch never reaches tea (tea calls it -b/--base)"
  assert_eq "0" "$(grep -cE -- '(^| )-h( |$)' "$log" || true)"   "forge-pr-create gitea: --head is never abbreviated to -h -- that is urfave/cli's help flag, not a branch name"
  assert_eq "0" "$(grep -cE -- '(^| )-y( |$)' "$log" || true)"   "forge-pr-create gitea: glab's -y never reaches tea -- tea has no such flag to accept"

  # The probe is a LIST plus a local filter, because tea pulls list has no
  # --head/--source-branch filter at all (cmd/pulls/list.go:31).
  assert_eq 'pulls list --state all -o json' "$(gtw_argv_line "$log" "pulls list")" \
    "forge-pr-create gitea: the idempotency probe is 'pulls list --state all -o json' -- tea offers no server-side head filter to ask instead"
  assert_eq "1" "$(gtw_argv_count "$log" "pulls list")" "forge-pr-create gitea: exactly one listing call -- the pre-create probe"
  assert_eq "1" "$(gtw_argv_detail_count "$log")"       "forge-pr-create gitea: exactly one DETAIL read -- the post-create structured re-read"
  assert_eq 'pulls 42 -o json' "$(gtw_argv_line "$log" "pulls 42")" \
    "forge-pr-create gitea: the re-read is the DETAIL form, whose index is a real int -- not the all-string LIST shape"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_existing_open_pr_is_unchanged() {
  echo ""
  echo "=== forge-pr-create (gitea): an OPEN pull request already exists for --head -- reports unchanged, never calls tea pulls create ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  # ALL-STRING, snake_cased LIST row -- `"index": "55"`, not 55. A fixture
  # that typed index as a number would let a naive implementation that
  # assumes the DETAIL shape pass unnoticed.
  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_LIST_JSON='[{"index":"55","title":"Existing","state":"open","url":"https://gitea.com/acme/widgets/pulls/55","head":"feat-x","base":"main","mergeable":"true"}]' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create gitea idempotent: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://gitea.com/acme/widgets/pulls/55","number":55},"message":null}' \
    "$out" "forge-pr-create gitea idempotent: status unchanged with the EXISTING PR under data, and number is a JSON INT 55 despite arriving as the string \"55\""

  # THE ASSERTION NO OUTPUT COMPARISON CAN MAKE: the create really was never
  # invoked, so a retried phase cannot open a second pull request.
  assert_eq "0" "$(gtw_argv_count "$log" "pulls create")" \
    "forge-pr-create gitea idempotent: tea pulls create was NEVER invoked (invocation count 0)"
  assert_eq "0" "$(gtw_argv_detail_count "$log")" \
    "forge-pr-create gitea idempotent: and no DETAIL re-read either -- the listing row already carried url and index"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_owner_prefixed_head_matches() {
  echo ""
  echo "=== forge-pr-create (gitea): a cross-fork LIST head of 'forkuser:feat-x' still matches the branch feat-x ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  # formatPRHead (modules/print/pull.go:83-93) prefixes the OWNER for a
  # cross-fork pull request, so the LIST head is not the branch name. Plain
  # equality here would miss the match and open a DUPLICATE pull request --
  # the precise failure this fixture exists to prevent.
  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_LIST_JSON='[{"index":"55","state":"open","url":"https://gitea.com/acme/widgets/pulls/55","head":"forkuser:feat-x","base":"main"}]' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-create gitea owner-prefixed head: exit 0"
  assert_eq "unchanged" "$(printf '%s' "$out" | jq -r '.status')" \
    "forge-pr-create gitea owner-prefixed head: 'forkuser:feat-x' matches the branch feat-x -- plain equality would have opened a duplicate"
  assert_eq "55" "$(printf '%s' "$out" | jq -r '.data.number')" "forge-pr-create gitea owner-prefixed head: the EXISTING pull request's number is reported"
  assert_eq "0" "$(gtw_argv_count "$log" "pulls create")" "forge-pr-create gitea owner-prefixed head: tea pulls create was never invoked"

  # ...and the suffix match is not so loose that a DIFFERENT branch ending in
  # the same text matches. `feat-x` must not be found inside `other-feat-x`.
  : > "$log"
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_LIST_JSON='[{"index":"55","state":"open","url":"https://gitea.com/acme/widgets/pulls/55","head":"forkuser:other-feat-x","base":"main"}]' \
    GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/91' \
    GTW_PULLS_DETAIL_AFTER_JSON='{"index":91,"url":"https://gitea.com/acme/widgets/pulls/91"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" \
    "forge-pr-create gitea owner-prefixed head: 'forkuser:other-feat-x' does NOT match feat-x -- the owner prefix is matched at the colon, not by substring"
  assert_eq "1" "$(gtw_argv_count "$log" "pulls create")" "forge-pr-create gitea owner-prefixed head: an unrelated branch therefore does not block creation"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_dead_pr_does_not_block() {
  echo ""
  echo "=== forge-pr-create (gitea): a CLOSED or MERGED pull request on --head does not block -- a fresh one is opened ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  # "merged" is spelled literally on the LIST path -- formatPRState
  # (modules/print/pull.go:95-100) returns it whenever pr.Merged != nil, which
  # the DETAIL path never prints. A reused branch must not be blocked forever
  # by a dead pull request.
  local log="$sandbox/tea.log" dead out exit_code
  for dead in closed merged; do
    : > "$log"
    rm -f "$sandbox/gtw_pull_created.flag"

    out=$(GTW_TEA_LOG="$log" \
      GTW_PULLS_LIST_JSON="[{\"index\":\"12\",\"state\":\"$dead\",\"url\":\"https://gitea.com/acme/widgets/pulls/12\",\"head\":\"feat-x\",\"base\":\"main\"}]" \
      GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/91' \
      GTW_PULLS_DETAIL_AFTER_JSON='{"index":91,"url":"https://gitea.com/acme/widgets/pulls/91"}' \
      PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

    assert_exit_code "0" "$exit_code" "forge-pr-create gitea $dead PR: exit 0"
    assert_eq "1" "$(gtw_argv_count "$log" "pulls create")" "forge-pr-create gitea $dead PR: tea pulls create WAS invoked -- a $dead pull request must not block a new one forever"
    assert_eq '{"status":"created","data":{"url":"https://gitea.com/acme/widgets/pulls/91","number":91},"message":null}' \
      "$out" "forge-pr-create gitea $dead PR: only the NEW pull request's identity is reported -- the dead one never leaks"
    assert_eq "4" "$(gtw_argv_flag_count "$log" "pulls create")" "forge-pr-create gitea $dead PR: the create still carried its four flags"
  done

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_missing_tea_prints_manual() {
  echo ""
  echo "=== forge-pr-create (gitea): tea absent -- MANDATORY-PRINT degrade in Gitea's own wording, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No tea written into the sandbox. This is the ONE criterion in this story
  # testable against reality rather than against a stub: tea genuinely is not
  # installed on this machine.

  local stderr_file="/tmp/gtw_pr_create_no_tea_stderr.$$"
  local out exit_code stderr_text
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "1" "$exit_code" "forge-pr-create gitea tea-absent: exits non-zero (hard-fail, same contract as the github and gitlab arms)"
  assert_eq '{"status":"degraded","data":null,"message":"tea not found -- this pull request was not created automatically."}' \
    "$out" "forge-pr-create gitea tea-absent: degraded envelope naming tea, not gh and not glab"
  assert_stderr_contains "tea not found" "$stderr_text" "forge-pr-create gitea tea-absent: _forge_bin_check's mandatory warning names tea"
  assert_stderr_contains "create it yourself" "$stderr_text" "forge-pr-create gitea tea-absent: manual instruction printed (MANDATORY-PRINT)"

  # THE NOUN STAYS "pull request". Gitea calls them pull requests, exactly
  # like GitHub -- only GitLab says merge request.
  assert_stderr_contains "gitea pull request" "$stderr_text" "forge-pr-create gitea tea-absent: the noun is pull request, NOT merge request"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'merge request' || true)" \
    "forge-pr-create gitea tea-absent: the word 'merge request' never appears -- that is GitLab's noun, not Gitea's"

  # tea's own command, with tea's own flag spellings.
  assert_stderr_contains "tea pulls create" "$stderr_text" "forge-pr-create gitea tea-absent: the printed manual command is tea pulls create"
  assert_stderr_contains "--head feat-x" "$stderr_text" "forge-pr-create gitea tea-absent: the printed command uses --head in its LONG FORM"
  assert_stderr_contains "-b main" "$stderr_text" "forge-pr-create gitea tea-absent: the printed command uses -b/--base"
  assert_stderr_contains "-d ..." "$stderr_text" "forge-pr-create gitea tea-absent: the printed command uses -d/--description"
  assert_stderr_contains "git push -u origin feat-x" "$stderr_text" "forge-pr-create gitea tea-absent: the git push command is printed too"

  # Gitea's compare path, with no GitHub ?expand=1 query parameter.
  assert_stderr_contains "https://gitea.com/acme/widgets/compare/main...feat-x" "$stderr_text" \
    "forge-pr-create gitea tea-absent: stderr prints Gitea's compare URL the user can open by hand"

  # These negatives fail against the pre-change code, which fell through to
  # the github arm's wording -- verified by running this test against a copy
  # of aimi-cli.sh at the previous commit.
  #
  # ONE EXCEPTION, STATED SO IT IS NOT MISREAD AS EVIDENCE: the github.com
  # negative directly below is NOT load-bearing here. This fixture's remote is
  # gitea.com, so _forge_repo_info resolves that host and github.com would not
  # have appeared even before this story -- it is a cheap regression pin, not
  # a demonstration. The host DEFAULT is the half that was actually wrong, and
  # gtw_test_manual_fallback_gitea_host_default is where that negative has
  # teeth: it stubs an unresolvable host and goes red against the old code.
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'github.com' || true)"   "forge-pr-create gitea tea-absent: github.com never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'gh pr create' || true)" "forge-pr-create gitea tea-absent: 'gh pr create' never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c -- '--body' || true)"    "forge-pr-create gitea tea-absent: gh's --body never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'expand=1' || true)"     "forge-pr-create gitea tea-absent: GitHub's ?expand=1 compare parameter never appears"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_create_failure_degrades() {
  echo ""
  echo "=== forge-pr-create (gitea): tea pulls create itself fails -- degraded envelope, manual instruction, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  local stderr_file="/tmp/gtw_pr_create_fail_stderr.$$"
  local out exit_code
  out=$(GTW_TEA_LOG="$log" GTW_PULLS_CREATE_EXIT=1 \
    GTW_PULLS_CREATE_STDERR="pull request already exists [index: 42]" \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create gitea create-failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create gitea create-failure: degraded envelope"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-pr-create gitea create-failure: data is null on degraded"
  assert_contains "tea pulls create exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-create gitea create-failure: message names the tea exit code"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create gitea create-failure: manual instruction printed"

  # Even the FAILING call carried its flags: this branch is a genuine tea
  # failure, never a prompt the run silently sat on.
  assert_eq "4" "$(gtw_argv_flag_count "$log" "pulls create")" "forge-pr-create gitea create-failure: the failing invocation still carried four flags"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_unparseable_url_degrades() {
  echo ""
  echo "=== forge-pr-create (gitea): create succeeded but PullDetails printed no URL line -- degraded, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  # A REAL branch, not a hypothetical: print.PullDetails appends the URL only
  # when it is non-empty (modules/print/pull.go:76-78), and `--output json` is
  # not consulted on the create path at all (modules/task/pull_create.go:89).
  local stderr_file="/tmp/gtw_pr_create_nourl_stderr.$$"
  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_CREATE_STDOUT='# #42 Add the Gitea adapter (open)
@octocat created 2026-08-06' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-create gitea no-URL: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-create gitea no-URL: degraded envelope"
  assert_contains "did not contain a parseable pull request URL" "$(printf '%s' "$out" | jq -r '.message')" \
    "forge-pr-create gitea no-URL: message says the URL could not be parsed, not that the create failed"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-pr-create gitea no-URL: manual instruction printed"
  assert_eq "0" "$(gtw_argv_detail_count "$log")" "forge-pr-create gitea no-URL: no DETAIL re-read is attempted -- there is no index to address it with"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_create_gitea_reread_failure_keeps_created_url() {
  echo ""
  echo "=== forge-pr-create (gitea): the PR was created but the re-read cannot confirm its number -- keeps the url, status created, exit 0 ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  # GTW_PULLS_DETAIL_AFTER_JSON deliberately unset, so the post-create re-read
  # falls to the stub's `Error: ...` + exit 1 arm.
  local stderr_file="/tmp/gtw_pr_create_reread_stderr.$$"
  local out exit_code stderr_text
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_CREATE_STDOUT='# #42 Add the Gitea adapter (open)

https://gitea.com/acme/widgets/pulls/42' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "0" "$exit_code" "forge-pr-create gitea re-read failure: exit 0 -- the pull request really was created"
  assert_eq '{"status":"created","data":{"url":"https://gitea.com/acme/widgets/pulls/42","number":null},"message":null}' \
    "$out" "forge-pr-create gitea re-read failure: the url survives under data with number:null, status stays created -- never degraded, which would null data and throw the url away"
  assert_stderr_contains "Warning:" "$stderr_text" "forge-pr-create gitea re-read failure: warns rather than erroring"
  assert_stderr_contains "https://gitea.com/acme/widgets/pulls/42" "$stderr_text" "forge-pr-create gitea re-read failure: the Warning names the created PR's url"
  assert_eq "1" "$(gtw_argv_detail_count "$log")" "forge-pr-create gitea re-read failure: the re-read WAS attempted -- the URL supplied its address"
  if printf '%s' "$stderr_text" | grep -qE "create it yourself|git push -u origin"; then
    echo -e "${RED}✗${NC} forge-pr-create gitea re-read failure: the create-it-yourself fallback was printed for a PR that already exists -- following it would open a duplicate"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-pr-create gitea re-read failure: the create-it-yourself fallback is never printed once a url is in hand"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_edit_gitea_updates() {
  echo ""
  echo "=== forge-pr-edit (gitea): updates a PR via tea pulls edit -- positional index, -d not --body, status unchanged ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_PULLS_EDIT_STDOUT='# #303 Add the Gitea adapter (open)' \
    GTW_PULLS_DETAIL_JSON='{"id":11111,"index":303,"state":"open","url":"https://gitea.com/acme/widgets/pulls/303","head":"feat-x","base":"main"}' \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-pr-edit gitea: exit 0"
  assert_eq '{"status":"unchanged","data":{"url":"https://gitea.com/acme/widgets/pulls/303","number":303},"message":null}' \
    "$out" "forge-pr-edit gitea: status unchanged (the identifier already existed) with {url, number} from the structured DETAIL re-read"

  # The pull request is a POSITIONAL argument, like glab mr update and unlike
  # gh pr edit's flag-shaped body, and the body flag is -d.
  assert_eq 'pulls edit 303 -d updated body' "$(gtw_argv_line "$log" "pulls edit")" \
    "forge-pr-edit gitea: exact argv -- positional index, then -d/--description"
  assert_eq "1" "$(gtw_argv_flag_count "$log" "pulls edit")" \
    "forge-pr-edit gitea: the recorded argv carries at least one flag -- a zero-flag tea write can enter an interactive survey"
  assert_eq "0" "$(grep -c -- '--body' "$log" || true)" "forge-pr-edit gitea: gh's --body never reaches tea"
  assert_eq 'pulls 303 -o json' "$(gtw_argv_line "$log" "pulls 303")" \
    "forge-pr-edit gitea: the re-read is the DETAIL form addressed by index -- the nested stub case is what keeps this from falling into the unhandled arm"
  assert_eq "1" "$(gtw_argv_detail_count "$log")" "forge-pr-edit gitea: exactly one DETAIL re-read"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_edit_gitea_missing_tea_prints_manual() {
  echo ""
  echo "=== forge-pr-edit (gitea): tea absent -- MANDATORY-PRINT degrade naming Gitea's /pulls/ path, exit non-zero ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No tea in the sandbox.

  local stderr_file="/tmp/gtw_pr_edit_no_tea_stderr.$$"
  local out exit_code stderr_text
  out=$(PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?
  stderr_text=$(cat "$stderr_file")
  rm -f "$stderr_file"

  assert_exit_code "1" "$exit_code" "forge-pr-edit gitea tea-absent: exits non-zero"
  assert_eq '{"status":"degraded","data":null,"message":"tea not found -- this pull request was not edited automatically."}' \
    "$out" "forge-pr-edit gitea tea-absent: degraded envelope naming tea"
  assert_stderr_contains "edit it yourself" "$stderr_text" "forge-pr-edit gitea tea-absent: manual instruction printed"
  assert_stderr_contains "tea pulls edit 303 -d" "$stderr_text" "forge-pr-edit gitea tea-absent: the printed manual command is tea pulls edit with -d"

  # GITEA'S PULL-REQUEST PATH IS /pulls/<number>, WITH AN "s". GitHub's
  # singular /pull/<number> 404s on a Gitea instance.
  assert_stderr_contains "https://gitea.com/acme/widgets/pulls/303" "$stderr_text" \
    "forge-pr-edit gitea tea-absent: stderr prints Gitea's own /pulls/<number> URL"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c '/pull/' || true)" \
    "forge-pr-edit gitea tea-absent: GitHub's singular /pull/<number> never appears -- it 404s on Gitea"
  # Same exception as on the create arm above: this fixture resolves a
  # gitea.com host, so the github.com negative is a regression pin rather than
  # a demonstration -- gtw_test_manual_fallback_gitea_host_default is where it
  # goes red against the old code.
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'github.com' || true)"  "forge-pr-edit gitea tea-absent: github.com never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'gh pr edit' || true)"  "forge-pr-edit gitea tea-absent: 'gh pr edit' never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c -- '--body' || true)"   "forge-pr-edit gitea tea-absent: gh's --body never appears"
  assert_eq "0" "$(printf '%s' "$stderr_text" | grep -c 'merge request' || true)" "forge-pr-edit gitea tea-absent: the noun is pull request, never merge request"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_pr_edit_gitea_failure_degrades() {
  echo ""
  echo "=== forge-pr-edit (gitea): tea pulls edit fails, and a failed re-read after a successful edit also degrades ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"
  rm -f "$sandbox/gtw_pull_created.flag"

  local stderr_file="/tmp/gtw_pr_edit_fail_stderr.$$"
  local out exit_code
  out=$(GTW_TEA_LOG="$log" GTW_PULLS_EDIT_EXIT=1 GTW_PULLS_EDIT_STDERR="pull request does not exist [index: 303]" \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit gitea edit-failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit gitea edit-failure: degraded envelope"
  assert_contains "tea pulls edit exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-edit gitea edit-failure: message names the tea exit code"
  assert_stderr_contains "edit it yourself" "$(cat "$stderr_file")" "forge-pr-edit gitea edit-failure: manual instruction printed"
  assert_eq "1" "$(gtw_argv_flag_count "$log" "pulls edit")" "forge-pr-edit gitea edit-failure: the failing invocation still carried its flag"

  # The other failure shape: the edit succeeded but the structured re-read
  # could not confirm the pull request. Unlike pr-create, no new identifier
  # was minted here, so there is no url to protect -- this branch degrades.
  : > "$log"
  out=$(GTW_TEA_LOG="$log" GTW_PULLS_EDIT_STDOUT='# #303 edited' \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-pr-edit gitea re-read failure: exits non-zero"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-pr-edit gitea re-read failure: degraded envelope"
  assert_contains "could not be re-read afterward" "$(printf '%s' "$out" | jq -r '.message')" "forge-pr-edit gitea re-read failure: message says the re-read failed, not that the edit did"
  assert_eq "1" "$(gtw_argv_count "$log" "pulls edit")" "forge-pr-edit gitea re-read failure: the edit itself really was attempted"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_issue_create_gitea_creates_issue() {
  echo ""
  echo "=== forge-issue-create (gitea): tea issues create -t/-d, number from the bare HTMLURL line ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"

  # task.CreateIssue prints markdown PLUS a bare issue.HTMLURL line
  # (modules/task/issue_create.go:28-30) -- friendlier than the pull path.
  local out exit_code
  out=$(GTW_TEA_LOG="$log" \
    GTW_ISSUES_CREATE_STDOUT='# #7 Backend spec (open)
@octocat created 2026-08-06
https://gitea.com/acme/widgets/issues/7' \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create gitea: exit 0"
  assert_eq '{"status":"created","data":{"url":"https://gitea.com/acme/widgets/issues/7","number":7},"message":null}' \
    "$out" "forge-issue-create gitea: the SHARED write envelope, status created, number parsed from the issue URL"

  assert_eq 'issues create -t Backend spec -d the body' "$(gtw_argv_line "$log" "issues create")" \
    "forge-issue-create gitea: exact argv -- -t/--title, -d/--description"
  assert_eq "2" "$(gtw_argv_flag_count "$log" "issues create")" \
    "forge-issue-create gitea: the recorded argv carries at least one flag"
  assert_eq "0" "$(grep -c -- '--body' "$log" || true)" "forge-issue-create gitea: gh's --body never reaches tea"
  assert_eq "0" "$(grep -cE -- '(^| )-y( |$)' "$log" || true)" "forge-issue-create gitea: glab's -y never reaches tea"

  popd >/dev/null
  teardown_detect_forge_fixture
}

gtw_test_forge_issue_create_gitea_always_exits_zero() {
  echo ""
  echo "=== forge-issue-create (gitea): the always-exit-0 soft-fail contract survives on the gitea branch ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log"
  : > "$log"

  # SOFT-FAIL, all three ways it can be reached. A failed issue must NEVER
  # block PR creation, so the gitea branch may not acquire a different
  # exit-code contract from the github and gitlab ones.
  local fail_out fail_rc nourl_out nourl_rc absent_out absent_rc
  fail_out=$(GTW_TEA_LOG="$log" GTW_ISSUES_CREATE_EXIT=1 GTW_ISSUES_CREATE_STDERR="issues are disabled for this repository" \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && fail_rc=0 || fail_rc=$?
  assert_exit_code "0" "$fail_rc" "forge-issue-create gitea tea-failure: EXITS 0 (soft-fail preserved -- a failed issue never blocks a PR)"
  assert_eq "degraded" "$(printf '%s' "$fail_out" | jq -r '.status')" "forge-issue-create gitea tea-failure: the outcome is reported in status, not in the exit code"
  assert_contains "tea issues create exited 1" "$(printf '%s' "$fail_out" | jq -r '.message')" "forge-issue-create gitea tea-failure: message names the tea exit code"

  : > "$log"
  nourl_out=$(GTW_TEA_LOG="$log" GTW_ISSUES_CREATE_STDOUT='# #7 Backend spec (open)' \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && nourl_rc=0 || nourl_rc=$?
  assert_exit_code "0" "$nourl_rc" "forge-issue-create gitea no-URL: EXITS 0 (soft-fail preserved)"
  assert_eq "degraded" "$(printf '%s' "$nourl_out" | jq -r '.status')" "forge-issue-create gitea no-URL: degraded in the envelope"
  assert_contains "did not contain a parseable issue URL" "$(printf '%s' "$nourl_out" | jq -r '.message')" "forge-issue-create gitea no-URL: message says the URL could not be parsed"

  rm -f "$sandbox/tea"
  absent_out=$(PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && absent_rc=0 || absent_rc=$?
  assert_exit_code "0" "$absent_rc" "forge-issue-create gitea tea-absent: EXITS 0 (soft-fail preserved)"
  assert_eq '{"status":"degraded","data":null,"message":"tea not found -- this issue was not created automatically."}' \
    "$absent_out" "forge-issue-create gitea tea-absent: degraded envelope naming tea, not gh and not glab"

  popd >/dev/null
  teardown_detect_forge_fixture
}

# The per-forge HOST DEFAULT in isolation. The end-to-end tests above always
# have a resolvable host (the fixture's own gitea.com remote), so the default
# branch they cannot reach is the one that was actually WRONG before this
# story: a Gitea repository whose host could not be resolved was told
# github.com.
#
# _forge_pr_write_print_manual is sourced and its _forge_repo_info dependency
# stubbed INSIDE A SUBSHELL, so neither definition leaks into any later test
# in this part; the assertions then read the captured stderr in the parent.
gtw_test_manual_fallback_gitea_host_default() {
  echo ""
  echo "=== manual fallback (gitea): an unresolvable host defaults to gitea.com, never github.com ==="

  local create_file edit_file github_file
  create_file=$(mktemp)
  edit_file=$(mktemp)
  github_file=$(mktemp)

  # host is JSON null -- exactly what _forge_repo_info emits when _detect_forge
  # could not resolve one -- while owner/repo ARE resolvable, which is what
  # makes the URL line print at all.
  (
    eval "$(sed -n '/^_forge_pr_write_print_manual()/,/^}/p' "$CLI")"
    _forge_repo_info() {
      printf '%s' '{"status":"found","data":{"forge":"gitea","host":null,"owner":"acme","repo":"widgets","nameWithOwner":"acme/widgets","source":"local-parse"},"message":null,"reason":null}'
    }
    _forge_pr_write_print_manual create gitea main feat-x "the body" "My PR"
  ) 2> "$create_file"

  (
    eval "$(sed -n '/^_forge_pr_write_print_manual()/,/^}/p' "$CLI")"
    _forge_repo_info() {
      printf '%s' '{"status":"found","data":{"forge":"gitea","host":null,"owner":"acme","repo":"widgets","nameWithOwner":"acme/widgets","source":"local-parse"},"message":null,"reason":null}'
    }
    _forge_pr_write_print_manual edit gitea "" 303 "the body"
  ) 2> "$edit_file"

  # The control: the SAME unresolvable host on a github repository still
  # defaults to github.com, so this is a per-forge default rather than a
  # global rename.
  (
    eval "$(sed -n '/^_forge_pr_write_print_manual()/,/^}/p' "$CLI")"
    _forge_repo_info() {
      printf '%s' '{"status":"found","data":{"forge":"github","host":null,"owner":"acme","repo":"widgets","nameWithOwner":"acme/widgets","source":"local-parse"},"message":null,"reason":null}'
    }
    _forge_pr_write_print_manual create github main feat-x "the body" "My PR"
  ) 2> "$github_file"

  local create_text edit_text github_text
  create_text=$(cat "$create_file")
  edit_text=$(cat "$edit_file")
  github_text=$(cat "$github_file")
  rm -f "$create_file" "$edit_file" "$github_file"

  assert_contains "https://gitea.com/acme/widgets/compare/main...feat-x" "$create_text" \
    "manual fallback gitea host default: an unresolvable host yields gitea.com, and Gitea's compare path"
  assert_eq "0" "$(printf '%s' "$create_text" | grep -c 'github.com' || true)" \
    "manual fallback gitea host default: github.com never appears on the create arm -- this is the live wrong-output bug this story fixes"
  assert_contains "https://gitea.com/acme/widgets/pulls/303" "$edit_text" \
    "manual fallback gitea host default: the edit arm yields gitea.com and Gitea's /pulls/ path"
  assert_eq "0" "$(printf '%s' "$edit_text" | grep -c 'github.com' || true)" \
    "manual fallback gitea host default: github.com never appears on the edit arm either"
  assert_eq "0" "$(printf '%s' "$edit_text" | grep -c '/pull/' || true)" \
    "manual fallback gitea host default: GitHub's singular /pull/ never appears"

  assert_contains "https://github.com/acme/widgets/compare/main...feat-x" "$github_text" \
    "manual fallback host default control: a github repository with an unresolvable host still defaults to github.com -- the default is per forge, not renamed"
  assert_contains "gh pr create" "$github_text" \
    "manual fallback host default control: and the github arm still prints gh's own command, unchanged by this story"
}

# The two token guards, in COUNTING form, plus the proof that each can go red.
gtw_test_gitea_write_token_source_guards() {
  echo ""
  echo "=== gitea writes: no tea invocation carries or blanks a token, counted so neither guard can fail open ==="

  assert_eq "0" "$(gtw_count_token_exports "$CLI")" \
    "gitea token guard: aimi-cli.sh exports no GH_TOKEN, GH_ENTERPRISE_TOKEN, GITEA_TOKEN or GITEA_INSTANCE_URL anywhere"
  assert_eq "0" "$(gtw_count_token_prefixed_tea_calls "$CLI")" \
    "gitea token guard: not one tea invocation carries a token PREFIX ASSIGNMENT -- tea honours GH_TOKEN, so the github arm's shape would hand a GitHub credential to a Gitea instance"

  # Nothing inside the three gitea write adapters touches a token variable in
  # ANY form -- neither forwarding nor blanking. Comment lines are dropped
  # first, because this section's own comments name GH_TOKEN on purpose.
  local bodies token_lines
  bodies=$(gtw_fn_body _forge_pr_create_gitea; gtw_fn_body _forge_pr_edit_gitea; gtw_fn_body _forge_issue_create_gitea)
  token_lines=$(printf '%s\n' "$bodies" | grep -v '^[[:space:]]*#' | grep -cE '(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN)') || token_lines=0
  assert_eq "0" "$token_lines" \
    "gitea token guard: no executable line in the three gitea write adapters mentions a token variable at all -- neither forwarded nor blanked"
  assert_eq "0" "$(printf '%s\n' "$bodies" | grep -cE '_forge_account_(override|override_slots|store_path|stored_entry|select)')" \
    "gitea token guard: and none of them reads the account store, whose empty slot defaults to the AMBIENT GH_TOKEN"

  # FALSIFIABILITY, BOTH GUARDS. A guard asserting "zero" against a file that
  # has zero is indistinguishable from a guard that always prints zero, so
  # each counter is shown to move on a copy with a deliberately planted
  # violation -- at the TOP of the copy, which is the experiment rather than a
  # detail: the discarded `grep -v | grep -q` shape must exit while the left
  # half still has thousands of lines to write, or there is nothing to
  # SIGPIPE and the demonstration would be timing-dependent.
  local early_export early_prefix
  early_export=$(mktemp)
  printf '%s\n' 'export GH_TOKEN="$gh_token_override"' > "$early_export"
  cat "$CLI" >> "$early_export"
  assert_eq "1" "$(gtw_count_token_exports "$early_export")" \
    'gitea token guard proof: a planted "export GH_TOKEN" on line 1 is COUNTED -- the guard can go red'

  early_prefix=$(mktemp)
  printf '%s\n' '  GH_TOKEN="$gh_token_override" _forge_capture stdout stderr_out rc -- tea pulls create -t "$title"' > "$early_prefix"
  cat "$CLI" >> "$early_prefix"
  assert_eq "1" "$(gtw_count_token_prefixed_tea_calls "$early_prefix")" \
    "gitea token guard proof: a planted GH_TOKEN= prefix on a tea call is COUNTED -- the guard can go red"

  # A BLANKING prefix is the opposite defect and equally forbidden: it would
  # revoke an operator's own GITEA_TOKEN selection, exactly as phase 2's bare
  # TOKEN="" prefix did on the gh side.
  local early_blank
  early_blank=$(mktemp)
  printf '%s\n' '  GITEA_TOKEN= _forge_capture stdout stderr_out rc -- tea pulls create -t "$title"' > "$early_blank"
  cat "$CLI" >> "$early_blank"
  assert_eq "1" "$(gtw_count_token_prefixed_tea_calls "$early_blank")" \
    "gitea token guard proof: a BLANKING GITEA_TOKEN= prefix is counted too -- revoking the operator's selection is its own defect"

  # And why `grep -c` rather than `grep -v | grep -q`, demonstrated rather
  # than asserted: under pipefail the -q form reads a real hit as "no hit".
  local short_circuit_verdict="absent"
  if (set -o pipefail; grep -v '^[[:space:]]*#' "$early_export" | grep -qE '(export|declare -x)[[:space:]]+GH_TOKEN') >/dev/null 2>&1; then
    short_circuit_verdict="present"
  fi
  assert_eq "absent" "$short_circuit_verdict" \
    'gitea token guard proof: the discarded "grep -v | grep -q" shape reports ABSENT on that same file -- fail-open, which is why both guards count instead'

  # A comment mentioning the forbidden form is not a violation of it. The
  # section header this story wrote names GH_TOKEN several times, on purpose.
  local commented
  commented=$(mktemp)
  cp "$CLI" "$commented"
  printf '%s\n' '#   export GH_TOKEN="..."   <- never do this on a tea call' >> "$commented"
  printf '%s\n' '#   GH_TOKEN="$x" _forge_capture a b c -- tea pulls create   <- nor this' >> "$commented"
  assert_eq "0" "$(gtw_count_token_exports "$commented")" \
    "gitea token guard: a commented-out export is not counted, so the section header can name the forbidden form in prose"
  assert_eq "0" "$(gtw_count_token_prefixed_tea_calls "$commented")" \
    "gitea token guard: a commented-out prefix assignment is not counted either"

  rm -f "$early_export" "$early_prefix" "$early_blank" "$commented"
}

# The LIVE token probe. Phase 3's US-005 shipped this assertion tautological
# in BOTH of the two ways it can be: it read the state through a separate
# forge-auth-status PROCESS, and it ran the write inside `$( )`. An `export`
# dies with the process or the subshell that made it, so nothing could ever be
# observed. Here the write is a PLAIN STATEMENT REDIRECTED TO A FILE, in the
# same shell that reads the environment before and after -- and the last
# assertion PROVES that shape has teeth by planting the very thing it looks
# for.
gtw_test_gitea_write_live_token_probe() {
  echo ""
  echo "=== gitea writes: no token is exported into the process, proven in the SAME shell the write ran in ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local log="$sandbox/tea.log" toklog="$sandbox/tea-token.log" writeout
  : > "$log"
  : > "$toklog"
  rm -f "$sandbox/gtw_pull_created.flag"
  writeout=$(mktemp)

  local probe before_gh before_gitea status after_gh after_gitea
  probe=$(
    unset GH_TOKEN GH_ENTERPRISE_TOKEN GITEA_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export PATH="$sandbox:$PATH"
    export GTW_TEA_LOG="$log" GTW_TEA_TOKEN_LOG="$toklog"
    export GTW_PULLS_CREATE_STDOUT='# #42 Add the Gitea adapter (open)

https://gitea.com/acme/widgets/pulls/42'
    export GTW_PULLS_DETAIL_AFTER_JSON='{"index":42,"url":"https://gitea.com/acme/widgets/pulls/42"}'
    gtw_source_gitea_write_path

    local b_gh b_gt a_gh a_gt s
    b_gh="${GH_TOKEN-<unset>}"
    b_gt="${GITEA_TOKEN-<unset>}"
    # PLAIN STATEMENT, REDIRECTED TO A FILE -- never s=$(...). A command
    # substitution is its own subshell, so an export the function made inside
    # it would die there and the after-reading would be clean no matter what.
    _forge_pr_create_gitea "My PR" main feat-x "the body" > "$writeout" 2>/dev/null || true
    s=$(jq -r '.status' < "$writeout" 2>/dev/null) || s="<unparseable>"
    a_gh="${GH_TOKEN-<unset>}"
    a_gt="${GITEA_TOKEN-<unset>}"
    printf '%s\t%s\t%s\t%s\t%s' "$b_gh" "$b_gt" "$s" "$a_gh" "$a_gt"
  )
  before_gh=$(printf '%s' "$probe" | cut -f1)
  before_gitea=$(printf '%s' "$probe" | cut -f2)
  status=$(printf '%s' "$probe" | cut -f3)
  after_gh=$(printf '%s' "$probe" | cut -f4)
  after_gitea=$(printf '%s' "$probe" | cut -f5)

  assert_eq "created" "$status" "live token probe: the write really happened, so the after-readings are not vacuous"
  assert_eq "<unset>" "$before_gh"    "live token probe: GH_TOKEN is unset before the write (baseline)"
  assert_eq "<unset>" "$before_gitea" "live token probe: GITEA_TOKEN is unset before the write (baseline)"
  assert_eq "<unset>" "$after_gh" \
    "live token probe: GH_TOKEN is STILL unset after the write, read in the SAME shell the write ran in -- an export would have been visible here"
  assert_eq "<unset>" "$after_gitea" "live token probe: GITEA_TOKEN is still unset after the write"

  # The child's own view, on its own channel: tea itself was handed nothing.
  assert_eq "3" "$(grep -c 'GH_TOKEN=<unset>|GITEA_TOKEN=<unset>' "$toklog")" \
    "live token probe: all three tea calls -- the listing, the create and the re-read -- ran with NO token supplied by this CLI"
  assert_eq "0" "$(grep -cvE 'GH_TOKEN=<unset>\|GITEA_TOKEN=<unset>' "$toklog")" \
    "live token probe: not one tea call received a token from this CLI"
  assert_eq "0" "$(grep -cE 'GH_TOKEN|GITEA_TOKEN|gh[po]_' "$log")" \
    "live token probe: no token and no token variable appears in any recorded tea argv line"

  # THE TEETH. The identical probe against a copy of aimi-cli.sh with a
  # deliberate process-wide export planted inside _forge_pr_create_gitea DOES
  # move the after-reading. Without this, an assertion that the environment is
  # unchanged is indistinguishable from an assertion that nothing was read.
  local planted planted_after
  planted=$(mktemp)
  assert_eq "changed" "$(gtw_plant_export_in_gitea_create "$planted")" \
    "live token probe: the planted-export patch landed (guards against a vacuous teeth check)"

  planted_after=$(
    unset GH_TOKEN GH_ENTERPRISE_TOKEN GITEA_TOKEN AIMI_FORGE_IDENTITY AIMI_FORGE_TYPE
    export PATH="$sandbox:$PATH"
    export GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/42'
    export GTW_PULLS_DETAIL_AFTER_JSON='{"index":42,"url":"https://gitea.com/acme/widgets/pulls/42"}'
    gtw_source_gitea_write_path "$planted"
    _forge_pr_create_gitea "My PR" main feat-x "the body" > /dev/null 2>&1 || true
    printf '%s' "${GH_TOKEN-<unset>}"
  )
  assert_eq "planted-into-the-process" "$planted_after" \
    "live token probe: with an export planted in the gitea write path this probe GOES RED -- the assertion above is a real observation, not a tautology"

  # And the other half of the degradation: an operator-exported GITEA_TOKEN
  # reaches tea untouched, on EVERY call, never blanked. Driven through the
  # real CLI, because what is being observed is the CHILD's environment.
  : > "$log"
  : > "$toklog"
  rm -f "$sandbox/gtw_pull_created.flag"
  local inherited_out inherited_rc
  inherited_out=$(env GITEA_TOKEN=operator-selected-token \
    GTW_TEA_LOG="$log" GTW_TEA_TOKEN_LOG="$toklog" \
    GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/42' \
    GTW_PULLS_DETAIL_AFTER_JSON='{"index":42,"url":"https://gitea.com/acme/widgets/pulls/42"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && inherited_rc=0 || inherited_rc=$?
  assert_exit_code "0" "$inherited_rc" "inherited token: forge-pr-create still succeeds"
  assert_eq "created" "$(printf '%s' "$inherited_out" | jq -r '.status')" "inherited token: the write really happened"
  assert_eq "3" "$(grep -c 'GITEA_TOKEN=operator-selected-token' "$toklog")" \
    "inherited token: all three tea calls received the operator's exported GITEA_TOKEN untouched -- never blanked, and never on only some of them"
  assert_eq "0" "$(grep -c 'GITEA_TOKEN=<unset>' "$toklog")" \
    "inherited token: not one tea call had the inherited token stripped from its environment"
  assert_eq "3" "$(grep -c 'GH_TOKEN=<unset>' "$toklog")" \
    "inherited token: and GH_TOKEN stayed unset throughout -- a Gitea instance is never handed a GitHub credential"

  rm -f "$writeout" "$planted"
  popd >/dev/null
  teardown_detect_forge_fixture
}

# The Gitea write-adapter section header is where a reader meets every hazard
# this story had to resolve, so each answer has to be THERE and has to be
# concrete. A hazard rediscovered from the code alone costs a debugging
# session; the interactivity one costs a hung autonomous run.
gtw_test_gitea_write_header_states_its_invariants() {
  echo ""
  echo "=== gitea write header: states the flag invariant, the flag spellings, the GH_TOKEN hazard, the ceiling and the known duplicate read path ==="

  local header
  header=$(gtw_write_header)

  assert_contains "EVERY tea WRITE INVOCATION CARRIES AT LEAST ONE FLAG" "$header" \
    "header: the always-pass-a-flag invariant is stated, in the section header, before any code"
  assert_contains "NumFlags() == 0" "$header" "header: names the exact condition that triggers tea's interactive survey"
  assert_contains "THE DOC COMMENT CLAIMS A TTY CHECK; THE IMPLEMENTATION PERFORMS NONE" "$header" \
    "header: records that tea's own doc comment is wrong about the TTY check, which is why non-TTY stdin does not save the run"
  assert_contains "do not go looking for a -y here" "$header" \
    "header: says outright that tea has no -y, so a reader does not add one by analogy with glab"

  assert_contains "NOT gh's --body" "$header"    "header: names the -d/--description spelling against gh's --body"
  assert_contains "LONG FORM ONLY" "$header"     "header: records that --head has no short alias"
  assert_contains "urfave/cli's help flag" "$header" "header: and why -h could not be one"

  assert_contains "GH_TOKEN HAZARD" "$header"    "header: the GH_TOKEN hazard is named as a hazard, not a style rule"
  assert_contains "context_login.go" "$header"   "header: cites the tea source that reads GH_TOKEN"
  assert_contains "Blanking is refused" "$header" "header: states the opposite refusal too -- blanking would revoke the operator's own selection"

  assert_contains "VERIFICATION CEILING" "$header" "header: the declared ceiling is stated in the code, in the same shape phase 3's glab header carries its own"
  assert_contains "tea is NOT" "$header"           "header: says plainly that tea is not installed"
  assert_contains "2026-08-06" "$header"           "header: dates the source reading"

  assert_contains "KNOWN, DELIBERATE DUPLICATE READ PATH" "$header" \
    "header: the second Gitea PR read path is recorded by name as a known, deliberate debt rather than left to be mistaken for an accident"
  assert_contains "_forge_pr_view_gitea" "$header" "header: names the function this probe deliberately does not call, and why"

  # The two LIST-vs-DETAIL traps a naive implementation gets wrong.
  assert_contains "EVERY LIST VALUE IS A JSON STRING" "$header" "header: records that LIST values are strings, so index arrives as \"42\""
  assert_contains "owner:" "$header" "header: records the cross-fork owner: prefix on the LIST head"
  assert_contains "ONLY AN OPEN PULL REQUEST BLOCKS CREATION" "$header" "header: records that a merged or closed pull request must not block a reused branch forever"

  # The source-level half of the flag invariant: EVERY tea write in the file,
  # including one a future edit adds without a test of its own.
  local write_lines total=0 flagless=0 line rest flags
  write_lines=$(grep -nE '_forge_capture .* -- tea (pulls create|pulls edit|issues create)' "$CLI" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    rest=$(printf '%s' "$line" | sed 's/.* -- tea [a-z]* [a-z]*//')
    flags=$(printf '%s' "$rest" | tr ' ' '\n' | grep -cE '^--?[A-Za-z]') || flags=0
    if [ "$flags" -eq 0 ]; then
      flagless=$((flagless + 1))
      echo -e "${RED}✗${NC} source guard: a tea write invocation carries NO flag: $line"
    fi
  done <<< "$write_lines"

  assert_eq "3" "$total"    "source guard: all three tea write invocations are present (pulls create, pulls edit, issues create)"
  assert_eq "0" "$flagless" "source guard: every tea write invocation carries at least one flag -- with zero, tea opens an interactive survey and the run hangs"

  # gh's and glab's flag vocabularies must never appear inside a tea call.
  local tea_calls
  tea_calls=$(grep -E '_forge_capture .* -- tea ' "$CLI" || true)
  assert_eq "0" "$(printf '%s' "$tea_calls" | grep -c -- '--body' || true)"          "source guard: no tea invocation passes gh's --body"
  assert_eq "0" "$(printf '%s' "$tea_calls" | grep -c -- '--source-branch' || true)" "source guard: no tea invocation passes glab's --source-branch"
  assert_eq "0" "$(printf '%s' "$tea_calls" | grep -c -- '--target-branch' || true)" "source guard: no tea invocation passes glab's --target-branch"
  assert_eq "0" "$(printf '%s' "$tea_calls" | grep -cE -- ' -y( |$)' || true)"       "source guard: no tea invocation passes glab's -y, which tea does not define"
}

# ONE MUTATION PER ROUTED WRITE VERB. For each of the three, a FRESH copy of
# aimi-cli.sh has that verb's gitea arm -- and only that verb's -- unrouted,
# restoring the pre-story behaviour in which gitea fell through to the
# no-adapter path, and a SPECIFIC, NAMED assertion is shown to go red. Three
# verbs, three distinct named assertions.
#
# Each mutation also asserts that its patch actually landed ("changed"),
# because a mutation test whose patch silently missed passes for the wrong
# reason -- the worst possible failure mode for this particular check.
gtw_test_gitea_write_verbs_mutation_matrix() {
  echo ""
  echo "=== gitea write verbs: unrouting each verb in turn turns a specific named assertion RED ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  gtw_install_fake_tea "$sandbox"

  local mut_dir mut live mutant mutant_rc
  mut_dir=$(mktemp -d)
  mut="$mut_dir/aimi-cli.sh"

  # --- 1/3: forge-pr-create ------------------------------------------------
  # Named assertion under test:
  #   "forge-pr-create gitea: the SHARED write envelope, status created"
  rm -f "$sandbox/gtw_pull_created.flag"
  assert_eq "changed" "$(gtw_mutate_unroute '      _forge_pr_create_gitea "$title" "$base" "$head" "$body" || gt_rc=$?' "$mut")" \
    "MUTATION 1/3 forge-pr-create: the unroute patch landed (guards against a vacuous mutation test)"
  live=$(GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/42' \
    GTW_PULLS_DETAIL_AFTER_JSON='{"index":42,"url":"https://gitea.com/acme/widgets/pulls/42"}' \
    PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>/dev/null | jq -r '.status')
  rm -f "$sandbox/gtw_pull_created.flag"
  mutant=$(GTW_PULLS_CREATE_STDOUT='https://gitea.com/acme/widgets/pulls/42' \
    GTW_PULLS_DETAIL_AFTER_JSON='{"index":42,"url":"https://gitea.com/acme/widgets/pulls/42"}' \
    PATH="$sandbox" bash "$mut" forge-pr-create --title "My PR" --base main --head feat-x --body "the body" 2>/dev/null) && mutant_rc=0 || mutant_rc=$?
  assert_eq "created" "$live" "MUTATION 1/3 forge-pr-create: routed, the named assertion 'status created' is GREEN"
  assert_eq "degraded" "$(printf '%s' "$mutant" | jq -r '.status')" "MUTATION 1/3 forge-pr-create: UNROUTED, that same named assertion goes RED -- status is degraded, not created"
  assert_contains 'no adapter for forge "gitea"' "$(printf '%s' "$mutant" | jq -r '.message')" "MUTATION 1/3 forge-pr-create: the unrouted build reverts to the no-adapter message"
  assert_exit_code "1" "$mutant_rc" "MUTATION 1/3 forge-pr-create: and the unrouted build exits non-zero, as the no-adapter branch always did"

  # --- 2/3: forge-pr-edit --------------------------------------------------
  # Named assertion under test:
  #   "forge-pr-edit gitea: status unchanged with {url, number} from the re-read"
  assert_eq "changed" "$(gtw_mutate_unroute '      _forge_pr_edit_gitea "$number" "$body" || gt_rc=$?' "$mut")" \
    "MUTATION 2/3 forge-pr-edit: the unroute patch landed"
  live=$(GTW_PULLS_EDIT_STDOUT='# #303 edited' \
    GTW_PULLS_DETAIL_JSON='{"index":303,"url":"https://gitea.com/acme/widgets/pulls/303"}' \
    PATH="$sandbox" "$CLI" forge-pr-edit --number 303 --body "updated body" 2>/dev/null | jq -r '.status')
  mutant=$(GTW_PULLS_EDIT_STDOUT='# #303 edited' \
    GTW_PULLS_DETAIL_JSON='{"index":303,"url":"https://gitea.com/acme/widgets/pulls/303"}' \
    PATH="$sandbox" bash "$mut" forge-pr-edit --number 303 --body "updated body" 2>/dev/null) && mutant_rc=0 || mutant_rc=$?
  assert_eq "unchanged" "$live" "MUTATION 2/3 forge-pr-edit: routed, the named assertion 'status unchanged' is GREEN"
  assert_eq "degraded" "$(printf '%s' "$mutant" | jq -r '.status')" "MUTATION 2/3 forge-pr-edit: UNROUTED, that same named assertion goes RED -- status is degraded, not unchanged"
  assert_contains 'no adapter for forge "gitea"' "$(printf '%s' "$mutant" | jq -r '.message')" "MUTATION 2/3 forge-pr-edit: the unrouted build reverts to the no-adapter message"
  assert_exit_code "1" "$mutant_rc" "MUTATION 2/3 forge-pr-edit: and the unrouted build exits non-zero"

  # --- 3/3: forge-issue-create ---------------------------------------------
  # Named assertion under test:
  #   "forge-issue-create gitea: status created, number parsed from the issue URL"
  assert_eq "changed" "$(gtw_mutate_unroute '      _forge_issue_create_gitea "$title" "$body"' "$mut")" \
    "MUTATION 3/3 forge-issue-create: the unroute patch landed"
  live=$(GTW_ISSUES_CREATE_STDOUT='https://gitea.com/acme/widgets/issues/7' \
    PATH="$sandbox" "$CLI" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null | jq -r '.status')
  mutant=$(GTW_ISSUES_CREATE_STDOUT='https://gitea.com/acme/widgets/issues/7' \
    PATH="$sandbox" bash "$mut" forge-issue-create --title "Backend spec" --body "the body" 2>/dev/null) && mutant_rc=0 || mutant_rc=$?
  assert_eq "created" "$live" "MUTATION 3/3 forge-issue-create: routed, the named assertion 'status created' is GREEN"
  assert_eq "degraded" "$(printf '%s' "$mutant" | jq -r '.status')" "MUTATION 3/3 forge-issue-create: UNROUTED, that same named assertion goes RED -- status is degraded, not created"
  assert_contains 'no adapter for forge "gitea"' "$(printf '%s' "$mutant" | jq -r '.message')" "MUTATION 3/3 forge-issue-create: the unrouted build reverts to the no-adapter message"
  assert_exit_code "0" "$mutant_rc" "MUTATION 3/3 forge-issue-create: and the unrouted build STILL exits 0 -- the soft-fail contract survives even the no-adapter branch"

  rm -rf "$mut_dir"
  popd >/dev/null
  teardown_detect_forge_fixture
}

# ============================================================================
# Forge Issue Verb Tests (US-006)
# ============================================================================
# forge-issue-view / forge-issue-create are the first forge-* verbs that
# actually shell out to a forge CLI, so exercising them offline needs a
# fake `gh` on PATH. setup_forge_cli_sandbox/teardown_forge_cli_sandbox
# below is that reusable, clearly-named fixture pair -- written for reuse
# across every forge-* verb's offline tests (forge-pr-view/forge-pr-create,
# a sibling story in this same wave, need the identical technique), mirror-
# ing the fake-opencode-binary precedent cmd_detect_models's tests already
# established (test_resolve_models_opencode_mtime_cache, ~line 8510).

# Sources the pure helper functions this section introduces (no gh
# shell-out, no cmd_ dispatcher) for direct, in-process testing -- same
# technique as source_forge_contract_functions above.
source_forge_issue_functions() {
  eval "$(sed -n '/^_forge_map_state()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_forge_extract_issue_number_from_url()/,/^}/p' "$CLI")"
}

# Removes a sandbox directory created by setup_forge_cli_sandbox.
teardown_forge_cli_sandbox() {
  rm -rf "$1"
}

test_forge_map_state_table() {
  echo ""
  echo "=== _forge_map_state: normalizes per forge-contract.md's State Mapping table ==="

  source_forge_issue_functions

  assert_eq "open"   "$(_forge_map_state github OPEN)"   "_forge_map_state: github OPEN -> open"
  assert_eq "closed" "$(_forge_map_state github CLOSED)" "_forge_map_state: github CLOSED -> closed"
  assert_eq "merged" "$(_forge_map_state github MERGED)" "_forge_map_state: github MERGED -> merged"
  assert_eq "open"   "$(_forge_map_state gitlab opened)" "_forge_map_state: gitlab opened -> open (the one real divergence in the table)"
  assert_eq "closed" "$(_forge_map_state gitlab closed)" "_forge_map_state: gitlab closed -> closed"
  assert_eq "merged" "$(_forge_map_state gitlab merged)" "_forge_map_state: gitlab merged -> merged"
  assert_eq "locked" "$(_forge_map_state gitlab locked)" "_forge_map_state: gitlab locked passes through unchanged (no GitHub/Gitea equivalent)"
  assert_eq "open"   "$(_forge_map_state gitea open)"   "_forge_map_state: gitea open -> open"
  assert_eq "closed" "$(_forge_map_state gitea closed)" "_forge_map_state: gitea closed -> closed"
}

test_forge_extract_issue_number_from_url() {
  echo ""
  echo "=== _forge_extract_issue_number_from_url: extracts trailing number, empty on mismatch ==="

  source_forge_issue_functions

  assert_eq "42" "$(_forge_extract_issue_number_from_url "https://github.com/owner/repo/issues/42")" "extract: plain issue URL"
  assert_eq "42" "$(_forge_extract_issue_number_from_url "https://github.com/owner/repo/issues/42?tab=comments")" "extract: issue URL with query string"
  assert_eq "" "$(_forge_extract_issue_number_from_url "https://github.com/owner/repo/pull/42")" "extract: PR URL does not match (no /issues/ segment)"
  assert_eq "" "$(_forge_extract_issue_number_from_url "not a url")" "extract: non-URL input -> empty"
}

test_forge_emit_issue_create_status_is_gone() {
  echo ""
  echo "=== _forge_emit_issue_create_status: deleted outright, zero remaining callers (the shared write builder replaced it) ==="

  local hits
  hits=$(grep -c '_forge_emit_issue_create_status' "$CLI" 2>/dev/null || true)
  assert_eq "0" "$hits" "issue-create builder: no definition and no caller left anywhere in aimi-cli.sh"

  # And the verb it used to serve now goes through the shared write builder.
  assert_contains "_forge_emit_write_status" "$(sed -n '/^_forge_issue_create()/,/^}/p' "$CLI")" \
    "issue-create builder: _forge_issue_create emits through the shared _forge_emit_write_status instead"
}

test_forge_issue_view_found() {
  echo ""
  echo "=== forge-issue-view: found -- normalized shape, labels, comments count, state mapping ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo '{"number":42,"title":"Bug: thing broke","body":"steps to repro","state":"OPEN","url":"https://github.com/o/r/issues/42","labels":[{"name":"bug"},{"name":"P1"}],"comments":[{"id":1},{"id":2}]}'
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 42) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view found: exit code"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view found: status"
  assert_eq "42" "$(printf '%s' "$out" | jq -r '.data.number')" "forge-issue-view found: number"
  assert_eq "Bug: thing broke" "$(printf '%s' "$out" | jq -r '.data.title')" "forge-issue-view found: title"
  assert_eq "steps to repro" "$(printf '%s' "$out" | jq -r '.data.body')" "forge-issue-view found: body"
  assert_eq "open" "$(printf '%s' "$out" | jq -r '.data.state')" "forge-issue-view found: state normalized (OPEN -> open)"
  assert_eq "https://github.com/o/r/issues/42" "$(printf '%s' "$out" | jq -r '.data.url')" "forge-issue-view found: url"
  assert_eq '["bug","P1"]' "$(printf '%s' "$out" | jq -c '.data.labels')" "forge-issue-view found: labels array of names"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.data.comments')" "forge-issue-view found: comments count derived from array length"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.data.unsupported_fields')" "forge-issue-view found: unsupported_fields empty on GitHub"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-view found: message null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view found: reason null"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_not_found() {
  echo ""
  echo "=== forge-issue-view: not-found is a query result -- exit 0, status not_found ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo "GraphQL: Could not resolve to an issue or pull request with the number of $3. (repository.issue)" >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 999999) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view not-found: exit code stays 0 (query result, not a verb failure)"
  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view not-found: status"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-issue-view not-found: data null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view not-found: reason null (nothing degraded -- the lookup ran and answered)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_degraded_missing_gh() {
  echo ""
  echo "=== forge-issue-view: gh absent -- QUIET degrade (status error, zero stderr) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh written into the sandbox at all -- simulates "gh not installed".

  local stderr_file="/tmp/forge_issue_view_gh_absent_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 42 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view gh-absent: exit code stays 0 (degraded result, not a hard failure)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view gh-absent: status error"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-issue-view gh-absent: data null"
  assert_contains "gh not found" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-view gh-absent: message names gh"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view gh-absent: reason is cli_missing"
  assert_eq "" "$(cat "$stderr_file")" "forge-issue-view gh-absent: QUIET mode -- zero stderr output"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_non_github_forge_degrades() {
  echo ""
  echo "=== forge-issue-view: a forge with no adapter (unknown) degrades, does not crash ==="

  # `unknown`, not gitea: phase 4 outline:02 routed gitea to tea, so the
  # adapter-less branch this test pins is now reached only by an unrecognized
  # host. RETARGETED, never deleted -- the no_adapter path must stay covered,
  # and `unknown` is the last control there is (AIMI_FORGE_TYPE validates only
  # github|gitlab|gitea, aimi-cli.sh:2130, and all three now have adapters).
  setup_detect_forge_fixture origin https://git.example.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 1) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view non-github: exit 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view non-github: status error"
  assert_contains "unknown" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-view non-github: message names the detected forge"
  assert_eq "no_adapter" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view non-github: reason is no_adapter"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_generic_failure_not_authenticated() {
  echo ""
  echo "=== forge-issue-view: gh broke AND the auth re-check says logged out -- reason not_authenticated ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # `issue view` fails with wording that does NOT match the not-found probe,
  # so the generic branch is reached; `auth status` then fails too, which is
  # the structural signal the classifier reads.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo "gh: something went wrong" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "You are not logged into any GitHub hosts." >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 42) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view not-authenticated: exit code stays 0 (degraded result)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view not-authenticated: status error"
  assert_eq "not_authenticated" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view not-authenticated: reason resolved by the structural auth re-check, not by gh's stderr wording"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_generic_failure_cli_failed() {
  echo ""
  echo "=== forge-issue-view: gh broke but the auth re-check says logged in -- reason cli_failed ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo "gh: connection refused" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "github.com"
  echo "  Logged in to github.com account octocat (keyring)"
  echo "  - Active account: true"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 42) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-view cli-failed: exit code stays 0 (degraded result)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-view cli-failed: status error"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "forge-issue-view cli-failed: an authenticated session means the failure was something else"
  assert_contains "connection refused" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-view cli-failed: message still carries the detail to read"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_view_input_errors() {
  echo ""
  echo "=== forge-issue-view: --url extraction, and caller-input errors exit non-zero ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo "{\"number\":$3,\"title\":\"t\",\"body\":\"b\",\"state\":\"OPEN\",\"url\":\"https://github.com/o/r/issues/$3\",\"labels\":[],\"comments\":[]}"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code stderr_file="/tmp/forge_issue_view_input_stderr.$$"

  # --url extraction routes to the same normalized number path.
  out=$(PATH="$sandbox" "$CLI" forge-issue-view --url "https://github.com/owner/repo/issues/123") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "forge-issue-view --url: exit code"
  assert_eq "123" "$(printf '%s' "$out" | jq -r '.data.number')" "forge-issue-view --url: number extracted from URL"

  # Missing both --number and --url.
  PATH="$sandbox" "$CLI" forge-issue-view >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-issue-view missing identifier: exit 1"
  assert_stderr_contains "--number <n> or --url" "$(cat "$stderr_file")" "forge-issue-view missing identifier: stderr names both flags"

  # Non-numeric --number.
  PATH="$sandbox" "$CLI" forge-issue-view --number abc >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-issue-view non-numeric --number: exit 1"
  assert_stderr_contains "must be a positive integer" "$(cat "$stderr_file")" "forge-issue-view non-numeric --number: stderr names the constraint"

  # Unknown/credential-shaped flag is rejected outright -- no --token exists.
  PATH="$sandbox" "$CLI" forge-issue-view --token secret >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-issue-view --token: rejected as unknown flag, exit 1"
  assert_stderr_contains "unknown flag" "$(cat "$stderr_file")" "forge-issue-view --token: stderr names it unknown"

  rm -f "$stderr_file"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_create_success() {
  echo ""
  echo "=== forge-issue-create: success -- the shared write envelope, url/number nested under data, derived from gh's own stdout URL ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/77"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_issue_create_success_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-create --title "Backend: thing" --body "spec here" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create success: exit code"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-create success: status created"
  assert_eq "https://github.com/owner/repo/issues/77" "$(printf '%s' "$out" | jq -r '.data.url')" "forge-issue-create success: url captured from gh stdout, nested under data like the two PR write verbs"
  assert_eq "77" "$(printf '%s' "$out" | jq -r '.data.number')" "forge-issue-create success: number derived from the URL (no caller-side regex needed), nested under data"
  assert_eq '["number","url"]' "$(printf '%s' "$out" | jq -c '.data | keys')" "forge-issue-create success: data keys are exactly {url, number} -- no flat sibling keys survive"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-create success: message null"
  assert_eq "" "$(cat "$stderr_file")" "forge-issue-create success: no manual instruction printed on success"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_create_degraded_failure_prints_manual() {
  echo ""
  echo "=== forge-issue-create: create call fails -- degraded status, exit 0, manual instruction printed (soft-fail contract) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "HTTP 403: Resource not accessible by integration" >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_issue_create_fail_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-create --title "Backend: thing" --body "spec here" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create degraded: exit code STAYS 0 -- never a hard failure a caller could mistake for a reason to block PR creation"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-create degraded: status"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "forge-issue-create degraded: data is null wholesale (the shared builder's null-forcing), so no stale url/number can leak"
  assert_contains "gh issue create exited 1" "$(printf '%s' "$out" | jq -r '.message')" "forge-issue-create degraded: message carries the gh failure detail"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-issue-create degraded: manual instruction printed (MANDATORY-PRINT)"
  assert_stderr_contains "Backend: thing" "$(cat "$stderr_file")" "forge-issue-create degraded: manual instruction includes the title"
  assert_stderr_contains "spec here" "$(cat "$stderr_file")" "forge-issue-create degraded: manual instruction includes the body"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_create_missing_gh_mandatory_print() {
  echo ""
  echo "=== forge-issue-create: gh absent -- MANDATORY-PRINT degrade (bin_check warning + manual instruction) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- simulates "gh not installed".

  local stderr_file="/tmp/forge_issue_create_no_gh_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-issue-create --title "T" --body "B" 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create gh-absent: exit 0"
  assert_eq "degraded" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-create gh-absent: status degraded"
  assert_stderr_contains "gh not found" "$(cat "$stderr_file")" "forge-issue-create gh-absent: _forge_bin_check's mandatory warning names gh"
  assert_stderr_contains "create it yourself" "$(cat "$stderr_file")" "forge-issue-create gh-absent: manual instruction also printed"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_create_credential_via_env_not_argv() {
  echo ""
  echo "=== forge-issue-create: credential reaches gh via inherited env var, never argv ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
# Fails loudly if any argument looks like a credential -- proves
# cmd_forge_issue_create/_forge_issue_create never interpolate one into argv.
for arg in "$@"; do
  case "$arg" in
    *token*|*TOKEN*|--token|ghp_*|gho_*) echo "credential leaked into argv: $arg" >&2; exit 2 ;;
  esac
done
if [ -z "${GH_TOKEN:-}" ]; then
  echo "GH_TOKEN not inherited from environment" >&2
  exit 3
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/55"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(GH_TOKEN="secret-value-xyz" PATH="$sandbox" "$CLI" forge-issue-create --title "T" --body "B") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "forge-issue-create credential: exit 0 (GH_TOKEN inherited correctly, no argv leak)"
  assert_eq "created" "$(printf '%s' "$out" | jq -r '.status')" "forge-issue-create credential: status created"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_create_input_errors() {
  echo ""
  echo "=== forge-issue-create: missing --title and unknown/credential-shaped flags are caller errors ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local stderr_file="/tmp/forge_issue_create_input_stderr.$$" exit_code

  PATH="$sandbox" "$CLI" forge-issue-create --body "B" >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-issue-create missing --title: exit 1"
  assert_stderr_contains "--title <text> is required" "$(cat "$stderr_file")" "forge-issue-create missing --title: stderr names the missing flag"

  PATH="$sandbox" "$CLI" forge-issue-create --title T --body B --token secret >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-issue-create --token: rejected as unknown flag, exit 1"
  assert_stderr_contains "unknown flag" "$(cat "$stderr_file")" "forge-issue-create --token: stderr names it unknown"

  rm -f "$stderr_file"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_issue_verbs_registered_in_help_and_dispatcher() {
  echo ""
  echo "=== forge-issue-view / forge-issue-create: listed in help and routed by the dispatcher ==="

  local help_out
  help_out=$("$CLI" help 2>&1)
  assert_contains "forge-issue-view" "$help_out" "help: lists forge-issue-view"
  assert_contains "forge-issue-create" "$help_out" "help: lists forge-issue-create"

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local view_out create_out
  view_out=$(PATH="$sandbox" "$CLI" forge-issue-view --number 1 2>&1)
  create_out=$(PATH="$sandbox" "$CLI" forge-issue-create --title t --body b 2>&1)

  popd >/dev/null
  teardown_detect_forge_fixture

  if printf '%s' "$view_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-issue-view is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-issue-view is routed"
    ((TESTS_PASSED++))
  fi

  if printf '%s' "$create_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-issue-create is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-issue-create is routed"
    ((TESTS_PASSED++))
  fi
}

# ============================================================================
# Forge Review-Thread Verb Tests (US-007)
# ============================================================================
# forge-pr-review-threads / forge-resolve-review-thread port the two GraphQL
# scripts under skills/resolve-pr-parallel/scripts/ into aimi-cli.sh. Offline
# fixtures reuse setup_forge_cli_sandbox/teardown_forge_cli_sandbox (US-006,
# test-aimi-cli.sh:17593) rather than adding a fourth fake-gh fixture -- each
# test below writes its own tiny `gh` stub into the sandbox, exactly the
# technique that section's own header comment predicted this sibling story
# would need for a `gh api graphql` invocation shape neither the FAKE_GH_*
# parameterized fixture (US-003) nor a bare `gh issue`/`gh pr` stub already
# covers.

# Extracts the two query/mutation builder functions' literal source text
# (not their runtime output) so the security tests below can inspect the
# actual quoting/interpolation shape rather than a rendered string.
_forge_review_thread_query_source() {
  sed -n '/^_forge_review_threads_query()/,/^}/p' "$CLI"
}

_forge_resolve_review_thread_mutation_source() {
  sed -n '/^_forge_resolve_review_thread_mutation()/,/^}/p' "$CLI"
}

# AC1's core security requirement: every identifier gh api graphql consumes
# for these two verbs is bound through -f/-F, never through string
# interpolation into the query/mutation text. The literal source of both
# constants DOES contain `$owner`/`$repo`/`$pr`/`$threadId` -- that is
# GraphQL's own variable-reference syntax, inert under bash's single-quoting
# (see the section header comment in aimi-cli.sh immediately above these
# two functions for the full statement of why a bare grep for any `$`
# character would be a false positive here). What must be true instead, and
# what this test actually asserts: (a) the query/mutation text is a single
# bash single-quoted literal with no shell command substitution inside it,
# and (b) the two adapter functions bind owner/repo/pr/threadId to gh ONLY
# via -f/-F flags.
test_forge_review_thread_queries_bind_via_flags_not_interpolation() {
  echo ""
  echo "=== forge-pr-review-threads / forge-resolve-review-thread: identifiers bound via gh -f/-F, zero shell interpolation in query text ==="

  local query_src mutation_src
  query_src=$(_forge_review_thread_query_source)
  mutation_src=$(_forge_resolve_review_thread_mutation_source)

  assert_contains "printf '%s' '" "$query_src" "review-threads query: body is a single-quoted printf literal"
  assert_contains "printf '%s' '" "$mutation_src" "resolve-thread mutation: body is a single-quoted printf literal"

  assert_contains '$owner: String!' "$query_src" "review-threads query: retains GraphQL \$owner variable declaration verbatim"
  assert_contains '$repo: String!' "$query_src" "review-threads query: retains GraphQL \$repo variable declaration verbatim"
  assert_contains '$pr: Int!' "$query_src" "review-threads query: retains GraphQL \$pr variable declaration verbatim"
  assert_contains '$threadId: ID!' "$mutation_src" "resolve-thread mutation: retains GraphQL \$threadId variable declaration verbatim"

  if printf '%s' "$query_src" | grep -qE '\$\(|`'; then
    echo -e "${RED}✗${NC} review-threads query: contains shell command substitution (\$( or backtick) -- must be zero"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} review-threads query: no shell command substitution anywhere in the query text"
    ((TESTS_PASSED++))
  fi

  if printf '%s' "$mutation_src" | grep -qE '\$\(|`'; then
    echo -e "${RED}✗${NC} resolve-thread mutation: contains shell command substitution (\$( or backtick) -- must be zero"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} resolve-thread mutation: no shell command substitution anywhere in the mutation text"
    ((TESTS_PASSED++))
  fi

  # The two adapter functions must bind every identifier via gh's own -f/-F
  # flags -- never by concatenating the value into the query/mutation string.
  local github_adapter_src resolve_adapter_src
  github_adapter_src=$(sed -n '/^_forge_pr_review_threads_github()/,/^}/p' "$CLI")
  resolve_adapter_src=$(sed -n '/^_forge_resolve_review_thread()/,/^}/p' "$CLI")

  assert_contains '-f owner="$owner"' "$github_adapter_src" "forge-pr-review-threads: owner bound via gh -f flag"
  assert_contains '-f repo="$repo"' "$github_adapter_src" "forge-pr-review-threads: repo bound via gh -f flag"
  assert_contains '-F pr="$pr_number"' "$github_adapter_src" "forge-pr-review-threads: PR number bound via gh -F flag (Int! variable)"
  assert_contains '-f threadId="$thread_id"' "$resolve_adapter_src" "forge-resolve-review-thread: thread id bound via gh -f flag"
}

# AC1's fail-fast usage checks: the PR number and thread id are validated
# BEFORE either is ever passed to gh.
test_forge_review_thread_input_validation() {
  echo ""
  echo "=== forge-pr-review-threads / forge-resolve-review-thread: PR number and thread id validated before reaching gh ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- if validation did not fail-fast, the command
  # would instead surface a "gh not found" degrade rather than a usage error.

  local exit_code stderr_file="/tmp/forge_review_threads_validation_stderr.$$"

  PATH="$sandbox" "$CLI" forge-pr-review-threads --pr abc --owner o --repo r >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-pr-review-threads non-numeric --pr: exit 1"
  assert_stderr_contains "must be a positive integer" "$(cat "$stderr_file")" "forge-pr-review-threads non-numeric --pr: stderr names the constraint"

  PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner 'o;rm' --repo r >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-pr-review-threads unsafe --owner: exit 1"
  assert_stderr_contains "invalid --owner" "$(cat "$stderr_file")" "forge-pr-review-threads unsafe --owner: stderr names it invalid"

  PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id 'bad id; rm -rf /' >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "forge-resolve-review-thread unsafe --thread-id: exit 1"
  assert_stderr_contains "invalid --thread-id" "$(cat "$stderr_file")" "forge-resolve-review-thread unsafe --thread-id: stderr names it invalid"

  rm -f "$stderr_file"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_found_default_filter() {
  echo ""
  echo "=== forge-pr-review-threads: found -- default filter drops resolved/outdated threads ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if printf '%s' "$*" | grep -q "FetchReviewThreads"; then
    printf '%s' '{"data":{"repository":{"pullRequest":{"title":"Fix bug","url":"https://github.com/acme/widgets/pull/5","reviewThreads":{"totalCount":2,"edges":[{"node":{"id":"T1","isResolved":false,"isOutdated":false,"isCollapsed":false,"path":"a.rb","line":10,"startLine":10,"diffSide":"RIGHT","comments":{"totalCount":1,"nodes":[{"id":"C1","author":{"login":"alice"},"body":"fix this","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","url":"https://github.com/acme/widgets/pull/5#C1","outdated":false}]}}},{"node":{"id":"T2","isResolved":true,"isOutdated":false,"isCollapsed":false,"path":"b.rb","line":20,"startLine":20,"diffSide":"RIGHT","comments":{"totalCount":0,"nodes":[]}}}]}}}}}'
    exit 0
  fi
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner acme --repo widgets) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads found: exit code"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads found: status"
  assert_eq "5" "$(printf '%s' "$out" | jq -r '.data.pr.number')" "pr-review-threads found: pr.number"
  assert_eq "Fix bug" "$(printf '%s' "$out" | jq -r '.data.pr.title')" "pr-review-threads found: pr.title"
  assert_eq "https://github.com/acme/widgets/pull/5" "$(printf '%s' "$out" | jq -r '.data.pr.url')" "pr-review-threads found: pr.url"
  assert_eq "1" "$(printf '%s' "$out" | jq '.data.threads | length')" "pr-review-threads found: default filter keeps only the unresolved, non-outdated thread"
  assert_eq "T1" "$(printf '%s' "$out" | jq -r '.data.threads[0].id')" "pr-review-threads found: surviving thread id"
  assert_eq "alice" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].author.login')" "pr-review-threads found: comment author.login preserved"
  assert_eq "1" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.totalCount')" "pr-review-threads found: comments.totalCount preserved"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.data.unsupported_fields')" "pr-review-threads found: unsupported_fields empty on GitHub"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "pr-review-threads found: message null"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_all_flag_includes_resolved_and_outdated() {
  echo ""
  echo "=== forge-pr-review-threads: --all returns resolved/outdated threads a plain call would filter out ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if printf '%s' "$*" | grep -q "FetchReviewThreads"; then
    printf '%s' '{"data":{"repository":{"pullRequest":{"title":"Fix bug","url":"https://github.com/acme/widgets/pull/5","reviewThreads":{"totalCount":2,"edges":[{"node":{"id":"T1","isResolved":false,"isOutdated":false,"isCollapsed":false,"path":"a.rb","line":10,"startLine":10,"diffSide":"RIGHT","comments":{"totalCount":0,"nodes":[]}}},{"node":{"id":"T2","isResolved":true,"isOutdated":true,"isCollapsed":true,"path":"b.rb","line":20,"startLine":20,"diffSide":"RIGHT","comments":{"totalCount":0,"nodes":[]}}}]}}}}}'
    exit 0
  fi
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner acme --repo widgets --all) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads --all: exit code"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads --all: status"
  assert_eq "2" "$(printf '%s' "$out" | jq '.data.threads | length')" "pr-review-threads --all: both threads present, including resolved+outdated"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_not_found_null_pull_request() {
  echo ""
  echo "=== forge-pr-review-threads: null pullRequest -- not_found, exits 0 ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if printf '%s' "$*" | grep -q "FetchReviewThreads"; then
    printf '%s' '{"data":{"repository":{"pullRequest":null}}}'
    exit 0
  fi
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 999999 --owner acme --repo widgets) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads not-found: exit code stays 0 (query result, not a verb failure)"
  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads not-found: status"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "pr-review-threads not-found: data null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "pr-review-threads not-found: message null -- distinguishable from the degraded case by this alone"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads not-found: reason null on the not_found outcome"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_degraded_missing_gh() {
  echo ""
  echo "=== forge-pr-review-threads: gh absent -- QUIET degrade (status error, zero stderr) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh written into the sandbox at all -- simulates "gh not installed".

  local stderr_file="/tmp/forge_pr_review_threads_gh_absent_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner acme --repo widgets 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads gh-absent: exit code stays 0 (degraded result, not a hard failure)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads gh-absent: status error"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "pr-review-threads gh-absent: data null"
  assert_contains "gh not found" "$(printf '%s' "$out" | jq -r '.message')" "pr-review-threads gh-absent: message names gh -- non-null, distinguishable from the not_found case"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads gh-absent: reason is cli_missing"
  assert_eq "" "$(cat "$stderr_file")" "pr-review-threads gh-absent: QUIET mode -- zero stderr output"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_non_github_forge_degrades() {
  echo ""
  echo "=== forge-pr-review-threads: a forge with no adapter (an UNRECOGNIZED host) degrades, does not crash ==="

  # RETARGETED TWICE, NEVER DELETED. Phase 3 US-004 moved it from gitlab to
  # codeberg.org once glab routing landed; phase 4 outline:04 moves it again,
  # to an unrecognized host, now that `tea` routing has landed and codeberg.org
  # classifies as the routed forge `gitea`. Deleting it instead would leave
  # the no_adapter branch untested for this verb entirely.
  #
  # THIS IS THE END OF THE LINE FOR FORGE-NAME RETARGETING. AIMI_FORGE_TYPE
  # validates against github|gitlab|gitea (aimi-cli.sh:2130) and all three are
  # routed, so there is no forge word left to point this test at. The only
  # remaining stand-in for "a forge with no adapter" is `unknown`, which
  # _detect_forge_classify_host answers for any host outside its three
  # exact-or-subdomain families -- reachable only through a remote URL like
  # the one below. Any future story needing this control must build its own
  # unrecognized-host fixture; there is nothing else to inherit.
  setup_detect_forge_fixture origin https://git.example.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 1) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads adapterless forge: exit 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads adapterless forge: status error"
  assert_contains "unknown" "$(printf '%s' "$out" | jq -r '.message')" "pr-review-threads adapterless forge: message names the detected forge, which is now unknown -- the last stand-in available"
  assert_eq "no_adapter" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads adapterless forge: reason is no_adapter"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_owner_repo_unresolved_is_cli_failed() {
  echo ""
  echo "=== forge-pr-review-threads: owner/repo unresolvable -- cli_failed, NOT a fifth enum value ==="

  # A github.com remote whose path has no owner/repo split, so neither the
  # gh primary nor the local-parse fallback can produce an owner/repo pair.
  setup_detect_forge_fixture origin https://github.com/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # gh IS present (so the cli_missing gate passes) but cannot name the repo.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "error: could not determine repository" >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads owner/repo-unresolved: exit code stays 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads owner/repo-unresolved: status error"
  assert_contains "could not resolve owner/repo" "$(printf '%s' "$out" | jq -r '.message')" "pr-review-threads owner/repo-unresolved: message names the unresolved pair"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads owner/repo-unresolved: reason is cli_failed -- no fifth enum value for one call site, and no classifier call (no gh invocation to re-check auth against)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_graphql_failure_not_authenticated() {
  echo ""
  echo "=== forge-pr-review-threads: graphql broke AND the auth re-check says logged out -- not_authenticated ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo "gh: request failed" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "You are not logged into any GitHub hosts." >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner acme --repo widgets) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads not-authenticated: exit code stays 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads not-authenticated: status error"
  assert_eq "not_authenticated" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads not-authenticated: reason resolved structurally by the auth re-check"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_graphql_failure_cli_failed() {
  echo ""
  echo "=== forge-pr-review-threads: graphql broke but the auth re-check says logged in -- cli_failed ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo "gh: connection refused" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "github.com"
  echo "  Logged in to github.com account octocat (keyring)"
  echo "  - Active account: true"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5 --owner acme --repo widgets) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads cli-failed: exit code stays 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads cli-failed: status error"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "pr-review-threads cli-failed: an authenticated session means the failure was something else"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_review_threads_owner_repo_auto_detected() {
  echo ""
  echo "=== forge-pr-review-threads: owner/repo auto-detected via forge-repo-info when not both supplied ==="

  setup_detect_forge_fixture origin https://github.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local log_file="$sandbox/gh.log"
  cat > "$sandbox/gh" << FAKE_GH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log_file"
if [ "\$1" = "api" ] && [ "\$2" = "graphql" ]; then
  if printf '%s' "\$*" | grep -q "FetchReviewThreads"; then
    printf '%s' '{"data":{"repository":{"pullRequest":null}}}'
    exit 0
  fi
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 5) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "pr-review-threads auto-detect: exit code"
  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "pr-review-threads auto-detect: query still ran (proves owner/repo resolved, not skipped)"
  assert_contains 'owner=acme' "$(cat "$log_file")" "pr-review-threads auto-detect: owner auto-detected from the git remote via forge-repo-info"
  assert_contains 'repo=widgets' "$(cat "$log_file")" "pr-review-threads auto-detect: repo auto-detected from the git remote via forge-repo-info"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_success() {
  echo ""
  echo "=== forge-resolve-review-thread: success -- resolved:true, matches the mutation's own output fields ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if printf '%s' "$*" | grep -q "resolveReviewThread"; then
    printf '%s' '{"data":{"resolveReviewThread":{"thread":{"id":"PRRT_kwDOABC123","isResolved":true,"path":"a.rb","line":5}}}}'
    exit 0
  fi
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_resolve_review_thread_success_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id PRRT_kwDOABC123 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "resolve-review-thread success: exit code"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "resolve-review-thread success: status"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.resolved')" "resolve-review-thread success: resolved true"
  assert_eq "PRRT_kwDOABC123" "$(printf '%s' "$out" | jq -r '.data.thread.id')" "resolve-review-thread success: thread.id"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.thread.isResolved')" "resolve-review-thread success: thread.isResolved"
  assert_eq "a.rb" "$(printf '%s' "$out" | jq -r '.data.thread.path')" "resolve-review-thread success: thread.path"
  assert_eq "5" "$(printf '%s' "$out" | jq -r '.data.thread.line')" "resolve-review-thread success: thread.line"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "resolve-review-thread success: message null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "resolve-review-thread success: reason null"
  assert_eq "" "$(cat "$stderr_file")" "resolve-review-thread success: no manual instruction printed"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_confirmed_invalid_id() {
  echo ""
  echo "=== forge-resolve-review-thread: mutation errors array -- confirmed-invalid, exit 0, no print ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if printf '%s' "$*" | grep -q "resolveReviewThread"; then
    echo "gh: Could not resolve to a node with the global id of 'bad-id'. (resolveReviewThread)" >&2
    exit 1
  fi
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_resolve_review_thread_invalid_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id bad-id 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "resolve-review-thread confirmed-invalid: exit 0 (the mutation ran; this is a confirmed answer, not a tool failure)"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "resolve-review-thread confirmed-invalid: status found (a definitive answer is still a successful lookup, per forge-auth-status's own authenticated:false precedent)"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.resolved')" "resolve-review-thread confirmed-invalid: resolved false"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.thread')" "resolve-review-thread confirmed-invalid: thread null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "resolve-review-thread confirmed-invalid: message null -- distinguishable from the degraded case by this alone"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "resolve-review-thread confirmed-invalid: reason null -- status stays found, and a confirmed answer must not acquire a reason merely for sitting beside a degraded-sounding path"
  assert_eq "" "$(cat "$stderr_file")" "resolve-review-thread confirmed-invalid: the confirmed-invalid-id path prints NOTHING (only the degraded path does)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_missing_gh_mandatory_print() {
  echo ""
  echo "=== forge-resolve-review-thread: gh absent -- MANDATORY-PRINT degrade, exits non-zero ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN
  # No gh in the sandbox -- simulates "gh not installed".

  local stderr_file="/tmp/forge_resolve_review_thread_no_gh_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id PRRT_kwDOABC123 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "resolve-review-thread gh-absent: exits NON-ZERO (write verb, no fallback path)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "resolve-review-thread gh-absent: status error"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data')" "resolve-review-thread gh-absent: data null"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "resolve-review-thread gh-absent: reason is cli_missing"
  assert_stderr_contains "gh not found" "$(cat "$stderr_file")" "resolve-review-thread gh-absent: stderr names gh as the missing binary"
  assert_stderr_contains "Files changed" "$(cat "$stderr_file")" "resolve-review-thread gh-absent: manual fallback instruction printed (no gh subcommand or REST fallback exists)"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_mutation_failure_not_authenticated() {
  echo ""
  echo "=== forge-resolve-review-thread: mutation broke AND the auth re-check says logged out -- not_authenticated ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  # Deliberately NOT the "could not resolve to a node" wording, so the
  # confirmed-invalid-id branch is skipped and the generic branch is reached.
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo "gh: request failed" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "You are not logged into any GitHub hosts." >&2
  exit 1
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_resolve_review_thread_noauth_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id PRRT_kwDOABC123 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "resolve-review-thread not-authenticated: exits non-zero (write verb, no fallback path)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "resolve-review-thread not-authenticated: status error"
  assert_eq "not_authenticated" "$(printf '%s' "$out" | jq -r '.reason')" "resolve-review-thread not-authenticated: reason resolved structurally by the auth re-check"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_resolve_review_thread_mutation_failure_cli_failed() {
  echo ""
  echo "=== forge-resolve-review-thread: mutation broke but the auth re-check says logged in -- cli_failed ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo "gh: connection refused" >&2
  exit 1
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  echo "github.com"
  echo "  Logged in to github.com account octocat (keyring)"
  echo "  - Active account: true"
  exit 0
fi
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local stderr_file="/tmp/forge_resolve_review_thread_clifailed_stderr.$$"
  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id PRRT_kwDOABC123 2>"$stderr_file") && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "resolve-review-thread cli-failed: exits non-zero (write verb, no fallback path)"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "resolve-review-thread cli-failed: status error"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "resolve-review-thread cli-failed: an authenticated session means the failure was something else"
  rm -f "$stderr_file"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_review_thread_verbs_registered_in_help_and_dispatcher() {
  echo ""
  echo "=== forge-pr-review-threads / forge-resolve-review-thread: listed in help and routed by the dispatcher ==="

  local help_out
  help_out=$("$CLI" help 2>&1)
  assert_contains "forge-pr-review-threads" "$help_out" "help: lists forge-pr-review-threads"
  assert_contains "forge-resolve-review-thread" "$help_out" "help: lists forge-resolve-review-thread"

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local view_out resolve_out
  view_out=$(PATH="$sandbox" "$CLI" forge-pr-review-threads --pr 1 --owner o --repo r 2>&1)
  resolve_out=$(PATH="$sandbox" "$CLI" forge-resolve-review-thread --thread-id T1 2>&1) || true

  popd >/dev/null
  teardown_detect_forge_fixture

  if printf '%s' "$view_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-pr-review-threads is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-pr-review-threads is routed"
    ((TESTS_PASSED++))
  fi

  if printf '%s' "$resolve_out" | grep -q "Unknown command"; then
    echo -e "${RED}✗${NC} dispatcher: forge-resolve-review-thread is not routed (answers 'Unknown command')"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} dispatcher: forge-resolve-review-thread is routed"
    ((TESTS_PASSED++))
  fi
}

# ============================================================================
# GitLab Review-Thread Routing Tests (phase 3 US-004)
# ============================================================================
# forge-pr-review-threads and forge-resolve-review-thread routed to
# `glab mr note list` / `glab mr note resolve`.
#
# NAMING: every function this story adds is prefixed `glt_` (GitLab Threads),
# INCLUDING the test functions themselves. That is an orchestration
# constraint, not a style preference: three sibling stories edited this one
# file in parallel, and bash silently keeps the LAST definition of a
# duplicated function name -- three individually green branches would then
# produce one red merge. A per-story prefix makes that collision impossible
# to express.
#
# glab is NOT installed on the machine this was written on -- the phase's
# declared verification ceiling, already recorded by
# _forge_map_pr_field_gitlab's header for the same reason -- so the stub
# below is the only glab any assertion here ever sees. Its payloads are
# modelled on GitLab's Discussions API shape, which glab's own documented
# examples pin (`glab mr note list -F json | jq '.[].notes[].body'` and
# `jq -r '.[].id'`), never on a captured real-binary response.
#
# A SEPARATE stub from setup_fake_glab_fixture on purpose: that one answers
# `mr view` for the field-mapper story and hard-exits 127 on anything else.
# Extending it here would put three parallel stories inside one case
# statement.

# Writes an argv-recording fake `glab` into an existing forge CLI sandbox and
# prints nothing. Every invocation's argv is appended to <sandbox>/glab.log,
# one line per call, so an assertion can prove WHICH flags were passed rather
# than merely that a call happened -- the whole point of the --state
# assertion below, which a fake that returned only unresolved items could
# otherwise satisfy vacuously.
#
# Driven entirely by GLT_* environment variables, all optional:
#   GLT_LIST_PAYLOAD_FILE   file whose contents are `mr note list` stdout
#   GLT_LIST_STDOUT         literal `mr note list` stdout (used when no file)
#   GLT_LIST_FAIL_STDERR    when set, `mr note list` writes it to stderr and
#                           exits 1 instead of printing anything
#   GLT_RESOLVE_FAIL_STDERR same, for `mr note resolve`
glt_write_fake_glab() {
  local sandbox="$1"
  cat > "$sandbox/glab" << 'GLT_FAKE_GLAB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GLT_GLAB_LOG"
case "$1 $2 $3" in
  "mr note list")
    if [ -n "${GLT_LIST_FAIL_STDERR:-}" ]; then
      printf '%s' "$GLT_LIST_FAIL_STDERR" >&2
      exit 1
    fi
    if [ -n "${GLT_LIST_PAYLOAD_FILE:-}" ]; then
      cat "$GLT_LIST_PAYLOAD_FILE"
    else
      printf '%s' "${GLT_LIST_STDOUT-[]}"
    fi
    exit 0
    ;;
  "mr note resolve")
    if [ -n "${GLT_RESOLVE_FAIL_STDERR:-}" ]; then
      printf '%s' "$GLT_RESOLVE_FAIL_STDERR" >&2
      exit 1
    fi
    echo "Resolved discussion."
    exit 0
    ;;
esac
echo "fake-glab: unhandled invocation: $*" >&2
exit 127
GLT_FAKE_GLAB
  chmod +x "$sandbox/glab"
}

# The recorded argv log, or the empty string when glab was never invoked.
glt_glab_argv() {
  cat "${1}/glab.log" 2>/dev/null || true
}

# How many times the fake glab was invoked. Load-bearing for the "resolves and
# does NOT post a reply" proof: the count must be exactly one.
glt_glab_call_count() {
  local log="${1}/glab.log" count
  if [ ! -f "$log" ]; then
    printf '0'
    return 0
  fi
  count=$(grep -c '' "$log" 2>/dev/null) || count=0
  printf '%s' "$count"
}

# One realistic `glab mr note list <iid> -F json` document: a JSON ARRAY of
# discussions, each carrying a `notes` array. Three properties are
# load-bearing and must not be "tidied" away:
#   - the first discussion's `id` is a FULL 40-character hex string. The
#     round-trip assertion resolves by exactly this value, so shortening it to
#     glab's 8-character display prefix would make that test pass by accident.
#   - the second discussion is a general (non-diff) note with NO position, so
#     path/line/diffSide are proven to come back null rather than guessed at.
#   - the second discussion's single note is `resolvable: false`, which is a
#     different thing from an unresolved resolvable note and must not be
#     reported as resolved.
glt_discussion_fixture() {
  printf '%s' '[
    {
      "id": "6a9c1750b37d513a43987b574953fceb50b03ce7",
      "individual_note": false,
      "notes": [
        {"id": 1126, "type": "DiffNote", "body": "please rename this",
         "author": {"username": "monalisa"},
         "created_at": "2026-01-01T10:00:00Z", "updated_at": "2026-01-01T10:30:00Z",
         "system": false, "resolvable": true, "resolved": false, "resolved_by": null,
         "position": {"base_sha": "aaa", "start_sha": "bbb", "head_sha": "ccc",
                      "old_path": "src/main.go", "new_path": "src/main.go",
                      "position_type": "text", "old_line": null, "new_line": 17,
                      "line_range": {"start": {"type": "new", "old_line": null, "new_line": 15},
                                     "end":   {"type": "new", "old_line": null, "new_line": 17}}}},
        {"id": 1127, "type": "DiffNote", "body": "agreed",
         "author": {"username": "octocat"},
         "created_at": "2026-01-01T11:00:00Z", "updated_at": "2026-01-01T11:00:00Z",
         "system": false, "resolvable": true, "resolved": false, "resolved_by": null}
      ]
    },
    {
      "id": "aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00",
      "individual_note": true,
      "notes": [
        {"id": 2000, "type": null, "body": "general remark",
         "author": {"username": "hubot"},
         "created_at": "2026-01-02T10:00:00Z", "updated_at": "2026-01-02T10:00:00Z",
         "system": false, "resolvable": false, "resolved": false}
      ]
    }
  ]'
}

# A hermetic PATH sandbox with the argv-recording fake glab installed in it.
# Prints the sandbox path, so it is safe inside $(...) -- which is exactly why
# the sandbox is created HERE and not inside the runner below: the runner is
# always called in a command substitution, and a value written from inside one
# dies with that subshell. Same pitfall _forge_capture's own header documents.
glt_new_sandbox() {
  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  glt_write_fake_glab "$sandbox"
  printf '%s' "$sandbox"
}

# Same sandbox, WITHOUT the fake glab. The allowlist setup_forge_cli_sandbox
# builds carries no glab of its own, so `command -v glab` genuinely fails
# inside it, exactly like a machine that never installed the GitLab CLI.
glt_new_sandbox_without_glab() {
  setup_forge_cli_sandbox
}

# Runs one aimi-cli.sh invocation inside the throwaway gitlab-remote
# repository, under <sandbox> as the entire PATH. Prints the command's stdout;
# its stderr goes to <stderr-file>. GLT_GLAB_LOG is pointed at
# <sandbox>/glab.log so glt_glab_argv can read the recorded argv afterwards.
#
# Usage: glt_run_cli <sandbox> <stderr-file> [ENV=VAL ...] -- <args...>
glt_run_cli() {
  local sandbox="$1" stderr_file="$2"
  shift 2

  local assignments=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    assignments+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift

  (
    cd "$GLT_REPO_DIR" || exit 1
    export PATH="$sandbox"
    export GLT_GLAB_LOG="$sandbox/glab.log"
    if [ "${#assignments[@]}" -gt 0 ]; then
      for _glt_assignment in "${assignments[@]}"; do
        export "${_glt_assignment?}"
      done
    fi
    "$CLI" "$@" 2>"$stderr_file"
  )
}

# Creates the gitlab-remote repository every test below runs inside, exported
# as GLT_REPO_DIR. Deliberately NOT setup_detect_forge_fixture: that helper
# pushd's the whole test process into the fixture, and these tests instead run
# the CLI in a subshell so a failing assertion can never leave the suite
# standing in a deleted directory.
glt_setup_repo() {
  local remote_url="${1:-https://gitlab.com/acme/widgets.git}"
  GLT_REPO_DIR=$(mktemp -d)
  (
    cd "$GLT_REPO_DIR" || exit 1
    git init >/dev/null 2>&1
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1
    git remote add origin "$remote_url"
    mkdir -p .aimi/tasks
  )
}

glt_teardown_repo() {
  rm -rf "$GLT_REPO_DIR"
  unset GLT_REPO_DIR
}

# Copies aimi-cli.sh, applies one sed mutation to the copy, and prints the
# copy's path. The mutation harness for the two "prove the routing is what
# makes the assertion pass" tests below: an assertion nobody has shown able to
# fail is not evidence.
glt_mutated_cli() {
  local sed_expr="$1"
  local mutant
  mutant=$(mktemp)
  sed "$sed_expr" "$CLI" > "$mutant"
  chmod +x "$mutant"
  printf '%s' "$mutant"
}

# Runs a MUTATED copy of the CLI through the same sandbox/repo/fake-glab the
# real assertions use, so the only difference between the green run and the
# red run is the one routing line the mutation removed.
glt_run_mutated_cli() {
  local mutant="$1" sandbox="$2"
  shift 2
  (
    cd "$GLT_REPO_DIR" || exit 1
    export PATH="$sandbox"
    export GLT_GLAB_LOG="$sandbox/glab.log"
    "$mutant" "$@" 2>/dev/null
  )
}

# ---------------------------------------------------------------------------
# RUNS FIRST, ON PURPOSE: prove the fake glab can turn these tests RED before
# a single routing assertion trusts it. An assertion that passes regardless of
# what the stub returns is not evidence -- that exact defect class is why
# phase 2's machine-account check had to be rebuilt.
# ---------------------------------------------------------------------------
glt_test_fake_glab_can_produce_a_failing_result() {
  echo ""
  echo "=== gitlab review threads: the fake glab CAN turn an assertion red (falsifiability proof, runs first) ==="

  glt_setup_repo

  local sandbox_a sandbox_b out_a out_b id_a id_b would_have_gone_red
  local stderr_file="/tmp/glt_falsifiability_stderr.$$"

  sandbox_a=$(glt_new_sandbox)
  sandbox_b=$(glt_new_sandbox)

  # Same code path, same flags, two DIFFERENT discussion ids. If the emitted
  # thread id did not actually track the stub's payload, these would be equal.
  out_a=$(glt_run_cli "$sandbox_a" "$stderr_file" \
    'GLT_LIST_STDOUT=[{"id":"1111111111111111111111111111111111111111","notes":[]}]' \
    -- forge-pr-review-threads --pr 42)
  out_b=$(glt_run_cli "$sandbox_b" "$stderr_file" \
    'GLT_LIST_STDOUT=[{"id":"2222222222222222222222222222222222222222","notes":[]}]' \
    -- forge-pr-review-threads --pr 42)

  id_a=$(printf '%s' "$out_a" | jq -r '.data.threads[0].id')
  id_b=$(printf '%s' "$out_b" | jq -r '.data.threads[0].id')

  assert_eq "1111111111111111111111111111111111111111" "$id_a" "glt falsifiability: the first payload's discussion id is what comes out"
  assert_eq "2222222222222222222222222222222222222222" "$id_b" "glt falsifiability: the second payload's DIFFERENT id comes out, so output really does track the stub"

  # Stated as a check rather than left as a comment: had id_b been asserted
  # against id_a, assert_eq would have gone red. Written this way so a future
  # edit that makes the stub ignore its own payload fails HERE, loudly,
  # instead of quietly making every assertion below vacuous.
  would_have_gone_red=no
  if [ "$id_b" != "$id_a" ]; then
    would_have_gone_red=yes
  fi
  assert_eq "yes" "$would_have_gone_red" "glt falsifiability: asserting the second id against the first WOULD have gone red -- the stub is not a rubber stamp"

  teardown_forge_cli_sandbox "$sandbox_a"
  teardown_forge_cli_sandbox "$sandbox_b"
  rm -f "$stderr_file"
  glt_teardown_repo
}

# THE ARGV ASSERTION. Asserted from the fake glab's RECORDED ARGV, never from
# the returned list: a fake that served only unresolved discussions would make
# a client-side filter look exactly as correct as a server-side one, so the
# returned list cannot tell the two apart and the argv can.
glt_test_pr_review_threads_asks_glab_for_state_unresolved() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): asks glab for --state unresolved, does not fetch everything and filter locally ==="

  glt_setup_repo

  local sandbox out payload_file argv
  local stderr_file="/tmp/glt_state_unresolved_stderr.$$"
  payload_file=$(mktemp)
  glt_discussion_fixture > "$payload_file"
  sandbox=$(glt_new_sandbox)

  out=$(glt_run_cli "$sandbox" "$stderr_file" "GLT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)
  argv=$(glt_glab_argv "$sandbox")

  # The exact argv, in order -- the subcommand, the iid, glab's own
  # whole-document -F json form, and the server-side resolution filter.
  assert_eq "mr note list 42 -F json --state unresolved" "$argv" "glt argv: the listing call is exactly \`glab mr note list <iid> -F json --state unresolved\`"
  assert_contains "--state unresolved" "$argv" "glt argv: --state unresolved is passed to glab -- the filter is SERVER-side, proven from argv rather than from the returned list"
  assert_eq "1" "$(glt_glab_call_count "$sandbox")" "glt argv: exactly one glab invocation -- no second whole-fetch call to filter from"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '--json')" "glt argv: no gh-style --json field-list selector (glab has none)"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '--state all')" "glt argv: the DEFAULT call never asks for --state all, which is what fetching-everything-then-filtering would have looked like"

  # And the envelope the argv produced.
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "glt listing: status found"
  assert_eq "42" "$(printf '%s' "$out" | jq -r '.data.pr.number')" "glt listing: pr.number is the iid the caller asked for"
  assert_eq "2" "$(printf '%s' "$out" | jq '.data.threads | length')" "glt listing: both discussions become threads"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "glt listing: message null on found"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "glt listing: reason null on found"
  assert_eq "" "$(cat "$stderr_file")" "glt listing: QUIET -- zero stderr output"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

# GitLab calls the unit a DISCUSSION; the contract calls it a THREAD. Pin the
# translation, and pin that the GitLab word never reaches the envelope.
glt_test_pr_review_threads_maps_discussion_vocabulary_to_thread() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): discussion vocabulary becomes thread vocabulary at the adapter boundary ==="

  glt_setup_repo

  local sandbox out payload_file
  local stderr_file="/tmp/glt_vocabulary_stderr.$$"
  payload_file=$(mktemp)
  glt_discussion_fixture > "$payload_file"
  sandbox=$(glt_new_sandbox)

  out=$(glt_run_cli "$sandbox" "$stderr_file" "GLT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)

  # The envelope key is `threads`, and the word `discussion` -- along with
  # every GitLab-native key name -- is nowhere in the emitted JSON.
  assert_eq "true"  "$(printf '%s' "$out" | jq -r '.data | has("threads")')" "glt vocabulary: the envelope key is threads"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data | has("discussions")')" "glt vocabulary: there is no discussions key"
  assert_eq "0" "$(printf '%s' "$out" | grep -c -i 'discussion')" "glt vocabulary: the word discussion does not leak into the normalized envelope anywhere"
  assert_eq "0" "$(printf '%s' "$out" | grep -c 'individual_note\|resolvable\|new_path\|created_at')" "glt vocabulary: no GitLab-native key name survives into the envelope"

  # Per-thread field translation, first (diff-anchored) discussion.
  assert_eq "6a9c1750b37d513a43987b574953fceb50b03ce7" "$(printf '%s' "$out" | jq -r '.data.threads[0].id')" "glt vocabulary: thread id is GitLab's FULL 40-character discussion id, not the 8-char display prefix"
  assert_eq "40" "$(printf '%s' "$out" | jq -r '.data.threads[0].id | length')" "glt vocabulary: and it really is 40 characters long"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.threads[0].isResolved')" "glt vocabulary: isResolved derived from the notes' per-note resolved flags"
  assert_eq "src/main.go" "$(printf '%s' "$out" | jq -r '.data.threads[0].path')" "glt vocabulary: path comes from the anchoring note's diff position"
  assert_eq "17" "$(printf '%s' "$out" | jq -r '.data.threads[0].line')" "glt vocabulary: line comes from position.new_line"
  assert_eq "15" "$(printf '%s' "$out" | jq -r '.data.threads[0].startLine')" "glt vocabulary: startLine comes from position.line_range.start"
  assert_eq "RIGHT" "$(printf '%s' "$out" | jq -r '.data.threads[0].diffSide')" "glt vocabulary: a new_line position is GitHub's RIGHT side"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.totalCount')" "glt vocabulary: notes become comments"
  assert_eq "monalisa" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].author.login')" "glt vocabulary: GitLab's author.username becomes the contract's author.login"
  assert_eq "please rename this" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].body')" "glt vocabulary: note body carried through"
  assert_eq "2026-01-01T10:00:00Z" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].createdAt')" "glt vocabulary: created_at becomes createdAt"
  assert_eq "2026-01-01T10:30:00Z" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].updatedAt')" "glt vocabulary: updated_at becomes updatedAt"
  assert_eq "\"1126\"" "$(printf '%s' "$out" | jq -c '.data.threads[0].comments.nodes[0].id')" "glt vocabulary: GitLab's integer note id is cast to string, so the contract's comment id is one type across forges"

  # Second (general, non-diff) discussion: nothing is invented for it.
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[1].path')" "glt vocabulary: a general discussion has no diff position, so path is null rather than guessed"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[1].line')" "glt vocabulary: and line is null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[1].diffSide')" "glt vocabulary: and diffSide is null"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.threads[1].isResolved')" "glt vocabulary: a discussion with no RESOLVABLE note is not reported resolved"

  # Capability gaps are declared, never left as bare unmarked nulls.
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].isOutdated')" "glt vocabulary: isOutdated is null -- GitLab has no per-discussion outdated flag"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].isCollapsed')" "glt vocabulary: isCollapsed is null -- a GitHub review-UI concept"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.unsupported_fields | index("threads[].isOutdated") != null')" "glt vocabulary: isOutdated's name is recorded in unsupported_fields, per forge-contract.md"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.unsupported_fields | index("threads[].isCollapsed") != null')" "glt vocabulary: isCollapsed's name is recorded too"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.unsupported_fields | index("pr.title") != null')" "glt vocabulary: pr.title is declared unsupported rather than silently null (it would cost a second glab call)"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

glt_test_pr_review_threads_all_flag_asks_for_state_all() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): --all maps to glab's --state all ==="

  glt_setup_repo

  local sandbox out argv
  local stderr_file="/tmp/glt_state_all_stderr.$$"

  sandbox=$(glt_new_sandbox)
  out=$(glt_run_cli "$sandbox" "$stderr_file" 'GLT_LIST_STDOUT=[]' \
    -- forge-pr-review-threads --pr 42 --all)
  argv=$(glt_glab_argv "$sandbox")

  assert_eq "mr note list 42 -F json --state all" "$argv" "glt --all: asks glab for --state all -- still server-side, still one call"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "glt --all: status found"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

# THE DISTINCTION THAT MAKES A CLEAN REVIEW READABLE: zero unresolved threads
# is a `found` result carrying an empty list. not_found means the MERGE
# REQUEST itself could not be located. Conflating them would make a clean
# review look like a broken lookup.
glt_test_pr_review_threads_zero_threads_is_found_with_empty_list() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): zero unresolved discussions is FOUND with an empty list, never not_found ==="

  glt_setup_repo

  local sandbox_empty sandbox_null sandbox_blank sandbox_missing
  local out_empty out_null out_blank out_missing
  local stderr_file="/tmp/glt_empty_stderr.$$"

  # Go marshals an empty slice as [] and a nil slice as null, and a command
  # that printed nothing at all is the same fact again. All three are a clean
  # review, so all three must be `found`.
  sandbox_empty=$(glt_new_sandbox)
  sandbox_null=$(glt_new_sandbox)
  sandbox_blank=$(glt_new_sandbox)
  sandbox_missing=$(glt_new_sandbox)

  out_empty=$(glt_run_cli "$sandbox_empty" "$stderr_file" 'GLT_LIST_STDOUT=[]' \
    -- forge-pr-review-threads --pr 42)
  out_null=$(glt_run_cli "$sandbox_null" "$stderr_file" 'GLT_LIST_STDOUT=null' \
    -- forge-pr-review-threads --pr 42)
  out_blank=$(glt_run_cli "$sandbox_blank" "$stderr_file" 'GLT_LIST_STDOUT=' \
    -- forge-pr-review-threads --pr 42)

  assert_eq "found" "$(printf '%s' "$out_empty" | jq -r '.status')" "glt empty: an empty JSON array is FOUND"
  assert_eq "[]"    "$(printf '%s' "$out_empty" | jq -c '.data.threads')" "glt empty: carrying an empty threads list"
  assert_eq "42"    "$(printf '%s' "$out_empty" | jq -r '.data.pr.number')" "glt empty: and still naming the merge request it looked at"
  assert_eq "found" "$(printf '%s' "$out_null" | jq -r '.status')" "glt empty: a null payload (Go's nil slice) is FOUND too, not an error"
  assert_eq "[]"    "$(printf '%s' "$out_null" | jq -c '.data.threads')" "glt empty: null collapses to an empty list"
  assert_eq "found" "$(printf '%s' "$out_blank" | jq -r '.status')" "glt empty: no output at all is FOUND too"
  assert_eq "[]"    "$(printf '%s' "$out_blank" | jq -c '.data.threads')" "glt empty: and also collapses to an empty list"

  # The contrast that gives the assertion its meaning: a merge request that
  # genuinely does not exist IS not_found, and the two outcomes differ.
  out_missing=$(glt_run_cli "$sandbox_missing" "$stderr_file" \
    'GLT_LIST_FAIL_STDERR=GET https://gitlab.com/api/v4/...: 404 {message: 404 Not found}' \
    -- forge-pr-review-threads --pr 999999)

  assert_eq "not_found" "$(printf '%s' "$out_missing" | jq -r '.status')" "glt empty: a 404 from glab IS not_found -- the merge request itself could not be located"
  assert_eq "null" "$(printf '%s' "$out_missing" | jq -r '.data')" "glt empty: not_found carries no data"
  local differ=no
  if [ "$(printf '%s' "$out_empty" | jq -r '.status')" != "$(printf '%s' "$out_missing" | jq -r '.status')" ]; then
    differ=yes
  fi
  assert_eq "yes" "$differ" "glt empty: 'no threads' and 'no merge request' produce DIFFERENT statuses -- they are not conflated"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_empty"
  teardown_forge_cli_sandbox "$sandbox_null"
  teardown_forge_cli_sandbox "$sandbox_blank"
  teardown_forge_cli_sandbox "$sandbox_missing"
  glt_teardown_repo
}

glt_test_pr_review_threads_glab_failure_is_cli_failed() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): a non-404 glab failure stays error/cli_failed, never a confirmed answer ==="

  glt_setup_repo

  local sandbox out
  local stderr_file="/tmp/glt_list_broken_stderr.$$"

  sandbox=$(glt_new_sandbox)
  out=$(glt_run_cli "$sandbox" "$stderr_file" \
    'GLT_LIST_FAIL_STDERR=Post "https://gitlab.com/api/v4/...": dial tcp: connection refused' \
    -- forge-pr-review-threads --pr 42)

  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glt broken: status error"
  assert_eq "cli_failed" "$(printf '%s' "$out" | jq -r '.reason')" "glt broken: reason cli_failed -- a could-not-attempt failure is never read as not_found"
  assert_contains "glab mr note list exited 1" "$(printf '%s' "$out" | jq -r '.message')" "glt broken: message names the failing glab call and its exit status"
  assert_eq "" "$(cat "$stderr_file")" "glt broken: still QUIET -- a read verb prints nothing"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

glt_test_pr_review_threads_glab_absent_degrades_through_the_shared_gate() {
  echo ""
  echo "=== forge-pr-review-threads (gitlab): glab absent -- same shared _forge_bin_check gate, naming glab not gh ==="

  glt_setup_repo

  local sandbox out
  local stderr_file="/tmp/glt_no_glab_stderr.$$"

  sandbox=$(glt_new_sandbox_without_glab)
  out=$(glt_run_cli "$sandbox" "$stderr_file" -- forge-pr-review-threads --pr 42)

  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glt no-glab: status error"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "glt no-glab: reason cli_missing -- the same enum value the gh path uses"
  assert_contains "glab not found" "$(printf '%s' "$out" | jq -r '.message')" "glt no-glab: the message names glab, not gh"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "glt no-glab: and does NOT name gh -- the wrong binary would send a GitLab user hunting for the wrong install"
  assert_eq "" "$(cat "$stderr_file")" "glt no-glab: QUIET mode -- zero stderr, exactly like the gh path"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

glt_test_resolve_review_thread_via_glab() {
  echo ""
  echo "=== forge-resolve-review-thread (gitlab): resolves via \`glab mr note resolve\` ==="

  glt_setup_repo

  local sandbox out argv
  local stderr_file="/tmp/glt_resolve_ok_stderr.$$"
  local full_id="6a9c1750b37d513a43987b574953fceb50b03ce7"

  sandbox=$(glt_new_sandbox)
  out=$(glt_run_cli "$sandbox" "$stderr_file" -- forge-resolve-review-thread --thread-id "$full_id")
  argv=$(glt_glab_argv "$sandbox")

  assert_eq "mr note resolve $full_id" "$argv" "glt resolve: the call is exactly \`glab mr note resolve <discussion-id>\`, with the merge request auto-detected from the branch"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "glt resolve: status found"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.resolved')" "glt resolve: resolved true"
  assert_eq "$full_id" "$(printf '%s' "$out" | jq -r '.data.thread.id')" "glt resolve: the thread object echoes the id that was resolved"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.thread.isResolved')" "glt resolve: thread.isResolved true"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.thread.path')" "glt resolve: path is null -- glab's resolve prints no diff position"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.unsupported_fields | index("thread.path") != null')" "glt resolve: and that null is DECLARED in unsupported_fields, never left bare"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "glt resolve: message null"
  assert_eq "" "$(cat "$stderr_file")" "glt resolve: nothing printed on the success path"
  assert_eq "0" "$(printf '%s' "$out" | grep -c -i 'discussion')" "glt resolve: the word discussion does not leak into the normalized envelope"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

# The verb RESOLVES and does NOT post a reply -- phase 2's handoff records
# that decision, and `glab mr note resolve` behaves the same way, so the two
# agree without special-casing. Proven from argv: one invocation, and it is
# not a note-creating one.
glt_test_resolve_review_thread_posts_no_reply() {
  echo ""
  echo "=== forge-resolve-review-thread (gitlab): resolves the thread and posts NO reply comment ==="

  glt_setup_repo

  local sandbox argv
  local stderr_file="/tmp/glt_no_reply_stderr.$$"

  sandbox=$(glt_new_sandbox)
  glt_run_cli "$sandbox" "$stderr_file" -- forge-resolve-review-thread --thread-id 6a9c1750b37d513a43987b574953fceb50b03ce7 >/dev/null
  argv=$(glt_glab_argv "$sandbox")

  assert_eq "1" "$(glt_glab_call_count "$sandbox")" "glt no-reply: exactly ONE glab invocation -- no second call could have posted anything"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c 'note create')" "glt no-reply: no \`mr note create\` anywhere in the recorded argv"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c 'mr comment')" "glt no-reply: no \`mr comment\` either"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '--message')" "glt no-reply: no --message flag -- nothing carried comment text"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '-m ')" "glt no-reply: nor its short form"
  assert_contains "note resolve" "$argv" "glt no-reply: the one call really is the resolve subcommand"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

glt_test_resolve_review_thread_confirmed_missing_is_found_false() {
  echo ""
  echo "=== forge-resolve-review-thread (gitlab): a 404 is a CONFIRMED negative (found/resolved:false), a broken call is not ==="

  glt_setup_repo

  local sandbox_404 sandbox_broken out_404 out_broken exit_404 exit_broken
  local stderr_404="/tmp/glt_resolve_404_stderr.$$"
  local stderr_broken="/tmp/glt_resolve_broken_stderr.$$"

  sandbox_404=$(glt_new_sandbox)
  sandbox_broken=$(glt_new_sandbox)

  out_404=$(glt_run_cli "$sandbox_404" "$stderr_404" \
    'GLT_RESOLVE_FAIL_STDERR=GET https://gitlab.com/api/v4/...: 404 {message: 404 Discussion Not Found}' \
    -- forge-resolve-review-thread --thread-id deadbeefdeadbeefdeadbeefdeadbeefdeadbeef) && exit_404=0 || exit_404=$?

  assert_exit_code "0" "$exit_404" "glt resolve-404: exit 0 -- the call ran and returned a definitive answer"
  assert_eq "found" "$(printf '%s' "$out_404" | jq -r '.status')" "glt resolve-404: status found, matching the github adapter's confirmed-invalid-id result"
  assert_eq "false" "$(printf '%s' "$out_404" | jq -r '.data.resolved')" "glt resolve-404: resolved false"
  assert_eq "null" "$(printf '%s' "$out_404" | jq -r '.data.thread')" "glt resolve-404: thread null"
  assert_eq "null" "$(printf '%s' "$out_404" | jq -r '.reason')" "glt resolve-404: no reason -- a confirmed answer is not a degradation"
  assert_eq "" "$(cat "$stderr_404")" "glt resolve-404: nothing printed"

  # The contrast: glab could not even attempt the resolve. That must NOT be
  # read as "the thread does not exist" -- it is the dangerous direction.
  out_broken=$(glt_run_cli "$sandbox_broken" "$stderr_broken" \
    'GLT_RESOLVE_FAIL_STDERR=no open merge request available for branch main' \
    -- forge-resolve-review-thread --thread-id deadbeefdeadbeefdeadbeefdeadbeefdeadbeef) && exit_broken=0 || exit_broken=$?

  assert_exit_code "1" "$exit_broken" "glt resolve-broken: exits non-zero (write verb, no fallback path)"
  assert_eq "error" "$(printf '%s' "$out_broken" | jq -r '.status')" "glt resolve-broken: status error, NOT a found/resolved:false that would claim the thread was checked"
  assert_eq "cli_failed" "$(printf '%s' "$out_broken" | jq -r '.reason')" "glt resolve-broken: reason cli_failed"
  assert_stderr_contains "resolve it manually" "$(cat "$stderr_broken")" "glt resolve-broken: the mandatory manual instruction is printed"

  rm -f "$stderr_404" "$stderr_broken"
  teardown_forge_cli_sandbox "$sandbox_404"
  teardown_forge_cli_sandbox "$sandbox_broken"
  glt_teardown_repo
}

glt_test_resolve_review_thread_glab_absent_mandatory_print() {
  echo ""
  echo "=== forge-resolve-review-thread (gitlab): glab absent -- MANDATORY-PRINT degrade naming glab, exits non-zero ==="

  glt_setup_repo

  local sandbox out exit_code
  local stderr_file="/tmp/glt_resolve_no_glab_stderr.$$"

  sandbox=$(glt_new_sandbox_without_glab)
  out=$(glt_run_cli "$sandbox" "$stderr_file" \
    -- forge-resolve-review-thread --thread-id 6a9c1750b37d513a43987b574953fceb50b03ce7) && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "glt resolve no-glab: exits non-zero, exactly like the gh-absent path"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "glt resolve no-glab: status error"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "glt resolve no-glab: reason cli_missing -- the same shared gate, the same enum value"
  assert_contains "glab not found" "$(printf '%s' "$out" | jq -r '.message')" "glt resolve no-glab: the message names glab"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "glt resolve no-glab: and does NOT name gh"
  assert_stderr_contains "resolve it manually" "$(cat "$stderr_file")" "glt resolve no-glab: manual instruction printed"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

# THE ROUND TRIP. Whatever identifier the listing verb emits must be accepted
# VERBATIM by the resolve verb. Emitting a prefix and resolving by full id (or
# the reverse) would work by luck against a fake and fail against the real
# service, so the id is never retyped here -- it is read out of the listing's
# own output and fed straight back in.
glt_test_thread_id_round_trips_from_listing_to_resolve() {
  echo ""
  echo "=== gitlab review threads: the id the listing emits is accepted VERBATIM by the resolve call (round trip) ==="

  glt_setup_repo

  local sandbox_list sandbox_resolve list_out resolve_out emitted_id resolve_argv payload_file
  local stderr_file="/tmp/glt_round_trip_stderr.$$"
  payload_file=$(mktemp)
  glt_discussion_fixture > "$payload_file"
  sandbox_list=$(glt_new_sandbox)
  sandbox_resolve=$(glt_new_sandbox)

  list_out=$(glt_run_cli "$sandbox_list" "$stderr_file" "GLT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)
  emitted_id=$(printf '%s' "$list_out" | jq -r '.data.threads[0].id')

  # Deliberately NOT a literal -- the value comes from the listing verb's own
  # output, so a change to what the listing emits is felt here immediately.
  resolve_out=$(glt_run_cli "$sandbox_resolve" "$stderr_file" \
    -- forge-resolve-review-thread --thread-id "$emitted_id")
  resolve_argv=$(glt_glab_argv "$sandbox_resolve")

  assert_eq "mr note resolve $emitted_id" "$resolve_argv" "glt round trip: the emitted id reaches glab's argv byte for byte, unshortened and unreformatted"
  assert_eq "40" "$(printf '%s' "$emitted_id" | wc -c | tr -d ' ')" "glt round trip: 40 characters plus no trailing newline -- the FULL discussion id, not glab's 8-character display prefix"
  assert_eq "found" "$(printf '%s' "$resolve_out" | jq -r '.status')" "glt round trip: the resolve call succeeded on that id"
  assert_eq "$emitted_id" "$(printf '%s' "$resolve_out" | jq -r '.data.thread.id')" "glt round trip: and the resolve result reports the same id back"

  # The failure this test exists to catch, stated as a check: had the listing
  # emitted a truncated prefix, the argv assertion above would have compared
  # against that prefix and still passed -- so pin the length independently
  # against the fixture's own full id.
  assert_eq "6a9c1750b37d513a43987b574953fceb50b03ce7" "$emitted_id" "glt round trip: the emitted id is the fixture's full discussion id, so the round trip is not merely self-consistent"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_list"
  teardown_forge_cli_sandbox "$sandbox_resolve"
  glt_teardown_repo
}

# The upstream-status disclosure required by this story, asserted against the
# source text so it cannot be deleted silently.
glt_test_resolve_records_glab_experimental_status() {
  echo ""
  echo "=== forge-resolve-review-thread (gitlab): the header discloses that glab marks \`mr note resolve\` EXPERIMENTAL ==="

  local resolve_src
  resolve_src=$(sed -n '/^# gitlab adapter for forge-resolve-review-thread/,/^_forge_resolve_review_thread_gitlab()/p' "$CLI")

  assert_contains "EXPERIMENTAL" "$resolve_src" "glt disclosure: the header says EXPERIMENTAL in as many words"
  assert_contains "docs/source/mr/note/resolve.md" "$resolve_src" "glt disclosure: and cites glab's own documentation page for it"
  assert_contains "might be unstable" "$resolve_src" "glt disclosure: quoting upstream's own 'might be unstable or removed at any time'"
  assert_contains "not a reason to skip" "$resolve_src" "glt disclosure: recorded as a disclosure to the caller, not as grounds for leaving GitLab unrouted"
}

# ---------------------------------------------------------------------------
# MUTATION TESTS. Each unroutes ONE verb in a COPY of the CLI -- by disabling
# that verb's own `forge == gitlab` gate and nothing else -- and confirms a
# SPECIFIC NAMED assertion above goes red, so the assertions are known to be
# load-bearing rather than merely green.
#
# The gate CONDITION is what is mutated, not the adapter call below it:
# deleting the call alone would leave the gate's trailing `return 0` in place,
# and the verb would emit nothing at all rather than falling through. Changing
# the condition makes the verb behave exactly as it did before this story --
# the adapterless `no_adapter` envelope -- which is the honest counterfactual.
# The substitution is scoped to each verb's own function body by a sed address
# range, so unrouting one verb provably leaves the other routed.
# ---------------------------------------------------------------------------
glt_test_mutation_unrouting_the_listing_verb_turns_an_assertion_red() {
  echo ""
  echo "=== mutation: unrouting forge-pr-review-threads makes the named --state-unresolved assertion go red ==="

  glt_setup_repo

  local sandbox mutant argv_green argv_red status_red reason_red payload_file
  local stderr_file="/tmp/glt_mutation_list_stderr.$$"
  payload_file=$(mktemp)
  glt_discussion_fixture > "$payload_file"

  # Green baseline through the real CLI, same fixture, same sandbox shape.
  sandbox=$(glt_new_sandbox)
  glt_run_cli "$sandbox" "$stderr_file" "GLT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42 >/dev/null
  argv_green=$(glt_glab_argv "$sandbox")
  assert_eq "mr note list 42 -F json --state unresolved" "$argv_green" "glt mutation (listing): the UNMUTATED CLI passes --state unresolved -- the assertion being mutated"

  # The mutation: disable the gitlab gate inside _forge_pr_review_threads
  # ONLY. The verb then falls through to the adapterless branch and never
  # calls glab at all.
  mutant=$(glt_mutated_cli '/^_forge_pr_review_threads() {$/,/^}$/ s/^  if \[ "\$forge" = "gitlab" \]; then$/  if [ "$forge" = "gitlab-unrouted-by-mutation" ]; then/')
  assert_eq "1" "$(diff "$CLI" "$mutant" | grep -c '^> ')" "glt mutation (listing): the mutation changed EXACTLY one line -- a broad edit would not localize the failure"
  rm -f "$sandbox/glab.log"
  glt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 >/dev/null || true
  argv_red=$(glt_glab_argv "$sandbox")

  assert_eq "" "$argv_red" "glt mutation (listing): with the gitlab gate disabled, glab is never invoked -- so \"the listing call is exactly glab mr note list <iid> -F json --state unresolved\" goes RED"
  local moved=no
  if [ "$argv_red" != "$argv_green" ]; then moved=yes; fi
  assert_eq "yes" "$moved" "glt mutation (listing): the verdict MOVED between the real and the mutated CLI, so that assertion is load-bearing, not decorative"

  # And the envelope regresses to the adapterless answer, naming the second
  # assertion this mutation kills.
  rm -f "$sandbox/glab.log"
  local mutant_out
  mutant_out=$(glt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 || true)
  status_red=$(printf '%s' "$mutant_out" | jq -r '.status')
  reason_red=$(printf '%s' "$mutant_out" | jq -r '.reason')
  assert_eq "error" "$status_red" "glt mutation (listing): the mutated CLI answers error, so \"glt listing: status found\" goes RED too"
  assert_eq "no_adapter" "$reason_red" "glt mutation (listing): with reason no_adapter -- exactly the pre-story behavior this routing replaced"

  # And the OTHER verb is untouched by this mutation, which is what makes the
  # two mutation tests independent evidence rather than one fact counted twice.
  rm -f "$sandbox/glab.log"
  glt_run_mutated_cli "$mutant" "$sandbox" forge-resolve-review-thread --thread-id 6a9c1750b37d513a43987b574953fceb50b03ce7 >/dev/null || true
  assert_contains "note resolve" "$(glt_glab_argv "$sandbox")" "glt mutation (listing): the RESOLVE verb still reaches glab under this mutation -- the unrouting is scoped to one verb"

  rm -f "$mutant" "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

glt_test_mutation_unrouting_the_resolve_verb_turns_an_assertion_red() {
  echo ""
  echo "=== mutation: unrouting forge-resolve-review-thread makes the named resolve-argv assertion go red ==="

  glt_setup_repo

  local sandbox mutant argv_green argv_red mutant_out
  local stderr_file="/tmp/glt_mutation_resolve_stderr.$$"
  local full_id="6a9c1750b37d513a43987b574953fceb50b03ce7"

  sandbox=$(glt_new_sandbox)
  glt_run_cli "$sandbox" "$stderr_file" -- forge-resolve-review-thread --thread-id "$full_id" >/dev/null
  argv_green=$(glt_glab_argv "$sandbox")
  assert_eq "mr note resolve $full_id" "$argv_green" "glt mutation (resolve): the UNMUTATED CLI calls glab mr note resolve -- the assertion being mutated"

  mutant=$(glt_mutated_cli '/^_forge_resolve_review_thread() {$/,/^}$/ s/^  if \[ "\$forge" = "gitlab" \]; then$/  if [ "$forge" = "gitlab-unrouted-by-mutation" ]; then/')
  assert_eq "1" "$(diff "$CLI" "$mutant" | grep -c '^> ')" "glt mutation (resolve): the mutation changed EXACTLY one line, scoped to this verb's own function body"
  rm -f "$sandbox/glab.log"
  mutant_out=$(glt_run_mutated_cli "$mutant" "$sandbox" forge-resolve-review-thread --thread-id "$full_id" || true)
  argv_red=$(glt_glab_argv "$sandbox")

  assert_eq "" "$argv_red" "glt mutation (resolve): with the gitlab gate disabled, glab is never invoked -- so \"the call is exactly glab mr note resolve <discussion-id>\" goes RED"
  local moved=no
  if [ "$argv_red" != "$argv_green" ]; then moved=yes; fi
  assert_eq "yes" "$moved" "glt mutation (resolve): the verdict MOVED between the real and the mutated CLI, so that assertion is load-bearing"
  assert_eq "error" "$(printf '%s' "$mutant_out" | jq -r '.status')" "glt mutation (resolve): the mutated CLI answers error, so \"glt resolve: resolved true\" goes RED too"
  assert_eq "no_adapter" "$(printf '%s' "$mutant_out" | jq -r '.reason')" "glt mutation (resolve): with reason no_adapter -- the pre-story behavior this routing replaced"

  # The mirror image of the listing mutation's own cross-check.
  rm -f "$sandbox/glab.log"
  glt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 >/dev/null || true
  assert_contains "note list" "$(glt_glab_argv "$sandbox")" "glt mutation (resolve): the LISTING verb still reaches glab under this mutation -- the unrouting is scoped to one verb"

  rm -f "$mutant" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  glt_teardown_repo
}

# ============================================================================
# Gitea Review-Thread Routing Tests (phase 4 outline:04)
# ============================================================================
# forge-pr-review-threads and forge-resolve-review-thread routed to
# `tea pulls review-comments` / `tea pulls resolve`.
#
# NAMING: every function and control variable this story adds is prefixed
# `gtt_`/`GTT_` (GiTea Threads), INCLUDING the test functions themselves.
# That is an orchestration constraint, not a style preference: sibling
# stories in this same phase edit this same file for the read verbs and the
# write verbs, on branches none of us can see, and bash silently keeps the
# LAST definition of a duplicated function name -- so individually-green
# branches merge into a red one. The phase-2 founding incident: two wave-1
# stories both defined source_forge_account_functions and six assertions
# failed with exit 127 only on the merge. `gtt_` is the prefix the phase's
# own naming table reserved for this story (see the Gitea PR-field Mapping
# section header above), verified disjoint from `gla_`, `glr_`, `glt_`,
# `glw_`, `gtm_` and `run_`, and this section installs its OWN fake tea
# rather than extending `gtm_setup_fake_tea_fixture`.
#
# VERIFICATION CEILING. `tea` is genuinely NOT INSTALLED on this machine --
# which is also what makes the tea-absent degrade test below the ONE
# assertion in this section measured against reality rather than against a
# stub. Everything else is measured against `gtt_write_fake_tea`, whose
# payloads are modelled on `gitea/tea` `main` source read on 2026-08-06 and
# never on a captured real-binary response. These tests prove WHICH ARGV the
# adapter emits and HOW it parses a fixture; they can never prove what real
# tea does with either. The argv half is sound against a fake -- a wrong flag
# is visible in the log. The parsing half is not: the stub emits whatever the
# author believed, so a wrong KEY NAME passes green on both sides.

# Writes an argv-recording fake `tea` into an existing forge CLI sandbox and
# prints nothing. Every invocation's argv is appended to <sandbox>/tea.log,
# one line per call, so an assertion can prove WHICH flags were passed rather
# than merely that a call happened -- load-bearing here, because tea has no
# server-side resolution filter and the returned list therefore cannot tell a
# local filter from a server-side one. Only the argv can.
#
# Failures are modelled on tea's uniform failure shape (main.go:18-30): the
# message on stderr, exit 1, no distinct not-found code.
#
# Driven entirely by GTT_* environment variables, all optional:
#   GTT_LIST_PAYLOAD_FILE   file whose contents are `pulls review-comments`
#                           stdout
#   GTT_LIST_STDOUT         literal `pulls review-comments` stdout (used when
#                           no file is given)
#   GTT_LIST_FAIL_STDERR    when set, `pulls review-comments` writes it to
#                           stderr and exits 1 instead of printing anything
#   GTT_RESOLVE_FAIL_STDERR same, for `pulls resolve`
gtt_write_fake_tea() {
  local sandbox="$1"
  cat > "$sandbox/tea" << 'GTT_FAKE_TEA'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GTT_TEA_LOG"
case "$1 $2" in
  "pulls review-comments")
    if [ -n "${GTT_LIST_FAIL_STDERR:-}" ]; then
      printf '%s' "$GTT_LIST_FAIL_STDERR" >&2
      exit 1
    fi
    if [ -n "${GTT_LIST_PAYLOAD_FILE:-}" ]; then
      cat "$GTT_LIST_PAYLOAD_FILE"
    else
      printf '%s' "${GTT_LIST_STDOUT-[]}"
    fi
    exit 0
    ;;
  "pulls resolve")
    if [ -n "${GTT_RESOLVE_FAIL_STDERR:-}" ]; then
      printf '%s' "$GTT_RESOLVE_FAIL_STDERR" >&2
      exit 1
    fi
    # tea reports success with a sentence on stdout and no JSON at all
    # (modules/task/pull_review_comment.go:55).
    echo "Comment $3 resolved"
    exit 0
    ;;
esac
echo "Error: unhandled invocation: $*" >&2
exit 1
GTT_FAKE_TEA
  chmod +x "$sandbox/tea"
}

# The recorded argv log, or the empty string when tea was never invoked.
gtt_tea_argv() {
  cat "${1}/tea.log" 2>/dev/null || true
}

# How many times the fake tea was invoked. Load-bearing for the "resolves and
# does NOT post a reply" proof: the count must be exactly one.
gtt_tea_call_count() {
  local log="${1}/tea.log" count
  if [ ! -f "$log" ]; then
    printf '0'
    return 0
  fi
  count=$(grep -c '' "$log" 2>/dev/null) || count=0
  printf '%s' "$count"
}

# One realistic `tea pulls review-comments <index> -f <csv> -o json` document.
# Four properties are load-bearing and must not be "tidied" away:
#   - EVERY value is a JSON STRING, including `line`. That is not sloppiness:
#     tea's LIST output path marshals a map[string]string
#     (modules/print/table.go:187-208), so a fixture with a numeric `line`
#     would let a missing coercion pass green.
#   - The second row's `resolver` is a USERNAME and the other two are EMPTY.
#     tea exposes no resolved boolean at all, and there is no server-side
#     state filter to ask, so both the local filter and the isResolved
#     derivation are read off this one field. A fixture carrying only
#     unresolved rows would make a broken filter pass -- the mix is what makes
#     the test able to fail.
#   - Rows one and three share `src/main.go`. Grouping by path would collapse
#     them into one thread, so the three-thread assertion catches an invented
#     grouping the forge does not have.
#   - `url` is populated on every row: it is SUPPORTED on gitea, unlike on
#     GitLab, and the unsupported_fields assertion below depends on there
#     being a real value to compare against.
gtt_review_comment_fixture() {
  printf '%s' '[
    {"id": "1126", "path": "src/main.go", "line": "17",
     "body": "please rename this", "reviewer": "monalisa", "resolver": "",
     "created": "2026-01-01T10:00:00Z", "updated": "2026-01-01T10:30:00Z",
     "url": "https://gitea.com/acme/widgets/pulls/42/files#issuecomment-1126"},
    {"id": "1127", "path": "src/util.go", "line": "3",
     "body": "already handled", "reviewer": "octocat", "resolver": "hubot",
     "created": "2026-01-02T10:00:00Z", "updated": "2026-01-02T11:00:00Z",
     "url": "https://gitea.com/acme/widgets/pulls/42/files#issuecomment-1127"},
    {"id": "1128", "path": "src/main.go", "line": "42",
     "body": "and one more on the same file", "reviewer": "monalisa", "resolver": "",
     "created": "2026-01-03T10:00:00Z", "updated": "2026-01-03T10:00:00Z",
     "url": "https://gitea.com/acme/widgets/pulls/42/files#issuecomment-1128"}
  ]'
}

# A hermetic PATH sandbox with the argv-recording fake tea installed in it.
# Prints the sandbox path, so it is safe inside $(...) -- which is why the
# sandbox is created HERE and not inside the runner below: the runner is
# always called in a command substitution, and a value written from inside one
# dies with that subshell.
gtt_new_sandbox() {
  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  gtt_write_fake_tea "$sandbox"
  printf '%s' "$sandbox"
}

# The same sandbox WITHOUT the fake tea. This is the one fixture in this
# section that is not a simulation: setup_forge_cli_sandbox's allowlist has no
# tea entry, AND tea is genuinely not installed anywhere on this machine, so
# `command -v tea` fails inside it for the real reason rather than a staged
# one.
gtt_new_sandbox_without_tea() {
  setup_forge_cli_sandbox
}

# Runs one aimi-cli.sh invocation inside the throwaway gitea-remote
# repository, under <sandbox> as the entire PATH. Prints the command's stdout;
# its stderr goes to <stderr-file>. GTT_TEA_LOG is pointed at
# <sandbox>/tea.log so gtt_tea_argv can read the recorded argv afterwards.
#
# Usage: gtt_run_cli <sandbox> <stderr-file> [ENV=VAL ...] -- <args...>
gtt_run_cli() {
  local sandbox="$1" stderr_file="$2"
  shift 2

  local assignments=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    assignments+=("$1")
    shift
  done
  [ "${1:-}" = "--" ] && shift

  (
    cd "$GTT_REPO_DIR" || exit 1
    export PATH="$sandbox"
    export GTT_TEA_LOG="$sandbox/tea.log"
    if [ "${#assignments[@]}" -gt 0 ]; then
      for _gtt_assignment in "${assignments[@]}"; do
        export "${_gtt_assignment?}"
      done
    fi
    "$CLI" "$@" 2>"$stderr_file"
  )
}

# Creates the gitea-remote repository every test below runs inside, exported
# as GTT_REPO_DIR. Deliberately NOT setup_detect_forge_fixture: that helper
# pushd's the whole test process into the fixture, and these tests instead run
# the CLI in a subshell so a failing assertion can never leave the suite
# standing in a deleted directory.
gtt_setup_repo() {
  local remote_url="${1:-https://gitea.com/acme/widgets.git}"
  GTT_REPO_DIR=$(mktemp -d)
  (
    cd "$GTT_REPO_DIR" || exit 1
    git init >/dev/null 2>&1
    git checkout -b main >/dev/null 2>&1
    echo "init" > README.md
    git add README.md
    git commit -m "Initial commit" >/dev/null 2>&1
    git remote add origin "$remote_url"
    mkdir -p .aimi/tasks
  )
}

# RESTORES nothing and unsets only GTT_REPO_DIR: this section never sets
# AIMI_CONFIG_DIR, and unsetting that here would hand the rest of part 4 back
# to the real ~/.config/aimi.
gtt_teardown_repo() {
  rm -rf "$GTT_REPO_DIR"
  unset GTT_REPO_DIR
}

# Copies aimi-cli.sh, applies one sed mutation to the copy, and prints the
# copy's path. The mutation harness for the two "prove the routing is what
# makes the assertion pass" tests at the end of this section.
gtt_mutated_cli() {
  local sed_expr="$1"
  local mutant
  mutant=$(mktemp)
  sed "$sed_expr" "$CLI" > "$mutant"
  chmod +x "$mutant"
  printf '%s' "$mutant"
}

# Runs a MUTATED copy of the CLI through the same sandbox/repo/fake-tea the
# real assertions use, so the only difference between the green run and the
# red run is the one routing line the mutation removed.
gtt_run_mutated_cli() {
  local mutant="$1" sandbox="$2"
  shift 2
  (
    cd "$GTT_REPO_DIR" || exit 1
    export PATH="$sandbox"
    export GTT_TEA_LOG="$sandbox/tea.log"
    "$mutant" "$@" 2>/dev/null
  )
}

# COUNTING FORM, never `grep -v ... | grep -q ...` inside an `if`. Under
# `set -o pipefail` the short-circuiting form reports ABSENT for a file that
# does contain the pattern, which is a fail-OPEN guard -- the class outline:05
# is removing seven of. This helper returns a number for assert_eq to compare,
# so a broken invocation shows up as a wrong count rather than as a silent
# pass. Comment lines are NOT stripped: several of the strings this story
# asserts on live in comments on purpose.
gtt_count_matches() {
  local file="$1" pattern="$2" count
  count=$(grep -cE -- "$pattern" "$file" 2>/dev/null) || count=0
  printf '%s' "$count"
}

# The same counting discipline for a needle that is easier to state as a
# FIXED string than as a regex -- notably the thread-id guard's own character
# class, which is nearly all metacharacters.
gtt_count_fixed() {
  local file="$1" needle="$2" count
  count=$(grep -cF -- "$needle" "$file" 2>/dev/null) || count=0
  printf '%s' "$count"
}

# Same counting discipline, restricted to ONE function body extracted from
# aimi-cli.sh -- so an assertion about what a function does cannot be
# satisfied (or broken) by the prose in the comment block above it.
gtt_count_matches_in_function() {
  local fn="$1" pattern="$2" body count
  body=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$CLI")
  count=$(printf '%s\n' "$body" | grep -cE -- "$pattern") || count=0
  printf '%s' "$count"
}

# Function-scoped counting over EXECUTABLE lines only -- comment lines
# dropped first. The token assertions need this: both gitea arms carry a
# comment saying they deliberately assign no GH_TOKEN, and a counter that
# could not tell that comment from an actual assignment would make the
# property untestable.
#
# This is the counting form AC-32 endorses -- `count=$(grep -v ... | grep -cE
# ...) || count=0` compared with assert_eq -- and NOT the `grep -v ... |
# grep -q ...`-inside-an-`if` shape outline:05 is removing, which under
# `set -o pipefail` reports ABSENT for a file that contains the pattern.
gtt_count_in_function_code() {
  local fn="$1" pattern="$2" body count
  body=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$CLI")
  count=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*#' | grep -cE -- "$pattern") || count=0
  printf '%s' "$count"
}

# The ERE for "this line assigns or exports one of the four credential
# variables tea would read". Named once so the assertion and its control ask
# literally the same question.
GTT_TOKEN_ASSIGNMENT_RE='(^|[^A-Za-z0-9_])(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)=|export[[:space:]]+(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)'

# Function-scoped counting for a FIXED needle. Same reason gtt_count_fixed
# exists: the thread-id guard is nearly all regex metacharacters, and it lives
# in a function whose header comment also names it -- so the count has to be
# taken over the body, not over the file.
gtt_count_fixed_in_function() {
  local fn="$1" needle="$2" body count
  body=$(sed -n "/^${fn}() {\$/,/^}\$/p" "$CLI")
  count=$(printf '%s\n' "$body" | grep -cF -- "$needle") || count=0
  printf '%s' "$count"
}

# Counts assert_* calls in <file> whose TRAILING MESSAGE ARGUMENT pairs a
# forge word (gitea/codeberg) with a no-adapter claim. The message is the last
# double-quoted string on the line, which is this suite's universal assertion
# shape.
#
# WHY A MESSAGE-SCOPED COUNT RATHER THAN A LINE-SCOPED ONE: a line like
# `assert_contains "no adapter for forge \"gitea\"" "$msg" "..."` asserts on
# the CLI's own emitted text for a verb another wave story owns, and is
# correct until that story routes it. What this invariant is about is the
# suite's own PROSE claiming gitea has no adapter -- which is now false for
# these two verbs and will be false for the rest as the wave lands.
gtt_count_stale_no_adapter_messages() {
  awk '
    {
      line = $0
      sub(/[[:space:]]+$/, "", line)
      if (line !~ /assert_[a-z_]+[[:space:]]/) next
      if (match(line, /"[^"]*"$/) == 0) next
      msg = tolower(substr(line, RSTART + 1, RLENGTH - 2))
      if ((index(msg, "gitea") || index(msg, "codeberg")) \
          && (index(msg, "no adapter") || index(msg, "no_adapter"))) n++
    }
    END { print n + 0 }
  ' "$1"
}

# ---------------------------------------------------------------------------
# RUNS FIRST, ON PURPOSE: prove the fake tea can turn these tests RED before a
# single routing assertion trusts it. An assertion that passes regardless of
# what the stub returns is not evidence -- that exact defect class is why
# phase 2's machine-account check had to be rebuilt, and it is the convention
# every phase-3 and phase-4 stub section here opens with.
# ---------------------------------------------------------------------------
gtt_test_fake_tea_can_produce_a_failing_result() {
  echo ""
  echo "=== gitea review threads: the fake tea CAN turn an assertion red (falsifiability proof, runs first) ==="

  gtt_setup_repo

  local sandbox_a sandbox_b out_a out_b id_a id_b would_have_gone_red
  local stderr_file="/tmp/gtt_falsifiability_stderr.$$"

  sandbox_a=$(gtt_new_sandbox)
  sandbox_b=$(gtt_new_sandbox)

  # Same code path, same flags, two DIFFERENT comment ids. If the emitted
  # thread id did not actually track the stub's payload, these would be equal.
  out_a=$(gtt_run_cli "$sandbox_a" "$stderr_file" \
    'GTT_LIST_STDOUT=[{"id":"1111","path":"a.go","line":"1","body":"b","reviewer":"r","resolver":"","created":"c","updated":"u","url":"h"}]' \
    -- forge-pr-review-threads --pr 42)
  out_b=$(gtt_run_cli "$sandbox_b" "$stderr_file" \
    'GTT_LIST_STDOUT=[{"id":"2222","path":"a.go","line":"1","body":"b","reviewer":"r","resolver":"","created":"c","updated":"u","url":"h"}]' \
    -- forge-pr-review-threads --pr 42)

  id_a=$(printf '%s' "$out_a" | jq -r '.data.threads[0].id')
  id_b=$(printf '%s' "$out_b" | jq -r '.data.threads[0].id')

  assert_eq "1111" "$id_a" "gtt falsifiability: the first payload's comment id is what comes out"
  assert_eq "2222" "$id_b" "gtt falsifiability: the second payload's DIFFERENT id comes out, so output really does track the stub"

  # Stated as a check rather than left as a comment: had id_b been asserted
  # against id_a, assert_eq would have gone red. Written this way so a future
  # edit that makes the stub ignore its own payload fails HERE, loudly,
  # instead of quietly making every assertion below vacuous.
  would_have_gone_red=no
  if [ "$id_b" != "$id_a" ]; then
    would_have_gone_red=yes
  fi
  assert_eq "yes" "$would_have_gone_red" "gtt falsifiability: asserting the second id against the first WOULD have gone red -- the stub is not a rubber stamp"

  teardown_forge_cli_sandbox "$sandbox_a"
  teardown_forge_cli_sandbox "$sandbox_b"
  rm -f "$stderr_file"
  gtt_teardown_repo
}

# THE ARGV ASSERTION. tea's field selector is `-f` (its own --fields,
# cmd/flags/generic.go:157) and its output selector is `-o json`. A gh-style
# `--json <field-list>` does not exist on tea at all, and copying gh's shape
# here is the mistake that would survive every envelope assertion in this
# section -- the emitted document would be identical, because the stub answers
# regardless. Only the recorded argv can catch it.
gtt_test_pr_review_threads_argv_is_teas_own_field_selector() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): the call is \`tea pulls review-comments <index> -f <csv> -o json\` ==="

  gtt_setup_repo

  local sandbox out payload_file argv
  local stderr_file="/tmp/gtt_argv_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"
  sandbox=$(gtt_new_sandbox)

  # --owner/--repo are passed deliberately: tea addresses the repository
  # through the cwd remote and has no owner/repo pair, so the gitea arm must
  # return BEFORE the gh-specific owner/repo resolution block and neither
  # value may reach tea's argv.
  out=$(gtt_run_cli "$sandbox" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42 --owner acme --repo widgets)
  argv=$(gtt_tea_argv "$sandbox")

  assert_eq "pulls review-comments 42 -f id,path,line,body,reviewer,resolver,created,updated,url -o json" "$argv" "gtt argv: the listing call is exactly \`tea pulls review-comments <index> -f <csv> -o json\`"
  assert_eq "1" "$(gtt_tea_call_count "$sandbox")" "gtt argv: exactly one tea invocation -- no second call"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '--json')" "gtt argv: no gh-style --json field-list selector -- tea has none, it has -f"
  assert_eq "1" "$(printf '%s\n' "$argv" | grep -cE -- '(^| )-f( |$)')" "gtt argv: the field selector really is tea's own -f"
  assert_eq "1" "$(printf '%s\n' "$argv" | grep -cE -- '(^| )-o json( |$)')" "gtt argv: and the output flag is -o json"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c -- '--state')" "gtt argv: no --state -- tea's review-comments has no server-side resolution filter to pass one to"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -cE -- '(^| )-s( |$)')" "gtt argv: nor its short form"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c 'acme')" "gtt argv: --owner never reaches tea -- the gitea arm returns before the gh-specific owner/repo resolution"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c 'widgets')" "gtt argv: and neither does --repo"

  # And the envelope the argv produced.
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gtt listing: status found"
  assert_eq "42" "$(printf '%s' "$out" | jq -r '.data.pr.number')" "gtt listing: pr.number is the index the caller asked for"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "gtt listing: message null on found"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "gtt listing: reason null on found"
  assert_eq "" "$(cat "$stderr_file")" "gtt listing: QUIET -- zero stderr output"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# THE FILTER IS LOCAL, AND THAT IS THE OPPOSITE OF THE GITLAB ARM. `tea pulls
# review-comments` carries only flags.AllDefaultFlags plus --fields, so there
# is no --state to ask the server with; the default view drops resolved rows
# after the call. The mixed fixture is what makes this testable: with only
# unresolved rows, a filter that did nothing at all would pass.
gtt_test_pr_review_threads_filters_locally_on_resolver() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): the unresolved-only default is filtered LOCALLY on resolver, with no --state to ask for ==="

  gtt_setup_repo

  local sandbox_default sandbox_all out_default out_all payload_file argv_default argv_all
  local stderr_file="/tmp/gtt_local_filter_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"
  sandbox_default=$(gtt_new_sandbox)
  sandbox_all=$(gtt_new_sandbox)

  out_default=$(gtt_run_cli "$sandbox_default" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)
  out_all=$(gtt_run_cli "$sandbox_all" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42 --all)
  argv_default=$(gtt_tea_argv "$sandbox_default")
  argv_all=$(gtt_tea_argv "$sandbox_all")

  # The fixture is genuinely mixed -- asserted, not assumed, because a fixture
  # that quietly lost its resolved row would make the filter untestable.
  assert_eq "3" "$(jq 'length' "$payload_file")" "gtt filter: the fixture carries three review comments"
  assert_eq "1" "$(jq '[.[] | select(.resolver != "")] | length' "$payload_file")" "gtt filter: exactly one of them has a NON-EMPTY resolver, so the filter has something to drop"
  assert_eq "2" "$(jq '[.[] | select(.resolver == "")] | length' "$payload_file")" "gtt filter: and two have an empty one"

  assert_eq "2" "$(printf '%s' "$out_default" | jq '.data.threads | length')" "gtt filter: the default call returns only the two unresolved comments"
  assert_eq "3" "$(printf '%s' "$out_all" | jq '.data.threads | length')" "gtt filter: --all returns all three, resolved one included"
  assert_eq "0" "$(printf '%s' "$out_default" | jq '[.data.threads[] | select(.isResolved)] | length')" "gtt filter: no resolved thread survives the default call"
  assert_eq "1" "$(printf '%s' "$out_all" | jq '[.data.threads[] | select(.isResolved)] | length')" "gtt filter: and exactly one does under --all"
  assert_eq "1127" "$(printf '%s' "$out_all" | jq -r '[.data.threads[] | select(.isResolved)][0].id')" "gtt filter: the resolved one is the row whose resolver is a username"

  # The proof that the filter is LOCAL: both calls emit byte-identical argv.
  # A server-side filter could not possibly produce two different lists from
  # the same request.
  assert_eq "$argv_default" "$argv_all" "gtt filter: --all and the default emit IDENTICAL argv -- the two lists differ only because the filtering happened locally"
  assert_eq "0" "$(printf '%s\n' "$argv_all" | grep -c -- '--state')" "gtt filter: --all does NOT become a --state all request, unlike the gitlab arm"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_default"
  teardown_forge_cli_sandbox "$sandbox_all"
  gtt_teardown_repo
}

# The row-to-thread translation, including the two coercions the LIST path
# forces: `line` back to a NUMBER and `isResolved` derived from a STRING.
gtt_test_pr_review_threads_maps_comment_to_degenerate_thread() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): one review comment becomes one DEGENERATE single-comment thread ==="

  gtt_setup_repo

  local sandbox out payload_file
  local stderr_file="/tmp/gtt_mapping_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"
  sandbox=$(gtt_new_sandbox)

  out=$(gtt_run_cli "$sandbox" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42 --all)

  # tea exposes no conversation object, so there is exactly one comment per
  # thread and three comments produce three threads -- even though two of them
  # share a path, which is what an invented grouping would have collapsed.
  assert_eq "3" "$(printf '%s' "$out" | jq '.data.threads | length')" "gtt degenerate: three review comments become THREE threads"
  assert_eq "1" "$(printf '%s' "$out" | jq '.data.threads[0].comments.totalCount')" "gtt degenerate: totalCount is 1 on the first thread"
  assert_eq "1" "$(printf '%s' "$out" | jq '.data.threads[1].comments.totalCount')" "gtt degenerate: 1 on the second"
  assert_eq "1" "$(printf '%s' "$out" | jq '.data.threads[2].comments.totalCount')" "gtt degenerate: 1 on the third"
  assert_eq "1" "$(printf '%s' "$out" | jq '[.data.threads[] | .comments.nodes | length] | unique | .[0]')" "gtt degenerate: and every comments.nodes array holds exactly one element"
  assert_eq "2" "$(printf '%s' "$out" | jq '[.data.threads[] | select(.path == "src/main.go")] | length')" "gtt degenerate: the two comments on src/main.go stay TWO threads -- grouping by path is not invented"

  # The LIST path marshals every value as a string. `line` must come back a
  # JSON number anyway; `id` must stay a string, as on every other forge.
  assert_eq "number" "$(printf '%s' "$out" | jq -r '.data.threads[0].line | type')" "gtt coercion: line is a JSON NUMBER, not the string tea printed"
  assert_eq "17" "$(printf '%s' "$out" | jq -r '.data.threads[0].line')" "gtt coercion: and it is the fixture's own value"
  assert_eq "string" "$(printf '%s' "$out" | jq -r '.data.threads[0].id | type')" "gtt coercion: thread id is a string, matching every other forge"
  assert_eq "string" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].id | type')" "gtt coercion: and so is the comment id"

  # isResolved is DERIVED: tea has no boolean, only a resolver username.
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.threads[0].isResolved')" "gtt derived: an EMPTY resolver is isResolved false"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.threads[1].isResolved')" "gtt derived: a resolver USERNAME is isResolved true"
  assert_eq "boolean" "$(printf '%s' "$out" | jq -r '.data.threads[1].isResolved | type')" "gtt derived: and it is a JSON boolean, never the raw resolver string"
  assert_eq "0" "$(printf '%s' "$out" | grep -c 'resolver')" "gtt derived: tea's own key name never leaks into the normalized envelope"

  # The rest of the per-comment translation.
  assert_eq "src/main.go" "$(printf '%s' "$out" | jq -r '.data.threads[0].path')" "gtt mapping: path carried through"
  assert_eq "monalisa" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].author.login')" "gtt mapping: tea's reviewer becomes the contract's author.login"
  assert_eq "please rename this" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].body')" "gtt mapping: body carried through"
  assert_eq "2026-01-01T10:00:00Z" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].createdAt')" "gtt mapping: created becomes createdAt"
  assert_eq "2026-01-01T10:30:00Z" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].updatedAt')" "gtt mapping: updated becomes updatedAt"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# THE GAP LIST, asserted as a whole array in one comparison so an entry that
# quietly appears or disappears is caught. The single most likely defect this
# catches is copying the gitlab arm's array wholesale, which would wrongly
# declare comments.nodes[].url unsupported -- the one field gitea has and
# GitLab does not.
gtt_test_pr_review_threads_declares_its_capability_gaps() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): unsupported_fields names every gap, and url is NOT one of them ==="

  gtt_setup_repo

  local sandbox out payload_file
  local stderr_file="/tmp/gtt_gaps_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"
  sandbox=$(gtt_new_sandbox)

  out=$(gtt_run_cli "$sandbox" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)

  assert_eq '["pr.title","pr.url","threads[].startLine","threads[].diffSide","threads[].isOutdated","threads[].isCollapsed","threads[].grouping","threads[].comments.nodes[].outdated"]' \
    "$(printf '%s' "$out" | jq -c '.data.unsupported_fields')" \
    "gtt gaps: unsupported_fields is exactly the eight gitea gaps, compared as a whole array"

  # Every named path is also null in the payload -- null PLUS the name, never
  # a bare unmarked null, per forge-contract.md.
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.pr.title')" "gtt gaps: pr.title is null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.pr.url')" "gtt gaps: pr.url is null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].startLine')" "gtt gaps: startLine is null -- tea has no such field"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].diffSide')" "gtt gaps: diffSide is null -- tea collapses LineNum and OldLineNum into one printed column"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].isOutdated')" "gtt gaps: isOutdated is null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].isCollapsed')" "gtt gaps: isCollapsed is null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].grouping')" "gtt gaps: grouping is null -- and present as a key, so the gap is declared at the point a reader meets it"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.threads[0] | has("grouping")')" "gtt gaps: grouping really is an explicit key, not merely an absent path that reads null"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].outdated')" "gtt gaps: comments.nodes[].outdated is null"

  # THE ONE PLACE GITEA IS RICHER THAN GITLAB. Copying the gitlab array
  # wholesale is the expected mistake; this is what catches it.
  assert_eq "https://gitea.com/acme/widgets/pulls/42/files#issuecomment-1126" \
    "$(printf '%s' "$out" | jq -r '.data.threads[0].comments.nodes[0].url')" \
    "gtt gaps: comments.nodes[].url is POPULATED verbatim from tea's own url field"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.unsupported_fields | index("threads[].comments.nodes[].url") != null')" \
    "gtt gaps: and it is NOT listed unsupported -- unlike GitLab's arm, which does list it"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# THE DISTINCTION THAT MAKES A CLEAN REVIEW READABLE: zero review comments is
# a `found` result carrying an empty list. not_found means the PULL REQUEST
# itself could not be located.
gtt_test_pr_review_threads_zero_comments_is_found_with_empty_list() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): zero review comments is FOUND with an empty list, never not_found ==="

  gtt_setup_repo

  local sandbox_empty sandbox_blank sandbox_missing out_empty out_blank out_missing
  local stderr_file="/tmp/gtt_empty_stderr.$$"

  sandbox_empty=$(gtt_new_sandbox)
  sandbox_blank=$(gtt_new_sandbox)
  sandbox_missing=$(gtt_new_sandbox)

  out_empty=$(gtt_run_cli "$sandbox_empty" "$stderr_file" 'GTT_LIST_STDOUT=[]' \
    -- forge-pr-review-threads --pr 42)
  out_blank=$(gtt_run_cli "$sandbox_blank" "$stderr_file" 'GTT_LIST_STDOUT=' \
    -- forge-pr-review-threads --pr 42)

  assert_eq "found" "$(printf '%s' "$out_empty" | jq -r '.status')" "gtt empty: an empty JSON array is FOUND"
  assert_eq "[]" "$(printf '%s' "$out_empty" | jq -c '.data.threads')" "gtt empty: carrying an empty threads list"
  assert_eq "42" "$(printf '%s' "$out_empty" | jq -r '.data.pr.number')" "gtt empty: and still naming the pull request it looked at"
  assert_eq "found" "$(printf '%s' "$out_blank" | jq -r '.status')" "gtt empty: printing nothing at all is FOUND too"
  assert_eq "[]" "$(printf '%s' "$out_blank" | jq -c '.data.threads')" "gtt empty: and also collapses to an empty list"

  # The contrast that gives the assertion its meaning.
  out_missing=$(gtt_run_cli "$sandbox_missing" "$stderr_file" \
    'GTT_LIST_FAIL_STDERR=Error: GET https://gitea.com/api/v1/...: 404 Not Found' \
    -- forge-pr-review-threads --pr 999999)

  assert_eq "not_found" "$(printf '%s' "$out_missing" | jq -r '.status')" "gtt empty: a 404 from tea IS not_found -- the pull request itself could not be located"
  assert_eq "null" "$(printf '%s' "$out_missing" | jq -r '.data')" "gtt empty: not_found carries no data"
  local differ=no
  if [ "$(printf '%s' "$out_empty" | jq -r '.status')" != "$(printf '%s' "$out_missing" | jq -r '.status')" ]; then
    differ=yes
  fi
  assert_eq "yes" "$differ" "gtt empty: 'no comments' and 'no pull request' produce DIFFERENT statuses -- they are not conflated"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_empty"
  teardown_forge_cli_sandbox "$sandbox_blank"
  teardown_forge_cli_sandbox "$sandbox_missing"
  gtt_teardown_repo
}

# tea exits 1 for EVERY error with no distinct not-found code, so `404` in
# stderr is the only confirmed negative and everything else must stay a
# could-not-attempt. Reading a broken call as "the pull request does not
# exist" is the dangerous direction.
gtt_test_pr_review_threads_failure_classification() {
  echo ""
  echo "=== forge-pr-review-threads (gitea): only a 404 is a confirmed negative; every other exit stays cli_failed ==="

  gtt_setup_repo

  local sandbox_net sandbox_old out_net out_old
  local stderr_file="/tmp/gtt_list_broken_stderr.$$"

  sandbox_net=$(gtt_new_sandbox)
  sandbox_old=$(gtt_new_sandbox)

  out_net=$(gtt_run_cli "$sandbox_net" "$stderr_file" \
    'GTT_LIST_FAIL_STDERR=Error: Get "https://gitea.com/api/v1/...": dial tcp: connection refused' \
    -- forge-pr-review-threads --pr 42)

  assert_eq "error" "$(printf '%s' "$out_net" | jq -r '.status')" "gtt broken: status error"
  assert_eq "cli_failed" "$(printf '%s' "$out_net" | jq -r '.reason')" "gtt broken: reason cli_failed -- a could-not-attempt failure is never read as not_found"
  assert_contains "tea pulls review-comments exited 1" "$(printf '%s' "$out_net" | jq -r '.message')" "gtt broken: message names the failing tea call and its exit status"
  assert_contains "connection refused" "$(printf '%s' "$out_net" | jq -r '.message')" "gtt broken: and carries tea's own stderr text through"
  assert_eq "" "$(cat "$stderr_file")" "gtt broken: still QUIET -- a read verb prints nothing"

  # A tea older than the v0.14.0 version floor answers with an
  # unknown-subcommand error, which is exactly this branch: cli_failed, never
  # a confirmed "this pull request has no review comments".
  out_old=$(gtt_run_cli "$sandbox_old" "$stderr_file" \
    'GTT_LIST_FAIL_STDERR=Error: No help topic for '"'"'review-comments'"'"'' \
    -- forge-pr-review-threads --pr 42)

  assert_eq "error" "$(printf '%s' "$out_old" | jq -r '.status')" "gtt version floor: a tea older than v0.14.0 (unknown subcommand) is an ERROR"
  assert_eq "cli_failed" "$(printf '%s' "$out_old" | jq -r '.reason')" "gtt version floor: classified cli_failed, never not_found and never an empty thread list"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_net"
  teardown_forge_cli_sandbox "$sandbox_old"
  gtt_teardown_repo
}

gtt_test_resolve_review_thread_via_tea() {
  echo ""
  echo "=== forge-resolve-review-thread (gitea): resolves via \`tea pulls resolve <comment id>\`, one call, no reply ==="

  gtt_setup_repo

  local sandbox out argv
  local stderr_file="/tmp/gtt_resolve_ok_stderr.$$"

  sandbox=$(gtt_new_sandbox)
  out=$(gtt_run_cli "$sandbox" "$stderr_file" -- forge-resolve-review-thread --thread-id 1126)
  argv=$(gtt_tea_argv "$sandbox")

  assert_eq "pulls resolve 1126" "$argv" "gtt resolve: the call is exactly \`tea pulls resolve <comment id>\`, with the pull request never named"
  assert_eq "1" "$(gtt_tea_call_count "$sandbox")" "gtt resolve: exactly ONE tea invocation -- no second call could have posted anything"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -c 'comment create')" "gtt resolve: no comment-creating subcommand anywhere in the recorded argv"
  assert_eq "0" "$(printf '%s\n' "$argv" | grep -cE -- '(^| )(-d|--description|--body|-m)( |$)')" "gtt resolve: no body/description flag -- nothing carried comment text"

  # tea prints `Comment <id> resolved` and no JSON, so the envelope is rebuilt
  # from the id and the exit status. Asserted as a WHOLE document.
  assert_eq '{"resolved":true,"thread":{"id":"1126","isResolved":true,"path":null,"line":null},"unsupported_fields":["thread.path","thread.line"]}' \
    "$(printf '%s' "$out" | jq -c '.data')" \
    "gtt resolve: the whole success envelope, rebuilt in the shape \`glab mr note resolve\` already established"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gtt resolve: status found"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "gtt resolve: message null"
  assert_eq "" "$(cat "$stderr_file")" "gtt resolve: nothing printed on the success path"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

gtt_test_resolve_review_thread_failure_classification() {
  echo ""
  echo "=== forge-resolve-review-thread (gitea): a 404 is a CONFIRMED negative (found/resolved:false), a broken call is not ==="

  gtt_setup_repo

  local sandbox_404 sandbox_broken out_404 out_broken exit_404 exit_broken
  local stderr_404="/tmp/gtt_resolve_404_stderr.$$"
  local stderr_broken="/tmp/gtt_resolve_broken_stderr.$$"

  sandbox_404=$(gtt_new_sandbox)
  sandbox_broken=$(gtt_new_sandbox)

  out_404=$(gtt_run_cli "$sandbox_404" "$stderr_404" \
    'GTT_RESOLVE_FAIL_STDERR=Error: GET https://gitea.com/api/v1/...: 404 Not Found' \
    -- forge-resolve-review-thread --thread-id 999999) && exit_404=0 || exit_404=$?

  assert_exit_code "0" "$exit_404" "gtt resolve-404: exit 0 -- the call ran and returned a definitive answer"
  assert_eq "found" "$(printf '%s' "$out_404" | jq -r '.status')" "gtt resolve-404: status found, matching the other two adapters' confirmed-invalid-id result"
  assert_eq '{"resolved":false,"thread":null,"unsupported_fields":[]}' "$(printf '%s' "$out_404" | jq -c '.data')" "gtt resolve-404: the whole confirmed-negative envelope"
  assert_eq "null" "$(printf '%s' "$out_404" | jq -r '.reason')" "gtt resolve-404: no reason -- a confirmed answer is not a degradation"
  assert_eq "" "$(cat "$stderr_404")" "gtt resolve-404: nothing printed"

  out_broken=$(gtt_run_cli "$sandbox_broken" "$stderr_broken" \
    'GTT_RESOLVE_FAIL_STDERR=Error: Get "https://gitea.com/api/v1/...": dial tcp: connection refused' \
    -- forge-resolve-review-thread --thread-id 1126) && exit_broken=0 || exit_broken=$?

  assert_exit_code "1" "$exit_broken" "gtt resolve-broken: exits non-zero (write verb, no fallback path)"
  assert_eq "error" "$(printf '%s' "$out_broken" | jq -r '.status')" "gtt resolve-broken: status error, NOT a found/resolved:false that would claim the comment was checked"
  assert_eq "cli_failed" "$(printf '%s' "$out_broken" | jq -r '.reason')" "gtt resolve-broken: reason cli_failed"
  assert_contains "tea pulls resolve exited 1" "$(printf '%s' "$out_broken" | jq -r '.message')" "gtt resolve-broken: message names the failing tea call"
  assert_stderr_contains "resolve it manually" "$(cat "$stderr_broken")" "gtt resolve-broken: the mandatory manual instruction is printed"

  rm -f "$stderr_404" "$stderr_broken"
  teardown_forge_cli_sandbox "$sandbox_404"
  teardown_forge_cli_sandbox "$sandbox_broken"
  gtt_teardown_repo
}

# THE ROUND TRIP. Whatever identifier the listing verb emits must be accepted
# VERBATIM by the resolve verb. The id is never retyped here -- it is read out
# of the listing's own output and fed straight back in.
gtt_test_thread_id_round_trips_from_listing_to_resolve() {
  echo ""
  echo "=== gitea review threads: the id the listing emits is accepted VERBATIM by the resolve call (round trip) ==="

  gtt_setup_repo

  local sandbox_list sandbox_resolve list_out resolve_out emitted_id resolve_argv payload_file last_arg
  local stderr_file="/tmp/gtt_round_trip_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"
  sandbox_list=$(gtt_new_sandbox)
  sandbox_resolve=$(gtt_new_sandbox)

  list_out=$(gtt_run_cli "$sandbox_list" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42)
  emitted_id=$(printf '%s' "$list_out" | jq -r '.data.threads[0].id')

  # Deliberately NOT a literal -- the value comes from the listing verb's own
  # output, so a change to what the listing emits is felt here immediately.
  resolve_out=$(gtt_run_cli "$sandbox_resolve" "$stderr_file" \
    -- forge-resolve-review-thread --thread-id "$emitted_id")
  resolve_argv=$(gtt_tea_argv "$sandbox_resolve")
  last_arg=$(printf '%s' "$resolve_argv" | awk '{print $NF}')

  assert_eq "$emitted_id" "$last_arg" "gtt round trip: the emitted id is tea's LAST recorded argument, byte for byte"
  assert_eq "pulls resolve $emitted_id" "$resolve_argv" "gtt round trip: and nothing else was added, reformatted or truncated around it"
  assert_eq "found" "$(printf '%s' "$resolve_out" | jq -r '.status')" "gtt round trip: the resolve call succeeded on that id"
  assert_eq "$emitted_id" "$(printf '%s' "$resolve_out" | jq -r '.data.thread.id')" "gtt round trip: and the resolve result reports the same id back"

  # Pinned independently against the fixture so the round trip is not merely
  # self-consistent: had the listing emitted something derived, the argv
  # assertion above would have compared against that derived value and passed.
  assert_eq "1126" "$emitted_id" "gtt round trip: the emitted id is the fixture's own comment id, not a re-derivation"

  # A numeric id passes cmd_forge_resolve_review_thread's existing thread-id
  # guard unchanged -- asserted against the guard's source text, so a story
  # that widened it to accommodate gitea would be caught here.
  assert_eq "1" "$(gtt_count_fixed_in_function "cmd_forge_resolve_review_thread" '^[A-Za-z0-9+/=_-]+$')" "gtt round trip: cmd_forge_resolve_review_thread's thread-id guard still reads ^[A-Za-z0-9+/=_-]+\$ -- a numeric gitea id passes it unchanged, so this story widened nothing"

  rm -f "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox_list"
  teardown_forge_cli_sandbox "$sandbox_resolve"
  gtt_teardown_repo
}

# THE ONE ASSERTION IN THIS SECTION MEASURED AGAINST REALITY. tea is genuinely
# not installed on this machine, so `command -v tea` fails for the real reason
# rather than a staged one. Both a stripped allowlist PATH and the machine's
# own PATH are checked, so a future machine that DOES install tea makes the
# reality check visibly stop applying instead of silently passing.
gtt_test_tea_absent_degrades_through_the_shared_gate() {
  echo ""
  echo "=== gitea review threads: tea absent -- same shared _forge_bin_check gate, naming tea not gh ==="

  gtt_setup_repo

  local sandbox stripped_path out resolve_out exit_code tea_really_absent
  local stderr_file="/tmp/gtt_no_tea_stderr.$$"
  local stderr_resolve="/tmp/gtt_no_tea_resolve_stderr.$$"

  tea_really_absent=yes
  command -v tea >/dev/null 2>&1 && tea_really_absent=no
  assert_eq "yes" "$tea_really_absent" "gtt no-tea: tea is genuinely absent from this machine's PATH -- this is the story's one reality-measured assertion, and it stops applying loudly if tea is ever installed"

  # A PATH built by stripping tea from the caller's real one, the same
  # setup_forge_no_gh_fixture shape, plus the allowlist sandbox that never had
  # a tea entry at all. Both must produce the same degradation.
  stripped_path=$(_path_without_binary tea)
  sandbox=$(gtt_new_sandbox_without_tea)

  out=$(gtt_run_cli "$sandbox" "$stderr_file" -- forge-pr-review-threads --pr 42)

  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "gtt no-tea: status error"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "gtt no-tea: reason cli_missing -- the same enum value the gh and glab paths use"
  assert_contains "tea not found" "$(printf '%s' "$out" | jq -r '.message')" "gtt no-tea: the message names tea, not gh"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "gtt no-tea: and does NOT name gh -- the wrong binary would send a Gitea user hunting for the wrong install"
  assert_eq "" "$(cat "$stderr_file")" "gtt no-tea: QUIET mode -- ZERO stderr from the listing verb"

  # The same scenario through the genuinely-stripped PATH rather than the
  # allowlist sandbox.
  local stripped_out
  stripped_out=$(cd "$GTT_REPO_DIR" && PATH="$stripped_path" "$CLI" forge-pr-review-threads --pr 42 2>/dev/null)
  assert_eq "cli_missing" "$(printf '%s' "$stripped_out" | jq -r '.reason')" "gtt no-tea: a PATH with tea stripped out reaches the identical cli_missing result"

  # The resolve verb is the MANDATORY-PRINT half: same envelope, but the
  # public wrapper prints and exits non-zero.
  resolve_out=$(gtt_run_cli "$sandbox" "$stderr_resolve" \
    -- forge-resolve-review-thread --thread-id 1126) && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "gtt resolve no-tea: exits non-zero, exactly like the gh-absent path"
  assert_eq "error" "$(printf '%s' "$resolve_out" | jq -r '.status')" "gtt resolve no-tea: status error"
  assert_eq "cli_missing" "$(printf '%s' "$resolve_out" | jq -r '.reason')" "gtt resolve no-tea: reason cli_missing"
  assert_contains "tea not found" "$(printf '%s' "$resolve_out" | jq -r '.message')" "gtt resolve no-tea: the message names tea"
  assert_stderr_contains "resolve it manually" "$(cat "$stderr_resolve")" "gtt resolve no-tea: cmd_forge_resolve_review_thread is still the ONLY layer that prints the manual instruction"

  rm -rf "$stripped_path"
  rm -f "$stderr_file" "$stderr_resolve"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# `unknown` is now the ONLY forge word with no adapter -- AIMI_FORGE_TYPE
# validates against github|gitlab|gitea, so an unrecognized remote host is the
# only way to reach the no_adapter branch at all.
gtt_test_no_adapter_message_names_all_three_adapters() {
  echo ""
  echo "=== review-thread verbs: the no_adapter message names all THREE adapters, and only \`unknown\` still reaches it ==="

  gtt_setup_repo https://git.example.com/owner/repo.git

  local sandbox list_out resolve_out exit_code
  local stderr_file="/tmp/gtt_no_adapter_stderr.$$"

  sandbox=$(gtt_new_sandbox)

  list_out=$(gtt_run_cli "$sandbox" "$stderr_file" -- forge-pr-review-threads --pr 42)
  assert_eq "error" "$(printf '%s' "$list_out" | jq -r '.status')" "gtt no_adapter (listing): status error"
  assert_eq "no_adapter" "$(printf '%s' "$list_out" | jq -r '.reason')" "gtt no_adapter (listing): reason no_adapter"
  assert_contains "unknown" "$(printf '%s' "$list_out" | jq -r '.message')" "gtt no_adapter (listing): the message names the detected forge, which for an unrecognized host is \`unknown\`"
  assert_contains "GitHub, GitLab and Gitea are the only adapters" "$(printf '%s' "$list_out" | jq -r '.message')" "gtt no_adapter (listing): and names all three adapters, not the stale two"
  assert_eq "0" "$(gtt_tea_call_count "$sandbox")" "gtt no_adapter (listing): tea is never invoked for an unrecognized host"

  resolve_out=$(gtt_run_cli "$sandbox" "$stderr_file" \
    -- forge-resolve-review-thread --thread-id 1126) && exit_code=0 || exit_code=$?
  assert_exit_code "1" "$exit_code" "gtt no_adapter (resolve): the write verb still exits non-zero"
  assert_eq "no_adapter" "$(printf '%s' "$resolve_out" | jq -r '.reason')" "gtt no_adapter (resolve): reason no_adapter"
  assert_contains "GitHub, GitLab and Gitea are the only adapters" "$(printf '%s' "$resolve_out" | jq -r '.message')" "gtt no_adapter (resolve): names all three adapters too"

  rm -f "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# THE STALENESS CATCH. The phase-1 GITEA CAPABILITY-GAP NOTE ruled that tea
# could not resolve a review thread at all. This story disproves that ruling,
# and leaving the note in place would let the next reader trust it -- so the
# rewrite is asserted rather than left to the eye.
#
# COUNTING FORM THROUGHOUT: `count=$(grep -c ...) || count=0` compared with
# assert_eq, never `grep -v ... | grep -q ...` inside an `if`, which under
# `set -o pipefail` reports ABSENT for a file that contains the pattern.
gtt_test_capability_gap_note_is_rewritten() {
  echo ""
  echo "=== GITEA CAPABILITY-GAP NOTE: the falsified ruling is gone, the advice survives, and the version floor is recorded ==="

  local note
  note=$(sed -n '/^# GITEA CAPABILITY-GAP NOTE/,/^# -\{20,\}$/p' "$CLI")

  # A control that MUST match, run before any zero is trusted: a query that
  # returns 0 because it was malformed is indistinguishable from one that
  # returns 0 because the string is gone.
  assert_eq "1" "$(gtt_count_matches "$CLI" 'GITEA CAPABILITY-GAP NOTE')" "gtt note control: the note itself is findable exactly once -- proving the counting query works before any zero below is believed"
  local note_lines
  note_lines=$(printf '%s\n' "$note" | grep -c '') || note_lines=0
  assert_eq "yes" "$([ "$note_lines" -gt 10 ] && echo yes || echo no)" "gtt note control: and the extracted note is a real block of text, not an empty sed result"

  # The falsified claims, gone.
  assert_eq "0" "$(gtt_count_matches "$CLI" 'NO equivalent for resolving a review thread')" "gtt note: the ruling that tea has NO equivalent for resolving a review thread is gone from aimi-cli.sh"
  assert_eq "0" "$(gtt_count_matches "$CLI" 'no reviewThread/conversation-resolution concept')" "gtt note: and so is the claim that tea has no reviewThread/conversation-resolution concept"

  # The facts that replace them.
  assert_eq "yes" "$([ "$(gtt_count_matches "$CLI" 'tea pulls review-comments')" -ge 1 ] && echo yes || echo no)" "gtt note: \`tea pulls review-comments\` is named in the file"
  assert_eq "yes" "$([ "$(gtt_count_matches "$CLI" 'tea pulls resolve')" -ge 1 ] && echo yes || echo no)" "gtt note: and so is \`tea pulls resolve\`"
  assert_eq "yes" "$([ "$(gtt_count_matches "$CLI" 'v0\.14\.0')" -ge 1 ] && echo yes || echo no)" "gtt note: the tea v0.14.0 version floor is recorded"

  # The narrowed real gap, stated inside the note itself.
  assert_contains "GROUPING" "$note" "gtt note: the rewritten note names GROUPING as the real gap"
  assert_contains "no thread/conversation object" "$note" "gtt note: and says tea exposes no thread/conversation object"
  assert_contains "DEGENERATE" "$note" "gtt note: so one review comment becomes one degenerate thread"
  assert_contains "diffSide" "$note" "gtt note: diffSide is named as part of the narrowed gap"
  assert_contains "collapses LineNum and OldLineNum" "$note" "gtt note: with the reason -- tea collapses the two line numbers into one printed field"

  # THE ADVICE SURVIVES. Only the factual claim changed.
  assert_eq "yes" "$([ "$(printf '%s\n' "$note" | grep -c 'unsupported_fields')" -ge 1 ] && echo yes || echo no)" "gtt note: the note still routes a permanent gap through unsupported_fields"
  assert_contains "nobody wrote the adapter" "$note" "gtt note: and still distinguishes 'this forge cannot do this at all' from 'nobody wrote the adapter yet'"

  # The stale note's own worked example is now the WRONG answer, because
  # resolution IS supported. Counted over the whole file: a quoted
  # resolveReviewThread would only ever appear as an unsupported_fields entry,
  # since the GraphQL mutation and the jq path both use it unquoted.
  assert_eq "0" "$(gtt_count_matches "$CLI" '"resolveReviewThread"')" "gtt note: resolveReviewThread appears in NO unsupported_fields array anywhere -- resolution is supported now"
  assert_eq "yes" "$([ "$(gtt_count_matches "$CLI" 'resolveReviewThread')" -ge 1 ] && echo yes || echo no)" "gtt note control: the bare word still appears (the GraphQL mutation), so the zero above is a scoped absence rather than a broken query"
}

# The section header carries the phase's declared ceiling and version floor in
# the same shape as the six that already exist, asserted so neither can be
# deleted silently.
gtt_test_section_header_declares_ceiling_and_version_floor() {
  echo ""
  echo "=== gitea review-thread adapters: the section header carries the VERIFICATION CEILING and the tea >= v0.14.0 version floor ==="

  local header
  header=$(sed -n '/^# GITEA REVIEW-THREAD ADAPTERS/,/^_forge_pr_review_threads_gitea/p' "$CLI")

  local header_lines
  header_lines=$(printf '%s\n' "$header" | grep -c '') || header_lines=0
  assert_eq "yes" "$([ "$header_lines" -gt 20 ] && echo yes || echo no)" "gtt header control: the header block really was extracted, so the assertions below are not reading an empty string"

  assert_contains "VERIFICATION CEILING" "$header" "gtt header: the ceiling is declared in as many words"
  assert_contains "NOT installed on the machine" "$header" "gtt header: stating that tea is not installed here"
  assert_contains "2026-08-06" "$header" "gtt header: and naming the date the source was read"
  assert_contains "never what real tea does" "$header" "gtt header: the tests prove emitted argv and fixture parsing, never real tea behaviour"
  assert_contains "VERSION FLOOR" "$header" "gtt header: the version floor is declared"
  assert_contains "v0.14.0" "$header" "gtt header: naming v0.14.0 as the floor"
  assert_contains "v0.15.1" "$header" "gtt header: and v0.15.1 as the release read"
  assert_contains "GH_TOKEN" "$header" "gtt header: the GH_TOKEN hazard is recorded"
  assert_contains "grouping" "$header" "gtt header: and so is the grouping gap that neither other forge has"
}

# NO TOKEN IS EVER HANDED TO tea. tea reads GH_TOKEN as a fallback credential,
# and _forge_account_override_slots defaults an empty slot to the AMBIENT
# GH_TOKEN, so copying the github arm's prefix-assignment shape onto a tea
# invocation would hand a GitHub token to a Gitea instance.
gtt_test_neither_gitea_arm_hands_a_token_to_tea() {
  echo ""
  echo "=== gitea review-thread adapters: neither function assigns or exports a token variable ==="

  # THE CONTROL, run first and required to be non-zero: the github arm of
  # _forge_resolve_review_thread genuinely does prefix-assign GH_TOKEN, so a
  # counting query that cannot find it there is broken, and every zero below
  # would be a false negative.
  local github_arm_assignments
  github_arm_assignments=$(gtt_count_in_function_code "_forge_resolve_review_thread" "$GTT_TOKEN_ASSIGNMENT_RE")
  assert_eq "yes" "$([ "$github_arm_assignments" -ge 1 ] && echo yes || echo no)" "gtt token control: the counting query DOES find a token assignment inside _forge_resolve_review_thread's github arm -- so a zero below means absent, not unmatched"

  assert_eq "0" "$(gtt_count_in_function_code "_forge_pr_review_threads_gitea" "$GTT_TOKEN_ASSIGNMENT_RE")" "gtt token: _forge_pr_review_threads_gitea assigns or exports no credential variable tea could read"
  assert_eq "0" "$(gtt_count_in_function_code "_forge_resolve_review_thread_gitea" "$GTT_TOKEN_ASSIGNMENT_RE")" "gtt token: nor does _forge_resolve_review_thread_gitea"
  assert_eq "0" "$(gtt_count_in_function_code "_forge_pr_review_threads_gitea" '(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)')" "gtt token: stronger still -- the listing arm's executable lines do not so much as NAME one of those variables"
  assert_eq "0" "$(gtt_count_in_function_code "_forge_resolve_review_thread_gitea" '(GH_TOKEN|GH_ENTERPRISE_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)')" "gtt token: and neither do the resolve arm's"
  assert_eq "0" "$(gtt_count_in_function_code "_forge_pr_review_threads_gitea" '_forge_account_override_slots')" "gtt token: neither arm calls _forge_account_override_slots, whose empty slot defaults to the AMBIENT GH_TOKEN"
  assert_eq "0" "$(gtt_count_in_function_code "_forge_resolve_review_thread_gitea" '_forge_account_override_slots')" "gtt token: confirmed for the resolve arm too"
}

# THE RETARGET CLASS, CLOSED BY INVARIANT RATHER THAN BY LINE NUMBER. Phase 3
# retargeted three tests from `gitlab` onto `gitea`; this phase does the same
# to `gitea`, and after it there is no forge word left to retarget to. Chasing
# the individual line numbers would collide with the sibling stories editing
# this same file, so the property is asserted instead: no assertion MESSAGE in
# part 3 or part 4 may claim gitea (or codeberg) has no adapter.
gtt_test_no_assertion_message_claims_gitea_has_no_adapter() {
  echo ""
  echo "=== part3/part4: no assertion message pairs gitea or codeberg with 'no adapter' ==="

  local part3="$SCRIPT_DIR/test-aimi-cli-part3-roadmap-forge.sh"
  local part4="$SCRIPT_DIR/test-aimi-cli-part4-forge-verbs.sh"

  # THE CONTROL THAT MUST MATCH, run before either zero is believed. Nine
  # false zeros in this repository have come from a query that silently
  # matched nothing, so the counter is first shown returning 1 for a line it
  # must catch.
  local probe
  probe=$(mktemp)
  printf '%s\n' '  assert_eq "gitea" "$out" "detection: gitea is untouched and still has no adapter"' > "$probe"
  assert_eq "1" "$(gtt_count_stale_no_adapter_messages "$probe")" "gtt retarget control: the counter DOES find a stale message when one is present -- so the zeros below mean absent, not unmatched"
  printf '%s\n' '  assert_eq "gitea" "$out" "detection: gitea.com classifies as gitea"' > "$probe"
  assert_eq "0" "$(gtt_count_stale_no_adapter_messages "$probe")" "gtt retarget control: and does NOT fire on a message that merely mentions gitea"
  rm -f "$probe"

  # NOTE TO WHOEVER READS A FAILURE HERE: the two messages below are worded so
  # they do not themselves trip the counter. That is not evasion -- an
  # assertion message asserting the property must not be an instance of the
  # property, or the invariant could never reach zero. Keep any replacement
  # wording free of the forbidden pairing for the same reason.
  assert_eq "0" "$(gtt_count_stale_no_adapter_messages "$part4")" "gtt retarget: part 4 carries zero stale assertion messages of the retargeted class"
  assert_eq "0" "$(gtt_count_stale_no_adapter_messages "$part3")" "gtt retarget: and part 3 carries zero as well"
}

# ---------------------------------------------------------------------------
# MUTATION TESTS. Each unroutes ONE verb in a COPY of the CLI -- by disabling
# that verb's own `forge == gitea` gate and nothing else -- and confirms a
# SPECIFIC NAMED assertion above goes red, so the assertions are known to be
# load-bearing rather than merely green.
#
# The gate CONDITION is what is mutated, not the adapter call below it:
# deleting the call alone would leave the gate's trailing `return 0` in place
# and the verb would emit nothing at all. Changing the condition makes the
# verb behave exactly as it did before this story -- the adapterless
# `no_adapter` envelope -- which is the honest counterfactual. Each mutation
# asserts its own patch landed before trusting the red.
# ---------------------------------------------------------------------------
gtt_test_mutation_unrouting_the_listing_verb_turns_an_assertion_red() {
  echo ""
  echo "=== mutation: unrouting forge-pr-review-threads (gitea) makes the named argv assertion go red ==="

  gtt_setup_repo

  local sandbox mutant argv_green argv_red mutant_out payload_file
  local stderr_file="/tmp/gtt_mutation_list_stderr.$$"
  payload_file=$(mktemp)
  gtt_review_comment_fixture > "$payload_file"

  sandbox=$(gtt_new_sandbox)
  gtt_run_cli "$sandbox" "$stderr_file" "GTT_LIST_PAYLOAD_FILE=$payload_file" \
    -- forge-pr-review-threads --pr 42 >/dev/null
  argv_green=$(gtt_tea_argv "$sandbox")
  assert_eq "pulls review-comments 42 -f id,path,line,body,reviewer,resolver,created,updated,url -o json" "$argv_green" "gtt mutation (listing): the UNMUTATED CLI emits that argv -- the assertion being mutated"

  mutant=$(gtt_mutated_cli '/^_forge_pr_review_threads() {$/,/^}$/ s/^  if \[ "\$forge" = "gitea" \]; then$/  if [ "$forge" = "gitea-unrouted-by-mutation" ]; then/')
  assert_eq "1" "$(diff "$CLI" "$mutant" | grep -c '^> ')" "gtt mutation (listing): the mutation changed EXACTLY one line, scoped to this verb's own function body -- a broad edit would not localize the failure"

  rm -f "$sandbox/tea.log"
  gtt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 >/dev/null || true
  argv_red=$(gtt_tea_argv "$sandbox")

  assert_eq "" "$argv_red" "gtt mutation (listing): with the gitea gate disabled, tea is never invoked -- so \"the listing call is exactly tea pulls review-comments <index> -f <csv> -o json\" goes RED"
  local moved=no
  if [ "$argv_red" != "$argv_green" ]; then moved=yes; fi
  assert_eq "yes" "$moved" "gtt mutation (listing): the verdict MOVED between the real and the mutated CLI, so that assertion is load-bearing, not decorative"

  rm -f "$sandbox/tea.log"
  mutant_out=$(gtt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 || true)
  assert_eq "error" "$(printf '%s' "$mutant_out" | jq -r '.status')" "gtt mutation (listing): the mutated CLI answers error, so \"gtt listing: status found\" goes RED too"
  assert_eq "no_adapter" "$(printf '%s' "$mutant_out" | jq -r '.reason')" "gtt mutation (listing): with reason no_adapter -- exactly the pre-story behavior this routing replaced"

  # And the OTHER verb is untouched by this mutation, which is what makes the
  # two mutation tests independent evidence rather than one fact counted twice.
  rm -f "$sandbox/tea.log"
  gtt_run_mutated_cli "$mutant" "$sandbox" forge-resolve-review-thread --thread-id 1126 >/dev/null || true
  assert_contains "pulls resolve" "$(gtt_tea_argv "$sandbox")" "gtt mutation (listing): the RESOLVE verb still reaches tea under this mutation -- the unrouting is scoped to one verb"

  rm -f "$mutant" "$payload_file" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

gtt_test_mutation_unrouting_the_resolve_verb_turns_an_assertion_red() {
  echo ""
  echo "=== mutation: unrouting forge-resolve-review-thread (gitea) makes the named resolve-argv assertion go red ==="

  gtt_setup_repo

  local sandbox mutant argv_green argv_red mutant_out
  local stderr_file="/tmp/gtt_mutation_resolve_stderr.$$"

  sandbox=$(gtt_new_sandbox)
  gtt_run_cli "$sandbox" "$stderr_file" -- forge-resolve-review-thread --thread-id 1126 >/dev/null
  argv_green=$(gtt_tea_argv "$sandbox")
  assert_eq "pulls resolve 1126" "$argv_green" "gtt mutation (resolve): the UNMUTATED CLI calls tea pulls resolve -- the assertion being mutated"

  mutant=$(gtt_mutated_cli '/^_forge_resolve_review_thread() {$/,/^}$/ s/^  if \[ "\$forge" = "gitea" \]; then$/  if [ "$forge" = "gitea-unrouted-by-mutation" ]; then/')
  assert_eq "1" "$(diff "$CLI" "$mutant" | grep -c '^> ')" "gtt mutation (resolve): the mutation changed EXACTLY one line, scoped to this verb's own function body"

  rm -f "$sandbox/tea.log"
  mutant_out=$(gtt_run_mutated_cli "$mutant" "$sandbox" forge-resolve-review-thread --thread-id 1126 || true)
  argv_red=$(gtt_tea_argv "$sandbox")

  assert_eq "" "$argv_red" "gtt mutation (resolve): with the gitea gate disabled, tea is never invoked -- so \"the call is exactly tea pulls resolve <comment id>\" goes RED"
  local moved=no
  if [ "$argv_red" != "$argv_green" ]; then moved=yes; fi
  assert_eq "yes" "$moved" "gtt mutation (resolve): the verdict MOVED between the real and the mutated CLI, so that assertion is load-bearing"
  assert_eq "error" "$(printf '%s' "$mutant_out" | jq -r '.status')" "gtt mutation (resolve): the mutated CLI answers error, so \"gtt resolve: status found\" goes RED too"
  assert_eq "no_adapter" "$(printf '%s' "$mutant_out" | jq -r '.reason')" "gtt mutation (resolve): with reason no_adapter -- the pre-story behavior this routing replaced"

  # The mirror image of the listing mutation's own cross-check.
  rm -f "$sandbox/tea.log"
  gtt_run_mutated_cli "$mutant" "$sandbox" forge-pr-review-threads --pr 42 >/dev/null || true
  assert_contains "review-comments" "$(gtt_tea_argv "$sandbox")" "gtt mutation (resolve): the LISTING verb still reaches tea under this mutation -- the unrouting is scoped to one verb"

  rm -f "$mutant" "$stderr_file"
  teardown_forge_cli_sandbox "$sandbox"
  gtt_teardown_repo
}

# ============================================================================
# Forge Dispatch-Order Tests (phase 1.1 US-006)
# ============================================================================
# Every forge-* verb used to be dispatched from main()'s SECOND case block --
# the one that runs after find_aimi_root. find_aimi_root does two things: it
# hard-exits when no .aimi/ exists anywhere up the tree, and it cd's the
# process into the .aimi/ parent. Both were load-bearing failures for verbs
# that need neither: nothing about opening or reading a pull request touches
# .aimi/ state, and in a multi-repo layout the .aimi/ parent is not even a git
# repository, so the cd actively moved the process OUT of the repo the caller
# was standing in. These tests pin the ten verbs into the pre-find_aimi_root
# "Skip auto-discovery" block, and pin the two consequences of living there:
# each verb must call check_jq itself (main()'s single check_jq also sits
# after find_aimi_root), and a stray --help now reaches the verb's own arg
# parser instead of the universal --help intercept.

# Creates a plain git repository in its own temp dir with a github.com origin
# remote and exactly one commit, and deliberately NO .aimi/ directory -- not
# in the repo, not anywhere in its parent chain. This is the resolve-pr-
# parallel / get-pr-comments scenario: a caller that legitimately has no aimi
# project at all. Sets FORGE_NO_AIMI_FIXTURE_DIR; caller must teardown.
setup_forge_no_aimi_dir_fixture() {
  FORGE_NO_AIMI_FIXTURE_DIR=$(mktemp -d)

  pushd "$FORGE_NO_AIMI_FIXTURE_DIR" >/dev/null
  git init >/dev/null 2>&1
  git checkout -b main >/dev/null 2>&1
  git remote add origin https://github.com/octocat/hello-world.git
  echo "init" > README.md
  git add README.md
  git commit -m "Initial commit" >/dev/null 2>&1
  popd >/dev/null
}

# Removes the temp directory created by setup_forge_no_aimi_dir_fixture
teardown_forge_no_aimi_dir_fixture() {
  rm -rf "$FORGE_NO_AIMI_FIXTURE_DIR"
  unset FORGE_NO_AIMI_FIXTURE_DIR
}

# Walks from <dir> up to the filesystem root and prints the first parent that
# owns a .aimi/ directory, or nothing when the whole chain is clean. Used to
# prove setup_forge_no_aimi_dir_fixture really is .aimi-free before a test
# reads anything into a passing detect-forge call -- a stray /tmp/.aimi on a
# developer's machine would otherwise make this section silently vacuous.
_first_aimi_owner_above() {
  local dir="$1" parent
  while true; do
    [ -d "$dir/.aimi" ] && { printf '%s' "$dir"; return 0; }
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && return 0
    dir="$parent"
  done
}

# Prints the first executed statement of a shell function defined at column 0
# in aimi-cli.sh -- blank lines and comment lines skipped, leading whitespace
# stripped. Used to assert check_jq is genuinely FIRST, not merely present
# somewhere in the body.
_first_statement_of_cli_function() {
  local fn="$1"
  # Exact string compare on the header line rather than a regex -- awk's -v
  # assignment applies its own escape processing, which silently mangles a
  # backslash-escaped "() {" into a regex that matches nothing at all.
  awk -v hdr="${fn}() {" '
    !infn && $0 == hdr { infn = 1; next }
    infn {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "" || line ~ /^#/) next
      print line
      exit
    }
  ' "$CLI"
}

# The ten verbs this story moves, as "<cli-verb> <function-name>" pairs.
_FORGE_DISPATCH_VERBS=(
  "detect-forge cmd_detect_forge"
  "forge-auth-status cmd_forge_auth_status"
  "forge-repo-info cmd_forge_repo_info"
  "forge-pr-view cmd_forge_pr_view"
  "forge-pr-create cmd_forge_pr_create"
  "forge-pr-edit cmd_forge_pr_edit"
  "forge-issue-view cmd_forge_issue_view"
  "forge-issue-create cmd_forge_issue_create"
  "forge-pr-review-threads cmd_forge_pr_review_threads"
  "forge-resolve-review-thread cmd_forge_resolve_review_thread"
)

test_forge_verbs_run_without_any_aimi_dir() {
  echo ""
  echo "=== forge verbs: a git repo with NO .aimi/ anywhere up the tree still gets a JSON envelope ==="

  setup_forge_no_aimi_dir_fixture

  local stray_owner
  stray_owner=$(_first_aimi_owner_above "$FORGE_NO_AIMI_FIXTURE_DIR")
  assert_eq "" "$stray_owner" "no-aimi fixture: no .aimi/ owner anywhere up the parent chain (fixture is genuinely aimi-free)"

  pushd "$FORGE_NO_AIMI_FIXTURE_DIR" >/dev/null

  local out exit_code
  out=$("$CLI" detect-forge 2>&1) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "detect-forge no-aimi: exits 0 (was exit 1 'aimi/ directory not found in any parent directory')"
  assert_eq "github" "$(printf '%s' "$out" | jq -r '.forge')" "detect-forge no-aimi: resolves the repo's own forge"
  assert_eq "origin" "$(printf '%s' "$out" | jq -r '.remote')" "detect-forge no-aimi: resolves the repo's own remote"

  # forge-pr-review-threads is the verb get-pr-comments actually calls -- the
  # probe that opened this story. It degrades (no gh session here), but it
  # must degrade through the CONTRACT envelope, not through find_aimi_root.
  local threads_out threads_exit no_gh_path
  no_gh_path=$(_path_without_binary gh)
  threads_out=$(PATH="$no_gh_path" "$CLI" forge-pr-review-threads --pr 1 --owner o --repo r 2>&1) && threads_exit=0 || threads_exit=$?

  assert_exit_code "0" "$threads_exit" "forge-pr-review-threads no-aimi: exits 0 (query verb degrades through its envelope)"
  assert_eq "error" "$(printf '%s' "$threads_out" | jq -r '.status')" "forge-pr-review-threads no-aimi: status is error (gh absent), not a bare find_aimi_root exit"
  assert_eq "cli_missing" "$(printf '%s' "$threads_out" | jq -r '.reason')" "forge-pr-review-threads no-aimi: reason is cli_missing -- a parseable envelope, which is the whole point"

  # Control: a verb that DOES touch .aimi/ state must still fail here. The
  # move must not have weakened auto-discovery for anything but the ten.
  local control_out control_exit
  control_out=$("$CLI" find-tasks 2>&1) && control_exit=0 || control_exit=$?
  assert_exit_code "1" "$control_exit" "control: find-tasks still exits 1 without .aimi/ (auto-discovery unchanged for non-forge verbs)"
  assert_contains ".aimi/ directory not found" "$control_out" "control: find-tasks still reports the .aimi-not-found error"

  rm -rf "$no_gh_path"
  popd >/dev/null
  teardown_forge_no_aimi_dir_fixture
}

test_forge_repo_info_multi_repo_child_without_project() {
  echo ""
  echo "=== forge-repo-info: multi-repo child repo, no --project -- resolves the CHILD, not the .aimi parent ==="

  setup_multi_repo_default_branch_fixture

  # cd DIRECTLY into the child repo. Never pushd through
  # MULTI_REPO_FIXTURE_ROOT (the non-git .aimi/ owner) -- the whole point is
  # that the invoking cwd, not find_aimi_root's cd target, decides the repo.
  pushd "$MULTI_REPO_FIXTURE_A" >/dev/null

  local remote_url expected_path expected_owner expected_repo
  remote_url=$(git remote get-url origin)
  expected_path="${remote_url#/}"
  expected_owner="${expected_path%/*}"
  expected_repo="${expected_path##*/}"

  local out exit_code
  out=$("$CLI" forge-repo-info 2>&1) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "repo-info multi-repo child: exits 0 (was exit 1 'Not a git repository' after find_aimi_root cd'd to the non-git parent)"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "repo-info multi-repo child: status is found"
  assert_eq "$expected_owner" "$(printf '%s' "$out" | jq -r '.data.owner')" "repo-info multi-repo child: owner comes from the CHILD's own origin remote"
  assert_eq "$expected_repo" "$(printf '%s' "$out" | jq -r '.data.repo')" "repo-info multi-repo child: repo comes from the CHILD's own origin remote"

  # Structural companion to the output assertions: the verb resolved a repo
  # the .aimi-owning parent does not even have (the parent is not a git repo
  # at all), and it left the caller's own working directory untouched.
  assert_eq "$MULTI_REPO_FIXTURE_A" "$(pwd)" "repo-info multi-repo child: caller's working directory is still the child repo after the call returns"

  local parent_is_git
  (cd "$MULTI_REPO_FIXTURE_ROOT" && git rev-parse --git-dir >/dev/null 2>&1) && parent_is_git=yes || parent_is_git=no
  assert_eq "no" "$parent_is_git" "repo-info multi-repo child: the .aimi-owning parent is genuinely not a git repo (fixture pins the scenario)"

  popd >/dev/null
  teardown_multi_repo_default_branch_fixture
}

test_forge_verbs_dispatched_before_find_aimi_root() {
  echo ""
  echo "=== forge verbs: all ten case arms live in main()'s pre-find_aimi_root skip-list block ==="

  local pre_block post_block entry verb fn
  pre_block=$(awk '/^main\(\) \{$/ { infn = 1 } infn && /^  find_aimi_root$/ { exit } infn' "$CLI")
  post_block=$(awk '/^  find_aimi_root$/ { infn = 1 } infn' "$CLI")

  for entry in "${_FORGE_DISPATCH_VERBS[@]}"; do
    verb="${entry%% *}"
    fn="${entry##* }"

    if printf '%s\n' "$pre_block" | grep -qE "^[[:space:]]*${verb}\)[[:space:]]*shift;[[:space:]]*${fn} \"\\\$@\";[[:space:]]*return[[:space:]]*;;"; then
      echo -e "${GREEN}✓${NC} dispatch order: $verb is in the pre-find_aimi_root block, ending in '; return ;;'"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} dispatch order: $verb must live in the pre-find_aimi_root block as '$verb) shift; $fn \"\$@\"; return ;;'"
      ((TESTS_FAILED++))
    fi

    if printf '%s\n' "$post_block" | grep -qE "^[[:space:]]*${verb}\)"; then
      echo -e "${RED}✗${NC} dispatch order: $verb must NOT remain in the post-find_aimi_root block (duplicate case labels are silently shadowed by the first match)"
      ((TESTS_FAILED++))
    else
      echo -e "${GREEN}✓${NC} dispatch order: $verb has no leftover arm in the post-find_aimi_root block"
      ((TESTS_PASSED++))
    fi
  done
}

test_forge_verbs_call_check_jq_first() {
  echo ""
  echo "=== forge verbs: each wrapper opens with check_jq (main()'s own check_jq is behind find_aimi_root) ==="

  local entry fn first
  for entry in "${_FORGE_DISPATCH_VERBS[@]}"; do
    fn="${entry##* }"
    first=$(_first_statement_of_cli_function "$fn")
    assert_eq "check_jq" "$first" "check_jq first: $fn's first executed statement is check_jq"
  done

  # Runtime proof, in the scenario where main()'s check_jq no longer runs at
  # all: no .aimi/ anywhere AND jq genuinely absent from PATH. Without the
  # in-function guard this surfaces a raw jq-not-found from deep inside a
  # `jq -nc` call instead of the friendly install hint.
  setup_forge_no_aimi_dir_fixture
  pushd "$FORGE_NO_AIMI_FIXTURE_DIR" >/dev/null

  local no_jq_path stderr_file="/tmp/forge_no_jq_stderr.$$" exit_code
  no_jq_path=$(_path_without_binary jq)
  PATH="$no_jq_path" "$CLI" forge-auth-status >/dev/null 2>"$stderr_file" && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "check_jq runtime (no .aimi, no jq): forge-auth-status exits 1"
  assert_stderr_contains "Error: jq is required but not installed." "$(cat "$stderr_file")" "check_jq runtime (no .aimi, no jq): friendly guard message, not a raw jq-not-found"

  rm -f "$stderr_file"
  rm -rf "$no_jq_path"
  popd >/dev/null
  teardown_forge_no_aimi_dir_fixture

  # Same guard still fires with an .aimi/ present, proving the in-function
  # call did not merely duplicate main()'s -- it replaced it for these verbs.
  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local aimi_no_jq_path aimi_stderr_file="/tmp/forge_no_jq_aimi_stderr.$$" aimi_exit_code
  aimi_no_jq_path=$(_path_without_binary jq)
  PATH="$aimi_no_jq_path" "$CLI" forge-auth-status >/dev/null 2>"$aimi_stderr_file" && aimi_exit_code=0 || aimi_exit_code=$?

  assert_exit_code "1" "$aimi_exit_code" "check_jq runtime (.aimi present, no jq): forge-auth-status exits 1"
  assert_stderr_contains "Error: jq is required but not installed." "$(cat "$aimi_stderr_file")" "check_jq runtime (.aimi present, no jq): friendly guard message survives the dispatch move"

  rm -f "$aimi_stderr_file"
  rm -rf "$aimi_no_jq_path"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_verb_stray_help_flag_parity() {
  echo ""
  echo "=== forge verbs: a stray --help now reaches the verb's own parser (accepted parity change) ==="

  # ACCEPTED, DELIBERATE parity change: main()'s universal --help-anywhere-in-
  # args loop runs strictly AFTER the skip-list case returns, so a verb that
  # lives in that block never sees it. resolve-models/detect-models have
  # behaved exactly this way since they moved there; this test pins the forge
  # verbs to the SAME behavior so it cannot silently drift into a third one.
  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out exit_code
  out=$("$CLI" forge-repo-info --help 2>&1) && exit_code=0 || exit_code=$?

  assert_exit_code "1" "$exit_code" "forge-repo-info --help: exits non-zero (no longer intercepted by the universal --help loop)"
  assert_contains "unknown flag: --help" "$out" "forge-repo-info --help: surfaces the verb's own unknown-flag error"

  if printf '%s' "$out" | grep -q 'aimi-cli.sh - Deterministic'; then
    echo -e "${RED}✗${NC} forge-repo-info --help: must NOT print the general help banner"
    ((TESTS_FAILED++))
  else
    echo -e "${GREEN}✓${NC} forge-repo-info --help: does not print the general help banner"
    ((TESTS_PASSED++))
  fi

  popd >/dev/null
  teardown_detect_forge_fixture

  # The pre-existing precedent this parity change matches, asserted live
  # rather than in prose -- if detect-models ever regains the universal
  # intercept, the forge verbs' behavior stops being "the same as its
  # neighbors" and this section needs rethinking.
  local models_out models_exit
  models_out=$("$CLI" detect-models --help 2>&1) && models_exit=0 || models_exit=$?
  assert_exit_code "1" "$models_exit" "detect-models --help: pre-existing precedent -- also exits non-zero"
  assert_contains "unknown flag: --help" "$models_out" "detect-models --help: pre-existing precedent -- also surfaces its own unknown-flag error"
}

# ============================================================================
# Forge Derivation Memo + PR-View Probe-Order Tests (phase 1.1 US-010)
# ============================================================================
# Two independent changes, measured independently because they do NOT
# compound: the per-project-dir forge memo behind _detect_forge_type, and the
# inverted gh pr list / gh pr view order in _forge_pr_view_github. For the
# full forge-pr-create create-succeeds flow specifically the aggregate
# gh-call count is UNCHANGED by the reordering alone (the existing-PR check
# drops 2 to 1, the post-create re-read rises 1 to 2, exactly offsetting);
# that flow's win comes entirely from the memo. Every count below is read
# from a counter or log file, never asserted as "fewer".

# Sources _detect_forge_type and everything it reaches into THIS process, so
# the memo it populates is observable across calls -- the whole point of the
# isolation test below. Follows source_cache_functions's eval-by-sed-range
# pattern, and eval's the memo's own `declare -gA` line straight out of the
# source rather than hand-redeclaring it here, so the test can never disagree
# with the file about what that array is.
source_detect_forge_type_functions() {
  eval "$(sed -n '/^_detect_forge_parse_host()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_detect_forge_classify_host()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_detect_forge_select_remote_raw()/,/^}/p' "$CLI")"
  eval "$(sed -n '/^_detect_forge_read_selection()/,/^}/p' "$CLI")"
  eval "$(grep '^declare -gA _DETECT_FORGE_TYPE_MEMO' "$CLI")"
  eval "$(sed -n '/^_detect_forge_type()/,/^}/p' "$CLI")"
}

# Replaces <dir>/git with a wrapper that appends every `git remote ...`
# invocation's arguments to <counter> and then exec's through to the REAL
# git, unchanged. git's real absolute path is resolved BEFORE the wrapper is
# written -- the same reason _path_without_binary resolves real paths first
# rather than trusting PATH from inside a directory it is itself shadowing --
# so the wrapper can never recurse into itself. Every other git invocation in
# the flow (rev-parse --git-dir, checkout, commit, ...) passes straight
# through and is not counted.
#
# <dir> is expected to be a setup_forge_cli_sandbox, whose `git` is a symlink
# to the real binary; the rm is what keeps `cat >` from following that
# symlink and trying to overwrite git itself.
setup_git_remote_counter_shim() {
  local dir="$1" counter="$2" real_git
  real_git=$(command -v git)
  : > "$counter"
  rm -f "$dir/git"
  cat > "$dir/git" << GIT_COUNTER_SHIM
#!/usr/bin/env bash
if [ "\$1" = "remote" ]; then
  printf '%s\n' "\$*" >> "$counter"
fi
exec "$real_git" "\$@"
GIT_COUNTER_SHIM
  chmod +x "$dir/git"
}

test_detect_forge_type_never_builds_or_parses_json() {
  echo ""
  echo "=== _detect_forge_type: no jq token anywhere on its own path (AC1) ==="

  # The whole point of the function is that the forge word costs no JSON
  # round trip. _detect_forge, by contrast, builds its envelope with jq -nc
  # -- so this grep is what distinguishes the new path from the old one
  # rather than merely asserting it is faster.
  local fn body
  for fn in _detect_forge_type _detect_forge_read_selection _detect_forge_select_remote_raw \
            _detect_forge_parse_host _detect_forge_classify_host; do
    body=$(sed -n "/^$fn()/,/^}/p" "$CLI" | grep -v '^\s*#')
    if [ -z "$body" ]; then
      echo -e "${RED}✗${NC} _detect_forge_type jq-free: $fn is not defined in $CLI"
      ((TESTS_FAILED++))
      continue
    fi
    if printf '%s' "$body" | grep -q "jq"; then
      echo -e "${RED}✗${NC} _detect_forge_type jq-free: $fn's body contains a jq token"
      ((TESTS_FAILED++))
    else
      echo -e "${GREEN}✓${NC} _detect_forge_type jq-free: $fn's body contains no jq token"
      ((TESTS_PASSED++))
    fi
  done

  # ...and the control: the function this one exists to avoid DOES use jq,
  # so the grep above is proven capable of failing.
  #
  # COUNTED, like every other scan in this suite -- but for the opposite
  # reason, and calling this one fail-open would be a fresh false claim
  # replacing an old one. Its polarity is INVERTED: here a match is the GREEN
  # case. So when `grep -q` short-circuits and SIGPIPEs its feeder, this
  # assertion goes RED on a tree that is perfectly fine. It fails CLOSED --
  # spurious failure, not a spurious pass. That is the benign direction, and
  # it is still worth removing: a control that can cry wolf gets ignored, and
  # then the five assertions it underwrites stop meaning anything.
  #
  # It also cannot be proven by planting, since the property it checks is
  # already true. It was proven instead by temporarily retargeting the `sed`
  # range below at `_detect_forge_type()` -- the function the loop just above
  # proved jq-free -- which turned this control red, and then reverting.
  #
  # assert_eq cannot express "> 0", so the count is mapped to a verdict word
  # first and the word is what gets compared.
  local control_jq_hits control_verdict="absent"
  control_jq_hits=$(sed -n '/^_detect_forge()/,/^}/p' "$CLI" | grep -v '^\s*#' | grep -c "jq") || control_jq_hits=0
  if [ "$control_jq_hits" -gt 0 ]; then
    control_verdict="present"
  fi
  assert_eq "present" "$control_verdict" \
    "_detect_forge_type jq-free: control -- _detect_forge itself does use jq, so the grep can fail"
}

test_detect_forge_type_matches_detect_forge_across_fixtures() {
  echo ""
  echo "=== _detect_forge_type: agrees with detect-forge's own .forge on every fixture scenario (AC1) ==="

  source_detect_forge_type_functions

  # Every scenario the detect-forge suite above pins, run through BOTH the
  # new jq-free path (in-process) and the shipped `detect-forge | jq -r
  # .forge` path (subprocess), asserting they agree. This is what keeps the
  # new function from becoming a second, silently-diverging implementation of
  # the same precedence rules. Each case gets its OWN fixture directory, so
  # no case can be answered out of the memo a previous case populated.
  #
  # Format: <label>|<expected>|<remote-name> <remote-url> [<name> <url> ...]
  local cases=(
    "https github|github|origin https://github.com/o/r.git"
    "scp-like ssh github|github|origin git@github.com:o/r.git"
    "explicit ssh:// gitlab|gitlab|origin ssh://git@gitlab.com/o/r.git"
    "alternate-port ssh|github|origin ssh://git@github.com:2222/o/r.git"
    "gitea host|gitea|origin https://gitea.com/o/r.git"
    "codeberg is gitea|gitea|origin https://codeberg.org/o/r.git"
    "github subdomain|github|origin git@ssh.github.com:o/r.git"
    "lookalike suffix|unknown|origin https://notgithub.com/o/r.git"
    "lookalike prefix|unknown|origin https://github.com.evil.example/o/r.git"
    "origin wins over disagreement|github|origin https://github.com/o/r.git upstream https://gitlab.com/o/r.git"
    "single non-origin remote|gitlab|fork https://gitlab.com/o/r.git"
    "ambiguous remotes|unknown|alpha https://github.com/o/r.git beta https://gitlab.com/o/r.git"
    "zero remotes|unknown|"
  )

  local case_entry label expected remotes direct subprocess
  for case_entry in "${cases[@]}"; do
    IFS='|' read -r label expected remotes <<< "$case_entry"

    # shellcheck disable=SC2086 -- $remotes is a deliberate name/url word split
    setup_detect_forge_fixture $remotes
    pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

    direct=""
    _detect_forge_type direct
    subprocess=$("$CLI" detect-forge | jq -r '.forge')

    assert_eq "$expected" "$direct" "detect-forge parity ($label): _detect_forge_type resolves $expected"
    assert_eq "$subprocess" "$direct" "detect-forge parity ($label): the jq-free path agrees with detect-forge's own .forge"

    popd >/dev/null
    teardown_detect_forge_fixture
  done

  # The AIMI_FORGE_TYPE override, which short-circuits both paths before any
  # git command runs at all.
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null
  export AIMI_FORGE_TYPE=gitea
  direct=""
  _detect_forge_type direct
  subprocess=$("$CLI" detect-forge | jq -r '.forge')
  unset AIMI_FORGE_TYPE
  assert_eq "gitea" "$direct" "detect-forge parity (AIMI_FORGE_TYPE override): override wins over the github remote"
  assert_eq "$subprocess" "$direct" "detect-forge parity (AIMI_FORGE_TYPE override): both paths honor it identically"
  popd >/dev/null
  teardown_detect_forge_fixture
}

test_detect_forge_type_memo_is_keyed_per_project_dir() {
  echo ""
  echo "=== _detect_forge_type: the memo is keyed on the project dir -- two sibling repos, ONE process, two independent answers (AC2) ==="

  # THE TEST THE REVIEW DEMANDED. Phase 1 deliberately does not cache
  # detect-forge, and the reason is that sibling repositories under one
  # multi-repo root must not leak forges into each other. A memo keyed on the
  # resolved project directory preserves that; a global one silently destroys
  # it. Everything below runs in THIS process -- no $CLI subprocess, no fork
  # -- because a memo populated in a subshell would die with it and a global
  # memo would then look indistinguishable from a keyed one.
  source_detect_forge_type_functions
  # Start from an empty memo: the parity test above runs in this same process
  # and leaves its own per-fixture entries behind, which would make the entry
  # COUNT asserted below meaningless. Re-eval'ing the `declare -gA` line does
  # not clear an already-populated array, so clear it explicitly.
  _DETECT_FORGE_TYPE_MEMO=()
  setup_detect_forge_multirepo_fixture

  local repo_a="$DETECT_FORGE_MULTIREPO_DIR/repo-a"
  local repo_b="$DETECT_FORGE_MULTIREPO_DIR/repo-b"
  local first="" second="" third=""

  pushd "$repo_a" >/dev/null
  _detect_forge_type first
  popd >/dev/null

  pushd "$repo_b" >/dev/null
  _detect_forge_type second
  popd >/dev/null

  # Back to repo-a, which by now has been visited before AND has had a
  # different repo classified in between. A single-slot memo answers gitlab
  # here; a cwd-keyed one answers github.
  pushd "$repo_a" >/dev/null
  _detect_forge_type third
  popd >/dev/null

  assert_eq "github" "$first"  "memo isolation: repo-a's own forge, first visit"
  assert_eq "gitlab" "$second" "memo isolation: repo-b answers gitlab in the SAME process -- repo-a's answer did not leak into it"
  assert_eq "github" "$third"  "memo isolation: returning to repo-a still reads github -- the memo did not degrade into 'whichever repo was classified most recently'"

  # A memo that is keyed but never actually populated would pass every
  # assertion above while doing all three derivations for real. Reading the
  # array directly is what pins BOTH halves: two entries (so it memoized at
  # all) under the two repositories' own paths (so it memoized per-directory).
  assert_eq "2" "${#_DETECT_FORGE_TYPE_MEMO[@]}" "memo isolation: exactly two memo entries -- one per project dir visited, not one global slot"
  assert_eq "github" "${_DETECT_FORGE_TYPE_MEMO[$repo_a]:-MISSING}" "memo isolation: the memo entry keyed on repo-a's own path holds github"
  assert_eq "gitlab" "${_DETECT_FORGE_TYPE_MEMO[$repo_b]:-MISSING}" "memo isolation: the memo entry keyed on repo-b's own path holds gitlab"

  teardown_detect_forge_multirepo_fixture
  unset _DETECT_FORGE_TYPE_MEMO
}

test_forge_pr_create_derives_forge_once_per_process() {
  echo ""
  echo "=== forge-pr-create: a full create-a-new-PR run derives the forge ONCE, measured by a git-remote counter (AC3) ==="

  setup_detect_forge_fixture origin https://github.com/owner/repo.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local sandbox
  sandbox=$(setup_forge_cli_sandbox)
  trap "teardown_forge_cli_sandbox '$sandbox'" RETURN

  local counter="$sandbox/git-remote-calls.log"
  setup_git_remote_counter_shim "$sandbox" "$counter"

  # Same shape as test_forge_pr_create_new_pr's fixture: no PR before
  # creation, the created PR visible to both gh pr list and gh pr view
  # afterward, so the run takes the full create-succeeds path (pre-create
  # existing-PR check -> gh pr create -> post-create re-read confirms found).
  cat > "$sandbox/gh" << 'FAKE_GH'
#!/usr/bin/env bash
FLAG="$(dirname "$0")/pr_created.flag"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -f "$FLAG" ]; then
    echo '{"url":"https://github.com/owner/repo/pull/101","number":101}'
    exit 0
  fi
  echo "no pull requests found for branch" >&2
  exit 1
fi
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  if [ -f "$FLAG" ]; then echo '[{"number":101}]'; else echo '[]'; fi
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
  : > "$FLAG"
  echo "https://github.com/owner/repo/pull/101"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 99
FAKE_GH
  chmod +x "$sandbox/gh"

  local out exit_code
  out=$(PATH="$sandbox" "$CLI" forge-pr-create --title "My PR" --base main --head feat-x --body "the body") && exit_code=0 || exit_code=$?

  # The run must genuinely have taken the create-succeeds path -- a counter
  # of 1 would also be what a run that failed early produced.
  assert_exit_code "0" "$exit_code" "forge derivation count: the measured run exits 0"
  assert_eq '{"status":"created","data":{"url":"https://github.com/owner/repo/pull/101","number":101},"message":null}' \
    "$out" "forge derivation count: the measured run really did create a PR and confirm its number"

  # A bare `git remote` (the remote LISTING call) is made exactly once per real
  # derivation, and this run makes exactly TWO derivations -- no more.
  #
  #   1. _detect_forge_type's, memoized in _DETECT_FORGE_TYPE_MEMO. Before
  #      phase 1.1 this alone read 3 (_forge_pr_create's own call, plus
  #      cmd_forge_pr_view's during the pre-create existing-PR check and again
  #      during the post-create re-read, none aware the others had run); the
  #      memo collapsed the second and third into zero-git-work hits.
  #   2. _forge_account_host_cached's, memoized in _FORGE_ACCOUNT_HOST_MEMO and
  #      added by the phase-2 routing pass. The account override is keyed by
  #      host, and _detect_forge_type carries no host at all (its own header
  #      says so), so the host is a genuinely separate question.
  #
  # THE NUMBER 2 IS THE POINT, and 3 is the failure this pins: the routing pass
  # asks _forge_account_override for BOTH token slots, and each call would
  # derive the host for itself if _forge_account_override_slots did not warm the
  # memo from the caller's own shell first -- a memo populated inside either
  # `$(...)` lookup would die with that subshell. The three cmd_forge_pr_view
  # calls this run makes still contribute nothing at all.
  local bare_remote_calls all_remote_calls geturl_calls
  bare_remote_calls=$(grep -cx 'remote' "$counter") || bare_remote_calls=0
  all_remote_calls=$(grep -c '^remote' "$counter") || all_remote_calls=0
  geturl_calls=$(grep -c '^remote get-url' "$counter") || geturl_calls=0

  assert_eq "2" "$bare_remote_calls" "forge derivation count: exactly 2 real derivations -- the forge word and the account host, each derived ONCE (3 would mean the two token slots each derived the host for themselves)"
  assert_eq "2" "$geturl_calls" "forge derivation count: one get-url per derivation, never a third"
  assert_eq "4" "$all_remote_calls" "forge derivation count: 4 git-remote-family calls total -- one listing plus one get-url per derivation (was 6 before the phase-1.1 memo, with no host derivation at all)"

  popd >/dev/null
  teardown_detect_forge_fixture
}

test_forge_pr_view_not_found_branch_ref_costs_one_gh_call() {
  echo ""
  echo "=== forge-pr-view: a not-found branch ref costs exactly ONE gh call -- pr list alone, pr view never invoked (AC4) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log_file="$FAKE_GH_DIR/call.log"
  : > "$log_file"

  # FAKE_GH_VIEW_* is deliberately left at its default (a SUCCESSFUL pr view
  # returning '{}'), so if pr view were still being called first this lookup
  # would come back `found` and the status assertion would fail loudly rather
  # than the call count quietly drifting.
  local out
  out=$(FAKE_GH_LOG="$log_file" FAKE_GH_LIST_JSON='[]' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url)

  assert_eq "not_found" "$(printf '%s' "$out" | jq -r '.status')" "gh call count (not_found): absence is confirmed structurally by the list probe"
  assert_contains "feat-x" "$(printf '%s' "$out" | jq -r '.message')" "gh call count (not_found): message still names the searched ref"

  local total list_calls view_calls
  total=$(wc -l < "$log_file" | tr -d ' ')
  list_calls=$(grep -c '^pr list' "$log_file") || list_calls=0
  view_calls=$(grep -c '^pr view' "$log_file") || view_calls=0

  # BEFORE this story: 2 -- a failing pr view followed by the confirming pr
  # list. AFTER: 1.
  assert_eq "1" "$total"      "gh call count (not_found): exactly 1 gh invocation total (was 2 before this story)"
  assert_eq "1" "$list_calls" "gh call count (not_found): that one call is gh pr list"
  assert_eq "0" "$view_calls" "gh call count (not_found): gh pr view is never invoked at all"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_found_branch_ref_costs_two_gh_calls_list_then_view() {
  echo ""
  echo "=== forge-pr-view: a FOUND branch ref costs two gh calls, pr list then pr view -- the accepted trade-off (AC4) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log_file="$FAKE_GH_DIR/call.log"
  : > "$log_file"

  local out
  out=$(FAKE_GH_LOG="$log_file" FAKE_GH_LIST_JSON='[{"number":7}]' \
    FAKE_GH_PR_JSON='{"url":"https://github.com/o/r/pull/7"}' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url)

  assert_eq '{"status":"found","pr":{"url":"https://github.com/o/r/pull/7"},"unsupported_fields":[],"message":null}' \
    "$out" "gh call count (found): the envelope is unchanged by the reordering"

  # DOCUMENTED, DELIBERATE TRADE-OFF, not a regression: a found branch-ref
  # lookup rises from 1 gh call to 2, buying the not-found path -- the
  # dominant case, since execute.md's per-phase idempotency pre-check runs
  # this exact lookup on every phase close whether or not a PR exists yet --
  # a drop from 2 to 1.
  local total
  total=$(wc -l < "$log_file" | tr -d ' ')
  assert_eq "2" "$total" "gh call count (found): exactly 2 gh invocations (was 1 before this story -- the accepted trade-off)"
  assert_eq "pr list --head feat-x --state all --json number" "$(sed -n '1p' "$log_file")" "gh call count (found): the probe runs FIRST"
  assert_eq "pr view feat-x --json url" "$(sed -n '2p' "$log_file")" "gh call count (found): pr view runs SECOND, to fetch the fields the probe cannot return"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

test_forge_pr_view_list_confirms_but_view_fails_is_error_never_not_found() {
  echo ""
  echo "=== forge-pr-view: list confirms the PR exists but pr view then fails -- status error, never not_found (AC5) ==="

  setup_fake_gh_fixture
  setup_detect_forge_fixture origin https://github.com/o/r.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local out

  # No existing test exercises this sequence: under the OLD call order pr
  # view always ran first, so "the probe already proved it exists, and then
  # the view failed" could not arise. It can now, on a transient failure or a
  # race between the two calls.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' \
    FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR="HTTP 502: upstream request timed out" \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url)

  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "three-way survival: a view failure after a confirming probe is error"
  assert_contains "HTTP 502" "$(printf '%s' "$out" | jq -r '.message')" "three-way survival: the message carries gh pr view's OWN stderr as evidence"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.pr')" "three-way survival: pr is null on error"

  # The sharper half of the same guarantee: gh pr view failing with gh's own
  # NOT-FOUND wording, while the probe has already structurally confirmed the
  # PR exists. A structural fact must outvote a text match -- otherwise the
  # stderr tier could still launder a confirmed-existing PR into not_found,
  # which is the exact conflation this verb exists to prevent.
  out=$(FAKE_GH_LIST_JSON='[{"number":7}]' \
    FAKE_GH_VIEW_EXIT=1 FAKE_GH_VIEW_STDERR='no pull requests found for branch "feat-x"' \
    PATH="$FAKE_GH_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include url)

  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "three-way survival: even gh's own not-found WORDING cannot outvote the probe's structural confirmation"

  popd >/dev/null
  teardown_detect_forge_fixture
  teardown_fake_gh_fixture
}

# ============================================================================
# Gitea READ-verb Routing Tests (phase 4 outline:02)
# ============================================================================
# Covers exactly three verbs -- forge-auth-status, forge-pr-view and
# forge-issue-view -- routing to `tea` when _detect_forge reports gitea, plus
# the deliberate NON-routing of forge-repo-info.
#
# EVERY helper this section introduces is prefixed `gtr_` (GiTea Read) and
# every control variable `GTR_TEA_*`. That is not decoration. Sibling stories
# in this same wave are editing this same file for the WRITE verbs (`gtw_`)
# and the REVIEW-THREAD verbs (`gtt_`), on branches none of us can see, and
# bash silently keeps the LAST definition of a duplicated function -- so
# three individually-green branches can merge into a red one. The phase-2
# founding incident: two wave-1 stories both defined
# source_forge_account_functions and six assertions failed with exit 127 only
# on the merge. The prefix, plus a PRIVATE fake-tea stub rather than an edit
# to outline:01's `gtm_` one, is what makes that collision structurally
# impossible rather than merely unlikely.
#
# WHY THE forge-auth-status TESTS LIVE IN PART 4 AND NOT PART 3, where every
# other forge-auth-status test sits: the dispatcher runs the parts
# CONCURRENTLY and part 3 IS the wall clock (40-46% of the serial total;
# measured concurrent wall time equals part 3's runtime to the second). A new
# assertion here costs ~nothing; in part 3 it extends the whole suite
# one-for-one. Phase 3's own read-verbs story made the same call for
# glr_test_forge_auth_status_gitlab. The one part-3 edit this story makes is
# the mandatory no-adapter retarget.
#
# DETECTION IS NOT UNDER TEST HERE AND IS NOT MODIFIED BY THIS STORY.
# _detect_forge_classify_host (aimi-cli.sh:1836) already answers `gitea` for
# gitea.com, *.gitea.com, codeberg.org and *.codeberg.org, and deliberately
# folds Forgejo under that single adapter word. Every fixture below simply
# relies on it.
#
# THE CONTROL FOR "a forge with NO adapter" MOVED, and had to. Three tests
# used `gitea` as that stand-in; routing gitea makes that premise false, so
# they were RETARGETED (never deleted -- the no_adapter path must stay
# covered) onto an unrecognized host that classifies as `unknown`:
# test_forge_auth_status_no_adapter_is_error (part 3),
# test_forge_pr_view_non_github_forge_quiet_degrade and
# test_forge_issue_view_non_github_forge_degrades (this file). This is the
# end of the line: AIMI_FORGE_TYPE validates only github|gitlab|gitea
# (aimi-cli.sh:2130), so after phase 4 no forge WORD is left to retarget to
# and `unknown` -- reachable solely through an unrecognized remote host -- is
# the only remaining control.
#
# `tea` is genuinely NOT INSTALLED on this machine. That is the phase's
# declared verification ceiling: the stub below is the only tea these tests
# ever see, and its payloads are modelled on `gitea/tea` `main` source read
# on 2026-08-06 rather than on a captured real-binary response. What these
# tests prove is WHICH ARGV aimi-cli.sh emits and HOW it parses a fixture --
# never what the real binary does with either. Where that under-verifies is
# the JSON key NAMES: the stub emits whatever the author believed, so a wrong
# key would pass green on both sides. The one criterion here testable against
# reality is the missing-binary degrade, and
# gtr_test_gitea_read_verbs_name_tea_when_binary_absent tests it.

# A fake `tea` covering the four invocations the three routed READ verbs make:
# `login list`, `pulls list`, `pulls <index>` and `issues <index>`.
#
# DELIBERATELY SEPARATE from outline:01's gtm_setup_fake_tea_fixture, which
# serves the two pull-request forms only. Extending that shared stub would put
# this story's edits on lines two sibling stories are editing right now; a
# private stub in a private variable namespace cannot collide with either.
#
# Written to a fresh temp dir and prepends nothing to PATH itself -- callers
# do `PATH="$GTR_TEA_DIR:$PATH" ...` per invocation. Driven entirely by
# GTR_TEA_* environment variables:
#   GTR_TEA_LOG            optional per-test file; every invocation's argv
#                          appended, one line per call -- lets an assertion
#                          prove WHICH flags were passed (`-o json` and tea's
#                          own `-f` selector, never a gh-style `--json`)
#   GTR_TEA_AUDIT          SECTION-WIDE argv log, created once and never torn
#                          down between tests, so a single counting query can
#                          state what was never invoked across the whole
#                          section (see gtr_test_tea_whoami_is_never_invoked)
#   GTR_TEA_LOGIN_JSON     `tea login list -o json` stdout (default '[]')
#   GTR_TEA_LOGIN_EXIT     its exit code (default 0)
#   GTR_TEA_LOGIN_COUNTER  path to a counter file bumped once per login call
#   GTR_TEA_PULL_JSON      `tea pulls <index> -o json` stdout (default '{}')
#   GTR_TEA_PULL_EXIT      its exit code (default 0)
#   GTR_TEA_PULL_STDERR    stderr emitted when that exit is non-zero
#   GTR_TEA_PULL_COUNTER   path to a counter file bumped once per detail call
#   GTR_TEA_LIST_JSON      `tea pulls list ... -o json` stdout (default '[]')
#   GTR_TEA_LIST_EXIT      its exit code (default 0)
#   GTR_TEA_LIST_COUNTER   path to a counter file bumped once per list call --
#                          this is what PROVES the probe was skipped for a
#                          numeric ref, which no exit status could show
#   GTR_TEA_ISSUE_JSON     `tea issues <index> -o json` stdout (default '{}')
#   GTR_TEA_ISSUE_EXIT     its exit code (default 0)
#   GTR_TEA_ISSUE_STDERR   stderr emitted when that exit is non-zero
#
# THE DEFAULT ARM EXITS 127 WITH A DIAGNOSTIC. That is load-bearing: `tea
# whoami` is a subcommand this adapter must never call (it round-trips the
# network and then discards its own error), and an unhandled invocation that
# quietly exited 0 would let such a call slip through green.
gtr_setup_fake_tea_read_fixture() {
  GTR_TEA_DIR=$(mktemp -d)
  # Created ONCE for the whole section and deliberately not torn down between
  # tests -- gtr_test_tea_whoami_is_never_invoked reads the accumulated log.
  if [ -z "${GTR_TEA_AUDIT:-}" ]; then
    GTR_TEA_AUDIT=$(mktemp)
    export GTR_TEA_AUDIT
  fi
  cat > "$GTR_TEA_DIR/tea" << 'GTR_FAKE_TEA_SCRIPT'
#!/usr/bin/env bash
[ -n "${GTR_TEA_AUDIT:-}" ] && printf '%s\n' "$*" >> "$GTR_TEA_AUDIT"
[ -n "${GTR_TEA_LOG:-}" ] && printf '%s\n' "$*" >> "$GTR_TEA_LOG"

gtr_tea_bump() {
  local file="$1" n
  [ -n "$file" ] || return 0
  n=$(cat "$file" 2>/dev/null || echo 0)
  printf '%s\n' "$((n + 1))" > "$file"
}

case "$1" in
  login)
    case "$2" in
      list)
        gtr_tea_bump "${GTR_TEA_LOGIN_COUNTER:-}"
        code="${GTR_TEA_LOGIN_EXIT:-0}"
        if [ "$code" != "0" ]; then
          echo "Error: could not read login list" >&2
          exit "$code"
        fi
        body="${GTR_TEA_LOGIN_JSON:-[]}"
        printf '%s' "$body"
        exit 0
        ;;
    esac
    ;;
  pulls)
    case "$2" in
      list)
        gtr_tea_bump "${GTR_TEA_LIST_COUNTER:-}"
        code="${GTR_TEA_LIST_EXIT:-0}"
        if [ "$code" != "0" ]; then
          echo "Error: could not list pulls" >&2
          exit "$code"
        fi
        body="${GTR_TEA_LIST_JSON:-[]}"
        printf '%s' "$body"
        exit 0
        ;;
      *)
        gtr_tea_bump "${GTR_TEA_PULL_COUNTER:-}"
        code="${GTR_TEA_PULL_EXIT:-0}"
        if [ "$code" != "0" ]; then
          printf '%s' "${GTR_TEA_PULL_STDERR:-Error: pulls failed}" >&2
          exit "$code"
        fi
        body="${GTR_TEA_PULL_JSON:-}"
        [ -z "$body" ] && body='{}'
        printf '%s' "$body"
        exit 0
        ;;
    esac
    ;;
  issues)
    case "$2" in
      list) ;;
      *)
        code="${GTR_TEA_ISSUE_EXIT:-0}"
        if [ "$code" != "0" ]; then
          printf '%s' "${GTR_TEA_ISSUE_STDERR:-Error: issues failed}" >&2
          exit "$code"
        fi
        body="${GTR_TEA_ISSUE_JSON:-}"
        [ -z "$body" ] && body='{}'
        printf '%s' "$body"
        exit 0
        ;;
    esac
    ;;
esac

echo "gtr-fake-tea: unhandled invocation: $*" >&2
exit 127
GTR_FAKE_TEA_SCRIPT
  chmod +x "$GTR_TEA_DIR/tea"
}

# Removes the private fake-tea temp dir and every GTR_TEA_* control variable
# EXCEPT GTR_TEA_AUDIT, which is section-scoped by design.
#
# It also deliberately does NOT touch AIMI_CONFIG_DIR: this section never sets
# it, and `unset AIMI_CONFIG_DIR` here would hand the rest of part 4 back to
# the developer's real ~/.config/aimi -- the one cross-part shared resource
# the concurrency audit found.
gtr_teardown_fake_tea_read_fixture() {
  rm -rf "$GTR_TEA_DIR"
  unset GTR_TEA_DIR GTR_TEA_LOG \
    GTR_TEA_LOGIN_JSON GTR_TEA_LOGIN_EXIT GTR_TEA_LOGIN_COUNTER \
    GTR_TEA_PULL_JSON GTR_TEA_PULL_EXIT GTR_TEA_PULL_STDERR GTR_TEA_PULL_COUNTER \
    GTR_TEA_LIST_JSON GTR_TEA_LIST_EXIT GTR_TEA_LIST_COUNTER \
    GTR_TEA_ISSUE_JSON GTR_TEA_ISSUE_EXIT GTR_TEA_ISSUE_STDERR
}

# A realistic `tea pulls <index> -o json` DETAIL document (cmd/pulls.go:29-52's
# `pullData`). Load-bearing properties, not to be "tidied" away:
#   - `id` (98765) DIFFERS from `index` (42), so an implementation reading id
#     produces a visibly wrong number rather than an accidental pass.
#   - `index` is a JSON NUMBER and `mergeable`/`hasMerged` are real BOOLEANS.
#   - `head`/`base` are BARE refs -- no owner: prefix, unlike the LIST shape.
gtr_tea_pull_detail_json() {
  printf '%s' '{
    "id": 98765,
    "index": 42,
    "title": "Add the Gitea adapter",
    "state": "open",
    "created": "2026-08-01T09:00:00Z",
    "updated": "2026-08-02T09:00:00Z",
    "labels": [],
    "user": "octotea",
    "body": "Body text of the pull request.",
    "assignees": [],
    "url": "https://gitea.com/acme/widgets/pulls/42",
    "base": "main",
    "head": "feat-x",
    "headSha": "deadbeefcafe1234567890abcdefdeadbeefcafe",
    "diffUrl": "https://gitea.com/acme/widgets/pulls/42.diff",
    "mergeable": true,
    "hasMerged": false,
    "mergedAt": null,
    "closedAt": null,
    "reviews": [],
    "comments": []
  }'
}

# The SAME document with the pull request merged. tea's DETAIL `state` is
# pr.State raw -- `closed`, never `merged` (cmd/pulls.go:33) -- so the
# contract's "merged" can only come from the separate `hasMerged` boolean.
# An adapter that read `state` alone would report this as closed.
gtr_tea_pull_detail_merged_json() {
  printf '%s' '{
    "id": 98765,
    "index": 42,
    "title": "Add the Gitea adapter",
    "state": "closed",
    "url": "https://gitea.com/acme/widgets/pulls/42",
    "body": "Body text of the pull request.",
    "base": "main",
    "head": "feat-x",
    "mergeable": false,
    "hasMerged": true,
    "mergedAt": "2026-08-03T09:00:00Z",
    "closedAt": "2026-08-03T09:00:00Z"
  }'
}

# The SAME merged document with hasMerged flipped to false: state is still
# `closed`, so this is the half of the pair that must NOT read as merged. A
# separate fixture rather than an in-place string substitution, so the
# difference between the two is visible as data rather than hidden in a bash
# expansion.
gtr_tea_pull_detail_closed_json() {
  printf '%s' '{
    "id": 98765,
    "index": 42,
    "title": "Add the Gitea adapter",
    "state": "closed",
    "url": "https://gitea.com/acme/widgets/pulls/42",
    "body": "Body text of the pull request.",
    "base": "main",
    "head": "feat-x",
    "mergeable": false,
    "hasMerged": false,
    "mergedAt": null,
    "closedAt": "2026-08-03T09:00:00Z"
  }'
}

# A realistic `tea pulls list --state all -f index,head -o json` LIST document.
# Every value is a STRING and every key snake-cased (table.go:175-208), and
# `head` carries a CROSS-FORK `owner:branch` prefix (formatPRHead,
# print/pull.go:83-93). That prefix is the whole point: plain equality against
# the branch name would report an existing pull request as absent and invite a
# duplicate.
gtr_tea_pull_list_json() {
  printf '%s' '[
    {"index": "42", "head": "contributor:feat-x"}
  ]'
}

# The same LIST shape for a DIFFERENT contributor branch, so the cross-fork
# comparison is proven to discriminate rather than to match everything with a
# colon in it.
gtr_tea_pull_list_other_json() {
  printf '%s' '[
    {"index": "99", "head": "contributor:other"}
  ]'
}

# A realistic `tea issues <index> -o json` document (cmd/issues.go:25-38's
# `issueData`). Two load-bearing properties:
#   - `comments` is an EMPTY ARRAY. That is what tea returns when --comments
#     was NOT passed (cmd/issues.go:148-154), so deriving a count from its
#     length would report 0 for every issue in existence.
#   - `labels` mixes a plain STRING and a `{name}` OBJECT, so the either-shape
#     expression is exercised on both halves in one document.
gtr_tea_issue_json() {
  printf '%s' '{
    "id": 55501,
    "index": 7,
    "title": "Login button does nothing",
    "state": "open",
    "created": "2026-08-01T09:00:00Z",
    "labels": ["bug", {"name": "frontend"}],
    "user": "octotea",
    "body": "Steps to reproduce: click it.",
    "assignees": [],
    "url": "https://gitea.com/acme/widgets/issues/7",
    "closedAt": null,
    "comments": []
  }'
}

# A realistic `tea login list -o json` document (print/login.go:34-54): an
# array of ALL-STRING rows keyed name, url, ssh_host, user, default. It holds
# ONLY a gitea.com login, which is what makes the host-filter pair meaningful
# -- the identical payload must read as authenticated on a gitea.com fixture
# and as a definitive negative on a codeberg.org one.
gtr_tea_login_list_json() {
  printf '%s' '[
    {"name": "gitea", "url": "https://gitea.com", "ssh_host": "gitea.com", "user": "octotea", "default": "true"}
  ]'
}

# Two logins for the SAME host, the non-first one flagged default, so
# "prefers the default entry" is distinguishable from "takes entry zero".
gtr_tea_login_list_default_second_json() {
  printf '%s' '[
    {"name": "first", "url": "https://gitea.com", "ssh_host": "gitea.com", "user": "not-default", "default": "false"},
    {"name": "second", "url": "https://gitea.com/", "ssh_host": "gitea.com", "user": "the-default", "default": "true"}
  ]'
}

# Writes a copy of aimi-cli.sh to <dest> with ONE full line replaced, and
# prints `<changed|unchanged> <replaced-line-count>` so a caller can PROVE
# both that the mutation landed AND that it landed exactly once.
#
# The COUNT is the addition over phase 3's glr_mutate_cli, and it is now
# necessary rather than decorative: several gitea arms exist across this wave,
# so an anchor that also matched a sibling story's arm would silently unroute
# three verbs at once and make the matrix prove less than it claims. Exact
# full-line comparison (awk `$0 == a`), never a regex.
# Usage: gtr_mutate_cli <exact-line> <replacement-line> <dest>
gtr_mutate_cli() {
  local anchor="$1" replacement="$2" dest="$3" count_file count verdict
  count_file=$(mktemp)
  awk -v a="$anchor" -v r="$replacement" -v cf="$count_file" \
    '$0 == a { print r; n++; next } { print } END { printf "%d\n", n+0 > cf }' "$CLI" > "$dest"
  chmod +x "$dest"
  count=$(cat "$count_file")
  rm -f "$count_file"
  if cmp -s "$CLI" "$dest"; then
    verdict="unchanged"
  else
    verdict="changed"
  fi
  printf '%s %s' "$verdict" "$count"
}

# Counts credential BINDINGS -- prefix assignments and exports of the three
# variables `tea` reads for authentication -- in a given file.
#
# COUNTED WITH `grep -c`, AND THAT IS NOT A STYLE CHOICE. This suite runs
# under `set -o pipefail`. In the `grep -v ... | grep -q ...` shape the right
# half exits the instant it matches, SIGPIPEs the left half, and the pipeline
# reports FAILURE -- so an `if` on it reads a real hit as "no hit" and the
# guard fails OPEN. `grep -c` consumes all of its input and cannot fire early;
# the trailing `|| count=0` absorbs grep's exit 1 on zero matches.
#
# WHY THESE THREE NAMES: tea honours GH_TOKEN, not only GITEA_TOKEN, whenever
# GITEA_INSTANCE_URL is also set (modules/context/context_login.go:15-51).
# _forge_account_override_slots already defaults an empty slot to the ambient
# GH_TOKEN and every routed GitHub write prefix-assigns it, so copying that
# habit onto a `tea` invocation would hand a GitHub token to a Gitea instance.
# Usage: gtr_count_credential_bindings <file>
gtr_count_credential_bindings() {
  local file="$1" count
  count=$(grep -v '^[[:space:]]*#' "$file" | grep -cE '((export|declare -x)[[:space:]]+(GH_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL))|((GH_TOKEN|GITEA_TOKEN|GITEA_INSTANCE_URL)[[:space:]]*=)') || count=0
  printf '%s' "$count"
}

# Concatenates the THREE function bodies this story adds into one file, so the
# credential guard above is scoped to this story's own code rather than to the
# whole 15k-line CLI (which legitimately binds GH_TOKEN elsewhere, in the
# GitHub account-override path).
gtr_write_gitea_read_bodies() {
  local dest="$1"
  {
    sed -n '/^_forge_auth_status_gitea()/,/^}/p' "$CLI"
    sed -n '/^_forge_pr_view_gitea()/,/^}/p' "$CLI"
    sed -n '/^_forge_issue_view_gitea()/,/^}/p' "$CLI"
  } > "$dest"
}

# RUNS BEFORE ANY OTHER ASSERTION IN THIS SECTION, ON PURPOSE.
#
# An assertion that passes regardless of what the code under test does is not
# evidence, and this repository has shipped that exact defect twice. So before
# a single routing assertion trusts this stub, drive all THREE routed verbs
# end to end -- real CLI, real dispatch, private fake tea -- twice each with a
# payload that SHOULD move the verdict, and show it actually moves. Each verb
# records a would_have_gone_red flag, so a future edit that makes the stub
# ignore its own fixture fails HERE, loudly, rather than quietly making every
# assertion below vacuous.
gtr_test_gitea_read_stub_can_produce_a_failing_result() {
  echo ""
  echo "=== gitea read verbs: the stub CAN produce a failing result, per verb (falsifiability proof, runs first) ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local green red flag

  # --- forge-auth-status ---------------------------------------------------
  green=$(GTR_TEA_LOGIN_JSON='[{"url":"https://gitea.com","user":"octotea","default":"true"}]' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.account')
  red=$(GTR_TEA_LOGIN_JSON='[{"url":"https://gitea.com","user":"someone-else","default":"true"}]' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.account')
  assert_eq "octotea" "$green" "gtr falsifiability auth-status: the matching payload yields the expected account"
  assert_eq "someone-else" "$red" "gtr falsifiability auth-status: the differing payload yields the OTHER account, so data.account really tracks tea's own output"
  flag=no; [ "$red" != "octotea" ] && flag=yes
  assert_eq "yes" "$flag" "gtr falsifiability auth-status: asserting the differing payload against the first account WOULD have gone red"

  # --- forge-pr-view -------------------------------------------------------
  green=$(GTR_TEA_PULL_JSON='{"index":42,"id":98765}' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number | jq -r '.pr.number')
  red=$(GTR_TEA_PULL_JSON='{"index":7,"id":98765}' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number | jq -r '.pr.number')
  assert_eq "42" "$green" "gtr falsifiability pr-view: the matching payload yields the expected number"
  assert_eq "7" "$red" "gtr falsifiability pr-view: the differing payload yields the OTHER number"
  flag=no; [ "$red" != "42" ] && flag=yes
  assert_eq "yes" "$flag" "gtr falsifiability pr-view: asserting the differing payload against 42 WOULD have gone red"

  # --- forge-issue-view ----------------------------------------------------
  green=$(GTR_TEA_ISSUE_JSON='{"index":7,"title":"Real title"}' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.data.title')
  red=$(GTR_TEA_ISSUE_JSON='{"index":7,"title":"Some other title"}' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.data.title')
  assert_eq "Real title" "$green" "gtr falsifiability issue-view: the matching payload yields the expected title"
  assert_eq "Some other title" "$red" "gtr falsifiability issue-view: the differing payload yields the OTHER title"
  flag=no; [ "$red" != "Real title" ] && flag=yes
  assert_eq "yes" "$flag" "gtr falsifiability issue-view: asserting the differing payload against the first title WOULD have gone red"

  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

# Detection is CITED, not re-implemented and not modified. This story changes
# no line of _detect_forge_classify_host; the assertion below proves the
# classification it already performs is what routes these three verbs, and
# that the retargeted no-adapter control really does reach `unknown`.
gtr_test_gitea_detection_is_preexisting_and_unmodified() {
  echo ""
  echo "=== gitea routing: detection is _detect_forge_classify_host's existing answer, unchanged by this story ==="

  eval "$(sed -n '/^_detect_forge_classify_host()/,/^}/p' "$CLI")"

  assert_eq "gitea" "$(_detect_forge_classify_host gitea.com)" "gtr detection: gitea.com already classifies as gitea (aimi-cli.sh:1841), no change required by this story"
  assert_eq "gitea" "$(_detect_forge_classify_host codeberg.org)" "gtr detection: codeberg.org classifies as gitea too -- Forgejo is deliberately not distinguished"
  assert_eq "gitea" "$(_detect_forge_classify_host git.gitea.com)" "gtr detection: a *.gitea.com subdomain classifies as gitea"
  assert_eq "unknown" "$(_detect_forge_classify_host git.example.com)" "gtr detection: an unrecognized host classifies as unknown -- the ONLY remaining stand-in for a forge the abstraction has not yet routed"

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null
  assert_eq "gitea" "$("$CLI" detect-forge | jq -r '.forge')" "gtr detection: detect-forge reports gitea for the fixture every test below uses"
  popd >/dev/null
  teardown_detect_forge_fixture
}

gtr_test_forge_auth_status_gitea() {
  echo ""
  echo "=== forge-auth-status: gitea answers through tea login list -- found or error, never not_found ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log out exit_code doc
  log=$(mktemp)
  doc=$(gtr_tea_login_list_json)

  out=$(GTR_TEA_LOG="$log" GTR_TEA_LOGIN_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status) && exit_code=0 || exit_code=$?

  assert_exit_code "0" "$exit_code" "gitea auth-status: exits 0"
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitea auth-status: the check ran, so status is found"
  assert_eq "true" "$(printf '%s' "$out" | jq -r '.data.authenticated')" "gitea auth-status: data.authenticated is true"
  assert_eq "octotea" "$(printf '%s' "$out" | jq -r '.data.account')" "gitea auth-status: the acting account is the matching login entry's own user field"
  assert_eq "gitea" "$(printf '%s' "$out" | jq -r '.data.forge')" "gitea auth-status: data.forge names gitea, so a caller printing .data.forge (open-pr.md Step 1a) renders it correctly"
  assert_eq "gitea.com" "$(printf '%s' "$out" | jq -r '.data.host')" "gitea auth-status: data.host is the detected host"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "gitea auth-status: a successful check carries no reason"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "gitea auth-status: ...and no message"

  # --- ARGV. The control comes FIRST and MUST match, so the zeros below are
  # --- measurements rather than greps that silently matched nothing.
  assert_eq "1" "$(grep -c -- '-o json' "$log")" "gitea auth-status argv control: the call carried tea's own -o json (this MUST match, so the zeros below are trustworthy)"
  assert_eq "1" "$(grep -c '^login list -o json$' "$log")" "gitea auth-status argv: the call is exactly 'login list -o json'"
  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitea auth-status argv: no gh-style --json field-list selector (tea has none)"
  assert_eq "0" "$(grep -c 'whoami' "$log")" "gitea auth-status argv: tea whoami is NEVER invoked -- it round-trips the network and discards its own error"
  assert_eq "0" "$(grep -c -- '--login' "$log")" "gitea auth-status argv: no --login is passed -- this call is what DECIDES which login is active"

  # --- HOST FILTERING, the pair that an entry-zero implementation fails ----
  # One and the same payload, holding only a gitea.com login, read from two
  # fixtures. An implementation that accepted the first entry answers true for
  # both and fails the second half.
  local cb_out
  popd >/dev/null
  teardown_detect_forge_fixture
  setup_detect_forge_fixture origin https://codeberg.org/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  cb_out=$(GTR_TEA_LOGIN_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "gitea" "$(printf '%s' "$cb_out" | jq -r '.data.forge')" "gitea auth-status host filter: codeberg.org is still the gitea adapter"
  assert_eq "codeberg.org" "$(printf '%s' "$cb_out" | jq -r '.data.host')" "gitea auth-status host filter: ...with codeberg.org as the detected host"
  assert_eq "found" "$(printf '%s' "$cb_out" | jq -r '.status')" "gitea auth-status host filter: a definitive negative is still status=found -- the lookup succeeded"
  assert_eq "false" "$(printf '%s' "$cb_out" | jq -r '.data.authenticated')" "gitea auth-status host filter: a gitea.com-only login does NOT authenticate codeberg.org"
  assert_eq "null" "$(printf '%s' "$cb_out" | jq -r '.data.account')" "gitea auth-status host filter: ...and reports no acting account"
  assert_eq "null" "$(printf '%s' "$cb_out" | jq -r '.reason')" "gitea auth-status host filter: a confirmed negative is not a degradation, so reason stays null"

  popd >/dev/null
  teardown_detect_forge_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  # The default entry wins over entry zero.
  local def_out
  def_out=$(GTR_TEA_LOGIN_JSON="$(gtr_tea_login_list_default_second_json)" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "the-default" "$(printf '%s' "$def_out" | jq -r '.data.account')" "gitea auth-status: among two logins for the same host, the one flagged default wins -- not entry zero"

  # --- THE TWO FAILURE SHAPES, each asserted independently ----------------
  # This is the one place the gitea arm deliberately does NOT copy
  # _forge_auth_status_gitlab, whose non-zero exit IS glab's confirmed
  # "not authenticated" answer. tea exits 1 uniformly for EVERY error, so the
  # same reading would manufacture a false clean negative -- and a false clean
  # negative is what lets a broken session open a duplicate pull request.
  local fail_out unparseable_out
  fail_out=$(GTR_TEA_LOGIN_EXIT=1 PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "error" "$(printf '%s' "$fail_out" | jq -r '.status')" "gitea auth-status failure 1 (non-zero exit): status is error, NOT a clean authenticated:false"
  assert_eq "cli_failed" "$(printf '%s' "$fail_out" | jq -r '.reason')" "gitea auth-status failure 1: reason is cli_failed"
  assert_eq "null" "$(printf '%s' "$fail_out" | jq -r '.data')" "gitea auth-status failure 1: data is null, so authenticated cannot be read at all"
  assert_contains "tea" "$(printf '%s' "$fail_out" | jq -r '.message')" "gitea auth-status failure 1: the message names tea"

  unparseable_out=$(GTR_TEA_LOGIN_JSON='this is not json' PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "error" "$(printf '%s' "$unparseable_out" | jq -r '.status')" "gitea auth-status failure 2 (exit 0, unparseable stdout): status is error"
  assert_eq "cli_failed" "$(printf '%s' "$unparseable_out" | jq -r '.reason')" "gitea auth-status failure 2: reason is cli_failed"
  assert_eq "null" "$(printf '%s' "$unparseable_out" | jq -r '.data')" "gitea auth-status failure 2: data is null too -- a folded authenticated:false here would turn this red"

  # An EMPTY but cleanly parsed list is the one definitive negative.
  local empty_out
  empty_out=$(GTR_TEA_LOGIN_JSON='[]' PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status)
  assert_eq "found" "$(printf '%s' "$empty_out" | jq -r '.status')" "gitea auth-status: a cleanly parsed EMPTY login list is a definitive negative -- found, not error"
  assert_eq "false" "$(printf '%s' "$empty_out" | jq -r '.data.authenticated')" "gitea auth-status: ...with authenticated false"

  # Its contract permits exactly TWO statuses. Sweep every path this verb can
  # take on gitea and prove not_found is unreachable on all of them.
  local scenario statuses="" no_tea_path
  no_tea_path=$(_path_without_binary tea)
  for scenario in ok negative broken unparseable missing; do
    case "$scenario" in
      ok)          statuses="$statuses $(GTR_TEA_LOGIN_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      negative)    statuses="$statuses $(GTR_TEA_LOGIN_JSON='[]' PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      broken)      statuses="$statuses $(GTR_TEA_LOGIN_EXIT=1 PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      unparseable) statuses="$statuses $(GTR_TEA_LOGIN_JSON='nope' PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.status')" ;;
      missing)     statuses="$statuses $(PATH="$no_tea_path" "$CLI" forge-auth-status | jq -r '.status')" ;;
    esac
  done
  rm -rf "$no_tea_path"
  assert_eq "0" "$(printf '%s' "$statuses" | grep -c 'not_found')" "gitea auth-status: not_found never appears on ANY of its gitea paths (its contract is found-or-error only)"
  assert_eq " found found error error error" "$statuses" "gitea auth-status: the five gitea paths are exactly found / found / error / error / error"

  rm -f "$log"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

gtr_test_forge_pr_view_gitea_found() {
  echo ""
  echo "=== forge-pr-view: gitea reads the DETAIL path and returns the found envelope ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local doc log out
  doc=$(gtr_tea_pull_detail_json)
  log=$(mktemp)

  # Default --include: the seven-field portable core. Exact envelope, literal
  # for literal.
  out=$(GTR_TEA_LOG="$log" GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_json)" GTR_TEA_PULL_JSON="$doc" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x)
  assert_eq '{"status":"found","pr":{"number":42,"url":"https://gitea.com/acme/widgets/pulls/42","title":"Add the Gitea adapter","body":"Body text of the pull request.","state":"open","headRefName":"feat-x","baseRefName":"main"},"unsupported_fields":[],"message":null}' \
    "$out" "gitea pr-view: an existing pull request resolves to status=found with the exact envelope"

  # number came from index, NOT id -- the document's id is 98765 and would
  # have resolved to a different pull request entirely.
  assert_eq "42" "$(printf '%s' "$out" | jq -r '.pr.number')" "gitea pr-view: number is the per-repository index"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.pr.number == 98765')" "gitea pr-view: number is NOT the instance-wide id the document also carries"
  assert_eq "feat-x" "$(printf '%s' "$out" | jq -r '.pr.headRefName')" "gitea pr-view: headRefName comes from the DETAIL head, a BARE ref"
  assert_eq "main" "$(printf '%s' "$out" | jq -r '.pr.baseRefName')" "gitea pr-view: baseRefName comes from base"

  # --- THE ARGV PROOF -----------------------------------------------------
  # The control comes FIRST and MUST match, so every zero below is a
  # measurement rather than a grep that silently matched nothing.
  assert_eq "2" "$(grep -c -- '-o json' "$log")" "gitea pr-view argv control: both calls carried tea's own -o json (this MUST match, so the zeros below are trustworthy)"
  assert_eq "1" "$(grep -c '^pulls 42 -o json$' "$log")" "gitea pr-view argv: the DETAIL call is exactly 'pulls <index> -o json' -- no field list of any kind"
  assert_eq "1" "$(grep -c '^pulls list --state all -f index,head -o json$' "$log")" "gitea pr-view argv: the probe is 'pulls list --state all -f index,head -o json' -- tea HAS a selector, so only the two consumed fields are asked for"
  assert_eq "0" "$(grep -c '^pulls [0-9][0-9]* .*-f ' "$log")" "gitea pr-view argv: the DETAIL call carries NO -f -- tea's selector does not extend to the detail path"
  assert_eq "0" "$(grep -c -- '--fields' "$log")" "gitea pr-view argv: nor the long --fields spelling"
  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitea pr-view argv: no gh-style --json field-list selector anywhere (tea has none)"
  assert_eq "0" "$(grep -c -- '--head ' "$log")" "gitea pr-view argv: gh's --head flag never leaks into a tea invocation (tea pulls list has no head filter at all)"
  assert_eq "0" "$(grep -c -- '--source-branch' "$log")" "gitea pr-view argv: nor glab's --source-branch"
  assert_eq "0" "$(grep -c 'whoami' "$log")" "gitea pr-view argv: tea whoami is never invoked"

  # --- --include of the three capability-gated fields ----------------------
  out=$(GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_json)" GTR_TEA_PULL_JSON="$doc" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include files,isDraft,mergeable)
  assert_eq '{"status":"found","pr":{"files":null,"isDraft":null,"mergeable":"true"},"unsupported_fields":["files","isDraft"],"message":null}' \
    "$out" "gitea pr-view: files and isDraft are reported ABSENT (null + named in unsupported_fields), mergeable is answered"

  # --- THE MERGED DERIVATION, one pair -------------------------------------
  # tea's DETAIL state is `closed` on both halves; only hasMerged separates
  # them. An adapter reading `state` alone reports both as closed.
  local merged_out closed_out merged_doc
  merged_doc=$(gtr_tea_pull_detail_merged_json)
  merged_out=$(GTR_TEA_PULL_JSON="$merged_doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number,state)
  closed_out=$(GTR_TEA_PULL_JSON="$(gtr_tea_pull_detail_closed_json)" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number,state)
  assert_eq "merged" "$(printf '%s' "$merged_out" | jq -r '.pr.state')" "gitea pr-view merged: state==closed + hasMerged==true yields the contract's 'merged'"
  assert_eq "closed" "$(printf '%s' "$closed_out" | jq -r '.pr.state')" "gitea pr-view merged: the SAME document with hasMerged==false yields 'closed'"
  assert_eq "closed" "$(printf '%s' "$merged_doc" | jq -r '.state')" "gitea pr-view merged: tea's own DETAIL state really does say closed on the merged document -- the contract value is derived, not copied"

  # `merged` is derived in EXACTLY ONE place in the whole CLI. Counting form,
  # with a control that MUST be non-zero so the exact-1 below is a
  # measurement.
  local derivation_sites hasmerged_mentions
  hasmerged_mentions=$(grep -c 'hasMerged' "$CLI") || hasmerged_mentions=0
  derivation_sites=$(grep -v '^[[:space:]]*#' "$CLI" | grep -c 'hasMerged') || derivation_sites=0
  assert_eq "yes" "$([ "$hasmerged_mentions" -gt 0 ] && echo yes || echo no)" "gitea pr-view merged control: hasMerged appears in aimi-cli.sh at all (so the count below is a measurement, not a silent miss)"
  assert_eq "1" "$derivation_sites" "gitea pr-view merged: exactly ONE non-comment hasMerged derivation site exists in aimi-cli.sh -- this story and outline:01 cannot both have added one"

  # --- A NUMERIC ref skips the probe entirely ------------------------------
  local pull_counter list_counter
  pull_counter=$(mktemp); list_counter=$(mktemp)
  printf '0\n' > "$pull_counter"; printf '0\n' > "$list_counter"
  out=$(GTR_TEA_PULL_COUNTER="$pull_counter" GTR_TEA_LIST_COUNTER="$list_counter" \
    GTR_TEA_PULL_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 --include number)
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitea pr-view numeric ref: resolves found"
  assert_eq "0" "$(cat "$list_counter")" "gitea pr-view numeric ref: the pulls list probe is skipped ENTIRELY -- the counter stays at 0"
  assert_eq "1" "$(cat "$pull_counter")" "gitea pr-view numeric ref: exactly one detail call"

  # ...and a BRANCH ref does pay for it, which is what makes the zero above a
  # measurement rather than a stub that never counts anything.
  printf '0\n' > "$pull_counter"; printf '0\n' > "$list_counter"
  out=$(GTR_TEA_PULL_COUNTER="$pull_counter" GTR_TEA_LIST_COUNTER="$list_counter" \
    GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_json)" GTR_TEA_PULL_JSON="$doc" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number)
  assert_eq "1" "$(cat "$list_counter")" "gitea pr-view branch ref: the probe counter IS non-zero for a branch ref -- the counter works, so the 0 above is real"
  assert_eq "1" "$(cat "$pull_counter")" "gitea pr-view branch ref: one probe, then one detail call"

  rm -f "$log" "$pull_counter" "$list_counter"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

gtr_test_forge_pr_view_gitea_not_found_and_error_never_conflated() {
  echo ""
  echo "=== forge-pr-view: on gitea, a missing pull request is not_found and a broken tea is error -- never conflated ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local ref="feat-x" pull_counter not_found_out error_out not_found_status error_status
  pull_counter=$(mktemp); printf '0\n' > "$pull_counter"

  # Run 1: no pull request exists. The structural probe returns [] at exit 0
  # -- a fact in JSON, not a string in a message.
  not_found_out=$(GTR_TEA_PULL_COUNTER="$pull_counter" GTR_TEA_LIST_JSON='[]' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  # Run 2: SAME ref -- tea itself is broken on both calls. This must resolve
  # to error. Reading it as not_found is exactly the defect that lets a broken
  # check report "no PR yet" and open a duplicate.
  error_out=$(GTR_TEA_LIST_EXIT=1 GTR_TEA_PULL_EXIT=1 GTR_TEA_PULL_STDERR="Error: authentication failed, run tea login add" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")

  not_found_status=$(printf '%s' "$not_found_out" | jq -r '.status')
  error_status=$(printf '%s' "$error_out" | jq -r '.status')

  assert_eq "not_found" "$not_found_status" "gitea pr-view conflation guard: run 1 (no pull request) resolves to not_found"
  assert_eq "error" "$error_status" "gitea pr-view conflation guard: run 2 (broken tea) resolves to error"

  if [ "$not_found_status" != "$error_status" ]; then
    echo -e "${GREEN}✓${NC} gitea pr-view conflation guard: not_found and error produce different status literals for the same ref"
    ((TESTS_PASSED++))
  else
    echo -e "${RED}✗${NC} gitea pr-view conflation guard: not_found and error produced the SAME status literal ($not_found_status) -- the exact conflation this verb exists to prevent"
    ((TESTS_FAILED++))
  fi

  assert_eq "null" "$(printf '%s' "$not_found_out" | jq -r '.pr')" "gitea pr-view conflation guard: not_found -- pr is null"
  assert_contains "$ref" "$(printf '%s' "$not_found_out" | jq -r '.message')" "gitea pr-view conflation guard: not_found -- message names the searched ref"
  assert_eq "0" "$(cat "$pull_counter")" "gitea pr-view conflation guard: a structural [] answers absence WITHOUT paying for a doomed detail call"
  assert_contains "authentication failed" "$(printf '%s' "$error_out" | jq -r '.message')" "gitea pr-view conflation guard: error -- message carries tea's own failure text"

  # --- THE CROSS-FORK PAIR ------------------------------------------------
  # tea's LIST head may be `owner:branch`. Plain string equality against the
  # branch name fails the first half of this pair -- which would report an
  # EXISTING pull request as absent and invite a duplicate.
  local fork_found fork_absent
  fork_found=$(GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_json)" GTR_TEA_PULL_JSON="$(gtr_tea_pull_detail_json)" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number)
  fork_absent=$(GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_other_json)" GTR_TEA_PULL_JSON="$(gtr_tea_pull_detail_json)" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr feat-x --include number)
  assert_eq "found" "$(printf '%s' "$fork_found" | jq -r '.status')" "gitea pr-view cross-fork: a head of 'contributor:feat-x' MATCHES --pr feat-x and resolves found"
  assert_eq "42" "$(printf '%s' "$fork_found" | jq -r '.pr.number')" "gitea pr-view cross-fork: ...and the detail call was addressed with the index the probe resolved"
  assert_eq "not_found" "$(printf '%s' "$fork_absent" | jq -r '.status')" "gitea pr-view cross-fork: a head of 'contributor:other' does NOT match feat-x -- the suffix comparison discriminates rather than matching any colon"

  # --- 404-AFTER-CONFIRMED-EXISTENCE --------------------------------------
  # The probe said the pull request exists; the detail call then failed with
  # text that literally contains 404. Absence has been positively DISPROVEN,
  # so this is error. A structural fact outranks stderr prose.
  local confirmed_out numeric_out
  confirmed_out=$(GTR_TEA_LIST_JSON="$(gtr_tea_pull_list_json)" \
    GTR_TEA_PULL_EXIT=1 GTR_TEA_PULL_STDERR="Error: GET /api/v1/repos/acme/widgets/pulls/42: 404 Not Found" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")
  assert_eq "error" "$(printf '%s' "$confirmed_out" | jq -r '.status')" "gitea pr-view: a probe-confirmed pull request whose detail call fails is error, even when the stderr literally says 404"
  assert_contains "404" "$(printf '%s' "$confirmed_out" | jq -r '.message')" "gitea pr-view: ...and the 404-bearing stderr is carried as the message, proving the test really did exercise the 404 text"

  # The 404 backstop IS used when the probe could not confirm anything (here:
  # a numeric ref, which never probes).
  numeric_out=$(GTR_TEA_PULL_EXIT=1 GTR_TEA_PULL_STDERR="Error: GET /api/v1/repos/acme/widgets/pulls/999: 404 Not Found" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 999)
  assert_eq "not_found" "$(printf '%s' "$numeric_out" | jq -r '.status')" "gitea pr-view: a numeric ref tea answers 404 for resolves to not_found via the stderr backstop"

  # An UNPARSEABLE probe response proves nothing and must not be read as
  # absence.
  local unparseable_out
  unparseable_out=$(GTR_TEA_LIST_JSON='not json at all' GTR_TEA_PULL_EXIT=1 GTR_TEA_PULL_STDERR="Error: boom" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr "$ref")
  assert_eq "error" "$(printf '%s' "$unparseable_out" | jq -r '.status')" "gitea pr-view: an unparseable probe response leaves existence unproven -- error, never not_found"

  rm -f "$pull_counter"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

gtr_test_forge_issue_view_gitea() {
  echo ""
  echo "=== forge-issue-view: gitea routes to tea issues <index> -o json, same three-way envelope ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local doc log out
  doc=$(gtr_tea_issue_json)
  log=$(mktemp)

  out=$(GTR_TEA_LOG="$log" GTR_TEA_ISSUE_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7)

  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitea issue-view: an existing issue resolves to status=found"
  assert_eq "7" "$(printf '%s' "$out" | jq -r '.data.number')" "gitea issue-view: number is the per-repository index, not the instance-wide id (55501)"
  assert_eq "Login button does nothing" "$(printf '%s' "$out" | jq -r '.data.title')" "gitea issue-view: title"
  assert_eq "Steps to reproduce: click it." "$(printf '%s' "$out" | jq -r '.data.body')" "gitea issue-view: body comes from body -- tea spells it body, unlike glab's description"
  assert_eq "https://gitea.com/acme/widgets/issues/7" "$(printf '%s' "$out" | jq -r '.data.url')" "gitea issue-view: url"
  assert_eq "open" "$(printf '%s' "$out" | jq -r '.data.state')" "gitea issue-view: state, normalized through _forge_map_state gitea"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.message')" "gitea issue-view: found carries no message"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.reason')" "gitea issue-view: found carries no reason"

  # labels accepted in BOTH shapes from one document, so neither half can be
  # silently dropped.
  assert_eq '["bug","frontend"]' "$(printf '%s' "$out" | jq -c '.data.labels')" "gitea issue-view: labels survive as plain strings AND as {name} objects -- the same either-shape expression the gitlab arm uses"

  # comments is reported ABSENT, not zero. The fixture's comments array is
  # EMPTY -- which is what tea returns when --comments was not passed -- so an
  # implementation deriving a count from its length would emit comments:0 for
  # every issue in existence.
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.data.comments')" "gitea issue-view: comments is null"
  assert_eq '["comments"]' "$(printf '%s' "$out" | jq -c '.data.unsupported_fields')" "gitea issue-view: ...and NAMED in unsupported_fields -- reported absent, never a wrong zero"
  assert_eq "false" "$(printf '%s' "$out" | jq -r '.data.comments == 0')" "gitea issue-view: comments is specifically NOT 0, even though the fixture's comments array is empty"
  assert_eq "0" "$(printf '%s' "$doc" | jq -r '.comments | length')" "gitea issue-view: ...and the fixture really does carry an empty comments array, so that distinction was exercised"

  # --- ARGV. Control first, then the zeros. -------------------------------
  assert_eq "1" "$(grep -c -- '-o json' "$log")" "gitea issue-view argv control: the call carried tea's own -o json (this MUST match, so the zeros below are trustworthy)"
  assert_eq "1" "$(grep -c '^issues 7 -o json$' "$log")" "gitea issue-view argv: exactly 'issues <index> -o json'"
  assert_eq "0" "$(grep -c -- '--json' "$log")" "gitea issue-view argv: no gh-style --json field-list selector"
  assert_eq "0" "$(grep -c -- '--comments' "$log")" "gitea issue-view argv: --comments is deliberately NOT passed, which is why comments is reported absent"
  assert_eq "0" "$(grep -c 'whoami' "$log")" "gitea issue-view argv: tea whoami is never invoked"

  # The five contract fields this call site resolves are read out of
  # _forge_map_pr_field_gitea rather than hard-coded here. That reuse is only
  # legitimate because Gitea spells them identically on an issue and on a pull
  # request -- pinned here so a future divergence fails loudly.
  eval "$(sed -n '/^_forge_map_pr_field_gitea()/,/^}/p' "$CLI")"
  assert_eq "7" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitea number)" '.[$k]')" "gitea issue-view mapper reuse: the number key (index) resolves on an ISSUE document too"
  assert_eq "Login button does nothing" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitea title)" '.[$k]')" "gitea issue-view mapper reuse: the title key resolves on an issue document"
  assert_eq "Steps to reproduce: click it." "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitea body)" '.[$k]')" "gitea issue-view mapper reuse: the body key resolves on an issue document"
  assert_eq "https://gitea.com/acme/widgets/issues/7" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitea url)" '.[$k]')" "gitea issue-view mapper reuse: the url key resolves on an issue document"
  assert_eq "open" "$(printf '%s' "$doc" | jq -r --arg k "$(_forge_map_pr_field_gitea state)" '.[$k]')" "gitea issue-view mapper reuse: the state key resolves on an issue document"

  # --- not_found is claimed ONLY on a positive 404/not-found match ---------
  local nf_out
  nf_out=$(GTR_TEA_ISSUE_EXIT=1 GTR_TEA_ISSUE_STDERR="Error: GET /api/v1/repos/acme/widgets/issues/4242: 404 Not Found" \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 4242)
  assert_eq "not_found" "$(printf '%s' "$nf_out" | jq -r '.status')" "gitea issue-view: a 404 resolves to not_found, not error"
  assert_eq "null" "$(printf '%s' "$nf_out" | jq -r '.data')" "gitea issue-view not_found: data is null"
  assert_eq "null" "$(printf '%s' "$nf_out" | jq -r '.reason')" "gitea issue-view not_found: reason stays null -- not_found is a result, not a degradation"

  # --- every OTHER failure is error, classified STRUCTURALLY ---------------
  local unauth_out broken_out probe_broken_out
  unauth_out=$(GTR_TEA_ISSUE_EXIT=1 GTR_TEA_ISSUE_STDERR="Error: 401 Unauthorized" GTR_TEA_LOGIN_JSON='[]' \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7)
  assert_eq "error" "$(printf '%s' "$unauth_out" | jq -r '.status')" "gitea issue-view: a non-404 failure resolves to error, never an invented not_found"
  assert_eq "not_authenticated" "$(printf '%s' "$unauth_out" | jq -r '.reason')" "gitea issue-view: with NO matching login entry, the reason is not_authenticated"
  assert_contains "tea issues exited" "$(printf '%s' "$unauth_out" | jq -r '.message')" "gitea issue-view: the message names tea, never gh and never glab"

  broken_out=$(GTR_TEA_ISSUE_EXIT=1 GTR_TEA_ISSUE_STDERR="Error: dial tcp: lookup gitea.com: no such host" \
    GTR_TEA_LOGIN_JSON="$(gtr_tea_login_list_json)" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7)
  assert_eq "cli_failed" "$(printf '%s' "$broken_out" | jq -r '.reason')" "gitea issue-view: WITH a valid login entry, the same shape of failure is cli_failed -- the classifier is structural, not textual"

  # The auth probe ITSELF failing proves nothing, so it must not be read as a
  # negative: cli_failed is the safe direction for an already-known failure.
  probe_broken_out=$(GTR_TEA_ISSUE_EXIT=1 GTR_TEA_ISSUE_STDERR="Error: dial tcp: no such host" GTR_TEA_LOGIN_EXIT=1 \
    PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7)
  assert_eq "cli_failed" "$(printf '%s' "$probe_broken_out" | jq -r '.reason')" "gitea issue-view: when the auth probe itself cannot run, the reason is cli_failed -- an unreadable login list is not a confirmed logout"

  # There is deliberately NO structural issue probe: tea issues list is
  # paginated with no index filter, so a local scan could invent a FALSE
  # not_found. Counting form with a control that MUST match.
  local issue_body listing_hits control_hits
  issue_body=$(mktemp)
  sed -n '/^_forge_issue_view_gitea()/,/^}/p' "$CLI" > "$issue_body"
  listing_hits=$(grep -v '^[[:space:]]*#' "$issue_body" | grep -c 'issues list') || listing_hits=0
  control_hits=$(grep -v '^[[:space:]]*#' "$issue_body" | grep -c 'tea issues') || control_hits=0
  assert_eq "yes" "$([ "$control_hits" -gt 0 ] && echo yes || echo no)" "gitea issue-view control: the identical query DOES find 'tea issues' in the body, so the zero below is a measurement"
  assert_eq "0" "$listing_hits" "gitea issue-view: the adapter body invokes no 'issues list' scan -- a paginated scan could report a real issue as missing"
  assert_contains "PAGINATED" "$(sed -n '/^# gitea adapter for forge-issue-view/,/^_forge_issue_view_gitea()/p' "$CLI")" "gitea issue-view: the function header RECORDS why there is no structural probe, so it is not later 'improved' into a scan"

  rm -f "$log" "$issue_body"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

# The mapper-reuse claim, proven NON-GAMEABLY by mutation: a build whose
# _forge_map_pr_field_gitea answers a DIFFERENT native key for `number`
# produces a different data.number out of forge-issue-view. An issue arm with
# its own hand-written key table would be unmoved by this patch.
gtr_test_forge_issue_view_gitea_reads_keys_through_the_mapper() {
  echo ""
  echo "=== forge-issue-view gitea: the five portable-core keys come from outline:01's mapper, proven by mutation ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local mut_dir mut doc live mutant mut_res
  mut_dir=$(mktemp -d)
  mut="$mut_dir/aimi-cli.sh"
  doc=$(gtr_tea_issue_json)

  mut_res=$(gtr_mutate_cli "    number)      printf 'index' ;;" "    number)      printf 'id' ;;" "$mut")
  assert_eq "changed" "${mut_res%% *}" "gitea issue-view mapper mutation: the patch landed"
  assert_eq "1" "${mut_res##* }" "gitea issue-view mapper mutation: it replaced EXACTLY ONE line of aimi-cli.sh"

  live=$(GTR_TEA_ISSUE_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.data.number')
  mutant=$(GTR_TEA_ISSUE_JSON="$doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-issue-view --number 7 | jq -r '.data.number')

  assert_eq "7" "$live" "gitea issue-view mapper mutation: the live build reads number through the mapper's own index answer"
  assert_eq "55501" "$mutant" "gitea issue-view mapper mutation: repointing the MAPPER alone changes data.number to the document's id -- so this arm has no key table of its own"
  assert_eq "no" "$([ "$live" = "$mutant" ] && echo yes || echo no)" "gitea issue-view mapper mutation: the live and mutant answers genuinely differ"

  rm -rf "$mut_dir"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

# THE ABSENCE OF _forge_repo_info_gitea IS A DECISION, AND THIS PINS IT.
# tea has no repo-as-JSON command: `tea repos <owner>/<name>` requires the
# slug this code would have to local-parse first and does not honour --output
# at all (cmd/repos.go:47-65). A gitea tier would therefore local-parse the
# answer, ask tea about it, and learn nothing.
gtr_test_forge_repo_info_gitea_is_local_parse_by_decision() {
  echo ""
  echo "=== forge-repo-info: gitea deliberately has NO adapter and answers from the local remote parse ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local log out
  log=$(mktemp)
  out=$(GTR_TEA_LOG="$log" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-repo-info)

  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "gitea repo-info: status is found -- this verb never degrades on gitea"
  assert_eq "local-parse" "$(printf '%s' "$out" | jq -r '.data.source')" "gitea repo-info: data.source is local-parse, and says so rather than implying a CLI answered"
  assert_eq "gitea" "$(printf '%s' "$out" | jq -r '.data.forge')" "gitea repo-info: data.forge names gitea"
  assert_eq "gitea.com" "$(printf '%s' "$out" | jq -r '.data.host')" "gitea repo-info: data.host is the detected host"
  assert_eq "acme" "$(printf '%s' "$out" | jq -r '.data.owner')" "gitea repo-info: owner is parsed from the remote URL"
  assert_eq "widgets" "$(printf '%s' "$out" | jq -r '.data.repo')" "gitea repo-info: repo is parsed from the remote URL"
  assert_eq "acme/widgets" "$(printf '%s' "$out" | jq -r '.data.nameWithOwner')" "gitea repo-info: nameWithOwner recomposes them"
  assert_eq "0" "$(wc -l < "$log" | tr -d ' ')" "gitea repo-info: the fake tea's argv log is EMPTY -- this verb invokes tea zero times"

  # The absence is structural, not accidental. Control first: the gitlab
  # sibling DOES exist, so the zero below is a measurement.
  local gitlab_arm gitea_arm
  gitlab_arm=$(grep -c '^_forge_repo_info_gitlab()' "$CLI") || gitlab_arm=0
  gitea_arm=$(grep -c '^_forge_repo_info_gitea()' "$CLI") || gitea_arm=0
  assert_eq "1" "$gitlab_arm" "gitea repo-info control: _forge_repo_info_gitlab DOES exist, so the zero below is a measurement"
  assert_eq "0" "$gitea_arm" "gitea repo-info: there is NO _forge_repo_info_gitea function in aimi-cli.sh"

  # ...and the reason is recorded at the decision site, so the next reader
  # meets a decision rather than an oversight.
  local repo_info_body
  repo_info_body=$(sed -n '/^_forge_repo_info()/,/^}/p' "$CLI")
  assert_contains "tea repos" "$repo_info_body" "gitea repo-info: the decision comment at the CLI-tier chain names 'tea repos' as the command that cannot answer"
  assert_contains "ITS ABSENCE IS A DECISION" "$repo_info_body" "gitea repo-info: ...and states outright that the absence is a decision"

  rm -f "$log"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

# THE ONE CRITERION IN THIS STORY TESTABLE AGAINST REALITY ON THIS MACHINE:
# tea genuinely is not installed, so "the binary is absent" needs no stub at
# all. _path_without_binary is used anyway so this still holds on a machine
# where a developer HAS installed tea.
gtr_test_gitea_read_verbs_name_tea_when_binary_absent() {
  echo ""
  echo "=== gitea read verbs: with tea absent, each degrades naming tea -- never gh, never glab ==="

  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local no_tea stderr_file="/tmp/gtr_no_tea_stderr.$$"
  no_tea=$(_path_without_binary tea)

  # Sanity guard: prove the scenario is real before anything is read into it.
  assert_eq "no" "$(PATH="$no_tea" command -v tea >/dev/null 2>&1 && echo yes || echo no)" "tea-absent fixture: tea is genuinely unresolvable on this PATH"

  local out exit_code

  out=$(PATH="$no_tea" "$CLI" forge-pr-view --pr feat-x 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "tea absent, pr-view: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "tea absent, pr-view: status is error"
  assert_contains "tea not found on PATH" "$(printf '%s' "$out" | jq -r '.message')" "tea absent, pr-view: the message names tea"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "tea absent, pr-view: the message does NOT tell a Gitea user to install gh"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'glab not found')" "tea absent, pr-view: nor glab"
  assert_eq "" "$(cat "$stderr_file")" "tea absent, pr-view: quiet degrade -- no stderr banner"

  out=$(PATH="$no_tea" "$CLI" forge-issue-view --number 7 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "tea absent, issue-view: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "tea absent, issue-view: status is error"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "tea absent, issue-view: reason is cli_missing, not no_adapter -- the adapter exists, the binary does not"
  assert_contains "tea not found" "$(printf '%s' "$out" | jq -r '.message')" "tea absent, issue-view: the message names tea"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "tea absent, issue-view: the message does NOT name gh"
  assert_eq "" "$(cat "$stderr_file")" "tea absent, issue-view: quiet degrade -- no stderr banner"

  out=$(PATH="$no_tea" "$CLI" forge-auth-status 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_exit_code "0" "$exit_code" "tea absent, auth-status: exits 0"
  assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "tea absent, auth-status: status is error (the check could not run)"
  assert_eq "cli_missing" "$(printf '%s' "$out" | jq -r '.reason')" "tea absent, auth-status: reason is cli_missing"
  assert_contains "tea not found on PATH" "$(printf '%s' "$out" | jq -r '.message')" "tea absent, auth-status: the message names tea"
  assert_eq "0" "$(printf '%s' "$out" | jq -r '.message' | grep -c 'gh not found')" "tea absent, auth-status: the message does NOT name gh"
  assert_eq "" "$(cat "$stderr_file")" "tea absent, auth-status: quiet degrade -- no stderr banner"

  # repo-info has an offline tier, so a missing tea is not a degradation for
  # it at all -- and on gitea it never had a CLI tier to lose.
  out=$(PATH="$no_tea" "$CLI" forge-repo-info 2>"$stderr_file") && exit_code=0 || exit_code=$?
  assert_eq "found" "$(printf '%s' "$out" | jq -r '.status')" "tea absent, repo-info: still answers found -- its offline tier needs no CLI"
  assert_eq "local-parse" "$(printf '%s' "$out" | jq -r '.data.source')" "tea absent, repo-info: ...and says so through data.source"

  rm -f "$stderr_file"
  rm -rf "$no_tea"
  popd >/dev/null
  teardown_detect_forge_fixture
}

# NO CREDENTIAL REACHES A `tea` INVOCATION. tea honours GH_TOKEN whenever
# GITEA_INSTANCE_URL is also set, so copying the GitHub write path's
# prefix-assignment habit would hand a GitHub token to a Gitea instance.
#
# The checker is PROVEN ABLE TO RETURN NON-ZERO before its zero is trusted --
# a guard that can only ever say "clean" is not a guard.
gtr_test_gitea_read_verbs_bind_no_credentials() {
  echo ""
  echo "=== gitea read verbs: no GH_TOKEN / GITEA_TOKEN / GITEA_INSTANCE_URL binding in any of the three function bodies ==="

  local bodies planted body_lines
  bodies=$(mktemp)
  planted=$(mktemp)
  gtr_write_gitea_read_bodies "$bodies"

  # Guard the guard: prove the extraction actually captured all three bodies,
  # or a zero below would mean "nothing was scanned" rather than "nothing was
  # found".
  body_lines=$(wc -l < "$bodies" | tr -d ' ')
  assert_eq "yes" "$([ "$body_lines" -gt 60 ] && echo yes || echo no)" "gitea credential guard: the three function bodies were actually extracted ($body_lines lines), so the count below scans real code"
  assert_eq "3" "$(grep -c '^_forge_.*_gitea() {$' "$bodies")" "gitea credential guard: all three function definitions are present in the scanned text"

  assert_eq "0" "$(gtr_count_credential_bindings "$bodies")" "gitea credential guard: ZERO prefix assignments or exports of GH_TOKEN, GITEA_TOKEN or GITEA_INSTANCE_URL in the three new bodies"

  # The falsifiability half: the same checker, run over a copy with ONE
  # planted binding, must report it.
  {
    printf '%s\n' 'GH_TOKEN="$leaked" tea pulls 1 -o json'
    cat "$bodies"
  } > "$planted"
  assert_eq "1" "$(gtr_count_credential_bindings "$planted")" "gitea credential guard falsifiability: the SAME checker reports 1 against a copy with one planted GH_TOKEN prefix assignment -- so the 0 above is a measurement"

  # The counting form itself, not the short-circuiting one. A `grep -v | grep -q`
  # inside an `if` fails OPEN under pipefail; this section uses `grep -c` with
  # `|| count=0` everywhere and adds no eighth instance of the broken shape.
  local checker_body short_circuit_hits count_hits
  checker_body=$(declare -f gtr_count_credential_bindings)
  short_circuit_hits=$(printf '%s\n' "$checker_body" | grep -c 'grep -q') || short_circuit_hits=0
  count_hits=$(printf '%s\n' "$checker_body" | grep -c 'grep -c') || count_hits=0
  assert_eq "1" "$count_hits" "gitea credential guard shape control: the checker DOES use the counting form, so the zero below is a measurement"
  assert_eq "0" "$short_circuit_hits" "gitea credential guard shape: the checker uses no 'grep -q' short-circuit -- it adds no eighth fail-open guard"

  rm -f "$bodies" "$planted"
}

# ONE MUTATION PER ROUTED VERB. For each of the three, a copy of aimi-cli.sh
# has that verb's gitea arm UNROUTED -- restoring the pre-story behaviour --
# and a SPECIFIC, NAMED assertion is shown to go red. Three verbs, three
# distinct named assertions.
#
# Each mutation asserts BOTH that its patch landed AND that it replaced
# exactly ONE line. The second half is new in phase 4 and is not decoration:
# several gitea arms exist across this wave, so an anchor that also matched
# outline:03's or outline:04's would silently unroute three verbs at once and
# make this matrix prove less than it claims.
gtr_test_gitea_read_verbs_mutation_matrix() {
  echo ""
  echo "=== gitea read verbs: unrouting each verb in turn turns a specific named assertion RED ==="

  gtr_setup_fake_tea_read_fixture
  setup_detect_forge_fixture origin https://gitea.com/acme/widgets.git
  pushd "$DETECT_FORGE_FIXTURE_DIR" >/dev/null

  local mut_dir mut pull_doc issue_doc login_doc live mutant mut_res
  mut_dir=$(mktemp -d)
  mut="$mut_dir/aimi-cli.sh"
  pull_doc=$(gtr_tea_pull_detail_json)
  issue_doc=$(gtr_tea_issue_json)
  login_doc=$(gtr_tea_login_list_json)

  # --- 1/3: forge-auth-status ----------------------------------------------
  # Named assertion under test:
  #   "gitea auth-status: data.authenticated is true"
  mut_res=$(gtr_mutate_cli '    gitea)  adapter_bin="tea" ;;' '    gitea-unrouted)  adapter_bin="tea" ;;' "$mut")
  assert_eq "changed" "${mut_res%% *}" "MUTATION 1/3 forge-auth-status: the unroute patch landed"
  assert_eq "1" "${mut_res##* }" "MUTATION 1/3 forge-auth-status: it replaced EXACTLY ONE line of aimi-cli.sh"
  live=$(GTR_TEA_LOGIN_JSON="$login_doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-auth-status | jq -r '.data.authenticated')
  mutant=$(GTR_TEA_LOGIN_JSON="$login_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-auth-status | jq -r '.data.authenticated')
  assert_eq "true" "$live" "MUTATION 1/3 forge-auth-status: routed, the named assertion 'data.authenticated is true' is GREEN"
  assert_eq "null" "$mutant" "MUTATION 1/3 forge-auth-status: UNROUTED, that same named assertion goes RED -- data is null, so authenticated cannot be read at all"
  assert_eq "no_adapter" "$(GTR_TEA_LOGIN_JSON="$login_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-auth-status | jq -r '.reason')" "MUTATION 1/3 forge-auth-status: the unrouted build reverts to reason=no_adapter"

  # --- 2/3: forge-pr-view --------------------------------------------------
  # Named assertion under test:
  #   "gitea pr-view: an existing pull request resolves to status=found"
  mut_res=$(gtr_mutate_cli '        _forge_pr_view_gitea "$pr_ref" "$fields_csv"' '        _forge_pr_view_emit "error" "null" "null" "no forge-pr-view adapter for the unrouted forge."' "$mut")
  assert_eq "changed" "${mut_res%% *}" "MUTATION 2/3 forge-pr-view: the unroute patch landed"
  assert_eq "1" "${mut_res##* }" "MUTATION 2/3 forge-pr-view: it replaced EXACTLY ONE line of aimi-cli.sh"
  live=$(GTR_TEA_PULL_JSON="$pull_doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-pr-view --pr 42 | jq -r '.status')
  mutant=$(GTR_TEA_PULL_JSON="$pull_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-pr-view --pr 42 | jq -r '.status')
  assert_eq "found" "$live" "MUTATION 2/3 forge-pr-view: routed, the named assertion 'an existing pull request resolves to status=found' is GREEN"
  assert_eq "error" "$mutant" "MUTATION 2/3 forge-pr-view: UNROUTED, that same named assertion goes RED -- status is error, not found"
  assert_contains "no forge-pr-view adapter" "$(GTR_TEA_PULL_JSON="$pull_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-pr-view --pr 42 | jq -r '.message')" "MUTATION 2/3 forge-pr-view: the unrouted build reverts to the no-adapter message"

  # --- 3/3: forge-issue-view -----------------------------------------------
  # Named assertion under test:
  #   "gitea issue-view: an existing issue resolves to status=found"
  mut_res=$(gtr_mutate_cli '    _forge_issue_view_gitea "$number" "$host"' '    _forge_emit_status error "" "forge-issue-view: unrouted." no_adapter' "$mut")
  assert_eq "changed" "${mut_res%% *}" "MUTATION 3/3 forge-issue-view: the unroute patch landed"
  assert_eq "1" "${mut_res##* }" "MUTATION 3/3 forge-issue-view: it replaced EXACTLY ONE line of aimi-cli.sh"
  live=$(GTR_TEA_ISSUE_JSON="$issue_doc" PATH="$GTR_TEA_DIR:$PATH" "$CLI" forge-issue-view --number 7 | jq -r '.status')
  mutant=$(GTR_TEA_ISSUE_JSON="$issue_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-issue-view --number 7 | jq -r '.status')
  assert_eq "found" "$live" "MUTATION 3/3 forge-issue-view: routed, the named assertion 'an existing issue resolves to status=found' is GREEN"
  assert_eq "error" "$mutant" "MUTATION 3/3 forge-issue-view: UNROUTED, that same named assertion goes RED -- status is error, not found"
  assert_eq "no_adapter" "$(GTR_TEA_ISSUE_JSON="$issue_doc" PATH="$GTR_TEA_DIR:$PATH" bash "$mut" forge-issue-view --number 7 | jq -r '.reason')" "MUTATION 3/3 forge-issue-view: the unrouted build reverts to reason=no_adapter"

  rm -rf "$mut_dir"
  popd >/dev/null
  teardown_detect_forge_fixture
  gtr_teardown_fake_tea_read_fixture
}

# RUNS LAST IN THIS SECTION, ON PURPOSE -- it reads the SECTION-WIDE argv log
# every test above appended to, so it can only state its claim once they have
# all run. (The per-test GTR_TEA_LOG files are torn down; GTR_TEA_AUDIT is
# not.)
#
# `tea whoami` makes a network round trip and then DISCARDS its own error
# (cmd/whoami.go:22-31, `user, _, _ :=`), so it cannot serve as an auth probe.
# No code path in this story invokes it, and this is where that is measured.
gtr_test_tea_whoami_is_never_invoked() {
  echo ""
  echo "=== gitea read verbs: tea whoami is invoked by no code path in this story (section-wide argv audit) ==="

  local total whoami_hits login_hits
  assert_eq "yes" "$([ -n "${GTR_TEA_AUDIT:-}" ] && [ -f "$GTR_TEA_AUDIT" ] && echo yes || echo no)" "gitea whoami audit: the section-wide argv log exists"

  total=$(wc -l < "$GTR_TEA_AUDIT" | tr -d ' ')
  assert_eq "yes" "$([ "$total" -gt 20 ] && echo yes || echo no)" "gitea whoami audit: it recorded the whole section's invocations ($total lines), so the zero below is a measurement rather than an empty file"

  # Control first: a subcommand that IS invoked must be found by the identical
  # counting query.
  login_hits=$(grep -c '^login list' "$GTR_TEA_AUDIT") || login_hits=0
  assert_eq "yes" "$([ "$login_hits" -gt 0 ] && echo yes || echo no)" "gitea whoami audit control: the identical query DOES find 'login list' invocations, so the zero below is trustworthy"

  whoami_hits=$(grep -c 'whoami' "$GTR_TEA_AUDIT") || whoami_hits=0
  assert_eq "0" "$whoami_hits" "gitea whoami audit: ZERO whoami invocations across every test in this section"

  # ...and the stub would not have let one pass quietly: its default arm exits
  # 127 with a diagnostic on any unhandled invocation.
  gtr_setup_fake_tea_read_fixture
  local rc=0
  GTR_TEA_AUDIT= PATH="$GTR_TEA_DIR:$PATH" tea whoami >/dev/null 2>&1 || rc=$?
  assert_eq "127" "$rc" "gitea whoami audit: the fake tea exits 127 on an unhandled invocation, so a stray whoami could not have passed silently"
  gtr_teardown_fake_tea_read_fixture
}

# ============================================================================
# Main
# ============================================================================

main() {
  if [ -z "${AIMI_TEST_PART_RESULT_FILE:-}" ]; then
    echo "================================================"
    echo "  Aimi CLI Test Suite - part4-forge-verbs"
    echo "================================================"
  fi

  # Ensure cleanup on exit/abort
  trap 'rm -rf "$TEST_DIR"' EXIT

  # Run inside isolated temp directory so find_aimi_root() discovers
  # the test .aimi/ instead of the real project .aimi/
  cd "$TEST_DIR"

  setup

  # The single-file suite reached this point with a session already
  # initialised by the General/Lifecycle sections that now live in part 1.
  # Each part gets its own TEST_DIR, so re-establish that precondition.
  "$CLI" init-session > /dev/null

  # The remembered answer applied to ONE forge invocation, without touching
  # the machine's active account. The two criteria that look contradictory --
  # every write uses the project's account, AND the machine account is
  # unchanged afterwards -- are both satisfied by a per-invocation token
  # override that never calls `gh auth switch`.
  echo ""
  echo "--- Forge Account Override Tests (phase 2 US-005) ---"
  test_forge_account_override_host_selects_the_variable
  test_forge_account_override_costs_nothing_when_it_has_nothing_to_do
  test_forge_account_override_precedence
  test_forge_account_override_lookup_ignores_an_ambient_override
  test_forge_account_override_degrades_when_the_account_is_gone
  test_forge_account_override_leaks_nothing_and_switches_nothing
  test_forge_account_override_reads_what_the_recorder_wrote
  test_forge_write_paths_route_the_recorded_account
  test_forge_writes_leave_the_machine_account_unchanged
  test_forge_writes_active_account_answer_needs_no_branch
  test_forge_resolve_review_thread_classifier_runs_under_the_override

  # Forge PR View Tests (US-004) -- field-selectable PR lookup with a
  # three-way found/not_found/error status, fixing the exit-code conflation
  # gh pr view --json url carries today
  echo ""
  echo "--- Forge PR View Tests (US-004) ---"
  test_forge_pr_view_found_single_field
  test_forge_pr_view_include_field_sets
  test_forge_pr_view_not_found_and_error_never_conflated
  test_forge_pr_view_not_found_prefers_structural_list_probe_over_stderr_text
  test_forge_pr_view_not_found_secondary_stderr_fallback
  test_forge_pr_view_numeric_ref_skips_list_probe
  test_forge_pr_view_unknown_include_field_rejected
  test_forge_pr_view_missing_gh_binary_quiet_degrade
  test_forge_pr_view_non_github_forge_quiet_degrade
  test_forge_pr_view_state_normalization_matches_issue_view
  test_forge_pr_view_unsupported_fields_is_always_an_array_on_found
  test_forge_pr_view_unsupported_fields_intersect_requested_only
  test_forge_pr_view_absent_key_vs_explicit_null_are_distinguishable
  test_forge_pr_view_include_accepts_contract_fields_and_rejects_gh_only_names
  test_forge_pr_view_registered_in_help_and_dispatcher

  # Forge PR Create/Edit Tests (US-005) -- the first WRITE verbs that
  # create/mutate a pull request, built on forge-pr-view (US-004) for both
  # the idempotency check and the post-write structured re-read
  echo ""
  echo "--- Forge PR Create/Edit Tests (US-005) ---"
  test_forge_pr_create_new_pr
  test_forge_pr_create_existing_pr_is_idempotent
  test_forge_pr_create_lookup_error_never_falls_through_to_create
  test_forge_pr_create_closed_or_merged_existing_pr_does_not_block
  test_forge_pr_create_post_create_reread_failure_keeps_created_url
  test_forge_pr_create_missing_gh_mandatory_print_nonzero_exit
  test_forge_pr_create_non_github_forge_mandatory_print
  test_forge_pr_create_guard_failures
  test_forge_pr_create_credential_via_env_not_argv
  test_forge_pr_edit_credential_via_env_not_argv
  test_forge_resolve_review_thread_credential_via_env_not_argv
  test_forge_pr_edit_success
  test_forge_pr_edit_missing_gh_mandatory_print_nonzero_exit
  test_forge_pr_edit_gh_failure_prints_manual_nonzero_exit
  test_forge_pr_edit_invalid_number_guard
  test_forge_pr_edit_omitted_body_is_rejected
  test_forge_pr_edit_explicit_empty_body_still_clears
  test_forge_write_verbs_share_one_data_shape
  test_forge_write_verbs_degraded_exit_code_split
  test_forge_pr_create_and_edit_registered_in_help_and_dispatcher

  # GitLab WRITE-verb tests (phase 3) -- the three write verbs routed to glab.
  # The -y falsifiability proof runs FIRST, before anything trusts the
  # detector every other assertion in this block depends on.
  echo ""
  echo "--- GitLab Write-Verb Tests (phase 3) ---"
  test_glw_yes_flag_detector_can_go_red
  test_glw_glab_write_url_extraction
  test_glw_forge_pr_create_gitlab_creates_mr_with_yes_flag
  test_glw_forge_pr_create_gitlab_existing_open_mr_is_unchanged
  test_glw_forge_pr_create_gitlab_stale_mr_does_not_block
  test_glw_forge_pr_create_gitlab_missing_glab_prints_mr_url
  test_glw_forge_pr_create_gitlab_create_failure_degrades
  test_glw_forge_pr_create_gitlab_reread_failure_keeps_created_url
  test_glw_forge_pr_edit_gitlab_updates_with_yes_flag
  test_glw_forge_pr_edit_gitlab_missing_glab_prints_mr_url
  test_glw_forge_pr_edit_gitlab_update_failure_degrades
  test_glw_forge_issue_create_gitlab_soft_fails_and_carries_yes
  test_glw_every_glab_write_invocation_carries_yes_in_source
  test_glw_gitlab_write_call_sites_are_prefix_assignment_ready

  # GitLab ACCOUNT selection (phase 3, US-005) -- the DEGRADED branch: glab has
  # no per-account token retrieval, so these police that the degradation is
  # honest. The fixture falsifiability proof runs FIRST, before any before/after
  # comparison trusts the stub to report the same account twice.
  echo ""
  echo "--- GitLab Account-Selection Tests (phase 3) ---"
  test_gla_fake_glab_can_report_a_differing_active_account
  test_gla_gitlab_write_leaves_the_machine_account_untouched
  test_gla_inherited_gitlab_token_reaches_glab_untouched
  test_gla_export_guard_counts_rather_than_short_circuits
  test_gla_gitlab_write_header_records_the_determination
  test_gla_agent_mode_persists_no_gitlab_account_answer

  # Gitea WRITE-verb tests (phase 4 outline:03) -- the three write verbs routed
  # to tea, plus the gitea arm of _forge_pr_write_print_manual. The
  # flag-count falsifiability proof runs FIRST, before anything trusts the
  # reader every always-pass-a-flag assertion in this block depends on; the
  # three-way mutation matrix runs LAST.
  echo ""
  echo "--- Gitea Write-Verb Tests (phase 4 outline:03) ---"
  gtw_test_flag_count_reader_can_go_red
  gtw_test_tea_write_url_extraction
  gtw_test_forge_pr_create_gitea_creates_pr
  gtw_test_forge_pr_create_gitea_existing_open_pr_is_unchanged
  gtw_test_forge_pr_create_gitea_owner_prefixed_head_matches
  gtw_test_forge_pr_create_gitea_dead_pr_does_not_block
  gtw_test_forge_pr_create_gitea_missing_tea_prints_manual
  gtw_test_forge_pr_create_gitea_create_failure_degrades
  gtw_test_forge_pr_create_gitea_unparseable_url_degrades
  gtw_test_forge_pr_create_gitea_reread_failure_keeps_created_url
  gtw_test_forge_pr_edit_gitea_updates
  gtw_test_forge_pr_edit_gitea_missing_tea_prints_manual
  gtw_test_forge_pr_edit_gitea_failure_degrades
  gtw_test_forge_issue_create_gitea_creates_issue
  gtw_test_forge_issue_create_gitea_always_exits_zero
  gtw_test_manual_fallback_gitea_host_default
  gtw_test_gitea_write_token_source_guards
  gtw_test_gitea_write_live_token_probe
  gtw_test_gitea_write_header_states_its_invariants
  gtw_test_gitea_write_verbs_mutation_matrix

  # Forge Issue Verb Tests (US-006) -- forge-issue-view / forge-issue-create,
  # the first forge-* verbs that actually shell out to a forge CLI
  echo ""
  echo "--- Forge Issue Verb Tests (US-006) ---"
  test_forge_capture_scratch_file_never_survives
  test_forge_map_state_table
  test_forge_extract_issue_number_from_url
  test_forge_emit_issue_create_status_is_gone
  test_forge_issue_view_found
  test_forge_issue_view_not_found
  test_forge_issue_view_degraded_missing_gh
  test_forge_issue_view_non_github_forge_degrades
  test_forge_issue_view_generic_failure_not_authenticated
  test_forge_issue_view_generic_failure_cli_failed
  test_forge_issue_view_input_errors
  test_forge_issue_create_success
  test_forge_issue_create_degraded_failure_prints_manual
  test_forge_issue_create_missing_gh_mandatory_print
  test_forge_issue_create_credential_via_env_not_argv
  test_forge_issue_create_input_errors
  test_forge_issue_verbs_registered_in_help_and_dispatcher

  # Forge Review-Thread Verb Tests (US-007) -- forge-pr-review-threads /
  # forge-resolve-review-thread, porting get-pr-comments/resolve-pr-thread's
  # GraphQL query and mutation into aimi-cli.sh with every identifier bound
  # via gh api graphql's own -f/-F flags
  echo ""
  echo "--- Forge Review-Thread Verb Tests (US-007) ---"
  test_forge_review_thread_queries_bind_via_flags_not_interpolation
  test_forge_review_thread_input_validation
  test_forge_pr_review_threads_found_default_filter
  test_forge_pr_review_threads_all_flag_includes_resolved_and_outdated
  test_forge_pr_review_threads_not_found_null_pull_request
  test_forge_pr_review_threads_degraded_missing_gh
  test_forge_pr_review_threads_non_github_forge_degrades
  test_forge_pr_review_threads_owner_repo_unresolved_is_cli_failed
  test_forge_pr_review_threads_graphql_failure_not_authenticated
  test_forge_pr_review_threads_graphql_failure_cli_failed
  test_forge_pr_review_threads_owner_repo_auto_detected
  test_forge_resolve_review_thread_success
  test_forge_resolve_review_thread_confirmed_invalid_id
  test_forge_resolve_review_thread_missing_gh_mandatory_print
  test_forge_resolve_review_thread_mutation_failure_not_authenticated
  test_forge_resolve_review_thread_mutation_failure_cli_failed
  test_forge_review_thread_verbs_registered_in_help_and_dispatcher

  # GitLab Review-Thread Routing Tests (phase 3 US-004) -- the two review-thread
  # verbs routed to `glab mr note list` / `glab mr note resolve`. Every function
  # in this block is `glt_`-prefixed (see its header for why). The
  # falsifiability proof runs FIRST, before any routing assertion trusts the
  # fake glab; the two mutation tests run LAST, each unrouting one verb and
  # naming the assertion that goes red.
  echo ""
  echo "--- GitLab Review-Thread Routing Tests (phase 3 US-004) ---"
  glt_test_fake_glab_can_produce_a_failing_result
  glt_test_pr_review_threads_asks_glab_for_state_unresolved
  glt_test_pr_review_threads_maps_discussion_vocabulary_to_thread
  glt_test_pr_review_threads_all_flag_asks_for_state_all
  glt_test_pr_review_threads_zero_threads_is_found_with_empty_list
  glt_test_pr_review_threads_glab_failure_is_cli_failed
  glt_test_pr_review_threads_glab_absent_degrades_through_the_shared_gate
  glt_test_resolve_review_thread_via_glab
  glt_test_resolve_review_thread_posts_no_reply
  glt_test_resolve_review_thread_confirmed_missing_is_found_false
  glt_test_resolve_review_thread_glab_absent_mandatory_print
  glt_test_thread_id_round_trips_from_listing_to_resolve
  glt_test_resolve_records_glab_experimental_status
  glt_test_mutation_unrouting_the_listing_verb_turns_an_assertion_red
  glt_test_mutation_unrouting_the_resolve_verb_turns_an_assertion_red

  # Gitea Review-Thread Routing Tests (phase 4 outline:04) --
  # forge-pr-review-threads and forge-resolve-review-thread routed to
  # `tea pulls review-comments` / `tea pulls resolve`, plus the rewrite of the
  # phase-1 GITEA CAPABILITY-GAP NOTE this story disproves. The falsifiability
  # proof runs FIRST, before any routing assertion trusts the private fake-tea
  # stub; the two mutation tests run LAST, unrouting each verb in turn.
  echo ""
  echo "--- Gitea Review-Thread Routing Tests (phase 4 outline:04) ---"
  gtt_test_fake_tea_can_produce_a_failing_result
  gtt_test_pr_review_threads_argv_is_teas_own_field_selector
  gtt_test_pr_review_threads_filters_locally_on_resolver
  gtt_test_pr_review_threads_maps_comment_to_degenerate_thread
  gtt_test_pr_review_threads_declares_its_capability_gaps
  gtt_test_pr_review_threads_zero_comments_is_found_with_empty_list
  gtt_test_pr_review_threads_failure_classification
  gtt_test_resolve_review_thread_via_tea
  gtt_test_resolve_review_thread_failure_classification
  gtt_test_thread_id_round_trips_from_listing_to_resolve
  gtt_test_tea_absent_degrades_through_the_shared_gate
  gtt_test_no_adapter_message_names_all_three_adapters
  gtt_test_capability_gap_note_is_rewritten
  gtt_test_section_header_declares_ceiling_and_version_floor
  gtt_test_neither_gitea_arm_hands_a_token_to_tea
  gtt_test_no_assertion_message_claims_gitea_has_no_adapter
  gtt_test_mutation_unrouting_the_listing_verb_turns_an_assertion_red
  gtt_test_mutation_unrouting_the_resolve_verb_turns_an_assertion_red

  # Forge Dispatch-Order Tests (phase 1.1 US-006) -- all ten forge verbs
  # dispatched ahead of find_aimi_root, so a caller with no .aimi/ anywhere
  # (resolve-pr-parallel) and a multi-repo child repo both get a working
  # envelope; plus the two consequences of that move (per-verb check_jq, and
  # a stray --help reaching the verb's own parser)
  echo ""
  echo "--- Forge Dispatch-Order Tests (phase 1.1 US-006) ---"
  test_forge_verbs_run_without_any_aimi_dir
  test_forge_repo_info_multi_repo_child_without_project
  test_forge_verbs_dispatched_before_find_aimi_root
  test_forge_verbs_call_check_jq_first
  test_forge_verb_stray_help_flag_parity

  # Forge Derivation Memo + PR-View Probe-Order Tests (phase 1.1 US-010) --
  # the per-project-dir memo behind _detect_forge_type, and the inverted
  # gh pr list / gh pr view order. Both measured by counter/log files.
  echo ""
  echo "--- Forge Derivation Memo + PR-View Probe-Order Tests (phase 1.1 US-010) ---"
  test_detect_forge_type_never_builds_or_parses_json
  test_detect_forge_type_matches_detect_forge_across_fixtures
  test_detect_forge_type_memo_is_keyed_per_project_dir
  test_forge_pr_create_derives_forge_once_per_process
  test_forge_pr_view_not_found_branch_ref_costs_one_gh_call
  test_forge_pr_view_found_branch_ref_costs_two_gh_calls_list_then_view
  test_forge_pr_view_list_confirms_but_view_fails_is_error_never_not_found

  # GitLab PR-field Mapping Tests (phase 3 US-001) -- the GitLab arm of the
  # _forge_map_pr_field_* seam, plus the fake-glab PATH stub every later
  # gitlab-adapter story in this phase reuses. The falsifiability proof runs
  # FIRST, before any mapping assertion trusts that stub.
  echo ""
  echo "--- GitLab PR-field Mapping Tests (phase 3 US-001) ---"
  test_fake_glab_stub_can_produce_a_failing_result
  test_fake_glab_records_argv_and_can_differ_across_calls
  test_forge_map_pr_field_gitlab

  # Gitea PR-field Mapping Tests (phase 4 outline:01) -- the gitea arm of the
  # _forge_map_pr_field_* seam, the _forge_map_pr_state_gitea derivation that
  # reads hasMerged, and the gitea) arm of _forge_pr_view_build_found, plus
  # the fake-tea PATH stub every later gitea-adapter story in this phase
  # reuses. The falsifiability proof runs FIRST, before any mapping assertion
  # trusts that stub.
  echo ""
  echo "--- Gitea PR-field Mapping Tests (phase 4 outline:01) ---"
  gtm_test_fake_tea_stub_can_produce_a_failing_result
  gtm_test_forge_map_pr_field_gitea
  gtm_test_tea_detail_and_list_shapes_differ
  gtm_test_forge_map_pr_state_gitea
  gtm_test_forge_pr_view_build_found_gitea

  # GitLab READ-verb Routing Tests (phase 3 US-002) -- forge-pr-view,
  # forge-issue-view, forge-repo-info and forge-auth-status routed to glab.
  # The per-verb falsifiability proof runs FIRST, before any routing
  # assertion trusts the private fake-glab stub; the mutation matrix runs
  # LAST, unrouting each verb in turn.
  echo ""
  echo "--- GitLab READ-verb Routing Tests (phase 3 US-002) ---"
  glr_test_gitlab_read_stub_can_produce_a_failing_result
  glr_test_gitlab_detection_is_preexisting_and_unmodified
  glr_test_forge_pr_view_gitlab_found
  glr_test_forge_pr_view_gitlab_not_found_and_error_never_conflated
  glr_test_forge_issue_view_gitlab
  glr_test_forge_repo_info_gitlab
  glr_test_forge_auth_status_gitlab
  glr_test_gitlab_read_verbs_name_glab_when_binary_absent
  glr_test_gitlab_read_verbs_mutation_matrix

  # Gitea READ-verb Routing Tests (phase 4 outline:02) -- forge-auth-status,
  # forge-pr-view and forge-issue-view routed to tea, plus the deliberate
  # NON-routing of forge-repo-info. The per-verb falsifiability proof runs
  # FIRST, before any routing assertion trusts the private fake-tea stub. The
  # section-wide whoami audit runs LAST because it reads the argv log every
  # test above it appended to -- including the mutation matrix's.
  #
  # The forge-auth-status tests live here rather than in part 3 (where every
  # other one does) because the parts run concurrently and part 3 is the wall
  # clock; phase 3's read-verbs story made the same call for
  # glr_test_forge_auth_status_gitlab.
  echo ""
  echo "--- Gitea READ-verb Routing Tests (phase 4 outline:02) ---"
  gtr_test_gitea_read_stub_can_produce_a_failing_result
  gtr_test_gitea_detection_is_preexisting_and_unmodified
  gtr_test_forge_auth_status_gitea
  gtr_test_forge_pr_view_gitea_found
  gtr_test_forge_pr_view_gitea_not_found_and_error_never_conflated
  gtr_test_forge_issue_view_gitea
  gtr_test_forge_issue_view_gitea_reads_keys_through_the_mapper
  gtr_test_forge_repo_info_gitea_is_local_parse_by_decision
  gtr_test_gitea_read_verbs_name_tea_when_binary_absent
  gtr_test_gitea_read_verbs_bind_no_credentials
  gtr_test_gitea_read_verbs_mutation_matrix
  gtr_test_tea_whoami_is_never_invoked

  cleanup

  if [ -n "${AIMI_TEST_PART_RESULT_FILE:-}" ]; then
    printf '%s %s\n' "$TESTS_PASSED" "$TESTS_FAILED" > "$AIMI_TEST_PART_RESULT_FILE"
  else
    echo ""
    echo "================================================"
    echo "  Results: ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
    echo "================================================"
  fi

  if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
