# CLI Path Resolution

Shared reference for resolving `$AIMI_CLI` and `$WORKTREE_MGR` across all commands. This file is the single source of truth for the CLI resolution logic.

## Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it using the layered strategy below. Each command is a separate Bash call (no compound operators).

### Layer 0-dev: AIMI_DEV_DIR (development override, any host)

```bash
if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi
```

`AIMI_DEV_DIR` names a plugin checkout to run **instead of** the installed copy, and it is the first thing consulted — ahead of the `AIMI_PLUGIN_DIR` layer below. It exists so testing a branch does not require editing the installed cache in place, which is how a "temporary" edit becomes the machine's plugin.

**It carries no `CLAUDECODE` gate, and that asymmetry with `AIMI_PLUGIN_DIR` is deliberate.** `AIMI_PLUGIN_DIR` names where the compound-plugin converter *installed* the plugin, so inside Claude Code — which has an install of its own under the plugin cache — honoring it would let another host's install win, and the layer below is skipped there for exactly that reason. `AIMI_DEV_DIR` names a tree the operator is deliberately testing; gating it on `CLAUDECODE` would make it work only in the host where nobody needs it.

The five checks are the four `AIMI_PLUGIN_DIR` applies below, plus a refusal of any path under a `/.worktrees/` segment — the same refusal `write_global_cli_cache` in `aimi-cli.sh` already applies, and for the same reason: a worktree copy is ephemeral, so pointing a session at one leaves every later call at exit 127 once the worktree is cleaned up. Written as a prefix-strip comparison rather than a `case` so the whole guard stays one line.

`aimi-cli.sh` honors the same variable from the inside: **every** invocation prints one unconditional stderr notice naming the path it resolved (unconditional because the defect being closed is a real install *silently* shadowed — the line belongs on the success path, not only on failure), `_resolve_skills_base_dir` answers the dev tree's `skills/`, and `check-version` answers a status of its own, `dev-override`, **without attempting `--fix`**. That last part is the point: `--fix` writes the resolved install into the *global* cli-path cache read by every later session in every project on the machine, so a `--fix` under the override would persist a development tree machine-wide and outlive the shell that set the variable. A value that is set but invalid is fatal at exit 1 rather than falling through to the install — falling through would be the same silent shadowing with the sign flipped.

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

> **A directory-source install (marketplace source: `directory`) legitimately writes a path here too, not only a versioned cache copy.** Layer 1's cache file just holds whatever `prime-cache` last wrote — for a directory-source Claude Code host that is the checkout's own `scripts/aimi-cli.sh`, not a copy under `plugins/cache/`. No layer in this file produces it on its own: Layer 0 is gated off whenever `CLAUDECODE` is set (every Claude Code session), Layer 2's glob below only ever matches `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh` and a directory source has no copy there, and Layer 3's `.aimi/cli-path` is created by nobody. Layer 0-dev above is the one exception, and it is not one in practice: it is an override the operator sets by hand for one tree, never something a fresh host arrives at. So on a fresh directory-source host every layer legitimately fails and `$AIMI_CLI` resolves to empty — which means `/aimi:init` itself cannot self-heal, since its own Step 0 needs `$AIMI_CLI` resolved before it can call `prime-cache` at all.
>
> **The SessionStart hook now writes Layer 1 whenever it does not already resolve**, so a session started after the plugin is installed finds the cache primed and the four layers above succeed at Layer 1. `_heal_cli_path_cache()` in `hooks/inspect-session.py` — registered on `SessionStart` in `hooks/hooks.json`, and the first thing that module runs — reads `$CLAUDE_PLUGIN_ROOT`, which Claude Code puts in the hook process's own environment and which is the one value that names the running install without guessing. Only when the Layer 1 read comes back empty or non-executable does it spawn that install's `scripts/aimi-cli.sh prime-cache`; it writes no cache file itself, because confinement, atomicity and the 0600 mode all belong to `prime-cache` and invoking the verb rather than re-deriving its rules is the whole point of the shape. The cheap Layer 1 read is the gate deliberately: a `prime-cache` spawn measured 299 ms against that module's 500 ms budget while the read plus the executable check measured 0.025 ms, so a host that already resolves pays nothing. It never raises — a missing `CLAUDE_PLUGIN_ROOT`, a root with no executable `scripts/aimi-cli.sh`, an unreadable config dir, a non-zero exit and a timeout each leave the session exactly as it was found.
>
> **This is Claude Code only, and OpenCode needs it less.** `install.sh` registers no hooks at all — `grep -i hook install.sh` returns nothing — so an OpenCode session never runs the healing even though the hook files travel with the install. It does not have to: `CLAUDECODE` is unset there, which is precisely the condition Layer 0 waits for, and `install.sh` writes `AIMI_PLUGIN_DIR` into the shell profile, so resolution succeeds one layer earlier than the cache file this healing exists to write.
>
> **Recovery, for a host the hook has not reached** — a session already open when the plugin was installed, or one where hooks are disabled — is running the CLI once by its absolute path:
>
> ```bash
> bash /abs/path/to/plugins/aimi-engineering/scripts/aimi-cli.sh prime-cache
> ```
>
> That single invocation writes Layer 1 directly (bypassing the four-layer search entirely, since the CLI is being run by a path the operator already knows), and every later `/aimi:*` command in the session resolves normally from there. It is the same verb the hook spawns, run by hand — so it repairs the session in front of you, and a new session would have healed itself anyway.
>
> **A new Layer 2b was the route NOT taken, and the reason it was rejected still stands even though it is no longer the reason nothing is automated.** The resolution snippets in this file are matched *literally* by `hooks/auto-approve-cli.sh`'s Patterns 7 and 8, built from `GLOB_VERSION_TAIL` near the top of that file — so a new layer's command text would need a byte-identical mirror in this file, `hooks/auto-approve-cli.sh`, the `--help` EXAMPLES block in `aimi-cli.sh`, `skills/resolve-pr-parallel/scripts/_resolve-cli.sh`, `commands/review.md`, `commands/validate-bug.md`, the top-level `CLAUDE.md`, and three test suites. One character of drift between any two of those turns every Layer 2 call into a permission prompt instead of an auto-approval. That cost is unchanged and is why the manual bootstrap stood alone for as long as it did; what changed is that the SessionStart healing above buys the automation without paying it, since it runs outside the resolution snippets entirely and touches none of those mirrors. Kept here so the mirror cost is not re-derived, and so the next proposal for a new layer is weighed against it.
>
> **The cost above is a measurement, not a warning, and it has since been paid twice in one commit** — once to add the numeric filter to `GLOB_VERSION_TAIL` and every block built from it, and once to add Layer 0-dev. Both moved all seven surfaces together, which is the only way this is survivable; the hook additionally keeps the pre-filter tail approved as a legacy form, so a command body that entered a conversation before the change is not suddenly prompted for. The lesson is unchanged: a layer is cheap to write and expensive to mirror, and the mirror is what the user actually feels.
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

The `grep -E` between the `sed` and the `sort` is load-bearing, not decoration.
`sort -V` is a total order over arbitrary strings, not a filter: a cache
directory that is not a version at all still gets ranked, and gets ranked
*above* the real ones. Measured — a sibling named `1.124.0.bak` beside
`1.124.0` wins, and a directory named `zz` beats `1.127.0`. A segment therefore
only counts when it looks like a version: three numeric parts and nothing else.

This is an inline copy of `_resolve_latest_cache_path` in `aimi-cli.sh`, which
is the canonical rule; it cannot be called here because it lives inside the
file this block is still looking for.

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
