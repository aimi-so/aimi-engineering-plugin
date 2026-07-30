# Running on OpenCode

The plugin ships from one source tree to two hosts. Claude Code reads the plugin directory as-is. OpenCode needs a translation step, which the installer performs.

---

## Install

```bash
git clone https://github.com/aimi-so/aimi-engineering-plugin
cd aimi-engineering-plugin
./install.sh --to opencode
```

This installs into OpenCode's global config directory, `~/.config/opencode/`.

Restart your shell afterward, or export the variable directly for the current session:

```bash
export AIMI_PLUGIN_DIR="$HOME/.config/opencode/plugins/aimi-engineering"
```

### Install into a project instead of globally

```bash
./install.sh --to opencode --project
```

Installs into `.opencode/` in the current project.

### See what it would do, without doing it

```bash
./install.sh --to opencode --dry-run
```

### Uninstall

```bash
./install.sh --uninstall --from opencode
```

---

## What the installer translates

It is not a file copy. Several things are rewritten so they work under OpenCode:

- **Commands** become nested directories — `commands/aimi/plan.md` — so they appear as `/aimi:plan`, `/aimi:execute`, and so on.
- **Command bodies** are rewritten: agent invocations use the Task tool, CLI path lookups use `OPENCODE_CONFIG_DIR`, and error messages point at the OpenCode installer rather than the Claude Code one.
- **Skills** are copied with their `SKILL.md` and reference files intact.
- **Agents** land in `~/.config/opencode/agents/aimi-*.md` with their model fields preserved.
- **Permissions** for autonomous Bash execution are configured in `opencode.json`.
- **Plugin source** — the CLI scripts and hooks — is copied to `~/.config/opencode/plugins/aimi-engineering/`.
- **The context7 MCP server** is added to `opencode.json`.
- **`AIMI_PLUGIN_DIR`** is written into your shell profile.

---

## What does not work the same

Three OpenCode gaps have workarounds rather than fixes.

**`disable-model-invocation` is not supported.** In Claude Code this flag stops the model from calling a command on its own. OpenCode has no equivalent, so the installer prepends a warning to command bodies telling the model not to invoke sub-agents autonomously. It is an instruction, not an enforcement.

**`AskUserQuestion` is not available.** Commands that would show a picker are rewritten to ask in plain conversation instead. You still get the question; you just type the answer rather than selecting it.

**Custom `subagent_type` is not supported.** Agents are installed as general-purpose, with the agent's own prompt inlined into the Task invocation. Behavior is preserved; the routing is not.

---

## `AIMI_PLUGIN_DIR`

Points at the installed plugin directory so commands can find the CLI scripts, skill references, and agent definitions.

The installer sets it. Do not set it by hand unless you have a custom layout — and note that inside Claude Code it is ignored entirely, because Claude Code resolves the plugin from its own cache instead.
