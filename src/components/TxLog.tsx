import { useEffect, useRef } from 'react'
import { usePublicClient } from 'wagmi'
import { CheckCircle2, ExternalLink, Loader2, Receipt, XCircle } from 'lucide-react'
import { buildTxExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/lib/vault'
import { shortHash } from '@/lib/format'
import { useTxLog } from '@/hooks/useTxLog'
import type { TxEntry } from '@/hooks/useTxLog'
import { Card, SectionLabel } from '@/components/ui'

function StatusIcon({ status }: { status: TxEntry['status'] }) {
  if (status === 'success') return <CheckCircle2 className="size-4 shrink-0" style={{ color: 'var(--success)' }} aria-label="Confirmed" />
  if (status === 'failed') return <XCircle className="size-4 shrink-0" style={{ color: 'var(--danger)' }} aria-label="Failed" />
  return <Loader2 className="size-4 shrink-0 animate-spin" style={{ color: 'var(--accent-hover)' }} aria-label="In progress" />
}

const STATUS_TEXT: Record<TxEntry['status'], string> = {
  wallet: 'Confirm in your wallet…',
  pending: 'Waiting for confirmation…',
  success: 'Confirmed',
  failed: 'Failed',
}

export function TxLog() {
  const { entries, update, clear } = useTxLog()
  const client = usePublicClient({ chainId: CHAIN_ID })

  // A hash saved before a reload may still be unresolved: settle it from the chain.
  const checked = useRef(false)
  useEffect(() => {
    if (!client || checked.current) return
    checked.current = true
    entries
      .filter((e) => e.status === 'pending' && e.hash)
      .forEach((e) => {
        const hash = e.hash
        if (!hash) return
        client
          .getTransactionReceipt({ hash })
          .then((r) => update(e.id, r.status === 'success' ? { status: 'success' } : { status: 'failed', error: 'The transaction reverted.' }))
          .catch(() => undefined)
      })
  }, [client, entries, update])

  return (
    <Card>
      <div className="mb-3 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Receipt className="size-4" style={{ color: 'var(--subtle)' }} aria-hidden />
          <SectionLabel>Transactions</SectionLabel>
        </div>
        {entries.length > 0 && (
          <button onClick={clear} className="text-xs font-semibold" style={{ color: 'var(--subtle)' }}>
            Clear
          </button>
        )}
      </div>

      {entries.length === 0 ? (
        <p className="text-sm" style={{ color: 'var(--muted)' }}>
          Every transaction you send shows up here with its hash and an explorer link.
        </p>
      ) : (
        <ul className="flex flex-col gap-2">
          {entries.map((e) => (
            <li key={e.id} className="glass-inner flex items-start gap-3 rounded-2xl px-4 py-3">
              <div className="pt-0.5">
                <StatusIcon status={e.status} />
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-baseline justify-between gap-x-3">
                  <span className="text-sm font-semibold">{e.label}</span>
                  <span className="text-xs" style={{ color: e.status === 'failed' ? 'var(--danger)' : 'var(--muted)' }}>
                    {STATUS_TEXT[e.status]}
                  </span>
                </div>
                {e.hash && (
                  <a
                    href={buildTxExplorerUrl(CHAIN_ID, e.hash)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="mono mt-1 inline-flex items-center gap-1 text-xs hover:underline"
                    style={{ color: 'var(--accent-hover)' }}
                    title={e.hash}
                  >
                    {shortHash(e.hash)}
                    <ExternalLink className="size-3" aria-hidden />
                    <span className="sr-only">View transaction on the explorer</span>
                  </a>
                )}
                {e.error && (
                  <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--danger)' }}>
                    {e.error}
                  </p>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
