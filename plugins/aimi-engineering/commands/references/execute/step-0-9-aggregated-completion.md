# Execute: Step 0.9: Aggregated Completion

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

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
while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  cd "$SPLIT_ROOT"
  $WORKTREE_MGR remove "$SPLIT_BRANCH" --keep-branch
done <<< "$SPLIT_PLAN"
```

STOP execution (aggregated report replaces normal Step 5).
