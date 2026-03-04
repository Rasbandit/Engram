#!/usr/bin/env bash
set -euo pipefail

# --- Configurable via environment ---
REGISTRY="${ENGRAM_REGISTRY:?Set ENGRAM_REGISTRY (e.g. ghcr.io/youruser/engram)}"
SERVER="${DEPLOY_SERVER:?Set DEPLOY_SERVER (e.g. user@host)}"
REMOTE_DIR="${DEPLOY_DIR:-/opt/engram}"
DOCKER_NETWORK="${DOCKER_NETWORK:-ai}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$HOME/documents/code-projects/brain-obsidian-sync}"

cd "${SCRIPT_DIR}"

# --- Require version argument ---
CURRENT=$(grep 'Current version' CLAUDE.md | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")

if [[ $# -lt 1 ]]; then
  echo "Usage: ./deploy.sh <version>"
  echo "Current version: ${CURRENT}"
  echo ""
  echo "Required environment variables:"
  echo "  ENGRAM_REGISTRY — container registry path (e.g. ghcr.io/youruser/engram)"
  echo "  DEPLOY_SERVER   — SSH target (e.g. user@host)"
  echo ""
  echo "Optional environment variables:"
  echo "  DEPLOY_DIR      — remote directory (default: /opt/engram)"
  echo "  DOCKER_NETWORK  — Docker network name (default: ai)"
  echo "  PLUGIN_DIR      — local path to brain-obsidian-sync repo"
  exit 1
fi
VERSION="$1"

if [[ "${VERSION}" == "${CURRENT}" ]]; then
  echo "Error: version ${VERSION} is already the current version. Bump it."
  exit 1
fi

echo "==> Deploying engram ${VERSION}"

# ===========================================================================
# PART 1: engram — build, push, deploy to remote server
# ===========================================================================

# --- Build ---
echo "--- Building image..."
docker compose build engram --quiet 2>&1 | tail -1

# --- Tag & push ---
echo "--- Tagging and pushing to registry..."
docker tag edi-brain-engram:latest "${REGISTRY}:${VERSION}"
docker tag edi-brain-engram:latest "${REGISTRY}:latest"
docker push "${REGISTRY}:${VERSION}" --quiet
docker push "${REGISTRY}:latest" --quiet

# --- Deploy to remote server ---
echo "--- Deploying to ${SERVER}..."
ssh "${SERVER}" "mkdir -p ${REMOTE_DIR}"
scp docker-compose.prod.yml "${SERVER}:${REMOTE_DIR}/docker-compose.yml"

# Ensure .env has JWT_SECRET and VERSION
ssh "${SERVER}" "cd ${REMOTE_DIR} && \
  if [ -f .env ]; then \
    sed -i 's/^VERSION=.*/VERSION=${VERSION}/' .env; \
    grep -q ENGRAM_IMAGE .env || echo 'ENGRAM_IMAGE=${REGISTRY}' >> .env; \
  else \
    echo 'VERSION=${VERSION}' > .env; \
    echo 'ENGRAM_IMAGE=${REGISTRY}' >> .env; \
    echo 'JWT_SECRET='$(openssl rand -base64 32) >> .env; \
  fi"

# Read JWT_SECRET from remote
JWT_SECRET=$(ssh "${SERVER}" "grep JWT_SECRET ${REMOTE_DIR}/.env | cut -d= -f2")

echo "--- Pulling image on remote..."
ssh "${SERVER}" "docker pull ${REGISTRY}:${VERSION}"

echo "--- Ensuring engram-redis is running..."
ssh "${SERVER}" "docker inspect engram-redis >/dev/null 2>&1 || \
  docker run -d \
    --name engram-redis \
    --network ${DOCKER_NETWORK} \
    --log-opt max-size=50m \
    --log-opt max-file=1 \
    --restart unless-stopped \
    --label net.unraid.docker.managed=dockerman \
    redis:7-alpine redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru"

echo "--- Replacing engram container..."
ssh "${SERVER}" "docker stop engram 2>/dev/null || true && docker rm engram 2>/dev/null || true"
ssh "${SERVER}" "docker run -d \
  --name engram \
  --network ${DOCKER_NETWORK} \
  -p 8000:8000 \
  --log-opt max-size=50m \
  --log-opt max-file=1 \
  --restart unless-stopped \
  --label net.unraid.docker.managed=dockerman \
  --label 'net.unraid.docker.webui=http://[IP]:[PORT:8000]/' \
  -e TZ=America/Los_Angeles \
  -e EMBED_MODEL=nomic-embed-text \
  -e EMBED_BACKEND=ollama \
  -e 'DATABASE_URL=postgresql://engram:engram@engram-postgres:5432/engram' \
  -e 'JWT_SECRET=${JWT_SECRET}' \
  -e REGISTRATION_ENABLED=true \
  -e 'OLLAMA_URL=http://ollama:11434' \
  -e 'QDRANT_URL=http://qdrant:6333' \
  -e 'JINA_URL=http://jina-reranker:8082' \
  -e COLLECTION=obsidian_notes \
  -e LOG_LEVEL=INFO \
  -e 'REDIS_URL=redis://engram-redis:6379/0' \
  ${REGISTRY}:${VERSION}"

# --- Verify API is healthy ---
REMOTE_HOST="${SERVER#*@}"
echo "--- Waiting for API to start..."
sleep 3
if curl -sf "http://${REMOTE_HOST}:8000/health" > /dev/null 2>&1; then
  echo "--- engram healthy"
else
  echo "!!! engram health check failed — check logs on remote server"
fi

# ===========================================================================
# PART 2: Obsidian plugin — build, release (if plugin has changes)
# ===========================================================================

if [[ -d "${PLUGIN_DIR}" ]]; then
  cd "${PLUGIN_DIR}"
  PLUGIN_CURRENT=$(grep '"version"' manifest.json | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')

  # Check for uncommitted plugin changes
  if [[ -n "$(git status --porcelain)" ]]; then
    echo ""
    echo "==> Plugin has uncommitted changes — building and releasing..."

    # Bump plugin version: increment patch
    IFS='.' read -r PMAJ PMIN PPATCH <<< "${PLUGIN_CURRENT}"
    PLUGIN_VERSION="${PMAJ}.${PMIN}.$((PPATCH + 1))"

    echo "--- Bumping plugin ${PLUGIN_CURRENT} → ${PLUGIN_VERSION}"
    sed -i "s/\"version\": \"${PLUGIN_CURRENT}\"/\"version\": \"${PLUGIN_VERSION}\"/" manifest.json
    sed -i "s/\"version\": \"${PLUGIN_CURRENT}\"/\"version\": \"${PLUGIN_VERSION}\"/" package.json

    # Add new version to versions.json
    python3 -c "
import json
with open('versions.json') as f: v = json.load(f)
v['${PLUGIN_VERSION}'] = v.get('${PLUGIN_CURRENT}', '1.0.0')
with open('versions.json', 'w') as f: json.dump(v, f, indent=2)
"

    # Build
    echo "--- Building plugin..."
    npm run build --silent

    # Run tests
    echo "--- Running plugin tests..."
    npm test --silent

    # Commit, tag, push
    git add -A
    git commit -m "Release ${PLUGIN_VERSION} (with engram ${VERSION})" \
      --author="deploy.sh <noreply@anthropic.com>"
    git tag -a "${PLUGIN_VERSION}" -m "v${PLUGIN_VERSION}"
    git push origin main --tags

    # Create GitHub release with built assets (BRAT needs this)
    echo "--- Creating GitHub release ${PLUGIN_VERSION}..."
    gh release create "${PLUGIN_VERSION}" main.js manifest.json \
      --title "${PLUGIN_VERSION}" \
      --notes "Released with engram ${VERSION}. Update via BRAT."

    echo "==> Plugin ${PLUGIN_VERSION} released — BRAT will pick it up."
  else
    echo ""
    echo "--- Plugin has no changes (${PLUGIN_CURRENT}), skipping."
  fi

  cd "${SCRIPT_DIR}"
fi

# ===========================================================================
# PART 3: Update docs and tag
# ===========================================================================

echo "--- Updating version references..."
sed -i "s#Current version | [0-9.]*#Current version | ${VERSION}#" "${SCRIPT_DIR}/CLAUDE.md"

# --- Tag the deploy commit ---
echo "--- Tagging git commit as v${VERSION}..."
git tag -a "v${VERSION}" -m "Deploy engram ${VERSION}" 2>/dev/null || true

# --- Final status ---
echo ""
STATUS=$(ssh "${SERVER}" "docker ps --filter name=engram --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'" 2>/dev/null)
echo "--- Containers on ${SERVER}:"
echo "${STATUS}"
echo ""
echo "==> Done. engram ${VERSION} deployed."
