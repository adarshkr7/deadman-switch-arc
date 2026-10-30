export function shortAddress(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

export function shortHash(hash: string): string {
  return `${hash.slice(0, 10)}…${hash.slice(-6)}`
}

export interface Countdown {
  days: number
  hours: number
  minutes: number
  seconds: number
}

export function splitSeconds(total: number): Countdown {
  const t = Math.max(0, Math.floor(total))
  return {
    days: Math.floor(t / 86400),
    hours: Math.floor((t % 86400) / 3600),
    minutes: Math.floor((t % 3600) / 60),
    seconds: t % 60,
  }
}

export function formatDuration(totalSeconds: number): string {
  const { days, hours, minutes, seconds } = splitSeconds(totalSeconds)
  const parts: string[] = []
  if (days) parts.push(`${days}d`)
  if (hours) parts.push(`${hours}h`)
  if (minutes) parts.push(`${minutes}m`)
  if (seconds || parts.length === 0) parts.push(`${seconds}s`)
  return parts.join(' ')
}

export function formatDateTime(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

/** Basis points to a percent string, e.g. 3333 -> "33.33". */
export function bpsToPercent(bps: number): string {
  const whole = Math.floor(bps / 100)
  const frac = bps % 100
  return frac === 0 ? String(whole) : `${whole}.${String(frac).padStart(2, '0').replace(/0$/, '')}`
}

/** Parse a percent string with up to 2 decimals into basis points, or undefined when invalid. */
export function percentToBps(value: string): number | undefined {
  const v = value.trim()
  if (!/^\d+(\.\d{1,2})?$/.test(v)) return undefined
  const [whole, frac = ''] = v.split('.')
  return Number(whole) * 100 + Number(frac.padEnd(2, '0'))
}
