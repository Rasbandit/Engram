import { lazy, Suspense } from 'react'

const UserProfile = lazy(() =>
  import('@clerk/clerk-react').then((mod) => ({ default: mod.UserProfile })),
)

export default function AccountPage() {
  return (
    <section>
      <h1 className="mb-4 text-xl font-semibold text-foreground">Account</h1>
      <Suspense fallback={<p className="text-muted-foreground">Loading account…</p>}>
        <UserProfile routing="path" path="/settings/account" />
      </Suspense>
    </section>
  )
}
