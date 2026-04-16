import { useState, useEffect, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router'
import { useAuthAdapter } from './use-auth-adapter'

export default function LocalSignIn() {
  const { login, isSignedIn } = useAuthAdapter()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  // Navigate after auth state propagates (React 18 batching)
  useEffect(() => {
    console.log('[SIGN-IN] useEffect: isSignedIn=%s', isSignedIn)
    if (isSignedIn) {
      console.log('[SIGN-IN] useEffect: navigating to /')
      navigate('/', { replace: true })
    }
  }, [isSignedIn, navigate])

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setError('')
    setLoading(true)
    console.log('[SIGN-IN] handleSubmit: starting login for', email)

    try {
      if (!login) throw new Error('Login not available for this auth provider')
      await login(email, password)
      console.log('[SIGN-IN] handleSubmit: login() resolved successfully')
    } catch (err) {
      console.log('[SIGN-IN] handleSubmit: login() threw:', err)
      setError(err instanceof Error ? err.message : 'Login failed')
    } finally {
      setLoading(false)
    }
  }

  return (
    <main className="flex justify-center pt-16">
      <form onSubmit={handleSubmit} className="w-full max-w-sm space-y-4">
        <h1 className="text-2xl font-semibold text-gray-900">Sign in to Engram</h1>

        {error && (
          <p role="alert" className="text-sm text-red-600">{error}</p>
        )}

        <label className="block">
          <span className="text-sm font-medium text-gray-700">Email</span>
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="mt-1 block w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
        </label>

        <label className="block">
          <span className="text-sm font-medium text-gray-700">Password</span>
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 block w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
        </label>

        <button
          type="submit"
          disabled={loading}
          className="w-full rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {loading ? 'Signing in...' : 'Sign in'}
        </button>

        <p className="text-center text-sm text-gray-500">
          Don't have an account?{' '}
          <Link to="/sign-up" className="text-blue-600 hover:underline">Sign up</Link>
        </p>
      </form>
    </main>
  )
}
