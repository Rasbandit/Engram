import fs from 'node:fs'
import path from 'node:path'
import { execSync } from 'node:child_process'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')
const CLERK_API = 'https://api.clerk.com/v1'

export default async function globalTeardown() {
  // 1. Clean up e2e test users from backend DB (both local + clerk tests)
  await cleanupDatabaseUsers()

  // 2. Clean up Clerk test user via API
  await cleanupClerkUser()
}

async function cleanupDatabaseUsers() {
  const dbUrl = process.env.DATABASE_URL
  if (!dbUrl) {
    console.log('DATABASE_URL not set — skipping DB cleanup')
    return
  }

  try {
    // Delete users created by browser E2E tests (pattern: e2e-local-* and e2e-browser-*)
    const result = execSync(
      `psql "${dbUrl}" -t -c "DELETE FROM users WHERE email LIKE 'e2e-local-%@test.com' OR email LIKE 'e2e-browser-%@test.com' RETURNING email;"`,
      { encoding: 'utf-8', timeout: 10_000 },
    ).trim()

    if (result) {
      const deleted = result.split('\n').map((l) => l.trim()).filter(Boolean)
      console.log(`Cleaned up ${deleted.length} test user(s) from DB: ${deleted.join(', ')}`)
    } else {
      console.log('No test users to clean up in DB')
    }
  } catch (err) {
    // Non-fatal — don't fail the suite over cleanup
    console.warn(`DB cleanup failed (non-fatal): ${err instanceof Error ? err.message : err}`)
  }
}

async function cleanupClerkUser() {
  if (!fs.existsSync(AUTH_STATE_PATH)) return

  const state = JSON.parse(fs.readFileSync(AUTH_STATE_PATH, 'utf-8'))

  if (state.skipped) {
    fs.unlinkSync(AUTH_STATE_PATH)
    return
  }

  const secretKey = process.env.E2E_CLERK_SECRET_KEY
  if (!secretKey || !state.clerk_user_id) {
    fs.unlinkSync(AUTH_STATE_PATH)
    return
  }

  const resp = await fetch(`${CLERK_API}/users/${state.clerk_user_id}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${secretKey}` },
  })

  if (resp.ok) {
    console.log(`Clerk test user deleted: ${state.clerk_user_id}`)
  } else {
    console.warn(`Failed to delete Clerk user ${state.clerk_user_id}: ${resp.status}`)
  }

  fs.unlinkSync(AUTH_STATE_PATH)
}
