import { useState, useDeferredValue } from 'react'
import { Link } from 'react-router'
import { useSearch } from '../api/queries'

export default function SearchPage() {
  const [input, setInput] = useState('')
  const deferredQuery = useDeferredValue(input)
  const { data: results, isLoading, error } = useSearch(deferredQuery)

  return (
    <section>
      <h1 className="mb-4 text-xl font-semibold">Search</h1>
      <input
        type="search"
        placeholder="Search your notes..."
        value={input}
        onChange={(e) => setInput(e.target.value)}
        className="mb-6 w-full rounded border px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
        autoFocus
      />

      {isLoading && <p className="text-gray-500">Searching...</p>}
      {error && <p className="text-red-600">Search failed: {error.message}</p>}

      {results && results.length === 0 && deferredQuery && (
        <p className="text-gray-500">No results for "{deferredQuery}"</p>
      )}

      {results && results.length > 0 && (
        <ul className="space-y-3">
          {results.map((r) => (
            <li key={r.path}>
              <Link
                to={`/note/${r.path}`}
                className="block rounded border p-3 hover:bg-gray-50"
              >
                <p className="font-medium">{r.title || r.path}</p>
                {r.snippet && (
                  <p className="mt-1 text-sm text-gray-600 line-clamp-2">{r.snippet}</p>
                )}
                <p className="mt-1 text-xs text-gray-400">
                  Score: {r.score.toFixed(3)}
                </p>
              </Link>
            </li>
          ))}
        </ul>
      )}

      {!deferredQuery && !isLoading && (
        <p className="text-gray-400">Type to search your notes</p>
      )}
    </section>
  )
}
