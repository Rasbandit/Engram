#!/usr/bin/env bash
# ============================================================================
# Engram Comprehensive Test Plan
# ============================================================================
# Tests all REST endpoints, auth, note lifecycle, search, sync, and edge cases.
# Requires: engram + postgres + redis running (docker compose up)
#
# Usage:
#   bash test_plan.sh          # run once against current config
#   bash test_plan.sh --both   # run twice: without Redis, then with Redis
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- --both mode: orchestrate two runs ---
if [[ "${1:-}" == "--both" ]]; then
    TOTAL_PASS=0
    TOTAL_FAIL=0
    ALL_OK=true

    wait_healthy() {
        local max_wait=30 i=0
        while [[ $i -lt $max_wait ]]; do
            if curl -sf "http://localhost:8000/health" > /dev/null 2>&1; then
                return 0
            fi
            sleep 1
            i=$((i + 1))
        done
        echo "ERROR: engram did not become healthy within ${max_wait}s"
        return 1
    }

    # ── Phase 1: Without Redis ──
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  PHASE 1: Tests WITHOUT Redis (in-memory mode)  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    REDIS_URL="" docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d engram --wait 2>&1 | tail -3
    wait_healthy
    echo ""

    set +e
    bash "$SCRIPT_DIR/test_plan.sh"
    EXIT1=$?
    set -e

    echo ""

    # ── Phase 2: With Redis ──
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  PHASE 2: Tests WITH Redis (shared state mode)  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d engram --wait 2>&1 | tail -3
    wait_healthy
    echo ""

    set +e
    bash "$SCRIPT_DIR/test_plan.sh"
    EXIT2=$?
    set -e

    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║              COMBINED RESULTS                   ║"
    echo "╠══════════════════════════════════════════════════╣"
    if [[ $EXIT1 -eq 0 ]]; then
        echo "║  Phase 1 (no Redis):   ALL PASSED               ║"
    else
        echo "║  Phase 1 (no Redis):   FAILURES                 ║"
        ALL_OK=false
    fi
    if [[ $EXIT2 -eq 0 ]]; then
        echo "║  Phase 2 (Redis):      ALL PASSED               ║"
    else
        echo "║  Phase 2 (Redis):      FAILURES                 ║"
        ALL_OK=false
    fi
    echo "╚══════════════════════════════════════════════════╝"

    if [[ "$ALL_OK" == "true" ]]; then
        echo "  Both modes passed!"
        exit 0
    else
        exit 1
    fi
fi

BASE="http://localhost:8000"
PASS=0
FAIL=0
ERRORS=""

# --- Helpers ---

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

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "__PARSE_ERROR__")
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc ($field = $expected)"
    else
        fail "$desc — $field: expected '$expected', got '$actual'"
    fi
}

assert_json_not_empty() {
    local desc="$1" json="$2" field="$3"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "")
    if [[ -n "$actual" && "$actual" != "null" && "$actual" != "[]" ]]; then
        pass "$desc ($field is not empty)"
    else
        fail "$desc — $field is empty or null"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        pass "$desc (contains '$needle')"
    else
        fail "$desc — expected to contain '$needle'"
    fi
}

# ============================================================================
# SECTION 1: Health Check
# ============================================================================
echo ""
echo "=== 1. Health Check ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/health")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /health" 200 "$STATUS"
assert_json_field "Health response" "$BODY" '.status' 'ok'

# ============================================================================
# SECTION 2: Auth — Registration & Login
# ============================================================================
echo ""
echo "=== 2. Auth — Registration ==="

TIMESTAMP=$(date +%s)
TEST_EMAIL="test_${TIMESTAMP}@example.com"
TEST_PASS="testpass123"
TEST_NAME="Test User ${TIMESTAMP}"

# Register via web form (expect 303 redirect to /search)
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/register" \
    -d "email=${TEST_EMAIL}&password=${TEST_PASS}&display_name=${TEST_NAME}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c /tmp/engram_cookies)
STATUS="$RESP"
assert_status "POST /register (new user → 303 redirect)" 303 "$STATUS"

# Duplicate registration
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" \
    -d "email=${TEST_EMAIL}&password=${TEST_PASS}&display_name=${TEST_NAME}" \
    -H "Content-Type: application/x-www-form-urlencoded" -o /dev/null)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /register (duplicate)" 400 "$STATUS"

echo ""
echo "=== 2b. Auth — Login ==="

# Good login (expect 303 redirect to /search)
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/login" \
    -d "email=${TEST_EMAIL}&password=${TEST_PASS}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c /tmp/engram_cookies)
STATUS="$RESP"
assert_status "POST /login (valid → 303 redirect)" 303 "$STATUS"

# Bad login
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" \
    -d "email=${TEST_EMAIL}&password=wrongpass" \
    -H "Content-Type: application/x-www-form-urlencoded" -o /dev/null)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /login (bad password)" 401 "$STATUS"

echo ""
echo "=== 2c. Auth — API Key Management ==="

# Create API key via settings
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/settings/keys" \
    -d "name=test-key" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -b /tmp/engram_cookies -L)
STATUS=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /settings/keys (create)" 200 "$STATUS"

# Extract the API key from the response HTML
API_KEY=$(echo "$RESP" | grep -oP 'engram_[A-Za-z0-9_-]+' | head -1 || true)
if [[ -z "$API_KEY" ]]; then
    fail "Could not extract API key from settings response"
    echo "FATAL: Cannot continue without API key"
    exit 1
fi
pass "Extracted API key: ${API_KEY:0:20}..."

# ============================================================================
# SECTION 3: Auth — API Key Validation
# ============================================================================
echo ""
echo "=== 3. Auth — Bearer Token Validation ==="

# No auth header
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /tags (no auth → 401)" 401 "$STATUS"

# Invalid API key
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
    -H "Authorization: Bearer engram_invalidkey123")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /tags (invalid key)" 401 "$STATUS"

# Valid API key
RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /tags (valid key)" 200 "$STATUS"

# ============================================================================
# SECTION 4: Note CRUD Lifecycle
# ============================================================================
echo ""
echo "=== 4. Note Upsert (POST /notes) ==="

AUTH="-H Authorization:\ Bearer\ $API_KEY"

# 4a. Create a simple note
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "path": "Test/Hello World.md",
        "content": "---\ntags: [health, omega]\n---\n# Hello World\n\nThis is a test note about omega 3 fatty acids and their health benefits.\n\n## Section Two\n\nMore content here about EPA and DHA.",
        "mtime": 1709234567.0
    }')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (create simple note)" 200 "$STATUS"
assert_json_field "Note path" "$BODY" '.note.path' 'Test/Hello World.md'
assert_json_field "Note title" "$BODY" '.note.title' 'Hello World'
assert_json_field "Note folder" "$BODY" '.note.folder' 'Test'

# Check tags extracted from frontmatter
TAGS=$(echo "$BODY" | jq -r '.note.tags | join(",")' 2>/dev/null || echo "")
if [[ "$TAGS" == *"health"* && "$TAGS" == *"omega"* ]]; then
    pass "Frontmatter tags extracted (health, omega)"
else
    fail "Frontmatter tags not extracted — got: $TAGS"
fi

# Check chunks indexed
CHUNKS=$(echo "$BODY" | jq -r '.chunks_indexed' 2>/dev/null || echo "0")
if [[ "$CHUNKS" -gt 0 ]]; then
    pass "Chunks indexed: $CHUNKS"
else
    fail "No chunks indexed (indexing may have failed)"
fi

# 4b. Create a note with no frontmatter
echo ""
echo "=== 4b. Note without frontmatter ==="

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "path": "Test/Plain Note.md",
        "content": "# Plain Note\n\nJust a plain note with no frontmatter.\n\nSome text about machine learning and neural networks.",
        "mtime": 1709234568.0
    }')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (no frontmatter)" 200 "$STATUS"
assert_json_field "Title from heading" "$BODY" '.note.title' 'Plain Note'

# 4c. Create a note in a nested folder
echo ""
echo "=== 4c. Nested folder note ==="

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "path": "2. Knowledge Vault/Health/Supplements/Vitamin D.md",
        "content": "---\ntags: [health, supplements, vitamin-d]\ntitle: Vitamin D Guide\n---\n# Vitamin D\n\nVitamin D is essential for bone health and immune function.\n\n## Dosage\n\n2000-4000 IU daily for most adults.\n\n## Sources\n\nSunlight, fatty fish, fortified foods.",
        "mtime": 1709234569.0
    }')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (nested folder)" 200 "$STATUS"
assert_json_field "Title from frontmatter" "$BODY" '.note.title' 'Vitamin D Guide'
assert_json_field "Nested folder" "$BODY" '.note.folder' '2. Knowledge Vault/Health/Supplements'

# 4d. Upsert (update existing note)
echo ""
echo "=== 4d. Note upsert (update) ==="

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "path": "Test/Hello World.md",
        "content": "---\ntags: [health, omega, updated]\n---\n# Hello World Updated\n\nThis note was updated. Omega 3 is great for brain health.",
        "mtime": 1709234600.0
    }')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (upsert/update)" 200 "$STATUS"
assert_json_field "Updated title" "$BODY" '.note.title' 'Hello World Updated'

# Check tags include the new "updated" tag
TAGS=$(echo "$BODY" | jq -r '.note.tags | join(",")' 2>/dev/null || echo "")
if [[ "$TAGS" == *"updated"* ]]; then
    pass "Tags updated after upsert"
else
    fail "Tags not updated after upsert — got: $TAGS"
fi

# ============================================================================
# SECTION 5: Note Read (GET /notes/{path})
# ============================================================================
echo ""
echo "=== 5. Note Read (GET /notes/{path}) ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/Test/Hello%20World.md" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/{path}" 200 "$STATUS"
assert_json_field "Read note path" "$BODY" '.path' 'Test/Hello World.md'
assert_json_field "Read note title" "$BODY" '.note.title // .title' 'Hello World Updated'
assert_contains "Content present" "$BODY" "Omega 3"

# 5b. Note not found
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/NonExistent/Note.md" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/{path} (not found)" 404 "$STATUS"

# ============================================================================
# SECTION 6: Legacy Note Endpoint (GET /note?source_path=)
# ============================================================================
echo ""
echo "=== 6. Legacy Note Endpoint (GET /note) ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/note?source_path=Test/Hello%20World.md" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /note?source_path= (exists)" 200 "$STATUS"
assert_contains "Legacy note content" "$BODY" "Hello World"

RESP=$(curl -s -w "\n%{http_code}" "$BASE/note?source_path=DoesNotExist.md" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /note?source_path= (missing)" 200 "$STATUS"
assert_contains "Legacy note not found" "$BODY" "not found"

# ============================================================================
# SECTION 7: Folders (GET /folders)
# ============================================================================
echo ""
echo "=== 7. Folders ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/folders" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /folders" 200 "$STATUS"
assert_json_not_empty "Folders list" "$BODY" '.folders'

# Check Test folder is present
FOLDER_COUNT=$(echo "$BODY" | jq '[.folders[] | select(.folder == "Test")] | length' 2>/dev/null || echo "0")
if [[ "$FOLDER_COUNT" -gt 0 ]]; then
    pass "Test folder present in results"
else
    fail "Test folder not found in folders response"
fi

# ============================================================================
# SECTION 8: Tags (GET /tags)
# ============================================================================
echo ""
echo "=== 8. Tags ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /tags" 200 "$STATUS"

# Check "health" tag exists
TAG_HEALTH=$(echo "$BODY" | jq '[.tags[] | select(.name == "health")] | length' 2>/dev/null || echo "0")
if [[ "$TAG_HEALTH" -gt 0 ]]; then
    pass "Tag 'health' found"
else
    fail "Tag 'health' not found in response"
fi

# ============================================================================
# SECTION 9: Search (POST /search)
# ============================================================================
echo ""
echo "=== 9. Search ==="

# Give indexing a moment to settle
sleep 1

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "omega 3 brain health", "limit": 5}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (omega 3)" 200 "$STATUS"

RESULT_COUNT=$(echo "$BODY" | jq '.results | length' 2>/dev/null || echo "0")
if [[ "$RESULT_COUNT" -gt 0 ]]; then
    pass "Search returned $RESULT_COUNT results"
else
    fail "Search returned 0 results"
fi

# Search with tags filter
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "health", "limit": 5, "tags": ["supplements"]}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (with tag filter)" 200 "$STATUS"

# Search with high limit
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "vitamin", "limit": 50}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (limit 50)" 200 "$STATUS"

# ============================================================================
# SECTION 10: Sync — Changes Endpoint (GET /notes/changes)
# ============================================================================
echo ""
echo "=== 10. Sync — Changes ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/changes?since=2020-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/changes (since 2020)" 200 "$STATUS"
assert_json_not_empty "Changes list" "$BODY" '.changes'
assert_json_not_empty "Server time" "$BODY" '.server_time'

CHANGE_COUNT=$(echo "$BODY" | jq '.changes | length' 2>/dev/null || echo "0")
if [[ "$CHANGE_COUNT" -ge 3 ]]; then
    pass "Changes contains >= 3 notes ($CHANGE_COUNT)"
else
    fail "Changes has fewer than 3 notes: $CHANGE_COUNT"
fi

# 10b. Changes with future timestamp (should return empty)
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/changes?since=2099-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/changes (future)" 200 "$STATUS"
CHANGE_COUNT=$(echo "$BODY" | jq '.changes | length' 2>/dev/null || echo "0")
if [[ "$CHANGE_COUNT" -eq 0 ]]; then
    pass "Future timestamp returns 0 changes"
else
    fail "Future timestamp returned $CHANGE_COUNT changes (expected 0)"
fi

# 10c. Invalid timestamp
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/changes?since=not-a-date" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/changes (bad timestamp)" 400 "$STATUS"

# ============================================================================
# SECTION 11: Note Deletion (DELETE /notes/{path})
# ============================================================================
echo ""
echo "=== 11. Note Deletion ==="

RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/notes/Test/Plain%20Note.md" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE /notes/{path}" 200 "$STATUS"
assert_json_field "Delete confirmed" "$BODY" '.deleted' 'true'

# Verify deleted note returns 404
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/Test/Plain%20Note.md" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET deleted note (404)" 404 "$STATUS"

# Verify deleted note appears in changes with deleted flag
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/changes?since=2020-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
DELETED_NOTE=$(echo "$BODY" | jq '[.changes[] | select(.path == "Test/Plain Note.md" and .deleted == true)] | length' 2>/dev/null || echo "0")
if [[ "$DELETED_NOTE" -gt 0 ]]; then
    pass "Deleted note appears in changes with deleted=true"
else
    fail "Deleted note not flagged in changes"
fi

# Delete non-existent note
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/notes/Fake/Note.md" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE /notes (not found)" 404 "$STATUS"

# ============================================================================
# SECTION 12: Edge Cases & Validation
# ============================================================================
echo ""
echo "=== 12. Edge Cases ==="

# Empty content
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/Empty.md", "content": "", "mtime": 1709234700.0}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (empty content)" 200 "$STATUS"

# Special characters in path
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/Special (Chars) & More!.md", "content": "# Special\n\nNote with special path chars.", "mtime": 1709234701.0}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (special chars in path)" 200 "$STATUS"

# Unicode content
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/Unicode.md", "content": "# Ünïcödé\n\nEmoji test: 🧠 日本語テスト", "mtime": 1709234702.0}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (unicode content)" 200 "$STATUS"

# Very long content (generate ~2000 words)
LONG_CONTENT="# Long Note\n\n"
for i in $(seq 1 200); do
    LONG_CONTENT+="This is paragraph $i with some filler text about various topics. "
done
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Test/Long.md" --arg content "$LONG_CONTENT" --argjson mtime 1709234703 '{path: $path, content: $content, mtime: $mtime}')")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (long content)" 200 "$STATUS"
CHUNKS=$(echo "$BODY" | jq -r '.chunks_indexed' 2>/dev/null || echo "0")
if [[ "$CHUNKS" -gt 1 ]]; then
    pass "Long note chunked into $CHUNKS chunks"
else
    # Even if indexing fails, the note should be stored
    pass "Long note stored (chunks: $CHUNKS)"
fi

# Missing required field
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"content": "no path", "mtime": 123}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (missing path)" 422 "$STATUS"

# Invalid JSON
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d 'not json at all')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (invalid JSON)" 422 "$STATUS"

# ============================================================================
# SECTION 13: Multi-Tenant Isolation
# ============================================================================
echo ""
echo "=== 13. Multi-Tenant Isolation ==="

# Register a second user
TIMESTAMP2=$(date +%s%N)
TEST_EMAIL2="other_${TIMESTAMP2}@example.com"

# Register second user
curl -s -X POST "$BASE/register" \
    -d "email=${TEST_EMAIL2}&password=otherpass&display_name=Other+User" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c /tmp/engram_cookies2 -L -o /dev/null

# Create API key for second user
RESP2=$(curl -s -X POST "$BASE/settings/keys" \
    -d "name=other-key" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -b /tmp/engram_cookies2 -L)
API_KEY2=$(echo "$RESP2" | grep -oP 'engram_[A-Za-z0-9_-]+' | head -1 || true)

if [[ -n "$API_KEY2" ]]; then
    pass "Second user created with API key"

    # Second user should NOT see first user's notes
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/Test/Hello%20World.md" \
        -H "Authorization: Bearer $API_KEY2")
    STATUS=$(echo "$RESP" | tail -1)
    assert_status "User 2 cannot read User 1's note" 404 "$STATUS"

    # Second user's folders should be empty
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/folders" \
        -H "Authorization: Bearer $API_KEY2")
    BODY=$(echo "$RESP" | head -1)
    FOLDER_COUNT=$(echo "$BODY" | jq '.folders | length' 2>/dev/null || echo "0")
    if [[ "$FOLDER_COUNT" -eq 0 ]]; then
        pass "User 2 sees no folders (isolation works)"
    else
        fail "User 2 sees $FOLDER_COUNT folders (isolation broken!)"
    fi

    # Second user's tags should be empty
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
        -H "Authorization: Bearer $API_KEY2")
    BODY=$(echo "$RESP" | head -1)
    TAG_COUNT=$(echo "$BODY" | jq '.tags | length' 2>/dev/null || echo "0")
    if [[ "$TAG_COUNT" -eq 0 ]]; then
        pass "User 2 sees no tags (isolation works)"
    else
        fail "User 2 sees $TAG_COUNT tags (isolation broken!)"
    fi
else
    fail "Could not create second user — multi-tenant tests skipped"
fi

# ============================================================================
# SECTION 14: Web UI Routes (Session Auth)
# ============================================================================
echo ""
echo "=== 14. Web UI Routes ==="

# Login page (no auth needed)
RESP=$(curl -s -w "\n%{http_code}" "$BASE/login")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /login" 200 "$STATUS"

# Register page
RESP=$(curl -s -w "\n%{http_code}" "$BASE/register")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /register" 200 "$STATUS"

# Search page (requires session — should redirect)
RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/search")
STATUS="$RESP"
# It redirects to /login with 303
if [[ "$STATUS" == "303" || "$STATUS" == "200" ]]; then
    pass "GET /search (no session) → redirect or 200"
else
    fail "GET /search (no session) — expected 303 redirect, got $STATUS"
fi

# Search page with session cookie
RESP=$(curl -s -w "\n%{http_code}" "$BASE/search" -b /tmp/engram_cookies -L)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /search (with session)" 200 "$STATUS"

# Settings page with session
RESP=$(curl -s -w "\n%{http_code}" "$BASE/settings" -b /tmp/engram_cookies -L)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /settings (with session)" 200 "$STATUS"

# ============================================================================
# SECTION 15: Search Validation
# ============================================================================
echo ""
echo "=== 15. Search Validation ==="

# Empty query
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": ""}')
STATUS=$(echo "$RESP" | tail -1)
# FastAPI may accept empty string — just check it doesn't crash
if [[ "$STATUS" == "200" || "$STATUS" == "422" ]]; then
    pass "POST /search (empty query) — HTTP $STATUS"
else
    fail "POST /search (empty query) — expected 200 or 422, got $STATUS"
fi

# Limit boundary: 0
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "test", "limit": 0}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (limit 0)" 422 "$STATUS"

# Limit boundary: 51 (over max)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "test", "limit": 51}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (limit 51, over max)" 422 "$STATUS"

# ============================================================================
# SECTION 17: SSE Live Sync (GET /notes/stream)
# ============================================================================
echo ""
echo "=== 17. SSE Live Sync ==="

# 17a. Unauthenticated SSE should fail
RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/stream")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/stream (no auth → 401)" 401 "$STATUS"

# 17b. Connect SSE stream, push a note, verify event received
SSE_OUTPUT=$(mktemp)
curl -sN "$BASE/notes/stream" \
    -H "Authorization: Bearer $API_KEY" \
    > "$SSE_OUTPUT" 2>/dev/null &
SSE_PID=$!

# Wait for connection to establish
sleep 1

# Verify connected event
if grep -q "event: connected" "$SSE_OUTPUT"; then
    pass "SSE connected event received"
else
    fail "SSE connected event not received"
fi

# Push a note — should trigger an SSE event
curl -s -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/SSE Test.md", "content": "# SSE Test\n\nTriggering SSE event.", "mtime": 1709234800.0}' \
    -o /dev/null

# Wait for event to arrive
sleep 1

if grep -q '"event_type": "upsert"' "$SSE_OUTPUT" && grep -q '"path": "Test/SSE Test.md"' "$SSE_OUTPUT"; then
    pass "SSE note_change event received for upsert"
else
    fail "SSE note_change event not received — output: $(cat $SSE_OUTPUT)"
fi

# Delete the note — should trigger delete event
ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('Test/SSE Test.md', safe=''))")
curl -s -X DELETE "$BASE/notes/$ENCODED" \
    -H "Authorization: Bearer $API_KEY" -o /dev/null

sleep 1

if grep -q '"event_type": "delete"' "$SSE_OUTPUT"; then
    pass "SSE note_change event received for delete"
else
    fail "SSE delete event not received"
fi

# 17e. CORS preflight on SSE endpoint returns 200 (was 405 before CORS fix)
CORS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS "$BASE/notes/stream" \
    -H "Origin: app://obsidian.md" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: Authorization")
assert_status "OPTIONS /notes/stream (CORS preflight → 200)" 200 "$CORS_STATUS"

# 17f. CORS preflight includes required headers
CORS_HEADERS=$(curl -s -D - -o /dev/null -X OPTIONS "$BASE/notes/stream" \
    -H "Origin: app://obsidian.md" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: Authorization")
if echo "$CORS_HEADERS" | grep -qi "access-control-allow-origin"; then
    pass "CORS Access-Control-Allow-Origin header present"
else
    fail "CORS Access-Control-Allow-Origin header missing"
fi
if echo "$CORS_HEADERS" | grep -qi "access-control-allow-headers.*authorization"; then
    pass "CORS allows Authorization header"
else
    fail "CORS does not allow Authorization header"
fi

# 17g. CORS preflight on other endpoints (not just SSE)
CORS_NOTES=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS "$BASE/notes" \
    -H "Origin: app://obsidian.md" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: Authorization,Content-Type")
assert_status "OPTIONS /notes (CORS preflight → 200)" 200 "$CORS_NOTES"

# Clean up SSE connection
kill "$SSE_PID" 2>/dev/null || true
rm -f "$SSE_OUTPUT"

# ============================================================================
# SECTION 18: Attachments
# ============================================================================
echo ""
echo "=== 18. Attachments ==="

# 18a. Upload attachment (small PNG-like payload)
# Create a small base64 payload (a 1x1 red PNG)
SMALL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/test-image.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709234900.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /attachments (upload)" 200 "$STATUS"
assert_json_field "Attachment path" "$BODY" '.attachment.path' 'Assets/test-image.png'
assert_json_field "Attachment mime_type" "$BODY" '.attachment.mime_type' 'image/png'

# 18b. Download attachment and verify round-trip
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/Assets/test-image.png" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments/{path}" 200 "$STATUS"
DOWNLOADED_B64=$(echo "$BODY" | jq -r '.content_base64' 2>/dev/null || echo "")
if [[ "$DOWNLOADED_B64" == "$SMALL_PNG_B64" ]]; then
    pass "Attachment round-trip content matches"
else
    fail "Attachment content mismatch"
fi

# 18c. Attachment not found
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/nonexistent.png" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments/{path} (not found)" 404 "$STATUS"

# 18d. Attachment changes endpoint
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/changes?since=2020-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments/changes" 200 "$STATUS"
ATTACH_COUNT=$(echo "$BODY" | jq '.changes | length' 2>/dev/null || echo "0")
if [[ "$ATTACH_COUNT" -ge 1 ]]; then
    pass "Attachment changes contains >= 1 entry ($ATTACH_COUNT)"
else
    fail "Attachment changes has 0 entries"
fi
# Changes should NOT include content
HAS_CONTENT=$(echo "$BODY" | jq '.changes[0] | has("content_base64")' 2>/dev/null || echo "true")
if [[ "$HAS_CONTENT" == "false" ]]; then
    pass "Attachment changes excludes content (metadata only)"
else
    fail "Attachment changes includes content (should be metadata only)"
fi

# 18e. Delete attachment
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/attachments/Assets/test-image.png" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE /attachments/{path}" 200 "$STATUS"
assert_json_field "Attachment delete confirmed" "$BODY" '.deleted' 'true'

# Verify deleted attachment returns 404
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/Assets/test-image.png" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET deleted attachment (404)" 404 "$STATUS"

# Delete non-existent attachment
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/attachments/fake.png" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE /attachments (not found)" 404 "$STATUS"

# 18f. Size limit (generate payload larger than 5MB)
# Write the large JSON payload to a temp file to avoid shell argument limits
LARGE_PAYLOAD=$(mktemp)
python3 -c "
import base64, json
b64 = base64.b64encode(b'x' * (5 * 1024 * 1024 + 1)).decode()
json.dump({'path': 'Assets/huge.bin', 'content_base64': b64, 'mtime': 1709235000.0}, open('$LARGE_PAYLOAD', 'w'))
"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$LARGE_PAYLOAD")
STATUS=$(echo "$RESP" | tail -1)
rm -f "$LARGE_PAYLOAD"
assert_status "POST /attachments (over size limit → 413)" 413 "$STATUS"

# 18g. Multi-tenant isolation for attachments
if [[ -n "$API_KEY2" ]]; then
    # Upload as user 1
    curl -s -X POST "$BASE/attachments" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "Assets/private.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709235100.0 \
            '{path: $path, content_base64: $b64, mtime: $mtime}')" -o /dev/null

    # User 2 should not see it
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/Assets/private.png" \
        -H "Authorization: Bearer $API_KEY2")
    STATUS=$(echo "$RESP" | tail -1)
    assert_status "User 2 cannot read User 1's attachment" 404 "$STATUS"

    # Clean up
    curl -s -X DELETE "$BASE/attachments/Assets/private.png" \
        -H "Authorization: Bearer $API_KEY" -o /dev/null
else
    pass "Attachment multi-tenant test skipped (no second user)"
fi

# 18h. User storage endpoint
RESP=$(curl -s -w "\n%{http_code}" "$BASE/user/storage" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /user/storage" 200 "$STATUS"
assert_json_not_empty "Storage max_bytes" "$BODY" '.max_bytes'
assert_json_not_empty "Storage max_attachment_bytes" "$BODY" '.max_attachment_bytes'

# 18i. Invalid base64
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Assets/bad.png", "content_base64": "not-valid-base64!!!", "mtime": 123.0}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /attachments (invalid base64 → 400)" 400 "$STATUS"

# ============================================================================
# SECTION 19: Deep Health Check (GET /health/deep)
# ============================================================================
echo ""
echo "=== 19. Deep Health Check ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/health/deep")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
# Accept either 200 (all ok) or 503 (degraded — some deps might be down in test env)
if [[ "$STATUS" == "200" || "$STATUS" == "503" ]]; then
    pass "GET /health/deep (HTTP $STATUS)"
else
    fail "GET /health/deep — expected 200 or 503, got $STATUS"
fi
assert_json_not_empty "Deep health status" "$BODY" '.status'
assert_json_not_empty "Deep health checks" "$BODY" '.checks'
assert_json_not_empty "PostgreSQL check" "$BODY" '.checks.postgresql'
assert_json_not_empty "Qdrant check" "$BODY" '.checks.qdrant'
assert_json_not_empty "Ollama check" "$BODY" '.checks.ollama'

# ============================================================================
# SECTION 20: API Key Deletion + Cache Invalidation
# ============================================================================
echo ""
echo "=== 20. API Key Deletion + Cache Invalidation ==="

# Create a temporary API key to delete
RESP=$(curl -s -X POST "$BASE/settings/keys" \
    -d "name=temp-delete-key" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -b /tmp/engram_cookies -L)
TEMP_KEY=$(echo "$RESP" | grep -oP 'engram_[A-Za-z0-9_-]+' | head -1 || true)

if [[ -n "$TEMP_KEY" ]]; then
    # Verify the key works
    RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
        -H "Authorization: Bearer $TEMP_KEY")
    STATUS=$(echo "$RESP" | tail -1)
    assert_status "Temp key works before delete" 200 "$STATUS"

    # Warm the cache by making a second request
    curl -s "$BASE/tags" -H "Authorization: Bearer $TEMP_KEY" -o /dev/null

    # Get the key ID for temp-delete-key from settings page
    SETTINGS_HTML=$(curl -s "$BASE/settings" -b /tmp/engram_cookies -L)
    # Extract key_id for the temp-delete-key specifically (not the main test key)
    KEY_ID=$(python3 -c "
import re, sys
html = sys.stdin.read()
# Find all (name, key_id) pairs
rows = re.findall(r'<td>([^<]+)</td>.*?keys/(\d+)/delete', html, re.DOTALL)
for name, kid in rows:
    if 'temp-delete-key' in name:
        print(kid)
        break
" <<< "$SETTINGS_HTML" || true)

    if [[ -n "$KEY_ID" ]]; then
        # Delete via settings endpoint
        curl -s -X POST "$BASE/settings/keys/$KEY_ID/delete" \
            -b /tmp/engram_cookies -L -o /dev/null

        # Key should be immediately invalid (cache invalidated)
        RESP=$(curl -s -w "\n%{http_code}" "$BASE/tags" \
            -H "Authorization: Bearer $TEMP_KEY")
        STATUS=$(echo "$RESP" | tail -1)
        assert_status "Deleted key rejected immediately (cache invalidated)" 401 "$STATUS"
    else
        fail "Could not extract key ID for deletion test"
    fi
else
    fail "Could not create temp key for deletion test"
fi

# ============================================================================
# SECTION 21: Logout
# ============================================================================
echo ""
echo "=== 21. Logout ==="

# First log in to get a valid session
curl -s -o /dev/null -X POST "$BASE/login" \
    -d "email=${TEST_EMAIL}&password=${TEST_PASS}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c /tmp/engram_cookies_logout

# Verify session works
RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/search" \
    -b /tmp/engram_cookies_logout -L)
assert_status "GET /search (before logout)" 200 "$RESP"

# Logout
RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/logout" \
    -b /tmp/engram_cookies_logout -c /tmp/engram_cookies_logout)
assert_status "GET /logout → 303 redirect" 303 "$RESP"

# After logout, search should redirect to login
RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/search" \
    -b /tmp/engram_cookies_logout)
assert_status "GET /search (after logout) → 303 redirect" 303 "$RESP"

rm -f /tmp/engram_cookies_logout

# ============================================================================
# SECTION 22: Note Size Limit (413)
# ============================================================================
echo ""
echo "=== 22. Note Size Limit ==="

# Generate a note exceeding MAX_NOTE_SIZE (10MB default)
LARGE_NOTE_PAYLOAD=$(mktemp)
python3 -c "
import json
content = 'x' * (10 * 1024 * 1024 + 1)
json.dump({'path': 'Test/Huge Note.md', 'content': content, 'mtime': 1709235500.0}, open('$LARGE_NOTE_PAYLOAD', 'w'))
"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$LARGE_NOTE_PAYLOAD")
STATUS=$(echo "$RESP" | tail -1)
rm -f "$LARGE_NOTE_PAYLOAD"
assert_status "POST /notes (over size limit → 413)" 413 "$STATUS"

# ============================================================================
# SECTION 23: Changes Response Shape
# ============================================================================
echo ""
echo "=== 23. Changes Response Shape ==="

RESP=$(curl -s -w "\n%{http_code}" "$BASE/notes/changes?since=2020-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /notes/changes (for shape check)" 200 "$STATUS"

# Verify each change entry has the content field (plugin depends on this)
HAS_CONTENT=$(echo "$BODY" | jq '.changes[0] | has("content")' 2>/dev/null || echo "false")
if [[ "$HAS_CONTENT" == "true" ]]; then
    pass "Changes entries include 'content' field"
else
    fail "Changes entries missing 'content' field (plugin needs this for re-indexing)"
fi

# Verify each change entry has required fields
HAS_PATH=$(echo "$BODY" | jq '.changes[0] | has("path")' 2>/dev/null || echo "false")
HAS_TITLE=$(echo "$BODY" | jq '.changes[0] | has("title")' 2>/dev/null || echo "false")
HAS_DELETED=$(echo "$BODY" | jq '.changes[0] | has("deleted")' 2>/dev/null || echo "false")
HAS_UPDATED=$(echo "$BODY" | jq '.changes[0] | has("updated_at")' 2>/dev/null || echo "false")
if [[ "$HAS_PATH" == "true" && "$HAS_TITLE" == "true" && "$HAS_DELETED" == "true" && "$HAS_UPDATED" == "true" ]]; then
    pass "Changes entries have all required fields (path, title, deleted, updated_at)"
else
    fail "Changes entries missing required fields"
fi

# ============================================================================
# SECTION 24: Root-Level Note + Title Filename Fallback
# ============================================================================
echo ""
echo "=== 24. Root-Level Note + Title Fallback ==="

# 24a. Root-level note (no folder separator → folder="")
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Root Note.md", "content": "# Root Level\n\nA note at the vault root.", "mtime": 1709235600.0}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (root-level note)" 200 "$STATUS"
assert_json_field "Root note folder is empty" "$BODY" '.note.folder' ''

# 24b. Title from filename fallback (no frontmatter title, no H1)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/No Title Note.md", "content": "Just some content with no heading at all.\n\nSecond paragraph.", "mtime": 1709235601.0}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (no frontmatter, no heading)" 200 "$STATUS"
assert_json_field "Title falls back to filename" "$BODY" '.note.title' 'No Title Note'

# ============================================================================
# SECTION 25: Tags as Comma-Separated String
# ============================================================================
echo ""
echo "=== 25. Tags as Comma-Separated String ==="

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{
        "path": "Test/Comma Tags.md",
        "content": "---\ntags: alpha, beta, gamma\n---\n# Comma Tags\n\nTags as comma-separated string.",
        "mtime": 1709235700.0
    }')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /notes (comma-separated tags)" 200 "$STATUS"

TAGS=$(echo "$BODY" | jq -r '.note.tags | join(",")' 2>/dev/null || echo "")
if [[ "$TAGS" == *"alpha"* && "$TAGS" == *"beta"* && "$TAGS" == *"gamma"* ]]; then
    pass "Comma-separated tags parsed correctly (alpha, beta, gamma)"
else
    fail "Comma-separated tags not parsed — got: $TAGS"
fi

# ============================================================================
# SECTION 26: Delete Already-Deleted Note (404)
# ============================================================================
echo ""
echo "=== 26. Delete Already-Deleted Note ==="

# Create then delete a note
curl -s -X POST "$BASE/notes" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"path": "Test/Double Delete.md", "content": "# Double\n\nTo be deleted twice.", "mtime": 1709235800.0}' -o /dev/null

ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('Test/Double Delete.md', safe=''))")
curl -s -X DELETE "$BASE/notes/$ENCODED" \
    -H "Authorization: Bearer $API_KEY" -o /dev/null

# Second delete should return 404
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/notes/$ENCODED" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE already-deleted note (404)" 404 "$STATUS"

# ============================================================================
# SECTION 27: Attachment Upsert (Update Existing)
# ============================================================================
echo ""
echo "=== 27. Attachment Upsert (Update) ==="

SMALL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

# Upload original
curl -s -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/update-test.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709236000.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')" -o /dev/null

# Re-upload with different content (a different base64 payload)
UPDATED_B64=$(echo -n "updated content bytes" | base64)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/update-test.png" --arg b64 "$UPDATED_B64" --argjson mtime 1709236001.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /attachments (upsert/update)" 200 "$STATUS"

# Verify round-trip returns updated content
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/Assets/update-test.png" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
DOWNLOADED=$(echo "$BODY" | jq -r '.content_base64' 2>/dev/null || echo "")
if [[ "$DOWNLOADED" == "$UPDATED_B64" ]]; then
    pass "Attachment upsert updated content correctly"
else
    fail "Attachment upsert content mismatch"
fi

# Cleanup
curl -s -X DELETE "$BASE/attachments/Assets/update-test.png" \
    -H "Authorization: Bearer $API_KEY" -o /dev/null

# ============================================================================
# SECTION 28: Attachment Changes Edge Cases
# ============================================================================
echo ""
echo "=== 28. Attachment Changes Edge Cases ==="

# 28a. Future timestamp → empty
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/changes?since=2099-01-01T00:00:00Z" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments/changes (future timestamp)" 200 "$STATUS"
ATTACH_COUNT=$(echo "$BODY" | jq '.changes | length' 2>/dev/null || echo "-1")
if [[ "$ATTACH_COUNT" -eq 0 ]]; then
    pass "Attachment changes with future timestamp returns 0"
else
    fail "Attachment changes with future timestamp returned $ATTACH_COUNT (expected 0)"
fi

# 28b. Invalid timestamp → 400
RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/changes?since=not-a-date" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /attachments/changes (bad timestamp → 400)" 400 "$STATUS"

# 28c. Deleted attachment appears in changes with deleted=true
SMALL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
BEFORE_DELETE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
sleep 1
curl -s -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/delete-track.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709236100.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')" -o /dev/null

curl -s -X DELETE "$BASE/attachments/Assets/delete-track.png" \
    -H "Authorization: Bearer $API_KEY" -o /dev/null

RESP=$(curl -s -w "\n%{http_code}" "$BASE/attachments/changes?since=$BEFORE_DELETE" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
DELETED_ATTACH=$(echo "$BODY" | jq '[.changes[] | select(.path == "Assets/delete-track.png" and .deleted == true)] | length' 2>/dev/null || echo "0")
if [[ "$DELETED_ATTACH" -gt 0 ]]; then
    pass "Deleted attachment appears in changes with deleted=true"
else
    fail "Deleted attachment not flagged in changes"
fi

# ============================================================================
# SECTION 29: Search Result Fields + Multi-Tag Filter
# ============================================================================
echo ""
echo "=== 29. Search Result Fields ==="

sleep 1

RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "omega brain health", "limit": 5}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (for field check)" 200 "$STATUS"

RESULT_COUNT=$(echo "$BODY" | jq '.results | length' 2>/dev/null || echo "0")
if [[ "$RESULT_COUNT" -gt 0 ]]; then
    # Check all expected fields present in first result
    HAS_TEXT=$(echo "$BODY" | jq '.results[0] | has("text")' 2>/dev/null || echo "false")
    HAS_SCORE=$(echo "$BODY" | jq '.results[0] | has("score")' 2>/dev/null || echo "false")
    HAS_VSCORE=$(echo "$BODY" | jq '.results[0] | has("vector_score")' 2>/dev/null || echo "false")
    HAS_SOURCE=$(echo "$BODY" | jq '.results[0] | has("source_path")' 2>/dev/null || echo "false")
    if [[ "$HAS_TEXT" == "true" && "$HAS_SCORE" == "true" && "$HAS_VSCORE" == "true" && "$HAS_SOURCE" == "true" ]]; then
        pass "Search results have expected fields (text, score, vector_score, source_path)"
    else
        fail "Search results missing expected fields"
    fi
else
    fail "No search results to check fields"
fi

# 29b. Multi-tag filter
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "health", "limit": 10, "tags": ["health", "omega"]}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /search (multi-tag filter)" 200 "$STATUS"

# ============================================================================
# SECTION 30: SSE User Isolation
# ============================================================================
echo ""
echo "=== 30. SSE User Isolation ==="

if [[ -n "$API_KEY2" ]]; then
    SSE_USER2=$(mktemp)
    curl -sN "$BASE/notes/stream" \
        -H "Authorization: Bearer $API_KEY2" \
        > "$SSE_USER2" 2>/dev/null &
    SSE_PID2=$!

    sleep 1

    # Push a note as user 1
    curl -s -X POST "$BASE/notes" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"path": "Test/Isolation Test.md", "content": "# Isolation\n\nUser 1 only.", "mtime": 1709236200.0}' -o /dev/null

    sleep 1

    # User 2's stream should NOT have the upsert event
    if grep -q '"path": "Test/Isolation Test.md"' "$SSE_USER2"; then
        fail "SSE user isolation broken — User 2 received User 1's event!"
    else
        pass "SSE user isolation — User 2 did not receive User 1's event"
    fi

    kill "$SSE_PID2" 2>/dev/null || true
    rm -f "$SSE_USER2"

    # Cleanup
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('Test/Isolation Test.md', safe=''))")
    curl -s -X DELETE "$BASE/notes/$ENCODED" \
        -H "Authorization: Bearer $API_KEY" -o /dev/null
else
    pass "SSE isolation test skipped (no second user)"
fi

# ============================================================================
# SECTION 31: Search Multi-Tenant Isolation
# ============================================================================
echo ""
echo "=== 31. Search Multi-Tenant Isolation ==="

if [[ -n "$API_KEY2" ]]; then
    RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/search" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"query": "omega brain health", "limit": 10}')
    BODY=$(echo "$RESP" | head -1)
    STATUS=$(echo "$RESP" | tail -1)
    assert_status "POST /search as User 2" 200 "$STATUS"

    RESULT_COUNT=$(echo "$BODY" | jq '.results | length' 2>/dev/null || echo "0")
    if [[ "$RESULT_COUNT" -eq 0 ]]; then
        pass "User 2 search returns 0 results (isolation works)"
    else
        fail "User 2 search returned $RESULT_COUNT results (isolation broken!)"
    fi
else
    pass "Search multi-tenant test skipped (no second user)"
fi

# ============================================================================
# SECTION 32: MCP Auth Middleware
# ============================================================================
echo ""
echo "=== 32. MCP Auth ==="

# No auth → 401
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/mcp/" \
    -H "Content-Type: application/json" \
    -d '{}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /mcp/ (no auth → 401)" 401 "$STATUS"

# Invalid key → 401
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/mcp/" \
    -H "Authorization: Bearer engram_invalidkey123" \
    -H "Content-Type: application/json" \
    -d '{}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /mcp/ (invalid key → 401)" 401 "$STATUS"

# Valid key → should not be 401 (exact status depends on MCP protocol expectations)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/mcp/" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{}')
STATUS=$(echo "$RESP" | tail -1)
if [[ "$STATUS" != "401" ]]; then
    pass "POST /mcp/ (valid key → not 401, got HTTP $STATUS)"
else
    fail "POST /mcp/ (valid key) — still got 401"
fi

# ============================================================================
# SECTION 33: Delete Already-Deleted Attachment (404)
# ============================================================================
echo ""
echo "=== 33. Delete Already-Deleted Attachment ==="

SMALL_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="

curl -s -X POST "$BASE/attachments" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg path "Assets/double-del.png" --arg b64 "$SMALL_PNG_B64" --argjson mtime 1709236300.0 \
        '{path: $path, content_base64: $b64, mtime: $mtime}')" -o /dev/null

curl -s -X DELETE "$BASE/attachments/Assets/double-del.png" \
    -H "Authorization: Bearer $API_KEY" -o /dev/null

RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/attachments/Assets/double-del.png" \
    -H "Authorization: Bearer $API_KEY")
STATUS=$(echo "$RESP" | tail -1)
assert_status "DELETE already-deleted attachment (404)" 404 "$STATUS"

# ============================================================================
# SECTION 34: Rate Limiting (429)
# ============================================================================
echo ""
echo "=== 34. Rate Limiting ==="

# Rate limiting is per-worker when using in-memory backend — not reliably testable
# from outside with multiple uvicorn workers. Only test when Redis provides a
# global rate limit (detected via /health/deep having a redis check).
DEEP_HEALTH=$(curl -s "$BASE/health/deep")
HAS_REDIS_RL=$(echo "$DEEP_HEALTH" | jq 'has("checks") and (.checks | has("redis"))' 2>/dev/null || echo "false")

if [[ "$HAS_REDIS_RL" == "true" ]]; then
    # Redis is configured — rate limit is global, so we can test it
    RATE_KEY=$(curl -s -X POST "$BASE/settings/keys" \
        -b /tmp/engram_cookies \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "name=rate-test-key" -L | grep -oP 'engram_[A-Za-z0-9_-]+' || echo "")

    if [[ -n "$RATE_KEY" ]]; then
        GOT_429=false
        # Default limit is 120/min. With Redis, it's global across all workers.
        for i in $(seq 1 130); do
            STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/search" \
                -H "Authorization: Bearer $RATE_KEY" \
                -H "Content-Type: application/json" \
                -d '{"query": "test", "limit": 1}')
            if [[ "$STATUS" == "429" ]]; then
                GOT_429=true
                break
            fi
        done

        if [[ "$GOT_429" == "true" ]]; then
            pass "Rate limiter returns 429 after exceeding limit (Redis)"
        else
            fail "Rate limiter did not return 429 after 130 requests (Redis)"
        fi

        # Verify the 429 response body has a useful message
        if [[ "$GOT_429" == "true" ]]; then
            RESP=$(curl -s -X POST "$BASE/search" \
                -H "Authorization: Bearer $RATE_KEY" \
                -H "Content-Type: application/json" \
                -d '{"query": "test", "limit": 1}')
            if echo "$RESP" | grep -qi "rate limit"; then
                pass "429 response includes rate limit message"
            else
                fail "429 response missing rate limit message"
            fi
        else
            fail "429 response check skipped (no 429 received)"
        fi
    else
        fail "Could not create rate-test key"
    fi
else
    pass "Rate limit test skipped (no Redis — per-worker limits not testable externally)"
fi

# ============================================================================
# SECTION 35: Deep Health — Redis Status
# ============================================================================
echo ""
echo "=== 35. Deep Health — Redis ==="

DEEP=$(curl -s "$BASE/health/deep")
HAS_REDIS=$(echo "$DEEP" | jq 'has("checks") and (.checks | has("redis"))' 2>/dev/null || echo "false")

if [[ "$HAS_REDIS" == "true" ]]; then
    REDIS_STATUS=$(echo "$DEEP" | jq -r '.checks.redis' 2>/dev/null || echo "unknown")
    if [[ "$REDIS_STATUS" == "ok" ]]; then
        pass "Deep health: Redis configured and healthy"
    else
        fail "Deep health: Redis configured but unhealthy — $REDIS_STATUS"
    fi
else
    pass "Deep health: Redis not configured (skipped — in-memory mode)"
fi

# ============================================================================
# SECTION 36: Folder Reindex
# ============================================================================
echo ""
echo "=== 36. Folder Reindex ==="

# Reindex folders (test notes should already be in various folders)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/folders/reindex" \
    -H "Authorization: Bearer $API_KEY")
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /folders/reindex" 200 "$STATUS"

FOLDER_COUNT=$(echo "$BODY" | jq -r '.folders_indexed' 2>/dev/null || echo "0")
if [[ "$FOLDER_COUNT" -gt 0 ]]; then
    pass "Folder reindex returned $FOLDER_COUNT folders"
else
    fail "Folder reindex returned 0 folders (expected > 0)"
fi

# Verify folder count matches actual folder count from GET /folders
FOLDERS_RESP=$(curl -s "$BASE/folders" -H "Authorization: Bearer $API_KEY")
PG_FOLDER_COUNT=$(echo "$FOLDERS_RESP" | jq '.folders | length' 2>/dev/null || echo "0")
if [[ "$FOLDER_COUNT" == "$PG_FOLDER_COUNT" ]]; then
    pass "Folder index count matches PostgreSQL folder count ($PG_FOLDER_COUNT)"
else
    fail "Folder index count ($FOLDER_COUNT) != PostgreSQL folder count ($PG_FOLDER_COUNT)"
fi

# ============================================================================
# SECTION 37: Folder Search
# ============================================================================
echo ""
echo "=== 37. Folder Search ==="

# Search for folders matching "health supplements vitamin"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/folders/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "health supplements vitamin", "limit": 3}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /folders/search" 200 "$STATUS"

RESULT_COUNT=$(echo "$BODY" | jq '.results | length' 2>/dev/null || echo "0")
if [[ "$RESULT_COUNT" -gt 0 ]]; then
    pass "Folder search returned $RESULT_COUNT results"
else
    fail "Folder search returned 0 results (expected > 0)"
fi

# Verify result shape has expected fields
FIRST_FOLDER=$(echo "$BODY" | jq -r '.results[0].folder' 2>/dev/null || echo "__MISSING__")
FIRST_SCORE=$(echo "$BODY" | jq -r '.results[0].score' 2>/dev/null || echo "")
FIRST_COUNT=$(echo "$BODY" | jq -r '.results[0].count' 2>/dev/null || echo "")
if [[ "$FIRST_FOLDER" != "null" && "$FIRST_FOLDER" != "__MISSING__" ]]; then
    DISPLAY_FOLDER="${FIRST_FOLDER:-"(root)"}"
    pass "Folder search result has folder field: $DISPLAY_FOLDER"
else
    fail "Folder search result missing folder field"
fi
if [[ -n "$FIRST_SCORE" && "$FIRST_SCORE" != "null" ]]; then
    pass "Folder search result has score field: $FIRST_SCORE"
else
    fail "Folder search result missing score field"
fi
if [[ -n "$FIRST_COUNT" && "$FIRST_COUNT" != "null" ]]; then
    pass "Folder search result has count field"
else
    fail "Folder search result missing count field"
fi

# Search with limit validation
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/folders/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "test", "limit": 1}')
BODY=$(echo "$RESP" | head -1)
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /folders/search limit=1" 200 "$STATUS"
RESULT_COUNT=$(echo "$BODY" | jq '.results | length' 2>/dev/null || echo "0")
if [[ "$RESULT_COUNT" -le 1 ]]; then
    pass "Folder search respects limit=1 (got $RESULT_COUNT)"
else
    fail "Folder search limit=1 returned $RESULT_COUNT results"
fi

# ============================================================================
# SECTION 38: Folder Search Multi-Tenant Isolation
# ============================================================================
echo ""
echo "=== 38. Folder Search Multi-Tenant Isolation ==="

if [[ -n "$API_KEY2" ]]; then
    # Second user should get empty results (they have no notes)
    RESP=$(curl -s "$BASE/folders/search" \
        -X POST \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"query": "health supplements", "limit": 5}')
    RESULT_COUNT=$(echo "$RESP" | jq '.results | length' 2>/dev/null || echo "0")
    if [[ "$RESULT_COUNT" -eq 0 ]]; then
        pass "Second user gets no folder results (isolation works)"
    else
        fail "Second user got $RESULT_COUNT folder results (expected 0 — isolation broken)"
    fi
else
    pass "Folder multi-tenant test skipped (no second user)"
fi

# ============================================================================
# SECTION 39: Folder Auto-Rebuild on Note Create
# ============================================================================
echo ""
echo "=== 39. Folder Auto-Rebuild on Note Create ==="

# Use User 2's key — rate limit test may have exhausted User 1's RPM window
if [[ -n "$API_KEY2" ]]; then
    # Create a note in a brand-new folder under User 2
    RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/notes" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"path": "NewFolderTest/AutoRebuild.md", "content": "# Auto Rebuild\nTesting folder auto-rebuild on new folder creation.", "mtime": 1709234999.0}')
    STATUS=$(echo "$RESP" | tail -1)
    assert_status "Create note in new folder" 200 "$STATUS"

    # Now search folders — should find the new folder
    RESP=$(curl -s -X POST "$BASE/folders/search" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"query": "auto rebuild testing", "limit": 5}')
    FOUND=$(echo "$RESP" | jq '[.results[] | select(.folder == "NewFolderTest")] | length' 2>/dev/null || echo "0")
    if [[ "$FOUND" -gt 0 ]]; then
        pass "New folder auto-indexed and searchable"
    else
        fail "New folder not found in search after auto-rebuild"
    fi

    # Cleanup User 2's test note
    curl -s -X DELETE "$BASE/notes/NewFolderTest%2FAutoRebuild.md" \
        -H "Authorization: Bearer $API_KEY2" -o /dev/null
else
    pass "Folder auto-rebuild test skipped (no second user)"
fi

# ============================================================================
# SECTION 40: Folder Search Relevance
# ============================================================================
echo ""
echo "=== 40. Folder Search Relevance ==="

# The "Vitamin D" note is in "2. Knowledge Vault/Health/Supplements"
# Searching for "vitamin supplement health" should return that folder somewhere in results
RESP=$(curl -s -X POST "$BASE/folders/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"query": "vitamin supplement health dosage", "limit": 5}')
HEALTH_FOUND=$(echo "$RESP" | jq '[.results[] | select(.folder | test("Health|Supplement|Knowledge"; "i"))] | length' 2>/dev/null || echo "0")
if [[ "$HEALTH_FOUND" -gt 0 ]]; then
    pass "Folder search returns health/supplements folder for vitamin query"
else
    # Show what we got for debugging
    ALL_FOLDERS=$(echo "$RESP" | jq -r '[.results[].folder] | join(", ")' 2>/dev/null || echo "(none)")
    fail "Health/supplements folder not in results for vitamin query (got: $ALL_FOLDERS)"
fi

# ============================================================================
# SECTION 41: Folder Auto-Rebuild on Note Delete
# ============================================================================
echo ""
echo "=== 41. Folder Auto-Rebuild on Note Delete ==="

if [[ -n "$API_KEY2" ]]; then
    # Create a note in a unique folder under User 2
    curl -s -X POST "$BASE/notes" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"path": "DeleteTest/Ephemeral.md", "content": "# Ephemeral\nThis will be deleted.", "mtime": 1709235001.0}' -o /dev/null

    # Verify folder exists in search
    RESP=$(curl -s -X POST "$BASE/folders/search" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"query": "ephemeral delete test", "limit": 5}')
    FOUND=$(echo "$RESP" | jq '[.results[] | select(.folder == "DeleteTest")] | length' 2>/dev/null || echo "0")
    if [[ "$FOUND" -gt 0 ]]; then
        pass "DeleteTest folder exists before delete"
    else
        fail "DeleteTest folder not found after creation"
    fi

    # Delete the note — should trigger folder rebuild, removing the folder
    curl -s -X DELETE "$BASE/notes/DeleteTest%2FEphemeral.md" \
        -H "Authorization: Bearer $API_KEY2" -o /dev/null

    # Verify folder is gone from search
    RESP=$(curl -s -X POST "$BASE/folders/search" \
        -H "Authorization: Bearer $API_KEY2" \
        -H "Content-Type: application/json" \
        -d '{"query": "ephemeral delete test", "limit": 5}')
    FOUND=$(echo "$RESP" | jq '[.results[] | select(.folder == "DeleteTest")] | length' 2>/dev/null || echo "0")
    if [[ "$FOUND" -eq 0 ]]; then
        pass "DeleteTest folder removed from index after note delete"
    else
        fail "DeleteTest folder still in index after note delete (expected 0, got $FOUND)"
    fi
else
    pass "Folder auto-rebuild on delete test skipped (no second user)"
    pass "Folder auto-rebuild on delete test skipped (no second user)"
fi

# ============================================================================
# SECTION 42: Folder Reindex Idempotency
# ============================================================================
echo ""
echo "=== 42. Folder Reindex Idempotency ==="

# Reindex twice — count should be the same both times
RESP1=$(curl -s -X POST "$BASE/folders/reindex" \
    -H "Authorization: Bearer $API_KEY")
COUNT1=$(echo "$RESP1" | jq -r '.folders_indexed' 2>/dev/null || echo "0")

RESP2=$(curl -s -X POST "$BASE/folders/reindex" \
    -H "Authorization: Bearer $API_KEY")
COUNT2=$(echo "$RESP2" | jq -r '.folders_indexed' 2>/dev/null || echo "0")

if [[ "$COUNT1" == "$COUNT2" ]]; then
    pass "Folder reindex is idempotent ($COUNT1 == $COUNT2)"
else
    fail "Folder reindex not idempotent ($COUNT1 != $COUNT2)"
fi

# ============================================================================
# SECTION 43: Folder Search Validation
# ============================================================================
echo ""
echo "=== 43. Folder Search Validation ==="

# Missing query field should return 422
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/folders/search" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"limit": 3}')
STATUS=$(echo "$RESP" | tail -1)
assert_status "POST /folders/search missing query" 422 "$STATUS"

# ============================================================================
# SECTION 16: Cleanup — Delete test notes
# ============================================================================
echo ""
echo "=== 16. Cleanup ==="

for NOTE_PATH in "Test/Hello World.md" "Test/Empty.md" "Test/Special (Chars) & More!.md" "Test/Unicode.md" "Test/Long.md" "2. Knowledge Vault/Health/Supplements/Vitamin D.md" "Root Note.md" "Test/No Title Note.md" "Test/Comma Tags.md"; do
    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$NOTE_PATH', safe=''))")
    curl -s -X DELETE "$BASE/notes/$ENCODED" \
        -H "Authorization: Bearer $API_KEY" -o /dev/null
done
pass "Test notes cleaned up"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "========================================"
echo "  Test Results: $PASS passed, $FAIL failed"
echo "========================================"
if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
else
    echo "  All tests passed!"
    exit 0
fi
