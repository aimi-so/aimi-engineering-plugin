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
      [ "$VERBOSE" -eq 1 ] && log "Backed up $path -> $bak"
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

  # If the body does not reference named agents, return unchanged
  case "$body" in
    *'subagent_type="aimi-engineering:'*) ;;
    *) printf '%s' "$body"; return 0 ;;
  esac

  # Replace general-purpose with general
  body="${body//general-purpose/general}"

  # Prepend the OpenCode agent invocation preamble
  local preamble
  preamble='## OpenCode Agent Invocation

When this command references agents via `Task subagent_type="aimi-engineering:CATEGORY:NAME"`, follow this pattern instead:

1. Extract CATEGORY and NAME from the reference (e.g., `aimi-engineering:review:aimi-security-sentinel` -> category=review, name=aimi-security-sentinel)
2. Read the agent definition file: `$AIMI_PLUGIN_DIR/agents/CATEGORY/NAME.md`
3. Strip the YAML frontmatter (everything between the first two `---` lines)
4. Use the remaining body as the agent'"'"'s system prompt
5. Spawn: `Task(subagent_type="general", prompt="[agent system prompt]\n\n[original task prompt]")`

Run all agent Tasks in parallel as instructed by the command below.

---

'

  printf '%s%s' "$preamble" "$body"
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

  local translated_body
  translated_body=$(translate_command_body "$FM_BODY")

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
    return 0
  fi

  mkdir -p "$cmd_dir"

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

    local dst_name="${cmd_name}.md"

    translate_command "$src_file" "$cmd_dir/$dst_name"
    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Command: aimi/$dst_name"
  done

  ok "Installed $count commands to $cmd_dir"
}

# ---------------------------------------------------------------------------
# install_agents — translate and write agents
# ---------------------------------------------------------------------------
install_agents() {
  local src="$1"
  local target_dir="$2"
  local agent_dir="$target_dir/agents"
  local count=0

  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] Would install agents to $agent_dir"
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

    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Skill: aimi-$skillname"
  done

  ok "Installed $count skills to $skill_dir"
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
  install_mcp "$target_dir"

  local plugin_dir="$target_dir/plugins/$PLUGIN_NAME"
  set_env_var "$plugin_dir"

  echo
  ok "Installation complete!"
  echo
  log "Plugin source: $plugin_dir"
  log "Commands:      $target_dir/commands/aimi/*.md"
  log "Agents:        $target_dir/agents/aimi-*.md"
  log "Skills:        $target_dir/skills/aimi-*/"
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
    log "[dry-run] Would remove $target_dir/agents/aimi-*.md"
    log "[dry-run] Would remove $target_dir/skills/aimi-*/"
    log "[dry-run] Would remove $target_dir/plugins/$PLUGIN_NAME/"
    log "[dry-run] Would remove context7 from $target_dir/opencode.json"
    log "[dry-run] Would remove AIMI_PLUGIN_DIR from shell profiles"
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
  [ "$count" -gt 0 ] && ok "Removed $count commands"

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
