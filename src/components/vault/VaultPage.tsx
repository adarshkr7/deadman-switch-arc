import { useMemo } from 'react'
import { useAccount } from 'wagmi'
import { ArrowLeft } from 'lucide-react'
import { deriveRoles, deriveState, isDemoVault } from '@/lib/phase'
import { useChainNow } from '@/hooks/useChainNow'
import { useVault } from '@/hooks/useVaultData'
import { useVaultLogs } from '@/hooks/useVaultLogs'
import { useGuardianVotes } from '@/hooks/useGuardianVotes'
import { useTxLog } from '@/hooks/useTxLog'
import { Button, Card, Notice, StatusChip } from '@/components/ui'
import { ShareVaultLink } from '@/components/ShareVaultLink'
import { RotationAlert } from '@/components/vault/RotationAlert'
import { StatusHero } from '@/components/vault/StatusHero'
import { PendingActions } from '@/components/vault/PendingActions'
import { FundsCard } from '@/components/vault/FundsCard'
import { BeneficiaryList } from '@/components/vault/BeneficiaryList'
import { GuardiansPanel } from '@/components/vault/GuardiansPanel'
import { DelegatePanel } from '@/components/vault/DelegatePanel'
import { DetailsPanel } from '@/components/vault/DetailsPanel'
import type { VaultCtx } from '@/components/vault/ctx'

export type VaultTab = VaultCtx['goTab'] extends (t: infer T) => void ? T : never

const TABS: { id: VaultTab; label: string }[] = [
  { id: 'overview', label: 'Overview' },
  { id: 'guardians', label: 'Guardians' },
  { id: 'delegate', label: 'Delegate' },
  { id: 'details', label: 'Details' },
]

interface VaultPageProps {
  vaultId: bigint
  tab: VaultTab
  onTab: (tab: VaultTab) => void
  onBack: () => void
}

/** The public vault page. Every read works without a wallet; actions depend on the connected wallet's role. */
export function VaultPage({ vaultId, tab, onTab, onBack }: VaultPageProps) {
  const { address } = useAccount()
  const { vault, notFound, isLoading, isError } = useVault(vaultId)
  const now = useChainNow()
  const logs = useVaultLogs(vaultId)
  const events = useMemo(() => logs.data?.events ?? [], [logs.data])
  const { data: proposals = [] } = useGuardianVotes(vault, events)
  const { entries } = useTxLog()
  const txBusy = entries.some((e) => e.status === 'wallet' || e.status === 'pending')

  const back = (
    <button onClick={onBack} className="inline-flex min-h-11 items-center gap-1.5 self-start text-sm font-semibold" style={{ color: 'var(--muted)' }}>
      <ArrowLeft className="size-4" aria-hidden /> All vaults
    </button>
  )

  if (notFound) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Card>
          <Notice tone="danger">Vault #{vaultId.toString()} does not exist.</Notice>
        </Card>
      </div>
    )
  }
  if (isError && !vault) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Card>
          <Notice tone="danger">Could not load this vault. Check your connection and try again.</Notice>
        </Card>
      </div>
    )
  }
  if (isLoading || !vault) {
    return (
      <div className="flex flex-col gap-4">
        {back}
        <Card>
          <div className="h-56 animate-pulse rounded-2xl" style={{ background: 'var(--track)' }} aria-busy="true" />
        </Card>
      </div>
    )
  }

  const derived = deriveState(vault, now)
  const roles = deriveRoles(address, vault)
  const ctx: VaultCtx = { vault, now, derived, roles, address, proposals, txBusy, goTab: onTab }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        {back}
        <div className="flex items-center gap-2">
          <h1 className="display text-lg font-bold">Vault #{vault.id.toString()}</h1>
          {isDemoVault(vault) && (
            <span className="glass-card rounded-full">
              <StatusChip tone="warn">Demo vault</StatusChip>
            </span>
          )}
        </div>
      </div>

      <RotationAlert ctx={ctx} />
      <StatusHero ctx={ctx} />

      <nav className="glass-card flex self-start overflow-x-auto rounded-full p-1" aria-label="Vault sections">
        {TABS.map((t) => (
          <button
            key={t.id}
            onClick={() => onTab(t.id)}
            aria-current={tab === t.id ? 'page' : undefined}
            className="min-h-10 shrink-0 rounded-full px-4 text-xs font-semibold transition-colors sm:px-6 sm:text-sm"
            style={tab === t.id ? { background: 'var(--accent)', color: 'var(--on-accent)' } : { color: 'var(--muted)' }}
          >
            {t.label}
          </button>
        ))}
      </nav>

      {tab === 'overview' && (
        <div className="grid items-start gap-5 lg:grid-cols-2">
          <div className="flex flex-col gap-5">
            <FundsCard ctx={ctx} />
          </div>
          <div className="flex flex-col gap-5">
            <PendingActions ctx={ctx} />
            <BeneficiaryList ctx={ctx} />
          </div>
          <Card className="lg:col-span-2">
            <ShareVaultLink vaultId={vault.id} />
            <p className="mt-2 text-center text-xs" style={{ color: 'var(--subtle)' }}>
              Anyone with the link can view this vault. Only connected wallets with a role can act.
            </p>
          </Card>
        </div>
      )}
      {tab === 'guardians' && <GuardiansPanel ctx={ctx} />}
      {tab === 'delegate' && <DelegatePanel ctx={ctx} />}
      {tab === 'details' && <DetailsPanel ctx={ctx} events={events} loadingEvents={logs.isLoading} />}
      <Button variant="ghost" onClick={() => window.scrollTo({ top: 0, behavior: 'smooth' })} className="self-center">
        Back to top
      </Button>
    </div>
  )
}
