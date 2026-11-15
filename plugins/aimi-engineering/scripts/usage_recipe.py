#!/usr/bin/env python3
"""usage_recipe.py -- the usage recipe: how to bring the whole product up.

A usage recipe is what a person confirmed about starting one project for
real-usage validation: setup steps, the serve command (or a CLI), the
readiness URL, the login, the browser and the cleanup. It lives at
`usage.recipe[<project key>]` of `<AIMI_ROOT>/.aimi/config.json`, beside
`dependencies.install[<project key>]` and under the same key rule, so one key
serves both recipes.

Shaped like deps_recipe.py, whose command, key and tracked-config rules it
imports rather than copies: an `_OPS` table, `main(argv)`, usage at exit 2.
Two ops:

  record --config <path> --project <key> [--serve C] [--cli C] [--setup C]...
         [--cleanup C]... [--port N] [--ready URL] [--login none|manual]
         [--login-url URL] [--browser agent-browser|chrome]
         [--external-services TEXT]
  get    --config <path> --project <key>

The wrapper in aimi-cli.sh owns the flags, `check_python3` and the lock; this
module makes the whole read-merge-write inside that lock, in one crossing.

NO DEFAULT IS EVER FILLED IN. A field the person did not supply is absent from
the entry and from the output, so each consumer states its own default.

`get` re-validates every stored field with the writer's validators, because a
caller will run the stored commands verbatim: a hand-edited entry that fails
is refused, never printed. It also trusts nothing in a config tracked by git,
and answers `untrusted` for it.
"""

import json
import os
import sys
from urllib.parse import urlsplit

import deps_recipe as D

Refusal = D.Refusal

RECORD_VERB = "usage-recipe-record"
GET_VERB = "usage-recipe-get"

MAX_STEPS = 20
PORT_MIN = 1024
PORT_MAX = 65535
URL_MAXLEN = 512
EXTERNAL_MAXLEN = 500
LOOPBACK_HOSTS = ("localhost", "127.0.0.1", "::1")
LOGIN_METHODS = ("none", "manual")
BROWSERS = ("agent-browser", "chrome")

# The entry's field order, which is also the order of its keys on disk.
ENTRY_FIELDS = ("setup", "serve", "cli", "port", "ready", "login", "browser", "cleanup", "externalServices")


def _command(value, label):
    """validate_command, with its `--command` refusals relabelled."""
    try:
        return D.validate_command(value)
    except Refusal as exc:
        raise Refusal(str(exc).replace("--command", label, 1))


def _steps(value, name, stored):
    flag = "--" + name
    if not isinstance(value, list):
        raise Refusal("%s is not a list" % (name if stored else flag))
    if len(value) > MAX_STEPS:
        raise Refusal("%s has more than %d steps" % (name if stored else flag, MAX_STEPS))
    out = []
    for i, step in enumerate(value, 1):
        label = ("%s[%d]" % (name, i - 1)) if stored else ("%s step %d" % (flag, i))
        out.append(_command(step, label))
    return out


def _port(value, label):
    if isinstance(value, bool):
        raise Refusal("%s must be an integer" % label)
    if isinstance(value, str):
        if not (value.isascii() and value.isdigit()):
            raise Refusal("%s must be an integer from %d to %d" % (label, PORT_MIN, PORT_MAX))
        value = int(value)
    if not isinstance(value, int):
        raise Refusal("%s must be an integer" % label)
    if not PORT_MIN <= value <= PORT_MAX:
        raise Refusal("%s must be from %d to %d" % (label, PORT_MIN, PORT_MAX))
    return value


def _loopback_url(value, label):
    """A /-prefixed path or an http(s) URL on a loopback host, with no userinfo."""
    if not isinstance(value, str) or not value.strip():
        raise Refusal("%s is blank" % label)
    if len(value) > URL_MAXLEN:
        raise Refusal("%s is longer than %d characters" % (label, URL_MAXLEN))
    if D._has_control(value) or any(c.isspace() for c in value) or "\\" in value:
        raise Refusal("%s holds whitespace, a backslash or a control character" % label)
    if value.startswith("/"):
        if value.startswith("//"):
            raise Refusal("%s is a scheme-relative URL, not a path" % label)
        return value
    try:
        parts = urlsplit(value)
        host = parts.hostname
        parts.port  # noqa: B018 -- raises ValueError on a bad port
    except ValueError:
        raise Refusal("%s is not a valid URL" % label)
    if parts.scheme not in ("http", "https"):
        raise Refusal("%s must be a /-prefixed path or an http(s) URL" % label)
    if "@" in parts.netloc:
        raise Refusal("%s must not carry userinfo" % label)
    if host not in LOOPBACK_HOSTS:
        raise Refusal(
            "%s names host %s; only localhost, 127.0.0.1 and [::1] are allowed "
            "because the run may only contact loopback origins" % (label, host or "(none)")
        )
    return value


def validate_entry(entry, stored=False):
    """Validate a recipe given as the entry's own dict; return it normalised.

    `stored` only changes how a refusal names the offending field (the stored
    field, or the flag that wrote it). The rules are the same on both sides.
    """
    if not isinstance(entry, dict):
        raise Refusal("the recipe is not an object")
    unknown = [k for k in entry if k not in ENTRY_FIELDS]
    if unknown:
        raise Refusal("the recipe holds an unknown field: %s" % unknown[0])

    def lab(flag, field):
        return field if stored else flag

    out = {}
    if "setup" in entry:
        out["setup"] = _steps(entry["setup"], "setup", stored)
    if "serve" in entry:
        out["serve"] = _command(entry["serve"], lab("--serve", "serve"))
    if "cli" in entry:
        out["cli"] = _command(entry["cli"], lab("--cli", "cli"))
    if "port" in entry:
        out["port"] = _port(entry["port"], lab("--port", "port"))
    if "ready" in entry:
        out["ready"] = _loopback_url(entry["ready"], lab("--ready", "ready"))
    if "login" in entry:
        login = entry["login"]
        if not isinstance(login, dict):
            raise Refusal("%s is not an object" % lab("--login", "login"))
        extra = [k for k in login if k not in ("method", "url")]
        if extra:
            raise Refusal("login holds an unknown field: %s" % extra[0])
        method = login.get("method")
        if method not in LOGIN_METHODS:
            raise Refusal("%s must be one of: %s" % (lab("--login", "login.method"), ", ".join(LOGIN_METHODS)))
        norm = {"method": method}
        if "url" in login:
            if method != "manual":
                raise Refusal("%s needs --login manual" % lab("--login-url", "login.url"))
            norm["url"] = _loopback_url(login["url"], lab("--login-url", "login.url"))
        elif method == "manual":
            raise Refusal("%s manual needs %s" % (lab("--login", "login.method"), lab("--login-url", "login.url")))
        out["login"] = norm
    if "browser" in entry:
        if entry["browser"] not in BROWSERS:
            raise Refusal("%s must be one of: %s" % (lab("--browser", "browser"), ", ".join(BROWSERS)))
        out["browser"] = entry["browser"]
    if "cleanup" in entry:
        out["cleanup"] = _steps(entry["cleanup"], "cleanup", stored)
    if "externalServices" in entry:
        label = lab("--external-services", "externalServices")
        text = entry["externalServices"]
        if not isinstance(text, str) or not text.strip():
            raise Refusal("%s is blank" % label)
        text = text.strip()
        if len(text) > EXTERNAL_MAXLEN:
            raise Refusal("%s is longer than %d characters" % (label, EXTERNAL_MAXLEN))
        if D._has_control(text):
            raise Refusal("%s holds a control character" % label)
        out["externalServices"] = text

    if "serve" not in out and "cli" not in out:
        raise Refusal("a recipe needs %s or %s" % (lab("--serve", "serve"), lab("--cli", "cli")))
    if "serve" not in out:
        needing = [(f, n) for f, n in (("--port", "port"), ("--ready", "ready"), ("--login", "login"), ("--browser", "browser")) if n in out]
        if needing:
            raise Refusal("%s needs %s" % (lab(needing[0][0], needing[0][1]), lab("--serve", "serve")))
    elif "ready" not in out:
        raise Refusal("%s needs %s" % (lab("--serve", "serve"), lab("--ready", "ready")))
    return {k: out[k] for k in ENTRY_FIELDS if k in out}


def _usage_recipes(doc, config):
    """The `usage.recipe` object of a parsed config, or None when it is absent."""
    usage = doc.get("usage")
    if "usage" in doc and not isinstance(usage, dict):
        raise Refusal("usage in %s is not an object" % config)
    recipes = usage.get("recipe") if isinstance(usage, dict) else None
    if isinstance(usage, dict) and "recipe" in usage and not isinstance(recipes, dict):
        raise Refusal("usage.recipe in %s is not an object" % config)
    return recipes


def record(config, project, entry):
    """Record <entry> under usage.recipe[<project>]; return the report."""
    key = D.validate_key(project)
    recipe = validate_entry(entry)
    if D.config_is_tracked(config):
        raise Refusal(
            "%s is tracked by git, so a recipe recorded there would not be trusted; "
            "untrack it or add it to .gitignore first" % config
        )
    doc = D._read_config(config)
    recipes = _usage_recipes(doc, config)

    report = {"status": "recorded", "project": key, "recipe": recipe, "config": config}
    if isinstance(recipes, dict) and recipes.get(key) == recipe:
        report["status"] = "unchanged"
        return report

    usage = doc.get("usage")
    if not isinstance(usage, dict):
        usage = {}
        doc["usage"] = usage
    if not isinstance(recipes, dict):
        recipes = {}
        usage["recipe"] = recipes
    recipes[key] = recipe
    D._write_atomically(config, doc)
    return report


def get(config, project):
    """Answer for usage.recipe[<project>]: recorded, absent or untrusted."""
    key = D.validate_key(project)
    if D.config_is_tracked(config):
        return {"status": "untrusted", "recipe": None}
    doc = D._read_config(config)
    recipes = _usage_recipes(doc, config)
    if not isinstance(recipes, dict) or key not in recipes:
        return {"status": "absent", "recipe": None}
    try:
        recipe = validate_entry(recipes[key], stored=True)
    except Refusal as exc:
        raise Refusal("usage.recipe[%s] in %s is invalid: %s" % (key, config, exc))
    return {"status": "recorded", "project": key, "recipe": recipe}


_SINGLE = {
    "--config": "config", "--project": "project", "--serve": "serve", "--cli": "cli",
    "--port": "port", "--ready": "ready", "--login": "login", "--login-url": "login-url",
    "--browser": "browser", "--external-services": "externalServices",
}
_REPEATED = {"--setup": "setup", "--cleanup": "cleanup"}


def _parse(args, verb, allowed):
    """Split argv into single-valued flags and repeated ones; a bad flag raises."""
    single, repeated = {}, {"setup": [], "cleanup": []}
    i = 0
    while i < len(args):
        flag = args[i]
        if flag not in allowed or i + 1 >= len(args):
            raise Refusal("unknown or incomplete flag: %s" % flag)
        value = args[i + 1]
        if flag in _REPEATED:
            repeated[_REPEATED[flag]].append(value)
        else:
            if _SINGLE[flag] in single:
                raise Refusal("%s was given more than once" % flag)
            single[_SINGLE[flag]] = value
        i += 2
    return single, repeated


def _entry_from_flags(single, repeated):
    entry = {}
    if repeated["setup"]:
        entry["setup"] = repeated["setup"]
    for name in ("serve", "cli", "port", "ready"):
        if name in single:
            entry[name] = single[name]
    if "login" in single or "login-url" in single:
        login = {}
        if "login" in single:
            login["method"] = single["login"]
        elif "login-url" in single:
            raise Refusal("--login-url needs --login manual")
        if "login-url" in single:
            login["url"] = single["login-url"]
        entry["login"] = login
    if "browser" in single:
        entry["browser"] = single["browser"]
    if repeated["cleanup"]:
        entry["cleanup"] = repeated["cleanup"]
    if "externalServices" in single:
        entry["externalServices"] = single["externalServices"]
    return entry


def _op_record(args):
    try:
        single, repeated = _parse(args, RECORD_VERB, set(_SINGLE) | set(_REPEATED))
        if not single.get("config"):
            raise Refusal("--config is required")
        report = record(single["config"], single.get("project"), _entry_from_flags(single, repeated))
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (RECORD_VERB, exc))
        return 1
    except OSError as exc:
        sys.stderr.write("Error: %s: cannot write the config (%s)\n" % (RECORD_VERB, exc.__class__.__name__))
        return 1
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 0


def _op_get(args):
    try:
        single, _ = _parse(args, GET_VERB, {"--config", "--project"})
        if not single.get("config"):
            raise Refusal("--config is required")
        report = get(single["config"], single.get("project"))
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (GET_VERB, exc))
        return 1
    except OSError as exc:
        sys.stderr.write("Error: %s: cannot read the config (%s)\n" % (GET_VERB, exc.__class__.__name__))
        return 1
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 0


_OPS = {"record": _op_record, "get": _op_get}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: usage_recipe.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
