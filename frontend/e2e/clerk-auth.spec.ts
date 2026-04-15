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

// Verified selectors from live Clerk v5 DOM inspection:
//   Root:   data-clerk-component="SignIn", classes: cl-rootBox cl-signIn-root
//   Input:  cl-formFieldInput__identifier (email/username), cl-formFieldInput__password
//   Submit: cl-formButtonPrimary
//   Title:  h1.cl-headerTitle
const SIGN_IN = '[data-clerk-component="SignIn"]'
const SIGN_UP = '[data-clerk-component="SignUp"]'
const EMAIL_INPUT = '.cl-formFieldInput__identifier input, input.cl-formFieldInput__identifier'
const PASSWORD_INPUT = '.cl-formFieldInput__password input, input.cl-formFieldInput__password'
const SUBMIT_BTN = '.cl-formButtonPrimary'
const USER_BUTTON = '[data-clerk-component="UserButton"]'
const ERROR_TEXT = '.cl-formFieldErrorText'

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
    await page.goto('/app/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })

    await page.locator(EMAIL_INPUT).first().fill(state.email)
    await page.locator(SUBMIT_BTN).first().click()

    await expect(page.locator(PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(PASSWORD_INPUT).first().fill(state.password)
    await page.locator(SUBMIT_BTN).first().click()

    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })
  })

  test('Clerk UserButton renders in header', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })
    await page.locator(EMAIL_INPUT).first().fill(state.email)
    await page.locator(SUBMIT_BTN).first().click()
    await expect(page.locator(PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(PASSWORD_INPUT).first().fill(state.password)
    await page.locator(SUBMIT_BTN).first().click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await expect(page.locator(USER_BUTTON)).toBeVisible()
    await expect(page.getByLabel('User menu')).toHaveCount(0)
  })

  test('sign out via Clerk → redirects', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })
    await page.locator(EMAIL_INPUT).first().fill(state.email)
    await page.locator(SUBMIT_BTN).first().click()
    await expect(page.locator(PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(PASSWORD_INPUT).first().fill(state.password)
    await page.locator(SUBMIT_BTN).first().click()
    await expect(page).toHaveURL(/\/app\/?$/, { timeout: 15_000 })

    await page.locator(USER_BUTTON).click()
    await page.getByRole('menuitem', { name: /sign out/i }).click()

    await expect(page).toHaveURL(/\/sign-in/, { timeout: 10_000 })
  })

  test('wrong password shows Clerk error', async ({ page }) => {
    await page.goto('/app/sign-in/')
    await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 })

    await page.locator(EMAIL_INPUT).first().fill(state.email)
    await page.locator(SUBMIT_BTN).first().click()
    await expect(page.locator(PASSWORD_INPUT).first()).toBeVisible({ timeout: 10_000 })
    await page.locator(PASSWORD_INPUT).first().fill('WrongPassword!99')
    await page.locator(SUBMIT_BTN).first().click()

    await expect(page.locator(ERROR_TEXT).first()).toBeVisible({ timeout: 10_000 })
    await expect(page).toHaveURL(/\/sign-in/)
  })
})
