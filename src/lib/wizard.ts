import { isAddress } from 'viem'
import type { Address } from 'viem'
import { DEFAULTS, LIMITS, USDC_ADDRESS, VAULT_ADDRESS, ZERO_ADDRESS } from '@/lib/vault'
import { bpsToPercent, formatDuration, percentToBps, shortAddress } from '@/lib/format'
import type { CreateParams } from '@/hooks/useVaultActions'

export type Unit = 'seconds' | 'minutes' | 'hours' | 'days'
export const UNIT_SECONDS: Record<Unit, number> = { seconds: 1, minutes: 60, hours: 3600, days: 86400 }

export interface DurationInput {
  amount: string
  unit: Unit
}

export function toSeconds(d: DurationInput): number | undefined {
  if (!/^\d+$/.test(d.amount)) return undefined
  const n = Number(d.amount) * UNIT_SECONDS[d.unit]
  return Number.isSafeInteger(n) && n > 0 ? n : undefined
}

export interface Row {
  id: number
  address: string
  percent: string
}

export type WindowsMode = 'standard' | 'custom'

export interface WizardState {
  beneficiaries: Row[]
  interval: DurationInput
  /** Id of the selected interval preset, or 'custom'. */
  preset: string
  windowsMode: WindowsMode
  withdrawDelay: DurationInput
  challengeWindow: DurationInput
  rotationTimelock: DurationInput
  sweepPeriod: DurationInput
  guardians: { id: number; address: string }[]
  threshold: string
  fallback: string
}

export interface IntervalPreset {
  id: string
  label: string
  seconds: number
  hint: string
}

export const NORMAL_PRESETS: IntervalPreset[] = [
  { id: '1d', label: '1 day', seconds: 86400, hint: 'Daily check-in' },
  { id: '7d', label: '7 days', seconds: 7 * 86400, hint: 'Weekly check-in' },
  { id: '30d', label: '30 days', seconds: 30 * 86400, hint: 'Monthly check-in' },
  { id: '90d', label: '90 days', seconds: 90 * 86400, hint: 'Quarterly check-in' },
  { id: '365d', label: '1 year', seconds: 365 * 86400, hint: 'Yearly check-in' },
]

export const DEMO_PRESETS: IntervalPreset[] = [
  { id: 'd2', label: '2 minutes', seconds: 120, hint: 'Fast demo' },
  { id: 'd5', label: '5 minutes', seconds: 300, hint: 'Relaxed demo' },
  { id: 'd15', label: '15 minutes', seconds: 900, hint: 'Longer demo' },
]

/** Demo vaults use the contract's 60-second minimum for every window (sweep gets 2 minutes). */
export const DEMO_WINDOWS = { withdrawDelay: 60, challengeWindow: 60, rotationTimelock: 60, sweepPeriod: 120 } as const

let rowId = 100
export const nextRowId = () => rowId++

export function initialState(demo: boolean, wallet: Address | undefined): WizardState {
  const preset = demo ? DEMO_PRESETS[0] : NORMAL_PRESETS[2]
  return {
    beneficiaries: [
      { id: 1, address: '', percent: '50' },
      { id: 2, address: '', percent: '50' },
    ],
    interval: demo ? { amount: '2', unit: 'minutes' } : { amount: '30', unit: 'days' },
    preset: preset.id,
    windowsMode: 'standard',
    withdrawDelay: { amount: '24', unit: 'hours' },
    challengeWindow: { amount: '24', unit: 'hours' },
    rotationTimelock: { amount: '48', unit: 'hours' },
    sweepPeriod: { amount: '180', unit: 'days' },
    guardians: [],
    threshold: '1',
    fallback: wallet ?? '',
  }
}

export interface StepErrors {
  beneficiaries: string[]
  shares: string[]
  interval: string[]
  guardians: string[]
  totalBps: number
}

const isUsable = (a: string) => isAddress(a.trim()) && a.trim().toLowerCase() !== ZERO_ADDRESS

function resolveWindows(s: WizardState, demo: boolean) {
  if (demo) return DEMO_WINDOWS
  if (s.windowsMode === 'standard') return { withdrawDelay: 0, challengeWindow: 0, rotationTimelock: 0, sweepPeriod: 0 }
  return {
    withdrawDelay: toSeconds(s.withdrawDelay) ?? -1,
    challengeWindow: toSeconds(s.challengeWindow) ?? -1,
    rotationTimelock: toSeconds(s.rotationTimelock) ?? -1,
    sweepPeriod: toSeconds(s.sweepPeriod) ?? -1,
  }
}

export function validate(s: WizardState, demo: boolean, owner: Address | undefined): StepErrors {
  const e: StepErrors = { beneficiaries: [], shares: [], interval: [], guardians: [], totalBps: 0 }
  const addrs = s.beneficiaries.map((r) => r.address.trim().toLowerCase())
  if (s.beneficiaries.length === 0) e.beneficiaries.push('Add at least one beneficiary.')
  if (s.beneficiaries.some((r) => !isUsable(r.address))) e.beneficiaries.push('Every beneficiary needs a valid wallet address.')
  else if (new Set(addrs).size !== addrs.length) e.beneficiaries.push('Each beneficiary address can only appear once.')

  const bps = s.beneficiaries.map((r) => percentToBps(r.percent))
  e.totalBps = bps.reduce<number>((sum, b) => sum + (b ?? 0), 0)
  if (bps.some((b) => b === undefined || b === 0)) e.shares.push('Every share must be above 0%, with at most 2 decimals.')
  else if (e.totalBps !== 10000) e.shares.push(`Shares total ${bpsToPercent(e.totalBps)}%. They must add up to exactly 100%.`)

  const seconds = toSeconds(s.interval)
  if (seconds === undefined) e.interval.push('Enter a whole number for the check-in window.')
  else if (seconds < LIMITS.minInterval) e.interval.push('The check-in window must be at least 60 seconds.')
  else if (seconds > LIMITS.maxInterval) e.interval.push('The check-in window is too long.')
  const w = resolveWindows(s, demo)
  const bad = (v: number, max: number) => v !== 0 && (v < LIMITS.minDelay || v > max)
  if (
    bad(w.withdrawDelay, LIMITS.maxDelay) ||
    bad(w.challengeWindow, LIMITS.maxDelay) ||
    bad(w.rotationTimelock, LIMITS.maxDelay) ||
    bad(w.sweepPeriod, LIMITS.maxSweepPeriod)
  ) {
    e.interval.push('Each safety window must be at least 60 seconds and at most 1 year (sweep: 10 years).')
  }

  const guardians = s.guardians.map((g) => g.address.trim().toLowerCase())
  if (s.guardians.some((g) => !isUsable(g.address))) e.guardians.push('Every guardian needs a valid wallet address.')
  else if (new Set(guardians).size !== guardians.length) e.guardians.push('Each guardian address can only appear once.')
  else if (owner && guardians.includes(owner.toLowerCase())) e.guardians.push('You are the owner, so you cannot also be a guardian.')
  if (s.guardians.length > LIMITS.maxGuardians) e.guardians.push('A vault supports at most 10 guardians.')
  const t = Number(s.threshold)
  if (s.guardians.length > 0 && (!Number.isInteger(t) || t < 1 || t > s.guardians.length)) {
    e.guardians.push(`Approvals needed must be between 1 and ${s.guardians.length}.`)
  }
  const fb = s.fallback.trim().toLowerCase()
  if (!isUsable(s.fallback)) e.guardians.push('Enter a valid fallback address for unclaimed funds.')
  else if (fb === VAULT_ADDRESS?.toLowerCase() || fb === USDC_ADDRESS.toLowerCase()) {
    e.guardians.push('The fallback address cannot be the vault or the USDC contract.')
  }
  return e
}

export function hasErrors(e: StepErrors): boolean {
  return e.beneficiaries.length + e.shares.length + e.interval.length + e.guardians.length > 0
}

export function toParams(s: WizardState, demo: boolean): CreateParams | undefined {
  const interval = toSeconds(s.interval)
  if (interval === undefined) return undefined
  const w = resolveWindows(s, demo)
  const bps = s.beneficiaries.map((r) => percentToBps(r.percent))
  if (bps.some((b) => b === undefined)) return undefined
  return {
    beneficiaries: s.beneficiaries.map((r) => r.address.trim() as Address),
    sharesBps: bps as number[],
    interval: BigInt(interval),
    guardians: s.guardians.map((g) => g.address.trim() as Address),
    guardianThreshold: s.guardians.length === 0 ? 0 : Number(s.threshold),
    withdrawDelay: BigInt(w.withdrawDelay),
    challengeWindow: BigInt(w.challengeWindow),
    rotationTimelock: BigInt(w.rotationTimelock),
    sweepPeriod: BigInt(w.sweepPeriod),
    fallbackAddress: s.fallback.trim() as Address,
  }
}

/** Plain-English description of what the vault will do, used on the Review step and in the confirmation. */
export function summarize(p: CreateParams): string[] {
  const secs = (v: bigint, fallback: number) => formatDuration(v === 0n ? fallback : Number(v))
  const lines = [
    `You must check in at least every ${formatDuration(Number(p.interval))}. Miss it and anyone can trigger the vault.`,
    `After a trigger there is a ${secs(p.challengeWindow, DEFAULTS.challengeWindow)} challenge window. You or your delegate can cancel by checking in during it.`,
    `Then beneficiaries claim: ${p.beneficiaries
      .map((b, i) => `${shortAddress(b)} gets ${bpsToPercent(p.sharesBps[i])}%`)
      .join(', ')}.`,
    `Withdrawing your own funds takes a ${secs(p.withdrawDelay, DEFAULTS.withdrawDelay)} delay and can be cancelled.`,
    p.guardians.length > 0
      ? `${p.guardianThreshold} of ${p.guardians.length} guardians must agree to extend a deadline once, cancel a withdrawal or propose a new owner. Guardians can never move funds, and a new owner needs your or your delegate's approval after a ${secs(p.rotationTimelock, DEFAULTS.rotationTimelock)} timelock.`
      : 'No guardians: nobody can extend the deadline or propose a new owner.',
    `Funds nobody claims within ${secs(p.sweepPeriod, DEFAULTS.sweepPeriod)} of claims opening can be swept to ${shortAddress(p.fallbackAddress)}.`,
  ]
  return lines
}
