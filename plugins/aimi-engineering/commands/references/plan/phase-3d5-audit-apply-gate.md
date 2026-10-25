# Plan: Phase 3d.5: Cross-Story DAG Audit, persistence, patch application and unresolved gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Persist audit-result.json

Immediately after parsing the auditor's output, use the `Write` tool to write the literal parsed object (`{patches, unresolved}`) to `<RUN_DIR>/audit-result.json`. story-merge deletes `RUN_DIR` on success — copy the file out before that point if you need it afterward.

### Patch Validation and Application

`apply-audit-patches` validates every patch, applies the survivors with one read and one atomic write per affected staging file, and stamps `audit-result.json` with `auditedIdx` (the staged idx set) and `appliedAt`. It enforces the idx lookup against the staged files only, a fixed op set per field (`dependsOn` takes `add`; `tasks` takes `add`, `replace` and `remove`; `notes` takes `add` and `replace`; `acceptanceCriteria`, `implementation.approach`, `implementation.verify`, `implementation.guardRails` and `gate.prompt` take `replace`), value sanitization, the 10-patch cap per story and post-patch validation with per-patch rollback. A `matchValue` must equal one whole `tasks` element, criterion, guard rail or `notes` paragraph (a chunk between `\n\n---\n\n`) and match exactly one. For `implementation.verify` it is a substring that must occur exactly once; its value replaces only that substring and lands identically in every `guardRails` entry containing it, and the patch is dropped as `guardRails-out-of-sync` only when it leaves a rail that equalled a verify segment before it no longer doing so (a rail that was already broken before the patch never causes a drop), or as `verify-composition` when the new verify can swallow a failing line. Verify and guard-rail values are stored verbatim, never rewritten. Its report is `{applied, dropped, unresolved, capped, auditedIdx}`.

`dropped` holds one entry per patch the verb refused: `{storyIdx, field, op, reason}`, plus `trigger` (the injection matcher's rule name, never the offending value) when the matcher refused it. A `guardRails-out-of-sync` entry also carries `rails`: the ascending integer indices of the `guardRails` entries that patch newly broke, never one that was already broken and never any rail text; no other reason has that key. **Dropped patches are not counted as unresolved:** a dropped patch adds no `unresolved` entry, and the only entry the verb adds of its own is the `audit cap reached` notice.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AUDIT_REPORT=$($AIMI_CLI apply-audit-patches --staging-dir "$RUN_DIR" --result "$RUN_DIR/audit-result.json") || exit 1
printf '%s' "$AUDIT_REPORT" | jq -c '{applied, dropped, unresolved, auditedIdx}'
```

The line printed carries `applied` (patches landed), `dropped` (the entries above), `unresolved` (the count now on disk) and `auditedIdx`. Relay each `dropped` entry to chat in one line, `[plan] Phase 3d.5: patch dropped — story <storyIdx> <field> <op>: <reason>`, with ` (<trigger>)` appended when it has one and ` (rails <i,j>)` appended when it has `rails` (the indices joined by commas), so a finding the verb refused is visible even though it is not in `unresolved[]`. Read the merged `unresolved[]` array — the auditor's entries plus the verb's own — from `audit-result.json` with the Read tool; it becomes the working-memory `unresolved[]` list (schema `{storyIdx, message}`). A non-zero exit is an apply failure: take the Failure Fallback.

### Failure Fallback

When the auditor Task crashes, times out, returns no parseable fenced `json` block, or `apply-audit-patches` exits non-zero in the apply step:

1. Sanitize the error string as Phase 3d retry does (strip `$(`, remove backticks, newlines to spaces, truncate to 500 characters).
2. Emit exactly one log line: `[plan] Phase 3d.5 audit failed: <sanitized error>; proceeding to story-merge without patches`
3. Replace `<RUN_DIR>/audit-result.json` with this stub. `auditedIdx` comes from the same `[0-9][0-9]-*.json` glob as the Skip Condition, so story-merge's gate passes it even though `apply-audit-patches` never ran:

```bash
AUDITED=$(find "$RUN_DIR" -maxdepth 1 -name '[0-9][0-9]-*.json' -type f | sed 's|.*/\([0-9][0-9]\)-.*|"\1"|' | sort | paste -sd, -)
printf '{"status":"audit-failed","auditedIdx":[%s],"patches":[],"unresolved":[{"storyIdx":"_audit","message":"audit failed - no patches applied"}]}\n' "$AUDITED" > "$RUN_DIR/audit-result.json"
```

4. Set `auditFailed = true` and use the stub's one `_audit` entry as the working-memory `unresolved[]`. No patch is applied; continue to the Unresolved Gate.

### Agent-Mode Behavior

When `INTERACTIVE_MODE=agent` the audit runs normally; nothing is suppressed. Emit one interim log line, where N is the report's `applied` and M the length of the merged `unresolved[]` (`0` and `1` after a Failure Fallback):

```
[plan] agent-mode: phase-3d.5 ran with <N> patches, <M> unresolved
```

This count is interim: the Unresolved Gate below still decides what happens to a non-empty list. It never blocks an agent-mode run, but it is not silent either — every unresolved item is deferred with a recorded reason and flagged on its story.

### unresolved[] Forwarding

The working-memory `unresolved[]` list (`{storyIdx: string, message: string}`) is forwarded to Step 5 and Phase 4 after the Unresolved Gate. `storyIdx` is a zero-padded outline index or the reserved sentinel `"_audit"`, an audit-system entry (auditor failure, or a cap notice not tied to one story) that consumers must treat as non-indexable.

### Phase 3d.5 Unresolved Gate

**Fires once**, immediately after the `unresolved[]` list above is complete — the merged array `apply-audit-patches` left in `audit-result.json`, or the Failure Fallback's stub entry when that path fired instead. When `unresolved[]` is empty at this point — including every run where the Skip Condition fired (fewer than 2 staged stories, so nothing above ever populated the list) — this gate is a no-op: no AskUserQuestion, no log line, proceed straight to Phase 3e.

**Interactive mode.** When `unresolved[]` is non-empty, sanitize each entry's `message` using the same four-step regime the Step 5 `Audit warnings` bullets use (replace newlines/CRs with spaces, strip `$(`, remove backticks, truncate to 200 characters, append `…` on truncation). Present **one** AskUserQuestion covering the whole accumulated list at once — never a per-item loop — rendering every entry as a bullet:

```
[storyIdx]: [sanitized message]
[storyIdx]: [sanitized message]
…
```

with exactly four options, verbatim:

```
Apply anyway — proceed to story-merge without acting on these findings
Defer with reason — annotate the affected stories and proceed
Edit outline — change the outline and re-expand only what the edit affects
Abort — stop before story-merge; nothing is written this run
```

- **[Apply anyway]:** proceed straight to Phase 3e — no staging-file change. Still record one `oqDecisions[]` entry per `unresolved[]` item:
  ```json
  {
    "anchor": "auditUnresolved:<storyIdx>",
    "source": "auditGate",
    "text": "<sanitized message>",
    "resolution": "applied"
  }
  ```
  `<storyIdx>` is the entry's own `storyIdx` value verbatim (a zero-padded index, or `_audit`). A reviewed-and-accepted finding gets the same paper trail a deferred one gets — mirroring the Phase 1.8 scope-pruning gates' own precedent of recording a CONFIRM outcome, not staying silent the way today's `Audit warnings` bullet does.

- **[Defer with reason]:** ask one open follow-up free-text question — "What is the reason for deferring these unresolved findings?" — then sanitize the answer: strip newlines/CRs to spaces, strip `$(`, remove backticks, truncate to 500 characters (the regime Phase 1.6b's research-conflict text uses). Pass it single-quoted, writing each `'` inside it as `'\''`, and run the verb once:

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  REASON='<sanitized reason>'
  $AIMI_CLI apply-audit-patches --staging-dir "$RUN_DIR" --result "$RUN_DIR/audit-result.json" --annotate-deferred --reason "$REASON"
  ```

  It annotates the `notes` of each staged story an entry names (the `_audit` sentinel, or an idx with no staged file, is never annotated) and prints `{annotated, oqDecisions}`. Append every `oqDecisions[]` entry it returns to the working-memory `oqDecisions[]` — one per unresolved item, annotated or not. A non-zero exit stops the plan here with `RUN_DIR` preserved; story-merge has not run. Proceed to Phase 3e.

- **[Edit outline]:** follow the section Edit Outline After Expansion in `commands/references/plan/phase-3c-outline-gate.md` (Read it first). It ends by re-running Phase 3d.5 in full, so this gate fires again on the new `unresolved[]`; no `oqDecisions[]` entry is recorded for this choice.

- **[Abort]:** stop plan generation before `story-merge` is invoked. `RUN_DIR` is preserved for inspection (never deleted on this path, matching the existing Phase 3e story-merge-failure convention). No `tasks.json` is written this run, `roadmap-set-status` is not called, and no `oqDecisions[]` entries are recorded for this gate.

**Agent-mode fallback:** when `INTERACTIVE_MODE=agent`, this gate never presents AskUserQuestion and `Edit outline` does not exist. It auto-selects **Defer with reason** with the fixed system-authored reason `"agent-mode auto-deferral (no interactive review available)"` (a hardcoded literal, not re-sanitized), running the same `--annotate-deferred` call and `oqDecisions[]` recording as the interactive path. Emit exactly one log line:

```
agent-mode: phase-3d.5-unresolved-gate deferred <N> unresolved item(s); flagged <F> stories for review
```

where `<N>` is the count of `unresolved[]` entries and `<F>` is the length of the verb's `annotated` array.
