#!/usr/bin/env bash
set -euo pipefail

REGISTRY="ghcr.io/rasbandit/brain-api"
SERVER="root@10.0.20.214"
CONTAINER="brain-api"
TEMPLATE="/boot/config/plugins/dockerMan/templates-user/my-brain-api.xml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_DIR="$HOME/.claude/projects/-home-open-claw/memory"

cd "${SCRIPT_DIR}"

# --- Read current version ---
CURRENT=$(grep 'Current version' CLAUDE.md | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
IFS='.' read -r CUR_MAJOR CUR_MINOR CUR_PATCH <<< "${CURRENT}"

# --- Determine version ---
if [[ $# -ge 1 && "$1" != "--auto" ]]; then
  # Explicit version provided
  VERSION="$1"
else
  # Auto-detect from git diff
  LAST_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo "")

  if [[ -z "${LAST_TAG}" ]]; then
    DIFF_REF="$(git rev-list --max-parents=0 HEAD)"
  else
    DIFF_REF="${LAST_TAG}"
  fi

  LOG=$(git log "${DIFF_REF}..HEAD" --oneline 2>/dev/null || echo "")
  CHANGED_FILES=$(git diff --name-status "${DIFF_REF}..HEAD" 2>/dev/null || echo "")

  if [[ -z "${LOG}" ]]; then
    echo "No changes since last deploy (${CURRENT}). Nothing to do."
    exit 0
  fi

  # Classify bump
  BUMP="patch"

  # Check for new files (minor)
  if echo "${CHANGED_FILES}" | grep -qP '^A\s'; then
    BUMP="minor"
  fi

  # Check commit messages for feature keywords (minor)
  if echo "${LOG}" | grep -qiP '\b(feat|add|new)\b'; then
    BUMP="minor"
  fi

  # Check for breaking changes (major)
  if echo "${LOG}" | grep -qiP '(BREAKING|breaking.change)'; then
    BUMP="major"
  fi

  # Check for deleted api files (major)
  if echo "${CHANGED_FILES}" | grep -qP '^D\s+api/'; then
    BUMP="major"
  fi

  # Compute next version
  case "${BUMP}" in
    major) VERSION="$((CUR_MAJOR + 1)).0.0" ;;
    minor) VERSION="${CUR_MAJOR}.$((CUR_MINOR + 1)).0" ;;
    patch) VERSION="${CUR_MAJOR}.${CUR_MINOR}.$((CUR_PATCH + 1))" ;;
  esac

  echo "--- Auto-detected bump: ${BUMP} (${CURRENT} -> ${VERSION})"
  echo "--- Changes since ${LAST_TAG:-initial}:"
  echo "${LOG}" | sed 's/^/    /'
fi

# Guard against reusing current version
if [[ "${VERSION}" == "${CURRENT}" ]]; then
  echo "Error: version ${VERSION} is already the current version. Bump it."
  exit 1
fi

echo "==> Deploying brain-api ${VERSION}"

# --- Build ---
echo "--- Building image..."
docker compose build brain-api --quiet 2>&1 | tail -1

# --- Tag & push ---
echo "--- Tagging ${REGISTRY}:${VERSION} and :latest..."
docker tag edi-brain-brain-api:latest "${REGISTRY}:${VERSION}"
docker tag edi-brain-brain-api:latest "${REGISTRY}:latest"

echo "--- Pushing to GHCR..."
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
sed -i "s|Current version | [0-9.]*|Current version | ${VERSION}|" "${SCRIPT_DIR}/CLAUDE.md"
sed -i "s|brain-api current version\*\*: [0-9.]*|brain-api current version**: ${VERSION}|" "${MEMORY_DIR}/MEMORY.md"
sed -i "s|currently [0-9.]*)|currently ${VERSION})|" "${MEMORY_DIR}/servers.md"

# --- Tag the deploy commit ---
echo "--- Tagging git commit as v${VERSION}..."
git tag -a "v${VERSION}" -m "Deploy brain-api ${VERSION}"

# --- Verify ---
STATUS=$(ssh "${SERVER}" "docker ps --filter name=${CONTAINER} --format '{{.Image}} {{.Status}}'")
echo "--- Container: ${STATUS}"
echo "==> Done. brain-api ${VERSION} deployed."
