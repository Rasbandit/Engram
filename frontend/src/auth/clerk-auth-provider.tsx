import { ClerkProvider, useAuth, useClerk } from '@clerk/clerk-react'
import { useCallback, useMemo } from 'react'
import { AuthContext, type AuthAdapter } from './auth-context'
import { setTokenGetter } from '../api/client'

const clerkPubKey = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY

function ClerkAdapterInner({ children }: { children: React.ReactNode }) {
  const { isLoaded, isSignedIn, getToken } = useAuth()
  const clerk = useClerk()

  const tokenGetter = useCallback(() => getToken(), [getToken])

  // Set token getter for API client (same as current AuthTokenProvider)
  setTokenGetter(tokenGetter)

  const adapter: AuthAdapter = useMemo(
    () => ({
      isLoaded,
      isSignedIn: isSignedIn ?? false,
      user: isSignedIn ? { email: clerk.user?.primaryEmailAddress?.emailAddress ?? '' } : null,
      getToken: tokenGetter,
      logout: async () => { await clerk.signOut() },
      hasBuiltInUI: true,
    }),
    [isLoaded, isSignedIn, clerk, tokenGetter],
  )

  return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>
}

export default function ClerkAuthProvider({ children }: { children: React.ReactNode }) {
  if (!clerkPubKey) {
    throw new Error('VITE_CLERK_PUBLISHABLE_KEY is required when AUTH_PROVIDER=clerk')
  }

  return (
    <ClerkProvider
      publishableKey={clerkPubKey}
      signInUrl="/app/sign-in"
      signUpUrl="/app/sign-up"
      afterSignOutUrl="/app/sign-in"
    >
      <ClerkAdapterInner>{children}</ClerkAdapterInner>
    </ClerkProvider>
  )
}
