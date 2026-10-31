import { arc, arcTestnet } from 'viem/chains'

/**
 * The network the vault lives on, chosen at build time with VITE_VAULT_CHAIN
 * ("arc" for mainnet, "arc-testnet" otherwise). Set it together with
 * VITE_VAULT_ADDRESS and VITE_VAULT_DEPLOY_BLOCK so all three describe the same deployment.
 */
export const VAULT_CHAIN = import.meta.env.VITE_VAULT_CHAIN === 'arc' ? arc : arcTestnet
