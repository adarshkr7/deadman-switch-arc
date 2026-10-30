import type { Address } from 'viem'
import { DEMO_MAX_WINDOW_SECONDS } from '@/lib/vault'

export interface VaultConfig {
  withdrawDelay: number
  challengeWindow: number
  rotationTimelock: number
  sweepPeriod: number
  fallbackAddress: Address
  guardianThreshold: number
  guardianCount: number
}

export interface PendingWithdrawal {
  amount: bigint
  executableAt: number
}

export interface PendingRotation {
  newOwner: Address
  executableAt: number
  proposedAt: number
  approved: boolean
}

/** Everything the UI needs to know about one vault, read from the contract. */
export interface VaultData {
  id: bigint
  owner: Address
  delegate: Address | undefined
  lastCheckIn: number
  interval: number
  deadline: number
  balance: bigint
  claimPool: bigint
  totalClaimed: bigint
  claimedCount: number
  triggered: boolean
  triggeredAt: number
  challengeEnd: number
  sweepAt: number
  finalized: boolean
  swept: boolean
  guardianNonce: bigint
  extensionUsed: boolean
  beneficiaries: Address[]
  sharesBps: number[]
  guardians: Address[]
  config: VaultConfig
  withdrawal: PendingWithdrawal | undefined
  rotation: PendingRotation | undefined
}

export type UiState = 'active' | 'warning' | 'challenge' | 'triggered' | 'swept'

export interface DerivedState {
  state: UiState
  /** Deadline passed but nobody has triggered yet (shown as Warning). */
  expired: boolean
  /** Seconds to the next boundary for this state; undefined when there is none. */
  remaining: number | undefined
  /** Length of the current window in seconds, for progress bars. */
  total: number
  headline: string
  countdownLabel: string
}

/** The warning band: the last quarter of the check-in window. */
const WARNING_FRACTION = 0.25

/** Derive the one state shown on the hero card from contract fields and chain time. */
export function deriveState(v: VaultData, now: number | undefined): DerivedState {
  if (v.swept) {
    return { state: 'swept', expired: false, remaining: undefined, total: 0, headline: 'Swept', countdownLabel: '' }
  }
  if (v.triggered) {
    if (now === undefined || now < v.challengeEnd) {
      return {
        state: 'challenge',
        expired: true,
        remaining: now === undefined ? undefined : v.challengeEnd - now,
        total: v.config.challengeWindow,
        headline: 'Challenge window',
        countdownLabel: 'Claims open in',
      }
    }
    return {
      state: 'triggered',
      expired: true,
      remaining: v.sweepAt - now,
      total: v.config.sweepPeriod,
      headline: 'Triggered, claims open',
      countdownLabel: 'Unclaimed funds can be swept in',
    }
  }
  const remaining = now === undefined ? undefined : v.deadline - now
  if (remaining !== undefined && remaining <= 0) {
    return {
      state: 'warning',
      expired: true,
      remaining: 0,
      total: v.interval,
      headline: 'Deadline passed',
      countdownLabel: 'Timer expired',
    }
  }
  const low = remaining !== undefined && remaining / v.interval < WARNING_FRACTION
  return {
    state: low ? 'warning' : 'active',
    expired: false,
    remaining,
    total: v.interval,
    headline: low ? 'Check in soon' : 'Active',
    countdownLabel: 'Time until this vault expires',
  }
}

export interface Roles {
  owner: boolean
  delegate: boolean
  guardian: boolean
  beneficiary: boolean
  fallback: boolean
  /** Connected wallet has no role in this vault (or no wallet is connected). */
  visitor: boolean
}

const same = (a: string | undefined, b: string | undefined) => Boolean(a && b && a.toLowerCase() === b.toLowerCase())

export function deriveRoles(address: Address | undefined, v: VaultData): Roles {
  const owner = same(address, v.owner)
  const delegate = same(address, v.delegate)
  const guardian = Boolean(address && v.guardians.some((g) => same(g, address)))
  const beneficiary = Boolean(address && v.beneficiaries.some((b) => same(b, address)))
  const fallback = same(address, v.config.fallbackAddress)
  return { owner, delegate, guardian, beneficiary, fallback, visitor: !(owner || delegate || guardian || beneficiary || fallback) }
}

export function roleLabels(r: Roles): string[] {
  const out: string[] = []
  if (r.owner) out.push('Owner')
  if (r.delegate) out.push('Delegate')
  if (r.guardian) out.push('Guardian')
  if (r.beneficiary) out.push('Beneficiary')
  if (r.fallback) out.push('Fallback')
  return out
}

/** True when every window on the vault is short enough to be a demo vault. */
export function isDemoVault(v: Pick<VaultData, 'interval' | 'config'>): boolean {
  const c = v.config
  return (
    v.interval <= DEMO_MAX_WINDOW_SECONDS &&
    c.withdrawDelay <= DEMO_MAX_WINDOW_SECONDS &&
    c.challengeWindow <= DEMO_MAX_WINDOW_SECONDS &&
    c.rotationTimelock <= DEMO_MAX_WINDOW_SECONDS
  )
}

export const sameAddress = same
