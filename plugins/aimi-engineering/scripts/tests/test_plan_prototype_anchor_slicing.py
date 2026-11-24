"""Pins how `/aimi:plan` slices a prototype per outline entry.

Until now the per-entry slicing matched `<section data-view="...">` only, so a
prototype built from id containers, tab panels or headings counted as having no
anchors: its first outline entry received the whole file and every later screen
story got the path alone. `index-prototype-anchors` now prints the anchors such
a file carries, and the plan passes the lines it selects, unchanged, to
`extract-prototype-sections --anchors`.

Each test reads one file as text and only the part it names (a Step, the
`prototypeDropped` bullet, the `prototypeDropped` paragraph), so a sentence
elsewhere cannot satisfy or break it. Every negated phrase is paired with the
positive statement it stands next to.
"""

import re
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
BLOCKS = PLUGIN / "commands" / "references" / "plan" / "phase-3d-prototype-blocks.md"
CONTEXT = PLUGIN / "commands" / "references" / "plan" / "phase-4-metadata-context.md"
SCHEMA = PLUGIN / "docs" / "dev" / "tasks-schema.md"
CLI = PLUGIN / "scripts" / "aimi-cli.sh"


def _flat(text: str) -> str:
    return " ".join(text.split())


def _step(marker: str, next_marker: str) -> str:
    text = BLOCKS.read_text(encoding="utf-8")
    start = text.index(marker)
    end = text.index(next_marker, start)
    return text[start:end]


def _step1() -> str:
    return _step("**Step 1 — ", "**Step 2 — ")


def _step2() -> str:
    return _step("**Step 2 — ", "**Step 3 — ")


def _step3() -> str:
    return _step("**Step 3 — ", "**Step 4 — ")


def _degradation() -> str:
    text = BLOCKS.read_text(encoding="utf-8")
    return text[text.index("**No-anchor degradation.**"):]


def _context_bullet() -> str:
    for line in CONTEXT.read_text(encoding="utf-8").splitlines():
        if line.startswith("- **prototypeDropped**"):
            return _flat(line)
    raise AssertionError("no prototypeDropped bullet in phase-4-metadata-context.md")


def _schema_paragraph() -> str:
    for line in SCHEMA.read_text(encoding="utf-8").splitlines():
        if line.startswith("> `metadata.prototypeDropped`"):
            return _flat(line)
    raise AssertionError("no prototypeDropped paragraph in tasks-schema.md")


def test_the_verb_the_plan_calls_is_one_the_cli_dispatches():
    cli = CLI.read_text(encoding="utf-8")
    assert re.search(r"^\s*index-prototype-anchors\)\s", cli, re.M)
    assert "cmd_index_prototype_anchors()" in cli
    assert "extract-prototype-sections)" in cli


def test_step_1_builds_the_index_from_the_verb_and_not_from_a_data_view_scan():
    step = _step1()
    assert '"$AIMI_CLI" index-prototype-anchors "<file path>"' in step
    assert "`<kind>:<name>`" in step
    for kind in ("`view`", "`id`", "`tab`", "`heading`"):
        assert kind in step
    assert "prototypeViewIndex" in step
    assert "scan the file for every `<section data-view" not in step


def test_step_1_carries_the_two_cli_path_resolution_lines_verbatim():
    resolution = [
        'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null'
        ' || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)',
        ': "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"',
    ]
    for step in (_step1(), _step3()):
        for line in resolution:
            assert line in step


def test_step_2_selects_the_screens_anchors_from_every_kind():
    step = _step2()
    assert "from every kind" in step
    assert "the screen that entry implements" in step
    # A prototype with data-view sections is still sliced by its views.
    assert "still sliced by its views" in step
    assert "select the `view:` line that names the screen" in step


def test_step_2_sanitizes_the_whole_line_and_drops_what_still_holds_a_metacharacter():
    step = _step2()
    assert "The rule applies to the whole line, and the colon after the kind survives it." in step
    assert "DROP any name that still contains `$`, a backtick, `\"`, or `\\`" in step
    assert "truncate to 200 characters" in step


def test_step_3_passes_the_selected_lines_unchanged_newline_joined():
    step = _step3()
    assert '"$AIMI_CLI" extract-prototype-sections "<file path>" --anchors "<newline-joined selected lines' in step
    assert "pass through unchanged, kind prefix included, joined with **newlines**" in step


def test_step_3_keeps_the_slice_cap_the_escaping_and_the_wrapping_tag():
    step = _step3()
    assert "**20 KB**" in step
    assert "`</prototype_html` sequence to `&lt;/prototype_html`" in step
    assert '<prototype_html label="<letter>" path="<relative-path-from-project-root>">' in step


def test_the_section_keeps_its_heading_guard_rail_and_read_on_demand_step():
    text = BLOCKS.read_text(encoding="utf-8")
    assert "### Per-Entry View-Scoped Prototype Block Preparation" in text
    assert "`metadata.prototypePaths` still names the WHOLE prototype file and never a slice" in text
    assert "**Step 4 — Read-on-demand fallback.**" in text
    assert "never a hard cap on what the expander can see" in text


def test_the_no_anchor_degradation_fires_only_for_an_empty_index():
    degradation = _flat(_degradation())
    assert "whose list (Step 1) is empty" in degradation
    assert "no anchor of any kind" in degradation
    assert "carries zero `data-view` sections" not in degradation
    assert "`reason` the literal string `no-view-anchors`" in degradation
    assert "A file that any anchor sliced gets no `prototypeDropped` entry" in degradation
    assert "the FIRST outline entry's `prototypeViewBlock`" in degradation


def test_the_intro_and_trigger_no_longer_say_slicing_matches_data_view_only():
    text = BLOCKS.read_text(encoding="utf-8")
    head = _flat(text[: text.index("**Step 1 — ")])
    assert "but matches `<section data-view" not in head
    assert "kind-tagged anchors (`view:`, `id:`, `tab:`, `heading:`)" in head
    assert "find no anchor in it" in head
    assert "find no `data-view` anchors in it" not in head


def test_the_metadata_bullet_describes_no_view_anchors_as_no_anchor_of_any_kind():
    bullet = _context_bullet()
    assert "carries no anchor of any kind" in bullet
    assert "no `data-view` section, container id, tab panel or heading" in bullet
    assert "carries zero `data-view` sections" not in bullet
    assert "that prototype WAS read, unlike an `aggregate-cap` entry" in bullet


def test_the_schema_paragraph_describes_no_view_anchors_as_no_anchor_of_any_kind():
    paragraph = _schema_paragraph()
    assert "carries no anchor of any kind" in paragraph
    assert "`index-prototype-anchors` prints nothing" in paragraph
    assert "carries zero `data-view` sections" not in paragraph
    assert "that prototype WAS read" in paragraph
    assert (
        "The executor still opens every prototype through `metadata.prototypePaths[]` and "
        "`story.implementation.prototypeAnchor`"
    ) in paragraph


def test_no_edited_text_tells_an_executor_to_skip_a_listed_prototype():
    # The guard for the roadmap's executor criterion: the plan side may only
    # describe how a prototype was sliced, never tell a reader to leave a
    # prototype in metadata.prototypePaths unopened.
    forbidden = (
        "never open, move, delete or resolve the path",
        "do not read a prototype listed in `metadata.prototypePaths`",
        "skip every prototype in `metadata.prototypePaths`",
    )
    for text in (
        _flat(BLOCKS.read_text(encoding="utf-8")),
        _context_bullet(),
        _schema_paragraph(),
    ):
        for phrase in forbidden:
            assert phrase not in text
    # Positive pairing: the read path stays open.
    assert "Read any of those files in full" in _flat(BLOCKS.read_text(encoding="utf-8"))
