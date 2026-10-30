import {
  BaseError,
  ContractFunctionRevertedError,
  RawContractError,
  UserRejectedRequestError,
  decodeErrorResult,
  isHex,
  parseAbi,
} from 'viem'
import type { Address } from 'viem'
import { arcTestnet } from 'viem/chains'
import { getUsdc, requireChain } from '@/onchain-facts'
import { vaultAbi } from '@/lib/vaultAbi'

export { vaultAbi }

/** Single place to change when the vault moves to Arc mainnet. */
export const VAULT_CHAIN = arcTestnet
export const CHAIN_ID = VAULT_CHAIN.id
export const CHAIN_NAME = requireChain(CHAIN_ID).name

export const VAULT_ADDRESS = import.meta.env.VITE_VAULT_ADDRESS as Address | undefined
const deployBlock = import.meta.env.VITE_VAULT_DEPLOY_BLOCK as string | undefined
/** First block the vault contract existed in; event scans never start earlier. */
export const VAULT_DEPLOY_BLOCK = deployBlock && /^\d+$/.test(deployBlock) ? BigInt(deployBlock) : undefined

const usdcFact = getUsdc(CHAIN_ID)
if (!usdcFact) throw new Error('USDC is missing from the onchain facts for the vault chain')
export const USDC_ADDRESS = usdcFact.address as Address
export const ZERO_ADDRESS: Address = '0x0000000000000000000000000000000000000000'

/** Mirrors the contract's public limits (all in seconds unless noted). */
export const LIMITS = {
  minInterval: 60,
  maxInterval: 100 * 365 * 86400,
  minDelay: 60,
  maxDelay: 365 * 86400,
  maxSweepPeriod: 3650 * 86400,
  maxBeneficiaries: 20,
  maxGuardians: 10,
} as const

/** Used by the contract when a delay is passed as 0. */
export const DEFAULTS = {
  withdrawDelay: 24 * 3600,
  challengeWindow: 24 * 3600,
  rotationTimelock: 48 * 3600,
  sweepPeriod: 180 * 86400,
} as const

/** A vault whose every window is at most this long is labelled as a demo vault. */
export const DEMO_MAX_WINDOW_SECONDS = 600

export const erc20Abi = parseAbi([
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
])

type Args = readonly unknown[] | undefined

const REVERTS: Record<string, string | ((a: Args) => string)> = {
  ZeroTokenAddress: 'The vault token is not configured.',
  VaultNotFound: 'That vault does not exist.',
  EmptyBeneficiaries: 'Add at least one beneficiary.',
  LengthMismatch: 'Beneficiaries and shares do not line up.',
  TooManyBeneficiaries: 'A vault supports at most 20 beneficiaries.',
  ZeroBeneficiary: 'A beneficiary address is empty.',
  DuplicateBeneficiary: 'Each beneficiary address can only appear once.',
  ZeroShare: 'Every beneficiary needs a share above zero.',
  InvalidSharesTotal: 'Shares must add up to exactly 100%.',
  InvalidInterval: 'The check-in window must be between 60 seconds and 100 years.',
  TimestampOverflow: 'That time is too far in the future.',
  TooManyGuardians: 'A vault supports at most 10 guardians.',
  ZeroGuardian: 'A guardian address is empty.',
  DuplicateGuardian: 'Each guardian address can only appear once.',
  GuardianIsOwner: 'The vault owner cannot also be a guardian.',
  InvalidGuardianThreshold: 'The approval threshold must be between 1 and the number of guardians (or 0 with no guardians).',
  InvalidDelay: 'Each delay must be between 60 seconds and its maximum.',
  InvalidFallbackAddress: 'The fallback address cannot be empty, the vault contract or the USDC token.',
  InvalidDelegate: 'The check-in delegate cannot be the owner, a guardian or the vault contract.',
  InvalidNewOwner:
    'That address cannot become owner. It must not be a guardian, beneficiary, delegate, fallback address or the current owner.',
  InvalidPayoutAddress: 'That payout address is not allowed.',
  NotVaultOwner: 'Only the vault owner can do this.',
  NotOwnerOrDelegate: 'Only the owner or the check-in delegate can do this.',
  NotOwnerOrGuardian: 'Only the owner or a guardian can do this.',
  NotGuardian: 'Only a guardian of this vault can do this.',
  NotBeneficiary: 'Only a beneficiary of this vault can do this.',
  NotOwnerDelegateOrBeneficiary: 'Only the owner, the delegate or a beneficiary can do this.',
  NotFallback: 'Only the fallback address can do this.',
  VaultExpired: 'The timer ran out, so this can no longer be done.',
  VaultNotExpired: 'The deadline has not passed yet.',
  VaultAlreadyTriggered: 'This vault has already been triggered.',
  VaultNotTriggered: 'This vault has not been triggered yet.',
  NotTriggered: 'This vault has not been triggered yet.',
  DepositsClosed: 'Deposits are closed because claims are open.',
  ChallengeEnded: 'The challenge window is over, so the trigger can no longer be cancelled.',
  ChallengeNotOver: 'The challenge window is still running. Claims open when it ends.',
  AlreadyFinalized: 'The payout pool is already locked in.',
  VaultSwept: 'Unclaimed funds were already swept.',
  SweepNotReady: 'It is too early to sweep unclaimed funds.',
  AlreadySwept: 'Unclaimed funds were already swept.',
  ZeroAmount: 'Enter an amount greater than zero.',
  NoTokensReceived: 'No USDC was received by the vault.',
  InsufficientVaultBalance: 'The vault does not hold that much USDC.',
  AlreadyClaimed: 'This wallet has already claimed its share.',
  WithdrawalPending: 'A withdrawal is already pending. Execute or cancel it first.',
  NoPendingWithdrawal: 'There is no pending withdrawal.',
  WithdrawalNotReady: 'The withdrawal delay has not finished yet.',
  AlreadyApproved: 'You already voted on this proposal.',
  DeadlinePassed: 'The deadline has passed, so guardians can no longer extend it.',
  ExtensionAlreadyUsed: 'Guardians already extended the deadline once since the last check-in.',
  ExtensionTooLarge: 'The new deadline must be later than the current one and at most one check-in window from now.',
  RotationPending: 'An owner rotation is already pending.',
  NoPendingRotation: 'There is no pending owner rotation.',
  RotationNotReady: 'The rotation timelock has not finished yet.',
  RotationNotApproved: 'The owner or delegate has not approved this rotation.',
  RotationAlreadyApproved: 'This rotation is already approved.',
  RotationTargetMismatch: 'The pending rotation is for a different address than the one you approved.',
  SafeERC20FailedOperation: 'The USDC transfer failed. Check your balance and allowance.',
  ReentrancyGuardReentrantCall: 'Please try again.',
}

export interface Revert {
  name: string
  args?: readonly unknown[]
}

function decodeRevert(error: unknown): Revert | undefined {
  if (!(error instanceof BaseError)) return undefined
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
  if (reverted instanceof ContractFunctionRevertedError && reverted.data) {
    return { name: reverted.data.errorName, args: reverted.data.args }
  }
  const raw = error.walk((e) => e instanceof RawContractError)
  if (raw instanceof RawContractError) {
    const data = typeof raw.data === 'object' ? raw.data?.data : raw.data
    if (data && isHex(data) && data.length >= 10) {
      try {
        const decoded = decodeErrorResult({ abi: vaultAbi, data })
        return { name: decoded.errorName, args: decoded.args }
      } catch {
        return undefined
      }
    }
  }
  return undefined
}

export interface ParsedError {
  rejected: boolean
  message: string
}

/** Turn a wallet, RPC or contract error into a message a person can act on. */
export function parseTxError(error: unknown): ParsedError {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) {
      return { rejected: true, message: 'Transaction cancelled.' }
    }
    const revert = decodeRevert(error)
    if (revert) {
      const entry = REVERTS[revert.name]
      const message = typeof entry === 'function' ? entry(revert.args) : entry
      return { rejected: false, message: message ?? `The contract rejected this action (${revert.name}).` }
    }
    const short = error.shortMessage.toLowerCase()
    if (short.includes('user rejected') || short.includes('denied')) {
      return { rejected: true, message: 'Transaction cancelled.' }
    }
    if (short.includes('insufficient funds')) {
      return { rejected: false, message: 'Not enough USDC to pay for gas. Use Get test USDC in the sidebar.' }
    }
    return { rejected: false, message: error.shortMessage }
  }
  return { rejected: false, message: 'Something went wrong. Please try again.' }
}
