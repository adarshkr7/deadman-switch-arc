import { useState } from 'react'
import { useReadContract } from 'wagmi'
import { formatUsdc, parseUsdc } from '@/onchain-money'
import { CHAIN_ID, USDC_ADDRESS, ZERO_ADDRESS, erc20Abi } from '@/lib/vault'
import { formatDuration } from '@/lib/format'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, AmountField, Card, SectionLabel } from '@/components/ui'
import type { VaultCtx } from '@/components/vault/ctx'

type Mode = 'deposit' | 'withdraw'

export function FundsCard({ ctx }: { ctx: VaultCtx }) {
  const { vault, roles, address, derived, txBusy } = ctx
  const actions = useVaultActions()
  const [mode, setMode] = useState<Mode>('deposit')
  const [amount, setAmount] = useState('')
  const [busy, setBusy] = useState(false)

  const { data: walletUsdc } = useReadContract({
    address: USDC_ADDRESS,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address ?? ZERO_ADDRESS],
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address), refetchInterval: 8000 },
  })

  let parsed: bigint | undefined
  try {
    parsed = amount ? parseUsdc(amount) : undefined
  } catch {
    parsed = undefined
  }
  const valid = parsed !== undefined && parsed > 0n
  const claimsOpen = derived.state === 'triggered' || derived.state === 'swept'

  let reason: string | undefined
  if (!address) reason = 'Connect a wallet to continue.'
  else if (mode === 'deposit') {
    if (claimsOpen) reason = 'Deposits are closed because claims are open.'
    else if (!valid) reason = 'Enter an amount.'
    else if (walletUsdc !== undefined && parsed !== undefined && parsed > walletUsdc) reason = 'That is more USDC than your wallet holds.'
  } else {
    if (!roles.owner) reason = 'Only the vault owner can withdraw.'
    else if (derived.state !== 'active' && derived.state !== 'warning') reason = 'Withdrawals are only possible while the vault is active.'
    else if (derived.expired) reason = 'The deadline passed, so withdrawals are locked.'
    else if (vault.withdrawal) reason = 'A withdrawal is already pending. Execute or cancel it first.'
    else if (!valid) reason = 'Enter an amount.'
    else if (parsed !== undefined && parsed > vault.balance) reason = 'That is more than the vault holds.'
  }
  if (!reason && txBusy && !busy) reason = 'Another transaction is in progress.'

  async function submit() {
    if (parsed === undefined || !valid) return
    setBusy(true)
    const ok = mode === 'deposit' ? await actions.deposit(vault, parsed) : await actions.requestWithdraw(vault, parsed)
    setBusy(false)
    if (ok) setAmount('')
  }

  const maxLabel =
    mode === 'deposit'
      ? walletUsdc !== undefined
        ? `Wallet: ${formatUsdc(walletUsdc)} · Max`
        : undefined
      : `Vault: ${formatUsdc(vault.balance)} · Max`

  return (
    <Card>
      <div className="mb-4 flex items-center justify-between">
        <SectionLabel>Funds</SectionLabel>
        <div className="glass-inner flex rounded-full p-1" role="tablist" aria-label="Deposit or withdraw">
          {(['deposit', 'withdraw'] as const).map((m) => (
            <button
              key={m}
              role="tab"
              aria-selected={mode === m}
              onClick={() => {
                setMode(m)
                setAmount('')
              }}
              className="min-h-9 rounded-full px-4 text-xs font-semibold capitalize transition-colors"
              style={mode === m ? { background: 'var(--accent)', color: 'var(--on-accent)' } : { color: 'var(--muted)' }}
            >
              {m === 'withdraw' ? 'Request withdrawal' : 'Deposit'}
            </button>
          ))}
        </div>
      </div>
      <div className="flex flex-col gap-3">
        <AmountField
          value={amount}
          onChange={setAmount}
          maxLabel={maxLabel}
          onMax={() => setAmount(formatUsdc(mode === 'deposit' ? (walletUsdc ?? 0n) : vault.balance))}
        />
        <p className="text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
          {mode === 'deposit'
            ? 'Anyone can deposit. Deposits never reset the timer. The first deposit also asks for a USDC allowance.'
            : `Withdrawals are delayed by ${formatDuration(vault.config.withdrawDelay)} and can be cancelled by you or the guardians.`}
        </p>
        <ActionButton variant="ghost" busy={busy} reason={reason} onClick={() => void submit()}>
          {mode === 'deposit' ? 'Deposit USDC' : 'Request withdrawal'}
        </ActionButton>
      </div>
    </Card>
  )
}
