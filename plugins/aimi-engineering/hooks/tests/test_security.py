"""Tests for hook_utils.redact_secrets (US-006)."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

_HOOKS_DIR = Path(__file__).resolve().parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import redact_secrets  # noqa: E402


def test_redact_openai_key():
    text = "Using key sk-abcdefghijklmnopqrstuvwxyz123456 to call the API"
    result = redact_secrets(text)
    assert "sk-abcdefghijklmnopqrstuvwxyz123456" not in result
    assert "[REDACTED:sk-token]" in result


def test_redact_github_pat():
    text = "export GITHUB_TOKEN=ghp_" + "A" * 36
    result = redact_secrets(text)
    assert "ghp_" + "A" * 36 not in result
    assert "[REDACTED:github-pat]" in result


def test_redact_jwt():
    # Minimal valid-looking JWT: three base64url segments of 20+ chars each
    header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    payload = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ"
    sig = "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    jwt_token = f"{header}.{payload}.{sig}"
    text = f"Authorization: Bearer {jwt_token}"
    result = redact_secrets(text)
    assert jwt_token not in result
    assert "[REDACTED:jwt]" in result


def test_redact_aws_access_key():
    text = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
    result = redact_secrets(text)
    assert "AKIAIOSFODNN7EXAMPLE" not in result
    assert "[REDACTED:aws-access-key]" in result


def test_redact_keeps_non_sensitive_text():
    text = "Hello, world! This is a normal log message with no secrets."
    result = redact_secrets(text)
    assert result == text
