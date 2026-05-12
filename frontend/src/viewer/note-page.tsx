import { PanelRightClose, PanelRightOpen } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import type { ImperativePanelHandle } from 'react-resizable-panels'
import { useParams } from 'react-router'
import { toast } from 'sonner'
import { useNote, useUpdateNote } from '../api/queries'
import { Button } from '@/components/ui/button'
import {
  ResizableHandle,
  ResizablePanel,
  ResizablePanelGroup,
} from '@/components/ui/resizable'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
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
  const tocRef = useRef<ImperativePanelHandle>(null)
  const [tocCollapsed, setTocCollapsed] = useState(false)

  useEffect(() => {
    if (note) setDraft(note.content)
  }, [note?.path, note?.content])

  const toggleToc = () => {
    const panel = tocRef.current
    if (!panel) return
    if (panel.isCollapsed()) panel.expand()
    else panel.collapse()
  }

  if (!path) {
    return <p className="p-6 text-muted-foreground">No note selected</p>
  }
  if (isLoading) {
    return <p className="p-6 text-muted-foreground">Loading note…</p>
  }
  if (error) {
    return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>
  }
  if (!note) {
    return <p className="p-6 text-muted-foreground">Note not found</p>
  }

  const dirty = draft !== note.content
  const saving = update.isPending

  const handleSave = async () => {
    try {
      await update.mutateAsync({ path: note.path, content: draft, version: note.version })
      toast.success('Note saved')
      setMode('preview')
    } catch (err) {
      toast.error('Failed to save note', {
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  const card = (
    <Tabs
      value={mode}
      onValueChange={(v) => setMode(v as Mode)}
      className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden rounded-2xl bg-card text-card-foreground shadow-sm ring-1 ring-border/60"
    >
      <div className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-4 py-2">
        <TabsList variant="line">
          <TabsTrigger value="preview">Preview</TabsTrigger>
          <TabsTrigger value="edit">Edit</TabsTrigger>
        </TabsList>
        <div className="flex items-center gap-2">
          {mode === 'edit' && (
            <>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setDraft(note.content)}
                disabled={!dirty || saving}
              >
                Revert
              </Button>
              <Button size="sm" onClick={handleSave} disabled={!dirty || saving}>
                {saving ? 'Saving…' : 'Save'}
              </Button>
            </>
          )}
          {mode === 'preview' && (
            <Button
              variant="ghost"
              size="icon-sm"
              onClick={toggleToc}
              aria-label={tocCollapsed ? 'Show outline' : 'Hide outline'}
              title={tocCollapsed ? 'Show outline' : 'Hide outline'}
            >
              {tocCollapsed ? <PanelRightOpen /> : <PanelRightClose />}
            </Button>
          )}
        </div>
      </div>

      <TabsContent
        value="preview"
        forceMount
        className="min-h-0 flex-1 data-[state=inactive]:hidden"
      >
        <ScrollArea className="h-full">
          <NoteView
            content={note.content}
            title={note.title}
            tags={note.tags}
            updatedAt={note.updated_at}
          />
        </ScrollArea>
      </TabsContent>
      <TabsContent
        value="edit"
        forceMount
        className="min-h-0 flex-1 data-[state=inactive]:hidden"
      >
        <ScrollArea className="h-full">
          <div className="px-6 py-6 lg:px-8 lg:py-8">
            <NoteEditor value={draft} onChange={setDraft} />
          </div>
        </ScrollArea>
      </TabsContent>
    </Tabs>
  )

  return (
    <div className="mx-auto h-full w-full max-w-[100rem]">
      <ResizablePanelGroup direction="horizontal" autoSaveId="engram:note-page">
        <ResizablePanel id="note-card" order={1} defaultSize={78} minSize={45}>
          {card}
        </ResizablePanel>
        {mode === 'preview' && (
          <>
            <ResizableHandle withHandle />
            <ResizablePanel
              id="note-toc"
              order={2}
              ref={tocRef}
              defaultSize={22}
              minSize={12}
              maxSize={40}
              collapsible
              collapsedSize={0}
              onCollapse={() => setTocCollapsed(true)}
              onExpand={() => setTocCollapsed(false)}
            >
              <ScrollArea className="h-full">
                <div className="p-1">
                  <NoteToc content={note.content} />
                </div>
              </ScrollArea>
            </ResizablePanel>
          </>
        )}
      </ResizablePanelGroup>
    </div>
  )
}
