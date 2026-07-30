# Forge Contract

Shared reference for the normalized forge PR/issue field contract and the
degradation convention every `forge-*` verb in `aimi-cli.sh` builds on. This
is the **single arbiter** of the vocabulary below — every later forge verb
(`forge-auth-status`, `forge-repo-info`, `forge-pr-view`, `forge-pr-create`,
`forge-pr-edit`, `forge-issue-view`, `forge-issue-create`, the review-thread
verbs) consumes the field names, the envelope shapes, and the three-way
status convention exactly as documented here. **No sibling verb may
introduce a variant field-name casing (e.g. camelCase `unsupportedFields`)
or a second degradation signal (e.g. a `degradedReason` field alongside
`status`).** If a degraded reason is ever genuinely needed, it is the
`message` field defined in the Three-Way Status Convention section below —
not a new field invented per verb.

**Consumed by:** `aimi-cli.sh`'s shared jq builder functions
(`_forge_build_pr_json`, `_forge_build_issue_json`,
`_forge_build_review_envelope_json`, `_forge_emit_status`,
`_forge_bin_check`) and every forge verb built on top of them. GitHub is the
only adapter shipping in phase 1; this contract is written so GitLab (`glab`)
and Gitea/Forgejo (`tea`) can be added later without changing the shape any
existing caller already depends on.

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
| `error` | The tool itself failed — authentication broken, network unreachable, malformed response, unexpected exit code. `data` is `null`; `message` carries the failure detail. |

`not_found` and `error` must **never** be conflated. `gh pr view --json url`
today exits non-zero for both "no PR exists for this branch" and "gh itself
is broken" — that is exactly the ambiguity this convention exists to remove.
A verb built on top of `_forge_emit_status` must distinguish the two before
calling it, the same way `_verify_creates_one` distinguishes a `missing`
identity from a `git` tool failure before calling `_verify_creates_emit`.

Shape (built by `_forge_emit_status` — see **Shared Builder Functions**
below):

```json
{"status": "found", "data": { "...": "normalized object" }, "message": null}
{"status": "not_found", "data": null, "message": null}
{"status": "error", "data": null, "message": "gh exited 4: authentication required"}
```

`message` is the one and only degraded-reason field in this contract. No
sibling verb may add a second field (`degradedReason`, `reason`, or any
other name) to carry the same information.

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
- **`_forge_build_review_envelope_json`** — builder for the review envelope.
  Flags: `--approved <true|false>`, `--changes-requested <true|false>`,
  `--approvals-count <int>` (all three capability-gated — presence of the
  flag marks support), `--raw <json object>`.
- **`_forge_emit_status`** — `_forge_emit_status <status> [data-json]
  [message]`. `status` must be exactly `found`, `not_found`, or `error`;
  any other value is a caller error (exit 1). `data` is forced to `null`
  unless `status == "found"`; `message` is forced to `null` unless
  `status == "error"` — this prevents a caller from accidentally carrying a
  stale value across the wrong branch of the three-way outcome.
- **`_forge_bin_check`** — `_forge_bin_check <binary> <quiet|mandatory>
  <forge-label>`. See **Degradation Contract** above for the mode
  semantics.

None of these functions parse a git remote, invoke `gh`/`glab`/`tea`, or
implement a `forge-pr-view`/`forge-auth-status`/`forge-repo-info` verb body
— they are pure, forge-agnostic assembly helpers. `detect-forge` (which
resolves *which* forge is active) and the read/write verbs (which call an
actual forge CLI and populate these builders' arguments from its output) are
separate stories built on top of this contract, not part of it.
