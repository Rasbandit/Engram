import { test, expect } from '@playwright/test'

const ts = Date.now()
const TEST_EMAIL = `e2e-local-${ts}@test.com`
const TEST_EMAIL_2 = `e2e-local-${ts}-2@test.com`
const TEST_PASSWORD = 'E2eTestPass!99'

// Capture browser console + network + navigation for debugging CI failures
test.beforeEach(async ({ page }) => {
  const messages: string[] = []
  const t0 = Date.now()
  const ts = () => `+${Date.now() - t0}ms`
  page.on('console', (msg) => {
    const text = msg.text()
    if (text.startsWith('[AUTH') || text.startsWith('[SIGN') || text.startsWith('[PAGE')) {
      messages.push(`${ts()} [console:${msg.type()}] ${text}`)
    }
  })
  page.on('pageerror', (err) => {
    messages.push(`${ts()} [PAGE-ERROR] ${err.message}`)
  })
  page.on('response', (response) => {
    const url = response.url()
    if (url.includes('/api/auth/')) {
      messages.push(`${ts()} [network] ${response.request().method()} ${url} → ${response.status()}`)
    }
  })
  // Detect ALL navigations (client-side + full reloads)
  page.on('framenavigated', (frame) => {
    if (frame === page.mainFrame()) {
      messages.push(`${ts()} [NAVIGATE] ${frame.url()}`)
    }
  })
  page.on('load', () => {
    messages.push(`${ts()} [FULL-PAGE-LOAD] ${page.url()}`)
  })
  ;(page as unknown as Record<string, unknown>).__authLogs = messages
})

test.afterEach(async ({ page }, testInfo) => {
  const messages = (page as unknown as Record<string, unknown>).__authLogs as string[] | undefined
  if (messages?.length) {
    console.log('=== Auth debug logs for:', testInfo.title, '===')
    for (const m of messages) console.log(m)
    console.log('=== End auth debug logs ===')
  }
})

test.describe('Local auth provider', () => {
  test('redirects unauthenticated users to sign-in', async ({ page }) => {
    await page.goto('/app/')
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.getByRole('heading', { name: 'Sign in to Engram' })).toBeVisible()
    await expect(page.locator('.cl-signIn')).toHaveCount(0)
  })

  test('register first user → redirects to dashboard', async ({ page }) => {
    await page.goto('/app/sign-up/')
    await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible()

    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByLabel('Confirm password').fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 10_000 })
    await expect(page.getByLabel('User menu')).toBeVisible()
  })

  test('sign out → redirects to sign-in', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Sign in' }).click()
    // Poll URL every 500ms for 5s to capture the exact transition
    for (let i = 0; i < 10; i++) {
      await page.waitForTimeout(500)
      const url = page.url()
      console.log(`[TEST:sign-out] t+${(i + 1) * 500}ms URL: ${url}`)
      if (/\/app\/?$/.test(url)) break
    }
    const logs = (page as unknown as Record<string, unknown>).__authLogs as string[]
    console.log(`[TEST:sign-out] final dump (${logs.length} entries):`)
    for (const m of logs) console.log(m)
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 10_000 })

    await page.getByLabel('User menu').click()
    await page.getByRole('button', { name: 'Sign out' }).click()

    await expect(page).toHaveURL(/\/sign-in/)
  })

  test('sign in with existing credentials → dashboard', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Sign in' }).click()
    // Poll URL every 500ms for 5s to capture the exact transition
    for (let i = 0; i < 10; i++) {
      await page.waitForTimeout(500)
      const url = page.url()
      console.log(`[TEST:sign-in] t+${(i + 1) * 500}ms URL: ${url}`)
      if (/\/app\/?$/.test(url)) break
    }
    const logs = (page as unknown as Record<string, unknown>).__authLogs as string[]
    console.log(`[TEST:sign-in] final dump (${logs.length} entries):`)
    for (const m of logs) console.log(m)
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 10_000 })
  })

  test('wrong password shows error', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill('WrongPassword!')
    await page.getByRole('button', { name: 'Sign in' }).click()

    await expect(page.getByRole('alert')).toBeVisible()
    await expect(page).toHaveURL(/\/sign-in/)
  })

  test('second user registration works', async ({ page }) => {
    await page.goto('/app/sign-up/')
    await page.getByLabel('Email').fill(TEST_EMAIL_2)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByLabel('Confirm password').fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 10_000 })
  })
})
