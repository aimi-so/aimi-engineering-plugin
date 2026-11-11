# CLI Path Resolution: Why

The reasoning behind `commands/references/cli-path-resolution.md` § Resolve CLI Path, moved out of that file because every command reads it at Step 0. The reference keeps each layer's line and one sentence of rule; read this when you change a layer, a resolution line, or `hooks/auto-approve-cli.sh`.

## Layer 0-dev: AIMI_DEV_DIR

`AIMI_DEV_DIR` names a plugin checkout to run **instead of** the installed copy, and it is the first thing consulted — ahead of the `AIMI_PLUGIN_DIR` layer below. It exists so testing a branch does not require editing the installed cache in place, which is how a "temporary" edit becomes the machine's plugin.

**It carries no `CLAUDECODE` gate, and that asymmetry with `AIMI_PLUGIN_DIR` is deliberate.** `AIMI_PLUGIN_DIR` names where the compound-plugin converter *installed* the plugin, so inside Claude Code — which has an install of its own under the plugin cache — honoring it would let another host's install win, and the layer below is skipped there for exactly that reason. `AIMI_DEV_DIR` names a tree the operator is deliberately testing; gating it on `CLAUDECODE` would make it work only in the host where nobody needs it.

The five checks are the four `AIMI_PLUGIN_DIR` applies below, plus a refusal of any path under a `/.worktrees/` segment — the same refusal `write_global_cli_cache` in `aimi-cli.sh` already applies, and for the same reason: a worktree copy is ephemeral, so pointing a session at one leaves every later call at exit 127 once the worktree is cleaned up. Written as a prefix-strip comparison rather than a `case` so the whole guard stays one line.

`aimi-cli.sh` honors the same variable from the inside: **every** invocation prints one unconditional stderr notice naming the path it resolved (unconditional because the defect being closed is a real install *silently* shadowed — the line belongs on the success path, not only on failure), `_resolve_skills_base_dir` answers the dev tree's `skills/`, and `check-version` answers a status of its own, `dev-override`, **without attempting `--fix`**. That last part is the point: `--fix` writes the resolved install into the *global* cli-path cache read by every later session in every project on the machine, so a `--fix` under the override would persist a development tree machine-wide and outlive the shell that set the variable. A value that is set but invalid is fatal at exit 1 rather than falling through to the install — falling through would be the same silent shadowing with the sign flipped.

## Layer 0: AIMI_PLUGIN_DIR

All four checks matter, and the absolute-path one is not redundant with the executable one: a **relative** `AIMI_PLUGIN_DIR` (a bare `.` being the worst case) makes `$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh` resolve against the caller's current working directory, so any repository that ships its own executable `scripts/aimi-cli.sh` would be run instead of the plugin's.

> **`skills/resolve-pr-parallel/scripts/_resolve-cli.sh`** mirrors this Layer 0 with one addition that has no counterpart elsewhere in this document: when `AIMI_PLUGIN_DIR` does not resolve, it falls back to `CLAUDE_PLUGIN_ROOT` (without the `CLAUDECODE` gate, since that variable is only ever set by Claude Code itself) under the **same four guards**. That branch lives only in that sourced helper — command authors never write it — which is why it is documented here as a note rather than as its own layer.

## Layer 0-pin: AIMI_CLI_PINNED

**Why it exists, stated as the asymmetry it closes rather than as a feature.** `_resolve_latest_cache_path` is parameterized on `config_dir`, and every one of its call sites passes `_claude_config_dir()` — so the **writer** of the cache always knows which plugin cache root is the right one. `_validate_cached_cli_path`'s versioned-cache arm is `*/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`, whose leading `*/` anchors no root — so the **reader** accepts a path under any of them and never asks. With more than one cache root installed, "which CLI is this" can therefore answer differently between two calls of a single run, with nothing on either side saying so. A caller that has already decided says so once, here.

**Validated with `[ -x ]`, never `[ -f ]` or `[ -e ]`, and absolute.** This is the third instance of a shape the tree already carries twice — `CV_CLI` in `commands/execute.md` and `PROBE_CLI` in `skills/story-executor/SKILL.md` — and it obeys the same rules those two established: an executable test rather than an existence test, an absolute path, its own stderr prefix, and no persistence. A file that is present but not executable resolves nothing, so admitting it would only move the failure to the invocation, where it reads as a broken CLI rather than as a bad pin. Validating by textual prefix instead of by `[ -x ]` is exactly what let a symlink into a worktree past `write_global_cli_cache`'s guard and produced the exit 127 recorded in `golden_from_jq.json`.

**It is PER-CALL and is never persisted, and that last rule has teeth rather than being a convention.** Nothing writes it to `~/.config/aimi/cli-path`, to `.aimi/cli-path`, or to the worktree pointer; `prime-cache` additionally refuses to let a pin answer its own already-current check, so a pin cannot suppress a cache write and then look as though it had been persisted. `write_global_cli_cache` refuses any `/.worktrees/` path in two places and `_dev_dir_path` refuses one on the same ground — persisting a per-run choice hands it to every later session in every project on the machine, which is the vanishing-worktree bug those guards exist to close.

**Set-but-invalid is reported and ignored, not fatal** — the one place this diverges from Layer 0-dev above. An invalid `AIMI_DEV_DIR` exits 1, because falling through would silently give the operator the install they did not ask for. A pin only fixes one answer out of several the ordinary layers can still reach, so a stale one degrades to those layers and says so, naming the value. Either way `main()` prints one line per process: a notice naming the pinned path when it is honored, a warning naming the rejected value when it is not.

**There is deliberately no command-side snippet for this layer, and the reason is the mirror cost measured in the Layer 1 note below.** The blocks in this file are matched *literally* by `hooks/auto-approve-cli.sh`, so a new fenced resolution line here needs a new hook pattern (and a legacy twin beside it) in the same commit, plus a byte-identical copy in every other surface carrying the idiom. That cost is real and is unpaid here: the pin is honored inside the CLI, where it needs no snippet at all. A later story that wants `$AIMI_CLI` itself pinned on the command side pays the mirror then, in one commit, the way the numeric filter and Layer 0-dev were each paid.

**Reporting the second root is the other half of the same fix, and it is a notice rather than a refusal.** When a cached path is accepted by the unanchored arm above but resolves under a root other than the one `_claude_config_dir()` names, `_validate_cached_cli_path` prints one stderr line naming **both** roots and still returns the path. Refusing would break hosts that are legitimately arranged that way — a `CLAUDE_CONFIG_DIR` moved after the cache was written is the ordinary case — and would surface the breakage far from its cause. It is not mirrored onto `_validate_cached_worktree_path`, because the worktree pointer is never resolved on its own: `_persist_worktree_pointer_for` derives it from the CLI install path, so a foreign worktree root is a consequence of a foreign cli-path root this line has already reported once.

## Layer 1: the cache, the SessionStart healing and the mirror cost

> **A directory-source install (marketplace source: `directory`) legitimately writes a path here too, not only a versioned cache copy.** Layer 1's cache file just holds whatever `prime-cache` last wrote — for a directory-source Claude Code host that is the checkout's own `scripts/aimi-cli.sh`, not a copy under `plugins/cache/`. No layer in this file produces it on its own: Layer 0 is gated off whenever `CLAUDECODE` is set (every Claude Code session), Layer 2's glob below only ever matches `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh` and a directory source has no copy there, and Layer 3's `.aimi/cli-path` is created by nobody. Layer 0-dev above is the one exception, and it is not one in practice: it is an override the operator sets by hand for one tree, never something a fresh host arrives at. So on a fresh directory-source host every layer legitimately fails and `$AIMI_CLI` resolves to empty — which means `/aimi:init` itself cannot self-heal, since its own Step 0 needs `$AIMI_CLI` resolved before it can call `prime-cache` at all.
>
> **The SessionStart hook now writes Layer 1 whenever it does not already resolve**, so a session started after the plugin is installed finds the cache primed and the four layers above succeed at Layer 1. `_heal_cli_path_cache()` in `hooks/inspect-session.py` — registered on `SessionStart` in `hooks/hooks.json`, and the only thing that module does — reads `$CLAUDE_PLUGIN_ROOT`, which Claude Code puts in the hook process's own environment and which is the one value that names the running install without guessing. Only when the Layer 1 read comes back empty or non-executable does it spawn that install's `scripts/aimi-cli.sh prime-cache`; it writes no cache file itself, because confinement, atomicity and the 0600 mode all belong to `prime-cache` and invoking the verb rather than re-deriving its rules is the whole point of the shape. The cheap Layer 1 read is the gate deliberately: a `prime-cache` spawn measured 299 ms while the read plus the executable check measured 0.025 ms, so a host that already resolves pays nothing. It never raises — a missing `CLAUDE_PLUGIN_ROOT`, a root with no executable `scripts/aimi-cli.sh`, an unreadable config dir, a non-zero exit and a timeout each leave the session exactly as it was found.
>
> **This is Claude Code only, and OpenCode needs it less.** `install.sh` registers no hooks at all — `grep -i hook install.sh` returns nothing — so an OpenCode session never runs the healing even though the hook files travel with the install. It does not have to: `CLAUDECODE` is unset there, which is precisely the condition Layer 0 waits for, and `install.sh` writes `AIMI_PLUGIN_DIR` into the shell profile, so resolution succeeds one layer earlier than the cache file this healing exists to write.
>
> **Recovery, for a host the hook has not reached** — a session already open when the plugin was installed, or one where hooks are disabled — is running the CLI once by its absolute path:
>
> ```bash
> bash /abs/path/to/plugins/aimi-engineering/scripts/aimi-cli.sh prime-cache
> ```
>

>
> That single invocation writes Layer 1 directly (bypassing the four-layer search entirely, since the CLI is being run by a path the operator already knows), and every later `/aimi:*` command in the session resolves normally from there. It is the same verb the hook spawns, run by hand — so it repairs the session in front of you, and a new session would have healed itself anyway.
>
> **A new Layer 2b was the route NOT taken, and the reason it was rejected still stands even though it is no longer the reason nothing is automated.** The resolution snippets in this file are matched *literally* by `hooks/auto-approve-cli.sh`'s Patterns 7 and 8, built from `GLOB_VERSION_TAIL` near the top of that file — so a new layer's command text would need a byte-identical mirror in this file, `hooks/auto-approve-cli.sh`, the `--help` EXAMPLES block in `aimi-cli.sh`, `skills/resolve-pr-parallel/scripts/_resolve-cli.sh`, `commands/review.md`, `commands/validate-bug.md`, and `scripts/test-aimi-cli-part1-core.sh`. One character of drift between any two of those turns every Layer 2 call into a permission prompt instead of an auto-approval. That cost is unchanged and is why the manual bootstrap stood alone for as long as it did; what changed is that the SessionStart healing above buys the automation without paying it, since it runs outside the resolution snippets entirely and touches none of those mirrors. Kept here so the mirror cost is not re-derived, and so the next proposal for a new layer is weighed against it.
>
> **Two names this list used to carry are gone from it, and both were measured rather than argued.** The top-level `CLAUDE.md` is **not** a carrier: it holds zero occurrences of the pipeline fragment (`sort -V | tail -1`), and its one hit for the cache glob is a prose line describing Layer 2, not a line anything executes — a document that *describes* the idiom costs a sentence to update and cannot drift into a permission prompt. And it is **one** test suite, not three: `scripts/test-aimi-cli-part1-core.sh` carries the pipeline as `_test_latest_installed_cli_path`, the twin the CLI's answer is compared against. Of the two other test files that come up in a careless grep, `scripts/tests/test_version_cache.py` mentions `sort -V` only in prose, and `hooks/tests/test_auto_approve_cli.py`'s two occurrences are the **pre-filter** spelling frozen inside `LEGACY_FORMS` on purpose — that file must NOT move with the idiom, because moving it would delete the coverage keeping an old conversation's command body auto-approved. Overstating the mirror cost is not the safe direction to be wrong in: this is the paragraph the next person reads to decide whether a layer is affordable.
>
> **The cost above is a measurement, not a warning, and it has since been paid twice in one commit** — once to add the numeric filter to `GLOB_VERSION_TAIL` and every block built from it, and once to add Layer 0-dev. Both moved all seven surfaces together, which is the only way this is survivable; the hook additionally keeps the pre-filter tail approved as a legacy form, so a command body that entered a conversation before the change is not suddenly prompted for. The lesson is unchanged: a layer is cheap to write and expensive to mirror, and the mirror is what the user actually feels.
>
> **Refuted alternative, recorded so it is not re-derived:** `CLAUDE_PLUGIN_ROOT` is NOT usable as a Layer 0b. It was measured unset in the Bash-tool environment — exactly where these resolution snippets execute — so a Layer 0b keyed on it would never fire for the host it would need to help.

## Layer 2: why the pipeline is shaped this way

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
