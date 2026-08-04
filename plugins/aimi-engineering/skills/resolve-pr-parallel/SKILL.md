---
name: resolve_pr_parallel
description: Resolve all PR comments using parallel processing. Use when addressing PR review feedback, resolving review threads, or batch-fixing PR comments.
argument-hint: "[optional: PR number or current PR]"
disable-model-invocation: true
allowed-tools: Bash(git *), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Read
---

# Resolve PR Comments in Parallel

Resolve all unresolved PR review comments by spawning parallel agents for each thread.

## Context Detection

Claude Code automatically detects git context:
- Current branch and associated PR
- All PR comments and review threads
- Works with any PR by specifying the number

## Workflow

### 1. Analyze

Fetch unresolved review threads using the forge-verb-backed script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/resolve-pr-parallel/scripts/get-pr-comments PR_NUMBER
```

This returns only **unresolved, non-outdated** threads with file paths, line numbers, and comment bodies.

If the script fails, call the underlying forge verb directly:
```bash
$AIMI_CLI forge-pr-review-threads --pr PR_NUMBER [--owner OWNER --repo REPO]
```

### 2. Plan

Create a TodoWrite list of all unresolved items grouped by type:
- Code changes requested
- Questions to answer
- Style/convention fixes
- Test additions needed

### 3. Implement (PARALLEL)

Spawn a `pr-comment-resolver` agent for each unresolved item in parallel.

If there are 3 comments, spawn 3 agents:

1. Task pr-comment-resolver(comment1)
2. Task pr-comment-resolver(comment2)
3. Task pr-comment-resolver(comment3)

Always run all in parallel subagents/Tasks for each Todo item.

### 4. Commit & Resolve

- Commit changes with a clear message referencing the PR feedback
- Resolve each thread programmatically:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/resolve-pr-parallel/scripts/resolve-pr-thread THREAD_ID
```

- Push to remote

### 5. Verify

Re-fetch comments to confirm all threads are resolved:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/resolve-pr-parallel/scripts/get-pr-comments PR_NUMBER
```

Should return an empty array `[]`. If threads remain, repeat from step 1.

## Scripts

- [scripts/get-pr-comments](scripts/get-pr-comments) - calls the `forge-pr-review-threads` forge verb (via `$AIMI_CLI`) for unresolved review threads
- [scripts/resolve-pr-thread](scripts/resolve-pr-thread) - calls the `forge-resolve-review-thread` forge verb (via `$AIMI_CLI`) to resolve a thread by ID
- [scripts/_resolve-cli.sh](scripts/_resolve-cli.sh) - internal helper, sourced by both scripts above to resolve `$AIMI_CLI`; not a standalone entry point

## Success Criteria

- All unresolved review threads addressed
- Changes committed and pushed
- Threads resolved via GraphQL (marked as resolved on GitHub)
- Empty result from get-pr-comments on verify
