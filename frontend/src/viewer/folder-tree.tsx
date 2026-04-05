import { useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { useFolders, type Folder } from '../api/queries'

interface TreeNode {
  name: string      // display name (last segment)
  fullPath: string  // full folder path (joined with '/')
  count: number     // note count at this exact path (0 if only an ancestor)
  children: TreeNode[]
}

function buildTree(folders: Folder[]): TreeNode[] {
  const root: TreeNode[] = []

  for (const folder of folders) {
    const segments = folder.name.split('/')
    let level = root

    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i] ?? ''
      const fullPath = segments.slice(0, i + 1).join('/')
      const isLeaf = i === segments.length - 1

      let node: TreeNode | undefined = level.find((n) => n.name === seg)
      if (!node) {
        node = { name: seg, fullPath, count: 0, children: [] }
        level.push(node)
      }

      if (isLeaf) {
        node.count = folder.count
      }

      level = node.children
    }
  }

  return root
}

interface FolderNodeProps {
  node: TreeNode
  depth: number
  selectedFolder: string
}

function FolderNode({ node, depth, selectedFolder }: FolderNodeProps) {
  const [open, setOpen] = useState(depth === 0)
  const hasChildren = node.children.length > 0
  const isSelected = selectedFolder === node.fullPath

  return (
    <li>
      <div
        className={`flex items-center gap-1 rounded px-2 py-1 text-sm ${
          isSelected ? 'bg-blue-50 font-medium text-blue-700' : 'text-gray-700 hover:bg-gray-100'
        }`}
        style={{ paddingLeft: `${depth * 12 + 8}px` }}
      >
        {hasChildren ? (
          <button
            onClick={() => setOpen((o) => !o)}
            aria-label={open ? `Collapse ${node.name}` : `Expand ${node.name}`}
            aria-expanded={open}
            className="shrink-0 text-gray-400 hover:text-gray-600"
          >
            {open ? '▾' : '▸'}
          </button>
        ) : (
          <span className="w-3 shrink-0" aria-hidden="true" />
        )}

        <Link
          to={`/?folder=${encodeURIComponent(node.fullPath)}`}
          className="flex-1 truncate"
          aria-current={isSelected ? 'page' : undefined}
        >
          {node.name}
        </Link>

        {node.count > 0 && (
          <span className="shrink-0 text-xs text-gray-400" aria-label={`${node.count} notes`}>
            {node.count}
          </span>
        )}
      </div>

      {hasChildren && open && (
        <ul role="list">
          {node.children.map((child) => (
            <FolderNode
              key={child.fullPath}
              node={child}
              depth={depth + 1}
              selectedFolder={selectedFolder}
            />
          ))}
        </ul>
      )}
    </li>
  )
}

export default function FolderTree() {
  const { data: folders, isLoading, isError } = useFolders()
  const [searchParams] = useSearchParams()
  const selectedFolder = searchParams.get('folder') ?? ''

  if (isLoading) {
    return <p className="px-4 py-3 text-sm text-gray-500">Loading…</p>
  }

  if (isError) {
    return <p className="px-4 py-3 text-sm text-red-600">Failed to load folders.</p>
  }

  if (!folders || folders.length === 0) {
    return <p className="px-4 py-3 text-sm text-gray-500">No folders yet.</p>
  }

  const tree = buildTree(folders)

  return (
    <nav aria-label="Folders" className="py-2">
      <ul role="list">
        {tree.map((node) => (
          <FolderNode
            key={node.fullPath}
            node={node}
            depth={0}
            selectedFolder={selectedFolder}
          />
        ))}
      </ul>
    </nav>
  )
}
