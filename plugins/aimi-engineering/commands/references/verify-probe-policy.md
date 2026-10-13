# Verify-Probe Policy

States, once, whether a plan-time probe of `implementation.verify` may refuse a plan for a
non-discriminating segment or only report it, and the measurement that decides it. Artifacts
written under `.aimi/` follow `commands/references/user-communication.md`. The code reads the
decision from `PROBE_PLAN_NONDISCRIMINATING_POLICY` in `scripts/tasks.py` (it is the `policy` key
of `probe-plan`'s `probed: true` payload); nothing parses this file.

## Decision

Decision: report-only

False positives: 256 of 279

Of 279 unlabelled non-discriminating segments over phases 1-7, 256 were guard-rail in fact or an
instrument defect and 23 were vacuous. A refusal would have blocked 256 legitimate segments to
catch 23. `PROBE_PLAN_NONDISCRIMINATING_POLICY` is `"report"`. The operator confirmed the
decision at the story's gate; the measured rule below independently agrees with it.

## Measured Corpus

One tasks file per phase under `.aimi/tasks/spec-contract-and-honest-verification/phase-{1..7}-*/`,
each probed by `probe-plan` at its own `metadata.baseRef` (all seven resolve in this repository),
with full-suite segments skipped (the default). Suite segments are counted under Unmeasured and
never treated as clean. A tasks file with no usable baseRef is reported by `probe-plan` as
`probed:false` with a reason, the `notProbed` case, and is never counted as zero findings; all
seven here probed, so Not probed is 0 throughout.

Classes. (a) vacuous: passes because it asserts nothing about the work. (b) guard-rail in fact:
passes by design. (c) instrument defect: the probe's verdict is wrong for a reason in the defect
digest. Scaffolding (function definitions, assignments, `cd`, `trap`, `mkdir`, `echo`, `export`)
is not an assertion; one rule covers it: it is counted in (b) and also reported on its own below.
Segments were grouped by shape and each family read by hand; every plan predates segment labels
(`implementation.guardRails` did not exist), so every hit is unlabelled by construction.

| Phase | baseRef | Stories | Segments | Non-discriminating | Unmeasured | Not probed | (a) vacuous | (b) guard-rail | (c) defect |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | e26aa9d | 5 | 115 | 52 | 12 | 0 | 6 | 46 | 0 |
| 2 | e0baf7c | 7 | 65 | 13 | 19 | 0 | 4 | 9 | 0 |
| 3 | bb1575e | 7 | 81 | 13 | 19 | 0 | 3 | 10 | 0 |
| 4 | ce4aa1c | 5 | 50 | 22 | 14 | 0 | 2 | 8 | 12 |
| 5 | f655483 | 5 | 217 | 98 | 16 | 0 | 4 | 91 | 3 |
| 6 | 915fbad | 4 | 84 | 56 | 11 | 0 | 1 | 22 | 33 |
| 7 | 8ea3346 | 7 | 102 | 25 | 24 | 0 | 3 | 22 | 0 |

Totals: 40 stories, 714 segments, 279 non-discriminating, 115 unmeasured, 23 (a), 208 (b), 48 (c).
Of the 208 (b), 118 are scaffolding. The rest are syntax checks (`py_compile`, `bash -n`), absence
assertions, precondition anchors, recorded-equals-actual byte checks and size ceilings. The 23 (a)
are positive greps for text that already existed at baseRef.

```measure
$ for n in 1 2 3 4 5 6 7; do aimi-cli.sh probe-plan --tasks-file phase-$n-*/*-phase-$n-tasks.json | jq -c --argjson n $n '{phase: $n, baseRef: .baseRef[0:7], probed, policy, stories: (.stories|length), segments: ([.stories[].segments|length]|add), unlabelled: (.unlabelledNonDiscriminating|length), unmeasured: (.unmeasured|length)}'; done
{"phase":1,"baseRef":"e26aa9d","probed":true,"policy":"report","stories":5,"segments":115,"unlabelled":52,"unmeasured":12}
{"phase":2,"baseRef":"e0baf7c","probed":true,"policy":"report","stories":7,"segments":65,"unlabelled":13,"unmeasured":19}
{"phase":3,"baseRef":"bb1575e","probed":true,"policy":"report","stories":7,"segments":81,"unlabelled":13,"unmeasured":19}
{"phase":4,"baseRef":"ce4aa1c","probed":true,"policy":"report","stories":5,"segments":50,"unlabelled":22,"unmeasured":14}
{"phase":5,"baseRef":"f655483","probed":true,"policy":"report","stories":5,"segments":217,"unlabelled":98,"unmeasured":16}
{"phase":6,"baseRef":"915fbad","probed":true,"policy":"report","stories":4,"segments":84,"unlabelled":56,"unmeasured":11}
{"phase":7,"baseRef":"8ea3346","probed":true,"policy":"report","stories":7,"segments":102,"unlabelled":25,"unmeasured":24}
```

Cross-check. The executors' saved pre-run probes are `verify-probe-<tasks-stem>-US-NNN.json`
beside each tasks file (30 files, 40 stories exist; ten executors skipped the pre-run). They hold
261 `discriminates:false` segments; `probe-plan` found every one of the 206 that fall in
segments it measured (segment text compared per story) and 0 that the saved probes missed. The 52
only in the saved files are suite or tree-state segments: executors probed on a tree slightly past
baseRef, and `probe-plan` skipped suites. No agreement was lost, 52 extra came from the executors.

```measure
$ for n in 1 2 3 4 5 6 7; do echo -n "phase $n "; jq -sc '{files: length, falseSegments: ([.[][]|select(.discriminates==false)]|length)}' phase-$n-*/verify-probe-*-tasks-US-???.json; done
phase 1 {"files":4,"falseSegments":59}
phase 2 {"files":5,"falseSegments":10}
phase 3 {"files":6,"falseSegments":23}
phase 4 {"files":3,"falseSegments":24}
phase 5 {"files":5,"falseSegments":122}
phase 6 {"files":1,"falseSegments":2}
phase 7 {"files":6,"falseSegments":21}
```

## Instrument Defects

One family produced class (c): an accumulator-style verify, whose helper (`check`, `chk`, `v`)
ends in `FAIL=1` and so exits 0 whatever it measured. The probe reads the exit status, so the
helper erases its own verdict and every call reports `discriminates:false`; the final `$FAIL`
readout and `echo "ALL CHECKS PASSED"` do the same. These assertions measured correctly (the
pre-run exited 1); the probe could not see it. Labelling cannot escape this, since the author
cannot fix the probe.

| Case | Where | Segments | Defect digest |
| --- | --- | --- | --- |
| C1 | phase 4 US-004, `check "..." "$N"` calls | 12 | `known-gaps/2026-09-10-US-006-2026-09-10-correcao-3-secoes-155-tasks.md` |
| C2 | phase 5 US-002, US-003, US-005, `$FAIL` readouts and the closing echo | 3 | `known-gaps/2026-09-10-US-006-2026-09-10-correcao-3-secoes-155-tasks.md` |
| C3 | phase 6 US-004, `v` and `chk` calls, readouts | 33 | `known-gaps/2026-09-10-US-006-2026-09-10-correcao-3-secoes-155-tasks.md` |

Instrument defects found: 3

(Three cases, 48 segments.) Other digest entries (shell-state blindness, the pytest segment
scored failing) were resolved in the verb or surface as `discriminates:null`, never as a wrong
`false`, so they add no row.

```measure
$ aimi-cli.sh probe-plan --tasks-file phase-6-*/*-phase-6-tasks.json | jq '[.unlabelledNonDiscriminating[]|select(.segment|test("^v |chk |ALL CHECKS PASSED"))]|length'
33
$ aimi-cli.sh probe-plan --tasks-file phase-4-*/*-phase-4-tasks.json | jq '[.unlabelledNonDiscriminating[]|select(.id=="US-004" and (.segment|test("^check ")))]|length'
12
$ aimi-cli.sh probe-plan --tasks-file phase-5-*/*-phase-5-tasks.json | jq '[.unlabelledNonDiscriminating[]|select(.segment|test("FAIL\" = 0|ALL CHECKS PASSED"))]|length'
3
```

## Decision Rule

Refuse when: the measured instrument-defect count (c) is 0 and the false-positive count N is 0, or every false positive can be escaped by labelling the segment in `implementation.guardRails`

Measured: (c) = 48 and N = 256, and the 48 cannot be escaped by a label, so the rule does not
fire and the decision is report-only. The rule is applied to the numbers, not to preference.

## Agent Mode

Agent mode: report-only in both modes. Interactive and non-interactive runs print the
`unlabelledNonDiscriminating` list and never block, the same as `skills/story-executor/SKILL.md`
step 1.5, which is report-only and never blocks. A refusal would depart from that baseline and
needs the measurement above to justify it; under `report` there is nothing to demote, so no
`--agent-mode` flag changes the outcome.

## Revisit When

Revisit when: a re-measure over new phases, run as above, shows (c) = 0 and the share of segments carrying a `guardRails` label is at least 90 percent of the guard-rail class (b), so a refusal can always be escaped by labelling.

Re-measure with the first command in `## Measured Corpus`, then re-run the classification of the
unlabelled list by shape. Evidence against refusal today: 256 of 279 hits (92 percent) are not
vacuous, and the single defect family wrongly flags 48. Evidence for it: none yet, since only 23
hits (8 percent) are real. Fixing the accumulator blindness in the probe, or labelling, is the
route to a refusal; if a later measure meets both conditions above, set the constant to
`"refuse"` and change the `Decision:` line in the same commit.
