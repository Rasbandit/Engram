import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { DangerZoneSection } from './danger-zone-section'

describe('DangerZoneSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('keeps delete disabled until the confirmation phrase matches', () => {
    render(<DangerZoneSection />)
    const btn = screen.getByRole('button', { name: /delete my account/i })
    expect(btn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*delete my account/i), { target: { value: 'delete my account' } })
    expect(btn).toBeEnabled()
  })

  it('calls user.delete when confirmed', async () => {
    render(<DangerZoneSection />)
    fireEvent.change(screen.getByLabelText(/type .*delete my account/i), { target: { value: 'delete my account' } })
    fireEvent.click(screen.getByRole('button', { name: /delete my account/i }))
    await waitFor(() => expect(user.delete).toHaveBeenCalled())
  })
})
