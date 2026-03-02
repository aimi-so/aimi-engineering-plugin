---
name: agent-native-architecture
description: Build applications where agents are first-class citizens. Use this skill when designing autonomous agents, creating MCP tools, implementing self-modifying systems, or building apps where features are outcomes achieved by agents operating in a loop.
---

<why_now>
## Why Now

Software agents work reliably now. Claude Code proved that an LLM with bash and file tools, looping until an objective is met, can accomplish complex tasks autonomously. The same architecture applies beyond coding — file management, workflows, any domain. The Claude Code SDK makes this accessible: features aren't code you write, they're outcomes agents achieve.
</why_now>

<core_principles>
## Core Principles

### 1. Parity

**Whatever the user can do through the UI, the agent must be able to achieve through tools.**

This doesn't require 1:1 mapping of UI buttons to tools — it requires the agent can achieve the same **outcomes**. Sometimes that's a single tool (`create_note`), sometimes it's composing primitives (`write_file` to a notes directory).

**Discipline:** When adding any UI capability, ask: can the agent achieve this outcome? If not, add the necessary tools or primitives.

> Read [action-parity-discipline.md](./references/action-parity-discipline.md) for capability mapping workflow.

### 2. Granularity

**Prefer atomic primitives. Features are outcomes achieved by an agent operating in a loop.**

A tool is a primitive capability (read file, write file, run bash). A **feature** is an outcome described in a prompt, achieved by an agent with tools looping until done.

```
Less granular: classify_and_organize_files(files)  → You wrote the logic
More granular: read_file, write_file, move_file    → Agent makes decisions
              Prompt: "Organize downloads by content and recency"
```

**Key shift:** To change how a feature behaves, you edit prose, not refactor code.

### 3. Composability

**With atomic tools and parity, new features are just new prompts.**

Want a "weekly review" feature? Write a prompt: *"Review files modified this week, summarize changes, suggest three priorities."* The agent uses `list_files`, `read_file`, and judgment. No weekly-review code needed. Users can extend behavior the same way.

**Constraint:** Only works if tools are atomic enough for unanticipated composition and the agent has parity.

### 4. Emergent Capability

**The agent can accomplish things you didn't explicitly design for.**

When tools are atomic and parity is maintained, users ask for unanticipated things — and the agent figures them out. This reveals latent demand: observe what users ask, then optimize common patterns with domain tools or dedicated prompts.

**Flywheel:** Atomic tools + parity → users request unexpected things → agent composes solutions → you observe patterns → optimize → repeat.

### 5. Improvement Over Time

**Agent-native apps get better through accumulated context and prompt refinement.**

- **Accumulated context:** Agent maintains state across sessions via `context.md` or structured memory
- **Prompt refinement:** Developer ships updated prompts; users customize theirs; agents self-modify (advanced)
- **Self-modification:** Agents editing own prompts/code — add safety rails for production

> Read [self-modification.md](./references/self-modification.md) for guardrails.

**Test for each principle:**
1. Parity — Can the agent achieve any UI action?
2. Granularity — Do you edit prose or refactor code to change behavior?
3. Composability — Can you add features by writing prompts alone?
4. Emergent — Can the agent handle open-ended domain requests?
5. Improvement — Does it work better after a month, without code changes?
</core_principles>

<intake>
## What aspect of agent-native architecture do you need help with?

1. **Design architecture** — Plan a new agent-native system
2. **Files & workspace** — Files as universal interface, shared workspace
3. **Tool design** — Primitive tools, dynamic capability discovery, CRUD
4. **Domain tools** — When to add domain tools vs stay with primitives
5. **Execution patterns** — Completion signals, partial completion, context limits
6. **System prompts** — Agent behavior in prompts, judgment criteria
7. **Context injection** — Inject runtime app state into agent prompts
8. **Action parity** — Ensure agents can do everything users can
9. **Self-modification** — Agents safely evolving themselves
10. **Product design** — Progressive disclosure, latent demand, approval patterns
11. **Mobile patterns** — iOS storage, background execution, checkpoint/resume
12. **Testing** — Capability and parity tests for agent-native apps
13. **Refactoring** — Make existing code more agent-native

**Wait for response before proceeding.**
</intake>

<routing>
| Response | Action |
|----------|--------|
| 1, "design", "architecture", "plan" | Read [architecture-patterns.md](./references/architecture-patterns.md), then apply Architecture Checklist below |
| 2, "files", "workspace", "filesystem" | Read [files-universal-interface.md](./references/files-universal-interface.md) and [shared-workspace-architecture.md](./references/shared-workspace-architecture.md) |
| 3, "tool", "mcp", "primitive", "crud" | Read [mcp-tool-design.md](./references/mcp-tool-design.md) |
| 4, "domain tool", "when to add" | Read [from-primitives-to-domain-tools.md](./references/from-primitives-to-domain-tools.md) |
| 5, "execution", "completion", "loop" | Read [agent-execution-patterns.md](./references/agent-execution-patterns.md) |
| 6, "prompt", "system prompt", "behavior" | Read [system-prompt-design.md](./references/system-prompt-design.md) |
| 7, "context", "inject", "runtime", "dynamic" | Read [dynamic-context-injection.md](./references/dynamic-context-injection.md) |
| 8, "parity", "ui action", "capability map" | Read [action-parity-discipline.md](./references/action-parity-discipline.md) |
| 9, "self-modify", "evolve", "git" | Read [self-modification.md](./references/self-modification.md) |
| 10, "product", "progressive", "approval", "latent demand" | Read [product-implications.md](./references/product-implications.md) |
| 11, "mobile", "ios", "android", "background", "checkpoint" | Read [mobile-patterns.md](./references/mobile-patterns.md) |
| 12, "test", "testing", "verify", "validate" | Read [agent-native-testing.md](./references/agent-native-testing.md) |
| 13, "review", "refactor", "existing" | Read [refactoring-to-prompt-native.md](./references/refactoring-to-prompt-native.md) |

**After reading the reference, apply those patterns to the user's specific context.**
</routing>

<architecture_checklist>
## Architecture Review Checklist

Verify these **before implementation**:

- [ ] **Parity:** Every UI action has a corresponding agent capability
- [ ] **Granularity:** Tools are primitives; features are prompt-defined outcomes
- [ ] **Composability:** New features via prompts alone
- [ ] **Emergent Capability:** Agent handles open-ended domain requests
- [ ] **Dynamic vs Static:** Use Dynamic Capability Discovery for external APIs
- [ ] **CRUD Completeness:** Every entity has create, read, update, AND delete
- [ ] **Primitives not Workflows:** Tools enable capability, don't encode business logic
- [ ] **Shared Workspace:** Agent and user work in same data space
- [ ] **context.md Pattern:** Agent reads/updates context for accumulated knowledge
- [ ] **Completion Signals:** Explicit `complete_task` tool (not heuristic detection)
- [ ] **Partial Completion:** Multi-step tasks track progress for resume
- [ ] **Context Injection:** System prompt includes available resources, capabilities, vocabulary
- [ ] **Agent → UI:** Agent changes reflect in UI immediately
- [ ] **Mobile (if applicable):** Checkpoint/resume, iCloud-first, cost-aware model selection

**When designing architecture, explicitly address each checkbox.**
</architecture_checklist>

<quick_start>
## Quick Start: Agent-Native Feature

```typescript
// Step 1: Atomic tools
const tools = [
  tool("read_file", "Read any file", { path: z.string() }, ...),
  tool("write_file", "Write any file", { path: z.string(), content: z.string() }, ...),
  tool("list_files", "List directory", { path: z.string() }, ...),
  tool("complete_task", "Signal completion", { summary: z.string() }, ...),
];

// Step 2: Behavior in system prompt
const systemPrompt = `When asked to organize content:
1. Read existing files to understand structure
2. Analyze what organization makes sense
3. Create/move files using your tools
4. Call complete_task when done. You decide the structure.`;

// Step 3: Agent loops until complete_task is called
const result = await agent.run({ prompt: userMessage, tools, systemPrompt });
```
</quick_start>

<reference_index>
## Reference Files

All references in `references/`:

**Core Patterns:**
- [architecture-patterns.md](./references/architecture-patterns.md) - Event-driven, unified orchestrator, agent-to-UI
- [files-universal-interface.md](./references/files-universal-interface.md) - Why files, organization patterns, context.md
- [mcp-tool-design.md](./references/mcp-tool-design.md) - Tool design, dynamic capability discovery, CRUD
- [from-primitives-to-domain-tools.md](./references/from-primitives-to-domain-tools.md) - When to add domain tools, graduating to code
- [agent-execution-patterns.md](./references/agent-execution-patterns.md) - Completion signals, partial completion, context limits
- [system-prompt-design.md](./references/system-prompt-design.md) - Features as prompts, judgment criteria

**Agent-Native Disciplines:**
- [dynamic-context-injection.md](./references/dynamic-context-injection.md) - Runtime context, what to inject
- [action-parity-discipline.md](./references/action-parity-discipline.md) - Capability mapping, parity workflow
- [shared-workspace-architecture.md](./references/shared-workspace-architecture.md) - Shared data space, UI integration
- [product-implications.md](./references/product-implications.md) - Progressive disclosure, latent demand, approval
- [agent-native-testing.md](./references/agent-native-testing.md) - Testing outcomes, parity tests

**Platform-Specific:**
- [mobile-patterns.md](./references/mobile-patterns.md) - iOS storage, checkpoint/resume, cost awareness
- [self-modification.md](./references/self-modification.md) - Git-based evolution, guardrails
- [refactoring-to-prompt-native.md](./references/refactoring-to-prompt-native.md) - Migrating existing code
</reference_index>

<anti_patterns>
## Anti-Patterns

### Approaches That Aren't Agent-Native

**Agent as router** — Agent figures out intent, calls a function. Uses intelligence to route, not to act. You're using a fraction of agent capability.

**Build app, then add agent** — Features built as code, then exposed to agent. No emergent capability possible.

**Request/response thinking** — Agent does one thing and returns. Misses the loop: agent pursues an outcome, handles unexpected situations along the way.

**Defensive tool design** — Over-constrained inputs (strict enums, excessive validation) prevent unanticipated usage.

**Happy path in code** — Edge cases handled in code means the agent is just a caller, not using judgment.

### Specific Anti-Patterns

**Cardinal sin: Agent executes your code instead of figuring things out**
```typescript
// WRONG: You wrote the workflow
tool("process_feedback", async ({ message }) => {
  const cat = categorize(message); const pri = calculatePriority(message);
  await store(message, cat, pri); if (pri > 3) await notify();
});
// RIGHT: Agent decides
tools: store_item, send_message
prompt: "Rate importance 1-5, store feedback, notify if >= 4"
```

**Workflow-shaped tools** — `analyze_and_organize` bundles judgment. Break into primitives.

**Context starvation** — Agent doesn't know what resources exist. Fix: inject available resources and vocabulary into system prompt.

**Orphan UI actions** — User can do something the agent can't. Fix: maintain parity.

**Silent actions** — Agent changes state, UI doesn't update. Fix: shared data stores with reactive binding.

**Heuristic completion** — Detecting completion through heuristics is fragile. Fix: explicit `complete_task` tool.

**Static tool mapping** — 50 tools for 50 API endpoints. Fix: `discover` + `access` pattern for dynamic APIs.

**Incomplete CRUD** — Agent can create but not update or delete. Fix: every entity needs full CRUD.

**Sandbox isolation** — Agent works in separate data space. Fix: shared workspace.

**Gates without reason** — Domain tool is the only path, restricting access unintentionally. Keep primitives available.
</anti_patterns>

<success_criteria>
## Success Criteria

**Architecture:**
- [ ] Agent achieves anything users can (parity)
- [ ] Tools are atomic; domain tools are shortcuts, not gates (granularity)
- [ ] New features via prompts alone (composability)
- [ ] Agent handles unanticipated domain tasks (emergent capability)
- [ ] Behavior changes via prompt edits, not code refactoring

**Implementation:**
- [ ] System prompt includes dynamic context about app state
- [ ] Every UI action has a corresponding agent tool
- [ ] Agent and user share data space; agent actions reflect in UI immediately
- [ ] Every entity has full CRUD; agents signal completion explicitly
- [ ] context.md or equivalent for accumulated knowledge

**The Ultimate Test:** Describe an outcome within your domain that you didn't build a feature for. Can the agent figure it out, looping until it succeeds? If yes — agent-native. If "I don't have a feature for that" — too constrained.
</success_criteria>
