# Aimi Engineering

You describe what you want built. The plugin turns it into a plan, splits it into pieces that don't depend on each other, and runs them at the same time — each in its own isolated workspace, each with a fresh context.

At the end you review commits, not steps.

Works with [Claude Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai).

---

## Why this exists

A coding agent working straight through a feature keeps one context for the whole job. It fills up. By the third file the agent is carrying everything it read for the first two, and quality drops right when the work gets hardest.

This plugin changes the shape of that work:

- A feature becomes a **plan** — a set of stories, each small enough to finish in one context window.
- Stories that don't depend on each other run **in parallel**, each in its own git worktree.
- Each story gets a **fresh agent** that sees only that story. No leftovers from the last one.
- Results merge back branch by branch, so a failure blocks only what depended on it.

You stay out of the loop until there is something to review.

---

## Install

### Claude Code

No dependencies. The plugin is self-contained.

```bash
claude /plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
claude /plugin install aimi-engineering
```

Check it worked:

```bash
claude /plugin list
/aimi:init
```

### OpenCode

```bash
git clone https://github.com/aimi-so/aimi-engineering-plugin
cd aimi-engineering-plugin
./install.sh --to opencode
```

The installer rewrites commands, skills, and agents for OpenCode's structure. See [docs/opencode.md](docs/opencode.md) for what gets translated and the three features that behave differently there.

---

## First run

```bash
# 1. Work out what you're building (optional, but it makes the plan better)
/aimi:brainstorm Add user authentication with email and password

# 2. Turn it into a plan
/aimi:plan Add user authentication

# 3. Run it
/aimi:execute

# 4. Review what came out
/aimi:review
```

Step 2 writes `.aimi/tasks/YYYY-MM-DD-user-authentication-tasks.json`. That file is the whole state of the run — you can read it, edit it, and commit it.

Step 3 does the work. Watch or walk away.

---

## How the parallel part works

A plan is a graph, not a list. Stories with no unmet dependencies can start immediately; grouping by depth gives you **waves**.

```
  wave 1                    wave 2                wave 3
  ┌─────────────┐           ┌─────────────┐       ┌─────────────┐
  │   US-001    │           │   US-004    │       │   US-006    │
  ├─────────────┤   merge   ├─────────────┤ merge └─────────────┘
  │   US-002    │  ───────► │   US-005    │ ─────►
  ├─────────────┤           └─────────────┘
  │   US-003    │
  └─────────────┘

  one worktree per            each wave merges into
  story, all running          the feature branch before
  at the same time            the next one starts
```

Full detail in [docs/architecture.md](docs/architecture.md).

---

## Commands

| Command | What it does |
|---------|--------------|
| `/aimi:brainstorm` | Explore what to build, through guided questions |
| `/aimi:plan` | Turn a description into a tasks file |
| `/aimi:deepen` | Enrich an existing plan with research |
| `/aimi:status` | Show progress |
| `/aimi:next` | Run the next story, one at a time |
| `/aimi:execute` | Run everything autonomously |
| `/aimi:review` | Multi-agent code review |
| `/aimi:open-pr` | Open a pull request from the task branch |
| `/aimi:validate-bug` | Reproduce and confirm a bug report |
| `/aimi:init` | Prime the CLI path cache |
| `/aimi:setup-models` | Choose which model runs which agent category |
| `/aimi:learnings` | Triage friction the hooks recorded while you worked |

Each one in detail: [docs/commands.md](docs/commands.md).

---

## What's inside

| | Count | |
|---|---|---|
| Commands | 12 | Slash commands for each stage |
| Skills | 24 | Packaged conventions and workflows |
| Agents | 33 | 7 research, 15 review, 2 design, 8 workflow |

The full catalogue, with what each one is for: [docs/agents-and-skills.md](docs/agents-and-skills.md).

You can route each agent category to a different Claude model — research on one, review on another — with `/aimi:setup-models`.

---

## Documentation

| | |
|---|---|
| [Commands](docs/commands.md) | Every command, in detail |
| [Agents and skills](docs/agents-and-skills.md) | What each one does |
| [Task schema](docs/task-schema.md) | The tasks file format |
| [Architecture](docs/architecture.md) | Parallel execution, context handling, security |
| [OpenCode](docs/opencode.md) | Installing and running on OpenCode |
| [Troubleshooting](docs/troubleshooting.md) | When something goes wrong |

---

## Contributors

| | Contributions |
|---|---|
| **Aimi** ([@aimieacc](https://github.com/aimieacc)) | Core architecture, command pipeline, agent system |
| **Stanley Yoshinori Takamatsu** ([@stanleytakamatsu](https://github.com/stanleytakamatsu)) | Plugin design, execution model, review workflow |
| **Alex Chastinet** | Tooling fixes |

Full history on the [contributors graph](https://github.com/aimi-so/aimi-engineering-plugin/graphs/contributors).

Contributions are welcome. Open an issue before starting anything substantial, so the direction can be agreed before the work.

---

## License

MIT
