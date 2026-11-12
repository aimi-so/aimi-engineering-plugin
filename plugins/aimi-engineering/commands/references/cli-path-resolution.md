# CLI Path Resolution

Shared reference for resolving `$AIMI_CLI` and `$WORKTREE_MGR` across all commands. This file is the single source of truth for the CLI resolution logic.

## Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it with the Fast path block below, which is one Bash call; the layers after it run one at a time only when the fast path prints `AIMI_CLI_UNRESOLVED`.

### Fast path: one Bash call

Layers 0, 0-dev, 1 and the Layer 1 validation, each line byte-identical to its section below, in one shell, followed by the [Version Check](#version-check). None of them writes a cache file. Layer 0 comes before Layer 0-dev here because neither line checks for an earlier answer, so the later one wins, and Layer 0-dev must win.

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); fi
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
[ -n "$AIMI_CLI" ] || { echo "AIMI_CLI_UNRESOLVED"; exit 0; }
echo "AIMI_CLI=$AIMI_CLI"
$AIMI_CLI check-version --quiet --fix
```

`AIMI_CLI=<path>` followed by the check-version JSON means resolution and the Version Check are both done: skip every layer below and read the JSON's `status` as the Version Check section says. `AIMI_CLI_UNRESOLVED` means the cache missed (a host the SessionStart hook has not primed): run Layer 2, its cache update and Layer 3 below, one Bash call each, then the Version Check.

### Layer 0-dev: AIMI_DEV_DIR (development override, any host)

```bash
if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi
```

`AIMI_DEV_DIR` names a plugin checkout to run **instead of** the installed copy. It is consulted ahead of `AIMI_PLUGIN_DIR` and on every host (no `CLAUDECODE` gate), and its fifth check refuses a path under `/.worktrees/`. Under it `check-version` answers `dev-override` and never runs `--fix`, and a set-but-invalid value is fatal at exit 1. Rationale: `docs/dev/cli-path-resolution.md`.

### Layer 0: AIMI_PLUGIN_DIR (env var override)

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

Layer 0 first checks that `CLAUDECODE` is unset — when running inside Claude Code, Layer 0 is skipped so the Claude Code cache directory is always used. For non-Claude Code hosts (e.g., OpenCode), it validates AIMI_PLUGIN_DIR with four checks: (1) env var is non-empty, (2) path starts with `/` (absolute), (3) directory exists, (4) target script is executable. If any check fails, silently falls through to Layer 1. Layer 0 does NOT write to global cache — env var check is negligible cost, no side effects.

A relative `AIMI_PLUGIN_DIR` would resolve against the caller's CWD, which is why the absolute-path check stays. Rationale: `docs/dev/cli-path-resolution.md`.

### Layer 0-pin: AIMI_CLI_PINNED (per-call pin, inside `aimi-cli.sh`)

`AIMI_CLI_PINNED` names the install this run means. `aimi-cli.sh` consults it **ahead of both cache files** — `_pinned_cli_path`, called at the top of `read_global_cli_cache` — and honors it on every host, with no `CLAUDECODE` gate. When it is set and valid, neither `~/.config/aimi/cli-path` nor the legacy path is opened at all.

It is per-call and never persisted, validated with `[ -x ]` as an absolute path; a set-but-invalid pin is reported and ignored. It has no command-side snippet, because the CLI honors it itself. Rationale: `docs/dev/cli-path-resolution.md`.

### Layer 1: Global cache (fast path)

Try the new XDG path first; fall back to the legacy path during the migration window.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); fi
```

### Layer 1 validation: verify cached path exists and is executable

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

> The SessionStart hook (`_heal_cli_path_cache()` in `hooks/inspect-session.py`) runs `prime-cache` whenever Layer 1 does not resolve, on Claude Code only; on OpenCode Layer 0 resolves first. A host the hook has not reached recovers by running the CLI once by its absolute path:
>
> ```bash
> bash /abs/path/to/plugins/aimi-engineering/scripts/aimi-cli.sh prime-cache
> ```
>
> A new layer is cheap to write and expensive to mirror: its line must be copied byte-identical into every surface `hooks/auto-approve-cli.sh` matches literally. Rationale: `docs/dev/cli-path-resolution.md`.

### Layer 2: Glob fallback (zsh-safe)

Only runs if Layer 1 failed. Uses `bash -c` to avoid zsh `NOMATCH` errors.

The pipeline keys `sort -V` on each candidate's version segment and admits only a three-part numeric segment, the rule `_resolve_latest_cache_path` in `aimi-cli.sh` owns. Rationale: `docs/dev/cli-path-resolution.md`.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d" " -f2-'); fi
```

### Layer 2 cache update: save for next time

Writes to the new XDG path. `mkdir -p` ensures the directory exists before the atomic write.

```bash
if [ -n "$AIMI_CLI" ]; then _aimi_cfg="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"; mkdir -p "$_aimi_cfg" && printf '%s\n' "$AIMI_CLI" > "$_aimi_cfg/cli-path.tmp" && mv "$_aimi_cfg/cli-path.tmp" "$_aimi_cfg/cli-path" && chmod 600 "$_aimi_cfg/cli-path"; fi
```

### Layer 3: Per-project fallback (last resort)

```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If empty, report error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "aimi-cli.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

## Resolve Worktree Manager Path

**CRITICAL:** The worktree manager script lives alongside the CLI. Resolve `$WORKTREE_MGR` using the same layered strategy.

### Layer 0-dev: AIMI_DEV_DIR (development override, any host)

```bash
if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then WORKTREE_MGR="$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager.sh"; fi
```

Same variable, same five checks, same absent `CLAUDECODE` gate as the CLI's own Layer 0-dev above. The two must move together for the reason the Layer 2 blocks give below: resolving the manager from a different install than the CLI is the same defect one file over, and a dev override that reaches one but not the other produces exactly that split.

### Layer 0: AIMI_PLUGIN_DIR (env var override)

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh" ]; then WORKTREE_MGR="$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh"; fi
```

Layer 0 first checks that `CLAUDECODE` is unset — when running inside Claude Code, Layer 0 is skipped so the Claude Code cache directory is always used. For non-Claude Code hosts, it validates AIMI_PLUGIN_DIR with four checks: (1) env var is non-empty, (2) path starts with `/` (absolute), (3) directory exists, (4) target script is executable. If any check fails, silently falls through to Layer 1. Layer 0 does NOT write to global cache — env var check is negligible cost, no side effects.

### Layer 1: Global cache (fast path)

Try the new XDG path first; fall back to the legacy path during the migration window.

```bash
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null); fi
```

### Layer 1 validation: verify cached path exists and is executable

```bash
if [ -n "$WORKTREE_MGR" ] && [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi
```

### Layer 2: Glob fallback (zsh-safe)

Only runs if Layer 1 failed. Uses `bash -c` to avoid zsh `NOMATCH` errors, and
keys the version comparison on the version path segment for the same reason the
CLI's own Layer 2 above does — canonical rule: `_resolve_latest_cache_path` in
`aimi-cli.sh`. The two must agree: resolving the worktree manager from a
different install than the CLI is the same defect one file over.

```bash
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d" " -f2-'); fi
```

### Layer 2 cache update: save for next time

Writes to the new XDG path. `mkdir -p` ensures the directory exists before the atomic write.

This is no longer the only writer, and it is no longer the reason the file exists. `aimi-cli.sh` now writes `worktree-path` itself, at the three points it already wrote `cli-path` — `check-version --fix`, `cleanup-versions` and `prime-cache` — deriving the manager from the same install root as the CLI (`_persist_worktree_pointer_for`). Until it did, the two pointers were written by different things at different times and could name different installs: a `check-version --fix` moved `cli-path` to the new version while `worktree-path` stayed on the old one, and when the old version was later pruned `$WORKTREE_MGR` became a path to nothing. Keep this block anyway — it is what primes the pointer for a session that resolves the manager before it ever calls a CLI verb.

```bash
if [ -n "$WORKTREE_MGR" ]; then _aimi_cfg="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"; mkdir -p "$_aimi_cfg" && printf '%s\n' "$WORKTREE_MGR" > "$_aimi_cfg/worktree-path.tmp" && mv "$_aimi_cfg/worktree-path.tmp" "$_aimi_cfg/worktree-path" && chmod 600 "$_aimi_cfg/worktree-path"; fi
```

### Layer 3: Per-project fallback (last resort)

```bash
if [ -z "$WORKTREE_MGR" ] && [ -f .aimi/cli-path ]; then WORKTREE_MGR=$(dirname "$(dirname "$(cat .aimi/cli-path)")")/skills/git-worktree/scripts/worktree-manager.sh; if [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi; fi
```

If empty, report error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "worktree-manager.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

## Version Check

After resolving `$AIMI_CLI`, verify the cached CLI path is current:

```bash
$AIMI_CLI check-version --quiet --fix
```

The `--quiet` flag suppresses informational output and `--fix` auto-updates a stale cli-path. This does NOT call `cleanup-versions` (cleanup is manual-only).

**`--fix` heals BOTH pointers, and the second one independently of the first.** The `status` field below reports the cli-path only; the worktree-path is re-derived from whichever install this run resolved and rewritten whenever it disagrees, whatever that status says. That is deliberate rather than incidental — `worktree-path` can be missing or stale while `cli-path` is already `current`, which is precisely the state the two-writer arrangement used to produce — so do not read `"status": "current"` as "nothing was written".

**`--fix` also heals the GLOBAL pointer (`~/.config/aimi/cli-path`, or `$AIMI_CONFIG_DIR/cli-path`), and the JSON then carries `globalCli`.** A stale global pointer — one naming an older versioned install, or an install under a Claude config root other than the current one — used to survive a `current` or `missing` project pointer, so a session in any other project kept resolving the old install. When one is found, `globalCli` is `{status: "stale"|"fixed", storedVersion, latestVersion, storedPath, latestPath}`; when the project pointer is `current` or `missing` the top-level `status`, `storedVersion` and `latestVersion` are the global pointer's, and when the project pointer is itself `stale` or `fixed` its own JSON is unchanged and `globalCli` sits beside it. Without `--fix` a stale global pointer exits 1. `--fix` writes only after the newest install's `aimi-cli.sh` exists, is executable and sits under an `x.y.z` version directory, and reports `fixed` only after re-reading the pointer; otherwise `globalCli.status` stays `stale`, `globalCli.reason` says why and the exit is 0. A current, missing, empty, legacy-file-only or non-versioned pointer adds no key, and the pointer is never compared or written under `AIMI_DEV_DIR`, the converter branch, a valid `AIMI_CLI_PINNED`, or a directory-source install.

**Read the `status` field, not the exit code alone.** Exit 0 covers four different situations, and one of them is not a healthy host:

| `status`   | Exit | Meaning |
|------------|------|---------|
| `current`  | 0 | Stored cli-path is the newest install. Proceed. |
| `fixed`    | 0 | Was stale; `--fix` repointed it. Proceed. |
| `missing`  | 0 | No stored cli-path yet; the JSON names the latest one. Proceed. |
| `unknown`  | 0 | **No plugin version is installed at all.** Nothing was resolved and nothing was fixed. |
| `stale`    | 1 | Stored cli-path is behind and `--fix` was not passed. The JSON is still valid — read it. |

`unknown` used to be unreachable: an empty plugin cache aborted the verb before it could be emitted, so "exits 0" and "a plugin is installed" happened to mean the same thing. They no longer do. A command that treats any exit 0 as healthy will now walk past a host with no plugin installed and fail later at a less obvious place; a command that needs a real install should check for `"status": "unknown"` and tell the user to run `/plugin install aimi-engineering`.

**`$AIMI_CLI` does not persist across Bash tool calls.** Re-read the cache at the top of every subsequent call — see [Per-Call Resolution](#per-call-resolution) below.

## Per-Call Resolution

**Precondition:** this pattern assumes Step 0 (the full Layer 0–3 resolution above) has already run in a prior Bash call and written the cache to the new XDG path. Without that primer, the one-liner below returns empty.

Each Bash tool call is an **isolated shell** — variables set in one call do not exist in the next. Re-read both `$AIMI_CLI` and `$WORKTREE_MGR` from the cache file at the top of every Bash call that needs them.

### $AIMI_CLI one-liner

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
```

The `||` fallback covers the migration window: if only the legacy file exists, it is used. The `: "${VAR:?…}"` guard turns a silent empty into a loud failure that exits the Bash call immediately with a clear message.

### Canonical single-line form (call sites)

The two lines above are two statements — an assignment and a fail-loud guard. Joined by `;` into one line, with every token, the migration-window fallback and the guard's error message unchanged, that is the canonical spelling a call site should use:

```
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
```

**Inline per file, never sourced.** `commands/references/context-budget.md`'s three-way classification is what decides this: a `scripts/aimi-cli.sh` verb is off the table by construction — this snippet exists to locate the CLI, so it cannot itself call the CLI, the same reason Layer 2's note above gives for not calling `_resolve_latest_cache_path` directly — which leaves the always-needed-inline-decision shape as the only fit. Concretely that means a literal `AIMI_CLI=` assignment repeated in every file rather than a shared sourced helper, forced by two independent constraints. First, `scripts/test-command-blocks.sh` Check 4 flags a variable read but never assigned in the same file, and its `ENV_ALLOWLIST` does not carry `AIMI_CLI` — a sourced helper would make every block that reads `$AIMI_CLI` trip that finding, tree-wide, the moment a call site adopts this form. Second, `install.sh`'s `translate_command_body` rewrites `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` to `${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}` by substring substitution inside inlined command bodies only; `commands/references/*.md` — this file included — reaches the OpenCode install through a separate, verbatim whole-tree copy that never calls that function. A sourced helper would carry the Claude Code token to OpenCode untranslated. Verified in isolation: `translate_command_body`, sourced on its own and fed the block above, returns it with only the `CLAUDE_CONFIG_DIR` token swapped and every other byte unchanged, so the existing rewrite already handles this shape with no logic change.

**No call site uses this form yet, including the two examples above.** The block above is a plain fence, not one tagged `bash`: both `scripts/test-command-blocks.sh` and `hooks/tests/test_auto_approve_cli.py` scan only fences tagged `bash` under `commands/**/*.md`, and this file lives inside that tree. `hooks/auto-approve-cli.sh` matches resolution lines by anchored literal regex and does not yet recognize the joined form — piped through the hook, it falls through to a permission prompt rather than being approved. Turning either example above into a live `bash`-tagged occurrence of the joined form before the hook is taught the shape would hand `test_every_resolution_line_in_commands_is_approved` a corpus entry it cannot approve, failing that suite. All 131 call sites — including this file's own two — convert together once the hook knows the form.

### $WORKTREE_MGR one-liner

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
```

**Two guards, because they catch two different failures, and only the first one used to exist.** `${VAR:?word}` fires on an EMPTY variable — the cache file absent, unreadable, or never primed. It says nothing about a variable that read back perfectly well and names a directory that has since been pruned, which is the failure that actually happened: the pointer survived a version cleanup, `$WORKTREE_MGR` expanded to a path to nothing, and the run continued past a guard that had no complaint. `[ -x "$WORKTREE_MGR" ]` is the half that catches that, and it exits non-zero so the Bash call stops there instead of carrying a dangling path into `create`, `serve` or `merge-all`. `$AIMI_CLI`'s own one-liner needs no twin of this: it is INVOKED (`$AIMI_CLI <verb>`), so a dangling path is a loud 127 at the next line — `$WORKTREE_MGR` is too, but only where it is invoked directly, and the sites that pass it into a command substitution or an `|| true` were where the silence came from.

### Failure Signature

Symptom: the Bash call prints `command not found: <subcommand>` with no path prefix before the subcommand name.

Cause: `$AIMI_CLI` (or `$WORKTREE_MGR`) expanded to empty in this Bash call. The shell tried to run the subcommand name as a standalone binary and failed.

Fix: add the per-call re-read one-liner at the top of the failing Bash call. If the re-read itself returns empty, Step 0 has not yet run in this session — run the full Layer 0–3 resolution first.

## Resolve Agent Models

After `$AIMI_CLI` is resolved and the version check passes, run this block **once per command invocation**. It re-reads `$AIMI_CLI` from the cache (each Bash tool call is an isolated shell, and a `--fix` above may have moved it) and echoes the category-to-model map plus the two values the first-run prompt below needs:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
echo "AGENT_MODELS=$($AIMI_CLI resolve-models)"
echo "INTERACTIVITY=$($AIMI_CLI detect-interactivity)"
echo "MODELS_PROMPT=$($AIMI_CLI models-prompt-check)"
```

`resolve-models` always emits a single-line JSON object with exactly five keys:

```json
{"research":"<model-or-inherit>","review":"<model-or-inherit>","design":"<model-or-inherit>","workflow":"<model-or-inherit>","executor":"<model-or-inherit>"}
```

When no `models.json` is configured, every value is the literal string `"inherit"`.

Store the JSON string as `AGENT_MODELS` (or as a working-memory map keyed by category) for the rest of the command invocation.

### Applying the resolved model to a Task call

At each `Task` spawn site, extract the model from `AGENT_MODELS` using the agent's `CATEGORY`:

- For namespaced agents (`subagent_type="aimi-engineering:CATEGORY:NAME"`), use the directory category — one of `research`, `review`, `design`, `workflow`.
- For host built-in `general-purpose` spawns used as **sub-orchestrators** by `/aimi:execute` (the parallel frontend/backend Tasks and the per-story executor), use the `executor` category.

- **When the resolved value is a model string** (anything other than `"inherit"`): add a `model:` line to the Task call with that string as the value.
- **When the resolved value is `"inherit"`**: omit the `model:` line entirely — current behavior is preserved.

Example (model configured for the `research` category):

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  model: claude-sonnet-4-5
  prompt: "…"
```

Example (model is `"inherit"` — line omitted):

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "…"
```

When `AGENT_MODELS` could not be parsed or `$AIMI_CLI` was not resolved, treat every category as `"inherit"` and proceed — never abort a command because model resolution failed.

### First-run configuration prompt (interactive hosts only)

The block above already echoed `INTERACTIVITY` (`detect-interactivity`) and `MODELS_PROMPT` (`models-prompt-check`). A command that resolved its own interactivity mode with a flag (brainstorm's `--non-interactive`) uses that mode in place of `INTERACTIVITY`.

**Only** when `INTERACTIVITY` is `picker` AND `MODELS_PROMPT` is `prompt`, show the user exactly this question via `AskUserQuestion`:

> Question: "No subagent model configuration found — agents inherit the main thread's model. Configure model selection per category?"
> Options: A — "Configure now" ; B — "Keep the default (inherit)"

**Option A — "Configure now":**

The model SELECTION must happen at the LLM-orchestrator layer using the interactive picker (`AskUserQuestion`), NOT inside a bash subprocess. The bash layer's job is only to list available models and write the config from explicit choices.

1. Run `$AIMI_CLI list-models` to get the host's available models as a JSON array:

   ```bash
   _aimi_available_models=$($AIMI_CLI list-models)
   ```

2. Use `AskUserQuestion` with **five questions in one call** — one per category — letting the user pick a model for each. Each question's options are the models returned by `list-models` (plus the picker's automatic "Other" for free-form input):

   - "Model for research/reading tasks (research)?" — suggested default: Claude Code → `haiku`, OpenCode → an Anthropic Haiku model id from `opencode models`
   - "Model for review and analysis (review)?" — suggested default: Claude Code → `opus`, OpenCode → an Anthropic Opus model id
   - "Model for design tasks (design)?" — suggested default: Claude Code → `sonnet`, OpenCode → an Anthropic Sonnet model id
   - "Model for workflow tasks (workflow)?" — suggested default: Claude Code → `sonnet`, OpenCode → an Anthropic Sonnet model id
   - "Model for execution sub-orchestrators (executor)?" — suggested default: Claude Code → `sonnet`, OpenCode → an Anthropic Sonnet model id

3. Run `$AIMI_CLI detect-models --research <chosen_research> --review <chosen_review> --design <chosen_design> --workflow <chosen_workflow> --executor <chosen_executor>` with the user's picks to write the config.

4. Re-run `$AIMI_CLI resolve-models` to refresh `AGENT_MODELS`.

**Option B — "Keep the default (inherit)":** no action needed beyond dismissal.

- Regardless of the choice (A or B): always run `$AIMI_CLI models-prompt-dismiss` so the prompt is never shown again.

When `INTERACTIVITY` is not `picker` (agent-mode / CI) OR `MODELS_PROMPT` is `skip`, do nothing — proceed silently with the already-resolved map. The prompt is shown at most once ever.

## CWD Auto-Discovery

The CLI automatically discovers the project root by walking up the directory tree from CWD looking for `.aimi/`. This means:

- The CLI can be invoked from any subdirectory within the project tree
- No need to `cd` to the project root before running CLI commands
- If `.aimi/` is not found in any parent directory, the CLI exits with an error

**Note:** The `.aimi/cli-path` fallback in the resolution snippet above uses a relative path (`.aimi/cli-path`). This fallback only works when CWD is the project root. The primary glob-based resolution is unaffected and works from any directory.
