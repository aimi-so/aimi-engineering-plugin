# Execute: Step 0.7: Visual Follow Prompt

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 0.7: Visual Follow Prompt

Which stories carry a visual verification strategy, and whether any `verification` field is malformed, are both answered by one verb from one read of the tasks file — `$AIMI_CLI status` still omits `verification` (see the note above `story_row` in `tasks.py`, an intentional scope cut), and this is the verb that answers what `status` leaves out:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
TASKS_PATH="$($AIMI_CLI init-session 2>/dev/null | jq -r '.tasks // empty')"
VERIF_REPORT=$($AIMI_CLI verification-report --tasks-file "$TASKS_PATH" 2>/dev/null)
VISUAL_STORIES=$(printf '%s' "$VERIF_REPORT" | jq '.visual | length' 2>/dev/null)
REPAIRABLE_COUNT=$(printf '%s' "$VERIF_REPORT" | jq '.malformed.repairable | length' 2>/dev/null)
UNREPAIRABLE_COUNT=$(printf '%s' "$VERIF_REPORT" | jq '.malformed.unrepairable | length' 2>/dev/null)
```

If `REPAIRABLE_COUNT` > 0 or `UNREPAIRABLE_COUNT` > 0, collect the affected story IDs and abort. The two counts are kept apart deliberately: `normalize-verification` (`_verification_migrated` in `tasks.py`) rewrites a bare-string `verification` — the empty string included — and returns every other non-object shape untouched, so a number-, array- or boolean-typed `verification` is malformed but not something that verb can fix. Naming it as the fix for a shape it declines to touch would send the user into a loop with no exit; this is a deliberate divergence from the single undifferentiated `MALFORMED_VERIF` scan this replaced, not a preserved behavior — the UNION of the two counts still matches what that scan counted.

```bash
REPAIRABLE_IDS=$(printf '%s' "$VERIF_REPORT" | jq -r '.malformed.repairable | join(", ")' 2>/dev/null)
UNREPAIRABLE_IDS=$(printf '%s' "$VERIF_REPORT" | jq -r '.malformed.unrepairable | join(", ")' 2>/dev/null)
```

Report the error and STOP. The header is always present; the two paragraphs below it are each included only when their own count is non-zero, so a file with only one shape of malformed `verification` gets a one-paragraph report, and a file with both gets both:
```
Malformed verification fields detected — aborting.
```

When `REPAIRABLE_COUNT` > 0, add:
```

Affected stories (bare string — repairable): [REPAIRABLE_IDS]

Run:
  $AIMI_CLI normalize-verification <tasks-path>
to fix these, then re-run /aimi:execute.
```

When `UNREPAIRABLE_COUNT` > 0, add:
```

Affected stories (verification must be an object {strategy, status, url, expect} — not automatically repairable): [UNREPAIRABLE_IDS]

Rewrite each of these stories' verification field into the object form by hand, then re-run /aimi:execute.
```
STOP execution.

- **If `VISUAL_STORIES` is 0 or empty:** Set `VISUAL_FOLLOW=false`. Proceed to Step 1.

- **If `VISUAL_STORIES` > 0:** Prompt the user:

```
Frontend stories detected. Follow implementation visually in a headed browser? (yes/no)
```

  - **If user says yes:** Set `VISUAL_FOLLOW=true`.
  - **If user says no:** Set `VISUAL_FOLLOW=false`.

See the Visual Follow Lifecycle section above for the full lifecycle contract.

Proceed to Step 1.
