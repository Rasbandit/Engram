# Dark Mode (System-Aware + Manual Override)

**Date:** 2026-05-11
**Scope:** `frontend/` SPA (React 19 + Tailwind v4 + Vite)
**Status:** Approved for plan

## Goal

Add dark theme to the Engram web UI. Default follows the OS preference (`prefers-color-scheme`). User can override to Light, Dark, or System via:

1. Icon button in the app header (cycles Light → Dark → System).
2. Three-button segmented control on the Settings page.

Override is persisted to `localStorage` under key `engram:theme`. When set to `system`, the UI tracks live changes to the OS preference.

## Non-Goals

- Multi-theme support beyond light/dark (no accent themes, no user-defined palettes).
- Per-vault or per-route themes.
- Server-side rendering / SEO (the SPA is shell-rendered by Phoenix; no SSR of theme state).
- Theming the highlight.js code-block colors beyond swapping to `github-dark` in dark mode.

## Approach

**Inline `dark:` Tailwind variants** for every color-bearing class. Tailwind v4 with a class-based variant: `@custom-variant dark (&:where(.dark, .dark *))`. Override comes from the presence of the `.dark` class on `<html>`.

Rejected alternatives:
- **Semantic CSS-var tokens** (e.g., `bg-surface`, `text-fg`). Cleaner long-term but adds an indirection layer that isn't justified at current UI size.
- **Hybrid (tokens for core + inline for accents).** Splits the mental model without solving a real problem yet.

If a third theme or user accent customization ever arrives, migrate then.

## Architecture

### State Resolution

```
stored theme: 'system' | 'light' | 'dark'   (localStorage 'engram:theme')
system pref:  'light' | 'dark'              (matchMedia '(prefers-color-scheme: dark)')

resolved =
  stored === 'system' ? system pref :
  stored
```

The `.dark` class is on `<html>` iff `resolved === 'dark'`.

### Boot Sequence (anti-FOUC)

1. `index.html` contains an inline `<script>` (executed before React mounts) that:
   - Reads `localStorage['engram:theme']`.
   - Computes effective theme using `window.matchMedia('(prefers-color-scheme: dark)')`.
   - Adds `.dark` to `document.documentElement` if effective theme is `dark`.
   - Wraps in try/catch so a localStorage exception (private mode quirks) silently falls back to system.

2. React mounts. `<ThemeProvider>` reads the same `localStorage` value into state and continues from there. The boot script and the provider agree on initial class state, so no flash.

### Files

**New:**

| File | Purpose |
|------|---------|
| `frontend/src/theme/theme-provider.tsx` | React context. State `{ theme, resolved }`. `setTheme(next)`. Subscribes to `matchMedia` only while `theme === 'system'`. |
| `frontend/src/theme/use-theme.ts` | `useTheme()` hook (named export from provider is fine if we want one file). |
| `frontend/src/theme/theme-toggle.tsx` | Header icon button. Cycles Light → Dark → System. Inline SVGs (sun, moon, monitor). `aria-label` reflects next state. |
| `frontend/src/theme/theme-segmented.tsx` | Settings-page segmented control. Three buttons with `aria-pressed`. |
| `frontend/src/theme/storage.ts` | Safe `getStoredTheme()` / `setStoredTheme()` with try/catch and validation. Shared by boot script and provider where practical. |

**Modified:**

| File | Change |
|------|--------|
| `frontend/src/main.css` | Add `@custom-variant dark (&:where(.dark, .dark *))`. Replace `@import "highlight.js/styles/github.css"` with both `github.css` and `github-dark.css`, scoping each via `@layer base` so only one set of variables applies per mode. |
| `frontend/index.html` | Inline `<script>` for FOUC-free theme application. Includes `<meta name="color-scheme" content="light dark">` so native UA chrome (scrollbars, form widgets) matches. |
| `frontend/src/main.tsx` | Wrap router in `<ThemeProvider>`. |
| `frontend/src/layout/app-layout.tsx` | Add `dark:` variants to header, sidebar, banners. Mount `<ThemeToggle>` next to nav links. |
| `frontend/src/settings/*` | Add a "Appearance" section with `<ThemeSegmented>`. |
| Remaining UI files with hardcoded color classes (viewer, folder-tree, vault-switcher, billing, oauth, device, login, not-found) | Add `dark:` variants pass. |

### Highlight.js

Both stylesheets ship. We scope them via attribute/class so only one is active:

```css
@import "highlight.js/styles/github.css" layer(base);
@import "highlight.js/styles/github-dark.css" layer(base);
```

Then in `main.css`:

```css
/* light wins by default; .dark scope flips to dark variant */
:where(html:not(.dark)) .hljs { /* re-apply light values if needed */ }
:where(html.dark) .hljs { /* dark values pre-applied by the dark stylesheet */ }
```

Implementation may simplify this by importing only the active sheet via a JS-side dynamic toggle, but the static dual-import keeps things synchronous and FOUC-free. The plan will pick the simpler path that works.

## Color Mapping

A small palette mapping that the plan will enumerate per component:

| Light | Dark |
|-------|------|
| `bg-white` | `dark:bg-gray-900` |
| `bg-gray-50` | `dark:bg-gray-950` |
| `bg-gray-100` | `dark:bg-gray-800` |
| `text-gray-900` | `dark:text-gray-100` |
| `text-gray-700` | `dark:text-gray-200` |
| `text-gray-600` | `dark:text-gray-300` |
| `text-gray-500` | `dark:text-gray-400` |
| `border-gray-200` | `dark:border-gray-800` |
| `bg-blue-50 text-blue-800` (info banner) | `dark:bg-blue-950 dark:text-blue-200` |
| `bg-amber-50 text-amber-800` (trial banner) | `dark:bg-amber-950 dark:text-amber-200` |
| Hover `hover:bg-gray-100` | `dark:hover:bg-gray-800` |

Exact tokens are a starting point; the plan will validate against rendered contrast before finalizing.

## Data Flow

```
boot.ts (inline in index.html)
  ├─ read localStorage['engram:theme']  (try/catch)
  ├─ resolve via matchMedia
  └─ toggle .dark on <html>

ThemeProvider
  ├─ initial state from localStorage
  ├─ subscribe to matchMedia (only when theme==='system')
  ├─ on change: re-resolve → update class on <html>
  └─ setTheme(next): write localStorage, update state, update class

ThemeToggle (header)
  └─ onClick: cycle Light → Dark → System → Light

ThemeSegmented (settings)
  └─ onClick: setTheme(value)
```

## Error Handling

- `localStorage.getItem` / `setItem` throws → caught, fallback to `'system'`, never propagated.
- Unknown stored value → coerced to `'system'`, stored value left as-is (or rewritten — plan picks one; rewriting is cleaner).
- `matchMedia` absent (very old browsers, jsdom in unit tests) → resolver returns `'light'`, no subscription attempted.

## Testing

**Unit (vitest):**
- `storage.ts`: round-trip, invalid value, localStorage throws.
- `theme-provider`: initial resolution from each stored state; `setTheme` updates class; matchMedia subscription added/removed when theme transitions in/out of `'system'`; unsubscribe on unmount.

**E2E (Playwright):**
- Settings → pick Dark → assert `html.dark` present and primary surface uses dark token.
- Settings → pick Light → assert class removed.
- Settings → pick System → emulate `prefers-color-scheme: dark` via Playwright → assert class present.
- Header toggle: cycle three times, assert `<html>` class and `localStorage` value match expected.
- FOUC: navigate with `engram:theme='dark'` pre-seeded → first paint already has `.dark` (assert via the screenshot or by checking class at `domcontentloaded` before React mounts).

**Manual:**
- Verify in actual browsers (Firefox, Chromium) that toggling OS theme while app is open with `system` selected flips colors live.
- Verify highlight.js code blocks render legibly in both modes.

## Open Questions

None. Plan can proceed.
