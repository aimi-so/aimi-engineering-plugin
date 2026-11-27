# Wave Contention: Symbol-Level Declarations

Stories of one wave run side by side, each in its own worktree, so two of them that
edit the same file race each other and meet only at the merge. The wave check refuses
that before execution. This note covers the three pieces that let it tell two stories
that merely touch one file from two that touch the same name inside it: the
`implementation.symbols` declaration, the rule `wave_symbol_contention`, and the
`staging-contention` verb that hands the same rule to the cross-story auditor while a
plan is still staged. Read it before changing any of them, or the messages and
smells they print.

## `implementation.symbols`

An optional object on a story's `implementation`, keyed by a path that is an exact entry
of the same story's `implementation.files`:

```json
"symbols": {"plugins/x/tasks.py": {"creates": ["wave_thing"], "edits": ["wave_contention"]}}
```

- Each value holds only `creates` and/or `edits`, each a list of strings, with at least
  one name in total. A name is judged by the identity rule (`_identity_reasons(name, "")`
  in `roadmap.py`, called with an empty description because a symbol has none).
- An absent key draws no finding from the schema rule (R30 of `validate-tasks`). A
  present key must be an object; `{}` is valid and says no file has a nameable symbol.
- **A path of `implementation.files` with no key is a whole-file claim**, and so is every
  file of a story whose map is absent or `{}`. Undeclared means "the whole file", never
  "nothing".
- The shape rule is `implementation_symbol_findings` in `tasks.py`, stated once; the
  reader the wave check uses is `declared_symbols(story)`, `{path: set of names}`
  (`creates` and `edits` read together) for exactly the entries that draw no finding. Both
  answer from one private per-entry helper, `_symbol_entry_problem`, so a malformed entry
  is refused by the validator and counts as not declared in the wave check, and the two
  cannot disagree. Both are lexical: the filesystem is never read. The field's shape is
  also written in `docs/dev/tasks-schema.md`.

Only declared names are measured. A story that touches a name it did not declare is not
refused at execute time: the story executor reports it as a `knownGaps` entry of the form
`undeclared-symbol: <path> <symbol>` and the integrated wave check remains the net.

## `wave_symbol_contention`

`wave_symbol_contention(claimants, declared=None)` in `tasks.py` is the rule, before it is
worded: it returns findings, never strings. `wave_contention` words them for
`validate-wave-contention`, and `staging_contention` reads them for the auditor.

**Same project only.** Stories are compared inside one computed wave AND one project key
(`_story_project_key`: the story's own `project`, else `.`). Two stories of different
projects that list one literal path name two different files, so they never contend. The
wave is the computed one, never the stored one (`computed_waves`), because a stale stored
`wave` must never hide a real contention.

For a path with two or more claimants whose project does not declare it as bookkeeping
(`docs/dev/bookkeeping.md`), each finding is one of:

| kind | when | outcome | message |
|---|---|---|---|
| `file` | some claimant has no entry for the path | refusal, one per path | `Wave contention: wave N path P claimed by A, B` |
| `symbol` | every claimant has an entry and a name is in two or more | refusal, one per shared name, sorted | `Wave contention: wave N path P symbol S claimed by A, B` |
| `shared-file` | every claimant has an entry and no name is shared | warning, verdict gains a `warnings` key | `Wave contention warning: wave N path P shared by K stories with disjoint symbols: A, B` |

A `symbol` path draws no other finding. A verdict with no `implementation.symbols` anywhere
and no cross-project overlap answers as before. Remedies are in
`commands/references/plan/phase-45-validation.md`: a `dependsOn` edge for a symbol
refusal; for a file refusal an edge, narrower `implementation.files`, or an
`implementation.symbols` entry for the path on EVERY claimant when the symbols are
disjoint. A warning needs no fix. **Which old plans now pass:** a plan whose only
contention was a literal path listed by stories of different projects was refused before
and is not now, and a plan whose claimants declare disjoint symbols on a shared file
passes with a warning.

## `staging-contention`

`aimi-cli.sh staging-contention --staging-dir <dir>` answers one line, `{"pairs":[...]}`,
exit 0: the staged-story pairs `validate-wave-contention` would refuse, computed by the
same `wave_symbol_contention`. The code is `staging_contention` in `story_merge.py`. Each
staged `NN-*.json` becomes a story `outline:<NN>` whose `dependsOn` keeps only the
`outline:NN` tokens that have a staged file; waves come from `computed_waves` and the
bookkeeping declaration is built the way `op_validate_wave_contention` builds it. Only
`file` and `symbol` findings give pairs (a `shared-file` warning gives none); a finding of
three or more stories gives one pair per two of them, the lower outline index first, each
`{wave, path, symbol, stories}` with `symbol` null for a file pair. It refuses (non-zero
exit) on an unreadable declaration, and `/aimi:plan` Phase 3d.5
(`commands/references/plan/phase-3d5-audit-spawn.md`) then renders the auditor's input as
`unavailable`, never as `none`. The auditor patches only listed pairs and derives no
contention itself (`agents/review/aimi-cross-story-auditor.md`, input 7).

## Answering `context-budget.md`, The Question Every New Gate Must Answer

`commands/references/context-budget.md` § The Question Every New Gate Must Answer asks
whether what a check measures has any relation to what it claims. Three gates here need
the answer. The same limit applies to all three: **only declared names are measured.**
`wave-verify-commands` and `commands/references/execute/wave-reconcile.md` (the
integrated wave check, run on the merged tree) are the net for an undeclared edit and for
a shared literal such as a counter two stories both raise.

### The symbol refusal of `validate-wave-contention`

- **Measures:** whether two stories of one computed wave and one project, each with a
  well-formed `implementation.symbols` entry for a shared path, name the same symbol in it.
- **Claims:** that two executors dispatched together will not both change one symbol.
- **Cannot evaluate:** a story with no entry, or a malformed one, for a shared path is a
  whole-file claim and keeps the file refusal rather than passing; a story whose declaration
  is incomplete or untrue (an edited name left out) is invisible to the check.

### The missing-declaration refusal of `validate-staging`

- **Measures:** that a staged story whose `implementation` object has no `implementation.symbols`
  key, or holds null, declares one (`{}` counts), by `symbol_declaration_missing_findings`.
  `story-merge --require-symbols` refuses the same stories through the same function.
- **Claims:** that the story author answered the question for each file, not that the answer
  is true.
- **Cannot evaluate:** the truth of a declaration; a story with no `implementation` object
  draws nothing; a malformed map belongs to the shape rule, not to this one.

### The advisory symbol-produces smell

- **Measures:** exact, case-sensitive equality between the names a story creates and the
  `sym:`/`cli:` names after the prefix of the `produces` tokens of its outline entry:
  `unproduced` created names equal to no produced name, `uncreated` produced `sym:` names
  no created symbol equals.
- **Claims:** that a story's declared symbols and its outline entry describe the same work.
- **Cannot evaluate:** a story with no declaration or a malformed one, or no matching outline
  entry, is skipped; helper functions show up in `unproduced` without being wrong, which is
  why it advises, never gates, and is recorded in `metadata.smellWarnings` as
  `{type: "symbol-produces", ...}` only when `story-merge` receives `--outline`.

## Tests

| Test | Pins |
|---|---|
| `scripts/tests/test_tasks.py` | `implementation_symbol_findings`, `declared_symbols`, `wave_symbol_contention` and the wave verdict |
| `scripts/tests/test_symbol_declaration_required.py` | the missing-declaration refusal and `--require-symbols` |
| `scripts/tests/test_staging_contention.py` | `staging-contention` |
| `scripts/tests/test_auditor_staging_contention.py` | the auditor's input 7 and its spawn |
| `scripts/tests/test_plan_wave_contention_warnings.py` | the warnings and remedies at plan validation |
| `scripts/tests/test_expander_symbols.py` | the expander declaring symbols |
| `scripts/tests/test_story_executor_symbols.py` | the executor brief and the `undeclared-symbol` report |
