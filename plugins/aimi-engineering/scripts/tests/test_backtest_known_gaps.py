"""Tests for backtest_known_gaps.py over a synthetic tmp_path corpus."""

import importlib.util
import json
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("backtest_known_gaps", os.path.join(HERE, "backtest_known_gaps.py"))
BT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(BT)

BAD_VERIFY = "set -o pipefail\ngrep -rn foo src | grep -q foo"
GOOD_VERIFY = "test -f README.md"


def story(sid, verify, status="completed"):
    return {
        "id": sid,
        "status": status,
        "description": "d",
        "implementation": {"files": ["a.py"], "verify": verify},
    }


def build(tmp_path, gaps, stories=None, stem="2026-01-01-demo-tasks"):
    root = tmp_path / "proj"
    (root / ".aimi" / "known-gaps").mkdir(parents=True)
    (root / ".aimi" / "tasks").mkdir()
    stories = stories if stories is not None else [
        story("US-001", BAD_VERIFY),
        story("US-002", GOOD_VERIFY),
        story("US-003", GOOD_VERIFY),
        story("US-004", GOOD_VERIFY, "pending"),
    ]
    (root / ".aimi" / "tasks" / (stem + ".json")).write_text(json.dumps({"userStories": stories}))
    for name in gaps:
        (root / ".aimi" / "known-gaps" / name).write_text("SECRET-GAP-TEXT")
    return str(root)


def test_linking_and_unlinkable(tmp_path):
    root = build(
        tmp_path,
        [
            "2026-02-01-US-001-2026-01-01-demo-tasks.md",
            "2026-02-01-US-009-2026-01-01-demo-tasks.md",  # story absent
            "2026-02-01-US-001-2026-01-01-missing-tasks.md",  # file missing
            "2026-02-01-US-001-free-slug.md",
            "2026-02-01-no-story-id.md",
        ],
    )
    report = BT.backtest(root, root)
    assert report["total_gaps"] == 5
    assert report["linked_gaps"] == 1
    assert report["unlinkable"] == 4
    assert report["base_size"] == 2  # US-002, US-003; pending US-004 and gap US-001 excluded


def test_threshold_both_sides(tmp_path):
    root = build(tmp_path, ["2026-02-01-US-001-2026-01-01-demo-tasks.md"])
    report = BT.backtest(root, root)
    row = {r["check"]: r for r in report["results"]}["pipefail-grep-q"]
    assert row["hits"] == 1 and row["verdict"] == "SHIP"
    assert {r["check"]: r for r in report["results"]}["git-diff-unstaged"]["verdict"] == "NOT-SHIP"
    # rate above the bar
    assert BT.decide(1, 0.5, (1, 0.10)) == "NOT-SHIP"
    assert BT.decide(1, 0.10, (1, 0.10)) == "SHIP"
    assert BT.decide(0, 0.0, (1, 0.10)) == "NOT-SHIP"
    assert BT.decide(1, 0.0, (2, 0.10)) == "NOT-SHIP"


def test_high_flag_rate_blocks_ship(tmp_path):
    stories = [story("US-001", BAD_VERIFY)] + [story("US-%03d" % i, BAD_VERIFY) for i in range(2, 6)]
    root = build(tmp_path, ["2026-02-01-US-001-2026-01-01-demo-tasks.md"], stories)
    row = {r["check"]: r for r in BT.backtest(root, root)["results"]}["pipefail-grep-q"]
    assert row["hits"] == 1 and row["rate"] == 1.0 and row["verdict"] == "NOT-SHIP"


def test_output_has_no_gap_text(tmp_path, capsys):
    root = build(tmp_path, ["2026-02-01-US-001-2026-01-01-demo-tasks.md"])
    assert BT.main(["--aimi-root", root], project_roots=[root]) == 0
    out = capsys.readouterr().out
    assert "SECRET-GAP-TEXT" not in out and "pipefail-grep-q" in out and "1/1" in out


def test_check_skips_without_corpus(tmp_path, capsys, monkeypatch):
    monkeypatch.delenv("AIMI_ROOT", raising=False)
    root = tmp_path / "empty"
    (root / ".aimi").mkdir(parents=True)
    assert BT.main(["--check", "--aimi-root", str(root)], project_roots=[str(root)]) == 0
    assert "skipped" in capsys.readouterr().out


def test_check_compares_to_expected(tmp_path, monkeypatch):
    root = build(tmp_path, ["2026-02-01-US-001-2026-01-01-demo-tasks.md"])
    monkeypatch.setattr(BT, "EXPECTED", frozenset({"pipefail-grep-q"}))
    assert BT.main(["--check", "--aimi-root", root], project_roots=[root]) == 0
    monkeypatch.setattr(BT, "EXPECTED", frozenset())
    assert BT.main(["--check", "--aimi-root", root], project_roots=[root]) == 1


def test_path_refusal(tmp_path, capsys):
    root = build(tmp_path, [])
    other = tmp_path / "elsewhere"
    other.mkdir()
    assert BT.main(["--aimi-root", str(other)], project_roots=[root]) == 2
    assert BT.main(["--aimi-root", root, "--labels", str(other / "l.json")], project_roots=[root]) == 2
    assert "refused" in capsys.readouterr().err


def test_labels_change_only_attribution(tmp_path):
    gap = "2026-02-01-US-001-2026-01-01-demo-tasks.md"
    root = build(tmp_path, [gap])
    plain = BT.backtest(root, root)
    labelled = BT.backtest(root, root, {gap: "pipefail-grep-q"})
    assert labelled["results"][0]["labelled"] == 1 and plain["results"][0]["labelled"] == 0
    for a, b in zip(plain["results"], labelled["results"]):
        assert (a["hits"], a["verdict"]) == (b["hits"], b["verdict"])


def test_no_verify_is_executed(tmp_path, monkeypatch):
    marker = tmp_path / "ran"
    stories = [story("US-001", "touch %s" % marker), story("US-002", "touch %s" % marker)]
    root = build(tmp_path, ["2026-02-01-US-001-2026-01-01-demo-tasks.md"], stories)

    def boom(*a, **k):
        raise AssertionError("process spawned")

    monkeypatch.setattr(subprocess, "run", boom)
    monkeypatch.setattr(subprocess, "Popen", boom)
    monkeypatch.setattr(os, "system", boom)
    BT.backtest(root, root)
    assert not marker.exists()


def test_filename_does_not_collect():
    assert not os.path.basename(os.path.join(HERE, "backtest_known_gaps.py")).startswith("test_")
