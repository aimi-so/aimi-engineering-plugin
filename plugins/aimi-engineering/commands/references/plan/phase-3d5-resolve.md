# Plan: Phase 3d.5: Resolve audit findings one by one

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. Wording of everything shown to the operator follows `commands/references/user-communication.md`.

Reached from the Unresolved Gate's **Resolve** option, interactive mode only. The working-memory `unresolved[]` list (`{storyIdx, message}`, messages sanitized as the gate describes) is complete and `audit-result.json` is not the Failure Fallback stub.

### Per-finding loop

For each `unresolved[]` entry, compose one proposed acceptance criterion from its sanitized `message`: one declarative sentence stating the observable condition the finding says is missing, with no shell syntax, no code fence and no more than 300 characters. Present the entries up to **four findings per AskUserQuestion call**, in list order. Each finding is one question showing `[storyIdx]: [sanitized message]` and the proposed criterion, with exactly three options:

```
Confirm — add the proposed criterion
Edit — I will type the criterion
Leave open — record the finding as open
```

For **Edit**, ask one free-text follow-up and use the answer as the criterion after sanitizing it: newlines/CRs to spaces, strip `$(`, remove backticks, truncate to 1000 characters. An empty answer means Leave open. A finding whose `storyIdx` is `_audit` names no staged story, so it is shown without a proposal and recorded as left open.

Build one resolutions entry per finding: `{"message": <sanitized message>, "stories": [<storyIdx>], "criterion": <string, or null when left open>}`.

### Write the resolutions file and run the verb

Use the `Write` tool, never a heredoc, so operator text is not shell-interpolated, to write `<RUN_DIR>/audit-resolutions.json`:

```json
{"resolutions": [{"message": "...", "stories": ["02"], "criterion": "..."}]}
```

Then run the verb once. It takes no `--result`:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI apply-audit-patches --staging-dir "$RUN_DIR" --resolve "$RUN_DIR/audit-resolutions.json"
```

It appends each confirmed criterion to `acceptanceCriteria` of every staged story the entry names and prints `{resolvedStories, openFindings, duplicates, refused, oqDecisions}`. A non-zero exit stops the plan here with `RUN_DIR` preserved.

### After the verb

- Append every returned `oqDecisions[]` entry to the working-memory `oqDecisions[]`.
- Set the working-memory `auditOpen` from `openFindings` **alone**: each element reduced to `{message, stories}`. Drop `reason`, and never read `refused` for it (a refused entry is already in `openFindings`). `stories` holds staged idx strings (`NN` or `_audit`), never US-NNN ids. When `openFindings` is empty, leave `auditOpen` unset.
- Carry `auditOpen` to Phase 4 beside `unresolved[]`, and the count of `resolved` decisions to Step 5.
- Relay one line for each `refused` entry: `[plan] Phase 3d.5: criterion refused — story <stories joined by comma> (<trigger>)`.

Proceed to Phase 3e.
