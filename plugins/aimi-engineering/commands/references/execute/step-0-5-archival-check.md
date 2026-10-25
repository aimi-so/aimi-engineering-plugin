# Execute: Step 0.5: Archival Check

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 0.5: Archival Check

Before starting a new session, check whether any completed task files should be archived to prevent accidental re-execution of finished work.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI list-archivable
```

This returns a JSON array of file paths, e.g.:
```json
["/home/user/project/.aimi/tasks/2026-03-15-auth-feature-tasks.json"]
```

**If the array is empty (`[]`):** Proceed silently to Step 1.

**If archivable tasks exist:** Display the list and ask the user whether to archive them:

```
Found [N] completed task file(s) that can be archived:

  - [filename1]
  - [filename2]

Archive these completed tasks before starting? (yes/no)
```

- **If user confirms (yes):** For each archivable file path, run:
  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI archive-task [file_path]
  ```
  After all files are archived, reset state files:
  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI clear-state
  ```
  Report:
  ```
  Archived [N] task file(s). State cleared.
  ```
  Proceed to Step 1.

- **If user declines (no):** Proceed to Step 1 without archiving.
