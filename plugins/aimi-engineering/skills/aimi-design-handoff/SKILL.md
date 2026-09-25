---
name: aimi-design-handoff
description: Interview the operator and author a compliant BusinessSpec.md/DesignSpec.md bundle at .aimi/design-bundles/<slug>/ so /aimi:brainstorm and /aimi:plan can treat a project with no Claude Design handoff like a real one. Use when a UI feature needs planning and no design bundle exists yet. Triggers on "no design bundle", "no Claude Design handoff", "write a BusinessSpec", "write a DesignSpec", "generate a design bundle", "design handoff interview".
disable-model-invocation: true
allowed-tools: Read, Write, Glob
---

# Design Handoff

Interview the operator directly — no Claude Design session required — and
write a `BusinessSpec.md`/`DesignSpec.md` bundle that reads, to every
downstream consumer, like a real Claude Design export. The bundle this skill
writes carries its own provenance marker rather than the Claude Design one,
so nothing downstream mistakes it for a Claude Design session it never had.

## Quick Start

1. Confirm no bundle already covers this feature (Instructions § 1).
2. Interview the operator in batches, following
   `references/interview-guide.md`.
3. Write the bundle in this exact order — `README.md`, then
   `project/BusinessSpec.md`, then `project/DesignSpec.md` — following
   `references/spec-output-shape.md`.
4. Tell the operator the bundle's path and name every item you recorded as
   an open question instead of answering yourself.

## Instructions

### 1. Confirm no bundle already exists

`Glob` `.aimi/design-bundles/*/README.md`. If a bundle for the same feature
already exists, stop and tell the operator — ask whether to extend that
bundle or pick a new slug, rather than silently overwriting it. Read the
matched `README.md` only far enough to see its own feature description; you
do not need the rest of an existing bundle to make this call.

### 2. Interview the operator

Ask in small, batched questions rather than one at a time — the operator's
answers drive everything you write next. `references/interview-guide.md`
splits the question bank into what your own write step can generate
directly from an answer, and what you must either ask for by name or, when
the operator does not know or declines, record verbatim in the generated
spec's own open-questions section. Never invent an answer to a Category B
item yourself — see **What You Do NOT Do** below.

### 3. Choose the bundle slug

Derive a slug from the feature or product name the operator gave you:
lowercase, spaces and punctuation collapsed to single hyphens, no leading or
trailing hyphen. Check the `Glob` result from step 1 for a collision; if the
slug is already taken by a different feature, append `-2`, `-3`, … until it
is unique. The bundle root is `.aimi/design-bundles/<slug>/`.

### 4. Write the bundle

Follow `references/spec-output-shape.md`'s write order and procedure
exactly: `README.md` first, then `project/BusinessSpec.md`, then
`project/DesignSpec.md`. That file resolves every section number for you at
run time against the contract — never copy a section number from memory or
from a prior bundle you happened to read.

### 5. Report back

Tell the operator the bundle's root path and list, by name, every item you
recorded as an open question rather than answered — that list is what tells
them, and `/aimi:plan` later, what still needs a human or a codebase
decision.

## Artifact Language Rule

This skill's own scaffolding prose — its section headings, instructional
labels, and placeholder copy — is English, because everything it writes
lives under `.aimi/` and an artifact this plugin owns is written in English
(`commands/references/user-communication.md`'s Artifact Language Rule). The
operator's own answers — product language, feature names, business-rule
wording, acceptance-criteria phrasing — are recorded verbatim, in the
operator's own language, under that same rule's quoted-content carve-out.

`agents/research/aimi-bundle-prototype-author.md`'s Output Contract invokes
the identical carve-out, but for a different reason: it quotes text out of a
`DesignSpec`/`BusinessSpec` that already exists and already has a language.
This skill has no such document to quote from — it originates the spec text
itself, directly out of the operator's live answers, so the "quoted
content" here is the operator's own words as they gave them, not a passage
copied from a file that predates this conversation.

## What You Do NOT Do

- **Never assume a project's icon library, CSS/component framework default,
  or the file path of an existing component.** A bundle writer that has
  never seen the target repository cannot know any of these — an earlier
  DesignSpec gloss elsewhere in this plugin hardcoded exactly this kind of
  assumption and was wrong often enough to be worth naming as the failure
  mode to avoid. Ask the operator directly; when they do not know or
  decline to answer, record the item verbatim in the generated spec's own
  open-questions section instead of guessing.
- **Never write the Claude Design handoff marker into `README.md`.** This
  bundle was not produced by a Claude Design session. Read the
  `AIMI_GENERATED_MARKER` constant's literal value at write time — see
  `references/spec-output-shape.md` § README — rather than retyping the
  sentence by hand anywhere in this skill or its references, which would
  let the two silently drift apart.
- **Never hardcode a BusinessSpec or DesignSpec section number, or restate
  what a section number means, in this file or in `references/`.** Resolve
  every section number at run time from
  `plugins/aimi-engineering/commands/references/spec-section-contract.md` —
  see `references/spec-output-shape.md`'s resolution procedure. A number
  written here would drift the moment the contract's own table changes.

## Input Sanitization

Every operator answer you record verbatim still passes through the same
minimal hygiene any prose written into a markdown spec needs: strip literal
control characters, close any code fence the answer itself opens (an
unterminated triple-backtick in an operator's answer would swallow the rest
of the file), and cap a single answer at roughly 5000 characters, noting the
truncation if you have to apply it. This is hygiene, not translation or
paraphrase — the operator's own words and language stay exactly as given.

## References

- `references/interview-guide.md` — the question bank, split into what your
  own write step can generate directly from an answer and what you must ask
  for by name or leave as an open question.
- `references/spec-output-shape.md` — the write order, the README's marker
  line, and the run-time section-number resolution procedure.

## Examples

**Operator has a feature in mind, no existing bundle.** The operator
describes a "vendor onboarding" flow. No `.aimi/design-bundles/*/README.md`
matches it. You interview them for screens, roles, and business rules
(Category A), ask about an icon library and component path (Category B),
and they say "no idea, whatever the codebase already uses." You write
`.aimi/design-bundles/vendor-onboarding/` with `README.md`,
`project/BusinessSpec.md`, and `project/DesignSpec.md`, and record the icon
library and component path as open questions in `DesignSpec.md` rather than
picking one yourself.

**A bundle for the same feature already exists.** Step 1's `Glob` turns up
`.aimi/design-bundles/vendor-onboarding/README.md`. You stop before
interviewing and ask the operator whether to extend that bundle or use a
different slug for this session, instead of overwriting what is already
there.
