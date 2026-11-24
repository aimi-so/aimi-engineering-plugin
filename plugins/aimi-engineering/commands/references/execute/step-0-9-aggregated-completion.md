# Execute: Step 0.9: Aggregated Completion

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.

### Aggregated Completion (Split Mode)

When all parallel Tasks complete, skip the normal Step 5 and report aggregated results. The report contains exactly one block per plan record — a member the verb never reported as active contributes no block and no "0 stories completed" line anywhere.

#### Pass 3 — Aggregated Completion Report

Each commit count is scoped with `git -C` against that repo's own default branch: a single global `git log $DEFAULT_BRANCH..` is wrong in a multi-repo layout, where `$AIMI_ROOT` is not a repo and no global `$DEFAULT_BRANCH` was ever detected.

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
SPLIT_TOTAL_COMMITS=0
while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_FILE=$(printf '%s' "$record" | jq -r '.file')
  SPLIT_PROJECT=$(printf '%s' "$record" | jq -r '.project')
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  SPLIT_DEFAULT=$(printf '%s' "$record" | jq -r '.default')
  SPLIT_COMMITS=$(git -C "$SPLIT_ROOT" log --oneline "$SPLIT_DEFAULT".."$SPLIT_BRANCH" 2>/dev/null | grep -c .)
  SPLIT_TOTAL_COMMITS=$((SPLIT_TOTAL_COMMITS + SPLIT_COMMITS))
  printf '%s\t%s\t%s\t%s\t%s\n' "$SPLIT_FILE" "$SPLIT_PROJECT" "$SPLIT_BRANCH" "$SPLIT_DEFAULT" "$SPLIT_COMMITS"
done <<< "$SPLIT_PLAN"
printf 'TOTAL_COMMITS\t%s\n' "$SPLIT_TOTAL_COMMITS"
```

Read each record's own usage-validation verdict from its own tasks file before rendering. Only `failing` holds: when any record is failing, the report prints no PR line for any record, only the one warning below, and Pass 4 keeps that record's worktree.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
# usage-rollup:begin
USAGE_FAILING_N=0
while IFS= read -r record; do
  [ -n "$record" ] || continue
  USAGE_FILE=$(printf '%s' "$record" | jq -r '.file')
  USAGE_STATUS=$("$AIMI_CLI" usage-validation-get --tasks-file "$USAGE_FILE" 2>/dev/null | jq -r '.record.status // "none"' 2>/dev/null)
  [ -n "$USAGE_STATUS" ] || USAGE_STATUS=unknown
  printf 'usage-validation: %s\t%s\n' "$USAGE_FILE" "$USAGE_STATUS"
  if [ "$USAGE_STATUS" = failing ]; then
    USAGE_FAILING_N=$((USAGE_FAILING_N + 1))
    printf 'usage-rollup-failing: %s\t/aimi:execute %s\n' "$USAGE_FILE" "$USAGE_FILE"
  fi
done <<< "$SPLIT_PLAN"
if [ "$USAGE_FAILING_N" -gt 0 ]; then echo "usage-rollup-gate: hold"; else echo "usage-rollup-gate: go"; fi
# usage-rollup:end
```

Show each block's `usage-validation:` status under its `Commits:` line. When the gate prints `hold`, replace the PR line of every record in Next Steps with one warning naming each `usage-rollup-failing:` file with its own re-run, `/aimi:execute <that file>`: usage validation is failing there, so no PR is offered for any record. The warning never names a re-run of the parent plan, because `split-detect` does not treat a child whose only open state is a failing usage validation as active, while the Re-validate branch of Step 3 picks up `/aimi:execute <that file>`. With `usage-rollup-gate: go` the report is unchanged.

Render one block per line of that output, filling **Stories completed** from that member's own Task result:

```
## Execution Complete (Split Mode)

For each plan record, one block:

[file]
  Project: [project]
  Branch: [branch]
  Stories completed: [count from that file's Task result]
  Commits: [that line's commit count]

Total stories: [sum of every record's completed count]
Total commits: [TOTAL_COMMITS from the loop above]

### Next Steps

- Review [branch] commits: git -C [root] log --oneline [default]..[branch]   (one line per plan record)
- Run /aimi:review for code review
- Open a PR for [branch] from [root]: /aimi:open-pr --branch [branch]   (one line per plan record)
```

The PR line is per plan record and names that record's own `[root]` because `/aimi:open-pr` resolves its repository from the current directory — it has no `--project` flag — so in a multi-repo split a line naming only the branch would not be actionable. It uses the `--branch` argument form for the same reason the container report below does: Pass 4 removes every split worktree, leaving each branch checked out nowhere. Naming the command at all is the obligation `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` § Always Name /aimi:open-pr states; it is not restated here.

Both `Total` lines are sums across **all** plan records, not two named Frontend/Backend slots. For a legacy pair every root is `$AIMI_ROOT` and every default is that repo's own default branch, so the two blocks render the same lines the paired-mode report produced before.

#### Pass 4 — Clean Up Split Worktrees

Clean up after reporting — once per plan record's own branch, in its own repo, never a fixed pair of calls. Every branch is a deliverable the report above just pointed the user at for review and PR creation — not a throwaway per-story worktree — so `--keep-branch` is required here to avoid deleting the very branches the user was told to open PRs against:

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  USAGE_STATUS=$("$AIMI_CLI" usage-validation-get --tasks-file "$(printf '%s' "$record" | jq -r '.file')" 2>/dev/null | jq -r '.record.status // "none"' 2>/dev/null)
  if [ "$USAGE_STATUS" = failing ]; then
    echo "kept: $SPLIT_BRANCH worktree — usage validation is failing there"
    continue
  fi
  cd "$SPLIT_ROOT"
  $WORKTREE_MGR remove "$SPLIT_BRANCH" --keep-branch
done <<< "$SPLIT_PLAN"
```

STOP execution (aggregated report replaces normal Step 5).
