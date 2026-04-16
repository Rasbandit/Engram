import { lazy, Suspense } from 'react'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'

const ClerkSignInPage = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({
        default: () => (
          <main style={{ display: 'flex', justifyContent: 'center', paddingTop: '4rem' }}>
            <mod.SignIn routing="hash" forceRedirectUrl="/app" />
          </main>
        ),
      }))
    )
  : null

const LocalSignIn = lazy(() => import('./local-sign-in'))

export default function SignInPage() {
  return (
    <Suspense fallback={<p>Loading...</p>}>
      {ClerkSignInPage ? <ClerkSignInPage /> : <LocalSignIn />}
    </Suspense>
  )
}
