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
changes behavior from this field's introduction. `/aimi:plan` now writes the
literal `"container"` into every freshly generated flat tasks.json (the
plan-time write default); the read contract below is unchanged by that —
absence still resolves to inline.

## Flat Files Only

`metadata.execution` applies to flat, non-phase tasks.json files only —
`ROADMAP_MODE=false`, no `metadata.phase` key. A phase-scoped file
(`metadata.phase` present) never carries `metadata.execution`: a claimed
phase already runs inside its own phase container (see execute.md's Create
or Reuse the Phase Container), so the flat-mode discriminator would be dead
data there — `CONTAINER_MODE` in execute.md is hardcoded to `false` whenever
`PHASE_MODE=true`, regardless of what `metadata.execution` might say. `/aimi:plan`
never writes the key on a phase-scoped file, and `aimi-cli.sh validate-tasks`
rejects any tasks.json that carries both `metadata.execution` and
`metadata.phase`. `/aimi:next` goes further: it refuses to run at all against
a phase-scoped file (see Override Flags below), since it has no phase-claim
logic and cannot resolve a phase's own container base.

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
accepted, and it may not be present alongside `metadata.phase`.

## Override Flags

Both `/aimi:execute` and `/aimi:next` accept `--container`/`--inline` on the
command line (mutually exclusive — passing both aborts with an error before
either command does anything else). The flag overrides `metadata.execution`
for that single invocation only where the override is meaningful:

- **`PHASE_MODE=false` (flat file):** the override replaces the effective
  execution mode for the run. When it changes the mode from what the file
  already had on disk, the command persists the new value onto
  `metadata.execution` via `aimi-cli.sh set-execution-mode <container|inline>`
  — the same atomic flock+mktemp+mv pattern `mark-complete` uses — so a later
  invocation that omits the flag continues in the same mode instead of
  silently reverting to whatever the file said before the override.
- **`PHASE_MODE=true` (phase-scoped file), in `/aimi:execute`:** the override
  is ignored with a warning. `CONTAINER_MODE` is hardcoded to `false` under
  `PHASE_MODE=true` regardless of the flag — a claimed phase already has its
  own container — so persisting the flag there would recreate the exact
  dead-data problem this file's Flat Files Only section describes.
- **Any phase-scoped file, in `/aimi:next`:** `/aimi:next` refuses to run at
  all, before evaluating `--container`/`--inline` or any other container
  logic, and points the user at `/aimi:execute` instead. `/aimi:next` has no
  phase-claim step and cannot resolve a phase's own container base, so
  degrading to a warning-and-ignore (as `/aimi:execute` does) is not safe
  here — the prior behavior of building a container straight from
  `metadata.branchName` on a phase file was exactly this bug.

`set-execution-mode` itself refuses (non-zero exit) when the active tasks
file carries `metadata.phase`, as a second line of defense behind the
callers' own phase checks above.
