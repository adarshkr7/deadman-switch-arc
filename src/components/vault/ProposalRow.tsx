import { useState } from 'react'
import { formatDateTime, shortAddress } from '@/lib/format'
import { sameAddress } from '@/lib/phase'
import { useVaultActions } from '@/hooks/useVaultActions'
import type { LiveProposal } from '@/hooks/useGuardianVotes'
import { ActionButton } from '@/components/ui'
import type { VaultCtx } from '@/components/vault/ctx'

export function proposalTitle(p: LiveProposal): string {
  const x = p.proposal
  if (x.kind === 'extend') return `Extend deadline to ${formatDateTime(x.newDeadline)}`
  if (x.kind === 'rotation') return `Make ${shortAddress(x.newOwner)} the new owner`
  return 'Cancel the pending withdrawal'
}

/** A guardian proposal collecting votes: progress toward the quorum and a vote button for each guardian. */
export function ProposalRow({ ctx, item }: { ctx: VaultCtx; item: LiveProposal }) {
  const { vault, roles, address, txBusy } = ctx
  const actions = useVaultActions()
  const [busy, setBusy] = useState(false)
  const x = item.proposal
  const pct = Math.min(100, (item.approvals / Math.max(1, item.threshold)) * 100)

  const reason = !roles.guardian
    ? 'Only guardians can vote.'
    : item.iVoted
      ? 'You already voted on this.'
      : txBusy && !busy
        ? 'Another transaction is in progress.'
        : undefined

  const vote = async () => {
    setBusy(true)
    if (x.kind === 'extend') await actions.extendDeadline(vault, x.newDeadline)
    else if (x.kind === 'rotation') await actions.proposeRotation(vault, x.newOwner)
    else await actions.cancelWithdraw(vault, true)
    setBusy(false)
  }

  return (
    <li className="glass-inner rounded-2xl p-3">
      <p className="text-sm font-semibold text-pretty">{proposalTitle(item)}</p>
      <div className="mt-2 flex items-center justify-between text-xs" style={{ color: 'var(--muted)' }}>
        <span className="tabular-nums">
          {item.approvals} of {item.threshold} approvals
        </span>
        <span>
          {item.voters.map((v) => (sameAddress(v, address) ? 'You' : shortAddress(v))).join(', ') || 'No votes yet'}
        </span>
      </div>
      <div className="mt-1.5 h-1.5 overflow-hidden rounded-full" style={{ background: 'var(--track)' }} role="progressbar" aria-valuenow={item.approvals} aria-valuemin={0} aria-valuemax={item.threshold}>
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: 'var(--accent)' }} />
      </div>
      <ActionButton className="mt-3" variant="ghost" busy={busy} reason={reason} onClick={() => void vote()}>
        Add my vote
      </ActionButton>
    </li>
  )
}
