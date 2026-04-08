import { useState } from 'react'
import { useAuth } from '@clerk/clerk-react'
import { api } from '../api/client'

type Vault = { id: number; name: string; note_count: number }

type Step = 'enter-code' | 'pick-vault' | 'success' | 'error'

export default function DeviceLinkPage() {
  const { isSignedIn } = useAuth()
  const [step, setStep] = useState<Step>('enter-code')
  const [userCode, setUserCode] = useState('')
  const [vaults, setVaults] = useState<Vault[]>([])
  const [selectedVaultId, setSelectedVaultId] = useState<number | null>(null)
  const [newVaultName, setNewVaultName] = useState('')
  const [createNew, setCreateNew] = useState(false)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  if (!isSignedIn) {
    return <p>Please sign in to link your Obsidian vault.</p>
  }

  async function handleVerifyCode() {
    const formatted = userCode.toUpperCase().replace(/[^A-Z2-9]/g, '')
    if (formatted.length !== 8) {
      setError('Code must be 8 characters (e.g., ENGR-7X4K)')
      return
    }

    setLoading(true)
    setError('')
    try {
      const data = await api.get<{ vaults: Vault[] }>('/vaults')
      setVaults(data.vaults)
      setUserCode(formatted.slice(0, 4) + '-' + formatted.slice(4))
      setStep('pick-vault')
    } catch {
      setError('Failed to load vaults. Please try again.')
    } finally {
      setLoading(false)
    }
  }

  async function handleAuthorize() {
    setLoading(true)
    setError('')
    try {
      const body = createNew
        ? { user_code: userCode, vault_id: 'new', vault_name: newVaultName }
        : { user_code: userCode, vault_id: selectedVaultId }

      await api.post('/auth/device/authorize', body)
      setStep('success')
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Authorization failed'
      if (message.includes('404') || message.includes('not found')) {
        setError('This code is invalid or has expired. Please try again from Obsidian.')
      } else {
        setError(message)
      }
    } finally {
      setLoading(false)
    }
  }

  const canAuthorize = createNew ? newVaultName.trim().length > 0 : selectedVaultId !== null

  return (
    <main style={{ maxWidth: 480, margin: '0 auto', padding: '2rem' }}>
      <h1>Link Obsidian Vault</h1>

      {step === 'enter-code' && (
        <section>
          <p>Enter the code shown in your Obsidian plugin:</p>
          <input
            type="text"
            value={userCode}
            onChange={(e) => setUserCode(e.target.value.toUpperCase())}
            placeholder="XXXX-XXXX"
            maxLength={9}
            style={{ fontFamily: 'monospace', fontSize: '1.5rem', textAlign: 'center', width: '100%', padding: '0.5rem' }}
            onKeyDown={(e) => e.key === 'Enter' && handleVerifyCode()}
          />
          <button onClick={handleVerifyCode} disabled={loading} style={{ marginTop: '1rem', width: '100%' }}>
            {loading ? 'Verifying...' : 'Verify'}
          </button>
        </section>
      )}

      {step === 'pick-vault' && (
        <section>
          <p>Code verified. Choose which vault to sync:</p>
          <fieldset style={{ border: 'none', padding: 0 }}>
            {vaults.map((v) => (
              <label key={v.id} style={{ display: 'block', padding: '0.5rem 0', cursor: 'pointer' }}>
                <input
                  type="radio"
                  name="vault"
                  checked={!createNew && selectedVaultId === v.id}
                  onChange={() => { setSelectedVaultId(v.id); setCreateNew(false) }}
                />
                {' '}{v.name} ({v.note_count} notes)
              </label>
            ))}
            <label style={{ display: 'block', padding: '0.5rem 0', cursor: 'pointer' }}>
              <input
                type="radio"
                name="vault"
                checked={createNew}
                onChange={() => { setCreateNew(true); setSelectedVaultId(null) }}
              />
              {' '}+ Create new vault
            </label>
          </fieldset>

          {createNew && (
            <input
              type="text"
              value={newVaultName}
              onChange={(e) => setNewVaultName(e.target.value)}
              placeholder="Vault name"
              style={{ width: '100%', padding: '0.5rem', marginTop: '0.5rem' }}
            />
          )}

          <button onClick={handleAuthorize} disabled={loading || !canAuthorize} style={{ marginTop: '1rem', width: '100%' }}>
            {loading ? 'Authorizing...' : 'Authorize'}
          </button>
        </section>
      )}

      {step === 'success' && (
        <section>
          <h2>Vault linked!</h2>
          <p>Your Obsidian plugin is now connected. You can close this tab.</p>
        </section>
      )}

      {error && <p style={{ color: 'red', marginTop: '1rem' }}>{error}</p>}
    </main>
  )
}
