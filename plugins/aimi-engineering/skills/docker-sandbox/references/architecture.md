# Docker Sandbox Architecture

Overview of the docker-sandbox skill architecture, covering container topology, image layering, ACP message flow, and state management.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Host Machine                                  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                     Claude Code CLI (Host)                        │  │
│  │                                                                   │  │
│  │  ┌─────────────┐                                                  │  │
│  │  │ /aimi:swarm  │  Orchestrator entry point                       │  │
│  │  └──────┬──────┘                                                  │  │
│  │         │                                                         │  │
│  │         ├── Discovers task files (.aimi/tasks/*-tasks.json)        │  │
│  │         ├── Builds project image (build-project-image.sh)         │  │
│  │         ├── Provisions containers (sandbox-manager.sh)            │  │
│  │         ├── Tracks state (aimi-cli.sh swarm-*)                    │  │
│  │         │                                                         │  │
│  │         ▼                                                         │  │
│  │  ┌─────────────────── Fan-Out ───────────────────┐                │  │
│  │  │  Parallel Task agents (one per container)      │                │  │
│  │  │                                                │                │  │
│  │  │  ┌──────────┐  ┌──────────┐  ┌──────────┐     │                │  │
│  │  │  │ Worker 1 │  │ Worker 2 │  │ Worker N │     │                │  │
│  │  │  └────┬─────┘  └────┬─────┘  └────┬─────┘     │                │  │
│  │  └───────┼─────────────┼─────────────┼────────────┘                │  │
│  └──────────┼─────────────┼─────────────┼────────────────────────────┘  │
│             │ docker      │ docker      │ docker                        │
│             │ exec -i     │ exec -i     │ exec -i                       │
│             │ (stdio)     │ (stdio)     │ (stdio)                       │
│  ┌──────────▼──────────┐ ┌▼──────────┐ ┌▼──────────┐                   │
│  │ Container 1         │ │Container 2│ │Container N│                   │
│  │ (Sysbox runtime)    │ │(Sysbox)   │ │(Sysbox)   │                   │
│  │                     │ │           │ │           │                   │
│  │ acp-adapter.py      │ │ acp-      │ │ acp-      │                   │
│  │   ↕ stdio           │ │ adapter   │ │ adapter   │                   │
│  │ Claude Code CLI     │ │ Claude CLI│ │ Claude CLI│                   │
│  │   ↕                 │ │           │ │           │                   │
│  │ Git worktree        │ │ worktree  │ │ worktree  │                   │
│  │ (cloned repo)       │ │           │ │           │                   │
│  └─────────────────────┘ └───────────┘ └───────────┘                   │
│                                                                         │
│  State: .aimi/swarm-state.json (flock-locked)                           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Docker Image Layering

```
┌─────────────────────────────────────────┐
│         aimi-sandbox-<project>:latest   │  Per-project layer
│                                         │  - Project source code (git clone)
│  FROM aimi-sandbox:base                 │  - Project dependencies (npm/pip/etc)
│  COPY . /workspace                      │  - .aimi/ configuration
│  RUN install-deps                       │  - Checksum-based rebuild skipping
├─────────────────────────────────────────┤
│         aimi-sandbox:base               │  Base image (Dockerfile.base)
│                                         │  - Ubuntu + Sysbox-compatible init
│  Claude Code CLI (headless)             │  - Node.js, Python, Git
│  acp-adapter.py at /opt/aimi/           │  - Claude Code CLI pre-installed
│  Git, SSH, curl                         │  - ACP adapter copied to /opt/aimi/
│  Node.js, Python runtime               │  - ANTHROPIC_API_KEY passed at runtime
└─────────────────────────────────────────┘
```

### Image Build Flow

```
build-project-image.sh
    │
    ├── Check if aimi-sandbox:base exists
    │   └── If not: build from Dockerfile.base
    │
    ├── Derive project slug from git repo name
    │
    ├── Check if aimi-sandbox-<slug>:latest exists
    │   └── If exists: compare Dockerfile checksum
    │       ├── Match: reuse existing image (skip rebuild)
    │       └── Mismatch: rebuild
    │
    └── Build from Dockerfile.project.template
        └── Output: aimi-sandbox-<slug>:latest
```

---

## ACP Message Flow

```
Orchestrator (Host)                    Container (Sysbox)
       │                                      │
       │  ┌─ docker exec -i ──────────────┐   │
       │  │                                │   │
       │  │  stdin ──────────────────────► │   │
       │  │  task-request JSON             │   │
       │  │                                │   │
       │  │                  acp-adapter.py│   │
       │  │                       │        │   │
       │  │                       ▼        │   │
       │  │              Claude Code CLI   │   │
       │  │              (headless mode)   │   │
       │  │                       │        │   │
       │  │  stdout ◄──────────── │        │   │
       │  │  progress-update (NDJSON)      │   │
       │  │  progress-update (NDJSON)      │   │
       │  │  ...                           │   │
       │  │  completion (NDJSON)           │   │
       │  │                                │   │
       │  └────────────────────────────────┘   │
       │                                      │
```

### Message Types

| Type | Direction | When |
|------|-----------|------|
| `task-request` | Host -> Container | Container startup, assigns task file |
| `progress-update` | Container -> Host | Each story status change |
| `completion` | Container -> Host | All stories finished (final message) |
| `error` | Container -> Host | Non-recoverable container failure |

See [acp-messages.md](./acp-messages.md) for full schemas and validation rules.

---

## Container Lifecycle

```
                    sandbox-manager.sh
                          │
          ┌───────────────┼───────────────┐
          │               │               │
          ▼               ▼               ▼
       create          status          remove
          │               │               │
          ▼               │               ▼
   ┌──────────┐           │        ┌──────────┐
   │ pending  │───────────┘        │ (gone)   │
   └────┬─────┘                    └──────────┘
        │ ACP task-request                ▲
        ▼                                 │
   ┌──────────┐                           │
   │ running  │───────────────────────────┤
   └────┬─────┘   remove (after          │
        │         completion/failure)     │
        ├──────────────┐                  │
        ▼              ▼                  │
   ┌──────────┐  ┌──────────┐            │
   │completed │  │ failed   │────────────┘
   └──────────┘  └──────────┘    cleanup
```

---

## State Management

### Swarm State File

Location: `.aimi/swarm-state.json`

Managed exclusively through `aimi-cli.sh swarm-*` subcommands with `flock` advisory locking for concurrent access safety.

```
aimi-cli.sh
    │
    ├── swarm-init      Create new swarm state file
    ├── swarm-add       Register container entry
    ├── swarm-update    Update container status/progress
    ├── swarm-remove    Remove container entry
    ├── swarm-status    Read current state
    ├── swarm-list      List active containers
    └── swarm-cleanup   Remove terminal entries
```

### Concurrency Model

- **flock advisory locking** on `.aimi/.state.lock` prevents concurrent state corruption
- **Atomic writes** via temp file + `mv` pattern
- **Reconciliation before reads** ensures displayed state matches Docker daemon reality

See [swarm-state-schema.json](./swarm-state-schema.json) for the full JSON Schema definition.

---

## State Reconciliation

Automatic reconciliation runs before `status` display and `resume` operations.

```
swarm-state.json              Docker Daemon
       │                           │
       │     For each container:   │
       ├──────────────────────────►│
       │   sandbox-manager.sh      │
       │   status <name>           │
       │◄──────────────────────────┤
       │   {exists, swarmState,    │
       │    exitCode}              │
       │                           │
       ▼                           │
  Compare states                   │
       │                           │
       ├── Match: no action        │
       ├── Zombie: mark failed     │
       ├── Silent completion:      │
       │   mark completed          │
       ├── Silent failure:         │
       │   mark failed             │
       └── Unexpected stop:        │
           mark stopped            │
```

### Detection Scenarios

| Scenario | State Says | Docker Says | Action |
|----------|-----------|-------------|--------|
| Zombie | `running` or `pending` | Container not found | Mark `failed` |
| Silent completion | `running` | Exited, code 0 | Mark `completed` |
| Silent failure | `running` | Exited, code != 0 | Mark `failed` |
| Unexpected stop | `running` | Paused/removing | Mark `stopped` |
| Already started | `pending` | Running | Mark `running` |

---

## Security Model

### Sysbox Isolation

- User-namespace mapping: container root maps to unprivileged host user
- No `--privileged` flag required
- Secure nested Docker support (Docker-in-Docker)
- Resource limits enforced via cgroups (CPU, memory, swap, disk)

### Auto-Approve Scope

Only these patterns are auto-approved (defined in `hooks/auto-approve-cli.sh`):

1. `$SANDBOX_MGR` with whitelisted subcommands only
2. `$BUILD_IMG` with path validation
3. `$AIMI_CLI swarm-*` subcommands only
4. `docker exec -i aimi-*` restricted to ACP adapter invocations

No wildcard Docker approvals. No `--privileged` approvals.
