# Spec Section Contract

Several commands, agents and one script already parse a Claude Design handoff
bundle's `BusinessSpec.md` and `DesignSpec.md` by section **number** — never by
a language-bound heading title, since that title is whatever language the spec
instance renders it in. Until now that numbering was implicit, reconstructed
independently by each reader. This file makes it explicit: one row per section
number every reader currently depends on, what a consumer may rely on there,
and which files read it today. A number absent from this file is a citation no
current reader depends on; adding a new dependency on a number means adding its
row here in the same change.

**Consumed by:** `commands/brainstorm.md`, `commands/plan.md`, `commands/deepen.md`,
`commands/references/business-spec-authoring.md`,
`agents/research/aimi-design-bundle-researcher.md`,
`agents/research/aimi-bundle-prototype-author.md`,
`agents/workflow/aimi-story-expander.md`, `skills/story-executor/SKILL.md`, and
`scripts/tasks.py`'s `validate-tasks` citation matching (`spec_contains`,
`tasks.py` around line 1806 — fixed-string substring containment against the
cited subsection's body, never a parsed dotted path; this is why the
`responseShape` flat-key contract in `commands/plan.md` § "responseShape
contract" holds: a subsection naming `portfolio` and `totalUsinas` separately
still rejects the literal `portfolio.totalUsinas`).

**This contract binds numbers, never titles.** No consumer listed below matches
a heading's text — that text is language-instance-specific prose. Where a
consumer parses a heading at all, it does so structurally rather than by title:
`commands/brainstorm.md`'s Specs index (around line 1467) extracts whatever
text follows a numbered heading using the pattern `^## <n>. <title>$` and
renders it back, it never matches *against* a title.

## Bundle Layout

A directory is a Claude Design handoff bundle when its root `README.md`
contains the literal marker `This is a **handoff bundle** from Claude Design
(claude.ai/design).` (`scripts/aimi-cli.sh`, `cmd_detect_design_bundle`, around
line 10614) — a fixed-string, case-sensitive check, never a heuristic over the
directory's contents. A bundle this plugin generates instead carries its own
second marker, owned by `aimi-cli.sh` and cited here rather than restated,
which the design handoff skill (US-004 of this phase) writes and checks.

Both spec files live at `project/BusinessSpec.md` and `project/DesignSpec.md`,
relative to the bundle root. That is the only location `detect-design-bundle`
and `bundle-prototype-status` agree on: `detect-design-bundle` discovers each
spec case-insensitively under `<bundle>/project/` only (`aimi-cli.sh` around
lines 10732–10733), while `bundle-prototype-status` is bundle-root-tolerant and
falls back to the bundle root itself when `project/` has no match
(`aimi-cli.sh` around lines 10883–10918). A spec file placed anywhere else is
invisible to the stricter of the two readers.

## BusinessSpec Sections

| Section | Backs | Consumers |
| --- | --- | --- |
| `BusinessSpec § 1` | Purpose / overview | `brainstorm.md` Purpose auto-pass, `plan.md`, `commands/references/business-spec-authoring.md` |
| `BusinessSpec § 2` | The canonical screen/view list (see *Screen List* below) | `plan.md` screen-per-story decomposition and validation (around lines 2711, 3498), `deepen.md` missing-AC gate (around line 226) |
| `BusinessSpec § 3` | Business rules, each with an `RN-NN` id | `plan.md` `businessRules`, `deepen.md` rule-id annotation gate, `skills/story-executor/SKILL.md` Rule-ID citation rule, `commands/references/business-spec-authoring.md` |
| `BusinessSpec § 4` | Data models / entities; one story per non-trivial entity | `plan.md` `dataModels`, `aimi-design-bundle-researcher.md` verbatim passthrough |
| `BusinessSpec § 4.1` | A numbered subsection of § 4 | `aimi-design-bundle-researcher.md` (citation-example use only) |
| `BusinessSpec § 5` | Endpoint / API groups (with `§ 5.1`, `§ 5.3` subsections) | `plan.md`, `aimi-design-bundle-researcher.md` |
| `BusinessSpec § 5.1` | An endpoint group subsection of § 5 | `plan.md` |
| `BusinessSpec § 5.3` | An endpoint group subsection of § 5; every `endpoints[].responseShape` source cites a subsection here, checked by `spec_contains`'s fixed-string containment | `plan.md`, `tasks.py` `validate-tasks` |
| `BusinessSpec § 7` | Personas / roles; one story per tier | `brainstorm.md` Users auto-pass and Personas render, `plan.md` `userRoles`, `commands/references/business-spec-authoring.md` |
| `BusinessSpec § 9` | Acceptance / success criteria, seeded verbatim with rule ids preserved | `brainstorm.md` Success auto-pass, `plan.md` AC seeding, `deepen.md` missing-AC gate, `aimi-design-bundle-researcher.md`, `aimi-bundle-prototype-author.md`, `aimi-story-expander.md`, `skills/story-executor/SKILL.md` Rule-ID citation rule, `commands/references/business-spec-authoring.md` |
| `BusinessSpec § 11` | Open questions; bundle-sourced OQs are not exempt from resolve/defer | `brainstorm.md`, `commands/references/business-spec-authoring.md` |

## DesignSpec Sections

| Section | Backs | Consumers |
| --- | --- | --- |
| `DesignSpec § 1` | Design tokens, a flat map of token categories; authoritative over any Tailwind-CDN fallback | `brainstorm.md` token extraction and Aesthetic Direction/Differentiation skip, `plan.md` `designTokens`, `tasks.py` visual-AC citation check, `aimi-design-bundle-researcher.md`, `aimi-bundle-prototype-author.md`, `aimi-story-expander.md`, `skills/story-executor/SKILL.md` designTokens passthrough rule |
| `DesignSpec § 2.2` | Component inventory's NOVOS subsection — new components with prop signatures; one story per entry | `plan.md`, `brainstorm.md` Specs index, `deepen.md` prop-type signature enforcement |
| `DesignSpec § 3` | View-name inference source, used only when `viewSource='infer'` | `aimi-bundle-prototype-author.md` |
| `DesignSpec § 4` | Reference maps — per-view content, never the screen list | `aimi-bundle-prototype-author.md`; also the stale skip-message citation swept by US-006 of this phase |
| `DesignSpec § 6` | Component-name-to-existing-project-path mapping table, read at run time, never a fixed path | `deepen.md` conflict detection, `skills/story-executor/SKILL.md` Match-visual-output and Component-mapping rules |
| `DesignSpec § 8` | Open questions; same role as `BusinessSpec § 11` | `brainstorm.md` |

## The Screen List: One Canonical Section

`BusinessSpec § 2` is the single canonical section for the screen/view list.
Three call sites already agree on this: `plan.md`'s screen-per-story
decomposition (around line 2711), `plan.md`'s validation pass (around line
3498), and `deepen.md`'s missing-AC gate (around line 226).

A different, incorrect citation is still live in `brainstorm.md` and `plan.md`,
in the bundle-prototype-generation skip message emitted when `view_source` is
`'none'` (`brainstorm.md` around line 140, `plan.md` around line 214):

```
bundle prototype generation skipped — no view list in DesignSpec § 4 or BusinessSpec § 5/§ 6
```

None of `DesignSpec § 4`, `BusinessSpec § 5`, or the nonexistent
`BusinessSpec § 6` is a screen list. `BusinessSpec § 2` is. Correcting those two
call sites onto the canonical section is a separate, later story in this phase
(US-006) — this document states the contract; it does not sweep the stale
citations itself.

## No Project-Specific Assumption

`DesignSpec § 6` is the section most at risk of carrying a project-specific
assumption, because the writer that produces a spec cannot see the repository
it will be consumed by. `deepen.md`'s current component-mapping conflict
detection (around line 249) both hardcodes a fixed `@/components/ui` path and
names the section by a Portuguese gloss ("Mapeamento para `@/components/ui`")
rather than by number alone — a project-specific assumption baked into a
project-agnostic contract. Correcting that call site is US-006's job, not this
document's; this section exists so the risk is written down before it is
fixed.

## Re-measuring This Contract

Run this from the plugin root to re-derive the citation set this file is
required to cover in full:

```bash
grep -rhoE '(BusinessSpec|DesignSpec) § [0-9]+(\.[0-9]+)?' commands/ agents/ skills/ | sort | uniq -c
```

Every distinct value this command prints must appear, verbatim, as a
`BusinessSpec § N[.N]` or `DesignSpec § N[.N]` table row above. A new citation
that adds a number not yet covered here is incomplete until this file's table
gains a matching row in the same change.
