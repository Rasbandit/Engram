import { useQuery } from '@tanstack/react-query'
import { api } from './client'

// Types matching backend JSON responses
export interface Folder {
  name: string
  count: number
}

export interface NoteSummary {
  path: string
  title: string
  folder: string
  tags: string[]
  version: number
  mtime: string
  updated_at: string
}

export interface Note extends NoteSummary {
  content: string
}

export interface SearchResult {
  path: string
  title: string
  snippet: string
  score: number
}

export interface User {
  id: number
  email: string
}

// Query hooks

export function useFolders() {
  return useQuery({
    queryKey: ['folders'],
    queryFn: () => api.get<{ folders: Folder[] }>('/folders'),
    select: (data) => data.folders,
  })
}

export function useFolderNotes(folder: string) {
  return useQuery({
    queryKey: ['folderNotes', folder],
    queryFn: () =>
      api.get<{ notes: NoteSummary[] }>(`/folders/list?folder=${encodeURIComponent(folder)}`),
    select: (data) => data.notes,
    enabled: !!folder,
  })
}

export function useNote(path: string) {
  return useQuery({
    queryKey: ['note', path],
    queryFn: () => api.get<Note>(`/notes/${encodeURIComponent(path)}`),
    enabled: !!path,
  })
}

export function useSearch(query: string) {
  return useQuery({
    queryKey: ['search', query],
    queryFn: () => api.post<{ results: SearchResult[] }>('/search', { query, limit: 20 }),
    select: (data) => data.results,
    enabled: query.length > 0,
  })
}

export function useTags() {
  return useQuery({
    queryKey: ['tags'],
    queryFn: () => api.get<{ tags: string[] }>('/tags'),
    select: (data) => data.tags,
  })
}

export function useMe() {
  return useQuery({
    queryKey: ['me'],
    queryFn: () => api.get<{ user: User }>('/me'),
    select: (data) => data.user,
  })
}

// Billing types
export interface BillingStatus {
  tier: 'trial' | 'starter' | 'pro'
  active: boolean
  trial_days_remaining: number
  subscription: {
    status: string
    tier: string
    current_period_end: string
  } | null
}

// Billing hooks

export function useBillingStatus() {
  return useQuery({
    queryKey: ['billing', 'status'],
    queryFn: () => api.get<BillingStatus>('/billing/status'),
  })
}
