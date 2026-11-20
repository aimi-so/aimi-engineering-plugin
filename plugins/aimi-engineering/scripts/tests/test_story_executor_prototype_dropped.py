"""Pins how the story-executor brief reads `metadata.prototypeDropped`.

An entry records how the PLAN saw a prototype, not whether the prototype
exists. Until 1.164.0 the brief read every entry as a prototype that was gone
and told the executor never to open the path it names. A `no-view-anchors`
entry names a prototype the plan did read, which `metadata.prototypePaths`
lists under the very same path, so the prohibition won: every screen story
after the first was built from the acceptance criteria's restatement of the
prototype instead of from the prototype, and an option a criterion left out
of its summary never reached the screen.

These tests read the brief's step 0b only, so a sentence elsewhere in the
file cannot satisfy or break them.
"""

from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
SKILL = PLUGIN / "skills" / "story-executor" / "SKILL.md"


def _prototypes_step() -> str:
    text = SKILL.read_text(encoding="utf-8")
    start = text.index("**0b. Prototypes.**")
    end = text.index("**0c. Working directory.**", start)
    return " ".join(text[start:end].split())


def test_no_entry_tells_the_executor_to_skip_a_listed_prototype():
    step = _prototypes_step()
    assert "never open, move, delete or resolve the path" not in step
    assert "it never stops you reading one" in step


def test_a_no_view_anchors_prototype_is_read_in_full_as_the_layout_reference():
    step = _prototypes_step()
    assert '`reason: "no-view-anchors"`' in step
    assert "Read it in full anyway: it is still this story's layout reference." in step


def test_a_prototype_the_plan_never_saw_is_read_and_checked_against_the_criteria():
    step = _prototypes_step()
    assert "the plan was written without its contents" in step
    assert "name in the report each place where a criterion and the prototype disagree" in step


def test_a_path_named_only_in_the_record_is_still_never_opened():
    # The record carries no path confinement, so the one route to a prototype
    # stays the two fields every other step already resolves.
    step = _prototypes_step()
    assert (
        "You open prototypes only through `metadata.prototypePaths[]` and "
        "`story.implementation.prototypeAnchor`"
    ) in step
    assert "A path named only in `prototypeDropped`, in neither of those fields: do not open it" in step
