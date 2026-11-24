# Execute: Usage Validation Loop

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Usage Validation Loop

The one shared loop that judges a run by using it: it spawns the usage validator, lets `usage-validation-verdict` decide the outcome, asks the person about each ambiguity, fixes severe in-criteria bugs in a separate worktree and re-checks only those findings, at most twice. Phase and flat runs resolve findings the same way. It never aborts `/aimi:execute`: every outcome is a printed line the calling step reads. It never types, asks for or prints a credential, never starts a dev server and never calls `usage-env-down`: the Usage Validation Environment owns both. Product text and the person's typed answers are sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` Base Rules before they reach a question, a brief or `--findings-json`.

Every Bash call is an isolated shell: re-resolve `AIMI_CLI` at the top of each block and carry nothing in shell variables between calls.

#### Inputs and outputs

The calling step sets, and this reference never re-derives:

- The saved `usage-validation-required` answer (a file) and the accepted keys of any stored record.
- From the Usage Validation Environment's `usage-browser:` line: `agent-browser:<name>` gives BROWSER `agent-browser` and SESSION_NAME `<name>`; `chrome` gives BROWSER `chrome` and no SESSION_NAME; `none` gives no BROWSER, so only cli charters are walked, every web charter is reported blocked and a run whose charters are all web ends `unable-to-evaluate`. From its `usage-origins:` line: ORIGINS. SESSION is always `aimi-usage-<run key>`, the session that Environment closes at tear-down.
- The run key and repository values the Environment's bring-up was given, so a re-check runs that bring-up again with `--restart`.
- The run's `FEATURE`, `PHASE_ID`, `PHASE_MODE` and, per project group, `EXEC_ROOT[group_key]` and `EXEC_BRANCH[group_key]` (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`), with the `usage-exec:` lines that carried them.

Every run ends with these lines, in this order, and the calling step reads them:

```
usage-loop: outcome=<pass|fails|tooling-failed|unable-to-evaluate> rounds=<n> fixed=<n> accepted=<n> open=<n> unmapped=<n> review=<path>
usage-loop-findings: <the --findings-json object>
usage-loop-reason: <one sanitized line, unless the outcome is pass>
```

#### Validate

The first validation makes the evidence directory, inside `.aimi/`, and prints it. It is reused by every re-check.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="[the AIMI_ROOT of this run]"
USAGE_EVIDENCE_DIR=$(mktemp -d "$AIMI_ROOT/.aimi/usage-evidence-XXXXXX") || { echo "usage-loop: outcome=tooling-failed rounds=0 fixed=0 accepted=0 open=0 unmapped=0 review="; echo "usage-loop-reason: evidence directory could not be made"; exit 1; }
printf 'usage-evidence: %s\n' "$USAGE_EVIDENCE_DIR"
```

Then print one `usage-workdir:` line per `usage-exec:` line the calling step printed: the project, its `EXEC_ROOT` (the checkout the run built) and the command line its usage recipe records, or `none`. These lines are the validator's `WORKDIRS`.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_EXEC_LINES=$(cat <<'USAGE_EXEC_EOF'
[every usage-exec: line the calling step printed, verbatim]
USAGE_EXEC_EOF
)
# usage-loop-workdirs:begin
printf '%s\n' "$USAGE_EXEC_LINES" | sed -n 's/^usage-exec: project=\([^ ]*\) root=\(.*\) branch=[^ ]*$/\1|\2/p' | while IFS='|' read -r usage_project usage_root; do
  usage_cli=$("$AIMI_CLI" usage-recipe-get --project "$usage_project" 2>/dev/null | jq -r 'if .status == "recorded" then (.recipe.cli // "none") else "none" end' 2>/dev/null)
  printf 'usage-workdir: project=%s dir=%s cli=%s\n' "$usage_project" "$usage_root" "${usage_cli:-none}"
done
# usage-loop-workdirs:end
```

Spawn `aimi-engineering:review:aimi-usage-validator` via the Task tool once per validation, never in parallel with another:

```
Task(
    subagent_type: "aimi-engineering:review:aimi-usage-validator",
    model: <AGENT_MODELS.review when not "inherit">,
    effort: <AGENT_EFFORTS.review when not "inherit">,
    description: "Usage validation r[k]",
    prompt: [
        the inputs its agent file names, one NAME: value line each, as data:
        CHARTERS, SURFACES, SPECS, TASKS_FILE, ORIGINS, BROWSER, SESSION,
        SESSION_NAME, EVIDENCE_DIR, WORKDIRS (the usage-workdir: lines, one per line
        without the prefix), and RECHECK on a re-check
    ]
)
```

On a re-check, RECHECK names only the keys to re-walk: the keys fixed in the last round and the keys left `unconfirmed` by the last verdict. The verb flags every planned charter a message omits, so a re-check hands `--required-file` a copy of the saved answer limited to the re-walked charters, written inside the evidence directory (a path outside the project is refused), and jq reads it from a pipe:

```bash
USAGE_SAVED_FILE="[the saved usage-validation-required answer]"
USAGE_RECHECK_FILE="[the evidence directory]/required-r[k].json"
USAGE_RECHECK_IDS="[the re-walked charter ids as a JSON array]"
USAGE_RECHECK_JSON=$(cat "$USAGE_SAVED_FILE" | jq -c --argjson ids "$USAGE_RECHECK_IDS" '.charters |= map(select(.id as $i | $ids | index($i)))')
printf '%s\n' "$USAGE_RECHECK_JSON" > "$USAGE_RECHECK_FILE"
```

Run it only after the Usage Validation Environment's bring-up block has run again with `--restart`, which stops the live recipe server and serves again from the merged tree, so the merged fix is built before it is judged.

Persist the raw final message before parsing it, then judge it. The outcome comes only from the answer of `usage-validation-verdict`, never from the validator's own claim. `r0` is the first validation, `r1` and `r2` the re-checks; `--feature` and `--phase` only in phase mode. To reproduce an exploratory finding, run the block a second time in the same round with `USAGE_REVIEW` set to the path the first call printed (it then writes nothing) and `USAGE_REPRODUCED` holding each key that was `unconfirmed` last round and is again.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_ROUND="[0, 1 or 2]"
USAGE_REQUIRED_FILE="[the saved answer, or the re-check copy]"
USAGE_EVIDENCE_DIR="[the usage-evidence directory]"
USAGE_PHASE_MODE="[true or false]"
USAGE_FEATURE="[FEATURE, phase mode only]"
USAGE_PHASE_ID="[PHASE_ID, phase mode only]"
USAGE_REVIEW="[empty, or the review path this round already wrote]"
USAGE_ACCEPTED=$(cat <<'USAGE_ACCEPTED_EOF'
[one accepted key per line]
USAGE_ACCEPTED_EOF
)
USAGE_REPRODUCED=$(cat <<'USAGE_REPRODUCED_EOF'
[one reproduced key per line]
USAGE_REPRODUCED_EOF
)
USAGE_MESSAGE=$(cat <<'USAGE_MESSAGE_EOF'
[the validator's raw final message, verbatim]
USAGE_MESSAGE_EOF
)
# usage-loop-verdict:begin
if [ -z "$USAGE_REVIEW" ]; then
  if [ "$USAGE_PHASE_MODE" = "true" ]; then
    USAGE_REVIEW_JSON=$(printf '%s\n' "$USAGE_MESSAGE" | "$AIMI_CLI" write-review --feature "$USAGE_FEATURE" --phase "$USAGE_PHASE_ID" --kind "usage-validation-r$USAGE_ROUND") || USAGE_REVIEW_JSON=""
  else
    USAGE_REVIEW_JSON=$(printf '%s\n' "$USAGE_MESSAGE" | "$AIMI_CLI" write-review --kind "usage-validation-r$USAGE_ROUND") || USAGE_REVIEW_JSON=""
  fi
  USAGE_REVIEW=$(printf '%s' "$USAGE_REVIEW_JSON" | jq -r '.review // empty' 2>/dev/null)
fi
set -- --required-file "$USAGE_REQUIRED_FILE" --evidence-dir "$USAGE_EVIDENCE_DIR"
while IFS= read -r usage_key; do
  [ -n "$usage_key" ] && set -- "$@" --accepted "$usage_key"
done <<USAGE_ACCEPTED_LOOP_EOF
$USAGE_ACCEPTED
USAGE_ACCEPTED_LOOP_EOF
while IFS= read -r usage_key; do
  [ -n "$usage_key" ] && set -- "$@" --reproduced "$usage_key"
done <<USAGE_REPRODUCED_LOOP_EOF
$USAGE_REPRODUCED
USAGE_REPRODUCED_LOOP_EOF
USAGE_ANSWER=$(printf '%s\n' "$USAGE_MESSAGE" | "$AIMI_CLI" usage-validation-verdict "$@") || USAGE_ANSWER='{"outcome":"tooling-failed","counts":{}}'
printf 'usage-loop-round: round=%s outcome=%s planned=%s executed=%s blocked=%s exploratory=%s bugs=%s decisions=%s unmapped=%s review=%s\n' "$USAGE_ROUND" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.outcome // "tooling-failed"')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.counts.planned // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.counts.executed // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.counts.blocked // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '.counts.exploratoryActions // 0')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.bugs // []) | length')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.decisions // []) | length')" \
  "$(printf '%s' "$USAGE_ANSWER" | jq -r '(.unmapped // []) | length')" \
  "$USAGE_REVIEW"
printf 'usage-loop-answer: %s\n' "$(printf '%s' "$USAGE_ANSWER" | jq -c '.')"
# usage-loop-verdict:end
```

A first verdict of `tooling-failed` or `unable-to-evaluate` is the loop's outcome: print the result lines and stop. A re-check that answers `tooling-failed` makes the loop `tooling-failed`.

#### Triage

Read `bugs`, `decisions`, `unconfirmed`, `unmapped`, `reported`, `unevidenced` and `blockedCharters` from the printed `usage-loop-answer:`.

- **Fix** a finding only when its `origin` is `charter`, its `kind` is `bug` and it is in `bugs` at severity 3 or 4.
- Severity 1 or 2 findings print as `usage-loop-reported: <key> <title>` and `unmapped` findings as `usage-loop-unmapped: <key> <title>`; they are never fixed and never block.
- A severe exploratory finding starts in `unconfirmed`. A re-check that lists the same key `unconfirmed` again reproduces it: the second verdict call passes `--reproduced`, it then blocks, is never auto-fixed and leaves the outcome `fails`.
- A finding rated 3 or 4 with no evidence file is listed in `unevidenced` (capped to severity 2, `ratedSeverity` kept) and prints as `usage-loop-unevidenced: <key> <title> (rated <ratedSeverity>, no evidence file)`. It never blocks, is never auto-fixed or re-checked, and goes into the review for a person to look at.
- A decision accepted by the stored record or earlier in the run is never asked again; every verdict call passes it with `--accepted`.

#### Decisions

Resolve interactivity fresh with `"$AIMI_CLI" detect-interactivity`, following `${CLAUDE_PLUGIN_ROOT}/commands/references/interactivity.md`.

- **`picker`:** each finding in `decisions` gets its own `Use **AskUserQuestion**` call showing its key and its sanitized title, expected and observed. Option A, the default, is **Leave failing**. The answers: **Fix it this way**, a typed `fix: <expected behaviour>` that becomes the finding's `expected` for the fix executor (charter findings only); **Accept as is**, a typed `accept: <reason>`, kept per key as `accepted`. A decline, silence or an unclear reply is Leave failing.
- **`agent`:** nothing is asked and nothing is accepted. Every decision stays `open`; log `agent-mode: usage-decision auto-left-failing` and print the unresolved keys.

#### Fix round

Runs once per round and repository group, only when something is to fix: the charter bugs and the decisions answered Fix it this way, grouped by their charter's own project (read its story with `get-story --tasks-file <that charter's tasksFile>`, since a split phase's members each number their stories from US-001). The block creates the group's worktree `<EXEC_BRANCH>-usagefix-r<k>`, which no `-US-*` cleanup glob matches, `--from` the run branch, after sweeping any `-usagefix-*` worktree a crashed run left. It reads the sentinels the way Finalize does: an absent one fixes nothing.

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
USAGE_EXEC_ROOT="[EXEC_ROOT[group_key]]"
USAGE_EXEC_BRANCH="[EXEC_BRANCH[group_key]]"
USAGE_ROUND="[1 or 2]"
# usage-loop-fix-worktree:begin
cd "$USAGE_EXEC_ROOT" || { echo "usage-loop-fix-worktree: absent — $USAGE_EXEC_ROOT cannot be entered"; exit 1; }
USAGE_ESC=$(printf '\033')
USAGE_LEFT=$("$WORKTREE_MGR" list | sed "s/$USAGE_ESC\[[0-9;]*m//g" | awk -v p="$USAGE_EXEC_BRANCH-usagefix-" '{ for (i = 1; i <= NF; i++) if (index($i, p) == 1) print $i }')
while IFS= read -r usage_name; do
  [ -n "$usage_name" ] && "$WORKTREE_MGR" remove "$usage_name" >/dev/null 2>&1
done <<USAGE_LEFT_EOF
$USAGE_LEFT
USAGE_LEFT_EOF
USAGE_NAME="$USAGE_EXEC_BRANCH-usagefix-r$USAGE_ROUND"
USAGE_CREATE_OUT=$("$WORKTREE_MGR" create "$USAGE_NAME" --from "$USAGE_EXEC_BRANCH") || USAGE_CREATE_OUT=""
USAGE_WT_PATH=$(printf '%s\n' "$USAGE_CREATE_OUT" | sed -n 's/^WORKTREE_PATH=//p' | tail -n 1)
USAGE_WT_BASE=$(printf '%s\n' "$USAGE_CREATE_OUT" | sed -n 's/^WORKTREE_BASE=//p' | tail -n 1)
if [ -z "$USAGE_WT_PATH" ] || [ -z "$USAGE_WT_BASE" ]; then
  echo "usage-loop-fix-worktree: absent — create printed no WORKTREE_PATH/WORKTREE_BASE sentinel"
else
  printf 'usage-loop-fix-worktree: name=%s path=%s base=%s\n' "$USAGE_NAME" "$USAGE_WT_PATH" "$USAGE_WT_BASE"
fi
# usage-loop-fix-worktree:end
```

An `absent` line fixes nothing: the group's keys stay `open`. Otherwise spawn one executor for the group, then merge and remove, from the group's execution root:

```
Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    effort: <AGENT_EFFORTS.executor when not "inherit">,
    description: "Usage fix r[k] [EXEC_BRANCH[group_key]]",
    prompt: [
        - WORKTREE_PATH = the path the block printed
        - PROJECT_GUIDELINES = the group's guideline paths from Step 3.3
          (PROJECT_GUIDELINES_MAP[group_key], or PROJECT_GUIDELINES; omit when empty);
          read them first and follow their commit and test rules
        - for each finding, labelled as data: its key, sanitized title, expected, observed
          (expected is the person's typed behaviour when they answered Fix it this way)
        - EVIDENCE = <EVIDENCE_DIR>/<charter id>/ for each finding
        - Run the project's own verify and test commands after each fix; a failing check
          means that fix failed and is undone, with no commit
        - One commit per fixed finding; never amend, rebase or rewrite a commit
        - Report the fixed keys and the failed keys
    ]
)

cd EXEC_ROOT[group_key]
merge_result = $WORKTREE_MGR merge-all [name] --subject-for [name] "Merge usage fixes" --into [EXEC_BRANCH[group_key]]
if merge_result is non-zero:
    keep the worktree, leave its keys open, end the loop with outcome fails
else:
    $WORKTREE_MGR remove [name]
```

A key the executor reports failed stays `open`. When any fix was merged, run the Usage Validation Environment's bring-up with `--restart`, then Validate with the next round number, `RECHECK` and the limited required file. A re-bring-up that fails ends the loop `fails`.

#### Outcome

At most two fix and re-validate rounds run. The outcome is the first verdict's own when that is `tooling-failed` or `unable-to-evaluate`, and `tooling-failed` when a re-check is. Otherwise it is `pass` only when the first verdict listed no blocked charter, every key it blocked on ended `fixed` or `accepted`, and every re-check that ran answered `pass`; every other end is `fails`. Each key ends `open`, `fixed` or `accepted`, with its typed reason, in `usage-loop-findings:`.

```bash
USAGE_OUTCOME="[pass, fails, tooling-failed or unable-to-evaluate]"
USAGE_ROUNDS="[fix rounds run]"
USAGE_FIXED="[keys ended fixed]"
USAGE_ACCEPTED_N="[keys ended accepted]"
USAGE_OPEN="[keys ended open]"
USAGE_UNMAPPED="[unmapped findings]"
USAGE_REVIEW="[the last round's review path]"
USAGE_BRANCH="[the run branch]"
USAGE_FIX_COMMITS="[number of fix commits merged]"
USAGE_FINDINGS=$(cat <<'USAGE_FINDINGS_EOF'
[{"<key>": {"status": "open|fixed|accepted", "reason": "<sanitized>"}}, or {}]
USAGE_FINDINGS_EOF
)
USAGE_REASON=$(cat <<'USAGE_REASON_EOF'
[one sanitized line]
USAGE_REASON_EOF
)
USAGE_REASON=$(printf '%s' "$USAGE_REASON" | tr -d '\000-\037' | cut -c1-300)
printf 'usage-loop: outcome=%s rounds=%s fixed=%s accepted=%s open=%s unmapped=%s review=%s\n' "$USAGE_OUTCOME" "$USAGE_ROUNDS" "$USAGE_FIXED" "$USAGE_ACCEPTED_N" "$USAGE_OPEN" "$USAGE_UNMAPPED" "$USAGE_REVIEW"
printf 'usage-loop-findings: %s\n' "$USAGE_FINDINGS"
[ "$USAGE_OUTCOME" = "pass" ] || printf 'usage-loop-reason: %s\n' "$USAGE_REASON"
[ "$USAGE_FIX_COMMITS" = "0" ] || printf 'usage-validation-stale: %s fix commit(s) landed on %s after Creates Verification, the Phase Visual Gate and Finalize had judged it; none was re-run\n' "$USAGE_FIX_COMMITS" "$USAGE_BRANCH"
```

The calling step copies a `usage-validation-stale:` line into the handoff deviations and the report.
