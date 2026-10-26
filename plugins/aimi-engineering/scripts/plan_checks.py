"""Static plan checks: unsatisfiable-verify detectors, citation drift and
reverse references.

Pure functions only. Nothing here writes a file, spawns a process, or runs
verify text -- a verify is taken apart by tasks.py's scanners and looked at,
never handed to a shell. Module-level imports are limited to os, re and
sanitize.rm_sanitize; every tasks symbol is imported inside the function that
needs it, because tasks imports story_merge, which imports audit_patches, and a
module-level import here would couple that chain to this module.
"""

import glob
import os
import re

from sanitize import rm_sanitize

DETECTORS = (
    "pipefail-grep-q",
    "runner-summary-colour",
    "git-diff-unstaged",
    "negated-grep-no-twin",
)

SNIPPET_MAX = 120
MESSAGE_MAX = 400
_FILE_READ_MAX = 1_000_000

_GREPS = ("grep", "egrep", "fgrep")
_SUMMARY_WORD = re.compile(r"\b(passed|failed|tests?|ok)\b", re.I)
_RUNNER = re.compile(
    r"\b(pytest|jest|vitest|mocha|unittest|cargo\s+test|go\s+test|npm\s+(?:run\s+)?test"
    r"|yarn\s+test|bash\s+\S*test\S*\.sh)\b"
)
_COLOUR_GUARD = re.compile(
    r"NO_COLOR|--color(?:=|\s+)never|--colou?r=no|\\x1b|\\033|\\e\[|\\u001b", re.I
)
_COMMITISH = re.compile(r"^(HEAD|FETCH_HEAD|ORIG_HEAD|[0-9a-f]{7,40})([~^@].*)?$")


def _clip(value, maxlen=SNIPPET_MAX):
    return rm_sanitize(value, maxlen)


def _unquote(word):
    if len(word) >= 2 and word[0] == word[-1] and word[0] in ("'", '"'):
        return word[1:-1]
    return word


def _command_words(stage):
    """The stage's words with a leading `!` and VAR=value prefixes removed."""
    words = list(stage)
    while words and (words[0] == "!" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0])):
        words.pop(0)
    return words


def _grep_words(stage):
    words = _command_words(stage)
    if words and os.path.basename(_unquote(words[0])) in _GREPS:
        return words
    return None


def _has_quiet(words):
    for word in words[1:]:
        if word == "--":
            break
        if word in ("--quiet", "--silent"):
            return True
        if re.match(r"^-[A-Za-z]*q[A-Za-z]*$", word):
            return True
    return False


def _grep_operands(words):
    """Non-option operands of a grep: pattern first, then files."""
    operands = []
    skip = False
    ended = False
    for word in words[1:]:
        if skip:
            skip = False
            continue
        if not ended and word == "--":
            ended = True
            continue
        if not ended and word.startswith("-") and len(word) > 1:
            if word in ("-e", "-f", "-m", "-A", "-B", "-C"):
                skip = True
            continue
        operands.append(word)
    return operands


def _finding(detector, segment, message):
    return {
        "detector": detector,
        "segment": _clip(segment),
        "message": rm_sanitize(message, MESSAGE_MAX),
    }


def _stages(segment):
    from tasks import _verify_pipe_stages, verify_words

    return _verify_pipe_stages(verify_words(segment))


def _detect_pipefail_grep_q(segments, text):
    if "pipefail" not in text:
        return []
    from tasks import verify_words

    sets_pipefail = False
    for _sep, segment in segments:
        words = verify_words(segment)
        if words and words[0] == "set" and any("pipefail" in w for w in words):
            sets_pipefail = True
    if not sets_pipefail:
        return []
    out = []
    for _sep, segment in segments:
        for stage in _stages(segment)[1:]:
            words = _grep_words(stage)
            if words and _has_quiet(words):
                out.append(
                    _finding(
                        "pipefail-grep-q",
                        segment,
                        'under pipefail, "' + _clip(segment) + '" ends the pipe in a grep that '
                        "quits at its first match; the writer is killed by SIGPIPE and the "
                        "pipeline exits non-zero even when the pattern is found",
                    )
                )
                break
    return out


def _detect_runner_summary_colour(segments, text):
    if _COLOUR_GUARD.search(text):
        return []
    out = []
    substituted = bool(re.search(r"(\$\(|`)[^)`]*" + _RUNNER.pattern, text))
    for _sep, segment in segments:
        stages = _stages(segment)
        for index, stage in enumerate(stages):
            words = _grep_words(stage)
            if not words:
                continue
            operands = _grep_operands(words)
            if not operands or not _SUMMARY_WORD.search(_unquote(operands[0])):
                continue
            earlier = " ".join(" ".join(s) for s in stages[:index])
            if _RUNNER.search(earlier) or substituted:
                out.append(
                    _finding(
                        "runner-summary-colour",
                        segment,
                        'greps a runner summary out of "' + _clip(segment) + '" with no '
                        "NO_COLOR, --color=never or escape-strip step; a coloured summary "
                        "line splits the word and the pattern does not match",
                    )
                )
                break
    return out


def _is_commitish(word):
    word = _unquote(word)
    return bool(
        ".." in word
        or _COMMITISH.match(word)
        or word.startswith(("origin/", "upstream/", "refs/"))
    )


def _detect_git_diff_unstaged(segments, text):
    out = []
    for _sep, segment in segments:
        for stage in _stages(segment):
            words = _command_words(stage)
            if len(words) < 2 or os.path.basename(_unquote(words[0])) != "git":
                continue
            rest = words[1:]
            while rest and rest[0].startswith("-"):
                rest = rest[2:] if rest[0] in ("-C", "-c") else rest[1:]
            if not rest or rest[0] != "diff":
                continue
            args = rest[1:]
            if any(a in ("--cached", "--staged") for a in args):
                continue
            if any(_is_commitish(a) for a in args if not a.startswith("-")):
                continue
            out.append(
                _finding(
                    "git-diff-unstaged",
                    segment,
                    'runs "' + _clip(segment) + '" with no --cached and no ref range; after '
                    "the story commits, the working tree matches HEAD and the diff is empty",
                )
            )
            break
    return out


def _detect_negated_grep_no_twin(segments, text):
    positive_targets = set()
    negated = []
    for _sep, segment in segments:
        stages = _stages(segment)
        is_negated = bool(stages and stages[0] and stages[0][0] == "!")
        stage_words = _grep_words(stages[0]) if stages and stages[0] else None
        if stage_words is None:
            continue
        operands = _grep_operands(stage_words)
        target = _unquote(operands[-1]) if len(operands) >= 2 else None
        if is_negated:
            negated.append((segment, target))
        else:
            positive_targets.add(target)
    out = []
    for segment, target in negated:
        if target in positive_targets:
            continue
        out.append(
            _finding(
                "negated-grep-no-twin",
                segment,
                'asserts absence with "' + _clip(segment) + '" and nothing in the verify '
                "greps the same target positively, so a missing or renamed file passes it",
            )
        )
    return out


_DETECTOR_FUNCS = {
    "pipefail-grep-q": _detect_pipefail_grep_q,
    "runner-summary-colour": _detect_runner_summary_colour,
    "git-diff-unstaged": _detect_git_diff_unstaged,
    "negated-grep-no-twin": _detect_negated_grep_no_twin,
}


def verify_static_findings(text, detectors=None):
    """Findings for a verify text that cannot hold as written.

    Each finding is a dict with `detector`, `segment` and `message`. `detectors`
    is an optional subset of DETECTORS; an unknown name raises ValueError.
    Non-string, empty and unterminated text return [].
    """
    selected = DETECTORS if detectors is None else tuple(detectors)
    for name in selected:
        if name not in _DETECTOR_FUNCS:
            raise ValueError("unknown detector: " + repr(name))
    if not isinstance(text, str) or not text.strip():
        return []
    from tasks import verify_segments, verify_unterminated

    if verify_unterminated(text) is not None:
        return []
    segments = verify_segments(text)
    findings = []
    for name in DETECTORS:
        if name in selected:
            findings.extend(_DETECTOR_FUNCS[name](segments, text))
    return findings


# ---------------------------------------------------------------------------
# citation drift
# ---------------------------------------------------------------------------

_SENTENCE_SPLIT = re.compile(r"(?<=[.!?;])\s+")
_IDENT = r"[A-Za-z_][A-Za-z0-9_]*"


def _sentence_of(text, anchor):
    for sentence in _SENTENCE_SPLIT.split(text):
        if anchor in sentence:
            return sentence
    return text


def _symbol_for(sentence, anchor):
    for token in re.findall(r"`([^`]+)`", sentence):
        token = token.strip()
        if not token or token == anchor or re.search(r"\.[A-Za-z]+:[0-9]+$", token):
            continue
        token = re.sub(r"\(.*\)$", "", token)
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", token):
            return token.split(".")[-1] if "." in token and "/" not in token else token
    after = sentence.split(anchor, 1)[1] if anchor in sentence else ""
    match = re.match(r"[\s:,(\-]*(" + _IDENT + r")(\()?", after)
    if match:
        name = match.group(1)
        if "_" in name or match.group(2) or re.match(r"^[A-Z][a-z]+[A-Z]", name):
            return name
    return None


def _confined(path, base_dir):
    if not isinstance(path, str) or not path or os.path.isabs(path):
        return None
    if ".." in path.replace("\\", "/").split("/"):
        return None
    root = os.path.realpath(base_dir)
    real = os.path.realpath(os.path.join(root, path))
    if real != root and not real.startswith(root + os.sep):
        return None
    return real


def citation_drift(text, base_dir):
    """One finding per `path:line` citation that names a symbol and has
    drifted, cannot be checked, or is refused. A citation whose line still
    holds the symbol produces nothing.

    Finding keys: `citation`, `kind` (drift | unverifiable | refused), `message`,
    and for a drift with exactly one current holder `current_line`.
    """
    from tasks import _line_anchors

    if not isinstance(text, str):
        return []
    findings = []
    for anchor in _line_anchors(text):
        path, _, line_text = anchor.rpartition(":")
        line_no = int(line_text)
        symbol = _symbol_for(_sentence_of(text, anchor), anchor)

        def make(kind, message, **extra):
            item = {"citation": _clip(anchor), "kind": kind, "message": rm_sanitize(message, MESSAGE_MAX)}
            item.update(extra)
            return item

        real = _confined(path, base_dir)
        if real is None:
            findings.append(make("refused", 'citation "' + _clip(anchor) + '" is outside the project root and was not opened'))
            continue
        if symbol is None:
            findings.append(make("unverifiable", 'citation "' + _clip(anchor) + '" names no symbol to check'))
            continue
        if not os.path.isfile(real):
            findings.append(make("unverifiable", 'citation "' + _clip(anchor) + '" names a file that does not exist'))
            continue
        try:
            with open(real, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.read(_FILE_READ_MAX).split("\n")
        except OSError:
            findings.append(make("unverifiable", 'citation "' + _clip(anchor) + '" names a file that cannot be read'))
            continue
        if 1 <= line_no <= len(lines) and symbol in lines[line_no - 1]:
            continue
        holders = [i + 1 for i, row in enumerate(lines) if symbol in row]
        if len(holders) == 1:
            findings.append(
                make(
                    "drift",
                    'citation "' + _clip(anchor) + '" no longer holds "' + _clip(symbol)
                    + '"; it is now on line ' + str(holders[0]),
                    current_line=holders[0],
                )
            )
        else:
            findings.append(
                make("drift", 'citation "' + _clip(anchor) + '" no longer holds "' + _clip(symbol) + '"')
            )
    return findings


# ---------------------------------------------------------------------------
# reverse references
# ---------------------------------------------------------------------------


def reverse_references(story, project_root, target_globs, maximum=3):
    """Project-relative paths of files in the target class that mention a
    literal the story names (its implementation.files and their basenames)
    and that the story does not itself list. Fixed-string match only."""
    if not isinstance(story, dict) or not isinstance(project_root, str) or not project_root:
        return []
    if not os.path.isdir(project_root) or not target_globs:
        return []
    impl = story.get("implementation")
    files = impl.get("files") if isinstance(impl, dict) else None
    if not isinstance(files, list):
        return []
    listed = {os.path.normpath(f) for f in files if isinstance(f, str) and f}
    literals = set()
    for entry in files:
        if isinstance(entry, str) and entry:
            literals.add(entry)
            literals.add(os.path.basename(entry))
    literals.discard("")
    if not literals:
        return []
    root = os.path.realpath(project_root)
    found = []
    for pattern in target_globs:
        if not isinstance(pattern, str) or not pattern or os.path.isabs(pattern):
            continue
        if ".." in pattern.replace("\\", "/").split("/"):
            continue
        for hit in sorted(glob.glob(os.path.join(root, pattern), recursive=True)):
            real = os.path.realpath(hit)
            if not real.startswith(root + os.sep) or not os.path.isfile(real):
                continue
            rel = os.path.relpath(real, root).replace(os.sep, "/")
            if os.path.normpath(rel) in listed or rel in found:
                continue
            try:
                with open(real, "r", encoding="utf-8", errors="replace") as handle:
                    body = handle.read(_FILE_READ_MAX)
            except OSError:
                continue
            if any(lit in body for lit in literals):
                found.append(rel)
    found.sort()
    return found[: max(0, int(maximum))]
