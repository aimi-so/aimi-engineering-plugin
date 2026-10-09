# BusinessSpec Authoring

On-demand reference for authoring a `BusinessSpec.md` from the operator's own answers plus a repository scan. Read by `commands/brainstorm.md` (Phase 3.9) and by `skills/aimi-design-handoff/references/interview-guide.md`; both point here rather than carrying a copy of this procedure.

## Artifact Language Rule

A BusinessSpec this procedure writes is a plugin-owned artifact and is written in English; the rule and its carve-outs live in `commands/references/user-communication.md` (§ Artifact Language Rule). Text the operator dictated that is quoted verbatim keeps its own language.

## Fire rule

Author a BusinessSpec only when the feature is an application feature. Whether it is one is decided by `commands/plan.md`'s **Implementation Scope Detection** section, which is the single source of the non-app keyword list and of the conflicting-signals handling. This reference restates no list of its own: read that section at run time and apply it unchanged. A non-app feature (and a feature whose bundle already carries a BusinessSpec) skips this procedure entirely with one log line.

## Questionnaire

These items come only from the operator's own answers (Category A of the interview guide). Ask in small batches, skip what was already answered, and record answers in the operator's wording.

| Item | Section category | Rule |
| --- | --- | --- |
| Purpose | purpose / overview | One or two sentences, the operator's words |
| Business rules | business rules | One numbered sentence each, ids `RN-01`, `RN-02`, ... in the order given; never renumber |
| Personas / roles | personas / roles | Who uses what, and what differs between roles |
| Acceptance criteria | acceptance / success criteria | Verbatim, rule ids preserved |
| Screens / views | the screen list | Ask only when no prototype or bundle already names them |

Nothing in this table may be guessed. An item the operator cannot or will not answer is recorded verbatim as an open question, never filled in.

## Propose-then-correct

Entities and endpoints are repository facts, not operator opinions, so they are proposed and then corrected rather than asked for.

1. Spawn the `aimi-spec-deriver` agent with the entity and endpoint names the operator mentioned as `targets`. It returns one fenced `spec_derivation` block.
2. Save that block's JSON to a scratch file and render it with the verb:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DERIVATION_FILE="<scratch path holding the spec_derivation JSON>"
$AIMI_CLI spec-derivation --input "$DERIVATION_FILE"
```

3. The verb's `markdown.entities` rows fill the data-model section and its `markdown.endpoints` rows fill the endpoint section (and its numbered subsections). Copy these rows as returned; the entity and endpoint rows come from the deriver and from nowhere else, never from a guess.
4. Show the rows to the operator and ask for corrections. Apply corrections as the operator words them.

In agent mode there is no operator: accept the proposals as-is, and turn any questionnaire item that would otherwise need the operator into an entry in the open-questions section.

## Absent vs unchecked

Three statuses, three different answers: `present` (found, with `path:line` evidence), `absent` (searched and not there, with the searches as evidence) and `unchecked` (not looked at).

An `absent` record with empty evidence says nothing was searched, so the verb relabels it `unchecked` and renders it with the distinct literal text `unchecked (claimed absent, no evidence)`. The verb reports each relabel on stderr; surface every relabeled record to the operator as a correction item ("the scan claimed this is absent but showed no search -- check it, or confirm it is new"). A genuinely never-checked record (status `unchecked` from the start) renders as plain `unchecked` and is not a correction item. Never rewrite either label to `absent` or `present` without evidence.

## Core vs per-phase

The sections split by when they can be written.

- **Shared core = § 1, § 3, § 7, § 11** -- authored at brainstorm for every feature, phased or not.
- **Per-phase detail = § 2, § 4, § 5, § 9** -- authored in full at brainstorm for a feature without phases. For a phased feature, brainstorm writes each per-phase section as a section containing exactly the literal marker line `<!-- aimi:per-phase-detail-deferred -->` and nothing else; `plan.md`'s roadmap mode later authors that phase's detail into the phase-tier bundle.

The numbers above name the contract rows, and the next section governs how they are written.

## Write procedure

1. Resolve every BusinessSpec section number at run time from `commands/references/spec-section-contract.md`, exactly as `skills/aimi-design-handoff/references/spec-output-shape.md` § "Resolving a Section Number" describes: find the row whose Backs column matches the content category, use that row's Section value for the heading. Never copy a number from this reference or from an earlier bundle.
2. Write `project/BusinessSpec.md` with the core sections from the questionnaire, the entity and endpoint sections from the deriver rows (or the deferred marker line for a phased feature), and the open-questions section from every unanswered item.
3. Write the bundle `README.md` following `spec-output-shape.md`'s `README.md` paragraph, which reads the generated-bundle marker (`AIMI_GENERATED_MARKER`) out of `aimi-cli.sh` at write time. Do not retype the marker here or anywhere else.
4. Report the sections written, the sections deferred, and every relabeled record still awaiting the operator.
