import { useState, useCallback, useEffect, useMemo } from 'react'
import { AuthContext, type AuthAdapter } from './auth-context'
import { setTokenGetter } from '../api/client'

export default function LocalAuthProvider({ children }: { children: React.ReactNode }) {
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [user, setUser] = useState<{ email: string } | null>(null)
  const [isLoaded, setIsLoaded] = useState(false)

  // On mount, attempt a silent refresh to restore session from cookie
  useEffect(() => {
    fetch('/api/auth/refresh', { method: 'POST', credentials: 'include' })
      .then(async (res) => {
        if (res.ok) {
          const data = await res.json()
          setAccessToken(data.access_token)
          const payload = JSON.parse(atob(data.access_token.split('.')[1] ?? ''))
          setUser({ email: payload.email })
        }
      })
      .catch(() => {})
      .finally(() => setIsLoaded(true))
  }, [])

  const getToken = useCallback(async () => {
    if (!accessToken) return null

    // Check if token is expired (with 60s buffer)
    const payload = JSON.parse(atob(accessToken.split('.')[1] ?? ''))
    if (payload.exp * 1000 < Date.now() + 60_000) {
      const res = await fetch('/api/auth/refresh', { method: 'POST', credentials: 'include' })
      if (res.ok) {
        const data = await res.json()
        setAccessToken(data.access_token)
        return data.access_token
      }
      setAccessToken(null)
      setUser(null)
      return null
    }

    return accessToken
  }, [accessToken])

  useEffect(() => {
    setTokenGetter(getToken)
  }, [getToken])

  const login = useCallback(async (email: string, password: string) => {
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ email, password }),
    })

    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      throw new Error(body.error ?? 'Login failed')
    }

    const data = await res.json()
    setAccessToken(data.access_token)
    setUser({ email: data.user.email })
  }, [])

  const register = useCallback(async (email: string, password: string) => {
    const res = await fetch('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ email, password }),
    })

    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      throw new Error(body.error ?? 'Registration failed')
    }

    const data = await res.json()
    setAccessToken(data.access_token)
    setUser({ email: data.user.email })
  }, [])

  const logout = useCallback(async () => {
    await fetch('/api/auth/logout', { method: 'POST', credentials: 'include' }).catch(() => {})
    setAccessToken(null)
    setUser(null)
  }, [])

  const adapter: AuthAdapter = useMemo(
    () => ({
      isLoaded,
      isSignedIn: !!accessToken,
      user,
      getToken,
      login,
      register,
      logout,
      hasBuiltInUI: false,
    }),
    [isLoaded, accessToken, user, getToken, login, register, logout],
  )

  return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>
}
