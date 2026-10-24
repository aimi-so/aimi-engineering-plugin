# Plan: Phase 3d: Pass 2 Story Expansion, schema validation, retry and failure budget

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Schema Validation and Retry

After each sub-agent writes its staging file, validate the JSON:

1. Read `<RUN_DIR>/<idx>-<slug>.json`.
2. Verify it is valid JSON (well-formed) and contains the required fields: `title`, `description`, `acceptanceCriteria` (non-empty array), `status` (`"pending"`), `dependsOn` (array), `verification` (object with `strategy` and `status`).
2b. **Run the staging check** on the file just validated. `validate-staging` applies the verify rule `story-merge` refuses on: a multi-line `implementation.verify` must be able to fail on any line, so it either starts with `set -e` or chains every later line with `&&`. A verify that does neither can swallow a failing line, and only the last line's exit status would count. With `--outline` it also reports a story that consumes a name another outline entry produces (a `produces`/`consumes` contract, `ext:` consumes excepted) but whose `dependsOn` lacks that producer's `outline:NN` token (specFlow:ImportantQ11). Exit 1 means a non-empty report, keyed by staged idx; exit 0 prints `{}`.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
STAGING_REPORT=$($AIMI_CLI validate-staging --staging-dir "$RUN_DIR" --outline "$RUN_DIR/outline.json") || true
printf '%s' "$STAGING_REPORT" | jq -r --arg idx "<idx>" '.[$idx] // [] | .[]'
```

   A line printed for the idx just expanded is a validation failure. It feeds the retry loop in step 4 with that finding as the error string, sanitized as below. Findings reported for any other idx belong to that expansion and are ignored here. A failed run of the verb itself (no report, non-zero exit with nothing on stdout) is a failure of the check and not a pass: surface it rather than treating the story as clean.
3. **If validation passes** (steps 2 and 2b both clean): mark this expansion as successful.
4. **If validation fails**: retry up to **2 times** with an enriched prompt appending the sanitized validator error string:

**Sanitize the error string before retry injection:**
- Strip any `$(` sequences (removes command-substitution attempts).
- Remove backtick characters.
- Replace newlines with spaces.
- Truncate to 500 characters.

Include the sanitized error in the retry prompt as:
```
Previous attempt failed validation. Error: <sanitized error string>
Please fix the JSON and write the file again at outputPath.
```

Before every re-spawn, delete the stale staging file with Bash `rm -f "$RUN_DIR/<idx>-<slug>.json"`: the guard hook denies Edit and Write over an existing staging `NN-*.json`, so the expander's rewrite would otherwise be refused. Never Edit or Write a staging file by hand. An expander that dies after the delete leaves no file, which fails validation and counts as a failed expansion under the Failure Budget.

After 2 failed retries (3 total attempts), mark this expansion as **permanently failed**. Record the story title and outline index.

### Failure Budget

After every wave has completed (see Wave Dispatch and Producer Slice Block Preparation in the prep-blocks file):
- **All succeeded**: proceed to Phase 3e.
- A story whose `implementation.verify` can swallow a failing line, or that lacks a producer's `outline:NN` in `dependsOn`, fails validation in step 2b and is retried like any other. When the retry prompt names it, state the rule as: a multi-line verify must not swallow a failing line, so start it with `set -e` or chain every line with `&&`. `story-merge` refuses the same story again at merge (see Phase 3e), so an expansion that exhausts its retries on this rule counts as permanently failed.
- **Some permanently failed**: surface to user via AskUserQuestion:
  ```
  Pass 2 expansion failed for N story(ies):
  <list of failed idx + title>
    held back, never spawned: <idx + title> (producer <idx> failed)   [one line per held-back entry, beneath its producer]
  Options:
    Skip failed — proceed to story-merge without them
    Retry with hint — provide additional context for failed stories, then re-expand
    Abort — stop plan generation
    Edit outline — change the outline and re-expand only what the edit affects   [interactive mode only]
  ```
  **Edit outline** (specFlow:CriticalQ3) follows the section Edit Outline After Expansion in `commands/references/plan/phase-3c-outline-gate.md`; Read it before acting on the choice.

  When `INTERACTIVE_MODE=agent`, auto-select **Skip failed**, which skips the held-back closure too instead of expanding it blind, and emit one log line:
  ```
  [plan] Pass 2: N expansion(s) permanently failed, M held back (agent-mode: skipping)
  ```
  N counts the permanently failed expansions and M the held-back entries, `0` when none.

### Held-Back Dependents of a Failed Producer

When an expansion is marked permanently failed, hold back its **dependent closure**: every entry reachable from it along the `edges` Wave Dispatch kept (the entries that consume what it produces, then the entries consuming theirs). Those entries are never spawned, since their expander would be told to cite a story that does not exist (specFlow:CriticalQ5). Record each as failed with the cause `held back: producer <idx> failed`, naming the nearest failed producer, and list it beneath that producer in the Failure Budget prompt above. A held-back entry is listed only as the line beneath its producer; it adds no failure of its own to the count in `N story(ies)`. An entry is not held back by a failed entry it does not consume from, even in the same wave.

- **Skip failed** drops the closure along with the failed producer: no staging file exists for any of them, and Phase 3e proceeds without them.
- **Retry with hint** re-expands the failed producers first, through Schema Validation and Retry again, and only then dispatches the closure, in wave order, with the recovered producers' slices. A producer that fails again keeps its closure held back.
