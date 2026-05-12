import { PanelLeftClose, PanelLeftOpen } from 'lucide-react'
import { lazy, Suspense, useRef, useState } from 'react'
import type { ImperativePanelHandle } from 'react-resizable-panels'
import { Link, NavLink, Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from '@/components/ui/resizable'
import { ScrollArea } from '@/components/ui/scroll-area'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))
import { useBillingStatus } from '../api/queries'
import { useChannel } from '../api/use-channel'
import ThemeToggle from '../theme/theme-toggle'
import FolderTree from '../viewer/folder-tree'
import VaultSwitcher from './vault-switcher'

function HeaderLink({ to, label }: { to: string; label: string }) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        `text-sm transition hover:text-foreground ${
          isActive ? 'font-medium text-foreground' : 'text-muted-foreground'
        }`
      }
    >
      {label}
    </NavLink>
  )
}

export default function AppLayout() {
  const sidebarRef = useRef<ImperativePanelHandle>(null)
  const [collapsed, setCollapsed] = useState(false)
  useChannel()
  const { data: billing } = useBillingStatus()

  const toggleSidebar = () => {
    const panel = sidebarRef.current
    if (!panel) return
    if (panel.isCollapsed()) panel.expand()
    else panel.collapse()
  }

  return (
    <>
      {billing?.subscription?.status === 'trialing' && billing.trial_days_remaining > 0 && billing.trial_days_remaining <= 3 && (
        <aside className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-900 dark:bg-amber-950/40 dark:text-amber-100" role="alert">
          {billing.trial_days_remaining} days left in your trial.
        </aside>
      )}
      <section className="flex h-screen flex-col bg-background text-foreground">
        <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
          <div className="flex items-center gap-3">
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={toggleSidebar}
              aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
              aria-expanded={!collapsed}
              aria-controls="sidebar"
            >
              {collapsed ? <PanelLeftOpen /> : <PanelLeftClose />}
            </Button>
            <Link to="/" className="text-lg font-semibold text-foreground hover:text-foreground/80">
              Engram
            </Link>
          </div>
          <nav className="flex items-center gap-4" aria-label="Main navigation">
            <HeaderLink to="/search" label="Search" />
            <HeaderLink to="/billing" label="Billing" />
            <HeaderLink to="/settings" label="Settings" />
            <ThemeToggle />
            <Suspense fallback={null}>
              {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
            </Suspense>
          </nav>
        </header>

        <ResizablePanelGroup
          direction="horizontal"
          autoSaveId="engram:app-layout"
          className="flex-1"
        >
          <ResizablePanel
            id="sidebar"
            order={1}
            ref={sidebarRef}
            defaultSize={18}
            minSize={12}
            maxSize={40}
            collapsible
            collapsedSize={0}
            onCollapse={() => setCollapsed(true)}
            onExpand={() => setCollapsed(false)}
            className="border-r border-border bg-card"
          >
            <ScrollArea className="h-full">
              <VaultSwitcher />
              <FolderTree />
            </ScrollArea>
          </ResizablePanel>
          <ResizableHandle withHandle />
          <ResizablePanel id="main" order={2} defaultSize={82} minSize={40}>
            <main className="h-full overflow-hidden bg-muted/40 p-6 text-foreground">
              <Outlet />
            </main>
          </ResizablePanel>
        </ResizablePanelGroup>
      </section>
    </>
  )
}
