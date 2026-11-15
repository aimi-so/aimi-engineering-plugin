# Per-category efforts

Maintainer note for the effort setting: a reasoning effort stored beside each category's model and delivered at every spawn. Read it before changing `models.py`'s effort handling, the `--<category>-effort` flags, an `[effort: ...]` annotation, `tools/aimi-task.ts`'s `variant` argument, or `commands/setup-models.md` Step 3b/3c. The user-facing description is `docs/commands.md` § `/aimi:setup-models`.

## Where the value lives

`~/.config/aimi/models.json`, inside each host table, as `categories.<host>.efforts` (`claudeCode` and `opencode`), a map from category to value. `schemaVersion` stays `2.0`: a file written before the setting existed has no `efforts` key and reads as every category `inherit`. Only non-`inherit` values are stored, so unset and `inherit` are the same state.

- **Claude Code**: one of `low`, `medium`, `high`, `xhigh`, `max` (`EFFORT_LEVELS` in `scripts/models.py`, which also lists `inherit`).
- **OpenCode**: a variant name of the category's model. A variant needs a model, so a category whose model is `inherit` has effort `inherit` too.

`merge_models_document` carries `efforts` for both hosts on every write, for the reason it carries both hosts' models: a key the merge does not name is erased by the next `detect-models` run (the 1.97.2 shape).

## Readers and writer, by verb

- `resolve-efforts` (`cmd_resolve_efforts`): the active host's five efforts as one single-line JSON object, like `resolve-models`. Never fails. A stored value outside the host's valid set is treated as `inherit` with one stderr line.
- `effort-options` (`cmd_effort_options`): what the picker offers. Claude Code: the six levels, a constant, so no crossing into Python. OpenCode: `--model <id>` is required and the variants come from the `opencode models --verbose` catalog; when the catalog is unavailable it prints `null` with one stderr line.
- `detect-models` (the writer): `--research-effort`, `--review-effort`, `--design-effort`, `--workflow-effort` and `--executor-effort`, each optional. An absent flag keeps the stored value, `inherit` clears it, and an invalid level is refused. On OpenCode the CLI, not the command prose, drops a stored variant the new model does not define and names what it dropped.

The reader/writer asymmetry of `check_python3` is the same as for the model verbs; see the root `CLAUDE.md` § Testing.

## Delivery at a spawn

**Claude Code.** Every spawn site that carries `[model: <AGENT_MODELS.x when not "inherit">]` carries the same category's `[effort: <AGENT_EFFORTS.x when not "inherit">]` on the line after it (or the parameter-list `effort: ...,` pair). `commands/references/cli-path-resolution.md` § Applying the resolved model to a Task call is the rule's home and is not restated here. `scripts/tests/test_agent_effort_sites.py` pins the pairing: an annotation of one kind with no matching annotation of the other, in the same category and spelling, is a finding, and so is a line that populates or hands on `AGENT_MODELS` without naming `AGENT_EFFORTS`.

**OpenCode.** The effort is passed to `aimi-task` as its own `variant` argument and forwarded as `opencode run --variant <name>`. The model string and `SAFE_MODEL_PATTERN` do not change. `SAFE_VARIANT_PATTERN` in `tools/aimi-task.ts` (`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`) is the defense-in-depth check on the value, the same literal as the one in `models.py`; `test_aimi_task.py` runs the tool under `bun` and compares the two. The OpenCode preamble written by `install.sh` tells the agent to pass the variant.

## What overrides it

`CLAUDE_CODE_EFFORT_LEVEL`, set in the environment, is applied by Claude Code to every spawn and overrides every per-category effort. `/aimi:setup-models` prints a line when it is set. The per-spawn `effort` parameter needs Claude Code 2.1.292 or newer. A level the chosen model does not support falls back to the highest supported level at or below it; this is the host's behaviour and is not validated here.

## Headless effort check

The automated verify cannot see a real spawn, so this check runs one. It makes a real model call and spends tokens, so it is run by hand at the release gate and is not part of any test suite.

Run it from the repository root. It builds a scratch `AIMI_CONFIG_DIR` and `HOME`, so the real `~/.config/aimi/models.json` is never read or written: one category (`research`) is set to effort `high` and another (`workflow`) is left unset.

```bash
set -euo pipefail
SCRATCH=$(mktemp -d)
export AIMI_CONFIG_DIR="$SCRATCH/aimi"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # keeps the real login; resolved before HOME changes
export HOME="$SCRATCH"
mkdir -p "$AIMI_CONFIG_DIR"
CLI="$PWD/plugins/aimi-engineering/scripts/aimi-cli.sh"
printf '%s' "$CLI" > "$AIMI_CONFIG_DIR/cli-path"
CLAUDECODE=1 "$CLI" detect-models --research inherit --review inherit --design inherit \
  --workflow inherit --executor inherit --research-effort high
CLAUDECODE=1 "$CLI" resolve-efforts
claude -p --output-format stream-json --verbose --plugin-dir "$PWD/plugins/aimi-engineering" \
  "Read plugins/aimi-engineering/commands/references/cli-path-resolution.md, run its Resolve Agent Models block, then spawn exactly two agents following its Applying the resolved model to a Task call rule: subagent_type aimi-engineering:research:aimi-codebase-researcher and subagent_type aimi-engineering:workflow:aimi-spec-flow-analyzer, each with the prompt 'reply ok'. Do nothing else." \
  > "$SCRATCH/stream.jsonl"
echo "stream: $SCRATCH/stream.jsonl"
```

Save the next block as `assert.sh` and run it as `bash assert.sh STREAM CONFIGURED INHERIT`, here `bash assert.sh "$SCRATCH/stream.jsonl" research workflow`. It finds each `Agent` or `Task` `tool_use` by the `aimi-engineering:<category>:` prefix of its `subagent_type`, prints one `PASS` or `FAIL` line per category and exits 1 on any `FAIL`. The configured category passes when every one of its spawns has `"effort":"high"`; the inherit category passes when none of its spawns has an `effort` key; a category with no spawn fails. It reads only the stream, so it also runs on synthetic streams with no model call, which is how the release verify exercises it.

```bash
# assert-effort-stream
STREAM=${1:?stream file}
CONFIGURED=${2:?configured category}
INHERIT=${3:?inherit category}
rc=0

spawn_inputs() {
  jq -c --arg c "$1" '
    select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
    | .input
    | select((.subagent_type // "") | startswith("aimi-engineering:" + $c + ":"))
  ' "$STREAM"
}

check() {
  category=$1
  kind=$2
  inputs=$(spawn_inputs "$category")
  if [ -z "$inputs" ]; then
    echo "FAIL $category: no spawn found"
    rc=1
    return
  fi
  if [ "$kind" = configured ]; then
    bad=$(printf '%s\n' "$inputs" | jq -c 'select((.effort // "") != "high")')
    want='effort "high"'
  else
    bad=$(printf '%s\n' "$inputs" | jq -c 'select(has("effort"))')
    want='no effort key'
  fi
  if [ -n "$bad" ]; then
    echo "FAIL $category: expected $want, got $(printf '%s' "$bad" | head -n 1)"
    rc=1
  else
    echo "PASS $category: $want"
  fi
}

check "$CONFIGURED" configured
check "$INHERIT" inherit
exit "$rc"
```

Clean up with `rm -rf "$SCRATCH"` afterwards. A `FAIL` on the configured category means the spawn rule did not reach the Task call, or `CLAUDE_CODE_EFFORT_LEVEL` and a host older than 2.1.292 got in the way; a `FAIL` on the inherit category means an effort leaked onto a spawn that should carry none.
