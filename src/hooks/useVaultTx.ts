import { useCallback } from 'react'
import { useAccount, usePublicClient, useSendTransaction, useSwitchChain } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import type { TransactionReceipt } from 'viem'
import { CHAIN_ID, parseTxError } from '@/lib/vault'
import type { EncodedCall } from '@/lib/calls'
import { useTxLog } from '@/hooks/useTxLog'
import { useConfirm } from '@/components/Confirm'
import type { ConfirmRequest } from '@/components/Confirm'

export interface TxRequest {
  label: string
  /** Summary shown before the wallet opens; false skips it (used for the second step of a flow). */
  confirm: ConfirmRequest | false
  call: EncodedCall
}

/**
 * Sends one transaction end to end: confirmation summary, chain switch, a dry run that turns
 * contract reverts into plain language before the wallet opens, the send, a real receipt wait,
 * a toast, and an entry in the transaction log with its explorer link.
 */
export function useVaultTx() {
  const { address, chainId } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const { sendTransactionAsync } = useSendTransaction()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const log = useTxLog()
  const queryClient = useQueryClient()
  const confirm = useConfirm()

  return useCallback(
    async ({ label, confirm: summary, call }: TxRequest): Promise<TransactionReceipt | undefined> => {
      if (!address) {
        toast.error('Connect your wallet first.')
        return undefined
      }
      if (!client) return undefined
      if (summary && !(await confirm(summary))) return undefined

      const id = crypto.randomUUID()
      log.add({ id, label, status: 'wallet', at: Date.now() })
      try {
        if (chainId !== CHAIN_ID) await switchChainAsync({ chainId: CHAIN_ID })
        await client.call({ account: address, to: call.to, data: call.data })
        const hash = await sendTransactionAsync({ to: call.to, data: call.data, chainId: CHAIN_ID })
        log.update(id, { hash, status: 'pending' })
        const receipt = await client.waitForTransactionReceipt({ hash })
        if (receipt.status === 'success') {
          log.update(id, { status: 'success' })
          toast.success(`${label} confirmed`)
          await queryClient.invalidateQueries()
          return receipt
        }
        log.update(id, { status: 'failed', error: 'The transaction was mined but reverted.' })
        toast.error(`${label} failed: the transaction reverted.`)
        return undefined
      } catch (error) {
        const parsed = parseTxError(error)
        if (parsed.rejected) {
          log.remove(id)
        } else {
          log.update(id, { status: 'failed', error: parsed.message })
          toast.error(parsed.message)
        }
        return undefined
      }
    },
    [address, chainId, client, confirm, log, queryClient, sendTransactionAsync, switchChainAsync],
  )
}
