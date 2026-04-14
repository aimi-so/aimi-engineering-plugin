# Integration with Workflows

## `/workflows:review`

Instead of always creating a worktree:

```
1. Check current branch
2. If ALREADY on target branch (PR branch or requested branch) -> stay there, no worktree needed
3. If DIFFERENT branch than the review target -> offer worktree:
   "Use worktree for isolated review? (y/n)"
   - yes -> call git-worktree skill
   - no -> proceed with PR diff on current branch
```

## `/workflows:work`

Always offer choice:

```
1. Ask: "How do you want to work?
   1. New branch on current worktree (live work)
   2. Worktree (parallel work)"

2. If choice 1 -> create new branch normally
3. If choice 2 -> call git-worktree skill to create from main
```
