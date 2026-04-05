import { useAuth } from '@clerk/clerk-react'
import { useEffect } from 'react'
import { setTokenGetter } from './client'

export default function AuthTokenProvider({ children }: { children: React.ReactNode }) {
  const { getToken } = useAuth()

  useEffect(() => {
    setTokenGetter(() => getToken())
  }, [getToken])

  return <>{children}</>
}
