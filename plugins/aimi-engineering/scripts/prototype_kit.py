#!/usr/bin/env python3
"""inspect-prototype-kit and import-prototype-kit: look at, and safely copy, a prototype kit.

A prototype kit is a third-party folder of HTML screens (optionally with
markdown notes and assets), handed over as a directory or a .zip. The two verbs
let brainstorm record such a kit under `.aimi/sources/` without extracting an
untrusted archive by hand and without touching the operator's original files.

    prototype_kit.py inspect <path> --aimi-dir <dir>
    prototype_kit.py import  <path> --aimi-dir <dir> [--slug <s>]

THE MANIFEST
============

Both verbs first build a full member manifest in memory and write nothing. Every
byte is read through a bounded streaming read that counts the bytes ACTUALLY
read (never the header's claimed size) and, for a zip, lets `zipfile` check the
CRC. A single top-level folder is flattened away, so member names are relative
to the kit. `__MACOSX/` members and `.DS_Store` files are skipped: they are not
copied and not counted.

TWO KINDS OF REFUSAL
====================

Archive-level (exit 1, a reason on stderr, nothing on stdout or disk, from both
verbs): a path that is neither a directory nor a .zip, a corrupt zip, an
encrypted member, a non-ASCII member name without the UTF-8 flag, more entries
than MAX_ENTRIES, more bytes than MAX_TOTAL_BYTES, a member that is neither a
regular file nor a directory, and two members that flatten to one name.

Member-level: a member with an absolute name or a `..` segment, a symlink, a
member under `.git/` or `.claude/`, or one named CLAUDE.md, AGENTS.md or
settings.json (compared case-insensitively). `inspect` lists each as
`{member, reason}` in `refused` and answers `qualifies: false`; `import`
refuses the whole kit at exit 1 naming each, before anything is written.

THE COPY
========

`import` writes into a `tempfile.mkdtemp` directory under `.aimi/sources/`
(every file opened with mode `xb` after a resolved-path-inside-the-temp-dir
check) and renames it to `<slug>-<hash8>`. hash8 is the first eight hex digits
of a SHA-256 over the sorted member names and bytes, so identical content maps
to the same directory: a final directory that already exists is a complete
earlier copy, the temp directory is dropped and `reused` is true.

This module is run with `python3 -I`, which drops the script directory from
sys.path, so it inserts its own realpath directory before importing `slug`.
"""

import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import zipfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from slug import slugify  # noqa: E402

MAX_ENTRIES = 2000
MAX_TOTAL_BYTES = 64 * 1024 * 1024
_CHUNK = 64 * 1024

_FORBIDDEN_DIRS = {".git", ".claude"}
_FORBIDDEN_NAMES = {"claude.md", "agents.md", "settings.json"}
_DRIVE = re.compile(r"^[A-Za-z]:")


class KitError(Exception):
    """An archive-level refusal: nothing is reported or written."""


def _segments(name):
    return [s for s in name.replace("\\", "/").split("/") if s not in ("", ".")]


def _unsafe_name(name):
    """The reason `name` escapes the kit, or None."""
    if name.startswith(("/", "\\")) or _DRIVE.match(name):
        return "absolute member name"
    if ".." in name.replace("\\", "/").split("/"):
        return "'..' path segment"
    return None


def _skipped(segments):
    return bool(segments) and (segments[0] == "__MACOSX" or segments[-1] == ".DS_Store")


def _name_refusal(segments):
    for seg in segments[:-1] + segments[-1:]:
        if seg.lower() in _FORBIDDEN_DIRS:
            return "member under %s/" % seg
    if segments and segments[-1].lower() in _FORBIDDEN_NAMES:
        return "forbidden file name %s" % segments[-1]
    return None


class _Budget:
    def __init__(self):
        self.total = 0

    def take(self, n):
        self.total += n
        if self.total > MAX_TOTAL_BYTES:
            raise KitError(
                "kit holds more than %d uncompressed bytes" % MAX_TOTAL_BYTES
            )


def _read_stream(fh, budget):
    parts = []
    while True:
        chunk = fh.read(_CHUNK)
        if not chunk:
            break
        budget.take(len(chunk))
        parts.append(chunk)
    return b"".join(parts)


def _collect_folder(root):
    """[(raw_name, kind, loader)] for an on-disk kit, never following links."""
    found = []
    for cur, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames) + list(filenames):
            full = os.path.join(cur, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            mode = os.lstat(full).st_mode
            if stat.S_ISLNK(mode):
                found.append((rel, "symlink", None))
            elif stat.S_ISDIR(mode):
                continue
            elif stat.S_ISREG(mode):
                found.append((rel, "file", full))
            else:
                raise KitError("member %s is not a regular file" % rel)
            if len(found) > MAX_ENTRIES:
                raise KitError("kit holds more than %d entries" % MAX_ENTRIES)
    return found


def _collect_zip(zf):
    infos = zf.infolist()
    if len(infos) > MAX_ENTRIES:
        raise KitError("archive holds more than %d entries" % MAX_ENTRIES)
    found = []
    for info in infos:
        name = info.filename
        if info.flag_bits & 0x1:
            raise KitError("encrypted member: %s" % name)
        if not (info.flag_bits & 0x800) and any(ord(c) > 127 for c in name):
            raise KitError(
                "non-ASCII member name without the UTF-8 flag: %r" % name
            )
        mode = (info.external_attr >> 16) & 0o170000
        if info.is_dir():
            kind = "dir"
        elif mode == 0o120000:
            kind = "symlink"
        elif mode not in (0, 0o100000):
            raise KitError("member %s is not a regular file" % name)
        else:
            kind = "file"
        found.append((name, kind, info if kind == "file" else None))
    return found


def _build_manifest(path):
    """({flattened name: bytes}, [{member, reason}], kind). Writes nothing."""
    budget = _Budget()
    if os.path.isdir(path):
        kind = "folder"
        entries = _collect_folder(path)

        def load(handle):
            with open(handle, "rb") as fh:
                return _read_stream(fh, budget)

        zf = None
    elif os.path.isfile(path) and path.lower().endswith(".zip"):
        kind = "zip"
        try:
            zf = zipfile.ZipFile(path)
        except (zipfile.BadZipFile, OSError, EOFError, zipfile.LargeZipFile) as exc:
            raise KitError("corrupt zip: %s" % exc)
        entries = _collect_zip(zf)

        def load(handle):
            with zf.open(handle) as fh:
                return _read_stream(fh, budget)

    else:
        raise KitError("not a directory or a .zip file: %s" % path)

    refused = []
    kept = []  # (raw, segments, loader handle)
    for raw, ekind, handle in entries:
        reason = _unsafe_name(raw)
        segs = _segments(raw)
        if reason is None and _skipped(segs):
            continue
        if ekind == "dir":
            if reason is None:
                reason = _name_refusal(segs)
            if reason:
                refused.append({"member": raw, "reason": reason})
            continue
        if reason is None and ekind == "symlink":
            reason = "symlink"
        if reason is None:
            reason = _name_refusal(segs)
        if reason:
            refused.append({"member": raw, "reason": reason})
            continue
        kept.append((raw, segs, handle))

    strip = 0
    if kept and all(len(s) >= 2 for _, s, _ in kept) and len({s[0] for _, s, _ in kept}) == 1:
        strip = 1

    members = {}
    try:
        for raw, segs, handle in kept:
            name = "/".join(segs[strip:])
            if name in members:
                raise KitError("two members flatten to the same name: %s" % name)
            members[name] = load(handle)
    except (zipfile.BadZipFile, zlib.error, EOFError, NotImplementedError, RuntimeError) as exc:
        raise KitError("corrupt zip: %s" % exc)
    finally:
        if zf is not None:
            zf.close()
    return members, refused, kind


def _classify(members):
    html, md, other = [], [], []
    for name in sorted(members):
        low = name.lower()
        if low.endswith(".html"):
            html.append(name)
        elif low.endswith(".md"):
            md.append(name)
        else:
            other.append(name)
    return html, md, other


def _content_hash(members):
    h = hashlib.sha256()
    for name in sorted(members):
        data = members[name]
        h.update(name.encode("utf-8"))
        h.update(b"\0")
        h.update(str(len(data)).encode("ascii"))
        h.update(b"\0")
        h.update(data)
    return h.hexdigest()


def _fail(verb, message):
    sys.stderr.write("Error: %s: %s\n" % (verb, message))
    return 1


def _parse(argv, verb, with_slug):
    path = None
    aimi_dir = None
    slug = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--aimi-dir" and i + 1 < len(argv):
            aimi_dir = argv[i + 1]
            i += 2
        elif with_slug and arg == "--slug" and i + 1 < len(argv):
            slug = argv[i + 1]
            i += 2
        elif arg.startswith("--"):
            raise ValueError("unknown or incomplete flag: %s" % arg)
        elif path is None:
            path = arg
            i += 1
        else:
            raise ValueError("exactly one kit path is accepted")
    if path is None:
        raise ValueError("a kit path is required")
    if not aimi_dir:
        raise ValueError("--aimi-dir is required")
    return path, os.path.abspath(aimi_dir), slug


def _inspect(argv):
    verb = "inspect-prototype-kit"
    try:
        path, _aimi_dir, _ = _parse(argv, verb, False)
        members, refused, kind = _build_manifest(path)
    except ValueError as exc:
        return _fail(verb, str(exc))
    except KitError as exc:
        return _fail(verb, str(exc))
    html, md, other = _classify(members)
    out = {
        "kind": kind,
        "htmlFiles": html,
        "markdownFiles": md,
        "otherFiles": other,
        "refused": refused,
        "qualifies": bool(html) and not refused,
    }
    sys.stdout.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    return 0


def _write_tree(members, sources_dir):
    os.makedirs(sources_dir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=".tmp-kit-", dir=sources_dir)
    try:
        tmp_real = os.path.realpath(tmp)
        for name, data in members.items():
            target = os.path.realpath(os.path.join(tmp_real, name))
            if not target.startswith(tmp_real + os.sep):
                raise KitError("member escapes the copy directory: %s" % name)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "xb") as fh:
                fh.write(data)
        os.chmod(tmp, 0o755)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return tmp


def _import(argv):
    verb = "import-prototype-kit"
    try:
        path, aimi_dir, slug_arg = _parse(argv, verb, True)
        members, refused, _kind = _build_manifest(path)
    except ValueError as exc:
        return _fail(verb, str(exc))
    except KitError as exc:
        return _fail(verb, str(exc))

    if refused:
        for item in refused:
            sys.stderr.write(
                "Error: %s: refused member %s: %s\n" % (verb, item["member"], item["reason"])
            )
        return 1
    html, md, other = _classify(members)
    if not html:
        return _fail(verb, "the kit holds no .html member")

    if slug_arg is not None:
        slug = slugify(slug_arg)
    else:
        base = os.path.basename(os.path.normpath(path))
        if base.lower().endswith(".zip"):
            base = base[:-4]
        slug = slugify(base)
    if not slug:
        return _fail(verb, "no ASCII letter or digit to build a directory slug from")

    dirname = "%s-%s" % (slug, _content_hash(members)[:8])
    sources_dir = os.path.join(aimi_dir, "sources")
    final = os.path.join(sources_dir, dirname)
    reused = os.path.isdir(final)
    if not reused:
        try:
            tmp = _write_tree(members, sources_dir)
        except KitError as exc:
            return _fail(verb, str(exc))
        try:
            os.rename(tmp, final)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)
            if not os.path.isdir(final):
                return _fail(verb, "could not place the copy at %s" % final)
            reused = True

    rel = ".aimi/sources/" + dirname
    out = {
        "dir": rel,
        "htmlFiles": [rel + "/" + n for n in html],
        "markdownFiles": [rel + "/" + n for n in md],
        "otherFiles": [rel + "/" + n for n in other],
        "reused": reused,
    }
    sys.stdout.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] not in ("inspect", "import"):
        sys.stderr.write("usage: prototype_kit.py (inspect|import) <path> --aimi-dir <dir>\n")
        return 1
    return _inspect(argv[2:]) if argv[1] == "inspect" else _import(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
