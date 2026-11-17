"""Tests for scripts/bookkeeping.py, the reader of a project's bookkeeping declaration.

Fixtures are throwaway directories under tmp_path; the repo's own .aimi/ is never touched.
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import bookkeeping as B  # noqa: E402


def _write(tmp_path, doc, raw=None):
    d = tmp_path / ".aimi"
    d.mkdir(exist_ok=True)
    p = d / "config.json"
    p.write_text(raw if raw is not None else json.dumps(doc), encoding="utf-8")
    return p


def _git(tmp_path, *args):
    subprocess.run(["git", "-C", str(tmp_path), *args], check=True, capture_output=True)


def _repo(tmp_path):
    _git(tmp_path, "init", "-q")
    _git(tmp_path, "config", "user.email", "t@example.com")
    _git(tmp_path, "config", "user.name", "t")


DECL = {"bookkeeping": {".": {"CHANGELOG.md": {"rule": "union-lines"}, "VERSION": {"rule": "max-version"}}}}


def test_rule_kinds():
    assert B.RULE_KINDS == ("union-lines", "max-version", "sum-delta", "size-step")
    assert issubclass(B.BookkeepingError, ValueError)


def test_valid_declaration_loads_in_order(tmp_path):
    _repo(tmp_path)
    p = _write(tmp_path, DECL)
    got = B.load_declaration(p, ".")
    assert got == {"CHANGELOG.md": "union-lines", "VERSION": "max-version"}
    assert list(got) == ["CHANGELOG.md", "VERSION"]


def test_all_kinds_accepted(tmp_path):
    doc = {"bookkeeping": {".": {k: {"rule": k} for k in B.RULE_KINDS}}}
    p = _write(tmp_path, doc)
    assert list(B.load_declaration(p, ".").values()) == list(B.RULE_KINDS)


def test_absent_file(tmp_path):
    assert B.load_declaration(tmp_path / "nope.json", ".") == {}


def test_absent_key(tmp_path):
    assert B.load_declaration(_write(tmp_path, {"other": 1}), ".") == {}


def test_absent_project_entry_with_other_declaring(tmp_path):
    _repo(tmp_path)
    p = _write(tmp_path, DECL)
    assert B.load_declaration(p, "api") == {}


def test_two_keys_one_declaring(tmp_path):
    doc = {"bookkeeping": {"web": {"a.txt": {"rule": "sum-delta"}}, "api": {}}}
    p = _write(tmp_path, doc)
    assert B.load_declaration(p, "web") == {"a.txt": "sum-delta"}
    assert B.load_declaration(p, "api") == {}


def test_unrelated_malformed_key_does_not_refuse(tmp_path):
    doc = {"bookkeeping": {"web": {"a.txt": {"rule": "sum-delta"}}, "api": "bad"}}
    p = _write(tmp_path, doc)
    assert B.load_declaration(p, "web") == {"a.txt": "sum-delta"}


@pytest.mark.parametrize("doc,raw", [
    (None, "{not json"),
    (None, "[1, 2]"),
    ({"bookkeeping": []}, None),
    ({"bookkeeping": {".": []}}, None),
    ({"bookkeeping": {".": {"a": "union-lines"}}}, None),
    ({"bookkeeping": {".": {"a": {}}}}, None),
    ({"bookkeeping": {".": {"a": {"rule": 3}}}}, None),
    ({"bookkeeping": {".": {"a": {"rule": "nope"}}}}, None),
    ({"bookkeeping": {".": {"a": {"rule": "union-lines", "x": 1}}}}, None),
    ({"bookkeeping": {".": {"": {"rule": "union-lines"}}}}, None),
    ({"bookkeeping": {".": {"/abs": {"rule": "union-lines"}}}}, None),
    ({"bookkeeping": {".": {"./a": {"rule": "union-lines"}}}}, None),
    ({"bookkeeping": {".": {"a/../b": {"rule": "union-lines"}}}}, None),
    ({"bookkeeping": {".": {"a\\b": {"rule": "union-lines"}}}}, None),
    ({"bookkeeping": {".": {"a\nb": {"rule": "union-lines"}}}}, None),
])
def test_malformed_refused_naming_file(tmp_path, doc, raw):
    _repo(tmp_path)
    p = _write(tmp_path, doc, raw)
    before = p.read_bytes()
    with pytest.raises(B.BookkeepingError) as exc:
        B.load_declaration(p, ".")
    assert str(p) in str(exc.value)
    assert p.read_bytes() == before


def test_tracked_config_with_declaration_refused(tmp_path):
    _repo(tmp_path)
    p = _write(tmp_path, DECL)
    _git(tmp_path, "add", ".aimi/config.json")
    before = p.read_bytes()
    with pytest.raises(B.BookkeepingError) as exc:
        B.load_declaration(p, ".")
    assert str(p) in str(exc.value)
    assert "not trusted" in str(exc.value)
    assert p.read_bytes() == before


def test_tracked_config_without_declaration_is_empty(tmp_path):
    _repo(tmp_path)
    p = _write(tmp_path, {"other": 1})
    _git(tmp_path, "add", ".aimi/config.json")
    assert B.load_declaration(p, ".") == {}


def test_untracked_declaration_loads_and_bytes_unchanged(tmp_path):
    _repo(tmp_path)
    p = _write(tmp_path, DECL)
    before = p.read_bytes()
    assert B.load_declaration(p, ".")
    assert p.read_bytes() == before
