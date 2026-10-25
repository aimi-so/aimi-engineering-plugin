# Execute: Phase Completion: Creates Verification

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Creates Verification

For every entry the phase declared in `roadmap.json`'s `creates[]`, confirm the artifact is actually present in at least one participating repository's own phase branch — not merely that some other phase's `needs` resolved against it. This is a distinct, stricter check than `validate-contracts`: `validate-contracts` (outline 03) answers "does a `needs` entry have a completed, handoff-documented provider," using `roadmap.json` and `handoff.md` as its only inputs, and never inspects source code. This check answers "does this phase's own promised artifact exist, somewhere among its participating repositories," by inspecting each repository's own phase container's actual tracked files.

**Union across repositories, not per-repository attribution.** An identity is `verified` for the phase when **any** participating repository's own call reports it `verified`; it is `missing` only when **every** participating repository reports it `missing`. This is a union, never a per-repository assignment, because a phase's `creates[]` contract is declared once, at the phase level: `scope-contexts.md`'s naming table (§ Creates/Needs Contracts) names every artifact by kind — endpoint, table, service, file — with no repository qualifier, so a phase never declares which repository will deliver a given artifact. There is no per-repository slot to attribute a verdict against; the only question this check can ask of an identity is whether it exists **anywhere** among the phase's own participating repositories, and the answer is the union of every repository's own answer.

**Split-mode timing (`PHASE_SPLIT_MODE=true`):** this check runs once per participating repository, against that repository's own container — and for a given repository, it never runs before **that repository's own merge** has landed. Merge Split Branches Into the Phase Branch (above) issues one `merge-all` call per repository, not one phase-wide call, so a repository's own `$PHASE_BRANCH` reflects that repository's split work only once **its own** `merge-all` call has returned successfully — a sibling repository's merge still being pending, or having conflicted, has no bearing on whether this repository is safe to check. Merge Split Branches Into the Phase Branch already STOPs (and releases the claim) on any repository's merge conflict before Phase Completion is ever reached, so every participating repository's container is guaranteed merged by the time this section runs — this note documents why that guarantee holds per repository, not a new gate this section itself enforces.

> **Cross-story flag for the auditor:** this story's brief describes creates verification as invoking "the outline:03 contract-validation CLI surface... in its phase-closure mode" (e.g. `validate-contracts <phase-id> --root <path>`) as an illustrative example. The landed `validate-contracts` (outline 03) has no `--root` flag or code-existence mode, and its own notes scope it exclusively to needs-vs-creates delivery resolution ("wiring validate-contracts and roadmap-sweep into plan.md and execute.md is owned by outline 08 and outline 11" — this story). Extending `validate-contracts`'s jq-only, roadmap.json-only logic to also grep real source files would be new scope outline 03 never claimed. Creates verification therefore ships as **its own CLI verb, `verify-creates`** — not as an extension of `validate-contracts`, and no longer as executable prose here. It was prose until this section was rewritten: five hand-written steps built on `[ -f ]` and a bare `git grep -l -F`, which no Bash suite could reach and which was wrong in five of nine measured scenarios (a docs-only mention, a `TODO` comment and a test-file mention each closed a phase; a directory identity could never verify, because `[ -f ]` is false on a directory; and a project that committed its own `.aimi/` found the identity inside the very `roadmap.json` that declared it). Reconcile if a future story wants to fold `verify-creates` into `validate-contracts` instead.

#### Inputs

- `FEATURE` and `PHASE_ID` — the claimed phase. Every repository's own `verify-creates` call reads that phase's `creates[]` out of `roadmap.json` itself and takes each entry's own `identity` field, so no `creates` array is extracted here and no second copy of that rule exists in this file, in any repository's call. Because every call reads the same phase-level `creates[]`, every repository's own verdict array covers the identical, identically-ordered identity set.
- `PARTICIPATING_GROUP_KEYS` — every project group with at least one story (non-split phase) or `$PHASE_SPLIT_FILES` member (split phase) scheduled for this phase, derived fresh in this block by the same rule that populated `PHASE_CONTAINER_PATHS[group_key]` for this phase run (Create Phase Containers Per Project Group's Derive Participating Project Groups, above) — branching on `PHASE_SPLIT_MODE` exactly as the adjacent Multi-File Pending Count block already does. Split mode sums over the **full** `$PHASE_SPLIT_FILES` member list, not just this run's active subset — the same reason Multi-File Pending Count does: a repository whose split member already completed on a prior run still delivered artifacts there, and still needs checking. For each participating group, its own container — `<repo toplevel>/.worktrees/$PHASE_BRANCH` (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Container Paths Per Project Group), recomputed fresh via `git -C ... rev-parse --show-toplevel`, never read from a value assumed to survive from Step 1.7 — is passed as that repository's own `--dir`; it is the checkout whose **tracked** files are searched there. With exactly one participating group — today's single-repo case — this is exactly today's single `PHASE_CONTAINER_PATH` value, unchanged.

#### Procedure

One `verify-creates` call **per participating repository** — never a single call regardless of how many repositories are involved, and never a path assumed to survive from Step 1.7 or from a prior loop iteration, since each Bash call is an isolated shell. `verify-creates` (`cmd_verify_creates` in `aimi-cli.sh`, **unmodified by this story** — it already accepts `--dir`, so N calls with N different `--dir` values need no verb change) runs four deterministic steps per `creates[]` entry — a tracked-path match via `git ls-files`, which matches a **directory** as well as a file; leading-HTTP-method extraction, so `POST /api/notifications` is searched as `/api/notifications`, which is what route code actually contains; a `git grep -n -I -F` over tracked source that excludes documentation, tests and `.aimi/`; and a filter that drops hits which are only a `TODO`/`FIXME`/`XXX`/`HACK` comment. Identity kinds are not dispatched on: every identity, in every repository's call, runs the same four steps.

It is a **query, not a gate**, for each repository's own call — any verdict array exits `0`, including one where every entry is `missing` — so branch on the JSON below, never on a `missing` verdict having "failed". A non-zero exit from any one repository's call means that repository's tooling could not run at all (unknown flag, absent or malformed `roadmap.json`, a `--dir` that is not a directory) and its stderr says which; per the union rule above, one repository's tooling failure fails the whole phase's check, so this is decided before any repository's missing count is ever consulted.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"

# Derive PARTICIPATING_GROUP_KEYS fresh in this block — Step 1.7's populated
# PHASE_CONTAINER_PATHS map does not persist across Bash calls. Same rule,
# same source files, as Create Phase Containers Per Project Group's own
# Derive Participating Project Groups — except split mode sums over the FULL
# member list, $PHASE_SPLIT_FILES, exactly like the adjacent Multi-File
# Pending Count block, not just this run's active subset.
if [ "$PHASE_SPLIT_MODE" = true ]; then
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  # Hoisted once, above the loop -- never re-called per split_file.
  PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
  CV_GROUP_RAW=""
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    CV_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // "."')
    CV_GROUP_RAW="${CV_GROUP_RAW}${CV_PROJECT}"$'\n'
  done <<< "$PHASE_SPLIT_FILES"
  PARTICIPATING_GROUP_KEYS=$(printf '%s\n' "$CV_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PARTICIPATING_GROUP_KEYS" ] || PARTICIPATING_GROUP_KEYS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline. A refusal here (an
  # invalid project value) is new: this site never validated before.
  CV_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || {
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  }
  PARTICIPATING_GROUP_KEYS=$(printf '%s' "$CV_GROUPS_JSON" | jq -r '.groups[]')
fi

# One verify-creates call per participating repository. Each repository's own
# container is recomputed fresh here — <repo toplevel>/.worktrees/$PHASE_BRANCH,
# the identical formula container-execution.md's Phase Container Paths Per
# Project Group contract uses — never read from a value assumed to survive
# from Step 1.7. Each call's own exit status is captured with a pre-initialized
# variable plus an || assignment, never a bare $? read, so one repository's
# tooling failure can never abort the loop before the remaining repositories
# are checked.
PHASE_CV_RESULTS=""
while IFS= read -r CV_PROJECT; do
  [ -n "$CV_PROJECT" ] || continue
  case "$CV_PROJECT" in
    .)
      CV_GROUP_KEY="DEFAULT"
      CV_GROUP_ROOT="$AIMI_ROOT"
      ;;
    /*|..|../*|*/..|*/../*)
      echo "Invalid project \"$CV_PROJECT\" for phase $PHASE_ID" >&2
      $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
      exit 1
      ;;
    *)
      if ! [[ "$CV_PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
        echo "Invalid project \"$CV_PROJECT\" for phase $PHASE_ID" >&2
        $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
        exit 1
      fi
      CV_GROUP_KEY="$CV_PROJECT"
      CV_GROUP_ROOT="$AIMI_ROOT/$CV_PROJECT"
      ;;
  esac

  CV_GROUP_TOPLEVEL=$(git -C "$CV_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || CV_GROUP_TOPLEVEL=""
  if [ -z "$CV_GROUP_TOPLEVEL" ]; then
    echo "Not a git repository: $CV_GROUP_ROOT (project \"$CV_PROJECT\" for phase $PHASE_ID)" >&2
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  fi
  CV_CONTAINER="$CV_GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"

  # Judge with the CLI the phase itself produced, when this repository's own
  # container carries one: a phase that changes aimi-cli.sh's own logic (e.g.
  # a filter verify-creates itself relies on) must be judged by that changed
  # code, not by whatever the global cache still has installed. This is only
  # ever true for a repository that is this plugin's own source tree; every
  # other participating repository's container has no
  # plugins/aimi-engineering of its own, and CV_CLI falls back to today's
  # resolution there. Either way the fallback is named on one stderr line, so
  # the report never leaves silent which code judged this repository.
  CV_CONTAINER_CLI="$CV_CONTAINER/plugins/aimi-engineering/scripts/aimi-cli.sh"
  if [ -x "$CV_CONTAINER_CLI" ]; then
    CV_CLI="$CV_CONTAINER_CLI"
  else
    CV_CLI="$AIMI_CLI"
    echo "creates-verification: $CV_GROUP_KEY: no executable aimi-cli.sh in container ($CV_CONTAINER_CLI) -- judging with the resolved CLI ($AIMI_CLI) instead" >&2
  fi

  CV_CALL_EXIT=0
  CV_CALL_OUTPUT=$($CV_CLI verify-creates --feature "$FEATURE" --phase "$PHASE_ID" --dir "$CV_CONTAINER") || CV_CALL_EXIT=$?
  [ "$CV_CALL_EXIT" -eq 0 ] || CV_CALL_OUTPUT='[]'

  PHASE_CV_RESULTS="${PHASE_CV_RESULTS}$(jq -nc \
    --arg gk "$CV_GROUP_KEY" --arg dir "$CV_CONTAINER" \
    --argjson exit "$CV_CALL_EXIT" --argjson verdicts "$CV_CALL_OUTPUT" \
    '{group_key: $gk, dir: $dir, exit: $exit, verdicts: $verdicts}')"$'\n'
done <<< "$PARTICIPATING_GROUP_KEYS"

# Tooling-failure tallies — computed unconditionally, from every repository's
# own RAW verdicts, before any union is attempted. status:"error" is git
# failing inside one repository's call, not an artifact failing to exist; a
# non-zero CV_CALL_EXIT is the same class one level up — that repository's
# call never ran at all. Either one, in ANY repository, dominates the branch
# decision below, before MISSING_COUNT is ever computed.
CV_REPO_COUNT=$(printf '%s\n' "$PARTICIPATING_GROUP_KEYS" | grep -c .)
CV_MULTI=$([ "$CV_REPO_COUNT" -gt 1 ] && echo true || echo false)
CV_EXIT_FAILURES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | select(.exit != 0)] | length')
# Each jq filter below is kept on a single physical line, even though it
# reads dense. A jq-internal name bound with "as" is easy to misread as an
# unassigned bash variable once the filter wraps past one source line, so
# every filter here stays on the line that opens its own quote — a plain
# formatting constraint, not a logic change.
CV_EXIT_LINES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r --argjson multi "$CV_MULTI" '.[] | select(.exit != 0) | if $multi then "\(.group_key) (\(.dir)): verify-creates exited \(.exit) and produced no verdicts." else "verify-creates exited \(.exit) and produced no verdicts." end')
ERROR_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | .verdicts[]? | select(.status == "error")] | length')
ERROR_CREATES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r --argjson multi "$CV_MULTI" '.[] as $r | ($r.verdicts[]? | select(.status == "error")) as $v | if $multi then "\($r.group_key): \($v.identity) — \($v.evidence) [git exit \($v.gitStatus)]" else "\($v.identity) — \($v.evidence) [git exit \($v.gitStatus)]" end')
# `unconfirmed` is counted here beside `missing` because both mean the same
# thing to a reader: the artifact was not proven to exist. verify-creates
# returns it for a documentation identity that resolved only through the text
# search -- some tracked file writes the page's name, which is what a table of
# contents does, and is not the page. Counting only `missing` here would let a
# tooling-failed run report "0 further entries" while every doc identity in the
# phase came back mention-only.
CV_RAW_MISSING_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | .verdicts[]? | select(.status == "missing" or .status == "unconfirmed")] | length')

if [ "$CV_EXIT_FAILURES" -gt 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
  CV_BRANCH="tooling-failed"
else
  # Union: an identity is verified for the phase when ANY repository verified
  # it; missing only when EVERY repository reported it missing. This step
  # never runs on a set missing a repository's own verdicts — reached only
  # once every repository's own call is confirmed clean above.
  CREATES_REPORT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s --argjson multi "$CV_MULTI" '(.[0].verdicts | map(.identity)) as $order | ([.[] as $r | $r.verdicts[] | {group_key: $r.group_key, identity, status, method, evidence, gitStatus}]) as $flat | [ $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | ($grp | map(select(.status == "verified")) | sort_by(.group_key)) as $ver | ($grp | map(select(.status == "missing" or .status == "unconfirmed")) | sort_by(.group_key)) as $und | if ($ver | length) > 0 then {identity: $id, status: "verified", method: $ver[0].method, evidence: $ver[0].evidence, gitStatus: $ver[0].gitStatus} else (if ($und | length) > 0 then $und else ($grp | sort_by(.group_key)) end) as $mis | (if $multi then ($mis | map("\(.group_key): \(.evidence)") | join("; ")) else $mis[0].evidence end) as $ev | {identity: $id, status: "missing", method: $mis[0].method, evidence: $ev, gitStatus: $mis[0].gitStatus} end ]')
  VERIFIED_ARTIFACTS=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "verified") | "\(.identity) — \(.evidence)"')
  MISSING_CREATES=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "missing") | "\(.identity) — \(.evidence)"')
  MISSING_COUNT=$(printf '%s' "$CREATES_REPORT" | jq '[.[] | select(.status == "missing")] | length')
  # Which of those undelivered identities are undelivered because they were
  # found ONLY as a mention. Derived from the RAW per-repository verdicts, not
  # from CREATES_REPORT: the union deliberately collapses `unconfirmed` into
  # `missing` so one branch handles both, and this is the one place that still
  # needs to tell them apart -- for the report, never for the branch decision.
  # An identity qualifies when no repository verified it and at least one
  # reported it `unconfirmed`; an identity every repository reported `missing`
  # does not, and neither does one some other repository verified.
  MENTION_ONLY_CREATES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r '(.[0].verdicts | map(.identity)) as $order | ([.[] | .verdicts[]?]) as $flat | $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | select(($grp | map(.status) | index("verified")) == null) | select(($grp | map(.status) | index("unconfirmed")) != null) | $id')
  MENTION_ONLY_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '(.[0].verdicts | map(.identity)) as $order | ([.[] | .verdicts[]?]) as $flat | [ $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | select(($grp | map(.status) | index("verified")) == null) | select(($grp | map(.status) | index("unconfirmed")) != null) ] | length')
  if [ "$MISSING_COUNT" -gt 0 ]; then
    CV_BRANCH="missing"
  else
    CV_BRANCH="ok"
  fi
fi

printf 'creates-verification: branch=%s repos=%s exit_failures=%s error_count=%s missing_count=%s mention_only_count=%s\n' \
  "$CV_BRANCH" "$CV_REPO_COUNT" "$CV_EXIT_FAILURES" "$ERROR_COUNT" "${MISSING_COUNT:-0}" "${MENTION_ONLY_COUNT:-0}"
printf -- '--- verified ---\n%s\n--- missing ---\n%s\n--- mention only ---\n%s\n--- tooling exit failures ---\n%s\n--- tooling errors ---\n%s\n' \
  "${VERIFIED_ARTIFACTS:-}" "${MISSING_CREATES:-}" "${MENTION_ONLY_CREATES:-}" "$CV_EXIT_LINES" "$ERROR_CREATES"
```

Every value is still derived with a `jq` select on `.status` — jq is the loop, deliberately instead of a shell `while` that accumulates a variable read after the loop has closed (`test-command-blocks.sh` check 3 catches exactly that shape) — now in two passes: `ERROR_COUNT`/`ERROR_CREATES` are computed from every repository's own **raw**, pre-union verdicts (so a tool failure is visible before any union is attempted), and `CREATES_REPORT`/`VERIFIED_ARTIFACTS`/`MISSING_CREATES`/`MISSING_COUNT` are computed from the **unioned** per-identity array, reached only once every repository's own call is confirmed clean. Each unioned verdict object keeps the existing shape, `{identity, status, method, evidence, gitStatus}`: `status` is `verified` | `missing` (never `error` — an error anywhere already routed the phase to Verification tooling failed before this point), `method` is `"path"` | `"text"` | `null`, and `evidence` names the tracked path or `file:line` that decided it, or, on a `missing`, what was found and rejected.

**`verify-creates` returns a third verdict, `unconfirmed`, and this section treats it as NOT DELIVERED — the same branch as `missing`, on purpose.** Two searches reach it, and both report the same thing — the name was found, the artifact was not. A documentation identity that resolved only through the text search gets it because some tracked file writes the string `docs/api.md`, which is what a table of contents does and is not the page; only that identity's own tracked path verifies it. ANY identity gets it when every line matching it is a comment, because a note describing an artifact is not the artifact — the defect that closed two verifications in this roadmap's own phase 3, both times on comments an author had written to explain it (`${CLAUDE_PLUGIN_ROOT}/commands/references/scope-contexts.md` § What verification looks for). The union names it beside `missing` in its own `$und` binding rather than leaving it to the `else` that used to catch every non-`verified` status unnamed: a verdict handled only by a catch-all is a verdict nobody can see is handled, and this file's own vocabulary sentence claimed for three releases that `missing` was the only undelivered status there was. Its **evidence is carried through unchanged**, so the report says the artifact was found only by mention rather than not found at all — the whole difference between "nobody wrote this page" and "three files link to a page nobody wrote". The unioned `status` still reads `missing`, which is what keeps `MISSING_COUNT`, `MISSING_CREATES` and the branch decision below identical to what they were: one undelivered branch, not two. `MENTION_ONLY_CREATES`/`MENTION_ONLY_COUNT` are the one place that still tells the two apart, computed from the raw per-repository verdicts and used only by the report.

`VERIFIED_ARTIFACTS` keeps its line shape `"<identity> — <location>"`, identity verbatim and first, one line per verified entry in `creates[]` order, with the winning repository's own `evidence` string as the location — never tagged with that repository's `group_key`, and never a concatenation of every repository that verified it: when more than one repository verifies the same identity, the location is the evidence from the first repository, in sorted `group_key` order, that verified it. Identity-first is load-bearing, not cosmetic: this list becomes handoff.md's `## Artifacts Created`, which `roadmap.py`'s `handoff_lists_artifact` substring-matches to resolve a downstream phase's `needs`.

`MISSING_CREATES` keeps the same `"<identity> — <evidence>"` shape, but with **more than one** participating repository its `evidence` names every repository that was searched: `"<group_key>: <that repository's own evidence>"`, joined with `"; "` in sorted `group_key` order, so a reader can tell "this name appears nowhere in any repository" from "this name appears only in prose in repository X" instead of one arbitrary repository's evidence standing in for all of them. Both the rejected-location detail and the tracked-files-only limitation `verify-creates` already returns per call (scope-contexts.md § What verification looks for) are preserved, once per repository, inside that combined string. With **exactly one** participating repository the tag is omitted — `MISSING_CREATES`, like `CREATES_REPORT`, `VERIFIED_ARTIFACTS`, `ERROR_CREATES` and `MISSING_COUNT`, is then byte-identical to today's single-call output: the union of one set is that set.

#### Which branch to take

Read the `creates-verification:` line the Procedure block printed above.

- `branch=tooling-failed` → **Verification tooling failed** below. No status transition. This fires when `CV_EXIT_FAILURES > 0` (at least one repository's own `verify-creates` call never ran) or `ERROR_COUNT > 0` (git broke while checking at least one identity in at least one repository) — decided before `MISSING_COUNT` is ever computed, so a single repository's tooling failure can never be silently read as that repository contributing zero verified identities to the union.
- `branch=missing` → **On any missing entry** below. `verification_failed`. An `unconfirmed` verdict routes here too, and is counted in `MISSING_COUNT` like any other undelivered entry — see the paragraph above for why the union collapses the two into one branch and where the distinction survives (`mention_only_count` on the same printed line, and the `--- mention only ---` block beneath it).
- `branch=ok` → **Write Handoff**.

Error entries are never part of `CREATES_REPORT`: `ERROR_COUNT`/`ERROR_CREATES` are computed from every repository's own raw verdicts, before the union step runs, and the union itself is reached only once `CV_EXIT_FAILURES` and `ERROR_COUNT` are both confirmed zero across every participating repository — so a tool failure in one repository can never be counted or reported as an undelivered artifact, and no repository's data is ever silently dropped from the union because a sibling repository's call failed.

#### Verification tooling failed

The phase's status is left exactly where it already was (`in_progress`) — do **not** call `roadmap-set-status`. Release the claim only (see Release the Claim on Abort), the same shape the handoff-write-failure path below uses, because `in_progress` is re-claimable once unclaimed:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Transitioning to `verification_failed` here would tell the user their phase failed to deliver when the tool is what failed — and would block next-phase planning on evidence that was never gathered for every repository, including the ones whose own call succeeded.

Report:
```
## Phase [PHASE_ID] Creates Verification Could Not Run

Verification tooling failed in at least one participating repository. This is
NOT a finding that the phase failed to deliver — nothing was proven either
way, for any repository, including ones whose own call succeeded cleanly.

[if CV_EXIT_FAILURES > 0, for each line of CV_EXIT_LINES:]
  - [line]

[if ERROR_COUNT > 0:]
[ERROR_COUNT] creates entr(y|ies) could not be checked because git exited above 1:

[for each line of ERROR_CREATES:]
  - [line]

Phase status is unchanged (in_progress) and the claim is released. Nothing was
marked verification_failed, because a broken tool is not a missing artifact.
Fix git in the repositor(y|ies) named above, then re-run /aimi:execute --
creates verification re-runs from scratch, against every participating
repository, on the next pass.

[if CV_RAW_MISSING_COUNT > 0:]
[CV_RAW_MISSING_COUNT] further entr(y|ies) came back missing, counted across
every repository's own raw verdicts rather than deduplicated per identity.
They are reported as unconfirmed rather than failed, because a run in which
git broke in even one repository is not a run whose other verdicts can be
trusted — no cross-repository union was computed — and they are re-checked
next pass.
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

#### On any missing entry

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Release the claim (see Release the Claim on Abort) right after the status transition above — `verification_failed` is one of the statuses `roadmap-claim`'s auto-mode branch treats as re-claimable once unclaimed, so releasing here is what lets "re-run `/aimi:execute` to re-verify" below actually work on the next attempt, self-session or otherwise.

Report — print each missing line **with the evidence `verify-creates` returned for it**, verbatim, tagged by every repository that was searched when more than one repository participated in this phase. That evidence is the difference between "this name appears nowhere in any participating repository" and "this name appears only in prose in repository X", and the user cannot tell those apart from a bare "not found":
```
## Phase [PHASE_ID] Verification Failed

[MISSING_COUNT] declared creates entr(y|ies) could not be confirmed in any
participating repository's phase branch:

[for each line of MISSING_CREATES:]
  - [line]

[if more than one participating repository:]
Each line names every repository searched for that identity and what was
found and rejected there, tagged by that repository's own group_key. An
identity reads missing here only when every participating repository
reported it missing — an identity delivered in even one repository verifies
for the whole phase, so this list is genuinely undelivered everywhere it was
looked for.
[otherwise:]
Each line carries what was searched and, when something was found, the file and
line that was found and rejected. "Found and rejected ... documentation or test
path" means the name exists only in prose or in a test — a mention of the work,
not the work. "Found and rejected ... TODO/FIXME marker comment" means the code
says the work is still owed.

[if MENTION_ONLY_COUNT > 0:]
[MENTION_ONLY_COUNT] of those entr(y|ies) came back as a MENTION, not as an
absence — the name is written somewhere in tracked source, but the artifact
it names was never found:

[for each line of MENTION_ONLY_CREATES:]
  - [line]

For a documentation identity, a text hit is a link to the page, not the page.
Confirm one of these by committing the file its identity names — the tracked
path is the only thing that verifies it. If the identity is not documentation,
it is named wrongly in `creates[]`: fix the entry with
`$AIMI_CLI roadmap-amend-phase --feature [FEATURE] --phase [PHASE_ID]` rather
than writing a file to satisfy the check.

git ls-files and git grep see tracked (committed) files only, in every
participating repository, so work that is written but committed nowhere in
any of them reads as missing here. If that is what happened, commit it on
the relevant repository's own [PHASE_BRANCH] and re-run to re-verify —
nothing else is needed.

Phase status set to verification_failed. Fix the missing artifact(s) on
branch [PHASE_BRANCH] in whichever repositor(y|ies) should have delivered
them, then re-run /aimi:execute to re-verify — creates verification re-runs
from scratch, against every participating repository, on the next pass.
Next-phase planning stays blocked until this phase re-verifies successfully
(verification_failed is excluded from next-eligible-phase selection, the same
way pending/in_progress are).
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5 (which still reports this phase's own story-level completion, unaffected by the roadmap-level failure).

