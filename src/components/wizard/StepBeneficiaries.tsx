import { Plus, Trash2 } from 'lucide-react'
import { useAccount } from 'wagmi'
import { LIMITS } from '@/lib/vault'
import { nextRowId } from '@/lib/wizard'
import { Button, Notice } from '@/components/ui'
import type { StepProps } from '@/components/wizard/types'

export function StepBeneficiaries({ state, update, errors }: StepProps) {
  const { address } = useAccount()
  const rows = state.beneficiaries

  function setAddress(id: number, value: string) {
    update({ beneficiaries: rows.map((r) => (r.id === id ? { ...r, address: value } : r)) })
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-pretty" style={{ color: 'var(--muted)' }}>
        Who should receive the USDC if you stop checking in? Beneficiaries are fixed at creation and cannot be changed later.
      </p>
      <ul className="flex flex-col gap-2">
        {rows.map((row, i) => (
          <li key={row.id} className="glass-inner flex items-center gap-2 rounded-2xl p-2">
            <input
              aria-label={`Beneficiary ${i + 1} wallet address`}
              value={row.address}
              onChange={(e) => setAddress(row.id, e.target.value)}
              placeholder="0x… wallet address"
              spellCheck={false}
              className="mono input-base min-h-11 min-w-0 flex-1 rounded-xl px-3 text-sm outline-none"
            />
            <button
              type="button"
              aria-label={`Remove beneficiary ${i + 1}`}
              disabled={rows.length === 1}
              onClick={() => update({ beneficiaries: rows.filter((r) => r.id !== row.id) })}
              className="flex size-11 shrink-0 items-center justify-center rounded-xl disabled:opacity-30"
              style={{ color: 'var(--subtle)' }}
            >
              <Trash2 className="size-4" aria-hidden />
            </button>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Button
          variant="ghost"
          type="button"
          disabled={rows.length >= LIMITS.maxBeneficiaries}
          onClick={() => update({ beneficiaries: [...rows, { id: nextRowId(), address: '', percent: '0' }] })}
        >
          <Plus className="size-4" aria-hidden /> Add beneficiary
        </Button>
        {address && !rows.some((r) => r.address.toLowerCase() === address.toLowerCase()) && (
          <Button
            variant="ghost"
            type="button"
            onClick={() => {
              const empty = rows.find((r) => r.address.trim() === '')
              if (empty) setAddress(empty.id, address)
              else update({ beneficiaries: [...rows, { id: nextRowId(), address, percent: '0' }] })
            }}
          >
            Use my wallet
          </Button>
        )}
      </div>
      <p className="text-xs" style={{ color: 'var(--subtle)' }}>
        {rows.length} of {LIMITS.maxBeneficiaries} beneficiaries
      </p>
      {errors.beneficiaries[0] && <Notice tone="warn">{errors.beneficiaries[0]}</Notice>}
    </div>
  )
}
