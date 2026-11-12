# Execute: Step 4: Wave Execution Loop

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 4: Wave Execution Loop

```
wave = 1
DESIGN_REVIEW_BUFFERS = {}  # key: story_id, value: {title, output}; populated by post-merge design reviewer
CONSOLE_BUFFER = {}         # key: story_id, value: ATTRIBUTION object; populated by post-merge console capture (see Console Error Attribution section)

# WAVE_TASKS_FILE — this run's own tasks file (PHASE_TASKS_PATH in phase mode, else TASKS_PATH,
# both already resolved here, a split sub-orchestrator's included). Every CLI call in this
# loop passes it as --tasks-file, never the shared current-tasks pointer.
WAVE_TASKS_FILE = PHASE_TASKS_PATH if PHASE_MODE else TASKS_PATH

# PLAN_DISC — this run's own plan identity, the sanitized stem of the file
# above. Derived by the block in Multi-Repo Handling's `### Plan Discriminator`;
# run that block in the Bash call that needs the value and read it back from
# the PLAN_DISC= line it echoes, since every Bash call is an isolated shell.
PLAN_DISC = sanitized stem of WAVE_TASKS_FILE

# EXECUTOR_BRIEF — absolute path of the story-executor skill, the worker's whole
# brief. Resolve it once, in a Bash call that already resolved $AIMI_CLI, and
# read it back from the line it echoes (the skill sits beside the CLI that runs
# this session, on both hosts and under AIMI_DEV_DIR alike):
#   B="$(cd "$(dirname "$AIMI_CLI")/.." && pwd)/skills/story-executor/SKILL.md"; [ -f "$B" ] && echo "EXECUTOR_BRIEF=$B" || echo "EXECUTOR_BRIEF_MISSING=$B"
# On EXECUTOR_BRIEF_MISSING, stop and report: never spawn a worker without its brief.
EXECUTOR_BRIEF = path echoed above

# metadata — this run's tasks-file metadata, read once; the post-merge design
# review reads its `prototypePaths`.
metadata = $AIMI_CLI metadata --tasks-file [WAVE_TASKS_FILE]

while true:
    # ========================================
    # RE-POINT THE CLI — TOP OF THE WAVE, NEVER MID-WAVE
    # ========================================
    # Step 0 resolved $AIMI_CLI once; a cleanup-versions in another session can prune that
    # path mid-run. Re-point here, between the last merge of a wave and the next spawn, where
    # nothing is in flight; never mid-wave, and never move this call. Later Bash calls re-read
    # the cache --fix rewrites. Read `status`, not only the exit code: `unknown` exits 0 and
    # means no plugin is installed.
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
            # `status` rows carry no `gate`: take the ids from `status`, then each
            # story's gate from `get-story`, in ONE Bash call — the same loop
            # Step 5's gate summary runs, with `{id, status, dependsOn, gate}`
            # printed for every story rather than pending gates only.
            all_stories = $AIMI_CLI status --tasks-file [WAVE_TASKS_FILE], each row joined with its gate from get-story
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
    # DERIVE EXEC_ROOT / EXEC_BRANCH PER PROJECT GROUP — see container-execution.md's
    # Execution Context. The only PHASE_MODE/CONTAINER_MODE check in the loop; every
    # consumer below reads EXEC_ROOT[group_key]/EXEC_BRANCH[group_key].
    # ========================================
    EXEC_ROOT = {}    # key: group_key, value: path every git/worktree op targets
    EXEC_BRANCH = {}  # key: group_key, value: branch every git/worktree op targets
    for group_key in project_groups:
        if PHASE_MODE:
            # PHASE_CONTAINER_PATHS comes from Step 1.7; a Phase-Mode Paired Split sub-orchestrator
            # never runs it, so its map is empty and the scalar PHASE_CONTAINER_PATH is used.
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

        # worktree_base keeps naming a real branch (it is read again as --from), so the plan
        # discriminator goes into a separate prefix.
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
            # create prints WORKTREE_PATH=<absolute path> and WORKTREE_BASE=<full sha of the new
            # tree's HEAD> on both fresh creation and reuse; take the LAST occurrence of each.
            worktree_path = value of the last WORKTREE_PATH= line in create_output
            worktree_base_sha = value of the last WORKTREE_BASE= line in create_output

            # Either sentinel missing fails THIS story before it is spawned (the usual cause is a
            # worktree-manager.sh older than the sentinels).
            if worktree_path is absent or worktree_base_sha is absent:
                $AIMI_CLI mark-failed [full_story.id] "Worktree create emitted no WORKTREE_PATH/WORKTREE_BASE sentinel" --tasks-file [WAVE_TASKS_FILE]
                $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                Report: "[full_story.id] failed: create printed no WORKTREE_PATH/WORKTREE_BASE (worktree-manager.sh too old?). Dependent stories cascade-skipped."
                drop full_story from full_stories, do not spawn it, continue with the next story

            # ========================================
            # THE TREE MUST STAND ON THE BASE WE ASKED FOR
            # ========================================
            # base_sha[group_key] is the base every story in this wave must stand on. Accept the tree
            # when its base equals it or descends from it (a resumed story's reused worktree may be
            # ahead of it); fail the story on anything else, never warn.
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
    # The prompt is a POINTER, never a copy: the worker reads EXECUTOR_BRIEF itself.
    # Do not paste, summarize or paraphrase the skill into the prompt — a pasted
    # copy is what drifted before, and a paraphrase drops rules.
    # In one tool-call turn, emit N Task calls (across ALL project groups):
    for full_story in full_stories:
        wt = all_worktrees[full_story.id]
        project_path = project_roots[wt.group_key] if wt.group_key != "DEFAULT" else null
        project_guidelines = PROJECT_GUIDELINES_MAP[wt.group_key] if wt.group_key != "DEFAULT" else PROJECT_GUIDELINES

        Task(
            subagent_type: "general-purpose",
            model: <AGENT_MODELS.executor when not "inherit">,
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: exactly this text, one "NAME: value" line per field below, nothing else:
                "You are a story worker for aimi-engineering. Before any other action, read
                 [EXECUTOR_BRIEF] in full with the Read tool and follow it exactly: it is your
                 whole brief, and the values below are its inputs."
              with:
                - STORY_ID = full_story.id  ← only the id; no description, no criteria, no prototype HTML
                - TASKS_FILE_PATH = WAVE_TASKS_FILE  ← this wave's own file, never the shared pointer
                - AIMI_ROOT = this run's already-resolved AIMI_ROOT (the directory holding `.aimi/`)
                  ← passed in, never re-derived inside a worktree, which has no `.aimi/` of its own;
                  the executor exports it beside TASKS_FILE_PATH for both verify runs
                - SCRATCH_PREFIX = PLAN_DISC + "-" + full_story.id  ← handed over composed; PLAN_DISC is
                  read, never recomposed. The plan comes first so two plans' same US-NNN never collide.
                - WORKTREE_PATH = wt.worktree_path
                - PROJECT_PATH = project_path (only include if non-null)
                - PROJECT_GUIDELINES = project_guidelines (the absolute paths Step 3.3 found; omit when empty)
                - VISUAL_VERIFICATION = post-merge  ← every worktree story: the dev server cannot see
                  worktree changes, so visual verification runs after merge-all instead
                - HEADED_MODE: never for a worktree story, for the same reason
        )

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
    # A story with no valid result_json whose worktree HEAD is still base_sha and whose tree is
    # dirty is stalled: the executor went idle without reporting or committing. Check every
    # story without result_json, whichever bucket the fallback above put it in, and move a
    # stalled one to succeeded_stories so it reaches commit verification and commit rescue
    # below. This adds no third resolution path.
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
    # A story that reported ok but left a dirty tree and no commit is committed on its behalf
    # only when every modified path is inside its implementation.files. One path outside that
    # list takes the unchanged failure flow: never rescued, never partially staged, never
    # trimmed to fit.
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

        # 2. The subset guard, read through get-story-context (the executor's own reader).
        declared_files = $AIMI_CLI get-story-context [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                         → .story.implementation.files
        # An absent or empty list declares nothing: no rescue. Never read it as "anything goes".
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

    # A rescued story is a success from here on: it merges and reaches mark-complete like any other.
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

            # cd to this group's EXEC_ROOT first: merge-all checks out the target branch in its CWD's
            # repo, and from AIMI_ROOT in phase mode that would be the main working tree.
            cd [merge_cwd]
            # One `--subject-for <worktree_name> "Merge story: <title>"` per story, each
            # value handed over as data in ONE argv element (never interpolated into
            # a shell string); the title is the story's own, and the helper strips any
            # id token it carries. Worktree and branch names keep their ids.
            merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] \
                [for s in stories: --subject-for [all_worktrees[s.id].worktree_name] "Merge story: [s.title]"] \
                --into [merge_target]

            # A conflict between stories of this wave is resolved here, and the stop further down is
            # the fallback (docs/dev/execute-wave-loop.md § Wave merge conflicts are resolved in place).
            unresolved_reason = "merge did not start"   # merge-all printed git's own reason, no conflicted file
            while merge_result is non-zero and `git -C [merge_cwd] diff --name-only --diff-filter=U` lists files:
                conflicted = that list
                involved = the story merge-all stopped at, plus each story of this wave already merged into
                           [merge_target] whose implementation.files names a file in conflicted
                Read each involved story with `$AIMI_CLI get-story [id] --tasks-file [WAVE_TASKS_FILE]`.
                Edit each conflicted file in [merge_cwd] so it keeps what every involved story adds; their
                acceptanceCriteria are what the result must satisfy. Stage nothing yet.
                Run each involved story's implementation.verify from [merge_cwd] (from the project's
                subfolder inside it when the project is a subfolder of a larger repository).
                if the criteria cannot all hold, or a verify fails:
                    git -C [merge_cwd] checkout --merge -- [conflicted...]   # git's own conflict, back for the human
                    unresolved_reason = "[ids] state requirements that cannot both hold" or "verify failed for [ids]"
                    break
                git -C [merge_cwd] add -- [conflicted...]
                git -C [merge_cwd] commit --no-edit --cleanup=strip   # keeps merge-all's "Merge story: <title>" subject
                Report: "Resolved merge conflict in [conflicted] (wave [wave], [group_key]); verify passed for [involved ids]."
                remaining = stories whose worktree_name is not yet reachable from [merge_target]
                            (git -C [merge_cwd] merge-base --is-ancestor)
                merge_result = success when remaining is empty, otherwise
                               $WORKTREE_MGR merge-all [remaining worktree names...] [their --subject-for pairs] --into [merge_target]

            if merge conflict (non-zero exit):
                Report:
                "MERGE CONFLICT during wave [wave] merge in project [group_key]: [unresolved_reason]."
                "Conflicting files:"
                "[conflict output from merge-all]"
                ""
                "Resolve the conflict on branch [merge_target] in [merge_cwd] and re-run `/aimi:execute` to continue."
                "[merge_cwd] itself — this group's execution root, whichever mode created it — and any live dev server running inside it are left untouched by this failure, so the conflict can be resolved directly in the still-live working tree."
                "Merged story worktrees were removed; the ones that did NOT merge keep both their worktree and their branch, so the retry has something to retry."

                # Clean up only the worktrees already merged into the target. merge-all stops at the first
                # conflict, so a story from that one on is unmerged, and removing it would delete the only
                # branch naming its commits.
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
                # Use result_json.knownGaps when non-empty; otherwise grep KNOWN-GAP trailers (bare
                # "KNOWN-GAP:" or "KNOWN-GAP (US-NNN):", anchored at line start) from the commit body.
                ```bash
                # Absolute under this run's AIMI_ROOT, never relative to the CWD (in container and phase
                # mode the CWD is the container, which is deleted).
                AIMI_ROOT="[this run's already-resolved AIMI_ROOT, the directory holding .aimi/]"
                mkdir -p "$AIMI_ROOT/.aimi/known-gaps"
                # Pseudo: prefer payload; fall back to commit grep
                payload_gaps="${result_payload_by_id[full_story.id].knownGaps or []}"
                if [ -n "$payload_gaps" ] && [ "$payload_gaps" != "[]" ]; then
                  WORKER_GAPS=$(printf '%s\n' "$payload_gaps")
                else
                  WORKER_GAPS=$(git -C "[all_worktrees[full_story.id].worktree_path]" log -1 --format=%B | grep -E '^KNOWN-GAP( \([^)]+\))?:' || true)
                fi
                # PLAN_DISC in the name keeps two plans' gaps for one story id on one day apart.
                if [ -n "$WORKER_GAPS" ]; then
                  GAP_DATE=$(date +%Y-%m-%d)
                  GAP_FILE="$AIMI_ROOT/.aimi/known-gaps/${GAP_DATE}-[full_story.id]-[PLAN_DISC].md"
                  printf '%s\n' "$WORKER_GAPS" > "$GAP_FILE"
                fi
                # --- Extract verify evidence: result_json.verify ({exit, preExit, segments, discriminating}).
                # Empty is a real and common answer (older executor, fallback parse, verify never ran) and
                # is never the same as a zeroed object. ---
                VERIFY_EVIDENCE_JSON="${result_payload_by_id[full_story.id].verify or ''}"
                ```

                $AIMI_CLI mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE] --evidence "$VERIFY_EVIDENCE_JSON"

                # Pass `--evidence` ONLY when `VERIFY_EVIDENCE_JSON` is non-empty. When it is empty the flag is omitted ENTIRELY — the call is exactly `mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE]`, never `--evidence ""`, never `--evidence {}`, and never `--verify-evidence`: the flag is spelled `--evidence` and `cmd_mark_complete` parses no other spelling, so a `--verify-evidence` reached for on the strength of the variable name falls through to the positional parser and is read as a second story id.
                # The flagless argv stays byte-identical: the golden recordings replay it, and an empty object would record "looked, found nothing".

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
                #
                # The wave's stories are `list-ready --brief` stubs ({id, title,
                # priority, dependsOn, project, gate}): no `verification`, no
                # `implementation`. Replace this one with the whole story before
                # the visual, judge and design-review checks below read them:
                full_story = $AIMI_CLI get-story [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                if full_story.verification and full_story.verification.strategy == "visual" and full_story.verification.status == "pending":
                    # --- Post-merge visual verification origin rewrite / degradation gate ---
                    # group_key is this story's group from the enclosing loop. Inline mode (EXEC_OWNS_ROOT
                    # false) has no shared server to rewrite against.
                    SKIP_VISUAL=false
                    if DEPS_STATUS[group_key] == "failed":
                        # The group's install failed (a split member's status is its pre-set
                        # DEPS_STATUS line): skip before any URL is resolved. mark-complete
                        # already ran and is not blocked.
                        $AIMI_CLI set-verification [full_story.id] skipped --reason "dependency install failed for project group [group_key]" --tasks-file [WAVE_TASKS_FILE]
                        Report: "[full_story.id] visual verification skipped — dependency install failed for project group [group_key]."
                        SKIP_VISUAL=true
                    elif not EXEC_OWNS_ROOT:
                        # Inline mode: the story's own verification.url, no rewrite, no gate.
                        STORY_TASKS_FILE="$TASKS_PATH"
                        STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
                        EFFECTIVE_URL="$STORY_VERIFICATION_URL"
                    else:
                        # Phase and container mode; PHASE_MODE only picks the port mechanism.
                        if PHASE_MODE:
                            # container-execution.md § Rewrite a Verification URL Origin with EXEC_ROOT=$AIMI_ROOT and
                            # EXEC_BRANCH=$PHASE_BRANCH (a split's own branch inside a split sub-orchestrator), never
                            # a value cached earlier in this run.
                            ```bash
                            AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
                            : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
                                # No dev server for this branch (expected for a split story whose page needs the sibling
                                # split's API): skip. Never blocks mark-complete or the wave, never retries.
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server running for [PHASE_BRANCH]" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — no dev server running for [PHASE_BRANCH]."
                                SKIP_VISUAL=true
                        else:
                            # CONTAINER_MODE: gate on the Step 3.3 cache, then rewrite the origin.
                            if group_key not in CONTAINER_DEV_URL:
                                # No port resolved for this group in Step 3.3: skip; never blocks mark-complete or the wave.
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server resolved for project group [group_key]" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — no dev server resolved for project group [group_key]."
                                SKIP_VISUAL=true
                            else:
                                ```bash
                                AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
                                : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
                                WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                                : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
                                BRANCH_NAME=$($AIMI_CLI metadata --tasks-file "$TASKS_PATH" | jq -r '.branchName')
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

                # Non-visual stories: judge from the evidence mark-complete persisted, never a blanket
                # "passed". A no-op for a story already judged.
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

    # Remove this wave's worktrees, per group's EXEC_ROOT. Branch deletion is unconditional
    # here; only container mode's own teardown keeps branchName.
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

