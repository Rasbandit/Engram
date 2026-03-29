"""Unit test conftest — no infrastructure required.

These tests run without Obsidian, the backend, or any Docker containers.
They test helper logic in isolation using mocks.
"""

import sys
from pathlib import Path

# Add e2e root to sys.path so `from helpers.cleanup import ...` works
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
