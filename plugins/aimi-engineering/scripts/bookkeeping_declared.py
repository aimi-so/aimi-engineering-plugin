#!/usr/bin/env python3
"""bookkeeping_declared.py -- the reader behind `aimi-cli.sh bookkeeping-declared`.

Prints one project key's effective bookkeeping declaration from
`<AIMI_ROOT>/.aimi/config.json` as a single JSON line, by calling
`bookkeeping.load_declaration`. Shaped like deps_recipe.py: an `_OPS` table,
`main(argv)`, usage at exit 2. One op, `declared --config <path> --project <key>`.

Absence is an answer (no file, no `bookkeeping` key, no entry for the key all
print an empty `paths`). A malformed declaration, or a git-tracked config that
carries one, is the reader's own refusal: its message goes to stderr, stdout
stays empty and the exit is 1. The module never writes.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bookkeeping  # noqa: E402

VERB = "bookkeeping-declared"


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
        sys.stderr.write("Usage: bookkeeping_declared.py declared --config <path> --project <key>\n")
        return 2
    config, project = parsed
    try:
        paths = bookkeeping.load_declaration(config, project)
    except bookkeeping.BookkeepingError as exc:
        sys.stderr.write("Error: %s: %s\n" % (VERB, exc))
        return 1
    sys.stdout.write(json.dumps({"project": project, "paths": paths}, ensure_ascii=False) + "\n")
    return 0


_OPS = {"declared": _declared}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: bookkeeping_declared.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
