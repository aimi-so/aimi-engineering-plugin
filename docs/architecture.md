# Architecture

How the plugin keeps context clean, runs work in parallel, and stays safe with generated content.

---

## The pipeline

```
/aimi:brainstorm → /aimi:plan → /aimi:deepen → /aimi:execute → /aimi:review
                                  (optional)
```

Brainstorm decides *what*. Plan decides *how* and writes it down. Execute runs it. Review checks it.

---

## How parallel execution works

This is the part that is hard to picture, so here it is concretely.

A plan is a graph, not a list. Stories that depend on nothing can start immediately; stories that depend on others wait. Grouping by depth in that graph produces **waves**.

```
  tasks.json
      │
      ▼
  dependency graph  ──►  waves
      │
      ▼

  wave 1                    wave 2                wave 3
  ┌─────────────┐           ┌─────────────┐       ┌─────────────┐
  │   US-001    │           │   US-004    │       │   US-006    │
  ├─────────────┤   merge   ├─────────────┤ merge └─────────────┘
  │   US-002    │  ───────► │   US-005    │ ─────►
  ├─────────────┤           └─────────────┘
  │   US-003    │
  └─────────────┘

  one git worktree           each wave merges
  per story, running         into the feature
  at the same time           branch before the
                             next one starts
```

Within a wave, every story gets its own git worktree and its own agent with a fresh context. They do not see each other's work and cannot collide. When the wave finishes, its branches merge into the feature branch, and the next wave starts from that merged state.

If a story fails, everything that depended on it is cascade-skipped rather than run against a broken foundation.

---

## One story at a time in context

Commands call `aimi-cli.sh` to pull exactly what they need, instead of loading the whole tasks file into the conversation.

```bash
AIMI_CLI=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/aimi/cli-path")

$AIMI_CLI init-session   # feature metadata only
$AIMI_CLI next-story     # exactly one story
$AIMI_CLI status         # progress summary
```

Centralizing these operations in a script has a second benefit beyond context size: the model never has to write the `jq` itself, so it cannot get it subtly wrong.

---

## Fresh context per story

Each spawned agent starts empty:

- No memory carried over from the previous story
- The full context window available for the current one
- Anything worth keeping goes into `CLAUDE.md` or `AGENTS.md`, not into the conversation

This is why story sizing matters. A story that does not fit in one context window cannot be executed this way.

---

## Per-category model configuration

The four agent categories — research, review, design, workflow — can each run on a different Claude model.

```bash
/aimi:setup-models
```

That writes `~/.config/aimi/models.json`. The file maps each category to a logical tier, then resolves tiers to concrete model ids per host (`claudeCode`, `opencode`).

On Claude Code the resolved model is passed through the Task tool's `model:` parameter. On OpenCode the `aimi-task` tool provides the equivalent. Run `aimi-cli resolve-models` to see what a category resolves to right now.

---

## Project guidelines discovery

Agents pick up your conventions automatically, in this order:

1. **`CLAUDE.md`** at the project root — project-wide conventions
2. **`AGENTS.md`** in any directory — rules for that module
3. **Plugin defaults** — commit and PR conventions, used only when the first two say nothing

Files under 2 KB are inlined into the agent's prompt. Larger ones are referenced by path so the agent reads only what it needs.

---

## Where files live

```
.aimi/
├── brainstorms/     design documents from /aimi:brainstorm
├── research/        findings from research agents
├── tasks/           the tasks file — all execution state
├── known-gaps/      things a story could not finish, recorded
└── solutions/       past solutions, searchable by later runs
```

---

## Security

Story content is generated text. It is treated as untrusted input, because it is.

### Path traversal

Blocked before any file operation:

- `..` sequences
- Absolute paths
- Protocol prefixes such as `file://` and `http://`
- Sensitive locations — `.git/`, `.env`, `.ssh/`

### Command injection

Blocked in story content:

- Chaining operators `&&`, `||`, `;`
- Redirects `>`, `<`, `>>`
- Command substitution `$()` and backticks
- Pipes

### Prompt injection

Blocked in any field an agent will read:

- Instruction-override phrasing
- Role manipulation
- Attempts to extract the system prompt

### Branch names

Must match:

```
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

Spaces, semicolons, and quotes fail validation rather than being escaped. A name that cannot be validated is refused, never rewritten into something that merely looks safe.
