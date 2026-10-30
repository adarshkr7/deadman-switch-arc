import { shortAddress, bpsToPercent } from '@/lib/format'
import { summarize, toParams } from '@/lib/wizard'
import { Notice, SectionLabel } from '@/components/ui'
import type { StepProps } from '@/components/wizard/types'

export function StepReview({ state, demo }: StepProps) {
  const params = toParams(state, demo)
  if (!params) return <Notice tone="warn">Some details are incomplete. Go back and check each step.</Notice>
  const lines = summarize(params)

  return (
    <div className="flex flex-col gap-5">
      {demo && <Notice tone="warn">Demo vault: short windows, for testing only.</Notice>}
      <div>
        <SectionLabel>What this vault will do</SectionLabel>
        <ul className="mt-3 flex flex-col gap-2.5">
          {lines.map((line) => (
            <li key={line} className="glass-inner rounded-2xl px-4 py-3 text-sm text-pretty">
              {line}
            </li>
          ))}
        </ul>
      </div>
      <div>
        <SectionLabel>Beneficiaries</SectionLabel>
        <ul className="mt-3 flex flex-col gap-1.5">
          {params.beneficiaries.map((b, i) => (
            <li key={b} className="flex items-center justify-between text-sm">
              <span className="mono">{shortAddress(b)}</span>
              <span className="display font-bold tabular-nums">{bpsToPercent(params.sharesBps[i])}%</span>
            </li>
          ))}
        </ul>
      </div>
      <Notice tone="danger">
        Beneficiaries, shares, guardians and the fallback address cannot be changed after the vault is created.
      </Notice>
    </div>
  )
}
