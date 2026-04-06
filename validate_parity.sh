#!/usr/bin/env bash
# ============================================================================
# Parity Validation Script
# ============================================================================
# Validates dev-prod parity by testing real services: MinIO, Qdrant (1024d
# binary quant), Voyage AI (asymmetric retrieval), and the app pipeline.
#
# Usage:
#   VOYAGE_API_KEY=xxx bash validate_parity.sh
#   ENGRAM_URL=http://localhost:8100/api VOYAGE_API_KEY=xxx bash validate_parity.sh
# ============================================================================

set -euo pipefail

ENGRAM_URL="${ENGRAM_URL:-http://localhost:8000}"
MINIO_URL="${MINIO_URL:-http://10.0.20.214:9768}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-ec26ada693c2e9a}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-a50d0fac00c4515}"
QDRANT_URL="${QDRANT_URL:-http://10.0.20.214:6333}"
QDRANT_COLLECTION="${QDRANT_COLLECTION:-obsidian_notes_v2}"
VOYAGE_API_KEY="${VOYAGE_API_KEY:?VOYAGE_API_KEY is required}"

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+="  ✗ $1\n"; echo "  ✗ $1"; }

assert_status() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc (HTTP $actual)"
    else
        fail "$desc — expected HTTP $expected, got $actual"
    fi
}

# ============================================================================
# 1. MinIO
# ============================================================================
echo ""
echo "=== 1. MinIO ==="

STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${MINIO_URL}/minio/health/live" 2>/dev/null || echo "000")
if [[ "$STATUS" == "200" ]]; then
    pass "MinIO health (HTTP $STATUS)"
else
    fail "MinIO health — expected 200, got $STATUS"
fi

PARITY_OBJ="parity-test/validate-$(date +%s).txt"
PARITY_DATA="parity-validation-$(date +%s)"

MC_OUTPUT=$(docker run --rm --network host --entrypoint /bin/sh minio/mc:latest -c "
  mc alias set local ${MINIO_URL} ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} 2>/dev/null
  echo '${PARITY_DATA}' | mc pipe local/engram-attachments/${PARITY_OBJ} 2>&1
  mc cat local/engram-attachments/${PARITY_OBJ} 2>&1
  mc rm local/engram-attachments/${PARITY_OBJ} 2>&1
" 2>&1)

if echo "$MC_OUTPUT" | grep -q "$PARITY_DATA"; then
    pass "MinIO put/get/delete round-trip"
else
    fail "MinIO round-trip failed"
fi

# ============================================================================
# 2. Qdrant
# ============================================================================
echo ""
echo "=== 2. Qdrant ==="

RESP=$(curl -s "${QDRANT_URL}/collections/${QDRANT_COLLECTION}")
VECTORS_SIZE=$(echo "$RESP" | jq -r '.result.config.params.vectors.size' 2>/dev/null || echo "null")
QUANT=$(echo "$RESP" | jq -r '.result.config.quantization_config.binary.always_ram' 2>/dev/null || echo "null")

if [[ "$VECTORS_SIZE" == "1024" ]]; then
    pass "Qdrant ${QDRANT_COLLECTION} — size=$VECTORS_SIZE"
else
    fail "Qdrant size — expected 1024, got $VECTORS_SIZE"
fi

if [[ "$QUANT" == "true" ]]; then
    pass "Qdrant binary quantization (always_ram=true)"
else
    fail "Qdrant binary quant — expected true, got $QUANT"
fi

# ============================================================================
# 3. Voyage AI
# ============================================================================
echo ""
echo "=== 3. Voyage AI ==="

RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.voyageai.com/v1/embeddings" \
    -H "Authorization: Bearer ${VOYAGE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"input": ["parity test"], "model": "voyage-4-large"}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "Voyage embed (voyage-4-large)" 200 "$STATUS"

DOC_DIMS=$(echo "$BODY" | jq '.data[0].embedding | length' 2>/dev/null || echo "0")
if [[ "$DOC_DIMS" == "1024" ]]; then
    pass "voyage-4-large → ${DOC_DIMS}d vector"
else
    fail "voyage-4-large — expected 1024d, got ${DOC_DIMS}d"
fi

RESP=$(curl -s -w "\n%{http_code}" -X POST "https://api.voyageai.com/v1/embeddings" \
    -H "Authorization: Bearer ${VOYAGE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"input": ["parity test"], "model": "voyage-4-lite"}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "Voyage embed (voyage-4-lite)" 200 "$STATUS"

QUERY_DIMS=$(echo "$BODY" | jq '.data[0].embedding | length' 2>/dev/null || echo "0")
if [[ "$QUERY_DIMS" == "1024" ]]; then
    pass "voyage-4-lite → ${QUERY_DIMS}d vector"
else
    fail "voyage-4-lite — expected 1024d, got ${QUERY_DIMS}d"
fi

# ============================================================================
# 4. App Endpoints
# ============================================================================
echo ""
echo "=== 4. App ==="

RESP=$(curl -s -w "\n%{http_code}" "${ENGRAM_URL}/health" 2>/dev/null || echo -e "\n000")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /health" 200 "$STATUS"

TIMESTAMP=$(date +%s)
RESP=$(curl -s -w "\n%{http_code}" -X POST "${ENGRAM_URL}/users/register" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"parity_${TIMESTAMP}@test.local\",\"password\":\"paritytest123456\",\"display_name\":\"Parity\"}")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
JWT_TOKEN=$(echo "$BODY" | jq -r '.token' 2>/dev/null || echo "")

if [[ -n "$JWT_TOKEN" && "$JWT_TOKEN" != "null" ]]; then
    pass "Register test user"
else
    fail "Register user (HTTP $STATUS)"
fi

RESP=$(curl -s -X POST "${ENGRAM_URL}/api-keys" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JWT_TOKEN" \
    -d '{"name": "parity-key"}')
API_KEY=$(echo "$RESP" | jq -r '.key' 2>/dev/null || echo "")

if [[ -n "$API_KEY" && "$API_KEY" != "null" ]]; then
    pass "Create API key"
else
    fail "Create API key"
fi

# ============================================================================
# 5. Attachment via S3
# ============================================================================
echo ""
echo "=== 5. Attachment via S3 ==="

SMALL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

RESP=$(curl -s -w "\n%{http_code}" -X POST "${ENGRAM_URL}/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/parity-test.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709234900.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /attachments (upload)" 200 "$STATUS"

RESP=$(curl -s -w "\n%{http_code}" "${ENGRAM_URL}/attachments/Assets/parity-test.png" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments (download)" 200 "$STATUS"

DOWNLOADED_B64=$(echo "$BODY" | jq -r '.content_base64' 2>/dev/null || echo "")
if [[ "$DOWNLOADED_B64" == "$SMALL_PNG_B64" ]]; then
    pass "Attachment content matches"
else
    fail "Attachment content mismatch"
fi

# ============================================================================
# RESULTS
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          PARITY VALIDATION RESULTS               ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║  Passed: %-3d  Failed: %-3d                       ║\n" "$PASS" "$FAIL"
echo "╚══════════════════════════════════════════════════╝"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
exit 0
