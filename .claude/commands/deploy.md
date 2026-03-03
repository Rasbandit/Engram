---
description: Deploy engram with auto-determined semver version
allowed-tools: Bash, Read, Grep, Glob
---

# Deploy Engram

## Current state

**Current version**: !`grep 'Current version' CLAUDE.md | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'`

**Last deploy tag**: !`git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "none"`

**Changes since last deploy**:
!`LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo ""); if [ -n "$LAST_TAG" ]; then git log --oneline "$LAST_TAG..HEAD"; else echo "No previous tag found — all commits will be included"; git log --oneline -10; fi`

**Files changed**:
!`LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo ""); if [ -n "$LAST_TAG" ]; then git diff --stat "$LAST_TAG..HEAD"; else echo "No previous tag"; fi`

## Your task

Analyze the changes above and determine the appropriate semver bump:

- **patch** (x.y.Z): Bug fixes, refactors, dependency updates, config tweaks, doc changes
- **minor** (x.Y.0): New features — new API endpoints, new MCP tools, new capabilities, new env vars
- **major** (X.0.0): Breaking changes — removed/renamed endpoints or MCP tools, changed request/response schemas, incompatible API changes

Compute the next version number from the current version and your chosen bump level.

Then deploy by running:
```
cd ~/documents/code-projects/edi-brain && ./deploy.sh <version>
```

If there are no changes since the last deploy tag, tell the user there's nothing to deploy.

Do not ask for confirmation. Just determine the version and deploy.
