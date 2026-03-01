#!/usr/bin/env python3
"""
ACP Adapter for Claude Code CLI inside Docker containers.

Reads a JSON task-request payload from stdin, invokes Claude Code CLI
in headless mode, and streams progress/completion/error messages back
to the host via stdout as JSON-lines (NDJSON).

Transport: stdin/stdout pipes (one JSON object per line).
Logging: stderr only (to avoid mixing with protocol messages).

Usage:
    docker exec -i <container> python /opt/aimi/acp-adapter.py

Environment:
    ANTHROPIC_API_KEY  - Required. Claude API key for headless mode.
    CONTAINER_ID       - Optional. Docker container ID for message envelope.
    SWARM_ID           - Optional. Swarm UUID for message envelope.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REQUIRED_ENV_VARS = ["ANTHROPIC_API_KEY"]

VALID_TASK_REQUEST_FIELDS = {"taskFilePath", "branchName", "repoUrl", "envVars"}
REQUIRED_TASK_REQUEST_FIELDS = {"taskFilePath", "branchName", "repoUrl"}

BRANCH_NAME_PATTERN_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789/_-"
)


# ---------------------------------------------------------------------------
# Globals for signal handling
# ---------------------------------------------------------------------------

_claude_process = None  # type: subprocess.Popen | None
_interrupted = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(message: str) -> None:
    """Log a message to stderr (never stdout)."""
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    print(f"[acp-adapter {timestamp}] {message}", file=sys.stderr, flush=True)


def iso_now() -> str:
    """Return the current UTC time as ISO 8601 string."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def emit(message: dict) -> None:
    """Write a single JSON-line message to stdout."""
    line = json.dumps(message, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def envelope(msg_type: str, payload: dict) -> dict:
    """Wrap a payload in the ACP message envelope."""
    return {
        "type": msg_type,
        "timestamp": iso_now(),
        "swarmId": os.environ.get("SWARM_ID", "00000000-0000-0000-0000-000000000000"),
        "containerId": os.environ.get("CONTAINER_ID", "unknown"),
        "payload": payload,
    }


def emit_progress(story_id: str, status: str, output: str) -> None:
    """Emit a progress-update message."""
    emit(envelope("progress-update", {
        "storyId": story_id,
        "status": status,
        "output": output[:2000],
    }))


def emit_completion(status: str, pr_url: str | None = None,
                    errors: list[str] | None = None) -> None:
    """Emit a completion message."""
    emit(envelope("completion", {
        "status": status,
        "prUrl": pr_url,
        "errors": [e[:500] for e in (errors or [])][:50],
    }))


def emit_error(code: str, message: str) -> None:
    """Emit an error message."""
    emit(envelope("error", {
        "code": code,
        "message": message[:2000],
    }))


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_branch_name(name: str) -> bool:
    """Validate branch name against ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$."""
    if not name:
        return False
    first_char = name[0]
    if not (first_char.isascii() and first_char.isalnum()):
        return False
    return all(c in BRANCH_NAME_PATTERN_CHARS for c in name)


def validate_task_file_path(path: str) -> bool:
    """Validate that taskFilePath ends with .json."""
    return isinstance(path, str) and path.endswith(".json")


def validate_repo_url(url: str) -> bool:
    """Validate that repoUrl looks like a valid git URL."""
    if not isinstance(url, str):
        return False
    return url.startswith("https://") or url.startswith("git@")


def validate_env_var_key(key: str) -> bool:
    """Validate env var key matches ^[A-Z_][A-Z0-9_]*$."""
    if not key:
        return False
    first = key[0]
    if not (first.isupper() or first == "_"):
        return False
    return all(c.isupper() or c.isdigit() or c == "_" for c in key)


def validate_task_request(payload: dict) -> list[str]:
    """Validate a task-request payload. Returns list of error strings."""
    errors = []

    for field in REQUIRED_TASK_REQUEST_FIELDS:
        if field not in payload:
            errors.append(f"Missing required field: {field}")

    if "taskFilePath" in payload and not validate_task_file_path(payload["taskFilePath"]):
        errors.append("taskFilePath must end with .json")

    if "branchName" in payload and not validate_branch_name(payload["branchName"]):
        errors.append(
            "branchName must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$"
        )

    if "repoUrl" in payload and not validate_repo_url(payload["repoUrl"]):
        errors.append("repoUrl must start with https:// or git@")

    if "envVars" in payload:
        env_vars = payload["envVars"]
        if not isinstance(env_vars, dict):
            errors.append("envVars must be an object")
        else:
            for key in env_vars:
                if not validate_env_var_key(key):
                    errors.append(
                        f"envVars key '{key}' must match ^[A-Z_][A-Z0-9_]*$"
                    )
                if not isinstance(env_vars[key], str):
                    errors.append(f"envVars value for '{key}' must be a string")

    return errors


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

def handle_sigterm(signum: int, frame: object) -> None:
    """Handle SIGTERM: kill Claude subprocess and report interrupted status."""
    global _interrupted
    _interrupted = True
    log("Received SIGTERM, shutting down gracefully...")

    if _claude_process is not None and _claude_process.poll() is None:
        log("Terminating Claude Code subprocess...")
        try:
            _claude_process.terminate()
            try:
                _claude_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                log("Subprocess did not exit in time, sending SIGKILL...")
                _claude_process.kill()
                _claude_process.wait(timeout=3)
        except OSError as exc:
            log(f"Error terminating subprocess: {exc}")

    emit_completion("stopped", errors=["Process interrupted by SIGTERM"])
    sys.exit(130)


# ---------------------------------------------------------------------------
# Core execution
# ---------------------------------------------------------------------------

def build_prompt(payload: dict) -> str:
    """Build the prompt string for Claude Code CLI from the task payload."""
    parts = [
        "You are an autonomous agent executing a task inside a Docker container.",
        "",
        f"## Task File: {payload['taskFilePath']}",
        f"## Branch: {payload['branchName']}",
        f"## Repository: {payload['repoUrl']}",
        "",
        "Execute the stories in the task file. For each story:",
        "1. Read the story requirements and acceptance criteria",
        "2. Implement the changes",
        "3. Verify acceptance criteria are met",
        "4. Commit with a descriptive message",
        "",
        "Work through stories in dependency order. Skip stories whose "
        "dependencies have failed.",
    ]

    if payload.get("envVars"):
        parts.append("")
        parts.append("## Environment Variables")
        for key, value in payload["envVars"].items():
            parts.append(f"- {key}={value}")

    return "\n".join(parts)


def run_claude(prompt: str) -> tuple[int, str]:
    """
    Invoke Claude Code CLI in headless mode and stream output.

    Returns (exit_code, captured_output).
    """
    global _claude_process

    cmd = [
        "claude",
        "--dangerously-skip-permissions",
        "-p",
        prompt,
    ]

    log(f"Launching Claude Code CLI: {' '.join(cmd[:3])} ...")

    output_lines = []

    try:
        _claude_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
        )

        # Stream stdout line by line as progress updates
        if _claude_process.stdout is not None:
            for line in _claude_process.stdout:
                stripped = line.rstrip("\n")
                if stripped:
                    output_lines.append(stripped)
                    # Emit periodic progress with the latest output line
                    emit_progress(
                        "US-000",
                        "in_progress",
                        stripped,
                    )

        # Wait for process to finish
        _claude_process.wait()
        exit_code = _claude_process.returncode

        # Capture any stderr
        stderr_output = ""
        if _claude_process.stderr is not None:
            stderr_output = _claude_process.stderr.read()
        if stderr_output:
            log(f"Claude Code stderr: {stderr_output.strip()}")

        log(f"Claude Code exited with code {exit_code}")
        return exit_code, "\n".join(output_lines[-20:])  # last 20 lines

    except FileNotFoundError:
        log("Claude Code CLI not found in PATH")
        return -1, "Claude Code CLI binary not found"
    except OSError as exc:
        log(f"Failed to launch Claude Code CLI: {exc}")
        return -1, str(exc)
    finally:
        _claude_process = None


def main() -> int:
    """Main entry point for the ACP adapter."""

    # Install signal handler
    signal.signal(signal.SIGTERM, handle_sigterm)

    # --- Validate environment ---
    missing_vars = [v for v in REQUIRED_ENV_VARS if not os.environ.get(v)]
    if missing_vars:
        msg = f"Missing required environment variables: {', '.join(missing_vars)}"
        log(msg)
        emit_error("MISSING_ENV_VAR", msg)
        return 1

    log("ACP adapter started. Waiting for task-request on stdin...")

    # --- Read task-request from stdin ---
    try:
        raw_input = sys.stdin.readline()
        if not raw_input.strip():
            msg = "Empty input received on stdin"
            log(msg)
            emit_error("INVALID_INPUT", msg)
            return 1

        request = json.loads(raw_input)
    except json.JSONDecodeError as exc:
        msg = f"Invalid JSON on stdin: {exc}"
        log(msg)
        emit_error("INVALID_INPUT", msg)
        return 1

    # --- Validate message type ---
    msg_type = request.get("type")
    if msg_type != "task-request":
        msg = f"Expected message type 'task-request', got '{msg_type}'"
        log(msg)
        emit_error("INVALID_INPUT", msg)
        return 1

    # --- Extract and validate payload ---
    payload = request.get("payload")
    if not isinstance(payload, dict):
        msg = "Missing or invalid 'payload' in task-request"
        log(msg)
        emit_error("INVALID_INPUT", msg)
        return 1

    validation_errors = validate_task_request(payload)
    if validation_errors:
        msg = "Task request validation failed: " + "; ".join(validation_errors)
        log(msg)
        emit_error("TASK_FILE_INVALID", msg)
        return 1

    log(f"Received task-request: taskFile={payload['taskFilePath']}, "
        f"branch={payload['branchName']}, repo={payload['repoUrl']}")

    # --- Set any provided environment variables ---
    env_vars = payload.get("envVars", {})
    for key, value in env_vars.items():
        os.environ[key] = value
        log(f"Set env var: {key}")

    # --- Build prompt and run Claude Code ---
    prompt = build_prompt(payload)

    emit_progress("US-000", "in_progress", "Starting Claude Code CLI...")

    exit_code, output = run_claude(prompt)

    if _interrupted:
        # Signal handler already emitted completion
        return 130

    # --- Map exit code to completion status ---
    if exit_code == 0:
        log("Claude Code completed successfully")
        emit_completion("completed", pr_url=None, errors=[])
        return 0
    else:
        error_msg = f"Claude Code exited with code {exit_code}"
        log(error_msg)
        errors = [error_msg]
        if output:
            errors.append(f"Last output: {output[:450]}")
        emit_completion("failed", pr_url=None, errors=errors)
        return 1


if __name__ == "__main__":
    sys.exit(main())
