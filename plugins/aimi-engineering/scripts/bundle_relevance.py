#!/usr/bin/env python3
"""bundle_relevance: keep only the scan-tier design bundles that relate to a feature.

WHAT THIS MODULE IS FOR
=======================

`detect-design-bundle` elects a bundle by scanning for README markers. A stray
or placeholder bundle left in the tree (a throwaway fixture directory, an old
import of another feature) carries the same marker as the real one, so it
either became the plan's design bundle or tied with the right one and forced a
refusal. Given the feature description, this module drops the scan-tier
candidates that share no word with it.

THE RULE
========

A candidate is relevant when the description and the candidate have at least
one token in common. The candidate's tokens come from two places: its directory
name, and the title of its BusinessSpec -- the first H1 of the file named
`businessspec.md` (any case) directly under `<bundle>/project/`.

Tokens are `ascii_fold` (scripts/slug.py: NFKD, ASCII only, lowercase) of the
text, cut into runs of [a-z0-9], at least 3 characters long, minus English and
Portuguese stop-words and a short list of generic app words. Folding first is
what lets an accented description match an unaccented directory name. The
description is capped at 2000 characters, counted on the text as received and
before folding.

A description with no token left (empty, whitespace, or only stop-words) cannot
say what is relevant, so the filter turns itself OFF: every candidate is
relevant and `active` is false. Silence about relevance never discards a bundle.

THE VERB
========

    bundle_relevance.py [--] <dir>...     the description on stdin, UTF-8

Candidate directories arrive as argv and the description only on stdin, so free
text never reaches a shell or a process listing. Prints one JSON object

    {"active": <bool>, "relevant": [<dir>...], "filtered": [<dir>...]}

with both lists in argv order and every directory spelled as it was given, and
exits 0. An unknown flag is refused on stderr with exit 1.

This module imports only the standard library and `ascii_fold` from slug.py.
"""

import json
import os
import re
import sys

from slug import ascii_fold

MAX_DESCRIPTION_CHARS = 2000
MIN_TOKEN_LENGTH = 3

_TOKEN_RUN = re.compile(r"[a-z0-9]+")
_H1 = re.compile(r"^#[ \t]+(\S.*)$")

_ENGLISH_STOP_WORDS = """
the and for are but not you all any can had her was one our out has have him his
how its may new now old see two way who did get let put say she too use that
this with from they will would there their what about which when your said each
them then than these those into over also been being were while where whose
does doing done just only some such very more most much many other another
should could might must shall onto upon within without between through during
before after above below under again further once here both few own same
""".split()

_PORTUGUESE_STOP_WORDS = """
que com para por uma uns umas dos das nos nas num numa pelo pela pelos pelas
como mais mas foi sao ser tem tinha entre sobre ate sua suas seu seus ele ela
eles elas isso esse essa esses essas este esta estes estas aquele aquela nao
sim ja muito muita muitos muitas quando onde qual quais quem cada todo toda
todos todas outro outra outros outras mesmo mesma depois antes ainda tambem
sem sob apos desde durante contra
""".split()

# Words that describe the work or the medium rather than the product, so two
# unrelated bundles would share them. Kept short on purpose: a word listed here
# can never make a bundle relevant, and a relevant bundle dropped is worse than
# an irrelevant one kept.
_GENERIC_APP_WORDS = """
app apps application applications page pages screen screens feature features
project projects add adding update create implement improve build make fix
support system tool version ui ux spec design bundle handoff claude aimi plan
task tasks
""".split()

STOP_WORDS = frozenset(
    _ENGLISH_STOP_WORDS + _PORTUGUESE_STOP_WORDS + _GENERIC_APP_WORDS
)


def tokens(text):
    """The set of relevance tokens in `text`."""
    return {
        token
        for token in _TOKEN_RUN.findall(ascii_fold(text))
        if len(token) >= MIN_TOKEN_LENGTH and token not in STOP_WORDS
    }


def description_tokens(description):
    """Tokens of a description, after the 2000-character cap."""
    return tokens(description[:MAX_DESCRIPTION_CHARS])


def _business_spec_path(bundle_dir):
    project = os.path.join(bundle_dir, "project")
    try:
        names = sorted(os.listdir(project))
    except OSError:
        return None
    for name in names:
        full = os.path.join(project, name)
        if name.lower() == "businessspec.md" and os.path.isfile(full):
            return full
    return None


def business_spec_title(bundle_dir):
    """The first H1 of the bundle's BusinessSpec, or "" when there is none.

    Lines inside a fenced code block are not headings, so a `# comment` in a
    shell sample is never mistaken for the title.
    """
    path = _business_spec_path(bundle_dir)
    if path is None:
        return ""
    try:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return ""
    fenced = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = _H1.match(line.rstrip())
        if match:
            return match.group(1)
    return ""


def bundle_tokens(bundle_dir):
    """Tokens of a bundle: its directory name plus its BusinessSpec title."""
    name = os.path.basename(bundle_dir.rstrip("/"))
    return tokens(name) | tokens(business_spec_title(bundle_dir))


def bundle_relevance_filter(description, bundle_dirs):
    """Split `bundle_dirs` into (active, relevant, filtered) for a description."""
    wanted = description_tokens(description)
    if not wanted:
        return False, list(bundle_dirs), []
    relevant = []
    filtered = []
    for bundle_dir in bundle_dirs:
        if wanted & bundle_tokens(bundle_dir):
            relevant.append(bundle_dir)
        else:
            filtered.append(bundle_dir)
    return True, relevant, filtered


def main(argv):
    dirs = []
    flags_over = False
    for arg in argv:
        if not flags_over and arg == "--":
            flags_over = True
        elif not flags_over and arg.startswith("--"):
            sys.stderr.write(
                "Error: bundle_relevance: unknown flag: " + arg
                + " (usage: bundle_relevance.py [--] <dir>... with the description on stdin)\n"
            )
            return 1
        else:
            dirs.append(arg)

    description = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    active, relevant, filtered = bundle_relevance_filter(description, dirs)
    sys.stdout.write(
        json.dumps({"active": active, "relevant": relevant, "filtered": filtered})
        + "\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
