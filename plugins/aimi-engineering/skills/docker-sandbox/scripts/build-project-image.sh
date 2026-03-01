#!/usr/bin/env bash
# =============================================================================
# build-project-image.sh — Build a per-project aimi-sandbox Docker image
# =============================================================================
# Checks for .aimi/Dockerfile.sandbox in the project root and builds a
# project-specific image layered on aimi-sandbox:base. If no Dockerfile is
# found, the base image is simply tagged as the project image.
#
# Features:
#   - Derives project slug from git repo name or directory basename
#   - Skips rebuild if image exists and Dockerfile checksum is unchanged
#   - Validates that Dockerfile.sandbox starts with FROM aimi-sandbox
#
# Usage:
#   ./build-project-image.sh [project-root]
#
# Arguments:
#   project-root  Path to the project root (default: git toplevel or cwd)
#
# Output:
#   Image tagged as: aimi-sandbox-<project-slug>:latest
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly DOCKERFILE_NAME="Dockerfile.sandbox"
readonly DOCKERFILE_REL_PATH=".aimi/${DOCKERFILE_NAME}"
readonly BASE_IMAGE="aimi-sandbox:base"
readonly CHECKSUM_LABEL="org.aimi.dockerfile-checksum"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_info() {
  echo "[aimi-build] $*"
}

log_error() {
  echo "[aimi-build] ERROR: $*" >&2
}

die() {
  log_error "$@"
  exit 1
}

# Derive a URL/filesystem-safe slug from a name.
# Lowercases, replaces non-alphanumeric chars with hyphens, trims leading/
# trailing hyphens, and collapses consecutive hyphens.
slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//'
}

# ---------------------------------------------------------------------------
# Resolve project root
# ---------------------------------------------------------------------------

if [[ $# -ge 1 ]]; then
  PROJECT_ROOT="$(cd "$1" && pwd)"
else
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

if [[ ! -d "${PROJECT_ROOT}" ]]; then
  die "Project root does not exist: ${PROJECT_ROOT}"
fi

# ---------------------------------------------------------------------------
# Derive project slug
# ---------------------------------------------------------------------------

# Prefer git remote-based name, fall back to directory basename
REPO_NAME=""
if git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree &>/dev/null; then
  REMOTE_URL="$(git -C "${PROJECT_ROOT}" remote get-url origin 2>/dev/null || true)"
  if [[ -n "${REMOTE_URL}" ]]; then
    # Extract repo name from remote URL (handles both HTTPS and SSH)
    REPO_NAME="$(basename "${REMOTE_URL}" .git)"
  fi
fi

if [[ -z "${REPO_NAME}" ]]; then
  REPO_NAME="$(basename "${PROJECT_ROOT}")"
fi

PROJECT_SLUG="$(slugify "${REPO_NAME}")"
IMAGE_TAG="aimi-sandbox-${PROJECT_SLUG}:latest"

log_info "Project root : ${PROJECT_ROOT}"
log_info "Project slug : ${PROJECT_SLUG}"
log_info "Image tag    : ${IMAGE_TAG}"

# ---------------------------------------------------------------------------
# Locate Dockerfile.sandbox
# ---------------------------------------------------------------------------

DOCKERFILE_PATH="${PROJECT_ROOT}/${DOCKERFILE_REL_PATH}"

if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  log_info "No ${DOCKERFILE_REL_PATH} found — tagging base image as ${IMAGE_TAG}"
  docker tag "${BASE_IMAGE}" "${IMAGE_TAG}"
  log_info "Done. Image: ${IMAGE_TAG}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Validate Dockerfile.sandbox
# ---------------------------------------------------------------------------

# The first non-comment, non-blank line must start with "FROM aimi-sandbox"
FIRST_INSTRUCTION="$(grep -E '^\s*[^#]' "${DOCKERFILE_PATH}" | head -n 1 | xargs)"
if [[ ! "${FIRST_INSTRUCTION}" =~ ^FROM[[:space:]]+aimi-sandbox ]]; then
  die "${DOCKERFILE_NAME} must start with 'FROM aimi-sandbox...' (found: '${FIRST_INSTRUCTION}')"
fi

log_info "Validated: ${DOCKERFILE_NAME} extends aimi-sandbox"

# ---------------------------------------------------------------------------
# Checksum-based skip — avoid rebuilding when Dockerfile hasn't changed
# ---------------------------------------------------------------------------

CURRENT_CHECKSUM="$(sha256sum "${DOCKERFILE_PATH}" | awk '{print $1}')"

# Check if image already exists and retrieve its stored checksum label
EXISTING_CHECKSUM=""
if docker image inspect "${IMAGE_TAG}" &>/dev/null; then
  EXISTING_CHECKSUM="$(
    docker image inspect "${IMAGE_TAG}" \
      --format "{{index .Config.Labels \"${CHECKSUM_LABEL}\"}}" 2>/dev/null || true
  )"
fi

if [[ "${CURRENT_CHECKSUM}" == "${EXISTING_CHECKSUM}" ]]; then
  log_info "Dockerfile unchanged (checksum: ${CURRENT_CHECKSUM:0:12}...) — skipping rebuild"
  log_info "Done. Image: ${IMAGE_TAG}"
  exit 0
fi

log_info "Building project image (checksum: ${CURRENT_CHECKSUM:0:12}...)"

# ---------------------------------------------------------------------------
# Build the project image
# ---------------------------------------------------------------------------

docker build \
  -f "${DOCKERFILE_PATH}" \
  -t "${IMAGE_TAG}" \
  --label "${CHECKSUM_LABEL}=${CURRENT_CHECKSUM}" \
  "${PROJECT_ROOT}"

log_info "Done. Image: ${IMAGE_TAG}"
