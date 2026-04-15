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

// Clerk component selectors — use data attributes (stable) over cl- classes (can change)
const CLERK_SIGN_IN = '[data-clerk-component="SignIn"], .cl-signIn, .cl-rootBox'
const CLERK_SIGN_UP = '[data-clerk-component="SignUp"], .cl-signUp, .cl-rootBox'
const CLERK_EMAIL_INPUT = 'input[name="identifier"], .cl-formFieldInput__emailAddress'
const CLERK_PASSWORD_INPUT = 'input[name="password"], .cl-formFieldInput__password'
const CLERK_SUBMIT = 'button:has-text("Continue"), .cl-formButtonPrimary'
const CLERK_USER_BUTTON = '.cl-userButtonTrigger, [data-clerk-component="UserButton"]'
const CLERK_ERROR = '.cl-formFieldErrorText, [data-clerk-field-error]'

test.describe('Clerk auth provider', () => {
  const state = loadAuthState()

  test.skip(() => state.skipped, 'E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests')

  test('redirects unauthenticated users to sign-in with Clerk UI', async ({ page }) => {
    await page.goto('/app/')
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.locator(CLERK_SIGN_IN).first()).toBeVisible({ timeout: 15_000 })
    // Local sign-in heading should NOT be present — Clerk provides its own
    await expect(page.getByRole('heading', { name: 'Sign in to Engram' })).toBeVisible({ timeout: 5_000 })
  })

  test('renders Clerk SignUp component', async ({ page }) => {
    await page.goto('/app/sign-up/')
    await expect(page.locator(CLERK_SIGN_UP).first()).toBeVisible({ timeout: 15_000 })
  })

  test('sign in via Clerk → dashboard', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(CLERK_SIGN_IN).first()).toBeVisible({ timeout: 15_000 })

    await page.locator(CLERK_EMAIL_INPUT).first().fill(state.email)
    await page.locator(CLERK_SUBMIT).first().click()

    await expect(page.locator(CLERK_PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(CLERK_PASSWORD_INPUT).first().fill(state.password)
    await page.locator(CLERK_SUBMIT).first().click()

    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })
  })

  test('Clerk UserButton renders in header', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(CLERK_SIGN_IN).first()).toBeVisible({ timeout: 15_000 })
    await page.locator(CLERK_EMAIL_INPUT).first().fill(state.email)
    await page.locator(CLERK_SUBMIT).first().click()
    await expect(page.locator(CLERK_PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(CLERK_PASSWORD_INPUT).first().fill(state.password)
    await page.locator(CLERK_SUBMIT).first().click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await expect(page.locator(CLERK_USER_BUTTON).first()).toBeVisible()
    await expect(page.getByLabel('User menu')).toHaveCount(0)
  })

  test('sign out via Clerk → redirects', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(CLERK_SIGN_IN).first()).toBeVisible({ timeout: 15_000 })
    await page.locator(CLERK_EMAIL_INPUT).first().fill(state.email)
    await page.locator(CLERK_SUBMIT).first().click()
    await expect(page.locator(CLERK_PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(CLERK_PASSWORD_INPUT).first().fill(state.password)
    await page.locator(CLERK_SUBMIT).first().click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await page.locator(CLERK_USER_BUTTON).first().click()
    await page.getByRole('menuitem', { name: /sign out/i }).click()

    await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })
  })

  test('wrong password shows Clerk error', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(CLERK_SIGN_IN).first()).toBeVisible({ timeout: 15_000 })

    await page.locator(CLERK_EMAIL_INPUT).first().fill(state.email)
    await page.locator(CLERK_SUBMIT).first().click()
    await expect(page.locator(CLERK_PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(CLERK_PASSWORD_INPUT).first().fill('WrongPassword!99')
    await page.locator(CLERK_SUBMIT).first().click()

    await expect(page.locator(CLERK_ERROR).first()).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/sign-in/)
  })
})
