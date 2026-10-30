import { splitSeconds } from '@/lib/format'
import type { Tone } from '@/components/ui'
import { TONES } from '@/components/ui'

interface CountdownProps {
  /** Seconds left; undefined while chain time is loading. */
  remaining: number | undefined
  /** Length of the window, for the progress bar. */
  total: number
  label: string
  tone?: Tone
  /** Hide the progress bar (used when the window has no fixed length). */
  noBar?: boolean
}

function Tile({ value, unit }: { value: number; unit: string }) {
  return (
    <div className="glass-inner flex min-w-0 flex-1 flex-col items-center rounded-2xl py-3">
      <span className="display text-3xl font-bold tabular-nums sm:text-4xl">{String(value).padStart(2, '0')}</span>
      <span className="mt-1 text-[10px] font-semibold uppercase tracking-[0.1em]" style={{ color: 'var(--subtle)' }}>
        {unit}
      </span>
    </div>
  )
}

/** Live countdown driven by chain time. */
export function Countdown({ remaining, total, label, tone = 'neutral', noBar }: CountdownProps) {
  if (remaining === undefined) {
    return (
      <div aria-busy="true" className="flex gap-2">
        {['Days', 'Hours', 'Min', 'Sec'].map((u) => (
          <div key={u} className="glass-inner h-[76px] flex-1 animate-pulse rounded-2xl" />
        ))}
      </div>
    )
  }

  const { days, hours, minutes, seconds } = splitSeconds(remaining)
  const fraction = total > 0 ? Math.min(1, Math.max(0, remaining / total)) : 0
  const barColor = tone === 'neutral' ? 'var(--accent)' : TONES[tone].fg

  return (
    <div>
      <div className="mb-2 text-xs font-semibold" style={{ color: 'var(--muted)' }}>
        {label}
      </div>
      <div className="flex gap-2" role="timer" aria-label={`${days} days ${hours} hours ${minutes} minutes ${seconds} seconds`}>
        <Tile value={days} unit="Days" />
        <Tile value={hours} unit="Hours" />
        <Tile value={minutes} unit="Min" />
        <Tile value={seconds} unit="Sec" />
      </div>
      {!noBar && (
        <div className="mt-3 h-1.5 overflow-hidden rounded-full" style={{ background: 'var(--track)' }}>
          <div
            className="h-full rounded-full transition-[width] duration-300"
            style={{ width: `${fraction * 100}%`, background: barColor }}
          />
        </div>
      )}
    </div>
  )
}

/** Compact inline countdown text for list rows, e.g. "1h 04m 09s". */
export function InlineCountdown({ remaining }: { remaining: number | undefined }) {
  if (remaining === undefined) return <span className="tabular-nums">…</span>
  if (remaining <= 0) return <span className="tabular-nums">now</span>
  const { days, hours, minutes, seconds } = splitSeconds(remaining)
  const parts = days > 0 ? [`${days}d`, `${hours}h`, `${minutes}m`] : [hours > 0 ? `${hours}h` : '', `${String(minutes).padStart(2, '0')}m`, `${String(seconds).padStart(2, '0')}s`]
  return <span className="tabular-nums">{parts.filter(Boolean).join(' ')}</span>
}
