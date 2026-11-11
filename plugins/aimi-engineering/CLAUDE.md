# Aimi Engineering Plugin - Development Guidelines

## Where the rest lives

This file holds the rules that apply to every change and loads whole. The notes for one
area live under `docs/dev/`; read the one that matches what you are about to change. A
`§ <heading>` citation anywhere in the tree names a heading in one of these files.

| File | Read before changing |
|---|---|
| `docs/dev/hooks.md` | a hook guard (staging-file, raw forge write) or a bypass env (§ Guard Bypass Envs) |
| `docs/dev/ratchets.md` | the artifact-language or spec-section ratchet, or their baselines |
| `docs/dev/routers.md` | `commands/plan.md`, `commands/execute.md`, their step files, or the OpenCode references allowlist |
| `docs/dev/story-lifecycle.md` | `remove-story`, `set-verification`, `acknowledge-*`, `judge-verification`, `triage-verify`, `split-detect` |
| `docs/dev/planning-verbs.md` | `story-merge`, `apply-audit-patches`, `validate-outline`/`validate-staging`/`outline-shift`, `plan_checks.py`, advisory smells |
| `docs/dev/cli-verbs.md` | the research and spec-derivation verbs, `check-version`, `slugify`, `detect-design-bundle` |
| `docs/dev/roadmap.md` | a `roadmap-*` verb, `roadmap.py`, or the `roadmap.json` shape |
| `docs/dev/story-executor.md` | `skills/story-executor/SKILL.md`, the worker's brief, or how a command spawns it |
| `docs/dev/tasks-schema.md` | the `tasks.json` shape or a validator over it |
| `docs/dev/jq-census.md` | a `jq` call in `aimi-cli.sh` or under `commands/` (the principle stays below) |

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
│   ├── docs/dev/                # Development notes this file indexes (see below)
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
- Every guard has a bypass env, `AIMI_<NAME>_GUARD=off`, listed in `docs/dev/hooks.md` § Guard Bypass Envs. A new guard adds its row there.

## Command Conventions

- Use `aimi:` prefix for all commands — always show `/aimi:plan`, `/aimi:execute`, etc. in output, NEVER the fully-qualified `/aimi-engineering:plan` form
- Use `disable-model-invocation: true` for side-effect commands
- Wrapper commands should pass `$ARGUMENTS` to wrapped commands
- Document allowed-tools in frontmatter with specific Bash prefixes
- **Agents declare their tools with the `tools` key; commands and skills keep `allowed-tools`.** Claude Code reads `tools` (a comma string) on an agent file and ignores `allowed-tools` there, so a list under the old key restricted nothing. The list is an accident guard and not a sandbox: an agent that lists Bash can still write, because a shell redirect needs no Write tool. A tool name the host does not have is dropped silently; Grep and Glob are absent on some Claude Code builds, which is why every read-only agent that lists them also lists Bash, so search keeps working. `scripts/tests/test_agent_tools.py` pins each agent's list (`TABLE`), requires that every agent declaring `tools` is in the table, and reads the agent files as text. An agent that is in no table row declares nothing and keeps every tool.
- Validate inputs before passing to external commands
- See `commands/references/user-communication.md` for the wording/tone rules governing text written to the human reader (completion reports, chat explanations, `AskUserQuestion` prompts); this file references them (no duplication)
- `commands/` (including `commands/references/`) is subject to a size discipline, the same as `SKILL.md` below — but the discipline that keeps a command small is a rule about *where content belongs*, not a line count to trim toward. `commands/references/context-budget.md` is its normative home: a deterministic procedure belongs in an `aimi-cli.sh` verb, a rare conditional judgment in a lazily-read `commands/references/` file, an always-needed "does this apply?" check inline in the parent. It is not restated here, and the enforceable per-file budget that backs it arrives with `scripts/test-command-size.sh`
- Before adding a new validation gate — a verb that returns a verdict, a validator warning, a criterion a story must satisfy — answer the question in `commands/references/context-budget.md` § *The Question Every New Gate Must Answer* first; that same section is where the three fields sharing the word `verification` are told apart. Neither is restated here, for the reason this file already gives twice about one rule living in two places

## Skill Conventions

- Keep SKILL.md under 300 lines
- Move detailed schemas/examples to `references/` directory
- Include trigger phrases in description
- Use imperative writing style
- Include Input Sanitization section for skills that process user data
- Document Available Capabilities for Task-spawned agents

## Agent Model Categories

A namespaced agent (`subagent_type="aimi-engineering:<category>:<name>"`) runs on the model configured for the category named by its directory under `agents/` (`research`, `review`, `design`, `workflow`); the spawn site reads it from `AGENT_MODELS` and omits the `model:` line when the value is `inherit`. `commands/references/cli-path-resolution.md` § Applying the resolved model to a Task call is the rule's home and is not restated here. The category is therefore a property of where the agent file lives, and moving a file changes which model it runs on.

- **`aimi-cross-story-auditor` runs on the review model category.** It lives at `agents/review/aimi-cross-story-auditor.md` and Phase 3d.5 (`commands/references/plan/phase-3d5-audit-spawn.md`) spawns it as `aimi-engineering:review:aimi-cross-story-auditor` with `AGENT_MODELS.review`. It was `aimi-engineering:workflow:` with `AGENT_MODELS.workflow` before, so a user who configured those two categories differently now gets a different model for the audit. The auditor reads a plan and judges it, which is what the review category is for. `install.sh` translates it as `aimi-cross-story-auditor` by its `agents/*/*.md` glob, so the OpenCode name did not change.
- **Its size budget is stepped.** The agent file is over the shared 16384-byte ceiling, so `scripts/command-size-baseline.txt` carries a line for `agents/review/aimi-cross-story-auditor.md` at the smallest multiple of 4096 that holds it. An edit that pushes the file past that number, or shrinks it into the step below, changes the line in the same commit; re-measure with `wc -c`.

## Forge Verbs

The forge verbs are `aimi-cli.sh` verbs (`forge-*`), and **GitHub and GitLab are the only adapters**: any other host gets manual steps. `forge-tag-create` and `forge-release-create` are the two that publish a tag and a release; both exist in `scripts/aimi-cli.sh` (`cmd_forge_tag_create`, `cmd_forge_release_create`) and `forge-release-create` makes a missing annotated tag itself and resumes a re-run. The AI reaches them through `skills/forge/SKILL.md`, which asks the user before every write and in agent mode only prints the call. `commands/references/forge-contract.md` is the contract's home (envelope, statuses, the tag and release rules) and `commands/references/publish-confirmation.md` the confirmation contract; neither is restated here. **Neither verb, nor `deps-recipe-record`, is in `hooks/auto-approve-cli.sh`:** a write the user must approve is meant to prompt, the same reasoning as `set-verification`. The raw `gh`/`glab` counterparts are refused by the hook in `### Raw forge write guard`.

## Dependency Recipes

`worktree-manager.sh install-deps <worktree-name>` and `install-deps --root` (the checkout the command runs from, with no `.worktrees/` containment check) install a repository's dependencies with no fallback and end their stdout with one `DEPS_STATUS=<status>` line (`ok`, `nothing-to-install`, `needs-recipe` or `failed`). The install is recorded in a marker, `aimi-deps.json`, in the worktree's git directory, so it never shows in `git status` and a re-run with the same command and lockfile hash installs nothing. `/aimi:execute` installs every execution root before its first wave, whether or not a story is visual; `serve start <worktree-name> [--dir <subfolder>]` serves one validated first-level subfolder and never borrows the main checkout's dependencies. `merge <worktree-name> [--subject <s>]` and `merge-all ... [--subject-for <name> <s>]...` give the merge commit a readable subject with `US-NNN` tokens removed. The mechanics are in `skills/git-worktree/SKILL.md` and the script's own usage text.

For a root whose status is `needs-recipe`, `commands/references/dependency-setup.md` is the procedure: read the repository's own instructions, propose one plain command, ask once, then record it with `deps-recipe-record`. That verb makes one crossing into `scripts/deps_recipe.py` inside the CLI lock, writes `dependencies.install[<project key>]` in `.aimi/config.json` by atomic rename, and refuses an unsafe command or key, a malformed config and a git-tracked `.aimi/config.json` (the reader never trusts a recipe in a tracked file). It refuses without `python3`. Tests: `scripts/tests/test_deps_recipe.py`.

## Deliverable Branch and the Closes Rule

`metadata --with-deliverable-branch` adds `.deliverableBranch` to the metadata object: the phase's branch (derived from the roadmap the way execute's Claim the Phase step derives it) for a phase-scoped split member, and `metadata.branchName` for every other file. `commands/open-pr.md` reads it in Steps 2a and 4a, counts plans rather than tasks files, and renders a `Closes` line for `metadata.issues` only when the plan's deliverable branch is the PR's branch; a plan split across repositories renders none, because one repository's PR could close an issue another repository's PR leaves open. Tests: `scripts/tests/test_open_pr_deliverable.py`.

## Output Files

All task execution files go in `.aimi/tasks/`:

- `YYYY-MM-DD-[feature-name]-tasks.json` - Structured task list with user stories
- `<feature-slug>/roadmap.json` + `<feature-slug>/phase-N[.M][-slug]/` - Phase/milestone roadmap layer for large-scope features (see `docs/dev/roadmap.md` § Roadmap File Schema). Each phase folder holds `<feature-slug>-phase-N-tasks.json` (materialized by `/aimi:plan --phase N`) and `handoff.md` (written by `roadmap-write-handoff`). Single-scope-context features never create this layout — they use the flat `YYYY-MM-DD-[feature-name]-tasks.json` form above, with zero overhead.

> The CLI auto-discovers `.aimi/` by walking up from CWD -- no need to be in the project root to run commands.

Learnings are stored in project files (not separate progress log):

- `CLAUDE.md` (root) - Project-wide patterns and conventions
- `AGENTS.md` (plugin-level) - Single source of truth for spawned agent output compression rules; portable across tools (Claude Code, OpenCode). Per-directory AGENTS.md files in skills/ extend these base rules with domain-specific patterns

## What stays `jq`, and why

**The organising principle: port where input the script does not control enters; leave it where the script is only talking to itself.** That one sentence is what separated the invocations the `ref/jq-nao-forge-para-python` branch moved into Python from the ones it left in place, and it is what `ref/leituras-comandos-para-verbos` (stories 01–04) then applied to the command layer's own jq — the same test, a different surface. It is the normative home of that boundary for **both** `aimi-cli.sh` and `commands/`, the same family of rule as the one-crossing invariant below, which is why it lives here rather than in the top-level `CLAUDE.md`. That file carries a pointer to this section and no second statement of it.

**This section widened rather than gaining a sibling.** The command layer carries jq of its own, and after stories 02–04 replaced 33 of its 37 file-opening reads with CLI verb calls, what remains there answers to the identical test as what remains in the script. A second section next to this one would hand a reader two places to look for one rule — the exact shape root `CLAUDE.md` already warns produced the last drift — so the title above no longer names `aimi-cli.sh` alone, and the `commands/` census in `docs/dev/jq-census.md` is a second table under the same organising sentence, not a second rule.

**This section exists because the reasons used to live in a conversation.** "Is there jq left?" was asked and re-derived from scratch twice in one session, because nothing in the tree answered it. A maintainer asking it now reads this section instead of re-scanning the tree.

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

## Performance Guidelines

1. **Pointer-only handoff** - Spawn prompts carry only the story id in a `task_pointer` block; each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action
   - Keeps the orchestrator's working memory slim across waves — no inlined story body, no inlined prototype HTML in the spawn prompt
   - Prototype files are read by the subagent itself using the Read tool when `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set

2. **Guidelines by path** - The orchestrator finds the project's `CLAUDE.md`/`AGENTS.md` and passes their absolute paths as `PROJECT_GUIDELINES`; the worker reads them itself. The orchestrator never reads or inlines them.

3. **The worker reads its own brief** - A story worker's spawn prompt is a fixed pointer ("read `EXECUTOR_BRIEF` in full and follow it") plus the input values; `EXECUTOR_BRIEF` is `skills/story-executor/SKILL.md`, resolved beside `$AIMI_CLI`. Never paste, summarize or paraphrase the skill into a spawn prompt: there is one copy of every executor rule, and the worker always reads the same text. `docs/dev/story-executor.md` records why.

4. **Fresh context per story** - Each Task agent starts with clean context
   - No memory carryover between stories
   - Learnings persist via CLAUDE.md/AGENTS.md files

5. **Spawned agent output behavior** - See `AGENTS.md` for output compression, safety escapes, and context-adaptive verbosity rules
   - AGENTS.md defines the rules; this file references them (no duplication)
   - AGENTS.md is portable across tools (Claude Code, OpenCode) and is the single source of truth for spawned agent behavior

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
