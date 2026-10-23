# Plan: Phase 4.5: Post-Generation Validation

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 4.5: Post-Generation Validation

After writing the tasks.json file(s), validate each generated output independently.

**Step 1 — Resolve the file list (run before any validator):**

Every file validated below comes from `MERGE_RETURN` — the value Phase 3e captured from `story-merge`'s stdout, and the same value Phase 4 patched from. **Never rebuild a filename by concatenating `$TASKS_PATH`**: on the PROJECT axis the surviving projects and their basename slugs are computed inside `story-merge` and are unknowable here any other way, and even on the SIDE axis the returned paths already account for `--phase-aware`'s basename collapse.

```bash
VALIDATE_FILES=$(printf '%s' "$MERGE_RETURN" | jq -r 'if type == "array" then .[].path elif has("frontend") then .frontend, .backend else .merged end')
```

The array test comes first and that ordering is load-bearing — `has()` errors on an array. `VALIDATE_FILES` is a newline-separated list covering every case with one shape: exactly 1 entry on the legacy / frontend-only path, exactly 2 on the SIDE axis, N on the PROJECT axis.

**Step 2 — Normalize and validate every file (the only validation path):**

Run the loop below once, on every axis — there is no separate single-file branch, because the legacy and frontend-only cases are just `VALIDATE_FILES` with one entry. `normalize-verification` auto-migrates any string-typed `verification` value emitted by the planner into the required object shape, and `normalize-status` defaults any story missing `status` to `"pending"`; both must run against a file **before** that file's validators, or `validate-stories` rejects rows it could have healed.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VALIDATE_FILES=$(printf '%s' "$MERGE_RETURN" | jq -r 'if type == "array" then .[].path elif has("frontend") then .frontend, .backend else .merged end')
DESIGN_SPEC_PATH=""      # fill with designBundleMeta.designSpec when it is non-null
PROTOTYPE_HTML_PATHS=""  # fill with the resolved prototype HTML paths, one per line
while IFS= read -r VALIDATE_FILE; do
  [ -n "$VALIDATE_FILE" ] || continue
  echo "Validating $VALIDATE_FILE"
  $AIMI_CLI normalize-verification "$VALIDATE_FILE" || exit 1
  $AIMI_CLI normalize-status "$VALIDATE_FILE" || exit 1
  $AIMI_CLI init-session --file "$VALIDATE_FILE" || exit 1
  $AIMI_CLI validate-ids || exit 1
  $AIMI_CLI validate-deps || exit 1
  $AIMI_CLI validate-stories || exit 1
  $AIMI_CLI validate-tasks || exit 1
  $AIMI_CLI validate-wave-contention || exit 1
  WAVES_JSON=$($AIMI_CLI validate-waves)
  if ! printf '%s\n' "$WAVES_JSON" | jq -e -s 'length > 0 and all(.valid)' >/dev/null; then
    printf '%s\n' "$WAVES_JSON" | jq -r -s '.[].errors[]?' >&2
    echo "validate-waves rejected $VALIDATE_FILE" >&2
    exit 1
  fi
  # Advisory only: no `exit` follows this call, whatever it returns.
  if [ -n "${DESIGN_SPEC_PATH:-}" ] || [ -n "${PROTOTYPE_HTML_PATHS:-}" ]; then
    set --
    [ -z "${DESIGN_SPEC_PATH:-}" ] || set -- "$@" --spec "$DESIGN_SPEC_PATH"
    while IFS= read -r PROTO_PATH; do
      [ -n "$PROTO_PATH" ] || continue
      set -- "$@" --prototype "$PROTO_PATH"
    done <<< "${PROTOTYPE_HTML_PATHS:-}"
    SV_JSON=$($AIMI_CLI structural-vocabulary --tasks "$VALIDATE_FILE" "$@" </dev/null) || SV_JSON=""
    if [ -z "$SV_JSON" ]; then
      echo "structural-vocabulary: no report for $VALIDATE_FILE (advisory, continuing)" >&2
    elif [ "$(printf '%s' "$SV_JSON" | jq -r '.measured')" = "true" ]; then
      echo "Structural vocabulary ($VALIDATE_FILE):"
      printf '%s' "$SV_JSON" | jq -r '(.missing[]? | "  missing: " + .), (.unsourced[]? | "  unsourced: " + .)'
    else
      echo "Structural vocabulary ($VALIDATE_FILE): nothing to measure"
    fi
  fi
done <<< "$VALIDATE_FILES"
```

**The `structural-vocabulary` call is advisory, and that is deliberate — it is the one call in this loop that never aborts the run.** It runs only for a UI phase (a non-null `designBundleMeta.designSpec` or a non-empty `resolvedPrototypePaths`, narrowed to prototype HTML files) and passes each spec and prototype path as its own quoted `--spec` / `--prototype` flag through the positional parameters, never from an unquoted string variable that zsh would not word-split. `missing` names a source term that never reaches the generated stories; `unsourced` names a container term a story uses that the design never named. A non-zero exit or empty output is logged and the loop continues; `measured: false` prints `nothing to measure`.

`init-session --file` rebinds the session's active tasks file, so the five `validate-*` calls always target the file bound immediately above them — keep them inside the same iteration and never reorder them. A non-zero exit anywhere aborts the loop: fix that file and re-run Phase 4.5 from the top rather than validating the remaining files against a half-fixed set. When the failure came from `normalize-verification` or `normalize-status`, inspect that file for malformed `verification` / `status` fields before retrying.

**`validate-waves` is the one validator read from its payload rather than from `$?`, and that is deliberate — do not normalize it into the shape of its four neighbours.** Its body ends at the crossing with no `return 1`: an invalid verdict still exits 0, a contract stated in comments on both sides (`cmd_validate_waves` in `aimi-cli.sh`, `op_validate_waves` in `tasks.py`) and pinned by assertions in `test-aimi-cli-part1-core.sh` against a wave-mismatch fixture, so that nothing "fixes" it into a regression for a caller branching on the status. A `|| exit 1` here would therefore be vacuous — it would read a status that is always 0 and wave every mismatch through. The verdict lives in `.valid`; `-s` slurps because one verdict is emitted per document and a tasks file may hold more than one, and `length > 0` makes an empty payload — what a hard CLI failure leaves behind — a failure rather than a silent pass. What it catches is a planning error a human reads in the file, not something dispatch consumes: `wave` is read in exactly one line of `tasks.py`, inside `validate_waves` itself, and `list-ready` ignores the field entirely. A mismatch this reports is fixed with `$AIMI_CLI normalize-waves <file>`, which recomputes every `wave` by the identical rule (`story_merge.py`'s own `compute_waves`), never by hand-editing the stored number.

**`validate-wave-contention` is read from `$?` like the four validators above it, not from its payload like `validate-waves` beside it — a NEW verb, not a widening of that one.** It refuses a wave whose stories declare the same path in `implementation.files`, so two executors dispatched into the same wave never race each other for one literal and discover the collision only at merge time. Unlike `validate-waves`, an invalid verdict here really does exit non-zero, which is why the call above needs no `WAVES_JSON`-style capture-and-inspect — the bare `|| exit 1` already stops the loop. Its remedy is never `normalize-waves`: that verb recomputes a *stored* wave from `dependsOn`, and cannot move a path out of `implementation.files`. The fix for a real contention is a `dependsOn` edge chaining the two stories (which moves the later one to a later computed wave), or narrowing `implementation.files` to the concrete paths each story actually touches — never a file split invented just to satisfy the check.

**If any validation fails (non-zero exit):**
1. Read the error output to identify the issues
2. Fix the offending story IDs, `dependsOn` references, dependency cycles, or malformed `skills[]` entries
3. Re-write the tasks.json file using the Write tool
4. Re-run all validations until they pass

**Note:** `validate-stories` catches malformed `skills[]` — entries that fail the `^[a-zA-Z0-9][a-zA-Z0-9_-]*$` regex, lists exceeding 10 entries, or an explicitly empty `skills: []` array (field must be omitted when no skills apply). It also enforces the **gate schema**: the plural `gates` field is rejected outright (use singular `gate`), and any singular `gate` object must carry all three required keys — `type`, `status`, and `prompt`.

**Step 3 — Probe every written file's verifies:**

After the validator loop passes, run `probe-plan` once for **every** file in `VALIDATE_FILES`, so each PROJECT-axis split is probed in its own repository at its own `metadata.baseRef`. This holds when `AIMI_ROOT` is a plain, non-git parent folder too: each split file is probed in the project repository its stories name, one group per `project`, and a project that is not a repository (or does not resolve) is listed as `unmeasured` while the other groups are still probed. The call is advisory in what it measures and strict in what it will not conceal: a probe that cannot answer is a `not probed` line and increments `K`, never a silent zero. The block prints the policy the verb reports, then one summary line, last.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VALIDATE_FILES=$(printf '%s' "$MERGE_RETURN" | jq -r 'if type == "array" then .[].path elif has("frontend") then .frontend, .backend else .merged end')
# phase45-probe-plan:begin
PROBE_UNLABELLED=0
PROBE_UNMEASURED=0
PROBE_NOT_PROBED=0
PROBE_POLICY="report"
while IFS= read -r VALIDATE_FILE; do
  [ -n "$VALIDATE_FILE" ] || continue
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  not probed: $VALIDATE_FILE — python3 is not installed"
    PROBE_NOT_PROBED=$((PROBE_NOT_PROBED + 1))
    continue
  fi
  PROBE_JSON=$("$AIMI_CLI" probe-plan --tasks-file "$VALIDATE_FILE" </dev/null 2>/dev/null) || PROBE_JSON=""
  if ! printf '%s' "$PROBE_JSON" | jq -e 'type == "object" and (.probed | type) == "boolean"' >/dev/null 2>&1; then
    echo "  not probed: $VALIDATE_FILE — probe-plan answered nothing usable"
    PROBE_NOT_PROBED=$((PROBE_NOT_PROBED + 1))
    continue
  fi
  if [ "$(printf '%s' "$PROBE_JSON" | jq -r '.probed')" != "true" ]; then
    PROBE_REASON=$(printf '%s' "$PROBE_JSON" | jq -r '(.reason // "no reason given") | tostring | gsub("[\\n\\r]"; " ") | gsub("`"; "") | gsub("\\$\\("; "") | .[0:200]')
    echo "  not probed: $VALIDATE_FILE — $PROBE_REASON"
    PROBE_NOT_PROBED=$((PROBE_NOT_PROBED + 1))
    continue
  fi
  PROBE_N=$(printf '%s' "$PROBE_JSON" | jq -r '[.unlabelledNonDiscriminating[]?] | length')
  PROBE_M=$(printf '%s' "$PROBE_JSON" | jq -r '[.unmeasured[]?] | length')
  PROBE_UNLABELLED=$((PROBE_UNLABELLED + PROBE_N))
  PROBE_UNMEASURED=$((PROBE_UNMEASURED + PROBE_M))
  [ "$(printf '%s' "$PROBE_JSON" | jq -r '.policy')" != "refuse" ] || PROBE_POLICY="refuse"
  printf '%s' "$PROBE_JSON" | jq -r 'def clean: tostring | gsub("[\\n\\r]"; " ") | gsub("`"; "") | gsub("\\$\\("; "") | .[0:200]; (.unlabelledNonDiscriminating[]? | "  unlabelled non-discriminating: " + (.id | clean) + ": " + (.segment | clean)), (.unmeasured[]? | "  unmeasured: " + (.id | clean) + ": " + ((.segment // "(whole verify)") | clean) + " — " + ((.why // "no reason given") | clean))'
done <<< "$VALIDATE_FILES"
echo "Verify probe policy: $PROBE_POLICY"
echo "Verify probe: $PROBE_UNLABELLED unlabelled non-discriminating, $PROBE_UNMEASURED unmeasured, $PROBE_NOT_PROBED not probed"
# phase45-probe-plan:end
```

Every jq call above reads its input from a pipe and none opens a file. Text that originates in story verifies and in probe reasons is sanitized before it is printed — newlines and carriage returns become spaces, backticks and `$(` are removed, and the text is cut to 200 characters — the same four-step rule the Audit-warnings bullets in Step 5 apply (the backtick is spelled ``` so the block holds no literal one). `unlabelledNonDiscriminating` and `unmeasured` are the verb's own precomputed answers; the block counts and prints them and never re-derives a guard rail from `stories[].segments`. An `unmeasured` entry is a segment the probe could not judge — skipped suite, timeout, shell state it could not reproduce, or an unterminated quote — and is listed by name, never counted clean.

**Applying the policy.** The block prints `Verify probe policy: report|refuse`, which is the `policy` key of the `probe-plan` payload; any other value is treated as `report`. The rationale for the recorded decision is in `commands/references/verify-probe-policy.md` — cite it, do not restate or parse it.
- **`report`:** continue to Step 4.6. The findings above are in the report; nothing blocks.
- **`refuse` with `N > 0`:** interactively, fix the written tasks file — label each named segment's exact text in `implementation.guardRails`, or rewrite the verify so it discriminates — re-write the file with the Write tool, and re-run Phase 4.5 from the top. In agent mode (`INTERACTIVE_MODE=agent`) STOP the whole `/aimi:plan` invocation and surface the report. A refusal never deletes a written tasks file.

Do **not** proceed to the report step until all validations succeed.
