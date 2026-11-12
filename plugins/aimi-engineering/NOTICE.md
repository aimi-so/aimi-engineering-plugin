# NOTICE

Some agents in this plugin are adapted from the **compound-engineering-plugin** by Every (https://github.com/EveryInc/compound-engineering-plugin), licensed under the MIT License (the "License"). The text of the License is reproduced below. Skills that come from other projects carry their own `NOTICE.md` in their directory.

---

## compound-engineering-plugin

Copyright (c) 2025 Every

### Agents adapted from the plugin as it stood on 2026-02-13 (commit 134a994)

These were copied into this plugin on 2026-02-25 and have been edited since. The last column is the share of the text each still has in common with the original.

| Agent here | Original, under `plugins/compound-engineering/` | In common |
|---|---|---|
| `aimi-design-iterator` | `agents/design/design-iterator.md` | 93% |
| `aimi-design-implementation-reviewer` | `agents/design/design-implementation-reviewer.md` | 61% |
| `aimi-learnings-researcher` | `agents/research/learnings-researcher.md` | 72% |
| `aimi-best-practices-researcher` | `agents/research/best-practices-researcher.md` | 61% |
| `aimi-framework-docs-researcher` | `agents/research/framework-docs-researcher.md` | 54% |
| `aimi-codebase-researcher` | `agents/research/repo-research-analyst.md` | 47% |
| `aimi-bug-reproduction-validator` | `agents/workflow/bug-reproduction-validator.md` | 93% |
| `aimi-spec-flow-analyzer` | `agents/workflow/spec-flow-analyzer.md` | 91% |

`aimi-codebase-researcher` comes from the original `repo-research-analyst`.

### Review agents written from the plugin's current reviewer personas (checked 2026-11-12)

The nine review agents are written for this plugin from the reviewer personas in `skills/ce-code-review/references/personas/` of the same repository. They keep the personas' hunting lists in this plugin's own wording, change the output to the shape `/aimi:review` merges, and make them independent of language and framework. The last column is the share of the text each still has in common with its persona.

| Agent here | Persona | In common |
|---|---|---|
| `aimi-correctness-reviewer` | `correctness-reviewer.md` | 49% |
| `aimi-project-standards-reviewer` | `project-standards-reviewer.md` | 25% |
| `aimi-security-reviewer` | `security-reviewer.md` | 65% |
| `aimi-performance-reviewer` | `performance-reviewer.md` | 56% |
| `aimi-maintainability-reviewer` | `maintainability-reviewer.md` | 63% |
| `aimi-frontend-races-reviewer` | `frontend-races-reviewer.md` | 67% |
| `aimi-data-migration-reviewer` | `data-migration-reviewer.md` | 59% |
| `aimi-agent-native-reviewer` | `agent-native-reviewer.md` | 85% |
| `aimi-deployment-verification-agent` | `deployment-verification-agent.md` | 31% |

---

This NOTICE preserves the copyright and permission notice that the License requires for any redistributed copy or substantial portion of the licensed material.

## MIT License

Copyright (c) 2025 Every

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
