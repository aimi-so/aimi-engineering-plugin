#!/usr/bin/env bash
# install.sh — Install aimi-engineering plugin for OpenCode
# Usage: ./install.sh [--project] [--uninstall] [--dry-run]
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="aimi-engineering"
DRY_RUN=0
PROJECT_MODE=0
UNINSTALL=0
VERBOSE=0
TARGET=""

log()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing (no getopt — portable)
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        shift; TARGET="$1" ;;
    --from)      shift; TARGET="$1"; UNINSTALL=1 ;;
    --project)   PROJECT_MODE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --verbose)   VERBOSE=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./install.sh --to opencode [OPTIONS]
       ./install.sh --uninstall --from opencode [OPTIONS]

Install aimi-engineering plugin for AI coding tools.

Options:
  --to TARGET   Install for target tool (required for install)
  --from TARGET Uninstall from target tool (implies --uninstall)
  --project     Install into project directory instead of global
  --uninstall   Remove installed files
  --dry-run     Show what would be done without doing it
  --verbose     Print detailed progress
  --help        Show this help

Supported targets: opencode

Examples:
  ./install.sh --to opencode              # Global install
  ./install.sh --to opencode --project    # Project install to .opencode/
  ./install.sh --uninstall --from opencode  # Remove install
  ./install.sh --to opencode --dry-run    # Preview changes
USAGE
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

# Validate target
if [ -z "$TARGET" ]; then
  die "Missing --to flag. Usage: ./install.sh --to opencode"
fi
case "$TARGET" in
  opencode) ;;
  *) die "Unsupported target: $TARGET. Supported: opencode" ;;
esac

# ---------------------------------------------------------------------------
# detect_plugin_source — find plugins/aimi-engineering/ relative to script
# ---------------------------------------------------------------------------
detect_plugin_source() {
  local src="$SCRIPT_DIR/plugins/$PLUGIN_NAME"
  if [ -d "$src" ] && [ -f "$src/.claude-plugin/plugin.json" ]; then
    printf '%s\n' "$src"
    return 0
  fi
  die "Plugin source not found at $src. Run this script from the repository root."
}

# ---------------------------------------------------------------------------
# resolve_target_dir — determine where to install
# ---------------------------------------------------------------------------
resolve_target_dir() {
  if [ "$PROJECT_MODE" -eq 1 ]; then
    printf '%s\n' "$(pwd)/.opencode"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  fi
}

# ---------------------------------------------------------------------------
# backup_file — timestamped backup before modifying
# ---------------------------------------------------------------------------
backup_file() {
  local path="$1"
  if [ -f "$path" ]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local bak="${path}.bak.${ts}"
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] Would backup $path -> $bak"
    else
      cp "$path" "$bak"
      # Use an explicit if (not `[ ... ] && log`): as the function's last
      # statement, a bare `&&` test returns 1 when VERBOSE=0, which aborts the
      # caller under `set -euo pipefail`. An if returns 0 when the test is false.
      if [ "$VERBOSE" -eq 1 ]; then log "Backed up $path -> $bak"; fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# parse_frontmatter — extract YAML frontmatter from .md file
# Returns via global vars: FM_KEYS[], FM_VALS[], FM_BODY
# Uses parallel arrays (bash 3 compat — no associative arrays)
# ---------------------------------------------------------------------------
FM_KEYS=()
FM_VALS=()
FM_BODY=""

parse_frontmatter() {
  local file="$1"
  FM_KEYS=()
  FM_VALS=()
  FM_BODY=""

  local in_fm=0
  local fm_started=0
  local body=""
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "---" ]; then
      if [ "$fm_started" -eq 0 ]; then
        fm_started=1
        in_fm=1
        continue
      else
        in_fm=0
        continue
      fi
    fi
    if [ "$in_fm" -eq 1 ]; then
      # Parse "key: value" or 'key: "value"'
      local key val
      key="${line%%:*}"
      val="${line#*: }"
      # Strip leading/trailing quotes
      val="${val#\"}"
      val="${val%\"}"
      FM_KEYS+=("$key")
      FM_VALS+=("$val")
    else
      body="${body}${line}
"
    fi
  done < "$file"

  FM_BODY="$body"
}

# ---------------------------------------------------------------------------
# fm_get — get frontmatter value by key
# ---------------------------------------------------------------------------
fm_get() {
  local target="$1"
  local i=0
  while [ "$i" -lt "${#FM_KEYS[@]}" ]; do
    if [ "${FM_KEYS[$i]}" = "$target" ]; then
      printf '%s' "${FM_VALS[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# translate_command_body — rewrite command body for OpenCode compatibility
# Prepends agent invocation preamble and fixes subagent_type references
# ---------------------------------------------------------------------------
translate_command_body() {
  local body="$1"

  # --- CLI path rewriting (applies to all commands) ---
  # Replace Claude config dir references with OpenCode config dir
  body="${body//\$\{CLAUDE_CONFIG_DIR:-\$HOME\/.claude\}/\$\{OPENCODE_CONFIG_DIR:-\$HOME\/.config\/opencode\}}"

  # Coverage re-verified (US-003): the single-line Per-Call Resolution form
  # documented in commands/references/cli-path-resolution.md — the same two
  # statements above, joined by `;` into one line — needs no new rule here.
  # This function was sourced in isolation, fed that literal joined line, and
  # returned it with only the CLAUDE_CONFIG_DIR token swapped and every other
  # byte (including the `;`) unchanged: the substring rewrite above is
  # already agnostic to where a statement boundary falls.

  # Replace plugin root variable with the OpenCode-side AIMI_PLUGIN_DIR
  # (CLAUDE_PLUGIN_ROOT is injected by Claude Code only; AIMI_PLUGIN_DIR is
  # exported by this installer for OpenCode.)
  body="${body//\$\{CLAUDE_PLUGIN_ROOT\}/\$\{AIMI_PLUGIN_DIR\}}"

  # --- Error message rewriting (applies to all commands) ---
  # Replace plugin install instructions with OpenCode installer
  body="${body//\/plugin install aimi-engineering/.\/install.sh --to opencode}"

  # --- AskUserQuestion rewriting (applies to all commands) ---
  # OpenCode ships a native `question` tool (https://opencode.ai/docs/tools/)
  # with header + lettered options + custom-text input. Map Claude Code's
  # AskUserQuestion to it so picker UX works on both hosts with one source body.
  # Permission is gated by "question" in opencode.json (default: "ask").
  # Order matters: match longer/more-specific patterns first.
  #
  # Coverage verified (US-003): these four rules cover every AskUserQuestion
  # call site in plan.md — including the Phase 3c iterative outline-gate
  # pickers (single-operation picker loop: approve|rename|add|remove|reorder)
  # introduced by the two-pass outline+expand pipeline. The outline-gate calls
  # use the "via AskUserQuestion" and plain "AskUserQuestion" patterns, both of
  # which are matched by the third and fourth substitution lines below.
  # The aimi-cli story-merge invocation (Phase 3e) uses the standard per-call
  # AIMI_CLI resolution and requires no additional translation — the CLI-path
  # rewrite above handles the path, and the subcommand name is preserved verbatim.
  #
  # Coverage re-verified (US-006): brainstorm.md's Phase 3.6 Prototype Offer
  # Gate picker ("Present via **AskUserQuestion** (picker mode)" / "Skip
  # AskUserQuestion entirely") is fully covered by the existing four rules
  # below — no new rule was needed. Any future picker phrased the same way is
  # covered automatically by the bare-token catch-all (last rule below).
  #
  # Coverage re-verified (US-005): execute.md's Creates Verification call
  # `$AIMI_CLI verify-creates --feature … --phase … --dir …` needs no new rule —
  # this function was sourced in isolation, fed that literal invocation, and
  # returned it byte-identical. None of the substitutions above or below can
  # match a subcommand name, so verify-creates survives translation verbatim
  # exactly as story-merge does; only the CLI-path rewrite applies.
  #
  # Coverage re-verified (bug/container-base-branch-resolution US-005):
  # execute.md's Step 0 `--base` extraction (a plain `case " $ARGUMENTS " in`
  # scan + `sed`/`grep` pair, mirroring the pre-existing `--phase`/`--container`/
  # `--inline` extractions) and every `resolve-base-branch`/
  # `setup-branch --base "$BASE_BRANCH"` call site it threads into need no new
  # rule — none of the substitutions above rewrite flag parsing or CLI
  # subcommand/flag names, so `--base` and its call sites survive translation
  # byte-identical, same as `--phase` already does.
  #
  # Coverage re-verified (forge-abstraction phase 1, US-012): none of the
  # `detect-forge`/`forge-*` verb call sites migrated into open-pr.md,
  # review.md, validate-bug.md, execute.md's phase-mode PR-creation loop, and
  # the resolve-pr-parallel skill scripts need a new rule either — this
  # function was sourced in isolation, fed a literal `$AIMI_CLI forge-pr-create
  # --title … --base … --head … --body …` invocation, and returned it
  # byte-identical, the same technique used for verify-creates and story-merge.
  # Note the trade-off this migration carries: since every `gh` call these
  # verbs make now runs inside `aimi-cli.sh` instead of directly in a command
  # body, it is covered by the blanket `aimi_cli` allow rule below instead of
  # prompting per call — a real broadening of unattended write consent,
  # accepted deliberately (see CHANGELOG.md and docs/opencode.md) rather than
  # narrowed with a `gh *` rule or a confirmation gate, because either would
  # break unattended `/aimi:execute`.
  # Coverage re-verified (forge-abstraction phase 2, forge account picker): the
  # per-repository forge-account pickers added to open-pr.md (Step 1a) and
  # execute.md (Offer a Pull Request) need no new rule — this function was
  # sourced in isolation, fed both picker paragraphs literally, and returned
  # `Use the **question** tool` from the first substitution below with no
  # AskUserQuestion literal left in either. Their `$AIMI_CLI
  # forge-account-select --check/--record/--record-active --project …` calls
  # survive byte-identical for the same reason verify-creates and story-merge
  # do: no substitution here matches a subcommand or flag name.
  #
  # This is also why those pickers live in the command bodies and NOT in
  # commands/references/forge-contract.md. Reference files never reach this
  # function: they are delivered by the verbatim whole-tree copy below and both
  # command-install loops skip the "references" subdirectory by name. A picker
  # written into a reference file would reach OpenCode untranslated, naming a
  # tool that host does not have. forge-contract.md therefore carries the
  # account-selection contract in prose with no AskUserQuestion literal at all.
  body="${body//Use \*\*AskUserQuestion\*\*/Use the **question** tool}"
  body="${body//Use AskUserQuestion/Use the question tool}"
  body="${body//via AskUserQuestion/via the question tool}"
  body="${body//AskUserQuestion/the question tool}"

  # --- REQUIRED_SKILLS / SKILLS_BASE_DIR: no rewrite needed ---
  # SKILLS_BASE_DIR resolution in execute.md already branches on CLAUDECODE vs AIMI_PLUGIN_DIR,
  # and AIMI_PLUGIN_DIR is set by this installer for OpenCode. The <required_skills> section
  # is injected verbatim into Task prompts — no OpenCode-specific translation required.

  # --- Task → aimi-task rewriting (namespaced agent calls only) ---
  # OpenCode's native `task` tool rejects plugin-namespaced subagent_type
  # strings like "aimi-engineering:research:aimi-codebase-researcher". The
  # `aimi-task` tool (plugins/aimi-engineering/tools/aimi-task.ts) strips the
  # prefix and shells out to `opencode run --agent <bare-name>`. Physically
  # rewriting the body removes the LLM's burden of doing this rewrite on every
  # invocation — previously the preamble told the model to translate Task →
  # aimi-task at call time, and the model sometimes forgot.
  body="${body//Task subagent_type=\"aimi-engineering:/aimi-task subagent_type=\"aimi-engineering:}"

  # --- Agent invocation preamble (only for commands referencing named agents) ---
  case "$body" in
    *'subagent_type="aimi-engineering:'*)
      # Replace general-purpose with general
      body="${body//general-purpose/general}"

      # Prepend the OpenCode agent invocation preamble
      local preamble
      preamble='## OpenCode Agent Invocation

### Step 0 — Resolve Agent Models

Before spawning any agent, run once:

```bash
AIMI_CLI="${AIMI_CLI:-${AIMI_PLUGIN_DIR}/scripts/aimi-cli.sh}"
RESOLVED_MODELS=$($AIMI_CLI resolve-models 2>/dev/null)
```

Extract per-category model values (all five keys are always present; value is a model id or the sentinel "inherit"):

```
RESEARCH_MODEL=$(printf '\''%s'\'' "$RESOLVED_MODELS" | jq -r '\''.research'\'')
REVIEW_MODEL=$(printf '\''%s'\'' "$RESOLVED_MODELS" | jq -r '\''.review'\'')
DESIGN_MODEL=$(printf '\''%s'\'' "$RESOLVED_MODELS" | jq -r '\''.design'\'')
WORKFLOW_MODEL=$(printf '\''%s'\'' "$RESOLVED_MODELS" | jq -r '\''.workflow'\'')
EXECUTOR_MODEL=$(printf '\''%s'\'' "$RESOLVED_MODELS" | jq -r '\''.executor'\'')
```

If `$AIMI_CLI` is not available or the call fails, set all five variables to the string `inherit`.

#### First-run configuration prompt (interactive hosts only)

After `AGENT_MODELS` is resolved, check once whether the one-time model-selection prompt should be shown:

```bash
_AIMI_INTERACTIVITY=$($AIMI_CLI detect-interactivity 2>/dev/null)
_AIMI_PROMPT_CHECK=$($AIMI_CLI models-prompt-check 2>/dev/null)
```

Only when `_AIMI_INTERACTIVITY` is `picker` AND `_AIMI_PROMPT_CHECK` is `prompt`, ask the user via the question tool:

> "Nenhuma configuração de modelo de subagente encontrada — os agentes herdam o modelo da thread principal. Quer configurar a seleção de modelo por categoria?"
> Options: A — "Configurar agora" ; B — "Manter o padrão (inherit)"

**Option A — "Configurar agora":**

The model SELECTION must happen at the LLM-orchestrator layer using the question tool, NOT inside a bash subprocess. The bash layer only lists available models and writes the config from explicit choices.

1. Run `$AIMI_CLI list-models` to get the host'\''s available models as a JSON array.
2. Use the question tool with **five questions in one call** — one per category — letting the user pick a model for each. Each question'\''s options are the models returned by `list-models`:
   - "Modelo para tarefas de pesquisa/leitura (research)?" — suggested default: an Anthropic Haiku model id from `opencode models`
   - "Modelo para revisão e análise (review)?" — suggested default: an Anthropic Opus model id
   - "Modelo para tarefas de design (design)?" — suggested default: an Anthropic Sonnet model id
   - "Modelo para tarefas de workflow (workflow)?" — suggested default: an Anthropic Sonnet model id
   - "Modelo para sub-orquestradores de execução (executor)?" — suggested default: an Anthropic Sonnet model id
3. Run `$AIMI_CLI detect-models --research <chosen_research> --review <chosen_review> --design <chosen_design> --workflow <chosen_workflow> --executor <chosen_executor>` with the user'\''s picks to write the config.
4. Re-run `$AIMI_CLI resolve-models` to refresh the model variables.

**Option B — "Manter o padrão (inherit)":** no action needed beyond dismissal.

- Regardless of choice: always run `$AIMI_CLI models-prompt-dismiss` so the prompt is never shown again.

When `_AIMI_INTERACTIVITY` is not `picker` (agent-mode / CI) OR `_AIMI_PROMPT_CHECK` is `skip`, do nothing — proceed silently.

### Step 1 — Per-spawn model selection

The command body below uses `aimi-task subagent_type="aimi-engineering:CATEGORY:NAME"` invocations directly (rewritten at install time from the upstream `Task subagent_type=...` form). For each invocation, look up the model by CATEGORY and pass it as the `model` argument:

- research → `$RESEARCH_MODEL`
- review → `$REVIEW_MODEL`
- design → `$DESIGN_MODEL`
- workflow → `$WORKFLOW_MODEL`
- executor → `$EXECUTOR_MODEL`

**Omit the `model` argument entirely when the resolved value is `inherit`** — do not pass `model="inherit"` literally, the spawned agent must inherit the session model.

For `Task(subagent_type="general", model: ...)` spawns (the parallel sub-orchestrators and per-story executor of /aimi:execute), route through **aimi-task** using `$EXECUTOR_MODEL` as the model, since the native `task` tool ignores per-call `model:` arguments:

```
aimi-task(
  subagent_type="general",
  model="[$EXECUTOR_MODEL, omit if inherit]",
  prompt="[original task prompt]"
)
```

`Task(subagent_type="general", ...)` spawns **without** a `model:` annotation are left unchanged — do NOT route them through aimi-task.

**HARD RULE — never call OpenCode'\''s native `task` tool with any `subagent_type` starting with `aimi-engineering:`.** OpenCode does not recognize plugin-namespaced agent names; only the `aimi-task` tool strips the prefix and routes correctly. If the command body ever shows `Task subagent_type="aimi-engineering:..."` (rare — should have been rewritten at install time), treat it as `aimi-task subagent_type="aimi-engineering:..."` instead.

Run all aimi-task invocations in parallel as instructed by the command below.

---

'
      body="${preamble}${body}"
      ;;
  esac

  printf '%s' "$body"
}

# ---------------------------------------------------------------------------
# translate_command — convert Claude command .md to OpenCode command .md
# ---------------------------------------------------------------------------
translate_command() {
  local src_file="$1"
  local dst_file="$2"

  parse_frontmatter "$src_file"

  local desc
  desc=$(fm_get "description") || desc=""

  # Append argument-hint to description if present
  local arg_hint
  arg_hint=$(fm_get "argument-hint") || arg_hint=""
  if [ -n "$arg_hint" ]; then
    desc="$desc $arg_hint"
  fi

  # Check for disable-model-invocation
  local disable_invoke
  disable_invoke=$(fm_get "disable-model-invocation") || disable_invoke=""

  local translated_body
  translated_body=$(translate_command_body "$FM_BODY")

  # Prepend side-effect warning if disable-model-invocation: true
  if [ "$disable_invoke" = "true" ]; then
    local warning
    warning='## WARNING: This command has side effects. Only invoke when explicitly requested by the user.

'
    translated_body="${warning}${translated_body}"
  fi

  {
    printf '%s\n' "---"
    printf 'description: %s\n' "$desc"
    printf '%s\n' "---"
    printf '%s' "$translated_body"
  } > "$dst_file"
}

# ---------------------------------------------------------------------------
# translate_agent — convert Claude agent .md to OpenCode agent .md
# ---------------------------------------------------------------------------
translate_agent() {
  local src_file="$1"
  local dst_file="$2"

  parse_frontmatter "$src_file"

  local desc
  desc=$(fm_get "description") || desc=""

  local model
  model=$(fm_get "model") || model=""

  {
    printf '%s\n' "---"
    printf '%s\n' "mode: subagent"
    printf 'description: %s\n' "$desc"
    if [ -n "$model" ] && [ "$model" != "inherit" ]; then
      printf 'model: %s\n' "$model"
    fi
    printf '%s\n' "---"
    printf '%s' "$FM_BODY"
  } > "$dst_file"
}

# ---------------------------------------------------------------------------
# install_plugin_source — copy full plugin to plugins/aimi-engineering/
# ---------------------------------------------------------------------------
install_plugin_source() {
  local src="$1"
  local target_dir="$2"
  local plugin_dst="$target_dir/plugins/$PLUGIN_NAME"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would copy plugin source to $plugin_dst"
    return 0
  fi

  mkdir -p "$plugin_dst"
  # Copy everything except .git
  # This is a whole-tree copy, not a per-file allowlist: commands/references/*.md
  # (cli-path-resolution.md, scope-contexts.md, ui-signals.md, visual-variants.md, ...)
  # is carried verbatim by this cp -R with no code change needed when new reference
  # files are added — install_commands' subdirectory loops deliberately skip
  # "references" (see below) because this copy already delivers them (verified US-006).
  cp -R "$src/." "$plugin_dst/"

  # Ensure scripts are executable
  find "$plugin_dst" -name '*.sh' -exec chmod +x {} +

  # Write version marker
  local version
  version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.claude-plugin/plugin.json" | head -1)
  printf '%s\n' "$version" > "$plugin_dst/.installed-version"

  ok "Plugin source installed to $plugin_dst (v$version)"
}

# ---------------------------------------------------------------------------
# install_commands — translate and write commands
# ---------------------------------------------------------------------------
install_commands() {
  local src="$1"
  local target_dir="$2"
  local cmd_dir="$target_dir/commands/aimi"
  local count=0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would install commands to $cmd_dir"
    # Top-level commands
    for src_file in "$src/commands/"*.md; do
      [ -f "$src_file" ] || continue
      local basename
      basename=$(basename "$src_file")
      local cmd_name
      cmd_name=$(sed -n 's/^name:[[:space:]]*aimi:\(.*\)/\1/p' "$src_file" | head -1)
      if [ -z "$cmd_name" ]; then
        cmd_name="${basename%.md}"
      fi
      # Flatten colons to hyphens for OpenCode flat command layout
      local dst_name
      dst_name="${cmd_name//:/-}.md"
      log "[dry-run]   Would translate command: aimi/$dst_name"
    done
    # Subdirectory commands (e.g., commands/design/*.md), skip references/
    for src_subdir in "$src/commands/"/*/; do
      [ -d "$src_subdir" ] || continue
      local subdir_name
      subdir_name=$(basename "$src_subdir")
      [ "$subdir_name" = "references" ] && continue
      for src_file in "$src_subdir"*.md; do
        [ -f "$src_file" ] || continue
        local basename
        basename=$(basename "$src_file")
        local cmd_name
        cmd_name=$(sed -n 's/^name:[[:space:]]*aimi:\(.*\)/\1/p' "$src_file" | head -1)
        if [ -z "$cmd_name" ]; then
          cmd_name="${subdir_name}-${basename%.md}"
        else
          # Flatten colons to hyphens (e.g., "design:shape" -> "design-shape")
          cmd_name="${cmd_name//:/-}"
        fi
        local dst_name="${cmd_name}.md"
        log "[dry-run]   Would translate command: aimi/$dst_name"
      done
    done
    return 0
  fi

  mkdir -p "$cmd_dir"

  # Install top-level commands
  for src_file in "$src/commands/"*.md; do
    [ -f "$src_file" ] || continue
    local basename
    basename=$(basename "$src_file")

    # Derive command name from frontmatter "name:" field (e.g., "aimi:plan" -> "plan")
    local cmd_name
    cmd_name=$(sed -n 's/^name:[[:space:]]*aimi:\(.*\)/\1/p' "$src_file" | head -1)
    # Fallback to filename without extension if frontmatter parsing fails
    if [ -z "$cmd_name" ]; then
      cmd_name="${basename%.md}"
    fi

    # Flatten colons to hyphens for OpenCode flat command layout
    local dst_name
    dst_name="${cmd_name//:/-}.md"

    translate_command "$src_file" "$cmd_dir/$dst_name"
    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Command: aimi/$dst_name"
  done

  # Install subdirectory commands (e.g., commands/design/*.md), skip references/
  for src_subdir in "$src/commands/"/*/; do
    [ -d "$src_subdir" ] || continue
    local subdir_name
    subdir_name=$(basename "$src_subdir")
    [ "$subdir_name" = "references" ] && continue
    for src_file in "$src_subdir"*.md; do
      [ -f "$src_file" ] || continue
      local basename
      basename=$(basename "$src_file")

      # Derive command name from frontmatter "name:" field
      local cmd_name
      cmd_name=$(sed -n 's/^name:[[:space:]]*aimi:\(.*\)/\1/p' "$src_file" | head -1)
      if [ -z "$cmd_name" ]; then
        cmd_name="${subdir_name}-${basename%.md}"
      else
        # Flatten colons to hyphens (e.g., "design:shape" -> "design-shape")
        cmd_name="${cmd_name//:/-}"
      fi

      local dst_name="${cmd_name}.md"

      translate_command "$src_file" "$cmd_dir/$dst_name"
      count=$((count + 1))
      [ "$VERBOSE" -eq 1 ] && log "  Command: aimi/$dst_name"
    done
  done

  ok "Installed $count commands to $cmd_dir"
}

# ---------------------------------------------------------------------------
# install_agents — translate and write agents
# ---------------------------------------------------------------------------
# OpenCode workflow subagent_type translation table (kept here for grep-discoverability
# even though the actual translation is glob-based via "agents/*/*.md"). Each workflow
# agent listed here is translated from `aimi-engineering:workflow:<name>` (Claude Code)
# to `aimi-<name>` (OpenCode) by the loop below.
#
# | workflow agent                       | translated as                          |
# | ------------------------------------ | -------------------------------------- |
# | aimi-bug-reproduction-validator      | aimi-bug-reproduction-validator        |
# | aimi-cross-story-auditor             | aimi-cross-story-auditor               |
# | aimi-learnings-triage                | aimi-learnings-triage                  |
# | aimi-scope-negative-verifier         | aimi-scope-negative-verifier           |
# | aimi-scope-positive-verifier         | aimi-scope-positive-verifier           |
# | aimi-spec-flow-analyzer              | aimi-spec-flow-analyzer                |
# | aimi-spec-flow-symbol-extractor      | aimi-spec-flow-symbol-extractor        |
# | aimi-story-expander                  | aimi-story-expander                    |
# ---------------------------------------------------------------------------
install_agents() {
  local src="$1"
  local target_dir="$2"
  local agent_dir="$target_dir/agents"
  local count=0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would install agents to $agent_dir"
    for src_file in "$src/agents/"*/*.md; do
      [ -f "$src_file" ] || continue
      local basename
      basename=$(basename "$src_file")
      local dst_name="$basename"
      case "$dst_name" in
        aimi-*) ;;
        *) dst_name="aimi-$dst_name" ;;
      esac
      log "[dry-run]   Would translate agent: $dst_name"
    done
    return 0
  fi

  mkdir -p "$agent_dir"

  # Find all agent .md files (they're in subdirs: design/, review/, etc.)
  for src_file in "$src/agents/"*/*.md; do
    [ -f "$src_file" ] || continue
    local basename
    basename=$(basename "$src_file")

    # Prefix with aimi- if not already
    local dst_name="$basename"
    case "$dst_name" in
      aimi-*) ;; # already prefixed
      *) dst_name="aimi-$dst_name" ;;
    esac

    translate_agent "$src_file" "$agent_dir/$dst_name"
    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Agent: $dst_name"
  done

  ok "Installed $count agents to $agent_dir"
}

# ---------------------------------------------------------------------------
# install_skills — copy skills to OpenCode's skill discovery directory
# ---------------------------------------------------------------------------
install_skills() {
  local src="$1"
  local target_dir="$2"
  local skill_dir="$target_dir/skills"
  local count=0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would install skills to $skill_dir"
    for src_skill in "$src/skills/"*/SKILL.md; do
      [ -f "$src_skill" ] || continue
      local skillname
      skillname=$(basename "$(dirname "$src_skill")")
      log "[dry-run]   Would install skill: aimi-$skillname"
      local skill_parent
      skill_parent=$(dirname "$src_skill")
      [ -d "$skill_parent/references" ] && log "[dry-run]     + references/"
      [ -d "$skill_parent/scripts" ]    && log "[dry-run]     + scripts/"
      [ -d "$skill_parent/templates" ]  && log "[dry-run]     + templates/"
      [ -f "$skill_parent/NOTICE.md" ]  && log "[dry-run]     + NOTICE.md"
    done
    return 0
  fi

  mkdir -p "$skill_dir"

  for src_skill in "$src/skills/"*/SKILL.md; do
    [ -f "$src_skill" ] || continue
    local skillname
    skillname=$(basename "$(dirname "$src_skill")")
    local dst="$skill_dir/aimi-$skillname"

    mkdir -p "$dst"
    cp "$src_skill" "$dst/SKILL.md"

    local skill_parent
    skill_parent=$(dirname "$src_skill")

    # Copy references/ if present
    if [ -d "$skill_parent/references" ]; then
      cp -R "$skill_parent/references" "$dst/"
      [ "$VERBOSE" -eq 1 ] && log "    + references/"
    fi

    # Copy scripts/ if present, mark .sh files executable
    if [ -d "$skill_parent/scripts" ]; then
      cp -R "$skill_parent/scripts" "$dst/"
      find "$dst/scripts" -name '*.sh' -exec chmod +x {} +
      [ "$VERBOSE" -eq 1 ] && log "    + scripts/ (executables marked)"
    fi

    # Copy templates/ if present
    if [ -d "$skill_parent/templates" ]; then
      cp -R "$skill_parent/templates" "$dst/"
      [ "$VERBOSE" -eq 1 ] && log "    + templates/"
    fi

    # Copy skill-root NOTICE.md if present (attribution/license notice)
    if [ -f "$skill_parent/NOTICE.md" ]; then
      cp "$skill_parent/NOTICE.md" "$dst/NOTICE.md"
      [ "$VERBOSE" -eq 1 ] && log "    + NOTICE.md"
    fi

    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Skill: aimi-$skillname"
  done

  ok "Installed $count skills to $skill_dir"
}

# ---------------------------------------------------------------------------
# install_custom_tools — copy plugin tools/ to the OpenCode tools directory
# ---------------------------------------------------------------------------
install_custom_tools() {
  local src="$1"
  local target_dir="$2"
  local tools_src="$src/tools"
  local tools_dst="$target_dir/tools"

  # Explicit allowlist — only these two files are managed by this plugin.
  # A glob over tools_src/* would risk copying unrelated files and could
  # silently destroy a pre-existing package.json owned by the user.
  local TOOL_ALLOWLIST="aimi-task.ts package.json"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would install custom tools to $tools_dst"
    if [ -d "$tools_src" ]; then
      for basename in $TOOL_ALLOWLIST; do
        [ -f "$tools_src/$basename" ] || continue
        if [ "$basename" = "package.json" ] && [ -f "$tools_dst/package.json" ]; then
          if ! cmp -s "$tools_src/package.json" "$tools_dst/package.json" 2>/dev/null; then
            log "[dry-run]   Would WARN: $tools_dst/package.json exists and differs — would skip (not plugin-owned)"
          else
            log "[dry-run]   Would install tool: $basename (identical, safe to overwrite)"
          fi
        else
          log "[dry-run]   Would install tool: $basename"
        fi
      done
    fi
    return 0
  fi

  if [ ! -d "$tools_src" ]; then
    [ "$VERBOSE" -eq 1 ] && log "No tools/ directory found in plugin source, skipping"
    return 0
  fi

  mkdir -p "$tools_dst"

  local count=0
  for basename in $TOOL_ALLOWLIST; do
    local f="$tools_src/$basename"
    [ -f "$f" ] || continue

    # Guard package.json: only write when destination is absent or identical to ours.
    if [ "$basename" = "package.json" ] && [ -f "$tools_dst/package.json" ]; then
      if cmp -s "$f" "$tools_dst/package.json" 2>/dev/null; then
        # Identical — safe no-op (already installed)
        [ "$VERBOSE" -eq 1 ] && log "  Tool: $basename (already up to date)"
        count=$((count + 1))
        continue
      else
        warn "Skipping $tools_dst/package.json — file exists and was not installed by this plugin. Add aimi-task dependencies manually or back it up and re-run."
        continue
      fi
    fi

    cp "$f" "$tools_dst/$basename"
    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Tool: $basename"
  done

  ok "Installed $count custom tools to $tools_dst"
}

# ---------------------------------------------------------------------------
# install_mcp — add context7 to opencode.json
# ---------------------------------------------------------------------------
install_mcp() {
  local target_dir="$1"
  local config_file="$target_dir/opencode.json"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would add context7 MCP to $config_file"
    return 0
  fi

  mkdir -p "$target_dir"

  # Check if context7 already configured
  if [ -f "$config_file" ] && grep -q '"context7"' "$config_file" 2>/dev/null; then
    [ "$VERBOSE" -eq 1 ] && log "MCP context7 already in $config_file, skipping"
    return 0
  fi

  if [ -f "$config_file" ]; then
    backup_file "$config_file"
    # Try jq first
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      jq '.mcp = (.mcp // {}) + {"context7": {"type": "remote", "url": "https://mcp.context7.com/mcp"}}' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    # Try python3 fallback
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json, sys
with open('$config_file') as f:
    try: cfg = json.load(f)
    except: cfg = {}
cfg.setdefault('mcp', {})['context7'] = {'type': 'remote', 'url': 'https://mcp.context7.com/mcp'}
with open('$config_file', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
    else
      warn "Neither jq nor python3 found. Add context7 MCP manually to $config_file"
      return 0
    fi
  else
    # Create new opencode.json
    cat > "$config_file" <<'JSON'
{
  "mcp": {
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp"
    }
  }
}
JSON
  fi

  ok "Added context7 MCP to $config_file"
}

# ---------------------------------------------------------------------------
# install_permissions — add Bash auto-approval rules to opencode.json
# ---------------------------------------------------------------------------
install_permissions() {
  local target_dir="$1"
  local plugin_dir="$target_dir/plugins/$PLUGIN_NAME"
  local config_file="$target_dir/opencode.json"

  local aimi_cli="$plugin_dir/scripts/aimi-cli.sh *"
  local worktree_mgr="$plugin_dir/skills/git-worktree/scripts/worktree-manager.sh *"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would add permissions to $config_file:"
    log "[dry-run]   bash: git * -> allow"
    log "[dry-run]   bash: $aimi_cli -> allow"
    log "[dry-run]   bash: $worktree_mgr -> allow"
    log "[dry-run]   bash: jq * -> allow"
    log "[dry-run]   bash: ls * -> allow"
    log "[dry-run]   bash: test * -> allow"
    log "[dry-run]   bash: id * -> allow"
    return 0
  fi

  mkdir -p "$target_dir"

  # Build the permissions JSON fragment
  local perms_json
  perms_json=$(cat <<PERMS
{
  "permission": {
    "bash": {
      "git *": "allow",
      "$aimi_cli": "allow",
      "$worktree_mgr": "allow",
      "jq *": "allow",
      "ls *": "allow",
      "test *": "allow",
      "id *": "allow"
    }
  }
}
PERMS
)

  if [ -f "$config_file" ]; then
    # Check if permissions.bash already has our rules
    if grep -q '"git \*"' "$config_file" 2>/dev/null; then
      [ "$VERBOSE" -eq 1 ] && log "Permissions already in $config_file, skipping"
      return 0
    fi

    backup_file "$config_file"

    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      jq --argjson perms "$perms_json" '.permission = ((.permission // {}) * $perms.permission)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json, sys

perms = json.loads('''$perms_json''')

with open('$config_file') as f:
    try: cfg = json.load(f)
    except: cfg = {}

existing = cfg.get('permission', {})
for section, rules in perms['permission'].items():
    existing.setdefault(section, {}).update(rules)
cfg['permission'] = existing

with open('$config_file', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
    else
      warn "Neither jq nor python3 found. Add permissions manually to $config_file"
      return 0
    fi
  else
    # Create new opencode.json with permissions
    mkdir -p "$target_dir"
    printf '%s\n' "$perms_json" > "$config_file"
  fi

  ok "Added Bash auto-approval permissions to $config_file"
}

# ---------------------------------------------------------------------------
# set_env_var — add AIMI_PLUGIN_DIR export to shell profiles
# ---------------------------------------------------------------------------
set_env_var() {
  local plugin_dir="$1"
  local marker="# aimi-engineering"
  local export_line="export AIMI_PLUGIN_DIR=\"$plugin_dir\" $marker"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would add to shell profiles: $export_line"
    return 0
  fi

  local updated=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ]; then
      if grep -q "$marker" "$rc" 2>/dev/null; then
        # Update existing line
        local tmp
        tmp=$(mktemp)
        grep -v "$marker" "$rc" > "$tmp"
        printf '%s\n' "$export_line" >> "$tmp"
        mv "$tmp" "$rc"
        [ "$VERBOSE" -eq 1 ] && log "Updated AIMI_PLUGIN_DIR in $rc"
        updated=1
      else
        printf '\n%s\n' "$export_line" >> "$rc"
        [ "$VERBOSE" -eq 1 ] && log "Added AIMI_PLUGIN_DIR to $rc"
        updated=1
      fi
    fi
  done

  # If no rc files exist, create .bashrc
  if [ "$updated" -eq 0 ]; then
    printf '%s\n' "$export_line" >> "$HOME/.bashrc"
    log "Created $HOME/.bashrc with AIMI_PLUGIN_DIR"
  fi

  ok "AIMI_PLUGIN_DIR=$plugin_dir added to shell profile"
}

# ---------------------------------------------------------------------------
# install_opencode — orchestrator
# ---------------------------------------------------------------------------
install_opencode() {
  local src
  src=$(detect_plugin_source)
  local target_dir
  target_dir=$(resolve_target_dir)

  log "Installing $PLUGIN_NAME for OpenCode..."
  if [ "$PROJECT_MODE" -eq 1 ]; then
    log "Mode: project (.opencode/)"
  else
    log "Mode: global ($target_dir)"
  fi

  install_plugin_source "$src" "$target_dir"
  install_commands "$src" "$target_dir"
  install_agents "$src" "$target_dir"
  install_skills "$src" "$target_dir"
  install_custom_tools "$src" "$target_dir"
  install_mcp "$target_dir"
  install_permissions "$target_dir"

  local plugin_dir="$target_dir/plugins/$PLUGIN_NAME"
  set_env_var "$plugin_dir"

  # Prime CLI path cache so the first /aimi:* command skips Layer 2 glob cost
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would prime cache: $plugin_dir/scripts/aimi-cli.sh"
  else
    chmod +x "$target_dir/plugins/$PLUGIN_NAME/scripts/aimi-cli.sh"
    local prime_out
    # State the host intent explicitly rather than relying on whatever
    # CLAUDECODE happens to be in this process: set_env_var only appends
    # AIMI_PLUGIN_DIR to a shell profile, it does not export into this
    # running shell, and running this installer from inside a Claude Code
    # session inherits CLAUDECODE=1 here. Without the override, cmd_prime_cache
    # falls to host_label="claude_code" and primes the shared cli-path cache
    # with the Claude Code checkout instead of this OpenCode install.
    prime_out=$(env -u CLAUDECODE AIMI_PLUGIN_DIR="$plugin_dir" \
      "$target_dir/plugins/$PLUGIN_NAME/scripts/aimi-cli.sh" prime-cache 2>&1) || {
      warn "Cache priming failed (non-fatal): $prime_out"
      prime_out=""
    }
    if [ -n "$prime_out" ]; then
      # Check for JSON status=error
      case "$prime_out" in
        *'"status":"error"'*|*'"status": "error"'*)
          warn "Cache priming reported error (non-fatal): $prime_out"
          ;;
        *)
          log "Primed CLI path cache"
          ;;
      esac
    else
      log "Primed CLI path cache"
    fi
  fi

  echo
  ok "Installation complete!"
  echo
  log "Plugin source: $plugin_dir"
  log "Commands:      $target_dir/commands/aimi/*.md"
  log "Agents:        $target_dir/agents/aimi-*.md"
  log "Skills:        $target_dir/skills/aimi-*/"
  log "Tools:         $target_dir/tools/aimi-task.ts"
  log "MCP:           $target_dir/opencode.json"
  echo
  log "Restart your shell or run:"
  log "  export AIMI_PLUGIN_DIR=\"$plugin_dir\""
}

# ---------------------------------------------------------------------------
# uninstall_opencode — remove installed files
# ---------------------------------------------------------------------------
uninstall_opencode() {
  local target_dir
  target_dir=$(resolve_target_dir)

  log "Uninstalling $PLUGIN_NAME from OpenCode..."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would remove $target_dir/commands/aimi/"
    log "[dry-run] Would remove $target_dir/commands/aimi-*.md (legacy flat files)"
    log "[dry-run] Would remove $target_dir/agents/aimi-*.md"
    log "[dry-run] Would remove $target_dir/skills/aimi-*/"
    log "[dry-run] Would remove $target_dir/plugins/$PLUGIN_NAME/"
    log "[dry-run] Would remove $target_dir/tools/aimi-task.ts"
    log "[dry-run] Would remove $target_dir/tools/package.json (only if plugin-owned; skipped otherwise with warning)"
    log "[dry-run] Would remove context7 from $target_dir/opencode.json"
    log "[dry-run] Would remove permissions from $target_dir/opencode.json"
    log "[dry-run] Would remove AIMI_PLUGIN_DIR from shell profiles"
    log "[dry-run] NOTE: models.json user config is preserved (not removed)"
    local new_cache_file="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path"
    local legacy_cache_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"
    [ -f "$new_cache_file" ]    && log "[dry-run] Would remove $new_cache_file"
    [ -f "$legacy_cache_file" ] && log "[dry-run] Would remove $legacy_cache_file"
    return 0
  fi

  # Remove commands
  local count=0
  if [ -d "$target_dir/commands/aimi" ]; then
    for f in "$target_dir/commands/aimi/"*.md; do
      [ -f "$f" ] || continue
      rm "$f"
      count=$((count + 1))
    done
    rmdir "$target_dir/commands/aimi" 2>/dev/null
  fi
  [ "$count" -gt 0 ] && ok "Removed $count commands (nested)"

  # Remove legacy flat command files (backwards compat with older installs)
  count=0
  for f in "$target_dir/commands/"aimi-*.md; do
    [ -f "$f" ] || continue
    rm "$f"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && ok "Removed $count legacy command files"

  # Remove agents
  count=0
  for f in "$target_dir/agents/"aimi-*.md; do
    [ -f "$f" ] || continue
    rm "$f"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && ok "Removed $count agents"

  # Remove skills
  count=0
  for d in "$target_dir/skills/"aimi-*/; do
    [ -d "$d" ] || continue
    rm -rf "$d"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && ok "Removed $count skills"

  # Remove plugin source
  if [ -d "$target_dir/plugins/$PLUGIN_NAME" ]; then
    rm -rf "$target_dir/plugins/$PLUGIN_NAME"
    ok "Removed plugin source"
  fi

  # Remove shipped aimi-task tool artifacts from the OpenCode tools directory.
  # Only the files we installed (aimi-task.ts and package.json) are removed.
  # package.json is only removed when it matches the plugin-owned copy; if the
  # user has modified it (or it belongs to another tool) we warn and leave it.
  # The user config file models.json under the aimi config directory is NOT touched.
  local plugin_src
  plugin_src=$(detect_plugin_source) 2>/dev/null || plugin_src=""
  local tools_dir="$target_dir/tools"
  local removed_tools=0
  if [ -f "$tools_dir/aimi-task.ts" ]; then
    rm -f "$tools_dir/aimi-task.ts"
    removed_tools=$((removed_tools + 1))
    [ "$VERBOSE" -eq 1 ] && log "Removed $tools_dir/aimi-task.ts"
  fi
  if [ -f "$tools_dir/package.json" ]; then
    local src_pkg=""
    [ -n "$plugin_src" ] && src_pkg="$plugin_src/tools/package.json"
    if [ -n "$src_pkg" ] && [ -f "$src_pkg" ] && cmp -s "$src_pkg" "$tools_dir/package.json" 2>/dev/null; then
      rm -f "$tools_dir/package.json"
      removed_tools=$((removed_tools + 1))
      [ "$VERBOSE" -eq 1 ] && log "Removed $tools_dir/package.json"
    else
      warn "Skipping $tools_dir/package.json — not identical to plugin-owned copy; remove manually if no longer needed."
    fi
  fi
  [ "$removed_tools" -gt 0 ] && ok "Removed aimi-task tool artifacts from $tools_dir"

  # Remove MCP from opencode.json
  local config_file="$target_dir/opencode.json"
  if [ -f "$config_file" ] && grep -q '"context7"' "$config_file" 2>/dev/null; then
    backup_file "$config_file"
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      jq 'del(.mcp.context7)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
      ok "Removed context7 MCP from $config_file"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json
with open('$config_file') as f:
    cfg = json.load(f)
cfg.get('mcp', {}).pop('context7', None)
with open('$config_file', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
      ok "Removed context7 MCP from $config_file"
    else
      warn "Remove context7 from $config_file manually (no jq or python3)"
    fi
  fi

  # Remove permissions from opencode.json
  if [ -f "$config_file" ] && grep -q '"permission"' "$config_file" 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
      local tmp
      tmp=$(mktemp)
      jq 'del(.permission)' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
      ok "Removed permissions from $config_file"
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json
with open('$config_file') as f:
    cfg = json.load(f)
cfg.pop('permission', None)
with open('$config_file', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
      ok "Removed permissions from $config_file"
    else
      warn "Remove permissions from $config_file manually (no jq or python3)"
    fi
  fi

  # Remove AIMI_PLUGIN_DIR from shell profiles
  local marker="# aimi-engineering"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && grep -q "$marker" "$rc" 2>/dev/null; then
      local tmp
      tmp=$(mktemp)
      grep -v "$marker" "$rc" > "$tmp"
      mv "$tmp" "$rc"
      [ "$VERBOSE" -eq 1 ] && log "Removed AIMI_PLUGIN_DIR from $rc"
    fi
  done
  ok "Removed AIMI_PLUGIN_DIR from shell profiles"

  # Remove global CLI path cache (best-effort; remove both new XDG and legacy paths)
  local new_cache_file="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path"
  local legacy_cache_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"
  if [ -f "$new_cache_file" ]; then
    rm -f "$new_cache_file"
    log "Removed CLI path cache $new_cache_file"
  fi
  if [ -f "$legacy_cache_file" ]; then
    rm -f "$legacy_cache_file"
    log "Removed legacy CLI path cache $legacy_cache_file"
  fi

  echo
  ok "Uninstall complete!"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_opencode
else
  install_opencode
fi
