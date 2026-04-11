#!/bin/bash
# Deploy Engram to FastRaid (Unraid).
# Called by CI on merge to main, or manually via SSH.
#
# Uses Unraid's native update_container script to recreate just the
# engram container from its XML template after pulling the new image.
set -euo pipefail

IMAGE="ghcr.io/rasbandit/engram:latest"

echo "==> Pulling $IMAGE"
docker pull "$IMAGE"

echo "==> Updating engram container"
/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container engram

echo "==> Waiting for health check"
for i in $(seq 1 30); do
  if curl -sf http://localhost:8000/api/health > /dev/null 2>&1; then
    echo "Deploy successful — engram is healthy"
    exit 0
  fi
  sleep 2
done

echo "ERROR: Health check failed after 60s" >&2
docker logs --tail 50 engram 2>&1 || true
exit 1
