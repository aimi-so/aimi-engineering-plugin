---
name: aimi-learnings
description: Triage the pending friction queue captured by aimi hooks. Groups events by scope (project / plugin / inbox), presents top patterns for review, and drafts promotion proposals locally for human review. Never auto-commits, never opens PRs. Triggers on /aimi:learnings, "triage friction", "review friction events", "drain friction queue".
disable-model-invocation: true
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Aimi Learnings Processor

Triage friction events captured by aimi hooks, group them by scope, present the
top patterns for review, and draft promotion proposals locally — for human review
only. This skill never writes to hooks, skills, or commands directories directly,
and never commits or opens pull requests.

## Quick Start

Run `/aimi:learnings` to triage the pending friction queue. The skill lists all
pending events grouped by scope, walks you through the top patterns one group at
a time, and saves any promoted proposals as draft files under
`~/.aimi/learnings/proposed/` for your review. Nothing is committed or pushed
until you decide to act on the drafts.

---

## Workflow

### Step 1 — Enumerate Pending Events

Run the drain script in list mode to get the current queue, grouped by scope:

```bash
python3 plugins/aimi-engineering/skills/aimi-learnings/scripts/drain-friction.py --list
```

The script outputs JSON in this shape:

```json
{
  "groups": {
    "project": { "count": 0, "samples": [] },
    "plugin":  { "count": 0, "samples": [] },
    "inbox":   { "count": 0, "samples": [] }
  },
  "total_pending": 0
}
```

If `total_pending` is `0`, report "No pending friction events." and stop.

### Step 2 — Present Top Patterns Per Scope Group

For each scope group whose `count > 0`, present the top patterns using
**AskUserQuestion**. Work through groups in this order: `project`, `plugin`,
`inbox`.

For each group:

1. Show the event count and up to 3 representative sample events (from the
   `samples` array). Display each sample's `current_prompt` and `previous_prompt`
   fields so the user can understand the friction context.

2. Ask the user what to do via **AskUserQuestion** with these options:
   - `Promote` — draft a promotion proposal for this pattern
   - `Discard` — mark these events as discarded, no draft created
   - `Skip` — leave the events untouched for a future triage session

3. On **Promote**: ask the user for the proposed rule wording via a follow-up
   **AskUserQuestion**. Once the user provides the wording, write a draft file
   to `~/.aimi/learnings/proposed/` using the naming convention:

   ```
   <scope>-<YYYY-MM-DD-HHMMSS>-<slug>.md
   ```

   Where `<slug>` is derived from the first 6 words of the proposed rule,
   lowercased, spaces replaced with hyphens, non-alphanumeric characters stripped.

   Use the draft template at
   `plugins/aimi-engineering/skills/aimi-learnings/references/draft-template.md`
   as the structure for the file. Populate:
   - `scope` from the current group name
   - `created_at` as the current UTC timestamp (ISO 8601)
   - `source_event_count` from the group's `count`
   - `suggested_target` based on scope (see Scope Semantics section)
   - `## Rationale` from the user's proposed rule wording
   - `## Sample friction events` from the samples in the group
   - `## Suggested rule` as a concise actionable rule statement
   - `## Suggested target` as the recommended destination file

4. Record the indices of promoted and discarded events so they can be marked
   after all groups are processed. Skipped events are not recorded.

### Step 3 — Mark Processed Events

After all groups have been reviewed, call the drain script's mark subcommand
with the collected indices:

```bash
echo '{"promoted": [<indices>], "discarded": [<indices>]}' \
  | python3 plugins/aimi-engineering/skills/aimi-learnings/scripts/drain-friction.py --mark
```

This writes a companion `<friction_file>.promoted.jsonl` file and removes the
marked entries from the live friction file.

### Step 4 — Report Results

Report a summary to the user:

- Count of events promoted, discarded, and skipped
- List of draft file paths written (if any), formatted as absolute paths
- Reminder: "Review drafts in `~/.aimi/learnings/proposed/` and decide what to
  promote. No changes have been committed."

---

## Constraints

These constraints are absolute — never override them regardless of user request:

- **Never run** `git add`, `git commit`, `gh pr create`, or any other
  repository-mutating command.
- **Never write directly to** `hooks/`, `skills/`, `commands/`, or `CLAUDE.md`
  during a learnings triage session. All output goes to `~/.aimi/learnings/proposed/`
  only.
- **Never auto-approve or auto-merge** any draft. The user is always the final
  decision-maker on what (if anything) gets promoted to the codebase.
- **Never delete friction events** without an explicit Promote or Discard
  decision from the user. Skipped events remain in the queue.

---

## Scope Semantics

**`project`** — Events captured while working in a project directory (one that
contains a `.aimi/` folder). Patterns in this scope are candidates for the
project's local `CLAUDE.md` file under a `## Prevention Rules` section, or for
a new project-scoped hook. The suggested target is typically:
"Append to CLAUDE.md under '## Prevention Rules'".

**`plugin`** — Events captured while the active skill frame was an aimi command
or skill (frame names starting with `aimi:` or `aimi-engineering:`), or when the
prompt referenced plugin internals (hooks, skills, tasks.json, etc.). Patterns
here are candidates for the plugin's own `CLAUDE.md`, a new hook script under
`hooks/`, or an update to an existing skill. The suggested target is typically:
"New hook at plugins/aimi-engineering/hooks/<name>.py" or
"Append to plugins/aimi-engineering/CLAUDE.md under '## Prevention Rules'".

**`inbox`** — Events that did not match project or plugin signals. These are
general-purpose corrections that could apply across contexts. They are candidates
for the user's global Claude config, a general-purpose hook, or simply discarded
if they don't represent a repeating pattern. The suggested target is typically:
"Review manually — consider global CLAUDE.md or discard".

---

## Example Output

```
Pending friction events: 7 total
  project: 3 events
  plugin:  3 events
  inbox:   1 event

--- Group: project (3 events) ---
Sample 1:
  Previous: "use requests for the HTTP call"
  Current:  "actually use httpx, not requests"
Sample 2:
  Previous: "add a new migration file"
  Current:  "wait, run alembic autogenerate instead"

→ Decision: Promote
→ Proposed rule: "Prefer httpx over requests for all HTTP calls in this project"
→ Draft written: ~/.aimi/learnings/proposed/project-2026-06-09-143022-prefer-httpx-over-requests.md

--- Group: plugin (3 events) ---
...

Summary:
  Promoted:  1 event group
  Discarded: 1 event group
  Skipped:   1 event group

Drafts to review:
  ~/.aimi/learnings/proposed/project-2026-06-09-143022-prefer-httpx-over-requests.md

No changes committed. Review drafts and decide what to promote.
```
