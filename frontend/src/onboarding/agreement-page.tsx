import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { TERMS_VERSION, TermsContent } from '../legal/terms-of-service'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Checkbox } from '@/components/ui/checkbox'
import { cn } from '@/lib/utils'

export default function AgreementPage() {
  const [agreed, setAgreed] = useState(false)
  const navigate = useNavigate()
  const { data } = useOnboardingStatus()
  const { mutateAsync, isPending } = useAcceptTerms()

  const version = data?.current_tos_version ?? TERMS_VERSION

  async function submit() {
    await mutateAsync(version)
    navigate('/onboard', { replace: true })
  }

  return (
    <section className="mx-auto flex min-h-0 w-full max-w-3xl flex-1 flex-col px-4 py-6">
      <div className="flex min-h-0 flex-1 flex-col gap-4 rounded-2xl border border-border bg-background p-5 sm:p-6">
        <h1 className="shrink-0 text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          Review the Terms
        </h1>
        <ScrollArea
          role="region"
          aria-label="Terms of Service"
          className="min-h-0 flex-1 rounded-lg border border-border bg-card"
        >
          <div className="prose prose-sm dark:prose-invert max-w-none p-5">
            <TermsContent />
          </div>
        </ScrollArea>
        <label
          className={cn(
            'flex shrink-0 cursor-pointer items-center gap-3 rounded-lg border p-4 transition-colors',
            agreed ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/50',
          )}
        >
          <Checkbox
            checked={agreed}
            onCheckedChange={(v) => setAgreed(v === true)}
            aria-label="I have read and agree to the Terms of Service"
          />
          <span className="text-sm font-medium text-foreground">
            I have read and agree to the Terms of Service
          </span>
        </label>
        <button
          type="button"
          onClick={submit}
          disabled={!agreed || isPending}
          className="w-full shrink-0 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? 'Saving…' : 'Continue'}
        </button>
      </div>
    </section>
  )
}
