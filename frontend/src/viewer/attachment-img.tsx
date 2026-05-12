import { useEffect, useState } from 'react'
import { api } from '../api/client'

export default function AttachmentImg({ path, alt }: { path: string; alt?: string }) {
  const [src, setSrc] = useState<string | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    let revoke: string | null = null
    let cancelled = false
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}`)
      .then((blob) => {
        if (cancelled) return
        const url = URL.createObjectURL(blob)
        revoke = url
        setSrc(url)
      })
      .catch(() => !cancelled && setError(true))
    return () => {
      cancelled = true
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [path])

  if (error) {
    return (
      <span className="inline-flex items-center gap-1 rounded bg-red-50 px-1.5 py-0.5 text-xs text-red-700 dark:bg-red-950/40 dark:text-red-300">
        Missing attachment: {path}
      </span>
    )
  }
  if (!src) {
    return <span className="text-xs text-gray-400">Loading {path}…</span>
  }
  return <img src={src} alt={alt ?? path} className="my-2 max-w-full rounded" />
}
