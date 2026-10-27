# Execute: Step 0.9: Split Detection

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 0.9: Multi-File Auto-Detection

Discover whether the tasks files on disk form a **split group** — a set of sibling task files planned together in one `story-merge` run that must all execute in this single invocation. Detection is owned entirely by one CLI verb; this step reads its answer and never re-derives it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI split-detect | jq -r '
  "mode=\(.mode) activeCount=\(.activeCount) total=\(.total)",
  "anchor=\(.anchor // "-")",
  (if .degradedReason == null then empty else "degraded: \(.degradedReason)" end),
  (.members[] | "  \(if .active then "active " else "skipped" end)  \(.project)  \(.branchName // "-")  \(.path)")
'
```

### Split Detection

`split-detect` is a **query, not a gate**: every detection outcome — including `single` and `none` — exits 0. A non-zero exit means a real error (bad argument, unreadable directory); report its stderr verbatim and STOP.

It owns every rule this step used to spell out as prose, and each of those rules is now a test case in `test-aimi-cli.sh` (TC36–TC54, the split-detect cases of part 2):

- **Project-Split Detection** — reads the `metadata.splitGroup` marker `{project, index, total, siblings[]}` that `story-merge`'s N-file PROJECT-axis writer stamps on every file it emits, resolves the anchor's declared siblings **by basename** against the anchor's own directory (which renders a traversal-shaped sibling entry inert), and validates the declared `total` against the resolved count. Nothing outside the anchor's own declared sibling list ever joins the group, however similar its basename.
- **Paired Split Detection** — the legacy `-frontend-tasks.json`/`-backend-tasks.json` suffix-and-shared-prefix rule, reached only when the newest candidate carries no marker. Unmarked pair members report `project` as `"."`.
- **Active Split Files** — a member is *active* when it has at least one story whose status is neither `completed` nor `skipped` (both are terminal). A file whose `userStories` array is empty (the N-file writer legitimately emits one for a project group that ended up with zero stories) is never active, and an inactive member produces no worktree, no branch, no container, no spawned Task, no report block, and no cleanup call. The predicate is `(.status // "pending")` outside the pair `completed`/`skipped` — one definition behind every count the verb reports.

Two of its properties are load-bearing for this step:

- **Its flat scope is depth 1 only** — the `*-tasks.json` files sitting directly in `.aimi/tasks/`, never a phase directory's own files. Step 0.9 runs before phase mode is resolved, so without that bound a PROJECT-axis phase would be picked up and executed here as a flat split, with the phase never claimed and nothing merged into the phase branch. A phase's own split is matched instead by Step 1.7's **Detect a Full-Stack Split Inside This Phase**, which detects against that one phase's directory; `split-detect --dir <phase-dir>` is the same verb narrowed to exactly that scope.
- **Newest wins.** The anchor is the newest candidate by mtime — not the first marker-carrying file in mtime order. A group with no active member is dropped from the candidate pool and the next-newest candidate is considered, so a stale split can neither preempt today's plan nor divert it to a single-file fallback.

Branch on `mode` and `activeCount`:

| `mode` | `activeCount` | Continue with |
|---|---|---|
| `none` | `0` | Skip the rest of Step 0.9 — Step 1's `init-session` reports the missing-file error. |
| `single` | `1` | **Single-File Fallback**, passing `.anchor` explicitly. |
| `project-split` / `paired-split` | `1` | Nothing left to parallelize — **Single-File Fallback**, passing the one active member's `.path` explicitly. |
| `project-split` / `paired-split` | `≥ 2` | The split flow: **Per-Repo Branch and Container Setup for the Split** onward. |
| `ambiguous` | any | **Stale Flat Plan Versus Planned Phase**, below. |

When `degradedReason` is non-null, report it verbatim; do not re-derive *why* the group was rejected, since the verb already computed both counts and the specific defect. A degraded group is terminal — it deliberately does not fall through to the legacy pair rule, because a scope planned by the project-split writer makes any `-frontend-tasks.json`/`-backend-tasks.json` sitting beside it stale, and running it would execute the wrong work.

### Stale Flat Plan Versus Planned Phase

`ambiguous` means the winning flat file has no `pending` or `in_progress` story and at least one `failed` one, while a `roadmap.json` under `.aimi/tasks/` holds a planned phase that is claimable (unclaimed, dependencies completed). The output still carries `.anchor` (the flat file), `.failedCount`, and `.claimablePhases[]` as `{feature, id, name}`. A flat file that still has a pending or in_progress story keeps its normal mode, and `--dir` scope never reports `ambiguous`. Never prefer either side automatically:

- **Picker mode** — ask via AskUserQuestion, naming the flat file with its failed count and each claimable phase (`feature`, `id`, `name`). Continue with the Single-File Fallback on `.anchor` if the flat file is chosen, or with phase mode for the chosen phase.
- **Agent mode** — print both and exit 1: `Ambiguous: stale flat plan <anchor> (<failedCount> failed) and claimable phase(s) <feature>#<id>. Re-run with /aimi:execute --phase N, or pass the tasks file explicitly.`
- **Bypass** — `--phase`, `--file`, or an explicit tasks argument skip this check; this step does not run `split-detect` for them.
