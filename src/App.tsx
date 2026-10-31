import { useEffect, useState } from 'react'
import { useAccount, useSwitchChain } from 'wagmi'
import { ConnectKitButton } from 'connectkit'
import { BookOpen, ExternalLink, Moon, Skull, Sun } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID, CHAIN_NAME, VAULT_ADDRESS } from '@/lib/vault'
import { PrefsProvider, usePrefs } from '@/hooks/usePrefs'
import { TxLogProvider } from '@/hooks/useTxLog'
import { ConfirmProvider } from '@/components/Confirm'
import { CreateWizard } from '@/components/wizard/CreateWizard'
import { VaultPicker } from '@/components/VaultPicker'
import { Docs } from '@/components/Docs'
import { VaultPage } from '@/components/vault/VaultPage'
import type { VaultTab } from '@/components/vault/VaultPage'
import { TxLog } from '@/components/TxLog'
import { Button, Notice } from '@/components/ui'

type Home = 'create' | 'mine' | 'docs'

const HOME_TABS: { id: Home; label: string }[] = [
  { id: 'create', label: 'Create' },
  { id: 'mine', label: 'My vaults' },
]
const VAULT_TABS: VaultTab[] = ['overview', 'guardians', 'delegate', 'details']

function readInitial(): { home: Home; vaultId?: bigint; tab: VaultTab } {
  const params = new URLSearchParams(window.location.search)
  const id = params.get('vault')
  const tab = params.get('tab')
  return {
    home: params.get('view') === 'mine' ? 'mine' : params.get('view') === 'docs' ? 'docs' : 'create',
    vaultId: id && /^[1-9]\d{0,17}$/.test(id) ? BigInt(id) : undefined,
    tab: VAULT_TABS.find((t) => t === tab) ?? 'overview',
  }
}

function Shell() {
  const initial = readInitial()
  const [home, setHome] = useState<Home>(initial.home)
  const [vaultId, setVaultId] = useState<bigint | undefined>(initial.vaultId)
  const [tab, setTab] = useState<VaultTab>(initial.tab)
  const { isConnected, chainId } = useAccount()
  const { switchChain, isPending: switching } = useSwitchChain()
  const { theme, toggleTheme, demo, setDemo } = usePrefs()

  // Keep the address bar shareable: /?vault=3&tab=guardians
  useEffect(() => {
    const params = new URLSearchParams()
    if (vaultId !== undefined) {
      params.set('vault', vaultId.toString())
      if (tab !== 'overview') params.set('tab', tab)
    } else if (home !== 'create') {
      params.set('view', home)
    }
    const query = params.toString()
    window.history.replaceState(null, '', query ? `/?${query}` : '/')
  }, [home, vaultId, tab])

  const open = (id: bigint) => {
    setVaultId(id)
    setTab('overview')
    window.scrollTo({ top: 0 })
  }
  const wrongChain = isConnected && chainId !== CHAIN_ID

  return (
    <div className="mx-auto min-h-dvh w-full max-w-4xl px-4 pb-24 pt-5">
      <header className="mb-6 flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2.5">
          <div className="flex size-10 shrink-0 items-center justify-center rounded-full" style={{ background: '#1c1c1e', color: 'var(--accent)' }}>
            <Skull className="size-5" aria-hidden />
          </div>
          <div className="min-w-0 leading-tight">
            <div className="display truncate text-lg font-bold">Dead-Man's Switch</div>
            <div className="truncate text-[11px] font-medium" style={{ color: 'var(--subtle)' }}>
              USDC vaults on {CHAIN_NAME}
            </div>
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <nav aria-label="Site">
            <button
              onClick={() => {
                setVaultId(undefined)
                setHome('docs')
                window.scrollTo({ top: 0 })
              }}
              aria-current={home === 'docs' && vaultId === undefined ? 'page' : undefined}
              className="glass-card flex min-h-11 items-center gap-2 rounded-full px-4 text-xs font-semibold transition-transform hover:scale-105"
              style={home === 'docs' && vaultId === undefined ? { background: 'var(--accent)', color: 'var(--on-accent)' } : undefined}
            >
              <BookOpen className="size-4" aria-hidden />
              Docs
            </button>
          </nav>
          <label
            className="glass-card hidden min-h-11 cursor-pointer items-center gap-2 rounded-full px-4 text-xs font-semibold sm:flex"
            title={demo ? 'New vaults use 60-second-scale windows' : 'New vaults use real-world windows'}
          >
            <input type="checkbox" role="switch" aria-label="Demo mode" checked={demo} onChange={(e) => setDemo(e.target.checked)} className="size-4 accent-[var(--accent)]" />
            Demo mode
          </label>
          <button
            onClick={toggleTheme}
            aria-label={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
            className="glass-card flex size-11 items-center justify-center rounded-full transition-transform hover:scale-105"
          >
            {theme === 'dark' ? <Sun className="size-4" aria-hidden /> : <Moon className="size-4" aria-hidden />}
          </button>
          <ConnectKitButton showAvatar={false} />
        </div>
      </header>


      <label className="glass-card mb-5 flex min-h-11 w-fit cursor-pointer items-center gap-2 rounded-full px-4 text-xs font-semibold sm:hidden">
        <input type="checkbox" role="switch" aria-label="Demo mode" checked={demo} onChange={(e) => setDemo(e.target.checked)} className="size-4 accent-[var(--accent)]" />
        Demo mode {demo ? 'on: 60-second windows' : 'off'}
      </label>

      {!VAULT_ADDRESS ? (
        <Notice tone="danger">The vault contract address is not configured. Set VITE_VAULT_ADDRESS in .env and restart the dev server.</Notice>
      ) : (
        <>
          {wrongChain && (
            <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-2xl px-4 py-3" style={{ background: 'var(--warn-bg)' }}>
              <span className="text-sm font-medium" style={{ color: 'var(--warn)' }}>
                Your wallet is on another network.
              </span>
              <Button variant="ghost" busy={switching} onClick={() => switchChain({ chainId: CHAIN_ID })}>
                Switch to {CHAIN_NAME}
              </Button>
            </div>
          )}

          {vaultId === undefined && (
            <nav className="glass-card mb-5 inline-flex rounded-full p-1" aria-label="Views">
              {HOME_TABS.map((t) => (
                <button
                  key={t.id}
                  onClick={() => setHome(t.id)}
                  aria-current={home === t.id ? 'page' : undefined}
                  className="min-h-10 rounded-full px-6 text-sm font-semibold transition-colors"
                  style={home === t.id ? { background: 'var(--accent)', color: 'var(--on-accent)' } : { color: 'var(--muted)' }}
                >
                  {t.label}
                </button>
              ))}
            </nav>
          )}

          <main className="flex flex-col gap-5">
            {vaultId !== undefined ? (
              <VaultPage vaultId={vaultId} tab={tab} onTab={setTab} onBack={() => setVaultId(undefined)} />
            ) : home === 'create' ? (
              <CreateWizard onCreated={open} />
            ) : home === 'docs' ? (
              <Docs />
            ) : (
              <VaultPicker onSelect={open} />
            )}
            <TxLog />
          </main>

          <footer className="mt-6 text-center text-xs" style={{ color: 'var(--subtle)' }}>
            Contract{' '}
            <a
              href={buildAddressExplorerUrl(CHAIN_ID, VAULT_ADDRESS)}
              target="_blank"
              rel="noopener noreferrer"
              className="mono inline-flex items-center gap-1 hover:underline"
            >
              {VAULT_ADDRESS.slice(0, 8)}…{VAULT_ADDRESS.slice(-6)}
              <ExternalLink className="size-3" aria-hidden />
            </a>
            . No admin keys, no upgrades.
          </footer>
        </>
      )}
    </div>
  )
}

export default function App() {
  return (
    <PrefsProvider>
      <TxLogProvider>
        <ConfirmProvider>
          <Shell />
        </ConfirmProvider>
      </TxLogProvider>
    </PrefsProvider>
  )
}
