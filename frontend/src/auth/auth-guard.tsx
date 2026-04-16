import { Navigate, Outlet } from 'react-router'
import { useAuthAdapter } from './use-auth-adapter'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuthAdapter()
  console.log('[AUTH-GUARD] render: isLoaded=%s isSignedIn=%s', isLoaded, isSignedIn)

  if (!isLoaded) {
    return <p>Loading...</p>
  }

  if (!isSignedIn) {
    console.log('[AUTH-GUARD] redirecting to /sign-in')
    return <Navigate to="/sign-in" replace />
  }

  return <Outlet />
}
