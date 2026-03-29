"""Unit tests for note_store pure helper functions: _extract_title, _extract_tags, _extract_folder."""

from __future__ import annotations

import sys
from unittest.mock import MagicMock

# Stub DB dependencies
sys.modules.setdefault("psycopg", MagicMock())
sys.modules.setdefault("psycopg.errors", MagicMock())
sys.modules.setdefault("pool", MagicMock())

from note_store import _extract_title, _extract_tags, _extract_folder


# ---------------------------------------------------------------------------
# _extract_title
# ---------------------------------------------------------------------------

class TestExtractTitle:
    def test_from_frontmatter(self):
        content = "---\ntitle: My Custom Title\n---\n# Heading\nBody"
        assert _extract_title(content, "Notes/File.md") == "My Custom Title"

    def test_from_heading(self):
        content = "# My Heading\nBody text"
        assert _extract_title(content, "Notes/File.md") == "My Heading"

    def test_heading_with_extra_spaces(self):
        content = "#   Spaced Heading  \nBody"
        assert _extract_title(content, "Notes/File.md") == "Spaced Heading"

    def test_falls_back_to_filename(self):
        content = "Just body text, no heading"
        assert _extract_title(content, "Notes/My Note.md") == "My Note"

    def test_filename_without_folder(self):
        content = "Just body text"
        assert _extract_title(content, "Inbox.md") == "Inbox"

    def test_frontmatter_title_takes_priority(self):
        content = "---\ntitle: FM Title\n---\n# Heading Title\nBody"
        assert _extract_title(content, "Notes/File.md") == "FM Title"

    def test_empty_content_uses_filename(self):
        assert _extract_title("", "Notes/Empty.md") == "Empty"

    def test_frontmatter_only_no_heading(self):
        content = "---\ntags: [a, b]\n---\nBody text"
        assert _extract_title(content, "Notes/Tagged.md") == "Tagged"


# ---------------------------------------------------------------------------
# _extract_tags
# ---------------------------------------------------------------------------

class TestExtractTags:
    def test_list_tags(self):
        content = "---\ntags: [health, fitness]\n---\nBody"
        assert _extract_tags(content) == ["health", "fitness"]

    def test_string_tags(self):
        content = "---\ntags: health, fitness\n---\nBody"
        assert _extract_tags(content) == ["health", "fitness"]

    def test_no_tags(self):
        content = "# No Tags\nBody"
        assert _extract_tags(content) == []

    def test_empty_tags(self):
        content = "---\ntags: []\n---\nBody"
        assert _extract_tags(content) == []

    def test_empty_content(self):
        assert _extract_tags("") == []


# ---------------------------------------------------------------------------
# _extract_folder
# ---------------------------------------------------------------------------

class TestExtractFolder:
    def test_single_folder(self):
        assert _extract_folder("Notes/File.md") == "Notes"

    def test_nested_folder(self):
        assert _extract_folder("Notes/Sub/File.md") == "Notes/Sub"

    def test_no_folder(self):
        assert _extract_folder("File.md") == ""

    def test_deep_nesting(self):
        assert _extract_folder("A/B/C/D/File.md") == "A/B/C/D"
