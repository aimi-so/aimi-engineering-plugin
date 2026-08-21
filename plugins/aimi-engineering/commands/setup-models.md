---
name: aimi:setup-models
description: Configure per-category model assignments interactively for Claude Code, OpenCode, or Codex while preserving every other host's settings.
argument-hint: ""
allowed-tools:
  - Bash(cat:*)
  - Bash(jq:*)
  - Bash(ls:*)
  - Bash(mkdir:*)
  - Bash(AIMI_CLI=*)
  - Bash($AIMI_CLI:*)
  - AskUserQuestion
---

# Aimi Setup Models

Interactive (re)configuration of per-category model assignments for `~/.config/aimi/models.json` (schema v2.0). Writes only the active host's sub-table; every other host's settings are preserved on merge.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report the error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 1: Determine Active Host and Fetch Inputs

Identify the host and gather the two JSON inputs needed for the picker.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "${AIMI_HOST:-}" = "codex" ]; then
  HOST_LABEL="Codex"
elif [ -n "${CLAUDECODE:-}" ]; then
  HOST_LABEL="Claude Code"
else
  HOST_LABEL="OpenCode"
fi
AVAILABLE_MODELS_JSON=$(AIMI_HOST="${AIMI_HOST:-}" $AIMI_CLI list-models 2>/dev/null)
CURRENT_MODELS_JSON=$(AIMI_HOST="${AIMI_HOST:-}" $AIMI_CLI get-current-models 2>/dev/null)
```

`AVAILABLE_MODELS_JSON` is a JSON array of model id strings. `CURRENT_MODELS_JSON` is a JSON object with five keys (research, review, design, workflow, executor) — each value is either a configured model id string or JSON null when unset.

If either call fails or returns empty, report the error and STOP — the picker cannot run without both inputs.

## Step 2: Display Current Assignments

Render a short summary to chat so the user can see what is configured before answering. For each of the five categories, parse the value from `CURRENT_MODELS_JSON` and display:

- When the value is a non-null string: display the literal model id.
- When the value is JSON null: display the literal text `not configured`.

Output exactly:

```
Current models for [HOST_LABEL] (~/.config/aimi/models.json):
  research:  <id or "not configured">
  review:    <id or "not configured">
  design:    <id or "not configured">
  workflow:  <id or "not configured">
  executor:  <id or "not configured">
```

## Step 3: Five-Question Picker

Use **AskUserQuestion** with **five questions in one call** — one per category. Each question's options are sourced from `AVAILABLE_MODELS_JSON`. The label on each option is the bare model id; the picker automatically appends an "Other" option for free-form input.

**Default selection per question** — pre-select the recommended option as follows:

| Category | Default when current value is a configured id | Default when current value is JSON null |
|----------|------------------------------------------------|-----------------------------------------|
| research | the current value (option that matches it)    | Claude Code: `haiku` · OpenCode: Anthropic Haiku · Codex: `gpt-5.6-luna` |
| review   | the current value                              | Claude Code: `opus` · OpenCode: Anthropic Opus · Codex: `gpt-5.6-sol` |
| design   | the current value                              | Claude Code: `sonnet` · OpenCode: Anthropic Sonnet · Codex: `gpt-5.6-terra` |
| workflow | the current value                              | Claude Code: `sonnet` · OpenCode: Anthropic Sonnet · Codex: `gpt-5.6-terra` |
| executor | the current value                              | Claude Code: `sonnet` · OpenCode: Anthropic Sonnet · Codex: `gpt-5.6-terra` |

Place the recommended/default option **first** in the option list for each question and append `(current)` or `(suggested default)` to its label — `(current)` when it matches the value parsed from `CURRENT_MODELS_JSON`, `(suggested default)` when the current value was JSON null.

Question text (one per category, exactly as shown):

- "Model for research/reading tasks (research)?"
- "Model for review and analysis (review)?"
- "Model for design tasks (design)?"
- "Model for workflow tasks (workflow)?"
- "Model for execution sub-orchestrators (executor)?"

Cap each question at four options (the top-4 most likely picks). The picker's auto-appended "Other" lets the user type any model id from `AVAILABLE_MODELS_JSON` that did not make the top-4 — accept any string the user provides without further validation (the CLI's `detect-models` will validate against the available-model list before writing).

Collect the user's five answers as `CHOSEN_RESEARCH`, `CHOSEN_REVIEW`, `CHOSEN_DESIGN`, `CHOSEN_WORKFLOW`, `CHOSEN_EXECUTOR`.

## Step 4: Write Configuration

Invoke `aimi-cli detect-models` with the five chosen values. `detect-models` validates each model id against the host's available-model list before writing, preserves every other host's `categories.<host>` sub-table, and emits the resulting config JSON on stdout.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_HOST="${AIMI_HOST:-}" $AIMI_CLI detect-models \
  --research  "[CHOSEN_RESEARCH]" \
  --review    "[CHOSEN_REVIEW]" \
  --design    "[CHOSEN_DESIGN]" \
  --workflow  "[CHOSEN_WORKFLOW]" \
  --executor  "[CHOSEN_EXECUTOR]"
```

If `detect-models` exits non-zero, report the error verbatim and STOP — the config file was not written. Otherwise capture the stdout JSON.

## Step 5: Confirm and Report

Display a confirmation summarising what was written:

```
Models configured for [HOST_LABEL]:
  research:  [CHOSEN_RESEARCH]
  review:    [CHOSEN_REVIEW]
  design:    [CHOSEN_DESIGN]
  workflow:  [CHOSEN_WORKFLOW]
  executor:  [CHOSEN_EXECUTOR]

Config: ~/.config/aimi/models.json (schema v2.0)
```

If another host's sub-table existed before this run, also note:

```
The other hosts' category assignments were preserved.
```

## Error Handling

| Failure | Action |
|---------|--------|
| `$AIMI_CLI` resolution fails | Report error from Step 0 and STOP |
| `list-models` returns empty | Report "list-models returned no available models — cannot run picker" and STOP |
| `get-current-models` returns empty | Report "get-current-models failed — cannot determine current values" and STOP (the bug fix in US-001 guarantees the command always returns valid JSON; an empty result indicates a deeper CLI failure) |
| Picker cancelled mid-flow | Stop without writing. No partial config is written — `detect-models` only fires after all five answers are collected |
| `detect-models` exits non-zero | Report the stderr verbatim and STOP — the config file was not modified |

## Notes

- This command is intentionally interactive-only. There is no `--non-interactive` flag; users wanting scripted writes can invoke `aimi-cli detect-models --research X --review Y --design Z --workflow W --executor V` directly.
- Re-running this command is idempotent in practice: selecting the current default for every question results in the same config content being re-written.
- The marker file `~/.config/aimi/models-prompt-seen` is **not** touched by this command. The first-run-prompt dismissal flag is independent of explicit re-configuration via `/aimi:setup-models`.
