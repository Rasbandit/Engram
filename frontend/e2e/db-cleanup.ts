import pg from 'pg'

const TEST_EMAIL_PATTERNS = ['e2e-local-%@test.com', 'e2e-browser-%@test.com']

export async function cleanupTestUsers(phase: 'setup' | 'teardown'): Promise<void> {
  const dbUrl = process.env.DATABASE_URL
  if (!dbUrl) {
    console.log('DATABASE_URL not set — skipping DB cleanup')
    return
  }

  const client = new pg.Client({ connectionString: dbUrl })

  try {
    await client.connect()

    const conditions = TEST_EMAIL_PATTERNS.map((_, i) => `email LIKE $${i + 1}`).join(' OR ')
    const result = await client.query(
      `DELETE FROM users WHERE ${conditions} RETURNING email`,
      TEST_EMAIL_PATTERNS,
    )

    if (result.rowCount && result.rowCount > 0) {
      const emails = result.rows.map((r: { email: string }) => r.email)
      console.log(`[${phase}] Cleaned up ${emails.length} test user(s): ${emails.join(', ')}`)
    } else {
      console.log(`[${phase}] No test users to clean up`)
    }
  } catch (err) {
    console.warn(`[${phase}] DB cleanup failed (non-fatal): ${err instanceof Error ? err.message : err}`)
  } finally {
    await client.end()
  }
}
