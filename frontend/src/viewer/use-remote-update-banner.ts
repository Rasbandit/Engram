import { useEffect, useState } from 'react'

interface BannerState {
  show: boolean
  remoteContent: string
  acknowledge: () => void
}

/**
 * Tracks whether a remote update has landed while the user has unsaved edits.
 *
 * The hook treats the first remote value it sees as the baseline. When remote
 * later changes:
 *   - If draft still equals baseline → silently advances baseline (no banner).
 *   - If draft has diverged from baseline → surfaces banner so user can decide
 *     whether to keep their edits or reload to the remote version.
 *
 * `acknowledge()` advances the baseline to the current remote without touching
 * the draft — the banner hides until the next remote change.
 */
export function useRemoteUpdateBanner(remote: string, draft: string): BannerState {
  const [baseline, setBaseline] = useState(remote)

  useEffect(() => {
    // Auto-advance baseline when there are no local edits to protect.
    if (remote !== baseline && draft === baseline) {
      setBaseline(remote)
    }
  }, [remote, draft, baseline])

  const show = remote !== baseline && draft !== baseline

  return {
    show,
    remoteContent: remote,
    acknowledge: () => setBaseline(remote),
  }
}
