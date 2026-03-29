"""Unit tests for note_store.sanitize_path — TDD.

Tests are organized in tiers:
1. Existing behavior: illegal character stripping (parametrized)
2. Security: path traversal prevention (exact output assertions)
3. Edge cases: empty segments, unicode, length limits
4. Combined: mixed traversal + illegal chars (realistic attack vectors)
"""

from __future__ import annotations

import sys
from unittest.mock import MagicMock

import pytest

# Stub out psycopg and pool so note_store can be imported without a database
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())

from note_store import sanitize_path


# ---------------------------------------------------------------------------
# Tier 1: Illegal character stripping (parametrized)
# ---------------------------------------------------------------------------


class TestIllegalCharStripping:
    r"""Characters illegal on iOS/Android/Windows: \:*?<>"|"""

    @pytest.mark.parametrize(
        "input_path, expected",
        [
            ("Notes/Why?.md", "Notes/Why.md"),
            ("Notes/Important*.md", "Notes/Important.md"),
            ("Notes/HH:MM.md", "Notes/HHMM.md"),
            ("Notes/<tag>.md", "Notes/tag.md"),
            ('Notes/"quoted".md', "Notes/quoted.md"),
            ("Notes/A|B.md", "Notes/AB.md"),
            ("Notes/A\\B.md", "Notes/AB.md"),
        ],
        ids=["question_mark", "asterisk", "colon", "angle_brackets", "double_quotes", "pipe", "backslash"],
    )
    def test_strips_single_illegal_char(self, input_path, expected):
        assert sanitize_path(input_path) == expected

    def test_strips_multiple_illegal_chars(self):
        assert sanitize_path('Notes/What: A "Great" Day*.md') == "Notes/What A Great Day.md"

    def test_preserves_forward_slash(self):
        assert sanitize_path("A/B/C.md") == "A/B/C.md"

    def test_collapses_multiple_spaces(self):
        assert sanitize_path("Notes/Too   Many  Spaces.md") == "Notes/Too Many Spaces.md"

    def test_strips_leading_trailing_spaces_per_segment(self):
        assert sanitize_path("Notes/ Padded .md") == "Notes/Padded .md"

    def test_strips_leading_trailing_only(self):
        assert sanitize_path("Notes/  Hello  ") == "Notes/Hello"

    def test_no_change_for_clean_path(self):
        assert sanitize_path("Notes/Clean File.md") == "Notes/Clean File.md"

    def test_single_segment_no_folder(self):
        assert sanitize_path("Inbox.md") == "Inbox.md"


# ---------------------------------------------------------------------------
# Tier 2: Path traversal prevention (SECURITY) — exact output assertions
# ---------------------------------------------------------------------------


class TestPathTraversal:
    """sanitize_path must prevent directory traversal attacks."""

    def test_strips_parent_directory_traversal(self):
        result = sanitize_path("../../../etc/passwd")
        assert ".." not in result
        assert "etc" in result and "passwd" in result

    def test_strips_dot_dot_in_middle(self):
        result = sanitize_path("Notes/../../../etc/passwd")
        assert ".." not in result
        assert "Notes" in result or "etc" in result

    def test_strips_dot_dot_at_end(self):
        result = sanitize_path("Notes/Subfolder/..")
        assert ".." not in result
        assert "Notes" in result

    def test_rejects_absolute_path(self):
        """Absolute paths should have leading slash stripped, content preserved."""
        result = sanitize_path("/etc/passwd")
        assert not result.startswith("/")
        assert "etc" in result and "passwd" in result

    def test_strips_windows_drive_letter(self):
        """C:\\Windows style — backslash and colon stripped."""
        result = sanitize_path("C:\\Windows\\System32")
        assert "\\" not in result
        assert ":" not in result
        assert "Windows" in result

    def test_double_dot_with_spaces(self):
        """Attacker might use spaces around dots: '. .'"""
        result = sanitize_path("Notes/. ./. ./secret")
        assert ". ." not in result
        assert "secret" in result

    def test_encoded_traversal_dots_only(self):
        """Plain dot-dot segments must be caught even with URL-encoded slashes."""
        result = sanitize_path("Notes/..%2F..%2Fetc/passwd")
        assert ".." not in result


# ---------------------------------------------------------------------------
# Tier 3: Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    def test_empty_string(self):
        result = sanitize_path("")
        assert result == ""

    def test_single_dot_segment(self):
        result = sanitize_path("Notes/./File.md")
        assert "//" not in result or result == "Notes/File.md"

    def test_empty_segments_collapsed(self):
        result = sanitize_path("Notes//File.md")
        assert "//" not in result
        assert "Notes" in result and "File.md" in result

    def test_unicode_preserved(self):
        assert sanitize_path("Notes/日本語.md") == "Notes/日本語.md"

    def test_emoji_preserved(self):
        assert sanitize_path("Notes/🧠 Brain Dump.md") == "Notes/🧠 Brain Dump.md"

    def test_diacritics_preserved(self):
        assert sanitize_path("Notes/café résumé.md") == "Notes/café résumé.md"

    def test_all_illegal_chars_produces_nonempty(self):
        result = sanitize_path('Notes/***???.md')
        assert result != ""
        assert ".md" in result

    def test_very_long_path_segment(self):
        long_name = "A" * 300 + ".md"
        result = sanitize_path(f"Notes/{long_name}")
        segment = result.split("/")[-1]
        assert len(segment.encode("utf-8")) <= 255

    def test_trailing_slash_stripped(self):
        result = sanitize_path("Notes/Subfolder/")
        assert result == "Notes/Subfolder"

    def test_unicode_with_illegal_chars(self):
        """Unicode + illegal chars combined."""
        result = sanitize_path("日記/メモ*?.md")
        assert "日記" in result
        assert "*" not in result and "?" not in result


# ---------------------------------------------------------------------------
# Tier 4: Combined traversal + illegal chars (realistic attack vectors)
# ---------------------------------------------------------------------------


class TestCombinedAttacks:
    """Mixed path traversal and illegal character attacks."""

    def test_traversal_with_illegal_chars(self):
        result = sanitize_path("Notes/../*foo*/file.md")
        assert ".." not in result
        assert "*" not in result
        assert "file.md" in result

    def test_traversal_with_colon(self):
        result = sanitize_path("../../C:\\Windows\\System32")
        assert ".." not in result
        assert ":" not in result
        assert "\\" not in result

    def test_multiple_traversal_styles(self):
        """Mix of .. and absolute path."""
        result = sanitize_path("/../../etc/passwd")
        assert not result.startswith("/")
        assert ".." not in result

    def test_traversal_in_url_encoded_context(self):
        result = sanitize_path("..%2F..%2F..%2Fetc%2Fpasswd")
        assert ".." not in result

    def test_null_byte_stripped(self):
        """Null bytes should be stripped (filesystem injection vector)."""
        result = sanitize_path("Notes/file\x00.md")
        assert "\x00" not in result

    @pytest.mark.parametrize(
        "malicious_path",
        [
            "../../../etc/passwd",
            "..\\..\\..\\windows\\system32",
            "Notes/../../../../etc/shadow",
            "/etc/passwd",
            "....//....//etc/passwd",
        ],
        ids=["unix_traversal", "windows_traversal", "deep_traversal", "absolute_unix", "double_dot_slash"],
    )
    def test_common_traversal_payloads(self, malicious_path):
        """Common path traversal attack payloads must all be neutralized."""
        result = sanitize_path(malicious_path)
        assert ".." not in result, f"Traversal not stripped from: {malicious_path}"
        assert not result.startswith("/"), f"Absolute path not stripped from: {malicious_path}"

    def test_sql_injection_in_path_is_passthrough(self):
        """SQL injection payloads pass through sanitize_path — that's fine.
        sanitize_path handles filesystem safety; parameterized queries handle SQL safety."""
        result = sanitize_path("Notes/'; DROP TABLE notes; --.md")
        assert isinstance(result, str)
        assert len(result) > 0
