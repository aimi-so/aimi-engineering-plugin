# Execute: Visual Follow Lifecycle

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Visual Follow Lifecycle

The visual-follow feature spans four phases of the execute flow. This section documents the full lifecycle; each call site below references it by name.

### Phase 1 — Detection (Step 0.7)

The tasks file is scanned for stories with `verification.strategy == "visual"`. If any are found, the user is prompted once whether to follow visually. The result is stored in `VISUAL_FOLLOW=true|false` and held for the rest of the session.

### Phase 2 — Session Open (Step 3.3)

When `VISUAL_FOLLOW=true`, a persistent headed browser session named `visual-follow` is opened before the wave loop begins:

```bash
agent-browser --headed --session visual-follow open "$VISUAL_URL"
```

**Availability check:** Before opening, `command -v agent-browser` is run. If `agent-browser` is not installed, the user is warned and `VISUAL_FOLLOW` is downgraded to `false` (headless fallback takes over in Phase 3):

```
⚠ agent-browser not installed. Falling back to headless mode — visual follow disabled.
```

The session is opened exactly once. It is never closed mid-run.

**Container mode:** `$VISUAL_URL` is not the raw `verification.url` in this case — its origin (scheme + host + port) is rewritten to the first visual story's own project group's container dev server, preserving path and query (see Container Dev Server Bootstrap and Open Visual Follow Session, both in Step 3.3). The dev server is started, and its port resolved, before this URL is computed — never after. Outside container mode, `$VISUAL_URL` is the unrewritten `verification.url`, exactly as before.

**Phase mode:** the same origin rewrite applies, keyed by `PHASE_BRANCH` instead of a project group — but unlike container mode, the port is never cached from the earlier bootstrap: it is re-queried fresh via `serve status "$PHASE_BRANCH"` at this exact point, since a phase's wave loop can run long after Step 1.7's bootstrap and each Bash call is an isolated shell (see Phase Container Dev Server Bootstrap and Open Visual Follow Session, both in Step 1.7/Step 3.3). This applies unmodified inside a Phase-Mode Paired Split sub-orchestrator too, whose spawn prompt already pre-sets `PHASE_BRANCH`/`PHASE_CONTAINER_PATH` to its own split before this step runs.

### Phase 3 — Reuse Within Wave (Step 4 per-story)

After each story merges, visual stories are verified. When `VISUAL_FOLLOW=true`, the existing `visual-follow` session is reused (`agent-browser --session visual-follow open/screenshot`). When `VISUAL_FOLLOW=false`, a fresh headless `agent-browser` session is opened, screenshot taken, and closed per story. If `agent-browser` is absent in either case, `verification.status` is set to `skipped`.

**Container mode:** the URL used at each per-story verification call is likewise rewritten to that story's own project group's container dev server origin (see the post-merge verification block in Step 4). When that group's dev server never resolved a port, `verification.status` is set to `skipped` for that story — mirroring the "agent-browser not installed" degradation above — without ever blocking `mark-complete` or the wave loop.

**Phase mode:** the same per-story rewrite applies, again via a fresh `serve status "$PHASE_BRANCH"` query at this exact call site rather than any cached value. A full-stack split story whose page depends on an API served by the sibling split's container may fail or show a broken API call against its own split's server — there is no proxy between the two split servers (see Split Container Dev Server Bootstrap in Phase-Mode Paired Split). This is a documented limitation, not a bug: it degrades that story's `verification.status` exactly like a missing dev server does, and never blocks the wave or triggers a retry.

**Console capture (additive, per story).** Immediately before each per-story `open`, the wave loop issues `agent-browser console --clear` to drop logs accumulated from prior stories in the same wave. Right after `screenshot`, it captures `agent-browser console --json` and `agent-browser errors --json` for this story's page-load output and feeds both into the `attribute_console_errors()` pass defined in the Console Error Attribution section. Capture is advisory only — it never changes `verification.status` and never blocks the wave. The per-story `--clear` is what enables per-story attribution; without it, the buffer is wave-cumulative and the LAST verified story would inherit every prior story's errors.

### Phase 4 — Keep Open on Completion (Post-Loop)

When `VISUAL_FOLLOW=true`, the `visual-follow` session is intentionally left open after execution ends so the user can inspect the final UI state. The user must close it manually.

---
