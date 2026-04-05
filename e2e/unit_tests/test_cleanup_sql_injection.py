"""Unit tests for cleanup helper — SQL injection prevention.

These tests verify that cleanup_test_data:
- Rejects patterns containing SQL injection payloads
- Rejects patterns with shell metacharacters
- Accepts legitimate e2e email patterns
- Constructs commands using psql \\set + :'var' quoting (not string interpolation)
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
# Command construction — verify psql variable binding via stdin
# ---------------------------------------------------------------------------

def test_command_uses_psql_variable_binding() -> None:
    """The SQL script must use \\set + :'pat' quoting, piped via stdin."""
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "DELETE 1"

        cleanup_test_data("e2e-%@test.local")

        # SQL is passed via stdin (input kwarg), not -c flag
        call_kwargs = mock_run.call_args[1]
        sql_input = call_kwargs.get("input", "")

        # Must set variable via \set
        assert "\\set pat 'e2e-%@test.local'" in sql_input

        # SQL must reference :'pat'
        assert ":'pat'" in sql_input


def test_command_does_not_interpolate_pattern_into_sql() -> None:
    """The SQL body (after \\set) must never contain the literal pattern value."""
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 0
        mock_run.return_value.stdout = "DELETE 0"

        test_pattern = "e2e-sync-99999@test.local"
        cleanup_test_data(test_pattern)

        call_kwargs = mock_run.call_args[1]
        sql_input = call_kwargs.get("input", "")

        # The \set line will contain the pattern, but the SQL body must not
        lines = sql_input.strip().split("\n")
        sql_body = "\n".join(lines[1:])  # Skip the \set line
        assert test_pattern not in sql_body, "Pattern value must not be interpolated into SQL body"


# ---------------------------------------------------------------------------
# Error propagation
# ---------------------------------------------------------------------------

def test_raises_on_subprocess_failure() -> None:
    with patch("helpers.cleanup.subprocess.run") as mock_run:
        mock_run.return_value.returncode = 1
        mock_run.return_value.stderr = "ERROR: relation does not exist"

        with pytest.raises(RuntimeError, match="Cleanup failed"):
            cleanup_test_data()
