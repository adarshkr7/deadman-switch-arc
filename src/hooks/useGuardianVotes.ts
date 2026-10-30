import { useQuery } from '@tanstack/react-query'
import { useAccount, usePublicClient } from 'wagmi'
import { decodeFunctionData } from 'viem'
import type { Address, Hex } from 'viem'
import { CHAIN_ID, VAULT_ADDRESS, vaultAbi } from '@/lib/vault'
import type { VaultData } from '@/lib/phase'
import { sameAddress } from '@/lib/phase'
import { cancelWithdrawActionId, extendActionId, rotationActionId } from '@/lib/guardian'
import type { GuardianProposal, ProposalProgress } from '@/lib/guardian'
import type { VaultEvent } from '@/hooks/useVaultLogs'

export interface LiveProposal extends ProposalProgress {
  /** True when the connected wallet is a guardian who already voted. */
  iVoted: boolean
}

/**
 * Guardian proposals still collecting votes. The contract only stores an action hash, so the
 * proposal's parameters are recovered from the calldata of the vote transactions, then the hash
 * is recomputed with the current guardian nonce. Only matching hashes with votes on-chain are live.
 */
export function useGuardianVotes(vault: VaultData | undefined, events: VaultEvent[] | undefined) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { address } = useAccount()
  const votes = (events ?? []).filter((e) => e.name === 'GuardianApproved')
  const voteKey = votes.map((e) => e.hash).join(',')

  return useQuery({
    queryKey: ['guardian-votes', vault?.id.toString(), vault?.guardianNonce.toString(), voteKey, vault?.withdrawal?.executableAt, address],
    enabled: Boolean(client && vault && VAULT_ADDRESS),
    refetchInterval: 8000,
    queryFn: async (): Promise<LiveProposal[]> => {
      if (!client || !vault || !VAULT_ADDRESS) return []
      const vaultAddress = VAULT_ADDRESS
      const nonce = vault.guardianNonce
      const candidates = new Map<Hex, GuardianProposal>()

      if (vault.withdrawal) {
        const id = cancelWithdrawActionId(vault.withdrawal.amount, BigInt(vault.withdrawal.executableAt), nonce)
        candidates.set(id, { kind: 'cancelWithdraw', actionId: id })
      }

      const hashes = [...new Set(votes.map((e) => e.hash))]
      for (const hash of hashes) {
        try {
          const tx = await client.getTransaction({ hash })
          const call = decodeFunctionData({ abi: vaultAbi, data: tx.input })
          if (call.functionName === 'extendDeadline') {
            const [, newDeadline] = call.args
            const id = extendActionId(newDeadline, nonce)
            candidates.set(id, { kind: 'extend', actionId: id, newDeadline: Number(newDeadline) })
          } else if (call.functionName === 'proposeOwnerRotation') {
            const [, newOwner] = call.args
            const id = rotationActionId(newOwner, nonce)
            candidates.set(id, { kind: 'rotation', actionId: id, newOwner })
          }
        } catch {
          // A vote sent through a contract wallet has different calldata; it simply is not listed.
        }
      }

      const live: LiveProposal[] = []
      for (const proposal of candidates.values()) {
        const approvals = Number(
          await client.readContract({
            address: vaultAddress,
            abi: vaultAbi,
            functionName: 'approvalCount',
            args: [vault.id, proposal.actionId],
          }),
        )
        if (approvals === 0) continue
        const voters: Address[] = []
        for (const g of vault.guardians) {
          const voted = await client.readContract({
            address: vaultAddress,
            abi: vaultAbi,
            functionName: 'hasApproved',
            args: [vault.id, proposal.actionId, g],
          })
          if (voted) voters.push(g)
        }
        live.push({
          proposal,
          approvals,
          threshold: vault.config.guardianThreshold,
          voters,
          iVoted: Boolean(address && voters.some((v) => sameAddress(v, address))),
        })
      }
      return live
    },
  })
}
