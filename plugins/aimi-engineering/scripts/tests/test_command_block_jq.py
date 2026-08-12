"""Tests for the command-block jq capture -- golden_from_jq.json's
`command_block_jq_sites` / `command_block_jq_cases` blocks.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for
test_story_merge.py. `command_block_jq_cases` was captured by mechanically
extracting every jq invocation in commands/**/*.md that opens a file and
running each one, unmodified, against a 26-fixture adversarial tasks.json
corpus -- BEFORE story 02-04 replace any of these sites with a call to a CLI
verb. It must never be regenerated from those verbs (see
`_comment_command_block_jq` in the golden file itself), and unlike the other
blocks in this file there is no port to check here yet -- this suite is not a
"does the new code match the old jq" test. What it proves instead:

  1. the recording is faithful -- replaying every case reproduces the golden
     answer byte for byte;
  2. the corpus is not a vacuum -- every question-group's answer actually
     differs somewhere across it;
  3. the capture is deterministic;
  4. the recorded ACTIVE site count and file distribution -- SITES minus the
     ones a retiring story has marked `retiredIn`, never SITES itself -- still
     match what the SAME extractor finds in the CURRENT commands/ tree. A site
     a story replaces with a CLI verb call gets `retiredIn: "<story id>"` in
     the same commit that rewrites the command file, same as
     command-blocks-baseline.txt shrinks its own rows in the commit that
     retires them; the site itself, and its cases, are never deleted.
"""

import json
import os
import subprocess
import sys
from collections import Counter, defaultdict

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import capture_command_block_jq as CAP  # noqa: E402

SCRIPTS = os.path.dirname(HERE)
CAPTURE_SH = os.path.join(SCRIPTS, "capture-command-block-jq.sh")

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _fh:
    GOLDEN = json.load(_fh)

SITES = GOLDEN["command_block_jq_sites"]
CASES = GOLDEN["command_block_jq_cases"]
SITE_BY_ID = {s["id"]: s for s in SITES}


# ---------------------------------------------------------------------------
# 1. The recording is faithful: every case, replayed
# ---------------------------------------------------------------------------


def _replay_case(case, tmp_path):
    """Rebuild the case's fixture under tmp_path, run the exact recorded
    expression, and normalize the result the same way the capture did."""
    case_root = str(tmp_path)
    operand = SITE_BY_ID[case["site"]]["operand"]
    env_vars = CAP.build_env_for_site(case["expression"], operand, case["input"], case_root)
    result = CAP.run_case(case["expression"], env_vars, case_root)
    real_root = os.path.realpath(case_root)
    for key in ("stdout", "stderr", "shellValue"):
        result[key] = CAP._normalize(result[key], case_root, real_root)
    return result


@pytest.mark.parametrize("case", CASES, ids=[f"{c['site']}--{c['fixture']}" for c in CASES])
def test_every_case_replays_byte_for_byte(case, tmp_path):
    result = _replay_case(case, tmp_path)
    for key in ("exit", "stdout", "stderr", "shellValue", "shellLines"):
        assert result[key] == case[key], (
            f"{case['site']} ({case['file']}:{case['line']}) fixture={case['fixture']!r} "
            f"field={key!r}: recorded {case[key]!r}, replay {result[key]!r}"
        )


def test_no_case_leaks_outside_tmp_path(tmp_path):
    """A probe's own env carries only PATH and HOME (pointed at the throwaway
    root) -- AIMI_PLUGIN_DIR and CLAUDECODE are absent by construction, never
    unset after the fact, and this is what makes that true rather than
    assumed: build_env_for_site's return value is exactly what gets passed as
    the subprocess's env, replacing os.environ wholesale (see run_case)."""
    case = CASES[0]
    operand = SITE_BY_ID[case["site"]]["operand"]
    env_vars = CAP.build_env_for_site(case["expression"], operand, case["input"], str(tmp_path))
    assert "AIMI_PLUGIN_DIR" not in env_vars
    assert "CLAUDECODE" not in env_vars


# ---------------------------------------------------------------------------
# 2. Anti-vacuum: every question-group's answer differs somewhere in the
#    recorded corpus -- computed from the golden data itself, not asserted.
# ---------------------------------------------------------------------------


def test_every_question_group_answers_differently_across_the_corpus():
    answers_by_group = defaultdict(set)
    for case in CASES:
        answers_by_group[case["group"]].add((case["exit"], case["shellValue"]))

    assert len(answers_by_group) >= 5, "too few question-groups recorded -- classification likely broke"
    vacuous = {g: a for g, a in answers_by_group.items() if len(a) <= 1}
    assert not vacuous, f"these groups show only ONE distinct answer across the whole corpus: {vacuous}"


def test_every_site_belongs_to_a_named_group():
    for s in SITES:
        assert s["group"] != "other", f"{s['id']} ({s['file']}:{s['line']}) fell through classify() uncategorized"


# ---------------------------------------------------------------------------
# 3. Determinism: capture twice, diff -- not asserted in prose.
# ---------------------------------------------------------------------------


def test_two_consecutive_captures_are_byte_identical():
    def _capture():
        proc = subprocess.run(
            ["bash", CAPTURE_SH], capture_output=True, text=True, timeout=180, check=True
        )
        return proc.stdout

    first = _capture()
    second = _capture()
    assert first == second


# ---------------------------------------------------------------------------
# 4. The recorded count and file distribution match a live re-extraction of
#    the CURRENT commands/ tree, over ACTIVE sites only (SITES minus the ones
#    carrying a `retiredIn` key). A site whose read a story replaces with a
#    CLI verb call is never deleted here -- its case in command_block_jq_cases
#    is the evidence the replacement preserves behaviour, and deleting the
#    site would strand it (see test_every_case_references_a_known_site).
#    Instead the retiring story adds `retiredIn: "<story id>"` to that site
#    object, in the SAME commit that rewrites the command file -- never left
#    for a later story to mark, the same rule command-blocks-baseline.txt
#    already follows for its own rows. Comparing only against active sites is
#    what keeps this suite green at every story's own commit rather than red
#    from story 02 through story 05: a site removed from commands/ without
#    being marked `retiredIn` fails one of the two tests below, and marking a
#    site `retiredIn` while it is still live in commands/ fails the other.
# ---------------------------------------------------------------------------

ACTIVE_SITES = [s for s in SITES if "retiredIn" not in s]


def _live_sites():
    proc = subprocess.run(
        ["bash", CAPTURE_SH, "--sites-only"], capture_output=True, text=True, timeout=60, check=True
    )
    return json.loads(proc.stdout)["sites"]


def test_recorded_site_count_matches_the_live_extractor():
    live = _live_sites()
    assert len(live) == len(ACTIVE_SITES), (
        f"{len(ACTIVE_SITES)} sites recorded as still active (retiredIn absent), live extractor now "
        f"finds {len(live)}. A site the live extractor no longer finds must be marked `retiredIn` in "
        "the same commit that rewrote the command file (see _comment_command_block_jq's retirement "
        "convention) -- it is not deleted from command_block_jq_sites and never regenerated from the "
        "replacement verb. A site the live extractor still finds must NOT carry `retiredIn`."
    )


def test_recorded_file_distribution_matches_the_live_extractor():
    live = _live_sites()
    live_dist = Counter(s["file"] for s in live)
    recorded_dist = Counter(s["file"] for s in ACTIVE_SITES)
    assert live_dist == recorded_dist, (
        "the live extractor's per-file counts, over the CURRENT commands/ tree, no longer match the "
        "counts of sites recorded as still active (retiredIn absent). Retiring a site updates its "
        "`retiredIn` field in the same commit as the command-file rewrite that retires it; it is never "
        "deleted from command_block_jq_sites."
    )


def test_recorded_files_are_exactly_the_ones_the_story_names():
    named = {
        "execute.md",
        "references/container-execution.md",
        "review.md",
        "plan.md",
        "references/execution-mode.md",
    }
    assert {s["file"] for s in SITES} == named


# ---------------------------------------------------------------------------
# Structural sanity on the golden block itself
# ---------------------------------------------------------------------------


def test_every_site_carries_the_four_required_fields():
    for s in SITES:
        assert s["expression"], s["id"]
        assert s["file"] and isinstance(s["line"], int), s["id"]
        assert s["question"], s["id"]


def test_every_case_references_a_known_site():
    site_ids = {s["id"] for s in SITES}
    for c in CASES:
        assert c["site"] in site_ids


def test_comment_states_the_never_regenerate_rule():
    comment = GOLDEN["_comment_command_block_jq"]
    assert "NEVER" in comment
    assert "regenerat" in comment.lower()


def test_no_existing_golden_block_was_touched():
    # A sentinel from a block this story must not modify -- a change here
    # would mean the golden file's earlier content drifted, not just grew.
    assert len(GOLDEN["story_merge_cases"]) == 92
