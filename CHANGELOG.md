# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.131.0] - 2026-09-05

Phase 3 of verification-integrity: the completion record gains negative space.
Closes the first and third items of issue #136 — a record that could not tell a
checked run from an empty one, and artifacts that carried no version to slice by.

### Added

- **The executor returns the verify evidence it already computes.** The
  `<result_json>` Result Contract gains an eighth key, `verify`, carrying the
  real verify's exit, the step-1.5 pre-run's exit, how many segments
  `verify-probe` returned and how many of them discriminated. Step 1.5 already
  measured all four and wrote them to a throwaway file that died with the
  worker. The object is omitted entirely when the story declares no verify —
  that absence is itself the signal, and zero is never used to mean "not
  measured", because zero is a real measured pass.
- **`mark-complete` accepts an optional `--evidence` and persists it at
  `verification.evidence`.** The write goes deep, through the same `jq_setpath`
  writer `update-field` uses: the shallow `. + {…}` patch the four mark-* verbs
  share would have replaced the whole `verification` object and destroyed
  `strategy`, `status`, `url` and `expect`. Without the flag the verb applies
  the identical `{"status": "completed"}` patch it always did and the crossing
  stays silent, so the 14 recorded `mark-complete` cases in
  `tests/golden_from_jq.json` are byte-unchanged. `/aimi:next` keeps calling it
  flagless forever, which is what makes that no-op load-bearing rather than
  tidy.
- **`verification-report` names which completed stories discriminated.** A
  fourth top-level key, `discriminating`, partitions completed stories into
  `checked`, `blind` and `unrecorded` beside a null-safe `fraction`. Absent
  evidence reads as `unrecorded`, never as `blind`: a story completed before the
  field existed was not shown to have zero discriminating assertions — nothing
  was recorded, and reporting a confident zero there would be a worse lie than
  the silence it replaces. `unrecorded` stays outside the denominator, so a
  legacy file answers `null` rather than `0`. The count is read as a plain
  non-negative int with `bool` rejected first, since `isinstance(True, int)`.
- **`metadata.pluginVersion` stamps the writing install into every tasks.json.**
  Shared across split files rather than resolved per file: `branchName` and
  `baseRef` are per-file because they name a repository, but a version names the
  writer, and one `/aimi:plan` invocation has one writer however many
  repositories it splits across. Omitted entirely when it cannot be resolved,
  the same rule and the same reason as `baseRef`.

### Changed

- **`/aimi:execute` carries the evidence from executor to record to report.**
  The wave loop reads `result_json.verify` beside the `knownGaps` extraction and
  passes it to the one `mark-complete` call already there, omitting the flag
  entirely — never empty — when the worker recorded nothing. The completion
  report prints `verification-evidence: discriminating=N completed=M`
  unconditionally, plus a `closed unchecked` line when `checked` is zero and
  completed stories exist. Printing only when the number is good would have
  reproduced the exact defect this phase removes.

### Known limitation

- The fraction is a **ceiling on what was verified, not a measurement of it**.
  Its input is `verify-probe`'s `discriminates`, and the probe's prelude carries
  only assignments and `cd`, so an assertion that fails because its
  `mkdir`/`printf`-built fixture never existed still scores as discriminating.
  Recorded in the field's own doc comment and in
  `.aimi/known-gaps/2026-09-04-p2-verify-probe-tem-uma-terceira-cegueira.md`.

## [1.130.0] - 2026-09-04

Phase 2 of verification-integrity: the narrow-trigger holes, and the two
decisions that were open for want of a decision rather than a fix.

### Fixed

- **`verify-probe` tells an assertion that has not passed yet from one that
  never can.** `discriminates` was `status != 0`, so a segment that could never
  pass — a check whose harness cannot observe what it claims — was reported as
  discriminating, indistinguishable from a good assertion. The verb now accepts
  `--previous-file`, the pre-run's own JSON, and names a segment `unsatisfiable`
  when it failed in both runs. Nothing is inferred from a segment's text; only
  failing twice separates a broken harness from unfinished work, and a lone run
  answers exactly what it answered before.
- **The wave notices an executor that goes idle without reporting.** The wave
  loop's only fallback presumed the Task returned something usable. It now
  crosses three facts it already captures — no `result_json`, HEAD unchanged
  from the captured base, dirty worktree — and routes the story into the two
  resolutions that already exist (commit rescue, or mark-failed plus
  cascade-skip) rather than adding a third. The report names which one handled
  it.
- **`write-review` names a review file in a flat execution.** The verb required
  `--feature` and `--phase` unconditionally, so a non-phase run had its design
  review die with the session — issue #135's defect surviving outside phase
  mode. A second naming mode, chosen by which flags arrive, derives the path
  from the active tasks file's basename; exactly one flag is refused rather than
  guessed.
- **`open-pr`'s backend issue honors the branch gate the PR title already
  had.** `metadata.title` is read once and gated against `branchName` for the PR
  title only; the mismatch branch warned but left the variable populated, so the
  backend issue could still be titled after an unrelated feature. The mismatch
  branch now empties it, and the issue call falls back to this branch's own
  derived title, announcing the source.

### Changed

- **`wave` is documented as derived, and rebuildable.** The schema now states
  that `wave` comes from `dependsOn`, is informational, and is never consumed by
  dispatch — measured: it is read zero times as a field outside `validate_waves`
  itself, and `list-ready` never mentions it. A new `normalize-waves` verb
  recomputes it beside the three existing `normalize-*`, importing
  `compute_waves` from `story_merge.py` rather than restating the writer's rule.
- **The static-analysis corpus reaches `agents/`.** `command_block_files()`
  gained a third root, walked recursively like `commands/`. Measured by invoking
  the extractor rather than by grep: 33 agent files, 8 carrying a bash fence,
  all parsing clean — the block baseline gained no entries. The two files over
  the size ceiling are grandfathered at their measured sizes.


## [1.129.0] - 2026-09-04

Phase 1 of verification-integrity: what a phase judges with, and what a plan is
allowed to see.

### Fixed

- **Creates Verification judges with the CLI the phase itself produced.** Each
  participating repository's `verify-creates` call now prefers that repository's
  own phase-container `aimi-cli.sh` when one exists and is executable, falling
  back to the resolved CLI otherwise and naming the fallback on one stderr line.
  A phase that changes the CLI's own logic was previously judged by whatever the
  global cache had installed — which accepted a comment as evidence for an
  artifact the changed code correctly located in real source.
- **`aimi-cli.sh` resolves its own directory before `find_aimi_root` moves the
  cwd.** `_aimi_script_py` resolved `${BASH_SOURCE[0]:-$0}` at call time, after
  the cwd had already changed; a relative invocation from inside a nested
  worktree therefore dispatched to the PARENT checkout's `tasks.py`,
  `roadmap.py`, `models.py` and `story_merge.py`. A worktree testing its own
  changed modules silently ran the unchanged ones. The directory is now captured
  once at the top of the file, keeping the `cd`/`pwd` pair so a script reached
  through a symlinked directory still resolves correctly.
- **The KNOWN-GAP extractor matches both spellings executors actually write.**
  The merge-time trailer grep in `execute.md` widened from `^KNOWN-GAP:` to
  `^KNOWN-GAP( \([^)]+\))?:`, still anchored to line start. Measured against
  the corpus: the old pattern matched 35 lines of 114 — the extractor was seeing
  31% of what executors had written.
- **`plan.md` reads the whole known-gaps corpus rather than the planned
  feature's slice.** Phase 1.7b scoped its read by `--feature` whenever a slug
  resolved. Measured by executing the block: a feature reached 20 of 134 entries
  and left 114 invisible — nearly all of them describing the pipeline every
  feature runs through, not the feature they happened to be filed under. A
  feature with gaps of its own gains entries and loses none (pipeline-audit
  113 → 134, its 113 a subset).

### Changed

- **A story's `implementation.verify` can resolve its own tasks file.**
  `story-executor` now exports `TASKS_FILE_PATH` into the verify's environment
  at both the pre-run and the real run, in both templates, so a verify needing
  `metadata.baseRef` reads the file its own story lives in rather than the
  shared `current-tasks` pointer a sibling split orchestrator may have
  overwritten. The expander's byte-reduction shape uses it when set and
  documents its fallback for a verify run by hand.


## [1.128.0] - 2026-09-04

Phase 4 of the pipeline audit: the plugin's own cache resolution, `open-pr`
correctness, and four checks the pipeline had built but never run.

### Added

- **`AIMI_DEV_DIR`, a layer-0 development override honored on any host.** Testing
  a branch used to mean editing the installed cache in place, which is how a
  temporary edit becomes the machine's plugin. The variable names a checkout to
  run instead, validated exactly as `AIMI_PLUGIN_DIR` is — absolute, existing,
  with an executable `scripts/aimi-cli.sh` — and refused when it points inside a
  worktree. Every command resolving through it prints an unconditional stderr
  line naming where it is running from: the defect being closed is a real install
  silently shadowed, so the notice appears on the success path, not only on
  failure. `check-version` answers a `dev-override` status and never `--fix`es,
  because repointing the global cache at a development tree is the damage the
  override exists to avoid. Unlike `AIMI_PLUGIN_DIR`, it is not skipped inside
  Claude Code; that rule is unchanged.
- **A byte-reduction claim must measure both sides.** `aimi-story-expander` now
  requires a criterion asserting a saving of N bytes to emit the measurement in
  its own `verify` — the previous size from `metadata.baseRef`, the current size
  from disk, compared against N — and to fail rather than fall back when the base
  cannot be resolved. `HEAD` is named as the wrong base for a reason worth
  keeping: by the time the check runs the story's own edit is in the tree, so
  `git show HEAD:<path>` can hand back the file the story just wrote and report a
  reduction of zero as a pass. A reduction with no number is not a claim and is
  rewritten to carry one.

### Fixed

- **A cache directory that is not a version can no longer win.** `sort -V` is a
  total order over arbitrary strings, not a filter, so a sibling `1.124.0.bak`
  outranked the real `1.124.0` and a directory named `zz` outranked `1.127.0`.
  `_resolve_latest_cache_path` now requires three numeric segments before the
  sort. The damage this was doing was not cosmetic: the recorded behaviour of
  `cleanup-versions` was to delete the real `1.2.3` install and keep the
  malformed directory beside it. The idiom moves across all seven surfaces that
  carry it, the approval hook included, so no inline CLI resolution starts asking
  for permission again.
- **A comment about the work no longer counts as the work.** `verify-creates`
  filtered only `TODO`/`FIXME`/`XXX`/`HACK` markers, so any other comment line
  satisfied a `creates` entry — twice in the previous phase the prose written to
  explain a defect became the evidence that the artifact existed. An identity
  whose only textual evidence is a comment now returns `unconfirmed`, which
  `execute.md` already treats as undelivered. The narrowness lives in the comment
  opener rather than in a prose-versus-code test, so `#define parseThing(x)`,
  `--count;` and `*ptr = f();` keep reading as code while `// f() is called here`
  does not.
- **`list-known-gaps` reads the corpus that exists.** A filename suffix became a
  feature without anything checking that the feature existed, so the corpus
  reported sixteen features of which the largest — thirty entries under `phase2`
  — was not one, and `--feature` excluded every entry whose feature had not
  resolved. A suffix is now believed only when it names a known feature, and the
  filter also returns the unattributed: an entry with no feature is not another
  feature's entry, and a planning defect with no owner is still one this plan can
  repeat. Measured coverage of the real use path went from 26% to 82%.
- **`open-pr` verifies the branch before switching to it, and says where the
  title came from.** A tasks file naming a branch that was never executed used to
  switch to it and fail further downstream with an unrelated error; the ref is now
  checked with `show-ref --verify refs/heads/`, which — unlike `rev-parse` — also
  refuses a same-named tag, and the command reports that the plan was generated
  and never run. `metadata.title` is adopted only when the tasks file's
  `branchName` matches the PR's branch, so an unrelated feature's file can no
  longer title this pull request, and all three sources are named in the output.
- **`verify-probe` stops writing into the caller's directory.** It replicated
  variable assignments between segments but not `cd`, so a later `mkdir` landed in
  the executor's own worktree — producing the class of defect the probe exists to
  find. The `cd` is now carried in the prelude, as `<segment> || exit 1` rather
  than bare: a `cd` that fails would otherwise leave everything after it running
  in the caller's directory again, the same defect with nothing in the answer to
  say the probe never moved. Refusing such a verify was considered and rejected on
  a measurement — eleven of the plugin's own 258 verifies carry a `cd`, and they
  are the elaborate ones, for which a refusal could only answer with an empty
  list indistinguishable from "every assertion discriminates".
- **The fifth validator runs.** `/aimi:plan`'s Phase 4.5 loop ran four of the five
  `validate-*` verbs; `validate-waves` appeared nowhere in any command. Against a
  story depending on another in the same declared wave, all four report
  `valid: true` — only the fifth sees it. Its verdict is read from `.valid` and
  not from the exit status, deliberately and with the reason written beside the
  call: the verb always exits 0 by a contract the suite pins, so `|| exit 1` would
  have read the zero and waved the file through.


## [1.127.0] - 2026-09-04

Phase 3 of the pipeline audit: an executor no longer works against the wrong
tree, finished work no longer becomes a failure for want of a commit, a phase no
longer closes with a verification nobody judged, and the static analysis reaches
the files it had never scanned.

### Added

- **A `pending` partition in `verification-report`** — the ids of every story
  whose `verification.status` is the literal `pending`. It counts the literal and
  nothing else: a story carrying no `verification` object at all is absent rather
  than counted, because "declared and unlooked-at" and "never declared" are
  different states and a gate conflating them would refuse every legacy phase.
  Each `.visual[]` entry now carries its own `status` as well.
- **A refusal in `roadmap-set-status --status completed`** when that partition is
  non-empty, naming each story, and a second when a `verify-coverage` smell
  carries no `acknowledged` beside it. The rule it applies is narrower than the
  partition: only a story whose own `status` is `completed` can be asked for a
  verdict, because a verification judges work that was done. That is what keeps a
  cascade-skipped story — which the orchestrator produces automatically, leaving
  its verification pending — from wedging a phase that legitimately closes.
- **`WORKTREE_PATH=` and `WORKTREE_BASE=` sentinels** from `create_worktree`, on
  both the fresh and the reuse branch, with every human-readable line unchanged.
  The base is read from the worktree's own `HEAD` rather than from the `--from`
  argument, so it reports what the tree actually stands on. `from_branch` no
  longer defaults to the literal `main`.
- **`write-review`** — a phase's design review written atomically to
  `.aimi/reviews/<feature>-phase-<N>.md`, guard-protected like `handoff.md`, so
  it survives the session that produced it.
- **A writer for the worktree-manager pointer.** `write_global_worktree_cache`
  had been defined, validated, and called by nothing; the file on disk existed
  only because somebody wrote it by hand. It is now written by `check-version
  --fix`, `cleanup-versions` and `prime-cache`, and the 24 sites that read it
  check the path exists rather than only that the variable is non-empty — a
  dangling path is exactly what made one `merge-all` exit 0 having merged
  nothing.

### Changed

- **`verify-creates` anchors its textual search on word boundaries.** Without
  `-w`, the identity `baseRef` matched inside `--arg baseRefName` in a forge
  adapter and closed a phase on a field it had nothing to do with. A doc identity
  now keeps the meta-document exclusions (`README*`, `CHANGELOG*`, `CLAUDE.md`,
  `AGENTS.md`) instead of disabling the whole list, and a `method=text` verdict
  over one reports `unconfirmed` rather than `verified`.
- **The block analysis scans `skills/**/SKILL.md`.** Those files are executed
  exactly like a command file and had no static analysis at all; the scan finds
  56 blocks there where it found none.
- **`known_gap_entries` reads a `feature` declared in frontmatter**, with the
  filename slug kept as the fallback for the corpus that has none. Scoped reads
  went from 10 entries to 23 against the same corpus.
- **The completion report names what stayed open** — the pending partition, the
  review file's path, and creates that were found only by mention.

### Fixed

- **A story's uncommitted work is no longer discarded.** When the tree is dirty
  and every modified path is inside `implementation.files`, the orchestrator
  commits on the executor's behalf instead of marking the story failed and
  cascade-skipping its dependents. This was not hypothetical: it happened to a
  story in this very phase.
- **The worktree base is validated before an executor is spawned.** A missing
  sentinel, or a base that is neither the container's `HEAD` nor an ancestor of
  it, fails the story before any work is done rather than after.
- **Direct writes to `golden_from_jq.json` are refused by the hook.** The corpus
  is the evidence that the jq-to-Python port changed nothing; it may move by
  decision, never by accident.

## [1.126.0] - 2026-09-04

Phase 2 of the pipeline audit: every field a story carries now has both a writer
and a reader, what travels to an executor is what the executor uses, and a plan
that names a line number or a directory nobody can open says so at write time.

### Added

- **R16 in `validate_tasks`** — an `acceptanceCriteria` that anchors to
  `path.ext:N` draws one warning line per story, naming every anchor found. It
  warns and never errors: `errors` is what makes `validate-tasks` exit 1, and a
  line number is fragile rather than invalid, so promoting it would refuse plans
  that pass today. DesignSpec citations are excluded as part of the rule rather
  than as a refinement of it — `CITATION` already captures an `L([0-9]+)` group
  that the R2/R3/R4 walk binds and never reads, because a citation is validated
  by its literal against its section. The one anchor already answered for by
  content is exactly the one a naive matcher would fire on.
- **R17 in `validate_tasks`** — an `implementation.files` entry whose parent
  directory does not exist under the project root draws a warning. The parent is
  what is checked, never the file: a story whose whole job is to create a file is
  the ordinary case, and requiring the file would refuse every scaffolding story.
  `implementation` is read only once `jq_type` says `object`. It sits below R16
  for a measured reason — warnings are compared byte for byte by the golden
  corpus, so a rule inserted above R16 would reorder the stderr of any document
  tripping both, while one appended below can only add lines after the last
  already recorded.
- **`warn_list` in `roadmap.py`** — every verdict the file could reach was fatal,
  13 `_die_list` call sites and nothing else, so a non-fatal check had no channel
  to speak through. `warn_list` mirrors the pair `story_merge.py` already has
  rather than inventing a second shape, and `_die_list` now calls it and adds the
  exit, so the two cannot drift in how a diagnostic renders. All 13 fatal checks
  are untouched.
- **A missing-parent-directory advisory in `judge_phases`**, on both writers
  (`roadmap-init` and `roadmap-amend-phase`). It fires only on identities that are
  actually path-shaped: a bare verb name names no directory and is never judged, a
  `METHOD /path` route's slash belongs to the route, and a globbed parent names no
  one literal directory. The project root is the parent of the nearest `.aimi`
  ancestor of the roadmap path both writers already hold, walked lexically because
  a fresh `roadmap-init` runs before its own feature directory exists.
- **`metadata.baseRef` in `/aimi:plan`** — the full 40-character SHA from
  `git rev-parse HEAD`, read in the repository the file's stories target. A plan
  is written against one tree and nothing in the file said which one, so a base
  that had since moved was discovered mid-wave, by an executor, as a merge
  conflict. The key enters all four enumerations the command maintains, because a
  key named only in the first is silently dropped from every file a split run
  produces. On the PROJECT axis each file carries its own repository's SHA — one
  global value would be wrong for N-1 of them. A root that does not resolve omits
  the key entirely: an absent key reads as "written before this field existed",
  where `""` reads as a SHA.

### Changed

- **`get-story-context` projects `metadata`** onto the three keys a story
  executor actually reads — `designBundle`, `designTokens`, `prototypePaths` —
  derived by grepping the skill rather than from the schema's maximum. The whole
  object had been travelling, `metadata.decisions` included.
- **`implementation.approach` gained the reader it never had.** The field was
  written by the expander and read by nothing in the executor; both
  `<execution_flow>` blocks in the story-executor skill now carry it.

### Fixed

- **A story's `verify` could not exercise a verb the story itself added.**
  Resolving `AIMI_CLI` from `~/.config/aimi/cli-path` points at the deployed
  plugin copy, never the worktree, so a story changing a verb measured the old
  one. Documented in the expander's rules as a named rule.

## [1.125.0] - 2026-09-03

Three bodies of work that had accumulated unreleased on one branch. The thread
running through them: a check that runs, exits zero, and measures something
disconnected from what it claims is indistinguishable from a check that works.

### Added

- **`measure-command-file <path>`** — returns `{bytes, lines, prose_bytes,
  fence_bytes, bash_fence_bytes, fences, bash_fences}` for a command file,
  computed by the same fence parser `test-command-blocks.sh` already uses. There
  is still exactly one fence parser in the tree; the verb sums what it reports
  rather than parsing anything itself. A hand-rolled `awk` had been counting 45
  bash fences in `plan.md` where the shared parser counts 50.
- **`verify-probe <story-id>`** — splits a story's `implementation.verify` into
  top-level segments and runs each in isolation, reporting
  `{segment, exit, discriminates}`. Settings such as `set -euo pipefail` are
  skipped, being configuration rather than assertions. Most verifies open with
  `set -e`, so the script stops at its first failing assertion and every
  assertion after it never runs — meaning a verify that exits non-zero can still
  carry assertions that would have passed before a line was written. The
  script-level pre-run says nothing about those.
- **`list-known-gaps [--feature <slug>] [--since <date>]`** — reads
  `.aimi/known-gaps/`, the corpus every story executor writes and no plan had
  ever read back. It depends on no frontmatter: the files have none, and arrive
  in three shapes (`KNOWN-GAP:` prefixed, `KNOWN-GAP (US-NNN):` prefixed, and
  bare prose). A file whose feature cannot be resolved yields an entry with a
  null feature rather than being dropped.
- **`prior_planning_gaps` in `/aimi:plan`** — the gaps above are injected into
  the story expander's prompt as a sanitized DATA block, tag-escaped exactly as
  the existing `research_file` blocks are, and the expander gained a section
  saying what to do with them.
- **A `measure` block convention in the three research agents** — every
  repository figure now arrives with the shell command that produced it and that
  command's literal output; a figure with no block is marked `UNVERIFIED`.
  `/aimi:plan` Phase 1.6 re-executes each block and escalates a divergence
  through the conflict path that already existed. Because those blocks are
  executed against agent-authored text, `commands/references/sanitization.md`
  gained a normative read-only allowlist, matched on the leading word of every
  pipeline segment, with shell constructs that could smuggle a command past it
  refused as shapes before the allowlist is consulted.
- **The question every new gate must answer**, in
  `commands/references/context-budget.md`: does what this check measures bear on
  what it claims? It carries the four measured cases that motivated it, and
  documents the three distinct verification concepts (`acceptanceCriteria`,
  `implementation.verify`, `verification.strategy`) without renaming any field.
- **`test-command-size.sh`** — a per-file byte budget for `commands/**/*.md`,
  enforced as a ratchet in both directions: a listed file that grows past its
  budget fails, and one that shrinks below it fails too, so the commit that
  shrinks a file must lower its number in the same diff.
- **A pre-run of `implementation.verify`** in the story executor, before any
  work exists. A zero exit means the check cannot tell the before-state from the
  after-state; it warns and never blocks, because a story re-executed over
  partial work can legitimately pass that early run.

### Changed

- **The story executor runs `story.implementation.verify` as written**, from the
  working directory step 0c established, and a non-zero exit fails the story. It
  previously ran a hardcoded `npx tsc --noEmit`, which named a tool this
  repository does not have.
- **The story expander must make `verify` cover what the criteria assert.** A
  criterion naming a check the verify never runs is the defect this closes.
- **`/aimi:plan` requires the project's own typecheck**, rather than mandating
  the literal string `Typecheck passes` regardless of whether the project has
  such a command.
- **The canonical single-line CLI resolution form is auto-approved by the hook**,
  and `commands/references/cli-path-resolution.md` defines it once as Per-Call
  Resolution.

### Fixed

- **`story-merge` warns when a criterion asserts a check the verify never runs**
  (`verify-coverage`), reporting the story ids it could not determine separately
  from the ones it cleared.


## [1.124.0] - 2026-08-31

### Added

- **A normative rule for where new `commands/` instruction content belongs** —
  `plugins/aimi-engineering/commands/references/context-budget.md`. It
  classifies three shapes: a deterministic procedure (validation,
  sanitization, path confinement, shell orchestration) belongs in a
  `scripts/aimi-cli.sh` verb; a rare conditional judgment belongs in a
  lazily-read `commands/references/` file; an always-needed "does this
  apply?" decision belongs inline in the parent, or in a verb that returns a
  verdict. It states the rule that makes the lazy-reference shape actually
  pay for itself — the condition gating whether to open the reference must
  be cheap and already live in the parent, or the file is read every time
  regardless and the saving is zero — grounded against this repo's own
  history rather than asserted abstractly, and cites
  `plugins/aimi-engineering/CLAUDE.md`'s "What stays `jq`, and why" section
  as precedent for the same organising test applied to a different surface.
  `plugins/aimi-engineering/CLAUDE.md`'s Command Conventions section gains
  one pointer bullet at it, mirroring the existing Skill Conventions size
  bullet.

## [1.123.2] - 2026-08-31

### Fixed

- **`auto-approve-cli.sh` speaks the contract of the event it is registered
  on.** It is wired on `PreToolUse`/`Bash`, but from its first commit
  (`e3506c9`, 2026-02-26) it emitted `hookEventName: "PermissionRequest"` with a
  `decision: {behavior: "allow"}` object. `PermissionRequest` is a real hook
  event — other plugins register it as its own key — but this plugin registers
  it nowhere, and `PreToolUse` decides through
  `hookSpecificOutput.permissionDecision` (`allow|deny|ask`), which is also the
  shape `hook_utils.deny()` already emits for the sibling `PreToolUse` guards in
  the same directory. The hook therefore approved nothing for six months. The
  payload now names `PreToolUse` and carries `permissionDecision`.
- **The resolution patterns match the text the commands actually emit.** A
  second, independent defect, and on its own also enough to approve nothing. On
  2026-05-15 the Per-Call Resolution gained quoted paths and a
  `|| cat <legacy>` fallback (`018bf6e`) while the hook learned only the new
  cache path (`b4f5768`), not the new shape. Six families stopped matching: the
  Layer 0 guard, which grew from two conditions to five; the per-call cache read
  on both `AIMI_CLI` and `WORKTREE_MGR`; that read's `if [ -z ... ]`-wrapped
  variant, which no pattern could reach because it opens with `if` rather than
  an assignment; the Layer 2 cache write, which gained an `_aimi_cfg` temporary
  and an `mkdir -p`; and the `${VAR:?...}` fail-loud guard, which never had a
  pattern at all. Nothing is removed — every previously accepted spelling still
  matches — and the added patterns stay anchored and enumerate their accepted
  forms rather than widening. The fail-loud guard is matched as a full literal
  on purpose: the word in `${VAR:?word}` *is* expanded when the variable is
  unset, so admitting arbitrary text there would auto-approve command
  substitution.
- **`deepen.md` writes its resolution preamble on one line**, like the other
  130 sites. It was the only one split across three lines with backslash
  continuations, which an anchored single-line pattern cannot match however the
  hook is written.

### Added

- **`hooks/tests/test_auto_approve_cli.py`** — the hook had no coverage at all,
  which is why two defects sat in it undisturbed. Two of its cases carry the
  weight. `test_the_allow_payload_names_the_event_the_hook_is_registered_on`
  reads `hooks.json`, finds the event the script is wired to, and requires the
  emitted `hookEventName` and decision key to belong to that event — the check
  whose absence let a payload for the wrong event survive six months, since
  every test one could write about the script's stdout stays true no matter
  which event's shape that stdout belongs to. `test_every_resolution_line_in_
  commands_is_approved` derives its corpus from `commands/**/*.md` rather than
  carrying a copy of the current preamble, because a hardcoded fixture would
  drift alongside the hook, agree with it, and confirm nothing. Adversarial
  cases pin the narrowness the hook depends on: command substitution inside a
  `${VAR:?word}` word, reads and writes redirected outside the config
  directory, and trailing chained commands. Both defects are verified to be
  caught — restoring either one alone turns the suite red.

## [1.123.1] - 2026-08-28

One issue — #129 — closed by a one-character correction and the release that
carries it. PATCH rather than MINOR: nothing is added, no syntax changes, and
no field appears or disappears; a validator that disagreed with every other
component in the plugin now agrees with them. The thing worth knowing before
you upgrade is that `validate-waves` was not occasionally wrong — it was wrong
about every story of every file it was ever given, so a verdict that flips
from invalid to valid on this upgrade is the verb being repaired, not your
data changing.

### Fixed

- **`validate-waves` computed waves from 0 while `story-merge` writes them from 1, so it reported a mismatch on every story of every tasks file for its entire existence.** `computed_waves` in `tasks.py` seeded a story with no dependencies at wave 0, while `compute_waves` in `story_merge.py` — the component that *writes* the field — seeds it at 1. The two never agreed, so every story in every file the planner produced came back off by exactly one. Concretely: the tasks file behind the previous release reported eight mismatches, `US-001 stored=1 computed=0` through `US-008 stored=2 computed=1`, every one off by one; it now reports `valid: true` with no errors. **If a file the verb used to call invalid now passes, nothing changed in your data** — the verb was previously wrong about every file it was handed, correct ones included.
- **The validator is the side that was corrected, and that was not a coin flip.** Four components already stated the 1-based convention, against `tasks.py` alone: `story_merge.py`'s `compute_waves`, the writer; `commands/plan.md`'s schema, which defines the field as "computed from dependsOn: roots=1, others=max(dep waves)+1" and repeats "wave 1 for roots" in two further checklist lines; and `commands/execute.md`, which starts its displayed wave numbering at 1 and prints it as `--- Wave [n] ---`. Correcting the writer instead would have invalidated every `tasks.json` already on disk and left the stored field disagreeing with the number you read on screen. The change is one seed value — `current[story_id] = 0` becoming `= 1`. The n-pass reduce, the increment and the mismatch predicate are all untouched, so a story inside a dependency cycle is still assigned no wave at all and a dangling `dependsOn` still hides its own story's wave errors; reporting those remains `validate-deps`' job.
- **Why this went unnoticed for the field's whole life: the failure was reported into a channel nothing branches on.** Nothing but `validate-waves` itself reads the stored `wave` field — `story-merge` writes it, `plan.md` documents it, and `execute.md` counts its own wave loop rather than reading it — so a wrong value corrupted no behavior anywhere. And `validate-waves` **always exits 0**, invalid verdict included: the verdict lives in `.valid` in its JSON output, so anything checking exit status saw success on every run. That exit status is unchanged here, deliberately, and a test still pins it against a wave-mismatch fixture. This release changes which verdict the verb computes, never how it reports one.
- **`tests/golden_from_jq.json` moved, which it normally must not, and the reason is that the disagreement predates the Python port.** That corpus was captured from the jq implementations before they were deleted and is the evidence the port changed nothing, so it is frozen except for the single carve-out `CLAUDE.md` names — a genuine rule change, recorded in the same commit with the reason in the message. This is that case: both sides are faithful ports, the jq behind `tasks.py` already disagreed with the jq behind `story_merge.py`, so the 0-based answers recorded there were the jq's own and the port reproduced them correctly. Only the `tasks_validate_cases` block moved. Of its 82 recorded `validate-waves` cases, 63 were re-recorded, 6 came back byte-identical (every one a document in which no story is ever assigned a wave) and 13 are engine-abort recordings already excused by name, which never depended on the convention. Across all 82 only `stdout` differs — `input`, `exit`, `stderr` and `state_after` are byte-identical — and each of the 63 was re-recorded by replaying its own stored input through the CLI, never regenerated from the Python. Every other block in the file is untouched, and the block's own comment gained its reason as an append, keeping the existing text as a byte-for-byte prefix. Six new pytest cases pin the convention directly rather than through a recording, and all six fail against the 0-based seed. Issue #129.

## [1.123.0] - 2026-08-27

Two issues — #126 and #127 — closed by six of the seven stories landed on one
branch. The seventh rides along under *Fixed* and belongs to neither: the
merge step ate one of its own staging files while this very branch was being
planned, so that bug was found by being hit rather than by being reported.
The foundation-gate work is what makes this a MINOR rather than a PATCH: a
repository in a multi-repo layout that previously got no architecture proposal
at all now gets one. Issue #127 on its own would have been a PATCH.

### Added

- **The Greenfield Foundation Gate now runs once per discovered child repository in a multi-repo layout, where it previously declined the layout outright.** `/aimi:plan`'s Phase 1.9 used to carry a single-repo layout as a fire condition and skip with a message saying per-repo foundations were unsupported. It now derives a set of **foundation roots** — the single `.` root of a single-repo layout, or one root per child repository the Phase 0 auto-scan already discovered, each key validated against the same path-safety regex Phase 4 applies to a `.project` value — and evaluates the greenfield/brownfield conditions per root. Each firing root gets **its own architecture proposal file, its own Accept/Adjust/Skip gate, and its own verdict**, recorded under a new `foundation:<topicSlug>:<repoSlug>` anchor, so a backend repo needing scaffolding and a frontend repo needing its existing conventions captured no longer share one answer. An unreadable proposal file drops only its own root from the set, as if that root's gate had resolved to Skip, with one warning line naming it; the remaining roots still get their entries.

  Each accepted root's proposal then threads through the rest of the pipeline on its own. **Phase 3b** emits one foundation outline entry per accepting repository, in foundation-roots order, each carrying a new `foundationProject` field naming its own routing key, with non-foundation entries numbered after them. **Phase 3c** protects every entry whose own `foundationEntry` field is true — identified by the field, never by position — so a Remove, a displacing Add, or a Reorder that does not keep those entries first is rejected; the rejection message is today's wording verbatim when one repository accepted, and names the disturbed repositories when two or more did. **Phase 3d** hands each spawned story the proposal block belonging to *its* repository, and an entry whose repository has no accepted proposal gets no proposal block at all rather than a sibling's (the 50 KB cap is per proposal and never pooled, so a small proposal is not truncated because a large one exists elsewhere). **Phase 3e** emits one `--foundation` flag per accepted root, reading each index off its own entry instead of assuming `01`. **Phase 4** registers every accepted proposal in `metadata.researchPaths`, so `research-gc`'s orphan sweep protects all of them rather than one.

  **`--foundation` becomes repeatable, and injects only within each foundation's own project group.** It previously pointed every story in every repository at one shared outline index, so on a multi-repo plan repo A's foundation was silently wired into repo B's stories and then dropped again by the per-repo split. A bare `<idx>` is still accepted whenever it is the sole occurrence, whatever project it resolves to; two or more values each require the qualified `<project>:<idx>` form, because a bare value alongside another names no project. The qualifier is a checksum rather than a second source of truth — routing always comes from the resolved story's own `.project`, and a stated project that disagrees refuses the merge before any write, which is the one `plan.md`/`story-merge` divergence nothing else in the pipeline catches. Legacy single-group merges are unaffected by construction, not by a special case: when every story shares one group, "inject only within your own group" reduces to the previous behaviour exactly.

  **One diagnostic inverts its meaning rather than disappearing.** `droppedDeps[].foundationEdge` used to rest on the premise that the foundation lives in exactly one group, so every other group loses that edge. Per-group injection makes that false, and since an injected edge can never leave its own group it can never be dropped — so every `true` reading from here on is necessarily a **hand-authored** dependency reaching into another group's foundation, which is what one repository resolving Accept while a sibling resolves Skip produces. The comment, the per-story message and the stderr note all say so now.

  **Single-repo runs are unchanged by construction, not by promise.** Every chat and log line the `.` root emits is byte-identical, its two glob patterns are unchanged, its spawn prompt omits the new per-repo input entirely, and a single-root collapse after the loop copies that root's values back onto the four original scalar working-memory names that every downstream consumer still reads. On a multi-root run those scalars are deliberately left unset — a scalar carrying one repository's verdict reads downstream as the verdict for the whole run — and the per-root maps are what the consumers read instead. The multi-root advisory line now reports the evaluated and accepted counts and stops there; it previously told the user "foundation stories are not generated for them yet", which became the opposite of what happens once both halves landed. Issue #126.

  **Know what tests this and what does not.** The per-repo gate is **prose logic inside `commands/plan.md`** — instructions an agent follows, not code a suite executes. `test-command-blocks.sh` checks only that the file's bash-fenced blocks parse and stay portable, and this change adds no new bash fence; **it cannot verify the gate's semantics**, and nothing else in the tree can either. The parts that are code — `story_merge.py`'s per-group injection, the flag grammar and its four refusals — are covered by `pytest` and by `test-aimi-cli.sh`, whose `EXPECTED_ASSERTIONS` rose by 23 for them.

### Fixed

- **`worktree-manager.sh` no longer writes an untracked `.gitignore` into a container, which used to abort the next `merge-all` before the merge began.** `GIT_ROOT` is resolved once at script load from `git rev-parse --show-toplevel`, so `create` running with its CWD inside a container — which container and phase mode both do by contract — resolved *that container's* own top level rather than the real repository root, and `ensure_gitignore` appended an untracked `.gitignore` there. A foundation story that later committed its own `.gitignore` then collided with the leftover file. `ensure_gitignore` now detects the linked worktree **structurally**, comparing `git rev-parse --git-dir` against `--git-common-dir` — a linked worktree keeps its own per-worktree git dir under the shared common dir — and warns on stderr instead of writing. Both answers are made absolute before the comparison and matched with `-ef`, because git returns them in mixed relative and absolute forms depending on the working directory, and a raw string compare would fire the guard on an ordinary repository and disable the append path entirely. The discriminator is deliberately structural rather than a `/.worktrees/` path-substring test, which would break the moment that directory is renamed. **What changes for you:** an untracked file left inside a container is now treated as the merge blocker it is, instead of being silently created on your behalf; the warning tells you to add `.worktrees` to the real repository's `.gitignore` and commit it. The true repository root's three existing branches — write when untracked, write when tracked and already dirty, warn when tracked and clean — are untouched, wording included. Issue #127.
- **Both merge paths now print git's own reason when a merge aborts before it starts, instead of a "Conflicting files:" heading above nothing.** `git diff --name-only --diff-filter=U` lists only files with unmerged *index* entries, and a pre-merge abort — an untracked file that would be overwritten, or a local change to a tracked file the incoming branch also touches — creates none at all, so the report was empty and named nothing. Both reporting sites, `merge_worktree` (behind `merge`) and `merge_all_worktrees`' per-branch loop (behind `merge-all`), now give `git merge` a per-call temporary file on its stderr and print that text when the unmerged list is empty. stdout stays unredirected, so a real content conflict still prints live exactly as before, and the conflicting-files listing is unchanged whenever the list is non-empty; a warning on a merge that *succeeds* is no longer swallowed either. The temporary file is removed on every exit path of both functions. Issue #127.
- **`story-merge` no longer silently discards a story file whose name merely contains the word "outline".** `is_sidecar` dropped any `.json` whose basename *contained* that substring — which is exactly the word a story about outline entries gets named after. Planning this very feature wrote `05-n-foundation-outline-entries.json`, the filter ate it, six files loaded instead of seven, and because `outline:NN` is a **position** in the merged array rather than a filename prefix, every later position shifted by one and two stories ended up depending on themselves. What the run printed was `Error: story-merge: circular dependency detected among stories: US-005, US-006` — a message naming no missing file, no skipped filename and no filter, sending the reader hunting for a cycle that existed in no staging file. **The predicate is now a suffix**: a sidecar is one of the three exact sidecar names, or a basename ending in `-outline.json`. The word may therefore appear anywhere in a story's name, and only a file whose name *ends* that way is claiming to be an outline. The substring arm was narrowed rather than removed, because an exact-name-only rule would have moved a verdict already frozen in `golden_from_jq.json` — a recorded case that skips `topic-outline.json`, which no exact name covers. This particular fix leaves that corpus byte-identical. (The `--foundation` change above does move exactly one case in it, `proj-fundacao-edge`, because the rule that case records genuinely changed; it was re-recorded by replaying the case's own stored input, never regenerated from the Python.) **And the skip is no longer silent** — a skipped file carrying a leading story index now names itself on stderr and says to rename it if it is a story. That scope is deliberate rather than partial: only a numbered file occupies a position, so only a numbered file can shift every later `outline:NN` and manufacture the cycle that gets reported in place of the skip, while the exact sidecar names and a plain `<topic>-outline.json` are written beside the stories on every ordinary plan run and announcing those would be noise on every merge. An ordinary merge is unchanged on stdout and stderr alike.
- **`ensure_gitignore` and the merge-all reporting branch had no test coverage at all, so the two fixes above would have shipped unguarded.** `test-worktree-manager.sh` grows from 27 to 59 assertions across two new sections, reaching all four of `ensure_gitignore`'s outcomes through `create`, its only caller, and reproducing the reported container scenario end to end. One case exists specifically for the relative/absolute normalization inside the linked-worktree discriminator, and asserts the underlying property in a form no git version can invalidate. Discrimination is checked rather than claimed: against the pre-fix script the suite reports 51 passed and 8 failed, and those eight are exactly the linked-worktree skip and the two reporting behaviours. The suite stays serial-only and outside `test-aimi-cli.sh`'s `PARTS` array, so no `EXPECTED_ASSERTIONS` moved for it.

## [1.122.0] - 2026-08-26

Four issues, closed by seven stories landed on one branch: #125, #121, #103,
and #108. Three carry behavior an operator will notice on upgrade; the other
two are internal fixes with no visible surface, folded in briefly under
*Fixed* rather than given their own heading.

### Added

- **`forge-pr-merge` is a new normalized write verb, implemented across GitHub, GitLab, and Gitea** — `aimi-cli.sh forge-pr-merge --pr <branch-or-number> --style <merge|squash|rebase> [--project <path>]` — so a PR or MR merges through the same write envelope and degradation contract every other `forge-*` write verb already uses, instead of a caller shelling `gh`/`glab`/`tea` directly. It resolves the PR/MR's `{number, url, state}` via an in-process `forge-pr-view` preflight before ever attempting a merge: an already-merged PR, or GitLab's lock-protected state, short-circuits to `unchanged` with no merge attempted; a closed-but-never-merged one degrades before any merge call runs; only an open PR/MR proceeds. Merge style is explicit and required, validated against a closed three-value enum (`merge`, `squash`, `rebase`) — Gitea's own fourth `rebase-merge` style is deliberately not exposed, since neither GitHub nor GitLab has an analogue, and no conditional/auto-merge or branch-deletion flag exists on any forge, which is what keeps the three forges normalizable. Issue #108.
- **`/aimi:open-pr` gains a `--merge` flag, and `commands/references/publish-confirmation.md` now enumerates publishing as three acts instead of two** — push, open a PR, and merge a PR on the forge — with merging named as the most consequential of the three. `--merge` is scoped to an already-existing pull request only: it is a no-op (with one informational line) when no PR exists yet, since auto-merging a PR the same invocation just opened would bypass the review a pull request exists to collect. It sits behind the same confirm-before-publish gate the push and PR-create acts already use: interactively it combines the merge-style choice with the approval in one question, with a trailing decline option; in agent mode the merge is always declined — no flag re-enables it — while the push and PR-create acts this command already performs unconditionally are untouched. Issue #108.
- **A new, always-on one-line classification summary now prints on every `/aimi:plan` and `/aimi:brainstorm` run**, carrying each gate's verdict as `fired`/`skipped`/`not-run` — three tokens rather than two, so a gate whose entry guard short-circuited reads differently from one that evaluated and declined. The five existing `AIMI_PLAN_DEBUG`/`AIMI_BRAINSTORM_DEBUG` debug lines are unchanged and remain opt-in; no existing line was re-gated. This closes the rest of what Issue #103 left open in 1.121.0: recovering a gate's verdict no longer needs a re-run with a debug variable set, since the summary line is on the ordinary transcript by default.

### Changed

- **A non-empty `unresolved[]` left by the Phase 3d.5 cross-story auditor now stops the `/aimi:plan` pipeline as a decision point, instead of being reported as a Step 5 bullet and walked past.** A new Phase 3d.5 Unresolved Gate fires once the full-run list has finished accumulating. Interactively it presents one question covering the whole list at once — never a per-item loop — with three options: apply anyway (proceeds to story-merge, records one decision entry per item), defer with reason (annotates every resolvable story's notes field with the same marker vocabulary the scope-pruning gates already use, plus one decision entry per item), or abort (stops before story-merge, nothing written this run). **Agent mode never blocks**: it auto-selects defer with reason using a fixed system-authored reason, applying the identical story annotation and decision recording, so a deferral is never left only in the transcript. The same story widened the cross-story patch allowlist from three fields to six (`acceptanceCriteria`, `implementation.approach`, and `gate.prompt` join `dependsOn`/`tasks`/`notes`), each field newly eligible for `replace` in addition to `add`, so a detected contradiction in those fields can now be corrected instead of only annotated. Issue #121.
- **Every `tasks.json` verb that resolves a path through the global `current-tasks` pointer now either honors an explicit `--tasks-file` or refuses it outright — it no longer silently answers from, or mutates, the wrong file.** 21 verbs honor the flag: `status`, `metadata`, `list-ready`, `count-pending`, `validate-deps`, `validate-stories`, `validate-ids`, `validate-waves`, `validate-tasks`, `get-story`, `get-story-context`, `mark-in-progress`, `mark-complete`, `mark-failed`, `mark-skipped`, `cascade-skip`, `gate-pass`, `gate-fail`, `update-field`, `reset-orphaned`, and `set-execution-mode`. `current-story` and `get-branch` refuse the flag with a non-zero exit instead, since their answer comes from session state and a tasks file is only a secondary lookup keyed by that state. Measured migration impact is nil — every existing caller already targeted one of the two verbs that honored the flag before this release — but the fix closes a real hazard: two concurrent orchestrators calling `init-session --file` with different paths in the same turn used to leave the last one to call it owning every subsequent verb call that fell through to the shared pointer. Issue #125.

### Fixed

- **Two internal fixes land in this release with no operator-visible surface**, closing out the rest of Issue #125's split-execution scope. `/aimi:execute`'s split flow now threads each orchestrator's own resolved tasks-file path directly through Step 3's precondition calls and Step 4's wave-execution loop, rather than relying on the shared `current-tasks` pointer the fix above still writes but nothing on this path still reads. `skills/story-executor/SKILL.md` carries the same resolved path into every spawned story executor's own `get-story-context` call, so a worker spawned by either sibling split orchestrator resolves its own file regardless of which orchestrator last wrote the shared pointer.

## [1.121.0] - 2026-08-21

Seven issues, reproduced and remediated independently rather than routed
through a roadmap — one scope context, no phases, per this branch's own
collapse-rule decision. Three touch behaviour an operator will notice on
upgrade; the rest correct what a message says without changing when it fires.

### Changed

- **The story executor now enters a monorepo story's own project directory, where it previously stopped at the repository root.** `worktree-manager.sh` creates every worktree under `$(git rev-parse --show-toplevel)/.worktrees`, so a worktree sits beside the *repository* root — the same place as the story's `project` only when that project is itself a repository. For a sibling-repo layout it is; for a monorepo subdirectory it is not, and the executor was landing one or more levels above the project it was given. A story whose `implementation.verify` was written for its own project — a bare `bun run typecheck` — therefore failed for want of a `package.json` that was one directory down. `skills/story-executor/SKILL.md` step 0 now resolves the project's own toplevel and descends into the project inside the worktree when the two differ. **A `verify` must not carry a `cd <project> &&` prefix**: by the time it runs the executor is already there, so the prefix resolves to `<project>/<project>`. Issue #105.

- **A phase whose stories are all completed-or-skipped now reads has-work `false` and is demoted in `roadmap-claim`'s auto ranking, the same way a fully-completed phase already was.** `ground_truth` had no branch for this shape and fell through to `in_progress` — a completed phase carrying one deliberately skipped story got un-completed on every reconcile, and a phase nobody had touched yet read as though execution was mid-flight on it. Two branches close it: every story completed-or-skipped now resolves to `completed`, every story still pending now resolves to `planned`. A bare `/aimi:execute` may claim a different phase than it would have before upgrading. Issue #102's own "not affected" analysis of `has_work_map` predates the skipped branch and does not cover this case. `split-detect`'s own copy of the same terminal-status rule is widened to match, so a split phase whose remaining stories were all deliberately skipped stops drawing a worktree, a branch and a spawned Task on every run — without that, #112 would have been fixed for a non-split phase only. And `roadmap-reconcile` refuses to demote a phase that is already `in_progress`, reporting it under `blocked` instead: `STATUS_TRANSITIONS` has no `planned -> completed` edge, so demoting a phase mid-claim would strand its owning session at Mark Phase Completed after every story had already run. Issues #102, #112.
- **`detect-parent-branch` can now answer `source: "ambiguous-decoration"` with `verified: false` and a `candidates` array, where it previously answered `verified: true` while being wrong.** The walk took the first decoration candidate that verified via `git merge-base` and reported it as the winner, even when a second candidate verified against the exact same commit — confidently wrong on a real topology, an integration branch and the default branch sitting on one un-diverged commit, where walk order alone decided which name "won". This corrects a regression commit `4384273` introduced. **A caller that branched on the boolean should revisit it.** `open-pr.md`, the sole in-tree consumer, now reads the new `source` value and names the tied candidates in its warning instead of folding ambiguity into the generic "could not verify" case. Issue #87 (direction 2).
- **Version call — MINOR, not MAJOR, argued from both manifests read live and confirmed to agree at `1.120.0` before any edit.** New CLI behaviour ships that a caller could not invoke before — `detect-parent-branch`'s `ambiguous-decoration` answer, and `roadmap.json`'s new `integrationBranch` field below — which excludes PATCH. This repository reserves MAJOR for the one-time, repo-wide `tasks.json` schema rewrite; No breaking change ships here: the one candidate — a `validate-stories` rejection of a `verify` without a `cd <project> &&` prefix — was withdrawn before release, because the executor already enters the project and the prefix was the defect rather than the fix. Every existing `tasks.json` that validated before this release still validates.

### Added

- **`roadmap.json` gains an optional top-level `integrationBranch`, the branch a roadmap declares its phases should target.** `detect-parent-branch` cannot resolve this on its own — a freshly cut integration branch is the same commit as the branch it was cut from until the first phase merges, so `git merge-base` and the decoration walk see one indistinguishable pair, and every roadmap's first phase starts in exactly that ambiguity. The value is a property of the feature, not the graph, declared by whoever set the roadmap up: writable at materialization via `roadmap-init --integration-branch`, or added by hand to a roadmap that predates it. `open-pr.md`'s Step 2b now prefers a declared value outright over inference, composing with the ambiguity report above rather than competing with it. An additive `roadmap-init --sync` only preserves the field — it is never the writer of a fresh value, so re-syncing cannot overwrite a branch someone declared by hand; the same change widens `--sync`'s key whitelist from four entries to five, since a key absent from that whitelist was silently erased on every additive sync, which would otherwise have erased this one on first use. No `roadmapVersion` bump: the field is optional and its absence is never an error, so every roadmap already on disk stays valid. Issue #87 (direction 1).

### Fixed

- **Four rules that were duplicated now have one owner, and two stale claims are corrected.** None of these changed behaviour a user can see; they change the shape that produced the behaviour defects above.
  - **`TERMINAL_STORY_STATUSES`** — "a story is finished iff `completed` or `skipped`" decided three questions in three places and they disagreed, which is how issue #112 stayed open for split phases after being closed everywhere else. `roadmap.py` names the pair; `tasks.py` imports it. It lives there rather than in `tasks.py`, where a story rule belongs, only because `tasks.py` already imports FROM `roadmap.py` and the reverse closes a cycle — the comment says so. `split-detect` is jq and can import nothing, so it keeps a third copy with a pointer to the normative home, and a test asserts that copy from its source text.
  - **`roadmap-init --sync` preserves every top-level key it did not come to change**, instead of rebuilding the document from an allowlist of five. That allowlist erased `integrationBranch` on its first use, and a list of permitted names is structurally unable to know about a key added by hand — the route issue #87 direction 1 documents for that field. It was also the only writer of `roadmap.json` doing this; the other six mutate in place and always preserved unknown keys.
  - **`/aimi:plan` no longer parses an `integrationBranch:` key out of brainstorm frontmatter.** Nothing in the plugin ever wrote that key, so it was a parser with no producer — and the value reached an executed bash line through a model-substituted placeholder, carrying LLM-authored text with sanitization guaranteed only by prose. `roadmap-init --integration-branch` still exists as a human affordance, in the same shape `roadmap-amend-phase` is; hand-editing `roadmap.json` remains the supported route.
  - **`BRANCH_REGEX` is applied with `fullmatch`**, not `search`. Python's `$` also matches before a trailing newline, so `"main\n"` passed at all four sites. Not exploitable — command substitution strips it before git sees it — but two of the four guard `integrationBranch`, which arrives from a CLI flag with no sanitizer in front of it.
  - **`CLAUDE.md` named the wrong test part as the suite's bound.** It said part 3 is ~40-46% of the serial total; four independent runs put part 4 ahead in every one (~40% vs ~33% on `main`'s numbers). The sentence carried no as-of marker, which is how it outlived the tree it described; it has one now.

- **The protected-branch denial from the guard hook now names the resolved directory, not only the branch.** The guard already computed the effective working directory — parsed out of a leading `cd <path> &&` in the command string — before resolving the branch, but the message only ever named the branch, so an agent that lost a `cd` into a container or a worktree saw a message indistinguishable from genuinely being on the default branch. No change to when the guard fires, only to what it says. Issue #86.
- **`/aimi:plan` and `/aimi:deepen` no longer recommend `/aimi:review` in their verbatim Next-steps block.** There is no code to review immediately after either command — no implementation exists yet at that point — so the stale recommendation read as an assertion the agent appeared to vouch for, with no signal to the user that it was never evaluated. Every other verbatim-reproduced Next-steps block in `commands/` was audited for the same class of misrecommendation; `brainstorm.md`'s is the only other one under a "copy verbatim" instruction, and its own items are all runnable at that point. Issue #120.
- **`plan.md` and `agents/workflow/aimi-story-expander.md` now tell a story author the opposite of what they briefly said: write `implementation.verify` bare, with no `cd <project> &&` prefix.** Five parallel story-expander agents had answered the same unasked question five different ways, because the story-shape block's placeholder never said which directory `verify` runs from. The answer is that the executor has already entered the project — see the Changed entry above — so the prefix is not merely unnecessary, it breaks the command. Issue #105.

- **Three scope/roadmap decision points that emitted nothing on either branch now log a debug line naming which branch fired, behind the existing `AIMI_PLAN_DEBUG`/`AIMI_BRAINSTORM_DEBUG` opt-in variables:** `brainstorm.md`'s Phase 3.5 Step 1 scope-context trigger check, `plan.md`'s Roadmap Materialization phases-key check, and `plan.md`'s Scope-Context Classification inline fallback. Each line reports the scope-context (or phase-entry) count that drove the verdict, so a genuine one-context feature reads differently from a classifier that found none. **This only partly closes issue #103.** Its own argument is that a classifier's verdict must be recoverable from an ordinary transcript; these lines are gated behind opt-in variables, so recovering a verdict still needs a re-run with the variable set, not a read of the default transcript, which stays byte-for-byte silent. Issue #103's own five-site list was also partly stale: two of its five sites were already covered by the existing debug line at `brainstorm.md:1111`, so only the three named above needed a new one.

## [1.120.0] - 2026-08-13

> One release, developed across ten internal version numbers on a single feature
> branch. It carries two bodies of work that arrived in that order: a **forge
> abstraction** that puts GitHub, GitLab and Gitea/Forgejo behind one normalized
> verb contract, and a **document-logic port** that moved `roadmap.json`,
> `tasks.json`, `models.json` and `story-merge`'s rules out of Bash and `jq`
> into Python modules beside the CLI.
>
> **Why one version and not ten.** The branch cut ten numbers — 1.120.0 through
> 1.126.0 — and **none of them was ever published**. `main` goes straight from
> 1.119.3 to this release, the repository carries no git tags, and no consumer
> ever saw an intermediate number. Ten headings for work that ships in one merge
> is noise, so each internal release is kept below as a subsection, verbatim,
> rather than as a separate entry. Every argument those entries made about their
> own level — including the ones that argued for PATCH — is preserved as written,
> and is now historical: the level that applies to a reader upgrading from
> 1.119.3 is the one argued here.
>
> **Read `#### Breaking` and `#### Migration` under *1.121.2* before upgrading,
> whatever else you skip.** A `creates`/`needs` entry became two fields,
> `{identity, description}`, and a roadmap already on disk is refused by every
> contract-reading verb until it is migrated once. The whole action is one
> command per roadmap: `aimi-cli.sh normalize-contracts --feature <slug>`.
> Nothing else in this release requires migrating anything.
>
> **`python3` is a runtime requirement now, and on OpenCode that is new.** It
> widened three times across the branch — onto the roadmap verbs, then the
> per-story `tasks.json` verbs every spawned executor runs, then the
> `models.json` surface and one `/aimi:review` path. Claude Code is unaffected:
> its hooks already spawned `python3` on every Bash call, so the interpreter was
> always a harder requirement there than the CLI itself. On OpenCode the install
> still succeeds and the requirement surfaces at **first use of a verb**, not at
> install — `install.sh` copies `scripts/` wholesale and has no dependency
> preflight. The four verbs that *locate* the CLI (`version`, `check-version`,
> `cleanup-versions`, `prime-cache`) deliberately did not cross, so finding
> `aimi-cli.sh` never depends on a module living in the directory being found.
>
> **Two output shapes start appearing for the first time**, which is a
> compatibility event rather than a repair: `check-version`'s
> `{"status":"unknown",…}` and `cleanup-versions`' `{"removed":0,"kept":null}`
> were documented but unreachable — both verbs aborted above their own handlers.
> A caller that read "the verb aborts" as its no-plugin signal now receives
> exit 0 and a JSON object. Read `status`, not the exit code alone.
>
> **The destructive one, if you read nothing else under *Fixed*.**
> `cleanup-versions` was deleting the **newest** installed version and reporting
> success — it resolved "latest" with a lexicographic sort, and `1.121.3`
> collates before `1.9.0`. On a cache holding both it removed 1.123.0, kept
> 1.9.0, wrote the older path into the global cache, and printed something that
> reads like success. Every session afterwards ran the older CLI. It destroyed
> plugin files rather than your work, but it silently reverted an upgrade you
> performed, with no message anywhere saying so.
>
> **Why MINOR and not MAJOR.** By the plugin's own table — MAJOR for breaking
> changes to command syntax or output format — no command's syntax moved and no
> output field was removed, renamed or repositioned. The `#### Breaking`
> subsection under *1.121.2* is the closest call and is disclosed above rather
> than argued away: a stored document its own reader refuses until a migration
> runs is the shape a reader expects a louder number for. The level stays MINOR
> because the refusal is loud, names itself, and prints the one command that
> fixes it — and because the `forge-*` envelope reshapes under *1.121.0* touch
> only verbs that did not exist in 1.119.3, so no published upgrade path ever
> carried those shapes.
>
> **Why MINOR and not PATCH.** Six new verb families ship here that a caller can
> invoke and could not before, and three separate widenings of the `python3`
> requirement change what a host must have installed. A bug-fix number would
> tell that reader nothing changed for them.

### After the branch — the SessionStart hook primes Layer 1, so a directory-source install is self-locating rather than merely locatable

Four stories, and the tail of the same path-resolution thread as the section
below — GitHub issues #113 and #118. That work made a directory-source install
*locatable* and left exactly one manual step between locatable and
self-locating. The step is gone, and it was removed from outside the four
resolution layers rather than by adding a fifth.

#### Fixed

- **A directory-source install now primes its own Layer 1 cache at session start, so the first `/aimi:*` command on a fresh host resolves.** `prime-cache` writes `~/.config/aimi/cli-path`, and on a `"source": "directory"` host nothing ran it: Layer 0 is gated off whenever `CLAUDECODE` is set, Layer 2's glob has no cache copy to match, Layer 3's `.aimi/cli-path` is created by nobody, and `/aimi:init` cannot self-heal because its own Step 0 needs `$AIMI_CLI` resolved before it can call `prime-cache` at all. A person had to run the CLI once by absolute path. `_heal_cli_path_cache()` in `hooks/inspect-session.py` now does it instead: `hooks/hooks.json` already registers that module on `SessionStart`, and the healing is the first thing it runs. GitHub issues #113 and #118.
  - **The measured precondition the whole approach rests on: `CLAUDE_PLUGIN_ROOT` is present in the hook process's own environment.** That is how a hook knows where the plugin is when all four resolution layers cannot. Measured with a temporary probe added to `hooks/auto-approve-cli.sh` and reverted afterwards; the value it printed matched a working `~/.config/aimi/cli-path` byte for byte. **This does not overturn the refutation recorded in the section below — that one measured a different process.** `CLAUDE_PLUGIN_ROOT` is still unset in the Bash-tool environment, which is where the resolution snippets execute, so a Layer 0b keyed on it would still never fire. Both measurements are true, and the gap between the two processes is precisely what the hook route exploits.
  - **The cheap Layer 1 read is a gate, not an optimisation.** A `prime-cache` spawn measured **299 ms** against that module's own **500 ms** budget (`_BUDGET_SECS = 0.5`), while the Layer 1 read plus its own check measured **0.025 ms**. Spawning unconditionally would charge roughly 60% of the session-start budget to every host that needs nothing, so the read decides and only a cache that is absent, or that names something other than this install's own CLI, reaches the subprocess. **That comparison is by identity, not by "is the cached path executable"** — under `CLAUDECODE` the CLI's own reader accepts exactly two cached paths, the versioned cache glob or today's directory-source path by exact equality, and for the running install both of those *are* `$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh`, so one string comparison admits precisely what the reader admits while re-deriving none of its arms. An executable-only test was strictly weaker and let the one state this hook exists to repair slip past: a hand-written `*/.worktrees/*` entry, which `write_global_cli_cache` refuses to write and the reader then refuses to read, is a real executable, so the gate called that session healthy and left it unable to resolve the CLI at all. A stale entry from an install since removed fails identically and is covered by the same comparison; both are asserted. The same constant bounds the spawn (`_HEAL_TIMEOUT_SECS = _BUDGET_SECS`), so a wedged CLI cannot stall session start indefinitely.
  - **It reimplements none of `prime-cache`'s rules, and it never raises.** Confinement, atomicity and the 0600 mode of the write all stay in the verb; the hook invokes the verb rather than re-deriving them, which is the whole point of the shape. A missing `CLAUDE_PLUGIN_ROOT`, a plugin root with no executable `scripts/aimi-cli.sh`, an unreadable config dir, a non-zero exit and a timeout each leave the session exactly as they found it. It runs **before** the quiet-mode exit deliberately — quiet mode suppresses the banner, not the plugin's ability to locate itself, and placed after that point every quiet session would stay unhealed — and outside `t_start`'s window, so the banner's two elapsed checks keep bounding exactly the work they were written to bound.
  - **Ten tests, one per branch, and the two that matter are asserted by observation rather than by outcome.** The hooks suite goes 285 → 295 and this module 11 → 21. Whether a subprocess starts is asserted against a patched `subprocess.run`'s `call_count`, never against the state of the cache file, because `prime-cache` answers `already_current` and writes nothing when Layer 1 already resolves — so an unconditional spawn leaves that file byte-identical to an inert step, and an outcome-only assertion would pass against the precise regression these tests exist to catch. Discrimination is measured rather than claimed: neutralising the gate so the spawn always runs fails **exactly one** test, the `call_count == 0` assertion, verified twice independently. `prime-cache` is stubbed as a real shell script rather than mocked, because argv, the exit status and the timeout are the contract and a mock reproduces none of them.
  - **A new Layer 2b was the route rejected, and issue #115 in this same release is why.** A fifth layer's command text would need a byte-identical mirror across eight files — `commands/references/cli-path-resolution.md`, `hooks/auto-approve-cli.sh`, the `--help` EXAMPLES block in `aimi-cli.sh`, `skills/resolve-pr-parallel/scripts/_resolve-cli.sh`, `commands/review.md`, `commands/validate-bug.md`, the top-level `CLAUDE.md`, and three test suites — because `auto-approve-cli.sh` matches the documented command text *literally*, and one character of drift turns every Layer 2 call into a permission prompt instead of an auto-approval. #115 is that failure already realised rather than a hypothetical: the hook mirrored a wrong `worktree-manager.sh` subpath faithfully for months, correct in two patterns and wrong in the two that mirror the doc, because nothing executed those snippets. A `SessionStart` hook buys the automation without paying that cost at all — it runs outside the resolution snippets and touches none of the mirrors. The mirror-cost assessment is kept in `cli-path-resolution.md` rather than deleted, so the next proposal for a new layer is weighed against it.
  - **Claude Code only, and OpenCode needs it less.** `install.sh` registers no hooks — `grep -i hook install.sh` returns nothing, and while the hook files travel with its wholesale copy, nothing runs them — so an OpenCode session never performs the healing. It does not have to: `CLAUDECODE` is unset there, which is precisely the condition Layer 0 waits for, and `install.sh` writes `AIMI_PLUGIN_DIR` into the shell profile, so resolution succeeds one layer above the cache file this healing exists to write.
  - **The manual bootstrap is documented as recovery now, not as the mechanism.** `cli-path-resolution.md` keeps `bash /abs/path/to/plugins/aimi-engineering/scripts/aimi-cli.sh prime-cache` for a session that was already open when the plugin was installed, or a host with hooks disabled — the same verb the hook spawns, run by hand. It repairs the session in front of you, and a new session would have healed itself anyway.

### After the branch — a directory-source install can locate itself, the worktree manager resolves again, and the suite measures the tree

Three GitHub issues, twelve stories, one branch. They are grouped here rather than
split because they share one root: the plugin's path resolution had three
independent holes, and the suite that should have caught two of them could not,
because its own assertion count depended on the developer's home directory.

#### Fixed

- **A marketplace registered as `"source": "directory"` can now locate its own install.** Claude Code accepts that install shape but populates no copy under `~/.claude/plugins/cache/`, so `_resolve_latest_cache_path`'s glob came back empty and every consumer concluded the plugin was not installed. `prime-cache` now falls back to reading the host's own `known_marketplaces.json` for a `directory` entry, resolving its `installLocation`, and taking the plugin subpath from that install's `.claude-plugin/marketplace.json`. `check-version` takes the same fallback, so it stops answering `unknown` — which `cli-path-resolution.md`'s own status table reads as *"no plugin version is installed at all"* — on a host where the plugin is installed and working. Both read `jq` only: these are among the four verbs that LOCATE `aimi-cli.sh`, and every Python module lives in the directory being located. GitHub issue #113.
  - **The version never comes from the path.** `_extract_version_from_path` returns the literal string `aimi-engineering` for a directory-source path — measured, not supposed — and `commands/init.md` renders that field verbatim to the user. It is read from `marketplace.json`'s `plugins[].version`, falling back to the install's own `plugin.json`, and emitted as JSON `null` when neither yields a string.
  - **Both read whitelists widened by identity, never by shape.** A third `case` arm matching `*/plugins/aimi-engineering/scripts/aimi-cli.sh` would admit almost anything, and that file gates a path later sessions exec. `_validate_cached_cli_path` and `_validate_cached_worktree_path` instead re-derive today's directory-source path and admit the cached string only on exact equality — after their existing versioned-cache arm has already returned, so the common case still costs no `jq` at all. A lookalike path that is not registered in `known_marketplaces.json` is still refused, and that refusal is asserted rather than assumed.
  - **The silent one: spawned story executors were losing their skills.** `_resolve_skills_base_dir` asked the same empty glob, so `cmd_get_story_context` passed `--skills-base-dir ""` and every executor received `skills: []` — no error, no warning, just an agent running without the SKILL.md files its own story named. It takes the same fallback now, and the test that proves it is end-to-end: it seeds a real `skills/<name>/SKILL.md` tree and asserts the returned payload's array is non-empty, because a test of the helper alone would still pass with the wiring broken.
  - **`install.sh`'s post-install `prime-cache` now states its host intent.** The call site inherited whatever `CLAUDECODE` happened to be set to — harmless while the glob always missed, and no longer: running `./install.sh --to opencode` from inside a Claude Code session inherits `CLAUDECODE=1`, so the new fallback would resolve the ambient Claude Code checkout and overwrite a working OpenCode entry in the shared `~/.config/aimi/cli-path` with a path the OpenCode-side whitelist then refuses. It now runs `env -u CLAUDECODE AIMI_PLUGIN_DIR="$plugin_dir"`; `cmd_prime_cache` itself is unchanged, so a directory-source user running the CLI by absolute path from a bare terminal is unaffected. This **retires the Known gap** recorded further down this same release, which described the pre-fallback half of the same call site. Pinned from both sides: a bare host still reaches the `claude_code` branch and its fallback, and a set `AIMI_PLUGIN_DIR` still wins over a resolvable directory source in the same config dir.
  - **`cleanup-versions`' `rm -rf` is now confined explicitly rather than incidentally.** It was already safe — its deletion targets come from one glob literal fifteen lines above the `rm`, and `latest_path` only ever built a skip key. But nothing *encoded* that, and the hazard is one edit away and it inverts: give the verb the same directory-source fallback "for consistency" and `latest_version_dir` matches no glob member, so the skip never fires and every cached version is deleted — the user's repo is never the target, the other installs are. Every deletion target is now checked against the resolved cache root before the `rm`, with a standing comment naming the invariant. The regression test lives in `test_version_cache.py`, not the bash suite, because that module records the whole throwaway filesystem tree either side of a run, which makes "nothing outside the cache was deleted" mechanical rather than described.
  - **What this deliberately does not fix, written down rather than left to be discovered.** The four resolution layers are bash snippets executed by the *command*, not by the CLI, and `prime-cache` only writes Layer 1 for next time. On a pure directory-source host no layer resolves `$AIMI_CLI`, so a person must run the CLI once by absolute path to bootstrap it — documented in `cli-path-resolution.md` with the command. Automating it needs a Layer 2b whose text `hooks/auto-approve-cli.sh` matches byte for byte, across eight mirror files; that is out of scope here. `CLAUDE_PLUGIN_ROOT` is recorded as refuted rather than left to be re-derived: it is unset in the environment the resolution snippets actually run in. **Corrected in place by the section above, in this same release, rather than deleted or left to mislead:** *"automating it needs a Layer 2b"* was accurate when written and is now false. The automation landed as a `SessionStart` hook, which runs outside the resolution snippets and therefore pays none of the eight-file mirror cost — so that cost survives as the reason not to add a fifth layer, not as the reason nothing is automated, and the manual bootstrap it justified is now recovery rather than the mechanism. The `CLAUDE_PLUGIN_ROOT` refutation stands exactly as written and is narrower than it reads: it was measured in the **Bash-tool** environment, where the snippets execute, while the hook runs in a **different process**, where the same variable is present.

- **`worktree-manager.sh` Layer 2 and Layer 3 pointed at a subpath that has never existed.** The file lives under `skills/git-worktree/scripts/`, and `cli-path-resolution.md`'s glob and per-project derivation both looked for it beside `aimi-cli.sh` instead. `hooks/auto-approve-cli.sh` carried *both* spellings — correct at Layer 0 and in its older legacy `ls` pattern, wrong in the two that mirror the broken lines — so the two right ones sat sixty lines from the two wrong ones in the same file, and the older of the pair was the correct one. Doc and hook are corrected in the same commit, because the hook matches the documented command text literally and one character of drift turns every Layer 2 call into a permission prompt. GitHub issue #115.
  - **The reason it survived from `6bd4f39` is that nothing executed those two snippets.** They are now covered by tests that EXTRACT THE SNIPPET FROM THE DOC AT RUN TIME rather than carrying a copy of it — a copied one-liner would keep passing after the doc regressed, which is the exact failure mode that let this live. Discrimination checked in both directions: against the corrected doc the suite reports 740 assertions and 0 failures in `part1`; against the pre-correction spelling restored from `25e2f39`, the same run reports 738 and 2, and the two failures are exactly these assertions.

- **The suite's assertion count is a property of the tree again, not of the developer's home directory.** Seven assertions across three functions in `test-aimi-cli-part1-core.sh` read the ambient `~/.claude/plugins/cache`: three functions skipped their assertions entirely when it was empty, and four more expected `check-version` to answer `missing` where an unresolvable glob answers `unknown`. On a host with no plugin cache the dispatcher reported **4428 with 4 failures** where a host with one reported **4441 with none** — the same tree, the same commit, thirteen assertions and four failures apart. Every one of them now builds and pins its own throwaway cache. GitHub issue #116.
  - **This was reachable for anyone developing the plugin against a directory-registered marketplace**, which produces no cache entry at all — so it was becoming the normal state, not an exotic one. It is also why the `EXPECTED_ASSERTIONS` invariant could not do its job: a count that moves with `$HOME` cannot prove no test was lost, and the failure it printed pointed at the wrong cause.
  - **The fix is verified by identity, not by a number.** The suite is run twice, once with an empty ambient cache and once with a seeded one, and the two assertion-label sets are diffed: they must come out identical. Before this work, thirteen labels appeared only in the seeded run.
  - The already-converted Test 1 of `test_check_version` was the model, and its own comment had said so since it was fixed: *"The cache is BUILT, not borrowed … so its contribution to the suite total depended on the host."* Finishing that conversion is all this is.

#### Changed

- **`EXPECTED_ASSERTIONS` 4441 → 4612, and the number was measured rather than summed.** Twelve stories added assertions across five waves; five of them ran in parallel against one base and were forbidden from touching the literal at all, because it is a single line and parallel edits to it conflict by construction. Each measured and reported its own delta, and the literal was set once per wave from what the dispatcher actually counts. That distinction is not bookkeeping: one wave's stories reported deltas summing to 46, while the merged tree measured 47 — the reconciliation described below removes some assertions and adds others, so a sum of self-reported deltas is not evidence. `_WORKTREE_FRAME_DELTA` is untouched.

- **Two stories reached opposite conclusions about the same behaviour, each correct from its own base, and the merge is where they were reconciled.** The `prime-cache` fallback could not see the widened read whitelist, so it declared the unreachable `already_current` a known gap and — correctly — asserted the gap itself, so the limitation could not rot into folklore. The whitelist widening closed that gap in parallel and wrote the paired test proving the second consecutive run now answers `already_current`, deliberately leaving it unregistered with a comment saying not to wire it in until the fallback landed. Both landed; the gap test then asserted a limitation that no longer existed and was the single failing assertion in an otherwise clean merged tree. It is deleted rather than inverted, because the other test already covers the same run pair with the correct expectation, and the note explaining why now sits where the wiring instruction used to.

- **`prime-cache` no longer reports `ok` for a write it did not perform.** `write_global_cli_cache` refuses a `*/.worktrees/*` path with `return 0`, and the caller tested only that exit status, so a refusal was indistinguishable from success — it reported the path as primed with nothing on disk. It now reads the cache file back and reports `error` on a mismatch. One recorded golden case had captured that false `ok`; it is split out of the shared parametrized assertion with the other two verbs left untouched, and the corrected answer is asserted directly.

- **The `aimi-cli.sh` jq census was re-measured twice, and both times it was already stale.** The section's own rule is to re-measure rather than quote, and it earned that rule again here: the first re-measurement found the version/cache row had silently fallen from 13 to 12 when an earlier commit on this branch deleted an unreachable `jq -n` branch, and the second found the whole total nine invocations behind, because two of the five commits that landed in between added file-opening reads the census had not absorbed. Now 243 invocations with eleven file-opening sites, stamped `d472a18`.


### After the branch — prime-cache stops answering a missing install with a refusal

#### Fixed

- **`prime-cache` no longer reports a path rejection when it never resolved a path.** On a host exporting `AIMI_PLUGIN_DIR` alongside `CLAUDECODE=1`, an empty plugin cache answered `{"status":"error","path":null,"message":"Resolved path rejected: does not match expected cache pattern"}` at exit 1 — claiming to have inspected and refused something, while reporting `path: null` in the same object, because nothing had been resolved at all. It now answers the `{"status":"not_found"}` at exit 0 that its own header contract has documented all along, and that `pc-cache-vazio-cc` already recorded for the same empty cache without that variable set. GitHub issue #113.
  - **The mechanism was a variable consulted in a branch that had already decided to ignore it.** The `not_found` early return sat nested inside a second `[ -z "${AIMI_PLUGIN_DIR:-}" ]` test. Layer 0 is skipped whenever `CLAUDECODE` is set — `commands/references/cli-path-resolution.md` says so, "so the Claude Code cache directory is always used" — and `_is_claude_code_host` had already won the host decision several lines earlier. So that inner test's only effect was to divert a host carrying both variables away from the honest answer and into the pattern check below it. `cmd_check_version` and `cmd_cleanup_versions` consult `AIMI_PLUGIN_DIR` once each, at the top, as part of host selection; this was the one place in the file that re-consulted it *inside* the branch `CLAUDECODE` had already decided, and the audit that found it checked every one of the file's fifteen occurrences rather than assuming.
  - **The cache-pattern gate was deleted rather than kept, on the same grounds as the OpenCode validator below.** It refused any resolved path outside `*/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`, and the empty string was the only input that ever reached it — `_resolve_latest_cache_path` returns either that or one of its own glob's matches, and the glob is the same shape as the pattern, so a real value satisfied it by construction. Its entire observable behaviour was therefore the wrong answer above. What the cache must not later *accept* is `_validate_cached_cli_path`'s job and is re-checked on read. An unreachable branch left standing is worse than no branch, because it reads like an assurance that shape is verified at that point. The dead `--arg path` on the neighbouring executable check went with it; that jq program hard-codes `path:null`, so no output byte moved and `"Resolved path is not executable"` is unchanged.
  - **No consumer needed an edit, and the reason is narrower than "nothing changed".** The refused message lived in exactly three places — the verb, one assertion in `test-aimi-cli-part1-core.sh`, and one golden recording — confirmed by grep over the tree; no command file and no hook ever mentioned it. `install.sh` pattern-matches `"status":"error"` generically, and the status it stops receiving is `error`, so its post-install step moves from a spurious warning to a clean log line. `commands/init.md` renders each documented status by name and already had a `not_found` arm — under the defect it rendered the `error` arm instead, printing *"Cache prime failed"* followed by a hint to check permissions on `~/.claude/`, a diagnosis with nothing to do with the condition.
  - **The recorded case was not repaired.** `pc-cache-vazio-com-plugin-dir-both` still shows exit 1 and the refusal, because that recording is the only evidence the defect existed; the label is named in a third `KNOWN_DIVERGENCES` table in `test_version_cache.py` and the inversion is asserted beside it rather than bought by the skip — exit 0, the full `not_found` object, and `stdout` byte-identical to `pc-cache-vazio-cc`'s, with `stderr`, both trees and both cli-path files compared field by field. A third table rather than an entry in either existing one for a mechanical reason: every `D2_ABORTS` recording is exit 1 with **both streams empty** and a test asserts it, while this one carries a JSON object on stdout. **Fifteen of the seventeen recorded `prime-cache` cases still replay byte-identically** — `pc-simlink-worktrees-cc` was already excused under D11, and this is the second.
  - **One assertion added, not five replaced.** The shell test that pinned the old message kept its fixture — it is still the only way to reach the scenario — and gained a sixth assertion on `.host`, which is what earns it a place beside `test_prime_cache_not_found` rather than duplicating it: it pins that a set `AIMI_PLUGIN_DIR` under `CLAUDECODE=1` does not quietly reroute the answer to the OpenCode branch, which is precisely the confusion the deleted guard institutionalised. `EXPECTED_ASSERTIONS` 4440 → 4441. Checked in both directions rather than claimed: the rewritten test fails three of its six assertions against the pre-fix CLI, and the three that hold either way are the ones the fix does not touch.

### Forge abstraction — the six phases, as they landed

### After the six phases — forge-pr-edit gains an optional --title

#### Added

- **`forge-pr-edit` can now change a pull request's title, on all three forges, without blanking its body.** The verb parsed `--number`/`--body`/`--project` and rejected everything else by name, so a title was writable exactly once — at creation, through `forge-pr-create --title` — and never again through this plugin. The only way back was `gh pr edit --title`, GitHub-only, which is precisely the forge-specific fallback this abstraction exists to remove for GitLab and Gitea users. `--title` and `--body` are now each **optional, with at least one required**, and every adapter is covered rather than GitHub alone: `gh pr edit <n> --title`, `glab mr update <n> -y -t`, `tea pulls edit <n> -t`. GitHub issue #110.
  - **No caller in the plugin passes `--title` yet, and this is not the repair of a broken path.** `open-pr.md` still derives a PR title once, at creation (Step 4a), and its Step 5c edit sends only `--body`, to append the `Related issue: #N` line. What ships is the symmetric ability the create side always had — for a person keeping a long-lived PR's title current, and for any future caller that wants to re-apply Step 4a's derivation after the fact. A reader who takes this for a bug fix will go hunting for the defect it closed and find none.
  - **Each adapter emits each flag only when that flag was seen, and that is the part protecting data you already have.** `--body` used to be mandatory, so it could be sent unconditionally and always be safe; once a title-only call is legal, an unconditional `--body` would send `--body ""` alongside the title and blank the description. A title-only edit is therefore the one case in which no `--body` reaches the forge CLI at all, and the manual copy-paste fallback withholds it too — otherwise the data loss the adapters avoid simply arrives one paste later. Each adapter spells out its three invocations literally rather than assembling an argv array, because the source-level guards that enforce `glab`'s `-y` and Gitea's always-pass-a-flag invariant work by reading the emitted line; an array would keep the behaviour and make it unverifiable.
  - **`--title ""` is refused at parse time, deliberately the opposite answer to `--body ""`.** An empty description is a real value every forge stores and clearing one is something a caller legitimately asks for, so `--body ""` keeps working exactly as before — flag-seen, not value-non-empty. No forge stores an empty title, so `--title` gets no "deliberate clear" escape hatch: it exits non-zero with a message of its own, distinct from the usage error, because "you asked for something no forge will store" is a different caller mistake from "you did not say what to change".
  - **This widens the guard *Phase 1.1*'s `#### Security` entry below describes, which stays as written.** That fix made the verb track whether `--body` was seen and refuse an omission outright; the refusal is now narrower — only a call supplying **neither** flag is refused. What it protected against is unchanged: an omitted `--body` still never reaches the forge as `--body ""`.
  - **`tea`'s `-t` is a source reading, not a real-binary observation, and *Phase 4*'s declared verification ceiling below applies to it unchanged.** `tea pulls edit` uses `flags.IssuePREditFlags` (`cmd/pulls/edit.go:66`), which ends in `}, issuePRFlags...)` (`cmd/flags/issue_pr.go:202`) — and it is that shared create/edit base, not `IssuePREditFlags`'s own literal body, that carries `{Name: "title", Aliases: ["t"]}` (`cmd/flags/issue_pr.go:95-98`). The parser gates the field on `ctx.IsSet("title")` (`:207-210`), which is what makes an omitted `-t` leave the stored title alone. Re-read on 2026-08-13, unmoved from the file's existing 2026-08-06 citation. **`tea` is still not installed on the machine this was developed on**: the new tests drive a fake `tea` that records its argv, so they prove *which arguments this file emits* and never what the real binary does with them. `glab`'s `-t` rests on the same footing, against `glab`'s published command reference. Only the `gh` arm is exercised against a real binary.
  - **39 assertions added to `test-aimi-cli-part4-forge-verbs.sh`** — title alone (asserting `--body` reaches the CLI zero times), title with body, body alone pinned byte-identical to its pre-change argv, neither flag refused, `--title ""` refused with `gh` never invoked, the exact argv all three of `gh`/`glab`/`tea` emit when a title is supplied, and the manual fallback withholding the body on a title-only degrade. `EXPECTED_ASSERTIONS` 4401 → 4440, with the full suite green at 4438 under `frame=worktree` — the documented 2 below the literal.

### Errata — corrections made after the phases landed

#### Changed

- **The GitLab adapter's PR key mapping was verified against a real binary, and every claim held.** Phase 3 shipped it with `glab` absent, so all nine key names rested on reading `gitlab-org/cli` and `gitlab-org/api/client-go` source. A container running **GitLab CE** with a real **glab 1.112.0** was stood up to check: `glab mr view <iid> -F json` returned `iid` (a number), `web_url`, `title`, `description`, `state`, `source_branch`, `target_branch`, `draft` (a real boolean) and `detailed_merge_status` — every name and type this adapter asserts. The document carried 64 keys, which is the "no field selector, `-F json` prints the whole marshalled document" claim confirmed from the other side. `state` came back `opened`, which `_forge_map_state` already normalizes to `open` for GitLab.
  - **Nothing needed correcting.** That matters because the same method, run against Gitea, *did* correct a claim — so this is a measured result rather than a rubber stamp.
  - **The ceiling is narrowed, not removed**, in `_forge_map_pr_field_gitlab`'s own header alongside the Gitea one. Still unverified against a real binary on both adapters: the review-thread and issue paths. For those the stub emits whatever its author believed, so a wrong key name still passes green on both sides.
  - **Docker's healthcheck is not a readiness signal for GitLab.** The container reported `healthy` at 45s; the API only answered at ~320s, with 502s in between. Anything automating this must poll the API itself, not the health status.

#### Fixed

- **`detect-parent-branch` now keeps searching after a candidate is rejected, instead of giving up on the first one.** `_detect_parent_branch_candidate` took the first decoration token that normalized and broke out of both loops; verification ran afterwards, in the caller. A rejected first candidate therefore ended the search — not the next token on the same line, not the next commit — and the verb fell straight through to the default branch. It now emits every candidate in `--first-parent` walk order, deduplicated, and the caller takes the first that survives `merge-base`.
  - **Reproduced before fixing, in an isolated fixture.** A leftover story branch pointing at the same tip as the branch being resolved normalizes (its name differs), then fails the caller's own "candidate must not be the branch's own tip" rule — and a genuine parent further down, carrying a valid decoration, was never consulted. Before: `Error: Could not detect default branch` in a fixture with no `origin` (or `main`/unverified where one exists). After: the real parent, `verified: true`, `source: decoration`. Deleting that one ref was enough to make the old code answer correctly, which is what identified the defect.
  - **This bit in real use during phase 4.** `detect-parent-branch` answered `main`/unverified for a branch cut from `feat/forge-abstraction`, which would have opened a 63-commit pull request against the wrong base. `open-pr.md` warns on `verified != true` but does not stop, so the flow would have proceeded.
  - Case (f) of the `detect-parent-branch` suite now expects `decoration`/`true` where it expected `default-branch`/`false`. The **base is unchanged** — that assertion never moved. Only the provenance did, and toward the truth: the branch it names was verifiable all along, and the old answer claimed a fallback it had not attempted.
- **A merge conflict mid-wave no longer deletes the branch refs of stories that did not merge.** `/aimi:execute`'s wave-loop conflict path removed every worktree from the wave without `--keep-branch`, including the conflicting story and everything after it that `merge-all` never reached — running `git branch -D` on the only ref naming those commits. Merged worktrees are still removed; unmerged ones now keep both worktree and branch, and are reported by name. This is the rule the Phase-Mode Paired Split conflict path already applied to its own members, and the two paths disagreed about the same scenario.

### Phase 4 — the Gitea adapter, the fail-open guards, and the forge documentation

#### Fixed

- **The Gitea adapter's PR shape was verified against a real binary, and that run corrected one claim source-reading had got wrong.** Phase 4 shipped with `tea` absent from the development machine, so every key name rested on reading `gitea/tea` source. A container running **Gitea 1.27.1** with a real **tea 0.15.1** was stood up afterwards to check: `tea pulls <index> -o json` returned exactly the 21 keys the adapter expects, with `index` a number, `mergeable` and `hasMerged` real booleans, and `base`/`head` bare refs — all as documented. `tea pulls list` returned an array whose values are all JSON strings, also as documented.
  - **The correction: LIST keys are the `--fields` names verbatim, NOT snake-cased.** Two headers in `aimi-cli.sh` claimed snake-casing, citing `toSnakeCase` (`modules/print/table.go:175-179`). That function exists but never fires — no valid `--fields` name is camelCase, and the two that carry a hyphen keep it. Measured: `-f index,author-id,base-commit` returns the keys `index`, `author-id`, `base-commit` unchanged. The shipped adapter never depended on the wrong claim (it requests only `index,head`, both single words), so no behaviour changes here — but a future reader reaching for a hyphenated field would have followed the header into reading `null`.
  - **This is exactly the class of error the declared ceiling warned about.** A key-name assertion cannot be proven against a stub: the fake binary emits whatever its author believed the wire format to be, so a wrong key passes green on both sides of the test. The phase-4 suites could not have caught this, and did not.
  - **The ceiling is narrowed rather than removed.** Still unverified against a real binary: the issue-side key names, the review-comment listing and resolve round trip, the `owner:` prefix on a cross-fork head, and every `glab` key — `glab` remains uninstalled.

> Phase 4 of forge abstraction: **the Gitea adapter** — a third forge behind the same verbs — together with the three items phase 3 carried forward (the fail-open test guards, the falsified forge documentation, and this release bump). The `test-aimi-cli.sh` performance work merged from PR #96 is rolled up here too; it landed under `[Unreleased]` while phase 4 was being built.


**The purpose of phase 4 was the abstraction, not the adapter — and the abstraction held.** Gitea is the third forge to go behind the same normalized verbs, and adding it needed no new seam: the per-forge knowledge stayed confined to one `_forge_map_pr_field_*` table, the `_forge_map_state` label and one adapter function per verb, exactly as the contract said it should. Where Gitea genuinely cannot supply a contract field, the gap is **declared in the payload** — an explicit null plus the field's name in `unsupported_fields` — rather than filled with invented structure: `threads[].grouping` (`tea` has no thread object, only flattened review comments), `threads[].diffSide` (`tea` collapses the new and old line numbers into one printed column), `files` and `isDraft` on a PR, and `comments` on an issue. `forge-repo-info` is deliberately **not** routed, because `tea` has no "show this repository as JSON" command and an adapter would only ask `tea` about an answer it had already parsed locally.

**Two written specs in this repository were wrong, and both were corrected rather than softened.** These were claims *this repository* asserted about upstream — not limitations upstream has — and both were disproved by reading `gitea/tea` source rather than its documentation:

- **`commands/references/forge-contract.md` ruled that `tea` cannot express `merged`.** It stated that `tea` "does not expose a distinct `merged` value" and instructed a future adapter author to normalize `tea`'s `closed` straight through. `tea` can express it: `formatPRState` (`modules/print/pull.go:95-100`) prints the literal string `merged` whenever `pr.Merged != nil`, and the detail path carries a `hasMerged` boolean and a `mergedAt` timestamp alongside the raw state (`cmd/pulls.go:33,46,47`). An adapter following the contract as written would report a merged pull request as `closed` forever. The contract now describes the LIST-vs-DETAIL split with those citations and names the derivation this release ships.
- **`aimi-cli.sh`'s phase-1 `GITEA CAPABILITY-GAP NOTE` claimed `tea` has no review-thread resolution at all**, and described it as a permanent gap rather than a temporary one. `tea pulls review-comments`, `tea pulls resolve` and `tea pulls unresolve` have existed since **v0.14.0**; the current release is v0.15.1. Both verbs are routed. The real gap is narrower and different in kind — `tea` exposes no thread or conversation object, so the adapter emits one degenerate single-comment thread per review comment — and the note now records that instead of the retracted ruling.

**Seven test assertions could not fail, and now can.** A guard written as `grep -v <comments> | grep -q <pattern>` reports **absent** on a file that contains the pattern: under `set -o pipefail`, `grep -q` exits at its first match and SIGPIPEs the `grep -v` still feeding it, so the pipeline's non-zero status reads as "no hit". Seven guards of that shape — six in `test-aimi-cli-part3-roadmap-forge.sh`, one in `test-aimi-cli-part4-forge-verbs.sh` — now count with `grep -c` and compare a number. Only one was failing open in practice, the whole-file `--identity` scan whose input is far larger than a 64 KB pipe buffer, and it was measured: green over a planted violation before the change, red over the same tree after. The other six were the defective *shape* carrying a latent defect rather than a live failure. The assertion delta is zero; what changed is whether the checks can report correctly, not how many there are.

**Read this before trusting the Gitea adapter in production — the verification ceiling.** `tea` **is not installed on the machine this release was developed on.** Every Gitea flag, subcommand and JSON key below was read off `gitea/tea` `main` source on 2026-08-06, file and line cited per claim, and was **never observed coming out of the real binary**. What the tests prove is **which arguments this CLI emits** and **how it parses a fixture** — never what real `tea` does with either. That is a strictly weaker claim than the GitHub half of these same verbs can make, which is exercised against a real `gh`. One difference from phase 3's identical `glab` ceiling is worth stating because it cuts the other way: the `tea` reading is off the actual command and printer implementations (`cmd/pulls.go`, `modules/print/table.go`), where the argv and the printed shape are decided, rather than off struct tags inferred to be the wire format. The asymmetry that remains is between argv and keys — an argv assertion is sound against a fake, since a wrong flag is visible in the recorded log, while a key-name assertion is not, since the stub emits whatever the author believed and a wrong key passes green on both sides. The one criterion testable against reality, the missing-binary degrade, **is** tested against reality, because `tea` genuinely is absent. The ceiling is recorded in `aimi-cli.sh` at each Gitea section it applies to, not only here.

#### Added

- **`forge-pr-review-threads` and `forge-resolve-review-thread` now run on Gitea/Forgejo through `tea`, and the phase-1 note that ruled this impossible has been rewritten because it was wrong.** `aimi-cli.sh` carried a GITEA CAPABILITY-GAP NOTE stating that a `tea` adapter "is expected to have NO equivalent for resolving a review thread at all" and that `tea` "simply has no reviewThread/conversation-resolution concept to call" — a **permanent** gap, not a temporary one. Source falsifies both halves: `tea pulls review-comments <pull index>` (`cmd/pulls/review_comments.go:24-32`) and `tea pulls resolve <comment id>` / `tea pulls unresolve` (`cmd/pulls/resolve.go`, `unresolve.go`) all exist and landed in **tea v0.14.0**; the current release is v0.15.1. Both verbs are routed, and the note now records the narrowed real gap instead of the retracted ruling.
  - **Read this before trusting the Gitea review-thread adapters — the verification ceiling, first, so the rest can be calibrated against it.** `tea` **is not installed on the machine this was developed on.** Every subcommand, flag and JSON key was read off `gitea/tea` `main` source on 2026-08-06, file and line cited per claim, and **none was observed coming out of the real binary**. The tests prove *which argv this file emits* and *how it parses a fixture* — never what real `tea` does with either. **The two halves are not equally covered, and that asymmetry is the honest part:** an argv assertion is sound against a fake (a wrong flag is visible in the recorded log), while a key-name assertion is not (the stub emits whatever the author believed, so a wrong key passes green on both sides). By contrast the GitHub half of these same two verbs is exercised against real `gh` behaviour and can still make the stronger claim.
  - **The real gap is GROUPING, not resolution — narrower and different from what the note claimed.** `tea` lists review *comments*, flattened across every review (`modules/task/pull_review_comment.go:16-44`), and exposes no thread/conversation object at all, so the adapter emits **one degenerate single-comment thread per review comment**, `comments.totalCount == 1`. That gap is declared as `threads[].grouping` — an explicit `null` key plus its name in `unsupported_fields`, never a bare unmarked null. Inventing grouping by path or reviewer would fabricate a structure the forge does not have.
  - **`threads[].diffSide` is permanently unrecoverable here, and the reason is not the usual absence.** `tea` collapses `LineNum` and `OldLineNum` into one printed column (`modules/print/pull_review_comment.go:52-59`), so RIGHT vs LEFT cannot be told apart from the CLI output at all. The GitLab arm genuinely *can* derive it, from separate `new_line`/`old_line` keys — recorded so the next reader does not try to port that derivation across.
  - **The unresolved-only default is filtered LOCALLY, the opposite of the GitLab arm.** `tea pulls review-comments` carries only `flags.AllDefaultFlags` plus `--fields` — there is no `--state` to ask the server with — so resolved rows are dropped after the call and `--all` skips the drop. Proven from the recorded argv (which carries no `--state`) against a fixture holding **both** a resolved and an unresolved row; a fixture of only-unresolved rows would have let a broken filter pass green.
  - **`threads[].comments.nodes[].url` is supported on Gitea and deliberately absent from `unsupported_fields`** — the one place this forge is richer than GitLab, whose arm lists it as a gap. Copying GitLab's array wholesale was the expected mistake and there is an assertion for exactly it. The full gap list: `pr.title`, `pr.url`, `threads[].startLine`, `threads[].diffSide`, `threads[].isOutdated`, `threads[].isCollapsed`, `threads[].grouping`, `threads[].comments.nodes[].outdated`.
  - **`line` comes back a JSON number even though `tea` printed a string.** `review-comments` is a LIST-path command and that path marshals a `map[string]string` (`modules/print/table.go:187-208`), so every value arrives as a string; `isResolved` is likewise **derived** from `resolver != ""` because `tea` exposes no boolean. Thread and comment ids stay strings, matching every other forge.
  - **No token is ever handed to `tea`, and that is a safety property rather than an omission.** `tea` reads `GH_TOKEN` as a fallback credential (`modules/context/context_login.go:15-51`) while `_forge_account_override_slots` defaults an empty slot to the *ambient* `GH_TOKEN` — so copying the GitHub arm's prefix-assignment shape onto a `tea` invocation would hand a GitHub token to a Gitea instance. Neither new function assigns or exports `GH_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITEA_TOKEN` or `GITEA_INSTANCE_URL`, and a counting assertion over both function bodies keeps it that way.
  - **`tea` exits 1 for every error with no distinct not-found code, so `404` in stderr is the only confirmed negative.** Listing → `not_found`; resolve → `found` with `resolved: false`. Every other non-zero exit stays `error`/`cli_failed` carrying `tea`'s own stderr — including the unknown-subcommand error a `tea` older than the v0.14.0 floor produces, which must never read as "this pull request has no review comments". A pull request with zero review comments is `found` with an empty `threads` array.
  - **Both `no_adapter` messages now name all three adapters**, and `unknown` — an unrecognized remote host — is the only forge word that still reaches that branch, since `AIMI_FORGE_TYPE` validates against `github|gitlab|gitea` and all three are routed. The test that used `gitea` as its stand-in for "a forge with no adapter" was **retargeted onto an unrecognized host, not deleted**; deleting it would have left the branch untested. There is nothing left to retarget to after this.
  - **169 assertions added to `test-aimi-cli-part4-forge-verbs.sh`** (1054 → 1223), all green, behind a `gtt_`/`GTT_` private namespace with its own fake `tea`, its own `mktemp -d` and its own argv log — never an edit to a shared stub. The falsifiability proof runs first and two mutation tests run last, each unrouting one verb and confirming a specific named assertion goes red. The tea-absent degrade test is the section's **one assertion measured against reality**, since `tea` genuinely is not installed.

- **The forge contract now has a Gitea field mapper: `_forge_map_pr_field_gitea` maps the ten normalized PR contract fields onto `tea`'s own vocabulary, and `_forge_pr_view_build_found` gained the matching `gitea)` arm.** `number -> index`, `url -> url`, `title -> title`, `body -> body`, `state -> state`, `headRefName -> head`, `baseRefName -> base`, `mergeable -> mergeable`. It sits directly below `_forge_map_pr_field_gitlab`, ten branches in the same case shape, so the three mappers stay diffable side by side. Nothing else in `_forge_pr_view_build_found` became forge-aware, so its header's stated invariant — the only per-forge knowledge is the single `_forge_map_pr_field_*` lookup and the `_forge_map_state` label — still holds.
  - **`files` and `isDraft` are present-but-empty branches, not deleted ones, and both are settled by absence in the data rather than by preference.** `tea`'s `diff`/`patch`/`diffUrl` all resolve to URLs (`modules/print/pull.go:277-280`), so there is no per-file list to name; Gitea models a draft as a `"WIP: "` **title prefix** that `--draft` writes (`cmd/pulls/create.go:89-91`), so `pullData` carries no draft key and `PullFields` has no `draft` entry to read back. Each comes back `null` **and** named in `unsupported_fields` — never a bare, unmarked null. Deriving `isDraft` by string-matching a title prefix would have been a guess.
  - **`merged` is reachable on Gitea, and this contradicts `commands/references/forge-contract.md:100-107` knowingly.** That document says `tea` "does not expose a distinct `merged` value" and that an adapter "should normalize `tea`'s `closed` straight through". Both halves are falsified by source: `formatPRState` (`modules/print/pull.go:95-100`) returns `"merged"` whenever `pr.Merged != nil`, and the detail path carries `hasMerged`/`mergedAt` alongside the raw state (`cmd/pulls.go:33,46,47`). A new sibling helper `_forge_map_pr_state_gitea <detail-json>` does the derivation — `merged` when `.hasMerged` is JSON true, otherwise `.state` through `_forge_map_state gitea`. It is a sibling rather than a branch inside the mapper because it reads a **different key** than `state`, which a one-field-one-key table cannot express, and it is not a `gitea` arm of `_forge_map_state` because that function maps a raw value and knows nothing about documents. `_forge_map_state`'s body is left byte-identical and contains zero occurrences of `gitea`, asserted in the counting `grep -c` form with a `gitlab` control query alongside that must be non-zero.
  - **`tea` emits two different JSON shapes for the same pull request, and getting that wrong is the most likely way to break this adapter — so it is pinned by test, not by comment.** `tea pulls <index> -o json` is one **object** with **typed** values (`index` a number, `mergeable`/`hasMerged` real booleans, `base`/`head` bare refs); `tea pulls list -o json -f <csv>` is a JSON **array** whose keys are snake-cased and whose every value is a **string** (`"index": "42"`), with `head` carrying an `owner:branch` prefix for a cross-fork PR. This adapter reads the **detail** path. The test file carries both fixtures for the same PR and asserts they genuinely differ (`.index | type` is `number` vs `string`, `.mergeable | type` is `boolean` vs `string`, only the list `head` contains `:`), then feeds each to the same `_forge_pr_view_build_found gitea` call: the detail object populates eight of ten keys, the list array yields a `pr` whose **every** key is null. That is not a coincidence — `jq --arg k index 'has($k)'` on an array exits **5** (`Cannot check whether array has a string key`), which the builder's `2>/dev/null) || present="false"` turns into skip-this-field; the test asserts that exit code directly.
  - **`tea` HAS a field selector, so glab's shape was deliberately not copied.** `--fields, -f` is a CSV over a fixed allowlist (`cmd/flags/generic.go:157`) — closer to `gh` than to `glab`. `_forge_pr_view_gitlab` fetches the whole marshalled document and picks keys out of it afterwards **only** because glab has no selector at all; that is a workaround for a missing feature, not a house style. The argv assertions pin it: `-o json` on both calls (asserted as a control that must match, so the zero below it is a measurement), `-f` on the list call, and **zero** occurrences of a gh-style `--json` field-list flag.
  - **Declared verification ceiling, stated in the function header and repeated here: `tea` is NOT installed on this machine.** Every flag, subcommand and JSON key was read off `gitea/tea` `main` source on 2026-08-06, file and line cited per claim, and none has been observed coming out of the real binary — the same ceiling phase 3 declared for `glab`. The tests prove **which arguments this file emits** and **how it parses a fixture**; they can never prove what real `tea` does with them.
  - **83 assertions added to `test-aimi-cli-part4-forge-verbs.sh`** (971 → 1054), all green, behind a `gtm_`/`GTM_` private namespace and a private fake-`tea` stub with its own `mktemp -d` and argv log — a separate stub rather than an edit to a shared one, because bash keeps the **last** definition of a duplicated function and three individually-green parallel branches can merge into a red one. A falsifiability proof runs first, before any assertion trusts the stub. The table was then checked against an 11-case mutation matrix (`number -> id`, `headRefName -> base`, `body -> description`, `url -> diffUrl`, `isDraft -> draft`, `files -> diffUrl`, `mergeable` branch deleted, the `gitea)` arm dropped, `hasMerged` never firing, `merged` invented from absence, and a `gitea` arm bolted onto `_forge_map_state`) — **every one turns assertions red**, against a control run of 80 passed / 0 failed.

- **A Gitea repository can now be READ through the forge contract: `forge-auth-status`, `forge-pr-view` and `forge-issue-view` answer from `tea` instead of degrading to `reason=no_adapter`.** Three new adapters — `_forge_auth_status_gitea`, `_forge_pr_view_gitea`, `_forge_issue_view_gitea` — each placed beside its GitLab sibling and structurally parallel to it, plus four dispatch edits. The PR arm consumes the `_forge_map_pr_field_gitea` table added above rather than writing a key table of its own, and so does the issue arm: Gitea spells `index`, `url`, `title`, `body` and `state` identically on `pullData` and `issueData`, which is what makes that reuse legitimate. `forge-repo-info` is deliberately **not** routed (see below).
  - **`forge-auth-status` reports `error`, never a clean negative, when the check could not run — and that is the one place the Gitea arm deliberately does not copy the GitLab one.** `glab auth status` exiting non-zero *is* glab's confirmed "not authenticated" answer, so folding it into `authenticated: false` is correct there. `tea` exits **1 uniformly for every error** (`main.go:18-30` — there is no distinct code for anything), so the same reading would manufacture a false clean negative out of a broken PATH or a corrupt config. A false negative here is precisely what lets a broken session walk into opening a duplicate pull request. Both failure shapes — non-zero exit, and exit 0 with stdout `jq` cannot parse as an array — resolve to `status="error"`, `reason="cli_failed"`, `data=null`, asserted independently, each asserting `data` is null so `authenticated` cannot be read at all. Only an **empty but cleanly parsed** login list is a definitive `authenticated: false`, and that stays `status="found"`. `not_found` is unreachable on all five paths this verb can take, swept and asserted.
  - **`tea login list -o json` is an offline config read, and the header says so rather than letting a caller assume gh-grade parity.** It proves a login entry for the detected host exists; it does not prove the token still works. Entries are filtered by the URL's **host component** (scheme, userinfo, path and port stripped, case-folded) and the `default` entry among the matches wins — never entry zero. One and the same payload holding only a `gitea.com` login therefore reports `authenticated: true` on a `gitea.com` fixture and a definitive `authenticated: false` on a `codeberg.org` one; an implementation that took the first entry answers true for both and fails that pair. **`tea whoami` is invoked by no code path**: it round-trips the network and then discards its own error (`cmd/whoami.go:22-31`, `user, _, _ :=`), so it cannot answer this question. A section-wide argv audit reports **0** `whoami` lines across every test, with a `login list` control query alongside that must be non-zero, and the fake `tea` exits 127 on any unhandled invocation so a stray call could not have passed quietly.
  - **`forge-pr-view` reads the DETAIL path and establishes absence structurally, and `tea`'s field selector is used rather than glab's fetch-everything shape.** The recorded argv for the detail call is exactly `pulls <index> -o json` — no `-f`, no `--fields`, and no gh-style `--json` anywhere (asserted after an `-o json` control that must match, so the zeros are measurements). The not-found probe *is* `pulls list --state all -f index,head -o json`, naming only the two fields it consumes: `tea` has a CSV selector (`cmd/flags/generic.go:157`) and `_forge_pr_view_gitlab` fetches whole documents only because glab has none. The probe is skipped entirely for a numeric ref, proven by a per-invocation counter file that stays at **0** for that case and is non-zero for a branch ref.
  - **A cross-fork head does not read as absent.** `tea pulls list` has no head filter at all, so the listing is filtered locally — and its `head` may be `owner:branch` (`formatPRHead`, `modules/print/pull.go:83-93`). The comparison is on the suffix after the last `:` (git refs cannot contain one), so a row whose head is `contributor:feat-x` matches `--pr feat-x` and resolves found, while `contributor:other` resolves `not_found`. Plain string equality fails the first half — and reporting an existing pull request as absent is what invites a duplicate. The probe also resolves the **index** the detail call is addressed with, because `tea pulls <arg>` takes an index and never a branch name.
  - **`not_found` and `error` are never conflated, and a structural fact outranks stderr prose.** When the probe positively confirmed the pull request exists and the detail call then failed — including a failure whose stderr literally contains `404` — the envelope is `error` carrying `tea`'s own stderr. The 404 text match survives only as a backstop for the cases where the probe could not confirm anything (a numeric ref, a failed probe, an unparseable probe response).
  - **`merged` is derived from `hasMerged`, in exactly one place in the whole file.** `_forge_pr_view_gitea` normalizes the detail document's `.state` through `_forge_map_pr_state_gitea` before handing it to the shared envelope builder, so `state: "closed"` + `hasMerged: true` yields `"merged"` and the same document with `hasMerged: false` yields `"closed"`. A counting `grep -c` over `aimi-cli.sh` asserts **exactly one** non-comment `hasMerged` derivation site, so this story and the mapper story cannot both have added one. `_forge_map_state` gains no `gitea` branch: it normalizes spelling and must not invent a value the source data did not provide.
  - **`comments` on a Gitea issue is reported ABSENT, not zero.** `issueData.Comments` is an array populated **only** when `--comments` is passed (`cmd/issues.go:148-154`) and an empty array otherwise, so deriving a count from its length would report `comments: 0` for every issue in existence. `--comments` is deliberately not passed, `data.comments` is `null` **and** `"comments"` is named in `unsupported_fields`, asserted against a fixture whose `comments` array really is empty. `labels` are accepted as plain strings **or** `{name}` objects from one mixed-shape fixture, the same either-shape expression the GitLab arm uses, so a label list is never silently dropped.
  - **`forge-issue-view` never invents `not_found`, and the reason it has no structural probe is recorded in the function header so it is not later "improved" into a scan.** `tea issues list` is paginated with no index filter, so a local scan could report a real issue as missing — the one outcome that must never be invented. Absence is therefore claimed only on a positive 404/not-found stderr match; every other non-zero exit is `error`, with `reason` decided **structurally** by asking `_forge_auth_status_gitea` (`not_authenticated` when there is no matching login, `cli_failed` otherwise — including when the auth probe itself could not run, because an unreadable login list is not a confirmed logout).
  - **There is deliberately no `_forge_repo_info_gitea`, and the absence is recorded as a decision at the decision site.** `tea` has no repo-as-JSON command: `tea repos <owner>/<name>` requires the slug this code would have to local-parse first and does not honour `--output` at all (`cmd/repos.go:47-65`), and `tea repos list` lists every accessible repository. A Gitea arm would local-parse the answer, ask `tea` about it, and learn nothing. `forge-repo-info` on a Gitea remote therefore still answers `status="found"` with `data.source="local-parse"`, with the fake `tea`'s argv log asserted **empty** for that verb and the `_forge_repo_info_gitlab` symbol used as the control that makes the `_forge_repo_info_gitea` zero a measurement.
  - **No credential reaches a `tea` invocation.** `tea` honours `GH_TOKEN` — not only `GITEA_TOKEN` — whenever `GITEA_INSTANCE_URL` is also set (`modules/context/context_login.go:15-51`), so copying the GitHub write path's prefix-assignment habit would hand a GitHub token to a Gitea instance. A counting `grep -c` scoped to the three new function bodies reports **0** bindings of those three names, and the checker is proven able to return non-zero by running it against a copy with one planted. It uses the counting form throughout and adds **no eighth** `grep -v … | grep -q …` fail-open guard.
  - **The three tests that used `gitea` as their stand-in for "a forge with no adapter" were RETARGETED, never deleted** — the `no_adapter` path stays covered, with every assertion including `reason=="no_adapter"` intact. `test_forge_auth_status_no_adapter_is_error` (part 3), `test_forge_pr_view_non_github_forge_quiet_degrade` and `test_forge_issue_view_non_github_forge_degrades` (part 4) now drive an unrecognized remote host that classifies as `unknown`, and one stale comment claiming gitea is "the control for every no_adapter assertion in this file" was corrected without touching its (still true) assertion. **This is the end of the retarget line**: `AIMI_FORGE_TYPE` validates only `github|gitlab|gitea` and all three now have adapters, so `unknown` — reachable solely through a host detection does not recognize — is the only control that remains.
  - **Declared verification ceiling, stated in all three function headers and repeated here: `tea` is NOT installed on this machine.** Every flag, subcommand and JSON key was read off `gitea/tea` `main` source on 2026-08-06 and none has been observed coming out of the real binary. These tests prove **which argv this file emits** and **how it parses a fixture** — never what real `tea` does with them. Where that under-verifies is the JSON key names themselves: the stub emits whatever the author believed, so a wrong key passes green on both sides. The one criterion here testable against reality is the missing-binary degrade, and it is tested: with `tea` genuinely absent, all three verbs report `status="error"` with a message naming **`tea`** (never `gh`, never `glab`), exit 0, and write nothing to stderr.
  - **182 assertions added to `test-aimi-cli-part4-forge-verbs.sh`** (1054 → 1236) and a net **0** to part 3 (the retargeted test keeps its assertions; only its fixture and wording changed), all green, behind a `gtr_`/`GTR_TEA_` private namespace and a private fake-`tea` stub with its own `mktemp -d`. The auth-status tests live in part 4 rather than part 3 — where every other `forge-auth-status` test sits — because the dispatcher runs the parts concurrently and part 3 *is* the wall clock; an assertion here costs ~nothing, one there extends the whole suite one-for-one. A three-verb falsifiability proof runs **first**, driving each verb twice with payloads that should move the verdict and recording a `would_have_gone_red` flag per verb. A three-verb mutation matrix runs last: each unroutes one verb and shows a specific **named** assertion go red, and each asserts both that its patch landed **and** that it replaced **exactly one** line of `aimi-cli.sh` — necessary now that several `gitea` arms exist across this wave, since an anchor matching a sibling's arm would silently unroute three verbs at once. A separate mutation proves the issue arm reads its keys through the shared mapper: repointing `_forge_map_pr_field_gitea number` alone changes `data.number` out of `forge-issue-view`.
- **Gitea and Forgejo repositories can now open, update and comment on their own work: `forge-pr-create`, `forge-pr-edit` and `forge-issue-create` route to `tea` instead of degrading with `no adapter for forge "gitea" yet`.** `tea pulls create -t <title> -d <body> --head <branch> -b <base>`, `tea pulls edit <number> -d <body>`, `tea issues create -t <title> -d <body>`. All three keep the shared write envelope `{status, data:{url, number}, message}` built by the existing `_forge_emit_write_status`/`_forge_build_write_data` pair, so `number` is still a JSON int; the two PR verbs keep mandatory-print plus a **non-zero** exit on every degraded branch, and `forge-issue-create` keeps its soft-fail contract and **always exits 0**, reporting failure only through `status` — asserted against a failing `tea` in all three shapes (call failed, URL unparseable, binary absent).
  - **The manual fallback was telling Gitea users to run `gh pr create` against `github.com`, and that is the half of this entry that changes behaviour users see today.** `_forge_pr_write_print_manual`'s `*)` host default and GitHub wording already fired for Gitea on every degraded write, whether or not `tea` is installed anywhere. It now has a `gitea` arm and a `gitea) host="gitea.com"` default: `tea pulls create` / `tea pulls edit` with tea's own flag spellings, Gitea's compare path `/<owner>/<repo>/compare/<base>...<head>` (no GitHub `?expand=1`), and Gitea's pull-request path `/<owner>/<repo>/pulls/<number>` — **`/pulls/`, with an `s`**; GitHub's singular `/pull/<number>` 404s on a Gitea instance. The tests assert the gitea text contains none of `github.com`, `gh pr create`, `gh pr edit`, `--body`, `?expand=1` or `/pull/`, and those negatives were **run against a copy of `aimi-cli.sh` at the previous commit to confirm they go red** rather than being assumed to.
  - **The noun stays "pull request".** Gitea calls them pull requests, exactly like GitHub — only GitLab says merge request — so the gitea arm is deliberately *not* symmetric with the glab arm next door. Both the section header and an assertion (`grep -c 'merge request'` is 0 on the gitea text) say so, because "fixing" it by symmetry is the obvious wrong move.
  - **`tea`'s flag names are neither `gh`'s nor `glab`'s, and one of them has no short form at all.** `-t/--title`, `-d/--description` (**not** gh's `--body` — the same gotcha `glab` has), `-b/--base` (**not** glab's `--target-branch`), and `--head` in its **long form only**: `tea` gives it no short alias, and `-h` is urfave/cli's help flag, so a `-h` there would print help instead of naming a branch. Read off `gitea/tea` `main` (`cmd/flags/issue_pr.go:94-118`, `cmd/pulls/create.go:26-55`) on 2026-08-06. Each of the three writes has its **entire recorded argv line pinned in one comparison**, so a wrong spelling fails outright instead of being absorbed by a loose grep.
  - **⚠️ `tea` has no `-y`/`--yes`/`--confirm` — its interactivity hazard has a different shape and is worse if hit.** `tea pulls create` enters an interactive survey whenever `ctx.Command.NumFlags() == 0` (`modules/context/context.go:55-59`), and **that check performs no TTY test despite its own doc comment claiming one** — so a zero-flag invocation hangs even with non-TTY stdin, in an autonomous run with nobody present to answer. The invariant — **every `tea` write invocation carries at least one flag** — is stated in the write section's header where a reviewer meets it before any code, and is asserted from **recorded argv, never from an exit status**: a fake `tea` never prompts, so it exits 0 either way and an exit-status assertion would pass vacuously. The flag-count reader behind it is proven able to answer "no flags" — against hand-written zero-flag argv lines — **before** any test trusts it answering "has flags".
  - **⚠️ `tea` honours `GH_TOKEN`, so no `tea` call carries a token prefix assignment — and none blanks one either.** `modules/context/context_login.go:15-51` reads both `GITEA_TOKEN` and `GH_TOKEN`, while `_forge_account_override_slots` deliberately defaults an empty slot to the **ambient** `GH_TOKEN`: copying the github arm's prefix-assignment shape onto a `tea` call would hand a **GitHub** credential to a **Gitea** instance. Blanking is refused for the opposite reason — a bare `GITEA_TOKEN=` prefix would revoke an operator's own account selection, exactly as phase 2's `TOKEN=""` did on the gh side. So this path sets nothing and unsets nothing: an operator-exported `GITEA_TOKEN` reaches all three `tea` calls untouched (asserted on the child's own environment, on a channel separate from argv), and `GH_TOKEN` stays unset throughout.
  - **Every token assertion is proven able to fail.** Both source guards use the **counting** form (`count=$(grep -v '^#' file | grep -cE ...) || count=0`, compared with `assert_eq "0"`), never `grep -v | grep -q`, which under `set -o pipefail` SIGPIPEs its left half and reports a real hit as "no hit"; a planted `export GH_TOKEN` on line 1 of a copy of `aimi-cli.sh` raises the count to 1, a planted `GH_TOKEN=` prefix on a `tea` call raises the other to 1, a planted blanking `GITEA_TOKEN=` prefix does too, and a commented-out mention raises neither. **No eighth fail-open guard was added.** The live probe runs the write as a **plain statement redirected to a file, in the same shell that reads the environment before and after** — never inside `$( )`, never through a separate `forge-auth-status` subprocess, the two ways phase 3's US-005 shipped this same assertion tautological. Proven with teeth: sourced from a copy of `aimi-cli.sh` with an `export GH_TOKEN` planted inside `_forge_pr_create_gitea`, the probe goes **red**.
  - **Idempotency is part of the contract, and it is proven by an invocation count of 0 rather than by an output comparison.** An already-open pull request for `$head` reports `unchanged` with that PR's `{url, number}` and **never** shells out to `tea pulls create`. The probe is `tea pulls list --state all -o json` plus a **local** head filter, because `tea pulls list` has no `--head`/`--source-branch` filter at all (`cmd/pulls/list.go:31`) — `gh pr list --head` and `glab mr list --source-branch` have no counterpart here. That local filter handles both ways tea's **LIST** output differs from its **DETAIL** output, and a fixture exercises each: every LIST value is a JSON **string** with snake_cased keys (`modules/print/table.go:187-208`), so `index` arrives as `"42"`; and the LIST `head` may carry an `owner:` prefix for a cross-fork PR (`formatPRHead`, `modules/print/pull.go:83-93`), so `forkuser:feat-x` must still match the branch `feat-x` — while `forkuser:other-feat-x` must **not**, which is asserted too.
  - **Only an OPEN pull request blocks creation.** tea's LIST `state` can literally be `merged` (`formatPRState`, `modules/print/pull.go:95-100`), and a closed or merged PR on the same branch falls through to creation exactly as it does on the github and gitlab arms — so a reused branch is never blocked forever by a dead PR. Both `closed` and `merged` fixtures reach `tea pulls create`.
  - **"Created but no parseable URL" is a real branch here, not a hypothetical.** `tea pulls create` ends in `print.PullDetails` (`modules/task/pull_create.go:89`), a markdown block that appends the URL line **only when it is non-empty** (`modules/print/pull.go:76-78`), and `--output json` is not consulted on the create path at all. That branch prints the manual instruction, reports `degraded` and exits 1. `tea issues create` is friendlier — markdown plus a bare `issue.HTMLURL` line (`modules/task/issue_create.go:28-30`). URL extraction is a last-`http(s)`-token scan (`_forge_tea_write_url`), never `tail -n1`, since both paths wrap the URL in markdown.
  - **Once a URL is in hand the outcome is never downgraded.** A failed post-create re-read reports `created` with `{url, number: null}` at exit 0 plus a Warning naming what is unconfirmed — never `degraded`, which would null `data` and throw the created pull request's URL away. The number itself always comes from a **structured field read**: the created URL's trailing segment is only an *address* for the `tea pulls <index> -o json` re-read, and the reported number is that document's own `index`, so a URL shape guessed wrong yields a null number rather than a wrong one.
  - **`_forge_tea_write_url` is a sibling of `_forge_glab_write_url`, not a rename of it, and the duplication is deliberate.** A forge-neutral rename would have touched phase 3's shipped gitlab arms plus `glw_source_write_helpers` and `test_glw_glab_write_url_extraction` while two sibling branches held the same file open — and tea's two write paths have genuinely different framings (`pulls create`'s URL line is *conditional*, `issues create`'s is guaranteed) that its own header has to state. Duplication over conflict, the same call phase 3 made for its five fake-`glab` stubs.
  - **A known, deliberate duplicate read path is recorded in the code by name.** The gitea idempotency probe does **not** call `_forge_pr_view_gitea`: that function lands in the same wave, so depending on it would make this unbuildable. The resulting second Gitea PR read path is named in the write section's header as a known debt awaiting unification — the same debt the GitLab arm still owes (`_forge_pr_view_gitlab` plus the inline `glab mr view`) — rather than left for a later reader to discover and assume is an accident.
  - **Retargeted, never deleted — and this is the end of the line.** `test_forge_pr_create_non_github_forge_mandatory_print` used `codeberg.org` → `gitea` as its stand-in for "a forge with no adapter", a premise that died the moment this change routed gitea, exactly as phase 3 did to gitlab. It now uses a host that classifies `unknown`, and its message assertion reads `no adapter for forge "unknown"`. `AIMI_FORGE_TYPE` validates only `github|gitlab|gitea`, so after this there is no forge **word** still lacking an adapter — only an unrecognized remote host. The three write verbs' fallthrough messages also stop claiming "GitHub and GitLab are the only adapters", which is now false, and name Gitea; the other three copies of that sentence belong to verbs this change does not route and are left alone.
  - **Declared verification ceiling, stated in the code and repeated here: `tea` is NOT installed on this machine.** Every flag, subcommand and JSON key was read off `gitea/tea` `main` source on 2026-08-06, file and line cited per claim, and none has been observed coming out of the real binary — the same ceiling phase 3 declared for `glab`. What these tests prove is **which argv this file emits** and **how it parses a fixture**, never what real `tea` does with them. The one criterion testable against reality — the missing-binary degrade — is tested against reality, because `tea` genuinely is absent.
  - **188 assertions added to `test-aimi-cli-part4-forge-verbs.sh`** (1054 → 1242), all green, in 20 test functions behind a `gtw_`/`GTW_` private namespace and a private fake-`tea` stub — a separate stub rather than an edit to `gtm_setup_fake_tea_fixture` or any of the five fake-`glab` installers, because bash keeps the **last** definition of a duplicated function and three individually-green parallel branches can merge into a red one. **The stub's case is nested rather than dispatching on `"$1 $2"`**: tea overloads the `pulls` noun, so `tea pulls 42 -o json` is a DETAIL read whose second argument is an index, and a flat dispatch would send every post-write re-read into the unhandled arm. A three-way mutation matrix unroutes `forge-pr-create`, `forge-pr-edit` and `forge-issue-create` in turn — each from a **fresh** copy so only that one verb is unrouted, each asserting its own patch landed, each naming the specific assertion that goes red. Run whole against the previous commit's `aimi-cli.sh`, **102 of the 188 go red**. Suite total is now `assertions=3351` under `frame=worktree` (3080 + 83 from the wave's first story + 188 here); `EXPECTED_ASSERTIONS` at `test-aimi-cli.sh:171,176` is deliberately **untouched** — the release story raises both branches once.

- **Every `test-aimi-cli.sh` run now ends with a one-line `suite-cost` record, so the suite's own cost is a `grep` rather than an investigation.** Fixed field order, `key=value` throughout:

  ```
    suite-cost cli_lines=15440 test_lines=28999 assertions=3080 wall_seconds=149 mode=concurrent frame=worktree
  ```

  - **It exists because this cost compounds and is invisible while it does.** Phase 3 of forge-abstraction added ~5,900 lines to `aimi-cli.sh` and ~11,000 to the test corpus, and that made the 1,544 assertions that *already existed* about 9% slower — 148.75ms to 162.08ms each — for tests with no relationship to the code that was added. Nobody noticed until somebody asked why the suite was slow, and answering that took hours. Printed every run, the next such regression is a two-line diff on the day it lands.
  - **It costs two `wc -l` reads and one clock read, and that is the whole design.** Measured at ~7ms per emit (100 emits in ~700ms, taken while the serial suite was running, so an upper bound) against a 149s concurrent run — 0.005%. There is deliberately **no** calibration or benchmark loop: a per-run micro-benchmark would itself be the sort of cost this line exists to expose, so the growth curve that motivated this work is documented in the entries below rather than re-measured on every run.
  - **`mode` and `frame` are on the line because two of the numbers are only comparable within their own environment.** `wall_seconds` means nothing across `mode=serial` and `mode=concurrent`. `assertions` is **2 lower** under `frame=worktree` than under `frame=checkout` *for the same tree* — `test_init_session_writes_global_cache` emits ONE assertion when the CLI under test is worktree-resident and THREE otherwise. The suite prints that caveat in prose directly under the line as well, because the failure it prevents is a reader comparing a container run against a main-tree run and concluding two tests vanished.
  - **The line was proved to report measurements rather than constants, field by field.** Against a scratch tree of stub parts whose sizes and counts were chosen: growing the CLI by 4,321 lines moved `cli_lines` by exactly 4,321 and nothing else; growing each part by 250 lines moved `test_lines` by exactly 1,000 and nothing else; a stub asserting 7 more moved `assertions` by exactly 7; a 3-second stub moved `wall_seconds` and nothing else; `--serial` moved `mode` alone; and running the identical tree from a path under `.worktrees/` moved `frame` and `EXPECTED_ASSERTIONS` together (3082 → 3080). Every expected value was computed outside the code under test and matched. **The frame offset was then confirmed on the real corpus, not just on the constant**: the same tree run from a non-worktree path reports `assertions=3082 frame=checkout` against `assertions=3080 frame=worktree`, and the difference is entirely part 1 going 522 → 524 (524 passed, 0 failed) — exactly the one test the caveat names, in exactly the part that owns it. This check is here because the repository has twice shipped assertions that passed regardless of the code under test, and a status line printing the same figures whatever it is fed is decoration.
  - Verified under both `bash` and `zsh`, concurrent and `--serial`, producing byte-identical lines. The corpus set is built as an array and expanded `"${COST_FILES[@]}"` — zsh does not word-split an unquoted variable, so a space-joined file list would have counted nothing and reported a plausible-looking zero.
  - `test-aimi-cli.sh` gains output only: `522 / 636 / 951 / 971 = 3080` assertions, 0 failures, exit 0, unchanged in both modes, and all five suites stay green.

#### Changed

- **`test-aimi-cli.sh` now runs its four parts concurrently — ~2.2x faster (405s → 152s in one back-to-back pair, and see the spread below).** The dispatcher launches all four parts at once and aggregates them; `bash plugins/aimi-engineering/scripts/test-aimi-cli.sh` is unchanged for the caller — same tests, same per-part sections in the same order, same `522 / 636 / 951 / 971 = 3080` invariant, same exit semantics. **Serial is still one flag away: `--serial` (or `-s`, or `AIMI_TEST_SERIAL=1`)**, which additionally streams each part's output live instead of buffering it — the mode to use when bisecting an intermittent failure, when a part hangs and you need to see how far it got, or on a host where four concurrent parts would thrash. `--parallel`/`-p` forces concurrency back on when the env var is set.
  - **The measurement is A/B/A/B, not before-and-after.** Alternated on this 16-core host in a linked worktree — serial 382s, 278s, 287s, 278s, 405s; concurrent 128s, 129s, 130s, 129s, 128s, 129s, 129s, 152s. **The absolute times drift with whatever else the host is doing; the pairwise ratio drifts much less** — the five back-to-back serial/concurrent pairs gave 2.98x, 2.15x, 2.22x, 2.15x and 2.66x, so the figure quoted is the ratio and not either endpoint. The 382s is the first run against a cold page cache rather than a slower serial, and quoting *it* against the fastest concurrent run would have inflated the win to 3.0x. Load average was recorded either side of every run (1.1-3.9 throughout, on 16 cores) precisely because an earlier "44s improvement" in this same branch turned out to be a "before" run competing with other work.
  - **~2.2x and not 4x, and the reason is imbalance rather than anything serializing the parts.** A concurrent run finishes when its *slowest* part does, and the parts are nothing like quarters. One pair measured both sides directly: serially 54s + 88s + 162s + 101s for a 405s wall; concurrently 42s / 72s / 152s / 104s for a 152s wall — **exactly part 3's own runtime**, and that equality held to the second on every concurrent run measured (three consecutive runs walled 173s / 125s / 129s against a part 3 of 173s / 125s / 129s). Part 3 (`roadmap-forge`) is 40-46% of the serial total, and 1/0.43 is about the ratio observed. More cores buy nothing from here, so the summary now prints each part's wall time beside its counts; the next real speedup is moving tests out of part 3.
  - **Three specific ways a parallel runner reports green while something is broken, each closed rather than assumed away.** Counts never come from stdout — each part writes `<passed> <failed>` to its own result file and the aggregate sums those, so interleaving cannot corrupt it. Exit status never comes from a bare `wait` — each part's status is recorded to its own file by the wrapper that ran it and read back per part, and a part that produced *no* status file counts as broken rather than as a pass. Output never interleaves — each part's stdout and stderr go to their own file and are replayed under that part's `>>> Part N` header once every part has finished, so a bare `Expected:` line is never orphaned. The cost of buffering is that a concurrent run prints no assertions until the parts finish; that is what `--serial` is for.
  - **Every part was proven to fail the aggregate, not just the first.** One assertion was broken in each of the four parts in turn and the full concurrent suite re-run each time: all four gave exit 1, `3079 passed, 1 failed`, the invariant still satisfied at 3080, the owning part named by filename, and the `Expected: MUTANT` line sitting between the correct part's header and the next one. This check exists because a runner that propagates part 1's failure but swallows part 4's is invisible on a green run. The dispatcher's own edge branches were exercised separately against stub parts: a part exiting non-zero with no failed assertion, a part writing no result file, and a part killed hard enough that no exit status was ever recorded — all three exit 1 and say which part and why.
  - **Repeatability was checked, because one green concurrent run cannot tell "isolated" from "got lucky on the interleaving".** Seven concurrent and three serial runs produced byte-identical per-part counts — 522 / 636 / 951 / 971, zero failures, every time.
  - **`test-worktree-manager.sh` is deliberately untouched and stays serial.** Its five `serve` assertions collide on a fixed port (22 passed / 5 failed under two concurrent runs, against 27 / 0 serially). Concurrency here applies to `test-aimi-cli.sh` only.
  - **One portability fix fell out of the work.** `SCRIPT_DIR` resolved through a bare `${BASH_SOURCE[0]}`, which zsh does not have; under `set -u` that aborted the expansion, left `SCRIPT_DIR` pointing at the caller's cwd and reported all four parts as missing files. It is now `${BASH_SOURCE[0]:-$0}`, and the runner was verified under both bash and zsh in both modes. The job-tracking uses no `mapfile`, no `readarray`, no associative arrays and no numeric array indexing — per-part state lives in per-part files keyed by index, which needs none of them.
  - **The PID-recycling caveat from the audit still stands and is still unreproducible here.** `test_roadmap_claim_stale_release` needs a killed PID to keep reading as dead, and concurrency burns PID space about four times faster. This machine's `pid_max` is 4,194,304, so it did not and could not happen; it remains the first thing to suspect if that one assertion ever goes intermittent on a small-`pid_max` host, and `--serial` is the way to confirm.

- **The four `test-aimi-cli` parts are cleared to run concurrently, and the one resource they all wrote is now per-part.** Every class of shared resource was audited per part; the verdict is *safe to run concurrently* for all four, and no part has to stay serial. Serial baseline and three concurrent runs give byte-identical per-part counts — 522 / 636 / 951 / 971 = 3080, zero failures, every time — at 9m04s serial versus 3m32s concurrent.
  - **Fixed: `~/.config/aimi/cli-path` was a file all four parts wrote.** `cmd_init_session` and `check-version --fix` both call `write_global_cli_cache`, and most of their ~120 call sites across the parts redirect nothing, so the write landed in the developer's own global CLI-path cache. Both halves were measured rather than inferred: a full suite run rewrote that file (120 → 107 bytes, repo path → plugin-cache path) from part 1's `check-version --fix`, and a direct A/B probe confirmed `init-session` writes it too whenever the CLI under test is *not* worktree-resident — which is every normal checkout, and therefore all four parts. No assertion ever read the value, which is why this never failed a run; it was still one file four concurrent processes wrote, and it silently repointed the machine's global cache on every run. `test-aimi-cli-common.sh` now exports `AIMI_CONFIG_DIR` to a per-part directory inside that part's own `TEST_DIR`, and the four teardown helpers in part 1 that used to `unset` it restore it instead — unsetting handed the remainder of the part back to the real `~/.config/aimi`. It is a default, not an override: `_aimi_config_dir` reads the variable, so a test that exports its own still wins.
  - **The audit was required to fail before its clean result was believed.** A cross-part collision was planted deliberately — parts 2 and 3 each writing a token to one fixed `/tmp` path and asserting at the end that it still held their own — because a clean sweep that has never been shown to detect anything is not evidence. Serially the collision is invisible: part 2 reports 637 passed / 0 failed and part 3 952 / 0, both green. Concurrently part 2 fails with `Expected: part2 / Actual: part3` and exits 1. The probe was then removed; this entry is the record that the method detects a real collision, in the same spirit as the suite's own mutation checks.
  - **Per-part verdict, by resource class.** (a) **Fixed ports: none, in any part.** Nothing binds, listens or connects; the only four-digit `:NNNN` matches are `ssh://…:2222` inside git-remote URL *strings* that `git remote add` never dials. This is precisely the class that makes `test-worktree-manager.sh` not parallel-safe — five `serve` assertions colliding on one port, 22 passed / 5 failed under two concurrent runs versus 27 / 0 serially — and it does not exist here. (b) **Fixed filesystem paths: none that reach disk.** The ~60 `/tmp/<name>.$$` stderr files carry the part process's own PID; the remaining literals (`/tmp/custom-claude`, `/tmp/custom-xdg`, `/tmp/custom-aimi`, `/tmp/opencode-test`, `/tmp/evil/…`, `/tmp/hacked/…`, `/tmp/nonexistent-tasks.json`) are *values* handed to pure resolver functions or written as file *content*, never created — all eight were confirmed still absent after a full run, so there is nothing for a second run to collide with. (c) **Shared state files:** `.aimi/state/` is touched only by part 3 and only under its own `TEST_DIR`; `dev-server.json` appears nowhere in the suite; `models.json`, the models prompt marker and the `forge-account-*.json` store are reached only through call sites that already redirect `AIMI_CONFIG_DIR`; the global CLI-path cache was the sole exception, fixed above. (d) **Git operations: zero against a shared repository.** All 16 `git init`, 3 `git clone`, 67 `git checkout` and 31 `git commit` run inside per-test `mktemp -d` fixtures, every bare `git init` is preceded by a `pushd` into one, nothing writes `git config --global`, and no test touches the repository under test. The 132 `mktemp -d` calls are *not* the argument — worktree-manager has them too and is still unsafe; the argument is that the four classes above were each checked by name.
  - **One environment-conditional risk that this machine cannot reproduce.** `test_roadmap_claim_stale_release` starts `sleep 30 &`, kills it, and requires the CLI's liveness check to see that PID as dead. Four concurrent parts consume the PID space roughly four times faster, so on a host with a small `/proc/sys/kernel/pid_max` a recycled PID could make the dead claim look alive and fail that assertion. This machine's `pid_max` is 4,194,304 against a few tens of thousands of forks per run, so it did not and could not happen here; on a 32,768-PID host it is the first thing to suspect if that one assertion ever goes intermittent.

- **`test-aimi-cli.sh` is now a dispatcher over four part files instead of one 28,261-line script.** `bash plugins/aimi-engineering/scripts/test-aimi-cli.sh` is unchanged for the caller — same command, same section/assertion stream, same exit semantics — but it now runs `test-aimi-cli-part1-core.sh`, `-part2-planning.sh`, `-part3-roadmap-forge.sh` and `-part4-forge-verbs.sh` in series and aggregates their counts. The original 178-line preamble — seven helpers: the `assert_*` family, `setup`, `cleanup`, `_test_claude_config_dir` — moved verbatim to the 179-line `test-aimi-cli-common.sh`, which every part sources; the 15 fixtures that more than one part needs moved to `test-aimi-cli-fixtures.sh`. Each part resolves the CLI under test with `CLI="$SCRIPT_DIR/aimi-cli.sh"` relative to its own location, gets its own `mktemp -d` `TEST_DIR` and its own `trap 'rm -rf "$TEST_DIR"' EXIT`, and can be run standalone for a focused loop.
  - **The check that a 27,000-line move was faithful is an assertion count, and the dispatcher asserts it in its own output.** All 687 top-level functions were moved byte-for-byte, each to exactly one file, and `main()`'s call order is preserved within each part and across the four. The four parts sum to 522 + 636 + 951 + 971 = 3080 assertions, 0 failures — identical to the single file's count measured in the same tree. The count is environment-aware for exactly one reason, and the dispatcher encodes it: `test_init_session_writes_global_cache` emits ONE assertion when the CLI under test is worktree-resident (`write_global_cli_cache` refuses to cache a `*/.worktrees/*` path) and THREE otherwise, so the same tree reads 3080 from a linked worktree and 3082 from a normal checkout. Comparing a before number taken in one frame against an after number taken in the other appears to lose or gain two tests when nothing changed.
  - **The earlier measurement that motivated this split is wrong by roughly 8x at the top end, and the correction matters more than the split does.** The `validate-tasks` entry below reports 20 trivial command substitutions costing 22ms from a 2-line script and 210ms from a 28,000-line one — 10.5ms each. Re-measured here with the timer inside the loaded script, so script load and parse are excluded and only fork cost is timed (median of 7 runs, 200 substitutions each): a `$(:)` substitution costs 0.40ms from a 10-line script, 0.55ms from a ~6,700-line part and 0.76ms from the 28,267-line monolith; with an exec (`$(/bin/true)`) 0.76 / 0.98 / 1.25ms; with a pipe, and therefore two forks, 1.33 / 1.74 / 2.37ms. **The direction of the earlier finding holds — fork cost really does scale with the parent script's size, at roughly 250-280µs per fork saved by going from 28k lines to 7k — but the magnitude does not.** The 2-line floor agrees with the earlier figure; the 28,000-line number does not, which points at the earlier harness having timed the script's ~27ms parse alongside the substitutions rather than at a machine difference.
  - **The predicted ~23-second saving does not exist, and the suite is not measurably faster.** Corrected arithmetic — ~270µs saved per fork across the suite's 3,269 command substitutions plus the extra fork each pipeline stage costs — predicts single-digit seconds, not tens. Measured end to end, alternating the two implementations back to back on an otherwise idle machine: monolith 490.7s and 498.5s, split 500.2s and 487.1s. The difference is ~1s against a ±6s run-to-run spread, i.e. indistinguishable from zero, exactly as the corrected model says it should be. The first before/after pair taken during this work showed 542.8s → 498.4s and looked like a 44s win; it was not, it was the "before" run competing with other work on the same machine. Per-process parse cost moved slightly the other way and is also small: 26.6ms once for the monolith versus ~9ms four times for a part plus its preamble.
  - **Splitting is still worth doing, for reasons that are not serial speed.** Each part is runnable on its own for a focused loop, a 28,000-line file becomes four navigable ones, and running the parts in parallel — the actual saving, and a separate change — is only possible once they are separate processes.
  - Adding a test now means adding it to the part that owns that concern (each part's header lists its sections in the order the single file ran them) and raising `EXPECTED_ASSERTIONS` in the dispatcher. That constant is deliberately load-bearing: it is what makes a lost, duplicated or silently skipped test fail the run rather than pass quietly.

- **`validate-tasks` runs ~6x faster: 485ms → 75ms.** The verb read eight scalar `metadata` fields — `schemaVersion`, `designBundle.designSpec`, `prototypePaths` length, `frontendOnly`, `designBundle.businessSpec`, `execution`, `phase` presence and `branchName` — through eight separate `jq` processes against the same document. They are now one `jq` call emitting all eight. No validation rule changed: the same errors are produced, in the same order, with the same exit codes.
  - **The saving is 410ms, not the ~126ms that process-startup arithmetic predicts, and the gap is the finding.** A `jq` process costs ~18ms to start and ~1ms to read a 46KB tasks file, so seven fewer of them should have bought ~126ms. Measured on this repo: **a command substitution forks the entire parent shell before it execs anything, and that fork costs in proportion to the parent script's size.** Twenty trivial substitutions cost 22ms from a 2-line script, 85ms from a 15,000-line one, and 210ms from a 28,000-line one. `aimi-cli.sh` is ~15,400 lines with ~880 substitutions, so every subprocess it spawns is roughly four times more expensive than the same subprocess spawned from a small script. The monolith is not only a ~15ms parse cost per invocation — it is a multiplier on every process the CLI starts.
  - **The delimiter is `\037` (ASCII unit separator), not the tab `@tsv` emits, and that substitution is the correctness argument rather than a detail.** A tab is IFS *whitespace*, and bash collapses runs of IFS whitespace into one delimiter — so two adjacent empty fields (the common case: no `designBundle`, no `execution`) silently vanish and every later value lands in the wrong variable. The first version of this change shipped exactly that bug: `prototype_count` received `false`, `business_spec_rel` received the branch name, `branch_name` came back empty. Every field uses `// ""` rather than `// empty` for the same reason — `empty` emits no field at all, which shifts the alignment jq is being asked to guarantee.
  - The arity assertion checks what **the shell parsed**, never what `jq` emitted. The broken first version passed a jq-side field count of 8 while the shell-side split had already dropped two fields; a check on the producer cannot see a defect introduced by the consumer.
  - Verified by an 11-fixture differential harness comparing the old and new implementations byte for byte across every field present and absent, plus schema-too-old, invalid branch name, invalid `execution`, `phase`+`execution` conflict, and bad `verification.url`. The harness was then mutation-tested twice — swapping two fields in the batch, and reverting the delimiter to tab — and caught both.

#### Fixed

- **A release heading had been silently destroyed by a merge, and was restored.** `b96b4a2` wrote that heading; merge commit `708ab45` (PR #96 into `feat/forge-abstraction`) resolved the CHANGELOG conflict by keeping both sides' bodies and dropping the single `## [...]` line that existed only on the phase-3 side. No body text was lost — only the heading — so the branch spent phase 4 with `plugin.json` and `marketplace.json` claiming one version while `CHANGELOG.md`'s top released heading named the one before it, and a whole release's text sat orphaned under `## [Unreleased]`. **The exact failure the release story exists to prevent had therefore already happened once, silently.** The restored section was diffed against `git show b96b4a2:CHANGELOG.md` and is byte-identical to what that phase had written. (Both headings were later folded into this single release — see the note at the top — but the accident and its lesson predate that consolidation.)
  - **The dropped heading had also swallowed a phase-4 entry, which is the part a version-string check would never have caught.** With that heading gone, the last `### Fixed` under `## [Unreleased]` belonged to the previous release, so `6f9a259` — phase 4's fail-open-guard fix — appended its release note into the previous release's section. Restoring the heading is what made that visible; the entry was moved to the phase that produced it. The duplicated `### Added`/`### Changed` pairs under `[Unreleased]` were the same seam and were deliberately **not** consolidated: merging them would have folded the GitLab adapter's notes into the Gitea adapter's and erased the boundary between two releases permanently.

- **The remaining seven `grep -v … | grep -q …` guards in the aimi-cli test suite are gone, and each one was measured going red rather than declared fixed.** The phase-3 entry above fixed the two export guards; a catalogue of seven more of the same shape was carried forward. All seven now count with `grep -c` — `hits=$(… | grep -v '^[[:space:]]*#' | grep -cE '…') || hits=0` followed by an `assert_eq` on a **number** instead of a branch on a corruptible boolean. Six are in `test-aimi-cli-part3-roadmap-forge.sh` (the credential-shaped-flag scan, the `jq -n` document-rebuild check, the three `--record`/`--reselect`/`--check` write-containment guards, and the whole-file `--identity` scan); the seventh is the `_detect_forge` jq control in `test-aimi-cli-part4-forge-verbs.sh`.
  - **Only one of the seven was actually failing open, and the entry says so rather than tarring all seven with the worst case.** The whole-file `--identity` scan reads all 15,440 lines of `aimi-cli.sh` — far more than a 64 KB pipe buffer — so `grep -q` reliably exited while `grep -v` was still writing. **Measured in-suite as a before/after pair, not reasoned about:** with a real code line `_aimi_identity_flag_probe="--identity"` planted on line 3 of `aimi-cli.sh`, the old form printed a **green** mark (951 passed, 0 failed) with the violation sitting in the file; the counting form printed **red** against the identical tree. The plant has to sit near the *top* of the file — `grep -q` must exit while thousands of lines are still queued or there is nothing left to SIGPIPE, and a bottom-of-file plant would have proved nothing.
  - **The other five scan a `printf` of a single function body, which fits the pipe buffer, so they were probably still reporting correctly today.** They were the defective *shape* carrying a latent defect, not a live failure — they would have begun failing open silently the first time one of those bodies outgrew the buffer. All five went red under a planted violation both before and after the change; what the change buys is that they can no longer stop being able to.
  - **The seventh is fail-CLOSED, and calling it fail-open would have been a fresh false claim replacing an old one.** The `_detect_forge` control has inverted polarity — a match is its *green* case — so a SIGPIPE there produces a spurious **failure**, not a spurious pass. It cannot be proven by planting, since the property it checks is already true; it was proven by temporarily retargeting its `sed` range at `_detect_forge_type()` (the function the loop above it proves jq-free), which turned it red as the only failing assertion in the part, and then reverted. Its converted form maps the count to a `present`/`absent` verdict because `assert_eq` cannot express "> 0".
  - **The `grep -v '^[[:space:]]*#'` comment filter is load-bearing at every site that had one and was kept.** `--identity` appears exactly twice in `aimi-cli.sh` and *both* occurrences are comment lines, so dropping the filter would have pinned that guard permanently red.
  - **Assertion delta: zero**, and `EXPECTED_ASSERTIONS` is untouched. Each converted site incremented exactly one counter before and `assert_eq` increments exactly one after, so the conversion is 1:1 — part 3 reported 951 total assertions both before and after the change. Three categories that resemble the defect were left byte-for-byte alone: the deliberate demonstration at `part4:4621` (converting it would destroy the proof that the discarded shape reports ABSENT), five comment lines that name the forbidden shape while explaining why it is wrong, and roughly fifty single-`grep -q` sites that share the SIGPIPE mechanism but not the double-grep shape and are all fed by small inputs.

- **`forge-contract.md` told a future Gitea adapter author to implement the WRONG behaviour, and that ruling is now deleted rather than softened.** The State Mapping section stated that `tea` "does not expose a distinct `merged` value the way GitHub's and GitLab's do", that "a merged PR reads as `closed` under `tea`'s own field list", and — the operative line — that an adapter "until then should normalize `tea`'s `closed` straight through as `\"closed\"` rather than guessing `\"merged\"`". Following that instruction produces a pull request that still reports `closed` after it was merged. Source falsifies the premise: `formatPRState` (`gitea/tea` `modules/print/pull.go:95-100`) prints the literal string `merged` whenever `pr.Merged != nil` on the LIST path, and the DETAIL path carries a raw `open`/`closed` `state` (`cmd/pulls.go:33`) alongside a `hasMerged` boolean and a `mergedAt` timestamp (`cmd/pulls.go:46,47`). The contract now describes the LIST-vs-DETAIL split with those citations and names the derivation this phase actually shipped — read `hasMerged`, emit `merged`, pass an absent key through untouched — recording that it lives in the adapter (`_forge_map_pr_state_gitea`) rather than in `_forge_map_state`, which is handed one raw value and no document and so cannot reach a second key. **This is the one entry here that is not a staleness sweep**: the other corrections would have left a reader merely out of date, this one would have left them wrong.
- **Four places under `commands/` still claimed GitHub was the only forge backend, false since phase 3.** `forge-contract.md`'s Consumed-by paragraph ("GitHub is the only adapter shipping in phase 1"), its `no_adapter` enum row and its Degradation Contract opener ("phase 1 ships GitHub only" / "ships only GitHub"), plus `open-pr.md`'s opening sentence ("GitHub is the only adapter this verb ships in phase 1"). Each now states what ships today, and `no_adapter` is described as what it has become in practice — `detect-forge`'s `unknown` verdict, since all three named forges are routed. **Guarded mechanically, not by eye:** a new test counts the extended regex `only adapter|phase 1 ships|ships in phase 1` across `plugins/aimi-engineering/commands/` and asserts **0**. That zero is earned before it is believed — one assertion first plants a deleted sentence back into a copy of `forge-contract.md` and requires the same reader to return ≥ 1, and a second requires a pattern known to be present (`Gitea/Forgejo`) to count non-zero over the real directory, proving the traversal reaches files at all. The reader uses the counting form (`count=$(grep -rE … | grep -c '^') || count=0`) with every variable quoted and nothing redirected to `/dev/null`: an unquoted list variable under zsh is passed as one argument and matches nothing, and `2>/dev/null` then hides the error, which is how a clean-looking zero proves nothing.
- **Four `cmd_help` blocks disagreed with the code that produces them — and two of them were never right rather than merely stale.** `forge-pr-view`'s help advertised `--include reviews` and `--include comments`, neither of which is a valid field: the verb exits 1 on both, while the two it actually accepts (`isDraft`, `mergeable`) went unlisted. Its documented output key was `evidence`; `_forge_pr_view_emit` emits `message`. Both are now read out of the code that produces them — the allowlist from the validator, the key from the emitter. Alongside those, `forge-pr-view`'s "Only github ships in this phase" clause, `forge-repo-info`'s "via a single `gh repo view` call" phrasing and its `source ("gh"|"local-parse")` enumeration (missing `"glab"`), `forge-auth-status`'s "(gh missing, or the forge has no adapter)", and the "GitHub only in phase 1" line on all six remaining forge verbs now name every backend that ships. `forge-repo-info` deliberately advertises **no** `"tea"` source value, because that tier was intentionally not written: `tea` has no "show THIS repository as JSON" command, so Gitea resolves correctly through the local-parse tier and a Gitea arm would ask `tea` about an answer it had already parsed. **Every help assertion reads `--help` STDOUT, not the source file**, so what is pinned is what a user actually reads, and each is scoped to its own verb's block — `evidence` is a legitimate key in `verify-creates`' help further down the same output, and an unscoped check on that word could have been satisfied, or defeated, by a block this work never touched. A control assertion states exactly that: `evidence` still counts non-zero in the full output while counting zero in the sliced block.
- **Two smaller corrections in the same file, folded in because they sit in the text being edited.** The contract's identity rule ("whatever identity value is used, it is passed to a forge CLI only via an environment variable, never as a command-line argument") collided with its own statement two lines above that `tea` supports identity selection via `--login <name>`, which *is* a command-line argument. The rule is now scoped to **credentials** — its actual purpose is keeping tokens out of `ps`, and a `--login` name carries no secret — with the collision resolved explicitly rather than left for the next reader to trip over. The rule is narrowed, not deleted, and no shipped verb passes `--login` today. Separately, the contract's account-selection bullet said only that `glab` "cannot match this exactly"; phase 3 established something more specific (`aimi-cli.sh:5058-5106`) — `glab` has no `auth token` subcommand at all and its store is `ScopePerHost` — which is now recorded as the reason.
- **46 assertions added to `test-aimi-cli-part4-forge-verbs.sh`**, all green, behind a `gtd_`/`GTD_` private namespace disjoint from every sibling prefix in this phase. Every content assertion states a NUMBER compared with `assert_eq`; the section contains no `grep -q` inside an `if`, the shape that fails **open** under `set -o pipefail` by SIGPIPE-ing its left half. New tests went into part 4 rather than part 3 because the four parts run concurrently and part 3 is the wall clock. The scope guard was mutation-checked: planting the stale claim back into `open-pr.md` turns two named assertions red.

### Phases 2 and 3 — forge account selection, and the GitLab adapter

> Two phases of forge abstraction, released together: **phase 2 — forge account selection** (which account a repository writes as) and **phase 3 — the GitLab adapter** (a second forge behind the same verbs). Phase 2 shipped in code but was never released; its four entries sat under `[Unreleased]` while phase 3 was built, and both are rolled up into this one bump.


**Read this before trusting the GitLab adapter in production — the verification ceiling.** `glab` **is not installed on the machine this release was developed on.** Every GitLab flag, subcommand and JSON key below was read off glab's own documentation and its Go source (`gitlab-org/cli`, read 2026-08-05) and was **never observed coming out of the real binary**. That is a strictly weaker claim than the GitHub half of this same release can make: phase 2's work was verified against a real `gh` v2.94.0 before a line of it was written. Treat the GitLab field mappings as documented-but-unobserved — the first run against a real `glab` is the one that confirms them. The ceiling is recorded in `aimi-cli.sh` at each GitLab section it applies to, not only here.

**Two of the GitLab verbs are marked EXPERIMENTAL by glab itself.** `glab mr note list` and `glab mr note resolve` — the commands behind `forge-pr-review-threads` and `forge-resolve-review-thread` on GitLab — are both documented upstream as "an experiment and is not ready for production use. It might be unstable or removed at any time." They are routed anyway, because having no automatic review-thread handling on GitLab is worse than having one whose upstream is still settling. This is a disclosure so you can decide for yourself, not a sign the routing is unfinished.

**The remembered forge account does NOT apply to GitLab writes.** Answering the forge-account question governs every GitHub write in this release; on GitLab it governs nothing, because `glab` has no `auth token` subcommand and no per-account credential model at all — its token is scoped per **host**, not per login (`Scope: ScopePerHost`, verified in `gitlab-org/cli` source). A GitLab user whose `glab` session is logged in as the wrong account therefore has `glab auth login` or an exported `GITLAB_TOKEN`, and nothing else. This is the degraded branch the phase contract explicitly permitted, not a defect; the `### Changed` entry below records where the reason lives in the code.

#### Added

- **A per-repository forge account store path, resolved outside the repository and stable across every worktree.** New internal helper `_forge_account_store_path` in `aimi-cli.sh` returns `<aimi config dir>/forge-account-<key>.json` — one file per repository, under `$AIMI_CONFIG_DIR` / `${XDG_CONFIG_HOME:-~/.config}/aimi` via the existing `_aimi_config_dir` resolver, so a remembered forge account is never committed, never shared with the rest of the team, and never inherited by a sibling repository. The key is the SHA-256 of the repository's absolute git common directory, produced by the same `_default_branch_cache_key` helper the per-repository default-branch cache already uses; no second hashing scheme was introduced.
  - **Keyed on `git rev-parse --git-common-dir`, not `--show-toplevel`.** `--show-toplevel` answers with the *worktree* path, so every `.worktrees/<branch>` checkout of one repository would hash differently and be asked for its account all over again. The common directory is the one `.git` both the main checkout and every worktree share, which is what makes "asked once, remembered thereafter" true for a repository that uses worktrees.
  - **The hashed value is guaranteed absolute before it is hashed.** Bare `git rev-parse --git-common-dir` answers *relatively* — `.git` from a toplevel, `../../../.git` from a sub-directory — so hashing it raw would hand every repository on the machine one shared key whenever the CLI ran from a toplevel, and would also change one repository's key depending on which sub-directory the command ran in. `--path-format=absolute` (git ≥ 2.31) is used first; older git falls back to the bare form joined against the current directory and normalized through `resolve_path`, which produces a byte-identical key.
  - **Outside a git repository the helper returns non-zero and prints nothing** rather than falling back to a hash of the empty string, which would have become a single global "no-repo" store every non-repository caller wrote into. Callers read the non-zero return as "no remembered answer, proceed on the active account".
  - The document at that path is a JSON object **keyed by forge host**, because one repository can carry remotes on more than one host. Writers must read the existing document and merge into it; rebuilding it with `jq -n` would drop every other host's entry, the exact defect fixed in 1.97.2 for `models.json`.

- **`aimi-cli.sh forge-account-select` — ask which forge account a repository writes as once, and be able to change the answer.** One verb owns three operations on the store above: `--record <login>` and `--record-active` persist an answer, `--check` reads it back and decides whether the question is warranted at all, and `--reselect` forgets it. Reselect is a **flag on this verb, not a second verb**. The verb does not prompt — per `commands/references/interactivity.md` the command layer asks and the CLI decides and remembers, because the CLI is invoked with a non-TTY stdin and a prompt implemented inside it would be silently dead under Claude Code. Exactly one mode is required; two modes, or none, exits 1 naming the valid modes. No `--token`, `--identity` or otherwise credential-shaped flag exists, matching every other forge write verb.
  - **`--record-active` stores "always use whichever account is active" as a real answer**, carrying a `mode` discriminator (`{"mode":"active"}` versus `{"mode":"account","account":"<login>"}`) so a later `--check` can tell "the user chose the active account" apart from "the user has not been asked". Encoding that opt-out as an empty account string, or by omitting the entry, is refused on both the write and the read side — neither is distinguishable from absent, which is the one property the answer must not have.
  - **`--check` decides on this repository's own entry, never on the store file's existence.** The store exists the moment the first repository answers, so an existence check would silence every repository afterwards — the shape of the 1.93.1 defect where `models-prompt-check` returned `skip` whenever `models.json` existed even with the current host's sub-table missing. A store that is absent, present without this host's entry, empty, or malformed all yield the ask decision; malformed input prompts rather than skipping silently.
  - **The recorded answer is revocable, and it is the only state.** `--reselect` clears this repository's entry so the very next `--check` asks again, and deleting the store file by hand does exactly the same — there is no companion marker or sentinel that survives the answer's deletion. That is the 1.93.0 defect where the models marker "suppressed the prompt even after the config was deleted, leaving the user silently stuck on all-inherit defaults with no way to re-trigger the prompt short of also deleting the marker", designed against rather than re-shipped.
  - **Every write is read-merge-write; no path rebuilds the document with `jq -n`.** Recording or revoking one host's answer leaves every other host's entry byte-for-byte intact, timestamp and mode discriminator included. `--reselect` is the trap — writing the file back without the entry is the obvious implementation and it destroys every sibling — so it is a `del` merge, not a rebuild. This is the 1.97.2 `detect-models` defect (it "wrote a fresh document via `jq -n`, silently dropping the inactive host's configured models on every invocation") applied to a second multi-entry document.
  - **`--check` has zero side effects** — it creates no store file, creates no config directory, chmods nothing, and leaves a pre-existing store byte-identical. That is the mechanical guarantee behind the agent-mode rule: an auto-selection made under `AIMI_AGENT_MODE`/`CI` is applied for that invocation and never persisted, so one unattended run cannot permanently answer the question for every human afterwards. Persisting is always a separate, explicit `--record*` call.
  - Writes go through a single locked path combining the two precedents already in the file: `roadmap-init`'s `flock` + `mktemp`-then-`mv` atomic swap, and `write_aimi_models_config`'s create-then-restrict-then-write ordering, with `chmod 0600` applied **before** any content is written — load-bearing for a file that names accounts. The current document is re-read inside the lock, so a concurrent writer cannot slip between the read and the write.
  - `--check` also skips, recording nothing, when `AIMI_FORGE_IDENTITY` is set: an explicitly requested identity makes the question moot, matching the file's existing env-over-stored precedence.

- **The forge account question is now actually asked — from the command layer, once per repository, and never answered on your behalf by an unattended run.** `/aimi:open-pr`'s Step 1a and `/aimi:execute`'s phase PR-creation step each show a picker offering "always use the active account", the account your project's git identity points at, any further logged-in accounts, and a free-form `Other`. The selected answer is handed to `forge-account-select`'s record path; the command layer owns the prompt and performs no file I/O of its own. In multi-repo phase runs the question is asked once **per participating repository**, naming the repository so separate prompts stay distinguishable.
  - **Gated on a two-condition AND, so it is asked at most once and only when it matters.** The picker appears only when `detect-interactivity` returns `picker` *and* `forge-account-select --check` returns `decision: "ask"` — that is, this repository has no recorded answer for its own host *and* its git identity genuinely diverges from the active forge account. Every other case proceeds silently on the active account. This is the same shape as the shipped first-run model-selection prompt.
  - **In agent mode the answer is applied for the invocation and NEVER persisted.** Under `--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`, each site auto-selects "use the active account" — which takes no action at all, since that is already the account every forge verb uses — and makes no record call whatsoever, leaving the store byte-for-byte as it was. The transcript says so explicitly: `agent-mode: forge-account auto-selected active account (not recorded)`. This matters because that auto-answer is *also* the permanent opt-out: persisting it would let one CI run silently and permanently answer the question for every human afterwards, who would never be asked and would have no way to discover why — the shape of the 1.93.0 unrevocable-dismissal defect.
  - **Two callers can apply a stored answer but can never ask.** `skills/resolve-pr-parallel/scripts/get-pr-comments` and `resolve-pr-thread` are plain shell scripts with no picker on either host, so a repository whose answer was never recorded runs those two paths on the machine's active account. This is stated in `commands/references/forge-contract.md` rather than left to be inferred; it matches phase 1's degradation posture and is resolved by answering the question once at either ask site.
  - The pickers live in translated command bodies, not in `commands/references/`: reference files are copied verbatim by `install.sh` and skipped by both command-install loops, so a picker written there would reach OpenCode still naming `AskUserQuestion`, a tool that host does not have. `translate_command_body` was sourced in isolation and fed both new picker paragraphs, which came back as `Use the **question** tool`.

- **Every forge write now actually runs as the account this repository remembered — including the reads those writes make internally.** The store, the verb and the picker above decided *which* account; this is the wiring that applies it. All four write paths in `aimi-cli.sh` are routed through the per-invocation override: `gh pr create` (`_forge_pr_create`), `gh pr edit` (`_forge_pr_edit`), `gh issue create` (`_forge_issue_create`) and the `resolveReviewThread` GraphQL mutation (`_forge_resolve_review_thread`). **What changes for you:** open a PR, edit a PR body, file an issue or resolve a review thread from a repository whose account you answered for, and it is attributed to that account instead of whichever account happens to be active on the machine — with no `gh auth switch` anywhere, so your machine's active account is exactly what it was before the run.
  - **The reads a write makes as part of the same operation are routed too, and that is correctness rather than tidiness.** `forge-pr-create`'s pre-create idempotency lookup and its post-create structured re-read, plus `forge-pr-edit`'s post-edit re-read, all run under the same account as the write. On a **private** repository the account that creates a PR can see it while a different reader account cannot, so a re-read performed as the machine account would fail against a pull request that had just been created successfully. One logical operation now stays on one identity.
  - **`forge-pr-view` invoked directly as its own verb is deliberately NOT routed** and stays a plain machine-account read. Only the reads made *inside* a write operation inherit the account.
  - **The token is a bash prefix assignment on exactly one command, never an export and never an argument.** `env GH_TOKEN=… gh …` is excluded for the same reason a `--token` flag is: `env`'s own argv carries the value into the process table. Exporting it is excluded for a second reason — with `GH_TOKEN` set process-wide, `gh auth status` reports the env-token account as the active one, which would make `forge-auth-status` misreport your machine's active account and would blind the very check that proves nothing was switched. The regression suite asserts all of this from the token that actually arrived at each `gh` call, and the argv scan that already covered `forge-pr-create` and `forge-issue-create` now covers `forge-pr-edit` and `forge-resolve-review-thread` as well.
  - **The "always use whichever account is active" answer needs no branch, and an inherited `GH_TOKEN` is never blanked.** The opt-out and the never-answered case both resolve to an empty override and flow through the identical call shape, since `gh` treats an empty token variable as unset. A `GH_TOKEN` you exported before invoking the CLI still reaches `gh` untouched in that case — a recorded account outranks it, an absent one leaves it alone.
  - **The failure classifier now re-checks the account that actually failed.** The one `_forge_classify_gh_failure_reason` call that sits inside a write path (`forge-resolve-review-thread`'s) runs under the same override as the mutation it is judging; previously it would have re-checked the *machine* account's auth after a write failed as a different one, so an overridden account whose token had expired was classified against the wrong account entirely. No `reason` enum value was added and no failure posture changed: `forge-pr-create`/`forge-pr-edit` keep mandatory-print degrade with a non-zero exit, `forge-issue-create` keeps its soft-fail contract, and `forge-resolve-review-thread` stays quiet and always returns 0.
  - The account is resolved **once per invocation** rather than at each of the three or four `gh`-facing steps a single write makes, through a per-directory host memo warmed from the calling function's own shell — a memo populated inside a command substitution would die with that subshell. A routed write costs exactly one `gh auth token` process; the opt-out and the never-answered case cost none.

- **GitLab's merge-request vocabulary now has one named home instead of being re-derived at each call site.** New internal helper `_forge_map_pr_field_gitlab` in `aimi-cli.sh` answers, for each of the ten normalized PR contract fields, the key GitLab's own `glab mr view <ref> -F json` document uses for it: `number → iid`, `url → web_url`, `title → title`, `body → description`, `state → state`, `headRefName → source_branch`, `baseRefName → target_branch`, `isDraft → draft`, `mergeable → detailed_merge_status`. It sits immediately beside `_forge_map_pr_field_github` and copies its case-statement shape branch for branch, so the two adapters' tables stay diffable side by side — this is the arm that function's own header always named as "the single seam a later GitLab or Gitea adapter replaces". Nothing dispatches to it yet; it is the table every later routing story reads.
  - **`number` maps to `iid`, never `id`, and the distinction is not cosmetic.** GitLab carries both: `id` is unique across the whole instance, `iid` is the per-project number the user sees in the merge-request URL and types at the CLI. Mapping to `id` would produce a number that resolves to a *different* merge request, so the regression fixture deliberately gives the two different values and asserts the mapper picks the right one.
  - **A contract field GitLab has no equivalent for emits nothing at all**, the same silent-empty default the github mapper's case statement has, so a field this adapter cannot express is never passed through to `glab` as-is and never guessed at.
  - **`files` is that field, and it is a settled answer rather than an unresolved one.** `glab mr view -F json` carries no changed-file list whatsoever — it marshals go-gitlab's `*gitlab.MergeRequest` whole, and neither that struct nor the `BasicMergeRequest` it embeds has a changed-files field; the nearest thing is `changes_count`, a count *string*. A file list requires a separate call to `/merge_requests/:iid/changes` or `/diffs`, which `glab mr view`'s JSON path never makes. There is simply no key to name, which is why nothing is emitted.
  - **`mergeable` maps to `detailed_merge_status`, settled by absence rather than by preference.** There is no `merge_status` field on either struct at all — the only one in go-gitlab's merge-request source belongs to the unrelated `BlockingMergeRequest` type — so the older key never appears in a `glab mr view -F json` document. That agrees with GitLab's own deprecation of `merge_status` in 15.6. The value is an enum string (`"mergeable"`, `"not_open"`, …), not a boolean, matching the string shape `_forge_build_pr_json` already carries for GitHub's `MERGEABLE`/`CONFLICTING`/`UNKNOWN`.
  - **`isDraft` maps to `draft`, chosen deliberately rather than by absence.** Both `draft` and `work_in_progress` really are emitted, because glab marshals the entire struct; the tie is broken by go-gitlab's own `// Deprecated: use Draft instead` on the latter and by GitLab's matching API docs. The fixture carries both keys so the choice is exercised rather than assumed.
  - **`reviews` is not a contract field and was not added.** GitLab merge requests carry `reviewers` — people *assigned* to review — but have no equivalent of GitHub's `reviews` array of *submitted* `APPROVED`/`CHANGES_REQUESTED` verdicts, which GitLab models as approvals, a separate resource behind its own endpoint. Reviewers and reviews are not the same thing and the mapper answers for neither.
  - **`state` maps the key only.** GitLab's value vocabulary is its own (`"opened"`, not `"open"`); folding it stays `_forge_map_state`'s job, which already carries the gitlab arm that does exactly that.
  - **Declared verification ceiling:** `glab` was not installed on the machine this was written on, so no key here was observed coming out of the real binary. Every one is read off glab's own Go source and GitLab's API documentation — go-gitlab's struct tags *are* glab's JSON keys, precisely because glab marshals the struct rather than projecting it — and the evidence for each, line references included, is recorded in the function's header comment. The phase-2 GitHub mapper was verified against a real `gh` v2.94.0 before a line of it was written; this one cannot make that claim, and says so in place rather than leaving it to be discovered.
  - The regression suite gains a reusable fake-`glab` PATH stub alongside the existing fake `gh` — argv-recording, able to serve differing payloads across two calls — plus a falsifiability check that runs **before** any mapping assertion trusts it, proving the stub can turn a test red rather than rubber-stamping whatever it is handed. Every mapping was then mutation-tested: changing any single key, adding `reviews`, or making the stub ignore its own fixture each turns the suite red.

- **Reading a merge request, an issue, a repository or your auth state now works in a GitLab repository, with no per-project configuration.** The four forge READ verbs — `forge-pr-view`, `forge-issue-view`, `forge-repo-info` and `forge-auth-status` — dispatch to `glab` whenever `detect-forge` reports `gitlab`, where each previously returned `no adapter for forge "gitlab" yet`. This is the story that routes through the `_forge_map_pr_field_gitlab` table above; nothing else consults GitLab key names. **What changes for you:** in a repository whose origin is on gitlab.com, `/aimi:open-pr`'s existing-PR check, `/aimi:validate-bug`'s issue lookup, and every `.data.forge` the commands print now answer for real instead of degrading. Detection itself is untouched — `_detect_forge_classify_host` has classified `gitlab.com` and `*.gitlab.com` as `gitlab` since phase 1, and this story cites that rather than modifying it. Write verbs and review-thread verbs are **not** part of this change and still report no GitLab adapter.
  - **`-F json`, never a `gh`-style `--json <field-list>`.** The single most likely way to get a GitLab adapter wrong is to assume `gh`'s shapes carry over. `gh pr view --json number,url` *selects* which fields come back; `glab` has no field selector on any read command — its whole output interface is `-F, --output string  Format output as: text, json` plus `--jq string`, and its JSON path marshals the go-gitlab struct **whole**. So every call here asks for the entire document and picks keys out of it afterwards. The regression suite records glab's argv and asserts both halves: that `-F json` was passed, and that `--json` never was.
  - **A contract field GitLab cannot express is reported absent, never guessed.** `files` is that field — a `glab mr view -F json` document carries no changed-file list at all — so a `--include files` request comes back with `files: null` **and** `"files"` named in `unsupported_fields`, which is the contract's own mechanism for exactly this. Likewise `comments` on `forge-issue-view`: GitLab's discussion model does not answer the question GitHub's flat comment array answers, so the count is reported unsupported rather than invented from a differently-shaped resource.
  - **A merge request that does not exist is `not_found`, not `error`** — the same three-way status the GitHub path emits, and the whole reason this verb exists. Absence is detected **structurally**, by `glab mr list --source-branch <branch> --all -F json` returning `[]` at exit 0, so it survives a reworded glab release or a non-English locale; glab's own 404 wording is only a backstop for a numeric ref, where there is no branch to probe. When the probe positively confirmed the merge request exists and the view call then failed anyway, the result is `error` even if the stderr says 404 — a string cannot outvote a structural fact.
  - **`forge-auth-status` reports `gitlab` in `.data.forge`** and keeps its own found-or-error contract: a confirmed "you are not logged in" is `found` with `authenticated: false`, because the check *ran*; `not_found` never appears on any of its GitLab paths. The acting account is read from glab's `Logged in to <host> as <username>` line — glab has no per-host multi-account model and therefore no "Active account" marker to read, which is the one place the GitLab parse genuinely differs from the GitHub one.
  - **`forge-repo-info` gains a `glab repo view` primary tier and reports `source: "glab"` when it answers**, with the existing offline remote-URL parse still behind it, so a missing or failing `glab` degrades to exactly today's behavior rather than to nothing. A nested GitLab subgroup path (`acme/tools/widgets`) survives intact as `owner: "acme/tools"`, reusing the same splitter the offline tier already used for precisely that reason.
  - **A missing `glab` names `glab`.** Every one of the four verbs gates on the binary its *detected* forge needs, through the shared `_forge_bin_check` in its quiet mode, so a GitLab user is never told to install `gh`. `forge-issue-view` distinguishes this from the adapter-less case: reason `cli_missing` (the adapter exists, the binary does not) rather than `no_adapter`. This is the one criterion in this phase testable against reality, because `glab` genuinely is not installed on the machine this was written on.
  - **Internally, the found-envelope is now built once for both adapters.** `_forge_pr_view_github`'s inline field-projection block became `_forge_pr_view_build_found`, which the GitLab arm calls with the same arguments; the only per-forge knowledge left is a single mapper lookup and the `_forge_map_state` label. GitHub's emitted envelope is byte-for-byte unchanged — the whole pre-existing `forge-pr-view` suite passes untouched.
  - **Declared verification ceiling, restated because it still applies:** `glab` is not installed here, so no flag or key in these adapters was observed coming out of the real binary. Each is read off glab's own documentation and Go source — `-F/--output` and `--jq` on `mr view`/`issue view`/`repo view`, `--hostname` on `auth status`, `--source-branch`/`--all` on `mr list`, and go-gitlab's `*gitlab.Issue` / `*gitlab.Project` struct tags — and recorded in each function's header comment.
  - The regression suite gains a **private** fake-`glab` stub covering all five invocations these verbs make, in its own control-variable namespace. Before any routing assertion trusts it, a falsifiability check drives all four verbs end to end with a payload that *should* turn each one red and confirms it does; and each verb was then mutation-tested by unrouting it alone and confirming a specific named assertion goes red — four verbs, four distinct assertions, each mutation asserting its own patch actually landed. Three existing tests that used `gitlab` as their stand-in for "a forge with no adapter" now use `gitea`, which is what that phrase means today.
- **The three forge write verbs now open, update and file things on GitLab instead of refusing to.** `forge-pr-create` opens a merge request through `glab mr create`, `forge-pr-edit` updates one through `glab mr update`, and `forge-issue-create` files an issue through `glab issue create`, on any repository whose `detect-forge` resolves to `gitlab`. All three previously returned the `no adapter for forge "gitlab" yet` degraded envelope and did nothing. **What changes for you:** a run against a GitLab remote now ends with a merge request that exists, reported through the same `{status, data: {url, number}, message}` envelope the GitHub paths already emit, so a caller reads both forges' answers with one code path.
  - **Every glab write invocation carries `-y` (`--yes`), and that is the entire reason this entry exists as its own story.** `glab mr create`, `glab mr update` and `glab issue create` each *prompt* for a submission confirmation unless passed that flag; `gh pr create` has no such flag and needs none. So the habit carried over from the GitHub adapter next door does not produce an error here — it produces a **hang, forever, with no output explaining why**, in an autonomous run with nobody present to answer. A hang is the hardest failure in this system to diagnose, which is why `-y` is written first on every invocation, immediately after the subcommand, where a reviewer meets it before any other flag.
  - **The flag names are glab's, not gh's.** `-t/--title` and `-d/--description` (**not** `--body`), `-s/--source-branch` (**not** `--head`), `-b/--target-branch` (**not** `--base`), with the merge request passed to `glab mr update` as a **positional** argument. Each name is taken from glab's own published command reference rather than assumed from the GitHub side, and the regression suite asserts that none of `--body`, `--head` or `--base` ever reaches a `glab` process.
  - **`created` versus `unchanged` is decided by a check that runs as the same account the write will.** Before creating anything, the adapter looks up whether an open merge request already exists for the source branch; an **open** one is reported back as `unchanged` with its own `{url, number}` and no second merge request is opened, which is what makes a retried phase safe. A **closed, merged or locked** merge request on a reused branch does not block — a fresh one is opened, exactly as on the GitHub side. GitLab's own `"opened"` spelling is folded through `_forge_map_state`, so a fixture that spelled it `"open"` could not hide a missing fold.
  - **A *failed* existence lookup falls through to creation rather than degrading, and that differs from the GitHub arm on purpose.** `gh` has `gh pr list --head <branch> --json number`, a structural probe that answers "no PR" as `[]` at exit 0, so the GitHub arm can treat a failed lookup as a hard error. glab's `glab mr view <branch> -F json` exits non-zero *both* when the merge request does not exist and when the lookup itself failed, distinguishable only by matching its stderr prose — the exact fragility `forge-pr-view`'s not_found detection was made structural to avoid. Falling through is safe on GitLab specifically: GitLab refuses to open a second open merge request for the same source/target branch pair, so guessing wrong yields a loud failure from `glab mr create`, never a duplicate.
  - **With `glab` absent, all three verbs print the merge-request URL you can open by hand instead of erroring** — GitLab's `/-/merge_requests/new?merge_request%5Bsource_branch%5D=…&merge_request%5Btarget_branch%5D=…` form for a create, the merge request's own `/-/merge_requests/<iid>` page for an edit — together with a copy-pasteable `glab` command that itself carries `-y`, so a human who pastes it into an unattended script does not inherit the hang. The instruction says "merge request" and never mentions `gh`. Opening a merge request has no other fallback, so this print is mandatory rather than best-effort.
  - **`forge-issue-create` keeps its soft-fail contract on the GitLab branch**: it exits 0 on every outcome including degraded and reports what happened in the envelope's `status`, so a failed issue can never block PR creation. Giving the GitLab branch a different exit-code contract from the GitHub one would have silently reintroduced the coupling that verb exists to prevent. `forge-pr-create`/`forge-pr-edit` keep their opposite, hard-fail contract: non-zero on every degraded branch.
  - **Once a merge request's URL is in hand it is never thrown away.** If the post-create re-read cannot confirm the number, the verb still reports `created` with that url and `number: null` at exit 0, warning that only the number is unconfirmed — reporting it as `degraded` would null out `data` by contract and lead a caller to open a second merge request for a branch that already has one.
  - **The account override is deliberately *not* wired here**, because how `glab` accepts a per-invocation token is a question left open at planning time. What this ships instead is a landing site: every `glab` call is a single `_forge_capture … -- glab …` statement, so a bash prefix assignment can be added on the line directly above it without restructuring anything, exactly the shape phase 2 used for `GH_TOKEN`. A regression test pins that shape, and the section header states it in words so the later story finds a landing site rather than a refactor.
  - **Declared verification ceiling:** `glab` is not installed on the machine this was written on, so not one invocation here was observed against the real binary. What the tests actually prove is **which argv `aimi-cli.sh` emits** — which is the right thing to pin, since the defect being prevented is a missing flag and a missing flag is visible in argv. The `-y` assertions read the fake glab's **recorded argv**, never an exit status: a fake never prompts, so it exits 0 whether or not the flag was passed and an exit-status assertion would pass vacuously. A falsifiability check proves the argv reader can answer "no" before anything trusts it answering "yes", and each of the three write paths was mutation-tested by deleting its `-y` and confirming the suite turns red.
- **Reviewing a GitLab merge request now works the same way reviewing a GitHub pull request does.** `aimi-cli.sh forge-pr-review-threads` and `forge-resolve-review-thread` are routed to `glab` when `detect-forge` reports `gitlab`, replacing the `no adapter for forge "gitlab" yet` error envelope both verbs returned before. Listing runs `glab mr note list <iid> -F json --state unresolved`; resolving runs `glab mr note resolve <discussion-id>`. **What changes for you:** the resolve-PR workflow that could previously only read and resolve review feedback on GitHub now does both on GitLab, with the same `{status, data, message, reason}` envelope and the same exit-code contract — nothing branches on which forge it is talking to. Gitea/Forgejo remains unrouted and still answers `no_adapter`.
  - **The unresolved filter is applied by GitLab, not by us.** `--state` is `glab`'s own resolution-state filter, so the default call asks the server for the unresolved discussions rather than fetching every discussion and dropping the resolved ones locally; `--all` maps to `--state all`. The regression suite asserts this from the fake `glab`'s **recorded argv**, deliberately not from the returned list — a fake that served only unresolved items would make a client-side filter look exactly as correct as a server-side one, so the returned list cannot tell the two apart.
  - **GitLab's `discussion` becomes the contract's `thread` at the adapter boundary and nowhere else.** The word never reaches the emitted envelope: the key stays `threads`, notes become `comments`, `author.username` becomes `author.login`, `created_at`/`updated_at` become `createdAt`/`updatedAt`, and GitLab's integer note id is cast to a string so the contract's comment id is one type across forges. `diffSide` is derived rather than read — a `new_line` position is GitHub's `RIGHT`, an `old_line`-only position its `LEFT`.
  - **A merge request with zero unresolved discussions is a `found` result carrying an empty list, never `not_found`.** `not_found` means the merge request itself could not be located, which is a different fact; conflating the two would make a clean review look like a broken lookup. An empty JSON array, Go's `null` for a nil slice, and no output at all all collapse to the same empty-list `found`, while a `404` from `glab` is the one thing that produces `not_found`.
  - **The thread identifier round-trips.** The listing emits GitLab's **full 40-character hex discussion id** — not the 8-character prefix `glab`'s text output displays — and the resolve path hands that string back to `glab` byte for byte, unshortened and unreformatted. `glab` accepts a full id, an 8+ character prefix, or an integer note id, so emitting one form and resolving by another would work by luck against a fake and fail against the real service; the regression suite feeds the listing verb's own output into the resolve verb rather than retyping the id.
  - **Resolving resolves and posts no reply.** That is this verb's established meaning here — phase 2 recorded the decision that it resolves a thread and does not comment, and that no reply call site exists anywhere in this repository — and `glab mr note resolve` behaves identically, so the two agree without special-casing. Proven from argv: exactly one `glab` invocation, and it carries no `note create`, no `mr comment` and no message flag.
  - **Upstream calls both subcommands EXPERIMENTAL, and the code says so.** `glab`'s own documentation marks `mr note resolve` (and `mr note list`) as "an experiment ... not ready for production use. It might be unstable or removed at any time." That is disclosed in each adapter's header comment as information for whoever relies on the verb — not as grounds for leaving GitLab unrouted, since no automatic resolve at all is strictly worse than one whose upstream is still settling.
  - **A missing `glab` degrades through the same `_forge_bin_check` gate a missing `gh` already does**, in the same quiet mode and with the same `cli_missing` reason — but naming `glab`, so a GitLab user is not sent hunting for the wrong install. A non-404 `glab` failure stays `error`/`cli_failed` rather than being read as a confirmed "no such thread": mistaking a could-not-attempt failure for a definitive answer is the dangerous direction.
  - **Fields GitLab cannot supply come back `null` with their names in `unsupported_fields`, never as bare unmarked nulls** — `threads[].isOutdated` and `threads[].isCollapsed` (no GitLab counterpart), the per-note `url`/`outdated`, and `pr.title`/`pr.url`, which would cost a second `glab mr view` round trip this verb deliberately does not make. `--owner`/`--repo` are honored on GitHub only: they are `gh`'s flat pair and cannot express a nested GitLab group path, so the GitLab arm targets the repository the current remote already points at.
  - The verb's manual-fallback message is no longer GitHub-only prose — it now names both forges' diff views rather than claiming "there is no `gh` subcommand for this", which stopped being true on GitLab.
  - **Declared verification ceiling, same as the field mapper above:** `glab` was not installed on the machine this was written on, so neither flag nor JSON key here was observed coming out of the real binary. Both are read off `glab`'s own documentation — whose examples pin the array shape and the full-id extraction — and GitLab's Discussions API. The regression suite adds its own argv-recording fake `glab`, a falsifiability proof that runs **first** (two payloads, two different emitted ids, and an explicit check that asserting one against the other would have gone red), and two mutation tests that unroute each verb in turn and confirm a specific named assertion goes red.

#### Changed

- **The remembered forge account is NOT applied to GitLab writes, and the GitLab write path now says so in one line instead of leaving you to find out from a misattributed merge request.** On GitHub, answering the forge-account question makes every write run as that account. On GitLab it cannot, and the reason is recorded at the top of `aimi-cli.sh`'s GitLab write-adapter section — where a reader meets the question — rather than being discoverable only by reading the absence of code: **`glab` has no per-account token retrieval.** There is no `glab auth token` subcommand at all, and glab's credential store is keyed by **host alone**, so there is no per-account token for this CLI to ask for. **What this means for you:** a merge request, an MR update or a GitLab issue filed by this plugin is attributed to whichever account your `glab` session is logged in as, regardless of what you answered for that repository. If that is the wrong account, the fix is `glab auth login` (or the `GITLAB_TOKEN` escape hatch below) — not a per-repository answer, which this path cannot honor.
  - **The finding was determined before anything was written, and the evidence is recorded next to the conclusion** so the next reader can re-check it rather than re-litigate it: `internal/commands/auth/` in `gitlab-org/cli` holds exactly `login`, `logout`, `status`, `credentialhelper`, `docker` and `generate` — no `token`; `internal/config/schema.go` declares the `token` key as `Scope: ScopePerHost`; and `internal/commands/auth/status/status.go` iterates `cfg.Hosts()` reading `cfg.GetWithSource(instance, "token", true)` — instances, never logins. `glab auth status --show-token --hostname <host>` is therefore not a workaround either: it returns that host's single token, not a named account's. The remaining two subcommands are not a back door — `auth generate` is DPoP proof generation and `auth credentialhelper` is a git credential helper.
  - **This is not the host-dependence problem, which is worth stating because it is the first thing to suspect** after the `GH_TOKEN`/`GH_ENTERPRISE_TOKEN` split on the GitHub side, where emitting the wrong variable at a GitHub Enterprise Server host fails *silently* and attributes the write to the wrong account. glab's token variables are `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN` and `OAUTH_TOKEN`, and the function that resolves them takes a config key and **no hostname at all** — the same three names apply to gitlab.com and to every self-managed instance alike. Self-managed GitLab needs no special handling here; the blocker is the missing retrieval, not the variable name.
  - **The one account-selection mechanism GitLab users still have keeps working, deliberately.** A `GITLAB_TOKEN` you export before invoking the CLI reaches `glab` untouched — the write path sets no token variable, so it cannot blank one either. This is asserted on **every** call a write makes (the pre-create idempotency lookup, the write itself and the post-write re-read), not only on the writing one, because those three are one operation and must run as one account.
  - **Your machine's active `glab` account is unchanged by a routed write**, asserted before-and-after in the *same shell the write runs in* — a separate process per reading would make a leaked process-wide token undetectable, since the leak dies with the process that made it.
  - **The escape hatch this path deliberately does not take:** no `glab auth login`, no rewriting of `~/.config/glab-cli/config.yml`, and no process-wide `export` of any token variable. A machine-wide credential change is not an acceptable substitute for a per-invocation one.

#### Fixed

- **A guard that was supposed to prove no auth token is ever exported process-wide could report "clean" while looking straight at one.** The check ran `grep -v '<comments>' | grep -q '<export pattern>'` under `set -o pipefail`: `grep -q` exits the instant it matches, which SIGPIPEs the `grep -v` still feeding it, so the pipeline reports failure and the `if` reads a **real hit as no hit** — fail-open, in the guard whose entire job is to catch a credential leak. Both export guards now count with `grep -c`, which consumes all of its input and cannot fire early, and the counting form is proven able to go red against a deliberately planted `export` before anything trusts it returning zero. The pattern also widened from `GH_*` to every token variable either CLI honors — `GH_TOKEN`, `GH_ENTERPRISE_TOKEN`, `GITLAB_TOKEN`, `GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN` — since exporting the second or third leaks exactly as far as exporting the first. No leak was present; the guard that would have had to detect one was not capable of it.

### Phase 1.2 — roadmap consumer agreement

> Phase 1.2 of forge abstraction: **roadmap-consumer-agreement**. Four defects of one family — a roadmap layer whose consumers disagreed with the roadmap, or with each other, about the same file on disk.


#### Changed

- **`/aimi:execute` with no arguments may now claim a DIFFERENT phase than the same command would have claimed yesterday against the same roadmap.** `roadmap-claim`'s auto mode now ranks dependency-eligible candidates by **remaining work first and numeric id second**, where it previously sorted by id alone. This is the other half of issue #90. A phase reaches `verification_failed` only when every one of its stories completed but its declared artifacts could not be confirmed — so it has zero pending work by construction, and being older it also carries a lower id. Under a plain id sort it therefore won every auto-claim indefinitely while making no progress, and every phase depending on it stayed blocked: a permanent claim sink. Ranking **demotes, it never excludes** — the candidate status set is unchanged and still wide (`pending`/`planned`/`in_progress`/`verification_failed`, each unclaimed), so a zero-work phase is still claimed the moment it is the only candidate, and both crash recovery and the `verification_failed` retry below stay reachable. **What to expect on your next run:** a roadmap holding a stuck phase alongside phases that still have work will now advance to that work instead of returning to the stuck phase, and will come back to the stuck phase once the others are done. A phase that keeps failing keeps its work, so it can starve a stuck phase in auto mode — `--phase <N>` reaches any phase directly and is never ranked.
  - "Has work" is read from each phase's own tasks file, reusing `roadmap-reconcile`'s existing ground-truth classification, now lifted into one shared definition so the two cannot drift. A phase counts as having **no** work only when that file exists, parses, holds at least one story and every story is `completed`; a missing, unparseable or zero-story file all count as having work, so a never-planned `pending` phase is never demoted merely for being unplanned.
  - **`roadmap-claim`'s auto mode and `roadmap-get --next-eligible` no longer disagree about the same roadmap.** They previously applied different eligibility predicates to the same file and could return different answers; both now share one implementation. The caller supplies the array to be judged, which is the one axis on which they still differ deliberately: the claim judges phases whose dead-PID claims have been cleared inside its own lock, while `--next-eligible` judges `.phases` as written, because inferring process liveness is a decision that belongs where the lock is. `--next-eligible` consequently performs one unlocked tasks-file read per phase; a file rewritten mid-read yields "has work", the safe answer.
  - **The end-of-phase prompt moves with it.** `Phase [N] is complete. Plan phase [M] now?` names whatever `--next-eligible` returns, so it too is now work-ranked rather than lowest-id: it can offer a higher-numbered phase ahead of a lower-numbered one whose stories are all complete. When every eligible candidate still has work the ordering collapses to ascending id, which is why this prompt is unchanged for the common case.
- **A phase left in `verification_failed` can now be re-verified by re-running `/aimi:execute`, instead of being permanently stuck.** A phase reaches `verification_failed` when every one of its stories completed but its declared `creates[]` artifacts could not be confirmed — so it has zero pending stories by construction. `commands/execute.md`'s Step 3 saw that zero, released the claim, printed `All stories already complete!` and STOPped roughly 900 lines before **Phase Completion**, the only place creates verification runs. The phase therefore stayed `verification_failed` forever and every phase depending on it stayed blocked, while the verification-failure report told the user to "re-run `/aimi:execute` to re-verify" — the one instruction that could not work. Step 3's zero-pending case now decides one new branch first: when the run is phase mode, the session itself claimed the phase, the phase is not split, and the phase's status **at claim time** was `verification_failed`, it reports the stuck phase and its branch, keeps its claim, skips the wave loop it has nothing to run, and continues straight into Phase Completion, where `verify-creates` re-runs from scratch against every participating repository. Success ends in `completed` plus `handoff.md` plus a released claim; a repeat failure sets `verification_failed` and releases the claim again, so the recovery is repeatable without manual intervention. The claim-at-entry status is captured in Step 1.7's existing claim-JSON extraction because Step 1.7's own `in_progress` transition destroys it moments later. Every other route through Step 3 — flat mode, flat container mode, a phase entered as `pending`/`planned`/`in_progress`, and a split sub-orchestrator — reaches the unchanged message and STOP, with the same claim-release behavior as before. `scripts/test-command-blocks.sh` gains a check asserting the capture site, the full five-condition gate, its position above the release-and-STOP, and that the new branch adds no claim release.

#### Added

- **`aimi-cli.sh roadmap-amend-phase` — an existing phase's contract is now correctable through a sanctioned verb.** `roadmap-init` writes a phase's contract once at creation and `--sync` deliberately leaves an existing phase byte-for-byte alone, so a phase whose `creates`/`needs`/`goal`/`successCriteria`/`areas`/`branch` turned out wrong could only be fixed by hand-editing `roadmap.json` — which `guard-runtime-state.py` blocks on the Write/Edit path while redirecting the caller to a `roadmap-*` verb that did not exist. This verb makes that redirect truthful. It amends one phase in place under the same `flock` + `mktemp`-then-`mv` discipline `roadmap-init` uses, merging partially by key presence: a key present replaces that field wholesale, a key absent leaves the stored value — and every other phase, and the document metadata — byte-for-byte unchanged.
  - `branch` is amendable because nothing else writes it for an existing phase, which is why a decimal phase's `null` branch could not be filled in. Amending it rewrites the roadmap field only — it does not move a worktree or git branch an `in_progress` phase already created. `status` and `claim` are excluded because `roadmap-set-status` and `roadmap-claim`/`roadmap-release-claim` already own them; both keys are rejected by name pointing at their owner, as are `id`, `dir`, `slug`, `name` and `dependsOn`.
  - Dropping or renaming a `creates` identity a later phase cites in its `needs` is refused by default, naming every downstream phase and identity and printing the invocation that would authorize the fix. `--retarget-needs "<old identity>=<new identity>"` (repeatable) authorizes it, and the same locked write then replaces every matching downstream `needs` entry with the amended phase's new `creates` entry verbatim, so provider and consumer stay byte-identical. Identity comparison is exact equality via `_cv_identity`, never substring containment.
  - Amended values pass `roadmap-init`'s own gates (same sanitizer and caps, same identity guard, same branch pattern). An amendment that would duplicate another phase's `creates` identity is refused, because `validate-contracts` hard-fails on that outside `--agent-mode` and halts `/aimi:plan`. A completed phase whose `handoff.md` omits a newly introduced identity draws one stderr advisory and still writes — repairing an already-completed phase's declared artifacts is a case this verb exists for, so no status gates the amend in either direction.
  - The verb was exercised on this repository's own `forge-abstraction` roadmap while this phase ran: phases 2, 3 and 4 carried `creates` entries written as English prose that `verify-creates` could never resolve, and each was amended to a greppable symbol with the downstream `needs` entries in phases 3 and 4 retargeted in the same locked write. That work changed roadmap data only and shipped no product code.

#### Fixed

- **`/aimi:execute` can now run a decimal-numbered phase whose roadmap `branch` is null.** `commands/execute.md`'s **Claim the Phase** step interpolated the raw phase id into the derived branch name, then validated the result against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` seven lines later — a regex with no dot. A phase like `5.5` therefore derived `feat/<feature>-phase-5.5-<slug>`, failed the file's own validation, released the claim and STOPped, making every such phase impossible to execute. Decimal ids are intentional (`roadmap-init` accepts them and builds `.dir` from the raw value), so the fix slugifies the dot to a hyphen at the single point where the branch name is produced: the branch becomes `feat/<feature>-phase-5-5-<slug>`. Every other consumer keeps the raw id — the `<feature>-phase-<id>-tasks.json` paths name real files that carry the dot, and every `--phase` argument must match `roadmap.json`'s own numeric id. An id with no dot slugifies to itself, so integer-id phases keep byte-for-byte the branch names they have today, and a phase with a hand-filled `branch` is still passed through untouched. `scripts/test-command-blocks.sh` gains a check that executes the real derivation block out of `execute.md` against decimal/integer × present/empty-slug fixtures.
- **`/aimi:plan` can now plan a decimal-numbered phase.** `commands/plan.md` had the same defect one command upstream: it built `metadata.branchName` from the raw `${SELECTED_PHASE_ID}`, then validated the result against the same dot-less `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`, with its own Phase 4 failure row instructing "report the invalid branch name and STOP". A decimal phase therefore could not be planned at all, so the `/aimi:execute` fix above was necessary but not sufficient — the phase never got a tasks file to execute. All three derivation shapes now build the branch from a dot-slugified id: the non-split rolling-wave form, the SIDE-axis split (`-frontend`/`-backend`), and the PROJECT-axis split (`-<project-slug>`). The two Phase 4 checklist items that asserted the pre-fix shape were updated to match. Filesystem paths are unchanged and deliberately keep the raw id — `${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json` and both split basenames name real on-disk files that carry the dot, and `commands/execute.md` reads those exact paths with the raw id. Integer-id phases produce byte-for-byte the branchName they did before.
- **`roadmap-init` now refuses a `creates`/`needs` identity that `verify-creates` could never find.** A contract entry whose searched token carries whitespace was accepted at write time and only failed at phase close, with a whole phase already planned and executed against it. The check is mechanical, not stylistic: `verify-creates` finds an artifact either as a tracked path or as a fixed-string `git grep` over tracked non-doc, non-test source, so a multi-word token can only match prose — and documentation, the one place such a phrase plausibly appears, is already excluded from that search.
  - The predicate reduces the entry to its identity (text before the first `(`), strips a leading `METHOD /` using the same seven methods and the same single-space shape `verify-creates` step 2 strips, and refuses what remains if it holds a space, tab, CR or LF. The token judged at write time is therefore byte-identical to the token searched at close time. `POST /api/notifications` is accepted; `POST  /api/x` with two spaces is refused, because that is not the endpoint form and would be searched whole. Nothing else about the identity is judged — not length, not charset, not whether it looks like a path. Identity *strength* stays unjudged, so a bare table name or bare directory is still accepted.
  - **Existing roadmaps are never retroactively refused.** The rule applies only to the phases a call actually writes: every phase in creation mode, and under `--sync` only those whose ids are not already on disk. A `--sync` that re-submits an existing phase leaves it byte-for-byte unchanged and never judges its identities. `roadmap-amend-phase` follows the same boundary at entry level — it hands the checker only the lists that call writes, so amending a phase's `goal` or `needs` no longer trips over a legacy identity in a `creates` list it never touched.
  - Each offending entry reports on its own line naming the phase, the list, the entry verbatim and what to write instead, so an author fixing several at once sees them all in one run. This matters because both `/aimi:plan` call sites downgrade a `roadmap-init` failure to a single warning line and continue.
  - `commands/references/scope-contexts.md` now teaches the single-token rule beside the naming table, states plainly that passing proves shape and never existence, and no longer holds up `DELETE user_sessions` as an example — a form the writer now refuses, and one that was never findable anyway, since real schemas write `DELETE FROM user_sessions`.

### Phase 1.1 — remediation of the phase-1 review findings

> Phase 1.1 of forge abstraction: remediation of the review findings raised against phase 1 (1.120.0), which has not yet reached `main`.

#### Breaking

**No action is required of anyone upgrading, and the blast radius is zero.** Every field named below belongs to a `forge-*` verb that did not exist in 1.119.3, the last published version. When this section was written the last released version was **1.119.2**; `main` has since shipped **1.119.3** (an `install.sh` fix, unrelated to any forge verb), which this branch has now merged. Neither number changes the argument, because what matters is what `main` does *not* carry: every intermediate release number this branch cut was later folded into the single 1.120.0 above, and none of them was ever published. So the shapes reshaped below were introduced on an unmerged branch, shipped to no one, and the upgrade path from the last published version is untouched — a consumer moving from 1.119.3 to 1.120.0 never saw the earlier envelopes at all.

This subsection is therefore a disclosure, not a migration notice: it exists so that anyone who *did* build against the branch can see exactly what moved. Two further reasons it does not warrant MAJOR: these verbs are consumed only by this plugin's own command markdown (`open-pr.md`, `review.md`, `validate-bug.md`, `execute.md`) and the `resolve-pr-parallel` skill scripts, all updated in this same release — they are not a slash-command syntax anyone types; and this repository's own precedent, 1.92.0 (2026-05-25), shipped a genuinely breaking change under a MINOR bump with exactly this kind of explicit `### Breaking` disclosure, reserving MAJOR (1.0.0) for the one-time repo-wide `tasks.json` schema rewrite.

- **`forge-pr-view`: the degradation field is renamed `evidence` → `message`.** `forge-contract.md`'s single-degradation-signal rule names `message` as the one human-readable degradation field; `forge-pr-view` was the lone verb still emitting its own `evidence` spelling. `open-pr.md` Step 1b now reports `.message`.
- **`forge-pr-view`: `unsupported_fields` is now always an array on `status: "found"`, never `null`.** It is explicitly `[]` when nothing is gated. Previously it was `null` in that case, so a caller iterating it had to null-check first.
- **`forge-pr-view`: `--include`'s known-field list changed.** `isDraft` and `mergeable` become selectable (they are contract fields and were previously unreachable); the gh-only `reviews` and `comments` are now rejected (they have no contract equivalent and had zero callers outside the test suite). `--include` now validates against the ten contract fields rather than passing names through.
- **`forge-pr-view`: `state` is normalized to the contract vocabulary instead of passed through in gh's uppercase form**, matching what `forge-issue-view` already did. Every `gh pr view` response now routes through the shared `_forge_build_pr_json` builder, so a key gh omitted is distinguishable from a key gh returned as an explicit `null`.
- **`forge-pr-create`, `forge-pr-edit` and `forge-issue-create` now share one write-result envelope, replacing three unrelated shapes.** Previously: a `{url, number, created}` boolean, a status-less `{url, number}`, and a flat `{url, number, status, message}` — and on a PR-verb failure path stdout was silent entirely. All three now emit `{status, data, message}` with the same field names and null-forcing discipline the read verbs use, `url`/`number` nested under `data`, and a write-side status enum of `created | unchanged | degraded`. This reconciles `forge-issue-create`'s separate status vocabulary onto the same axis the read verbs use. `_forge_emit_issue_create_status` is removed. The exit-code contract is unchanged: the PR verbs still exit non-zero on every degraded outcome, and `forge-issue-create` still exits 0 on all of them, preserving `open-pr.md`'s soft-fail contract that a failed backend issue never blocks PR creation.

#### Fixed

- **`forge-pr-create` opened a duplicate pull request when its own pre-create lookup broke.** The existing-PR check tested only for `status: "found"`, so `forge-pr-view`'s `status: "error"` — which it deliberately reports *inside* its envelope at exit 0, precisely so a caller can tell "no PR exists" from "the lookup failed" — fell straight through to `gh pr create`. An expired token or a network blip therefore opened a second PR on a branch that already had one, and the `existing_rc` exit-code guard could never catch it because that path does not exit non-zero. The check now branches over all three contract statuses: `not_found` creates, `error` (and defensively any unrecognized status) prints the manual fallback and returns 1 without reaching `gh pr create`, and `found` short-circuits only when the existing PR's normalized `state` is `open`. `state` joined the `--include` list to make that last distinction possible — `gh pr view <branch>` is not state-filtered, so a branch reused after its prior PR was merged or closed used to resolve to that stale PR and could never get a new one.
- **`forge-pr-create` discarded a pull request it had just created when the post-create re-read failed**, printed create-it-yourself instructions for a PR that already existed (guaranteeing a duplicate if followed), and returned 1 — a false failure in `/aimi:execute`'s per-repository loop. Both failure branches now keep the captured url, emit `created: true` at exit 0 with `number: null`, and warn that only the number is unconfirmed. The manual fallback now prints only on paths that run before a url is ever captured.
- **`forge-pr-view` reported `not_found` when the pull request demonstrably existed but `gh pr view` failed.** The `gh pr list` structural probe now runs first and is authoritative: a probe that confirms the PR exists followed by a failing `gh pr view` resolves to `error` carrying that command's own stderr — including when the stderr uses gh's own not-found wording, which can no longer outvote the structural confirmation.
- **`resolve-pr-thread` decided whether a degradation was fatal by substring-matching `.message` prose.** It now compares `.reason` for exact equality against `no_adapter`, so a message that merely mentions no-adapter wording can no longer be misread as non-fatal, and an absent `.reason` from an older cached CLI fails closed.
- **`detect-forge` and the nine `forge-*` verbs no longer require an `.aimi/` directory to exist.** They were dispatched after `find_aimi_root`, which hard-exits when no `.aimi/` is found anywhere up the tree and `cd`s the process into the `.aimi/` parent — neither appropriate for verbs that touch only git, an optional forge CLI and jq. Two consequences are closed: a repository with no `.aimi/` anywhere (the `resolve-pr-parallel` skill's `get-pr-comments`) now gets a parseable envelope instead of a bare exit 1, and in a multi-repo layout a verb invoked from inside a child repository with no `--project` now resolves that child instead of erroring out from the non-git parent. Each of the ten verbs now runs its own `check_jq`, since `main()`'s single check also sat behind `find_aimi_root`. One accepted parity change: a stray `--help` on a forge verb now reaches that verb's own arg parser rather than the universal `--help` intercept, matching `detect-models`' pre-existing behavior.

#### Security

- **`open-pr.md` Step 5c asked the model to repaste the assembled PR body into a `<<'PR_BODY_EOF'` heredoc, so a commit message containing a line equal to `PR_BODY_EOF` closed the heredoc early and ran every following line as a shell command in the operator's session.** The body is assembled from commit messages and the diff — repository content, not operator input — and the delimiter was published in the command file, so it was not even a guess. Step 5c now retypes only `PR_NUMBER` (a forge-issued integer), validates it against `^[0-9]+$`, and re-reads the body through `forge-pr-view --pr "$PR_NUMBER" --include url,number,body`. A returned `.pr.number` that disagrees with the retyped one is handled exactly like `not_found`/`error`. Step 5b's three echo lines that published the body for that repaste are gone.
- **`_resolve-cli.sh` Layer 0 accepted a *relative* `AIMI_PLUGIN_DIR`, so `"$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"` resolved against the caller's working directory** — any repository shipping its own executable `scripts/aimi-cli.sh` got to run it. `cli-path-resolution.md`'s four documented guards (non-empty, absolute, directory exists, executable) now apply to that branch and to the `CLAUDE_PLUGIN_ROOT` branch, and Layer 2's glob result is validated the way Layer 1's cached path already was.
- **`review.md`'s Detect Target Type interpolated `$ARGUMENTS` into a `forge-pr-view` command line with no validation.** A digits-only gate now runs in the *same* bash block as the interpolation — each block runs in its own shell, so a gate in an earlier block cannot protect a later one. It uses `case` rather than `grep -qE`, which matches line by line and would accept a multi-line value whose first line is digits. The URL branch re-enters that gated block instead of describing a parallel unguarded call.
- **`forge-pr-edit` treated an omitted `--body` identically to an empty one, and `gh pr edit N --body ""` blanks a description** — a caller that forgot the flag silently destroyed the pull request body. The verb now tracks whether the flag was seen, refusing omission while keeping an explicit `--body ""` as a deliberate clear.
- **`AIMI_FORGE_TYPE` made `_detect_forge` emit a JSON `null` host, which `jq -r '.host'` renders as the four-character string `"null"`** — non-empty, so it survived every downstream check and reached `gh auth status --hostname null`, whose refusal read as a confirmed `authenticated: false`. Fixed at the root cause with `.host // empty` at the two reads that lacked it, which also revives `_forge_pr_write_print_manual`'s own already-correct fallback (dead because `"null"` is truthy in jq).
- Hardening: the userinfo-redaction scheme match is now case-insensitive, so an uppercase `HTTPS://` remote is stripped like a lowercase one.

#### Added

- **A machine-readable `reason` enum on the read verbs' degradation envelope, so no caller has to grep `message` prose.** `_forge_emit_status` gains a fourth positional argument validated against a closed four-value set — `no_adapter | cli_missing | not_authenticated | cli_failed` — forced to `null` off the error branch exactly like `message`, and passed by every error call site in `forge-auth-status`, `forge-issue-view`, `forge-pr-review-threads` and `forge-resolve-review-thread`. `not_authenticated` is determined structurally, by calling `_forge_auth_status_github` and reading its `.authenticated` field, never by pattern-matching a failing gh invocation's stderr wording, which reworks between releases and varies by locale. `commands/references/forge-contract.md`, the single arbiter, is amended to permit exactly this one enum alongside `message` — a value to switch on versus prose for a log — while keeping the prohibition on variant field-name casing and on any further ad-hoc degradation field.
- `forge-contract.md` gains a Write-Verb Status Convention section, a `forge-pr-view` Envelope section, and a canonical list near the top naming all four result-envelope shapes the file defines, so a phase-2/3 adapter author reads one list instead of inferring it from ten verb bodies.

#### Changed

- **A completed phase no longer pushes a repository's branch to `origin` when no forge adapter can open the resulting pull request — a deliberate behavior change, and stricter than the gate it replaces.** Phase 1 moved `/aimi:execute`'s phase-mode PR call onto `forge-pr-create`, which correctly took the CLI-presence check with it, but left the `git push -u origin` one line above with no check at all — so a user with no forge CLI installed, or any GitLab/Gitea remote (phase 1 ships no write adapter for either), got a branch published where they previously got manual instructions and no push. The push is now gated per repository on `forge-auth-status` reporting `status: "found"`, which is true only when the remote resolves to a forge with a working write adapter *and* that adapter's CLI is on `PATH` — the same two conditions `forge-pr-create` gates its own write on. Note this is narrower than the pre-phase-1 gate, which tested only whether a GitHub CLI existed: a GitLab or Gitea remote on a machine that happened to have one installed used to get its branch pushed and only fail at PR creation. It no longer does, because whether a branch reaches `origin` should not depend on an unrelated binary being installed. A skipped repository prints its own recovery block instead — its label, the container-scoped `git push -u origin` command, and the `base...head` compare range — so the outcome is one pasted command, not a lost push. The check extends by itself: a future GitLab or Gitea write adapter makes those remotes report `found` with no change to `execute.md`.
- **Every `forge-pr-create` failure in a completed phase now prints a line naming the repository it belongs to.** `_forge_pr_write_print_manual` has no repository context and so names none, which meant a multi-repo phase with N failing repositories emitted N indistinguishable stderr banners — the loop itself printed nothing attributable, contradicting the per-repository failure isolation documented directly beneath it. The loop now echoes one labelled line per failing repository alongside that banner.
- **Fewer subprocesses per forge call.** A new jq-free `_detect_forge_type` classifier, memoized per working directory (never globally — sibling repositories under one multi-repo root must not leak forges into each other), serves the four call sites that read only `.forge`; the five that also need host/remoteUrl keep the full `_detect_forge` call. Measured: a `forge-pr-create` run that creates a new pull request drops from 3 forge derivations to 1, and a `not_found` `forge-pr-view` drops from 2 gh calls to 1. A *found* `forge-pr-view` branch lookup rises from 1 gh call to 2 (`gh pr list` then `gh pr view`) — the accepted trade-off for the correctness fix above.

#### Known follow-up

- **`scripts/command-blocks-baseline.txt` grew from 37 grandfathered findings to 44.** The seven new entries are *pre-existing* debt in `brainstorm.md` (2), `design/polish.md` (2), `execute.md` (1), `open-pr.md` (1) and `plan.md` (1), made visible only because this release added `test-command-blocks.sh`'s Check 5, which detects the whole class of "a bash block interpolates `$ARGUMENTS` without validating it in that same block". `review.md`'s own instance — the one with a real security consequence, since it fed a PR identifier straight to a forge command line — is fixed, not baselined. The seven differ in severity: each parses `$ARGUMENTS` to extract a flag or phase id and hands the result to `aimi-cli.sh`, which validates it again on its own side. They are recorded rather than blanket-patched because closing them means editing four command files, one read per block; that is a follow-up, not part of this remediation.
- **`_forge_pr_edit` carries the same post-edit re-read-discards-url defect that `forge-pr-create`'s was fixed for above.** It is deliberately left untouched here and flagged for a later story.

### Phase 1 — the forge abstraction itself

#### Changed

- **Under OpenCode, forge write calls no longer prompt for per-call confirmation — a real broadening of unattended write consent, accepted deliberately.** `forge-pr-create`, `forge-pr-edit`, and `forge-issue-create` used to run as a bare `gh pr create`/`gh pr edit`/`gh issue create` invocation inside a command body, which fell outside `opencode.json`'s `permissions.bash` allowlist and prompted for approval every time. Those calls now run inside `aimi-cli.sh`, which the allowlist already covers with a blanket `aimi-cli.sh *` rule installed for CLI subcommands generally — so they stop prompting. This is intentional: a confirmation gate on these verbs, or a narrower `forge-*`-specific allowlist entry, would break unattended `/aimi:execute`, which is the plugin's purpose, so neither was added. No `gh *` permission entry exists anywhere in `install.sh`. See `docs/opencode.md`.
- **`open-pr.md`'s pre-flight checks no longer conflate a broken forge check with a confirmed negative answer.** Previously, any failure of `gh auth status` was reported identically to "not authenticated," and any failure of `gh pr view` was reported identically to "no PR exists yet" — either misdiagnosis could let a broken token or a network failure proceed straight into creating a duplicate PR. Both checks now branch on `forge-auth-status`'s and `forge-pr-view`'s three-way `found`/`not_found`/`error` status (`commands/references/forge-contract.md`) and surface a distinct, accurate message when the check itself could not run, instead of silently treating that as a definitive answer.
- `open-pr.md`'s standing `PR_URL`/`PR_BODY` defect is fixed as part of this migration: Step 5b previously never captured `gh pr create`'s output, so Step 5c read variables nothing had assigned. `forge-pr-create`'s JSON response is now captured and both values are threaded through correctly.
- `docs/opencode.md` documents the OpenCode write-consent change above. `docs/commands.md` documents `--base <branch>` on `/aimi:execute` and `/aimi:next` (previously only in `README.md`), and now states that `/aimi:open-pr`, `/aimi:review`, and `/aimi:validate-bug` detect the forge from the git remote instead of assuming GitHub.

#### Added

- **`detect-forge` and eight `forge-*` verbs in `aimi-cli.sh`** — `forge-auth-status`, `forge-repo-info`, `forge-pr-view`, `forge-pr-create`, `forge-pr-edit`, `forge-issue-view`, `forge-issue-create`, and two review-thread verbs (`forge-pr-review-threads`, `forge-resolve-review-thread`) — a normalized PR/issue field contract with a three-way `found`/`not_found`/`error` status convention and a documented degradation contract. GitHub is the only working adapter shipped in phase 1; GitLab and Gitea are designed for behind the same contract but not implemented yet. See `plugins/aimi-engineering/commands/references/forge-contract.md`.
- `open-pr.md`, `review.md`, `validate-bug.md`, `execute.md`'s phase-mode PR-creation loop, and the `resolve-pr-parallel` skill scripts are migrated onto these verbs — no command file makes an executable `gh` call directly anymore; every `gh` invocation now lives inside `aimi-cli.sh`.
### Branch commit 1 — 2026-08-07

> Phase 5 of forge abstraction: **confirm before publishing.** Finishing the work and publishing it are two decisions now, not one. Every completion path asks once before a branch reaches `origin` or a pull request is opened, an unattended run never publishes, and `--push` — the flag that let a command line authorize a publish — is gone.
>
> **What did NOT change, stated first, because "the push was removed" reads worse than it is.** The `git merge` that moves each story worktree's work onto the feature branch is local and untouched — `worktree-manager.sh` contains zero `git push`, only `git merge`. Commits, branch refs, container teardown with `--keep-branch`, and story and phase status all behave exactly as before. Nothing about how the work gets *made* moved; only how it gets *published*.
>
> **Read this before upgrading if anything you run passes `--push`.** The flag removal below is breaking on its own terms: `/aimi:execute --push` no longer runs at all — it exits non-zero in Step 0, before any state is touched — and there is nothing a caller can add to keep the old outcome, because the escape hatch is deliberately absent rather than renamed. An unattended run that used to finish with a branch on `origin` now finishes with a local one.
>
> **Why the level is MINOR anyway.** `plugins/aimi-engineering/CLAUDE.md` defines MAJOR as a breaking change to command syntax or output format, which by the letter of the rule this is. The number was set deliberately below that: the flag was an agent-mode-only opt-in with a narrow surface, and the plugin argues its release levels case by case rather than applying the rule mechanically — the previous entry did the same in the opposite direction. That judgment does not soften the paragraph above; it is why the breaking change is announced here in the first sentence rather than left to be discovered from the version number.

#### Removed

- **BREAKING: `/aimi:execute --push` is removed, and an invocation still carrying it stops.** The flag used to authorize an unattended run to publish its branch to `origin` on completion. It is not accepted, not ignored and not deprecated: Step 0 scans the arguments before `init-session` mutates any state and exits non-zero with `Removed flag: --push. An agent-mode run never publishes to origin, and no flag re-enables it. Publish with /aimi:open-pr --branch <branchName>.`
  - **Failing loudly is the point, not a side effect.** A pipeline that passed `--push` on the previous version got a published branch out of it. Accepting the flag and quietly doing nothing would hand that same pipeline silence instead — the one outcome nobody notices. A non-zero exit that names the replacement is the only result that cannot be misread.
  - **Nothing re-enables it.** Agent mode has no substitute argument, and that absence is the rule rather than a gap to fill: an unattended run cannot obtain consent, and a flag claiming to stand in for consent is the same substitution the gate exists to prevent. Publish deliberately afterwards with `/aimi:open-pr --branch <branchName>`, which pushes the branch itself before opening anything.
  - The `--push` row is gone from `README.md`'s `/aimi:execute` flag table, and `docs/commands.md` now describes the gate that replaced it instead of the flag.

#### Changed

- **Every completion path asks before it publishes, and the contract behind that question is written down once.** New `commands/references/publish-confirmation.md` defines what counts as publishing — pushing a branch *and* opening a pull request, the push being an outward-facing act in its own right rather than a mere precondition — why nothing inside a tasks file, a roadmap or a command line may authorize one, what each interactivity mode owes the reader, and why a decline is a normal outcome rather than a failure. `execute.md`, `next.md` and `container-execution.md` cite it instead of each carrying a partial copy that could drift. It is prose only, carrying no picker markup and no fenced blocks: reference files reach OpenCode through a verbatim tree copy that never translates the interactive-question tool's name, so a picker written into one would name a tool that host does not have.
- **Phase completion asks once per phase, and offers three outcomes.** `/aimi:execute`'s **Offer a Pull Request** step raises one question for the whole phase — push and open the pull request / push only / neither — before either act. One answer governs every participating repository, because "should this phase's work go out" is one decision by one person; asking once per repository would turn a single answer into an interrogation and invite a mis-click on repository number four. The gate **fails closed**: anything that is not an explicit approval — a dismissed prompt, an unparseable answer, no answer at all — is *neither*. Declining changes nothing else: the phase stays `completed`, no claim is re-taken, nothing is retried, and execution continues to the next phase.
- **An unattended run publishes nothing, on every path.** Agent mode (`--non-interactive`, `AIMI_AGENT_MODE=true`, `CI=true`) skips the question because it cannot answer one, and therefore skips the publish too — logging one line that names both what was not done and the command that does it.
- **`/aimi:next` no longer pushes when its last story completes.** It removes the container, keeps the branch, counts the commits and reports as before; the report now states that the branch is local only and names `/aimi:open-pr --branch <branchName>`. No prompt was added here — there is nothing to confirm when nothing is published.
- **Three completion reports that recommended a raw `gh pr create` now name `/aimi:open-pr` — in three deliberately different forms.** The multi-repo split report carries both the repository root and the branch, because `/aimi:open-pr` resolves its repository from the current directory and has no `--project` flag, so a line naming only the branch would not be actionable. The inline report uses the **bare** form, because the branch is still checked out right there and the bare form is what keeps `/aimi:open-pr`'s own uncommitted-changes check in play. The no-usable-forge degradation names it **conditionally**, keeping the manual `git push` and the compare range as the immediate fallback — that branch fires precisely because no forge CLI is usable, and `/aimi:open-pr` routes through the same forge verbs, so it would stop on the same condition if run right now.
- **The flat-container push confirmation moved from `container-execution.md` into `execute.md`'s command body.** Same question, same two options, same fail-closed reading of a non-answer; only its home changed. `install.sh` rewrites the interactive-question tool into OpenCode's equivalent in command bodies only, and delivers reference files verbatim, so the picker had to live where the translation reaches it. The reference keeps the push itself and the contract prose that gates it.

### Branch commit 2 — 2026-08-08

> **One rule for what a `creates`/`needs` artifact identity may be, enforced where the text enters the system.** Three places decided what a legal identity was and none of them consulted the others, which produced two failures that looked unrelated and shared one root: a roadmap the CLI itself had just written was rejected by the CLI's own reader (#99, #85), and an identity written with backticks was deleted on its way to disk and resurfaced an entire phase later as a contract nothing could fulfil (#100).
>
> **What now gets refused that did not before.** Read this part even if you skip the rest — the version number is a PATCH and will not signal it for you.
>
> - An identity carrying `;`, `|`, `&` or a bare `$` — `cmd_a;b (…)`. Previously written in silence, then refused by `validate-contracts` one `/aimi:plan` later.
> - An entry matching an instruction-injection marker in its **marker** form: `INSTRUCTIONS:` with a colon, `system:` preceded by a non-identifier character, `ignore previous`, a code fence, `$(`.
> - An `areas[]` glob that is absolute or contains `..`.
>
> **What now gets ACCEPTED that used to be silently rewritten**, which is the larger change in practice: `parseList<T> (a generic helper)` was stored as `parseList (a generic helper)`, and `design-system:tokens (a token file)` as `design-tokens (a token file)` — exit 0, `validate-contracts` green, and `verify-creates` then looking for a name the phase never produces. Namespaced, templated and globbed identities now survive verbatim.
>
> Ordinary English is no longer a marker. `docs/instructions.md (setup instructions)` was written and then hard-refused, and a story titled *"Update the setup instructions"* stopped every `/aimi:execute` at content validation. Both were the unanchored `INSTRUCTIONS` alternative matching the plain word.
>
> **Why PATCH.** The defect is the headline — the symptoms are one disagreement seen from several angles, and closing it is a bug fix in the ordinary sense. The counterweight is stated rather than buried: `roadmap-init` genuinely accepts less than it did, and a tightening argues for a number a reader notices. It was still set at PATCH because every identity now refused was already unverifiable downstream — the contract reader refused that whole class, so writing one only deferred the identical rejection — and because the same release stops refusing, and stops mangling, a larger set of perfectly legal names than it starts refusing. The backtick case makes the point measurably: against the pre-fix CLI, `roadmap-init` fed `` creates: ["`cmd_foo` (a backticked name)"] `` *already* exited 1, with `is not a usable artifact identity: empty once the description is stripped`. For that shape this release replaces an unreadable failure with a legible one. This plugin argues its release levels case by case rather than applying the MAJOR/MINOR/PATCH definitions mechanically; the two entries below did the same, in the other direction. The list above is the compensation for choosing the quieter number.

#### Fixed

- **The writer and the reader now agree on what a legal artifact identity is (#99, #85).** The roadmap sanitizer removed `$(`, backticks, code fences and HTML tags but left `;`, `|`, `&` and a bare `$` untouched, while the contract reader refused that whole class — so `roadmap-init` wrote phases that `validate-contracts` then hard-failed, stopping `/aimi:plan`'s Pre-Expansion Contract Gate on a roadmap the CLI itself had produced. Both sides now read one shared table instead of two that overlapped by accident, and the write-time guard consumes the reader's own injection predicate, so the agreement is structural rather than two lists that happen to line up.
  - **`INSTRUCTIONS` was the one that got away, and it kept #99 alive.** It was the single alternative the sanitizer never stripped and the reader matched case-insensitively, so `docs/instructions.md (setup instructions)` — an ordinary path — was written and then refused. The same alternation in `validate-stories` gave the defect a wider reach: a story titled *"Update the setup instructions"* stopped every `/aimi:execute` at content validation. Both markers are now matched only in their marker form.
  - **Two rulers, applied to the two things they actually describe.** The **identity** — the text before the first `(`, trimmed — may not carry whitespace, nor any of ``$``, `` ` ``, `;`, `|`, `&`, because it is grepped as a literal string against tracked source. The **description** — the parenthesised remainder — is freed from that character class, which is what unblocks `"cmd_clean (does x; then y)"`. That entry's identity was always clean; it died because the check judged the whole raw entry rather than the identity the search actually uses.
  - **The description keeps its injection guard** — `ignore previous`, `system:`, `INSTRUCTIONS:`, code fences and `$(` — because it is not human-only prose: `/aimi:plan` reads every completed phase's `handoff.md` into `phaseHandoffBlocks` and threads it verbatim into every story-expander sub-agent prompt. Freeing the description of the character class is a legibility fix; freeing it of the injection patterns would have reopened a path that is closed today.
  - **The refusal moved to write time, and it names the character.** `roadmap-init` and `roadmap-amend-phase` reject before anything reaches `roadmap.json`, naming the phase, the list, the entry and the offending character, and pointing at the parenthesised description as the place that text belongs. `validate-contracts` and `roadmap-sweep` still apply the same class when they read a roadmap; that check is defence in depth now, not the place an author is expected to meet the rule.
- **A backticked identity is unwrapped rather than deleted, so it survives into the handoff (#100).** The sanitizer's single-backtick rule removed the span *and its contents*. Fed `` `cmd_foo` (a backticked name) ``, the handoff recorded ` (a backticked name)` and the identity was simply gone — and `## Artifacts Created` is exactly the section a later phase's `needs` is resolved against, so the loss surfaced as a permanently unmet contract one phase after its cause. The span now unwraps to its inner text: the same payload stores `cmd_foo (a backticked name)` and the downstream `needs` resolves again. Triple-fenced blocks are still deleted whole — a fenced block is not an identity — and the lone-backtick strip is kept deliberately, so no backtick ever reaches output.
  - **This is not confined to `creates`/`needs`.** The same sanitizer runs over phase names, goals, notes, success criteria, branch names, `brainstormPath`, handoff content, and `story-merge`'s stderr banners and `droppedDeps` titles. All of them now keep the words inside a backticked span instead of losing them; a phase declaring `` branch: "`main`" `` stores `main` and passes the branch pattern where it previously emptied to a hard error.

#### Changed
- **An identity is never rewritten — only refused.** The two rulers now govern mutation as well as judgement: the identity gets formatting normalization alone, the description additionally gets the tag and instruction-override strips. Those strips delete content, and an identity is grepped for literally, so rewriting one produced a name the phase would never deliver — silently, with `validate-contracts` passing and the contract reading as undelivered a whole phase later. A comparison guard backs the split up, refusing an entry whose identity would change and naming what changed.
- **`areas[]` is checked for traversal.** `/aimi:plan` exempts phase `areas` from the filter it applies to user-typed path tokens, on the grounds that `roadmap-init` already sanitized them — which was never true for `..` or a leading `/`. It was masked while the sanitizer deleted a backticked span whole; unwrapping the span removed the accidental cover, so `` `../../../etc/**` `` reached the research path hints intact.
- **`roadmap-sweep` reports what it drops**, and both readers name the offending entry by position and reason instead of saying only "contains suspicious content". An entry that matched an injection pattern is reported with its content withheld — that stderr is read by the agent that will act on it.
- **`/aimi:plan` repairs a refusal it authored instead of degrading in silence.** Both `roadmap-init` call sites answered every non-zero exit by warning once and carrying on, which was written for a failure the command cannot fix. Because `ROADMAP_MODE` is derived from whether `roadmap.json` exists, a refused write left a user who asked for a phased rollout with one flat tasks file behind a single line of prose — and on `--sync`, one bad entry dropped every new phase and the run continued from a stale roadmap. The malformed-identity case is now repaired from the phases still in working memory and retried once; everything else keeps the old path, and the warning says what was lost.


- **The tightened rule binds new writes only.** Nothing re-judges a roadmap already on disk. `roadmap-init` judges only the phases it is creating — under `--sync`, only the ids not already stored — and `roadmap-amend-phase` judges only the lists a given call actually amends, so a phase whose stored `creates` holds a legacy whitespace identity can still have its `needs` corrected. Repairing exactly those phases is what that verb exists for. This repository's own phases 2, 3 and 4 carry whitespace-bearing `creates` today and stay readable and amendable.
- **`commands/references/scope-contexts.md` § Creates/Needs Contracts now teaches the contract instead of leaving it to be discovered from an error.** It states the two rulers and why each half is judged the way it is, the write-time rejection and its diagnostic, the backtick unwrap and the phase-late failure the old deletion used to cause, and the new-writes-only scope. The rule is written there once: `plugins/aimi-engineering/CLAUDE.md`'s `roadmap-init` entry gains a pointer to it, not a second copy.

### Branch commit 3 — 2026-08-10

> **A `creates`/`needs` entry is now two fields, `{identity, description}`, and a roadmap already on disk stops being readable by the contract verbs until it is migrated once.** The identity is grepped literally against tracked source to prove a phase built what it promised; the rest is prose. While both halves lived in one string, every boundary that needed one of them re-derived the split at the first `(` — four splitters that disagreed with each other had accumulated — and whoever forgot applied prose-cleaning rules to a name.
>
> **Read `### Breaking` and `### Migration` below before upgrading, whatever else you skip. The version number is a PATCH and will not signal any of it.** The whole action is one command, once per roadmap: `aimi-cli.sh normalize-contracts --feature <slug>`.
>
> **Why the number is PATCH anyway, stated rather than left to be inferred.** By the letter of `plugins/aimi-engineering/CLAUDE.md` — "MAJOR: breaking changes to command syntax or output format" — a stored document that its own reader refuses until a migration is run is the kind of change a reader expects a louder number for, and no argument below is offered to talk anyone out of that reading. The level was set deliberately at PATCH, so the disclosure carries the weight the number does not: the two sections below name every verb that refuses, every verb that does not, the exact invocation that fixes it, and what the migration does and does not touch. This plugin argues its release levels case by case rather than applying the definitions mechanically, and the entries above did the same in both directions; the difference here is that a quieter number costs the reader something specific, so the compensation is specific too.

#### Breaking

- **A roadmap written before this version is refused by every contract-reading verb until `normalize-contracts` is run once against it.** Six verbs refuse by name and each names the migration in its own message: `validate-contracts`, `verify-creates`, `roadmap-sweep`, `roadmap-write-handoff`, `roadmap-amend-phase`, and `roadmap-init --sync`. The refusal reads `this roadmap stores creates/needs in the pre-2.0 form, where one entry is the single string "identity (description)". Nothing was read and nothing was checked.` and prints the exact command below it. **It refuses rather than skipping deliberately** — reporting `valid: true` about a document it never parsed is worse than no check at all, because the caller acts on the verdict either way and only one of the two outcomes tells them the truth is unknown.
- **The five lifecycle verbs stay readable on an unmigrated roadmap, and that is the guarantee that keeps a session already in flight from being bricked**: `roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim`, `roadmap-reconcile`. None of them reads a contract entry; they move status and claims. Gating them would mean a run that was mid-phase when the upgrade landed could not release its own claim or record the phase it just finished — a worse failure than the one the gate exists to prevent. `phase-overlap` is ungated for the same reason: its verdict comes from two tasks files' `implementation.files`, so a contract entry never enters it.
- **A `roadmap-init` payload that spells a `creates`/`needs` entry as a string is rejected outright, not converted.** The write side moved with the read side: an entry must be an object with exactly `identity` and `description`. This is the shape `/aimi:brainstorm`'s `phases:` block and `/aimi:plan`'s materialization step now emit, and anything else authoring a phases array — a hand-written file, a script of your own — has to move with them. `normalize-contracts` migrates a *stored* document; it is not a compatibility shim on the input path.
- **`python3` is now a runtime requirement, not only a test-time one — and on OpenCode that is new.** Thirteen of the fourteen roadmap verbs shell out to `scripts/roadmap.py`, which now owns `roadmap.json`'s document logic; each calls `check_python3()` first and fails with an install hint when it is absent. `estimate-payload` is the one exception and stays pure Bash + jq, as does every non-roadmap verb, so a host without python3 still runs those. Claude Code already invoked `hooks/*.py` on every session, so nothing changes there. `install.sh` copies `scripts/` wholesale and needed no change to carry the file, which is exactly why this can surprise: the install succeeds on a host that cannot then run a roadmap verb.
- **A `creates`/`needs` identity is now refused rather than repaired** — see `### Removed`. The visible case is a backticked identity such as `` `cmd_foo` ``, which used to be unwrapped to `cmd_foo` and is now rejected at write time; the same applies to one over 500 characters, where every other roadmap field is truncated.

#### Changed

- **A `creates`/`needs` entry is now two fields, `{identity, description}`, instead of one string `"identity (description)"`.** The identity is grepped literally to prove a phase built what it promised; the rest is prose. While both lived in one string, every boundary that needed one half had to re-derive the split at the first `(` — and whoever forgot applied prose-cleaning rules to a name. That is the defect, and four independent paren-splitters that disagreed with each other had accumulated around it. There is nothing left to re-derive.
  - **Existing roadmaps must be migrated once, and are refused until they are.** `aimi-cli.sh normalize-contracts --feature <slug>` rewrites a roadmap in place; it is idempotent, and it computes each identity with the same function every pre-migration reader used, so no identity changes by a byte and no downstream `needs` is repointed. Run against this repository's own roadmap (7 phases, 64 entries), `validate-contracts` and `roadmap-sweep` return byte-identical output before and after.
  - **Every contract-reading verb refuses a pre-2.0 roadmap by name** — `validate-contracts`, `verify-creates`, `roadmap-sweep`, `roadmap-write-handoff`, `roadmap-amend-phase`, and `roadmap-init --sync` — and names the migration in its message. It refuses rather than skipping deliberately: reporting `valid: true` about a document it never parsed is worse than no check at all.
  - **The five lifecycle verbs stay readable on an unmigrated roadmap** — `roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim`, `roadmap-reconcile`. None of them reads a contract entry, and a migration must never leave a session already in flight unable to release its own claim.
  - **A malformed entry now raises instead of vanishing.** Thirteen readers filtered their lists by type first, which against the new shape would have silently dropped every entry and reported a clean roadmap — disabling the orphan check, the duplicate check and the downstream rewrite without printing a line. The filter is gone; the refusal names the phase, the list and the position.
  - **The surface that tells an agent how to WRITE an entry now describes the two fields.** `/aimi:plan`'s inline scope-context fallback still compared whole strings when detecting a shared foundation, so two phases describing one artifact differently no longer collided; it compares identities now, as `/aimi:brainstorm` already did. `/aimi:brainstorm`'s `phases:` block still applied the 500-char cap to identities as well as descriptions, which the CLI now refuses rather than clips. And the `task-planner` skill still carried a full second copy of the materialization step emitting `creates: ["…"]` — an agent following it produced a payload `roadmap-init` rejects outright.
  - **`/aimi:plan` repairs both refusals it can author, not one.** The shape gate added with the new entry format prints `Error: roadmap-init: malformed creates/needs entry`, distinct from the identity gate's `… malformed creates/needs identity`; only the second was named, so a payload written in the old shape fell straight through to warn-and-continue and the phased rollout silently became one flat plan. Both prefixes now take the repair-and-retry-once path.
  - **The rule that a description is sanitized and an identity is never touched has one normative home.** `scope-contexts.md` § *Two rulers* states it; `sanitization.md` carries the carve-out and a two-row dispatch table, and `plan.md`, `brainstorm.md` and the `task-planner` skill say what to do and point at it rather than restating the rationale, the character class or the refusal asymmetry. Three places disagreeing about what a legal identity is was the original defect — prose drifts faster than code, because nothing tests it.

#### Fixed

- **A roadmap can no longer end up holding both entry shapes at once.** Measured on the previous code: amending a stored roadmap with an entry of the other shape dropped an identity a later phase still cited, exited 0, and left `validate-contracts` crashing on the file it had just written. Both doors are shut — the amendment is refused before the lock, and a document that already holds a mixed list is refused by every reader.
- **`verify-creates`' own diagnostic for an empty identity stopped instructing the reader to write the shape the CLI refuses.** It quoted the pre-`2.0` `"<artifact-name> (<description>)"` form as what it expected — reachable on a migrated legacy roadmap, since `normalize-contracts` deliberately does not repair what it converts.
- **The roadmap subcommand roster in `plugins/aimi-engineering/CLAUDE.md` was one verb short.** `verify-creates` was added after the roster was written and never got an entry, leaving the stated count stale and the verb `/aimi:execute` calls at every phase close undocumented. The section also now records that `python3` is a runtime requirement for these verbs — thirteen of the fourteen shell out to `roadmap.py`, `estimate-payload` being the one that stays pure Bash + jq.

#### Removed

- **Nothing is applied to a `creates`/`needs` identity any more** — no fence strip, no backtick unwrap, no newline fold, no truncation. The two sanitizers that existed only to split one string and treat its halves differently are deleted with it. An identity that breaks a rule is now **refused rather than repaired**, including one over 500 characters, where every other roadmap field is truncated: a truncated goal is still the goal, a truncated name is a search that returns nothing. One behaviour changes visibly — a backticked identity such as `` `cmd_foo` `` is refused, where it used to be unwrapped to `cmd_foo`. The author hears about it at the one moment they can still rename the artifact, rather than finding a roadmap that stores a name they did not type. A backticked span in a **description** still unwraps to its inner text.

#### Migration

- **One command, once per roadmap, before anything else reads it:**

  ```
  aimi-cli.sh normalize-contracts --feature <slug>
  ```

  `<slug>` is the feature directory name under `.aimi/tasks/` — the same value every other roadmap verb takes. It rewrites `.aimi/tasks/<slug>/roadmap.json` in place under the same `flock` + write-temp-then-`mv` discipline every other roadmap writer uses, sets `roadmapVersion` to `2.0`, and prints `{roadmap, converted, roadmapVersion}` where `converted` counts the entries that were strings *before* the run. There is no repository-wide sweep: one roadmap, one invocation, and a project with several features runs it once per feature.
- **It is idempotent, and it changes no identity by a byte.** Each identity is computed by the **same function every pre-migration reader used** — cut at the first `(`, then trim — rather than by a fresh regex written for the migration. A fourth ruler disagreeing on even one entry in one roadmap would silently repoint a downstream `needs` at nothing, because `needs` are matched against `creates` by exact byte equality; reusing the function makes the migrated identity byte-identical to what those readers saw by construction rather than by testing. Run it a second time and it converts nothing: an entry already in object form is left untouched. Against this repository's own roadmap — 7 phases, 64 entries — `validate-contracts` and `roadmap-sweep` return byte-identical output before and after.
- **It does not judge, and does not repair.** A whitespace-bearing or prose identity that the current writer would refuse migrates unchanged, and the reader reports it afterwards by name. Repairing on the way past would change what a phase promises without telling anyone. Fix such an entry deliberately, after the migration, with `roadmap-amend-phase`.
- **One-way in one narrow respect.** An entry whose text after the first `(` does not end in `)` loses that unbalanced trailing paren from its description. The identity half — the half compared byte-for-byte downstream — never sees it, so nothing that resolves a `needs` is affected.
- **A run that is already in flight does not have to stop.** Migrate whenever it suits: until you do, the phase still moves — `roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim` and `roadmap-reconcile` all read a `1.0` document unchanged. What will not run is the contract half: `validate-contracts`, `verify-creates` and `roadmap-write-handoff` — and because `roadmap-set-status --status completed` requires that phase's `handoff.md` to be on disk already, a phase that has not written one yet cannot be *closed* until the roadmap is migrated. Releasing a claim, recording a status short of completion, and reconciling all keep working either way.
- **Nothing else needs rewriting, and nothing needs re-planning.** No tasks file is touched, no phase is re-authored, no brainstorm is re-run. A roadmap is the only file the migration reads or writes.
- **On OpenCode, check for `python3` before the first roadmap verb.** `./install.sh --to opencode` carries `roadmap.py` with no installer change, so the install itself succeeds either way; a host without `python3` gets an install that fails at the first roadmap verb with an install hint instead of at install time. Every non-roadmap verb keeps working there regardless.

### Branch commit 4 — 2026-08-10

> **A refactor. No behaviour a caller can see changes, no flag moves, and nothing needs migrating.** `story-merge` used to be ~1520 lines of Bash and ~90 jq invocations in `aimi-cli.sh`; it is now `scripts/story_merge.py`, ported rule for rule. What made it worth doing is narrow: the prose sanitizer existed **twice**, once as Python and once as the jq blob `_ROADMAP_SANITIZE_JQ`, and the only four call sites keeping the jq copy alive were inside this verb. There is one implementation of that rule now, in `scripts/sanitize.py`, imported by both readers.

#### Changed

- **`story-merge`'s merge, both split axes and its writes moved to `scripts/story_merge.py`.** `aimi-cli.sh` keeps the shell-shaped half — flag parsing, path confinement, and the `--phase-aware` basename precondition — and calls the module once. Locking moved with the writers rather than staying in Bash: on the PROJECT axis the output paths are derived from the stories themselves, and Bash cannot hold a lock on a name it has not computed yet. Every rule was captured from the jq it replaces, case by case, over a 92-case adversarial corpus **before** the jq was deleted; 440 of 460 recorded field comparisons are identical, and the 20 that differ are named one by one in `tests/golden_from_jq.json`. `aimi-cli.sh` is 1532 lines shorter and the planning half of the test suite runs in roughly half the wall time it did.
- **The prose sanitizer lives in one file, `scripts/sanitize.py`, and neither importer owns it.** `roadmap.py` held it while it was the only caller; `story_merge.py` needs the same rule for the sub-agent-authored titles it puts into a dropped-dependency warning, and a story title is not a roadmap concern. The function, its caps and its rule order are unchanged.
- **`python3` is now required by `story-merge` as well as by the roadmap verbs.** `check_python3()` covers both and its message names both. Every other verb stays pure Bash + jq and still runs on a host without python3. `install.sh` copies `scripts/` wholesale, so the new modules travel with no installer change.

#### Fixed

- **A staging file holding an ARRAY of stories now merges, instead of aborting the whole run with a jq engine error.** Arrays are documented as supported and the Bash had a complete flattening loop for them — directly underneath a first attempt that called jq's `path` with no argument. That is a compile error; its failure was redirected to `/dev/null` and its empty output was assigned over the accumulator the loop was about to append to, so the merge collapsed to `jq: error … null (null) has no keys` and exit 5 with nothing written. Nothing exercised it. The port runs the loop the file was written to run.
- **A staging file whose top-level value is a number, a string, or two JSON values is refused by name.** Each used to abort inside jq — mid-`--argjson`, or adding a scalar to an object — so the exit status was the engine's and no message said which file was at fault.
- **A failed write in legacy or `--split full-stack` SIDE mode now says so and cleans up after itself.** `set -e` killed the shell on the failing lock redirect before either writer's own `failed to write output file` branch could run, leaving an orphaned `mktemp` scratch file and no diagnostic at all. Both remain refusals that write no tasks file; they just say which one and remove the scratch file. The PROJECT axis, whose report was already reachable, is byte-identical.

### Branch commit 5 — 2026-08-10

> **`/aimi:plan` stops deciding for you which roadmap you meant, and stops deciding twice which phase is next.** Both halves are things a caller feels against roadmaps already on disk. With a single **finished** roadmap in `.aimi/tasks/` and a description matching no slug, a bare `/aimi:plan` used to adopt that feature, find nothing to expand, and abort the whole invocation printing a heading above an empty list; it now declines to adopt, names the feature and both deliberate ways to target it anyway, and continues as a flat plan. And the eligibility rule `/aimi:plan` carried in four jq blocks is gone — it reads the new `roadmap-eligible` verb, so the answer comes from the one implementation `roadmap.py` owns.
>
> **Phase ORDERING did not move, and that is measured rather than argued.** The retired jq was recovered verbatim from git history and run beside `roadmap-eligible --statuses pending` over a seven-roadmap corpus: 21 field comparisons (selected phase id, ordered eligible list, blocked-phase reason text, per roadmap), **0 disagreements**. See *Changed* for the counterfactual, which is the number that makes the ordering choice a decision rather than an accident.
>
> **Read the `--phase` bullets and the `python3` bullet below.** `--phase 2.10` now resolves to phase `2.1`, a rejected phase id says something different, and one `/aimi:plan` block that was pure Bash and jq now needs `python3`.

#### Added

- **`roadmap-eligible --feature <slug> [--statuses <a,b>]`** — one JSON object naming every phase in roadmap order (`{id, name, status, claim, eligible, unmet[]}`) plus the ordered ids of the eligible ones and their count, so a single call serves both a whole-list rendering and a by-id lookup. Three properties are deliberate and each is asserted by the suite: it does **not** call `_roadmap_require_contracts` (it reads `id`, `status`, `claim` and `dependsOn`, never a `creates`/`needs` entry, so gating it would make every pre-2.0 roadmap unexpandable over a shape it never looks at); **zero eligible exits 0** with an empty list, because its caller captures stdout in a command substitution and has to tell "no phase is ready" apart from a CLI that broke; and **no field carries a sentence**, because the plugin's wording follows the language the reader writes in and prose composed inside `roadmap.py` cannot be re-worded by the command that prints it. An unknown `--statuses` value is refused by name with the accepted vocabulary, rather than silently returning zero eligible phases — an answer indistinguishable from a roadmap where nothing is ready. **This new verb is why the number is MINOR.**

#### Changed

- **`/aimi:plan` no longer computes eligibility itself; it asks `roadmap-eligible`.** Rolling-Wave Phase Selection carried the pending/unclaimed/deps-complete rule in four jq blocks — the filter, the `--phase` lookup, the count-and-take-first pair, and the blocked-phase report. `roadmap.py` already owned that rule, so the two could drift, and the refusal a reader saw was assembled from a predicate nobody had checked against the one the claim path uses. There is one implementation now.
  - **The ordering result, measured.** The retired predicate was recovered with `git show` rather than retyped and run beside the new verb over seven roadmaps: an ordinary all-pending roadmap, a dependency-blocked phase, a claim-blocked phase, a `planned` phase (which both sides must exclude), an all-completed roadmap, a zero-phase roadmap, and the one shape that can actually separate the two orderings — a `pending` phase whose own tasks file exists, parses, holds stories and has every one of them `completed`, which is the only condition under which the rank helper demotes a phase. **21 field comparisons, 0 disagreements.** Nothing about which phase gets offered for expansion moved.
  - **The counterfactual is why the ordering parameter exists.** Run with the rank-first key that `roadmap-claim` and `roadmap-get --next-eligible` keep, **1 of the 7 corpus roadmaps would have selected a different phase** — exactly the demotion shape, and only that one. So `/aimi:plan` asking for id-only order is a choice with a visible consequence, not a coincidence that happens to agree today.
  - **Determinism, demonstrated on the same fixture.** Because id-only order reads no tasks file, `roadmap-eligible`'s answer depends on `roadmap.json` alone: invoked twice with a phase's tasks file rewritten in between, its stdout is **byte-identical**. `roadmap-get --next-eligible`, which does consult the work map, moved its answer from phase 2 to phase 1 across that same rewrite. That is the contrast the parameter buys — `/aimi:plan` reports what it may expand while an `/aimi:execute` run is rewriting the very files a work ranking would read.
- **A bare `/aimi:plan` no longer adopts the only roadmap on disk when every phase is `completed` — and this is retroactive, against roadmaps you already have.** One roadmap in `.aimi/tasks/` was treated as evidence that it was the feature you meant; it is only evidence that it is the one you still have. The single-roadmap arm now adopts only when at least one phase carries a status other than `completed`, read through `roadmap-eligible` so the command and `roadmap.py` cannot drift into two readings of the same document. When it declines it names the feature, its phase-status counts, and **both deliberate ways to target it anyway — a description matching the roadmap slug, or `--phase <N>`** — then continues as a flat plan. In agent mode it **STOPs** instead of continuing flat, because the adjacent zero-eligible branch already forbids that fall-through for exactly this reason (it would silently create an unrelated top-level `tasks.json`) and nobody reads a log line there. An all-`in_progress` roadmap is still adopted and still dead-ends at the zero-eligible branch: an in-progress roadmap *is* the feature being continued, and the report must say so. The **exact-match arm is untouched** — adopting without a work check is right when you named the feature.
  - **The multiple-roadmap picker labels each option with phase-status counts instead of phase names**, so a 7-of-7-completed roadmap no longer renders identically to one with work left. The same counts go on the agent-mode STOP line for that branch, which renders no picker and would otherwise be the one caller unable to see them.
- **`--phase 2.10` now selects phase `2.1` in `/aimi:plan`, where the old string comparison found nothing.** They are the same number, every other `--phase` consumer already read it that way, and `plan.md`'s `(.id|tostring) == $n` was the anomaly. Verified by execution. The selected phase's id is re-read from the phase object afterwards, so downstream paths and CLI arguments carry the roadmap's own spelling of the id.
- **A non-canonical decimal that names no phase is now reported through `roadmap.py`'s number rendering: `verify-creates --phase 2.10` against a missing phase says `phase 2.1 not found` where bash echoed `phase 2.10 not found`.** The two bash phase-exists checks in `verify-creates` and `validate-contracts` are gone — they were a second reader of `.phases[].id`, and only one of the two normalized the number. Their Python twins print the same bytes and exit 1 the same way, so this rendering is the only byte that moves.
- **`verify-creates` argument precedence shifts in two cases, both intended.** A bad phase together with a bad `--dir` now reports the `--dir` error, and a bad phase on a host with no `python3` now reports the missing-interpreter hint. The phase check now runs behind the `--dir` test, path confinement and the interpreter check, because those three answer questions about this process's own environment and none of them can be answered by reading the roadmap. `validate-contracts` keeps `_roadmap_require_contracts` ahead of its phase check, so a pre-2.0 roadmap is still named as such rather than reported as a missing phase.
- **`/aimi:plan`'s roadmap *detection* block now requires `python3`, where it previously used only `ls` and `jq`.** This is narrower than "`/aimi:plan` needs `python3`" — the eligibility block below it was already Python-backed through `roadmap-get`, so that half never was interpreter-free. What is new is that deciding *whether to adopt* the single roadmap on disk now shells out to `roadmap.py` as well. The failure mode is a decline rather than the old adopt-then-fail, which is the better of the two, but it is a new dependency at a point that had none. **It matters most on OpenCode**, where `install.sh` copies `scripts/` wholesale and needed no change to carry the module — so the install succeeds on a host that cannot then run this block, and you meet it at first use rather than at install time.

#### Fixed

- **`--phase 02` is refused with one readable line instead of twelve lines of uncaught `JSONDecodeError`.** The guard's integer half accepted a leading zero, so `02` passed validation, reached `json.loads("02")` inside `roadmap.py`, and came back as a traceback with exit 1. It now spells the refusal out — `^(0|[1-9][0-9]*)(\.[0-9]+)?$` — and all ten call sites inherit it; `0`, `2`, `2.1` and `2.10` still pass, and the decimal half is untouched because it is the only thing keeping `2.10` admissible. **This was reachable through `roadmap-get --phase 02` before any of the work in this release**, and it had to be fixed here rather than deferred: deleting the bash phase-exists checks would otherwise have promoted the same input from a clean one-line error to a traceback in two more verbs.
- **The zero-eligible report can no longer print a heading above an empty list.** It had a filter and an `else empty` fall-through that between them could select nothing to say. It now enumerates every phase with a status-keyed reason, and splits its heading the way `roadmap-claim` already splits its exits: *no phase is pending at all*, versus *some are and every one is blocked*. Widening the filter alone would not have fixed it — a completed phase has met its dependencies and carries no claim, so it fell through the same `else`.
- **The roadmap glob is one traversal instead of two.** `ls -1 | wc -l` followed by a second `ls -1` miscounted a directory name containing a newline — one roadmap read as two — and left a window in which a concurrent session could change the answer between counting and choosing. The count, the description match and the candidate list now come out of the same expansion.
- **`has_work_map` no longer raises on a hand-edited `phases` that is not a list of objects.** A scalar `phases` reached `.get()` on an int and printed an `AttributeError` traceback, which told the agent reading the stream nothing it could act on. It answers with an empty map, as every other malformed shape in the module already does — and an empty map is the safe answer, since the rank helper leaves an unmentioned phase undemoted, so a roadmap nobody can read reorders nothing.

### Branch commit 6 — 2026-08-11

> **The `tasks.json` verbs answer from `scripts/tasks.py` now, and three lost-update races closed on the way there.** Twenty-six verbs — the six read-only ones, `list-ready`/`next-story`, the seven locked writers, the five validators, `cascade-skip`, both gates, `reset-orphaned`, `get-story-context` and `archive-task` — used to be Bash and `jq` inside `aimi-cli.sh`, re-reading the same document once per question they asked it. Each is one crossing into a module that reads it once, and for a writer that crossing happens inside the lock Bash still owns. `aimi-cli.sh` is **822 lines shorter**. Most of this is a refactor nobody can see from outside, and it is evidenced rather than asserted: **917 adversarial recordings** were captured from the `jq` **before** the `jq` was deleted, and every divergence from them is named one by one below.
>
> **Three changes are not refactors, and they are why this entry is long.** Two security fixes — `update-field` was building its `jq` program out of an argument it was handed, and `validate-tasks` would open a spec file outside the project root — and one race that lost real work, where `cascade-skip` overwrote stories that completed while it was still thinking. See *Security* and *Fixed*.
>
> **Read the `python3` bullet under *Changed* before upgrading on OpenCode.** `python3` is now required by the per-story verbs `/aimi:execute` runs on every story, not only by the roadmap verbs and `story-merge`. **Nothing breaks on Claude Code** — its hooks already spawn `python3` on every single Bash call, so the interpreter was always a harder requirement there than the CLI itself ever was. On OpenCode the install still succeeds and the requirement surfaces at first use of a verb.
>
> **Why the number is MINOR.** Against the three-line table in `plugins/aimi-engineering/CLAUDE.md` — MAJOR for breaking changes to command syntax or output format, MINOR for new commands, skills or features, PATCH for bug fixes and documentation updates — this is chosen under MINOR's *features* line, where the feature is a new runtime requirement plus a new payload key rather than a new subcommand. **This release adds no verb**, which is the whole of why 1.122.0 was MINOR and is deliberately not the reasoning reused here. PATCH is too small: a host that ran `mark-complete` yesterday and has no `python3` cannot run it today, and a bug-fix number tells that reader nothing changed for them. (1.121.3 shipped a *widened* `python3` requirement as a PATCH — it widened it to `story-merge`, a verb no user invokes, where this one reaches the verbs every spawned executor runs.) MAJOR does not reach it either: a runtime requirement is neither command syntax nor output format, no command's syntax moved, and no output field was removed, renamed or repositioned — `get-story-context` **gains** `skillsDropped[]`, and every key that was already there keeps its name and its place.

#### Security

- **`update-field` no longer builds its `jq` program out of the field path it is handed.** It was the one verb whose filter was assembled from an argument instead of from a fixed string, which made that argument program text: it was split on `.` and concatenated in with no validation at all. A field path shaped to close the filter's own parenthesis could open a second one, and the assignment then landed on a field nobody named on the command line — a story other than the one `validate_story_id` and `validate_story_exists` had just approved, or `metadata.branchName`. **`branchName` is why this is filed here and not as an input-validation nicety:** `init-session` and `validate-tasks` both gate that field to `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` precisely because `git` and `gh` consume it downstream, and a write arriving through `update-field` passed neither gate. The trailing echo-back interpolated the same argument into a second `jq` program, so one insertion point reached both. `validate_field_path` now runs ahead of the path-building loop and accepts **only a dotted chain of identifier segments** — letters, digits and underscores between the dots and nothing else; a path carrying a bracket, a parenthesis, a quote, whitespace or any other punctuation is refused by name on stderr at exit 1, in the refusal style `validate_story_id` already uses. `update-field` is deliberately **not** widened to write arbitrary nested paths: the intended contract is restored, not extended. Nothing recorded ever exercised the hole — all eight call sites live in `commands/execute.md` and every one passes the literal `verification.status` — but it was a latent hole on a public entry point of a user-facing executable. Containment is proven rather than described: after a refusal, `metadata.branchName` and every non-target story are unchanged on disk.

- **`validate-tasks` no longer opens a spec file outside the project root.** `metadata.designBundle.designSpec` and `metadata.designBundle.businessSpec` are paths read out of the tasks file, joined to the project root and opened — and nothing checked where they landed. A tasks file carrying `"designSpec": "../../etc/passwd"` had that file read and reported on: the validator answered whether a quoted literal appeared in the cited section of it, which turns a document that a human edits and that arrives in branches into a read primitive pointed at anything the CLI's own user can read. `../../.ssh/config`, a sibling checkout's `.env`, any absolute-ish path reachable by `..` — all readable, all with the answer coming back through `validate-tasks`' output. Both paths are now resolved and confined against the project root before anything is opened, following symlinks so a link out of the tree is caught too, and a path that escapes is reported as an ordinary validation error naming the offending value (`DesignSpec path escapes the project root: ../fora/Spec.md`) rather than as a missing file — the distinction matters, because "not found" would be a lie about a file that is right there. Confinement lives in `scripts/tasks.py` beside the code that resolves the paths, not in `aimi-cli.sh` beside `get_tasks_file`'s own `validate_path_in_project`, for a structural reason: these two values only become visible after the document is parsed, and confining them in Bash would mean reading the file a second time. Relative spec paths inside the root are unaffected, which is what every real tasks file uses; an absolute value was already harmless, since it is concatenated rather than joined and simply lands nowhere. The two recordings in `scripts/tests/golden_from_jq.json` that show the old behaviour reading an outside file are **kept rather than regenerated** — they are the evidence for this entry — and their single divergence is named in `_comment_validate_tasks`.

#### Added

- **`scripts/test-tasks-concurrency.sh` — a new, serial-only suite that runs two tasks.json verbs at once and asserts what the loser sees.** Four verbs read a precondition outside the lock they then write under, and no test had ever run two of them together. Nothing in the product changes with this entry; what changes is that these behaviours are now written down as assertions instead of being reachable only in production.
  - **`cascade-skip` loses a completion that lands inside its window, and the suite asserts that as CURRENT behaviour.** The transitive skip set is computed in an unlocked `jq`, and that call is the only place `status != "completed"` is ever tested; the locked apply that follows asks a weaker question — is this id in the list I computed a few seconds ago — and never re-reads status. A story that completes in between is overwritten with `status: "skipped"` and a note claiming it depends on a failed story. The window is wide enough to hit deterministically rather than intermittently: the closure is quadratic, measured at ~37ms for 50 stories, ~337ms for 200 and ~2826ms for 400, so the test sleeps 0.10s into a ~2.8s window and asserts the margin held rather than assuming it. **These assertions are green today and invert when the defect is fixed** — that inversion is meant to be the reviewable statement that behaviour changed, and until then any accidental change to this code path turns the suite red.
  - **`gate-pass` and `gate-fail` can write a gate onto a story that no longer has one.** Both check "does this story have a gate?" in an unlocked `jq` and then write under the lock; if the gate is removed in between, nothing re-asks. The write merges into `.gate`, and in jq `null + {status: "passed"}` is `{status: "passed"}` — so the verb does not refuse, it creates. The suite produces this interleaving exactly rather than approximately: it takes the lock itself and waits for the verb's own `mktemp` sibling to appear, which cannot happen until the unlocked read is already done. No sleep, no guessing.
  - **`reset-orphaned`'s divergence is report-only, and is ranked that way deliberately.** Its locked write re-selects `status == "in_progress"` and ignores the precomputed list, so the file on disk is already correct — a story that stops being in-progress mid-flight is left alone. Only the printed `{count, reset}` report, built from the stale unlocked read, can name a story it did not reset. The suite asserts both halves, so the correct-file guarantee keeps being checked after the report is fixed.
  - **It stays out of `test-aimi-cli.sh`'s four concurrent parts on purpose**, and the header says why: every assertion depends on a timing window, and four parts contending for cores compress those windows unpredictably, which is precisely how a deterministic test becomes a flaky one. `test-worktree-manager.sh` is the standing precedent. The cost is that its assertions do not roll into `EXPECTED_ASSERTIONS`; it is paid for by printing its own passed/failed totals, exiting non-zero on failure, and being named in `CLAUDE.md` beside the other suites.
  - **Both halves ship in this same release, so read this section together with *Fixed* below.** The suite was written against the `jq` and asserted the four behaviours as *current*; the fix inverts those assertions. Where the bullets above say "green today", *today* means before the fix landed, not at 1.123.0 — the inversion diff is the reviewable statement of what moved, and it is the reason the suite was written first.

#### Fixed

- **`cascade-skip` no longer overwrites a story that completed while it was running.** Its transitive skip set was computed in an unlocked `jq`, and that call was the only place `status != "completed"` was ever tested; the locked apply that followed asked a weaker question — is this id in the list I computed a few seconds ago — and never re-read status. A story that completed inside that window came back as `status: "skipped"` with a note claiming it depended on a failed story. Deterministic when it fired: **8 lost updates in 8 runs.** The window was wide because the closure was a quadratic `reduce range(length)`, measured at ~37ms for 50 stories, ~337ms for 200 and ~2826ms for 400. The verb now makes one crossing into `scripts/tasks.py` inside the lock, so the closure, both status filters, the write and the `{skipped, count}` report all run against the same document and a completion that lands first is seen.
- **`gate-pass` and `gate-fail` no longer create a gate on a story that no longer has one.** Both read the gate-present precondition in an unlocked `jq`, wrote under the lock, then re-read the result outside it — three crossings with the lock around only the middle one. Because the write merges into `.gate` and jq's `null + {status: "passed"}` is `{status: "passed"}`, a gate removed in between was not refused, it was invented. The precondition is now decided inside the crossing that writes: the verb refuses with the same `{"valid":false,"errors":["Story US-NNN has no gate defined"]}` object and the same exit status it always printed, and writes nothing. Nothing about the non-racing path changed — the refusal shape, the `{id, gate}` echo-back and both exit codes are unchanged.
- **`reset-orphaned` now reports what it actually reset — a report fix, and only a report fix.** Its locked write always re-selected `status == "in_progress"` and ignored the precomputed list, so **the file on disk was already correct** and a story that stopped being in progress mid-flight was never touched. What could be wrong was the printed `{count, reset}` list, built from a stale unlocked read, so a caller trusting stdout over the file believed it had reset a story it had not. No data was ever lost here and none is recovered; do not read this beside the `cascade-skip` entry above.
- **The proof is a diff, not a claim.** `scripts/test-tasks-concurrency.sh` asserted all four of these as *current* behaviour when it was written, green against the jq; its assertions invert in this same change, so the diff of that one file states exactly what moved and when. It discriminates in both directions and that is checked: against the pre-fix implementation the new assertions fail 9 of 18, and the pre-inversion assertions fail 8 of 18 against the fix. `scripts/tests/golden_from_jq.json` is **not** extended, edited or regenerated — it is single-threaded by construction and can observe none of this, which is why the concurrency suite exists separately.

#### Changed

- **Twenty-six `tasks.json` verbs moved out of Bash and `jq` into `scripts/tasks.py`, one crossing each.** `aimi-cli.sh` keeps what is shell-shaped — flag parsing, `validate_story_id`, `get_tasks_file`, `validate_path_in_project` over path *arguments*, `_lock` and both its strategies, and the `printf` and state-file lines each `mark-*` prints — and calls the module once; the document logic is the module's. For a writer that crossing is **inside the lock** (`( _lock "$f.lock"; python3 tasks.py <op> … ) 200>"$f.lock"`), which is now a written-down invariant with a test that counts `python3` invocations per wrapper — because *"did concurrency change?"* is not a question a reviewer can answer by reading a diff, and *"how many times does this wrapper cross?"* is. Nothing about a verb's flags, its stdout shape or its exit codes was meant to move, and the 917 recordings are what say whether it did. `cmd_init_session` deliberately did **not** move: it resolves `$0` and writes that path into both the session state and the global CLI cache, and inside `tasks.py` `$0` is the `.py` file — porting it would have put a Python module's path into `~/.config/aimi/cli-path` and broken every later resolution one session afterwards. `.aimi/state/` never crosses either, so the state lock and its path confinement keep one owner.
  - **What the port collapsed, because a port that de-duplicates nothing is not worth running.** The `maxConcurrency` default clamp was written out **three times** in `aimi-cli.sh` and is one function now (a fourth copy stays in `hooks/pre-bash-dispatcher.py` on purpose — separate process, no import path, and it deliberately implements a different rule; comments at both ends now name each other). `list-ready` and `next-story` stand on **one** readiness predicate: `next-story` used to run `list-ready` as a shell function and re-sort its output through a `jq` of its own, so "one implementation" held only until somebody touched either. And `validate-tasks` lost three pieces of scaffolding that existed only because eight reads of one document meant eight `jq` startups — a `\037` field delimiter, a `// ""` that could never be `// empty`, and a ninth sentinel variable with no ninth field. **Measured**, same 73KB tasks file with both spec gates open, best of twelve over three rounds: **0.28s → 0.10s**, eight `jq` processes becoming one `python3`, counted with a shim on `PATH` rather than read off the source. `archive-task` measured **232ms → 117ms** the same way, five `jq` processes becoming zero.
  - **Path confinement is split on a real boundary and stays split.** `validate_path_in_project` in `aimi-cli.sh` remains the sole authority over every path that arrives as a CLI *argument* — it runs before `python3` starts, so an escaping argument is refused without the document being read at all. The paths that come *out* of the document — `metadata.designBundle`'s two spec paths, `metadata.brainstormPath`, `metadata.researchPaths[]`, `metadata.prototypePaths[]` — are confined in `tasks.py`, because they exist only after the crossing and routing them back would mean reading the file a second time. The Python check is an exact port of the Bash rule, refusal message and exit status included, and both of the two distinct call-site orderings survive: research and prototype paths are confined **before** their existence check, `brainstormPath` only inside it.

- **`get-story-context` — the verb every spawned story executor runs first — now answers from one `python3` process, counts its 100KB skills cap in BYTES, and reports what it dropped.** Three changes a caller can see, and one they only feel. (1) **The cap counts bytes.** It was `${#skill_content}`, which counts bytes under `LC_ALL=C` and characters under `LC_ALL=C.UTF-8` — so the same story hydrated five skills on one machine and four on another, silently, depending on the caller's locale. The SKILL.md files shipped here are full of em-dashes and arrows, so a 34,200-character body measures 102,600 bytes: over the cap by one reading and comfortably under it by the other. Bytes is what a payload cap defends, and both locales now answer identically. (2) **A skill whose own body exceeds the cap is dropped by itself, before the aggregate trim.** It used to take everything declared after it down with it — the trim popped from the END until the total fit, so the two small skills behind a 100KB one were evicted first — and then killed the verb outright, because `(( total -= n ))` returning 0 exits 1 under `set -e`. The executor received an empty payload and no diagnostic. Declaration order is priority order again, and the oversized entry gets its own warning naming it and its size. (3) **The payload carries `skillsDropped[]`**, entries of `{name, bytes, reason}`, `[]` when nothing was dropped so the key is always present and always safe to read. The eviction warnings stay on stderr, where they always were — stdout is piped straight into a JSON parse by every consumer there is, which is exactly why a caller using `2>/dev/null` could not previously tell a hydrated skill set from a halved one. `skills/story-executor/SKILL.md` documents the new key. The first four keys keep their positions: against this repository's own tasks file, three real stories produce payloads byte-identical to the pre-port CLI apart from the appended `skillsDropped`.
  - **Two crashes go away with the shell that caused them, and neither was ever reported anywhere.** An **empty `SKILL.md`** declared first returned exit 1 with empty stdout AND empty stderr — the same `((expr))`-returns-1 trap as above, tripped by a zero running total. And a `## Design Decisions` section larger than a pipe buffer died of **SIGPIPE** (exit 141, no output) when `head -c 65536` closed the pipe under `set -o pipefail`, which means the 64KB truncation that pipeline was written for was unreachable: anything big enough to trigger it killed the verb instead. Both now behave as the code always read as if it did — an empty skill hydrates as `content: ""`, a long decisions section truncates at 65,536 bytes.
  - **It is faster because it stopped being quadratic, and the number is measured rather than asserted.** 8 fixed `jq` invocations plus one per skill became zero, and the per-skill accumulator that re-serialized every body already read on each new one became one list append and one serialization. 20 calls per sample after two discarded warm-ups, four samples of each build run alternately from the same directory on Linux 6.8 x86_64 / 16 cores, against one story declaring five skills: **447.4 ms → 143.3 ms, a 3.1x reduction** in whole-CLI wall time (pre-port medians 445.2/446.0/448.7/464.2 ms, post-port 141.3/142.9/143.7/143.8 ms). Whole-CLI deliberately — bash startup, `find_aimi_root`'s `git rev-parse`, `get_tasks_file` and `validate_story_exists`' own jq are still in both numbers, because they are what the agent waits for; the function itself is where the ~6x lives. That cost is paid inside every agent `/aimi:execute` spawns, once per story.

- **The fourteen rule-bearing tasks.json verbs are now pinned by their whole contract — exit code, exact stdout shape, and resulting on-disk state — instead of by an exit code and a substring.** `validate-ids` had no assertions at all; `cascade-skip`, `gate-pass`, `gate-fail` and `reset-orphaned` had nine between them. Two things the old coverage would have let a rewrite quietly change are now written down: `validate-ids` **accepts a lowercase-suffixed id** such as `US-001a` (its regex permits it and the schema documents it, while its error wording says "expected US-NNN", which describes the common case and not the rule), and its output shape is **asymmetric** — the pass branch carries no `errors` key and the failure branch carries no `count`. Also pinned: `validate-waves` **exits 0 even for an invalid verdict**, so a caller branching on `$?` rather than on `.valid` sees a pass. That is current behaviour and is now recorded as such rather than left to be discovered.

- **`python3` is now required by the `tasks.json` verbs as well, which retires a promise this CHANGELOG made twice.** 1.121.2 and 1.121.3 both told you that every non-roadmap verb stayed pure Bash and `jq` and would keep running on a host without an interpreter. That was true when it was written and it is not true now: `mark-complete`, `mark-in-progress`, `mark-failed`, `mark-skipped`, `list-ready`, `next-story`, `count-pending`, `get-story-context`, `status`, `metadata`, `get-story`, `current-story`, `get-state`, every validator, `cascade-skip`, both gates, `reset-orphaned`, the two normalizers, `update-field` and `archive-task` all cross into `scripts/tasks.py`. `check_python3()`'s scope is the whole CLI now and its message says so rather than naming a family of verbs; the install hint still names `brew install python` (macOS) and `apt install python3` (Linux). **Those two past entries are left exactly as they were** — they are the record of what shipped then, not a claim about today — and the two *live* statements that repeated the promise, in the root `CLAUDE.md` and in `plugins/aimi-engineering/CLAUDE.md`, are corrected in this release instead.
  - **The break lands on OpenCode alone, and it lands at first use rather than at install.** On Claude Code `python3` was already a harder requirement than the CLI's own: `hooks/hooks.json` wires `hooks/pre-bash-dispatcher.py` on `PreToolUse`/`Bash`, so every Bash call in every session already spawned an interpreter and a session without one never reached a verb at all. **Nothing on that host breaks.** `install.sh` **wires no hooks** — `grep -i hook install.sh` returns nothing; the hook *files* travel with its wholesale `cp -R "$src/."`, but nothing registers them and nothing runs them, so an OpenCode session never spawns `python3` on its own. That same wholesale copy carries `scripts/tasks.py` with no installer change, so the install itself still succeeds. Nor is there a dependency preflight in it to catch this: its only `command -v python3` is a *fallback* for editing JSON config when `jq` is missing. So on OpenCode you meet the requirement at the first verb you run, not while installing.
  - **One verb hides it, which is worth knowing while diagnosing.** Most refuse loudly with the install hint at exit 1. `next-story` runs its crossing inside a command substitution guarded by `|| story=""` — deliberately, so `/aimi:next` reads "no story is ready" as a clean stop rather than an error — so on a host with no `python3` it prints the hint on stderr and still answers `null` at **exit 0**, which its caller reads as *all stories complete*.
  - **What still runs without `python3`**: `init-session`, `version`, `check-version`, `prime-cache`, the `detect-*` and `forge-*` families, `setup-branch`, `estimate-payload` and `list-archivable`. Treat that as the residue rather than the rule — assume `aimi-cli.sh` needs `python3`.

- **`archive-task` and `list-archivable` disagree about whether an empty document is archivable, and this release pins the disagreement rather than resolving it.** `list-archivable` calls `_archivable_file_is_terminal`, which additionally requires `userStories` to be **non-empty**; `cmd_archive_task` carried its own copy of the same check without that clause. A tasks file whose `userStories` is `[]` is therefore never offered by the list and is accepted by the act. That was already one rule with two implementations, in one language, before any port; `archive-userstories-vazio` records the acceptance, so it is pinned by data now instead of living unread in two places. `list-archivable` deliberately did not move — porting it would mean reproducing `find | xargs -0 ls -t` ordering, which has no test coverage at all today, inside the one slice whose entire value rests on a proven no-behaviour-change. Deciding which of the two readings is right is its own change.
  - **`archive-task` still moves `<tasks>.lock` into the archive beside the document, and still takes no lock of its own.** A writer holding `flock` on that inode keeps holding it while a writer arriving a moment later opens the original path, creates the file fresh, and takes an uncontended lock on a **different inode** — so the two have no mutual exclusion at all. This is unchanged behaviour rather than a regression, and it is preserved on purpose: everything the port's evidence is worth for the one verb that deletes a user's files rests on showing that verb changed nothing, and a concurrency fix in the same change destroys that proof exactly where it matters most. `archive-lock-acompanha` records it so it cannot drift in silence, and the fix is deferred to its own labelled change. A `.lock` that is a *directory* is still left behind rather than moved, for the same `[ -f ]` reason.

- **Every intentional divergence from the recorded `jq`, named where it landed.** Delta zero is the claim for the port slices, and these are its exceptions; each sits in `scripts/tests/golden_from_jq.json` beside the case that caught it, and the deliberate ones are kept in tables of their own so that a decision is never filed as an engine excuse.
  - **Exit code and stderr where `jq` aborted mid-expression** — the largest class by far, and reachable only with documents the schema does not allow: 37 cases across the six read-only verbs, 37 across `list-ready`/`next-story`, 5 across the writers, 39 across the four validators, 5 in `validate-tasks`, 6 in `get-story-context`, 3 in `archive-task`. In each, the pre-port CLI exited at `jq`'s own status (often 5) with the message swallowed by a `2>/dev/null` on the assignment that ran it; the Python refuses at 1 with a message you can read. All of them still refuse, and every one still leaves the document byte-identical — which the recordings compare rather than assert.
  - **Two cases where bash's own `[` complained** about a value it could not compare and the `if` read the complaint as false. Both still do what they did: a two-document tasks file is archived anyway, with the complaint the only trace.
  - **No path leaves a temp file behind any more.** Three writer cases hand the verb a `.lock` that is a *directory*, so the redirect fails before the lock body runs; the pre-port Bash had already run `mktemp`, and `set -euo pipefail` ended the script before the matching `rm -f`. That leak is the one thing the port does not reproduce, and cannot.
  - **`validate-tasks`' two escaping-spec-path recordings keep the old outside-read**, at exit 0, having read a file one directory above the project root. They are neither regenerated nor skipped: what the `jq` did *is* the finding behind the Security entry above, and the new refusal is asserted separately — including that no word of the outside file reaches stdout.
  - **`get-story-context`'s three rule changes** — the byte cap, the oversized skill dropped up front, and `skillsDropped[]` always being emitted — are the *Changed* entry above, and are recorded as decisions rather than as aborts.
  - **Reproduced rather than tidied away, because each would be a regression to "correct":** an empty tasks file still prints nothing at exit 0, and still makes `list-ready` print a bare newline without `--brief`; a file holding two concatenated documents still runs the verb twice and comes back with **both** rewritten; a `priority` written as `3.0` still comes back as `3`; `validate-ids` still accepts `US-001a` while its message says *expected US-NNN*, and its output is still asymmetric (`{valid, count}` on the pass branch, `{valid, errors}` on the failure one); `validate-waves` still exits 0 for an invalid verdict; the plural-`gates` message still carries no quotes around the field names, because the `jq` lived in a single-quoted Bash string and the quotes the author typed closed it; a dangling `dependsOn` id still *ends* the dependency walk instead of merely failing to block, so `["US-999","US-001"]` is ready where `["US-001","US-999"]` — the same two ids, other order — is blocked; a story whose `priority` is null or absent is still picked **first**, ahead of priority 1, and priority ties still fall back to file order; `archive-task`'s `-N` collision suffix still splits the basename on the **first** dot (`corpus.v2-tasks.json` → `corpus-2.v2-tasks.json`); its deletes are still non-recursive, so a directory named in `researchPaths` still ends the run with GNU `rm`'s own wording and the directory survives whole; and the tab collapse that `validate-tasks`' `\037` delimiter existed to fix is still live in the two scans that never got it.

### Branch commit 7 — 2026-08-12

> **`cleanup-versions` was deleting the NEWEST installed version and reporting success.** It resolved "latest" with a lexicographic `ls <cache glob> | tail -1`, and `ls` collates `1.121.3` *before* `1.9.0`, because `1` sorts below `9` at the third character. So on a cache holding 1.9.0 next to 1.123.0 it `rm -rf`'d **1.123.0**, kept **1.9.0**, wrote 1.9.0's path into `~/.config/aimi/cli-path` through `write_global_cli_cache`, and printed `{"removed":1,"kept":"1.9.0"}` — which reads like success. Every session afterwards ran the older CLI out of the global cache. This plugin's published history spans **1.9.0 to 1.123.0**, so that pairing is reachable on any long-lived install rather than hypothetical. What it destroyed was the newest install's directory — plugin files, not your work — and what it left behind was worse than the deletion: an upgrade you performed and the tool silently reverted, with no message anywhere saying so. Measured in both directions against a throwaway cache holding both versions: before, `{"removed":1,"kept":"1.9.0"}` with only 1.9.0 left on disk; after, `{"removed":1,"kept":"1.123.0"}` with only 1.123.0 left. **Read this entry first.**
>
> **This release ships a branch scoped as "move the remaining non-forge `jq` into Python", and what it mostly delivered was fixes.** A destructive deletion; four silent deaths, each of them empty stdout *and* empty stderr, which is the failure nobody notices and nobody reports; two documented outputs that had never once been emitted in the plugin's life; spawned agents reading a different installed version than the CLI that spawned them; and a model picker offering ids the resolver then refused. Do not read the word *refactor* in the commit history and skip the sections below.
>
> **Two documented outputs start appearing for the first time, and that is a compatibility event rather than a repair.** `check-version`'s `{"status":"unknown","message":"No installed version found"}` and `cleanup-versions`' `{"removed":0,"kept":null}` were unreachable dead code: an empty plugin-cache glob put a non-zero status into a bare assignment, and `set -euo pipefail` aborted both verbs above their own handlers. **A caller that read "check-version aborts" as its no-plugin signal now receives exit 0 and a JSON object instead.** Read `check-version`'s `status` field rather than its exit code alone. Every consumer was grepped and each is named under *Changed*.
>
> **`python3` widens again, it lands on OpenCode alone, and the boundary is narrower than "the CLI needs it".** The whole `models.json` surface crossed — the four readers *degrade*, `detect-models` *refuses* — and `init-session` joined the tasks verbs in refusing. The four verbs that LOCATE the CLI (`version`, `check-version`, `cleanup-versions`, `prime-cache`) deliberately did **not** cross, because a Python gate there would make finding `aimi-cli.sh` depend on a module that lives in the directory being found. Full boundary under *Changed*; **it matters on OpenCode and nowhere else**, and it surfaces at first use rather than at install.
>
> **Why nothing is filed under *Security*, argued rather than defaulted.** Two items here have a plausible claim on that section and neither takes it. The `cleanup-versions` deletion destroys data at `rm -rf` scale and writes a downgraded path into a global cache, which is a security bug's blast radius — but there is no attacker in it and no privilege boundary is crossed. It is a comparison operator that was wrong for every user equally, triggered by nothing more adversarial than upgrading twice. Filing it under *Security* would tell you someone could do this to you, and nobody could; it is filed at the top of *Fixed*, where its severity is carried by the words instead of by the heading. The second candidate is the nested `bash -c` that expanded `$CLAUDE_CONFIG_DIR` into another shell's program text — genuinely exploitable, and measured as such: against the pre-fix code a `CLAUDE_CONFIG_DIR` of `cfg";touch MARKER;ls "` created the marker while `prime-cache` still reported `not_found` at exit 0. It is filed under *Changed* as hardening, because reaching it requires prior control over this process's own environment and anyone holding that already runs commands directly — the exposure it removes is real, the threat model it removes is not. Both closures carry permanent regression cases regardless of which heading they sit under.
>
> **Why the number is MINOR, argued against both precedents by name.** **PATCH is ruled out.** 1.121.3 took PATCH for a refactor with nothing for a reader to do — no flag moved, no output changed, nothing needed migrating. This release is the opposite on three counts a reader must act on: two output shapes callers can now receive where a verb used to abort, a runtime requirement that widens onto a new document family, and a `version` verb that now exits 1 where it used to print the four-letter string `null` at exit 0. A bug-fix number would tell that reader nothing changed for them. **MINOR is what 1.123.0 took** for a new runtime requirement with no new verb, and this release is that same shape plus a destructive-deletion repair and two newly-reachable outputs — a superset of the same reasons, so it takes the same level rather than inventing a second argument. **This release adds no verb**, which is worth saying out loud because a new verb is what MINOR usually buys here and is deliberately not the reasoning used. **MAJOR is addressed and rejected.** By the plugin's own three-line table — MAJOR for breaking changes to command syntax or output format — no command's syntax moved, and no output field was removed, renamed or repositioned. The two shapes that start appearing were always *documented*; what changed is that they became reachable, and an abort was never a documented contract that could be taken away. The closest call is `version`, which stops printing `null` for a manifest carrying no string `version` key and refuses by name instead — the removal of an output no document ever promised and no caller could have acted on. That is the argument, not an omission.

#### Fixed

- **`cleanup-versions` no longer deletes the newest installed version.** The full account is in the preamble above; this is the shape of the repair. One helper, `_resolve_latest_cache_path`, owns the comparison, and the four in-file sites call it: `cmd_check_version`, `cmd_cleanup_versions`, `cmd_prime_cache` and `_resolve_skills_base_dir`. It is deliberately **not** a plain `sort -V` over the globbed paths — the cache glob spans two wildcards, so sorting whole path strings orders by marketplace-entry directory first and by version only *within* one entry, which reintroduces the same bug class on a host with two marketplace entries. Each candidate carries its own version segment and the sort keys on that segment alone. Five sites outside `aimi-cli.sh` cannot call a function that lives in the file they are still locating, so they carry the version-aware idiom inline with a comment naming the helper as the canonical rule: the `--help` EXAMPLES block, both glob blocks in `commands/references/cli-path-resolution.md` (the CLI's and `worktree-manager.sh`'s), `commands/review.md`, `commands/validate-bug.md` and `resolve-pr-parallel`'s `_resolve-cli.sh`. Patterns 7 and 8 of `hooks/auto-approve-cli.sh` match those published one-liners **literally**, so they moved in step or the commands would have stopped being auto-approved and started prompting; all four one-liners were replayed through the hook to confirm they are approved and a tampered variant still is not.
- **Spawned agents and the CLI now resolve to the same installed version.** `_resolve_skills_base_dir` took the lexicographically **first** cache match while CLI-path resolution took the **last**, so with 1.122.0 and 1.123.0 both cached the two answered with different installs in the same session — measured live as skills at `…/1.122.0/skills` against a CLI at `…/1.123.0/scripts/aimi-cli.sh`. That is what decides which `SKILL.md` every spawned agent reads, so **agents were running the previous version's instructions while the CLI ran the new one**. The visible consequence, and the reason this is worth an entry rather than a footnote: after an upgrade, agents behave differently than they did before, because until now they were not upgrading with you. The comment beside the resolver records that this is a decision and not a head-to-tail typo fix.
- **`aimi-cli detect-models` no longer exits silently without writing anything when the host's model list contains no model named "haiku".** `grep -i haiku` over a list with no match exits 1, `pipefail` made that the pipeline's status, and the assignment taking it was bare — so `set -euo pipefail` took the shell down with **empty stdout, empty stderr and nothing written**, leaving any existing `models.json` untouched and unexplained. The three documented fallbacks sitting directly underneath (first line for fast, second for balanced, last for powerful) were unreachable dead code, which is worse than absent: the file said the case was handled. Reachable on OpenCode with a non-Anthropic provider set, and not on Claude Code, whose list is the literal `opus`/`sonnet`/`haiku`. A host with `openai/gpt-5`, `google/gemini-3-pro` and `meta/llama-4-405b` now writes its table, and the other host's `categories` sub-table is preserved on that path like every other.
- **A non-string model id no longer takes `resolve-models` down with it.** `resolve-models` documents three things about itself — stdout is always valid JSON, warnings go to stderr, every failure path prints the all-`inherit` fallback and returns 0 — and a category whose value was `true`, `5`, `{}` or `["opus"]` contradicted all three at once, exiting **5 with empty stdout and empty stderr**. Eight commands and skills call this verb once per invocation, so what they saw was a silent non-answer from the one verb that promises never to give one. A non-string is now treated as the invalid id it is: one warning naming it, rendered the same compact way jq's own string interpolation rendered it (`true` reads `true`, `["opus"]` reads `["opus"]`), and `inherit` in its place.
- **`list-models` no longer offers ids that `resolve-models` refuses.** `/aimi:setup-models` lists choices with `list-models` and stores them for `resolve-models` to read back, and the two disagreed. With an `opencode models` line padded with two spaces, `list-models` piped it through `jq -R .` untrimmed and offered the padding verbatim, while `resolve-models` trimmed the *list* with jq's `ltrimstr(" ")`/`rtrimstr(" ")` — **one** space each, not all — and never trimmed the candidate at all. The padded id **and its fully trimmed twin were both refused**, so nothing the user could copy out of the offered list was acceptable, and the configured model silently degraded to `inherit` with a warning they only saw on the next run. An empty line in that same output was offered as the JSON string `""`. One normalizer, one host-valid-set builder and one membership predicate now serve all five sites; the regression test drives a four-line stub (plain id, padded id, empty line, plain id) and asserts that every id `list-models` offers survives `resolve-models` with no warning and no degrade.
- **`version` no longer answers for a manifest that has no version.** Its only guard was that `plugin.json` exists, and `jq -r '.version'` answers well below that bar: the literal string `null` at exit 0 for a document with no `version` key, a JSON object pretty-printed across four lines at exit 0 when the key is not a string, and jq's own parse error at exit 4 for malformed JSON. This is the CLI identity probe — a caller comparing its output against a version, or a human reading it, is entitled to a version string or to an explanation, and `null` dressed as a version is neither. One `jq -er` with `empty` covers a missing key, a non-string key and a parse failure in the same branch, and each exits 1 naming the file. **Callers that captured `version`'s stdout without checking its exit status now get an empty string where they used to get `null`.**
- **The global CLI cache no longer stores a path that is about to disappear.** `write_global_cli_cache` refuses a path under a `.worktrees/` segment, because caching a throwaway checkout globally points every later session at a file that vanishes on worktree cleanup — exit 127, out of a cache file nobody thinks to look at. The refusal matched the path **string**, so a plugin-cache entry that is a *symlink* into a worktree carried no such segment in its own name and sailed straight past it. All three verbs that write the cache reached it, not just one. The resolved path is checked as well as the given one now; the string test still runs first and still answers alone for the common case, and a path that cannot be resolved falls back to the string verdict rather than refusing, because refusing is the branch that silently does nothing. The refusal remains a no-op success returning 0 — that contract is load-bearing and unchanged — and `check-version --fix` still writes the per-project `cli-path`, which is a different writer and was never this guard's business.
- **A model id containing a newline no longer produces a second warning naming a category that does not exist.** The invalid-entry tagging was split back apart by a line-oriented `read` loop, so line 2 of the id was read as a category name with an empty model, and the user was told about a category they had never configured. One invalid category is one warning now, carrying the whole id. The delimiter that made this possible had already been changed once, from `=` to a tab, after a model id containing `=` truncated a message; it is deleted rather than changed a third time.
- **A failed `init-session` no longer leaves a stale `.aimi/current-branch` behind.** Its three document reads used to happen one jq at a time, so a document that jq refused at the *second* read had already had the first read gated and `current-branch` already written. One crossing cannot fail one read at a time, so a refusal now leaves strictly less state behind — on a document the previous implementation would not have finished reading either.
- **Aborts that said nothing now refuse with a line you can read.** For `init-session`, `research-gc` and `list-archivable`, the failure mode on a document the engine could not parse was jq's own exit 4 or 5 with its message swallowed by a `2>/dev/null` on the assignment that ran it — a number and a silence. Those paths refuse at exit 1 with one line naming the verb, the file and the shape it could not read. The verdict is unchanged in every case — everything that was refused is still refused, everything that was included is still included, `list-archivable`'s array and its order are byte-identical across all 46 recorded cases — and every document is still left untouched.

#### Changed

- **`check-version` and `cleanup-versions` no longer abort on a host with no plugin version installed.** They emit their documented `{"status":"unknown","message":"No installed version found"}` and `{"removed":0,"kept":null}` at exit 0. **Both shapes are new in practice**: an empty plugin-cache glob used to kill the verb before either branch was reached. `_resolve_latest_cache_path` always returns 0 now and answers with the empty string, so "nothing installed" is a value every caller tests with the `[ -z "$var" ]` it already had — a helper whose safety depended on the caller remembering to append `|| var=""` was the defect, so it no longer has a failure mode to forget. **Every consumer was grepped, with its verdict:**
  - `commands/references/cli-path-resolution.md` — **normative, and updated in this release.** Its old rule "if `check-version` exits 0, no action is needed" would newly classify a host with no plugin installed as healthy. It now carries a status table and says which exit-0 status is not a healthy host.
  - `commands/review.md` and `commands/validate-bug.md` — both call `check-version --quiet --fix`, and both change from an abort to a clean exit 0 on a cache-less host. **Neither reads the exit code**, so neither needed an edit.
  - `hooks/auto-approve-cli.sh` — allowlists by verb **name**, never by exit code. Verified unaffected rather than assumed.
  - `install.sh` and `commands/init.md` — consume `prime-cache`. **That sentence read "whose contract is unchanged and whose empty-cache recording replays byte-identically", which was accurate when it was written and is not any more; it is corrected here rather than removed.** `prime-cache`'s empty-cache answer moved later in this same unshipped release — see *After the branch — prime-cache stops answering a missing install with a refusal* above — so `pc-cache-vazio-com-plugin-dir-both` no longer replays byte-identically and is named in `KNOWN_DIVERGENCES` with the two fields that moved. Fifteen of the seventeen recorded `prime-cache` cases still do. **Neither consumer needed an edit even so**, and the reason is narrower than the retired claim: `install.sh` branches on `"status":"error"` and the status it stops receiving is `error`, so it moves from a spurious warning to a clean log line; `commands/init.md` renders every documented status by name and already carried a `not_found` arm.
- **`python3` is now required by the whole `models.json` surface and by `init-session`, and the boundary is stated exactly rather than generalised.** The four **readers** — `resolve-models`, `get-current-models`, `models-prompt-check` and `list-models` — each answer from the new `scripts/models.py` at one crossing, and **none of them calls `check_python3`**: `resolve-models` runs once per invocation of `/aimi:brainstorm`, `/aimi:plan`, `/aimi:deepen`, `/aimi:execute`, `/aimi:review`, `/aimi:validate-bug`, `design/polish` and the task-planner skill, so a hard `exit 1` there would turn a python3-less OpenCode host from "works" into "every command dies at its first CLI call", which is a regression against the pure-jq behaviour being replaced. Each degrades to what it already promises when it cannot read the config — all-`inherit`, all-`null`, `prompt`, the built-in Anthropic list — with one line on stderr naming the missing interpreter, and **exit 0**. **The consequence worth knowing before diagnosing a support report: a *configured* OpenCode user with no `python3` silently receives the *unconfigured* answer rather than an error.** A missing or empty config file is byte-identical with or without an interpreter, because the check sits after the branches Bash answers on its own.
  - **`detect-models`, the writer of that same file, makes the opposite choice on purpose.** It calls `check_python3` and **refuses at exit 1 before it reads, prompts or writes anything**. A reader always has an honest degrade available — the unconfigured answer is a real answer. A writer has none: writing the current host's five values alone is exactly the regression fixed in 1.97.2, where the inactive host's table was dropped on every invocation, and writing nothing while returning 0 tells `/aimi:setup-models` the config was saved when it was not. So on a python3-less OpenCode host every command still works and every model still resolves; **what stops is re-configuring them**, which is what `commands/setup-models.md` already told its reader to expect.
  - **`init-session` refuses like every other tasks verb; `list-archivable` degrades to an empty list.** `init-session`'s three `tasks.json` reads crossed, so it calls `check_python3` — but its own self-resolution, the two writes that persist this script's path, never crossed and never will: inside a Python module `$0` is the `.py` file, and persisting that would have the next session load a module as a shell script. `list-archivable` gained a second crossing (into `roadmap.py`, for the phase-status half of its answer) and still refuses to break: its predicate answers "not archivable" for a document it cannot read and says nothing, so an interpreter-less host gets an empty list rather than a broken command, and the roadmap read is never even reached because the loop has already moved on.
  - **The four version and cache verbs stayed pure Bash + `jq`, and that is a decision with a reason.** `version`, `check-version`, `cleanup-versions` and `prime-cache` are what **locate** `aimi-cli.sh`, and every Python module lives in the directory being located — a `check_python3` there would make finding the CLI depend on having found it. `install.sh` runs `prime-cache` *during* the OpenCode install and `cli-path-resolution.md` runs `check-version --quiet --fix` after *every* resolution; both would start requiring an interpreter on hosts that today need only Bash and `jq`. `cmd_prime_cache`'s header comment is the normative home of that decision.
  - **Where the requirement bites, verified by reading `install.sh` rather than assumed.** Under Claude Code `python3` was already a harder dependency than the CLI itself — `hooks/hooks.json` wires `hooks/pre-bash-dispatcher.py` on `PreToolUse`/`Bash`, so a session without an interpreter never reaches a verb — and **nothing on that host changes**. `install.sh` **wires no hooks**: `grep -i hook install.sh` returns nothing, and while the hook *files* travel with its wholesale `cp -R "$src/."`, nothing registers them and nothing runs them, so an OpenCode session never spawns `python3` on its own. That same copy carries `scripts/models.py` with no installer change, so the install still succeeds on a host that cannot then run the verb; and there is no dependency preflight to catch it, because `install.sh`'s only `command -v python3` occurrences are a *fallback* for editing JSON config when `jq` is missing. **So the break lands on OpenCode alone and you meet it at first use, not at install time.**
  - **A correction to 1.123.0, made here rather than by editing it.** That entry's *"What still runs without `python3`"* bullet named `init-session` and the whole `detect-*` family. Both statements were accurate when they shipped and neither is accurate now: `init-session` refuses, and `detect-models` is the one `detect-*` verb that needs the interpreter. **The 1.123.0 entry is left exactly as written** — it is the record of what shipped then, not a claim about today — and the live statements that repeated it, in the root `CLAUDE.md` and in `aimi-cli.sh`'s `check_python3` header comment, are corrected in this release instead. That is the same handling 1.123.0 gave its own retired promise.
- **Model-id normalization is trim-only, which changes which ids are accepted.** Three consequences a user can see. (1) The interactive picker stopped using `tr -d '[:space:]'`, which deleted **internal** whitespace too and silently repaired the typo `son net` into the valid alias `sonnet`; it trims the ends and asks the shared predicate now, so **a typo is a typo again** and falls back to the category default. (2) A padded id in a hand-edited `models.json` is **accepted** and resolves to its trimmed form instead of degrading to `inherit`, and no downstream consumer is handed a model id with spaces around it; `list-models` emits that same normalized set, so its array can no longer contain `"  anthropic/claude-sonnet-4-6  "` or `""`. (3) `detect-models` flag mode validated nothing and wrote whatever it was handed; it now writes the **normalized** id and **warns on stderr when the id is not valid for the host — but still writes it and still exits 0**. That boundary is deliberate: `/aimi:setup-models` writes through this path and its picker offers a free-form "Other", and validation in this CLI happens at read time. The one new hard error is a value that is non-empty but normalizes to empty, which is an argument mistake rather than a wrong id.
- **The `models.json` surface, the last five `jq` reads of `tasks.json`, `list-archivable`'s roadmap half and `set-execution-mode` moved into Python, one crossing each.** `models.py` is new; `tasks.py` gained `init-session`'s three document reads, `get-branch`'s fallback, `research-gc`'s walk and both counts in the archivable predicate; `roadmap.py` gained the phase-status rule `list-archivable` had been re-deriving in `jq` beside it. `set-execution-mode` was the last `tasks.json` wrapper doing its own read-decide-write in Bash — its phase guard was a `jq` read *outside* the lock and its assignment a second `jq` inside it — and the invariant test that should have caught it selected on wrappers that *already* crossed, so a wrapper crossing zero times was discarded before the comparison ran. That check selects on the **lock** now, and the exhaustive set went from 11 wrappers to 12. **No race was reachable and none is claimed**: nothing mutates `metadata.phase` at runtime. What was wrong was the shape, and the sentence claiming every such wrapper crossed exactly once.
  - **Delta zero is the claim for the port slices, and it is evidenced rather than asserted.** **373 new adversarial recordings** were captured from the `jq` **before** the `jq` was deleted — 114 across the four `models.json` readers, 60 across `detect-models`, 51 across the version and cache verbs, 65 across the session-document readers, 37 across `research-gc` and 46 across `list-archivable`'s roadmap half — and every divergence from them is named one by one, by case label and by field, in `scripts/tests/golden_from_jq.json` and the `KNOWN_DIVERGENCES` tables beside it. Where a rule genuinely changed, the golden file changed in the same commit as the rule and by hand, never by regenerating it from the new code. The bash suite grew by **159 assertions**.
  - **Two things were preserved rather than improved, because "correcting" them would be this release changing its mind.** `research-gc`'s walk still **stops** at the first tasks file it cannot read instead of skipping it, and `archive-task` still accepts a `userStories: []` document that `list-archivable` refuses to offer. Both disagreements are now pinned from both sides so they cannot reconcile by accident, and resolving either is its own change with its own tests and its own entry.
- **The cache glob no longer runs inside a nested `bash -c`, and no config directory is ever expanded into another shell's program text.** It is a plain Bash array assignment now — no `ls`, so there is no exit status for `pipefail` to propagate, and an unmatched pattern is told apart from a real match by testing the first element with `-e` plus `-L`, so a dangling symlink still counts as the match `ls -d` would have printed. This is the hardening argued in the preamble; the ordering is untouched, which is what lets the six out-of-file copies of the idiom stay in agreement without this change having to move them.
- **A validator in `prime-cache` that could never reject was deleted rather than made real.** Its OpenCode branch tested `candidate` against the expression it had been assigned from four lines earlier, so the comparison was tautologically false and its error branch could not execute. Nothing enters that string from a caller — it is constructed from `$plugin_dir`, which `_validate_plugin_dir` has already checked, and what the cache must not later *accept* is re-checked on read by `_validate_cached_cli_path`. An unreachable branch left standing is worse than no branch, because it reads like an assurance that traversal is handled at that point.
- **What is still `jq` in `aimi-cli.sh`, and the principle that decides it, is written down once.** `plugins/aimi-engineering/CLAUDE.md` gains a section carrying the organising sentence — *port where input the script does not control enters; leave it where the script is only talking to itself* — a measured per-family census with an as-of marker and an instruction to re-measure rather than quote it, and the reason each surviving family stays. The root `CLAUDE.md` carries one pointer line and no second statement, because those two files have drifted before by saying the same thing twice.

#### Known gaps

Six findings this branch's corpora surfaced and deliberately did **not** repair. Each is recorded in the tree beside the code it concerns; a release that ships this many fixes should also say what it did not fix.

- **`sort -V` orders a non-version directory ABOVE a real version**, so `cleanup-versions` would `rm -rf` the genuine install, keep the junk directory and write *its* path into the global `cli-path` — the same data loss as the headline entry, reached by another route. Left because deciding what counts as a version directory is a policy with its own blast radius: `1.2.3-beta.1` is legitimately not `N.N.N`.
- **The OpenCode models cache is keyed on the wrong file's mtime and is never collected.** `models-oc-cache-<mtime>.txt` is keyed on `models.json`'s mtime while the file stores `opencode models` output, which changes when `opencode` is upgraded or a provider is added — not when `models.json` is edited. Fixing the key changes *when* a shell-out happens, so it could not ride inside a delta-zero commit.
- **`detect-models --research` with no value exits 1 with both streams empty.** The flag arm shifts to read its value and the loop bottom shifts again, so on an exhausted argument list the second `shift` returns 1 under `set -euo pipefail`. Argument-parser scope, not the merge's.
- **One malformed tasks file truncates `research-gc`'s referenced set** and deletes the research every *later* file names. The walk stops rather than skips, by design and reproduced deliberately; the two file orderings that make it visible or invisible are recorded beside it.
- **A missing `branchName` becomes the string `"null"` and passes the charset gate.** `jq -r` prints the four-letter word for a null, `null` matches `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`, and `init-session` writes it into `.aimi/current-branch` and reports it as the branch. The gate is doing its job; the hole is upstream of it, in a read that cannot tell absent from present.

### Branch commit 8 — 2026-08-12

> **The command layer stops re-deriving state `aimi-cli.sh` already owns, over the questions it used to open `tasks.json` itself to answer.** The plan scoped this at 38 file-opening reads; a mechanical extractor built for the purpose found 37 (three of the estimate's lines sit inside a pseudocode fence, not a bash one, and are correctly never counted). Of those 37, eight branch-name reads and two execution-mode reads collapse into the CLI's existing `metadata` call; seven `metadata.splitGroup` reads and two pending-count reads collapse into a new `split-detect --dir` scope; the rest needed two new verbs, because neither `status` nor `metadata` carried the fields these blocks needed and widening either payload was rejected in favor of a narrower answer (see *Added*). **33 of the 37 are retired. Four remain**, each named under *Changed* with the reason it still opens a file — none of the four had a verb it could safely call at that exact point in the flow.
>
> **Three defects surfaced along the way and are fixed here, not carried forward.** A malformed (non-object) `verification` field sent a user into a repair loop with no exit: `normalize-verification` only ever repairs a bare string, but the STOP message it triggered pointed every malformed shape at it, including a number or an array it declines to touch. An array-valued `.project` pretty-printed across several lines under `jq -r` and split one story into multiple bogus project groups inside a read loop; a non-string `verification.url` reached a `serve url` call the same way. And `review.md`'s own visual-verification gate carried no `type == "object"` guard, so it aborted on a string-typed `verification` where the equivalent guarded read in `/aimi:execute` counted zero. All four are closed at the new verbs' one source rather than patched at each call site.
>
> **`python3` widens by one narrow path, and it is the same path 1.124.0 already widened onto `init-session`.** `/aimi:review`'s empty-argument path (Case B: HEAD parked on the default branch) crosses into `python3` for the first time when it adopts the guarded `metadata` call in place of its own `find-tasks` lookup — every other replaced site was already downstream of `/aimi:execute`'s own `init-session`, which has required `python3` since 1.123.0. Confirmed against the current `install.sh` rather than repeated from a prior release: `grep -ci hook install.sh` still returns 0, so an OpenCode session never spawns `python3` on its own, and the requirement surfaces at first use of the affected command path, not at install.
>
> **Two new verbs, both under *Added* — and `status` is unchanged.** Neither `verification` nor `project` was added to `status`'s existing payload; both questions got their own verb instead, because `status`'s `story_row` projection deliberately omits execution detail (see the comment above it in `tasks.py`) and widening it would have undone that scope cut rather than answered a different question.
>
> **Why the number is MINOR, argued against this file's own precedents.** Two new verbs alone already match 1.122.0's reasoning — a new subcommand is what MINOR buys here. This release is a superset of that shape: it adds two verbs, narrows `python3`'s reach onto one more command path (1.123.0's shape), fixes three defects that shipped no output contract of their own to protect, and tightens `project-groups`' validation where the six sites it replaces validated nothing before it (see *Changed*) — a caller relying on an invalid `.project` value silently routing into the root group now gets a refusal instead. **PATCH is ruled out** the same way 1.123.0 ruled it out there: a bug-fix number tells a reader nothing about a new verb they can now call, or a validation rule that can now refuse a value it used to accept without comment. **MAJOR does not apply**: no command's syntax moved and no output field was removed, renamed or repositioned — the tightened validation is a new refusal on an input no schema ever declared valid, not a removed capability, and in a 1.x line that stays MINOR by the same argument 1.124.0 already made about `version`'s own new refusal.

#### Added

- **`verification-report --tasks-file <path>`** — answers, from one read, which stories in the named tasks file carry `verification.strategy == "visual"` (each with its own `project` and `url`), and partitions a malformed (non-object) `verification` field into what `normalize-verification` actually repairs (a bare string, the empty string included) and what it does not (a number, an array, a boolean). `/aimi:execute`'s Step 0.7 and `/aimi:review`'s Design Fidelity trigger both answer from this verb now, replacing eight raw `jq` reads in `execute.md` plus `review.md`'s own separately-guarded visual-story count.
- **`project-groups [--tasks-file <path>]`** — answers the sorted-unique list of project routing groups a tasks file's stories participate in (a story with no `.project` and one with `.project: "."` both collapse into the same `"."` group), plus the count of stories carrying a genuinely non-null project — the two questions six `execute.md` call sites used to compute separately with `jq -r` plus a bash empty-fallback. Validates every non-`"."` group against the same traversal-case-list and character-regex pair `execute.md`'s own split loop and `plan.md`'s staging gate already apply to the same field, collecting every offender before refusing rather than stopping at the first — none of the six replaced sites validated the field before this.

#### Changed

- **Eight `execute.md`/`container-execution.md`/`review.md` reads of `.metadata.branchName` and two reads of `.metadata.execution` now go through the single guarded `$AIMI_CLI metadata` call `open-pr.md`'s own Case B already established for the identical situation.** `review.md`'s Case B also drops its separate `find-tasks` lookup in favor of this call — the one place this route into the command layer starts requiring `python3` on a path that did not require it before (see the preamble).
- **Seven `metadata.splitGroup` reads and two pending-count reads across phase-mode split-detection now go through `$AIMI_CLI split-detect --dir`, called once per block and consumed in-memory for every file the loop already iterates**, rather than once per file. One anchor-selection type-gate (`execute.md:1257`, deciding which candidate file becomes the anchor in the first place) is left untouched on purpose — `split-detect` answers for a scope once the anchor is already known, and cannot itself decide which candidate that is; the full reasoning for this and the three other command-layer sites still reading a file directly is recorded in `plugins/aimi-engineering/CLAUDE.md` § What stays `jq`, and why.
- **Eight visual-verification reads and `review.md`'s own separate visual-story-count gate now answer from `verification-report`.** The rewritten STOP message in `/aimi:execute` Step 0.7 tells a user with a malformed `verification` field the truth about their shape instead of pointing every shape at a fix that only handles one of them (see the preamble); the sentence that used to justify the raw reads by naming `status`'s scope cut (`execute.md`, formerly at line 248) is corrected to name `verification-report` instead of the reads it replaced.
- **Six project-grouping reads now answer from `project-groups`, which validates `.project` where none of the six did before — a deliberate tightening.** An invalid group value that used to be silently grouped is now refused by name, collecting every offender rather than stopping at the first. This also reaches the Unsupported Combination Guard's own count: `project-groups` normalizes `.project` through the same non-string collapse `verification-report` already applies to the same field, so an array-valued `.project` — which used to satisfy the guard's raw `!= null` check — no longer counts as a project there.
- **`plugins/aimi-engineering/CLAUDE.md` § What stays `jq`, and why now covers `commands/` as well as `aimi-cli.sh`, under one widened title and one organising sentence rather than a second section.** The command layer's own census — 212 lines of `jq ` across `commands/**/*.md`, of which 4 still open a file at the mechanical extractor's own count (plus one the extractor cannot see, disclosed by name) — sits under the same as-of discipline as the `aimi-cli.sh` table beside it. Root `CLAUDE.md`'s one-line pointer is updated to match the new title and states nothing further, per that file's own standing rule against restating the principle twice.

#### Fixed

- **A malformed (non-object) `verification` field no longer sends `/aimi:execute`'s user into a repair loop with no exit.** Step 0.7 used to abort on any non-object `verification` and always name `normalize-verification` as the fix — but that verb only ever repairs a bare string (the empty string included) and declines to touch a number, an array or a boolean, so a story carrying either of the latter shapes had no path forward. The STOP message now splits into a repairable paragraph (naming `normalize-verification`) and an unrepairable one (asking for the object form by hand), each shown only when its own count is non-zero.
- **An array-valued `.project` no longer pretty-prints across multiple lines under `jq -r` and splits one story into several bogus project groups inside a read loop.** Normalized to a single value at `verification-report`'s and `project-groups`' shared source.
- **A non-string `verification.url` no longer reaches a `$WORKTREE_MGR serve url` call unnormalized.** Normalized to `""` at the same source.
- **`review.md`'s own visual-verification gate no longer aborts on a string-typed `verification` field.** It carried no `type == "object"` guard, so `jq` failed with "Cannot index string with strategy" where `/aimi:execute` Step 0.7's own guarded copy counted zero visual stories for the same document. Folded into `verification-report`, which type-checks before it reads `.strategy`, so a malformed `verification` now answers zero visual stories in both places, never an abort in either.

#### Known gaps

- **`review.md`'s Design Fidelity trigger gate still opens a tasks file with a raw `jq` outside any verb** (`jq -r '.metadata.prototypePaths // empty' $TASKS_FILE`, condition 1 of its two-condition trigger). It was never counted by any of stories 01–04's captures because it is written as inline prose — a single-backtick code span, not inside a fenced bash block — so the mechanical extractor that found the other 37 sites has never seen it. Its sibling condition, two lines below, was rewritten to call `verification-report` in this same release; condition 1 is left as found because fixing it means reshaping the surrounding prose into an actual fenced block, not swapping one call for another.

### Branch commit 9 — 2026-08-13

> **Two independent fixes land together: an empty-directory answer that used to lie, and a branch discriminator that used to guess wrong after a stacked run.** A script that shells out to `find-tasks` or `find-tasks-all` against a project with no tasks file used to get exit 0 and a bogus path back — usable-looking, and wrong. A person running `/aimi:open-pr` or `/aimi:review` after a container-mode `/aimi:execute` run that was stacked on another feature branch used to have that stacked branch treated as the feature — a PR opened, or a review scoped, against the wrong thing. Both are fixed at the source rather than patched at each caller.
>
> **Why the number is MINOR, argued against this file's own precedent.** 1.121.3 took PATCH for "a refactor with nothing for a reader to do" — no flag moved, no output changed, nothing needed migrating. This release is not that shape: `find-tasks` and `find-tasks-all`'s exit code moves from 0 to 1 on an input a caller can hit today, and a bug-fix number tells that caller nothing about it. 1.123.0, 1.124.0 and 1.125.0 each took MINOR on the same reasoning — an output or exit code that becomes reachable, or moves, where it used to abort or answer wrong is what MINOR buys here, not only a new verb; this release is that same shape without a new verb of its own. PATCH is rejected for the reason above. MAJOR is rejected too: no command's syntax moved and no documented output was taken away — `cmd_find_tasks`'s `No tasks file(s) found in <dir>/` error branch was already written into the source before this release, simply unreachable; making a written branch reachable is not retracting a promised contract.

#### Fixed

- **`find-tasks` and `find-tasks-all` no longer exit 0 with a bogus path when `.aimi/tasks/` has nothing in it.** Both verbs — plus `get_tasks_file`'s own stale-pointer fallback, which most `tasks.json` verbs fall through to whenever session state is unset or points at a file that no longer exists, and `split-detect`'s own `--dir` directory listing — piped a NUL-delimited `find` straight into `xargs -0 ls -t`. `xargs` runs its command once even on empty input, so an empty tasks directory made `ls -t` run with zero arguments and list the current directory instead of nothing — handing the caller the newest file sitting in the project root (a `CLAUDE.md`, say) as though it were a tasks file. That answer was also non-deterministic: it changed as files in the project root were edited. All three call sites now exit 1 with `No tasks file(s) found in <dir>/` — the message `cmd_find_tasks` already carried in its source and could never reach until now. **A caller that treated exit 0 as "a tasks file exists" was already being lied to, and the exit code itself genuinely moves, from 0 to 1, on an input reachable today.** `list-archivable` read this same document family throughout this release and is unaffected — its own dirname filter and its predicate's malformed-JSON swallow already discarded the bogus candidate before this fix, by accident rather than by design.
- **`/aimi:open-pr` and `/aimi:review` no longer mistake a stacked base branch for the feature branch.** Both commands' Case A/Case B branch discriminator fired "trust HEAD as the feature branch" whenever HEAD merely differed from the repository's default branch — the rule they meant was "is HEAD the branch the active tasks file names". After a container-mode `/aimi:execute` run stacked on top of another feature branch (an ordinary way to build one feature on another), HEAD parks on that other feature branch rather than the default, the old rule treated it as the feature, and `open-pr.md` reached `git push` and opened a PR against the stacked base while `review.md` reviewed the wrong scope. Both files now correct HEAD whenever a valid `metadata.branchName` differs from it — one rule covering both the pre-existing default-branch case and the stacked-base case — and both print one stderr line naming the branch resolved to and the HEAD value it replaced. The tracking issue (#107) named only `open-pr.md`; `review.md` carried the identical discriminator and is fixed here alongside it, not as an afterthought.

## [1.119.3] - 2026-08-01

### Fixed

- **`install.sh` wrote OpenCode Bash auto-approval rules under `permissions` (plural), the opencode 0.x schema key; opencode 1.x rejects unknown top-level keys at startup with `Unrecognized key: permissions`, aborting launch before any session starts.** `install_permissions()` and `uninstall_permissions()` now use the singular `permission` key throughout: the heredoc JSON fragment, the `jq` merge (`.permission = ((.permission // {}) * $perms.permission)`), the `python3` fallback (`cfg.get('permission', …)`, `perms['permission']`, `cfg['permission']`), and the uninstall path (`grep '"permission"'`, `del(.permission)`, `cfg.pop('permission', None)`). Verified against the canonical schema at <https://opencode.ai/docs/permissions> and against opencode 1.18.10, where the singular key loads cleanly and the plural key is the rejection the user reproduced. Comments and human-readable log strings (`ok "Removed permissions from …"`) are unchanged — they are prose, not schema keys.
- **Known limitation, accepted as residual risk:** a reinstall over an `opencode.json` that already carries the stale plural `permissions` key from a prior buggy install does **not** self-heal. The installer's idempotency guard greps for the `"git *"` rule, finds it under the old plural key, and returns early without ever writing the singular key or removing the plural one — so the startup crash persists across reinstalls. Affected users must delete the `permissions` (plural) block from `~/.config/opencode/opencode.json` by hand once; a migration step in `install_permissions()` was deliberately deferred. Fresh installs are correct.

## [1.119.2] - 2026-07-30

### Fixed

- **1.119.1's command-position anchoring regressed real detections: a `git commit` or `git worktree add` preceded on the same statement by an environment assignment, a wrapper command, or a body-opening keyword stopped being guarded at all.** `[^\S\n]*` after the anchor consumes whitespace only, so any token between the separator and `git` broke the match — and the failure was silent, in the fail-open direction: the commit on the protected branch simply happened, with no message. Verified missed by 1.119.1 and detected again now: `GIT_AUTHOR_DATE=2020-01-01 git commit` (the canonical way to backdate a commit, and an everyday git idiom), `sudo git commit`, `env FOO=1 git commit`, `time`/`nohup`, `for f in a b; do git commit; done`, `if ok; then git commit; fi`, `else` bodies, `{ git commit; }` brace groups, and `! git commit`. `_CMD_START` is now `_CMD_ANCHOR` (unchanged) plus `_CMD_PREFIX`, a bounded run of those tokens; the four guard regexes concatenate `_CMD_START`, so none of their own definitions changed. Issue #82 stays closed — no prefix token can match `grep`, `echo`, `cat`, `find`, `jq` or `awk`, and every token requires trailing whitespace, which is what keeps `find … {} \;`, `jq '{a: 1}'`, `awk '{print $1}'`, brace expansion `{src,test}`, `${VAR}` and `!=` out of the guard. Confirmed a strict superset over all 802 string literals in the hook test suite: 28 detections gained, zero lost.
- **This entry supersedes the environment-assignment and wrapper clause of 1.119.1's "Known limitation" bullet below** — that class is now detected, and the sentence claiming `\s*` consumes whitespace only is no longer the shipped behavior. The rest of that bullet (`bash -c`, subshell, command substitution, single `&`, non-`-C` option forms) still stands.
- **Known limitation, accepted as residual risk:** a wrapper outside the four covered (`timeout`, `xargs`, `command`, `exec`, `nice`, `stdbuf`) or one carrying its own option token (`sudo -u alice git commit`, `env -i git commit`, `time -p git commit`) is not detected — covering those needs another nested quantifier, and the backtracking surface is not worth it. Also undetected: an assignment whose value holds a `$(...)` substitution containing whitespace, `VAR="a"b`, prefix runs deeper than six tokens, and `case` arms or bodies opened by `(`. Note that `FOO=a&b git commit` not matching is correct rather than a gap — bash parses it as `FOO=a &` followed by `b git commit`, so no commit runs.

### Changed

- `_GIT_WORKTREE_ADD_RE` gained the leading `\b` its three sibling regexes already carried. Provably a no-op — the anchor already guarantees the word boundary — but the asymmetry had been flagged by four separate reviewers as an inconsistency inviting a reader to hunt for a reason that does not exist.

## [1.119.1] - 2026-07-30

### Fixed

- **`pre-bash-dispatcher.py`'s commit guard and worktree-add guard matched `git commit`/`git worktree add` as a bare substring anywhere in a Bash command string, so a commit message or comment merely *mentioning* either phrase — with no invocation present — triggered the guard (issue #82).** Both `_GIT_COMMIT_RE` and `_GIT_WORKTREE_ADD_RE` are now anchored to command-start position via a shared `_CMD_START` lookbehind (start of string, or immediately after `;`, `&&`, `||`, `|`, or a literal newline — regexes are never compiled with `re.MULTILINE`), so only a genuine invocation matches, not an incidental mention. `git -C <path> commit`/`git -C <path> worktree add` gained their own anchored `_GIT_C_COMMIT_RE`/`_GIT_C_WORKTREE_ADD_RE` variants (quoted-or-bare `-C` path token), closing two pre-existing gaps: `main()`'s routing gate previously never dispatched a `git -C <path> commit` invocation to the commit guard at all, and no `-C` variant of the worktree-add guard existed. A heredoc body is stripped from the detection copy before either family of regexes runs (`_strip_heredocs`, fails closed to the original unstripped string on any internal error), so a commit message authored via `<<EOF ... EOF` no longer feeds guard detection.
- **`effective_cwd` could not resolve the quoted `git -C "<path>"` form the guards had just learned to detect, so every quoted `-C` invocation failed open.** The detection regexes accepted a quoted path while `hook_utils.effective_cwd` still captured it with a bare `\S+`, keeping the opening quote (and stopping at the first space inside it). The resulting path resolved to nothing, `git rev-parse` failed, the branch read as empty, and — because an empty branch is not in the protected set — the commit was allowed. This affected *any* quoted `-C` path, not only paths containing spaces. Both `effective_cwd` extractors (`git -C <path>` and the leading `cd <path> &&`) now share one quoted-or-bare path token with the detection regexes, so a shape that is detected is also one whose target directory can be resolved.
- **The `_CMD_START` anchor scanned quadratically over runs of blank lines, which could exhaust the hook timeout and disable the guard entirely.** A newline is both an anchor and a `\s` character, so the trailing `\s*` let every position inside a whitespace run start a match and then backtrack across the remainder — roughly 1.4 s of CPU on 4,000 blank lines and growing with the square, against a 60 s hook timeout after which a `PreToolUse` hook can no longer emit a denial. The trailing run is now `[^\S\n]*` ("whitespace except newline"), which is verdict-identical to `\s*` because each newline already has its own lookbehind branch. Note for future readers: `[ \t]*` is *not* an equivalent narrowing — it silently stops detecting a command prefixed by a carriage return, vertical tab, or form feed, and a regression test pins this.
- **Anchoring the regexes removed their leading literal, which CPython's `re` uses to skip ahead, so the six-branch alternation was evaluated at every offset of every Bash command the hook saw.** `main()` now short-circuits on `"git" not in command` before any regex runs — safe because every detection regex requires that literal and `_strip_heredocs` only ever removes whole lines.
- **Known limitation, accepted as residual risk:** command-position anchoring deliberately does not detect `git commit`/`git worktree add` invocations wrapped in `bash -c '...'`, inside a subshell `(...)`, produced via command substitution, chained with a single `&` (background) rather than `&&`, embedded in an `if`/`then` or loop body, or preceded on the same statement by an environment-assignment or wrapper prefix (`GIT_AUTHOR_DATE=… git commit`, `env`, `sudo`, `time`, `nohup`). Option forms other than `-C` — `git -c key=value commit`, `git --git-dir=… commit` — are likewise undetected. These are all forms the prior unanchored regex caught only by accident, alongside every false positive it produced. Closing the quote-wrapped cases would require treating a quote character as a command-start anchor, which reopens issue #82's false-positive class; the trade-off is intentional and documented here rather than silently narrowed.

## [1.119.0] - 2026-07-29

### Added

- **`aimi-cli.sh resolve-base-branch <name> --default-branch <branch> [--base <branch>] [--project <path>]` — the single source of base-branch selection for both the inline (`setup-branch`) and container-creation paths (issue #78).** Prints `{base, reason, currentBranch, defaultBranch, promptNeeded}` without performing any git mutation, `reason` one of `explicit-base`, `target-exists`, `detached-head`, `default-branch`, `stacked-on-current`. `base` prefers the `origin/<name>` remote-tracking ref over the bare local name when the fully-qualified ref exists on origin, falling back to the local name when offline or local-only — with one deliberate exception: `stacked-on-current` always keeps the bare local ref, because stacking exists to inherit the local tip and preferring origin there would drop every commit made since the last push. Both the origin probe and the target-exists probe match the full ref (`refs/heads/<name>`) rather than a pattern, so a repository carrying `team/main` but no `main` no longer yields an `origin/main` that does not resolve. The merged check matches whole lines literally, so a branch named `feat.x` is no longer misread as the merged `feat/x`. `promptNeeded` is true only for `stacked-on-current`. `cmd_setup_branch` now delegates its own base-selection logic to this same helper rather than carrying a second copy of it, so the two paths land on the same commit — asserted by a regression test that compares `git rev-parse` output, not just the two paths' labels.
- **`--base <branch>` on `/aimi:execute`**, parsed out of `$ARGUMENTS` in Step 0 the same way `--phase` already is, bringing it to parity with the flag `/aimi:next` already had. It threads through to `resolve-base-branch` as an explicit override, giving an escape hatch to name the base outright instead of relying on the stacking prompt or reshaping the working tree first.

### Fixed

- **Issue #78: container-mode execution no longer silently branches from the default branch when the checked-out branch carries unmerged work.** An unset base used to mean "stack on the current branch" on the inline path but "use the default branch" in container mode, so the same story could branch from two different commits depending only on which path executed. Flat Container Mode, Per-Project Branch Setup, the paired-split loop, the phase container, and `/aimi:next` all now resolve through `resolve-base-branch` and agree with the inline path — five call sites in total, including the phase container, which the original issue did not name. Separately, in multi-repo layouts the base is now selected per child repository instead of being skipped wholesale: Step 1.6's Early-Skip Guard, which previously left the base unset for every repo in the layout the moment more than one repo was detected, is removed, and each project group resolves and prompts (or logs, under the agent path) independently, naming its own repo.
- **Containers were also being cut from a stale local default branch even immediately after a successful fetch.** `worktree-manager.sh` resolves its `--from` argument against a local ref, while container creation was comparing against the bare local default branch name — so a fetch that updated `origin/<default>` had no effect on what a freshly created container actually branched from. `resolve-base-branch`'s origin-over-local preference (above) closes this for the container path the same way it does for the inline one, for every reason except `stacked-on-current`, where the local tip is the correct base by definition.
- **`/aimi:execute --base` and `/aimi:next --base` are parsed and validated in one shell, and the parsed value is echoed.** Both commands previously assigned the flag in one ` ```bash ` fence and validated it in a second one. Each fence is its own shell, so the validation tested an unset variable, matched nothing, and passed vacuously — and the value never reached the call sites that consume it, leaving the flag inert while appearing to work. Parsing, validation and a hard `exit 1` on a malformed value now live in a single block that echoes the result, and every later block that reads `$BASE_BRANCH` re-assigns it from that echoed value, the same way Step 0.9 Pass 2 re-assigns `SPLIT_PLAN`.

### Changed

- **Container creation and reuse now report the resolved base branch and the reason it was chosen, at every point a container is created or reused** — Flat Container Mode, Per-Project Branch Setup, the Phase-Mode Paired Split loop (one line per split record naming its root, branch, and resolved base/reason), and `/aimi:next`'s own create-or-reuse call, whose successful path previously reported nothing: only a failure surfaced `create`'s captured output, so the base never reached the reader on a successful create or reuse.

## [1.118.0] - 2026-07-28

### Added

- **Phase mode now runs across a multi-repo layout: one phase container and one phase branch per participating repository, never a single pair for the whole layout (resolves GitHub issue #73, `aimi-so/aimi-engineering-plugin`).** `/aimi:execute`'s Step 1.7 **Create Phase Containers Per Project Group** derives one project group per participating repository — resolved via `git -C rev-parse --show-toplevel` and `detect-default-branch --project`, collision-checked on `(toplevel, branch)`, the same mechanism the flat flow's Step 0.9 Pass 1 already used — and creates or reuses `PHASE_CONTAINER_PATHS[group_key] = <repo toplevel>/.worktrees/<phase branch>` for each one, documented in `commands/references/container-execution.md`'s new **Phase Container Paths Per Project Group** section. Split detection now runs *before* container creation, so a phase's own full-stack split routes each active member to its own repository. A split member's worktree now roots at its own repository (`SPLIT_ROOT`/`SPLIT_TOPLEVEL`, carried as one JSON object per line in `SPLIT_PLAN` rather than tab-delimited, since a tasks-file path may contain spaces) instead of nesting under a single container that never resolved for a non-root repo. Merge and cleanup run once per repository — grouped from `SPLIT_PLAN`'s own distinct toplevels, sequentially, each against that repository's own phase-branch container — and a conflict names the specific repository while reporting every sibling repository's own status. Step 4's wave loop, previously pinned to a single scalar for every group in phase mode, now reads the per-group `PHASE_CONTAINER_PATHS[group_key]` map (falling back to the scalar only for a Phase-Mode Paired Split sub-orchestrator, which never populates the map). Creates verification calls `verify-creates` once per participating repository and unions the verdicts — an identity verifies for the phase when *any* repository verifies it, and is missing only when *every* repository reports it missing, so an artifact landing in whichever sibling repository actually owns it no longer blocks phase close; a tooling error in any one repository's call still dominates and routes the whole phase to the existing tooling-failure path. Mark Phase Completed stops each repository's own dev server (previously only `$AIMI_ROOT`'s, silently orphaning every other repository's server) and lists one repository/branch line per participating group. Offering a pull request now pushes and opens one PR per participating repository, resolving each one's own default branch fresh rather than assuming a single `$DEFAULT_BRANCH`. With exactly one participating repository — every existing single-repo phase — every one of these loops runs exactly once against exactly today's path, byte-identical to before.
- **Multi-repo phase and flat splits both require the PROJECT axis: `metadata.splitGroup.project` is the single source of routing truth.** Every story in a multi-repo plan needs its own `project` field; `story-merge`'s PROJECT-axis writer (1.116.0) already stamps `splitGroup.project` on each split file, and `/aimi:execute` now reads it in phase mode the same way the flat flow already did. Documented in a new "Multiple repositories" section in `README.md`, root `CLAUDE.md`, and `docs/roadmaps.md`, and in `plugins/aimi-engineering/CLAUDE.md`'s `splitGroup` schema notes. `docs/roadmaps.md`'s "What this does not do" section previously stated "Roadmap mode is not supported in a multi-repo layout" — the roadmap lifecycle operations (`roadmap-claim`, `roadmap-set-status`, `roadmap-write-handoff`, `roadmap-reconcile`) never made a git call and never had this limitation; that sentence is removed as stale documentation, not as a behavior change.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** Per-repository phase containers are new capability — squarely "new commands, skills, or features" under `plugins/aimi-engineering/CLAUDE.md`'s Versioning Requirements. No command's flags or verb names moved: `/aimi:execute`'s own invocation, and `detect-default-branch`, `detect-parent-branch`, and `split-detect`'s arguments and JSON return shapes, are all unchanged. Two changes narrow existing behavior rather than adding to it, and neither rises to "breaking changes to command syntax or output format." First, the phase-mode multi-repo guard, which previously refused *every* phase claimed under a non-git `AIMI_ROOT` unconditionally, now refuses only two genuinely unroutable residue cases — this is a loosening (more phases now run) with corrected prose on the narrow refusal path that remains, not a syntax change to any command a user types, since `/aimi:execute` takes no flag that controls this. Second, `split-detect`'s new `mode: "none"` + `degradedReason` outcome for an unmarked legacy pair under a non-git `AIMI_ROOT` is an additional value within its existing return shape (`{mode, anchor, members, activeCount, total, degradedReason}`, unchanged from 1.116.0), not a new shape — and the case it now refuses previously resolved silently to routing key `"."` and then failed downstream with a bare `fatal: not a git repository` (issue #73), so no caller that worked before stops working; a caller that previously failed opaquely now fails with a diagnosis instead. This is the same shape of change 1.116.0 and 1.117.0 both shipped as MINOR: an internal CLI verb invoked by `/aimi:execute`, not typed directly by a user, whose verdict was wrong or unreachable.

### Fixed

- **`_resolve_default_branch`'s offline fallback and its `Error: Could not detect default branch` path were both unreachable, and had been since the verb was added.** Under `set -euo pipefail`, `branch=$(git remote show origin 2>/dev/null | sed -n '...')` — with no network, or no configured remote — returned a non-zero exit from the pipeline itself, which aborted the whole function (and the script) with a silent **exit 128** before the `[ -z "$branch" ]` offline-`symbolic-ref` fallback, or the final error message, could ever run. `detect-default-branch` and every caller of `_resolve_default_branch` (including the new per-repository resolution below) could fail with no diagnostic the moment a repository had no reachable remote. Both assignments now suffix `|| branch=""` so a failing pipeline clears the variable instead of exiting the shell, making both the offline path and the error path reachable for the first time.
- **The default-branch cache was a single shared file under `AIMI_ROOT/.aimi/default-branch`, so `detect-default-branch --project <repo>` returned whichever repository resolved first, silently, for every sibling repository asked about afterward.** In a multi-repo layout this meant the second child repository's own default branch was never actually read — it inherited the first repository's cached value — and `worktree-manager create --from` then failed with `fatal: Not a valid object name` when that inherited branch name did not exist in the second repository. The cache is now keyed per repository toplevel (`default-branch-<hash-of-toplevel>`, SHA-256 when available, a portable slugified fallback otherwise), so each repository's resolution is independent. `clear-state` now removes every `default-branch-*` file instead of the one old shared name.
- **`split-detect` now refuses an unroutable legacy `-frontend-tasks.json`/`-backend-tasks.json` pair instead of silently reporting routing key `"."`.** When neither file in the pair carries a `metadata.splitGroup` marker and `AIMI_ROOT` is not a git repository, the pair previously resolved to the root group `"."` — a routing key with no repository underneath it to execute in once a caller acted on it. `split-detect` now detects this exact combination and returns `mode: "none"` with a `degradedReason` naming the layout and instructing a re-plan with `--split full-stack` so every story carries its own `project`. This is a query, not a gate: it still exits 0.
- **The phase-mode multi-repo guard's own suggested workaround could not work, and is corrected.** The guard's refusal message told users to "run `/aimi:execute` without `--phase`" — but `--phase` never controlled phase mode (phase mode is detected from a `roadmap.json` sibling, not from a flag), and even if it had, the flat flow's `split-detect` scope is depth-1 (`.aimi/tasks/*-tasks.json`), so it cannot see files inside a phase directory at all. That workaround text is removed. The guard itself is narrowed from a blanket refusal to the two cases that remain genuinely unroutable (see Added, above), and the refusal message for each names the specific condition split-detect or the phase's own tasks file surfaced, plus the one workaround that actually works — running from inside a single repository with its own `.aimi/` directory — captioned honestly with the cost it carries (a separate roadmap per repository, outside the shared claim/lifecycle).

## [1.117.0] - 2026-07-28

### Added

- **`aimi-cli.sh verify-creates` — phase-closure creates verification moves out of executable command prose and into the CLI, where the test suite can reach it.** `/aimi:execute`'s Creates Verification section carried five hand-written steps built on `[ -f "$PHASE_CONTAINER_PATH/$identity" ]` and a bare `git grep -l -F` over the whole tracked tree, first hit wins — two lines no Bash suite could execute, answering "does this name appear anywhere?" when the question is "was this built?". `$AIMI_CLI verify-creates --feature <slug> --phase <id> [--dir <container-path>]` now answers it once and prints one JSON object per `creates[]` entry: `{identity, status, method, evidence, gitStatus}`, where `status` is `verified` | `missing` | `error` and `method` is `"path"` | `"text"` | `null`. Four deterministic steps run per identity, with no dispatch on identity kind: **(1)** a tracked-path check via `git ls-files`, which matches a **directory** as well as a file; **(2)** extraction of a leading `GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD`/`OPTIONS` token, so `POST /api/notifications` is searched as `/api/notifications` — route code contains the path and never the method-plus-path literal, so without this step excluding documentation would turn every endpoint-kind phase into `verification_failed`; **(3)** a `git grep -n -I -F` over tracked source with documentation, tests and `.aimi/` excluded, bypassed entirely when the identity is itself documentation (`docs/api/notifications.md`), because there the docs page **is** the artifact; **(4)** a filter dropping hits that are only a `TODO`/`FIXME`/`XXX`/`HACK` marker inside a comment. It is a **query, not a gate**: producing a verdict array exits 0, including an array in which every entry is `missing`, so a caller loops over the result instead of branching on the exit status. Non-zero is reserved for real errors — unknown flag, absent or non-numeric `--phase`, absent or malformed `roadmap.json`, a `--dir` that is not a directory. **git exiting above 1 becomes `status: "error"` carrying the code, never `"missing"`** — a tool failure is not an absent artifact — and `/aimi:execute` takes a separate branch for it: the phase is left `in_progress` with its claim released rather than transitioned to `verification_failed`, because reporting that a phase failed to deliver when git is what broke blocks the next phase on evidence nobody gathered. A `missing` verdict names the file and line that was found and rejected, and why. Measured against nine fixture repositories: the procedure this replaces was wrong in five of them, the new one in none. Covered by 88 assertions, one isolated git repository per row of the matrix, each pinning status **and** method so a right verdict reached through the wrong step still fails.
- **The exclusion list uses the long `:(exclude)` pathspec form for every pattern, and that is load-bearing rather than stylistic.** The short `:!` form is not interchangeable: git reads the character after the colon as pathspec magic, so `':!__tests__/*'` aborts the whole invocation with `fatal: Unimplemented pathspec magic '_'` and **exit 128**. On the code path this replaces that would have returned empty and marked **every artifact of every phase** missing — a silent, total failure with no error surfaced anywhere. It is recorded here because it is invisible in a diff: a dedicated assertion pins git's exit status at or below 1 rather than merely checking the verdict, and every pattern is written long-form so no future edit reintroduces the short form by copying a neighbour.

### Changed

- **Behavior change users will notice: a phase whose only evidence is a mention now FAILS Creates Verification where it previously passed.** Three classes of "evidence" used to close a phase and no longer do — the declared name appearing **only in documentation**, **only in a test file**, or **only in a pending `TODO`/`FIXME`/`XXX`/`HACK` comment**. Each of those is a description of the work, or a note that the work is still owed; none of them is the work. A fourth and worse case closes with them: a project that had **committed its own `.aimi/` directory** verified every artifact of every phase unconditionally, because the identity was found inside the tracked `roadmap.json` that declared it — the phase verified itself, and no `creates[]` entry in such a project has ever been checked against real code. This is a deliberate loss of passes, not a tightening at the margins. Its reach is bounded, though, and the bound is worth stating precisely: creates verification runs **only at the moment a phase closes**, and a phase already at status `completed` is not claimable — `roadmap-claim` refuses it with `phase status is completed` — so it is never re-verified. **No phase that already closed is re-examined, and no roadmap turns red on upgrade.** What changes is the bar for every phase that has not closed yet. See Migration.
- **`roadmap-init` now refuses a phase whose `creates[]` or `needs[]` carries an identity that can never name a real artifact.** Exactly three shapes are rejected, judged over the identity (the text before the first `(`, trimmed) and nothing else: empty once the description is stripped; a `..` **path segment** — `(^|/)\.\.($|/)`, so `services/foo..bar` is untouched; and a leading `/` anchored at position 0, because `POST /api/notifications` contains a slash but does not begin with one and an unanchored rule would make every endpoint-kind phase unwritable. Identity *strength* is explicitly not judged: at declaration time research has not run, so a bare table name (`notifications`) or a bare directory (`db/migrations`) still passes — guessing a path there fails at phase close for a reason nobody can debug. The check runs **inside the `roadmap.json` lock, after the filter that drops phase ids already on disk**, so it judges only the phases the call is actually writing; placed beside the existing directory and branch validators it would have fired on legacy phases during `--sync`, and because both `/aimi:plan` call sites downgrade a `roadmap-init` failure to a warning, the new phase would then have been dropped silently instead of reported. `creates[]` and `needs[]` go through the same predicate in the same pass, because `validate-contracts` matches a need against a provider's creates by **exact byte equality** — a rule applied to one list alone lets a roadmap hold two shapes at once and deadlocks planning on a permanently unmet need.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** This release makes previously passing phases start failing, which under this repo's own "MAJOR: breaking changes to command syntax or output format" rule could be read as MAJOR. MINOR is chosen on the precedent set one release earlier: 1.116.0 shipped the analogous `split-detect` verb together with a behavior change of the same shape (a partially tagged plan that used to split now refuses) and shipped as MINOR. No command syntax and no file format moved here — `verify-creates` is an internal CLI verb invoked by `/aimi:execute`, and what changed is a verdict that was wrong.

### Fixed

- **An identity naming a directory — `db/migrations` — previously failed verification even when the directory existed, blocking the next phase for no reason.** `[ -f ]` is false on a directory, and the text search found nothing, so the one identity form previously recommended as "strong" was the one form that could never verify by path; the test that recommended it only ever measured the repository where the directory was absent. The tracked-path check now matches a directory as well as a file (`git ls-files -- "<identity>" "<identity>/*"`). This is the correction in the opposite direction from the behavior change above: it unblocks phases that should never have been blocked.
- **The `creates`/`needs`/`areas` truncation cap was documented as 2000 characters when the CLI applies 500 — and two of the three documents asserted that the wrong number matched the CLI.** `plan.md`, `brainstorm.md` and `skills/task-planner/references/pipeline-phases.md` each grouped `successCriteria`/`creates`/`needs`/`areas` into a single clause under one 2000-character cap. `_ROADMAP_SANITIZE_JQ` applies 2000 to `successCriteria` alone and 500 to the other three. Documenting 2000 clipped **looser** than the CLI, so the tail of a long entry was lost at the CLI boundary rather than at authoring time — precisely what `brainstorm.md`'s own "must never clip tighter than the CLI does" clause existed to prevent; that clause is now true. The grouped sentence could not be corrected without splitting it, so all four fields are stated separately in all three files. No cap value moved and nothing under `scripts/` was touched: the documents were corrected to match the CLI.
- **Both documents that told an author how `creates[]` would be checked described the superseded procedure**, and were wrong in each direction — they omitted the tracked-path check and every exclusion, and promised a text search that no longer accepts documentation. `docs/roadmaps.md`'s "Closing a phase" section now describes what actually runs, in the register of the surrounding user-facing prose: the artifact is looked for among the files git tracks on the phase branch, first as a path (file or folder), then as a name in tracked source; an endpoint drops its leading method; documentation, tests and to-do comments do not count as delivery, except when the artifact *is* documentation; and only committed work is visible. `commands/references/scope-contexts.md` gains a "What verification looks for" subsection at reference depth. The four-kind identity table is unchanged byte for byte and neither page states a naming rule — the format was never the defect, the search was, and `notifications` remains a valid Table identity that `roadmap-init` accepts.

### Known Limitations

- **`git ls-files` and `git grep` see tracked files only, so an artifact that exists in the worktree but is committed nowhere reads as missing.** This is a real change for File-kind identities: the `[ -f ]` check being replaced saw the worktree and verified uncommitted files, while the text search beside it never did — the two halves of the old procedure disagreed about what counted, and they now agree on the stricter answer. The limit is surfaced rather than absorbed: every `missing` verdict's `evidence` states it, and `/aimi:execute`'s failure report tells the user to commit on the phase branch and re-run. Creates verification re-runs from scratch on the next pass, so committing is the entire fix.
- **`roadmap-init`'s identity guard judges newly written phases only, so a roadmap already holding a malformed identity keeps it.** `--sync` against an existing `roadmap.json` deliberately does not re-validate phases already on disk, for the call-site reason given under Changed. An existing bad identity therefore surfaces at phase close — as a `verification_failed` naming what was searched — rather than at write time.

### Migration

- **Nothing that already closed changes. The phase to watch is the one you started before upgrading and close after.** Creates verification runs only as a phase closes, and `roadmap-claim` refuses a phase whose status is already `completed`, so an existing roadmap's finished phases are frozen exactly as they are — upgrading re-examines nothing and flips nothing. The phase that will surprise you is the one still `pending`, `planned`, or `in_progress` on upgrade day: it would have closed yesterday on a documentation mention, a test-file mention, or a `TODO` comment, and it will not close on that evidence today. Two remedies, and the failure report names which one applies: **land the artifact for real** — write the code and commit it on the phase branch, since only tracked files are visible — or **correct the phase's `creates[]` identity**, if what it declares is not what was actually built. Then re-run `/aimi:execute`: creates verification re-runs from scratch on every pass, so nothing needs resetting by hand. Each missing line now carries the file and line that was found and rejected, so "found and rejected at `docs/plano.md:1`" reads differently from no match at all.
- **A project that committed its own `.aimi/` directory should expect the largest change.** Every phase in such a repository previously verified unconditionally, because the identity was found in the tracked `roadmap.json` that declared it. `.aimi/*` is now excluded from the search. This does not reopen anything: phases such a project already closed stay closed, unverified and unrevisited. It means the next phase it closes gets the first honest creates verification that project has ever had — and a phase that was going to sail through on its own declaration will now be judged on the code.
- **Nothing needs re-planning and no existing `roadmap.json` needs rewriting.** The identity guard applies to newly written phases only; `--sync` against a roadmap holding pre-existing entries accepts them and appends as before, leaving prior phases byte-for-byte unchanged.

## [1.116.0] - 2026-07-27

### Added

- **`aimi-cli.sh split-detect` — split-group detection moves out of executable command prose and into the CLI, where the test suite can reach it.** Anchor selection, sibling resolution, marker validation, active filtering, and the legacy-pair fallback are pure, deterministic, file-only logic, but they lived twice inside `execute.md` (flat Step 0.9 and phase mode), the two copies had already diverged, and neither Bash suite could exercise either one. `$AIMI_CLI split-detect [--dir <phase-dir>]` now answers the question once and returns a single JSON object — `{mode, anchor, members[], activeCount, total, degradedReason}`, where `mode` is `project-split` / `paired-split` / `single` / `none`. It is a query, not a gate: every outcome including `single` and `none` exits 0, and non-zero is reserved for real errors. Three behavioral corrections came with the move. **Its flat scope is depth 1** — `*-tasks.json` whose parent directory is `.aimi/tasks` itself — where the prose it replaces reused a depth-1-to-3 glob that also matched phase directories, which is exactly how a phase's split files were captured by the flat flow and run as a flat split, leaving the phase unclaimed and nothing merged into the phase branch. **"Newest wins" replaces "first marker-carrying file"**: the anchor is the newest candidate by mtime, so a stale marked split from a past feature can no longer preempt today's plan, and a group whose members are all completed is dropped whole and the search repeats rather than routing today's real work to a single-file fallback. And there is now **one** definition of pending — `(.status // "pending") != "completed"` — where `execute.md` carried two that disagreed, so an `in_progress` story was counted by the phase-completion check and not by the active filter, letting a phase close with work in flight. Covered by TC36–TC46.
- **A third test suite: `plugins/aimi-engineering/scripts/test-command-blocks.sh`.** Command files are executed, not read — an agent runs their fenced `bash` blocks literally, each in its own isolated shell — so an edit to "documentation" under `commands/` is a code change, and neither existing suite could see it. Three stories on this branch changed only command prose, and all three shipped runtime bugs that reviewers had to find by hand. The suite extracts every fenced bash block under `commands/**` and applies four checks: the block parses (`bash -n`); it uses no bash-only construct, since blocks may run under zsh or macOS bash 3.2; it reads no variable whose only assignment is inside a loop it has already left; and it introduces no variable that nothing in the file assigns. Blocks are addressed by their enclosing heading rather than by any marker in the markdown, because `install.sh` translates command bodies for OpenCode by pure string substitution and would ship an embedded annotation to users verbatim. Known findings are grandfathered in `scripts/command-blocks-baseline.txt`, and the suite fails when a baselined entry stops firing, so that file can only shrink. **Its honest limit: no static check can see a variable that a prose sentence reads.** That class of defect is closed only by moving the logic into `aimi-cli.sh` — which is what `split-detect` above does.

### Changed

- **`story-merge --split full-stack` now picks its split axis from the plan's own layout instead of always splitting frontend/backend (resolves issue #72, `aimi-so/aimi-engineering-plugin`).** Before any writer runs — and before `--foundation`, cycle detection, and the Phase 3.1/4.1/4.2 sweeps, so a refusal costs nothing and warns about nothing — the merged story array is resolved to an axis by counting distinct `project` values. **Two or more distinct values → PROJECT axis:** one output file per repo (`<base>-<project-slug>-tasks.json`), ordered lexicographically by normalized project path, each carrying its own derived `branchName` — and no frontend/backend decision is made anywhere on that path. Ids are reassigned `US-001..US-M` in contiguous per-group blocks so they stay unique across the whole N-file set; two project paths that slugify to the same basename hard-fail the merge before any file is written. **Fewer than two distinct values → SIDE axis:** the two-file `*-frontend-tasks.json` / `*-backend-tasks.json` writer, unchanged. Single-repo plans and monorepos — no story sets `project`, or every story shares one value — keep the previous behavior byte-identical. The axis exists because separate repositories are a layout fact, not a question the frontend/backend heuristic is capable of answering.
- **Behavior change — a partially tagged plan now refuses instead of splitting.** Under `--split full-stack`, if any story carries a `project` and any other story's `project` is absent or blank, `story-merge` refuses the whole merge: it names every offending story, writes zero files, and preserves the staging directory. A story that belongs to the root repository must now say so **explicitly with `"."`** — an absent value is not the root, it is unrouteable, and the implicit "project-less stories fall into the `.` root group" rule that made it look routeable is deleted. Previously such a plan produced a frontend/backend split, which is how one tagged repo plus untagged stories could yield **one file and one branch spanning two repositories**. The fix for an affected plan is one line per story — tag it `"."` — and the refusal message says so.
- **Malformed `project` values are refused in every `--split` mode, legacy included.** Leading `./`, any `..` component, doubled slashes, surrounding whitespace, and any character outside the grammar `story-merge` publishes in its own refusal message all abort the merge before a file is written. The value is a repository path a downstream command will `cd` into, so `"../sibling-repo"` must not reach a tasks file by any route. Validation inspects the **raw** string rather than a trimmed one: `" apps/web "` is invalid rather than being quietly normalized into a value whose raw form is what the downstream command would actually use, and `"./apps/web"` is rejected rather than silently becoming a second spelling of an existing group.
- **Every PROJECT-axis split file carries a self-describing `metadata.splitGroup` marker** = `{project, index, total, siblings[]}` — its own project routing key, its 1-based position, the total file count, and the paths of its N−1 siblings. This is what `/aimi:plan` Phase 4 and `split-detect` key on, replacing filename-pattern guessing. Detection order is load-bearing: the marker pass runs first and wins, and the legacy suffix rule runs only when no candidate carries a marker — otherwise a repo whose path slugifies to the basename `frontend` or `backend` would be misread as the legacy pair. A marker that fails validation degrades and is terminal; it does not fall through to the legacy pair, which beside a project-split marker is stale work. Siblings resolve by basename against the anchor's own directory, which is what makes a traversal-shaped sibling entry inert. SIDE-axis and legacy files have no `splitGroup` key, and none is invented for them.
- **`story-merge`'s return contract gains a third shape, and `/aimi:plan` now consumes it instead of re-deriving filenames.** On the PROJECT axis story-merge prints an N-element array of `{path, project, branchName, storyCount}`; the SIDE-axis `{frontend, backend, frontend_stories, backend_stories}` object and the legacy `{merged, stories}` object are unchanged. Phase 3e captures stdout as `MERGE_RETURN`, and Phase 4 / Phase 4.5 read their file list from it rather than string-concatenating `$TASKS_PATH` with hard-coded suffixes — the surviving projects, their slugs, and their count are computed inside story-merge and are unknowable to the caller any other way. Phase 4.5 collapsed to a single `VALIDATE_FILES` loop that covers N=1 through N; the two steps it replaced operated on a hardcoded placeholder path story-merge never writes on a split, so they exited non-zero and the surrounding prose said "stop here", making the correct loop below them unreachable. Phase 4 additionally resolves each PROJECT-axis branch's base branch per repo via `detect-default-branch --project`, and must merge its patch **into** the existing `metadata` object so `splitGroup` survives verbatim.
- **Derived names are bounded, and refused rather than truncated when they exceed a bound.** A 301-character `project` used to kill `mktemp` mid-loop with no diagnostic, and ~200 characters yielded a 212-character `branchName` handed to git. Four limits are now checked up front and the refusal names which one failed: slug ≤ 64, output basename ≤ 248 (`NAME_MAX` minus mktemp's 7-byte suffix), path ≤ 4000, `branchName` ≤ 100. Truncating instead would manufacture a basename collision between two distinct long project values, which the collision guard would then misdiagnose. Separately, `--phase-aware` is refused when the `--output` basename does not end in `-tasks` with at least one character before it: both writers strip one trailing `-tasks`, which would otherwise collapse to the empty string and produce output whose basename starts with `-`.
- **`cross-file-dep-dropped` smell entries key on `project` on the new axis and keep `side` on the old one** — the two keys are mutually exclusive per entry, and consumers read whichever is present — plus a new per-edge `foundationEdge` flag on the PROJECT axis. The flag exists because `--foundation` in a multi-repo split drops an edge for every story in every non-foundation repo at once: the shared foundation story lives in exactly one group by construction, so its injected edges cannot survive into the others. Those drops get their own stderr note, separate from the ordinary drop-count banner, marking them as expected fallout of `--foundation` plus a multi-repo split rather than hand-authored dependencies that went missing.
- **`/aimi:execute` runs N per-repo split files, in both the flat and the phase-mode flow.** Step 0.9 is rewritten around `split-detect` with real loops, generalizing the paired-split path from two named Frontend/Backend slots into a loop over the active file set — two for a legacy pair, N for an N-repo project split — still spawning every member in a single tool-call turn. Each split file's worktree and container are rooted at that file's own repo, and `SPLIT_WORKTREE_PATH` is built from `git -C "$SPLIT_ROOT" rev-parse --show-toplevel` rather than from the project path, because `worktree-manager.sh` resolves its worktree-name argument against the repository toplevel and not against CWD — for sibling repos the two coincide, for a monorepo subdirectory they do not. The collision check accordingly keys on `(repo toplevel, branch)` rather than on the branch alone. Completion-report totals are summed with `git -C` per repo against that repo's own default branch. Step 1.7's Phase-Mode Paired Split takes the same generalization and consumes the same verb, scoped to the phase's own directory.
- **`.project` is treated as sub-agent-authored text everywhere it is rendered.** `/aimi:plan`'s Step 5 renderer was told to render `smellWarnings` as-is, justified by "project values are routing keys derived from `.project`, not free text" — true when the discriminating field was `side`, a closed-set CLI literal, and false once `project` carries text a sub-agent wrote. That clause is dropped; the four-step untrusted-content treatment is now required on `message`, `droppedDeps[].title`, `project`, `side`, and `droppedDeps[].project`. `story-merge` sanitizes `.project` and `.title` alike in its own refusal output, and `execute.md`'s phase-mode branch-derivation loop gained the traversal rejection and charset regex the flat side already had — not for branch safety (slugify already guarantees the branch regex) but because `SPLIT_PROJECT` is echoed verbatim into the aggregated report and into each spawned Task's description.
- **TC18, TC20, TC21, TC22, TC29, and TC30 in `test-aimi-cli.sh` were rewritten on purpose — read the flipped assertions as expected, not as a regression.** The first four pinned the majority-vote behavior removed below and went red the moment that vote was deleted: superseded, not broken. TC18 now asserts that a two-distinct-project fixture yields one file per project and no side files at all; TC20 generalizes the two-file bipartition invariant to an N-way one while keeping an arity floor that names both files; TC21 asserts `.project` survives verbatim on every story of every per-project file; TC22 swaps its tie-goes-to-backend assertion for a normalization-boundary one. TC29 inverted: its fixture — two tagged repos plus an untagged story — is now the refusal case, and TC47 picks up the half of the contract that survives, that an explicit `"."` still forms a root group. TC30's rationale comment was factually wrong and is corrected: verified against the pre-change CLI, the singleton was not swallowed by the majority vote; the real defect was N repos force-fitted into two side-named files. Each rewritten case carries a leading `SUPERSEDED, NOT BROKEN` comment naming exactly what it used to assert and pointing here.
- **Six mutations that survived the whole suite are now killed by named assertions**, each proven by breaking the production code in a scratch copy and watching the new assertion fail. `wave` was never read on any project-split file, so deleting `recompute_waves` from the PROJECT writer survived everything while shipping `dependsOn: []` stories at wave 2; TC28/TC34/TC35 now assert `.userStories[].wave`. TC48 covers `--phase-aware` on the PROJECT axis, which no prior case could reach. TC49 covers the partial-write handler, reachable only since the `set -e` fix below. Assertions that could not fail are repaired or deleted: unfalsifiable `_fe`/`_side` leak checks on a path that computes neither key, a `sort -u` duplicate check that needed `uniq -d`, an "identical `smellWarnings`" pair that passed on the empty set, a directory assertion that could not fail, and two else-branches that under-reported a missing file by 12 and 7 failures.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** This release does change `story-merge --split full-stack`'s output format for multi-repo plans: a different number of files, different filenames, a changed return contract, and a refusal where a partially tagged plan previously produced two files. Under this repo's own "MAJOR: breaking changes to command syntax or output format" rule that could be read as MAJOR. MINOR is chosen on the identical precedent set by PR #68 / 1.113.0 — which also changed split output for existing multi-repo plans (partition-by-`project` plus a new `smellWarnings` entry type) and shipped as MINOR — and because `story-merge` is an internal CLI verb invoked by `/aimi:plan`, not a user-facing command surface, while the single-repo/monorepo path here is byte-identical to 1.115.0.

### Removed

- **The strict-majority vote that assigned an entire project group to one side, and its tie-goes-to-backend bias, are deleted outright** — not left unreachable behind the new axis. Introduced in 1.113.0, it grouped stories by `project` and then sent each whole group to whichever split file won a strict majority of its members' individual file-pattern/keyword verdicts, ties going to backend. On a genuinely multi-repo plan that question has no correct answer, and the vote answered it wrongly: a real frontend project whose stories happened to trip backend-looking heuristics was moved wholesale into the backend file. That is issue #72 (`aimi-so/aimi-engineering-plugin`), reproduced with both two-repo and three-repo layouts. Separate repos are now separated by layout, so no side verdict — and no tiebreak — is computed for them at all.

### Fixed

- **A five-reviewer audit of this branch raised roughly forty findings, eleven of them blocking; all eleven are fixed here.** Each reviewer was required to prove findings by execution. Two were bad enough to name individually. First, the axis dispatcher and the group router used **different normalizations** of the same field — the dispatcher discarded untagged stories before counting while the router turned those same nulls into a real `"."` group one function away — so one tagged repo plus untagged stories counted as a single distinct project, took the SIDE axis, and produced **one output file and one branch for two repositories**, reintroducing issue #72 inside the change meant to fix it. Divergence is now impossible rather than merely corrected: the dispatcher computes nothing of its own, both `// "."` fallbacks are gone, and a single shared `group_key` definition is the only routing key in the file. Second, `AIMI_ROOT_IS_GIT_REPO` was **never assigned in any executable block** — only by an English sentence in Step 1.5 — and since each Bash call is an isolated shell, the phase-mode guard read an empty variable and `[ "" != "true" ]` is true, so **every phase-mode run in an ordinary single-repo layout refused with "multi-repo layout detected"**. Phase mode was unusable, not merely fragile; the value is now a per-block derived one-liner, the same convention the file already uses for `AIMI_CLI` and `AIMI_ROOT`. The remaining nine span the same three root causes — a `"."` root group that was invented mid-implementation and never specified, a Step 0.9 that ran before phase-mode detection and scanned unbounded, and three stories that changed only prose in a repo that could not test prose: Step 0.9's per-file blocks read a `$split_file` that no loop set; the phase-split merge used `mapfile`, absent under zsh and macOS bash 3.2, with an arity guard below it that turned the failure into a silent no-op; phase Pass 2 gated on a variable Pass 1 also empties on validation failure, so a failed group ran a stale legacy pair right after announcing it would degrade; the split dev-server gate collapsed N per-member decisions into one scalar so only the last member's value survived; and the N-file partial-write handler was dead code — `set -euo pipefail` exited the shell at the failing compound command before `write_exit=$?` could run, leaving one file on disk advertising `total: 3` with two siblings that did not exist, an orphaned `mktemp` file, and no error message at all. That handler now reports three sets — written before the failure, the failure itself, and never attempted — plus the preserved staging directory, because every file that did land advertises a split that is not on disk.
- **Issue #73 reframed and addressed: multi-repo + container + split was a diagnosability defect, not a corruption one (`aimi-so/aimi-engineering-plugin`).** Verified empirically before any fix was written — the combination corrupts nothing. `cd "$AIMI_ROOT"` followed by a worktree create under a non-git parent folder exits **128** with a bare `fatal: not a git repository` and creates nothing at all; the failure is total and immediate, and what it fails to do is name the phase, the layout, or the fix. Three changes address that. Each split file now owns exactly one repo, so its container is created under that repo rather than under the non-git root, which removes the failure from the flat multi-repo split path entirely. Worktree paths are derived from the repository's git toplevel rather than from the project path, so they point at a directory that will actually exist. And for the combinations that remain unsupported, `/aimi:execute` refuses clearly instead of letting git produce the opaque message: a guard placed before the first `cd` and before any `$WORKTREE_MGR create`, covering phase mode under a non-git root and the case where a multi-repo plan converges on a single surviving repo and therefore lands as a two-file frontend/backend split under that same non-repo root. The refusal names the detected layout, the exact failure that would otherwise follow, and what to do about it — and it releases the phase claim in the same block that makes the decision, so a single-repo layout never touches the release and a multi-repo layout can never skip it.
- **Path traversal could reach a bare `cd` in `/aimi:plan`.** The only validator that rejects `..` ran in Phase 4.5, after Phase 4 had already handed the raw sub-agent-authored `.project` to `detect-default-branch --project`. A Project Path Gate now validates every distinct staged `.project` at the top of Phase 3e — while `RUN_DIR` still exists and nothing has been written — with the same guard repeated in Phase 4 as defense in depth; both mirror `execute.md`'s Step 0.9 check byte-for-byte so the sites stay diffable. Refusing in Phase 4 instead would fire after `story-merge` had already deleted the staging directory, destroying the run.
- **Stale prose describing the deleted majority vote as current behavior** is corrected in `skills/task-planner/SKILL.md`, its `references/pipeline-phases.md` copy, `references/validation-checklist.md`, `commands/references/user-communication.md`, and `story-merge`'s own `--help` text, all of which still described a split that always produces exactly two files. `validation-checklist.md` additionally records the new tagging contract: in a multi-repo plan every story needs a `project`, and a story belonging to the root must say so with `"."`. `metadata.splitGroup` — mandated by the Phase 4 checklist and detected on by `/aimi:execute`, yet absent from both normative schema blocks — is now documented in `/aimi:plan`'s Schema v3.3 Structure block and in `plugins/aimi-engineering/CLAUDE.md`'s Tasks File Schema, which also gains both `cross-file-dep-dropped` shapes and their mutual exclusivity; `cmd_help` documents `--foundation`, which was entirely absent while being fully implemented and routinely passed by `/aimi:plan` Phase 3e, and rewrites the `--phase-aware` paragraph to cover both axes and the new `-tasks` precondition. The root `CLAUDE.md` testing section now lists three suites and says why a prose-only edit under `commands/` is a code change. No README.md edit accompanies this release — no command, skill, or agent was added or removed, so the component-count tables are unaffected.

### Known Limitations

- **The SIDE-axis writer still carries the latent `set -e` partial-write bug the PROJECT writer just fixed.** `_story_merge_write_split`'s `fe_exit`/`be_exit` sites have the identical shape: a bare compound command under `set -euo pipefail` exits the shell before the following `$?` read can run. It is deliberately not fixed here. Doing so would change SIDE-axis stderr and exit code on write failure, and eight pinned tests plus this branch's byte-identical-SIDE merge gate depend on exactly that behavior. Deferred to a follow-up that can move the tests and the code together.
- **`metadata.splitGroup.siblings` embeds every other member's path in every file, so its total size grows quadratically in the number of repos.** Accepted rather than fixed: at realistic repo counts the cost is noise, and the obvious alternative — having each consumer reconstruct sibling filenames from a naming convention — is exactly what the rest of this pipeline forbids, because the surviving projects and their slugs are computed inside `story-merge` and are not derivable by any caller.

### Migration

- **Split task files written before 1.116.0 keep executing unchanged.** They carry no `metadata.splitGroup` marker, so `/aimi:execute` falls through to the legacy `-frontend-tasks.json` / `-backend-tasks.json` suffix-and-shared-prefix rule, which survives as an explicit documented fallback rather than as dead code. Nothing needs re-planning and no file needs rewriting; only newly merged multi-repo plans take the project axis.
- **A plan that tags some stories with `project` and leaves others untagged must be updated before it will merge.** Under `--split full-stack` that plan now refuses instead of producing a frontend/backend split. Give every story a `project`, using `"."` for stories that belong to the root repository; the refusal message names each story that needs one.

## [1.115.0] - 2026-07-26

### Added

- **`commands/references/user-communication.md`.** New human-facing writing-style reference governing the wording, tone, and density of text a plugin command sends directly to the person running it — completion reports, chat explanations, and `AskUserQuestion` prompts — formatted as five before/after pairs, each with a checkable rule caption (e.g. "grep the block for ... — zero matches") so a rewrite's compliance is verifiable, not just asserted. Scope is human-facing text only: it explicitly excludes text sent to subagents (Task spawn prompts), whose objective — sufficiency to a fresh-context agent, not human readability — is the opposite of this file's density and jargon rules. Introduces the Adaptive Language Rule: user-facing output follows whatever language the person is writing in, so a command that hardcodes a single language into a completion report or prompt is a defect under this rule regardless of which language is hardcoded. Wired into three call sites: `plugins/aimi-engineering/CLAUDE.md`'s Command Conventions, `AGENTS.md`'s `<scope>` block, and `commands/references/interactivity.md`'s "Adding a New Question Site" checklist.

### Changed

- **Four interactive gates normalized from Portuguese to English**, the first application of the new Adaptive Language Rule rather than a plain translation: `brainstorm.md`'s Prototype Offer Gate (`Prototipar`/`Tenho uma referência`/`Pular` → `Prototype`/`I have a reference`/`Skip`) and its foundation-proposal-reuse offer (`Reaproveitar existente`/`Criar novo` → `Reuse existing`/`Create new`); `plan.md`'s Phase 1.9 Greenfield Foundation Gate (`Aceitar`/`Ajustar`/`Pular` → `Accept`/`Adjust`/`Skip`, plus the derived resolution language and the outline-gate rejection message); and `setup-models.md`'s five model-category questions and `cli-path-resolution.md`'s matching first-run model-config prompt (question and option wording only — picker format is unchanged).

### Fixed

- **`setup-models.md` Step 0 CLI path resolution.** Replaced a hardcoded developer-machine absolute path (one contributor's local checkout of `cli-path-resolution.md`) with `${CLAUDE_PLUGIN_ROOT}`, which `install.sh` already translates for OpenCode installs — the command now resolves correctly on any machine and under either host.

## [1.114.0] - 2026-07-26

### Added

- **`detect-parent-branch` aimi-cli.sh verb.** New `aimi-cli.sh detect-parent-branch <branch>` resolves a branch's parent by walking `git log --first-parent` ref decorations as individual tokens — never as whole lines or substrings — matching candidates against the current branch by exact token equality, then verifies the surviving candidate via `git merge-base` before returning it. Falls back to the default branch (`verified:false, source:"default-branch"`) when no candidate survives verification. Output shape: `{branch, base, verified, source}`. Extracted `_resolve_default_branch` as a shared private helper reused by the new verb, and covered by 29 new `test-aimi-cli.sh` assertions spanning all six defect/design cases.

### Fixed

- **`/aimi:open-pr` resolved the wrong base branch, and under container mode the wrong feature branch too (resolves issue #69, `aimi-so/aimi-engineering-plugin`).** Two independent defects failed silently. First, Step 2b's parent-branch detection piped `git log --first-parent --pretty=format:'%D'` through `grep -v "HEAD"` and `grep -v "$CURRENT_BRANCH"` (`commands/open-pr.md:128`) — line and substring filters where token filters were required, since `%D` packs every ref decorating a commit onto one comma-separated line. A parent decorated `HEAD -> <parent>` — exactly what git writes when the parent branch is the one checked out — lost its entire line to the first filter, and the second filter dropped any parent branch that merely contained the current branch's name as a substring (`feat/auth-base` vanishing when the current branch was `feat/auth`). Verified live in this repo: the old pipeline returned a branch 125 commits behind the true base, and because the result was non-empty it silently suppressed the default-branch fallback that would otherwise have caught the failure. Second, Step 2a resolved the feature branch via `git rev-parse --abbrev-ref HEAD`, which is wrong under container execution mode — the Main Working Tree Untouched Invariant plus `--keep-branch` teardown leave the feature branch checked out nowhere and HEAD parked on the base branch. Since `/aimi:plan` writes `"container"` by default for fresh flat tasks files, this was the default execution path, not an edge case; verified live, the old read resolved the base branch where the new one resolves the feature branch.
- **`/aimi:open-pr` now reuses the plugin's shared detection primitives instead of maintaining its own.** Step 2b/2c/2d call the new `detect-parent-branch` verb (reading `.base`, warning when `verified` is `false`) instead of the in-markdown grep pipeline; Step 2c uses the shared cached `$AIMI_CLI detect-default-branch` instead of a `gh repo view --json defaultBranchRef` network round-trip — `open-pr.md` was the only command in the repo still doing its own network round-trip for the default branch. Step 2a now resolves the branch from `metadata.branchName` via a guarded `$AIMI_CLI metadata` call (Case A: HEAD is already a real feature branch, reuse it; Case B: HEAD is on the default branch or detached, read the tasks file), mirroring the Case A/Case B pattern `commands/review.md` already uses for the identical problem.

## [1.113.0] - 2026-07-26

### Changed

- **`story-merge --split full-stack` now partitions by `project` instead of classifying every story independently, fixing documentation-only stories landing in the wrong split file (resolves issue #67, `aimi-so/aimi-engineering-plugin`).** Stories are first grouped by their normalized `.project` field (trim whitespace, strip one trailing slash, blank treated as absent), then each group is assigned to the frontend or backend output file by a strict majority vote of its members' own file-pattern/keyword verdicts, ties going to backend. Stories with no `project`, and any staging set where fewer than 2 distinct `project` values are present — including the monorepo case where no story sets `project` at all — keep the previous per-story heuristic unchanged, so single-repo and monorepo plans stay byte-identical to before. This fixes the concrete defect where a documentation-only story (files like `AGENTS.md`, `CLAUDE.md`, `docs/`) matched no frontend path pattern and landed in the backend split file even when its `project` field placed it alongside frontend siblings — after which it silently lost its cross-file `dependsOn` edges and became eligible for wave 1, schedulable before the stories it documents.
- **Cross-file `dependsOn` removal in the split is no longer silent.** Each split file must stay self-contained since the two files execute as independent sessions, so cross-file `dependsOn` edges are still dropped — but `story-merge` now emits one aggregated stderr banner reporting dropped-edge and affected-story counts, enumerates the stories that lost every dependency and therefore became wave-1 roots ("false roots"), and records one `cross-file-dep-dropped` entry per affected story in `metadata.smellWarnings` of both output files. Exit code is unchanged (still 0). No README.md edit accompanies this release — the fix adds no new command, skill, or agent, so the component-count tables are unaffected.

## [1.112.0] - 2026-07-24

### Added

- **`extract-sections` aimi-cli.sh verb.** New `aimi-cli.sh extract-sections <file> --anchors "<heading titles>"` prints only the requested `## `/`### ` sections of a research `.md` file, concatenated verbatim in request order — each section spans its matching heading up to the next heading of the same-or-higher level (or EOF), so an h2 anchor pulls in its nested h3s. `--anchors` accepts newline-separated heading titles matched case-insensitively (newline rather than comma, so a heading that itself contains commas — `## Testing, Linting, and CI` — stays matchable); an anchor with no matching heading is skipped rather than erroring and named in a stderr warning, and a run whose anchors match nothing exits 0 with empty output. Heading detection is fenced-code aware, so a `#` comment inside a ` ``` ` block never truncates a section. Anchors containing a shell metacharacter (`$`, a backtick, `"`, `\`) are rejected with a warning rather than processed — defense in depth behind the caller's own sanitization. Path confinement mirrors the existing `research-lookup` verb (`resolve_path` + `validate_path_in_project`). This is the slicing primitive the section-scoped Pass 2 delivery below is built on.
- **Structured claim/citation/quote findings format for research agents.** `AGENTS.md` gains a `<research_findings_format>` contract: every factual claim in a research agent's on-disk findings file must now be either a short verbatim quote plus a locatable citation (`file:line`, `path:Lstart-Lend`, or the most specific doc/URL pointer available) or explicitly tagged `[INFERRED]` when no source exists — no bare assertions. Wired into all five research agent specs (`aimi-codebase-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`, `aimi-learnings-researcher`, `aimi-design-bundle-researcher`). Composes with issue #64's planned `verify-citations` CLI pass, which this structure is designed to be mechanically checkable by; it extends (does not override) the existing `<preservation_rules>`/`<research_return_contract>` and leaves the pointer-block Task return (`research_file`, `summary`, `sections`) unaffected.

### Changed

- **`/aimi:plan` Pass 2 story expansion now receives section-scoped research excerpts with read-on-demand, replacing the full-corpus `researchFileBlocks` broadcast.** A new Per-Entry Section-Scoped Research Block Preparation step builds a `researchSectionsIndex` of each collected research file's heading anchors, selects the anchors per file most relevant to each outline entry's subject matter (typically 2-5; no hard cap), sanitizes each one before it reaches a shell argument, and slices them via the new `extract-sections` verb into that entry's `researchSectionBlock`, capped at 20 KB per entry — so per-spawn token cost scales with what each story actually needs rather than with the size of the entire research corpus. Every sub-agent also receives `allResearchPaths` — a new working-memory union of the files written this run and every reused research file — plus an explicit instruction to Read any of them in full when an excerpt is insufficient for an acceptance-criterion detail, so reused-research runs (the `/aimi:brainstorm` → `/aimi:plan` flow, where Phase 1.7 collects nothing because every file is already in context) still have a durable fallback. Phase 1.7's on-disk ingestion and the existing `researchFileBlocks` feed to outline generation and the Phase 3d.5 auditor are unchanged. Note the saving is asymmetric rather than absolute: it removes N sub-agent copies of the corpus, but the per-entry slices are pulled back through the orchestrator's own context to be inlined, trading sub-agent tokens for orchestrator tokens.
- **Learnings-researcher spawn now passes prototype file paths for on-demand reading instead of broadcasting prototype HTML blocks.** `/aimi:plan`'s learnings-researcher Task prompt replaces the inlined `prototypeBlocks` broadcast with `resolvedPrototypePaths`, instructing the agent to read those files itself, on demand, only when a `.aimi/solutions/` match is prototype-relevant.
- **Researcher exploration budgets and plan-then-search added to all five research agent specs.** Each of `aimi-codebase-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`, `aimi-learnings-researcher`, and `aimi-design-bundle-researcher` now derives a short list of concrete target questions before issuing any Grep/Read/Glob call, stopping each question as soon as it is confidently answered, and treats a tool-call ceiling as a soft budget — finishing a nearly-complete line of inquiry rather than cutting it off, but writing up partial findings once at or beyond the ceiling instead of exhaustively continuing to search. The three repo/web-facing researchers (`aimi-codebase`, `aimi-best-practices`, `aimi-framework-docs`) scale the ceiling by `researchDepth` (quick ~8, standard ~15, deep ~25); `aimi-learnings` (~10) and `aimi-design-bundle` (~12) use a fixed ceiling instead, since each already reads a bounded input set. The codebase researcher's migration-aware existence checks are explicitly exempt from the ceiling — a partial signal set may never be reported as an absent entity, which is what keeps the budget from manufacturing the false negative that doctrine exists to prevent.

## [1.111.0] - 2026-07-24

### Added

- **Five stack-convention skills**: `typescript-node-conventions`, `nestjs-conventions`, `nextjs-tanstack-conventions`, `go-conventions`, and `rust-conventions`. Each follows the `architecture-foundation` template — a self-sufficient `SKILL.md` (<300 lines) covering evergreen, version-independent conventions for that stack, deeper `references/` tiers for on-demand depth, and a `NOTICE.md` attributing its upstream source under the applicable license (MIT, CC-BY-4.0, or dual MIT OR Apache-2.0), with a matching `license: ... (NOTICE.md)` pointer in the frontmatter.
- **`/aimi:plan`'s file-pattern-to-skill mapping wired for all 5 new skills.** Story-expansion now attaches `typescript-node-conventions` for `*.ts` (non-test, non-`.tsx`), `bunfig.toml`, `bun.lock`/`bun.lockb`; `nestjs-conventions` for `*.module.ts`, `*.controller.ts`, `*.service.ts`, `nest-cli.json`; `nextjs-tanstack-conventions` for `app/**/*.tsx`, `app/**/*.ts` (non-test), `next.config.*`, `*tanstack*`; `go-conventions` for `*.go`, `go.mod`; and `rust-conventions` for `*.rs`, `Cargo.toml`. Matching is glob-scoped by extension (not a bare `app/**`) so the Next.js/TanStack mapping never collides with Rails' own `app/` directory. Stories whose files match both a generic and a framework-specific pattern (e.g. a NestJS `*.service.ts`) intentionally receive both skills — generic hygiene and framework structure are complementary.

### Fixed

- **`react-best-practices` NOTICE backfill.** The skill (`name: vercel-react-best-practices`, "from Vercel Engineering") shipped with no `NOTICE.md` despite incorporating MIT-licensed Vercel content. Added `plugins/aimi-engineering/skills/react-best-practices/NOTICE.md` naming Vercel Engineering as the source under the MIT License, and a `license: MIT (NOTICE.md)` pointer in the `SKILL.md` frontmatter, matching the `architecture-foundation/NOTICE.md` shape.
- **README.md skill count correction.** The `aimi-learnings` skill has shipped with a `SKILL.md` since its introduction but was never given a row in the Skills table, leaving the stated count permanently one short of the actual directory count. It now has a row in the Core (Internal) table, and the headline count is recounted from disk (`find plugins/aimi-engineering/skills -maxdepth 1 -mindepth 1 -type d | wc -l`) to 24, matching the enumerated table rows exactly.
- **Review remediation for the stack-convention skills.** Synced the file-pattern-to-skill mapping into `agents/workflow/aimi-story-expander.md` so the five new skills actually attach under both hosts — the agent-definition copy of the mapping table (the one OpenCode installs as the story-expander's system prompt) had not been updated alongside `commands/plan.md`, so stack stories risked hydrating no convention skill at all. Corrected the skill-eviction rationale in `plan.md`'s composition note: the emitted `skills[]` order is not pinned, so the 100KB `get-story-context` hydration cap makes no generic-vs-framework eviction guarantee (the note previously claimed the reverse of the actual drop-last-inserted behavior). Trimmed authoring-process narration that had leaked into shipped files — removed the hydrated "Context7 Verification Notes" section from `typescript-node-conventions/SKILL.md`; deleted `rust-conventions/references/context7-verification.md` (a process log citing a now-absent `.aimi/research/` path) and its two `SKILL.md` references; condensed `rust-conventions/NOTICE.md` from reproducing the full Apache-2.0 license text to a link (the MIT body and every per-source attribution retained); and removed a dangling `.aimi/research/` citation plus a defensive-writing meta-note from `go-conventions/NOTICE.md` (the substantive CC-BY 3.0→4.0 correction retained).

## [1.110.0] - 2026-07-24

### Added

- **brownfield-sem-convencoes as the second degree of the Phase 1.9 Greenfield Foundation Gate (issue #56 phase 3).** `/aimi:plan`'s gate no longer only fires on empty greenfield repositories — a repository with 5 or more tracked source files (or find-fallback matches) but no `CLAUDE.md`/`AGENTS.md` at `AIMI_ROOT` now classifies as brownfield-sem-convencoes ("established code with no captured conventions") and fires the same gate through condition (a), filtered through the shared ancestor-manifest lookup that now covers both degrees. `commands/references/foundation-signals.md` documents the classification and names `plan.md`'s Phase 1.9 as the consumer for both degrees; working-memory `foundationMode` is set to `brownfield` when this degree — rather than greenfield — is what held.
- **`aimi-foundation-architect` brownfield mode with repo-inspection.** The agent now accepts a `mode` input (`greenfield` | `brownfield`). In brownfield mode it runs a direct repository-inspection step (Grep/Glob against real source) before proposing conventions, so its output reflects the codebase as it actually is — verbatim lint config, a Module Template drawn from a real existing module — rather than a generic prescription; anywhere a coherent existing pattern can't be inferred, the gap is routed to the proposal's Open Questions section instead of guessed at. It still writes the same `-foundation.md` artifact shape (`foundationProposalPath`, 14-day freshness, path confinement, `research-gc` coverage, Foundation-first ordering) regardless of mode.
- **`architecture-foundation` skill.** A new self-sufficient (~200-280 line) `SKILL.md` skill packages condensed, actionable Clean Architecture (dependency direction, layers, ports/adapters) and Domain-Driven Design (Ubiquitous Language, Bounded Contexts, Entities, Value Objects, Aggregates, Repositories) guidance for both greenfield layering decisions and brownfield convention inference, with fuller tiers under `references/` for on-demand depth. Content is MIT-attributed via a `NOTICE.md` following the existing `frontend-design` pattern, and is attached only to the foundation-entry story (`foundationEntry: true`) rather than every story.
- **`foundationMode` threading through `story-expander`.** The brownfield branch of story expansion now receives and honors `foundationMode`, documenting conventions in-place (`CLAUDE.md`/`AGENTS.md` only) instead of scaffolding a greenfield-style folder layout — no `.gitkeep` placeholders, no overwriting an existing lint config.

### Fixed

- **`install.sh`'s `install_skills` now copies skill-root `NOTICE.md` files to the OpenCode install target.** Previously only `SKILL.md` and `references/` were copied, silently dropping any skill-root `NOTICE.md` — this had already been losing `frontend-design/NOTICE.md` on every OpenCode install, and would have done the same to the new `architecture-foundation/NOTICE.md`. Both skills' MIT attribution now survives the OpenCode translation.
- **`get-story-context` now resolves `aimi-` prefixed skills under OpenCode.** Skill hydration built the path from the bare skill name a story declares (`skills/<name>/SKILL.md`), but `install.sh` installs OpenCode skills under an `aimi-` prefix (`skills/aimi-<name>/SKILL.md`) — so every story-declared skill silently failed to hydrate under OpenCode (pre-existing, affecting all skills, surfaced while wiring the new `architecture-foundation` attach). The lookup now falls back to the `aimi-`prefixed directory when the bare path is absent; Claude Code's unprefixed cache is unaffected.

### Changed

- **`/aimi:open-pr` no longer leaks internal `US-NNN` story tags into the PR title or body.** Under the phase/story execute flow each story is its own commit whose subject carries a `US-NNN` tag, and the title also described only the first story's slice. Title derivation now prefers the tasks file's `metadata.title` (the human-authored feature title), falling back to the first commit subject with any trailing/leading `US-NNN` (or `Story US-NNN`) tag stripped, then to the branch name. The body's **Changes** bullets and the **Summary** subject-fallback now apply the same story-tag strip to every commit subject they render; commit bodies (the Summary's primary source) are still used verbatim, and the diff/Files-Changed section is unchanged.

## [1.109.0] - 2026-07-23

### Added

- **Greenfield detection and a Foundation question category in `/aimi:brainstorm` (Phase 1.8, issue #56 phase 2).** Brainstorm now runs its own Structural Signals check (`commands/references/foundation-signals.md`, shared with `/aimi:plan`'s Phase 1.9 gate) early in the session. When the target repository is greenfield, Phase 2's batched questions gain a conditional Foundation category — stack/runtime, architecture pattern, folder/convention structure, and lint/format tooling — alongside the standard topic categories, so these decisions are captured once, in the user's own words, instead of only at planning time.
- **Phase 3.7 Foundation Synthesis in `/aimi:brainstorm`.** When Foundation questions were answered, a new phase sanitizes and synthesizes the four sections `/aimi:plan`'s foundation flow actually consumes (CLAUDE.md Draft, AGENTS.md Draft, Folder Layout, Lint and Format Config) into a single artifact under `.aimi/research/`, gated by a validation check (all four sections present and concrete) before the pointer is ever emitted — a failed check degrades silently to `/aimi:plan`'s existing `aimi-foundation-architect` spawn path. A project-wide reuse check (`.aimi/research/*-foundation.md` glob — deliberately no topic-slug segment, since architecture is per-repository — with 14-day freshness and pre-acceptance validation of the candidate's confinement and 4-section content) offers reusing an existing fresh proposal instead of re-synthesizing on every run.
- **`foundationProposalPath` frontmatter key and its plan-reuse contract.** `/aimi:brainstorm` emits this single relative-path string in a brainstorm document's frontmatter only when Phase 3.7 validated its artifact (fresh reuse counts); the key is omitted entirely — no placeholder, no companion boolean — otherwise. `/aimi:plan`'s Phase 0 reads it under a strict, narrow path-confinement regime (join to `AIMI_ROOT`, `realpath` resolve accounting for traversal/symlinks, require the result to land inside `.aimi/research/` and end with `-foundation.md`), checks existence and 14-day freshness, and on success feeds the validated path into Phase 1.9's Greenfield Foundation Gate as a second reuse source alongside the existing topic-slug glob. Post-review hardening: the confinement boundary was narrowed from a bare `AIMI_ROOT` prefix to the foundation-artifact directory and filename shape, brainstorm's own reuse path now pre-validates candidates (confinement + 4-section content) instead of trusting a filename glob, and `research-gc`'s scalar extraction tolerates YAML-quoted values and trailing comments so a live pointer can never be mis-parsed into deleting its artifact.
- **`/aimi:plan` Phase 0 reuse wiring and Phase 1.9 hardening.** Phase 1.9's fire-condition and reuse-source logic now account for a Phase 0-populated `foundationProposalPath`, applying the same mtime tie-break the topic-slug glob already used when both sources resolve and differ. The gate's mature-repo, multi-repo, and roadmap-continuation skip branches now consistently reset any Phase 0-populated `foundationAccepted`/`foundationProposalPath` pair to unset/false before skipping, closing a gap where those branches previously left a stale pointer in place.
- **`research-gc` third orphan-check source.** The orphan garbage collector now also treats any `.aimi/brainstorms/*.md` frontmatter `foundationProposalPath` as a live reference, alongside the existing `metadata.researchPaths` and frontmatter `researchPaths` sources, so a synthesized foundation proposal with a live pointer is never swept as an orphan.

## [1.108.0] - 2026-07-23

### Added

- **Greenfield Foundation Gate in `/aimi:plan` (Phase 1.9, issue #56 phase 1).** When planning targets a repository with no established architecture (structural absence signals plus additive keyword signals, mirroring `ui-signals.md`'s detection pattern), `/aimi:plan` now inserts a gate after research and before spec-flow analysis that proposes a prescriptive architecture foundation before story decomposition begins. The gate loops on **[Ajustar]** (re-spawn the architect with accumulated adjustment text) until a terminal choice — **[Aceitar]** or **[Pular]** — is reached, pattern-parity with the Phase 3c Outline Gate's edit loop. `plugins/aimi-engineering/commands/references/foundation-signals.md` centralizes the detection vocabulary (structural absence markers, additive keywords) the gate uses to decide whether to fire.
- **`aimi-foundation-architect` agent.** A new prescriptive architecture agent (distinct from the descriptive `aimi-codebase-researcher`) that proposes a stack-appropriate Clean Architecture/DDD-inspired foundation — layering, module boundaries, and conventions — writing a single `FOUNDATION.md`-style proposal file under `.aimi/research/` for the gate to present.
- **`story-merge --foundation <idx>` flag.** When the Greenfield Foundation Gate is accepted, the foundation story becomes outline entry `01` (immutable through the Phase 3c Outline Gate) and its assigned `US-NNN` id is injected into every other story's `dependsOn` via a deterministic post-merge sweep — the foundation always lands in wave 1, and every other story's wave reflects the added dependency.
- **`story-expander` `foundation_proposal` support.** Sub-agents expanding non-foundation outline entries now receive the accepted foundation proposal's content (capped, HTML-entity-escaped) as additional context, so every generated story is consistent with the accepted architecture.
- **`metadata.decisions[].anchor` form `foundation:<topicSlug>` and `metadata.decisions[].source` value `"foundation"`**, documented in `plugins/aimi-engineering/CLAUDE.md`'s Tasks File Schema section, covering the Aceitar/Ajustar/Pular decisions the Phase 1.9 gate records in `oqDecisions[]`.

## [1.107.0] - 2026-07-23

### Changed

- **`/aimi:plan` now defaults freshly generated flat `tasks.json` files to `metadata.execution: "container"`** (previously `"inline"`). This is backward-compatible: existing files with the field absent still resolve to `"inline"` via the read fail-safe, and `--inline` can still be passed to `/aimi:execute` or `/aimi:next` to run a single invocation inline.

## [1.106.0] - 2026-07-23

### Added

- **Proactive Prototype Offer Gate in `/aimi:brainstorm` (Phase 3.6, issue #55).** Brainstorm now checks whether the drafted roadmap ships a frontend by inspecting **structural** roadmap deliverables — phase `creates` entries, `areas`, and the feature `goal` — rather than relying on the free-text description alone. This closes the gap where a backend-worded description ("add an endpoint for X") still ships a UI and previously skipped prototyping silently. When a frontend deliverable is detected and no prototype exists yet, brainstorm offers a three-option gate: **[Prototipar]** (launch guided prototype creation), **[Tenho uma referência]** (Reference Intake — see below), or **[Pular]** (skip, proceeding without a prototype). The gate only fires once per brainstorm session and never blocks progress.
- **Reference Intake flow.** When the user has an existing reference instead of wanting a prototype built from scratch, brainstorm accepts a local image, HTML/CSS file, a URL, or free-text description of the look-and-feel, and feeds the extracted visual tokens (colors, spacing, component shapes, copy tone) into the design pipeline as **Probe #0** — a seed probe that subsequent design exploration builds on rather than starting from a blank slate.
- **`plugins/aimi-engineering/commands/references/ui-signals.md`.** A new shared reference unifying the vocabulary used to detect "this feature has a UI" across commands: the keyword list (visual/UI-bearing terms) and the structural markers (roadmap `creates`/`areas`/`goal` patterns that imply a frontend). Both `/aimi:brainstorm` and `/aimi:plan` now source their frontend detection from this single file instead of maintaining separate, drifting keyword lists.

### Changed

- **`/aimi:brainstorm` Phase 1.7** now sources its keyword list from `ui-signals.md` instead of an inline list. The keyword scan is kept as an additive signal alongside the new structural check, and its vocabulary was extended with `frontend` and common framework names (React, Vue, Next.js, etc.) so more real-world descriptions are caught.
- **`/aimi:plan`** now emits a non-blocking warning when a frontend-bearing feature reaches the end of planning with no prototype on record, surfacing the same structural signal used by the brainstorm gate so features planned without going through `/aimi:brainstorm` first still get a nudge — the warning never stops or fails planning.

## [1.105.0] - 2026-07-21

### Added

- **Container execution mode for `/aimi:execute` and `/aimi:next`.** A new `metadata.execution` discriminator (`"container"` | `"inline"`) lets a tasks.json run its stories inside an isolated git worktree ("container") at `.worktrees/<branchName>` instead of against the current working tree. It's opt-in per invocation: pass `--container` (or `--inline`) on `/aimi:execute` or `/aimi:next` to select the mode for that run — the two flags are mutually exclusive — and when the choice differs from what the file already has, it's persisted onto `metadata.execution` via the new `aimi-cli.sh set-execution-mode` subcommand, so a later invocation without the flag stays in the same mode. In container mode, `/aimi:execute` creates or reuses the feature's container, installs dependencies once via the new `worktree-manager.sh install-deps` subcommand (lockfile-detected package manager — bun/pnpm/yarn/npm, silent skip when no `package.json`), starts a managed loopback-only dev server (new `serve start|stop|status` subcommand, state tracked in `.aimi/state/dev-server.json`) before the wave loop whenever a story needs visual verification, and runs the full wave loop inside the container. On completion, the dev server is stopped; pushing `<branchName>` to `origin` requires confirmation (an AskUserQuestion prompt in an interactive session, an explicit `--push` flag in agent mode — otherwise it's skipped), and the container is then removed while the branch itself is preserved (`worktree-manager.sh remove --keep-branch`) — the completion report points to `/aimi:open-pr --branch <branchName>` (which pushes on your behalf if needed) and `/aimi:review <branchName>` as next steps, since nothing is left checked out locally. `/aimi:next` gains the equivalent behavior for sequential execution, containerizing the feature branch across invocations and passing the container path as `WORKTREE_PATH` to the story executor; it refuses to run at all against a phase-scoped tasks file, pointing at `/aimi:execute` instead, since it has no phase-claim logic of its own. The 1.104.0 phase/milestone roadmap layer's own containers get the same managed dev server treatment, so visual verification works identically whether a feature runs flat or phased — a claimed phase always executes inside its own phase container regardless of `metadata.execution`, and phase-scoped tasks.json files never carry that field at all.
- **`metadata.execution` backward-compatibility guarantee.** The field is optional and defaults to `"inline"` when absent — every tasks.json created before this change, and any new one that doesn't set the field, keeps executing exactly as it always has, directly against the current working tree, with no container ever created. `/aimi:plan` writes `"inline"` explicitly into every freshly generated flat tasks.json and omits the field entirely on phase-scoped files; only an explicit `--container` override on `/aimi:execute` or `/aimi:next` opts a file into container mode.

### Fixed

- **Paired-split branch deletion in `/aimi:execute`'s Aggregated Completion report.** The flat full-stack paired-split completion path used to remove both the frontend and backend worktrees with a plain `worktree-manager.sh remove`, which also deleted their branches — the very branches the report had just told the user to open PRs from. It now passes the new `--keep-branch` flag, so the worktrees are cleaned up but both branches survive for `/aimi:open-pr` and `/aimi:review`.

### Known Limitations

- Non-Node stacks (no `package.json` with a `dev` script) get no managed dev server in container mode; visual verification degrades to `skipped` rather than failing the run.
- Ports hardcoded in application configuration (OAuth redirect URIs, CORS allowlists) are not remapped when the managed dev server binds to a different free port than expected.
- There is no proxy between sibling containers in a full-stack split, so visual verification from one container cannot reach the other container's API.
- Uncommitted edits left in the main working tree do not propagate into a container — `git worktree add` only branches from committed history, so any dirty-tree changes must be committed first.

## [1.104.0] - 2026-07-19

### Added

- **Phase/milestone roadmap layer for large-scope features.** A new optional planning tier sits above the existing flat pipeline for features too large to expand and execute in one pass. `/aimi:brainstorm` gains a Phase 3.5 roadmap-definition gate that lets the user cut a feature into named phases (with goals, success criteria, and `creates`/`needs` contracts) instead of a single flat scope; `/aimi:plan` falls back to the same phase-cut classification inline when no brainstorm roadmap exists. When phases are defined, a new `roadmap.json` artifact is materialized at `.aimi/tasks/<feature-slug>/roadmap.json`, tracking each phase's lifecycle status (`pending → planned → in_progress → completed`, or `→ verification_failed`), dependencies, and claim state. Each phase gets its own `.aimi/tasks/<feature-slug>/phase-N[.M][-slug]/` folder holding a phase-scoped `tasks.json` (materialized by `/aimi:plan --phase N`'s rolling-wave expansion) and a `handoff.md` summarizing decisions, artifacts, deviations, deferred items, and delivered contracts. `/aimi:execute` becomes phase-aware — it can claim and run an eligible phase, including parallel sibling sessions claiming independent phases concurrently, and composes with `--split full-stack` for phases that need paired frontend/backend task files. `/aimi:status` gains a roadmap summary view and a `--phase N` detail view. Eleven new `aimi-cli.sh` subcommands (`roadmap-init`, `roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim`, `roadmap-reconcile`, `roadmap-write-handoff`, `validate-contracts`, `phase-overlap`, `roadmap-sweep`, `estimate-payload`) back the whole lifecycle; `roadmap.json` and each phase's `handoff.md` are protected from direct Write/Edit-tool writes via `AIMI_RUNTIME_STATE_GUARD` the same way `.aimi/tasks/*-tasks.json` is (a Bash-issued write is not intercepted). **Single-scope-context features are entirely unaffected** — the flat `YYYY-MM-DD-[feature-name]-tasks.json` pipeline is unchanged and carries zero overhead when no roadmap is defined.

## [1.103.0] - 2026-06-25

### Changed

- **Restricted `allowed-tools` on the three filesystem-facing research agents to read-only + Write.** `aimi-codebase-researcher`, `aimi-learnings-researcher`, and `aimi-design-bundle-researcher` now declare `allowed-tools: Read, Grep, Glob, Write` (previously they inherited the full tool set). This captures the read-only safety posture of the built-in `Explore` agent — these agents crawl the user's source tree and can no longer `Edit`/`NotebookEdit` existing files or spawn sub-agents — while preserving `Write`, which the pointer-only research handoff depends on (each agent writes its findings to `.aimi/research/*.md` and returns only a pointer). Matches the existing `allowed-tools` convention already used by `aimi-bundle-prototype-author` and the workflow verifier agents. The web/MCP-dependent researchers (`aimi-best-practices-researcher`, `aimi-framework-docs-researcher`) are intentionally left unrestricted, since an allowlist would have to enumerate host-specific Context7 MCP tool names and risk silently breaking their external-documentation lookups.

### Notes

- This restriction is honored under Claude Code (which reads the plugin source verbatim). As with the five pre-existing `allowed-tools` agents, the OpenCode translator (`install.sh` `translate_agent`) does not yet propagate `allowed-tools` into OpenCode agent frontmatter, so under OpenCode these agents retain their current tool set — no regression, but no parity. Adding `allowed-tools` translation to the OpenCode installer is tracked as a separate follow-up.

## [1.102.0] - 2026-06-25

### Changed

- **Default `metadata.maxConcurrency` raised from `5` to `20`.** The wave-based executor now fans out up to 20 stories in parallel by default (previously 5), and the worktree-budget guard (`pre-bash-dispatcher.py`) allows up to 20 concurrent story worktrees before denying `git worktree add`. The new default is applied consistently across `aimi-cli.sh` (`status`/`metadata` fallbacks, including the `<= 0` floor), the `pre-bash-dispatcher` worktree-budget guard, and `/aimi:plan` (the value written into new tasks.json files). Explicit per-task overrides are unaffected — set `metadata.maxConcurrency` to any value (e.g. `1` for strictly sequential execution).

## [1.101.0] - 2026-06-24

### Added

- **Phase 1.8 Scope-Pruning-Positive Gate + new `aimi-scope-positive-verifier` workflow agent.** The `/aimi:plan` pipeline now runs a positive-premise verification step (Phase 1.8) after the existing scope-pruning-negative gate. A new standalone agent `aimi-scope-positive-verifier` receives each load-bearing positive spec premise and verifies it by data-flow analysis, tracing the actual call graph to confirm the claimed behavior exists. Premises that cannot be verified emit a `specFlow:CriticalQ` decision entry for human review before story expansion begins. Agent lives at `plugins/aimi-engineering/agents/workflow/aimi-scope-positive-verifier.md`.
- **Phase 1.6b research-conflict escalation gate.** When a researcher finding directly contradicts a spec premise, the plan pipeline now escalates the conflict as a `researchConflict:<n>` decision (source `"researchConflict"`) instead of silently suppressing it. The human reviewer resolves the conflict at the outline-review gate before story expansion proceeds.
- **`research-lookup --ignore-missing-cited-paths` flag.** Callers that tolerate missing file references (e.g. migration stories that cite to-be-created files) can now pass this flag to suppress the stale-exit triggered by non-existent cited paths. Freshness is still checked against all paths that do exist.
- **`normalize-status` CLI subcommand.** `aimi-cli.sh normalize-status <tasks-file>` auto-heals tasks files that are missing the `status` field on one or more stories by injecting `"status": "pending"` in-place. Designed to run before `validate-stories` so pre-fix tasks files self-repair without requiring manual edits.

### Fixed

- **`story-merge` now defaults `status: "pending"` in all three JSON writers** (legacy single-file, split-frontend, split-backend). Previously only the story-expander schema included a default, leaving the merge writers as the authoritative path missing the field. `validate-stories` has been updated with a `has(status)` predicate that rejects any story missing the field — ensuring the `/aimi:deepen` command no longer finds zero pending stories due to a missing `status` key.
- **`/aimi:deepen` reuse-gate now matches `touched-area` (existing-file overlap) instead of full file-set superset.** The previous gate required the new story's entire file set to be a subset of the cached research file set before allowing reuse. Migration stories that add new files alongside existing ones always failed this check and forced a full researcher re-spawn. The gate now fires when the intersection of the story's `implementation.files` with the cached research's cited paths is non-empty — so migration stories correctly reuse plan research for the files they share.

### Notes

- **Fix 4 (skill map defaults to `dhh-rails` for unmatched files) investigated and confirmed NON-BUG.** The original proposal listed a fix for the story-expander skill map defaulting unmatched file extensions (e.g. `*.ts`) to `dhh-rails-style`. Codebase cross-check (Phase 2.4) confirmed no TypeScript skill exists in this plugin — the only TypeScript-related agent is `aimi-kieran-typescript-reviewer`, which is a review agent, not a skill. The existing omit-on-no-match behavior (no skill selected when the extension has no mapping) is already correct. No skill-map change was shipped in this release.

## [1.100.1] - 2026-06-19

### Fixed

- **Concern 6 of `aimi-cross-story-auditor` reframed from "verification" to "surfacing".** The 1.100.0 design attempted to auto-verify deferral phrases by substring-matching the noun phrase preceding the deferral against the target story's acceptance criteria. Self-review caught a critical false negative: the noun in a deferral (e.g. "affiliation") commonly appears verbatim in the helper name introduced by the target story (e.g. `requiresAffiliation`), so a substring match produces a tautological "deferral honored" verdict — a silent pass that looks like a clean check. Worse than no check at all, because reviewers trust silence. Replaced with **deferral surfacing**: every matched deferral phrase emits an `unresolved[]` entry naming the source story and target story; the human reviewer judges whether the target wires the deferred behavior or only exposes a helper. The regex stays strict (only `deferred to (story )?\d+` and `story \d+ (will|owns|covers)`) — looser phrases still produce too many false positives.

## [1.100.0] - 2026-06-19

### Added

- **Two new built-in audit concerns on `aimi-cross-story-auditor`.** The agent now evaluates six concerns instead of four. (a) **Orphan public APIs** — when a story's `implementation.approach` introduces a named symbol (camelCase / PascalCase / snake_case, length ≥ 6) that does not appear in any sibling story's text corpus (title, description, AC, approach, files, tasks), the agent emits an `unresolved[]` entry naming the symbol and the producer story; reviewer decides whether it is a legitimate leaf API (CLI entry point, webhook handler, SDK surface) or a planning gap. Skipped when staging set contains only one story. (b) **Honored deferrals** — when a story's `notes` contains the strict-regex phrases `deferred to (story )?\d+` or `story \d+ (will|owns|covers)`, the agent extracts the target outline index and the noun phrase immediately before the deferral, then verifies that the target story's `acceptanceCriteria` contains a substring of that noun phrase (case-insensitive). When the deferral is not honored, the agent emits an `unresolved[]` entry naming the source story, target story, and unhonored concept. The regex is intentionally narrow — `future work`, `out of scope`, `intentionally not enforced here` are NOT matched because they signal vague aspirations without a named target.
- **`metadata.smellWarnings[]` field on the merged tasks.json (`aimi-cli.sh story-merge`).** Phase 4.2 orphan-symbol findings are now embedded in the output tasks.json (in addition to the existing stderr warning), so the orchestrator's Step 5 report can surface them without parsing stderr. Each entry has shape `{type: "orphan-symbol", storyId: "US-NNN", symbols: ["symbolA", ...], message: "..."}`. The field is written by both legacy and split-mode writers (in split mode, the same array is written to both frontend and backend files so per-file summaries stay self-contained). Absent entirely when no orphan symbols were detected — backward-compatible for downstream consumers.

### Changed

- **`/aimi:plan` Step 5 report renders `metadata.smellWarnings`.** A new `Smell warnings: N orphan-symbol finding(s)` line appears in the report when the merged tasks.json has a non-empty `smellWarnings` array, followed by one bullet per entry showing `storyId`, `type`, `symbols`, and `message`. No sanitization required (fields are CLI-emitted literals or regex-constrained). Omitted entirely when absent or empty.

## [1.99.1] - 2026-06-17

### Fixed

- **`story-merge` ingests `audit-result.json` as a phantom story (`aimi-cli.sh`).** The staging glob excluded only `outline.json`, `*outline*.json`, and `metadata.json`, but Phase 3d.5 writes its debug artifact to `<RUN_DIR>/audit-result.json` in the same directory — so the merger picked it up as a story-shaped JSON object, producing a malformed `tasks.json` entry with no `title`/`description`/`acceptanceCriteria`. Added `audit-result.json` to the exclusion case. Consistent with the strict `[0-9][0-9]-*.json` prefix glob already used by Phase 3d.5's own staging lookup.
- **`validate-stories` rejects natural-markdown single backticks in `title`, `description`, and `tasks[]` (`aimi-cli.sh`).** The suspicious-content regex listed single backtick alongside triple-backtick and `$(`, blocking common phrasings like `Run \`bun run test\` after edit` even though `tasks[]` only flows into LLM prompts (one site: `next.md:135`, XML-wrapped) — never into shell. Narrowed the regex to triple-backticks and `$(`, which remain the actual prompt-injection vectors. Authored `plan.md` Pass 2 prompt doc updated to drop `backticks` from the Forbidden list.

## [1.99.0] - 2026-06-15

### Added

- **Phase 2.4 Codebase Cross-Check gate (`plan.md`).** A new phase that runs between Phase 2 (spec-flow open questions) and Phase 2.5, auto-resolving sanitized spec-flow OQs when the named symbol is already implemented in the target codebase. For each OQ batched through the `aimi-spec-flow-symbol-extractor` agent, the gate runs `grep -F -rn` against every repo discovered by the Phase 0/1 auto-scan — excluding `.git`, `.worktrees`, `.aimi`, `node_modules`, `vendor`, `dist`, `build`, `.next`, `coverage`, `.cache` — classifies each non-doc/non-comment hit by path category (prod / test / migration / other), and records the OQ as resolved with `source: codebaseVerified` and a per-repo `file:line` evidence string. Eliminates the spec-flow-asks-about-already-implemented-code class of friction without round-tripping the user.
- **New `aimi-spec-flow-symbol-extractor` workflow agent.** A single batched extractor spawn per Phase 2.4 invocation receives all sanitized spec-flow OQs and returns a JSON `{anchor: [symbols]}` map naming the candidate symbol(s) implied by each question. Each emitted symbol is constrained to `^[A-Za-z_][A-Za-z0-9_.:-]{5,99}$` and is rejected if shorter than 6 chars or in the stoplist `{id, get, set, User, Service, data, result, error, value, name}` — keeping Phase 2.4 grep targets specific enough to avoid false positives on generic identifiers. Batched so the orchestrator spawns the agent once per phase, not once per OQ.
- **`codebaseVerified` source value on `oqDecisions[]`/`decisions[]` entries.** A ninth allowed value in the `source` enum (joining the existing `specFlow:CriticalQ<n>`, `specFlow:Gap<n>`, `outline`, `scopeNegVerifier`, etc. set), used by Phase 2.4 to mark an OQ as resolved by codebase existence evidence rather than by user answer or research conclusion. Lets downstream `deepen`/`review` distinguish "resolved by what's already shipped" from "resolved by what the user said".
- **Optional `evidence` string field on `oqDecisions[]`/`decisions[]` entries.** A free-form string capturing classified `file:line` hits per repo for OQs resolved through Phase 2.4 (e.g. `prod: apps/web/src/foo.ts:142; test: apps/web/test/foo.spec.ts:18`). Optional everywhere else on the schema — only Phase 2.4 populates it today — so existing decision entries written by other phases remain valid.
- **Three Phase 2.4 failure rows in the `/aimi:plan` Error Handling table.** Covers (a) `grep` invocation failure in a scanned repo (Phase 2.4 records the failure as a per-repo skip, continues with remaining repos, never blocks); (b) malformed `aimi-spec-flow-symbol-extractor` output that fails JSON-shape validation (the gate logs a warning and falls through to user-answered resolution for the affected OQs); (c) extracted symbol rejected by the regex / length / stoplist filter (the gate skips Phase 2.4 for that OQ and falls through to user-answered resolution). All three are non-blocking — Phase 2.4 degrades gracefully back to the pre-existing OQ resolution path.
- **OpenCode translator documentation entry for `aimi-spec-flow-symbol-extractor` (`install.sh`).** The translator's documented agent inventory now lists the new workflow agent alongside the existing `aimi-scope-negative-verifier`, `aimi-cross-story-auditor`, and other Phase-N gate agents, so OpenCode installs ship the same Phase 2.4 capability set as Claude Code.
## [1.98.1] - 2026-06-26

### Fixed

- **OpenCode startup crash on `aimi-migration-dataflow-signals.md`.** `install_agents()` (install.sh) translates `agents/references/migration-dataflow-signals.md` into `~/.config/opencode/agents/aimi-migration-dataflow-signals.md` because the `agents/*/*.md` glob lacks the `references/` exclusion that `install_commands()` enforces. With no frontmatter on the source, `translate_agent` wrote `description: ` (empty), which the YAML parser read as `null`, failing OpenCode's agent schema (`Expected string | undefined, got null description`) and aborting startup. Added a `description` field to the reference so the translated file validates.

## [1.98.0] - 2026-06-10

### Added

- **`AIMI_ROOT` capture + anchored git auto-scan (`plan.md` Step 0 / Phase 1).** Step 0 captures the project root once by walking up to the `.aimi/` marker (the same root the CLI resolves), and the Phase 1 git-repo auto-scan iterates `"$AIMI_ROOT"/*/` instead of the CWD-relative `for dir in */`. A working directory leaked from an earlier Bash call can no longer silently report zero nested repos or break path-within-root validation.
- **Backend-migration scope detection (`plan.md` Phase 0).** The Implementation Scope Detection heuristic gains a backend-migration branch: when the feature combines `migrate`/`migration` with backend/server/API signals and no frontend/UI signals, the frontend-vs-full-stack scope question is skipped and `implementationScope` is left unset (legacy single-file mode).
- **Phase 4.2 cross-story orphan-symbol smell (`aimi-cli.sh story-merge`).** A warning-only post-merge sweep that flags a story whose every extracted symbol (camelCase/PascalCase/snake_case, length ≥ 4, from `implementation.approach`) appears in no other story's text corpus. It is a heuristic over sibling-story prose — **not** codebase dead-code detection — never blocks the merge, and is skipped for single-story merges.
- **New `aimi-scope-negative-verifier` workflow agent + Phase 1.8 Scope-Pruning-Negative Gate (`plan.md`).** When a research conclusion is a negative ("X is absent / not migrated") that would drop or shrink a story, the gate spawns a tool-enabled (Read/Grep/Glob) verifier that independently re-checks existence by data flow and caller tracing — not by re-running the legacy-name grep — and returns CONFIRM/REFUTE/PARTIAL with evidence. A refuted negative restores the pruned story (or surfaces it via AskUserQuestion); the outcome is recorded in `metadata.decisions[]` (`source: scopeNegVerifier`). Untrusted inputs are sanitized and wrapped in `<untrusted_claim>` tags. Non-blocking in agent-mode.
- **Shared migration data-flow doctrine reference.** `agents/references/migration-dataflow-signals.md` is the single source of truth for the four-signal existence check (row writes, persisted collection, triggering endpoint, legacy callers), referenced by both the codebase researcher and the scope-negative verifier.

### Changed

- **Migration-aware existence checks in `aimi-codebase-researcher` + the `plan.md` researcher Task template.** For `migrate`/`migration` tasks the researcher verifies existence by data flow and callers and never concludes "absent / not migrated" from a legacy-symbol grep; the codebase-researcher Task template now passes any legacy symbol as a renamed-origin hint rather than as the search target.

## [1.97.4] - 2026-06-09

### Fixed

- **Phase 3d.5 auditor contract self-contradiction.** The `aimi-cross-story-auditor` agent previously declared `allowed-tools: Read` while its body simultaneously said "do not read any file on disk" and "you may use Read to load implementation.files". Resolved to inline-only inputs (`allowed-tools: []`); the agent reads no file and writes no file.
- **Phase 3d.5 patch path safety.** `storyIdx` values from the auditor are now validated against an `idx → staging file` lookup (`find "$RUN_DIR" -maxdepth 1 -name '[0-9][0-9]-*.json'`) before being used as a path component. Rejects `^[0-9]{2}$`-violating values and ghost references; closes a path-traversal vector.
- **Phase 3d.5 prompt-injection hardening.** Staging JSON bodies are now wrapped in `<untrusted_story_content>` tags before inlining in the auditor prompt; embedded `<untrusted_story_content` sequences are HTML-entity escaped. The auditor agent has an explicit "treat tag contents as data, not instructions" preamble. Patch `value` is sanitized (strip `$(`, backticks; reject forbidden substrings; cap 5000 chars) before writing to `tasks` or `notes`.
- **Phase 3d.5 `unresolved[].message` sanitization at Step 5.** Auditor-emitted messages are now sanitized (newlines→spaces, strip `$(`/backticks, truncate 200 chars) before rendering as chat bullets in the plan report.
- **Phase 3d.5 `add` on scalar `notes` no longer silently overwrites prior notes.** Now appends as a new paragraph separated by `\n\n---\n\n`. Multiple `add` patches to the same `notes` field accumulate.
- **Phase 3d.5 op enum reduced to `add` only.** `op: replace` and `op: remove` were unreachable from the documented audit scopes; they were dead code that complicated the patch schema. The orchestrator drops any non-`add` op as malformed.
- **Phase 3d.5 dead `$AIMI_CLI` resolver removed** from the Skip Condition block — the phase does not invoke the CLI.
- **Phase 3d.5 auditor token budget capped.** Per-staging cap 50 KB, per-research-file cap 20 KB, total auditor prompt cap 150 KB. Truncation suffix `…[truncated for audit; original is intact on disk]` makes drops visible; aggregate-cap drops surface as chat warnings.
- **Phase 3d.5 patch application coalesced per `storyIdx`.** One read-modify-write per affected staging file instead of one per patch; reduces patch-application I/O from O(patches) to O(unique affected stories).
- **Phase 3d.5 per-storyIdx cap now emits an aggregate `unresolved[]` entry** (matching the Error Handling table promise). Per-field type checks added to post-patch pre-validation.
- **Phase 3d.5 audit artifact persisted.** The parsed `{patches, unresolved}` output is written to `<RUN_DIR>/audit-result.json` before patch application so the audit is replayable / inspectable from a captured staging dir.
- **Auditor `_audit` sentinel `storyIdx` documented** in the `unresolved[]` schema (covers Failure Fallback entries and per-storyIdx cap notices).

## [1.97.3] - 2026-06-09

### Added

- Phase 3b outline validator — non-blocking warnings at Phase 3c gate for entries with `summary < 40` chars and entries whose title/summary path-like tokens have no match in the consolidated research `## File References` section. Cap of 10 warning lines with overflow count.
- Phase 3d.5 cross-story DAG audit — new `aimi-cross-story-auditor` workflow agent (Read-only) emits `patches[]` and `unresolved[]`; orchestrator applies allowlisted patches (`dependsOn`, `tasks`, `notes`; max 10 per story) to staging files before story-merge. Skipped when fewer than 2 stories expanded. Auditor failure degrades gracefully — proceeds to story-merge without patches.

## [1.97.2] - 2026-06-03

### Fixed

- `aimi-cli detect-models` in **default mode (no `--research/--review/...` flags)** now preserves the OTHER host's sub-table in `~/.config/aimi/models.json`. Previously the no-flag branch wrote a fresh `{schemaVersion, categories:{<current host>:{...}}}` document via `jq -n`, silently dropping the inactive host's configured models on every invocation. This caused `/aimi:plan`'s automatic resolve to wipe a user's OpenCode model assignments whenever the command ran inside Claude Code (and vice-versa). The fix applies the same merge pattern the flag-mode branch already uses (read existing config → merge by `host_key`). Regression test added: `test_detect_models_default_mode_preserves_other_host`.

## [1.97.1] - 2026-06-03

### Added

- **Console error attribution in post-merge visual verification.** `/aimi:execute` now captures `agent-browser console --json` and `agent-browser errors --json` after every per-story screenshot in a visual wave, and runs an `attribute_console_errors()` pass that links each error/warning back to the wave story most likely to have caused it. Attribution strategies: (a) stack-trace file match against `implementation.files[]`, (b) PascalCase component-name match in error text, (c) wave-shared fallback when neither matches. Output goes into a `## Console (advisory)` section in the wave summary alongside the existing `## Design Review` block. Advisory only — never changes `verification.status`, never blocks the wave.
- Per-story `agent-browser console --clear` before each `open` so the console buffer is per-story, not wave-cumulative. Without this, attribution would silently blame the last-merged story for every prior story's errors.

### Notes

- Requires `agent-browser` ≥ 0.25.x (the version exposing `console` and `errors` subcommands — undocumented in `--help` but present and stable; verified against 0.25.3).
- Multi-`/aimi:execute` runs in parallel that share `--session visual-follow` will see cross-run console contamination (upstream issue `vercel-labs/agent-browser#326`). Workaround: each run uses a unique session name. Not applied here because single-user-single-run is the common case.

## [1.97.0] - 2026-06-03

### Added

- **Structured `<result_json>` contract for story-executor workers.** Workers MUST end their final message with a `<result_json>` block carrying `{status, commit, tests?, typecheck?, knownGaps?, deviations?, failureCause?}`. The orchestrator parses this block as source of truth — prose outside is debugging only.
- `execute.md` wave loop parses `<result_json>` from each worker tool_result: status drives the success/fail branch; `commit` is cross-checked against `git rev-parse HEAD` in the worktree; `failureCause` is surfaced verbatim to the user via `mark-failed`; `knownGaps` is preferred over the legacy `KNOWN-GAP:` commit-trailer grep.

### Changed

- `story-executor` SKILL.md `<execution_flow>` (full + compact templates) and Failure Handling now end on the explicit instruction to emit the `<result_json>` block. The Checklist gains a new line to lock the contract in.

### Rationale

- Measured 5 most-recent `/aimi:execute` worker runs from `Feats/migration`: average **680 result tokens** emitted per worker, of which **~0.8% reused verbatim** by the orchestrator (≈50-200 tokens of structured signal actually consumed). The contract shrinks the consumed payload toward ~120 tokens per worker — ~82% reduction on the orchestrator's next-turn input cost.

### Compatibility

- Workers that DO NOT emit `<result_json>` (legacy) fall back to the existing behavior: Task's own success/failure exit signal + commit verification. No worker is forced to update immediately. New workers MUST emit the block.

## [1.96.2] - 2026-06-03

### Fixed

- `aimi-cli story-merge` no longer attempts to merge the `outline.json` sidecar (written by `plan.md` Phase 3b) as if it were a story. The previous glob in `cmd_story_merge` picked up every `*.json` in the staging directory, including the outline sidecar; the sidecar's shape (a list of `{idx, title, summary}` entries) tripped jq later in Rule 22 / Phase 3.1 / Phase 4.1 with `null (null) has no keys`, aborting the entire merge. The fix filters `outline.json`, any `*outline*.json`, and `metadata.json` from the staging glob before processing. Added test TC9 to lock in the behaviour.

## [1.96.1] - 2026-06-01

### Fixed

- Added missing `aimi-story-expander` workflow agent referenced by `/aimi:plan` Phase 3d. The 1.96.0 plan.md rewrite invoked `subagent_type="aimi-engineering:workflow:aimi-story-expander"` but the corresponding agent file was never authored, causing the orchestrator to fall back to authoring staging JSON inline on every run (defeating the point of parallel Pass 2 expansion). The agent receives one outline entry plus full context (outline, research, decisions, optional specs) and writes one staging JSON file using `outline:NN` dependsOn tokens that `story-merge` later remaps.

## [1.96.0] - 2026-06-01

### Added

- `aimi-cli story-merge` subcommand: consolidates per-story staging files into a validated `tasks.json` with deterministic `US-NNN` ID assignment, DAG cycle detection, wave computation, Rule 22 mock-sync AC routing, Phase 3.1 inventory verdict check, Phase 4.1 coverage ratio check, and atomic `flock`-protected write. Supports `--split full-stack` for paired frontend/backend output and `--agent-mode` to demote hard rejects to warnings in CI.
- `/aimi:plan` outline gate: between Pass 1 outline generation and Pass 2 expansion, the user can approve / rename / add / remove / reorder stories via iterative `AskUserQuestion` pickers. Edits are recorded in `metadata.decisions[]` with new anchor format `outline:edit:<idx>` and `source: "outline"`.
- `/aimi:plan` Pass 2 parallel expansion: each outline entry expands in its own Task sub-agent with `outline:NN` dependsOn tokens; story-merge remaps tokens to final `US-NNN`. Schema-validation failures trigger up to 2 retries with sanitized validator error injected into the next prompt (`$(`, backticks, newlines stripped; truncated to 500 chars).
- `--non-interactive` outline auto-approve: emits `[plan] outline auto-approved (non-interactive): N stories` log line.

### Changed

- `/aimi:plan` Phase 3 + Phase 4 replaced with a two-pass outline+expand pipeline (Pass 1 outline → outline gate → Pass 2 fan-out → `story-merge` deterministic merge). Drop-in: schema of `tasks.json` is unchanged; `/aimi:execute`, `/aimi:status`, `/aimi:deepen` consumers unaffected.
- `metadata.decisions[]` accepts new `source` value `outline` for outline-gate edits (additive; no schema version bump).
- Rule 22 mock-sync AC routing, Phase 3.1 Reference Element Inventory, and Phase 4.1 Coverage Self-Check now execute inside `story-merge` instead of inline in plan.md Phase 3.

### Security

- Pass 2 retry prompt sanitization: validator error strings are stripped of `$(`, backticks, and newlines, then truncated to 500 chars before injection into retry prompts — prevents shell-expansion and prompt-injection vectors from poisoning auto-correction context.
- Staging-path validation: outline-title slug sanitization rejects `..` traversal, `/` characters, and leading dots before staging file paths are constructed. Per-run staging subdirectory `.aimi/.tasks-staging/<topic-slug>-<RUN_TS>/` isolates each run.

## [1.95.1] — 2026-05-28

### Fixed

- `aimi-cli.sh` — `write_global_cli_cache` no longer persists an ephemeral git-worktree path to the global cache (`~/.config/aimi/cli-path`). When `init-session` ran from a `.worktrees/` checkout (e.g. `test-aimi-cli.sh` inside a worktree, or an `/aimi:execute` wave), the worktree-local `aimi-cli.sh` path was cached globally; after the worktree was removed during merge cleanup, every later command resolved `$AIMI_CLI` to a deleted file and failed with exit 127. The write now no-ops on any path containing a `.worktrees/` segment.

## [1.95.0] — 2026-05-28

### Added

- `research-lookup <path>` CLI subcommand — content-aware freshness check for research `.md` files. Compares the research file's mtime against the newest mtime of all source paths listed under its `## File References` h2 bullet section. Prints the resolved path and exits 0 when fresh; prints nothing and exits 1 (stale) when any cited source is newer, missing, or outside the project root. Consumed by `plan` and `deepen` before spawning researchers.
- `research-gc` CLI subcommand — prunes orphaned `.aimi/research/*.md` files older than 30 days that are not referenced by any active `.aimi/tasks/*.json` `metadata.researchPaths` or any `.aimi/brainstorms/*.md` frontmatter `researchPaths`. Called opportunistically (once per session) from `plan` and `deepen` to prevent unbounded accumulation. Silent when nothing is removed.

### Changed

- `plan` / `brainstorm` — reusedResearch map generalized from a flat lookup to a `{kind → path}` map covering all four research kinds (`codebase`, `learnings`, `best-practices`, `framework-docs`). Both commands now populate `metadata.researchPaths` on the tasks.json after writing, closing the orphan gap that previously left per-run research files untracked.
- `deepen` Step 3 reuse-gate — before spawning per-story researchers, deepen now checks `research-lookup` freshness on any existing per-story research file. A fresh hit skips the re-research spawn entirely; a stale or missing file triggers a targeted researcher with `--paths` narrowed to `story.implementation.files`.
- Research agents (`aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`) — output a pointer block (`{outputPath, researchKind, sourcePaths[]}`) instead of restating a summary in the agent response. Callers resolve the actual content from disk via the pointer; reduces orchestrator working-memory and eliminates cross-agent summary drift.

## [1.94.1] — 2026-05-28

### Changed

- `story-executor/SKILL.md` — both the full and compact execution-flow templates now explicitly direct the spawned agent to follow `story.tasks[]` as the ordered implementation recipe when present, with special attention to `"Wire <X> into <Y>"` entries that encode cross-story file wiring. `acceptanceCriteria` remains the completion gate; `tasks[]` is planner guidance. Closes the planner→executor wiring gap where the planner was required to enumerate cross-story integration steps but the executor template never instructed the agent to walk them.

## [1.94.0] — 2026-05-28

### Added

- `get-story-context` CLI command now emits two new top-level keys alongside `story` and `metadata`:
  - `skills` — array of `{name, path, content}` objects assembled from each story's `skills[]` declarations, with tag-breakout escapes (`</required_skills` → `&lt;`) and a 100 KB aggregate cap that drops in reverse-of-insertion order.
  - `designContext` — `{decisions, bundleGuidance}` sourced from `metadata.brainstormPath` and `metadata.designBundle`, respectively. Wires the previously orphaned `[DESIGN_BUNDLE_CONTEXT]` placeholder in `story-executor/SKILL.md` for the first time.
- New internal helper `_resolve_skills_base_dir` in `aimi-cli.sh` mirroring execute.md's prior `SKILLS_BASE_DIR` resolution (Claude Code cache glob; OpenCode plugin dir; silent fallback to empty skills array).
- Four new tests covering the extended `get-story-context`: skills present, skills absent, 100 KB cap drop, designContext extraction.

### Changed

- `story-executor/SKILL.md` (both full and compact templates) — removed the inlined `<required_skills>`, `[DESIGN_CONTEXT]`, and `<design_bundle_context>` blocks. Workers now consume that material from the extended `get-story-context` JSON. Bootstrap step 0a updated accordingly.
- `commands/execute.md` — deleted the wave-loop skill-assembly logic, the Step 3.4 design-context build, the Step 3.6 `SKILLS_BASE_DIR` resolution, and the `REQUIRED_SKILLS` / `DESIGN_CONTEXT` / `DESIGN_BUNDLE_CONTEXT` spawn variables. The orchestrator's working memory per wave is correspondingly smaller.

## [1.93.2] - 2026-05-25

### Changed

- First-run dismissal marker is now **per-host**. The marker file path is `~/.config/aimi/models-prompt-seen-claudeCode` or `~/.config/aimi/models-prompt-seen-opencode` depending on the active host. Picking "Manter o padrão (inherit)" on one host no longer silences the prompt on the other — each host's dismissal is independent. The legacy global marker at `~/.config/aimi/models-prompt-seen` is no longer read; existing users may see one extra prompt after upgrade (on each host where they had dismissed without configuring) and will not see it again after dismissing or configuring on that host.
- `aimi-cli models-prompt-check` now honors the per-host marker as a tie-breaker: when the config file is present but the current host has no configured categories, `skip` is returned if the host's marker exists (explicit dismissal preserved), `prompt` otherwise. The file-missing branch still re-prompts regardless of any marker — the v1.93.0 behavior (deleting `models.json` always re-triggers the prompt) is preserved.
- `aimi-cli models-prompt-dismiss` writes the per-host marker for the active host. Idempotent. Other host's marker is not touched.

## [1.93.1] - 2026-05-25

### Changed

- `aimi-cli models-prompt-check` now decides on the **current host's** configured categories rather than mere file existence. Previously the check returned `skip` whenever `~/.config/aimi/models.json` existed, even if the current host's `categories.<host>` sub-table was missing or empty — which silently left users on all-inherit when they ran a command on a host they had never configured (e.g., opened Claude Code after only configuring OpenCode). Now `prompt` is returned when `get-current-models` would emit all-null for the active host (no category configured, host key absent, host key with empty `{}`, or all category values explicitly null). `skip` requires at least one category for the current host to carry a non-null model id. Schema v1.0 configs are treated as unconfigured (prompt). Empty/malformed files also prompt instead of skipping silently.

## [1.93.0] - 2026-05-25

### Added

- `/aimi:setup-models` slash command for interactive (re)configuration of per-category model assignments at any time. Shows current values for the active host (claudeCode or opencode), then runs the same five-question picker used by the first-run prompt — with current values pre-selected as defaults so the common "tweak one category" workflow takes one keystroke per question. The picker question text is identical to the first-run prompt (Portuguese, per the existing localisation). Writes via `aimi-cli detect-models`, which validates each model id against the host's available-model list and preserves the other host's `categories.<host>` sub-table on merge.
- `aimi-cli get-current-models` subcommand emitting current per-category model assignments for the active host as a JSON object with keys `research`, `review`, `design`, `workflow`, `executor`. Unset entries emit JSON null (not the literal `"inherit"` returned by `resolve-models`) so picker UIs can distinguish "not configured" from an explicit `"inherit"` override and pre-select sensible defaults. Schema v1.0 configs rejected identically to `resolve-models` (stderr warning, all-null on stdout).

### Fixed

- `aimi-cli models-prompt-check` now returns `prompt` whenever `~/.config/aimi/models.json` is missing, regardless of whether the `~/.config/aimi/models-prompt-seen` marker file exists. Previously the marker file suppressed the prompt even after the config was deleted, leaving the user silently stuck on all-inherit defaults with no way to re-trigger the prompt short of also deleting the marker. The marker is no longer read; `models-prompt-dismiss` still writes the marker for backward compatibility with callers in `install.sh` and `cli-path-resolution.md`, but the marker now has no effect on the check.

## [1.92.1] - 2026-05-25

### Fixed

- OpenCode translation: `install.sh` now physically rewrites `Task subagent_type="aimi-engineering:CATEGORY:NAME"` invocations in command bodies to `aimi-task subagent_type="aimi-engineering:CATEGORY:NAME"`. Previously the OpenCode preamble instructed the LLM to perform this rewrite at call time, but the orchestrator sometimes ignored it and called OpenCode's native `task` tool with the plugin-namespaced string — OpenCode rejected the call with `Unknown agent type: aimi-engineering:...` because only flat agent names are registered on the OpenCode side. The body rewrite eliminates that class of error for all 25 namespaced invocations across `/aimi:plan`, `/aimi:brainstorm`, `/aimi:deepen`, `/aimi:review`, `/aimi:design:polish`, and `/aimi:validate-bug`.
- OpenCode preamble Step 1 reworded: now describes per-spawn model selection only (the body uses `aimi-task` directly) and adds a hard prohibition against ever calling the native `task` tool with `aimi-engineering:*` subagent types — covering the remaining rare multi-line `Task(...)` form in `/aimi:execute`'s design-review block which is not eligible for the body rewrite.

## [1.92.0] - 2026-05-25

### Changed

- `models.json` schema migrated from `1.0` to `2.0`. The two-level tier indirection (`categories.<cat> → tier`, `models.<host>.<tier> → modelId`) is replaced with direct one-level mapping (`categories.<host>.<cat> → modelId`). The top-level `.models` key is removed. Five categories are honored: `research`, `review`, `design`, `workflow`, `executor`.
- `aimi-cli detect-models` flag set renamed: the three-tier flags `--fast` / `--balanced` / `--powerful` (all-or-nothing) are replaced with five per-category flags `--research` / `--review` / `--design` / `--workflow` / `--executor` (all five required when any is provided). The interactive picker (TTY and first-run prompt) now asks five per-category questions instead of three per-tier questions.
- First-run prompt documentation in `commands/references/cli-path-resolution.md` and the mirrored block in `install.sh` updated to describe the five-question per-category flow.

### Breaking

- Existing v1.0 configs at `~/.config/aimi/models.json` are no longer honored. `aimi-cli resolve-models` detects v1.0 (presence of top-level `.models` key or `schemaVersion` other than `"2.0"`), emits a stderr warning containing `schema 1.0`, and falls back to all-inherit until the file is regenerated.
- Action required after upgrade: re-run `aimi-cli detect-models` (interactive) or `aimi-cli detect-models --research <id> --review <id> --design <id> --workflow <id> --executor <id>` (flag mode) on each host (`claudeCode` and `opencode`) to write the v2.0 file. The writer preserves the other host's `categories.<host>` sub-table on merge.

## [1.91.0] - 2026-05-25

### Added

- New `executor` agent category for sub-orchestrator spawns. `/aimi:execute` now resolves an `EXECUTOR_MODEL` and annotates `model: <AGENT_MODELS.executor when not "inherit">` on the three `general-purpose` Task spawns (parallel frontend/backend sub-orchestrators and per-story executor). Default tier mapping is `executor=balanced`. Users can override per-tier via `~/.config/aimi/models.json` or via the first-run picker (the `balanced` tier already covered design/workflow; executor now also maps to it by default).
- `resolve-models` output now includes the `executor` key alongside `research`, `review`, `design`, `workflow` (five keys total). Unconfigured executor entries fall back to the literal `"inherit"`.
- OpenCode translation: `install.sh` extracts `EXECUTOR_MODEL` from `resolve-models` and routes `Task(subagent_type="general", model: ...)` spawns through `aimi-task` so the per-call model is honored on OpenCode too. Untyped general-purpose spawns (no `model:` annotation) remain native.

### Added

- `aimi-cli resolve-models` — reads `~/.config/aimi/models.json` and resolves the configured model id for each agent category (`research`, `review`, `design`, `workflow`). Always emits all four category keys; uses the sentinel `inherit` when no override is configured so commands can pass it through without special-casing.
- `aimi-cli detect-models` — interactive generator for the host-aware `~/.config/aimi/models.json` config. When stdin is a TTY, prompts per category; otherwise writes a sensible default mapping. Falls back to a built-in Anthropic default list when the `opencode` binary is not on PATH.
- `~/.config/aimi/models.json` host-aware config: a `categories` map (category name → logical tier) plus a per-host `models` table (`claudeCode` and `opencode`) resolving tiers to concrete model ids. Includes a `schemaVersion` field following the `tasks.json` precedent.
- Per-spawn model selection wired into the planning/research and review/execution commands (`/aimi:plan`, `/aimi:brainstorm`, `/aimi:deepen`, `/aimi:review`, `/aimi:design:polish`, `/aimi:validate-bug`, `/aimi:execute`). On Claude Code, resolved model ids are passed via the native `Task` tool `model:` parameter; the sentinel `inherit` leaves the model at host default.
- `tools/aimi-task.ts` — OpenCode custom tool (TypeScript, loaded by the Bun runtime) that spawns subagents with an explicit `model` parameter, giving OpenCode per-spawn model selection parity with Claude Code. `install.sh` copies the tool and its `tools/package.json` companion into the OpenCode config directory and registers it in `opencode.json`. The tool regex-validates the model id before any shell-out.
- One-time first-run prompt to configure model selection: when no `models.json` exists and no prior dismissal marker is present, commands show a single `AskUserQuestion` offering to configure model selection now or keep the default "inherit" behavior. The prompt is shown at most once (gated on interactive / picker mode only) and permanently suppressed after the user responds via `aimi-cli models-prompt-dismiss`. Two new `aimi-cli` subcommands support this: `models-prompt-check` (echoes `prompt` or `skip`) and `models-prompt-dismiss` (atomically writes `~/.config/aimi/models-prompt-seen`).
- `aimi-cli list-models` — lists available models for the current host as a JSON array on stdout. Claude Code returns `["opus","sonnet","haiku"]`; OpenCode reads `opencode models` and falls back to the built-in Anthropic default list when the binary is absent. Used by the first-run flow so the LLM orchestrator can present real model options to the user.
- `aimi-cli detect-models --fast <model> --balanced <model> --powerful <model>` — new non-interactive tier-flag mode: when all three flags are provided, writes `models.json` with the given tier-to-model assignments and the default category mapping (research=fast, design=balanced, workflow=balanced, review=powerful). Preserves the other host's `models` sub-table when a file already exists. The existing interactive / default-write path is unchanged.

### Changed

- First-run "Configurar agora" flow: model selection now happens at the LLM-orchestrator layer via `AskUserQuestion` (Claude Code) / the `question` tool (OpenCode) with three questions — one per tier (fast / balanced / powerful) — using the model list from `list-models` as picker options. The orchestrator then calls `detect-models --fast … --balanced … --powerful …` with the chosen values. Previously the flow delegated to `detect-models` in a subprocess which could never prompt interactively inside a Bash tool call.

## [1.89.0] - 2026-05-21

### Added

- `--non-interactive` flag for `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish`. Pass `--non-interactive` to skip all interactive prompts and auto-defer every Open Question (agent/CI mode). Interactive (`picker`) mode is now the default for all three commands.

### Changed

- `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish` default to **interactive mode** (`INTERACTIVE_MODE=picker`). Previously these commands could silently fall through to `agent` mode when running in a non-TTY shell (e.g. inside OpenCode's bash tool calls), suppressing all user-facing questions. The bare-TTY fallback in `detect-interactivity` has been removed so a hostless non-TTY shell no longer triggers agent mode.
- `cmd_detect_interactivity` in `aimi-cli.sh` now returns `picker` as the default. Agent mode is reached only through explicit opt-out: `--non-interactive` flag, `AIMI_AGENT_MODE=true`, or `CI=true`.

### Fixed

- OpenCode agent-mode misclassification: `detect-interactivity` previously returned `agent` for OpenCode sessions because OpenCode runs bash tool calls in a non-TTY shell and does not export `OPENCODE_CONFIG_DIR` in that context, causing the TTY fallback (step 6) to fire. Removing the bare-TTY fallback ensures the command correctly defaults to `picker` on OpenCode.

## [1.88.0] - 2026-05-21

### Removed

- `aimi-every-style-editor` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-ankane-readme-writer` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-lint` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-pr-comment-resolver` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-figma-design-sync` agent — out-of-scope / orphaned; no active command consumer.

### Added

- `/aimi:validate-bug` command (`commands/validate-bug.md`): reproduces and validates bug reports by delegating to the `aimi-bug-reproduction-validator` agent. Accepts a free-form bug description, runs a structured reproduction workflow, and reports whether the bug is confirmed, cannot be reproduced, or is a user error.

### Changed

- `aimi-bug-reproduction-validator` agent generalized: Rails-specific bias removed from its Investigation Techniques section so the agent operates effectively across all languages and frameworks.
- `/aimi:design:polish` now optionally delegates to `aimi-design-iterator` for a multi-cycle visual iteration pass (screenshot → analyze → improve loop) in addition to the existing inline polish workflow.

## [1.87.1] - 2026-05-20

### Fixed
- `cmd_update_field` was dropping the final segment of a dotted path (e.g., `verification.status` built `.verification` instead of `.verification.status`) because `printf '%s' | sed | while read -r` skips the loop body for the last unterminated segment. Replaced the pipe chain with an `IFS=. read -ra` herestring split that is trailing-newline-safe, so `update-field US-NNN verification.status passed` now patches only the leaf field and preserves all sibling fields on the parent object.

## [1.87.0] - 2026-05-15

### Added
- XDG-compliant cache location at `~/.config/aimi/cli-path` and `~/.config/aimi/worktree-path` for storing the resolved CLI and worktree paths. The location can be overridden via the new `AIMI_CONFIG_DIR` environment variable (e.g., `AIMI_CONFIG_DIR=/custom/path`), which governs cache file placement only — Layer 2 plugin discovery continues to use `CLAUDE_CONFIG_DIR`.
- New `_aimi_config_dir()` helper in `aimi-cli.sh` encapsulates the `AIMI_CONFIG_DIR`-or-XDG-default resolution, making all cache read/write call sites consistent.
- "Per-Call Resolution" section in `commands/references/cli-path-resolution.md` documenting the shell-isolation hazard and the required per-call `cat` re-read pattern with explicit precondition (Step 0 full resolution must have run first to prime the new path).

### Changed
- `plan.md`, `execute.md`, `brainstorm.md`, `skills/story-executor/SKILL.md`, and `skills/task-planner/SKILL.md` migrated to per-call CLI re-read: each Bash call that needs `$AIMI_CLI` now resolves it inline via `cat ~/.config/aimi/cli-path` rather than relying on a shell variable from a prior call.
- `auto-approve-cli.sh` hook updated to recognize the new XDG paths (`~/.config/aimi/cli-path`, `~/.config/aimi/worktree-path`) alongside the legacy `~/.claude/aimi-engineering-{cli,worktree}-path` paths, so CLI cache reads and writes do not trigger unexpected permission prompts during the migration window.
- Hard-coded legacy `~/.claude/aimi-engineering-cli-path` references in `commands/init.md`, `CLAUDE.md`, `install.sh`, and `settings.local.json` updated to reflect the new XDG location.

### Fixed
- Shell-isolation hazard where `$AIMI_CLI` resolved correctly in one Bash call but expanded to empty in every subsequent call (each Claude Code Bash invocation runs in an isolated subshell), causing silent "command not found: `<subcommand>`" failures throughout plan, execute, and brainstorm workflows.

### Compatibility
- Legacy `~/.claude/aimi-engineering-cli-path` and `~/.claude/aimi-engineering-worktree-path` files remain supported via a read-both fallback: `aimi-cli.sh` tries the new XDG location first and falls back to the legacy path if the new file is absent. **No user action is required.** The legacy read-both fallback is planned for removal in the next MAJOR version bump.

## [1.86.7] - 2026-05-13

### Changed
- Trimmed the Pre-Save Checklist in `brainstorm.md` Phase 4 by removing the eight items marked `(advisory/non-blocking)` that restate rules already enforced in the document body (Design Decisions section presence, Personas/View Modes/Layout Variation subsections, Specs and Prototypes section presence, generated-bundle YAML key ordering, researchPaths emission). Added a one-line preamble directing readers to the body rules as the source of truth. The Pre-Save Blocking Gate — Open Questions section (with `[resolved: ...]` / `[deferred: ...]` sentinels, bundle-source clarification, and agent-mode auto-defer fallback) is preserved verbatim. Behavior unchanged.

## [1.86.6] - 2026-05-13

### Changed
- Consolidated the `AIMI_ROOT_IS_GIT_REPO` branching rule, the per-story project-grouping pattern (absolute-path resolution, path-validation regex, no-leading-./, no-.. rules), and the per-project cleanup rule into one "Multi-Repo Handling" section at the top of `execute.md` (placed between Step 0 and Step 0.5). Each call site now carries a one-line pointer to the section while keeping the decision pseudocode inline — no per-run Read cost. The wave-loop group_key/project_roots/base_sha/all_worktrees pseudocode, setup-branch invocations, PROJECT_GUIDELINES_MAP build, merge-per-project logic, and cleanup iteration are all preserved verbatim.

## [1.86.5] - 2026-05-13

### Changed
- Folded the four near-identical inline "check flag → emit once → set true" blocks for `echoedBundleEarlyExit`, `echoedBrowserUnavailable`, `echoedSessionLost`, and `echoedPickerUnavailable` in `brainstorm.md` into one "Once-per-session echo helper" rule documented near Step 0b. Each call site now invokes the helper with its flag name and message. Flag names, message texts, working-memory initialization, and surrounding contextual prose are preserved verbatim.

## [1.86.4] - 2026-05-13

### Changed
- Consolidated the visual-follow lifecycle (detection, session-open, reuse-within-wave, keep-open-on-completion) from the four scattered sites in `execute.md` (Step 0.7, Step 3.3, Step 4 wave loop, Post-Loop) into one "Visual Follow Lifecycle" section placed before Step 0.7. Each call site now points at the consolidated section. Behavior preserved verbatim — MALFORMED_VERIF abort, per-story screenshot+compare logic, session name `visual-follow`, and the "Visual follow session still open" completion message all remain inline at their original sites.

## [1.86.3] - 2026-05-13

### Changed
- Collapsed the three near-identical "How `<flag>` works at runtime" subsections in `brainstorm.md` Override Keywords section (`show variants`, `vary ui`, `render bundle`) into one parameterized rule table (columns: trigger phrase, flag name, activation log line, scope/clear condition, precedence over Step 0a) and a single co-occurrence statement covering all pairwise and triple-overlap semantics. The user-facing summary table is preserved verbatim. Behavior unchanged — every flag name, log line, scope, clear condition, and precedence-over-Step-0a rule is identical.

## [1.86.2] - 2026-05-13

### Changed
- Extracted input-sanitization rules and topic-slug derivation algorithm from `brainstorm.md` and `execute.md` into `commands/references/sanitization.md` and `commands/references/topic-slug.md`. Both commands now cite the new reference files instead of restating the rules inline, eliminating the stale line-number citation in `execute.md` Step 3.4. Behavior is preserved verbatim — pure prose deduplication.

## [1.86.1] - 2026-05-13

### Fixed
- `detect-interactivity` no longer returns `agent` inside Claude Code or OpenCode when stdin is not a TTY. Both hosts run command bash bodies in non-TTY subshells, so the previous `[ ! -t 0 ]` check misclassified every interactive session as agent mode — causing Phase 0.5 / Phase 1.8 / Phase 2.5 OQ gates in `/aimi:plan` to silently auto-defer every open question instead of prompting the user. The check now treats `CLAUDECODE=1` and a set `OPENCODE_CONFIG_DIR` as picker-available regardless of TTY state. `AIMI_AGENT_MODE=true` and `CI=true` still force agent mode as before.

## [1.86.0] - 2026-05-13

### Added
- Phase 1.8 (Post-Research Open Questions Gate) in /aimi:plan — surfaces every researcher's `## Open Questions` and `[PROMOTE-TO-OPEN-QUESTIONS]` entries via AskUserQuestion before story decomposition; auto-defers under AIMI_AGENT_MODE.
- Phase 2.5 (Spec-Flow Gap Gate) in /aimi:plan — surfaces the spec-flow analyzer's `### Missing Elements & Gaps` and `### Critical Questions Requiring Clarification` entries before story decomposition; auto-defers under AIMI_AGENT_MODE.

### Changed
- metadata.decisions[].source schema extended with three new forms: `researchFile:<basename>:OQ<n>`, `specFlow:CriticalQ<n>`, `specFlow:Gap<n>`.

## [1.85.0] - 2026-05-12

### Changed
- Subagent spawn prompts now use pointer-only context handoff: each spawned agent receives only the story ID in a `task_pointer` block and fetches its full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action, keeping the orchestrator's working memory slim across waves and eliminating inlined story bodies and prototype HTML from spawn prompts.
- New `get-story-context` CLI subcommand added to `aimi-cli.sh`: given a story ID, emits the full story JSON (including acceptance criteria, implementation block, verification, and gate fields) so subagents can self-bootstrap without relying on orchestrator-inlined payloads.

## [1.84.0] - 2026-05-12

### Added
- `normalize-verification` CLI subcommand: rewrites bare-string verification fields into the object form `{strategy, status, url, expect}` with atomic tmp+mv write.
- Visual Source-of-Truth Protocol (V1/V2/V3) in story-executor SKILL.md: pre-implementation enumeration rail for visual stories, gated on `verification.strategy == "visual"` or non-empty PROTOTYPE_CONTEXT.
- Per-element PASS/DIVERGES/KNOWN-GAP table requirement in the Reference-Artifact Parity Pass (visual stories only).
- `KNOWN-GAP:` trailer persistence: execute.md captures trailers from worker commits into `.aimi/known-gaps/YYYY-MM-DD-<storyId>.md` and aggregates them in the Step 5 final report under `## Known Gaps`.
- Auto-spawned `aimi-design-implementation-reviewer` after each visual story merges; review output captured in the Step 5 final report under `## Design Review`.

### Changed
- `validate-stories` now rejects any story whose `verification` is a bare string (must be an object with a `strategy` key).
- `/aimi:plan` Phase 4.5 invokes `normalize-verification` before validators, auto-migrating planner-emitted string verifications in place.
- `/aimi:execute` Step 0.7 now aborts (non-zero exit) on malformed verifications instead of warning and continuing; abort message lists offending story IDs and points at `normalize-verification` for remediation.
- Gap-trailer token renamed from `KNOWN GAP:` (with space) to `KNOWN-GAP:` (hyphenated) in story-executor SKILL.md and the verdict-table label, enabling clean `grep -E '^KNOWN-GAP:'` parsing.

## [1.83.0] - 2026-05-12

### Added
- `/aimi:plan` Phase 0.5 now scans BusinessSpec/DesignSpec content for marker-style Open Questions (`[a confirmar]`, `[TBD]`, `[to confirm]`, `[to be confirmed]`, `[to be defined]`) and surfaces each via AskUserQuestion with source+anchor. Spec-marker resolutions are recorded in working-memory `oqDecisions[]` only; spec files are never written back to. Aggregate cap of 20 entries.
- `/aimi:plan` Phase 1 now spawns `aimi-design-bundle-researcher` when invoked directly against a Claude Design handoff bundle (no prior brainstorm). Restores parity with the brainstorm-to-plan flow; resulting Open Questions merge into the Phase 0.5 list before continuing to Phase 1.5.

### Fixed
- `aimi-cli detect-design-bundle` now uses case-insensitive `find -iname` for spec file discovery, so bundles with camelCase filenames (`businessSpec.md`, `designSpec.md`) are detected correctly. Returned paths preserve actual on-disk casing.

### Changed
- Schema v3.3 documentation in `plan.md` now includes a `responseShape contract (frontend-only mode)` block explaining the flat-key constraint and why dotted keys like `portfolio.totalUsinas` are rejected by `validate-tasks`.

## [1.82.0] - 2026-05-12

### Added

- **Plan command: Phase 3.1 Reference Element Inventory (BLOCKING when triggered):** New `### Phase 3.1: Reference Element Inventory (BLOCKING when triggered)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 3 section, before `dependsOn` Inference Rules). When any story declares a reference artifact (`prototypeAnchor`, `specSection`, `referenceCommand`, `referenceFixture`, `migrationDiff`, `referenceUrl`, etc.), opens the artifact and enumerates every addressable element in the cited region using kind-specific vocabulary (HTML/UI, OpenAPI/JSON Schema, CLI man page, SQL/migration diff, business rules table). Records findings as an `Element | Locator | Verdict | AC anchor` table; every row must be marked `encoded` or `excluded` with a written reason before story JSON is emitted. Block Phase 4 until all rows are verdicted; agent-mode fallback auto-marks unverdicted rows as `deferred`. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Phase 4.1 Coverage Self-Check (BLOCKING):** New `### Phase 4.1: Coverage Self-Check (BLOCKING)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 4 Derive Metadata section, before Write File). For each story with a Phase 3.1 inventory, computes `ac_anchors / proto_elements` ratio; if `ac_anchors < floor(proto_elements * 0.6)`, returns to Phase 3.1 to add AC lines or upgrade rows to `excluded`. Blocks Write File until the ratio is satisfied for every affected story; agent-mode fallback emits a structured deficit warning and proceeds. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Anti-Citation-Bias Reminder:** New `### Anti-Citation-Bias Reminder` block inserted into `plugins/aimi-engineering/commands/plan.md` (after Schema v3.3 Structure, before Checklist Before Writing). Clarifies that the validator only enforces citation format — not completeness, compositional fidelity, or behavioral coverage. Explicitly requires encoding of behavioral obligations and edge cases even without quotable literals, and recommends chaining citations for compositional obligations. Not labeled BLOCKING (worldview reminder, not a gate).
- **Researcher agents: `## Contracts` quoting requirement:** New `## Contracts` section inserted into both `plugins/aimi-engineering/agents/research/aimi-codebase-researcher.md` and `plugins/aimi-engineering/agents/research/aimi-framework-docs-researcher.md`. Requires verbatim quoting of every consumed contract (typed signatures, REST/RPC shapes, CLI flag lists, DB schema, SDK public APIs) into the research file body with `file:line` citation — one fenced block per contract, no invention or inference of shapes.
- **Story executor: Reference-Artifact Parity Pass (BLOCKING when triggered):** New `## Reference-Artifact Parity Pass (BLOCKING when triggered)` named section inserted into `plugins/aimi-engineering/skills/story-executor/SKILL.md` (before Prompt Template). Fires when a story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Procedure: load reference → enumerate addressable elements in cited region → cross-check against implementation → per-element verdict (`Implemented` or `KNOWN GAP: <element> — <reason>` appended to commit body). Silent drops are not acceptable. Blocks commit until every element has a verdict; agent-mode fallback logs `Parity pass skipped — reference not readable: <path>` and proceeds. Also added as step 3.5 in the canonical prompt template `<execution_flow>` and as a one-sentence extension to the compact template `<execution_flow>`.

### Changed

- **Plan command: Phase 1.7 Research File Ingestion trigger extended to `quick` tier:** The `## Phase 1.7: Research File Ingestion` trigger in `plugins/aimi-engineering/commands/plan.md` now fires for `researchDepth` `quick`, `standard`, or `deep` (previously `standard` or `deep` only). The no-op case shrinks to `skip` or unset. Mirrored in `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.81.0] - 2026-05-12

### Added

- **Plan command: Phase 1.7 Research File Ingestion (US-001):** New `## Phase 1.7: Research File Ingestion` section inserted between Phase 1.6 and Phase 2 in `plugins/aimi-engineering/commands/plan.md`. When `researchDepth` is `standard` or `deep`, reads the full on-disk content of every path in `metadata.researchPaths`, deduped against `reusedCodebasePath` and `reusedBestPracticesPath` (already loaded by Phase 1.6). Missing files are silently skipped; no per-file or aggregate size cap is applied. Each loaded file is wrapped as `<research_file path="...">` with light HTML-entity escape on literal wrapper-tag sequences (analogous to the `prototype_html` escape pattern). Collected blocks are stored in `researchFileBlocks` and threaded into Phase 3 alongside `prototypeBlocks` so acceptance-criteria authoring draws on complete on-disk research detail rather than capped summary returns. `quick`, `skip`, and unset tiers preserve previous summary-only behavior bit-for-bit. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.80.0] - 2026-05-11

### Added

- **Pre-Save Blocking Gate for Open Questions in `/aimi:brainstorm` (US-001):** The Pre-Save Checklist at `plugins/aimi-engineering/commands/brainstorm.md` is strengthened with a `### Pre-Save Blocking Gate — Open Questions` block that counts entries under `## Open Questions` lacking a `[resolved: <choice>]` or `[deferred: <reason>]` sentinel suffix, loops `AskUserQuestion` until every OQ carries one, and writes the sentinel back to the OQ line as the idempotency marker. Bundle-sourced OQs (lines originating from `BusinessSpec § 11` or `DesignSpec § 8`) are NOT exempt — `bundleAddressedTopics` covers chat-question categories, not spec pendencies. Agent-mode fallback auto-marks every unresolved OQ as `[deferred: agent-mode auto-defer]` before save.
- **Defensive Phase 0.5 Open Questions Resolution Gate in `/aimi:plan` (US-002):** New `### Phase 0.5: Open Questions Resolution Gate` section inserted between Phase 0 and Phase 1 of `plugins/aimi-engineering/commands/plan.md`. Parses the brainstorm `## Open Questions` section; for each line without a `[resolved: ...]` or `[deferred: ...]` sentinel, calls `AskUserQuestion`, appends the sentinel via `Edit`, records the choice in working memory `oqDecisions: { <oqId>: <choice> }` for use in Phase 4 `metadata.decisions[]`, and blocks Phase 1 until every OQ is sentinelled. Agent-mode fallback: auto-defer (do not block). Catches stale brainstorms that bypassed the upstream save-gate.
- **`validate-stories` gate-schema enforcement in `aimi-cli.sh` (US-003):** `cmd_validate_stories` now rejects the plural `gates` field with `<id>: gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)` and validates the singular `gate` object shape by requiring `type`, `status`, and `prompt` keys (emits `<id>: gate: missing required field <name>` per missing key). Errors flow through the existing `{valid, errors[]}` output channel — no `ERROR:` prefix, no exit-per-error. Three new fixtures registered in `test-aimi-cli.sh` (`test_validate_stories_gate_field`): plural `gates` (fail), singular `gate` missing `type` (fail), well-formed singular `gate` (pass).

### Changed

- **`/aimi:plan` Phase 4.5 validator note extended (US-004):** The existing note around `validate-stories (US-001) catches malformed skills[]` is extended to also document the new gate-schema enforcement — both `gates` plural rejection and singular `gate` shape validation.

## [1.79.0] - 2026-05-11

### Added

- **`validate-tasks` subcommand in `aimi-cli.sh` (US-006, gap-analysis case 6):** New CLI subcommand that mechanically enforces citation contracts in a tasks.json file before execution. Reads `acceptanceCriteria[]` entries flagged as visual and verifies each contains at least one verbatim DesignSpec citation anchored as `"<literal>" (DesignSpec § N.N L<line>)`. Exits non-zero with a structured error report on first violation, preventing story execution from proceeding with uncited visual ACs.
- **Rule 19a in `/aimi:plan` Phase 3 (US-001, US-002, US-003, gap-analysis cases 1, 2, 3):** Verbatim DesignSpec citation requirement for visual acceptance criteria. Any AC that describes a visual element (layout, copy, label, badge, header, footer, column header, KPI label, button text, subtitle) must embed the exact literal string from the DesignSpec section followed by a citation anchor in the form `"<literal>" (DesignSpec § N.N L<line>)`. Applies to H1 text, subtitles, KPI labels, column headers, button labels, footer text, and badge copy. Planner must resolve the section number and line number from the attached DesignSpec before emitting the story.
- **`source` field requirement on `backendSpec.endpoints[]` and `responseShape` (US-007, gap-analysis case 7):** Every entry in `backendSpec.endpoints[]` must carry a `source` field citing the spec document and section that mandates the endpoint (e.g., `"source": "BusinessSpec § 3.2"`). Every `responseShape` field in frontend-only plans must likewise declare its provenance. A `derived:` escape hatch is available for legitimately computed shapes whose structure is not directly specified in any spec document (e.g., `"source": "derived: aggregated from /users and /roles responses"`).
- Gap-analysis cases 4, 5, 8 are deferred to v1.80.

## [1.78.0] - 2026-05-11

### Added

- **`aimi-bundle-prototype-author` agent (US-002):** New research-category agent (`plugins/aimi-engineering/agents/research/aimi-bundle-prototype-author.md`) that generates self-contained bundle prototype HTML files from a design bundle and brainstorm context. Reads BusinessSpec/DesignSpec, applies design tokens, and emits a fully styled interactive prototype.
- **`bundle-prototype-status` CLI subcommand (US-003):** New `aimi-cli.sh` subcommand that reads `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json` and reports the current generation status (pending, in-progress, complete) for a given topic slug.
- **`bundle-prototype-finalize` CLI subcommand (US-004):** New `aimi-cli.sh` subcommand that marks a bundle prototype sidecar as finalized and records the output HTML path, enabling downstream commands to locate the generated prototype.
- **`/aimi:brainstorm` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty in the tasks metadata, brainstorm automatically invokes `aimi-bundle-prototype-author` to generate bundle prototype HTML before surfacing questions to the user.
- **`/aimi:plan` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty, plan auto-generates bundle prototype HTML via `aimi-bundle-prototype-author` during the research phase, then passes the generated path as a prototype anchor for visual story decomposition.
- **"render bundle" override keyword:** Both `/aimi:brainstorm` and `/aimi:plan` recognize a case-insensitive `render bundle` substring in the feature description as a one-shot override that forces bundle prototype generation even when `prototypes[]` is already populated.
- **Sidecar idempotency at `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json`:** Bundle prototype generation is idempotent — if a sidecar file already exists at the canonical path for a given topic slug, the author agent skips re-generation and returns the existing output HTML path.

## [1.77.0] - 2026-05-08

### Changed

- **Per-entry character cap raised from 600 to 5000:** Applies to `acceptanceCriteria[]` and `tasks[]` entries. Loosens the previous limit that was forcing truncation of detailed criteria and recipe steps. `title` (200) and `description` (500) caps unchanged.
- **`tasks[]` array length cap raised from 20 to 50:** Allows richer mechanical recipes for complex stories. Soft target of 3–15 entries remains as planner guidance.

## [1.76.0] - 2026-05-08

### Added

- **`/aimi:plan` now populates `tasks[]` on every user story (US-001):** Phase 3 Story Decomposition step 9.6 generates a horizontal mechanical breakdown of 3–15 concrete sub-steps per vertical story in verb-object phrasing. Integration steps (`"Wire <X> into <Y>"`) are mandatory whenever `implementation.files` lists a path shared with another story, closing the planning gap that caused orphaned tabs and missing routes in parallel-worktree executions.

## [1.75.0] - 2026-05-08

### Added

- **Optional `tasks[]` free-form sub-step checklist on userStories (US-001):** Stories may now include a `tasks` array (max 20 items, each ≤600 chars) of free-form sub-step strings displayed to executors as a checklist. The field is optional and additive; existing tasks.json files are unaffected.
- **Tasks-file schema bumped from 3.2 to 3.3 (US-002):** `schemaVersion` advances to `"3.3"`. The bump is additive — `validate-stories` accepts the new `tasks[]` field and enforces string elements.

### Changed

- **`/aimi:plan` now produces vertical-slice deliverables instead of layer-atomic stories (US-003):** Story decomposition targets end-to-end feature slices (each story delivers user-visible value across all layers) rather than horizontal layer boundaries. Decomposition guidance in `task-planner` updated accordingly.

## [1.74.0] - 2026-05-06

### Added

- **`researchPaths` frontmatter in brainstorm output (US-001):** `/aimi:brainstorm` now records the absolute paths of every research file it produced (`*-codebase.md`, `*-best-practices.md`, etc.) in the brainstorm document's YAML frontmatter so downstream commands can reuse them.
- **`paths` scope parameter on aimi-codebase-researcher (US-003):** The codebase researcher now accepts an optional `paths:` parameter that scopes its `Glob`/`Grep` searches to the listed directories or files instead of globbing the whole repo.
- **Path-hint extraction in brainstorm and plan (US-004):** Both commands now extract path-like tokens from the feature description (`$ARGUMENTS`) and forward them to the codebase researcher as the `paths:` scope when present.

### Changed

- **`/aimi:plan` reuses brainstorm research (US-002):** When a matched brainstorm exposes `researchPaths` and the files exist on disk with mtime ≤14 days, plan skips spawning `aimi-codebase-researcher` and `aimi-best-practices-researcher` and reads the existing files instead. Phase 5 reports `Research reused: [N] file(s) from brainstorm` when reuse occurs. Legacy brainstorms without `researchPaths` are unaffected.
- **Default `researchDepth` lowered from `standard` to `quick` (US-005):** Across `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, and `aimi-framework-docs-researcher`. Reduces default summary cap and shrinks per-research token cost when callers do not specify a depth.

## [1.73.1] - 2026-05-05

### Fixed

- **`aimi-cli (detect-design-bundle):`** `--root <path>` now also matches when `<path>` itself is a bundle directory, not only when it's a parent containing bundles. Previously returned `null` when callers pointed `--root` at the bundle itself.
- **`aimi-cli (help):`** `<subcommand> --help` and `<subcommand> -h` now print the full help doc instead of returning "Unknown flag" and exit 1 from strict subcommand parsers (`init-session`, `detect-design-bundle`, `setup-branch`, `gate-pass`) or being misinterpreted as positional input by other subcommands.

## [1.73.0] - 2026-05-05

### Fixed

- **`commands (US-001):`** Plan and brainstorm now read the `prototypes` key from design-bundle metadata and pass `--root` instead of the non-existent `--bundle` flag, so prototype HTML actually loads.
- **`commands (US-008):`** Executor's PROTOTYPE_CONTEXT builder validates `prototypeAnchor` and AC-cited paths against AIMI_ROOT before loading, preventing path-traversal escapes.

### Added

- **`brainstorm (US-002):`** Brainstorm emits bundle-discovered prototype paths in the frontmatter `prototype:` key and a `## Prototypes` body section with Path/Source/Question Category columns; plan parses both.
- **`plan (US-003):`** Phase 3 rule 19 requires every visual-layout AC to cite a prototype region using `(prototype: path §heading)` or line-range fallback `(prototype: path:Lstart-Lend)`. Plan canonicalizes prototype HTML for layout; spec for tokens, types, and states.
- **`design-bundle-researcher (US-004):`** New §16.5 `Spec-Prototype Coverage Gaps` section surfaces regions present in prototype HTML but missing or partial in DesignSpec.md, with high-confidence-missing markers for Open Questions promotion.
- **`plan (US-005):`** Phase 3 rule 20 auto-injects a mock-sync AC onto stories whose `implementation.files` match schema/types/zod path globs, with idempotency guard for re-plan and graceful degradation when no mocks/ directory exists.
- **`design-reviewer (US-006):`** `aimi-design-implementation-reviewer` now accepts polymorphic prototype source (Figma URL, prototype HTML path, or screenshot) with advisory degradation when no source is provided.
- **`review (US-007):`** `/aimi:review` automatically invokes the design-implementation-reviewer once per visual story when `metadata.prototypePaths` is non-empty, with graceful skip when `agent-browser` is not installed.
- **`plan,execute,executor (US-008):`** Plan emits `implementation.prototypeAnchor` for visual stories citing a single prototype; executor pins that anchor as label A in PROTOTYPE_CONTEXT, falling back to AC-parse when the field is absent.
- **`plan (US-009):`** Phase 3 rule 22 routes the rule-20 mock-sync AC onto consumer stories that mention the new field by name (with CamelCase entity-name fuzzy fallback), moving rather than copying when a consumer matches.

## [1.72.0] - 2026-05-05

### Added

- **`detect-design-bundle` CLI subcommand (US-001):** New `aimi-cli.sh` subcommand that detects whether a project contains a BusinessSpec and/or DesignSpec file, emitting structured JSON output consumed by brainstorm, plan, and story-executor workflows.
- **test-aimi-cli.sh bundle detection tests (US-002):** Test coverage for `detect-design-bundle` — presence, absence, and partial-match cases added to the CLI test suite.
- **`aimi-design-bundle-researcher` agent (US-003):** New 16-section structured passthrough agent that reads BusinessSpec and DesignSpec files and emits a compressed research summary for downstream brainstorm and plan consumers.
- **brainstorm bundle-aware research consolidation (US-004):** Brainstorm now invokes `aimi-design-bundle-researcher` when a bundle is detected, merging spec insights into the question-selection and variant-axis stages before surfacing them to the user.
- **bundle-aware token probe in visual-variants.md (US-005):** `visual-variants.md` reference now includes a token probe step that reads `metadata.designTokens` when a design bundle is present, feeding spec-extracted tokens into the variant axis decision tree.
- **brainstorm short-circuits visual variants when bundle present (US-006):** When a DesignSpec is detected, brainstorm skips the token-extraction fallback path and uses spec-defined tokens directly, preventing redundant extraction work.
- **spec-aware brainstorm document (US-007):** Brainstorm output document gains Personas, View Modes, Layout, and Specs sections populated from bundle research when a BusinessSpec or DesignSpec is present.
- **plan ingests bundle into tasks.json `metadata.designBundle` (US-008):** `/aimi:plan` populates `metadata.designBundle` and `metadata.designTokens` fields in the generated `tasks.json` when a design bundle is detected at planning time.
- **story-executor design-bundle fidelity guidance (US-009):** Story-executor reads `metadata.designBundle` and `metadata.designTokens` from `tasks.json` and surfaces spec-aware read order with rule-ID citation in its implementation guidance.
- **`/aimi:deepen` spec cross-reference (US-011):** `/aimi:deepen` now cross-references BusinessSpec and DesignSpec when enriching story acceptance criteria, citing spec rule IDs in the enriched output.

## [1.71.0] - 2026-04-29

### Added

- **`vary ui` override keyword (US-005):** Typing `vary ui` in a brainstorm visual question opts into UI-token variation for the next variant axis selection, activating color, typography, radii, and surface axes even when project tokens are present.

### Changed

- **brainstorm visual variants (US-005):** When project design tokens are present, variant axes now default to UX-branch axes (layout, hierarchy, flow) instead of UI-branch axes. UI-branch axes (color, typography, radii, surface) activate only on full token-extraction fallback or explicit `vary ui` override. This preserves prior behavior for projects without tokens while improving consistency for token-backed design systems.

## [1.70.0] - 2026-04-29

### Added

- **design references (US-001–US-009):** 12 new reference documents ported from Anthropic Impeccable v3.0.5 into `skills/frontend-design/references/`: `brand.md`, `product.md`, `color-and-contrast.md`, `typography.md`, `spatial-design.md`, `motion-design.md`, `responsive-design.md`, `ux-writing.md`, `interaction-design.md`, `cognitive-load.md`, `heuristics-scoring.md`, `personas.md`.
- **design references index:** `skills/frontend-design/references/index.md` — registry mapping each reference slug to its file and canonical trigger phrase for use by brainstorm lazy-load hooks.
- **commands (`/aimi:design:shape`, `/aimi:design:craft`, `/aimi:design:critique`, `/aimi:design:audit`, `/aimi:design:polish`):** 5 new design slash commands under `commands/design/` covering idea shaping, component crafting, design critique, accessibility/heuristics audit, and visual polish workflows.
- **brainstorm lazy-load hooks:** `loaded_design_refs[]` working memory array plus 4 hook points in `skills/frontend-design/SKILL.md` enabling on-demand reference loading during brainstorm sessions without pre-loading all 12 documents.

### Changed

- **skill (`frontend-design` SKILL.md):** Full rewrite — 42 lines expanded to ~161 lines. Integrates shared design laws (Gestalt, Fitts, Hick, aesthetic-usability effect), absolute bans list, and AI-slop detection test. Now references the 12 ported design documents via the lazy-load hook system.

### Security

- Design reference content ported under Apache-2.0 license from Anthropic Impeccable v3.0.5. License attribution preserved in reference file headers.

### Notes

- US-012: CLI test suite (325 tests), YAML frontmatter smoke checks (SKILL.md + 5 commands/design/*.md), and references/ token budget (1657/3000 lines) all verified prior to release. Fixed invalid YAML frontmatter in `commands/design/craft.md` and `commands/design/shape.md` (unquoted `description` values containing `: ` sequences).

## [1.69.1] - 2026-04-29

### Fixed

- **installer (install.sh — US-010):** `install_commands()` now translates subdirectory commands (e.g., `commands/design/*.md`) in addition to top-level `commands/*.md`. Previously only flat files were processed; `commands/design/{shape,craft,critique,audit,polish}.md` were silently dropped during OpenCode install. Subdirectory commands are flattened to `aimi/design-<name>.md` using colon-to-hyphen normalisation of the `name:` frontmatter field. The `references/` subdirectory is skipped (it holds shared reference docs, not commands). Dry-run mode now lists all translated commands, including subdirectory ones.

## [1.69.0] - 2026-04-29

### Changed

- execute: every story now runs in its own git worktree — single-story waves no longer skip worktree creation; the N=1 fast-path was deleted so the multi-story flow handles all wave sizes uniformly
- Default metadata.maxConcurrency raised from 4 to 5; selection within a wave remains deterministic (tasks.json file order via $AIMI_CLI list-ready)

## [1.68.3] - 2026-04-28

### Fixed

- **commands (CLI path resolution):** Replaced the CWD-relative `Read \`references/cli-path-resolution.md\`` loader with the absolute `Read \`${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md\`` form across the seven commands that resolve `$AIMI_CLI` (init, brainstorm, plan, execute — both CLI and Worktree Manager reads — next, open-pr, status). The relative form failed when commands ran from a project CWD outside the plugin tree, causing the agent to glob the project for `cli-path-resolution.md`.
- **command (`/aimi:init`):** Widened `allowed-tools` from the scoped `Read(references/cli-path-resolution.md)` to bare `Read`, matching the pattern used by the other six commands. The scoped form prevented the new absolute-path read from being authorized.
- **install (OpenCode):** `install.sh translate_command_body()` now rewrites `${CLAUDE_PLUGIN_ROOT}` to `${AIMI_PLUGIN_DIR}` so translated commands resolve under OpenCode's plugin layout (where `CLAUDE_PLUGIN_ROOT` is undefined). Mirrors the existing `CLAUDE_CONFIG_DIR` rewrite.

## [1.68.2] - 2026-04-27

### Removed

- **docs (README):** Dropped the `## Version History` section and its TOC entry. CHANGELOG.md is now the single source of truth for version history; the README links to it from a one-line pointer at the end of Troubleshooting.

## [1.68.1] - 2026-04-27

### Added

- **docs (README):** New Troubleshooting subsection "Inspecting an agent-browser headed session" documenting how to attach Chrome DevTools to a running `agent-browser --headed` session via `--remote-debugging-port=9222` and `chrome://inspect/#devices`. Useful for debugging Visual Follow sessions launched by `/aimi:execute`.

## [1.68.0] - 2026-04-27

### Removed

- **command (`/aimi:swarm`):** Deleted `/aimi:swarm` and its `plugins/aimi-engineering/commands/swarm.md` body. Parallel execution is now handled exclusively by `/aimi:execute` via git worktrees (no Docker dependency).
- **skill (`orchestrating-swarms`):** Deleted the entire `plugins/aimi-engineering/skills/orchestrating-swarms/` directory (7 files). The skill was only referenced by `/aimi:swarm` and was already labeled "Disabled (Reference Only)" in the README.
- **hook patterns:** Removed Docker auto-approve patterns (13–18) from `plugins/aimi-engineering/hooks/auto-approve-cli.sh` — they exclusively approved `aimi-swarm-*` and `aimi-*` container commands.
- **OpenCode install:** `install.sh` no longer grants Docker permissions in `opencode.json` (the swarm-only Docker allow rules are removed from `install_permissions`).

### Migration

Users running `/aimi:swarm <args>` should switch to `/aimi:execute`, which now provides the same parallel-wave execution via worktrees without needing Docker or `ANTHROPIC_API_KEY` in environment.

## [1.67.1] - 2026-04-27

### Changed

- **docs (AGENTS.md):** Extended AGENTS.md output compression with caveman-derived rules (Guzik 2026 benchmark; expected 10-20% reduction on spawned-agent summary returns). New blocks: article-elision (drop a/an/the in bullet leads), sentence-pattern compression (convert passive constructions to active telegraphic form), short-synonyms substitution table, and scope-guard (suppresses rules when user requests verbose output or full prose).

## [1.67.0] - 2026-04-22

### Added

- **tasks schema (US-001):** New optional `skills[]` field on user story objects. The validator accepts an array of skill-name strings (e.g. `["dhh-rails-style", "frontend-design"]`); stories without `skills[]` are valid and behave identically to pre-1.67. Stories can now declare skills they need (e.g. dhh-rails-style, frontend-design) — the executor injects SKILL.md contents into the worker prompt, keeping the base template lean while giving each story targeted conventions.
- **command (aimi:execute — US-002):** Executor skill injection. When a story carries a non-empty `skills[]` array, `/aimi:execute` resolves each named skill's `SKILL.md` from the plugin's `skills/` directory and injects its contents into the Task agent prompt ahead of the story body. Skills that cannot be resolved are logged as warnings and skipped; execution continues.

### Changed

- **command (aimi:plan — US-003):** `plan.md` heuristic auto-populates `skills[]` from file patterns detected in the story's `implementation.files` list. Rails/Ruby paths → `dhh-rails-style`; React/Next.js/CSS/Tailwind paths → `frontend-design`. The field is omitted when no patterns match, preserving backwards compatibility.

## [1.66.0] - 2026-04-22

### Added

- **cli (aimi-cli.sh):** New `--base <branch>` flag on the `setup-branch` subcommand. Callers can now specify an explicit base branch (e.g., `aimi-cli.sh setup-branch --base main`) instead of relying solely on automatic default-branch detection. When omitted, behavior is identical to pre-1.66: the default branch is detected via `detect-default-branch`. Enables `/aimi:execute` to thread the user's chosen base branch all the way down to the worktree creation call.

### Changed

- **command (aimi:execute):** Interactive base-branch selection at Step 1.6. When the current branch has unmerged work, `/aimi:execute` now asks whether to stack on the current branch or start fresh from the default branch. Previously auto-stacked. In agent mode (`AIMI_AGENT_MODE=true`, `CI=true`, or no TTY) the pre-1.66 automatic stacking behavior is preserved — no prompt is emitted and the current branch is used as-is.

## [1.65.0] - 2026-04-22

### Added

- **command (aimi:init):** New `/aimi:init` slash command that primes the global CLI path cache (`~/.claude/aimi-engineering-cli-path`) on demand. After priming, subsequent `/aimi:*` commands skip the Layer 2 glob in `references/cli-path-resolution.md` until the cache goes stale. Users can re-run it anytime to repair a broken cache.
- **cli (aimi-cli.sh):** New `prime-cache` subcommand that actively populates the global CLI path cache with a structured JSON contract `{status, path, host, version, message}`. Under Claude Code it globs `~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`, validates the resolved path against the same pattern used by `read_global_cli_cache`, and writes atomically. Under OpenCode it writes `$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh` after verifying the script is executable — diverging from `cmd_check_version`'s short-circuit because the whole point of `prime-cache` is to populate the cache, not defer to the converter. Status values: `ok`, `already_current`, `not_found`, `error`. Exempt from `find_aimi_root()` so it runs from any directory, including fresh installs with no `.aimi/`.

### Changed

- **installer (install.sh):** `install.sh --to opencode` now primes the global CLI path cache post-install by invoking `aimi-cli.sh prime-cache` after the shell-profile env var is set. This writes `~/.claude/aimi-engineering-cli-path` at install time so the first `/aimi:*` command after install skips the Layer 2 glob entirely. Failure is non-fatal — the installer warns and continues. `./install.sh --uninstall --from opencode` now removes the global cache file via `rm -f` (best-effort; dry-run logs `Would remove ...` only when the file exists).

### Notes

- The global cache file `~/.claude/aimi-engineering-cli-path` is now written at install time (OpenCode via `install.sh`) or on demand (Claude Code via `/aimi:init`). Layer 2 glob-and-cache-update logic in `references/cli-path-resolution.md` remains as a rescue fallback when the cache is missing or stale — no change to the 4-layer resolution contract.

## [1.64.0] - 2026-04-21

### Added

- **command (aimi:brainstorm — US-002):** Pre-flight browser availability check with chat output. Before the first visual question, `/aimi:brainstorm` runs `command -v agent-browser` plus a `DISPLAY`/`CI` heuristic once and echoes `Visual preview: ready` or `Visual preview: disabled (<reason>)` to chat. Result is cached in working memory so subsequent visual questions do not re-check.
- **command (aimi:brainstorm — US-004):** `AIMI_BRAINSTORM_DEBUG=1` environment variable support. When set, emits `[brainstorm-debug] <context>: <value>` diagnostic lines to chat at four decision points (topic slug, category classification, browser attempt, variant choice). A new "Environment Variables" section in `brainstorm.md` documents the flag alongside `AIMI_AGENT_MODE`.
- **command (aimi:brainstorm — US-005):** `show variants` override keyword. Typing the phrase in a brainstorm topic or reply forces the next question to render HTML variants regardless of its category classification. Echoes `Visual override active — rendering variants for next question` to chat once per trigger.
- **command (aimi:brainstorm — US-003):** Chat-surfacing for browser skip/degradation events. `agent-browser unavailable`, `agent-browser session lost`, and `agent-mode: picker unavailable — auto-selected variant A` are now echoed to chat once per session (guarded by `echoedBrowserUnavailable`, `echoedSessionLost`, `echoedPickerUnavailable` flags), in addition to being logged to the brainstorm document.

### Changed

- **command (aimi:brainstorm — US-001):** Step 4 retry logic improved. A failed session reload now retries once with a `-2` session-name suffix before degrading to text-only, matching the canonical flow in `references/visual-variants.md` "Fallback: mid-session crash" section. Previously degraded on first failure.

## [1.63.0] - 2026-04-20

### Added

- **cli (aimi-cli.sh):** New `detect-interactivity` subcommand that resolves the active interactivity mode from environment: prints `agent` when `AIMI_AGENT_MODE=true`, `CI=true`, or stdin is not a TTY; prints `picker` otherwise. Exempt from `find_aimi_root()` since it reads only env vars — usable by commands before any `.aimi/` state exists. Documented in `cmd_help` usage.
- **reference (interactivity.md):** New `commands/references/interactivity.md` defines the two-mode contract (`picker`, `agent`), the picker option-format rules (lettered labels, escape hatch on last option, 2–6 options cap), the agent auto-pick log-line format (`agent-mode: <site-id> auto-<action>`), and a 3-step checklist for adding new question sites. Single source of truth for all commands that ask the user questions.
- **command (aimi:brainstorm):** New Step 0 (Resolve CLI Path) + Step 0.5 (Resolve Interactivity Mode) preamble sets `INTERACTIVE_MODE` once per invocation via `$AIMI_CLI detect-interactivity`. Phase 2 main batch questions now branch on `INTERACTIVE_MODE`: `picker` emits one `AskUserQuestion` call per question with lettered options + `Other` free-form escape (replaces the former single prose block with shorthand parser); `agent` auto-selects option A and logs one line per question. Agent-mode fallback notes added to the remaining 3 picker sites (Phase 0 plan-redirect auto-proceeds to `/aimi:plan`; Phase 3 approach auto-picks option A; Phase 4 open questions defer to a `Deferred Questions` section). Combined with the existing visual-variant fallback (L335) and the new Phase 2 branch, all 7 user-facing question sites now have deterministic agent-mode behavior.

### Changed

- **installer (install.sh):** AskUserQuestion translation no longer degrades to prose-in-chat. OpenCode ships a native `question` tool ([docs/tools](https://opencode.ai/docs/tools/)) with header + lettered options + custom-text input; the translator now maps `Use **AskUserQuestion**` → `Use the **question** tool`, `Use AskUserQuestion` → `Use the question tool`, `via AskUserQuestion` → `via the question tool`, and the bare `AskUserQuestion` fallback → `the question tool`. OpenCode users get the same picker UX as Claude Code users across every command that uses the pattern (brainstorm, swarm, plan, task-planner). Permission-gated by `"question"` in `opencode.json` (default: `"ask"`).

### Fixed

- **command (aimi:brainstorm):** Shorthand answer parser (`"1A, 2C, 3B"`) removed from Phase 2 — it was a workaround for the missing picker on the main batch and no longer applies when every question is a picker call. Pre-existing visual-variant fallback log line changed from `agent-mode: AskUserQuestion unavailable` to `agent-mode: picker unavailable` so it stays grammatical after OpenCode translation.

### Tests

- **test-aimi-cli.sh:** Three new tests covering `detect-interactivity`: `test_detect_interactivity_agent_mode_env` (AIMI_AGENT_MODE=true overrides), `test_detect_interactivity_ci_env` (CI=true triggers agent mode), `test_detect_interactivity_non_tty` (no TTY on stdin triggers agent mode). Baseline raised from 283/0 to 286/0.

## [1.62.0] - 2026-04-20

### Added

- **schema (tasks.json):** New optional `metadata.prototypePaths[]` field — a deduplicated array of relative paths to prototype HTML variants and the `<topic-slug>-tokens.json` sidecar. Schema version stays at `3.2` (additive optional field, follows the `researchPaths[]` precedent).
- **command (aimi:plan):** Phase 0 Prototype Context now collects successfully loaded prototype paths (non-dropped after the 200 KB aggregate cap, non-missing on disk) into `resolvedPrototypePaths`; Phase 4 Derive Metadata persists them as `metadata.prototypePaths[]`. Full-stack split writes the same array to both frontend and backend tasks.json files. The Aimi-branded report surfaces `Prototypes: [N] variant file(s) registered` when non-empty.
- **command (aimi:execute):** New Step 3.5 Load Prototype Context reads `metadata.prototypePaths[]` and builds `PROTOTYPE_CONTEXT` — `.html` files wrap as `<prototype_html label="X" path="...">` blocks with tag-breakout escape, `.json` sidecars wrap as `<prototype_tokens>` blocks. Re-applies the 200 KB aggregate cap at execute time; skips missing files with a warning line. `PROTOTYPE_CONTEXT` is injected into all three worker-prompt assembly sites (single-story wave, multi-story parallel wave, paired-split sub-Tasks) immediately after `DESIGN_CONTEXT`, omitted when empty. Start report surfaces `Prototype context: [N] variant(s) loaded` when variants are present.
- **skill (story-executor):** Prompt Template and Compact Template both define a `<prototype_context>` XML section (after `<design_context>`) so spawned workers know how to consume prototype variants when threaded.
- **cli (aimi-cli.sh — archive-task):** Cleans `metadata.prototypePaths[]` files alongside `researchPaths[]` using an identical loop (relative-path resolution from PROJECT_ROOT, `validate_path_in_project` gate, `[ -e ]` missing-file tolerance, `rm -f`). Output JSON gains a `prototypeCleaned` counter field on the existing single `jq -n` call.
- **tests (test-aimi-cli.sh):** Four new archive-task tests covering prototype cleanup: `test_archive_task_with_prototype_paths`, `test_archive_task_without_prototype_paths`, `test_archive_task_missing_prototype_files`, and `test_archive_task_both_research_and_prototype_paths`.

### Security

- **command (aimi:plan):** Phase 0 Prototype Context now validates that each resolved absolute path stays within AIMI_ROOT before reading — paths escaping via `../` or symlink targets are rejected with `prototype <path> rejected — path outside project root` and skipped (plan does not abort for a bad path). Prevents a malicious brainstorm with a `prototype: ../../etc/passwd` frontmatter key from injecting arbitrary file contents into the planning context.

## [1.61.1] - 2026-04-17

### Changed

- **command (aimi:deepen):** Research file naming standardized to the `brainstorm` and `plan` canonical shape `.aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-<story.id>-codebase.md`. Deepen now derives `TOPIC_SLUG` from `metadata.branchName` (stripping the `type/` prefix), generates a single `RUN_TS` via `date +%H%M%S` and reuses it across every parallel researcher, and passes the path via a structured `outputPath:` field so researcher agents write to the exact canonical location (the researcher Output Contract honors caller-supplied `outputPath:`). Same-run grouping now matches brainstorm/plan.

### Fixed

- **command (aimi:deepen):** Step 4.5 appends every written research path to `metadata.researchPaths[]` (deduplicated). Previously deepen's research files leaked — `$AIMI_CLI archive-task` reads `researchPaths[]` to clean up, but deepen never wrote into the array, so its files persisted across archive cycles.

## [1.61.0] - 2026-04-17

### Added

- **reference (visual-variants.md):** New `commands/references/visual-variants.md` — Alpine.js switcher skeleton with topic-slug sanitization and HTML-escape rules (including JS-context escaping note for future `x-data` embeddings), Tailwind CDN offline behavior, 2–4 variants-per-question constraint, and append semantics for multi-question sessions.
- **reference (visual-variants.md — Token Extraction):** 6-source precedence list for design-token resolution: `tailwind.config.{js,ts}` → `theme.{ts,js,tsx,jsx}` → CSS custom properties → `_variables.scss` → MUI `createTheme` → Chakra `extendTheme`. **Eight token families** covered: colors, fonts, radii, spacing, shadows, transitions, screens (breakpoints), and dark-mode. Per-family independent resolution, Tailwind CDN defaults fallback with in-document warning, parse errors silently skip the source and never abort brainstorm.
- **reference (visual-variants.md — Token Sidecar JSON):** Extraction writes a machine-readable `<topic-slug>-tokens.json` alongside the HTML variants file, recording resolved values, per-family source attribution, and fallback list. Consumed by `/aimi:plan` (implementation context) and `/aimi:review` (fidelity checks).
- **reference (visual-variants.md — Structural Guidance):** Canonical-shape taxonomy (form/card/nav/hero/modal/table/layout-with-sidebar). Variants in the same question share shape, density, and primary-action copy; direction varies via typography, color, radius, shadow, and density. Tokens emitted as CSS custom properties on `:root` (plus `.dark :root` for dark-mode strategy `class`) and referenced via Tailwind arbitrary-value syntax.
- **reference (visual-variants.md — Browser Session Lifecycle):** Lazy open, reuse-with-reload (idempotent on re-runs), close-on-completion; missing-skill / missing-display / CI fallback degrades to text-only.
- **command (aimi:brainstorm — Phase 2):** Visual Variant Rendering phase with optional Component-Shell Scan (samples 2–3 representative component files to surface wrapper-tag and class-recipe idioms for Structural Guidance). Variant Selection sub-step offers `AskUserQuestion` options; **agent-mode fallback** auto-selects Variant A when `AskUserQuestion` is unavailable (non-interactive hosts). Variant Persistence stores `chosen_variant_slug` and records `selectedVariants` in brainstorm frontmatter. Non-visual categories remain text-only throughout.
- **command (aimi:brainstorm — Phase 5):** Cleanup step prunes the scratch prototype file after clean session completion; standalone variant files and the tokens sidecar are preserved.
- **command (aimi:plan — Phase 0):** Prototype Context sub-step — parses brainstorm `prototype:` frontmatter and `## Prototype` section; loads the `<topic-slug>-tokens.json` sidecar; sanitizes embedded `</prototype_html>` sequences before wrapping; **200 KB aggregate cap** across all loaded blocks (drops in reverse label order with warning); injects `<prototype_html>` block and tokens JSON into researcher and decomposition prompts so implementation agents inherit the visual intent.
- **command (aimi:review):** Prototype Design Context sub-step — when a PR's branch has a matching brainstorm, loads the prototype HTML and tokens JSON and threads them into architecture, simplicity, and language-specific reviewers so fidelity against the chosen variant and target-project tokens can be verified.

### Changed

- **install.sh:** `install_plugin_source` dry-run branch simplified — removed the per-file enumeration of `commands/references/` (cosmetic only; `cp -R` already copies the directory).

## [1.60.3] - 2026-04-16

### Changed

- **skill (story-executor):** Worker prompt template (both full and compact variants) now explicitly instructs the spawned agent to apply output compression rules from `AGENTS.md`. Previously the rules were only loaded passively through project guidelines; the new `<output_rules>` section in the full template and the appended sentence in the compact template ensure the directive reaches the agent even when `AGENTS.md` is missing or in edge-case multi-repo scenarios.
- **docs (plugin CLAUDE.md):** Hedge unverified token-reduction claims (~33% inline-story savings, ~60% compact-template savings) — replaced with qualitative descriptions noting the savings have not been benchmarked. Applies to both `plugins/aimi-engineering/CLAUDE.md` Performance Guidelines and the Compact Template blockquote in `skills/story-executor/SKILL.md`.

## [1.60.2] - 2026-04-16

### Removed

- **plugin manifest:** Remove local-only `penpot` MCP server entry from `mcpServers` (pointed at `http://localhost:4401/mcp`, not suitable for distribution).

## [1.60.1] - 2026-04-16

### Changed

- **command (aimi:open-pr):** Document that the command does not read `CLAUDE.md`/`AGENTS.md` and point users to `.github/pull_request_template.md` for project-specific PR structure (honored automatically by `gh pr create`). No behavior change.

## [1.60.0] - 2026-04-16

### Changed

- **command (aimi:open-pr):** PR title and body are now derived from git commits and the diff against the base branch instead of `tasks.json`. Title comes from the first commit subject on the branch (fallback: current branch name). Body replaces the former `Problem`/`Solution`/`Stories Completed`/`Testing` sections with `Summary` (aggregated commit bodies), `Changes` (commit subjects as bullets), and `Files Changed` (git diff --stat). `tasks.json` is only read inside the conditional `Backend Implementation Spec` block (requires `metadata.frontendOnly` AND `metadata.backendSpec`); when no tasks file is present or metadata lookup fails, that block is silently skipped and PR creation still succeeds.

## [1.59.1] - 2026-04-15

### Fixed

- **cli**: Context-aware CLI path resolution — Layer 0 (`AIMI_PLUGIN_DIR`) is now skipped when running inside Claude Code (`CLAUDECODE=1`), ensuring the Claude Code cache directory is always used instead of the stale OpenCode install path
- **cli**: `check-version --fix` and `cleanup-versions` no longer bail early with "managed by converter" when inside Claude Code, enabling self-heal after plugin updates
- **cli**: `read_global_cli_cache` and `read_global_worktree_cache` reject OpenCode-style cached paths when inside Claude Code, preventing split-brain version resolution

## [1.59.0] - 2026-04-15

### Changed

- **agents (aimi-lint, aimi-learnings-researcher):** Remove hardcoded model: haiku; both agents now inherit model from calling context

## [1.58.2] - 2026-04-15

### Added

- **cli**: `archive-task` now deletes research files listed in `metadata.researchPaths` — reads each path, resolves relative paths from `PROJECT_ROOT`, validates with `validate_path_in_project`, checks existence, and deletes with `rm -f`; missing files are silently skipped
- **cli**: JSON output of `archive-task` now always includes `researchCleaned` integer field (0 when no research files were present or none existed)
- **tests**: Three new tests for archive-task research cleanup: with researchPaths, without researchPaths (researchCleaned 0), and with missing research files (silent skip)

## [1.58.1] - 2026-04-15

### Added

- **schema**: Add `researchPaths` (string[]) metadata field to task-format-v3.md — tracks research files generated during planning so archive-task can clean them up; omitted when `researchDepth` is `skip` or no files written
- **planner**: Phase 4 Derive Metadata now includes `researchPaths` bullet instructing the orchestrator to collect paths from Phase 1 and Phase 1.5b research agents
- **docs**: CLAUDE.md key fields summary updated with `researchPaths[](optional)` after `maxConcurrency`

## [1.58.0] - 2026-04-15

### Changed

- **research**: Unify research file naming with run discriminator — all four research agents (codebase, learnings, best-practices, framework-docs) now use `YYYY-MM-DD-<topicSlug>-<HHmmss>-<short-name>.md` pattern
- **planner**: Generate `RUN_TS=$(date +%H%M%S)` once in plan.md Phase 1 and pass it to all agent `outputPath` parameters so same-day re-runs produce separate files
- **brainstorm**: Phase 1b now generates `RUN_TS` and specifies explicit `outputPath` for each research agent instead of relying on agent Output Contract defaults
- **task-planner**: SKILL.md and pipeline-phases.md agent prompts updated to use `outputPath` with the new `YYYY-MM-DD-[topicSlug]-[RUN_TS]-<short-name>.md` pattern
- **research agents**: Output Contract updated to document that caller-specified `outputPath` takes precedence over agent-derived slug/timestamp; short names in frontmatter updated to `codebase`, `learnings`, `best-practices`, `framework-docs`

## [1.57.0] - 2026-04-15

### Added

- **cli**: Add `version` subcommand that prints the plugin version from plugin.json
- **tests**: Add version command test validating semver output

## [1.56.0] - 2026-04-15

### Fixed

- **tests**: Unset `AIMI_PLUGIN_DIR` before version staleness and global cache tests to prevent compound-plugin converter from short-circuiting test assertions

## [1.55.0] - 2026-04-15

### Fixed

- **cli**: Add `--project` flag to `setup-branch` and `detect-default-branch` commands for multi-repo layouts where AIMI root is not a git repository
- **cli**: Add git-repo guard to both commands with clear error message instead of cryptic `fatal: not a git repository`
- **execute**: Detect multi-repo layout (AIMI root is not a git repo) and skip main repo branch setup, handling branch creation per-project instead
- **planner**: Defer default branch detection to per-project when AIMI root is not a git repo

### Added

- **tests**: Add `--project` flag and non-git-repo error tests for `setup-branch`

## [1.54.0] - 2026-04-14

### Fixed

- **planner**: Add missing auto-scan for git repos step in plan.md Phase 1, syncing with SKILL.md
- **planner**: Promote `project` field assignment to explicit numbered step 6 in Phase 3, preventing model from skipping multi-repo project assignment

## [1.53.0] - 2026-04-14

### Changed

- **brainstorm**: Structured consolidation schema in Phase 1.6 with adaptive return caps tied to researchDepth
- **deepen**: Research agents write findings to `.aimi/research/` files instead of returning bulk text inline
- **deepen**: Adaptive return caps tied to researchDepth — lower depths produce shorter agent output
- **planner**: Default researchDepth inherited through planning pipeline
- **review**: Protected artifacts updated for `.aimi/research/` output path

## [1.52.0] - 2026-04-14

### Added

- **agents**: AGENTS.md with context-adaptive compression rules for spawned agent output

### Changed

- **cli**: Deduplicated CLI path resolution to eliminate redundant path computations
- **story-executor**: XML tags in story executor prompts for structured content boundaries
- **story-executor**: Compact prompt pattern — subsequent stories use condensed static sections (~60% token reduction)
- **git-worktree**: Progressive disclosure — worktree skill surfaces details on demand instead of upfront
- **task-planner**: Progressive disclosure — planner skill surfaces details on demand instead of upfront

## [1.51.0] - 2026-04-14

### Fixed

- **execute**: Visual verification for worktree stories now runs post-merge instead of inside isolated worktrees where dev server cannot see changes

## [1.50.0] - 2026-04-14

### Added

- **brainstorm**: Design-thinking integration for visual features — auto-detect UI keywords in feature descriptions, inject Aesthetic Direction and Differentiation topic categories into Phase 2, conditional Design Decisions section in brainstorm document template, design context passed to story executors
- **planner**: Auto-skip implementation scope question for non-app features (plugin changes, refactors, CLI tools, docs) — uses keyword detection with conflicting-signals precedence

## [1.49.0] - 2026-04-14

### Fixed

- **execute**: Visual-follow browser detection now type-guards `verification` field — prevents silent failure when verification is a string instead of object, warns about malformed fields
- **planner**: Added explicit "verification MUST be an object" warnings with JSON examples to all planner instruction files (SKILL.md, plan.md, pipeline-phases.md, story-decomposition.md)

### Changed

- **schema**: `backendSpec.businessContext` expanded from string to structured object with `summary`, `userRoles[]`, `constraints[]`, `assumptions[]`, `successCriteria[]` sub-fields
- **open-pr**: Backend Implementation Spec "Business Context" section now renders structured sub-sections (User Roles, Constraints, Assumptions, Success Criteria) with legacy string fallback
- **planner**: Phase 4 businessContext generation guidance updated with explicit extraction instructions for each sub-field

## [1.48.0] - 2026-04-14

### Added

- **open-pr**: GitHub issue creation with backend spec for frontend-only PRs — after PR creation, attempts `gh issue create` with Backend Implementation Spec body, links issue to PR via `gh pr edit`, graceful degradation on failure (warning only, PR unaffected)

## [1.47.0] - 2026-04-14

### Added

- **execute**: Multi-file auto-detection (Step 0.9) — uses `find-tasks-all` to discover all task files, auto-detects paired `*-frontend-tasks.json` and `*-backend-tasks.json` with matching date+feature prefix, spawns two parallel foreground Tasks with worktree isolation and `init-session --file`, aggregated completion report showing per-file results
- **open-pr**: Backend Implementation Spec section in PR body for frontend-only prototypes — when `frontendOnly` is true and `backendSpec` exists, appends Endpoints, Data Models, Business Rules, and Business Context subsections after Testing (deterministic rendering, no LLM generation)

## [1.46.0] - 2026-04-14

### Added

- **planner**: Split task file generation — full-stack scope produces separate `*-frontend-tasks.json` and `*-backend-tasks.json` with independent branch names, dependency graphs, and wave numbers
- **planner**: `backendSpec` metadata generation — frontend-only scope synthesizes `endpoints`, `dataModels`, `businessRules`, and `businessContext` from story analysis
- **planner**: Per-file Phase 4.5 validation using `init-session --file` for independent validation of each split file

## [1.45.0] - 2026-04-14

### Added

- **cli**: `find-tasks-all` subcommand — returns newline-separated list of all *-tasks.json files sorted by modification time for multi-file discovery
- **cli**: `--file <path>` flag for `init-session` — allows specifying a tasks file directly instead of auto-detecting the most recent one, with existence and pattern validation
- **story-executor**: Headed mode context and visual-follow session reuse — adds `[HEADED_MODE]` placeholder, conditional visual verification branches for headed (session reuse, no close) vs headless (executor-owned lifecycle) modes

## [1.44.0] - 2026-04-14

### Added

- **execute**: Visual-follow session prompt (Step 0.7) — detects frontend stories with `verification.strategy == "visual"`, prompts user to follow implementation in a headed browser, manages `agent-browser` session lifecycle around the wave loop

## [1.43.1] - 2026-04-09

### Fixed

- **cli**: Improved `setup-branch` comment clarity — distinguish "on default branch" vs "merged into default" cases

### Changed

- **test**: Added test for merged-but-not-on-default branch scenario in `setup-branch`, updated test descriptions for accuracy

## [1.43.0] - 2026-04-09

### Added

- **cli**: `setup-branch` subcommand — deterministic branch creation/checkout with JSON output, supports local/remote/new branch detection with merge-status-aware base selection
- **hooks**: `setup-branch` added to auto-approve whitelist in `auto-approve-cli.sh`

## [1.42.0] - 2026-04-08

### Changed

- **execute**: Branch creation from `origin/[DEFAULT_BRANCH]` is now conditional — only when the current branch has been merged into the default branch; otherwise creates from current HEAD

## [1.41.0] - 2026-04-08

### Added

- **cli**: `detect-default-branch` subcommand — dynamically detects repository default branch with `git remote show origin` primary and `git symbolic-ref` fallback, cached in `.aimi/default-branch`
- **cli**: `list-archivable` subcommand — returns JSON array of task files where all stories are completed or skipped
- **cli**: `archive-task` subcommand — moves completed task file + linked brainstorm to `.aimi/archive/` with collision handling
- **execute**: Archival prompt at entry point (Step 0.5) — checks for completed task files via `list-archivable` and offers to archive them before starting execution
- **execute**: Branch freshness check (Step 1.5) — fetches origin and detects default branch via `$AIMI_CLI detect-default-branch` before branch setup
- **plan**: Branch freshness check — fetches origin before Phase 0 to ensure local refs are current, with offline warning fallback
- **plan**: CLI path resolution using 4-layer strategy and `detect-default-branch` for dynamic default branch detection
- **review**: Dynamic default branch detection using `git symbolic-ref`, replacing hardcoded `main`

### Changed

- **execute**: New branches now created from `origin/[DEFAULT_BRANCH]` instead of current HEAD, ensuring fresh base
- **execute**: Commit counting in Step 5 uses dynamically detected default branch instead of hardcoded `main`
- **cli**: `clear-state` now also removes `default-branch` cache file

## [1.40.0] - 2026-04-08

### Changed

- **branding**: Updated author to "Aimi — Autonomous Code Companion" in plugin.json and marketplace.json

## [1.39.0] - 2026-04-07

### Added

- **story-executor**: Visual verification section in prompt template — conditional agent-browser flow for stories with `verification.strategy: visual` and `verification.url`, advisory only (failures do not block commits)

## [1.38.0] - 2026-04-07

### Added

- **execute**: Commit verification after Task execution — captures HEAD SHA before each Task spawn and compares after success; stories with no commit are marked as failed with cascade-skip instead of silently completing
- **execute**: Parallel worktree commit verification — captures base SHA per project group before worktree creation, filters out no-commit stories before merge step

## [1.37.0] - 2026-04-06

### Added

- **commands**: `/aimi:open-pr` command for opening pull requests from executed task branches with structured PR descriptions

## [1.36.0] - 2026-04-02

### Added

- **schema**: `researchDepth` metadata field for controlling research thoroughness (quick, standard, deep)
- **schema**: `wave` field on stories for explicit wave assignment and parallel execution grouping
- **schema**: `implementation` object on stories with `files`, `approach`, and `verify` fields for structured implementation guidance
- **schema**: `verification` object on stories with `strategy`, `status`, `url`, and `expect` fields for post-execution verification
- **schema**: `gate` object on stories with `type`, `status`, `prompt`, and `options` fields for decision/action/verify gates
- **aimi-cli**: `gate-pass` command to resolve a gate as passed
- **aimi-cli**: `gate-fail` command to resolve a gate as failed
- **aimi-cli**: `validate-waves` validator for checking wave assignment consistency and dependency ordering
- **aimi-cli**: `update-field` command for updating nested story fields (e.g., `verification.status`)
- **execute**: Gate handling in wave execution loop — decision gates block story start with log message, action gates log post-completion with dependent pause, verify gates log as non-blocking
- **execute**: Gate-blocked story detection — differentiates gate-blocked from true deadlocks when no stories are ready
- **execute**: Wave summary includes gate status counts (action/verify gates pending)
- **execute**: Completion summary includes pending gate inventory with resolution instructions
- **execute**: Executor updates `verification.status` to `passed` when story-executor reports verification success

### Changed

- **schema**: Schema version bumped from 3.1 to 3.2
- **execute**: `list-ready` gate filtering — stories with pending gates excluded from ready list
- **story-executor**: Prompt template now includes `implementation.files` (Key Files), `implementation.approach` (Approach), `implementation.verify` (Verification Command), and `verification.strategy`/`verification.expect` (Verification) sections when present in v3.2 story data
- **story-executor**: Story format summary in SKILL.md updated with `implementation` and `verification` field descriptions
- **story-executor**: execution-rules.md inline JSON example updated with `implementation` and `verification` objects

## [1.35.0] - 2026-04-02

### Added

- **brainstorm**: Parallel best-practices research in Phase 1 — spawns aimi-best-practices-researcher alongside aimi-codebase-researcher
- **brainstorm**: Decoupled specificity-skip logic — codebase and best-practices researchers assessed independently with distinct skip criteria
- **brainstorm**: Research Consolidation step (1c) merges internal patterns and external best practices, surfaces conflicts as candidate Phase 2 questions
- **brainstorm**: Graceful degradation for all 4 research permutations (both succeed, either fails/skipped, both fail)
- **brainstorm**: Approach-in-questions integration — Phase 2 includes approach selection questions when research reveals multiple valid approaches, with tradeoff hints per option
- **brainstorm**: Phase 3 Resolve Approach fallback — lightweight approach resolution only when not addressed in Phase 2, with skip conditions for already-resolved or single-obvious-approach cases
- **brainstorm**: Progressive quality gates — Research Adequacy gate (Phase 1→2), Topic Coverage gate (Phase 2→3/4), and Pre-Save Checklist (Phase 4) with conversational nudges and user override support
- **brainstorm**: Document template "Why This Approach" guidance updated for 3 resolution paths (Phase 2 questions, Phase 3 fallback, single obvious approach with justification)
- **brainstorm**: Error handling table expanded with quality gate failure scenarios and research agent failure combinations

## [1.34.0] - 2026-03-31

### Added

- **install.sh**: Full OpenCode command body translation — agent invocations rewritten for OpenCode Task tool compatibility
- **install.sh**: Skills installation (`install_skills()`) — copies SKILL.md and references to OpenCode skills directory
- **install.sh**: Nested command directories — commands installed as `commands/aimi/plan.md` for `/aimi:plan` naming
- **install.sh**: Bash permission auto-approval (`install_permissions()`) — configures opencode.json for autonomous execution
- **install.sh**: CLI path resolution rewriting — `CLAUDE_CONFIG_DIR` references replaced with `OPENCODE_CONFIG_DIR`
- **install.sh**: Error message rewriting — recovery instructions point to `./install.sh --to opencode`
- **install.sh**: AskUserQuestion fallback — replaced with natural conversation prompts
- **install.sh**: `disable-model-invocation` workaround — side-effect warning prepended to command bodies
- **install.sh**: Agent model field preservation — `model: haiku` preserved in translated agents

### Fixed

- **install.sh**: Python3 MCP fallback now uses `type: remote` instead of `type: http`

## [1.33.0] - 2026-03-30

### Added

- **install.sh**: Self-contained installer script for OpenCode cross-platform installation (no external dependencies)
- **install.sh**: Translates Claude Code commands and agents to OpenCode-native format
- **install.sh**: Automatic context7 MCP configuration in opencode.json
- **install.sh**: Uninstall support with `--uninstall` flag

### Changed

- **README.md**: Replaced compound-plugin converter instructions with install.sh usage

## [1.32.0] - 2026-03-30

### Added

- **cross-platform**: Cross-platform installation via compound-plugin converter for OpenCode, Codex, Copilot, and auto-detect
- **AIMI_PLUGIN_DIR**: Environment variable support for custom plugin directory resolution in all CLI commands
- **Layer 0**: CLI path resolution in all commands using AIMI_PLUGIN_DIR as Layer 0
- **auto-approve**: Hook patterns for Layer 0 resolution
- **tests**: Coverage for AIMI_PLUGIN_DIR paths

## [1.31.0] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — removes dependency on SKILL.md and reference files
- **brainstorm.md**: Conditional codebase research — skip research phase when no codebase context is available, reducing latency for greenfield brainstorms

### Removed

- **question-patterns.md**: Delete unused reference file from brainstorm skill — content was already inlined into brainstorm.md
- **SKILL.md (brainstorm)**: Remove reference to deleted question-patterns.md; add deprecation notice — skill is retained for reference only

## [1.30.3] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — response parsing table, formatting constraints, contextual question rules, topic addressed signals, input sanitization, pre-save checklist, and incremental validation guidance. Removes all references to the brainstorm skill, reducing token usage per session.

## [1.30.2] - 2026-03-30

### Fixed

- **execute.md, next.md, status.md, swarm.md**: Inline CLI path resolution logic — removes broken `See commands/references/cli-path-resolution.md` references that fail when plugin is installed outside the repo
- **status.md**: Remove broken `See task-format-v3.md` reference
- **SKILL.md (story-executor)**: Remove broken `See task-format-v3.md in ../task-planner/references/` reference — inline key fields with constraints instead
- **CLAUDE.md**: Remove broken `See task-format-v3.md` reference — inline schema version and key fields

## [1.30.1] - 2026-03-27

### Fixed

- **plan.md**: Inline schema v3 structure and dependsOn inference rules — planner agent no longer fails to find reference files when running outside the plugin repo
- **plan.md**: Add `validate-stories` to Phase 4.5 validation step
- **SKILL.md (task-planner)**: Remove broken relative path references to `references/task-format-v3.md`, `references/pipeline-phases.md`, and `references/story-decomposition.md` — inline essential content instead
- **SKILL.md (task-planner)**: Inline git repo auto-scan bash command (previously only in pipeline-phases.md)

## [1.30.0] - 2026-03-26

### Added

- **task-format-v3.md**: Optional per-story `project` field added to task schema v3 — specifies the relative path from AIMI_ROOT to the target git repository for multi-repo story execution
- **aimi-cli.sh**: Project field validation in `cmd_validate_stories()` — rejects absolute paths, path traversal (`..`), and shell metacharacters (`$`, `` ` ``, `;`, `|`, `&`); accepts valid relative paths; backwards compatible when project is absent
- **aimi-cli.sh**: Project field included in `cmd_list_ready --brief` output (`{id, title, priority, dependsOn, project}`)
- **next.md**: Per-story project path resolution — when a story has a `project` field, resolves PROJECT_PATH relative to AIMI_ROOT and passes it to the worker agent prompt; loads CLAUDE.md from PROJECT_PATH when set; backwards compatible when project field is absent
- **execute.md**: Per-project worktree grouping for multi-repo execution — wave stories are grouped by `project` field before worktree creation, worktrees are created within each project's git repo, merge-all runs per-project group
- **execute.md**: Per-project branch setup — creates/checks out the feature branch in each unique project's git repo when stories target different repos
- **execute.md**: Per-project guidelines loading — builds `PROJECT_GUIDELINES_MAP` from each project's CLAUDE.md/AGENTS.md
- **execute.md**: Single-story waves pass `PROJECT_PATH` to worker prompt when story has `project` field
- **execute.md**: Post-loop cleanup handles per-project worktree removal
- **plan.md / story-decomposition.md**: Multi-repo project assignment rules — planner auto-scans subfolders for git repos and assigns `project` field to stories targeting specific repositories
- **test-aimi-cli.sh**: Updated `--brief` key count assertion to include project field

## [1.29.0] - 2026-03-06

### Changed

- **cli-path-resolution.md**: Rewrite CLI resolution with three-layer strategy — global cache, zsh-safe glob fallback, per-project fallback — for reliable path discovery across shells and plugin updates
- **cli-path-resolution.md**: Add equivalent WORKTREE_MGR three-layer resolution section
- **cli-path-resolution.md**: Structure resolution as sequential commands (no compound `&&` or `||`) for auto-approve hook compatibility

### Added

- **aimi-cli.sh**: Global cache functions (`_cache_path`, `_read_cache`, `_write_cache`) for persistent CLI and worktree manager path storage across sessions
- **auto-approve-cli.sh**: Auto-approve patterns for three-layer CLI resolution commands (cache read via `cat`, Layer 1 validation, Layer 2 `bash -c` glob fallback, Layer 2 cache write via `printf`/`mv`/`chmod`, Layer 3 per-project fallback)
- **aimi-cli.sh / worktree-manager.sh**: Tests for global cache read/write/invalidation functions

## [1.28.2] - 2026-03-04

### Fixed

- **plan.md**: Add explicit US-NNN ID format step to Phase 3 story decomposition and checklist — LLM now sees the format requirement before generating IDs, not just in reference docs
- **task-planner/SKILL.md**: Add US-NNN ID format step to Phase 3 between dependency assignment and description writing
- **pipeline-phases.md**: Add US-NNN ID format to Phase 3 and Phase 4 metadata derivation
- **story-decomposition.md**: Strengthen ID format with explicit zero-padding language, regex pattern, and negative examples (US-1, story-1, S1, F1)

### Added

- **aimi-cli.sh**: New `validate-ids` command — validates all story IDs in a tasks file match `^US-[0-9]{3}[a-z]?$` regex, returns JSON with valid/count or errors array
- **plan.md**: Phase 4.5 post-generation validation step — runs `validate-ids` and `validate-deps` after writing tasks.json, with fix-and-rewrite loop if validation fails
- **task-planner/SKILL.md**: Matching Phase 4.5 post-generation validation step

## [1.28.1] - 2026-03-03

### Fixed

- **task-format-v3.md**: Enforce specific role in user story descriptions — `[user]` replaced with `[specific role]` with examples (e.g., "store admin", "developer"), preventing generic "As a user" descriptions
- **story-decomposition.md**: Add "Description Format" section with required format, good/bad examples, and 500-char limit
- **task-planner/SKILL.md**: Add description format step to Phase 3 story decomposition and checklist validation
- **plan.md**: Add description format step to Phase 3 story decomposition and checklist validation

## [1.28.0] - 2026-03-03

### Added

- **aimi-cli.sh**: New `_claude_config_dir()` helper that resolves the Claude config directory from `CLAUDE_CONFIG_DIR` env var, falling back to `~/.claude` -- validates the path is absolute when set, and strips trailing slashes
- **aimi-cli.sh**: All hardcoded `~/.claude/plugins/cache/` glob patterns in `cmd_check_version()`, `cmd_cleanup_versions()`, and help text examples now use the resolved config dir variable, enabling custom config directory support
- **test-aimi-cli.sh**: New test cases for `CLAUDE_CONFIG_DIR` support — validates custom config dir resolution, absolute path enforcement, and trailing slash stripping

### Changed

- **auto-approve-cli.sh**: Dynamic config dir resolution using `CONFIG_DIR_RE` alternation — auto-approve patterns now match both `~/.claude` and custom `CLAUDE_CONFIG_DIR` paths
- **cli-path-resolution.md**: Parameterized CLI resolution example to use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` instead of hardcoded `~/.claude`
- **execute.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`
- **swarm.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`

### Security

- **aimi-cli.sh**: Add `PROJECT_ROOT` export to `find_aimi_root()` — discovers git repository root and exports it for use by other functions
- **aimi-cli.sh**: Add `validate_path_in_project()` function — validates resolved paths are under `PROJECT_ROOT` using realpath comparison, exits with clear error if path escapes project root
- **aimi-cli.sh**: Add path validation to file operation functions (`read_state`, `write_state`, `clear_state_file`, `get_tasks_file`) — prevents directory traversal attacks
- **story-executor/SKILL.md**: Add explicit project-root boundary guardrails — agents must not read or modify files outside the git repository root, worktree paths are explicitly allowed

## [1.27.4] - 2026-03-03

### Fixed

- **execute.md**: Use task branch name as worktree branch prefix instead of hardcoded `aimi-` — worktree branches are now named `[branchName]-[storyId]` (e.g., `feat/feature-name-US-001`) for clearer branch association

## [1.27.3] - 2026-03-03

### Fixed

- **task-format-v3.md**: Add explicit validation rule requiring story `id` fields to match `^US-\d{3}[a-z]?$` format — previously only `dependsOn` references were validated, allowing LLMs to generate invalid IDs like `S1` or `F1` that are rejected by aimi-cli.sh at runtime
- **task-planner/SKILL.md**: Add checklist item enforcing US-NNN format for story IDs in the v3 Schema Validations section

## [1.27.2] - 2026-03-03

### Added

- **react-best-practices skill**: Add AGENTS.md compiled guide with all React and Next.js rules expanded
- **react-native-skills skill**: Add AGENTS.md compiled guide and move rule files into skill's own rules/ directory

### Fixed

- **marketplace.json**: Sync version to match plugin.json

## [1.27.1] - 2026-03-02

### Added

- **react-best-practices skill**: Vercel React and Next.js performance optimization guidelines — 58 rules across 8 categories covering waterfalls, bundle size, server-side performance, and client-side data fetching
- **react-native-skills skill**: React Native and Expo best practices — rules for list performance, animations with Reanimated, UI patterns, image handling, navigation, monorepo configuration, and platform-specific optimizations

## [1.27.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `get-story <id>` command for on-demand story fetching — returns full story JSON for a single story by ID, enabling lazy loading instead of bulk extraction

### Changed

- **execute.md**: Two-phase story loading — wave selection uses `list-ready --brief` (returns `{id, title, priority, dependsOn}` stubs), full story data fetched via `get-story <id>` per story after `mark-in-progress` (claim-then-fetch pattern)
- **execute.md**: Single-story wave path now follows: `list-ready --brief` -> `mark-in-progress` -> `get-story` -> build prompt -> Task
- **execute.md**: Multi-story wave path now follows: `list-ready --brief` -> select -> `mark-in-progress` all -> `get-story` each -> create worktrees -> spawn Tasks
- **execute.md**: Error handling for `get-story` failures: marks story failed, cascade-skips dependents, continues with remaining stories in wave
- **execute.md**: Multi-story wave gracefully degrades — if fetch failures reduce to 1 story, falls back to single-story path (no worktree overhead)

## [1.26.2] - 2026-03-02

### Fixed

- **execute.md**: Added `subagent_type` guard (`IMPORTANT: Do NOT change subagent_type`) to Task spawn ensuring agents never substitute `story-executor` as an agent type
- **next.md**: Added `subagent_type` guard comments to both Task spawn locations (line 86 and retry at line 122), matching the pattern in execute.md — prevents agents from substituting `story-executor` as an agent type

### Added

- **story-executor SKILL.md**: Added Tools section documenting available capabilities (Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Task) for agents spawned within story execution

## [1.26.1] - 2026-03-02

### Changed

- **Acceptance criterion limit increased from 300 to 600 chars** across CLI validation, schema docs, skill references, and command checklists (aimi-cli.sh, task-format-v3.md, story-decomposition.md, SKILL.md, plan.md, CLAUDE.md, README.md)

## [1.26.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `--brief` flag on `list-ready` command — outputs a summary line (count + story IDs) instead of full JSON story objects, reducing output for wave orchestration
- **aimi-cli.sh**: `--counts-only` flag on `status` command — returns aggregate counts (`pending`, `in_progress`, `completed`, `failed`, `skipped`, `total`) without the `userStories` array, enabling lightweight progress checks in wave loops
- **aimi-cli.sh**: `status` dispatch updated to `shift; cmd_status "$@"` pattern for flag forwarding

### Changed

- **aimi-cli.sh**: `mark-in-progress`, `mark-completed`, `mark-failed`, `mark-skipped` commands now return minimal `{id, status}` JSON confirmation instead of the full story object, reducing output noise in agent loops

## [1.25.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `find_aimi_root()` auto-discovery — CLI walks up the directory tree from CWD to find `.aimi/`, eliminating silent failures when invoked from subdirectories
- **test-aimi-cli.sh**: Test isolation via `cd "$TEST_DIR"` and `trap` cleanup; new auto-discovery tests (subdirectory + not-found)
- **cli-path-resolution.md**: CWD Auto-Discovery section documenting the new behavior
- **CLAUDE.md**: CWD contract documented in both root and plugin CLAUDE.md files

## [1.24.1] - 2026-03-02

### Added

- **auto-approve-cli.sh**: Docker auto-approve patterns (5–10) for `/aimi:swarm` commands
  - Pattern 5: `docker version` availability check
  - Pattern 6: `docker run --rm` with `--name aimi-swarm-*` and `--label aimi-swarm` (worker containers)
  - Pattern 7: `docker container ls` with `--filter name=aimi-swarm-` (container listing)
  - Pattern 8: `docker rm -f` with validated `aimi-swarm-*` container names (cleanup)
  - Pattern 9: `docker container prune -f --filter label=aimi-swarm` (safety net)
  - Pattern 10: `docker ps --filter name=aimi-*` (status/cleanup checks)
- All Docker patterns enforce aimi- prefix on container names and reject shell metacharacters

## [1.24.0] - 2026-03-02

### Changed

- **swarm.md**: Complete rewrite — replace Docker/ACP/Sysbox architecture with Team orchestration + git worktrees + simplified `docker run --rm` containers
- **swarm.md**: New frontmatter with Team/Docker/Worktree allowed-tools (removed SANDBOX_MGR, BUILD_IMG)
- **swarm.md**: Step 0 resolves only $AIMI_CLI and $WORKTREE_MGR (no SANDBOX_MGR or BUILD_IMG)
- **swarm.md**: Workers run `docker run --rm` with volume-mounted worktrees and `npx claude` inside generic `node:22-slim` image
- **swarm.md**: Team lead reads task file content and passes it in worker prompt (no reliance on task file in worktree)
- **swarm.md**: `status` subcommand reads task files directly (no swarm-state.json)
- **swarm.md**: `cleanup` subcommand removes aimi-* worktrees and Docker containers
- **swarm.md**: Merge conflict handling preserves worktrees for manual inspection

### Removed

- **docker-sandbox skill**: Removed entire skill (sandbox-manager.sh, build-project-image.sh, acp-adapter.py, Dockerfile.base)
- **swarm.md**: All references to Sysbox runtime, ACP protocol, sandbox-manager, build-project-image
- **swarm.md**: swarm-state.json state management (replaced by Team task list)
- **swarm.md**: `resume` subcommand (Team workers are foreground, no detached containers to resume)
- **swarm.md**: State reconciliation subroutine (no persistent container state to reconcile)
- **swarm.md**: Container provisioning with Sysbox-isolated containers
- **swarm.md**: ACP adapter invocation via docker exec/docker cp

## [1.23.2] - 2026-03-02

### Removed

- **auto-approve-cli.sh**: Remove swarm-* entries from CLI subcommand whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Remove Pattern 5 (SANDBOX_MGR= assignment) and Pattern 6 ($SANDBOX_MGR invocation)
- **auto-approve-cli.sh**: Remove Pattern 7 (BUILD_IMG= assignment) and Pattern 8 ($BUILD_IMG invocation)
- **auto-approve-cli.sh**: Remove Pattern 9 (docker exec aimi-* for ACP adapter)
- **auto-approve-cli.sh**: Remove Pattern 10 (docker cp for ACP payload files)

## [1.23.1] - 2026-03-02

### Changed

- **commands**: Extract CLI path resolution boilerplate to shared reference at `commands/references/cli-path-resolution.md`
- **execute.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **status.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **next.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **swarm.md**: Replace AIMI CLI resolution block in Step 0 with pointer to shared reference

## [1.23.0] - 2026-03-01

### Added

- **swarm.md**: Subscription auth detection in Step 2.5 — checks for `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
- **swarm.md**: `CLAUDE_AUTH=subscription` variable set when subscription credentials found
- **swarm.md**: `--mount-claude-config` flag passthrough to `sandbox-manager.sh create` when subscription auth detected
- **swarm.md**: Credential summary now displays `Claude` field showing subscription auth status

### Changed

- **swarm.md**: `ANTHROPIC_API_KEY` check is now a warning (not hard stop) when subscription auth is available
- **swarm.md**: Hard stop message updated to mention both `ANTHROPIC_API_KEY` and Claude config directory options
- **swarm.md**: Resume subcommand container recreation now passes `--mount-claude-config` when subscription auth detected
- **swarm.md**: Resume fan-out re-detection now includes `CLAUDE_AUTH` alongside `AUTH_METHOD`

## [1.22.0] - 2026-03-01

### Added

- **Dockerfile.base**: Pre-populate SSH known_hosts for GitHub, GitLab, and Bitbucket during image build
- **sandbox-manager.sh**: New `--ssh-agent` flag to forward host SSH_AUTH_SOCK into containers
- **acp-adapter.py**: SSH clone support with protocol detection (git@/ssh:// vs https://)
- **swarm.md**: Credential auto-detection step (Step 2.5) — detects ANTHROPIC_API_KEY, GITHUB_TOKEN via env/gh-cli/SSH agent
- **swarm.md**: Git remote fallback chain — tries origin, upstream, then first available remote
- **swarm.md**: AUTH_METHOD-to-protocol mismatch warnings (SSH auth with HTTPS remote, and vice versa)
- **swarm.md**: `--ssh-agent` flag passthrough in container provisioning when SSH auth detected
- **swarm.md**: Container creation command logging for debugging
- **swarm.md**: Resume subcommand now uses the same fallback chain and credential detection

### Fixed

- **swarm.md**: No longer hard-fails when `origin` remote is missing — falls back to other remotes
- **swarm.md**: Resume subcommand no longer hard-codes `git remote get-url origin`
- **acp-adapter.py**: SSH URLs no longer attempt HTTPS credential helper setup

## [1.21.0] - 2026-03-01

### Changed

- **README.md**: Added Skills section documenting all 17 skills (4 core, 6 development/style, 4 tooling/automation, 3 disabled/reference)
- **README.md**: Added Agents section documenting all 28 agents with descriptions per category
- **README.md**: Updated Components table from 4 skills to 17 skills
- **README.md**: Updated Table of Contents with Skills and Agents links
- **orchestrating-swarms SKILL.md**: Replaced all `compound-engineering:*` agent type references with `aimi-engineering:*` equivalents
- **orchestrating-swarms SKILL.md**: Updated agent lists to match actual aimi-engineering agents (removed non-existent `git-history-analyzer`, `repo-research-analyst`)

### Fixed

- **README.md**: Fixed stale `/aimi:plan-to-tasks` reference in troubleshooting → `/aimi:plan`
- **README.md**: Fixed "Check both plugins" → "Check plugin" in installation verification

### Removed

- **orchestrating-swarms SKILL.md**: All `compound-engineering` references eliminated — zero remaining in active plugin code

## [1.20.0] - 2026-03-01

### Changed

- **`check-version` CLI subcommand**: `_extract_version_from_path()` now uses bash parameter expansion (`${path%/*}`, `${no_scripts##*/}`) instead of `dirname`/`basename` forks — eliminates 3 subshell spawns per call
- **`check-version` CLI subcommand**: `current` status path uses `printf` instead of `jq -n` for JSON output — eliminates 1 jq fork on the happy path
- **`check-version` `--quiet` flag**: Suppresses all stderr warnings (e.g., stale/missing cli-path) for clean machine-readable output
- **`check-version` `--fix` flag**: Auto-updates `cli-path` via `write_state` on stale detection and outputs `{"status":"fixed",...}` with exit 0 instead of `{"status":"stale",...}` with exit 1
- **`check-version` dispatch table**: Now passes `"$@"` to `cmd_check_version` for flag forwarding
- **Command version-check blocks**: Consolidated multi-line `check-version` + jq parsing + `init-session` re-stamp in `execute.md`, `status.md`, `next.md`, and `swarm.md` into single `$AIMI_CLI check-version --quiet --fix` call — eliminates `2>/dev/null`, `VERSION_CHECK`, `VERSION_EXIT`, `STORED_VER`, `LATEST_VER` variables and jq dependency from version-check sections

### Added

- **`check-version` `--quiet` and `--fix` tests**: Tests for `--quiet` flag (suppressed stderr), `--fix` flag (auto-update on stale), combined `--quiet --fix` flags, and backward compatibility (no-flags behavior unchanged)

### Fixed

- **CHANGELOG.md**: Removed redundant `[1.18.1]` entry that duplicated content from `[1.18.0]`
- **auto-approve-cli.sh path traversal regex**: Version segments in plugin path now require digit-first pattern (`[0-9][0-9.]*`) — prevents crafted directory names from bypassing path validation

### Security

- **auto-approve-cli.sh `has_metacharacters()`**: Added `[<>]` character class to the first grep pattern — now blocks `>`, `>>`, `<`, `<<` redirection operators in addition to existing `;`, `&&`, `||`, backtick, and `$()` patterns

## [1.19.0] - 2026-03-01

### Added

- **`check-version` CLI subcommand**: Compares running plugin version against installed version on disk — returns JSON `{running, installed, match}` result; warns user on mismatch and triggers `init-session` to refresh `cli-path`
- **`cleanup-versions` CLI subcommand**: Finds and removes stale plugin versions from `~/.claude/plugins/cache/` — keeps only the latest installed version, returns JSON `{kept, removed: [paths]}` result
- **Step 0 version check integration**: All four execution commands (`execute.md`, `status.md`, `next.md`, `swarm.md`) now call `$AIMI_CLI check-version` after glob resolution — warns user on version mismatch and auto-updates `cli-path` via `init-session`; does NOT call `cleanup-versions` (cleanup is manual-only)
- **auto-approve-cli.sh whitelist**: Added `check-version` and `cleanup-versions` to the permitted subcommand list for auto-approval during task execution
- **test-aimi-cli.sh**: New tests covering `check-version` (match and mismatch scenarios) and `cleanup-versions` (no stale versions, stale version removal)

## [1.18.0] - 2026-03-01

### Added

- **Dockerfile.base**: COPY `acp-adapter.py` into base image at `/opt/aimi/acp-adapter.py` — containers now have the ACP adapter available for `docker exec` invocation
- **acp-adapter.py `provision_repo()`**: Repository cloning and branch checkout inside containers — clones `repoUrl`, configures GITHUB_TOKEN credential helper, checks out target branch (with fallback for new branches), verifies task file exists
- **acp-adapter.py `--input` flag**: File-based alternative to stdin for receiving task-request payloads — enables auto-approve-compatible `docker cp` + `docker exec --input` pattern
- **acp-adapter.py env var value sanitization**: `validate_env_var_value()` rejects values containing newlines, null bytes, or shell metacharacters (`;`, `&&`, `||`, backticks, `$(`)
- **acp-adapter.py progress throttling**: Progress emissions throttled to at most once every 2 seconds (time-based), reducing NDJSON volume by 90%+ with final line always emitted
- **acp-adapter.py concurrent stderr drain**: `threading.Thread` drains stderr concurrently while streaming stdout, preventing 64KB pipe buffer deadlock
- **sandbox-manager.sh `--container-id` and `--swarm-id`**: Optional flags for `cmd_create` to pass identity env vars into containers for ACP message envelopes
- **sandbox-manager.sh advisory disk limit**: Attempts `--storage-opt size=` and falls back gracefully with warning if storage driver doesn't support it
- **swarm.md non-interactive flags**: `--all`, `--files`, `--force`, `--append` flags skip AskUserQuestion prompts for fully autonomous agent-to-agent orchestration
- **auto-approve-cli.sh Pattern 9/10**: `docker exec` with optional `--input` flag and `docker cp` for ACP payload delivery — restricted to `aimi-` prefixed containers
- **SKILL.md total resource table**: Shows CPU, RAM, and swap consumption at 2, 4, and 8 containers with host sizing guidance (2x container RAM recommended)

### Fixed

- **auto-approve-cli.sh path regex**: Changed `skills/sandbox/` to `skills/docker-sandbox/` in `SANDBOX_MGR` and `BUILD_IMG` patterns to match actual plugin directory structure
- **sandbox-manager.sh swap default**: Changed `AIMI_SANDBOX_SWAP` from `4g` to `8g` — Docker's `--memory-swap` is total (memory + swap), so `4g` with `4g` memory meant zero actual swap
- **sandbox-manager.sh consolidated inspect**: Replaced 5 separate `docker inspect` calls in `cmd_status` with a single call using combined Go template format string
- **aimi-cli.sh swarm-cleanup**: Updated jq filter to also exclude `stopped` status (was only excluding `completed` and `failed`)
- **aimi-cli.sh `_validate_container_name`**: Harmonized with `sandbox-manager.sh` — now requires `aimi-` prefix and same character set (`^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`)
- **swarm.md Step 5 ACP invocation**: Changed from piped `echo | docker exec -i` to file-based `docker cp` + `docker exec --input` pattern — works with auto-approve hooks

## [1.17.1] - 2026-03-01

### Fixed

- **auto-approve-cli.sh**: Fixed `SANDBOX_MGR` and `BUILD_IMG` path validation regex patterns — changed `skills/sandbox/` to `skills/docker-sandbox/` to match actual plugin directory structure and the glob patterns used in swarm.md Step 0

## [1.17.0] - 2026-03-01

### Changed

- **`/aimi:swarm` status subcommand**: Now runs automatic state reconciliation before displaying status table — detects zombie entries (containers in state but missing from Docker), silent completions, silent failures, unexpected stops, and already-started containers
- **`/aimi:swarm` resume subcommand**: Enhanced with full crash recovery — reconciles state first, identifies resumable containers, recreates failed containers for retry, skips running/completed containers, fans out only pending containers
- **`/aimi:swarm` cleanup subcommand**: Enhanced with per-container removal reporting (removed vs already gone), proper state entry cleanup count, and graceful handling of missing swarms

### Added

- **State reconciliation subroutine** in swarm.md: Shared procedure that runs before `status` display and `resume` operations, comparing `swarm-state.json` entries against actual Docker daemon state via `sandbox-manager.sh status`
- **Zombie detection documentation**: New "State Reconciliation" reference section documenting detection scenarios (zombie, silent completion/failure, unexpected stop, already started), zombie causes, and idempotency guarantees

### Security

- **auto-approve-cli.sh**: Added `SANDBOX_MGR` patterns with path validation and subcommand whitelist (create, remove, list, status, cleanup, check-runtime)
- **auto-approve-cli.sh**: Added `BUILD_IMG` patterns with path validation for build-project-image.sh invocation
- **auto-approve-cli.sh**: Added swarm subcommands to `$AIMI_CLI` whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Added `docker exec -i aimi-*` pattern for ACP adapter communication — restricted to `aimi-` prefixed containers running `python3 /opt/aimi/acp-adapter.py` only (no wildcard Docker approvals)

## [1.16.0] - 2026-03-01

### Added

- **`/aimi:swarm` command**: Multi-task Docker sandbox orchestration for parallel feature execution
  - Discovers `.aimi/tasks/*-tasks.json` files, presents multi-select list to user
  - Supports `--file <path>` flag for single-file execution
  - Provisions Sysbox-isolated Docker containers via `sandbox-manager.sh` for each task file
  - Builds per-project images via `build-project-image.sh` with checksum-based rebuild skipping
  - Fans out parallel Task agents, each communicating with its container via ACP adapter (`docker exec -i`)
  - Tracks execution via `swarm-state.json` using CLI swarm-* subcommands
  - Configurable `maxContainers` limit (default 4, override with `--max <N>`)
  - Subcommands: `status` (view swarm state), `resume` (restart pending containers), `cleanup` (remove containers and state)
  - Handles partial failure: failed containers marked in state, successful ones continue independently
  - Reports summary with per-container status, branch names, and PR URLs

## [1.15.0] - 2026-03-01

### Changed

- **execute.md parallel execution rewrite**: Replaced Team/SendMessage swarm orchestration with foreground fan-out using `run_in_background` Task agents — eliminates Team lifecycle complexity, reduces token overhead, and runs parallel workers directly from the orchestrator's context
- **execute.md Team/SendMessage dependency removed**: Parallel story execution no longer requires TeamCreate, SendMessage, or teammate coordination — workers are spawned as background tasks and polled for completion

### Fixed

- **worktree-manager.sh merge stderr suppression**: Removed `2>/dev/null` from `git checkout` and `git merge` commands in `merge_worktree()` and `merge_all_worktrees()` functions — merge conflicts and failures are now visible in stderr for proper diagnosis

## [1.14.0] - 2026-02-28

### Changed

- **aimi-cli.sh portable `_lock()` function**: Replaces direct `flock` calls with cross-platform locking — Linux uses `flock`, macOS uses atomic `mkdir` spinlock with 10s stale-lock timeout and `trap EXIT` cleanup
- **aimi-cli.sh platform detection at startup**: Caches `_HAS_FLOCK` and `_HAS_REALPATH` to avoid per-call `command -v` overhead
- **aimi-cli.sh `cmd_clear_state`**: Also removes `*.lock.d` directories (mkdir-based lock cleanup)
- **execute.md CLI resolution**: Glob first (always finds latest version), cli-path as fallback only — prevents stale cached path from using old plugin version
- **status.md + next.md CLI resolution**: Consistent with execute.md — glob first, cli-path fallback (was glob-only, no fallback)

## [1.13.0] - 2026-02-27

### Added

- **aimi-cli.sh `resolve_path()` helper**: POSIX-compatible path resolution (uses `realpath` when available, falls back to `cd`+`pwd`+`basename` for macOS)
- **aimi-cli.sh `reset-orphaned` subcommand**: Atomically marks all `in_progress` stories as `failed`, returns `{count, reset: [ids]}` — replaces fragile `status | jq` pipeline
- **aimi-cli.sh `validate_story_exists()` function**: Verifies story ID exists in tasks file before mutation; all `mark-*` and `cascade-skip` commands now exit 1 with clear error for non-existent IDs
- **aimi-cli.sh `cli-path` state file**: `init-session` writes CLI's absolute path to `.aimi/cli-path` for reliable resolution across shell sessions
- **aimi-cli.sh stale state warning**: `get_tasks_file()` prints stderr warning when `current-tasks` points to a deleted file, auto-updates state with discovered alternative
- **test-aimi-cli.sh**: 16 new tests (65 total) covering: resolve_path, cli-path, userStories key, story ID existence validation, reset-orphaned (empty + with orphans), stale state warning
- **test-aimi-cli.sh `assert_stderr_contains` helper**: New test helper for validating stderr output

### Changed

- **aimi-cli.sh `cmd_status` output**: Renamed `.stories` key to `.userStories` for consistency with schema v3.0 source field name
- **aimi-cli.sh state files**: `init-session` and `get_tasks_file()` now store absolute paths in `.aimi/current-tasks` (resolves cwd-dependency bugs)
- **aimi-cli.sh `write_state()` and `clear_state_file()`**: Now use `flock` with `$AIMI_DIR/.state.lock` for parallel execution safety
- **aimi-cli.sh `cmd_clear_state`**: Also removes `.state.lock`, `cli-path`, and all `.lock` files under `.aimi/`
- **execute.md Step 0**: CLI resolution now tries `cat .aimi/cli-path` first, falls back to `ls` glob if missing or invalid
- **execute.md orphaned recovery**: Replaced `status | jq` pipeline with `$AIMI_CLI reset-orphaned` subcommand
- **status.md**: Updated example output to use `userStories` key
- **auto-approve-cli.sh**: Added `reset-orphaned` to subcommand whitelist

## [1.12.0] - 2026-02-27

### Added

- **worktree-manager.sh `remove` command**: New `remove <worktree-name>` subcommand for non-interactive worktree cleanup (`git worktree remove --force` + `git branch -D`)
- **worktree-manager.sh `--from` flag**: `create` now supports `create name --from branch` (and positional backward compat)
- **worktree-manager.sh input validation**: `validate_branch_name()` with regex `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`, path containment check via `realpath -m`
- **aimi-cli.sh flock-based file locking**: All 5 mutation functions use `flock -x` advisory locking with unique `mktemp` temp files
- **aimi-cli.sh `validate_story_id()`**: Regex `^US-[0-9]{3}[a-z]?$` validated on all mark-* commands
- **aimi-cli.sh `validate-stories` command**: Checks field lengths (title: 200, description: 500, criterion: 300) and suspicious content patterns for prompt injection defense
- **aimi-cli.sh `maxConcurrency` guard**: Values <= 0 default to 4 in status and metadata commands
- **execute.md orphaned recovery**: Step 1 detects stories stuck in `in_progress` from interrupted runs, resets to `failed`
- **execute.md content validation**: Step 1 calls `validate-stories` before any execution
- **execute.md agent-driven merge conflict resolution**: On merge conflict, spawns a Task agent to attempt resolution before falling back to manual
- **execute.md worker timeout**: Configurable timeout (default 15 min); non-responding workers marked as failed

### Changed

- **worktree-manager.sh**: Removed all interactive `read -r` prompts — create reuses existing worktrees silently, cleanup proceeds without confirmation
- **worktree-manager.sh**: Removed unnecessary `git checkout`/`git pull` from create (worktree add works without checkout)
- **worktree-manager.sh**: `chmod 600` applied to all copied .env files; git commands use `--` separator before branch arguments
- **story-executor SKILL.md**: Fixed contradiction (agents report results, callers handle status via CLI), removed duplicated sections (compact prompt, JS examples, default rules), added `story.notes` placeholder, declared as canonical prompt template
- **execute.md**: Moved `validate-deps` from parallel-only path to shared Step 3.1 — both sequential and parallel validate dependency graph
- **execute.md**: Worker prompt includes `## PREVIOUS NOTES` section with `story.notes` (omitted when empty)
- **execute.md + next.md**: Replaced duplicated inline worker prompts with references to story-executor SKILL.md canonical template (net -96 lines)
- **execute.md + next.md**: Replaced duplicated guideline loading sections with references to story-executor discovery order

### Security

- **auto-approve-cli.sh**: Replaced permissive `$AIMI_CLI` pattern with explicit subcommand whitelist (19 commands) and shell metacharacter rejection
- **auto-approve-cli.sh**: `AIMI_CLI=` assignment now validates path matches expected plugin install directory
- **auto-approve-cli.sh**: Added `WORKTREE_MGR` patterns with path validation and subcommand whitelist (create, remove, merge, list, help)

## [1.11.0] - 2026-02-27

### Removed

- **v2.2 backward compatibility**: All v2.2 schema support removed — v3.0 is now the only supported format
- **plan-to-tasks skill**: Deleted entire `skills/plan-to-tasks/` directory (v2.2-only task generator)
- **detect-schema CLI command**: Removed `detect-schema` command and all dual-schema detection logic from aimi-cli.sh
- **v2.2 code paths in CLI**: Removed `detect_schema()`, `is_v3()`, `cmd_detect_schema()` functions and all if/else version branching
- **v2.2 test fixtures**: Rewrote test suite to v3-only (49 tests, all passing)
- **v2.2 references in docs**: Cleaned all v2.2 mentions from commands (deepen, next, status, execute), execution-rules, task-format-v3, story-decomposition, and CLAUDE.md files

## [1.10.0] - 2026-02-27

### Fixed

- **Plugin CLAUDE.md**: Updated schema example from v2.1 to v3 (status, dependsOn, maxConcurrency)
- **story-executor**: Removed direct tasks file mutation instructions — agents now delegate to CLI for all status updates
- **execution-rules.md**: Updated with v3 status enum and dual-schema documentation
- **deepen.md**: Made schema-aware — detects v3 status field instead of v2.2 passes boolean
- **next.md**: Updated CLI output example with both v3 and v2.2 variants
- **pipeline-phases.md**: Fixed output report from "Schema: 2.2" to "Schema: 3.0"
- **story-decomposition.md**: Fixed conversion rule from `passes: false` to `status: "pending"`

### Changed

- **aimi-cli.sh**: Removed dead code (abandoned jq blocks, duplicated ready-story logic); DRYed cmd_next_story to reuse cmd_list_ready
- **plan-to-tasks**: Added deprecation notice (generates v2.2 only; use task-planner for v3)

### Added

- **test-aimi-cli.sh**: 31 new v3 test cases covering detect-schema, list-ready, mark-in-progress, validate-deps, cascade-skip, dependency resolution, and circular dependency detection (65 total tests)

## [1.9.0] - 2026-02-27

### Added

- **Schema v3 (`task-format-v3.md`)**: New tasks.json schema with dependency graph and parallel execution support
  - `dependsOn` (string[]) for explicit inter-story dependency graphs (DAG)
  - `status` enum (`pending`, `in_progress`, `completed`, `failed`, `skipped`) replacing `passes` boolean
  - `maxConcurrency` metadata field (default 4) for parallel story execution
  - `priority` retained as tiebreaker for stories at same dependency depth
  - Status state machine with valid transitions documented
  - `dependsOn` validation rules: no circular deps, no self-refs, all referenced IDs must exist
  - Backward compatibility with v2.2: auto-detection and fallback behavior
  - Migration guide: v2.2 to v3 conversion rules with priority-layer inference for `dependsOn`

- **Parallel execution in `/aimi:execute`**: Automatic detection and execution of independent stories in parallel
  - Wave-based execution: independent stories run concurrently within waves
  - Team/swarm orchestration for parallel workers using Claude Code Teams
  - Adaptive concurrency: `min(ready stories, maxConcurrency)`
  - Cascade-skip on failure: dependent stories automatically skipped when a dependency fails
  - v2.2 fallback: sequential execution preserved for older schema files
  - v3 with linear deps: runs sequentially without Team/worktree overhead

- **Worktree merge commands** in `worktree-manager.sh`
  - `merge <worktree-name> [--into <branch>]` — merge worktree branch into target
  - `merge-all <branch1> <branch2> ... [--into <branch>]` — sequential multi-merge
  - Merge conflict detection with conflicting file listing
  - Stop-on-conflict behavior for merge-all

- **CLI extensions** for v3 schema support in `aimi-cli.sh`
  - `detect-schema` — returns schema version (`2.2` or `3.0`)
  - `list-ready` — dependency-aware ready story detection (v3)
  - `mark-in-progress` — sets `status: "in_progress"` for a story (v3)
  - `validate-deps` — DAG validation for dependency graph (cycles, missing refs, self-refs)
  - `cascade-skip` — transitive skip on failure for dependent stories

### Changed

- **`/aimi:execute` command**: Rewritten for smart parallel/sequential execution based on schema version and dependency graph shape
- **`story-decomposition.md`**: Updated with `dependsOn` generation rules, layer-based inference, and parallel grouping examples
- **`task-planner` SKILL.md**: Phase 3 and Phase 4 updated for v3 output with `dependsOn` arrays and `status` field
- **`plan.md` command**: Output format updated to v3 schema with `dependsOn` and `status` fields
- **`story-executor` skill**: Added optional `WORKTREE_PATH` variable for parallel worker context; workers report status instead of writing tasks.json directly
- **`/aimi:status` command**: v3 display with status values, dependency info, and wave grouping; v2.2 display unchanged
- **CLI dual-version support**: `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `next-story` all updated for v2.2/v3 compatibility

## [1.8.0] - 2026-02-27

### Added

- **`brainstorm` skill**: Standalone process knowledge for brainstorming sessions
  - `skills/brainstorm/SKILL.md` (229 lines) — hybrid question flow, Ralph-style batched multiple-choice, adaptive exit, YAGNI, design document template
  - `skills/brainstorm/references/question-patterns.md` (240 lines) — formatting rules, scenario batches, response parsing, contextual question generation

### Changed

- **`/aimi:brainstorm` command**: Full rewrite as standalone (no longer wraps compound-engineering)
  - Phase 0: Assess requirements clarity
  - Phase 1: Codebase research via `aimi-codebase-researcher` agent
  - Phase 2: Batched 3-5 multiple-choice questions with "1A, 2C, 3B" shorthand
  - Phase 3: Conditional approaches (only when multiple valid paths exist)
  - Phase 4: Design document capture with slug derivation, collision handling, open questions enforcement
  - Phase 5: Aimi-branded handoff
- **compound-engineering dependency fully eliminated**: All commands and skills are now standalone. Zero external plugin dependencies required.
- **CLAUDE.md**: Dependencies section updated to reflect full independence
- **`aimi-code-simplicity-reviewer` agent**: Updated pipeline artifacts reference
- **`aimi-best-practices-researcher` agent**: Removed `compound-docs` from skill mapping

## [1.7.0] - 2026-02-26

### Added

- **PermissionRequest hook**: Auto-approves `$AIMI_CLI` and `AIMI_CLI=` Bash commands during task execution, eliminating manual permission prompts for CLI operations
  - `hooks/hooks.json` — hook configuration
  - `hooks/auto-approve-cli.sh` — approval script matching only AIMI CLI patterns

## [1.6.0] - 2026-02-25

### Changed

- **Output directory**: All document output paths moved from `docs/` to `.aimi/`
  - `docs/tasks/` → `.aimi/tasks/`
  - `docs/brainstorms/` → `.aimi/brainstorms/`
  - `docs/plans/` → `.aimi/plans/`
  - `docs/solutions/` → `.aimi/solutions/`
- **`aimi-cli.sh`**: `TASKS_DIR` now derived from `$AIMI_DIR` variable (`$AIMI_DIR/tasks`)
- All commands, skills, and agents updated with new paths

## [1.5.2] - 2026-02-25

### Changed

- **`/aimi:plan` command**: Inlined full task-planner pipeline directly into plan.md to fix double skill loading issue (both `plan` command and `task-planner` skill were loading into context)
- **`task-planner` skill**: Set to `user-invocable: false` since pipeline is now embedded in `/aimi:plan`

## [1.5.1] - 2026-02-25

### Added

- **Context7 MCP server**: Registered `context7` HTTP MCP server directly in plugin.json so `aimi-best-practices-researcher` and `aimi-framework-docs-researcher` can access documentation without compound-engineering installed

## [1.5.0] - 2026-02-25

### Added

- **28 aimi-native agents**: Standalone agents that eliminate compound-engineering dependency for plan, review, and deepen workflows
  - 4 research agents: `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`
  - 15 review agents: `aimi-architecture-strategist`, `aimi-security-sentinel`, `aimi-code-simplicity-reviewer`, `aimi-performance-oracle`, `aimi-agent-native-reviewer`, `aimi-data-integrity-guardian`, `aimi-data-migration-expert`, `aimi-deployment-verification-agent`, `aimi-schema-drift-detector`, `aimi-pattern-recognition-specialist`, `aimi-dhh-rails-reviewer`, `aimi-kieran-rails-reviewer`, `aimi-kieran-typescript-reviewer`, `aimi-kieran-python-reviewer`, `aimi-julik-frontend-races-reviewer`
  - 3 design agents: `aimi-design-implementation-reviewer`, `aimi-design-iterator`, `aimi-figma-design-sync`
  - 1 docs agent: `aimi-ankane-readme-writer`
  - 5 workflow agents: `aimi-spec-flow-analyzer`, `aimi-bug-reproduction-validator`, `aimi-every-style-editor`, `aimi-lint`, `aimi-pr-comment-resolver`

### Changed

- **`task-planner` skill**: All agent references updated from `compound-engineering:*` to `aimi-engineering:*`
- **`/aimi:deepen` command**: Now uses `aimi-engineering:research:aimi-codebase-researcher` instead of compound agent
- **`/aimi:review` command**: Fully rewritten as standalone multi-agent review command. No longer wraps `/workflows:review`. Invokes parallel aimi-native review agents with default agents (architecture, security, simplicity, performance, agent-native), conditional migration agents, language-specific reviewers, and findings synthesis with severity categorization.
- **Reduced compound-engineering dependency**: Only `/aimi:brainstorm` still requires compound-engineering. Plan, deepen, and review are now fully standalone.

## [1.4.0] - 2026-02-25

### Added

- **`task-planner` skill**: New skill that generates `tasks.json` directly from a feature description. Full pipeline: brainstorm detection, local/external research (parallel), spec-flow analysis, story decomposition, and direct JSON output — no intermediate markdown plan.
  - `skills/task-planner/SKILL.md` (160 lines) — orchestration overview and agent invocation syntax
  - `skills/task-planner/references/pipeline-phases.md` — detailed phase-by-phase instructions
  - `skills/task-planner/references/story-decomposition.md` — sizing, ordering, validation rules

### Changed

- **`/aimi:plan` command**: No longer wraps compound-engineering `/workflows:plan`. Now invokes the `task-planner` skill directly, producing `tasks.json` without an intermediate plan markdown file.
- **`/aimi:deepen` command**: No longer wraps compound-engineering `/deepen-plan`. Now enriches `tasks.json` directly — spawns research agents per pending story, improves acceptance criteria, splits oversized stories, preserves completed story state. Accepts optional path argument; auto-discovers most recent tasks.json if omitted.
- **Schema version**: Bumped from 2.1 to 2.2
  - `metadata.planPath` is now optional/nullable (`null` when generated by task-planner)
  - `metadata.brainstormPath` documented as optional context reference
  - Backward compatible with v2.1 — existing files work without modification
- **`plan-to-tasks` skill**: Updated to output schema v2.2. Added note directing users to `task-planner` for direct generation. Remains functional as standalone converter for external markdown plans.

## [1.3.1] - 2026-02-25

### Fixed

- **`/aimi:plan` not loading `plan-to-tasks` skill**: Step 4 used ambiguous pseudo-syntax (`Skill: plan-to-tasks`) inside a code block, which Claude interpreted as descriptive text instead of an actionable tool invocation
  - Replaced with explicit instructions to call the Skill tool with `skill: "aimi-engineering:plan-to-tasks"`
  - Added "Do NOT generate tasks.json from memory or inline" guardrail
  - Added fallback: read `SKILL.md` directly if Skill tool is unavailable
  - Updated Step 5 to clarify the skill handles output writing

## [1.3.0] - 2026-02-24

### Fixed

- **CLI script path resolution**: Commands now resolve `aimi-cli.sh` from plugin install directory (`~/.claude/plugins/cache/*/aimi-engineering/*/scripts/`) instead of using `./scripts/` relative path which fails when cwd is the user's project
  - Updated `execute.md`, `next.md`, `status.md` with Step 0: Resolve CLI Path
  - Added `$AIMI_CLI` variable pattern (matches compound-engineering's plugin path convention)
  - Updated `allowed-tools` frontmatter to permit `$AIMI_CLI` execution
  - Updated README architecture section and CLI help examples

## [1.2.2] - 2026-02-24

### Fixed

- **Schema structure divergences** across 7 files:
  - `commands/plan.md`: Schema version output said "2.0" instead of "2.1"
  - `README.md`: jq example referenced non-existent top-level `project`/`branchName` fields (now uses `metadata.*`)
  - `README.md`: Removed stale `steps`/`taskType` from field length limits table (fields removed in v2.1)
  - `README.md`: Updated intro text (removed references to removed `steps`/`qualityChecks` fields)
  - `README.md`: Added missing Root Fields table, moved `schemaVersion` out of Metadata table
  - `README.md`: Added missing `brainstormPath` to Metadata Fields table
  - Root `CLAUDE.md`: Replaced obsolete pre-v2.0 schema (missing `schemaVersion`, `metadata` wrapper) with current v2.1 structure
  - `marketplace.json`: Synced version from "0.2.0" to "1.2.2" (matching plugin.json)

## [1.2.1] - 2026-02-24

### Changed

- **Schema version bump**: `schemaVersion` updated from "2.0" to "2.1" across all files
  - README.md, CLAUDE.md, SKILL.md, task-format.md, test-aimi-cli.sh

## [1.2.0] - 2026-02-24

### Added

- **aimi-cli.sh**: Single bash script for deterministic task file operations
  - 13 subcommands: `init-session`, `find-tasks`, `status`, `metadata`, `next-story`, `current-story`, `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `get-branch`, `get-state`, `clear-state`
  - State management via `.aimi/` directory (persists across `/clear`)
  - Atomic file updates using temp file + mv pattern
  - Comprehensive test suite (33 tests)
- **Story-by-story execution**: Execute one story at a time with `/clear` between stories
- `.gitignore` entry for `.aimi/` state directory

### Changed

- **Commands updated to use CLI instead of inline jq**:
  - `/aimi:execute` - Uses `init-session`, `count-pending`, `get-state`
  - `/aimi:next` - Uses `next-story`, `mark-complete`, `mark-failed`, `mark-skipped`
  - `/aimi:status` - Uses `status` command
- Simplified command files (less error-prone, no jq interpretation by AI)

### Fixed

- AI hallucination when interpreting bash commands embedded in markdown
  - Variable substitution errors
  - Command sequence errors
  - jq query modifications
  - Path/filename errors

## [1.1.0] - 2026-02-17

### Changed

- Restored v2.0 tasks.json schema with task-specific fields
  - Re-added `taskType`, `steps`, `relevantFiles`, `qualityChecks` to story schema
  - `schemaVersion` changed from "3.0" to "2.0"
  - Improved agent execution with domain-specific guidance
  - All story `steps` start with "Read CLAUDE.md and AGENTS.md for project conventions"

### Added

- Automated taskType detection via keyword matching (7 types)
  - `prisma_schema` - Database schema/migration changes
  - `server_action` - Server-side logic and actions
  - `react_component` - React/UI component work
  - `api_route` - API endpoint implementation
  - `utility` - Helper functions and services
  - `test` - Test implementation
  - `other` - Fallback for unclassified tasks
- Predefined step templates for each taskType
- `relevantFiles` inference from story content + taskType defaults
- `qualityChecks` assignment based on taskType
- New placeholders in prompt template: `[TASK_TYPE]`, `[STEPS_ENUMERATED]`, `[RELEVANT_FILES_BULLETED]`, `[QUALITY_CHECKS_BULLETED]`

### Removed

- v3.0 schema (minimal field set without task-specific guidance)

### Migration

Existing v3.0 tasks.json files must be regenerated:

```bash
/aimi:plan [feature]
```

## [1.0.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v3.0 with Ralph-style flat stories
  - Flat story structure (no nested `tasks[]` array)
  - Story IDs changed from `story-0` to `US-001` format
  - Added `priority` field for explicit execution order
  - Simple `passes: true/false` state tracking (no per-task status)
  - Per-story `acceptanceCriteria` array (moved from root level)
  - Required "Typecheck passes" in every story's acceptance criteria
  - `successMetrics` at root level for tracking improvements

### Added

- **Priority-based execution**: `/aimi:next` uses jq `sort_by(.priority)` to select next story
- **Project guidelines loading**: CLAUDE.md/AGENTS.md loaded before implementation
- **Aimi default rules**: Fallback commit format and quality checks when no project guidelines exist
- Brainstorm document: `docs/brainstorms/2026-02-16-ralph-style-tasks-brainstorm.md`

### Updated

- `plan-to-tasks` skill updated for flat story conversion
- `task-format.md` reference rewritten for v3.0 schema
- `story-executor` skill simplified for flat structure
- `execution-rules.md` updated with "Read Project Guidelines" as Step 1
- `/aimi:next` loads guidelines before building Task prompt
- `/aimi:execute` derives branch name from metadata title
- `/aimi:status` shows priority in story list

### Removed

- Nested `tasks[]` array structure
- `estimatedEffort` field (agent determines pace from story scope)
- `taskType`, `steps`, `relevantFiles`, `patternsToFollow` fields
- Root-level `acceptanceCriteria` (now per-story)
- `deploymentOrder` field

### Migration

Existing tasks.json files need to be regenerated:

```bash
/aimi:plan-to-tasks docs/plans/your-plan.md
```

## [0.9.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v2.0 with nested tasks structure
  - Stories contain nested `tasks[]` array with task objects
  - Added `metadata` object with `title`, `type`, `createdAt`, `planPath`, `brainstormPath`
  - Added `successMetrics` object for tracking improvements
  - Tasks have `id`, `title`, `description`, `file`, `action`, `status` fields
  - Added `estimatedEffort` field to stories

### Updated

- `plan-to-tasks` skill updated for new schema structure
- `task-format.md` reference rewritten for v2.0 schema
- `story-executor` skill updated to work with nested tasks
- `execution-rules.md` updated for task-based execution flow

### Removed

- Old schema fields: `taskType`, `steps`, `relevantFiles`, `patternsToFollow`, `qualityChecks` (per-story)

## [0.8.0] - 2026-02-16

### Fixed

- **Aimi-Branded Messaging**: All commands now show only Aimi commands in next steps
  - Commands still execute compound-engineering workflows under the hood
  - Post-completion options are intercepted and replaced with Aimi equivalents
  - Command mapping: `/workflows:plan` → `/aimi:plan`, `/deepen-plan` → `/aimi:deepen`, etc.

### Changed

- `/aimi:brainstorm` - Added Step 2 with Aimi-branded next steps override
- `/aimi:plan` - Added Step 6 with Aimi-branded report override
- `/aimi:deepen` - Added Step 6 with Aimi-branded report override
- `/aimi:review` - Added Step 2 with Aimi-branded summary override
- All commands include "NEVER mention" guidance to prevent compound-engineering leakage

## [0.7.0] - 2026-02-16

### Added

- **Project Guidelines Injection**: CLAUDE.md/AGENTS.md content injected into Task prompts
  - Discovery order: CLAUDE.md (root) → AGENTS.md (directory) → Aimi defaults
  - Small files (<2KB) inlined, larger files referenced
- **Aimi Default Commit/PR Rules**: Fallback rules when project lacks CLAUDE.md/AGENTS.md
  - `default-rules.md` reference file with commit format, behavior, and PR guidelines
  - Always applied if project files lack commit/PR section
- **Fresh Context Per Story**: Each Task agent starts with clean context (no memory carryover)

### Changed

- **BREAKING:** Renamed `[PATTERNS_CONTENT]` placeholder to `[PROJECT_GUIDELINES]`
- Story-executor now uses `get_project_guidelines()` instead of `get_patterns_content()`
- Execution rules Step 1 now reads CLAUDE.md/AGENTS.md instead of progress.md
- Learnings stored in CLAUDE.md (project-wide) or AGENTS.md (module-specific)

### Removed

- `patternsToFollow` field is now optional (guidelines discovery is automatic)

## [0.6.0] - 2026-02-16

### Changed

- **BREAKING:** Removed `progress.md` - all state now in `tasks.json`
  - No more progress.md initialization in `/aimi:plan`
  - No more progress entry appending in `/aimi:next`
  - No more CODEBASE_PATTERNS from progress.md
- Simplified prompt template (removed progress.md references)
- Simplified interpolation function signature

### Removed

- `progress.md` file and all references
- CODEBASE_PATTERNS placeholder
- `Bash(grep:*)`, `Bash(cat:*)`, `Bash(tail:*)` from allowed-tools (no longer needed)

## [0.5.1] - 2026-02-16

### Fixed

- `/aimi:next` now ensures `progress.md` is always updated after task completion
  - Step 5a: Verify tasks.json updated, fallback update via jq if not
  - Step 5b: Check if progress entry exists, append if missing
- `/aimi:status` now uses jq for minimal context usage
- `/aimi:status` shows skipped stories with `✗` indicator
- `/aimi:status` displays recent activity from progress.md

### Added

- `Bash(grep:*)`, `Bash(cat:*)` to `/aimi:next` allowed-tools
- `Bash(tail:*)` to `/aimi:status` allowed-tools

## [0.5.0] - 2026-02-16

### Added

- **jq-based task extraction**: Only load ONE story into context at a time
  - `/aimi:execute` extracts only metadata (project, branchName, counts)
  - `/aimi:next` extracts only the next pending story
- **`skipped` field**: Prevents infinite loop on failed tasks
  - When user says "skip", sets `skipped: true` on the story
  - jq query filters: `passes == false AND skipped != true`

### Changed

- `/aimi:execute` now shows separate counts for pending, completed, and skipped
- `/aimi:next` uses jq instead of reading full tasks.json
- Added `Bash(jq:*)` to allowed-tools for both commands

### Fixed

- Infinite loop when a task keeps failing (now properly excluded after skip)

## [0.4.2] - 2026-02-16

### Fixed

- `/aimi:plan` now properly runs compound-engineering's `/workflows:plan` first, then automatically converts to tasks.json
- Added explicit two-phase execution flow with no user prompts between phases
- Added `Skill(compound-engineering:workflows:plan)` to allowed-tools

### Added

- Error handling section in `/aimi:plan` for failed or cancelled operations

## [0.4.1] - 2026-02-16

### Security

- **Path Traversal Prevention**: Added comprehensive path validation for `relevantFiles` and `patternsToFollow`
  - Blocks `..` sequences, absolute paths, protocol prefixes, null bytes
  - Blocks access to sensitive paths (`.git/`, `.env`, `.ssh/`)
- **Expanded Command Injection Blocklist**: Now blocks `&&`, `||`, `>`, `>>`, `<`, newlines, and more
- **Strengthened Prompt Injection Defenses**: Added patterns for role manipulation, system prompt extraction, and boundary breaking

### Added

- **Schema Versioning**: `schemaVersion` field in tasks.json (v2.0 for task-specific steps)
- **qualityChecks Field**: Explicit verification commands per story (typecheck, test, lint)
- **AGENTS.md Content Injection**: Small AGENTS.md files (< 2KB) are inlined directly in prompts
- **Placeholder Interpolation Documentation**: Complete reference for prompt template placeholders
- **Pattern Matching Tie-Breaking Rules**: Deterministic selection when multiple patterns match

### Changed

- **Naming Consistency**: Renamed `file_patterns` to `filePatterns` (camelCase) in pattern library
- **Simplified Error Messages**: Consistent format: `Error: Story [ID] - [field]: [issue]. Fix: [action].`
- **Consolidated Validation Rules**: task-format.md is now the single source of truth
- **Removed Duplicate Prompt Example**: Task Tool Invocation section now references the main template

### Fixed

- Pattern files now use consistent camelCase for `filePatterns` field

## [0.4.0] - 2026-02-16

### Added

- **Task-Specific Step Generation**: Each story now includes pre-computed, domain-aware execution steps
- **Pattern Library** (`docs/patterns/`): Workflow templates for common task types
  - `prisma-schema.md` - Database schema changes with Prisma
  - `server-action.md` - Next.js server actions
  - `react-component.md` - React component creation
  - `api-route.md` - API endpoint implementation
- **AGENTS.md Discovery**: Automatic discovery and matching of AGENTS.md files to tasks
- **TaskType Inference**: Keyword-based pattern matching with LLM fallback

### Changed

- **BREAKING:** tasks.json schema now requires four new fields per story:
  - `taskType` (string, snake_case, max 50 chars) - Domain classification
  - `steps` (array, 1-10 items, each max 500 chars) - Task-specific execution steps
  - `relevantFiles` (array, max 20 items) - Files to read first
  - `patternsToFollow` (string) - AGENTS.md path or "none"
- `/aimi:next` now validates required fields before execution
- `/aimi:next` prompt template uses story.steps instead of generic execution flow
- `story-executor` skill updated with STEPS, RELEVANT FILES, and PATTERNS sections
- `plan-to-tasks` skill now generates task-specific fields during conversion

### Migration

Existing tasks.json files will fail validation. To migrate:

```bash
# Regenerate tasks.json from your plan file
/aimi:plan-to-tasks docs/plans/your-plan.md
```

Or manually add the required fields to each story in tasks.json.

## [0.3.0] - 2026-02-15

### Changed

- **BREAKING:** Rename `completed` field to `passes` in tasks.json schema
  - Better reflects acceptance criteria validation semantics (pass/fail)
  - Aligns with testing vocabulary
  - Updated all commands: deepen, execute, next, status
  - Updated all skills: plan-to-tasks, story-executor
  - Existing tasks.json files need field renamed from `completed` to `passes`

## [0.2.1] - 2026-02-15

### Added

- AGENTS.md update instructions in story-executor (mirrors Ralph's prompt.md pattern)
- Step 10 in execution-rules.md for updating AGENTS.md files with reusable patterns
- AGENTS.md guidance in compact prompt template

### Changed

- Execution flow now includes AGENTS.md check before committing (Step 5 in SKILL.md)

## [0.2.0] - 2026-02-15

### Security

- **BREAKING:** Add branchName validation in `/aimi:execute` to prevent command injection
- Add input sanitization for story content before prompt interpolation (prevents prompt injection)
- Restrict Bash permissions in `/aimi:next` to specific command prefixes (git, npm, bun, yarn, tsc, eslint, prettier)

### Changed

- **BREAKING:** Introduced `completed` field in tasks.json schema (now renamed to `passes` in v0.3.0)
- Inline story data in Task prompts (reduces file I/O by ~33%)
- Extract only Codebase Patterns from progress.md (reduces context usage)
- Add structured error format with type classification for programmatic handling

### Added

- JSON schema validation requirements in task-format.md
- Available Capabilities section in story-executor (agents know their tools)
- Compact prompt template for subsequent stories (~60% token reduction)
- Progress rotation guidelines (archive when exceeding 50KB)
- Error type classification: typecheck_failure, test_failure, lint_failure, runtime_error, dependency_missing, unknown

### Removed

- Duplicate plugin.json at root level (keep only in plugins/aimi-engineering/)

## [0.1.0] - 2026-02-15

### Added

#### Commands
- `/aimi:brainstorm` - Explore ideas through guided brainstorming (wraps compound-engineering)
- `/aimi:plan` - Create implementation plan and convert to tasks.json
- `/aimi:deepen` - Enhance plan with research and update tasks.json
- `/aimi:review` - Code review using compound-engineering workflows
- `/aimi:status` - Show current task execution progress
- `/aimi:next` - Execute the next pending story with retry logic
- `/aimi:execute` - Run all stories autonomously in a loop

#### Skills
- `plan-to-tasks` - Convert markdown implementation plans to structured tasks.json format
- `story-executor` - Provides prompt template for Task-spawned agents executing stories

#### Documentation
- Task format reference with JSON schema and sizing rules
- Execution rules reference with 9-step execution flow
- Complete README with workflow guide and troubleshooting

### Dependencies

This plugin requires **compound-engineering-plugin** for brainstorm, plan, and review workflows.
