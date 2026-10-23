# Plan: Phase 0: Issue Reference Confirmation Gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Issue Reference Confirmation Gate

Runs after Phase 0.5 and before Phase 1. `FEATURE_DESCRIPTION` and
`INTERACTIVE_MODE` are both already resolved by Step 0 at this point, so this
gate reads nothing the pipeline has not produced yet, and it writes exactly one
optional key — `metadata.issues`, the forge-confirmed issue numbers this plan
closes, which `/aimi:open-pr` later renders as `Closes` lines.

The gate is SCAN → RESOLVE → CONFIRM, and every step is there because the step
before it cannot decide alone. A scan finds number-shaped tokens but cannot tell
an issue reference from a version fragment. A forge lookup proves a number names
something real but not that it is work this plan closes — measured on this
repository, `#149` (open) and `#3` (merged) both resolve `status: found`, so
existence alone discriminates nothing. State and title are what carry the
decision, and only a human answers the last question. Do not collapse the three
steps into two.

**SCAN and RESOLVE — one CLI call.** Both steps are decidable with no person
in the loop, so both live in `aimi-cli.sh` and this file calls them rather than
describing them. The verb reads the description, treats every `#<digits>` and
every bare `<digits>` token as a candidate — deduplicated, leading zeros
dropped, positive integers only, because issue numbers start at 1 — resolves
each candidate through the forge, and prints only the survivors whose envelope
`.status` is `found` **and** whose `.data.state` is `open`, as a compact JSON
array of `{number, title}` ascending by number:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"

ISSUE_SURVIVORS=$($AIMI_CLI forge-issue-scan --description "$FEATURE_DESCRIPTION")
printf '%s' "$ISSUE_SURVIVORS"
```

Bare digits are in scope deliberately, and the noise that brings — `v1.2.3`
contributes `1`, `2` and `3` — is the CONFIRM step's problem, not the scan's. A
description that names its issue without a `#` is far more common than one that
names no issue at all, and a candidate nobody confirms costs one forge lookup.

**The verb degrades, so this gate never aborts.** It answers `[]` at exit 0 in
three cases: the description named no candidate (and then no forge was
consulted at all), the working directory is not a git repository, and every
candidate was dropped. Individual candidates leave quietly too — `not_found`
was a version fragment, a line number, or an issue on another repository;
`status: "error"` is offline, no forge configured, no `gh`/`glab`/`tea`,
unauthenticated, or rate-limited; anything but `open` (`closed`, and on a
number that names a pull request, `merged`) is work a plan does not close.
Never surface a raw CLI error from this call to the user: a plan that cannot
reach a forge is still a plan, and the only thing lost is an optional key.

A run in which every candidate is dropped is indistinguishable, from here on,
from a run whose description named no numbers at all: no picker is presented,
nothing is logged, and `metadata.issues` is omitted entirely from the written
tasks.json — never `[]`, never `null`.

**CONFIRM.** When `ISSUE_SURVIVORS` holds anything other than `[]`, present the
whole list in **exactly one** AskUserQuestion call — never one call per
candidate — as a multi-select whose options are the surviving issues, each
labelled with its own element's `number` and `title`:

```
Which issues does this plan close?
#<number> — <title>
#<number> — <title>
…
```

Selecting none is a valid answer and means the same thing as zero survivors.
**Cap the picker at four options**, the same cap `/aimi:setup-models` applies to
its own questions; when more than four survive, sort ascending by number,
present the first four, and emit one warning line naming the numbers left out so
the user knows they were not offered. Record the confirmed numbers in working
memory as `confirmedIssues[]` — an array of positive integers, in ascending
order, holding **only** what the user selected. A survivor the user did not pick
is not recorded and leaves no trace.

**Agent-mode fallback:** when `INTERACTIVE_MODE=agent`, this gate never presents
AskUserQuestion — an unattended run cannot answer one. SCAN and RESOLVE still
run: both are fully automated and need no user input, the same reason the Phase
1.8 scope-pruning gates spawn their verifiers under agent mode and defer only
the question at the end. Only CONFIRM is skipped. It auto-defers with the
reason literal `agent-mode auto-defer (issue confirmation)`, distinct from every
other gate's reason literal in this file so the deferral is greppable back to
this gate, leaves `confirmedIssues[]` empty, and omits `metadata.issues` for that
run. Emit exactly one log line:

```
agent-mode: issue-confirmation-gate deferred <N> candidate issue(s)
```

where `<N>` is the number of surviving open issues that would have been offered.

**It never guesses, and that asymmetry is the whole design.** Confirming nothing
costs a `Closes` line somebody adds by hand. Confirming wrongly makes
`/aimi:open-pr` close an issue nobody approved, on a repository where an
unattended run is exactly the case with no one watching. The two mistakes are
not the same size, so the gate is built to make only the cheap one.

**Recording.** `confirmedIssues[]` is carried in working memory to Phase 4 and
written there as `metadata.issues` by **Derive and Patch Metadata Fields** —
this gate writes no file itself. No validator change is needed for the key:
nothing in `tasks.py` rejects an unknown `metadata` key, and `issues` is
documented as optional in `skills/task-planner/references/task-format-v3.md`.
