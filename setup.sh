#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# -- Secrets -------------------------------------------------------------------
if command -v op &>/dev/null && op account list &>/dev/null 2>&1; then
    op inject -i .env.tpl -o .env
    ok "Secrets injected from 1Password"
else
    if [[ ! -f .env ]]; then
        cp .env.tpl .env
        warn "1Password not available. Copied .env.tpl -> .env (edit manually)"
    fi
fi

# -- Build Docker image (for deploy to FastRaid) -------------------------------
if command -v docker &>/dev/null; then
    info "Building engram Docker image..."
    docker compose build engram 2>/dev/null || docker build -t engram:latest -f api/Dockerfile .
    ok "Docker image built"
else
    warn "Docker not found — skipping image build"
fi

ok "Setup complete (engram runs on FastRaid, not locally)"
