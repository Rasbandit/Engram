import { useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { useNote, useUpdateNote } from '../api/queries'
import NoteEditor from './note-editor'
import NoteToc from './note-toc'
import NoteView from './note-view'

type Mode = 'preview' | 'edit'

export default function NotePage() {
  // React Router v7 uses "*" for catch-all params
  const params = useParams()
  const path = params['*'] ?? ''

  const { data: note, isLoading, error } = useNote(path)
  const update = useUpdateNote()

  const [mode, setMode] = useState<Mode>('preview')
  const [draft, setDraft] = useState('')
  const [saveError, setSaveError] = useState<string | null>(null)

  useEffect(() => {
    if (note) setDraft(note.content)
  }, [note?.path, note?.content])

  if (!path) {
    return <p className="p-6 text-gray-500">No note selected</p>
  }
  if (isLoading) {
    return <p className="p-6 text-gray-500">Loading note…</p>
  }
  if (error) {
    return <p className="p-6 text-red-600 dark:text-red-400">Failed to load note: {error.message}</p>
  }
  if (!note) {
    return <p className="p-6 text-gray-500">Note not found</p>
  }

  const dirty = draft !== note.content
  const saving = update.isPending

  const handleSave = async () => {
    setSaveError(null)
    try {
      await update.mutateAsync({ path: note.path, content: draft, version: note.version })
      setMode('preview')
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : String(err))
    }
  }

  return (
    <div className="mx-auto grid w-full max-w-7xl gap-6 px-4 py-4 lg:grid-cols-[1fr_14rem]">
      <div className="min-w-0">
        <div className="mb-4 flex items-center justify-between gap-3 border-b border-gray-200 dark:border-gray-800">
          <div role="tablist" className="flex">
            {(['preview', 'edit'] as const).map((m) => (
              <button
                key={m}
                role="tab"
                aria-selected={mode === m}
                onClick={() => setMode(m)}
                className={`px-3 py-2 text-sm font-medium capitalize transition ${
                  mode === m
                    ? 'border-b-2 border-indigo-500 text-indigo-600 dark:text-indigo-400'
                    : 'text-gray-500 hover:text-gray-800 dark:text-gray-400 dark:hover:text-gray-200'
                }`}
              >
                {m}
              </button>
            ))}
          </div>
          {mode === 'edit' && (
            <div className="flex items-center gap-2 pb-1 text-xs">
              {saveError && <span className="text-red-600 dark:text-red-400">{saveError}</span>}
              <button
                onClick={() => setDraft(note.content)}
                disabled={!dirty || saving}
                className="rounded px-2 py-1 text-gray-500 hover:bg-gray-100 disabled:opacity-50 dark:text-gray-400 dark:hover:bg-gray-800"
              >
                Revert
              </button>
              <button
                onClick={handleSave}
                disabled={!dirty || saving}
                className="rounded bg-indigo-600 px-3 py-1 font-medium text-white shadow-sm transition hover:bg-indigo-700 disabled:opacity-50"
              >
                {saving ? 'Saving…' : 'Save'}
              </button>
            </div>
          )}
        </div>

        {mode === 'preview' ? (
          <NoteView
            content={note.content}
            title={note.title}
            tags={note.tags}
            updatedAt={note.updated_at}
          />
        ) : (
          <NoteEditor value={draft} onChange={setDraft} />
        )}
      </div>

      {mode === 'preview' && (
        <aside className="hidden lg:block">
          <div className="sticky top-4">
            <NoteToc content={note.content} />
          </div>
        </aside>
      )}
    </div>
  )
}
