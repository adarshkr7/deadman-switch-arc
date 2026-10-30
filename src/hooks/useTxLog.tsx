import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'

export type TxStatus = 'wallet' | 'pending' | 'success' | 'failed'

export interface TxEntry {
  id: string
  label: string
  status: TxStatus
  hash?: `0x${string}`
  error?: string
  at: number
}

interface TxLogValue {
  entries: TxEntry[]
  add: (entry: TxEntry) => void
  update: (id: string, patch: Partial<TxEntry>) => void
  remove: (id: string) => void
  clear: () => void
}

const STORAGE_KEY = 'vault-tx-log-v1'
const MAX_ENTRIES = 30

const TxLogContext = createContext<TxLogValue | null>(null)

function load(): TxEntry[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    // An entry without a hash never reached the network, so it cannot be resumed after a reload.
    return (parsed as TxEntry[]).filter((e) => e.hash)
  } catch {
    return []
  }
}

export function TxLogProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<TxEntry[]>(load)

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(entries.slice(0, MAX_ENTRIES)))
    } catch {
      // storage unavailable: the in-memory log still works
    }
  }, [entries])

  const add = useCallback((entry: TxEntry) => setEntries((prev) => [entry, ...prev].slice(0, MAX_ENTRIES)), [])
  const update = useCallback(
    (id: string, patch: Partial<TxEntry>) => setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, ...patch } : e))),
    [],
  )
  const remove = useCallback((id: string) => setEntries((prev) => prev.filter((e) => e.id !== id)), [])
  const clear = useCallback(() => setEntries([]), [])

  const value = useMemo(() => ({ entries, add, update, remove, clear }), [entries, add, update, remove, clear])
  return <TxLogContext.Provider value={value}>{children}</TxLogContext.Provider>
}

export function useTxLog(): TxLogValue {
  const ctx = useContext(TxLogContext)
  if (!ctx) throw new Error('useTxLog must be used inside TxLogProvider')
  return ctx
}
