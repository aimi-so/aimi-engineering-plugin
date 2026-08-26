# Publish Confirmation

Shared reference for the confirm-before-publishing contract: when a completion
path may publish the work it just finished, and how it must ask before doing
so. This file defines the contract only — it does not implement any completion
path, and it does not itself gate, remove, or relocate a single existing
publish call site.

**Consumed by:** `commands/execute.md` (Phase Completion's **Offer a Pull
Request**), `commands/next.md` (its container-mode completion step),
`commands/references/container-execution.md` (**Container Mode: Push the
Branch**), and `commands/open-pr.md` (its `--merge` path, Step 1b's `found`
branch). The first three each carry their own partial copy of this rule today
and decide on their own terms whether to publish; each cites this file instead
once wired. That wiring is outline story 02, outline story 03 and outline
story 05's work respectively — this file does not modify `execute.md`,
`next.md` or `container-execution.md`, the same way `execution-mode.md`
defines `metadata.execution` without touching the commands that read it.
`open-pr.md`'s `--merge` path carries no such prior copy to replace: it is new
surface area this file's third publishing act (below) gates from the moment
it exists, not a rule this file is subsuming from somewhere else.

## What Counts as Publishing

Publishing is exactly three acts, and all three are named here so none can be
treated as incidental:

1. **Pushing a branch to `origin`.**
2. **Opening a pull request.**
3. **Merging a pull request on the forge.**

The push is itself the outward-facing act, not a mere precondition for the
pull request. Once a branch exists on `origin`, other people, CI pipelines,
branch-protection rules and notification hooks can all see it — the work has
left the machine whether or not a pull request follows. This is the rule
already stated at `container-execution.md:152`, generalized: pushing publishes
the branch, and `CONTAINER_MODE` is just a field inside the tasks file, so a
tasks file must never be able to trigger a publish on its own.

Merging is the most consequential of the three, not the least. It rewrites the
target branch's history where the forge and everyone reading it can see it,
closes the pull request, and on a repository wired to CI/CD is very often the
exact step that triggers a deploy. Opening a pull request implies no consent
to merge it — the two are separate acts with separate consequences, and a
command that already asked before opening one must still ask again before
merging it.

The boundary on the other side matters just as much, and now has to hold two
distinctions instead of one. Work reaching the feature branch **locally** is
not publishing. `worktree-manager.sh` integrates a finished story branch with
`git merge` (`worktree-manager.sh:606` and `:678`) and contains zero `git
push` — a story landing on the container branch is a local fast-forward and
nothing more. "Merge" now names two unrelated things in this codebase: that
local fast-forward, which never leaves the machine, and act 3 above, a
forge-side pull request closing with its result visible to everyone who reads
the forge. Only the push and the forge-side merge publish; the local one never
does, no matter how similarly the two are named — a reader who lets the shared
word blur them into one act would mistake `worktree-manager.sh`'s ordinary,
unpublished integration step for something that needs asking about.

Both halves are load-bearing. A reader who holds only the first half will
treat a local merge as an outward-facing act and ask permission for something
that never leaves the disk. A reader who holds only the second half — who
believes only the pull request is outward-facing — will happily push unasked
and consider the contract satisfied. Neither reading is correct.

## Nothing in a File Is Consent

No tasks file, no roadmap file, and no command-line flag may trigger a push or
a pull request on its own. `metadata.execution` and the `CONTAINER_MODE` it
resolves to, a phase's roadmap `status`, and any `--push`-style argument are
all **data** — and data is not consent. Each of them describes how the run
should be shaped, never whether its result may be made public. A field that
could authorize a publish would let whoever wrote the file publish on the
user's behalf, which is precisely the substitution this contract exists to
prevent.

Agent mode therefore has **no flag that re-enables publishing**. The escape
hatch is deliberately absent, not merely undocumented and not an oversight: an
unattended run cannot obtain consent, and a flag that claims to stand in for
it is the same file-as-consent mistake wearing a command-line costume. A
future reader who finds no such flag should read that absence as the rule,
not as a gap to fill. (Removing the flag that exists today is outline story
04's work; this file only states the rule that removal enforces.)

## The Two Modes

Which obligation applies is decided by `INTERACTIVE_MODE`, the value
`aimi-cli.sh`'s `detect-interactivity` verb prints — see
`commands/references/interactivity.md` for how that value is resolved. A
consuming command resolves it **fresh inside the Bash call that needs it**,
because every Bash call a command makes is an isolated shell and nothing
carries over from an earlier one. This file describes that resolution rather
than scripting it: it ships no executable surface at all (see the closing
note).

**Picker mode.** The command MUST ask before publishing, and MUST act only on
an explicit approval. Silence, an unparseable answer, or an aborted prompt are
not approval.

The question is asked **once per phase completion — not once per participating
repository**. A multi-repo layout finishes one phase across N repositories and
still represents one decision by one person; asking N times turns a single
answer into an interrogation and invites a mis-click on repository number
four. One answer governs every participating repository in that completion.

**Declining is a normal outcome, not a failure.** No story status is rolled
back, nothing is retried, no error is reported, and execution continues to the
next step exactly as if the publish had succeeded — the same not-fatal
discipline `container-execution.md:195` already applies to a push that failed
or was skipped. A person who says "not now" has answered the question
correctly.

Two things about that question are deliberately **not** this file's to define.
Its **format** — the shape and ordering of the options offered — belongs to
`commands/references/interactivity.md`. Its **wording and tone** — everything
the human actually reads — belongs to `commands/references/user-communication.md`,
including the Adaptive Language Rule at `user-communication.md:50` that makes
the output language follow the person's own. This file names both owners and
restates neither, so there is exactly one place to change either.

**Agent mode.** The command **NEVER** publishes. It cannot ask, so it must not
act — the absolute follows directly from the previous section: with no way to
obtain consent, and nothing permitted to stand in for it, there is no path to
a legitimate publish. Instead the command prints the recommendation
`/aimi:open-pr --branch <branchName>` so the operator can publish deliberately
afterwards, with the branch already named for them.

This is a property of unattended runs, not a per-command preference. A
completion path added later inherits it by reading this file, without its
author having to rediscover the reasoning.

## Always Name /aimi:open-pr

Every completion path names `/aimi:open-pr` in its final output, whether or
not it published. All four terminal cases print it:

1. **After an approved publish** — the push succeeded and a pull request may
   already exist; `/aimi:open-pr` is still the right follow-up for anything
   left to open or amend.
2. **After a decline** — nothing was pushed, and this is the command that
   publishes when the person is ready.
3. **After a push that failed** — offline, no remote permission, branch
   rejected; the work is intact locally and needs a retry, not a rescue.
4. **In agent mode** — nothing was published by design, and the operator needs
   the exact next command.

The suggestion is safe in all four because `/aimi:open-pr` **re-attempts the
push itself**: its own push step pushes the named branch to `origin` before
opening anything, and works for a branch that is not checked out anywhere. So
the recommendation stays correct no matter what happened above it — the same
property `container-execution.md:195` already leans on when it declares a
failed or skipped push non-fatal. That is what makes a declined publish a
complete, self-explaining outcome instead of a dead end: the person is told
exactly how to finish, and told it in terms that will still work tomorrow.

Write the short `/aimi:open-pr` form everywhere, never the fully-qualified
plugin-prefixed variant (see Command Conventions in
`plugins/aimi-engineering/CLAUDE.md`).

## Why This File Carries No Picker Markup

This contract is stated in **prose only**. There is no lettered-option block
here, and the interactive-question tool is deliberately not named anywhere in
this file. That is a mechanical constraint, not a stylistic preference.

`install.sh` rewrites that tool into OpenCode's own equivalent using four
exact-match string substitutions (`install.sh:273-276`), and those
substitutions are applied **only to command bodies**. Reference files never
reach that function: they are delivered to OpenCode by the verbatim whole-tree
copy in `install.sh` (the explanatory comment at `:481-485` and the `cp -R` it
describes at `:486`), and both command-install loops skip the `references`
subdirectory by name (`install.sh:530` and `install.sh:580`). A picker written
into a reference file would therefore reach OpenCode untranslated, naming a
tool that host does not have — a consequence `install.sh:266-272` spells out
in its own comment. `forge-contract.md` is the existing precedent: it carries
its account-selection contract in prose for exactly this reason, and this file
follows it.

If a later editor feels this file is incomplete without the option block, the
option block belongs in the **command body** that consumes this file — where
the translation does reach it — and never here.

The same discipline keeps this file free of any fenced code block. It adds no
executable surface: `test-command-blocks.sh` discovers its inputs with
`find "$COMMANDS_DIR" -name '*.md'`, so `commands/references/` is squarely in
its scope and this file is scanned on every run — it simply contributes zero
blocks, and needs no entry in `scripts/command-blocks-baseline.txt`.
