from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HOOKS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(HOOKS_DIR))


def _load_dispatcher():
    """Import pre-bash-dispatcher as a module (hyphen in name)."""
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher",
        HOOKS_DIR / "pre-bash-dispatcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()
_strip_heredocs = dispatcher._strip_heredocs


# ---------------------------------------------------------------------------
# Tag form coverage
# ---------------------------------------------------------------------------

def test_bare_tag_form_strips_body():
    command = "cat <<EOF\ngit commit\nEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert result.count("git commit") == 1, "Only the real trailing commit should survive"
    assert result.endswith("git commit -m x")


def test_single_quoted_tag_form_strips_body():
    command = "cat <<'EOF'\ngit commit\nEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert result.count("git commit") == 1
    assert result.endswith("git commit -m x")


def test_double_quoted_tag_form_strips_body():
    command = 'cat <<"EOF"\ngit commit\nEOF\ngit commit -m x'
    result = _strip_heredocs(command)
    assert result.count("git commit") == 1
    assert result.endswith("git commit -m x")


def test_dash_tag_form_allows_indented_terminator():
    command = "cat <<-EOF\ngit commit\n\tEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert result.count("git commit") == 1
    assert result.endswith("git commit -m x")


def test_dash_tag_form_does_not_allow_indent_on_plain_form():
    """Without the `-` flag, an indented terminator line does NOT close the heredoc.

    This is a fail-closed case: since the plain-form heredoc never finds its
    (unindented) terminator, the whole command is treated as unterminated and
    the original string is returned unchanged.
    """
    command = "cat <<EOF\ngit commit\n\tEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert result == command


# ---------------------------------------------------------------------------
# Here-string exclusion
# ---------------------------------------------------------------------------

def test_here_string_is_never_treated_as_heredoc_opener():
    command = 'cat <<< "git commit"'
    result = _strip_heredocs(command)
    assert result == command, "A <<< here-string must never be treated as a heredoc opener"


def test_here_string_followed_by_real_commit_is_untouched():
    command = 'cat <<< "not a commit" && git commit -m x'
    result = _strip_heredocs(command)
    assert result == command


# ---------------------------------------------------------------------------
# Fail-closed behavior
# ---------------------------------------------------------------------------

def test_unterminated_heredoc_returns_original_string():
    command = "cat <<EOF\nsome body\nno terminator here"
    result = _strip_heredocs(command)
    assert result == command, "Unterminated heredoc must fail closed to the original string"


def test_unterminated_heredoc_never_raises():
    command = "cat <<EOF\n" + "line\n" * 5
    # Should not raise; should return the original unmodified command.
    result = _strip_heredocs(command)
    assert result == command


# ---------------------------------------------------------------------------
# Nested lookalike line inside a real heredoc body
# ---------------------------------------------------------------------------

def test_lookalike_opener_inside_body_does_not_swallow_subsequent_statement():
    """A line inside the body that itself looks like a heredoc opener must not
    be treated as a nested opener — the outer heredoc's own terminator still
    closes it, and the real statement after that terminator remains intact."""
    command = "cat <<EOF\ncat <<INNER\nEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert result == "cat <<EOF\ngit commit -m x"


def test_mention_inside_body_stays_invisible_while_trailing_statement_detected():
    command = "cat <<EOF\nremember to git commit\nEOF\ngit commit -m x"
    result = _strip_heredocs(command)
    assert "remember" not in result
    assert result.count("git commit") == 1
    assert dispatcher._GIT_COMMIT_RE.search(result)


# ---------------------------------------------------------------------------
# No heredoc present — identity
# ---------------------------------------------------------------------------

def test_no_heredoc_returns_command_unchanged():
    command = "git commit -m x"
    assert _strip_heredocs(command) == command


def test_multiline_without_heredoc_returns_command_unchanged():
    command = "cd /repo\ngit add -A\ngit commit -m x"
    assert _strip_heredocs(command) == command
