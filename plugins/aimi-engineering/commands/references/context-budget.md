# Context Budget

Shared reference for deciding where a new piece of `commands/` instruction
content belongs — a CLI verb, a lazily-read `commands/references/` file, or an
inline decision in the parent command. Apply this classification whenever a
command grows a new procedure, a new conditional judgment, or a new
"does this apply?" check, rather than re-deriving the split from scratch.

## The Three-Way Classification

| Nature | Destination | Why |
|---|---|---|
| A **deterministic procedure** — validation, sanitization, path confinement, shell orchestration | A verb in `scripts/aimi-cli.sh` | Zero context tokens once resolved. Cannot be mis-followed by the model and cannot drift from the prose that describes it, because there is no prose to drift from. |
| A **rare conditional judgment** — a body the model must read only when an uncommon path fires | A lazily-read `commands/references/*.md` file | Pays one `Read` round-trip only on the invocations where that path actually fires; every other invocation pays nothing. |
| An **always-needed "does this apply?" decision** | Inline in the parent command, or a verb that returns a verdict | Every invocation needs the answer, so there is no lazy path to exploit — putting it in a reference file that gets read every time is the worst of both: always loaded into context AND paying a `Read` round-trip. |

## The Cheap-Condition-In-The-Parent Rule

Lazy-loading a reference file only pays off under one condition, and it is
worth stating on its own rather than folding it into the table above:
**the gate deciding whether to open the reference must be cheap AND already
live in the parent — only the expensive body goes in the reference.** If
opening the reference is itself required to learn whether the reference
applies, the file is read on every invocation regardless of outcome, the
saving is zero, and an extra `Read` was paid for nothing. The gate has to be
answerable from state the parent already holds — a flag, a mode variable, a
field already loaded — before the reference is ever opened.

## Evidence

This is not hypothetical; the corpus this rule was written to fix carries
both shapes side by side. `brainstorm.md` reads three reference files
unconditionally — the condition that decides whether the file's content
*applies* lives **inside** the file itself, so there is no cheap check in
`brainstorm.md` that could skip opening it:

- `brainstorm.md:433` — "read that file and apply its keyword list" against
  `ui-signals.md`.
- `brainstorm.md:448` — "read that file and apply its detection rules" against
  `foundation-signals.md`.
- `brainstorm.md:931` — "read that file and apply its criteria" against
  `scope-contexts.md`.

`plan.md:1330` repeats the same shape against `foundation-signals.md`: the
gate reads the file and applies its Structural Signals section to learn
whether condition (a) holds, rather than deciding that from something the
parent already knew.

`plan.md:734` is the one genuinely conditional read in the corpus.
`frontendBearing` is resolved from `implementationScope` and `ROADMAP_MODE` —
both cheap values already sitting in the parent — and `ui-signals.md` is
opened only when that resolution says it is needed. Every invocation that
resolves `frontendBearing` without those conditions holding never pays the
`Read` at all.

The measured consequence of the unconditional shape, taken once and not
re-derived here: roughly 55 KB of the 73 KB under `commands/references/` is
always-on context plus one `Read` round-trip per file, for a split that was
supposed to be lazy.

## Precedent

This is the same organising test `plugins/aimi-engineering/CLAUDE.md`'s
"What stays `jq`, and why" section already applies to `aimi-cli.sh` and to
`commands/`'s own `jq` — quoted verbatim rather than restated: **"port where
input the script does not control enters; leave it where the script is only
talking to itself."** See that section for the per-family census; it is not
repeated here.

## The Question Every New Gate Must Answer

The classification above decides **where** a piece of instruction belongs. This
section decides **whether a check is worth having at all**, and it is the sibling
rule: before adding any new validation gate — a CLI verb that returns a verdict,
a validator warning, a criterion a story must satisfy — answer one question in
writing.

**Does what this check MEASURES have any relation to what it CLAIMS?** A gate
earns its place only when it measures what it claims. One that does not is worse
than no gate at all, because it converts an unexamined thing into a green result
and nothing looks at it again.

### The four measured cases

Each of these was green. Each passed multiple validators. In none of them was the
check broken in the sense of running incorrectly — each ran exactly as written,
and each answered a narrower question than the one its wording promised.

| Case | What it MEASURED | What it CLAIMED |
|---|---|---|
| **Issue #134** — `implementation.verify` had a working-directory contract and no coverage contract | one of the three suites the story's own `acceptanceCriteria` named (`bun run test:e2e:legacy`) | that the criteria were satisfied. `validate-ids`, `validate-deps`, `validate-stories` and `validate-tasks` were all green over it. |
| **Issue #135** — the post-merge visual verification and the design review are *evidence* steps sitting in a block whose other steps are *state-machine* steps | that merge, `mark-complete` and worktree removal had run — the steps the wave loop reads back and cannot advance without | that the phase was verified. It closed with 9 of 15 stories at `verification.status: "pending"`, 1 of 5 visual stories verified, 0 design reviews run. |
| **The criterion naming a suite the chosen codebase does not have** — `plan.md` required the literal string `Typecheck passes` in every story | nothing at all: this repository is plain Bash, with no build, lint or package-manager step to run | that types were checked. Resolved by requiring *the project's own* type/syntax check rather than a fixed string. |
| **`verify-creates` closing a phase on a prose mention** — the hand-written procedure it replaced was wrong in five of nine measured scenarios | that the identity's name appeared somewhere git tracked: a CHANGELOG line, a `TODO` comment, a test file | that the declared artifact existed in code. Its successor excludes documentation, but its test-file patterns still miss this repository's own `test-<name>.sh` naming. |

Issue #135 states the shared shape in one sentence, quoted rather than restated:
*"Both end at the same place: a green result over a check that never happened."*
The defect is never inside the command the check runs. It is in the distance
between the sentence that describes the check and the command that performs it,
and that distance is invisible to everything downstream once the result is green.

Two consequences worth carrying into a new gate. **A check that cannot evaluate
must not report as a check that passed** — "could not determine the repository's
command vocabulary" and "checked and clean" are different answers, and collapsing
them manufactures confidence. And **a step whose result nothing reads back will
eventually be skipped in silence**; if it must happen, put it where something
downstream refuses to advance without it, or give it an artifact whose absence is
observable after the session ends.

## Three Fields, One Word: `verification`

A story spells verification three ways and they are not synonyms. Today the only
way to tell them apart is to read the code that consumes each one, which is
itself part of why the cases above were easy to write. Documented here, side by
side:

| Field | What it is | Who reads it |
|---|---|---|
| `acceptanceCriteria[]` | the **asserted end state** — prose that is true when the story is finished | the story executor, as its completion gate; `story-merge` warns when a criterion asserts a check `implementation.verify` never runs |
| `implementation.verify` | the **command that proves it** — one executable string, run from the story's own project | the story executor, before it commits; a non-zero exit fails the story and blocks the commit |
| `verification.strategy` | **how** proof is obtained — `test`, `visual` or `api` — with `verification.status` carrying the verdict | `/aimi:execute`'s post-merge verification and `/aimi:review`'s design-fidelity gate, both via the `verification-report` verb |

**No field is renamed by the story that wrote this section, deliberately.**
Renaming `verification` would touch the schema, the executor and
`tests/golden_from_jq.json` in a single commit. Documenting the three is the part
that costs nothing and removes the ambiguity; the rename, if it is ever worth
doing, is its own story with its own blast radius.
