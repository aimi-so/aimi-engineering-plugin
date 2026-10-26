# Plan: Phase 4: Schema v3.3 structure

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Derive `metadata.backendSpec` (frontend-only mode only)

**When `businessSpecPath` is non-null** (spec-driven path — takes precedence over inference):
- `endpoints`: populate from `BusinessSpec § 5`. Every entry MUST carry a `source` field matching `"BusinessSpec § N[.N] L<line>"`. Every `responseShape` field MUST also carry a `source`. Do NOT invent fields absent from the spec — emit a `gate` of type `decision` on the story instead.
- `dataModels`: populate from `BusinessSpec § 4`. Every entry MUST carry a `source` field.
- `businessRules`: populate from `BusinessSpec § 3`.
- `businessContext.userRoles`: populate from `BusinessSpec § 7`.
- `businessContext.successCriteria`: populate from `BusinessSpec § 9`.
- `businessContext.summary`, `businessContext.constraints`, `businessContext.assumptions`: derive from spec context.

**When `businessSpecPath` is null** (inference fallback):
- `endpoints`: array of `{ method, path, description }` — API contracts implied by UI interactions.
- `dataModels`: array of `{ name, fields }` — data structures implied by forms and displays.
- `businessRules`: array of strings — validation rules and business logic from acceptance criteria.
- `businessContext`: object with `summary`, `userRoles`, `constraints`, `assumptions`, `successCriteria` derived from story content.

### `dependsOn` Inference Rules (for reference — applied by sub-agents in Phase 3d)

- **Same layer, independent concerns** → no dependency (`dependsOn: []`)
- **Same layer, shared concern** (FK referencing another story's table, component extending another) → add dependency
- **Cross-layer**: backend depends on schema stories it reads/writes; UI depends on backend it calls; aggregation depends on what it consumes
- **Skip layers when appropriate**: UI reading directly from a new table depends on the schema story, not a non-existent backend story

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

### Schema v3.3 Structure

```json
{
  "schemaVersion": "3.3",
  "metadata": {
    "title": "string (required)",
    "type": "feat|ref|bug|chore (required)",
    "branchName": "string (required, regex: ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$)",
    "createdAt": "YYYY-MM-DD (required)",
    "baseRef": "string (optional, 40-char commit SHA this file's stories were planned against — git rev-parse HEAD in the repository they target; on a PROJECT-axis split each file carries its own repo's SHA; omitted entirely when no repository root resolves or the command fails)",
    "pluginVersion": "string (optional, the plugin version that wrote this file — what aimi-cli.sh version printed for the install that ran /aimi:plan; one shared value patched identically into every file of a split, never resolved per file; omitted entirely when that verb fails or prints nothing)",
    "issues": "number[] (optional, the forge-confirmed issue numbers this plan closes — positive integers in ascending order, written from the Issue Reference Confirmation Gate's confirmedIssues[]; one shared value patched identically into every file of a split; omitted entirely when nothing was confirmed, never [] and never null)",
    "finalize": "object (optional, {intent, files[], commitSubject} — the round's single end-of-round step, the one commit no story can structurally make; files[] is a non-empty array of strings naming the paths no story should declare, and validate-tasks warns when a story's implementation.files claims one of them; a present-but-incomplete object is an error; resolved per repository on a split — one per entry on the PROJECT axis, the backend file alone on the SIDE axis — never shared across repositories; omitted entirely when the round declares no final step, never null and never {})",
    "planPath": "null (always null for planner-generated)",
    "roadmapPath": "string (optional, present only when this phase was expanded via Rolling-Wave Phase Selection; relative path to the feature's roadmap.json)",
    "phase": {
      "id": "number (optional, present only in rolling-wave mode; the selected phase's numeric id)",
      "dir": "string (optional, present only in rolling-wave mode; the phase-<id>[-<slug>] directory segment)"
    },
    "brainstormPath": "string (optional)",
    "researchDepth": "skip|quick|standard|deep (optional, computed in Phase 1.5)",
    "researchPaths": "string[] (optional, relative paths to research files written by Phase 1 and Phase 1.5b agents, plus every foundation proposal Phase 1.9 accepted — one per accepted root)",
    "prototypePaths": "string[] (optional, relative paths to prototype HTML files and tokens sidecar JSON registered by Phase 0 Prototype Context)",
    "prototypeDropped": "object[] (optional, one entry per wrapped prototype block that was removed rather than sliced — each entry {path, reason, bytes}: path relative to AIMI_ROOT, reason a non-empty string naming why (aggregate-cap from Phase 0's aggregate prototype drop cap, or no-view-anchors from Phase 3d's view-slicing no-anchor degradation), bytes the size weighed by whichever writer recorded it; the complement of prototypePaths above, so a plan written from a filename alone is distinguishable from one written from the file; one shared value patched identically into every file of a split. Omit the key entirely when nothing was dropped, never [] and never null)",
    "prototypeSuperseded": "object[] (optional, entries {path, decision, note}: path of a prototype in prototypePaths, decision the oqDecisions anchor that supersedes part of what it depicts, note sanitized; omit the key entirely when empty, never [] and never null; one shared value patched identically into every file of a split)",
    "designBundle": {
      "root": "string (relative path to bundle root dir)",
      "readme": "string (relative path to bundle README)",
      "chats": ["string (relative paths to chat export files)"],
      "businessSpec": "string|null (relative path to BusinessSpec.md, or null when absent)",
      "designSpec": "string|null (relative path to DesignSpec.md, or null when absent)"
    },
    "designTokens": "object (optional, flat token map parsed from DesignSpec § 1; keys are token categories e.g. color, typography, spacing, radii, shadow, transition; values verbatim from spec)",
    "decisions": [
      {
        "anchor": "string (unique key, one of: <brainstorm-path>:L<line> | businessSpec:L<line> | designSpec:L<line> | researchFile:<basename>:OQ<n> | specFlow:CriticalQ<n> | specFlow:Gap<n> | scopeNeg:<entity-slug> | scopePos:<entity-slug> | outline:edit:<idx> | outline:edit:reorder)",
        "source": "string (one of: <brainstorm-path>:L<line> | businessSpec:L<line> | designSpec:L<line> | researchFile:<basename>:OQ<n> | specFlow:CriticalQ<n> | specFlow:Gap<n> | scopeNegVerifier | scopePosVerifier | codebaseVerified | outline — for outline-gate edits recorded in Phase 3c)",
        "text": "string (the OQ text or the trimmed line containing the marker, or description of the outline edit)",
        "resolution": "string (the user's choice, or '[deferred]')",
        "evidence": "string (optional; serialized form `evidence: <class>:<path>:<line>,<class>:<path>:<line>,...`; present only when source=codebaseVerified; comma-separated '<classification>:<path>:<line>' entries from Phase 2.4's per-root grep, truncated to 2000 chars with '…' appended when truncation fires)"
      }
    ],
    "maxConcurrency": "number (optional, default 20)",
    "execution": "container|inline (optional; flat files only — /aimi:plan writes 'container' explicitly into every freshly generated flat file and omits the key entirely on phase-scoped files; /aimi:execute --container/--inline and /aimi:next --container/--inline can override and persist a flat file's value later — see commands/references/execution-mode.md for the full read/override contract)",
    "frontendOnly": "boolean (optional, true when frontend-only scope)",
    "splitGroup": {
      "project": "string (optional object, PROJECT-axis split files only — written by story-merge, preserved verbatim by Phase 4; this file's own project routing key, e.g. 'apps/web', or '.' for the root group)",
      "index": "number (1-based position of this file among the split's output files)",
      "total": "number (count of files the PROJECT-axis split produced)",
      "siblings": ["string (paths of the other total−1 files in the same split)"]
    },
    "smellWarnings": "array (optional; three entry shapes: {type: \"orphan-symbol\", storyId, symbols, message} written by story-merge Phase 4.2; {type: \"cross-file-dep-dropped\", storyId, side, becameRoot, droppedDeps: [{id, side, title}], message} — SIDE axis, written by _story_merge_write_split when --split full-stack drops an edge across the frontend/backend boundary (single-repo/monorepo layouts); and {type: \"cross-file-dep-dropped\", storyId, project, becameRoot, droppedDeps: [{id, project, title, foundationEdge}], message} — PROJECT axis, written by _story_merge_write_project_split when --split full-stack drops an edge across a repo boundary (2+ distinct .project values), where project is the owning group's routing key and foundationEdge marks a dropped edge whose target is a story --foundation named in any project group — necessarily hand-authored, since injection is per group and the writer can never drop an injected edge. and six advisory shapes written by story-merge, {type: \"field-overlap\", storyId, ratio, ngram, message} (tasks[] restates implementation.approach), {type: \"story-oversize\", storyId, bytes, medianBytes, floorBytes, message} (the story serializes far above the plan median or the byte floor), {type: \"audit-duplication\", storyId, ratio, ngram, message} (an audit patch changed both tasks and implementation.approach and tasks[] now restates the approach), {type: \"stale-sibling-note\", storyId, cited, message} (an older notes paragraph cites another story of the plan), {type: \"leftover-outline-token\", storyId, fields, message} (an outline: token survived the remap in a string field other than dependsOn) and {type: \"ac-test-enumeration\", storyId, index, count, message} (an acceptance criterion lists three or more distinct tests). side and project are mutually exclusive per entry — see Step 5 renderer below for all cases; absent when no smell is detected)",
    "backendSpec": {
      "endpoints": [
        {
          "method": "string",
          "path": "string",
          "description": "string",
          "source": "BusinessSpec § N[.N] L<line> (required when businessSpecPath non-null; or 'derived: <explanation>' for computed endpoints)",
          "responseShape": {
            "<fieldName>": {
              "type": "string",
              "source": "BusinessSpec § N[.N] L<line> (required when businessSpecPath non-null; or 'derived: <explanation>')"
            }
          }
        }
      ],
      "dataModels": [
        {
          "name": "string",
          "fields": ["string"],
          "source": "BusinessSpec § N[.N] L<line> (required when businessSpecPath non-null; or 'derived: <explanation>')"
        }
      ],
      "businessRules": ["string"],
      "businessContext": {
        "summary": "string",
        "userRoles": ["string"],
        "constraints": ["string"],
        "assumptions": ["string"],
        "successCriteria": ["string"]
      }
    }
  },
  "userStories": [
    {
      "id": "US-NNN (required, zero-padded, regex: ^US-[0-9]{3}[a-z]?$)",
      "title": "string (required, max 200 chars)",
      "description": "string (required, max 500 chars, user story format)",
      "acceptanceCriteria": ["string[] (required, each max 5000 chars, must assert the project's own type/syntax check passes)"],
      "priority": "number (required, sequential integers, tiebreaker for same-depth stories)",
      "status": "pending (required, always 'pending' for new stories)",
      "dependsOn": ["US-NNN (required, array of story IDs, empty [] for root stories)"],
      "notes": "string (optional, default '')",
      "project": "string (optional, relative path for multi-repo, no '..' components)",
      "wave": "number (required, DERIVED from dependsOn — roots=1, others=max(dep waves)+1 — informational only, never consumed by dispatch; a stale value is corrected with the normalize-waves verb, not by hand)",
      "implementation": {
        "files": ["string[] (required, concrete in-repository paths from research, plain relative: no .. segment, no leading / or ~, no ./, no whitespace)"],
        "approach": "string (required, actionable strategy referencing codebase patterns)",
        "verify": "string (required, executable command or checkable assertion)",
        "guardRails": ["string[] (optional, exact text of each verify segment that is supposed to pass before and after the work, as the probe segmenter splits it)"],
        "outputs": ["string[] (optional, files written outside the repository, each a path relative to the AIMI root starting with .aimi/)"],
        "prototypeAnchor": "string (optional, relative path to the single prototype file most relevant to this story; set by Pass 2 sub-agent when AC cites exactly one prototype via F3 syntax; absent when AC cites zero or multiple prototypes)"
      },
      "verification": {
        "strategy": "test|visual|api (required)",
        "status": "pending (required)",
        "url": "string (optional, for api/visual strategies)",
        "expect": "string (optional, expected result description)"
      },
      "gate": {
        "type": "verify|decision|action (required)",
        "status": "pending (required)",
        "prompt": "string (required, human-readable description)",
        "options": ["string[] (optional, for decision gates)"]
      },
      "skills": "string[] (optional, array of bare skill names matching ^[a-zA-Z0-9][a-zA-Z0-9_-]*$, max 10 entries; omit field entirely when empty)",
      "tasks": "string[] (optional, max 50 entries, each ≤ 5000 chars; omit when empty)"
    }
  ]
}
```
