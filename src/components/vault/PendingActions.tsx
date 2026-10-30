import { useState } from 'react'
import type { ReactNode } from 'react'
import { formatUsdc } from '@/onchain-money'
import { shortAddress } from '@/lib/format'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, Card, SectionLabel } from '@/components/ui'
import { InlineCountdown } from '@/components/Countdown'
import { ProposalRow } from '@/components/vault/ProposalRow'
import type { VaultCtx } from '@/components/vault/ctx'

function Item({ title, detail, children }: { title: string; detail: ReactNode; children?: ReactNode }) {
  return (
    <li className="glass-inner rounded-2xl p-4">
      <div className="flex items-start justify-between gap-3">
        <p className="text-sm font-semibold text-pretty">{title}</p>
        <p className="display shrink-0 text-lg font-bold">{detail}</p>
      </div>
      {children}
    </li>
  )
}

/** Pending withdrawals, owner rotations, triggers and guardian votes, each with a live countdown and a Cancel action. */
export function PendingActions({ ctx }: { ctx: VaultCtx }) {
  const { vault, now, roles, txBusy, proposals, derived } = ctx
  const actions = useVaultActions()
  const [busy, setBusy] = useState<string>()
  const run = async (key: string, fn: () => Promise<boolean>) => {
    setBusy(key)
    await fn()
    setBusy(undefined)
  }
  const other = (key: string) => txBusy && busy !== key

  const items: ReactNode[] = []

  if (vault.withdrawal) {
    const w = vault.withdrawal
    const remaining = now === undefined ? undefined : w.executableAt - now
    const ready = remaining !== undefined && remaining <= 0
    const cancelVote = proposals.find((p) => p.proposal.kind === 'cancelWithdraw')
    const executeReason = !roles.owner
      ? 'Only the vault owner can execute a withdrawal.'
      : derived.state !== 'active' && derived.state !== 'warning'
        ? 'Withdrawals can only run while the vault is active.'
        : derived.expired
          ? 'The deadline passed, so this withdrawal can no longer run.'
          : !ready
            ? 'The withdrawal delay has not finished yet.'
            : other('exec')
              ? 'Another transaction is in progress.'
              : undefined
    const cancelReason = roles.owner || roles.guardian ? (other('cancel') ? 'Another transaction is in progress.' : cancelVote?.iVoted ? 'You already voted to cancel.' : undefined) : 'Only the owner or a guardian can cancel a withdrawal.'
    items.push(
      <Item key="withdrawal" title={`Withdrawal of ${formatUsdc(w.amount)} USDC`} detail={ready ? 'Ready' : <InlineCountdown remaining={remaining} />}>
        {cancelVote && (
          <p className="mt-1 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
            Guardian cancel votes: {cancelVote.approvals} of {cancelVote.threshold}
          </p>
        )}
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <ActionButton variant="ghost" reason={executeReason} busy={busy === 'exec'} onClick={() => void run('exec', () => actions.executeWithdraw(vault))}>
            Execute withdrawal
          </ActionButton>
          <ActionButton
            variant="ghost"
            reason={cancelReason}
            busy={busy === 'cancel'}
            onClick={() => void run('cancel', () => actions.cancelWithdraw(vault, !roles.owner))}
          >
            {roles.owner ? 'Cancel withdrawal' : 'Vote to cancel'}
          </ActionButton>
        </div>
      </Item>,
    )
  }

  if (vault.rotation) {
    const r = vault.rotation
    const remaining = now === undefined ? undefined : r.executableAt - now
    const canVeto = roles.owner || roles.delegate || roles.beneficiary
    items.push(
      <Item
        key="rotation"
        title={`Owner rotation to ${shortAddress(r.newOwner)}${r.approved ? ' (approved)' : ' (not approved)'}`}
        detail={remaining !== undefined && remaining <= 0 ? 'Timelock over' : <InlineCountdown remaining={remaining} />}
      >
        <ActionButton
          className="mt-3"
          variant="ghost"
          reason={canVeto ? (other('veto') ? 'Another transaction is in progress.' : undefined) : 'Only the owner, delegate or a beneficiary can veto.'}
          busy={busy === 'veto'}
          onClick={() => void run('veto', () => actions.cancelRotation(vault))}
        >
          Cancel rotation
        </ActionButton>
      </Item>,
    )
  }

  if (vault.triggered && !vault.swept && derived.state === 'challenge') {
    const remaining = now === undefined ? undefined : vault.challengeEnd - now
    const can = roles.owner || roles.delegate
    items.push(
      <Item key="trigger" title="Trigger challenge window" detail={<InlineCountdown remaining={remaining} />}>
        <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
          Claims open when this ends. Checking in now cancels the trigger.
        </p>
        <ActionButton
          className="mt-3"
          variant="ghost"
          reason={can ? (other('trigger') ? 'Another transaction is in progress.' : undefined) : 'Only the owner or the check-in delegate can cancel a trigger.'}
          busy={busy === 'trigger'}
          onClick={() => void run('trigger', () => actions.checkIn(vault))}
        >
          Cancel trigger
        </ActionButton>
      </Item>,
    )
  }

  const votes = proposals.filter((p) => p.proposal.kind !== 'cancelWithdraw')

  return (
    <Card>
      <SectionLabel>Pending actions</SectionLabel>
      {items.length === 0 && votes.length === 0 ? (
        <p className="mt-3 text-sm" style={{ color: 'var(--muted)' }}>
          Nothing is pending. Withdrawals, owner rotations, triggers and guardian votes appear here with live countdowns.
        </p>
      ) : (
        <ul className="mt-3 flex flex-col gap-3">
          {items}
          {votes.map((p) => (
            <ProposalRow key={p.proposal.actionId} ctx={ctx} item={p} />
          ))}
        </ul>
      )}
    </Card>
  )
}
