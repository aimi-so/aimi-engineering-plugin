#!/usr/bin/env python3
"""slugify: derive an ASCII directory slug from free text.

WHAT THIS MODULE IS FOR
=======================

`commands/references/topic-slug.md` describes how a feature description becomes
a URL-safe slug. Done as a `tr | sed | cut` pipeline in a command body, the
derivation silently dropped every accented letter and turned a title written in
a non-Latin script into an empty directory name. This module is the
deterministic form: accents fold to their ASCII base letter, and text with no
ASCII letter or digit at all is refused rather than given a made-up name.

THE FOLD
========

`ascii_fold(text)` is NFKD, keep the ASCII characters, lowercase -- and nothing
else. NFKD splits an accented letter into its base letter plus a combining mark,
and the encode-ignore step then drops the mark. A character with no NFKD
decomposition (o-slash, sharp s, ae) has no ASCII form to fall back to and is
dropped outright, so `Soren` spelled with o-slash slugs as `sren`. That limit is
deliberate: a transliteration table would be a second rule to keep in step with
the first, and the verb's callers get an honest refusal when nothing survives.

`slugify(text)` is built on `ascii_fold`: each run of characters outside
[a-z0-9] becomes one hyphen, both ends are trimmed of hyphens, the result is cut
to 50 characters, and the cut is trimmed again so it never ends on a hyphen.

THE VERB
========

    slug.py [--] <text>      the text as one argument
    slug.py --stdin          the text on stdin, decoded as UTF-8 with replacement

Free text never reaches a shell: it arrives as argv or stdin bytes and is only
ever handed to the functions above. Prints the slug and exits 0. A missing text
source, an unknown flag, `--stdin` together with another argument, or a result
with no letter or digit is refused on stderr with exit 1 and nothing on stdout.

This module imports only the standard library; in particular it loads none of
tasks, story_merge or audit_patches, so a later caller can import `ascii_fold`
without paying for them.
"""

import re
import sys
import unicodedata

MAX_SLUG_LENGTH = 50

_NON_SLUG_RUN = re.compile(r"[^a-z0-9]+")


def ascii_fold(text):
    """NFKD, ASCII characters only, lowercase. Nothing else is touched."""
    decomposed = unicodedata.normalize("NFKD", text)
    return decomposed.encode("ascii", "ignore").decode("ascii").lower()


def slugify(text):
    """The slug for `text`, or "" when it holds no ASCII letter or digit."""
    folded = ascii_fold(text)
    slug = _NON_SLUG_RUN.sub("-", folded).strip("-")
    return slug[:MAX_SLUG_LENGTH].strip("-")


def _refuse(message):
    sys.stderr.write("Error: slugify: " + message + "\n")
    return 1


def main(argv):
    usage = "usage: aimi-cli.sh slugify <text> | slugify --stdin"
    use_stdin = False
    texts = []
    flags_over = False
    for arg in argv:
        if not flags_over and arg == "--":
            flags_over = True
        elif not flags_over and arg == "--stdin":
            use_stdin = True
        elif not flags_over and arg.startswith("--"):
            return _refuse("unknown flag: " + arg + " (" + usage + ")")
        else:
            texts.append(arg)

    if use_stdin and (texts or flags_over):
        return _refuse("--stdin takes no other argument (" + usage + ")")
    if len(texts) > 1:
        return _refuse("exactly one text argument is accepted (" + usage + ")")
    if not use_stdin and not texts:
        return _refuse("a text argument or --stdin is required (" + usage + ")")

    if use_stdin:
        text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    else:
        text = texts[0]

    slug = slugify(text)
    if not slug:
        return _refuse("no ASCII letter or digit to build a slug from")
    sys.stdout.write(slug + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
