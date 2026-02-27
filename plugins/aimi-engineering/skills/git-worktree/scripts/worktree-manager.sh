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

# Get repo root
GIT_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_DIR="$GIT_ROOT/.worktrees"

# Ensure .worktrees is in .gitignore
ensure_gitignore() {
  if ! grep -q "^\.worktrees$" "$GIT_ROOT/.gitignore" 2>/dev/null; then
    echo ".worktrees" >> "$GIT_ROOT/.gitignore"
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
    echo -e "  ${GREEN}✓ Copied $env_file${NC}"
    copied=$((copied + 1))
  done

  echo -e "  ${GREEN}✓ Copied $copied environment file(s)${NC}"
}

# Create a new worktree
create_worktree() {
  local branch_name="$1"
  local from_branch="${2:-main}"

  if [[ -z "$branch_name" ]]; then
    echo -e "${RED}Error: Branch name required${NC}"
    exit 1
  fi

  local worktree_path="$WORKTREE_DIR/$branch_name"

  # Check if worktree already exists — reuse silently (non-interactive)
  if [[ -d "$worktree_path" ]]; then
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

  echo -e "${BLUE}Creating worktree...${NC}"
  git worktree add -b "$branch_name" "$worktree_path" "$from_branch"

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
  local worktree_name="$1"

  if [[ -z "$worktree_name" ]]; then
    echo -e "${RED}Error: Worktree name required${NC}"
    echo "Usage: worktree-manager.sh remove <worktree-name>"
    exit 1
  fi

  local worktree_path="$WORKTREE_DIR/$worktree_name"

  if [[ -d "$worktree_path" ]]; then
    git worktree remove "$worktree_path" --force 2>/dev/null || true
    echo -e "${GREEN}✓ Removed worktree: $worktree_name${NC}"
  else
    echo -e "${YELLOW}Worktree directory not found: $worktree_name (may already be removed)${NC}"
    # Still try to clean up git worktree tracking
    git worktree prune 2>/dev/null || true
  fi

  # Clean up the associated branch
  git branch -D "$worktree_name" 2>/dev/null || true

  # Remove empty .worktrees directory
  if [[ -d "$WORKTREE_DIR" ]] && [[ -z "$(ls -A "$WORKTREE_DIR" 2>/dev/null)" ]]; then
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
  fi
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

  echo -e "${BLUE}Merging branch '$worktree_branch' into '$target_branch'...${NC}"

  # Checkout the target branch
  git checkout "$target_branch" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: Failed to checkout target branch: $target_branch${NC}"
    exit 1
  fi

  # Attempt the merge
  if git merge "$worktree_branch" 2>/dev/null; then
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
    git checkout "$target_branch" 2>/dev/null
    if [[ $? -ne 0 ]]; then
      echo -e "${RED}Error: Failed to checkout target branch: $target_branch${NC}"
      exit 1
    fi

    # Attempt merge
    if git merge "$resolved_branch" 2>/dev/null; then
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

# Main command handler
main() {
  local command="${1:-list}"

  case "$command" in
    create)
      create_worktree "$2" "$3"
      ;;
    list|ls)
      list_worktrees
      ;;
    switch|go)
      switch_worktree "$2"
      ;;
    remove|rm)
      remove_worktree "$2"
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
  create <branch-name> [from-branch]  Create new worktree (copies .env files automatically)
                                      (from-branch defaults to main)
  remove | rm <worktree-name>         Remove a specific worktree and its branch
  list | ls                           List all worktrees
  switch | go <name>                  Switch to worktree
  copy-env | env [name]               Copy .env files from main repo to worktree
                                      (if name omitted, uses current worktree)
  merge <worktree-name> [--into <b>]  Merge worktree branch into target branch
                                      (defaults --into to current branch)
  merge-all <b1> <b2> ... [--into <b>]  Merge multiple branches sequentially
                                         (stops on first conflict)
  cleanup | clean                     Clean up inactive worktrees
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

Examples:
  worktree-manager.sh create feature-login
  worktree-manager.sh create feature-auth develop
  worktree-manager.sh switch feature-login
  worktree-manager.sh copy-env feature-login
  worktree-manager.sh copy-env                   # copies to current worktree
  worktree-manager.sh merge feature-login        # merge into current branch
  worktree-manager.sh merge feature-login --into main
  worktree-manager.sh merge-all feat-a feat-b --into develop
  worktree-manager.sh cleanup
  worktree-manager.sh list

EOF
}

# Run
main "$@"
