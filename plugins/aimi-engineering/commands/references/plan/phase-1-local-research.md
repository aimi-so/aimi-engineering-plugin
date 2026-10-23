# Plan: Phase 1: Local Research

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 1: Local Research (Parallel)

### Prepare Research Directory

```bash
mkdir -p .aimi/research
```

### Derive Topic Slug

**When `ROADMAP_MODE=true`** (see Rolling-Wave Phase Selection in Phase 0): `topicSlug = PHASE_TOPIC_SLUG` (already computed there) — skip the derivation below entirely. This is what keeps every research filename, `RUN_DIR`, and staging path phase-scoped for the rest of this pipeline with no further per-phase changes needed.

**Otherwise**, from the feature description, derive a topic slug for research filename derivation:
1. Convert to lowercase
2. Replace spaces and special characters with hyphens
3. Remove consecutive hyphens
4. Truncate to 50 characters
5. Remove trailing hyphens

Store as `topicSlug` for use in researcher agent prompts.

### Generate Run Discriminator

Generate a single timestamp for this run to prevent same-day re-runs from overwriting prior research files:

```bash
RUN_TS=$(date +%H%M%S)
```

Store `RUN_TS` and use it in **all** research agent prompts and Phase 3a staging directory construction for this run.

### Auto-Scan for Git Repos

Before launching research agents, scan immediate child directories for `.git/` directories to discover sub-projects. The loop is anchored to `$AIMI_ROOT` so a leaked CWD from a prior Bash call cannot produce a zero-repos scan:

```bash
for dir in "$AIMI_ROOT"/*/; do
  dir="${dir%/}"          # strip trailing slash for consistent naming
  name="${dir##*/}"       # basename only
  case "$name" in .worktrees|node_modules|.aimi|vendor) continue;; esac
  [ -d "$dir/.git" ] && echo "$name/"
done
```

List discovered repos with their relative paths from the `.aimi/` parent.

- If **zero** or **one** repo is found, no multi-repo handling is needed
- If **multiple** repos are found, pass the list to research agents and use it in Phase 3d for `project` assignment

### Extract Path Hints

Before running research agents, extract file-path hints from the feature description so the codebase researcher can scope its search rather than globbing the entire repo.

**Regex:** Match tokens that look like file paths or directory globs — tokens containing `/` or `*` that do not start with a URL scheme (`http://`, `https://`, `ftp://`).

Concretely, scan `$ARGUMENTS` for whitespace-delimited tokens that satisfy **all** of these:

1. Contains at least one `/` or `*` character.
2. Does not start with `http://`, `https://`, or `ftp://`.
3. Does not start with `/etc/`.
4. Does not contain `..` (any path traversal component).
5. Is not inside a code fence (skip tokens between `` ``` `` or `` ` `` delimiters).
6. Does not contain an HTML tag (`<` or `>`).

**Sanitize each surviving token** using the same Phase 1 rules applied to the feature description itself:
- Strip any surrounding code-fence characters.
- Remove HTML/XML tags.
- Remove instruction-override patterns (`ignore previous`, `you are now`, and similar).
- Reject the token entirely if it still contains `..` after stripping.

Store the surviving tokens as `pathHints` (a list). If no tokens survive, set `pathHints` to an empty list.

**When `ROADMAP_MODE=true`:** merge `PHASE_AREAS_JSON` (the selected phase's `areas[]`, already sanitized by `roadmap-init` at materialization time) into `pathHints`, deduplicated. These are phase-declared scope hints, not user-typed tokens, so they skip the six-check filter above — they are appended as-is.

### Phase-Scoped Research Reuse

**When `ROADMAP_MODE=true`:** before spawning any Phase 1 or Phase 1.5b researcher, check for an existing phase-scoped research file to reuse — this is what keeps re-running `/aimi:plan --phase <N>` (e.g. after fixing a validation error) from needlessly re-researching a phase whose codebase context has not changed.

For each research kind not already populated by brainstorm-reuse (`reusedResearch.codebase`, `reusedResearch.learnings`, `reusedResearch["best-practices"]`, `reusedResearch["framework-docs"]` — see Reuse Brainstorm Research above; brainstorm-reuse always takes precedence when both apply for the same kind):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
CANDIDATE=$(ls -t "$AIMI_ROOT"/.aimi/research/*-"${PHASE_TOPIC_SLUG}"-*-<suffix>.md 2>/dev/null | head -1)
if [ -n "$CANDIDATE" ]; then
  FRESH_PATH=$($AIMI_CLI research-lookup --ignore-missing-cited-paths "$CANDIDATE" 2>/dev/null)
  HAS_VERIFIED=$(grep -c '^## Verified' "$CANDIDATE" 2>/dev/null || echo 0)
  echo "research-reuse: $CANDIDATE verified-section=$HAS_VERIFIED"
fi
```

Where `<suffix>` is `codebase`, `learnings`, `best-practices`, or `framework-docs` respectively (run once per kind). On a fresh match (`research-lookup` exits 0, `FRESH_PATH` non-empty), set `reusedResearch.<kind> = FRESH_PATH` — this populates the exact same map the brainstorm-reuse path populates, so every "If `reusedResearch.X` is set: skip the Task" branch already documented in Run Research Agents / Phase 1.5b below applies unchanged. On a stale match or no candidate file, leave that kind unset — its normal Task spawn proceeds.

`research-lookup` answers **freshness only** — whether the file is older than the sources it cites. It says nothing about whether a figure inside it was ever corrected, which is why the block also reports `verified-section=<count>`: a non-zero count means the file carries a `## Verified` section, and Phase 1.6 will read that section with precedence over the body. A reused file with no such section is the exact path by which a corrected number gets re-imported wrong, so the count is printed even when it is `0`.

**When `ROADMAP_MODE=false`:** this step does not run — behavior is unchanged from today.

### Run Research Agents

Run these agents **in parallel** using the Task tool.

**If `reusedResearch.codebase` is unset** (no valid codebase research from brainstorm):

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Analyze the codebase for patterns relevant to: [feature description].
           topicSlug: [topicSlug]
           [If pathHints is non-empty]: paths: [<comma-joined pathHints>]
           [If ROADMAP_MODE]: Phase scope — this research is scoped to phase
           [SELECTED_PHASE_ID] ([PHASE_NAME]): goal: [PHASE_GOAL].
           Look for: existing patterns, CLAUDE.md guidance, similar features,
           technology familiarity, file structure conventions.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-codebase.md
           [If the feature description contains 'migrate' or 'migration']:
           Migration origin hint (likely renamed in target — NOT the search target):
             legacySymbol: [legacy class/module/function name, if known]
           Do NOT treat a failed grep for the legacy symbol name as proof the
           feature is absent. Instead, verify existence through data flow as
           described in the agent's Migration-aware existence checks doctrine:
           locate row writes / persistence calls, confirm the persisted
           collection or table, find the triggering endpoint or mutation, and
           trace callers of the legacy symbol. Only after all four signals are
           checked may you conclude the feature has not been migrated.
           [End migration clause]
           [If prototypeBlocks is non-empty]:
           Prototype designs chosen for this feature (use as implementation reference):
           [prototypeBlocks]"
```

**If `reusedResearch.codebase` is set**: skip the codebase researcher Task entirely. The existing file at `reusedResearch.codebase` will be read directly in Phase 1.6.

**If `reusedResearch.learnings` is unset** (brainstorm did not produce learnings research, or reuse is not available):

```
Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Search .aimi/solutions/ for learnings relevant to: [feature description].
           topicSlug: [topicSlug]
           [If ROADMAP_MODE]: Phase scope — this research is scoped to phase
           [SELECTED_PHASE_ID] ([PHASE_NAME]): goal: [PHASE_GOAL].
           Look for: gotchas, patterns, past solutions, lessons learned.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-learnings.md
           [If resolvedPrototypePaths is non-empty]:
           Prototype paths for this feature: [resolvedPrototypePaths]. Read these
           files yourself, on demand, ONLY if a .aimi/solutions/ match you find is
           prototype-relevant."
```

**If `reusedResearch.learnings` is set**: skip the learnings researcher Task entirely. The existing file at `reusedResearch.learnings` will be read directly in Phase 1.6.

If any spawned agent fails, proceed with available results.
