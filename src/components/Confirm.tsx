import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { AlertTriangle } from 'lucide-react'

export interface ConfirmRequest {
  title: string
  /** One short plain-language line per fact the person is agreeing to. */
  lines: string[]
  /** Highlighted consequence, shown in red. */
  warning?: string
  confirmLabel: string
  danger?: boolean
}

type ConfirmFn = (request: ConfirmRequest) => Promise<boolean>

const ConfirmContext = createContext<ConfirmFn | null>(null)

interface Pending {
  request: ConfirmRequest
  resolve: (ok: boolean) => void
}

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [pending, setPending] = useState<Pending>()
  const cancelRef = useRef<HTMLButtonElement>(null)

  const confirm = useCallback<ConfirmFn>(
    (request) =>
      new Promise<boolean>((resolve) => {
        setPending({ request, resolve })
      }),
    [],
  )

  const close = useCallback(
    (ok: boolean) => {
      pending?.resolve(ok)
      setPending(undefined)
    },
    [pending],
  )

  useEffect(() => {
    if (!pending) return
    cancelRef.current?.focus()
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [pending, close])

  const value = useMemo(() => confirm, [confirm])
  const req = pending?.request

  return (
    <ConfirmContext.Provider value={value}>
      {children}
      {req && (
        <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center" role="presentation">
          <button
            type="button"
            aria-label="Close dialog"
            className="absolute inset-0 bg-black/40 backdrop-blur-sm"
            onClick={() => close(false)}
          />
          <div
            role="alertdialog"
            aria-modal="true"
            aria-labelledby="confirm-title"
            className="glass-card relative w-full max-w-md rounded-t-3xl p-5 sm:rounded-3xl"
            style={{ background: 'var(--surface-solid)' }}
          >
            <h2 id="confirm-title" className="display text-xl font-bold text-balance">
              {req.title}
            </h2>
            <ul className="mt-3 flex flex-col gap-1.5 text-sm" style={{ color: 'var(--ink-2)' }}>
              {req.lines.map((line) => (
                <li key={line} className="text-pretty">
                  {line}
                </li>
              ))}
            </ul>
            {req.warning && (
              <p
                className="mt-4 flex gap-2 rounded-2xl p-3 text-sm font-medium text-pretty"
                style={{ background: 'var(--danger-bg)', color: 'var(--danger)' }}
              >
                <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden />
                {req.warning}
              </p>
            )}
            <div className="mt-5 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <button
                ref={cancelRef}
                type="button"
                onClick={() => close(false)}
                className="min-h-11 rounded-2xl px-5 text-sm font-semibold"
                style={{ background: 'var(--surface-strong)', border: '1px solid var(--border)', color: 'var(--ink)' }}
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={() => close(true)}
                className="min-h-11 rounded-2xl px-5 text-sm font-semibold text-white"
                style={{ background: req.danger ? 'var(--danger)' : 'var(--accent)', color: 'var(--on-accent)' }}
              >
                {req.confirmLabel}
              </button>
            </div>
          </div>
        </div>
      )}
    </ConfirmContext.Provider>
  )
}

export function useConfirm(): ConfirmFn {
  const ctx = useContext(ConfirmContext)
  if (!ctx) throw new Error('useConfirm must be used inside ConfirmProvider')
  return ctx
}
