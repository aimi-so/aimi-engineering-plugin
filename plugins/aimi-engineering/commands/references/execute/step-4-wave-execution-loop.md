# Execute: Step 4: Wave Execution Loop

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 4: Wave Execution Loop

```
wave = 1
is_first_story_in_session = true
DESIGN_REVIEW_BUFFERS = {}  # key: story_id, value: {title, output}; populated by post-merge design reviewer
CONSOLE_BUFFER = {}         # key: story_id, value: ATTRIBUTION object; populated by post-merge console capture (see Console Error Attribution section)

# WAVE_TASKS_FILE — this run's own tasks file, resolved once here with the
# same PHASE_MODE-conditioned formula Step 3 above already applied ($PHASE_TASKS_PATH
# when PHASE_MODE=true, else $TASKS_PATH (absolute) — both already resolved by
# this point in every flow, including a split sub-orchestrator, which pre-sets
# PHASE_TASKS_PATH before it ever reaches here). Every CLI call in this loop
# passes it explicitly as --tasks-file instead of falling through to the
# shared current-tasks pointer, which is what let two concurrent split
# orchestrators silently read and mutate each other's file.
WAVE_TASKS_FILE = PHASE_TASKS_PATH if PHASE_MODE else TASKS_PATH

# PLAN_DISC — this run's own plan identity, the sanitized stem of the file
# above. Derived by the block in Multi-Repo Handling's `### Plan Discriminator`;
# run that block in the Bash call that needs the value and read it back from
# the PLAN_DISC= line it echoes, since every Bash call is an isolated shell.
PLAN_DISC = sanitized stem of WAVE_TASKS_FILE

while true:
    # ========================================
    # RE-POINT THE CLI — TOP OF THE WAVE, NEVER MID-WAVE
    # ========================================
    # Step 0 resolves $AIMI_CLI once, at the start of the run, and nothing in
    # this loop has ever revisited it. A wave loop outlives that resolution:
    # a `cleanup-versions` run in another session prunes the cache directory
    # this run's path points into, and every later call answers "No such file
    # or directory" through a path that was correct when it was written.
    #
    # The POSITION is the load-bearing part, not the call. The same --fix run
    # between spawn and merge is what broke a mark-complete mid-wave: the
    # cached path moved while N workers already held the old one, so the
    # orchestrator wrote through a CLI its own workers had never seen. Here,
    # between the last merge of wave N and the first spawn of wave N+1,
    # nothing is in flight and a re-point can strand no one. Do not move this
    # call further down for symmetry with anything.
    #
    # Every Bash call in this file re-reads $AIMI_CLI from the cache --fix
    # rewrites (Step 0's Per-Call Resolution note), so the repointing reaches
    # the next call on its own; nothing is reassigned here. Read `status` and
    # not the exit code alone — `unknown` exits 0 and means no plugin is
    # installed at all (see cli-path-resolution.md's Version Check table).
    $AIMI_CLI check-version --quiet --fix

    # Check remaining work
    pending = $AIMI_CLI count-pending --tasks-file [WAVE_TASKS_FILE]
    if pending == 0: break

    # Get ready stories (brief mode — returns {id, title, priority, dependsOn, project, gate} only)
    # NOTE: The CLI's list-ready already filters out:
    #   - Stories with pending decision gates (blocked before start)
    #   - Stories whose dependencies have pending action gates (blocked until gate resolved)
    ready_stories = $AIMI_CLI list-ready --brief --tasks-file [WAVE_TASKS_FILE]
    if ready_stories is empty:
        if pending > 0:
            # ========================================
            # GATE-BLOCKED STORY DETECTION
            # ========================================
            # Before reporting deadlock, check if stories are blocked by gates.
            # Use $AIMI_CLI status to get all stories and identify gate-blocked ones.
            all_stories = $AIMI_CLI status --tasks-file [WAVE_TASKS_FILE]
            decision_blocked = []  # stories with pending decision gates
            action_blocked = []    # stories whose dependencies have pending action gates

            for story in all_stories.userStories:
                if story.status == "pending":
                    # Check for pending decision gates on this story
                    if story.gate and story.gate.type == "decision" and story.gate.status == "pending":
                        decision_blocked.append(story)
                    # Check for pending action gates on dependencies
                    else if story.dependsOn:
                        for dep_id in story.dependsOn:
                            dep = find story with id == dep_id in all_stories.userStories
                            if dep.gate and dep.gate.type == "action" and dep.gate.status == "pending":
                                action_blocked.append(story)
                                break

            if len(decision_blocked) > 0 or len(action_blocked) > 0:
                Report: "No stories ready — blocked by gates:"
                for story in decision_blocked:
                    Report: "  Waiting for decision on [story.id]: [story.gate.prompt]"
                for story in action_blocked:
                    Report: "  [story.id] paused — dependency has pending action gate"
                Report: ""
                Report: "Use /aimi:status to see gate details. Resolve gates with:"
                Report: "  $AIMI_CLI gate-pass <story-id> [--option 'value']"
                Break loop (proceed to completion)
            else:
                Report: "Deadlock detected: [pending] stories pending but none are ready."
                Report: "This may indicate circular dependencies or all remaining stories depend on failed/skipped stories."
                Break loop (proceed to completion)
        else:
            break

    # Adaptive concurrency
    concurrency = min(len(ready_stories), MAX_CONCURRENCY)
    selected_stories = ready_stories[0:concurrency]

    Report:
    "--- Wave [wave] ---"
    "Executing [len(selected_stories)] stories"
    For each story: "  - [story.id]: [story.title]"

    # Mark all selected stories as in-progress
    for story in selected_stories:
        $AIMI_CLI mark-in-progress [story.id] --tasks-file [WAVE_TASKS_FILE]

    # ========================================
    # WORKTREE WAVE (parallel with worktrees)
    # ========================================

    # All selected stories proceed — story data is fetched by each subagent via get-story-context
    full_stories = selected_stories

    # Proceed with worktree parallelism

    # ========================================
    # GROUP STORIES BY PROJECT — see Multi-Repo Handling section
    # ========================================

    project_groups = {}  # key: project_path (or "DEFAULT"), value: list of full_story
    for full_story in full_stories:
        if full_story.project is not null/absent:
            group_key = full_story.project
        else:
            group_key = "DEFAULT"
        project_groups[group_key].append(full_story)

    # Resolve absolute paths for each project group
    # AIMI_ROOT = directory containing .aimi/ (resolved during init-session)
    project_roots = {}  # key: group_key, value: absolute path to git root
    for group_key in project_groups:
        if group_key == "DEFAULT":
            project_roots[group_key] = CWD  (current working directory / git root)
        else:
            project_roots[group_key] = AIMI_ROOT / group_key  (resolve to absolute path)

    # ========================================
    # DERIVE EXEC_ROOT / EXEC_BRANCH PER PROJECT GROUP — see container-
    # execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT,
    # EXEC_KEEPS_BRANCH. This is the only place in the wave loop
    # and its cleanup passes that checks PHASE_MODE/CONTAINER_MODE directly —
    # every consumer below reads EXEC_ROOT[group_key]/EXEC_BRANCH[group_key]
    # instead (project_roots itself still survives untouched for the four
    # consumers that need it independently of EXEC_ROOT — see that section).
    # ========================================
    EXEC_ROOT = {}    # key: group_key, value: path every git/worktree op targets
    EXEC_BRANCH = {}  # key: group_key, value: branch every git/worktree op targets
    for group_key in project_groups:
        if PHASE_MODE:
            # PHASE_CONTAINER_PATHS[group_key] is populated for every
            # participating group by Create Phase Containers Per Project
            # Group (Step 1.7) in the top-level orchestrator. A Phase-Mode
            # Paired Split sub-orchestrator never runs Step 1.7 — its spawn
            # prompt pre-sets only the scalar PHASE_CONTAINER_PATH to its own
            # split's worktree (see Spawn Split Sub-Orchestrators), so the map
            # is empty there and this falls back to that scalar unchanged.
            EXEC_ROOT[group_key] = PHASE_CONTAINER_PATHS[group_key] if group_key in PHASE_CONTAINER_PATHS else PHASE_CONTAINER_PATH
            EXEC_BRANCH[group_key] = PHASE_BRANCH
        elif CONTAINER_MODE:
            EXEC_ROOT[group_key] = CONTAINER_PATHS[group_key]
            EXEC_BRANCH[group_key] = branchName
        else:
            EXEC_ROOT[group_key] = project_roots[group_key]
            EXEC_BRANCH[group_key] = branchName
    EXEC_OWNS_ROOT = PHASE_MODE or CONTAINER_MODE    # single scalar, not a map
    EXEC_KEEPS_BRANCH = true                         # single scalar; no consumer reads it yet

    # ========================================
    # CAPTURE BASE SHA PER PROJECT GROUP (for commit verification)
    # ========================================
    base_sha = {}  # key: group_key, value: HEAD SHA before worktree creation
    for group_key in project_groups:
        base_sha[group_key] = git -C [EXEC_ROOT[group_key]] rev-parse [EXEC_BRANCH[group_key]]

    # ========================================
    # CREATE WORKTREES PER PROJECT GROUP
    # ========================================
    all_worktrees = {}  # key: full_story.id, value: {worktree_name, worktree_path, group_key}

    for group_key, stories in project_groups:
        worktree_cwd = EXEC_ROOT[group_key]
        worktree_base = EXEC_BRANCH[group_key]

        # PLAN_DISC comes from Multi-Repo Handling's `### Plan Discriminator`,
        # derived once from WAVE_TASKS_FILE above. worktree_base is deliberately
        # NOT redefined: it is read a second time below as `--from [worktree_base]`
        # and must keep naming a branch that really exists, so the discriminator
        # goes into a separate prefix rather than being folded into the base.
        worktree_prefix = PLAN_DISC + "-" + worktree_base

        for full_story in stories:
            # The story id stays LAST. skills/story-executor/SKILL.md requires in
            # two places that the branch an executor finds checked out END in
            # "-<STORY_ID>", and treats a mismatch as a refusal to stage or commit.
            worktree_name = worktree_prefix + "-" + full_story.id

            # cd to this group's execution root (see Execution Context above)
            cd [worktree_cwd]
            create_output = $WORKTREE_MGR create [worktree_name] --from [worktree_base]

            # ========================================
            # READ BOTH CREATE SENTINELS — OR FAIL THE STORY HERE
            # ========================================
            # worktree-manager.sh's create emits two unprefixed lines on BOTH
            # of its branches, fresh creation and silent reuse alike:
            #     WORKTREE_PATH=<absolute path>
            #     WORKTREE_BASE=<full 40-char sha of the new tree's own HEAD>
            # Take the LAST occurrence of each: the fresh-creation branch
            # prints a `cd <path>` hint after them, and everything else create
            # writes is ANSI-coloured progress text carrying neither prefix.
            # The sha is deliberately full-length — an abbreviated one is
            # ambiguous exactly when two bases are close enough to confuse.
            worktree_path = value of the last WORKTREE_PATH= line in create_output
            worktree_base_sha = value of the last WORKTREE_BASE= line in create_output

            # Either sentinel missing is a FAILURE OF THIS STORY, decided
            # BEFORE the executor is spawned. There is no useful recovery
            # after that point: by the time a wrong tree announces itself the
            # work is already written onto it. The usual cause is a
            # worktree-manager.sh predating the sentinels, which is a host
            # problem and not this story's — say so and stop.
            if worktree_path is absent or worktree_base_sha is absent:
                $AIMI_CLI mark-failed [full_story.id] "Worktree create emitted no WORKTREE_PATH/WORKTREE_BASE sentinel" --tasks-file [WAVE_TASKS_FILE]
                $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                Report: "[full_story.id] failed: create printed no WORKTREE_PATH/WORKTREE_BASE (worktree-manager.sh too old?). Dependent stories cascade-skipped."
                drop full_story from full_stories, do not spawn it, continue with the next story

            # ========================================
            # THE TREE MUST STAND ON THE BASE WE ASKED FOR
            # ========================================
            # base_sha[group_key] is this group's EXEC_BRANCH HEAD, captured
            # above before any worktree was cut — the base every story in this
            # wave is meant to stand on. worktree_base_sha is what the tree
            # ACTUALLY stands on. Divergence is a FAILURE, not a warning.
            #
            # Measured, in this repository's own phase 2: a story worktree cut
            # from main instead of from its phase branch announced nothing at
            # creation. It surfaced three levels downstream as a CLI verb
            # answering "Unknown command", a pytest suite short by the phase's
            # own new cases, and a golden file still holding the previous
            # value — three symptoms pointing at three different places, none
            # of them at the base. This comparison is what turns that into one
            # line, before a single file is written.
            #
            # Equality is the fresh-creation case. The one other ACCEPTED
            # shape is a reused worktree that already carries commits of its
            # own: a story that committed and then failed keeps both worktree
            # and branch (see the merge-conflict cleanup below), so a re-run
            # legitimately finds a tree AHEAD of the base. Accept exactly that
            # — base_sha[group_key] reachable from worktree_base_sha — and
            # nothing else. A tree cut from a different branch fails this,
            # which is the whole point; a strict equality test would instead
            # fail every resumed run, and a check that cries wolf on the
            # normal path is a check someone deletes.
            if worktree_base_sha != base_sha[group_key] and not (git -C [worktree_path] merge-base --is-ancestor [base_sha[group_key]] [worktree_base_sha]):
                $AIMI_CLI mark-failed [full_story.id] "Worktree base [worktree_base_sha] does not descend from [base_sha[group_key]]" --tasks-file [WAVE_TASKS_FILE]
                $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                Report: "[full_story.id] failed: worktree stands on [worktree_base_sha], expected [EXEC_BRANCH[group_key]] at [base_sha[group_key]]. Dependent stories cascade-skipped."
                drop full_story from full_stories, do not spawn it, continue with the next story

            all_worktrees[full_story.id] = {
                worktree_name: worktree_name,
                worktree_path: worktree_path,
                worktree_base_sha: worktree_base_sha,
                group_key: group_key
            }

    # Spawn ALL workers as foreground Tasks in a SINGLE tool-call turn.
    # Claude Code runs multiple foreground Tasks concurrently and returns
    # all results before the agent's turn ends.
    #
    # IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
    #
    # Template selection: full for first story in session, compact for subsequent.
    # In a multi-story wave, the first story uses full_template only if is_first_story_in_session
    # is true; all others in the wave use compact_template.
    # In one tool-call turn, emit N Task calls (across ALL project groups):
    story_index = 0
    for full_story in full_stories:
        wt = all_worktrees[full_story.id]
        project_path = project_roots[wt.group_key] if wt.group_key != "DEFAULT" else null
        project_guidelines = PROJECT_GUIDELINES_MAP[wt.group_key] if wt.group_key != "DEFAULT" else PROJECT_GUIDELINES

        template = full_template if (is_first_story_in_session and story_index == 0) else compact_template

        Task(
            subagent_type: "general-purpose",
            model: <AGENT_MODELS.executor when not "inherit">,
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md [template] with:
                - WORKTREE_PATH = wt.worktree_path
                - PROJECT_PATH = project_path (only include if non-null)
                - PROJECT_GUIDELINES = project_guidelines
                - HEADED_MODE = (do NOT include for worktree stories — visual verification runs post-merge, not inside the worktree)
                - Omit the <visual_verification> section entirely for worktree stories
                  (the dev server cannot see worktree changes; verification runs after merge-all instead)
                - STORY_ID = full_story.id  ← only the id; no description, no criteria, no prototype HTML
                - TASKS_FILE_PATH = WAVE_TASKS_FILE  ← this wave's own resolved tasks file. The
                  story-executor SKILL.md <task_pointer> template substitutes TASKS_FILE_PATH onto
                  its own get-story-context call, so the spawned executor reads this orchestrator's
                  file even when a sibling split orchestrator's init-session call last wrote the
                  shared pointer
                - AIMI_ROOT = this run's already-resolved AIMI_ROOT (the directory holding `.aimi/`)
                  ← passed in, never re-derived inside a worktree, which has no `.aimi/` of its own;
                  the executor exports it beside TASKS_FILE_PATH for both verify runs
                - SCRATCH_PREFIX = PLAN_DISC + "-" + full_story.id  ← the executor's scratchpad
                  namespace, handed over ALREADY COMPOSED rather than left to be chosen. `PLAN_DISC`
                  is READ here and never recomposed nor re-sanitized: `### Plan Discriminator` under
                  Multi-Repo Handling derived it once from WAVE_TASKS_FILE, its sanitization is
                  load-bearing (`validate_branch_name` refuses a single dot), and a second derivation
                  is only a second chance to disagree with the first.
                  The axis is the PLAN and the story id comes SECOND, which is why that order is
                  not arbitrary. The collision measured on 2026-09-08 was not
                  sibling-against-sibling: a `verify-US-002.sh` left in the shared scratchpad by an
                  EARLIER plan's run was read by this run's US-002, whose id happened to be the same
                  string. A prefix keyed on the story id alone composes the identical name for both
                  and would have separated nothing — only the plan's own identity does.
                - Do NOT modify the tasks.json file — report result (success/failure + details)
            ]
        )
        story_index += 1

    is_first_story_in_session = false

    # All Tasks return in the same turn. Collect results.
    failed_stories = []
    succeeded_stories = []
    result_payload_by_id = {}  # full_story.id → parsed result_json object

    # ========================================
    # PARSE WORKER RESULT_JSON BLOCK (per story-executor SKILL.md Result Contract)
    # ========================================
    # The orchestrator's source of truth is the <result_json>...</result_json>
    # block at the END of each worker's final message. Prose outside the block
    # is debugging only and is NOT consumed here.
    #
    # Extraction rule (regex): the LAST occurrence in the message of
    #   <result_json>\s*({.*?})\s*</result_json>   (DOTALL, non-greedy)
    # is parsed as JSON. If the block is malformed, missing, or fails to parse,
    # fall back to the legacy heuristic: Task's own exit signal (succeeded/failed)
    # + commit verification below.
    #
    # Reading the structured block keeps the next orchestrator turn's input
    # token cost down — empirically a worker returns ~600 tokens of prose where
    # the orchestrator only consumes ~50-200 tokens of structured signal.

    for each Task result:
        payload = parse_result_json(Task.final_message_text)  # see extraction rule above
        if payload is not None:
            result_payload_by_id[full_story.id] = payload
            status = payload.get("status")
            if status == "ok":
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)
        else:
            # Legacy fallback: trust Task's own success/failure signal.
            # Log: "[full_story.id] missing or malformed <result_json> — falling back to Task exit signal"
            if Task succeeded:
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)

    # --- Post-Wave Processing ---

    # ========================================
    # STALLED EXECUTOR DETECTION — the executor that went idle
    # ========================================
    # This happened for real, twice in phase 1 of this feature: a spawned
    # executor finished its work, ran its own verify suite, and went idle
    # without ever emitting <result_json> and without running `git commit`.
    # Both times the only way it surfaced was the orchestrator going and
    # looking at `ps` / the agent roster by hand — nothing in this loop told
    # anyone to. The fallback above (missing or malformed <result_json> —
    # falling back to Task exit signal) presupposes the Task returned with
    # SOMETHING usable; a stalled executor's Task call still returns in this
    # same turn (every Task here is foreground — see "Spawn ALL workers"
    # above), but its own exit signal says nothing about whether real work
    # got left behind uncommitted, because it never looked.
    #
    # No clock, no liveness probe of the agent — this crosses three facts
    # the loop already captures for every story with no valid result_json:
    #   1. missing or malformed result_json (payload is None, from the loop above)
    #   2. HEAD in the worktree is unchanged from base_sha (no commit landed)
    #   3. the worktree is dirty (the executor wrote SOMETHING before going idle)
    # All three together is a stalled story. Any one of them alone is not:
    # (1) alone is the existing fallback, untouched, trusting Task's own
    # signal; (2)+(3) without (1) is the ordinary ok-but-no-commit case the
    # COMMIT VERIFICATION step below already walks through result_payload_by_id.
    #
    # Detection runs over EVERY story with no result_json, whichever bucket
    # the fallback above placed it in — a stalled executor's own Task exit
    # signal can read as a success (nothing errored, it just never reported)
    # or as a failure (it ran out of turns going idle), and the fallback has
    # no way to tell those apart. A stalled story found sitting in
    # failed_stories is moved into succeeded_stories so it reaches the SAME
    # commit-verification / commit-rescue pass below as every other
    # no-commit story — this never adds a third resolution path, it only
    # widens which stories reach the two that already exist.
    stalled_story_ids = []
    for full_story in (succeeded_stories + failed_stories):
        if result_payload_by_id.get(full_story.id) is not None:
            continue    # Task returned a valid block — not this case
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        tree_is_dirty = (`git -C [wt.worktree_path] status --porcelain` output is non-empty)
        if worktree_head == base_sha[wt.group_key] and tree_is_dirty:
            stalled_story_ids.append(full_story.id)
            if full_story in failed_stories:
                failed_stories.remove(full_story)
                succeeded_stories.append(full_story)
            Report: "[full_story.id] stalled — executor went idle without <result_json> and without committing (dirty tree, no new commit). Routing through commit verification / commit rescue below."

    # ========================================
    # COMMIT VERIFICATION (parallel path)
    # ========================================
    # Prefer the commit SHA from result_payload_by_id[full_story.id].commit when
    # present and non-null — cross-check it against git rev-parse HEAD in the
    # worktree. Mismatch → treat as no-commit (worker lied or aborted post-emit).
    # When result_json is absent, fall back to the legacy "HEAD differs from
    # base_sha" check unchanged.
    no_commit_stories = []
    verified_stories = []
    for full_story in succeeded_stories:
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        payload = result_payload_by_id.get(full_story.id)

        if payload is not None and payload.get("commit"):
            # Cross-check declared SHA against actual HEAD (short-SHA prefix match OK)
            declared = payload["commit"]
            if not worktree_head.startswith(declared) and declared != worktree_head:
                # Declared commit not at HEAD — treat as no-commit
                no_commit_stories.append(full_story)
                continue

        if worktree_head == base_sha[wt.group_key]:
            no_commit_stories.append(full_story)
        else:
            verified_stories.append(full_story)

    # ========================================
    # COMMIT RESCUE — BEFORE mark-failed, AND ONLY ON THE SUBSET
    # ========================================
    # A story that reached here reported ok and left a dirty tree with no
    # commit on it. That is a mechanics defect, not a bad story: the work
    # exists and the only thing missing is the `git commit` the executor owed.
    # Failing it discards a finished implementation and cascade-skips
    # everything downstream of it, which is a far larger loss than the defect.
    # This happened for real — a story in this very phase finished its work
    # and returned without committing.
    #
    # THE SUBSET IS THE GUARD, and it is the only thing making this safe to do
    # on someone else's behalf. `implementation.files` is what the planner said
    # this story would touch. When every modified path is inside that list, the
    # orchestrator knows exactly what it is committing and to which story it
    # belongs. One path outside the list means the tree holds something nobody
    # declared — a stray edit, a half-finished second concern, another story's
    # leftovers — and the orchestrator has no basis to attribute it. That case
    # takes the unchanged failure flow below; it is never rescued, never
    # partially staged, and never trimmed down to the declared subset to make
    # it fit.
    rescued_stories = []
    for full_story in no_commit_stories:
        wt = all_worktrees[full_story.id]
        pre_rescue_head = git -C [wt.worktree_path] rev-parse HEAD

        # 1. Is there anything to rescue? A clean tree means the executor wrote
        #    nothing at all; the failure is real and stands.
        dirty_paths = paths from `git -C [wt.worktree_path] status --porcelain`
                      (both sides of a rename count as modified paths)
        if dirty_paths is empty:
            continue    # falls through to the failure flow below

        # 2. The subset guard. `implementation.files` comes from the CLI, not
        #    from a raw read of the tasks file — get-story-context is the same
        #    verb the executor itself bootstraps with, so orchestrator and
        #    worker read one document through one reader.
        declared_files = $AIMI_CLI get-story-context [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                         → .story.implementation.files
        # `implementation` is optional in schema v3.3. Absent or empty declares
        # nothing, so nothing can be inside it — no list, no rescue. Do not
        # read an absent list as "anything is allowed"; that inverts the guard.
        if declared_files is absent or empty:
            continue    # falls through to the failure flow below
        if any path in dirty_paths is not in declared_files:
            Report: "[full_story.id] not rescued — modified files outside implementation.files: [the offending paths]"
            continue    # falls through to the failure flow below

        # 3. Subset holds. Commit on the executor's behalf, staging the
        #    modified declared paths BY NAME — never `-A`, never `.`, the same
        #    rule the story executor itself follows.
        cd [wt.worktree_path]
        git add [each path in dirty_paths]
        git commit -m "feat([full_story.id]): [full_story.title]" -m "Committed by the wave orchestrator: the executor finished the work and returned without committing it."

        # 4. Trust the tree, not the exit code — a pre-commit hook can refuse
        #    after `git commit` has already printed. If HEAD did not move, the
        #    rescue did not happen and the story takes the failure flow.
        rescued_head = git -C [wt.worktree_path] rev-parse HEAD
        if rescued_head == pre_rescue_head:
            Report: "[full_story.id] not rescued — the rescue commit did not land (hook refused?)"
            continue    # falls through to the failure flow below

        rescued_stories.append(full_story)
        stalled_note = " (stalled executor — resolved by commit rescue)" if full_story.id in stalled_story_ids else ""
        Report: "[full_story.id] rescued[stalled_note] — executor left [len(dirty_paths)] modified file(s), all inside implementation.files; committed as [rescued_head]:"
        Report: git -C [wt.worktree_path] show --stat --format= [rescued_head]

    # Move the stories that were NOT rescued to failed
    for full_story in no_commit_stories and not in rescued_stories:
        $AIMI_CLI mark-failed [full_story.id] "No commit detected after execution" --tasks-file [WAVE_TASKS_FILE]
        $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
        stalled_note = " (stalled executor — resolved by mark-failed + cascade-skip)" if full_story.id in stalled_story_ids else ""
        Report: "[full_story.id] failed (no commit detected)[stalled_note]. Dependent stories cascade-skipped."

    # Replace succeeded_stories with the ones carrying a commit — verified by
    # the worker itself, or rescued above. A rescued story is a SUCCESS from
    # here on: it merges with the wave and reaches mark-complete like any
    # other, because its work is on its branch exactly as if the executor had
    # committed it. The rescue is reported so the human sees the diff someone
    # else committed; it is not tracked as a separate story state.
    succeeded_stories = verified_stories + rescued_stories

    # Handle failures first
    for full_story in failed_stories:
        # Prefer the structured failureCause over generic message when available
        payload = result_payload_by_id.get(full_story.id)
        cause = (payload.get("failureCause") if payload else None) or "Failed during parallel wave [wave]"
        # Static triage of the verify text, read-only; the dynamic verify-probe
        # unsatisfiable result stays authoritative, so report both and prefer
        # the dynamic one. A triage error never blocks mark-failed.
        triage = $AIMI_CLI triage-verify [full_story.id] --tasks-file [WAVE_TASKS_FILE]   # on error: triage = {findings: []}
        notes = cause + ("; static triage: [finding.detector] [finding.message]" for each triage.findings)
        $AIMI_CLI mark-failed [full_story.id] "[notes]" --tasks-file [WAVE_TASKS_FILE]
        $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
        Report: "[full_story.id] failed: [notes]. Dependent stories cascade-skipped."

    # ========================================
    # MERGE PER PROJECT GROUP (not across repos)
    # ========================================
    # Merge successful worktrees grouped by project.
    # Each project group merges independently into its own repo's branch.

    if len(succeeded_stories) > 0:
        # Group succeeded stories by project
        succeeded_by_project = {}
        for full_story in succeeded_stories:
            group_key = all_worktrees[full_story.id].group_key
            succeeded_by_project[group_key].append(full_story)

        for group_key, stories in succeeded_by_project:
            merge_cwd = EXEC_ROOT[group_key]
            merge_target = EXEC_BRANCH[group_key]
            succeeded_worktree_names = [all_worktrees[s.id].worktree_name for s in stories]

            # cd to this group's execution root before merging (see container-
            # execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
            # EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) -- merge-all issues a bare
            # `git checkout <target-branch>` against whatever repo its CWD belongs
            # to, so running it from AIMI_ROOT in phase mode would check the phase
            # branch out onto the main working tree, violating the Main Working
            # Tree Untouched Invariant.
            cd [merge_cwd]
            merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] --into [merge_target]

            if merge conflict (non-zero exit):
                Report:
                "MERGE CONFLICT during wave [wave] merge in project [group_key]."
                "Conflicting files:"
                "[conflict output from merge-all]"
                ""
                "Resolve the conflict on branch [merge_target] in [merge_cwd] and re-run `/aimi:execute` to continue."
                "[merge_cwd] itself — this group's execution root, whichever mode created it — and any live dev server running inside it are left untouched by this failure, so the conflict can be resolved directly in the still-live working tree."
                "Merged story worktrees were removed; the ones that did NOT merge keep both their worktree and their branch, so the retry has something to retry."

                # Cleanup this wave's worktrees -- but ONLY the ones whose work
                # is already reachable from the merge target. merge_all_worktrees
                # processes its argv in order and stops at the first conflict
                # without attempting the rest, so a story from the conflicting
                # one onward has NOT been merged: removing it without
                # --keep-branch would run `git branch -D` on the only ref naming
                # its commits, stranding them. This is the same rule the
                # Phase-Mode Paired Split conflict path already applies to its
                # own members (see "Merge Split Branches Into the Phase Branch"),
                # and the two must not disagree about the same scenario.
                for full_story_id, wt in all_worktrees:
                    cd EXEC_ROOT[wt.group_key]
                    if git -C [EXEC_ROOT[wt.group_key]] merge-base --is-ancestor [wt.worktree_name] [EXEC_BRANCH[wt.group_key]]:
                        # Merged: its commits live on the target branch, so the
                        # branch ref has no remaining consumer.
                        $WORKTREE_MGR remove [wt.worktree_name]
                    else:
                        # Unmerged -- the conflicting story, anything after it
                        # merge-all never reached, and every story that failed
                        # earlier in this wave. Leave the worktree AND the branch
                        # in place; report the branch so the user can find it.
                        Report: "  kept (unmerged): [wt.worktree_name]"

                # PHASE_MODE with PHASE_ID set (this session itself ran Step 1.7 --
                # never true inside a Phase-Mode Paired Split sub-orchestrator):
                # release the claim before stopping (see Release the Claim on Abort).
                if PHASE_MODE and PHASE_ID is set:
                    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"

                STOP execution.

            # Merges succeeded for this project group — mark stories complete
            for full_story in stories:
                # --- Extract knownGaps: prefer result_json.knownGaps, fall back to commit trailers ---
                # When result_payload_by_id[full_story.id].knownGaps is a non-empty array,
                # use those entries (one line each). Otherwise, fall back to grepping
                # KNOWN-GAP trailers from the commit body for backward compat. Two spellings
                # are matched -- bare "KNOWN-GAP:" and "KNOWN-GAP (US-NNN):" with the story id
                # folded in -- because a worker legitimately writes either one, and a
                # single-spelling grep silently drops whichever it does not cover. Both stay
                # anchored to line start so a KNOWN-GAP mention inside a paragraph is never
                # extracted as if it were a trailer.
                ```bash
                mkdir -p .aimi/known-gaps
                # Pseudo: prefer payload; fall back to commit grep
                payload_gaps="${result_payload_by_id[full_story.id].knownGaps or []}"
                if [ -n "$payload_gaps" ] && [ "$payload_gaps" != "[]" ]; then
                  WORKER_GAPS=$(printf '%s\n' "$payload_gaps")
                else
                  WORKER_GAPS=$(git -C "[all_worktrees[full_story.id].worktree_path]" log -1 --format=%B | grep -E '^KNOWN-GAP( \([^)]+\))?:' || true)
                fi
                # Discriminated by PLAN_DISC, this run's own plan identity (see
                # `### Plan Discriminator` under Multi-Repo Handling) — two plans
                # that both produce a gap for the same story id on the same day
                # would otherwise compose the same path and silently truncate
                # each other's finding.
                if [ -n "$WORKER_GAPS" ]; then
                  GAP_DATE=$(date +%Y-%m-%d)
                  GAP_FILE=".aimi/known-gaps/${GAP_DATE}-[full_story.id]-[PLAN_DISC].md"
                  printf '%s\n' "$WORKER_GAPS" > "$GAP_FILE"
                fi
                # --- Extract verify evidence: the FOURTH result_json field this
                # command consumes, beside .commit, .failureCause and .knownGaps ---
                # The story-executor Result Contract carries `verify`
                # ({exit, preExit, segments, discriminating}) — the count of verify
                # segments that behaved differently before the story's work than
                # after. Empty here is a real answer and a common one: an executor
                # whose payload predates that contract, a payload recovered by the
                # fallback parse rather than read as JSON, or a story whose verify
                # never ran. It is NOT the same as a zeroed evidence object, and the
                # call below is written so the two can never collapse into each other.
                VERIFY_EVIDENCE_JSON="${result_payload_by_id[full_story.id].verify or ''}"
                ```

                $AIMI_CLI mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE] --evidence "$VERIFY_EVIDENCE_JSON"

                # Pass `--evidence` ONLY when `VERIFY_EVIDENCE_JSON` is non-empty. When it is empty the flag is omitted ENTIRELY — the call is exactly `mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE]`, never `--evidence ""`, never `--evidence {}`, and never `--verify-evidence`: the flag is spelled `--evidence` and `cmd_mark_complete` parses no other spelling, so a `--verify-evidence` reached for on the strength of the variable name falls through to the positional parser and is read as a second story id.
                # Two reasons the flagless argv has to stay byte-identical rather than
                # gaining an always-passed empty flag. It is the argv the pre-existing
                # golden `mark-complete` recordings replay, so a flag that is always
                # present rewrites all of them for nothing. And an empty evidence object
                # would persist at `verification.evidence` as "we looked and found
                # nothing" — precisely the conflation this reporting exists to remove:
                # `tasks.py`'s `_report_discriminating` routes a missing count to
                # `unrecorded` and a real 0 to `blind`, and those are two different
                # statements about the same run.

                # --- Post-merge visual verification for visual stories ---
                # Session lifecycle: see Visual Follow Lifecycle section.
                # Capture sequence per story (when agent-browser is available):
                #   1. console --clear  ← drop logs accumulated from PRIOR story in this wave
                #   2. open <url>       ← navigate
                #   3. screenshot       ← visual snapshot
                #   4. console --json   ← capture this story's console output
                #   5. errors  --json   ← capture this story's uncaught exceptions
                # Per-story attribution depends on the --clear in step 1 — without it,
                # console buffer is wave-cumulative and last-story-merged eats the blame.
                if full_story.verification and full_story.verification.strategy == "visual" and full_story.verification.status == "pending":
                    # --- Post-merge visual verification origin rewrite / degradation gate ---
                    # `group_key` is already in scope here from the enclosing "for
                    # group_key, stories in succeeded_by_project" loop above — this
                    # story's own project group. Discriminates on EXEC_OWNS_ROOT (see
                    # container-execution.md's Execution Context: EXEC_ROOT,
                    # EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) rather
                    # than checking PHASE_MODE/CONTAINER_MODE separately at this top
                    # level: false only for inline mode (no shared server exists to
                    # rewrite against), true for both phase and container mode, which
                    # keep their own distinct port-acquisition mechanisms below.
                    SKIP_VISUAL=false
                    if not EXEC_OWNS_ROOT:
                        # Inline mode — identical to today's inline branch: the
                        # story's own verification.url, no rewrite, no gate.
                        # verification-report already normalizes a non-string
                        # url to the empty string, so no `// empty` is needed
                        # here — see the closed jq -r non-string hazard note
                        # above Container Dev Server Bootstrap.
                        STORY_TASKS_FILE="$TASKS_PATH"
                        STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
                        EFFECTIVE_URL="$STORY_VERIFICATION_URL"
                    else:
                        # EXEC_OWNS_ROOT is true for both phase and container mode.
                        # PHASE_MODE is read here too, but only to pick between the
                        # two modes' own distinct port-acquisition mechanisms — never
                        # again as a top-level EXEC_ROOT/EXEC_BRANCH mode gate.
                        if PHASE_MODE:
                            # Apply container-execution.md's § Rewrite a Verification
                            # URL Origin with EXEC_ROOT="$AIMI_ROOT", EXEC_BRANCH=
                            # "$PHASE_BRANCH" — never a value cached from Phase/Split
                            # Container Dev Server Bootstrap or Step 3.3 earlier in
                            # this run. Inside a split sub-orchestrator, PHASE_BRANCH
                            # is already that split's own branch (see Spawn Split
                            # Sub-Orchestrators), so this applies unmodified one level
                            # deeper too.
                            ```bash
                            WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                            : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
                            cd "$AIMI_ROOT"
                            STORY_TASKS_FILE="$PHASE_TASKS_PATH"
                            STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
                            SERVE_URL_JSON=$($WORKTREE_MGR serve url "$PHASE_BRANCH" "$STORY_VERIFICATION_URL")
                            REWRITTEN=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.rewritten')
                            EFFECTIVE_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
                            ```
                            if REWRITTEN != "true":
                                # No dev server running for this phase's (or split's) own
                                # branch. Degrade to skipped — this is also the expected,
                                # non-bug outcome for a full-stack split story whose page
                                # depends on the sibling split's API (no proxy exists between
                                # the two split servers — see Split Container Dev Server
                                # Bootstrap). mark-complete already ran above; this never
                                # blocks it, never blocks the wave, and never retries.
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server running for [PHASE_BRANCH]" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — no dev server running for [PHASE_BRANCH]."
                                SKIP_VISUAL=true
                        else:
                            # CONTAINER_MODE — EXEC_OWNS_ROOT is true and PHASE_MODE is
                            # false, so this is the only remaining case. Gates on the
                            # Step 3.3 cache before applying container-execution.md's
                            # § Rewrite a Verification URL Origin, keyed by this story's
                            # own project group.
                            if group_key not in CONTAINER_DEV_URL:
                                # No dev server ever resolved a port for this group (see Container
                                # Dev Server Bootstrap in Step 3.3) — degrade to skipped. mark-complete
                                # already ran above; this never blocks it or the wave loop.
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server resolved for project group [group_key]" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — no dev server resolved for project group [group_key]."
                                SKIP_VISUAL=true
                            else:
                                ```bash
                                WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                                : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
                                BRANCH_NAME=$(jq -r '.metadata.branchName' "$TASKS_PATH")
                                if [ "[group_key]" = "DEFAULT" ]; then
                                  cd "$AIMI_ROOT"
                                else
                                  cd "$AIMI_ROOT/[group_key]"
                                fi
                                STORY_TASKS_FILE="$TASKS_PATH"
                                STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
                                SERVE_URL_JSON=$($WORKTREE_MGR serve url "$BRANCH_NAME" "$STORY_VERIFICATION_URL")
                                EFFECTIVE_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
                                ```

                    if not SKIP_VISUAL:

                        if VISUAL_FOLLOW == true:
                            # Reuse the existing headed session (managed by execute.md)
                            agent-browser --session visual-follow console --clear
                            agent-browser --session visual-follow open [EFFECTIVE_URL]
                            agent-browser --session visual-follow screenshot /tmp/verify-[full_story.id].png
                            CONSOLE_JSON=$(agent-browser --session visual-follow console --json)
                            ERRORS_JSON=$(agent-browser --session visual-follow errors --json)
                            # Read screenshot and compare against full_story.verification.expect
                            Read /tmp/verify-[full_story.id].png
                            Compare visual output against full_story.verification.expect

                            # Run console attribution pass (see "Console Error Attribution" section below)
                            ATTRIBUTION = attribute_console_errors(
                                console_json=CONSOLE_JSON,
                                errors_json=ERRORS_JSON,
                                wave_stories=succeeded_stories
                            )

                            if visual matches expectations:
                                $AIMI_CLI set-verification [full_story.id] passed --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification passed."
                            else:
                                $AIMI_CLI set-verification [full_story.id] failed --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification failed — [reason]. (advisory, not blocking)"

                            # Report attribution lines as advisory (do NOT toggle verification.status)
                            if ATTRIBUTION.has_errors:
                                Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                # Push attribution into wave-level CONSOLE_BUFFER for the wave summary
                                CONSOLE_BUFFER[full_story.id] = ATTRIBUTION
                        else:
                            # No visual-follow session — headless verification
                            has_browser = command -v agent-browser
                            if has_browser:
                                agent-browser console --clear
                                agent-browser open [EFFECTIVE_URL]
                                agent-browser screenshot /tmp/verify-[full_story.id].png
                                CONSOLE_JSON=$(agent-browser console --json)
                                ERRORS_JSON=$(agent-browser errors --json)
                                Read /tmp/verify-[full_story.id].png
                                Compare visual output against full_story.verification.expect

                                ATTRIBUTION = attribute_console_errors(
                                    console_json=CONSOLE_JSON,
                                    errors_json=ERRORS_JSON,
                                    wave_stories=succeeded_stories
                                )

                                if visual matches expectations:
                                    $AIMI_CLI set-verification [full_story.id] passed --tasks-file [WAVE_TASKS_FILE]
                                else:
                                    $AIMI_CLI set-verification [full_story.id] failed --tasks-file [WAVE_TASKS_FILE]
                                    Report: "[full_story.id] visual verification failed — [reason]. (advisory)"

                                if ATTRIBUTION.has_errors:
                                    Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                    CONSOLE_BUFFER[full_story.id] = ATTRIBUTION

                                agent-browser close
                            else:
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "agent-browser not installed" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — agent-browser not installed."

                # Non-visual stories: the verdict now comes from the verify evidence
                # mark-complete already persisted above (see VERIFY_EVIDENCE_JSON) —
                # a blanket rewrite to "passed" here claimed success whether or not
                # this story's own check ever ran, which is exactly the dishonesty
                # judge-verification exists to close. It is a safe no-op (writes
                # nothing, reports why) for a story already judged, so the pending
                # check below is an optimization, not a correctness requirement.
                elif full_story.verification and full_story.verification.status == "pending":
                    $AIMI_CLI judge-verification [full_story.id] --tasks-file [WAVE_TASKS_FILE]

                Report: "[full_story.id] merged successfully."

                # --- Design Review (visual stories only) ---
                if full_story.verification and full_story.verification.strategy == "visual" and (metadata.prototypePaths is non-empty or full_story.implementation.prototypeAnchor is non-empty):
                    # 1. Resolve prototype path: prefer prototypeAnchor, fall back to metadata.prototypePaths[0]
                    REVIEW_PROTOTYPE_PATH = full_story.implementation.prototypeAnchor
                    if REVIEW_PROTOTYPE_PATH is empty:
                        REVIEW_PROTOTYPE_PATH = metadata.prototypePaths[0] (if the array is non-empty)

                    if REVIEW_PROTOTYPE_PATH is empty:
                        Report: "Design review skipped for [full_story.id] — no prototype available."
                    else:
                        # 2. Collect changed files from the worker's commit
                        ```bash
                        DESIGN_REVIEW_CHANGED_FILES=$(git -C "[all_worktrees[full_story.id].worktree_path]" show --name-only --pretty=format: HEAD | grep -v '^$')
                        ```

                        # 3. Spawn the reviewer in foreground (capture output)
                        DESIGN_REVIEW_OUTPUT = Task(
                            subagent_type: "aimi-engineering:design:aimi-design-implementation-reviewer",
                            model: <AGENT_MODELS.design when not "inherit">,
                            description: "Design review: [full_story.id]",
                            prompt: "Review the implementation of [full_story.id] ([full_story.title]).

Prototype: [REVIEW_PROTOTYPE_PATH]
Changed files:
[DESIGN_REVIEW_CHANGED_FILES]
Worktree: [all_worktrees[full_story.id].worktree_path]

Read the prototype file at the path above. Compare each visual element of the prototype against the changed files listed. Report PASS / DIVERGES / KNOWN-GAP verdicts with a brief diagnosis per element.

Output your full structured review under the heading '## Design Implementation Review'."
                        )

                        # 4. Store per-story buffer for Step 5 aggregation
                        DESIGN_REVIEW_BUFFERS[full_story.id] = {
                            title: full_story.title,
                            output: DESIGN_REVIEW_OUTPUT
                        }

                # Post-completion gate logging
                if full_story.gate:
                    if full_story.gate.type == "action" and full_story.gate.status == "pending":
                        Report: "Action required for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents will wait until gate is resolved."
                    if full_story.gate.type == "verify" and full_story.gate.status == "pending":
                        Report: "Verification pending for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents proceed immediately (non-blocking)."

    # Remove all worktrees from this wave (per project group, EXEC_ROOT[wt.group_key]
    # — see container-execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
    # EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH). Branch deletion
    # here is unconditional in every mode (no --keep-branch) — container mode's
    # own teardown (outline:08) is the only removal call that preserves branchName.
    for full_story_id, wt in all_worktrees:
        cd EXEC_ROOT[wt.group_key]
        $WORKTREE_MGR remove [wt.worktree_name]

    # Count gate statuses for wave summary
    action_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "action" and s.gate.status == "pending"]
    verify_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "verify" and s.gate.status == "pending"]

    wave_summary = "Wave [wave] complete: [len(succeeded_stories)] succeeded, [len(failed_stories)] failed"
    if len(action_gates) > 0:
        wave_summary += ", [len(action_gates)] action gate(s) pending"
    if len(verify_gates) > 0:
        wave_summary += ", [len(verify_gates)] verify gate(s) pending"
    Report: wave_summary
    wave += 1
```

