# Plan: Phase 3d: Pass 2 Story Expansion, schema validation, retry and failure budget

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Schema Validation and Retry

After each sub-agent writes its staging file, validate the JSON:

1. Read `<RUN_DIR>/<idx>-<slug>.json`.
2. Verify it is valid JSON (well-formed) and contains the required fields: `title`, `description`, `acceptanceCriteria` (non-empty array), `status` (`"pending"`), `dependsOn` (array), `verification` (object with `strategy` and `status`).
2b. **Run the staging check** on the file just validated. `validate-staging` applies the verify rule `story-merge` refuses on: a multi-line `implementation.verify` must be able to fail on any line, so it either starts with `set -e` or chains every later line with `&&`. A verify that does neither can swallow a failing line, and only the last line's exit status would count. It also reports each `implementation.guardRails` entry that is not a whole top-level segment of the verify (list the whole compound or its call line), and each `implementation.files` entry outside the repository, which belongs in `implementation.outputs`; `story-merge` refuses both again. With `--outline` it also reports a story that consumes a name another outline entry produces (a `produces`/`consumes` contract, `ext:` consumes excepted) but whose `dependsOn` lacks that producer's `outline:NN` token (specFlow:ImportantQ11). Exit 1 means a non-empty report, keyed by staged idx; exit 0 prints `{}`.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
STAGING_REPORT=$($AIMI_CLI validate-staging --staging-dir "$RUN_DIR" --outline "$RUN_DIR/outline.json") || true
printf '%s' "$STAGING_REPORT" | jq -r --arg idx "<idx>" '.[$idx] // [] | .[]'
```

   A line printed for the idx just expanded is a validation failure. It feeds the retry loop in step 4 with that finding as the error string, sanitized as below. Findings reported for any other idx belong to that expansion and are ignored here. A failed run of the verb itself (no report, non-zero exit with nothing on stdout) is a failure of the check and not a pass: surface it rather than treating the story as clean.
3. **If validation passes** (steps 2 and 2b both clean): mark this expansion as successful, then stamp the story file. The stamp is the file `<RUN_DIR>/<idx>-<slug>.json.validated` holding the sha256 hex of the validated story file. Write it only now, with Bash, never before steps 2 and 2b are both clean: a `verification.url` finding from `validate-staging` is a retryable defect, so it must reach the expander while the file is still unstamped. Once the stamp exists the guard hook denies every further Write or Edit of that story file, and the expander can never write the stamp itself. The stamp name never ends in `.json`, so `story-merge` and `apply-audit-patches` do not read it as a story, and `outline-shift` moves or deletes it together with its story file.

```bash
RUN_DIR="<RUN_DIR>"
STORY_FILE="$RUN_DIR/<idx>-<slug>.json"
if command -v shasum >/dev/null 2>&1; then
  STORY_SHA=$(shasum -a 256 "$STORY_FILE" | cut -d' ' -f1)
else
  STORY_SHA=$(sha256sum "$STORY_FILE" | cut -d' ' -f1)
fi
printf '%s\n' "$STORY_SHA" > "${STORY_FILE}.validated"
```
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

A re-spawn is a batch of its own and runs inside the Working Tree Guard (`phase-3d-tree-guard.md`): `snapshot` before it, `check` after it. Before every re-spawn, delete the stale staging file and its stamp together with Bash `rm -f "$RUN_DIR/<idx>-<slug>.json" "$RUN_DIR/<idx>-<slug>.json.validated"`: a story file that carries a stamp is denied to every Write and Edit, so a stamp left behind would refuse the expander's rewrite. An unstamped story file the expander may overwrite itself, which is the normal route for the retry in step 4, but the deletion keeps a re-spawn identical whichever state the file was in. A re-spawn whose shared inputs changed (an outline edit, changed resolved decisions) first rewrites the affected context files, per Rewrite before a re-spawn in `phase-3d-context-files.md`; if a rewrite fails, stop the batch naming the file. Never Edit or Write a staging file by hand, and never write a stamp except in step 3. An expander that dies after the delete leaves no file, which fails validation and counts as a failed expansion under the Failure Budget.

After 2 failed retries (3 total attempts), mark this expansion as **permanently failed**. Record the story title and outline index.

### Failure Budget

After every wave has completed (see Wave Dispatch and Producer Slice Block Preparation in the prep-blocks file):
- **All succeeded**: proceed to Phase 3e.
- A story whose `implementation.verify` can swallow a failing line, or that lacks a producer's `outline:NN` in `dependsOn`, fails validation in step 2b and is retried like any other. When the retry prompt names it, state the rule as: a multi-line verify must not swallow a failing line, so start it with `set -e` or chain every line with `&&`. A guard rail must be a whole top-level verify segment and a file outside the repository belongs in `implementation.outputs`; `story-merge` refuses both again at merge. `story-merge` refuses the same story again at merge (see Phase 3e), so an expansion that exhausts its retries on this rule counts as permanently failed.
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
