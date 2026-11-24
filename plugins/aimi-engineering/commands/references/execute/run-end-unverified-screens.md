# Execute: Unverified Screen Stop

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.

## Unverified Screen Stop

A completed screen story that neither a visual check nor usage validation ever looked at must not reach a pull request looking like a clean one. This step asks the CLI which ones there are and, when any, lets the operator stop before the run publishes or closes. It runs **once per run**, at one of three call sites, each of which points here and does not restate it:

- **Phase mode** (`PHASE_MODE=true`): at the top of Offer a Pull Request, before the forge-account question and the publish question. Step 5 does not ask it again.
- **Flat container run** (`PHASE_MODE=false`, `CONTAINER_MODE=true`): in Step 5, after the usage-validation gate prints `go` and before any container step.
- **Flat inline run** (`PHASE_MODE=false`, `CONTAINER_MODE=false`): in Step 5, after the gate prints `go` and before the Next Steps.

Where Step 5's gate printed `usage-validation-gate: hold`, this step does not run and adds no second question: the held Next Steps already name `/aimi:open-pr`.

**`UNVERIFIED_STOP` holds `stop` or `continue` after the question.** It is `continue` when this step is skipped, when the count is 0, when the answer is unreadable and in agent mode; it is `stop` only when the operator answered Stop, or gave no answer. The flat container push, the phase publish question and the inline close each read it.

Substitute the four values below from the run's own state (each Bash call is an isolated shell, so nothing survives from an earlier block), then run the block:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_MODE="[true or false]"
FEATURE="[the feature slug, phase mode only]"
PHASE_ID="[the phase id, phase mode only]"
TASKS_PATH="[TASKS_PATH, flat run only]"
# unverified-screens:begin
UNV_STAGE=""
UNV_JSON=""
UNV_COUNT=0
if [ "$PHASE_MODE" = true ]; then
  UNV_JSON=$("$AIMI_CLI" unverified-screens --feature "$FEATURE" --phase "$PHASE_ID" 2>/dev/null) || UNV_STAGE="unverified-screens exited non-zero"
else
  UNV_JSON=$("$AIMI_CLI" unverified-screens --tasks-file "$TASKS_PATH" 2>/dev/null) || UNV_STAGE="unverified-screens exited non-zero"
fi
[ -n "$UNV_STAGE" ] || [ -n "$UNV_JSON" ] || UNV_STAGE="empty answer"
[ -n "$UNV_STAGE" ] || UNV_COUNT=$(printf '%s' "$UNV_JSON" | jq -r '.count' 2>/dev/null) || UNV_STAGE="answer is not JSON"
if [ -z "$UNV_STAGE" ]; then
  case "$UNV_COUNT" in ''|*[!0-9]*) UNV_STAGE="count is not a number" ;; esac
fi
if [ -n "$UNV_STAGE" ]; then
  printf 'unverified-screens: unknown — %s\n' "$UNV_STAGE"
  echo "unverified-screens-stop: report"
elif [ "$UNV_COUNT" -eq 0 ]; then
  echo "unverified-screens: 0"
  echo "unverified-screens-stop: none"
else
  printf 'unverified-screens: %s\n' "$UNV_COUNT"
  printf '%s' "$UNV_JSON" | jq -r '.stories[]? | "unverified-screen: \(.id) | \(.title) | cause=\(.cause)\(if .visualStatus then " | visual=" + .visualStatus else "" end)\(if .skipReason then " | skipReason=" + .skipReason else "" end) | usage=\(.usageSkip.status // "none")\(if .usageSkip.kind then " (" + .usageSkip.kind + ")" else "" end)"'
  UNV_MODE=$("$AIMI_CLI" detect-interactivity 2>/dev/null) || UNV_MODE=agent
  if [ "$UNV_MODE" = picker ]; then
    echo "unverified-screens-stop: ask"
  else
    echo "unverified-screens-stop: report"
  fi
fi
# unverified-screens:end
```

Read the last line:

- **`unverified-screens-stop: none`**: count 0. Ask nothing, set `UNVERIFIED_STOP=continue`, and the run behaves exactly as it did before this step existed.
- **`unverified-screens-stop: ask`**: picker mode with a count above 0. Raise the question below.
- **`unverified-screens-stop: report`**: agent mode with a count above 0, or an unreadable answer. Raise no question, set `UNVERIFIED_STOP=continue`, publish as the run already would, and print the section under Agent Mode below.

## The Question

Use **AskUserQuestion** exactly once for the whole run, with exactly two options. List each story from the `unverified-screen:` lines by id and title with its `cause` (and `visualStatus` and `skipReason` when printed) and its usage-validation skip status and kind. Stop is first, because it is what silence means; this is the one place the escape hatch is not last (`commands/references/interactivity.md`'s Option Format). Write the question and its option text in whatever language the person is writing in, never a hardcoded one (`commands/references/user-communication.md`'s Adaptive Language Rule).

```
[N] completed screen stories were never checked against the running product.

- [id] [title] — [cause], [visualStatus/skipReason when set], usage validation [status (kind)]

A — Stop (publish nothing; check these screens, then run /aimi:open-pr yourself)
B — Continue (go on to the publish question)
```

**Option A** sets `UNVERIFIED_STOP=stop`. **Option B** sets `UNVERIFIED_STOP=continue`. Anything that is not an explicit B, meaning a dismissed prompt, an unparseable answer or no answer at all, is Stop: silence is not approval.

## Stop and Continue

**Stop withholds publishing and nothing else.** Stories and phase stay completed, nothing new is written to the tasks file or the roadmap, and no status moves.

- **Phase mode:** set `PHASE_PUBLISH=none`. Neither the forge-account picker nor the publish question is raised; the publish loop's own `none` branch prints its decline line.
- **Flat container run:** skip the three container steps (stop the dev server, push, remove the container) and the push question. Nothing is pushed, the dev server keeps running and the container is left as it is.
- **Flat inline run:** nothing was going to be pushed; use the Next Steps below in place of the ones Step 5 prints.

In all three, the final report lists the stories (the section below) and both skips, and names the command that publishes later: `/aimi:open-pr --branch [PHASE_BRANCH]` in phase mode, `/aimi:open-pr --branch [branchName]` in a container run, bare `/aimi:open-pr` in inline mode.

```
### Next Steps

- Check the listed screens against the running product, or re-run `/aimi:execute` with usage validation enabled
- Review commits: `git log --oneline -[count]`
- Nothing was published. To publish anyway: `/aimi:open-pr --branch [PHASE_BRANCH]` in phase mode, `/aimi:open-pr --branch [branchName]` in container mode, or bare `/aimi:open-pr` in inline mode
```

**Continue** proceeds to the existing publish question unchanged, which keeps its own exactly-once rule.

## Agent Mode

Raise no question and publish as the run already would. The final report gains this section after `## Usage Validation`, from the lines the block printed:

```
## Unverified Screen Stories

screen stories unverified: [N]
- [id] [title]: visual [cause, with visualStatus and skipReason when set]; usage validation [status (kind)]
```

An unreadable answer prints `unverified-screens: unknown — [stage]` in place of the count line and lists no story. The section never prints a pass line, not even for an empty list; with a count of 0 it is omitted.
