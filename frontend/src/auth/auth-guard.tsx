import { Navigate, Outlet } from 'react-router'
import { useAuthAdapter } from './use-auth-adapter'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuthAdapter()

  if (!isLoaded) {
    return <p>Loading...</p>
  }

  if (!isSignedIn) {
    return <Navigate to="/sign-in" replace />
  }

  return <Outlet />
}
