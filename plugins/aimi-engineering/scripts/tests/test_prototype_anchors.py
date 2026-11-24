"""Tests for scripts/prototype_anchors.py, driven through index-prototype-anchors
and extract-prototype-sections against throwaway AIMI roots."""

import os
import shutil
import subprocess
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

# No data-view section anywhere: only containers with ids, a tab panel named from
# a tab that FOLLOWS it, a tab panel named by aria-labelledby, one named by
# aria-label, and h1-h3 headings. #app wraps every other anchor.
NO_VIEW_HTML = """<!doctype html>
<html><body>
<div id="app">
  <h1>Acme   Console</h1>
  <section id="login">
    <h2>Sign in</h2>
    <p>login body</p>
  </section>
  <div role="tabpanel" id="panel-usage" aria-labelledby="tab-usage">
    <h2>Usage</h2>
    <p>usage body</p>
  </div>
  <div role="tabpanel" id="panel-billing">
    <h2>Billing</h2>
    <p>billing body</p>
  </div>
  <div role="tabpanel" aria-label="Audit log">
    <p>audit body</p>
  </div>
  <nav role="tablist">
    <button role="tab" id="tab-usage" aria-controls="panel-usage">Usage tab</button>
    <button role="tab" id="tab-billing" aria-controls="panel-billing">Billing  tab</button>
  </nav>
</div>
</body></html>
"""


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = os.path.realpath(tmp)
        os.makedirs(os.path.join(tmp, ".aimi"))
        yield tmp


def cli(root, *args, cwd=None, env_extra=None):
    env = dict(os.environ)
    env.pop("AIMI_DEV_DIR", None)
    env.update(env_extra or {})
    return subprocess.run(
        ["bash", CLI, *args], cwd=cwd or root, capture_output=True, text=True, env=env
    )


def put(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(text if isinstance(text, bytes) else text.encode("utf-8"))
    return path


def index(root, path, **kw):
    return cli(root, "index-prototype-anchors", path, **kw)


def extract(root, path, *anchors, **kw):
    return cli(root, "extract-prototype-sections", path, "--anchors", "\n".join(anchors), **kw)


def lines(result):
    return result.stdout.splitlines()


# --- index -------------------------------------------------------------------


def test_index_lists_kind_tagged_anchors_in_document_order(root):
    path = put(root, ".aimi/proto.html", NO_VIEW_HTML)
    r = index(root, path)
    assert r.returncode == 0, r.stderr
    assert lines(r) == [
        "heading:Acme Console",
        "id:login",
        "heading:Sign in",
        "id:panel-usage",
        "tab:Usage tab",
        "heading:Usage",
        "id:panel-billing",
        "tab:Billing tab",
        "heading:Billing",
        "tab:Audit log",
    ]


def test_index_leaves_out_the_container_that_encloses_every_other_anchor(root):
    path = put(root, ".aimi/proto.html", NO_VIEW_HTML)
    assert "id:app" not in lines(index(root, path))


def test_index_keeps_a_container_that_does_not_enclose_everything(root):
    html = '<div id="a"><h2>One</h2></div><div id="b"><h2>Two</h2></div>'
    path = put(root, ".aimi/proto.html", html)
    assert lines(index(root, path)) == ["id:a", "heading:One", "id:b", "heading:Two"]


def test_index_names_a_tab_panel_from_a_tab_that_follows_it(root):
    html = (
        '<div role="tabpanel" id="p1"><p>x</p></div>'
        '<button role="tab" aria-controls="p1">Late   name</button>'
    )
    path = put(root, ".aimi/proto.html", html)
    assert "tab:Late name" in lines(index(root, path))


def test_index_prefers_aria_labelledby_over_the_controlling_tab_and_the_label(root):
    html = (
        '<span id="lbl">From  label</span>'
        '<div role="tabpanel" id="p1" aria-labelledby="lbl" aria-label="Plain">x</div>'
        '<button role="tab" aria-controls="p1">From tab</button>'
    )
    path = put(root, ".aimi/proto.html", html)
    assert [x for x in lines(index(root, path)) if x.startswith("tab:")] == ["tab:From label"]


def test_index_lists_view_sections_and_a_repeated_anchor_once(root):
    html = (
        '<section data-view="home"><h2>Same</h2></section>'
        '<section data-view="home"><h2>Same</h2></section>'
    )
    path = put(root, ".aimi/proto.html", html)
    assert lines(index(root, path)) == ["view:home", "heading:Same"]


def test_index_only_reads_h1_to_h3(root):
    path = put(root, ".aimi/proto.html", "<h3>Three</h3><h4>Four</h4><h6>Six</h6>")
    assert lines(index(root, path)) == ["heading:Three"]


def test_index_skips_an_unsafe_name_with_a_warning(root):
    html = (
        "<h2>Costs $5</h2><h2>Back`tick</h2><h2>Say \"hi\"</h2>"
        "<h2>Back\\slash</h2><h2>Fine</h2>"
    )
    path = put(root, ".aimi/proto.html", html)
    r = index(root, path)
    assert r.returncode == 0
    assert lines(r) == ["heading:Fine"]
    assert r.stderr.count("anchor skipped") == 4
    assert "heading:Costs $5" in r.stderr


def test_index_of_a_file_with_no_anchor_prints_nothing(root):
    path = put(root, ".aimi/proto.html", "<html><body><p>nothing</p></body></html>")
    r = index(root, path)
    assert (r.returncode, r.stdout) == (0, "")


def test_index_reads_a_file_under_aimi_sources(root):
    path = put(root, ".aimi/sources/kit-abc12345/screen.html", "<h2>In kit</h2>")
    r = index(root, path)
    assert r.returncode == 0 and lines(r) == ["heading:In kit"]


def test_index_refuses_a_path_that_escapes_the_project(root):
    # An absolute path outside the root and a ../ path to the same file both refuse.
    sibling = os.path.join(os.path.dirname(root), "escape-%d.html" % os.getpid())
    put(os.path.dirname(root), os.path.basename(sibling), "<h2>x</h2>")
    try:
        r = index(root, os.path.join("..", os.path.basename(sibling)))
        assert r.returncode == 1 and "escapes project root" in r.stderr and r.stdout == ""
    finally:
        os.unlink(sibling)
    outside = tempfile.NamedTemporaryFile(suffix=".html", delete=False)
    outside.write(b"<h2>x</h2>")
    outside.close()
    try:
        r = index(root, outside.name)
        assert r.returncode == 1
        assert "escapes project root" in r.stderr
        assert r.stdout == ""
    finally:
        os.unlink(outside.name)


def test_index_refuses_a_missing_file_and_a_missing_argument(root):
    r = index(root, os.path.join(root, ".aimi", "nope.html"))
    assert r.returncode == 1 and "not found" in r.stderr.lower()
    r = cli(root, "index-prototype-anchors")
    assert r.returncode == 1 and "Usage" in r.stderr
    r = cli(root, "index-prototype-anchors", "--bogus")
    assert r.returncode == 1 and "Usage" in r.stderr


def test_index_rebases_a_relative_path_onto_the_callers_directory(root):
    put(root, "sub/screen.html", "<h2>Local</h2>")
    r = index(root, "screen.html", cwd=os.path.join(root, "sub"))
    assert r.returncode == 0, r.stderr
    assert lines(r) == ["heading:Local"]


def test_index_is_listed_in_help(root):
    r = cli(root, "help")
    assert "index-prototype-anchors <file>" in r.stdout


def test_index_refuses_without_python3(root, tmp_path):
    path = put(root, ".aimi/proto.html", "<h2>x</h2>")
    r = index(root, path, env_extra={"PATH": nopython_path(tmp_path)})
    assert r.returncode == 1
    assert "python3 is required" in r.stderr


# --- extract -----------------------------------------------------------------


def disk(root, path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8")


def test_extract_round_trips_every_indexed_line_byte_for_byte(root):
    path = put(root, ".aimi/proto.html", NO_VIEW_HTML)
    text = disk(root, path)
    expected = {
        "id:login": text[text.index('<section id="login">'): text.index("</section>") + len("</section>")],
        "tab:Usage tab": text[
            text.index('<div role="tabpanel" id="panel-usage"'): text.index("</div>", text.index("usage body")) + 6
        ],
        "tab:Audit log": text[
            text.index('<div role="tabpanel" aria-label="Audit log">'): text.index("</div>", text.index("audit body")) + 6
        ],
    }
    for line in lines(index(root, path)):
        r = extract(root, path, line)
        assert r.returncode == 0, (line, r.stderr)
        assert r.stdout, line
        assert r.stderr == "", (line, r.stderr)
        assert r.stdout in text, line
    for anchor, want in expected.items():
        assert extract(root, path, anchor).stdout == want


def test_extract_id_prints_the_element_through_its_matching_close(root):
    html = '<div id="a"><div id="b">in<div>deep</div>b</div>tail</div><p>after</p>'
    path = put(root, ".aimi/proto.html", html)
    assert extract(root, path, "id:b").stdout == '<div id="b">in<div>deep</div>b</div>'
    assert extract(root, path, "id:a").stdout == '<div id="a"><div id="b">in<div>deep</div>b</div>tail</div>'


def test_extract_unclosed_id_prints_to_end_of_file(root):
    html = '<p>before</p>\n<div id="open">\n<p>one</p>\n<p>two</p>\n'
    path = put(root, ".aimi/proto.html", html)
    assert extract(root, path, "id:open").stdout == '<div id="open">\n<p>one</p>\n<p>two</p>\n'


def test_extract_tab_prints_the_panel(root):
    path = put(root, ".aimi/proto.html", NO_VIEW_HTML)
    r = extract(root, path, "tab:Billing tab")
    assert r.stdout.startswith('<div role="tabpanel" id="panel-billing">')
    assert r.stdout.endswith("</div>")
    assert "billing body" in r.stdout and "usage body" not in r.stdout


def test_extract_heading_runs_to_the_next_heading_of_the_same_or_higher_level(root):
    html = "<h1>Top</h1>a<h2>Mid</h2>b<h3>Low</h3>c<h4>Deep</h4>d<h2>Next</h2>e<h1>Again</h1>f"
    path = put(root, ".aimi/proto.html", html)
    assert extract(root, path, "heading:Mid").stdout == "<h2>Mid</h2>b<h3>Low</h3>c<h4>Deep</h4>d"
    assert extract(root, path, "heading:Low").stdout == "<h3>Low</h3>c<h4>Deep</h4>d"
    assert extract(root, path, "heading:Top").stdout == "<h1>Top</h1>a<h2>Mid</h2>b<h3>Low</h3>c<h4>Deep</h4>d<h2>Next</h2>e"
    assert extract(root, path, "heading:Again").stdout == "<h1>Again</h1>f"


def test_extract_heading_stops_at_a_deeper_numbered_heading_only_when_it_is_not_deeper(root):
    html = "<h2>A</h2>x<h5>five</h5>y<h3>three</h3>z<h2>B</h2>"
    path = put(root, ".aimi/proto.html", html)
    assert extract(root, path, "heading:A").stdout == "<h2>A</h2>x<h5>five</h5>y<h3>three</h3>z"
    assert extract(root, path, "heading:three").stdout == "<h3>three</h3>z"


def test_extract_heading_survives_unbalanced_markup(root):
    html = "<div><h2>Open<p>text</div>\n<h2>Following</h2><span>last"
    path = put(root, ".aimi/proto.html", html)
    r = extract(root, path, "heading:Open")
    assert r.returncode == 0
    assert r.stdout == "<h2>Open<p>text</div>\n"
    assert extract(root, path, "heading:Following").stdout == "<h2>Following</h2><span>last"


def test_extract_prints_the_raw_bytes_including_crlf_and_utf8(root):
    raw = '<div id="x">\r\n  <h2>Café — menu</h2>\r\n  <p>naïve &amp; über</p>\r\n</div>\r\n<p>out</p>'
    path = put(root, ".aimi/proto.html", raw)
    r = subprocess.run(
        ["bash", CLI, "extract-prototype-sections", path, "--anchors", "id:x"],
        cwd=root,
        capture_output=True,
    )
    assert r.returncode == 0
    assert r.stdout == raw[: raw.index("</div>") + 6].encode("utf-8")
    assert extract(root, path, "heading:Café — menu").stdout.startswith("<h2>Café")


def test_extract_keeps_request_order(root):
    path = put(root, ".aimi/proto.html", "<h2>One</h2>1<h2>Two</h2>2")
    assert extract(root, path, "heading:Two", "heading:One").stdout == "<h2>Two</h2>2<h2>One</h2>1"


def test_extract_unmatched_anchor_warns_and_exits_zero(root):
    path = put(root, ".aimi/proto.html", "<h2>One</h2>")
    for anchor in ("id:ghost", "tab:ghost", "heading:ghost", "view:ghost", "id:", "ghost"):
        r = extract(root, path, anchor)
        assert r.returncode == 0, anchor
        assert r.stdout == "", anchor
        assert "no section matched anchor: %s" % anchor in r.stderr, anchor


def test_extract_rejects_metacharacters_after_the_kind_prefix(root):
    path = put(root, ".aimi/proto.html", "<h2>One</h2>")
    for anchor in ("id:a$b", "heading:a`b", 'tab:a"b', "heading:a\\b"):
        r = extract(root, path, anchor)
        assert r.returncode == 0
        assert r.stdout == ""
        assert "anchor rejected (shell metacharacter)" in r.stderr


def test_extract_view_prefix_matches_a_data_view_section_like_a_bare_name(root):
    html = '<section data-view="Home">\n<p>home</p>\n</section>\n<p>out</p>\n'
    path = put(root, ".aimi/proto.html", html)
    bare = extract(root, path, "Home").stdout
    assert bare == '<section data-view="Home">\n<p>home</p>\n</section>\n'
    assert extract(root, path, "view:Home").stdout == bare
    assert extract(root, path, "view:home").stdout == bare


def test_extract_matches_names_case_insensitively_as_a_fallback(root):
    path = put(root, ".aimi/proto.html", "<h2>Sign In</h2>x")
    assert extract(root, path, "heading:sign in").stdout == "<h2>Sign In</h2>x"


def test_extract_reads_the_first_of_a_repeated_anchor(root):
    path = put(root, ".aimi/proto.html", "<h2>Same</h2>first<h2>Same</h2>second")
    assert extract(root, path, "heading:Same").stdout == "<h2>Same</h2>first"


def test_extract_bare_and_view_anchors_run_without_python3(root, tmp_path):
    html = '<section data-view="Home">\n<p>home</p>\n</section>\n'
    path = put(root, ".aimi/proto.html", html)
    env = {"PATH": nopython_path(tmp_path)}
    assert extract(root, path, "Home", env_extra=env).stdout == html
    assert extract(root, path, "view:Home", env_extra=env).stdout == html


def test_extract_kind_tagged_anchor_refuses_without_python3(root, tmp_path):
    path = put(root, ".aimi/proto.html", "<h2>One</h2>")
    r = extract(root, path, "heading:One", env_extra={"PATH": nopython_path(tmp_path)})
    assert r.returncode == 1
    assert "python3 is required" in r.stderr


def test_extract_refusal_and_confinement_are_unchanged(root):
    r = extract(root, os.path.join(root, ".aimi", "nope.html"), "id:x")
    assert r.returncode == 1 and "not found" in r.stderr.lower()
    outside = tempfile.NamedTemporaryFile(suffix=".html", delete=False)
    outside.close()
    try:
        r = extract(root, outside.name, "id:x")
        assert r.returncode == 1 and "escapes project root" in r.stderr
    finally:
        os.unlink(outside.name)


# --- helpers -----------------------------------------------------------------

_TOOLS = (
    "bash sh env awk gawk mawk sed tr cat grep egrep dirname basename mkdir rm mktemp "
    "date head tail sort uniq wc cut readlink realpath ls cp mv printf git jq find "
    "xargs stat id uname true false test expr sleep touch ln chmod tee which"
).split()


def nopython_path(tmp_path):
    """A PATH directory holding the shell tools the CLI needs and no python3."""
    bindir = os.path.join(str(tmp_path), "nopython-bin")
    if not os.path.isdir(bindir):
        os.makedirs(bindir)
        for tool in _TOOLS:
            found = shutil.which(tool)
            if found:
                os.symlink(found, os.path.join(bindir, tool))
    return bindir
