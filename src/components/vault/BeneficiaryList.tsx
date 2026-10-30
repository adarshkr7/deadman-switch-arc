import { useState } from 'react'
import { isAddress } from 'viem'
import type { Address } from 'viem'
import { ExternalLink } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { formatUsdc } from '@/onchain-money'
import { CHAIN_ID, ZERO_ADDRESS } from '@/lib/vault'
import { bpsToPercent, shortAddress } from '@/lib/format'
import { sameAddress } from '@/lib/phase'
import { useBeneficiaryState } from '@/hooks/useVaultData'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, Card, SectionLabel, StatusChip, TextField } from '@/components/ui'
import type { VaultCtx } from '@/components/vault/ctx'

function PayoutEditor({ ctx, current }: { ctx: VaultCtx; current: Address | undefined }) {
  const { vault, address, txBusy } = ctx
  const actions = useVaultActions()
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState(false)
  const target = value.trim()
  const usingCustom = current && !sameAddress(current, address)

  const reason = !isAddress(target)
    ? 'Enter the wallet that should receive your share.'
    : target.toLowerCase() === ZERO_ADDRESS
      ? 'That address is not allowed.'
      : txBusy && !busy
        ? 'Another transaction is in progress.'
        : undefined

  return (
    <div className="glass-inner mt-4 rounded-2xl p-4">
      <h4 className="text-sm font-semibold">Where should your share go?</h4>
      <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
        {usingCustom ? `Currently paid to ${current}.` : 'By default your share is paid to your own wallet.'} You can change this until you claim.
      </p>
      <TextField className="mono mt-3" label="Payout address" value={value} onChange={(e) => setValue(e.target.value)} placeholder="0x…" spellCheck={false} />
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <ActionButton
          variant="ghost"
          busy={busy}
          reason={reason}
          onClick={() => {
            setBusy(true)
            void actions.setPayout(vault, target as Address).finally(() => setBusy(false))
          }}
        >
          Save payout address
        </ActionButton>
        {usingCustom && (
          <ActionButton
            variant="ghost"
            busy={busy}
            reason={txBusy && !busy ? 'Another transaction is in progress.' : undefined}
            onClick={() => {
              setBusy(true)
              void actions.setPayout(vault, undefined).finally(() => setBusy(false))
            }}
          >
            Use my own wallet
          </ActionButton>
        )}
      </div>
    </div>
  )
}

/** Fixed beneficiaries with shares, claim status and payout addresses; a payout editor for beneficiaries. */
export function BeneficiaryList({ ctx }: { ctx: VaultCtx }) {
  const { vault, address, roles } = ctx
  const { claimed, payouts } = useBeneficiaryState(vault.id, vault.beneficiaries)
  const pool = vault.triggered ? vault.claimPool || vault.balance : vault.balance
  const myIndex = address ? vault.beneficiaries.findIndex((b) => sameAddress(b, address)) : -1
  const iClaimed = myIndex >= 0 && claimed[myIndex] === true

  return (
    <Card>
      <SectionLabel>Beneficiaries (fixed)</SectionLabel>
      <ul className="mt-3 flex flex-col gap-2">
        {vault.beneficiaries.map((b, i) => {
          const bps = vault.sharesBps[i]
          const projected = (pool * BigInt(bps)) / 10000n
          const payout = payouts[i]
          return (
            <li key={b} className="glass-inner flex items-center justify-between gap-3 rounded-2xl px-4 py-3">
              <div className="min-w-0">
                <a
                  href={buildAddressExplorerUrl(CHAIN_ID, b)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="mono inline-flex items-center gap-1 text-sm hover:underline"
                  title={b}
                >
                  {shortAddress(b)}
                  <ExternalLink className="size-3" aria-hidden />
                </a>
                {sameAddress(b, address) && (
                  <span className="ml-2 text-xs font-semibold" style={{ color: 'var(--accent-hover)' }}>
                    You
                  </span>
                )}
                <div className="mt-0.5 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
                  {vault.triggered ? 'About ' : 'Currently about '}
                  {formatUsdc(projected)} USDC
                  {payout && !sameAddress(payout, b) ? ` · paid to ${shortAddress(payout)}` : ''}
                </div>
              </div>
              <div className="flex shrink-0 items-center gap-2">
                {vault.triggered && claimed[i] === true && <StatusChip tone="success">Claimed</StatusChip>}
                <span className="display text-lg font-bold tabular-nums">{bpsToPercent(bps)}%</span>
              </div>
            </li>
          )
        })}
      </ul>
      {roles.beneficiary && !iClaimed && !vault.swept && (
        <PayoutEditor ctx={ctx} current={myIndex >= 0 ? payouts[myIndex] : undefined} />
      )}
    </Card>
  )
}
