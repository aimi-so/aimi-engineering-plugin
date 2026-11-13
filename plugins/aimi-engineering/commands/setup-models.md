---
name: aimi:setup-models
description: Configure per-category model assignments interactively. Shows current values for the active host (claudeCode or opencode), then runs a five-question picker (research, review, design, workflow, executor) with current values pre-selected as defaults, then behind one gate question an effort picker (reasoning effort on Claude Code, model variant on OpenCode) per category. Writes ~/.config/aimi/models.json (schema v2.0) via aimi-cli detect-models, preserving the other host's sub-table. Use when you want to change model assignments after first-run, or when ~/.config/aimi/models.json was deleted and you want to re-configure.
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

Interactive (re)configuration of per-category model assignments and efforts for `~/.config/aimi/models.json` (schema v2.0). Writes only the active host's sub-table; the other host's settings are preserved on merge.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`: its Fast path block is one Bash call, and the layers after it run one at a time only when it prints `AIMI_CLI_UNRESOLVED`.

If resolution fails, report the error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 1: Determine Active Host and Fetch Inputs

Identify the host and gather the two JSON inputs needed for the picker.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "${CLAUDECODE}" ]; then
  HOST_LABEL="Claude Code"
else
  HOST_LABEL="OpenCode"
fi
AVAILABLE_MODELS_JSON=$($AIMI_CLI list-models 2>/dev/null)
CURRENT_MODELS_JSON=$($AIMI_CLI get-current-models 2>/dev/null)
CURRENT_EFFORTS_JSON=$($AIMI_CLI resolve-efforts 2>/dev/null)
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity 2>/dev/null)
if [ -n "${CLAUDE_CODE_EFFORT_LEVEL}" ]; then
  echo "CLAUDE_CODE_EFFORT_LEVEL is set (${CLAUDE_CODE_EFFORT_LEVEL}): it overrides every per-category effort on Claude Code."
fi
```

`AVAILABLE_MODELS_JSON` is a JSON array of model id strings. `CURRENT_MODELS_JSON` is a JSON object with five keys (research, review, design, workflow, executor) — each value is either a configured model id string or JSON null when unset.

If either of the first two calls fails or returns empty, report the error and STOP — the picker cannot run without both inputs. `CURRENT_EFFORTS_JSON` is a JSON object with the same five keys, each the stored effort or `inherit`. An empty `resolve-efforts` answer means skip Steps 3b and 3c with one line saying the efforts could not be read. When the block printed the `CLAUDE_CODE_EFFORT_LEVEL` line, keep it for Step 2.

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

Then show the current efforts from `CURRENT_EFFORTS_JSON`, one `<category>: <effort>` line each (`inherit` shown as is). When Step 1 printed the `CLAUDE_CODE_EFFORT_LEVEL` line, repeat it once here.

## Step 3: Five-Question Picker

Use **AskUserQuestion** with **five questions in one call** — one per category. Each question's options are sourced from `AVAILABLE_MODELS_JSON`. The label on each option is the bare model id; the picker automatically appends an "Other" option for free-form input.

**Default selection per question** — pre-select the recommended option as follows:

| Category | Default when current value is a configured id | Default when current value is JSON null |
|----------|------------------------------------------------|-----------------------------------------|
| research | the current value (option that matches it)    | Claude Code: `haiku` · OpenCode: an Anthropic Haiku model id from `AVAILABLE_MODELS_JSON` |
| review   | the current value                              | Claude Code: `opus` · OpenCode: an Anthropic Opus model id |
| design   | the current value                              | Claude Code: `sonnet` · OpenCode: an Anthropic Sonnet model id |
| workflow | the current value                              | Claude Code: `sonnet` · OpenCode: an Anthropic Sonnet model id |
| executor | the current value                              | Claude Code: `sonnet` · OpenCode: an Anthropic Sonnet model id |

Place the recommended/default option **first** in the option list for each question and append `(current)` or `(suggested default)` to its label — `(current)` when it matches the value parsed from `CURRENT_MODELS_JSON`, `(suggested default)` when the current value was JSON null.

Question text (one per category, exactly as shown):

- "Model for research/reading tasks (research)?"
- "Model for review and analysis (review)?"
- "Model for design tasks (design)?"
- "Model for workflow tasks (workflow)?"
- "Model for execution sub-orchestrators (executor)?"

Cap each question at four options (the top-4 most likely picks). The picker's auto-appended "Other" lets the user type any model id from `AVAILABLE_MODELS_JSON` that did not make the top-4 — accept any string the user provides without further validation (the CLI's `detect-models` will validate against the available-model list before writing).

Collect the user's five answers as `CHOSEN_RESEARCH`, `CHOSEN_REVIEW`, `CHOSEN_DESIGN`, `CHOSEN_WORKFLOW`, `CHOSEN_EXECUTOR`.

## Step 3b: Effort Gate

Skip with the empty-answer rule of Step 1. Otherwise Use **AskUserQuestion** with one question, "Adjust effort as well?", and two options in this order:

- `A — No, keep current efforts`
- `B — Yes, adjust efforts`

Only B opens Step 3c. Every other answer, Other included, means no: send no effort flag in Step 4.

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select option A. Log: `agent-mode: effort-gate auto-selected option A`.*

## Step 3c: Effort Questions

Only after a B answer. Print once: `Cost note: max multiplies cost for review and research, which spawn many agents per run.`

Ask one question per category, worded exactly:

- "Effort for research/reading tasks (research)?"
- "Effort for review and analysis (review)?"
- "Effort for design tasks (design)?"
- "Effort for workflow tasks (workflow)?"
- "Effort for execution sub-orchestrators (executor)?"

Use **AskUserQuestion** in two calls, because one call holds at most four questions: research, review and design first; workflow and executor in a second call. Put the current effort (from `CURRENT_EFFORTS_JSON`) first, labelled `(current)`, at most four options per question.

Fetch the levels with this block, replacing each `[CHOSEN_<CATEGORY>]` with the model chosen in Step 3 (an id containing a single quote counts as unsafe: send `inherit`). It prints `levels=<answer>` on Claude Code and `<category>=<answer>` for each fetched model on OpenCode.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "${CLAUDECODE}" ]; then
  echo "levels=$($AIMI_CLI effort-options)"
else
  for pair in research:'[CHOSEN_RESEARCH]' review:'[CHOSEN_REVIEW]' design:'[CHOSEN_DESIGN]' workflow:'[CHOSEN_WORKFLOW]' executor:'[CHOSEN_EXECUTOR]'; do
    name=${pair%%:*}
    model=${pair#*:}
    case "$model" in ""|inherit) continue ;; [A-Za-z0-9]*) ;; *) continue ;; esac
    case "$model" in *[!A-Za-z0-9._/-]*) continue ;; esac
    echo "$name=$($AIMI_CLI effort-options --model "$model")"
  done
fi
```

**Claude Code.** The levels come from one `effort-options` call (no `--model`). Options are `inherit`, `low`, `medium`, `high`, the current one first; a current `xhigh` or `max` takes the first slot and drops `low`. `xhigh` and `max` are typed through Other. A category whose model is `inherit` is still asked.

**OpenCode.** Run the block only after a B answer: each `effort-options --model <chosen model>` call runs the verbose catalog. A model of `inherit` gets no question and its effort stays `inherit`.

- A variant array offers `inherit (no variant)` plus the first three variants in catalog order (the current one first, labelled `(current)`; the rest through Other).
- `[]` gets no question and one line saying the model defines no variants.
- A catalog that is unavailable (`null`, an empty answer or an unsafe id): if the chosen model equals the current one and a variant is stored, offer `keep current (<variant>)` and `inherit (no variant)`; else skip the question with one line saying the variants could not be read. `keep current` sends no flag. A variant named `none` is an ordinary variant: only `inherit (no variant)` means no variant.

**Matching.** Trim each answer at both ends and compare it case-sensitively with the offered set (Claude Code: the six values `effort-options` printed; OpenCode: `inherit` plus that model's variants; `keep current` and `inherit (no variant)` map to no flag and `inherit`). An answer outside the set is asked again once; a second miss leaves the category unanswered. An unmatched answer is never placed in a command.

Collect the matched values as `EFFORT_RESEARCH`, `EFFORT_REVIEW`, `EFFORT_DESIGN`, `EFFORT_WORKFLOW`, `EFFORT_EXECUTOR`; a category not asked or unanswered is the empty string.

## Step 4: Write Configuration

Invoke `aimi-cli detect-models` with the five chosen values and the matched efforts. The `[EFFORT_<CATEGORY>]` placeholders sit inside single quotes: substitute the matched value or the empty string. The `case` gate admits the empty string and `inherit`, on Claude Code only `low`, `medium`, `high`, `xhigh` and `max`, on OpenCode only names matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; any other value, an unsubstituted placeholder included, exits 1 before `detect-models` runs. `detect-models` validates each model id against the host's available-model list before writing, preserves the other host's `categories.<host>` sub-table, and emits the resulting config JSON on stdout.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
EFFORT_RESEARCH='[EFFORT_RESEARCH]'
EFFORT_REVIEW='[EFFORT_REVIEW]'
EFFORT_DESIGN='[EFFORT_DESIGN]'
EFFORT_WORKFLOW='[EFFORT_WORKFLOW]'
EFFORT_EXECUTOR='[EFFORT_EXECUTOR]'
effort_ok() {
  case "$1" in ""|inherit) return 0 ;; esac
  if [ -n "${CLAUDECODE}" ]; then
    case "$1" in low|medium|high|xhigh|max) return 0 ;; esac
    return 1
  fi
  case "$1" in [A-Za-z0-9]*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}
for value in "$EFFORT_RESEARCH" "$EFFORT_REVIEW" "$EFFORT_DESIGN" "$EFFORT_WORKFLOW" "$EFFORT_EXECUTOR"; do
  effort_ok "$value" || { echo "Error: invalid effort value, nothing written" >&2; exit 1; }
done
set -- --research "[CHOSEN_RESEARCH]" --review "[CHOSEN_REVIEW]" --design "[CHOSEN_DESIGN]" --workflow "[CHOSEN_WORKFLOW]" --executor "[CHOSEN_EXECUTOR]"
if [ -n "$EFFORT_RESEARCH" ]; then set -- "$@" --research-effort "$EFFORT_RESEARCH"; fi
if [ -n "$EFFORT_REVIEW" ]; then set -- "$@" --review-effort "$EFFORT_REVIEW"; fi
if [ -n "$EFFORT_DESIGN" ]; then set -- "$@" --design-effort "$EFFORT_DESIGN"; fi
if [ -n "$EFFORT_WORKFLOW" ]; then set -- "$@" --workflow-effort "$EFFORT_WORKFLOW"; fi
if [ -n "$EFFORT_EXECUTOR" ]; then set -- "$@" --executor-effort "$EFFORT_EXECUTOR"; fi
$AIMI_CLI detect-models "$@"
```

If `detect-models` exits non-zero, report the error verbatim and STOP — the config file was not written. Otherwise capture the stdout JSON and keep every line it printed on stderr: each is a notice (a variant dropped or coerced).

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

Read the efforts back, and show them as stored (not as asked), so a variant the CLI dropped or coerced shows as `inherit`:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI resolve-efforts
```

Then repeat each notice line `detect-models` printed, once, and the `CLAUDE_CODE_EFFORT_LEVEL` line when Step 1 printed it.

If the other host's sub-table existed before this run, also note:

```
The other host's category assignments were preserved.
```

## Error Handling

| Failure | Action |
|---------|--------|
| `$AIMI_CLI` resolution fails | Report error from Step 0 and STOP |
| `list-models` returns empty | Report "list-models returned no available models — cannot run picker" and STOP |
| `get-current-models` returns empty | Report "get-current-models failed — cannot determine current values" and STOP (the bug fix in US-001 guarantees the command always returns valid JSON; an empty result indicates a deeper CLI failure) |
| Picker cancelled mid-flow | Stop without writing. No partial config is written — `detect-models` only fires after all five answers are collected |
| `resolve-efforts` returns empty | Skip Steps 3b and 3c with one line; write models only |
| Effort answer outside the offered set | Ask again once; a second miss leaves the category unanswered |
| `detect-models` exits non-zero | Report the stderr verbatim and STOP — the config file was not modified |

## Notes

- This command is intentionally interactive-only. There is no `--non-interactive` flag; users wanting scripted writes can invoke `aimi-cli detect-models --research X --review Y --design Z --workflow W --executor V` directly.
- Efforts are optional: `--<category>-effort` is sent only for an answered category (absent keeps the stored value, `inherit` clears it). The command applies none of the CLI's stale-variant rules itself; it repeats the CLI's notices.
- Re-running this command is idempotent in practice: selecting the current default for every question results in the same config content being re-written.
- The marker file `~/.config/aimi/models-prompt-seen` is **not** touched by this command. The first-run-prompt dismissal flag is independent of explicit re-configuration via `/aimi:setup-models`.
