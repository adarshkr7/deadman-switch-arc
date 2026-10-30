# [App Name]

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

[Brief description of what the app does and its primary use case]

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Deployed contracts

- `DeadMansSwitchVault` on Arc Testnet (5042002): `0xa907530cfa52ddcce47d3b233d030a07b24ecdb6` (constructor arg: USDC `0x3600000000000000000000000000000000000000`). Address is read by the app from `VITE_VAULT_ADDRESS` in `.env`.
- CURRENT: `DeadMansSwitchVault` v2.2 on Arc Testnet: `0x7c371c3403cd5866000678c28bfe1105444078ee` (constructor arg: USDC `0x3600000000000000000000000000000000000000`). The frontend now targets this address via `VITE_VAULT_ADDRESS` (+ `VITE_VAULT_DEPLOY_BLOCK=69905919`); the v1 address above is no longer used by the app. v2.2 API highlights: `createVault(CreateParams)` with guardians (m-of-n), delays, fallback; delayed withdrawals (`requestWithdraw`/`executeWithdraw`/`cancelWithdraw`); `setCheckInDelegate`; two-phase `trigger` + challenge window (owner/delegate `checkIn` cancels); `finalize`, `claim`, `setPayoutAddress`, `sweep`, `setFallbackPayout`. Owner rotation needs guardian-quorum `proposeOwnerRotation`, the timelock, and an explicit `approveOwnerRotation(vaultId, newOwner)` from the owner or delegate (routine `checkIn` never approves); owner, delegate or any beneficiary can `cancelOwnerRotation` at any time. `extendDeadline` is once per check-in period, only before the deadline (`DeadlinePassed` after), capped at one interval from now. Lost-key recovery: the delegate approves the rotation.
- SUPERSEDED (do not use): v2 `0xeaf918d74b8ce2b56fe852b93351c67488fa5997` and v2.1 `0x95cdd05d83a1668eddb1878c3f983682d5dd6a73` (implicit check-in liveness proof, since replaced by explicit approval). The v1 source and tests are archived in `archive/v1/`.
- Mainnet move: change `VAULT_CHAIN` in `src/lib/vault.ts`, redeploy from the user's own wallet, update `VITE_VAULT_ADDRESS`. Explorer links come from `@/onchain-facts`.
- Vault IDs start at 1. Deposit never resets the timer. Triggered vaults revert `checkIn`/`withdraw` with `VaultAlreadyTriggered`; expired-untriggered with `VaultExpired`.

## Key Files

- `src/App.tsx` - Shell (header, theme, demo mode, routing by query string: `?vault=ID&tab=...`)
- `src/lib/vaultAbi.ts` - ABI generated from the v2.2 artifact (regenerate if the contract changes)
- `src/components/wizard/` - 6-step create wizard; `src/components/vault/` - vault page (hero, rotation alert, pending actions, guardians, delegate, details)
- `src/hooks/useVaultTx.ts` - single tx pipeline (confirm dialog, dry run decodes reverts, receipt wait, toast, tx log)
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## Share links

- Starter apps already ship `getShareBase`, `buildShareLink` and `installShareSync` in `src/lib/share.ts`; import them instead of rewriting them.
- Keep shareable state in the URL path or query, not in the `#fragment`.
- Never put a secret (private key, claim secret, seed phrase, session token, API key) in the URL path or query, encoded or not: every in-app path and query is mirrored to the visitor's studio.arc.io address bar and browser history and reaches servers. A bearer claim secret goes only in the `#fragment` appended to the share link (`` `${await buildShareLink('/claim')}#${secret}` ``) and is read from `location.hash` on load. A link to the app's own share URL shown inside the app must be copy-only or open in a new tab with `target="_blank" rel="noopener noreferrer"`.
- Build every link a user copies or sends with `buildShareLink()` from `src/lib/share.ts`.
- Keep the `installShareSync()` call in `src/main.tsx` when editing it; it keeps the Studio address bar in step with in-app navigation.
- Navigate inside the app with relative links.

## To Run

```bash
bun install
bun run dev
```
