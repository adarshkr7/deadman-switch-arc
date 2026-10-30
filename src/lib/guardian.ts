import { encodeAbiParameters, keccak256, toBytes } from 'viem'
import type { Address, Hex } from 'viem'

/** Mirrors the contract's action tags and encodings so the app can find votes on a proposal. */
const EXTEND_TAG = keccak256(toBytes('EXTEND_DEADLINE'))
const CANCEL_TAG = keccak256(toBytes('CANCEL_WITHDRAW'))
const ROTATION_TAG = keccak256(toBytes('OWNER_ROTATION'))

export function extendActionId(newDeadline: bigint, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint64' }, { type: 'uint256' }],
      [EXTEND_TAG, newDeadline, nonce],
    ),
  )
}

export function rotationActionId(newOwner: Address, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'address' }, { type: 'uint256' }],
      [ROTATION_TAG, newOwner, nonce],
    ),
  )
}

export function cancelWithdrawActionId(amount: bigint, executableAt: bigint, nonce: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint256' }, { type: 'uint64' }, { type: 'uint256' }],
      [CANCEL_TAG, amount, executableAt, nonce],
    ),
  )
}

export type GuardianProposal =
  | { kind: 'extend'; actionId: Hex; newDeadline: number }
  | { kind: 'rotation'; actionId: Hex; newOwner: Address }
  | { kind: 'cancelWithdraw'; actionId: Hex }

export interface ProposalProgress {
  proposal: GuardianProposal
  approvals: number
  threshold: number
  voters: Address[]
}
