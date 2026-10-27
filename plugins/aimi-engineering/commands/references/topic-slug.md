# Topic Slug Derivation

Shared reference for deriving a URL-safe slug from a feature description.
Apply these five steps wherever the command says "derive a topic slug."

## Algorithm

Given a feature description string:

1. Convert to lowercase
2. Replace spaces and special characters with hyphens
3. Remove consecutive hyphens
4. Truncate to 50 characters
5. Remove trailing hyphens

The result is the topic slug used in research output paths, brainstorm
filenames, prototype paths, and any other artefact that embeds the topic.

## Deterministic form: `slugify`

`$AIMI_CLI slugify --stdin` (text on stdin) or `$AIMI_CLI slugify "<text>"` is the
deterministic form of the derivation above, for a caller that names a
directory after the result and cannot afford a slug that differs from run to
run. It works from any directory and takes no lock.

- **ASCII transliteration.** The text is decomposed (NFKD) and only its ASCII
  characters are kept, so `Café Résumé Über` gives `cafe-resume-uber`. The five
  steps then apply as written: lowercase, runs of non-alphanumerics become one
  hyphen, truncate to 50, remove trailing hyphens (the ends are trimmed before
  the cut as well, so a leading separator never survives).
- **The NFKD-only limit.** A letter with no NFKD decomposition is dropped, not
  transliterated: o-slash, sharp s and ae vanish, so `Søren Straße Ærø` gives
  `sren-strae-r`. There is no table that maps them to `o`, `ss` or `ae`.
- **An empty result is refused.** Text with no ASCII letter or digit left after
  the fold (a title in a non-Latin script, punctuation alone, nothing at all)
  exits 1 with a message on stderr and prints nothing. The verb never makes up
  a fallback name; the caller stops, or asks for a description it can slug.

The five steps remain the definition wherever a command derives a slug in
prose. Directories already created under an earlier derivation keep their
names; nothing renames them.
