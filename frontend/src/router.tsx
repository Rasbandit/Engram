import { createBrowserRouter } from 'react-router'
import AuthGuard from './auth/auth-guard'
import SignInPage from './auth/sign-in'
import SignUpPage from './auth/sign-up'
import AppLayout from './layout/app-layout'
import Dashboard from './viewer/dashboard'
import NotePage from './viewer/note-page'

// Placeholder — replaced in Task 8
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
