import { useState } from 'react'
import { ConnectKitButton } from 'connectkit'
import { TokenUSDC } from '@web3icons/react'
import { AlertTriangle, HandCoins, HeartPulse, Hourglass, Lock, PackageOpen, Zap } from 'lucide-react'
import { formatUsdc } from '@/onchain-money'
import { formatDateTime } from '@/lib/format'
import { roleLabels, sameAddress } from '@/lib/phase'
import type { UiState } from '@/lib/phase'
import { useBeneficiaryState, useClaimable } from '@/hooks/useVaultData'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, Button, StatusChip, TONES } from '@/components/ui'
import type { Tone } from '@/components/ui'
import { Countdown } from '@/components/Countdown'
import type { VaultCtx } from '@/components/vault/ctx'

const STATE_TONE: Record<UiState, Tone> = { active: 'success', warning: 'danger', challenge: 'warn', triggered: 'neutral', swept: 'neutral' }
const STATE_LABEL: Record<UiState, string> = {
  active: 'Active',
  warning: 'Warning',
  challenge: 'Challenge',
  triggered: 'Triggered',
  swept: 'Swept',
}

interface Primary {
  label: string
  icon: 'alive' | 'trigger' | 'claim' | 'sweep' | 'lock' | 'guard'
  run?: () => Promise<boolean>
  reason?: string
  danger?: boolean
}

const ICONS = { alive: HeartPulse, trigger: Zap, claim: HandCoins, sweep: PackageOpen, lock: Lock, guard: Hourglass }

/** One state, one live countdown, one primary action for the connected role. */
export function StatusHero({ ctx }: { ctx: VaultCtx }) {
  const { vault, derived, roles, address, txBusy, goTab, now } = ctx
  const actions = useVaultActions()
  const claimable = useClaimable(vault.id)
  const { claimed, payouts } = useBeneficiaryState(vault.id, vault.beneficiaries)
  const [busy, setBusy] = useState(false)
  const tone = STATE_TONE[derived.state]
  const { state } = derived

  const myIndex = address ? vault.beneficiaries.findIndex((b) => sameAddress(b, address)) : -1
  const iClaimed = myIndex >= 0 && claimed[myIndex] === true
  const myPayout = myIndex >= 0 ? payouts[myIndex] : undefined
  const sweepReady = vault.triggered && !vault.swept && now !== undefined && now >= vault.sweepAt
  const canCheckIn = roles.owner || roles.delegate

  function choose(): Primary {
    if (state === 'swept') return { label: 'Vault closed', icon: 'lock', reason: 'Unclaimed funds were swept. Nothing more can be done here.' }
    if (state === 'active' || (state === 'warning' && !derived.expired)) {
      if (canCheckIn) return { label: "I'm alive", icon: 'alive', run: () => actions.checkIn(vault) }
      if (roles.guardian) {
        return {
          label: 'Open guardian tools',
          icon: 'guard',
          run: () => {
            goTab('guardians')
            return Promise.resolve(true)
          },
        }
      }
      return {
        label: roles.beneficiary ? 'Claim locked' : 'Check-in only',
        icon: 'lock',
        reason: roles.beneficiary
          ? 'Claims open only if the owner stops checking in and the vault is triggered.'
          : 'Only the owner or the check-in delegate can check in. You can still deposit below.',
      }
    }
    if (state === 'warning') {
      return { label: 'Trigger vault', icon: 'trigger', run: () => actions.trigger(vault), danger: true }
    }
    if (state === 'challenge') {
      if (canCheckIn) return { label: "Cancel trigger, I'm alive", icon: 'alive', run: () => actions.checkIn(vault) }
      return { label: 'Claims not open yet', icon: 'lock', reason: 'Claims open when the challenge window ends. The owner can still cancel until then.' }
    }
    // triggered, claims open
    if (roles.beneficiary && !iClaimed) {
      const amount = claimable ?? 0n
      return {
        label: `Claim ${formatUsdc(amount)} USDC`,
        icon: 'claim',
        run: () => actions.claim(vault, amount, myPayout ?? address ?? vault.owner),
      }
    }
    // Sweeping sends other beneficiaries' unclaimed shares to the fallback, so it is only ever the
    // fallback's main action. The contract still lets anyone call it; that lives in the Details tab.
    if (sweepReady && roles.fallback) return { label: 'Collect unclaimed funds', icon: 'sweep', run: () => actions.sweep(vault), danger: true }
    if (roles.beneficiary && iClaimed) return { label: 'Claimed', icon: 'lock', reason: 'You already claimed your share. Other beneficiaries claim their own shares.' }
    return { label: 'Nothing to do', icon: 'lock', reason: "Each beneficiary claims their own share. Shares nobody claims in time go to the fallback address the owner chose." }
  }

  const primary = choose()
  const Icon = ICONS[primary.icon]
  const t = TONES[tone]
  const pool = vault.triggered ? vault.claimPool || vault.balance : vault.balance
  const urgent = state === 'warning'
  const needsWallet = !address && Boolean(primary.run)

  const countdownTone: Tone = urgent ? 'danger' : state === 'challenge' ? 'warn' : state === 'active' ? 'success' : 'neutral'

  return (
    <section
      className={`glass-card rounded-3xl p-5 sm:p-6 ${urgent ? 'alert-pulse' : ''}`}
      style={urgent ? { borderColor: 'var(--danger)', borderWidth: 2, background: 'var(--danger-bg)' } : undefined}
      aria-label="Vault status"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <StatusChip tone={tone}>{STATE_LABEL[state]}</StatusChip>
        <span className="text-xs" style={{ color: 'var(--muted)' }}>
          {roles.visitor ? (address ? 'Visitor (no role in this vault)' : 'Read-only view') : `You: ${roleLabels(roles).join(', ')}`}
        </span>
      </div>

      <h2 className="display mt-3 flex items-center gap-2 text-2xl font-bold text-balance" style={urgent ? { color: 'var(--danger)' } : undefined}>
        {urgent && <AlertTriangle className="size-6 shrink-0" aria-hidden />}
        {derived.headline}
      </h2>

      <div className="mt-4 flex items-baseline gap-2">
        <TokenUSDC variant="branded" size={28} className="self-center" />
        <span className="display text-4xl font-bold tabular-nums sm:text-5xl">{formatUsdc(pool)}</span>
        <span className="text-lg font-medium" style={{ color: 'var(--subtle)' }}>
          USDC
        </span>
      </div>
      <p className="mt-1 text-xs" style={{ color: 'var(--muted)' }}>
        {vault.triggered ? 'Reserved for beneficiaries' : 'Held in this vault'}
      </p>

      {state !== 'swept' && (
        <div className="mt-5">
          {derived.expired && state === 'warning' ? (
            <p className="rounded-2xl p-3 text-sm font-medium text-pretty" style={{ background: t.bg, color: t.fg }}>
              The deadline passed {now !== undefined ? formatDateTime(vault.deadline) : ''}. Anyone can trigger this vault now. The owner or delegate can still cancel a trigger by
              checking in during the challenge window.
            </p>
          ) : (
            <Countdown
              remaining={derived.remaining === undefined ? undefined : Math.max(0, derived.remaining)}
              total={derived.total}
              label={derived.countdownLabel}
              tone={countdownTone}
            />
          )}
        </div>
      )}
      {state === 'active' || (state === 'warning' && !derived.expired) ? (
        <p className="mt-3 text-xs" style={{ color: 'var(--subtle)' }}>
          Deadline {formatDateTime(vault.deadline)}
        </p>
      ) : null}

      <div className="mt-5">
        {needsWallet ? (
          <ConnectKitButton.Custom>
            {({ show }) => (
              <Button onClick={show} className="w-full py-4 text-base">
                Connect wallet to continue
              </Button>
            )}
          </ConnectKitButton.Custom>
        ) : (
          <ActionButton
            variant={primary.danger ? 'danger' : 'primary'}
            busy={busy}
            reason={primary.reason ?? (txBusy && !busy ? 'Another transaction is in progress.' : undefined)}
            className="[&_button]:min-h-14 [&_button]:text-base"
            onClick={() => {
              if (!primary.run) return
              setBusy(true)
              void primary.run().finally(() => setBusy(false))
            }}
          >
            <Icon className="size-5" aria-hidden />
            {primary.label}
          </ActionButton>
        )}
      </div>
    </section>
  )
}
