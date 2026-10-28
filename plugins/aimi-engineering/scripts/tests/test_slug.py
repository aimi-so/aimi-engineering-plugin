"""Tests for scripts/slug.py, the module behind `aimi-cli.sh slugify`.

What is worth pinning: the fold (accents become their ASCII letter, letters with
no NFKD form are dropped, nothing else is touched), the slug rules built on it
(one hyphen per run, both ends trimmed, 50 characters then trimmed again), the
refusal of a text with nothing to slug, that free text is inert, and that the
module imports nothing from the tasks -> story_merge -> audit_patches chain.
Each CLI case runs from a temp directory with no .aimi/ beside it.
"""

import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import slug as S  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
MODULE = os.path.join(SCRIPTS, "slug.py")


def run_cli(args, cwd, stdin=None):
    return subprocess.run(
        [CLI, "slugify"] + args,
        cwd=cwd,
        input=stdin,
        capture_output=True,
        text=False,
    )


def out(proc):
    return proc.stdout.decode("utf-8")


def err(proc):
    return proc.stderr.decode("utf-8")


def test_slug_ascii_fold_is_nfkd_ascii_lowercase_only():
    assert S.ascii_fold("Café Résumé Über") == "cafe resume uber"
    assert S.ascii_fold("A-B_c  D!") == "a-b_c  d!"
    assert S.ascii_fold("Søren Straße Ærø") == "sren strae r"
    assert S.ascii_fold("日本語") == ""


def test_slug_slugify_collapses_runs_and_trims_both_ends():
    assert S.slugify("  --Hello, World!  ") == "hello-world"
    assert S.slugify("a___b...c") == "a-b-c"
    assert S.slugify("Café Résumé Über") == "cafe-resume-uber"


def test_slug_slugify_drops_letters_without_an_nfkd_form():
    assert S.slugify("Søren Straße Ærø") == "sren-strae-r"


def test_slug_slugify_cuts_to_fifty_then_trims_again():
    letters = "a" * 49
    assert S.slugify(letters + " b") == letters
    assert S.slugify("a" * 80) == "a" * 50
    assert len(S.slugify("word " * 30)) <= 50
    assert not S.slugify("word " * 30).endswith("-")


def test_slug_slugify_returns_empty_when_nothing_survives():
    assert S.slugify("日本語") == ""
    assert S.slugify("!!! ???") == ""
    assert S.slugify("") == ""


def test_slug_cli_text_argument(tmp_path):
    proc = run_cli(["Café Résumé Über"], tmp_path)
    assert proc.returncode == 0
    assert out(proc) == "cafe-resume-uber\n"
    assert not (tmp_path / ".aimi").exists()


def test_slug_cli_leading_double_dash_allows_a_dash_led_text(tmp_path):
    proc = run_cli(["--", "--x y"], tmp_path)
    assert proc.returncode == 0
    assert out(proc) == "x-y\n"


def test_slug_cli_stdin(tmp_path):
    proc = run_cli(["--stdin"], tmp_path, stdin="  --Hello, World!  ".encode())
    assert proc.returncode == 0
    assert out(proc) == "hello-world\n"


def test_slug_cli_stdin_decodes_utf8_with_replacement(tmp_path):
    proc = run_cli(["--stdin"], tmp_path, stdin=b"caf\xc3\xa9 \xff ok")
    assert proc.returncode == 0
    assert out(proc) == "cafe-ok\n"


def test_slug_cli_dropped_letters(tmp_path):
    proc = run_cli(["Søren Straße Ærø"], tmp_path)
    assert proc.returncode == 0
    assert out(proc) == "sren-strae-r\n"


@pytest.mark.parametrize("text", ["日本語", "!!! ???", ""])
def test_slug_cli_refuses_a_text_with_no_ascii_letter_or_digit(tmp_path, text):
    proc = run_cli([text], tmp_path)
    assert proc.returncode == 1
    assert out(proc) == ""
    assert "slugify" in err(proc)
    assert "no ASCII letter or digit to build a slug from" in err(proc)


def test_slug_cli_empty_stdin_is_refused(tmp_path):
    proc = run_cli(["--stdin"], tmp_path, stdin=b"")
    assert proc.returncode == 1
    assert out(proc) == ""
    assert "no ASCII letter or digit" in err(proc)


def test_slug_cli_shell_metacharacters_are_inert(tmp_path):
    text = "$(touch PWNED) `id`"
    proc = run_cli([text], tmp_path)
    assert proc.returncode == 0
    assert out(proc) == "touch-pwned-id\n"
    proc = run_cli(["--stdin"], tmp_path, stdin=text.encode())
    assert out(proc) == "touch-pwned-id\n"
    assert not (tmp_path / "PWNED").exists()


def test_slug_cli_refuses_a_missing_source_an_unknown_flag_and_mixed_sources(tmp_path):
    proc = run_cli([], tmp_path)
    assert proc.returncode == 1 and out(proc) == ""
    assert "slugify: a text argument or --stdin is required" in err(proc)

    proc = run_cli(["--bogus"], tmp_path)
    assert proc.returncode == 1 and out(proc) == ""
    assert "slugify: unknown flag: --bogus" in err(proc)

    proc = run_cli(["--stdin", "text"], tmp_path, stdin=b"x")
    assert proc.returncode == 1 and out(proc) == ""
    assert "--stdin takes no other argument" in err(proc)

    proc = run_cli(["one", "two"], tmp_path)
    assert proc.returncode == 1 and out(proc) == ""
    assert "exactly one text argument" in err(proc)


def test_slug_cli_wrapper_shape():
    with open(CLI, encoding="utf-8") as f:
        text = f.read()
    start = text.index("\ncmd_slugify() {")
    body = text[start:text.index("\n}\n", start)]
    assert "check_python3" in body
    assert body.count("python3 ") == 1
    assert "_lock" not in body
    assert "find_aimi_root" not in body
    dispatch = text.index("slugify) shift; cmd_slugify")
    assert dispatch < text.index("find_aimi_root", dispatch)
    help_start = text.index("cmd_help()")
    assert "slugify (--stdin | <text>)" in text[help_start:]


def test_slug_import_loads_no_other_planning_module():
    code = (
        "import sys; sys.path.insert(0, %r); import slug; "
        "print(sorted(m for m in ('tasks','story_merge','audit_patches') if m in sys.modules))"
    ) % SCRIPTS
    proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert proc.returncode == 0
    assert proc.stdout.strip() == "[]"
    assert os.path.isfile(MODULE)
