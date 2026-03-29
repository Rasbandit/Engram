"""Unit tests for cleanup helper — SQL injection prevention.

These tests verify that cleanup_test_data:
- Rejects patterns containing SQL injection payloads
- Rejects patterns with shell metacharacters
- Accepts legitimate e2e email patterns
- Constructs commands using psql variable binding (not string interpolation)
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from helpers.cleanup import cleanup_test_data


# ---------------------------------------------------------------------------
# Injection patterns that MUST be rejected
# ---------------------------------------------------------------------------

INJECTION_PATTERNS = [
    # Classic SQL injection
    "'; DROP TABLE users; --",
    "e2e-%' OR '1'='1",
    "e2e-%'; DELETE FROM users WHERE '1'='1",
    # Subquery injection
    "e2e-%' UNION SELECT password FROM users--",
    # Shell metacharacters (could escape via docker exec)
    "e2e-$(whoami)@test.local",
    "e2e-`id`@test.local",
    "e2e-*@test.local",
    # Newline / null byte injection
    "e2e-%@test.local\n; DROP TABLE users;",
    "e2e-%@test.local\x00; DROP TABLE users;",
    # Parentheses and brackets (SQL subexpressions)
    "e2e-(SELECT 1)@test.local",
    "e2e-[admin]@test.local",
    # Backslash and quotes
    "e2e-\\@test.local",
    "e2e-'@test.local",
    'e2e-"@test.local',
]


@pytest.mark.parametrize("pattern", INJECTION_PATTERNS)
def test_rejects_sql_injection_patterns(pattern: str) -> None:
    with pytest.raises(ValueError, match="Unsafe email pattern rejected"):
        cleanup_test_data(pattern)


# ---------------------------------------------------------------------------
# Legitimate patterns that MUST be accepted
# ---------------------------------------------------------------------------

SAFE_PATTERNS = [
    "e2e-%@test.local",
    "e2e-sync-20260329120000@test.local",
    "e2e-iso-20260329120000@test.local",
    "test+tag@example.com",
    "user.name@domain.co",
    "%@test.local",
]


@pytest.mark.parametrize("pattern", SAFE_PATTERNS)
def test_accepts_safe_email_patterns(pattern: str) -> None:
    """Safe patterns should pass validation and reach subprocess.run."""
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "DELETE 1"
        cleanup_test_data(pattern)
        mock_run.assert_called_once()


# ---------------------------------------------------------------------------
# Command construction — verify psql variable binding
# ---------------------------------------------------------------------------

def test_command_uses_psql_variable_binding() -> None:
    """The generated command must use -v pat=... and :'pat', not f-string interpolation."""
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "DELETE 1"

        cleanup_test_data("e2e-%@test.local")

        cmd = mock_run.call_args[0][0]

        # Must pass pattern via -v flag
        assert "-v" in cmd
        v_idx = cmd.index("-v")
        assert cmd[v_idx + 1] == "pat=e2e-%@test.local"

        # SQL must reference :'pat', not contain the raw pattern
        sql_arg_idx = cmd.index("-c") + 1
        sql = cmd[sql_arg_idx]
        assert ":'pat'" in sql
        assert "e2e-%" not in sql, "Raw pattern must not appear in SQL string"


def test_command_does_not_interpolate_pattern_into_sql() -> None:
    """Even with a safe pattern, SQL must never contain the literal pattern value."""
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "DELETE 0"

        test_pattern = "e2e-sync-99999@test.local"
        cleanup_test_data(test_pattern)

        cmd = mock_run.call_args[0][0]
        sql_arg_idx = cmd.index("-c") + 1
        sql = cmd[sql_arg_idx]
        assert test_pattern not in sql, "Pattern value must not be interpolated into SQL"


# ---------------------------------------------------------------------------
# Error propagation
# ---------------------------------------------------------------------------

def test_raises_on_subprocess_failure() -> None:
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "ERROR: relation does not exist"

        with pytest.raises(RuntimeError, match="Cleanup failed"):
            cleanup_test_data()
