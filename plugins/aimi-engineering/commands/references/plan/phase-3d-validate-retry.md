# Plan: Phase 3d: Pass 2 Story Expansion, schema validation, retry and failure budget

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Schema Validation and Retry

After each sub-agent writes its staging file, validate the JSON:

1. Read `<RUN_DIR>/<idx>-<slug>.json`.
2. Verify it is valid JSON (well-formed) and contains the required fields: `title`, `description`, `acceptanceCriteria` (non-empty array), `status` (`"pending"`), `dependsOn` (array), `verification` (object with `strategy` and `status`).
3. **If validation passes**: mark this expansion as successful.
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

After all expansions complete (in parallel):
- **All succeeded**: proceed to Phase 3e.
- **Some permanently failed**: surface to user via AskUserQuestion:
  ```
  Pass 2 expansion failed for N story(ies):
  <list of failed idx + title>
  Options:
    Skip failed — proceed to story-merge without them
    Retry with hint — provide additional context for failed stories, then re-expand
    Abort — stop plan generation
  ```
  When `INTERACTIVE_MODE=agent`, auto-select **Skip failed** and emit one log line:
  ```
  [plan] Pass 2: N expansion(s) permanently failed (agent-mode: skipping)
  ```
