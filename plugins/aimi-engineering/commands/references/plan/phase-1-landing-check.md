# Plan: Phase 1: Confirm Each Research File Landed

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Confirm Each Research File Landed

An agent that fails says so. An agent that returns a well-formed pointer block and never writes its file says nothing at all — and its `outputPath` then travels into `metadata.researchPaths` and into every phase that reads it. Confirm on disk that each file you told a researcher to write actually landed.

**Timing — once per researcher, and only after that researcher's own Task has returned.** Run the check as each research Task comes back. Never run it while a Task is still in flight, and never once for the whole group: a researcher that has not returned has not finished writing, so an early check reads an absent file and warns about work that is still happening. This is not hypothetical — the neighbouring liveness cross-check was once hoisted into the middle of a wave and reported `stopped` for two agents that were working normally, and the next reader of a per-path predicate will want to run it early for the same reason.

**Predicate — the file exists AND `wc -c` reports at least 512 bytes.** Existence alone was rejected by measurement, not by taste: a researcher once left a 207-byte placeholder reading `PROBE - write-channel test in progress. This file will be overwritten with full findings.` at its `outputPath` for about three minutes, and a bare `[ -f ]` passes that file — so a consumer checking existence reads a stub that says nothing as a success. Measured over the nine files in `.aimi/research/` on this tree: smallest legitimate file 2483 bytes, largest 42600, and the stub 207. A floor of 512 sits about 2.5x above the stub and about 4.8x below the smallest real file, so neither edge is close.

Run this once per researcher, against the `outputPath` that researcher was handed:

```bash
RESEARCH_OUT="[the outputPath this researcher was handed]"
RESEARCH_BYTES=0
[ -f "$RESEARCH_OUT" ] && RESEARCH_BYTES=$(wc -c < "$RESEARCH_OUT" | tr -d '[:space:]')
if [ "${RESEARCH_BYTES:-0}" -lt 512 ]; then
  echo "warning: research file not written or below the 512-byte floor (${RESEARCH_BYTES} bytes) - dropping: $RESEARCH_OUT"
fi
```

**Accumulate `researchWritten`.** Keep a working-memory list named `researchWritten`. When the block above prints nothing, append that researcher's `outputPath` to `researchWritten` — the file landed and is above the floor. When the block prints its warning line, append nothing: that path is dropped here and must not reach any downstream list. `researchWritten` is the list both downstream research lists read — the `allResearchPaths` union computed before the research-conflict gate, and Phase 4's fresh-written source for `metadata.researchPaths` — so both key on the file being on disk rather than on "the agent returned".

**Then measure the evidence, for each path that reached `researchWritten`.** The 512-byte floor above proves a file LANDED; it says nothing about whether the findings in it carry any evidence at all. The three research agents' Structured Findings Format has required a ` ```measure ` block under every figure about this repository for five contract mentions, and a recursive grep for that fence across `.aimi/` returned ZERO files — the contract had never once been honoured, so a sixth mention produces the same zero. This measures the absence instead of restating the rule. It runs only for a path already in `researchWritten` (a clean landing, or a `recovered:` one) and never for a file this section just dropped: a stub is not worth measuring.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RESEARCH_OUT="[the outputPath this researcher was handed, already appended to researchWritten]"
FIGURES_JSON=$($AIMI_CLI research-figures "$RESEARCH_OUT" 2>/dev/null || printf '')
MEASURE_BLOCKS=$(printf '%s' "$FIGURES_JSON" | jq -r '.blocks // empty' 2>/dev/null)
BARE_FIGURES=$(printf '%s' "$FIGURES_JSON" | jq -r '.figures_outside // empty' 2>/dev/null)
DEAD_KEYS=$(printf '%s' "$FIGURES_JSON" | jq -r '(.dead_keys // []) | map("block \(.block) reads \(.key) against \(.subject)") | join("; ")' 2>/dev/null)
UNRECORDED=$(printf '%s' "$FIGURES_JSON" | jq -r '(.unrecorded // []) | map("block \(.block) line \(.line) `\(.command)`") | join("; ")' 2>/dev/null)
if [ "${MEASURE_BLOCKS:-1}" = 0 ] && [ "${BARE_FIGURES:-0}" -ge 10 ]; then
  echo "warning: research file carries no measure block - blocks=${MEASURE_BLOCKS}, figures_outside=${BARE_FIGURES}, so every figure in it is UNVERIFIED: $RESEARCH_OUT"
fi
if [ -n "${DEAD_KEYS:-}" ]; then
  echo "warning: a measure block indexes a name its own subject does not carry, so its figure is independent of the corpus - ${DEAD_KEYS}: $RESEARCH_OUT"
fi
if [ -n "${UNRECORDED:-}" ]; then
  echo "warning: a measure block records a command with no output, so its figure is UNVERIFIED - ${UNRECORDED}: $RESEARCH_OUT"
fi
```

**`${MEASURE_BLOCKS:-1}` defaults to a NON-zero on purpose.** A verb that could not answer — an older CLI that has no `research-figures`, a host with no `python3` behind the CLI, an unreadable path — leaves the variable empty, and a default of `0` would then print the warning for every file on such a host. Defaulting to 1 makes a CLI that failed print nothing at all, which is the honest answer: nothing was measured, so nothing is claimed.

**The threshold 10 is arbitrary, and it is a knob rather than a constant.** Nothing in the codebase, in the contract or in any measurement implies 10 over 8 or 15: the two research files measured on 2026-09-10 scored 130 and 196 bare figures against 0 blocks, and a synthetic violator scored 12, so 10 is a round number with margin on both sides. Retune it once real data arrives. It is also a FLOOR and not a ratio — the same 12 figures accompanied by ONE token block pass — and that is deliberate rather than an oversight: a ratio needs a calibration set of files that actually carry blocks, and this floor is what generates it.

**The `dead_keys` line answers a different question, and the three together still leave a fourth open.** `blocks` proves a block EXISTS. Phase 1.6's re-execution below proves it REPRODUCES. `dead_keys` proves its subject is ADDRESSED — it is what catches a figure produced by `x.get('output','')` over case objects that carry no `output` key, which returned its default for every input and was therefore independent of the corpus, and which re-execution had PASSED twice, because a wrong-but-deterministic command reproduces its own wrong output forever. None of the three proves the command answers the question the prose asks. That last step is human reading, and nothing here claims it.

**The measure-block warning never blocks**, and neither do the `dead_keys` and `unrecorded` ones (`unrecorded` names a block recording a command with no output under it). All three are advisory in the same way: no abort, no retry, no re-spawn of the researcher, no change to the command's exit status, and no path is dropped from `researchWritten` by any of them. They add at most three more lines per path to the at-most-two-lines-and-always-continues promise below, which they extend rather than replace. Their scope is this section's own — every researcher Task this run actually spawns, at both spawn sites (Phase 1's codebase and learnings researchers above, and Phase 1.5b's best-practices and framework-docs researchers below) — and never a path taken from `reusedResearch`, for which no Task was spawned this run and so nothing was promised to land.

**Recover before you drop.** This branch fires only when the block above printed its warning — the file did not land. Look at the same Task return's pointer block for an `unwritten_findings:` key before giving up on that researcher.

- **`unwritten_findings` present** — the agent still holds the findings it could not write. Persist that key's value verbatim, with the `Write` tool, to the `outputPath` this command handed that researcher — never to the path the return names, since `research_file` in the pointer block is agent-authored text and a return that could redirect a write could write anywhere. A bash heredoc is the wrong tool for this: the payload is agent-returned prose that may carry unbalanced quotes, backticks and `$(...)`, and these fences are executed literally, one per isolated shell, under zsh or bash — interpolating the payload into one would be exactly the quoting hazard this convention exists to avoid.
- **`unwritten_findings` absent** — no file and no payload offered. There is nothing left to recover: report the drop with its own distinguishable line and move on, inventing nothing.

Neither branch is a claim the return itself makes. The return never asserts success — this whole section measures the disk, and that measurement is already the status field, which is why the pointer block carries no separate success key of its own. A well-formed return with no `unwritten_findings` key looks identical in both cases above — file landed, or nothing to recover — and the disk check is what separates them.

Once the payload is written, confirm it landed the same way the predicate above did:

```bash
RESEARCH_OUT="[the outputPath this researcher was handed]"
RESEARCH_BYTES=0
[ -f "$RESEARCH_OUT" ] && RESEARCH_BYTES=$(wc -c < "$RESEARCH_OUT" | tr -d '[:space:]')
if [ "${RESEARCH_BYTES:-0}" -ge 512 ]; then
  echo "recovered: research payload persisted from the Task return (${RESEARCH_BYTES} bytes): $RESEARCH_OUT"
else
  echo "warning: recovered payload still below the 512-byte floor (${RESEARCH_BYTES} bytes) - dropping: $RESEARCH_OUT"
fi
```

On the `recovered:` line, append the path to `researchWritten` exactly as the predicate above does on a clean landing. On the `warning:` line, append nothing — a recovered payload that is itself under the floor is still dropped. This recovery only survives an untruncated return: the payload travels inside the Task return itself, and GitHub issue #153 records that a return was truncated twice in the very run that motivated this recovery — 2 of 8 sections never arrived, and a follow-up SendMessage carrying the missing findings was truncated too. Detecting a truncated return is issue #153 direction 3 and is deliberately out of scope here.

**The check never blocks.** It emits at most two lines per failing path — the original drop warning above, plus one branch-specific line reporting the recovery attempt or the missing payload — and always continues: no abort, no retry, no re-spawn of the researcher, no change to the command's exit status. This extends the `If any spawned agent fails, proceed with available results.` promise directly above rather than replacing it — an agent that fails loudly and an agent that returns without writing now leave the run in the same, visible state. A run whose files all land prints nothing new at all.

**Scope — every researcher Task this run actually spawns.** The check is not conditional on `ROADMAP_MODE`, on `researchDepth`, or on the host: it applies in flat mode and in phase mode alike, and to both spawn sites — Phase 1's codebase and learnings researchers above, and Phase 1.5b's best-practices and framework-docs researchers below.

Two exclusions are deliberate:

- **A path taken from `reusedResearch` is not checked here.** No Task was spawned for it this run, so there is nothing that was supposed to land. A reused path that has since vanished is caught downstream by Phase 1.7's Research File Ingestion, which names it in a warning of its own.
- **The Phase-Scoped Research Reuse glob is left exactly as it is.** A glob that finds no candidate is answering "nothing to reuse", which is a legitimate answer and not a missing deliverable; making it warn would print a line on every fresh run.
