import { useRef } from 'react'
import { Joyride, type EventData, type Step, STATUS, EVENTS, ACTIONS } from 'react-joyride'
import { tourSteps } from './steps'

interface Props {
  active: boolean
  onExit: (reachedEnd: boolean) => void
  reachedEnd: boolean
  setReachedEnd: (v: boolean) => void
}

export function TourController({ active, onExit, setReachedEnd }: Props) {
  // Stash callbacks behind refs so React-Joyride's event handler always sees
  // the latest closures without us re-mounting on every parent render.
  const onExitRef = useRef(onExit)
  const setReachedEndRef = useRef(setReachedEnd)
  onExitRef.current = onExit
  setReachedEndRef.current = setReachedEnd

  const handle = (data: EventData) => {
    const { status, index, action, type } = data
    // Track final step reached for the "Create my vault" CTA semantics.
    if (type === EVENTS.STEP_AFTER && index === tourSteps.length - 1 && action === ACTIONS.NEXT) {
      setReachedEndRef.current(true)
      onExitRef.current(true)
      return
    }
    if (status === STATUS.FINISHED || status === STATUS.SKIPPED) {
      onExitRef.current(status === STATUS.FINISHED)
    }
  }

  return (
    <Joyride
      steps={tourSteps as Step[]}
      run={active}
      continuous
      onEvent={handle}
      locale={{ last: 'Create my vault', skip: 'Skip' }}
      options={{
        showProgress: true,
        zIndex: 60, // sits above shadcn dialogs (z-50)
        // ESC closes; overlay click is a no-op (no overlay dismissal).
        overlayClickAction: false,
        // Show skip button alongside back+primary.
        buttons: ['skip', 'back', 'primary'],
        // Pick up the design tokens. CSS vars are HSL triplets in this app
        // (see frontend/src/index.css or main.css). Wrap with hsl() so the
        // browser parses them as colors rather than raw triplets.
        primaryColor: 'hsl(var(--primary))',
        backgroundColor: 'hsl(var(--popover))',
        textColor: 'hsl(var(--popover-foreground))',
        arrowColor: 'hsl(var(--popover))',
        overlayColor: 'rgba(0, 0, 0, 0.45)',
      }}
    />
  )
}
