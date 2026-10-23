---
name: aimi:plan
description: Generate tasks.json directly from a feature description
argument-hint: "[feature description] [--non-interactive] [--phase <N>]"
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(mkdir:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Task
---

# Aimi Plan

Generate `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. Full pipeline: research, spec analysis, story decomposition, JSON output. No intermediate markdown plan.

By default, `/aimi:plan` runs in interactive mode — Open Question gates (Phase 0.5, Phase 1.8, Phase 1.9, Phase 2.5) present `AskUserQuestion` prompts. Pass `--non-interactive` to skip all prompts and auto-defer every Open Question (agent/CI mode).

## Phase Files

Most phases below are routers: a heading, an `Applies when:` condition evaluable from state this file already holds, and a `Read` line naming the phase's file under `${CLAUDE_PLUGIN_ROOT}/commands/references/plan/`. When the condition holds, Read that file in full before running the phase, and follow it as written. When it does not, skip the file and apply the default stated beside the condition, so every variable a later phase reads is still set. **When the conversation resumes after a context compaction, re-read the current phase's file before continuing.** Its text does not survive compaction; this router does.

Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Feature Description

The planning input is `$ARGUMENTS` with the `--non-interactive` token removed (see Step 0 below).

## Environment Variables

| Variable | Value | Effect |
|----------|-------|--------|
| `AIMI_PLAN_DEBUG` | `1` | Opt-in diagnostic output. When set, three decision points each emit a `[plan-debug] <phase>: <fired\|skipped> (reason: <...>)` line to chat at their own fire/skip decision point: Phase 1.9 (the Greenfield Foundation Gate), Roadmap Materialization (the `phases:` frontmatter parse), and Scope-Context Classification — Inline Fallback (Step 1's scope-context collapse). Unset (or any value other than `1`) produces no diagnostic output. Mirrors `brainstorm.md`'s `AIMI_BRAINSTORM_DEBUG` convention. |

## Step 0: Environment Setup

Applies when: every run; this is the first thing `/aimi:plan` does.
Covers: `### Resolve CLI Path`, `### Capture AIMI_ROOT`, `### Detect Git Repo Layout`, `### Fetch Origin & Detect Default Branch`, `### Parse --phase Override`, `### Detect Interactivity`, `### Resolve Agent Models`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/step-0-environment-setup.md in full.

## Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match on topic, within 14 days):

```bash
ls -t .aimi/brainstorms/*.md 2>/dev/null | head -10
```

- **If relevant brainstorm found:** Read it, use as context, skip questions.
- **If multiple match:** Ask user which to use.
- **If none found:** Ask refinement questions via AskUserQuestion until the idea is clear.

### Prototype Context

Applies when: a brainstorm was found and read above. When none was, skip this file: `reusedResearch`, `foundationProposalPath` and `prototypeTokens` stay unset, `brainstormBundleRoot` stays empty and no prototype is loaded from a brainstorm.
Covers: `### Reuse Brainstorm Research`, `### Reuse Brainstorm Foundation Proposal`, `### Reuse Brainstorm Design Bundle`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-brainstorm-reuse.md in full.

### Roadmap Materialization

Applies when: a brainstorm was loaded above (a `phases:` frontmatter key can exist only on a brainstorm document). When no brainstorm was found, this entire section is skipped with no log line: set the `roadmapMaterializationVerdict` working-memory variable to `not-run` (this gate's own trigger check, the `phases:` frontmatter parse, never evaluates this run) and proceed directly to Rolling-Wave Phase Selection below.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-roadmap-materialization.md in full.

### Rolling-Wave Phase Selection

Applies when: every run; it executes whether or not a brainstorm loaded this session, and it is what sets `ROADMAP_MODE` and `featureSlug`.
Covers: `#### Resolve `featureSlug` and detect roadmap mode`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-roadmap-mode-detection.md in full.

#### Load the roadmap and ask the CLI which phases may be expanded

Applies when: `ROADMAP_MODE=true`. When `ROADMAP_MODE=false` skip this file and every other Rolling-Wave file below.
Covers: `#### Select the target phase`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-rolling-wave-select.md in full.

**The `ABSENT` outcome — offer to author the phase, or report and STOP**

Applies when: `ROADMAP_MODE=true`, `PHASE_OVERRIDE` is non-empty, and the `--phase` override block ended with `PHASE_GATE_OUTCOME=ABSENT`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-rolling-wave-absent-phase.md in full.

**Bare invocation (no `--phase`):**

Applies when: `ROADMAP_MODE=true`; the bare-invocation branch runs only when `PHASE_OVERRIDE` is empty, and the sections after it run once a phase is selected.
Covers: `#### Extract selected-phase working memory`, `#### Pre-Expansion Contract Gate`, `#### Prior Phase Handoff Ingestion`, `#### Phase-Scoped Topic Slug`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-rolling-wave-bare-and-gates.md in full.

### Design Bundle Detection

Applies when: every run; it is what resolves `designBundleMeta` (null when no bundle is found).
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-design-bundle-detection.md in full.

### Bundle Prototype Auto-Generation

Applies when: `designBundleMeta` is non-null, or `$ARGUMENTS` contains the case-insensitive substring `render bundle`. Otherwise skip this file: `businessSpecPath` and `designSpecPath` are null and `businessSpecContent` and `designSpecContent` stay unset.
Covers: `### Phase-Tier Spec Detail Authoring`, `### Phase 0.7: Spec Ingestion`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-bundle-prototype-and-spec.md in full.

### Implementation Scope Detection

Applies when: every run; it is what sets `implementationScope`.
Covers: `### Frontend-Without-Prototype Warning (Advisory)`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-scope-detection.md in full.

### Scope-Context Classification (Inline Fallback)

Applies when: every run; the Classification Summary Line is emitted unconditionally, and the Inline Fallback decides its own skip inside the file.
Covers: `### Classification Summary Line`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-scope-context-classification.md in full.

### Phase 0.5: Open Questions Resolution Gate

Applies when: every run; the gate collects its own sources and auto-defers in agent mode.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-open-questions-gate.md in full.

### Issue Reference Confirmation Gate

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-0-issue-confirmation.md in full.

## Phase 1: Local Research (Parallel)

Applies when: every run.
Covers: `### Prepare Research Directory`, `### Derive Topic Slug`, `### Generate Run Discriminator`, `### Auto-Scan for Git Repos`, `### Extract Path Hints`, `### Phase-Scoped Research Reuse`, `### Run Research Agents`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-local-research.md in full.

### Confirm Each Research File Landed

Applies when: a Phase 1 or Phase 1.5b researcher Task was spawned this run (apply it once per researcher as that researcher's Task returns). When every research kind was reused, skip this file.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-landing-check.md in full.

### Bundle Researcher (Bundle-Direct Mode)

Applies when: `designBundleMeta` is non-null AND no brainstorm was loaded in Phase 0.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-bundle-researcher.md in full.

## Phase 1.5: Research Decision

- **High-risk** (security, payments, external APIs) → always run external research
- **Strong local context** → skip external research
- **Uncertainty** → run external research

Compute `researchDepth` and store in metadata: `skip` (internal + strong patterns), `quick` (solid patterns, minor uncertainty), `standard` (default), `deep` (security, payments, new tech, high uncertainty).

## Phase 1.5b: External Research (Conditional, Parallel)

Applies when: Phase 1.5 decided external research is needed (`researchDepth` is not `skip`).
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-5b-external-research.md in full.

## Phase 1.6: Research Consolidation

Applies when: every run.
Covers: `### Phase 1.6b: Research Conflict Escalation Gate`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-6-research-consolidation.md in full.

## Phase 1.7: Research File Ingestion

Applies when: `researchDepth` is `quick`, `standard` or `deep`. For `skip` or unset this phase is a no-op: proceed directly to Phase 2 with no change to Phase 1.6 output.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-7-research-ingestion.md in full.

## Phase 1.7b: Prior Planning Gaps Ingestion

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-7b-prior-planning-gaps.md in full.

## Phase 1.7c: Brainstorm Design Decisions Ingestion

Applies when: a brainstorm was loaded in Phase 0. When none was, skip this file: `designDecisionsBlock` is the empty string and you emit exactly one line, `[plan] design decisions: absent`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-7c-design-decisions.md in full.

## Phase 1.8: Post-Research Open Questions Gate

Applies when: every run.
Covers: `### Phase 1.8 Scope-Pruning-Negative Gate`, `### Phase 1.8 Scope-Pruning-Positive Gate`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-8-open-questions-and-scope-gates.md in full.

## Phase 1.9: Greenfield Foundation Gate

Applies when: every run; Step 1 decides whether the gate fires for any root.
Covers: `### Step 1: Fire-Condition Check`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-9-foundation-conditions.md in full.

### Steps 2–5 Run Once Per Firing Root

Applies when: Step 1 left at least one root for which condition (c) held globally, condition (a) held, and condition (d) did not already resolve it through its reuse path. When no root fires, skip this file and the next.
Covers: `### Step 2: Architect Spawn`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-9-architect-spawn.md in full.

### Step 3: Non-Interactive Fast Path

Applies when: the same condition as the architect spawn above (at least one root fired).
Covers: `### Step 4: Interactive Gate`, `### Step 5: Recording the Decision`.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-1-9-decision-and-recording.md in full.

## Phase 2: Spec Analysis

```
Task subagent_type="aimi-engineering:workflow:aimi-spec-flow-analyzer"
  [model: <AGENT_MODELS.workflow when not "inherit">]
  prompt: "Analyze this feature specification for flow completeness, gaps, and edge cases:
           Feature: [feature description]
           Context from research: [consolidated research summary]
           Identify: user flows, edge cases, missing requirements, security concerns."
```

Incorporate gaps as acceptance criteria or story notes.

## Phase 2.4: Codebase Cross-Check

Applies when: every run; the phase decides its own skip inside the file.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-2-4-codebase-cross-check.md in full.

## Phase 2.5: Spec-Flow Gap Gate

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-2-5-spec-flow-gap-gate.md in full.

## Phase 3a: Run Setup

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3a-3b-setup-and-outline.md in full.

## Phase 3b: Pass 1 — Outline Generation

Applies when: every run; the Phase 3a file holds it.

## Phase 3c: Outline Gate

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3c-outline-gate.md in full.

## Phase 3d: Pass 2 — Parallel Story Expansion

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d-prep-blocks.md in full.

### Per-Entry View-Scoped Prototype Block Preparation

Applies when: `resolvedPrototypePaths` holds at least one `.html` path; otherwise skip, with no prototype slicing.
Before running this phase (prototypes present), Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d-prototype-blocks.md in full.

### Sub-Agent Prompt Template

Applies when: every run; holds the expander spawn prompt.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d-expander-prompt.md in full.

### Schema Validation and Retry

Applies when: every run, after the expanders return.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d-validate-retry.md in full.

## Phase 3d.5: Cross-Story DAG Audit

Applies when: `RUN_DIR` holds 2 or more `NN-*.json` staging files; otherwise skip this file and the next, log `[plan] Phase 3d.5 skipped: fewer than 2 stories expanded`, go to Phase 3e.
Before running this phase (fewer than 2 staging files: skip), Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d5-audit-spawn.md in full.

### Persist audit-result.json

Applies when: the audit above ran.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3d5-audit-apply-gate.md in full.

## Phase 3e: story-merge Invocation

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-3e-story-merge.md in full.

## Phase 4: Metadata Patch

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-metadata-identity.md in full.

### Derive and Patch Metadata Fields, continued

Applies when: every run, after the identity fields.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-metadata-context.md in full.

### Schema v3.3 Structure

Applies when: every run; holds the frontend-only backendSpec derivation.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-schema-v33.md in full.

### responseShape contract (frontend-only mode)

Applies when: `implementationScope` is `frontend-only`; otherwise skip.
Before running this phase (frontend-only), Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-response-shape.md in full.

### Checklist Before Phase 4.5

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-checklist.md in full.

## Phase 4.5: Post-Generation Validation

Applies when: every run.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-45-validation.md in full.

## Step 4.6: Research GC (advisory, non-fatal)

Applies when: every run, after Phase 4.5 passes.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/step-46-5-report.md in full.

## Step 5: Aimi-Branded Report

Applies when: every run; the Step 4.6 file holds it.

## Error Handling

Applies when: any step above fails or refuses.
Before running this phase, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/error-handling.md in full.
