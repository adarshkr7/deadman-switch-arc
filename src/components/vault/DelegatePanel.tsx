import { useState } from 'react'
import { isAddress } from 'viem'
import type { Address } from 'viem'
import { ExternalLink } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID, ZERO_ADDRESS } from '@/lib/vault'
import { sameAddress } from '@/lib/phase'
import { useVaultActions } from '@/hooks/useVaultActions'
import { ActionButton, Card, Notice, SectionLabel, TextField } from '@/components/ui'
import type { VaultCtx } from '@/components/vault/ctx'

export function DelegatePanel({ ctx }: { ctx: VaultCtx }) {
  const { vault, roles, derived, txBusy } = ctx
  const actions = useVaultActions()
  const [value, setValue] = useState('')
  const [busy, setBusy] = useState<'set' | 'remove' | 'checkin'>()
  const target = value.trim()

  let setReason: string | undefined
  if (!roles.owner) setReason = 'Only the vault owner can set the delegate.'
  else if (!isAddress(target)) setReason = 'Enter the delegate wallet address.'
  else if (target.toLowerCase() === ZERO_ADDRESS || sameAddress(target, vault.owner)) setReason = 'The delegate must be a different wallet from the owner.'
  else if (vault.guardians.some((g) => sameAddress(g, target))) setReason = 'A guardian cannot be the delegate.'
  else if (sameAddress(target, vault.delegate)) setReason = 'That wallet is already the delegate.'
  else if (txBusy && !busy) setReason = 'Another transaction is in progress.'

  const removeReason = !roles.owner ? 'Only the vault owner can remove the delegate.' : txBusy && !busy ? 'Another transaction is in progress.' : undefined

  const canCheckIn = derived.state === 'active' || derived.state === 'challenge' || (derived.state === 'warning' && !derived.expired)
  const checkInReason = !canCheckIn ? 'The deadline passed. A check-in works again only after someone triggers the vault, during the challenge window.' : txBusy && busy !== 'checkin' ? 'Another transaction is in progress.' : undefined

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <SectionLabel>Check-in delegate</SectionLabel>
        <p className="mt-3 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          A delegate is a second wallet you trust (for example a hardware wallet or a family member). It can check in for you, cancel a trigger, and approve or veto
          an owner rotation. It cannot withdraw, change anything else, or act as a guardian. If you lose your owner key, the delegate is how you recover the vault.
        </p>
        <div className="glass-inner mt-4 rounded-2xl p-4">
          <div className="text-[11px] font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>
            Current delegate
          </div>
          {vault.delegate ? (
            <a
              href={buildAddressExplorerUrl(CHAIN_ID, vault.delegate)}
              target="_blank"
              rel="noopener noreferrer"
              className="mono mt-1 inline-flex items-start gap-1 break-all text-sm hover:underline"
            >
              {vault.delegate}
              {roles.delegate ? ' (you)' : ''}
              <ExternalLink className="mt-0.5 size-3 shrink-0" aria-hidden />
            </a>
          ) : (
            <p className="mt-1 text-sm" style={{ color: 'var(--muted)' }}>
              No delegate set.
            </p>
          )}
        </div>
      </Card>

      {roles.delegate && (
        <Card>
          <SectionLabel>You are the delegate</SectionLabel>
          <p className="mt-3 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
            Check in on behalf of the owner. Rotation approvals and vetoes appear at the top of the vault page when a rotation is pending.
          </p>
          <ActionButton
            className="mt-3"
            busy={busy === 'checkin'}
            reason={checkInReason}
            onClick={() => {
              setBusy('checkin')
              void actions.checkIn(vault).finally(() => setBusy(undefined))
            }}
          >
            {vault.triggered ? "Cancel trigger, I'm alive" : "I'm alive"}
          </ActionButton>
        </Card>
      )}

      <Card>
        <SectionLabel>{vault.delegate ? 'Change delegate' : 'Set a delegate'}</SectionLabel>
        {!roles.owner && (
          <div className="mt-3">
            <Notice>Only the vault owner can change the delegate.</Notice>
          </div>
        )}
        <TextField
          className="mono mt-3"
          label="Delegate wallet address"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="0x…"
          spellCheck={false}
        />
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <ActionButton
            variant="ghost"
            busy={busy === 'set'}
            reason={setReason}
            onClick={() => {
              setBusy('set')
              void actions.setDelegate(vault, target as Address).finally(() => setBusy(undefined))
            }}
          >
            {vault.delegate ? 'Replace delegate' : 'Set delegate'}
          </ActionButton>
          {vault.delegate && (
            <ActionButton
              variant="ghost"
              busy={busy === 'remove'}
              reason={removeReason}
              onClick={() => {
                setBusy('remove')
                void actions.setDelegate(vault, undefined).finally(() => setBusy(undefined))
              }}
            >
              Remove delegate
            </ActionButton>
          )}
        </div>
      </Card>
    </div>
  )
}
