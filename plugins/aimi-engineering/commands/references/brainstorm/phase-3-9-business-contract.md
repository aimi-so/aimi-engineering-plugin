# Brainstorm: Phase 3.9: Business Contract Authoring

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 3.9: Business Contract Authoring

This is a **gate** that authors the feature's `BusinessSpec.md` so `/aimi:plan` always has a business contract to decompose against, with or without a detected Claude Design bundle. The questionnaire, propose-then-correct flow, absent-vs-unchecked rules and write procedure live in `${CLAUDE_PLUGIN_ROOT}/commands/references/business-spec-authoring.md`; read it on demand when the gate fires and follow it, rather than restating it here.

### Step 1: Fire/Skip Conditions

Evaluate in order; the first match decides. Set the `phase39Verdict` working-memory variable to `fired` or `skipped` (parity with the other gates; Phase 3.8's line does not read it).

1. **Non-app feature:** `$FEATURE_DESCRIPTION` matches the non-app keyword rule in `commands/plan.md` § Implementation Scope Detection with no app signal present. Skip silently: no log line, no artifact.
2. **Bundle already has a BusinessSpec:** `bundleDetected=true` and the `businessSpec` field of `bundlePayload` is non-null. Skip with exactly one log line naming that path: `business-contract-authoring skipped (bundle already carries a BusinessSpec: <path>)`. No directory is created.
3. **Ambiguous bundle in agent mode:** `BUNDLE_STATUS=3` and `INTERACTIVE_MODE=agent`. Skip with exactly one line: `agent-mode: business-contract-authoring skipped (ambiguous bundle detection unresolved — re-run with --bundle <path> to choose one)`.

Otherwise the gate fires.

### Step 2: Derive Repository Facts

Spawn the deriver with the entity and endpoint names the description mentions as `targets`:

```
Task subagent_type="aimi-engineering:research:aimi-spec-deriver"
  [model: <AGENT_MODELS.research when not "inherit">]
  [effort: <AGENT_EFFORTS.research when not "inherit">]
  prompt: "repoRoot: <absolute project root>
           targets: <entity and endpoint names from the feature description>
           context: <one-paragraph summary of the feature>"
```

Save the returned `spec_derivation` JSON to `.aimi/design-bundles/<topic-slug>/spec-derivation.json`, then render it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI spec-derivation --input ".aimi/design-bundles/<topic-slug>/spec-derivation.json"
```

### Step 3: Author the Bundle

Follow the reference's questionnaire and propose-then-correct flow. Core vs per-phase: when Phase 3.5 settled a phase cut (`phase35Verdict=fired`), the per-phase sections carry only the reference's deferred marker line; otherwise they are authored in full. Write `project/BusinessSpec.md` under `.aimi/design-bundles/<topic-slug>/` and a `README.md` carrying `AIMI_GENERATED_MARKER` at the bundle root (the reference's write procedure says how the marker is read; never retype it). Set `businessContractBundlePath` to `.aimi/design-bundles/<topic-slug>` and `businessContractBusinessSpecPath` to `.aimi/design-bundles/<topic-slug>/project/BusinessSpec.md`.

Artifact language: see `commands/references/user-communication.md` (§ Artifact Language Rule).

*Agent mode:* log exactly one line, `agent-mode: business-contract-authoring wrote <path> (<N> open questions)`.
