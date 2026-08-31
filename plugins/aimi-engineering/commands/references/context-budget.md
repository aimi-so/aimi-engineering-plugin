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
