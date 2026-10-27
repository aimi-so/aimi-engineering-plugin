# Plan: Phase 3d: Pass 2 Story Expansion, working tree guard

> Loaded by `commands/plan.md` when its `Applies when:` condition holds.

### Working Tree Guard

An expander writes one staging file and nothing else, but it holds tools that can edit the repository, and expanders have edited it and run a bare `git stash` to "try" a story. Run the block below with `snapshot` right before a batch of expander spawns (a wave, a retry, a Retry with hint, an Edit-outline re-expansion) and with `check` once the batch has returned, before Schema Validation. It records `git status` and the stash of every repository under AIMI_ROOT, ignoring `.aimi/`:

```bash
TREE_GUARD_MODE="[snapshot or check]"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
TREE_STATE=$(find "$AIMI_ROOT" -mindepth 1 -maxdepth 2 -name .git 2>/dev/null | sort | while IFS= read -r TREE_GIT; do
  TREE_REPO=$(dirname "$TREE_GIT")
  printf '== %s\n' "$TREE_REPO"
  git -C "$TREE_REPO" status --porcelain=v1 --untracked-files=all 2>/dev/null | grep -v '^.. \.aimi/'
  git -C "$TREE_REPO" stash list --format='stash %H' 2>/dev/null
done)
case "$TREE_GUARD_MODE" in
  snapshot) printf '%s\n' "$TREE_STATE" > "$RUN_DIR/tree-guard.txt" ;;
  check)
    if [ ! -f "$RUN_DIR/tree-guard.txt" ]; then echo "tree-guard: no snapshot to compare against" >&2; exit 1; fi
    if printf '%s\n' "$TREE_STATE" | cmp -s - "$RUN_DIR/tree-guard.txt"; then
      echo "tree-guard: working tree and stash unchanged"
    else
      echo "tree-guard: the working tree or the stash changed while expanders ran" >&2
      printf '%s\n' "$TREE_STATE" | diff -u "$RUN_DIR/tree-guard.txt" - >&2
      exit 1
    fi
    ;;
  *) echo "tree-guard: mode must be snapshot or check" >&2; exit 1 ;;
esac
```

**A failed check stops the plan, in every mode.** Spawn nothing more, report the diff above to the user, and keep `RUN_DIR`. Nothing is reverted automatically: only the expanders ran between the two calls, but whether to keep or undo a change in the user's own tree is the user's call. A change the user made in that tree while the batch ran trips the check too, which is why the report shows the diff instead of guessing whose it is. `tree-guard.txt` is not a staging file (`[0-9][0-9]-*.json` is), and story-merge removes it with `RUN_DIR`.
