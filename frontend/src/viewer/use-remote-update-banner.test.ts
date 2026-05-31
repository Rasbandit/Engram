import { describe, expect, it } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useRemoteUpdateBanner } from './use-remote-update-banner'

describe('useRemoteUpdateBanner', () => {
  it('does not show on initial mount — baseline equals remote, no draft change', () => {
    const { result } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })
    expect(result.current.show).toBe(false)
  })

  it('does not show when user types but remote is unchanged', () => {
    const { result, rerender } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })

    rerender({ remote: 'hello', draft: 'hello world' })
    expect(result.current.show).toBe(false)
  })

  it('does not show when remote changes but user has no local edits', () => {
    const { result, rerender } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })

    // Remote changed; draft still equals old baseline → silent baseline update
    rerender({ remote: 'hello updated', draft: 'hello' })
    expect(result.current.show).toBe(false)
  })

  it('shows when remote changes AND user has local edits (collision)', () => {
    const { result, rerender } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })

    rerender({ remote: 'hello', draft: 'hello local' })
    rerender({ remote: 'hello remote', draft: 'hello local' })
    expect(result.current.show).toBe(true)
    expect(result.current.remoteContent).toBe('hello remote')
  })

  it('acknowledge() dismisses the banner without changing draft', () => {
    const { result, rerender } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })

    rerender({ remote: 'hello', draft: 'hello local' })
    rerender({ remote: 'hello remote', draft: 'hello local' })
    expect(result.current.show).toBe(true)

    act(() => result.current.acknowledge())
    expect(result.current.show).toBe(false)

    // Same remote stays acknowledged
    rerender({ remote: 'hello remote', draft: 'hello local' })
    expect(result.current.show).toBe(false)
  })

  it('re-shows when remote changes again after acknowledgement', () => {
    const { result, rerender } = renderHook(({ remote, draft }) =>
      useRemoteUpdateBanner(remote, draft),
    { initialProps: { remote: 'hello', draft: 'hello' } })

    rerender({ remote: 'hello', draft: 'hello local' })
    rerender({ remote: 'hello remote', draft: 'hello local' })
    act(() => result.current.acknowledge())
    rerender({ remote: 'hello remote 2', draft: 'hello local' })
    expect(result.current.show).toBe(true)
  })
})
