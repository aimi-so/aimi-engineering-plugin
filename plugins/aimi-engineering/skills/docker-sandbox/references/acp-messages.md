# ACP Message Schema Reference

Agent Communication Protocol (ACP) messages are JSON payloads exchanged between the swarm orchestrator and sandbox containers. Every message has a `type` field that determines its shape.

---

## Message Envelope

All ACP messages share a common envelope:

```json
{
  "type": "string",
  "timestamp": "ISO 8601 date-time",
  "swarmId": "UUID v4",
  "containerId": "Docker container ID"
}
```

| Field         | Type   | Required | Description                                      |
|---------------|--------|----------|--------------------------------------------------|
| `type`        | string | Yes      | Message type discriminator                        |
| `timestamp`   | string | Yes      | ISO 8601 timestamp when the message was created   |
| `swarmId`     | string | Yes      | UUID of the swarm this message belongs to          |
| `containerId` | string | Yes      | Docker container ID that sent or receives the msg  |

---

## Message Types

### 1. `task-request`

**Direction:** Orchestrator -> Container

Sent by the orchestrator to assign a task file to a sandbox container. The container reads the task file and begins executing stories.

#### Schema

```json
{
  "type": "task-request",
  "timestamp": "2026-03-01T10:00:00Z",
  "swarmId": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "containerId": "abc123def456",
  "payload": {
    "taskFilePath": ".aimi/tasks/2026-03-01-feature-tasks.json",
    "branchName": "feat/my-feature",
    "repoUrl": "https://github.com/org/repo.git",
    "envVars": {
      "NODE_ENV": "development",
      "DATABASE_URL": "postgres://localhost:5432/dev"
    }
  }
}
```

#### Payload Fields

| Field          | Type   | Required | Description                                                        |
|----------------|--------|----------|--------------------------------------------------------------------|
| `taskFilePath` | string | Yes      | Relative path to the tasks.json file to execute                     |
| `branchName`   | string | Yes      | Git branch to check out and work on. Must match `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` |
| `repoUrl`      | string | Yes      | Git remote URL to clone inside the container                        |
| `envVars`      | object | No       | Key-value pairs of environment variables to set in the container. Keys and values must be strings. Defaults to `{}` |

#### Validation

- `branchName` must match `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`
- `taskFilePath` must end with `.json`
- `repoUrl` must be a valid URL (https or ssh)
- `envVars` keys must match `^[A-Z_][A-Z0-9_]*$`

---

### 2. `progress-update`

**Direction:** Container -> Orchestrator

Sent by a container when a story's status changes. The orchestrator uses this to update `swarm-state.json`.

#### Schema

```json
{
  "type": "progress-update",
  "timestamp": "2026-03-01T10:05:00Z",
  "swarmId": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "containerId": "abc123def456",
  "payload": {
    "storyId": "US-001",
    "status": "completed",
    "output": "Migration created and applied. Schema validated. Typecheck passes."
  }
}
```

#### Payload Fields

| Field     | Type   | Required | Description                                                    |
|-----------|--------|----------|----------------------------------------------------------------|
| `storyId` | string | Yes      | ID of the story being reported on (e.g., `US-001`)              |
| `status`  | string | Yes      | New story status. One of: `pending`, `in_progress`, `completed`, `failed`, `skipped` |
| `output`  | string | Yes      | Human-readable summary of what happened (max 2000 chars)        |

#### Validation

- `storyId` must match `^US-\d{3}$`
- `status` must be one of: `pending`, `in_progress`, `completed`, `failed`, `skipped`
- `output` must not exceed 2000 characters

---

### 3. `completion`

**Direction:** Container -> Orchestrator

Sent by a container when it finishes all assigned stories (success or failure). This is the final message a container sends before exiting.

#### Schema

```json
{
  "type": "completion",
  "timestamp": "2026-03-01T11:30:00Z",
  "swarmId": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "containerId": "abc123def456",
  "payload": {
    "status": "completed",
    "prUrl": "https://github.com/org/repo/pull/42",
    "errors": []
  }
}
```

#### Payload Fields

| Field    | Type     | Required | Description                                                                |
|----------|----------|----------|----------------------------------------------------------------------------|
| `status` | string   | Yes      | Final container status. One of: `completed`, `failed`, `stopped`            |
| `prUrl`  | string or null | Yes | URL of the pull request created, or `null` if no PR was created             |
| `errors` | array    | Yes      | Array of error strings encountered during execution. Empty array if none    |

#### Validation

- `status` must be one of: `completed`, `failed`, `stopped`
- `prUrl` must be a valid URL or `null`
- Each entry in `errors` must be a string (max 500 chars per entry, max 50 entries)

#### Status Meanings

| Status      | Meaning                                                     |
|-------------|-------------------------------------------------------------|
| `completed` | All stories finished (some may have failed individually)     |
| `failed`    | Container-level failure (crash, resource exhaustion, etc.)   |
| `stopped`   | Container was explicitly stopped by orchestrator or user     |

---

### 4. `error`

**Direction:** Container -> Orchestrator

Sent by a container when a non-recoverable error occurs. Unlike `progress-update` with `failed` status (which is story-level), this indicates a container-level problem.

#### Schema

```json
{
  "type": "error",
  "timestamp": "2026-03-01T10:15:00Z",
  "swarmId": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "containerId": "abc123def456",
  "payload": {
    "code": "CONTAINER_OOM",
    "message": "Container exceeded memory limit (4GB). Process killed by OOM killer."
  }
}
```

#### Payload Fields

| Field     | Type   | Required | Description                                              |
|-----------|--------|----------|----------------------------------------------------------|
| `code`    | string | Yes      | Machine-readable error code (SCREAMING_SNAKE_CASE)        |
| `message` | string | Yes      | Human-readable error description (max 2000 chars)         |

#### Standard Error Codes

| Code                   | Description                                          |
|------------------------|------------------------------------------------------|
| `CONTAINER_OOM`        | Container ran out of memory                           |
| `CONTAINER_TIMEOUT`    | Container exceeded execution time limit               |
| `GIT_CLONE_FAILED`     | Failed to clone the repository                        |
| `GIT_CHECKOUT_FAILED`  | Failed to check out the specified branch              |
| `TASK_FILE_NOT_FOUND`  | The specified task file does not exist                 |
| `TASK_FILE_INVALID`    | The task file failed schema validation                |
| `ACP_CONNECTION_LOST`  | Lost connection to the orchestrator                   |
| `AGENT_CRASH`          | The agent process inside the container crashed         |
| `UNKNOWN_ERROR`        | Unclassified error                                    |

#### Validation

- `code` must match `^[A-Z][A-Z0-9_]*$`
- `message` must not exceed 2000 characters

---

## Message Flow

```
Orchestrator                    Container
    |                               |
    |--- task-request ------------->|
    |                               |
    |<-- progress-update (US-001) --|  (in_progress)
    |<-- progress-update (US-001) --|  (completed)
    |<-- progress-update (US-002) --|  (in_progress)
    |<-- progress-update (US-002) --|  (completed)
    |                               |
    |<-- completion ----------------|
    |                               |
```

Error flow:

```
Orchestrator                    Container
    |                               |
    |--- task-request ------------->|
    |                               |
    |<-- progress-update (US-001) --|  (in_progress)
    |<-- error ---------------------|  (CONTAINER_OOM)
    |                               X  (container exits)
```

---

## Transport

ACP messages are exchanged via **stdout/stdin pipes** between the orchestrator process and the container's ACP process. Each message is a single line of JSON (newline-delimited JSON / NDJSON).

- One JSON object per line
- No trailing commas
- UTF-8 encoding
- Maximum message size: 64 KB
