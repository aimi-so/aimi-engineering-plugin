"""Tests for scripts/roadmap.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE.

`golden_from_jq.json` was captured by running the jq implementations that used
to live in aimi-cli.sh over an adversarial corpus, at commit ea9f919, BEFORE
those implementations were deleted. It is the evidence that the port changed
nothing. It must never be regenerated from roadmap.py -- doing that would turn
it into a snapshot of whatever the code happens to do today, which is the exact
opposite of what it is for. If a test here goes red, either the port drifted or
a rule genuinely changed; in the second case the golden file changes in the same
commit as the rule, with the reason in the commit message.

The bash suite (test-aimi-cli-part3-roadmap-forge.sh) covers these verbs
end-to-end through the CLI. This suite covers the rules directly, at a
granularity that suite cannot reach and roughly five hundred times faster.
"""

import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import roadmap as R  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _handle:
    GOLDEN = json.load(_handle)


# ---------------------------------------------------------------------------
# The port is faithful: every sanitizer, every entry, against the jq original
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "entry,expected",
    list(zip(GOLDEN["corpus"], GOLDEN["sanitizers"])),
    ids=[repr(e)[:40] for e in GOLDEN["corpus"]],
)
def test_sanitizers_match_the_jq_they_replaced(entry, expected):
    assert R.rm_sanitize(entry, 2000) == expected["s"]
    assert R.rm_markers_only(entry, 500) == expected["m"]
    assert R.rm_sanitize_contract(entry, 2000) == expected["c"]
    assert R.cv_identity(entry) == expected["i"]
    assert R.cv_injection(entry) is expected["inj"]
    assert R.cv_suspicious(entry) is expected["sus"]


def _phases_from_corpus():
    """Rebuild the phases exactly as roadmap-init builds them before judging.

    __mk* carries the markers-only form and creates/needs the contract-sanitized
    form; _identity_reasons compares the two, so a test that skipped this step
    would never exercise the mutation rule at all.
    """
    phases = []
    for i, entry in enumerate(GOLDEN["corpus"]):
        phases.append(
            {
                "id": i + 1,
                "name": "P",
                "goal": "g",
                "slug": "p",
                "__mkCreates": [R.rm_markers_only(entry, 500)],
                "__mkNeeds": [R.rm_markers_only(entry, 500)],
                "creates": [R.rm_sanitize_contract(entry, 500)],
                "needs": [R.rm_sanitize_contract(entry, 500)],
                "areas": [R.rm_sanitize(entry, 500)],
            }
        )
    return phases


def test_judge_phases_matches_the_jq_it_replaced():
    assert R.judge_phases(_phases_from_corpus()) == GOLDEN["judge_lines"]


def test_the_golden_corpus_actually_exercises_the_judge():
    """Anti-vacuum: a corpus that produced no diagnostics would pass forever."""
    assert len(GOLDEN["judge_lines"]) >= 40
    reasons = " ".join(GOLDEN["judge_lines"])
    for fragment in (
        "contains whitespace",
        'begins with "/"',
        'contains a ".." path segment',
        "instruction-injection pattern",
        "shell metacharacter",
        "names nothing in particular",
        "not a usable scope hint",
    ):
        assert fragment in reasons, fragment + " is never exercised by the corpus"


def test_the_mutation_rule_is_unreachable_through_the_real_write_path():
    """Deliberately NOT in the anti-vacuum list above, and this is why.

    The mutation rule refuses an entry whose stored identity differs from the
    one submitted. It cannot fire through roadmap-init, because
    rm_sanitize_contract applies rm_markers_only -- the very function that
    produces the marker form -- to the identity half and nothing else. The two
    identities are therefore equal by construction, which is what the review
    found empirically (zero firings across ~366k entries) stated as its cause.

    The rule is kept rather than deleted because it is defence in depth against
    a FUTURE caller that sanitizes differently, and the test below proves it
    still fires for such a caller. When the schema splits the two fields the
    rule stops being expressible at all and goes with them.
    """
    for raw in ("parseList<T> (a helper)", "$(x) (y)", "a<b>c (d)", "`t` (d)"):
        marker = R.rm_markers_only(raw, 500)
        stored = R.rm_sanitize_contract(raw, 500)
        assert R.cv_identity(marker) == R.cv_identity(stored), raw


def test_the_mutation_rule_still_fires_for_a_caller_that_does_sanitize_differently():
    reasons = R._identity_reasons("parseList (a helper)", "parseList", "parseList<T> (a helper)")
    assert any("DIFFERENT identity" in r for r in reasons)
    assert any("parseList<T>" in r for r in reasons)


# ---------------------------------------------------------------------------
# The rules themselves, stated directly rather than through a golden blob
# ---------------------------------------------------------------------------


def test_identity_is_everything_before_the_first_paren_trimmed():
    assert R.cv_identity("parseList<T> (a generic helper)") == "parseList<T>"
    assert R.cv_identity("foo.rb") == "foo.rb"
    assert R.cv_identity("   (only a description)") == ""
    assert R.cv_identity("cmd_x (parses (a,b) pairs)") == "cmd_x"


def test_markers_only_never_deletes_content():
    """The whole reason the two sanitizers exist as a pair."""
    for identity in ("parseList<T>", "design-system:tokens", "db/migrations/*.sql"):
        assert R.rm_markers_only(identity, 500) == identity
    # ...while the full sanitizer does delete, which is right for prose.
    assert R.rm_sanitize("parseList<T>", 500) == "parseList"


def test_a_backticked_span_unwraps_rather_than_disappearing():
    """Deleting it destroyed the token a later phase greps for."""
    assert R.rm_markers_only("`cmd_foo`", 500) == "cmd_foo"
    assert R.rm_sanitize("a `x` b", 500) == "a x b"


def test_instruction_markers_are_anchored_by_position():
    """Both a wider and a narrower version of this rule were wrong. See
    scope-contexts.md § Two rulers."""
    for blocked in ("--system: do this", "### INSTRUCTIONS do this", "INSTRUCTIONS: do X"):
        assert R.cv_injection(blocked), blocked
    for ordinary in (
        "design-system:tokens",
        "ecosystem:pkg",
        "a-system:tokens",
        "docs/INSTRUCTIONS.md",
        "docs/instructions.md (setup instructions)",
    ):
        assert not R.cv_injection(ordinary), ordinary


# ---------------------------------------------------------------------------
# normalize-contracts
# ---------------------------------------------------------------------------


def test_normalize_is_idempotent_and_leaves_objects_alone():
    doc = {"roadmapVersion": "1.0", "phases": [{"creates": ["a (b)"], "needs": []}]}
    assert R.normalize_contracts(doc) == 1
    assert doc["phases"][0]["creates"] == [{"identity": "a", "description": "b"}]
    assert doc["roadmapVersion"] == "2.0"
    assert R.normalize_contracts(doc) == 0
    assert doc["phases"][0]["creates"] == [{"identity": "a", "description": "b"}]


def test_normalize_gives_an_empty_description_never_null():
    doc = {"phases": [{"creates": ["foo.rb"]}]}
    R.normalize_contracts(doc)
    assert doc["phases"][0]["creates"][0]["description"] == ""


def test_normalize_does_not_judge():
    """A prose identity the writer refuses migrates unchanged. Repairing it on
    the way past would silently change what a phase promises."""
    prose = "forge command surface in aimi-cli.sh (open/view/diff/edit PR)"
    doc = {"phases": [{"creates": [prose]}]}
    R.normalize_contracts(doc)
    assert doc["phases"][0]["creates"][0]["identity"] == "forge command surface in aimi-cli.sh"


def test_normalize_identity_equals_what_every_previous_reader_computed():
    """The migration's entire correctness argument, as an assertion."""
    for entry in GOLDEN["corpus"]:
        doc = {"phases": [{"creates": [entry]}]}
        R.normalize_contracts(doc)
        assert doc["phases"][0]["creates"][0]["identity"] == R.cv_identity(entry)


def test_the_one_way_loss_is_confined_to_the_description():
    """An entry not ending in ")" drops one unbalanced paren. Recorded, not
    fixed: nothing re-glues these, and the identity never sees it."""
    assert R.nc_description("a (b) c") == "b) c"
    assert R.nc_description("a (b) c)") == "b) c"
    assert R.cv_identity("a (b) c") == R.cv_identity("a (b) c)") == "a"


# ---------------------------------------------------------------------------
# roadmap-init
# ---------------------------------------------------------------------------
#
# The end-to-end behaviour of this verb is covered twice over: 52 black-box
# calls in test-aimi-cli-part3-roadmap-forge.sh, and golden_from_jq.json's
# init_cases, which recorded the jq's exit/stdout/stderr/file for 29 payloads
# before that jq was deleted. What the tests below add is the parts of the rule
# that are awkward to reach through a shell.

INIT_CASES = {c["label"]: c for c in GOLDEN["init_cases"]}


def test_the_one_case_the_port_deliberately_does_not_reproduce():
    """jq exited 5 on `dependsOn: "1"` with a raw engine error, and the message
    the code takes the trouble to write was unreachable: it lived in the same
    collected array as the per-entry check, and iterating a string aborts jq.

    There is no faithful port of a crash. The golden file records what jq did;
    this records what we do instead, so the deviation is stated in both places.
    """
    assert INIT_CASES["dependson-nao-array"]["exit"] == 5
    assert "Cannot iterate over string" in INIT_CASES["dependson-nao-array"]["stderr"]
    errors = R.init_validation_errors([{"id": 1, "name": "A", "goal": "g", "dependsOn": "1"}])
    assert errors == ["phase 1: dependsOn must be an array"]


def test_validation_errors_are_grouped_by_check_not_by_phase():
    """The order callers have been reading: every duplicate id, then every bad
    id, then every missing name, and so on."""
    errors = R.init_validation_errors(
        [{"id": 1, "goal": "g"}, {"id": 1, "name": "B"}]
    )
    assert errors == [
        "duplicate phase id: 1",
        "phase 1: name is required",
        "phase 1: goal is required",
    ]


@pytest.mark.parametrize(
    "raw,stored,expected_dir",
    [(2, 2, "phase-2-a"), (2.0, 2, "phase-2-a"), (2.1, 2.1, "phase-2.1-a"), (1e3, 1000, "phase-1000-a")],
)
def test_an_integral_float_id_is_stored_the_way_jq_rendered_it(raw, stored, expected_dir):
    """jq puts every number through a double and prints the shortest round-trip
    form, so 2.0 lands as 2. Python keeps int and float apart and would write
    2.0 -- and phases[].id genuinely accepts decimals, so this is a real path."""
    phases = R.init_sanitize(R.jq_numbers([{"id": raw, "name": "A", "goal": "g", "slug": "a"}]))
    assert phases[0]["id"] == stored
    assert phases[0]["dir"] == expected_dir


def test_the_deliberate_precision_divergence_is_left_alone():
    """jq renders this as 1e+19 because a double cannot hold it. Reproducing a
    precision loss would be indefensible; no test in the bash suite reaches it."""
    assert R.jq_numbers([10000000000000000001]) == [10000000000000000001]


def test_sort_survives_a_hand_seeded_phase_with_no_id():
    """roadmap.json is a file people edit. sort_by(.id) in jq tolerated a null
    id (nulls sort first); a bare Python sort would raise on the mixed list."""
    ids = [3, None, 1, "x", 2.5]
    assert sorted(ids, key=R.jq_sort_key) == [None, 1, 2.5, 3, "x"]


def test_markers_are_scratch_and_never_reach_disk():
    phases = R.init_sanitize([{"id": 1, "name": "A", "goal": "g", "creates": ["a.rb (x)"]}])
    assert "__mkCreates" in phases[0]
    assert "__mkCreates" not in R._without_markers(phases)[0]
    assert "__mkNeeds" not in R._without_markers(phases)[0]


def test_dangling_dependson_names_the_phase_and_the_missing_id():
    errors = R.dangling_errors([{"id": 1, "dependsOn": [99]}], [1])
    assert errors == ["phase 1: dependsOn references unknown phase id 99"]


def test_the_identity_note_survived_the_move_with_its_example_intact():
    """This note used to be three copies of an `echo "..."` whose illustrative
    example was itself a backticked span -- so every refusal forked a lookup for
    a command named `x` and printed the sentence with the example missing.

    In a Python string literal a backtick is inert, so that failure mode is gone
    by construction. What still has to hold is that the example is there at all:
    a note about how backticks are handled is worthless without one.
    """
    assert "`x` span becomes x" in R.IDENTITY_NOTE
    assert R.IDENTITY_NOTE.startswith("Note: an entry is quoted after backtick normalization")


# ---------------------------------------------------------------------------
# roadmap-amend-phase
# ---------------------------------------------------------------------------

AMEND_CASES = {c["label"]: c for c in GOLDEN["amend_cases"]}


def test_every_refusal_in_the_capture_left_the_file_alone():
    """32 of the 41 captured cases refuse. Not one of them wrote. This is the
    property the verb's own comment claims and the one a port is most likely to
    break, because it depends on every check running before the write."""
    refusals = [c for c in AMEND_CASES.values() if c["exit"] != 0]
    assert len(refusals) >= 30
    assert all(c["unchanged"] for c in refusals)


def test_the_amended_field_no_longer_leaks_the_scratch_keys():
    """The SECOND place where this code deliberately differs from the golden.

    The jq reported `.amended` as the payload's raw key list, so amending
    creates returned ["__mkCreates","creates"] -- the marker forms the identity
    guard consumes, which are scratch and never schema. The port reproduced it
    faithfully so that commit's zero delta kept meaning "nothing changed"; this
    is the separate fix, and the golden below is left showing the old output
    because it records what jq did, not what we do.

    The first such divergence is dependson-nao-array (see the init section):
    there, jq crashed with exit 5 and the message the code writes was
    unreachable. Both are named on both sides rather than discovered later.
    """
    assert AMEND_CASES["retarget-ok"]["stdout"].count("__mkCreates") == 1, "the golden is history"
    for label in ("retarget-ok", "handoff-avisa"):
        assert "__mk" in AMEND_CASES[label]["stdout"]
    # And what the code does now: only amendable keys, by intersection.
    patch = {"creates": [], "__mkCreates": [], "needs": [], "__mkNeeds": [], "goal": "g"}
    assert sorted(k for k in patch if k in R.AMENDABLE_KEYS) == ["creates", "goal", "needs"]


def test_the_scratch_keys_never_reached_disk_in_any_captured_case():
    """The property that was always true and that the fix must not break: the
    leak was in the report, never in roadmap.json. 70 captured cases across both
    writers, zero occurrences on disk."""
    cases = GOLDEN["init_cases"] + GOLDEN["amend_cases"]
    assert len(cases) == 70
    assert not [c for c in cases if "__mk" in json.dumps(c.get("file"))]


def test_the_orphan_suggestion_guesses_only_when_there_is_nothing_to_guess():
    """The set difference proves an identity was dropped but never which new one
    replaced it. With exactly one added identity the pairing is complete; with
    two, the new side stays a placeholder rather than a guess."""
    assert 'shared_widget=renamed_widget' in AMEND_CASES["orfao-um-added"]["stderr"]
    assert 'shared_widget=<new identity>' in AMEND_CASES["orfao-dois-added"]["stderr"]


def test_retarget_matches_by_exact_equality_never_by_containment():
    """Phase 2 needs both "shared_widget" and "shared". Retargeting the first
    must not touch the second -- this repository's own roadmap has phases citing
    overlapping identities verbatim, and a substring rule would corrupt both."""
    needs = AMEND_CASES["retarget-ok"]["file"]["phases"][1]["needs"]
    assert needs == ["renamed_widget (renomeado)", "shared (a shorter one)"]


def test_the_orphan_guard_still_fires():
    """The regression that worries me most: a guard that stops guarding is
    silent. Reproduced here against the captured baseline."""
    stored = {"id": 1, "creates": ["shared_widget (the widget)"]}
    amended = {"id": 1, "creates": ["renamed_widget (r)"]}
    doc = {"phases": [stored, {"id": 2, "needs": ["shared_widget (the widget)"]}]}
    assert R.amend_orphan_rows(stored, amended, doc, []) == [(2, "shared_widget")]
    # ...and an authorized drop is not an orphan.
    assert R.amend_orphan_rows(stored, amended, doc, ["shared_widget"]) == []


def test_unamendable_keys_are_redirected_to_their_owner_by_name():
    assert R.amend_key_errors({"status": 1}) == [
        '  "status" is not amendable -- phase status is owned by roadmap-set-status'
    ]
    assert R.amend_key_errors({"claim": 1}) == [
        '  "claim" is not amendable -- phase claims are owned by roadmap-claim / roadmap-release-claim'
    ]
    assert R.amend_key_errors({"id": 1}) == [
        '  "id" is not amendable -- it is phase identity, written once by roadmap-init'
    ]
    assert R.amend_key_errors({"goal": "g", "creates": []}) == []


def test_the_v1_string_filter_is_named_so_the_schema_commit_can_find_it():
    """Thirteen call sites, one helper. Today it discards nothing -- in 1.0
    every entry IS a string -- and after the schema change it must be gone, or a
    malformed entry vanishes instead of raising."""
    assert R._v1_string_entries(["a", "b"]) == ["a", "b"]
    assert R._v1_string_entries([{"identity": "a"}, "b"]) == ["b"]
    source = open(os.path.join(SCRIPTS, "roadmap.py"), encoding="utf-8").read()
    assert source.count("_v1_string_entries") >= 4
    assert "DELETED IN THE SCHEMA COMMIT" in source


# --- the handoff advisory, which had no test at all until now --------------


def test_handoff_advisory_reads_only_the_artifacts_created_section(tmp_path):
    handoff = tmp_path / "handoff.md"
    handoff.write_text(
        "# Phase\n"
        "## Decisions\n"
        "- decided_thing was considered\n"
        "## Artifacts Created\n"
        "- real_thing -- built\n"
        "## Deferred\n"
        "- deferred_thing\n",
        encoding="utf-8",
    )
    assert R.handoff_lists_artifact(str(handoff), "real_thing")
    # A name that appears only OUTSIDE the section does not count as delivered:
    # that is the whole reason the section is scoped rather than grepped whole.
    assert not R.handoff_lists_artifact(str(handoff), "decided_thing")
    assert not R.handoff_lists_artifact(str(handoff), "deferred_thing")
    assert not R.handoff_lists_artifact(str(handoff), "never_mentioned")


def test_handoff_advisory_is_silent_when_the_file_is_missing(tmp_path):
    assert not R.handoff_lists_artifact(str(tmp_path / "nope.md"), "anything")


def test_handoff_advisory_fired_and_stayed_silent_in_the_capture():
    assert "does not list \"novo_artefato\"" in AMEND_CASES["handoff-avisa"]["stderr"]
    assert AMEND_CASES["handoff-avisa"]["exit"] == 0, "advisory never gates the amend"
    assert AMEND_CASES["handoff-silencia"]["stderr"] == ""
    assert AMEND_CASES["handoff-ausente"]["stderr"] == ""


# ---------------------------------------------------------------------------
# verify-creates
# ---------------------------------------------------------------------------

VERIFY_CASES = {c["label"]: c for c in GOLDEN["verify_cases"]}


def _verdicts(label):
    return VERIFY_CASES[label]["stdout"]


def test_every_documented_identity_kind_verifies():
    """scope-contexts.md declares these kinds legal. If one of them stopped
    verifying, phases would fail their own gate for declaring what they were
    told to declare."""
    for label, method in [
        ("kind-file", "path"),
        ("kind-dir", "path"),
        ("kind-path-glob", "path"),
        ("kind-symbol", "text"),
        ("kind-table", "text"),
        ("kind-endpoint", "text"),
        ("kind-namespaced", "text"),
    ]:
        v = _verdicts(label)[0]
        assert v["status"] == "verified", label
        assert v["method"] == method, label


def test_git_exit_status_separates_absent_from_unreadable():
    """gitStatus is the highest code any git call returned. 1 is a legitimate
    no-match and stays "missing"; above 1 is tool failure and becomes "error".
    Confusing the two would report an unreadable repository as a phase that
    built nothing."""
    assert _verdicts("ausente")[0]["status"] == "missing"
    assert _verdicts("ausente")[0]["gitStatus"] == 1
    assert _verdicts("kind-file")[0]["gitStatus"] == 0
    # And the ladder itself, exercised directly.
    assert R._verdict("x", "error", "", "e", 128)["method"] is None


def test_prose_and_tests_do_not_count_as_delivery():
    """The whole point of the exclusion list: a name mentioned only in docs or
    only in a test file is not an artifact. The evidence says which."""
    doc = _verdicts("so-em-doc")[0]
    assert doc["status"] == "missing"
    assert "documentation or test path" in doc["evidence"]
    assert _verdicts("so-em-teste")[0]["status"] == "missing"
    # ...unless the identity names the documentation itself.
    assert _verdicts("identidade-doc")[0]["status"] == "verified"


def test_a_todo_marker_is_never_the_work_being_done():
    v = _verdicts("marcador-todo")[0]
    assert v["status"] == "missing"
    assert "TODO/FIXME marker comment, not an implementation" in v["evidence"]


def test_marker_line_recognises_the_comment_syntaxes_it_claims():
    for line in ("// TODO: x", "# FIXME x", "-- XXX x", " * HACK x", "<!-- TODO x"):
        assert R.is_marker_line(line), line
    # A line that merely contains the word is not a marker comment.
    assert not R.is_marker_line("const TODO_COUNT = 3")
    assert not R.is_marker_line("// TODOS is a different word")


def test_the_endpoint_strip_is_exactly_one_space_then_slash():
    """verify-creates strips a leading method token so the search hits the route
    real code writes. Two spaces is not that shape -- and the writer refuses it
    for the same reason, so the two halves agree."""
    assert _verdicts("kind-endpoint")[0]["status"] == "verified"
    assert '(searched "/api/notifications")' in _verdicts("kind-endpoint")[0]["evidence"]
    assert _verdicts("endpoint-2-barras")[0]["status"] == "missing"


def test_pathspec_magic_cannot_verify_a_phase_that_built_nothing():
    """':(glob)' is the gate. Without it, `ls-files -- '*'` returned every
    tracked file and any of these would have verified by PATH."""
    for label in ("glob-estrela", "glob-exclude"):
        assert _verdicts(label)[0]["method"] != "path", label
    # The honest residue, recorded rather than papered over: a bare ":" still
    # verifies by TEXT, because `git grep -F ':'` finds a colon in any source
    # file. That is closed at WRITE time -- an identity must carry an
    # alphanumeric -- not here. Do not "fix" the reader for it.
    assert _verdicts("glob-doispontos")[0]["status"] == "verified"
    assert _verdicts("glob-doispontos")[0]["method"] == "text"


def test_one_verdict_per_declared_identity_in_declaration_order():
    """Anti-vacuum: the invariant test depends on this array lining up with the
    declared list, and an empty array would pass a length check that never ran."""
    assert [v["identity"] for v in _verdicts("varias")] == [
        "src/parse.ts",
        "notifications",
        "never_written",
    ]
    assert _verdicts("creates-vazio") == []


# ---------------------------------------------------------------------------
# validate-contracts
# ---------------------------------------------------------------------------

VALIDATE_CASES = {c["label"]: c for c in GOLDEN["validate_cases"]}


def _reasons(label):
    return [m["reason"] for m in (VALIDATE_CASES[label]["stdout"] or {}).get("missing", [])]


def test_a_need_resolves_through_the_transitive_closure():
    """Phase 3 depends on 2 depends on 1, and phase 3 needs what phase 1 built.
    Direct-dependency-only resolution would call that unmet."""
    assert VALIDATE_CASES["phase-3-entregue"]["exit"] == 0
    assert "base.rb" in VALIDATE_CASES["phase-3-entregue"]["stdout"]["providers"]


def test_a_provider_outside_the_closure_is_no_provider_not_a_resolution():
    """Phase 4 needs mid.rb, which phase 2 declares -- but phase 4 depends on
    nothing. Declaring a need on a phase you do not depend on is a scheduling
    error, and calling it resolved would hide it until execution."""
    assert _reasons("phase-4-fora-do-fecho") == ["no-provider"]
    assert VALIDATE_CASES["phase-4-fora-do-fecho"]["stdout"]["providers"] == {}


def test_the_two_missing_reasons_are_not_interchangeable():
    """no-provider means nobody promises it. not-delivered means somebody
    promised and the handoff does not show it. Collapsing them would point the
    reader at the wrong phase."""
    assert _reasons("phase-5-sem-provedor") == ["no-provider"]
    assert _reasons("phase-3-nao-entregue") == ["not-delivered"]


def test_the_delivery_gate_only_exists_when_phase_is_given():
    """Same roadmap, provider in_progress: scoped says not-delivered, unscoped
    resolves. The gate is about one phase's execution readiness, not about
    whether the contract graph is coherent."""
    assert "not-delivered" in _reasons("provedor-pendente-escopado")
    unscoped = VALIDATE_CASES["provedor-pendente-sem-escopo"]["stdout"]
    assert "mid.rb" in unscoped["providers"]
    assert "not-delivered" not in [m["reason"] for m in unscoped["missing"]]


def test_delivery_requires_the_artifacts_created_section_specifically():
    """A completed provider whose handoff mentions the identity under Decisions
    or Deferred has not delivered it. Grepping the whole file would pass."""
    assert _reasons("handoff-fora-da-secao") == ["not-delivered"]
    assert _reasons("handoff-ausente") == ["not-delivered"]


def test_duplicates_block_by_default_and_warn_under_agent_mode():
    """Same finding, two shapes: --agent-mode demotes it to a warning AND adds
    duplicateWarnings to the report. It is the only check --agent-mode demotes."""
    blocked = VALIDATE_CASES["duplicata-bloqueia"]
    assert blocked["exit"] == 1 and blocked["stdout"] is None
    assert "Error: validate-contracts: duplicate creates:" in blocked["stderr"]
    warned = VALIDATE_CASES["duplicata-agent-mode"]
    assert "Warning: validate-contracts: duplicate creates" in warned["stderr"]
    assert warned["stdout"]["duplicateWarnings"][0]["identity"] == "base.rb"
    assert "duplicateWarnings" not in (
        VALIDATE_CASES["phase-2-entregue"]["stdout"] or {}
    ), "the key appears only when there IS a duplicate and --agent-mode"


def test_the_sanitization_pass_names_the_entry_and_the_reason():
    """Two distinct reasons, and the anti-vacuum check that both are reached."""
    meta = VALIDATE_CASES["suspeita-metacaractere"]["stderr"]
    assert "shell metacharacter" in meta and "entry #1" in meta
    inject = VALIDATE_CASES["suspeita-injecao"]["stderr"]
    assert "instruction-injection pattern" in inject
    for case in ("suspeita-metacaractere", "suspeita-injecao"):
        assert VALIDATE_CASES[case]["exit"] == 1
        assert "never demoted" not in VALIDATE_CASES[case]["stderr"]


def test_reachable_ids_reaches_a_fixed_point_and_drops_the_start():
    doc = {"phases": [{"id": 1, "dependsOn": []}, {"id": 2, "dependsOn": [1]},
                      {"id": 3, "dependsOn": [2]}, {"id": 4, "dependsOn": []}]}
    assert R.reachable_ids(doc, 3) == [1, 2]
    assert R.reachable_ids(doc, 1) == []
    assert R.reachable_ids(doc, 4) == []


def test_reachable_ids_terminates_on_a_dependency_cycle():
    """roadmap.json is a file people edit, and roadmap-init's dangling check does
    not reject a cycle. Without the fixed-point test this loops forever."""
    doc = {"phases": [{"id": 1, "dependsOn": [2]}, {"id": 2, "dependsOn": [1]}]}
    assert R.reachable_ids(doc, 1) == [2]


def test_the_first_provider_by_phase_id_wins():
    """Deterministic rather than incidental: creates_in_scope orders by phase id
    and the lookup takes the first match."""
    doc = {"phases": [
        {"id": 3, "dependsOn": [], "status": "completed", "dir": "d3", "creates": ["x (late)"]},
        {"id": 1, "dependsOn": [], "status": "pending", "dir": "d1", "creates": ["x (early)"]},
    ]}
    rows = R.creates_in_scope(doc, [1, 3])
    assert [r[0] for r in rows] == [1, 3]


# ---------------------------------------------------------------------------
# roadmap-sweep
# ---------------------------------------------------------------------------

SWEEP_CASES = {c["label"]: c for c in GOLDEN["sweep_cases"]}


def _sweep(label):
    return SWEEP_CASES[label]["stdout"]


def test_an_orphan_creates_is_one_no_phase_needs():
    """The signal is "declared and never consumed", not "declared". base.rb is
    cited downstream and stays out of the report; extra.rb is not."""
    assert _sweep("orfao")["orphanCreates"] == [{"phase": 1, "creates": "extra.rb"}]
    assert _sweep("limpo")["orphanCreates"] == []


def test_a_deferred_need_names_the_provider_that_has_not_finished():
    assert _sweep("provedor-pendente")["deferredNeeds"] == [
        {"phase": 2, "need": "base.rb", "deferred": 1}
    ]
    assert _sweep("limpo")["deferredNeeds"] == [], "a completed provider is not deferred"


def test_a_need_nobody_declares_is_not_deferred():
    """deferredNeeds means "somebody will build it, later". A need with no
    provider at all is validate-contracts' no-provider, and reporting it here
    would point the reader at a phase that does not exist."""
    assert _sweep("needs-sem-provedor") == {
        "orphanCreates": [],
        "deferredNeeds": [],
        "warnings": [],
    }


def test_the_lowest_phase_id_is_the_provider_that_gets_named():
    """Two phases declare dup.rb; phase 1 is the one reported, whatever order
    they sit in the document."""
    assert _sweep("dois-provedores")["deferredNeeds"] == [
        {"phase": 2, "need": "dup.rb", "deferred": 1}
    ]


def test_a_suspicious_entry_is_dropped_and_the_drop_is_reported():
    """The drop must not be silent: phase 2 needs exactly what phase 1's dropped
    creates declared, and without the warning that need would simply vanish from
    the report with nothing saying why."""
    case = _sweep("drop-reportado")
    assert case["orphanCreates"] == [] and case["deferredNeeds"] == []
    assert [(w["phase"], w["field"]) for w in case["warnings"]] == [(1, "creates"), (2, "needs")]
    assert all(w["message"] == R.SWEEP_DROP_MESSAGE for w in case["warnings"])


def test_dropped_positions_are_counted_against_the_stored_list():
    """entry #2 of phase 1's creates, not entry #1 of the suspicious ones."""
    warning = _sweep("suspeito-creates")["warnings"][0]
    assert warning["droppedCount"] == 1 and warning["droppedIndexes"] == [2]
    assert _sweep("suspeito-creates")["orphanCreates"] == [{"phase": 1, "creates": "ok.rb"}]


def test_warnings_are_sorted_by_phase_then_field():
    """jq's unique_by([.phase,.field]) never deduplicated anything here -- the
    pairs are unique by construction -- so the sort was its whole effect, and a
    document whose phases are out of order proves it."""
    assert [(w["phase"], w["field"]) for w in _sweep("warnings-ordenados")["warnings"]] == [
        (1, "creates"),
        (2, "needs"),
        (3, "creates"),
    ]
    assert [(w["phase"], w["field"]) for w in _sweep("suspeito-dois-campos")["warnings"]] == [
        (1, "creates"),
        (1, "needs"),
    ]


def test_a_phase_id_is_reported_the_way_jq_rendered_it():
    """Phase 3.0 comes back as 3 and phase 2.1 stays 2.1. Without jq_numbers the
    first would print as 3.0 and no caller matching on the id would find it."""
    assert _sweep("ids-decimais")["deferredNeeds"] == [
        {"phase": 3, "need": "a.rb", "deferred": 2.1}
    ]


def test_the_sweep_divergence_is_the_schema_filter_and_nothing_else():
    """THE ONE PLACE THIS PORT DELIBERATELY DIFFERS FROM THE GOLDEN.

    An entry that is not a string is outside the 1.0 schema. jq could not match
    it and aborted the whole sweep (exit 5, its own error text); the Python reads
    those lists through _v1_string_entries, which drops the entry and reports a
    clean roadmap. That silent drop is precisely the hazard that helper's
    docstring names, and deleting it is the schema story's job -- at which point
    entry["identity"] raises and this case becomes loud again.
    """
    for label in ("creates-nao-string", "creates-objeto"):
        assert SWEEP_CASES[label]["exit"] == 5, "the golden is history, not a target"
        assert "not a string" in SWEEP_CASES[label]["stderr"]
    source = open(os.path.join(SCRIPTS, "roadmap.py"), encoding="utf-8").read()
    assert "_v1_string_entries_numbered" in source


def test_the_numbered_filter_keeps_positions_from_the_stored_list():
    assert R._v1_string_entries_numbered(["a", {"identity": "b"}, "c"]) == [(1, "a"), (3, "c")]
    assert R._v1_string_entries(["a", {"identity": "b"}, "c"]) == ["a", "c"]


# ---------------------------------------------------------------------------
# roadmap-write-handoff
# ---------------------------------------------------------------------------

HANDOFF_CASES = {c["label"]: c for c in GOLDEN["handoff_cases"]}

HANDOFF_HEADINGS = [
    "## Decisions Made",
    "## Artifacts Created",
    "## Deviations",
    "## Deferred Items",
    "## Contracts Delivered",
]


def test_the_five_headings_are_always_all_five_in_the_fixed_order():
    """roadmap-set-status's completed precondition and handoff_lists_artifact's
    section lookup both key on this shape, so an empty phase still renders it."""
    for label in ("pleno", "vazio", "campos-null", "campos-false"):
        body = HANDOFF_CASES[label]["file"]
        assert [line for line in body.split("\n") if line.startswith("## ")] == HANDOFF_HEADINGS
    assert HANDOFF_CASES["vazio"]["file"].count("_None._") == 5


def test_a_declared_identity_survives_the_render_byte_for_byte():
    """The defect this rule closes: the prose sanitizer deletes an HTML-looking
    tag, so "parseList<T>" landed in handoff.md as "parseList" and
    validate-contracts reported that need not-delivered forever."""
    body = HANDOFF_CASES["identidade-verbatim"]["file"]
    assert "- parseList<T> (um helper generico) — src/p.ts" in body
    assert "- parseList<T> (um helper generico) entregue" in body


def test_a_line_matching_no_declared_identity_is_ordinary_prose():
    """The exemption is for the identity at the head of the line, not for the
    delivery lists as a whole -- "<coisa>" in an unclaimed line still goes."""
    assert "- outra  qualquer" in HANDOFF_CASES["linha-sem-identidade"]["file"]
    assert "- qualquer  linha" in HANDOFF_CASES["identidade-vazia"]["file"]


def test_the_longest_declared_identity_wins():
    """A phase declaring both "alpha" and "alphabet" must keep the longer one
    whole; taking the first match would rewrite alphabet<X> into alpha."""
    body = HANDOFF_CASES["prefixo-mais-longo"]["file"]
    assert "- alphabet<X> (longo) — feito" in body and "- alpha (curto) — feito" in body


def test_the_cap_applies_to_the_spliced_line_as_well_as_to_the_prose():
    for label in ("cap-2000-com-identidade", "cap-2000-sem-identidade"):
        bullets = [l for l in HANDOFF_CASES[label]["file"].split("\n") if l.startswith("- ")]
        assert len(bullets[0]) - len("- ") == 2000


def test_null_and_false_fields_mean_no_entries_rather_than_a_refusal():
    """`(.[$k] // [])` treats both as absent. A caller that sends
    "artifacts": null is saying "none", not sending a malformed payload."""
    for label in ("campos-null", "campos-false"):
        assert HANDOFF_CASES[label]["exit"] == 0
    assert R.handoff_field({"a": None}, "a") == []
    assert R.handoff_field({"a": False}, "a") == []
    assert R.handoff_field({}, "a") == []


def test_every_field_refusal_names_its_field_and_writes_nothing():
    expected = {
        "decisions-string": "decisions",
        "artifacts-numero": "artifacts",
        "contracts-objeto": "contracts",
        "deviations-item-nao-string": "deviations",
        "deferred-item-null": "deferred",
        "dois-campos-ruins": "decisions",
    }
    for label, field in expected.items():
        case = HANDOFF_CASES[label]
        assert case["exit"] == 1 and case["file"] is None
        assert "field '" + field + "' must be an array of strings" in case["stderr"]


def test_the_fields_are_checked_in_a_fixed_order():
    """dois-campos-ruins carries a bad decisions AND a bad artifacts and reports
    decisions, so a caller fixing them one at a time walks a stable order."""
    assert R.handoff_field_error({"decisions": "x", "artifacts": 5}) == "decisions"
    assert R.handoff_field_error({"artifacts": 5}) == "artifacts"
    assert R.handoff_field_error({"decisions": ["ok"]}) is None


def test_a_malformed_payload_is_refused_before_anything_is_written():
    for label in ("payload-array", "payload-string", "payload-invalido"):
        case = HANDOFF_CASES[label]
        assert case["exit"] == 1 and case["file"] is None
        assert "payload must be a JSON object" in case["stderr"]


def test_an_empty_payload_still_writes_the_file():
    """Zero jq inputs meant zero outputs and an empty body, and the file it left
    behind satisfies roadmap-set-status's completed precondition, which only
    checks existence. Refusing here would change which phases can complete."""
    assert HANDOFF_CASES["payload-vazio"]["exit"] == 0
    assert HANDOFF_CASES["payload-vazio"]["file"] == "\n"


def test_the_tripwire_never_fired_in_the_capture():
    """It is not a check on today's renderer -- with that renderer it cannot
    fire. It is the guard that notices if a future sanitizer edit reopens the
    defect, so its value here is precisely that it stayed silent."""
    for case in GOLDEN["handoff_cases"]:
        assert "lost a declared identity" not in case["stderr"]


def test_the_tripwire_fires_for_a_body_that_lost_a_claimed_identity():
    payload = {"artifacts": ["parseList<T> — src/p.ts"], "contracts": []}
    assert R.handoff_lost_identities(payload, ["parseList<T>"], "- parseList — src/p.ts") == [
        "parseList<T>"
    ]
    assert R.handoff_lost_identities(payload, ["parseList<T>"], "- parseList<T> — src/p.ts") == []


def test_the_tripwire_ignores_an_identity_no_line_claimed():
    """A phase reporting fewer artifacts than it declared is a legitimate partial
    delivery, not a lost identity."""
    assert R.handoff_lost_identities({"artifacts": ["other"]}, ["never-mentioned"], "") == []


# ---------------------------------------------------------------------------
# phase-overlap
# ---------------------------------------------------------------------------

OVERLAP_CASES = {c["label"]: c for c in GOLDEN["overlap_cases"]}


def _overlap(label):
    return OVERLAP_CASES[label]["stdout"]["overlapping_files"]


def test_the_overlap_is_the_sorted_deduplicated_intersection():
    assert _overlap("intersecao") == ["src/b.ts", "src/c.ts"]
    assert _overlap("sem-intersecao") == []
    assert _overlap("duplicatas") == ["src/a.ts"]
    assert _overlap("saida-ordenada") == ["a.ts", "m.ts", "z.ts"]


def test_the_overlap_does_not_depend_on_which_phase_is_named_first():
    assert _overlap("intersecao") == _overlap("ordem-invertida")


def test_a_phase_that_planned_no_files_is_empty_rather_than_an_error():
    """A story with no implementation, an implementation with no files, and a
    document with no userStories at all: a phase may legitimately have planned
    none of them, and each hop was tolerant in the jq too."""
    assert _overlap("historias-magras") == ["src/a.ts"]
    assert _overlap("sem-historias") == []
    assert _overlap("sem-chave-userstories") == []
    assert R.overlap_files({}) == []
    assert R.overlap_files({"userStories": [{}, {"implementation": {}}]}) == []


def test_jq_total_order_puts_a_number_before_a_string():
    """files[] is not schema-checked, and sorting a mixed list is what
    jq_sort_key exists for -- plain Python would raise."""
    assert _overlap("files-nao-string") == [7, "src/a.ts"]
    assert R.jq_unique(["b", 7, "a", 7]) == [7, "a", "b"]


def test_the_phase_id_the_caller_typed_is_what_reaches_the_message_and_the_path():
    """A decimal id has to survive two hops as text: the tasks file it reads is
    <dir>/f-phase-2.1-tasks.json, and a refusal quotes the id back. ids-decimais
    resolving an overlap at all is the proof of the first -- the file is only
    found if "2.1" reached the name -- and fase-sem-dir the proof of the second.
    """
    assert OVERLAP_CASES["ids-decimais"]["exit"] == 0
    assert _overlap("ids-decimais") == ["src/x.ts"]
    assert "phase 9 not found" in OVERLAP_CASES["fase-a-inexistente"]["stderr"]
    assert "-phase-2-tasks.json" in OVERLAP_CASES["tasks-b-ausente"]["stderr"]


def test_a_missing_or_malformed_tasks_file_names_the_path_and_the_next_step():
    missing = OVERLAP_CASES["tasks-b-ausente"]
    assert missing["exit"] == 1
    assert "has no tasks file yet" in missing["stderr"]
    assert "run /aimi:plan --phase 2 to materialize it first" in missing["stderr"]
    for label in ("tasks-a-malformado", "tasks-b-malformado"):
        assert "malformed tasks file:" in OVERLAP_CASES[label]["stderr"]


def test_phase_dirs_answers_with_the_bare_directory():
    doc = {"phases": [{"id": 1, "dir": "phase-1-a"}, {"id": 2}, {"id": 3, "dir": None}]}
    assert R.phase_dirs(doc, 1) == "phase-1-a"
    assert R.phase_dirs(doc, 2) == "", "a phase with no dir reads as not found, as it did"
    assert R.phase_dirs(doc, 3) == ""
    assert R.phase_dirs(doc, 99) == ""


# ---------------------------------------------------------------------------
# The two constants that must not drift apart
# ---------------------------------------------------------------------------


def test_contract_version_agrees_with_the_bash_gate():
    """_roadmap_require_contracts compares against its own copy of this number.
    Two constants for one fact drift; this is the guard that says so."""
    cli = os.path.join(SCRIPTS, "aimi-cli.sh")
    with open(cli, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("_ROADMAP_CONTRACT_VERSION="):
                bash_value = line.split("=", 1)[1].strip().strip('"')
                assert bash_value == R.CONTRACT_VERSION
                return
    pytest.fail("_ROADMAP_CONTRACT_VERSION not found in aimi-cli.sh")


# ---------------------------------------------------------------------------
# The CLI surface of roadmap.py itself
# ---------------------------------------------------------------------------


def _run(args, stdin=""):
    return subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "roadmap.py")] + args,
        input=stdin,
        capture_output=True,
        text=True,
    )


def test_unknown_op_exits_two_and_says_so():
    result = _run(["no-such-op"])
    assert result.returncode == 2
    assert "Usage: roadmap.py" in result.stderr


def test_judge_phases_reads_stdin_and_prints_one_line_per_bad_entry():
    phases = json.dumps([{"id": 1, "creates": ["/etc/passwd (absolute)"], "needs": []}])
    result = _run(["judge-phases"], stdin=phases)
    assert result.returncode == 0
    assert result.stdout.count("\n") == 1
    assert 'phase 1: creates entry #1 "/etc/passwd (absolute)"' in result.stdout


def test_judge_phases_is_silent_on_a_clean_roadmap():
    phases = json.dumps([{"id": 1, "creates": ["services/foo.Bar (does a thing)"], "needs": []}])
    result = _run(["judge-phases"], stdin=phases)
    assert result.returncode == 0
    assert result.stdout == ""
