# Execute: Phase Completion: Offer a Pull Request

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Offer a Pull Request

Best-effort only — never reverts or changes the already-`completed` status on failure or refusal. Runs once per participating repository — the same project groups **Mark Phase Completed**'s report above already derived. Re-derived fresh in this block, since each Bash call is an isolated shell and nothing from that earlier block persists here:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "$PHASE_SPLIT_MODE" = true ]; then
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  # Hoisted once, above the loop -- never re-called per split_file.
  PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
  PHASE_GROUP_RAW=""
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    GROUP_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // "."')
    PHASE_GROUP_RAW="${PHASE_GROUP_RAW}${GROUP_PROJECT}"$'\n'
  done <<< "$PHASE_SPLIT_FILES"
  PHASE_GROUP_PROJECTS=$(printf '%s\n' "$PHASE_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PHASE_GROUP_PROJECTS" ] || PHASE_GROUP_PROJECTS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline. A refusal here just skips
  # this best-effort step -- the already-`completed` status above is never
  # reverted.
  PHASE_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || exit 1
  PHASE_GROUP_PROJECTS=$(printf '%s' "$PHASE_GROUPS_JSON" | jq -r '.groups[]')
fi
```

#### Select the acting forge account per repository

Before any of those repositories is pushed or gets a pull request, settle which account will author those writes — once per repository ever, and **separately per repository**, since a multi-repo phase can legitimately span two repositories that want two different accounts. Resolve interactivity once (re-resolved here when still unset, the same cheap idempotent safety net the per-repo base-branch picker above uses, since each Bash call is an isolated shell) and ask the CLI, per group, whether the question is warranted:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -z "$INTERACTIVE_MODE" ]; then
  INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
fi
echo "$INTERACTIVE_MODE"
while IFS= read -r ACCOUNT_GROUP_PROJECT; do
  [ -n "$ACCOUNT_GROUP_PROJECT" ] || continue
  if [ "$ACCOUNT_GROUP_PROJECT" = "." ]; then
    ACCOUNT_GROUP_ROOT="$AIMI_ROOT"
  else
    ACCOUNT_GROUP_ROOT="$AIMI_ROOT/$ACCOUNT_GROUP_PROJECT"
  fi
  ACCOUNT_GROUP_TOPLEVEL=$(git -C "$ACCOUNT_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || ACCOUNT_GROUP_TOPLEVEL=""
  [ -n "$ACCOUNT_GROUP_TOPLEVEL" ] || continue
  ACCOUNT_CHECK_JSON=$($AIMI_CLI forge-account-select --check --project "$ACCOUNT_GROUP_TOPLEVEL") || ACCOUNT_CHECK_JSON=""
  [ -n "$ACCOUNT_CHECK_JSON" ] || continue
  printf '%s\t%s\t%s\n' "$ACCOUNT_GROUP_PROJECT" "$ACCOUNT_GROUP_TOPLEVEL" "$ACCOUNT_CHECK_JSON"
done <<< "$PHASE_GROUP_PROJECTS"
```

Each printed line is one repository: its group key, its repository root, and its `forge-account-select --check` verdict. `detect-interactivity` prints exactly `picker` or `agent`, and `picker` is the default — `agent` comes only from an explicit opt-out (`--non-interactive`, `AIMI_AGENT_MODE=true`, `CI=true`); a non-TTY shell is **not** a signal for agent mode. `commands/references/interactivity.md` is the arbiter for mode resolution, option format and the agent-mode rule at this site.

Ask for a given repository **only** when `INTERACTIVE_MODE` is `picker` AND that line's `.decision` is `"ask"` — the same two-condition AND the first-run model prompt uses (`commands/references/cli-path-resolution.md`). `forge-account-select --check` owns the second condition entirely: it reports `"ask"` only when that repository has no recorded answer *for its own host* and that project's git identity and the active forge account actually diverge. It decides on that repository's own entry, never on the store file's existence, so a store already holding other repositories' answers still asks here. Every other `.basis` — `answer_recorded`, `identity_override`, `no_repository`, `no_host`, `single_account`, `identity_matches_active`, `not_authenticated`, `cli_missing`, `no_adapter` — reports `"skip"`: that repository gets no picker and no output. `--check` writes nothing, so evaluating it never changes what a later run asks.

**When `INTERACTIVE_MODE=picker` and a line's `.decision == "ask"`:** Use **AskUserQuestion** once for that repository, naming it so a multi-repo run's separate prompts stay distinguishable — the same discipline the per-repo `resolve-base-branch` picker above follows:

```
Which account should author the pull request for [project_path] on [host]?

A — Always use the active account ([activeAccount])
B — [the divergence candidate]
C/D/E — [further logged-in accounts, in the order .accounts lists them]
Other — Enter a different account login
```

- **Option A** is deliberately the least disruptive answer, and it is the one agent mode auto-picks below: every write for that repository stays on whichever account is active.
- **Option B** is the divergence candidate — the login in that line's `.accounts` that the repository's own git identity points at and that is not `.activeAccount`. Derive it from `.identity.email`: a `…@users.noreply.github.com` address encodes the login exactly (dropping any leading `<digits>+`); otherwise use the address's local-part with the same leading `<digits>+` dropped. When no `.accounts` entry matches, option B is the first `.accounts` entry other than `.activeAccount`.
- **C/D/E** are the remaining `.accounts` entries in gh's own order, and **Other** is the free-form escape hatch, always last. Never fewer than 2 options and never more than 6 in total, so at most five accounts are listed; when gh reports more than fit, keep option A and the divergence candidate and drop the remainder — `Other` already covers them.

Record the answer once per repository that was actually answered — picker mode only. Both the repository and the chosen value cross into this call as literals the orchestrator substitutes, never as shell variables carried over from the enumeration fence above:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FORGE_ACCOUNT_PROJECT="[the repository root printed for the group just answered]"
FORGE_ACCOUNT_CHOICE="[the account chosen above — the literal word active for option A, otherwise the login]"
if [ "$FORGE_ACCOUNT_CHOICE" = "active" ]; then
  $AIMI_CLI forge-account-select --record-active --project "$FORGE_ACCOUNT_PROJECT"
elif echo "$FORGE_ACCOUNT_CHOICE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9-]*$'; then
  $AIMI_CLI forge-account-select --record "$FORGE_ACCOUNT_CHOICE" --project "$FORGE_ACCOUNT_PROJECT"
else
  echo "Not a forge login: $FORGE_ACCOUNT_CHOICE — nothing recorded for $FORGE_ACCOUNT_PROJECT." >&2
fi
```

Option A records the permanent "always use the active account" opt-out — a real stored answer, not the absence of one, which is why it stops the question being raised for that repository again. Every other option records that login. A free-form `Other` value that fails the login shape records nothing and is reported, and this step then continues on the active account rather than stopping: this whole step is best-effort like the rest of **Offer a Pull Request**, and the phase is already `completed`. Because nothing was recorded, the next run asks that repository again. This command layer performs no file I/O of its own — it owns the prompt, and `forge-account-select` owns both "should I ask?" and "remember this answer".

**When `INTERACTIVE_MODE=agent`** (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`): no picker for any repository. Auto-select option A — act as whichever account is active — and make **no** `forge-account-select --record` or `--record-active` call at all, for any repository. Applying option A takes no action of any kind: the active account is already the one every forge verb uses, so "applied for this invocation" and "changed nothing" are the same thing here. Every participating repository's recorded state after an agent-mode run is byte-for-byte what it was before. Log exactly one line per repository — no retry, no blocking, no second line:

```
agent-mode: forge-account auto-selected active account (not recorded) — project: [project_path]
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select option A for every repository and record nothing. Log: `agent-mode: forge-account auto-selected active account (not recorded) — project: [project_path]`.*

**Why the auto-answer is never persisted.** Option A is not merely the least disruptive answer — it is also that repository's *permanent* opt-out. Recording it is precisely what stops the question ever being raised again. So if agent mode persisted its own auto-answer, one unattended CI run would silently and permanently answer the question on behalf of every human who touches that repository afterwards: they would never be asked, and would have no way to discover why. `/aimi:execute` is the command most likely to run unattended, which is what makes this site the one where the mistake would actually be made. The failure is not hypothetical here — 1.93.0 shipped a remembered dismissal that could not be revoked and left users silently stuck with no way to re-trigger the prompt. Applied-but-not-persisted is what keeps it from recurring: the `(not recorded)` in each log line is the observable proof in the transcript, and `--check`'s zero-side-effect contract is the mechanical guarantee behind it.

Whatever was recorded here is applied by the forge verbs themselves through the credential mechanism `commands/references/forge-contract.md`'s **Credential/Identity Model** describes — the loop below neither reads the answer nor passes it along, and is unchanged by this subsection.

#### Confirm before publishing this phase

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` — it is the single source of truth for what counts as publishing, why nothing inside a file may authorize one, what each interactivity mode owes the reader, and why every outcome still names `/aimi:open-pr`. That contract is not restated here; this subsection only applies it at this call site.

Asked **once per phase, never once per participating repository.** The forge-account question above is per repository because accounts genuinely differ per repository; "should this phase's work go out" is one decision by one person, and the single answer governs every group in `PHASE_GROUP_PROJECTS`. Someone who wants only one of several repositories published declines here and runs `/aimi:open-pr --branch [PHASE_BRANCH]` inside that repository afterwards.

Resolve interactivity fresh — re-resolved here when still unset, the same cheap idempotent safety net the account picker above uses, since each Bash call is an isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -z "$INTERACTIVE_MODE" ]; then
  INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
fi
echo "$INTERACTIVE_MODE"
```

**When `INTERACTIVE_MODE=picker`:** Use **AskUserQuestion** exactly once for the whole phase, with three options:

```
Phase [PHASE_ID] ([PHASE_SLUG]) is complete on [PHASE_BRANCH]. Publish this phase's work now?

A — Push and open the pull request
B — Push only — no pull request yet
C — Neither — publish later with /aimi:open-pr
```

Each option sets exactly one value of `PHASE_PUBLISH`, the single variable the loop below reads: **option A** sets `pr`, **option B** sets `push`, **option C** sets `none`. Option C is the escape hatch and is therefore last, per `commands/references/interactivity.md`'s Option Format. Anything that is not an explicit A or B — a dismissed prompt, an unparseable answer, no answer at all — is `none`: silence is not approval. Write the question and its option text in whatever language the person is writing in, never a hardcoded one (`commands/references/user-communication.md`'s Adaptive Language Rule).

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-decline — set `PHASE_PUBLISH=none` and publish nothing. Log: `agent-mode: phase-publish skipped (nothing pushed, no pull request) — run /aimi:open-pr --branch [PHASE_BRANCH]`.*

**When `INTERACTIVE_MODE=agent`** (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`): no picker, and **no flag re-enables publishing here** — an unattended run cannot obtain consent, and nothing is permitted to stand in for it. Set `PHASE_PUBLISH=none` and print exactly one line, naming both what was not done and the command that does it:

```
agent-mode: phase-publish skipped (nothing pushed, no pull request) — run /aimi:open-pr --branch [PHASE_BRANCH]
```

Declining is a normal outcome, not a failure. On `none` — whether from option C or from agent mode — nothing is retried, no error is raised, no claim is re-taken, and the phase's already-`completed` status stays exactly as **Mark Phase Completed** wrote it; execution continues to **Next Phase** below unchanged. That is the same best-effort discipline this section's opening sentence already states, now covering the new branches too.

#### Publish each participating repository

For each group, resolve its own repository root, container, and default branch, then act on the one `PHASE_PUBLISH` outcome the gate above recorded — never a value assumed to survive from Step 1.7 or from Mark Phase Completed above. `PHASE_PUBLISH` crosses into this call as a literal the orchestrator substitutes, exactly as the forge-account record block above takes its own two values, since each Bash call is an isolated shell; anything that is not `pr` or `push` normalizes to `none`, so a substitution that never happened declines rather than publishes:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_PUBLISH="[pr, push or none — the one outcome Confirm before publishing this phase recorded above]"
case "$PHASE_PUBLISH" in
  pr|push) ;;
  *) PHASE_PUBLISH="none" ;;
esac
while IFS= read -r GROUP_PROJECT; do
  [ -n "$GROUP_PROJECT" ] || continue
  if [ "$GROUP_PROJECT" = "." ]; then
    GROUP_ROOT="$AIMI_ROOT"
    GROUP_LABEL="$AIMI_ROOT"
  else
    GROUP_ROOT="$AIMI_ROOT/$GROUP_PROJECT"
    GROUP_LABEL="$GROUP_PROJECT"
  fi
  GROUP_TOPLEVEL=$(git -C "$GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || GROUP_TOPLEVEL=""
  if [ -z "$GROUP_TOPLEVEL" ]; then
    echo "Skipping PR for $GROUP_LABEL — not a git repository at $GROUP_ROOT."
    continue
  fi
  GROUP_CONTAINER="$GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"
  GROUP_DEFAULT=$($AIMI_CLI detect-default-branch --project "$GROUP_TOPLEVEL") || GROUP_DEFAULT=""

  if [ "$PHASE_PUBLISH" = "none" ]; then
    echo "Nothing published for $GROUP_LABEL — no push, no pull request. Publish it when you are ready:"
    echo "  /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi

  GROUP_FORGE_STATUS=$($AIMI_CLI forge-auth-status --project "$GROUP_TOPLEVEL" | jq -r '.status // empty')
  if [ "$GROUP_FORGE_STATUS" != "found" ]; then
    echo "No usable forge for $GROUP_LABEL — skipping the push and the pull request. Do both manually:"
    echo "  git -C \"$GROUP_CONTAINER\" push -u origin $PHASE_BRANCH"
    echo "  Then open a PR: $GROUP_DEFAULT...$PHASE_BRANCH"
    echo "  Once a forge CLI is installed and authenticated for this repository, run this from $GROUP_TOPLEVEL instead: /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi

  cd "$GROUP_CONTAINER"
  git push -u origin "$PHASE_BRANCH"
  if [ "$PHASE_PUBLISH" = "push" ]; then
    echo "Pushed $PHASE_BRANCH for $GROUP_LABEL — no pull request opened. Open one when you are ready:"
    echo "  /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi
  GROUP_PR_JSON=$($AIMI_CLI forge-pr-create --base "$GROUP_DEFAULT" --head "$PHASE_BRANCH" \
    --title "Phase [PHASE_ID]: [PHASE_NAME]" \
    --body "Completes phase [PHASE_ID] of [FEATURE]. See [PHASE_DIR]/handoff.md for details." \
    --project "$GROUP_TOPLEVEL") || GROUP_PR_JSON=""
  if [ -n "$GROUP_PR_JSON" ]; then
    GROUP_PR_STATUS=$(printf '%s' "$GROUP_PR_JSON" | jq -r '.status // empty')
    GROUP_PR_URL=$(printf '%s' "$GROUP_PR_JSON" | jq -r '.data.url // empty')
    if [ "$GROUP_PR_STATUS" = "created" ]; then
      echo "Opened pull request for $GROUP_LABEL: $GROUP_PR_URL"
    elif [ "$GROUP_PR_STATUS" = "unchanged" ]; then
      echo "Pull request already exists for $GROUP_LABEL: $GROUP_PR_URL"
    fi
  else
    echo "Pull request not opened for $GROUP_LABEL — see forge-pr-create's error above."
  fi
done <<< "$PHASE_GROUP_PROJECTS"
cd "$AIMI_ROOT"
```

`PHASE_PUBLISH` is the only thing in this loop that decides **whether** to publish, and it decides nothing else. On `none` the repository's own decline line is printed with the `/aimi:open-pr --branch` command that publishes it later, and the iteration ends before `forge-auth-status` is even consulted — no forge is queried, no `origin` is contacted, and the branch stays exactly where the container left it. On `push` the branch is pushed and the iteration ends before `forge-pr-create`, printing the same `/aimi:open-pr --branch` command, which is safe to suggest for an already-pushed branch precisely because `/aimi:open-pr` re-attempts the push itself (`${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` § Always Name /aimi:open-pr). On `pr` the loop body runs end to end exactly as it did before this gate existed. Every other decision in the loop is untouched by all three: the not-a-git-repository skip, the `forge-auth-status` pre-push check and its recovery block, the `created`/`unchanged` reporting, the blank-`GROUP_PR_JSON` else branch, and the closing `cd "$AIMI_ROOT"` — which still runs after the loop no matter which branch each repository took. No branch here reverts, re-reads or rewrites the phase's `completed` status, and none re-claims the phase.

`forge-auth-status` is this loop's own actionability check, and it deliberately runs **before** the push rather than after it. It reports `status: "found"` if and only if the repository's remote resolves to a forge that has a working write adapter **and** that adapter's CLI is present on `PATH` — precisely the two conditions `forge-pr-create` gates its own write on (`commands/references/forge-contract.md`). This loop therefore reads that one `status` field and never re-derives the forge type or probes for a CLI binary itself, which is also why the check extends for free: the moment a GitLab or Gitea write adapter makes `forge-auth-status` report `found` for those remotes, they start pushing and opening PRs here with no change to this file. `data.authenticated` is deliberately **not** consulted — an installed-but-unauthenticated CLI still reaches the create call and fails there, which is an ordinary per-repository failure this loop already reports, not a reason to withhold the branch. Any status other than `found` means nothing here can open a pull request for that repository, so its branch is not published either: the loop prints that repository's own recovery block — its label, the container-scoped `git push -u origin` command, the `$GROUP_DEFAULT...$PHASE_BRANCH` compare range, and the `/aimi:open-pr --branch` line to run from that repository's own root once a forge CLI is installed and authenticated there — and moves to the next repository without ever touching `origin`. That last line is deliberately conditional: this branch fires precisely because no forge adapter or CLI is usable here, and `/aimi:open-pr` routes through the same forge verbs, so it would stop on the same condition if it were run right now. The push command and the compare range above it are the fallback that works with no forge at all, which is why both stay.

**This is stricter than the binary-presence gate phase 1 deleted, not a restoration of it.** That gate tested only whether a GitHub CLI existed on `PATH`, so a GitLab or Gitea remote on a machine that happened to have one installed *did* get its branch pushed; only the PR call failed, leaving a merge request openable from the forge's web UI. Routing the decision through `forge-auth-status` withdraws that push, on the principle that whether a branch reaches `origin` should not depend on an unrelated binary being installed. The recovery block above is what keeps that a defensible change rather than a regression — those users lose one pasted command, not the push itself.

`forge-pr-create` owns the presence check for whichever forge CLI this repository's remote needs, independently of the pre-push check above. When the forge is unsupported, its CLI is missing, or the create call itself fails, `forge-pr-create` prints the manual push/PR-URL fallback instructions itself (mandatory-print degrade mode, `commands/references/forge-contract.md`), emits a `status: "degraded"` envelope, and exits non-zero; this loop does not reimplement or duplicate that guidance — the non-zero exit blanks `GROUP_PR_JSON`, so neither the "opened" nor the "already exists" echo can be reached, and the `else` branch instead echoes one line naming that repository. That line is the attribution `_forge_pr_write_print_manual` cannot supply on its own: it has no repository context to name, so its banner is unattributed by construction, and a phase with N failing repositories would otherwise produce N indistinguishable banners. `forge-pr-create` checks for an existing open PR on `$PHASE_BRANCH` before ever creating one (its own check-then-create contract, matching open-pr.md's pre-existing "PR already exists" behavior) — a retried or re-entered phase reuses that PR (`status: "unchanged"`, `forge-contract.md`'s Write-Verb Status Convention: no new PR number was minted) rather than opening a duplicate.

If `git push` or `forge-pr-create` fails for a given repository (no permissions, offline, branch already has an open PR the tool itself cannot read, etc.), that repository's failure is what `forge-pr-create` already reported on stderr — report it verbatim, echo the loop's own per-repository line naming it, and continue on to the next repository — do not retry, do not prompt interactively, and never revert the phase's `completed` status. The `forge-auth-status` skip above obeys the same isolation contract: it is reported for that one repository, it consumes no other repository's turn, and the phase stays `completed` no matter how many of the participating repositories are skipped or fail.

With exactly one participating group — today's only previously-supported case — `PHASE_GROUP_PROJECTS` resolves to exactly `.`, `GROUP_TOPLEVEL` resolves to the same repository `$PHASE_CONTAINER_PATH` was built from, so `GROUP_CONTAINER` equals `$PHASE_CONTAINER_PATH` exactly, and `GROUP_DEFAULT` — detected fresh via the identical `--project`-scoped call Step 1.5's own `$DEFAULT_BRANCH` detection uses — equals `$DEFAULT_BRANCH`. Under the approving `pr` answer the push and the forge call issued are therefore the same single-repository push and PR creation as before, now routed through `forge-pr-create` instead of a direct GitHub-CLI invocation. That single repository is subject to the `forge-auth-status` check like any other: when its own status is not `found`, neither the push nor the PR call runs at all — the one group prints its recovery block, the loop body ends there, and the phase still finishes `completed`, exactly as the skip behaves for one repository out of many. When more than one group participates, the loop runs once per repository, each against its own container, its own default branch, its own actionability check, and its own pull request.

