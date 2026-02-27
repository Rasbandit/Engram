#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/rasbandit/brain-api"
SERVER="root@10.0.20.214"
CONTAINER="brain-api"
TEMPLATE="/boot/config/plugins/dockerMan/templates-user/my-brain-api.xml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_DIR="$HOME/.claude/projects/-home-open-claw/memory"

cd "${SCRIPT_DIR}"

# --- Require version argument ---
CURRENT=$(grep 'Current version' CLAUDE.md | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")

if [[ $# -lt 1 ]]; then
  echo "Usage: ./deploy.sh <version>"
  echo "Current version: ${CURRENT}"
  exit 1
fi
VERSION="$1"

if [[ "${VERSION}" == "${CURRENT}" ]]; then
  echo "Error: version ${VERSION} is already the current version. Bump it."
  exit 1
fi

echo "==> Deploying brain-api ${VERSION}"

# --- Build ---
echo "--- Building image..."
docker compose build brain-api --quiet 2>&1 | tail -1

# --- Tag & push ---
echo "--- Tagging and pushing to GHCR..."
docker tag edi-brain-brain-api:latest "${REGISTRY}:${VERSION}"
docker tag edi-brain-brain-api:latest "${REGISTRY}:latest"
docker push "${REGISTRY}:${VERSION}" --quiet
docker push "${REGISTRY}:latest" --quiet

# --- Deploy to FastRaid ---
echo "--- Pulling on FastRaid..."
ssh "${SERVER}" "docker pull ${REGISTRY}:${VERSION}" >/dev/null

echo "--- Replacing container..."
ssh "${SERVER}" "docker stop ${CONTAINER} && docker rm ${CONTAINER}" >/dev/null 2>&1 || true

ssh "${SERVER}" "docker run -d \
  --name ${CONTAINER} \
  --network ai \
  -p 8000:8000 \
  -e TZ=America/Los_Angeles \
  -e EMBED_MODEL=nomic-embed-text \
  -e HOST_OS=Unraid \
  -e HOST_HOSTNAME=unraid-fast \
  -e HOST_CONTAINERNAME=${CONTAINER} \
  -e OLLAMA_URL=http://ollama:11434 \
  -e QDRANT_URL=http://qdrant:6333 \
  -e JINA_URL=http://jinareranker:8082 \
  -e COLLECTION=obsidian_notes \
  -e LOG_LEVEL=INFO \
  --log-opt max-size=50m \
  --log-opt max-file=1 \
  -l net.unraid.docker.managed=dockerman \
  ${REGISTRY}:${VERSION}" >/dev/null

# --- Update Unraid template ---
echo "--- Updating Unraid template XML..."
ssh "${SERVER}" "sed -i 's|brain-api:[0-9.]*|brain-api:${VERSION}|' ${TEMPLATE}"

# --- Update version in docs ---
echo "--- Updating version references..."
sed -i "s#Current version | [0-9.]*#Current version | ${VERSION}#" "${SCRIPT_DIR}/CLAUDE.md"
sed -i "s#brain-api current version\*\*: [0-9.]*#brain-api current version**: ${VERSION}#" "${MEMORY_DIR}/MEMORY.md"
sed -i "s#currently [0-9.]*)\$#currently ${VERSION})#" "${MEMORY_DIR}/servers.md"

# --- Tag the deploy commit ---
echo "--- Tagging git commit as v${VERSION}..."
git tag -a "v${VERSION}" -m "Deploy brain-api ${VERSION}"

# --- Verify ---
STATUS=$(ssh "${SERVER}" "docker ps --filter name=${CONTAINER} --format '{{.Image}} {{.Status}}'")
echo "--- Container: ${STATUS}"
echo "==> Done. brain-api ${VERSION} deployed."
