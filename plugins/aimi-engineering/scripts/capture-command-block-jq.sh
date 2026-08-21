#!/usr/bin/env bash
set -uo pipefail

# capture-command-block-jq.sh - records what the 38-ish jq sites in commands/
# answer today, before story 02-04 replace any of them with a CLI verb call.
#
# WHY THIS EXISTS
#
# commands/*.md are executed, not read: an agent runs their bash-fenced blocks
# literally, each in its own isolated shell. A handful of those blocks read
# tasks.json with jq directly, and stories 02-04 mean to replace each one with
# a call to a CLI verb that already exists (in Python) or is about to. Before
# any of that happens, this script proves what the jq itself answers, over an
# adversarial corpus of tasks.json shapes, the same way golden_from_jq.json's
# other blocks proved a Python port faithful before the jq it replaced was
# deleted. There is no port here -- these sites live in commands/, never in
# aimi-cli.sh -- but the evidentiary shape is the same: capture first, replace
# second, never regenerate the capture from the replacement.
#
# HOW IT SHARES THE EXTRACTOR
#
# The block extraction is lib/extract-command-blocks.sh's extract_blocks(),
# the SAME function test-command-blocks.sh uses, sourced rather than
# reimplemented, so the two can never see a different set of blocks. See that
# file for the addressing rule (heading-keyed, never marker-keyed) and why it
# matters for install.sh's OpenCode translation.
#
# Everything past extraction -- finding the jq invocations that open a file,
# building the adversarial fixture corpus, executing each site against it in
# a shell that reproduces the agent's own (no set -euo pipefail), and
# recording the result -- is scripts/tests/capture_command_block_jq.py, which
# this wrapper just shells out to. JSON emission belongs in Python for the
# same reason story_merge.py and tasks.py's document logic does: correct
# escaping, not another hand-rolled jq -n construction.
#
# USAGE
#
#   capture-command-block-jq.sh              # full capture to stdout
#   capture-command-block-jq.sh --sites-only # just {"sites": [...]}, no probes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$SCRIPT_DIR/../commands"

# shellcheck source=lib/extract-command-blocks.sh
source "$SCRIPT_DIR/lib/extract-command-blocks.sh"

WORK_DIR="$(mktemp -d)"
BLOCKS_DIR="$WORK_DIR/blocks"
INDEX="$WORK_DIR/index.tsv"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

extract_blocks

exec python3 "$SCRIPT_DIR/tests/capture_command_block_jq.py" \
  --blocks-dir "$BLOCKS_DIR" --index "$INDEX" --commands-dir "$COMMANDS_DIR" "$@"
