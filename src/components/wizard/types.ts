import type { StepErrors, WizardState } from '@/lib/wizard'

export interface StepProps {
  state: WizardState
  update: (patch: Partial<WizardState>) => void
  errors: StepErrors
  demo: boolean
}
