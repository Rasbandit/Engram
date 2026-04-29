#!/usr/bin/env bash
# Point this clone's git hooks at .githooks/ in the repo. Run once after
# cloning; idempotent.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/*
echo "✓ Git hooks installed: $(git config core.hooksPath)"
