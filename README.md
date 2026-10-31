# Dead-Man's Switch Vault

A USDC dead-man's switch on Arc. You lock USDC in a vault, name beneficiaries and their shares, and keep checking in. If you stop, the vault expires, a challenge window gives you a last chance to cancel, and then each beneficiary claims their share. There are no admin keys and no upgrades, and beneficiaries and shares are fixed at creation.

Built with [Arc Studio](https://studio.arc.io) for [Arc Microgrants: Built with Arc Studio](https://dorahacks.io/hackathon/arc-microgrants-2/detail) (DoraHacks, Circle / Arc).

## What you can do

- Create a vault with a guided wizard: beneficiaries, shares (must total 100%), check-in interval presets, optional guardians and a fallback address, then a plain-English review.
- Open any vault on a public, read-only page. Connect a wallet and the page adapts to your role: owner, check-in delegate, guardian, beneficiary or visitor. Actions you cannot take say why.
- Each vault shows one status (Active, Warning, Challenge, Triggered or Swept) with a live countdown and one main action for your role.
- Owners check in, deposit and request delayed withdrawals. Anyone can deposit and trigger an expired vault.
- Guardians vote (for example 1 of 2 approvals) to extend a deadline once per check-in, cancel a withdrawal, or propose a new owner. They can never move funds.
- A pending owner rotation shows a red alert to the owner, delegate and beneficiaries, with Approve and Veto.
- Beneficiaries claim once and can set a different payout address. Unclaimed funds can be swept to the fallback address after the sweep period.
- Every transaction shows a confirmation summary first, a toast when it finishes, and its hash with an explorer link.
- Light and dark modes, mobile first. Demo mode creates vaults with 60-second-scale windows for testing.

## Security model

- **Two-phase trigger.** After the deadline anyone can `trigger`, which opens a challenge window. A check-in by the owner or delegate during the window cancels it; claims open only after it ends.
- **Check-in delegate.** A separate key that can only call `checkIn` (and approve or veto an owner rotation). If it is stolen, the worst case is that the vault stays alive.
- **Delayed withdrawals.** `requestWithdraw` then `executeWithdraw` after a delay; the owner or a guardian quorum can cancel.
- **Guardians cannot take over.** An owner rotation proposed by guardians executes only after a timelock **and** an explicit `approveOwnerRotation` by the owner or delegate for that exact address. The owner, delegate or any beneficiary can veto. A dead owner never approves, so the funds go to the beneficiaries. Guardians may extend the deadline once per check-in period and never after it has passed.
- **Tests.** 379 Foundry tests, including fuzz and invariant campaigns where a colluding guardian quorum and attackers try every action against a dead owner, and no USDC ever reaches an address other than a beneficiary payout address or the fallback.

## Deployments

| Network | Contract | Deploy tx |
| --- | --- | --- |
| Arc Testnet | [`0x7c371c3403cd5866000678c28bfe1105444078ee`](https://testnet.explorer.arc.io/address/0x7c371c3403cd5866000678c28bfe1105444078ee) | [`0x0f8fd4df…3e18`](https://testnet.explorer.arc.io/tx/0x0f8fd4dfc8c242394c4b2d02b9d78b1cfce7e2454e414f2fa10c166678da3e18) |
| Arc Mainnet | [`0xb14d5F1Ea45808bB2f4aD474D9fD39069d36EBcE`](https://explorer.arc.io/address/0xb14d5F1Ea45808bB2f4aD474D9fD39069d36EBcE) | [`0x6ef6dc73…6ee`](https://explorer.arc.io/tx/0x6ef6dc736bf5d63e65a08d8d8f5be447f6437014dac83e5c1e98e65fb19e06ee) |

Earlier testnet versions are listed in `AGENTS.md`; the first version's source and tests are in `archive/v1/`.

## Tech stack

- React, Vite, TypeScript, Tailwind CSS
- wagmi, viem, ConnectKit
- Solidity 0.8.28 and Foundry (contract in `contracts/`, tests in `contracts/test/`)
- Arc (USDC at `0x3600000000000000000000000000000000000000`)

## Development

Prerequisites: [Bun](https://bun.sh) and [Foundry](https://book.getfoundry.sh).

```bash
cp .env.example .env
bun install
bun run dev
```

Other commands:

```bash
bun run contracts:build   # compile the contract
bun run contracts:test    # run the Foundry tests
bun run check             # lint and typecheck
```

### Environment variables

- `VITE_VAULT_ADDRESS`: address of the deployed vault contract the app talks to.
- `VITE_VAULT_DEPLOY_BLOCK`: block the vault contract was deployed in; activity and vote scans start there.
- `RPC_PROXY_BASE_URL`, `RPC_PROXY_TOKEN`, `RPC_PROXY_CHAINS`: provisioned by Arc Studio, optional outside Arc Studio.

## Submission

| Item | Value |
| --- | --- |
| Arc Studio project | https://studio.arc.io/app/9f05c1c7-b735-4f47-8c7b-b703912cbbe2 |
| Live app | https://deadman-switch-arc.vercel.app |
| Contract address(es) | [`0xb14d5F1Ea45808bB2f4aD474D9fD39069d36EBcE`](https://explorer.arc.io/address/0xb14d5F1Ea45808bB2f4aD474D9fD39069d36EBcE) (Arc mainnet) |
| Example USDC tx (deposit 0.1 USDC into vault #1) | [`0x4a0e26014b5268d76f3314f9b226395fce89cff76a74d05458236b0af2d6ab0b`](https://explorer.arc.io/tx/0x4a0e26014b5268d76f3314f9b226395fce89cff76a74d05458236b0af2d6ab0b) |
| Example USDC tx (beneficiary claims 0.1 USDC from vault #1) | [`0x4c2105f9573537826c95c6694810033c5944fa61242aa169293414b1473b8e0f`](https://explorer.arc.io/tx/0x4c2105f9573537826c95c6694810033c5944fa61242aa169293414b1473b8e0f) |
| Video walkthrough | https://youtu.be/KU6erjHD8BA |
| Builder profile | _TODO: GitHub, X, or Farcaster_ |

Checklist (requirements from the hackathon page):

- [x] Built in Arc Studio from first contract to working app
- [x] Contracts written and tested in Arc Studio
- [x] Contracts deployed to **Arc mainnet** (testnet-only isn't eligible)
- [x] Working app live at a public link
- [x] At least one mainnet transaction that moves USDC through the contract and app
- [x] Contract address(es) plus one tx hash, linked on explorer.arc.io
- [ ] **Public** repo (switch before submitting: `gh repo edit --visibility public --accept-visibility-change-consequences`)
- [x] Video walkthrough showing the build in Arc Studio and the mainnet transaction
- [ ] Short description of the project and how Arc Studio was used
- [ ] Public builder profile on GitHub, X, or Farcaster

Deadline: 2026-11-02 04:59 UTC.
