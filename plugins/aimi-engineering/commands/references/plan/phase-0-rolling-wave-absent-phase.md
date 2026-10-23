# Plan: Phase 0: Rolling-Wave Phase Selection, the ABSENT outcome

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

**The `ABSENT` outcome — offer to author the phase, or report and STOP**

`ABSENT` means the reader named a phase this roadmap does not carry, and two readings of that are possible: a typo, or a phase they intend to exist and have not written down yet. Only they can tell the two apart, so this outcome asks — in a picker session, and never in agent mode. `INTERACTIVE_MODE` is what separates them, and the steps below run in this order: validate the id first, then fork on the mode.

**Step 1 — validate the id against the CLI's own validator, before anything is offered to anyone.** The `case` gate above admits `02` and `09`; `_roadmap_validate_phase_id` in `aimi-cli.sh` does not, because every `--phase` consumer hands the id to `roadmap.py`, which reads it with `json.loads()`, and JSON has no `02`. On the `PRESENT` path that divergence is harmless — the id matches numerically and is canonicalized away by the working-memory extraction below. Here it is not, because this is the first place `PHASE_OVERRIDE` becomes a **write**: `--phase 09` would present the authoring question and then have the Yes refused by the CLI *after* the person had already answered it. Delegate to the verb that already validates, rather than copying its regex into this file:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_ID_PROBE_ERR=$($AIMI_CLI roadmap-get --feature "$featureSlug" --phase "$PHASE_OVERRIDE" 2>&1 >/dev/null)
if printf '%s' "$PHASE_ID_PROBE_ERR" | grep -qF 'must be a numeric phase id'; then
  echo "PHASE_ID_VERDICT=INVALID_ID" >&2
  exit 1
fi
echo "PHASE_ID_VERDICT=AUTHORABLE"
```

**Read the message, never the exit code.** Both refusals exit **1** and only stderr tells them apart — measured against this tree: `roadmap-get --feature <slug> --phase 09` answers `Error: roadmap-get: --phase <id> must be a numeric phase id`, while `--phase 9` against a roadmap that has no phase 9 answers `Error: roadmap-get: phase 9 not found in <path>`. Branching on the status would collapse the two into one outcome and hand a leading-zero typo the authoring question. `PHASE_ID_VERDICT=INVALID_ID` is the same class of refusal as `INVALID_SHAPE` above: compose it from the CLI's own stderr per the Adaptive Language Rule, name the value the person typed, and STOP. Only `PHASE_ID_VERDICT=AUTHORABLE` — the legitimately absent phase — reaches Step 2.

**Step 2 — agent mode: agent-mode never authors a phase.** When `INTERACTIVE_MODE=agent`, or `--non-interactive` was passed: present nothing. Emit exactly one log line naming the requested id and the feature — `agent-mode: phase [PHASE_OVERRIDE] absent from [featureSlug]'s roadmap — not authored` — and STOP the entire `/aimi:plan` invocation. The reason is already established two branches below, where a bare invocation with no eligible phase is forbidden from falling through to the flat pipeline because that silently writes an unrelated top-level tasks.json nobody reviewed. A phase authored with no reviewer is the same class of artifact and worse: it mutates shared state that a later `/aimi:plan` and a concurrent `/aimi:execute` both read.

**Step 3 — picker mode: one AskUserQuestion.** Present exactly one AskUserQuestion, naming the requested id and `featureSlug`, with two options — the same compact two-option shape the `### Scope-Context Classification (Inline Fallback)` gate below uses, and for the same reason: this is a recovery fork, not the primary surface for authoring a phase cut.

```
Author it — add phase <id> to <featureSlug>'s roadmap and expand it now
Stop — leave the roadmap unchanged
```

Compose the question in the reader's own language per the Adaptive Language Rule referenced at the top of this section — `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`, where the `${CLAUDE_PLUGIN_ROOT}` prefix is required because it is the only form `install.sh` rewrites to `${AIMI_PLUGIN_DIR}` for OpenCode. Both option labels are shapes, not strings.

**Step 4 — on Stop.** Fall through to the report this outcome already had — `Phase [PHASE_OVERRIDE] not found in [featureSlug]'s roadmap.` — and STOP. Nothing is written.

**Step 5 — on Author it.** Collect four fields for the new phase and no others:

- `name` — a short phase name.
- `goal` — the one-sentence outcome this phase delivers.
- `successCriteria` — the list the phase is judged against; an empty list is allowed and stays `[]`.
- `dependsOn` — the phase ids this one waits on. Every entry must be an id already present in `ROADMAP_JSON`; an empty list is allowed, and a decimal phase inserted mid-roadmap usually depends on the integer phase below it.

`id` is the `PHASE_OVERRIDE` the reader typed and is never renumbered. `slug` is neither asked for nor hand-authored — the second step named below derives it. Nothing else is collected: `creates`, `needs` and `areas` default to `[]` exactly as the sanitizing step already specifies, and `status`, `claim` and `branch` belong to the CLI.

Then build that phase as ONE entry and re-enter, by name, the three steps `### Roadmap Materialization` above already carries. None of them is reimplemented here:

1. **`Sanitize every phase field`** — applied to the collected `name`, `goal` and `successCriteria` exactly as written there, including its rule that `id` and each `dependsOn` entry are numbers and never go through string sanitization, and its rule that an authored `slug` is discarded.
2. **`Derive and validate each phase's directory segment`** — this is what produces `slug`, from the sanitized `name`, and what falls back to the empty string when the composed `phase-<id>[-<slug>]` segment fails validation.
3. **`Detect existing roadmap.json and materialize`** — its `exists` branch is the one that fires, since a roadmap being targeted by `--phase` is on disk by definition. Hand the single entry over as `sanitizedPhases`, the one-element list those steps consume, and take that branch's repair-and-retry-once rule with it unchanged.

`roadmap-init --sync` is therefore the only writer on this path, and the properties this branch leans on are its own, measured rather than assumed: a decimal id joins at its numeric position rather than at the end (`1.1` lands between `1` and `2`), every phase id already in the file is left byte-for-byte unchanged, and a re-sync of the same entry reports zero added and rewrites nothing. No second write path is created here — no new verb, no new flag, and no Write or Edit tool call, which `guard-runtime-state.py` blocks for `roadmap.json` anyway and redirects at these same verbs.

**Step 6 — re-enter the ordinary selection.** Once the write succeeds, go back to `#### Load the roadmap and ask the CLI which phases may be expanded` above and run this override path again from its top with the same `PHASE_OVERRIDE`; the id is now `PRESENT` and is selected by the ordinary path. Do not fabricate `SELECTED_PHASE_JSON` from the entry just authored — the same reason the `PRESENT` bullet takes the phase out of `ROADMAP_JSON` rather than out of the verdict record: `slug`, `dir`, `goal`, `areas` and `creates` are what the working-memory extraction below reads, and `dir` and `slug` exist only as the CLI computed them. Re-enter once, not in a loop: an id still `ABSENT` after a write the CLI reported as successful is a genuine failure — surface the CLI's own output and STOP.

**What this branch deliberately does not do.** It does not re-run `### Scope-Context Classification (Inline Fallback)` below, and that subsection's *Additional guard* gains no exception for a phase authored here. The guard skips because that pass proposes a whole new phase cut, which is exactly what conflicts with a roadmap that already exists — and a phase the reader just authored does not change that, since running the classifier would propose a competing cut of the entire feature. What the new phase needs is a `goal` and `successCriteria`, and Step 5 collects both.
