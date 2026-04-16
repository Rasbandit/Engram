import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router'
import { QueryClientProvider } from '@tanstack/react-query'
import { router } from './router'
import { queryClient } from './api/query-client'
import { config } from './config'
import './main.css'

const isClerk = config.authProvider === 'clerk'

const AuthProvider = isClerk
  ? lazy(() => import('./auth/clerk-auth-provider'))
  : lazy(() => import('./auth/local-auth-provider'))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Suspense fallback={<p>Loading...</p>}>
      <AuthProvider>
        <QueryClientProvider client={queryClient}>
          <RouterProvider router={router} />
        </QueryClientProvider>
      </AuthProvider>
    </Suspense>
  </StrictMode>,
)
