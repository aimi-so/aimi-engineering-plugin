# Agent Types Reference

---

## Built-in Agent Types

These are always available without plugins.

### Bash
```javascript
Task({
  subagent_type: "Bash",
  description: "Run git commands",
  prompt: "Check git status and show recent commits"
})
```
- **Tools:** Bash only
- **Model:** Inherits from parent
- **Best for:** Git operations, command execution, system tasks

### Explore
```javascript
Task({
  subagent_type: "Explore",
  description: "Find API endpoints",
  prompt: "Find all API endpoints in this codebase. Be very thorough.",
  model: "haiku"  // Fast and cheap
})
```
- **Tools:** All read-only tools (no Edit, Write, NotebookEdit, Task)
- **Model:** Haiku (optimized for speed)
- **Best for:** Codebase exploration, file searches, code understanding
- **Thoroughness levels:** "quick", "medium", "very thorough"

### Plan
```javascript
Task({
  subagent_type: "Plan",
  description: "Design auth system",
  prompt: "Create an implementation plan for adding OAuth2 authentication"
})
```
- **Tools:** All read-only tools
- **Model:** Inherits from parent
- **Best for:** Architecture planning, implementation strategies

### general-purpose
```javascript
Task({
  subagent_type: "general-purpose",
  description: "Research and implement",
  prompt: "Research React Query best practices and implement caching for the user API"
})
```
- **Tools:** All tools (*)
- **Model:** Inherits from parent
- **Best for:** Multi-step tasks, research + action combinations

### claude-code-guide
```javascript
Task({
  subagent_type: "claude-code-guide",
  description: "Help with Claude Code",
  prompt: "How do I configure MCP servers?"
})
```
- **Tools:** Read-only + WebFetch + WebSearch
- **Best for:** Questions about Claude Code, Agent SDK, Anthropic API

### statusline-setup
```javascript
Task({
  subagent_type: "statusline-setup",
  description: "Configure status line",
  prompt: "Set up a status line showing git branch and node version"
})
```
- **Tools:** Read, Edit only
- **Model:** Sonnet
- **Best for:** Configuring Claude Code status line

---

## Plugin Agent Types (aimi-engineering)

### Review Agents

```javascript
// Security review
Task({
  subagent_type: "aimi-engineering:review:aimi-security-sentinel",
  description: "Security audit",
  prompt: "Audit this PR for security vulnerabilities"
})

// Performance review
Task({
  subagent_type: "aimi-engineering:review:aimi-performance-oracle",
  description: "Performance check",
  prompt: "Analyze this code for performance bottlenecks"
})

// Rails code review
Task({
  subagent_type: "aimi-engineering:review:aimi-kieran-rails-reviewer",
  description: "Rails review",
  prompt: "Review this Rails code for best practices"
})

// Architecture review
Task({
  subagent_type: "aimi-engineering:review:aimi-architecture-strategist",
  description: "Architecture review",
  prompt: "Review the system architecture of the authentication module"
})

// Code simplicity
Task({
  subagent_type: "aimi-engineering:review:aimi-code-simplicity-reviewer",
  description: "Simplicity check",
  prompt: "Check if this implementation can be simplified"
})
```

**All review agents from aimi-engineering:**
- `aimi-agent-native-reviewer` - Ensures features work for agents too
- `aimi-architecture-strategist` - Architectural compliance
- `aimi-code-simplicity-reviewer` - YAGNI and minimalism
- `aimi-data-integrity-guardian` - Database and data safety
- `aimi-data-migration-expert` - Migration validation
- `aimi-deployment-verification-agent` - Pre-deploy checklists
- `aimi-dhh-rails-reviewer` - DHH/37signals Rails style
- `aimi-julik-frontend-races-reviewer` - JavaScript race conditions
- `aimi-kieran-python-reviewer` - Python best practices
- `aimi-kieran-rails-reviewer` - Rails best practices
- `aimi-kieran-typescript-reviewer` - TypeScript best practices
- `aimi-pattern-recognition-specialist` - Design patterns and anti-patterns
- `aimi-performance-oracle` - Performance analysis
- `aimi-security-sentinel` - Security vulnerabilities

### Research Agents

```javascript
// Best practices research
Task({
  subagent_type: "aimi-engineering:research:aimi-best-practices-researcher",
  description: "Research auth best practices",
  prompt: "Research current best practices for JWT authentication in Rails 2024-2026"
})

// Framework documentation
Task({
  subagent_type: "aimi-engineering:research:aimi-framework-docs-researcher",
  description: "Research Active Storage",
  prompt: "Gather comprehensive documentation about Active Storage file uploads"
})

// Learnings research
Task({
  subagent_type: "aimi-engineering:research:aimi-learnings-researcher",
  description: "Search past solutions",
  prompt: "Search .aimi/solutions/ for relevant past solutions to authentication issues"
})
```

**All research agents from aimi-engineering:**
- `aimi-best-practices-researcher` - External best practices
- `aimi-framework-docs-researcher` - Framework documentation
- `aimi-codebase-researcher` - Repository structure and patterns
- `aimi-learnings-researcher` - Search .aimi/solutions/

### Design Agents

```javascript
Task({
  subagent_type: "aimi-engineering:design:aimi-figma-design-sync",
  description: "Sync with Figma",
  prompt: "Compare implementation with Figma design at [URL]"
})
```

### Workflow Agents

```javascript
Task({
  subagent_type: "aimi-engineering:workflow:aimi-bug-reproduction-validator",
  description: "Validate bug",
  prompt: "Reproduce and validate this reported bug: [description]"
})
```
