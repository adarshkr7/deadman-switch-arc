import { useQuery, useQueryClient } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import { decodeEventLog, numberToHex, pad } from 'viem'
import type { Address, Hex, PublicClient } from 'viem'
import { CHAIN_ID, VAULT_ADDRESS, VAULT_DEPLOY_BLOCK, vaultAbi } from '@/lib/vault'

export interface VaultEvent {
  name: string
  args: Record<string, unknown>
  hash: Hex
  blockNumber: bigint
  logIndex: number
}

interface LogScan {
  events: VaultEvent[]
  scannedTo: bigint
}

const FIRST_CHUNK = 20000n
const MIN_CHUNK = 500n
/** Used only when VITE_VAULT_DEPLOY_BLOCK is not set: look back a bounded distance from the head. */
const FALLBACK_LOOKBACK = 5000n

interface RawLog {
  data: Hex
  topics: [Hex, ...Hex[]]
  transactionHash: Hex | null
  blockNumber: Hex | null
  logIndex: Hex | null
}

/** Fetch logs for one vault (topic 1 is the indexed vaultId on every event), halving the range on RPC errors. */
async function fetchRange(client: PublicClient, from: bigint, to: bigint, topic: Hex): Promise<RawLog[]> {
  if (!VAULT_ADDRESS) return []
  try {
    return (await client.request({
      method: 'eth_getLogs',
      params: [{ address: VAULT_ADDRESS, fromBlock: numberToHex(from), toBlock: numberToHex(to), topics: [null, topic] }],
    })) as unknown as RawLog[]
  } catch (error) {
    if (to - from < MIN_CHUNK) throw error
    const mid = from + (to - from) / 2n
    const left = await fetchRange(client, from, mid, topic)
    const right = await fetchRange(client, mid + 1n, to, topic)
    return [...left, ...right]
  }
}

function decode(log: RawLog): VaultEvent | undefined {
  if (!log.transactionHash || !log.blockNumber || log.logIndex === null) return undefined
  try {
    const decoded = decodeEventLog({ abi: vaultAbi, data: log.data, topics: log.topics, strict: false })
    return {
      name: decoded.eventName,
      args: (decoded.args ?? {}),
      hash: log.transactionHash,
      blockNumber: BigInt(log.blockNumber),
      logIndex: Number(BigInt(log.logIndex)),
    }
  } catch {
    return undefined
  }
}

/**
 * Every event for one vault, oldest first. Scans from the contract's deploy block
 * (never from block 0) and resumes from the last scanned block on each refresh.
 */
export function useVaultLogs(vaultId: bigint | undefined) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const queryClient = useQueryClient()
  const key = ['vault-logs', vaultId?.toString()]

  return useQuery({
    queryKey: key,
    enabled: Boolean(client && VAULT_ADDRESS && vaultId !== undefined),
    refetchInterval: 8000,
    queryFn: async (): Promise<LogScan> => {
      if (!client || vaultId === undefined) return { events: [], scannedTo: 0n }
      const prev = queryClient.getQueryData<LogScan>(key)
      const head = await client.getBlockNumber()
      let start = prev ? prev.scannedTo + 1n : (VAULT_DEPLOY_BLOCK ?? (head > FALLBACK_LOOKBACK ? head - FALLBACK_LOOKBACK : 1n))
      const topic = pad(numberToHex(vaultId), { size: 32 })
      const fresh: VaultEvent[] = []
      while (start <= head) {
        const end = start + FIRST_CHUNK - 1n < head ? start + FIRST_CHUNK - 1n : head
        for (const log of await fetchRange(client, start, end, topic)) {
          const event = decode(log)
          if (event) fresh.push(event)
        }
        start = end + 1n
      }
      const events = [...(prev?.events ?? []), ...fresh].sort((a, b) =>
        a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1,
      )
      return { events, scannedTo: head }
    },
  })
}

export function argAddress(event: VaultEvent, name: string): Address | undefined {
  const value = event.args[name]
  return typeof value === 'string' ? (value as Address) : undefined
}

export function argBig(event: VaultEvent, name: string): bigint | undefined {
  const value = event.args[name]
  return typeof value === 'bigint' ? value : undefined
}
