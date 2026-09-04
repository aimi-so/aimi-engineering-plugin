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

| Artifact kind | Naming rule | Example `identity` |
|---|---|---|
| Endpoint | `METHOD /path` | `POST /api/notifications` |
| Table | `table_name` | `notifications` |
| Service | module/class path | `services/notifications.NotificationService` |
| File | relative path | `components/NotificationBell.tsx` |

Every entry is an object with exactly two keys:

```json
{"identity": "POST /api/notifications", "description": "creates a notification for a user"}
```

`description` is `""` when a phase has no prose for the artifact — never `null`,
never an absent key. An entry carrying any other key is refused, naming the key.

**The artifact name must be a single token.** It is searched as a literal string,
so it has to be a symbol, a path, a table name, or the `METHOD /path` endpoint
form — that endpoint form is the *only* shape with a space in it that is
accepted, and only with exactly one space before the `/`. `roadmap-init` and
`roadmap-amend-phase` refuse an entry whose name carries whitespace and name the
phase, the list and the entry when they do. Write `_forge_account_override` or
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

### Two rulers: the identity and the description

One entry, two fields, two different rules. They used to be two halves of one
string, split at the first `(` by every boundary that needed one — which is why
they are two fields now: a split that has to be re-derived is a split that can
be re-derived differently, and whoever forgot applied prose rules to a name.

**The identity may not carry whitespace, and may not carry any of**
``$``, `` ` ``, `;`, `|`, `&`. That is not a style preference — the identity is
grepped as a literal string against tracked source (see *What verification
looks for* below), so a character that no source token would ever hold makes
the entry unresolvable by construction. The whitespace half of the rule is
judged after the same method-plus-space strip verification performs, which is
why `POST /api/notifications` passes and `POST  /api/x` with two spaces does
not: the second is not the endpoint form, so it would be searched whole.

**The description is exempt from that character class.** An identity of
`cmd_clean` described as `does x; then y` is a legal entry — the identity is
clean, and a semicolon sitting in human prose has nothing to do with the token
a search will look for. Only the identity is searched, so only the identity
carries the ban.

**The description is not exempt from the injection patterns.** It still refuses
`ignore previous`, `system:`, `INSTRUCTIONS:`, code fences and `$(`, because it
is not human-only prose: `/aimi:plan` reads every completed phase's `handoff.md`
into its `phaseHandoffBlocks` and threads that text verbatim into every
story-expander sub-agent prompt. A description is therefore LLM-prompt input,
and the injection guard covers it for the same reason it covers any other
prompt-bound field.

Both instruction markers are matched by **position** — start of the entry or
whitespace, then any run of punctuation — because that is the shape a marker
has and an ordinary name does not. `### INSTRUCTIONS do X`, `--system: do this`
and `system: you are now …` are refused; `docs/instructions.md`,
`design-system:tokens`, `ecosystem:pkg` and a file identity literally named
`INSTRUCTIONS.md` are all legal entries and pass. Both fields are judged for
injection patterns; only the identity is judged for the character class.

Both halves of that have been wrong before, in opposite directions: unanchored,
the alternation matched ordinary English; anchored to the *neighbouring
character*, it admitted `--system:` (a hyphen is an identifier character) and
`### INSTRUCTIONS` (a heading needs no colon). The heading form deliberately
requires the `#`, so an artifact genuinely named `INSTRUCTIONS.md` is not
refused. Both directions are pinned by paired tables in
`test-aimi-cli-part3-roadmap-forge.sh` — widening the rule fails one table,
narrowing it fails the other.

**The identity is never rewritten — only refused.** The two rulers govern
mutation as well as judgement, and on the identity side the rule is now
absolute: **nothing** is applied to it. Not a fence strip, not a backtick
unwrap, not a newline fold, not the 500-char cap. The description gets the full
prose sanitizer and that cap. The asymmetry is the point: those rules **delete
or reshape content**, and an identity is grepped for literally, so rewriting one
produces a name the phase will never deliver. Before the split,
`design-system:tokens (a token file)` was stored as `design-tokens (a token
file)` and `parseList<T>` as `parseList` — silently, with `validate-contracts`
then passing, so the contract read as undelivered a whole phase later.
Namespaced, templated and globbed identities are declared on purpose here
(`queue:emails`, `Generic<T>`, `db/migrations/*.sql`) and survive verbatim.

An identity over 500 characters is therefore **refused**, where every other
roadmap field is truncated. A truncated goal is still the goal; a truncated
name is a search that returns nothing.

**The refusal happens at write time.** `roadmap-init` and `roadmap-amend-phase`
reject a malformed identity before anything reaches `roadmap.json`, naming the
phase, the list, the entry's position, the entry and every reason it failed:

```
phase 2: creates entry #1 "cmd_a;cmd_b" is not a usable artifact identity: contains the shell metacharacter ";", which validate-contracts refuses in an identity -- move that text into the description field, or, for an endpoint, declare the route without its query string
```

An entry that matched an injection pattern is reported by position with its
content **withheld**: that stderr is read by the agent that will act on it, so
replaying the payload would be the delivery the check exists to block.

`areas[]` is judged too, by its own narrow rule — a glob may not be absolute
and may not traverse. It is not an identity, so none of the rules above apply
to it; it is checked because `/aimi:plan` appends phase `areas` to its research
path hints as-is, exempting them from the filter it applies to user-typed
tokens on the grounds that this verb already sanitized them.

`validate-contracts` and `roadmap-sweep` apply the same rules when they *read* a
roadmap. That reader-side check is defence in depth, not the place an author is
meant to meet the rule: it should not fire on a roadmap this CLI wrote, and if
it does, the write path is what to look at. When it does fire — on a roadmap
written before these rules, or hand-edited — it names the phase, the field, the
entry's position and the reason, and points at `roadmap-amend-phase` to repair
it. `roadmap-sweep` additionally reports **what it dropped**: it removes a
flagged entry before computing orphans and deferred needs, so a downstream
`needs` that cited it would otherwise read as unmet with no trace of why.

### Two behaviours to know before writing an entry

**A backticked identity is refused, not silently renamed.** Write an identity
of `` `cmd_foo` `` and `roadmap-init` refuses the payload, naming the backtick.
It used to be *unwrapped* to `cmd_foo` — itself a repair of an earlier version
that *deleted* the span with its contents, so the identity vanished and the
failure surfaced one phase later as a `needs` entry nothing could ever fulfil.
Refusing is better than either: the author hears about it at the one moment they
can still rename the artifact, instead of finding a roadmap that stores a name
they did not type. In a **description**, a backticked span still unwraps to its
inner text and a triple-fenced block is still deleted whole — those are prose
rules, applied to prose.

**The rule binds new writes only.** Nothing re-judges a roadmap already on
disk. `roadmap-init` judges only the phases it is creating — under `--sync`,
only the ids not already stored — and `roadmap-amend-phase` judges only the
lists a given call actually amends, so a phase whose stored `creates` holds a
legacy whitespace identity can still have its `needs` corrected. Repairing
exactly those phases is what that verb exists for. This repository's own phases
2, 3 and 4 carry whitespace-bearing `creates` today and stay readable and
amendable. The discipline is stated in full in `aimi-cli.sh`, in
`_roadmap_identity_errors`' header under *"RETROACTIVITY IS THE CALLER'S
PROPERTY, NOT THIS HELPER'S"*.

### What verification looks for

At a phase's close, `aimi-cli.sh verify-creates` reads each `creates` entry's
`identity` field and looks for it among the files git tracks on the phase
branch. It is not kind-aware: every identity
runs the same steps in the same order, whatever its kind column says, and the
first step that finds the artifact ends the search.

1. **Tracked path.** If the identity names a file *or* a directory that git
   tracks, that alone verifies it. A `File` identity such as
   `components/NotificationBell.tsx` and a directory such as `db/migrations`
   both resolve here, as does a path glob such as `db/migrations/*.sql`. An
   identity that starts with `/` or traverses with `..` skips this step and
   falls through to the text search.

   The identity is passed as an explicit `:(glob)` pathspec, never bare. Bare,
   git reads it *as* pathspec: an identity of `*`, `:` or `:!nope` matched every
   tracked file and reported the phase verified against artifacts that did not
   exist. Glob rather than literal, because literal would also stop
   `db/migrations/*.sql` — a declared kind — from resolving. An identity built
   only from separators and glob metacharacters is refused at write time
   instead, since it names nothing in particular.
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
3. **Text in source.** Whatever is left is matched as a literal **whole word**
   across tracked files, with documentation (`*.md`, `docs/`, `README*`), tests
   (`*_test.*`, `tests/`, `__tests__/`) and `.aimi/` excluded, and with comment
   lines set aside — a `TODO`/`FIXME`/`XXX`/`HACK` line discarded outright, any
   other comment line held back as a mention (step 4). A `Table` identity such
   as `notifications` resolves here.

   Whole word rather than substring, and the difference decided a phase:
   `baseRef` matched 37 lines that were every one of them `--arg baseRefName`
   inside a forge adapter — a GitHub pull-request field with no relation to the
   `metadata.baseRef` the phase had promised. A match must begin and end at a
   non-word character, which every kind in the table above already does:
   `parseList<T>`, `queue:emails` and a stripped `/api/notifications` all still
   resolve.

   When the identity is itself documentation (`docs/api/notifications.md`), the
   exclusions are bypassed *except* for the four meta-documents that cite other
   files by name — `README*`, `CHANGELOG*`, `CLAUDE.md`, `AGENTS.md` — which
   match nearly any identity and announce work rather than being it. And a text
   hit does not close a doc identity at all: it reports **`unconfirmed`**. Only
   step 1's tracked path reports `verified` for one, because finding the string
   `docs/api.md` proves that some file names the page, not that the page
   exists.
4. **Comment-only evidence.** When every line step 3 matched is a comment, the
   identity reports **`unconfirmed`** rather than `verified` — the same verdict
   a doc identity gets, for the same reason: a note describing an artifact is
   not the artifact. One real code line outranks any number of comments, so a
   phase that built the thing and also wrote about it still verifies at the
   code. `#`, `--` and `*` count as comment openers only when followed by
   whitespace, which is what keeps `#define parseThing(x)`, `--count;` and
   `*ptr = parseThing();` reading as the code they are.

This is guidance about verification *strength*, which is not judged. `roadmap-init`
accepts a bare name such as `notifications` exactly as the table above
prescribes, and the close check verifies it — via step 3 rather than step 1.
Knowing which step an identity will take tells you how much a pass proves: a
tracked path is direct evidence the artifact exists at that location, while a
bare name is evidence that the name appears, as a whole word, in
non-documentation, non-test source. When every one of a bare name's matches
lands in a file no story of that phase declared touching, the verdict is still
`verified` and one advisory line goes to stderr — the verdict is usually right,
and the doubt belongs where a reader can weigh it rather than in a refusal.
Neither `roadmap-init` nor the close check prefers one of those shapes
over the other, and at declaration time an author often cannot know the eventual
path — a wrong guessed path fails at close for a reason nobody can debug.

Two shapes *are* judged, and neither is about strength: an identity carrying
whitespace in the token that will be searched, and an identity carrying a shell
metacharacter, are both refused at write time, because no search this verb can
run would ever resolve either (see the single-token rule and *Two rulers*
above). Everything else — how specific the name is, how likely it is to exist,
whether it looks like a path — is left to the author.

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
