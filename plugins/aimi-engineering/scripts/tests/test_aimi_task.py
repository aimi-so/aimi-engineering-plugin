"""Tests for tools/aimi-task.ts, the OpenCode spawn tool.

The repository has no tsc, no tsconfig and no earlier harness for this tool, so
it is tested by running it. The test copies the tool beside a stub
`node_modules/@opencode-ai/plugin` (a `tool()` that returns its argument and a
`schema` that records nothing) and puts a stub named exactly `opencode` first
on PATH. The stub records its argv, one element per line, and prints or fails
as the case directs. A small driver `.ts` calls `execute` and prints the result
as JSON. The real `opencode` binary is unreachable: the test asserts the stub
is what PATH resolves before it runs anything.

bun is a maintainer-machine tool, not a repository dependency, so this module
skips without it. The story's verify requires bun and fails if it is absent.
"""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

BUN = shutil.which("bun")
pytestmark = pytest.mark.skipif(BUN is None, reason="bun is not installed")

TOOLS = Path(__file__).resolve().parents[2] / "tools"
TOOL_SRC = TOOLS / "aimi-task.ts"
MODELS_PY = Path(__file__).resolve().parents[1] / "models.py"

PLUGIN_STUB = """
const chain = () => {
  const o: any = {}
  o.optional = () => o
  o.describe = () => o
  return o
}
export const tool: any = (def: any) => def
tool.schema = { string: () => chain() }
"""

DRIVER = """
import t from "./aimi-task.ts"
const args = JSON.parse(process.env.AIMI_TEST_ARGS as string)
try {
  const out = await (t as any).execute(args, { directory: "/work/dir" })
  console.log(JSON.stringify({ ok: true, out }))
} catch (e: any) {
  console.log(JSON.stringify({ ok: false, error: String(e && e.message) }))
}
"""

STUB_OPENCODE = """#!/usr/bin/env bash
: > "$AIMI_TEST_ARGV"
for a in "$@"; do printf '%s\\n' "$a" >> "$AIMI_TEST_ARGV"; done
printf 'x' >> "$AIMI_TEST_COUNT"
if [ -n "${AIMI_TEST_FAIL_OUT:-}" ]; then
  printf '%s\\n' "$AIMI_TEST_FAIL_OUT" >&2
  exit 3
fi
printf 'stub-ok'
"""


@pytest.fixture()
def harness(tmp_path):
    work = tmp_path / "work"
    plug = work / "node_modules" / "@opencode-ai" / "plugin"
    plug.mkdir(parents=True)
    (plug / "package.json").write_text(
        '{"name":"@opencode-ai/plugin","type":"module","main":"index.ts"}'
    )
    (plug / "index.ts").write_text(PLUGIN_STUB)
    shutil.copy(TOOL_SRC, work / "aimi-task.ts")
    (work / "driver.ts").write_text(DRIVER)
    binp = tmp_path / "bin"
    binp.mkdir()
    stub = binp / "opencode"
    stub.write_text(STUB_OPENCODE)
    stub.chmod(0o755)
    env = dict(os.environ)
    env["PATH"] = f"{binp}:{env['PATH']}"
    env["AIMI_TEST_ARGV"] = str(tmp_path / "argv")
    env["AIMI_TEST_COUNT"] = str(tmp_path / "count")
    env.pop("AIMI_TEST_FAIL_OUT", None)
    assert shutil.which("opencode", path=env["PATH"]) == str(stub)

    def run(args, fail_out=None):
        e = dict(env)
        e["AIMI_TEST_ARGS"] = json.dumps(args)
        if fail_out is not None:
            e["AIMI_TEST_FAIL_OUT"] = fail_out
        (tmp_path / "argv").write_text("")
        (tmp_path / "count").write_text("")
        r = subprocess.run(
            [BUN, "run", "driver.ts"], cwd=work, env=e,
            capture_output=True, text=True, timeout=60,
        )
        assert r.returncode == 0, r.stderr
        res = json.loads(r.stdout.strip().splitlines()[-1])
        argv = (tmp_path / "argv").read_text().splitlines()
        calls = len((tmp_path / "count").read_text())
        return res, argv, calls

    return run


BASE = {"subagent_type": "aimi-engineering:review:aimi-x", "prompt": "do it"}


def test_variant_follows_model_and_precedes_prompt(harness):
    res, argv, calls = harness(
        {**BASE, "model": "anthropic/claude-sonnet-4-6", "variant": "high"}
    )
    assert res["ok"] is True
    assert calls == 1
    assert argv == [
        "run", "--agent", "aimi-x", "--dir", "/work/dir",
        "--model", "anthropic/claude-sonnet-4-6", "--variant", "high", "do it",
    ]


@pytest.mark.parametrize("variant", [None, "", "inherit"])
def test_unset_variant_keeps_the_old_argv(harness, variant):
    args = {**BASE, "model": "anthropic/claude-sonnet-4-6"}
    if variant is not None:
        args["variant"] = variant
    res, argv, _ = harness(args)
    assert res["ok"] is True
    assert argv == [
        "run", "--agent", "aimi-x", "--dir", "/work/dir",
        "--model", "anthropic/claude-sonnet-4-6", "do it",
    ]
    assert "--variant" not in argv


def test_no_model_no_variant_is_unchanged(harness):
    res, argv, _ = harness({**BASE, "model": "inherit", "variant": "inherit"})
    assert res["ok"] is True
    assert argv == ["run", "--agent", "aimi-x", "--dir", "/work/dir", "do it"]


@pytest.mark.parametrize("bad", ["-high", "a b", "hi;gh", "x" * 65, "high#1", "../x"])
def test_invalid_variant_throws_naming_it_and_does_not_spawn(harness, bad):
    res, _, calls = harness({**BASE, "model": "anthropic/claude-sonnet-4-6", "variant": bad})
    assert res["ok"] is False
    assert bad in res["error"]
    assert calls == 0


@pytest.mark.parametrize("model", [None, "", "inherit"])
def test_variant_without_model_throws(harness, model):
    args = {**BASE, "variant": "high"}
    if model is not None:
        args["model"] = model
    res, _, calls = harness(args)
    assert res["ok"] is False
    assert "high" in res["error"]
    assert calls == 0


def test_model_pattern_still_rejects_hash(harness):
    res, _, calls = harness({**BASE, "model": "anthropic/claude-sonnet-4-6#high"})
    assert res["ok"] is False
    assert calls == 0


def test_rejected_variant_names_variant_and_model_and_does_not_retry(harness):
    res, _, calls = harness(
        {**BASE, "model": "anthropic/claude-sonnet-4-6", "variant": "turbo"},
        fail_out="error: unknown variant turbo",
    )
    assert res["ok"] is False
    err = res["error"]
    assert "turbo" in err and "anthropic/claude-sonnet-4-6" in err
    assert "/aimi:setup-models" in err
    assert "not retried" in err
    assert calls == 1


@pytest.mark.parametrize("variant", [None, "high"])
def test_other_failures_keep_the_generic_message(harness, variant):
    args = {**BASE, "model": "anthropic/claude-sonnet-4-6"}
    if variant:
        args["variant"] = variant
    res, _, calls = harness(args, fail_out="network down")
    assert res["ok"] is False
    assert "opencode run failed for agent" in res["error"]
    assert calls == 1


def test_variant_pattern_literal_matches_models_py():
    ts = TOOL_SRC.read_text()
    m = re.search(r"SAFE_VARIANT_PATTERN = /\^(.*)\$/", ts)
    assert m, "SAFE_VARIANT_PATTERN not found"
    py = re.search(r'_VARIANT_RE = re.compile\(r"(.*)"\)', MODELS_PY.read_text())
    assert py, "_VARIANT_RE not found"
    assert m.group(1) == py.group(1)
    assert "SAFE_MODEL_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._-]*(?:\\/[a-zA-Z0-9][a-zA-Z0-9._-]*)?$/" in ts
