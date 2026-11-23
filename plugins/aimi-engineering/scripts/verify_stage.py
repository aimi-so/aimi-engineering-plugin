#!/usr/bin/env python3
"""verify_stage.py -- the reader behind `aimi-cli.sh verify-stage-declared`.

A project whose own verification commands tell apart WHERE they run may say so
in `<AIMI_ROOT>/.aimi/config.json`:

    {"verifyStage": {"<project key>": true}}

`.` is the single-repo project key. The declaration means: this project's
commands read `AIMI_VERIFY_STAGE` and leave out, when its value is `worktree`,
the checks that cannot run beside a sibling story's (an end-to-end suite that
owns one test database, containers with fixed names, a fixed port). They run
them when the value is `merged`.

/aimi:execute is the consumer. It exports `worktree` to the story workers of a
declared project that run in parallel worktrees, exports `merged` in the
integrated wave check that follows the merge, and never skips that check for a
declared project, because it is the only place those checks run.

ABSENCE IS NOT AN ERROR. No config, no `verifyStage` key and no entry for the
requested project all answer `staged: false`. Anything present but malformed
is refused, naming the config file: a typo must not read as "not declared" and
quietly put the end-to-end suite back into every parallel worktree.

Read-only. It runs no command and never writes the config. A tracked config is
not refused, unlike bookkeeping's: this declaration decides no file content and
runs nothing, it only withholds a skip and sets one variable.

One op, `declared --config <path> --project <key>`, shaped like
bookkeeping_declared.py: an `_OPS` table, `main(argv)`, usage at exit 2.
"""

import json
import os
import sys

VERB = "verify-stage-declared"
KEY = "verifyStage"


class VerifyStageError(ValueError):
    """A malformed verifyStage declaration."""


def load_declaration(config_path, project_key):
    """True when project_key declares stage-aware verification, else False."""
    config = str(config_path)
    if not os.path.exists(config):
        return False
    try:
        with open(config, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError, RecursionError) as exc:
        raise VerifyStageError("%s is not valid JSON (%s)" % (config, exc.__class__.__name__))
    if not isinstance(doc, dict):
        raise VerifyStageError("%s is not a JSON object" % config)
    if KEY not in doc:
        return False
    declared = doc[KEY]
    if not isinstance(declared, dict):
        raise VerifyStageError("%s: %s is not an object" % (config, KEY))
    if project_key not in declared:
        return False
    value = declared[project_key]
    if not isinstance(value, bool):
        raise VerifyStageError(
            "%s: %s for project %r is not true or false" % (config, KEY, project_key)
        )
    return value


def _parse(args):
    config = project = None
    i = 0
    while i < len(args):
        flag = args[i]
        if flag not in ("--config", "--project") or i + 1 >= len(args):
            return None
        if flag == "--config":
            config = args[i + 1]
        else:
            project = args[i + 1]
        i += 2
    if config is None or project is None:
        return None
    return config, project


def _declared(args):
    parsed = _parse(args)
    if parsed is None:
        sys.stderr.write("Usage: verify_stage.py declared --config <path> --project <key>\n")
        return 2
    config, project = parsed
    try:
        staged = load_declaration(config, project)
    except VerifyStageError as exc:
        sys.stderr.write("Error: %s: %s\n" % (VERB, exc))
        return 1
    sys.stdout.write(json.dumps({"project": project, "staged": staged}, ensure_ascii=False) + "\n")
    return 0


_OPS = {"declared": _declared}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: verify_stage.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
