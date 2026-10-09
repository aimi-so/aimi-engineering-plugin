# Interview Guide

The interview has one job: separate what you can write directly from the
operator's own answers from what only the repository, or the operator
speaking for it, can supply. Never blur the two — an answer you invent to
fill a Category B gap is exactly the failure this skill exists to avoid.

Ask in small batches (three to five related questions at a time), and let
the operator's answers steer which follow-ups you ask next. You do not need
to ask every question below in every session — skip anything the operator
has already answered unprompted, and drop a topic entirely when it plainly
does not apply to their feature (e.g. no data model question for a
single-static-screen feature).

## Category A — Generated Directly From the Operator's Own Answers

Everything here becomes spec content the moment the operator answers it. No
repository access is needed, and nothing here should ever become an open
question — if the operator can describe their own product, you can write it
down.

The Category A items (purpose, screens / views, business rules, personas /
roles, acceptance criteria, and the data-model note) are defined once, in
`commands/references/business-spec-authoring.md` under its **Questionnaire**
section. Follow that section for what to ask, how to number business rules
(`RN-NN`, in the order given) and how to record acceptance criteria verbatim.
Entities and endpoints are not asked for: that reference's
**Propose-then-correct** section covers them.

## Category B — Ask By Name, or Leave Open

Nothing here is yours to decide. A bundle writer has never seen the target
repository, so a guess at any of these is not a shortcut — it is a
fabricated assumption a later story would inherit as if it were fact. Ask
each one directly. When the operator does not know, declines, or says
"whatever's already there," do not pick a default: record the item verbatim
in the generated spec's own open-questions section instead, worded closely
enough to what the operator actually said that a later reader can tell it
was genuinely unanswered rather than paraphrased away.

- **Icon library** — which icon set (if any) this feature's screens should
  draw from.
- **Component path** — where, in the target project's own source tree, an
  existing component library or design system already lives, if one does.
- **Design-system mapping** — whether this feature should reuse an existing
  design system's components, tokens, or patterns, and which ones.
- **Token source** — where visual tokens (color, spacing, typography) come
  from for this project — a token file, a config, or "ask the design
  system," never a value you supply yourself.

## Writing Down an Open Question

When an item lands here, the wording matters: write what the operator
actually told you (including "I don't know" or "not sure yet"), not a
rephrased question that sounds like you are the one asking it. The
generated spec's open-questions section is a record of what the operator
left unresolved, not a checklist you authored.
