"""Tests for `extract-sections --all-headings`, against a kit handoff document under
.aimi/sources/<kit>/ of a throwaway root."""

import os
import subprocess
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

# A handoff written with h1 and setext headings, behind a YAML front matter block
# whose closing --- sits directly under a text line, with fenced underline lookalikes.
HANDOFF = """---
title: Kit handoff
owner: design
---
Screens
=======

Intro to the screens.

Login
-----

Login body line.

```
Fake heading
============
```

~~~
Tilde fake
----------
~~~

# Settings

Settings body.

## Profile

Profile body.

Billing
=======

Billing body.
"""


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = os.path.realpath(tmp)
        os.makedirs(os.path.join(tmp, ".aimi", "sources", "kit-0123abcd"))
        yield tmp


def handoff_path(root, text=HANDOFF):
    path = os.path.join(root, ".aimi", "sources", "kit-0123abcd", "handoff.md")
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    return path


def sections(root, path, *anchors, all_headings=True):
    args = ["bash", CLI, "extract-sections", path, "--anchors", "\n".join(anchors)]
    if all_headings:
        args.append("--all-headings")
    env = dict(os.environ)
    env.pop("AIMI_DEV_DIR", None)
    return subprocess.run(args, cwd=root, capture_output=True, text=True, env=env)


def test_all_headings_slices_a_setext_level_one_heading(root):
    r = sections(root, handoff_path(root), "Screens")
    assert r.returncode == 0, r.stderr
    assert r.stdout.startswith("Screens\n=======\n")
    assert "Intro to the screens." in r.stdout
    # a level 2 setext heading is inside the level 1 section
    assert "Login\n-----\n" in r.stdout and "Login body line." in r.stdout
    assert "# Settings" not in r.stdout


def test_all_headings_slices_a_setext_level_two_heading_and_closes_at_the_next_heading(root):
    r = sections(root, handoff_path(root), "Login")
    assert r.returncode == 0, r.stderr
    assert r.stdout.startswith("Login\n-----\n")
    assert "Login body line." in r.stdout
    assert "# Settings" not in r.stdout and "Settings body." not in r.stdout


def test_all_headings_matches_an_atx_level_one_heading(root):
    r = sections(root, handoff_path(root), "Settings")
    assert r.returncode == 0
    assert r.stdout.startswith("# Settings\n")
    assert "Profile body." in r.stdout
    # the next setext level 1 heading closes it
    assert "Billing" not in r.stdout


def test_all_headings_a_level_two_atx_section_is_closed_by_a_setext_level_one(root):
    r = sections(root, handoff_path(root), "Profile")
    assert r.stdout == "## Profile\n\nProfile body.\n\n"


def test_all_headings_last_section_runs_to_end_of_file(root):
    r = sections(root, handoff_path(root), "Billing")
    assert r.stdout == "Billing\n=======\n\nBilling body.\n"


def test_all_headings_ignores_underlines_inside_a_fence(root):
    for fenced in ("Fake heading", "Tilde fake"):
        r = sections(root, handoff_path(root), fenced)
        assert r.returncode == 0
        assert r.stdout == ""
        assert "no section matched anchor: %s" % fenced in r.stderr


def test_all_headings_ignores_front_matter_delimiters(root):
    # `owner: design` is directly above the closing --- and must not become a heading.
    r = sections(root, handoff_path(root), "owner: design", "title: Kit handoff")
    assert r.stdout == ""
    assert r.stderr.count("no section matched anchor") == 2


def test_all_headings_front_matter_without_a_close_is_not_front_matter(root):
    text = "---\nWhat\n----\nbody\n"
    r = sections(root, handoff_path(root, text), "What")
    assert r.stdout == "What\n----\nbody\n"


def test_all_headings_a_line_used_as_an_underline_is_not_heading_text(root):
    text = "Title\n=====\n-----\nbody\n"
    r = sections(root, handoff_path(root, text), "=====")
    assert r.stdout == ""


def test_all_headings_matching_is_by_the_same_key_as_before(root):
    text = 'The "foo" flow\n==============\nbody\n'
    r = sections(root, handoff_path(root, text), "the foo flow")
    assert r.stdout == 'The "foo" flow\n==============\nbody\n'


def test_without_the_flag_h1_and_setext_headings_are_not_matchable(root):
    path = handoff_path(root)
    for anchor in ("Screens", "Login", "Settings", "Billing"):
        r = sections(root, path, anchor, all_headings=False)
        assert r.returncode == 0
        assert r.stdout == "", anchor
        assert "no section matched anchor: %s" % anchor in r.stderr


def test_without_the_flag_a_level_two_section_runs_through_a_setext_heading(root):
    # Setext headings do not close a section by default: the output is what it was.
    text = "## Alpha\nbody\n\nBeta\n====\nmore\n\n## Gamma\nlast\n"
    r = sections(root, handoff_path(root, text), "Alpha", all_headings=False)
    assert r.stdout == "## Alpha\nbody\n\nBeta\n====\nmore\n\n"


def test_with_the_flag_the_same_section_stops_at_the_setext_heading(root):
    text = "## Alpha\nbody\n\nBeta\n====\nmore\n\n## Gamma\nlast\n"
    r = sections(root, handoff_path(root, text), "Alpha")
    assert r.stdout == "## Alpha\nbody\n\n"


def test_the_flag_does_not_change_what_a_plain_markdown_file_slices_to(root):
    text = "# Title\n\n## One\nbody 1\n### Sub\nsub body\n## Two\nbody 2\n"
    path = handoff_path(root, text)
    for anchor in ("One", "Sub", "Two"):
        plain = sections(root, path, anchor, all_headings=False)
        flagged = sections(root, path, anchor)
        assert plain.stdout == flagged.stdout and plain.stdout != ""
        assert plain.returncode == flagged.returncode == 0


def test_all_headings_keeps_request_order_and_the_unmatched_warning(root):
    r = sections(root, handoff_path(root), "Billing", "Login", "Nothing here")
    assert r.returncode == 0
    assert r.stdout.index("Billing") < r.stdout.index("Login body line.")
    assert "no section matched anchor: Nothing here" in r.stderr


def test_the_flag_is_in_help_and_usage(root):
    env = dict(os.environ)
    env.pop("AIMI_DEV_DIR", None)
    h = subprocess.run(["bash", CLI, "help"], cwd=root, capture_output=True, text=True, env=env)
    assert "--all-headings" in h.stdout
    u = subprocess.run(["bash", CLI, "extract-sections"], cwd=root, capture_output=True, text=True, env=env)
    assert u.returncode == 1 and "--all-headings" in u.stderr
