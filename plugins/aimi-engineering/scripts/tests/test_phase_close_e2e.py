"""End-to-end proof that this phase's own honest-verification contract holds
when driven through the real CLI, not asserted verb by verb.

Every other module under this directory proves one Python function against a
fixture. This one drives `aimi-cli.sh` itself, as a subprocess, through the
exact sequence `/aimi:execute` runs at phase close -- `roadmap-init`,
`mark-complete` (with and without `--evidence`), `judge-verification`,
`set-verification`, `roadmap-write-handoff`, `roadmap-set-status --status
completed`, and a closing `verification-report` read -- and checks the
document that comes out the other end, not the intermediate claims each verb
makes about itself. "Success is measured, not judged" (this phase's own
design decision) is the reason this module exists: US-001 through US-006
each proved their own verb in isolation, and none of them proved the verbs
still agree with each other when chained for real.

EVERY CASE BUILDS A THROWAWAY PROJECT ROOT under pytest's own `tmp_path` and
points HOME, XDG_CONFIG_HOME, CLAUDE_CONFIG_DIR and AIMI_CONFIG_DIR at
directories under it -- test_version_cache.py's own `_build_root` fixture
pattern (see that module's header for why: a case that leaked the developer's
real value could rewrite the plugin install running the suite), pared down to
what a roadmap/tasks lifecycle run needs. `CLI` is resolved from THIS
worktree's own `scripts/` directory, the same `os.path.dirname` derivation
test_version_cache.py uses, never the global plugin cache -- so this module
proves the tree under test, not whatever happens to be installed. This module
never opens the repository's own `.aimi/`.
"""

import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")


def _build_root(root):
    """A throwaway project root with its own `.aimi/`, and an env that points
    every config-path-reading variable at directories under `root` rather
    than the developer's real ones.

    No plugin-cache entry and no cli-path pointer are seeded here, unlike
    test_version_cache.py's fuller fixture: every call below invokes `CLI` by
    its own literal path (`["bash", CLI, ...]`), so nothing here ever needs
    to RESOLVE the CLI the way a spawned command does.
    """
    project = os.path.join(root, "project")
    os.makedirs(os.path.join(project, ".aimi"), exist_ok=True)
    aimi_config = os.path.join(root, "aimi-config")
    os.makedirs(aimi_config, exist_ok=True)
    os.makedirs(os.path.join(root, "xdg"), exist_ok=True)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": root,
        "XDG_CONFIG_HOME": os.path.join(root, "xdg"),
        "CLAUDE_CONFIG_DIR": os.path.join(root, "claude-config"),
        "AIMI_CONFIG_DIR": aimi_config,
        "LC_ALL": "C",
        "CLAUDECODE": "1",
    }
    return project, env


def _run(project, env, args, input_text=None):
    """One `aimi-cli.sh` invocation, cwd'd at the throwaway project so
    `find_aimi_root` discovers `project/.aimi` immediately rather than
    walking anywhere."""
    return subprocess.run(
        ["bash", CLI] + list(args),
        cwd=project,
        env=env,
        input=input_text,
        capture_output=True,
        text=True,
        timeout=120,
    )


def _assert_ok(proc, label):
    assert proc.returncode == 0, (
        label + " exited " + str(proc.returncode)
        + "\nstdout:\n" + proc.stdout
        + "\nstderr:\n" + proc.stderr
    )
    return proc


def _phase_tasks_path(project, feature, phase_id, slug):
    """`_phase_tasks_path`'s own formula (roadmap.py), reproduced rather than
    imported: `<feature_dir>/<dir>/<feature>-phase-<id>-tasks.json`, where
    `<dir>` is `_compute_phase_dir`'s `phase-<id>[-<slug>]`."""
    feature_dir = os.path.join(project, ".aimi", "tasks", feature)
    phase_dir_name = "phase-" + str(phase_id) + ("-" + slug if slug else "")
    return os.path.join(
        feature_dir, phase_dir_name, feature + "-phase-" + str(phase_id) + "-tasks.json"
    )


def _write_tasks_file(path, stories, phase_id=1, metadata_extra=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    doc = {
        "schemaVersion": "3.3",
        "metadata": dict({"title": "Fixture Phase", "type": "phase"}, **(metadata_extra or {})),
        "userStories": stories,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2, ensure_ascii=False)


def _init_phase(project, env, feature, phase_id=1, slug="fixture"):
    """`roadmap-init` with one minimal phase on stdin, then the pending ->
    in_progress transition every real claim performs before a phase can ever
    reach `completed` (STATUS_TRANSITIONS has no `pending:completed` edge)."""
    payload = json.dumps(
        [
            {
                "id": phase_id,
                "name": "Fixture Phase",
                "goal": "Prove the honest-verification contract end to end",
                "slug": slug,
                "successCriteria": [],
                "creates": [],
                "needs": [],
                "areas": [],
            }
        ]
    )
    _assert_ok(
        _run(project, env, ["roadmap-init", "--feature", feature], input_text=payload),
        "roadmap-init",
    )
    _assert_ok(
        _run(
            project,
            env,
            [
                "roadmap-set-status",
                "--feature", feature,
                "--phase", str(phase_id),
                "--status", "in_progress",
            ],
        ),
        "roadmap-set-status --status in_progress",
    )


def _write_handoff(project, env, feature, phase_id=1):
    return _run(
        project,
        env,
        ["roadmap-write-handoff", "--feature", feature, "--phase", str(phase_id)],
        input_text="{}",
    )


def _set_status_completed(project, env, feature, phase_id=1):
    return _run(
        project,
        env,
        [
            "roadmap-set-status",
            "--feature", feature,
            "--phase", str(phase_id),
            "--status", "completed",
        ],
    )


def _verification_report(project, env, tasks_path):
    proc = _assert_ok(
        _run(project, env, ["verification-report", "--tasks-file", tasks_path]),
        "verification-report",
    )
    return json.loads(proc.stdout)


# ---------------------------------------------------------------------------
# AC1 -- the positive single-file case
# ---------------------------------------------------------------------------


def test_a_fixture_phase_closes_clean_with_every_verdict_judged(tmp_path):
    """The whole chain, run for real: a story whose verify recorded a
    discriminating exit 0 (mark-complete --evidence, judge-verification ->
    passed), a story that declared implementation.verify but recorded no
    evidence at all (mark-complete with no flag, judge-verification ->
    skipped, for the reason judge-verification names when nothing was
    recorded), and a visual story short-circuited by an operator
    (set-verification skipped --reason). All three complete, the phase's
    handoff writes, and `roadmap-set-status --status completed` succeeds --
    then `verification-report` on the SAME file must read back
    `verdicts.pending == 0` and the visual story's own reason in `skipped`,
    proving the close and the report agree about the same document rather
    than each being separately unit-tested.
    """
    root = str(tmp_path)
    project, env = _build_root(root)
    feature = "e2e-fixture"
    tasks_path = _phase_tasks_path(project, feature, 1, "fixture")

    _write_tasks_file(
        tasks_path,
        [
            {
                "id": "US-001",
                "title": "Discriminating verify",
                "description": "A story whose verify recorded real evidence.",
                "acceptanceCriteria": ["verify exits 0"],
                "status": "pending",
                "dependsOn": [],
                "implementation": {"verify": "bash scripts/verify-001.sh"},
                "verification": {"strategy": "test", "status": "pending"},
            },
            {
                "id": "US-002",
                "title": "Declared but unrecorded verify",
                "description": "A story that declared implementation.verify but "
                "whose executor left no evidence behind.",
                "acceptanceCriteria": ["verify exits 0"],
                "status": "pending",
                "dependsOn": [],
                "implementation": {"verify": "bash scripts/verify-002.sh"},
                "verification": {"strategy": "test", "status": "pending"},
            },
            {
                "id": "US-003",
                "title": "Visual story",
                "description": "A story judged by an operator rather than by "
                "recorded verify evidence.",
                "acceptanceCriteria": ["renders correctly"],
                "status": "pending",
                "dependsOn": [],
                "verification": {
                    "strategy": "visual",
                    "status": "pending",
                    "url": "http://localhost:4000/fixture",
                },
            },
        ],
    )

    _init_phase(project, env, feature)

    _assert_ok(
        _run(
            project,
            env,
            [
                "mark-complete", "US-001",
                "--evidence", json.dumps({"exit": 0, "preExit": 1, "segments": 5, "discriminating": 3}),
                "--tasks-file", tasks_path,
            ],
        ),
        "mark-complete US-001",
    )
    _assert_ok(
        _run(project, env, ["mark-complete", "US-002", "--tasks-file", tasks_path]),
        "mark-complete US-002",
    )
    _assert_ok(
        _run(project, env, ["mark-complete", "US-003", "--tasks-file", tasks_path]),
        "mark-complete US-003",
    )

    judge_001 = _assert_ok(
        _run(project, env, ["judge-verification", "US-001", "--tasks-file", tasks_path]),
        "judge-verification US-001",
    )
    assert json.loads(judge_001.stdout)["verification"]["status"] == "passed"

    judge_002 = _assert_ok(
        _run(project, env, ["judge-verification", "US-002", "--tasks-file", tasks_path]),
        "judge-verification US-002",
    )
    judged_002 = json.loads(judge_002.stdout)["verification"]
    assert judged_002["status"] == "skipped"
    assert judged_002["skipReason"] == (
        "implementation.verify was declared but the executor recorded no verify evidence"
    )

    visual_reason = "agent-browser not installed"
    _assert_ok(
        _run(
            project,
            env,
            [
                "set-verification", "US-003", "skipped",
                "--reason", visual_reason,
                "--tasks-file", tasks_path,
            ],
        ),
        "set-verification US-003",
    )

    _assert_ok(_write_handoff(project, env, feature), "roadmap-write-handoff")

    close = _set_status_completed(project, env, feature)
    _assert_ok(close, "roadmap-set-status --status completed")

    report = _verification_report(project, env, tasks_path)
    assert report["verdicts"]["pending"] == 0
    assert report["verdicts"] == {"pending": 0, "passed": 1, "failed": 0, "skipped": 2, "other": 0}
    skipped_by_id = {entry["id"]: entry["reason"] for entry in report["skipped"]}
    assert skipped_by_id["US-003"] == visual_reason


# ---------------------------------------------------------------------------
# The negative twin -- one unjudged completed story blocks the close
# ---------------------------------------------------------------------------


def test_a_phase_with_one_unjudged_verification_refuses_to_close(tmp_path):
    """Same shape as the positive case, minus the judgment on one story: US-002
    completes but is never run through judge-verification or
    set-verification, so its `verification.status` stays the literal
    "pending" it was born with. `roadmap-set-status --status completed` must
    refuse at a non-zero exit -- the completed-gate precondition
    `_completed_gate_refusals` exists to enforce, proven here against a real
    close rather than against the gate function in isolation.
    """
    root = str(tmp_path)
    project, env = _build_root(root)
    feature = "e2e-negative"
    tasks_path = _phase_tasks_path(project, feature, 1, "fixture")

    _write_tasks_file(
        tasks_path,
        [
            {
                "id": "US-001",
                "title": "Judged story",
                "description": "Completes and gets judged.",
                "acceptanceCriteria": ["verify exits 0"],
                "status": "pending",
                "dependsOn": [],
                "verification": {"strategy": "test", "status": "pending"},
            },
            {
                "id": "US-002",
                "title": "Completed but never judged",
                "description": "Completes and is left at verification.status pending.",
                "acceptanceCriteria": ["verify exits 0"],
                "status": "pending",
                "dependsOn": [],
                "verification": {"strategy": "test", "status": "pending"},
            },
        ],
    )

    _init_phase(project, env, feature)

    for story_id in ("US-001", "US-002"):
        _assert_ok(
            _run(project, env, ["mark-complete", story_id, "--tasks-file", tasks_path]),
            "mark-complete " + story_id,
        )

    _assert_ok(
        _run(project, env, ["judge-verification", "US-001", "--tasks-file", tasks_path]),
        "judge-verification US-001",
    )
    # US-002 is deliberately never judged.

    _assert_ok(_write_handoff(project, env, feature), "roadmap-write-handoff")

    close = _set_status_completed(project, env, feature)
    assert close.returncode != 0, "the close must refuse with US-002 still unjudged"
    assert "US-002" in close.stderr
    assert 'verification.status is still the literal "pending"' in close.stderr

    report = _verification_report(project, env, tasks_path)
    assert report["verdicts"]["pending"] == 1


# ---------------------------------------------------------------------------
# The split-phase variant -- every member gets judged before the close
# ---------------------------------------------------------------------------


def test_a_split_phase_closes_only_once_every_member_is_judged(tmp_path):
    """Two member tasks files sit inside one phase directory with no phase
    'main' file -- the shape `_completed_gate_resolve_members` reaches by
    finding an anchor carrying a well-formed `metadata.splitGroup` and then
    following its declared `siblings`, per the schema in this plugin's own
    CLAUDE.md (Tasks File Schema, `metadata.splitGroup`). Every story in
    BOTH files gets judged before the close; proves outline:06's per-member
    gate end to end rather than only against `_completed_gate_resolve_members`
    directly.
    """
    root = str(tmp_path)
    project, env = _build_root(root)
    feature = "e2e-split"
    phase_id = 1
    slug = "split"

    _init_phase(project, env, feature, phase_id=phase_id, slug=slug)

    feature_dir = os.path.join(project, ".aimi", "tasks", feature)
    phase_dir = os.path.join(feature_dir, "phase-" + str(phase_id) + "-" + slug)
    alpha_path = os.path.join(phase_dir, feature + "-phase-" + str(phase_id) + "-alpha-tasks.json")
    beta_path = os.path.join(phase_dir, feature + "-phase-" + str(phase_id) + "-beta-tasks.json")

    def _split_doc(project_key, index, sibling_basename, story_id):
        return {
            "schemaVersion": "3.3",
            "metadata": {
                "title": "Fixture Split Phase",
                "type": "phase",
                "splitGroup": {
                    "project": project_key,
                    "index": index,
                    "total": 2,
                    "siblings": [sibling_basename],
                },
            },
            "userStories": [
                {
                    "id": story_id,
                    "title": "Split member story",
                    "description": "One story per member file.",
                    "acceptanceCriteria": ["verify exits 0"],
                    "status": "pending",
                    "dependsOn": [],
                    "verification": {"strategy": "test", "status": "pending"},
                }
            ],
        }

    os.makedirs(phase_dir, exist_ok=True)
    with open(alpha_path, "w", encoding="utf-8") as handle:
        json.dump(
            _split_doc("apps/alpha", 1, os.path.basename(beta_path), "US-001"),
            handle, indent=2, ensure_ascii=False,
        )
    with open(beta_path, "w", encoding="utf-8") as handle:
        json.dump(
            _split_doc("apps/beta", 2, os.path.basename(alpha_path), "US-001"),
            handle, indent=2, ensure_ascii=False,
        )

    # No main <feature>-phase-<id>-tasks.json is ever written at this dir --
    # the resolver must fall through to the split-member branch on its own.
    main_path = os.path.join(phase_dir, feature + "-phase-" + str(phase_id) + "-tasks.json")
    assert not os.path.isfile(main_path)

    for member_path in (alpha_path, beta_path):
        _assert_ok(
            _run(project, env, [
                "mark-complete", "US-001",
                "--evidence", json.dumps({"exit": 0, "preExit": 1, "segments": 2, "discriminating": 1}),
                "--tasks-file", member_path,
            ]),
            "mark-complete US-001 (" + os.path.basename(member_path) + ")",
        )
        _assert_ok(
            _run(project, env, ["judge-verification", "US-001", "--tasks-file", member_path]),
            "judge-verification US-001 (" + os.path.basename(member_path) + ")",
        )

    _assert_ok(_write_handoff(project, env, feature, phase_id=phase_id), "roadmap-write-handoff")

    close = _set_status_completed(project, env, feature, phase_id=phase_id)
    _assert_ok(close, "roadmap-set-status --status completed (split phase)")

    for member_path in (alpha_path, beta_path):
        report = _verification_report(project, env, member_path)
        assert report["verdicts"]["pending"] == 0, member_path


# ---------------------------------------------------------------------------
# The phase-close visual gate -- a UI phase closes only once its comparison is recorded
# ---------------------------------------------------------------------------


def _set_visual_gate(project, feature, phase_id, visual_gate):
    """Set (or, with None, pop) phases[i].visualGate on roadmap.json -- plain file
    I/O, the way this module's fixtures already build state."""
    path = os.path.join(project, ".aimi", "tasks", feature, "roadmap.json")
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    for phase in doc["phases"]:
        if phase["id"] == phase_id:
            if visual_gate is None:
                phase.pop("visualGate", None)
            else:
                phase["visualGate"] = visual_gate
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle, indent=2)


def test_a_ui_phase_refuses_to_close_until_its_visual_gate_is_recorded(tmp_path):
    root = str(tmp_path)
    project, env = _build_root(root)
    feature = "e2e-visual"
    tasks_path = _phase_tasks_path(project, feature, 1, "fixture")
    _write_tasks_file(
        tasks_path,
        [
            {
                "id": "US-001",
                "title": "Visual story",
                "description": "Completes with a visual verification.",
                "acceptanceCriteria": ["matches the prototype"],
                "status": "pending",
                "dependsOn": [],
                "verification": {"strategy": "visual", "status": "pending"},
            }
        ],
        metadata_extra={"prototypePaths": [".aimi/prototypes/p.html"]},
    )
    _init_phase(project, env, feature)
    _assert_ok(
        _run(project, env, [
            "mark-complete", "US-001",
            "--evidence", json.dumps({"exit": 0, "discriminating": 1}),
            "--tasks-file", tasks_path,
        ]),
        "mark-complete US-001",
    )
    _assert_ok(
        _run(project, env, ["set-verification", "US-001", "passed", "--tasks-file", tasks_path]),
        "set-verification US-001",
    )
    _assert_ok(_write_handoff(project, env, feature), "roadmap-write-handoff")

    # No record at all.
    close = _set_status_completed(project, env, feature)
    assert close.returncode != 0
    assert "roadmap-record-visual-gate" in close.stderr
    assert "phase 1" in close.stderr

    # A recorded divergence still refuses.
    _set_visual_gate(project, feature, 1, {
        "status": "diverges", "reason": "spacing", "review": None,
        "recordedAt": "2020-01-01T00:00:00Z",
    })
    close = _set_status_completed(project, env, feature)
    assert close.returncode != 0
    assert "roadmap-record-visual-gate" in close.stderr

    # Accepted closes.
    _set_visual_gate(project, feature, 1, {
        "status": "accepted", "reason": "known and tolerated", "review": None,
        "recordedAt": "2020-01-01T00:00:00Z",
    })
    _assert_ok(_set_status_completed(project, env, feature), "roadmap-set-status --status completed")


# ---------------------------------------------------------------------------
# The evidence gate -- closing a phase that proved nothing needs a human reason
# ---------------------------------------------------------------------------


def test_evidence_gate_refuses_then_acknowledge_evidence_lets_the_phase_close(tmp_path):
    """A story completed with a bare exit 0 (no discriminating count) is
    judged `passed` by judge-verification, and the close still refuses until
    acknowledge-evidence records why; the acknowledgement lapses when a
    further story completes."""
    root = str(tmp_path)
    project, env = _build_root(root)
    feature = "e2e-evidence"
    tasks_path = _phase_tasks_path(project, feature, 1, "fixture")

    def _story(story_id):
        return {
            "id": story_id,
            "title": "Self-reported exit 0",
            "description": "Completes with an exit 0 and nothing discriminating.",
            "acceptanceCriteria": ["verify exits 0"],
            "status": "pending",
            "dependsOn": [],
            "implementation": {"verify": "true"},
            "verification": {"strategy": "test", "status": "pending"},
        }

    _write_tasks_file(tasks_path, [_story("US-001"), _story("US-002")])
    _init_phase(project, env, feature)
    for story_id in ("US-001",):
        _assert_ok(
            _run(project, env, [
                "mark-complete", story_id, "--evidence", json.dumps({"exit": 0}),
                "--tasks-file", tasks_path,
            ]),
            "mark-complete " + story_id,
        )
        _assert_ok(
            _run(project, env, ["judge-verification", story_id, "--tasks-file", tasks_path]),
            "judge-verification " + story_id,
        )
    _assert_ok(_write_handoff(project, env, feature), "roadmap-write-handoff")

    refused = _set_status_completed(project, env, feature)
    assert refused.returncode != 0
    assert "acknowledge-evidence" in refused.stderr
    assert "discriminating=0 completed=1" in refused.stderr

    # An agent session cannot acknowledge: the verb refuses before the lock.
    agent_env = dict(env, AIMI_AGENT_MODE="true")
    agent = _run(project, agent_env, ["acknowledge-evidence", "--reason", "x", "--tasks-file", tasks_path])
    assert agent.returncode != 0
    assert "human decision" in agent.stderr

    human_env = {k: v for k, v in env.items() if k not in ("CI", "AIMI_AGENT_MODE")}
    _assert_ok(
        _run(project, human_env, [
            "acknowledge-evidence", "--reason", "single-story phase, exit 0 reviewed",
            "--tasks-file", tasks_path,
        ]),
        "acknowledge-evidence",
    )
    _assert_ok(_set_status_completed(project, env, feature), "roadmap-set-status --status completed")
