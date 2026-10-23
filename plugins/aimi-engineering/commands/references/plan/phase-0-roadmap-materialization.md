# Plan: Phase 0: Roadmap Materialization

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Roadmap Materialization

This step turns `/aimi:brainstorm`'s Phase 3.5 roadmap-gate output (the `phases:` frontmatter block — see `commands/brainstorm.md` "phases frontmatter rules") into durable, guard-protected state via `aimi-cli.sh`. `/aimi:brainstorm` never writes `.aimi/tasks/<feature-slug>/roadmap.json` itself; this is the only place that does. The "Sanitize every phase field," "Derive and validate each phase's directory segment," and "Detect existing roadmap.json and materialize" steps below are also reused, by name, by the Scope-Context Classification (Inline Fallback) subsection further down this phase — the fallback proposes a `phases` array itself, from a classification pass rather than brainstorm frontmatter, and re-enters this section's steps to sanitize and materialize it rather than reimplementing them.

**Parse `phases:` frontmatter**

1. Parse the `phases:` key from the same brainstorm frontmatter block already loaded above. Each entry carries `id, name, slug, goal, successCriteria, dependsOn, creates, needs, areas` in that fixed order.
2. **If the key is absent** (legacy brainstorm, single scope-context feature, or the roadmap gate was skipped/collapsed): skip the rest of this section entirely. No `.aimi/tasks/<feature-slug>/` folder is created, no `roadmap.json` is written, and the rest of the pipeline (Phase 1 through Phase 3e) behaves identically to today's flat, non-phased flow. This is the default, most common path — emit no log line.
3. **If present but fewer than 2 entries** (defensive re-check — `/aimi:brainstorm` never emits a single-entry `phases:` list, but a hand-edited or externally authored brainstorm might): treat as absent. Emit one warning line `phases: frontmatter has fewer than 2 entries — ignoring, falling back to flat flow` and skip the rest of this section.

*(Optional debug: if `AIMI_PLAN_DEBUG=1`, emit `[plan-debug] roadmap-materialization: <fired|skipped> (reason: phase-entries=<N>)` to chat, where `<N>` is the number of `phases:` entries parsed from the frontmatter (0 when the key is absent) — `fired` when `<N>` is 2 or more and the rest of this section runs, `skipped` when `<N>` is 0 (key absent) or 1 (defensive re-check above, treated as absent).)*

Set the `roadmapMaterializationVerdict` working-memory variable to the same `<fired|skipped>` token computed above — read back, never recomputed, by the Classification Summary Line subsection below. (When a brainstorm was loaded but the `phases:` key was absent or held fewer than 2 entries, this gate's own trigger check DID run and decided not to fire — that is `skipped`, distinct from the `not-run` set at this section's entry guard above where the trigger check never evaluated at all.)

**Sanitize every phase field**

For each remaining phase entry, apply the base rules in `commands/references/sanitization.md` (delete fenced blocks whole but **unwrap** a single backticked span to its inner text, strip HTML/XML tags, strip instruction-override patterns) plus the newline/`$(`-stripping extension already applied to Path Hints and Phase 1.8 OQ text elsewhere in this command, to every free-text field, before it is used in any directory-segment derivation, CLI argument, or downstream prompt.

**`creates` and `needs` are not free-text fields.** Each entry is `{identity, description}`, and the two halves take opposite treatment — `commands/references/sanitization.md` § *Contract Entries* states the carve-out that governs this step, and points in turn at the rule's normative home. Applied here: pass each `identity` through **verbatim** (no sanitization, no trimming, no truncation) and treat the `description` beside it as ordinary free text, subject to every rule below including the 500-char cap. Do not judge an identity here — submit it as authored and let `roadmap-init` refuse it; the repair-and-retry rule further down this section exists for exactly that.

For every other field:

- Replace newlines/carriage returns with spaces.
- Strip `$(` sequences and backtick characters.
- Truncate: `name` 200 chars, `goal` 2000 chars, each `successCriteria` entry 2000 chars, each `creates`/`needs` **description** and each `areas` entry 500 chars (each cap matches the truncation `roadmap.py` re-applies — 2000 for `successCriteria`, 500 for descriptions and `areas` — so nothing added here is silently re-truncated a second time downstream. Those lists do **not** share `successCriteria`'s cap; using 2000 for them clips looser than the CLI does and loses the tail of a long entry at the CLI boundary instead of here). **Never truncate an `identity`** — the CLI refuses one over 500 characters rather than clipping it, because a clipped name is one `verify-creates` would grep for and never find.
- Each of `successCriteria`, `dependsOn`, `creates`, `needs`, `areas` defaults to an empty list `[]` when absent from the entry.
- `id` and each `dependsOn` entry are numbers, not text — do not run them through string sanitization. Instead validate `id` is present and numeric; drop (with a warning `phase <n>: dropped — id missing or non-numeric`) any entry that fails.
- **Discard the frontmatter's own `slug` value entirely — never trust it.** The next step derives a fresh one from the sanitized `name`.

**Derive and validate each phase's directory segment**

For each sanitized phase entry, in order:

1. Derive `candidateSlug` from the *sanitized* `name` using the five-step algorithm in `commands/references/topic-slug.md`.
2. Compose `candidateDir = "phase-" + <id> + (candidateSlug non-empty ? "-" + candidateSlug : "")`, rendering `<id>` exactly as its numeric frontmatter value (e.g. `2` or `2.1`).
3. Validate `candidateDir` against `^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$` — the identical pattern `aimi-cli.sh` enforces server-side as `_ROADMAP_DIR_REGEX`.
4. **Match:** use `candidateSlug` as the phase's `slug` field in the payload built below.
5. **No match** (topic-slugging already excludes slashes and `..` in the common case, but this is the required defense-in-depth backstop): emit one warning line `phase <id>: computed dir segment "<candidateDir>" failed validation — falling back to bare phase-<id>` and use an **empty string** as the phase's `slug` field instead, so the CLI computes the bare `phase-<id>` form. Never pass `candidateDir` or the rejected `candidateSlug` itself to `mkdir`, the `roadmap-init` CLI call, or any Write/Edit tool call — only the empty-string fallback is used.

Collect the results into a `sanitizedPhases` working-memory list — each entry `{id, name, slug, goal, successCriteria, dependsOn, creates, needs, areas}` in that fixed key order.

**Derive the feature slug**

`phases:` frontmatter is only ever written by `/aimi:brainstorm`, and every brainstorm document carries a top-level `topic:` frontmatter key (already produced by the same five-step topic-slug algorithm — see brainstorm.md Phase 4 template). Read it as `featureSlug`. Validate it against `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` (the `--feature` pattern `aimi-cli.sh` enforces); on the rare mismatch, re-derive `featureSlug` by running the topic-slug algorithm on the raw `topic:` value. If it is still empty or invalid, skip the rest of this section with warning `roadmap materialization skipped — could not derive a valid feature slug`.

**Detect existing roadmap.json and materialize**

```bash
[ -f "$AIMI_ROOT/.aimi/tasks/$featureSlug/roadmap.json" ] && echo exists || echo absent
```

- **`exists`:** call `roadmap-init --sync` — the additive-sync path. Any phase id already present in the file is left byte-for-byte unchanged (status, claim, and branch fields untouched); any phase id present only in `sanitizedPhases` is appended, joining the ordering purely by numeric id (a decimal-inserted phase like `2.1` sorts between its numeric neighbors). This is also the correct call on a byte-for-byte unchanged re-run — `--sync` with zero new ids is a no-op for every existing phase. Never call `roadmap-init` without `--sync` when the file already exists — that path is a hard error by design, guarding against clobbering.

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI roadmap-init --feature "$featureSlug" --sync <<'PHASES_JSON'
  <sanitizedPhases as a JSON array>
  PHASES_JSON
  ```

- **`absent`:** call `roadmap-init` in creation mode, passing the brainstorm's own path (relative to `AIMI_ROOT`, no leading `./`, no `..` — the file read at the top of Phase 0) as `--brainstorm-path`. The CLI creates `.aimi/tasks/<feature-slug>/` itself as part of its locked write — no separate `mkdir` call is needed, and no Write tool call ever touches `roadmap.json`.

  `roadmap-init` still accepts `--integration-branch` (see `plugins/aimi-engineering/CLAUDE.md`), and this step deliberately does not pass it. The flag is a human affordance for materialising a feature onto a long-lived integration branch, in the same shape `roadmap-amend-phase` is a human affordance for correcting a phase; nothing in this plugin writes the value, and issue #87 direction 1 documents hand-editing `roadmap.json` as the supported route. Threading it from brainstorm frontmatter meant parsing a key no command emits and interpolating the result — LLM-authored text — into this very bash line through a model-substituted placeholder, with sanitization guaranteed only by the prose telling the model to sanitize. Removing the parse removes that, and costs nothing that ever worked.

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI roadmap-init --feature "$featureSlug" --brainstorm-path "<brainstorm relative path>" <<'PHASES_JSON'
  <sanitizedPhases as a JSON array>
  PHASES_JSON
  ```

In both branches, the JSON array piped via stdin is built directly from `sanitizedPhases` — one object per phase, key order `id, name, slug, goal, successCriteria, dependsOn, creates, needs, areas` — e.g.:

```json
[
  {"id": 1, "name": "Foundation", "slug": "foundation", "goal": "...", "successCriteria": ["..."], "dependsOn": [], "creates": [{"identity": "...", "description": "..."}], "needs": [], "areas": ["..."]},
  {"id": 2, "name": "Notifications", "slug": "notifications", "goal": "...", "successCriteria": ["..."], "dependsOn": [1], "creates": [], "needs": [{"identity": "...", "description": "..."}], "areas": ["..."]}
]
```

The quoted heredoc delimiter (`<<'PHASES_JSON'`) prevents shell expansion of the JSON body — defense in depth alongside the field sanitization above.

**If `roadmap-init` exits non-zero, first check whether the failure is one this command authored and can repair.** Exactly **two** stderr prefixes qualify, and both name the phase, the list and the entry's position per offending entry — every one of which came from `sanitizedPhases`, which this command composed and still holds in working memory:

- `Error: roadmap-init: malformed creates/needs entry` — the entry is not the `{identity, description}` object at all: a bare string (the pre-`2.0` `"identity (description)"` form), a non-string in either field, a missing `identity`, or an extra key, each named individually. Rebuild that entry as the two-key object, putting the artifact's name in `identity` and any prose in `description` (`""` when there is none, never `null`).
- `Error: roadmap-init: malformed creates/needs identity` — the entry is shaped correctly but its identity is one `verify-creates` could never resolve. The message quotes the identity exactly as submitted and gives every reason it failed.

Repair them in `sanitizedPhases` exactly as each reason directs — move the offending text out of the `identity` and into the `description`, drop a query string from an endpoint, reword a description that tripped an injection pattern, give a name to an identity that is only separators and glob metacharacters — then **re-run the same call once**. **Never repair by deleting the offending character from the identity**: that silently produces a name the phase will not deliver, which is the exact failure this contract exists to prevent. Rename the artifact, or move the text. If the retry also fails, fall through to the warn-and-continue path below; do not retry a second time.

Only those two stderr shapes are repaired here. Every other non-zero exit — a dangling `dependsOn` reference introduced by a hand-edited brainstorm, an id collision, an unwritable directory — is not something this command can fix from its own memory, and takes the unchanged path: surface the CLI's stderr as a single warning line and continue the rest of the plan pipeline. Do not abort the whole `/aimi:plan` run over a roadmap-materialization failure — the flat pipeline output is still valuable even when phase tracking could not be initialized this run.

**Say what was lost when the warning fires.** `ROADMAP_MODE` is computed further below from whether `roadmap.json` exists on disk, so a materialization failure silently downgrades a phased feature to a single flat tasks file. Whenever the warning path is taken for a feature that had more than one phase in `sanitizedPhases`, the warning line must say so explicitly — e.g. `roadmap not materialized: continuing as a single flat plan instead of [N] phases`. A user who asked for a phased rollout must never discover the downgrade only by noticing the output shape.

`featureSlug` and `sanitizedPhases` remain in working memory for the rest of this session. `featureSlug` is also the primary input to the Rolling-Wave Phase Selection step immediately below, which drives phase-scoped behavior across Phase 1 through Phase 4.
