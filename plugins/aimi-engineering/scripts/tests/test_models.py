"""Tests for scripts/models.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for test_tasks.py.

`golden_from_jq.json`'s `models_read_cases` was captured by running the bash
and jq that used to live in aimi-cli.sh over 114 adversarial cases, BEFORE any
of it was deleted, and every case records its INPUT: the models.json bytes or
their deliberate absence, which host, what an `opencode` stub prints or whether
the binary is absent, whether python3 is reachable, which per-host prompt
marker exists, and any pre-seeded cache. So the whole corpus replays through
the CLI below and every recorded field is compared -- exit, stdout, stderr, and
the files left behind in the throwaway config root. That test is the evidence
the port changed nothing; the rest of this file asserts the properties a reader
would otherwise have to reconstruct from 114 recordings by eye.

`models_write_cases` is the same thing for the WRITER, `detect-models`, and it
carries one field the readers' block does not need: `file`, the whole document
AFTER the run. A writer's recording that only held stdout would stay green
while the config was being clobbered, which is precisely what shipped as
1.97.2 and precisely what this corpus exists to make impossible.

Neither block may ever be regenerated from models.py. If a case goes red,
either the port drifted or a rule genuinely changed; in the second case the
golden changes in the same commit as the rule, with the reason in the message.
"""

import json
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import models as M  # noqa: E402
import roadmap as R  # noqa: E402
import tasks as T  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _handle:
    GOLDEN = json.load(_handle)

CASES = {c["label"]: c for c in GOLDEN["models_read_cases"]}
WRITE_CASES = {c["label"]: c for c in GOLDEN["models_write_cases"]}

# ---------------------------------------------------------------------------
# The three divergences, by corpus label and by FIELD, with what each costs
# ---------------------------------------------------------------------------
#
# A label-wide excuse would hide the fields that still match, which is most of
# what these cases prove -- the cache-order pair below still agrees on stdout,
# stderr and exit status, and only leaves a different file behind. So the
# excuse names the field, and test_each_excused_field_really_diverges runs the
# case and fails if the excuse has gone stale.
KNOWN_DIVERGENCES = {
    # D4. The fabricated second warning was a consequence of splitting a value
    # on tabs and reading it a line at a time. Reproducing it would mean
    # re-implementing the tab-split loop this story exists to delete, so the
    # port emits ONE warning per invalid category, carrying the whole id.
    # COST: a model id containing a newline now produces a two-line warning
    # instead of two warnings, one of which named a category that never existed.
    "rm-id-com-newline-cc": {
        "stderr": "the fabricated second warning was the read loop's, not a rule's",
    },
    "rm-id-com-newline-oc-stub": {
        "stderr": "the fabricated second warning was the read loop's, not a rule's",
    },
    # THE VALID SET IS NOW AN INPUT TO THE ONE CROSSING, so it is computed
    # before the document is judged rather than after two jq passes have
    # already accepted it. On OpenCode that means `opencode models` runs, and
    # its mtime-keyed cache file is written, even for a config that is then
    # rejected. Preserving the old order would take either a second crossing or
    # a bash-side copy of the schema verdict -- both of them the shape this
    # port removes.
    # COST: on OpenCode, a rejected or unreadable config pays one shell-out it
    # used to skip, and leaves behind the same models-oc-cache-<mtime>.txt the
    # next successful call would have written anyway.
    "rm-v1-oc": {
        "files": "the valid set is an input to the crossing, so it is built before the verdict",
    },
    "rm-json-malformado-oc": {
        "files": "the valid set is an input to the crossing, so it is built before the verdict",
    },
    "rm-categories-host-array-oc-stub": {
        "files": "the valid set is an input to the crossing, so it is built before the verdict",
    },
    # THE PYTHON3 DEGRADE. These four verbs were pure bash and jq at capture
    # time, so the corpus records a python3-less host getting the full answer.
    # It cannot any more, and the alternative -- check_python3's hard exit 1 --
    # would break every command on a python3-less OpenCode host, which is the
    # regression this degrade exists to avoid. Each verb falls back to what it
    # already promises when it cannot read the config, with one line to stderr
    # and exit 0. test_the_degrade_answers_each_verb_s_own_fallback asserts the
    # new behaviour rather than leaving it merely excused.
    # COST: on a host with no python3 -- only possible under OpenCode, since
    # Claude Code spawns hooks/*.py on every Bash call -- a CONFIGURED user
    # gets the unconfigured answer plus a warning naming the missing
    # interpreter, instead of their configured models.
    "rm-python3-ausente-config-valida-cc": {
        "stdout": "no interpreter, so all-inherit rather than the configured ids",
        "stderr": "one line naming the missing interpreter",
    },
    "rm-python3-ausente-config-valida-oc": {
        "stdout": "no interpreter, so all-inherit rather than the configured ids",
        "stderr": "one line naming the missing interpreter",
    },
    "gcm-python3-ausente-config-valida-cc": {
        "stdout": "no interpreter, so all-null rather than the configured ids",
        "stderr": "one line naming the missing interpreter",
    },
    "gcm-python3-ausente-config-valida-oc": {
        "stdout": "no interpreter, so all-null rather than the configured ids",
        "stderr": "one line naming the missing interpreter",
    },
    "mpc-python3-ausente-configurado-cc": {
        "stdout": "no interpreter, so prompt rather than skip",
        "stderr": "one line naming the missing interpreter",
    },
    "mpc-python3-ausente-configurado-oc": {
        "stdout": "no interpreter, so prompt rather than skip",
        "stderr": "one line naming the missing interpreter",
    },
    "lm-python3-ausente-oc-stub": {
        "stdout": "no interpreter, so the built-in list rather than the host's own",
        "stderr": "one line naming the missing interpreter",
    },
    "lm-python3-ausente-oc-sem-binario": {
        "stderr": "one line naming the missing interpreter, after the one about the binary",
    },
}

# ---------------------------------------------------------------------------
# The WRITER's divergences, same rule: by corpus label, by FIELD, with the cost
# ---------------------------------------------------------------------------
#
# Seven fields across seven of the 60 cases. Every merge case, every escaping
# case and every D6 case matches byte for byte, which is what "delta zero"
# meant for this port.
KNOWN_DIVERGENCES_WRITE = {
    # jq puts every number through a double and prints the shortest form that
    # round-trips; Python keeps an int exact and renders -0.0 as 0. This is
    # jq_numbers' own documented divergence, inherited rather than introduced,
    # and it is split into its own case precisely so the ORDINARY numbers case
    # (1e3 -> 1000, 1.0 -> 1) can be compared with nothing excused.
    # COST: a number too large for a double in the other host's sub-table is
    # rewritten exact instead of as 1e+22, and a stored -0 becomes 0. Neither
    # is a model id; both would already be refused at read time.
    "dm-outro-host-com-numeros-extremos-cc": {
        "stdout": "jq renders a double, Python keeps the int exact",
        "file": "jq renders a double, Python keeps the int exact",
    },
    # FOUR jq ABORTS. The status is jq's exit 5 and it is reproduced exactly,
    # because that is what the shell propagated and what a caller reads. The
    # message was the ENGINE's -- "Cannot index array with string" and "string
    # and object cannot be added" -- and reproducing an engine's wording from a
    # different engine would be a fabrication, not fidelity. `exit`, `file` and
    # `tree` all still match: nothing is written on any of them.
    # COST: a user who broke their models.json by hand now reads a sentence
    # naming detect-models instead of one naming jq.
    "dm-documento-array-cc": {"stderr": "the abort message was jq's"},
    "dm-documento-string-cc": {"stderr": "the abort message was jq's"},
    "dm-categories-string-cc": {"stderr": "the abort message was jq's"},
    "dm-flags-categories-string-cc": {"stderr": "the abort message was jq's"},
    # THE INTERPRETER IS NOW REQUIRED, and for the writer it is required
    # LOUDLY. The four readers degrade because refusing would break every
    # command on a python3-less OpenCode host and because each of them has an
    # honest fallback to give. A writer has neither: writing the current host's
    # five values alone IS the 1.97.2 regression, and writing nothing at exit 0
    # tells /aimi:setup-models the config was saved when it was not. So this
    # one calls check_python3 and refuses before touching anything --
    # test_the_writer_refuses_rather_than_degrading asserts the new behaviour
    # rather than leaving it merely excused.
    # COST: on a host with no python3 -- only possible under OpenCode, since
    # Claude Code spawns hooks/*.py on every Bash call -- detect-models stops
    # working, where it used to be pure bash and jq. `file` and `tree` still
    # match: the refusal happens before anything is read or written.
    "dm-python3-ausente-cc": {
        "exit": "check_python3 refuses; a writer has no honest degrade",
        "stdout": "nothing is written, so nothing is echoed",
        "stderr": "the install hint, in place of the two notes",
    },
    "dm-flags-python3-ausente-cc": {
        "exit": "check_python3 refuses; a writer has no honest degrade",
        "stdout": "nothing is written, so nothing is echoed",
        "stderr": "the install hint, in place of the two notes",
    },
}

# Binaries the four verbs can reach. The shim directory is the WHOLE PATH for
# every replay, so a python3-absent case differs from its twin by exactly one
# symlink rather than by a different environment -- which is also how the
# capture ran.
_SHIM = [
    "cat", "stat", "mkdir", "rm", "mv", "chmod", "ls", "sed", "grep", "sort",
    "tail", "head", "cut", "tr", "wc", "dirname", "basename", "mktemp", "date",
    "env", "uname", "git", "flock", "realpath", "sha256sum", "jq", "bash", "sh",
]

_CACHE_RE = re.compile(r"models-oc-cache-\d+\.txt")
_TMP_RE = re.compile(r"models\.json\.[A-Za-z0-9]{6}")


def _replay(case, tmp_path):
    """Rebuild the case's config root, run the CLI, and normalize as the capture did."""
    base = str(tmp_path)
    root = os.path.join(base, "root")
    os.makedirs(root)
    home = os.path.join(base, "home")
    os.makedirs(home)
    spec = case["input"]

    config_path = os.path.join(root, "models.json")
    if spec["config"] is not None:
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write(spec["config"])
    if spec["seed_cache"] is not None:
        mtime = int(os.stat(config_path).st_mtime)
        name = "models-oc-cache-%d.txt" % mtime
        with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
            handle.write(spec["seed_cache"])
    if spec["marker"] is not None:
        with open(os.path.join(root, "models-prompt-seen-" + spec["marker"]), "w",
                  encoding="utf-8") as handle:
            handle.write("seen\n")

    shim = os.path.join(base, "shim")
    os.makedirs(shim)
    for name in _SHIM:
        found = shutil.which(name)
        if found:
            os.symlink(found, os.path.join(shim, name))
    if spec["python3"]:
        os.symlink(shutil.which("python3"), os.path.join(shim, "python3"))
    path = shim
    if spec["opencode_stub"] is not None:
        stubdir = os.path.join(base, "stub")
        os.makedirs(stubdir)
        stub = os.path.join(stubdir, "opencode")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(spec["opencode_stub"])
        os.chmod(stub, 0o755)
        path = stubdir + ":" + shim

    env = {
        "PATH": path,
        "HOME": home,
        "AIMI_CONFIG_DIR": root,
        "CLAUDE_CONFIG_DIR": root,
        "XDG_CONFIG_HOME": os.path.join(base, "xdg"),
    }
    if spec["host"] == "claudeCode":
        env["CLAUDECODE"] = "1"

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=base, env=env,
        capture_output=True, text=True, timeout=120,
    )

    files = {}
    for name in sorted(os.listdir(root)):
        with open(os.path.join(root, name), encoding="utf-8", errors="replace") as handle:
            files[_CACHE_RE.sub("models-oc-cache-<MTIME>.txt", name)] = handle.read()

    def norm(text):
        return _CACHE_RE.sub("models-oc-cache-<MTIME>.txt", text.replace(root, "/TMP"))

    return {
        "exit": proc.returncode,
        "stdout": norm(proc.stdout),
        "stderr": norm(proc.stderr),
        "files": files,
    }


def _replay_write(case, tmp_path):
    """Same rebuild for the WRITER, plus the two things only a writer needs.

    `readonly` chmods the config root to 0500 for the duration of the run, and
    the result carries `file` -- the whole document left on disk, or None when
    there is none -- beside the streams. A third normalization joins the
    other two, because mktemp's six random characters are in stderr on the
    read-only case.
    """
    base = str(tmp_path)
    root = os.path.join(base, "root")
    os.makedirs(root)
    home = os.path.join(base, "home")
    os.makedirs(home)
    spec = case["input"]

    config_path = os.path.join(root, "models.json")
    if spec["config"] is not None:
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write(spec["config"])

    shim = os.path.join(base, "shim")
    os.makedirs(shim)
    for name in _SHIM:
        if name == "jq" and not spec["jq"]:
            continue
        found = shutil.which(name)
        if found:
            os.symlink(found, os.path.join(shim, name))
    if spec["python3"]:
        os.symlink(shutil.which("python3"), os.path.join(shim, "python3"))
    path = shim
    if spec["opencode_stub"] is not None:
        stubdir = os.path.join(base, "stub")
        os.makedirs(stubdir)
        stub = os.path.join(stubdir, "opencode")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write(spec["opencode_stub"])
        os.chmod(stub, 0o755)
        path = stubdir + ":" + shim

    env = {
        "PATH": path,
        "HOME": home,
        "AIMI_CONFIG_DIR": root,
        "CLAUDE_CONFIG_DIR": root,
        "XDG_CONFIG_HOME": os.path.join(base, "xdg"),
    }
    if spec["host"] == "claudeCode":
        env["CLAUDECODE"] = "1"

    if spec["readonly"]:
        os.chmod(root, 0o500)
    try:
        proc = subprocess.run(
            ["bash", CLI] + case["args"], cwd=base, env=env,
            capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL,
        )
    finally:
        if spec["readonly"]:
            os.chmod(root, 0o700)

    def norm_name(name):
        return _TMP_RE.sub("models.json.<RANDOM>",
                           _CACHE_RE.sub("models-oc-cache-<MTIME>.txt", name))

    def norm(text):
        return norm_name(text.replace(root, "/TMP"))

    after = None
    if os.path.exists(config_path):
        with open(config_path, encoding="utf-8", errors="replace") as handle:
            after = handle.read()

    return {
        "exit": proc.returncode,
        "stdout": norm(proc.stdout),
        "stderr": norm(proc.stderr),
        "file": after,
        "tree": sorted(norm_name(name) for name in os.listdir(root)),
    }


# ---------------------------------------------------------------------------
# The port is faithful: the whole corpus, replayed
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("label", sorted(CASES), ids=sorted(CASES))
def test_the_port_reproduces_the_jq(label, tmp_path):
    """Every recorded field, for every case, except the ones named above."""
    case = CASES[label]
    actual = _replay(case, tmp_path)
    excused = KNOWN_DIVERGENCES.get(label, {})
    for field in ("exit", "stdout", "stderr", "files"):
        if field in excused:
            continue
        assert actual[field] == case[field], label + " . " + field


@pytest.mark.parametrize("label", sorted(WRITE_CASES), ids=sorted(WRITE_CASES))
def test_the_writer_port_reproduces_the_jq(label, tmp_path):
    """Every recorded field, for every writer case, except the ones named above.

    `file` is the whole document after the run, so this is also the assertion
    that no case leaves the config in a state the recording did not have. 53 of
    the 60 match on all five fields; the other seven are named field by field
    in KNOWN_DIVERGENCES_WRITE with what each costs.
    """
    case = WRITE_CASES[label]
    actual = _replay_write(case, tmp_path)
    excused = KNOWN_DIVERGENCES_WRITE.get(label, {})
    for field in ("exit", "stdout", "stderr", "file", "tree"):
        if field in excused:
            continue
        assert actual[field] == case[field], label + " . " + field


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES_WRITE),
                         ids=sorted(KNOWN_DIVERGENCES_WRITE))
def test_each_excused_writer_field_really_diverges(label, tmp_path):
    """Same rule as the readers': an excuse is only good while it is true."""
    case = WRITE_CASES[label]
    actual = _replay_write(case, tmp_path)
    for field in KNOWN_DIVERGENCES_WRITE[label]:
        assert actual[field] != case[field], label + " . " + field + " no longer diverges"


def test_the_divergence_table_names_only_cases_that_exist():
    """A label that stops existing must not sit here quietly excusing nothing."""
    assert set(KNOWN_DIVERGENCES) <= set(CASES)
    for label, fields in KNOWN_DIVERGENCES.items():
        assert set(fields) <= {"exit", "stdout", "stderr", "files"}, label
    assert set(KNOWN_DIVERGENCES_WRITE) <= set(WRITE_CASES)
    for label, fields in KNOWN_DIVERGENCES_WRITE.items():
        assert set(fields) <= {"exit", "stdout", "stderr", "file", "tree"}, label


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES), ids=sorted(KNOWN_DIVERGENCES))
def test_each_excused_field_really_diverges(label, tmp_path):
    """The excuse is only good while the field still diverges.

    An entry that starts matching again has stopped being a divergence and has
    to leave the table, or the table becomes a place where a future regression
    could hide. This is the mechanical version of that rule.
    """
    case = CASES[label]
    actual = _replay(case, tmp_path)
    for field in KNOWN_DIVERGENCES[label]:
        assert actual[field] != case[field], label + " . " + field + " no longer diverges"


# ---------------------------------------------------------------------------
# The python3 degrade, asserted rather than merely excused
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "label,expected_stdout,fallback_name",
    [
        ("rm-python3-ausente-config-valida-cc",
         '{"research":"inherit","review":"inherit","design":"inherit",'
         '"workflow":"inherit","executor":"inherit"}\n',
         "all-inherit"),
        ("gcm-python3-ausente-config-valida-cc",
         '{"research":null,"review":null,"design":null,"workflow":null,"executor":null}\n',
         "all-null"),
        ("mpc-python3-ausente-configurado-cc", "prompt\n", "prompt"),
        ("lm-python3-ausente-oc-stub",
         '[\n  "anthropic/claude-haiku-4-5",\n  "anthropic/claude-sonnet-4-6",'
         '\n  "anthropic/claude-opus-4-7"\n]\n',
         "the built-in Anthropic model list"),
    ],
)
def test_the_degrade_answers_each_verb_s_own_fallback(label, expected_stdout, fallback_name,
                                                      tmp_path):
    """A python3-less host gets the documented fallback, one warning, and exit 0.

    check_python3 exits 1. Calling it here would turn a python3-less OpenCode
    host -- the only host where that is possible, since Claude Code spawns
    hooks/*.py on every Bash call and install.sh wires no hooks at all -- from
    "works" into "every command dies at its first CLI call", which is a
    regression against the pure-jq behaviour this port replaces AND a violation
    of resolve-models' documented never-fail contract.
    """
    case = CASES[label]
    actual = _replay(case, tmp_path)
    verb = case["verb"]
    assert actual["exit"] == 0
    assert actual["stdout"] == expected_stdout
    assert ("Warning: " + verb + ": python3 is required to read models.json and was "
            "not found; falling back to " + fallback_name + ".") in actual["stderr"]


def test_the_degrade_is_invisible_where_the_document_is_never_read(tmp_path):
    """No config file means no crossing, so a python3-less host sees no change.

    The python3 check sits AFTER the branches bash answers on its own, which is
    what keeps these three byte-identical rather than merely well-behaved.
    """
    for label in ("rm-python3-ausente-arquivo-ausente-cc",
                  "rm-python3-ausente-arquivo-vazio-cc",
                  "mpc-python3-ausente-arquivo-ausente-cc"):
        case = CASES[label]
        actual = _replay(case, tmp_path / label)
        assert actual["stdout"] == case["stdout"], label
        assert actual["stderr"] == case["stderr"], label
        assert actual["exit"] == case["exit"], label


def test_list_models_needs_no_interpreter_on_claude_code(tmp_path):
    """The Claude Code branch answers a constant and crosses nothing at all."""
    case = CASES["lm-python3-ausente-cc"]
    actual = _replay(case, tmp_path)
    assert actual["stdout"] == case["stdout"]
    assert actual["stderr"] == ""


# ---------------------------------------------------------------------------
# The scaffolding is gone, and the rules that replaced it
# ---------------------------------------------------------------------------


def _source(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def test_no_delimiter_survives_anywhere():
    """The INVALID tag is deleted, not relocated, and no delimiter replaced it.

    The tag existed only because a value crossing a process boundary is a
    string. It had already been changed once, from "=" to tab, after a model id
    containing "=" truncated a message -- so a third delimiter would not have
    been a fix. models.py carries (category, model, valid) as a tuple instead,
    which is why the class cannot recur.
    """
    cli = _source(CLI)
    assert "INVALID" not in cli
    assert "IFS=$'\\t'" not in cli
    module = _source(os.path.join(SCRIPTS, "models.py"))
    # The tab appears in this module only inside the whitespace set both trims
    # already agreed on. Nothing here builds a tagged value and nothing splits
    # one back apart: the category, the model and the verdict travel as a
    # tuple, and the only split in the file is op_list's line reader, which is
    # jq -R's rule and not a delimiter.
    assert '.split("\\t")' not in module
    assert 'INVALID\\t" +' not in module
    assert module.count('split("\\n")') == 2  # valid_set, op_list


def test_each_reader_crosses_at_most_once_per_invocation():
    """The counting half of the one-crossing invariant, for the models readers.

    They take no lock -- they are readers -- so the lock half does not apply.
    The counting half does: a wrapper that crosses twice has, by construction,
    read something outside the decision it then makes. list-models names the
    module once, inside its OpenCode branch; its Claude Code branch answers a
    constant with no crossing at all, the same branch exemption cmd_list_ready
    has and asserted the same way.
    """
    crossing = 'python3 "$(_aimi_models_py)"'
    cli = _source(CLI)
    bodies = {}
    for name in ("cmd_resolve_models", "cmd_get_current_models",
                 "cmd_models_prompt_check", "cmd_list_models",
                 "cmd_resolve_efforts", "cmd_effort_options"):
        start = cli.index("\n" + name + "() {")
        end = cli.index("\n}\n", start)
        bodies[name] = cli[start:end]
    for name, body in bodies.items():
        assert body.count(crossing) == 1, name
        assert "_lock " not in body, name
    # And no reader smuggles in check_python3, whose exit 1 is the regression
    # the degrade exists to avoid.
    for name, body in bodies.items():
        assert "check_python3" not in body, name
        assert "_models_python3_or_degrade" in body, name


def test_the_writer_crosses_once_and_the_assembly_is_written_once():
    """The counting half of the invariant, plus the duplication this port removed.

    cmd_detect_models held the assembly TWICE, verbatim -- once in its flag
    branch and once in its default branch -- because one was copied over the
    other to repair 1.97.2. Both call merge_models_document now, through one
    crossing, and the two-line stderr epilogue that was duplicated beside them
    is written once as well. The writer takes no lock: nothing else writes
    models.json, and the mktemp-then-mv in write_aimi_models_config is what
    makes a concurrent reader see one document or the other, never half of one.
    """
    cli = _source(CLI)
    start = cli.index("\ncmd_detect_models() {")
    body = cli[start:cli.index("\n}\n", start)]
    assert body.count('python3 "$(_aimi_models_py)"') == 1
    assert body.count("detect-models: wrote %s table to %s") == 1
    assert body.count("re-run on the other host") == 1
    # The jq that built the document is gone from both branches, not moved.
    assert "schemaVersion: \"2.0\"" not in body
    assert "jq -n" not in body
    # check_jq STAYS: deleting it as part of a port to Python would silently
    # admit a jq-less host to a verb the rest of this file still refuses.
    assert "check_jq" in body


def test_the_writer_refuses_rather_than_degrading(tmp_path):
    """A writer with no interpreter says so and writes nothing.

    The opposite choice from the four readers beside it, and deliberately: they
    degrade to all-inherit / all-null / prompt / the built-in list because
    refusing would break every command on a python3-less OpenCode host and
    because each of them has an honest answer to give. This one has none.
    Writing the current host's five values alone IS 1.97.2; writing nothing at
    exit 0 tells /aimi:setup-models the config was saved when it was not. Its
    only two callers already handle the refusal -- setup-models.md says to
    report the error verbatim and stop.
    """
    case = WRITE_CASES["dm-python3-ausente-cc"]
    actual = _replay_write(case, tmp_path)
    assert actual["exit"] == 1
    assert actual["stdout"] == ""
    assert "python3 is required by aimi-cli.sh" in actual["stderr"]
    # And the pre-existing config is untouched, which is the half that matters.
    assert actual["file"] == case["input"]["config"]
    assert actual["tree"] == case["tree"]


def test_a_model_list_with_no_haiku_still_writes_a_table(tmp_path):
    """D6's repair, asserted at the rule the three moved records describe.

    The capture found this aborting at exit 1 with both streams empty and
    nothing written: `pipefail` handed grep's exit 1 to a bare assignment and
    `set -e` took the verb down, so the three documented fallbacks after it --
    first line, second line, last line -- were dead code. They are reachable
    now, and this reads them off a real run rather than off the comment.
    """
    actual = _replay_write(WRITE_CASES["dm-lista-sem-haiku-oc-stub"], tmp_path)
    assert actual["exit"] == 0
    assert json.loads(actual["file"])["categories"]["opencode"] == {
        # no haiku -> the FIRST entry; no opus -> the LAST; no sonnet -> the SECOND
        "research": "openai/gpt-5",
        "review": "meta/llama-4-405b",
        "design": "google/gemini-3-pro",
        "workflow": "google/gemini-3-pro",
        "executor": "google/gemini-3-pro",
    }


def test_the_repaired_path_still_merges(tmp_path):
    """The repair does not get to cost the thing this story is about.

    An OpenCode host with no haiku in its list and a config carrying both hosts
    used to write nothing at all; it now writes its own table AND leaves
    claudeCode's byte-for-byte alone.
    """
    case = WRITE_CASES["dm-lista-sem-haiku-config-existente-oc-stub"]
    actual = _replay_write(case, tmp_path)
    assert actual["exit"] == 0
    before = json.loads(case["input"]["config"])["categories"]["claudeCode"]
    assert json.loads(actual["file"])["categories"]["claudeCode"] == before


def test_no_case_fails_silently_except_the_one_the_parser_owns():
    """A verb that exits non-zero with both streams empty has said nothing.

    Four cases in the capture did that: three were D6 and are repaired. The
    survivor is `detect-models --research` with no value, where the parser
    shifts twice and the second `shift` fails under set -e -- an argument bug,
    not a document one, and deliberately left for the slice that owns flag
    parsing rather than smuggled into a commit about the merge. Naming it here
    is what stops the list growing back.
    """
    silent = sorted(label for label, case in WRITE_CASES.items()
                    if case["exit"] != 0 and case["stdout"] == "" and case["stderr"] == "")
    assert silent == ["dm-flags-valor-ausente-cc"]


def test_the_merge_takes_the_existing_document_as_a_parameter():
    """The signature is the enforcement, so it is asserted like one.

    A rebuild -- the 1.97.2 defect -- is not expressible in a function whose
    first parameter is the existing document without visibly ignoring it. This
    test is what makes that structural rather than a comment.
    """
    import inspect

    params = list(inspect.signature(M.merge_models_document).parameters)
    assert params == ["existing", "host_key", "categories"]


def test_the_merge_keeps_exactly_what_the_jq_kept_and_nothing_more():
    """All four halves of `{schemaVersion:"2.0", categories:((.categories // {}) + {...})}`.

    Read them together, because the third and fourth are the counter-intuitive
    ones: today's merge is itself a rebuild that happens to preserve one key.
    """
    five = {"research": "haiku", "review": "opus", "design": "sonnet",
            "workflow": "sonnet", "executor": "sonnet"}
    existing = {
        "schemaVersion": "1.0",
        "updatedAt": "2026-01-01T00:00:00Z",
        "categories": {
            "opencode": {"research": "anthropic/claude-haiku-4-5"},
            "claudeCode": {"research": "opus", "custom": "keep me?"},
        },
    }
    merged = M.merge_models_document(existing, "claudeCode", five)
    # 1. the other host survives -- the whole point, and the 1.97.2 regression
    assert merged["categories"]["opencode"] == {"research": "anthropic/claude-haiku-4-5"}
    # 2. schemaVersion is force-written over a v1.0 document
    assert merged["schemaVersion"] == "2.0"
    # 3. every other top-level key is discarded
    assert set(merged) == {"schemaVersion", "categories"}
    # 4. the current host's sub-table is REPLACED, not merged into
    assert merged["categories"]["claudeCode"] == five
    # and the fresh-create branch is the same expression with nothing carried
    assert M.merge_models_document(None, "claudeCode", five) == {
        "schemaVersion": "2.0", "categories": {"claudeCode": five}}


def test_the_merge_inherits_the_same_two_jq_rules_the_readers_do():
    """`//` fires on false, and indexing a non-object aborts."""
    five = {"research": "haiku"}
    assert M.merge_models_document({"categories": False}, "claudeCode", five) == {
        "schemaVersion": "2.0", "categories": {"claudeCode": five}}
    assert M.merge_models_document({"categories": None}, "claudeCode", five) == {
        "schemaVersion": "2.0", "categories": {"claudeCode": five}}
    with pytest.raises(T.MalformedTasks):
        M.merge_models_document(["opus"], "claudeCode", five)
    with pytest.raises(T.MalformedTasks):
        M.merge_models_document({"categories": "nope"}, "claudeCode", five)


def test_the_writer_matches_jq_byte_for_byte_where_json_dumps_would_not():
    """The two disagreements, at the rule.

    U+007F is the only character in the whole range where jq's escaping and
    json.dumps' differ, and a non-finite double is the only value jq prints as
    something other than itself. Both are handled where they arise rather than
    left for a reader of the corpus to discover.
    """
    assert M.jq_finite(float("nan")) is None
    assert M.jq_finite({"a": [float("inf"), float("-inf"), 1.5]}) == {"a": [None, None, 1.5]}
    assert M.jq_finite("nan") == "nan"
    case = WRITE_CASES["dm-flags-controle-cc"]
    assert "\\u007f" in case["file"]
    assert "\x7f" not in case["file"]
    assert json.dumps({"a": "\x7f"}, ensure_ascii=False) == '{"a": "\x7f"}'


# ---------------------------------------------------------------------------
# D7, driven through a real pty instead of read off the source
# ---------------------------------------------------------------------------


def _drive_prompt(tmp_path, keystroke):
    """Run detect-models with a controlling terminal and answer its prompts.

    NO CASE IN THE CORPUS CAN REACH THIS PATH: every one runs with stdin on
    /dev/null, so `[ -t 0 ]` is false and the prompt block never executes. That
    is stated in _comment_models_write rather than papered over with a case
    that pretends -- and this is the coverage it points at instead.
    """
    base = str(tmp_path)
    root = os.path.join(base, "root")
    os.makedirs(root)
    home = os.path.join(base, "home")
    os.makedirs(home)
    env = {
        "PATH": os.environ["PATH"],
        "HOME": home,
        "AIMI_CONFIG_DIR": root,
        "CLAUDE_CONFIG_DIR": root,
        "XDG_CONFIG_HOME": os.path.join(base, "xdg"),
        "CLAUDECODE": "1",
        "TERM": "dumb",
    }
    pid, fd = pty.fork()
    if pid == 0:  # pragma: no cover - the child execs immediately
        os.execve("/bin/bash", ["bash", CLI, "detect-models"], env)

    out = b""
    answered = 0
    deadline = time.time() + 60
    status = None
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if b"Category" in out and answered < len(M.CATEGORIES) + 1:
                os.write(fd, keystroke)
                answered += 1
        else:
            done, raw = os.waitpid(pid, os.WNOHANG)
            if done:
                status = raw
                break
    if status is None:
        _, status = os.waitpid(pid, 0)
    os.close(fd)
    config = os.path.join(root, "models.json")
    written = None
    if os.path.exists(config):
        with open(config, encoding="utf-8") as handle:
            written = handle.read()
    return os.waitstatus_to_exitcode(status), out.decode(errors="replace"), written


def test_eof_at_the_prompt_takes_the_default_and_always_did(tmp_path):
    """D7, REFUTED by driving it rather than by reading the source.

    The claim was that Ctrl-D makes `read -r answer </dev/tty` return 1 and
    take the verb down through the same set -e chain that kills it when the
    model list has no haiku. It does not, and the difference is where the
    failing command sits: bash CLEARS -e inside a command substitution when not
    in POSIX mode, so the `read` inside _prompt_category aborts nothing and the
    substitution's status is its last command's -- the printf. D6's bare
    assignment is at the function's own level, where -e is live, which is why
    that one really does abort. Nothing was repaired here because nothing was
    broken; this test is what says so.
    """
    exit_code, transcript, written = _drive_prompt(tmp_path, b"\x04")
    assert exit_code == 0
    assert transcript.count("Category ") == len(M.CATEGORIES)
    assert written is not None
    assert json.loads(written)["categories"]["claudeCode"] == {
        "research": "haiku", "review": "opus", "design": "sonnet",
        "workflow": "sonnet", "executor": "sonnet"}


def test_a_typed_answer_at_the_prompt_is_honoured(tmp_path):
    """The other half, so the EOF result cannot be read as "the pty did nothing"."""
    exit_code, _, written = _drive_prompt(tmp_path, b"opus\n")
    assert exit_code == 0
    assert json.loads(written)["categories"]["claudeCode"] == {
        "research": "opus", "review": "opus", "design": "opus",
        "workflow": "opus", "executor": "opus"}


def test_the_jq_semantics_helpers_are_imported_and_not_recopied():
    """One implementation of each, in the module that owns it."""
    assert M.jq_index is T.jq_index
    assert M.jq_index_in is T.jq_index_in
    assert M.jq_equal is T.jq_equal
    assert M._emit_compact is T._emit_compact
    assert M.jq_numbers is R.jq_numbers


def test_the_pt_br_rejection_is_one_literal_emitted_at_both_sites():
    """The string is written once now; the BYTES at both sites are unchanged.

    `/aimi:setup-models` matches on "schema 1.0", and both verbs prefix it with
    their own name -- which is the only part that ever differed.
    """
    assert M.SCHEMA_OBSOLETO == "schema 1.0 obsoleto — re-rode aimi-cli detect-models"
    assert CASES["rm-v1-cc"]["stderr"] == (
        "Warning: resolve-models: " + M.SCHEMA_OBSOLETO + "\n")
    assert CASES["gcm-v1-cc"]["stderr"] == (
        "Warning: get-current-models: " + M.SCHEMA_OBSOLETO + "\n")


# ---------------------------------------------------------------------------
# The document rules, directly
# ---------------------------------------------------------------------------


def test_the_stream_rule_is_jq_s_and_not_a_single_document():
    assert M.parse_stream("") == []
    assert M.parse_stream("   \n ") == []
    assert M.parse_stream('{"a":1}{"a":2}') == [{"a": 1}, {"a": 2}]
    with pytest.raises(ValueError):
        M.parse_stream('{"a":')


def test_normalize_trims_the_ends_and_never_the_middle():
    assert M.normalize("  sonnet  ") == "sonnet"
    assert M.normalize("\n\nsonnet\n\n") == "sonnet"
    assert M.normalize("son net") == "son net"
    assert M.normalize("son\tnet") == "son\tnet"
    assert M.normalize("sonnet\nopus") == "sonnet\nopus"
    # D1's abort, which is the one thing in this file that produces no output.
    with pytest.raises(M.JqAbort):
        M.normalize(True)


def test_an_all_whitespace_id_degrades_silently():
    """It normalizes to "", which the accept arm swallows before any warning.

    Worth stating because it is the one invalid-looking value that produces no
    diagnostic at all -- and because a reader would otherwise expect the same
    warning ' ' gets from every other refusal.
    """
    resolved, warnings = M.validate(
        {"research": "   ", "review": "opus"}, ["opus"], "resolve-models", "Claude Code", "")
    assert resolved == {"research": "inherit", "review": "opus"}
    assert warnings == []


def test_a_non_string_value_is_refused_like_every_other_invalid_one():
    """D1's repair, at the rule rather than through the CLI.

    `true`, `5`, `{}` and `["opus"]` used to reach jq's "INVALID\\t" + value
    concatenation, which is a type error: the call's stderr was discarded, its
    assignment was bare, and `set -euo pipefail` took the shell down at exit 5
    with EMPTY stdout and EMPTY stderr -- the one input that contradicted
    resolve-models' never-fail contract. Each is an invalid id now, warned
    about in the one refusal line and degraded to inherit, and rendered the way
    jq rendered a non-string inside a message: its compact JSON form.
    """
    qualifier = "must be exactly opus, sonnet, or haiku; "
    resolved, warnings = M.validate(
        {"research": True, "review": 5, "design": {}, "workflow": ["opus"],
         "executor": "opus"},
        ["opus"], "resolve-models", "Claude Code", qualifier,
    )
    assert resolved == {"research": "inherit", "review": "inherit", "design": "inherit",
                        "workflow": "inherit", "executor": "opus"}
    assert [w.split("model ")[1].split(" is not")[0] for w in warnings] == [
        "'true'", "'5'", "'{}'", '\'["opus"]\'']
    for warning in warnings:
        assert warning.endswith("), falling back to inherit")
        assert qualifier in warning


def test_the_corpus_has_no_failing_case_left():
    """resolve-models' contract, read off the whole recording at once.

    Every one of the 114 cases exits 0 -- including the four the capture found
    at exit 5, whose entries were rewritten by the repair commit that changed
    the rule. A new non-zero here means a verb that promises never to fail has
    learned how.
    """
    assert sorted({case["exit"] for case in CASES.values()}) == [0]


def test_the_valid_set_is_normalized_on_both_sides_of_the_question():
    assert M.valid_set("opus\n  sonnet  \n\nhaiku") == ["opus", "sonnet", "haiku"]
    assert M.valid_set("") == []
    resolved, warnings = M.validate(
        {"research": "  sonnet  "}, M.valid_set("sonnet\n"), "resolve-models", "OpenCode", "")
    assert resolved == {"research": "sonnet"}
    assert warnings == []


def test_the_schema_verdict_is_typed_the_way_jq_s_equality_was():
    assert M.schema_verdict({"schemaVersion": "2.0"}) == "ok"
    # The NUMBER 2.0 is not the STRING "2.0", in jq or here.
    assert M.schema_verdict({"schemaVersion": 2.0}) == "reject"
    assert M.schema_verdict({"schemaVersion": "2.0", "models": {}}) == "reject"
    assert M.schema_verdict({}) == "reject"
    with pytest.raises(M.JqAbort):
        M.schema_verdict("a bare string")


def test_a_false_reads_as_unset_where_a_zero_does_not():
    """jq's `//` fires on false as well as null, and both verbs inherit it."""
    doc = {"categories": {"claudeCode": {"research": False, "review": 0}}}
    assert M.read_categories(doc, "claudeCode")["research"] is None
    assert M.read_categories(doc, "claudeCode")["review"] == 0
    assert M._host_configured({"categories": {"claudeCode": {"research": False}}},
                              "claudeCode") is False
    assert M._host_configured({"categories": {"claudeCode": {"research": 0}}},
                              "claudeCode") is True


def test_indexing_a_non_object_aborts_where_indexing_null_does_not():
    """The only route to the "malformed JSON" message, and the reason for it."""
    assert M.read_categories({}, "claudeCode")["research"] is None
    with pytest.raises(T.MalformedTasks):
        M.read_categories({"categories": "nope"}, "claudeCode")
    with pytest.raises(T.MalformedTasks):
        M.read_categories({"categories": {"claudeCode": "nope"}}, "claudeCode")


# ---------------------------------------------------------------------------
# Efforts: the reasoning level (Claude Code) or variant (OpenCode) beside each
# category's model. See models.py's EFFORTS note.
# ---------------------------------------------------------------------------

EFFORT_CASES = {c["label"]: c for c in GOLDEN["models_effort_cases"]}

_ALL_INHERIT = {c: "inherit" for c in M.CATEGORIES}
_MODELS_CC = ["--research", "haiku", "--review", "opus", "--design", "sonnet",
              "--workflow", "sonnet", "--executor", "sonnet"]
_MODELS_OC = ["--research", "p/haiku", "--review", "p/opus", "--design", "p/sonnet",
              "--workflow", "p/sonnet", "--executor", "p/sonnet"]

_CATALOG_TEXT = """p/opus
{
  "id": "opus",
  "variants": {"high": {}, "max": {}, "bad name": {}}
}
p/haiku
{
  "id": "haiku"
}
p/sonnet
{
  "variants": {"low": {}}
}
"""


def _detect(doc, host_key, args, catalog=None, tmp_path=None):
    """Run op_detect's CLI half as a subprocess: (exit, stdout, stderr)."""
    argv = [sys.executable, os.path.join(SCRIPTS, "models.py"), "detect", "--host-key", host_key] + args
    if catalog is not None:
        path = tmp_path / "catalog.txt"
        path.write_text(catalog, encoding="utf-8")
        argv += ["--catalog-file", str(path)]
    stdin = "" if doc is None else json.dumps(doc)
    done = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    return done.returncode, done.stdout, done.stderr


def test_effort_levels_are_the_six_and_in_order():
    assert M.EFFORT_LEVELS == ("inherit", "low", "medium", "high", "xhigh", "max")


@pytest.mark.parametrize("label", sorted(EFFORT_CASES))
def test_effort_read_golden_cases(label):
    case = EFFORT_CASES[label]
    efforts, warnings = M.read_efforts(case["doc"], case["host"])
    assert efforts == case["efforts"]
    assert len(warnings) == case["warnings"]


def test_effort_read_valid_values_per_host():
    doc = {"categories": {"claudeCode": {"efforts": {"review": "xhigh", "design": " low "}}}}
    efforts, warnings = M.read_efforts(doc, "claudeCode")
    assert efforts["review"] == "xhigh" and efforts["design"] == "low"
    assert efforts["research"] == "inherit" and warnings == []
    doc = {"categories": {"opencode": {"efforts": {"review": "none", "design": "My.Var-1"}}}}
    efforts, warnings = M.read_efforts(doc, "opencode")
    assert efforts["review"] == "none" and efforts["design"] == "My.Var-1" and warnings == []


def test_effort_read_unset_shapes_say_nothing():
    for unset in (None, False, "", "   "):
        doc = {"categories": {"claudeCode": {"efforts": {"review": unset}}}}
        assert M.read_efforts(doc, "claudeCode") == (_ALL_INHERIT, [])
    for doc in ({}, None, [], {"categories": None}, {"categories": {"claudeCode": None}},
                {"categories": {"claudeCode": {"efforts": None}}}):
        assert M.read_efforts(doc, "claudeCode") == (_ALL_INHERIT, [])


def test_effort_read_invalid_values_warn_once_and_echo_cut():
    long_value = "x" * 100
    for bad in ("High", "ultra", True, 0, long_value, ["a"]):
        doc = {"categories": {"claudeCode": {"efforts": {"review": bad}}}}
        efforts, warnings = M.read_efforts(doc, "claudeCode")
        assert efforts == _ALL_INHERIT
        assert len(warnings) == 1 and "review" in warnings[0]
    _, warnings = M.read_efforts(
        {"categories": {"claudeCode": {"efforts": {"review": long_value}}}}, "claudeCode")
    assert long_value not in warnings[0] and '"' + "x" * 10 in warnings[0]
    _, warnings = M.read_efforts(
        {"categories": {"opencode": {"efforts": {"review": "has space"}}}}, "opencode")
    assert len(warnings) == 1 and '"has space"' in warnings[0]


def test_effort_read_malformed_container_is_all_inherit_with_one_warning():
    for container in ("high", ["high"], 5, True):
        doc = {"categories": {"claudeCode": {"efforts": container}}}
        efforts, warnings = M.read_efforts(doc, "claudeCode", verb="resolve-efforts")
        assert efforts == _ALL_INHERIT and len(warnings) == 1
        assert warnings[0].startswith("Warning: resolve-efforts:")


def test_effort_malformed_container_leaves_model_reads_untouched():
    doc = {"schemaVersion": "2.0", "categories": {"claudeCode": {
        "research": "haiku", "review": "opus", "efforts": "garbage"}}}
    values = M.read_categories(doc, "claudeCode")
    assert values["research"] == "haiku" and values["review"] == "opus"
    assert values["design"] is None
    assert M.read_efforts(doc, "claudeCode")[0] == _ALL_INHERIT


def test_effort_read_never_raises_on_odd_documents():
    for doc in (1, "x", [1], {"categories": [1]}, {"categories": {"claudeCode": 3}}):
        efforts, warnings = M.read_efforts(doc, "claudeCode")
        assert efforts == _ALL_INHERIT and warnings == []


def test_effort_catalog_parses_ids_variants_and_order(capsys):
    catalog = M.catalog_variants(_CATALOG_TEXT)
    assert catalog == {"p/opus": ["high", "max"], "p/haiku": [], "p/sonnet": ["low"]}
    assert list(catalog) == ["p/opus", "p/haiku", "p/sonnet"]
    err = capsys.readouterr().err
    assert err.count('"bad name"') == 1 and err.count("\n") == 1


def test_effort_catalog_none_when_empty_or_unparseable():
    assert M.catalog_variants("") is None
    assert M.catalog_variants("  \n\n") is None
    assert M.catalog_variants("no models here\nat all\n") is None
    assert M.catalog_variants("p/x\n{ broken") is None


def test_effort_write_stores_and_keeps_and_clears_on_claude_code(tmp_path):
    code, out, _ = _detect(None, "claudeCode", _MODELS_CC + ["--review-effort", "high"])
    assert code == 0
    doc = json.loads(out)
    assert doc["categories"]["claudeCode"]["efforts"] == {"review": "high"}
    assert doc["schemaVersion"] == "2.0"
    assert [k for k in doc["categories"]["claudeCode"] if k != "efforts"] == list(M.CATEGORIES)
    # a later write with no effort flag keeps it
    code, out, _ = _detect(doc, "claudeCode", _MODELS_CC)
    assert json.loads(out)["categories"]["claudeCode"]["efforts"] == {"review": "high"}
    # inherit clears it and drops the empty container
    code, out, _ = _detect(doc, "claudeCode", _MODELS_CC + ["--review-effort", "inherit"])
    assert "efforts" not in json.loads(out)["categories"]["claudeCode"]


def test_effort_write_without_efforts_has_no_efforts_key():
    code, out, _ = _detect(None, "claudeCode", _MODELS_CC)
    assert code == 0 and "efforts" not in out


def test_effort_write_trims_and_is_case_sensitive():
    code, out, _ = _detect(None, "claudeCode", _MODELS_CC + ["--review-effort", "  max\t"])
    assert code == 0 and json.loads(out)["categories"]["claudeCode"]["efforts"] == {"review": "max"}
    code, out, err = _detect(None, "claudeCode", _MODELS_CC + ["--review-effort", "MAX"])
    assert code == 1 and out == "" and err.startswith("Error: detect-models:")


def test_effort_write_refuses_invalid_claude_code_value_and_cuts_the_echo():
    value = "z" * 90
    code, out, err = _detect(None, "claudeCode", _MODELS_CC + ["--design-effort", value])
    assert code == 1 and out == ""
    assert err.startswith('Error: detect-models: --design-effort value "' + "z" * 10)
    assert value not in err


def test_effort_write_allows_effort_beside_model_inherit_on_claude_code():
    models = ["--research", "inherit", "--review", "opus", "--design", "sonnet",
              "--workflow", "sonnet", "--executor", "sonnet"]
    code, out, _ = _detect(None, "claudeCode", models + ["--research-effort", "low"])
    assert code == 0
    table = json.loads(out)["categories"]["claudeCode"]
    assert table["research"] == "inherit" and table["efforts"] == {"research": "low"}


def test_effort_write_keeps_the_other_hosts_models_and_efforts():
    other = {"research": "p/a", "review": "p/b", "design": "p/c", "workflow": "p/d",
             "executor": "p/e", "efforts": {"review": "deep"}}
    existing = {"schemaVersion": "2.0", "categories": {"opencode": other}}
    code, out, _ = _detect(existing, "claudeCode", _MODELS_CC + ["--review-effort", "high"])
    assert code == 0
    merged = json.loads(out)["categories"]
    assert merged["opencode"] == other
    assert merged["claudeCode"]["efforts"] == {"review": "high"}


def test_effort_write_malformed_stored_container_does_not_block_a_write():
    existing = {"schemaVersion": "2.0", "categories": {"claudeCode": {
        "research": "haiku", "efforts": "garbage"}}}
    code, out, err = _detect(existing, "claudeCode", _MODELS_CC)
    assert code == 0 and "efforts" not in json.loads(out)["categories"]["claudeCode"]
    assert "not an object" in err


def test_effort_write_opencode_charset_and_none_variant_verbatim():
    code, out, _ = _detect(None, "opencode", _MODELS_OC + ["--review-effort", "none"])
    assert code == 0 and json.loads(out)["categories"]["opencode"]["efforts"] == {"review": "none"}
    for bad in ("-lead", "has space", "a" * 65, "x/y"):
        code, out, err = _detect(None, "opencode", _MODELS_OC + ["--review-effort", bad])
        assert code == 1 and out == "" and err.startswith("Error: detect-models:")


def test_effort_write_opencode_model_inherit_writes_inherit_with_notice():
    models = ["--research", "inherit", "--review", "p/opus", "--design", "p/sonnet",
              "--workflow", "p/sonnet", "--executor", "p/sonnet"]
    code, out, err = _detect(None, "opencode", models + ["--research-effort", "high"])
    assert code == 0 and "efforts" not in json.loads(out)["categories"]["opencode"]
    assert "research" in err


def test_effort_write_opencode_catalog_refuses_new_and_drops_kept(tmp_path):
    code, out, err = _detect(None, "opencode", _MODELS_OC + ["--review-effort", "high"],
                             catalog=_CATALOG_TEXT, tmp_path=tmp_path)
    assert code == 0 and json.loads(out)["categories"]["opencode"]["efforts"] == {"review": "high"}
    code, out, err = _detect(None, "opencode", _MODELS_OC + ["--review-effort", "medium"],
                             catalog=_CATALOG_TEXT, tmp_path=tmp_path)
    assert code == 1 and out == "" and "p/opus" in err
    # a model with no variants refuses any new variant
    code, out, err = _detect(None, "opencode", _MODELS_OC + ["--research-effort", "high"],
                             catalog=_CATALOG_TEXT, tmp_path=tmp_path)
    assert code == 1 and out == ""
    # a kept variant the model does not define is dropped with a notice
    existing = {"schemaVersion": "2.0", "categories": {"opencode": {
        **{c: "p/opus" for c in M.CATEGORIES}, "efforts": {"design": "max"}}}}
    code, out, err = _detect(existing, "opencode", _MODELS_OC, catalog=_CATALOG_TEXT,
                             tmp_path=tmp_path)
    assert code == 0 and "efforts" not in json.loads(out)["categories"]["opencode"]
    assert '"max"' in err and "p/sonnet" in err


def test_effort_write_opencode_without_catalog_keeps_unchanged_drops_changed(tmp_path):
    existing = {"schemaVersion": "2.0", "categories": {"opencode": {
        **{c: "p/sonnet" for c in M.CATEGORIES}, "efforts": {"design": "low"}}}}
    # model unchanged: kept
    code, out, _ = _detect(existing, "opencode", _MODELS_OC[:4] + ["--design", "p/sonnet"] + _MODELS_OC[6:])
    assert code == 0
    assert json.loads(out)["categories"]["opencode"]["efforts"] == {"design": "low"}
    # model changed: dropped, and the notice says the catalog was unavailable
    changed = ["--research", "p/sonnet", "--review", "p/sonnet", "--design", "p/opus",
               "--workflow", "p/sonnet", "--executor", "p/sonnet"]
    code, out, err = _detect(existing, "opencode", changed)
    assert code == 0 and "efforts" not in json.loads(out)["categories"]["opencode"]
    assert "catalog was unavailable" in err
    # a new variant is written as given after the charset check
    code, out, _ = _detect(None, "opencode", _MODELS_OC + ["--review-effort", "whatever"])
    assert json.loads(out)["categories"]["opencode"]["efforts"] == {"review": "whatever"}


def test_effort_flags_do_not_change_the_unknown_flag_usage_line(tmp_path):
    env = dict(os.environ, CLAUDECODE="1", AIMI_CONFIG_DIR=str(tmp_path))
    done = subprocess.run(["bash", CLI, "detect-models", "--bogus"], capture_output=True,
                          text=True, env=env, stdin=subprocess.DEVNULL)
    assert done.returncode == 1
    assert ("Usage: aimi-cli.sh detect-models [--research <model>] [--review <model>] "
            "[--design <model>] [--workflow <model>] [--executor <model>]\n") in done.stderr


def test_effort_cli_help_lists_all_five_flags():
    done = subprocess.run(["bash", CLI, "help"], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)
    for category in M.CATEGORIES:
        assert "--" + category + "-effort" in done.stdout + done.stderr


# ---------------------------------------------------------------------------
# resolve-efforts and effort-options: the two effort READER verbs.
# ---------------------------------------------------------------------------

EFFORTS_READ_CASES = {c["label"]: c for c in GOLDEN["efforts_read_cases"]}
_INHERIT_LINE = json.dumps(_ALL_INHERIT, separators=(",", ":"))
_VERBOSE = (
    'p/glm\n{\n  "variants": {"high": {}, "max": {}}\n}\n'
    'p/plain\n{\n  "id": "plain"\n}\n'
)


def _stub_bin(tmp_path, catalog=_VERBOSE, variant_flag=True, fail_verbose=False):
    """A directory holding a stub `opencode` that logs every call to calls.log."""
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    (bindir / "catalog.txt").write_text(catalog)
    script = (
        "#!/usr/bin/env bash\n"
        'echo "$*" >> "' + str(tmp_path / "calls.log") + '"\n'
        'case "${1:-} ${2:-}" in\n'
        '  "run --help") ' + ('echo "  --variant  v"' if variant_flag else 'echo "  --model"') + ' ;;\n'
        '  "models --verbose") ' + ('exit 1' if fail_verbose else 'cat "$(dirname "$0")/catalog.txt"') + ' ;;\n'
        "esac\n"
    )
    stub = bindir / "opencode"
    stub.write_text(script)
    stub.chmod(0o755)
    return bindir


def _cli(tmp_path, host, args, config=None, bindir=None, strip_python=False):
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    if config is not None:
        (cfg / "models.json").write_text(config)
    env = {k: v for k, v in os.environ.items() if k not in ("AIMI_PLUGIN_DIR", "CLAUDECODE")}
    env["AIMI_CONFIG_DIR"] = str(cfg)
    if host == "cc":
        env["CLAUDECODE"] = "1"
    path = env["PATH"]
    if strip_python:
        # A PATH holding only bash plus the coreutils the verb needs, no python3.
        safe = tmp_path / "nopy"
        safe.mkdir(exist_ok=True)
        for tool in ("bash", "cat", "mkdir", "dirname", "env", "grep", "sed", "tr", "head", "stat", "rm"):
            found = shutil.which(tool)
            if found and not (safe / tool).exists():
                (safe / tool).symlink_to(found)
        path = str(safe)
    if bindir is not None:
        path = str(bindir) + ":" + path
    env["PATH"] = path
    done = subprocess.run(["bash", CLI] + args, env=env, capture_output=True,
                          text=True, timeout=120, cwd=str(tmp_path))
    return done.returncode, done.stdout.strip(), done.stderr


@pytest.mark.parametrize("label", sorted(EFFORTS_READ_CASES))
def test_resolve_efforts_golden_cases(label, tmp_path):
    case = EFFORTS_READ_CASES[label]
    host = "cc" if case["host"] == "claudeCode" else "oc"
    rc, out, err = _cli(tmp_path, host, ["resolve-efforts"], config=case["config"])
    assert rc == 0
    assert out == case["stdout"]
    assert json.loads(out)
    assert len([l for l in err.splitlines() if "resolve-efforts" in l]) == case["stderr_lines"]


def test_efforts_golden_says_no_jq_produced_it():
    assert "no jq produced" in GOLDEN["_comment_efforts_read"]


def test_efforts_golden_pins_false_as_unset_and_zero_as_invalid():
    assert EFFORTS_READ_CASES["er-false-is-unset-cc"]["stderr_lines"] == 0
    assert EFFORTS_READ_CASES["er-zero-is-invalid-cc"]["stderr_lines"] == 1


def test_resolve_efforts_claudecode_example(tmp_path):
    cfg = json.dumps({"schemaVersion": "2.0",
                      "categories": {"claudeCode": {"efforts": {"review": "high"}}}})
    rc, out, err = _cli(tmp_path, "cc", ["resolve-efforts"], config=cfg)
    assert (rc, out, err) == (0, '{"research":"inherit","review":"high","design":"inherit",'
                                 '"workflow":"inherit","executor":"inherit"}', "")


def test_resolve_efforts_missing_file_is_silent_and_never_crosses(tmp_path):
    rc, out, err = _cli(tmp_path, "cc", ["resolve-efforts"], strip_python=True)
    assert (rc, out, err) == (0, _INHERIT_LINE, "")


@pytest.mark.parametrize("text", ["", "   \n", "{not json", "[]"])
def test_resolve_efforts_unreadable_file_is_all_inherit(tmp_path, text):
    rc, out, err = _cli(tmp_path, "cc", ["resolve-efforts"], config=text)
    assert (rc, out) == (0, _INHERIT_LINE)
    if text != "[]":
        assert err.count("Warning: resolve-efforts:") == 1


def test_resolve_efforts_without_python3_degrades_with_one_line(tmp_path):
    cfg = json.dumps({"schemaVersion": "2.0",
                      "categories": {"claudeCode": {"efforts": {"review": "high"}}}})
    rc, out, err = _cli(tmp_path, "cc", ["resolve-efforts"], config=cfg, strip_python=True)
    assert (rc, out) == (0, _INHERIT_LINE)
    assert err.strip() == ("Warning: resolve-efforts: python3 is required to read models.json "
                           "and was not found; falling back to all-inherit.")


def test_resolve_efforts_never_invokes_opencode(tmp_path):
    bindir = _stub_bin(tmp_path)
    cfg = json.dumps({"schemaVersion": "2.0", "categories": {"opencode": {
        "research": "p/glm", "efforts": {"research": "high"}}}})
    rc, out, _ = _cli(tmp_path, "oc", ["resolve-efforts"], config=cfg, bindir=bindir)
    assert json.loads(out)["research"] == "high"
    assert not (tmp_path / "calls.log").exists()


def test_resolve_efforts_leaves_resolve_models_alone(tmp_path):
    cfg = json.dumps({"schemaVersion": "2.0", "categories": {"claudeCode": {
        "review": "opus", "efforts": {"review": "high", "design": 0}}}})
    rc, out, _ = _cli(tmp_path, "cc", ["resolve-models"], config=cfg)
    assert json.loads(out)["review"] == "opus" and rc == 0


def test_effort_options_claudecode_is_a_constant_without_python3(tmp_path):
    expected = json.dumps(list(M.EFFORT_LEVELS), separators=(",", ":"))
    assert _cli(tmp_path, "cc", ["effort-options"], strip_python=True)[:2] == (0, expected)
    assert _cli(tmp_path, "cc", ["effort-options", "--model", "x/y"])[:2] == (0, expected)


def test_effort_options_opencode_variants_in_catalog_order(tmp_path):
    bindir = _stub_bin(tmp_path)
    assert _cli(tmp_path, "oc", ["effort-options", "--model", "p/glm"], bindir=bindir)[:2] == (0, '["high","max"]')
    assert _cli(tmp_path, "oc", ["effort-options", "--model", "p/plain"], bindir=bindir)[:2] == (0, "[]")
    assert _cli(tmp_path, "oc", ["effort-options", "--model", "p/absent"], bindir=bindir)[:2] == (0, "[]")
    calls = (tmp_path / "calls.log").read_text().splitlines()
    assert calls.count("models --verbose") == 3


def test_effort_options_inherit_does_not_fetch(tmp_path):
    bindir = _stub_bin(tmp_path)
    assert _cli(tmp_path, "oc", ["effort-options", "--model", "inherit"], bindir=bindir)[:2] == (0, "[]")
    assert not (tmp_path / "calls.log").exists()


def test_effort_options_never_prints_a_name_outside_the_pattern(tmp_path):
    bindir = _stub_bin(tmp_path, catalog='p/m\n{"variants": {"ok": {}, "bad name": {}}}\n')
    rc, out, _ = _cli(tmp_path, "oc", ["effort-options", "--model", "p/m"], bindir=bindir)
    assert (rc, out) == (0, '["ok"]')


@pytest.mark.parametrize("kind", ["no-opencode", "no-variant-flag", "verbose-fails", "unparseable"])
def test_effort_options_unavailable_catalog_is_null_with_a_warning(tmp_path, kind):
    bindir = None
    if kind == "no-variant-flag":
        bindir = _stub_bin(tmp_path, variant_flag=False)
    elif kind == "verbose-fails":
        bindir = _stub_bin(tmp_path, fail_verbose=True)
    elif kind == "unparseable":
        bindir = _stub_bin(tmp_path, catalog="not a catalog\n")
    env_strip = kind == "no-opencode"
    rc, out, err = _cli(tmp_path, "oc", ["effort-options", "--model", "p/glm"], bindir=bindir)
    if env_strip:
        pytest.skip("host has a real opencode on PATH") if shutil.which("opencode") else None
    assert (rc, out) == (0, "null")
    assert "Warning: effort-options:" in err


def test_effort_options_without_python3_is_null_with_a_warning(tmp_path):
    bindir = _stub_bin(tmp_path)
    rc, out, err = _cli(tmp_path, "oc", ["effort-options", "--model", "p/glm"],
                        bindir=bindir, strip_python=True)
    assert (rc, out) == (0, "null")
    assert err.count("Warning: effort-options:") == 1


@pytest.mark.parametrize("args", [[], ["--model"], ["--bogus"], ["--model", "p/glm", "extra"]])
def test_effort_options_bad_arguments_exit_one_on_opencode(tmp_path, args):
    bindir = _stub_bin(tmp_path)
    rc, out, err = _cli(tmp_path, "oc", ["effort-options"] + args, bindir=bindir)
    assert (rc, out) == (1, "")
    assert "Error: effort-options:" in err


def test_effort_verbs_are_listed_in_help_and_dispatched_without_a_root(tmp_path):
    rc, out, err = _cli(tmp_path, "cc", ["help"])
    for verb in ("resolve-efforts", "effort-options"):
        assert "    " + verb in out + err
    cli = _source(CLI)
    assert "resolve-efforts) cmd_resolve_efforts" in cli
    assert "effort-options) shift; cmd_effort_options" in cli
    assert '"resolve-efforts": op_resolve_efforts' in _source(os.path.join(SCRIPTS, "models.py"))
    assert '"effort-options": op_effort_options' in _source(os.path.join(SCRIPTS, "models.py"))


def test_resolve_efforts_op_malformed_models_table_means_every_model_unset():
    done = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "models.py"), "resolve-efforts", "--host", "opencode"],
        input=json.dumps({"categories": {"opencode": "nope"}}), capture_output=True, text=True)
    assert done.returncode == 0 and done.stdout.strip() == _INHERIT_LINE
