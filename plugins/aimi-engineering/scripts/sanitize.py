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

The module has two jobs, and they share a screen. The first is the prose
sanitizer above. The second is the patch matcher, `sanitize_patch_value`, which
decides whether a text an auditor proposes may be written into a story at all;
it lives here because its backtick handling is rm_sanitize's (one private helper
serves both) and because, for the fields validate-tasks screens, it must apply the
validator's own SUSPICIOUS pattern -- defined once, below, and imported by
tasks.py -- so that a patch the matcher accepts can never fail validate-tasks
afterwards. Anything beyond those two jobs is visibly out of place.

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
import unicodedata


# The prompt-injection screen, written out THREE times in the jq -- once for a
# title, once for a description, once per tasks[] entry. One constant here for
# the same reason clamp_max_concurrency is one function: three copies of a
# security rule are three chances to fix two of them.
#
# WHICH RULER THIS IS: the instruction-injection one, and only that one. None of
# the three fields it guards is ever evaluated by a shell. They are interpolated
# into PROMPTS -- get-story-context hands title, description and tasks[] to the
# story executor, and /aimi:plan threads a description into story-expander
# sub-agent prompts via phaseHandoffBlocks (grep that symbol; line numbers
# drift). An instruction marker does damage there, and so does a code fence,
# because these fields land INSIDE fenced prompt blocks and a fence in the data
# can break out of one. A command-substitution operator does neither: nothing
# here reaches a shell, so its only measured effect was refusing PROSE -- a
# tasks[] entry that merely named the operator while describing the parsing it
# was fixing. That alternative was dropped and nothing else about this changed.
#
# The split is roadmap.py's, applied rather than re-derived: read the comment
# above cv_suspicious there before widening this back. cv_injection judges both
# an identity and its description because both reach prompts, while _SHELL_CLASS
# judges the identity ALONE -- judging the description too refused "cmd_clean"
# described as "does x; then y", an identity that is itself clean. That is this
# defect with the fields renamed.
#
# The shell ruler is re-scoped, never abolished. It still applies exactly where
# a shell reads: validate_stories below keeps `.project`'s own `[\$`;|&]`
# metacharacter test and skills[]'s PATH_COMPONENT check untouched, and
# validate_path_in_project in aimi-cli.sh remains the sole authority over every
# path arriving as a CLI argument.
#
# The two surfaces that TELL an author this rule move with it -- the
# "Forbidden in tasks[]" line in commands/plan.md and the one in
# agents/workflow/aimi-story-expander.md each enumerate exactly the alternatives
# below. A reader that accepts what the writer still forbids is the
# writer-mints-what-reader-refuses shape of .aimi/known-gaps/2026-08-08-US-003.md
# running the other way, and it leaves the defect alive under its own fix.
SUSPICIOUS = (
    "ignore previous"
    "|(^|\\s)[^a-zA-Z0-9]*system\\s*:"
    "|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b"
    "|INSTRUCTIONS\\s*:"
    "|```"
)


def _unwrap_code_markup(s):
    """The three backtick rules, in rm_sanitize's order: fenced blocks are
    deleted first so their contents cannot be reinterpreted by a later rule, a
    single-backtick span unwraps to its inner text, and a stray backtick goes."""
    s = re.sub(r"```[\s\S]*?```", "", s)
    s = re.sub(r"`([^`\n]*)`", r"\1", s)
    return s.replace("`", "")


def rm_sanitize(value, maxlen):
    """Full prose sanitizer: formatting normalization AND content deletion."""
    if value is None:
        return None
    s = value
    s = _unwrap_code_markup(s)
    s = re.sub(r"\r\n|\r|\n", " ", s)
    s = s.replace("$(", "")
    s = re.sub(r"<[^>]*>", "", s)
    s = re.sub(r"ignore previous( instructions)?", "", s, flags=re.I)
    s = re.sub(r"you are now", "", s, flags=re.I)
    s = re.sub(r"((?:^|\s)[^a-zA-Z0-9]*)system\s*:", r"\1", s, flags=re.I)
    return s[:maxlen] if len(s) > maxlen else s


def rm_sanitize_report(value, maxlen):
    """Classify what rm_sanitize(value, maxlen) did, without a second copy of
    its regexes -- by calling rm_sanitize itself twice: once unclamped (at
    len(value)) to see whether the formatting/content rules touched anything,
    once at maxlen to produce the actual stored value.

    Returns (sanitized_value, changes). sanitized_value is exactly what a
    caller's own `rm_sanitize(value, maxlen)` call would have returned --
    this function computes nothing a caller could use in its place. changes
    is a list of zero or more of "rewritten"/"truncated", always in that
    order when both fire:
      "rewritten"  -- rm_sanitize(value, len(value)) != value
      "truncated"  -- len(rm_sanitize(value, len(value))) > maxlen
    Neither fires when the value passes through unchanged. A None value
    reports unchanged -- rm_sanitize(None, maxlen) is already None, and
    len(None) would raise before either rule could be judged.
    """
    if value is None:
        return None, []
    unclamped = rm_sanitize(value, len(value))
    changes = []
    if unclamped != value:
        changes.append("rewritten")
    if len(unclamped) > maxlen:
        changes.append("truncated")
    return rm_sanitize(value, maxlen), changes


# ---------------------------------------------------------------------------
# The patch matcher
# ---------------------------------------------------------------------------
#
# rm_sanitize DELETES what it dislikes and carries on; a patch is different. An
# auditor's patch is a whole replacement text, and silently deleting half of it
# would write something nobody proposed, so the matcher answers yes or no and
# leaves the stored text alone. It also refuses far less than rm_sanitize
# rewrites: only IMPERATIVE forms, the ones that read as an instruction to a
# model, and never prose that merely NAMES a word ("Instructions" in a list of
# section titles, "file system: ext4", Portuguese sentences about "sistema").

# Names, in the fixed order the narrow rules run, so the trigger reported for a
# text that trips several is deterministic. "validator-screen" is not a narrow
# rule: it is the validator's own pattern, applied last and only to the fields
# the validator screens.
PATCH_TRIGGERS = (
    "ignore-previous",
    "system-label",
    "instructions-heading",
    "instructions-label",
    "validator-screen",
)

# The fields validate-tasks screens with SUSPICIOUS. Today that is `tasks` alone
# (tasks[] entries); a field the validator never screens gets the narrow rules
# only. Without the extra step a `tasks` patch could pass the audit and then
# fail validate-tasks at merge -- "file system: ext4" is exactly such a text,
# because the validator's system pattern accepts any whitespace-preceded
# "system:".
VALIDATED_PATCH_FIELDS = ("tasks",)

# Compiled once, applied in PATCH_TRIGGERS order to the NORMALISED copy
# (normalise_for_match): NFKC-folded, format characters gone, horizontal runs
# collapsed to one space, newlines kept so `^` can mean "start of a line".
_NARROW_PATCH_PATTERNS = (
    # 'ignore previous', optionally 'all'/'any'/'the' between, at word boundaries.
    ("ignore-previous", re.compile(r"\bignore (?:(?:all|any|the) )?previous\b", re.I)),
    # A 'system' role label at the start of the text or of a line, or after a
    # sentence end, with optional punctuation before it. A letter or digit before
    # it ("file system:", "the system:") disqualifies it.
    (
        "system-label",
        re.compile(r"(?:^|\n|[.!?] )[^a-zA-Z0-9\n]*system ?:", re.I),
    ),
    # A markdown heading whose text opens with INSTRUCTIONS, at the start of a line.
    ("instructions-heading", re.compile(r"(?:^|\n)#{1,6} ?instructions\b", re.I)),
    # An UPPERCASE INSTRUCTIONS label with a colon, so the word in prose is not one.
    ("instructions-label", re.compile(r"INSTRUCTIONS ?:")),
)


def normalise_for_match(value):
    """The copy the matcher reads; the stored text never goes through this.

    NFKC folds fullwidth letters and no-break spaces onto their plain forms
    (Cyrillic homoglyphs are NOT folded and are not claimed). Horizontal
    whitespace -- tab included -- becomes a space before format and control
    characters are dropped, so a tab is never deleted into the word beside it;
    a zero-width character inside a word then disappears, and runs of spaces
    collapse to one. Newlines are the one control character kept.
    """
    s = unicodedata.normalize("NFKC", value)
    s = re.sub(r"\r\n|\r", "\n", s)
    s = re.sub(r"[^\S\n]", " ", s)
    s = "".join(c for c in s if c == "\n" or not unicodedata.category(c).startswith("C"))
    return re.sub(r" {2,}", " ", s)


def sanitize_patch_value(value, field, maxlen=5000):
    """Judge a patch text for `field`; return (clean, trigger).

    A text that trips no rule comes back as (stored, None), where stored is the
    backtick-unwrapped text with "$(" removed, cut to maxlen AFTER the match so a
    forbidden phrase past the cap is still caught. A text that trips one comes
    back as (None, name) with name from PATCH_TRIGGERS. A value that is not a
    string is the caller's schema problem and is not handled here.
    """
    full = _unwrap_code_markup(value).replace("$(", "")
    normalised = normalise_for_match(full)
    for name, pattern in _NARROW_PATCH_PATTERNS:
        if pattern.search(normalised):
            return None, name
    if field in VALIDATED_PATCH_FIELDS and re.search(SUSPICIOUS, full, re.I):
        return None, "validator-screen"
    return (full[:maxlen] if len(full) > maxlen else full), None
