# Bookkeeping Files

Read before changing `bookkeeping-declared`, `bookkeeping-resolve`, the `bookkeeping` key of `.aimi/config.json`, the `declared` parameter of `wave_contention`, or the cross-story auditor's shared-path rule.

## What a bookkeeping file is

Some repository files change in every story by design: a changelog gains a bullet, a version manifest gains a version, a test script's assertion total moves, a size baseline row grows. Two stories of one wave that both touch such a file conflict textually, and the conflict has one right answer that needs no judgment. Without a declaration the planner serializes those stories with a `dependsOn` edge and the wave merge hands the conflict to the judgment loop. A declaration lets both be skipped for exactly the files that are mechanical.

## The declaration

The `bookkeeping` key of `.aimi/config.json` is an object keyed by project key, with `.` as the single-repo key. Each value maps an exact repository-relative path to `{"rule": ...}`:

```json
{"bookkeeping": {".": {"CHANGELOG.md": {"rule": "union-lines"}}}}
```

A path is refused when it is empty, absolute, starts with `./`, holds a backslash or a control character, or has a `..` segment. An entry with an unknown rule, a missing rule or any key besides `rule` is refused. Only the requested project's entry is validated, so an unrelated key never refuses this project. Absence is never an error: no config, no `bookkeeping` key or no entry for the project all read as an empty declaration, and every verb then behaves as it did before the feature.

**It is a per-machine setting, because the config is untracked.** A rule decides how a merge result is written without a person looking at it, so it is never honoured from a file a contributor can change in a pull request. A tracked config that carries a bookkeeping declaration is refused, naming the file; a tracked config declaring nothing is not refused, because it asks for nothing to be trusted. The probe is `deps_recipe.config_is_tracked`, the same one `deps-recipe-record` uses, and it runs only when the config actually declares something.

## The four rule kinds

| Rule | Resolves a conflicting line by |
|---|---|
| `union-lines` | whole-line set union of both sides, order-preserving, idempotent |
| `max-version` | the highest dotted-numeric version on the line |
| `sum-delta` | ours + theirs - base on the one integer of the line |
| `size-step` | the smallest multiple of 4096 covering the merged size |

`max-version`, `sum-delta` and `size-step` share one three-way line walk: per line, equal sides keep it, a side equal to base yields to the other, and only a line both sides changed reaches the rule's claim test. `union-lines` does not use the walk and applies its own whole-file claim.

`sum-delta` and `size-step` are arithmetic. No command is run: `sum-delta` computes ours + theirs - base from the three texts, and `size-step` measures the merged text through an injected callable and rounds up to a multiple of 4096. A computed number is a best guess about what the file should say, not a fact, so the integrated wave check must still pass after resolution. The vocabulary has no prose-figure rule: a figure written inside a sentence is not recoverable by arithmetic and falls to the judgment loop.

## Safety rules

- **A rule resolves a file only when it claims every conflict hunk in it.** One hunk the rule cannot answer, or a line-count mismatch between the versions, leaves the whole file unclaimed and it falls to the judgment loop. A partial text is never returned, because a half-resolved file that looks resolved is worse than a conflict.
- **Files are written in one pass or none is.** Every resolution is computed in memory first. A refusal of kind `unproducible` (the rule cannot produce an answer at all, for example a size it cannot measure) writes nothing. An unclaimed file stays conflicted for the judgment loop and the other files are still written. Each write goes through a temp file beside the target and `os.replace`; a write that fails restores the files already replaced.
- **A failed verify restores both sets.** The wave merge stages the resolved and the judged files together and, on failure, runs `git checkout --merge` over both, so git's own conflict comes back and the next run resolves it identically.
- **A re-run is idempotent.** The verb reads index stages (base, ours, theirs), never the working tree's conflict markers, and stages nothing, so a second run starts from the same input and prints the same answer.
- **Bookkeeping resolution is never used to merge a finalize-owned bump with a story bump.** A release bump owned by the finalize step and a story's own bump are different decisions, not two additions to one list, and taking the maximum would hide the second.

## Verb contracts

`bookkeeping-declared [--project <key>]` is read-only. It prints one project key's effective declaration as one JSON line and is listed in `hooks/auto-approve-cli.sh` Pattern 2 with the other read-only verbs.

`bookkeeping-resolve [--project <key>] [--root <dir>]` is a writer, and is kept out of `hooks/auto-approve-cli.sh` Pattern 2 so it prompts like any other writer. It refuses without `python3` rather than degrading, because a caller that believes files were resolved when none were would commit conflict markers away. It takes no CLI lock: it writes only the working tree of the repository named by `--root`, which must be that repository's top level and is not a shared document. Output is `{resolved[{path,rule,changes}], unclaimed[{path,rule,reason}], refused[{path,rule,kind,reason}]}`; a non-empty `refused` exits 1 with nothing written. Callers branch on `kind`, never on reason text.

Paths match by exact string equality against the declaration, relative to `--root`. A declared path that is not conflicted and a conflicted path that is not declared are neither read nor written.

## Plan-time contracts

`wave_contention` (in `tasks.py`) takes the declared paths as an optional parameter, a map of project key to a set of paths, matched by exact string equality. An absent declaration gives today's output unchanged. A path with several claimants is exempt only when every claimant's own project key declares it, and a mixed overlap lists the undeclared paths only. The cross-story auditor no longer re-derives the shared-path rule for its `dependsOn` serialization: the `staging-contention` verb hands it the contending staged pairs, computed by the same `wave_symbol_contention` the wave check uses with this declaration passed in (see `docs/dev/wave-contention.md`). It patches only listed pairs, still skips a pair's declared paths, reads them from a data line it never opens as a file, and a path declared under another project key exempts nothing.

## Modules

| Module | Role |
|---|---|
| `scripts/bookkeeping.py` | the one reader and validator of the declaration (`load_declaration`) |
| `scripts/bookkeeping_rules.py` | the four rules, pure: three file versions in, merged text or a structured refusal out |
| `scripts/bookkeeping_declared.py` | the reader behind `bookkeeping-declared` |
| `scripts/bookkeeping_resolve.py` | the writer behind `bookkeeping-resolve` |

Tests: `test_bookkeeping.py`, `test_bookkeeping_rules.py`, `test_bookkeeping_declared.py`, `test_bookkeeping_resolve.py`, `test_bookkeeping_resolve_step.py` and `test_auditor_bookkeeping_declared.py` under `scripts/tests/`. The loop ordering is in `docs/dev/execute-wave-loop.md` § Bookkeeping files are resolved by declared rule; the procedure is `commands/references/execute/bookkeeping-resolve.md`.
