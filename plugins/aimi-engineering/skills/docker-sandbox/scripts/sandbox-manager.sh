#!/usr/bin/env bash

# =============================================================================
# sandbox-manager.sh — Docker container lifecycle for Aimi sandbox workers
# =============================================================================
# Manages creating, monitoring, and cleaning up Docker containers that run
# autonomous agent workers inside Sysbox-isolated sandboxes.
#
# Follows worktree-manager.sh patterns: idempotent operations, validation
# functions, colored output, error handling, case statement structure.
#
# Usage:
#   sandbox-manager.sh <command> [options]
#
# Commands:
#   create <name> --image <image> [--task-file <path>] [--branch <branch>]
#   remove <name>
#   list
#   status <name>
#   cleanup
#   check-runtime
#   help
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Configurable resource limits (env vars with defaults)
# ---------------------------------------------------------------------------
AIMI_SANDBOX_CPUS="${AIMI_SANDBOX_CPUS:-2}"
AIMI_SANDBOX_MEMORY="${AIMI_SANDBOX_MEMORY:-4g}"
AIMI_SANDBOX_SWAP="${AIMI_SANDBOX_SWAP:-4g}"
AIMI_SANDBOX_DISK="${AIMI_SANDBOX_DISK:-8g}"

# Container name prefix
readonly AIMI_PREFIX="aimi-"
# Label used to tag aimi-managed containers
readonly AIMI_LABEL="org.aimi.sandbox"
# Label for task file association
readonly AIMI_TASK_LABEL="org.aimi.task-file"
# Sysbox runtime name
readonly SYSBOX_RUNTIME="sysbox-runc"
# Sysbox install URL
readonly SYSBOX_INSTALL_URL="https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-package.md"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  echo -e "${BLUE}[aimi-sandbox]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[aimi-sandbox]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[aimi-sandbox]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[aimi-sandbox]${NC} ERROR: $*" >&2
}

die() {
  log_error "$@"
  exit 1
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Validate container name matches required pattern: aimi-<slug>
# Slug must start with alphanumeric, then allow alphanumeric, underscore, hyphen
validate_container_name() {
  local name="$1"
  if ! [[ "$name" =~ ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    die "Invalid container name: '${name}'. Must match ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*\$"
  fi
}

# Ensure Docker is available
require_docker() {
  if ! command -v docker &>/dev/null; then
    die "Docker is not installed or not in PATH"
  fi
  if ! docker info &>/dev/null; then
    die "Docker daemon is not running or current user lacks permissions"
  fi
}

# ---------------------------------------------------------------------------
# check-runtime: Verify Sysbox runtime is registered
# ---------------------------------------------------------------------------
cmd_check_runtime() {
  require_docker

  # Check if sysbox-runc is registered in Docker daemon
  local runtimes
  runtimes=$(docker info --format '{{json .Runtimes}}' 2>/dev/null || echo "{}")

  if echo "$runtimes" | grep -q "${SYSBOX_RUNTIME}"; then
    log_success "Sysbox runtime '${SYSBOX_RUNTIME}' is available"
    echo "{\"available\": true, \"runtime\": \"${SYSBOX_RUNTIME}\"}"
    return 0
  else
    log_error "Sysbox runtime '${SYSBOX_RUNTIME}' is NOT registered with Docker"
    echo ""
    echo -e "${RED}Sysbox is required for secure container-in-container sandboxing.${NC}"
    echo ""
    echo -e "${YELLOW}Install Sysbox:${NC}"
    echo "  ${SYSBOX_INSTALL_URL}"
    echo ""
    echo -e "${YELLOW}After installation, verify with:${NC}"
    echo "  docker info --format '{{json .Runtimes}}' | grep sysbox-runc"
    echo ""
    return 1
  fi
}

# ---------------------------------------------------------------------------
# create: Spawn a new sandbox container
# ---------------------------------------------------------------------------
cmd_create() {
  local name=""
  local image=""
  local task_file=""
  local branch=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        image="$2"
        shift 2
        ;;
      --task-file)
        task_file="$2"
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        else
          die "Unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done

  # Validate required arguments
  if [[ -z "$name" ]]; then
    die "Container name required. Usage: sandbox-manager.sh create <name> --image <image>"
  fi
  if [[ -z "$image" ]]; then
    die "Image required. Usage: sandbox-manager.sh create <name> --image <image>"
  fi

  # Ensure name has aimi- prefix
  local container_name
  if [[ "$name" == aimi-* ]]; then
    container_name="$name"
  else
    container_name="${AIMI_PREFIX}${name}"
  fi

  # Validate container name
  validate_container_name "$container_name"

  # Require Docker
  require_docker

  # Validate Sysbox runtime is available — hard-fail if absent
  if ! cmd_check_runtime &>/dev/null; then
    echo ""
    die "Sysbox runtime is required but not available. Install from: ${SYSBOX_INSTALL_URL}"
  fi

  # Collision detection: check if container already exists
  local existing_state
  existing_state=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null || echo "")

  if [[ -n "$existing_state" ]]; then
    if [[ "$existing_state" == "running" ]]; then
      die "Container '${container_name}' already exists and is running. Remove it first or use a different name."
    else
      # Container exists but is not running (exited, created, etc.) — recreate
      log_warn "Container '${container_name}' exists in state '${existing_state}'. Removing and recreating..."
      docker rm -f "$container_name" &>/dev/null || true
    fi
  fi

  # Create per-container bridge network
  local network_name="${container_name}-net"
  if ! docker network inspect "$network_name" &>/dev/null; then
    log_info "Creating bridge network: ${network_name}"
    docker network create --driver bridge "$network_name" >/dev/null
  else
    log_info "Network '${network_name}' already exists, reusing"
  fi

  # Build docker run arguments
  local -a run_args=(
    "--runtime=${SYSBOX_RUNTIME}"
    "--name" "$container_name"
    "--hostname" "$container_name"
    "--detach"
    "--cpus=${AIMI_SANDBOX_CPUS}"
    "--memory=${AIMI_SANDBOX_MEMORY}"
    "--memory-swap=${AIMI_SANDBOX_SWAP}"
    "--network" "$network_name"
    "--label" "${AIMI_LABEL}=true"
  )

  # Add task file label if provided
  if [[ -n "$task_file" ]]; then
    run_args+=("--label" "${AIMI_TASK_LABEL}=${task_file}")
  fi

  # Inject environment variables from host
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    run_args+=("--env" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  else
    log_warn "ANTHROPIC_API_KEY is not set in host environment"
  fi

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    run_args+=("--env" "GITHUB_TOKEN=${GITHUB_TOKEN}")
  else
    log_warn "GITHUB_TOKEN is not set in host environment"
  fi

  # Always set IS_SANDBOX=1
  run_args+=("--env" "IS_SANDBOX=1")

  # Add branch as env var if provided
  if [[ -n "$branch" ]]; then
    run_args+=("--env" "AIMI_BRANCH=${branch}")
  fi

  # Run the container
  log_info "Creating container: ${container_name}"
  log_info "  Image    : ${image}"
  log_info "  CPUs     : ${AIMI_SANDBOX_CPUS}"
  log_info "  Memory   : ${AIMI_SANDBOX_MEMORY}"
  log_info "  Swap     : ${AIMI_SANDBOX_SWAP}"
  log_info "  Network  : ${network_name}"
  log_info "  Runtime  : ${SYSBOX_RUNTIME}"

  local container_id
  container_id=$(docker run "${run_args[@]}" "$image" 2>&1) || {
    # Clean up network on failure
    docker network rm "$network_name" &>/dev/null || true
    die "Failed to create container: ${container_id}"
  }

  log_success "Container created successfully"

  # Output JSON result
  cat <<EOF
{
  "containerId": "${container_id}",
  "name": "${container_name}",
  "image": "${image}",
  "network": "${network_name}",
  "runtime": "${SYSBOX_RUNTIME}",
  "resources": {
    "cpus": "${AIMI_SANDBOX_CPUS}",
    "memory": "${AIMI_SANDBOX_MEMORY}",
    "swap": "${AIMI_SANDBOX_SWAP}"
  }
}
EOF
}

# ---------------------------------------------------------------------------
# remove: Stop and remove a container by name (idempotent)
# ---------------------------------------------------------------------------
cmd_remove() {
  local name="$1"

  if [[ -z "$name" ]]; then
    die "Container name required. Usage: sandbox-manager.sh remove <name>"
  fi

  # Ensure name has aimi- prefix
  local container_name
  if [[ "$name" == aimi-* ]]; then
    container_name="$name"
  else
    container_name="${AIMI_PREFIX}${name}"
  fi

  validate_container_name "$container_name"
  require_docker

  local network_name="${container_name}-net"

  # Stop and remove container (idempotent — no error if already gone)
  if docker inspect "$container_name" &>/dev/null; then
    log_info "Stopping container: ${container_name}"
    docker stop "$container_name" &>/dev/null || true
    log_info "Removing container: ${container_name}"
    docker rm -f "$container_name" &>/dev/null || true
    log_success "Container '${container_name}' removed"
  else
    log_warn "Container '${container_name}' does not exist (already removed)"
  fi

  # Remove associated network (idempotent)
  if docker network inspect "$network_name" &>/dev/null; then
    log_info "Removing network: ${network_name}"
    docker network rm "$network_name" &>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# list: Output running aimi-* containers in JSON format
# ---------------------------------------------------------------------------
cmd_list() {
  require_docker

  # Query all containers with our label
  local containers
  containers=$(docker ps -a \
    --filter "label=${AIMI_LABEL}=true" \
    --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}\t{{.Label "org.aimi.task-file"}}' \
    2>/dev/null || echo "")

  if [[ -z "$containers" ]]; then
    echo '{"containers": []}'
    return 0
  fi

  # Build JSON array
  local json_items=""
  local first=true

  while IFS=$'\t' read -r name status created task_file; do
    if [[ "$first" == true ]]; then
      first=false
    else
      json_items+=","
    fi

    # Escape any special JSON characters in fields
    status="${status//\"/\\\"}"
    created="${created//\"/\\\"}"
    task_file="${task_file//\"/\\\"}"

    json_items+="
    {
      \"name\": \"${name}\",
      \"status\": \"${status}\",
      \"created\": \"${created}\",
      \"taskFile\": \"${task_file}\"
    }"
  done <<< "$containers"

  cat <<EOF
{
  "containers": [${json_items}
  ]
}
EOF
}

# ---------------------------------------------------------------------------
# status: Query single container health and map to swarm-state enum
# ---------------------------------------------------------------------------
cmd_status() {
  local name="$1"

  if [[ -z "$name" ]]; then
    die "Container name required. Usage: sandbox-manager.sh status <name>"
  fi

  # Ensure name has aimi- prefix
  local container_name
  if [[ "$name" == aimi-* ]]; then
    container_name="$name"
  else
    container_name="${AIMI_PREFIX}${name}"
  fi

  validate_container_name "$container_name"
  require_docker

  # Check if container exists
  if ! docker inspect "$container_name" &>/dev/null; then
    cat <<EOF
{
  "name": "${container_name}",
  "exists": false,
  "swarmState": "not_found"
}
EOF
    return 0
  fi

  # Get container details
  local docker_state
  docker_state=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null)
  local exit_code
  exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$container_name" 2>/dev/null)
  local started_at
  started_at=$(docker inspect --format '{{.State.StartedAt}}' "$container_name" 2>/dev/null)
  local finished_at
  finished_at=$(docker inspect --format '{{.State.FinishedAt}}' "$container_name" 2>/dev/null)
  local image
  image=$(docker inspect --format '{{.Config.Image}}' "$container_name" 2>/dev/null)

  # Map Docker state to swarm-state enum
  # Swarm states: pending, running, completed, failed, stopped
  local swarm_state
  case "$docker_state" in
    created)
      swarm_state="pending"
      ;;
    running|restarting)
      swarm_state="running"
      ;;
    paused)
      swarm_state="stopped"
      ;;
    exited)
      if [[ "$exit_code" == "0" ]]; then
        swarm_state="completed"
      else
        swarm_state="failed"
      fi
      ;;
    dead)
      swarm_state="failed"
      ;;
    removing)
      swarm_state="stopped"
      ;;
    *)
      swarm_state="unknown"
      ;;
  esac

  cat <<EOF
{
  "name": "${container_name}",
  "exists": true,
  "dockerState": "${docker_state}",
  "swarmState": "${swarm_state}",
  "exitCode": ${exit_code},
  "image": "${image}",
  "startedAt": "${started_at}",
  "finishedAt": "${finished_at}"
}
EOF
}

# ---------------------------------------------------------------------------
# cleanup: Remove all stopped aimi-* containers and prune associated volumes
# ---------------------------------------------------------------------------
cmd_cleanup() {
  require_docker

  log_info "Cleaning up stopped Aimi sandbox containers..."

  # Find all stopped containers with our label
  local stopped
  stopped=$(docker ps -a \
    --filter "label=${AIMI_LABEL}=true" \
    --filter "status=exited" \
    --filter "status=dead" \
    --filter "status=created" \
    --format '{{.Names}}' \
    2>/dev/null || echo "")

  if [[ -z "$stopped" ]]; then
    log_success "No stopped Aimi containers to clean up"
    return 0
  fi

  local count=0
  while IFS= read -r container_name; do
    [[ -z "$container_name" ]] && continue

    local network_name="${container_name}-net"

    log_info "Removing container: ${container_name}"
    docker rm -f "$container_name" &>/dev/null || true

    # Remove associated network
    if docker network inspect "$network_name" &>/dev/null; then
      log_info "Removing network: ${network_name}"
      docker network rm "$network_name" &>/dev/null || true
    fi

    count=$((count + 1))
  done <<< "$stopped"

  # Prune dangling volumes associated with aimi containers
  log_info "Pruning dangling volumes..."
  docker volume prune -f --filter "label=${AIMI_LABEL}=true" &>/dev/null || true

  log_success "Cleanup complete: removed ${count} container(s)"
}

# ---------------------------------------------------------------------------
# help: Show usage information
# ---------------------------------------------------------------------------
show_help() {
  cat << EOF
Aimi Sandbox Manager — Docker container lifecycle for sandbox workers

Usage: sandbox-manager.sh <command> [options]

Commands:
  create <name> --image <image> [options]  Create a new sandbox container
    --task-file <path>                     Associate with a task file
    --branch <branch>                      Git branch to pass as AIMI_BRANCH env

  remove <name>                  Stop and remove a container (idempotent)
  list                           List all aimi-* containers (JSON output)
  status <name>                  Query container health (JSON output)
  cleanup                        Remove all stopped aimi-* containers
  check-runtime                  Verify Sysbox runtime is available
  help                           Show this help message

Environment Variables:
  AIMI_SANDBOX_CPUS     CPU limit (default: 2)
  AIMI_SANDBOX_MEMORY   Memory limit (default: 4g)
  AIMI_SANDBOX_SWAP     Memory+swap limit (default: 4g)
  AIMI_SANDBOX_DISK     Disk limit label (default: 8g)
  ANTHROPIC_API_KEY     Injected into container
  GITHUB_TOKEN          Injected into container

Container Naming:
  Containers are named as aimi-<slug>
  Name must match: ^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$

Networking:
  Each container gets its own bridge network: <container-name>-net
  No cross-container network access

Runtime:
  Requires Sysbox (sysbox-runc) for secure container isolation
  Install: ${SYSBOX_INSTALL_URL}

Examples:
  sandbox-manager.sh check-runtime
  sandbox-manager.sh create my-task --image aimi-sandbox:base
  sandbox-manager.sh create aimi-feat-login --image aimi-sandbox-myapp:latest --task-file .aimi/tasks/login.json
  sandbox-manager.sh status aimi-feat-login
  sandbox-manager.sh list
  sandbox-manager.sh remove aimi-feat-login
  sandbox-manager.sh cleanup

EOF
}

# ---------------------------------------------------------------------------
# Main command handler
# ---------------------------------------------------------------------------
main() {
  local command="${1:-help}"

  case "$command" in
    create)
      shift
      cmd_create "$@"
      ;;
    remove|rm)
      shift
      cmd_remove "${1:-}"
      ;;
    list|ls)
      cmd_list
      ;;
    status)
      shift
      cmd_status "${1:-}"
      ;;
    cleanup|clean)
      cmd_cleanup
      ;;
    check-runtime)
      cmd_check_runtime
      ;;
    help|--help|-h)
      show_help
      ;;
    *)
      log_error "Unknown command: $command"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

# Run
main "$@"
