import { useEffect, useState } from 'react'

export interface Bootstrap {
  bootstrap_pending: boolean
  registration_mode: 'open' | 'invite_only' | 'closed'
}

// Fetch self-host bootstrap state on mount. 404 (Clerk) → null, treated as
// "not self-host" by callers. Errors → null so the page just renders normally.
export function useBootstrap(): Bootstrap | null {
  const [state, setState] = useState<Bootstrap | null>(null)

  useEffect(() => {
    let cancelled = false
    fetch('/api/auth/bootstrap')
      .then((r) => (r.ok ? r.json() : null))
      .then((b: Bootstrap | null) => {
        if (!cancelled) setState(b)
      })
      .catch(() => {
        if (!cancelled) setState(null)
      })
    return () => {
      cancelled = true
    }
  }, [])

  return state
}
