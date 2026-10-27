# Execute: Step 1.7: Detect a Full-Stack Split Inside This Phase

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Detect a Full-Stack Split Inside This Phase

Before pointing the session at a single governing tasks file, check whether this phase's own directory instead holds a **split** — a set of sibling tasks files planned together for this one phase that must all execute in this single invocation. Detection mirrors Step 0.9's fixed two-pass order (project-split marker first, legacy `-frontend-tasks.json`/`-backend-tasks.json` suffix pair only as the fallback), scoped to just this phase's own directory. `PHASE_SPLIT_MODE` stays a plain boolean — *is this phase split at all* — and never becomes a count; the member list is what carries N.

Enumerate this phase's own candidate files:

```bash
PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
PHASE_MAIN_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-tasks.json"
PHASE_SPLIT_CANDIDATES=""
for candidate in "$PHASE_DIR_PATH"/*-tasks.json; do
  [ -f "$candidate" ] || continue
  [ "$candidate" = "$PHASE_MAIN_TASKS" ] && continue
  PHASE_SPLIT_CANDIDATES="${PHASE_SPLIT_CANDIDATES}${candidate}"$'\n'
done
```

**Why a directory glob is safe here and is forbidden in Step 0.9.** `PHASE_DIR_PATH` contains exactly one phase's own files. Step 0.9's `find-tasks-all` returns every `*-tasks.json` under the flat `.aimi/tasks/` root, across every feature ever planned, which is why it must never derive a group from a filename scan. The asymmetry is deliberate and load-bearing: the glob above only enumerates *candidates* local to this phase, and the group itself is still decided by the marker (Pass 1) or by the legacy pair rule (Pass 2), never by the glob alone.

#### Pass 1 — Project-Split Detection (`metadata.splitGroup`)

Read the same self-describing marker Step 0.9's **Project-Split Detection** reads — `metadata.splitGroup` = `{project, index, total, siblings[]}`, where `project` is the normalized project path (`"."` meaning the root group) and `siblings` lists every *other* member — with the same anchor-plus-declared-siblings rule and the same `total`-versus-resolved-count validation. The anchor is the first candidate carrying a well-formed marker; the group is exactly the anchor plus its own declared siblings, each resolved **by basename** against `$PHASE_DIR_PATH` (which renders a traversal-shaped sibling entry inert):

```bash
PHASE_ANCHOR_FILE=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if jq -e '(.metadata.splitGroup | type) == "object"
            and (.metadata.splitGroup.total | type) == "number"
            and (.metadata.splitGroup.siblings | type) == "array"' "$candidate" >/dev/null 2>&1; then
    PHASE_ANCHOR_FILE="$candidate"
    break
  fi
done <<< "$PHASE_SPLIT_CANDIDATES"

PHASE_SPLIT_FILES=""
if [ -n "$PHASE_ANCHOR_FILE" ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  # split-detect already resolves this exact anchor-plus-declared-siblings
  # group over $PHASE_DIR_PATH -- one call replaces the two raw jq reads of
  # $PHASE_ANCHOR_FILE that used to run here (`.metadata.splitGroup.total`
  # and `.siblings[]?`), never a per-sibling read. The candidate loop above
  # and the basename-resolution loop below are UNCHANGED: they still decide
  # which file is the anchor and still validate every declared sibling
  # against the anchor's own directory (the traversal-defeating property
  # Step 0.9 Pass 1 and this Pass 1 both describe) -- only the SOURCE of the anchor's
  # declared total and siblings moves from a raw file read to this call.
  PHASE_SPLIT_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH")
  PHASE_SPLIT_TOTAL=$(printf '%s' "$PHASE_SPLIT_JSON" | jq -r '.total')
  PHASE_SPLIT_FILES="$PHASE_ANCHOR_FILE"
  PHASE_SPLIT_OK=true
  while IFS= read -r sibling; do
    [ -n "$sibling" ] || continue
    SIBLING_PATH="$PHASE_DIR_PATH/$(basename "$sibling")"
    if [ ! -f "$SIBLING_PATH" ]; then
      echo "Warning: declared split sibling missing on disk: $SIBLING_PATH" >&2
      PHASE_SPLIT_OK=false
      break
    fi
    PHASE_SPLIT_FILES="${PHASE_SPLIT_FILES}"$'\n'"${SIBLING_PATH}"
  done < <(printf '%s' "$PHASE_SPLIT_JSON" | jq -r --arg anchor "$PHASE_ANCHOR_FILE" '.members[] | select(.path != $anchor) | .path')
  PHASE_SPLIT_COUNT=$(printf '%s\n' "$PHASE_SPLIT_FILES" | grep -c .)
  if [ "$PHASE_SPLIT_OK" != true ] || [ "$PHASE_SPLIT_COUNT" -ne "$PHASE_SPLIT_TOTAL" ] || [ "$PHASE_SPLIT_COUNT" -lt 2 ]; then
    echo "Warning: phase split group is incomplete (declared total ${PHASE_SPLIT_TOTAL}, resolved ${PHASE_SPLIT_COUNT}) — falling back to single-file phase execution" >&2
    PHASE_SPLIT_FILES=""
  fi
fi
```

A group that fails validation degrades to single-file phase execution rather than running a partial split — and it does **not** fall through to Pass 2. Emptying `PHASE_SPLIT_FILES` above records only "no usable group here"; `PHASE_ANCHOR_FILE` stays set and is what the dispatch below reads, precisely so a failed group cannot resurrect a stale legacy pair that happens to sit in the same directory.

#### Pass 2 — Legacy Paired Split (fallback)

**Only reached when Pass 1 found no marker-carrying candidate at all** — i.e. this phase's files predate the project-split writer. The legacy rule is unchanged: two files sharing the `<feature>-phase-<N>` prefix, one ending `-frontend-tasks.json` and the other `-backend-tasks.json`. It terminates by feeding the pair into the same N-aware member list as its two-member case.

Pass 1 and Pass 2 run in the **same** Bash call, so `PHASE_ANCHOR_FILE` from Pass 1 is in scope here. The dispatch has exactly three arms, and the discriminator is `PHASE_ANCHOR_FILE` — never `PHASE_SPLIT_FILES`, which Pass 1 empties for *two* different reasons (no marker found, and marker found but group invalid) that must not be treated alike:

```bash
if [ -n "$PHASE_ANCHOR_FILE" ] && [ -n "$PHASE_SPLIT_FILES" ]; then
  # Arm 1 — Pass 1 found a marker and its group validated. Run the project split.
  PHASE_SPLIT_MODE=true
elif [ -n "$PHASE_ANCHOR_FILE" ]; then
  # Arm 2 — a marker was found but its group failed validation. Degrade to
  # single-file phase execution. The legacy pair is NOT considered: this phase
  # was planned by the project-split writer, so any -frontend-/-backend-tasks.json
  # sitting beside it is stale, and running it would execute the wrong work.
  echo "Phase split group failed validation — degrading to single-file phase execution (legacy frontend/backend pair not considered: this phase carries a project-split marker)" >&2
  PHASE_SPLIT_FILES=""
  PHASE_SPLIT_MODE=false
else
  # Arm 3 — no candidate carries the marker. Legacy pair fallback.
  LEGACY_FE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-frontend-tasks.json"
  LEGACY_BE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-backend-tasks.json"
  if [ -f "$LEGACY_FE_TASKS" ] && [ -f "$LEGACY_BE_TASKS" ]; then
    PHASE_SPLIT_FILES="$LEGACY_FE_TASKS"$'\n'"$LEGACY_BE_TASKS"
    PHASE_SPLIT_MODE=true
  else
    PHASE_SPLIT_MODE=false
  fi
fi
```

This mirrors the flat side, whose Project-Split Detection likewise dispatches on `ANCHOR_FILE` ("When `ANCHOR_FILE` is empty… fall through to Paired Split Detection"; "When the group failed validation… the run degrades to Single-File Fallback"). Arm 2 is the case a `PHASE_SPLIT_FILES` gate silently mishandles: it announces the degradation and then runs the stale pair anyway.

Legacy pair files carry no `metadata.splitGroup`, so every step below derives their slugs from their own basenames (`frontend`, `backend`) and reproduces exactly today's `<PHASE_BRANCH>-frontend` / `<PHASE_BRANCH>-backend` branch pair — byte-for-byte the same worktree creation, spawn, report, merge, and cleanup behavior as before, now expressed as the two-iteration case of one loop.

#### Active Split Files

A member with nothing left to do takes no part in execution. Before any branch, worktree, dev server, or Task exists, filter the member list down to its **active** entries — those with at least one story that is not already `completed`. A file whose `userStories` array is empty (the N-file writer legitimately emits a file for a project group that ended up with zero stories) drops out here and produces no worktree, no branch, no spawned Task, no dev-server bootstrap, no report block, and no cleanup call. This is the identical skip rule Step 0.9's **Active Split Files** applies in the flat flow:

```bash
PHASE_ACTIVE_SPLIT_FILES=""
if [ "$PHASE_SPLIT_MODE" = true ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  # One split-detect call, hoisted above the loop, in place of a per-member
  # jq pending-count read -- it already computes pendingCount per member
  # from the same `(.status // "pending") != "completed"` predicate this
  # loop used to apply itself.
  PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    SPLIT_PENDING=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .pendingCount')
    if [ "${SPLIT_PENDING:-0}" -gt 0 ]; then
      if [ -n "$PHASE_ACTIVE_SPLIT_FILES" ]; then
        PHASE_ACTIVE_SPLIT_FILES="${PHASE_ACTIVE_SPLIT_FILES}"$'\n'"${split_file}"
      else
        PHASE_ACTIVE_SPLIT_FILES="$split_file"
      fi
    else
      echo "Skipping split file with no pending stories: $split_file" >&2
    fi
  done <<< "$PHASE_SPLIT_FILES"
fi
PHASE_ACTIVE_COUNT=$(printf '%s\n' "$PHASE_ACTIVE_SPLIT_FILES" | grep -c .)
```

`PHASE_SPLIT_FILES` (every member) and `PHASE_ACTIVE_SPLIT_FILES` (the members that still have work) are both carried forward. Everything that *creates* something loops over the active list; **Multi-File Pending Count** in Phase Completion sums over the full member list.

**When `PHASE_SPLIT_MODE=true`:** skip **Point the session at this phase's own tasks file** below entirely — a split phase has no single governing tasks file for this session to point at — and, after Path and State Notes immediately below, proceed to **Phase-Mode Paired Split** instead of Step 2. `PHASE_ACTIVE_COUNT` of `0` is legal (every member already completed, e.g. on a resume after a merge conflict): that case creates nothing and spawns nothing, and Phase-Mode Paired Split routes it straight to **Continue to Phase Completion**.

**When `PHASE_SPLIT_MODE=false` (unchanged):** continue with **Point the session at this phase's own tasks file** below exactly as before.

**Point the session at this phase's own tasks file** so Steps 2–5 operate on the claimed phase, not whichever nested file `init-session`'s mtime-based auto-discovery happened to pick in Step 1 (a feature with multiple materialized phase tasks files could have a more-recently-touched sibling phase that is not the one just claimed):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_TASKS_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json"
$AIMI_CLI init-session --file "$PHASE_TASKS_PATH"
```

**`init-session --file` above still writes the global current-tasks pointer, and that write is kept, not removed.** Steps 3 and 4 below never read it back — every call they make resolves its own tasks file explicitly (`$PHASE_TASKS_PATH` here, `$TASKS_PATH` in flat mode), so a concurrent split sub-orchestrator's own `init-session --file` call overwriting this pointer is harmless to them. The pointer still has two real readers: `cmd_get_state` (and therefore `/aimi:status`'s own bare reads) has no other source for a "current tasks file" value to report, and any single-session flat CLI usage with no locally-resolved path — a human typing `$AIMI_CLI list-ready` by hand outside of this flow — still depends on it. What stays racy after this fix is `cmd_get_state`'s own reported field, last-writer-wins across concurrent split orchestrators, and purely cosmetic: nothing on the wave-loop or executor-spawn path consults it to decide what to read or mutate.

If this errors with "File not found," the claimed phase has not been planned yet. Report:
```
Phase [PHASE_ID] is claimed but has no tasks file yet ([PHASE_TASKS_PATH]).
Run /aimi:plan --phase [PHASE_ID] to materialize it, then re-run /aimi:execute.
```
Release the claim so it does not block other sessions, then STOP:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```
