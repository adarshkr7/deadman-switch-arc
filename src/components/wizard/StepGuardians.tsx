import { Plus, Trash2 } from 'lucide-react'
import { LIMITS } from '@/lib/vault'
import { nextRowId } from '@/lib/wizard'
import { Button, Notice, TextField } from '@/components/ui'
import type { StepProps } from '@/components/wizard/types'

export function StepGuardians({ state, update, errors }: StepProps) {
  const guardians = state.guardians
  const n = guardians.length

  return (
    <div className="flex flex-col gap-5">
      <div>
        <p className="text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          Guardians are optional trusted people who vote together. They can extend the deadline once per check-in, cancel a pending
          withdrawal, or propose a new owner if you lose your key. They can never move funds or trigger the vault early.
        </p>
        <ul className="mt-3 flex flex-col gap-2">
          {guardians.map((g, i) => (
            <li key={g.id} className="glass-inner flex items-center gap-2 rounded-2xl p-2">
              <input
                aria-label={`Guardian ${i + 1} wallet address`}
                value={g.address}
                onChange={(e) => update({ guardians: guardians.map((x) => (x.id === g.id ? { ...x, address: e.target.value } : x)) })}
                placeholder="0x… guardian address"
                spellCheck={false}
                className="mono input-base min-h-11 min-w-0 flex-1 rounded-xl px-3 text-sm outline-none"
              />
              <button
                type="button"
                aria-label={`Remove guardian ${i + 1}`}
                onClick={() => update({ guardians: guardians.filter((x) => x.id !== g.id) })}
                className="flex size-11 shrink-0 items-center justify-center rounded-xl"
                style={{ color: 'var(--subtle)' }}
              >
                <Trash2 className="size-4" aria-hidden />
              </button>
            </li>
          ))}
        </ul>
        <div className="mt-3">
          <Button
            variant="ghost"
            type="button"
            disabled={n >= LIMITS.maxGuardians}
            onClick={() => update({ guardians: [...guardians, { id: nextRowId(), address: '' }] })}
          >
            <Plus className="size-4" aria-hidden /> Add guardian
          </Button>
        </div>
        {n > 0 && (
          <div className="mt-4 glass-inner rounded-2xl p-4">
            <label className="flex items-center justify-between gap-3">
              <span className="text-sm font-semibold">Approvals needed</span>
              <span className="flex items-center gap-2">
                <select
                  aria-label="Approvals needed"
                  value={state.threshold}
                  onChange={(e) => update({ threshold: e.target.value })}
                  className="input-base min-h-11 rounded-xl px-3 text-sm tabular-nums"
                >
                  {Array.from({ length: n }, (_, i) => i + 1).map((k) => (
                    <option key={k} value={String(k)}>
                      {k}
                    </option>
                  ))}
                </select>
                <span className="text-sm" style={{ color: 'var(--muted)' }}>
                  of {n}
                </span>
              </span>
            </label>
          </div>
        )}
      </div>

      <div>
        <TextField
          label="Fallback address for unclaimed funds"
          hint="If beneficiaries never claim, anyone can sweep what is left to this address after the sweep period. It is fixed at creation."
          value={state.fallback}
          onChange={(e) => update({ fallback: e.target.value })}
          placeholder="0x…"
          spellCheck={false}
          className="mono"
        />
      </div>
      {errors.guardians[0] && <Notice tone="warn">{errors.guardians[0]}</Notice>}
    </div>
  )
}
