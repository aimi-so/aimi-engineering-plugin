# Scope Contexts

Shared reference for cutting a large feature into scope contexts — the phase-level
unit used when a single feature is too large for one flat planning pass. Apply the
rules in this file wherever the command says "identify scope contexts" or "run the
scope-context step."

**Consumed by:** the `/aimi:brainstorm` roadmap-definition step and the `/aimi:plan`
inline scope-context fallback. Both must cut phases identically for the same
feature, regardless of which command runs the step.

## What Is a Scope Context

A scope context is a vertical, user-observable capability: a complete end-to-end
slice of functionality, not a technical layer. "Signup flow" and "payment flow" are
scope contexts; "database layer" and "API layer" are not.

Contrast with a user story: one story is one capability sized to a single agent
iteration (a context window). One scope context is a cluster of stories delivering
one larger vertical capability, sized to roughly one rolling-wave planning pass —
big enough to need its own phase, small enough to plan and demo as a unit before
moving to the next one.

## Cut Criteria

Cut a feature into scope contexts using these criteria, in order:

1. **Coherent** — each context maps to one nameable business capability. If you
   cannot name the capability in a few words ("checkout," "notifications"), it is
   not a valid cut.
2. **Sequential or independent** — contexts either form a clean dependency order
   (a foundation context before the contexts that consume it) or are mutually
   independent. Avoid partial, tangled dependencies between contexts.
3. **One complete, verifiable capability per phase** — each context must be
   independently demoable without waiting on a later phase to finish it.
4. **Split an oversized context only along semantic seams** — e.g. "Payments"
   splits into "Checkout" and "Subscriptions" because those are two distinct
   capabilities, never by size alone.

## The Collapse Rule

When a feature decomposes into exactly one scope context, there are **no phases at
all**. Skip the roadmap/phase machinery entirely and run the feature through the
existing flat pipeline unchanged.

This is distinct from a "1-phase roadmap." A 1-phase roadmap still carries phase
scaffolding (a phase container, a goal, success criteria). The collapse rule means
that scaffolding is never created — the single scope context is the whole feature,
planned exactly as if phases did not exist.

## Shared-Foundation Detection

When an artifact — a table, a service, a shared type, a file — is needed by two or
more scope contexts, it is never duplicated into each consumer's creates list. It is
produced exactly once: either by a dedicated foundation phase that precedes its
consumers, or by whichever consuming phase comes first in dependency order.

Example: if both "Checkout" and "Subscriptions" need a `payment_methods` table,
that table is created once — by a foundation phase, or by whichever of the two
phases runs first — and the other phase declares it as a need, not a create.

## Anti-Patterns

| Anti-pattern | Why it's wrong | Corrective |
|---|---|---|
| Horizontal layer phases (e.g. "Phase 1: all migrations, Phase 2: all endpoints, Phase 3: all UI") | No phase is independently demoable; nothing is user-observable until every phase finishes | Cut by capability instead — each phase ships schema + backend + UI together for one vertical slice |
| Numeric size quotas (splitting to hit a target story or phase count) | Produces contexts with no coherent capability boundary | Cut only where Cut Criteria §1 (coherent) and §4 (semantic seam) apply; let the count fall out of the cuts |
| Phase-count padding (imposing a fixed phase count regardless of actual scope) | Forces artificial splits or merges to match a number chosen in advance | Let the number of phases equal the number of valid scope contexts, including one (see The Collapse Rule) |
| Artificial splits (dividing one coherent capability just to hit a count or size target) | Breaks a single demoable capability across two phases that can't be verified independently | Keep one coherent capability in one phase even if it is larger than other phases |

## Goal and Success Criteria

Each phase's goal must be phrased as an outcome, not a task list.

- Good: "Users receive and can act on in-app notifications."
- Bad: "Build the notification schema and endpoints."

Each phase carries 2 to 5 observable success criteria — things a human can check
against the running app, not internal implementation details.

**Detection heuristic:** a goal that names only technical actions with no
user-facing verb (build, add, migrate, wire up — with no "user can...") is a
horizontal-layer red flag. Re-examine the cut before proceeding.

## Creates/Needs Contracts

Cross-phase contracts name artifacts at the artifact level, using one naming rule
per kind:

| Artifact kind | Naming rule | Example |
|---|---|---|
| Endpoint | `METHOD /path` | `"POST /api/notifications (creates a notification for a user)"` |
| Table | `table_name` | `"notifications (stores per-user notification rows)"` |
| Service | module/class path | `"services/notifications.NotificationService (sends and lists notifications)"` |
| File | relative path | `"components/NotificationBell.tsx (header bell icon with unread badge)"` |

Every entry uses the string format `"<artifact-name> (<one-line description>)"`.

**The artifact name must be a single token.** It is searched as a literal string,
so it has to be a symbol, a path, a table name, or the `METHOD /path` endpoint
form — that endpoint form is the *only* shape with a space in it that is
accepted, and only with exactly one space before the `/`. `roadmap-init` refuses
an entry whose name carries whitespace and names the phase, the list and the
entry when it does. Write `_forge_account_override` or
`services/forge/account.ts`, never `account override applied inside the forge
command surface`. The reason is mechanical rather than stylistic: verification
searches tracked source for that literal, and a multi-word phrase can only match
prose — a comment or a string — while documentation, the one place such a phrase
plausibly appears, is already excluded from the search. A whitespace-bearing
name is therefore either unfindable or findable only in a comment.

Passing this check proves the name is the *kind* of string a search can resolve.
It never proves the artifact will exist: `cmd_forge_nonexistent` passes, and so
does a prose phrase hyphen-joined into one token. At declaration time the
artifact has not been built, so only shape can be judged.

Contracts are checked deterministically, never by LLM judgment alone: a phase's
`creates` entries are verified to exist in code at that phase's close, and a
phase's `needs` entries are checked against prior phases' fulfilled `creates` at
next-phase planning time.

### What verification looks for

At a phase's close, `aimi-cli.sh verify-creates` reduces each `creates` entry to
its identity — the text before the first `(` — and looks for that identity among
the files git tracks on the phase branch. It is not kind-aware: every identity
runs the same steps in the same order, whatever its kind column says, and the
first step that finds the artifact ends the search.

1. **Tracked path.** If the identity names a file *or* a directory that git
   tracks, that alone verifies it. A `File` identity such as
   `components/NotificationBell.tsx` and a directory such as `db/migrations`
   both resolve here. An identity that starts with `/` or traverses with `..`
   skips this step and falls through to the text search.
2. **Endpoint path extraction.** A leading HTTP method followed by a space and a
   `/` — the `METHOD /path` form in the table above — is stripped, so
   `POST /api/notifications` is searched as `/api/notifications`. Real code
   writes `router.post('/api/notifications', …)` and never the method-plus-path
   literal. Nothing else is stripped, and the shape is exact: the method must be
   followed by a single space and then a `/`. `POST  /api/x` with two spaces is
   not that form and would be searched whole, which is why `roadmap-init` refuses
   it rather than letting it reach a search it cannot survive. A method token
   *not* followed by a slash is not an endpoint either — it would be searched
   whole, carry a space, and so is refused at write time as well.
3. **Text in source.** Whatever is left is matched as a literal string across
   tracked files, with documentation (`*.md`, `docs/`, `README*`), tests
   (`*_test.*`, `tests/`, `__tests__/`) and `.aimi/` excluded, and with lines
   that are nothing but a `TODO`/`FIXME`/`XXX`/`HACK` comment discarded. A
   `Table` identity such as `notifications` resolves here. When the identity is
   itself documentation (`docs/api/notifications.md`), the documentation
   exclusions are bypassed for that entry — there the docs page *is* the
   artifact.

This is guidance about verification *strength*, which is not judged. `roadmap-init`
accepts a bare name such as `notifications` exactly as the table above
prescribes, and the close check verifies it — via step 3 rather than step 1.
Knowing which step an identity will take tells you how much a pass proves: a
tracked path is direct evidence the artifact exists at that location, while a
bare name is evidence that the name appears in non-documentation, non-test
source. Neither `roadmap-init` nor the close check prefers one of those shapes
over the other, and at declaration time an author often cannot know the eventual
path — a wrong guessed path fails at close for a reason nobody can debug.

Exactly one shape *is* judged, and it is not about strength: an artifact name
carrying whitespace in the token that will be searched is refused at write time,
because no search this verb can run would ever resolve it (see the single-token
rule above). Everything else — how specific the name is, how likely it is to
exist, whether it looks like a path — is left to the author.

One limit applies to every step: git sees tracked files only, so work that is
not committed on the phase branch reads as missing. Every `missing` verdict says
so in its evidence string.

## Coarse File-Area Declaration

Before any story exists, each phase declares a short list of top-level directories
or path globs its stories are expected to touch (e.g. `app/checkout/**`,
`services/payments/`). This declaration is necessarily coarse — directory or glob
level, not individual file paths — because no story has been planned yet.

Use the declaration only for early collision detection between candidate phases
(flagging two phases that claim overlapping areas so the cut can be revisited). It
is not an enforcement mechanism — a phase is not blocked from touching files
outside its declared areas once stories are planned.
