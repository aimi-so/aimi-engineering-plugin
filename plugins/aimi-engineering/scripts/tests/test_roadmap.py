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
