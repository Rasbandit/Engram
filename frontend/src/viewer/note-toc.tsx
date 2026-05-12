import GithubSlugger from 'github-slugger'
import { useMemo } from 'react'

interface Heading {
  depth: number
  text: string
  id: string
}

function extractHeadings(markdown: string): Heading[] {
  const slugger = new GithubSlugger()
  const headings: Heading[] = []
  // Strip fenced code blocks so `# foo` inside them isn't picked up.
  const stripped = markdown.replace(/```[\s\S]*?```/g, '')
  const re = /^(#{1,6})\s+(.+?)\s*#*\s*$/gm
  let match: RegExpExecArray | null
  while ((match = re.exec(stripped)) !== null) {
    const hashes = match[1] ?? ''
    const text = (match[2] ?? '').trim()
    const depth = hashes.length
    if (depth <= 4 && text) headings.push({ depth, text, id: slugger.slug(text) })
  }
  return headings
}

export default function NoteToc({ content }: { content: string }) {
  const headings = useMemo(() => extractHeadings(content), [content])
  if (headings.length < 2) return null

  return (
    <nav aria-label="Table of contents" className="text-xs">
      <p className="mb-2 font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">On this page</p>
      <ul className="space-y-1 border-l border-gray-200 dark:border-gray-800">
        {headings.map((h, i) => (
          <li
            key={`${h.id}-${i}`}
            style={{ paddingLeft: `${(h.depth - 1) * 0.75}rem` }}
            className="-ml-px border-l border-transparent pl-3 transition hover:border-indigo-400"
          >
            <a
              href={`#${h.id}`}
              className="block py-0.5 text-gray-600 hover:text-indigo-600 dark:text-gray-400 dark:hover:text-indigo-400"
            >
              {h.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  )
}
