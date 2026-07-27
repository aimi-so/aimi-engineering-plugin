# User Communication

Shared reference for the wording, tone, and density of text a plugin command sends directly to the person running it — completion reports, chat explanations, and `AskUserQuestion` prompts. Apply the rules in this file wherever a command emits text meant for a human reader, not another agent.

**Consumed by:** `execute.md`, `plan.md`, `brainstorm.md`, `next.md`, `setup-models.md`, `learnings.md`, `commands/design/shape.md`, and `commands/design/polish.md` — every command file with an `AskUserQuestion` call site or a completion-report block.

## Scope

In scope: completion reports, chat explanations, and `AskUserQuestion` prompts — any text a human reads and acts on.

Out of scope: text sent to subagents (Task spawn prompts). A spawn prompt optimizes for **sufficiency to a fresh-context agent** — a complete objective, output format, tool guidance, and stop condition an agent can act on without follow-up — not for human readability. Applying this file's density and jargon rules to a spawn prompt would strip context an agent needs, causing it to guess and redo work, which costs more than the words saved. Spawn prompts are governed by neither this file nor `AGENTS.md` (see Boundaries below) — see the Performance Guidelines in `plugins/aimi-engineering/CLAUDE.md` for prompt-construction rules instead.

### What Counts as a Real Example Source

Every "Before:" half below is real, quoted text — but not everything in a command file qualifies as a source. Only text actually **displayed to the human** counts: fenced-block literal templates and quoted `AskUserQuestion` question/option strings. Instructional prose addressed to the orchestrating LLM — the surrounding paragraphs that tell the model what to compute, when, and why — is dense by design; it is written for a model that reads once and acts, not a person who reads and re-reads. That prose must never be cited here as a violation. Every "Before:" half in this file passes this test: each is copied from a fenced block or a quoted question/option string, never from LLM-facing instructional prose.

## Boundaries

**Format vs. wording.** This file governs wording, tone, and density — never `AskUserQuestion` *format* (lettered A/B/C options, escape-hatch-last, 2-6 option count). Format is owned by `commands/references/interactivity.md`. When both apply to the same picker: the option letters, order, and count come from `interactivity.md`; the words inside each option come from here.

**Clarity vs. compression.** `AGENTS.md` governs a different, non-overlapping category: text an agent returns to its orchestrator (status updates, summary returns, progress reports, task confirmations). Its axis is token economy — shorter is better, fragments over sentences. This file's axis is human clarity, and the two sometimes pull in opposite directions: a compressed fragment that saves tokens for an orchestrator can read as a wall of jargon to a person. Neither file overrides the other — they govern different senders and different readers, and a command body can be correct under both at once only because they never apply to the same span of text.

## Jargon Carve-Out

Not all technical language is a violation. Sort any term into one of three buckets before treating it as a problem.

### Bucket 1 — Real, Searchable Proper Nouns: may appear unglossed

A name that points at one real, findable thing — a git concept, a CLI flag, a function name. A person can copy it into a search or a `--help` output and find exactly what it means.

Examples: `merge-base`, `--split full-stack`, `_story_merge_write_split`.

### Bucket 2 — Invented On-the-Spot Abstractions: gloss on first use, or don't use

A term coined for one explanation, documented nowhere else. Nobody can search for it; its only definition is whoever just said it.

Examples: "false root," "bipartition invariant," "token-aware." If a term like this must appear, gloss it in the same sentence on first use. If there is no room to gloss it, cut the term and say what it means instead.

### Bucket 3 — Internal ALL-CAPS Code Symbols: classify into Bucket 1 or 2, never leave unclassified

Being real code doesn't put an ALL-CAPS symbol in Bucket 1 — the test is whether a person outside this codebase would recognize it or search for it, not whether it exists in the source.

- `PHASE_SPLIT_MODE`, `CONTAINER_MODE` — **Bucket 2.** Internal state flags meaningful only to the orchestrating command's own control flow, not names a person would recognize or search for. A completion report should say "the stories ran as separate splits, one per output file," never surface the variable name.
- `--split full-stack` — **Bucket 1**, even though it is also a literal CLI flag: it is documented in `aimi-cli.sh`'s own help output and in `plugins/aimi-engineering/CLAUDE.md`, so a person can search and find it.

The dividing question for any ALL-CAPS symbol: would a person outside this codebase recognize it or successfully search for it? If yes, Bucket 1. If it only means something inside this plugin's own control flow, Bucket 2 — gloss it or cut it before it reaches the human.

## Adaptive Language Rule

The plugin's user-facing output language follows whatever language the person is writing in — Portuguese in, Portuguese out; English in, English out. A command that hardcodes a single language into a completion report or an `AskUserQuestion` prompt is a defect under this rule, regardless of which language is hardcoded.

This file does not fix any existing hardcoded-language call site — that is separate, follow-up work. It states the rule here so future text, and future fixes, have something to point at.

## Before/After Pairs

Convention: every "Before:" below is real, quoted verbatim text with a citation — a `file:line` pointer, or "session-sourced" when drawn from the assistant's own chat messages in the session that motivated this file (the repo persists no chat transcript, so no `file:line` exists for those). Every "After:" is an authored rewrite of that same passage, written for this file — it cannot also be pre-existing text, since a fixed version of a passage cannot exist verbatim while the defect it fixes is still live. Each pair addresses exactly one problem: density (too many facts packed into too few sentences) or untranslated jargon (an unglossed Bucket 2 term).

### 1. Untranslated jargon — Pass 2 failure options

Source: `plan.md:2014-2019`.

Before:
```
Pass 2 expansion failed for N story(ies):
<list of failed idx + title>
Options:
  Skip failed — proceed to story-merge without them
  Retry with hint — provide additional context for failed stories, then re-expand
  Abort — stop plan generation
```

After:
```
Couldn't finish detailing N of your stories:
<list of failed idx + title>

What would you like to do?
  Skip them — continue without these N stories
  Add more detail — give extra context, then retry just these
  Stop — cancel this planning run
```

Checkable: grep the block for `Pass 2|expansion|story-merge` (case-insensitive) — zero matches; every internal pipeline-stage name is replaced with plain language.

### 2. Untranslated jargon — Greenfield Foundation Gate options

Source: `plan.md:1278-1281` — real, quoted verbatim in the original Portuguese (`"Pular — planejar sem foundation"`, et al.); translated into English below per the Adaptive Language Rule above and this file's own English-only convention.

Before:
```
[foundationMode=greenfield] Accept — use the proposed architecture
[foundationMode=brownfield] Accept — capture the existing conventions
Adjust — describe changes
Skip — plan without foundation
```

After:
```
[foundationMode=greenfield] Accept — use the proposed architecture
[foundationMode=brownfield] Accept — capture the existing conventions
Adjust — describe changes
Skip — plan without reviewing the proposed architecture first
```

Checkable: no bare internal feature name ("foundation") appears in an option's text without a plain-language gloss in the same clause.

### 3. Untranslated jargon — outline warning preamble

Source: `plan.md:1633-1635`.

Before:
```
[warn] outline:<idx>: summary too short (<N> chars) — expand to clarify scope.
[warn] outline:<idx>: path token '<token>' not found in File References — verify coverage.
[warn] ... and N more entries with potential outline gaps.
```

After:
```
Story <idx>'s summary is short (<N> chars) — consider adding more detail.
Story <idx> mentions '<token>', but no source file covers it yet — worth checking.
... and N more stories worth a second look.
```

Checkable: grep the block for `outline:|File References|path token` — zero matches; each line names the story and the concern, not the internal identifier.

### 4. Density — merge-conflict report

Source: `execute.md:1491-1503`.

Before:
```
MERGE CONFLICT while merging phase [PHASE_ID]'s split branches into [PHASE_BRANCH].
Split branches merged: [one line per active split branch]
Conflicting files:
[conflict output from merge-all]

Resolve the conflict on branch [PHASE_BRANCH] in [PHASE_CONTAINER_PATH] and re-run
`/aimi:execute` to continue. Every split file's stories are already marked complete —
re-running will not re-execute them, only retry this merge and the phase-completion
checks that follow it.

The phase container [PHASE_CONTAINER_PATH] itself — and any live dev server running
inside it — is left untouched by this failure; only the split worktrees above are
removed.
```

After:
```
Merge conflict — phase [PHASE_ID]'s split branches don't merge cleanly into [PHASE_BRANCH].

Split branches merged: [one line per active split branch]

Conflicting files:
[conflict output from merge-all]

To fix:
1. Resolve the conflict on branch [PHASE_BRANCH] in [PHASE_CONTAINER_PATH].
2. Re-run `/aimi:execute`.

Nothing else is affected: your stories are already marked complete, and the phase
container (including any running dev server) is untouched. Re-running only retries
this merge.
```

Checkable: count instruction-plus-justification sentences — before has two sentences that each carry an instruction and a separate justification clause together; after gives each its own line or numbered step.

### 5. Density — session-sourced chat explanation

Source: session-sourced — reconstructed from the brainstorming session that motivated this file; no `file:line` citation exists, since the repo persists no chat transcript.

Before:
```
I found that the reference directory has 10 files totaling 1,425 lines with
cli-path-resolution.md at 248 and visual-variants.md at 386 being outliers, and the
shared structural shape across all of them is an H1 title followed by an opening
paragraph starting "Shared reference for" and ending with an "Apply wherever"
instruction, plus an optional bold Consumed-by line, and before/after pairs are rare
— the only instance is in scope-contexts.md:75-76 — so the new file should synthesize
AGENTS.md's Before/After shape with that Good/Bad pair instead of copying an existing
file wholesale.
```

After:
```
The reference directory has 10 files, 1,425 lines total. Two outliers:
cli-path-resolution.md (248 lines), visual-variants.md (386 lines).

Every file shares one shape: an H1 title, a "Shared reference for..." opening
paragraph ending in "Apply wherever...", and an optional bold Consumed-by line.

Before/after pairs are rare — only one exists, in scope-contexts.md:75-76. The new
file pairs that shape with AGENTS.md's Before/After format, rather than copying
either wholesale.
```

Checkable: count distinct findings per sentence — before packs four into one sentence; after gives each its own sentence or paragraph.
