import { createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'

// Placeholder components for now — will be replaced in Tasks 6-8
function Dashboard() {
  return <h2>Dashboard — coming soon</h2>
}

function NotePage() {
  return <h2>Note viewer — coming soon</h2>
}

function SearchPage() {
  return <h2>Search — coming soon</h2>
}

export const router = createBrowserRouter([
  // Public routes
  { path: '/sign-in', element: <SignInPage /> },
  { path: '/sign-up', element: <SignUpPage /> },

  // Authenticated routes
  {
    element: <AuthGuard />,
    children: [
      { path: '/', element: <Dashboard /> },
      { path: '/note/*', element: <NotePage /> },
      { path: '/search', element: <SearchPage /> },
    ],
  },
], { basename: '/app' })
