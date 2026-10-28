# Execute: Split File Waves

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

A project-split plan can order its files: `metadata.splitGroup.after` names the sibling files whose repositories a file's stories depend on, and `split-detect` returns it as `after[]` on every member (empty unless the mode is `project-split`). This entry turns that order into **waves**: every Task of wave N returns before any Task of wave N+1 starts, and the members with no active predecessor share the first turn. It serves both spawn sites, **Parallel Execution for Split Files** (flat) and **Spawn Split Sub-Orchestrators** (phase mode), by replacing their single turn with one turn per wave. Everything else about the Tasks stays as that site writes it.

## Compute the Waves

Run this once, **before the first spawn**, and print its output. It keeps nothing between runs: a resumed run runs it again and gets the waves of the files that still have work, because a predecessor whose stories are all completed or skipped is no longer an active member. Compute them before the first spawn and not after, since a predecessor that ends with a failed story is still active and would otherwise be judged again. For a flat split leave `WAVE_SCOPE_DIR` empty; for phase mode set it to the literal phase directory (`$AIMI_ROOT/.aimi/tasks/<FEATURE>/<PHASE_DIR>` as Step 1.7 derived it), replacing the empty string in the line below.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
WAVE_SCOPE_DIR=""
if [ -n "$WAVE_SCOPE_DIR" ]; then
  WAVE_DETECT=$($AIMI_CLI split-detect --dir "$WAVE_SCOPE_DIR") || { echo "split-detect failed for $WAVE_SCOPE_DIR" >&2; exit 1; }
else
  WAVE_DETECT=$($AIMI_CLI split-detect) || { echo "split-detect failed" >&2; exit 1; }
fi
# The program is built one balanced line at a time, so every jq variable stays inside single quotes.
WAVE_JQ='def base: split("/") | last;'
WAVE_JQ+=' [.members[] | select(.active)] as $active'
WAVE_JQ+=' | ($active | map(.path | base)) as $names'
WAVE_JQ+=' | ($active | map({file: .path, base: (.path | base), deps: ((.after // []) | map(base) | map(select(. as $d | any($names[]; . == $d))) | unique)})) as $nodes'
WAVE_JQ+=' | {done: [], rest: $nodes, wave: 1, out: []}'
WAVE_JQ+=' | until(.rest | length == 0; . as $s'
WAVE_JQ+=' | ($s.rest | map(select(.deps | all(. as $d | any($s.done[]; . == $d))))) as $ready'
WAVE_JQ+=' | if ($ready | length) == 0'
WAVE_JQ+=' then error("split files cannot be ordered, cycle or self-reference in after among: " + ($s.rest | map(.base) | join(", ")))'
WAVE_JQ+=' else {done: ($s.done + ($ready | map(.base))), rest: ($s.rest - $ready), wave: ($s.wave + 1), out: ($s.out + ($ready | map({wave: $s.wave, file: .file})))}'
WAVE_JQ+=' end)'
WAVE_JQ+=' | .out[]'
printf '%s' "$WAVE_DETECT" | jq -c "$WAVE_JQ"
```

It reads the active members, matches each `after` entry to a member by basename, and treats an entry that names no active member (a finished file, a file outside the group) as satisfied. It prints one `{"wave":N,"file":"<path>"}` line per active member. Keep that printed output: later turns read the waves from it, the same way Pass 1's `SPLIT_PLAN` is read from its printed stdout, and never by running the block again.

A non-zero exit means a file-level cycle or a self-reference in `after` (a hand-edited file, since `story-merge` refuses a cycle at plan time); stderr names the files. Report that message and STOP before any worktree-bound Task is spawned.

## Spawn by Wave

- When every printed line has `wave` 1, spawn one turn exactly as the spawn site writes it. A split where no member has an active predecessor, and the legacy frontend/backend pair (which carries no `after`), land here and behave as before.
- Otherwise, for wave 1, 2, ... in order: emit one foreground Task per record of that wave in a **single tool-call turn**, selecting the `SPLIT_PLAN` records (flat) or the `PHASE_ACTIVE_SPLIT_FILES` entries (phase mode) whose file is a printed `file`. Use the spawn site's Task template unchanged. Wait for every Task of the wave to return before the next turn.
- After each wave, report one line per file of that wave, from the Task results: `[wave N] [file basename]: [completed] completed, [failed] failed, [skipped] skipped`. Then spawn the next wave. Nothing is cancelled.
- After the last wave, continue with Aggregated Completion (Split Mode) for a flat split, or with the collection of results after the Tasks for phase mode, exactly as the spawn site says.

## A Failed Predecessor Does Not Block

A dependent file runs even when a predecessor file ends with failed or skipped stories. The plan declared the order, not a condition on how the predecessor ended, and the stories of the dependent file carry their own `dependsOn` checks inside their own file. The per-wave line above is how that outcome is made visible.

## Limits

- **Ordering only.** Waves decide when a Task starts. They merge nothing between repositories.
- **No cross-repository merge between waves.** Each dependent branches from its own base, so a predecessor's unmerged code is not visible to it. A dependent file that needs the predecessor's code must wait for a merge the person performs.
- **The SIDE axis is out of scope.** A frontend/backend split inside one repository carries no `after`, and it stays a single turn.
