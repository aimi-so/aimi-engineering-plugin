# Execute: Phase Completion: Phase Visual Gate

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Phase Visual Gate

Reached only when Creates Verification's `branch=ok`. It runs here, before Write Handoff and before Mark Phase Completed's dev-server stop, because the comparison needs the phase's own dev server still up. A phase that shipped UI must never reach `completed` with an unjudged visual comparison; the completed-phase gate refuses one whose `visualGate` is absent or unjudged, and this section is what records it. It never writes `handoff.md` itself and never sets the phase to `completed`.

#### Is a comparison owed

One `roadmap-visual-gate-required` call, read-only. `.required` is true only when the phase's tasks file(s) carry a prototype **and** at least one completed visual story. `.groups` counts resolved tasks-file members (1 for any non-split phase) — it is **not** the participating-project-group count the checks below derive.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_JSON=$($AIMI_CLI roadmap-visual-gate-required --feature "$FEATURE" --phase "$PHASE_ID") || {
  echo "visual-gate: tooling-failed — roadmap-visual-gate-required exited non-zero" >&2
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
}
VG_REQUIRED=$(printf '%s' "$VG_JSON" | jq -r '.required')
VG_REASON=$(printf '%s' "$VG_JSON" | jq -r '.reason')
if [ "$VG_REQUIRED" = "true" ]; then
  printf 'visual-gate-required: required=true groups=%s\n' "$(printf '%s' "$VG_JSON" | jq -r '.groups')"
else
  printf 'visual-gate: not-required — %s\n' "$VG_REASON"
fi
```

**`.required` false:** record nothing — no `roadmap-record-visual-gate` call — and keep the printed `visual-gate: not-required — <reason>` line verbatim for Write Handoff's deviations. Fall through to Write Handoff. If the call itself failed, the claim is released and the phase's status stays `in_progress`; report the tooling failure the way Verification tooling failed above does and skip directly to Step 5 — `handoff.md` is not written.

#### Environment checks and the live URLs

When `.required` is true, three deterministic checks run in this fixed order. Each one that fails records its own `skipped` verdict and the phase still reaches `completed`; none of them spawns the reviewer or calls `write-review`:

1. **More than one participating project group, or a split phase** — reason names "per-repository servers": each repository serves its own phase branch, so one comparison cannot cover them. A split phase is `PHASE_SPLIT_MODE=true`; the group count is `project-groups` over `$PHASE_TASKS_PATH`, the same derivation Mark Phase Completed uses, not `.groups`.
2. **`agent-browser` not installed.**
3. **No dev server resolved for that group's own `$PHASE_BRANCH`** — any visual story URL whose `serve url` comes back `rewritten:false`.

When all three pass, every completed visual story's URL is rewritten through `$WORKTREE_MGR serve url`, following `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Rewrite a Verification URL Origin: `EXEC_ROOT` is the one group's own resolved toplevel — the same `EXEC_ROOT` Phase Container Dev Server Bootstrap `cd`s to before its `serve start` — and `EXEC_BRANCH="$PHASE_BRANCH"`, re-queried here and never a value cached from the bootstrap.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_JSON=$($AIMI_CLI roadmap-visual-gate-required --feature "$FEATURE" --phase "$PHASE_ID") || exit 1
VG_STORY_LINES=""
VG_CONTAINER=""
VG_MULTI=false
VG_GROUP_PROJECTS=""
if [ "$PHASE_SPLIT_MODE" = true ]; then
  VG_MULTI=true
else
  VG_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || exit 1
  VG_GROUP_PROJECTS=$(printf '%s' "$VG_GROUPS_JSON" | jq -r '.groups[]')
  [ "$(printf '%s\n' "$VG_GROUP_PROJECTS" | grep -c .)" -gt 1 ] && VG_MULTI=true
fi
VG_STATE=compare
if [ "$VG_MULTI" = true ]; then
  VG_STATE=skipped
  VG_SKIP_REASON="split phase or more than one participating project group: each repository serves its own phase branch (per-repository servers), so one comparison cannot cover them"
  $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
elif ! command -v agent-browser >/dev/null 2>&1; then
  VG_STATE=skipped
  VG_SKIP_REASON="agent-browser is not installed"
  $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
else
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  VG_PROJECT=$(printf '%s\n' "$VG_GROUP_PROJECTS" | grep -v '^$' | head -1)
  if [ -z "$VG_PROJECT" ] || [ "$VG_PROJECT" = "." ]; then
    VG_ROOT="$AIMI_ROOT"
  else
    VG_ROOT="$AIMI_ROOT/$VG_PROJECT"
  fi
  EXEC_ROOT=$(git -C "$VG_ROOT" rev-parse --show-toplevel 2>/dev/null) || EXEC_ROOT="$VG_ROOT"
  EXEC_BRANCH="$PHASE_BRANCH"
  VG_CONTAINER="$EXEC_ROOT/.worktrees/$EXEC_BRANCH"
  cd "$EXEC_ROOT"
  VG_UNREWRITTEN=0
  while IFS= read -r VG_STORY; do
    [ -n "$VG_STORY" ] || continue
    VG_STORY_ID=$(printf '%s' "$VG_STORY" | jq -r '.id')
    VG_RAW_URL=$(printf '%s' "$VG_STORY" | jq -r '.url // ""')
    SERVE_URL_JSON=$($WORKTREE_MGR serve url "$EXEC_BRANCH" "$VG_RAW_URL")
    VG_REWRITTEN=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.rewritten')
    [ "$VG_REWRITTEN" = "true" ] || VG_UNREWRITTEN=$((VG_UNREWRITTEN + 1))
    # roadmap-visual-gate-required emits {id, url}; the reviewer takes {storyId, url}.
    VG_STORY_ENTRY=$(printf '%s' "$SERVE_URL_JSON" | jq -c --arg id "$VG_STORY_ID" '{storyId: $id, url: .url}')
    VG_STORY_LINES="${VG_STORY_LINES}${VG_STORY_ENTRY}"$'\n'
  done <<< "$(printf '%s' "$VG_JSON" | jq -c '.visualStories[]')"
  cd "$AIMI_ROOT"
  if [ "$VG_UNREWRITTEN" -gt 0 ]; then
    VG_STATE=skipped
    VG_SKIP_REASON="no dev server resolved for $PHASE_BRANCH"
    $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
  fi
fi
if [ "$VG_STATE" = skipped ]; then
  printf 'visual-gate: skipped — %s\n' "$VG_SKIP_REASON"
else
  VG_STORIES_JSON=$(printf '%s' "$VG_STORY_LINES" | jq -s -c '.')
  VG_INPUT=$(printf '%s' "$VG_JSON" | jq -c --arg root "$AIMI_ROOT" --arg container "$VG_CONTAINER" --argjson stories "$VG_STORIES_JSON" '{prototypePaths: [.prototypePaths[] | "\($root)/\(.)"], designSpecPath: (if .designSpec then "\($root)/\(.designSpec)" else null end), stories: $stories, containerPath: $container}')
  printf 'visual-gate-input: %s\n' "$VG_INPUT"
fi
```

A `visual-gate: skipped — <reason>` line means the gate recorded its `skipped` verdict and the phase continues to Write Handoff unchanged; keep that line verbatim for its deviations. A `visual-gate-input:` line means the environment can compare: continue below.

#### Run the comparison

Spawn `aimi-engineering:design:aimi-design-implementation-reviewer` via the Task tool **exactly once for the whole phase** — never once per story, unlike Step 4's per-story design review. The prompt's **first line is the literal `MODE: phase-close-visual-gate`**; without it the agent falls back to per-story mode and never emits a `visual_gate_verdict` block. After it, give the agent the parsed `visual-gate-input:` object's fields: `prototypePaths` (every prototype path), `designSpecPath` (only when non-null), `stories` (the full `{storyId, url}` list) and `containerPath`.

Persist the reviewer's raw final response with `write-review --kind visual-gate` **before** the verdict is parsed — the suffix gives this review its own file, `.aimi/reviews/<feature>-phase-<N>-visual-gate.md`, so Step 5's design review, which names the same feature and phase, cannot overwrite the file `--review` points at — so a malformed verdict still leaves the transcript on disk, then parse **only the LAST** fenced `visual_gate_verdict` block, strictly. The fence is built with `printf` rather than typed, so this block carries no literal fence line of its own:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_REVIEW_BODY=$(cat <<'VG_REVIEW_EOF'
[paste the reviewer's raw final response here, verbatim]
VG_REVIEW_EOF
)
VG_REVIEW_JSON=$(printf '%s\n' "$VG_REVIEW_BODY" | $AIMI_CLI write-review --feature "$FEATURE" --phase "$PHASE_ID" --kind visual-gate) || VG_REVIEW_JSON=""
REVIEW_PATH=$(printf '%s' "$VG_REVIEW_JSON" | jq -r '.review // empty' 2>/dev/null)
VG_FENCE=$(printf '\140\140\140')
VG_VERDICT_JSON=$(printf '%s\n' "$VG_REVIEW_BODY" | awk -v fence="$VG_FENCE" 'BEGIN { open = fence "visual_gate_verdict" } $0 == open { inb = 1; buf = ""; next } inb && $0 == fence { inb = 0; last = buf; have = 1; next } inb { buf = buf $0 "\n" } END { if (have) printf "%s", last }')
VG_VERDICT=$(printf '%s' "$VG_VERDICT_JSON" | jq -r '.verdict' 2>/dev/null) || VG_VERDICT=""
VG_SUMMARY=$(printf '%s' "$VG_VERDICT_JSON" | jq -r '.summary // ""' 2>/dev/null)
case "$VG_VERDICT" in
  pass)
    $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status passed --review "$REVIEW_PATH"
    printf 'visual-gate: passed — %s\n' "$VG_SUMMARY"
    ;;
  diverges)
    printf 'visual-gate-verdict: diverges review=%s\n' "${REVIEW_PATH:-<not written>}"
    printf '%s' "$VG_VERDICT_JSON" | jq -r '.divergences[]? | "  - \(.storyId): \(.element) — expected \(.expected), observed \(.observed) [\(.source)]"'
    ;;
  *)
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    printf 'visual-gate: tooling-failed — no parseable visual_gate_verdict block with a pass or diverges verdict (review=%s)\n' "${REVIEW_PATH:-<not written>}"
    ;;
esac
```

- **`visual-gate: passed — <summary>`** — recorded; the phase falls through to Write Handoff.
- **`visual-gate-verdict: diverges`** — see below.
- **`visual-gate: tooling-failed`** — a missing block, a JSON parse failure, or a `.verdict` outside `pass`/`diverges`. Nothing was recorded via `roadmap-record-visual-gate` and the claim is released (the call above did it); the phase's status is left exactly where it was (`in_progress`), the same shape as Verification tooling failed above. Report:

  ```
  ## Phase [PHASE_ID] Visual Gate Could Not Run

  The design reviewer did not return a usable visual_gate_verdict block. This is
  NOT a finding that the UI diverges — nothing was proven either way.

  Raw review: [REVIEW_PATH, or "not written"]

  Phase status is unchanged (in_progress) and the claim is released. Re-run
  /aimi:execute -- the visual gate re-runs on the next pass.
  ```

  Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

#### On a diverges verdict

Resolve interactivity fresh — each Bash call is an isolated shell (Step 0):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
echo "visual-gate: interactivity=$INTERACTIVE_MODE"
```

- **`INTERACTIVE_MODE=picker`:** ask exactly one `AskUserQuestion`, showing the reviewer's `divergences[]`. Option A, the default and least disruptive, is **Leave the phase failing**; the trailing "Other" option is **Accept the divergences**, answered with a typed reason. Anything that is not an explicit Other answer carrying a reason — a decline, silence, any other option — leaves the phase failing. A typed reason is sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md`'s Base Rules before it reaches `--reason`.
- **`INTERACTIVE_MODE=agent`:** never ask this question and never record `accepted` — an unattended run cannot own an acceptance. The phase is left failing unconditionally.

**Accepting** records the verdict, satisfies the gate and falls through to Write Handoff. Compose the sanitized reason in the quoted heredoc so its bytes reach the verb unexpanded:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_ACCEPT_REASON=$(cat <<'VG_ACCEPT_EOF'
[the typed reason, sanitized per sanitization.md Base Rules]
VG_ACCEPT_EOF
)
$AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status accepted --reason "$VG_ACCEPT_REASON" --review "$REVIEW_PATH"
printf 'visual-gate: accepted — %s\n' "$VG_ACCEPT_REASON"
```

**Leaving it failing** (every decline, and unconditionally in agent mode) records `diverges`, transitions the phase to `verification_failed` and releases the claim, so re-running `/aimi:execute` re-enters Phase Completion and re-runs this gate:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_DIVERGE_REASON=$(cat <<'VG_DIVERGE_EOF'
[the reviewer's one-line summary, sanitized per sanitization.md Base Rules]
VG_DIVERGE_EOF
)
$AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status diverges --reason "$VG_DIVERGE_REASON" --review "$REVIEW_PATH"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Report the reviewer's `divergences[]` (the lines the verdict block printed) and the raw review path, and say the phase is `verification_failed` and that re-running `/aimi:execute` re-runs the gate. Do **not** write `handoff.md`, do **not** run Mark Phase Completed, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

