"""Tests for scripts/bundle_relevance.py, the scoring behind `detect-design-bundle --feature-stdin`.

What is worth pinning: the tokenizer (ASCII fold first, [a-z0-9] runs, three
characters or more, stop-words and generic app words removed), the title rule
(first H1 of a BusinessSpec found in any case directly under project/), the
2000-character cap on the description, the filter turning itself off for a
description with nothing usable, that the description travels on stdin only, and
the leaked-fixture regression the filter exists for. Every case builds its
bundles under pytest's tmp_path, never under a real .aimi/.
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import bundle_relevance as B  # noqa: E402

MODULE = os.path.join(SCRIPTS, "bundle_relevance.py")
HANDOFF = "This is a **handoff bundle** from Claude Design (claude.ai/design).\n"


def make_bundle(parent, name, title=None, spec_name="BusinessSpec.md", body=None):
    bundle = parent / name
    (bundle / "project").mkdir(parents=True)
    (bundle / "README.md").write_text(HANDOFF)
    if body is not None:
        (bundle / "project" / spec_name).write_text(body)
    elif title is not None:
        (bundle / "project" / spec_name).write_text("# " + title + "\n")
    return str(bundle) + "/"


def run_module(description, dirs):
    proc = subprocess.run(
        [sys.executable, MODULE, "--"] + list(dirs),
        input=description.encode("utf-8"),
        capture_output=True,
    )
    return proc


class TestTokens:
    def test_fold_matches_accented_to_unaccented(self):
        assert "configuracao" in B.tokens("Configuração")
        assert B.tokens("Configuração") == B.tokens("configuracao")

    def test_runs_of_letters_and_digits_only(self):
        assert B.tokens("invoice-dashboard_v2/export") == {
            "invoice", "dashboard", "export"
        }

    def test_short_tokens_are_dropped(self):
        assert B.tokens("go to ui ab abc") == {"abc"}

    def test_english_and_portuguese_stop_words_are_dropped(self):
        assert B.tokens("the invoice for the customer") == {"invoice", "customer"}
        assert B.tokens("para a fatura do cliente") == {"fatura", "cliente"}

    def test_generic_app_words_are_dropped(self):
        assert B.tokens("new app page feature for payroll") == {"payroll"}

    def test_digits_count_as_token_characters(self):
        assert "2923383" in B.tokens("verify-import-2923383")

    def test_description_is_capped_at_2000_characters(self):
        # The cut falls on character 2000, so a word ending at or before it is
        # kept whole, a word straddling it is cut short, and one starting
        # after it is gone.
        assert B.description_tokens(("-" * 1990) + " alpha") == {"alpha"}
        assert B.description_tokens(("-" * 1995) + " alpha") == {"alph"}
        assert B.description_tokens(("-" * 2000) + " alpha") == set()


class TestTitle:
    def test_first_h1_wins(self, tmp_path):
        d = make_bundle(tmp_path, "b", body="intro\n# First title\n# Second\n")
        assert B.business_spec_title(d) == "First title"

    def test_h2_is_not_a_title(self, tmp_path):
        d = make_bundle(tmp_path, "b", body="## Only h2\n")
        assert B.business_spec_title(d) == ""

    def test_h1_inside_a_code_fence_is_skipped(self, tmp_path):
        d = make_bundle(tmp_path, "b", body="```\n# not a title\n```\n# Real title\n")
        assert B.business_spec_title(d) == "Real title"

    def test_spec_found_case_insensitively(self, tmp_path):
        d = make_bundle(tmp_path, "b", title="Camel case title", spec_name="businessSpec.md")
        assert B.business_spec_title(d) == "Camel case title"

    def test_missing_spec_is_an_empty_title(self, tmp_path):
        d = make_bundle(tmp_path, "b")
        assert B.business_spec_title(d) == ""

    def test_title_alone_makes_a_bundle_relevant(self, tmp_path):
        d = make_bundle(tmp_path, "opaque-name", title="Payroll export")
        active, relevant, filtered = B.bundle_relevance_filter("rewrite payroll", [d])
        assert (active, relevant, filtered) == (True, [d], [])

    def test_directory_name_alone_makes_a_bundle_relevant(self, tmp_path):
        d = make_bundle(tmp_path, "billing-portal")
        active, relevant, _ = B.bundle_relevance_filter("billing changes", [d])
        assert relevant == [d]


class TestFilter:
    def test_accented_description_matches_unaccented_directory(self, tmp_path):
        d = make_bundle(tmp_path, "configuracao-conta")
        active, relevant, filtered = B.bundle_relevance_filter(
            "Melhorar a configuração da conta", [d]
        )
        assert active and relevant == [d] and filtered == []

    def test_unrelated_bundle_is_filtered(self, tmp_path):
        good = make_bundle(tmp_path, "billing-portal", title="Invoice dashboard")
        bad = make_bundle(tmp_path, "weather-widget", title="Forecast")
        active, relevant, filtered = B.bundle_relevance_filter(
            "Improve the invoice dashboard", [good, bad]
        )
        assert (active, relevant, filtered) == (True, [good], [bad])

    @pytest.mark.parametrize("description", ["", "   \n\t", "the and for a new app"])
    def test_description_with_no_usable_token_turns_the_filter_off(
        self, tmp_path, description
    ):
        a = make_bundle(tmp_path, "aaa-one")
        b = make_bundle(tmp_path, "bbb-two")
        assert B.bundle_relevance_filter(description, [a, b]) == (False, [a, b], [])

    def test_order_is_preserved(self, tmp_path):
        dirs = [make_bundle(tmp_path, n) for n in ("zeta-shop", "alpha-shop", "mid-shop")]
        _, relevant, _ = B.bundle_relevance_filter("shop", dirs)
        assert relevant == dirs

    def test_leaked_fixture_is_filtered_for_an_unrelated_description(self, tmp_path):
        leaked = make_bundle(
            tmp_path, "verify-import-2923383", body="biz-CHANGED"
        )
        assert os.path.getsize(os.path.join(leaked, "project", "BusinessSpec.md")) == 11
        real = make_bundle(tmp_path, "billing-portal", title="Invoice dashboard")
        _, relevant, filtered = B.bundle_relevance_filter(
            "Improve the invoice dashboard", [leaked, real]
        )
        assert relevant == [real] and filtered == [leaked]
        _, relevant, filtered = B.bundle_relevance_filter(
            "Improve the invoice dashboard", [leaked]
        )
        assert relevant == [] and filtered == [leaked]


class TestVerb:
    def test_prints_one_json_object(self, tmp_path):
        good = make_bundle(tmp_path, "billing-portal", title="Invoice dashboard")
        bad = make_bundle(tmp_path, "verify-import-2923383", body="biz-CHANGED")
        proc = run_module("Improve the invoice dashboard", [good, bad])
        assert proc.returncode == 0
        assert json.loads(proc.stdout) == {
            "active": True,
            "relevant": [good],
            "filtered": [bad],
        }

    def test_accented_description_over_stdin(self, tmp_path):
        d = make_bundle(tmp_path, "configuracao-conta")
        proc = run_module("configuração", [d])
        assert json.loads(proc.stdout)["relevant"] == [d]

    def test_invalid_utf8_on_stdin_does_not_crash(self, tmp_path):
        d = make_bundle(tmp_path, "alpha-shop")
        proc = subprocess.run(
            [sys.executable, MODULE, "--", d],
            input=b"alpha \xff\xfe shop",
            capture_output=True,
        )
        assert proc.returncode == 0
        assert json.loads(proc.stdout)["relevant"] == [d]

    def test_unknown_flag_is_refused(self):
        proc = subprocess.run(
            [sys.executable, MODULE, "--nope"], input=b"", capture_output=True
        )
        assert proc.returncode == 1
        assert b"unknown flag" in proc.stderr
        assert proc.stdout == b""
