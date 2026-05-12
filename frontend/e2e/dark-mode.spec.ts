import { test, expect } from '@playwright/test'

const TEST_PASSWORD = 'E2eTestPass!99'

async function registerUser(baseURL: string, email: string) {
  const res = await fetch(`${baseURL}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: TEST_PASSWORD }),
  })
  if (res.status === 422) return
  if (!res.ok) throw new Error(`Register failed: ${res.status} ${await res.text()}`)
}

function testEmail(label: string) {
  return `e2e-theme-${Date.now()}-${label}@test.com`
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/sign-in/')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('button', { name: /sign in/i }).click()
  await expect(page).toHaveURL('/')
}

test.describe('Dark mode', () => {
  test('header toggle cycles Light → Dark → System and persists', async ({ page, baseURL }) => {
    const email = testEmail('cycle')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    const toggle = page.getByRole('button', { name: /switch to .* theme/i })
    // Default is system. On a default headless Chromium, system pref is light.
    await expect(page.locator('html')).not.toHaveClass(/dark/)

    // System → Light
    await toggle.click()
    await expect(toggle).toHaveAttribute('data-theme-choice', 'light')
    await expect(page.locator('html')).not.toHaveClass(/dark/)

    // Light → Dark
    await toggle.click()
    await expect(toggle).toHaveAttribute('data-theme-choice', 'dark')
    await expect(page.locator('html')).toHaveClass(/dark/)

    // Dark → System
    await toggle.click()
    await expect(toggle).toHaveAttribute('data-theme-choice', 'system')

    const stored = await page.evaluate(() => window.localStorage.getItem('engram:theme'))
    expect(stored).toBe('system')
  })

  test('Settings → Appearance segmented control sets theme', async ({ page, baseURL }) => {
    const email = testEmail('settings')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    await page.goto('/settings/appearance')
    await page.getByRole('button', { name: 'Dark' }).click()
    await expect(page.locator('html')).toHaveClass(/dark/)
    await expect(page.getByRole('button', { name: 'Dark' })).toHaveAttribute('aria-pressed', 'true')

    await page.getByRole('button', { name: 'Light' }).click()
    await expect(page.locator('html')).not.toHaveClass(/dark/)
    await expect(page.getByRole('button', { name: 'Light' })).toHaveAttribute('aria-pressed', 'true')
  })

  test('System mode tracks prefers-color-scheme', async ({ browser, baseURL }) => {
    const email = testEmail('system')
    await registerUser(baseURL!, email)

    const ctx = await browser.newContext({ colorScheme: 'dark' })
    const page = await ctx.newPage()
    await signIn(page, email)

    // First-paint check: with empty storage (system) + colorScheme dark, html should have .dark.
    await expect(page.locator('html')).toHaveClass(/dark/)
    await ctx.close()
  })

  test('FOUC-free: pre-seeded localStorage applies class before React mounts', async ({ browser, baseURL }) => {
    const email = testEmail('fouc')
    await registerUser(baseURL!, email)

    const ctx = await browser.newContext()
    await ctx.addInitScript(() => {
      window.localStorage.setItem('engram:theme', 'dark')
    })
    const page = await ctx.newPage()
    await page.goto(baseURL! + '/sign-in/')
    // At domcontentloaded the inline boot script has already run.
    await page.waitForLoadState('domcontentloaded')
    await expect(page.locator('html')).toHaveClass(/dark/)
    await ctx.close()
  })
})
