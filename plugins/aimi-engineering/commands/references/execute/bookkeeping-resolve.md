# Execute: Bookkeeping Resolve

> Loaded by `commands/execute.md` through its Step 4 entry, before the in-place conflict loop of the wave merge.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Inputs

The in-place conflict loop of `step-4-wave-execution-loop.md` runs this procedure once per pass, before any judgment. The caller derives the state; this file never re-derives it.

```
group_key, merge_cwd, merge_target, label     # label: "wave N"
conflicted            # git -C [merge_cwd] diff --name-only --diff-filter=U, this pass
machine_resolved      # one list per group, kept across the passes of that group's merge
```

`machine_resolved` starts empty for each group. It is handed to `wave-reconcile.md` after the merge, so the reconcile loop knows which files a rule wrote.

## Run the resolver

```
project = "." if group_key == "DEFAULT" else group_key
out = $AIMI_CLI bookkeeping-resolve --project [project] --root [merge_cwd]
      # stdout: {resolved[{path,rule,changes}], unclaimed[{path,rule,reason}], refused[{path,rule,kind,reason}]}
```

The verb rewrites only declared, conflicted files inside `merge_cwd`. It stages nothing and writes nothing on a refusal, so a stop needs no restore and a re-run starts from the same conflict. With nothing declared the three arrays come back empty and the pass is the judgment loop alone: no report line, no change of edit scope.

## Outcomes

Branch on the `kind` of each entry and on the exit status. Never branch on reason text.

```
if exit is 1 and stdout is empty:        # a malformed or git-tracked declaration
    unresolved_reason = the stderr line
    stop the loop (the existing MERGE CONFLICT report)
if exit is 1 (refused[] is non-empty, kind "unproducible"):
    unresolved_reason = "bookkeeping refused: " + for each refused entry "[path] ([rule]): [reason]"
    stop the loop before any judgment (the existing MERGE CONFLICT report)
resolved   -> a file a rule wrote: it is no longer judged
unclaimed  -> declared but not claimed by its rule: the judgment loop takes it, with the file named
```

`judged = conflicted` minus the `resolved` paths. The judgment loop edits only `judged`: the unclaimed files and the undeclared ones.

Append each `resolved` entry `{path, rule, changes}` to `machine_resolved`. A path resolved in an earlier pass of the same group is not removed.

## Verify, stage together, continue

- Involved stories are taken over every conflicted file, resolved and judged alike, and each involved story's `implementation.verify` still runs when every conflicted file was declared.
- The resolved and the judged files go through ONE `git add -- [conflicted...]` and ONE `git commit --no-edit --cleanup=strip`, after the verifies pass.
- A failed verify, or acceptance criteria that cannot all hold, runs `git checkout --merge -- [conflicted...]` (`git -C [merge_cwd]`) over BOTH sets, then the existing stop. The rule's output is discarded with the judged edits, and the next run resolves the same conflict identically.
- merge-all then continues over the remaining stories, as it does after a judged resolution.

## Report

Each machine resolution is reported, with its file, rule and before/after values:

```
Report: "Bookkeeping resolved [path] by [rule] ([label], [group_key]): [for each change: line N: [before] -> [after]]."
```

A judged file keeps the existing `Resolved merge conflict in ...` line.
