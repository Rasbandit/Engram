#!/usr/bin/env bash
# Runner bootstrap — run once on the self-hosted runner to pre-install
# tooling that CI would otherwise download every run.
#
# Usage: sudo bash .github/setup-runner.sh
#
# After running, the CI workflow skips install steps when it detects
# the tools are already present.
set -euo pipefail

echo "=== Engram CI Runner Setup ==="

DOCKER_REGISTRY="10.0.20.214:5000"
NPM_REGISTRY="http://10.0.20.214:4873"

# ── Docker insecure registry ─────────────────────────────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
if ! grep -q "$DOCKER_REGISTRY" "$DAEMON_JSON" 2>/dev/null; then
  echo "Adding ${DOCKER_REGISTRY} as insecure registry..."
  if [ -f "$DAEMON_JSON" ]; then
    # Merge into existing config
    python3 -c "
import json
with open('$DAEMON_JSON') as f: cfg = json.load(f)
regs = cfg.setdefault('insecure-registries', [])
if '$DOCKER_REGISTRY' not in regs: regs.append('$DOCKER_REGISTRY')
with open('$DAEMON_JSON', 'w') as f: json.dump(cfg, f, indent=2)
"
  else
    echo '{"insecure-registries": ["'"$DOCKER_REGISTRY"'"]}' > "$DAEMON_JSON"
  fi
  echo "Restarting Docker daemon..."
  systemctl restart docker
else
  echo "Docker already trusts ${DOCKER_REGISTRY}"
fi

# ── Python packages (pytest, playwright, requests) ───────────────────────
echo "Installing Python packages..."
pip3 install --upgrade 'playwright>=1.48' pytest requests

echo "Installing Playwright Chromium..."
python3 -m playwright install --with-deps chromium

# ── Seed local Docker registry ───────────────────────────────────────────
echo "Pushing CI images to local Docker registry (${DOCKER_REGISTRY})..."
for img in postgres:16-alpine qdrant/qdrant:v1.17.1 node:20-slim; do
  local_tag="${DOCKER_REGISTRY}/${img}"
  docker pull "$img"
  docker tag "$img" "$local_tag"
  docker push "$local_tag"
  echo "  ✓ ${local_tag}"
done

echo "Configuring npm to use local Verdaccio registry..."
npm config set registry "$NPM_REGISTRY"

# ── Claude Code CLI ──────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code
else
  echo "Claude Code CLI already installed: $(claude --version)"
fi

# ── Verify ───────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Python:     $(python3 --version)"
echo "Playwright: $(python3 -m playwright --version)"
echo "pytest:     $(python3 -m pytest --version)"
echo "Docker:     $(docker --version)"
echo "Claude:     $(claude --version 2>/dev/null || echo 'not found')"
echo ""
echo "Docker images:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'postgres|qdrant|node'
echo ""
echo "=== Runner setup complete ==="
