# /aimi:review: why it reads

The reasoning behind `commands/review.md`, kept here so the command carries one line of instruction where each passage was. Read it when you change the command or the reviewers in `agents/review/`.

## How the request is read

In ten recorded reviews the person passed free text in nine: a focus ("bugs and security"), a scope ("only the PR's diff"), or both, usually with a PR number or URL. The command used to treat the whole text as a target and always named the same five reviewers, so the orchestrator improvised. It now splits the text into TARGET, SCOPE and FOCUS. The target blocks keep their same-block checks and receive the TARGET alone, the way the command already did for a URL, so a pasted sentence never reaches a shell.

A bare word that is not a number, a URL or an existing branch is a focus: `/aimi:review security` must not fail as an unknown branch.

The comment inside the Setup block no longer repeats the request: a multi-line request pasted into a comment would make its second line a command.

## Which reviewers run

The set was chosen from usage, not from a list of well-known reviewers. Over ten runs, bugs, security and performance were the focus asked for most, and no reviewer existed for bugs; the orchestrator repurposed a TypeScript style reviewer with a prompt that said "only correctness bugs". The default set is now correctness, security, performance and maintainability. The rest run only when the diff touches their subject, which is what Step 2 tabulates.

Reviewers for one language or one framework's style (Rails, Python, TypeScript) are gone: a project's style lives in its own `CLAUDE.md` and `AGENTS.md`, and `aimi-project-standards-reviewer` reads those and cites the rule. Architecture and pattern review overlapped the maintainability reviewer (2 of the 35 findings the architecture reviewer made were its alone), and the data-integrity and schema-drift reviewers overlapped the data-migration reviewer.

A project may define review agents of its own. The host lists them in the session, so the command includes one that fits instead of copying it into the plugin.

## Why the reviewers get data, not the diff

The prompt carries a place to work and the command that prints the diff. In practice the orchestrator already passed a worktree path and a `git diff` command, and the reviewers spent 33 to 54 turns each reading files one `cat` at a time. The shared "How you work" section tells them to use Read, Grep and Glob, and to use Bash to run one check that confirms a finding (14 of 50 reviewers did, in 2% of their commands).

Reviewers never change the repository. The tools list is an accident guard, not a sandbox, so the rule is also stated in the text, and `scripts/tests/test_agent_tools.py` pins the sentence.

## Why the findings are checked

Every reviewer returns the quoted line next to `path:line`, so finding the line costs one read. The line is not the claim, though. A finding usually rests on a premise somewhere else: the guard it says is missing, the caller it says exists, the rule it cites, the concurrency guarantee it assumes. A check that stops at the line confirms the quote and leaves the premise unread, so the finding goes out marked checked while the part that decides its severity was never looked at. The orchestrator therefore checks the line and the premise of every P1 and P2, with up to four tool calls each. It checks a P3 when two reads settle it, since an unchecked P3 the person then has to verify costs more than the two reads. It drops what the code does not support and counts it, and it removes a claim the code does not support from a finding that otherwise holds.

For static claims the check measures what it claims: the statement about the cited code, and the premise it rests on, are true. For claims about speed, races or exploits it measures only that the pattern and its premise are present, so those findings carry that label instead of `Checked: yes`. `Checked: no` is kept for checks that need running code or exceed the budget, so it signals a real limit and not a skipped read. This answers `commands/references/context-budget.md` § The Question Every New Gate Must Answer: what the gate claims and what it measures are the same thing, and the label is honest where they differ.

A severity that rests on a rule the project never wrote (a size limit, a naming convention) is a reviewer's preference, so the orchestrator lowers it to P3. A rule the project did write is the project-standards reviewer's to cite.

## The shared sections

All nine reviewer files end with the same two sections, `## How you work` and `## What you return`, and `scripts/tests/test_review_agents.py` requires them to be byte-identical. Before, the reviewers returned three different shapes (prose, bullet lists, a JSON object) and the orchestrator merged them by hand. One shape, with the quoted line, is what makes the check in Step 4 cheap.

The deployment-verification reviewer produces readiness gaps as findings, with the exact query or step in the Fix field, instead of a free-standing checklist, so its result merges like the others.

## Why the gates sit where they do

What follows is the text these passages carried in the command before 1.159.0, moved here whole.

### the PR fetch item

1. **PR number** (numeric): Fetch PR with `forge-pr-view` (`--include` is a comma-separated field selector — see `commands/references/forge-contract.md`; `files` is dropped here since nothing at this step consumes it). Runs in `forge-pr-view`'s built-in quiet degrade mode, so a missing/unauthenticated `gh` yields `status: "error"` with no stderr banner — the git-diff fallback documented in Error Handling below is what actually surfaces that to the user:

### the digits-only gate

`$ARGUMENTS` is validated as digits-only **in the same block that interpolates it**, never in a block of its own — each fenced block runs in its own isolated shell, so a gate placed in an earlier block cannot stop this one: its `exit 1` ends only that shell. The `case` form is deliberate rather than the `grep -qE` used for branch names in item 3: `grep` matches line by line, so it would accept a multi-line value whose *first* line is digits, while `case` tests the whole string and rejects any non-digit character, newlines included.

### the empty-argument branch

Only runs when `$ARGUMENTS` is empty (Detect Target Type item 4). It determines `$REVIEW_BRANCH` without assuming `$CURRENT_BRANCH` is the feature branch — HEAD parked on **the base branch** is the normal end state after a container-mode or phase-mode `/aimi:execute` run, since the main working tree is never checked out onto the feature branch in either mode. "The base branch" is not always `$DEFAULT_BRANCH`: a container-mode run stacked on top of another feature branch (its own base was never the default branch to begin with) leaves HEAD parked on that other feature branch instead, so the discriminator below asks the one question that actually matters — does HEAD differ from the branch the active tasks file names — rather than the narrower "does HEAD differ from `$DEFAULT_BRANCH`".

### the metadata call

2. Read the active tasks file's branch name with the single guarded `$AIMI_CLI metadata` call `commands/open-pr.md`'s own Case B already establishes for this identical situation, rather than a separate `find-tasks` lookup plus a raw `jq -r '.metadata.branchName'` read. It is **read-only** in the same sense that lookup was: `cmd_metadata`'s `get_tasks_file` (`aimi-cli.sh:507`) never calls `init-session`, so it cannot repoint a live `/aimi:execute` session's tracked tasks file — its only state write is the narrow self-heal path that fires solely when the recorded state pointer already points to a deleted file.

### Case B

**Case B — HEAD is not the branch the tasks file names.** Fires whenever a valid `$CANDIDATE_BRANCH` differs from `$CURRENT_BRANCH`. This covers both the pre-existing scenario (HEAD parked on `$DEFAULT_BRANCH`, the ordinary container-mode end state) and the stacked-base scenario the widened trigger fixes (HEAD parked on a *different* feature branch because the run was stacked on top of it) — one rule for both, since neither case is special beyond "HEAD is not the tasks file's branch":

### the reported correction

The correction is reported (to stderr, matching the Case A warning's own `>&2` convention) rather than applied silently: once the trigger also covers the stacked-base case, `$REVIEW_BRANCH` being swapped is no longer obviously "HEAD was on the default branch" — the swapped-from value is itself a plausible-looking feature branch, and a silent substitution there would be a surprise rather than a correction. Naming both branches makes it auditable in the transcript instead.

### the Design Fidelity gate

2. `$AIMI_CLI verification-report --tasks-file $TASKS_FILE | jq '.visual | length'` returns a value greater than 0 — the same verb `/aimi:execute` Step 0.7 answers this from, folded in here rather than left as its own third reading of the rule. It also closes a gap the old `jq -r '[.userStories[] | select(.verification.strategy == "visual")] | length' $TASKS_FILE'` had and Step 0.7's own scan never did: with no `type == "object"` guard on `.verification`, a string-typed `verification` made jq abort ("Cannot index string with strategy") where Step 0.7's guarded copy counted zero. `verification-report` type-checks before it reads `.strategy`, so a malformed `verification` answers zero visual stories here too, never an abort.
