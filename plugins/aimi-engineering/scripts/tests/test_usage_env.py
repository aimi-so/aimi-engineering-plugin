"""Tests for scripts/usage_env.py, the module behind `usage-env-up`, `usage-env-status`
and `usage-env-down`.

Everything goes through the CLI as a subprocess against a throwaway layout: a
git repository with an `.aimi/` and a worktree under `.worktrees/`. Servers are
python3's stdlib http.server bound to 127.0.0.1 on a port the OS hands out; no
test names a fixed port.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
sys.path.insert(0, SCRIPTS)

import usage_env  # noqa: E402

needs_tools = pytest.mark.skipif(
    not (shutil.which("jq") and shutil.which("git")), reason="needs jq and git"
)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Layout:
    def __init__(self, root):
        self.root = root
        self.runs = []
        self.env = dict(os.environ, AIMI_USAGE_ENV_READY_TIMEOUT="20", DEV_SERVER_READY_TIMEOUT="20")
        self.env.pop("AIMI_DEV_DIR", None)

    def git(self, *args):
        subprocess.run(["git", "-C", self.root, *args], check=True, stdout=subprocess.DEVNULL)

    def cli(self, *args, env=None, cwd=None):
        e = dict(self.env, **(env or {}))
        return subprocess.run([CLI, *args], cwd=cwd or self.root, env=e, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)

    def js(self, *args, **kw):
        out = self.cli(*args, **kw)
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout.strip().splitlines()[-1])

    def record(self, project=".", **flags):
        argv = ["usage-recipe-record", "--project", project]
        for k, v in flags.items():
            for item in (v if isinstance(v, list) else [v]):
                argv += ["--" + k.replace("_", "-"), str(item)]
        out = self.cli(*argv)
        assert out.returncode == 0, out.stderr

    def serve_cmd(self, port):
        return "python3 -m http.server %d --bind 127.0.0.1" % port

    def up(self, run, *repos, restart=False, **kw):
        argv = ["usage-env-up", "--run", run]
        for r in repos:
            argv += ["--repo", r]
        if restart:
            argv.append("--restart")
        self.runs.append((run, list(repos)))
        return self.cli(*argv, **kw)

    def wait(self, run, secs=30):
        return self.js("usage-env-status", "--run", run, "--wait", str(secs))

    def state(self, run):
        path = os.path.join(self.root, ".aimi", "state", "usage-env", run.replace("/", "_") + ".json")
        with open(path) as fh:
            return json.load(fh)


@pytest.fixture
def lay():
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.realpath(tmp)
        layout = Layout(root)
        layout.git("init", "-q")
        layout.git("config", "user.email", "t@example.com")
        layout.git("config", "user.name", "t")
        layout.git("commit", "-q", "--allow-empty", "-m", "i")
        os.makedirs(os.path.join(root, ".aimi"))
        os.makedirs(os.path.join(root, ".worktrees", "w1"))
        with open(os.path.join(root, ".worktrees", "w1", "index.html"), "w") as fh:
            fh.write("hi\n")
        yield layout
        for run, _ in layout.runs:
            layout.cli("usage-env-down", "--run", run)


def read(path):
    with open(path) as fh:
        return fh.read()


@needs_tools
def test_usage_env_lifecycle_runs_setup_serves_and_cleans_up(lay):
    port = free_port()
    lay.record(setup=["touch setup-1", "touch setup-2"], serve=lay.serve_cmd(port), port=port,
               ready="/index.html", cleanup=["touch cleanup-1"])
    started = time.monotonic()
    out = lay.up("run-a", ".=w1")
    assert out.returncode == 0, out.stderr
    assert time.monotonic() - started < 10
    first = json.loads(out.stdout)
    assert first["status"] == "starting" and set(first) == {"run", "status", "stage", "state"}

    st = lay.wait("run-a")
    assert st["status"] == "ready"
    assert st["repositories"] == [{"project": ".", "status": "ready", "url": "http://127.0.0.1:%d" % port}]
    wt = os.path.join(lay.root, ".worktrees", "w1")
    assert os.path.exists(os.path.join(wt, "setup-1")) and os.path.exists(os.path.join(wt, "setup-2"))
    assert not os.path.exists(os.path.join(lay.root, "setup-1"))
    entry = json.load(open(os.path.join(lay.root, ".aimi", "state", "dev-server.json")))[wt]
    assert entry["command"] == lay.serve_cmd(port)

    down = lay.js("usage-env-down", "--run", "run-a")
    assert down == {"run": "run-a", "status": "down", "cleanupFailed": 0, "stopped": 1}
    assert os.path.exists(os.path.join(wt, "cleanup-1"))
    assert lay.js("usage-env-status", "--run", "run-a")["status"] == "down"
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", port), timeout=1).close()


@needs_tools
def test_usage_env_no_recipe_answers_unable_to_evaluate_and_spawns_nothing(lay):
    out = lay.up("run-n", ".=w1")
    assert out.returncode == 0
    doc = json.loads(out.stdout)
    assert doc["status"] == "unable-to-evaluate"
    state = lay.state("run-n")
    assert state["status"] == "unable-to-evaluate" and state["reason"] == "no usage recipe recorded"
    assert not os.path.exists(os.path.join(lay.root, ".aimi", "state", "dev-server.json"))
    assert lay.js("usage-env-status", "--run", "run-n")["status"] == "unable-to-evaluate"


@needs_tools
def test_usage_env_refusals_exit_1_before_anything_starts(lay):
    lay.record(serve=lay.serve_cmd(free_port()), ready="/")
    other = tempfile.mkdtemp()
    try:
        cases = [
            ("bad run", ["usage-env-up", "--run", "bad!", "--repo", "."]),
            ("no run", ["usage-env-up", "--repo", "."]),
            ("no repo", ["usage-env-up", "--run", "r"]),
            ("duplicate", ["usage-env-up", "--run", "r", "--repo", ".", "--repo", ".=w1"]),
            ("outside", ["usage-env-up", "--run", "r", "--repo", "../elsewhere"]),
            ("absolute", ["usage-env-up", "--run", "r", "--repo", other]),
            ("missing container", ["usage-env-up", "--run", "r", "--repo", ".=nope"]),
            ("bad branch", ["usage-env-up", "--run", "r", "--repo", ".=../x"]),
        ]
        os.symlink(other, os.path.join(lay.root, "link"))
        cases.append(("symlink out", ["usage-env-up", "--run", "r", "--repo", "link"]))
        for name, argv in cases:
            out = lay.cli(*argv)
            assert out.returncode == 1, (name, out.stdout, out.stderr)
            assert out.stdout == ""
        assert not os.path.exists(os.path.join(lay.root, ".aimi", "state", "usage-env"))
        # A layout that is not a git repository: a project directory that is no
        # repository either is refused.
        with tempfile.TemporaryDirectory() as plain:
            os.makedirs(os.path.join(plain, ".aimi"))
            os.makedirs(os.path.join(plain, "not-a-repo"))
            out = lay.cli("usage-env-up", "--run", "r", "--repo", "not-a-repo", cwd=plain)
            assert out.returncode == 1 and "no git repository" in out.stderr
    finally:
        shutil.rmtree(other, ignore_errors=True)


@needs_tools
def test_usage_env_status_flags(lay):
    out = lay.cli("usage-env-status")
    assert out.returncode == 1 and "usage-env-status: --run" in out.stderr
    for wait in ("61", "-1", "x"):
        out = lay.cli("usage-env-status", "--run", "r", "--wait", wait)
        assert out.returncode == 1, wait
    assert lay.js("usage-env-status", "--run", "never")["status"] == "absent"
    assert lay.js("usage-env-down", "--run", "never") == {"run": "never", "status": "absent"}


@needs_tools
def test_usage_env_setup_failure_is_failed_with_stage_and_command(lay):
    port = free_port()
    lay.record(setup=["touch ok-1", "false", "touch never-2"], serve=lay.serve_cmd(port), ready="/", port=port)
    assert lay.up("run-f", ".=w1").returncode == 0
    st = lay.wait("run-f")
    assert st["status"] == "failed"
    assert st["stage"].startswith("setup:.:2")
    assert "false" in st["reason"]
    wt = os.path.join(lay.root, ".worktrees", "w1")
    assert os.path.exists(os.path.join(wt, "ok-1")) and not os.path.exists(os.path.join(wt, "never-2"))
    assert not os.path.exists(os.path.join(lay.root, ".aimi", "state", "dev-server.json"))


@needs_tools
def test_usage_env_first_word_not_on_path_fails_its_stage_and_runs_nothing(lay):
    lay.record(setup=["no-such-binary-xyz arg", "touch after"], serve=lay.serve_cmd(free_port()), ready="/")
    lay.up("run-p", ".=w1")
    st = lay.wait("run-p")
    assert st["status"] == "failed" and "no-such-binary-xyz" in st["reason"]
    assert not os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "after"))


@needs_tools
def test_usage_env_shell_metacharacter_in_stored_recipe_runs_nothing(lay):
    lay.record(setup=["touch clean"], serve=lay.serve_cmd(free_port()), ready="/")
    cfg = os.path.join(lay.root, ".aimi", "config.json")
    doc = json.load(open(cfg))
    doc["usage"]["recipe"]["."]["setup"] = ["touch pwned; touch pwned2"]
    json.dump(doc, open(cfg, "w"))
    out = lay.up("run-m", ".=w1")
    assert out.returncode == 0
    assert json.loads(out.stdout)["status"] == "unable-to-evaluate"
    assert not os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "pwned"))
    assert not os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "pwned2"))


@needs_tools
def test_usage_env_step_timeout_fails_the_bring_up(lay):
    lay.record(setup=["sleep 30"], serve=lay.serve_cmd(free_port()), ready="/")
    lay.up("run-t", ".=w1", env={"AIMI_USAGE_ENV_STEP_TIMEOUT": "1"})
    st = lay.wait("run-t", 30)
    assert st["status"] == "failed" and "timed out" in st["reason"] and "sleep 30" in st["reason"]


@needs_tools
def test_usage_env_busy_fixed_port_is_unable_to_evaluate_before_setup(lay):
    holder = socket.socket()
    holder.bind(("127.0.0.1", 0))
    holder.listen(1)
    port = holder.getsockname()[1]
    try:
        lay.record(setup=["touch should-not-run"], serve=lay.serve_cmd(port), port=port, ready="/")
        lay.up("run-b", ".=w1")
        st = lay.wait("run-b")
        assert st["status"] == "unable-to-evaluate" and str(port) in st["reason"]
        assert not os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "should-not-run"))
    finally:
        holder.close()


@needs_tools
def test_usage_env_a_recipe_without_serve_gets_no_server(lay):
    lay.record(cli="true", setup=["touch only-setup"])
    lay.up("run-c", ".=w1")
    st = lay.wait("run-c")
    assert st["status"] == "ready"
    assert st["repositories"][0]["url"] is None
    assert os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "only-setup"))


@needs_tools
def test_usage_env_inline_run_serves_the_checkout_itself(lay):
    port = free_port()
    lay.record(setup=["touch inline-setup"], serve=lay.serve_cmd(port), port=port, ready="/")
    lay.up("run-i", ".")
    st = lay.wait("run-i")
    assert st["status"] == "ready" and st["repositories"][0]["url"] == "http://127.0.0.1:%d" % port
    assert os.path.exists(os.path.join(lay.root, "inline-setup"))
    key = json.load(open(os.path.join(lay.root, ".aimi", "state", "dev-server.json")))
    assert list(key) == [lay.root]
    lay.js("usage-env-down", "--run", "run-i")


@needs_tools
def test_usage_env_plain_up_reuses_a_ready_run_and_refuses_a_starting_one(lay):
    port = free_port()
    lay.record(setup=["sh -c true"], serve=lay.serve_cmd(port), port=port, ready="/")
    lay.up("run-r", ".=w1")
    assert lay.wait("run-r")["status"] == "ready"
    again = lay.up("run-r", ".=w1")
    assert again.returncode == 0 and json.loads(again.stdout)["reused"] is True

    lay.js("usage-env-down", "--run", "run-r")
    lay.record(setup=["sleep 20"], serve=lay.serve_cmd(free_port()), ready="/")
    lay.up("run-s", ".=w1")
    refused = lay.up("run-s", ".=w1")
    assert refused.returncode == 1
    assert lay.js("usage-env-status", "--run", "run-s")["status"] == "starting"
    down = lay.js("usage-env-down", "--run", "run-s")
    assert down["status"] == "down"
    assert not usage_env._runner_alive(os.path.join(lay.root, ".aimi", "state", "usage-env", "run-s.lock"))


@needs_tools
def test_usage_env_restart_does_not_repeat_setup(lay):
    port = free_port()
    lay.record(setup=["sh -c true", "touch marker"], serve=lay.serve_cmd(port), port=port, ready="/")
    lay.up("run-x", ".=w1")
    assert lay.wait("run-x")["status"] == "ready"
    wt = os.path.join(lay.root, ".worktrees", "w1")
    os.unlink(os.path.join(wt, "marker"))
    key = os.path.join(lay.root, ".aimi", "state", "dev-server.json")
    pid1 = json.load(open(key))[wt]["pid"]
    out = lay.up("run-x", ".=w1", restart=True)
    assert out.returncode == 0 and json.loads(out.stdout)["status"] == "starting"
    st = lay.wait("run-x")
    assert st["status"] == "ready"
    assert not os.path.exists(os.path.join(wt, "marker"))
    assert json.load(open(key))[wt]["pid"] != pid1


@needs_tools
def test_usage_env_down_counts_a_failing_cleanup_and_runs_the_rest(lay):
    lay.record(cli="true", cleanup=["false", "touch cleaned-after"])
    lay.up("run-d", ".=w1")
    assert lay.wait("run-d")["status"] == "ready"
    down = lay.js("usage-env-down", "--run", "run-d")
    assert down["cleanupFailed"] == 1 and down["status"] == "down"
    assert os.path.exists(os.path.join(lay.root, ".worktrees", "w1", "cleaned-after"))


@needs_tools
def test_usage_env_status_reports_a_dead_runner_as_failed(lay):
    lay.record(cli="true")
    state_dir = os.path.join(lay.root, ".aimi", "state", "usage-env")
    os.makedirs(state_dir)
    doc = {"run": "ghost", "status": "starting", "stage": "setup:.:1/1", "reason": None,
           "repositories": [{"project": ".", "status": "starting", "url": None}], "log": "x.log"}
    json.dump(doc, open(os.path.join(state_dir, "ghost.json"), "w"))
    st = lay.js("usage-env-status", "--run", "ghost", "--wait", "2")
    assert st["status"] == "failed" and st["reason"] == "bring-up process exited"


@needs_tools
def test_usage_env_default_dev_server_is_stopped_before_the_recipe_server(lay, tmp_path):
    stub = tmp_path / "bin"
    stub.mkdir()
    npm = stub / "npm"
    npm.write_text('#!/bin/bash\nscript=$(jq -r --arg s "$2" \'.scripts[$s]\' package.json)\nexec bash -c "$script"\n')
    npm.chmod(0o755)
    env = {"PATH": "%s:%s" % (stub, os.environ["PATH"])}
    wt = os.path.join(lay.root, ".worktrees", "w1")
    with open(os.path.join(wt, "package.json"), "w") as fh:
        json.dump({"name": "x", "scripts": {"dev": 'exec python3 -m http.server "$PORT" --bind 127.0.0.1'}}, fh)
    os.makedirs(os.path.join(wt, "node_modules"))
    manager = os.path.join(os.path.dirname(SCRIPTS), "skills", "git-worktree", "scripts", "worktree-manager.sh")
    started = subprocess.run(["bash", manager, "serve", "start", "w1"], cwd=lay.root,
                             env=dict(lay.env, **env), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert started.stdout.startswith("http://127.0.0.1:"), started.stderr
    default_port = int(started.stdout.strip().rsplit(":", 1)[1])
    port = free_port()
    lay.record(serve=lay.serve_cmd(port), port=port, ready="/")
    lay.up("run-e", ".=w1", env=env)
    st = lay.wait("run-e")
    assert st["status"] == "ready", st
    assert st["repositories"][0]["url"] == "http://127.0.0.1:%d" % port
    assert port != default_port
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", default_port), timeout=1).close()


def test_usage_env_main_usage_is_exit_2():
    assert usage_env.main(["usage_env.py"]) == 2
    assert usage_env.main(["usage_env.py", "nonsense"]) == 2


def test_usage_env_ready_path_never_leaves_loopback():
    assert usage_env._ready_path("/health?x=1") == "/health?x=1"
    assert usage_env._ready_path("http://localhost:9999/ok") == "/ok"
    assert usage_env._ready_path("https://127.0.0.1") == "/"


# --------------------------------------------------------------------------
# The state file is never trusted for what runs
# --------------------------------------------------------------------------

def _plant(lay, run, doc):
    state_dir = os.path.join(lay.root, ".aimi", "state", "usage-env")
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, run + ".json")
    with open(path, "w") as fh:
        json.dump(doc, fh)
    return path


def _evil(tmp_path, name):
    """A script that leaves <tmp_path>/<name>.ran behind when anything runs it."""
    marker = tmp_path / (name + ".ran")
    script = tmp_path / (name + ".sh")
    script.write_text('#!/bin/bash\ntouch "%s"\n' % marker)
    script.chmod(0o755)
    return str(script), marker


def _direct(*args):
    return subprocess.run([sys.executable, os.path.join(SCRIPTS, "usage_env.py"), *args],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)


@needs_tools
def test_usage_env_down_never_runs_the_manager_or_cleanup_a_planted_state_names(lay, tmp_path):
    evil_manager, manager_marker = _evil(tmp_path, "manager")
    evil_cleanup, cleanup_marker = _evil(tmp_path, "cleanup")
    _plant(lay, "run1", {
        "run": "run1", "status": "ready", "manager": evil_manager,
        "repositories": [{"project": ".", "worktree": lay.root, "toplevel": lay.root}],
        "recipes": {".": {"cleanup": ["bash " + evil_cleanup]}},
        "servers": [{"project": ".", "toplevel": lay.root, "target": ["--root"]}],
        "runnerPid": os.getpid(),
    })
    down = lay.js("usage-env-down", "--run", "run1")
    assert down["status"] == "down" and down["cleanupFailed"] == 0
    assert not manager_marker.exists() and not cleanup_marker.exists()
    assert "manager" not in lay.state("run1")

    # The module itself, called the way the finding reproduced it, refuses
    # without the wrapper's manager and still runs nothing from the file.
    _plant(lay, "run2", {
        "run": "run2", "status": "ready", "manager": evil_manager,
        "repositories": [{"project": ".", "worktree": lay.root}],
        "recipes": {".": {"cleanup": ["bash " + evil_cleanup]}},
        "servers": [{"project": ".", "toplevel": lay.root, "target": ["--root"]}],
    })
    out = _direct("down", "--aimi-root", lay.root, "--run", "run2")
    assert out.returncode == 1 and "--manager" in out.stderr
    assert not manager_marker.exists() and not cleanup_marker.exists()


@needs_tools
def test_usage_env_down_runs_the_trusted_recipe_cleanup_only_inside_the_layout(lay, tmp_path):
    lay.record(cli="true", cleanup=["touch trusted-cleanup"])
    outside = tmp_path / "outside"
    outside.mkdir()
    _plant(lay, "run3", {
        "run": "run3", "status": "ready",
        "repositories": [{"project": ".", "worktree": str(outside)}],
        "recipes": {".": {"cleanup": ["touch planted-cleanup"]}}, "servers": [],
    })
    down = lay.js("usage-env-down", "--run", "run3")
    assert down["cleanupFailed"] == 1
    assert not (outside / "trusted-cleanup").exists() and not (outside / "planted-cleanup").exists()

    _plant(lay, "run4", {
        "run": "run4", "status": "ready",
        "repositories": [{"project": ".", "worktree": os.path.join(lay.root, ".worktrees", "w1")}],
        "recipes": {".": {"cleanup": ["touch planted-cleanup"]}}, "servers": [],
    })
    assert lay.js("usage-env-down", "--run", "run4")["cleanupFailed"] == 0
    wt = os.path.join(lay.root, ".worktrees", "w1")
    assert os.path.exists(os.path.join(wt, "trusted-cleanup"))
    assert not os.path.exists(os.path.join(wt, "planted-cleanup"))


@needs_tools
def test_usage_env_server_entries_from_the_file_are_confined(lay, tmp_path):
    # A stand-in manager that records the directory it was run from.
    manager = tmp_path / "manager.sh"
    manager.write_text('#!/bin/bash\ntouch "$PWD/manager-ran"\n')
    manager.chmod(0o755)
    outside = tmp_path / "outside"
    outside.mkdir()
    _plant(lay, "run5", {
        "run": "run5", "status": "ready", "repositories": [],
        "servers": [
            {"project": "a", "toplevel": str(outside), "target": ["--root"]},
            {"project": "b", "toplevel": lay.root, "target": ["../escape"]},
            {"project": "c", "toplevel": lay.root, "target": ["--root", "--command", "x"]},
        ],
    })
    out = _direct("down", "--aimi-root", lay.root, "--manager", str(manager), "--run", "run5")
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout)["stopped"] == 0
    assert not (outside / "manager-ran").exists()
    assert not os.path.exists(os.path.join(lay.root, "manager-ran"))

    # The same stand-in IS run for a confined entry, so the absence above is
    # the confinement and not a manager that never runs.
    _plant(lay, "run6", {"run": "run6", "status": "ready", "repositories": [],
                         "servers": [{"project": ".", "toplevel": lay.root, "target": ["--root"]}]})
    out = _direct("down", "--aimi-root", lay.root, "--manager", str(manager), "--run", "run6")
    assert json.loads(out.stdout)["stopped"] == 1
    assert os.path.exists(os.path.join(lay.root, "manager-ran"))
    os.unlink(os.path.join(lay.root, "manager-ran"))

    # up's reuse check never hands an unconfined previous server to the manager.
    _plant(lay, "run7", {"run": "run7", "status": "ready", "stage": "ready", "repositories": [],
                         "servers": [{"project": "a", "toplevel": str(outside), "target": ["--root"]}]})
    out = _direct("up", "--aimi-root", lay.root, "--manager", str(manager), "--run", "run7", "--repo", ".=w1")
    assert out.returncode == 0, out.stderr
    assert json.loads(out.stdout)["status"] == "unable-to-evaluate"
    assert not (outside / "manager-ran").exists()
    assert lay.state("run7")["previousServers"] == []


@needs_tools
def test_usage_env_a_state_file_git_tracks_is_refused(lay, tmp_path):
    evil_manager, manager_marker = _evil(tmp_path, "manager")
    path = _plant(lay, "run8", {
        "run": "run8", "status": "ready", "manager": evil_manager, "repositories": [],
        "servers": [{"project": ".", "toplevel": lay.root, "target": ["--root"]}],
    })
    lay.git("add", "-f", path)
    down = lay.cli("usage-env-down", "--run", "run8")
    assert down.returncode == 1 and "tracked by git" in down.stderr
    up = lay.cli("usage-env-up", "--run", "run8", "--repo", ".=w1")
    assert up.returncode == 1 and "tracked by git" in up.stderr
    assert not manager_marker.exists()
    lay.git("rm", "-q", "--cached", path)
