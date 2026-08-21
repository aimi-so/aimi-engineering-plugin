---
name: aimi-validate-bug
description: Validate and reproduce a bug report using the aimi-bug-reproduction-validator
  agent. Returns a structured report covering Reproduction Status, Steps Taken, Findings,
  Root Cause, Severity, and Recommended Next Steps. Use when you have a bug report
  (issue number, GitHub URL, or free-text description) that needs systematic reproduction
  and classification.
---

# Codex compatibility contract

This file is generated from `commands/validate-bug.md`. Do not edit it directly.

- `AIMI_REQUEST` means the user's text following the explicit `$aimi-validate-bug` invocation. Treat it as data, not a shell environment variable.
- Resolve `PLUGIN_ROOT` as the absolute Aimi plugin root containing this skill. For shell calls, resolve `AIMI_CLI` from `${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path`; if absent, run `$aimi-init` first. Prefix every Aimi CLI call with `AIMI_HOST=codex`.
- A named `$role-skill` means spawn a Codex subagent and explicitly require that internal skill. Preserve requested concurrency and pass only the source workflow's prompt payload.
- Use Codex structured user input when the workflow says `request_user_input`. In non-interactive mode, retain the source workflow's automatic choice.
- Follow Codex approval and sandbox policy. Never infer permission to publish, push, delete, or bypass a guard.
- The source workflow below is authoritative after applying these host mappings.

## Source workflow


# Aimi Validate Bug

Systematically reproduce and validate a bug report using the aimi-bug-reproduction-validator agent.

## Step 1: Resolve $AIMI_CLI and Run Version Check

Resolve the CLI path using the four-layer strategy. Each check is a separate Bash call (no compound operators).

**Layer 0: AIMI_PLUGIN_DIR (env var override)**

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

**Layer 1: Global cache (fast path)**

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); fi
```

**Layer 1 validation: verify cached path exists and is executable**

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2: Glob fallback (zsh-safe)**

Picks the newest **version**, which is not the last line `ls` prints — `ls`
collates `1.121.3` before `1.9.0`. Sorting whole paths is wrong too, because
the glob spans two wildcards and would order by marketplace entry first, so
each candidate carries its own version segment and `sort -V` keys on that.
Canonical rule: `_resolve_latest_cache_path` in `aimi-cli.sh`, inlined here
because it lives inside the file this block is still looking for.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | sort -V | tail -1 | cut -d" " -f2-'); fi
```

**Layer 2 cache update: save for next time**

```bash
if [ -n "$AIMI_CLI" ]; then _aimi_cfg="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"; mkdir -p "$_aimi_cfg" && printf '%s\n' "$AIMI_CLI" > "$_aimi_cfg/cli-path.tmp" && mv "$_aimi_cfg/cli-path.tmp" "$_aimi_cfg/cli-path" && chmod 600 "$_aimi_cfg/cli-path"; fi
```

**Layer 3: Per-project fallback (last resort)**

```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If `$AIMI_CLI` is still empty after all layers, report the error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "aimi-cli.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

**Run version check:**

```bash
$AIMI_CLI check-version --quiet --fix
```

## Step 2: Detect Input Type and Fetch Bug Context

<bug_input> #AIMI_REQUEST </bug_input>

Classify `AIMI_REQUEST` and gather context. `forge-issue-view` and `forge-pr-view` both run in the quiet degrade mode (`commands/references/forge-contract.md`'s Degradation Contract) — a missing or unauthenticated `gh` yields `status: "error"` with no stderr output — and both report the three-way `found`/`not_found`/`error` status (forge-contract.md's Three-Way Status Convention). Branch on that field directly; never on a bare non-zero exit code or by grepping stderr text:

1. **Numeric issue number** (e.g. `42`, `#42`): Strip any leading `#` and fetch with:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   ISSUE_JSON=$($AIMI_CLI forge-issue-view --number <number>)
   ```
   - `status == "found"`: use `.data.title`, `.data.body`, and `.data.labels` as the bug context.
   - `status == "not_found"`: report the error; ask the user to verify the issue number or URL (see Error Handling below).
   - `status == "error"`: prompt the user to run `gh auth login` or describe the bug in free text (see Error Handling below).

2. **GitHub URL** (contains `github.com`): Extract the issue or PR number from the URL path, then fetch with:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   ISSUE_JSON=$($AIMI_CLI forge-issue-view --number <number>)
   # OR for a PR URL:
   PR_JSON=$($AIMI_CLI forge-pr-view --pr <number>)
   ```
   Branch on `status` exactly as item 1 above. On `found`, read `.data.title`/`.data.body`/`.data.labels` (issue) or `.pr.title`/`.pr.body` (PR — `forge-pr-view`'s own envelope shape; see forge-contract.md). `forge-pr-view` has no `labels` field in its `--include` selector today — PR labels are outside the normalized PR field set `forge-pr-view` ships with in this phase — so a PR-URL input carries no label context into `BUG_CONTEXT` until a later story adds one; this is a known gap versus the `gh pr view --json labels` this branch fetched before this migration, not a silent drop.

3. **Free-text bug description** (anything else): Use `AIMI_REQUEST` directly as the bug context — no `gh` call needed.

Collect the bug context into a single `BUG_CONTEXT` string for use in Step 3.

## Step 2.5: Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

## Step 3: Spawn the Bug Reproduction Validator Agent

Spawn a single Codex subagent with the bug context gathered in Step 2:

```
Codex subagent_type="$aimi-bug-reproduction-validator"
  [model: <AGENT_MODELS.workflow when not "inherit">]
  prompt: "Validate and reproduce the following bug report.

Bug Context:
[BUG_CONTEXT from Step 2 — include issue URL or free-text description, labels, and any stack traces or error messages]

Please produce a structured report with these sections:
- Reproduction Status (Confirmed Bug / Cannot Reproduce / Not a Bug / Environmental Issue / Data Issue / User Error)
- Steps Taken
- Findings
- Root Cause (if identified)
- Evidence (relevant code, logs, or test output)
- Severity Assessment (Critical / High / Medium / Low)
- Recommended Next Steps"
```

Wait for the agent to complete before proceeding to Step 4.

## Step 4: Render Report and Next Steps

Display the agent's full structured report verbatim, then append this block:

```
---

### Next Steps

1. **If Confirmed Bug** — open or update a GitHub issue, then run `$aimi-plan` to create a fix plan
2. **If Cannot Reproduce** — add reproduction environment details to the issue and request more context
3. **If Not a Bug** — document the expected behavior and close the issue with an explanation
4. **Run `$aimi-review`** — review any fix branches before merging
5. **Run `$aimi-status`** — check current task progress across all stories
```

## Error Handling

| Failure | Action |
|---------|--------|
| No input provided | Ask the user for an issue number, GitHub URL, or bug description |
| `gh` not installed or not authenticated | Prompt user to run `gh auth login` or describe the bug in free text |
| Issue not found | Report the error; ask the user to verify the issue number or URL |
| `$AIMI_CLI` not resolved | Stop and report the resolution failure (see Step 1 error messages) |
| Validator agent fails | Surface the partial output; note which sections are missing |
