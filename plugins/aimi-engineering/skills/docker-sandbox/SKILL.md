---
name: docker-sandbox
description: "Provision and manage Docker sandbox containers for parallel task execution. Provides Sysbox-isolated environments where Claude Code agents execute story-executor flows autonomously. Triggers on: swarm, sandbox, parallel docker, container execution."
user-invocable: false
---

# Docker Sandbox

Provision Sysbox-isolated Docker containers that run Claude Code agents autonomously, one container per task file, with ACP (Agent Communication Protocol) for orchestrator-to-container communication.

---

## The Job

Provide the infrastructure layer for `/aimi:swarm`: container lifecycle management, image building, and ACP message transport. Each task file gets its own sandbox container with a full agent running the story-executor flow inside it.

---

## Prerequisites

| Requirement | How to Check | Install Guide |
|-------------|-------------|---------------|
| Docker Engine | `docker version` | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/) |
| Sysbox runtime | `docker info --format '{{.Runtimes}}'` must include `sysbox-runc` | [github.com/nestybox/sysbox](https://github.com/nestybox/sysbox#installation) |
| `ANTHROPIC_API_KEY` env var | `echo $ANTHROPIC_API_KEY` | Set in shell profile or `.env` |
| Git remote `origin` | `git remote get-url origin` | `git remote add origin <url>` |
| Optional: `GITHUB_TOKEN` | `echo $GITHUB_TOKEN` | Needed for PR creation inside containers |

**Sysbox is a hard requirement.** It enables secure nested Docker (Docker-in-Docker) without `--privileged` mode. Containers run with user-namespace isolation — root inside the container maps to an unprivileged user on the host.

---

## Components

### Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `sandbox-manager.sh` | `skills/docker-sandbox/scripts/` | Container lifecycle: create, remove, list, status, cleanup, check-runtime |
| `build-project-image.sh` | `skills/docker-sandbox/scripts/` | Build per-project Docker image with checksum-based rebuild skipping |
| `acp-adapter.py` | `skills/docker-sandbox/scripts/` | ACP protocol handler inside containers — reads task-request from stdin, runs Claude Code CLI, streams progress via stdout |

### Docker

| File | Location | Purpose |
|------|----------|---------|
| `Dockerfile.base` | `skills/docker-sandbox/docker/` | Base image with Claude Code CLI, git, Node.js, Python |
| `Dockerfile.project.template` | `skills/docker-sandbox/docker/` | Template for per-project image layer (project files, dependencies) |

### Command

| Command | File | Purpose |
|---------|------|---------|
| `/aimi:swarm` | `commands/swarm.md` | Orchestration entry point — discovery, provisioning, fan-out, result collection |

### CLI Extensions

These subcommands are added to `aimi-cli.sh`:

| Subcommand | Purpose |
|------------|---------|
| `swarm-init` | Initialize swarm state file |
| `swarm-add` | Register a container in swarm state |
| `swarm-update` | Update container status and progress |
| `swarm-remove` | Remove a container entry from state |
| `swarm-status` | Read current swarm state |
| `swarm-list` | List active containers |
| `swarm-cleanup` | Remove terminal entries from state |

---

## Architecture Overview

See [references/architecture.md](./references/architecture.md) for the full architecture diagram.

### Key Design Decisions

1. **One container per task file** — complete isolation between features
2. **Sysbox runtime** — secure nested Docker without `--privileged`
3. **ACP over stdio** — JSON-lines over `docker exec -i` pipes (no network ports)
4. **Layered images** — base `aimi-sandbox` + per-project layer with checksum-based caching
5. **File-based state** — `swarm-state.json` with `flock` advisory locking
6. **State reconciliation** — automatic zombie detection before status and resume

---

## Execution Flow

1. `/aimi:swarm` discovers task files, user selects which to execute
2. `build-project-image.sh` builds (or reuses) per-project Docker image
3. `sandbox-manager.sh create` provisions Sysbox-isolated containers
4. `swarm-init` / `swarm-add` register containers in `swarm-state.json`
5. Parallel Task agents invoke `docker exec -i <container> python3 /opt/aimi/acp-adapter.py`
6. ACP adapter receives `task-request`, runs Claude Code CLI headless inside container
7. Container streams `progress-update` messages as stories complete
8. Container sends `completion` message when all stories finish
9. Orchestrator collects results, updates swarm state, removes containers

---

## Available Capabilities for Task-Spawned Agents

Agents spawned by `/aimi:swarm` as swarm workers have access to:

| Tool | Purpose |
|------|---------|
| `Bash` | Run `docker exec`, `$SANDBOX_MGR`, `$BUILD_IMG`, `$AIMI_CLI` commands |
| `Read` | Read task files and swarm state |
| `Glob` | Discover task files |

Workers do NOT modify `tasks.json` or `swarm-state.json` directly. They run `docker exec` to invoke the ACP adapter and report results back to the orchestrator.

---

## State Management

### Swarm State File

Location: `.aimi/swarm-state.json`

Tracks all containers in the current swarm. See [references/swarm-state-schema.json](./references/swarm-state-schema.json) for the full JSON Schema.

### Container Status Lifecycle

```
pending -> running -> completed
                   -> failed
                   -> stopped
```

### State Reconciliation

Runs automatically before `status` display and `resume` operations. Compares `swarm-state.json` entries against actual Docker daemon state via `sandbox-manager.sh status`.

Detects: zombie entries, silent completions, silent failures, unexpected stops, already-started containers. See [references/architecture.md](./references/architecture.md) for details.

---

## ACP Message Protocol

Transport: JSON-lines (NDJSON) over `docker exec -i` stdin/stdout pipes.

Four message types:

| Type | Direction | Purpose |
|------|-----------|---------|
| `task-request` | Orchestrator -> Container | Assign task file and branch |
| `progress-update` | Container -> Orchestrator | Report story status changes |
| `completion` | Container -> Orchestrator | Final container result |
| `error` | Container -> Orchestrator | Non-recoverable container error |

See [references/acp-messages.md](./references/acp-messages.md) for full message schemas and validation rules.

---

## Resource Limits

Container resource limits are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AIMI_SANDBOX_CPUS` | `2` | CPU cores per container |
| `AIMI_SANDBOX_MEMORY` | `4g` | Memory limit per container |
| `AIMI_SANDBOX_SWAP` | `8g` | Memory+swap total per container (with 4g memory, gives 4g actual swap) |
| `AIMI_SANDBOX_DISK` | `8g` | Disk limit per container (advisory — requires storage driver support) |

### Total Resource Consumption

| Containers | CPUs | RAM | Swap (actual) | Total Memory+Swap |
|------------|------|-----|---------------|-------------------|
| 2 | 4 | 8 GB | 8 GB | 16 GB |
| 4 | 8 | 16 GB | 16 GB | 32 GB |
| 8 | 16 | 32 GB | 32 GB | 64 GB |

> **Host sizing:** The host machine should have at least **2x the total container RAM** for OS overhead, Docker daemon, and other processes. For example, running 4 containers (16 GB container RAM) requires a host with at least 32 GB total RAM.

---

## Input Sanitization

### Container Names

Container names must match: `^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`

Validation rules:
- Must start with the `aimi-` prefix
- After prefix, must start with an alphanumeric character
- Only alphanumeric characters, hyphens, and underscores allowed after that
- No spaces, dots, or special characters
- Validated by `sandbox-manager.sh` before any Docker operation

### Task File Paths

Task file paths are validated before use:
- Must end with `.json`
- Must exist on disk (checked before container creation)
- Must be a relative path (no absolute paths or `..` traversal)
- Must be under `.aimi/tasks/` directory
- Path traversal patterns (`..`, `~`, `$`) are rejected

### Branch Names

Branch names must match: `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`

This is the same validation used by `aimi-cli.sh` for all git branch operations.

### Environment Variable Keys

When passed via ACP `task-request.payload.envVars`:
- Keys must match `^[A-Z_][A-Z0-9_]*$`
- Values must be strings (no command substitution allowed)

---

## Auto-Approve Hooks

The following patterns are auto-approved in `hooks/auto-approve-cli.sh`:

- `$SANDBOX_MGR` with subcommand whitelist: `create`, `remove`, `list`, `status`, `cleanup`, `check-runtime`
- `$BUILD_IMG` with path validation
- `$AIMI_CLI swarm-*` subcommands
- `docker exec -i aimi-*` for ACP adapter communication (restricted to `aimi-` prefixed containers running `python3 /opt/aimi/acp-adapter.py`)

---

## References

| Document | Description |
|----------|-------------|
| [architecture.md](./references/architecture.md) | Architecture overview with ASCII diagram |
| [swarm-state-schema.json](./references/swarm-state-schema.json) | JSON Schema for swarm-state.json |
| [acp-messages.md](./references/acp-messages.md) | ACP message types, schemas, and validation |
| [example-swarm-state.json](./references/example-swarm-state.json) | Example swarm state file |
| [example-acp-messages.json](./references/example-acp-messages.json) | Example ACP message payloads |
