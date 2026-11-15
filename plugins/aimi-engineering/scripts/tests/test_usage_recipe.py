"""Tests for scripts/usage_recipe.py, the module behind `usage-recipe-record` and `usage-recipe-get`.

Document rules are driven through `main`; the CLI wiring, the lock race and the
python3-less refusal go through aimi-cli.sh as a subprocess. Every fixture is a
tempfile root outside the repository.
"""

import json
import os
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import usage_recipe as U  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
BASE = ["--serve", "npm run dev", "--ready", "/"]


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, ".aimi"))
        yield tmp


def cfg(root):
    return os.path.join(root, ".aimi", "config.json")


def rec(root, *flags, project="."):
    return U.main(["usage_recipe.py", "record", "--config", cfg(root), "--project", project, *flags])


def get(root, project="."):
    return U.main(["usage_recipe.py", "get", "--config", cfg(root), "--project", project])


def load(root):
    with open(cfg(root)) as fh:
        return json.load(fh)


def raw(root):
    with open(cfg(root), "rb") as fh:
        return fh.read()


def test_record_and_get_full_recipe(root, capsys):
    flags = ["--setup", "make deps", "--setup", "make db", "--serve", "npm run dev", "--port", "3000",
             "--ready", "http://localhost:3000/health", "--login", "manual", "--login-url", "/login",
             "--browser", "chrome", "--cleanup", "make down", "--cleanup", "make clean",
             "--external-services", "stripe is stubbed"]
    assert rec(root, *flags) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "recorded"
    assert get(root) == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"status": "recorded", "project": ".", "recipe": {
        "setup": ["make deps", "make db"], "serve": "npm run dev", "port": 3000,
        "ready": "http://localhost:3000/health", "login": {"method": "manual", "url": "/login"},
        "browser": "chrome", "cleanup": ["make down", "make clean"],
        "externalServices": "stripe is stubbed"}}


def test_only_supplied_fields_and_no_defaults(root, capsys):
    assert rec(root, *BASE) == 0
    capsys.readouterr()
    assert load(root)["usage"]["recipe"]["."] == {"serve": "npm run dev", "ready": "/"}


def test_cli_only_recipe(root):
    assert rec(root, "--cli", "mytool run") == 0
    assert load(root)["usage"]["recipe"]["."] == {"cli": "mytool run"}


def test_absent_key_exit_zero(root, capsys):
    assert get(root) == 0
    assert json.loads(capsys.readouterr().out) == {"status": "absent", "recipe": None}
    rec(root, *BASE)
    capsys.readouterr()
    assert get(root, "other") == 0
    assert json.loads(capsys.readouterr().out) == {"status": "absent", "recipe": None}


@pytest.mark.parametrize("cmd", ["a;b", "a|b", "a&b", "a$b", "a<b", "a>b", "a`b`", "a\nb", "x" * 513, "  "])
@pytest.mark.parametrize("flag", ["--serve", "--cli", "--setup", "--cleanup"])
def test_unsafe_commands_refused_config_absent(root, flag, cmd, capsys):
    flags = [flag, cmd] + ([] if flag == "--serve" else ["--cli", "ok"])
    if flag == "--serve":
        flags += ["--ready", "/"]
    assert rec(root, *flags) == 1
    err = capsys.readouterr().err
    assert "Error: usage-recipe-record:" in err and flag in err
    assert not os.path.exists(cfg(root))


def test_step_refusal_names_the_step(root, capsys):
    assert rec(root, *BASE, "--setup", "ok", "--setup", "a;b") == 1
    assert "--setup step 2" in capsys.readouterr().err


def test_step_limits(root):
    ok = [x for i in range(20) for x in ("--setup", "s%d" % i)]
    assert rec(root, *BASE, *ok) == 0
    assert rec(root, *BASE, *ok, "--setup", "one more") == 1
    over = [x for i in range(21) for x in ("--cleanup", "c%d" % i)]
    assert rec(root, *BASE, *over, project="p2") == 1


@pytest.mark.parametrize("port", ["1023", "65536", "abc", "-1", "80.5", ""])
def test_bad_port(root, port):
    assert rec(root, *BASE, "--port", port) == 1
    assert not os.path.exists(cfg(root))


@pytest.mark.parametrize("port", ["1024", "65535"])
def test_port_bounds_accepted(root, port):
    assert rec(root, *BASE, "--port", port) == 0


@pytest.mark.parametrize("url", [
    "http://evil.com/", "https://example.org", "http://user:pw@localhost/", "http://localhost@evil.com/",
    "ftp://localhost/", "//evil.com/x", "relative", "http://localhost:abc/", "/a b", "/a\\b", "http://0.0.0.0/",
    "http://127.0.0.2:3000/", "http://u@localhost:3000/", "ws://localhost:3000/", "http://localhost.:3000/",
])
@pytest.mark.parametrize("flag", ["--ready", "--login-url"])
def test_non_loopback_refused(root, flag, url, capsys):
    flags = ["--serve", "x", "--ready", "/"] if flag == "--login-url" else ["--serve", "x"]
    flags += ["--login", "manual"] if flag == "--login-url" else []
    flags += [flag, url] if flag == "--login-url" else ["--ready", url]
    if flag == "--ready":
        flags = ["--serve", "x", "--ready", url]
    assert rec(root, *flags) == 1
    assert not os.path.exists(cfg(root))


@pytest.mark.parametrize("url", ["/", "/health", "http://localhost:3000/", "https://127.0.0.1/x", "http://[::1]:8080/ok"])
def test_loopback_accepted(root, url):
    assert rec(root, "--serve", "x", "--ready", url) == 0


def test_host_named_in_refusal(root, capsys):
    rec(root, "--serve", "x", "--ready", "http://evil.com/")
    assert "evil.com" in capsys.readouterr().err


def test_login_browser_external_rules(root):
    assert rec(root, *BASE, "--login", "none") == 0
    assert rec(root, *BASE, "--login", "oauth") == 1
    assert rec(root, *BASE, "--login", "manual") == 1
    assert rec(root, *BASE, "--login", "none", "--login-url", "/l") == 1
    assert rec(root, *BASE, "--login-url", "/l") == 1
    assert rec(root, *BASE, "--browser", "firefox") == 1
    assert rec(root, *BASE, "--browser", "agent-browser") == 0
    assert rec(root, *BASE, "--external-services", "x" * 501) == 1
    assert rec(root, *BASE, "--external-services", "a\x01b") == 1
    assert rec(root, *BASE, "--external-services", "x" * 500) == 0


def test_cross_field_rules(root):
    assert rec(root) == 1
    assert rec(root, "--ready", "/") == 1
    assert rec(root, "--serve", "x") == 1
    for extra in (["--port", "3000"], ["--ready", "/"], ["--login", "none"], ["--browser", "chrome"]):
        assert rec(root, "--cli", "tool", *extra) == 1
    assert not os.path.exists(cfg(root))


def test_duplicate_single_flag_refused(root, capsys):
    assert rec(root, *BASE, "--serve", "other") == 1
    assert "more than once" in capsys.readouterr().err
    assert rec(root, *BASE, "--port", "3000", "--port", "3001") == 1


def test_replace_whole_and_unchanged(root, capsys):
    rec(root, *BASE, "--browser", "chrome")
    capsys.readouterr()
    before = os.stat(cfg(root)).st_mtime_ns
    rec(root, *BASE, "--browser", "chrome")
    assert json.loads(capsys.readouterr().out)["status"] == "unchanged"
    assert os.stat(cfg(root)).st_mtime_ns == before
    rec(root, "--cli", "tool")
    assert load(root)["usage"]["recipe"]["."] == {"cli": "tool"}


def test_other_keys_order_and_deps_survive(root):
    with open(cfg(root), "w") as fh:
        json.dump({"z": 1, "dependencies": {"install": {".": "make"}}, "a": 3}, fh)
    assert rec(root, *BASE) == 0
    doc = load(root)
    assert list(doc) == ["z", "dependencies", "a", "usage"]
    assert doc["dependencies"] == {"install": {".": "make"}}


@pytest.mark.parametrize("text", ["not json", "[1]", '{"usage": 3}', '{"usage": {"recipe": []}}'])
def test_bad_config_refused_byte_identical(root, text):
    with open(cfg(root), "w") as fh:
        fh.write(text)
    assert rec(root, *BASE) == 1
    assert raw(root) == text.encode()


def test_tracked_config(root, capsys):
    subprocess.run(["git", "init", "-q", root], check=True)
    with open(cfg(root), "w") as fh:
        fh.write('{"usage": {"recipe": {".": {"serve": "x", "ready": "/"}}}}\n')
    subprocess.run(["git", "-C", root, "add", "-f", ".aimi/config.json"], check=True)
    before = raw(root)
    assert rec(root, *BASE) == 1
    assert "tracked by git" in capsys.readouterr().err
    assert raw(root) == before
    assert get(root) == 0
    assert json.loads(capsys.readouterr().out) == {"status": "untrusted", "recipe": None}


@pytest.mark.parametrize("entry", [
    {"serve": "a;b", "ready": "/"},
    {"serve": "x"},
    {"serve": "x", "ready": "http://evil.com/"},
    {"serve": "x", "ready": "/", "port": 80},
    {"serve": "x", "ready": "/", "bogus": 1},
    {"cli": "x", "browser": "chrome"},
    "string",
])
def test_get_refuses_hand_edited_entry(root, entry, capsys):
    with open(cfg(root), "w") as fh:
        json.dump({"usage": {"recipe": {".": entry}}}, fh)
    assert get(root) == 1
    cap = capsys.readouterr()
    assert cap.out == "" and "Error: usage-recipe-get:" in cap.err


def test_usage_exit_two():
    assert U.main(["usage_recipe.py"]) == 2


def run(root, *args, **kw):
    return subprocess.run([CLI, *args], cwd=root, capture_output=True, text=True, **kw)


def test_cli_roundtrip_from_subdirectory(root):
    sub = os.path.join(root, "sub")
    os.makedirs(sub)
    r = subprocess.run([CLI, "usage-recipe-record", "--project", ".", *BASE], cwd=sub, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    g = subprocess.run([CLI, "usage-recipe-get", "--project", "."], cwd=sub, capture_output=True, text=True)
    assert json.loads(g.stdout)["recipe"] == {"serve": "npm run dev", "ready": "/"}


def test_cli_unknown_flag_and_help(root):
    assert run(root, "usage-recipe-get", "--project", ".", "--serve", "x").returncode == 1
    assert run(root, "usage-recipe-record", "--bogus", "x").returncode == 1
    h = run(root, "help").stdout
    assert "usage-recipe-record" in h and "usage-recipe-get" in h


def test_lock_race_with_each_other_and_deps(root):
    procs = [subprocess.Popen([CLI, "usage-recipe-record", "--project", "k%d" % i, *BASE], cwd=root,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(6)]
    procs += [subprocess.Popen([CLI, "deps-recipe-record", "--project", "d%d" % i, "--command", "make"], cwd=root,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) for i in range(6)]
    assert [p.wait() for p in procs] == [0] * 12
    doc = load(root)
    assert sorted(doc["usage"]["recipe"]) == ["k%d" % i for i in range(6)]
    assert sorted(doc["dependencies"]["install"]) == ["d%d" % i for i in range(6)]
    assert [n for n in os.listdir(os.path.join(root, ".aimi")) if n.endswith(".tmp")] == []


def test_refuses_without_python3(root):
    bindir = tempfile.mkdtemp()
    for tool in ("bash", "dirname", "cat", "env", "sed", "mkdir", "pwd", "readlink", "ls", "jq", "grep", "awk", "tr", "sort", "head", "tail", "date", "mktemp", "git", "cut", "wc", "basename", "rm", "uname", "id", "tee", "xargs", "find", "stat"):
        for d in ("/usr/bin", "/bin"):
            p = os.path.join(d, tool)
            if os.path.exists(p):
                os.symlink(p, os.path.join(bindir, tool))
                break
    env = dict(os.environ, PATH=bindir)
    for verb in ("usage-recipe-record", "usage-recipe-get"):
        r = subprocess.run(["/bin/bash", CLI, verb, "--project", ".", *(BASE if verb.endswith("record") else [])],
                           cwd=root, capture_output=True, text=True, env=env)
        assert r.returncode == 1
        assert "python3" in r.stderr
    assert not os.path.exists(cfg(root))


@pytest.mark.parametrize("url,schemes,ok", [
    ("http://localhost", None, True),
    ("https://127.0.0.1:8443/x?y#z", None, True),
    ("http://[::1]:3000", None, True),
    ("http://127.0.0.2:3000", None, False),
    ("http://u@localhost:3000", None, False),
    ("http://localhost:99999", None, False),
    ("http://local host", None, False),
    ("ws://localhost:3000", None, False),
    ("ws://localhost:3000", ("ws",), True),
    ("wss://[::1]", U.WEB_SCHEMES + U.SOCKET_SCHEMES, True),
    ("ws://127.0.0.2", U.WEB_SCHEMES + U.SOCKET_SCHEMES, False),
    ("/relative", None, False),
    (None, None, False),
])
def test_is_loopback_origin_is_the_one_rule(url, schemes, ok):
    args = (url,) if schemes is None else (url, schemes)
    assert U.is_loopback_origin(*args) is ok
