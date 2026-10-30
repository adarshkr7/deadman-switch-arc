import { useEffect, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { useQuery } from '@tanstack/react-query'
import { CHAIN_ID } from '@/lib/vault'

/**
 * Current chain time in unix seconds, ticking every 250ms.
 * Anchored to the latest block timestamp so the countdown agrees with what the contract will enforce,
 * not with the visitor's local clock. Undefined until the first block has been read.
 */
export function useChainNow(): number | undefined {
  const client = usePublicClient({ chainId: CHAIN_ID })

  const { data: anchor } = useQuery({
    queryKey: ['chain-anchor'],
    enabled: Boolean(client),
    refetchInterval: 6000,
    queryFn: async () => {
      if (!client) throw new Error('No client')
      const requestedAt = Date.now()
      const block = await client.getBlock()
      return { chainSeconds: Number(block.timestamp), localMs: Math.round((requestedAt + Date.now()) / 2) }
    },
  })

  const [now, setNow] = useState<number>()

  useEffect(() => {
    if (!anchor) return
    const update = () => setNow(anchor.chainSeconds + (Date.now() - anchor.localMs) / 1000)
    update()
    const t = setInterval(update, 250)
    return () => clearInterval(t)
  }, [anchor])

  return now
}
