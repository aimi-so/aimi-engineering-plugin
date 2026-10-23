# Plan: Phase 0: Rolling-Wave Phase Selection, roadmap mode detection

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Rolling-Wave Phase Selection

Only meaningful for phased features — but unlike Roadmap Materialization above, this step runs whether or not a brainstorm loaded **this** session. This is what lets a bare `/aimi:plan` (or `/aimi:plan --phase <N>`) re-invocation on an *existing* large-scope feature auto-select and expand exactly one pending phase per invocation ("rolling wave"), leaving every other phase outline-only in `roadmap.json`. When the feature has no roadmap at all, this entire section is a no-op and the rest of the pipeline runs byte-for-byte as it does today (see the flat-feature acceptance criterion for this story).

#### Resolve `featureSlug` and detect roadmap mode

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
CANDIDATE_SLUG=""
if [ -n "$featureSlug" ]; then
  # Roadmap Materialization above already derived and validated featureSlug
  # this session (a brainstorm with phases: frontmatter was loaded) — reuse it.
  CANDIDATE_SLUG="$featureSlug"
elif [ -n "$FEATURE_DESCRIPTION" ]; then
  # Derive via the same five-step topic-slug algorithm
  # (commands/references/topic-slug.md) Phase 1 uses for topicSlug — the only
  # way to identify an existing roadmap when this invocation did not reload
  # a brainstorm. Validate against ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ (the --feature
  # pattern aimi-cli.sh enforces); an invalid result is treated as empty.
  CANDIDATE_SLUG="<topic-slug algorithm applied to FEATURE_DESCRIPTION, validated>"
fi

if [ -n "$CANDIDATE_SLUG" ] && [ -f "$AIMI_ROOT/.aimi/tasks/$CANDIDATE_SLUG/roadmap.json" ]; then
  featureSlug="$CANDIDATE_SLUG"
  ROADMAP_MODE=true
else
  # ONE traversal. The count, the single match and the candidate slug list all
  # fall out of the same expansion, so no concurrent session can add or remove a
  # roadmap between counting and choosing, and a directory name carrying a space
  # or a newline survives intact instead of being re-split out of a second `ls`.
  ROADMAP_GLOB_COUNT=0
  ROADMAP_MATCH=""
  ROADMAP_CANDIDATE_SLUGS=""
  for ROADMAP_CANDIDATE in "$AIMI_ROOT"/.aimi/tasks/*/roadmap.json; do
    [ -f "$ROADMAP_CANDIDATE" ] || continue
    ROADMAP_GLOB_COUNT=$((ROADMAP_GLOB_COUNT + 1))
    ROADMAP_MATCH="$ROADMAP_CANDIDATE"
    ROADMAP_CANDIDATE_DIR=${ROADMAP_CANDIDATE%/roadmap.json}
    ROADMAP_CANDIDATE_SLUGS="$ROADMAP_CANDIDATE_SLUGS ${ROADMAP_CANDIDATE_DIR##*/}"
  done
  case "$ROADMAP_GLOB_COUNT" in
    0) ROADMAP_MODE=false ;;
    1)
      ROADMAP_ONLY_DIR=${ROADMAP_MATCH%/roadmap.json}
      ROADMAP_ONLY_SLUG=${ROADMAP_ONLY_DIR##*/}
      ROADMAP_ONLY_VERDICTS=$($AIMI_CLI roadmap-eligible --feature "$ROADMAP_ONLY_SLUG" --statuses pending)
      ROADMAP_PHASE_TOTAL=$(printf '%s' "$ROADMAP_ONLY_VERDICTS" | jq '.phases | length')
      ROADMAP_PHASE_DONE=$(printf '%s' "$ROADMAP_ONLY_VERDICTS" | jq '[.phases[] | select(.status == "completed" or .status == "cancelled")] | length')
      ROADMAP_PHASE_OPEN=$(printf '%s' "$ROADMAP_ONLY_VERDICTS" | jq '[.phases[] | select(.status != "completed" and .status != "cancelled")] | length')
      if [ "${ROADMAP_PHASE_OPEN:-0}" -gt 0 ]; then
        featureSlug="$ROADMAP_ONLY_SLUG"
        ROADMAP_MODE=true
        echo "[plan] rolling-wave: continuing feature '$featureSlug' (single roadmap.json found in .aimi/tasks/)"
      else
        ROADMAP_MODE=false
      fi
      ;;
    *) : ;; # multiple roadmaps — disambiguate below, do not guess
  esac
fi
```

**The single-roadmap arm adopts only a roadmap with work left in it.** One `roadmap.json` on disk is not evidence that it is the feature the person meant — it is only evidence that it is the one they happen to still have. The arm below it already refuses to guess between two roadmaps, on the ground that misfiling a phase's stories into the wrong feature's container is not a recoverable mistake; a count of exactly one does not make the same guess safe, it only makes it invisible. So the arm now asks the roadmap what state it is in before adopting it, and the predicate is **at least one phase whose `status` is neither `completed` nor `cancelled`** (`ROADMAP_PHASE_OPEN`).

That predicate deliberately admits a roadmap whose phases are all `in_progress` or all `planned`. Such a roadmap **is** the feature being continued, so adopting it is right; it then dead-ends at the zero-eligible report further down, which names every phase and why none of them can be expanded. That is the intended path and not an oversight — the alternative, refusing to adopt anything that is not `pending`, would decline the very feature the person is in the middle of.

The statuses come from `roadmap-eligible` rather than a fresh read of `roadmap.json`, so this command and `roadmap.py` cannot drift into two different readings of the same document. Only the `phases[].status` column is read here; the eligible list is not, which is why `--statuses pending` is immaterial on this call and is passed only to match the call further down. **This block therefore needs `python3`, which the detection step did not need before.** That costs nothing real: the very next block already shelled out to `roadmap.py` twice, so any session that reaches roadmap mode already paid for it. And when `python3` is missing the payload is empty, `ROADMAP_PHASE_OPEN` defaults to `0`, and the arm declines — strictly better than the old behavior, which adopted and then failed one block later.

The CLI also validates `--feature` against `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`, so a directory whose name could never have been a feature slug — the whitespace and newline cases the single traversal now counts correctly — is refused by name here and declined rather than silently adopted.

**When the arm declines** (`ROADMAP_MODE=false`, interactive): report one line, then continue as a flat plan. Compose it here from `ROADMAP_ONLY_SLUG`, `ROADMAP_PHASE_TOTAL` and `ROADMAP_PHASE_DONE`, in the reader's own language per the Adaptive Language Rule referenced below — never as a fixed English string:

```
[plan] rolling-wave: not continuing '[ROADMAP_ONLY_SLUG]' — all [ROADMAP_PHASE_DONE] of its [ROADMAP_PHASE_TOTAL] phases are completed or cancelled, so it has nothing left to expand. Planning this description as a flat feature instead.
To work on that roadmap on purpose, re-run /aimi:plan with a description that matches '[ROADMAP_ONLY_SLUG]', or with /aimi:plan --phase <N>.
```

Both escape hatches belong in that same message. A refusal that says only what did not happen leaves the reader with a roadmap they cannot reach; the two ways to reach it deliberately are a description that slugifies to the roadmap's own directory name (which takes the exact-match arm at the top of this block, where adoption is correct because the person named the feature), and an explicit `--phase <N>`.

**Agent mode (`INTERACTIVE_MODE=agent`) does not continue flat here — it STOPs the entire `/aimi:plan` invocation**, reporting the same composed line naming the feature and its phase counts. The reason is the zero-eligible branch further down in **Select the target phase**: that branch already forbids exactly this fall-through, because dropping into the flat pipeline silently creates an unrelated top-level `tasks.json` instead of expanding the roadmap. Interactively the log line is the safeguard — a person reads it and can re-run with a `--phase` target. In agent mode nobody reads it, so continuing flat would produce an unreviewed artifact that contradicts its own neighbour.

**Multiple roadmaps found** (`ROADMAP_GLOB_COUNT` > 1, and the exact-match fast path above did not resolve one): the candidates are the slugs the traversal already collected in `ROADMAP_CANDIDATE_SLUGS`. For each one, run `$AIMI_CLI roadmap-eligible --feature <slug>` and take three numbers off the payload — `.phases | length`, `[.phases[] | select(.status == "completed")] | length` and `[.phases[] | select(.status == "cancelled")] | length` — then offer them via **AskUserQuestion**:

```
Multiple large-scope features have an active roadmap. Which one is /aimi:plan continuing?
A — <featureSlug1> (<total> phases, <completed> completed[, <cancelled> cancelled])
B — <featureSlug2> (<total> phases, <completed> completed[, <cancelled> cancelled])
...
```

The `<cancelled> cancelled` clause is omitted whenever that roadmap's cancelled count is `0` — the same omitted-when-zero convention `metadata.baseRef`/`metadata.pluginVersion` already follow, so a roadmap with no cancelled phase renders exactly as it did before this count existed.

Set `featureSlug` to the chosen slug and `ROADMAP_MODE=true`.

**The counts replace the phase-name list this picker used to show, and that is the point of them.** Phase names describe what a feature is about, which the slug beside them already said; they cannot tell a roadmap with every phase finished apart from one with work left, so a `7 phases, 7 completed` roadmap rendered identically to an active one and the reader disambiguated blind. The counts are the one fact that separates them. Compose the option labels here, in the reader's own language, from those three numbers per the Adaptive Language Rule referenced below.

**Agent-mode fallback:** do NOT guess. Report `[plan] rolling-wave: ambiguous feature — N roadmaps found (<slug1>: <total> phases, <completed> completed[, <cancelled> cancelled]; <slug2>: <total> phases, <completed> completed[, <cancelled> cancelled]; ...); re-run with a feature description that matches one of them, or with an unambiguous --phase target once the feature is clear.` — again composed here rather than fixed in English, and again omitting the `<cancelled> cancelled` clause per-slug when that count is `0` — and STOP the entire `/aimi:plan` invocation. The counts belong on this line too: this branch renders no picker, so without them the caller least able to go look at the roadmaps itself is the one caller that would never see them. This is the only place in this section where agent-mode still requires a decision — silently picking the wrong feature's roadmap would misfile an entire phase's stories into the wrong container.

**`ROADMAP_MODE=false`:** skip the rest of this section entirely — no log line. Proceed to Implementation Scope Detection; the rest of the pipeline (Phase 1 through Phase 4.5) runs exactly as it does for a flat feature today.
