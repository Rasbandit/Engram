import { test, expect } from '@playwright/test'

const ts = Date.now()
const TEST_EMAIL = `e2e-local-${ts}@test.com`
const TEST_EMAIL_2 = `e2e-local-${ts}-2@test.com`
const TEST_PASSWORD = 'E2eTestPass!99'

test.describe('Local auth provider', () => {
  test('redirects unauthenticated users to sign-in', async ({ page }) => {
    await page.goto('/app')
    await expect(page).toHaveURL(/\/sign-in/)
    await expect(page.getByRole('heading', { name: 'Sign in to Engram' })).toBeVisible()
    await expect(page.locator('.cl-signIn')).toHaveCount(0)
  })

  test('register first user → redirects to dashboard', async ({ page }) => {
    await page.goto('/app/sign-up')
    await expect(page.getByRole('heading', { name: 'Create your account' })).toBeVisible()

    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByLabel('Confirm password').fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page).toHaveURL('/app', { timeout: 10_000 })
    await expect(page.getByLabel('User menu')).toBeVisible()
  })

  test('sign out → redirects to sign-in', async ({ page }) => {
    await page.goto('/app/sign-in')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Sign in' }).click()
    await expect(page).toHaveURL('/app', { timeout: 10_000 })

    await page.getByLabel('User menu').click()
    await page.getByRole('button', { name: 'Sign out' }).click()

    await expect(page).toHaveURL(/\/sign-in/)
  })

  test('sign in with existing credentials → dashboard', async ({ page }) => {
    await page.goto('/app/sign-in')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Sign in' }).click()

    await expect(page).toHaveURL('/app', { timeout: 10_000 })
  })

  test('wrong password shows error', async ({ page }) => {
    await page.goto('/app/sign-in')
    await page.getByLabel('Email').fill(TEST_EMAIL)
    await page.getByLabel('Password', { exact: true }).fill('WrongPassword!')
    await page.getByRole('button', { name: 'Sign in' }).click()

    await expect(page.getByRole('alert')).toBeVisible()
    await expect(page).toHaveURL(/\/sign-in/)
  })

  test('second user registration works', async ({ page }) => {
    await page.goto('/app/sign-up')
    await page.getByLabel('Email').fill(TEST_EMAIL_2)
    await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
    await page.getByLabel('Confirm password').fill(TEST_PASSWORD)
    await page.getByRole('button', { name: 'Create account' }).click()

    await expect(page).toHaveURL('/app', { timeout: 10_000 })
  })
})
