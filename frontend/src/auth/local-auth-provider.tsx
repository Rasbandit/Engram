import { useState, useCallback, useEffect, useMemo, useRef } from 'react'
import { AuthContext, type AuthAdapter } from './auth-context'
import { setTokenGetter } from '../api/client'

function parseJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const base64 = token.split('.')[1]
    if (!base64) return null
    const json = atob(base64.replace(/-/g, '+').replace(/_/g, '/'))
    return JSON.parse(json)
  } catch {
    return null
  }
}

export default function LocalAuthProvider({ children }: { children: React.ReactNode }) {
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [user, setUser] = useState<{ email: string } | null>(null)
  const [isLoaded, setIsLoaded] = useState(false)
  const refreshPromiseRef = useRef<Promise<string | null> | null>(null)

  // On mount, attempt a silent refresh to restore session from cookie
  useEffect(() => {
    console.log('[AUTH] mount: silent refresh starting')
    fetch('/api/auth/refresh', { method: 'POST', credentials: 'include' })
      .then(async (res) => {
        console.log('[AUTH] mount: refresh response status', res.status)
        if (res.ok) {
          const data = await res.json()
          const payload = parseJwtPayload(data.access_token)
          if (payload?.email) {
            console.log('[AUTH] mount: refresh succeeded, setting token for', payload.email)
            setAccessToken(data.access_token)
            setUser({ email: payload.email as string })
          }
        }
      })
      .catch((err) => console.error('[AUTH] mount: silent refresh failed:', err))
      .finally(() => {
        console.log('[AUTH] mount: setting isLoaded=true')
        setIsLoaded(true)
      })
  }, [])

  const doRefresh = useCallback(async (): Promise<string | null> => {
    const res = await fetch('/api/auth/refresh', { method: 'POST', credentials: 'include' })
    if (res.ok) {
      const data = await res.json()
      setAccessToken(data.access_token)
      return data.access_token
    }
    setAccessToken(null)
    setUser(null)
    return null
  }, [])

  const getToken = useCallback(async () => {
    if (!accessToken) return null

    // Check if token is expired (with 60s buffer)
    const payload = parseJwtPayload(accessToken)
    if (payload && (payload.exp as number) * 1000 >= Date.now() + 60_000) {
      return accessToken
    }

    // Deduplicate concurrent refresh requests
    if (!refreshPromiseRef.current) {
      refreshPromiseRef.current = doRefresh().finally(() => {
        refreshPromiseRef.current = null
      })
    }
    return refreshPromiseRef.current
  }, [accessToken, doRefresh])

  useEffect(() => {
    setTokenGetter(getToken)
  }, [getToken])

  const login = useCallback(async (email: string, password: string) => {
    console.log('[AUTH] login: calling /api/auth/login for', email)
    const res = await fetch('/api/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ email, password }),
    })

    console.log('[AUTH] login: response status', res.status)
    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      console.log('[AUTH] login: FAILED', body)
      throw new Error(body.error ?? 'Login failed')
    }

    const data = await res.json()
    console.log('[AUTH] login: SUCCESS, has access_token:', !!data.access_token, 'has user:', !!data.user)
    setAccessToken(data.access_token)
    setUser({ email: data.user.email })
    console.log('[AUTH] login: setState calls complete')
  }, [])

  const register = useCallback(async (email: string, password: string) => {
    console.log('[AUTH] register: calling /api/auth/register for', email)
    const res = await fetch('/api/auth/register', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'include',
      body: JSON.stringify({ email, password }),
    })

    console.log('[AUTH] register: response status', res.status)
    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      console.log('[AUTH] register: FAILED', body)
      throw new Error(body.error ?? 'Registration failed')
    }

    const data = await res.json()
    console.log('[AUTH] register: SUCCESS, has access_token:', !!data.access_token, 'has user:', !!data.user)
    setAccessToken(data.access_token)
    setUser({ email: data.user.email })
    console.log('[AUTH] register: setState calls complete')
  }, [])

  const logout = useCallback(async () => {
    await fetch('/api/auth/logout', { method: 'POST', credentials: 'include' }).catch((err) => console.error('Logout request failed:', err))
    setAccessToken(null)
    setUser(null)
  }, [])

  const adapter: AuthAdapter = useMemo(
    () => {
      const isSignedIn = !!accessToken
      console.log('[AUTH] adapter memo: isLoaded=%s isSignedIn=%s user=%s', isLoaded, isSignedIn, user?.email ?? 'null')
      return {
        isLoaded,
        isSignedIn,
        user,
        getToken,
        login,
        register,
        logout,
        hasBuiltInUI: false,
      }
    },
    [isLoaded, accessToken, user, getToken, login, register, logout],
  )

  return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>
}
