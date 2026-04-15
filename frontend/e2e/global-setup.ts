import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execSync } from 'node:child_process'
import { clerkSetup } from '@clerk/testing/playwright'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')
const CLERK_API = 'https://api.clerk.com/v1'

export default async function globalSetup() {
  // Clean up stale test users from previous runs (in case teardown didn't run)
  const dbUrl = process.env.DATABASE_URL
  if (dbUrl) {
    try {
      execSync(
        `psql "${dbUrl}" -c "DELETE FROM users WHERE email LIKE 'e2e-local-%@test.com' OR email LIKE 'e2e-browser-%@test.com';"`,
        { encoding: 'utf-8', timeout: 10_000 },
      )
      console.log('Cleaned up stale test users from previous runs')
    } catch {
      // Non-fatal
    }
  }

  const secretKey = process.env.E2E_CLERK_SECRET_KEY
  if (!secretKey) {
    console.log('E2E_CLERK_SECRET_KEY not set — Clerk browser tests will be skipped')
    fs.writeFileSync(AUTH_STATE_PATH, JSON.stringify({ skipped: true }))
    return
  }

  // Set CLERK_SECRET_KEY for @clerk/testing (it reads this env var)
  process.env.CLERK_SECRET_KEY = secretKey
  await clerkSetup()

  const ts = Date.now()
  const email = `e2e-browser-${ts}@test.com`
  const password = crypto.randomBytes(12).toString('base64url')

  const resp = await fetch(`${CLERK_API}/users`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email_address: [email],
      username: `e2e-browser-${ts}`,
      password,
      skip_password_checks: true,
    }),
  })

  if (!resp.ok) {
    const body = await resp.text()
    throw new Error(`Clerk user creation failed: ${resp.status} ${body}`)
  }

  const user = await resp.json()
  console.log(`Clerk test user created: ${email} (${user.id})`)

  fs.writeFileSync(
    AUTH_STATE_PATH,
    JSON.stringify({
      email,
      password,
      clerk_user_id: user.id,
      skipped: false,
    }),
  )
}
