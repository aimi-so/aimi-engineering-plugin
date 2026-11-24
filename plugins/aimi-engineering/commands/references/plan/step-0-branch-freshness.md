# Plan: Step 0: Local Branch Freshness

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. Wording of everything shown to the operator follows `commands/references/user-communication.md`.

## Local Branch Freshness

`BRANCH_DIVERGENCE` is the object Step 0 stored: `{branch, divergence, ahead, behind}`, read after `git fetch origin`. This file runs only when `divergence` is `local-behind` or `diverged`, which means origin holds commits the working tree does not have.

The plan is written against the working tree. Research reads it, stories cite it, and `metadata.baseRef` records its HEAD. Nothing here changes that rule: the question is only whether the person wants the tree brought up to date before the plan is written against it.

### Agent mode

When `INTERACTIVE_MODE=agent`, ask nothing and change nothing. Emit exactly one line and continue to Phase 0:

```
[plan] base: local <branch> is <behind> commit(s) behind origin/<branch> (<ahead> ahead); planning against the local tree
```

### Interactive mode

Present **one** AskUserQuestion. Say which branch it is, how many commits origin has that the local branch does not (`behind`), and how many local commits origin does not have (`ahead`).

When `divergence` is `local-behind`, offer exactly these three options, in this order:

```
Update — fast-forward the local branch to origin, then plan
Continue — plan against the local tree as it is
Stop — end here; nothing is written
```

When `divergence` is `diverged`, a fast-forward is impossible, so offer only `Continue` and `Stop`, and say that the two sides must be reconciled by hand if the person wants origin's commits in the plan.

- **[Update]:** run the block below with the `branch` value from `BRANCH_DIVERGENCE`. It moves the branch only when that loses nothing, and git refuses it when a local change would be overwritten.

  ```bash
  AIMI_ROOT="$PWD"
  while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
  [ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  if [ "$(git -C "$AIMI_ROOT" branch --show-current)" != "[branch]" ]; then
    echo "UPDATE=failed: the checkout at $AIMI_ROOT is no longer on [branch]"
  else
    git -C "$AIMI_ROOT" merge --ff-only "origin/[branch]" && echo "UPDATE=ok" || echo "UPDATE=failed"
  fi
  ```

  It acts on the checkout `BRANCH_DIVERGENCE` was read from and nowhere else. On `UPDATE=ok`, continue to Phase 0. On `UPDATE=failed`, show the message verbatim and ask again with `Continue` and `Stop` only.
- **[Continue]:** continue to Phase 0. The plan's `baseRef` will name the local HEAD.
- **[Stop]:** end the command. Nothing has been written.

### Never

- Run `git pull`, `git rebase`, `git reset`, `git stash` or `git checkout` here, or any merge that is not `--ff-only`.
- Point research at `origin/<branch>` instead of updating the tree: every later phase reads the working tree, and a finding taken from another ref describes code the executor will not find.
