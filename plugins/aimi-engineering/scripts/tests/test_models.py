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

It must never be regenerated from models.py. If a case goes red, either the
port drifted or a rule genuinely changed; in the second case the golden changes
in the same commit as the rule, with the reason in the message.
"""

import json
import os
import re
import shutil
import subprocess
import sys

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


def test_the_divergence_table_names_only_cases_that_exist():
    """A label that stops existing must not sit here quietly excusing nothing."""
    assert set(KNOWN_DIVERGENCES) <= set(CASES)
    for label, fields in KNOWN_DIVERGENCES.items():
        assert set(fields) <= {"exit", "stdout", "stderr", "files"}, label


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
                 "cmd_models_prompt_check", "cmd_list_models"):
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
