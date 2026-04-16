export interface EngramConfig {
  authProvider: 'local' | 'clerk'
  clerkPublishableKey: string
}

function loadConfig(): EngramConfig {
  const injected = (window as unknown as { __ENGRAM_CONFIG__?: Partial<EngramConfig> })
    .__ENGRAM_CONFIG__

  if (injected?.authProvider) {
    return injected as EngramConfig
  }

  // Fallback: Vite dev server (not served by Phoenix)
  return {
    authProvider: (import.meta.env.VITE_AUTH_PROVIDER as 'local' | 'clerk') ?? 'local',
    clerkPublishableKey: import.meta.env.VITE_CLERK_PUBLISHABLE_KEY ?? '',
  }
}

export const config = loadConfig()
