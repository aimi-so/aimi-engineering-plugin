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

Five independent test suites — four plain Bash, one Python (pytest) for the `hooks/` directory:

```bash
bash plugins/aimi-engineering/scripts/test-aimi-cli.sh            # four parts, concurrent
bash plugins/aimi-engineering/scripts/test-aimi-cli.sh --serial   # same tests, one part at a time
bash plugins/aimi-engineering/scripts/test-worktree-manager.sh
bash plugins/aimi-engineering/scripts/test-command-blocks.sh
bash plugins/aimi-engineering/scripts/test-resolve-pr-parallel.sh
python3 -m pytest plugins/aimi-engineering/hooks/tests/ -q
```

`plugins/aimi-engineering/hooks/` is the one Python component in this repo; everything else has no build step, no lint step, no package manager and stays plain Bash. The pytest suite requires Python 3.10+ (hook source and tests use `X | None` and `list[int]` union/generic syntax) and `pytest` installed via `pip install pytest`.

- Run `test-aimi-cli.sh` after any change to `plugins/aimi-engineering/scripts/aimi-cli.sh` or files it sources. It is a **dispatcher**: it runs `test-aimi-cli-part{1..4}-*.sh` **concurrently** and aggregates their counts. Each part sources the 179-line `test-aimi-cli-common.sh` preamble (the `assert_*` family, `setup`, `cleanup`) plus `test-aimi-cli-fixtures.sh` for the fixtures more than one part needs, and is runnable on its own for a focused loop. A new test goes in the part that owns its concern — each part's header comment lists its sections — and `EXPECTED_ASSERTIONS` in the dispatcher must be raised to match, because the dispatcher asserts the total and fails the run when it moves.
  - **Serial escape hatch: `--serial` (or `-s`, or `AIMI_TEST_SERIAL=1`).** Concurrent is the default and is ~2.2x faster. Serial mode streams each part's output live instead of buffering it — reach for it when bisecting an intermittent failure, when a part hangs and you need to see how far it got, or on a host where four concurrent parts would thrash. `--parallel`/`-p` forces concurrency back on when `AIMI_TEST_SERIAL` is set in the environment. Counts, the invariant and the exit status are identical either way; only wall time and buffering differ.
  - The run is bounded by its slowest part, not by core count — part 3 (`roadmap-forge`) is ~40-46% of the serial total on its own, which is why four parts on 16 cores gives ~2.2x rather than 4x. The summary prints each part's wall time beside its counts so that imbalance stays visible.
  - Concurrency applies to **this suite only**. `test-worktree-manager.sh` is not parallel-safe — five `serve` assertions collide on a fixed port — and stays serial.
  - **The run ends with a fixed-shape `suite-cost` line** — `cli_lines`, `test_lines`, `assertions`, `wall_seconds`, `mode`, `frame`, always in that order. `grep suite-cost` two transcripts to see the trend mechanically. Two of its fields are environment-scoped and the line names which environment it measured: `wall_seconds` is not comparable across `mode=serial`/`mode=concurrent`, and `assertions` is **2 lower** under `frame=worktree` than `frame=checkout` for the same tree (the worktree-resident CLI case emits 1 assertion where a checkout emits 3, which is also why `EXPECTED_ASSERTIONS` is 3748 vs 3750). Comparing a container run against a main-tree run without reading `frame` looks like two tests vanished.
- Run `test-worktree-manager.sh` after any change to `plugins/aimi-engineering/skills/git-worktree/scripts/worktree-manager.sh`.
- **Run `test-command-blocks.sh` after any change under `plugins/aimi-engineering/commands/`** — including changes that touch only prose. Command files are executed, not read: an agent runs their ` ```bash ` blocks literally, each in its own isolated shell, so a "documentation-only" edit is a code change. This suite extracts every bash-fenced block and checks it parses, avoids bash-only constructs (blocks may run under zsh), does not read a variable that only exists inside a loop, and introduces no variable that nothing in the file assigns. Known findings are grandfathered in `scripts/command-blocks-baseline.txt`; the suite fails when a baselined entry stops firing, so that file shrinks as things are fixed. It cannot see a variable that a *prose sentence* reads — that class is only fixed by moving the logic into `aimi-cli.sh`.
- Run `test-resolve-pr-parallel.sh` after any change to `plugins/aimi-engineering/skills/resolve-pr-parallel/scripts/`. It exists specifically because `test-command-blocks.sh`'s own scope is `commands/*.md` and it does not scan `skills/` at all, leaving these scripts with no other static-analysis safety net.
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
- `plugins/aimi-engineering/scripts/aimi-cli.sh` — all jq/state operations (task file management, story lifecycle, version checks). Prevents model hallucination of bash by centralizing deterministic operations.
- `.claude-plugin/marketplace.json` — marketplace manifest for Claude Code discovery
- `install.sh` — OpenCode translator/installer
- `CHANGELOG.md` — user-facing change log (Keep a Changelog format)
