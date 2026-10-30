import { useState } from 'react'
import { ExternalLink, ShieldAlert } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/lib/vault'
import { formatDuration } from '@/lib/format'
import { useVaultActions } from '@/hooks/useVaultActions'
import { Button, ActionButton } from '@/components/ui'
import { InlineCountdown } from '@/components/Countdown'
import type { VaultCtx } from '@/components/vault/ctx'

/**
 * Red alert shown at the top of the vault page while an owner rotation is pending.
 * Approving hands the vault over, so it sits behind a confirm dialog that says so.
 */
export function RotationAlert({ ctx }: { ctx: VaultCtx }) {
  const { vault, now, roles, txBusy, proposals } = ctx
  const actions = useVaultActions()
  const [busy, setBusy] = useState<'approve' | 'veto' | 'execute'>()
  const rotation = vault.rotation
  const earlyVotes = proposals.filter((p) => p.proposal.kind === 'rotation')

  if (!rotation) {
    // Votes started but the quorum is not reached yet: warn the people who can later stop it.
    const first = earlyVotes[0]
    if (!first || first.proposal.kind !== 'rotation') return null
    if (!(roles.owner || roles.delegate || roles.beneficiary)) return null
    return (
      <div className="rounded-3xl p-4 text-sm" role="status" style={{ background: 'var(--warn-bg)', color: 'var(--warn)' }}>
        <p className="font-semibold">Guardians are voting to replace the owner</p>
        <p className="mt-1 text-pretty">
          {first.approvals} of {first.threshold} approvals so far for <span className="mono break-all">{first.proposal.newOwner}</span>. Nothing changes unless
          the quorum is reached and the owner or delegate approves.
        </p>
      </div>
    )
  }

  const remaining = now === undefined ? undefined : rotation.executableAt - now
  const timelockDone = remaining !== undefined && remaining <= 0
  const canDecide = roles.owner || roles.delegate
  const canVeto = canDecide || roles.beneficiary
  const triggered = vault.triggered

  const run = async (kind: 'approve' | 'veto' | 'execute') => {
    setBusy(kind)
    if (kind === 'approve') await actions.approveRotation(vault, rotation.newOwner)
    else if (kind === 'veto') await actions.cancelRotation(vault)
    else await actions.executeRotation(vault)
    setBusy(undefined)
  }

  return (
    <section
      role="alert"
      className="alert-pulse rounded-3xl p-5"
      style={{ background: 'var(--danger-bg)', border: '2px solid var(--danger)', color: 'var(--ink)' }}
    >
      <div className="flex items-start gap-3">
        <ShieldAlert className="mt-0.5 size-6 shrink-0" style={{ color: 'var(--danger)' }} aria-hidden />
        <div className="min-w-0">
          <h2 className="display text-xl font-bold" style={{ color: 'var(--danger)' }}>
            Owner rotation pending
          </h2>
          <p className="mt-1 text-sm text-pretty">
            Guardians proposed handing this vault to a new owner. If approved and executed, the new owner can withdraw everything.
          </p>
        </div>
      </div>

      <div className="glass-inner mt-4 rounded-2xl p-3">
        <div className="text-[11px] font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>
          Proposed new owner
        </div>
        <a
          href={buildAddressExplorerUrl(CHAIN_ID, rotation.newOwner)}
          target="_blank"
          rel="noopener noreferrer"
          className="mono mt-1 inline-flex items-start gap-1 break-all text-sm hover:underline"
        >
          {rotation.newOwner}
          <ExternalLink className="mt-0.5 size-3 shrink-0" aria-hidden />
        </a>
        <dl className="mt-3 grid grid-cols-2 gap-3 text-sm">
          <div>
            <dt className="text-xs" style={{ color: 'var(--muted)' }}>
              Timelock ({formatDuration(vault.config.rotationTimelock)})
            </dt>
            <dd className="display text-lg font-bold">{timelockDone ? 'Finished' : <InlineCountdown remaining={remaining} />}</dd>
          </div>
          <div>
            <dt className="text-xs" style={{ color: 'var(--muted)' }}>
              Owner approval
            </dt>
            <dd className="display text-lg font-bold" style={{ color: rotation.approved ? 'var(--danger)' : 'var(--success)' }}>
              {rotation.approved ? 'Approved' : 'Not approved'}
            </dd>
          </div>
        </dl>
      </div>

      <p className="mt-3 text-sm text-pretty">
        {rotation.approved
          ? timelockDone
            ? 'Approved and the timelock is over: anyone can execute this now unless it is vetoed.'
            : 'Already approved. It will be executable when the timelock ends unless it is vetoed.'
          : 'It cannot execute until the owner or the check-in delegate approves it. Routine check-ins never approve.'}
      </p>

      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        {canVeto ? (
          <Button variant="primary" busy={busy === 'veto'} disabled={txBusy} onClick={() => void run('veto')}>
            Veto this rotation
          </Button>
        ) : (
          <p className="text-xs sm:col-span-2" style={{ color: 'var(--muted)' }}>
            The owner, the delegate and every beneficiary can veto this rotation. Connect one of those wallets to act.
          </p>
        )}
        {canDecide && !rotation.approved && (
          <ActionButton
            variant="danger"
            busy={busy === 'approve'}
            disabled={txBusy}
            reason={triggered ? 'The vault is triggered, so rotations are blocked.' : undefined}
            onClick={() => void run('approve')}
          >
            Approve (hands over the vault)
          </ActionButton>
        )}
        {rotation.approved && timelockDone && !triggered && (
          <Button variant="danger" busy={busy === 'execute'} disabled={txBusy} onClick={() => void run('execute')}>
            Execute rotation
          </Button>
        )}
      </div>
      {!canDecide && roles.beneficiary && (
        <p className="mt-3 text-xs" style={{ color: 'var(--muted)' }}>
          As a beneficiary you can veto, but only the owner or delegate can approve.
        </p>
      )}
    </section>
  )
}
