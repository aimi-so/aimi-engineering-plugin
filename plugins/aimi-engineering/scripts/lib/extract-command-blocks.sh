# extract-command-blocks.sh - the one block-extraction mechanism, shared.
#
# WHY THIS IS ITS OWN FILE
#
# test-command-blocks.sh needs to pull every ```bash fence out of the corpus
# below to run its static checks. capture-command-block-jq.sh needs the exact same
# blocks, addressed the exact same way, to find the jq invocations inside them.
# aimi-cli.sh's measure-command-file verb needs those same fence boundaries a
# third time, to say how many of a markdown file's bytes are prose and how many
# are fenced code. Forking a second extractor for any one caller is how the
# definitions drift apart — one gets a fix the others don't, and nobody notices
# until a block one of them sees and another doesn't causes a false negative.
# The third caller's hand-rolled predecessor is the worked example: an awk
# written on the spot for a roadmap measurement, anchored at the start of the
# line, never matched an INDENTED fence and reported 45 bash blocks in plan.md
# where there were 50. This file is sourced by all three, so there is exactly
# one extract_blocks to maintain.
#
# THE CORPUS
#
# command_block_files() is the single definition of what this analysis covers:
# every commands/**/*.md, plus every skills/**/SKILL.md. The second half was
# added because a SKILL.md is executed exactly the way a command file is -- an
# agent runs its ```bash fences literally -- while the find here was anchored
# at $COMMANDS_DIR alone, so skills/ was reached by no static analysis at all.
# The one net this repo has had a hole in it the shape of every skill.
#
# Only SKILL.md is taken from skills/, never its references/*.md. A skill's
# SKILL.md is the file the host loads and runs; the reference files beside it
# are read on demand as prose, the same relationship commands/ does NOT have
# with commands/references/ (install.sh copies those verbatim into command
# bodies' reach, which is why they are in scope there and not here).
#
# Two roots, two relpath rules, one index. A commands file is reported
# relative to $COMMANDS_DIR -- `plan.md`, `references/forge-contract.md` --
# exactly as it always was, so no baseline key moved. A skills file is
# reported relative to the plugin directory, so it arrives already prefixed:
# `skills/story-executor/SKILL.md`. The prefix is what keeps the two halves
# distinguishable in a shared baseline without a fourth column saying which
# root a line came from.
#
# ADDRESSING (unchanged from the sole prior definition)
#
# Blocks are addressed by their enclosing markdown heading, never by a marker
# inside the file. install.sh's translate_command_body() rewrites command
# bodies for OpenCode by pure string substitution and never parses fences, so
# any annotation added to a fence info-string or an HTML comment would flow
# verbatim into the installed OpenCode command files.
#
# A closing fence must carry no info string (CommonMark) and must not be
# indented deeper than its opener. Both rules are load-bearing: execute.md
# nests ```bash fences inside a plain pseudo-code fence, and a naive open/close
# toggle desynchronises there and starts extracting pseudo-code as bash.
#
# CONTRACT WITH THE CALLER
#
# extract_blocks() has three forms. They run the same awk over the same rules;
# only which files it reads and where the answer goes differ.
#
#   extract_blocks                       (the directory form, unchanged)
#     Reads $COMMANDS_DIR and $WORK_DIR, writes one file per bash block under
#     $BLOCKS_DIR (named "<4-digit-id>.sh", created if missing), and writes
#     $INDEX as a TSV of `id \t relpath \t startline \t heading`. All four
#     variables are globals the caller must set before calling; this file
#     defines no defaults for them, on purpose, so a caller that forgets one
#     fails loudly on an empty path rather than silently writing into the
#     wrong place. $SKILLS_DIR is the one addition and it is optional twice
#     over: left UNSET it is derived as $COMMANDS_DIR/../skills, and set to
#     the EMPTY STRING it turns the skills half of the corpus off. The two
#     are told apart with ${SKILLS_DIR+set}, not ${SKILLS_DIR:-}, so "off"
#     is a thing a caller can actually say.
#
#   extract_blocks                       (the corpus form)
#     The same no-argument call with NONE of $BLOCKS_DIR, $WORK_DIR and
#     $INDEX set. Discovers the corpus the same way the directory form does
#     -- from $COMMANDS_DIR when set, otherwise from this file's own location
#     -- and streams the listing form's TSV to stdout instead. It answers
#     "what does the static analysis actually cover?", which had no answer
#     before skills/ joined the corpus and became a question worth asking.
#
#     This does NOT weaken the no-defaults rule above. That rule is about a
#     caller who forgets one of the three write targets and silently writes
#     into the wrong place; forgetting one still fails exactly as loudly,
#     because the corpus form requires all three to be absent. With all three
#     absent there is no place the caller could have meant, and this form
#     writes nothing anywhere -- no block files, no index, no scratch awk --
#     so the hazard the rule guards against cannot arise in it.
#
#   extract_blocks FILE...               (the listing form)
#     Writes nothing anywhere — no block files, no index, no temporary awk
#     program — and streams a TSV report over the given files to stdout:
#
#       BLOCK \t id \t relpath \t startline \t heading
#         One per bash block, in file order, carrying the same four fields the
#         directory form writes to $INDEX. Counting these lines and reading
#         SUMMARY's bash_fences field are the same measurement by construction:
#         one `nblk++` produces both.
#
#       SUMMARY bytes lines prose_bytes fence_bytes bash_fence_bytes
#               fences bash_fences last_line_in_fence last_line_in_bash_fence
#         One line, last, totalled over every FILE given. Nine integers
#         separated by single spaces — NOT tabs, and the difference is a rule
#         rather than a taste. A BLOCK line carries a markdown heading, which
#         is free text that can hold a space, so it needs a delimiter that text
#         cannot contain and uses the same tab $INDEX does. Every SUMMARY field
#         is a number, so a plain `read` splitting on default whitespace is
#         enough, and the caller never has to reassign IFS to take it apart.
#
#         `fences` counts TOP-LEVEL fences only — a fence opened inside another
#         fence is content of the outer one, the same rule that keeps a ```bash
#         nested in a pseudo-code fence out of the extracted blocks — and
#         `bash_fences` is the subset of those whose info string is exactly
#         `bash`. `fence_bytes` spans each top-level fence from its opening
#         line through its closing line inclusive, `bash_fence_bytes` is that
#         same span for the bash subset, and `prose_bytes` is everything else,
#         so prose_bytes + fence_bytes == bytes.
#
#         A line costs its own length plus one for the newline awk stripped, so
#         a file whose final line carries no newline measures one byte over.
#         The two trailing flags say which bucket that last line landed in, so
#         a caller holding the file's real size can put the difference back
#         where it belongs rather than breaking the partition.
#
#     $COMMANDS_DIR is honoured if set (relpaths are reported relative to it)
#     and simply not needed if it is not; the other three globals are untouched.
#     This form never discovers anything -- it reads exactly the files named --
#     so a caller measuring one SKILL.md passes its path and gets its blocks.

# The awk program, written down once. The directory form spills it to
# $WORK_DIR/extract.awk and passes it with -f, exactly as it always did; the
# listing form passes the same text as awk's program operand so it can run
# without a scratch directory. Neither has its own copy of these rules.
_command_blocks_awk() {
  cat <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
BEGIN {
  nblk = 0; nfence = 0
  bytes = 0; lines = 0; fencebytes = 0; bashfencebytes = 0
  lastfence = 0; lastbash = 0
}
FNR == 1 {
  infence = 0; isbash = 0; heading = "(preamble)"; delete hseen
  # Two roots, tried in order, each matched as a literal ANCHORED prefix --
  # never sub()'s "first occurrence anywhere, pattern read as a regex". ROOT
  # is the commands root and yields `plan.md`; ROOT2 is the plugin directory
  # and yields `skills/story-executor/SKILL.md`, prefix included.
  rel = FILENAME
  if (ROOT != "" && substr(rel, 1, length(ROOT) + 1) == ROOT "/") {
    rel = substr(rel, length(ROOT) + 2)
  } else if (ROOT2 != "" && substr(rel, 1, length(ROOT2) + 1) == ROOT2 "/") {
    rel = substr(rel, length(ROOT2) + 2)
  }
}
{
  # The newline awk stripped is this line's, so charge it here. LC_ALL=C on the
  # listing invocation is what makes length() count bytes and not characters —
  # a heading with one accented word would otherwise measure short.
  linebytes = length($0) + 1
  bytes += linebytes
  lines++
  lastfence = 0; lastbash = 0

  probe = $0; sub(/^[ \t]+/, "", probe)
  if (probe ~ /^```/) {
    ind = match($0, /[^ \t]/) - 1
    info = probe; sub(/^`+/, "", info); info = trim(info)
    if (infence == 0) {
      infence = 1; openind = ind; isbash = (info == "bash"); nfence++
      fencebytes += linebytes; lastfence = 1
      if (isbash) {
        bashfencebytes += linebytes; lastbash = 1
        nblk++; id = sprintf("%04d", nblk); hseen[heading]++
        if (LIST) {
          printf "BLOCK\t%s\t%s\t%d\t%s (block %d)\n", id, rel, FNR + 1, heading, hseen[heading]
        } else {
          outf = OUTDIR "/" id ".sh"
          printf "%s\t%s\t%d\t%s (block %d)\n", id, rel, FNR + 1, heading, hseen[heading]
          printf "" > outf
        }
      }
      next
    }
    if (info == "" && ind <= openind) {
      fencebytes += linebytes; lastfence = 1
      if (isbash) { bashfencebytes += linebytes; lastbash = 1; if (!LIST) close(outf) }
      infence = 0; isbash = 0; next
    }
  }
  if (infence == 1) {
    fencebytes += linebytes; lastfence = 1
    if (isbash) { bashfencebytes += linebytes; lastbash = 1; if (!LIST) print $0 >> outf }
    next
  }
  if (probe ~ /^#{1,6}[ \t]/) { h = probe; sub(/^#+[ \t]*/, "", h); heading = trim(h) }
}
END {
  if (infence == 1) printf "warning: unclosed fence in %s\n", rel > "/dev/stderr"
  if (LIST) {
    printf "SUMMARY %d %d %d %d %d %d %d %d %d\n", \
      bytes, lines, bytes - fencebytes, fencebytes, bashfencebytes, \
      nfence, nblk, lastfence, lastbash
  }
}
AWK
}

# The listing form's body, split out so the directory form below stays the
# short, unchanged thing it was.
# The two roots come from _command_blocks_resolve_roots when a corpus call
# already ran, and from $COMMANDS_DIR alone when this is the bare FILE... form
# (aimi-cli.sh's measure-command-file), where nothing is discovered and the
# relpath rule is exactly what it always was.
_list_command_blocks() {
  LC_ALL=C awk -v OUTDIR="" \
    -v ROOT="${_CB_COMMANDS_ROOT:-${COMMANDS_DIR:-}}" \
    -v ROOT2="${_CB_PLUGIN_ROOT:-}" -v LIST=1 \
    "$(_command_blocks_awk)" "$@"
}

# The plugin directory this library ships inside: scripts/lib -> scripts -> .
# Used only when the caller set no $COMMANDS_DIR at all, so that the corpus
# form can answer without being told where the tree is.
_command_blocks_plugin_root() {
  local libdir
  libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  (cd "$libdir/../.." && pwd)
}

# The corpus, written down once so no caller can carry a second definition of
# what "the files this analysis covers" means. Sorted as one list rather than
# two concatenated ones; `commands` sorts before `skills` under a shared
# parent, so every command block keeps the id it had before skills/ arrived.
command_block_files() {
  local commands_root="$1" skills_root="$2"
  {
    [ -n "$commands_root" ] && [ -d "$commands_root" ] && find "$commands_root" -name '*.md'
    [ -n "$skills_root" ] && [ -d "$skills_root" ] && find "$skills_root" -name 'SKILL.md'
  } 2>/dev/null | sort
}

# Resolves the two corpus roots and the plugin root the skills relpaths are
# reported against, into _CB_COMMANDS_ROOT / _CB_SKILLS_ROOT / _CB_PLUGIN_ROOT.
# ${SKILLS_DIR+set} rather than ${SKILLS_DIR:-}: an explicitly EMPTY $SKILLS_DIR
# means "do not scan skills", which is a different answer from "not told".
_command_blocks_resolve_roots() {
  _CB_COMMANDS_ROOT="${COMMANDS_DIR:-}"
  if [ -n "$_CB_COMMANDS_ROOT" ]; then
    _CB_PLUGIN_ROOT="$(cd "$_CB_COMMANDS_ROOT/.." && pwd)" || return 1
  else
    _CB_PLUGIN_ROOT="$(_command_blocks_plugin_root)" || return 1
    _CB_COMMANDS_ROOT="$_CB_PLUGIN_ROOT/commands"
  fi

  if [ -n "${SKILLS_DIR+set}" ]; then
    _CB_SKILLS_ROOT="$SKILLS_DIR"
  else
    _CB_SKILLS_ROOT="$_CB_PLUGIN_ROOT/skills"
  fi
}

extract_blocks() {
  if [ "$#" -gt 0 ]; then
    _list_command_blocks "$@"
    return
  fi

  _command_blocks_resolve_roots || return 1

  # The corpus form: no write target named at all, so stream instead. See the
  # CONTRACT block above for why this does not soften the no-defaults rule.
  if [ -z "${BLOCKS_DIR:-}" ] && [ -z "${WORK_DIR:-}" ] && [ -z "${INDEX:-}" ]; then
    # shellcheck disable=SC2046
    _list_command_blocks $(command_block_files "$_CB_COMMANDS_ROOT" "$_CB_SKILLS_ROOT")
    return
  fi

  mkdir -p "$BLOCKS_DIR"
  _command_blocks_awk > "$WORK_DIR/extract.awk"

  # shellcheck disable=SC2046
  awk -v OUTDIR="$BLOCKS_DIR" -v ROOT="$_CB_COMMANDS_ROOT" -v ROOT2="$_CB_PLUGIN_ROOT" -v LIST=0 \
    -f "$WORK_DIR/extract.awk" \
    $(command_block_files "$_CB_COMMANDS_ROOT" "$_CB_SKILLS_ROOT") > "$INDEX"
}
