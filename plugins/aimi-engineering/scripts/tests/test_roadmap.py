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


# THREE OF THE SIX GOLDEN SANITIZER COLUMNS ARE 1.0 HISTORY NOW, and this is
# where that is recorded rather than quietly dropped. "m" and "c" were captured
# from _rm_markers_only and _rm_sanitize_contract: a formatting-only variant, and
# a splitter that found the "(" and applied two rules either side of it. Both
# existed only because the identity and the description shared one string. There
# is no string to split, so both functions are gone and the two columns have
# nothing left to compare against. "sus" changed shape rather than value --
# cv_suspicious takes an entry, and an entry is no longer a string.
#
# The columns stay in the golden file, unregenerated, because it records what jq
# did. What replaces them as evidence is stronger, not weaker: the "i" column is
# the identity JQ ITSELF computed for every corpus entry, and
# test_normalize_identity_equals_what_the_jq_itself_computed asserts the
# migration reproduces every one of them byte-for-byte. The 1.0 sanitizers are
# not tested any more because nothing runs them; the migration that carries
# their output forward is tested against the original recording.
@pytest.mark.parametrize(
    "entry,expected",
    list(zip(GOLDEN["corpus"], GOLDEN["sanitizers"])),
    ids=[repr(e)[:40] for e in GOLDEN["corpus"]],
)
def test_sanitizers_match_the_jq_they_replaced(entry, expected):
    assert R.rm_sanitize(entry, 2000) == expected["s"]
    assert R.cv_identity(entry) == expected["i"]
    assert R.cv_injection(entry) is expected["inj"]


def _phases_from_corpus():
    """Rebuild the phases exactly as roadmap-init builds them before judging.

    Every corpus entry is migrated first, which is precisely the path a roadmap
    written before the split takes to reach the judge today: normalize-contracts
    splits it, and the two fields are then judged by their two rules. The
    description goes through rm_sanitize because that is what init_sanitize does
    to it; the identity goes through nothing, because that is the rule.
    """
    phases = []
    for i, raw in enumerate(GOLDEN["corpus"]):
        entry = R.sanitize_contract_entry(R.nc_entry(raw))
        phases.append(
            {
                "id": i + 1,
                "name": "P",
                "goal": "g",
                "slug": "p",
                "creates": [entry],
                "needs": [entry],
                "areas": [R.rm_sanitize(raw, 500)],
            }
        )
    return phases


def _refusal_sites(lines):
    """The (phase, list, position) each diagnostic points at, without its text."""
    return {
        line.split(" is not a usable")[0].split(" (content withheld")[0].split(' "')[0]
        for line in lines
    }


def test_judge_phases_refuses_a_strict_superset_of_what_the_jq_refused():
    """NOT an equality against the golden lines, and every part of that is stated.

    THE TEXT of three diagnostics changed. "empty once the description is
    stripped" describes a strip that no longer happens; the shell-metacharacter
    reason used to say "move that text into the parenthesised description"; and
    the mutation rule is gone entirely, because it compared an entry's stored
    identity against the submitted one and there is no longer a second form to
    compare against.

    WHICH ENTRIES are refused may only grow, never shrink -- an entry jq refused
    that this code accepts is a hole. It grew by exactly four sites, all the same
    cause: jq's sanitizer ran over the whole entry and unwrapped or dropped a
    backtick before the guard saw it, so a backticked identity was silently
    stored under a different name than the one written. Nothing sanitizes an
    identity now, so the backtick reaches the shell-class rule and is refused --
    which is what the unwrap was approximating, reached by saying so.
    """
    got = _refusal_sites(R.judge_phases(_phases_from_corpus()))
    recorded = _refusal_sites(GOLDEN["judge_lines"])

    assert recorded - got == set(), "an entry the jq refused is no longer refused"
    assert got - recorded == {
        "phase 10: creates entry #1",   # `cmd_foo` (backticked identity)
        "phase 10: needs entry #1",
        "phase 30: creates entry #1",   # a`b (stray tick)
        "phase 30: needs entry #1",
    }
    for index in (10, 30):
        assert "`" in GOLDEN["corpus"][index - 1], "the four new refusals are the backtick ones"


def test_the_golden_corpus_actually_exercises_the_judge():
    """Anti-vacuum: a corpus that produced no diagnostics would pass forever."""
    assert len(GOLDEN["judge_lines"]) >= 40
    reasons = " ".join(R.judge_phases(_phases_from_corpus()))
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


def test_the_mutation_rule_went_with_the_thing_that_made_it_necessary():
    """It refused an entry whose STORED identity differed from the SUBMITTED one.

    It existed because one sanitizer ran over a string holding both halves, so a
    content rule meant for prose could reach a name: "parseList<T>" was stored as
    "parseList" and verify-creates then grepped for a token the phase never
    produces. The rule caught that -- and a review found it had fired zero times
    across ~366k entries, because the write path applied the same
    markers-only pass to the identity on both sides of the comparison.

    Nothing rewrites an identity now, so the rule is not merely unfired but
    inexpressible: there is no second form of the identity to compare against.
    This test replaces it, and asserts the property the rule was protecting --
    stronger, because it is an equality rather than the absence of a diagnostic.
    """
    for raw in ("parseList<T> (a helper)", "$(x) (y)", "a<b>c (d)", "`t` (d)",
                "design-system:tokens (a token file)"):
        submitted = R.nc_entry(raw)
        stored = R.sanitize_contract_entry(submitted)
        assert stored["identity"] == submitted["identity"], raw
    # ...and the prose rules that used to reach a name still apply to the half
    # they were written for.
    assert R.sanitize_contract_entry(
        {"identity": "parseList<T>", "description": "a <b>bold</b> helper"}
    ) == {"identity": "parseList<T>", "description": "a bold helper"}


# ---------------------------------------------------------------------------
# The rules themselves, stated directly rather than through a golden blob
# ---------------------------------------------------------------------------


def test_identity_is_everything_before_the_first_paren_trimmed():
    assert R.cv_identity("parseList<T> (a generic helper)") == "parseList<T>"
    assert R.cv_identity("foo.rb") == "foo.rb"
    assert R.cv_identity("   (only a description)") == ""
    assert R.cv_identity("cmd_x (parses (a,b) pairs)") == "cmd_x"


def test_nothing_at_all_is_applied_to_an_identity():
    """The two rulers, now that the two halves are two fields.

    There used to be a formatting-only sanitizer here so an identity could be
    normalized without being rewritten. The rule is simpler and stricter: the
    identity is stored exactly as submitted, and a name this file will not accept
    is refused rather than repaired.
    """
    for identity in ("parseList<T>", "design-system:tokens", "db/migrations/*.sql",
                     "`cmd_foo`", "x" * 40):
        assert R.sanitize_contract_entry({"identity": identity})["identity"] == identity
    # ...while the full sanitizer does delete, which is right for prose.
    assert R.rm_sanitize("parseList<T>", 500) == "parseList"


def test_the_identity_is_refused_rather_than_repaired():
    """Each of these used to be quietly normalized into a different name. The
    author now hears about it at write time, which is the one moment they can
    still rename the artifact."""
    assert any("shell metacharacter" in r for r in R._identity_reasons("`cmd_foo`", ""))
    assert any("contains whitespace" in r for r in R._identity_reasons("a\nb", ""))
    assert any("longer than 500" in r for r in R._identity_reasons("x" * 501, ""))
    # The cap is a refusal precisely because truncating would produce a name
    # verify-creates greps for and never finds. 500 exactly is fine.
    assert R._identity_reasons("x" * 500, "") == []


def test_a_backticked_span_unwraps_rather_than_disappearing():
    """In a DESCRIPTION. Deleting the span with its contents destroyed text a
    later reader needs, and the description is threaded into a sub-agent prompt."""
    assert R.rm_sanitize("a `x` b", 500) == "a x b"
    assert R.sanitize_contract_entry(
        {"identity": "cmd_foo", "description": "a `tick` here"}
    )["description"] == "a tick here"


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


def test_normalize_identity_equals_what_the_jq_itself_computed():
    """THE MIGRATION'S ENTIRE CORRECTNESS ARGUMENT, AS AN ASSERTION.

    Against the golden "i" column, not against cv_identity: that column is the
    identity the jq implementation computed for every corpus entry, recorded
    before it was deleted. Comparing the migration to today's Python would only
    prove the two agree with each other; comparing it to the recording proves
    every pre-migration reader would have resolved the same token.

    A needs entry is matched against a creates entry by exact equality, so one
    identity moving by one byte silently repoints a contract at nothing. This is
    the assertion that says it did not.
    """
    for entry, recorded in zip(GOLDEN["corpus"], GOLDEN["sanitizers"]):
        doc = {"phases": [{"creates": [entry]}]}
        R.normalize_contracts(doc)
        assert doc["phases"][0]["creates"][0]["identity"] == recorded["i"], entry


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


def test_an_entry_reaches_disk_as_exactly_two_keys():
    """The scratch keys this replaces (__mkCreates/__mkNeeds) carried the marker
    forms the mutation rule compared against, and had to be stripped before the
    write. There is no mutation rule and no scratch: what init_sanitize produces
    IS the stored shape, so nothing has to remember to remove anything."""
    phases = R.init_sanitize(
        [{"id": 1, "name": "A", "goal": "g",
          "creates": [{"identity": "a.rb", "description": "x"}]}]
    )
    assert phases[0]["creates"] == [{"identity": "a.rb", "description": "x"}]
    assert not [k for k in phases[0] if k.startswith("__")]


def test_an_unknown_key_in_an_entry_is_refused_by_name():
    """By name, because the key the author meant to write is the one the message
    has to show them."""
    errors = R.init_entry_shape_errors(
        [{"id": 1, "creates": [{"identity": "a", "desc": "x"}]}]
    )
    assert errors == [
        'phase 1: creates entry #1 carries the unknown key "desc" -- an entry has '
        "exactly identity and description"
    ]
    assert R.init_entry_shape_errors([{"id": 1, "creates": [{"identity": "a"}]}]) == []


def test_a_description_may_be_absent_but_never_null():
    """"" and null would be the same fact spelled two ways, and every reader
    downstream would carry a branch for the distinction."""
    assert R.sanitize_contract_entry({"identity": "a"})["description"] == ""
    reasons = R.entry_shape_reasons({"identity": "a", "description": None})
    assert reasons == [
        'description must be a string, got null -- an absent description is "", never null'
    ]


def test_dangling_dependson_names_the_phase_and_the_missing_id():
    errors = R.dangling_errors([{"id": 1, "dependsOn": [99]}], [1])
    assert errors == ["phase 1: dependsOn references unknown phase id 99"]


def test_the_identity_note_survived_the_move_with_its_example_intact():
    """This note used to be three copies of an `echo "..."` whose illustrative
    example was itself a backticked span -- so every refusal forked a lookup for
    a command named `x` and printed the sentence with the example missing.

    In a Python string literal a backtick is inert, so that failure mode is gone
    by construction. What still has to hold is that the example is there at all:
    a note about how backticks are handled is worthless without one. The note's
    CLAIM changed with the schema -- a backticked name is refused now rather than
    unwrapped -- and it still has to carry an example of the thing it describes.
    """
    assert "such as `x` is refused" in R.IDENTITY_NOTE
    assert R.IDENTITY_NOTE.startswith("Note: an identity is quoted back exactly as submitted")


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
    silent. The captured baseline, restated in the shape the guard now reads --
    its inputs are exactly what this commit changed, since both sides used to be
    re-derived by splitting a string at its first "(".
    """
    widget = R.contract_entry("shared_widget", "the widget")
    stored = {"id": 1, "creates": [widget]}
    amended = {"id": 1, "creates": [R.contract_entry("renamed_widget", "r")]}
    doc = {"phases": [stored, {"id": 2, "needs": [widget]}]}
    assert R.amend_orphan_rows(stored, amended, doc, []) == [(2, "shared_widget")]
    # ...and an authorized drop is not an orphan.
    assert R.amend_orphan_rows(stored, amended, doc, ["shared_widget"]) == []


def test_the_orphan_guard_raises_rather_than_skipping_a_malformed_entry():
    """THE FAILURE MODE THE FILTER USED TO PRODUCE, pinned as a refusal.

    `select(type == "string")` over a 2.0 list dropped every entry, so this guard
    saw an empty creates on both sides, found nothing orphaned, and let the
    amendment through -- dropping an identity a later phase still cited, exit 0.
    A malformed entry has to stop the verb, not shrink what it looked at.
    """
    stored = {"id": 1, "creates": ["shared_widget (the widget)"]}
    amended = {"id": 1, "creates": [R.contract_entry("renamed_widget", "r")]}
    with pytest.raises(R.MalformedEntry) as caught:
        R.amend_orphan_rows(stored, amended, {"phases": [stored]}, [])
    assert "phase 1: creates entry #1" in str(caught.value)
    assert "normalize-contracts" in str(caught.value)


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


def test_the_v1_string_filter_is_gone_and_stays_gone():
    """Thirteen call sites, one helper, and its docstring named this commit as
    its deadline. Against 2.0 entries the filter would have dropped every one of
    them and reported a clean roadmap -- disabling the orphan check, the
    dropped/added diff, retarget resolution, the duplicate check and the
    downstream rewrite, without printing a line. The grep is the assertion,
    because a reintroduced filter would pass every behavioural test in this file
    by making the lists it reads empty."""
    source = open(os.path.join(SCRIPTS, "roadmap.py"), encoding="utf-8").read()
    assert "_v1_string_entries" not in source
    # ...and what replaced it raises instead of skipping, at every reader.
    with pytest.raises(R.MalformedEntry):
        R.contract_entries({"id": 3, "creates": ["a (b)"]}, "creates")


def test_a_malformed_entry_names_the_phase_the_list_and_the_position():
    """The caller who can act on this reads stderr; a bare TypeError would tell a
    developer where the code broke and tell them nothing about which entry to
    fix."""
    with pytest.raises(R.MalformedEntry) as caught:
        R.contract_entries({"id": 2.1, "needs": [R.contract_entry("ok"), 7]}, "needs")
    message = str(caught.value)
    assert message.startswith("phase 2.1: needs entry #2 must be an object")
    assert "got a number" in message
    assert "normalize-contracts" in message and "roadmap-amend-phase" in message


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
        {"id": 3, "dependsOn": [], "status": "completed", "dir": "d3",
         "creates": [R.contract_entry("x", "late")]},
        {"id": 1, "dependsOn": [], "status": "pending", "dir": "d1",
         "creates": [R.contract_entry("x", "early")]},
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


def test_the_sweep_divergence_closed_and_the_case_is_loud_again():
    """THE ONE PLACE THE PORT DELIBERATELY DIFFERED FROM THE GOLDEN, now closed.

    An entry that is not a string was outside the 1.0 schema. jq could not match
    it and aborted the whole sweep (exit 5, its own error text). The port read
    those lists through _v1_string_entries, which DROPPED the entry and reported
    a clean roadmap -- and the divergence was recorded with this commit named as
    its deadline, because a silent drop is worse than a crash: a downstream needs
    that cited the dropped identity reads as unmet with nothing saying why.

    Both golden cases now raise, by name, naming the entry. Note that the shapes
    have swapped sides: jq aborted on an OBJECT and accepted a string, and this
    accepts an object and refuses a string. That is the schema change, not a
    reversal of the rule -- both refuse the shape the document does not hold.
    """
    for label in ("creates-nao-string", "creates-objeto"):
        assert SWEEP_CASES[label]["exit"] == 5, "the golden is history, not a target"
        assert "not a string" in SWEEP_CASES[label]["stderr"]

    doc = {"phases": [{"id": 1, "creates": [R.contract_entry("ok"), 42], "needs": []}]}
    with pytest.raises(R.MalformedEntry) as caught:
        R.sweep(doc)
    assert "phase 1: creates entry #2" in str(caught.value)


def test_dropped_positions_are_counted_against_the_stored_list_not_the_survivors():
    """roadmap-sweep reports droppedIndexes against the list AS STORED, so a
    reader comparing the warning to roadmap.json counts to the same entry. The
    numbered filter this replaces existed for exactly that; enumerate does it
    without a filter that could also skip something."""
    doc = {"phases": [{"id": 1, "status": "pending", "needs": [],
                       "creates": [R.contract_entry("ok.rb"),
                                   R.contract_entry("evil;x", "shell class")]}]}
    warning = R.sweep(doc)["warnings"][0]
    assert warning["droppedCount"] == 1 and warning["droppedIndexes"] == [2]


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
# The lifecycle verbs: get, set-status, claim, release-claim, reconcile
# ---------------------------------------------------------------------------

LIFECYCLE = {c["label"]: c for c in GOLDEN["lifecycle_cases"]}


def _phase(pid=1, status="pending", claim=None, **extra):
    phase = {"id": pid, "dir": "phase-" + str(pid), "status": status, "claim": claim}
    phase.update(extra)
    return phase


def test_every_refusal_in_the_lifecycle_capture_left_the_document_alone():
    """The property a port is most likely to break, because it depends on every
    check running before the write. Refusals here span all five verbs and every
    exit status the contract uses -- 1, plus roadmap-claim's 3 and 4. The 5 is
    the jq engine's own, on the phases-less roadmap named in _comment_lifecycle;
    it is frozen history, not an exit status this code produces."""
    refusals = [c for c in LIFECYCLE.values() if c["exit"] != 0]
    assert len(refusals) >= 40
    assert {c["exit"] for c in refusals} == {1, 3, 4, 5}
    assert [c["label"] for c in refusals if c["exit"] == 5] == ["get-next-sem-chave-phases"]
    for case in refusals:
        assert case["stdout"] == "", case["label"]


def test_the_status_graph_is_the_seven_edges_the_capture_walked():
    """Recomputed from STATUS_TRANSITIONS against every unforced set-status case,
    so a silently widened or narrowed graph fails here rather than in a phase
    nobody is looking at. --force cases are excluded because they are precisely
    the ones allowed to walk an edge the graph does not hold."""
    assert len(R.STATUS_TRANSITIONS) == 7
    walked = set()
    for label, case in LIFECYCLE.items():
        if case["verb"] != "roadmap-set-status" or label.endswith("-com-force"):
            continue
        if isinstance(case["stdout"], dict):
            edge = case["stdout"]["from"] + ":" + case["stdout"]["to"]
            walked.add(edge)
            assert edge in R.STATUS_TRANSITIONS or case["stdout"]["to"] == "verification_failed"
        elif "is not allowed without --force" in case["stderr"]:
            edge = case["stderr"].split("transition ", 1)[1].split(" is not", 1)[0]
            assert edge.replace(" -> ", ":") not in R.STATUS_TRANSITIONS
    assert walked >= {"pending:planned", "in_progress:completed", "verification_failed:completed"}


def test_force_overrides_transition_order_and_never_the_handoff_precondition():
    """The one rule in this verb that --force must not reach. Both sides are in
    the capture: --force carries pending -> completed, and --force does NOT
    carry a completed with no handoff.md on disk."""
    forced_order = LIFECYCLE["ss-pending-completed-com-force"]
    assert forced_order["exit"] == 0
    assert forced_order["stdout"] == {"phase": 1, "from": "pending", "to": "completed"}

    forced_precondition = LIFECYCLE["ss-completed-sem-handoff-com-force"]
    assert forced_precondition["exit"] == 1
    assert "no handoff.md found at" in forced_precondition["stderr"]
    assert forced_precondition["file"]["phases"][0]["status"] == "in_progress"


def test_completing_a_phase_releases_its_claim_in_the_same_write():
    """No window where status reads completed while the phase still shows
    claimed. The fixture claim is a 2020 timestamp, so its disappearance is
    unambiguous."""
    completed = LIFECYCLE["ss-in-progress-completed-com-handoff"]["file"]["phases"][0]
    assert completed["status"] == "completed"
    assert completed["claim"] is None
    # And the same write leaves a claim alone for every other target status.
    other = LIFECYCLE["ss-completed-planned-com-force"]["file"]["phases"][0]
    assert other["status"] == "planned"
    assert other["claim"]["claimedBy"] == "sess-old"


def test_a_null_status_reads_as_a_phase_that_is_not_there():
    """`// empty` drops a null or false status per match, so a phase carrying one
    is reported as not found rather than transitioned from "null"."""
    assert "not found in" in LIFECYCLE["ss-status-null-armazenado"]["stderr"]
    assert LIFECYCLE["ss-status-null-armazenado"]["file"]["phases"][0]["status"] is None


def test_two_phases_sharing_an_id_produce_an_edge_no_graph_entry_matches():
    """The joined two-line status is not an accident to tidy up: it is what makes
    a duplicated id refuse instead of silently transitioning both phases."""
    case = LIFECYCLE["ss-fase-duplicada"]
    assert case["exit"] == 1
    assert "transition pending\npending -> planned" in case["stderr"]
    assert ("pending\npending:planned") not in R.STATUS_TRANSITIONS


def test_pid_liveness_reads_permission_denied_as_alive(monkeypatch):
    """ProcessLookupError is dead, PermissionError is alive -- the same reading
    guard-runtime-state.py's is_alive() uses. Inverting the second one would
    release a live session's claim to whoever asked next."""
    def denied(_pid, _sig):
        raise PermissionError

    def gone(_pid, _sig):
        raise ProcessLookupError

    monkeypatch.setattr(R.os, "kill", denied)
    assert R.is_pid_alive("4242") is True
    monkeypatch.setattr(R.os, "kill", gone)
    assert R.is_pid_alive("4242") is False


def test_a_pid_that_is_not_a_positive_integer_is_dead_before_any_signal(monkeypatch):
    """The text arrives as `tostring` produced it, so a null claimedPid is the
    literal "null". Sending it to kill(2) is what the numeric test prevents."""
    def explode(_pid, _sig):
        pytest.fail("kill(2) must not be reached for a non-numeric pid")

    monkeypatch.setattr(R.os, "kill", explode)
    for text in ("null", "nao-um-pid", "0", "-1", "", "12.5"):
        assert R.is_pid_alive(text) is False


def test_a_stale_claim_is_released_even_on_a_phase_nobody_claims():
    """Release is not a side effect of claiming that phase: the dead claim sits
    on a completed phase 1 while the caller claims phase 2, and it is both
    cleared on disk and reported in staleReleased."""
    case = LIFECYCLE["cl-stale-em-outra-fase-reportada"]
    assert case["stdout"]["id"] == 2
    assert case["stdout"]["staleReleased"] == [
        {"id": 1, "pid": "<DEADPID>", "sessionId": "morta"}
    ]
    assert case["file"]["phases"][0]["claim"] is None


def test_self_reclaim_returns_the_phase_again_without_refreshing_the_claim():
    """What makes re-running /aimi:execute on an already-claimed phase
    idempotent. The 2020 claimedAt survives, which is how we know the claim was
    returned rather than rewritten."""
    case = LIFECYCLE["cl-autoreivindicacao"]
    assert case["exit"] == 0
    assert case["stdout"]["id"] == 1
    assert case["stdout"]["claim"]["claimedAt"] == "2020-01-01T00:00:00Z"
    # The sibling is untouched -- self-reclaim does not re-run eligibility.
    assert case["file"]["phases"][1]["claim"] is None


def test_self_reclaim_ignores_a_phase_that_has_already_completed():
    """The status set is pending/planned/in_progress. A completed phase this
    session still holds is not "mine to resume", so eligibility runs instead."""
    case = LIFECYCLE["cl-autoreivindicacao-fase-completed-nao-conta"]
    assert case["stdout"]["id"] == 2


def test_ranking_demotes_a_zero_work_candidate_and_never_excludes_it():
    """Issue #90 was the ORDER, not the set. Both halves are asserted: the
    zero-work phase loses to a higher-id phase that still has work, and wins the
    moment it is the only candidate left."""
    phases = [_phase(1, "verification_failed"), _phase(1.1, "planned")]
    work = {"1": False, "1.1": True}
    assert [p["id"] for p in R.candidates(phases, R.CLAIMABLE_STATUSES, work)] == [1.1, 1]
    alone = [_phase(1, "verification_failed")]
    assert R.candidates(alone, R.CLAIMABLE_STATUSES, {"1": False})[0]["id"] == 1


def test_a_phase_the_work_map_does_not_mention_is_not_demoted():
    """`has($k)` before the lookup, not `// true` after it. Collapsing the two
    would rank every unmentioned phase as zero-work and reorder the roadmap."""
    assert R._rank(_phase(3), {}) == 0
    assert R._rank(_phase(3), {"3": True}) == 0
    assert R._rank(_phase(3), {"3": False}) == 1


def test_the_two_selectors_disagree_about_a_dead_pid_claim_on_purpose():
    """roadmap-claim clears stale claims inside its lock and then claims;
    roadmap-get holds no lock, so the same phase stays invisible to it. A
    read-only verb has no business inferring liveness."""
    assert LIFECYCLE["get-next-pid-morto-continua-invisivel"]["exit"] == 1
    assert LIFECYCLE["cl-stale-liberada-e-reivindicada"]["exit"] == 0


def test_the_has_work_lookup_uses_the_per_phase_tasks_filename(tmp_path):
    """Reading a bare tasks.json here made every lookup miss, so reconcile
    silently reported zero corrections and ranking silently did nothing."""
    feature_dir = tmp_path / "f"
    (feature_dir / "phase-1").mkdir(parents=True)
    (feature_dir / "phase-1" / "tasks.json").write_text(
        json.dumps({"userStories": [{"status": "completed"}]}), encoding="utf-8"
    )
    doc = {"phases": [_phase(1)]}
    roadmap = str(feature_dir / "roadmap.json")
    assert R.has_work_map(roadmap, doc, "f") == {"1": True}
    (feature_dir / "phase-1" / "f-phase-1-tasks.json").write_text(
        json.dumps({"userStories": [{"status": "completed"}]}), encoding="utf-8"
    )
    assert R.has_work_map(roadmap, doc, "f") == {"1": False}


def test_ground_truth_is_one_rule_reconcile_and_the_work_map_both_read():
    """Two answers about the same tasks file is the drift this shares to avoid."""
    assert R.ground_truth({"userStories": []}) == "unknown"
    assert R.ground_truth({"userStories": [{"status": "completed"}]}) == "completed"
    assert R.ground_truth(
        {"userStories": [{"status": "completed"}, {"status": "failed"}]}
    ) == "verification_failed"
    assert R.ground_truth(
        {"userStories": [{"status": "completed"}, {"status": "pending"}]}
    ) == "in_progress"


def test_the_empty_ground_truth_is_the_jq_capture_and_not_an_invention():
    """A tasks file that parses but whose userStories is absent made jq abort and
    the bash carry on with an empty capture. Reconcile then wrote status: "".
    Reproduced deliberately -- it is a defect, and a port is not where a defect
    is fixed. Delete this test when the defect is, in the same commit."""
    assert R.ground_truth({"metadata": {}}) == ""
    case = LIFECYCLE["re-tasks-sem-userstories"]
    assert case["stdout"]["corrections"] == [{"id": 1, "from": "planned", "to": ""}]
    assert case["file"]["phases"][0]["status"] == ""


def test_reconcile_refuses_a_completed_correction_with_no_handoff_on_disk():
    """The same hard precondition roadmap-set-status enforces. Reconcile must not
    become a second write path with weaker invariants -- the divergence is
    reported as blocked so it stays visible instead of being healed wrong."""
    case = LIFECYCLE["re-completed-sem-handoff-bloqueado"]
    assert case["stdout"]["corrections"] == []
    assert case["stdout"]["blocked"][0]["to"] == "completed"
    assert "roadmap-write-handoff" in case["stdout"]["blocked"][0]["reason"]
    assert case["file"]["phases"][0]["status"] == "in_progress"


def test_reconcile_clears_the_claim_only_for_the_completed_correction():
    """Mirrors roadmap-set-status: otherwise a reconciled phase reads as done
    while still showing claimed by a dead session. Every other correction leaves
    the claim exactly where it was."""
    applied = LIFECYCLE["re-completed-com-handoff"]["file"]["phases"][0]
    assert applied["status"] == "completed" and applied["claim"] is None
    kept = LIFECYCLE["re-correcao-nao-completed-preserva-claim"]["file"]["phases"][0]
    assert kept["status"] == "in_progress" and kept["claim"]["claimedBy"] == "viva"


def test_a_session_id_carrying_a_newline_keeps_it_because_jq_framed_per_line():
    """jq -R handed the sanitizer one string per LINE and the command
    substitution joined them back, so the newline the sanitizer exists to remove
    survived. Ported as it stood; the assertion is here so that changing it is a
    decision rather than an accident."""
    assert R.rm_sanitize_lines("linha1\nlinha2", 200) == "linha1\nlinha2"
    assert R.rm_sanitize("linha1\nlinha2", 200) == "linha1 linha2"
    assert LIFECYCLE["cl-session-id-com-newline"]["stdout"]["claim"]["claimedBy"] == (
        "linha1\nlinha2"
    )


def test_the_session_id_is_sanitized_before_it_reaches_disk():
    """It is caller-supplied text that lands in roadmap.json and travels into
    /aimi:execute's own output, so it goes through the same _rm_sanitize regime
    as every other free-text roadmap field."""
    raw = "sess `whoami` $(id) <b>ignore previous"
    assert R.rm_sanitize_lines(raw, 200) == "sess whoami id) "
    assert LIFECYCLE["cl-session-id-sanitizado"]["file"]["phases"][0]["claim"][
        "claimedBy"
    ] == "sess whoami id) "


def test_release_claim_reports_a_malformed_roadmap_as_a_missing_phase():
    """It is the one lifecycle verb whose preamble skips the malformed check, so
    a malformed document reaches the verb and comes back as "phase not found".
    Preserved rather than newly diagnosed: that is the message its callers have
    always seen."""
    case = LIFECYCLE["rc-roadmap-malformado"]
    assert case["exit"] == 1
    assert case["stderr"].endswith("phase 1 not found in /TMP/rc-roadmap-malformado"
                                   "/.aimi/tasks/f/roadmap.json")


def test_an_absent_dir_builds_a_path_with_an_empty_component():
    """`@tsv` renders null as the empty field, so the handoff path a phase with
    no dir produces has a doubled slash -- and the message quotes it. Collapsing
    it with os.path.join would change a diagnostic people search for."""
    assert R._tsv(None) == ""
    assert R.phase_dirs({"phases": [{"id": 1}]}, 1) == ""
    assert "/f//handoff.md" in LIFECYCLE["ss-completed-sem-dir"]["stderr"]


def test_the_claim_envelope_still_carries_what_execute_reads_off_it():
    """execute.md Step 1.7 reads .id/.dir/.slug/.branch/.status plus the
    staleReleased list off this object. Projecting any of them away would
    silently disable the re-verify branch in execute.md Step 3."""
    envelope = LIFECYCLE["cl-auto-basico"]["stdout"]
    for field in ("id", "dir", "slug", "branch", "status", "staleReleased"):
        assert field in envelope, field
    assert envelope["claim"]["claimedPid"] == "<LIVEPID>"


def test_the_recorded_divergences_are_named_and_are_the_only_ones():
    """736 of 745 field comparisons identical. The nine that are not are all jq
    aborting mid-expression, and the comment beside the capture names every one
    -- so a tenth appearing later is a regression, not a rediscovery."""
    note = GOLDEN["_comment_lifecycle"]
    assert "736 of 745" in note
    for label in (
        "get-next-tasks-sem-userstories",
        "cl-tasks-sem-userstories",
        "re-tasks-sem-userstories",
        "ss-sem-chave-phases",
        "re-sem-chave-phases",
        "get-next-sem-chave-phases",
        "cl-sem-chave-phases",
    ):
        assert label in note, label
        assert label in LIFECYCLE, label


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
    phases = json.dumps(
        [{"id": 1, "creates": [R.contract_entry("/etc/passwd", "absolute")], "needs": []}]
    )
    result = _run(["judge-phases"], stdin=phases)
    assert result.returncode == 0
    assert result.stdout.count("\n") == 1
    assert 'phase 1: creates entry #1 "/etc/passwd"' in result.stdout


def test_judge_phases_is_silent_on_a_clean_roadmap():
    phases = json.dumps(
        [{"id": 1, "creates": [R.contract_entry("services/foo.Bar", "does a thing")], "needs": []}]
    )
    result = _run(["judge-phases"], stdin=phases)
    assert result.returncode == 0
    assert result.stdout == ""


def test_a_malformed_entry_stops_the_verb_with_one_stderr_line_and_no_traceback():
    """main() catches MalformedEntry and nothing else. The agent reading this
    stream needs a sentence naming the entry, not a Python stack -- and a
    traceback exits 1 too, so only the message distinguishes the two."""
    phases = json.dumps([{"id": 1, "creates": ["a (b)"], "needs": []}])
    result = _run(["judge-phases"], stdin=phases)
    assert result.returncode == 1
    assert result.stdout == ""
    assert result.stderr.startswith("Error: judge-phases: phase 1: creates entry #1")
    assert "Traceback" not in result.stderr
    assert result.stderr.count("\n") == 1


def test_the_diagnostic_names_the_verb_a_caller_can_run_not_the_internal_op():
    """Half the ops are named differently from the aimi-cli.sh verb that invokes
    them. "Error: sweep:" points at nothing anybody has typed."""
    assert R._VERB_FOR_OP["sweep"] == "roadmap-sweep"
    for op in R._VERB_FOR_OP.values():
        assert op.startswith("roadmap-"), op
    # Every op either appears in the map or is already named after its verb.
    for op in R._OPS:
        assert op in R._VERB_FOR_OP or op in (
            "judge-phases", "roadmap-get", "verify-creates", "validate-contracts",
            "normalize-contracts", "phase-overlap",
        ), op
