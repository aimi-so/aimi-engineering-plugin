# Execute: Step 4: Flat Usage Validation

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Flat Usage Validation Step

Runs after Finalize and before Step 5's container teardown (teardown removes the worktree the validator drives), and again when a failing run is re-executed (Step 3's Re-validate block), so a plan whose delivered product was never used for real cannot pass silently and every skip says why. A multi-repository or split plan is validated like any other (`members` and `projects` are information only). An inline run is validated on the checkout itself over loopback only; none is skipped for being inline. It never aborts `/aimi:execute`: every end is one `usage-validation:` line and the run goes on to Step 5.

Every Bash call is an isolated shell: re-resolve `AIMI_CLI` at the top of each block. The `Use **AskUserQuestion**` and agent-mode rules are `${CLAUDE_PLUGIN_ROOT}/commands/references/interactivity.md`; typed text is sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` Base Rules before it reaches `--reason`.

#### Is validation owed

One `usage-validation-required` call per run, read-only, on the run's own tasks file. The answer is saved under `.aimi/` only when validation is owed. A non-zero exit, an empty answer, a `required` that is not a boolean or an unwritable file is tooling-failed: the block prints a skip line for `unable-to-evaluate` naming the stage, and the Skip ladder records it.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RUN_TASKS_FILE="[tasks path from the init-session output]"
AIMI_ROOT="[AIMI_ROOT]"
# usage-flat-required:begin
usage_failed() {
  echo "usage-validation-required: tooling-failed"
  printf 'usage-validation-skip: kind=unable-to-evaluate ask=false reason=%s\n' "$1"
  exit 0
}
USAGE_ANSWER=$("$AIMI_CLI" usage-validation-required --tasks-file "$RUN_TASKS_FILE") || usage_failed "usage-validation-required: exited non-zero"
[ -n "$USAGE_ANSWER" ] || usage_failed "usage-validation-required: empty answer"
USAGE_REQUIRED=$(printf '%s' "$USAGE_ANSWER" | jq -r 'if (.required | type) == "boolean" then (.required | tostring) else "invalid" end' 2>/dev/null) || USAGE_REQUIRED=""
case "$USAGE_REQUIRED" in true|false) ;; *) usage_failed "usage-validation-required: answer carries no boolean required" ;; esac
printf 'usage-validation-required: required=%s skipKind=%s surfaceSource=%s members=%s projects=%s charters=%s\n' "$USAGE_REQUIRED" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.skipKind // "none"')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.surfaceSource // "none"')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.members // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.projects // []) | join(",")')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.charters // []) | length')"
if [ "$USAGE_REQUIRED" = "true" ]; then
  USAGE_ANSWER_FILE=$(mktemp "$AIMI_ROOT/.aimi/usage-required-XXXXXX") || usage_failed "answer file: could not be created under .aimi"
  printf '%s\n' "$USAGE_ANSWER" > "$USAGE_ANSWER_FILE" || usage_failed "answer file: could not be written"
  printf 'usage-validation-answer: %s\n' "$USAGE_ANSWER_FILE"
else
  printf 'usage-validation-skip: kind=%s ask=%s reason=%s\n' \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.skipKind // "unable-to-evaluate"')" \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.askUndeclared // false')" \
    "$(printf '%s' "$USAGE_ANSWER" | jq -r '.reason // ""')"
fi
# usage-flat-required:end
```

#### The stored record and the run values

Read the stored record from the `metadata` verb through a pipe, never by opening a file with `jq`. Set `USAGE_ANSWER_FILE` to the saved answer's path when validation is owed, and to an empty string otherwise. This block re-derives each project group's `EXEC_ROOT` and `EXEC_BRANCH` by the table in `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` (inline: the project's checkout and `branchName`; container: that checkout plus `/.worktrees/` plus `branchName`), since Step 4's values do not survive a re-validate. The run key is the tasks file's name, as `PLAN_DISC` is derived in Step 5, so a re-run finds the earlier state.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RUN_TASKS_FILE="[tasks path from the init-session output]"
AIMI_ROOT="[AIMI_ROOT]"
CONTAINER_MODE="[CONTAINER_MODE from Step 1]"
USAGE_ANSWER_FILE="[the usage-validation-answer path, or empty]"
META_JSON=$("$AIMI_CLI" metadata --tasks-file "$RUN_TASKS_FILE") || META_JSON="{}"
BRANCH_NAME=$(printf '%s' "$META_JSON" | jq -r '.branchName // ""')
printf 'usage-validation-stored: status=%s kind=%s reason=%s\n' \
  "$(printf '%s' "$META_JSON" | jq -r '.usageValidation.status // "none"')" \
  "$(printf '%s' "$META_JSON" | jq -r '.usageValidation.kind // "none"')" \
  "$(printf '%s' "$META_JSON" | jq -r '.usageValidation.reason // ""')"
printf '%s' "$META_JSON" | jq -r '(.usageValidation.findings // {}) | to_entries[] | select(.value.status == "accepted") | "usage-validation-accepted: " + .key'
if [ -n "$USAGE_ANSWER_FILE" ]; then
  USAGE_SAVED=$(cat "$USAGE_ANSWER_FILE")
  USAGE_RUN=$(basename "$RUN_TASKS_FILE" .json | sed 's/[^A-Za-z0-9_-]/-/g')
  case "$USAGE_RUN" in [A-Za-z0-9]*) ;; *) USAGE_RUN="p$USAGE_RUN" ;; esac
  printf 'usage-run: %s\n' "$USAGE_RUN"
  printf 'usage-project: %s\n' "$(printf '%s' "$USAGE_SAVED" | jq -r '([.charters[] | select(.kind == "web")][0].project) // .projects[0] // "."')"
  printf '%s' "$USAGE_SAVED" | jq -r '.projects[]' | while IFS= read -r usage_project; do
    case "$usage_project" in
      .) usage_dir="$AIMI_ROOT" ;;
      *) usage_dir="$AIMI_ROOT/$usage_project" ;;
    esac
    usage_top=$(git -C "$usage_dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$usage_dir")
    if [ "$CONTAINER_MODE" = "true" ]; then
      printf 'usage-repo: %s=%s\n' "$usage_project" "$BRANCH_NAME"
      printf 'usage-exec: project=%s root=%s branch=%s\n' "$usage_project" "$usage_top/.worktrees/$BRANCH_NAME" "$BRANCH_NAME"
    else
      printf 'usage-repo: %s\n' "$usage_project"
      printf 'usage-exec: project=%s root=%s branch=%s\n' "$usage_project" "$usage_top" "$BRANCH_NAME"
    fi
  done
fi
```

#### Skip ladder

**`required=true`:** go to Bring up and validate.

**`required=false`** (or the tooling-failed skip line above): the answer's own `skipKind` and reason are recorded, except in the one case below that asks first.

- **`skipKind` is `not-applicable`, `askUndeclared` is true and the stored status is not `skipped`.** In picker mode ask one `Use **AskUserQuestion**` question with lettered options and an Other escape hatch: **A** nothing a person can use (the default) records `not-applicable`; **B** a web UI and **C** a command line, or Other (typed, sanitized per `sanitization.md` Base Rules), say a surface exists that the plan never declared, and record `unable-to-evaluate` with the answered surface in `--reason` (`usage surface declared by the person, not in the plan: <answer>`). A decline or silence is A. In agent mode ask nothing, log `agent-mode: usage-surface auto-recorded not-applicable` and record `not-applicable`.
- **A stored `skipped` record** answers that question already: reuse it with no question and no overwrite, print `usage-validation: skipped (<stored kind>) — <stored reason>` and go to Step 5.
- **`disabled-by-operator`** is never asked about.

A stored `failing` record is replaced only by a verdict that judged the product (`passed`, `failing`) or by a skip somebody chose (`not-applicable`, `disabled-by-operator`). An `unable-to-evaluate` end learned nothing: the writer keeps the `failing` record, answers `{"kept":"failing", ...}` and the block prints `usage-validation: failing — re-validation could not run (<stage>: <reason>)`, so a broken environment on a re-run cannot unblock a run whose severe findings are still open. The writer decides this inside its lock, so the block does not read the stored status itself. A record call that exits non-zero prints `usage-validation: tooling-failed` and records nothing; the run still goes to Step 5.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RUN_TASKS_FILE="[tasks path from the init-session output]"
USAGE_KIND="[not-applicable, unable-to-evaluate or disabled-by-operator]"
USAGE_REASON=$(cat <<'USAGE_REASON_EOF'
[the reason: the answer's, or the sanitized one for the undeclared surface]
USAGE_REASON_EOF
)
# usage-flat-skip:begin
if ! USAGE_OUT=$("$AIMI_CLI" usage-validation-record --tasks-file "$RUN_TASKS_FILE" --status skipped --kind "$USAGE_KIND" --reason "$USAGE_REASON"); then
  echo "usage-validation: tooling-failed"
elif [ "$(printf '%s' "$USAGE_OUT" | jq -r '.kept // empty' 2>/dev/null)" = failing ]; then
  printf 'usage-validation: failing — re-validation could not run (%s)\n' "$USAGE_REASON"
else
  printf 'usage-validation: skipped (%s) — %s\n' "$USAGE_KIND" "$USAGE_REASON"
fi
# usage-flat-skip:end
```

#### Bring up and validate

1. Run the **Usage Validation Environment** entry's Recipe, Bring-up, Poll, Origins and Login and Browser sections. Its inputs: `USAGE_RUN` is `usage-run:`, `USAGE_REPOS` every `usage-repo:` value, `USAGE_PROJECT` is `usage-project:`, `USAGE_SESSION` is `aimi-usage-<run key>`, and `USAGE_RESTART` is `true` exactly when `usage-validation-stored:` says `status=failing` (a re-validation) and `false` otherwise.
2. Read its `usage-env:` line. `ready` goes to step 3. `unable-to-evaluate` or `tooling-failed` skips the loop and goes to Record the outcome with that line and its `usage-env-reason:`.
3. Run the **Usage Validation Loop** entry. Its inputs, as that entry's Inputs and outputs section names them: the `usage-validation-answer:` file, the Environment's `usage-browser:` and `usage-origins:` values, the run key and repositories handed to step 1, the `usage-validation-accepted:` keys as the accepted keys, `PHASE_MODE=false` and each group's `EXEC_ROOT` and `EXEC_BRANCH` from the `usage-exec:` lines. Nothing else.
4. Run the Environment's Tear Down on every end except the loop's `fails` (`USAGE_VALIDATION_OUTCOME` is `passing` for `pass` and `skipped` otherwise). On `fails` the container and the server stay up for the person and no tear-down runs.

#### Record the outcome

Paste the Environment's outcome and reason and the loop's result lines: `USAGE_LOOP_LINE` is the `usage-loop:` line (empty when the loop did not run), `USAGE_LOOP_FINDINGS` the object after `usage-loop-findings:`, `USAGE_LOOP_REASON` the text after `usage-loop-reason:`, and `USAGE_STALE_LINE` the `usage-validation-stale:` line when one printed. The block reads the line by field name and builds optional flags with `set --`; `--review` is passed only when that file exists. `pass` records `passed`; `fails` records `failing` and prints the failing line; `unable-to-evaluate`, `tooling-failed`, any other word or an Environment that was not `ready` is a skip that learned nothing, which the writer keeps off a stored `failing` record.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RUN_TASKS_FILE="[tasks path from the init-session output]"
AIMI_ROOT="[AIMI_ROOT]"
USAGE_ENV_OUTCOME="[ready, unable-to-evaluate or tooling-failed]"
USAGE_ENV_REASON="[the usage-env-reason: text, or empty]"
USAGE_STALE_LINE="[the usage-validation-stale: line, or empty]"
USAGE_LOOP_LINE="[the usage-loop: line, verbatim, or empty]"
USAGE_LOOP_FINDINGS=$(cat <<'USAGE_FINDINGS_EOF'
[the object printed after usage-loop-findings:]
USAGE_FINDINGS_EOF
)
USAGE_LOOP_REASON=$(cat <<'USAGE_LOOP_REASON_EOF'
[the text printed after usage-loop-reason:, or empty]
USAGE_LOOP_REASON_EOF
)
# usage-flat-record:begin
usage_loop_field() { printf '%s\n' "$USAGE_LOOP_LINE" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1; }
usage_skip_unable() {
  if ! USAGE_OUT=$("$AIMI_CLI" usage-validation-record --tasks-file "$RUN_TASKS_FILE" --status skipped --kind unable-to-evaluate --reason "$1"); then
    echo "usage-validation: tooling-failed"
  elif [ "$(printf '%s' "$USAGE_OUT" | jq -r '.kept // empty' 2>/dev/null)" = failing ]; then
    printf 'usage-validation: failing — re-validation could not run (%s)\n' "$1"
  else
    printf 'usage-validation: skipped (unable-to-evaluate) — %s\n' "$1"
  fi
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
if [ "$USAGE_ENV_OUTCOME" != "ready" ]; then
  usage_skip_unable "environment: ${USAGE_ENV_REASON:-$USAGE_ENV_OUTCOME}"
else
  case "$USAGE_OUTCOME" in
    pass)
      if "$AIMI_CLI" usage-validation-record --tasks-file "$RUN_TASKS_FILE" --status passed "$@" >/dev/null; then
        printf 'usage-validation: passed — %s fix round(s), %s accepted\n' "$USAGE_ROUNDS" "${USAGE_ACCEPTED_N:-0}"
      else
        echo "usage-validation: tooling-failed"
      fi
      ;;
    fails)
      if "$AIMI_CLI" usage-validation-record --tasks-file "$RUN_TASKS_FILE" --status failing --reason "$USAGE_LOOP_REASON" "$@" >/dev/null; then
        printf 'usage-validation: failing — %s\n' "$USAGE_LOOP_REASON"
      else
        echo "usage-validation: tooling-failed"
      fi
      ;;
    unable-to-evaluate) usage_skip_unable "loop: $USAGE_LOOP_REASON" ;;
    *) usage_skip_unable "loop: ${USAGE_LOOP_REASON:-no usable usage-loop line}" ;;
  esac
fi
[ -n "$USAGE_STALE_LINE" ] && printf '%s\n' "$USAGE_STALE_LINE"
# usage-flat-record:end
```

- **`passed`** and **`skipped (<kind>)`** lines are recorded; go to Step 5.
- **`usage-validation: failing — <reason>`** after a `fails` end is recorded with the round count and each finding key's status (accepted decisions included, so they survive into the re-run). The container and its server stay up, no tear-down runs, and re-running `/aimi:execute` validates again. Report the review file and the findings, then go to Step 5.
- **`usage-validation: tooling-failed`** recorded nothing. Report it, and that usage validation runs again on the next `/aimi:execute`; go to Step 5.

#### Never

- Never edit `step-5-completion.md`, and never stop a server or remove a container except through the Environment's Tear Down.
- Never call `project-groups` or record a skip for "more than one repository".
- Never read the two cited entries' files directly: the Usage Validation Environment and the Usage Validation Loop are router entries, read through their own `Read` lines.
- Never record `accepted` for an undeclared surface or a finding in agent mode, and never overwrite a stored `skipped` record to ask again.
