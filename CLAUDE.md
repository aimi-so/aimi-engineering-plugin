# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repo **builds** the aimi-engineering plugin — it is not a plugin consumer. It ships two distribution targets from a single source tree:

- **Claude Code** via `claude /plugin install aimi-engineering` (reads `plugins/aimi-engineering/` directly)
- **OpenCode** via `./install.sh --to opencode` (translates the plugin into OpenCode's structure and installs to `~/.config/opencode/`)

The nested **`plugins/aimi-engineering/CLAUDE.md`** is the source of truth for plugin-internal conventions (versioning, command/skill authoring, schema requirements). Read it when editing anything under `plugins/aimi-engineering/`.

## Dual-Host Architecture

A single source tree serves both hosts. Anything touching CLI path resolution, environment variables, or install mechanics must account for both:

- **`CLAUDECODE=1`** — set by Claude Code in every session. Absent in OpenCode. This is the runtime discriminator used by `aimi-cli.sh` and `commands/references/cli-path-resolution.md` to decide between Claude Code's cache (`~/.claude/plugins/cache/`) and OpenCode's install (`$AIMI_PLUGIN_DIR`).
- **`AIMI_PLUGIN_DIR`** — set by `install.sh` in shell profiles. Only honored when `CLAUDECODE` is unset. Inside Claude Code, Layer 0 resolution skips this entirely so the Claude Code cache always wins.
- **`install.sh`** — performs heavy translation: rewrites command bodies (Task tool mappings, CLI path glob → `OPENCODE_CONFIG_DIR`), handles missing OpenCode features (`disable-model-invocation`, `AskUserQuestion`, custom `subagent_type`), copies/flattens skills and agents. Before changing command syntax or CLI behavior, check whether `install.sh` needs a matching translation.

## Multi-Repo Execution Layout

`AIMI_ROOT` — the directory holding `.aimi/` — is not required to be a git repository. A **multi-repo** layout is a plain, non-git parent folder holding one git repository per subfolder instead, with `.aimi/` living in that parent. `/aimi:execute`, including phase mode, resolves each story's own `project` field to the repository that owns it and runs one container, one branch, and one PR per participating repository — never a single one spanning the whole layout.

Before touching container, branch, or split-detection logic, read:
- `plugins/aimi-engineering/commands/execute.md`'s **Multi-Repo Handling** section — the single source of truth for layout detection and per-project story routing.
- `plugins/aimi-engineering/commands/references/container-execution.md` — the shared container/worktree mechanics every execution mode (flat, container, phase) delegates to.

## Commit Conventions

**Never add Claude (or any AI assistant) as a co-author on commits.** Do not append `Co-Authored-By: Claude ...` or similar trailers. Commits are authored by the human running the tool.

## Key Commands

### Testing

Seven independent test suites — five plain Bash, two Python (pytest):

```bash
bash plugins/aimi-engineering/scripts/test-aimi-cli.sh            # four parts, concurrent
bash plugins/aimi-engineering/scripts/test-aimi-cli.sh --serial   # same tests, one part at a time
bash plugins/aimi-engineering/scripts/test-worktree-manager.sh
bash plugins/aimi-engineering/scripts/test-tasks-concurrency.sh
bash plugins/aimi-engineering/scripts/test-command-blocks.sh
bash plugins/aimi-engineering/scripts/test-resolve-pr-parallel.sh
python3 -m pytest plugins/aimi-engineering/hooks/tests/ -q
python3 -m pytest plugins/aimi-engineering/scripts/tests/ -q
```

There are two Python components: `plugins/aimi-engineering/hooks/` (the hook dispatcher and guards) and the modules beside `aimi-cli.sh` — `scripts/roadmap.py` (the roadmap.json document logic behind the `roadmap-*` verbs), `scripts/tasks.py` (the tasks.json document logic behind the tasks verbs), `scripts/story_merge.py` (everything `story-merge` does after its flags are parsed) and `scripts/sanitize.py` (the one prose sanitizer both of them import, so neither owns it). Everything else has no build step, no lint step, no package manager and stays plain Bash. Both pytest suites require Python 3.10+ and `pytest` installed via `pip install pytest`.

**Path confinement is split on a real boundary, and the split is not a preference.** `validate_path_in_project` in `aimi-cli.sh` stays the sole authority over every path that arrives as a CLI ARGUMENT — it runs before `python3` starts, so an escaping argument is refused without the document being read at all. `tasks.py` owns confinement for the paths that come out of the document it reads: `metadata.designBundle`'s spec paths (`confined_spec_path`), and `metadata.brainstormPath` / `metadata.researchPaths[]` / `metadata.prototypePaths[]` (`require_in_project`, which `archive-task` uses to decide what it may move and delete). Those paths exist only after the crossing; routing them back to bash would mean reading the file a second time, which is the shape the port exists to remove. Both Python checks are exact ports of the bash rule — realpath for a path that exists, resolved parent plus basename for one that does not, prefix comparison against `PROJECT_ROOT` — and `require_in_project` reproduces its refusal message and exit status byte for byte. **A new document-sourced path belongs behind one of those two, never behind a fresh check.**

**`python3` is a runtime requirement of `aimi-cli.sh` as a whole, not only a test-time one, and no longer of one family of verbs.** Claude Code already invokes `hooks/*.py` directly on every session; `aimi-cli.sh` shells out to `roadmap.py` for the roadmap verbs, to `story_merge.py` for `story-merge`, and to `tasks.py` for every `tasks.json` verb. That last group is the per-story hot path `/aimi:execute` runs — the `init-session` neighbourhood, `mark-complete`/`mark-in-progress`/`mark-failed`/`mark-skipped`, `list-ready`, `next-story`, `count-pending`, and `get-story-context`, the verb every spawned story executor runs as its first action — plus the validators, `cascade-skip`, the gates and `archive-task`. `check_python3()` fails with an install hint and all of them call it, so **assume the CLI needs `python3`**: what still runs without it is `init-session` itself and the environment/forge half (`version`, `check-version`, `prime-cache`, `detect-*`, `forge-*`, `setup-branch`) plus `estimate-payload` and `list-archivable` — a residue, not the rule. Earlier CHANGELOG entries promised the opposite and were accurate when written; they stay as the records they are, and the entry that retires the promise names the release it changed in.

**The requirement change lands on OpenCode alone, and it surfaces at first use rather than at install.** Under Claude Code `python3` was already a hard per-Bash-call dependency — `hooks/hooks.json` wires `hooks/pre-bash-dispatcher.py` on `PreToolUse`/`Bash`, so a session without an interpreter never reaches a verb — and nothing there changes. `install.sh` **wires no hooks** — `grep -i hook install.sh` returns nothing, and while the hook *files* travel with its wholesale `cp -R "$src/."`, nothing registers or runs them — so an OpenCode session never spawns `python3` on its own. That same copy carries `scripts/*.py` with no installer change, so the install still succeeds on a host that cannot then run a verb. It has no dependency preflight to lean on either: its only `command -v python3` is a *fallback* used to edit JSON config when `jq` is missing. A one-line `command -v python3 || warn` beside its post-install `prime-cache` step would be the cheap earlier signal, and is deliberately not built yet. Know one asymmetry when diagnosing this: most verbs refuse loudly, but `next-story` runs its crossing inside a command substitution guarded by `|| story=""` (so `/aimi:next` reads a clean stop rather than an error), which means a missing interpreter prints the hint on stderr and still answers `null` at exit 0 — read as "all stories complete".

**The four `models.json` READERS are the second asymmetry, and unlike `next-story`'s it is designed rather than inherited.** `resolve-models`, `get-current-models`, `models-prompt-check` and `list-models` each answer from `scripts/models.py` at one crossing, which widens the requirement onto the hottest path in the plugin — `resolve-models` runs once per invocation of `/aimi:brainstorm`, `/aimi:plan`, `/aimi:deepen`, `/aimi:execute`, `/aimi:review`, `/aimi:validate-bug`, `design/polish` and the task-planner skill. So **none of them calls `check_python3`**: its `exit 1` would turn a python3-less OpenCode host from "works" into "every command dies at its first CLI call", and `resolve-models`' documented contract is that it never fails at all. Each degrades to what it already promises when it cannot read the config — all-`inherit`, all-`null`, `prompt`, the built-in Anthropic list — with one line on stderr naming the missing interpreter, and exit 0. Two consequences worth knowing before diagnosing a support report: a configured OpenCode user with no `python3` silently gets the UNCONFIGURED answer rather than an error, and `list-models` on Claude Code crosses nothing at all, because its answer there is a constant. `detect-models`, the writer of the same file, is untouched and still pure Bash + jq.

- Run `python3 -m pytest plugins/aimi-engineering/scripts/tests/ -q` after any change to `roadmap.py`, `tasks.py`, `story_merge.py` or `sanitize.py` — one test module each (`test_roadmap.py`, `test_tasks.py`, `test_story_merge.py`), and `tasks.py` is the largest of the four. **`tasks.py` needs a second suite that pytest cannot give it:** `test-tasks-concurrency.sh` (below) is the only thing that runs two verbs at once, and it is a separate serial artifact precisely because the corpus this bullet is about cannot observe concurrency. Its `tests/golden_from_jq.json` was captured from the jq implementations that used to live in `aimi-cli.sh`, **before they were deleted**, and is the evidence that the port changed nothing. Never regenerate it from the Python — that would turn it into a snapshot of whatever the code does today. When a rule genuinely changes, the golden file changes in the same commit, with the reason in the message.
  - The `story_merge_cases` block records each case's INPUT as well as its output, so `test_story_merge.py` replays the whole 92-case corpus through the CLI and compares every field rather than describing it. Eight cases are excused by name in `KNOWN_DIVERGENCES`, every one of them a jq or `set -e` abort where the recorded message was the engine's; the golden file's `_comment_story_merge` says what each one cost.

- Run `test-aimi-cli.sh` after any change to `plugins/aimi-engineering/scripts/aimi-cli.sh` or files it sources. It is a **dispatcher**: it runs `test-aimi-cli-part{1..4}-*.sh` **concurrently** and aggregates their counts. Each part sources the 179-line `test-aimi-cli-common.sh` preamble (the `assert_*` family, `setup`, `cleanup`) plus `test-aimi-cli-fixtures.sh` for the fixtures more than one part needs, and is runnable on its own for a focused loop. A new test goes in the part that owns its concern — each part's header comment lists its sections — and `EXPECTED_ASSERTIONS` in the dispatcher must be raised to match, because the dispatcher asserts the total and fails the run when it moves.
  - **Serial escape hatch: `--serial` (or `-s`, or `AIMI_TEST_SERIAL=1`).** Concurrent is the default and is ~2.2x faster. Serial mode streams each part's output live instead of buffering it — reach for it when bisecting an intermittent failure, when a part hangs and you need to see how far it got, or on a host where four concurrent parts would thrash. `--parallel`/`-p` forces concurrency back on when `AIMI_TEST_SERIAL` is set in the environment. Counts, the invariant and the exit status are identical either way; only wall time and buffering differ.
  - The run is bounded by its slowest part, not by core count — part 3 (`roadmap-forge`) is ~40-46% of the serial total on its own, which is why four parts on 16 cores gives ~2.2x rather than 4x. The summary prints each part's wall time beside its counts so that imbalance stays visible.
  - Concurrency applies to **this suite only**. `test-worktree-manager.sh` is not parallel-safe — five `serve` assertions collide on a fixed port — and stays serial.
  - **The run ends with a fixed-shape `suite-cost` line** — `cli_lines`, `test_lines`, `assertions`, `wall_seconds`, `mode`, `frame`, always in that order. `grep suite-cost` two transcripts to see the trend mechanically. Two of its fields are environment-scoped and the line names which environment it measured: `wall_seconds` is not comparable across `mode=serial`/`mode=concurrent`, and `assertions` is **2 lower** under `frame=worktree` than `frame=checkout` for the same tree (the worktree-resident CLI case emits 1 assertion where a checkout emits 3). Comparing a container run against a main-tree run without reading `frame` looks like two tests vanished. The suite carries one `EXPECTED_ASSERTIONS` literal and derives the worktree frame from it by that same 2 — deliberately, because the two used to be separate literals and drifted apart; no absolute count is quoted here for the same reason.
- Run `test-worktree-manager.sh` after any change to `plugins/aimi-engineering/skills/git-worktree/scripts/worktree-manager.sh`.
- **Run `test-tasks-concurrency.sh` after any change to the locking or the ordering of reads and writes in `cascade-skip`, `gate-pass`, `gate-fail` or `reset-orphaned`** — the four tasks.json verbs that used to read a precondition outside the lock they then wrote under. It runs two verbs at once and asserts what the loser sees. **Serial-only and not parallel-safe**, for the same reason `test-worktree-manager.sh` is: every test spawns background processes contending for one lock and one document. It is deliberately **not** in `test-aimi-cli.sh`'s `PARTS` array and so contributes nothing to `EXPECTED_ASSERTIONS`; it prints its own passed/failed totals and exits non-zero on failure. Fixtures live under `mktemp -d` and it never touches the repo's own `.aimi/`.
  - **Its assertions inverted once, deliberately, in the commit that moved those four verbs onto one crossing into `tasks.py` inside the lock** — `assert_eq "skipped"` became `assert_eq "completed"`, and the gate tests now expect a refusal where they expected an invented gate. That diff is the reviewable statement that behaviour changed; the file's header explains each inversion beside the assertion it belongs to. The suite discriminates in both directions and this is checked rather than claimed: against the pre-fix jq the new assertions fail 9 of 18, and the pre-inversion assertions fail 8 of 18 against the fix.
  - **This suite covers what `golden_from_jq.json` cannot.** That corpus is single-threaded by construction — one CLI invocation per case — so no recording in it can observe a lost update. A reviewer who assumes the golden covers concurrency is wrong.
  - The `reset-orphaned` entry is ranked separately and deliberately: its locked write always re-selected `status == "in_progress"`, so the file on disk was already correct and only the printed report could be stale. **Cosmetic, not data loss** — nothing was lost there and nothing was recovered. Its two file assertions did not invert, because they were never wrong.
- **Run `test-command-blocks.sh` after any change under `plugins/aimi-engineering/commands/`** — including changes that touch only prose. Command files are executed, not read: an agent runs their ` ```bash ` blocks literally, each in its own isolated shell, so a "documentation-only" edit is a code change. This suite extracts every bash-fenced block and checks it parses, avoids bash-only constructs (blocks may run under zsh), does not read a variable that only exists inside a loop, and introduces no variable that nothing in the file assigns. Known findings are grandfathered in `scripts/command-blocks-baseline.txt`; the suite fails when a baselined entry stops firing, so that file shrinks as things are fixed. It cannot see a variable that a *prose sentence* reads — that class is only fixed by moving the logic into `aimi-cli.sh`.
- Run `test-resolve-pr-parallel.sh` after any change to `plugins/aimi-engineering/skills/resolve-pr-parallel/scripts/`. It exists specifically because `test-command-blocks.sh` does not scan `skills/` at all, leaving these scripts with no other static-analysis safety net. (That suite's own scope is `commands/**/*.md` — it discovers inputs with a recursive `find`, so `commands/references/` **is** covered, and its baseline already carries entries from there. It is `skills/` alone that it never reaches.)
- Run `python3 -m pytest plugins/aimi-engineering/hooks/tests/ -q` from the repo root after any change under `plugins/aimi-engineering/hooks/` (dispatcher handlers, guard logic, or their tests).

### OpenCode install verification

```bash
./install.sh --to opencode --dry-run   # preview translation output
./install.sh --to opencode             # perform install
./install.sh --uninstall --from opencode
```

### Version bump workflow

Every plugin change requires synchronized bumps in three files (per `plugins/aimi-engineering/CLAUDE.md`):

1. `plugins/aimi-engineering/.claude-plugin/plugin.json` — `"version"`
2. `.claude-plugin/marketplace.json` — the plugin entry's `"version"`
3. `CHANGELOG.md` — new entry under the version heading (Keep a Changelog format)

## CLI Path Resolution (Critical)

`aimi-cli.sh` is the only executable consumed by commands. All commands resolve it through a four-layer strategy documented in `plugins/aimi-engineering/commands/references/cli-path-resolution.md`:

- Layer 0: `$AIMI_PLUGIN_DIR` (skipped inside Claude Code)
- Layer 1: `~/.config/aimi/cli-path` global cache (new XDG path; `$AIMI_CONFIG_DIR/cli-path` when that var is set; legacy `~/.claude/aimi-engineering-cli-path` read as fallback)
- Layer 2: glob under `~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`
- Layer 3: per-project `.aimi/cli-path`

After resolution, commands call `$AIMI_CLI check-version --quiet --fix` for self-heal. The fix path is gated by `_is_claude_code_host()` — it short-circuits to "managed by converter" only when running under OpenCode.

When editing resolution logic, mirror changes in:
- `plugins/aimi-engineering/commands/references/cli-path-resolution.md` (command-facing docs)
- `plugins/aimi-engineering/scripts/aimi-cli.sh` (`read_global_cli_cache`, `read_global_worktree_cache`, `cmd_check_version`, `cmd_cleanup_versions`)
- `plugins/aimi-engineering/scripts/test-aimi-cli-fixtures.sh` (`source_cache_functions` must eval every helper used by the code under test)

## Where Things Live

- `plugins/aimi-engineering/` — the plugin source; installed verbatim by Claude Code
- `plugins/aimi-engineering/CLAUDE.md` — plugin development rules (versioning, security, schema, conventions)
- `plugins/aimi-engineering/AGENTS.md` — portable single source of truth for spawned-agent output compression rules (consumed by both Claude Code and OpenCode)
- `plugins/aimi-engineering/scripts/aimi-cli.sh` — the one executable commands call, and the owner of every deterministic operation (task file management, story lifecycle, version checks). Prevents model hallucination of bash by centralizing them. It is no longer where all of that logic *lives*: the `roadmap.json`, `tasks.json` and story-merge document rules are in `roadmap.py`, `tasks.py` and `story_merge.py` beside it, and the wrapper's job is flags, path confinement, the lock and one crossing.
- `.claude-plugin/marketplace.json` — marketplace manifest for Claude Code discovery
- `install.sh` — OpenCode translator/installer
- `CHANGELOG.md` — user-facing change log (Keep a Changelog format)
