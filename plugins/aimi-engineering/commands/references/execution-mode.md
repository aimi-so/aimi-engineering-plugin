# Execution Mode

Shared reference for reading `metadata.execution`, the discriminator that tells a
command whether a tasks.json expects legacy inline execution or container-based
execution. This file defines the read contract only — it does not implement
either execution path itself.

**Consumed by:** outline story 05 (`/aimi:execute`'s flat container creation) and
outline story 10 (`/aimi:next`'s sequential containerization). Both commands read
`metadata.execution` at the point where they currently decide how to run a
tasks.json, and branch per the rule below. This file does not modify
`execute.md` or `next.md` — that wiring is those stories' responsibility.

## The Field

`metadata.execution` is an optional string on a tasks.json's `metadata` object.
Valid values are exactly `"container"` or `"inline"`. Any tasks.json written
before this field existed has no `execution` key at all — that absence must
keep behaving exactly as `"inline"` always has, so no pre-existing tasks.json
changes behavior from this field's introduction.

## Read Rule

Read the field with a jq default that folds absence into `"inline"`:

```bash
jq -r '.metadata.execution // "inline"' "$TASKS_FILE"
```

Resolve the result with a fail-safe default: only the literal string
`"container"` selects the container path. Every other value — `"inline"`,
absence, or anything unexpected — resolves to the inline (legacy) path. This
mirrors the schema's backward-compatibility guarantee: a discriminator a
consumer doesn't recognize should never silently activate new behavior.

| `metadata.execution` value | Resolved path |
|---|---|
| (absent) | inline |
| `"inline"` | inline |
| `"container"` | container |
| anything else | inline (fail-safe default) |

## What Each Path Means (for the consuming stories)

- **inline** — the legacy path: execute stories directly against the current
  working tree, exactly as every command has always done.
- **container** — the new path: outline stories 05 and 10 define what
  "container" means operationally (worktree creation, dev server lifecycle,
  etc.) for `/aimi:execute` and `/aimi:next` respectively. This file only
  guarantees that both commands agree on when to take that path — it does not
  define the path's behavior.

`aimi-cli.sh validate-tasks` enforces that when `metadata.execution` is
present, its value is exactly `"container"` or `"inline"` — no other value is
accepted.
