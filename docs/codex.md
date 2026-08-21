# Codex

The repository is a native Codex marketplace. Its Codex manifest lives at `plugins/aimi-engineering/.codex-plugin/plugin.json`; the marketplace catalogue is `.agents/plugins/marketplace.json`.

## Install

```bash
codex plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
codex plugin add aimi-engineering@aimi-marketplace
```

For a local checkout, replace the GitHub URL with the repository directory. Restart Codex after installing or upgrading, and review and trust the plugin hooks when Codex asks. The runtime requires Git, Bash, `jq`, and Python 3.10 or newer.

To upgrade later:

```bash
codex plugin marketplace upgrade aimi-marketplace
```

## Run workflows

Codex presents Aimi commands as explicitly invoked skills. Replace the Claude-style `/aimi:` prefix with `$aimi-`:

| Claude Code | Codex |
|---|---|
| `/aimi:brainstorm` | `$aimi-brainstorm` |
| `/aimi:plan` | `$aimi-plan` |
| `/aimi:deepen` | `$aimi-deepen` |
| `/aimi:status` | `$aimi-status` |
| `/aimi:next` | `$aimi-next` |
| `/aimi:execute` | `$aimi-execute` |
| `/aimi:review` | `$aimi-review` |
| `/aimi:open-pr` | `$aimi-open-pr` |
| `/aimi:validate-bug` | `$aimi-validate-bug` |
| `/aimi:init` | `$aimi-init` |
| `/aimi:setup-models` | `$aimi-setup-models` |
| `/aimi:learnings` | `$aimi-learnings` |

The six design commands follow the same rule, such as `/aimi:design:shape` becoming `$aimi-design-shape`.

The source commands and agent definitions remain authoritative. `scripts/build-codex-skills.py` generates their Codex adapters alongside the portable skills under `skills/`; `codex/generation-manifest.json` records the generated set. Contributors should run the generator after changing either source surface and commit the result.

## Models and MCP

`$aimi-setup-models` stores Codex-specific routing without overwriting Claude Code or OpenCode settings. The built-in Codex choices are `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5`, and `gpt-5.4`.

The Context7 MCP server is declared in the Codex plugin manifest and becomes available with the plugin.

## Hooks and compatibility

Codex discovers `hooks/hooks.json` from the plugin. Bash safety guards, runtime-state protection, session initialization, prompt capture, read tracing, and permission-time approval of narrowly whitelisted Aimi CLI commands are shared with Claude Code.

Codex does not expose Claude Code's `Skill` tool hook event. The four hook handlers whose matcher is `Skill` therefore do not receive automatic skill-entry and skill-exit telemetry on Codex. This affects friction telemetry and nested-skill bookkeeping, not task planning, execution, worktree isolation, review, or the safety guards on Bash and file writes.

Generated adapters set `AIMI_HOST=codex` on Aimi CLI calls so model configuration remains host-specific. They preserve references to `/aimi:…` in explanatory text when that text describes the portable workflow; invoke the `$aimi-…` skill name at the Codex prompt.
