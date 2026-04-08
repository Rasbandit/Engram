import { useAuth } from '@clerk/clerk-react'
import { setTokenGetter } from './client'

export default function AuthTokenProvider({ children }: { children: React.ReactNode }) {
  const { getToken } = useAuth()

  // Set synchronously during render (not in useEffect) so the getter
  // is available before children mount and fire API requests.
  setTokenGetter(() => getToken())

  return <>{children}</>
}
