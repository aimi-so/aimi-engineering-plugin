# Interactivity Modes

Commands that ask the user questions (`brainstorm`, `plan`, etc.) run
in one of two modes, resolved once per invocation and stored as
`INTERACTIVE_MODE`.

## Mode Resolution

Call `$AIMI_CLI detect-interactivity` once at the top of the command. It prints
exactly one of: `picker`, `agent`.

Precedence (first match wins):

1. `AIMI_AGENT_MODE=true` → `agent` (explicit opt-out always wins)
2. `CI=true` → `agent`
3. `CLAUDECODE=1` → `picker` (Claude Code provides `AskUserQuestion`)
4. `OPENCODE_CONFIG_DIR` is set → `picker` (OpenCode provides the `question` tool)
5. stdin is a TTY → `picker`
6. Otherwise → `agent`

Steps 3 and 4 deliberately ignore TTY state. Both hosts run command bash bodies
in a subshell without a controlling terminal, but a host-level picker is fully
available — relying on `[ -t 0 ]` alone would misclassify every Claude Code and
OpenCode invocation as non-interactive.

Do not re-implement this logic inline. Use the CLI so the rule stays in one
place and is covered by `test-aimi-cli.sh`.

## Picker Mode

Interactive user, either host. One question per tool call.

**Claude Code:** use the `AskUserQuestion` tool.
**OpenCode:** use the native `question` tool
([opencode.ai/docs/tools](https://opencode.ai/docs/tools/)) — header + question
text + list of options, single-select with free-form custom answer. It is
permission-gated by `"question"` in `opencode.json` and defaults to `"ask"`.

Command source always writes `AskUserQuestion` — `install.sh` rewrites to
`question tool` for the OpenCode install, so one source body produces a picker
on both hosts.

### Option Format

- Lettered labels: `A — <short name>`, `B — <short name>`, …
- The last option is always an escape hatch:
  - `Other` (free-form) for open questions
  - `None — show again / revise` for variant selection sites
- Never fewer than 2 options. Never more than 6 (pickers get unwieldy).

### Response Handling

Accept the selected option directly. Do not ask the user to type
`"1A, 2C, 3B"` shorthand — that format is not supported in picker mode on
either host. If a question needs multiple answers, emit multiple picker calls.

## Agent Mode

Non-interactive context (`AIMI_AGENT_MODE=true`, `CI=true`, or no TTY). Never
block, never prompt. At every question site:

1. Auto-select the first non-escape option (option A).
2. Log exactly one line into the command's output artifact (brainstorm
   document, plan scratch, etc.) in the form:
   ```
   agent-mode: <site-id> auto-<action>
   ```
   Example: `agent-mode: Q2 auto-selected option A`, `agent-mode: phase-4
   open-questions deferred`.
3. Move on. Never retry.

If the first option is an escape hatch for a given site, pick option B
instead. (Escape hatches are `Other` and `None — show again / revise`.)

## Adding a New Question Site

1. Write the picker call using `Use **AskUserQuestion**` (exact string —
   `install.sh` matches on it). Provide lettered options + escape hatch.
2. Decide the default auto-pick for agent mode. Pick the least disruptive
   option (proceed, accept recommendation, defer) and document it inline.
3. Add a one-sentence agent-mode fallback immediately below the picker call:
   > *Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-[action]. Log:
   > `agent-mode: [site] auto-[action]`.*
