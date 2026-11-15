# Usage Validation

Plugin development notes, moved out of `plugins/aimi-engineering/CLAUDE.md` so that file loads whole. Read this when you change the usage-validation gate: its two step files, its environment and loop entries, its verbs, its agent, or the records it leaves in `roadmap.json` and `tasks.json`.

The gate judges delivered work by using it. After a run's stories have merged, the product that was built is brought up from a recipe a person confirmed, and a validator agent walks it as a person would, with proof for everything it reports. A run whose surface fails that walk is not offered for publishing until the findings are resolved.

## Where it runs

| Run | Step file | Position |
|---|---|---|
| Phase mode | `commands/references/execute/phase-completion-usage-validation.md` | after the Phase Visual Gate, before Write Handoff |
| Flat run | `commands/references/execute/step-4-usage-validation.md` | after Finalize, before container teardown in Step 5 |

Teardown removes the worktree the validator drives, so a flat run validates before it. A flat run is also validated again when a failing run is re-executed with nothing left to execute (Step 3's Re-validate block); a phase is validated again on the next `/aimi:execute` of a phase whose stored status is `verification_failed`. Both read the stored record, and the findings a person accepted survive into the re-run, so an accepted decision is never asked twice.

Two shared entries sit under both step files: `usage-validation-environment.md` (recipe, bring-up, poll, origins, login and browser, tear down) and `usage-validation-loop.md` (validate, triage, decisions, fix round, outcome). A split phase or a multi-repository plan is validated like any other: `members` and `projects` in the answer are information only and never a reason to skip. In a spawned split run the parent validates once after the members merge, so a `phase-split-sub-orchestrator` skips all four entries and a `flat-split-child` skips the phase one (see `docs/dev/routers.md` § Execute Router Layout).

The loop runs at most two fix-and-re-validate rounds. A bug that a criterion or the spec states is fixed by an executor separate from the validator and only the fixed findings are re-checked. A finding that needs a decision is asked in picker mode and, in agent mode, is never accepted unattended: the run is left failing, the rule the visual gate already applies. The outcome comes only from `usage-validation-verdict`, never from the validator's own claim.

## Verbs

Every verb whose name carries `usage`, all dispatched from `scripts/aimi-cli.sh`. The four read-only ones are in the Pattern 2 whitelist of `hooks/auto-approve-cli.sh`; the five that run a recipe command or write state are not, and still prompt.

| Verb | Does | Writes | Module |
|---|---|---|---|
| `usage-recipe-record --project <key> (--serve <cmd> \| --cli <cmd>) [--setup <cmd>]... [--cleanup <cmd>]... [--port <n>] [--ready <url>] [--login none\|manual] [--login-url <url>] [--browser agent-browser\|chrome] [--external-services <text>]` | Records how a person confirmed the product comes up, at `usage.recipe[<key>]` of `.aimi/config.json`, inside the lock `deps-recipe-record` takes | `.aimi/config.json` | `usage_recipe.py` |
| `usage-recipe-get --project <key>` | Reads that recipe; `recorded` or `absent`. Refuses without `python3`, since an `absent` that is only a missing interpreter would skip validation as if the person had declined | nothing | `usage_recipe.py` |
| `usage-env-up --run <key> --repo <project>[=<branch>]... [--restart]` | Brings the product up from the recipe, detached, one entry per repository | run state under `.aimi/` | `usage_env.py` |
| `usage-env-status --run <key> [--wait <0-60>]` | Reports whether the run's processes answer | nothing | `usage_env.py` |
| `usage-env-down --run <key>` | Stops what `usage-env-up` started and runs the recipe's cleanup | run state under `.aimi/` | `usage_env.py` |
| `usage-validation-required (--feature <slug> --phase <id> \| [--tasks-file <path>])` | Whether validation is owed, with surfaces, charters, specs and, when it is not, the skip kind and reason | nothing | `usage_validation.py` |
| `usage-validation-verdict --required-file <path> --evidence-dir <dir> [--reproduced <key>]... [--accepted <key>]...` | The gate outcome of one validation, from the validator's last `usage_validation_verdict` block on stdin, the required answer and the evidence directory. Every outcome, `tooling-failed` included, is an answer at exit 0 | nothing | `usage_validation.py` |
| `usage-validation-record --status <passed\|failing\|skipped> [--kind <kind>] [--reason <text>] [--review <path>] [--rounds <n>] [--findings-json <json>] [--tasks-file <path>]` | Writes the flat run's `metadata.usageValidation`; refused on a phase-scoped tasks file | the tasks file | `tasks.py`, `usage_record.py` |
| `roadmap-record-usage-validation --feature <slug> --phase <id> --status <passed\|failing\|skipped> [--kind <kind>] [--reason <text>] [--review <path>] [--rounds <n>] [--findings-json <json>]` | Writes a phase's `usageValidation` into `roadmap.json` | `roadmap.json` | `roadmap.py`, `usage_record.py` |

`usage-validation-required` refuses without `python3`: a gate that cannot evaluate must not degrade into an answer. Its decision is a fixed ladder, first match wins, taken after surfaces and charters are built from every readable member so that a skipped answer still names what stayed unvalidated:

1. `AIMI_USAGE_VALIDATION=off` is `disabled-by-operator`.
2. No readable tasks file is `unable-to-evaluate`.
3. No declared surface is `not-applicable` (an unreadable member makes it `unable-to-evaluate`).
4. A surface whose project has no recorded recipe is `unable-to-evaluate`.
5. Otherwise validation is required.

## The records

A record is `{status, kind?, reason?, review?, rounds, findings?, recordedAt}`. `status` is `passed`, `failing` or `skipped`; `kind` is present only with `skipped` and is one of the three skip kinds below; `reason` is required with `failing` and `skipped`. `findings` maps a key `<charterId>:<step>:<heuristic>` to `{status: open|fixed|accepted, reason?}` (an accepted entry needs a reason). Every write replaces the whole object, except that the previous record's `accepted` findings the call does not restate are carried over. Both writers apply the same vocabulary before the document is read, so a refusal never opens the file. That vocabulary, its checks and the build of a record live once, in `scripts/usage_record.py` (`parse_request`, `build_record`), which imports only the standard library and `sanitize.py`; each writer only reads its document, finds the stored record and writes what `build_record` returns.

The record lives in two places by scope: `phases[].usageValidation` in `roadmap.json` for a phase (`docs/dev/roadmap.md`), and `metadata.usageValidation` for a flat run (`docs/dev/tasks-schema.md`). `metadata.usageSurfaces`, the surfaces the plan declared, is written by `/aimi:plan` (`commands/references/plan/phase-4-usage-surfaces.md`).

## The skip kinds

A skip is never a pass and always says why.

- **`not-applicable`**: the run delivered nothing a person or an agent can use. When the plan declared no surface and the answer's `askUndeclared` is true, picker mode asks once whether a surface exists that the plan never declared; a stored `skipped` record answers that already.
- **`unable-to-evaluate`**: a surface exists and the check could not be made: no recipe, an unreadable tasks file, an environment that did not come up, a charter blocked by a login the saved session does not give, a verdict the verb could not read.
- **`disabled-by-operator`**: `AIMI_USAGE_VALIDATION=off` in the environment, which records `disabled-by-operator`. It is never asked about.

## The agent

`agents/review/aimi-usage-validator.md` runs on the review model category (`AGENT_MODELS.review`) and walks each charter as a persona, one cognitive-walkthrough step per acceptance criterion, then an exploratory pass bounded by action counts. It never edits the repository. Every finding rated 3 or 4 cites an evidence file saved under the evidence directory; an observation with no artifact is rated 2 at most. Severity is Nielsen's 0 to 4 and 3 and 4 block.

It ends its message with one fenced block tagged `usage_validation_verdict`: `charters`, `findings`, `origins`, `exploratoryActions` and an optional `summary`, with no `verdict` key, because the caller computes the outcome. The agent declares `tools` explicitly, including the `mcp__claude-in-chrome__*` pattern; on OpenCode the installer drops that pattern with a warning (see `docs/dev/routers.md`, the permission-block bullet of its OpenCode references allowlist section) and the agent falls back to `agent-browser`.

## The completed gate and what refuses downstream

`roadmap-set-status --status completed` refuses a phase that owes validation (the same predicate `usage-validation-required` answers) and carries no `passed` or `skipped` record, by `_completed_gate_usage_refusal` in `scripts/roadmap.py`. It refuses an unrecorded phase and a recorded `failing` with distinct wording, and a requirement that cannot be computed draws one advisory line rather than a refusal.

For a flat run, `archive-task` and the archivable predicate refuse a tasks file whose `metadata.usageValidation.status` is `failing` (`_usage_validation_failing` in `scripts/tasks.py`). Step 5 of `/aimi:execute` holds its publishing path on a stored `failing` record and `/aimi:open-pr` prints the stored verdict (Step 2g) without blocking.

## Answering `context-budget.md`, The Question Every New Gate Must Answer

`commands/references/context-budget.md` asks of every new gate whether what it measures has any relation to what it claims. For this one:

- **Measures:** whether the delivered surface, brought up from a person-confirmed recipe, completes each charter's acceptance criteria when driven as a person would, and the severity of every problem met on the way, each with a re-checkable artifact (screenshot, console or network line, command output with its exit code).
- **Claims:** that the product was used for real and that no major or catastrophic problem is left open.
- **Cannot evaluate:** a skipped verdict with its kind (`not-applicable`, `unable-to-evaluate` or `disabled-by-operator`), recorded with a reason and never read as a pass; a charter the validator could not walk is `blocked`, never `executed`, and a verdict that omits a planned charter does not pass.
- **Refused downstream:** `roadmap-set-status --status completed` refuses a phase that owes validation with no `passed` or `skipped` record, and Step 5 holds the push and the container steps on a `failing` record, so the record is unavoidable rather than optional.

## Tests

| Test | Pins |
|---|---|
| `scripts/tests/test_usage_recipe.py` | the recipe writer and reader |
| `scripts/tests/test_usage_env.py` | bring-up, status, tear down |
| `scripts/tests/test_usage_validation.py` | `usage-validation-required` and its skip ladder |
| `scripts/tests/test_usage_validation_verdict.py` | `usage-validation-verdict` |
| `scripts/tests/test_usage_validator_agent.py` | the agent file and its verdict block |
| `scripts/tests/test_usage_record.py` | the record rule both writers share (`usage_record.py`) |
| `scripts/tests/test_usage_validation_gate.py` | the completed gate, `archive-task` and the Step 5 hold |
| `scripts/tests/test_usage_validation_loop.py` | the loop entry |
| `scripts/tests/test_usage_validation_phase_step.py`, `scripts/tests/test_usage_validation_flat_step.py` | the two step files |
| `scripts/tests/test_plan_usage_surfaces.py` | the plan's surface declaration |
