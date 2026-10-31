interface GaugeProps {
  /** 0..1, how much of the arc is filled. */
  value: number
  /** Big number in the middle; defaults to the value as a percentage. */
  display?: string
  label: string
  color?: string
}

const CX = 100
const CY = 100
const R = 78

function point(theta: number, r: number) {
  return { x: CX + r * Math.cos(theta), y: CY - r * Math.sin(theta) }
}

/** Half-circle gauge: a solid arc for the value and tick marks for the rest. */
export function Gauge({ value, display, label, color = 'var(--accent)' }: GaugeProps) {
  const v = Math.min(1, Math.max(0, value))
  const end = Math.PI * (1 - v)
  const start = point(Math.PI, R)
  const stop = point(end, R)
  const ticks: number[] = []
  for (let deg = Math.floor((end * 180) / Math.PI) - 7; deg >= 0; deg -= 7) ticks.push((deg * Math.PI) / 180)

  return (
    <div className="relative mx-auto w-full max-w-[220px]" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(v * 100)} aria-label={label}>
      <svg viewBox="0 0 200 112" className="w-full" aria-hidden>
        {v > 0.002 && (
          <path
            d={`M ${start.x} ${start.y} A ${R} ${R} 0 0 1 ${stop.x} ${stop.y}`}
            fill="none"
            stroke={color}
            strokeWidth={20}
            className="transition-all duration-500"
          />
        )}
        {ticks.map((t) => {
          const a = point(t, R - 8)
          const b = point(t, R + 9)
          return <line key={t} x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke="rgba(255,255,255,0.55)" strokeWidth={2} strokeLinecap="round" />
        })}
      </svg>
      <div className="absolute inset-x-0 bottom-0 flex flex-col items-center">
        <span className="display text-4xl font-bold tabular-nums leading-none">{display ?? Math.round(v * 100)}</span>
        <span className="mt-1 text-[11px] font-medium" style={{ color: 'var(--muted)' }}>
          {label}
        </span>
      </div>
    </div>
  )
}
