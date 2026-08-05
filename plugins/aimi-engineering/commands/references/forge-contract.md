# Forge Contract

Shared reference for the normalized forge PR/issue field contract and the
degradation convention every `forge-*` verb in `aimi-cli.sh` builds on. This
is the **single arbiter** of the vocabulary below — every later forge verb
(`forge-auth-status`, `forge-repo-info`, `forge-pr-view`, `forge-pr-create`,
`forge-pr-edit`, `forge-issue-view`, `forge-issue-create`, the review-thread
verbs) consumes the field names, the envelope shapes, and the three-way
status convention exactly as documented here. **No sibling verb may
introduce a variant field-name casing (e.g. camelCase `unsupportedFields`),
and no verb may invent a further ad-hoc free-text degradation field of its
own (e.g. a `degradedReason` string alongside `status`).** There is exactly
one exception, and it is named here rather than invented per verb:
`reason` — a **fixed, closed enum, never free text** — defined in the
**Degradation Reason Enum** subsection below. It exists *alongside*
`message`, never as a replacement for it, because the two answer different
questions: `message` stays human-readable prose for a log or a person,
while `reason` is the value a caller switches on programmatically without
pattern-matching a translatable English string. Every other second
degradation signal stays forbidden.

**Consumed by:** `aimi-cli.sh`'s shared jq builder functions
(`_forge_build_pr_json`, `_forge_build_issue_json`, `_forge_emit_status`,
`_forge_emit_write_status`, `_forge_build_write_data`, `_forge_bin_check`)
and every forge verb built on top of them. GitHub is the
only adapter shipping in phase 1; this contract is written so GitLab (`glab`)
and Gitea/Forgejo (`tea`) can be added later without changing the shape any
existing caller already depends on.

## Result Envelope Shapes — the complete list

This file defines exactly **four** result envelope shapes and no others. An
adapter author adding a GitLab or Gitea backend reads this list rather than
inferring the total by reading all ten `forge-*` verb bodies, and a new verb
picks one of these four rather than inventing a fifth.

| # | Envelope | `status` values | Built by | Emitted by |
|---|---|---|---|---|
| 1 | **Read three-way** — `{status, data, message, reason}` | `found` / `not_found` / `error` | `_forge_emit_status` | `forge-auth-status`, `forge-repo-info`, `forge-issue-view`, `forge-pr-review-threads`, `forge-resolve-review-thread` |
| 2 | **`forge-pr-view`'s own** — `{status, pr, unsupported_fields, message}` | `found` / `not_found` / `error` | `_forge_pr_view_emit` | `forge-pr-view` only |
| 3 | **Write three-way** — `{status, data, message}` | `created` / `unchanged` / `degraded` | `_forge_emit_write_status` | `forge-pr-create`, `forge-pr-edit`, `forge-issue-create` |
| 4 | **Review/Approval** — `{approved, changes_requested, approvals_count, unsupported_fields, raw}` | *(no `status` field)* | *(no builder yet)* | *(no verb yet — spec only)* |

Envelopes 1 and 3 share the three field names `status`, `data` and `message`
and their null-forcing discipline exactly. They differ in two ways: which
three values `status` may take — a lookup can come back empty-handed
(`not_found`), a write cannot, since a write looks nothing up — and the
machine-readable `reason` enum, which envelope 1 carries and envelope 3 does
not (see **Degradation Reason Enum**). Envelope 2 is `forge-pr-view`'s
documented exception and is scoped to that one verb — see **`forge-pr-view`
Envelope** below for why it exists at all. Envelope 4 is a spec for a future
verb, not a description of code that ships today.

`message` carries the human-readable degraded reason across every envelope
above; `reason` (envelope 1 only) carries the machine-readable one. Those two
are the complete set — no verb may add a third degradation field under any
name, and no verb may define enum values of its own beyond the four below.

## Normalized PR Field Set

The portable core — cheap and structured on all three forges today — plus
three capability-gated fields that are NOT cheap or structured everywhere.

| Field | Type | Portable core? | Notes |
|---|---|---|---|
| `number` | int | yes | GitHub `number` / GitLab `iid` / Gitea `index`. Always the project-scoped number a human types (`!123`, `#123`), never GitLab's separate global `id`. |
| `url` | string | yes | GitHub `url` / GitLab `web_url` / Gitea `url`. Direct 1:1 across all three. |
| `title` | string | yes | Direct 1:1 across all three. |
| `body` | string | yes | GitHub/Gitea `body` / GitLab `description`. Same concept, different key upstream — always normalized to `body` here. |
| `state` | string | yes | See **State Mapping** below — never an assumed shared enum. |
| `headRefName` | string | yes | GitHub `headRefName` / GitLab `source_branch` / Gitea `head`. |
| `baseRefName` | string | yes | GitHub `baseRefName` / GitLab `target_branch` / Gitea `base`. |
| `files` | array \| null | **capability-gated** | See **Capability-Gated Fields** below. |
| `isDraft` | bool \| null | **capability-gated** | See **Capability-Gated Fields** below. |
| `mergeable` | string \| null | **capability-gated** | See **Capability-Gated Fields** below. Deliberately untyped (not forced to boolean) — GitHub/Gitea reduce to a boolean, GitLab's `detailed_merge_status` is a 16-value enum describing *why* it's blocked. Forcing a shared boolean would discard GitLab's richer signal; a verb that only needs yes/no can test truthiness itself. |
| `unsupported_fields` | array of string | — | Names every capability-gated field the caller did NOT supply a value for. Empty array, never omitted, when every capability-gated field was supplied. |
| `raw` | object \| null | — | The forge-native object, untouched, alongside the normalized shape. Never discarded even when every normalized field above is populated. |

Anchored on the GitHub fields this plugin already consumes today (`open-pr.md`,
`review.md`, `validate-bug.md`, `resolve-pr-parallel/SKILL.md`): `number`,
`url`, `title`, `body`, `state`, `headRefName`, `baseRefName`, `files`. This
contract must not regress any of them.

### State Mapping

`state` needs an explicit mapping table, not an assumed shared enum —
GitLab's `locked` value has no GitHub or Gitea/Forgejo equivalent.

| Normalized `state` | GitHub | GitLab | Gitea/Forgejo (`tea`) |
|---|---|---|---|
| `open` | `state: OPEN` | `state: opened` | `state: open` |
| `closed` | `state: CLOSED` | `state: closed` | `state: closed` |
| `merged` | `state: MERGED` | `state: merged` | *(not distinguished — see note)* |
| `locked` | *(no equivalent)* | `state: locked` | *(no equivalent)* |

- **GitLab's `locked`** describes a merged-and-lock-protected MR. Neither
  GitHub nor Gitea/Forgejo expose an equivalent fourth value — normalize it
  through unchanged as `"locked"` rather than collapsing it into `"merged"`,
  since collapsing would silently discard a real GitLab-only signal.
- **Gitea/Forgejo's `tea` state field** is documented as `open`/`closed`
  only — it does not expose a distinct `merged` value the way GitHub's and
  GitLab's do. A merged PR reads as `closed` under `tea`'s own field list.
  This is a capability gap in the source data, not a mapping bug in this
  contract: a Gitea adapter that needs to distinguish "closed" from "merged"
  must derive it from a different field (e.g. a merge-commit field) when
  that adapter is built, and until then should normalize `tea`'s `closed`
  straight through as `"closed"` rather than guessing `"merged"`.

## Capability-Gated Fields

These three fields do not generalize across forges and are capability-gated
from day one — GitHub can populate all three fully today; GitLab and Gitea
cannot, or can only partially.

| Field | GitHub | GitLab | Gitea/Forgejo (`tea`) |
|---|---|---|---|
| `files` | Yes — a single `--json files` call returns a structured per-file array (`path`, `additions`, `deletions`). | No single cheap call. The MR resource itself exposes only `changes_count` (an async-populated string count); the full file list needs a second `Get single MR changes`/diffs call. | Only raw `diff`/`patch` text fields — not a parsed per-file list. |
| `isDraft` | Yes — `isDraft` boolean. | Yes — `draft` boolean. | **Not exposed by the CLI at all.** `tea`'s documented PR field list has no `draft`/`is-draft` entry; Gitea/Forgejo support draft PRs in the web UI but `tea` cannot report it. |
| `mergeable` (merge-status detail) | Yes — a plain boolean. | Yes, but richer: `detailed_merge_status` is a 16-value enum (`mergeable`, `conflict`, `ci_must_pass`, `ci_still_running`, `discussions_not_resolved`, `draft_status`, `checking`, `unchecked`, `commits_status`, `merge_request_blocked`, `status_checks_must_pass`, `jira_association_missing`, `title_regex`, `locked_paths`, `locked_lfs_files`, `approvals_syncing`) describing *why* it's blocked, not just whether. | Yes — a plain boolean. |

An unpopulated capability-gated field is **always** represented as `null`
**plus its name recorded in `unsupported_fields`** — never a bare, unmarked
`null`. A bare `null` is ambiguous between "the forge returned no data yet"
and "this forge cannot express this field at all"; the sentinel resolves
that ambiguity for every caller, present and future, without needing every
existing caller re-touched the day a stricter distinction becomes necessary.

## Normalized Issue Field Set

| Field | Type | Portable core? | Notes |
|---|---|---|---|
| `number` | int | yes | GitHub `number` / GitLab `iid` / Gitea `index` — same convention as the PR object. |
| `url` | string | yes | Direct 1:1 across all three. |
| `title` | string | yes | Direct 1:1 across all three. |
| `body` | string | yes | GitHub/Gitea `body` / GitLab `description`. |
| `state` | string | yes | `open`/`closed` — issues do not carry the PR-only `merged`/`locked` values. |
| `comments` | int \| null | **capability-gated** | GitHub: a comment count from the discussion thread. GitLab's `notes`/`discussions` model conflates PR/issue discussion with system-generated events ("changed the description") unless explicitly filtered, so a naive pass-through would double-count noise as comments. `tea` exposes a `comments` field on both its `pr` and `tea issue` field lists, but its counting semantics are not guaranteed to match GitHub's filtered count. Capability-gated for this reason, not because any forge lacks the concept entirely. |
| `unsupported_fields` | array of string | — | Same convention as the PR object. |
| `raw` | object \| null | — | Same convention as the PR object. |

Issues carry no `headRefName`/`baseRefName`/`files`/`isDraft`/`mergeable` —
those are PR-only concepts and must never appear on the normalized issue
object.

## Review/Approval Envelope

The three forges do not share a review/approval data model at all — GitLab
in particular has no `changes_requested` concept. Forcing a fake shared
enum here would be the single most expensive phase-1 mistake to unwind
later, so this is a lowest-common-denominator envelope, not an invented
unified enum:

```json
{
  "approved": true,
  "changes_requested": null,
  "approvals_count": 2,
  "unsupported_fields": ["changes_requested"],
  "raw": { "...": "forge-native object, untouched" }
}
```

| Field | Type | Notes |
|---|---|---|
| `approved` | bool \| null | `true`/`false` when the forge can report it; `null` (with the name recorded in `unsupported_fields`) when it cannot. |
| `changes_requested` | bool \| null | GitHub/Gitea: derived from a discrete `CHANGES_REQUESTED` review state. GitLab: **always capability-gated** — GitLab's Merge Request Approvals API has no "changes requested" concept at all, only an `approved` boolean and an approvals count. |
| `approvals_count` | int \| null | GitHub/Gitea: count of `APPROVED` reviews. GitLab: `approvals_left`/`approvals_required` from the (Premium/Ultimate-gated) Approvals API. |
| `unsupported_fields` | array of string | Same convention as the PR/issue objects — every one of the three fields above is individually capability-gated, since any of them can be absent depending on forge and plan tier. |
| `raw` | object \| null | The forge-native review/approval payload, untouched, alongside the normalized envelope. |

No verb implements this envelope yet and no shared builder assembles it —
the shape above is the spec whichever future approval-state verb is built
against it must produce, not a description of code that exists today.
(`forge-pr-review-threads` is a different concept: review *threads*, not
approval state, and it builds its own `{pr, threads, unsupported_fields}`
shape.)

Reviews themselves (the per-reviewer list of discrete review objects) have
**no shared data model across forges** and are explicitly out of scope for
this envelope — GitHub/Gitea's `reviews` arrays and GitLab's discussion
`notes` are structurally different enough that a later verb needing per-
reviewer detail must consume the forge-native `raw` object directly rather
than expect this envelope to carry it.

## Three-Way Status Convention

Every forge lookup verb (`forge-auth-status`, `forge-repo-info`,
`forge-pr-view`, `forge-issue-view`, and any verb added after them) reports
one of exactly three outcomes, modeled directly on `verify-creates`'
existing `verified`/`missing`/`error` trio in `aimi-cli.sh`:

| `status` | Meaning |
|---|---|
| `found` | The lookup succeeded and returned real data. `data` carries the normalized object (PR/issue/whatever the verb looks up); `message` is `null`. |
| `not_found` | The lookup ran successfully and confirmed the thing does not exist (no PR for this branch, no such issue number). `data` is `null`; `message` is `null` unless a short human-readable note is useful. |
| `error` | The tool itself failed — authentication broken, network unreachable, malformed response, unexpected exit code. `data` is `null`; `message` carries the human-readable failure detail and `reason` the machine-readable one (see **Degradation Reason Enum** below). |

`not_found` and `error` must **never** be conflated. `gh pr view --json url`
today exits non-zero for both "no PR exists for this branch" and "gh itself
is broken" — that is exactly the ambiguity this convention exists to remove.
A verb built on top of `_forge_emit_status` must distinguish the two before
calling it, the same way `_verify_creates_one` distinguishes a `missing`
identity from a `git` tool failure before calling `_verify_creates_emit`.

Shape (built by `_forge_emit_status` — see **Shared Builder Functions**
below):

```json
{"status": "found", "data": { "...": "normalized object" }, "message": null, "reason": null}
{"status": "not_found", "data": null, "message": null, "reason": null}
{"status": "error", "data": null, "message": "gh exited 4: authentication required", "reason": "not_authenticated"}
```

`message` and `reason` are the two — and the only two — degradation-related
fields this contract permits. No sibling verb may invent a third field
(`degradedReason`, `failureKind`, or any other name) to carry the same
information, and none may extend `reason` with an enum value of its own
beyond the four defined immediately below.

### Degradation Reason Enum

`reason` is populated only on `status == "error"`, and only ever with one of
these four values. It is a **closed enum, never free text** — the four
situations map onto four genuinely different agent responses, which is the
whole reason a caller can branch on it instead of grepping `message` prose:

| `reason` | Meaning | What the caller should do |
|---|---|---|
| `no_adapter` | The active forge has no adapter written for it yet (phase 1 ships GitHub only). A **permanent** gap for this install — retrying will not fix it, and neither will installing anything. | Stop. Do not retry. |
| `cli_missing` | The forge CLI binary is not on `PATH` at all. | Install it, or complete the operation manually. |
| `not_authenticated` | The forge CLI ran, but a live re-check of auth state against the same host — the same authenticated/account check `forge-auth-status` already performs — reports no valid credentials. Determined **structurally**, by re-querying auth state; **never** by pattern-matching the failing command's own stderr text, which reworks between CLI releases and varies by locale. | Re-authenticate, then retry. |
| `cli_failed` | The forge CLI ran and failed for any other reason — network unreachable, malformed response, an owner/repo that could not be auto-resolved, or an unexpected exit code the structural auth re-check did not attribute to `not_authenticated`. | Read `message` for the detail. |

`reason` is populated only by verbs built on the shared `_forge_emit_status`
builder: `forge-auth-status`, `forge-issue-view`, `forge-pr-review-threads`,
and `forge-resolve-review-thread`. `forge-repo-info` also builds on that
envelope but never reaches `status == "error"` (its local-parse fallback
keeps it to `found`/`not_found`), so it never populates `reason` in practice.
`forge-pr-view`'s own distinct envelope — documented below under
**`forge-pr-view` Envelope** — is a deliberate, pre-existing exception that
this rule does **not** extend `reason` onto.

## `forge-pr-view` Envelope

`forge-pr-view` is the one documented exception to the read envelope above.
It keeps the same `found`/`not_found`/`error` vocabulary and the same
`message` degradation signal, but carries its payload under `pr` alongside a
sibling `unsupported_fields` key instead of under a generic `data`:

```json
{"status": "found",     "pr": {"url": "..."}, "unsupported_fields": [], "message": null}
{"status": "not_found", "pr": null, "unsupported_fields": null, "message": "no open pull request for feat-x"}
{"status": "error",     "pr": null, "unsupported_fields": null, "message": "gh exited 4: authentication required"}
```

Two properties force the exception, and neither generalizes to any other
verb:

- Its `--include` field selector requires `pr` to carry **exactly** the
  caller's requested keys and no others — never the fixed superset
  `_forge_build_pr_json` always returns — so `unsupported_fields` has to sit
  outside the payload it describes.
- A `not_found` outcome here carries a populated `message` naming the ref
  that was searched, which the Three-Way Status Convention above explicitly
  permits ("`message` is `null` unless a short human-readable note is
  useful") but `_forge_emit_status`'s own null-forcing does not produce.

On `found`, `unsupported_fields` is **always** a JSON array — an explicitly
empty `[]` when every requested capability-gated field was supplied, never a
bare `null`. Built by `_forge_pr_view_emit`; no other verb may adopt this
shape.

## Write-Verb Status Convention

Every forge **write** verb (`forge-pr-create`, `forge-pr-edit`,
`forge-issue-create`) reports one of exactly three outcomes, through the same
`{status, data, message}` field names and the same null-forcing discipline
the read side uses. A write is never "not found" — nothing was looked up —
so the read trio would be a bad fit; three per-verb vocabularies were worse
still, since a caller then had to learn a different shape per verb, or read
the exit code alone, to find out what a write actually did.

| `status` | Meaning |
|---|---|
| `created` | A new resource identifier was minted. `data` carries `{url, number}` for the new resource; `message` is `null`. |
| `unchanged` | No new identifier was minted. `data` carries `{url, number}` for the resource that already existed; `message` is `null`. |
| `degraded` | The write could not complete automatically. `data` is `null`; `message` carries the reason — the same one-and-only degraded-reason field the read side uses. |

Shape (built by `_forge_emit_write_status` — see **Shared Builder Functions**
below):

```json
{"status": "created",   "data": {"url": "https://github.com/o/r/pull/101", "number": 101}, "message": null}
{"status": "unchanged", "data": {"url": "https://github.com/o/r/pull/55", "number": 55},   "message": null}
{"status": "degraded",  "data": null, "message": "gh pr create exited 1: HTTP 403"}
```

**`unchanged` covers two outcomes that look different but are the same
fact.** `forge-pr-create` finding an already-open PR on `--head` reports it,
and so does every successful `forge-pr-edit` call — an edit mutates a number
that already existed. `forge-pr-edit`'s PR *body* really did change; the word
is about the **resource identifier**, not the content. `forge-issue-create`
never reports `unchanged` at all: it only ever mints a new issue.

**The exit-code contract is unchanged by this envelope, and is not replaced
by it.** The hard-fail versus soft-fail split stated in `aimi-cli.sh`'s own
`EXIT CONTRACT DIFFERS FROM forge-issue-create ON PURPOSE` comment survives
completely intact:

| Verb | Exit code on `degraded` | Why |
|---|---|---|
| `forge-pr-create` | **non-zero** | Opening a PR has no fallback. `execute.md`'s per-repository loop needs a real non-zero exit for its own per-repository failure isolation. |
| `forge-pr-edit` | **non-zero** | Same contract as `forge-pr-create`. |
| `forge-issue-create` | **always `0`** | A failed backend issue must never block PR creation (`open-pr.md`'s documented soft-fail behavior). A caller branches on `status`, never on this verb's exit code. |

What the envelope adds is an **in-band** signal: stdout is no longer silent
on a failure path, so a caller reading stdout learns the outcome from
`status` instead of inferring it from an empty capture. It removes the exit
code being the *only* signal — it does not remove or weaken the exit code
itself.

One deliberate asymmetry inside `forge-pr-create`: once `gh pr create` has
returned a URL, a failed post-create re-read still reports `created` (with
`data.number` null and a `Warning` on stderr) at exit `0`, **not**
`degraded`. The pull request genuinely exists and only its number is
unconfirmed; reporting `degraded` would force `data` to `null` per the table
above and throw the created PR's URL away, leading a caller to open a second
pull request for a branch that already has one.

## Credential/Identity Model

Credentials are **forge-and-host-scoped**, not global — a machine can hold
distinct credentials for `github.com` and a self-hosted GitLab instance at
the same time, and a multi-repo `AIMI_ROOT` can legitimately mix forges.

Identity selection (acting as a specific account rather than whichever
account is currently active for that host) is an **OPTIONAL** parameter any
forge adapter may decline to support:

- `gh` can satisfy it fully today: `gh auth token --user <username>` prints
  that one account's token without touching the active-account pointer, and
  exporting it as `GH_TOKEN` for one invocation makes that single call act
  as `<username>` while the globally active account is untouched.
- `glab` cannot match this exactly — it is host-scoped, not identity-scoped;
  the closest mechanism is an externally-supplied `GITLAB_TOKEN` env var
  override, which requires the caller to already hold that token rather
  than pulling it from a `glab`-native multi-identity vault.
- `tea` supports it natively via `--login <name>` per invocation.

**Whatever identity value is used, it is passed to a forge CLI only via an
environment variable, never as a command-line argument.** A token passed as
a CLI argument leaks through `ps` and shell history; an environment variable
does not. This applies to every current and future forge verb, with no
exception for a "just this once" convenience call.

### The Remembered Answer — `forge-account-select`

Which account a repository writes as is asked **once per repository** and
remembered outside the repository, so the answer is never committed, never
inherited by a sibling repository, and never shared with the rest of the team.
`forge-account-select` owns that answer end to end — recording it, reading it
back, and revoking it.

**The command layer asks; the CLI decides whether asking is warranted and
remembers the answer.** That split is the same one `interactivity.md`
prescribes for every question site, and it is mechanical rather than stylistic:
the CLI is invoked through the Bash tool with a non-TTY stdin, so a prompt
implemented inside it would be silently dead in the host that matters.

Exactly **two** answer states are storable, and they are distinguishable from
each other and from having no answer at all:

```json
{"mode": "account", "account": "<login>", "recordedAt": "<ISO 8601 UTC>"}
{"mode": "active",                        "recordedAt": "<ISO 8601 UTC>"}
```

`mode: "active"` is the **"always use whichever account is currently active"**
answer. It is a first-class stored value, not the absence of one — encoding it
as an empty account string, or by leaving the entry out, is refused on both the
write and the read side, because neither is distinguishable from "has not been
asked yet".

The document is one file per repository holding **one entry per forge host**, so
a repository with remotes on more than one host carries one answer per host.
Every write is read-merge-write: recording or revoking one host's answer leaves
every other host's entry byte-for-byte intact.

Reading it back is decided on **this repository's entry**, never on the store
file's existence — the file exists the moment the first repository answers, so
an existence check would silence every repository afterwards. A store that is
absent, empty, malformed, or missing this host's entry all mean *not yet
answered*, and the question is raised again.

**The answer is the only state, and it is revocable.** `--reselect` clears this
repository's entry so the next check asks again; deleting the store file by hand
does exactly the same thing. No companion marker or sentinel file exists that
could outlive the deleted answer and keep the question suppressed.

Reading the answer back has **zero side effects** — no file is created, no
directory is created, nothing is written. That is what keeps an agent-mode or CI
auto-selection *applied for that invocation but never persisted*: one unattended
run must not be able to permanently answer the question on every human's behalf.
Persisting is always a separate, explicit record call the command layer makes
only after a person actually answered.

An explicitly requested identity outranks the remembered one: when
`AIMI_FORGE_IDENTITY` names the account to act as, the question is moot and is
not raised. Consistent with the rest of this file, that value is an environment
variable — `forge-account-select` accepts no `--token`, `--identity`, or
otherwise credential-shaped flag, and none may be added to it.

### Applying the Answer — One Invocation at a Time

The remembered login is turned into an acting account by `gh auth token`, which
prints that one account's stored token **without touching the active-account
pointer**. `gh auth switch` is the only thing that rewrites `hosts.yml`
globally, and no path here ever calls it. That is what lets both halves of the
guarantee hold at once: every forge write acts as the project's account, and
the machine's active account is byte-for-byte unchanged afterwards.

The token is applied as a **bash prefix assignment on the wrapped call**, and
both variable names are written literally because bash cannot prefix-assign a
dynamically named variable. At most one slot is ever non-empty — the resolver
decides which:

```bash
GH_TOKEN="$(_forge_account_override GH_TOKEN)" \
GH_ENTERPRISE_TOKEN="$(_forge_account_override GH_ENTERPRISE_TOKEN)" \
  _forge_capture stdout stderr_out rc -- gh pr create --title "Add the thing" --base main --head feat || true
```

`gh` treats an **empty** token variable as unset, so the "always use whichever
account is active" answer and the no-answer case reuse this identical shape
with no separate branch anywhere.

**`export` is forbidden; the override is a prefix assignment on one command,
always.** This is load-bearing rather than stylistic. With a token in the
environment, `gh auth status` reports the *env-token* account as
`Active account: true` — so an override that leaked process-wide would make
`forge-auth-status` report the overridden account as the machine's active one,
and the very before/after check that proves the machine account was left alone
would lose the ability to detect the violation. For the same reason the token
lookup itself runs with both variables cleared, or it resolves to itself
instead of to the keyring.

**Which variable, decided by host.** `gh` honors `GH_TOKEN` for `github.com`
and `*.ghe.com` only; a GitHub Enterprise Server host on a company domain
requires `GH_ENTERPRISE_TOKEN`. Emitting the wrong one does not error — it is
ignored, and the write succeeds **attributed to the wrong account**, which is
why the mapping is fixed rather than left to a caller:

| Host | Variable | `gh auth token` hostname flag |
|---|---|---|
| `github.com`, `*.github.com` | `GH_TOKEN` | `--hostname <host>` |
| `ghe.com`, `*.ghe.com` | `GH_TOKEN` | `--hostname <host>` |
| any other non-empty host (GHES on a company domain) | `GH_ENTERPRISE_TOKEN` | `--hostname <host>` |
| empty / unresolvable host (the `AIMI_FORGE_TYPE` override path, where `host` is null) | `GH_TOKEN` | omitted entirely |

The host is lowercased before matching, and an unresolvable host omits
`--hostname` rather than passing the four-character string `null` — a null read
as text once turned a bogus hostname into a confirmed-looking
`authenticated: false`.

**The token never reaches argv, and never reaches a log.** The
`env GH_TOKEN=… gh …` shape is banned outright, because `env(1)`'s own argv
carries the value and leaks it through `ps`; the prefix-assignment form never
materializes the token as an argv element at all. Nothing echoes, logs or emits
it either — it is the resolver's stdout value and nothing else, held to the same
bar as the userinfo stripped from a remote URL before `detect-forge` prints it.

**Degradation matches the rest of this file.** A remembered account that was
later logged out makes the lookup fail; the resolver then yields the empty
string and emits exactly one stderr warning naming the login and the host, and
the operation proceeds as the machine's active account. The write is not
blocked — the same warn-and-fall-back posture the Degradation Contract below
establishes — but the wrong-account attribution is made visible rather than
silent. The warning never carries the token and never forwards the forge CLI's
own stderr verbatim, which can echo token prefixes. No new `reason` enum value
is introduced by any of this.

## Degradation Contract

A forge CLI (`gh`, `glab`, `tea`) may not be installed at all, and a forge
with no adapter yet (phase 1 ships only GitHub) must not crash a caller that
tries to use it anyway. `_forge_bin_check` (see **Shared Builder Functions**
below) is the one shared presence check every forge verb uses instead of a
raw, unguarded `command -v` or a bare invocation that would fail with an
uncontrolled `127`.

Two modes, matching the two existing tiers already present in this codebase
(`check_jq` is hard-required and exits 1 on absence; `list-models`/
`detect-models` warn and fall back at exit 0) — this contract's degradation
helper always uses the **warn-and-fall-back shape**, never the hard-exit
shape, because a missing forge CLI is never fatal to the whole process the
way a missing `jq` is:

| Mode | When to use it | Behavior on absence |
|---|---|---|
| `quiet` | The caller already has its own fallback path and would only restate what the caller is about to do anyway. Matches `review.md`'s documented row: "gh CLI not installed → Fall back to git diff for branch comparison" — that fallback must not gain a spurious warning it doesn't have today. | No stderr output at all. |
| `mandatory` | The operation genuinely has no fallback without the binary (e.g. "open a PR" with no forge CLI present at all). Matches `execute.md`'s existing `command -v gh` gate at the per-repository PR-creation step. | Exactly one stderr warning naming the missing binary, the detected forge (from `detect-forge`'s output — never a generic placeholder), and a manual next step. |

In both modes the function returns a normal guarded exit code: `0` when the
binary is present, `1` when it is not. It never lets a bare invocation of
the missing binary reach the shell and fail the caller with an unguarded
`127`.

## Shared Builder Functions

Implemented in `plugins/aimi-engineering/scripts/aimi-cli.sh`. Every later
forge verb builds its result through these functions instead of hand-rolling
JSON assembly per verb — mirroring how `_verify_creates_emit` centralizes
`verify-creates`'s own verdict construction.

- **`_forge_build_pr_json`** — `jq -nc` builder for the normalized PR object
  above. Flags: `--number`, `--url`, `--title`, `--body`, `--state`,
  `--head-ref-name`, `--base-ref-name` (portable core); `--files <json
  array>`, `--is-draft <true|false>`, `--mergeable <string>` (capability-
  gated — presence of the flag is what marks a field supported, regardless
  of the value passed); `--raw <json object>`. Any capability-gated flag
  the caller omits comes back `null` and its name is appended to
  `unsupported_fields`.
- **`_forge_build_issue_json`** — matching builder for the normalized issue
  object. Flags: `--number`, `--url`, `--title`, `--body`, `--state`
  (portable core); `--comments <int>` (capability-gated); `--raw <json
  object>`.
- **`_forge_emit_status`** — `_forge_emit_status <status> [data-json]
  [message] [reason]`. `status` must be exactly `found`, `not_found`, or
  `error`; any other value is a caller error (exit 1). `reason`, the fourth
  positional argument, is validated the identical way: it must be empty or
  exactly one of `no_adapter`, `cli_missing`, `not_authenticated`,
  `cli_failed` (see **Degradation Reason Enum**), and any other non-empty
  value is a caller error (exit 1) rather than silently coerced or passed
  through. `data` is forced to `null` unless `status == "found"`; `message`
  and `reason` are both forced to `null` unless `status == "error"` — this
  prevents a caller from accidentally carrying a stale value across the
  wrong branch of the three-way outcome.
- **`_forge_emit_write_status`** — `_forge_emit_write_status <status>
  [data-json] [message]`, the write-side sibling of `_forge_emit_status`
  above (see **Write-Verb Status Convention**). `status` must be exactly
  `created`, `unchanged`, or `degraded`; any other value is a caller error
  (exit 1), mirroring `_forge_emit_status`'s own guard rather than silently
  coercing. `data` is forced to `null` unless `status` is `created` or
  `unchanged`; `message` is forced to `null` unless `status == "degraded"`.
  Returns exactly `{status, data, message}` — the identical field names and
  null-forcing discipline the read-side builder uses, differing only in
  which three values `status` may take.
- **`_forge_build_write_data`** — `_forge_build_write_data <url> [number]`.
  Builds the `{url, number}` object the three write verbs nest under
  `_forge_emit_write_status`'s `data` key. An empty `url` or `number` comes
  back `null`; a supplied `number` is a JSON int, never a quoted string.
  One builder for all three verbs, so their success shapes are identical by
  construction rather than by three hand-rolled `jq` expressions that merely
  happen to agree.
- **`_forge_bin_check`** — `_forge_bin_check <binary> <quiet|mandatory>
  <forge-label>`. See **Degradation Contract** above for the mode
  semantics.

None of these functions parse a git remote, invoke `gh`/`glab`/`tea`, or
implement a `forge-pr-view`/`forge-auth-status`/`forge-repo-info` verb body
— they are pure, forge-agnostic assembly helpers. `detect-forge` (which
resolves *which* forge is active) and the read/write verbs (which call an
actual forge CLI and populate these builders' arguments from its output) are
separate stories built on top of this contract, not part of it.
