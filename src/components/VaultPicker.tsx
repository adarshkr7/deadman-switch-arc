import { useState } from 'react'
import { useAccount } from 'wagmi'
import { ChevronRight } from 'lucide-react'
import { ConnectKitButton } from 'connectkit'
import { formatUsdc } from '@/onchain-money'
import { deriveState, isDemoVault, roleLabels } from '@/lib/phase'
import type { UiState } from '@/lib/phase'
import { useChainNow } from '@/hooks/useChainNow'
import { useMyVaults } from '@/hooks/useVaultData'
import { Button, Card, Notice, SectionLabel, StatusChip } from '@/components/ui'
import type { Tone } from '@/components/ui'

const TONE: Record<UiState, Tone> = { active: 'success', warning: 'danger', challenge: 'warn', triggered: 'neutral', swept: 'neutral' }
const LABEL: Record<UiState, string> = { active: 'Active', warning: 'Warning', challenge: 'Challenge', triggered: 'Triggered', swept: 'Swept' }

/** The wallet's vaults, plus an "open by ID" box that works for any visitor. */
export function VaultPicker({ onSelect }: { onSelect: (id: bigint) => void }) {
  const { isConnected } = useAccount()
  const { data: items, isLoading, isError } = useMyVaults()
  const now = useChainNow()
  const [manualId, setManualId] = useState('')
  const manualValid = /^[1-9]\d{0,17}$/.test(manualId)

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <h2 className="display text-3xl font-bold text-balance">Your vaults</h2>
        <p className="mt-2 max-w-[60ch] text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          Vaults where this wallet is the owner, delegate, guardian, beneficiary or fallback address.
        </p>
        <div className="mt-5">
          {!isConnected ? (
            <ConnectKitButton.Custom>{({ show }) => <Button onClick={show}>Connect wallet to list your vaults</Button>}</ConnectKitButton.Custom>
          ) : isLoading ? (
            <div className="h-16 animate-pulse rounded-2xl" style={{ background: 'var(--track)' }} aria-busy="true" />
          ) : isError ? (
            <Notice tone="danger">Could not load your vaults. Open one by ID below.</Notice>
          ) : !items || items.length === 0 ? (
            <p className="text-sm" style={{ color: 'var(--muted)' }}>
              No vaults found for this wallet. Create one, or open a vault by its ID below.
            </p>
          ) : (
            <ul className="flex flex-col gap-2">
              {items.map(({ vault, roles }) => {
                const d = deriveState(vault, now)
                return (
                  <li key={vault.id.toString()}>
                    <button
                      onClick={() => onSelect(vault.id)}
                      className="glass-inner hover-surface flex min-h-16 w-full items-center justify-between gap-3 rounded-2xl px-4 py-3 text-left transition-colors"
                    >
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="display text-lg font-bold">Vault #{vault.id.toString()}</span>
                          <StatusChip tone={TONE[d.state]}>{LABEL[d.state]}</StatusChip>
                          {isDemoVault(vault) && <StatusChip tone="warn">Demo</StatusChip>}
                        </div>
                        <div className="mt-0.5 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
                          {formatUsdc(vault.triggered ? vault.claimPool || vault.balance : vault.balance)} USDC · {roleLabels(roles).join(', ')}
                        </div>
                      </div>
                      <ChevronRight className="size-4 shrink-0" style={{ color: 'var(--subtle)' }} aria-hidden />
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>
      </Card>

      <Card>
        <SectionLabel>Open any vault by ID</SectionLabel>
        <p className="mt-2 text-xs" style={{ color: 'var(--subtle)' }}>
          Vault pages are public and read-only until you connect a wallet that has a role in the vault.
        </p>
        <form
          className="mt-3 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault()
            if (manualValid) onSelect(BigInt(manualId))
          }}
        >
          <input
            aria-label="Vault ID"
            inputMode="numeric"
            value={manualId}
            onChange={(e) => setManualId(e.target.value.replace(/\D/g, ''))}
            placeholder="e.g. 1"
            className="input-base min-h-11 min-w-0 flex-1 rounded-xl px-3 text-sm tabular-nums outline-none"
          />
          <Button type="submit" disabled={!manualValid}>
            Open
          </Button>
        </form>
      </Card>
    </div>
  )
}
