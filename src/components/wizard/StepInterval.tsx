import { DEFAULTS } from '@/lib/vault'
import { formatDuration } from '@/lib/format'
import { DEMO_PRESETS, DEMO_WINDOWS, NORMAL_PRESETS } from '@/lib/wizard'
import type { DurationInput, Unit } from '@/lib/wizard'
import { Notice } from '@/components/ui'
import type { StepProps } from '@/components/wizard/types'

const UNITS: Unit[] = ['seconds', 'minutes', 'hours', 'days']

function DurationField({ label, value, onChange }: { label: string; value: DurationInput; onChange: (v: DurationInput) => void }) {
  return (
    <div>
      <span className="mb-1 block text-xs font-semibold" style={{ color: 'var(--muted)' }}>
        {label}
      </span>
      <div className="flex gap-2">
        <input
          aria-label={`${label} length`}
          inputMode="numeric"
          value={value.amount}
          onChange={(e) => onChange({ ...value, amount: e.target.value.replace(/\D/g, '') })}
          className="input-base min-h-11 w-24 rounded-xl px-3 text-sm tabular-nums outline-none"
        />
        <select
          aria-label={`${label} unit`}
          value={value.unit}
          onChange={(e) => onChange({ ...value, unit: e.target.value as Unit })}
          className="input-base min-h-11 flex-1 rounded-xl px-3 text-sm"
        >
          {UNITS.map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </select>
      </div>
    </div>
  )
}

export function StepInterval({ state, update, errors, demo }: StepProps) {
  const presets = demo ? DEMO_PRESETS : NORMAL_PRESETS

  return (
    <div className="flex flex-col gap-5">
      {demo && (
        <Notice tone="warn">
          Demo mode is on. This vault will use very short windows (60 seconds for withdrawals, challenge and rotation) so you can watch every
          state change in minutes. Do not use it to protect real funds.
        </Notice>
      )}
      <div>
        <p className="mb-3 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          How often will you check in? If you miss the deadline, the vault can be triggered.
        </p>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          {presets.map((p) => {
            const selected = state.preset === p.id
            return (
              <button
                key={p.id}
                type="button"
                aria-pressed={selected}
                onClick={() => {
                  const minutes = p.seconds < 3600
                  update({
                    preset: p.id,
                    interval: minutes ? { amount: String(p.seconds / 60), unit: 'minutes' } : { amount: String(p.seconds / 86400), unit: 'days' },
                  })
                }}
                className="glass-inner min-h-16 rounded-2xl p-3 text-left"
                style={selected ? { borderColor: 'var(--accent)', boxShadow: '0 0 0 1px var(--accent)' } : undefined}
              >
                <span className="display block text-lg font-bold">{p.label}</span>
                <span className="text-xs" style={{ color: 'var(--muted)' }}>
                  {p.hint}
                </span>
              </button>
            )
          })}
          <button
            type="button"
            aria-pressed={state.preset === 'custom'}
            onClick={() => update({ preset: 'custom' })}
            className="glass-inner min-h-16 rounded-2xl p-3 text-left"
            style={state.preset === 'custom' ? { borderColor: 'var(--accent)', boxShadow: '0 0 0 1px var(--accent)' } : undefined}
          >
            <span className="display block text-lg font-bold">Custom</span>
            <span className="text-xs" style={{ color: 'var(--muted)' }}>
              From 60 seconds
            </span>
          </button>
        </div>
        {state.preset === 'custom' && (
          <div className="mt-3">
            <DurationField label="Check-in window" value={state.interval} onChange={(interval) => update({ interval })} />
          </div>
        )}
      </div>

      <div>
        <h3 className="text-sm font-semibold">Safety windows</h3>
        {demo ? (
          <ul className="mt-2 grid gap-1 text-sm" style={{ color: 'var(--muted)' }}>
            <li>Withdrawal delay: {formatDuration(DEMO_WINDOWS.withdrawDelay)}</li>
            <li>Challenge window: {formatDuration(DEMO_WINDOWS.challengeWindow)}</li>
            <li>Rotation timelock: {formatDuration(DEMO_WINDOWS.rotationTimelock)}</li>
            <li>Sweep period: {formatDuration(DEMO_WINDOWS.sweepPeriod)}</li>
          </ul>
        ) : (
          <>
            <div className="mt-2 flex gap-2" role="group" aria-label="Safety window mode">
              {(['standard', 'custom'] as const).map((m) => (
                <button
                  key={m}
                  type="button"
                  aria-pressed={state.windowsMode === m}
                  onClick={() => update({ windowsMode: m })}
                  className="glass-inner min-h-10 rounded-full px-4 text-xs font-semibold capitalize"
                  style={state.windowsMode === m ? { borderColor: 'var(--accent)', boxShadow: '0 0 0 1px var(--accent)' } : undefined}
                >
                  {m === 'standard' ? 'Recommended' : 'Custom'}
                </button>
              ))}
            </div>
            {state.windowsMode === 'standard' ? (
              <ul className="mt-2 grid gap-1 text-sm" style={{ color: 'var(--muted)' }}>
                <li>Withdrawal delay: {formatDuration(DEFAULTS.withdrawDelay)}</li>
                <li>Challenge window: {formatDuration(DEFAULTS.challengeWindow)}</li>
                <li>Rotation timelock: {formatDuration(DEFAULTS.rotationTimelock)}</li>
                <li>Sweep period: {formatDuration(DEFAULTS.sweepPeriod)}</li>
              </ul>
            ) : (
              <div className="mt-3 grid gap-3 sm:grid-cols-2">
                <DurationField label="Withdrawal delay" value={state.withdrawDelay} onChange={(withdrawDelay) => update({ withdrawDelay })} />
                <DurationField label="Challenge window" value={state.challengeWindow} onChange={(challengeWindow) => update({ challengeWindow })} />
                <DurationField label="Rotation timelock" value={state.rotationTimelock} onChange={(rotationTimelock) => update({ rotationTimelock })} />
                <DurationField label="Sweep period" value={state.sweepPeriod} onChange={(sweepPeriod) => update({ sweepPeriod })} />
              </div>
            )}
          </>
        )}
      </div>
      {errors.interval[0] && <Notice tone="warn">{errors.interval[0]}</Notice>}
    </div>
  )
}
