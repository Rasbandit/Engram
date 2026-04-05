import { SignUp } from '@clerk/clerk-react'

export default function SignUpPage() {
  return (
    <main style={{ display: 'flex', justifyContent: 'center', paddingTop: '4rem' }}>
      <SignUp routing="hash" />
    </main>
  )
}
