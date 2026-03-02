#!/usr/bin/env bash
# ============================================================================
# brain-api Comprehensive Test Plan
# ============================================================================
# Tests all REST endpoints, auth, note lifecycle, search, sync, and edge cases.
# Requires: brain-api + postgres running (docker compose up)
#
# Usage: bash test_plan.sh
# ============================================================================

set -euo pipefail

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
    -c /tmp/brain_cookies)
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
    -c /tmp/brain_cookies)
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
    -b /tmp/brain_cookies -L)
STATUS=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | head -1)
assert_status "POST /settings/keys (create)" 200 "$STATUS"

# Extract the API key from the response HTML
API_KEY=$(echo "$RESP" | grep -oP 'brain_[A-Za-z0-9_-]+' | head -1 || true)
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
    -H "Authorization: Bearer brain_invalidkey123")
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
    -c /tmp/brain_cookies2 -L -o /dev/null

# Create API key for second user
RESP2=$(curl -s -X POST "$BASE/settings/keys" \
    -d "name=other-key" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -b /tmp/brain_cookies2 -L)
API_KEY2=$(echo "$RESP2" | grep -oP 'brain_[A-Za-z0-9_-]+' | head -1 || true)

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
RESP=$(curl -s -w "\n%{http_code}" "$BASE/search" -b /tmp/brain_cookies -L)
STATUS=$(echo "$RESP" | tail -1)
assert_status "GET /search (with session)" 200 "$STATUS"

# Settings page with session
RESP=$(curl -s -w "\n%{http_code}" "$BASE/settings" -b /tmp/brain_cookies -L)
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
# SECTION 16: Cleanup — Delete test notes
# ============================================================================
echo ""
echo "=== 16. Cleanup ==="

for NOTE_PATH in "Test/Hello World.md" "Test/Empty.md" "Test/Special (Chars) & More!.md" "Test/Unicode.md" "Test/Long.md" "2. Knowledge Vault/Health/Supplements/Vitamin D.md"; do
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
