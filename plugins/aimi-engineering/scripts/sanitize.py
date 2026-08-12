#!/usr/bin/env python3
"""The prose sanitizer, ported from _ROADMAP_SANITIZE_JQ.

WHY THIS IS A MODULE OF ITS OWN
===============================

Two callers need this rule and neither may own it. roadmap.py sanitizes the free
text a phase contract carries; story_merge.py sanitizes the sub-agent-authored
titles that reach a dropped-dependency warning. Leaving it in roadmap.py and
importing it from story_merge.py would say that a story title is a roadmap
concern, which it is not; copying it would put the same rule in two places, which
is the disease this branch exists to cure -- it already existed twice, once here
and once as jq in aimi-cli.sh, and that is what US-006 ended.

Nothing else belongs in this file. It is the sanitizer and its argument, so that
"where is the rule" has exactly one answer and adding a second rule here would be
visibly out of place.

Rule order is load-bearing and is preserved exactly. Fenced blocks go first so
their contents cannot be reinterpreted by a later rule; the backtick span unwraps
to its inner text rather than being deleted, because deleting it destroyed the
very token a later phase greps for.

jq's regex engine is Oniguruma and Python's is `re`. Every pattern below was
compared against the jq original over the corpus in tests/test_roadmap.py --
`^` and `$` anchor to the whole string in both (no MULTILINE), `.` stops at a
newline in both, and both count length in codepoints, so the truncation slices
identically.
"""

import re


def rm_sanitize(value, maxlen):
    """Full prose sanitizer: formatting normalization AND content deletion."""
    if value is None:
        return None
    s = value
    s = re.sub(r"```[\s\S]*?```", "", s)
    s = re.sub(r"`([^`\n]*)`", r"\1", s)
    s = s.replace("`", "")
    s = re.sub(r"\r\n|\r|\n", " ", s)
    s = s.replace("$(", "")
    s = re.sub(r"<[^>]*>", "", s)
    s = re.sub(r"ignore previous( instructions)?", "", s, flags=re.I)
    s = re.sub(r"you are now", "", s, flags=re.I)
    s = re.sub(r"((?:^|\s)[^a-zA-Z0-9]*)system\s*:", r"\1", s, flags=re.I)
    return s[:maxlen] if len(s) > maxlen else s
