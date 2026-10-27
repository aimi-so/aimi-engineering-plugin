# Plan: Phase 0: Design Bundle Detection

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Design Bundle Detection

Parse `--bundle <path>`, `--root <path>` and a bare `--reimport` token out of `$FEATURE_DESCRIPTION` — never raw `$ARGUMENTS`, which by this point in the pipeline no longer carries the feature description at all. Strip every matched token, and the two flags' own values, out of `$FEATURE_DESCRIPTION` in this same block, re-assigning it exactly the way `### Parse --phase Override` and `### Detect Interactivity` strip their own flags above. Validate `--bundle`'s shape in this same block, before any CLI call below uses it: a token that itself starts with `--` is not a path, it is the *next* flag — the sed capture caught it only because `--bundle` was given with no argument of its own before that flag:

```bash
BUNDLE_ARG=""
case " $FEATURE_DESCRIPTION " in
  *" --bundle "*)
    BUNDLE_ARG=$(echo "$FEATURE_DESCRIPTION" | sed -n 's/.*--bundle[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
    FEATURE_DESCRIPTION=$(echo "$FEATURE_DESCRIPTION" | sed 's/[[:space:]]*--bundle[[:space:]]\+[^[:space:]]\+[[:space:]]*/  /' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ;;
esac
BUNDLE_OVERRIDE=""
case " $FEATURE_DESCRIPTION " in
  *" --root "*)
    BUNDLE_OVERRIDE=$(echo "$FEATURE_DESCRIPTION" | sed -n 's/.*--root[[:space:]]\+\([^[:space:]]\+\).*/\1/p')
    FEATURE_DESCRIPTION=$(echo "$FEATURE_DESCRIPTION" | sed 's/[[:space:]]*--root[[:space:]]\+[^[:space:]]\+[[:space:]]*/  /' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ;;
esac
REIMPORT_FLAG=false
case " $FEATURE_DESCRIPTION " in
  *" --reimport "*)
    REIMPORT_FLAG=true
    FEATURE_DESCRIPTION=$(echo "$FEATURE_DESCRIPTION" | sed 's/[[:space:]]*--reimport[[:space:]]*/  /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ;;
esac
if [ -z "$BUNDLE_ARG" ] && [ -n "${brainstormBundleRoot:-}" ]; then
  case "$brainstormBundleRoot" in
    /*) BUNDLE_ARG="$brainstormBundleRoot" ;;
    *)  BUNDLE_ARG="$AIMI_ROOT/$brainstormBundleRoot" ;;
  esac
fi
BUNDLE_SHAPE_OK=true
case "$BUNDLE_ARG" in
  --*) BUNDLE_SHAPE_OK=false ;;
esac
```

When `BUNDLE_SHAPE_OK=false`: report `[plan] --bundle requires a path argument` and STOP the entire `/aimi:plan` invocation — nothing below this point runs. An empty `BUNDLE_ARG` is not an error; it just means no `--bundle` was named. When no `--bundle` token was typed, the block above fills `BUNDLE_ARG` from the brainstorm's `designBundle.root` (`### Reuse Brainstorm Design Bundle`); a typed `--bundle` is never overridden by it, and the value then takes the same `realpath` confinement and import path below as a typed one.

**When `BUNDLE_ARG` is non-empty, resolve it before any `detect-design-bundle` call runs — D5's confinement rule applies here exactly as it applies inside the verb itself:**

```bash
BUNDLE_ARG_REAL=$(realpath "$BUNDLE_ARG" 2>/dev/null || printf '%s' "$BUNDLE_ARG")
case "$BUNDLE_ARG_REAL" in
  "$AIMI_ROOT"|"$AIMI_ROOT"/*) BUNDLE_FINAL="$BUNDLE_ARG" ;;
  *) BUNDLE_FINAL="" ;;
esac
```

- **`BUNDLE_FINAL` non-empty (the path, symlinks resolved, already sits inside `AIMI_ROOT`):** use `$BUNDLE_ARG` as-is — no import needed.
- **`BUNDLE_FINAL` empty (the path resolves outside `AIMI_ROOT`):** bring it into the project first with `import-design-bundle`, then point `BUNDLE_FINAL` at the imported copy. The destination (`BUNDLE_DEST`) depends on `ROADMAP_MODE` (set above, in Rolling-Wave Phase Selection):
  - `ROADMAP_MODE=true`: `$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR/design-bundle` — D2's fixed phase-scoped location, reusing `$featureSlug`/`$PHASE_DIR` from `#### Extract selected-phase working memory` above; this is the same `<phase-dir>/design-bundle/README.md` layout `_select_design_bundle`'s phase tier already expects.
  - `ROADMAP_MODE=false`: `$AIMI_ROOT/.aimi/design-bundles/<slug>`, `<slug>` derived from `$FEATURE_DESCRIPTION` by `$AIMI_CLI slugify --stdin`, the deterministic form of the derivation in `commands/references/topic-slug.md` (accents folded to ASCII, lowercase, hyphenate, dedupe hyphens, truncate 50, strip trailing hyphens) that Phase 1's own `topicSlug` derivation applies below — that derivation has not run yet for a flat feature at this point in the pipeline, so this is a local, one-off derivation rather than a reuse of it.

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  if [ "$ROADMAP_MODE" = true ]; then
    BUNDLE_DEST="$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR/design-bundle"
  else
    BUNDLE_IMPORT_SLUG=$(printf '%s' "$FEATURE_DESCRIPTION" | $AIMI_CLI slugify --stdin) || BUNDLE_IMPORT_SLUG=""
    [ -n "$BUNDLE_IMPORT_SLUG" ] || { echo "Error: no slug can be derived from the feature description" >&2; exit 1; }
    BUNDLE_DEST="$AIMI_ROOT/.aimi/design-bundles/$BUNDLE_IMPORT_SLUG"
  fi
  IMPORT_ERR_FILE=$(mktemp)
  if [ "$REIMPORT_FLAG" = true ]; then
    IMPORT_JSON=$($AIMI_CLI import-design-bundle --from "$BUNDLE_ARG" --to "$BUNDLE_DEST" --reimport 2>"$IMPORT_ERR_FILE")
  else
    IMPORT_JSON=$($AIMI_CLI import-design-bundle --from "$BUNDLE_ARG" --to "$BUNDLE_DEST" 2>"$IMPORT_ERR_FILE")
  fi
  IMPORT_EXIT=$?
  IMPORT_STDERR=$(cat "$IMPORT_ERR_FILE" 2>/dev/null)
  rm -f "$IMPORT_ERR_FILE"
  ```

  **When the slug is empty** (the description holds no ASCII letter or digit once accents are folded, so `slugify` refused it), the block above prints the verb's own stderr line and its own `Error: no slug can be derived` line and STOPS the entire `/aimi:plan` invocation before `import-design-bundle` runs. No fallback slug is made up.

  **On `IMPORT_EXIT != 0`:** report `$IMPORT_STDERR` as a single warning line — the CLI's own refusal already names both the source and the destination when a different copy already lives there, and names `--reimport` as the way to replace it — and STOP the entire `/aimi:plan` invocation before any `detect-design-bundle` call runs. **On `IMPORT_EXIT = 0`:** `BUNDLE_FINAL="$BUNDLE_DEST"`.

**Build and run the `detect-design-bundle` call, capturing stdout and the exit status separately from stderr — never merged, and never swallowed into an empty default the way this call used to be:**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BUNDLE_ERR_FILE=$(mktemp)
if [ -n "$BUNDLE_FINAL" ]; then
  BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle --bundle "$BUNDLE_FINAL" 2>"$BUNDLE_ERR_FILE")
elif [ "$ROADMAP_MODE" = true ] && [ -n "$BUNDLE_OVERRIDE" ]; then
  BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle --root "$BUNDLE_OVERRIDE" --phase-dir "$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR" 2>"$BUNDLE_ERR_FILE")
elif [ "$ROADMAP_MODE" = true ]; then
  BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle --phase-dir "$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR" 2>"$BUNDLE_ERR_FILE")
elif [ -n "$BUNDLE_OVERRIDE" ]; then
  BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle --root "$BUNDLE_OVERRIDE" 2>"$BUNDLE_ERR_FILE")
else
  BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle 2>"$BUNDLE_ERR_FILE")
fi
BUNDLE_EXIT=$?
BUNDLE_STDERR=$(cat "$BUNDLE_ERR_FILE" 2>/dev/null)
rm -f "$BUNDLE_ERR_FILE"
```

`--bundle` takes precedence over everything else whenever `BUNDLE_FINAL` is non-empty (named directly, or resolved through the import step above). Otherwise `--phase-dir "$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR"` is passed — composed with `--root "$BUNDLE_OVERRIDE"` when both apply — whenever `ROADMAP_MODE=true`, reusing `$PHASE_DIR` from `#### Extract selected-phase working memory` above; `--phase-dir` is never passed when `ROADMAP_MODE=false`. The pre-existing `--root` forwarding is unchanged beyond now composing with `--phase-dir` in roadmap mode.

**Branch on `BUNDLE_EXIT`:**

- **`0`, and `BUNDLE_STDOUT` is the literal `null`:** `designBundleMeta=null`. Continue.
- **`0`, and `BUNDLE_STDOUT` is a JSON object:** `designBundleMeta=<that object>`. Continue.
- **`3` (ambiguous):** see below.
- **anything else:** report `$BUNDLE_STDERR` as a single warning line and STOP the entire `/aimi:plan` invocation. This is unlike the Pre-Expansion Contract Gate's and Roadmap Materialization's own "surface the CLI's stderr and continue the rest of the plan pipeline" precedent for an unhandled failure shape: every exit `detect-design-bundle` can produce by design is already one of the three cases above, so a fourth one means something this command does not understand happened, before any planning context exists for the rest of the pipeline to fall back on.

**On exit 3 — ambiguous, two or more same-tier candidates and no bundle was named:** `BUNDLE_STDOUT` parses as `{"ambiguous":true,"tier":"...","candidates":[...]}`; each entry in `.candidates[]` carries `.path`, `.businessSpec` and `.designSpec` (`null` when that spec is absent).

- **Interactive** (`INTERACTIVE_MODE` is not `agent`): present exactly one AskUserQuestion, naming the count and listing the first 4 entries of `.candidates[]` in its own path order:
  ```
  Design Bundle Detection found <N> bundles and none was named. Which one should this plan use?
  A — <candidates[0].path> (<"BusinessSpec, DesignSpec" | "BusinessSpec only" | "DesignSpec only" | "no specs", from that candidate's own businessSpec/designSpec>)
  B — <candidates[1].path> (...)
  ...
  none — plan without a bundle
  ```
  On a pick: set `BUNDLE_FINAL` to the chosen candidate's own `.path` and re-run **Build and run the `detect-design-bundle` call** above — skip the realpath/import resolution step entirely, a candidate the CLI's own scan already returned is already inside `AIMI_ROOT`. On **none — plan without a bundle**: `designBundleMeta=null`, continue.
- **Agent mode** (`INTERACTIVE_MODE=agent`): do not guess — compose and report one line naming every candidate, then STOP the entire `/aimi:plan` invocation:
  ```
  agent-mode: design-bundle-detection ambiguous — <N> bundles found and none was named (<candidates[0].path>, <candidates[1].path>, ...); re-run with --bundle <path> to choose one.
  ```

Store the resolved JSON object (or `null`) as `designBundleMeta`.
