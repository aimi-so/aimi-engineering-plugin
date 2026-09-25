# Spec Output Shape

Write exactly three files, in this order, all under one bundle root
`.aimi/design-bundles/<slug>/`:

1. `README.md` at the bundle root.
2. `project/BusinessSpec.md`.
3. `project/DesignSpec.md`.

This is the one bundle location both of the CLI's own bundle readers agree
on — the stricter of the two only ever looks for a spec under `project/`,
never at the bundle root. Do not write either spec file anywhere else, and
do not skip `project/` even when nothing else lives beside it yet.

## Resolving a Section Number — Never From Memory

Neither this file nor `SKILL.md` may state a section number or what it
means. Every time you are about to write a numbered heading into
`BusinessSpec.md` or `DesignSpec.md`, resolve that number fresh: `Read`
`commands/references/spec-section-contract.md` (the plugin's own copy is at
`plugins/aimi-engineering/commands/references/spec-section-contract.md`) and
find the table row — under **BusinessSpec Sections** or **DesignSpec
Sections** — whose **Backs** column describes the content category you are
about to write (e.g. the row backing the business-rules content, or the row
backing the design-tokens content). That row's **Section** column is the
number to use in your `## <n>. <title>` heading. If a content category you
gathered in the interview has no matching row in either table, still write
it — a section absent from the contract is simply one no current consumer
depends on by number, not one you may not write — but pick the next
unclaimed integer in that spec's own sequence and do not reuse or renumber a
row the contract already claims.

Re-read the contract file for every bundle you write. It is a shared file
this skill does not own, and a number it states today is the only number
that is ever correct — copying one forward from an earlier bundle you wrote
is exactly the staleness this procedure exists to prevent.

## `README.md`

Contents:

- A short paragraph describing the feature, in the operator's own words
  where possible.
- One line carrying the plugin's own generated-bundle marker, read at write
  time rather than retyped. `Read` `scripts/aimi-cli.sh` around the
  `cmd_detect_design_bundle` function (currently near line 10618, but
  re-locate it by function name rather than trusting the line number, since
  the file changes) and find the line assigning the `AIMI_GENERATED_MARKER`
  shell variable. Copy that string's literal value — exactly, including its
  punctuation — as the marker line in `README.md`. Never hand-type this
  sentence from memory, and never write the *other* marker string the same
  function defines beside it: that other one names a different tool as this
  bundle's origin, and this bundle did not come from there.
- A one-line pointer to `project/BusinessSpec.md` and `project/DesignSpec.md`.

## `project/BusinessSpec.md`

Write one numbered heading per content category you have material for,
using the resolution procedure above for each heading's number. Typical
categories, each only if the interview produced content for it: purpose,
the canonical screen/view list, business rules (each carrying its own
`RN-NN` id, in the order the operator gave them), data models, personas or
roles, and acceptance criteria (seeded verbatim from the operator's own
wording, with any cited rule ids preserved).

End the file with its own numbered open-questions section (resolved the
same way) listing every Category B item from `references/interview-guide.md`
that the operator left unanswered, worded as they actually left it.

## `project/DesignSpec.md`

Write one numbered heading per content category with material, resolved the
same way: design tokens (if the operator gave you any — otherwise omit the
section rather than inventing values), new component inventory, the view
list this spec's screens use, per-view reference notes, and a
component-mapping section.

The component-mapping section is where an unanswered icon library,
component path, design-system mapping, or token source lands when the
operator did not supply one — do not fold it into the file's general
open-questions section instead; a future reader looking for exactly this
kind of gap should find it in the section that is supposed to hold it.

End the file with its own numbered open-questions section, the same shape
as `BusinessSpec.md`'s, for anything left over that does not belong in the
component-mapping section.
