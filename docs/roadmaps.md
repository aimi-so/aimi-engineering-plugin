# Roadmaps

For work too large to plan in one pass. A roadmap cuts a big feature into phases, plans one at a time, and checks that each phase actually delivered what it promised before the next one starts.

Small features never touch this. It only appears when the work genuinely spans more than one capability.

---

## When it kicks in

`/aimi:brainstorm` classifies what you described into **scope contexts** — vertical, user-observable capabilities. "Checkout" is a scope context; "database layer" is not.

Find one context, nothing changes: you get a normal plan. Find two or more, and brainstorm proposes a phase cut.

The cut criteria, applied in order:

1. **Coherent** — each phase maps to one nameable business capability. If you can't name it in a few words, it isn't a valid cut.
2. **Sequential or independent** — phases form a clean dependency order, or they don't depend on each other at all. Partially tangled dependencies mean the cut is wrong.
3. **One complete capability per phase** — each phase must be demoable on its own, without waiting for a later one to finish it.
4. **Split only along semantic seams** — "Payments" becomes "Checkout" and "Subscriptions" because those are two capabilities. Never split by size alone.

---

## What a phase declares

```json
{
  "id": 1,
  "name": "Checkout",
  "slug": "checkout",
  "goal": "Users can complete a purchase end to end.",
  "successCriteria": [
    "Cart totals reflect tax and shipping before payment.",
    "Payment confirmation is shown on success."
  ],
  "dependsOn": [],
  "creates": ["orders (stores completed purchase records)"],
  "needs": [],
  "areas": ["app/checkout/**"]
}
```

`goal` is an outcome, not a task list. `successCriteria` are observable — two to five of them.

`creates` and `needs` are the contracts between phases. A phase declares what it will produce; a later phase declares what it requires. Those two lists are what make the roadmap more than an ordered list of intentions.

`areas` are coarse globs. They exist so overlapping phases can be flagged before anyone writes code.

A phase's contract is correctable after the fact. Nothing in the roadmap has to be right the first time: `goal`, `successCriteria`, `creates`, `needs`, `areas` and `branch` can each be rewritten on an existing phase, at any status, including one already completed — repairing a finished phase's declared artifacts is one of the reasons the correction path exists. Everything else about the phase is left exactly as it was, and so is every other phase.

The one thing a correction will not do quietly is break a contract someone downstream is relying on. If you rename or remove a `creates` entry that a later phase names in its `needs`, the edit is refused and you are told which phases still cite it. You then either leave the identity alone or say explicitly what replaces it — and when you do, the provider's new wording and every consumer's `needs` are rewritten together, in one write, so the two sides never drift apart in between. An amendment that would make two phases claim to create the same thing is refused for the same reason: the roadmap's own validator rejects that, and planning stops.

---

## The approval gate

The proposed cut is not applied silently. You get a gate with merge, split, reorder, rename, add, and remove — and **Approve is blocked until every decision from the session is covered by some phase**.

That check is a hard block, not a warning. If you said something about rate limiting during brainstorming and no phase mentions it, Approve is rejected and the gate comes back. The orphan has to be placed, renamed into an existing phase, or explicitly merged somewhere.

The reasoning: a decision that survives brainstorming but appears in no phase is a decision that will be silently dropped. Better to refuse the roadmap than to ship one with a hole in it.

If your edits collapse the cut down to a single phase, the roadmap is dropped entirely and you get an ordinary plan — no note, no warning. One phase is not a roadmap.

---

## Rolling-wave planning

You do not plan every phase up front. That would mean writing detailed stories for work that later phases will change.

```bash
/aimi:plan --phase 1      # plan only the first phase
/aimi:execute             # run it
/aimi:plan --phase 2      # now plan the second, informed by what phase 1 actually did
```

Each phase's tasks file lives in its own directory:

```
.aimi/tasks/checkout/
├── roadmap.json
├── phase-1-checkout/
│   ├── checkout-phase-1-tasks.json
│   └── handoff.md
└── phase-2-subscriptions/
    └── checkout-phase-2-tasks.json
```

Phase ids are plain numbers, so a phase can be inserted later as `2.1` without renumbering everything after it.

---

## Claiming a phase

`/aimi:execute` with a roadmap present claims a phase before running it. Without `--phase`, it takes the lowest-numbered phase that is unclaimed, not yet done, and whose dependencies are all complete.

The claim is atomic. Two sessions can work different phases of the same roadmap at the same time without colliding — if both reach for the same phase, one wins and the other moves to the next eligible one.

A claim records the session's process id. If a session crashes, the next `/aimi:execute` notices the process is gone, releases the stale claim, and continues. You do not have to clean up by hand.

Each phase runs in its own **phase container** — a git worktree on the phase's branch — so your working tree is untouched here too. When a phase spans more than one repository, each one gets its own phase container, on a branch of the same name (see [Multiple repositories](#multiple-repositories) below).

---

## Closing a phase

A phase does not close just because its stories finished. Three things happen first.

**Creates verification.** Every artifact the phase declared in `creates` must be found in the code the phase branch committed. The check looks for it among the files git tracks. First it looks for a file or a folder at that exact path. If there is none, it searches the tracked source for the name. For an endpoint it drops the leading method and searches only the path, because working code writes the route itself, never the words `POST /api/notifications`. Documentation, tests and to-do comments are left out of that search: a name that appears only there says the work was described or planned, not that it was built, so it does not count as delivery. The one exception is a phase whose artifact *is* documentation — then the docs page is the thing, and finding it counts. This is stricter than checking that a later phase's `needs` resolved: it asks whether the promise was kept.

One limit is worth knowing: only committed work is visible. Anything still uncommitted on the phase branch reads as missing, so commit before you close.

If anything is missing, the phase is marked `verification_failed` and the next phase stays blocked. Fix the gap on the phase branch and re-run — verification runs again from scratch.

**Handoff.** A `handoff.md` is written into the phase's directory with five sections:

| Section | What it carries |
|---------|-----------------|
| Decisions Made | Implementation decisions worth knowing downstream |
| Artifacts Created | Exactly the verified `creates` entries, verbatim |
| Deviations | Known gaps recorded during the phase |
| Deferred Items | Stories left skipped |
| Contracts Delivered | What is now available to dependent phases |

A later phase reads this rather than re-deriving what happened. Artifacts Created is matched verbatim when a downstream phase's `needs` is checked, so the wording is load-bearing.

**Status and claim.** Only once the handoff is on disk does the phase transition to `completed`, releasing its claim in the same atomic write. There is no window where a phase reads as done while still claimed.

Then you are offered the next eligible phase.

---

## Multiple repositories

`AIMI_ROOT` — the folder holding `.aimi/` — does not have to be a git repository. It can be a plain parent folder with one git repository per subfolder instead: this is a **multi-repo** layout.

The roadmap itself does not care. `roadmap-claim`, `roadmap-set-status`, `roadmap-write-handoff`, and `roadmap-reconcile` — the four operations that move a phase through its lifecycle — make no git calls at all. They only read and write `AIMI_ROOT/.aimi/`. So the claim, the phase's status, and its `handoff.md` all stay exactly what they are in a single-repo layout: one claim, one status, one handoff file, no matter how many repositories the phase touches.

The deliverable is different, because it is git-bound. A phase container and its phase branch live inside a repository, and `AIMI_ROOT` itself may not be one. So a phase running across N repositories gets N phase containers and N phase branches — one per participating repository, all sharing the same branch name — and closing time opens one pull request per repository, never a single combined one. Creates verification runs once per repository's own container and takes the union of every repository's result: an artifact counts as delivered the moment any one participating repository has it.

Getting stories routed to the right repository takes one thing: every story needs its own `project` field, naming the path from `AIMI_ROOT` to the repository it belongs to. When `/aimi:plan` splits a full-stack scope across repositories, `metadata.splitGroup.project` is the single source of routing truth both `story-merge` and `/aimi:execute` trust — worth knowing before you plan, not just after `/aimi:execute` refuses to run. A legacy split that predates this — a `-frontend-tasks.json`/`-backend-tasks.json` pair with no `project` routing — carries no repository information at all, so it is refused with an instruction to re-plan, never silently accepted or silently misrouted.

---

## When the roadmap runs out

When no phase remains eligible, a sweep reports what is left over:

- **Orphan creates** — a phase declared an artifact that no other phase ever needed. Either the contract was unnecessary or a `needs` is missing.
- **Deferred needs** — a phase needs something whose producing phase has not completed.
- **Warnings** — malformed or suspicious phase fields.

An empty sweep means every declared contract is consumed and every need is satisfied.

---

## What this does not do

Phase-scoped tasks files ignore `--container` and `--inline`. A claimed phase always runs in its own phase container.
