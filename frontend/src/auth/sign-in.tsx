import { SignIn } from '@clerk/clerk-react'

export default function SignInPage() {
  return (
    <main style={{ display: 'flex', justifyContent: 'center', paddingTop: '4rem' }}>
      <SignIn routing="hash" forceRedirectUrl="/app" />
    </main>
  )
}
