import type { Address } from 'viem'
import type { DerivedState, Roles, VaultData } from '@/lib/phase'
import type { LiveProposal } from '@/hooks/useGuardianVotes'

/** Everything a vault page section needs, computed once per render in VaultPage. */
export interface VaultCtx {
  vault: VaultData
  /** Chain time in unix seconds; undefined until the first block is read. */
  now: number | undefined
  derived: DerivedState
  roles: Roles
  address: Address | undefined
  proposals: LiveProposal[]
  /** True while any of this wallet's transactions is waiting for the wallet or the network. */
  txBusy: boolean
  goTab: (tab: 'overview' | 'guardians' | 'delegate' | 'details') => void
}
