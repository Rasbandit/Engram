import { createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import AppLayout from './layout/app-layout'
import Dashboard from './viewer/dashboard'

// Placeholders — replaced in Tasks 7-8
function NotePage() {
  return <h2 className="text-lg font-semibold text-gray-700">Note viewer — coming in Task 7</h2>
}

function SearchPage() {
  return <h2 className="text-lg font-semibold text-gray-700">Search — coming in Task 8</h2>
}

export const router = createBrowserRouter(
  [
    // Public routes
    { path: '/sign-in', element: <SignInPage /> },
    { path: '/sign-up', element: <SignUpPage /> },

    // Authenticated routes
    {
      element: <AuthGuard />,
      children: [
        {
          element: <AppLayout />,
          children: [
            { path: '/', element: <Dashboard /> },
            { path: '/note/*', element: <NotePage /> },
            { path: '/search', element: <SearchPage /> },
          ],
        },
      ],
    },
  ],
  { basename: '/app' },
)
