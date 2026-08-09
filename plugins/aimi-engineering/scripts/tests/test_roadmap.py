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
