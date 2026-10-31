import { useState } from 'react'
import { ConnectKitButton } from 'connectkit'
import { TokenUSDC } from '@web3icons/react'
import { AlertTriangle, HandCoins, HeartPulse, Hourglass, Info, Loader2, Lock, MoreHorizontal, PackageOpen, Zap } from 'lucide-react'
import { formatUsdc } from '@/onchain-money'
import { formatDateTime } from '@/lib/format'
import { roleLabels, sameAddress } from '@/lib/phase'
import type { UiState } from '@/lib/phase'
import { useBeneficiaryState, useClaimable } from '@/hooks/useVaultData'
import { useVaultActions } from '@/hooks/useVaultActions'
import { StatusChip } from '@/components/ui'
import type { Tone } from '@/components/ui'
import { InlineCountdown } from '@/components/Countdown'
import { Gauge } from '@/components/Gauge'
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
  const pool = vault.triggered ? vault.claimPool || vault.balance : vault.balance
  const urgent = state === 'warning'
  const needsWallet = !address && Boolean(primary.run)
  const blocked = !needsWallet && (Boolean(primary.reason) || (txBusy && !busy) || !primary.run)

  const remaining = derived.remaining === undefined ? undefined : Math.max(0, derived.remaining)
  const fraction = state === 'swept' ? 0 : remaining !== undefined && derived.total > 0 ? Math.min(1, remaining / derived.total) : 0
  const percent = Math.round(fraction * 100)
  const barColor = urgent ? 'var(--danger)' : state === 'challenge' ? 'var(--warn)' : 'var(--accent)'
  const caption =
    primary.reason ??
    (txBusy && !busy ? 'Another transaction is in progress.' : needsWallet ? 'Connect a wallet to act on this vault.' : primary.label)

  const description =
    state === 'swept'
      ? 'Unclaimed funds were swept to the fallback address. This vault is closed.'
      : vault.triggered
        ? state === 'challenge' ? 'Reserved for the beneficiaries. The owner can still cancel by checking in before the challenge window ends.' : 'Reserved for the beneficiaries. Each one claims their own share; anything left unclaimed later goes to the fallback address.'
        : derived.expired
          ? `The deadline passed ${now !== undefined ? formatDateTime(vault.deadline) : ''}. Anyone can trigger this vault now; the owner or delegate can still cancel during the challenge window.`
          : `Held in this vault. The owner must check in before ${formatDateTime(vault.deadline)}, or the beneficiaries can claim it.`

  const run = () => {
    if (!primary.run || blocked) return
    setBusy(true)
    void primary.run().finally(() => setBusy(false))
  }

  const roundButton = (onClick: () => void) => (
    <button
      type="button"
      onClick={onClick}
      disabled={!needsWallet && blocked}
      aria-label={needsWallet ? 'Connect wallet' : primary.label}
      className={`flex size-14 shrink-0 items-center justify-center rounded-full transition-transform active:scale-95 disabled:cursor-not-allowed disabled:opacity-40 ${urgent && !blocked ? 'alert-pulse' : ''}`}
      style={{ background: primary.danger ? 'var(--danger)' : '#f4f1ea', color: primary.danger ? '#fff' : '#141416' }}
    >
      {busy ? <Loader2 className="size-6 animate-spin" aria-hidden /> : <Icon className="size-6" aria-hidden />}
    </button>
  )

  return (
    <section className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,1.45fr)]" aria-label="Vault status">
      {/* Large art card: the one state, big. */}
      <div
        className={`glass-card grain-art grain-wave art-${state} relative flex min-h-[260px] flex-col justify-between rounded-[28px] p-5 sm:row-span-2 sm:min-h-[360px] ${urgent ? 'alert-pulse' : ''}`}
      >
        <div className="grain-shade absolute inset-0 -z-[1]" aria-hidden />
        <div className="flex flex-wrap items-center justify-between gap-2">
          <StatusChip tone={STATE_TONE[state]}>{STATE_LABEL[state]}</StatusChip>
          <span className="rounded-full bg-black/40 px-2.5 py-1 text-[11px] font-medium text-white/85 backdrop-blur">
            {roles.visitor ? (address ? 'Visitor' : 'Read-only') : roleLabels(roles).join(' · ')}
          </span>
        </div>
        <h2 className="display flex items-end gap-2 text-3xl font-bold leading-tight text-white text-balance sm:text-4xl">
          {urgent && <AlertTriangle className="mb-1 size-7 shrink-0" aria-hidden />}
          {derived.headline}
        </h2>
      </div>

      {/* Wide card: art thumbnail, the balance and what it means. */}
      <div className="glass-card grid grid-cols-[auto_minmax(0,1fr)] items-center gap-4 rounded-[28px] p-3 sm:gap-6">
        <div className={`grain-art grain-swirl art-${state} size-28 rounded-[22px] sm:size-40`} aria-hidden />
        <div className="min-w-0 py-2 pr-2">
          <div className="flex items-center gap-2">
            <TokenUSDC variant="branded" size={24} className="shrink-0" />
            <span className="display truncate text-2xl font-bold tabular-nums sm:text-3xl">{formatUsdc(pool)}</span>
            <span className="text-sm font-semibold" style={{ color: 'var(--muted)' }}>
              USDC
            </span>
          </div>
          <p className="mt-2 text-xs leading-relaxed text-pretty sm:text-[13px]" style={{ color: 'var(--muted)' }}>
            {description}
          </p>
        </div>
      </div>

      <div className="grid gap-3 sm:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
        {/* Progress card: the one action as a round button, and the live countdown. */}
        <div className="glass-card flex flex-col justify-center rounded-[28px] px-4 py-5">
          <div className="flex items-center gap-3">
            {needsWallet ? <ConnectKitButton.Custom>{({ show }) => roundButton(() => show?.())}</ConnectKitButton.Custom> : roundButton(run)}
            <div className="min-w-0 flex-1">
              <div className="flex items-baseline gap-2 text-sm">
                <span className="font-semibold tabular-nums">{state === 'swept' ? 'Closed' : <InlineCountdown remaining={remaining} />}</span>
                <span className="truncate text-xs" style={{ color: 'var(--muted)' }}>
                  {derived.countdownLabel || 'No timer'}
                </span>
              </div>
              <div className="mt-2 h-1 overflow-hidden rounded-full" style={{ background: 'var(--track)' }}>
                <div className="h-full rounded-full transition-[width] duration-500" style={{ width: `${percent}%`, background: barColor }} />
              </div>
            </div>
            <button
              type="button"
              onClick={() => goTab('details')}
              aria-label="Vault details"
              className="flex size-9 shrink-0 items-center justify-center rounded-full border transition-colors hover:bg-white/10"
              style={{ borderColor: 'var(--border-strong)' }}
            >
              <Info className="size-4" aria-hidden />
            </button>
          </div>
          <p className="mt-3 text-center text-xs text-pretty" style={{ color: primary.reason ? 'var(--muted)' : 'var(--ink-2)' }}>
            {caption}
          </p>
        </div>

        {/* Gauge card: how much of the current window is left. */}
        <div className="glass-card relative flex flex-col justify-end rounded-[28px] px-4 pb-4 pt-6">
          <button
            type="button"
            onClick={() => goTab('details')}
            aria-label="More"
            className="absolute right-3 top-2 rounded-full p-1.5 transition-colors hover:bg-white/10"
          >
            <MoreHorizontal className="size-5" aria-hidden />
          </button>
          <Gauge value={fraction} label={state === 'swept' ? 'Vault closed' : '% of window left'} color={barColor} />
        </div>
      </div>
    </section>
  )
}
