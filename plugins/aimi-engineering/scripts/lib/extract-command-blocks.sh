# extract-command-blocks.sh - the one block-extraction mechanism, shared.
#
# WHY THIS IS ITS OWN FILE
#
# test-command-blocks.sh needs to pull every ```bash fence out of commands/**/*.md
# to run its static checks. capture-command-block-jq.sh needs the exact same
# blocks, addressed the exact same way, to find the jq invocations inside them.
# Forking a second extractor for the second caller is how the two definitions
# drift apart — one gets a fix the other doesn't, and nobody notices until a
# block one of them sees and the other doesn't causes a false negative. This
# file is sourced by both, so there is exactly one extract_blocks to maintain.
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
# extract_blocks() reads $COMMANDS_DIR and $WORK_DIR, writes one file per bash
# block under $BLOCKS_DIR (named "<4-digit-id>.sh", created if missing), and
# writes $INDEX as a TSV of `id \t relpath \t startline \t heading`. All four
# variables are globals the caller must set before calling; this file defines
# no defaults for them, on purpose, so a caller that forgets one fails loudly
# on an empty path rather than silently writing into the wrong place.
extract_blocks() {
  mkdir -p "$BLOCKS_DIR"
  cat > "$WORK_DIR/extract.awk" <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
BEGIN { nblk = 0 }
FNR == 1 {
  infence = 0; isbash = 0; heading = "(preamble)"; delete hseen
  rel = FILENAME; sub(ROOT "/", "", rel)
}
{
  probe = $0; sub(/^[ \t]+/, "", probe)
  if (probe ~ /^```/) {
    ind = match($0, /[^ \t]/) - 1
    info = probe; sub(/^`+/, "", info); info = trim(info)
    if (infence == 0) {
      infence = 1; openind = ind; isbash = (info == "bash")
      if (isbash) {
        nblk++; id = sprintf("%04d", nblk); hseen[heading]++
        outf = OUTDIR "/" id ".sh"
        printf "%s\t%s\t%d\t%s (block %d)\n", id, rel, FNR + 1, heading, hseen[heading]
        printf "" > outf
      }
      next
    }
    if (info == "" && ind <= openind) {
      infence = 0; if (isbash) close(outf); isbash = 0; next
    }
  }
  if (infence == 1) { if (isbash) print $0 >> outf; next }
  if (probe ~ /^#{1,6}[ \t]/) { h = probe; sub(/^#+[ \t]*/, "", h); heading = trim(h) }
}
END { if (infence == 1) printf "warning: unclosed fence in %s\n", rel > "/dev/stderr" }
AWK

  # shellcheck disable=SC2046
  awk -v OUTDIR="$BLOCKS_DIR" -v ROOT="$COMMANDS_DIR" -f "$WORK_DIR/extract.awk" \
    $(find "$COMMANDS_DIR" -name '*.md' | sort) > "$INDEX"
}
