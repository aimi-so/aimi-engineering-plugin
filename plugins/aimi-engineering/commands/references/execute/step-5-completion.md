# Execute: Step 5: Completion

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

> **PHASE_MODE scope note:** this step's reporting is written for the flat-mode case (CWD = `AIMI_ROOT`, `HEAD` on `branchName`). In phase mode, run this step's commands with CWD inside `PHASE_CONTAINER_PATH` and substitute `PHASE_BRANCH` for `branchName` / `CONTAINER_BASE` for `DEFAULT_BRANCH` where used below. Phase-level completion — verifying the claimed phase's `creates`, writing `handoff.md`, updating roadmap status, offering a PR, and offering or auto-continuing to the next phase — is handled entirely by the **Phase Completion** section above, which runs before this step whenever `PHASE_MODE=true` and the phase's own pending count reaches zero. This step still runs afterward, in both modes, to report story-level completion for the phase's own tasks file.

> **CONTAINER_MODE scope note:** when `CONTAINER_MODE=true` and `PHASE_MODE=false` (flat container-mode execution — see Execution Mode Detection in Step 1), the **If all stories complete** branch below runs three additional ordered steps before its existing report: stop each project group's dev server, confirm and (unless declined or not opted into) push `[branchName]` to `origin`, then remove each project group's container while preserving its branch. Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Mode: Stop the Dev Server, § Container Mode: Push the Branch, and § Container Mode: Remove the Container immediately below — the order there is load-bearing; removing a container before its dev server is stopped orphans that server, still holding its port with no backing directory. When `CONTAINER_MODE=false` (inline mode, the default and unchanged), none of the three apply: no `git push` is invoked, no container is removed, and `serve stop` is never called.
>
> **Container removal is completion-path-only.** The reference's **Container Mode: Remove the Container** step is the only place in flat container mode that `$WORKTREE_MGR remove <branchName>` is ever called against the feature container itself — as opposed to a per-story worktree nested inside it. The **If deadlock detected** branch below, the per-wave merge-conflict report path (Step 4), and the reference's **Abandoning a Containerized Run** procedure never call it outside of this completion path or that explicit, user-initiated abandonment — every other exit leaves the feature container (and any dev server inside it) exactly as it was. (Phase mode's own container, `PHASE_CONTAINER_PATH`, is never removed anywhere in this document — see Phase Completion's **Mark Phase Completed**, which updates roadmap status only — so the same guarantee holds there trivially; the phase-mode split-merge conflict report below states it explicitly anyway, for parity with the flat case.)

### If all stories complete:

**When `CONTAINER_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Mode: Stop the Dev Server, § Container Mode: Push the Branch, and § Container Mode: Remove the Container, and run all three, in that order, before continuing below — raising the push confirmation immediately below in between, after every dev-server stop has completed and before anything is pushed. When `CONTAINER_MODE=false` (inline mode), skip all three, skip the confirmation with them, and continue directly below.

**Confirm before this container's branch reaches `origin`.** The contract this question satisfies is defined once in `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` and is not restated here. The question itself lives in this file rather than in that reference — or in `container-execution.md`, which owns the push it gates — because install.sh translates only a command body and the REFERENCE_ALLOWLIST_FULL subtrees (plan/ and execute/) with the full command-body rewrite, while container-execution.md gets only the REFERENCE_ALLOWLIST_LITERALS host-literal rewrite and Check 14 refuses picker markup in it and every other reference. Resolve interactivity fresh — each Bash call is an isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
echo "$INTERACTIVE_MODE"
```

**When `INTERACTIVE_MODE=picker`:** Use **AskUserQuestion** exactly once for the whole run, with exactly two options:

```
All stories are complete. Push [branchName] to origin now?

A — Push now
B — Skip (push it yourself later, or run /aimi:open-pr)
```

**Option A:** proceed to the push in § Container Mode: Push the Branch. **Option B:** set `SKIP_PUSH=true` — the same variable that reference's own push block gates on — and skip straight to § Container Mode: Remove the Container. Anything that is not an explicit A — a dismissed prompt, an unparseable answer, no answer at all — is B: silence is not approval. Ask once for the whole run, not once per project group; one answer governs every participating group (`publish-confirmation.md`). Write the question and its option text in whatever language the person is writing in, never a hardcoded one (`${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`'s Adaptive Language Rule).

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, raise no question at all — § Container Mode: Push the Branch's own `INTERACTIVE_MODE=agent` branch decides whether that run pushes and logs its own `agent-mode: container-push …` line.*

Count commits on this branch:

**When `CONTAINER_MODE=false` (inline mode, unchanged):**
```bash
git log --oneline $DEFAULT_BRANCH..HEAD | wc -l
```

**When `CONTAINER_MODE=true`:** the main working tree's `HEAD` was never checked out to `[branchName]` during container-mode execution (the same invariant Phase Mode's Main Working Tree Untouched Invariant establishes for `PHASE_BRANCH`, applied here by analogy), and the container that held it has just been removed above — count against the branch itself instead of `HEAD`, scoped per project group. A single global `$AIMI_ROOT`/`$DEFAULT_BRANCH` git log is wrong here: in a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`) there is no repo at `$AIMI_ROOT` and `$DEFAULT_BRANCH` was never set. For each unique `group_key` with a container from this run (see Container Paths Per Project Group), mirroring the same "for each unique `group_key`" loop **Container Mode: Push the Branch** and **Container Mode: Remove the Container** above already use. Read and validate `branchName` again — each Bash call is an isolated shell:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
if [ "[group_key]" = "DEFAULT" ]; then
  GROUP_ROOT="$AIMI_ROOT"
  GROUP_DEFAULT="$DEFAULT_BRANCH"
else
  GROUP_ROOT="$AIMI_ROOT/[group_key]"
  GROUP_DEFAULT=$($AIMI_CLI detect-default-branch --project "$GROUP_ROOT")
fi
git -C "$GROUP_ROOT" log --oneline "$GROUP_DEFAULT".."$BRANCH_NAME" | wc -l
```

When exactly one `group_key` was scheduled this run (the common single-repo case, `group_key = "DEFAULT"`), report its count on today's single `Commits: [count]` line below — no format change for that case. When more than one `group_key` was scheduled (multi-repo), report one `Commits (project_path): [count]` line per group instead, in place of the single line.

Check for any remaining pending gates across all stories:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI status
```

Parse gate summary from status output:
- `pending_action_gates`: count of stories with gate.type == "action" and gate.status == "pending"
- `pending_verify_gates`: count of stories with gate.type == "verify" and gate.status == "pending"
- `pending_decision_gates`: count of stories with gate.type == "decision" and gate.status == "pending"

A gate is not the only thing that can still be open at this point. A story whose `verification.status` is still the literal `pending` declared a check nobody has judged — it is neither passed nor failed, and until this section it left no trace in the report at all, so a phase could close in silence with every one of its verifications unlooked-at. `verification-report`'s `pending` partition answers that from the same one read the malformed scan uses (see Step 0.7), scoped to the object branch so a story that never declared a verification never enters — the partition counts what was declared and not looked at, never what was never declared:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "${PHASE_MODE:-false}" = true ]; then
  COMPLETION_VERIF_REPORT=$($AIMI_CLI verification-report --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null)
else
  COMPLETION_VERIF_REPORT=$($AIMI_CLI verification-report 2>/dev/null)
fi
# `.pending // []` is deliberate, not defensive habit: a CLI predating this
# partition answers {visual, malformed} with no `pending` key at all, and a
# bare `.pending | length` would abort the whole completion report over a
# section that is meant to be additive. An older CLI reports zero pending
# verifications, which is exactly what it knew.
PENDING_VERIF_COUNT=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.pending // [] | length' 2>/dev/null)
PENDING_VERIF_IDS=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq -r '.pending // [] | join(", ")' 2>/dev/null)
printf 'pending-verification: count=%s ids=%s\n' "${PENDING_VERIF_COUNT:-0}" "${PENDING_VERIF_IDS:-}"
# The `discriminating` partition is read off the SAME captured payload, never a
# second `verification-report` call: one read cannot disagree with itself about
# one file, and two reads across a phase this long can. `// 0` carries the same
# meaning `.pending // []` carries above — a CLI predating the partition answers
# {visual, pending, malformed} with no `discriminating` key, and it must report
# zero rather than abort a completion report over an additive section.
# `completed` is the whole partition (checked + blind + unrecorded), not
# `fraction`'s denominator: `unrecorded` stays out of that denominator on
# purpose, and leaving it out here too would hide exactly the legacy run this
# section exists to make visible — every story completed, nothing recorded.
EVIDENCE_CHECKED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '(.discriminating.checked | length) // 0' 2>/dev/null)
EVIDENCE_COMPLETED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '((.discriminating.checked | length) + (.discriminating.blind | length) + (.discriminating.unrecorded | length)) // 0' 2>/dev/null)
# Unconditional. Printed on every run, whatever the numbers are.
printf 'verification-evidence: discriminating=%s completed=%s\n' "${EVIDENCE_CHECKED:-0}" "${EVIDENCE_COMPLETED:-0}"
if [ "${EVIDENCE_CHECKED:-0}" -eq 0 ] && [ "${EVIDENCE_COMPLETED:-0}" -gt 0 ]; then
  printf 'verification-evidence: completion refused — %s completed stor(y|ies), not one of them carrying a discriminating assertion; a human records why with acknowledge-evidence --reason <text>, and it lapses if the completed count changes\n' "${EVIDENCE_COMPLETED:-0}"
fi
# Echo the acknowledgement that let an unchecked phase close, when one is recorded.
if [ "${PHASE_MODE:-false}" = true ]; then
  EVIDENCE_ACK_JSON=$($AIMI_CLI metadata --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null | jq -c '.evidenceAcknowledged // empty' 2>/dev/null)
else
  EVIDENCE_ACK_JSON=$($AIMI_CLI metadata 2>/dev/null | jq -c '.evidenceAcknowledged // empty' 2>/dev/null)
fi
if [ -n "$EVIDENCE_ACK_JSON" ]; then
  printf 'evidence-acknowledged: %s (%s)\n' "$(printf '%s' "$EVIDENCE_ACK_JSON" | jq -r '.reason')" "$(printf '%s' "$EVIDENCE_ACK_JSON" | jq -r '.acknowledgedAt')"
fi
# `skipped` is read off the SAME captured payload too, for the identical
# one-read-cannot-disagree-with-itself reason the discriminating comment
# above gives. `// []` carries the same meaning `.pending // []` carries —
# a CLI predating this key answers {visual, pending, malformed,
# discriminating} with no `skipped` key at all, and it must report zero
# rather than abort a completion report over an additive section.
SKIPPED_VERIF_COUNT=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.skipped // [] | length' 2>/dev/null)
SKIPPED_VERIF_LINES=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq -r '.skipped // [] | map("  " + .id + " — " + (.reason // "no reason recorded")) | join("\n")' 2>/dev/null)
printf 'skipped-verification: count=%s\n' "${SKIPPED_VERIF_COUNT:-0}"
# `verdicts` is read off the SAME captured payload too, for the identical
# one-read-cannot-disagree-with-itself reason the two comments above give.
# Each `// 0` carries the same meaning every other default on this payload
# carries — a CLI predating this key answers {visual, pending, malformed,
# discriminating, skipped} with no `verdicts` key at all, and each of its
# five counts must report zero rather than abort a completion report over
# an additive section.
VERDICT_PASSED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.passed // 0' 2>/dev/null)
VERDICT_FAILED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.failed // 0' 2>/dev/null)
VERDICT_SKIPPED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.skipped // 0' 2>/dev/null)
VERDICT_PENDING=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.pending // 0' 2>/dev/null)
VERDICT_OTHER=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.other // 0' 2>/dev/null)
# Unconditional, like `verification-evidence:` above and for the identical
# reason — see that printf's own comment.
printf 'verdicts: passed=%s failed=%s skipped=%s pending=%s other=%s\n' \
  "${VERDICT_PASSED:-0}" "${VERDICT_FAILED:-0}" "${VERDICT_SKIPPED:-0}" "${VERDICT_PENDING:-0}" "${VERDICT_OTHER:-0}"
```

In phase mode the file named is this phase's own tasks file, the same one Step 5 already scopes its story-level reporting to. In flat mode the flag is omitted so the wrapper resolves the session-bound file itself — the one case in this command where `verification-report`'s `get_tasks_file` fallback is the right answer, because by Step 5 `init-session` has long since pointed session state at the file this run executed.

```
## Execution Complete

All stories completed successfully!

Branch: [branchName]
Waves: [total_waves]
Commits: [count]
```

In flat container mode with more than one `group_key` scheduled this run, replace the single `Commits: [count]` line above with one line per group instead:
```
Commits (project_path): [count]
Commits (project_path): [count]
```

Aggregate known-gap files from this run:
```bash
if [ -d .aimi/known-gaps ] && [ -n "$(ls .aimi/known-gaps/ 2>/dev/null)" ]; then
  echo ""
  echo "## Known Gaps"
  for gap_file in .aimi/known-gaps/*.md; do
    [ -f "$gap_file" ] || continue
    story_id=$(basename "$gap_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/^(US-[0-9]+).*/\1/')
    echo ""
    echo "### $story_id"
    cat "$gap_file"
  done
fi
```

If `PENDING_VERIF_COUNT` > 0, append:
```
## Pending Verification

[PENDING_VERIF_COUNT] stor(y|ies) declared a verification that has not been
judged — not passed, not failed, still `pending`:

  [PENDING_VERIF_IDS]

These stories are complete as work and open as verification. Nothing here
blocks the branch or the PR; it is named because the alternative is a phase
that closes with its checks unlooked-at and says nothing about it.
```

If `PENDING_VERIF_COUNT` is 0 (or the section's own command produced nothing — an older CLI with no `pending` partition reads as zero), omit the `## Pending Verification` section entirely.

If `SKIPPED_VERIF_COUNT` > 0, append:
```
## Skipped Verification

[SKIPPED_VERIF_COUNT] completed stor(y|ies) recorded a verification that was
short-circuited rather than judged — not passed, not failed, deliberately
`skipped`:

[SKIPPED_VERIF_LINES]

Each line is the story id and the reason recorded for skipping it, or the
literal "no reason recorded" for a legacy skip that predates this field.
Nothing here blocks the branch or the PR; it is named so a skip is never
silent about why it happened.
```

If `SKIPPED_VERIF_COUNT` is 0 (or the section's own command produced nothing — an older CLI with no `skipped` key reads as zero), omit the `## Skipped Verification` section entirely — the identical omit-at-zero rule `## Pending Verification` takes immediately above, and for the identical reason: both report a POSITIVE fact (a story did something worth naming), so zero of either is genuinely nothing to report, no story declared-and-unjudged, no story short-circuited its own verdict. This is deliberately the SAME rule `## Verification Evidence` immediately below refuses to take — see the reasoned paragraph beside that section for why zero *discriminating* evidence is the one silence this report must never allow, unlike zero pending or zero skipped, which are both silences this report is glad to have nothing to say about.

Append, on **every** run — never omitted, never conditional on the numbers being good:
```
## Verification Evidence

discriminating=[EVIDENCE_CHECKED] completed=[EVIDENCE_COMPLETED]
verdicts: passed=[VERDICT_PASSED] failed=[VERDICT_FAILED] skipped=[VERDICT_SKIPPED] pending=[VERDICT_PENDING] other=[VERDICT_OTHER]

[EVIDENCE_CHECKED] of [EVIDENCE_COMPLETED] completed stor(y|ies) recorded a
verify that discriminated — at least one assertion that behaved differently
before the story's work than after it. The rest either recorded an honest zero
or recorded nothing at all.
```

When `EVIDENCE_CHECKED` is 0 and `EVIDENCE_COMPLETED` is greater than 0, append this paragraph to that same section — the identical condition the `completion refused` printf above carries, restated here so the streamed line and the written section can never disagree about one run:
```
This phase closed unchecked. Every story is complete and not one of them left
evidence that anything was actually verified.
```

When `EVIDENCE_ACK_JSON` is non-empty, add one more line to that section: `Acknowledged: <reason> (<acknowledgedAt>)`.

**This section deliberately does NOT take `## Pending Verification`'s omit-at-zero rule, and a later edit must not tidy the two into consistency.** They look like neighbours and they are opposites. Zero pending verifications is genuinely nothing to report — nobody declared a check that nobody judged, so the section has no subject. Zero *discriminating* verifications is the single loudest thing this report can say: it means the phase closed with no evidence that anything was checked, and that is exactly the run a silent report makes indistinguishable from a flawless one. "33/33 completed, 0 unmet" is equally compatible with both, which is the defect this section exists to remove; a line that only prints when the number is good would rebuild it. The absence has to be as visible as the presence, so the numbers print whatever they are.

**The `verdicts:` line beside it is deliberately kept OUT of `handoff.md`'s `## Deviations` array and out of the locked-token list two bullets above it (Write Handoff, `verification-evidence:`/`verification-skipped:`), and a later edit must not "complete the set" by adding it there — and not for the reason it first looks like.** Write Handoff already makes its own dedicated `verification-report` call at that point in the flow (the one that reads `.skipped` for the `verification-skipped:` line) and that same response already carries `.verdicts` too, at no extra cost — so "it would take a second, possibly-disagreeing call" is not why this stays out; that call already exists. The real reason is what a handoff exists to preserve. `verification-evidence:`'s `m`/`n` counts THIS RUN's own contribution, computed from Step 4's own per-run accumulator — a fact no later read of the tasks file can recover, because nothing in the document records which run completed which story, so the handoff is the only place that fact survives at all. `verdicts` carries no such unrecoverable fact: it is a pure function of the finished tasks file, answerable by re-running `verification-report` for as long as that file exists — forever, for a completed phase. The one piece of the distribution worth writing down permanently — WHY a story was short-circuited — is already itemized, one line per story, in `verification-skipped:` above; the rest is a summary a later reader can always ask for again, never information that would otherwise be gone.

Append, on **every** run, immediately after `## Verification Evidence` above — the **Finalize Step** (Step 4, after Post-Loop Cleanup) always leaves `FINALIZE_STATUS` set, so there is always something to say:
```
## Finalize

status: [FINALIZE_STATUS]
commit: [FINALIZE_COMMIT]
subject: [FINALIZE_SUBJECT]
reason: [FINALIZE_REASON]
```

Render exactly the lines that carry a value: on `status: ran`, print `commit:` and `subject:` and omit `reason:`; on `status: skipped` or `status: failed`, print `reason:` — the step's own recorded sentence, verbatim, whether it is `metadata.finalize not declared`, a project-group count, or a merge conflict — and omit `commit:` and `subject:`, which name a commit that was never made.

This section takes `## Verification Evidence`'s print-whatever-it-is rule rather than `## Pending Verification`'s omit-at-zero one, for the same reason: `skipped` is the answer a reader most needs and the one a conditional section would hide. A run whose closing commit never happened looks, in a report that omits the section, exactly like a run whose closing commit landed — and the operator finds out at release time. `ran` with no commit sha is likewise impossible by construction: the Finalize Step only reaches `ran` after `merge-all` returns and `rev-parse` has answered.

If `DESIGN_REVIEW_BUFFERS` is non-empty, append:
```
## Design Review

For each entry in DESIGN_REVIEW_BUFFERS (keyed by story id, insertion order):

### [story_id]: [entry.title]

[entry.output]
```

If `DESIGN_REVIEW_BUFFERS` is empty, omit the `## Design Review` section entirely.

**Persist that section, then name the file it was written to.** Until this step the design reviews existed only in the transcript: the reviewer agent ran per story in Step 4, its output was buffered, printed once here, and lost with the session — so a review nobody read in the hour it was printed was a review nobody could read at all. `write-review` writes it to `.aimi/reviews/<feature>-phase-<N>.md` under the same `mktemp`-then-`mv` discipline every other document writer in this CLI uses, and returns `{review: "<path>"}`. Run this when `DESIGN_REVIEW_BUFFERS` is non-empty **and** `PHASE_MODE=true` and `$PHASE_ID` is set — the verb takes a feature and a phase, and those are the only two values that name the file. Compose the whole section body first (every `### [story_id]: [entry.title]` block and its `[entry.output]`, in insertion order, exactly as printed above) and pipe it in one call: the path is derived from feature and phase alone, so one call per story would have every story overwrite the last and leave only the final review on disk.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DESIGN_REVIEW_BODY=$(cat <<'DESIGN_REVIEW_EOF'
[paste the composed ## Design Review section body here, verbatim — every
### [story_id]: [entry.title] heading and its [entry.output], insertion order]
DESIGN_REVIEW_EOF
)
DESIGN_REVIEW_JSON=$(printf '%s\n' "$DESIGN_REVIEW_BODY" | $AIMI_CLI write-review --feature "$FEATURE" --phase "$PHASE_ID") || DESIGN_REVIEW_JSON=""
DESIGN_REVIEW_PATH=$(printf '%s' "$DESIGN_REVIEW_JSON" | jq -r '.review // empty' 2>/dev/null)
printf 'design-review: %s\n' "${DESIGN_REVIEW_PATH:-<not written>}"
```

The heredoc delimiter is quoted, so review prose carrying `$`, backticks or `$(` reaches the verb as the bytes the reviewer wrote rather than as something this shell tries to expand. `|| DESIGN_REVIEW_JSON=""` is what keeps a refusal advisory: `write-review` refuses an empty stdin at exit 1 rather than leaving a zero-byte file that reads on disk exactly like a review that was never written, and a completion report is not the place to abort over a document that was already printed in full two paragraphs above.

When `DESIGN_REVIEW_PATH` is non-empty, append the path to the `## Design Review` section as its last line, so the reader is told where the section they just read now lives:
```

Written to: [DESIGN_REVIEW_PATH]
```

When the write did not happen, say which of the two reasons applies rather than printing nothing:

- **`PHASE_MODE=false`** (flat execution, no roadmap and so no `FEATURE`/`PHASE_ID` pair): append `Not written to disk — flat execution has no feature/phase pair to name a review file.` The verb is not called at all here; inventing a phase id to satisfy it would put a review under a phase that does not exist.
- **The call ran and returned nothing** (`DESIGN_REVIEW_PATH` empty at exit): append `Not written to disk — write-review returned no path; the review above is the only copy.` Say it plainly; a reader who believes a file was written and finds none is worse off than one who was told the transcript is it.

If `CONSOLE_BUFFER` is non-empty, append:
```
## Console (advisory)

For each entry in CONSOLE_BUFFER (keyed by story id, insertion order):

### [story_id]
- [N] errors, [M] warnings, [E] exceptions
[For each entry in attributed where story_id matches:]
  - [kind] [text] (attribution: [attribution_method])

If any record was attributed via "text-component" or "wave-shared", prefix the
record's line with "likely:" so the user knows the call is heuristic.

[After per-story groups, if any wave-shared entries exist:]
### wave-shared
- [N] message(s) could not be attributed to a single story
  - [kind] [text]

Reminder: Console output is advisory. It does NOT change `verification.status`
and never blocks the wave — failed visual stories still fail on screenshot
mismatch only.
```

If `CONSOLE_BUFFER` is empty, omit the `## Console` section entirely.

If `ROADMAP_SWEEP_REPORT` is set (only ever set by Phase Completion's Next Phase step, roadmap-exhaustion branch), append:
```
## Roadmap Sweep

No phase remains ready to plan or claim — every phase in [FEATURE]'s roadmap
is completed, verification_failed, or otherwise not pending/planned.
Residual report from `roadmap-sweep`:

[If ROADMAP_SWEEP_REPORT.orphanCreates is non-empty:]
Orphan creates (declared but never consumed by any needs):
  For each: "  - phase [entry.phase]: [entry.creates]"

[If ROADMAP_SWEEP_REPORT.deferredNeeds is non-empty:]
Deferred needs (a provider exists but has not completed):
  For each: "  - phase [entry.phase] needs \"[entry.need]\", provided by phase [entry.deferred] (not yet completed)"

[If ROADMAP_SWEEP_REPORT.warnings is non-empty:]
Warnings:
  For each: "  - phase [entry.phase] field '[entry.field]': [entry.message]"

[If orphanCreates, deferredNeeds, and warnings are all empty:]
No residual gaps — every declared creates entry is consumed and every need is satisfied.
```

If `ROADMAP_SWEEP_REPORT` is unset, omit the `## Roadmap Sweep` section entirely.

If any pending gates exist, append:
```
### Pending Gates

[If pending_action_gates > 0:]
Action gates ([pending_action_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_verify_gates > 0:]
Verify gates ([pending_verify_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_decision_gates > 0:]
Decision gates ([pending_decision_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

Resolve gates with: $AIMI_CLI gate-pass <story-id> [--option 'value']
```

**When `CONTAINER_MODE=false` (inline mode):** no container was ever created and nothing was torn down, so the branch is still checked out right here — use the bare form, with no `--branch`, so that `/aimi:open-pr` still runs its uncommitted-changes check (it skips that check whenever `--branch` names a branch, since that branch is checked out elsewhere or nowhere). Naming the command at all is the obligation `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` § Always Name /aimi:open-pr states.
```
### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Open a PR when ready: `/aimi:open-pr`
```

**When `CONTAINER_MODE=true`:** the container was already removed above and nothing is checked out anywhere, so use the argument forms that work for a branch checked out nowhere instead:
```
### Next Steps

- Review commits: `git log --oneline -[count]`
- Open a PR: `/aimi:open-pr --branch [branchName]`
- Run `/aimi:review [branchName]` for code review
```

