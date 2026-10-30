import { useEffect, useState } from 'react'
import { Link2 } from 'lucide-react'
import { toast } from 'sonner'
import { buildShareLink } from '@/lib/share'
import { Button } from '@/components/ui'

/** Copies a public, read-only link to this vault. */
export function ShareVaultLink({ vaultId }: { vaultId: bigint }) {
  const [link, setLink] = useState<string>()

  useEffect(() => {
    let cancelled = false
    buildShareLink(`/?vault=${vaultId}`)
      .then((url) => {
        if (!cancelled) setLink(url)
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [vaultId])

  async function copy() {
    if (!link) return
    try {
      await navigator.clipboard.writeText(link)
      toast.success('Public vault link copied')
    } catch {
      toast.error(`Could not copy. The vault ID is ${vaultId}.`)
    }
  }

  return (
    <Button variant="ghost" onClick={() => void copy()} disabled={!link} className="w-full">
      <Link2 className="size-4" aria-hidden /> Copy public link
    </Button>
  )
}
