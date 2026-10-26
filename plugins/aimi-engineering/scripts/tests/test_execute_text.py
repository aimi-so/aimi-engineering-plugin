"""The document-order reader for /aimi:execute's text (execute_text.py)."""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import execute_text as E  # noqa: E402

MODULE = os.path.join(HERE, "execute_text.py")

ROUTER = """# Execute

intro line

```
Read references/execute/a.md in full
```

## Step A
Read `${CLAUDE_PLUGIN_ROOT}/commands/references/execute/a.md` in full.
after a

## Step B
Read `${CLAUDE_PLUGIN_ROOT}/commands/references/execute/b.md` in full.
Read `${CLAUDE_PLUGIN_ROOT}/commands/references/execute/a.md` in full.
tail
"""


def _corpus(extra=None):
    corpus = {
        "execute.md": ROUTER,
        "references/execute/a.md": "A1\nA2\n",
        "references/execute/b.md": "B1\n",
    }
    corpus.update(extra or {})
    return corpus


def test_files_interleave_at_the_first_read_line():
    lines = E.execute_text(_corpus()).split("\n")
    a = lines.index("A1")
    b = lines.index("B1")
    assert lines[a - 1].startswith("Read `") and "a.md" in lines[a - 1]
    assert lines.index("after a") == a + 2
    assert lines[b - 1].endswith("b.md` in full.")
    assert lines.index("tail") > b


def test_read_line_inside_a_fence_is_ignored():
    text = E.execute_text(_corpus())
    # a.md is inserted once, after Step A's real Read line, not after the fenced one
    assert text.count("A1") == 1
    assert text.index("A1") > text.index("## Step A")


def test_second_read_of_one_file_does_not_duplicate_it():
    text = E.execute_text(_corpus())
    assert text.count("A1") == 1 and text.count("B1") == 1


def test_unreferenced_file_is_appended_last_in_sorted_order():
    corpus = _corpus({"references/execute/z.md": "Z1\n", "references/execute/c.md": "C1\n"})
    text = E.execute_text(corpus)
    assert text.index("tail") < text.index("C1") < text.index("Z1")
    assert text.endswith("Z1")


def test_markers_option():
    plain = E.execute_text(_corpus())
    marked = E.execute_text(_corpus(), markers=True)
    assert E.FILE_MARKER % "execute.md" in marked
    assert E.FILE_MARKER % "references/execute/a.md" in marked
    assert E.FILE_MARKER % "references/execute/b.md" in marked
    assert "<!-- execute-file" not in plain
    stripped = "\n".join(l for l in marked.split("\n") if not l.startswith("<!-- execute-file"))
    assert stripped == plain


def test_router_alone_is_its_own_bytes():
    assert E.execute_text({"execute.md": ROUTER}) == ROUTER


def test_real_execute_md_nested_fence_and_headings():
    text = E.load_execute_corpus()["execute.md"]
    titles = [t for _, _, t in E.headings(text)]
    assert "Post-Loop Cleanup" in titles
    assert not any(t.startswith("Reuse the existing headed session") for t in titles)
    slices = E.heading_slices(text, r"^Post-Loop Cleanup$")
    assert len(slices) == 1 and slices[0].startswith("### Post-Loop Cleanup")


def test_indented_nested_bash_fence_does_not_close_the_outer_fence():
    text = "```\n  ```bash\n  # not a heading\n  ```\n# still inside\n```\n# Real\n"
    assert [t for _, _, t in E.headings(text)] == ["Real"]
    assert len(E.fenced_blocks(text)) == 1


def test_environment_override(tmp_path, monkeypatch):
    (tmp_path / "execute.md").write_text("only me\n", encoding="utf-8")
    monkeypatch.setenv(E.ROOT_ENV, str(tmp_path))
    assert list(E.load_execute_corpus()) == ["execute.md"]
    assert E.execute_text() == "only me\n"


def test_command_line_output_equals_execute_text(tmp_path):
    (tmp_path / "references" / "execute").mkdir(parents=True)
    (tmp_path / "execute.md").write_text(ROUTER, encoding="utf-8")
    (tmp_path / "references" / "execute" / "a.md").write_text("A1\nA2\n", encoding="utf-8")
    (tmp_path / "references" / "execute" / "b.md").write_text("B1\n", encoding="utf-8")
    env = dict(os.environ, **{E.ROOT_ENV: str(tmp_path)})
    out = subprocess.run([sys.executable, MODULE], env=env, capture_output=True, text=True, check=True).stdout
    assert out == E.execute_text(E.load_execute_corpus(tmp_path))


def test_real_tree_reads_as_execute_md():
    corpus = E.load_execute_corpus()
    if list(corpus) == ["execute.md"]:
        assert E.execute_text(corpus) == corpus["execute.md"]
