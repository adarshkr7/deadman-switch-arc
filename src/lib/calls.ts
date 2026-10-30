import { encodeFunctionData } from 'viem'
import type { Address, ContractFunctionArgs, ContractFunctionName, Hex } from 'viem'
import { USDC_ADDRESS, VAULT_ADDRESS, erc20Abi, vaultAbi } from '@/lib/vault'

export interface EncodedCall {
  to: Address
  data: Hex
}

type VaultWrite = ContractFunctionName<typeof vaultAbi, 'nonpayable'>
type Erc20Write = ContractFunctionName<typeof erc20Abi, 'nonpayable'>

/** Encode a vault write with function name and arguments checked against the contract ABI. */
export function vaultCall<F extends VaultWrite>(
  functionName: F,
  args: ContractFunctionArgs<typeof vaultAbi, 'nonpayable', F>,
): EncodedCall {
  if (!VAULT_ADDRESS) throw new Error('VITE_VAULT_ADDRESS is not set')
  const data = encodeFunctionData({ abi: vaultAbi, functionName, args } as Parameters<typeof encodeFunctionData>[0])
  return { to: VAULT_ADDRESS, data }
}

export function usdcCall<F extends Erc20Write>(
  functionName: F,
  args: ContractFunctionArgs<typeof erc20Abi, 'nonpayable', F>,
): EncodedCall {
  const data = encodeFunctionData({ abi: erc20Abi, functionName, args } as Parameters<typeof encodeFunctionData>[0])
  return { to: USDC_ADDRESS, data }
}
