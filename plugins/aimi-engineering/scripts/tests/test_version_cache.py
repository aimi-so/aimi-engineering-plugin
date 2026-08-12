"""Tests for the four version/cache verbs of aimi-cli.sh.

THIS IS THE ONE GOLDEN BLOCK WHOSE VERBS NEVER CROSSED INTO PYTHON.

`version`, `check-version`, `cleanup-versions` and `prime-cache` stay Bash + jq
-- the decision, and why, is in cmd_prime_cache's header comment in
aimi-cli.sh. So `version_cache_cases` is not a port's before-picture. It is the
before-picture of a FIX: the empty-cache abort (D2) and the `ls`-pipeline glob
that carried it. Everything the fix did not mean to touch has to come back
byte-identical, and everything it did mean to touch is named in
KNOWN_DIVERGENCES below with what changed.

The capture ran against 112d72f, before a line of aimi-cli.sh moved.

EVERY CASE BUILDS A THROWAWAY ROOT and points CLAUDE_CONFIG_DIR, AIMI_CONFIG_DIR,
HOME and XDG_CONFIG_HOME at it. That is not tidiness: `cleanup-versions` runs
`rm -rf` over every version directory it resolves out of CLAUDE_CONFIG_DIR, so a
case that leaked the developer's real value would delete the plugin install
running the suite. `_build_root` is the only thing that creates a path here, and
it creates all of them under `root`.

The recording is of a FILESYSTEM, not of a stream. `tree_before` and `tree` are
the whole throwaway root either side of the run, so a case cannot go green while
a directory it never mentioned was deleted.
"""

import json
import os
import re
import shutil
import stat
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _handle:
    GOLDEN = json.load(_handle)

CASES = {c["label"]: c for c in GOLDEN["version_cache_cases"]}

# The cases the D2 fix deliberately inverted, each with what it cost. Everything
# NOT named here must replay byte for byte -- that is the whole assurance this
# block buys, and the reason the list is spelled out instead of computed.
#
# Read this table as the compatibility event itself: these are exactly the runs
# whose observable behaviour a caller could notice changing.
KNOWN_DIVERGENCES = {
    "cv-cache-vazio-cc": (
        "D2 FIXED: was exit 1 with both streams empty (the helper's `return 1` "
        "carried into a bare assignment under `set -euo pipefail`); now reaches "
        'the documented {status:"unknown"} branch at exit 0.'
    ),
    "cv-quiet-cache-vazio-cc": (
        "D2 FIXED: same abort, now the same documented branch with --quiet "
        "suppressing the stderr warning it was never reached to print."
    ),
    "cv-sem-diretorio-cache-cc": (
        "D2 FIXED: an absent plugins/cache is the same empty glob as an empty "
        "one, and aborted identically; now {status:\"unknown\"} at exit 0."
    ),
    "cv-cache-ilegivel-cc": (
        "D2 FIXED: an unreadable plugins/cache yields no candidates, which is "
        "the empty glob again; now {status:\"unknown\"} at exit 0."
    ),
    "cv-config-dir-metacaracteres-cc": (
        "D2 FIXED: this case's cache is empty too, so it aborted for the D2 "
        "reason and not for its metacharacters. What it pins -- that the "
        "injected `touch` never runs -- is unchanged and asserted separately by "
        "test_a_metacharacter_bearing_config_dir_has_no_side_effect."
    ),
    "clv-cache-vazio-cc": (
        "D2 FIXED: was exit 1 with both streams empty; now reaches the "
        "documented {removed:0,kept:null} branch at exit 0. Note it still writes "
        "no cli-path -- the branch returns before write_global_cli_cache."
    ),
    "clv-sem-diretorio-cache-cc": (
        "D2 FIXED: absent plugins/cache, same abort, same repair."
    ),
    "clv-cache-ilegivel-cc": (
        "D2 FIXED: unreadable plugins/cache, same abort, same repair."
    ),
    "clv-config-dir-metacaracteres-cc": (
        "D2 FIXED: empty cache again; the injection half of the case is asserted "
        "separately and did not move."
    ),
}


# ---------------------------------------------------------------------------
# Rebuilding a case's world
# ---------------------------------------------------------------------------


def _expand(text, root, config_dir):
    if text is None:
        return None
    return text.replace("{ROOT}", root).replace("{CONFIG}", config_dir)


def _build_root(spec, root):
    """Materialize one case's throwaway filesystem and return its run recipe.

    Everything this writes lives under `root`. Nothing here reads an ambient
    environment variable, so a case behaves the same on a developer machine that
    exports CLAUDECODE=1 and AIMI_PLUGIN_DIR (this one does) as on a bare host.
    """
    config_dir = os.path.join(root, _expand(spec.get("config_dir", "claude-config"), root, ""))
    aimi_config = os.path.join(root, "aimi-config")
    project = os.path.join(root, "project")

    os.makedirs(os.path.join(project, ".aimi"), exist_ok=True)
    os.makedirs(aimi_config, exist_ok=True)
    os.makedirs(os.path.join(root, "xdg"), exist_ok=True)

    if spec.get("make_cache_dir", True):
        os.makedirs(os.path.join(config_dir, "plugins", "cache"), exist_ok=True)

    for entry in spec.get("cache", []):
        version_dir = os.path.join(
            config_dir, "plugins", "cache", entry["entry"], "aimi-engineering", entry["version"]
        )
        if entry.get("worktree_symlink"):
            # D11: the version directory is a symlink whose TARGET sits under a
            # `.worktrees/` segment. write_global_cli_cache's refusal matches the
            # path string it is handed, which never contains that segment.
            real = os.path.join(root, ".worktrees", "wt-" + entry["version"], "install")
            os.makedirs(os.path.join(real, "scripts"), exist_ok=True)
            _write_stub(os.path.join(real, "scripts", "aimi-cli.sh"), entry.get("exec", True))
            os.makedirs(os.path.dirname(version_dir), exist_ok=True)
            os.symlink(real, version_dir)
        else:
            os.makedirs(os.path.join(version_dir, "scripts"), exist_ok=True)
            _write_stub(os.path.join(version_dir, "scripts", "aimi-cli.sh"), entry.get("exec", True))

    plugin_dir = None
    if spec.get("plugin_dir") is not None:
        plugin_dir = os.path.join(root, "opencode-plugin")
        os.makedirs(os.path.join(plugin_dir, "scripts"), exist_ok=True)
        if spec["plugin_dir"].get("script", True):
            _write_stub(
                os.path.join(plugin_dir, "scripts", "aimi-cli.sh"),
                spec["plugin_dir"].get("exec", True),
            )

    if spec.get("global_cli_path") is not None:
        with open(os.path.join(aimi_config, "cli-path"), "w", encoding="utf-8") as handle:
            handle.write(_expand(spec["global_cli_path"], root, config_dir) + "\n")

    if spec.get("state_cli_path") is not None:
        with open(os.path.join(project, ".aimi", "cli-path"), "w", encoding="utf-8") as handle:
            handle.write(_expand(spec["state_cli_path"], root, config_dir) + "\n")

    # `version` reads plugin.json relative to the SCRIPT, so those cases run a
    # copy of the CLI out of a fake install rather than the repo's own.
    cli = CLI
    if spec.get("plugin_json") is not None:
        install = os.path.join(root, "fake-install")
        os.makedirs(os.path.join(install, "scripts"), exist_ok=True)
        shutil.copy(CLI, os.path.join(install, "scripts", "aimi-cli.sh"))
        if spec["plugin_json"] != "<absent>":
            os.makedirs(os.path.join(install, ".claude-plugin"), exist_ok=True)
            with open(
                os.path.join(install, ".claude-plugin", "plugin.json"), "w", encoding="utf-8"
            ) as handle:
                handle.write(spec["plugin_json"])
        cli = os.path.join(install, "scripts", "aimi-cli.sh")

    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": root,
        "XDG_CONFIG_HOME": os.path.join(root, "xdg"),
        "CLAUDE_CONFIG_DIR": config_dir,
        "AIMI_CONFIG_DIR": aimi_config,
        "LC_ALL": "C",
    }
    host = spec.get("host", "claudeCode")
    if host in ("claudeCode", "both"):
        env["CLAUDECODE"] = "1"
    if host in ("opencode", "both") and plugin_dir is not None:
        env["AIMI_PLUGIN_DIR"] = plugin_dir

    # Applied last: a read-only directory must not block the build itself.
    for locked in spec.get("readonly", []):
        os.chmod(os.path.join(root, _expand(locked["path"], root, config_dir)), int(locked["mode"], 8))

    return {"cli": cli, "cwd": project, "env": env, "config_dir": config_dir}


def _write_stub(path, executable):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("#!/usr/bin/env bash\nexit 0\n")
    os.chmod(path, 0o755 if executable else 0o644)


def _unlock(root):
    """Undo every chmod a case made, so tmp_path teardown can remove the tree."""
    for dirpath, dirnames, _ in os.walk(root):
        for name in dirnames:
            target = os.path.join(dirpath, name)
            if not os.path.islink(target):
                os.chmod(target, 0o755)
    os.chmod(root, 0o755)


# ---------------------------------------------------------------------------
# Recording it
# ---------------------------------------------------------------------------


def _normalize(text, root):
    text = text.replace(root, "/TMP")
    text = re.sub(r"\S*aimi-cli\.sh: line \d+:", "<CLI>: line <N>:", text)
    return re.sub(r"\.[A-Za-z0-9]{6}$", ".<MKTEMP>", text)


def _normalize_name(name):
    return re.sub(r"\.[A-Za-z0-9]{6}$", ".<MKTEMP>", name)


def _tree(root):
    """Every path under root, symlinks named as symlinks and never followed.

    Relative names go through the full normalizer and not only the mktemp one:
    the metacharacter cases put the ABSOLUTE root inside a directory NAME, so a
    tree entry can carry the temp path even though it is relative to it.
    """
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in sorted(dirnames) + sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = _normalize(os.path.relpath(full, root), root)
            if os.path.islink(full):
                out.append(rel + " -> " + _normalize(os.readlink(full), root))
            elif os.path.isdir(full):
                out.append(rel + "/")
            else:
                out.append(rel)
        dirnames[:] = [d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))]
    return sorted(out)


def _read(path, root):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return _normalize(handle.read(), root)
    except OSError:
        return None


def replay(spec, root):
    """Build, run, and record -- the same function the capture used."""
    recipe = _build_root(spec, root)
    tree_before = _tree(root)
    proc = subprocess.run(
        ["bash", recipe["cli"]] + spec["args"],
        cwd=recipe["cwd"],
        env=recipe["env"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    record = {
        "exit": proc.returncode,
        "stdout": _normalize(proc.stdout, root),
        "stderr": _normalize(proc.stderr, root),
        "tree_before": tree_before,
        "tree": _tree(root),
        "global_cli_path": _read(os.path.join(root, "aimi-config", "cli-path"), root),
        "state_cli_path": _read(os.path.join(root, "project", ".aimi", "cli-path"), root),
    }
    _unlock(root)
    return record


FIELDS = ("exit", "stdout", "stderr", "tree_before", "tree", "global_cli_path", "state_cli_path")


# ---------------------------------------------------------------------------
# The corpus, replayed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("label", sorted(CASES), ids=sorted(CASES))
def test_the_fix_changed_only_what_it_named(label, tmp_path):
    """Every case not in KNOWN_DIVERGENCES comes back byte-identical."""
    case = CASES[label]
    actual = replay(case["input"], str(tmp_path))
    if label in KNOWN_DIVERGENCES:
        pytest.skip(KNOWN_DIVERGENCES[label])
    for field in FIELDS:
        assert actual[field] == case[field], label + " . " + field


def test_the_divergence_table_names_only_cases_that_exist():
    """A label that stops existing must not sit here quietly excusing nothing."""
    assert set(KNOWN_DIVERGENCES) <= set(CASES)


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES), ids=sorted(KNOWN_DIVERGENCES))
def test_each_excused_case_recorded_the_abort_it_is_excused_for(label):
    """The excuse is only good while the RECORDING still shows the D2 abort.

    Every entry in the table was captured as exit 1 with both streams empty --
    that is what "the documented branch was dead code" looks like from outside.
    If a future edit to the capture makes one of them an ordinary answer, it
    stops belonging here, and this says so instead of letting the skip stand.
    """
    case = CASES[label]
    assert case["exit"] == 1, label + ": the recording is not an abort"
    assert case["stdout"] == "", label + ": the recording printed something"
    assert case["stderr"] == "", label + ": the recording warned about something"


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES), ids=sorted(KNOWN_DIVERGENCES))
def test_each_excused_case_now_answers_at_exit_zero(label, tmp_path):
    """And the inversion is asserted, not merely skipped past.

    A skip that named the change but never checked it would be exactly the hole
    `239af48` found in the test that printed "(skipping current-version test)".
    """
    case = CASES[label]
    actual = replay(case["input"], str(tmp_path))
    assert actual["exit"] == 0, label + ": still aborting"
    parsed = json.loads(actual["stdout"])
    if case["input"]["args"][0] == "check-version":
        assert parsed == {"status": "unknown", "message": "No installed version found"}
    else:
        assert parsed == {"removed": 0, "kept": None}
    # The abort used to precede write_global_cli_cache. Reaching the handler must
    # not start writing a cli-path that names nothing.
    assert actual["global_cli_path"] is None, label + ": wrote a cli-path for an empty cache"


# ---------------------------------------------------------------------------
# The contracts the fix was not allowed to move
# ---------------------------------------------------------------------------


def test_stale_still_exits_one_while_emitting_valid_json(tmp_path):
    """Non-zero-with-valid-output is load-bearing: callers read the JSON anyway."""
    case = CASES["cv-uma-versao-obsoleta-cc"]
    actual = replay(case["input"], str(tmp_path))
    assert actual["exit"] == 1
    assert json.loads(actual["stdout"])["status"] == "stale"


def test_the_two_json_spellings_still_coexist(tmp_path):
    """`current` is printf-built and compact; `missing` is jq-built and pretty.

    test-aimi-cli-part1-core.sh asserts both spellings LITERALLY -- `"status":
    "current"` with no space would fail one of them and `"status":"missing"`
    the other. Making the output uniform is therefore a test-breaking change,
    and this is where that shows up as a statement rather than as a surprise.
    """
    compact = replay(CASES["cv-uma-versao-atual-cc"]["input"], str(tmp_path / "a"))
    pretty = replay(CASES["cv-uma-versao-sem-state-cc"]["input"], str(tmp_path / "b"))
    assert '"status":"current"' in compact["stdout"]
    assert '"status": "missing"' in pretty["stdout"]


def test_prime_cache_keeps_every_documented_status_and_its_exit_code(tmp_path):
    """ok / already_current / not_found exit 0; error exits 1."""
    expected = {
        "pc-uma-versao-cc": ("ok", 0),
        "pc-ja-atual-cc": ("already_current", 0),
        "pc-cache-vazio-cc": ("not_found", 0),
        "pc-nao-executavel-cc": ("error", 1),
    }
    for index, (label, (status, code)) in enumerate(sorted(expected.items())):
        actual = replay(CASES[label]["input"], str(tmp_path / str(index)))
        assert json.loads(actual["stdout"])["status"] == status, label
        assert actual["exit"] == code, label


def test_the_newest_version_wins_over_the_lexicographically_last(tmp_path):
    """1.9.0 next to 1.10.0 and 1.123.0 -- `ls | tail -1` answers 1.9.0.

    The fixture uses THREE versions on purpose: a two-version fixture lets a
    wrong comparator pass by luck in one direction or the other.
    """
    for label in ("cv-tres-versoes-cc", "pc-tres-versoes-cc"):
        actual = replay(CASES[label]["input"], str(tmp_path / label))
        assert "1.123.0" in actual["stdout"], label
        assert "1.9.0" not in actual["stdout"], label


def test_cleanup_keeps_the_newest_and_deletes_the_rest(tmp_path):
    """The one verb that rm -rf's, checked against the filesystem and not stdout."""
    actual = replay(CASES["clv-tres-versoes-cc"]["input"], str(tmp_path))
    assert json.loads(actual["stdout"]) == {"removed": 2, "kept": "1.123.0"}
    survivors = [p for p in actual["tree"] if "aimi-engineering/" in p and p.endswith("/")]
    assert any("/1.123.0/" in p or p.endswith("/1.123.0/") for p in survivors)
    assert not any("/1.9.0" in p or "/1.10.0" in p for p in survivors)


def test_a_metacharacter_bearing_config_dir_has_no_side_effect(tmp_path):
    """The permanent regression case for the nested-shell interpolation.

    A CLAUDE_CONFIG_DIR embedding `";touch MARKER;ls "` used to be expanded by
    the OUTER shell into the INNER `bash -c`'s program text, closing the escaped
    quote and running the remainder. `7133927` closed the injection when it moved
    the glob behind _resolve_latest_cache_path with the directory passed as a
    positional argument; the array glob removed the nested shell entirely. This
    case is what keeps either from being undone.

    The marker is a RELATIVE path on purpose: it lands in the run's own cwd, so
    the payload carries no absolute temp path and two captures can agree.
    """
    for label in (
        "cv-config-dir-metacaracteres-cc",
        "clv-config-dir-metacaracteres-cc",
        "pc-config-dir-metacaracteres-cc",
    ):
        root = str(tmp_path / label)
        os.makedirs(root)
        replay(CASES[label]["input"], root)
        assert not os.path.exists(
            os.path.join(root, "project", "MARKER")
        ), label + ": the injected command ran"
