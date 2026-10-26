# Execute: Finalize Step

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Finalize Step

Runs once, immediately after Post-Loop Cleanup above and before **Phase Completion** below — so the closing commit is already on the branch by the time **Offer a Pull Request** and Step 5 read it. It exists for the one commit no story can structurally make: the version bump, the CHANGELOG entry, the regenerated index. Their content *is* this run's own diff, so they cannot be written until every story has merged, and a story that wrote them anyway would be racing every sibling story for the same file — which is exactly the collision `validate-tasks` warns about when a story's `implementation.files` claims a path this key declares.

**Only the top-level orchestrator runs it.** A Phase-Mode Paired Split sub-orchestrator reaches Post-Loop Cleanup too and must skip this section outright: its parent runs the step once, from **Continue to Phase Completion**, after every member branch has merged into `$PHASE_BRANCH`. The discriminator is the one this file already uses for every claim-releasing call — `PHASE_MODE=true` with `$PHASE_ID` unset is a sub-orchestrator, and nothing else is. Two orchestrators each writing a closing commit would put two of them on one branch, which is the one shape a later reverter cannot undo by naming a single sha.

The step is **declared, never inferred**: it runs only when this run's own tasks file carries `metadata.finalize` — the `{intent, files[], commitSubject}` object `${CLAUDE_PLUGIN_ROOT}/commands/plan.md`'s metadata contract writes and explicitly leaves to its consumer to run. This is that consumer. Read the key with the same `metadata` verb idiom Step 5 already uses for `verification-report`: `--tasks-file "$PHASE_TASKS_PATH"` in phase mode, the flag omitted in flat mode, where `init-session` has long since pointed session state at the file this run executed.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "${PHASE_MODE:-false}" = "true" ]; then
  FINALIZE_JSON=$($AIMI_CLI metadata --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null | jq -c '.finalize // empty')
else
  FINALIZE_JSON=$($AIMI_CLI metadata 2>/dev/null | jq -c '.finalize // empty')
fi
FINALIZE_STATUS=skipped
FINALIZE_COMMIT=""
FINALIZE_REASON="metadata.finalize not declared"
FINALIZE_INTENT=$(printf '%s' "$FINALIZE_JSON" | jq -r '.intent // empty' 2>/dev/null)
FINALIZE_SUBJECT=$(printf '%s' "$FINALIZE_JSON" | jq -r '.commitSubject // empty' 2>/dev/null)
FINALIZE_FILES=$(printf '%s' "$FINALIZE_JSON" | jq -r '.files[]?' 2>/dev/null)
printf 'finalize: status=%s (%s)\n' "$FINALIZE_STATUS" "$FINALIZE_REASON"
```

`// empty` is what makes an absent key silent, the same reason Step 2's `baseRef` read spells it that way: `.finalize` answers `null` for a key that is not there, and the word `null` in `$FINALIZE_JSON` would read downstream as a declared step.

**An absent key takes zero of the path below.** When `$FINALIZE_JSON` is empty the section is over at the line above: no worktree is created, no executor is spawned, nothing is committed, and the run continues into Phase Completion byte-for-byte as it did before this section existed. Every tasks file written before the key entered the schema takes this branch, and so does every plan that simply has no closing step. The only trace is the streamed status line, which is a report and not a change to the branch.

**More than one project group is `skipped` too, and on purpose.** When this run scheduled stories under more than one `group_key` (the multi-repo layout Multi-Repo Handling describes), record `FINALIZE_STATUS=skipped` with `FINALIZE_REASON` naming the count, and run nothing. `metadata.finalize` names **one** repository's closing step — `plan.md`'s patch rule gives each PROJECT-axis file its own — so a single key cannot be spread across N repositories, and inventing N closing commits from one declaration would put a version bump written for one repository onto every other repository's branch. Reporting the skip is the honest answer; guessing is not.

**One worktree, cut from this group's own tip, exactly as Step 4 cuts a story's.** Same `cd` to that group's execution root, same `create`, and the same two sentinels read from its output — this section invents no second mechanism for something Step 4 already does:

```
FINALIZE_WORKTREE = EXEC_BRANCH[group_key] + "-finalize"

cd EXEC_ROOT[group_key]
create_output = $WORKTREE_MGR create [FINALIZE_WORKTREE] --from [EXEC_BRANCH[group_key]]

# Same two unprefixed lines Step 4 reads, same last-occurrence rule.
WORKTREE_PATH = value of the last WORKTREE_PATH= line in create_output
WORKTREE_BASE = value of the last WORKTREE_BASE= line in create_output

if WORKTREE_PATH is absent or WORKTREE_BASE is absent:
    FINALIZE_STATUS = failed
    FINALIZE_REASON = "worktree create printed no WORKTREE_PATH/WORKTREE_BASE sentinel"
    skip the rest of this section and continue to Phase Completion

# The commits this closing step is written ABOUT: everything the run merged.
FINALIZE_COMMITS = git -C [EXEC_ROOT[group_key]] log --oneline [CONTAINER_BASE]..[EXEC_BRANCH[group_key]]
```

The `-finalize` suffix is chosen so the name does **not** match the `"[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*"` pattern Post-Loop Cleanup sweeps — nor the un-prefixed legacy pattern in the pass beside it, since `[EXEC_BRANCH[group_key]]-finalize` fails the `-US-*` tail of both globs alike, which is what carries this invariant across the rename unchanged in substance. Post-Loop Cleanup has already run by the time this section starts, but the two must not overlap even on a re-entry: this section removes its own worktree below, and a sweep that also claimed it would be racing for the same tree.

**One executor, not a fixed command.** The step needs judgment — deciding the increment, writing a CHANGELOG entry that says what *this* set of commits did — which is why it gets the merged-commit list alongside the key's own intent rather than a hardcoded recipe:

```
Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Finalize [EXEC_BRANCH[group_key]]",
    prompt: [
        - WORKTREE_PATH = the path read from create_output above
        - INTENT = metadata.finalize.intent          ← what this closing step is for
        - FILES = metadata.finalize.files[]          ← the only paths it may write
        - COMMITS = FINALIZE_COMMITS                 ← what this run actually did
        - COMMIT_SUBJECT = metadata.finalize.commitSubject
        - Make exactly ONE commit, whose subject line is COMMIT_SUBJECT verbatim
        - Stage only paths listed in FILES; never `git add -A` and never `.`
        - Never amend, rebase, revert or otherwise rewrite a story's commit
        - Report the short sha of the commit made, or that none was made
    ]
)
```

**Merge it the way a story merges, then remove it.** Same primitive, same target, same CWD rule — `merge-all` issues a bare `git checkout` against whatever repository its CWD belongs to, so this runs from the group's execution root like every other merge in this file:

```
cd EXEC_ROOT[group_key]
merge_result = $WORKTREE_MGR merge-all [FINALIZE_WORKTREE] --into [EXEC_BRANCH[group_key]]

if merge_result is non-zero:
    FINALIZE_STATUS = failed
    FINALIZE_REASON = "merge of [FINALIZE_WORKTREE] into [EXEC_BRANCH[group_key]] conflicted"
    Report the conflict output verbatim, keep the worktree and its branch so the
    closing commit is not stranded, and continue to Phase Completion
else:
    FINALIZE_COMMIT = git -C [EXEC_ROOT[group_key]] rev-parse --short [EXEC_BRANCH[group_key]]
    FINALIZE_STATUS = ran
    $WORKTREE_MGR remove [FINALIZE_WORKTREE]
```

**The commit is separate and trivially reversible.** It is the branch's last commit, its subject is `metadata.finalize.commitSubject` and nothing else, and `FINALIZE_COMMIT` carries its sha into the report so a reader has the one argument `git revert` needs. No story commit is touched, amended, reordered or rewritten by any path in this section — the executor above is told so explicitly, and this section never calls anything that could.

**Nothing here can fail the run, and that is a rule rather than a default.** `FINALIZE_STATUS` takes exactly one of `ran`, `skipped` or `failed`; `failed` is reported and never propagated to `/aimi:execute`'s own exit status, and no branch of this section aborts the command. By the time it runs, every story has already been executed, verified and merged: turning a whole completed run red over a version bump would throw away work that is finished and correct, and would leave the operator with a branch that is fine and a command that says otherwise. A `failed` finalize is a line in the report and a worktree left in place to retry from.

Emit the status line on **every** path through this section, including the two that do nothing:

```
finalize: status=[FINALIZE_STATUS] ([FINALIZE_REASON or FINALIZE_COMMIT])
```

Step 5's `## Finalize` report section renders these same variables — see **If all stories complete** below.

