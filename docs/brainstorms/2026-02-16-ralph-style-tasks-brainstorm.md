# Brainstorm: Ralph-Style Task Format for Aimi

**Date:** 2026-02-16  
**Status:** Implemented

## What We're Building

Refactoring Aimi's tasks.json format to adopt Ralph's flat, battle-tested structure while keeping Aimi's metadata richness. This simplifies the schema, improves execution reliability, and aligns with proven autonomous agent patterns.

## Why This Approach

### Problems with Previous Format (v2.0)
- **Nested complexity**: Stories contained `tasks[]` arrays, adding unnecessary indirection
- **Status tracking confusion**: Had to track `status` on each nested task
- **No explicit priority**: Stories ordered by array position, not explicit dependency
- **Missing required checks**: No enforcement of "Typecheck passes" criteria

### Ralph's Proven Patterns
- **Flat structure**: Each story = one atomic unit of work
- **Simple state**: `passes: true/false` instead of per-task status
- **Explicit priority**: `priority` field determines execution order
- **Required criteria**: "Typecheck passes" enforced on every story
- **Size rule**: "One context window" keeps stories right-sized

## Key Decisions

1. **Schema v3.0**: Flat stories with `priority` field, no nested tasks
2. **Story IDs**: Changed from `story-0` to `US-001` format
3. **Priority-based selection**: jq sorts by `.priority` to pick next story
4. **Required "Typecheck passes"**: Every story must include this criterion
5. **Removed fields**: `tasks[]`, `estimatedEffort`, `taskType`, `steps`, `relevantFiles`, `patternsToFollow`
6. **Kept Aimi metadata**: `schemaVersion`, `metadata.planPath`, `successMetrics`

## Schema Comparison

### Before (v2.0 - nested)
```json
{
  "userStories": [{
    "id": "story-0",
    "title": "Phase 0: ...",
    "tasks": [
      {"id": "task-0-1", "file": "...", "status": "pending"}
    ]
  }]
}
```

### After (v3.0 - flat)
```json
{
  "userStories": [{
    "id": "US-001",
    "title": "Add status field to tasks table",
    "description": "As a developer, I need...",
    "acceptanceCriteria": ["...", "Typecheck passes"],
    "priority": 1,
    "passes": false,
    "notes": ""
  }]
}
```

## Files Updated

1. `skills/plan-to-tasks/references/task-format.md` - New v3.0 schema
2. `skills/plan-to-tasks/SKILL.md` - Conversion rules for flat stories
3. `commands/next.md` - jq selection by priority
4. `commands/execute.md` - Priority-based loop
5. `commands/status.md` - Display with priority info
6. `skills/story-executor/SKILL.md` - Simplified prompt template
7. `skills/story-executor/references/execution-rules.md` - Flat story execution

## Open Questions

None - implemented and ready for testing.

## Next Steps

- Run `/workflows:plan` to create implementation plan if further changes needed
- Test with real plan conversion to validate the flow
