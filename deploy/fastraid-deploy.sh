#!/bin/bash
# Deploy Engram to FastRaid (Unraid).
# Called by CI on merge to main, or manually via SSH.
#
# Usage: bash fastraid-deploy.sh <version>
#   version: semver from mix.exs (e.g. 0.1.9)
#
# Pulls the exact version tag from GHCR, updates the Unraid container
# template to pin that version, then recreates the container via Unraid's
# update_container (which handles stop → remove → run automatically).
set -euo pipefail

VERSION="${1:?Usage: fastraid-deploy.sh <version>}"
IMAGE="ghcr.io/rasbandit/engram"
TEMPLATE="/boot/config/plugins/dockerMan/templates-user/my-engram.xml"

echo "==> Pulling ${IMAGE}:${VERSION}"
docker pull "${IMAGE}:${VERSION}"

# Update Unraid XML template to pin the deployed version
if [ -f "$TEMPLATE" ]; then
  sed -i "s|<Repository>${IMAGE}:[^<]*</Repository>|<Repository>${IMAGE}:${VERSION}</Repository>|" "$TEMPLATE"
  echo "==> Updated Unraid template to ${IMAGE}:${VERSION}"
else
  echo "WARN: Unraid template not found at ${TEMPLATE}" >&2
fi

# Tag as :latest locally so Unraid UI shows consistent state
docker tag "${IMAGE}:${VERSION}" "${IMAGE}:latest"

# Let update_container handle the full lifecycle (stop → remove → run).
# It only auto-starts if the container was running when it begins, so the
# container must still be running at this point — do NOT stop/rm beforehand.
echo "==> Updating engram container"
/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container engram

echo "==> Waiting for health check (version ${VERSION})"
for i in $(seq 1 30); do
  HEALTH=$(curl -sf http://localhost:8000/api/health 2>/dev/null || true)
  if [ -n "$HEALTH" ]; then
    RUNNING_VERSION=$(echo "$HEALTH" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
    if [ "$RUNNING_VERSION" = "$VERSION" ]; then
      echo "Deploy successful — engram ${VERSION} is healthy"
      exit 0
    elif [ -n "$RUNNING_VERSION" ]; then
      echo "WARN: Health OK but version mismatch: expected ${VERSION}, got ${RUNNING_VERSION}"
    fi
  fi
  sleep 2
done

echo "ERROR: Health check failed or version mismatch after 60s" >&2
docker logs --tail 50 engram 2>&1 || true
exit 1
