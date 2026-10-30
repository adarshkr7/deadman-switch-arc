import { useState } from 'react'
import { isAddress } from 'viem'
import type { Address } from 'viem'
import { ZERO_ADDRESS } from '@/lib/vault'
import { shortAddress, formatDateTime } from '@/lib/format'
import { sameAddress } from '@/lib/phase'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, Card, Notice, SectionLabel, StatusChip, TextField } from '@/components/ui'
import { ProposalRow } from '@/components/vault/ProposalRow'
import type { VaultCtx } from '@/components/vault/ctx'

const SPANS = [
  { label: 'minutes', seconds: 60 },
  { label: 'hours', seconds: 3600 },
  { label: 'days', seconds: 86400 },
] as const
/** Keeps a proposed deadline inside the contract's "at most one window from now" cap despite clock drift. */
const CAP_MARGIN = 10

function ExtendForm({ ctx }: { ctx: VaultCtx }) {
  const { vault, now, roles, derived, txBusy } = ctx
  const actions = useVaultActions()
  const [amount, setAmount] = useState('')
  const [span, setSpan] = useState(1)
  const [busy, setBusy] = useState(false)

  const secs = /^\d+$/.test(amount) ? Number(amount) * SPANS[span].seconds : undefined
  const newDeadline = now !== undefined && secs !== undefined ? Math.floor(now) + secs : undefined
  const maxDeadline = now === undefined ? undefined : Math.floor(now) + vault.interval - CAP_MARGIN

  let reason: string | undefined
  if (!roles.guardian) reason = 'Only guardians can extend the deadline.'
  else if (vault.triggered) reason = 'The vault is triggered, so the deadline can no longer be extended.'
  else if (derived.expired) reason = 'The deadline has passed. Guardians cannot extend it after expiry.'
  else if (vault.extensionUsed) reason = 'Guardians already extended once since the last check-in. It resets when the owner or delegate checks in.'
  else if (newDeadline === undefined) reason = 'Enter how long from now the new deadline should be.'
  else if (newDeadline <= vault.deadline) reason = 'The new deadline must be later than the current one.'
  else if (maxDeadline !== undefined && newDeadline > maxDeadline) reason = 'At most one full check-in window from now.'
  else if (txBusy && !busy) reason = 'Another transaction is in progress.'

  return (
    <div className="glass-inner rounded-2xl p-4">
      <h4 className="text-sm font-semibold">Propose a deadline extension</h4>
      <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
        Once per check-in period, before the deadline, and at most one window ({Math.round(vault.interval / 60)} min) from now. Other guardians must vote for the same time.
      </p>
      <div className="mt-3 flex gap-2">
        <input
          aria-label="Extend deadline to this long from now"
          inputMode="numeric"
          value={amount}
          onChange={(e) => setAmount(e.target.value.replace(/\D/g, ''))}
          placeholder="e.g. 2"
          className="input-base min-h-11 w-24 rounded-xl px-3 text-sm tabular-nums outline-none"
        />
        <select
          aria-label="Unit"
          value={span}
          onChange={(e) => setSpan(Number(e.target.value))}
          className="input-base min-h-11 flex-1 rounded-xl px-3 text-sm"
        >
          {SPANS.map((s, i) => (
            <option key={s.label} value={i}>
              {s.label} from now
            </option>
          ))}
        </select>
      </div>
      {newDeadline !== undefined && (
        <p className="mt-2 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
          New deadline: {formatDateTime(newDeadline)}
        </p>
      )}
      <ActionButton
        className="mt-3"
        variant="ghost"
        busy={busy}
        reason={reason}
        onClick={() => {
          if (newDeadline === undefined) return
          setBusy(true)
          void actions.extendDeadline(vault, newDeadline).finally(() => setBusy(false))
        }}
      >
        Add my vote to extend
      </ActionButton>
    </div>
  )
}

function RotationForm({ ctx }: { ctx: VaultCtx }) {
  const { vault, roles, txBusy } = ctx
  const actions = useVaultActions()
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const target = value.trim()

  const blocked = (a: string) =>
    a.toLowerCase() === ZERO_ADDRESS ||
    sameAddress(a, vault.owner) ||
    sameAddress(a, vault.delegate) ||
    sameAddress(a, vault.config.fallbackAddress) ||
    vault.guardians.some((g) => sameAddress(g, a)) ||
    vault.beneficiaries.some((b) => sameAddress(b, a))

  let reason: string | undefined
  if (!roles.guardian) reason = 'Only guardians can propose a new owner.'
  else if (vault.triggered) reason = 'The vault is triggered, so rotations are blocked.'
  else if (vault.rotation) reason = 'A rotation is already pending. It must be vetoed or executed first.'
  else if (!isAddress(target)) reason = 'Enter the new owner wallet address.'
  else if (blocked(target)) reason = 'That address cannot be the new owner (owner, guardian, beneficiary, delegate or fallback).'
  else if (txBusy && !busy) reason = 'Another transaction is in progress.'

  return (
    <div className="glass-inner rounded-2xl p-4">
      <h4 className="text-sm font-semibold">Propose a new owner</h4>
      <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
        For a lost owner key. After the quorum, the owner or delegate must approve, then a {Math.round(vault.config.rotationTimelock / 60)} minute timelock must pass. The owner, delegate and every beneficiary can veto.
      </p>
      <TextField
        className="mono mt-3"
        label="New owner address"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        placeholder="0x…"
        spellCheck={false}
      />
      <ActionButton
        className="mt-3"
        variant="ghost"
        busy={busy}
        reason={reason}
        onClick={() => {
          setBusy(true)
          void actions.proposeRotation(vault, target as Address).finally(() => setBusy(false))
        }}
      >
        Add my vote to propose
      </ActionButton>
    </div>
  )
}

export function GuardiansPanel({ ctx }: { ctx: VaultCtx }) {
  const { vault, proposals, address } = ctx
  const c = vault.config

  if (vault.guardians.length === 0) {
    return (
      <Card>
        <SectionLabel>Guardians</SectionLabel>
        <p className="mt-3 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          This vault has no guardians. Nobody can extend the deadline or propose a new owner. Guardians are chosen when a vault is created and cannot be added later.
        </p>
      </Card>
    )
  }

  const voted = new Set(proposals.flatMap((p) => p.voters.map((v) => v.toLowerCase())))

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <div className="flex items-center justify-between">
          <SectionLabel>Guardians</SectionLabel>
          <StatusChip tone="neutral">
            {c.guardianThreshold} of {c.guardianCount} must agree
          </StatusChip>
        </div>
        <ul className="mt-3 flex flex-col gap-2">
          {vault.guardians.map((g) => (
            <li key={g} className="glass-inner flex items-center justify-between rounded-2xl px-4 py-3 text-sm">
              <span className="mono" title={g}>
                {shortAddress(g)}
                {sameAddress(g, address) && (
                  <span className="ml-2 text-xs font-semibold" style={{ color: 'var(--accent-hover)' }}>
                    You
                  </span>
                )}
              </span>
              {voted.has(g.toLowerCase()) && <StatusChip tone="success">Voted</StatusChip>}
            </li>
          ))}
        </ul>
        <div className="mt-3">
          <Notice>
            {vault.extensionUsed
              ? 'Deadline extension used since the last check-in. It resets when the owner or delegate checks in.'
              : 'One deadline extension is available this check-in period.'}{' '}
            Guardians can never move funds or trigger the vault early.
          </Notice>
        </div>
      </Card>

      <Card>
        <SectionLabel>Open proposals</SectionLabel>
        {proposals.length === 0 ? (
          <p className="mt-3 text-sm" style={{ color: 'var(--muted)' }}>
            No proposals are collecting votes.
          </p>
        ) : (
          <ul className="mt-3 flex flex-col gap-2">
            {proposals.map((p) => (
              <ProposalRow key={p.proposal.actionId} ctx={ctx} item={p} />
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <SectionLabel>Guardian actions</SectionLabel>
        <div className="mt-3 flex flex-col gap-3">
          <ExtendForm ctx={ctx} />
          <RotationForm ctx={ctx} />
        </div>
      </Card>
    </div>
  )
}
