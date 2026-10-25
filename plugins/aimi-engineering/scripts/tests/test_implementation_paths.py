"""Tests for the lexical path rule over `implementation.files` and
`implementation.outputs` in scripts/tasks.py: the predicate, the story-level
findings, R17's escape warning and R24's error.

This module is separate from test_tasks.py on purpose: the rule is new, no jq
ever ran it, so there is no recording to replay, and sibling stories edit
tasks.py and its tests in parallel. `golden_from_jq.json` is read here but
never written; `test_the_golden_corpus_carries_no_outputs_key` is the
measured statement that it cannot observe R24.

validate-tasks is driven through the real CLI in a throwaway project under
pytest's tmp_path, the way test_tasks.py's replay helpers do. schemaVersion
3.3 is load-bearing: R1 returns before validate_tasks on anything older, and a
rule that never ran would pass these cases on nothing.
"""

import inspect
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tasks as T  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
GOLDEN_PATH = os.path.join(HERE, "golden_from_jq.json")

FILES = "implementation.files"
OUTPUTS = "implementation.outputs"
ESCAPE_REMEDY = (
    "a file outside the story's repository belongs in implementation.outputs "
    "as a path starting with .aimi/ relative to the AIMI root"
)
ABSENT = object()


# ---------------------------------------------------------------------------
# The predicate
# ---------------------------------------------------------------------------

FILES_CASES = [
    # (value, valid)
    ("src/app.py", True),
    ("src/", True),  # trailing slash: a directory entry
    ("a/b/c/", True),
    ("file.txt", True),
    ("src/.hidden", True),  # a dot inside a name is not a "." segment
    ("src/a..b", True),  # ".." inside a name is not a segment
    ("", False),
    ("   ", False),
    ("\t", False),
    ("a b.py", False),
    ("a\tb", False),
    ("a\nb", False),
    ("a\\b", False),
    ("/etc/passwd", False),
    ("~", False),
    ("~/x", False),
    ("~user/x", False),
    ("../x", False),
    ("a/../b", False),
    ("a/..", False),
    ("..", False),
    ("./x", False),  # a leading ./ is a "." segment
    ("a/./b", False),
    (".", False),
    (None, False),
    (7, False),
    (["a"], False),
]


@pytest.mark.parametrize("value, valid", FILES_CASES, ids=[repr(c[0]) for c in FILES_CASES])
def test_files_predicate_table(value, valid):
    reason = T.implementation_path_problem(FILES, value)
    assert (reason is None) == valid, (value, reason)
    if not valid:
        assert isinstance(reason, str) and reason


OUTPUTS_CASES = [
    (".aimi/x", True),
    (".aimi/solutions/a.md", True),
    (".aimi/solutions/", True),
    (".aimi/a b", False),
    (".aimi/", False),
    (".aimi//", False),
    (".aimi", False),
    ("aimi/x", False),
    ("src/x", False),
    ("/.aimi/x", False),
    ("~/.aimi/x", False),
    (".aimi/../x", False),
    (".aimi/./x", False),
    (".aimi/a\\b", False),
    ("", False),
    (" ", False),
    (None, False),
]


@pytest.mark.parametrize("value, valid", OUTPUTS_CASES, ids=[repr(c[0]) for c in OUTPUTS_CASES])
def test_outputs_predicate_table(value, valid):
    reason = T.implementation_path_problem(OUTPUTS, value)
    assert (reason is None) == valid, (value, reason)


def test_outputs_applies_every_files_refusal_and_adds_the_prefix_rule():
    """Every value `files` refuses, `outputs` refuses too; the prefix is extra."""
    for value, valid in FILES_CASES:
        if not valid:
            assert T.implementation_path_problem(OUTPUTS, value) is not None, value
    assert T.implementation_path_problem(FILES, "src/x") is None
    assert T.implementation_path_problem(OUTPUTS, "src/x") is not None


def test_an_unknown_field_is_the_callers_bug():
    with pytest.raises(ValueError):
        T.implementation_path_problem("implementation.verify", "x")


def test_the_escape_helper_agrees_with_the_predicate():
    for value in ("/a", "~", "~x", "../a", "a/../b", ".."):
        assert T.implementation_path_escapes(value) is True, value
    for value in ("a", "a/", "./a", "a b", "a\\b", "", None, 3):
        assert T.implementation_path_escapes(value) is False, value


def test_the_rule_is_lexical_no_filesystem_and_no_os_path():
    """The count of os.path calls in tasks.py is pinned elsewhere; the rule adds none."""
    for function in (
        T._path_escape_reason,
        T.implementation_path_escapes,
        T.implementation_path_problem,
        T.implementation_outputs_findings,
        T.implementation_path_findings,
        T._path_echo,
        T._path_finding,
    ):
        source = inspect.getsource(function)
        assert "os.path" not in source, function.__name__
        assert "os." not in source, function.__name__
        assert "open(" not in source, function.__name__


# ---------------------------------------------------------------------------
# Story-level findings
# ---------------------------------------------------------------------------


def _story(implementation=ABSENT, **extra):
    story = {"id": "US-001"}
    if implementation is not ABSENT:
        story["implementation"] = implementation
    story.update(extra)
    return story


def test_findings_come_files_first_then_outputs_with_field_and_index():
    story = _story(
        {
            "files": ["ok.py", "../x.py", "a b"],
            "outputs": [".aimi/ok", "src/not-aimi"],
        }
    )
    findings = T.implementation_path_findings(story)
    assert len(findings) == 3
    assert findings[0].startswith("implementation.files[1] ")
    assert findings[1].startswith("implementation.files[2] ")
    assert findings[2].startswith("implementation.outputs[1] ")


def test_a_files_escape_carries_the_outputs_remedy_and_other_problems_do_not():
    findings = T.implementation_path_findings(_story({"files": ["../x", "a b"]}))
    assert ESCAPE_REMEDY in findings[0]
    assert ESCAPE_REMEDY not in findings[1]
    assert "has a .. segment" in findings[0]
    assert "contains whitespace" in findings[1]


def test_each_finding_is_one_plain_sentence_naming_reason_and_value():
    (finding,) = T.implementation_path_findings(_story({"files": ["/etc/passwd"]}))
    assert "\n" not in finding
    assert finding.endswith(".")
    assert "is an absolute path" in finding
    assert "/etc/passwd" in finding


def test_non_string_files_entries_are_skipped_as_r17_skips_them():
    assert T.implementation_path_findings(_story({"files": [1, None, ["../x"]]})) == []


def test_files_that_is_not_a_list_is_not_this_rules_business():
    assert T.implementation_path_findings(_story({"files": "../x"})) == []
    assert T.implementation_path_findings(_story({"files": None})) == []


def test_outputs_absent_null_and_empty_are_valid():
    for implementation in (
        {"files": []},
        {"outputs": None},
        {"outputs": []},
        ABSENT,
        "not an object",
        None,
    ):
        assert T.implementation_outputs_findings(_story(implementation)) == [], implementation
    assert T.implementation_outputs_findings("not a story") == []


@pytest.mark.parametrize(
    "outputs",
    ["a string", {"a": 1}, 5, True, [1], [".aimi/ok", 2], [None], [[".aimi/x"]]],
    ids=lambda v: repr(v),
)
def test_outputs_that_is_not_a_list_of_strings_is_exactly_one_finding(outputs):
    findings = T.implementation_outputs_findings(_story({"outputs": outputs}))
    assert len(findings) == 1
    assert findings[0].startswith("implementation.outputs is not a list of strings")
    assert T.implementation_path_findings(_story({"files": ["../x"], "outputs": outputs}))[-1] == findings[0]


def test_no_finding_holds_a_backtick_or_a_command_substitution():
    hostile = [
        "`rm -rf x`/../a",
        "$(id)/../a",
        "../$(id)",
        "../$$((x",
        "../a`b",
        "../a\nb`c`",
    ]
    story = _story({"files": hostile, "outputs": [".aimi/`x` y", "$(id)", ".aimi/$(id) z"]})
    findings = T.implementation_path_findings(story)
    assert len(findings) == len(hostile) + 3
    for finding in findings:
        assert "`" not in finding, finding
        assert "$(" not in finding, finding
        assert "\n" not in finding, finding


def test_the_echoed_value_is_cut_short():
    long_value = "../" + "x" * 500
    (finding,) = T.implementation_path_findings(_story({"files": [long_value]}))
    assert long_value not in finding
    assert len(finding) < 400
    assert "..." in finding


# ---------------------------------------------------------------------------
# validate-tasks through the real CLI: R17 escape wording and R24
# ---------------------------------------------------------------------------


def _run(tmp_path, implementation=ABSENT, project=ABSENT, seed=None, second=None):
    """One story (or two) through `validate-tasks`; returns (exit, stdout, stderr)."""
    root = os.path.join(os.path.realpath(str(tmp_path)), "proj")
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    for relative, content in (seed or {}).items():
        target = os.path.join(root, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(content)

    def make(number, impl, proj):
        story = {
            "id": "US-%03d" % number,
            "title": "Story %d" % number,
            "description": "As a user, I want %d." % number,
            "acceptanceCriteria": ["um criterio sem ancora nenhuma"],
            "status": "pending",
            "priority": number,
            "dependsOn": [],
            "wave": 0,
        }
        if impl is not ABSENT:
            story["implementation"] = impl
        if proj is not ABSENT:
            story["project"] = proj
        return story

    stories = [make(1, implementation, project)]
    if second is not None:
        stories.append(make(2, second, ABSENT))
    document = {
        "schemaVersion": "3.3",
        "metadata": {"branchName": "ref/paths", "maxConcurrency": 1},
        "userStories": stories,
    }
    with open(os.path.join(tasks_dir, "2020-01-01-paths-tasks.json"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(document, ensure_ascii=False) + "\n")
    proc = subprocess.run(
        ["bash", CLI, "validate-tasks"], cwd=root, capture_output=True, text=True, timeout=120
    )
    norm = lambda text: text.replace(root, "/TMP")  # noqa: E731
    return proc.returncode, norm(proc.stdout), norm(proc.stderr)


def _impl(files=None, outputs=ABSENT):
    impl = {"files": files if files is not None else [], "approach": "a", "verify": "true"}
    if outputs is not ABSENT:
        impl["outputs"] = outputs
    return impl


PREFIX = "/TMP/.aimi/tasks/2020-01-01-paths-tasks.json: US-001: "
ESCAPE_WARNING = PREFIX + (
    "implementation.files leaves the story's repository: %s"
    " — move a file outside the repository to implementation.outputs\n"
)
MISSING_WARNING = PREFIX + (
    "implementation.files names a directory that does not exist: %s"
    " — the file may be new, the directory it lands in may not\n"
)
VALID = '{"valid": true, "errors": []}\n'


@pytest.mark.parametrize(
    "entries",
    [["../x.py"], ["/etc/passwd"], ["~/x"], ["src/../../x"]],
    ids=["dotdot", "absolute", "home", "inner-dotdot"],
)
def test_an_escape_warns_once_stays_valid_and_never_says_missing_directory(tmp_path, entries):
    code, out, err = _run(tmp_path, _impl(entries), seed={"src/e.py": "#\n"})
    assert code == 0
    assert out == VALID
    assert err == ESCAPE_WARNING % ", ".join(entries)
    assert "names a directory" not in err


def test_one_warning_per_story_lists_every_escape_entry(tmp_path):
    code, out, err = _run(tmp_path, _impl(["../a", "/b", "../a", "ok.py"]))
    assert code == 0 and out == VALID
    assert err.count("\n") == 1
    assert err == ESCAPE_WARNING % "../a, /b"


def test_an_escape_in_a_child_project_is_the_same_warning_not_a_missing_directory(tmp_path):
    seed = {"api/src/e.py": "#\n"}
    code, out, err = _run(tmp_path, _impl(["../outside/x.py", "src/new.py"]), project="api", seed=seed)
    assert code == 0 and out == VALID
    assert err == ESCAPE_WARNING % "../outside/x.py"
    assert "names a directory" not in err


def test_an_escape_under_an_escaping_project_is_still_an_escape(tmp_path):
    code, out, err = _run(tmp_path, _impl(["../x.py", "src/y.py"]), project="../outside")
    assert code == 0 and out == VALID
    assert err == ESCAPE_WARNING % "../x.py" + MISSING_WARNING % "src/y.py"


def test_escape_warning_precedes_the_missing_directory_warning(tmp_path):
    code, out, err = _run(
        tmp_path, _impl(["../x.py", "nao/existe/z.py"]), seed={"src/e.py": "#\n"}
    )
    assert code == 0 and out == VALID
    assert err == ESCAPE_WARNING % "../x.py" + MISSING_WARNING % "nao/existe/z.py"


def test_the_missing_directory_warning_is_unchanged_for_an_in_repo_entry(tmp_path):
    code, out, err = _run(tmp_path, _impl(["nao/existe/x.py"]), seed={"src/e.py": "#\n"})
    assert code == 0 and out == VALID
    assert err == MISSING_WARNING % "nao/existe/x.py"
    code, out, err = _run(tmp_path, _impl(["src/novo.py"]), seed={"src/e.py": "#\n"})
    assert code == 0 and out == VALID and err == ""


def test_a_clean_files_list_says_nothing(tmp_path):
    code, out, err = _run(tmp_path, _impl(["src/a.py", "src/"]), seed={"src/e.py": "#\n"})
    assert (code, out, err) == (0, VALID, "")


# R24 ------------------------------------------------------------------------


def test_r24_a_bad_outputs_entry_is_an_error_carrying_story_id_and_finding(tmp_path):
    code, out, err = _run(tmp_path, _impl(["src/a.py"], [".aimi/ok", "src/not-aimi"]), seed={"src/e.py": "#\n"})
    assert code == 1
    verdict = json.loads(out)
    assert verdict["valid"] is False
    assert len(verdict["errors"]) == 1
    expected = T.implementation_outputs_findings(
        {"implementation": _impl([], [".aimi/ok", "src/not-aimi"])}
    )
    assert expected and len(expected) == 1
    assert verdict["errors"][0] == PREFIX + expected[0]
    assert "implementation.outputs[1] " in verdict["errors"][0]


def test_r24_outputs_that_is_not_a_list_of_strings_is_an_error(tmp_path):
    for bad in ("a string", [1], {"k": ".aimi/x"}):
        code, out, _ = _run(tmp_path, _impl(["src/a.py"], bad), seed={"src/e.py": "#\n"})
        assert code == 1, bad
        errors = json.loads(out)["errors"]
        assert len(errors) == 1 and "is not a list of strings" in errors[0], bad


def test_r24_a_files_escape_alone_is_never_an_error(tmp_path):
    code, out, _ = _run(tmp_path, _impl(["../x"]))
    assert code == 0 and out == VALID


def test_r24_valid_outputs_pass_and_absent_null_empty_are_no_ops(tmp_path):
    seed = {"src/e.py": "#\n"}
    baseline = _run(tmp_path, _impl(["src/a.py"]), seed=seed)
    assert baseline == (0, VALID, "")
    for outputs in ([".aimi/a", ".aimi/solutions/"], None, []):
        assert _run(tmp_path, _impl(["src/a.py"], outputs), seed=seed) == baseline, outputs


def test_r24_lists_each_story_s_errors_in_story_order(tmp_path):
    code, out, _ = _run(
        tmp_path, _impl([], ["x"]), second=_impl([], ["y"]), seed={}
    )
    assert code == 1
    errors = json.loads(out)["errors"]
    assert [e.split(": ")[1] for e in errors] == ["US-001", "US-002"]


def test_r24_sits_after_r23_in_the_source():
    with open(os.path.join(SCRIPTS, "tasks.py"), encoding="utf-8") as handle:
        source = handle.read()
    assert source.index("# R23 -- ") < source.index("# R24 -- ")


# The golden corpus ------------------------------------------------------------


def _count_outputs_keys(node):
    """How many times an `outputs` key sits inside an `implementation` object."""
    if isinstance(node, dict):
        total = 0
        for key, value in node.items():
            if key == "implementation" and isinstance(value, dict) and "outputs" in value:
                total += 1
            total += _count_outputs_keys(value)
        return total
    if isinstance(node, list):
        return sum(_count_outputs_keys(item) for item in node)
    return 0


def _tasks_documents_of(case):
    raw = case["input"]["tasks"]
    try:
        return [json.loads(raw)]
    except ValueError:
        documents = []
        for line in raw.splitlines():
            try:
                documents.append(json.loads(line))
            except ValueError:
                continue
        return documents


def test_the_counter_finds_an_outputs_key_when_one_is_there():
    """Positive control: a counter that always said zero would pass the next test on nothing."""
    assert _count_outputs_keys({"userStories": [{"implementation": {"outputs": []}}]}) == 1
    assert _count_outputs_keys({"userStories": [{"implementation": {"outputs": None}}]}) == 1
    assert _count_outputs_keys({"userStories": [{"implementation": {"files": []}}]}) == 0
    fake_case = {"input": {"tasks": json.dumps({"userStories": [{"implementation": {"outputs": []}}]})}}
    assert sum(_count_outputs_keys(d) for d in _tasks_documents_of(fake_case)) == 1


def test_the_golden_corpus_carries_no_outputs_key():
    """No recorded validate_tasks case reaches R24, so R24 cannot move one."""
    with open(GOLDEN_PATH, encoding="utf-8") as handle:
        golden = json.load(handle)
    cases = golden["validate_tasks_cases"]
    assert len(cases) > 100, "the corpus moved; re-read this test before trusting it"
    parsed = 0
    total = 0
    for case in cases:
        documents = _tasks_documents_of(case)
        parsed += len(documents)
        total += sum(_count_outputs_keys(document) for document in documents)
    assert parsed > 100, "most recorded documents must actually parse for the count to mean anything"
    assert total == 0
