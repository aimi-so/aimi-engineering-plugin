#!/usr/bin/env python3
"""deps_recipe.py -- the writer half of the dependency-install recipe.

`_detect_dependency_installer` (worktree-manager.sh) reads
`dependencies.install[<project key>]` out of `<AIMI_ROOT>/.aimi/config.json`
and runs it when the repository's own manifests do not decide. This module is
the one place that writes that key, behind `aimi-cli.sh deps-recipe-record`.

Shaped like models.py: an `_OPS` table, `main(argv)`, usage at exit 2. One op,
`record --config <path> --project <key> --command <text>`.

The wrapper in aimi-cli.sh owns the flags, `check_python3` and the lock; this
module makes the whole read-merge-write inside that lock, in one crossing.

WHAT IT REFUSES, AND WHY THE SET IS WIDER THAN THE READER'S
-----------------------------------------------------------
The reader treats a recipe holding any of `; | & $ < > `` ` `` or a newline as
"not a plain command" and refuses to run it. The writer refuses the same set
plus every other control character, so it never records a command the reader
would then reject. A key is refused when it is absolute or has a `..` segment,
a backslash or a control character. A config that is not valid JSON, not an
object, or whose `dependencies` / `dependencies.install` is not an object is
refused untouched, because rewriting it would destroy what it holds.

A `.aimi/config.json` tracked by git is refused as well: the reader never
trusts a recipe in a tracked file, so recording one would be a write that is
ignored. The probe mirrors the reader's `_dep_config_tracked`.
"""

import json
import os
import subprocess
import sys
import tempfile

VERB = "deps-recipe-record"
COMMAND_MAXLEN = 512
FORBIDDEN_COMMAND_CHARS = set(";|&$<>`")


class Refusal(Exception):
    """A reason the record is refused; the config stays as it was."""


def _has_control(text):
    return any(ord(c) < 32 or ord(c) == 127 for c in text)


def validate_command(command):
    if not isinstance(command, str):
        raise Refusal("--command is required")
    trimmed = command.strip()
    if not trimmed:
        raise Refusal("--command is blank")
    if len(trimmed) > COMMAND_MAXLEN:
        raise Refusal("--command is longer than %d characters" % COMMAND_MAXLEN)
    if _has_control(trimmed):
        raise Refusal("--command holds a control character")
    if any(c in FORBIDDEN_COMMAND_CHARS for c in trimmed):
        raise Refusal("--command is not a plain command (it holds one of ; | & $ < > or a backtick)")
    return trimmed


def validate_key(key):
    if not isinstance(key, str) or not key.strip():
        raise Refusal("--project is required")
    if key.startswith("/"):
        raise Refusal("--project must be a relative key, not an absolute path")
    if "\\" in key:
        raise Refusal("--project holds a backslash")
    if _has_control(key):
        raise Refusal("--project holds a control character")
    if ".." in key.split("/"):
        raise Refusal("--project has a '..' segment")
    return key


def config_is_tracked(config):
    """True when git tracks <config>, or when git could not say.

    Exit 0 is tracked, exit 1 untracked; any other exit reads as tracked unless
    `git rev-parse --git-dir` then says this is not a git repository, which is
    the multi-repo layout and is trusted.
    """
    directory = os.path.dirname(os.path.abspath(config))
    if not os.path.isdir(directory):
        return False
    env = dict(os.environ, LC_ALL="C")
    try:
        rc = subprocess.run(
            ["git", "-C", directory, "ls-files", "--error-unmatch", "--", os.path.basename(config)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        ).returncode
    except OSError:
        return False
    if rc == 0:
        return True
    if rc == 1:
        return False
    try:
        probe = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--git-dir"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, text=True,
        )
    except OSError:
        return False
    return "not a git repository" not in (probe.stderr or "")


def _read_config(config):
    if not os.path.exists(config):
        return {}
    try:
        with open(config, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise Refusal("%s is not valid JSON (%s)" % (config, exc.__class__.__name__))
    if not isinstance(doc, dict):
        raise Refusal("%s is not a JSON object" % config)
    return doc


def _write_atomically(config, doc):
    directory = os.path.dirname(os.path.abspath(config))
    os.makedirs(directory, exist_ok=True)
    if os.path.exists(config):
        mode = os.stat(config).st_mode & 0o777
    else:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".config.json.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, mode)
        os.replace(tmp, config)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def record(config, project, command):
    """Record <command> under dependencies.install[<project>]; return the report."""
    key = validate_key(project)
    cmd = validate_command(command)
    if config_is_tracked(config):
        raise Refusal(
            "%s is tracked by git, so a recipe recorded there would not be trusted; "
            "untrack it or add it to .gitignore first" % config
        )
    doc = _read_config(config)
    deps = doc.get("dependencies")
    if "dependencies" in doc and not isinstance(deps, dict):
        raise Refusal("dependencies in %s is not an object" % config)
    install = deps.get("install") if isinstance(deps, dict) else None
    if isinstance(deps, dict) and "install" in deps and not isinstance(install, dict):
        raise Refusal("dependencies.install in %s is not an object" % config)

    report = {"status": "recorded", "project": key, "command": cmd, "config": config}
    if isinstance(install, dict) and install.get(key) == cmd:
        report["status"] = "unchanged"
        return report

    if not isinstance(deps, dict):
        deps = {}
        doc["dependencies"] = deps
    if not isinstance(install, dict):
        install = {}
        deps["install"] = install
    install[key] = cmd
    _write_atomically(config, doc)
    return report


def _op_record(args):
    values = {"--config": None, "--project": None, "--command": None}
    i = 0
    while i < len(args):
        flag = args[i]
        if flag not in values or i + 1 >= len(args):
            sys.stderr.write("Error: %s: unknown or incomplete flag: %s\n" % (VERB, flag))
            return 1
        values[flag] = args[i + 1]
        i += 2
    if not values["--config"]:
        sys.stderr.write("Error: %s: --config is required\n" % VERB)
        return 1
    try:
        report = record(values["--config"], values["--project"], values["--command"])
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (VERB, exc))
        return 1
    except OSError as exc:
        sys.stderr.write("Error: %s: cannot write %s (%s)\n" % (VERB, values["--config"], exc.__class__.__name__))
        return 1
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 0


_OPS = {"record": _op_record}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: deps_recipe.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
