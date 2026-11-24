# Execute: Open Audit Findings

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Open Audit Findings

The plan's cross-story audit can leave findings open (`metadata.auditOpen`). Show them before the run changes anything, once per top-level run, and let the operator decide. Nothing before this point changes state beyond `init-session`: it runs before Orphaned Story Recovery, the phase claim, and any branch, container or worktree.

The tasks file is the `tasks` path `init-session` printed on the single-file path, or the `split-detect` anchor in a flat split (the plan writes the same value into every split file). Read the list only through `audit-open`, never with `jq`:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI audit-open --tasks-file "[tasks path, or the split-detect anchor]"
echo "INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)"
```

A non-zero exit from `audit-open` is reported verbatim and STOPS the run: an unreadable list is never read as nothing open.

When `count` is 0, print nothing, ask nothing and continue. Otherwise print each finding with its `message` and the staged stories it names (`stories[]`, staged idx strings: `NN`, or `_audit` for the cross-story audit itself).

- **`INTERACTIVE_MODE=picker`:** ask once with **AskUserQuestion**: "This plan carries N open audit finding(s), listed above. Run anyway?" with two options, **Run anyway** and **Stop**. **Stop** ends the run here: no Orphaned Story Recovery, no phase claim, no branch, container or worktree, no story status change. Report the stop in the person's language and STOP. **Run anyway** continues the run unchanged.
- **Any other `INTERACTIVE_MODE` (agent mode):** after the list print one line, `Continuing with N open audit finding(s).`, ask nothing and continue.
