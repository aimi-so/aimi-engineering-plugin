#!/usr/bin/env python3
"""Backtest of the static plan checks against the known-gap corpus.

Scores each check from plan_checks -- the four verify detectors separately,
citation_drift and reverse_references -- and prints a SHIP or NOT-SHIP verdict
per check. The output is aggregate counts only; no gap text is ever printed.

Linking is by filename alone. A gap named `<date>-US-NNN-<tasks stem>.md`
resolves to story US-NNN of `<stem>.json` under `.aimi/tasks/` or
`.aimi/archive/`. Every other gap (no story id, a free-slug tail, tasks file
missing, story absent) is counted as unlinkable, never as missed, and
linked/total is printed beside every figure that depends on it.

The comparison base is every executed story (status completed or failed) in the
resolvable tasks files that has no gap. The script only calls the pure
plan_checks functions on story text: it never executes, probes or interprets a
verify, and it spawns no process.

Default mode prints the table. `--check` exits 0 with a one-line message when
`.aimi/known-gaps/` is absent, and otherwise exits 1 when the computed verdict
set differs from EXPECTED. `--aimi-root` and `--labels` are confined to the
project's roots; an escaping path is refused with exit 2.

Optional human labels are read from `.aimi/backtest-labels.json` (gitignored,
never committed): an object mapping a gap file name to the check it was written
about. They change only the printed attribution column.

Run from anywhere:
`python3 plugins/aimi-engineering/scripts/tests/backtest_known_gaps.py [--check]`.
"""

import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import plan_checks as PC  # noqa: E402

# Thresholds were chosen on the corpus as of this marker. A check ships only
# when it hits at least `min_hits` linked gap stories AND flags at most
# `max_rate` of the executed no-gap stories. A check with no linked hit is
# NOT-SHIP whatever its rate.
BACKTEST_AS_OF = "2026-10-26"
DEFAULT_THRESHOLD = (1, 0.10)
THRESHOLDS = {
    "pipefail-grep-q": (1, 0.10),
    "runner-summary-colour": (1, 0.10),
    "git-diff-unstaged": (1, 0.10),
    "negated-grep-no-twin": (1, 0.10),
    "citation_drift": (1, 0.10),
    "reverse_references": (1, 0.10),
}
CHECKS = tuple(PC.DETECTORS) + ("citation_drift", "reverse_references")
REVERSE_TARGET_GLOBS = (
    "plugins/aimi-engineering/commands/**/*.md",
    "plugins/aimi-engineering/skills/*/SKILL.md",
    "plugins/aimi-engineering/agents/**/*.md",
)

# Checks that earned SHIP in the recorded run (stories 07 to 09 read this), and
# the set --check compares the computed verdicts against.
BACKTEST_VERDICT = ("pipefail-grep-q", "git-diff-unstaged")
EXPECTED = frozenset(BACKTEST_VERDICT)

EXECUTED = ("completed", "failed")
_GAP_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-(US-\d{3})-(.+)\.md$")
LABELS_FILE = "backtest-labels.json"


# ---------------------------------------------------------------------------
# roots and confinement (no subprocess: .git is read as plain files)
# ---------------------------------------------------------------------------


def _git_roots(start):
    """The working tree holding `start` and, from a worktree, the main checkout."""
    current = os.path.abspath(start)
    while True:
        dotgit = os.path.join(current, ".git")
        if os.path.isdir(dotgit):
            return [current]
        if os.path.isfile(dotgit):
            roots = [current]
            try:
                with open(dotgit, encoding="utf-8") as handle:
                    line = handle.read().strip()
                if line.startswith("gitdir:"):
                    gitdir = line[len("gitdir:"):].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.join(current, gitdir)
                    commondir = os.path.join(gitdir, "commondir")
                    if os.path.isfile(commondir):
                        with open(commondir, encoding="utf-8") as handle:
                            common = handle.read().strip()
                        common = os.path.normpath(os.path.join(gitdir, common))
                        if os.path.basename(common) == ".git":
                            roots.append(os.path.dirname(common))
            except OSError:
                pass
            return roots
        parent = os.path.dirname(current)
        if parent == current:
            return []
        current = parent


def default_project_roots():
    return _git_roots(HERE)


def confine(path, project_roots):
    """realpath of `path` when it sits inside one of the roots, else None."""
    real = os.path.realpath(path)
    for root in project_roots:
        base = os.path.realpath(root)
        if real == base or real.startswith(base + os.sep):
            return real
    return None


def aimi_roots(explicit, project_roots):
    roots = []
    for candidate in (explicit, os.environ.get("AIMI_ROOT")):
        if candidate:
            roots.append(candidate)
    roots.extend(project_roots)
    seen, ordered = set(), []
    for root in roots:
        if root not in seen and os.path.isdir(os.path.join(root, ".aimi")):
            seen.add(root)
            ordered.append(root)
    return ordered


# ---------------------------------------------------------------------------
# corpus
# ---------------------------------------------------------------------------


def load_tasks(aimi_root):
    """{stem: {story id: story}} for every readable tasks document."""
    plans = {}
    for sub in ("tasks", "archive"):
        pattern = os.path.join(aimi_root, ".aimi", sub, "*.json")
        for path in sorted(glob.glob(pattern)):
            stem = os.path.basename(path)[: -len(".json")]
            if stem in plans:
                continue
            try:
                with open(path, encoding="utf-8") as handle:
                    document = json.load(handle)
            except (OSError, ValueError):
                continue
            stories = document.get("userStories") if isinstance(document, dict) else None
            if not isinstance(stories, list):
                continue
            plans[stem] = {
                s["id"]: s for s in stories if isinstance(s, dict) and isinstance(s.get("id"), str)
            }
    return plans


def link_gaps(gap_names, plans):
    """(linked, unlinkable): linked is {(stem, story id): [gap file names]}."""
    linked, unlinkable = {}, 0
    for name in gap_names:
        match = _GAP_NAME.match(name)
        if match and match.group(2) in plans and match.group(1) in plans[match.group(2)]:
            linked.setdefault((match.group(2), match.group(1)), []).append(name)
        else:
            unlinkable += 1
    return linked, unlinkable


def _text(value):
    return value if isinstance(value, str) else ""


def story_prose(story):
    impl = story.get("implementation") if isinstance(story.get("implementation"), dict) else {}
    parts = [_text(story.get("description")), _text(story.get("notes")), _text(impl.get("approach"))]
    for key in ("acceptanceCriteria", "tasks"):
        value = story.get(key)
        if isinstance(value, list):
            parts.extend(x for x in value if isinstance(x, str))
    return "\n".join(p for p in parts if p)


def flagged(story, check, project_root):
    """True when `check` fires on the story. Pure calls into plan_checks only."""
    impl = story.get("implementation") if isinstance(story.get("implementation"), dict) else {}
    if check in PC.DETECTORS:
        return bool(PC.verify_static_findings(_text(impl.get("verify")), detectors=(check,)))
    if check == "citation_drift":
        return any(f.get("kind") == "drift" for f in PC.citation_drift(story_prose(story), project_root))
    if check == "reverse_references":
        return bool(PC.reverse_references(story, project_root, REVERSE_TARGET_GLOBS))
    raise ValueError("unknown check: " + repr(check))


def read_labels(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


# ---------------------------------------------------------------------------
# scoring
# ---------------------------------------------------------------------------


def decide(hits, rate, threshold):
    min_hits, max_rate = threshold
    return "SHIP" if hits >= 1 and hits >= min_hits and rate <= max_rate else "NOT-SHIP"


def backtest(aimi_root, project_root, labels=None):
    gap_dir = os.path.join(aimi_root, ".aimi", "known-gaps")
    names = sorted(n for n in os.listdir(gap_dir) if n.endswith(".md")) if os.path.isdir(gap_dir) else []
    plans = load_tasks(aimi_root)
    linked, unlinkable = link_gaps(names, plans)
    labels = labels or {}
    gap_stories = set(linked)
    base = [
        story
        for stem, stories in plans.items()
        for sid, story in stories.items()
        if (stem, sid) not in gap_stories and story.get("status") in EXECUTED
    ]
    executed_linked = len(linked)
    linked_gaps = sum(len(v) for v in linked.values())
    results = []
    for check in CHECKS:
        hit_stories = [key for key in sorted(linked) if flagged(plans[key[0]][key[1]], check, project_root)]
        labelled = sum(
            1 for key in hit_stories for gap in linked[key] if labels.get(gap) == check
        )
        base_flags = sum(1 for story in base if flagged(story, check, project_root))
        rate = (base_flags / len(base)) if base else 0.0
        threshold = THRESHOLDS.get(check, DEFAULT_THRESHOLD)
        results.append(
            {
                "check": check,
                "hits": len(hit_stories),
                "labelled": labelled,
                "base_flags": base_flags,
                "rate": rate,
                "verdict": decide(len(hit_stories), rate, threshold),
            }
        )
    executed_all = len(base) + executed_linked
    return {
        "total_gaps": len(names),
        "linked_gaps": linked_gaps,
        "linked_stories": executed_linked,
        "unlinkable": unlinkable,
        "base_size": len(base),
        "base_rate": (executed_linked / executed_all) if executed_all else 0.0,
        "results": results,
    }


def verdict_set(report):
    return frozenset(r["check"] for r in report["results"] if r["verdict"] == "SHIP")


def print_report(report, out):
    total, linked = report["total_gaps"], report["linked_gaps"]
    print("BACKTEST_AS_OF = " + BACKTEST_AS_OF, file=out)
    print(
        "linked/total gaps: %d/%d (unlinkable: %d); gap stories: %d; no-gap executed base: %d;"
        " base rate (gap stories / executed): %.3f"
        % (linked, total, report["unlinkable"], report["linked_stories"], report["base_size"], report["base_rate"]),
        file=out,
    )
    print(
        "%-24s %-9s %-26s %-26s %s"
        % ("check", "verdict", "hits on linked gap stories", "flag rate on no-gap base", "labelled"),
        file=out,
    )
    for r in report["results"]:
        print(
            "%-24s %-9s %-26s %-26s %d"
            % (
                r["check"],
                r["verdict"],
                "%d (linked %d/%d)" % (r["hits"], linked, total),
                "%d/%d = %.3f" % (r["base_flags"], report["base_size"], r["rate"]),
                r["labelled"],
            ),
            file=out,
        )


def main(argv, project_roots=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--aimi-root")
    parser.add_argument("--labels")
    args = parser.parse_args(argv)
    roots = default_project_roots() if project_roots is None else list(project_roots)

    explicit = None
    if args.aimi_root:
        explicit = confine(args.aimi_root, roots)
        if explicit is None:
            print("backtest_known_gaps: --aimi-root is outside the project root; refused", file=sys.stderr)
            return 2
    found = aimi_roots(explicit, roots)
    gap_dir = os.path.join(found[0], ".aimi", "known-gaps") if found else None
    if not found or not os.path.isdir(gap_dir):
        if args.check:
            print("backtest_known_gaps: no .aimi/known-gaps/ here; --check skipped")
            return 0
        print("backtest_known_gaps: no .aimi/known-gaps/ found; nothing to score", file=sys.stderr)
        return 0
    aimi_root = found[0]

    labels_path = os.path.join(aimi_root, ".aimi", LABELS_FILE)
    if args.labels:
        labels_path = confine(args.labels, roots + [aimi_root])
        if labels_path is None:
            print("backtest_known_gaps: --labels is outside the project root; refused", file=sys.stderr)
            return 2
    labels = read_labels(labels_path) if os.path.isfile(labels_path) else {}

    project_root = roots[0] if roots else aimi_root
    report = backtest(aimi_root, project_root, labels)
    if not args.check:
        print_report(report, sys.stdout)
        return 0
    got = verdict_set(report)
    if got != EXPECTED:
        print(
            "backtest_known_gaps: verdict set %s differs from EXPECTED %s"
            % (sorted(got), sorted(EXPECTED)),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
