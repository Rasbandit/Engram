import { test, expect } from '@playwright/test'

const ts = Date.now()
const TEST_EMAIL = `e2e-local-${ts}@test.com`
const TEST_EMAIL_2 = `e2e-local-${ts}-2@test.com`
const TEST_PASSWORD = 'E2eTestPass!99'

// Capture browser console + network for debugging CI failures
test.beforeEach(async ({ page }) => {
  const messages: string[] = []
  page.on('console', (msg) => {
    const text = msg.text()
    if (text.startsWith('[AUTH') || text.startsWith('[SIGN') || text.startsWith('[PAGE')) {
      messages.push(`[console:${msg.type()}] ${text}`)
    }
  })
  page.on('pageerror', (err) => {
    messages.push(`[PAGE-ERROR] ${err.message}`)
  })
  // Log auth-related API requests/responses
  page.on('response', (response) => {
    const url = response.url()
    if (url.includes('/api/auth/')) {
      messages.push(`[network] ${response.request().method()} ${url} → ${response.status()}`)
    }
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
    console.log('[TEST:sign-out] clicking Sign in, current URL:', page.url())
    await page.getByRole('button', { name: 'Sign in' }).click()
    // Wait a beat then dump state before assertion
    await page.waitForTimeout(2_000)
    const logs = (page as unknown as Record<string, unknown>).__authLogs as string[]
    console.log('[TEST:sign-out] pre-assert URL:', page.url(), 'log count:', logs.length)
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
    console.log('[TEST:sign-in] clicking Sign in, current URL:', page.url())
    await page.getByRole('button', { name: 'Sign in' }).click()
    // Wait a beat then dump state before assertion
    await page.waitForTimeout(2_000)
    const logs = (page as unknown as Record<string, unknown>).__authLogs as string[]
    console.log('[TEST:sign-in] pre-assert URL:', page.url(), 'log count:', logs.length)
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
