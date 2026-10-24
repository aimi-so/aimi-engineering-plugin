#!/usr/bin/env python3
"""Calibration for story_merge's six advisory smells.

The six are field-overlap, story-oversize, audit-duplication, stale-sibling-note,
leftover-outline-token and ac-test-enumeration.

Default mode prints the measurement tables the constants in story_merge.py were
chosen from. `--check` prints nothing unless it fails: it exits 1 when the
current constants fire on any golden story_merge case, or when the set of types
firing on the #164 reference plan is not exactly EXPECTED_REFERENCE_TYPES, and 0
otherwise. The constants are imported from story_merge, never
repeated here, so the table and the merge cannot disagree.

Sources:
  * golden_from_jq.json, always. Only the NN-*.json story inputs of each case
    count; audit-result.json, outline.json, metadata.json and any *-outline.json
    are inputs that carry no story.
  * `.aimi/**/*tasks*.json`, when present. Looked for under --aimi-root, then
    $AIMI_ROOT, then the working directory's repository (and, from a worktree,
    the main checkout that holds the gitignored .aimi/). A file that is not a
    tasks document (a verify-probe array, a lock) is skipped.
  * `--plan <glob>` narrows the "#164 reference plan" gate of --check to the
    tasks files whose basename matches; the default is the #164 plan
    (`*fix-issue-164-multi-repo-plan-execute-defects*`).

Run from anywhere: `python3 plugins/aimi-engineering/scripts/tests/calibrate_story_smells.py [--check]`.
"""

import argparse
import fnmatch
import glob
import json
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import story_merge as SM  # noqa: E402

GOLDEN = os.path.join(HERE, "golden_from_jq.json")
DEFAULT_PLAN_GLOB = "*fix-issue-164-multi-repo-plan-execute-defects*"
SMELL_TYPES = (
    "field-overlap",
    "story-oversize",
    "audit-duplication",
    "stale-sibling-note",
    "leftover-outline-token",
    "ac-test-enumeration",
)
# What the #164 plan fires, measured by this script. That plan predates the text
# remap, so its prose still carries outline:NN tokens (11 fields across 5
# stories) and leftover-outline-token is the one type that fires; it has no
# stale sibling note, no test enumeration, no audit record, and stays under both
# overlap and size bars. --check requires exactly this set, so a constant that
# starts firing a second type there, or stops firing this one, fails.
EXPECTED_REFERENCE_TYPES = frozenset({"leftover-outline-token"})
_NN_STORY = re.compile(r"[0-9]{2}-.*\.json", re.S)


def golden_plans():
    """One list of stories per golden story_merge case that stages any."""
    with open(GOLDEN, encoding="utf-8") as handle:
        cases = json.load(handle)["story_merge_cases"]
    plans = []
    for case in cases:
        stories = []
        for name, content in sorted((case.get("input") or {}).items()):
            if SM.is_sidecar(name) or not _NN_STORY.fullmatch(name):
                continue
            try:
                value = json.loads(content)
            except ValueError:
                continue
            for entry in value if isinstance(value, list) else [value]:
                if isinstance(entry, dict):
                    stories.append(entry)
        if stories:
            plans.append((case["label"], stories))
    return plans


def _aimi_roots(explicit):
    roots = []
    for candidate in (explicit, os.environ.get("AIMI_ROOT")):
        if candidate:
            roots.append(candidate)
    for cwd_based in (["rev-parse", "--show-toplevel"], ["rev-parse", "--git-common-dir"]):
        try:
            out = subprocess.run(
                ["git"] + cwd_based, capture_output=True, text=True, timeout=30
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            continue
        if out:
            path = os.path.abspath(out)
            roots.append(os.path.dirname(path) if path.endswith(".git") else path)
    seen, ordered = set(), []
    for root in roots:
        if root not in seen and os.path.isdir(os.path.join(root, ".aimi")):
            seen.add(root)
            ordered.append(root)
    return ordered


def tasks_plans(explicit_root):
    """(path, stories) for every tasks document under the first root that has .aimi/."""
    roots = _aimi_roots(explicit_root)
    if not roots:
        return []
    plans = []
    pattern = os.path.join(roots[0], ".aimi", "**", "*tasks*.json")
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, encoding="utf-8") as handle:
                document = json.load(handle)
        except (OSError, ValueError):
            continue
        stories = document.get("userStories") if isinstance(document, dict) else None
        if isinstance(stories, list) and stories:
            plans.append((path, [s for s in stories if isinstance(s, dict)]))
    return plans


def percentile(values, q):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))]


def fired(stories):
    """Advisory entries the current constants produce for one plan's stories."""
    keyed = []
    for position, story in enumerate(stories):
        story = dict(story)
        story["id"] = story.get("id") or "US-" + str(position + 1).zfill(3)
        keyed.append(story)
    return SM.advisory_story_smells(keyed)


def table(label, plans):
    sizes = [SM.story_bytes(s) for _, stories in plans for s in stories]
    ratios = [
        r
        for _, stories in plans
        for r in (SM.field_overlap_ratio(s) for s in stories)
        if r is not None
    ]
    print("== " + label + ": " + str(len(plans)) + " plans, " + str(len(sizes)) + " stories")
    if sizes:
        print(
            "   bytes: min %d p50 %d p90 %d max %d"
            % (min(sizes), percentile(sizes, 0.5), percentile(sizes, 0.9), max(sizes))
        )
        for floor in (12288, 14336, 16384):
            print("   bytes > %d: %d" % (floor, sum(1 for b in sizes if b > floor)))
    if ratios:
        print(
            "   overlap n=%d over %d eligible stories: p50 %.2f p90 %.2f p95 %.2f max %.2f"
            % (
                SM.FIELD_OVERLAP_NGRAM,
                len(ratios),
                percentile(ratios, 0.5),
                percentile(ratios, 0.9),
                percentile(ratios, 0.95),
                max(ratios),
            )
        )
        for n in (3, 4, 5):
            at_n = [
                r
                for _, stories in plans
                for r in (SM.field_overlap_ratio(s, n) for s in stories)
                if r is not None
            ]
            print("   overlap n=%d: max %.2f p95 %.2f" % (n, max(at_n), percentile(at_n, 0.95)))
    entries = [e for _, stories in plans for e in fired(stories)]
    print(
        "   fires at current constants: "
        + ", ".join("%s %d" % (t, sum(1 for e in entries if e["type"] == t)) for t in SMELL_TYPES)
    )
    multi = [stories for _, stories in plans if len(stories) >= 3]
    ratio_over_median = 0
    for stories in multi:
        median = statistics.median(SM.story_bytes(s) for s in stories)
        ratio_over_median += sum(1 for s in stories if SM.story_bytes(s) > 2 * median)
    print("   stories above 2x their plan median (plans of 3+): %d" % ratio_over_median)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--aimi-root")
    parser.add_argument("--plan", default=DEFAULT_PLAN_GLOB)
    args = parser.parse_args(argv)

    golden = golden_plans()
    tasks = tasks_plans(args.aimi_root)
    reference_plan = [
        (path, stories)
        for path, stories in tasks
        if fnmatch.fnmatch(os.path.basename(path), args.plan + ".json")
        or fnmatch.fnmatch(os.path.basename(path), args.plan)
    ]

    if not args.check:
        print("SMELL_CALIBRATION_AS_OF = " + SM.SMELL_CALIBRATION_AS_OF)
        table("golden story_merge cases", golden)
        if tasks:
            table("tasks files under .aimi/", tasks)
            table("#164 reference plan (" + args.plan + ")", reference_plan)
        else:
            print("== no .aimi/ tasks files found; golden corpus only")
        return 0

    failures = []
    for label, stories in golden:
        for entry in fired(stories):
            failures.append("golden case %s: %s on %s" % (label, entry["type"], entry["storyId"]))
    if not reference_plan:
        print(
            "calibrate_story_smells: the #164 reference plan (%s) was not found under .aimi/;"
            " its half of --check did not run" % args.plan,
            file=sys.stderr,
        )
    for path, stories in reference_plan:
        firing = {e["type"] for e in fired(stories)}
        if firing != EXPECTED_REFERENCE_TYPES:
            failures.append(
                "%s: fires %s, expected exactly %s"
                % (
                    os.path.basename(path),
                    sorted(firing) or "nothing",
                    sorted(EXPECTED_REFERENCE_TYPES),
                )
            )
    for line in failures:
        print("calibrate_story_smells: FIRES " + line, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
