import { useState } from 'react'
import type { ReactNode } from 'react'
import { isAddress } from 'viem'
import type { Address } from 'viem'
import { ExternalLink } from 'lucide-react'
import { buildAddressExplorerUrl, buildTxExplorerUrl } from '@/onchain-facts'
import { formatUsdc } from '@/onchain-money'
import { CHAIN_ID, ZERO_ADDRESS } from '@/lib/vault'
import { formatDuration, shortAddress, shortHash } from '@/lib/format'
import { sameAddress } from '@/lib/phase'
import { useFallbackPayout } from '@/hooks/useVaultData'
import { useVaultActions } from '@/hooks/useVaultActions'
import { argAddress, argBig } from '@/hooks/useVaultLogs'
import type { VaultEvent } from '@/hooks/useVaultLogs'
import { ActionButton, Card, SectionLabel, TextField } from '@/components/ui'
import { InlineCountdown } from '@/components/Countdown'
import type { VaultCtx } from '@/components/vault/ctx'

function describe(e: VaultEvent): string {
  const who = (k: string) => shortAddress(argAddress(e, k) ?? ZERO_ADDRESS)
  const amt = (k: string) => `${formatUsdc(argBig(e, k) ?? 0n)} USDC`
  switch (e.name) {
    case 'VaultCreated': return `Vault created by ${who('owner')}`
    case 'Deposited': return `${who('from')} deposited ${amt('amount')}`
    case 'CheckedIn': return `${who('by')} checked in`
    case 'CheckInDelegateSet': return argAddress(e, 'delegate') === ZERO_ADDRESS ? 'Delegate removed' : `Delegate set to ${who('delegate')}`
    case 'WithdrawRequested': return `Withdrawal of ${amt('amount')} requested`
    case 'WithdrawExecuted': return `Withdrawal of ${amt('amount')} executed`
    case 'WithdrawCancelled': return `Withdrawal cancelled by ${who('by')}`
    case 'GuardianApproved': return `${who('guardian')} voted (${String(argBig(e, 'approvals') ?? 0n)} of ${String(argBig(e, 'threshold') ?? 0n)})`
    case 'DeadlineExtended': return `Guardians extended the deadline`
    case 'ExtensionAllowanceReset': return `Extension allowance reset by ${who('by')}`
    case 'OwnerRotationProposed': return `Rotation to ${who('newOwner')} proposed`
    case 'OwnerRotationApproved': return `Rotation to ${who('newOwner')} approved by ${who('by')}`
    case 'OwnerRotationCancelled': return `Rotation vetoed by ${who('by')}`
    case 'OwnerRotated': return `Owner changed to ${who('newOwner')}`
    case 'Triggered': return `Triggered by ${who('caller')}`
    case 'TriggerCancelled': return `Trigger cancelled by ${who('by')}`
    case 'Finalized': return `Payout pool locked at ${amt('claimPool')}`
    case 'PayoutAddressSet': return `${who('beneficiary')} set a payout address`
    case 'Claimed': return `${who('beneficiary')} claimed ${amt('amount')}`
    case 'FallbackPayoutSet': return 'Fallback payout address changed'
    case 'Swept': return `${amt('amount')} swept to ${who('fallbackAddress')}`
    default: return e.name
  }
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 py-2 text-sm" style={{ borderBottom: '1px solid var(--border)' }}>
      <dt style={{ color: 'var(--muted)' }}>{label}</dt>
      <dd className="text-right font-medium tabular-nums">{children}</dd>
    </div>
  )
}

export function DetailsPanel({ ctx, events, loadingEvents }: { ctx: VaultCtx; events: VaultEvent[]; loadingEvents: boolean }) {
  const { vault, now, roles, txBusy, derived } = ctx
  const actions = useVaultActions()
  const fallbackPayout = useFallbackPayout(vault.id)
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState<string>()
  const c = vault.config
  const target = value.trim()

  const fbReason = !roles.fallback
    ? 'Only the fallback address can change where swept funds go.'
    : vault.swept
      ? 'Funds were already swept.'
      : !isAddress(target)
        ? 'Enter the address that should receive swept funds.'
        : txBusy && !busy
          ? 'Another transaction is in progress.'
          : undefined

  const lockReason = !vault.triggered
    ? 'Only available after a trigger.'
    : vault.swept || vault.finalized
      ? 'Already locked in.'
      : derived.state === 'challenge'
        ? 'Claims, and locking the payout pool, open when the challenge window ends.'
        : txBusy && !busy
          ? 'Another transaction is in progress.'
          : undefined
  const sweepRemaining = vault.triggered && now !== undefined ? vault.sweepAt - now : undefined
  const sweepReason = !vault.triggered ? 'Only available after a trigger.' : vault.swept ? 'Already swept.' : sweepRemaining !== undefined && sweepRemaining > 0 ? 'The sweep period has not finished yet.' : txBusy && !busy ? 'Another transaction is in progress.' : undefined

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <SectionLabel>Settings</SectionLabel>
        <dl className="mt-3">
          <Row label="Owner">{shortAddress(vault.owner)}</Row>
          <Row label="Check-in window">{formatDuration(vault.interval)}</Row>
          <Row label="Withdrawal delay">{formatDuration(c.withdrawDelay)}</Row>
          <Row label="Challenge window">{formatDuration(c.challengeWindow)}</Row>
          <Row label="Rotation timelock">{formatDuration(c.rotationTimelock)}</Row>
          <Row label="Sweep period">{formatDuration(c.sweepPeriod)}</Row>
          <Row label="Guardian approvals">{c.guardianCount === 0 ? 'No guardians' : `${c.guardianThreshold} of ${c.guardianCount}`}</Row>
          <Row label="Fallback address">
            <a href={buildAddressExplorerUrl(CHAIN_ID, c.fallbackAddress)} target="_blank" rel="noopener noreferrer" className="mono hover:underline">
              {shortAddress(c.fallbackAddress)}
            </a>
          </Row>
          <Row label="Sweep goes to">{fallbackPayout ? shortAddress(fallbackPayout) : '…'}</Row>
        </dl>
      </Card>

      {vault.triggered && (
        <Card>
          <SectionLabel>After the trigger</SectionLabel>
          <p className="mt-3 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
            {vault.swept ? 'Unclaimed funds were swept.' : <>Unclaimed funds can be swept in <InlineCountdown remaining={sweepRemaining} />. Beneficiaries can keep claiming until then.</>}
          </p>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <ActionButton variant="ghost" reason={lockReason} busy={busy === 'lock'} onClick={() => { setBusy('lock'); void actions.finalize(vault).finally(() => setBusy(undefined)) }}>
              Lock payout pool
            </ActionButton>
            <ActionButton variant="ghost" reason={sweepReason} busy={busy === 'sweep'} onClick={() => { setBusy('sweep'); void actions.sweep(vault).finally(() => setBusy(undefined)) }}>
              Sweep unclaimed funds
            </ActionButton>
          </div>
          {roles.fallback && !vault.swept && (
            <div className="mt-5">
              <TextField className="mono" label="Send swept funds to a different address" value={value} onChange={(e) => setValue(e.target.value)} placeholder="0x…" spellCheck={false} />
              <div className="mt-3 grid gap-3 sm:grid-cols-2">
                <ActionButton variant="ghost" reason={fbReason} busy={busy === 'fb'} onClick={() => { setBusy('fb'); void actions.setFallbackPayout(vault, target as Address).finally(() => setBusy(undefined)) }}>
                  Save destination
                </ActionButton>
                {fallbackPayout && !sameAddress(fallbackPayout, c.fallbackAddress) && (
                  <ActionButton variant="ghost" busy={busy === 'fbreset'} onClick={() => { setBusy('fbreset'); void actions.setFallbackPayout(vault, undefined).finally(() => setBusy(undefined)) }}>
                    Use the fallback address
                  </ActionButton>
                )}
              </div>
            </div>
          )}
        </Card>
      )}

      <Card>
        <SectionLabel>Activity</SectionLabel>
        {loadingEvents && events.length === 0 ? (
          <div className="mt-3 h-16 animate-pulse rounded-2xl" style={{ background: 'var(--track)' }} aria-busy="true" />
        ) : events.length === 0 ? (
          <p className="mt-3 text-sm" style={{ color: 'var(--muted)' }}>
            No activity found yet.
          </p>
        ) : (
          <ul className="mt-3 flex flex-col gap-2">
            {[...events].reverse().map((e) => (
              <li key={`${e.hash}-${e.logIndex}`} className="glass-inner rounded-2xl px-4 py-3">
                <p className="text-sm text-pretty">{describe(e)}</p>
                <a
                  href={buildTxExplorerUrl(CHAIN_ID, e.hash)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="mono mt-1 inline-flex items-center gap-1 text-xs hover:underline"
                  style={{ color: 'var(--accent-hover)' }}
                >
                  {shortHash(e.hash)}
                  <ExternalLink className="size-3" aria-hidden />
                  <span className="sr-only">View transaction on the explorer</span>
                </a>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}
