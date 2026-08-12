# Aimi Engineering Plugin - Development Guidelines

## Versioning Requirements

**Every change to this plugin MUST include:**

1. **Bump version** in `.claude-plugin/plugin.json` (follow semver)
   - MAJOR: Breaking changes to command syntax or output format
   - MINOR: New commands, skills, or features
   - PATCH: Bug fixes, documentation updates

2. **Update CHANGELOG.md** with the change description
   - Follow [Keep a Changelog](https://keepachangelog.com/) format
   - Categories: Added, Changed, Fixed, Removed, Security

3. **Update README.md** component counts if adding/removing components

4. **Update marketplace.json** version to match plugin.json

## Plugin Structure

```
aimi-engineering-plugin/
├── .claude-plugin/
│   └── marketplace.json         # Marketplace manifest (points to plugins/)
├── plugins/aimi-engineering/    # Actual plugin content
│   ├── .claude-plugin/
│   │   └── plugin.json          # Plugin manifest
│   ├── commands/                # Slash commands (.md files)
│   ├── skills/                  # Skills (subdirs with SKILL.md)
│   │   └── skill-name/
│   │       ├── SKILL.md
│   │       └── references/
│   └── CLAUDE.md                # This file
├── CHANGELOG.md                 # Version history
└── README.md                    # User documentation
```

## Security Requirements

### Input Validation (CRITICAL)

1. **branchName validation** - Must match `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`
   - Prevents command injection in git operations
   - Reject invalid names before any git command

2. **Story content sanitization** - Before prompt interpolation:
   - Strip newlines, markdown headers, code fences
   - Validate field lengths (title: 200, description: 500, criterion: 5000)
   - Reject suspicious content ("ignore previous instructions", shell syntax)

3. **Bash permissions** - Use specific prefixes in allowed-tools:
   - `Bash(git:*), Bash(npm:*), Bash(bun:*), Bash(tsc:*)` etc.
   - Never use unrestricted `Bash` in commands that spawn Task agents

## Hook Conventions

- Hooks emitting hookSpecificOutput must gate on CLAUDECODE env var when their output schema is Claude Code-specific.

## Command Conventions

- Use `aimi:` prefix for all commands — always show `/aimi:plan`, `/aimi:execute`, etc. in output, NEVER the fully-qualified `/aimi-engineering:plan` form
- Use `disable-model-invocation: true` for side-effect commands
- Wrapper commands should pass `$ARGUMENTS` to wrapped commands
- Document allowed-tools in frontmatter with specific Bash prefixes
- Validate inputs before passing to external commands
- See `commands/references/user-communication.md` for the wording/tone rules governing text written to the human reader (completion reports, chat explanations, `AskUserQuestion` prompts); this file references them (no duplication)

## Skill Conventions

- Keep SKILL.md under 300 lines
- Move detailed schemas/examples to `references/` directory
- Include trigger phrases in description
- Use imperative writing style
- Include Input Sanitization section for skills that process user data
- Document Available Capabilities for Task-spawned agents

## Output Files

All task execution files go in `.aimi/tasks/`:

- `YYYY-MM-DD-[feature-name]-tasks.json` - Structured task list with user stories
- `<feature-slug>/roadmap.json` + `<feature-slug>/phase-N[.M][-slug]/` - Phase/milestone roadmap layer for large-scope features (see Roadmap File Schema below). Each phase folder holds `<feature-slug>-phase-N-tasks.json` (materialized by `/aimi:plan --phase N`) and `handoff.md` (written by `roadmap-write-handoff`). Single-scope-context features never create this layout — they use the flat `YYYY-MM-DD-[feature-name]-tasks.json` form above, with zero overhead.

> The CLI auto-discovers `.aimi/` by walking up from CWD -- no need to be in the project root to run commands.

Learnings are stored in project files (not separate progress log):

- `CLAUDE.md` (root) - Project-wide patterns and conventions
- `AGENTS.md` (plugin-level) - Single source of truth for spawned agent output compression rules; portable across tools (Claude Code, OpenCode). Per-directory AGENTS.md files in skills/ extend these base rules with domain-specific patterns

## aimi-cli.sh Research Subcommands

Two CLI subcommands manage the research lifecycle. Both are internal — consumed by `plan` and `deepen` commands, not invoked by users directly.

- **`research-lookup <path>`** — Content-aware freshness check. Reads the `## File References` h2 bullet section of the given research `.md` file, compares its mtime against the newest mtime of every cited source path, and exits 0 (fresh) or 1 (stale). Cited paths that are missing or outside the project root are treated as stale. Used by `plan`/`deepen` before deciding whether to spawn a researcher.

- **`research-gc`** — Orphan garbage collector. Deletes `.aimi/research/*.md` files older than 30 days that are not referenced by any active `.aimi/tasks/*.json` `metadata.researchPaths`, any `.aimi/brainstorms/*.md` frontmatter `researchPaths`, or any `.aimi/brainstorms/*.md` frontmatter `foundationProposalPath`. Called opportunistically once per `plan`/`deepen` session. Silent when nothing is removed.

## aimi-cli.sh Story Lifecycle Subcommands

### One-crossing invariant (structural, and mechanically checkable)

**Every `tasks.json` verb wrapper in `aimi-cli.sh` makes exactly one crossing into Python, and for a writer that crossing is inside the lock.** The shape is `( _lock "$f.lock"; python3 tasks.py <op> … ) 200>"$f.lock"` — read, decide, write and return, all within the single call. A wrapper that crosses twice has, by construction, a read that happens outside the lock it then writes under, and something can change in between.

**The check is counting `python3` invocations per wrapper, over the wrappers selected by the LOCK.** That is the whole point of writing this down: *"did concurrency change?"* is a behavioural question a reviewer cannot answer by reading a diff, and *"how many times does this wrapper call `python3`?"* is a structural one they can. In a tasks verb, more than one crossing is the defect and **zero is the same defect wearing jq** — a wrapper that never reaches Python is doing its own read-decide-write in bash, which is the shape this invariant exists to forbid. `test_every_locked_tasks_verb_crosses_into_python_exactly_once` in `scripts/tests/test_tasks.py` enforces it; `scripts/test-tasks-concurrency.sh` is what demonstrates the consequence.

**Selecting on the crossing is how a wrapper hides from the count, and that is not hypothetical.** That test's filter used to require a crossing to be present before it would count crossings, so `set-execution-mode` — which took `"${tasks_file}.lock"`, read its phase guard with `jq` *outside* it and wrote with a second `jq` *inside* it — was discarded before the exhaustive comparison ran, and the word "every" above was false for as long as it stood. The filter selects on the lock now, and the two failure modes report themselves separately so neither is read as the other's diagnosis. A locked tasks wrapper making zero crossings is exercised as a fixture in the same file, so the widened check is shown to bite rather than merely to pass.

Two exemptions exist, both in the roadmap family, both named here so the list cannot grow quietly:

- **`roadmap-init`** and **`roadmap-amend-phase`** cross twice on purpose. A payload arrives on **stdin** and can be refused without reading `roadmap.json` at all — malformed JSON, a bad `creates`/`needs` identity, an unamendable key. Refusing inside the lock would create the feature directory as a side effect of saying no, so the payload is validated in its own crossing first. `cmd_roadmap_set_status` carries the normative statement of this in a comment beside its own single crossing.
- **No `tasks.json` verb takes a stdin payload**, so none of them has that exemption available. Every refusal a tasks verb can reach without the document — a missing argument, a malformed story id, an unknown flag — already happens in bash before the lock; every remaining one needs the file, and a second call could only re-read what the first one holds.

Readers are exempt from the lock half and not from the counting half. `cmd_list_ready` names the module in each of two mutually exclusive branches, which is one crossing per invocation; that branch exemption is asserted by name too.

The same counting rule covers the four **`models.json` readers** — `cmd_resolve_models`, `cmd_get_current_models`, `cmd_models_prompt_check` and `cmd_list_models`, each one crossing into `scripts/models.py`, none of them taking a lock (`test_each_reader_crosses_at_most_once_per_invocation` in `scripts/tests/test_models.py` counts them). `cmd_list_models` is the second **branch** exemption after `cmd_list_ready`, and the opposite shape: its Claude Code branch crosses ZERO times, because that host's answer is a constant. Zero crossings is the defect in a tasks verb — there it means a read-decide-write done in bash — and is not one here, where nothing is read and nothing is decided. The three aliases it prints are consequently spelled twice, once as data in `_host_valid_models` and once as JSON in the branch; the two are run against each other by `test_list_models_claudecode_matches_the_host_valid_set` so the second cannot drift. **None of the four calls `check_python3`** — see the top-level `CLAUDE.md` § Testing for why that would be a regression, and what each degrades to instead.

`cmd_detect_models`, the **writer** of that same file, is counted by the same rule (`test_the_writer_crosses_once_and_the_assembly_is_written_once`) and answers the `check_python3` question the other way: it calls it and refuses, because a writer has no honest degrade — see the top-level `CLAUDE.md`. It takes no lock either, and that is deliberate rather than an oversight: nothing else writes `models.json`, and `write_aimi_models_config`'s mktemp-then-`mv` is what makes a concurrent reader see one whole document or the other, never half of one. Its merge lives in `merge_models_document`, whose first parameter is the existing document **so that a rebuild cannot be written there by accident** — that shape is what shipped as 1.97.2, dropping the inactive host's models on every invocation, and the assembly was duplicated verbatim across two branches precisely because the fix was copied from one to the other.

### `story-merge`

One CLI subcommand manages the story-merge lifecycle. It is consumed by the `/aimi:plan` two-pass pipeline, not invoked by users directly.

- **`story-merge`** — Consolidates per-story JSON staging files written by Pass 2 sub-agents into a single validated `tasks.json`. Key behaviors:
  - **Deterministic ID assignment**: each staging file receives a stable `US-NNN` identifier in outline order.
  - **dependsOn token remapping**: `outline:NN` tokens emitted by sub-agents are rewritten to the assigned `US-NNN` before write.
  - **DAG validation**: cycle detection aborts the merge before any write.
  - **Wave computation**: BFS over the dependency graph assigns each story to a parallelism wave.
  - **Post-merge sweeps**: Rule 22 mock-sync AC routing, Phase 3.1 Reference Element Inventory verdict check, and Phase 4.1 Coverage Self-Check run after DAG validation and before the atomic write.
  - **Atomic write**: output file is written under `flock` to prevent partial reads by concurrent processes.
  - **Flags**:
    - `--staging-dir <path>` — directory containing per-story staging `.json` files (default: `.aimi/.tasks-staging/<topic-slug>-<RUN_TS>/`).
    - `--output <path>` — destination `tasks.json` path (default: `.aimi/tasks/<date>-<topic-slug>-tasks.json`).
    - `--split legacy|full-stack` — `legacy` (default) emits one file. `full-stack` picks its split **axis** from the merged array before either writer runs, by counting distinct normalized `.project` values (trim whitespace, strip one trailing slash, blank/absent treated as null):
      - **2 or more distinct values → PROJECT axis** (multi-repo). One output file per distinct project, N files, no frontend/backend decision at all. Project-less stories route to the `"."` root group. Groups are ordered lexicographically by normalized project path; ids are reassigned `US-001..US-M` in contiguous per-group blocks so they stay unique across the whole set. Each file carries `metadata.splitGroup` = `{project, index, total, siblings[]}` and its own derived `branchName`. Output basenames are slugified (every character outside `[A-Za-z0-9_-]` becomes `-`), and two projects that collide on the same slug hard-fail the merge before any file is written.
      - **Fewer than 2 distinct values → SIDE axis** (single-repo/monorepo, including "no story has `.project`" and "every story shares exactly one project"). The unchanged two-file frontend/backend writer; each story is classified by its own file-pattern/title heuristic verdict.
    - `--agent-mode` — demotes Phase 3.1 and Phase 4.1 hard rejects to warnings, allowing CI pipelines to proceed without a user review gate.
    - `--phase-aware` — only meaningful with `--split full-stack`. Strips one trailing `-tasks` segment from the `--output` basename before the writer appends its per-file suffix, so a phase-scoped output path (`<feature>-phase-<N>-tasks.json`) produces single-`tasks`-segment split basenames instead of the legacy double-`tasks` form. The strip is pure basename manipulation performed before the axis writer runs, so it is independent of the axis and composes at any N: on the SIDE axis it yields `<feature>-phase-<N>-frontend-tasks.json`/`-backend-tasks.json`, on the PROJECT axis `<feature>-phase-<N>-<project-slug>-tasks.json` per project. Omitted (default): unchanged legacy derivation.
    - `--foundation <NN>` — deterministic dependsOn injection for the Greenfield Foundation Gate. `NN` is a two-digit (`^[0-9]{2}$`) 1-based outline position, resolved against the same outline-position map used for `outline:NN` remapping (not a literal staging-filename digit). The resolved foundation story's own `dependsOn` must already be `[]` — a non-empty value aborts the merge before any write. When valid, the sweep appends the foundation's assigned `US-NNN` id to every other story's `dependsOn`, deduplicated (a story that already references the foundation, e.g. via its own `outline:NN` token, keeps exactly one occurrence); the foundation's own `dependsOn` stays `[]`. Runs after the `outline:NN` remap and before both cycle detection and wave computation, so injected edges participate in both — the foundation lands in wave 1 and every other story's wave reflects the added dependency. Composes with `--split full-stack`/`--phase-aware` (the sweep runs once against the full merged array before the split/legacy write branch). On the PROJECT axis the resolved foundation id is threaded into the writer: the foundation lives in exactly one project group, so every other group's injected edge is dropped and recorded with `droppedDeps[].foundationEdge: true` plus one stderr note line separate from the ordinary drop-count banner — the loss is expected fallout of `--foundation` + multi-repo, not a hand-authored dependency that went missing. The SIDE axis is unaffected (no `foundationEdge` field). Omitted (default): no injection, byte-identical to pre-flag behavior.

## aimi-cli.sh Roadmap Lifecycle Subcommands

Fifteen CLI subcommands manage the phase/milestone roadmap layer for large-scope features (see `commands/references/scope-contexts.md` for when a feature qualifies for phases vs. the flat single-scope-context pipeline). All are internal — consumed by `/aimi:brainstorm`, `/aimi:plan`, `/aimi:execute`, and `/aimi:status`, not invoked by users directly.

**`python3` is a runtime requirement for these verbs, not only a test-time one.** Fourteen of the fifteen shell out to `scripts/roadmap.py`, which owns `roadmap.json`'s document logic; each calls `check_python3()` first and fails with an install hint when it is absent. `estimate-payload` is the one roadmap verb that shells out to nothing and stays pure Bash + jq. **Outside this group the requirement is no longer narrow** — `story-merge` needs it, and so does every `tasks.json` verb, including the per-story hot path `/aimi:execute` runs (`mark-*`, `list-ready`, `next-story`, `count-pending`, `get-story-context`). Do not read this section as the boundary of the dependency; the normative statement, its full scope and what it means for an OpenCode install are in the top-level `CLAUDE.md` § Testing, and stating it twice is how the two drifted before.

- **`roadmap-init --feature <slug> [--file <path>] [--sync] [--brainstorm-path <path>]`** — Materializes `roadmap.json` from a phases array (stdin or `--file`). `--sync` merges additively into an existing roadmap instead of erroring on an existing file. A `creates`/`needs` entry is `{identity, description}`; one carrying any other key, or a malformed identity, is refused here at write time — the identity/description contract and its diagnostics are documented once, in `commands/references/scope-contexts.md` § Creates/Needs Contracts. Refuses a pre-`2.0` roadmap under `--sync`, naming `normalize-contracts`, rather than merging the two entry shapes into one document.
- **`roadmap-amend-phase --feature <slug> --phase <id> [--goal <text>] [--branch <name>] [--file <path>] [--retarget-needs "<old>=<new>"]...`** — Corrects an **existing** phase's contract in place, under the same `flock` + `mktemp`-then-`mv` discipline `roadmap-init` uses. This is the verb `guard-runtime-state.py` points at when it blocks a Write/Edit on `roadmap.json`; before it existed, that redirect named nothing. Amendable fields are exactly six — `goal`, `successCriteria`, `creates`, `needs`, `areas`, `branch` — supplied as scalar flags or as a JSON object on stdin/`--file` (stdin is read only when neither scalar flag is given). The merge is **partial by key presence**: a key present replaces that field wholesale, a key absent leaves the stored value byte-for-byte unchanged, as do every other phase and the document metadata.
  - **`branch` is amendable** because nothing else writes it for an existing phase: `roadmap-init` sets it once at creation and `--sync`'s anti-clobber guarantee never revisits it — which is exactly why a decimal phase's `null` branch could not be filled in. Amending it rewrites the roadmap field only; it does not move a worktree or git branch an `in_progress` phase already created.
  - **`status` and `claim` are not amendable** on the opposite ground: `roadmap-set-status` already owns status (transition graph plus the `handoff.md` precondition) and `roadmap-claim`/`roadmap-release-claim` already own claims (PID liveness, self-reclaim). A second writer would duplicate those guarantees, so both keys are rejected by name pointing at their owner. `id`, `dir`, `slug`, `name` and `dependsOn` are phase identity and are rejected by name too.
  - Amended values pass `roadmap-init`'s own gates (same sanitizer and caps, same `creates`/`needs` identity guard, same branch pattern). Dropping or renaming a `creates` identity a later phase cites in `needs` is **refused by default**; `--retarget-needs "<old identity>=<new identity>"` (repeatable) authorizes it, and the same locked write then replaces every matching downstream `needs` entry with the amended phase's new `creates` entry verbatim. Identity comparison is exact equality on the entry's own `identity` field, never substring containment. Refuses a pre-`2.0` roadmap, naming `normalize-contracts`. An amendment that would duplicate another phase's `creates` identity is refused (it would produce a roadmap `validate-contracts` rejects); a completed phase whose `handoff.md` omits a newly introduced identity only draws a stderr advisory and still writes.
- **`normalize-contracts --feature <slug>`** — Migrates a roadmap's stored `creates`/`needs` entries from the `roadmapVersion` `1.0` form — one string, `"identity (description)"` — to the `2.0` form `{identity, description}`, in place, under the same `flock` + `mktemp`-then-`mv` discipline every other roadmap writer uses. Each identity is computed by the **same function every reader used before the migration**, so no identity changes by a byte and no downstream `needs` is repointed; an entry with no `(` gets `description: ""` (never `null`), and an entry already in object form is left untouched, which is what makes a second run a no-op. It does not judge: a prose or whitespace-bearing identity the current writer would refuse migrates unchanged, and the reader reports it afterwards by name — repairing on the way past would silently change what a phase promises. One-way: an entry whose text after the first `(` does not end in `)` loses that unbalanced trailing paren from its description, which the identity half never sees. Prints `{roadmap, converted, roadmapVersion}`, where `converted` counts entries that were strings *before* the run.
- **`roadmap-get --feature <slug> [--phase <id>] [--next-eligible]`** — Reads a single phase, or the next eligible-to-claim phase, from `roadmap.json`.
- **`roadmap-eligible --feature <slug> [--statuses <a,b>]`** — Prints one JSON object naming **every** phase in roadmap order with a machine-readable verdict — `{id, name, status, claim, eligible, unmet[]}`, each `unmet` entry `{id, status}` — plus `eligible` (the ordered ids of the eligible ones) and `eligibleCount`, so one call serves both a list rendering and a by-id lookup. Structured fields only: no field carries a sentence, because user-facing wording follows the reader's own language (`commands/references/user-communication.md`) and the calling command composes it. **Zero eligible exits 0** with an empty list — unlike `roadmap-get --next-eligible`, which exits 1 — so a command substitution can tell "no phase ready" apart from a broken CLI. `--statuses` defaults to `pending,planned` and refuses an unknown name instead of silently returning nothing. Reads no tasks file, so its answer depends on `roadmap.json` alone and stays fixed while a concurrent `/aimi:execute` rewrites tasks files; ordered by numeric id. Ungated by `_roadmap_require_contracts` for the same reason the five lifecycle verbs are: it reads no `creates`/`needs` entry.
- **`roadmap-set-status --feature <slug> --phase <id> --status <status> [--force]`** — Transitions a phase's lifecycle status (`pending → planned → in_progress → completed`, or `→ verification_failed`). `--force` overrides the *transition-order* check only. It never overrides the hard precondition that a phase can reach `completed` only once `roadmap-write-handoff` has already written that phase's `handoff.md` to disk — that check runs even with `--force`.
- **`roadmap-claim --feature <slug> --session-id <id> --session-pid <pid> [--phase <id>]`** — Atomically claims the next eligible phase (or a specific `--phase` override) for a session via a locked check-and-set. Auto-releases stale claims whose `claimedPid` is no longer alive before choosing. Idempotent: re-claiming a phase the same session already owns returns it again instead of erroring.
- **`roadmap-release-claim --feature <slug> --phase <id>`** — Manual escape hatch to release a phase's claim (in addition to automatic stale-claim recovery).
- **`roadmap-reconcile --feature <slug>`** — Reconciles every phase's `status` against its own `<feature>-phase-<id>-tasks.json` ground truth (derived from that file's story statuses) and applies corrections in place. A correction that would set a phase to `completed` is applied only when `handoff.md` already exists on disk for that phase; otherwise it is reported as `blocked` rather than applied. Applying a `completed` correction also clears that phase's claim in the same write — reconcile does not otherwise touch claims. Returns `{corrections, blocked}`.
- **`roadmap-write-handoff --feature <slug> --phase <id> [--file <path>]`** — Writes `phase-N/handoff.md` from a structured payload (`decisions`, `artifacts`, `deviations`, `deferred`, `contracts` arrays). A precondition for `roadmap-set-status ... --status completed`.
- **`validate-contracts <feature> [--phase <id>] [--agent-mode]`** — Checks a phase's declared `creates`/`needs` contracts for duplicates and suspicious content; `--agent-mode` demotes hard blocks to warnings (mirrors the Phase 3.1/4.1 `--agent-mode` convention). Reads `roadmap.json` and `handoff.md` only, and never inspects source code — that is `verify-creates`' job.
- **`verify-creates --feature <slug> --phase <id> [--dir <container-path>]`** — Proves a phase's declared `creates[]` artifacts actually exist in code, by searching the files git tracks in `--dir` (the phase container; defaults to the project root). Reads each entry's own `identity` field and runs the same steps against every one, whatever kind it names — the search itself is documented once, in `commands/references/scope-contexts.md` § *What verification looks for*. Prints one verdict object per entry (`{identity, status, method, evidence, gitStatus}`); it is a query rather than a gate, so producing a verdict array exits 0 even when every entry is `missing`. `/aimi:execute` calls it once per participating repository at phase close and unions the verdicts.
- **`phase-overlap <feature> <phase-a> <phase-b>`** — Compares two expanded phases' task files' `implementation.files` sets and emits `{overlapping_files: [...]}`. It reports the overlap only — no splitting suggestion; the caller decides what to do with it.
- **`roadmap-sweep <feature>`** — Batch contract/status consistency sweep across an entire roadmap.
- **`estimate-payload --outline <path> [--research <path>]... [--spec <path>]... [--prototype <path>]... [--budget-bytes <n>] [--budget-fraction <0-1>]`** — Advisory token/byte budget estimate for an outline plus its cited sources; used to warn before a phase's expansion payload gets too large, suggesting a split along a semantic seam.

## Roadmap File Schema

> `roadmap.json` lives at `.aimi/tasks/<feature>/roadmap.json` and tracks phase/milestone lifecycle state for large-scope features. Key fields: `roadmapVersion` ("2.0"), `feature` (slug), `createdAt` (ISO 8601), `brainstormPath` (optional), `phases[]{id(number),name,goal,slug,dir,status(pending|planned|in_progress|completed|verification_failed),dependsOn[](phase ids),branch(optional),notes(optional),successCriteria[](optional),creates[](optional),needs[](optional),areas[](optional),claim(null|{claimedBy,claimedAt,claimedPid})}`.
> `creates[]` and `needs[]` hold `{identity, description}` objects — exactly those two keys, `description` `""` rather than `null` when absent. `roadmapVersion` tracks that entry shape and nothing else: `"1.0"` meant one string, `"identity (description)"`. Every contract-READING verb refuses a pre-`2.0` document by name and points at `normalize-contracts`; the five lifecycle verbs (`roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim`, `roadmap-reconcile`) read one unchanged, so a migration never strands a session already in flight.
> `phases[].dir` is a single-path-component directory name matching `^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$` (e.g. `phase-2`, `phase-2.1-auth-refactor`) — never a slash or `..`.
> `phases[].claim` is written only by `roadmap-claim` and cleared by `roadmap-release-claim`, or automatically when `claimedPid` is no longer alive (PID-liveness check mirrors the guard-runtime-state `_is_alive` pattern).
> All free-text phase fields (`name`, `goal`, `notes`, `successCriteria[]`, `branch`, `brainstormPath`) are sanitized before write using the same regime as `commands/references/sanitization.md` (strip newlines/backticks/`$(`, truncate).

## Tasks File Schema

> Key fields: `schemaVersion` ("3.3"), `metadata{title,type,branchName,researchDepth,maxConcurrency,researchPaths[](optional),prototypePaths[](optional),frontendOnly(optional),execution(optional:"container"|"inline", default "inline" when absent — see `commands/references/execution-mode.md` for the read contract; `/aimi:plan` writes `"container"` by default for freshly generated flat files),backendSpec(optional:{endpoints[],dataModels[],businessRules[],businessContext{summary,userRoles[],constraints[],assumptions[],successCriteria[]}}),splitGroup(optional:{project,index,total,siblings[]}),decisions[](optional:{anchor,source,text,resolution})}`, `userStories[]{id(US-NNN),title,description,acceptanceCriteria,status,dependsOn,project,wave,tasks[](optional,max50,each≤5000chars),implementation{files,approach,verify},verification{strategy,status,url,expect},gate{type,status,prompt,options}}`
> The `project` field is optional on stories — when present, it specifies the relative path from AIMI_ROOT to the target git repository for multi-repo execution.
> `metadata.splitGroup` is an optional object written by `story-merge` on the **PROJECT axis only** (`--split full-stack` over 2 or more distinct `.project` values): `{project, index, total, siblings[]}` — the file's own project routing key (`"."` for the root group), its 1-based position in the returned file list, the total file count, and the paths of the other N−1 files. `/aimi:plan` Phase 4 preserves it verbatim when patching `metadata`, and `/aimi:execute` Step 0.9 reads `metadata.splitGroup.project` to root each split's worktree/container at that project's own repo — losing it reintroduces `fatal: not a git repository` in multi-repo layouts. Phase mode reads the same field for the same purpose, not only the flat Step 0.9 flow: `/aimi:execute`'s **Detect a Full-Stack Split Inside This Phase** and **Create Phase Containers Per Project Group** (both in `commands/execute.md`) resolve a claimed phase's own per-repository phase container and phase branch from `metadata.splitGroup.project` on a split phase's member files, or from a story's own `project` field on a single non-split phase tasks file — one repository at a time, same as the flat flow. SIDE-axis, legacy, and frontend-only files have no `splitGroup` key and none should be invented for them.
> `metadata.smellWarnings` is an optional array written by `story-merge`; absent entirely when no smell is detected. Each entry is discriminated by `type`:
> - `{type: "orphan-symbol", storyId, symbols[], message}` — Phase 4.2: a story introduces a named symbol no sibling story references.
> - `{type: "cross-file-dep-dropped", storyId, side, becameRoot, droppedDeps: [{id, side, title}], message}` — **SIDE axis**, written by `_story_merge_write_split` when `--split full-stack` drops a `dependsOn` edge across the frontend/backend boundary. `side` is `"frontend"`/`"backend"` (`"unknown"` for an unresolvable target).
> - `{type: "cross-file-dep-dropped", storyId, project, becameRoot, droppedDeps: [{id, project, title, foundationEdge}], message}` — **PROJECT axis**, written by `_story_merge_write_project_split` when `--split full-stack` drops a `dependsOn` edge across a repo boundary. `project` is the owning group's routing key (e.g. `"apps/web"`, `"."` for the root group; `"unknown"` for an unresolvable target). `foundationEdge` is `true` only for an edge `--foundation` injected onto the shared foundation story, which lives in exactly one group — every other group losing it is expected fallout of `--foundation` + a multi-repo split, not a hand-authored dependency that went missing; `false` otherwise, and on every entry of a run without `--foundation`.
>
> `side` and `project` are mutually exclusive per entry — the axis decides which one is emitted, and consumers (e.g. the `/aimi:plan` Step 5 renderer) read whichever is present. `becameRoot` is `true` when the drop emptied the story's entire `dependsOn` list, making it a false wave-1 root. The combined array is written identically into every file the split produces (both side files, or all N project files). `message` and `droppedDeps[].title` embed sub-agent-authored titles already passed through `_rm_sanitize` (200-char cap) before write.
> `metadata.decisions[].anchor` valid forms: `specFlow:<key>`, `outline:edit:<idx>` (zero-padded index into the outline list, e.g. `outline:edit:02`), `phase:edit:<idx>` (zero-padded index into a proposed `phases` array at edit time, e.g. `phase:edit:02` — distinct from the persisted numeric phase `id`; used by both the `/aimi:brainstorm` roadmap-gate and the `/aimi:plan` inline fallback gate, see `source` below for how to tell them apart), `foundation:<topicSlug>` (the topic slug used to name the accepted/adjusted/skipped proposal file, e.g. `foundation:userAuth` — recorded by the `/aimi:plan` Phase 1.9 Greenfield Foundation Gate). `metadata.decisions[].source` valid values: `"specFlow:CriticalQ<n>"`, `"specFlow:Gap<n>"`, `"researchConflict"` (Phase 1.6b conflict escalation gate; anchor `researchConflict:<n>`), `"outline"` (for outline-gate edits recorded during the `/aimi:plan` outline gate), `"phaseGate"` (for roadmap-gate edits recorded in `phaseEditDecisions[]` during the `/aimi:brainstorm` Phase 3.5 roadmap definition gate; never written to a tasks.json `metadata.decisions[]` array), `"phase"` (for phase-cut Edit-round edits recorded in `oqDecisions[]`, and thus flushed to `metadata.decisions[]`, by the `/aimi:plan` Phase 0 Scope-Context Classification (Inline Fallback) gate — the no-brainstorm/legacy-brainstorm path that classifies scope contexts directly instead of reusing a brainstorm's `phases:` frontmatter), `"foundation"` (for the Aceitar/Ajustar/Pular decisions of the `/aimi:plan` Phase 1.9 Greenfield Foundation Gate, recorded in `oqDecisions[]` with anchor `foundation:<topicSlug>` and thus flushed to `metadata.decisions[]`).
> `foundationProposalPath` is a `.aimi/brainstorms/*.md` frontmatter key, not a `tasks.json` field — a single relative-path string (never a list, unlike `researchPaths`, since one repository has at most one active foundation proposal), emitted only when `/aimi:brainstorm`'s Phase 3.7 (Foundation Synthesis) writes and validates its 4-section artifact (fresh reuse counts as validated too); omitted entirely — no placeholder value, no companion boolean flag — when Phase 3.7 did not fire or its validation gate failed. `/aimi:plan`'s Phase 0 reads this key under the same strict path-confinement regime as its `### Prototype Context` subsection (absolute resolve, `AIMI_ROOT` prefix check, reject traversal/symlinks — not the looser `researchPaths` join-and-exists check), requires the target file to exist and be no older than 14 days, and on success populates the working-memory `foundationProposalPath` variable that Phase 1.9's Greenfield Foundation Gate consumes as a second reuse source (alongside its own topicSlug glob) for its fire-condition and reuse-source resolution.

## Performance Guidelines

1. **Pointer-only handoff** - Spawn prompts carry only the story id in a `task_pointer` block; each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action
   - Keeps the orchestrator's working memory slim across waves — no inlined story body, no inlined prototype HTML in the spawn prompt
   - Prototype files are read by the subagent itself using the Read tool when `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set

2. **Use CLAUDE.md/AGENTS.md** - Project conventions inline or referenced
   - Small files (<2KB) are inlined in prompt
   - Larger files are referenced for agent to read

3. **Compact prompts** - First story in a session gets the full template (SKILL.md "Prompt Template"); subsequent stories get the condensed variant (SKILL.md "Compact Template") where static sections (`<project_guidelines>`, `<execution_flow>`, `<tools>`, `<on_failure>`, `<project_root_boundary>`) are condensed to one-line summaries — NOT omitted, since each agent has fresh context. Story-specific and context-varying sections remain in full
   - Reduces prompt size by collapsing static sections; actual savings depend on story content and have not been benchmarked

4. **Fresh context per story** - Each Task agent starts with clean context
   - No memory carryover between stories
   - Learnings persist via CLAUDE.md/AGENTS.md files

5. **Spawned agent output behavior** - See `AGENTS.md` for output compression, safety escapes, and context-adaptive verbosity rules
   - AGENTS.md defines the rules; this file references them (no duplication)
   - AGENTS.md is portable across tools (Claude Code, OpenCode) and is the single source of truth for spawned agent behavior

## Guard Bypass Envs

Hooks support per-guard bypass via environment variables. Set `<name>=off` (or unset to leave the guard active). Bypass is intentional escape hatch — use sparingly and document why.

| Env Var | Hook | Behavior when `off` |
|---|---|---|
| `AIMI_DEFAULT_BRANCH_GUARD` | pre-bash-dispatcher (default-branch handler) | Allows commits on protected branches (main/master/develop) |
| `AIMI_SHELL_TRUE_GUARD` | pre-bash-dispatcher (shell-true handler) | Allows commits with shell=True in staged Python files |
| `AIMI_WORKTREE_BUDGET_GUARD` | pre-bash-dispatcher (worktree-budget handler) | Allows git worktree add beyond metadata.maxConcurrency |
| `AIMI_RUNTIME_STATE_GUARD` | guard-runtime-state | Allows direct Write/Edit to .aimi/state/, .aimi/tasks during execution, friction/telemetry logs, roadmap.json, and phase-*/handoff.md |
| `AIMI_AGENT_MODE` | aimi-learnings skill | Forces JSON-only read-only path; never marks events |

> `AIMI_RUNTIME_STATE_GUARD` (`guard-runtime-state.py`) intercepts the Write/Edit tool path and blocks direct writes to `roadmap.json` and `phase-*/handoff.md` (see Roadmap File Schema above) the same way it blocks `.aimi/tasks/*-tasks.json`, pointing the caller at the `roadmap-*` aimi-cli.sh verbs instead. This coverage is Write/Edit-tool-only — the hook is registered on `matcher: Write|Edit` (`hooks/hooks.json`) and reads `tool_input.file_path`. A Bash command that writes either file directly (e.g. `jq ... > roadmap.json`) is **not** intercepted.

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
