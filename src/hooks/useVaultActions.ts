import { useMemo } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import { parseEventLogs } from 'viem'
import type { Address } from 'viem'
import { formatUsdc } from '@/onchain-money'
import { CHAIN_ID, USDC_ADDRESS, VAULT_ADDRESS, ZERO_ADDRESS, erc20Abi, vaultAbi } from '@/lib/vault'
import { usdcCall, vaultCall } from '@/lib/calls'
import { formatDuration, shortAddress } from '@/lib/format'
import type { VaultData } from '@/lib/phase'
import { useVaultTx } from '@/hooks/useVaultTx'

export interface CreateParams {
  beneficiaries: Address[]
  sharesBps: number[]
  interval: bigint
  guardians: Address[]
  guardianThreshold: number
  withdrawDelay: bigint
  challengeWindow: bigint
  rotationTimelock: bigint
  sweepPeriod: bigint
  fallbackAddress: Address
}

/** Every vault write, each with its own plain-language confirmation summary. */
export function useVaultActions() {
  const send = useVaultTx()
  const { address } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })

  return useMemo(() => {
    const ok = async (promise: ReturnType<typeof send>) => Boolean(await promise)
    const tag = (v: VaultData) => `vault #${v.id}`

    return {
      async createVault(params: CreateParams, summary: string[]): Promise<bigint | undefined> {
        const receipt = await send({
          label: 'Create vault',
          confirm: {
            title: 'Create this vault?',
            lines: summary,
            warning: 'Beneficiaries, shares and guardians are permanent. They cannot be changed after creation.',
            confirmLabel: 'Create vault',
          },
          call: vaultCall('createVault', [params]),
        })
        if (!receipt) return undefined
        const [created] = parseEventLogs({ abi: vaultAbi, eventName: 'VaultCreated', logs: receipt.logs })
        return created?.args.vaultId
      },

      async deposit(v: VaultData, amount: bigint): Promise<boolean> {
        if (!client || !address || !VAULT_ADDRESS) return false
        const allowance = await client.readContract({
          address: USDC_ADDRESS,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [address, VAULT_ADDRESS],
        })
        const summary = {
          title: `Deposit ${formatUsdc(amount)} USDC?`,
          lines: [
            `Adds ${formatUsdc(amount)} USDC to ${tag(v)}.`,
            allowance < amount ? 'Your wallet will first ask to allow the vault to take this USDC, then to deposit it.' : 'One transaction.',
            'Deposits never reset the timer.',
          ],
          confirmLabel: 'Deposit',
        }
        if (allowance < amount) {
          const approved = await send({
            label: 'Approve USDC',
            confirm: summary,
            call: usdcCall('approve', [VAULT_ADDRESS, amount]),
          })
          if (!approved) return false
          return ok(send({ label: `Deposit into ${tag(v)}`, confirm: false, call: vaultCall('deposit', [v.id, amount]) }))
        }
        return ok(send({ label: `Deposit into ${tag(v)}`, confirm: summary, call: vaultCall('deposit', [v.id, amount]) }))
      },

      checkIn: (v: VaultData) =>
        ok(
          send({
            label: `Check in to ${tag(v)}`,
            confirm: {
              title: v.triggered ? 'Cancel the trigger?' : "Confirm you're alive?",
              lines: [
                `Resets the timer on ${tag(v)} to ${formatDuration(v.interval)}.`,
                v.triggered ? 'This cancels the trigger and stops the challenge window.' : 'Any extra time guardians added is replaced.',
              ],
              confirmLabel: v.triggered ? 'Cancel trigger' : "I'm alive",
            },
            call: vaultCall('checkIn', [v.id]),
          }),
        ),

      setDelegate: (v: VaultData, delegate: Address | undefined) =>
        ok(
          send({
            label: delegate ? 'Set check-in delegate' : 'Remove check-in delegate',
            confirm: {
              title: delegate ? 'Set this check-in delegate?' : 'Remove the check-in delegate?',
              lines: delegate
                ? [
                    `${shortAddress(delegate)} will be able to check in for ${tag(v)} and cancel a trigger.`,
                    'A delegate can also approve or veto an owner rotation. It cannot withdraw funds.',
                  ]
                : ['The current delegate loses its check-in, approval and veto rights.'],
              confirmLabel: delegate ? 'Set delegate' : 'Remove delegate',
            },
            call: vaultCall('setCheckInDelegate', [v.id, delegate ?? ZERO_ADDRESS]),
          }),
        ),

      requestWithdraw: (v: VaultData, amount: bigint) =>
        ok(
          send({
            label: `Request withdrawal from ${tag(v)}`,
            confirm: {
              title: `Request to withdraw ${formatUsdc(amount)} USDC?`,
              lines: [
                `You can execute it after a ${formatDuration(v.config.withdrawDelay)} delay, while the vault is still active.`,
                'Guardians or you can cancel it any time before then.',
              ],
              confirmLabel: 'Request withdrawal',
            },
            call: vaultCall('requestWithdraw', [v.id, amount]),
          }),
        ),

      executeWithdraw: (v: VaultData) =>
        ok(
          send({
            label: `Execute withdrawal from ${tag(v)}`,
            confirm: {
              title: `Withdraw ${formatUsdc(v.withdrawal?.amount ?? 0n)} USDC?`,
              lines: ['The USDC is sent to the vault owner wallet now.'],
              confirmLabel: 'Withdraw',
            },
            call: vaultCall('executeWithdraw', [v.id]),
          }),
        ),

      cancelWithdraw: (v: VaultData, asGuardian: boolean) =>
        ok(
          send({
            label: asGuardian ? 'Vote to cancel withdrawal' : 'Cancel withdrawal',
            confirm: {
              title: asGuardian ? 'Vote to cancel the pending withdrawal?' : 'Cancel the pending withdrawal?',
              lines: asGuardian
                ? [`Cancelling needs ${v.config.guardianThreshold} of ${v.config.guardianCount} guardians to agree. This adds your vote.`]
                : ['The funds stay in the vault.'],
              confirmLabel: asGuardian ? 'Add my vote' : 'Cancel withdrawal',
            },
            call: vaultCall('cancelWithdraw', [v.id]),
          }),
        ),

      extendDeadline: (v: VaultData, newDeadline: number) =>
        ok(
          send({
            label: 'Vote to extend deadline',
            confirm: {
              title: 'Vote to extend the deadline?',
              lines: [
                `New deadline: ${new Date(newDeadline * 1000).toLocaleString()}.`,
                `It needs ${v.config.guardianThreshold} of ${v.config.guardianCount} guardians voting for exactly this time.`,
                'Guardians can extend once per check-in period, and only before the deadline.',
              ],
              confirmLabel: 'Add my vote',
            },
            call: vaultCall('extendDeadline', [v.id, BigInt(newDeadline)]),
          }),
        ),

      proposeRotation: (v: VaultData, newOwner: Address) =>
        ok(
          send({
            label: 'Vote to rotate owner',
            confirm: {
              title: 'Vote to propose a new owner?',
              lines: [
                `Proposed new owner: ${newOwner}.`,
                `It needs ${v.config.guardianThreshold} of ${v.config.guardianCount} guardians voting for this address.`,
                `After that the vault owner or delegate must approve, and a ${formatDuration(v.config.rotationTimelock)} timelock must pass.`,
              ],
              confirmLabel: 'Add my vote',
            },
            call: vaultCall('proposeOwnerRotation', [v.id, newOwner]),
          }),
        ),

      approveRotation: (v: VaultData, newOwner: Address) =>
        ok(
          send({
            label: 'Approve owner rotation',
            confirm: {
              title: 'Approve this owner rotation?',
              lines: [
                `${newOwner} becomes the owner of ${tag(v)} once the timelock ends.`,
                'The new owner can request and execute withdrawals of the whole balance.',
              ],
              warning: 'Approving hands over the vault. Only approve an address you recognise and control.',
              confirmLabel: 'Approve and hand over',
              danger: true,
            },
            call: vaultCall('approveOwnerRotation', [v.id, newOwner]),
          }),
        ),

      cancelRotation: (v: VaultData) =>
        ok(
          send({
            label: 'Veto owner rotation',
            confirm: {
              title: 'Veto the pending owner rotation?',
              lines: ['The proposal is cancelled. Guardians would need a fresh quorum to propose again.'],
              confirmLabel: 'Veto rotation',
            },
            call: vaultCall('cancelOwnerRotation', [v.id]),
          }),
        ),

      executeRotation: (v: VaultData) =>
        ok(
          send({
            label: 'Execute owner rotation',
            confirm: {
              title: 'Execute the approved rotation?',
              lines: [
                `${v.rotation ? shortAddress(v.rotation.newOwner) : 'The new owner'} becomes the vault owner now.`,
                'The check-in delegate and any pending withdrawal are cleared.',
              ],
              confirmLabel: 'Execute',
            },
            call: vaultCall('executeOwnerRotation', [v.id]),
          }),
        ),

      trigger: (v: VaultData) =>
        ok(
          send({
            label: `Trigger ${tag(v)}`,
            confirm: {
              title: 'Trigger this vault?',
              lines: [
                `The deadline has passed. This starts a ${formatDuration(v.config.challengeWindow)} challenge window.`,
                'The owner or delegate can still cancel by checking in during the window. After it, beneficiaries can claim.',
              ],
              confirmLabel: 'Trigger',
            },
            call: vaultCall('trigger', [v.id]),
          }),
        ),

      finalize: (v: VaultData) =>
        ok(
          send({
            label: `Lock payouts for ${tag(v)}`,
            confirm: {
              title: 'Lock in the payout pool?',
              lines: ['Fixes the amount shared between beneficiaries. Claiming does this automatically.'],
              confirmLabel: 'Lock in',
            },
            call: vaultCall('finalize', [v.id]),
          }),
        ),

      setPayout: (v: VaultData, payout: Address | undefined) =>
        ok(
          send({
            label: 'Set payout address',
            confirm: {
              title: payout ? 'Send your share to a different address?' : 'Use your own address for payouts?',
              lines: [payout ? `Your share will be paid to ${payout}.` : 'Your share will be paid to the beneficiary address itself.'],
              confirmLabel: 'Save',
            },
            call: vaultCall('setPayoutAddress', [v.id, payout ?? ZERO_ADDRESS]),
          }),
        ),

      claim: (v: VaultData, amount: bigint, payoutTo: Address) =>
        ok(
          send({
            label: `Claim from ${tag(v)}`,
            confirm: {
              title: `Claim ${formatUsdc(amount)} USDC?`,
              lines: [`Paid to ${shortAddress(payoutTo)}. You can claim only once.`],
              confirmLabel: 'Claim',
            },
            call: vaultCall('claim', [v.id]),
          }),
        ),

      sweep: (v: VaultData) =>
        ok(
          send({
            label: `Sweep ${tag(v)}`,
            confirm: {
              title: 'Sweep unclaimed funds?',
              lines: [
                'Everything not yet claimed goes to the fallback address chosen at creation.',
                'Beneficiaries who have not claimed lose their share.',
              ],
              confirmLabel: 'Sweep',
              danger: true,
            },
            call: vaultCall('sweep', [v.id]),
          }),
        ),

      setFallbackPayout: (v: VaultData, payout: Address | undefined) =>
        ok(
          send({
            label: 'Set fallback payout',
            confirm: {
              title: 'Change where swept funds go?',
              lines: [payout ? `Swept funds will be sent to ${payout}.` : 'Swept funds will go to the fallback address itself.'],
              confirmLabel: 'Save',
            },
            call: vaultCall('setFallbackPayout', [v.id, payout ?? ZERO_ADDRESS]),
          }),
        ),
    }
  }, [send, address, client])
}
