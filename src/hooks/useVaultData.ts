import { useQuery } from '@tanstack/react-query'
import { useAccount, usePublicClient, useReadContract, useReadContracts } from 'wagmi'
import type { Address } from 'viem'
import { CHAIN_ID, VAULT_ADDRESS, ZERO_ADDRESS, vaultAbi } from '@/lib/vault'
import { deriveRoles } from '@/lib/phase'
import type { PendingRotation, PendingWithdrawal, Roles, VaultConfig, VaultData } from '@/lib/phase'

const REFETCH_MS = 6000

interface RawView {
  owner: Address
  lastCheckIn: bigint
  interval: bigint
  deadline: bigint
  balance: bigint
  claimPool: bigint
  totalClaimed: bigint
  claimedCount: bigint
  triggered: boolean
  triggeredAt: bigint
  challengeEnd: bigint
  sweepAt: bigint
  finalized: boolean
  swept: boolean
  checkInDelegate: Address
  guardianNonce: bigint
  extensionUsed: boolean
}

interface RawConfig {
  withdrawDelay: bigint
  challengeWindow: bigint
  rotationTimelock: bigint
  sweepPeriod: bigint
  fallbackAddress: Address
  guardianThreshold: number
  guardianCount: bigint
}

function toConfig(c: RawConfig): VaultConfig {
  return {
    withdrawDelay: Number(c.withdrawDelay),
    challengeWindow: Number(c.challengeWindow),
    rotationTimelock: Number(c.rotationTimelock),
    sweepPeriod: Number(c.sweepPeriod),
    fallbackAddress: c.fallbackAddress,
    guardianThreshold: Number(c.guardianThreshold),
    guardianCount: Number(c.guardianCount),
  }
}

function buildVault(
  id: bigint,
  v: RawView,
  config: RawConfig,
  beneficiaries: readonly Address[],
  shares: readonly number[],
  guardians: readonly Address[],
  withdrawal: PendingWithdrawal | undefined,
  rotation: PendingRotation | undefined,
): VaultData {
  return {
    id,
    owner: v.owner,
    delegate: v.checkInDelegate === ZERO_ADDRESS ? undefined : v.checkInDelegate,
    lastCheckIn: Number(v.lastCheckIn),
    interval: Number(v.interval),
    deadline: Number(v.deadline),
    balance: v.balance,
    claimPool: v.claimPool,
    totalClaimed: v.totalClaimed,
    claimedCount: Number(v.claimedCount),
    triggered: v.triggered,
    triggeredAt: Number(v.triggeredAt),
    challengeEnd: Number(v.challengeEnd),
    sweepAt: Number(v.sweepAt),
    finalized: v.finalized,
    swept: v.swept,
    guardianNonce: v.guardianNonce,
    extensionUsed: v.extensionUsed,
    beneficiaries: [...beneficiaries],
    sharesBps: shares.map((s) => Number(s)),
    guardians: [...guardians],
    config: toConfig(config),
    withdrawal,
    rotation,
  }
}

/** Reads one vault with its config, beneficiaries, guardians and pending actions. */
export function useVault(vaultId: bigint | undefined) {
  const enabled = vaultId !== undefined && Boolean(VAULT_ADDRESS)
  const id = vaultId ?? 0n
  const common = { address: VAULT_ADDRESS, abi: vaultAbi, chainId: CHAIN_ID } as const
  const result = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...common, functionName: 'getVault', args: [id] },
      { ...common, functionName: 'getConfig', args: [id] },
      { ...common, functionName: 'getBeneficiaries', args: [id] },
      { ...common, functionName: 'getGuardians', args: [id] },
      { ...common, functionName: 'getPendingWithdrawal', args: [id] },
      { ...common, functionName: 'getPendingRotation', args: [id] },
    ],
    query: { enabled, refetchInterval: REFETCH_MS },
  })

  const [vRes, cRes, bRes, gRes, wRes, rRes] = result.data ?? []
  let vault: VaultData | undefined
  if (
    vaultId !== undefined &&
    vRes?.status === 'success' &&
    cRes?.status === 'success' &&
    bRes?.status === 'success' &&
    gRes?.status === 'success' &&
    wRes?.status === 'success' &&
    rRes?.status === 'success'
  ) {
    const w = wRes.result
    const r = rRes.result
    vault = buildVault(
      vaultId,
      vRes.result,
      cRes.result,
      bRes.result[0],
      bRes.result[1],
      gRes.result,
      w.exists ? { amount: w.amount, executableAt: Number(w.executableAt) } : undefined,
      r.exists
        ? { newOwner: r.newOwner, executableAt: Number(r.executableAt), proposedAt: Number(r.proposedAt), approved: r.approved }
        : undefined,
    )
  }

  const notFound = Boolean(result.data) && vRes?.status === 'failure'
  return { vault, notFound, isLoading: enabled && result.isLoading, isError: result.isError, refetch: result.refetch }
}

/** Per-beneficiary claimed flags and payout addresses, in beneficiary order. */
export function useBeneficiaryState(vaultId: bigint | undefined, beneficiaries: Address[] | undefined) {
  const list = beneficiaries ?? []
  const enabled = vaultId !== undefined && list.length > 0 && Boolean(VAULT_ADDRESS)
  const claimed = useReadContracts({
    allowFailure: false,
    contracts: list.map((account) => ({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: 'hasClaimed' as const,
      args: [vaultId ?? 0n, account] as const,
      chainId: CHAIN_ID,
    })),
    query: { enabled, refetchInterval: REFETCH_MS },
  })
  const payouts = useReadContracts({
    allowFailure: false,
    contracts: list.map((account) => ({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: 'payoutAddressOf' as const,
      args: [vaultId ?? 0n, account] as const,
      chainId: CHAIN_ID,
    })),
    query: { enabled, refetchInterval: REFETCH_MS },
  })
  return {
    claimed: (claimed.data ?? []).map((v) => v === true),
    payouts: (payouts.data ?? []).map((v) => (typeof v === 'string' ? (v as Address) : undefined)),
  }
}

/** What the connected wallet could claim from this vault right now. */
export function useClaimable(vaultId: bigint | undefined) {
  const { address } = useAccount()
  const result = useReadContract({
    address: VAULT_ADDRESS,
    abi: vaultAbi,
    functionName: 'claimable',
    args: [vaultId ?? 0n, address ?? ZERO_ADDRESS],
    chainId: CHAIN_ID,
    query: { enabled: vaultId !== undefined && Boolean(address) && Boolean(VAULT_ADDRESS), refetchInterval: REFETCH_MS },
  })
  return result.data
}

export function useFallbackPayout(vaultId: bigint | undefined) {
  const result = useReadContract({
    address: VAULT_ADDRESS,
    abi: vaultAbi,
    functionName: 'fallbackPayoutOf',
    args: [vaultId ?? 0n],
    chainId: CHAIN_ID,
    query: { enabled: vaultId !== undefined && Boolean(VAULT_ADDRESS), refetchInterval: REFETCH_MS },
  })
  return result.data
}

export interface VaultListItem {
  vault: VaultData
  roles: Roles
}

const LIST_LIMIT = 40n

/** Recent vaults (newest first) where the connected wallet has any role. */
export function useMyVaults() {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })

  return useQuery({
    queryKey: ['my-vaults', address],
    enabled: Boolean(client && address && VAULT_ADDRESS),
    refetchInterval: 15000,
    queryFn: async (): Promise<VaultListItem[]> => {
      if (!client || !address || !VAULT_ADDRESS) return []
      const vaultAddress = VAULT_ADDRESS
      const next = await client.readContract({ address: vaultAddress, abi: vaultAbi, functionName: 'nextVaultId' })
      const last = next - 1n
      if (last < 1n) return []
      const first = last >= LIST_LIMIT ? last - LIST_LIMIT + 1n : 1n
      const ids: bigint[] = []
      for (let id = last; id >= first; id--) ids.push(id)

      const [views, configs, bens, guards] = await Promise.all([
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ address: vaultAddress, abi: vaultAbi, functionName: 'getVault' as const, args: [id] as const })),
        }),
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ address: vaultAddress, abi: vaultAbi, functionName: 'getConfig' as const, args: [id] as const })),
        }),
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ address: vaultAddress, abi: vaultAbi, functionName: 'getBeneficiaries' as const, args: [id] as const })),
        }),
        client.multicall({
          allowFailure: false,
          contracts: ids.map((id) => ({ address: vaultAddress, abi: vaultAbi, functionName: 'getGuardians' as const, args: [id] as const })),
        }),
      ])

      const items: VaultListItem[] = []
      ids.forEach((id, i) => {
        const [beneficiaries, shares] = bens[i] as readonly [readonly Address[], readonly number[]]
        const vault = buildVault(
          id,
          views[i],
          configs[i],
          beneficiaries,
          shares,
          guards[i],
          undefined,
          undefined,
        )
        const roles = deriveRoles(address, vault)
        if (!roles.visitor) items.push({ vault, roles })
      })
      return items
    },
  })
}
