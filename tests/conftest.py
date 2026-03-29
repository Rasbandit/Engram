"""Backend unit test conftest — pure logic tests, no database required."""

import sys
from pathlib import Path

# Add api/ to sys.path so `from note_store import sanitize_path` works
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "api"))
