# Execute: Phase Completion: Phase Usage Validation

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Phase Usage Validation

Runs after the Phase Visual Gate has fallen through and before Write Handoff, so a phase whose delivered product was never used for real cannot reach `completed`, and every skip says why. A split phase, or one with several participating repositories, is validated like any other: this section never calls `project-groups`, never reads `PHASE_SPLIT_MODE` and records no skip for "more than one repository". It never writes `handoff.md` and never sets the phase to `completed`.

Every Bash call is an isolated shell: re-resolve `AIMI_CLI` at the top of each block and carry nothing in shell variables between calls. The `Use **AskUserQuestion**` and agent-mode rules are `${CLAUDE_PLUGIN_ROOT}/commands/references/interactivity.md`; typed text is sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` Base Rules before it reaches `--reason`.

#### Is validation owed

One `usage-validation-required` call per run, read-only. The answer is saved to a file under `.aimi/` only when validation is owed.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FEATURE="[FEATURE]"
PHASE_ID="[PHASE_ID]"
AIMI_ROOT="[AIMI_ROOT]"
# usage-phase-required:begin
USAGE_ANSWER=$("$AIMI_CLI" usage-validation-required --feature "$FEATURE" --phase "$PHASE_ID") || USAGE_ANSWER=""
USAGE_REQUIRED=$(printf '%s' "$USAGE_ANSWER" | jq -r 'if (.required | type) == "boolean" then (.required | tostring) else "invalid" end' 2>/dev/null) || USAGE_REQUIRED=""
case "$USAGE_REQUIRED" in
  true|false) ;;
  *)
    echo "usage-validation: tooling-failed"
    "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
    ;;
esac
printf 'usage-validation-required: required=%s skipKind=%s surfaceSource=%s members=%s projects=%s charters=%s\n' "$USAGE_REQUIRED" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.skipKind // "none"')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.surfaceSource // "none"')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.members // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.projects // []) | join(",")')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.charters // []) | length')"
if [ "$USAGE_REQUIRED" = "true" ]; then
  USAGE_ANSWER_FILE=$(mktemp "$AIMI_ROOT/.aimi/usage-required-XXXXXX") || { echo "usage-validation: tooling-failed"; "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"; exit 1; }
  printf '%s\n' "$USAGE_ANSWER" > "$USAGE_ANSWER_FILE"
  printf 'usage-validation-answer: %s\n' "$USAGE_ANSWER_FILE"
else
  printf 'usage-validation-skip: kind=%s ask=%s reason=%s\n' \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.skipKind // "unable-to-evaluate"')" \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.askUndeclared // false')" \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.reason // ""')"
fi
# usage-phase-required:end
```

A `usage-validation: tooling-failed` line (a non-zero exit, an empty answer or a `required` that is not a boolean) means the claim is released and the status is left `in_progress`. Report it as Could Not Run (below), write no `handoff.md` and skip directly to Step 5.

#### The stored record and the run values

Read the phase's stored `usageValidation` through a pipe, never by opening a file with `jq`. Set `USAGE_ANSWER_FILE` to the saved answer's path when validation is owed, and to an empty string otherwise.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FEATURE="[FEATURE]"
PHASE_ID="[PHASE_ID]"
AIMI_ROOT="[AIMI_ROOT]"
PHASE_BRANCH="[PHASE_BRANCH]"
USAGE_ANSWER_FILE="[the usage-validation-answer path, or empty]"
# usage-phase-stored:begin
PHASE_JSON=$("$AIMI_CLI" roadmap-get --feature "$FEATURE" --phase "$PHASE_ID") || PHASE_JSON="{}"
printf 'usage-validation-stored: status=%s kind=%s\n' \
  "$(printf '%s' "$PHASE_JSON" | jq -r '.usageValidation.status // "none"')" \
  "$(printf '%s' "$PHASE_JSON" | jq -r '.usageValidation.kind // "none"')"
printf '%s' "$PHASE_JSON" | jq -r '(.usageValidation.findings // {}) | to_entries[] | select(.value.status == "accepted") | "usage-validation-accepted: " + .key'
if [ -n "$USAGE_ANSWER_FILE" ]; then
  USAGE_SAVED=$(cat "$USAGE_ANSWER_FILE")
  printf 'usage-run: %s-phase-%s\n' "$FEATURE" "$(printf '%s' "$PHASE_ID" | tr . -)"
  printf 'usage-project: %s\n' "$(printf '%s' "$USAGE_SAVED" | jq -r '([.charters[] | select(.kind == "web")][0].project) // .projects[0] // "."')"
  printf '%s' "$USAGE_SAVED" | jq -r --arg b "$PHASE_BRANCH" '.projects[] | "usage-repo: " + . + "=" + $b'
  printf '%s' "$USAGE_SAVED" | jq -r '.projects[]' | while IFS= read -r usage_project; do
    case "$usage_project" in
      .) usage_dir="$AIMI_ROOT" ;;
      *) usage_dir="$AIMI_ROOT/$usage_project" ;;
    esac
    usage_top=$(git -C "$usage_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$usage_dir")
    printf 'usage-exec: project=%s root=%s branch=%s\n' "$usage_project" "$usage_top/.worktrees/$PHASE_BRANCH" "$PHASE_BRANCH"
  done
fi
# usage-phase-stored:end
```

`usage-run:` is the run key, `usage-repo:` is one repository value per participating project with `PHASE_BRANCH` as its container, and `usage-exec:` gives each group's `EXEC_ROOT` and `EXEC_BRANCH`. `EXEC_ROOT` is the phase container (`container-execution.md`'s Execution Context table), never the toplevel, where git refuses a fix round's `merge-all --into PHASE_BRANCH`. `usage-validation-stored:` and the `usage-validation-accepted:` keys are what a re-run reads.

#### Skip ladder

**`required=true`:** go to Bring up and validate.

**`required=false`:** the answer's own `skipKind` and reason are recorded, except in the one case below that asks first.

- **`skipKind` is `not-applicable`, `askUndeclared` is true and the stored status is not `skipped`.** In picker mode ask one `Use **AskUserQuestion**` question with lettered options and an Other escape hatch: **A** nothing a person can use (the default) records `not-applicable`; **B** a web UI and **C** a command line, or Other (typed, sanitized per `sanitization.md` Base Rules), say a surface exists that the plan never declared, and record `unable-to-evaluate` with the answered surface in `--reason` (`usage surface declared by the person, not in the plan: <answer>`). A decline or silence is A. In agent mode ask nothing, log `agent-mode: usage-surface auto-recorded not-applicable` and record `not-applicable`.
- **A stored `skipped` record on the phase** answers that question already: reuse it with no question and no overwrite, print `usage-validation: skipped (<stored kind>) — <stored reason>` from the stored record and continue to Write Handoff.
- **`disabled-by-operator`** is never asked about.

Record the skip, then continue to Write Handoff. The block prints the line Write Handoff copies verbatim; a record call that exits non-zero is `tooling-failed`, never recorded. An `unable-to-evaluate` skip never replaces a stored `failing` record: the writer answers `kept` and the block prints the kept line handled under Record the outcome.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FEATURE="[FEATURE]"
PHASE_ID="[PHASE_ID]"
USAGE_KIND="[not-applicable, unable-to-evaluate or disabled-by-operator]"
USAGE_REASON=$(cat <<'USAGE_REASON_EOF'
[the reason: the answer's, or the sanitized one for the undeclared surface]
USAGE_REASON_EOF
)
# usage-phase-skip:begin
if USAGE_OUT=$("$AIMI_CLI" roadmap-record-usage-validation --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --kind "$USAGE_KIND" --reason "$USAGE_REASON"); then
  if [ "$(printf '%s' "$USAGE_OUT" | jq -r '.kept // empty' 2>/dev/null)" = failing ]; then
    printf 'usage-validation: failing — re-validation could not run (%s)\n' "$USAGE_REASON"
    "$AIMI_CLI" roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
    "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  else
    printf 'usage-validation: skipped (%s) — %s\n' "$USAGE_KIND" "$USAGE_REASON"
  fi
else
  echo "usage-validation: tooling-failed"
  "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
fi
# usage-phase-skip:end
```

#### Bring up and validate

1. Run the **Usage Validation Environment** entry's bring-up, Poll, Origins and Login and Browser sections. Its inputs: `USAGE_RUN` is the `usage-run:` value, `USAGE_REPOS` is every `usage-repo:` value, `USAGE_PROJECT` is `usage-project:`, `USAGE_SESSION` is `aimi-usage-<run key>`, and `USAGE_RESTART` is `true` exactly when `usage-validation-stored:` says `status=failing` (a re-validation on re-run) and `false` otherwise.
2. Read its `usage-env:` line. `unable-to-evaluate` records a skip with the block above (`USAGE_KIND=unable-to-evaluate`, the reason naming the stage and reason it printed) and the phase continues to Write Handoff, unless that block printed the kept `failing` line. `tooling-failed` is handled as the loop's `tooling-failed` below and the loop is not run.
3. On `ready`, run the **Usage Validation Loop** entry. Its inputs, as that entry's Inputs and outputs section names them: the `usage-validation-answer:` file, its `usage-browser:` and `usage-origins:` values, the run key and repositories handed to step 1, the `usage-validation-accepted:` keys as the accepted keys, and the run's `FEATURE`, `PHASE_ID`, `PHASE_MODE=true` and each group's `EXEC_ROOT` and `EXEC_BRANCH` from the `usage-exec:` lines.
4. Run the Environment's Tear Down on every outcome except `fails` (`USAGE_VALIDATION_OUTCOME` is `passing` for `pass` and `skipped` otherwise). On `fails` the container and the server stay up for the person.

#### Record the outcome

Paste the loop's three result lines into the block: `USAGE_LOOP_LINE` is the `usage-loop:` line, `USAGE_LOOP_FINDINGS` the object after `usage-loop-findings:`, `USAGE_LOOP_REASON` the text after `usage-loop-reason:` (empty on `pass`). The block reads the line by field name, so a reordered field cannot break it, and builds its optional flags with `set --` so bash and zsh split alike. `--review` is passed only when that file exists.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FEATURE="[FEATURE]"
PHASE_ID="[PHASE_ID]"
AIMI_ROOT="[AIMI_ROOT]"
USAGE_LOOP_LINE="[the usage-loop: line, verbatim]"
USAGE_LOOP_FINDINGS=$(cat <<'USAGE_FINDINGS_EOF'
[the object printed after usage-loop-findings:]
USAGE_FINDINGS_EOF
)
USAGE_LOOP_REASON=$(cat <<'USAGE_LOOP_REASON_EOF'
[the text printed after usage-loop-reason:, or empty]
USAGE_LOOP_REASON_EOF
)
# usage-phase-record:begin
usage_loop_field() { printf '%s\n' "$USAGE_LOOP_LINE" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1; }
usage_tooling_failed() {
  echo "usage-validation: tooling-failed"
  "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
}
USAGE_OUTCOME=$(usage_loop_field outcome)
USAGE_ROUNDS=$(usage_loop_field rounds)
USAGE_REVIEW=$(usage_loop_field review)
USAGE_ACCEPTED_N=$(usage_loop_field accepted)
case "$USAGE_ROUNDS" in ''|*[!0-9]*) USAGE_ROUNDS=0 ;; esac
set --
set -- "$@" --rounds "$USAGE_ROUNDS"
case "$USAGE_LOOP_FINDINGS" in ''|'{}') ;; *) set -- "$@" --findings-json "$USAGE_LOOP_FINDINGS" ;; esac
USAGE_REVIEW_FILE="$USAGE_REVIEW"
case "$USAGE_REVIEW_FILE" in /*) ;; *) USAGE_REVIEW_FILE="$AIMI_ROOT/$USAGE_REVIEW_FILE" ;; esac
[ -n "$USAGE_REVIEW" ] && [ -f "$USAGE_REVIEW_FILE" ] && set -- "$@" --review "$USAGE_REVIEW"
case "$USAGE_OUTCOME" in
  pass)
    "$AIMI_CLI" roadmap-record-usage-validation --feature "$FEATURE" --phase "$PHASE_ID" --status passed "$@" >/dev/null || usage_tooling_failed
    printf 'usage-validation: passed — %s fix round(s), %s accepted\n' "$USAGE_ROUNDS" "${USAGE_ACCEPTED_N:-0}"
    ;;
  fails)
    "$AIMI_CLI" roadmap-record-usage-validation --feature "$FEATURE" --phase "$PHASE_ID" --status failing --reason "$USAGE_LOOP_REASON" "$@" >/dev/null || usage_tooling_failed
    "$AIMI_CLI" roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
    "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    printf 'usage-validation-verdict: failing review=%s\n' "${USAGE_REVIEW:-<not written>}"
    ;;
  unable-to-evaluate)
    USAGE_OUT=$("$AIMI_CLI" roadmap-record-usage-validation --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --kind unable-to-evaluate --reason "$USAGE_LOOP_REASON" "$@") || usage_tooling_failed
    if [ "$(printf '%s' "$USAGE_OUT" | jq -r '.kept // empty' 2>/dev/null)" = failing ]; then
      printf 'usage-validation: failing — re-validation could not run (%s)\n' "$USAGE_LOOP_REASON"
      "$AIMI_CLI" roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
      "$AIMI_CLI" roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    else
      printf 'usage-validation: skipped (unable-to-evaluate) — %s\n' "$USAGE_LOOP_REASON"
    fi
    ;;
  *)
    usage_tooling_failed
    ;;
esac
# usage-phase-record:end
```

- **`usage-validation: passed — <summary>`** and **`usage-validation: skipped (<kind>) — <reason>`** are recorded; the phase falls through to Write Handoff, which copies the line verbatim, plus the loop's `usage-validation-stale:` line when one printed.
- **`usage-validation: failing — re-validation could not run (<reason>)`** — the writer kept the stored `failing` record (`kept`); the phase is `verification_failed` and the claim is released. Handle it as the failing verdict below.
- **`usage-validation-verdict: failing`** — recorded `failing` with the round count and each finding key's status (accepted decisions included, so they survive into the re-run), the phase is `verification_failed` and the claim is released. Report the review file, the findings the loop printed, and that re-running `/aimi:execute` validates again. Do **not** write `handoff.md`, do **not** run Mark Phase Completed, do **not** offer a PR, do **not** run Next Phase. Skip directly to Step 5.
- **`usage-validation: tooling-failed`** — nothing was recorded, the claim is released and the status stays `in_progress`. Report:

  ```
  ## Phase [PHASE_ID] Usage Validation Could Not Run

  Usage validation did not produce a usable verdict. This is NOT a finding that
  the product fails — nothing was proven either way.

  Phase status is unchanged (in_progress) and the claim is released. Re-run
  /aimi:execute -- usage validation runs again on the next pass.
  ```

  Do **not** write `handoff.md`, do **not** offer a PR, do **not** run Next Phase. Skip directly to Step 5.

#### Never

- Never write `handoff.md` and never set `completed`: Write Handoff and Mark Phase Completed own both.
- Never call `project-groups`, read `PHASE_SPLIT_MODE` or record a skip for "more than one repository".
- Never read the two cited entries' files directly: the Usage Validation Environment and the Usage Validation Loop are router entries, read through their own `Read` lines.
- Never record `accepted` for an undeclared surface or a finding in agent mode, and never overwrite a stored `skipped` record to ask again.
