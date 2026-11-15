#!/usr/bin/env python3
"""usage_env.py -- bring the whole product up from the recorded usage recipe.

Real-usage validation drives the product the way a person would, so something
has to start it. This module is that something, behind three verbs of
`aimi-cli.sh`: `usage-env-up`, `usage-env-status` and `usage-env-down`. The
recorded usage recipe, read in process through `usage_recipe.get` (the reader
behind `usage-recipe-get`, with its tracked-config check), is the ONLY source
of what runs: no package.json, Makefile or other convention is
consulted, and the package-manager `run dev` default is never started.

Shaped like deps_recipe.py and usage_recipe.py: an `_OPS` table, `main(argv)`,
usage at exit 2. Four ops:

  up      --aimi-root P --manager P --run K --repo project[=branch]...
          [--restart]
  run     --state P --manager P  (the detached runner; never called by hand)
  status  --aimi-root P --run K [--wait N]
  down    --aimi-root P --manager P --run K

The wrapper in aimi-cli.sh owns the flags, `check_python3` and the manager
lookup; this module owns the rules.

THE SHAPE OF A RUN
------------------
`up` validates everything that can be refused (exit 1) before anything starts,
writes the state file, and starts a detached runner with
`subprocess.Popen(start_new_session=True)` (macOS has no `setsid`). The runner
walks the repositories in the order given: setup steps, then the serve command
through `worktree-manager.sh serve start --command`, then the readiness URL.
It rewrites `.aimi/state/usage-env/<run, / as _>.json` atomically at each
stage and logs to a `.log` beside it.

RUNNER LIVENESS IS AN flock, NOT A PID. `up` takes an exclusive `flock` on
`<state>.lock` and hands the descriptor to the runner, which holds it for its
whole life. A reader that cannot take the lock knows a runner is alive; a pid
recycled into something else can never fake that, which is the failure
`dev_server_entry_is_ours` exists to prevent on the server side.

EVERYTHING RUNS AS ARGV WITH NO SHELL. A step or serve command holding any of
`; | & $ < >`, a backtick or a newline, or whose first word is not on PATH,
fails its stage and runs nothing. Every manager call runs with the repository
toplevel as working directory, because serve start, stop and status derive
their key from it.

THE STATE FILE IS NEVER TRUSTED FOR WHAT RUNS. It records progress, not
authority: nothing executable is read back from it. The manager always comes
from the wrapper (`--manager`, resolved beside the CLI) and is never persisted;
`down` re-reads each project's cleanup steps from the trusted recipe instead of
the copy in the file; every directory taken from the file (a repository
worktree, a server toplevel) must resolve inside `--aimi-root`, and a server
target must be `--root` or a valid branch name, or it is skipped. A state file
git tracks is refused outright by `up` and `down`, the rule
`deps_recipe.config_is_tracked` already applies to the config, because a
tracked file is content anyone with commit access wrote.
"""

import fcntl
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

import deps_recipe as D
import usage_recipe as U

Refusal = D.Refusal

UP_VERB = "usage-env-up"
STATUS_VERB = "usage-env-status"
DOWN_VERB = "usage-env-down"

RUN_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")
BRANCH_RE = RUN_RE
STATE_SUBDIR = os.path.join(".aimi", "state", "usage-env")
DEV_SERVER_STATE = os.path.join(".aimi", "state", "dev-server.json")

DEFAULT_STEP_TIMEOUT = 900
DEFAULT_READY_TIMEOUT = 300
MAX_WAIT = 60
STATUSES = ("starting", "ready", "unable-to-evaluate", "failed", "down", "absent")
STOP_GRACE = 10


# --------------------------------------------------------------------------
# State files
# --------------------------------------------------------------------------

def _state_paths(aimi_root, run):
    base = os.path.join(aimi_root, STATE_SUBDIR, run.replace("/", "_"))
    return base + ".json", base + ".log", base + ".lock"


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _env_seconds(name, default):
    raw = os.environ.get(name, "")
    if raw.isascii() and raw.isdigit() and int(raw) > 0:
        return int(raw)
    return default


def _atomic_write(path, doc):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".usage-env.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _read_state(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def _runner_alive(lock_path):
    """True while some process holds the run's lock (the runner, by construction)."""
    try:
        fd = os.open(lock_path, os.O_RDWR)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def _emit(doc):
    sys.stdout.write(json.dumps(doc, ensure_ascii=False) + "\n")


def _public_repos(state):
    return [
        {"project": r.get("project"), "status": r.get("status"), "url": r.get("url")}
        for r in state.get("repositories", [])
    ]


# --------------------------------------------------------------------------
# Commands, as argv
# --------------------------------------------------------------------------

def _plain(cmd):
    if not isinstance(cmd, str) or not cmd.strip():
        return False
    if any(c in D.FORBIDDEN_COMMAND_CHARS for c in cmd):
        return False
    return not D._has_control(cmd)


def _argv_for(cmd, cwd):
    """(argv, None) for a plain command whose first word is on PATH, else (None, why)."""
    if not _plain(cmd):
        return None, "not a plain command (it holds one of ; | & $ < > or a backtick, or a newline)"
    argv = cmd.split()
    first = argv[0]
    found = os.path.join(cwd, first) if "/" in first else shutil.which(first)
    if not found or not os.path.isfile(found) or not os.access(found, os.X_OK):
        return None, "its first word is not on PATH: %s" % first
    return argv, None


class _Child:
    """The step currently running, so a SIGTERM to the runner can stop it too."""
    pgid = None


def _kill_group(pgid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pgid, sig)
        except OSError:
            return
        if sig == signal.SIGTERM:
            time.sleep(0.5)


def _run_argv(argv, cwd, log, timeout):
    """Run argv with no shell. Returns ("ok", 0), ("exit", n) or ("timeout", None)."""
    proc = subprocess.Popen(
        argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
        start_new_session=True,
    )
    _Child.pgid = proc.pid
    try:
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(proc.pid)
            proc.wait()
            return "timeout", None
    finally:
        _Child.pgid = None
    return ("ok", 0) if rc == 0 else ("exit", rc)


# --------------------------------------------------------------------------
# The manager (worktree-manager.sh serve ...)
# --------------------------------------------------------------------------

def _manager(manager, toplevel, args, timeout, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", manager] + args, cwd=toplevel, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout,
    )


def _target_args(repo):
    return ["--root"] if repo.get("branch") is None else [repo["branch"]]


def _server_running(manager, server):
    try:
        out = _manager(manager, server["toplevel"], ["serve", "status"] + server["target"], 30)
        return bool(json.loads(out.stdout.strip().splitlines()[-1]).get("running"))
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return False


def _stop_server(manager, server):
    try:
        _manager(manager, server["toplevel"], ["serve", "stop"] + server["target"], 60)
        return True
    except (OSError, subprocess.TimeoutExpired):
        return False


def _registered_entry(aimi_root, key):
    """The dev-server.json entry for <key>, or None. Read only."""
    try:
        with open(os.path.join(aimi_root, DEV_SERVER_STATE), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    entry = doc.get(key) if isinstance(doc, dict) else None
    return entry if isinstance(entry, dict) else None


def _pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def _port_busy(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: it could leave loopback."""

    def redirect_request(self, *args, **kwargs):
        return None


def _ready_path(ready):
    """Only the path and query of the recipe's readiness URL are ever used."""
    if ready.startswith("/"):
        parts = urlsplit("http://127.0.0.1" + ready)
    else:
        parts = urlsplit(ready)
    path = parts.path or "/"
    return path + ("?" + parts.query if parts.query else "")


def _probe_ready(port, ready, timeout):
    """Poll http://127.0.0.1:<port><path> until any HTTP answer below 500 or timeout."""
    url = "http://127.0.0.1:%d%s" % (port, _ready_path(ready))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)
    deadline = time.monotonic() + timeout
    while True:
        try:
            with opener.open(url, timeout=5) as resp:
                if resp.status < 500:
                    return True
        except urllib.error.HTTPError as exc:
            if exc.code < 500:
                return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


# --------------------------------------------------------------------------
# up: validation, state, detach
# --------------------------------------------------------------------------

def _git_toplevel(directory):
    try:
        out = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, env=dict(os.environ, LC_ALL="C"),
        )
    except OSError:
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else None


def _within(child, parent):
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


def _confined_dir(path, aimi_root):
    """The real path of <path> when it is an existing directory inside
    <aimi_root>, else None. For directories read back from the state file."""
    if not isinstance(path, str) or not path or "\0" in path:
        return None
    real = os.path.realpath(path)
    if not _within(real, os.path.realpath(aimi_root)) or not os.path.isdir(real):
        return None
    return real


def _trusted_server(server, aimi_root):
    """A server entry read back from the state file, confined, or None.

    Its toplevel must be a directory inside <aimi_root> and its target exactly
    ["--root"] or [<branch>] with a valid branch name, because both reach the
    manager's argv and working directory."""
    if not isinstance(server, dict):
        return None
    toplevel = _confined_dir(server.get("toplevel"), aimi_root)
    target = server.get("target")
    if toplevel is None or not isinstance(target, list) or len(target) != 1:
        return None
    if target[0] != "--root" and not (isinstance(target[0], str) and BRANCH_RE.match(target[0])):
        return None
    project = server.get("project")
    return {"project": project if isinstance(project, str) else None, "toplevel": toplevel,
            "target": list(target), "port": server.get("port") if isinstance(server.get("port"), int) else None}


def _refuse_tracked_state(state_path):
    if D.config_is_tracked(state_path):
        raise Refusal(
            "%s is tracked by git, so nothing it names is run or stopped; "
            "untrack it or add .aimi/ to .gitignore first" % state_path
        )


def _parse_repos(aimi_root, specs):
    """Validate every --repo spec; return the repositories, in the order given."""
    if not specs:
        raise Refusal("at least one --repo <project>[=<branch>] is required")
    root_real = os.path.realpath(aimi_root)
    repos, seen_projects, seen_tops = [], set(), {}
    for spec in specs:
        project, has_branch, branch = spec.partition("=")
        key = D.validate_key(project) if project else None
        if key is None:
            raise Refusal("--repo '%s' names no project" % spec)
        if key != "." and os.path.normpath(key) != key:
            raise Refusal("--repo project '%s' is not a normalised relative path" % key)
        if key in seen_projects:
            raise Refusal("--repo project '%s' is given more than once" % key)
        seen_projects.add(key)

        directory = os.path.realpath(os.path.join(root_real, key))
        if not _within(directory, root_real):
            raise Refusal("--repo project '%s' is outside the layout" % key)
        if not os.path.isdir(directory):
            raise Refusal("--repo project '%s' is not a directory under the layout" % key)
        toplevel = _git_toplevel(directory)
        if toplevel is None:
            raise Refusal("--repo project '%s' is in no git repository" % key)
        if not _within(toplevel, root_real):
            raise Refusal("--repo project '%s' belongs to a repository outside the layout" % key)
        if toplevel in seen_tops:
            raise Refusal("--repo project '%s' is in the same repository as '%s'" % (key, seen_tops[toplevel]))
        seen_tops[toplevel] = key

        repo = {
            "project": key, "branch": None, "toplevel": toplevel, "worktree": toplevel,
            "status": "pending", "url": None,
        }
        if has_branch:
            if not BRANCH_RE.match(branch):
                raise Refusal("--repo '%s' has an invalid branch '%s'" % (spec, branch))
            container_dir = os.path.join(toplevel, ".worktrees")
            worktree = os.path.realpath(os.path.join(container_dir, branch))
            if not _within(worktree, os.path.realpath(container_dir)) or worktree == os.path.realpath(container_dir):
                raise Refusal("--repo '%s' resolves outside .worktrees/" % spec)
            if not os.path.isdir(worktree):
                raise Refusal("--repo '%s': container directory %s does not exist" % (spec, worktree))
            repo["branch"] = branch
            repo["worktree"] = worktree
        repos.append(repo)
    return repos


def _fetch_recipe(aimi_root, project):
    """(recipe | None, reason | None) from usage_recipe.get, in process.

    The same reader `usage-recipe-get` answers from, with its tracked-config
    check: a recipe in a config git tracks is never trusted."""
    config = os.path.join(aimi_root, ".aimi", "config.json")
    try:
        answer = U.get(config, project)
    except Refusal as exc:
        return None, "usage recipe could not be read: %s" % exc
    except OSError as exc:
        return None, "usage recipe could not be read (%s)" % exc.__class__.__name__
    status = answer.get("status")
    if status == "recorded" and isinstance(answer.get("recipe"), dict):
        return answer["recipe"], None
    if status == "untrusted":
        return None, "usage recipe is not trusted (the config is tracked by git)"
    return None, "no usage recipe recorded"


def _open_log(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return open(path, "ab")


def _spawn_runner(state_path, log_path, lock_fd, manager):
    log = _open_log(log_path)
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "run", "--state", state_path, "--manager", manager],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, close_fds=True,
            pass_fds=(lock_fd,), start_new_session=True,
        )
    finally:
        log.close()
    return proc.pid


def _parse_flags(args, single, repeated=(), switches=()):
    out = {k: None for k in single}
    for k in repeated:
        out[k] = []
    for k in switches:
        out[k] = False
    i = 0
    while i < len(args):
        flag = args[i]
        if flag in switches:
            out[flag] = True
            i += 1
            continue
        if flag not in single and flag not in repeated or i + 1 >= len(args):
            raise Refusal("unknown or incomplete flag: %s" % flag)
        if flag in repeated:
            out[flag].append(args[i + 1])
        else:
            if out[flag] is not None:
                raise Refusal("%s was given more than once" % flag)
            out[flag] = args[i + 1]
        i += 2
    return out


def _op_up(args):
    lock_fd = None
    try:
        f = _parse_flags(
            args, ("--aimi-root", "--manager", "--run"), ("--repo",), ("--restart",),
        )
        for name in ("--aimi-root", "--manager"):
            if not f[name]:
                raise Refusal("%s is required" % name)
        run = f["--run"]
        if not run or not RUN_RE.match(run):
            raise Refusal("--run must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")
        aimi_root = f["--aimi-root"]
        repos = _parse_repos(aimi_root, f["--repo"])
        state_path, log_path, lock_path = _state_paths(aimi_root, run)
        os.makedirs(os.path.dirname(state_path), exist_ok=True)

        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise Refusal("run %s is still starting; wait for it with usage-env-status or stop it with usage-env-down" % run)

        _refuse_tracked_state(state_path)
        previous = _read_state(state_path)
        # Servers named by the previous file are confined before the manager
        # ever sees them; one that fails is dropped, never run against.
        raw_servers = (previous or {}).get("servers")
        prev_servers = []
        for server in raw_servers if isinstance(raw_servers, list) else []:
            trusted = _trusted_server(server, aimi_root)
            if trusted is not None:
                prev_servers.append(trusted)
        if previous and previous.get("status") == "ready" and not f["--restart"]:
            servers = prev_servers
            if servers and all(_server_running(f["--manager"], s) for s in servers):
                doc = {"run": run, "status": "ready", "stage": previous.get("stage"), "state": state_path, "reused": True}
                _emit(doc)
                return 0

        recipes, reasons = {}, {}
        for repo in repos:
            recipe, reason = _fetch_recipe(aimi_root, repo["project"])
            if recipe is not None:
                recipes[repo["project"]] = recipe
            else:
                reasons[repo["project"]] = reason
        for repo in repos:
            repo["hasRecipe"] = repo["project"] in recipes

        now = _now()
        state = {
            "run": run, "status": "starting", "stage": "queued", "reason": None,
            "startedAt": now, "updatedAt": now, "runnerPid": None,
            "mode": "restart" if f["--restart"] and previous else "fresh",
            "aimiRoot": aimi_root, "log": log_path,
            "repositories": repos, "recipes": recipes, "servers": [],
            "previousServers": prev_servers,
        }
        if not recipes:
            reason = "no usage recipe recorded"
            if reasons and all(r != reason for r in reasons.values()):
                reason = next(iter(reasons.values()))
            state.update(status="unable-to-evaluate", stage="recipe", reason=reason, previousServers=[])
            for repo in repos:
                repo["status"] = "unable-to-evaluate"
            _atomic_write(state_path, state)
            _emit({"run": run, "status": state["status"], "stage": state["stage"], "state": state_path})
            return 0

        _atomic_write(state_path, state)
        pid = _spawn_runner(state_path, log_path, lock_fd, f["--manager"])
        state["runnerPid"] = pid
        _atomic_write(state_path, state)
        _emit({"run": run, "status": "starting", "stage": "queued", "state": state_path})
        return 0
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (UP_VERB, exc))
        return 1
    except OSError as exc:
        sys.stderr.write("Error: %s: %s\n" % (UP_VERB, exc.__class__.__name__ + (": %s" % exc.strerror if exc.strerror else "")))
        return 1
    finally:
        # The runner holds its own duplicate of the lock; closing ours only
        # drops this process's reference.
        if lock_fd is not None:
            os.close(lock_fd)


# --------------------------------------------------------------------------
# run: the detached runner
# --------------------------------------------------------------------------

class _Runner:
    def __init__(self, state_path, manager):
        self.path = state_path
        self.manager = manager
        self.state = _read_state(state_path)
        if self.state is None:
            raise Refusal("cannot read the state file")
        self.log = _open_log(self.state["log"])
        self.step_timeout = _env_seconds("AIMI_USAGE_ENV_STEP_TIMEOUT", DEFAULT_STEP_TIMEOUT)
        self.ready_timeout = _env_seconds("AIMI_USAGE_ENV_READY_TIMEOUT", DEFAULT_READY_TIMEOUT)

    def save(self, **fields):
        self.state.update(fields)
        self.state["updatedAt"] = _now()
        _atomic_write(self.path, self.state)

    def note(self, text):
        self.log.write(("[usage-env] %s\n" % text).encode("utf-8", "replace"))
        self.log.flush()

    def finish(self, status, stage, reason=None, repo=None, repo_status=None):
        if repo is not None and repo_status:
            repo["status"] = repo_status
        self.save(status=status, stage=stage, reason=reason)
        return 0

    def fail(self, stage, reason, repo=None):
        self.note("failed at %s: %s" % (stage, reason))
        return self.finish("failed", stage, reason, repo, "failed")

    # -- stages ----------------------------------------------------------

    def clear_previous(self):
        for server in self.state.get("previousServers") or []:
            trusted = _trusted_server(server, self.state["aimiRoot"])
            if trusted is None:
                self.note("skipping an earlier server whose toplevel or target is not confined")
                continue
            self.note("stopping this run's earlier server for %s" % trusted.get("project"))
            _stop_server(self.manager, trusted)
        self.save(previousServers=[])

    def port_check(self):
        """Refuse before any setup step when a fixed port is busy."""
        for repo in self.state["repositories"]:
            recipe = self.state["recipes"].get(repo["project"]) or {}
            port = recipe.get("port")
            if recipe.get("serve") and isinstance(port, int) and _port_busy(port):
                reason = "port %d is busy on 127.0.0.1 and no server of this run holds it; another port is never picked" % port
                self.note(reason)
                return self.finish("unable-to-evaluate", "port-check", reason, repo, "unable-to-evaluate")
        return None

    def run_steps(self, repo, steps, label):
        """Run steps in order; returns (stage, reason) of the first failure, or None."""
        for n, cmd in enumerate(steps, 1):
            stage = "%s:%s:%d/%d" % (label, repo["project"], n, len(steps))
            self.save(stage=stage)
            argv, problem = _argv_for(cmd, repo["worktree"])
            if argv is None:
                return stage, "%s step %d: %s: %s" % (label, n, problem, cmd)
            self.note("%s: %s" % (stage, cmd))
            how, rc = _run_argv(argv, repo["worktree"], self.log, self.step_timeout)
            if how == "timeout":
                return stage, "%s step %d timed out after %ds: %s" % (label, n, self.step_timeout, cmd)
            if how == "exit":
                return stage, "%s step %d exited %d: %s" % (label, n, rc, cmd)
        return None

    def serve(self, repo, recipe):
        manager, toplevel = self.manager, repo["toplevel"]
        serve = recipe["serve"]
        stage = "serve:%s" % repo["project"]
        self.save(stage=stage)
        argv, problem = _argv_for(serve, repo["worktree"])
        if argv is None:
            return self.fail(stage, "serve command %s: %s" % (problem, serve), repo)

        # Whatever sits on this key without a recorded recipe command (the
        # default `run dev` server) would be adopted by serve start's reuse
        # path; it is stopped first. One with a command is left for serve start
        # to compare.
        entry = _registered_entry(self.state["aimiRoot"], os.path.realpath(repo["worktree"]))
        if entry and not entry.get("command") and _pid_alive(entry.get("pid")):
            self.note("stopping the default dev server registered for %s" % repo["project"])
            _stop_server(manager, {"toplevel": toplevel, "target": _target_args(repo)})

        cmd = ["serve", "start"] + _target_args(repo) + ["--command", serve]
        if isinstance(recipe.get("port"), int):
            cmd += ["--port", str(recipe["port"])]
        self.note("%s: %s" % (stage, " ".join(cmd)))
        try:
            out = _manager(
                manager, toplevel, cmd, self.ready_timeout + 60,
                {"DEV_SERVER_READY_TIMEOUT": str(self.ready_timeout)},
            )
        except subprocess.TimeoutExpired:
            return self.fail(stage, "serve start did not return: %s" % serve, repo)
        if out.stderr:
            self.log.write(out.stderr.encode("utf-8", "replace"))
            self.log.flush()
        url = None
        for line in reversed((out.stdout or "").splitlines()):
            if re.match(r"^http://127\.0\.0\.1:\d+$", line.strip()):
                url = line.strip()
                break
        if url is None:
            why = "serve command did not start (exit %d): %s" % (out.returncode, serve)
            return self.fail(stage, why, repo)
        port = int(url.rsplit(":", 1)[1])
        self.state["servers"].append({
            "project": repo["project"], "toplevel": toplevel, "target": _target_args(repo),
            "key": os.path.realpath(repo["worktree"]), "port": port,
        })
        self.save()
        if not _probe_ready(port, recipe["ready"], self.ready_timeout):
            return self.fail(stage, "readiness timed out after %ds: http://127.0.0.1:%d%s" % (
                self.ready_timeout, port, _ready_path(recipe["ready"])), repo)
        repo["url"] = url
        self.save()
        return None

    def go(self):
        restart = self.state.get("mode") == "restart"
        self.clear_previous()
        refused = self.port_check()
        if refused is not None:
            return refused
        for repo in self.state["repositories"]:
            recipe = self.state["recipes"].get(repo["project"])
            repo["status"] = "starting"
            self.save()
            if recipe is None:
                repo["status"] = "ready"
                self.save()
                continue
            if not restart:
                problem = self.run_steps(repo, recipe.get("setup") or [], "setup")
                if problem:
                    return self.fail(problem[0], problem[1], repo)
            if recipe.get("serve"):
                if self.serve(repo, recipe) is not None or repo["status"] == "failed":
                    return 0
            repo["status"] = "ready"
            self.save()
        return self.finish("ready", "ready")


def _op_run(args):
    try:
        f = _parse_flags(args, ("--state", "--manager"))
        if not f["--state"] or not f["--manager"]:
            raise Refusal("--state and --manager are required")
        runner = _Runner(f["--state"], f["--manager"])
    except (Refusal, OSError) as exc:
        sys.stderr.write("Error: usage-env run: %s\n" % exc)
        return 1

    def on_term(signum, _frame):
        if _Child.pgid:
            _kill_group(_Child.pgid)
        os._exit(143)

    signal.signal(signal.SIGTERM, on_term)
    try:
        return runner.go()
    except BaseException as exc:  # a runner that dies silently leaves `starting` forever
        try:
            runner.fail(runner.state.get("stage") or "run", "internal error: %s" % exc.__class__.__name__)
        except BaseException:
            pass
        return 1


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

def _op_status(args):
    try:
        f = _parse_flags(args, ("--aimi-root", "--run", "--wait"))
        if not f["--aimi-root"]:
            raise Refusal("--aimi-root is required")
        run = f["--run"]
        if not run or not RUN_RE.match(run):
            raise Refusal("--run is required and must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")
        wait = 0
        if f["--wait"] is not None:
            raw = f["--wait"]
            if not (raw.isascii() and raw.isdigit()) or not 0 <= int(raw) <= MAX_WAIT:
                raise Refusal("--wait must be an integer from 0 to %d" % MAX_WAIT)
            wait = int(raw)
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (STATUS_VERB, exc))
        return 1

    state_path, log_path, lock_path = _state_paths(f["--aimi-root"], run)
    deadline = time.monotonic() + wait
    while True:
        state = _read_state(state_path)
        if state is None:
            _emit({"run": run, "status": "absent", "stage": None, "reason": None, "repositories": [], "log": None})
            return 0
        status, reason = state.get("status"), state.get("reason")
        if status == "starting" and not _runner_alive(lock_path):
            # The runner may have finished between the read and the probe.
            again = _read_state(state_path) or state
            if again.get("status") == "starting":
                status, reason, state = "failed", "bring-up process exited", again
            else:
                state, status, reason = again, again.get("status"), again.get("reason")
        if status != "starting" or time.monotonic() >= deadline:
            break
        time.sleep(0.25)
    _emit({
        "run": run, "status": status, "stage": state.get("stage"), "reason": reason,
        "repositories": _public_repos(state), "log": state.get("log"),
    })
    return 0


# --------------------------------------------------------------------------
# down
# --------------------------------------------------------------------------

def _is_our_runner(pid, state_path):
    """True when <pid> is this run's runner: its command line is the one
    _spawn_runner gave it. The pid comes from the state file, so liveness
    alone is never enough to signal it."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        out = subprocess.run(
            ["ps", "-ww", "-o", "args=", "-p", str(pid)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    args = out.stdout.strip()
    return " run --state %s " % state_path in args + " " and os.path.basename(__file__) in args


def _stop_runner(state, state_path, lock_path):
    pid = state.get("runnerPid")
    if not _runner_alive(lock_path):
        return
    if not _is_our_runner(pid, state_path):
        return
    if isinstance(pid, int) and pid > 0:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + STOP_GRACE
    while _runner_alive(lock_path) and time.monotonic() < deadline:
        time.sleep(0.1)
    if _runner_alive(lock_path) and isinstance(pid, int) and pid > 0:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass


def _op_down(args):
    try:
        f = _parse_flags(args, ("--aimi-root", "--manager", "--run"))
        for name in ("--aimi-root", "--manager"):
            if not f[name]:
                raise Refusal("%s is required" % name)
        run = f["--run"]
        if not run or not RUN_RE.match(run):
            raise Refusal("--run is required and must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")
        aimi_root = f["--aimi-root"]
        state_path, log_path, lock_path = _state_paths(aimi_root, run)
        _refuse_tracked_state(state_path)
    except Refusal as exc:
        sys.stderr.write("Error: %s: %s\n" % (DOWN_VERB, exc))
        return 1

    state = _read_state(state_path)
    if state is None:
        _emit({"run": run, "status": "absent"})
        return 0
    if state.get("status") == "down":
        _emit({"run": run, "status": "down", "cleanupFailed": 0, "stopped": 0, "alreadyDown": True})
        return 0

    _stop_runner(state, state_path, lock_path)
    timeout = _env_seconds("AIMI_USAGE_ENV_STEP_TIMEOUT", DEFAULT_STEP_TIMEOUT)
    cleanup_failed = 0
    log = _open_log(log_path)

    def note(text):
        log.write(("[usage-env] %s\n" % text).encode("utf-8", "replace"))
        log.flush()

    repositories = state.get("repositories") if isinstance(state.get("repositories"), list) else []
    try:
        for repo in repositories:
            if not isinstance(repo, dict):
                continue
            project = repo.get("project")
            try:
                project = D.validate_key(project)
            except Refusal:
                note("cleanup skipped: a repository entry names no valid project")
                continue
            # The cleanup steps come from the trusted recipe, never from the
            # copy the state file holds.
            recipe, reason = _fetch_recipe(aimi_root, project)
            steps = (recipe or {}).get("cleanup") or []
            if recipe is None:
                note("cleanup %s skipped: %s" % (project, reason))
            worktree = _confined_dir(repo.get("worktree"), aimi_root)
            for n, cmd in enumerate(steps, 1):
                argv, problem = _argv_for(cmd, worktree or "/")
                if argv is None or worktree is None:
                    cleanup_failed += 1
                    note("cleanup %s step %d refused: %s" % (project, n, problem or "worktree is not a directory inside the layout"))
                    continue
                note("cleanup %s step %d: %s" % (project, n, cmd))
                try:
                    how, _rc = _run_argv(argv, worktree, log, timeout)
                except OSError:
                    how = "exit"
                if how != "ok":
                    cleanup_failed += 1
        stopped = 0
        servers = state.get("servers") if isinstance(state.get("servers"), list) else []
        for server in servers:
            trusted = _trusted_server(server, aimi_root)
            if trusted is None:
                note("server entry skipped: its toplevel or target is not confined")
                continue
            if _stop_server(f["--manager"], trusted):
                stopped += 1
    finally:
        log.close()
    state.update(status="down", stage="down", reason=None, runnerPid=None, servers=[], updatedAt=_now())
    state.pop("manager", None)
    for repo in repositories:
        if isinstance(repo, dict):
            repo["status"] = "down"
            repo["url"] = None
    _atomic_write(state_path, state)
    _emit({"run": run, "status": "down", "cleanupFailed": cleanup_failed, "stopped": stopped})
    return 0


_OPS = {"up": _op_up, "run": _op_run, "status": _op_status, "down": _op_down}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: usage_env.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
