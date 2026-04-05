import { useAuth } from '@clerk/clerk-react'
import { Navigate, Outlet } from 'react-router'

export default function AuthGuard() {
  const { isLoaded, isSignedIn } = useAuth()

  if (!isLoaded) {
    return <p>Loading...</p>
  }

  if (!isSignedIn) {
    return <Navigate to="/sign-in" replace />
  }

  return <Outlet />
}
