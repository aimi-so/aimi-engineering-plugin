"""Measure what each kind of `/aimi:execute` run reads, in bytes.

`commands/execute.md` is a router over `commands/references/execute/`. A run
loads the router, then reads the step files whose `Applies when:` condition
holds for it. This script prints one `name=integer` line per figure:

    router             bytes of execute.md (equals `wc -c`)
    all_references     byte sum of every file under references/execute/
    router_plus_all    router + all_references
    container_execution  bytes of references/container-execution.md
                       (informational: container and phase runs read it through
                       a step file's own citation, so it is reported beside the
                       flows and not folded into them)
    flat_inline        a flat run, inline mode, in a git repository
    flat_container     a flat run, container mode, in a git repository
    phase              a phase run (phase container, no full-stack split)
    phase_split        a phase run that detected a full-stack split

Each run type is the router plus the files its row of TABLE selects. The
shared assumptions: a top-level orchestrator (not a spawned split task), one
tasks file, no visual story, no deadlock, no resume after /clear, and a
pending count that reaches zero for a phase run. A phase_split run also counts
the wave-loop files its spawned sub-orchestrators read (Spawned Tasks), since
the orchestrator hands the stories to them.

The TABLE is written by hand from the router's `Applies when:` lines. This
script does not evaluate prose; it only checks the table for coverage:

  * a file under references/execute/ missing from TABLE fails,
  * a TABLE name with no file fails,
  * a file not read by all four run types whose router entry names no
    narrowing state fails (so a file cannot silently leave the common path).

Usage: python3 measure_execute_reads.py [commands-dir]
`AIMI_EXECUTE_WIRING_ROOT` overrides the commands directory, as for
`execute_text.py`; the argument wins over it.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import execute_text  # noqa: E402

FLAT_INLINE = "flat_inline"
FLAT_CONTAINER = "flat_container"
PHASE = "phase"
PHASE_SPLIT = "phase_split"
RUN_TYPES = (FLAT_INLINE, FLAT_CONTAINER, PHASE, PHASE_SPLIT)

ALL = set(RUN_TYPES)
FLAT = {FLAT_INLINE, FLAT_CONTAINER}
PHASES = {PHASE, PHASE_SPLIT}
NOT_SPLIT = {FLAT_INLINE, FLAT_CONTAINER, PHASE}
# A split phase hands its stories to spawned sub-orchestrators; the wave loop
# they run is part of the run, so their reads are counted once, here.
SPLIT_CHILD = {PHASE_SPLIT}

# basename under references/execute/ -> run types that read it
TABLE = {
    "multi-repo-handling.md": ALL,
    "step-0-5-archival-check.md": ALL,
    "visual-follow-lifecycle.md": set(),
    "step-0-7-visual-follow-prompt.md": ALL,
    "step-0-9-split-detection.md": ALL,
    "step-0-9-split-flow.md": set(),
    "step-0-9-aggregated-completion.md": set(),
    "step-1-initialize-session.md": ALL,
    "step-1-execution-mode.md": ALL,
    "step-1-5-branch-freshness.md": ALL,
    "step-1-6-branch-base-selection.md": ALL,
    "release-claim-on-abort.md": PHASES,
    "step-1-7-claim-the-phase.md": PHASES,
    "step-1-7-phase-container.md": PHASES,
    "step-1-7-detect-split.md": PHASES,
    "step-1-7-per-group-containers.md": PHASES,
    "step-1-7-dev-server-and-notes.md": PHASES,
    "paired-split-branches-and-worktrees.md": {PHASE_SPLIT},
    "paired-split-dev-server-and-spawn.md": {PHASE_SPLIT},
    "paired-split-merge-and-continue.md": {PHASE_SPLIT},
    "step-2-flat-container.md": {FLAT_CONTAINER},
    "step-2-main-repo-branch-setup.md": {FLAT_INLINE},
    "step-2-per-project-branch-setup.md": FLAT,
    "step-3-check-pending.md": NOT_SPLIT | SPLIT_CHILD,
    "step-3-1-3-2-worktree-and-concurrency.md": NOT_SPLIT | SPLIT_CHILD,
    "step-3-3-guidelines-and-dev-server.md": NOT_SPLIT | SPLIT_CHILD,
    "step-3-3-open-visual-follow.md": set(),
    "step-4-wave-execution-loop.md": NOT_SPLIT | SPLIT_CHILD,
    "step-4-post-loop-cleanup.md": NOT_SPLIT | SPLIT_CHILD,
    "step-4-finalize.md": NOT_SPLIT,
    "console-error-attribution.md": set(),
    "phase-completion-pending-count.md": PHASES,
    "phase-completion-creates-verification.md": PHASES,
    "phase-completion-visual-gate.md": PHASES,
    "phase-completion-handoff-and-mark.md": PHASES,
    "phase-completion-offer-pull-request.md": PHASES,
    "phase-completion-next-phase.md": PHASES,
    "step-5-completion.md": NOT_SPLIT,
    "step-5-deadlock.md": set(),
    "resuming-and-error-recovery.md": set(),
}

# A router entry narrows when its text names state that differs between runs.
NARROWING = re.compile(
    r"PHASE_MODE|PHASE_SPLIT_MODE|CONTAINER_MODE|AIMI_ROOT_IS_GIT_REPO|"
    r"SPAWNED_SPLIT_TASK|VISUAL_FOLLOW|VISUAL_STORIES|visual story|"
    r"split-detect|activeCount|pending count|Re-verify|deadlock|/clear|resumes|"
    r"abandoned"
)

READ_LINE = re.compile(
    r"Read \$\{CLAUDE_PLUGIN_ROOT\}/commands/references/execute/([A-Za-z0-9._-]+\.md) in full"
)
HEADING = re.compile(r"^#{1,6}[ \t]+\S")


def entry_texts(router):
    """{basename: text from the nearest heading above its Read line to that line}."""
    lines = router.split("\n")
    flags = [in_fence for _, in_fence in execute_text.scan_lines(router)]
    found = {}
    start = 0
    for i, line in enumerate(lines):
        if flags[i]:
            continue
        if HEADING.match(line):
            start = i
            continue
        m = READ_LINE.search(line)
        if m:
            found.setdefault(m.group(1), "\n".join(lines[start:i + 1]))
    return found


def check(commands):
    refs_dir = Path(commands) / "references" / "execute"
    files = sorted(p.name for p in refs_dir.glob("*.md")) if refs_dir.is_dir() else []
    problems = []
    for name in files:
        if name not in TABLE:
            problems.append("references/execute/%s is missing from TABLE" % name)
    for name in TABLE:
        if name not in files:
            problems.append("TABLE names %s but references/execute has no such file" % name)
    router_path = Path(commands) / "execute.md"
    entries = entry_texts(router_path.read_text(encoding="utf-8")) if router_path.is_file() else {}
    for name, runs in TABLE.items():
        if runs == ALL:
            continue
        text = entries.get(name)
        if text is None:
            problems.append("no router Read line names %s" % name)
        elif not NARROWING.search(text):
            problems.append(
                "%s is not read by all four run types but its router entry names no narrowing state" % name
            )
    return files, problems


def size(path):
    return len(Path(path).read_bytes())


def measure(commands):
    base = Path(commands)
    files, problems = check(base)
    if problems:
        return None, problems
    router = size(base / "execute.md")
    sizes = {name: size(base / "references" / "execute" / name) for name in files}
    all_references = sum(sizes.values())
    figures = [
        ("router", router),
        ("all_references", all_references),
        ("router_plus_all", router + all_references),
        ("container_execution", size(base / "references" / "container-execution.md")),
    ]
    for run in RUN_TYPES:
        figures.append((run, router + sum(sizes[n] for n in files if run in TABLE[n])))
    return figures, []


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    commands = argv[0] if argv else str(execute_text.commands_dir())
    figures, problems = measure(commands)
    if problems:
        for p in problems:
            print("FAIL: " + p, file=sys.stderr)
        return 1
    for name, value in figures:
        print("%s=%d" % (name, value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
