#!/usr/bin/env python3
"""bookkeeping.py -- the reader of a project's declared bookkeeping files.

A project may declare, in `<AIMI_ROOT>/.aimi/config.json`, the repository files
that every story touches by design (a changelog, a version manifest) and the
rule that reconciles concurrent edits to each:

    {"bookkeeping": {"<project key>": {"<path>": {"rule": "<kind>"}}}}

`.` is the single-repo project key. `load_declaration` is the one reader, so
every later verb trusts one validated declaration and behaves as before when
none exists.

ABSENCE IS NOT AN ERROR. No config, no `bookkeeping` key or no entry for the
requested project all return {}. Anything present but malformed raises
BookkeepingError naming the config file.

A config that carries a declaration and is tracked by git is refused: a rule is
never honoured from a tracked file. The probe is `deps_recipe.config_is_tracked`
and runs only when the config actually declares something.

Read-only: nothing here writes the config or runs a command but the git probe.
Only the requested project's entry is validated, so an unrelated key never
refuses this project. Paths are validated lexically here so later joins to a
repository root need no fresh check.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import deps_recipe  # noqa: E402

RULE_KINDS = ("union-lines", "max-version", "sum-delta", "size-step")
_ENTRY_KEYS = {"rule"}


class BookkeepingError(ValueError):
    """A malformed or untrusted bookkeeping declaration."""


def _has_control(text):
    return any(ord(c) < 32 or ord(c) == 127 for c in text)


def _validate_path(config, path):
    reason = None
    if not isinstance(path, str) or not path:
        reason = "is empty"
    elif path.startswith("/"):
        reason = "is absolute"
    elif path.startswith("./"):
        reason = "starts with './'"
    elif "\\" in path:
        reason = "holds a backslash"
    elif _has_control(path):
        reason = "holds a control character"
    elif ".." in path.split("/"):
        reason = "has a '..' segment"
    if reason:
        raise BookkeepingError("%s: bookkeeping path %r %s" % (config, path, reason))
    return path


def _validate_entry(config, path, entry):
    if not isinstance(entry, dict):
        raise BookkeepingError("%s: bookkeeping entry for %r is not an object" % (config, path))
    rule = entry.get("rule")
    if not isinstance(rule, str):
        raise BookkeepingError("%s: bookkeeping entry for %r has a missing or non-string rule" % (config, path))
    if rule not in RULE_KINDS:
        raise BookkeepingError(
            "%s: bookkeeping entry for %r has unknown rule %r (expected one of %s)"
            % (config, path, rule, ", ".join(RULE_KINDS))
        )
    extra = sorted(set(entry) - _ENTRY_KEYS)
    if extra:
        raise BookkeepingError("%s: bookkeeping entry for %r has extra key(s): %s" % (config, path, ", ".join(extra)))
    return rule


def load_declaration(config_path, project_key):
    """Return {path: rule kind} declared for project_key, in declaration order."""
    config = str(config_path)
    if not os.path.exists(config):
        return {}
    try:
        with open(config, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise BookkeepingError("%s is not valid JSON (%s)" % (config, exc.__class__.__name__))
    if not isinstance(doc, dict):
        raise BookkeepingError("%s is not a JSON object" % config)
    if "bookkeeping" not in doc:
        return {}
    declared = doc["bookkeeping"]
    if not isinstance(declared, dict):
        raise BookkeepingError("%s: bookkeeping is not an object" % config)
    if deps_recipe.config_is_tracked(config):
        raise BookkeepingError(
            "%s is tracked by git and carries a bookkeeping declaration: a tracked config is not trusted" % config
        )
    if project_key not in declared:
        return {}
    project = declared[project_key]
    if not isinstance(project, dict):
        raise BookkeepingError("%s: bookkeeping for project %r is not an object" % (config, project_key))
    result = {}
    for path, entry in project.items():
        _validate_path(config, path)
        result[path] = _validate_entry(config, path, entry)
    return result
