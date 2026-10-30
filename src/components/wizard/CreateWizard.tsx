import { useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { Check, ChevronLeft, ChevronRight, Loader2 } from 'lucide-react'
import { hasErrors, initialState, summarize, toParams, validate } from '@/lib/wizard'
import type { WizardState } from '@/lib/wizard'
import { useVaultActions } from '@/hooks/useVaultActions'
import { useTxLog } from '@/hooks/useTxLog'
import { usePrefs } from '@/hooks/usePrefs'
import { ActionButton, Button, Card, Notice } from '@/components/ui'
import { StepBeneficiaries } from '@/components/wizard/StepBeneficiaries'
import { StepShares } from '@/components/wizard/StepShares'
import { StepInterval } from '@/components/wizard/StepInterval'
import { StepGuardians } from '@/components/wizard/StepGuardians'
import { StepReview } from '@/components/wizard/StepReview'

const STEPS = ['Beneficiaries', 'Shares', 'Interval', 'Guardians', 'Review', 'Deploy'] as const
const DEPLOY = 5

type DeployState = 'idle' | 'sending' | 'failed' | 'done'

export function CreateWizard({ onCreated }: { onCreated: (vaultId: bigint) => void }) {
  const { address, isConnected } = useAccount()
  const { demo } = usePrefs()
  const actions = useVaultActions()
  const { entries } = useTxLog()
  const [draft, setState] = useState<WizardState>(() => initialState(demo, address))
  // The fallback defaults to the connected wallet until the person types another address.
  const state = useMemo<WizardState>(() => (draft.fallback ? draft : { ...draft, fallback: address ?? '' }), [draft, address])
  const [step, setStep] = useState(0)
  const [deploy, setDeploy] = useState<DeployState>('idle')
  const [createdId, setCreatedId] = useState<bigint>()

  const errors = useMemo(() => validate(state, demo, address), [state, demo, address])
  const stepErrors = [errors.beneficiaries, errors.shares, errors.interval, errors.guardians][step] ?? []
  const stepBlocked = stepErrors.length > 0
  const inFlight = entries.some((e) => e.status === 'wallet' || e.status === 'pending')

  const update = (patch: Partial<WizardState>) => setState((s) => ({ ...s, ...patch }))

  async function create() {
    const params = toParams(state, demo)
    if (!params || hasErrors(errors)) return
    setStep(DEPLOY)
    setDeploy('sending')
    const id = await actions.createVault(params, summarize(params))
    if (id === undefined) {
      setDeploy('failed')
      return
    }
    setCreatedId(id)
    setDeploy('done')
  }

  const stepProps = { state, update, errors, demo }

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <h2 className="display text-3xl font-bold text-balance">Create a vault</h2>
        <ol className="mt-4 flex items-center gap-1" aria-label="Progress">
          {STEPS.map((label, i) => {
            const done = i < step
            const current = i === step
            return (
              <li key={label} className="flex min-w-0 flex-1 flex-col items-center gap-1" aria-current={current ? 'step' : undefined}>
                <span
                  className="flex size-7 items-center justify-center rounded-full text-xs font-bold tabular-nums"
                  style={
                    done || current
                      ? { background: 'var(--accent)', color: 'var(--on-accent)' }
                      : { background: 'var(--neutral-bg)', color: 'var(--subtle)' }
                  }
                >
                  {done ? <Check className="size-3.5" aria-hidden /> : i + 1}
                </span>
                <span className="hidden truncate text-[10px] font-semibold sm:block" style={{ color: current ? 'var(--ink)' : 'var(--subtle)' }}>
                  {label}
                </span>
              </li>
            )
          })}
        </ol>
        <p className="mt-3 text-center text-sm font-semibold sm:hidden">
          Step {step + 1} of {STEPS.length}: {STEPS[step]}
        </p>
      </Card>

      <Card>
        {step === 0 && <StepBeneficiaries {...stepProps} />}
        {step === 1 && <StepShares {...stepProps} />}
        {step === 2 && <StepInterval {...stepProps} />}
        {step === 3 && <StepGuardians {...stepProps} />}
        {step === 4 && <StepReview {...stepProps} />}
        {step === DEPLOY && (
          <div className="flex flex-col items-center gap-3 py-6 text-center" aria-live="polite">
            {deploy === 'sending' && (
              <>
                <Loader2 className="size-8 animate-spin" style={{ color: 'var(--accent-hover)' }} aria-hidden />
                <p className="display text-xl font-bold">Creating your vault…</p>
                <p className="text-sm" style={{ color: 'var(--muted)' }}>
                  Confirm in your wallet, then wait for the network. The transaction hash appears under Transactions.
                </p>
              </>
            )}
            {deploy === 'done' && createdId !== undefined && (
              <>
                <span className="flex size-12 items-center justify-center rounded-full" style={{ background: 'var(--success-bg)', color: 'var(--success)' }}>
                  <Check className="size-6" aria-hidden />
                </span>
                <p className="display text-xl font-bold">Vault #{createdId.toString()} created</p>
                <p className="text-sm" style={{ color: 'var(--muted)' }}>
                  Next, deposit USDC and keep checking in before the deadline.
                </p>
                <Button onClick={() => onCreated(createdId)} className="mt-2">
                  Open vault
                </Button>
              </>
            )}
            {deploy === 'failed' && (
              <>
                <Notice tone="danger">The vault was not created. Nothing was changed. Check the Transactions list for the reason.</Notice>
                <Button
                  variant="ghost"
                  onClick={() => {
                    setDeploy('idle')
                    setStep(4)
                  }}
                >
                  Back to review
                </Button>
              </>
            )}
          </div>
        )}
      </Card>

      {step < DEPLOY && (
        <div className="flex items-start gap-3">
          <Button variant="ghost" onClick={() => setStep((s) => Math.max(0, s - 1))} disabled={step === 0} aria-label="Back">
            <ChevronLeft className="size-4" aria-hidden /> Back
          </Button>
          <div className="min-w-0 flex-1">
            {step < 4 ? (
              <ActionButton onClick={() => setStep((s) => s + 1)} reason={stepBlocked ? stepErrors[0] : undefined}>
                Next <ChevronRight className="size-4" aria-hidden />
              </ActionButton>
            ) : isConnected ? (
              <ActionButton
                onClick={() => void create()}
                reason={hasErrors(errors) ? 'Fix the highlighted steps before creating.' : inFlight ? 'Another transaction is in progress.' : undefined}
              >
                Create vault
              </ActionButton>
            ) : (
              <ConnectKitButton.Custom>
                {({ show }) => <Button onClick={show} className="w-full">Connect wallet to create</Button>}
              </ConnectKitButton.Custom>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
