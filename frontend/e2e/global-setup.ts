import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')
const CLERK_API = 'https://api.clerk.com/v1'

export default async function globalSetup() {
  const secretKey = process.env.E2E_CLERK_SECRET_KEY
  if (!secretKey) {
    console.log('E2E_CLERK_SECRET_KEY not set — Clerk browser tests will be skipped')
    fs.writeFileSync(AUTH_STATE_PATH, JSON.stringify({ skipped: true }))
    return
  }

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
