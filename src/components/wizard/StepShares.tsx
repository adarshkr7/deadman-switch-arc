import { bpsToPercent, shortAddress } from '@/lib/format'
import { Notice } from '@/components/ui'
import type { StepProps } from '@/components/wizard/types'

export function StepShares({ state, update, errors }: StepProps) {
  const rows = state.beneficiaries
  const total = errors.totalBps
  const exact = total === 10000
  const over = total > 10000

  function splitEvenly() {
    const n = rows.length
    const base = Math.floor(10000 / n)
    const remainder = 10000 - base * n
    update({ beneficiaries: rows.map((r, i) => ({ ...r, percent: bpsToPercent(base + (i === n - 1 ? remainder : 0)) })) })
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-start justify-between gap-3">
        <p className="text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          Set each beneficiary's percentage. The shares must total exactly 100%.
        </p>
        <button type="button" onClick={splitEvenly} className="shrink-0 text-xs font-semibold" style={{ color: 'var(--accent-hover)' }}>
          Split evenly
        </button>
      </div>

      <div className="glass-inner rounded-2xl p-4" aria-live="polite">
        <div className="flex items-baseline justify-between">
          <span className="text-xs font-semibold" style={{ color: 'var(--muted)' }}>
            Total
          </span>
          <span
            className="display text-3xl font-bold tabular-nums"
            style={{ color: exact ? 'var(--success)' : over ? 'var(--danger)' : 'var(--ink)' }}
          >
            {bpsToPercent(total)}%
          </span>
        </div>
        <div className="mt-2 h-2 overflow-hidden rounded-full" style={{ background: 'var(--track)' }}>
          <div
            className="h-full rounded-full transition-[width] duration-200"
            style={{ width: `${Math.min(100, total / 100)}%`, background: exact ? 'var(--success)' : over ? 'var(--danger)' : 'var(--accent)' }}
          />
        </div>
        <p className="mt-2 text-xs" style={{ color: exact ? 'var(--success)' : 'var(--muted)' }}>
          {exact ? 'Perfect, that adds up to 100%.' : over ? `${bpsToPercent(total - 10000)}% too much.` : `${bpsToPercent(10000 - total)}% left to assign.`}
        </p>
      </div>

      <ul className="flex flex-col gap-2">
        {rows.map((row, i) => (
          <li key={row.id} className="glass-inner flex items-center justify-between gap-3 rounded-2xl p-3">
            <span className="mono min-w-0 truncate text-sm" title={row.address}>
              {row.address ? shortAddress(row.address) : `Beneficiary ${i + 1}`}
            </span>
            <div className="input-base flex min-h-11 w-28 shrink-0 items-center rounded-xl px-3">
              <input
                aria-label={`Share for beneficiary ${i + 1} in percent`}
                inputMode="decimal"
                value={row.percent}
                onChange={(e) =>
                  update({ beneficiaries: rows.map((r) => (r.id === row.id ? { ...r, percent: e.target.value } : r)) })
                }
                className="w-full min-w-0 bg-transparent text-right text-sm tabular-nums outline-none"
              />
              <span className="ml-1 text-sm" style={{ color: 'var(--subtle)' }}>
                %
              </span>
            </div>
          </li>
        ))}
      </ul>
      {errors.shares[0] && <Notice tone="warn">{errors.shares[0]}</Notice>}
    </div>
  )
}
