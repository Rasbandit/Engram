import { lazy, Suspense } from 'react'

const UserProfile = lazy(() =>
  import('@clerk/clerk-react').then((mod) => ({ default: mod.UserProfile })),
)

// The global ClerkProvider already maps our design tokens + reactive dark
// theme. Here we only override layout for the embedded (in-panel) context:
// fill the settings column so the card can't overflow and skew centering, and
// drop Clerk's own card shadow since it sits inside our settings panel.
const appearance = {
  elements: {
    rootBox: { width: '100%' },
    cardBox: { width: '100%', boxShadow: 'none' },
  },
}

export default function AccountPage() {
  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-xl font-semibold text-foreground">Account</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Manage your profile, security, and active sessions.
        </p>
      </header>
      <Suspense fallback={<p className="text-muted-foreground">Loading account…</p>}>
        <UserProfile routing="path" path="/settings/account" appearance={appearance} />
      </Suspense>
    </article>
  )
}
