"""Unit tests for note_store.sanitize_path — TDD.

Tests are organized in tiers:
1. Existing behavior: illegal character stripping (should pass now)
2. Security: path traversal prevention (should FAIL until implementation is fixed)
3. Edge cases: empty segments, unicode, length limits
"""

from __future__ import annotations

import importlib
import re
import sys
import types
from unittest.mock import MagicMock

import pytest

# Stub out psycopg and pool so note_store can be imported without a database
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())

from note_store import sanitize_path


# ---------------------------------------------------------------------------
# Tier 1: Illegal character stripping (existing behavior)
# ---------------------------------------------------------------------------

class TestIllegalCharStripping:
    """Characters illegal on iOS/Android/Windows: \\:*?<>"|"""

    def test_strips_question_mark(self):
        assert sanitize_path("Notes/Why?.md") == "Notes/Why.md"

    def test_strips_asterisk(self):
        assert sanitize_path("Notes/Important*.md") == "Notes/Important.md"

    def test_strips_colon(self):
        assert sanitize_path("Notes/HH:MM.md") == "Notes/HHMM.md"

    def test_strips_angle_brackets(self):
        assert sanitize_path("Notes/<tag>.md") == "Notes/tag.md"

    def test_strips_double_quotes(self):
        assert sanitize_path('Notes/"quoted".md') == "Notes/quoted.md"

    def test_strips_pipe(self):
        assert sanitize_path("Notes/A|B.md") == "Notes/AB.md"

    def test_strips_backslash(self):
        assert sanitize_path("Notes/A\\B.md") == "Notes/AB.md"

    def test_strips_multiple_illegal_chars(self):
        assert sanitize_path('Notes/What: A "Great" Day*.md') == "Notes/What A Great Day.md"

    def test_preserves_forward_slash(self):
        assert sanitize_path("A/B/C.md") == "A/B/C.md"

    def test_collapses_multiple_spaces(self):
        assert sanitize_path("Notes/Too   Many  Spaces.md") == "Notes/Too Many Spaces.md"

    def test_strips_leading_trailing_spaces_per_segment(self):
        # " Padded .md" → strip → "Padded .md" (interior space before .md is preserved)
        assert sanitize_path("Notes/ Padded .md") == "Notes/Padded .md"

    def test_strips_leading_trailing_only(self):
        assert sanitize_path("Notes/  Hello  ") == "Notes/Hello"

    def test_no_change_for_clean_path(self):
        assert sanitize_path("Notes/Clean File.md") == "Notes/Clean File.md"

    def test_single_segment_no_folder(self):
        assert sanitize_path("Inbox.md") == "Inbox.md"


# ---------------------------------------------------------------------------
# Tier 2: Path traversal prevention (SECURITY)
# ---------------------------------------------------------------------------

class TestPathTraversal:
    """sanitize_path must prevent directory traversal attacks."""

    def test_strips_parent_directory_traversal(self):
        result = sanitize_path("../../../etc/passwd")
        assert ".." not in result

    def test_strips_dot_dot_in_middle(self):
        result = sanitize_path("Notes/../../../etc/passwd")
        assert ".." not in result

    def test_strips_dot_dot_at_end(self):
        result = sanitize_path("Notes/Subfolder/..")
        assert ".." not in result

    def test_rejects_absolute_path(self):
        """Absolute paths should have leading slash stripped."""
        result = sanitize_path("/etc/passwd")
        assert not result.startswith("/")

    def test_strips_windows_drive_letter(self):
        """C:\\Windows style paths — backslash already stripped, but C: colon too."""
        result = sanitize_path("C:\\Windows\\System32")
        # Backslash and colon are illegal chars, so should be stripped
        assert "\\" not in result
        assert ":" not in result

    def test_double_dot_with_spaces(self):
        """Attacker might use spaces around dots: '. .'"""
        result = sanitize_path("Notes/. ./. ./secret")
        assert ". ." not in result

    def test_encoded_traversal_dots_only(self):
        """Plain dot-dot segments must be caught."""
        result = sanitize_path("Notes/..%2F..%2Fetc/passwd")
        # The %2F won't become / (no URL decoding), but .. must still be stripped
        assert ".." not in result


# ---------------------------------------------------------------------------
# Tier 3: Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    def test_empty_string(self):
        result = sanitize_path("")
        assert result == ""

    def test_single_dot_segment(self):
        """Current directory reference — should be stripped or preserved harmlessly."""
        result = sanitize_path("Notes/./File.md")
        assert "//" not in result or result == "Notes/File.md"

    def test_empty_segments_collapsed(self):
        """Double slashes should not produce empty path segments."""
        result = sanitize_path("Notes//File.md")
        assert "//" not in result

    def test_unicode_preserved(self):
        assert sanitize_path("Notes/日本語.md") == "Notes/日本語.md"

    def test_emoji_preserved(self):
        assert sanitize_path("Notes/🧠 Brain Dump.md") == "Notes/🧠 Brain Dump.md"

    def test_diacritics_preserved(self):
        assert sanitize_path("Notes/café résumé.md") == "Notes/café résumé.md"

    def test_all_illegal_chars_produces_nonempty(self):
        """A segment of only illegal chars should not produce an empty segment."""
        result = sanitize_path('Notes/***???.md')
        # Should produce "Notes/.md" at minimum — the .md extension survives
        assert result != ""
        assert "//" not in result

    def test_very_long_path_segment(self):
        """Filesystem limit is typically 255 bytes per segment."""
        long_name = "A" * 300 + ".md"
        result = sanitize_path(f"Notes/{long_name}")
        segment = result.split("/")[-1]
        assert len(segment.encode("utf-8")) <= 255

    def test_trailing_slash_stripped(self):
        """Trailing slashes produce empty segments which get filtered."""
        result = sanitize_path("Notes/Subfolder/")
        assert result == "Notes/Subfolder"
