# Plan: Phase 0: Implementation Scope Detection

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Implementation Scope Detection

After the brainstorm check, determine the implementation scope:

- **Non-app feature detected** (feature description contains keywords: `refactor`, `rename`, `migrate`, `CLI`, `command-line`, `plugin`, `skill`, `command`, `documentation`, `docs`, `changelog`, `readme` AND does NOT contain app-related signals: `page`, `dashboard`, `form`, `modal`, `UI`, `frontend`, `backend`, `API`) → skip scope question, leave `implementationScope` unset, proceed to Phase 1
- **Backend migration detected** (feature description contains `migrate` or `migration` AND contains backend/server signals: `backend`, `server`, `API`, `database`, `db`, `schema`, `endpoint`, `service` AND does NOT contain frontend/UI signals: `frontend`, `UI`, `page`, `dashboard`, `form`, `modal`, `component`) → skip scope question, leave `implementationScope` unset (legacy single-file mode), proceed to Phase 1
- **Conflicting signals** (both non-app keywords and app-related signals present) → do NOT skip, ask the question below

1. **Auto-detect default from brainstorm context** (if a brainstorm was found):
   - If brainstorm text contains signals like `frontend-only`, `mocked data`, or `prototype` → default to option 1
   - If brainstorm text contains signals like `backend`, `API`, `schema`, or `full-stack` → default to option 2

2. **Ask the user** via AskUserQuestion:
   > What type of implementation? (1) frontend prototype with mocked data (2) full-stack implementation (frontend + backend)

   Present the auto-detected default if one was determined.

3. **Store the result** as `implementationScope: "frontend-only" | "full-stack"` for use in Phase 4 metadata.

### Frontend-Without-Prototype Warning (Advisory)

Runs once, immediately after `implementationScope` is stored above. Purely advisory — it never blocks, aborts, or spawns any Task/agent; the rest of the pipeline continues unchanged regardless of outcome.

**Determine `frontendBearing`:**

- `true` when `implementationScope` is `"frontend-only"` or `"full-stack"`.
- Otherwise, when `ROADMAP_MODE=true`: read `${CLAUDE_PLUGIN_ROOT}/commands/references/ui-signals.md` (the `${CLAUDE_PLUGIN_ROOT}` prefix is required — it is the only form `install.sh` rewrites to `${AIMI_PLUGIN_DIR}` for OpenCode) and apply its Structural Signals section to `SELECTED_PHASE_JSON`'s `creates`, `PHASE_AREAS_JSON` (`areas`), and `PHASE_GOAL` (`goal`) — a match against any of the three sets `frontendBearing = true`.
- Otherwise: `false`.

**Emit the warning.** When `frontendBearing` is `true` AND `resolvedPrototypePaths` is empty, emit exactly one chat line and continue:

```
warning: feature ships a frontend but no prototype exists — run /aimi:brainstorm to create one, or proceed without a visual acceptance target.
```

Otherwise, emit no line.
