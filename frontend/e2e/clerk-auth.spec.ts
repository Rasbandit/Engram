import { test, expect } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')

function loadAuthState(): { email: string; password: string; clerk_user_id: string; skipped: boolean } {
  if (!fs.existsSync(AUTH_STATE_PATH)) {
    return { email: '', password: '', clerk_user_id: '', skipped: true }
  }
  return JSON.parse(fs.readFileSync(AUTH_STATE_PATH, 'utf-8'))
}

test.describe('Clerk auth provider', () => {
  const state = loadAuthState()

  test.skip(() => state.skipped, 'E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests')

  test('redirects unauthenticated users to sign-in with Clerk UI', async ({ page }) => {
    await page.goto('/app/')
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.locator('.cl-signIn')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByRole('heading', { name: 'Sign in to Engram' })).toHaveCount(0)
  })

  test('renders Clerk SignUp component', async ({ page }) => {
    await page.goto('/app/sign-up/')
    await expect(page.locator('.cl-signUp')).toBeVisible({ timeout: 15_000 })
  })

  test('sign in via Clerk → dashboard', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator('.cl-signIn')).toBeVisible({ timeout: 15_000 })

    await page.locator('.cl-formFieldInput__emailAddress').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()

    await expect(page.locator('.cl-formFieldInput__password')).toBeVisible({ timeout: 10_000 })
    await page.locator('.cl-formFieldInput__password').fill(state.password)
    await page.locator('.cl-formButtonPrimary').click()

    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })
  })

  test('Clerk UserButton renders in header', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator('.cl-signIn')).toBeVisible({ timeout: 15_000 })
    await page.locator('.cl-formFieldInput__emailAddress').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()
    await expect(page.locator('.cl-formFieldInput__password')).toBeVisible({ timeout: 10_000 })
    await page.locator('.cl-formFieldInput__password').fill(state.password)
    await page.locator('.cl-formButtonPrimary').click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await expect(page.locator('.cl-userButtonTrigger')).toBeVisible()
    await expect(page.getByLabel('User menu')).toHaveCount(0)
  })

  test('sign out via Clerk → redirects', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator('.cl-signIn')).toBeVisible({ timeout: 15_000 })
    await page.locator('.cl-formFieldInput__emailAddress').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()
    await expect(page.locator('.cl-formFieldInput__password')).toBeVisible({ timeout: 10_000 })
    await page.locator('.cl-formFieldInput__password').fill(state.password)
    await page.locator('.cl-formButtonPrimary').click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await page.locator('.cl-userButtonTrigger').click()
    await page.getByRole('menuitem', { name: /sign out/i }).click()

    await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })
  })

  test('wrong password shows Clerk error', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator('.cl-signIn')).toBeVisible({ timeout: 15_000 })

    await page.locator('.cl-formFieldInput__emailAddress').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()
    await expect(page.locator('.cl-formFieldInput__password')).toBeVisible({ timeout: 10_000 })
    await page.locator('.cl-formFieldInput__password').fill('WrongPassword!99')
    await page.locator('.cl-formButtonPrimary').click()

    await expect(page.locator('.cl-formFieldErrorText')).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/sign-in/)
  })
})
