#!/bin/bash

# Git Worktree Manager
# Handles creating, listing, switching, and cleaning up Git worktrees
# KISS principle: Simple, interactive, opinionated

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Detect flock availability once (Linux has it; macOS falls back to a mkdir spinlock)
_HAS_FLOCK=$(command -v flock &>/dev/null && echo 1 || echo 0)

# serve start|stop|status configuration
DEV_SERVER_BASE_PORT=4100        # first port probed when picking a free loopback port
DEV_SERVER_PORT_SCAN_LIMIT=20    # give up after this many ports scanned upward from base
DEV_SERVER_READY_TIMEOUT="${DEV_SERVER_READY_TIMEOUT:-90}"      # seconds to wait for the readiness probe per launch attempt (env-overridable; a cold-compiling bundler needs headroom beyond the old 30s default)
DEV_SERVER_PROBE_MAX_TIME="${DEV_SERVER_PROBE_MAX_TIME:-5}"     # max seconds per individual HTTP probe inside _wait_ready (env-overridable)
DEV_SERVER_STOP_GRACE=5          # seconds to wait after SIGTERM before escalating to SIGKILL
DEV_SERVER_LOG_MAX_BYTES="${DEV_SERVER_LOG_MAX_BYTES:-10485760}" # 10MB cap (env-overridable); serve_start's reuse path truncates to the final half when exceeded, so a server kept alive across phase-mode waves never grows its log unbounded

# Validate branch name to prevent command injection
validate_branch_name() {
  local name="$1"
  if ! [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo -e "${RED}Error: Invalid branch name: $name${NC}" >&2
    exit 1
  fi
}

# Get repo root
GIT_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_DIR="$GIT_ROOT/.worktrees"

# Ensure .worktrees is in .gitignore
ensure_gitignore() {
  local gi="$GIT_ROOT/.gitignore"

  # Committed truth first: if .worktrees is already in HEAD's .gitignore,
  # there is nothing to do — appending on top of that risks a stray
  # duplicate line without fixing anything. grep against the working copy
  # alone would miss this when the file has since been edited but not
  # staged/committed yet.
  if git -C "$GIT_ROOT" show HEAD:.gitignore 2>/dev/null | grep -q "^\.worktrees$"; then
    return
  fi

  # HEAD doesn't have the entry (or there's no HEAD commit yet). Only
  # append when doing so introduces no *new* uncommitted-diff signal: the
  # file is untracked (nothing committed to diff against) or it already has
  # uncommitted changes of its own (one more line is not a new violation of
  # a clean tree). A tracked-and-clean file missing the entry is the one
  # case container mode must never silently dirty — warn instead.
  if ! git -C "$GIT_ROOT" ls-files --error-unmatch "$gi" &>/dev/null; then
    echo ".worktrees" >> "$gi"
  elif ! git -C "$GIT_ROOT" diff --quiet -- "$gi" 2>/dev/null; then
    echo ".worktrees" >> "$gi"
  else
    echo -e "${YELLOW}Warning: .gitignore is tracked and clean but missing a .worktrees entry. Add it and commit — container mode will not modify a tracked, clean .gitignore for you.${NC}" >&2
  fi
}

# Copy .env files from main repo to worktree
copy_env_files() {
  local worktree_path="$1"

  echo -e "${BLUE}Copying environment files...${NC}"

  # Find all .env* files in root (excluding .env.example which should be in git)
  local env_files=()
  for f in "$GIT_ROOT"/.env*; do
    if [[ -f "$f" ]]; then
      local basename=$(basename "$f")
      # Skip .env.example (that's typically committed to git)
      if [[ "$basename" != ".env.example" ]]; then
        env_files+=("$basename")
      fi
    fi
  done

  if [[ ${#env_files[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}ℹ️  No .env files found in main repository${NC}"
    return
  fi

  local copied=0
  for env_file in "${env_files[@]}"; do
    local source="$GIT_ROOT/$env_file"
    local dest="$worktree_path/$env_file"

    if [[ -f "$dest" ]]; then
      echo -e "  ${YELLOW}⚠️  $env_file already exists, backing up to ${env_file}.backup${NC}"
      cp "$dest" "${dest}.backup"
    fi

    cp "$source" "$dest"
    chmod 600 "$dest"
    echo -e "  ${GREEN}✓ Copied $env_file${NC}"
    copied=$((copied + 1))
  done

  echo -e "  ${GREEN}✓ Copied $copied environment file(s)${NC}"
}

# Create a new worktree
create_worktree() {
  local branch_name=""
  local from_branch="main"

  # Parse arguments (supports both positional and --from flag)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        from_branch="$2"
        shift 2
        ;;
      *)
        if [[ -z "$branch_name" ]]; then
          branch_name="$1"
        else
          from_branch="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$branch_name" ]]; then
    echo -e "${RED}Error: Branch name required${NC}"
    exit 1
  fi

  # Validate branch names
  validate_branch_name "$branch_name"
  validate_branch_name "$from_branch"

  local worktree_path="$WORKTREE_DIR/$branch_name"

  # Path containment check — prevent directory traversal
  local resolved_path
  resolved_path=$(realpath -m "$worktree_path")
  local resolved_dir
  resolved_dir=$(realpath -m "$WORKTREE_DIR")
  if [[ ! "$resolved_path" == "$resolved_dir"/* ]]; then
    echo -e "${RED}Error: Worktree path escapes expected directory${NC}" >&2
    exit 1
  fi

  # Check if worktree already exists — reuse silently (non-interactive).
  # Require the .git entry, not just the directory, so a stray non-worktree
  # directory at this path isn't mistaken for a worktree to reuse.
  if [[ -d "$worktree_path" && -e "$worktree_path/.git" ]]; then
    echo -e "${YELLOW}Worktree already exists at: $worktree_path${NC}"
    echo "$worktree_path"
    return
  fi

  echo -e "${BLUE}Creating worktree: $branch_name${NC}"
  echo "  From: $from_branch"
  echo "  Path: $worktree_path"

  # Create worktree (git worktree add works without checking out from_branch)
  mkdir -p "$WORKTREE_DIR"
  ensure_gitignore

  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    # Branch already exists (e.g. `remove --keep-branch` preserved it from a
    # prior run). Find out whether another worktree — or the main checkout —
    # already holds it before deciding how to attach.
    local holder_path="" current_wt=""
    while IFS= read -r line; do
      if [[ "$line" == worktree\ * ]]; then
        current_wt="${line#worktree }"
      elif [[ "$line" == "branch refs/heads/$branch_name" ]]; then
        holder_path="$current_wt"
      fi
    done < <(git worktree list --porcelain)

    if [[ -n "$holder_path" ]]; then
      echo -e "${RED}Error: Branch '$branch_name' is already checked out at: $holder_path${NC}" >&2
      exit 1
    fi

    echo -e "${BLUE}Branch exists and is unused, attaching worktree...${NC}"
    git worktree add "$worktree_path" "$branch_name"
  else
    echo -e "${BLUE}Creating worktree...${NC}"
    git worktree add -b "$branch_name" "$worktree_path" -- "$from_branch"
  fi

  # Copy environment files
  copy_env_files "$worktree_path"

  echo -e "${GREEN}✓ Worktree created successfully!${NC}"
  echo ""
  echo "To switch to this worktree:"
  echo -e "${BLUE}cd $worktree_path${NC}"
  echo ""
}

# List all worktrees
list_worktrees() {
  echo -e "${BLUE}Available worktrees:${NC}"
  echo ""

  if [[ ! -d "$WORKTREE_DIR" ]]; then
    echo -e "${YELLOW}No worktrees found${NC}"
    return
  fi

  local count=0
  for worktree_path in "$WORKTREE_DIR"/*; do
    if [[ -d "$worktree_path" && -e "$worktree_path/.git" ]]; then
      count=$((count + 1))
      local worktree_name=$(basename "$worktree_path")
      local branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

      if [[ "$PWD" == "$worktree_path" ]]; then
        echo -e "${GREEN}✓ $worktree_name${NC} (current) → branch: $branch"
      else
        echo -e "  $worktree_name → branch: $branch"
      fi
    fi
  done

  if [[ $count -eq 0 ]]; then
    echo -e "${YELLOW}No worktrees found${NC}"
  else
    echo ""
    echo -e "${BLUE}Total: $count worktree(s)${NC}"
  fi

  echo ""
  echo -e "${BLUE}Main repository:${NC}"
  local main_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  echo "  Branch: $main_branch"
  echo "  Path: $GIT_ROOT"
}

# Switch to a worktree
switch_worktree() {
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}"
    echo "Usage: worktree-manager.sh switch <worktree-name>"
    exit 1
  fi

  local worktree_path="$WORKTREE_DIR/$worktree_name"

  if [[ ! -d "$worktree_path" ]]; then
    echo -e "${RED}Error: Worktree not found: $worktree_name${NC}"
    echo ""
    list_worktrees
    exit 1
  fi

  echo -e "${GREEN}Switching to worktree: $worktree_name${NC}"
  cd "$worktree_path"
  echo -e "${BLUE}Now in: $(pwd)${NC}"
}

# Copy env files to an existing worktree (or current directory if in a worktree)
copy_env_to_worktree() {
  local worktree_name="$1"
  local worktree_path

  if [[ -z "$worktree_name" ]]; then
    # Check if we're currently in a worktree
    local current_dir=$(pwd)
    if [[ "$current_dir" == "$WORKTREE_DIR"/* ]]; then
      worktree_path="$current_dir"
      worktree_name=$(basename "$worktree_path")
      echo -e "${BLUE}Detected current worktree: $worktree_name${NC}"
    else
      echo -e "${YELLOW}Usage: worktree-manager.sh copy-env [worktree-name]${NC}"
      echo "Or run from within a worktree to copy to current directory"
      list_worktrees
      return 1
    fi
  else
    worktree_path="$WORKTREE_DIR/$worktree_name"

    if [[ ! -d "$worktree_path" ]]; then
      echo -e "${RED}Error: Worktree not found: $worktree_name${NC}"
      list_worktrees
      return 1
    fi
  fi

  copy_env_files "$worktree_path"
  echo ""
}

# Clean up completed worktrees
cleanup_worktrees() {
  if [[ ! -d "$WORKTREE_DIR" ]]; then
    echo -e "${YELLOW}No worktrees to clean up${NC}"
    return
  fi

  echo -e "${BLUE}Checking for completed worktrees...${NC}"
  echo ""

  local found=0
  local to_remove=()

  for worktree_path in "$WORKTREE_DIR"/*; do
    if [[ -d "$worktree_path" && -e "$worktree_path/.git" ]]; then
      local worktree_name=$(basename "$worktree_path")

      # Skip if current worktree
      if [[ "$PWD" == "$worktree_path" ]]; then
        echo -e "${YELLOW}(skip) $worktree_name - currently active${NC}"
        continue
      fi

      found=$((found + 1))
      to_remove+=("$worktree_path")
      echo -e "${YELLOW}• $worktree_name${NC}"
    fi
  done

  if [[ $found -eq 0 ]]; then
    echo -e "${GREEN}No inactive worktrees to clean up${NC}"
    return
  fi

  echo ""
  echo -e "${BLUE}Cleaning up $found worktree(s)...${NC}"
  for worktree_path in "${to_remove[@]}"; do
    local worktree_name=$(basename "$worktree_path")
    # Best-effort stop before removal — see remove_worktree's own comment for
    # why: an unconditional cleanup that skips this would orphan any dev
    # server still running against one of these worktrees.
    serve_stop "$worktree_name" || true
    git worktree remove "$worktree_path" --force 2>/dev/null || true
    git branch -D "$worktree_name" 2>/dev/null || true
    echo -e "${GREEN}✓ Removed: $worktree_name${NC}"
  done

  # Clean up empty directory if nothing left
  if [[ -z "$(ls -A "$WORKTREE_DIR" 2>/dev/null)" ]]; then
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
  fi

  echo -e "${GREEN}Cleanup complete!${NC}"
}

# Remove a specific worktree and its branch (non-interactive)
remove_worktree() {
  local worktree_name=""
  local keep_branch=false

  # Parse arguments (supports both positional and --keep-branch flag)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-branch)
        keep_branch=true
        shift
        ;;
      *)
        if [[ -z "$worktree_name" ]]; then
          worktree_name="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}"
    echo "Usage: worktree-manager.sh remove <worktree-name> [--keep-branch]"
    exit 1
  fi

  # Validate worktree name
  validate_branch_name "$worktree_name"

  # Stop any dev server registered for this worktree before removing its
  # backing directory — best-effort: serve_stop always returns 0 on every
  # path, so this never fails or blocks removal even when it finds nothing
  # to stop. Without this, a live server outlives the container it was
  # serving from, still holding its port with dev-server.json reporting
  # running:true forever.
  serve_stop "$worktree_name" || true

  local worktree_path="$WORKTREE_DIR/$worktree_name"

  if [[ -d "$worktree_path" ]]; then
    git worktree remove "$worktree_path" --force 2>/dev/null || true
    echo -e "${GREEN}✓ Removed worktree: $worktree_name${NC}"
  else
    echo -e "${YELLOW}Worktree directory not found: $worktree_name (may already be removed)${NC}"
    # Still try to clean up git worktree tracking
    git worktree prune 2>/dev/null || true
  fi

  # Clean up the associated branch, unless the caller asked to keep it
  if [[ "$keep_branch" == true ]]; then
    echo -e "${BLUE}ℹ️  Preserving branch: $worktree_name${NC}"
  else
    git branch -D "$worktree_name" 2>/dev/null || true
  fi

  # Remove empty .worktrees directory
  if [[ -d "$WORKTREE_DIR" ]] && [[ -z "$(ls -A "$WORKTREE_DIR" 2>/dev/null)" ]]; then
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
  fi
}

# Detect the package manager for <worktree_path> by lockfile, fixed priority
# order: bun.lockb > pnpm-lock.yaml > yarn.lock > else npm. Prints exactly one
# of bun|pnpm|yarn|npm on stdout. Shared by install_deps (which layers its own
# package-lock.json npm-ci-vs-install distinction on top) and serve_start
# (which only needs the pm name to pick its `<pm> run dev` command) — the
# single place this detection order is defined, instead of two drifted copies.
_detect_package_manager() {
  local worktree_path="$1"
  if [[ -f "$worktree_path/bun.lockb" ]]; then
    printf 'bun'
  elif [[ -f "$worktree_path/pnpm-lock.yaml" ]]; then
    printf 'pnpm'
  elif [[ -f "$worktree_path/yarn.lock" ]]; then
    printf 'yarn'
  else
    printf 'npm'
  fi
}

# Install dependencies inside a worktree by detecting the package manager from its lockfile.
# Advisory/non-fatal contract: a missing package.json is not an error (exit 0), and an install
# failure is reported clearly but never left in a state that trips the script's `set -e`.
install_deps() {
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}"
    echo "Usage: worktree-manager.sh install-deps <worktree-name>"
    exit 1
  fi

  # Validate worktree name before any filesystem access
  validate_branch_name "$worktree_name"

  local worktree_path="$WORKTREE_DIR/$worktree_name"

  # Path containment check — prevent directory traversal
  local resolved_path
  resolved_path=$(realpath -m "$worktree_path")
  local resolved_dir
  resolved_dir=$(realpath -m "$WORKTREE_DIR")
  if [[ ! "$resolved_path" == "$resolved_dir"/* ]]; then
    echo -e "${RED}Error: Worktree path escapes expected directory${NC}" >&2
    exit 1
  fi

  if [[ ! -d "$worktree_path" ]]; then
    echo -e "${RED}Error: Worktree directory not found: $worktree_name${NC}" >&2
    exit 1
  fi

  if [[ ! -f "$worktree_path/package.json" ]]; then
    echo -e "${YELLOW}ℹ️  No package.json in worktree, skipping dependency install: $worktree_name${NC}"
    return 0
  fi

  # Package manager name comes from the shared detector; the install-specific
  # command and lockfile path (used below for the idempotency mtime check)
  # are layered on top here since serve_start never needs either.
  local pm_name pm_cmd lockfile_path=""
  pm_name=$(_detect_package_manager "$worktree_path")
  case "$pm_name" in
    bun)
      pm_cmd="bun install"
      lockfile_path="$worktree_path/bun.lockb"
      ;;
    pnpm)
      pm_cmd="pnpm install"
      lockfile_path="$worktree_path/pnpm-lock.yaml"
      ;;
    yarn)
      pm_cmd="yarn install"
      lockfile_path="$worktree_path/yarn.lock"
      ;;
    npm)
      if [[ -f "$worktree_path/package-lock.json" ]]; then
        pm_cmd="npm ci"
        lockfile_path="$worktree_path/package-lock.json"
      else
        pm_cmd="npm install"
      fi
      ;;
  esac

  # Idempotency short-circuit: when a recognized lockfile exists and node_modules/
  # is already at least as fresh as it, skip the install entirely — a resumed
  # container that already had correct dependencies never pays a cold reinstall,
  # and npm ci never deletes a node_modules/ that was already correct. Only
  # applies when a lockfile was detected above; the no-lockfile (npm install)
  # branch and a missing node_modules/ always fall through to a real install.
  if [[ -n "$lockfile_path" ]] && [[ -d "$worktree_path/node_modules" ]]; then
    local lockfile_mtime node_modules_mtime
    lockfile_mtime=$(stat -c '%Y' "$lockfile_path" 2>/dev/null || stat -f '%m' "$lockfile_path" 2>/dev/null)
    node_modules_mtime=$(stat -c '%Y' "$worktree_path/node_modules" 2>/dev/null || stat -f '%m' "$worktree_path/node_modules" 2>/dev/null)
    if [[ -n "$lockfile_mtime" ]] && [[ -n "$node_modules_mtime" ]] && [[ "$node_modules_mtime" -ge "$lockfile_mtime" ]]; then
      echo -e "${GREEN}✓ Dependencies already up to date in worktree '$worktree_name' (node_modules/ is not older than the lockfile), skipping install${NC}"
      return 0
    fi
  fi

  echo -e "${BLUE}Installing dependencies in worktree '$worktree_name' with $pm_name...${NC}"

  # Guarded subshell: an install failure must never trip the script's top-level `set -e`.
  if ! ( cd "$worktree_path" && eval "$pm_cmd" ); then
    if [[ "$pm_cmd" == "npm ci" ]]; then
      echo -e "${YELLOW}⚠️  npm ci failed, falling back to npm install...${NC}"
      if ! ( cd "$worktree_path" && npm install ); then
        echo -e "${RED}Error: Dependency install failed for worktree '$worktree_name' (npm, after npm ci and npm install fallback)${NC}" >&2
        return 1
      fi
      echo -e "${GREEN}✓ Dependencies installed successfully with npm (install fallback) in worktree: $worktree_name${NC}"
      return 0
    fi

    echo -e "${RED}Error: Dependency install failed for worktree '$worktree_name' using $pm_name${NC}" >&2
    return 1
  fi

  echo -e "${GREEN}✓ Dependencies installed successfully with $pm_name in worktree: $worktree_name${NC}"
  return 0
}

# Merge a worktree branch into a target branch
merge_worktree() {
  local worktree_name=""
  local target_branch=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --into)
        target_branch="$2"
        shift 2
        ;;
      *)
        if [[ -z "$worktree_name" ]]; then
          worktree_name="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}"
    echo "Usage: worktree-manager.sh merge <worktree-name> [--into <branch>]"
    exit 1
  fi

  # Resolve the worktree branch name
  local worktree_path="$WORKTREE_DIR/$worktree_name"
  local worktree_branch=""

  if [[ -d "$worktree_path" && -e "$worktree_path/.git" ]]; then
    worktree_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
  else
    # If not found as a worktree dir, treat the name as a branch name directly
    worktree_branch="$worktree_name"
  fi

  if [[ -z "$worktree_branch" ]]; then
    echo -e "${RED}Error: Could not resolve branch for worktree: $worktree_name${NC}"
    exit 1
  fi

  # Default target to current branch if not specified
  if [[ -z "$target_branch" ]]; then
    target_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -z "$target_branch" ]]; then
      echo -e "${RED}Error: Could not determine current branch${NC}"
      exit 1
    fi
  fi

  # Validate branch names
  validate_branch_name "$worktree_branch"
  validate_branch_name "$target_branch"

  echo -e "${BLUE}Merging branch '$worktree_branch' into '$target_branch'...${NC}"

  # Checkout the target branch (validated above, -- not used here as it changes checkout semantics)
  git checkout "$target_branch"
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: Failed to checkout target branch: $target_branch${NC}"
    exit 1
  fi

  # Attempt the merge
  if git merge -- "$worktree_branch"; then
    local merge_hash
    merge_hash=$(git rev-parse HEAD)
    echo -e "${GREEN}Merge successful!${NC}"
    echo -e "Merge commit: ${GREEN}$merge_hash${NC}"
  else
    echo -e "${RED}Merge conflict detected!${NC}"
    echo -e "${YELLOW}Conflicting files:${NC}"
    git diff --name-only --diff-filter=U
    exit 1
  fi
}

# Merge multiple worktree branches sequentially into a target branch
merge_all_worktrees() {
  local branches=()
  local target_branch=""

  # Parse arguments: collect branches and optional --into flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --into)
        target_branch="$2"
        shift 2
        ;;
      *)
        branches+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#branches[@]} -eq 0 ]]; then
    echo -e "${RED}Error: At least one branch name required${NC}"
    echo "Usage: worktree-manager.sh merge-all <branch1> <branch2> ... [--into <branch>]"
    exit 1
  fi

  # Default target to current branch if not specified
  if [[ -z "$target_branch" ]]; then
    target_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -z "$target_branch" ]]; then
      echo -e "${RED}Error: Could not determine current branch${NC}"
      exit 1
    fi
  fi

  echo -e "${BLUE}Merging ${#branches[@]} branch(es) into '$target_branch'...${NC}"
  echo ""

  local merged=0
  for branch in "${branches[@]}"; do
    echo -e "${BLUE}[$((merged + 1))/${#branches[@]}] Merging '$branch'...${NC}"

    # Resolve branch name from worktree if applicable
    local worktree_path="$WORKTREE_DIR/$branch"
    local resolved_branch=""

    if [[ -d "$worktree_path" && -e "$worktree_path/.git" ]]; then
      resolved_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    else
      resolved_branch="$branch"
    fi

    # Checkout target branch
    git checkout "$target_branch"
    if [[ $? -ne 0 ]]; then
      echo -e "${RED}Error: Failed to checkout target branch: $target_branch${NC}"
      exit 1
    fi

    # Attempt merge
    if git merge "$resolved_branch"; then
      local merge_hash
      merge_hash=$(git rev-parse HEAD)
      echo -e "${GREEN}  Merged '$branch' successfully (commit: $merge_hash)${NC}"
      merged=$((merged + 1))
    else
      echo -e "${RED}Merge conflict on branch '$branch'!${NC}"
      echo -e "${YELLOW}Conflicting files:${NC}"
      git diff --name-only --diff-filter=U
      echo ""
      echo -e "${RED}Stopping merge-all. $merged of ${#branches[@]} branch(es) merged before conflict.${NC}"
      exit 1
    fi
  done

  echo ""
  echo -e "${GREEN}All ${#branches[@]} branch(es) merged successfully into '$target_branch'!${NC}"
}

# ============================================================================
# Dev server management (serve start|stop|status)
# ============================================================================
#
# Manages a loopback-only dev server for a container worktree: picks a free
# 127.0.0.1 port, launches the worktree's `dev` script as its own process
# group (via setsid), confirms readiness with an HTTP probe, confirms the
# listening socket actually belongs to the process it just spawned, and
# tracks the result in .aimi/state/dev-server.json keyed by the container's
# absolute resolved path (see _dev_server_key below) — not by worktree/branch
# name, since two project groups in a multi-repo layout can share the same
# `[branchName]`. Every failure mode here degrades gracefully (exit 0, clear
# message) except a missing or invalid worktree-name argument (usage error:
# non-zero exit, stderr message, no stdout at all) — and, for serve_start
# specifically, a worktree directory that doesn't exist or a resolved path
# that escapes .worktrees/ are the same usage-error category, not a runtime
# degradation: both mean the caller passed a name that never corresponded to
# a real worktree.
#
# A live pid is NOT proof of identity. The OS recycles pids, so a dead dev
# server's pid can be reassigned to a completely unrelated process before
# stop/start ever runs again. _is_pid_alive (below) only answers "is
# something running at this pid right now" — that alone is never grounds to
# kill or reuse a registered pid. The actual safety gate is
# dev_server_entry_is_ours, which additionally compares the pid's current
# process-identity token (its /proc/pid/stat starttime, or `ps -o lstart=`
# where /proc is unavailable) against the token recorded in the entry at
# start time; a live pid with a missing or mismatched token is treated
# exactly like a dead one.

# Portable exclusive lock (Linux: flock, macOS: mkdir spinlock).
# Usage: call inside a subshell with an FD 200 redirect: ( _lock "$f"; ... ) 200>"$f"
_lock() {
  if [[ "$_HAS_FLOCK" -eq 1 ]]; then
    flock -x 200
  else
    local lockdir="$1.d"
    local pidfile="$lockdir/pid"
    local attempts=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      sleep 0.05
      attempts=$((attempts + 1))
      if [[ "$attempts" -ge 200 ]]; then
        # Only force-break a lock whose holder is comprovably dead (or whose
        # pid file is missing/unreadable) — never a live holder just because
        # the spin threshold passed. Always reset attempts so the next pass
        # re-evaluates instead of spinning here forever.
        local holder_pid
        holder_pid=$(cat "$pidfile" 2>/dev/null)
        if [[ -z "$holder_pid" ]] || ! _is_pid_alive "$holder_pid"; then
          rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir"
        fi
        attempts=0
      fi
    done
    printf '%s' "$$" > "$pidfile" 2>/dev/null || true

    # Chain onto any EXIT trap the caller already installed instead of
    # silently overwriting it.
    local existing_trap
    existing_trap=$(trap -p EXIT)
    existing_trap="${existing_trap#trap -- \'}"
    existing_trap="${existing_trap%\' EXIT}"
    # rm -rf, not rmdir: $lockdir now holds the pid file written above, so a
    # plain rmdir would fail on "Directory not empty" — and under `set -e`,
    # a trap whose own command exits non-zero propagates that failure to the
    # caller's shell instead of quietly cleaning up. The explicit `|| true`
    # guards the same way for good measure.
    trap "rm -rf '$lockdir' 2>/dev/null || true; ${existing_trap}" EXIT
  fi
}

# Process-liveness probe, mirroring roadmap.py's is_pid_alive (which aimi-cli.sh's
# stale-claim recovery calls): a kill -0 signal-zero probe. "No such process"
# -> dead. "Exists, not permitted to signal" -> alive (a foreign/other-user
# process is still a live process).
# Liveness alone is NOT identity — see dev_server_entry_is_ours below, the
# real gate used before any kill or reuse of a registered dev-server.json pid.
_is_pid_alive() {
  local pid="$1"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]]; then
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  local err
  err=$(kill -0 "$pid" 2>&1 >/dev/null) || true
  if printf '%s' "$err" | grep -qi "not permitted"; then
    return 0
  fi
  return 1
}

# Process-identity token for <pid>: starttime (field 22 overall of
# /proc/pid/stat on Linux), falling back to `ps -o lstart=` when /proc is
# unavailable or unreadable (e.g. macOS). This is what tells "this exact
# process" apart from "some process that now happens to hold this pid" — a
# plain liveness check cannot, since pids get recycled by the OS.
#
# /proc/pid/stat's second field (comm) is parenthesized and may itself
# contain spaces or parens, so fields can't be split by position from the
# start of the line; instead, strip everything up to and including the
# LAST ')' — the remainder starts at field 3 (state), so its 20th
# whitespace-separated field is field 22 (starttime) overall.
#
# Prints empty on any failure. Callers MUST treat empty as "no identity
# proof" — never as a wildcard match.
process_identity() {
  local pid="$1"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]]; then
    return 0
  fi
  if [[ -r "/proc/$pid/stat" ]]; then
    local stat_line rest starttime
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || true
    if [[ -n "$stat_line" ]]; then
      rest="${stat_line##*)}"
      starttime=$(printf '%s' "$rest" | awk '{print $20}')
      if [[ -n "$starttime" ]]; then
        printf '%s' "$starttime"
        return 0
      fi
    fi
  fi
  # Portable fallback: /proc absent (macOS) or unreadable for this pid.
  if command -v ps &>/dev/null; then
    local lstart
    lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -n "$lstart" ]]; then
      printf '%s' "$lstart"
      return 0
    fi
  fi
  return 0
}

# The real safety gate before killing or reusing a dev-server.json pid:
# alive AND the entry's recorded identity token is non-empty AND it matches
# the pid's identity right now. Any other combination — dead pid, an empty
# recorded token (a pre-upgrade entry written before this field existed), or
# a mismatched token (a recycled pid) — is a hard failure, so a single
# non-ours pid is never treated as ours by one caller and foreign by another.
dev_server_entry_is_ours() {
  local pid="$1" recorded_identity="$2"
  _is_pid_alive "$pid" || return 1
  [[ -n "$recorded_identity" ]] || return 1
  local current_identity
  current_identity=$(process_identity "$pid")
  [[ -n "$current_identity" ]] || return 1
  [[ "$current_identity" == "$recorded_identity" ]]
}

# Walk upward from CWD looking for a .aimi/ directory, mirroring aimi-cli.sh's
# find_aimi_root. Stops at $HOME. GIT_ROOT (line ~27) cannot be assumed to be
# the right place: inside a nested phase/story container GIT_ROOT resolves to
# that container's own worktree root, and in a multi-repo layout .aimi/ sits
# above any single git repo. Prints the discovered root on stdout; returns 1
# (prints nothing) if none is found.
find_aimi_root() {
  local dir="$PWD"
  while true; do
    if [[ -d "$dir/.aimi" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    if [[ "$dir" == "$HOME" ]]; then
      return 1
    fi
    local parent
    parent=$(dirname "$dir")
    if [[ "$parent" == "$dir" ]]; then
      return 1
    fi
    dir="$parent"
  done
}

# A successful connect means something is already listening (occupied); a
# refused/failed connect means the port is free. Loopback-only by construction.
# FD 3 is opened by, and belongs entirely to, the `(exec 3<> ...)` subshell —
# it closes automatically when that subshell exits, so there is nothing of
# ours left to clean up here. An explicit `exec 3>&-` in this (parent) scope
# would not be closing that socket at all; it would be blindly closing
# whatever FD 3 happens to mean in the caller's own shell, which is exactly
# the kind of action-at-a-distance a shared script like this must never risk.
_port_free() {
  local port="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    return 1
  fi
  return 0
}

# Scan upward from DEV_SERVER_BASE_PORT for the first free loopback port.
_pick_free_port() {
  local port="$DEV_SERVER_BASE_PORT"
  local tries=0
  while [[ "$tries" -lt "$DEV_SERVER_PORT_SCAN_LIMIT" ]]; do
    if _port_free "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
    tries=$((tries + 1))
  done
  return 1
}

# Poll http://127.0.0.1:<port> (never a wildcard address) until it answers or
# a bounded timeout elapses. "Process started" is not "server up" — only an
# actual HTTP response counts. Bounded by real wall-clock time via the bash
# SECONDS builtin rather than an iteration count times an assumed per-probe
# duration — a fixed iteration count would let a slow --max-time compound
# with the iteration count and blow well past the declared timeout.
# Returns: 0 ready; 1 nothing was ever listening on the port; 2 something was
# listening but never answered HTTP within the budget — callers use 1 vs 2 to
# tell "wrong port/flag, worth another attempt" from "just slow, retrying
# would only repeat the same failure."
_wait_ready() {
  local port="$1"
  local timeout_s="${2:-$DEV_SERVER_READY_TIMEOUT}"
  local start_s=$SECONDS
  while [[ $((SECONDS - start_s)) -lt "$timeout_s" ]]; do
    if curl -sf -o /dev/null --max-time "$DEV_SERVER_PROBE_MAX_TIME" "http://127.0.0.1:${port}" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  if _port_free "$port"; then
    return 1
  fi
  return 2
}

# Resolve the pid holding the LISTEN socket on 127.0.0.1:<port>, preferring
# `ss` (iproute2) and falling back to `lsof`. Prints nothing if neither tool
# is available or nothing is found.
_port_listener_pid() {
  local port="$1"
  local out=""
  if command -v ss &>/dev/null; then
    out=$(ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1) || true
  fi
  if [[ -z "$out" ]] && command -v lsof &>/dev/null; then
    out=$(lsof -ti tcp:"${port}" -sTCP:LISTEN 2>/dev/null | head -n1) || true
  fi
  printf '%s' "$out"
}

# Resolve the actual local bind address of the LISTEN socket owned by <pid> on
# <port>, mirroring _port_listener_pid's ss-then-lsof fallback. A readiness
# probe and an ownership check both query 127.0.0.1 and answer identically
# whether the underlying socket is loopback-only or wildcard, so this is the
# only way to tell the two apart. Strips the trailing :<port> and any IPv6
# brackets from the resolved address. Prints nothing (fail closed) if neither
# tool resolves an address.
_listener_bind_addr() {
  local pid="$1" port="$2"
  local addr=""
  if command -v ss &>/dev/null; then
    addr=$(ss -H -ltnp "sport = :${port}" 2>/dev/null | grep "pid=${pid}," | awk '{print $4}' | head -n1) || true
  fi
  if [[ -z "$addr" ]] && command -v lsof &>/dev/null; then
    # lsof's NAME column (second-to-last field) is "<addr>:<port>"; the last
    # field is always the literal "(LISTEN)" state marker we already filtered on.
    addr=$(lsof -Pan -p "$pid" -i tcp:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $(NF-1)}' | head -n1) || true
  fi
  addr="${addr%:${port}}"
  addr="${addr#\[}"
  addr="${addr%\]}"
  printf '%s' "$addr"
}

# Kill the entire process group of a setsid-launched leader: SIGTERM the
# group, wait a grace period, then SIGKILL the group as a last resort. Never
# fails hard — stop must always be able to clear the state entry afterward.
# Three steps only, no isolated kill against the bare pid: _launch_dev_server
# always launches via setsid, so the leader's pid IS its pgid by construction
# — any signal a plain `kill $pgid` could deliver is already delivered by the
# matching `kill -- "-$pgid"` group signal above it, so the isolated form
# never reaches anything the group form doesn't.
_kill_process_group() {
  local pgid="$1"
  [[ -z "$pgid" ]] && return 0

  kill -TERM -- "-$pgid" 2>/dev/null || true

  local waited=0
  while _is_pid_alive "$pgid" && [[ "$waited" -lt "$DEV_SERVER_STOP_GRACE" ]]; do
    sleep 1
    waited=$((waited + 1))
  done

  # Unconditional final escalation: gating this on the leader's own liveness
  # would let a surviving child that ignored SIGTERM keep the port forever
  # once the leader itself has already exited (e.g. an npm that forks and
  # returns) — always SIGKILL the whole group, whether or not the leader is
  # still around to report itself alive.
  kill -9 -- "-$pgid" 2>/dev/null || true

  return 0
}

# Launch a dev command under setsid so it becomes its own session/process-
# group leader (pid == pgid), which is what serve_stop later negates for the
# group kill. We don't rely on setsid's own pid (util-linux versions differ
# on whether setsid forks before exec-ing its argument) — instead the exec'd
# process reports its own $$ to pid_file just before replacing its image via
# exec, which is reliable regardless of that fork behavior.
# Args: port log_file pid_file -- dev_cmd_words...
_launch_dev_server() {
  local port="$1" log_file="$2" pid_file="$3"
  shift 3
  # Truncate in place — never delete-then-recreate. pid_file was created
  # atomically by a real `mktemp` in serve_start (not `mktemp -u`), so its
  # path already exists; deleting and letting a later open() recreate it
  # would open a window for a symlink planted at that exact path to be
  # followed. `>|` also overrides noclobber, for the same reason.
  : >| "$pid_file"

  setsid env PORT="$port" HOST=127.0.0.1 bash -c 'printf "%s" "$$" >| "$0"; exec "$@"' \
    "$pid_file" "$@" </dev/null >"$log_file" 2>&1 &
  disown 2>/dev/null || true

  local waited=0
  while [[ ! -s "$pid_file" ]] && [[ "$waited" -lt 20 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  if [[ -s "$pid_file" ]]; then
    cat "$pid_file"
  fi
  return 0
}

# Read dev-server.json in full, defaulting to "{}" when absent or malformed.
_dev_server_read_all() {
  local state_file="$1"
  if [[ -f "$state_file" ]] && jq empty "$state_file" >/dev/null 2>&1; then
    cat "$state_file"
  else
    printf '{}'
  fi
}

# Resolve a worktree/branch name to the absolute path used as the
# dev-server.json key — the same realpath -m computation create_worktree's
# containment check already performs. Absolute-path-by-construction, so two
# project groups whose container happens to get the same `[branchName]`
# (e.g. two `.aimi/`-sharing project_roots in a multi-repo layout) never
# collide on the same key, even though WORKTREE_DIR is recomputed fresh in
# every invocation from that call's own CWD (git rev-parse --show-toplevel).
_dev_server_key() {
  local worktree_name="$1"
  realpath -m "$WORKTREE_DIR/$worktree_name"
}

# Print the entry (compact JSON) for a dev-server.json key on stdout, or
# nothing if absent.
_dev_server_get_entry() {
  local state_file="$1" key="$2"
  _dev_server_read_all "$state_file" | jq -c --arg key "$key" '.[$key] // empty'
  return 0
}

# Atomic (mktemp-then-move, flock-protected) upsert of one key's entry.
_dev_server_write_entry() {
  local state_file="$1" key="$2" entry_json="$3"
  mkdir -p "$(dirname "$state_file")"
  local lock_file="${state_file}.lock"
  (
    _lock "$lock_file"
    local current updated tmp_file
    current=$(_dev_server_read_all "$state_file")
    updated=$(printf '%s' "$current" | jq --arg key "$key" --argjson entry "$entry_json" '.[$key] = $entry')
    tmp_file=$(mktemp "${state_file}.XXXXXX")
    printf '%s\n' "$updated" > "$tmp_file"
    mv "$tmp_file" "$state_file"
  ) 200>"$lock_file"
  return 0
}

# Atomic (mktemp-then-move, flock-protected) removal of one key's entry.
# A no-op (not an error) when the state file doesn't exist yet.
_dev_server_remove_entry() {
  local state_file="$1" key="$2"
  [[ -f "$state_file" ]] || return 0
  local lock_file="${state_file}.lock"
  (
    _lock "$lock_file"
    local current updated tmp_file
    current=$(_dev_server_read_all "$state_file")
    updated=$(printf '%s' "$current" | jq --arg key "$key" 'del(.[$key])')
    tmp_file=$(mktemp "${state_file}.XXXXXX")
    printf '%s\n' "$updated" > "$tmp_file"
    mv "$tmp_file" "$state_file"
  ) 200>"$lock_file"
  return 0
}

# Classify a package.json scripts.dev string by substring match, so
# serve_start can pick the host-restricting flag the actual dev command
# needs instead of trying the same PORT/HOST env pair for every framework.
_classify_dev_command() {
  local script="$1"
  case "$script" in
    *"next dev"*) printf 'next-dev' ;;
    *"astro dev"*) printf 'astro-dev' ;;
    *"nuxt dev"*) printf 'nuxt-dev' ;;
    *"vite"*) printf 'vite' ;;
    *"react-scripts"*) printf 'react-scripts' ;;
    *) printf 'unrecognized' ;;
  esac
}

# Start (or reuse) a loopback dev server for a container worktree.
serve_start() {
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}" >&2
    echo "Usage: worktree-manager.sh serve start <worktree-name>" >&2
    exit 1
  fi

  validate_branch_name "$worktree_name"

  local worktree_path="$WORKTREE_DIR/$worktree_name"
  local dev_server_key
  dev_server_key=$(_dev_server_key "$worktree_name")

  # Path containment check — prevent directory traversal
  local resolved_path
  resolved_path=$(realpath -m "$worktree_path")
  local resolved_dir
  resolved_dir=$(realpath -m "$WORKTREE_DIR")
  if [[ ! "$resolved_path" == "$resolved_dir"/* ]]; then
    # Argument-validation failure, not a runtime degradation: the caller
    # passed a structurally invalid or malicious name. Same category as a
    # missing argument (see validate_branch_name above), and the same exit
    # code install_deps already uses for the identical check.
    echo -e "${RED}Error: Worktree path escapes expected directory${NC}" >&2
    exit 1
  fi

  if [[ ! -d "$worktree_path" ]]; then
    # Also a caller bug, not a degradation: a worktree that was supposed to
    # exist doesn't. Mirrors install_deps' exit 1 for the same condition —
    # distinct from "no package.json"/"no dev script" below, which are
    # legitimate skips for a real, existing worktree.
    echo -e "${RED}Error: Worktree directory not found: $worktree_name${NC}" >&2
    exit 1
  fi

  if [[ ! -f "$worktree_path/package.json" ]]; then
    echo -e "${YELLOW}ℹ️  No package.json in worktree, no dev server applies: $worktree_name${NC}" >&2
    return 0
  fi

  local dev_script
  dev_script=$(jq -r '.scripts.dev // empty' "$worktree_path/package.json" 2>/dev/null || echo "")
  if [[ -z "$dev_script" ]]; then
    echo -e "${YELLOW}ℹ️  No 'dev' script in package.json, no dev server applies: $worktree_name${NC}" >&2
    return 0
  fi

  # Pick the loopback-binding flag the detected dev command actually needs.
  # HOST=127.0.0.1 (set unconditionally in _launch_dev_server) only satisfies
  # CRA/webpack-dev-server; every other framework here needs its own flag, or
  # (react-scripts / unrecognized) is left to the env var alone.
  local dev_framework
  dev_framework=$(_classify_dev_command "$dev_script")

  local -a host_flag_args=()
  case "$dev_framework" in
    next-dev) host_flag_args=(-H 127.0.0.1) ;;
    vite|astro-dev|nuxt-dev) host_flag_args=(--host 127.0.0.1) ;;
    *) host_flag_args=() ;;
  esac

  local aimi_root
  if ! aimi_root=$(find_aimi_root); then
    echo -e "${RED}Error: Could not locate a .aimi/ directory searching upward from $(pwd)${NC}" >&2
    return 0
  fi

  local state_file="$aimi_root/.aimi/state/dev-server.json"

  # log_file's path only depends on dev_server_key, so it's resolved here —
  # before the reuse check below — rather than after it, alongside pid_file.
  # touch + chmod unconditionally on every call (reuse or fresh start) so the
  # log never inherits the process umask and any permission drift on an
  # existing file self-heals on the next serve_start.
  mkdir -p "$aimi_root/.aimi/state"
  local safe_name="${dev_server_key//\//_}"
  local log_file="$aimi_root/.aimi/state/.dev-server-${safe_name}.log"
  touch "$log_file" && chmod 600 "$log_file"

  # Reuse a registered entry only when it survives BOTH gates: identity
  # (pid alive AND its identity token matches what was recorded at start —
  # see dev_server_entry_is_ours) and, only once identity passes, a fresh
  # port-ownership re-check (the registered port may have been taken over by
  # something else in the interval since the last write). Any other case —
  # dead pid, mismatched/missing identity, or a port no longer held by that
  # pid's process group — is discarded exactly like an absent entry, and
  # falls through to the fresh-start flow below.
  local existing_entry
  existing_entry=$(_dev_server_get_entry "$state_file" "$dev_server_key")
  if [[ -n "$existing_entry" ]]; then
    local existing_pid existing_port existing_identity
    existing_pid=$(printf '%s' "$existing_entry" | jq -r '.pid // empty')
    existing_port=$(printf '%s' "$existing_entry" | jq -r '.port // empty')
    existing_identity=$(printf '%s' "$existing_entry" | jq -r '.identity // empty')

    local reused=false
    if [[ -n "$existing_pid" ]] && dev_server_entry_is_ours "$existing_pid" "$existing_identity"; then
      # Identity match alone isn't enough to reuse: re-resolve who currently
      # holds the registered port's LISTEN socket and require its pgid to
      # match the recorded pid, mirroring the fresh-start ownership check
      # further below (listener pid -> pgid == leader pid).
      local reuse_listener_pid reuse_listener_pgid
      reuse_listener_pid=$(_port_listener_pid "$existing_port")
      reuse_listener_pgid=""
      [[ -n "$reuse_listener_pid" ]] && reuse_listener_pgid=$(ps -o pgid= -p "$reuse_listener_pid" 2>/dev/null | tr -d ' ')
      if [[ -n "$reuse_listener_pgid" ]] && [[ "$reuse_listener_pgid" == "$existing_pid" ]]; then
        reused=true
      else
        echo -e "${YELLOW}⚠️  Registered dev server for '$worktree_name' (pid $existing_pid) no longer holds port ${existing_port}; discarding the stale entry and starting fresh${NC}" >&2
      fi
    elif [[ -n "$existing_pid" ]] && _is_pid_alive "$existing_pid"; then
      echo -e "${YELLOW}⚠️  pid $existing_pid registered for '$worktree_name' is alive but its identity is missing or does not match this tool's record (likely a recycled pid); treating the entry as dead and starting fresh${NC}" >&2
    fi

    if [[ "$reused" == true ]]; then
      # Cap the log on reuse: a server kept alive across phase-mode waves
      # otherwise keeps the same log file growing for the life of the
      # container. Truncate to the final half in place (reopen the existing
      # path with `>`, never delete-then-recreate) so a still-writing dev
      # server's own fd offset isn't left pointing at an unlinked inode.
      if [[ -f "$log_file" ]]; then
        local log_size
        log_size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ')
        if [[ -n "$log_size" ]] && [[ "$log_size" -gt "$DEV_SERVER_LOG_MAX_BYTES" ]]; then
          local log_tail
          log_tail=$(tail -c "$((DEV_SERVER_LOG_MAX_BYTES / 2))" "$log_file")
          printf '%s\n' "$log_tail" > "$log_file"
          chmod 600 "$log_file"
        fi
      fi
      echo -e "${GREEN}✓ Dev server already running for '$worktree_name' at http://127.0.0.1:${existing_port} (pid $existing_pid)${NC}" >&2
      echo "http://127.0.0.1:${existing_port}"
      return 0
    fi

    _dev_server_remove_entry "$state_file" "$dev_server_key"
  fi

  # Package manager name comes from the shared detector (see install_deps
  # above); only the run-dev command array is specific to serve_start.
  local pm_name
  local -a pm_cmd
  pm_name=$(_detect_package_manager "$worktree_path")
  case "$pm_name" in
    bun) pm_cmd=(bun run dev) ;;
    pnpm) pm_cmd=(pnpm run dev) ;;
    yarn) pm_cmd=(yarn run dev) ;;
    npm) pm_cmd=(npm run dev) ;;
  esac

  local port
  if ! port=$(_pick_free_port); then
    echo -e "${RED}Error: No free 127.0.0.1 port found for dev server (scanned $DEV_SERVER_BASE_PORT-$((DEV_SERVER_BASE_PORT + DEV_SERVER_PORT_SCAN_LIMIT)))${NC}" >&2
    return 0
  fi

  # Real mktemp (no -u): creates the file atomically, so _launch_dev_server's
  # in-place truncation of it never has to recreate a deleted path — see the
  # symlink-race note on _launch_dev_server above.
  local pid_file
  pid_file=$(mktemp "$aimi_root/.aimi/state/.dev-server-pid-${safe_name}.XXXXXX")

  # Build each attempt's `-- <extra args>` passthrough: the framework-specific
  # host flag is added to BOTH attempts, alongside — never instead of — the
  # PORT/HOST env vars _launch_dev_server already sets unconditionally.
  local -a attempt1_extra=("${host_flag_args[@]}")
  local -a attempt2_extra=(--port "$port" "${host_flag_args[@]}")

  echo -e "${BLUE}Starting dev server for '$worktree_name' with $pm_name on port $port (attempt 1: PORT env var, dev command: $dev_framework)...${NC}" >&2

  local leader_pid=""
  if [[ ${#attempt1_extra[@]} -gt 0 ]]; then
    leader_pid=$(cd "$worktree_path" && _launch_dev_server "$port" "$log_file" "$pid_file" "${pm_cmd[@]}" -- "${attempt1_extra[@]}")
  else
    leader_pid=$(cd "$worktree_path" && _launch_dev_server "$port" "$log_file" "$pid_file" "${pm_cmd[@]}")
  fi

  # Capture _wait_ready's distinguishing return code (0 ready, 1 nothing ever
  # listened, 2 listened but never answered HTTP) via an if-condition so a
  # non-zero return never trips the script's top-level `set -e`.
  local ready=false
  local wait_rc=1
  if [[ -n "$leader_pid" ]]; then
    if _wait_ready "$port" "$DEV_SERVER_READY_TIMEOUT"; then
      wait_rc=0
    else
      wait_rc=$?
    fi
  fi

  if [[ "$wait_rc" -eq 0 ]]; then
    ready=true
  elif [[ "$wait_rc" -eq 2 ]]; then
    # Something was already listening on $port but never answered HTTP
    # within the budget — killing a process mid-compile and discarding the
    # cache it had warmed, only to repeat the identical PORT-env attempt a
    # second time for the same reason (slow, not a wrong port/flag), would
    # never help. Report the cause and don't retry.
    _kill_process_group "$leader_pid"
    rm -f "$pid_file"
    echo -e "${RED}Error: Dev server for '$worktree_name' occupied port $port but never answered HTTP within ${DEV_SERVER_READY_TIMEOUT}s; not retrying a second attempt for the same reason. See log: $log_file${NC}" >&2
    return 0
  else
    [[ -n "$leader_pid" ]] && _kill_process_group "$leader_pid"
    # No intermediate pid_file deletion here: _launch_dev_server truncates it
    # in place at the start of every call, so a delete before the next call
    # would be redundant with that truncation (see _launch_dev_server above).

    echo -e "${BLUE}PORT env var attempt did not answer on port $port; retrying with -- --port ${port} (attempt 2)...${NC}" >&2
    leader_pid=$(cd "$worktree_path" && _launch_dev_server "$port" "$log_file" "$pid_file" "${pm_cmd[@]}" -- "${attempt2_extra[@]}")

    if [[ -n "$leader_pid" ]] && _wait_ready "$port" "$DEV_SERVER_READY_TIMEOUT"; then
      ready=true
    fi
  fi

  rm -f "$pid_file"

  if [[ "$ready" != true ]]; then
    [[ -n "$leader_pid" ]] && _kill_process_group "$leader_pid"
    echo -e "${RED}Error: Dev server for '$worktree_name' never answered on http://127.0.0.1:${port} after trying both the PORT env var and -- --port ${port}. See log: $log_file${NC}" >&2
    return 0
  fi

  # Ownership check: the listening socket must belong to the process group we
  # just spawned, not a stale or unrelated foreign process on that port.
  local listener_pid
  listener_pid=$(_port_listener_pid "$port")
  if [[ -z "$listener_pid" ]]; then
    echo -e "${RED}Error: Dev server for '$worktree_name' answered on port $port but its listener pid could not be resolved for the ownership check (no ss/lsof?); not adopting it${NC}" >&2
    _kill_process_group "$leader_pid"
    return 0
  fi

  local listener_pgid
  listener_pgid=$(ps -o pgid= -p "$listener_pid" 2>/dev/null | tr -d ' ')
  if [[ "$listener_pgid" != "$leader_pid" ]]; then
    echo -e "${RED}Error: Port $port is already held by an unrelated process (pid $listener_pid, pgid $listener_pgid) — not adopting it as the dev server for '$worktree_name'${NC}" >&2
    _kill_process_group "$leader_pid"
    return 0
  fi

  # Capture the identity token now that ownership is confirmed, so a later
  # stop or start has proof this leader_pid is the exact process this run
  # spawned — not just a pid that happens to be alive (see dev_server_entry_is_ours).
  local leader_identity
  leader_identity=$(process_identity "$leader_pid")

  # Bind-address verification: an attempted host flag is not a guarantee —
  # some frameworks silently ignore an unrecognized flag or env var. The
  # readiness probe and the ownership check above both query 127.0.0.1 and
  # answer identically whether the underlying socket is loopback-only or a
  # wildcard bind (0.0.0.0 / ::), so this is the only check that can actually
  # see the difference. Refuse anything but exactly 127.0.0.1 or ::1.
  local bind_addr
  bind_addr=$(_listener_bind_addr "$listener_pid" "$port")
  if [[ "$bind_addr" != "127.0.0.1" && "$bind_addr" != "::1" ]]; then
    local framework_desc
    case "$dev_framework" in
      next-dev) framework_desc="next dev" ;;
      astro-dev) framework_desc="astro dev" ;;
      nuxt-dev) framework_desc="nuxt dev" ;;
      vite) framework_desc="vite" ;;
      react-scripts) framework_desc="react-scripts" ;;
      *) framework_desc="unrecognized dev command" ;;
    esac
    echo -e "${RED}Error: Dev server for '$worktree_name' ($framework_desc) is listening on '${bind_addr:-an address that could not be determined}', not a loopback-only address — the loopback bind could not be confirmed; not adopting it${NC}" >&2
    _kill_process_group "$leader_pid"
    return 0
  fi

  local entry
  entry=$(jq -n --argjson port "$port" --argjson pid "$leader_pid" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg identity "$leader_identity" \
    '{port: $port, pid: $pid, startedAt: $started, identity: $identity}')
  _dev_server_write_entry "$state_file" "$dev_server_key" "$entry"

  echo -e "${GREEN}✓ Dev server ready for '$worktree_name': http://127.0.0.1:${port} (pid $leader_pid)${NC}" >&2
  echo "http://127.0.0.1:${port}"
}

# Stop a container worktree's dev server, killing its whole process group.
serve_stop() {
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}" >&2
    echo "Usage: worktree-manager.sh serve stop <worktree-name>" >&2
    exit 1
  fi

  validate_branch_name "$worktree_name"

  local dev_server_key
  dev_server_key=$(_dev_server_key "$worktree_name")

  local aimi_root
  if ! aimi_root=$(find_aimi_root); then
    echo -e "${YELLOW}ℹ️  Could not locate a .aimi/ directory; nothing to stop for '$worktree_name'${NC}"
    return 0
  fi

  local state_file="$aimi_root/.aimi/state/dev-server.json"
  local entry
  entry=$(_dev_server_get_entry "$state_file" "$dev_server_key")

  if [[ -z "$entry" ]]; then
    echo -e "${YELLOW}ℹ️  No dev server registered for '$worktree_name'${NC}"
    return 0
  fi

  local pid identity
  pid=$(printf '%s' "$entry" | jq -r '.pid // empty')
  identity=$(printf '%s' "$entry" | jq -r '.identity // empty')

  if [[ -n "$pid" ]]; then
    if dev_server_entry_is_ours "$pid" "$identity"; then
      echo -e "${BLUE}Stopping dev server for '$worktree_name' (process group $pid)...${NC}"
      _kill_process_group "$pid"
    elif _is_pid_alive "$pid"; then
      echo -e "${YELLOW}⚠️  pid $pid registered for '$worktree_name' is alive but its identity is missing or does not match the dev server this tool started (likely a recycled pid); not sending it any signal${NC}" >&2
    fi
  fi

  # Remove the state entry regardless of outcome — whether the kill fully
  # succeeded, or was skipped entirely because the identity gate above
  # failed (a live-but-foreign pid must never be treated as this tool's
  # dev server, so it is dropped from state without ever being signaled).
  _dev_server_remove_entry "$state_file" "$dev_server_key"
  echo -e "${GREEN}✓ Dev server stopped and state cleared for '$worktree_name'${NC}"
}

# Report a container worktree's dev server status: a true read-only verb.
# Contract (consumed by US-007/US-013 via jq): prints EXACTLY one line of
# JSON with keys running (boolean), port (number|null), pid (number|null);
# exit 0 in EVERY state case — no .aimi/ locatable, no entry registered, a
# dead pid, a live pid with a complete entry, and a live pid with a
# partial/corrupt entry (e.g. missing port). No other stdout output is
# permitted in this function. The one exception is a missing or invalid
# worktree-name argument: a usage error (see validate_branch_name) — stderr
# message, non-zero exit, no stdout line at all.
# Never writes state, unlike before: a dead-pid entry is reported as
# running:false without removing it. Cleanup of a stale entry is exclusively
# serve_start's job (on its own reuse path) and serve_stop's — never a read
# verb's — so a concurrent status call can never race a start writing the
# same key.
serve_status() {
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}" >&2
    echo "Usage: worktree-manager.sh serve status <worktree-name>" >&2
    exit 1
  fi

  validate_branch_name "$worktree_name"

  local dev_server_key
  dev_server_key=$(_dev_server_key "$worktree_name")

  local aimi_root
  if ! aimi_root=$(find_aimi_root); then
    jq -n -c '{running: false, port: null, pid: null}'
    return 0
  fi

  local state_file="$aimi_root/.aimi/state/dev-server.json"

  # Single jq call reading pid and port together, bound to the resolved
  # dev_server_key (never the raw worktree name — see _dev_server_key).
  # Reads through _dev_server_read_all, which guards file existence and JSON
  # validity and emits `{}` otherwise. Calling jq directly on $state_file was
  # a defect: `2>/dev/null` hides stderr but NOT jq's non-zero exit, so under
  # `set -e` a missing file killed the script before this function could reach
  # its own not-running fallback -- violating the exit-0-always contract. Comma-separated, not space-separated:
  # `read` with a space/tab IFS collapses an empty leading field (e.g. a
  # corrupt entry with no port) into the wrong variable — verified that
  # `read -r a b <<<" 4100"` yields a=4100, b empty, when pid should be
  # empty and port 4100.
  local line pid port
  line=$(_dev_server_read_all "$state_file" | jq -r --arg key "$dev_server_key" \
    'if type == "object" then (.[$key] // {}) else {} end | "\(.pid // ""),\(.port // "")"' \
    2>/dev/null)
  IFS=',' read -r pid port <<<"$line"

  if [[ -n "$pid" ]] && _is_pid_alive "$pid"; then
    # --arg + tonumber?, never --argjson: --argjson requires a valid JSON
    # literal, so an empty or non-numeric port/pid string would abort jq
    # with exit 2 and no stdout at all — exactly the contract violation this
    # rewrite fixes. tonumber? // null degrades a missing/non-numeric field
    # to JSON null instead of crashing.
    jq -n -c --arg port "$port" --arg pid "$pid" \
      '{running: true, port: ($port | tonumber? // null), pid: ($pid | tonumber? // null)}'
  else
    jq -n -c '{running: false, port: null, pid: null}'
  fi
}

# Rewrite <raw-url>'s origin to point at <worktree-name>'s running dev server,
# preserving path and query — the single place the origin-rewrite one-liner
# used to be inlined at every execute.md/next.md call site lives now. Reuses
# serve_status internally (never re-implements the pid/port read) and shares
# its never-fails contract: prints EXACTLY one line of compact JSON
# {"url":<string>,"rewritten":<bool>} and exits 0 in every case. When no
# server is running (or serve_status reports a dead/absent entry), <raw-url>
# is echoed back unchanged with rewritten:false — the same advisory
# degradation every other serve verb uses. The only usage error is a missing
# worktree-name argument (see validate_branch_name), matching start/stop/status.
serve_url() {
  local worktree_name="$1" raw_url="$2"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}" >&2
    echo "Usage: worktree-manager.sh serve url <worktree-name> <raw-url>" >&2
    exit 1
  fi

  validate_branch_name "$worktree_name"

  local status_json running port
  status_json=$(serve_status "$worktree_name")
  running=$(printf '%s' "$status_json" | jq -r '.running')
  port=$(printf '%s' "$status_json" | jq -r '.port // empty')

  if [[ "$running" == "true" ]] && [[ -n "$port" ]]; then
    local path_query
    path_query=$(printf '%s' "$raw_url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+##')
    jq -n -c --arg url "http://127.0.0.1:${port}${path_query}" '{url: $url, rewritten: true}'
  else
    jq -n -c --arg url "$raw_url" '{url: $url, rewritten: false}'
  fi
}

# Dispatch serve start|stop|status|url <worktree-name> [<raw-url>]
serve_dispatch() {
  local subcmd="$1"
  shift || true
  case "$subcmd" in
    start)
      serve_start "$1"
      ;;
    stop)
      serve_stop "$1"
      ;;
    status)
      serve_status "$1"
      ;;
    url)
      serve_url "$1" "$2"
      ;;
    *)
      echo -e "${RED}Error: Unknown serve subcommand: ${subcmd:-<none>}${NC}" >&2
      echo "Usage: worktree-manager.sh serve start|stop|status|url <worktree-name> [<raw-url>]" >&2
      exit 1
      ;;
  esac
}

# Main command handler
main() {
  local command="${1:-list}"

  case "$command" in
    create)
      shift
      create_worktree "$@"
      ;;
    list|ls)
      list_worktrees
      ;;
    switch|go)
      switch_worktree "$2"
      ;;
    remove|rm)
      shift
      remove_worktree "$@"
      ;;
    copy-env|env)
      copy_env_to_worktree "$2"
      ;;
    merge)
      shift
      merge_worktree "$@"
      ;;
    merge-all)
      shift
      merge_all_worktrees "$@"
      ;;
    cleanup|clean)
      cleanup_worktrees
      ;;
    install-deps)
      install_deps "$2"
      ;;
    serve)
      shift
      serve_dispatch "$@"
      ;;
    help)
      show_help
      ;;
    *)
      echo -e "${RED}Unknown command: $command${NC}"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

show_help() {
  cat << EOF
Git Worktree Manager

Usage: worktree-manager.sh <command> [options]

Commands:
  create <branch-name> [--from <branch>]  Create new worktree (copies .env files automatically)
                                          (from-branch defaults to main)
  remove | rm <name> [--keep-branch]  Remove a specific worktree and its branch
                                      (--keep-branch skips branch deletion, default off)
  list | ls                           List all worktrees
  switch | go <name>                  Switch to worktree
  copy-env | env [name]               Copy .env files from main repo to worktree
                                      (if name omitted, uses current worktree)
  merge <worktree-name> [--into <b>]  Merge worktree branch into target branch
                                      (defaults --into to current branch)
  merge-all <b1> <b2> ... [--into <b>]  Merge multiple branches sequentially
                                         (stops on first conflict)
  cleanup | clean                     Clean up inactive worktrees
  install-deps <worktree-name>        Install dependencies inside a worktree
                                      (detects package manager by lockfile)
  serve start <worktree-name>         Start a dev server for a worktree, verify its
                                      listener is actually loopback-only, print its
                                      raw URL to stdout only — pid and all narration
                                      go to stderr (refuses and kills a wildcard bind)
  serve stop <worktree-name>          Stop a worktree's dev server (kills the
                                      whole process group)
  serve status <worktree-name>        Report a worktree's dev server status as
                                      single-line JSON: {"running":bool,"port":n|null,"pid":n|null}
  serve url <name> <raw-url>          Rewrite <raw-url>'s origin to the worktree's
                                      running dev server (path/query preserved);
                                      prints {"url":string,"rewritten":bool}, exit 0 always
  help                                Show this help message

Environment Files:
  - Automatically copies .env, .env.local, .env.test, etc. on create
  - Skips .env.example (should be in git)
  - Creates .backup files if destination already exists
  - Use 'copy-env' to refresh env files after main repo changes

Merge:
  - merge resolves the worktree's branch name automatically
  - On success: prints the merge commit hash
  - On conflict: prints conflicting files and exits with code 1
  - merge-all stops on first conflict and reports which branch failed

Install Deps:
  - Detection order (first lockfile match wins): bun.lockb -> bun install;
    pnpm-lock.yaml -> pnpm install; yarn.lock -> yarn install;
    package-lock.json -> npm ci (falls back to npm install on failure);
    no recognized lockfile but package.json present -> npm install
  - Idempotency short-circuit: when a recognized lockfile exists and
    node_modules/ is already at least as fresh as it (mtime comparison),
    the install is skipped entirely and this exits 0 with an informational
    line — a resumed container that already had correct dependencies never
    pays a cold reinstall. Does not apply when there's no recognized
    lockfile, or node_modules/ doesn't exist yet, or the lockfile is newer
  - No package.json: prints an informational line and exits 0 (not an error)
  - Install failure: prints a clear error naming the package manager and
    worktree, and exits non-zero
  - Advisory/non-fatal contract for callers: a non-zero exit here must be
    treated as a degradation, not a fatal error. Callers such as the
    container mode of /aimi:execute should fall visual verification back to
    skipped/failed and never abort the wave loop because install-deps failed

Serve (Dev Server):
  - Attempt-then-verify loopback bind: serve start reads scripts.dev from the
    worktree's package.json and picks the host flag the detected command
    actually needs (-H 127.0.0.1 for next dev; --host 127.0.0.1 for vite,
    astro dev, nuxt dev; the PORT/HOST env pair alone for react-scripts or an
    unrecognized command) — but an attempted flag is never trusted blindly.
    Once the readiness probe succeeds, serve start resolves the listening
    socket's actual local address (via ss, falling back to lsof) and refuses
    to adopt anything but exactly 127.0.0.1 or ::1: it kills the process
    group, prints an error naming the detected (or 'unrecognized') command
    and the actual address found, and writes no state entry. This is what
    turns the flag from a best-effort attempt into a guarantee
  - Port injection, tried in order: (1) PORT env var (Next.js, CRA, Nuxt,
    Remix); (2) if the readiness probe finds nothing ever listening on the
    port, kill that attempt and retry once with '-- --port <n>' appended
    (Vite, Astro). Both attempts also pass the framework-specific host flag
    above, when one applies. If neither yields a listener, serve start
    reports the failure and exits 0. Attempt 2 is skipped — not retried —
    when attempt 1's port was occupied but never answered HTTP (see
    Readiness probe below); killing a mid-compile process to repeat the
    identical PORT-env attempt for the same reason (slow, not a wrong
    port/flag) would never help, so that case reports its cause directly
  - Readiness probe (_wait_ready): polls http://127.0.0.1:<port> with a
    real wall-clock budget (DEV_SERVER_READY_TIMEOUT, default 90s,
    env-overridable) rather than an iteration count, so a slow per-probe
    --max-time (DEV_SERVER_PROBE_MAX_TIME, default 5s, env-overridable)
    can never make the actual wait exceed the declared timeout. A process
    merely starting is never enough — only an observed HTTP response counts
    as ready. On timeout it distinguishes "nothing ever listened" from
    "something listened but never answered HTTP", which is what lets
    attempt 2 above be skipped when retrying would be pointless
  - Ownership check: before adopting the port's listener as this worktree's
    dev server, serve start confirms the listening pid's process group
    matches the process it just spawned, so a stale or foreign process on
    that port is never mistaken for the dev server. This runs before, and is
    unaffected by, the bind-address verification above
  - State: .aimi/state/dev-server.json, keyed by the container's absolute
    resolved path (realpath -m of the worktree directory, not by worktree/
    branch name — so two project groups whose container shares the same
    `[branchName]` never collide on the same entry), each entry holding
    port, pid (the process-group leader pid), startedAt, and identity (the
    pid's process-identity token at start — /proc/pid/stat starttime, or
    `ps -o lstart=` as a portable fallback). Written exclusively via a
    Bash-level atomic (mktemp-then-move, flock-protected) write inside this
    script — never via the Write/Edit tool, which guard-runtime-state.py
    blocks unconditionally for this path
  - Liveness is not identity: pids get recycled by the OS, so a kill -0
    check alone cannot tell "the process we started" apart from "whatever
    unrelated process now holds that pid". serve start's reuse path and
    serve stop's kill both gate on dev_server_entry_is_ours instead, which
    additionally requires the entry's recorded identity token to match the
    pid's identity right now; a live pid with a missing (pre-upgrade entry)
    or mismatched identity is treated exactly like a dead one — never
    reused, never signaled
  - serve start reuses an entry only once it passes that identity gate AND
    a fresh port-ownership re-check (the port's current LISTEN-socket owner
    must still resolve to the recorded pid's process group) — a foreign
    process on the recorded pid, or one that has since taken over the port,
    is discarded exactly like a dead entry, and a fresh server is spawned
  - serve stop kills the recorded process group (negative-pid kill against
    the setsid-launched leader), not just the single pid, so forked children
    (a next-server worker, a vite worker) don't survive — but only once the
    same identity gate passes; when it fails but the pid is still alive, a
    warning is printed and no signal is sent. The state entry is removed in
    every case: kill succeeded, kill failed, or kill was never attempted
  - serve status prints EXACTLY one line of JSON to stdout:
    {"running":<bool>,"port":<number|null>,"pid":<number|null>}, exit 0 in
    EVERY state case — no .aimi/ locatable, no entry registered, a dead pid,
    a live pid with a complete entry, or a live pid with a partial/corrupt
    entry (e.g. missing port). This exact shape is a contract consumed by
    other tooling via jq — do not add or rename keys. status is a true
    read-only verb: unlike before, it never removes a stale (dead-pid) entry
    as a side effect — that cleanup is exclusively serve start's (its own
    reuse path) and serve stop's job, never a read verb's, so a concurrent
    status call can never race a start writing the same key
  - serve start's stdout, on both the reuse path and a successful fresh
    launch, is exactly the raw URL http://127.0.0.1:<port> as its only line
    — pid and all decorated progress narration (attempt 1/2, the reuse
    confirmation, the final readiness message) go to stderr instead, so
    scripted callers can capture stdout directly without parsing it out of
    human-readable text
  - serve url <name> <raw-url> rewrites <raw-url>'s origin to point at the
    worktree's currently running dev server, preserving path and query —
    the single implementation of the origin-rewrite every visual-verification
    call site in execute.md/next.md used to inline as its own sed one-liner.
    It reuses serve status internally (never re-implements the pid/port
    read) and shares its never-fails contract: EXACTLY one line of compact
    JSON {"url":<string>,"rewritten":<bool>} on stdout, exit 0 in every
    state case. When no server is running (or the registered entry is dead),
    <raw-url> is echoed back unchanged with rewritten:false — never an error
  - No package.json, or no "dev" script: clean skip — exits 0, writes no
    state, and is never reported as an error
  - Every failure mode (port exhaustion, readiness timeout, ownership
    mismatch, a confirmed non-loopback bind, no package.json, no dev script,
    kill failure, no server running for a url rewrite) degrades gracefully:
    serve start/stop/status/url never exit non-zero for these conditions. A
    missing or invalid worktree-name argument (see validate_branch_name) is
    a usage error in all four verbs — non-zero exit, stderr message, no
    stdout line at all. serve start adds two more usage errors in the same
    category, because both mean the caller passed a name that never
    corresponded to a real worktree, not a runtime degradation: a worktree
    directory that doesn't exist, and a resolved path that escapes
    .worktrees/ (the same containment check and exit code install-deps
    already uses for both)

Examples:
  worktree-manager.sh create feature-login
  worktree-manager.sh create feature-auth --from develop
  worktree-manager.sh switch feature-login
  worktree-manager.sh remove feature-login              # removes worktree and branch
  worktree-manager.sh remove feature-login --keep-branch  # removes worktree, keeps branch
  worktree-manager.sh copy-env feature-login
  worktree-manager.sh copy-env                   # copies to current worktree
  worktree-manager.sh merge feature-login        # merge into current branch
  worktree-manager.sh merge feature-login --into main
  worktree-manager.sh merge-all feat-a feat-b --into develop
  worktree-manager.sh cleanup
  worktree-manager.sh install-deps feature-login
  worktree-manager.sh serve start feature-login
  worktree-manager.sh serve status feature-login
  worktree-manager.sh serve url feature-login "https://example.com/dashboard?tab=1"
  worktree-manager.sh serve stop feature-login
  worktree-manager.sh list

EOF
}

# Run
main "$@"
