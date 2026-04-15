import { test, expect, type Page } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'

const AUTH_STATE_PATH = path.join(__dirname, '.auth-state.json')

function loadAuthState(): { email: string; password: string; clerk_user_id: string; skipped: boolean } {
  if (!fs.existsSync(AUTH_STATE_PATH)) {
    return { email: '', password: '', clerk_user_id: '', skipped: true }
  }
  return JSON.parse(fs.readFileSync(AUTH_STATE_PATH, 'utf-8'))
}

// Verified selectors from live Clerk v5 DOM inspection:
//   Root:     data-clerk-component="SignIn" / "SignUp"
//   Email:    input[name="identifier"]
//   Password: input[name="password"]
//   Submit:   .cl-formButtonPrimary (only one per step — social buttons use cl-socialButtonsIconButton)
//   User btn: data-clerk-component="UserButton"
const SIGN_IN = '[data-clerk-component="SignIn"]'
const SIGN_UP = '[data-clerk-component="SignUp"]'
const USER_BUTTON = '[data-clerk-component="UserButton"]'

/** Sign in through Clerk's multi-step flow (email → password → dashboard). */
async function clerkSignIn(page: Page, email: string, password: string) {
  await page.goto('/app/sign-in/')
  await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })

  // Step 1: enter email
  await page.locator('input[name="identifier"]').fill(email)
  await page.locator('.cl-formButtonPrimary').click()

  // Step 2: enter password (Clerk navigates to #/factor-one)
  const pwInput = page.locator('input[name="password"]')
  await expect(pwInput).toBeVisible({ timeout: 10_000 })
  await pwInput.fill(password)
  // Press Enter to submit — more reliable than clicking Clerk's button
  await pwInput.press('Enter')

  await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })
}

test.describe('Clerk auth provider', () => {
  const state = loadAuthState()

  test.skip(() => state.skipped, 'E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests')

  test('redirects unauthenticated users to sign-in with Clerk UI', async ({ page }) => {
    await page.goto('/app/')
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('h1.cl-headerTitle')).toContainText('Sign in')
  })

  test('renders Clerk SignUp component', async ({ page }) => {
    await page.goto('/app/sign-up/')
    await expect(page.locator(SIGN_UP)).toBeVisible({ timeout: 15_000 })
  })

  test('sign in via Clerk → dashboard', async ({ page }) => {
    await clerkSignIn(page, state.email, state.password)
  })

  test('Clerk UserButton renders in header', async ({ page }) => {
    await clerkSignIn(page, state.email, state.password)

    await expect(page.locator(USER_BUTTON)).toBeVisible()
    await expect(page.getByLabel('User menu')).toHaveCount(0)
  })

  test('sign out via Clerk → redirects', async ({ page }) => {
    await clerkSignIn(page, state.email, state.password)

    await page.locator(USER_BUTTON).click()
    await page.getByRole('menuitem', { name: /sign out/i }).click()

    await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })
  })

  test('wrong password shows Clerk error', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })

    await page.locator('input[name="identifier"]').fill(state.email)
    await page.locator('.cl-formButtonPrimary').click()

    const pwInput = page.locator('input[name="password"]')
    await expect(pwInput).toBeVisible({ timeout: 10_000 })
    await pwInput.fill('WrongPassword!99')
    await page.locator('.cl-formButtonPrimary').click()

    await expect(page.locator('.cl-formFieldErrorText').first()).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/sign-in/)
  })
})
