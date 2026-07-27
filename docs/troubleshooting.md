# Troubleshooting

---

## "No tasks file found"

No plan exists yet. Run `/aimi:plan [feature]` to create one.

---

## A story keeps failing

1. Check what went wrong with `/aimi:status` — the failure reason is stored on the story.
2. Retry with `/aimi:next`, adjusting the approach.
3. If it stays blocked, skip it. The story is marked `skipped` and anything depending on it is skipped too, rather than run against a broken foundation.

---

## "Invalid branch name"

The branch name in the tasks file contains a character that fails validation. Edit `metadata.branchName` to use only letters, numbers, hyphens, underscores, and forward slashes.

Names are refused rather than rewritten — a mangled fallback would be worse than an error.

---

## "Story validation failed"

Story content matched one of the injection or traversal patterns. Open the tasks file, look at the flagged story, and remove the offending content — or regenerate with `/aimi:plan`.

See [architecture.md](architecture.md#security) for what is checked.

---

## Commands resolve slowly

Run `/aimi:init` once. It primes the CLI path cache so later commands skip a filesystem search.

---

## Visual verification was skipped

Expected in three cases, none of which is a failure:

- The project has no `package.json` with a `dev` script, so no dev server could start.
- `agent-browser` is not installed.
- The run is in container mode and the story's page depends on a sibling container's API — there is no proxy between them.

---

## Inspecting a headed browser session

To attach Chrome DevTools to the Chromium that `agent-browser` launches in `--headed` mode:

1. Start the session with remote debugging enabled:

   ```bash
   agent-browser --headed --session visual-follow \
     --chrome-flag="--remote-debugging-port=9222" \
     open https://example.com
   ```

2. In any local Chrome window, open `chrome://inspect/#devices`.
3. Under "Discover network targets", click **Configure...** and add `localhost:9222`.
4. The session appears under "Remote Target". Click **inspect**.

The port is arbitrary — pick any free one and use the same number in step 3. If your `agent-browser` build does not accept `--chrome-flag`, check `agent-browser --help` for the equivalent on your version, such as `--chromium-arg`.

---

## Uncommitted work did not reach the container

`git worktree add` branches from committed history. Anything sitting uncommitted in your main working tree stays there.

Commit first, then run.

---

For version history, see [CHANGELOG.md](../CHANGELOG.md).
