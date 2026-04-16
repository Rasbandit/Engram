import { useState, useRef, useEffect } from 'react'
import { useAuthAdapter } from './use-auth-adapter'

export default function LocalUserMenu() {
  const { user, logout } = useAuthAdapter()
  const [open, setOpen] = useState(false)
  const menuRef = useRef<HTMLElement>(null)

  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [])

  return (
    <nav className="relative" ref={menuRef} aria-label="User menu">
      <button
        onClick={() => setOpen((o) => !o)}
        className="flex h-8 w-8 items-center justify-center rounded-full bg-blue-600 text-sm font-medium text-white"
        aria-label="User menu"
        aria-expanded={open}
        aria-haspopup="menu"
      >
        {user?.email?.[0]?.toUpperCase() ?? '?'}
      </button>

      {open && (
        <menu className="absolute right-0 mt-2 w-48 rounded border border-gray-200 bg-white py-1 shadow-lg" role="menu">
          <li role="none">
            <p className="truncate px-4 py-2 text-sm text-gray-700">{user?.email}</p>
          </li>
          <hr className="border-gray-100" />
          <li role="none">
            <button
              role="menuitem"
              onClick={() => { logout(); setOpen(false) }}
              className="w-full px-4 py-2 text-left text-sm text-gray-700 hover:bg-gray-100"
            >
              Sign out
            </button>
          </li>
        </menu>
      )}
    </nav>
  )
}
