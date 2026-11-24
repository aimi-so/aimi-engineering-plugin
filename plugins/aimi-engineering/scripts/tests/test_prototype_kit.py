"""Tests for scripts/prototype_kit.py, driven through inspect-prototype-kit and
import-prototype-kit against throwaway AIMI roots."""

import json
import os
import subprocess
import sys
import tempfile
import zipfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
MODULE = os.path.join(SCRIPTS, "prototype_kit.py")


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = os.path.realpath(tmp)
        os.makedirs(os.path.join(tmp, ".aimi"))
        yield tmp


def cli(root, verb, *args):
    env = dict(os.environ)
    env.pop("AIMI_DEV_DIR", None)
    return subprocess.run(
        ["bash", CLI, verb, *args], cwd=root, capture_output=True, text=True, env=env
    )


def make_folder(root, name="kit", files=None):
    d = os.path.join(root, name)
    for rel, data in (files or {"screen.html": "<html></html>", "notes.md": "# n"}).items():
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as fh:
            fh.write(data.encode() if isinstance(data, str) else data)
    return d


def make_zip(root, name="kit.zip", files=None, write=None):
    p = os.path.join(root, name)
    with zipfile.ZipFile(p, "w") as zf:
        for rel, data in (files or {"screen.html": "<html></html>"}).items():
            zf.writestr(rel, data)
        if write:
            write(zf)
    return p


def sources(root):
    d = os.path.join(root, ".aimi", "sources")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def inspect(root, path):
    r = cli(root, "inspect-prototype-kit", path)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_inspect_folder(root):
    make_folder(root, files={"screen.html": "<html>", "a.md": "x", "img/p.png": "z"})
    out = inspect(root, "kit")
    assert out["kind"] == "folder" and out["qualifies"] is True
    assert out["htmlFiles"] == ["screen.html"]
    assert out["markdownFiles"] == ["a.md"]
    assert out["otherFiles"] == ["img/p.png"]
    assert out["refused"] == []
    assert sources(root) == []


def test_inspect_zip_flattens_single_folder(root):
    make_zip(root, files={"top/screen.html": "<html>", "top/x/y.md": "m", "__MACOSX/top/._s": "j", "top/.DS_Store": "d"})
    out = inspect(root, "kit.zip")
    assert out["kind"] == "zip"
    assert out["htmlFiles"] == ["screen.html"]
    assert out["markdownFiles"] == ["x/y.md"]
    assert out["otherFiles"] == []


def test_inspect_no_html_does_not_qualify(root):
    make_folder(root, files={"a.md": "x"})
    assert inspect(root, "kit")["qualifies"] is False


def test_import_folder_and_idempotent_reimport(root):
    make_folder(root)
    r = cli(root, "import-prototype-kit", "kit", "--slug", "My Kit")
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["reused"] is False
    assert out["dir"].startswith(".aimi/sources/my-kit-") and len(out["dir"].split("-")[-1]) == 8
    assert out["htmlFiles"] == [out["dir"] + "/screen.html"]
    assert os.path.isfile(os.path.join(root, out["dir"], "screen.html"))
    r2 = cli(root, "import-prototype-kit", "kit", "--slug", "My Kit")
    out2 = json.loads(r2.stdout)
    assert out2["reused"] is True and out2["dir"] == out["dir"]
    assert len(sources(root)) == 1
    with open(os.path.join(root, "kit", "screen.html")) as fh:
        assert fh.read() == "<html></html>"


def test_import_changed_content_gets_new_dir(root):
    make_folder(root)
    a = json.loads(cli(root, "import-prototype-kit", "kit").stdout)
    make_folder(root, files={"screen.html": "<html>changed"})
    b = json.loads(cli(root, "import-prototype-kit", "kit").stdout)
    assert a["dir"] != b["dir"] and b["dir"].startswith(".aimi/sources/kit-")


def test_import_zip_slug_from_basename(root):
    make_zip(root, name="Cool Kit.zip", files={"d/screen.html": "<html>"})
    out = json.loads(cli(root, "import-prototype-kit", "Cool Kit.zip").stdout)
    assert out["dir"].startswith(".aimi/sources/cool-kit-")
    assert out["htmlFiles"][0].endswith("/screen.html")


def refuse_import(root, path, *needles):
    r = cli(root, "import-prototype-kit", path)
    assert r.returncode == 1 and r.stdout == ""
    for n in needles:
        assert n in r.stderr, r.stderr
    assert sources(root) == []
    return r


def test_refuse_symlink_in_folder(root):
    d = make_folder(root)
    os.symlink("/etc/hostname", os.path.join(d, "link.html"))
    refuse_import(root, "kit", "link.html", "symlink")
    out = inspect(root, "kit")
    assert out["qualifies"] is False and out["refused"][0]["member"] == "link.html"


def test_refuse_symlink_in_zip(root):
    def w(zf):
        i = zipfile.ZipInfo("link.html")
        i.external_attr = 0o120777 << 16
        zf.writestr(i, "/etc/hostname")

    make_zip(root, write=w)
    refuse_import(root, "kit.zip", "link.html", "symlink")


@pytest.mark.parametrize("name", ["../evil.html", "/abs.html", "a/../b.html"])
def test_refuse_unsafe_names(root, name):
    make_zip(root, files={"screen.html": "x", name: "y"})
    refuse_import(root, "kit.zip", name)


@pytest.mark.parametrize(
    "name",
    [".git/config", ".claude/x.html", "sub/.git/HEAD", "CLAUDE.md", "sub/agents.MD", "Settings.JSON"],
)
def test_refuse_forbidden_members(root, name):
    make_zip(root, files={"screen.html": "x", name: "y"})
    refuse_import(root, "kit.zip", name)


def test_refuse_names_every_offender(root):
    make_zip(root, files={"screen.html": "x", "CLAUDE.md": "a", ".git/config": "b"})
    refuse_import(root, "kit.zip", "CLAUDE.md", ".git/config")


def test_refuse_not_a_kit_path(root):
    with open(os.path.join(root, "f.txt"), "w") as fh:
        fh.write("x")
    for verb in ("inspect-prototype-kit", "import-prototype-kit"):
        r = cli(root, verb, "f.txt")
        assert r.returncode == 1 and r.stdout == "" and r.stderr


def test_refuse_corrupt_zip(root):
    with open(os.path.join(root, "bad.zip"), "wb") as fh:
        fh.write(b"not a zip at all")
    for verb in ("inspect-prototype-kit", "import-prototype-kit"):
        r = cli(root, verb, "bad.zip")
        assert r.returncode == 1 and r.stdout == "" and "corrupt" in r.stderr
    assert sources(root) == []


def test_refuse_bad_crc(root):
    p = make_zip(root, files={"screen.html": "<html>" + "a" * 200})
    data = bytearray(open(p, "rb").read())
    i = data.index(b"aaaa")
    data[i] ^= 0xFF
    open(p, "wb").write(bytes(data))
    for verb in ("inspect-prototype-kit", "import-prototype-kit"):
        r = cli(root, verb, "kit.zip")
        assert r.returncode == 1 and r.stdout == "", r.stderr
    assert sources(root) == []


def test_refuse_encrypted_member(root):
    p = make_zip(root, files={"screen.html": "x"})
    data = bytearray(open(p, "rb").read())
    # set the encryption bit in the local header and the central directory entry
    data[6] |= 1
    cd = data.index(b"PK\x01\x02")
    data[cd + 8] |= 1
    open(p, "wb").write(bytes(data))
    for verb in ("inspect-prototype-kit", "import-prototype-kit"):
        r = cli(root, verb, "kit.zip")
        assert r.returncode == 1 and r.stdout == "" and "encrypted" in r.stderr


def test_refuse_non_ascii_name_without_utf8_flag(root):
    p = make_zip(root, files={"screen.html": "x", "aXb.html": "y"})
    data = bytearray(open(p, "rb").read())
    for sig, off in ((b"PK\x03\x04", 30), (b"PK\x01\x02", 46)):
        j = 0
        while (k := data.find(sig + b"", j)) != -1:
            n = int.from_bytes(data[k + (26 if sig == b"PK\x03\x04" else 28):][:2], "little")
            name = bytes(data[k + off:k + off + n])
            if name == b"aXb.html":
                data[k + off + 1] = 0xE9
            j = k + 4
    open(p, "wb").write(bytes(data))
    for verb in ("inspect-prototype-kit", "import-prototype-kit"):
        r = cli(root, verb, "kit.zip")
        assert r.returncode == 1 and r.stdout == "" and "non-ASCII" in r.stderr


def run_module(root, mode, path, **caps):
    code = (
        "import sys, prototype_kit as P\n"
        + "".join("P.%s = %r\n" % kv for kv in caps.items())
        + "sys.exit(P.main(['p', %r, %r, '--aimi-dir', %r]))" % (mode, path, os.path.join(root, ".aimi"))
    )
    return subprocess.run(
        [sys.executable, "-c", code], cwd=SCRIPTS, capture_output=True, text=True
    )


@pytest.mark.parametrize("mode", ["inspect", "import"])
def test_refuse_entry_cap(root, mode):
    make_zip(root, files={"screen.html": "x", "b.md": "y", "c.md": "z"})
    r = run_module(root, mode, os.path.join(root, "kit.zip"), MAX_ENTRIES=2)
    assert r.returncode == 1 and r.stdout == "" and "entries" in r.stderr
    assert sources(root) == []


@pytest.mark.parametrize("mode", ["inspect", "import"])
def test_refuse_size_cap_counts_real_bytes(root, mode):
    make_zip(root, files={"screen.html": "a" * 100})
    r = run_module(root, mode, os.path.join(root, "kit.zip"), MAX_TOTAL_BYTES=50)
    assert r.returncode == 1 and r.stdout == "" and "bytes" in r.stderr
    make_folder(root, files={"screen.html": "a" * 100})
    r = run_module(root, mode, os.path.join(root, "kit"), MAX_TOTAL_BYTES=50)
    assert r.returncode == 1 and r.stdout == ""
    assert sources(root) == []


def test_path_outside_project_is_refused_by_the_cli(root):
    with tempfile.TemporaryDirectory() as other:
        make_folder(other)
        r = cli(root, "inspect-prototype-kit", os.path.join(other, "kit"))
        assert r.returncode != 0 and r.stdout == ""
        assert sources(root) == []
