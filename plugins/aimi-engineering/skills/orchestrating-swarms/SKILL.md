---
name: orchestrating-swarms
description: This skill should be used when orchestrating multi-agent swarms using Claude Code's TeammateTool and Task system. It applies when coordinating multiple agents, running parallel code reviews, creating pipeline workflows with dependencies, building self-organizing task queues, or any task benefiting from divide-and-conquer patterns.
disable-model-invocation: true
---

# Claude Code Swarm Orchestration

Multi-agent orchestration using Claude Code's TeammateTool and Task system.

---

## Primitives

| Primitive | What It Is | File Location |
|-----------|-----------|---------------|
| **Agent** | A Claude instance that can use tools. You are an agent. | N/A (process) |
| **Team** | A named group of agents. One leader, multiple teammates. | `~/.claude/teams/{name}/config.json` |
| **Teammate** | An agent in a team. Spawned via Task with `team_name` + `name`. | Listed in team config |
| **Leader** | The agent that created the team. Receives messages, approves shutdowns. | First member in config |
| **Task** | A work item with subject, status, owner, and dependencies. | `~/.claude/tasks/{team}/N.json` |
| **Inbox** | JSON file where an agent receives messages. | `~/.claude/teams/{name}/inboxes/{agent}.json` |
| **Message** | JSON sent between agents (text, shutdown_request, idle_notification, etc). | Stored in inbox files |

### How They Connect

Leader communicates with teammates via inbox messages. Teammates can also message each other. All agents share a task list where tasks have statuses (pending, in_progress, completed) and dependency chains that auto-unblock.

### Lifecycle

Create Team -> Create Tasks -> Spawn Teammates -> Work (claim + execute) -> Coordinate (inbox messages) -> Shutdown (requestShutdown each) -> Cleanup (remove resources)

### Message Flow

Leader creates tasks and spawns teammates. Teammates claim tasks, complete them, and send findings to leader. Leader requests shutdown from each teammate, waits for approvals, then calls cleanup.

> For detailed team config structure, file layout, environment variables, and spawn backends, use the Read tool on `references/team-lifecycle.md`

---

## Two Ways to Spawn Agents

### Subagent (Task tool, no team)

Short-lived, focused work that returns a result:

```javascript
Task({
  subagent_type: "Explore",
  description: "Find auth files",
  prompt: "Find all authentication-related files in this codebase",
  model: "haiku"
})
```

Runs synchronously (or async with `run_in_background: true`), returns result directly. No team membership.

### Teammate (Task + team_name + name)

Persistent agent that joins a team:

```javascript
Task({
  team_name: "my-project",
  name: "security-reviewer",
  subagent_type: "aimi-engineering:review:aimi-security-sentinel",
  prompt: "Review all auth code for vulnerabilities. Send findings to team-lead.",
  run_in_background: true
})
```

Joins team, communicates via inbox, can claim tasks from shared list. Persists until shutdown.

| Aspect | Subagent | Teammate |
|--------|----------|----------|
| Lifespan | Until task complete | Until shutdown |
| Communication | Return value | Inbox messages |
| Task access | None | Shared task list |
| Team membership | No | Yes |

---

## Agent Types

### Built-in

| Type | Tools | Best For |
|------|-------|----------|
| `Bash` | Bash only | Git ops, command execution |
| `Explore` | Read-only (model: haiku) | Codebase search, file discovery |
| `Plan` | Read-only | Architecture planning |
| `general-purpose` | All tools | Multi-step tasks, implementation |
| `claude-code-guide` | Read-only + Web | Claude Code questions |

### Plugin (aimi-engineering)

**Review:** `aimi-engineering:review:aimi-security-sentinel`, `aimi-performance-oracle`, `aimi-architecture-strategist`, `aimi-code-simplicity-reviewer`, `aimi-kieran-rails-reviewer`, `aimi-kieran-typescript-reviewer`, `aimi-kieran-python-reviewer`, `aimi-dhh-rails-reviewer`, and more.

**Research:** `aimi-engineering:research:aimi-best-practices-researcher`, `aimi-framework-docs-researcher`, `aimi-codebase-researcher`, `aimi-learnings-researcher`

**Design:** `aimi-engineering:design:aimi-figma-design-sync`

**Workflow:** `aimi-engineering:workflow:aimi-bug-reproduction-validator`

> For full agent type details with examples, use the Read tool on `references/agent-types.md`

---

## Core Operations

### Team Setup

```javascript
// Create team (you become leader)
Teammate({ operation: "spawnTeam", team_name: "feature-auth" })
```

### Messaging

```javascript
// Message one teammate
Teammate({ operation: "write", target_agent_id: "worker-1", value: "Prioritize auth module" })

// Broadcast to all (expensive -- prefer write)
Teammate({ operation: "broadcast", name: "team-lead", value: "Status check" })
```

### Task Management

```javascript
// Create task
TaskCreate({ subject: "Review auth", description: "...", activeForm: "Reviewing..." })

// Set dependencies (auto-unblock when blocking task completes)
TaskUpdate({ taskId: "2", addBlockedBy: ["1"] })

// Claim and work
TaskUpdate({ taskId: "1", owner: "worker-1", status: "in_progress" })
TaskUpdate({ taskId: "1", status: "completed" })
```

### Shutdown

```javascript
// Request shutdown for each teammate, wait for approvals, then cleanup
Teammate({ operation: "requestShutdown", target_agent_id: "worker-1" })
// Wait for {"type": "shutdown_approved"} ...
Teammate({ operation: "cleanup" })
```

> For all 13 TeammateTool operations and message format schemas, use the Read tool on `references/message-protocols.md`

> For detailed TaskCreate/TaskList/TaskGet/TaskUpdate usage and task file structure, use the Read tool on `references/task-coordination.md`

---

## Orchestration Patterns

### Parallel Specialists

Spawn multiple reviewers simultaneously, collect results, synthesize:

```javascript
Teammate({ operation: "spawnTeam", team_name: "code-review" })

Task({ team_name: "code-review", name: "security",
  subagent_type: "aimi-engineering:review:aimi-security-sentinel",
  prompt: "Review PR for security issues. Send findings to team-lead.",
  run_in_background: true })

Task({ team_name: "code-review", name: "performance",
  subagent_type: "aimi-engineering:review:aimi-performance-oracle",
  prompt: "Review PR for performance issues. Send findings to team-lead.",
  run_in_background: true })

// Collect from inbox, synthesize, shutdown + cleanup
```

### Pipeline (Sequential)

Tasks auto-unblock as dependencies complete:

```javascript
TaskCreate({ subject: "Research" })   // #1
TaskCreate({ subject: "Implement" })  // #2
TaskCreate({ subject: "Test" })       // #3
TaskUpdate({ taskId: "2", addBlockedBy: ["1"] })
TaskUpdate({ taskId: "3", addBlockedBy: ["2"] })
// Spawn workers -- tasks unblock automatically
```

### Swarm (Self-Organizing)

Workers race to claim from a pool of independent tasks:

```javascript
// Create many independent tasks, spawn N workers with prompt:
// "1. TaskList  2. Find pending task  3. Claim  4. Work  5. Complete  6. Repeat"
```

### Research + Implementation

Synchronous research, then pass results to implementer:

```javascript
const research = await Task({ subagent_type: "...", prompt: "Research caching..." })
Task({ subagent_type: "general-purpose", prompt: `Implement based on: ${research.content}` })
```

> For complete pattern examples, plan approval workflow, multi-file refactoring, and full end-to-end workflows, use the Read tool on `references/orchestration-patterns.md`

---

## Error Handling

| Error | Solution |
|-------|----------|
| "Cannot cleanup with active members" | `requestShutdown` all teammates first |
| "Already leading a team" | `cleanup` first, or use different name |
| "Agent not found" | Check `config.json` for actual names |
| "Team does not exist" | Call `spawnTeam` first |

Crashed teammates auto-deactivate after 5-minute heartbeat timeout. Their tasks can be reclaimed.

> For graceful shutdown sequence, debugging commands, and detailed error reference, use the Read tool on `references/error-handling.md`

---

## Quick Reference

```javascript
// Spawn subagent (no team)
Task({ subagent_type: "Explore", description: "Find files", prompt: "..." })

// Spawn teammate (with team)
Teammate({ operation: "spawnTeam", team_name: "my-team" })
Task({ team_name: "my-team", name: "worker", subagent_type: "general-purpose", prompt: "...", run_in_background: true })

// Message teammate
Teammate({ operation: "write", target_agent_id: "worker-1", value: "..." })

// Create task pipeline
TaskCreate({ subject: "Step 1", description: "..." })
TaskCreate({ subject: "Step 2", description: "..." })
TaskUpdate({ taskId: "2", addBlockedBy: ["1"] })

// Shutdown team
Teammate({ operation: "requestShutdown", target_agent_id: "worker-1" })
// Wait for approval...
Teammate({ operation: "cleanup" })
```

---

*Based on Claude Code v2.1.19 - Tested and verified 2026-01-25*
