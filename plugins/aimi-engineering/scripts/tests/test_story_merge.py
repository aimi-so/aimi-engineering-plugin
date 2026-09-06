"""Tests for scripts/story_merge.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for test_roadmap.py.

`golden_from_jq.json`'s `story_merge_cases` was captured by running the jq
implementation that used to live in aimi-cli.sh over 92 adversarial cases,
BEFORE it was deleted. Unlike the earlier captures it also records each case's
INPUT, which makes every one of them replayable: test_the_port_reproduces_the_jq
below re-runs the whole corpus through the CLI and compares every field. That
test is the evidence the port changed nothing, and it is why the rest of this
file can stay short -- it asserts the properties a reader would otherwise have
to reconstruct from 92 recordings by eye.

It must never be regenerated from story_merge.py. If a case here goes red,
either the port drifted or a rule genuinely changed; in the second case the
golden file changes in the same commit as the rule, with the reason in the
message.
"""

import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_merge as SM  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _handle:
    GOLDEN = json.load(_handle)

CASES = {c["label"]: c for c in GOLDEN["story_merge_cases"]}

# The eight cases the capture's own comment names, with what each one costs. jq
# or `set -e` aborted in every one of them, so the recording is of an engine
# message rather than of a rule, and reproducing it would mean synthesizing an
# engine error on purpose. Everything NOT in this table must match byte for byte.
KNOWN_DIVERGENCES = {
    "arquivo-array": "jq aborted before the bash's own array-flattening loop could run",
    "json-numero": "jq aborted adding a number to {_srcIdx}",
    "json-string": "jq aborted adding a string to {_srcIdx}",
    "json-multiplos-valores": "--argjson rejected two JSON values three steps late",
    "dep-nao-string": "jq aborted inside startswith()",
    "escrita-legada-falha": "set -e killed the shell before the writer's own error branch",
    "side-escrita-falha": "set -e killed the shell before the writer's own error branch",
    "proj-falha-parcial": "the shell's redirect diagnostic has no Python equivalent",
}


# ---------------------------------------------------------------------------
# The port is faithful: the whole corpus, replayed
# ---------------------------------------------------------------------------


def _replay(case, tmp_path):
    """Rebuild the case's project root, run the CLI, and normalize as the capture did."""
    root = str(tmp_path)
    os.makedirs(os.path.join(root, ".aimi", "tasks"))
    if case["input"] is not None:
        os.makedirs(os.path.join(root, ".aimi", "stg"))
        for name, content in case["input"].items():
            with open(os.path.join(root, ".aimi", "stg", name), "w", encoding="utf-8") as handle:
                handle.write(content)
    # The three write-failure cases put a DIRECTORY where a lock file goes. The
    # capture recorded the obstacle only through its effect, so it is rebuilt
    # from the path the refusal names.
    for line in case["stderr"].split("\n"):
        if line.endswith(".lock: Is a directory"):
            obstacle = line.split(" ")[-4].rstrip(":")
            os.makedirs(os.path.join(root, obstacle), exist_ok=True)

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=root, capture_output=True, text=True, timeout=120
    )
    return {
        "exit": proc.returncode,
        "stdout": _normalize(proc.stdout),
        "stderr": _normalize(proc.stderr),
        "files": _files(root),
        "tree": _tree(root),
    }


def _normalize(text):
    import re

    text = re.sub(r'"createdAt": "\d{4}-\d\d-\d\d"', '"createdAt": "<DATE>"', text)
    return re.sub(r"\S*aimi-cli\.sh: line \d+:", "<CLI>: line <N>:", text)


def _normalize_name(name):
    import re

    return re.sub(r"\.[A-Za-z0-9]{6}$", ".<MKTEMP>", name)


def _files(root):
    tasks = os.path.join(root, ".aimi", "tasks")
    written = {}
    for name in sorted(os.listdir(tasks)) if os.path.isdir(tasks) else []:
        path = os.path.join(tasks, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                written[_normalize_name(".aimi/tasks/" + name)] = _normalize(handle.read())
    return written


def _tree(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(root, ".aimi")):
        for name in dirnames:
            out.append(os.path.relpath(os.path.join(dirpath, name), root) + "/")
        for name in filenames:
            out.append(_normalize_name(os.path.relpath(os.path.join(dirpath, name), root)))
    return sorted(out)


@pytest.mark.parametrize("label", sorted(CASES), ids=sorted(CASES))
def test_the_port_reproduces_the_jq(label, tmp_path):
    case = CASES[label]
    actual = _replay(case, tmp_path)
    if label in KNOWN_DIVERGENCES:
        pytest.skip(KNOWN_DIVERGENCES[label])
    for field in ("exit", "stdout", "stderr", "files", "tree"):
        assert actual[field] == case[field], label + " . " + field


def test_the_divergence_table_names_only_cases_that_exist():
    """A label that stops existing must not sit here quietly excusing nothing."""
    assert set(KNOWN_DIVERGENCES) <= set(CASES)


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES), ids=sorted(KNOWN_DIVERGENCES))
def test_each_excused_case_was_excused_for_an_engine_abort(label, tmp_path):
    """The excuse is only good while the recording still shows an engine abort.

    Every one of these was recorded either with jq's own message on stderr, or
    with the shell's redirect diagnostic. If a future capture edit makes one of
    them an ordinary refusal, it stops belonging in the table and this says so.
    """
    recorded = CASES[label]["stderr"]
    assert recorded.startswith("jq:") or "<CLI>: line <N>:" in recorded
    # And each one still refuses, or -- for the array case -- still writes the
    # merge the bash was written to write. Nothing here silently does nothing.
    actual = _replay(CASES[label], tmp_path)
    if label == "arquivo-array":
        assert actual["exit"] == 0
        merged = json.loads(actual["files"][".aimi/tasks/out-tasks.json"])
        assert [s["id"] for s in merged["userStories"]] == ["US-001", "US-002"]
    else:
        assert actual["exit"] != 0
        assert actual["stdout"] == ""


# ---------------------------------------------------------------------------
# The axis is COMPUTED, never assumed
# ---------------------------------------------------------------------------


def _written(label):
    """The tasks files a case left behind -- never its .lock files or a scratch
    file a failed write orphaned, both of which the capture also records."""
    return sorted(p for p in CASES[label]["files"] if p.endswith(".json"))


def _doc(label, path):
    return json.loads(CASES[label]["files"][path])


def _docs(label):
    return [_doc(label, path) for path in _written(label)]


def test_the_axis_is_decided_by_distinct_project_count_and_nothing_else():
    """Two or more distinct normalized .project values take the PROJECT axis;
    anything less takes SIDE. Measured off the files each case actually wrote,
    because a case's NAME is not evidence of which axis it took."""
    project_axis = [
        label for label in CASES if any("splitGroup" in doc["metadata"] for doc in _docs(label))
    ]
    side_axis = [
        label for label in CASES if any(p.endswith("-frontend-tasks.json") for p in _written(label))
    ]
    assert not set(project_axis) & set(side_axis), "no case may take both axes"
    assert len(project_axis) >= 10 and len(side_axis) >= 10

    for label in project_axis:
        total = _docs(label)[0]["metadata"]["splitGroup"]["total"]
        assert total >= 2, label
        if CASES[label]["exit"] == 0:
            # A completed run writes one file per distinct project and no other.
            assert len(_written(label)) == total, label
            projects = {
                SM.norm_project(s.get("project")) for d in _docs(label) for s in d["userStories"]
            }
            assert len(projects) == total, label
    for label in side_axis:
        projects = {SM.norm_project(s.get("project")) for d in _docs(label) for s in d["userStories"]}
        assert len(projects) < 2, label


def test_one_tagged_project_plus_an_untagged_story_is_refused_not_routed():
    """The failure the untagged rule exists to stop: one tagged repo and stories
    with no project counts as a SINGLE distinct project, so without the rule it
    would take the SIDE axis -- one file, one branch, two repositories."""
    for label in ("proj-nao-marcado-recusa", "proj-nao-marcado-um-projeto"):
        case = CASES[label]
        assert case["exit"] == 1
        assert "EVERY story needs a project" in case["stderr"]
        assert case["files"] == {}, "a refusal writes nothing"


def test_a_malformed_project_is_refused_in_every_split_mode():
    """The value is a repository path a downstream command will cd into, so
    "../sibling-repo" must not reach a tasks file by any route -- legacy
    included, where no split ever happens."""
    assert "--split" not in CASES["projeto-invalido-legacy"]["args"]
    for label in ("projeto-invalido-legacy", "projeto-invalido-numero", "proj-projeto-invalido"):
        assert CASES[label]["exit"] == 1
        assert "no files were written" in CASES[label]["stderr"]
        assert CASES[label]["files"] == {}


@pytest.mark.parametrize(
    "raw,state,norm",
    [
        ("apps/web", "tagged", "apps/web"),
        ("apps/web/", "tagged", "apps/web"),
        (".", "tagged", "."),
        ("a@b", "tagged", "a@b"),
        (None, "untagged", None),
        ("", "untagged", None),
        ("\t", "untagged", None),
        (" apps/web ", "invalid", "apps/web"),
        ("./x", "invalid", "./x"),
        ("../x", "invalid", "../x"),
        ("a/../b", "invalid", "a/../b"),
        ("a//b", "invalid", "a//b"),
        ("/a", "invalid", "/a"),
        ("-lead", "invalid", "-lead"),
        (7, "invalid", None),
    ],
)
def test_the_project_grammar_judges_the_raw_value_and_normalizes_separately(raw, state, norm):
    """project_state deliberately inspects the RAW string: " apps/web " is
    invalid rather than being quietly trimmed into a value whose raw form is
    what a downstream command would cd into."""
    assert SM.project_state(raw) == state
    if isinstance(raw, str) or raw is None:
        assert SM.norm_project(raw) == norm


def test_a_trailing_slash_groups_with_its_unslashed_twin():
    """One normalization, used by both the axis decision and the grouping pass.
    Two rules is how one branch for two repositories came back."""
    assert SM.group_key("apps/web/") == SM.group_key("apps/web")
    assert len(_written("side-um-projeto-barra")) == 2, "one project, so the SIDE axis"
    assert len(_written("proj-barra-final")) == 2, "two projects that normalize apart"


# ---------------------------------------------------------------------------
# PROJECT axis: splitGroup, contiguous ids, slugs
# ---------------------------------------------------------------------------


def test_split_group_describes_the_whole_set_from_inside_any_one_file():
    """Downstream consumers discover the full set from splitGroup instead of
    re-deriving it from filename string conventions."""
    paths = [p for p in _written("proj-tres-repos") if p.endswith("-tasks.json")]
    assert len(paths) == 3
    seen = {}
    for path in paths:
        group = _doc("proj-tres-repos", path)["metadata"]["splitGroup"]
        assert group["total"] == 3
        assert len(group["siblings"]) == 2
        assert path not in group["siblings"]
        seen[group["index"]] = group["project"]
    assert sorted(seen) == [1, 2, 3]
    assert list(seen.values()) == sorted(seen.values()), "groups are in lexicographic order"


def test_the_side_axis_invents_no_split_group():
    """SIDE-axis, legacy and frontend-only files have no splitGroup key and none
    should be invented for them."""
    for label in ("side-particao", "feliz-tres-historias"):
        for doc in _docs(label):
            assert "splitGroup" not in doc["metadata"]


def test_ids_are_reassigned_in_contiguous_blocks_and_stay_unique_across_the_set():
    for label in ("proj-tres-repos", "proj-singleton", "side-particao"):
        ids = [s["id"] for doc in _docs(label) for s in doc["userStories"]]
        assert sorted(ids) == sorted(set(ids)), label + ": ids collide across files"
        assert sorted(ids) == ["US-%03d" % (i + 1) for i in range(len(ids))], label


def test_a_project_path_never_reaches_a_filename_raw():
    assert SM.slugify("apps/web") == "apps-web"
    assert SM.slugify("a.b") == "a-b"
    assert SM.slugify(".") == "root", "a value that flattens to nothing becomes root"
    assert SM.slugify("--a--b--") == "a-b"
    assert ".aimi/tasks/out-tasks-root-tasks.json" in _written("proj-grupo-raiz")


def test_two_projects_that_flatten_to_one_slug_hard_fail_before_any_write():
    case = CASES["proj-colisao-slug"]
    assert case["exit"] == 1
    assert 'basename slug "a-b" is shared by projects: a.b, a/b' in case["stderr"]
    assert case["files"] == {}, "zero files land, not one"


def test_a_derived_name_is_refused_never_truncated():
    """Truncating two long project values to a common prefix would manufacture a
    slug collision between projects that do not actually conflict."""
    for label in ("proj-slug-longo", "proj-basename-longo"):
        assert CASES[label]["exit"] == 1
        assert "names are refused, never truncated" in CASES[label]["stderr"]
        assert CASES[label]["files"] == {}
    assert "limit 64" in CASES["proj-slug-longo"]["stderr"]
    assert "limit 248 = NAME_MAX 255 minus the 7-char mktemp suffix" in (
        CASES["proj-basename-longo"]["stderr"]
    )


def test_the_branch_regex_leg_is_reachable_if_slugify_ever_changes():
    """Currently unreachable given slugify's output, which is the point: it costs
    one search and is the only thing between a future slugify edit and a branch
    name handed to git unchecked."""
    bad = {"project": "p", "slug": "s", "path": "d/x.json", "branchName": "-nope", "storyCount": 1}
    assert SM._derived_name_errors(bad, r"^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")
    good = dict(bad, branchName="feat/merged-s")
    assert SM._derived_name_errors(good, r"^[a-zA-Z0-9][a-zA-Z0-9/_-]*$") == []


def test_a_mid_loop_write_failure_names_all_three_sets():
    """Each surviving file advertises a splitGroup.total and a siblings[] list
    describing a complete N-way split that does not exist on disk, so the reader
    needs to know which of those siblings landed and which never will."""
    case = CASES["proj-falha-parcial"]
    assert case["exit"] == 1
    assert "Written before this failure (1):" in case["stderr"]
    assert "Not attempted (1):" in case["stderr"]
    assert "Staging dir preserved for retry:" in case["stderr"]
    assert ".aimi/tasks/out-tasks-apps-mobile-tasks.json" in case["files"]
    assert ".aimi/tasks/out-tasks-services-api-tasks.json" not in case["files"]
    assert ".aimi/stg/" in case["tree"], "the staging dir survives so a retry is unambiguous"


# ---------------------------------------------------------------------------
# The dropped cross-file dependencies, on both axes
# ---------------------------------------------------------------------------


def _smells(label, path):
    return _doc(label, path)["metadata"].get("smellWarnings", [])


def test_side_and_project_key_their_drops_by_different_names():
    """`side` and `project` are mutually exclusive per entry -- the axis decides
    which one is emitted, and consumers read whichever is present."""
    side = [e for e in _smells("side-queda-cross-file", _written("side-queda-cross-file")[0])
            if e["type"] == "cross-file-dep-dropped"]
    project = [e for e in _smells("proj-avisos-por-projeto", _written("proj-avisos-por-projeto")[0])
               if e["type"] == "cross-file-dep-dropped"]
    assert side and project
    for entry in side:
        assert "side" in entry and "project" not in entry
        assert all("side" in d and "project" not in d for d in entry["droppedDeps"])
    for entry in project:
        assert "project" in entry and "side" not in entry
        assert all("project" in d and "side" not in d for d in entry["droppedDeps"])


def test_the_same_combined_smell_set_reaches_every_file_of_a_split():
    """Reviewers see the same full smell surface regardless of which file they
    inspect first."""
    for label in ("side-queda-cross-file", "proj-tres-repos", "proj-avisos-por-projeto"):
        sets = [_smells(label, path) for path in _written(label)]
        assert all(s == sets[0] for s in sets), label


def test_a_drop_that_empties_the_list_is_called_a_false_root_and_a_partial_loss_is_not():
    """becameRoot is true only when the drop emptied the story's entire dependsOn
    list. The stderr callout is per false-root story, never per edge."""
    false_root = CASES["side-queda-cross-file"]
    assert "became a false wave-1 root" in false_root["stderr"]
    partial = CASES["side-perda-parcial"]
    assert "1 cross-file dependsOn edge(s) dropped" in partial["stderr"]
    assert "became a false wave-1 root" not in partial["stderr"]
    entry = [e for e in _smells("side-perda-parcial", _written("side-perda-parcial")[0])
             if e["type"] == "cross-file-dep-dropped"][0]
    assert entry["becameRoot"] is False


def test_a_dropped_target_title_is_sanitized_before_it_reaches_json_or_stderr():
    """Sub-agent-authored text, capped at 200 and stripped of the markers that
    would forge a second Warning: line."""
    for label in ("side-titulo-sanitizado", "proj-titulo-sanitizado"):
        case = CASES[label]
        assert len([l for l in case["stderr"].split("\n") if l.startswith(("Warning:", "Error:"))]) == 1
        for path in _written(label):
            for entry in _smells(label, path):
                for dep in entry.get("droppedDeps", []):
                    assert "`" not in dep["title"] and "\n" not in dep["title"]
    assert SM.rm_sanitize("Fix widget\nWarning: forged`x`", 200) == "Fix widget Warning: forgedx"


def test_a_same_side_dependency_is_not_a_drop():
    assert CASES["side-particao"]["stderr"] == ""
    for doc in _docs("side-particao"):
        assert "smellWarnings" not in doc["metadata"]


# ---------------------------------------------------------------------------
# --foundation
# ---------------------------------------------------------------------------


def test_the_foundation_edge_is_injected_once_and_deduplicated():
    stories = _doc("fundacao-injecao", ".aimi/tasks/out-tasks.json")["userStories"]
    foundation = stories[0]
    assert foundation["dependsOn"] == [], "the foundation keeps its own empty list"
    for story in stories[1:]:
        assert story["dependsOn"].count(foundation["id"]) == 1
    deduped = _doc("fundacao-dedup", ".aimi/tasks/out-tasks.json")["userStories"]
    assert deduped[1]["dependsOn"] == ["US-001"], "a pre-existing reference stays single"


def test_the_injected_edge_participates_in_the_wave_computation():
    """It is injected after the outline:NN remap and before both cycle detection
    and wave computation, so the foundation lands in wave 1 and every other
    story's wave reflects the added dependency."""
    stories = _doc("fundacao-injecao", ".aimi/tasks/out-tasks.json")["userStories"]
    assert [s["wave"] for s in stories] == [1, 2, 3]
    unflagged = _doc("fundacao-omitida", ".aimi/tasks/out-tasks.json")["userStories"]
    assert [s["wave"] for s in unflagged] == [1, 1, 2], "--foundation omitted is a no-op"


def test_a_foundation_with_its_own_dependencies_aborts_before_any_write():
    assert CASES["fundacao-dependson-nao-vazio"]["exit"] == 1
    assert "has non-empty dependsOn" in CASES["fundacao-dependson-nao-vazio"]["stderr"]
    assert CASES["fundacao-dependson-nao-vazio"]["files"] == {}
    assert "not present among staging files" in CASES["fundacao-inexistente"]["stderr"]


def test_a_lone_foundation_in_a_group_of_one_injects_nothing_and_drops_nothing():
    """proj-fundacao-edge, re-recorded when injection became per project group.

    Its lone bare --foundation 01 resolves into apps/web, which has no OTHER
    member, and neither of the other two groups names a foundation of its own.
    Nothing is injected anywhere, so nothing can be dropped: no banner, no note,
    no smellWarnings key, every dependsOn still empty. Under the retired
    global-injection rule this same input produced two cross-group drops.
    """
    case = CASES["proj-fundacao-edge"]
    assert case["exit"] == 0
    assert case["stderr"] == ""
    assert len(_written("proj-fundacao-edge")) == 3
    for path in _written("proj-fundacao-edge"):
        doc = _doc("proj-fundacao-edge", path)
        assert "smellWarnings" not in doc["metadata"]
        assert all(story["dependsOn"] == [] for story in doc["userStories"])


def test_a_bare_index_is_valid_for_a_tagged_non_root_project():
    """A bare value is bounded by ARITY, never by which project it lands in.

    proj-fundacao-edge is the frozen evidence: a lone bare --foundation 01 over
    a genuine 3-project layout, resolving to apps/web rather than to a root
    repository. A bare-means-root rule would refuse a recording that exits 0.
    """
    case = CASES["proj-fundacao-edge"]
    assert case["args"][-2:] == ["--foundation", "01"]
    inputs = list(case["input"].values())
    assert json.loads(inputs[0])["project"] == "apps/web"
    assert case["exit"] == 0


def test_foundation_edge_is_false_on_every_entry_of_a_run_without_the_flag():
    entries = [e for e in _smells("proj-avisos-por-projeto", _written("proj-avisos-por-projeto")[0])
               if e["type"] == "cross-file-dep-dropped"]
    assert entries
    assert all(d["foundationEdge"] is False for e in entries for d in e["droppedDeps"])


def test_the_side_axis_carries_no_foundation_edge_field_at_all():
    entries = [e for e in _smells("side-fundacao", _written("side-fundacao")[0])
               if e["type"] == "cross-file-dep-dropped"]
    assert entries
    assert all("foundationEdge" not in d for e in entries for d in e["droppedDeps"])


# --- inject_foundation, directly ------------------------------------------
#
# The golden corpus cannot reach any of this: every --foundation recording in it
# is a LONE BARE index, because that was the only form the jq accepted. The
# per-group contract is new capability, so it is exercised here against the
# function itself, and end to end through the wrapper in
# test-aimi-cli-part2-planning.sh's TC35/TC36.


def _story(index, project, deps=None):
    """One merged story as inject_foundation sees it: ids already assigned by
    assign_ids, outline:NN already remapped, dependsOn already a real list."""
    return {
        "id": "US-" + str(index).zfill(3),
        "title": "Story " + str(index),
        "project": project,
        "dependsOn": list(deps or []),
    }


def _deps(stories):
    return {s["id"]: s["dependsOn"] for s in stories}


def test_two_qualified_foundations_each_inject_only_inside_their_own_group():
    stories = [
        _story(1, "apps/web"),
        _story(2, "apps/web"),
        _story(3, "services/api"),
        _story(4, "services/api"),
    ]
    assert SM.inject_foundation(stories, ["apps/web:01", "services/api:03"]) == [
        "US-001",
        "US-003",
    ]
    assert _deps(stories) == {
        "US-001": [],
        "US-002": ["US-001"],
        "US-003": [],
        "US-004": ["US-003"],
    }


def test_a_group_no_value_names_receives_no_injected_edge_at_all():
    """Silent and normal -- the group either has no foundation story of its own
    or its Foundation Gate resolved Skip. Never a partial failure."""
    stories = [_story(1, "apps/web"), _story(2, "apps/web"), _story(3, "services/api")]
    assert SM.inject_foundation(stories, ["apps/web:01"]) == ["US-001"]
    assert _deps(stories) == {"US-001": [], "US-002": ["US-001"], "US-003": []}


def test_the_untagged_group_reduces_to_the_legacy_inject_into_everything_rule():
    """No axis-specific branch makes this true -- group_key(None) is one value
    for every untagged story, so per-group injection IS the legacy rule whenever
    every story shares one group. That is resolve_axis's own SIDE boundary."""
    stories = [_story(1, None), _story(2, None), _story(3, None)]
    assert SM.inject_foundation(stories, ["01"]) == ["US-001"]
    assert _deps(stories) == {"US-001": [], "US-002": ["US-001"], "US-003": ["US-001"]}


def test_a_bare_value_resolving_into_a_tagged_project_is_accepted_when_it_is_alone():
    stories = [_story(1, "apps/web"), _story(2, "apps/web")]
    assert SM.inject_foundation(stories, ["01"]) == ["US-001"]
    assert _deps(stories) == {"US-001": [], "US-002": ["US-001"]}


def test_a_story_that_already_names_its_own_foundation_keeps_exactly_one():
    stories = [_story(1, "apps/web"), _story(2, "apps/web", ["US-001"])]
    SM.inject_foundation(stories, ["01"])
    assert stories[1]["dependsOn"] == ["US-001"]


def test_an_exact_repeat_is_idempotent_rather_than_a_collision():
    stories = [_story(1, "apps/web"), _story(2, "apps/web")]
    assert SM.inject_foundation(stories, ["apps/web:01", "apps/web:01"]) == ["US-001"]
    assert stories[1]["dependsOn"] == ["US-001"]


def test_a_bare_value_is_refused_when_it_is_not_the_sole_occurrence(capsys):
    """Asked of the flag surface, not of what the values resolve to: with two
    bare values there is no way to say which project each one is for."""
    stories = [_story(1, "apps/web"), _story(2, "services/api")]
    with pytest.raises(SystemExit) as exc:
        SM.inject_foundation(stories, ["01", "services/api:02"])
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert err == (
        "Error: story-merge: --foundation 01 must be qualified as <project>:NN when"
        " more than one --foundation is given\n"
    )
    assert stories[1]["dependsOn"] == [], "refused before anything was injected"


def test_two_identical_bare_values_are_refused_before_either_is_resolved(capsys):
    stories = [_story(1, "apps/web"), _story(2, "apps/web")]
    with pytest.raises(SystemExit):
        SM.inject_foundation(stories, ["01", "01"])
    assert capsys.readouterr().err.count("must be qualified as <project>:NN") == 2


def test_a_qualifier_that_disagrees_with_the_resolved_story_refuses_the_merge(capsys):
    """The one failure nothing else in the pipeline catches: plan.md's own
    per-project bookkeeping disagreeing with what the staging file says."""
    stories = [_story(1, "apps/web"), _story(2, "services/api"), _story(3, "services/api")]
    with pytest.raises(SystemExit) as exc:
        SM.inject_foundation(stories, ["apps/web:01", "apps/web:02"])
    assert exc.value.code == 1
    assert capsys.readouterr().err == (
        'Error: story-merge: --foundation apps/web:02: story US-002 belongs to project'
        ' "services/api", not "apps/web"\n'
    )
    assert stories[2]["dependsOn"] == []


def test_the_qualifier_only_ever_confirms_and_never_decides_the_routing():
    """A qualifier that matches changes nothing about where the edges land --
    grouping comes from the story's own .project either way."""
    bare = [_story(1, "apps/web"), _story(2, "apps/web"), _story(3, "services/api")]
    qualified = [_story(1, "apps/web"), _story(2, "apps/web"), _story(3, "services/api")]
    SM.inject_foundation(bare, ["01"])
    SM.inject_foundation(qualified, ["apps/web:01"])
    assert _deps(bare) == _deps(qualified)


def test_a_trailing_slash_qualifier_matches_because_both_sides_are_normalized():
    stories = [_story(1, "apps/web/"), _story(2, "apps/web")]
    assert SM.inject_foundation(stories, ["apps/web:01"]) == ["US-001"]
    assert stories[1]["dependsOn"] == ["US-001"]


def test_two_foundations_landing_in_one_group_abort_before_any_write(capsys):
    stories = [_story(1, "apps/web"), _story(2, "apps/web"), _story(3, "apps/web")]
    with pytest.raises(SystemExit) as exc:
        SM.inject_foundation(stories, ["apps/web:01", "apps/web:02"])
    assert exc.value.code == 1
    err = capsys.readouterr().err
    assert "names more than one foundation story in the same project group" in err
    assert 'US-001 and US-002 both resolve to project "apps/web"' in err
    assert stories[2]["dependsOn"] == []


def test_an_untagged_collision_group_is_named_rather_than_printed_as_empty(capsys):
    stories = [_story(1, None), _story(2, None)]
    with pytest.raises(SystemExit):
        SM.inject_foundation(stories, [":01", ":02"])
    assert "US-001 and US-002 both resolve to project (untagged)" in capsys.readouterr().err


def test_the_missing_index_message_is_byte_identical_for_one_violator(capsys):
    """golden's fundacao-inexistente froze this exact line; batching must not
    prepend a header to it."""
    stories = [_story(1, None)]
    with pytest.raises(SystemExit) as exc:
        SM.inject_foundation(stories, ["09"])
    assert exc.value.code == 1
    assert capsys.readouterr().err == (
        "Error: story-merge: --foundation 09 not present among staging files\n"
    )


def test_every_missing_index_gets_its_own_complete_line(capsys):
    stories = [_story(1, "apps/web")]
    with pytest.raises(SystemExit):
        SM.inject_foundation(stories, ["apps/web:08", "apps/web:09"])
    assert capsys.readouterr().err == (
        "Error: story-merge: --foundation 08 not present among staging files\n"
        "Error: story-merge: --foundation 09 not present among staging files\n"
    )


def test_the_non_empty_dependson_message_is_byte_identical_for_one_violator(capsys):
    """golden's fundacao-dependson-nao-vazio froze this exact line."""
    stories = [_story(1, None, ["US-002"]), _story(2, None)]
    with pytest.raises(SystemExit) as exc:
        SM.inject_foundation(stories, ["01"])
    assert exc.value.code == 1
    assert capsys.readouterr().err == (
        "Error: story-merge: foundation story US-001 has non-empty dependsOn\n"
    )


def test_every_foundation_with_its_own_dependencies_gets_its_own_line(capsys):
    stories = [
        _story(1, "apps/web", ["US-002"]),
        _story(2, "apps/web"),
        _story(3, "services/api", ["US-002"]),
    ]
    with pytest.raises(SystemExit):
        SM.inject_foundation(stories, ["apps/web:01", "services/api:03"])
    assert capsys.readouterr().err == (
        "Error: story-merge: foundation story US-001 has non-empty dependsOn\n"
        "Error: story-merge: foundation story US-003 has non-empty dependsOn\n"
    )


def test_flags_all_collects_every_occurrence_in_argv_order():
    argv = ["--foundation", "a:01", "--split", "full-stack", "--foundation", "b:02"]
    assert SM._flags_all(argv, "--foundation") == ["a:01", "b:02"]
    assert SM._flag(argv, "--foundation") == "a:01", "_flag still answers the first"
    assert SM._flags_all(argv, "--branch-regex") == []


# --- foundationEdge, directly ---------------------------------------------


def _project_drops(tmp_path, stories, foundation_ids):
    """Run the PROJECT writer and return its cross-file-dep-dropped entries.

    Read out of ONE output file, not unioned across all of them: the combined
    smell set is written identically into every file the split produces, so
    flattening the whole set would count each entry N times.
    """
    staging = str(tmp_path / "stg")
    os.makedirs(staging, exist_ok=True)
    output = str(tmp_path / "tasks" / "out-tasks.json")
    SM.write_project_split(stories, output, staging, [], False, foundation_ids, r"^[a-z0-9/-]+$")
    written = sorted(n for n in os.listdir(str(tmp_path / "tasks")) if n.endswith(".json"))
    with open(str(tmp_path / "tasks" / written[0]), encoding="utf-8") as handle:
        doc = json.load(handle)
    return [
        e
        for e in doc["metadata"].get("smellWarnings", [])
        if e["type"] == "cross-file-dep-dropped"
    ]


def test_a_hand_authored_edge_into_another_groups_foundation_reads_true(tmp_path, capsys):
    """The case the field is KEPT for: one repository's Foundation Gate resolved
    Accept while a sibling's resolved Skip, so a story in the second repository
    still carries a dependency pointing at the first repository's foundation.
    Nothing mechanical put it there -- an injected edge never leaves its own
    group, so it is never dropped -- but it targets what IS a foundation."""
    stories = [
        _story(1, "apps/web"),
        _story(2, "services/api", ["US-001"]),
    ]
    entries = _project_drops(tmp_path, stories, ["US-001"])
    assert len(entries) == 1
    dropped = entries[0]["droppedDeps"]
    assert [d["foundationEdge"] for d in dropped] == [True]
    assert "a --foundation story belonging to another project group" in entries[0]["message"]
    err = capsys.readouterr().err
    assert "target a --foundation story in another project group" in err
    assert "hand-authored dependencies reaching across the split" in err


def test_an_ordinary_cross_group_edge_targeting_a_non_foundation_reads_false(tmp_path):
    stories = [
        _story(1, "apps/web"),
        _story(2, "apps/web"),
        _story(3, "services/api", ["US-002"]),
    ]
    dropped = [d for e in _project_drops(tmp_path, stories, ["US-001"]) for d in e["droppedDeps"]]
    assert dropped and all(d["foundationEdge"] is False for d in dropped)


def test_the_whole_set_is_threaded_in_not_one_group_s_id(tmp_path):
    """A single scalar cannot express "this dropped edge targets SOME group's
    foundation" once there can be one foundation per group."""
    stories = [
        _story(1, "apps/web"),
        _story(2, "services/api"),
        _story(3, "apps/mobile", ["US-001", "US-002"]),
    ]
    dropped = [
        d for e in _project_drops(tmp_path, stories, ["US-001", "US-002"]) for d in e["droppedDeps"]
    ]
    assert len(dropped) == 2 and all(d["foundationEdge"] is True for d in dropped)
    assert {d["project"] for d in dropped} == {"apps/web", "services/api"}


# ---------------------------------------------------------------------------
# --phase-aware
# ---------------------------------------------------------------------------


def test_phase_aware_collapses_the_doubled_tasks_segment_on_both_axes():
    assert ".aimi/tasks/feat-phase-2-frontend-tasks.json" in _written("side-phase-aware")
    assert ".aimi/tasks/feat-phase-3-apps-web-tasks.json" in _written("proj-phase-aware")
    # Unflagged derivation is untouched: it keeps the legacy double-"tasks" form.
    assert ".aimi/tasks/out-tasks-frontend-tasks.json" in _written("side-particao")
    assert ".aimi/tasks/out-tasks-apps-web-tasks.json" in _written("proj-duas-repos")


def test_a_basename_that_would_degenerate_is_refused_rather_than_guarded_per_axis():
    """Guarding inside the writers would mean fixing one axis and leaving the
    other, so the precondition refuses the input and both `${base%-tasks}` strips
    stay byte-identical."""
    for label in ("phase-aware-basename-invalido", "phase-aware-basename-so-tasks"):
        assert CASES[label]["exit"] == 1
        assert 'requires an --output basename ending in "-tasks"' in CASES[label]["stderr"]


# ---------------------------------------------------------------------------
# The sweeps
# ---------------------------------------------------------------------------


def test_agent_mode_demotes_the_two_hard_blocks_and_only_those_two():
    for hard, soft in (
        ("inventario-nao-julgado", "inventario-nao-julgado-agent"),
        ("cobertura-insuficiente", "cobertura-insuficiente-agent"),
    ):
        assert CASES[hard]["exit"] == 1 and CASES[hard]["files"] == {}
        assert CASES[soft]["exit"] == 0 and CASES[soft]["files"] != {}
        assert "--agent-mode: proceeding" in CASES[soft]["stderr"]
    # Phase 4.2 is a warning in BOTH modes; only the header names --agent-mode.
    assert CASES["simbolo-orfao"]["exit"] == 0 and CASES["simbolo-orfao-agent"]["exit"] == 0
    assert "heuristic; verify before proceeding" in CASES["simbolo-orfao"]["stderr"]
    assert "--agent-mode: proceeding" in CASES["simbolo-orfao-agent"]["stderr"]


def test_the_coverage_threshold_is_the_floor_of_six_tenths():
    assert SM.coverage_violations([{"id": "US-001", "referenceInventory": [{}] * 5, "ac_anchors": 3}]) == []
    assert SM.coverage_violations([{"id": "US-001", "referenceInventory": [{}] * 5, "ac_anchors": 2}])
    assert "floor(5 * 0.6)=3" in CASES["cobertura-insuficiente"]["stderr"]
    assert CASES["cobertura-ok"]["exit"] == 0


def test_ac_anchors_falls_back_to_the_criteria_count_when_absent():
    story = {"id": "US-001", "referenceInventory": [{}] * 5, "acceptanceCriteria": ["a"] * 3}
    assert SM.coverage_violations([story]) == []
    story["acceptanceCriteria"] = ["a"]
    assert SM.coverage_violations([story])


def test_the_orphan_symbol_smell_is_skipped_for_a_single_story_merge():
    """No sibling corpus, so every symbol would be trivially flagged."""
    assert CASES["simbolo-orfao-uma-historia"]["stderr"] == ""
    one = [{"id": "US-001", "implementation": {"approach": "Add parseWidget"}}]
    assert SM.orphan_symbol_findings(one) == []


def test_the_orphan_symbol_match_is_word_bounded():
    """`userId` is NOT treated as referenced by an unrelated `userIdentifier`."""
    assert "userId" in CASES["simbolo-orfao-limite-palavra"]["stderr"]
    assert CASES["simbolo-orfao-negativo"]["stderr"] == ""


def test_the_smell_reaches_metadata_only_when_there_is_one():
    flagged = _doc("simbolo-orfao", ".aimi/tasks/out-tasks.json")["metadata"]
    assert flagged["smellWarnings"][0]["type"] == "orphan-symbol"
    assert flagged["smellWarnings"][0]["storyId"] == "US-001"
    assert "smellWarnings" not in _doc("simbolo-orfao-negativo", ".aimi/tasks/out-tasks.json")["metadata"]


# ---------------------------------------------------------------------------
# Phase 4.3: verify coverage -- the vocabulary is DERIVED from the repository,
# never hardcoded, and CHECKED-AND-CLEAN stays distinguishable from
# CANNOT-DETERMINE-THE-VOCABULARY rather than one silently reading as the
# other.
# ---------------------------------------------------------------------------


def test_repo_command_vocabulary_is_none_with_no_recognized_source_file(tmp_path):
    """None, never an empty set: an empty set would claim "this repo's tooling
    runs nothing," which is a finding about the repo, not an admission this
    function found no package.json/Makefile/Cargo.toml/pyproject.toml/go.mod
    to read at all."""
    assert SM.repo_command_vocabulary(str(tmp_path)) is None
    assert SM.repo_command_vocabulary(str(tmp_path / "no-such-dir")) is None


def test_repo_command_vocabulary_reads_pyproject_toml_package_json_and_makefile(tmp_path):
    (tmp_path / "pyproject.toml").write_text("[tool.pytest]\n", encoding="utf-8")
    (tmp_path / "package.json").write_text(
        json.dumps({"scripts": {"build": "tsc", "test": "jest"}}), encoding="utf-8"
    )
    (tmp_path / "Makefile").write_text("lint:\n\tflake8\n\n.PHONY: lint\n", encoding="utf-8")
    vocabulary = SM.repo_command_vocabulary(str(tmp_path))
    assert "pytest" in vocabulary
    assert "npm run build" in vocabulary
    assert "npm test" in vocabulary
    assert "make lint" in vocabulary
    assert "make .PHONY" not in vocabulary, ".PHONY is not a runnable target"


def test_verify_coverage_findings_distinguishes_checked_and_clean_from_cannot_determine(tmp_path):
    """The two non-finding outcomes constraint 3 requires kept apart. Both
    stories cite the same command; only their PROJECT differs, so only one of
    the two groups has a vocabulary to check against."""
    (tmp_path / "pyproject.toml").write_text("[tool.pytest]\n", encoding="utf-8")
    clean_story = {
        "id": "US-001",
        "project": ".",
        "acceptanceCriteria": ["Running `pytest` must be green before merge."],
        "implementation": {"verify": "pytest -q"},
    }
    undetermined_story = {
        "id": "US-002",
        "project": "other-repo",  # no repo files under tmp_path/other-repo
        "acceptanceCriteria": ["Running `pytest` must be green before merge."],
        "implementation": {"verify": "echo nothing"},
    }
    findings, undetermined, clean = SM.verify_coverage_findings(
        [clean_story, undetermined_story], str(tmp_path)
    )
    assert findings == []
    assert clean == ["US-001"]
    assert undetermined == ["US-002"]


def test_verify_coverage_findings_reports_a_command_verify_never_runs(tmp_path):
    (tmp_path / "pyproject.toml").write_text("[tool.pytest]\n", encoding="utf-8")
    story = {
        "id": "US-001",
        "acceptanceCriteria": ["Running `pytest` must be green before merge."],
        "implementation": {"verify": "flake8 ."},
    }
    findings, undetermined, clean = SM.verify_coverage_findings([story], str(tmp_path))
    assert findings == [{"id": "US-001", "commands": ["pytest"]}]
    assert undetermined == clean == []


def test_verify_coverage_findings_is_silent_when_no_criterion_cites_a_command(tmp_path):
    """No backtick citation anywhere -- neither non-finding state applies. This
    is what keeps test_an_ordinary_merge_says_nothing_about_the_sidecars_
    beside_it's default staging stories (acceptanceCriteria: ["Typecheck
    passes"]) silent on stderr."""
    story = {
        "id": "US-001",
        "acceptanceCriteria": ["Typecheck passes"],
        "implementation": {"verify": "tsc --noEmit"},
    }
    assert SM.verify_coverage_findings([story], str(tmp_path)) == ([], [], [])


def test_the_verify_coverage_smell_reaches_metadata_only_for_a_real_divergence(tmp_path):
    """End to end through the real CLI, mirroring
    test_the_smell_reaches_metadata_only_when_there_is_one for orphan-symbol."""
    (tmp_path / "pyproject.toml").write_text("[tool.pytest]\n", encoding="utf-8")
    proc, doc = _merge(
        tmp_path,
        {
            "01-a.json": {
                **_staging_story("A"),
                "acceptanceCriteria": ["Running `pytest` must be green before merge."],
                "implementation": {
                    "files": ["src/x.py"],
                    "approach": "Implement it",
                    "verify": "flake8 src/x.py",
                },
            },
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert "Phase 4.3 verify-coverage smell detected" in proc.stderr
    warnings = doc["metadata"]["smellWarnings"]
    assert warnings[0]["type"] == "verify-coverage"
    assert warnings[0]["storyId"] == "US-001"
    assert warnings[0]["commands"] == ["pytest"]


def test_the_verify_coverage_smell_never_blocks_in_either_mode(tmp_path):
    files = {
        "01-a.json": {
            **_staging_story("A"),
            "acceptanceCriteria": ["Running `pytest` must be green before merge."],
            "implementation": {
                "files": ["src/x.py"],
                "approach": "Implement it",
                "verify": "flake8 src/x.py",
            },
        },
    }
    for label, extra_args in (("normal", []), ("agent", ["--agent-mode"])):
        root = tmp_path / label
        root.mkdir()
        (root / "pyproject.toml").write_text("[tool.pytest]\n", encoding="utf-8")
        proc, _doc = _merge(root, files, args=extra_args)
        assert proc.returncode == 0, (label, proc.stderr)
        assert "Phase 4.3 verify-coverage smell detected" in proc.stderr


def test_a_mock_sync_criterion_moves_to_the_story_that_consumes_the_field():
    stories = _doc("rule22-roteamento", ".aimi/tasks/out-tasks.json")["userStories"]
    schema, consumer = stories[0], stories[1]
    assert not any("Mock data updated" in ac for ac in schema["acceptanceCriteria"])
    assert any("Mock data updated" in ac for ac in consumer["acceptanceCriteria"])


def test_a_consumer_that_already_has_one_is_not_given_a_second():
    stories = _doc("rule22-consumidor-ja-tem-mock", ".aimi/tasks/out-tasks.json")["userStories"]
    consumer = stories[1]
    assert len([ac for ac in consumer["acceptanceCriteria"] if "mock" in ac.lower()]) == 1


def test_with_no_consumer_the_criterion_stays_where_it_was_written():
    stories = _doc("rule22-sem-consumidor", ".aimi/tasks/out-tasks.json")["userStories"]
    assert any("Mock data updated" in ac for ac in stories[0]["acceptanceCriteria"])


# ---------------------------------------------------------------------------
# The graph, and the things that are not the graph
# ---------------------------------------------------------------------------


def test_a_dependson_naming_no_story_is_reported_as_a_cycle():
    """Kahn's algorithm cannot tell an unreachable node from a cycle, and the
    bash never tried to. Reproduced on purpose -- a port is not where a defect
    is fixed."""
    assert "circular dependency detected among stories: US-001" in (
        CASES["dep-literal-inexistente"]["stderr"]
    )
    assert SM.cycle_stories([{"id": "US-001", "dependsOn": ["US-999"]}]) == ["US-001"]


def test_a_real_cycle_names_every_story_in_it_and_writes_nothing():
    assert "US-001, US-002" in CASES["ciclo"]["stderr"]
    assert "US-002, US-003" in CASES["ciclo-parcial"]["stderr"], "the acyclic story is not named"
    assert CASES["ciclo"]["files"] == {}


def test_an_unresolved_outline_token_names_every_story_that_carries_one():
    assert CASES["outline-pendente-multiplo"]["stderr"].count("UNRESOLVED_OUTLINE:") == 2
    assert CASES["outline-pendente-multiplo"]["files"] == {}


def test_waves_are_recomputed_per_file_after_the_split():
    """A story whose only dependency crossed the boundary is a wave-1 root in its
    own file, which is exactly what becameRoot exists to flag."""
    backend = [p for p in _written("side-queda-cross-file") if "backend" in p][0]
    stories = _doc("side-queda-cross-file", backend)["userStories"]
    assert [s["wave"] for s in stories] == [1]


def test_wave_assignment_reads_the_previous_pass_never_a_half_updated_one():
    stories = [
        {"id": "US-001", "dependsOn": []},
        {"id": "US-002", "dependsOn": ["US-001"]},
        {"id": "US-003", "dependsOn": ["US-002"]},
        {"id": "US-004", "dependsOn": ["US-001", "US-003"]},
    ]
    SM.compute_waves(stories)
    assert [s["wave"] for s in stories] == [1, 2, 3, 4]


# ---------------------------------------------------------------------------
# Reading the staging directory
# ---------------------------------------------------------------------------


def test_the_sidecars_plan_writes_beside_the_stories_are_skipped_by_name():
    assert SM.is_sidecar("outline.json")
    assert SM.is_sidecar("topic-outline.json")
    assert SM.is_sidecar("metadata.json")
    assert SM.is_sidecar("audit-result.json")
    assert not SM.is_sidecar("01-a.json")
    assert not SM.is_sidecar("outline-ish.txt")
    stories = _doc("sidecar-outline", ".aimi/tasks/out-tasks.json")["userStories"]
    assert len(stories) == 1, "four sidecars and one story"
    assert CASES["so-sidecars"]["exit"] == 1
    assert "no *.json files found" in CASES["so-sidecars"]["stderr"]


def test_a_sidecar_is_an_exact_name_or_a_name_ending_in_outline_json():
    """The predicate is a SUFFIX, not a substring.

    The four that must stay sidecars include topic-outline.json, which no exact
    name covers -- it is matched only by the suffix arm, and golden_from_jq.json
    records it as skipped, so an exact-list-only rule would move a recorded
    verdict. The two that must NOT be sidecars are the names the substring rule
    ate: 'outline' is a descriptive word in the middle of each, not the file's
    kind."""
    for name in ("outline.json", "topic-outline.json", "metadata.json", "audit-result.json"):
        assert SM.is_sidecar(name), name
    for name in (
        "05-n-foundation-outline-entries.json",
        "01-outline-generation.json",
        "03-per-project-foundation-injection.json",
    ):
        assert not SM.is_sidecar(name), name


def _merge(tmp_path, files, args=None):
    """Run a real story-merge over a staging directory built from `files`."""
    root = str(tmp_path)
    staging = os.path.join(root, ".aimi", "stg")
    os.makedirs(os.path.join(root, ".aimi", "tasks"))
    os.makedirs(staging)
    for name, value in files.items():
        with open(os.path.join(staging, name), "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))
    proc = subprocess.run(
        ["bash", CLI, "story-merge", "--staging-dir", ".aimi/stg", "--output"]
        + [".aimi/tasks/out-tasks.json"]
        + (args or []),
        cwd=root,
        capture_output=True,
        text=True,
        timeout=120,
    )
    doc = None
    written = os.path.join(root, ".aimi", "tasks", "out-tasks.json")
    if os.path.isfile(written):
        with open(written, encoding="utf-8") as handle:
            doc = json.load(handle)
    return proc, doc


def _staging_story(title, deps=None):
    return {
        "title": title,
        "description": "As a user, I want " + title + " so that it works.",
        "acceptanceCriteria": ["Typecheck passes"],
        "priority": 1,
        "status": "pending",
        "dependsOn": list(deps or []),
        "notes": "",
        "implementation": {
            "files": ["src/x.ts"],
            "approach": "Implement it",
            "verify": "tsc --noEmit",
        },
    }


def test_a_story_whose_name_embeds_outline_is_merged_rather_than_dropped(tmp_path):
    """The bug, end to end, in the shape that produced it.

    Three numbered stories, the middle one named the way a story about foundation
    outline entries gets named, and the third depending on the middle by its
    outline POSITION. Under the substring rule the middle file was dropped, the
    array shrank to two, outline:02 then pointed at the third story itself, and
    the run died with 'circular dependency detected' -- naming neither the
    dropped file nor the filter."""
    proc, doc = _merge(
        tmp_path,
        {
            "01-a.json": _staging_story("A"),
            "02-n-foundation-outline-entries.json": _staging_story("B"),
            "03-c.json": _staging_story("C", ["outline:02"]),
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert "circular dependency" not in proc.stderr
    stories = doc["userStories"]
    assert [s["id"] for s in stories] == ["US-001", "US-002", "US-003"], "all three merged"
    assert [s["title"] for s in stories] == ["A", "B", "C"]
    for story in stories:
        assert story["id"] not in story["dependsOn"], story["id"] + " depends on itself"
    assert _deps(stories)["US-003"] == ["US-002"], "outline:02 resolves to the middle story"


def test_an_ordinary_merge_says_nothing_about_the_sidecars_beside_it(tmp_path):
    """The routine sidecars are written beside the stories on EVERY plan run and
    hold no position in the merged array, so announcing them would be noise on
    every merge -- and golden_from_jq.json's sidecar-outline case records exactly
    this silence."""
    proc, doc = _merge(
        tmp_path,
        {
            "01-a.json": _staging_story("A"),
            "outline.json": "[{\"idx\": 1}]",
            "topic-outline.json": "{\"idx\": 2}",
            "metadata.json": "{\"k\": 1}",
            "audit-result.json": "{\"k\": 2}",
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stderr == "", "an ordinary merge stays silent on stderr"
    assert len(doc["userStories"]) == 1


def test_a_skipped_file_that_carries_a_story_index_names_itself_on_stderr(tmp_path):
    """The half of the bug that cost the most: a skip that says nothing.

    Only a NUMBERED file occupies a position, so only a numbered file can shift
    every outline:NN after it. That is the shape that must never be silent, and
    it is the one the suffix rule still (correctly) treats as a sidecar."""
    proc, doc = _merge(
        tmp_path,
        {
            "01-a.json": _staging_story("A"),
            "02-topic-outline.json": "{\"idx\": 2}",
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert "02-topic-outline.json" in proc.stderr, "the skipped basename is named"
    assert "skipped" in proc.stderr
    assert len(doc["userStories"]) == 1, "it is still treated as a sidecar"


def test_a_document_whose_only_value_is_null_or_false_reads_as_malformed():
    """`jq -e .` reported both as a failure, so both stay malformed here."""
    for label in ("json-null", "json-false", "json-malformado"):
        assert CASES[label]["exit"] == 1
        assert "malformed JSON in file: 01-a.json" in CASES[label]["stderr"]


def test_every_file_is_validated_before_any_file_is_loaded():
    """A refusal must not depend on how far the loader got."""
    assert CASES["indice-duplicado"]["exit"] == 1
    assert "duplicate index '01' in files: 01-a.json and 01-b.json" in (
        CASES["indice-duplicado"]["stderr"]
    )
    assert CASES["indice-duplicado"]["files"] == {}


def test_a_file_with_no_numeric_prefix_is_ordered_but_not_index_checked():
    stories = _doc("sem-prefixo-numerico", ".aimi/tasks/out-tasks.json")["userStories"]
    assert [s["title"] for s in stories] == ["A", "B"], "alpha.json before beta.json"


def test_ids_follow_file_order_not_the_digits_in_the_names():
    stories = _doc("ordem-lexicografica", ".aimi/tasks/out-tasks.json")["userStories"]
    assert [(s["id"], s["title"]) for s in stories] == [
        ("US-001", "A"),
        ("US-002", "B"),
        ("US-003", "J"),
    ], "10-j.json sorts after 02-b.json lexicographically, not numerically"


# ---------------------------------------------------------------------------
# What reaches disk
# ---------------------------------------------------------------------------


def test_the_working_keys_never_reach_a_written_file():
    """_fe, _side, __droppedDeps, __becameRoot, referenceInventory and ac_anchors
    are scaffolding for the merge and belong to no schema."""
    for case in GOLDEN["story_merge_cases"]:
        for content in case["files"].values():
            for key in SM._WORKING_KEYS + ("_srcIdx",):
                assert '"' + key + '"' not in content, case["label"] + " leaked " + key


def test_project_survives_verbatim_into_the_output():
    """It is the routing key: a lossy transform would make the key that groups
    differ from the key that is written."""
    for doc in _docs("proj-barra-final"):
        for story in doc["userStories"]:
            assert story["project"] in ("apps/web/", "services/api")


def test_a_missing_status_defaults_to_pending_and_an_authored_one_survives():
    stories = _doc("status-preservado", ".aimi/tasks/out-tasks.json")["userStories"]
    assert [s["status"] for s in stories] == ["in_progress", "done"]
    bare = _doc("status-ausente", ".aimi/tasks/out-tasks.json")["userStories"]
    assert bare[0]["status"] == "pending"


def test_the_authored_keys_keep_their_order_and_the_derived_ones_follow():
    """jq's `+` appends keys the left side did not have and leaves the rest where
    they were. A story written by this port has to land the same way, or a diff
    of two tasks files stops being readable."""
    story = json.loads(CASES["historia-magra"]["files"][".aimi/tasks/out-tasks.json"])
    assert list(story["userStories"][0]) == ["title", "id", "dependsOn", "wave", "status"]


def test_an_empty_split_side_still_writes_its_file_and_says_so():
    """Traced, does not crash downstream -- but surfaced rather than failing
    silently."""
    assert "frontend split produced zero stories" in CASES["side-lado-vazio-frontend"]["stderr"]
    assert "backend split produced zero stories" in CASES["side-lado-vazio-backend"]["stderr"]
    empty = [p for p in _written("side-lado-vazio-frontend") if "frontend" in p][0]
    assert _doc("side-lado-vazio-frontend", empty)["userStories"] == []


def test_a_successful_merge_deletes_the_staging_dir_and_a_refusal_keeps_it():
    assert ".aimi/stg/" not in CASES["feliz-uma-historia"]["tree"]
    for label in ("ciclo", "inventario-nao-julgado", "proj-colisao-slug"):
        assert ".aimi/stg/" in CASES[label]["tree"], label
