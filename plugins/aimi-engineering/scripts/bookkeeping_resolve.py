#!/usr/bin/env python3
"""bookkeeping_resolve.py -- the writer behind `aimi-cli.sh bookkeeping-resolve`.

In a repository that is mid-merge, resolves the project's DECLARED bookkeeping
files (`bookkeeping.load_declaration`) by their declared rule
(`bookkeeping_rules.resolve_by_rule`) and writes the merged text into the
working tree. Shaped like deps_recipe.py: an `_OPS` table, `main(argv)`, usage
at exit 2. One op, `resolve --config <path> --root <dir> --project <key>`.

WHAT IT READS. Each declared path that is unmerged in the index is read from
its index stages (base :1, ours :2, theirs :3; a missing stage is None), never
from the working tree's conflict markers. A declared path that is not
conflicted, and a conflicted path that is not declared, is neither read nor
written. Paths match by exact string equality, relative to --root, which must
be the repository's top level.

WHAT IT DOES NOT DO. It stages nothing: a resolved file stays unmerged in the
index until the caller adds it, so a re-run starts from the same stages and
prints the same answer.

BUCKETS, decided by `RuleRefusal.kind` alone (never by reason text):

    resolved   {path, rule, changes}      written in one pass
    unclaimed  {path, rule, reason}       left byte-identical and conflicted
    refused    {path, rule, kind, reason} stops the verb: exit 1, NOTHING written

All resolutions are computed in memory first and written only when `refused` is
empty, each through a temp file beside the target and os.replace; a write that
fails restores the files already replaced.
"""

import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bookkeeping  # noqa: E402
import bookkeeping_rules  # noqa: E402

VERB = "bookkeeping-resolve"
USAGE = "Usage: aimi-cli.sh bookkeeping-resolve [--project <key>] [--root <dir>]"
_REGULAR_MODES = ("100644", "100755")


def _git(root, *args):
    env = dict(os.environ, LC_ALL="C")
    return subprocess.run(["git", "-C", root, *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env)


def _top_level_ok(root):
    if not os.path.isdir(root):
        return False
    res = _git(root, "rev-parse", "--show-toplevel")
    if res.returncode != 0:
        return False
    top = res.stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    return os.path.realpath(top) == os.path.realpath(root)


def _unmerged(root):
    """Return {path: {stage: (mode, sha)}} for every unmerged index entry."""
    res = _git(root, "ls-files", "-u", "-z")
    if res.returncode != 0:
        return {}
    out = {}
    for rec in res.stdout.split(b"\0"):
        if not rec:
            continue
        meta, _, raw = rec.partition(b"\t")
        parts = meta.decode("ascii", "replace").split()
        if len(parts) != 3 or not raw:
            continue
        mode, _sha, stage = parts
        path = raw.decode("utf-8", "surrogateescape")
        out.setdefault(path, {})[int(stage)] = mode
    return out


def _refusal(path, rule, reason):
    return bookkeeping_rules.RuleRefusal(path, rule, reason, "unproducible")


def _read_stage(root, path, rule, stage, modes):
    """Return the stage's text, or None when that stage does not exist."""
    mode = modes.get(stage)
    if mode is None:
        return None
    if mode not in _REGULAR_MODES:
        raise _refusal(path, rule, "stage %d is not a regular file (mode %s)" % (stage, mode))
    res = _git(root, "show", ":%d:%s" % (stage, path))
    if res.returncode != 0:
        raise _refusal(path, rule, "stage %d could not be read" % stage)
    try:
        return res.stdout.decode("utf-8")
    except UnicodeDecodeError:
        raise _refusal(path, rule, "stage %d is not valid UTF-8" % stage) from None


def _within(real_root, real_path):
    return real_path == real_root or real_path.startswith(real_root + os.sep)


def _make_measure(root, declared_path, unmerged):
    real_root = os.path.realpath(root)
    dirs = [""]
    parent = os.path.dirname(declared_path)
    while parent:
        dirs.append(parent)
        parent = os.path.dirname(parent)

    def measure(row_path):
        if (not row_path or row_path.startswith("/") or "\\" in row_path
                or any(ord(c) < 32 or ord(c) == 127 for c in row_path)
                or ".." in row_path.split("/")):
            return None
        for base in dirs:
            for sub in ("", "commands"):
                candidate = os.path.join(root, base, sub, row_path)
                real = os.path.realpath(candidate)
                if not _within(real_root, real) or not os.path.isfile(real):
                    continue
                rel = os.path.relpath(real, real_root).replace(os.sep, "/")
                if rel in unmerged:
                    return bookkeeping_rules.CONFLICTED
                try:
                    return os.path.getsize(real)
                except OSError:
                    return None
        return None

    return measure


def _target(root, path, rule):
    """The real file to write for a declared path, confined to root."""
    real_root = os.path.realpath(root)
    joined = os.path.join(root, path)
    parent = os.path.realpath(os.path.dirname(joined))
    real = os.path.join(parent, os.path.basename(joined))
    if os.path.lexists(joined):
        real = os.path.realpath(joined)
    if not _within(real_root, real):
        raise _refusal(path, rule, "resolves outside --root through a symlink")
    return real


def _mode_of(real):
    if os.path.exists(real):
        return os.stat(real).st_mode & 0o7777
    umask = os.umask(0)
    os.umask(umask)
    return 0o666 & ~umask


def _replace_with(real, data, mode):
    directory = os.path.dirname(real)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".bookkeeping.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _write_all(writes):
    """writes: [(real, new_bytes)]. Restore the replaced ones when one fails."""
    done = []
    try:
        for real, data in writes:
            original = None
            if os.path.exists(real):
                with open(real, "rb") as fh:
                    original = fh.read()
            mode = _mode_of(real)
            _replace_with(real, data, mode)
            done.append((real, original, mode))
    except BaseException:
        for real, original, mode in reversed(done):
            try:
                if original is None:
                    os.unlink(real)
                else:
                    _replace_with(real, original, mode)
            except OSError:
                pass
        raise


def resolve(config, root, project):
    """Return (report, refused_lines). Writes only when nothing is refused."""
    declared = bookkeeping.load_declaration(config, project)
    report = {"resolved": [], "unclaimed": [], "refused": []}
    if not declared:
        return report, []
    unmerged = _unmerged(root)
    resolved, writes, lines = [], [], []
    for path, rule in declared.items():
        modes = unmerged.get(path)
        if not modes:
            continue
        try:
            base = _read_stage(root, path, rule, 1, modes)
            ours = _read_stage(root, path, rule, 2, modes)
            theirs = _read_stage(root, path, rule, 3, modes)
            measure = _make_measure(root, path, unmerged)
            res = bookkeeping_rules.resolve_by_rule(rule, path, base, ours, theirs, measure)
            real = _target(root, path, rule)
        except bookkeeping_rules.RuleRefusal as ref:
            if ref.kind == "unclaimed":
                report["unclaimed"].append({"path": path, "rule": rule, "reason": ref.reason})
            else:
                report["refused"].append({"path": path, "rule": rule, "kind": ref.kind, "reason": ref.reason})
                lines.append("Error: %s: %s (%s): %s" % (VERB, path, rule, ref.reason))
            continue
        resolved.append({"path": path, "rule": rule, "changes": res.changes})
        writes.append((real, res.text.encode("utf-8")))
    if report["refused"]:
        return report, lines
    _write_all(writes)
    report["resolved"] = resolved
    return report, []


def _parse(args):
    values = {"--config": None, "--root": None, "--project": None}
    i = 0
    while i < len(args):
        flag = args[i]
        if flag not in values or i + 1 >= len(args):
            return None
        values[flag] = args[i + 1]
        i += 2
    if any(v is None for v in values.values()):
        return None
    return values


def _op_resolve(args):
    values = _parse(args)
    if values is None:
        sys.stderr.write(USAGE + "\n")
        return 1
    root = values["--root"]
    if not _top_level_ok(root):
        sys.stderr.write("Error: %s: --root %s is not the top level of a git repository\n" % (VERB, root))
        sys.stderr.write(USAGE + "\n")
        return 1
    try:
        report, lines = resolve(values["--config"], root, values["--project"])
    except bookkeeping.BookkeepingError as exc:
        sys.stderr.write("Error: %s: %s\n" % (VERB, exc))
        return 1
    except OSError as exc:
        sys.stderr.write("Error: %s: cannot write (%s)\n" % (VERB, exc.__class__.__name__))
        return 1
    for line in lines:
        sys.stderr.write(line + "\n")
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 1 if lines else 0


_OPS = {"resolve": _op_resolve}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: bookkeeping_resolve.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
