import { defineConfig, devices } from '@playwright/test'

const isCI = !!process.env.CI

// Ports — configurable via env for parallel CI, defaults for local dev
const LOCAL_BACKEND_PORT = +(process.env.PW_LOCAL_BACKEND_PORT ?? 4000)
const LOCAL_VITE_PORT = +(process.env.PW_LOCAL_VITE_PORT ?? 5173)
const CLERK_BACKEND_PORT = +(process.env.PW_CLERK_BACKEND_PORT ?? 4001)
const CLERK_VITE_PORT = +(process.env.PW_CLERK_VITE_PORT ?? 5174)

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  forbidOnly: isCI,
  retries: isCI ? 1 : 0,
  reporter: isCI ? 'github' : 'html',
  globalSetup: './e2e/global-setup.ts',
  globalTeardown: './e2e/global-teardown.ts',
  use: {
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    ...devices['Desktop Chrome'],
  },

  projects: [
    {
      name: 'local',
      testMatch: 'local-auth.spec.ts',
      use: {
        baseURL: `http://localhost:${LOCAL_VITE_PORT}`,
      },
    },
    {
      name: 'clerk',
      testMatch: 'clerk-auth.spec.ts',
      use: {
        baseURL: `http://localhost:${CLERK_VITE_PORT}`,
      },
    },
  ],

  webServer: [
    {
      command: 'mix phx.server',
      cwd: '..',
      port: LOCAL_BACKEND_PORT,
      timeout: 30_000,
      reuseExistingServer: !isCI,
      env: {
        MIX_ENV: 'dev',
        AUTH_PROVIDER: 'local',
        PHX_SERVER: 'true',
        PORT: String(LOCAL_BACKEND_PORT),
      },
    },
    {
      command: `bun run dev -- --port ${LOCAL_VITE_PORT}`,
      cwd: '.',
      port: LOCAL_VITE_PORT,
      timeout: 15_000,
      reuseExistingServer: !isCI,
      env: {
        VITE_AUTH_PROVIDER: 'local',
        VITE_API_TARGET: `http://localhost:${LOCAL_BACKEND_PORT}`,
      },
    },
    {
      command: 'mix phx.server',
      cwd: '..',
      port: CLERK_BACKEND_PORT,
      timeout: 30_000,
      reuseExistingServer: !isCI,
      env: {
        MIX_ENV: 'dev',
        AUTH_PROVIDER: 'clerk',
        PHX_SERVER: 'true',
        PORT: String(CLERK_BACKEND_PORT),
        CLERK_JWKS_URL: process.env.CLERK_JWKS_URL ?? '',
        CLERK_ISSUER: process.env.CLERK_ISSUER ?? '',
      },
    },
    {
      command: `bun run dev -- --port ${CLERK_VITE_PORT}`,
      cwd: '.',
      port: CLERK_VITE_PORT,
      timeout: 15_000,
      reuseExistingServer: !isCI,
      env: {
        VITE_AUTH_PROVIDER: 'clerk',
        VITE_CLERK_PUBLISHABLE_KEY: process.env.VITE_CLERK_PUBLISHABLE_KEY ?? '',
        VITE_API_TARGET: `http://localhost:${CLERK_BACKEND_PORT}`,
      },
    },
  ],
})
