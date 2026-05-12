import { GripVertical } from "lucide-react"
import * as ResizablePrimitive from "react-resizable-panels"

import { cn } from "@/lib/utils"

function ResizablePanelGroup({
  className,
  ...props
}: React.ComponentProps<typeof ResizablePrimitive.PanelGroup>) {
  return (
    <ResizablePrimitive.PanelGroup
      data-slot="resizable-panel-group"
      className={cn(
        "flex h-full w-full data-[panel-group-direction=vertical]:flex-col",
        className
      )}
      {...props}
    />
  )
}

const ResizablePanel = ResizablePrimitive.Panel

function ResizableHandle({
  withHandle,
  className,
  ...props
}: React.ComponentProps<typeof ResizablePrimitive.PanelResizeHandle> & {
  withHandle?: boolean
}) {
  return (
    <ResizablePrimitive.PanelResizeHandle
      data-slot="resizable-handle"
      className={cn(
        "group/handle relative flex w-1 items-center justify-center bg-border transition-colors hover:bg-primary/40 data-[resize-handle-state=drag]:bg-primary data-[resize-handle-state=hover]:bg-primary/40 focus-visible:bg-primary/60 focus-visible:outline-hidden cursor-col-resize",
        "data-[panel-group-direction=vertical]:h-1 data-[panel-group-direction=vertical]:w-full data-[panel-group-direction=vertical]:cursor-row-resize",
        "[&[data-panel-group-direction=vertical]>div]:rotate-90",
        className
      )}
      {...props}
    >
      {withHandle && (
        <div className="z-10 flex h-8 w-4 items-center justify-center rounded-md border border-border bg-card shadow-sm transition group-hover/handle:border-primary/60 group-data-[resize-handle-state=drag]/handle:border-primary group-data-[resize-handle-state=drag]/handle:bg-primary/10">
          <GripVertical className="size-3 text-muted-foreground group-hover/handle:text-foreground group-data-[resize-handle-state=drag]/handle:text-primary" />
        </div>
      )}
    </ResizablePrimitive.PanelResizeHandle>
  )
}

export { ResizableHandle, ResizablePanel, ResizablePanelGroup }
