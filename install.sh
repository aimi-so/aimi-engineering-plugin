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

log()  { printf '\033[0;34m%s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing (no getopt — portable)
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT_MODE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --verbose)   VERBOSE=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: ./install.sh [OPTIONS]

Install aimi-engineering plugin for OpenCode.

Options:
  --project     Install into .opencode/ in current directory (project-level)
  --uninstall   Remove installed files
  --dry-run     Show what would be done without doing it
  --verbose     Print detailed progress
  --help        Show this help

Examples:
  ./install.sh                  # Global install to ~/.config/opencode/
  ./install.sh --project        # Project install to .opencode/
  ./install.sh --uninstall      # Remove global install
  ./install.sh --dry-run        # Preview changes
USAGE
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help for usage." ;;
  esac
  shift
done

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
# translate_command — convert Claude command .md to OpenCode command .md
# ---------------------------------------------------------------------------
translate_command() {
  local src_file="$1"
  local dst_file="$2"

  parse_frontmatter "$src_file"

  local desc
  desc=$(fm_get "description") || desc=""

  {
    printf '%s\n' "---"
    printf 'description: %s\n' "$desc"
    printf '%s\n' "---"
    printf '%s' "$FM_BODY"
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

  {
    printf '%s\n' "---"
    printf '%s\n' "mode: agent"
    printf 'description: %s\n' "$desc"
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
  local cmd_dir="$target_dir/commands"
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

    # Derive OpenCode filename: aimi:plan.md -> aimi-plan.md
    local dst_name
    dst_name=$(printf '%s' "$basename" | sed 's/://g')
    # Prefix with aimi- if not already
    case "$dst_name" in
      aimi-*|aimi*) ;; # already prefixed via name
    esac
    dst_name="aimi-${dst_name#aimi}"
    # Normalize: aimi-aimi -> aimi, handle edge cases
    dst_name=$(printf '%s' "$dst_name" | sed 's/^aimi-aimi/aimi/')

    translate_command "$src_file" "$cmd_dir/$dst_name"
    count=$((count + 1))
    [ "$VERBOSE" -eq 1 ] && log "  Command: $dst_name"
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
      jq '.mcp = (.mcp // {}) + {"context7": {"type": "http", "url": "https://mcp.context7.com/mcp"}}' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    # Try python3 fallback
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "
import json, sys
with open('$config_file') as f:
    try: cfg = json.load(f)
    except: cfg = {}
cfg.setdefault('mcp', {})['context7'] = {'type': 'http', 'url': 'https://mcp.context7.com/mcp'}
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
      "type": "http",
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
  install_mcp "$target_dir"

  local plugin_dir="$target_dir/plugins/$PLUGIN_NAME"
  set_env_var "$plugin_dir"

  echo
  ok "Installation complete!"
  echo
  log "Plugin source: $plugin_dir"
  log "Commands:      $target_dir/commands/aimi-*.md"
  log "Agents:        $target_dir/agents/aimi-*.md"
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
    log "[dry-run] Would remove $target_dir/commands/aimi-*.md"
    log "[dry-run] Would remove $target_dir/agents/aimi-*.md"
    log "[dry-run] Would remove $target_dir/plugins/$PLUGIN_NAME/"
    log "[dry-run] Would remove context7 from $target_dir/opencode.json"
    log "[dry-run] Would remove AIMI_PLUGIN_DIR from shell profiles"
    return 0
  fi

  # Remove commands
  local count=0
  for f in "$target_dir/commands/"aimi-*.md; do
    [ -f "$f" ] || continue
    rm "$f"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && ok "Removed $count commands"

  # Remove agents
  count=0
  for f in "$target_dir/agents/"aimi-*.md; do
    [ -f "$f" ] || continue
    rm "$f"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] && ok "Removed $count agents"

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
