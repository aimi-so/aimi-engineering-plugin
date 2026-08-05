# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A per-repository forge account store path, resolved outside the repository and stable across every worktree.** New internal helper `_forge_account_store_path` in `aimi-cli.sh` returns `<aimi config dir>/forge-account-<key>.json` — one file per repository, under `$AIMI_CONFIG_DIR` / `${XDG_CONFIG_HOME:-~/.config}/aimi` via the existing `_aimi_config_dir` resolver, so a remembered forge account is never committed, never shared with the rest of the team, and never inherited by a sibling repository. The key is the SHA-256 of the repository's absolute git common directory, produced by the same `_default_branch_cache_key` helper the per-repository default-branch cache already uses; no second hashing scheme was introduced.
  - **Keyed on `git rev-parse --git-common-dir`, not `--show-toplevel`.** `--show-toplevel` answers with the *worktree* path, so every `.worktrees/<branch>` checkout of one repository would hash differently and be asked for its account all over again. The common directory is the one `.git` both the main checkout and every worktree share, which is what makes "asked once, remembered thereafter" true for a repository that uses worktrees.
  - **The hashed value is guaranteed absolute before it is hashed.** Bare `git rev-parse --git-common-dir` answers *relatively* — `.git` from a toplevel, `../../../.git` from a sub-directory — so hashing it raw would hand every repository on the machine one shared key whenever the CLI ran from a toplevel, and would also change one repository's key depending on which sub-directory the command ran in. `--path-format=absolute` (git ≥ 2.31) is used first; older git falls back to the bare form joined against the current directory and normalized through `resolve_path`, which produces a byte-identical key.
  - **Outside a git repository the helper returns non-zero and prints nothing** rather than falling back to a hash of the empty string, which would have become a single global "no-repo" store every non-repository caller wrote into. Callers read the non-zero return as "no remembered answer, proceed on the active account".
  - The document at that path is a JSON object **keyed by forge host**, because one repository can carry remotes on more than one host. Writers must read the existing document and merge into it; rebuilding it with `jq -n` would drop every other host's entry, the exact defect fixed in 1.97.2 for `models.json`.

- **`aimi-cli.sh forge-account-select` — ask which forge account a repository writes as once, and be able to change the answer.** One verb owns three operations on the store above: `--record <login>` and `--record-active` persist an answer, `--check` reads it back and decides whether the question is warranted at all, and `--reselect` forgets it. Reselect is a **flag on this verb, not a second verb**. The verb does not prompt — per `commands/references/interactivity.md` the command layer asks and the CLI decides and remembers, because the CLI is invoked with a non-TTY stdin and a prompt implemented inside it would be silently dead under Claude Code. Exactly one mode is required; two modes, or none, exits 1 naming the valid modes. No `--token`, `--identity` or otherwise credential-shaped flag exists, matching every other forge write verb.
  - **`--record-active` stores "always use whichever account is active" as a real answer**, carrying a `mode` discriminator (`{"mode":"active"}` versus `{"mode":"account","account":"<login>"}`) so a later `--check` can tell "the user chose the active account" apart from "the user has not been asked". Encoding that opt-out as an empty account string, or by omitting the entry, is refused on both the write and the read side — neither is distinguishable from absent, which is the one property the answer must not have.
  - **`--check` decides on this repository's own entry, never on the store file's existence.** The store exists the moment the first repository answers, so an existence check would silence every repository afterwards — the shape of the 1.93.1 defect where `models-prompt-check` returned `skip` whenever `models.json` existed even with the current host's sub-table missing. A store that is absent, present without this host's entry, empty, or malformed all yield the ask decision; malformed input prompts rather than skipping silently.
  - **The recorded answer is revocable, and it is the only state.** `--reselect` clears this repository's entry so the very next `--check` asks again, and deleting the store file by hand does exactly the same — there is no companion marker or sentinel that survives the answer's deletion. That is the 1.93.0 defect where the models marker "suppressed the prompt even after the config was deleted, leaving the user silently stuck on all-inherit defaults with no way to re-trigger the prompt short of also deleting the marker", designed against rather than re-shipped.
  - **Every write is read-merge-write; no path rebuilds the document with `jq -n`.** Recording or revoking one host's answer leaves every other host's entry byte-for-byte intact, timestamp and mode discriminator included. `--reselect` is the trap — writing the file back without the entry is the obvious implementation and it destroys every sibling — so it is a `del` merge, not a rebuild. This is the 1.97.2 `detect-models` defect (it "wrote a fresh document via `jq -n`, silently dropping the inactive host's configured models on every invocation") applied to a second multi-entry document.
  - **`--check` has zero side effects** — it creates no store file, creates no config directory, chmods nothing, and leaves a pre-existing store byte-identical. That is the mechanical guarantee behind the agent-mode rule: an auto-selection made under `AIMI_AGENT_MODE`/`CI` is applied for that invocation and never persisted, so one unattended run cannot permanently answer the question for every human afterwards. Persisting is always a separate, explicit `--record*` call.
  - Writes go through a single locked path combining the two precedents already in the file: `roadmap-init`'s `flock` + `mktemp`-then-`mv` atomic swap, and `write_aimi_models_config`'s create-then-restrict-then-write ordering, with `chmod 0600` applied **before** any content is written — load-bearing for a file that names accounts. The current document is re-read inside the lock, so a concurrent writer cannot slip between the read and the write.
  - `--check` also skips, recording nothing, when `AIMI_FORGE_IDENTITY` is set: an explicitly requested identity makes the question moot, matching the file's existing env-over-stored precedence.

- **The forge account question is now actually asked — from the command layer, once per repository, and never answered on your behalf by an unattended run.** `/aimi:open-pr`'s Step 1a and `/aimi:execute`'s phase PR-creation step each show a picker offering "always use the active account", the account your project's git identity points at, any further logged-in accounts, and a free-form `Other`. The selected answer is handed to `forge-account-select`'s record path; the command layer owns the prompt and performs no file I/O of its own. In multi-repo phase runs the question is asked once **per participating repository**, naming the repository so separate prompts stay distinguishable.
  - **Gated on a two-condition AND, so it is asked at most once and only when it matters.** The picker appears only when `detect-interactivity` returns `picker` *and* `forge-account-select --check` returns `decision: "ask"` — that is, this repository has no recorded answer for its own host *and* its git identity genuinely diverges from the active forge account. Every other case proceeds silently on the active account. This is the same shape as the shipped first-run model-selection prompt.
  - **In agent mode the answer is applied for the invocation and NEVER persisted.** Under `--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`, each site auto-selects "use the active account" — which takes no action at all, since that is already the account every forge verb uses — and makes no record call whatsoever, leaving the store byte-for-byte as it was. The transcript says so explicitly: `agent-mode: forge-account auto-selected active account (not recorded)`. This matters because that auto-answer is *also* the permanent opt-out: persisting it would let one CI run silently and permanently answer the question for every human afterwards, who would never be asked and would have no way to discover why — the shape of the 1.93.0 unrevocable-dismissal defect.
  - **Two callers can apply a stored answer but can never ask.** `skills/resolve-pr-parallel/scripts/get-pr-comments` and `resolve-pr-thread` are plain shell scripts with no picker on either host, so a repository whose answer was never recorded runs those two paths on the machine's active account. This is stated in `commands/references/forge-contract.md` rather than left to be inferred; it matches phase 1's degradation posture and is resolved by answering the question once at either ask site.
  - The pickers live in translated command bodies, not in `commands/references/`: reference files are copied verbatim by `install.sh` and skipped by both command-install loops, so a picker written there would reach OpenCode still naming `AskUserQuestion`, a tool that host does not have. `translate_command_body` was sourced in isolation and fed both new picker paragraphs, which came back as `Use the **question** tool`.

## [1.122.0] - 2026-08-04

> Phase 1.2 of forge abstraction: **roadmap-consumer-agreement**. Four defects of one family — a roadmap layer whose consumers disagreed with the roadmap, or with each other, about the same file on disk.

**Why this is MINOR, not PATCH and not MAJOR.** PATCH is excluded because `roadmap-amend-phase` is a CLI verb that did not previously exist, and SemVer makes added functionality a MINOR bump however small the rest of the release is. MAJOR is excluded by this repository's own precedent, stated in the 1.121.0 entry below: 1.92.0 shipped a genuinely breaking change under a MINOR bump with an explicit `### Breaking` disclosure, and MAJOR (1.0.0) is reserved for the one-time repo-wide `tasks.json` schema rewrite. The two behavior changes below alter which phase a run picks and how far a run proceeds, but they remove no verb, rename no field and invalidate no roadmap already on disk. The closest call is `roadmap-init` now refusing a `creates` identity it previously accepted — that is a tightened **write-time** input contract, judging only the phases a call actually writes and leaving every roadmap already on disk untouched, which is what keeps it MINOR rather than breaking.

### Changed

- **`/aimi:execute` with no arguments may now claim a DIFFERENT phase than the same command would have claimed yesterday against the same roadmap.** `roadmap-claim`'s auto mode now ranks dependency-eligible candidates by **remaining work first and numeric id second**, where it previously sorted by id alone. This is the other half of issue #90. A phase reaches `verification_failed` only when every one of its stories completed but its declared artifacts could not be confirmed — so it has zero pending work by construction, and being older it also carries a lower id. Under a plain id sort it therefore won every auto-claim indefinitely while making no progress, and every phase depending on it stayed blocked: a permanent claim sink. Ranking **demotes, it never excludes** — the candidate status set is unchanged and still wide (`pending`/`planned`/`in_progress`/`verification_failed`, each unclaimed), so a zero-work phase is still claimed the moment it is the only candidate, and both crash recovery and the `verification_failed` retry below stay reachable. **What to expect on your next run:** a roadmap holding a stuck phase alongside phases that still have work will now advance to that work instead of returning to the stuck phase, and will come back to the stuck phase once the others are done. A phase that keeps failing keeps its work, so it can starve a stuck phase in auto mode — `--phase <N>` reaches any phase directly and is never ranked.
  - "Has work" is read from each phase's own tasks file, reusing `roadmap-reconcile`'s existing ground-truth classification, now lifted into one shared definition so the two cannot drift. A phase counts as having **no** work only when that file exists, parses, holds at least one story and every story is `completed`; a missing, unparseable or zero-story file all count as having work, so a never-planned `pending` phase is never demoted merely for being unplanned.
  - **`roadmap-claim`'s auto mode and `roadmap-get --next-eligible` no longer disagree about the same roadmap.** They previously applied different eligibility predicates to the same file and could return different answers; both now share one implementation. The caller supplies the array to be judged, which is the one axis on which they still differ deliberately: the claim judges phases whose dead-PID claims have been cleared inside its own lock, while `--next-eligible` judges `.phases` as written, because inferring process liveness is a decision that belongs where the lock is. `--next-eligible` consequently performs one unlocked tasks-file read per phase; a file rewritten mid-read yields "has work", the safe answer.
  - **The end-of-phase prompt moves with it.** `Phase [N] is complete. Plan phase [M] now?` names whatever `--next-eligible` returns, so it too is now work-ranked rather than lowest-id: it can offer a higher-numbered phase ahead of a lower-numbered one whose stories are all complete. When every eligible candidate still has work the ordering collapses to ascending id, which is why this prompt is unchanged for the common case.
- **A phase left in `verification_failed` can now be re-verified by re-running `/aimi:execute`, instead of being permanently stuck.** A phase reaches `verification_failed` when every one of its stories completed but its declared `creates[]` artifacts could not be confirmed — so it has zero pending stories by construction. `commands/execute.md`'s Step 3 saw that zero, released the claim, printed `All stories already complete!` and STOPped roughly 900 lines before **Phase Completion**, the only place creates verification runs. The phase therefore stayed `verification_failed` forever and every phase depending on it stayed blocked, while the verification-failure report told the user to "re-run `/aimi:execute` to re-verify" — the one instruction that could not work. Step 3's zero-pending case now decides one new branch first: when the run is phase mode, the session itself claimed the phase, the phase is not split, and the phase's status **at claim time** was `verification_failed`, it reports the stuck phase and its branch, keeps its claim, skips the wave loop it has nothing to run, and continues straight into Phase Completion, where `verify-creates` re-runs from scratch against every participating repository. Success ends in `completed` plus `handoff.md` plus a released claim; a repeat failure sets `verification_failed` and releases the claim again, so the recovery is repeatable without manual intervention. The claim-at-entry status is captured in Step 1.7's existing claim-JSON extraction because Step 1.7's own `in_progress` transition destroys it moments later. Every other route through Step 3 — flat mode, flat container mode, a phase entered as `pending`/`planned`/`in_progress`, and a split sub-orchestrator — reaches the unchanged message and STOP, with the same claim-release behavior as before. `scripts/test-command-blocks.sh` gains a check asserting the capture site, the full five-condition gate, its position above the release-and-STOP, and that the new branch adds no claim release.

### Added

- **`aimi-cli.sh roadmap-amend-phase` — an existing phase's contract is now correctable through a sanctioned verb.** `roadmap-init` writes a phase's contract once at creation and `--sync` deliberately leaves an existing phase byte-for-byte alone, so a phase whose `creates`/`needs`/`goal`/`successCriteria`/`areas`/`branch` turned out wrong could only be fixed by hand-editing `roadmap.json` — which `guard-runtime-state.py` blocks on the Write/Edit path while redirecting the caller to a `roadmap-*` verb that did not exist. This verb makes that redirect truthful. It amends one phase in place under the same `flock` + `mktemp`-then-`mv` discipline `roadmap-init` uses, merging partially by key presence: a key present replaces that field wholesale, a key absent leaves the stored value — and every other phase, and the document metadata — byte-for-byte unchanged.
  - `branch` is amendable because nothing else writes it for an existing phase, which is why a decimal phase's `null` branch could not be filled in. Amending it rewrites the roadmap field only — it does not move a worktree or git branch an `in_progress` phase already created. `status` and `claim` are excluded because `roadmap-set-status` and `roadmap-claim`/`roadmap-release-claim` already own them; both keys are rejected by name pointing at their owner, as are `id`, `dir`, `slug`, `name` and `dependsOn`.
  - Dropping or renaming a `creates` identity a later phase cites in its `needs` is refused by default, naming every downstream phase and identity and printing the invocation that would authorize the fix. `--retarget-needs "<old identity>=<new identity>"` (repeatable) authorizes it, and the same locked write then replaces every matching downstream `needs` entry with the amended phase's new `creates` entry verbatim, so provider and consumer stay byte-identical. Identity comparison is exact equality via `_cv_identity`, never substring containment.
  - Amended values pass `roadmap-init`'s own gates (same sanitizer and caps, same identity guard, same branch pattern). An amendment that would duplicate another phase's `creates` identity is refused, because `validate-contracts` hard-fails on that outside `--agent-mode` and halts `/aimi:plan`. A completed phase whose `handoff.md` omits a newly introduced identity draws one stderr advisory and still writes — repairing an already-completed phase's declared artifacts is a case this verb exists for, so no status gates the amend in either direction.
  - The verb was exercised on this repository's own `forge-abstraction` roadmap while this phase ran: phases 2, 3 and 4 carried `creates` entries written as English prose that `verify-creates` could never resolve, and each was amended to a greppable symbol with the downstream `needs` entries in phases 3 and 4 retargeted in the same locked write. That work changed roadmap data only and shipped no product code.

### Fixed

- **`/aimi:execute` can now run a decimal-numbered phase whose roadmap `branch` is null.** `commands/execute.md`'s **Claim the Phase** step interpolated the raw phase id into the derived branch name, then validated the result against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` seven lines later — a regex with no dot. A phase like `5.5` therefore derived `feat/<feature>-phase-5.5-<slug>`, failed the file's own validation, released the claim and STOPped, making every such phase impossible to execute. Decimal ids are intentional (`roadmap-init` accepts them and builds `.dir` from the raw value), so the fix slugifies the dot to a hyphen at the single point where the branch name is produced: the branch becomes `feat/<feature>-phase-5-5-<slug>`. Every other consumer keeps the raw id — the `<feature>-phase-<id>-tasks.json` paths name real files that carry the dot, and every `--phase` argument must match `roadmap.json`'s own numeric id. An id with no dot slugifies to itself, so integer-id phases keep byte-for-byte the branch names they have today, and a phase with a hand-filled `branch` is still passed through untouched. `scripts/test-command-blocks.sh` gains a check that executes the real derivation block out of `execute.md` against decimal/integer × present/empty-slug fixtures.
- **`/aimi:plan` can now plan a decimal-numbered phase.** `commands/plan.md` had the same defect one command upstream: it built `metadata.branchName` from the raw `${SELECTED_PHASE_ID}`, then validated the result against the same dot-less `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`, with its own Phase 4 failure row instructing "report the invalid branch name and STOP". A decimal phase therefore could not be planned at all, so the `/aimi:execute` fix above was necessary but not sufficient — the phase never got a tasks file to execute. All three derivation shapes now build the branch from a dot-slugified id: the non-split rolling-wave form, the SIDE-axis split (`-frontend`/`-backend`), and the PROJECT-axis split (`-<project-slug>`). The two Phase 4 checklist items that asserted the pre-fix shape were updated to match. Filesystem paths are unchanged and deliberately keep the raw id — `${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json` and both split basenames name real on-disk files that carry the dot, and `commands/execute.md` reads those exact paths with the raw id. Integer-id phases produce byte-for-byte the branchName they did before.
- **`roadmap-init` now refuses a `creates`/`needs` identity that `verify-creates` could never find.** A contract entry whose searched token carries whitespace was accepted at write time and only failed at phase close, with a whole phase already planned and executed against it. The check is mechanical, not stylistic: `verify-creates` finds an artifact either as a tracked path or as a fixed-string `git grep` over tracked non-doc, non-test source, so a multi-word token can only match prose — and documentation, the one place such a phrase plausibly appears, is already excluded from that search.
  - The predicate reduces the entry to its identity (text before the first `(`), strips a leading `METHOD /` using the same seven methods and the same single-space shape `verify-creates` step 2 strips, and refuses what remains if it holds a space, tab, CR or LF. The token judged at write time is therefore byte-identical to the token searched at close time. `POST /api/notifications` is accepted; `POST  /api/x` with two spaces is refused, because that is not the endpoint form and would be searched whole. Nothing else about the identity is judged — not length, not charset, not whether it looks like a path. Identity *strength* stays unjudged, so a bare table name or bare directory is still accepted.
  - **Existing roadmaps are never retroactively refused.** The rule applies only to the phases a call actually writes: every phase in creation mode, and under `--sync` only those whose ids are not already on disk. A `--sync` that re-submits an existing phase leaves it byte-for-byte unchanged and never judges its identities. `roadmap-amend-phase` follows the same boundary at entry level — it hands the checker only the lists that call writes, so amending a phase's `goal` or `needs` no longer trips over a legacy identity in a `creates` list it never touched.
  - Each offending entry reports on its own line naming the phase, the list, the entry verbatim and what to write instead, so an author fixing several at once sees them all in one run. This matters because both `/aimi:plan` call sites downgrade a `roadmap-init` failure to a single warning line and continue.
  - `commands/references/scope-contexts.md` now teaches the single-token rule beside the naming table, states plainly that passing proves shape and never existence, and no longer holds up `DELETE user_sessions` as an example — a form the writer now refuses, and one that was never findable anyway, since real schemas write `DELETE FROM user_sessions`.

## [1.121.0] - 2026-08-04

> Phase 1.1 of forge abstraction: remediation of the review findings raised against phase 1 (1.120.0), which has not yet reached `main`.

### Breaking

**No action is required of anyone upgrading, and the blast radius is zero.** Every field named below belongs to a `forge-*` verb that did not exist before 1.120.0 — and 1.120.0 has never been published. When this section was written the last released version was **1.119.2**; `main` has since shipped **1.119.3** (an `install.sh` fix, unrelated to any forge verb), which this branch has now merged. Neither number changes the argument, because what matters is what `main` does *not* carry: no released version has ever carried 1.120.0, 1.121.0 or 1.122.0. Those release commits are not ancestors of `main`; they are reachable only from this feature branch and its `origin` mirror. So the shapes reshaped below were introduced on an unmerged branch, shipped to no one, and the upgrade path from the last published version is untouched — a consumer moving from 1.119.3 to 1.122.0 never saw 1.120.0's envelopes at all.

This subsection is therefore a disclosure, not a migration notice: it exists so that anyone who *did* build against the branch can see exactly what moved. Two further reasons it does not warrant MAJOR: these verbs are consumed only by this plugin's own command markdown (`open-pr.md`, `review.md`, `validate-bug.md`, `execute.md`) and the `resolve-pr-parallel` skill scripts, all updated in this same release — they are not a slash-command syntax anyone types; and this repository's own precedent, 1.92.0 (2026-05-25), shipped a genuinely breaking change under a MINOR bump with exactly this kind of explicit `### Breaking` disclosure, reserving MAJOR (1.0.0) for the one-time repo-wide `tasks.json` schema rewrite.

- **`forge-pr-view`: the degradation field is renamed `evidence` → `message`.** `forge-contract.md`'s single-degradation-signal rule names `message` as the one human-readable degradation field; `forge-pr-view` was the lone verb still emitting its own `evidence` spelling. `open-pr.md` Step 1b now reports `.message`.
- **`forge-pr-view`: `unsupported_fields` is now always an array on `status: "found"`, never `null`.** It is explicitly `[]` when nothing is gated. Previously it was `null` in that case, so a caller iterating it had to null-check first.
- **`forge-pr-view`: `--include`'s known-field list changed.** `isDraft` and `mergeable` become selectable (they are contract fields and were previously unreachable); the gh-only `reviews` and `comments` are now rejected (they have no contract equivalent and had zero callers outside the test suite). `--include` now validates against the ten contract fields rather than passing names through.
- **`forge-pr-view`: `state` is normalized to the contract vocabulary instead of passed through in gh's uppercase form**, matching what `forge-issue-view` already did. Every `gh pr view` response now routes through the shared `_forge_build_pr_json` builder, so a key gh omitted is distinguishable from a key gh returned as an explicit `null`.
- **`forge-pr-create`, `forge-pr-edit` and `forge-issue-create` now share one write-result envelope, replacing three unrelated shapes.** Previously: a `{url, number, created}` boolean, a status-less `{url, number}`, and a flat `{url, number, status, message}` — and on a PR-verb failure path stdout was silent entirely. All three now emit `{status, data, message}` with the same field names and null-forcing discipline the read verbs use, `url`/`number` nested under `data`, and a write-side status enum of `created | unchanged | degraded`. This reconciles `forge-issue-create`'s separate status vocabulary onto the same axis the read verbs use. `_forge_emit_issue_create_status` is removed. The exit-code contract is unchanged: the PR verbs still exit non-zero on every degraded outcome, and `forge-issue-create` still exits 0 on all of them, preserving `open-pr.md`'s soft-fail contract that a failed backend issue never blocks PR creation.

### Fixed

- **`forge-pr-create` opened a duplicate pull request when its own pre-create lookup broke.** The existing-PR check tested only for `status: "found"`, so `forge-pr-view`'s `status: "error"` — which it deliberately reports *inside* its envelope at exit 0, precisely so a caller can tell "no PR exists" from "the lookup failed" — fell straight through to `gh pr create`. An expired token or a network blip therefore opened a second PR on a branch that already had one, and the `existing_rc` exit-code guard could never catch it because that path does not exit non-zero. The check now branches over all three contract statuses: `not_found` creates, `error` (and defensively any unrecognized status) prints the manual fallback and returns 1 without reaching `gh pr create`, and `found` short-circuits only when the existing PR's normalized `state` is `open`. `state` joined the `--include` list to make that last distinction possible — `gh pr view <branch>` is not state-filtered, so a branch reused after its prior PR was merged or closed used to resolve to that stale PR and could never get a new one.
- **`forge-pr-create` discarded a pull request it had just created when the post-create re-read failed**, printed create-it-yourself instructions for a PR that already existed (guaranteeing a duplicate if followed), and returned 1 — a false failure in `/aimi:execute`'s per-repository loop. Both failure branches now keep the captured url, emit `created: true` at exit 0 with `number: null`, and warn that only the number is unconfirmed. The manual fallback now prints only on paths that run before a url is ever captured.
- **`forge-pr-view` reported `not_found` when the pull request demonstrably existed but `gh pr view` failed.** The `gh pr list` structural probe now runs first and is authoritative: a probe that confirms the PR exists followed by a failing `gh pr view` resolves to `error` carrying that command's own stderr — including when the stderr uses gh's own not-found wording, which can no longer outvote the structural confirmation.
- **`resolve-pr-thread` decided whether a degradation was fatal by substring-matching `.message` prose.** It now compares `.reason` for exact equality against `no_adapter`, so a message that merely mentions no-adapter wording can no longer be misread as non-fatal, and an absent `.reason` from an older cached CLI fails closed.
- **`detect-forge` and the nine `forge-*` verbs no longer require an `.aimi/` directory to exist.** They were dispatched after `find_aimi_root`, which hard-exits when no `.aimi/` is found anywhere up the tree and `cd`s the process into the `.aimi/` parent — neither appropriate for verbs that touch only git, an optional forge CLI and jq. Two consequences are closed: a repository with no `.aimi/` anywhere (the `resolve-pr-parallel` skill's `get-pr-comments`) now gets a parseable envelope instead of a bare exit 1, and in a multi-repo layout a verb invoked from inside a child repository with no `--project` now resolves that child instead of erroring out from the non-git parent. Each of the ten verbs now runs its own `check_jq`, since `main()`'s single check also sat behind `find_aimi_root`. One accepted parity change: a stray `--help` on a forge verb now reaches that verb's own arg parser rather than the universal `--help` intercept, matching `detect-models`' pre-existing behavior.

### Security

- **`open-pr.md` Step 5c asked the model to repaste the assembled PR body into a `<<'PR_BODY_EOF'` heredoc, so a commit message containing a line equal to `PR_BODY_EOF` closed the heredoc early and ran every following line as a shell command in the operator's session.** The body is assembled from commit messages and the diff — repository content, not operator input — and the delimiter was published in the command file, so it was not even a guess. Step 5c now retypes only `PR_NUMBER` (a forge-issued integer), validates it against `^[0-9]+$`, and re-reads the body through `forge-pr-view --pr "$PR_NUMBER" --include url,number,body`. A returned `.pr.number` that disagrees with the retyped one is handled exactly like `not_found`/`error`. Step 5b's three echo lines that published the body for that repaste are gone.
- **`_resolve-cli.sh` Layer 0 accepted a *relative* `AIMI_PLUGIN_DIR`, so `"$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"` resolved against the caller's working directory** — any repository shipping its own executable `scripts/aimi-cli.sh` got to run it. `cli-path-resolution.md`'s four documented guards (non-empty, absolute, directory exists, executable) now apply to that branch and to the `CLAUDE_PLUGIN_ROOT` branch, and Layer 2's glob result is validated the way Layer 1's cached path already was.
- **`review.md`'s Detect Target Type interpolated `$ARGUMENTS` into a `forge-pr-view` command line with no validation.** A digits-only gate now runs in the *same* bash block as the interpolation — each block runs in its own shell, so a gate in an earlier block cannot protect a later one. It uses `case` rather than `grep -qE`, which matches line by line and would accept a multi-line value whose first line is digits. The URL branch re-enters that gated block instead of describing a parallel unguarded call.
- **`forge-pr-edit` treated an omitted `--body` identically to an empty one, and `gh pr edit N --body ""` blanks a description** — a caller that forgot the flag silently destroyed the pull request body. The verb now tracks whether the flag was seen, refusing omission while keeping an explicit `--body ""` as a deliberate clear.
- **`AIMI_FORGE_TYPE` made `_detect_forge` emit a JSON `null` host, which `jq -r '.host'` renders as the four-character string `"null"`** — non-empty, so it survived every downstream check and reached `gh auth status --hostname null`, whose refusal read as a confirmed `authenticated: false`. Fixed at the root cause with `.host // empty` at the two reads that lacked it, which also revives `_forge_pr_write_print_manual`'s own already-correct fallback (dead because `"null"` is truthy in jq).
- Hardening: the userinfo-redaction scheme match is now case-insensitive, so an uppercase `HTTPS://` remote is stripped like a lowercase one.

### Added

- **A machine-readable `reason` enum on the read verbs' degradation envelope, so no caller has to grep `message` prose.** `_forge_emit_status` gains a fourth positional argument validated against a closed four-value set — `no_adapter | cli_missing | not_authenticated | cli_failed` — forced to `null` off the error branch exactly like `message`, and passed by every error call site in `forge-auth-status`, `forge-issue-view`, `forge-pr-review-threads` and `forge-resolve-review-thread`. `not_authenticated` is determined structurally, by calling `_forge_auth_status_github` and reading its `.authenticated` field, never by pattern-matching a failing gh invocation's stderr wording, which reworks between releases and varies by locale. `commands/references/forge-contract.md`, the single arbiter, is amended to permit exactly this one enum alongside `message` — a value to switch on versus prose for a log — while keeping the prohibition on variant field-name casing and on any further ad-hoc degradation field.
- `forge-contract.md` gains a Write-Verb Status Convention section, a `forge-pr-view` Envelope section, and a canonical list near the top naming all four result-envelope shapes the file defines, so a phase-2/3 adapter author reads one list instead of inferring it from ten verb bodies.

### Changed

- **A completed phase no longer pushes a repository's branch to `origin` when no forge adapter can open the resulting pull request — a deliberate behavior change, and stricter than the gate it replaces.** Phase 1 moved `/aimi:execute`'s phase-mode PR call onto `forge-pr-create`, which correctly took the CLI-presence check with it, but left the `git push -u origin` one line above with no check at all — so a user with no forge CLI installed, or any GitLab/Gitea remote (phase 1 ships no write adapter for either), got a branch published where they previously got manual instructions and no push. The push is now gated per repository on `forge-auth-status` reporting `status: "found"`, which is true only when the remote resolves to a forge with a working write adapter *and* that adapter's CLI is on `PATH` — the same two conditions `forge-pr-create` gates its own write on. Note this is narrower than the pre-phase-1 gate, which tested only whether a GitHub CLI existed: a GitLab or Gitea remote on a machine that happened to have one installed used to get its branch pushed and only fail at PR creation. It no longer does, because whether a branch reaches `origin` should not depend on an unrelated binary being installed. A skipped repository prints its own recovery block instead — its label, the container-scoped `git push -u origin` command, and the `base...head` compare range — so the outcome is one pasted command, not a lost push. The check extends by itself: a future GitLab or Gitea write adapter makes those remotes report `found` with no change to `execute.md`.
- **Every `forge-pr-create` failure in a completed phase now prints a line naming the repository it belongs to.** `_forge_pr_write_print_manual` has no repository context and so names none, which meant a multi-repo phase with N failing repositories emitted N indistinguishable stderr banners — the loop itself printed nothing attributable, contradicting the per-repository failure isolation documented directly beneath it. The loop now echoes one labelled line per failing repository alongside that banner.
- **Fewer subprocesses per forge call.** A new jq-free `_detect_forge_type` classifier, memoized per working directory (never globally — sibling repositories under one multi-repo root must not leak forges into each other), serves the four call sites that read only `.forge`; the five that also need host/remoteUrl keep the full `_detect_forge` call. Measured: a `forge-pr-create` run that creates a new pull request drops from 3 forge derivations to 1, and a `not_found` `forge-pr-view` drops from 2 gh calls to 1. A *found* `forge-pr-view` branch lookup rises from 1 gh call to 2 (`gh pr list` then `gh pr view`) — the accepted trade-off for the correctness fix above.

### Known follow-up

- **`scripts/command-blocks-baseline.txt` grew from 37 grandfathered findings to 44.** The seven new entries are *pre-existing* debt in `brainstorm.md` (2), `design/polish.md` (2), `execute.md` (1), `open-pr.md` (1) and `plan.md` (1), made visible only because this release added `test-command-blocks.sh`'s Check 5, which detects the whole class of "a bash block interpolates `$ARGUMENTS` without validating it in that same block". `review.md`'s own instance — the one with a real security consequence, since it fed a PR identifier straight to a forge command line — is fixed, not baselined. The seven differ in severity: each parses `$ARGUMENTS` to extract a flag or phase id and hands the result to `aimi-cli.sh`, which validates it again on its own side. They are recorded rather than blanket-patched because closing them means editing four command files, one read per block; that is a follow-up, not part of this remediation.
- **`_forge_pr_edit` carries the same post-edit re-read-discards-url defect that `forge-pr-create`'s was fixed for above.** It is deliberately left untouched here and flagged for a later story.

## [1.120.0] - 2026-07-31

### Changed

- **Under OpenCode, forge write calls no longer prompt for per-call confirmation — a real broadening of unattended write consent, accepted deliberately.** `forge-pr-create`, `forge-pr-edit`, and `forge-issue-create` used to run as a bare `gh pr create`/`gh pr edit`/`gh issue create` invocation inside a command body, which fell outside `opencode.json`'s `permissions.bash` allowlist and prompted for approval every time. Those calls now run inside `aimi-cli.sh`, which the allowlist already covers with a blanket `aimi-cli.sh *` rule installed for CLI subcommands generally — so they stop prompting. This is intentional: a confirmation gate on these verbs, or a narrower `forge-*`-specific allowlist entry, would break unattended `/aimi:execute`, which is the plugin's purpose, so neither was added. No `gh *` permission entry exists anywhere in `install.sh`. See `docs/opencode.md`.
- **`open-pr.md`'s pre-flight checks no longer conflate a broken forge check with a confirmed negative answer.** Previously, any failure of `gh auth status` was reported identically to "not authenticated," and any failure of `gh pr view` was reported identically to "no PR exists yet" — either misdiagnosis could let a broken token or a network failure proceed straight into creating a duplicate PR. Both checks now branch on `forge-auth-status`'s and `forge-pr-view`'s three-way `found`/`not_found`/`error` status (`commands/references/forge-contract.md`) and surface a distinct, accurate message when the check itself could not run, instead of silently treating that as a definitive answer.
- `open-pr.md`'s standing `PR_URL`/`PR_BODY` defect is fixed as part of this migration: Step 5b previously never captured `gh pr create`'s output, so Step 5c read variables nothing had assigned. `forge-pr-create`'s JSON response is now captured and both values are threaded through correctly.
- `docs/opencode.md` documents the OpenCode write-consent change above. `docs/commands.md` documents `--base <branch>` on `/aimi:execute` and `/aimi:next` (previously only in `README.md`), and now states that `/aimi:open-pr`, `/aimi:review`, and `/aimi:validate-bug` detect the forge from the git remote instead of assuming GitHub.

### Added

- **`detect-forge` and eight `forge-*` verbs in `aimi-cli.sh`** — `forge-auth-status`, `forge-repo-info`, `forge-pr-view`, `forge-pr-create`, `forge-pr-edit`, `forge-issue-view`, `forge-issue-create`, and two review-thread verbs (`forge-pr-review-threads`, `forge-resolve-review-thread`) — a normalized PR/issue field contract with a three-way `found`/`not_found`/`error` status convention and a documented degradation contract. GitHub is the only working adapter shipped in phase 1; GitLab and Gitea are designed for behind the same contract but not implemented yet. See `plugins/aimi-engineering/commands/references/forge-contract.md`.
- `open-pr.md`, `review.md`, `validate-bug.md`, `execute.md`'s phase-mode PR-creation loop, and the `resolve-pr-parallel` skill scripts are migrated onto these verbs — no command file makes an executable `gh` call directly anymore; every `gh` invocation now lives inside `aimi-cli.sh`.
## [1.119.3] - 2026-08-01

### Fixed

- **`install.sh` wrote OpenCode Bash auto-approval rules under `permissions` (plural), the opencode 0.x schema key; opencode 1.x rejects unknown top-level keys at startup with `Unrecognized key: permissions`, aborting launch before any session starts.** `install_permissions()` and `uninstall_permissions()` now use the singular `permission` key throughout: the heredoc JSON fragment, the `jq` merge (`.permission = ((.permission // {}) * $perms.permission)`), the `python3` fallback (`cfg.get('permission', …)`, `perms['permission']`, `cfg['permission']`), and the uninstall path (`grep '"permission"'`, `del(.permission)`, `cfg.pop('permission', None)`). Verified against the canonical schema at <https://opencode.ai/docs/permissions> and against opencode 1.18.10, where the singular key loads cleanly and the plural key is the rejection the user reproduced. Comments and human-readable log strings (`ok "Removed permissions from …"`) are unchanged — they are prose, not schema keys.
- **Known limitation, accepted as residual risk:** a reinstall over an `opencode.json` that already carries the stale plural `permissions` key from a prior buggy install does **not** self-heal. The installer's idempotency guard greps for the `"git *"` rule, finds it under the old plural key, and returns early without ever writing the singular key or removing the plural one — so the startup crash persists across reinstalls. Affected users must delete the `permissions` (plural) block from `~/.config/opencode/opencode.json` by hand once; a migration step in `install_permissions()` was deliberately deferred. Fresh installs are correct.

## [1.119.2] - 2026-07-30

### Fixed

- **1.119.1's command-position anchoring regressed real detections: a `git commit` or `git worktree add` preceded on the same statement by an environment assignment, a wrapper command, or a body-opening keyword stopped being guarded at all.** `[^\S\n]*` after the anchor consumes whitespace only, so any token between the separator and `git` broke the match — and the failure was silent, in the fail-open direction: the commit on the protected branch simply happened, with no message. Verified missed by 1.119.1 and detected again now: `GIT_AUTHOR_DATE=2020-01-01 git commit` (the canonical way to backdate a commit, and an everyday git idiom), `sudo git commit`, `env FOO=1 git commit`, `time`/`nohup`, `for f in a b; do git commit; done`, `if ok; then git commit; fi`, `else` bodies, `{ git commit; }` brace groups, and `! git commit`. `_CMD_START` is now `_CMD_ANCHOR` (unchanged) plus `_CMD_PREFIX`, a bounded run of those tokens; the four guard regexes concatenate `_CMD_START`, so none of their own definitions changed. Issue #82 stays closed — no prefix token can match `grep`, `echo`, `cat`, `find`, `jq` or `awk`, and every token requires trailing whitespace, which is what keeps `find … {} \;`, `jq '{a: 1}'`, `awk '{print $1}'`, brace expansion `{src,test}`, `${VAR}` and `!=` out of the guard. Confirmed a strict superset over all 802 string literals in the hook test suite: 28 detections gained, zero lost.
- **This entry supersedes the environment-assignment and wrapper clause of 1.119.1's "Known limitation" bullet below** — that class is now detected, and the sentence claiming `\s*` consumes whitespace only is no longer the shipped behavior. The rest of that bullet (`bash -c`, subshell, command substitution, single `&`, non-`-C` option forms) still stands.
- **Known limitation, accepted as residual risk:** a wrapper outside the four covered (`timeout`, `xargs`, `command`, `exec`, `nice`, `stdbuf`) or one carrying its own option token (`sudo -u alice git commit`, `env -i git commit`, `time -p git commit`) is not detected — covering those needs another nested quantifier, and the backtracking surface is not worth it. Also undetected: an assignment whose value holds a `$(...)` substitution containing whitespace, `VAR="a"b`, prefix runs deeper than six tokens, and `case` arms or bodies opened by `(`. Note that `FOO=a&b git commit` not matching is correct rather than a gap — bash parses it as `FOO=a &` followed by `b git commit`, so no commit runs.

### Changed

- `_GIT_WORKTREE_ADD_RE` gained the leading `\b` its three sibling regexes already carried. Provably a no-op — the anchor already guarantees the word boundary — but the asymmetry had been flagged by four separate reviewers as an inconsistency inviting a reader to hunt for a reason that does not exist.

## [1.119.1] - 2026-07-30

### Fixed

- **`pre-bash-dispatcher.py`'s commit guard and worktree-add guard matched `git commit`/`git worktree add` as a bare substring anywhere in a Bash command string, so a commit message or comment merely *mentioning* either phrase — with no invocation present — triggered the guard (issue #82).** Both `_GIT_COMMIT_RE` and `_GIT_WORKTREE_ADD_RE` are now anchored to command-start position via a shared `_CMD_START` lookbehind (start of string, or immediately after `;`, `&&`, `||`, `|`, or a literal newline — regexes are never compiled with `re.MULTILINE`), so only a genuine invocation matches, not an incidental mention. `git -C <path> commit`/`git -C <path> worktree add` gained their own anchored `_GIT_C_COMMIT_RE`/`_GIT_C_WORKTREE_ADD_RE` variants (quoted-or-bare `-C` path token), closing two pre-existing gaps: `main()`'s routing gate previously never dispatched a `git -C <path> commit` invocation to the commit guard at all, and no `-C` variant of the worktree-add guard existed. A heredoc body is stripped from the detection copy before either family of regexes runs (`_strip_heredocs`, fails closed to the original unstripped string on any internal error), so a commit message authored via `<<EOF ... EOF` no longer feeds guard detection.
- **`effective_cwd` could not resolve the quoted `git -C "<path>"` form the guards had just learned to detect, so every quoted `-C` invocation failed open.** The detection regexes accepted a quoted path while `hook_utils.effective_cwd` still captured it with a bare `\S+`, keeping the opening quote (and stopping at the first space inside it). The resulting path resolved to nothing, `git rev-parse` failed, the branch read as empty, and — because an empty branch is not in the protected set — the commit was allowed. This affected *any* quoted `-C` path, not only paths containing spaces. Both `effective_cwd` extractors (`git -C <path>` and the leading `cd <path> &&`) now share one quoted-or-bare path token with the detection regexes, so a shape that is detected is also one whose target directory can be resolved.
- **The `_CMD_START` anchor scanned quadratically over runs of blank lines, which could exhaust the hook timeout and disable the guard entirely.** A newline is both an anchor and a `\s` character, so the trailing `\s*` let every position inside a whitespace run start a match and then backtrack across the remainder — roughly 1.4 s of CPU on 4,000 blank lines and growing with the square, against a 60 s hook timeout after which a `PreToolUse` hook can no longer emit a denial. The trailing run is now `[^\S\n]*` ("whitespace except newline"), which is verdict-identical to `\s*` because each newline already has its own lookbehind branch. Note for future readers: `[ \t]*` is *not* an equivalent narrowing — it silently stops detecting a command prefixed by a carriage return, vertical tab, or form feed, and a regression test pins this.
- **Anchoring the regexes removed their leading literal, which CPython's `re` uses to skip ahead, so the six-branch alternation was evaluated at every offset of every Bash command the hook saw.** `main()` now short-circuits on `"git" not in command` before any regex runs — safe because every detection regex requires that literal and `_strip_heredocs` only ever removes whole lines.
- **Known limitation, accepted as residual risk:** command-position anchoring deliberately does not detect `git commit`/`git worktree add` invocations wrapped in `bash -c '...'`, inside a subshell `(...)`, produced via command substitution, chained with a single `&` (background) rather than `&&`, embedded in an `if`/`then` or loop body, or preceded on the same statement by an environment-assignment or wrapper prefix (`GIT_AUTHOR_DATE=… git commit`, `env`, `sudo`, `time`, `nohup`). Option forms other than `-C` — `git -c key=value commit`, `git --git-dir=… commit` — are likewise undetected. These are all forms the prior unanchored regex caught only by accident, alongside every false positive it produced. Closing the quote-wrapped cases would require treating a quote character as a command-start anchor, which reopens issue #82's false-positive class; the trade-off is intentional and documented here rather than silently narrowed.

## [1.119.0] - 2026-07-29

### Added

- **`aimi-cli.sh resolve-base-branch <name> --default-branch <branch> [--base <branch>] [--project <path>]` — the single source of base-branch selection for both the inline (`setup-branch`) and container-creation paths (issue #78).** Prints `{base, reason, currentBranch, defaultBranch, promptNeeded}` without performing any git mutation, `reason` one of `explicit-base`, `target-exists`, `detached-head`, `default-branch`, `stacked-on-current`. `base` prefers the `origin/<name>` remote-tracking ref over the bare local name when the fully-qualified ref exists on origin, falling back to the local name when offline or local-only — with one deliberate exception: `stacked-on-current` always keeps the bare local ref, because stacking exists to inherit the local tip and preferring origin there would drop every commit made since the last push. Both the origin probe and the target-exists probe match the full ref (`refs/heads/<name>`) rather than a pattern, so a repository carrying `team/main` but no `main` no longer yields an `origin/main` that does not resolve. The merged check matches whole lines literally, so a branch named `feat.x` is no longer misread as the merged `feat/x`. `promptNeeded` is true only for `stacked-on-current`. `cmd_setup_branch` now delegates its own base-selection logic to this same helper rather than carrying a second copy of it, so the two paths land on the same commit — asserted by a regression test that compares `git rev-parse` output, not just the two paths' labels.
- **`--base <branch>` on `/aimi:execute`**, parsed out of `$ARGUMENTS` in Step 0 the same way `--phase` already is, bringing it to parity with the flag `/aimi:next` already had. It threads through to `resolve-base-branch` as an explicit override, giving an escape hatch to name the base outright instead of relying on the stacking prompt or reshaping the working tree first.

### Fixed

- **Issue #78: container-mode execution no longer silently branches from the default branch when the checked-out branch carries unmerged work.** An unset base used to mean "stack on the current branch" on the inline path but "use the default branch" in container mode, so the same story could branch from two different commits depending only on which path executed. Flat Container Mode, Per-Project Branch Setup, the paired-split loop, the phase container, and `/aimi:next` all now resolve through `resolve-base-branch` and agree with the inline path — five call sites in total, including the phase container, which the original issue did not name. Separately, in multi-repo layouts the base is now selected per child repository instead of being skipped wholesale: Step 1.6's Early-Skip Guard, which previously left the base unset for every repo in the layout the moment more than one repo was detected, is removed, and each project group resolves and prompts (or logs, under the agent path) independently, naming its own repo.
- **Containers were also being cut from a stale local default branch even immediately after a successful fetch.** `worktree-manager.sh` resolves its `--from` argument against a local ref, while container creation was comparing against the bare local default branch name — so a fetch that updated `origin/<default>` had no effect on what a freshly created container actually branched from. `resolve-base-branch`'s origin-over-local preference (above) closes this for the container path the same way it does for the inline one, for every reason except `stacked-on-current`, where the local tip is the correct base by definition.
- **`/aimi:execute --base` and `/aimi:next --base` are parsed and validated in one shell, and the parsed value is echoed.** Both commands previously assigned the flag in one ` ```bash ` fence and validated it in a second one. Each fence is its own shell, so the validation tested an unset variable, matched nothing, and passed vacuously — and the value never reached the call sites that consume it, leaving the flag inert while appearing to work. Parsing, validation and a hard `exit 1` on a malformed value now live in a single block that echoes the result, and every later block that reads `$BASE_BRANCH` re-assigns it from that echoed value, the same way Step 0.9 Pass 2 re-assigns `SPLIT_PLAN`.

### Changed

- **Container creation and reuse now report the resolved base branch and the reason it was chosen, at every point a container is created or reused** — Flat Container Mode, Per-Project Branch Setup, the Phase-Mode Paired Split loop (one line per split record naming its root, branch, and resolved base/reason), and `/aimi:next`'s own create-or-reuse call, whose successful path previously reported nothing: only a failure surfaced `create`'s captured output, so the base never reached the reader on a successful create or reuse.

## [1.118.0] - 2026-07-28

### Added

- **Phase mode now runs across a multi-repo layout: one phase container and one phase branch per participating repository, never a single pair for the whole layout (resolves GitHub issue #73, `aimi-so/aimi-engineering-plugin`).** `/aimi:execute`'s Step 1.7 **Create Phase Containers Per Project Group** derives one project group per participating repository — resolved via `git -C rev-parse --show-toplevel` and `detect-default-branch --project`, collision-checked on `(toplevel, branch)`, the same mechanism the flat flow's Step 0.9 Pass 1 already used — and creates or reuses `PHASE_CONTAINER_PATHS[group_key] = <repo toplevel>/.worktrees/<phase branch>` for each one, documented in `commands/references/container-execution.md`'s new **Phase Container Paths Per Project Group** section. Split detection now runs *before* container creation, so a phase's own full-stack split routes each active member to its own repository. A split member's worktree now roots at its own repository (`SPLIT_ROOT`/`SPLIT_TOPLEVEL`, carried as one JSON object per line in `SPLIT_PLAN` rather than tab-delimited, since a tasks-file path may contain spaces) instead of nesting under a single container that never resolved for a non-root repo. Merge and cleanup run once per repository — grouped from `SPLIT_PLAN`'s own distinct toplevels, sequentially, each against that repository's own phase-branch container — and a conflict names the specific repository while reporting every sibling repository's own status. Step 4's wave loop, previously pinned to a single scalar for every group in phase mode, now reads the per-group `PHASE_CONTAINER_PATHS[group_key]` map (falling back to the scalar only for a Phase-Mode Paired Split sub-orchestrator, which never populates the map). Creates verification calls `verify-creates` once per participating repository and unions the verdicts — an identity verifies for the phase when *any* repository verifies it, and is missing only when *every* repository reports it missing, so an artifact landing in whichever sibling repository actually owns it no longer blocks phase close; a tooling error in any one repository's call still dominates and routes the whole phase to the existing tooling-failure path. Mark Phase Completed stops each repository's own dev server (previously only `$AIMI_ROOT`'s, silently orphaning every other repository's server) and lists one repository/branch line per participating group. Offering a pull request now pushes and opens one PR per participating repository, resolving each one's own default branch fresh rather than assuming a single `$DEFAULT_BRANCH`. With exactly one participating repository — every existing single-repo phase — every one of these loops runs exactly once against exactly today's path, byte-identical to before.
- **Multi-repo phase and flat splits both require the PROJECT axis: `metadata.splitGroup.project` is the single source of routing truth.** Every story in a multi-repo plan needs its own `project` field; `story-merge`'s PROJECT-axis writer (1.116.0) already stamps `splitGroup.project` on each split file, and `/aimi:execute` now reads it in phase mode the same way the flat flow already did. Documented in a new "Multiple repositories" section in `README.md`, root `CLAUDE.md`, and `docs/roadmaps.md`, and in `plugins/aimi-engineering/CLAUDE.md`'s `splitGroup` schema notes. `docs/roadmaps.md`'s "What this does not do" section previously stated "Roadmap mode is not supported in a multi-repo layout" — the roadmap lifecycle operations (`roadmap-claim`, `roadmap-set-status`, `roadmap-write-handoff`, `roadmap-reconcile`) never made a git call and never had this limitation; that sentence is removed as stale documentation, not as a behavior change.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** Per-repository phase containers are new capability — squarely "new commands, skills, or features" under `plugins/aimi-engineering/CLAUDE.md`'s Versioning Requirements. No command's flags or verb names moved: `/aimi:execute`'s own invocation, and `detect-default-branch`, `detect-parent-branch`, and `split-detect`'s arguments and JSON return shapes, are all unchanged. Two changes narrow existing behavior rather than adding to it, and neither rises to "breaking changes to command syntax or output format." First, the phase-mode multi-repo guard, which previously refused *every* phase claimed under a non-git `AIMI_ROOT` unconditionally, now refuses only two genuinely unroutable residue cases — this is a loosening (more phases now run) with corrected prose on the narrow refusal path that remains, not a syntax change to any command a user types, since `/aimi:execute` takes no flag that controls this. Second, `split-detect`'s new `mode: "none"` + `degradedReason` outcome for an unmarked legacy pair under a non-git `AIMI_ROOT` is an additional value within its existing return shape (`{mode, anchor, members, activeCount, total, degradedReason}`, unchanged from 1.116.0), not a new shape — and the case it now refuses previously resolved silently to routing key `"."` and then failed downstream with a bare `fatal: not a git repository` (issue #73), so no caller that worked before stops working; a caller that previously failed opaquely now fails with a diagnosis instead. This is the same shape of change 1.116.0 and 1.117.0 both shipped as MINOR: an internal CLI verb invoked by `/aimi:execute`, not typed directly by a user, whose verdict was wrong or unreachable.

### Fixed

- **`_resolve_default_branch`'s offline fallback and its `Error: Could not detect default branch` path were both unreachable, and had been since the verb was added.** Under `set -euo pipefail`, `branch=$(git remote show origin 2>/dev/null | sed -n '...')` — with no network, or no configured remote — returned a non-zero exit from the pipeline itself, which aborted the whole function (and the script) with a silent **exit 128** before the `[ -z "$branch" ]` offline-`symbolic-ref` fallback, or the final error message, could ever run. `detect-default-branch` and every caller of `_resolve_default_branch` (including the new per-repository resolution below) could fail with no diagnostic the moment a repository had no reachable remote. Both assignments now suffix `|| branch=""` so a failing pipeline clears the variable instead of exiting the shell, making both the offline path and the error path reachable for the first time.
- **The default-branch cache was a single shared file under `AIMI_ROOT/.aimi/default-branch`, so `detect-default-branch --project <repo>` returned whichever repository resolved first, silently, for every sibling repository asked about afterward.** In a multi-repo layout this meant the second child repository's own default branch was never actually read — it inherited the first repository's cached value — and `worktree-manager create --from` then failed with `fatal: Not a valid object name` when that inherited branch name did not exist in the second repository. The cache is now keyed per repository toplevel (`default-branch-<hash-of-toplevel>`, SHA-256 when available, a portable slugified fallback otherwise), so each repository's resolution is independent. `clear-state` now removes every `default-branch-*` file instead of the one old shared name.
- **`split-detect` now refuses an unroutable legacy `-frontend-tasks.json`/`-backend-tasks.json` pair instead of silently reporting routing key `"."`.** When neither file in the pair carries a `metadata.splitGroup` marker and `AIMI_ROOT` is not a git repository, the pair previously resolved to the root group `"."` — a routing key with no repository underneath it to execute in once a caller acted on it. `split-detect` now detects this exact combination and returns `mode: "none"` with a `degradedReason` naming the layout and instructing a re-plan with `--split full-stack` so every story carries its own `project`. This is a query, not a gate: it still exits 0.
- **The phase-mode multi-repo guard's own suggested workaround could not work, and is corrected.** The guard's refusal message told users to "run `/aimi:execute` without `--phase`" — but `--phase` never controlled phase mode (phase mode is detected from a `roadmap.json` sibling, not from a flag), and even if it had, the flat flow's `split-detect` scope is depth-1 (`.aimi/tasks/*-tasks.json`), so it cannot see files inside a phase directory at all. That workaround text is removed. The guard itself is narrowed from a blanket refusal to the two cases that remain genuinely unroutable (see Added, above), and the refusal message for each names the specific condition split-detect or the phase's own tasks file surfaced, plus the one workaround that actually works — running from inside a single repository with its own `.aimi/` directory — captioned honestly with the cost it carries (a separate roadmap per repository, outside the shared claim/lifecycle).

## [1.117.0] - 2026-07-28

### Added

- **`aimi-cli.sh verify-creates` — phase-closure creates verification moves out of executable command prose and into the CLI, where the test suite can reach it.** `/aimi:execute`'s Creates Verification section carried five hand-written steps built on `[ -f "$PHASE_CONTAINER_PATH/$identity" ]` and a bare `git grep -l -F` over the whole tracked tree, first hit wins — two lines no Bash suite could execute, answering "does this name appear anywhere?" when the question is "was this built?". `$AIMI_CLI verify-creates --feature <slug> --phase <id> [--dir <container-path>]` now answers it once and prints one JSON object per `creates[]` entry: `{identity, status, method, evidence, gitStatus}`, where `status` is `verified` | `missing` | `error` and `method` is `"path"` | `"text"` | `null`. Four deterministic steps run per identity, with no dispatch on identity kind: **(1)** a tracked-path check via `git ls-files`, which matches a **directory** as well as a file; **(2)** extraction of a leading `GET`/`POST`/`PUT`/`PATCH`/`DELETE`/`HEAD`/`OPTIONS` token, so `POST /api/notifications` is searched as `/api/notifications` — route code contains the path and never the method-plus-path literal, so without this step excluding documentation would turn every endpoint-kind phase into `verification_failed`; **(3)** a `git grep -n -I -F` over tracked source with documentation, tests and `.aimi/` excluded, bypassed entirely when the identity is itself documentation (`docs/api/notifications.md`), because there the docs page **is** the artifact; **(4)** a filter dropping hits that are only a `TODO`/`FIXME`/`XXX`/`HACK` marker inside a comment. It is a **query, not a gate**: producing a verdict array exits 0, including an array in which every entry is `missing`, so a caller loops over the result instead of branching on the exit status. Non-zero is reserved for real errors — unknown flag, absent or non-numeric `--phase`, absent or malformed `roadmap.json`, a `--dir` that is not a directory. **git exiting above 1 becomes `status: "error"` carrying the code, never `"missing"`** — a tool failure is not an absent artifact — and `/aimi:execute` takes a separate branch for it: the phase is left `in_progress` with its claim released rather than transitioned to `verification_failed`, because reporting that a phase failed to deliver when git is what broke blocks the next phase on evidence nobody gathered. A `missing` verdict names the file and line that was found and rejected, and why. Measured against nine fixture repositories: the procedure this replaces was wrong in five of them, the new one in none. Covered by 88 assertions, one isolated git repository per row of the matrix, each pinning status **and** method so a right verdict reached through the wrong step still fails.
- **The exclusion list uses the long `:(exclude)` pathspec form for every pattern, and that is load-bearing rather than stylistic.** The short `:!` form is not interchangeable: git reads the character after the colon as pathspec magic, so `':!__tests__/*'` aborts the whole invocation with `fatal: Unimplemented pathspec magic '_'` and **exit 128**. On the code path this replaces that would have returned empty and marked **every artifact of every phase** missing — a silent, total failure with no error surfaced anywhere. It is recorded here because it is invisible in a diff: a dedicated assertion pins git's exit status at or below 1 rather than merely checking the verdict, and every pattern is written long-form so no future edit reintroduces the short form by copying a neighbour.

### Changed

- **Behavior change users will notice: a phase whose only evidence is a mention now FAILS Creates Verification where it previously passed.** Three classes of "evidence" used to close a phase and no longer do — the declared name appearing **only in documentation**, **only in a test file**, or **only in a pending `TODO`/`FIXME`/`XXX`/`HACK` comment**. Each of those is a description of the work, or a note that the work is still owed; none of them is the work. A fourth and worse case closes with them: a project that had **committed its own `.aimi/` directory** verified every artifact of every phase unconditionally, because the identity was found inside the tracked `roadmap.json` that declared it — the phase verified itself, and no `creates[]` entry in such a project has ever been checked against real code. This is a deliberate loss of passes, not a tightening at the margins. Its reach is bounded, though, and the bound is worth stating precisely: creates verification runs **only at the moment a phase closes**, and a phase already at status `completed` is not claimable — `roadmap-claim` refuses it with `phase status is completed` — so it is never re-verified. **No phase that already closed is re-examined, and no roadmap turns red on upgrade.** What changes is the bar for every phase that has not closed yet. See Migration.
- **`roadmap-init` now refuses a phase whose `creates[]` or `needs[]` carries an identity that can never name a real artifact.** Exactly three shapes are rejected, judged over the identity (the text before the first `(`, trimmed) and nothing else: empty once the description is stripped; a `..` **path segment** — `(^|/)\.\.($|/)`, so `services/foo..bar` is untouched; and a leading `/` anchored at position 0, because `POST /api/notifications` contains a slash but does not begin with one and an unanchored rule would make every endpoint-kind phase unwritable. Identity *strength* is explicitly not judged: at declaration time research has not run, so a bare table name (`notifications`) or a bare directory (`db/migrations`) still passes — guessing a path there fails at phase close for a reason nobody can debug. The check runs **inside the `roadmap.json` lock, after the filter that drops phase ids already on disk**, so it judges only the phases the call is actually writing; placed beside the existing directory and branch validators it would have fired on legacy phases during `--sync`, and because both `/aimi:plan` call sites downgrade a `roadmap-init` failure to a warning, the new phase would then have been dropped silently instead of reported. `creates[]` and `needs[]` go through the same predicate in the same pass, because `validate-contracts` matches a need against a provider's creates by **exact byte equality** — a rule applied to one list alone lets a roadmap hold two shapes at once and deadlocks planning on a permanently unmet need.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** This release makes previously passing phases start failing, which under this repo's own "MAJOR: breaking changes to command syntax or output format" rule could be read as MAJOR. MINOR is chosen on the precedent set one release earlier: 1.116.0 shipped the analogous `split-detect` verb together with a behavior change of the same shape (a partially tagged plan that used to split now refuses) and shipped as MINOR. No command syntax and no file format moved here — `verify-creates` is an internal CLI verb invoked by `/aimi:execute`, and what changed is a verdict that was wrong.

### Fixed

- **An identity naming a directory — `db/migrations` — previously failed verification even when the directory existed, blocking the next phase for no reason.** `[ -f ]` is false on a directory, and the text search found nothing, so the one identity form previously recommended as "strong" was the one form that could never verify by path; the test that recommended it only ever measured the repository where the directory was absent. The tracked-path check now matches a directory as well as a file (`git ls-files -- "<identity>" "<identity>/*"`). This is the correction in the opposite direction from the behavior change above: it unblocks phases that should never have been blocked.
- **The `creates`/`needs`/`areas` truncation cap was documented as 2000 characters when the CLI applies 500 — and two of the three documents asserted that the wrong number matched the CLI.** `plan.md`, `brainstorm.md` and `skills/task-planner/references/pipeline-phases.md` each grouped `successCriteria`/`creates`/`needs`/`areas` into a single clause under one 2000-character cap. `_ROADMAP_SANITIZE_JQ` applies 2000 to `successCriteria` alone and 500 to the other three. Documenting 2000 clipped **looser** than the CLI, so the tail of a long entry was lost at the CLI boundary rather than at authoring time — precisely what `brainstorm.md`'s own "must never clip tighter than the CLI does" clause existed to prevent; that clause is now true. The grouped sentence could not be corrected without splitting it, so all four fields are stated separately in all three files. No cap value moved and nothing under `scripts/` was touched: the documents were corrected to match the CLI.
- **Both documents that told an author how `creates[]` would be checked described the superseded procedure**, and were wrong in each direction — they omitted the tracked-path check and every exclusion, and promised a text search that no longer accepts documentation. `docs/roadmaps.md`'s "Closing a phase" section now describes what actually runs, in the register of the surrounding user-facing prose: the artifact is looked for among the files git tracks on the phase branch, first as a path (file or folder), then as a name in tracked source; an endpoint drops its leading method; documentation, tests and to-do comments do not count as delivery, except when the artifact *is* documentation; and only committed work is visible. `commands/references/scope-contexts.md` gains a "What verification looks for" subsection at reference depth. The four-kind identity table is unchanged byte for byte and neither page states a naming rule — the format was never the defect, the search was, and `notifications` remains a valid Table identity that `roadmap-init` accepts.

### Known Limitations

- **`git ls-files` and `git grep` see tracked files only, so an artifact that exists in the worktree but is committed nowhere reads as missing.** This is a real change for File-kind identities: the `[ -f ]` check being replaced saw the worktree and verified uncommitted files, while the text search beside it never did — the two halves of the old procedure disagreed about what counted, and they now agree on the stricter answer. The limit is surfaced rather than absorbed: every `missing` verdict's `evidence` states it, and `/aimi:execute`'s failure report tells the user to commit on the phase branch and re-run. Creates verification re-runs from scratch on the next pass, so committing is the entire fix.
- **`roadmap-init`'s identity guard judges newly written phases only, so a roadmap already holding a malformed identity keeps it.** `--sync` against an existing `roadmap.json` deliberately does not re-validate phases already on disk, for the call-site reason given under Changed. An existing bad identity therefore surfaces at phase close — as a `verification_failed` naming what was searched — rather than at write time.

### Migration

- **Nothing that already closed changes. The phase to watch is the one you started before upgrading and close after.** Creates verification runs only as a phase closes, and `roadmap-claim` refuses a phase whose status is already `completed`, so an existing roadmap's finished phases are frozen exactly as they are — upgrading re-examines nothing and flips nothing. The phase that will surprise you is the one still `pending`, `planned`, or `in_progress` on upgrade day: it would have closed yesterday on a documentation mention, a test-file mention, or a `TODO` comment, and it will not close on that evidence today. Two remedies, and the failure report names which one applies: **land the artifact for real** — write the code and commit it on the phase branch, since only tracked files are visible — or **correct the phase's `creates[]` identity**, if what it declares is not what was actually built. Then re-run `/aimi:execute`: creates verification re-runs from scratch on every pass, so nothing needs resetting by hand. Each missing line now carries the file and line that was found and rejected, so "found and rejected at `docs/plano.md:1`" reads differently from no match at all.
- **A project that committed its own `.aimi/` directory should expect the largest change.** Every phase in such a repository previously verified unconditionally, because the identity was found in the tracked `roadmap.json` that declared it. `.aimi/*` is now excluded from the search. This does not reopen anything: phases such a project already closed stay closed, unverified and unrevisited. It means the next phase it closes gets the first honest creates verification that project has ever had — and a phase that was going to sail through on its own declaration will now be judged on the code.
- **Nothing needs re-planning and no existing `roadmap.json` needs rewriting.** The identity guard applies to newly written phases only; `--sync` against a roadmap holding pre-existing entries accepts them and appends as before, leaving prior phases byte-for-byte unchanged.

## [1.116.0] - 2026-07-27

### Added

- **`aimi-cli.sh split-detect` — split-group detection moves out of executable command prose and into the CLI, where the test suite can reach it.** Anchor selection, sibling resolution, marker validation, active filtering, and the legacy-pair fallback are pure, deterministic, file-only logic, but they lived twice inside `execute.md` (flat Step 0.9 and phase mode), the two copies had already diverged, and neither Bash suite could exercise either one. `$AIMI_CLI split-detect [--dir <phase-dir>]` now answers the question once and returns a single JSON object — `{mode, anchor, members[], activeCount, total, degradedReason}`, where `mode` is `project-split` / `paired-split` / `single` / `none`. It is a query, not a gate: every outcome including `single` and `none` exits 0, and non-zero is reserved for real errors. Three behavioral corrections came with the move. **Its flat scope is depth 1** — `*-tasks.json` whose parent directory is `.aimi/tasks` itself — where the prose it replaces reused a depth-1-to-3 glob that also matched phase directories, which is exactly how a phase's split files were captured by the flat flow and run as a flat split, leaving the phase unclaimed and nothing merged into the phase branch. **"Newest wins" replaces "first marker-carrying file"**: the anchor is the newest candidate by mtime, so a stale marked split from a past feature can no longer preempt today's plan, and a group whose members are all completed is dropped whole and the search repeats rather than routing today's real work to a single-file fallback. And there is now **one** definition of pending — `(.status // "pending") != "completed"` — where `execute.md` carried two that disagreed, so an `in_progress` story was counted by the phase-completion check and not by the active filter, letting a phase close with work in flight. Covered by TC36–TC46.
- **A third test suite: `plugins/aimi-engineering/scripts/test-command-blocks.sh`.** Command files are executed, not read — an agent runs their fenced `bash` blocks literally, each in its own isolated shell — so an edit to "documentation" under `commands/` is a code change, and neither existing suite could see it. Three stories on this branch changed only command prose, and all three shipped runtime bugs that reviewers had to find by hand. The suite extracts every fenced bash block under `commands/**` and applies four checks: the block parses (`bash -n`); it uses no bash-only construct, since blocks may run under zsh or macOS bash 3.2; it reads no variable whose only assignment is inside a loop it has already left; and it introduces no variable that nothing in the file assigns. Blocks are addressed by their enclosing heading rather than by any marker in the markdown, because `install.sh` translates command bodies for OpenCode by pure string substitution and would ship an embedded annotation to users verbatim. Known findings are grandfathered in `scripts/command-blocks-baseline.txt`, and the suite fails when a baselined entry stops firing, so that file can only shrink. **Its honest limit: no static check can see a variable that a prose sentence reads.** That class of defect is closed only by moving the logic into `aimi-cli.sh` — which is what `split-detect` above does.

### Changed

- **`story-merge --split full-stack` now picks its split axis from the plan's own layout instead of always splitting frontend/backend (resolves issue #72, `aimi-so/aimi-engineering-plugin`).** Before any writer runs — and before `--foundation`, cycle detection, and the Phase 3.1/4.1/4.2 sweeps, so a refusal costs nothing and warns about nothing — the merged story array is resolved to an axis by counting distinct `project` values. **Two or more distinct values → PROJECT axis:** one output file per repo (`<base>-<project-slug>-tasks.json`), ordered lexicographically by normalized project path, each carrying its own derived `branchName` — and no frontend/backend decision is made anywhere on that path. Ids are reassigned `US-001..US-M` in contiguous per-group blocks so they stay unique across the whole N-file set; two project paths that slugify to the same basename hard-fail the merge before any file is written. **Fewer than two distinct values → SIDE axis:** the two-file `*-frontend-tasks.json` / `*-backend-tasks.json` writer, unchanged. Single-repo plans and monorepos — no story sets `project`, or every story shares one value — keep the previous behavior byte-identical. The axis exists because separate repositories are a layout fact, not a question the frontend/backend heuristic is capable of answering.
- **Behavior change — a partially tagged plan now refuses instead of splitting.** Under `--split full-stack`, if any story carries a `project` and any other story's `project` is absent or blank, `story-merge` refuses the whole merge: it names every offending story, writes zero files, and preserves the staging directory. A story that belongs to the root repository must now say so **explicitly with `"."`** — an absent value is not the root, it is unrouteable, and the implicit "project-less stories fall into the `.` root group" rule that made it look routeable is deleted. Previously such a plan produced a frontend/backend split, which is how one tagged repo plus untagged stories could yield **one file and one branch spanning two repositories**. The fix for an affected plan is one line per story — tag it `"."` — and the refusal message says so.
- **Malformed `project` values are refused in every `--split` mode, legacy included.** Leading `./`, any `..` component, doubled slashes, surrounding whitespace, and any character outside the grammar `story-merge` publishes in its own refusal message all abort the merge before a file is written. The value is a repository path a downstream command will `cd` into, so `"../sibling-repo"` must not reach a tasks file by any route. Validation inspects the **raw** string rather than a trimmed one: `" apps/web "` is invalid rather than being quietly normalized into a value whose raw form is what the downstream command would actually use, and `"./apps/web"` is rejected rather than silently becoming a second spelling of an existing group.
- **Every PROJECT-axis split file carries a self-describing `metadata.splitGroup` marker** = `{project, index, total, siblings[]}` — its own project routing key, its 1-based position, the total file count, and the paths of its N−1 siblings. This is what `/aimi:plan` Phase 4 and `split-detect` key on, replacing filename-pattern guessing. Detection order is load-bearing: the marker pass runs first and wins, and the legacy suffix rule runs only when no candidate carries a marker — otherwise a repo whose path slugifies to the basename `frontend` or `backend` would be misread as the legacy pair. A marker that fails validation degrades and is terminal; it does not fall through to the legacy pair, which beside a project-split marker is stale work. Siblings resolve by basename against the anchor's own directory, which is what makes a traversal-shaped sibling entry inert. SIDE-axis and legacy files have no `splitGroup` key, and none is invented for them.
- **`story-merge`'s return contract gains a third shape, and `/aimi:plan` now consumes it instead of re-deriving filenames.** On the PROJECT axis story-merge prints an N-element array of `{path, project, branchName, storyCount}`; the SIDE-axis `{frontend, backend, frontend_stories, backend_stories}` object and the legacy `{merged, stories}` object are unchanged. Phase 3e captures stdout as `MERGE_RETURN`, and Phase 4 / Phase 4.5 read their file list from it rather than string-concatenating `$TASKS_PATH` with hard-coded suffixes — the surviving projects, their slugs, and their count are computed inside story-merge and are unknowable to the caller any other way. Phase 4.5 collapsed to a single `VALIDATE_FILES` loop that covers N=1 through N; the two steps it replaced operated on a hardcoded placeholder path story-merge never writes on a split, so they exited non-zero and the surrounding prose said "stop here", making the correct loop below them unreachable. Phase 4 additionally resolves each PROJECT-axis branch's base branch per repo via `detect-default-branch --project`, and must merge its patch **into** the existing `metadata` object so `splitGroup` survives verbatim.
- **Derived names are bounded, and refused rather than truncated when they exceed a bound.** A 301-character `project` used to kill `mktemp` mid-loop with no diagnostic, and ~200 characters yielded a 212-character `branchName` handed to git. Four limits are now checked up front and the refusal names which one failed: slug ≤ 64, output basename ≤ 248 (`NAME_MAX` minus mktemp's 7-byte suffix), path ≤ 4000, `branchName` ≤ 100. Truncating instead would manufacture a basename collision between two distinct long project values, which the collision guard would then misdiagnose. Separately, `--phase-aware` is refused when the `--output` basename does not end in `-tasks` with at least one character before it: both writers strip one trailing `-tasks`, which would otherwise collapse to the empty string and produce output whose basename starts with `-`.
- **`cross-file-dep-dropped` smell entries key on `project` on the new axis and keep `side` on the old one** — the two keys are mutually exclusive per entry, and consumers read whichever is present — plus a new per-edge `foundationEdge` flag on the PROJECT axis. The flag exists because `--foundation` in a multi-repo split drops an edge for every story in every non-foundation repo at once: the shared foundation story lives in exactly one group by construction, so its injected edges cannot survive into the others. Those drops get their own stderr note, separate from the ordinary drop-count banner, marking them as expected fallout of `--foundation` plus a multi-repo split rather than hand-authored dependencies that went missing.
- **`/aimi:execute` runs N per-repo split files, in both the flat and the phase-mode flow.** Step 0.9 is rewritten around `split-detect` with real loops, generalizing the paired-split path from two named Frontend/Backend slots into a loop over the active file set — two for a legacy pair, N for an N-repo project split — still spawning every member in a single tool-call turn. Each split file's worktree and container are rooted at that file's own repo, and `SPLIT_WORKTREE_PATH` is built from `git -C "$SPLIT_ROOT" rev-parse --show-toplevel` rather than from the project path, because `worktree-manager.sh` resolves its worktree-name argument against the repository toplevel and not against CWD — for sibling repos the two coincide, for a monorepo subdirectory they do not. The collision check accordingly keys on `(repo toplevel, branch)` rather than on the branch alone. Completion-report totals are summed with `git -C` per repo against that repo's own default branch. Step 1.7's Phase-Mode Paired Split takes the same generalization and consumes the same verb, scoped to the phase's own directory.
- **`.project` is treated as sub-agent-authored text everywhere it is rendered.** `/aimi:plan`'s Step 5 renderer was told to render `smellWarnings` as-is, justified by "project values are routing keys derived from `.project`, not free text" — true when the discriminating field was `side`, a closed-set CLI literal, and false once `project` carries text a sub-agent wrote. That clause is dropped; the four-step untrusted-content treatment is now required on `message`, `droppedDeps[].title`, `project`, `side`, and `droppedDeps[].project`. `story-merge` sanitizes `.project` and `.title` alike in its own refusal output, and `execute.md`'s phase-mode branch-derivation loop gained the traversal rejection and charset regex the flat side already had — not for branch safety (slugify already guarantees the branch regex) but because `SPLIT_PROJECT` is echoed verbatim into the aggregated report and into each spawned Task's description.
- **TC18, TC20, TC21, TC22, TC29, and TC30 in `test-aimi-cli.sh` were rewritten on purpose — read the flipped assertions as expected, not as a regression.** The first four pinned the majority-vote behavior removed below and went red the moment that vote was deleted: superseded, not broken. TC18 now asserts that a two-distinct-project fixture yields one file per project and no side files at all; TC20 generalizes the two-file bipartition invariant to an N-way one while keeping an arity floor that names both files; TC21 asserts `.project` survives verbatim on every story of every per-project file; TC22 swaps its tie-goes-to-backend assertion for a normalization-boundary one. TC29 inverted: its fixture — two tagged repos plus an untagged story — is now the refusal case, and TC47 picks up the half of the contract that survives, that an explicit `"."` still forms a root group. TC30's rationale comment was factually wrong and is corrected: verified against the pre-change CLI, the singleton was not swallowed by the majority vote; the real defect was N repos force-fitted into two side-named files. Each rewritten case carries a leading `SUPERSEDED, NOT BROKEN` comment naming exactly what it used to assert and pointing here.
- **Six mutations that survived the whole suite are now killed by named assertions**, each proven by breaking the production code in a scratch copy and watching the new assertion fail. `wave` was never read on any project-split file, so deleting `recompute_waves` from the PROJECT writer survived everything while shipping `dependsOn: []` stories at wave 2; TC28/TC34/TC35 now assert `.userStories[].wave`. TC48 covers `--phase-aware` on the PROJECT axis, which no prior case could reach. TC49 covers the partial-write handler, reachable only since the `set -e` fix below. Assertions that could not fail are repaired or deleted: unfalsifiable `_fe`/`_side` leak checks on a path that computes neither key, a `sort -u` duplicate check that needed `uniq -d`, an "identical `smellWarnings`" pair that passed on the empty set, a directory assertion that could not fail, and two else-branches that under-reported a missing file by 12 and 7 failures.
- **Version call — MINOR, not MAJOR, recorded so it is auditable rather than assumed.** This release does change `story-merge --split full-stack`'s output format for multi-repo plans: a different number of files, different filenames, a changed return contract, and a refusal where a partially tagged plan previously produced two files. Under this repo's own "MAJOR: breaking changes to command syntax or output format" rule that could be read as MAJOR. MINOR is chosen on the identical precedent set by PR #68 / 1.113.0 — which also changed split output for existing multi-repo plans (partition-by-`project` plus a new `smellWarnings` entry type) and shipped as MINOR — and because `story-merge` is an internal CLI verb invoked by `/aimi:plan`, not a user-facing command surface, while the single-repo/monorepo path here is byte-identical to 1.115.0.

### Removed

- **The strict-majority vote that assigned an entire project group to one side, and its tie-goes-to-backend bias, are deleted outright** — not left unreachable behind the new axis. Introduced in 1.113.0, it grouped stories by `project` and then sent each whole group to whichever split file won a strict majority of its members' individual file-pattern/keyword verdicts, ties going to backend. On a genuinely multi-repo plan that question has no correct answer, and the vote answered it wrongly: a real frontend project whose stories happened to trip backend-looking heuristics was moved wholesale into the backend file. That is issue #72 (`aimi-so/aimi-engineering-plugin`), reproduced with both two-repo and three-repo layouts. Separate repos are now separated by layout, so no side verdict — and no tiebreak — is computed for them at all.

### Fixed

- **A five-reviewer audit of this branch raised roughly forty findings, eleven of them blocking; all eleven are fixed here.** Each reviewer was required to prove findings by execution. Two were bad enough to name individually. First, the axis dispatcher and the group router used **different normalizations** of the same field — the dispatcher discarded untagged stories before counting while the router turned those same nulls into a real `"."` group one function away — so one tagged repo plus untagged stories counted as a single distinct project, took the SIDE axis, and produced **one output file and one branch for two repositories**, reintroducing issue #72 inside the change meant to fix it. Divergence is now impossible rather than merely corrected: the dispatcher computes nothing of its own, both `// "."` fallbacks are gone, and a single shared `group_key` definition is the only routing key in the file. Second, `AIMI_ROOT_IS_GIT_REPO` was **never assigned in any executable block** — only by an English sentence in Step 1.5 — and since each Bash call is an isolated shell, the phase-mode guard read an empty variable and `[ "" != "true" ]` is true, so **every phase-mode run in an ordinary single-repo layout refused with "multi-repo layout detected"**. Phase mode was unusable, not merely fragile; the value is now a per-block derived one-liner, the same convention the file already uses for `AIMI_CLI` and `AIMI_ROOT`. The remaining nine span the same three root causes — a `"."` root group that was invented mid-implementation and never specified, a Step 0.9 that ran before phase-mode detection and scanned unbounded, and three stories that changed only prose in a repo that could not test prose: Step 0.9's per-file blocks read a `$split_file` that no loop set; the phase-split merge used `mapfile`, absent under zsh and macOS bash 3.2, with an arity guard below it that turned the failure into a silent no-op; phase Pass 2 gated on a variable Pass 1 also empties on validation failure, so a failed group ran a stale legacy pair right after announcing it would degrade; the split dev-server gate collapsed N per-member decisions into one scalar so only the last member's value survived; and the N-file partial-write handler was dead code — `set -euo pipefail` exited the shell at the failing compound command before `write_exit=$?` could run, leaving one file on disk advertising `total: 3` with two siblings that did not exist, an orphaned `mktemp` file, and no error message at all. That handler now reports three sets — written before the failure, the failure itself, and never attempted — plus the preserved staging directory, because every file that did land advertises a split that is not on disk.
- **Issue #73 reframed and addressed: multi-repo + container + split was a diagnosability defect, not a corruption one (`aimi-so/aimi-engineering-plugin`).** Verified empirically before any fix was written — the combination corrupts nothing. `cd "$AIMI_ROOT"` followed by a worktree create under a non-git parent folder exits **128** with a bare `fatal: not a git repository` and creates nothing at all; the failure is total and immediate, and what it fails to do is name the phase, the layout, or the fix. Three changes address that. Each split file now owns exactly one repo, so its container is created under that repo rather than under the non-git root, which removes the failure from the flat multi-repo split path entirely. Worktree paths are derived from the repository's git toplevel rather than from the project path, so they point at a directory that will actually exist. And for the combinations that remain unsupported, `/aimi:execute` refuses clearly instead of letting git produce the opaque message: a guard placed before the first `cd` and before any `$WORKTREE_MGR create`, covering phase mode under a non-git root and the case where a multi-repo plan converges on a single surviving repo and therefore lands as a two-file frontend/backend split under that same non-repo root. The refusal names the detected layout, the exact failure that would otherwise follow, and what to do about it — and it releases the phase claim in the same block that makes the decision, so a single-repo layout never touches the release and a multi-repo layout can never skip it.
- **Path traversal could reach a bare `cd` in `/aimi:plan`.** The only validator that rejects `..` ran in Phase 4.5, after Phase 4 had already handed the raw sub-agent-authored `.project` to `detect-default-branch --project`. A Project Path Gate now validates every distinct staged `.project` at the top of Phase 3e — while `RUN_DIR` still exists and nothing has been written — with the same guard repeated in Phase 4 as defense in depth; both mirror `execute.md`'s Step 0.9 check byte-for-byte so the sites stay diffable. Refusing in Phase 4 instead would fire after `story-merge` had already deleted the staging directory, destroying the run.
- **Stale prose describing the deleted majority vote as current behavior** is corrected in `skills/task-planner/SKILL.md`, its `references/pipeline-phases.md` copy, `references/validation-checklist.md`, `commands/references/user-communication.md`, and `story-merge`'s own `--help` text, all of which still described a split that always produces exactly two files. `validation-checklist.md` additionally records the new tagging contract: in a multi-repo plan every story needs a `project`, and a story belonging to the root must say so with `"."`. `metadata.splitGroup` — mandated by the Phase 4 checklist and detected on by `/aimi:execute`, yet absent from both normative schema blocks — is now documented in `/aimi:plan`'s Schema v3.3 Structure block and in `plugins/aimi-engineering/CLAUDE.md`'s Tasks File Schema, which also gains both `cross-file-dep-dropped` shapes and their mutual exclusivity; `cmd_help` documents `--foundation`, which was entirely absent while being fully implemented and routinely passed by `/aimi:plan` Phase 3e, and rewrites the `--phase-aware` paragraph to cover both axes and the new `-tasks` precondition. The root `CLAUDE.md` testing section now lists three suites and says why a prose-only edit under `commands/` is a code change. No README.md edit accompanies this release — no command, skill, or agent was added or removed, so the component-count tables are unaffected.

### Known Limitations

- **The SIDE-axis writer still carries the latent `set -e` partial-write bug the PROJECT writer just fixed.** `_story_merge_write_split`'s `fe_exit`/`be_exit` sites have the identical shape: a bare compound command under `set -euo pipefail` exits the shell before the following `$?` read can run. It is deliberately not fixed here. Doing so would change SIDE-axis stderr and exit code on write failure, and eight pinned tests plus this branch's byte-identical-SIDE merge gate depend on exactly that behavior. Deferred to a follow-up that can move the tests and the code together.
- **`metadata.splitGroup.siblings` embeds every other member's path in every file, so its total size grows quadratically in the number of repos.** Accepted rather than fixed: at realistic repo counts the cost is noise, and the obvious alternative — having each consumer reconstruct sibling filenames from a naming convention — is exactly what the rest of this pipeline forbids, because the surviving projects and their slugs are computed inside `story-merge` and are not derivable by any caller.

### Migration

- **Split task files written before 1.116.0 keep executing unchanged.** They carry no `metadata.splitGroup` marker, so `/aimi:execute` falls through to the legacy `-frontend-tasks.json` / `-backend-tasks.json` suffix-and-shared-prefix rule, which survives as an explicit documented fallback rather than as dead code. Nothing needs re-planning and no file needs rewriting; only newly merged multi-repo plans take the project axis.
- **A plan that tags some stories with `project` and leaves others untagged must be updated before it will merge.** Under `--split full-stack` that plan now refuses instead of producing a frontend/backend split. Give every story a `project`, using `"."` for stories that belong to the root repository; the refusal message names each story that needs one.

## [1.115.0] - 2026-07-26

### Added

- **`commands/references/user-communication.md`.** New human-facing writing-style reference governing the wording, tone, and density of text a plugin command sends directly to the person running it — completion reports, chat explanations, and `AskUserQuestion` prompts — formatted as five before/after pairs, each with a checkable rule caption (e.g. "grep the block for ... — zero matches") so a rewrite's compliance is verifiable, not just asserted. Scope is human-facing text only: it explicitly excludes text sent to subagents (Task spawn prompts), whose objective — sufficiency to a fresh-context agent, not human readability — is the opposite of this file's density and jargon rules. Introduces the Adaptive Language Rule: user-facing output follows whatever language the person is writing in, so a command that hardcodes a single language into a completion report or prompt is a defect under this rule regardless of which language is hardcoded. Wired into three call sites: `plugins/aimi-engineering/CLAUDE.md`'s Command Conventions, `AGENTS.md`'s `<scope>` block, and `commands/references/interactivity.md`'s "Adding a New Question Site" checklist.

### Changed

- **Four interactive gates normalized from Portuguese to English**, the first application of the new Adaptive Language Rule rather than a plain translation: `brainstorm.md`'s Prototype Offer Gate (`Prototipar`/`Tenho uma referência`/`Pular` → `Prototype`/`I have a reference`/`Skip`) and its foundation-proposal-reuse offer (`Reaproveitar existente`/`Criar novo` → `Reuse existing`/`Create new`); `plan.md`'s Phase 1.9 Greenfield Foundation Gate (`Aceitar`/`Ajustar`/`Pular` → `Accept`/`Adjust`/`Skip`, plus the derived resolution language and the outline-gate rejection message); and `setup-models.md`'s five model-category questions and `cli-path-resolution.md`'s matching first-run model-config prompt (question and option wording only — picker format is unchanged).

### Fixed

- **`setup-models.md` Step 0 CLI path resolution.** Replaced a hardcoded developer-machine absolute path (one contributor's local checkout of `cli-path-resolution.md`) with `${CLAUDE_PLUGIN_ROOT}`, which `install.sh` already translates for OpenCode installs — the command now resolves correctly on any machine and under either host.

## [1.114.0] - 2026-07-26

### Added

- **`detect-parent-branch` aimi-cli.sh verb.** New `aimi-cli.sh detect-parent-branch <branch>` resolves a branch's parent by walking `git log --first-parent` ref decorations as individual tokens — never as whole lines or substrings — matching candidates against the current branch by exact token equality, then verifies the surviving candidate via `git merge-base` before returning it. Falls back to the default branch (`verified:false, source:"default-branch"`) when no candidate survives verification. Output shape: `{branch, base, verified, source}`. Extracted `_resolve_default_branch` as a shared private helper reused by the new verb, and covered by 29 new `test-aimi-cli.sh` assertions spanning all six defect/design cases.

### Fixed

- **`/aimi:open-pr` resolved the wrong base branch, and under container mode the wrong feature branch too (resolves issue #69, `aimi-so/aimi-engineering-plugin`).** Two independent defects failed silently. First, Step 2b's parent-branch detection piped `git log --first-parent --pretty=format:'%D'` through `grep -v "HEAD"` and `grep -v "$CURRENT_BRANCH"` (`commands/open-pr.md:128`) — line and substring filters where token filters were required, since `%D` packs every ref decorating a commit onto one comma-separated line. A parent decorated `HEAD -> <parent>` — exactly what git writes when the parent branch is the one checked out — lost its entire line to the first filter, and the second filter dropped any parent branch that merely contained the current branch's name as a substring (`feat/auth-base` vanishing when the current branch was `feat/auth`). Verified live in this repo: the old pipeline returned a branch 125 commits behind the true base, and because the result was non-empty it silently suppressed the default-branch fallback that would otherwise have caught the failure. Second, Step 2a resolved the feature branch via `git rev-parse --abbrev-ref HEAD`, which is wrong under container execution mode — the Main Working Tree Untouched Invariant plus `--keep-branch` teardown leave the feature branch checked out nowhere and HEAD parked on the base branch. Since `/aimi:plan` writes `"container"` by default for fresh flat tasks files, this was the default execution path, not an edge case; verified live, the old read resolved the base branch where the new one resolves the feature branch.
- **`/aimi:open-pr` now reuses the plugin's shared detection primitives instead of maintaining its own.** Step 2b/2c/2d call the new `detect-parent-branch` verb (reading `.base`, warning when `verified` is `false`) instead of the in-markdown grep pipeline; Step 2c uses the shared cached `$AIMI_CLI detect-default-branch` instead of a `gh repo view --json defaultBranchRef` network round-trip — `open-pr.md` was the only command in the repo still doing its own network round-trip for the default branch. Step 2a now resolves the branch from `metadata.branchName` via a guarded `$AIMI_CLI metadata` call (Case A: HEAD is already a real feature branch, reuse it; Case B: HEAD is on the default branch or detached, read the tasks file), mirroring the Case A/Case B pattern `commands/review.md` already uses for the identical problem.

## [1.113.0] - 2026-07-26

### Changed

- **`story-merge --split full-stack` now partitions by `project` instead of classifying every story independently, fixing documentation-only stories landing in the wrong split file (resolves issue #67, `aimi-so/aimi-engineering-plugin`).** Stories are first grouped by their normalized `.project` field (trim whitespace, strip one trailing slash, blank treated as absent), then each group is assigned to the frontend or backend output file by a strict majority vote of its members' own file-pattern/keyword verdicts, ties going to backend. Stories with no `project`, and any staging set where fewer than 2 distinct `project` values are present — including the monorepo case where no story sets `project` at all — keep the previous per-story heuristic unchanged, so single-repo and monorepo plans stay byte-identical to before. This fixes the concrete defect where a documentation-only story (files like `AGENTS.md`, `CLAUDE.md`, `docs/`) matched no frontend path pattern and landed in the backend split file even when its `project` field placed it alongside frontend siblings — after which it silently lost its cross-file `dependsOn` edges and became eligible for wave 1, schedulable before the stories it documents.
- **Cross-file `dependsOn` removal in the split is no longer silent.** Each split file must stay self-contained since the two files execute as independent sessions, so cross-file `dependsOn` edges are still dropped — but `story-merge` now emits one aggregated stderr banner reporting dropped-edge and affected-story counts, enumerates the stories that lost every dependency and therefore became wave-1 roots ("false roots"), and records one `cross-file-dep-dropped` entry per affected story in `metadata.smellWarnings` of both output files. Exit code is unchanged (still 0). No README.md edit accompanies this release — the fix adds no new command, skill, or agent, so the component-count tables are unaffected.

## [1.112.0] - 2026-07-24

### Added

- **`extract-sections` aimi-cli.sh verb.** New `aimi-cli.sh extract-sections <file> --anchors "<heading titles>"` prints only the requested `## `/`### ` sections of a research `.md` file, concatenated verbatim in request order — each section spans its matching heading up to the next heading of the same-or-higher level (or EOF), so an h2 anchor pulls in its nested h3s. `--anchors` accepts newline-separated heading titles matched case-insensitively (newline rather than comma, so a heading that itself contains commas — `## Testing, Linting, and CI` — stays matchable); an anchor with no matching heading is skipped rather than erroring and named in a stderr warning, and a run whose anchors match nothing exits 0 with empty output. Heading detection is fenced-code aware, so a `#` comment inside a ` ``` ` block never truncates a section. Anchors containing a shell metacharacter (`$`, a backtick, `"`, `\`) are rejected with a warning rather than processed — defense in depth behind the caller's own sanitization. Path confinement mirrors the existing `research-lookup` verb (`resolve_path` + `validate_path_in_project`). This is the slicing primitive the section-scoped Pass 2 delivery below is built on.
- **Structured claim/citation/quote findings format for research agents.** `AGENTS.md` gains a `<research_findings_format>` contract: every factual claim in a research agent's on-disk findings file must now be either a short verbatim quote plus a locatable citation (`file:line`, `path:Lstart-Lend`, or the most specific doc/URL pointer available) or explicitly tagged `[INFERRED]` when no source exists — no bare assertions. Wired into all five research agent specs (`aimi-codebase-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`, `aimi-learnings-researcher`, `aimi-design-bundle-researcher`). Composes with issue #64's planned `verify-citations` CLI pass, which this structure is designed to be mechanically checkable by; it extends (does not override) the existing `<preservation_rules>`/`<research_return_contract>` and leaves the pointer-block Task return (`research_file`, `summary`, `sections`) unaffected.

### Changed

- **`/aimi:plan` Pass 2 story expansion now receives section-scoped research excerpts with read-on-demand, replacing the full-corpus `researchFileBlocks` broadcast.** A new Per-Entry Section-Scoped Research Block Preparation step builds a `researchSectionsIndex` of each collected research file's heading anchors, selects the anchors per file most relevant to each outline entry's subject matter (typically 2-5; no hard cap), sanitizes each one before it reaches a shell argument, and slices them via the new `extract-sections` verb into that entry's `researchSectionBlock`, capped at 20 KB per entry — so per-spawn token cost scales with what each story actually needs rather than with the size of the entire research corpus. Every sub-agent also receives `allResearchPaths` — a new working-memory union of the files written this run and every reused research file — plus an explicit instruction to Read any of them in full when an excerpt is insufficient for an acceptance-criterion detail, so reused-research runs (the `/aimi:brainstorm` → `/aimi:plan` flow, where Phase 1.7 collects nothing because every file is already in context) still have a durable fallback. Phase 1.7's on-disk ingestion and the existing `researchFileBlocks` feed to outline generation and the Phase 3d.5 auditor are unchanged. Note the saving is asymmetric rather than absolute: it removes N sub-agent copies of the corpus, but the per-entry slices are pulled back through the orchestrator's own context to be inlined, trading sub-agent tokens for orchestrator tokens.
- **Learnings-researcher spawn now passes prototype file paths for on-demand reading instead of broadcasting prototype HTML blocks.** `/aimi:plan`'s learnings-researcher Task prompt replaces the inlined `prototypeBlocks` broadcast with `resolvedPrototypePaths`, instructing the agent to read those files itself, on demand, only when a `.aimi/solutions/` match is prototype-relevant.
- **Researcher exploration budgets and plan-then-search added to all five research agent specs.** Each of `aimi-codebase-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`, `aimi-learnings-researcher`, and `aimi-design-bundle-researcher` now derives a short list of concrete target questions before issuing any Grep/Read/Glob call, stopping each question as soon as it is confidently answered, and treats a tool-call ceiling as a soft budget — finishing a nearly-complete line of inquiry rather than cutting it off, but writing up partial findings once at or beyond the ceiling instead of exhaustively continuing to search. The three repo/web-facing researchers (`aimi-codebase`, `aimi-best-practices`, `aimi-framework-docs`) scale the ceiling by `researchDepth` (quick ~8, standard ~15, deep ~25); `aimi-learnings` (~10) and `aimi-design-bundle` (~12) use a fixed ceiling instead, since each already reads a bounded input set. The codebase researcher's migration-aware existence checks are explicitly exempt from the ceiling — a partial signal set may never be reported as an absent entity, which is what keeps the budget from manufacturing the false negative that doctrine exists to prevent.

## [1.111.0] - 2026-07-24

### Added

- **Five stack-convention skills**: `typescript-node-conventions`, `nestjs-conventions`, `nextjs-tanstack-conventions`, `go-conventions`, and `rust-conventions`. Each follows the `architecture-foundation` template — a self-sufficient `SKILL.md` (<300 lines) covering evergreen, version-independent conventions for that stack, deeper `references/` tiers for on-demand depth, and a `NOTICE.md` attributing its upstream source under the applicable license (MIT, CC-BY-4.0, or dual MIT OR Apache-2.0), with a matching `license: ... (NOTICE.md)` pointer in the frontmatter.
- **`/aimi:plan`'s file-pattern-to-skill mapping wired for all 5 new skills.** Story-expansion now attaches `typescript-node-conventions` for `*.ts` (non-test, non-`.tsx`), `bunfig.toml`, `bun.lock`/`bun.lockb`; `nestjs-conventions` for `*.module.ts`, `*.controller.ts`, `*.service.ts`, `nest-cli.json`; `nextjs-tanstack-conventions` for `app/**/*.tsx`, `app/**/*.ts` (non-test), `next.config.*`, `*tanstack*`; `go-conventions` for `*.go`, `go.mod`; and `rust-conventions` for `*.rs`, `Cargo.toml`. Matching is glob-scoped by extension (not a bare `app/**`) so the Next.js/TanStack mapping never collides with Rails' own `app/` directory. Stories whose files match both a generic and a framework-specific pattern (e.g. a NestJS `*.service.ts`) intentionally receive both skills — generic hygiene and framework structure are complementary.

### Fixed

- **`react-best-practices` NOTICE backfill.** The skill (`name: vercel-react-best-practices`, "from Vercel Engineering") shipped with no `NOTICE.md` despite incorporating MIT-licensed Vercel content. Added `plugins/aimi-engineering/skills/react-best-practices/NOTICE.md` naming Vercel Engineering as the source under the MIT License, and a `license: MIT (NOTICE.md)` pointer in the `SKILL.md` frontmatter, matching the `architecture-foundation/NOTICE.md` shape.
- **README.md skill count correction.** The `aimi-learnings` skill has shipped with a `SKILL.md` since its introduction but was never given a row in the Skills table, leaving the stated count permanently one short of the actual directory count. It now has a row in the Core (Internal) table, and the headline count is recounted from disk (`find plugins/aimi-engineering/skills -maxdepth 1 -mindepth 1 -type d | wc -l`) to 24, matching the enumerated table rows exactly.
- **Review remediation for the stack-convention skills.** Synced the file-pattern-to-skill mapping into `agents/workflow/aimi-story-expander.md` so the five new skills actually attach under both hosts — the agent-definition copy of the mapping table (the one OpenCode installs as the story-expander's system prompt) had not been updated alongside `commands/plan.md`, so stack stories risked hydrating no convention skill at all. Corrected the skill-eviction rationale in `plan.md`'s composition note: the emitted `skills[]` order is not pinned, so the 100KB `get-story-context` hydration cap makes no generic-vs-framework eviction guarantee (the note previously claimed the reverse of the actual drop-last-inserted behavior). Trimmed authoring-process narration that had leaked into shipped files — removed the hydrated "Context7 Verification Notes" section from `typescript-node-conventions/SKILL.md`; deleted `rust-conventions/references/context7-verification.md` (a process log citing a now-absent `.aimi/research/` path) and its two `SKILL.md` references; condensed `rust-conventions/NOTICE.md` from reproducing the full Apache-2.0 license text to a link (the MIT body and every per-source attribution retained); and removed a dangling `.aimi/research/` citation plus a defensive-writing meta-note from `go-conventions/NOTICE.md` (the substantive CC-BY 3.0→4.0 correction retained).

## [1.110.0] - 2026-07-24

### Added

- **brownfield-sem-convencoes as the second degree of the Phase 1.9 Greenfield Foundation Gate (issue #56 phase 3).** `/aimi:plan`'s gate no longer only fires on empty greenfield repositories — a repository with 5 or more tracked source files (or find-fallback matches) but no `CLAUDE.md`/`AGENTS.md` at `AIMI_ROOT` now classifies as brownfield-sem-convencoes ("established code with no captured conventions") and fires the same gate through condition (a), filtered through the shared ancestor-manifest lookup that now covers both degrees. `commands/references/foundation-signals.md` documents the classification and names `plan.md`'s Phase 1.9 as the consumer for both degrees; working-memory `foundationMode` is set to `brownfield` when this degree — rather than greenfield — is what held.
- **`aimi-foundation-architect` brownfield mode with repo-inspection.** The agent now accepts a `mode` input (`greenfield` | `brownfield`). In brownfield mode it runs a direct repository-inspection step (Grep/Glob against real source) before proposing conventions, so its output reflects the codebase as it actually is — verbatim lint config, a Module Template drawn from a real existing module — rather than a generic prescription; anywhere a coherent existing pattern can't be inferred, the gap is routed to the proposal's Open Questions section instead of guessed at. It still writes the same `-foundation.md` artifact shape (`foundationProposalPath`, 14-day freshness, path confinement, `research-gc` coverage, Foundation-first ordering) regardless of mode.
- **`architecture-foundation` skill.** A new self-sufficient (~200-280 line) `SKILL.md` skill packages condensed, actionable Clean Architecture (dependency direction, layers, ports/adapters) and Domain-Driven Design (Ubiquitous Language, Bounded Contexts, Entities, Value Objects, Aggregates, Repositories) guidance for both greenfield layering decisions and brownfield convention inference, with fuller tiers under `references/` for on-demand depth. Content is MIT-attributed via a `NOTICE.md` following the existing `frontend-design` pattern, and is attached only to the foundation-entry story (`foundationEntry: true`) rather than every story.
- **`foundationMode` threading through `story-expander`.** The brownfield branch of story expansion now receives and honors `foundationMode`, documenting conventions in-place (`CLAUDE.md`/`AGENTS.md` only) instead of scaffolding a greenfield-style folder layout — no `.gitkeep` placeholders, no overwriting an existing lint config.

### Fixed

- **`install.sh`'s `install_skills` now copies skill-root `NOTICE.md` files to the OpenCode install target.** Previously only `SKILL.md` and `references/` were copied, silently dropping any skill-root `NOTICE.md` — this had already been losing `frontend-design/NOTICE.md` on every OpenCode install, and would have done the same to the new `architecture-foundation/NOTICE.md`. Both skills' MIT attribution now survives the OpenCode translation.
- **`get-story-context` now resolves `aimi-` prefixed skills under OpenCode.** Skill hydration built the path from the bare skill name a story declares (`skills/<name>/SKILL.md`), but `install.sh` installs OpenCode skills under an `aimi-` prefix (`skills/aimi-<name>/SKILL.md`) — so every story-declared skill silently failed to hydrate under OpenCode (pre-existing, affecting all skills, surfaced while wiring the new `architecture-foundation` attach). The lookup now falls back to the `aimi-`prefixed directory when the bare path is absent; Claude Code's unprefixed cache is unaffected.

### Changed

- **`/aimi:open-pr` no longer leaks internal `US-NNN` story tags into the PR title or body.** Under the phase/story execute flow each story is its own commit whose subject carries a `US-NNN` tag, and the title also described only the first story's slice. Title derivation now prefers the tasks file's `metadata.title` (the human-authored feature title), falling back to the first commit subject with any trailing/leading `US-NNN` (or `Story US-NNN`) tag stripped, then to the branch name. The body's **Changes** bullets and the **Summary** subject-fallback now apply the same story-tag strip to every commit subject they render; commit bodies (the Summary's primary source) are still used verbatim, and the diff/Files-Changed section is unchanged.

## [1.109.0] - 2026-07-23

### Added

- **Greenfield detection and a Foundation question category in `/aimi:brainstorm` (Phase 1.8, issue #56 phase 2).** Brainstorm now runs its own Structural Signals check (`commands/references/foundation-signals.md`, shared with `/aimi:plan`'s Phase 1.9 gate) early in the session. When the target repository is greenfield, Phase 2's batched questions gain a conditional Foundation category — stack/runtime, architecture pattern, folder/convention structure, and lint/format tooling — alongside the standard topic categories, so these decisions are captured once, in the user's own words, instead of only at planning time.
- **Phase 3.7 Foundation Synthesis in `/aimi:brainstorm`.** When Foundation questions were answered, a new phase sanitizes and synthesizes the four sections `/aimi:plan`'s foundation flow actually consumes (CLAUDE.md Draft, AGENTS.md Draft, Folder Layout, Lint and Format Config) into a single artifact under `.aimi/research/`, gated by a validation check (all four sections present and concrete) before the pointer is ever emitted — a failed check degrades silently to `/aimi:plan`'s existing `aimi-foundation-architect` spawn path. A project-wide reuse check (`.aimi/research/*-foundation.md` glob — deliberately no topic-slug segment, since architecture is per-repository — with 14-day freshness and pre-acceptance validation of the candidate's confinement and 4-section content) offers reusing an existing fresh proposal instead of re-synthesizing on every run.
- **`foundationProposalPath` frontmatter key and its plan-reuse contract.** `/aimi:brainstorm` emits this single relative-path string in a brainstorm document's frontmatter only when Phase 3.7 validated its artifact (fresh reuse counts); the key is omitted entirely — no placeholder, no companion boolean — otherwise. `/aimi:plan`'s Phase 0 reads it under a strict, narrow path-confinement regime (join to `AIMI_ROOT`, `realpath` resolve accounting for traversal/symlinks, require the result to land inside `.aimi/research/` and end with `-foundation.md`), checks existence and 14-day freshness, and on success feeds the validated path into Phase 1.9's Greenfield Foundation Gate as a second reuse source alongside the existing topic-slug glob. Post-review hardening: the confinement boundary was narrowed from a bare `AIMI_ROOT` prefix to the foundation-artifact directory and filename shape, brainstorm's own reuse path now pre-validates candidates (confinement + 4-section content) instead of trusting a filename glob, and `research-gc`'s scalar extraction tolerates YAML-quoted values and trailing comments so a live pointer can never be mis-parsed into deleting its artifact.
- **`/aimi:plan` Phase 0 reuse wiring and Phase 1.9 hardening.** Phase 1.9's fire-condition and reuse-source logic now account for a Phase 0-populated `foundationProposalPath`, applying the same mtime tie-break the topic-slug glob already used when both sources resolve and differ. The gate's mature-repo, multi-repo, and roadmap-continuation skip branches now consistently reset any Phase 0-populated `foundationAccepted`/`foundationProposalPath` pair to unset/false before skipping, closing a gap where those branches previously left a stale pointer in place.
- **`research-gc` third orphan-check source.** The orphan garbage collector now also treats any `.aimi/brainstorms/*.md` frontmatter `foundationProposalPath` as a live reference, alongside the existing `metadata.researchPaths` and frontmatter `researchPaths` sources, so a synthesized foundation proposal with a live pointer is never swept as an orphan.

## [1.108.0] - 2026-07-23

### Added

- **Greenfield Foundation Gate in `/aimi:plan` (Phase 1.9, issue #56 phase 1).** When planning targets a repository with no established architecture (structural absence signals plus additive keyword signals, mirroring `ui-signals.md`'s detection pattern), `/aimi:plan` now inserts a gate after research and before spec-flow analysis that proposes a prescriptive architecture foundation before story decomposition begins. The gate loops on **[Ajustar]** (re-spawn the architect with accumulated adjustment text) until a terminal choice — **[Aceitar]** or **[Pular]** — is reached, pattern-parity with the Phase 3c Outline Gate's edit loop. `plugins/aimi-engineering/commands/references/foundation-signals.md` centralizes the detection vocabulary (structural absence markers, additive keywords) the gate uses to decide whether to fire.
- **`aimi-foundation-architect` agent.** A new prescriptive architecture agent (distinct from the descriptive `aimi-codebase-researcher`) that proposes a stack-appropriate Clean Architecture/DDD-inspired foundation — layering, module boundaries, and conventions — writing a single `FOUNDATION.md`-style proposal file under `.aimi/research/` for the gate to present.
- **`story-merge --foundation <idx>` flag.** When the Greenfield Foundation Gate is accepted, the foundation story becomes outline entry `01` (immutable through the Phase 3c Outline Gate) and its assigned `US-NNN` id is injected into every other story's `dependsOn` via a deterministic post-merge sweep — the foundation always lands in wave 1, and every other story's wave reflects the added dependency.
- **`story-expander` `foundation_proposal` support.** Sub-agents expanding non-foundation outline entries now receive the accepted foundation proposal's content (capped, HTML-entity-escaped) as additional context, so every generated story is consistent with the accepted architecture.
- **`metadata.decisions[].anchor` form `foundation:<topicSlug>` and `metadata.decisions[].source` value `"foundation"`**, documented in `plugins/aimi-engineering/CLAUDE.md`'s Tasks File Schema section, covering the Aceitar/Ajustar/Pular decisions the Phase 1.9 gate records in `oqDecisions[]`.

## [1.107.0] - 2026-07-23

### Changed

- **`/aimi:plan` now defaults freshly generated flat `tasks.json` files to `metadata.execution: "container"`** (previously `"inline"`). This is backward-compatible: existing files with the field absent still resolve to `"inline"` via the read fail-safe, and `--inline` can still be passed to `/aimi:execute` or `/aimi:next` to run a single invocation inline.

## [1.106.0] - 2026-07-23

### Added

- **Proactive Prototype Offer Gate in `/aimi:brainstorm` (Phase 3.6, issue #55).** Brainstorm now checks whether the drafted roadmap ships a frontend by inspecting **structural** roadmap deliverables — phase `creates` entries, `areas`, and the feature `goal` — rather than relying on the free-text description alone. This closes the gap where a backend-worded description ("add an endpoint for X") still ships a UI and previously skipped prototyping silently. When a frontend deliverable is detected and no prototype exists yet, brainstorm offers a three-option gate: **[Prototipar]** (launch guided prototype creation), **[Tenho uma referência]** (Reference Intake — see below), or **[Pular]** (skip, proceeding without a prototype). The gate only fires once per brainstorm session and never blocks progress.
- **Reference Intake flow.** When the user has an existing reference instead of wanting a prototype built from scratch, brainstorm accepts a local image, HTML/CSS file, a URL, or free-text description of the look-and-feel, and feeds the extracted visual tokens (colors, spacing, component shapes, copy tone) into the design pipeline as **Probe #0** — a seed probe that subsequent design exploration builds on rather than starting from a blank slate.
- **`plugins/aimi-engineering/commands/references/ui-signals.md`.** A new shared reference unifying the vocabulary used to detect "this feature has a UI" across commands: the keyword list (visual/UI-bearing terms) and the structural markers (roadmap `creates`/`areas`/`goal` patterns that imply a frontend). Both `/aimi:brainstorm` and `/aimi:plan` now source their frontend detection from this single file instead of maintaining separate, drifting keyword lists.

### Changed

- **`/aimi:brainstorm` Phase 1.7** now sources its keyword list from `ui-signals.md` instead of an inline list. The keyword scan is kept as an additive signal alongside the new structural check, and its vocabulary was extended with `frontend` and common framework names (React, Vue, Next.js, etc.) so more real-world descriptions are caught.
- **`/aimi:plan`** now emits a non-blocking warning when a frontend-bearing feature reaches the end of planning with no prototype on record, surfacing the same structural signal used by the brainstorm gate so features planned without going through `/aimi:brainstorm` first still get a nudge — the warning never stops or fails planning.

## [1.105.0] - 2026-07-21

### Added

- **Container execution mode for `/aimi:execute` and `/aimi:next`.** A new `metadata.execution` discriminator (`"container"` | `"inline"`) lets a tasks.json run its stories inside an isolated git worktree ("container") at `.worktrees/<branchName>` instead of against the current working tree. It's opt-in per invocation: pass `--container` (or `--inline`) on `/aimi:execute` or `/aimi:next` to select the mode for that run — the two flags are mutually exclusive — and when the choice differs from what the file already has, it's persisted onto `metadata.execution` via the new `aimi-cli.sh set-execution-mode` subcommand, so a later invocation without the flag stays in the same mode. In container mode, `/aimi:execute` creates or reuses the feature's container, installs dependencies once via the new `worktree-manager.sh install-deps` subcommand (lockfile-detected package manager — bun/pnpm/yarn/npm, silent skip when no `package.json`), starts a managed loopback-only dev server (new `serve start|stop|status` subcommand, state tracked in `.aimi/state/dev-server.json`) before the wave loop whenever a story needs visual verification, and runs the full wave loop inside the container. On completion, the dev server is stopped; pushing `<branchName>` to `origin` requires confirmation (an AskUserQuestion prompt in an interactive session, an explicit `--push` flag in agent mode — otherwise it's skipped), and the container is then removed while the branch itself is preserved (`worktree-manager.sh remove --keep-branch`) — the completion report points to `/aimi:open-pr --branch <branchName>` (which pushes on your behalf if needed) and `/aimi:review <branchName>` as next steps, since nothing is left checked out locally. `/aimi:next` gains the equivalent behavior for sequential execution, containerizing the feature branch across invocations and passing the container path as `WORKTREE_PATH` to the story executor; it refuses to run at all against a phase-scoped tasks file, pointing at `/aimi:execute` instead, since it has no phase-claim logic of its own. The 1.104.0 phase/milestone roadmap layer's own containers get the same managed dev server treatment, so visual verification works identically whether a feature runs flat or phased — a claimed phase always executes inside its own phase container regardless of `metadata.execution`, and phase-scoped tasks.json files never carry that field at all.
- **`metadata.execution` backward-compatibility guarantee.** The field is optional and defaults to `"inline"` when absent — every tasks.json created before this change, and any new one that doesn't set the field, keeps executing exactly as it always has, directly against the current working tree, with no container ever created. `/aimi:plan` writes `"inline"` explicitly into every freshly generated flat tasks.json and omits the field entirely on phase-scoped files; only an explicit `--container` override on `/aimi:execute` or `/aimi:next` opts a file into container mode.

### Fixed

- **Paired-split branch deletion in `/aimi:execute`'s Aggregated Completion report.** The flat full-stack paired-split completion path used to remove both the frontend and backend worktrees with a plain `worktree-manager.sh remove`, which also deleted their branches — the very branches the report had just told the user to open PRs from. It now passes the new `--keep-branch` flag, so the worktrees are cleaned up but both branches survive for `/aimi:open-pr` and `/aimi:review`.

### Known Limitations

- Non-Node stacks (no `package.json` with a `dev` script) get no managed dev server in container mode; visual verification degrades to `skipped` rather than failing the run.
- Ports hardcoded in application configuration (OAuth redirect URIs, CORS allowlists) are not remapped when the managed dev server binds to a different free port than expected.
- There is no proxy between sibling containers in a full-stack split, so visual verification from one container cannot reach the other container's API.
- Uncommitted edits left in the main working tree do not propagate into a container — `git worktree add` only branches from committed history, so any dirty-tree changes must be committed first.

## [1.104.0] - 2026-07-19

### Added

- **Phase/milestone roadmap layer for large-scope features.** A new optional planning tier sits above the existing flat pipeline for features too large to expand and execute in one pass. `/aimi:brainstorm` gains a Phase 3.5 roadmap-definition gate that lets the user cut a feature into named phases (with goals, success criteria, and `creates`/`needs` contracts) instead of a single flat scope; `/aimi:plan` falls back to the same phase-cut classification inline when no brainstorm roadmap exists. When phases are defined, a new `roadmap.json` artifact is materialized at `.aimi/tasks/<feature-slug>/roadmap.json`, tracking each phase's lifecycle status (`pending → planned → in_progress → completed`, or `→ verification_failed`), dependencies, and claim state. Each phase gets its own `.aimi/tasks/<feature-slug>/phase-N[.M][-slug]/` folder holding a phase-scoped `tasks.json` (materialized by `/aimi:plan --phase N`'s rolling-wave expansion) and a `handoff.md` summarizing decisions, artifacts, deviations, deferred items, and delivered contracts. `/aimi:execute` becomes phase-aware — it can claim and run an eligible phase, including parallel sibling sessions claiming independent phases concurrently, and composes with `--split full-stack` for phases that need paired frontend/backend task files. `/aimi:status` gains a roadmap summary view and a `--phase N` detail view. Eleven new `aimi-cli.sh` subcommands (`roadmap-init`, `roadmap-get`, `roadmap-set-status`, `roadmap-claim`, `roadmap-release-claim`, `roadmap-reconcile`, `roadmap-write-handoff`, `validate-contracts`, `phase-overlap`, `roadmap-sweep`, `estimate-payload`) back the whole lifecycle; `roadmap.json` and each phase's `handoff.md` are protected from direct Write/Edit-tool writes via `AIMI_RUNTIME_STATE_GUARD` the same way `.aimi/tasks/*-tasks.json` is (a Bash-issued write is not intercepted). **Single-scope-context features are entirely unaffected** — the flat `YYYY-MM-DD-[feature-name]-tasks.json` pipeline is unchanged and carries zero overhead when no roadmap is defined.

## [1.103.0] - 2026-06-25

### Changed

- **Restricted `allowed-tools` on the three filesystem-facing research agents to read-only + Write.** `aimi-codebase-researcher`, `aimi-learnings-researcher`, and `aimi-design-bundle-researcher` now declare `allowed-tools: Read, Grep, Glob, Write` (previously they inherited the full tool set). This captures the read-only safety posture of the built-in `Explore` agent — these agents crawl the user's source tree and can no longer `Edit`/`NotebookEdit` existing files or spawn sub-agents — while preserving `Write`, which the pointer-only research handoff depends on (each agent writes its findings to `.aimi/research/*.md` and returns only a pointer). Matches the existing `allowed-tools` convention already used by `aimi-bundle-prototype-author` and the workflow verifier agents. The web/MCP-dependent researchers (`aimi-best-practices-researcher`, `aimi-framework-docs-researcher`) are intentionally left unrestricted, since an allowlist would have to enumerate host-specific Context7 MCP tool names and risk silently breaking their external-documentation lookups.

### Notes

- This restriction is honored under Claude Code (which reads the plugin source verbatim). As with the five pre-existing `allowed-tools` agents, the OpenCode translator (`install.sh` `translate_agent`) does not yet propagate `allowed-tools` into OpenCode agent frontmatter, so under OpenCode these agents retain their current tool set — no regression, but no parity. Adding `allowed-tools` translation to the OpenCode installer is tracked as a separate follow-up.

## [1.102.0] - 2026-06-25

### Changed

- **Default `metadata.maxConcurrency` raised from `5` to `20`.** The wave-based executor now fans out up to 20 stories in parallel by default (previously 5), and the worktree-budget guard (`pre-bash-dispatcher.py`) allows up to 20 concurrent story worktrees before denying `git worktree add`. The new default is applied consistently across `aimi-cli.sh` (`status`/`metadata` fallbacks, including the `<= 0` floor), the `pre-bash-dispatcher` worktree-budget guard, and `/aimi:plan` (the value written into new tasks.json files). Explicit per-task overrides are unaffected — set `metadata.maxConcurrency` to any value (e.g. `1` for strictly sequential execution).

## [1.101.0] - 2026-06-24

### Added

- **Phase 1.8 Scope-Pruning-Positive Gate + new `aimi-scope-positive-verifier` workflow agent.** The `/aimi:plan` pipeline now runs a positive-premise verification step (Phase 1.8) after the existing scope-pruning-negative gate. A new standalone agent `aimi-scope-positive-verifier` receives each load-bearing positive spec premise and verifies it by data-flow analysis, tracing the actual call graph to confirm the claimed behavior exists. Premises that cannot be verified emit a `specFlow:CriticalQ` decision entry for human review before story expansion begins. Agent lives at `plugins/aimi-engineering/agents/workflow/aimi-scope-positive-verifier.md`.
- **Phase 1.6b research-conflict escalation gate.** When a researcher finding directly contradicts a spec premise, the plan pipeline now escalates the conflict as a `researchConflict:<n>` decision (source `"researchConflict"`) instead of silently suppressing it. The human reviewer resolves the conflict at the outline-review gate before story expansion proceeds.
- **`research-lookup --ignore-missing-cited-paths` flag.** Callers that tolerate missing file references (e.g. migration stories that cite to-be-created files) can now pass this flag to suppress the stale-exit triggered by non-existent cited paths. Freshness is still checked against all paths that do exist.
- **`normalize-status` CLI subcommand.** `aimi-cli.sh normalize-status <tasks-file>` auto-heals tasks files that are missing the `status` field on one or more stories by injecting `"status": "pending"` in-place. Designed to run before `validate-stories` so pre-fix tasks files self-repair without requiring manual edits.

### Fixed

- **`story-merge` now defaults `status: "pending"` in all three JSON writers** (legacy single-file, split-frontend, split-backend). Previously only the story-expander schema included a default, leaving the merge writers as the authoritative path missing the field. `validate-stories` has been updated with a `has(status)` predicate that rejects any story missing the field — ensuring the `/aimi:deepen` command no longer finds zero pending stories due to a missing `status` key.
- **`/aimi:deepen` reuse-gate now matches `touched-area` (existing-file overlap) instead of full file-set superset.** The previous gate required the new story's entire file set to be a subset of the cached research file set before allowing reuse. Migration stories that add new files alongside existing ones always failed this check and forced a full researcher re-spawn. The gate now fires when the intersection of the story's `implementation.files` with the cached research's cited paths is non-empty — so migration stories correctly reuse plan research for the files they share.

### Notes

- **Fix 4 (skill map defaults to `dhh-rails` for unmatched files) investigated and confirmed NON-BUG.** The original proposal listed a fix for the story-expander skill map defaulting unmatched file extensions (e.g. `*.ts`) to `dhh-rails-style`. Codebase cross-check (Phase 2.4) confirmed no TypeScript skill exists in this plugin — the only TypeScript-related agent is `aimi-kieran-typescript-reviewer`, which is a review agent, not a skill. The existing omit-on-no-match behavior (no skill selected when the extension has no mapping) is already correct. No skill-map change was shipped in this release.

## [1.100.1] - 2026-06-19

### Fixed

- **Concern 6 of `aimi-cross-story-auditor` reframed from "verification" to "surfacing".** The 1.100.0 design attempted to auto-verify deferral phrases by substring-matching the noun phrase preceding the deferral against the target story's acceptance criteria. Self-review caught a critical false negative: the noun in a deferral (e.g. "affiliation") commonly appears verbatim in the helper name introduced by the target story (e.g. `requiresAffiliation`), so a substring match produces a tautological "deferral honored" verdict — a silent pass that looks like a clean check. Worse than no check at all, because reviewers trust silence. Replaced with **deferral surfacing**: every matched deferral phrase emits an `unresolved[]` entry naming the source story and target story; the human reviewer judges whether the target wires the deferred behavior or only exposes a helper. The regex stays strict (only `deferred to (story )?\d+` and `story \d+ (will|owns|covers)`) — looser phrases still produce too many false positives.

## [1.100.0] - 2026-06-19

### Added

- **Two new built-in audit concerns on `aimi-cross-story-auditor`.** The agent now evaluates six concerns instead of four. (a) **Orphan public APIs** — when a story's `implementation.approach` introduces a named symbol (camelCase / PascalCase / snake_case, length ≥ 6) that does not appear in any sibling story's text corpus (title, description, AC, approach, files, tasks), the agent emits an `unresolved[]` entry naming the symbol and the producer story; reviewer decides whether it is a legitimate leaf API (CLI entry point, webhook handler, SDK surface) or a planning gap. Skipped when staging set contains only one story. (b) **Honored deferrals** — when a story's `notes` contains the strict-regex phrases `deferred to (story )?\d+` or `story \d+ (will|owns|covers)`, the agent extracts the target outline index and the noun phrase immediately before the deferral, then verifies that the target story's `acceptanceCriteria` contains a substring of that noun phrase (case-insensitive). When the deferral is not honored, the agent emits an `unresolved[]` entry naming the source story, target story, and unhonored concept. The regex is intentionally narrow — `future work`, `out of scope`, `intentionally not enforced here` are NOT matched because they signal vague aspirations without a named target.
- **`metadata.smellWarnings[]` field on the merged tasks.json (`aimi-cli.sh story-merge`).** Phase 4.2 orphan-symbol findings are now embedded in the output tasks.json (in addition to the existing stderr warning), so the orchestrator's Step 5 report can surface them without parsing stderr. Each entry has shape `{type: "orphan-symbol", storyId: "US-NNN", symbols: ["symbolA", ...], message: "..."}`. The field is written by both legacy and split-mode writers (in split mode, the same array is written to both frontend and backend files so per-file summaries stay self-contained). Absent entirely when no orphan symbols were detected — backward-compatible for downstream consumers.

### Changed

- **`/aimi:plan` Step 5 report renders `metadata.smellWarnings`.** A new `Smell warnings: N orphan-symbol finding(s)` line appears in the report when the merged tasks.json has a non-empty `smellWarnings` array, followed by one bullet per entry showing `storyId`, `type`, `symbols`, and `message`. No sanitization required (fields are CLI-emitted literals or regex-constrained). Omitted entirely when absent or empty.

## [1.99.1] - 2026-06-17

### Fixed

- **`story-merge` ingests `audit-result.json` as a phantom story (`aimi-cli.sh`).** The staging glob excluded only `outline.json`, `*outline*.json`, and `metadata.json`, but Phase 3d.5 writes its debug artifact to `<RUN_DIR>/audit-result.json` in the same directory — so the merger picked it up as a story-shaped JSON object, producing a malformed `tasks.json` entry with no `title`/`description`/`acceptanceCriteria`. Added `audit-result.json` to the exclusion case. Consistent with the strict `[0-9][0-9]-*.json` prefix glob already used by Phase 3d.5's own staging lookup.
- **`validate-stories` rejects natural-markdown single backticks in `title`, `description`, and `tasks[]` (`aimi-cli.sh`).** The suspicious-content regex listed single backtick alongside triple-backtick and `$(`, blocking common phrasings like `Run \`bun run test\` after edit` even though `tasks[]` only flows into LLM prompts (one site: `next.md:135`, XML-wrapped) — never into shell. Narrowed the regex to triple-backticks and `$(`, which remain the actual prompt-injection vectors. Authored `plan.md` Pass 2 prompt doc updated to drop `backticks` from the Forbidden list.

## [1.99.0] - 2026-06-15

### Added

- **Phase 2.4 Codebase Cross-Check gate (`plan.md`).** A new phase that runs between Phase 2 (spec-flow open questions) and Phase 2.5, auto-resolving sanitized spec-flow OQs when the named symbol is already implemented in the target codebase. For each OQ batched through the `aimi-spec-flow-symbol-extractor` agent, the gate runs `grep -F -rn` against every repo discovered by the Phase 0/1 auto-scan — excluding `.git`, `.worktrees`, `.aimi`, `node_modules`, `vendor`, `dist`, `build`, `.next`, `coverage`, `.cache` — classifies each non-doc/non-comment hit by path category (prod / test / migration / other), and records the OQ as resolved with `source: codebaseVerified` and a per-repo `file:line` evidence string. Eliminates the spec-flow-asks-about-already-implemented-code class of friction without round-tripping the user.
- **New `aimi-spec-flow-symbol-extractor` workflow agent.** A single batched extractor spawn per Phase 2.4 invocation receives all sanitized spec-flow OQs and returns a JSON `{anchor: [symbols]}` map naming the candidate symbol(s) implied by each question. Each emitted symbol is constrained to `^[A-Za-z_][A-Za-z0-9_.:-]{5,99}$` and is rejected if shorter than 6 chars or in the stoplist `{id, get, set, User, Service, data, result, error, value, name}` — keeping Phase 2.4 grep targets specific enough to avoid false positives on generic identifiers. Batched so the orchestrator spawns the agent once per phase, not once per OQ.
- **`codebaseVerified` source value on `oqDecisions[]`/`decisions[]` entries.** A ninth allowed value in the `source` enum (joining the existing `specFlow:CriticalQ<n>`, `specFlow:Gap<n>`, `outline`, `scopeNegVerifier`, etc. set), used by Phase 2.4 to mark an OQ as resolved by codebase existence evidence rather than by user answer or research conclusion. Lets downstream `deepen`/`review` distinguish "resolved by what's already shipped" from "resolved by what the user said".
- **Optional `evidence` string field on `oqDecisions[]`/`decisions[]` entries.** A free-form string capturing classified `file:line` hits per repo for OQs resolved through Phase 2.4 (e.g. `prod: apps/web/src/foo.ts:142; test: apps/web/test/foo.spec.ts:18`). Optional everywhere else on the schema — only Phase 2.4 populates it today — so existing decision entries written by other phases remain valid.
- **Three Phase 2.4 failure rows in the `/aimi:plan` Error Handling table.** Covers (a) `grep` invocation failure in a scanned repo (Phase 2.4 records the failure as a per-repo skip, continues with remaining repos, never blocks); (b) malformed `aimi-spec-flow-symbol-extractor` output that fails JSON-shape validation (the gate logs a warning and falls through to user-answered resolution for the affected OQs); (c) extracted symbol rejected by the regex / length / stoplist filter (the gate skips Phase 2.4 for that OQ and falls through to user-answered resolution). All three are non-blocking — Phase 2.4 degrades gracefully back to the pre-existing OQ resolution path.
- **OpenCode translator documentation entry for `aimi-spec-flow-symbol-extractor` (`install.sh`).** The translator's documented agent inventory now lists the new workflow agent alongside the existing `aimi-scope-negative-verifier`, `aimi-cross-story-auditor`, and other Phase-N gate agents, so OpenCode installs ship the same Phase 2.4 capability set as Claude Code.
## [1.98.1] - 2026-06-26

### Fixed

- **OpenCode startup crash on `aimi-migration-dataflow-signals.md`.** `install_agents()` (install.sh) translates `agents/references/migration-dataflow-signals.md` into `~/.config/opencode/agents/aimi-migration-dataflow-signals.md` because the `agents/*/*.md` glob lacks the `references/` exclusion that `install_commands()` enforces. With no frontmatter on the source, `translate_agent` wrote `description: ` (empty), which the YAML parser read as `null`, failing OpenCode's agent schema (`Expected string | undefined, got null description`) and aborting startup. Added a `description` field to the reference so the translated file validates.

## [1.98.0] - 2026-06-10

### Added

- **`AIMI_ROOT` capture + anchored git auto-scan (`plan.md` Step 0 / Phase 1).** Step 0 captures the project root once by walking up to the `.aimi/` marker (the same root the CLI resolves), and the Phase 1 git-repo auto-scan iterates `"$AIMI_ROOT"/*/` instead of the CWD-relative `for dir in */`. A working directory leaked from an earlier Bash call can no longer silently report zero nested repos or break path-within-root validation.
- **Backend-migration scope detection (`plan.md` Phase 0).** The Implementation Scope Detection heuristic gains a backend-migration branch: when the feature combines `migrate`/`migration` with backend/server/API signals and no frontend/UI signals, the frontend-vs-full-stack scope question is skipped and `implementationScope` is left unset (legacy single-file mode).
- **Phase 4.2 cross-story orphan-symbol smell (`aimi-cli.sh story-merge`).** A warning-only post-merge sweep that flags a story whose every extracted symbol (camelCase/PascalCase/snake_case, length ≥ 4, from `implementation.approach`) appears in no other story's text corpus. It is a heuristic over sibling-story prose — **not** codebase dead-code detection — never blocks the merge, and is skipped for single-story merges.
- **New `aimi-scope-negative-verifier` workflow agent + Phase 1.8 Scope-Pruning-Negative Gate (`plan.md`).** When a research conclusion is a negative ("X is absent / not migrated") that would drop or shrink a story, the gate spawns a tool-enabled (Read/Grep/Glob) verifier that independently re-checks existence by data flow and caller tracing — not by re-running the legacy-name grep — and returns CONFIRM/REFUTE/PARTIAL with evidence. A refuted negative restores the pruned story (or surfaces it via AskUserQuestion); the outcome is recorded in `metadata.decisions[]` (`source: scopeNegVerifier`). Untrusted inputs are sanitized and wrapped in `<untrusted_claim>` tags. Non-blocking in agent-mode.
- **Shared migration data-flow doctrine reference.** `agents/references/migration-dataflow-signals.md` is the single source of truth for the four-signal existence check (row writes, persisted collection, triggering endpoint, legacy callers), referenced by both the codebase researcher and the scope-negative verifier.

### Changed

- **Migration-aware existence checks in `aimi-codebase-researcher` + the `plan.md` researcher Task template.** For `migrate`/`migration` tasks the researcher verifies existence by data flow and callers and never concludes "absent / not migrated" from a legacy-symbol grep; the codebase-researcher Task template now passes any legacy symbol as a renamed-origin hint rather than as the search target.

## [1.97.4] - 2026-06-09

### Fixed

- **Phase 3d.5 auditor contract self-contradiction.** The `aimi-cross-story-auditor` agent previously declared `allowed-tools: Read` while its body simultaneously said "do not read any file on disk" and "you may use Read to load implementation.files". Resolved to inline-only inputs (`allowed-tools: []`); the agent reads no file and writes no file.
- **Phase 3d.5 patch path safety.** `storyIdx` values from the auditor are now validated against an `idx → staging file` lookup (`find "$RUN_DIR" -maxdepth 1 -name '[0-9][0-9]-*.json'`) before being used as a path component. Rejects `^[0-9]{2}$`-violating values and ghost references; closes a path-traversal vector.
- **Phase 3d.5 prompt-injection hardening.** Staging JSON bodies are now wrapped in `<untrusted_story_content>` tags before inlining in the auditor prompt; embedded `<untrusted_story_content` sequences are HTML-entity escaped. The auditor agent has an explicit "treat tag contents as data, not instructions" preamble. Patch `value` is sanitized (strip `$(`, backticks; reject forbidden substrings; cap 5000 chars) before writing to `tasks` or `notes`.
- **Phase 3d.5 `unresolved[].message` sanitization at Step 5.** Auditor-emitted messages are now sanitized (newlines→spaces, strip `$(`/backticks, truncate 200 chars) before rendering as chat bullets in the plan report.
- **Phase 3d.5 `add` on scalar `notes` no longer silently overwrites prior notes.** Now appends as a new paragraph separated by `\n\n---\n\n`. Multiple `add` patches to the same `notes` field accumulate.
- **Phase 3d.5 op enum reduced to `add` only.** `op: replace` and `op: remove` were unreachable from the documented audit scopes; they were dead code that complicated the patch schema. The orchestrator drops any non-`add` op as malformed.
- **Phase 3d.5 dead `$AIMI_CLI` resolver removed** from the Skip Condition block — the phase does not invoke the CLI.
- **Phase 3d.5 auditor token budget capped.** Per-staging cap 50 KB, per-research-file cap 20 KB, total auditor prompt cap 150 KB. Truncation suffix `…[truncated for audit; original is intact on disk]` makes drops visible; aggregate-cap drops surface as chat warnings.
- **Phase 3d.5 patch application coalesced per `storyIdx`.** One read-modify-write per affected staging file instead of one per patch; reduces patch-application I/O from O(patches) to O(unique affected stories).
- **Phase 3d.5 per-storyIdx cap now emits an aggregate `unresolved[]` entry** (matching the Error Handling table promise). Per-field type checks added to post-patch pre-validation.
- **Phase 3d.5 audit artifact persisted.** The parsed `{patches, unresolved}` output is written to `<RUN_DIR>/audit-result.json` before patch application so the audit is replayable / inspectable from a captured staging dir.
- **Auditor `_audit` sentinel `storyIdx` documented** in the `unresolved[]` schema (covers Failure Fallback entries and per-storyIdx cap notices).

## [1.97.3] - 2026-06-09

### Added

- Phase 3b outline validator — non-blocking warnings at Phase 3c gate for entries with `summary < 40` chars and entries whose title/summary path-like tokens have no match in the consolidated research `## File References` section. Cap of 10 warning lines with overflow count.
- Phase 3d.5 cross-story DAG audit — new `aimi-cross-story-auditor` workflow agent (Read-only) emits `patches[]` and `unresolved[]`; orchestrator applies allowlisted patches (`dependsOn`, `tasks`, `notes`; max 10 per story) to staging files before story-merge. Skipped when fewer than 2 stories expanded. Auditor failure degrades gracefully — proceeds to story-merge without patches.

## [1.97.2] - 2026-06-03

### Fixed

- `aimi-cli detect-models` in **default mode (no `--research/--review/...` flags)** now preserves the OTHER host's sub-table in `~/.config/aimi/models.json`. Previously the no-flag branch wrote a fresh `{schemaVersion, categories:{<current host>:{...}}}` document via `jq -n`, silently dropping the inactive host's configured models on every invocation. This caused `/aimi:plan`'s automatic resolve to wipe a user's OpenCode model assignments whenever the command ran inside Claude Code (and vice-versa). The fix applies the same merge pattern the flag-mode branch already uses (read existing config → merge by `host_key`). Regression test added: `test_detect_models_default_mode_preserves_other_host`.

## [1.97.1] - 2026-06-03

### Added

- **Console error attribution in post-merge visual verification.** `/aimi:execute` now captures `agent-browser console --json` and `agent-browser errors --json` after every per-story screenshot in a visual wave, and runs an `attribute_console_errors()` pass that links each error/warning back to the wave story most likely to have caused it. Attribution strategies: (a) stack-trace file match against `implementation.files[]`, (b) PascalCase component-name match in error text, (c) wave-shared fallback when neither matches. Output goes into a `## Console (advisory)` section in the wave summary alongside the existing `## Design Review` block. Advisory only — never changes `verification.status`, never blocks the wave.
- Per-story `agent-browser console --clear` before each `open` so the console buffer is per-story, not wave-cumulative. Without this, attribution would silently blame the last-merged story for every prior story's errors.

### Notes

- Requires `agent-browser` ≥ 0.25.x (the version exposing `console` and `errors` subcommands — undocumented in `--help` but present and stable; verified against 0.25.3).
- Multi-`/aimi:execute` runs in parallel that share `--session visual-follow` will see cross-run console contamination (upstream issue `vercel-labs/agent-browser#326`). Workaround: each run uses a unique session name. Not applied here because single-user-single-run is the common case.

## [1.97.0] - 2026-06-03

### Added

- **Structured `<result_json>` contract for story-executor workers.** Workers MUST end their final message with a `<result_json>` block carrying `{status, commit, tests?, typecheck?, knownGaps?, deviations?, failureCause?}`. The orchestrator parses this block as source of truth — prose outside is debugging only.
- `execute.md` wave loop parses `<result_json>` from each worker tool_result: status drives the success/fail branch; `commit` is cross-checked against `git rev-parse HEAD` in the worktree; `failureCause` is surfaced verbatim to the user via `mark-failed`; `knownGaps` is preferred over the legacy `KNOWN-GAP:` commit-trailer grep.

### Changed

- `story-executor` SKILL.md `<execution_flow>` (full + compact templates) and Failure Handling now end on the explicit instruction to emit the `<result_json>` block. The Checklist gains a new line to lock the contract in.

### Rationale

- Measured 5 most-recent `/aimi:execute` worker runs from `Feats/migration`: average **680 result tokens** emitted per worker, of which **~0.8% reused verbatim** by the orchestrator (≈50-200 tokens of structured signal actually consumed). The contract shrinks the consumed payload toward ~120 tokens per worker — ~82% reduction on the orchestrator's next-turn input cost.

### Compatibility

- Workers that DO NOT emit `<result_json>` (legacy) fall back to the existing behavior: Task's own success/failure exit signal + commit verification. No worker is forced to update immediately. New workers MUST emit the block.

## [1.96.2] - 2026-06-03

### Fixed

- `aimi-cli story-merge` no longer attempts to merge the `outline.json` sidecar (written by `plan.md` Phase 3b) as if it were a story. The previous glob in `cmd_story_merge` picked up every `*.json` in the staging directory, including the outline sidecar; the sidecar's shape (a list of `{idx, title, summary}` entries) tripped jq later in Rule 22 / Phase 3.1 / Phase 4.1 with `null (null) has no keys`, aborting the entire merge. The fix filters `outline.json`, any `*outline*.json`, and `metadata.json` from the staging glob before processing. Added test TC9 to lock in the behaviour.

## [1.96.1] - 2026-06-01

### Fixed

- Added missing `aimi-story-expander` workflow agent referenced by `/aimi:plan` Phase 3d. The 1.96.0 plan.md rewrite invoked `subagent_type="aimi-engineering:workflow:aimi-story-expander"` but the corresponding agent file was never authored, causing the orchestrator to fall back to authoring staging JSON inline on every run (defeating the point of parallel Pass 2 expansion). The agent receives one outline entry plus full context (outline, research, decisions, optional specs) and writes one staging JSON file using `outline:NN` dependsOn tokens that `story-merge` later remaps.

## [1.96.0] - 2026-06-01

### Added

- `aimi-cli story-merge` subcommand: consolidates per-story staging files into a validated `tasks.json` with deterministic `US-NNN` ID assignment, DAG cycle detection, wave computation, Rule 22 mock-sync AC routing, Phase 3.1 inventory verdict check, Phase 4.1 coverage ratio check, and atomic `flock`-protected write. Supports `--split full-stack` for paired frontend/backend output and `--agent-mode` to demote hard rejects to warnings in CI.
- `/aimi:plan` outline gate: between Pass 1 outline generation and Pass 2 expansion, the user can approve / rename / add / remove / reorder stories via iterative `AskUserQuestion` pickers. Edits are recorded in `metadata.decisions[]` with new anchor format `outline:edit:<idx>` and `source: "outline"`.
- `/aimi:plan` Pass 2 parallel expansion: each outline entry expands in its own Task sub-agent with `outline:NN` dependsOn tokens; story-merge remaps tokens to final `US-NNN`. Schema-validation failures trigger up to 2 retries with sanitized validator error injected into the next prompt (`$(`, backticks, newlines stripped; truncated to 500 chars).
- `--non-interactive` outline auto-approve: emits `[plan] outline auto-approved (non-interactive): N stories` log line.

### Changed

- `/aimi:plan` Phase 3 + Phase 4 replaced with a two-pass outline+expand pipeline (Pass 1 outline → outline gate → Pass 2 fan-out → `story-merge` deterministic merge). Drop-in: schema of `tasks.json` is unchanged; `/aimi:execute`, `/aimi:status`, `/aimi:deepen` consumers unaffected.
- `metadata.decisions[]` accepts new `source` value `outline` for outline-gate edits (additive; no schema version bump).
- Rule 22 mock-sync AC routing, Phase 3.1 Reference Element Inventory, and Phase 4.1 Coverage Self-Check now execute inside `story-merge` instead of inline in plan.md Phase 3.

### Security

- Pass 2 retry prompt sanitization: validator error strings are stripped of `$(`, backticks, and newlines, then truncated to 500 chars before injection into retry prompts — prevents shell-expansion and prompt-injection vectors from poisoning auto-correction context.
- Staging-path validation: outline-title slug sanitization rejects `..` traversal, `/` characters, and leading dots before staging file paths are constructed. Per-run staging subdirectory `.aimi/.tasks-staging/<topic-slug>-<RUN_TS>/` isolates each run.

## [1.95.1] — 2026-05-28

### Fixed

- `aimi-cli.sh` — `write_global_cli_cache` no longer persists an ephemeral git-worktree path to the global cache (`~/.config/aimi/cli-path`). When `init-session` ran from a `.worktrees/` checkout (e.g. `test-aimi-cli.sh` inside a worktree, or an `/aimi:execute` wave), the worktree-local `aimi-cli.sh` path was cached globally; after the worktree was removed during merge cleanup, every later command resolved `$AIMI_CLI` to a deleted file and failed with exit 127. The write now no-ops on any path containing a `.worktrees/` segment.

## [1.95.0] — 2026-05-28

### Added

- `research-lookup <path>` CLI subcommand — content-aware freshness check for research `.md` files. Compares the research file's mtime against the newest mtime of all source paths listed under its `## File References` h2 bullet section. Prints the resolved path and exits 0 when fresh; prints nothing and exits 1 (stale) when any cited source is newer, missing, or outside the project root. Consumed by `plan` and `deepen` before spawning researchers.
- `research-gc` CLI subcommand — prunes orphaned `.aimi/research/*.md` files older than 30 days that are not referenced by any active `.aimi/tasks/*.json` `metadata.researchPaths` or any `.aimi/brainstorms/*.md` frontmatter `researchPaths`. Called opportunistically (once per session) from `plan` and `deepen` to prevent unbounded accumulation. Silent when nothing is removed.

### Changed

- `plan` / `brainstorm` — reusedResearch map generalized from a flat lookup to a `{kind → path}` map covering all four research kinds (`codebase`, `learnings`, `best-practices`, `framework-docs`). Both commands now populate `metadata.researchPaths` on the tasks.json after writing, closing the orphan gap that previously left per-run research files untracked.
- `deepen` Step 3 reuse-gate — before spawning per-story researchers, deepen now checks `research-lookup` freshness on any existing per-story research file. A fresh hit skips the re-research spawn entirely; a stale or missing file triggers a targeted researcher with `--paths` narrowed to `story.implementation.files`.
- Research agents (`aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`) — output a pointer block (`{outputPath, researchKind, sourcePaths[]}`) instead of restating a summary in the agent response. Callers resolve the actual content from disk via the pointer; reduces orchestrator working-memory and eliminates cross-agent summary drift.

## [1.94.1] — 2026-05-28

### Changed

- `story-executor/SKILL.md` — both the full and compact execution-flow templates now explicitly direct the spawned agent to follow `story.tasks[]` as the ordered implementation recipe when present, with special attention to `"Wire <X> into <Y>"` entries that encode cross-story file wiring. `acceptanceCriteria` remains the completion gate; `tasks[]` is planner guidance. Closes the planner→executor wiring gap where the planner was required to enumerate cross-story integration steps but the executor template never instructed the agent to walk them.

## [1.94.0] — 2026-05-28

### Added

- `get-story-context` CLI command now emits two new top-level keys alongside `story` and `metadata`:
  - `skills` — array of `{name, path, content}` objects assembled from each story's `skills[]` declarations, with tag-breakout escapes (`</required_skills` → `&lt;`) and a 100 KB aggregate cap that drops in reverse-of-insertion order.
  - `designContext` — `{decisions, bundleGuidance}` sourced from `metadata.brainstormPath` and `metadata.designBundle`, respectively. Wires the previously orphaned `[DESIGN_BUNDLE_CONTEXT]` placeholder in `story-executor/SKILL.md` for the first time.
- New internal helper `_resolve_skills_base_dir` in `aimi-cli.sh` mirroring execute.md's prior `SKILLS_BASE_DIR` resolution (Claude Code cache glob; OpenCode plugin dir; silent fallback to empty skills array).
- Four new tests covering the extended `get-story-context`: skills present, skills absent, 100 KB cap drop, designContext extraction.

### Changed

- `story-executor/SKILL.md` (both full and compact templates) — removed the inlined `<required_skills>`, `[DESIGN_CONTEXT]`, and `<design_bundle_context>` blocks. Workers now consume that material from the extended `get-story-context` JSON. Bootstrap step 0a updated accordingly.
- `commands/execute.md` — deleted the wave-loop skill-assembly logic, the Step 3.4 design-context build, the Step 3.6 `SKILLS_BASE_DIR` resolution, and the `REQUIRED_SKILLS` / `DESIGN_CONTEXT` / `DESIGN_BUNDLE_CONTEXT` spawn variables. The orchestrator's working memory per wave is correspondingly smaller.

## [1.93.2] - 2026-05-25

### Changed

- First-run dismissal marker is now **per-host**. The marker file path is `~/.config/aimi/models-prompt-seen-claudeCode` or `~/.config/aimi/models-prompt-seen-opencode` depending on the active host. Picking "Manter o padrão (inherit)" on one host no longer silences the prompt on the other — each host's dismissal is independent. The legacy global marker at `~/.config/aimi/models-prompt-seen` is no longer read; existing users may see one extra prompt after upgrade (on each host where they had dismissed without configuring) and will not see it again after dismissing or configuring on that host.
- `aimi-cli models-prompt-check` now honors the per-host marker as a tie-breaker: when the config file is present but the current host has no configured categories, `skip` is returned if the host's marker exists (explicit dismissal preserved), `prompt` otherwise. The file-missing branch still re-prompts regardless of any marker — the v1.93.0 behavior (deleting `models.json` always re-triggers the prompt) is preserved.
- `aimi-cli models-prompt-dismiss` writes the per-host marker for the active host. Idempotent. Other host's marker is not touched.

## [1.93.1] - 2026-05-25

### Changed

- `aimi-cli models-prompt-check` now decides on the **current host's** configured categories rather than mere file existence. Previously the check returned `skip` whenever `~/.config/aimi/models.json` existed, even if the current host's `categories.<host>` sub-table was missing or empty — which silently left users on all-inherit when they ran a command on a host they had never configured (e.g., opened Claude Code after only configuring OpenCode). Now `prompt` is returned when `get-current-models` would emit all-null for the active host (no category configured, host key absent, host key with empty `{}`, or all category values explicitly null). `skip` requires at least one category for the current host to carry a non-null model id. Schema v1.0 configs are treated as unconfigured (prompt). Empty/malformed files also prompt instead of skipping silently.

## [1.93.0] - 2026-05-25

### Added

- `/aimi:setup-models` slash command for interactive (re)configuration of per-category model assignments at any time. Shows current values for the active host (claudeCode or opencode), then runs the same five-question picker used by the first-run prompt — with current values pre-selected as defaults so the common "tweak one category" workflow takes one keystroke per question. The picker question text is identical to the first-run prompt (Portuguese, per the existing localisation). Writes via `aimi-cli detect-models`, which validates each model id against the host's available-model list and preserves the other host's `categories.<host>` sub-table on merge.
- `aimi-cli get-current-models` subcommand emitting current per-category model assignments for the active host as a JSON object with keys `research`, `review`, `design`, `workflow`, `executor`. Unset entries emit JSON null (not the literal `"inherit"` returned by `resolve-models`) so picker UIs can distinguish "not configured" from an explicit `"inherit"` override and pre-select sensible defaults. Schema v1.0 configs rejected identically to `resolve-models` (stderr warning, all-null on stdout).

### Fixed

- `aimi-cli models-prompt-check` now returns `prompt` whenever `~/.config/aimi/models.json` is missing, regardless of whether the `~/.config/aimi/models-prompt-seen` marker file exists. Previously the marker file suppressed the prompt even after the config was deleted, leaving the user silently stuck on all-inherit defaults with no way to re-trigger the prompt short of also deleting the marker. The marker is no longer read; `models-prompt-dismiss` still writes the marker for backward compatibility with callers in `install.sh` and `cli-path-resolution.md`, but the marker now has no effect on the check.

## [1.92.1] - 2026-05-25

### Fixed

- OpenCode translation: `install.sh` now physically rewrites `Task subagent_type="aimi-engineering:CATEGORY:NAME"` invocations in command bodies to `aimi-task subagent_type="aimi-engineering:CATEGORY:NAME"`. Previously the OpenCode preamble instructed the LLM to perform this rewrite at call time, but the orchestrator sometimes ignored it and called OpenCode's native `task` tool with the plugin-namespaced string — OpenCode rejected the call with `Unknown agent type: aimi-engineering:...` because only flat agent names are registered on the OpenCode side. The body rewrite eliminates that class of error for all 25 namespaced invocations across `/aimi:plan`, `/aimi:brainstorm`, `/aimi:deepen`, `/aimi:review`, `/aimi:design:polish`, and `/aimi:validate-bug`.
- OpenCode preamble Step 1 reworded: now describes per-spawn model selection only (the body uses `aimi-task` directly) and adds a hard prohibition against ever calling the native `task` tool with `aimi-engineering:*` subagent types — covering the remaining rare multi-line `Task(...)` form in `/aimi:execute`'s design-review block which is not eligible for the body rewrite.

## [1.92.0] - 2026-05-25

### Changed

- `models.json` schema migrated from `1.0` to `2.0`. The two-level tier indirection (`categories.<cat> → tier`, `models.<host>.<tier> → modelId`) is replaced with direct one-level mapping (`categories.<host>.<cat> → modelId`). The top-level `.models` key is removed. Five categories are honored: `research`, `review`, `design`, `workflow`, `executor`.
- `aimi-cli detect-models` flag set renamed: the three-tier flags `--fast` / `--balanced` / `--powerful` (all-or-nothing) are replaced with five per-category flags `--research` / `--review` / `--design` / `--workflow` / `--executor` (all five required when any is provided). The interactive picker (TTY and first-run prompt) now asks five per-category questions instead of three per-tier questions.
- First-run prompt documentation in `commands/references/cli-path-resolution.md` and the mirrored block in `install.sh` updated to describe the five-question per-category flow.

### Breaking

- Existing v1.0 configs at `~/.config/aimi/models.json` are no longer honored. `aimi-cli resolve-models` detects v1.0 (presence of top-level `.models` key or `schemaVersion` other than `"2.0"`), emits a stderr warning containing `schema 1.0`, and falls back to all-inherit until the file is regenerated.
- Action required after upgrade: re-run `aimi-cli detect-models` (interactive) or `aimi-cli detect-models --research <id> --review <id> --design <id> --workflow <id> --executor <id>` (flag mode) on each host (`claudeCode` and `opencode`) to write the v2.0 file. The writer preserves the other host's `categories.<host>` sub-table on merge.

## [1.91.0] - 2026-05-25

### Added

- New `executor` agent category for sub-orchestrator spawns. `/aimi:execute` now resolves an `EXECUTOR_MODEL` and annotates `model: <AGENT_MODELS.executor when not "inherit">` on the three `general-purpose` Task spawns (parallel frontend/backend sub-orchestrators and per-story executor). Default tier mapping is `executor=balanced`. Users can override per-tier via `~/.config/aimi/models.json` or via the first-run picker (the `balanced` tier already covered design/workflow; executor now also maps to it by default).
- `resolve-models` output now includes the `executor` key alongside `research`, `review`, `design`, `workflow` (five keys total). Unconfigured executor entries fall back to the literal `"inherit"`.
- OpenCode translation: `install.sh` extracts `EXECUTOR_MODEL` from `resolve-models` and routes `Task(subagent_type="general", model: ...)` spawns through `aimi-task` so the per-call model is honored on OpenCode too. Untyped general-purpose spawns (no `model:` annotation) remain native.

### Added

- `aimi-cli resolve-models` — reads `~/.config/aimi/models.json` and resolves the configured model id for each agent category (`research`, `review`, `design`, `workflow`). Always emits all four category keys; uses the sentinel `inherit` when no override is configured so commands can pass it through without special-casing.
- `aimi-cli detect-models` — interactive generator for the host-aware `~/.config/aimi/models.json` config. When stdin is a TTY, prompts per category; otherwise writes a sensible default mapping. Falls back to a built-in Anthropic default list when the `opencode` binary is not on PATH.
- `~/.config/aimi/models.json` host-aware config: a `categories` map (category name → logical tier) plus a per-host `models` table (`claudeCode` and `opencode`) resolving tiers to concrete model ids. Includes a `schemaVersion` field following the `tasks.json` precedent.
- Per-spawn model selection wired into the planning/research and review/execution commands (`/aimi:plan`, `/aimi:brainstorm`, `/aimi:deepen`, `/aimi:review`, `/aimi:design:polish`, `/aimi:validate-bug`, `/aimi:execute`). On Claude Code, resolved model ids are passed via the native `Task` tool `model:` parameter; the sentinel `inherit` leaves the model at host default.
- `tools/aimi-task.ts` — OpenCode custom tool (TypeScript, loaded by the Bun runtime) that spawns subagents with an explicit `model` parameter, giving OpenCode per-spawn model selection parity with Claude Code. `install.sh` copies the tool and its `tools/package.json` companion into the OpenCode config directory and registers it in `opencode.json`. The tool regex-validates the model id before any shell-out.
- One-time first-run prompt to configure model selection: when no `models.json` exists and no prior dismissal marker is present, commands show a single `AskUserQuestion` offering to configure model selection now or keep the default "inherit" behavior. The prompt is shown at most once (gated on interactive / picker mode only) and permanently suppressed after the user responds via `aimi-cli models-prompt-dismiss`. Two new `aimi-cli` subcommands support this: `models-prompt-check` (echoes `prompt` or `skip`) and `models-prompt-dismiss` (atomically writes `~/.config/aimi/models-prompt-seen`).
- `aimi-cli list-models` — lists available models for the current host as a JSON array on stdout. Claude Code returns `["opus","sonnet","haiku"]`; OpenCode reads `opencode models` and falls back to the built-in Anthropic default list when the binary is absent. Used by the first-run flow so the LLM orchestrator can present real model options to the user.
- `aimi-cli detect-models --fast <model> --balanced <model> --powerful <model>` — new non-interactive tier-flag mode: when all three flags are provided, writes `models.json` with the given tier-to-model assignments and the default category mapping (research=fast, design=balanced, workflow=balanced, review=powerful). Preserves the other host's `models` sub-table when a file already exists. The existing interactive / default-write path is unchanged.

### Changed

- First-run "Configurar agora" flow: model selection now happens at the LLM-orchestrator layer via `AskUserQuestion` (Claude Code) / the `question` tool (OpenCode) with three questions — one per tier (fast / balanced / powerful) — using the model list from `list-models` as picker options. The orchestrator then calls `detect-models --fast … --balanced … --powerful …` with the chosen values. Previously the flow delegated to `detect-models` in a subprocess which could never prompt interactively inside a Bash tool call.

## [1.89.0] - 2026-05-21

### Added

- `--non-interactive` flag for `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish`. Pass `--non-interactive` to skip all interactive prompts and auto-defer every Open Question (agent/CI mode). Interactive (`picker`) mode is now the default for all three commands.

### Changed

- `/aimi:plan`, `/aimi:brainstorm`, and `/aimi:design:polish` default to **interactive mode** (`INTERACTIVE_MODE=picker`). Previously these commands could silently fall through to `agent` mode when running in a non-TTY shell (e.g. inside OpenCode's bash tool calls), suppressing all user-facing questions. The bare-TTY fallback in `detect-interactivity` has been removed so a hostless non-TTY shell no longer triggers agent mode.
- `cmd_detect_interactivity` in `aimi-cli.sh` now returns `picker` as the default. Agent mode is reached only through explicit opt-out: `--non-interactive` flag, `AIMI_AGENT_MODE=true`, or `CI=true`.

### Fixed

- OpenCode agent-mode misclassification: `detect-interactivity` previously returned `agent` for OpenCode sessions because OpenCode runs bash tool calls in a non-TTY shell and does not export `OPENCODE_CONFIG_DIR` in that context, causing the TTY fallback (step 6) to fire. Removing the bare-TTY fallback ensures the command correctly defaults to `picker` on OpenCode.

## [1.88.0] - 2026-05-21

### Removed

- `aimi-every-style-editor` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-ankane-readme-writer` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-lint` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-pr-comment-resolver` agent — out-of-scope / orphaned; no active command consumer.
- `aimi-figma-design-sync` agent — out-of-scope / orphaned; no active command consumer.

### Added

- `/aimi:validate-bug` command (`commands/validate-bug.md`): reproduces and validates bug reports by delegating to the `aimi-bug-reproduction-validator` agent. Accepts a free-form bug description, runs a structured reproduction workflow, and reports whether the bug is confirmed, cannot be reproduced, or is a user error.

### Changed

- `aimi-bug-reproduction-validator` agent generalized: Rails-specific bias removed from its Investigation Techniques section so the agent operates effectively across all languages and frameworks.
- `/aimi:design:polish` now optionally delegates to `aimi-design-iterator` for a multi-cycle visual iteration pass (screenshot → analyze → improve loop) in addition to the existing inline polish workflow.

## [1.87.1] - 2026-05-20

### Fixed
- `cmd_update_field` was dropping the final segment of a dotted path (e.g., `verification.status` built `.verification` instead of `.verification.status`) because `printf '%s' | sed | while read -r` skips the loop body for the last unterminated segment. Replaced the pipe chain with an `IFS=. read -ra` herestring split that is trailing-newline-safe, so `update-field US-NNN verification.status passed` now patches only the leaf field and preserves all sibling fields on the parent object.

## [1.87.0] - 2026-05-15

### Added
- XDG-compliant cache location at `~/.config/aimi/cli-path` and `~/.config/aimi/worktree-path` for storing the resolved CLI and worktree paths. The location can be overridden via the new `AIMI_CONFIG_DIR` environment variable (e.g., `AIMI_CONFIG_DIR=/custom/path`), which governs cache file placement only — Layer 2 plugin discovery continues to use `CLAUDE_CONFIG_DIR`.
- New `_aimi_config_dir()` helper in `aimi-cli.sh` encapsulates the `AIMI_CONFIG_DIR`-or-XDG-default resolution, making all cache read/write call sites consistent.
- "Per-Call Resolution" section in `commands/references/cli-path-resolution.md` documenting the shell-isolation hazard and the required per-call `cat` re-read pattern with explicit precondition (Step 0 full resolution must have run first to prime the new path).

### Changed
- `plan.md`, `execute.md`, `brainstorm.md`, `skills/story-executor/SKILL.md`, and `skills/task-planner/SKILL.md` migrated to per-call CLI re-read: each Bash call that needs `$AIMI_CLI` now resolves it inline via `cat ~/.config/aimi/cli-path` rather than relying on a shell variable from a prior call.
- `auto-approve-cli.sh` hook updated to recognize the new XDG paths (`~/.config/aimi/cli-path`, `~/.config/aimi/worktree-path`) alongside the legacy `~/.claude/aimi-engineering-{cli,worktree}-path` paths, so CLI cache reads and writes do not trigger unexpected permission prompts during the migration window.
- Hard-coded legacy `~/.claude/aimi-engineering-cli-path` references in `commands/init.md`, `CLAUDE.md`, `install.sh`, and `settings.local.json` updated to reflect the new XDG location.

### Fixed
- Shell-isolation hazard where `$AIMI_CLI` resolved correctly in one Bash call but expanded to empty in every subsequent call (each Claude Code Bash invocation runs in an isolated subshell), causing silent "command not found: `<subcommand>`" failures throughout plan, execute, and brainstorm workflows.

### Compatibility
- Legacy `~/.claude/aimi-engineering-cli-path` and `~/.claude/aimi-engineering-worktree-path` files remain supported via a read-both fallback: `aimi-cli.sh` tries the new XDG location first and falls back to the legacy path if the new file is absent. **No user action is required.** The legacy read-both fallback is planned for removal in the next MAJOR version bump.

## [1.86.7] - 2026-05-13

### Changed
- Trimmed the Pre-Save Checklist in `brainstorm.md` Phase 4 by removing the eight items marked `(advisory/non-blocking)` that restate rules already enforced in the document body (Design Decisions section presence, Personas/View Modes/Layout Variation subsections, Specs and Prototypes section presence, generated-bundle YAML key ordering, researchPaths emission). Added a one-line preamble directing readers to the body rules as the source of truth. The Pre-Save Blocking Gate — Open Questions section (with `[resolved: ...]` / `[deferred: ...]` sentinels, bundle-source clarification, and agent-mode auto-defer fallback) is preserved verbatim. Behavior unchanged.

## [1.86.6] - 2026-05-13

### Changed
- Consolidated the `AIMI_ROOT_IS_GIT_REPO` branching rule, the per-story project-grouping pattern (absolute-path resolution, path-validation regex, no-leading-./, no-.. rules), and the per-project cleanup rule into one "Multi-Repo Handling" section at the top of `execute.md` (placed between Step 0 and Step 0.5). Each call site now carries a one-line pointer to the section while keeping the decision pseudocode inline — no per-run Read cost. The wave-loop group_key/project_roots/base_sha/all_worktrees pseudocode, setup-branch invocations, PROJECT_GUIDELINES_MAP build, merge-per-project logic, and cleanup iteration are all preserved verbatim.

## [1.86.5] - 2026-05-13

### Changed
- Folded the four near-identical inline "check flag → emit once → set true" blocks for `echoedBundleEarlyExit`, `echoedBrowserUnavailable`, `echoedSessionLost`, and `echoedPickerUnavailable` in `brainstorm.md` into one "Once-per-session echo helper" rule documented near Step 0b. Each call site now invokes the helper with its flag name and message. Flag names, message texts, working-memory initialization, and surrounding contextual prose are preserved verbatim.

## [1.86.4] - 2026-05-13

### Changed
- Consolidated the visual-follow lifecycle (detection, session-open, reuse-within-wave, keep-open-on-completion) from the four scattered sites in `execute.md` (Step 0.7, Step 3.3, Step 4 wave loop, Post-Loop) into one "Visual Follow Lifecycle" section placed before Step 0.7. Each call site now points at the consolidated section. Behavior preserved verbatim — MALFORMED_VERIF abort, per-story screenshot+compare logic, session name `visual-follow`, and the "Visual follow session still open" completion message all remain inline at their original sites.

## [1.86.3] - 2026-05-13

### Changed
- Collapsed the three near-identical "How `<flag>` works at runtime" subsections in `brainstorm.md` Override Keywords section (`show variants`, `vary ui`, `render bundle`) into one parameterized rule table (columns: trigger phrase, flag name, activation log line, scope/clear condition, precedence over Step 0a) and a single co-occurrence statement covering all pairwise and triple-overlap semantics. The user-facing summary table is preserved verbatim. Behavior unchanged — every flag name, log line, scope, clear condition, and precedence-over-Step-0a rule is identical.

## [1.86.2] - 2026-05-13

### Changed
- Extracted input-sanitization rules and topic-slug derivation algorithm from `brainstorm.md` and `execute.md` into `commands/references/sanitization.md` and `commands/references/topic-slug.md`. Both commands now cite the new reference files instead of restating the rules inline, eliminating the stale line-number citation in `execute.md` Step 3.4. Behavior is preserved verbatim — pure prose deduplication.

## [1.86.1] - 2026-05-13

### Fixed
- `detect-interactivity` no longer returns `agent` inside Claude Code or OpenCode when stdin is not a TTY. Both hosts run command bash bodies in non-TTY subshells, so the previous `[ ! -t 0 ]` check misclassified every interactive session as agent mode — causing Phase 0.5 / Phase 1.8 / Phase 2.5 OQ gates in `/aimi:plan` to silently auto-defer every open question instead of prompting the user. The check now treats `CLAUDECODE=1` and a set `OPENCODE_CONFIG_DIR` as picker-available regardless of TTY state. `AIMI_AGENT_MODE=true` and `CI=true` still force agent mode as before.

## [1.86.0] - 2026-05-13

### Added
- Phase 1.8 (Post-Research Open Questions Gate) in /aimi:plan — surfaces every researcher's `## Open Questions` and `[PROMOTE-TO-OPEN-QUESTIONS]` entries via AskUserQuestion before story decomposition; auto-defers under AIMI_AGENT_MODE.
- Phase 2.5 (Spec-Flow Gap Gate) in /aimi:plan — surfaces the spec-flow analyzer's `### Missing Elements & Gaps` and `### Critical Questions Requiring Clarification` entries before story decomposition; auto-defers under AIMI_AGENT_MODE.

### Changed
- metadata.decisions[].source schema extended with three new forms: `researchFile:<basename>:OQ<n>`, `specFlow:CriticalQ<n>`, `specFlow:Gap<n>`.

## [1.85.0] - 2026-05-12

### Changed
- Subagent spawn prompts now use pointer-only context handoff: each spawned agent receives only the story ID in a `task_pointer` block and fetches its full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action, keeping the orchestrator's working memory slim across waves and eliminating inlined story bodies and prototype HTML from spawn prompts.
- New `get-story-context` CLI subcommand added to `aimi-cli.sh`: given a story ID, emits the full story JSON (including acceptance criteria, implementation block, verification, and gate fields) so subagents can self-bootstrap without relying on orchestrator-inlined payloads.

## [1.84.0] - 2026-05-12

### Added
- `normalize-verification` CLI subcommand: rewrites bare-string verification fields into the object form `{strategy, status, url, expect}` with atomic tmp+mv write.
- Visual Source-of-Truth Protocol (V1/V2/V3) in story-executor SKILL.md: pre-implementation enumeration rail for visual stories, gated on `verification.strategy == "visual"` or non-empty PROTOTYPE_CONTEXT.
- Per-element PASS/DIVERGES/KNOWN-GAP table requirement in the Reference-Artifact Parity Pass (visual stories only).
- `KNOWN-GAP:` trailer persistence: execute.md captures trailers from worker commits into `.aimi/known-gaps/YYYY-MM-DD-<storyId>.md` and aggregates them in the Step 5 final report under `## Known Gaps`.
- Auto-spawned `aimi-design-implementation-reviewer` after each visual story merges; review output captured in the Step 5 final report under `## Design Review`.

### Changed
- `validate-stories` now rejects any story whose `verification` is a bare string (must be an object with a `strategy` key).
- `/aimi:plan` Phase 4.5 invokes `normalize-verification` before validators, auto-migrating planner-emitted string verifications in place.
- `/aimi:execute` Step 0.7 now aborts (non-zero exit) on malformed verifications instead of warning and continuing; abort message lists offending story IDs and points at `normalize-verification` for remediation.
- Gap-trailer token renamed from `KNOWN GAP:` (with space) to `KNOWN-GAP:` (hyphenated) in story-executor SKILL.md and the verdict-table label, enabling clean `grep -E '^KNOWN-GAP:'` parsing.

## [1.83.0] - 2026-05-12

### Added
- `/aimi:plan` Phase 0.5 now scans BusinessSpec/DesignSpec content for marker-style Open Questions (`[a confirmar]`, `[TBD]`, `[to confirm]`, `[to be confirmed]`, `[to be defined]`) and surfaces each via AskUserQuestion with source+anchor. Spec-marker resolutions are recorded in working-memory `oqDecisions[]` only; spec files are never written back to. Aggregate cap of 20 entries.
- `/aimi:plan` Phase 1 now spawns `aimi-design-bundle-researcher` when invoked directly against a Claude Design handoff bundle (no prior brainstorm). Restores parity with the brainstorm-to-plan flow; resulting Open Questions merge into the Phase 0.5 list before continuing to Phase 1.5.

### Fixed
- `aimi-cli detect-design-bundle` now uses case-insensitive `find -iname` for spec file discovery, so bundles with camelCase filenames (`businessSpec.md`, `designSpec.md`) are detected correctly. Returned paths preserve actual on-disk casing.

### Changed
- Schema v3.3 documentation in `plan.md` now includes a `responseShape contract (frontend-only mode)` block explaining the flat-key constraint and why dotted keys like `portfolio.totalUsinas` are rejected by `validate-tasks`.

## [1.82.0] - 2026-05-12

### Added

- **Plan command: Phase 3.1 Reference Element Inventory (BLOCKING when triggered):** New `### Phase 3.1: Reference Element Inventory (BLOCKING when triggered)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 3 section, before `dependsOn` Inference Rules). When any story declares a reference artifact (`prototypeAnchor`, `specSection`, `referenceCommand`, `referenceFixture`, `migrationDiff`, `referenceUrl`, etc.), opens the artifact and enumerates every addressable element in the cited region using kind-specific vocabulary (HTML/UI, OpenAPI/JSON Schema, CLI man page, SQL/migration diff, business rules table). Records findings as an `Element | Locator | Verdict | AC anchor` table; every row must be marked `encoded` or `excluded` with a written reason before story JSON is emitted. Block Phase 4 until all rows are verdicted; agent-mode fallback auto-marks unverdicted rows as `deferred`. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Phase 4.1 Coverage Self-Check (BLOCKING):** New `### Phase 4.1: Coverage Self-Check (BLOCKING)` block inserted into `plugins/aimi-engineering/commands/plan.md` (Phase 4 Derive Metadata section, before Write File). For each story with a Phase 3.1 inventory, computes `ac_anchors / proto_elements` ratio; if `ac_anchors < floor(proto_elements * 0.6)`, returns to Phase 3.1 to add AC lines or upgrade rows to `excluded`. Blocks Write File until the ratio is satisfied for every affected story; agent-mode fallback emits a structured deficit warning and proceeds. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.
- **Plan command: Anti-Citation-Bias Reminder:** New `### Anti-Citation-Bias Reminder` block inserted into `plugins/aimi-engineering/commands/plan.md` (after Schema v3.3 Structure, before Checklist Before Writing). Clarifies that the validator only enforces citation format — not completeness, compositional fidelity, or behavioral coverage. Explicitly requires encoding of behavioral obligations and edge cases even without quotable literals, and recommends chaining citations for compositional obligations. Not labeled BLOCKING (worldview reminder, not a gate).
- **Researcher agents: `## Contracts` quoting requirement:** New `## Contracts` section inserted into both `plugins/aimi-engineering/agents/research/aimi-codebase-researcher.md` and `plugins/aimi-engineering/agents/research/aimi-framework-docs-researcher.md`. Requires verbatim quoting of every consumed contract (typed signatures, REST/RPC shapes, CLI flag lists, DB schema, SDK public APIs) into the research file body with `file:line` citation — one fenced block per contract, no invention or inference of shapes.
- **Story executor: Reference-Artifact Parity Pass (BLOCKING when triggered):** New `## Reference-Artifact Parity Pass (BLOCKING when triggered)` named section inserted into `plugins/aimi-engineering/skills/story-executor/SKILL.md` (before Prompt Template). Fires when a story declares any reference artifact or any AC line contains a prototype/spec citation or `verification.strategy` implies a reference. Procedure: load reference → enumerate addressable elements in cited region → cross-check against implementation → per-element verdict (`Implemented` or `KNOWN GAP: <element> — <reason>` appended to commit body). Silent drops are not acceptable. Blocks commit until every element has a verdict; agent-mode fallback logs `Parity pass skipped — reference not readable: <path>` and proceeds. Also added as step 3.5 in the canonical prompt template `<execution_flow>` and as a one-sentence extension to the compact template `<execution_flow>`.

### Changed

- **Plan command: Phase 1.7 Research File Ingestion trigger extended to `quick` tier:** The `## Phase 1.7: Research File Ingestion` trigger in `plugins/aimi-engineering/commands/plan.md` now fires for `researchDepth` `quick`, `standard`, or `deep` (previously `standard` or `deep` only). The no-op case shrinks to `skip` or unset. Mirrored in `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.81.0] - 2026-05-12

### Added

- **Plan command: Phase 1.7 Research File Ingestion (US-001):** New `## Phase 1.7: Research File Ingestion` section inserted between Phase 1.6 and Phase 2 in `plugins/aimi-engineering/commands/plan.md`. When `researchDepth` is `standard` or `deep`, reads the full on-disk content of every path in `metadata.researchPaths`, deduped against `reusedCodebasePath` and `reusedBestPracticesPath` (already loaded by Phase 1.6). Missing files are silently skipped; no per-file or aggregate size cap is applied. Each loaded file is wrapped as `<research_file path="...">` with light HTML-entity escape on literal wrapper-tag sequences (analogous to the `prototype_html` escape pattern). Collected blocks are stored in `researchFileBlocks` and threaded into Phase 3 alongside `prototypeBlocks` so acceptance-criteria authoring draws on complete on-disk research detail rather than capped summary returns. `quick`, `skip`, and unset tiers preserve previous summary-only behavior bit-for-bit. Mirrored into `plugins/aimi-engineering/skills/task-planner/references/pipeline-phases.md`.

## [1.80.0] - 2026-05-11

### Added

- **Pre-Save Blocking Gate for Open Questions in `/aimi:brainstorm` (US-001):** The Pre-Save Checklist at `plugins/aimi-engineering/commands/brainstorm.md` is strengthened with a `### Pre-Save Blocking Gate — Open Questions` block that counts entries under `## Open Questions` lacking a `[resolved: <choice>]` or `[deferred: <reason>]` sentinel suffix, loops `AskUserQuestion` until every OQ carries one, and writes the sentinel back to the OQ line as the idempotency marker. Bundle-sourced OQs (lines originating from `BusinessSpec § 11` or `DesignSpec § 8`) are NOT exempt — `bundleAddressedTopics` covers chat-question categories, not spec pendencies. Agent-mode fallback auto-marks every unresolved OQ as `[deferred: agent-mode auto-defer]` before save.
- **Defensive Phase 0.5 Open Questions Resolution Gate in `/aimi:plan` (US-002):** New `### Phase 0.5: Open Questions Resolution Gate` section inserted between Phase 0 and Phase 1 of `plugins/aimi-engineering/commands/plan.md`. Parses the brainstorm `## Open Questions` section; for each line without a `[resolved: ...]` or `[deferred: ...]` sentinel, calls `AskUserQuestion`, appends the sentinel via `Edit`, records the choice in working memory `oqDecisions: { <oqId>: <choice> }` for use in Phase 4 `metadata.decisions[]`, and blocks Phase 1 until every OQ is sentinelled. Agent-mode fallback: auto-defer (do not block). Catches stale brainstorms that bypassed the upstream save-gate.
- **`validate-stories` gate-schema enforcement in `aimi-cli.sh` (US-003):** `cmd_validate_stories` now rejects the plural `gates` field with `<id>: gate: 'gates' field is invalid; use singular 'gate' (see plan.md L687-692)` and validates the singular `gate` object shape by requiring `type`, `status`, and `prompt` keys (emits `<id>: gate: missing required field <name>` per missing key). Errors flow through the existing `{valid, errors[]}` output channel — no `ERROR:` prefix, no exit-per-error. Three new fixtures registered in `test-aimi-cli.sh` (`test_validate_stories_gate_field`): plural `gates` (fail), singular `gate` missing `type` (fail), well-formed singular `gate` (pass).

### Changed

- **`/aimi:plan` Phase 4.5 validator note extended (US-004):** The existing note around `validate-stories (US-001) catches malformed skills[]` is extended to also document the new gate-schema enforcement — both `gates` plural rejection and singular `gate` shape validation.

## [1.79.0] - 2026-05-11

### Added

- **`validate-tasks` subcommand in `aimi-cli.sh` (US-006, gap-analysis case 6):** New CLI subcommand that mechanically enforces citation contracts in a tasks.json file before execution. Reads `acceptanceCriteria[]` entries flagged as visual and verifies each contains at least one verbatim DesignSpec citation anchored as `"<literal>" (DesignSpec § N.N L<line>)`. Exits non-zero with a structured error report on first violation, preventing story execution from proceeding with uncited visual ACs.
- **Rule 19a in `/aimi:plan` Phase 3 (US-001, US-002, US-003, gap-analysis cases 1, 2, 3):** Verbatim DesignSpec citation requirement for visual acceptance criteria. Any AC that describes a visual element (layout, copy, label, badge, header, footer, column header, KPI label, button text, subtitle) must embed the exact literal string from the DesignSpec section followed by a citation anchor in the form `"<literal>" (DesignSpec § N.N L<line>)`. Applies to H1 text, subtitles, KPI labels, column headers, button labels, footer text, and badge copy. Planner must resolve the section number and line number from the attached DesignSpec before emitting the story.
- **`source` field requirement on `backendSpec.endpoints[]` and `responseShape` (US-007, gap-analysis case 7):** Every entry in `backendSpec.endpoints[]` must carry a `source` field citing the spec document and section that mandates the endpoint (e.g., `"source": "BusinessSpec § 3.2"`). Every `responseShape` field in frontend-only plans must likewise declare its provenance. A `derived:` escape hatch is available for legitimately computed shapes whose structure is not directly specified in any spec document (e.g., `"source": "derived: aggregated from /users and /roles responses"`).
- Gap-analysis cases 4, 5, 8 are deferred to v1.80.

## [1.78.0] - 2026-05-11

### Added

- **`aimi-bundle-prototype-author` agent (US-002):** New research-category agent (`plugins/aimi-engineering/agents/research/aimi-bundle-prototype-author.md`) that generates self-contained bundle prototype HTML files from a design bundle and brainstorm context. Reads BusinessSpec/DesignSpec, applies design tokens, and emits a fully styled interactive prototype.
- **`bundle-prototype-status` CLI subcommand (US-003):** New `aimi-cli.sh` subcommand that reads `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json` and reports the current generation status (pending, in-progress, complete) for a given topic slug.
- **`bundle-prototype-finalize` CLI subcommand (US-004):** New `aimi-cli.sh` subcommand that marks a bundle prototype sidecar as finalized and records the output HTML path, enabling downstream commands to locate the generated prototype.
- **`/aimi:brainstorm` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty in the tasks metadata, brainstorm automatically invokes `aimi-bundle-prototype-author` to generate bundle prototype HTML before surfacing questions to the user.
- **`/aimi:plan` bundle prototype integration (US-001):** When a design bundle is detected and `prototypes[]` is empty, plan auto-generates bundle prototype HTML via `aimi-bundle-prototype-author` during the research phase, then passes the generated path as a prototype anchor for visual story decomposition.
- **"render bundle" override keyword:** Both `/aimi:brainstorm` and `/aimi:plan` recognize a case-insensitive `render bundle` substring in the feature description as a one-shot override that forces bundle prototype generation even when `prototypes[]` is already populated.
- **Sidecar idempotency at `.aimi/brainstorms/prototypes/<topic-slug>-bundle-sidecar.json`:** Bundle prototype generation is idempotent — if a sidecar file already exists at the canonical path for a given topic slug, the author agent skips re-generation and returns the existing output HTML path.

## [1.77.0] - 2026-05-08

### Changed

- **Per-entry character cap raised from 600 to 5000:** Applies to `acceptanceCriteria[]` and `tasks[]` entries. Loosens the previous limit that was forcing truncation of detailed criteria and recipe steps. `title` (200) and `description` (500) caps unchanged.
- **`tasks[]` array length cap raised from 20 to 50:** Allows richer mechanical recipes for complex stories. Soft target of 3–15 entries remains as planner guidance.

## [1.76.0] - 2026-05-08

### Added

- **`/aimi:plan` now populates `tasks[]` on every user story (US-001):** Phase 3 Story Decomposition step 9.6 generates a horizontal mechanical breakdown of 3–15 concrete sub-steps per vertical story in verb-object phrasing. Integration steps (`"Wire <X> into <Y>"`) are mandatory whenever `implementation.files` lists a path shared with another story, closing the planning gap that caused orphaned tabs and missing routes in parallel-worktree executions.

## [1.75.0] - 2026-05-08

### Added

- **Optional `tasks[]` free-form sub-step checklist on userStories (US-001):** Stories may now include a `tasks` array (max 20 items, each ≤600 chars) of free-form sub-step strings displayed to executors as a checklist. The field is optional and additive; existing tasks.json files are unaffected.
- **Tasks-file schema bumped from 3.2 to 3.3 (US-002):** `schemaVersion` advances to `"3.3"`. The bump is additive — `validate-stories` accepts the new `tasks[]` field and enforces string elements.

### Changed

- **`/aimi:plan` now produces vertical-slice deliverables instead of layer-atomic stories (US-003):** Story decomposition targets end-to-end feature slices (each story delivers user-visible value across all layers) rather than horizontal layer boundaries. Decomposition guidance in `task-planner` updated accordingly.

## [1.74.0] - 2026-05-06

### Added

- **`researchPaths` frontmatter in brainstorm output (US-001):** `/aimi:brainstorm` now records the absolute paths of every research file it produced (`*-codebase.md`, `*-best-practices.md`, etc.) in the brainstorm document's YAML frontmatter so downstream commands can reuse them.
- **`paths` scope parameter on aimi-codebase-researcher (US-003):** The codebase researcher now accepts an optional `paths:` parameter that scopes its `Glob`/`Grep` searches to the listed directories or files instead of globbing the whole repo.
- **Path-hint extraction in brainstorm and plan (US-004):** Both commands now extract path-like tokens from the feature description (`$ARGUMENTS`) and forward them to the codebase researcher as the `paths:` scope when present.

### Changed

- **`/aimi:plan` reuses brainstorm research (US-002):** When a matched brainstorm exposes `researchPaths` and the files exist on disk with mtime ≤14 days, plan skips spawning `aimi-codebase-researcher` and `aimi-best-practices-researcher` and reads the existing files instead. Phase 5 reports `Research reused: [N] file(s) from brainstorm` when reuse occurs. Legacy brainstorms without `researchPaths` are unaffected.
- **Default `researchDepth` lowered from `standard` to `quick` (US-005):** Across `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, and `aimi-framework-docs-researcher`. Reduces default summary cap and shrinks per-research token cost when callers do not specify a depth.

## [1.73.1] - 2026-05-05

### Fixed

- **`aimi-cli (detect-design-bundle):`** `--root <path>` now also matches when `<path>` itself is a bundle directory, not only when it's a parent containing bundles. Previously returned `null` when callers pointed `--root` at the bundle itself.
- **`aimi-cli (help):`** `<subcommand> --help` and `<subcommand> -h` now print the full help doc instead of returning "Unknown flag" and exit 1 from strict subcommand parsers (`init-session`, `detect-design-bundle`, `setup-branch`, `gate-pass`) or being misinterpreted as positional input by other subcommands.

## [1.73.0] - 2026-05-05

### Fixed

- **`commands (US-001):`** Plan and brainstorm now read the `prototypes` key from design-bundle metadata and pass `--root` instead of the non-existent `--bundle` flag, so prototype HTML actually loads.
- **`commands (US-008):`** Executor's PROTOTYPE_CONTEXT builder validates `prototypeAnchor` and AC-cited paths against AIMI_ROOT before loading, preventing path-traversal escapes.

### Added

- **`brainstorm (US-002):`** Brainstorm emits bundle-discovered prototype paths in the frontmatter `prototype:` key and a `## Prototypes` body section with Path/Source/Question Category columns; plan parses both.
- **`plan (US-003):`** Phase 3 rule 19 requires every visual-layout AC to cite a prototype region using `(prototype: path §heading)` or line-range fallback `(prototype: path:Lstart-Lend)`. Plan canonicalizes prototype HTML for layout; spec for tokens, types, and states.
- **`design-bundle-researcher (US-004):`** New §16.5 `Spec-Prototype Coverage Gaps` section surfaces regions present in prototype HTML but missing or partial in DesignSpec.md, with high-confidence-missing markers for Open Questions promotion.
- **`plan (US-005):`** Phase 3 rule 20 auto-injects a mock-sync AC onto stories whose `implementation.files` match schema/types/zod path globs, with idempotency guard for re-plan and graceful degradation when no mocks/ directory exists.
- **`design-reviewer (US-006):`** `aimi-design-implementation-reviewer` now accepts polymorphic prototype source (Figma URL, prototype HTML path, or screenshot) with advisory degradation when no source is provided.
- **`review (US-007):`** `/aimi:review` automatically invokes the design-implementation-reviewer once per visual story when `metadata.prototypePaths` is non-empty, with graceful skip when `agent-browser` is not installed.
- **`plan,execute,executor (US-008):`** Plan emits `implementation.prototypeAnchor` for visual stories citing a single prototype; executor pins that anchor as label A in PROTOTYPE_CONTEXT, falling back to AC-parse when the field is absent.
- **`plan (US-009):`** Phase 3 rule 22 routes the rule-20 mock-sync AC onto consumer stories that mention the new field by name (with CamelCase entity-name fuzzy fallback), moving rather than copying when a consumer matches.

## [1.72.0] - 2026-05-05

### Added

- **`detect-design-bundle` CLI subcommand (US-001):** New `aimi-cli.sh` subcommand that detects whether a project contains a BusinessSpec and/or DesignSpec file, emitting structured JSON output consumed by brainstorm, plan, and story-executor workflows.
- **test-aimi-cli.sh bundle detection tests (US-002):** Test coverage for `detect-design-bundle` — presence, absence, and partial-match cases added to the CLI test suite.
- **`aimi-design-bundle-researcher` agent (US-003):** New 16-section structured passthrough agent that reads BusinessSpec and DesignSpec files and emits a compressed research summary for downstream brainstorm and plan consumers.
- **brainstorm bundle-aware research consolidation (US-004):** Brainstorm now invokes `aimi-design-bundle-researcher` when a bundle is detected, merging spec insights into the question-selection and variant-axis stages before surfacing them to the user.
- **bundle-aware token probe in visual-variants.md (US-005):** `visual-variants.md` reference now includes a token probe step that reads `metadata.designTokens` when a design bundle is present, feeding spec-extracted tokens into the variant axis decision tree.
- **brainstorm short-circuits visual variants when bundle present (US-006):** When a DesignSpec is detected, brainstorm skips the token-extraction fallback path and uses spec-defined tokens directly, preventing redundant extraction work.
- **spec-aware brainstorm document (US-007):** Brainstorm output document gains Personas, View Modes, Layout, and Specs sections populated from bundle research when a BusinessSpec or DesignSpec is present.
- **plan ingests bundle into tasks.json `metadata.designBundle` (US-008):** `/aimi:plan` populates `metadata.designBundle` and `metadata.designTokens` fields in the generated `tasks.json` when a design bundle is detected at planning time.
- **story-executor design-bundle fidelity guidance (US-009):** Story-executor reads `metadata.designBundle` and `metadata.designTokens` from `tasks.json` and surfaces spec-aware read order with rule-ID citation in its implementation guidance.
- **`/aimi:deepen` spec cross-reference (US-011):** `/aimi:deepen` now cross-references BusinessSpec and DesignSpec when enriching story acceptance criteria, citing spec rule IDs in the enriched output.

## [1.71.0] - 2026-04-29

### Added

- **`vary ui` override keyword (US-005):** Typing `vary ui` in a brainstorm visual question opts into UI-token variation for the next variant axis selection, activating color, typography, radii, and surface axes even when project tokens are present.

### Changed

- **brainstorm visual variants (US-005):** When project design tokens are present, variant axes now default to UX-branch axes (layout, hierarchy, flow) instead of UI-branch axes. UI-branch axes (color, typography, radii, surface) activate only on full token-extraction fallback or explicit `vary ui` override. This preserves prior behavior for projects without tokens while improving consistency for token-backed design systems.

## [1.70.0] - 2026-04-29

### Added

- **design references (US-001–US-009):** 12 new reference documents ported from Anthropic Impeccable v3.0.5 into `skills/frontend-design/references/`: `brand.md`, `product.md`, `color-and-contrast.md`, `typography.md`, `spatial-design.md`, `motion-design.md`, `responsive-design.md`, `ux-writing.md`, `interaction-design.md`, `cognitive-load.md`, `heuristics-scoring.md`, `personas.md`.
- **design references index:** `skills/frontend-design/references/index.md` — registry mapping each reference slug to its file and canonical trigger phrase for use by brainstorm lazy-load hooks.
- **commands (`/aimi:design:shape`, `/aimi:design:craft`, `/aimi:design:critique`, `/aimi:design:audit`, `/aimi:design:polish`):** 5 new design slash commands under `commands/design/` covering idea shaping, component crafting, design critique, accessibility/heuristics audit, and visual polish workflows.
- **brainstorm lazy-load hooks:** `loaded_design_refs[]` working memory array plus 4 hook points in `skills/frontend-design/SKILL.md` enabling on-demand reference loading during brainstorm sessions without pre-loading all 12 documents.

### Changed

- **skill (`frontend-design` SKILL.md):** Full rewrite — 42 lines expanded to ~161 lines. Integrates shared design laws (Gestalt, Fitts, Hick, aesthetic-usability effect), absolute bans list, and AI-slop detection test. Now references the 12 ported design documents via the lazy-load hook system.

### Security

- Design reference content ported under Apache-2.0 license from Anthropic Impeccable v3.0.5. License attribution preserved in reference file headers.

### Notes

- US-012: CLI test suite (325 tests), YAML frontmatter smoke checks (SKILL.md + 5 commands/design/*.md), and references/ token budget (1657/3000 lines) all verified prior to release. Fixed invalid YAML frontmatter in `commands/design/craft.md` and `commands/design/shape.md` (unquoted `description` values containing `: ` sequences).

## [1.69.1] - 2026-04-29

### Fixed

- **installer (install.sh — US-010):** `install_commands()` now translates subdirectory commands (e.g., `commands/design/*.md`) in addition to top-level `commands/*.md`. Previously only flat files were processed; `commands/design/{shape,craft,critique,audit,polish}.md` were silently dropped during OpenCode install. Subdirectory commands are flattened to `aimi/design-<name>.md` using colon-to-hyphen normalisation of the `name:` frontmatter field. The `references/` subdirectory is skipped (it holds shared reference docs, not commands). Dry-run mode now lists all translated commands, including subdirectory ones.

## [1.69.0] - 2026-04-29

### Changed

- execute: every story now runs in its own git worktree — single-story waves no longer skip worktree creation; the N=1 fast-path was deleted so the multi-story flow handles all wave sizes uniformly
- Default metadata.maxConcurrency raised from 4 to 5; selection within a wave remains deterministic (tasks.json file order via $AIMI_CLI list-ready)

## [1.68.3] - 2026-04-28

### Fixed

- **commands (CLI path resolution):** Replaced the CWD-relative `Read \`references/cli-path-resolution.md\`` loader with the absolute `Read \`${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md\`` form across the seven commands that resolve `$AIMI_CLI` (init, brainstorm, plan, execute — both CLI and Worktree Manager reads — next, open-pr, status). The relative form failed when commands ran from a project CWD outside the plugin tree, causing the agent to glob the project for `cli-path-resolution.md`.
- **command (`/aimi:init`):** Widened `allowed-tools` from the scoped `Read(references/cli-path-resolution.md)` to bare `Read`, matching the pattern used by the other six commands. The scoped form prevented the new absolute-path read from being authorized.
- **install (OpenCode):** `install.sh translate_command_body()` now rewrites `${CLAUDE_PLUGIN_ROOT}` to `${AIMI_PLUGIN_DIR}` so translated commands resolve under OpenCode's plugin layout (where `CLAUDE_PLUGIN_ROOT` is undefined). Mirrors the existing `CLAUDE_CONFIG_DIR` rewrite.

## [1.68.2] - 2026-04-27

### Removed

- **docs (README):** Dropped the `## Version History` section and its TOC entry. CHANGELOG.md is now the single source of truth for version history; the README links to it from a one-line pointer at the end of Troubleshooting.

## [1.68.1] - 2026-04-27

### Added

- **docs (README):** New Troubleshooting subsection "Inspecting an agent-browser headed session" documenting how to attach Chrome DevTools to a running `agent-browser --headed` session via `--remote-debugging-port=9222` and `chrome://inspect/#devices`. Useful for debugging Visual Follow sessions launched by `/aimi:execute`.

## [1.68.0] - 2026-04-27

### Removed

- **command (`/aimi:swarm`):** Deleted `/aimi:swarm` and its `plugins/aimi-engineering/commands/swarm.md` body. Parallel execution is now handled exclusively by `/aimi:execute` via git worktrees (no Docker dependency).
- **skill (`orchestrating-swarms`):** Deleted the entire `plugins/aimi-engineering/skills/orchestrating-swarms/` directory (7 files). The skill was only referenced by `/aimi:swarm` and was already labeled "Disabled (Reference Only)" in the README.
- **hook patterns:** Removed Docker auto-approve patterns (13–18) from `plugins/aimi-engineering/hooks/auto-approve-cli.sh` — they exclusively approved `aimi-swarm-*` and `aimi-*` container commands.
- **OpenCode install:** `install.sh` no longer grants Docker permissions in `opencode.json` (the swarm-only Docker allow rules are removed from `install_permissions`).

### Migration

Users running `/aimi:swarm <args>` should switch to `/aimi:execute`, which now provides the same parallel-wave execution via worktrees without needing Docker or `ANTHROPIC_API_KEY` in environment.

## [1.67.1] - 2026-04-27

### Changed

- **docs (AGENTS.md):** Extended AGENTS.md output compression with caveman-derived rules (Guzik 2026 benchmark; expected 10-20% reduction on spawned-agent summary returns). New blocks: article-elision (drop a/an/the in bullet leads), sentence-pattern compression (convert passive constructions to active telegraphic form), short-synonyms substitution table, and scope-guard (suppresses rules when user requests verbose output or full prose).

## [1.67.0] - 2026-04-22

### Added

- **tasks schema (US-001):** New optional `skills[]` field on user story objects. The validator accepts an array of skill-name strings (e.g. `["dhh-rails-style", "frontend-design"]`); stories without `skills[]` are valid and behave identically to pre-1.67. Stories can now declare skills they need (e.g. dhh-rails-style, frontend-design) — the executor injects SKILL.md contents into the worker prompt, keeping the base template lean while giving each story targeted conventions.
- **command (aimi:execute — US-002):** Executor skill injection. When a story carries a non-empty `skills[]` array, `/aimi:execute` resolves each named skill's `SKILL.md` from the plugin's `skills/` directory and injects its contents into the Task agent prompt ahead of the story body. Skills that cannot be resolved are logged as warnings and skipped; execution continues.

### Changed

- **command (aimi:plan — US-003):** `plan.md` heuristic auto-populates `skills[]` from file patterns detected in the story's `implementation.files` list. Rails/Ruby paths → `dhh-rails-style`; React/Next.js/CSS/Tailwind paths → `frontend-design`. The field is omitted when no patterns match, preserving backwards compatibility.

## [1.66.0] - 2026-04-22

### Added

- **cli (aimi-cli.sh):** New `--base <branch>` flag on the `setup-branch` subcommand. Callers can now specify an explicit base branch (e.g., `aimi-cli.sh setup-branch --base main`) instead of relying solely on automatic default-branch detection. When omitted, behavior is identical to pre-1.66: the default branch is detected via `detect-default-branch`. Enables `/aimi:execute` to thread the user's chosen base branch all the way down to the worktree creation call.

### Changed

- **command (aimi:execute):** Interactive base-branch selection at Step 1.6. When the current branch has unmerged work, `/aimi:execute` now asks whether to stack on the current branch or start fresh from the default branch. Previously auto-stacked. In agent mode (`AIMI_AGENT_MODE=true`, `CI=true`, or no TTY) the pre-1.66 automatic stacking behavior is preserved — no prompt is emitted and the current branch is used as-is.

## [1.65.0] - 2026-04-22

### Added

- **command (aimi:init):** New `/aimi:init` slash command that primes the global CLI path cache (`~/.claude/aimi-engineering-cli-path`) on demand. After priming, subsequent `/aimi:*` commands skip the Layer 2 glob in `references/cli-path-resolution.md` until the cache goes stale. Users can re-run it anytime to repair a broken cache.
- **cli (aimi-cli.sh):** New `prime-cache` subcommand that actively populates the global CLI path cache with a structured JSON contract `{status, path, host, version, message}`. Under Claude Code it globs `~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh`, validates the resolved path against the same pattern used by `read_global_cli_cache`, and writes atomically. Under OpenCode it writes `$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh` after verifying the script is executable — diverging from `cmd_check_version`'s short-circuit because the whole point of `prime-cache` is to populate the cache, not defer to the converter. Status values: `ok`, `already_current`, `not_found`, `error`. Exempt from `find_aimi_root()` so it runs from any directory, including fresh installs with no `.aimi/`.

### Changed

- **installer (install.sh):** `install.sh --to opencode` now primes the global CLI path cache post-install by invoking `aimi-cli.sh prime-cache` after the shell-profile env var is set. This writes `~/.claude/aimi-engineering-cli-path` at install time so the first `/aimi:*` command after install skips the Layer 2 glob entirely. Failure is non-fatal — the installer warns and continues. `./install.sh --uninstall --from opencode` now removes the global cache file via `rm -f` (best-effort; dry-run logs `Would remove ...` only when the file exists).

### Notes

- The global cache file `~/.claude/aimi-engineering-cli-path` is now written at install time (OpenCode via `install.sh`) or on demand (Claude Code via `/aimi:init`). Layer 2 glob-and-cache-update logic in `references/cli-path-resolution.md` remains as a rescue fallback when the cache is missing or stale — no change to the 4-layer resolution contract.

## [1.64.0] - 2026-04-21

### Added

- **command (aimi:brainstorm — US-002):** Pre-flight browser availability check with chat output. Before the first visual question, `/aimi:brainstorm` runs `command -v agent-browser` plus a `DISPLAY`/`CI` heuristic once and echoes `Visual preview: ready` or `Visual preview: disabled (<reason>)` to chat. Result is cached in working memory so subsequent visual questions do not re-check.
- **command (aimi:brainstorm — US-004):** `AIMI_BRAINSTORM_DEBUG=1` environment variable support. When set, emits `[brainstorm-debug] <context>: <value>` diagnostic lines to chat at four decision points (topic slug, category classification, browser attempt, variant choice). A new "Environment Variables" section in `brainstorm.md` documents the flag alongside `AIMI_AGENT_MODE`.
- **command (aimi:brainstorm — US-005):** `show variants` override keyword. Typing the phrase in a brainstorm topic or reply forces the next question to render HTML variants regardless of its category classification. Echoes `Visual override active — rendering variants for next question` to chat once per trigger.
- **command (aimi:brainstorm — US-003):** Chat-surfacing for browser skip/degradation events. `agent-browser unavailable`, `agent-browser session lost`, and `agent-mode: picker unavailable — auto-selected variant A` are now echoed to chat once per session (guarded by `echoedBrowserUnavailable`, `echoedSessionLost`, `echoedPickerUnavailable` flags), in addition to being logged to the brainstorm document.

### Changed

- **command (aimi:brainstorm — US-001):** Step 4 retry logic improved. A failed session reload now retries once with a `-2` session-name suffix before degrading to text-only, matching the canonical flow in `references/visual-variants.md` "Fallback: mid-session crash" section. Previously degraded on first failure.

## [1.63.0] - 2026-04-20

### Added

- **cli (aimi-cli.sh):** New `detect-interactivity` subcommand that resolves the active interactivity mode from environment: prints `agent` when `AIMI_AGENT_MODE=true`, `CI=true`, or stdin is not a TTY; prints `picker` otherwise. Exempt from `find_aimi_root()` since it reads only env vars — usable by commands before any `.aimi/` state exists. Documented in `cmd_help` usage.
- **reference (interactivity.md):** New `commands/references/interactivity.md` defines the two-mode contract (`picker`, `agent`), the picker option-format rules (lettered labels, escape hatch on last option, 2–6 options cap), the agent auto-pick log-line format (`agent-mode: <site-id> auto-<action>`), and a 3-step checklist for adding new question sites. Single source of truth for all commands that ask the user questions.
- **command (aimi:brainstorm):** New Step 0 (Resolve CLI Path) + Step 0.5 (Resolve Interactivity Mode) preamble sets `INTERACTIVE_MODE` once per invocation via `$AIMI_CLI detect-interactivity`. Phase 2 main batch questions now branch on `INTERACTIVE_MODE`: `picker` emits one `AskUserQuestion` call per question with lettered options + `Other` free-form escape (replaces the former single prose block with shorthand parser); `agent` auto-selects option A and logs one line per question. Agent-mode fallback notes added to the remaining 3 picker sites (Phase 0 plan-redirect auto-proceeds to `/aimi:plan`; Phase 3 approach auto-picks option A; Phase 4 open questions defer to a `Deferred Questions` section). Combined with the existing visual-variant fallback (L335) and the new Phase 2 branch, all 7 user-facing question sites now have deterministic agent-mode behavior.

### Changed

- **installer (install.sh):** AskUserQuestion translation no longer degrades to prose-in-chat. OpenCode ships a native `question` tool ([docs/tools](https://opencode.ai/docs/tools/)) with header + lettered options + custom-text input; the translator now maps `Use **AskUserQuestion**` → `Use the **question** tool`, `Use AskUserQuestion` → `Use the question tool`, `via AskUserQuestion` → `via the question tool`, and the bare `AskUserQuestion` fallback → `the question tool`. OpenCode users get the same picker UX as Claude Code users across every command that uses the pattern (brainstorm, swarm, plan, task-planner). Permission-gated by `"question"` in `opencode.json` (default: `"ask"`).

### Fixed

- **command (aimi:brainstorm):** Shorthand answer parser (`"1A, 2C, 3B"`) removed from Phase 2 — it was a workaround for the missing picker on the main batch and no longer applies when every question is a picker call. Pre-existing visual-variant fallback log line changed from `agent-mode: AskUserQuestion unavailable` to `agent-mode: picker unavailable` so it stays grammatical after OpenCode translation.

### Tests

- **test-aimi-cli.sh:** Three new tests covering `detect-interactivity`: `test_detect_interactivity_agent_mode_env` (AIMI_AGENT_MODE=true overrides), `test_detect_interactivity_ci_env` (CI=true triggers agent mode), `test_detect_interactivity_non_tty` (no TTY on stdin triggers agent mode). Baseline raised from 283/0 to 286/0.

## [1.62.0] - 2026-04-20

### Added

- **schema (tasks.json):** New optional `metadata.prototypePaths[]` field — a deduplicated array of relative paths to prototype HTML variants and the `<topic-slug>-tokens.json` sidecar. Schema version stays at `3.2` (additive optional field, follows the `researchPaths[]` precedent).
- **command (aimi:plan):** Phase 0 Prototype Context now collects successfully loaded prototype paths (non-dropped after the 200 KB aggregate cap, non-missing on disk) into `resolvedPrototypePaths`; Phase 4 Derive Metadata persists them as `metadata.prototypePaths[]`. Full-stack split writes the same array to both frontend and backend tasks.json files. The Aimi-branded report surfaces `Prototypes: [N] variant file(s) registered` when non-empty.
- **command (aimi:execute):** New Step 3.5 Load Prototype Context reads `metadata.prototypePaths[]` and builds `PROTOTYPE_CONTEXT` — `.html` files wrap as `<prototype_html label="X" path="...">` blocks with tag-breakout escape, `.json` sidecars wrap as `<prototype_tokens>` blocks. Re-applies the 200 KB aggregate cap at execute time; skips missing files with a warning line. `PROTOTYPE_CONTEXT` is injected into all three worker-prompt assembly sites (single-story wave, multi-story parallel wave, paired-split sub-Tasks) immediately after `DESIGN_CONTEXT`, omitted when empty. Start report surfaces `Prototype context: [N] variant(s) loaded` when variants are present.
- **skill (story-executor):** Prompt Template and Compact Template both define a `<prototype_context>` XML section (after `<design_context>`) so spawned workers know how to consume prototype variants when threaded.
- **cli (aimi-cli.sh — archive-task):** Cleans `metadata.prototypePaths[]` files alongside `researchPaths[]` using an identical loop (relative-path resolution from PROJECT_ROOT, `validate_path_in_project` gate, `[ -e ]` missing-file tolerance, `rm -f`). Output JSON gains a `prototypeCleaned` counter field on the existing single `jq -n` call.
- **tests (test-aimi-cli.sh):** Four new archive-task tests covering prototype cleanup: `test_archive_task_with_prototype_paths`, `test_archive_task_without_prototype_paths`, `test_archive_task_missing_prototype_files`, and `test_archive_task_both_research_and_prototype_paths`.

### Security

- **command (aimi:plan):** Phase 0 Prototype Context now validates that each resolved absolute path stays within AIMI_ROOT before reading — paths escaping via `../` or symlink targets are rejected with `prototype <path> rejected — path outside project root` and skipped (plan does not abort for a bad path). Prevents a malicious brainstorm with a `prototype: ../../etc/passwd` frontmatter key from injecting arbitrary file contents into the planning context.

## [1.61.1] - 2026-04-17

### Changed

- **command (aimi:deepen):** Research file naming standardized to the `brainstorm` and `plan` canonical shape `.aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-<story.id>-codebase.md`. Deepen now derives `TOPIC_SLUG` from `metadata.branchName` (stripping the `type/` prefix), generates a single `RUN_TS` via `date +%H%M%S` and reuses it across every parallel researcher, and passes the path via a structured `outputPath:` field so researcher agents write to the exact canonical location (the researcher Output Contract honors caller-supplied `outputPath:`). Same-run grouping now matches brainstorm/plan.

### Fixed

- **command (aimi:deepen):** Step 4.5 appends every written research path to `metadata.researchPaths[]` (deduplicated). Previously deepen's research files leaked — `$AIMI_CLI archive-task` reads `researchPaths[]` to clean up, but deepen never wrote into the array, so its files persisted across archive cycles.

## [1.61.0] - 2026-04-17

### Added

- **reference (visual-variants.md):** New `commands/references/visual-variants.md` — Alpine.js switcher skeleton with topic-slug sanitization and HTML-escape rules (including JS-context escaping note for future `x-data` embeddings), Tailwind CDN offline behavior, 2–4 variants-per-question constraint, and append semantics for multi-question sessions.
- **reference (visual-variants.md — Token Extraction):** 6-source precedence list for design-token resolution: `tailwind.config.{js,ts}` → `theme.{ts,js,tsx,jsx}` → CSS custom properties → `_variables.scss` → MUI `createTheme` → Chakra `extendTheme`. **Eight token families** covered: colors, fonts, radii, spacing, shadows, transitions, screens (breakpoints), and dark-mode. Per-family independent resolution, Tailwind CDN defaults fallback with in-document warning, parse errors silently skip the source and never abort brainstorm.
- **reference (visual-variants.md — Token Sidecar JSON):** Extraction writes a machine-readable `<topic-slug>-tokens.json` alongside the HTML variants file, recording resolved values, per-family source attribution, and fallback list. Consumed by `/aimi:plan` (implementation context) and `/aimi:review` (fidelity checks).
- **reference (visual-variants.md — Structural Guidance):** Canonical-shape taxonomy (form/card/nav/hero/modal/table/layout-with-sidebar). Variants in the same question share shape, density, and primary-action copy; direction varies via typography, color, radius, shadow, and density. Tokens emitted as CSS custom properties on `:root` (plus `.dark :root` for dark-mode strategy `class`) and referenced via Tailwind arbitrary-value syntax.
- **reference (visual-variants.md — Browser Session Lifecycle):** Lazy open, reuse-with-reload (idempotent on re-runs), close-on-completion; missing-skill / missing-display / CI fallback degrades to text-only.
- **command (aimi:brainstorm — Phase 2):** Visual Variant Rendering phase with optional Component-Shell Scan (samples 2–3 representative component files to surface wrapper-tag and class-recipe idioms for Structural Guidance). Variant Selection sub-step offers `AskUserQuestion` options; **agent-mode fallback** auto-selects Variant A when `AskUserQuestion` is unavailable (non-interactive hosts). Variant Persistence stores `chosen_variant_slug` and records `selectedVariants` in brainstorm frontmatter. Non-visual categories remain text-only throughout.
- **command (aimi:brainstorm — Phase 5):** Cleanup step prunes the scratch prototype file after clean session completion; standalone variant files and the tokens sidecar are preserved.
- **command (aimi:plan — Phase 0):** Prototype Context sub-step — parses brainstorm `prototype:` frontmatter and `## Prototype` section; loads the `<topic-slug>-tokens.json` sidecar; sanitizes embedded `</prototype_html>` sequences before wrapping; **200 KB aggregate cap** across all loaded blocks (drops in reverse label order with warning); injects `<prototype_html>` block and tokens JSON into researcher and decomposition prompts so implementation agents inherit the visual intent.
- **command (aimi:review):** Prototype Design Context sub-step — when a PR's branch has a matching brainstorm, loads the prototype HTML and tokens JSON and threads them into architecture, simplicity, and language-specific reviewers so fidelity against the chosen variant and target-project tokens can be verified.

### Changed

- **install.sh:** `install_plugin_source` dry-run branch simplified — removed the per-file enumeration of `commands/references/` (cosmetic only; `cp -R` already copies the directory).

## [1.60.3] - 2026-04-16

### Changed

- **skill (story-executor):** Worker prompt template (both full and compact variants) now explicitly instructs the spawned agent to apply output compression rules from `AGENTS.md`. Previously the rules were only loaded passively through project guidelines; the new `<output_rules>` section in the full template and the appended sentence in the compact template ensure the directive reaches the agent even when `AGENTS.md` is missing or in edge-case multi-repo scenarios.
- **docs (plugin CLAUDE.md):** Hedge unverified token-reduction claims (~33% inline-story savings, ~60% compact-template savings) — replaced with qualitative descriptions noting the savings have not been benchmarked. Applies to both `plugins/aimi-engineering/CLAUDE.md` Performance Guidelines and the Compact Template blockquote in `skills/story-executor/SKILL.md`.

## [1.60.2] - 2026-04-16

### Removed

- **plugin manifest:** Remove local-only `penpot` MCP server entry from `mcpServers` (pointed at `http://localhost:4401/mcp`, not suitable for distribution).

## [1.60.1] - 2026-04-16

### Changed

- **command (aimi:open-pr):** Document that the command does not read `CLAUDE.md`/`AGENTS.md` and point users to `.github/pull_request_template.md` for project-specific PR structure (honored automatically by `gh pr create`). No behavior change.

## [1.60.0] - 2026-04-16

### Changed

- **command (aimi:open-pr):** PR title and body are now derived from git commits and the diff against the base branch instead of `tasks.json`. Title comes from the first commit subject on the branch (fallback: current branch name). Body replaces the former `Problem`/`Solution`/`Stories Completed`/`Testing` sections with `Summary` (aggregated commit bodies), `Changes` (commit subjects as bullets), and `Files Changed` (git diff --stat). `tasks.json` is only read inside the conditional `Backend Implementation Spec` block (requires `metadata.frontendOnly` AND `metadata.backendSpec`); when no tasks file is present or metadata lookup fails, that block is silently skipped and PR creation still succeeds.

## [1.59.1] - 2026-04-15

### Fixed

- **cli**: Context-aware CLI path resolution — Layer 0 (`AIMI_PLUGIN_DIR`) is now skipped when running inside Claude Code (`CLAUDECODE=1`), ensuring the Claude Code cache directory is always used instead of the stale OpenCode install path
- **cli**: `check-version --fix` and `cleanup-versions` no longer bail early with "managed by converter" when inside Claude Code, enabling self-heal after plugin updates
- **cli**: `read_global_cli_cache` and `read_global_worktree_cache` reject OpenCode-style cached paths when inside Claude Code, preventing split-brain version resolution

## [1.59.0] - 2026-04-15

### Changed

- **agents (aimi-lint, aimi-learnings-researcher):** Remove hardcoded model: haiku; both agents now inherit model from calling context

## [1.58.2] - 2026-04-15

### Added

- **cli**: `archive-task` now deletes research files listed in `metadata.researchPaths` — reads each path, resolves relative paths from `PROJECT_ROOT`, validates with `validate_path_in_project`, checks existence, and deletes with `rm -f`; missing files are silently skipped
- **cli**: JSON output of `archive-task` now always includes `researchCleaned` integer field (0 when no research files were present or none existed)
- **tests**: Three new tests for archive-task research cleanup: with researchPaths, without researchPaths (researchCleaned 0), and with missing research files (silent skip)

## [1.58.1] - 2026-04-15

### Added

- **schema**: Add `researchPaths` (string[]) metadata field to task-format-v3.md — tracks research files generated during planning so archive-task can clean them up; omitted when `researchDepth` is `skip` or no files written
- **planner**: Phase 4 Derive Metadata now includes `researchPaths` bullet instructing the orchestrator to collect paths from Phase 1 and Phase 1.5b research agents
- **docs**: CLAUDE.md key fields summary updated with `researchPaths[](optional)` after `maxConcurrency`

## [1.58.0] - 2026-04-15

### Changed

- **research**: Unify research file naming with run discriminator — all four research agents (codebase, learnings, best-practices, framework-docs) now use `YYYY-MM-DD-<topicSlug>-<HHmmss>-<short-name>.md` pattern
- **planner**: Generate `RUN_TS=$(date +%H%M%S)` once in plan.md Phase 1 and pass it to all agent `outputPath` parameters so same-day re-runs produce separate files
- **brainstorm**: Phase 1b now generates `RUN_TS` and specifies explicit `outputPath` for each research agent instead of relying on agent Output Contract defaults
- **task-planner**: SKILL.md and pipeline-phases.md agent prompts updated to use `outputPath` with the new `YYYY-MM-DD-[topicSlug]-[RUN_TS]-<short-name>.md` pattern
- **research agents**: Output Contract updated to document that caller-specified `outputPath` takes precedence over agent-derived slug/timestamp; short names in frontmatter updated to `codebase`, `learnings`, `best-practices`, `framework-docs`

## [1.57.0] - 2026-04-15

### Added

- **cli**: Add `version` subcommand that prints the plugin version from plugin.json
- **tests**: Add version command test validating semver output

## [1.56.0] - 2026-04-15

### Fixed

- **tests**: Unset `AIMI_PLUGIN_DIR` before version staleness and global cache tests to prevent compound-plugin converter from short-circuiting test assertions

## [1.55.0] - 2026-04-15

### Fixed

- **cli**: Add `--project` flag to `setup-branch` and `detect-default-branch` commands for multi-repo layouts where AIMI root is not a git repository
- **cli**: Add git-repo guard to both commands with clear error message instead of cryptic `fatal: not a git repository`
- **execute**: Detect multi-repo layout (AIMI root is not a git repo) and skip main repo branch setup, handling branch creation per-project instead
- **planner**: Defer default branch detection to per-project when AIMI root is not a git repo

### Added

- **tests**: Add `--project` flag and non-git-repo error tests for `setup-branch`

## [1.54.0] - 2026-04-14

### Fixed

- **planner**: Add missing auto-scan for git repos step in plan.md Phase 1, syncing with SKILL.md
- **planner**: Promote `project` field assignment to explicit numbered step 6 in Phase 3, preventing model from skipping multi-repo project assignment

## [1.53.0] - 2026-04-14

### Changed

- **brainstorm**: Structured consolidation schema in Phase 1.6 with adaptive return caps tied to researchDepth
- **deepen**: Research agents write findings to `.aimi/research/` files instead of returning bulk text inline
- **deepen**: Adaptive return caps tied to researchDepth — lower depths produce shorter agent output
- **planner**: Default researchDepth inherited through planning pipeline
- **review**: Protected artifacts updated for `.aimi/research/` output path

## [1.52.0] - 2026-04-14

### Added

- **agents**: AGENTS.md with context-adaptive compression rules for spawned agent output

### Changed

- **cli**: Deduplicated CLI path resolution to eliminate redundant path computations
- **story-executor**: XML tags in story executor prompts for structured content boundaries
- **story-executor**: Compact prompt pattern — subsequent stories use condensed static sections (~60% token reduction)
- **git-worktree**: Progressive disclosure — worktree skill surfaces details on demand instead of upfront
- **task-planner**: Progressive disclosure — planner skill surfaces details on demand instead of upfront

## [1.51.0] - 2026-04-14

### Fixed

- **execute**: Visual verification for worktree stories now runs post-merge instead of inside isolated worktrees where dev server cannot see changes

## [1.50.0] - 2026-04-14

### Added

- **brainstorm**: Design-thinking integration for visual features — auto-detect UI keywords in feature descriptions, inject Aesthetic Direction and Differentiation topic categories into Phase 2, conditional Design Decisions section in brainstorm document template, design context passed to story executors
- **planner**: Auto-skip implementation scope question for non-app features (plugin changes, refactors, CLI tools, docs) — uses keyword detection with conflicting-signals precedence

## [1.49.0] - 2026-04-14

### Fixed

- **execute**: Visual-follow browser detection now type-guards `verification` field — prevents silent failure when verification is a string instead of object, warns about malformed fields
- **planner**: Added explicit "verification MUST be an object" warnings with JSON examples to all planner instruction files (SKILL.md, plan.md, pipeline-phases.md, story-decomposition.md)

### Changed

- **schema**: `backendSpec.businessContext` expanded from string to structured object with `summary`, `userRoles[]`, `constraints[]`, `assumptions[]`, `successCriteria[]` sub-fields
- **open-pr**: Backend Implementation Spec "Business Context" section now renders structured sub-sections (User Roles, Constraints, Assumptions, Success Criteria) with legacy string fallback
- **planner**: Phase 4 businessContext generation guidance updated with explicit extraction instructions for each sub-field

## [1.48.0] - 2026-04-14

### Added

- **open-pr**: GitHub issue creation with backend spec for frontend-only PRs — after PR creation, attempts `gh issue create` with Backend Implementation Spec body, links issue to PR via `gh pr edit`, graceful degradation on failure (warning only, PR unaffected)

## [1.47.0] - 2026-04-14

### Added

- **execute**: Multi-file auto-detection (Step 0.9) — uses `find-tasks-all` to discover all task files, auto-detects paired `*-frontend-tasks.json` and `*-backend-tasks.json` with matching date+feature prefix, spawns two parallel foreground Tasks with worktree isolation and `init-session --file`, aggregated completion report showing per-file results
- **open-pr**: Backend Implementation Spec section in PR body for frontend-only prototypes — when `frontendOnly` is true and `backendSpec` exists, appends Endpoints, Data Models, Business Rules, and Business Context subsections after Testing (deterministic rendering, no LLM generation)

## [1.46.0] - 2026-04-14

### Added

- **planner**: Split task file generation — full-stack scope produces separate `*-frontend-tasks.json` and `*-backend-tasks.json` with independent branch names, dependency graphs, and wave numbers
- **planner**: `backendSpec` metadata generation — frontend-only scope synthesizes `endpoints`, `dataModels`, `businessRules`, and `businessContext` from story analysis
- **planner**: Per-file Phase 4.5 validation using `init-session --file` for independent validation of each split file

## [1.45.0] - 2026-04-14

### Added

- **cli**: `find-tasks-all` subcommand — returns newline-separated list of all *-tasks.json files sorted by modification time for multi-file discovery
- **cli**: `--file <path>` flag for `init-session` — allows specifying a tasks file directly instead of auto-detecting the most recent one, with existence and pattern validation
- **story-executor**: Headed mode context and visual-follow session reuse — adds `[HEADED_MODE]` placeholder, conditional visual verification branches for headed (session reuse, no close) vs headless (executor-owned lifecycle) modes

## [1.44.0] - 2026-04-14

### Added

- **execute**: Visual-follow session prompt (Step 0.7) — detects frontend stories with `verification.strategy == "visual"`, prompts user to follow implementation in a headed browser, manages `agent-browser` session lifecycle around the wave loop

## [1.43.1] - 2026-04-09

### Fixed

- **cli**: Improved `setup-branch` comment clarity — distinguish "on default branch" vs "merged into default" cases

### Changed

- **test**: Added test for merged-but-not-on-default branch scenario in `setup-branch`, updated test descriptions for accuracy

## [1.43.0] - 2026-04-09

### Added

- **cli**: `setup-branch` subcommand — deterministic branch creation/checkout with JSON output, supports local/remote/new branch detection with merge-status-aware base selection
- **hooks**: `setup-branch` added to auto-approve whitelist in `auto-approve-cli.sh`

## [1.42.0] - 2026-04-08

### Changed

- **execute**: Branch creation from `origin/[DEFAULT_BRANCH]` is now conditional — only when the current branch has been merged into the default branch; otherwise creates from current HEAD

## [1.41.0] - 2026-04-08

### Added

- **cli**: `detect-default-branch` subcommand — dynamically detects repository default branch with `git remote show origin` primary and `git symbolic-ref` fallback, cached in `.aimi/default-branch`
- **cli**: `list-archivable` subcommand — returns JSON array of task files where all stories are completed or skipped
- **cli**: `archive-task` subcommand — moves completed task file + linked brainstorm to `.aimi/archive/` with collision handling
- **execute**: Archival prompt at entry point (Step 0.5) — checks for completed task files via `list-archivable` and offers to archive them before starting execution
- **execute**: Branch freshness check (Step 1.5) — fetches origin and detects default branch via `$AIMI_CLI detect-default-branch` before branch setup
- **plan**: Branch freshness check — fetches origin before Phase 0 to ensure local refs are current, with offline warning fallback
- **plan**: CLI path resolution using 4-layer strategy and `detect-default-branch` for dynamic default branch detection
- **review**: Dynamic default branch detection using `git symbolic-ref`, replacing hardcoded `main`

### Changed

- **execute**: New branches now created from `origin/[DEFAULT_BRANCH]` instead of current HEAD, ensuring fresh base
- **execute**: Commit counting in Step 5 uses dynamically detected default branch instead of hardcoded `main`
- **cli**: `clear-state` now also removes `default-branch` cache file

## [1.40.0] - 2026-04-08

### Changed

- **branding**: Updated author to "Aimi — Autonomous Code Companion" in plugin.json and marketplace.json

## [1.39.0] - 2026-04-07

### Added

- **story-executor**: Visual verification section in prompt template — conditional agent-browser flow for stories with `verification.strategy: visual` and `verification.url`, advisory only (failures do not block commits)

## [1.38.0] - 2026-04-07

### Added

- **execute**: Commit verification after Task execution — captures HEAD SHA before each Task spawn and compares after success; stories with no commit are marked as failed with cascade-skip instead of silently completing
- **execute**: Parallel worktree commit verification — captures base SHA per project group before worktree creation, filters out no-commit stories before merge step

## [1.37.0] - 2026-04-06

### Added

- **commands**: `/aimi:open-pr` command for opening pull requests from executed task branches with structured PR descriptions

## [1.36.0] - 2026-04-02

### Added

- **schema**: `researchDepth` metadata field for controlling research thoroughness (quick, standard, deep)
- **schema**: `wave` field on stories for explicit wave assignment and parallel execution grouping
- **schema**: `implementation` object on stories with `files`, `approach`, and `verify` fields for structured implementation guidance
- **schema**: `verification` object on stories with `strategy`, `status`, `url`, and `expect` fields for post-execution verification
- **schema**: `gate` object on stories with `type`, `status`, `prompt`, and `options` fields for decision/action/verify gates
- **aimi-cli**: `gate-pass` command to resolve a gate as passed
- **aimi-cli**: `gate-fail` command to resolve a gate as failed
- **aimi-cli**: `validate-waves` validator for checking wave assignment consistency and dependency ordering
- **aimi-cli**: `update-field` command for updating nested story fields (e.g., `verification.status`)
- **execute**: Gate handling in wave execution loop — decision gates block story start with log message, action gates log post-completion with dependent pause, verify gates log as non-blocking
- **execute**: Gate-blocked story detection — differentiates gate-blocked from true deadlocks when no stories are ready
- **execute**: Wave summary includes gate status counts (action/verify gates pending)
- **execute**: Completion summary includes pending gate inventory with resolution instructions
- **execute**: Executor updates `verification.status` to `passed` when story-executor reports verification success

### Changed

- **schema**: Schema version bumped from 3.1 to 3.2
- **execute**: `list-ready` gate filtering — stories with pending gates excluded from ready list
- **story-executor**: Prompt template now includes `implementation.files` (Key Files), `implementation.approach` (Approach), `implementation.verify` (Verification Command), and `verification.strategy`/`verification.expect` (Verification) sections when present in v3.2 story data
- **story-executor**: Story format summary in SKILL.md updated with `implementation` and `verification` field descriptions
- **story-executor**: execution-rules.md inline JSON example updated with `implementation` and `verification` objects

## [1.35.0] - 2026-04-02

### Added

- **brainstorm**: Parallel best-practices research in Phase 1 — spawns aimi-best-practices-researcher alongside aimi-codebase-researcher
- **brainstorm**: Decoupled specificity-skip logic — codebase and best-practices researchers assessed independently with distinct skip criteria
- **brainstorm**: Research Consolidation step (1c) merges internal patterns and external best practices, surfaces conflicts as candidate Phase 2 questions
- **brainstorm**: Graceful degradation for all 4 research permutations (both succeed, either fails/skipped, both fail)
- **brainstorm**: Approach-in-questions integration — Phase 2 includes approach selection questions when research reveals multiple valid approaches, with tradeoff hints per option
- **brainstorm**: Phase 3 Resolve Approach fallback — lightweight approach resolution only when not addressed in Phase 2, with skip conditions for already-resolved or single-obvious-approach cases
- **brainstorm**: Progressive quality gates — Research Adequacy gate (Phase 1→2), Topic Coverage gate (Phase 2→3/4), and Pre-Save Checklist (Phase 4) with conversational nudges and user override support
- **brainstorm**: Document template "Why This Approach" guidance updated for 3 resolution paths (Phase 2 questions, Phase 3 fallback, single obvious approach with justification)
- **brainstorm**: Error handling table expanded with quality gate failure scenarios and research agent failure combinations

## [1.34.0] - 2026-03-31

### Added

- **install.sh**: Full OpenCode command body translation — agent invocations rewritten for OpenCode Task tool compatibility
- **install.sh**: Skills installation (`install_skills()`) — copies SKILL.md and references to OpenCode skills directory
- **install.sh**: Nested command directories — commands installed as `commands/aimi/plan.md` for `/aimi:plan` naming
- **install.sh**: Bash permission auto-approval (`install_permissions()`) — configures opencode.json for autonomous execution
- **install.sh**: CLI path resolution rewriting — `CLAUDE_CONFIG_DIR` references replaced with `OPENCODE_CONFIG_DIR`
- **install.sh**: Error message rewriting — recovery instructions point to `./install.sh --to opencode`
- **install.sh**: AskUserQuestion fallback — replaced with natural conversation prompts
- **install.sh**: `disable-model-invocation` workaround — side-effect warning prepended to command bodies
- **install.sh**: Agent model field preservation — `model: haiku` preserved in translated agents

### Fixed

- **install.sh**: Python3 MCP fallback now uses `type: remote` instead of `type: http`

## [1.33.0] - 2026-03-30

### Added

- **install.sh**: Self-contained installer script for OpenCode cross-platform installation (no external dependencies)
- **install.sh**: Translates Claude Code commands and agents to OpenCode-native format
- **install.sh**: Automatic context7 MCP configuration in opencode.json
- **install.sh**: Uninstall support with `--uninstall` flag

### Changed

- **README.md**: Replaced compound-plugin converter instructions with install.sh usage

## [1.32.0] - 2026-03-30

### Added

- **cross-platform**: Cross-platform installation via compound-plugin converter for OpenCode, Codex, Copilot, and auto-detect
- **AIMI_PLUGIN_DIR**: Environment variable support for custom plugin directory resolution in all CLI commands
- **Layer 0**: CLI path resolution in all commands using AIMI_PLUGIN_DIR as Layer 0
- **auto-approve**: Hook patterns for Layer 0 resolution
- **tests**: Coverage for AIMI_PLUGIN_DIR paths

## [1.31.0] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — removes dependency on SKILL.md and reference files
- **brainstorm.md**: Conditional codebase research — skip research phase when no codebase context is available, reducing latency for greenfield brainstorms

### Removed

- **question-patterns.md**: Delete unused reference file from brainstorm skill — content was already inlined into brainstorm.md
- **SKILL.md (brainstorm)**: Remove reference to deleted question-patterns.md; add deprecation notice — skill is retained for reference only

## [1.30.3] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — response parsing table, formatting constraints, contextual question rules, topic addressed signals, input sanitization, pre-save checklist, and incremental validation guidance. Removes all references to the brainstorm skill, reducing token usage per session.

## [1.30.2] - 2026-03-30

### Fixed

- **execute.md, next.md, status.md, swarm.md**: Inline CLI path resolution logic — removes broken `See commands/references/cli-path-resolution.md` references that fail when plugin is installed outside the repo
- **status.md**: Remove broken `See task-format-v3.md` reference
- **SKILL.md (story-executor)**: Remove broken `See task-format-v3.md in ../task-planner/references/` reference — inline key fields with constraints instead
- **CLAUDE.md**: Remove broken `See task-format-v3.md` reference — inline schema version and key fields

## [1.30.1] - 2026-03-27

### Fixed

- **plan.md**: Inline schema v3 structure and dependsOn inference rules — planner agent no longer fails to find reference files when running outside the plugin repo
- **plan.md**: Add `validate-stories` to Phase 4.5 validation step
- **SKILL.md (task-planner)**: Remove broken relative path references to `references/task-format-v3.md`, `references/pipeline-phases.md`, and `references/story-decomposition.md` — inline essential content instead
- **SKILL.md (task-planner)**: Inline git repo auto-scan bash command (previously only in pipeline-phases.md)

## [1.30.0] - 2026-03-26

### Added

- **task-format-v3.md**: Optional per-story `project` field added to task schema v3 — specifies the relative path from AIMI_ROOT to the target git repository for multi-repo story execution
- **aimi-cli.sh**: Project field validation in `cmd_validate_stories()` — rejects absolute paths, path traversal (`..`), and shell metacharacters (`$`, `` ` ``, `;`, `|`, `&`); accepts valid relative paths; backwards compatible when project is absent
- **aimi-cli.sh**: Project field included in `cmd_list_ready --brief` output (`{id, title, priority, dependsOn, project}`)
- **next.md**: Per-story project path resolution — when a story has a `project` field, resolves PROJECT_PATH relative to AIMI_ROOT and passes it to the worker agent prompt; loads CLAUDE.md from PROJECT_PATH when set; backwards compatible when project field is absent
- **execute.md**: Per-project worktree grouping for multi-repo execution — wave stories are grouped by `project` field before worktree creation, worktrees are created within each project's git repo, merge-all runs per-project group
- **execute.md**: Per-project branch setup — creates/checks out the feature branch in each unique project's git repo when stories target different repos
- **execute.md**: Per-project guidelines loading — builds `PROJECT_GUIDELINES_MAP` from each project's CLAUDE.md/AGENTS.md
- **execute.md**: Single-story waves pass `PROJECT_PATH` to worker prompt when story has `project` field
- **execute.md**: Post-loop cleanup handles per-project worktree removal
- **plan.md / story-decomposition.md**: Multi-repo project assignment rules — planner auto-scans subfolders for git repos and assigns `project` field to stories targeting specific repositories
- **test-aimi-cli.sh**: Updated `--brief` key count assertion to include project field

## [1.29.0] - 2026-03-06

### Changed

- **cli-path-resolution.md**: Rewrite CLI resolution with three-layer strategy — global cache, zsh-safe glob fallback, per-project fallback — for reliable path discovery across shells and plugin updates
- **cli-path-resolution.md**: Add equivalent WORKTREE_MGR three-layer resolution section
- **cli-path-resolution.md**: Structure resolution as sequential commands (no compound `&&` or `||`) for auto-approve hook compatibility

### Added

- **aimi-cli.sh**: Global cache functions (`_cache_path`, `_read_cache`, `_write_cache`) for persistent CLI and worktree manager path storage across sessions
- **auto-approve-cli.sh**: Auto-approve patterns for three-layer CLI resolution commands (cache read via `cat`, Layer 1 validation, Layer 2 `bash -c` glob fallback, Layer 2 cache write via `printf`/`mv`/`chmod`, Layer 3 per-project fallback)
- **aimi-cli.sh / worktree-manager.sh**: Tests for global cache read/write/invalidation functions

## [1.28.2] - 2026-03-04

### Fixed

- **plan.md**: Add explicit US-NNN ID format step to Phase 3 story decomposition and checklist — LLM now sees the format requirement before generating IDs, not just in reference docs
- **task-planner/SKILL.md**: Add US-NNN ID format step to Phase 3 between dependency assignment and description writing
- **pipeline-phases.md**: Add US-NNN ID format to Phase 3 and Phase 4 metadata derivation
- **story-decomposition.md**: Strengthen ID format with explicit zero-padding language, regex pattern, and negative examples (US-1, story-1, S1, F1)

### Added

- **aimi-cli.sh**: New `validate-ids` command — validates all story IDs in a tasks file match `^US-[0-9]{3}[a-z]?$` regex, returns JSON with valid/count or errors array
- **plan.md**: Phase 4.5 post-generation validation step — runs `validate-ids` and `validate-deps` after writing tasks.json, with fix-and-rewrite loop if validation fails
- **task-planner/SKILL.md**: Matching Phase 4.5 post-generation validation step

## [1.28.1] - 2026-03-03

### Fixed

- **task-format-v3.md**: Enforce specific role in user story descriptions — `[user]` replaced with `[specific role]` with examples (e.g., "store admin", "developer"), preventing generic "As a user" descriptions
- **story-decomposition.md**: Add "Description Format" section with required format, good/bad examples, and 500-char limit
- **task-planner/SKILL.md**: Add description format step to Phase 3 story decomposition and checklist validation
- **plan.md**: Add description format step to Phase 3 story decomposition and checklist validation

## [1.28.0] - 2026-03-03

### Added

- **aimi-cli.sh**: New `_claude_config_dir()` helper that resolves the Claude config directory from `CLAUDE_CONFIG_DIR` env var, falling back to `~/.claude` -- validates the path is absolute when set, and strips trailing slashes
- **aimi-cli.sh**: All hardcoded `~/.claude/plugins/cache/` glob patterns in `cmd_check_version()`, `cmd_cleanup_versions()`, and help text examples now use the resolved config dir variable, enabling custom config directory support
- **test-aimi-cli.sh**: New test cases for `CLAUDE_CONFIG_DIR` support — validates custom config dir resolution, absolute path enforcement, and trailing slash stripping

### Changed

- **auto-approve-cli.sh**: Dynamic config dir resolution using `CONFIG_DIR_RE` alternation — auto-approve patterns now match both `~/.claude` and custom `CLAUDE_CONFIG_DIR` paths
- **cli-path-resolution.md**: Parameterized CLI resolution example to use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` instead of hardcoded `~/.claude`
- **execute.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`
- **swarm.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`

### Security

- **aimi-cli.sh**: Add `PROJECT_ROOT` export to `find_aimi_root()` — discovers git repository root and exports it for use by other functions
- **aimi-cli.sh**: Add `validate_path_in_project()` function — validates resolved paths are under `PROJECT_ROOT` using realpath comparison, exits with clear error if path escapes project root
- **aimi-cli.sh**: Add path validation to file operation functions (`read_state`, `write_state`, `clear_state_file`, `get_tasks_file`) — prevents directory traversal attacks
- **story-executor/SKILL.md**: Add explicit project-root boundary guardrails — agents must not read or modify files outside the git repository root, worktree paths are explicitly allowed

## [1.27.4] - 2026-03-03

### Fixed

- **execute.md**: Use task branch name as worktree branch prefix instead of hardcoded `aimi-` — worktree branches are now named `[branchName]-[storyId]` (e.g., `feat/feature-name-US-001`) for clearer branch association

## [1.27.3] - 2026-03-03

### Fixed

- **task-format-v3.md**: Add explicit validation rule requiring story `id` fields to match `^US-\d{3}[a-z]?$` format — previously only `dependsOn` references were validated, allowing LLMs to generate invalid IDs like `S1` or `F1` that are rejected by aimi-cli.sh at runtime
- **task-planner/SKILL.md**: Add checklist item enforcing US-NNN format for story IDs in the v3 Schema Validations section

## [1.27.2] - 2026-03-03

### Added

- **react-best-practices skill**: Add AGENTS.md compiled guide with all React and Next.js rules expanded
- **react-native-skills skill**: Add AGENTS.md compiled guide and move rule files into skill's own rules/ directory

### Fixed

- **marketplace.json**: Sync version to match plugin.json

## [1.27.1] - 2026-03-02

### Added

- **react-best-practices skill**: Vercel React and Next.js performance optimization guidelines — 58 rules across 8 categories covering waterfalls, bundle size, server-side performance, and client-side data fetching
- **react-native-skills skill**: React Native and Expo best practices — rules for list performance, animations with Reanimated, UI patterns, image handling, navigation, monorepo configuration, and platform-specific optimizations

## [1.27.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `get-story <id>` command for on-demand story fetching — returns full story JSON for a single story by ID, enabling lazy loading instead of bulk extraction

### Changed

- **execute.md**: Two-phase story loading — wave selection uses `list-ready --brief` (returns `{id, title, priority, dependsOn}` stubs), full story data fetched via `get-story <id>` per story after `mark-in-progress` (claim-then-fetch pattern)
- **execute.md**: Single-story wave path now follows: `list-ready --brief` -> `mark-in-progress` -> `get-story` -> build prompt -> Task
- **execute.md**: Multi-story wave path now follows: `list-ready --brief` -> select -> `mark-in-progress` all -> `get-story` each -> create worktrees -> spawn Tasks
- **execute.md**: Error handling for `get-story` failures: marks story failed, cascade-skips dependents, continues with remaining stories in wave
- **execute.md**: Multi-story wave gracefully degrades — if fetch failures reduce to 1 story, falls back to single-story path (no worktree overhead)

## [1.26.2] - 2026-03-02

### Fixed

- **execute.md**: Added `subagent_type` guard (`IMPORTANT: Do NOT change subagent_type`) to Task spawn ensuring agents never substitute `story-executor` as an agent type
- **next.md**: Added `subagent_type` guard comments to both Task spawn locations (line 86 and retry at line 122), matching the pattern in execute.md — prevents agents from substituting `story-executor` as an agent type

### Added

- **story-executor SKILL.md**: Added Tools section documenting available capabilities (Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Task) for agents spawned within story execution

## [1.26.1] - 2026-03-02

### Changed

- **Acceptance criterion limit increased from 300 to 600 chars** across CLI validation, schema docs, skill references, and command checklists (aimi-cli.sh, task-format-v3.md, story-decomposition.md, SKILL.md, plan.md, CLAUDE.md, README.md)

## [1.26.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `--brief` flag on `list-ready` command — outputs a summary line (count + story IDs) instead of full JSON story objects, reducing output for wave orchestration
- **aimi-cli.sh**: `--counts-only` flag on `status` command — returns aggregate counts (`pending`, `in_progress`, `completed`, `failed`, `skipped`, `total`) without the `userStories` array, enabling lightweight progress checks in wave loops
- **aimi-cli.sh**: `status` dispatch updated to `shift; cmd_status "$@"` pattern for flag forwarding

### Changed

- **aimi-cli.sh**: `mark-in-progress`, `mark-completed`, `mark-failed`, `mark-skipped` commands now return minimal `{id, status}` JSON confirmation instead of the full story object, reducing output noise in agent loops

## [1.25.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `find_aimi_root()` auto-discovery — CLI walks up the directory tree from CWD to find `.aimi/`, eliminating silent failures when invoked from subdirectories
- **test-aimi-cli.sh**: Test isolation via `cd "$TEST_DIR"` and `trap` cleanup; new auto-discovery tests (subdirectory + not-found)
- **cli-path-resolution.md**: CWD Auto-Discovery section documenting the new behavior
- **CLAUDE.md**: CWD contract documented in both root and plugin CLAUDE.md files

## [1.24.1] - 2026-03-02

### Added

- **auto-approve-cli.sh**: Docker auto-approve patterns (5–10) for `/aimi:swarm` commands
  - Pattern 5: `docker version` availability check
  - Pattern 6: `docker run --rm` with `--name aimi-swarm-*` and `--label aimi-swarm` (worker containers)
  - Pattern 7: `docker container ls` with `--filter name=aimi-swarm-` (container listing)
  - Pattern 8: `docker rm -f` with validated `aimi-swarm-*` container names (cleanup)
  - Pattern 9: `docker container prune -f --filter label=aimi-swarm` (safety net)
  - Pattern 10: `docker ps --filter name=aimi-*` (status/cleanup checks)
- All Docker patterns enforce aimi- prefix on container names and reject shell metacharacters

## [1.24.0] - 2026-03-02

### Changed

- **swarm.md**: Complete rewrite — replace Docker/ACP/Sysbox architecture with Team orchestration + git worktrees + simplified `docker run --rm` containers
- **swarm.md**: New frontmatter with Team/Docker/Worktree allowed-tools (removed SANDBOX_MGR, BUILD_IMG)
- **swarm.md**: Step 0 resolves only $AIMI_CLI and $WORKTREE_MGR (no SANDBOX_MGR or BUILD_IMG)
- **swarm.md**: Workers run `docker run --rm` with volume-mounted worktrees and `npx claude` inside generic `node:22-slim` image
- **swarm.md**: Team lead reads task file content and passes it in worker prompt (no reliance on task file in worktree)
- **swarm.md**: `status` subcommand reads task files directly (no swarm-state.json)
- **swarm.md**: `cleanup` subcommand removes aimi-* worktrees and Docker containers
- **swarm.md**: Merge conflict handling preserves worktrees for manual inspection

### Removed

- **docker-sandbox skill**: Removed entire skill (sandbox-manager.sh, build-project-image.sh, acp-adapter.py, Dockerfile.base)
- **swarm.md**: All references to Sysbox runtime, ACP protocol, sandbox-manager, build-project-image
- **swarm.md**: swarm-state.json state management (replaced by Team task list)
- **swarm.md**: `resume` subcommand (Team workers are foreground, no detached containers to resume)
- **swarm.md**: State reconciliation subroutine (no persistent container state to reconcile)
- **swarm.md**: Container provisioning with Sysbox-isolated containers
- **swarm.md**: ACP adapter invocation via docker exec/docker cp

## [1.23.2] - 2026-03-02

### Removed

- **auto-approve-cli.sh**: Remove swarm-* entries from CLI subcommand whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Remove Pattern 5 (SANDBOX_MGR= assignment) and Pattern 6 ($SANDBOX_MGR invocation)
- **auto-approve-cli.sh**: Remove Pattern 7 (BUILD_IMG= assignment) and Pattern 8 ($BUILD_IMG invocation)
- **auto-approve-cli.sh**: Remove Pattern 9 (docker exec aimi-* for ACP adapter)
- **auto-approve-cli.sh**: Remove Pattern 10 (docker cp for ACP payload files)

## [1.23.1] - 2026-03-02

### Changed

- **commands**: Extract CLI path resolution boilerplate to shared reference at `commands/references/cli-path-resolution.md`
- **execute.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **status.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **next.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **swarm.md**: Replace AIMI CLI resolution block in Step 0 with pointer to shared reference

## [1.23.0] - 2026-03-01

### Added

- **swarm.md**: Subscription auth detection in Step 2.5 — checks for `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
- **swarm.md**: `CLAUDE_AUTH=subscription` variable set when subscription credentials found
- **swarm.md**: `--mount-claude-config` flag passthrough to `sandbox-manager.sh create` when subscription auth detected
- **swarm.md**: Credential summary now displays `Claude` field showing subscription auth status

### Changed

- **swarm.md**: `ANTHROPIC_API_KEY` check is now a warning (not hard stop) when subscription auth is available
- **swarm.md**: Hard stop message updated to mention both `ANTHROPIC_API_KEY` and Claude config directory options
- **swarm.md**: Resume subcommand container recreation now passes `--mount-claude-config` when subscription auth detected
- **swarm.md**: Resume fan-out re-detection now includes `CLAUDE_AUTH` alongside `AUTH_METHOD`

## [1.22.0] - 2026-03-01

### Added

- **Dockerfile.base**: Pre-populate SSH known_hosts for GitHub, GitLab, and Bitbucket during image build
- **sandbox-manager.sh**: New `--ssh-agent` flag to forward host SSH_AUTH_SOCK into containers
- **acp-adapter.py**: SSH clone support with protocol detection (git@/ssh:// vs https://)
- **swarm.md**: Credential auto-detection step (Step 2.5) — detects ANTHROPIC_API_KEY, GITHUB_TOKEN via env/gh-cli/SSH agent
- **swarm.md**: Git remote fallback chain — tries origin, upstream, then first available remote
- **swarm.md**: AUTH_METHOD-to-protocol mismatch warnings (SSH auth with HTTPS remote, and vice versa)
- **swarm.md**: `--ssh-agent` flag passthrough in container provisioning when SSH auth detected
- **swarm.md**: Container creation command logging for debugging
- **swarm.md**: Resume subcommand now uses the same fallback chain and credential detection

### Fixed

- **swarm.md**: No longer hard-fails when `origin` remote is missing — falls back to other remotes
- **swarm.md**: Resume subcommand no longer hard-codes `git remote get-url origin`
- **acp-adapter.py**: SSH URLs no longer attempt HTTPS credential helper setup

## [1.21.0] - 2026-03-01

### Changed

- **README.md**: Added Skills section documenting all 17 skills (4 core, 6 development/style, 4 tooling/automation, 3 disabled/reference)
- **README.md**: Added Agents section documenting all 28 agents with descriptions per category
- **README.md**: Updated Components table from 4 skills to 17 skills
- **README.md**: Updated Table of Contents with Skills and Agents links
- **orchestrating-swarms SKILL.md**: Replaced all `compound-engineering:*` agent type references with `aimi-engineering:*` equivalents
- **orchestrating-swarms SKILL.md**: Updated agent lists to match actual aimi-engineering agents (removed non-existent `git-history-analyzer`, `repo-research-analyst`)

### Fixed

- **README.md**: Fixed stale `/aimi:plan-to-tasks` reference in troubleshooting → `/aimi:plan`
- **README.md**: Fixed "Check both plugins" → "Check plugin" in installation verification

### Removed

- **orchestrating-swarms SKILL.md**: All `compound-engineering` references eliminated — zero remaining in active plugin code

## [1.20.0] - 2026-03-01

### Changed

- **`check-version` CLI subcommand**: `_extract_version_from_path()` now uses bash parameter expansion (`${path%/*}`, `${no_scripts##*/}`) instead of `dirname`/`basename` forks — eliminates 3 subshell spawns per call
- **`check-version` CLI subcommand**: `current` status path uses `printf` instead of `jq -n` for JSON output — eliminates 1 jq fork on the happy path
- **`check-version` `--quiet` flag**: Suppresses all stderr warnings (e.g., stale/missing cli-path) for clean machine-readable output
- **`check-version` `--fix` flag**: Auto-updates `cli-path` via `write_state` on stale detection and outputs `{"status":"fixed",...}` with exit 0 instead of `{"status":"stale",...}` with exit 1
- **`check-version` dispatch table**: Now passes `"$@"` to `cmd_check_version` for flag forwarding
- **Command version-check blocks**: Consolidated multi-line `check-version` + jq parsing + `init-session` re-stamp in `execute.md`, `status.md`, `next.md`, and `swarm.md` into single `$AIMI_CLI check-version --quiet --fix` call — eliminates `2>/dev/null`, `VERSION_CHECK`, `VERSION_EXIT`, `STORED_VER`, `LATEST_VER` variables and jq dependency from version-check sections

### Added

- **`check-version` `--quiet` and `--fix` tests**: Tests for `--quiet` flag (suppressed stderr), `--fix` flag (auto-update on stale), combined `--quiet --fix` flags, and backward compatibility (no-flags behavior unchanged)

### Fixed

- **CHANGELOG.md**: Removed redundant `[1.18.1]` entry that duplicated content from `[1.18.0]`
- **auto-approve-cli.sh path traversal regex**: Version segments in plugin path now require digit-first pattern (`[0-9][0-9.]*`) — prevents crafted directory names from bypassing path validation

### Security

- **auto-approve-cli.sh `has_metacharacters()`**: Added `[<>]` character class to the first grep pattern — now blocks `>`, `>>`, `<`, `<<` redirection operators in addition to existing `;`, `&&`, `||`, backtick, and `$()` patterns

## [1.19.0] - 2026-03-01

### Added

- **`check-version` CLI subcommand**: Compares running plugin version against installed version on disk — returns JSON `{running, installed, match}` result; warns user on mismatch and triggers `init-session` to refresh `cli-path`
- **`cleanup-versions` CLI subcommand**: Finds and removes stale plugin versions from `~/.claude/plugins/cache/` — keeps only the latest installed version, returns JSON `{kept, removed: [paths]}` result
- **Step 0 version check integration**: All four execution commands (`execute.md`, `status.md`, `next.md`, `swarm.md`) now call `$AIMI_CLI check-version` after glob resolution — warns user on version mismatch and auto-updates `cli-path` via `init-session`; does NOT call `cleanup-versions` (cleanup is manual-only)
- **auto-approve-cli.sh whitelist**: Added `check-version` and `cleanup-versions` to the permitted subcommand list for auto-approval during task execution
- **test-aimi-cli.sh**: New tests covering `check-version` (match and mismatch scenarios) and `cleanup-versions` (no stale versions, stale version removal)

## [1.18.0] - 2026-03-01

### Added

- **Dockerfile.base**: COPY `acp-adapter.py` into base image at `/opt/aimi/acp-adapter.py` — containers now have the ACP adapter available for `docker exec` invocation
- **acp-adapter.py `provision_repo()`**: Repository cloning and branch checkout inside containers — clones `repoUrl`, configures GITHUB_TOKEN credential helper, checks out target branch (with fallback for new branches), verifies task file exists
- **acp-adapter.py `--input` flag**: File-based alternative to stdin for receiving task-request payloads — enables auto-approve-compatible `docker cp` + `docker exec --input` pattern
- **acp-adapter.py env var value sanitization**: `validate_env_var_value()` rejects values containing newlines, null bytes, or shell metacharacters (`;`, `&&`, `||`, backticks, `$(`)
- **acp-adapter.py progress throttling**: Progress emissions throttled to at most once every 2 seconds (time-based), reducing NDJSON volume by 90%+ with final line always emitted
- **acp-adapter.py concurrent stderr drain**: `threading.Thread` drains stderr concurrently while streaming stdout, preventing 64KB pipe buffer deadlock
- **sandbox-manager.sh `--container-id` and `--swarm-id`**: Optional flags for `cmd_create` to pass identity env vars into containers for ACP message envelopes
- **sandbox-manager.sh advisory disk limit**: Attempts `--storage-opt size=` and falls back gracefully with warning if storage driver doesn't support it
- **swarm.md non-interactive flags**: `--all`, `--files`, `--force`, `--append` flags skip AskUserQuestion prompts for fully autonomous agent-to-agent orchestration
- **auto-approve-cli.sh Pattern 9/10**: `docker exec` with optional `--input` flag and `docker cp` for ACP payload delivery — restricted to `aimi-` prefixed containers
- **SKILL.md total resource table**: Shows CPU, RAM, and swap consumption at 2, 4, and 8 containers with host sizing guidance (2x container RAM recommended)

### Fixed

- **auto-approve-cli.sh path regex**: Changed `skills/sandbox/` to `skills/docker-sandbox/` in `SANDBOX_MGR` and `BUILD_IMG` patterns to match actual plugin directory structure
- **sandbox-manager.sh swap default**: Changed `AIMI_SANDBOX_SWAP` from `4g` to `8g` — Docker's `--memory-swap` is total (memory + swap), so `4g` with `4g` memory meant zero actual swap
- **sandbox-manager.sh consolidated inspect**: Replaced 5 separate `docker inspect` calls in `cmd_status` with a single call using combined Go template format string
- **aimi-cli.sh swarm-cleanup**: Updated jq filter to also exclude `stopped` status (was only excluding `completed` and `failed`)
- **aimi-cli.sh `_validate_container_name`**: Harmonized with `sandbox-manager.sh` — now requires `aimi-` prefix and same character set (`^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`)
- **swarm.md Step 5 ACP invocation**: Changed from piped `echo | docker exec -i` to file-based `docker cp` + `docker exec --input` pattern — works with auto-approve hooks

## [1.17.1] - 2026-03-01

### Fixed

- **auto-approve-cli.sh**: Fixed `SANDBOX_MGR` and `BUILD_IMG` path validation regex patterns — changed `skills/sandbox/` to `skills/docker-sandbox/` to match actual plugin directory structure and the glob patterns used in swarm.md Step 0

## [1.17.0] - 2026-03-01

### Changed

- **`/aimi:swarm` status subcommand**: Now runs automatic state reconciliation before displaying status table — detects zombie entries (containers in state but missing from Docker), silent completions, silent failures, unexpected stops, and already-started containers
- **`/aimi:swarm` resume subcommand**: Enhanced with full crash recovery — reconciles state first, identifies resumable containers, recreates failed containers for retry, skips running/completed containers, fans out only pending containers
- **`/aimi:swarm` cleanup subcommand**: Enhanced with per-container removal reporting (removed vs already gone), proper state entry cleanup count, and graceful handling of missing swarms

### Added

- **State reconciliation subroutine** in swarm.md: Shared procedure that runs before `status` display and `resume` operations, comparing `swarm-state.json` entries against actual Docker daemon state via `sandbox-manager.sh status`
- **Zombie detection documentation**: New "State Reconciliation" reference section documenting detection scenarios (zombie, silent completion/failure, unexpected stop, already started), zombie causes, and idempotency guarantees

### Security

- **auto-approve-cli.sh**: Added `SANDBOX_MGR` patterns with path validation and subcommand whitelist (create, remove, list, status, cleanup, check-runtime)
- **auto-approve-cli.sh**: Added `BUILD_IMG` patterns with path validation for build-project-image.sh invocation
- **auto-approve-cli.sh**: Added swarm subcommands to `$AIMI_CLI` whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Added `docker exec -i aimi-*` pattern for ACP adapter communication — restricted to `aimi-` prefixed containers running `python3 /opt/aimi/acp-adapter.py` only (no wildcard Docker approvals)

## [1.16.0] - 2026-03-01

### Added

- **`/aimi:swarm` command**: Multi-task Docker sandbox orchestration for parallel feature execution
  - Discovers `.aimi/tasks/*-tasks.json` files, presents multi-select list to user
  - Supports `--file <path>` flag for single-file execution
  - Provisions Sysbox-isolated Docker containers via `sandbox-manager.sh` for each task file
  - Builds per-project images via `build-project-image.sh` with checksum-based rebuild skipping
  - Fans out parallel Task agents, each communicating with its container via ACP adapter (`docker exec -i`)
  - Tracks execution via `swarm-state.json` using CLI swarm-* subcommands
  - Configurable `maxContainers` limit (default 4, override with `--max <N>`)
  - Subcommands: `status` (view swarm state), `resume` (restart pending containers), `cleanup` (remove containers and state)
  - Handles partial failure: failed containers marked in state, successful ones continue independently
  - Reports summary with per-container status, branch names, and PR URLs

## [1.15.0] - 2026-03-01

### Changed

- **execute.md parallel execution rewrite**: Replaced Team/SendMessage swarm orchestration with foreground fan-out using `run_in_background` Task agents — eliminates Team lifecycle complexity, reduces token overhead, and runs parallel workers directly from the orchestrator's context
- **execute.md Team/SendMessage dependency removed**: Parallel story execution no longer requires TeamCreate, SendMessage, or teammate coordination — workers are spawned as background tasks and polled for completion

### Fixed

- **worktree-manager.sh merge stderr suppression**: Removed `2>/dev/null` from `git checkout` and `git merge` commands in `merge_worktree()` and `merge_all_worktrees()` functions — merge conflicts and failures are now visible in stderr for proper diagnosis

## [1.14.0] - 2026-02-28

### Changed

- **aimi-cli.sh portable `_lock()` function**: Replaces direct `flock` calls with cross-platform locking — Linux uses `flock`, macOS uses atomic `mkdir` spinlock with 10s stale-lock timeout and `trap EXIT` cleanup
- **aimi-cli.sh platform detection at startup**: Caches `_HAS_FLOCK` and `_HAS_REALPATH` to avoid per-call `command -v` overhead
- **aimi-cli.sh `cmd_clear_state`**: Also removes `*.lock.d` directories (mkdir-based lock cleanup)
- **execute.md CLI resolution**: Glob first (always finds latest version), cli-path as fallback only — prevents stale cached path from using old plugin version
- **status.md + next.md CLI resolution**: Consistent with execute.md — glob first, cli-path fallback (was glob-only, no fallback)

## [1.13.0] - 2026-02-27

### Added

- **aimi-cli.sh `resolve_path()` helper**: POSIX-compatible path resolution (uses `realpath` when available, falls back to `cd`+`pwd`+`basename` for macOS)
- **aimi-cli.sh `reset-orphaned` subcommand**: Atomically marks all `in_progress` stories as `failed`, returns `{count, reset: [ids]}` — replaces fragile `status | jq` pipeline
- **aimi-cli.sh `validate_story_exists()` function**: Verifies story ID exists in tasks file before mutation; all `mark-*` and `cascade-skip` commands now exit 1 with clear error for non-existent IDs
- **aimi-cli.sh `cli-path` state file**: `init-session` writes CLI's absolute path to `.aimi/cli-path` for reliable resolution across shell sessions
- **aimi-cli.sh stale state warning**: `get_tasks_file()` prints stderr warning when `current-tasks` points to a deleted file, auto-updates state with discovered alternative
- **test-aimi-cli.sh**: 16 new tests (65 total) covering: resolve_path, cli-path, userStories key, story ID existence validation, reset-orphaned (empty + with orphans), stale state warning
- **test-aimi-cli.sh `assert_stderr_contains` helper**: New test helper for validating stderr output

### Changed

- **aimi-cli.sh `cmd_status` output**: Renamed `.stories` key to `.userStories` for consistency with schema v3.0 source field name
- **aimi-cli.sh state files**: `init-session` and `get_tasks_file()` now store absolute paths in `.aimi/current-tasks` (resolves cwd-dependency bugs)
- **aimi-cli.sh `write_state()` and `clear_state_file()`**: Now use `flock` with `$AIMI_DIR/.state.lock` for parallel execution safety
- **aimi-cli.sh `cmd_clear_state`**: Also removes `.state.lock`, `cli-path`, and all `.lock` files under `.aimi/`
- **execute.md Step 0**: CLI resolution now tries `cat .aimi/cli-path` first, falls back to `ls` glob if missing or invalid
- **execute.md orphaned recovery**: Replaced `status | jq` pipeline with `$AIMI_CLI reset-orphaned` subcommand
- **status.md**: Updated example output to use `userStories` key
- **auto-approve-cli.sh**: Added `reset-orphaned` to subcommand whitelist

## [1.12.0] - 2026-02-27

### Added

- **worktree-manager.sh `remove` command**: New `remove <worktree-name>` subcommand for non-interactive worktree cleanup (`git worktree remove --force` + `git branch -D`)
- **worktree-manager.sh `--from` flag**: `create` now supports `create name --from branch` (and positional backward compat)
- **worktree-manager.sh input validation**: `validate_branch_name()` with regex `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`, path containment check via `realpath -m`
- **aimi-cli.sh flock-based file locking**: All 5 mutation functions use `flock -x` advisory locking with unique `mktemp` temp files
- **aimi-cli.sh `validate_story_id()`**: Regex `^US-[0-9]{3}[a-z]?$` validated on all mark-* commands
- **aimi-cli.sh `validate-stories` command**: Checks field lengths (title: 200, description: 500, criterion: 300) and suspicious content patterns for prompt injection defense
- **aimi-cli.sh `maxConcurrency` guard**: Values <= 0 default to 4 in status and metadata commands
- **execute.md orphaned recovery**: Step 1 detects stories stuck in `in_progress` from interrupted runs, resets to `failed`
- **execute.md content validation**: Step 1 calls `validate-stories` before any execution
- **execute.md agent-driven merge conflict resolution**: On merge conflict, spawns a Task agent to attempt resolution before falling back to manual
- **execute.md worker timeout**: Configurable timeout (default 15 min); non-responding workers marked as failed

### Changed

- **worktree-manager.sh**: Removed all interactive `read -r` prompts — create reuses existing worktrees silently, cleanup proceeds without confirmation
- **worktree-manager.sh**: Removed unnecessary `git checkout`/`git pull` from create (worktree add works without checkout)
- **worktree-manager.sh**: `chmod 600` applied to all copied .env files; git commands use `--` separator before branch arguments
- **story-executor SKILL.md**: Fixed contradiction (agents report results, callers handle status via CLI), removed duplicated sections (compact prompt, JS examples, default rules), added `story.notes` placeholder, declared as canonical prompt template
- **execute.md**: Moved `validate-deps` from parallel-only path to shared Step 3.1 — both sequential and parallel validate dependency graph
- **execute.md**: Worker prompt includes `## PREVIOUS NOTES` section with `story.notes` (omitted when empty)
- **execute.md + next.md**: Replaced duplicated inline worker prompts with references to story-executor SKILL.md canonical template (net -96 lines)
- **execute.md + next.md**: Replaced duplicated guideline loading sections with references to story-executor discovery order

### Security

- **auto-approve-cli.sh**: Replaced permissive `$AIMI_CLI` pattern with explicit subcommand whitelist (19 commands) and shell metacharacter rejection
- **auto-approve-cli.sh**: `AIMI_CLI=` assignment now validates path matches expected plugin install directory
- **auto-approve-cli.sh**: Added `WORKTREE_MGR` patterns with path validation and subcommand whitelist (create, remove, merge, list, help)

## [1.11.0] - 2026-02-27

### Removed

- **v2.2 backward compatibility**: All v2.2 schema support removed — v3.0 is now the only supported format
- **plan-to-tasks skill**: Deleted entire `skills/plan-to-tasks/` directory (v2.2-only task generator)
- **detect-schema CLI command**: Removed `detect-schema` command and all dual-schema detection logic from aimi-cli.sh
- **v2.2 code paths in CLI**: Removed `detect_schema()`, `is_v3()`, `cmd_detect_schema()` functions and all if/else version branching
- **v2.2 test fixtures**: Rewrote test suite to v3-only (49 tests, all passing)
- **v2.2 references in docs**: Cleaned all v2.2 mentions from commands (deepen, next, status, execute), execution-rules, task-format-v3, story-decomposition, and CLAUDE.md files

## [1.10.0] - 2026-02-27

### Fixed

- **Plugin CLAUDE.md**: Updated schema example from v2.1 to v3 (status, dependsOn, maxConcurrency)
- **story-executor**: Removed direct tasks file mutation instructions — agents now delegate to CLI for all status updates
- **execution-rules.md**: Updated with v3 status enum and dual-schema documentation
- **deepen.md**: Made schema-aware — detects v3 status field instead of v2.2 passes boolean
- **next.md**: Updated CLI output example with both v3 and v2.2 variants
- **pipeline-phases.md**: Fixed output report from "Schema: 2.2" to "Schema: 3.0"
- **story-decomposition.md**: Fixed conversion rule from `passes: false` to `status: "pending"`

### Changed

- **aimi-cli.sh**: Removed dead code (abandoned jq blocks, duplicated ready-story logic); DRYed cmd_next_story to reuse cmd_list_ready
- **plan-to-tasks**: Added deprecation notice (generates v2.2 only; use task-planner for v3)

### Added

- **test-aimi-cli.sh**: 31 new v3 test cases covering detect-schema, list-ready, mark-in-progress, validate-deps, cascade-skip, dependency resolution, and circular dependency detection (65 total tests)

## [1.9.0] - 2026-02-27

### Added

- **Schema v3 (`task-format-v3.md`)**: New tasks.json schema with dependency graph and parallel execution support
  - `dependsOn` (string[]) for explicit inter-story dependency graphs (DAG)
  - `status` enum (`pending`, `in_progress`, `completed`, `failed`, `skipped`) replacing `passes` boolean
  - `maxConcurrency` metadata field (default 4) for parallel story execution
  - `priority` retained as tiebreaker for stories at same dependency depth
  - Status state machine with valid transitions documented
  - `dependsOn` validation rules: no circular deps, no self-refs, all referenced IDs must exist
  - Backward compatibility with v2.2: auto-detection and fallback behavior
  - Migration guide: v2.2 to v3 conversion rules with priority-layer inference for `dependsOn`

- **Parallel execution in `/aimi:execute`**: Automatic detection and execution of independent stories in parallel
  - Wave-based execution: independent stories run concurrently within waves
  - Team/swarm orchestration for parallel workers using Claude Code Teams
  - Adaptive concurrency: `min(ready stories, maxConcurrency)`
  - Cascade-skip on failure: dependent stories automatically skipped when a dependency fails
  - v2.2 fallback: sequential execution preserved for older schema files
  - v3 with linear deps: runs sequentially without Team/worktree overhead

- **Worktree merge commands** in `worktree-manager.sh`
  - `merge <worktree-name> [--into <branch>]` — merge worktree branch into target
  - `merge-all <branch1> <branch2> ... [--into <branch>]` — sequential multi-merge
  - Merge conflict detection with conflicting file listing
  - Stop-on-conflict behavior for merge-all

- **CLI extensions** for v3 schema support in `aimi-cli.sh`
  - `detect-schema` — returns schema version (`2.2` or `3.0`)
  - `list-ready` — dependency-aware ready story detection (v3)
  - `mark-in-progress` — sets `status: "in_progress"` for a story (v3)
  - `validate-deps` — DAG validation for dependency graph (cycles, missing refs, self-refs)
  - `cascade-skip` — transitive skip on failure for dependent stories

### Changed

- **`/aimi:execute` command**: Rewritten for smart parallel/sequential execution based on schema version and dependency graph shape
- **`story-decomposition.md`**: Updated with `dependsOn` generation rules, layer-based inference, and parallel grouping examples
- **`task-planner` SKILL.md**: Phase 3 and Phase 4 updated for v3 output with `dependsOn` arrays and `status` field
- **`plan.md` command**: Output format updated to v3 schema with `dependsOn` and `status` fields
- **`story-executor` skill**: Added optional `WORKTREE_PATH` variable for parallel worker context; workers report status instead of writing tasks.json directly
- **`/aimi:status` command**: v3 display with status values, dependency info, and wave grouping; v2.2 display unchanged
- **CLI dual-version support**: `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `next-story` all updated for v2.2/v3 compatibility

## [1.8.0] - 2026-02-27

### Added

- **`brainstorm` skill**: Standalone process knowledge for brainstorming sessions
  - `skills/brainstorm/SKILL.md` (229 lines) — hybrid question flow, Ralph-style batched multiple-choice, adaptive exit, YAGNI, design document template
  - `skills/brainstorm/references/question-patterns.md` (240 lines) — formatting rules, scenario batches, response parsing, contextual question generation

### Changed

- **`/aimi:brainstorm` command**: Full rewrite as standalone (no longer wraps compound-engineering)
  - Phase 0: Assess requirements clarity
  - Phase 1: Codebase research via `aimi-codebase-researcher` agent
  - Phase 2: Batched 3-5 multiple-choice questions with "1A, 2C, 3B" shorthand
  - Phase 3: Conditional approaches (only when multiple valid paths exist)
  - Phase 4: Design document capture with slug derivation, collision handling, open questions enforcement
  - Phase 5: Aimi-branded handoff
- **compound-engineering dependency fully eliminated**: All commands and skills are now standalone. Zero external plugin dependencies required.
- **CLAUDE.md**: Dependencies section updated to reflect full independence
- **`aimi-code-simplicity-reviewer` agent**: Updated pipeline artifacts reference
- **`aimi-best-practices-researcher` agent**: Removed `compound-docs` from skill mapping

## [1.7.0] - 2026-02-26

### Added

- **PermissionRequest hook**: Auto-approves `$AIMI_CLI` and `AIMI_CLI=` Bash commands during task execution, eliminating manual permission prompts for CLI operations
  - `hooks/hooks.json` — hook configuration
  - `hooks/auto-approve-cli.sh` — approval script matching only AIMI CLI patterns

## [1.6.0] - 2026-02-25

### Changed

- **Output directory**: All document output paths moved from `docs/` to `.aimi/`
  - `docs/tasks/` → `.aimi/tasks/`
  - `docs/brainstorms/` → `.aimi/brainstorms/`
  - `docs/plans/` → `.aimi/plans/`
  - `docs/solutions/` → `.aimi/solutions/`
- **`aimi-cli.sh`**: `TASKS_DIR` now derived from `$AIMI_DIR` variable (`$AIMI_DIR/tasks`)
- All commands, skills, and agents updated with new paths

## [1.5.2] - 2026-02-25

### Changed

- **`/aimi:plan` command**: Inlined full task-planner pipeline directly into plan.md to fix double skill loading issue (both `plan` command and `task-planner` skill were loading into context)
- **`task-planner` skill**: Set to `user-invocable: false` since pipeline is now embedded in `/aimi:plan`

## [1.5.1] - 2026-02-25

### Added

- **Context7 MCP server**: Registered `context7` HTTP MCP server directly in plugin.json so `aimi-best-practices-researcher` and `aimi-framework-docs-researcher` can access documentation without compound-engineering installed

## [1.5.0] - 2026-02-25

### Added

- **28 aimi-native agents**: Standalone agents that eliminate compound-engineering dependency for plan, review, and deepen workflows
  - 4 research agents: `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`
  - 15 review agents: `aimi-architecture-strategist`, `aimi-security-sentinel`, `aimi-code-simplicity-reviewer`, `aimi-performance-oracle`, `aimi-agent-native-reviewer`, `aimi-data-integrity-guardian`, `aimi-data-migration-expert`, `aimi-deployment-verification-agent`, `aimi-schema-drift-detector`, `aimi-pattern-recognition-specialist`, `aimi-dhh-rails-reviewer`, `aimi-kieran-rails-reviewer`, `aimi-kieran-typescript-reviewer`, `aimi-kieran-python-reviewer`, `aimi-julik-frontend-races-reviewer`
  - 3 design agents: `aimi-design-implementation-reviewer`, `aimi-design-iterator`, `aimi-figma-design-sync`
  - 1 docs agent: `aimi-ankane-readme-writer`
  - 5 workflow agents: `aimi-spec-flow-analyzer`, `aimi-bug-reproduction-validator`, `aimi-every-style-editor`, `aimi-lint`, `aimi-pr-comment-resolver`

### Changed

- **`task-planner` skill**: All agent references updated from `compound-engineering:*` to `aimi-engineering:*`
- **`/aimi:deepen` command**: Now uses `aimi-engineering:research:aimi-codebase-researcher` instead of compound agent
- **`/aimi:review` command**: Fully rewritten as standalone multi-agent review command. No longer wraps `/workflows:review`. Invokes parallel aimi-native review agents with default agents (architecture, security, simplicity, performance, agent-native), conditional migration agents, language-specific reviewers, and findings synthesis with severity categorization.
- **Reduced compound-engineering dependency**: Only `/aimi:brainstorm` still requires compound-engineering. Plan, deepen, and review are now fully standalone.

## [1.4.0] - 2026-02-25

### Added

- **`task-planner` skill**: New skill that generates `tasks.json` directly from a feature description. Full pipeline: brainstorm detection, local/external research (parallel), spec-flow analysis, story decomposition, and direct JSON output — no intermediate markdown plan.
  - `skills/task-planner/SKILL.md` (160 lines) — orchestration overview and agent invocation syntax
  - `skills/task-planner/references/pipeline-phases.md` — detailed phase-by-phase instructions
  - `skills/task-planner/references/story-decomposition.md` — sizing, ordering, validation rules

### Changed

- **`/aimi:plan` command**: No longer wraps compound-engineering `/workflows:plan`. Now invokes the `task-planner` skill directly, producing `tasks.json` without an intermediate plan markdown file.
- **`/aimi:deepen` command**: No longer wraps compound-engineering `/deepen-plan`. Now enriches `tasks.json` directly — spawns research agents per pending story, improves acceptance criteria, splits oversized stories, preserves completed story state. Accepts optional path argument; auto-discovers most recent tasks.json if omitted.
- **Schema version**: Bumped from 2.1 to 2.2
  - `metadata.planPath` is now optional/nullable (`null` when generated by task-planner)
  - `metadata.brainstormPath` documented as optional context reference
  - Backward compatible with v2.1 — existing files work without modification
- **`plan-to-tasks` skill**: Updated to output schema v2.2. Added note directing users to `task-planner` for direct generation. Remains functional as standalone converter for external markdown plans.

## [1.3.1] - 2026-02-25

### Fixed

- **`/aimi:plan` not loading `plan-to-tasks` skill**: Step 4 used ambiguous pseudo-syntax (`Skill: plan-to-tasks`) inside a code block, which Claude interpreted as descriptive text instead of an actionable tool invocation
  - Replaced with explicit instructions to call the Skill tool with `skill: "aimi-engineering:plan-to-tasks"`
  - Added "Do NOT generate tasks.json from memory or inline" guardrail
  - Added fallback: read `SKILL.md` directly if Skill tool is unavailable
  - Updated Step 5 to clarify the skill handles output writing

## [1.3.0] - 2026-02-24

### Fixed

- **CLI script path resolution**: Commands now resolve `aimi-cli.sh` from plugin install directory (`~/.claude/plugins/cache/*/aimi-engineering/*/scripts/`) instead of using `./scripts/` relative path which fails when cwd is the user's project
  - Updated `execute.md`, `next.md`, `status.md` with Step 0: Resolve CLI Path
  - Added `$AIMI_CLI` variable pattern (matches compound-engineering's plugin path convention)
  - Updated `allowed-tools` frontmatter to permit `$AIMI_CLI` execution
  - Updated README architecture section and CLI help examples

## [1.2.2] - 2026-02-24

### Fixed

- **Schema structure divergences** across 7 files:
  - `commands/plan.md`: Schema version output said "2.0" instead of "2.1"
  - `README.md`: jq example referenced non-existent top-level `project`/`branchName` fields (now uses `metadata.*`)
  - `README.md`: Removed stale `steps`/`taskType` from field length limits table (fields removed in v2.1)
  - `README.md`: Updated intro text (removed references to removed `steps`/`qualityChecks` fields)
  - `README.md`: Added missing Root Fields table, moved `schemaVersion` out of Metadata table
  - `README.md`: Added missing `brainstormPath` to Metadata Fields table
  - Root `CLAUDE.md`: Replaced obsolete pre-v2.0 schema (missing `schemaVersion`, `metadata` wrapper) with current v2.1 structure
  - `marketplace.json`: Synced version from "0.2.0" to "1.2.2" (matching plugin.json)

## [1.2.1] - 2026-02-24

### Changed

- **Schema version bump**: `schemaVersion` updated from "2.0" to "2.1" across all files
  - README.md, CLAUDE.md, SKILL.md, task-format.md, test-aimi-cli.sh

## [1.2.0] - 2026-02-24

### Added

- **aimi-cli.sh**: Single bash script for deterministic task file operations
  - 13 subcommands: `init-session`, `find-tasks`, `status`, `metadata`, `next-story`, `current-story`, `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `get-branch`, `get-state`, `clear-state`
  - State management via `.aimi/` directory (persists across `/clear`)
  - Atomic file updates using temp file + mv pattern
  - Comprehensive test suite (33 tests)
- **Story-by-story execution**: Execute one story at a time with `/clear` between stories
- `.gitignore` entry for `.aimi/` state directory

### Changed

- **Commands updated to use CLI instead of inline jq**:
  - `/aimi:execute` - Uses `init-session`, `count-pending`, `get-state`
  - `/aimi:next` - Uses `next-story`, `mark-complete`, `mark-failed`, `mark-skipped`
  - `/aimi:status` - Uses `status` command
- Simplified command files (less error-prone, no jq interpretation by AI)

### Fixed

- AI hallucination when interpreting bash commands embedded in markdown
  - Variable substitution errors
  - Command sequence errors
  - jq query modifications
  - Path/filename errors

## [1.1.0] - 2026-02-17

### Changed

- Restored v2.0 tasks.json schema with task-specific fields
  - Re-added `taskType`, `steps`, `relevantFiles`, `qualityChecks` to story schema
  - `schemaVersion` changed from "3.0" to "2.0"
  - Improved agent execution with domain-specific guidance
  - All story `steps` start with "Read CLAUDE.md and AGENTS.md for project conventions"

### Added

- Automated taskType detection via keyword matching (7 types)
  - `prisma_schema` - Database schema/migration changes
  - `server_action` - Server-side logic and actions
  - `react_component` - React/UI component work
  - `api_route` - API endpoint implementation
  - `utility` - Helper functions and services
  - `test` - Test implementation
  - `other` - Fallback for unclassified tasks
- Predefined step templates for each taskType
- `relevantFiles` inference from story content + taskType defaults
- `qualityChecks` assignment based on taskType
- New placeholders in prompt template: `[TASK_TYPE]`, `[STEPS_ENUMERATED]`, `[RELEVANT_FILES_BULLETED]`, `[QUALITY_CHECKS_BULLETED]`

### Removed

- v3.0 schema (minimal field set without task-specific guidance)

### Migration

Existing v3.0 tasks.json files must be regenerated:

```bash
/aimi:plan [feature]
```

## [1.0.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v3.0 with Ralph-style flat stories
  - Flat story structure (no nested `tasks[]` array)
  - Story IDs changed from `story-0` to `US-001` format
  - Added `priority` field for explicit execution order
  - Simple `passes: true/false` state tracking (no per-task status)
  - Per-story `acceptanceCriteria` array (moved from root level)
  - Required "Typecheck passes" in every story's acceptance criteria
  - `successMetrics` at root level for tracking improvements

### Added

- **Priority-based execution**: `/aimi:next` uses jq `sort_by(.priority)` to select next story
- **Project guidelines loading**: CLAUDE.md/AGENTS.md loaded before implementation
- **Aimi default rules**: Fallback commit format and quality checks when no project guidelines exist
- Brainstorm document: `docs/brainstorms/2026-02-16-ralph-style-tasks-brainstorm.md`

### Updated

- `plan-to-tasks` skill updated for flat story conversion
- `task-format.md` reference rewritten for v3.0 schema
- `story-executor` skill simplified for flat structure
- `execution-rules.md` updated with "Read Project Guidelines" as Step 1
- `/aimi:next` loads guidelines before building Task prompt
- `/aimi:execute` derives branch name from metadata title
- `/aimi:status` shows priority in story list

### Removed

- Nested `tasks[]` array structure
- `estimatedEffort` field (agent determines pace from story scope)
- `taskType`, `steps`, `relevantFiles`, `patternsToFollow` fields
- Root-level `acceptanceCriteria` (now per-story)
- `deploymentOrder` field

### Migration

Existing tasks.json files need to be regenerated:

```bash
/aimi:plan-to-tasks docs/plans/your-plan.md
```

## [0.9.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v2.0 with nested tasks structure
  - Stories contain nested `tasks[]` array with task objects
  - Added `metadata` object with `title`, `type`, `createdAt`, `planPath`, `brainstormPath`
  - Added `successMetrics` object for tracking improvements
  - Tasks have `id`, `title`, `description`, `file`, `action`, `status` fields
  - Added `estimatedEffort` field to stories

### Updated

- `plan-to-tasks` skill updated for new schema structure
- `task-format.md` reference rewritten for v2.0 schema
- `story-executor` skill updated to work with nested tasks
- `execution-rules.md` updated for task-based execution flow

### Removed

- Old schema fields: `taskType`, `steps`, `relevantFiles`, `patternsToFollow`, `qualityChecks` (per-story)

## [0.8.0] - 2026-02-16

### Fixed

- **Aimi-Branded Messaging**: All commands now show only Aimi commands in next steps
  - Commands still execute compound-engineering workflows under the hood
  - Post-completion options are intercepted and replaced with Aimi equivalents
  - Command mapping: `/workflows:plan` → `/aimi:plan`, `/deepen-plan` → `/aimi:deepen`, etc.

### Changed

- `/aimi:brainstorm` - Added Step 2 with Aimi-branded next steps override
- `/aimi:plan` - Added Step 6 with Aimi-branded report override
- `/aimi:deepen` - Added Step 6 with Aimi-branded report override
- `/aimi:review` - Added Step 2 with Aimi-branded summary override
- All commands include "NEVER mention" guidance to prevent compound-engineering leakage

## [0.7.0] - 2026-02-16

### Added

- **Project Guidelines Injection**: CLAUDE.md/AGENTS.md content injected into Task prompts
  - Discovery order: CLAUDE.md (root) → AGENTS.md (directory) → Aimi defaults
  - Small files (<2KB) inlined, larger files referenced
- **Aimi Default Commit/PR Rules**: Fallback rules when project lacks CLAUDE.md/AGENTS.md
  - `default-rules.md` reference file with commit format, behavior, and PR guidelines
  - Always applied if project files lack commit/PR section
- **Fresh Context Per Story**: Each Task agent starts with clean context (no memory carryover)

### Changed

- **BREAKING:** Renamed `[PATTERNS_CONTENT]` placeholder to `[PROJECT_GUIDELINES]`
- Story-executor now uses `get_project_guidelines()` instead of `get_patterns_content()`
- Execution rules Step 1 now reads CLAUDE.md/AGENTS.md instead of progress.md
- Learnings stored in CLAUDE.md (project-wide) or AGENTS.md (module-specific)

### Removed

- `patternsToFollow` field is now optional (guidelines discovery is automatic)

## [0.6.0] - 2026-02-16

### Changed

- **BREAKING:** Removed `progress.md` - all state now in `tasks.json`
  - No more progress.md initialization in `/aimi:plan`
  - No more progress entry appending in `/aimi:next`
  - No more CODEBASE_PATTERNS from progress.md
- Simplified prompt template (removed progress.md references)
- Simplified interpolation function signature

### Removed

- `progress.md` file and all references
- CODEBASE_PATTERNS placeholder
- `Bash(grep:*)`, `Bash(cat:*)`, `Bash(tail:*)` from allowed-tools (no longer needed)

## [0.5.1] - 2026-02-16

### Fixed

- `/aimi:next` now ensures `progress.md` is always updated after task completion
  - Step 5a: Verify tasks.json updated, fallback update via jq if not
  - Step 5b: Check if progress entry exists, append if missing
- `/aimi:status` now uses jq for minimal context usage
- `/aimi:status` shows skipped stories with `✗` indicator
- `/aimi:status` displays recent activity from progress.md

### Added

- `Bash(grep:*)`, `Bash(cat:*)` to `/aimi:next` allowed-tools
- `Bash(tail:*)` to `/aimi:status` allowed-tools

## [0.5.0] - 2026-02-16

### Added

- **jq-based task extraction**: Only load ONE story into context at a time
  - `/aimi:execute` extracts only metadata (project, branchName, counts)
  - `/aimi:next` extracts only the next pending story
- **`skipped` field**: Prevents infinite loop on failed tasks
  - When user says "skip", sets `skipped: true` on the story
  - jq query filters: `passes == false AND skipped != true`

### Changed

- `/aimi:execute` now shows separate counts for pending, completed, and skipped
- `/aimi:next` uses jq instead of reading full tasks.json
- Added `Bash(jq:*)` to allowed-tools for both commands

### Fixed

- Infinite loop when a task keeps failing (now properly excluded after skip)

## [0.4.2] - 2026-02-16

### Fixed

- `/aimi:plan` now properly runs compound-engineering's `/workflows:plan` first, then automatically converts to tasks.json
- Added explicit two-phase execution flow with no user prompts between phases
- Added `Skill(compound-engineering:workflows:plan)` to allowed-tools

### Added

- Error handling section in `/aimi:plan` for failed or cancelled operations

## [0.4.1] - 2026-02-16

### Security

- **Path Traversal Prevention**: Added comprehensive path validation for `relevantFiles` and `patternsToFollow`
  - Blocks `..` sequences, absolute paths, protocol prefixes, null bytes
  - Blocks access to sensitive paths (`.git/`, `.env`, `.ssh/`)
- **Expanded Command Injection Blocklist**: Now blocks `&&`, `||`, `>`, `>>`, `<`, newlines, and more
- **Strengthened Prompt Injection Defenses**: Added patterns for role manipulation, system prompt extraction, and boundary breaking

### Added

- **Schema Versioning**: `schemaVersion` field in tasks.json (v2.0 for task-specific steps)
- **qualityChecks Field**: Explicit verification commands per story (typecheck, test, lint)
- **AGENTS.md Content Injection**: Small AGENTS.md files (< 2KB) are inlined directly in prompts
- **Placeholder Interpolation Documentation**: Complete reference for prompt template placeholders
- **Pattern Matching Tie-Breaking Rules**: Deterministic selection when multiple patterns match

### Changed

- **Naming Consistency**: Renamed `file_patterns` to `filePatterns` (camelCase) in pattern library
- **Simplified Error Messages**: Consistent format: `Error: Story [ID] - [field]: [issue]. Fix: [action].`
- **Consolidated Validation Rules**: task-format.md is now the single source of truth
- **Removed Duplicate Prompt Example**: Task Tool Invocation section now references the main template

### Fixed

- Pattern files now use consistent camelCase for `filePatterns` field

## [0.4.0] - 2026-02-16

### Added

- **Task-Specific Step Generation**: Each story now includes pre-computed, domain-aware execution steps
- **Pattern Library** (`docs/patterns/`): Workflow templates for common task types
  - `prisma-schema.md` - Database schema changes with Prisma
  - `server-action.md` - Next.js server actions
  - `react-component.md` - React component creation
  - `api-route.md` - API endpoint implementation
- **AGENTS.md Discovery**: Automatic discovery and matching of AGENTS.md files to tasks
- **TaskType Inference**: Keyword-based pattern matching with LLM fallback

### Changed

- **BREAKING:** tasks.json schema now requires four new fields per story:
  - `taskType` (string, snake_case, max 50 chars) - Domain classification
  - `steps` (array, 1-10 items, each max 500 chars) - Task-specific execution steps
  - `relevantFiles` (array, max 20 items) - Files to read first
  - `patternsToFollow` (string) - AGENTS.md path or "none"
- `/aimi:next` now validates required fields before execution
- `/aimi:next` prompt template uses story.steps instead of generic execution flow
- `story-executor` skill updated with STEPS, RELEVANT FILES, and PATTERNS sections
- `plan-to-tasks` skill now generates task-specific fields during conversion

### Migration

Existing tasks.json files will fail validation. To migrate:

```bash
# Regenerate tasks.json from your plan file
/aimi:plan-to-tasks docs/plans/your-plan.md
```

Or manually add the required fields to each story in tasks.json.

## [0.3.0] - 2026-02-15

### Changed

- **BREAKING:** Rename `completed` field to `passes` in tasks.json schema
  - Better reflects acceptance criteria validation semantics (pass/fail)
  - Aligns with testing vocabulary
  - Updated all commands: deepen, execute, next, status
  - Updated all skills: plan-to-tasks, story-executor
  - Existing tasks.json files need field renamed from `completed` to `passes`

## [0.2.1] - 2026-02-15

### Added

- AGENTS.md update instructions in story-executor (mirrors Ralph's prompt.md pattern)
- Step 10 in execution-rules.md for updating AGENTS.md files with reusable patterns
- AGENTS.md guidance in compact prompt template

### Changed

- Execution flow now includes AGENTS.md check before committing (Step 5 in SKILL.md)

## [0.2.0] - 2026-02-15

### Security

- **BREAKING:** Add branchName validation in `/aimi:execute` to prevent command injection
- Add input sanitization for story content before prompt interpolation (prevents prompt injection)
- Restrict Bash permissions in `/aimi:next` to specific command prefixes (git, npm, bun, yarn, tsc, eslint, prettier)

### Changed

- **BREAKING:** Introduced `completed` field in tasks.json schema (now renamed to `passes` in v0.3.0)
- Inline story data in Task prompts (reduces file I/O by ~33%)
- Extract only Codebase Patterns from progress.md (reduces context usage)
- Add structured error format with type classification for programmatic handling

### Added

- JSON schema validation requirements in task-format.md
- Available Capabilities section in story-executor (agents know their tools)
- Compact prompt template for subsequent stories (~60% token reduction)
- Progress rotation guidelines (archive when exceeding 50KB)
- Error type classification: typecheck_failure, test_failure, lint_failure, runtime_error, dependency_missing, unknown

### Removed

- Duplicate plugin.json at root level (keep only in plugins/aimi-engineering/)

## [0.1.0] - 2026-02-15

### Added

#### Commands
- `/aimi:brainstorm` - Explore ideas through guided brainstorming (wraps compound-engineering)
- `/aimi:plan` - Create implementation plan and convert to tasks.json
- `/aimi:deepen` - Enhance plan with research and update tasks.json
- `/aimi:review` - Code review using compound-engineering workflows
- `/aimi:status` - Show current task execution progress
- `/aimi:next` - Execute the next pending story with retry logic
- `/aimi:execute` - Run all stories autonomously in a loop

#### Skills
- `plan-to-tasks` - Convert markdown implementation plans to structured tasks.json format
- `story-executor` - Provides prompt template for Task-spawned agents executing stories

#### Documentation
- Task format reference with JSON schema and sizing rules
- Execution rules reference with 9-step execution flow
- Complete README with workflow guide and troubleshooting

### Dependencies

This plugin requires **compound-engineering-plugin** for brainstorm, plan, and review workflows.
