# Brainstorm: Step 0.7 Ambiguous Bundle Resolution

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

### Step 0.7 Ambiguous Bundle Resolution

Branches on `BUNDLE_STATUS` from the detection call above. When `BUNDLE_STATUS`
is `0` (whether `bundleDetected` ended up `true`, or `false` from a literal
`null`), this section does not fire at all — proceed straight to Step 0.7
Design Handoff Offer below exactly as if this section did not exist. The three
subsections below are mutually exclusive on `BUNDLE_STATUS` and
`INTERACTIVE_MODE`, and brainstorm never aborts over a bundle in any of them
(D9).

#### Interactive Picker (status 3)

Fires when `BUNDLE_STATUS=3` and `INTERACTIVE_MODE=picker`. `BUNDLE_RESULT`
parses as `{"ambiguous":true,"tier":"...","candidates":[...]}`; each entry in
`.candidates[]` carries `.path`, `.businessSpec` and `.designSpec` (`null`
when that spec is absent).

Present exactly one AskUserQuestion, naming the count and listing the first 4
entries of `.candidates[]` in their own path order, escape hatch last per
`commands/references/interactivity.md`'s Option Format. Compose the question
and option text in the same language `$FEATURE_DESCRIPTION` is written in,
per the Adaptive Language Rule (`commands/references/user-communication.md`
§ Adaptive Language Rule) — the English wording below is an illustration for
a reader of this file, not a fixed string to emit verbatim:

```
Design Bundle Detection found <N> bundles and none was named. Which one should this brainstorm use?
A — <candidates[0].path> (<"BusinessSpec, DesignSpec" | "BusinessSpec only" | "DesignSpec only" | "no specs", from that candidate's own businessSpec/designSpec>)
B — <candidates[1].path> (...)
...
None — proceed without a bundle
```

- **[None, the escape option]:** `bundleDetected` stays `false`
  (already derived above). Proceed to Step 0.7 Design Handoff Offer below.
- **[A pick]:** set `CHOSEN_BUNDLE_PATH` to the selected candidate's own
  `.path`, then re-detect directly against it — a candidate the CLI's own scan
  already returned is already inside `AIMI_ROOT`, so no realpath/import
  resolution is needed:

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  BUNDLE_ERR_FILE=$(mktemp)
  BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle --bundle "$CHOSEN_BUNDLE_PATH" 2>"$BUNDLE_ERR_FILE")
  BUNDLE_STATUS=$?
  BUNDLE_STDERR=$(cat "$BUNDLE_ERR_FILE" 2>/dev/null)
  rm -f "$BUNDLE_ERR_FILE"
  ```

  Re-derive `bundleDetected`, `bundlePayload` and `bundlePath` from this fresh
  result using the exact same rule stated above (`BUNDLE_STATUS=0` and
  non-null is required for `bundleDetected=true`) — no second test is written
  here. A second ambiguity is structurally impossible: `--bundle` names
  exactly one directory. Proceed to Step 0.7 Design Handoff Offer below.

#### Agent Mode (status 3)

Fires when `BUNDLE_STATUS=3` and `INTERACTIVE_MODE=agent`. There is no user to
ask, so do not guess: log exactly one line to the brainstorm document's
working memory naming every candidate, leave `bundleDetected` as `false`
(already derived above), and proceed:

```
agent-mode: design-bundle-ambiguous — <N> bundles found and none was named (<candidates[0].path>, <candidates[1].path>, ...); re-run with --bundle <path> to choose one.
```

#### Other Detection Failure (status neither 0 nor 3)

Fires when `BUNDLE_STATUS` is neither `0` nor `3`, in either picker or agent
mode. Log one warning line carrying the CLI's own stderr and proceed without a
bundle:

```
bundle detection failed (exit <BUNDLE_STATUS>): <BUNDLE_STDERR>
```

Leave `bundleDetected` as `false` (already derived above) and continue to
Step 0.7 Design Handoff Offer below.
