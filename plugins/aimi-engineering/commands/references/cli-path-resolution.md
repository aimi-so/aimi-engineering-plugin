# CLI Path Resolution

Shared reference for resolving `$AIMI_CLI` and `$WORKTREE_MGR` across all commands. This file is the single source of truth for the CLI resolution logic.

## Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it using the four-layer strategy below. Each command is a separate Bash call (no compound operators).

### Layer 0: AIMI_PLUGIN_DIR (env var override)

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

Layer 0 first checks that `CLAUDECODE` is unset — when running inside Claude Code, Layer 0 is skipped so the Claude Code cache directory is always used. For non-Claude Code hosts (e.g., OpenCode), it validates AIMI_PLUGIN_DIR with four checks: (1) env var is non-empty, (2) path starts with `/` (absolute), (3) directory exists, (4) target script is executable. If any check fails, silently falls through to Layer 1. Layer 0 does NOT write to global cache — env var check is negligible cost, no side effects.

All four checks matter, and the absolute-path one is not redundant with the executable one: a **relative** `AIMI_PLUGIN_DIR` (a bare `.` being the worst case) makes `$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh` resolve against the caller's current working directory, so any repository that ships its own executable `scripts/aimi-cli.sh` would be run instead of the plugin's.

> **`skills/resolve-pr-parallel/scripts/_resolve-cli.sh`** mirrors this Layer 0 with one addition that has no counterpart elsewhere in this document: when `AIMI_PLUGIN_DIR` does not resolve, it falls back to `CLAUDE_PLUGIN_ROOT` (without the `CLAUDECODE` gate, since that variable is only ever set by Claude Code itself) under the **same four guards**. That branch lives only in that sourced helper — command authors never write it — which is why it is documented here as a note rather than as its own layer.

### Layer 1: Global cache (fast path)

Try the new XDG path first; fall back to the legacy path during the migration window.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); fi
```

### Layer 1 validation: verify cached path exists and is executable

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

> **A directory-source install (marketplace source: `directory`) legitimately writes a path here too, not only a versioned cache copy.** Layer 1's cache file just holds whatever `prime-cache` last wrote — for a directory-source Claude Code host that is the checkout's own `scripts/aimi-cli.sh`, not a copy under `plugins/cache/`. Nothing bootstraps it automatically: Layer 0 is gated off whenever `CLAUDECODE` is set (every Claude Code session), Layer 2's glob below only ever matches `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh` and a directory source has no copy there, and Layer 3's `.aimi/cli-path` is created by nobody. So on a fresh directory-source host every layer legitimately fails and `$AIMI_CLI` resolves to empty — which means `/aimi:init` itself cannot self-heal, since its own Step 0 needs `$AIMI_CLI` resolved before it can call `prime-cache` at all. The one escape is running the CLI once by its absolute path:
>
> ```bash
> bash /abs/path/to/plugins/aimi-engineering/scripts/aimi-cli.sh prime-cache
> ```
>
> That single invocation writes Layer 1 directly (bypassing the four-layer search entirely, since the CLI is being run by a path the operator already knows), and every later `/aimi:*` command in the session resolves normally from there. It is a manual, once-per-host step, not something a command can trigger on its own behalf.
>
> **Automating this into a new Layer 2b is out of scope on purpose.** The resolution snippets in this file are matched *literally* by `hooks/auto-approve-cli.sh`'s Patterns 7 and 8, built from `GLOB_VERSION_TAIL` around line 58 of that file — so a new layer's command text would need a byte-identical mirror in this file, `hooks/auto-approve-cli.sh`, the `--help` EXAMPLES block in `aimi-cli.sh`, `skills/resolve-pr-parallel/scripts/_resolve-cli.sh`, `commands/review.md`, `commands/validate-bug.md`, the top-level `CLAUDE.md`, and three test suites. One character of drift between any two of those turns every Layer 2 call into a permission prompt instead of an auto-approval. The manual `prime-cache` bootstrap above exists because paying that mirror cost is not justified for a one-time, once-per-host step.
>
> **Refuted alternative, recorded so it is not re-derived:** `CLAUDE_PLUGIN_ROOT` is NOT usable as a Layer 0b. It was measured unset in the Bash-tool environment — exactly where these resolution snippets execute — so a Layer 0b keyed on it would never fire for the host it would need to help.

### Layer 2: Glob fallback (zsh-safe)

Only runs if Layer 1 failed. Uses `bash -c` to avoid zsh `NOMATCH` errors.

The pipeline picks the newest **version**, and that is not the same as the last
line `ls` prints: `ls` collates `1.121.3` before `1.9.0`, because `1` sorts
below `9` at the third character. A plain `sort -V` over the whole path is
wrong too — the glob spans two wildcards, so it would order by
marketplace-entry directory first and by version only inside one entry. So each
candidate is prefixed with its own version segment and `sort -V` keys on that.
This is an inline copy of `_resolve_latest_cache_path` in `aimi-cli.sh`, which
is the canonical rule; it cannot be called here because it lives inside the
file this block is still looking for.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | sort -V | tail -1 | cut -d" " -f2-'); fi
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

**CRITICAL:** The worktree manager script lives alongside the CLI. Resolve `$WORKTREE_MGR` using the same four-layer strategy.

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
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | sort -V | tail -1 | cut -d" " -f2-'); fi
```

### Layer 2 cache update: save for next time

Writes to the new XDG path. `mkdir -p` ensures the directory exists before the atomic write.

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

### $WORKTREE_MGR one-liner

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
```

### Failure Signature

Symptom: the Bash call prints `command not found: <subcommand>` with no path prefix before the subcommand name.

Cause: `$AIMI_CLI` (or `$WORKTREE_MGR`) expanded to empty in this Bash call. The shell tried to run the subcommand name as a standalone binary and failed.

Fix: add the per-call re-read one-liner at the top of the failing Bash call. If the re-read itself returns empty, Step 0 has not yet run in this session — run the full Layer 0–3 resolution first.

## Resolve Agent Models

After `$AIMI_CLI` is resolved and the version check passes, call `resolve-models` **once per command invocation** to obtain the category-to-model map. Re-read `$AIMI_CLI` from the cache before calling (each Bash tool call is an isolated shell):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AGENT_MODELS=$($AIMI_CLI resolve-models)
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

After `AGENT_MODELS` is resolved, check once whether the user should be offered the one-time model-selection prompt:

```bash
_aimi_interactivity=$($AIMI_CLI detect-interactivity)
_aimi_prompt_check=$($AIMI_CLI models-prompt-check)
```

**Only** when `detect-interactivity` returns `picker` AND `models-prompt-check` returns `prompt`, show the user exactly this question via `AskUserQuestion`:

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

When `detect-interactivity` is not `picker` (agent-mode / CI) OR `models-prompt-check` returns `skip`, do nothing — proceed silently with the already-resolved map. The prompt is shown at most once ever.

## CWD Auto-Discovery

The CLI automatically discovers the project root by walking up the directory tree from CWD looking for `.aimi/`. This means:

- The CLI can be invoked from any subdirectory within the project tree
- No need to `cd` to the project root before running CLI commands
- If `.aimi/` is not found in any parent directory, the CLI exits with an error

**Note:** The `.aimi/cli-path` fallback in the resolution snippet above uses a relative path (`.aimi/cli-path`). This fallback only works when CWD is the project root. The primary glob-based resolution is unaffected and works from any directory.
