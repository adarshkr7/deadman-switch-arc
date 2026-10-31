import type { ReactNode } from 'react'
import { ExternalLink } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID, CHAIN_NAME, USDC_ADDRESS, VAULT_ADDRESS } from '@/lib/vault'
import { GrainArt } from '@/components/GrainArt'

const SECTIONS = [
  { id: 'what', title: 'What it is' },
  { id: 'start', title: 'Quick start' },
  { id: 'lifecycle', title: 'Vault lifecycle' },
  { id: 'create', title: 'Creating a vault' },
  { id: 'owner', title: 'Owner' },
  { id: 'delegate', title: 'Check-in delegate' },
  { id: 'guardians', title: 'Guardians' },
  { id: 'beneficiaries', title: 'Beneficiaries' },
  { id: 'fallback', title: 'Fallback and sweep' },
  { id: 'screen', title: 'Reading the vault page' },
  { id: 'demo', title: 'Demo mode' },
  { id: 'security', title: 'Security guarantees' },
  { id: 'limits', title: 'Limits and defaults' },
  { id: 'faq', title: 'FAQ' },
] as const

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="glass-card scroll-mt-6 rounded-[32px] p-6 sm:p-8">
      <h2 className="display text-2xl font-bold">{title}</h2>
      <div className="docs-body mt-4 flex flex-col gap-3 text-sm leading-relaxed" style={{ color: 'var(--ink-2)' }}>
        {children}
      </div>
    </section>
  )
}

function Steps({ items }: { items: ReactNode[] }) {
  return (
    <ol className="flex flex-col gap-2">
      {items.map((item, i) => (
        <li key={i} className="flex gap-3">
          <span className="flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-bold" style={{ background: 'var(--accent)', color: 'var(--on-accent)' }}>
            {i + 1}
          </span>
          <span className="pt-0.5">{item}</span>
        </li>
      ))}
    </ol>
  )
}

function Bullets({ items }: { items: ReactNode[] }) {
  return (
    <ul className="flex flex-col gap-1.5">
      {items.map((item, i) => (
        <li key={i} className="flex gap-2.5">
          <span className="mt-2 size-1.5 shrink-0 rounded-full" style={{ background: 'var(--accent)' }} />
          <span>{item}</span>
        </li>
      ))}
    </ul>
  )
}

function Table({ head, rows }: { head: string[]; rows: ReactNode[][] }) {
  return (
    <div className="overflow-x-auto rounded-2xl" style={{ border: '1px solid var(--border)' }}>
      <table className="w-full text-left text-[13px]">
        <thead>
          <tr style={{ background: 'var(--surface-muted)' }}>
            {head.map((h) => (
              <th key={h} className="px-4 py-2.5 font-semibold" style={{ color: 'var(--muted)' }}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} style={{ borderTop: '1px solid var(--border)' }}>
              {r.map((c, j) => (
                <td key={j} className="px-4 py-2.5 align-top">
                  {c}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

const B = ({ children }: { children: ReactNode }) => <strong style={{ color: 'var(--ink)' }}>{children}</strong>

/** In-app documentation: every feature, every role, and how to use them. */
export function Docs() {
  return (
    <div className="flex flex-col gap-5">
      <header className="glass-card on-art relative isolate flex min-h-[220px] flex-col justify-end overflow-hidden rounded-[36px] p-6 sm:p-8">
        <GrainArt variant="wave" state="active" className="-z-20" />
        <div className="grain-shade absolute inset-0 -z-10" aria-hidden />
        <p className="text-xs font-semibold uppercase tracking-[0.12em] text-white/70">Documentation</p>
        <h1 className="display mt-1 text-3xl font-bold text-white sm:text-4xl">How the Dead-Man's Switch works</h1>
        <p className="mt-2 max-w-xl text-sm text-white/80">Every feature, every role, and how to use them.</p>
      </header>

      <nav className="glass-card rounded-[32px] p-5" aria-label="On this page">
        <p className="mb-3 text-[11px] font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>
          On this page
        </p>
        <div className="flex flex-wrap gap-2">
          {SECTIONS.map((s) => (
            <a key={s.id} href={`#${s.id}`} className="rounded-full px-3.5 py-1.5 text-xs font-semibold transition-colors hover:brightness-125" style={{ background: 'var(--surface-strong)' }}>
              {s.title}
            </a>
          ))}
        </div>
      </nav>

      <Section id="what" title="What it is">
        <p>
          A <B>dead-man's switch for USDC</B> on {CHAIN_NAME}. You lock USDC in a vault, name the people who should receive it and their shares, and check in
          regularly to prove you are still around. If you stop checking in, the vault expires, and after a short challenge window your beneficiaries claim their
          shares.
        </p>
        <p>
          Everything is enforced by one smart contract. There are <B>no admin keys and no upgrades</B>: nobody, including the people who built this app, can move
          funds outside the rules described here. Beneficiaries and their shares are fixed when the vault is created.
        </p>
      </Section>

      <Section id="start" title="Quick start">
        <Steps
          items={[
            <>Connect a wallet on {CHAIN_NAME}. On Arc, USDC is also the gas token, so you only need USDC (a few cents covers every action).</>,
            <>
              Open <B>Create</B> and follow the wizard: beneficiaries, shares, check-in interval, optional guardians, review, then deploy.
            </>,
            <>Deposit USDC into the vault (your wallet asks once for a USDC allowance, then the deposit).</>,
            <>
              Press <B>I'm alive</B> before the countdown runs out. Each check-in restarts the timer.
            </>,
            <>
              Share the vault link with your beneficiaries. If you ever stop checking in, they <B>trigger</B> the vault, wait out the challenge window, and{' '}
              <B>claim</B>.
            </>,
          ]}
        />
      </Section>

      <Section id="lifecycle" title="Vault lifecycle">
        <p>Every vault is in exactly one state, shown on the big card at the top of its page.</p>
        <Table
          head={['State', 'What it means', 'What can happen next']}
          rows={[
            [<B>Active</B>, 'The owner checked in recently. The countdown shows time left before the deadline.', 'Owner or delegate checks in; deposits; withdrawals; guardian actions.'],
            [<B>Warning</B>, 'Less than a quarter of the check-in window is left, or the deadline has passed (red).', 'Check in now. Once the deadline passes, anyone can trigger.'],
            [<B>Challenge</B>, 'Someone triggered the expired vault. A challenge window is running.', 'The owner or delegate can still cancel by checking in. Otherwise claims open when it ends.'],
            [<B>Triggered</B>, 'Claims are open.', 'Each beneficiary claims their own share. After the sweep period, unclaimed shares can go to the fallback.'],
            [<B>Swept</B>, 'Unclaimed funds were sent to the fallback address.', 'Nothing. The vault is closed.'],
          ]}
        />
      </Section>

      <Section id="create" title="Creating a vault">
        <Steps
          items={[
            <>
              <B>Beneficiaries.</B> Add 1 to 20 wallet addresses. Each address can appear once. They cannot be changed later.
            </>,
            <>
              <B>Shares.</B> Give each beneficiary a percentage. The live total must reach exactly 100% (up to two decimals).
            </>,
            <>
              <B>Interval.</B> How often you must check in: presets from 1 day to 1 year, or a custom value (minimum 60 seconds). Choose a generous interval:
              forgetting counts the same as not being there. You can also use recommended or custom safety windows (withdrawal delay, challenge window, rotation
              timelock, sweep period).
            </>,
            <>
              <B>Guardians (optional).</B> Up to 10 trusted addresses and how many must agree (for example 2 of 3). Also set the <B>fallback address</B> that
              receives shares nobody claims; it defaults to your own wallet.
            </>,
            <>
              <B>Review.</B> A plain-English summary of exactly what the vault will do. The wizard warns you if the fallback is also a guardian or a beneficiary.
            </>,
            <>
              <B>Deploy.</B> Your wallet sends one transaction and the new vault opens.
            </>,
          ]}
        />
      </Section>

      <Section id="owner" title="Owner">
        <Bullets
          items={[
            <>
              <B>Check in ("I'm alive").</B> Restarts the timer: the new deadline is now plus your interval. Works until the deadline, and during a challenge
              window to cancel a trigger.
            </>,
            <>
              <B>Deposit.</B> Add USDC at any time before the vault is triggered. Anyone can deposit; deposits never reset the timer.
            </>,
            <>
              <B>Withdraw.</B> Two steps: <B>request</B> an amount, wait the withdrawal delay (default 24 hours), then <B>execute</B>. One request at a time,
              only while the vault is active. You can cancel your own request; a guardian quorum can cancel it too, which protects your heirs if your key is
              stolen.
            </>,
            <>
              <B>Set a check-in delegate.</B> A second key that can only check in (see below). Set it to empty to remove it.
            </>,
            <>
              <B>Approve or veto an owner rotation</B> proposed by guardians (see Guardians).
            </>,
          ]}
        />
      </Section>

      <Section id="delegate" title="Check-in delegate">
        <p>
          A separate wallet, for example on your phone, that keeps the vault alive while your main key stays in cold storage. The delegate can{' '}
          <B>only</B>:
        </p>
        <Bullets items={['check in (including cancelling a trigger during the challenge window),', 'approve or veto a pending owner rotation.']} />
        <p>
          It can never withdraw or move funds. If it is stolen, the worst case is that the vault stays alive. A delegate cannot be the owner or a guardian.
        </p>
      </Section>

      <Section id="guardians" title="Guardians">
        <p>
          Guardians are optional trusted people who vote together. Each action needs the quorum you set at creation (shown as "1 of 2 approvals"); every guardian
          adds their vote from the <B>Guardians</B> tab. Guardians <B>never move funds and can never trigger a vault early</B>.
        </p>
        <Table
          head={['Guardian action', 'Rules']}
          rows={[
            [<B>Extend the deadline</B>, 'Once per check-in period, at most one interval from now, and only before the deadline has passed. For when the owner is temporarily unable to check in.'],
            [<B>Cancel a pending withdrawal</B>, 'Stops a withdrawal request before it executes, e.g. if the owner key looks stolen.'],
            [
              <B>Propose a new owner</B>,
              'For an owner who lost their key. The new owner cannot be a guardian, beneficiary, the delegate or the fallback. It executes only after the rotation timelock (default 48 hours) AND an explicit approval by the current owner or delegate for that exact address.',
            ],
          ]}
        />
        <p>
          A pending rotation shows as a <B>red alert</B> on the vault page. The owner, the delegate or <B>any beneficiary</B> can veto it at any time. Routine
          check-ins never count as approval, and a dead owner never approves, so guardians cannot take over a vault.
        </p>
      </Section>

      <Section id="beneficiaries" title="Beneficiaries">
        <Bullets
          items={[
            <>
              <B>Trigger.</B> Once the deadline has passed, anyone (usually a beneficiary) can trigger the vault. This starts the challenge window (default 24
              hours) during which the owner can still cancel.
            </>,
            <>
              <B>Claim.</B> When the challenge window ends, each beneficiary claims their own share, once. Your share is your percentage of the vault balance at
              that moment; the last beneficiary to claim also receives any rounding remainder.
            </>,
            <>
              <B>Payout address.</B> Before claiming you can send your share to a different wallet (for example if you lost access to the original). Only you can
              set it, and only before you claim.
            </>,
            <>A beneficiary can only ever take their own share. They cannot move anyone else's.</>,
          ]}
        />
      </Section>

      <Section id="fallback" title="Fallback and sweep">
        <p>
          If some beneficiaries never claim, their shares would otherwise be locked forever. After the <B>sweep period</B> (default 180 days after claims open),
          the remaining unclaimed balance can be sent to the <B>fallback address</B> chosen at creation. The money always goes to that address, never to whoever
          sends the sweep. The fallback collects it with <B>Collect unclaimed funds</B>, and can redirect where it is paid. Beneficiaries can keep claiming
          right up until the sweep happens.
        </p>
      </Section>

      <Section id="screen" title="Reading the vault page">
        <Bullets
          items={[
            <>
              <B>Big card:</B> the current state. Its colours follow it: orange when active, red when overdue, amber during the challenge window.
            </>,
            <>
              <B>Balance card:</B> USDC held in (or reserved by) the vault, and what it means right now.
            </>,
            <>
              <B>Round button:</B> the one main action for your role (for example the heart for "I'm alive", or Claim). If it is greyed out, the line under it
              says why. Next to it: the live countdown and progress bar.
            </>,
            <>
              <B>Gauge:</B> how much of the current window is left, from 100 down to 0.
            </>,
            <>
              <B>Tabs:</B> Overview (funds, pending actions, beneficiaries, share link), Guardians, Delegate, and Details (settings, activity log, payout and
              fallback tools).
            </>,
            <>
              <B>Pending actions:</B> withdrawals, owner rotations, triggers and guardian votes, each with a live countdown and a Cancel or Vote button.
            </>,
            <>
              Every transaction shows a summary before you sign, a toast when it finishes, and its hash with an explorer link. Contract errors are shown in plain
              English.
            </>,
            <>The page adapts to the connected wallet's role. Without a wallet it is a public, read-only view anyone can open from the share link.</>,
          ]}
        />
      </Section>

      <Section id="demo" title="Demo mode">
        <p>
          Turn on <B>Demo mode</B> in the header to create vaults with very short timers so you can see the whole lifecycle in a few minutes: check-in presets of
          2, 5 or 15 minutes, a 60-second withdrawal delay, challenge window and rotation timelock, and a 10-minute sweep period. Demo vaults are labelled{' '}
          <B>Demo vault</B>. They are real vaults with real USDC, so use small amounts.
        </p>
      </Section>

      <Section id="security" title="Security guarantees">
        <Bullets
          items={[
            'No admin keys and no upgrades: the rules cannot be changed after deployment.',
            'Beneficiaries and shares are fixed at creation.',
            'A stolen delegate key can only keep the vault alive.',
            'A stolen owner key cannot empty the vault instantly: withdrawals are delayed and guardians can cancel them.',
            'Guardians can never move funds, trigger early, or take ownership without the owner or delegate approving the exact new address.',
            'Funds only ever leave through: owner withdrawals, beneficiary claims, or the sweep to the fallback address.',
            'Tested with 379 Foundry tests, including fuzz and invariant campaigns where colluding guardians and attackers try every action against a dead owner.',
            'The contract is not audited. Use amounts you are comfortable with.',
          ]}
        />
      </Section>

      <Section id="limits" title="Limits and defaults">
        <Table
          head={['Setting', 'Default', 'Allowed range']}
          rows={[
            ['Check-in interval', 'chosen in the wizard', '60 seconds to 100 years'],
            ['Withdrawal delay', '24 hours', '60 seconds to 1 year'],
            ['Challenge window', '24 hours', '60 seconds to 1 year'],
            ['Rotation timelock', '48 hours', '60 seconds to 1 year'],
            ['Sweep period', '180 days', '60 seconds to 10 years'],
            ['Beneficiaries', '', '1 to 20'],
            ['Guardians', 'none', '0 to 10, quorum 1 to the number of guardians'],
          ]}
        />
      </Section>

      <Section id="faq" title="FAQ">
        <Bullets
          items={[
            <>
              <B>Do I need ETH?</B> No. On Arc, gas is paid in USDC. Each action costs a fraction of a cent.
            </>,
            <>
              <B>I missed my deadline. Is it over?</B> Not yet. Check-ins are blocked until the vault is triggered, but anyone can trigger it, including you.
              After the trigger, check in during the challenge window to cancel it and restart your timer.
            </>,
            <>
              <B>Can I change beneficiaries?</B> No, they are fixed. Withdraw your funds and create a new vault instead.
            </>,
            <>
              <B>A beneficiary lost their wallet.</B> If they still control it at claim time, they can set a payout address first. Otherwise their share eventually
              goes to the fallback after the sweep period.
            </>,
            <>
              <B>I lost my owner key.</B> Your delegate keeps the vault alive. To recover ownership, your guardians propose a new owner and your delegate approves
              it after the timelock.
            </>,
          ]}
        />
      </Section>

      {VAULT_ADDRESS && (
        <p className="text-center text-xs" style={{ color: 'var(--subtle)' }}>
          Vault contract{' '}
          <a href={buildAddressExplorerUrl(CHAIN_ID, VAULT_ADDRESS)} target="_blank" rel="noopener noreferrer" className="mono inline-flex items-center gap-1 hover:underline">
            {VAULT_ADDRESS} <ExternalLink className="size-3" aria-hidden />
          </a>{' '}
          · USDC <span className="mono">{USDC_ADDRESS}</span> on {CHAIN_NAME}
        </p>
      )}
    </div>
  )
}
