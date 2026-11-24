# Execute: Usage Validation Environment

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Usage Validation Environment

Brings the whole product up from the recorded usage recipe, waits for it, and captures one reusable manual login, so that usage validation always starts against a live, signed-in product. It ends with exactly one outcome and never blocks a run by itself: every failing check ends the reference with one outcome line.

Every Bash call is an isolated shell. Re-resolve `AIMI_CLI` at the top of each block and carry nothing between calls in shell variables; the state lives in `.aimi/state/usage-env/` behind the verbs.

#### Inputs

The caller (the usage-validation loop) hands over, and this reference never re-derives:

- `USAGE_RUN` — the run key (`^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`).
- `USAGE_REPOS` — one `--repo` value per line: `<project>=<branch>` for a container worktree, the `<project>` alone for an inline checkout (the repository checkout itself).
- `USAGE_RESTART` — `true` only when the caller asks for a restart (the loop re-runs this reference after a merged fix); otherwise `false`.
- `USAGE_PROJECT` — the project whose recipe carries the login (the repository that serves the UI).
- `USAGE_SESSION` — `aimi-usage-<run key>`, the browser session the loop hands the validator.

#### Recipe

The recipe is the only source: setup steps, serve command, fixed port, readiness URL and login all come from `usage-recipe-get`. This reference names no package-manager command and no other convention. No recipe ends with `unable-to-evaluate`.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_PROJECT="[the project that serves the UI]"
RECIPE_JSON=$("$AIMI_CLI" usage-recipe-get --project "$USAGE_PROJECT") || { echo "usage-env: tooling-failed"; echo "usage-env-reason: usage-recipe-get exited non-zero"; exit 1; }
if [ "$(printf '%s' "$RECIPE_JSON" | jq -r '.status')" != "recorded" ]; then
  echo "usage-env: unable-to-evaluate"
  echo "usage-env-reason: recipe: no trusted usage recipe is recorded for $USAGE_PROJECT"
  exit 1
fi
printf 'usage-recipe: login=%s browser=%s port=%s\n' "$(printf '%s' "$RECIPE_JSON" | jq -r '.recipe.login.method // "none"')" "$(printf '%s' "$RECIPE_JSON" | jq -r '.recipe.browser // "agent-browser"')" "$(printf '%s' "$RECIPE_JSON" | jq -r '.recipe.port // "none"')"
```

A `usage-env: unable-to-evaluate` line ends the reference at Output.

#### Bring-up

One Bash call, and it returns at once: the verb starts a detached process and the setup steps, the serve command and the readiness wait run there. `usage-env-up` stops a default-mode server on the same key itself and takes the repository checkout as the worktree for an inline run. Pass `--restart` when `USAGE_RESTART` is `true`.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_RUN="[the run key]"
USAGE_RESTART="[true or false]"
USAGE_REPOS=$(cat <<'USAGE_REPOS_EOF'
[one repo spec per line]
USAGE_REPOS_EOF
)
set --
while IFS= read -r spec; do
  [ -n "$spec" ] && set -- "$@" --repo "$spec"
done <<USAGE_LOOP_EOF
$USAGE_REPOS
USAGE_LOOP_EOF
if [ "$USAGE_RESTART" = "true" ]; then
  "$AIMI_CLI" usage-env-up --run "$USAGE_RUN" "$@" --restart || { echo "usage-env: tooling-failed"; echo "usage-env-reason: bring-up: usage-env-up refused"; exit 1; }
else
  "$AIMI_CLI" usage-env-up --run "$USAGE_RUN" "$@" || { echo "usage-env: tooling-failed"; echo "usage-env-reason: bring-up: usage-env-up refused"; exit 1; }
fi
```

Its JSON line carries `status`: `starting` goes to Poll, `ready` (a reused run) goes to Origins, `unable-to-evaluate` ends at Output with the reason it names.

#### Poll

Run this block in a separate Bash call, with the Bash tool timeout set to `540000` ms (under the `600000` ms cap), and no state carried from the previous call. It performs one poll, waits up to 480 seconds inside the verb (returning as soon as the status leaves `starting`), and prints the state.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_RUN="[the run key]"
STATUS_JSON=$("$AIMI_CLI" usage-env-status --run "$USAGE_RUN" --wait 480) || { echo "usage-env-state: tooling-failed usage-env-status exited non-zero"; exit 1; }
printf 'usage-env-state: %s stage=%s reason=%s\n' "$(printf '%s' "$STATUS_JSON" | jq -r '.status')" "$(printf '%s' "$STATUS_JSON" | jq -r '.stage // ""')" "$(printf '%s' "$STATUS_JSON" | jq -r '.reason // ""')"
```

- `starting` is the only in-progress status: poll again in a new Bash call. Elapsed time never turns it into `tooling-failed`; the per-step and readiness limits belong to the detached process, which ends in `failed` by itself.
- `ready` goes to Origins.
- `unable-to-evaluate` ends at Output, with the stage and reason it names (a busy fixed port names that port; another port is never chosen).
- `failed`, `absent` or `down` is `tooling-failed`, with the stage and reason.

#### Origins

Before any browser navigates, every URL the run may be sent to is judged by `usage-env-status`, which applies the gate's one loopback rule (`is_loopback_origin` in `usage_recipe.py`: `http` or `https`, host exactly `localhost`, `127.0.0.1` or `[::1]`, no userinfo). It prints the de-duplicated `origins` of every server URL and recipe login URL, each repository's `loginUrl` (a relative login URL already joined to that repository's own server), and `originsRefused`, the URLs that failed. Inline flat runs are validated on the repository checkout itself under the same rule. A refusal, or a run that is no longer `ready`, is `tooling-failed`, and the origins it prints are the only ones ever navigated.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_RUN="[the run key]"
USAGE_PROJECT="[the project that serves the UI]"
STATUS_JSON=$("$AIMI_CLI" usage-env-status --run "$USAGE_RUN") || { echo "usage-env: tooling-failed"; echo "usage-env-reason: origins: usage-env-status exited non-zero"; exit 1; }
if [ "$(printf '%s' "$STATUS_JSON" | jq -r '.status')" != "ready" ]; then
  echo "usage-env: tooling-failed"
  echo "usage-env-reason: origins: the run is no longer ready"
  exit 1
fi
if [ "$(printf '%s' "$STATUS_JSON" | jq -r '.originsRefused | length')" != "0" ]; then
  echo "usage-env: tooling-failed"
  echo "usage-env-reason: origins: a URL outside loopback was refused"
  exit 1
fi
USAGE_ORIGINS=$(printf '%s' "$STATUS_JSON" | jq -r '.origins | join(" ")')
LOGIN_URL=$(printf '%s' "$STATUS_JSON" | jq -r --arg p "$USAGE_PROJECT" '[.repositories[] | select(.project == $p) | .loginUrl // empty] | first // ""')
printf 'usage-origins: %s\n' "$USAGE_ORIGINS"
printf 'usage-login-url: %s\n' "$LOGIN_URL"
```

#### Login and Browser

Resolve interactivity fresh:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$("$AIMI_CLI" detect-interactivity)
echo "usage-env: interactivity=$INTERACTIVE_MODE claudecode=${CLAUDECODE:-unset}"
```

**Browser choice.** `chrome` is printed only when the recipe's browser is `chrome`, `CLAUDECODE` is set, and a tabs-context probe through the claude-in-chrome tools (`mcp__claude-in-chrome__tabs_context_mcp`, loaded with ToolSearch first) answers. Otherwise fall back to agent-browser and say so in one line (`usage-browser: falling back to agent-browser — <why>`). In chrome mode only the `usage-origins:` origins are ever navigated, and the login is whatever the person's own Chrome already holds: nothing below runs. A recipe with no `browser`, or `agent-browser`, takes the agent-browser path. If agent-browser is not installed (`command -v agent-browser`), the browser is `none` (a CLI-only recipe has no browser to drive).

**Login, agent-browser path.** The saved login is an agent-browser session name, `aimi-login-<project key with / as _; "root" for ".">`, distinct from the run's own `USAGE_SESSION`. Skip the whole section when the recipe's login method is `none`.

1. Visit the recipe's login URL headless. A page past the login screen means the saved login is live: reuse it headless for every later validation and run.

```bash
LOGIN_SESSION="[aimi-login-<project key>]"
LOGIN_URL="[the usage-login-url printed by the origins gate]"
agent-browser --session-name "$LOGIN_SESSION" open "$LOGIN_URL"
agent-browser --session-name "$LOGIN_SESSION" snapshot -i
agent-browser --session-name "$LOGIN_SESSION" close
```

2. A login form on that visit (no saved login yet, or one that expired) is the only reason to ask for a new one.
3. `INTERACTIVE_MODE=picker`: open the window for the person.

```bash
LOGIN_SESSION="[aimi-login-<project key>]"
LOGIN_URL="[the usage-login-url printed by the origins gate]"
agent-browser --headed --session-name "$LOGIN_SESSION" open "$LOGIN_URL"
```

Ask exactly one `AskUserQuestion` ("Log in by hand in the window that just opened, then answer here"). The person logs in by hand. The agent never types, reads or asks for a credential, and never reads the page for one. When the answer says done, save the session by closing it, then repeat step 1 once to confirm:

```bash
LOGIN_SESSION="[aimi-login-<project key>]"
agent-browser --session-name "$LOGIN_SESSION" close
```

4. `INTERACTIVE_MODE=agent`: nothing is asked and no window opens. Print `usage-login: not captured (agent mode)` and continue unauthenticated.

#### Output

Print exactly these lines and stop. `usage-env-reason:` is one line naming the stage, sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` Base Rules, and is never printed with `ready`.

```bash
USAGE_OUTCOME="[ready, unable-to-evaluate or tooling-failed]"
USAGE_BROWSER_LINE="[agent-browser:<login session name>, chrome or none]"
USAGE_ORIGINS_LINE="[the origins printed by the gate, space separated]"
USAGE_REASON=$(cat <<'USAGE_REASON_EOF'
[stage: reason, empty when ready]
USAGE_REASON_EOF
)
USAGE_REASON=$(printf '%s' "$USAGE_REASON" | tr -d '\000-\037' | cut -c1-300)
printf 'usage-env: %s\n' "$USAGE_OUTCOME"
[ "$USAGE_OUTCOME" = "ready" ] || printf 'usage-env-reason: %s\n' "$USAGE_REASON"
printf 'usage-browser: %s\n' "$USAGE_BROWSER_LINE"
printf 'usage-origins: %s\n' "$USAGE_ORIGINS_LINE"
```

`ready` needs every stage above to have passed. `unable-to-evaluate` is a missing recipe or a busy fixed port; `tooling-failed` is a failed setup step, a readiness URL that never answered, a refused origin or a verb that exited non-zero.

#### Tear Down

Runs for every outcome except failing. On a failing validation the container and the server stay up for the person, and the line says so (`usage-env: kept — validation failing`). It closes only the run's own browser session, `USAGE_SESSION`, and leaves the saved login in place.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
USAGE_RUN="[the run key]"
USAGE_VALIDATION_OUTCOME="[passing, skipped or failing]"
if [ "$USAGE_VALIDATION_OUTCOME" = "failing" ]; then
  echo "usage-env: kept — validation failing; the container and the server stay up"
else
  command -v agent-browser >/dev/null 2>&1 && agent-browser --session "aimi-usage-$USAGE_RUN" close >/dev/null 2>&1
  "$AIMI_CLI" usage-env-down --run "$USAGE_RUN"
fi
```
