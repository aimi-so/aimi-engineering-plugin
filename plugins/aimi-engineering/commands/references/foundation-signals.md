# Foundation Signals

Shared reference for detecting greenfield repositories — an empty or
near-empty project with no established stack, structure, or conventions yet.
Apply the rules in this file wherever the caller says "scan for foundation
signals" or "check whether this repo is greenfield."

**Consumed by:** plan.md's Phase 1.9 (Greenfield Foundation Gate) consumes
both the greenfield (degree 1) and brownfield-sem-convencoes (degree 2)
classifications below. brainstorm.md's Phase 1.8 (Greenfield Foundation
Detection — Structural Signals only) remains a degree-1-only consumer.

## Keyword Signals

Scan the feature description for greenfield-intent phrases using
case-insensitive whole-word matching (regex word boundaries `\b`).

**Phrase list:** novo projeto, greenfield, from scratch, do zero, new project

| Bucket | Signals | Action |
|--------|---------|--------|
| **Detect** | Text contains at least one phrase from the list | Mark the text as greenfield-relevant |
| **Skip** | No phrase matches | Treat the text as non-greenfield for keyword-signal purposes |

## Structural Signals

Keyword matching is evaded by phrasing (a request can target a greenfield
repo without saying so — e.g. "add the first endpoint"). Structural signals
close that gap by inspecting the repository itself, not how the request is
worded. All three signals below are absence-based and evaluated at
`AIMI_ROOT`, not CWD.

**Manifest absence** — none of the following manifest files exist at
`AIMI_ROOT`:

| Manifest |
|---|
| `package.json` |
| `pyproject.toml` |
| `go.mod` |
| `Gemfile` |
| `Cargo.toml` |
| `composer.json` |
| `pom.xml` |
| `build.gradle` |
| `mix.exs` |

**Tracked source-file count** — fewer than 5 files tracked by git match the
source-extension regex:

```
git ls-files | grep -cE '\.(js|ts|jsx|tsx|py|rb|go|rs|java|kt|php|cs|c|cpp|h|swift|scala|ex|exs|vue|svelte)$'
```

When `AIMI_ROOT` has no git history (no `.git`), fall back to:

```
find . -type f -regex '.*\.\(js\|ts\|jsx\|tsx\|py\|rb\|go\|rs\|java\|kt\|php\|cs\|c\|cpp\|h\|swift\|scala\|ex\|exs\|vue\|svelte\)$' | wc -l
```

Both use the same fewer-than-5 threshold.

**Convention-file absence** — neither `CLAUDE.md` nor `AGENTS.md` exists at
`AIMI_ROOT`.

**Ancestor-manifest lookup (monorepo false-positive suppression):** before
accepting either a greenfield (degree 1) or a brownfield-sem-convencoes
(degree 2) classification, walk parent directories starting at `AIMI_ROOT`
up to the git toplevel (`git rev-parse --show-toplevel`) or 5 levels,
whichever comes first. If any ancestor directory contains one of the nine
manifests above, or a `CLAUDE.md`, the classification is disqualified — the
repo is a package inside an established monorepo, not a greenfield root. For
degree 2 specifically, this suppresses the monorepo-package false positive
where the root already carries a `CLAUDE.md` but a subfolder has 5+ tracked
source files and no local `CLAUDE.md`/`AGENTS.md` of its own — that subfolder
inherits the root's conventions and must not be misclassified as
brownfield-sem-convencoes.

**Second degree — brownfield-sem-convencoes:** a repo with 5 or more tracked
source files (or find-fallback matches) AND no `CLAUDE.md`/`AGENTS.md` at
`AIMI_ROOT` classifies as brownfield-sem-convencoes rather than greenfield —
established code with no captured conventions. plan.md's Phase 1.9 condition
(a) is this degree's consumer: it fires on this classification exactly as it
does on greenfield, filtered through the same (now dual-scoped)
ancestor-manifest lookup above, and sets working-memory `foundationMode` to
`brownfield` when this degree — rather than greenfield — is what held.

## How to Combine

Structural signals are authoritative: manifest absence, the tracked
source-file threshold, and convention-file absence — filtered through the
ancestor-manifest lookup — determine the classification regardless of what
the keyword scan finds. Keyword signals are additive only: they can flag a
plain-text feature description as greenfield-relevant before any repository
exists to inspect structurally, but they never override a structural
disqualification. Keywords alone, with structural signals absent or
disqualified, never trigger the gate.
