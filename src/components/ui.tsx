import { Loader2 } from 'lucide-react'
import type { ButtonHTMLAttributes, CSSProperties, InputHTMLAttributes, ReactNode } from 'react'

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`glass-card rounded-[32px] p-6 sm:p-7 ${className}`}>{children}</section>
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <h3 className="text-[11px] font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>
      {children}
    </h3>
  )
}

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  busy?: boolean
  variant?: 'primary' | 'ghost' | 'danger'
}

export function Button({ busy, variant = 'primary', className = '', children, disabled, style, ...rest }: ButtonProps) {
  const base =
    'inline-flex min-h-11 items-center justify-center gap-2 rounded-2xl px-5 py-3 text-sm font-semibold transition-all active:scale-[0.99] disabled:cursor-not-allowed disabled:opacity-40'
  const looks: Record<NonNullable<ButtonProps['variant']>, CSSProperties> = {
    primary: { background: 'var(--accent)', color: 'var(--on-accent)' },
    danger: { background: 'var(--danger)', color: '#fff' },
    ghost: { background: 'var(--surface-strong)', border: '1px solid var(--border)', color: 'var(--ink)' },
  }
  return (
    <button
      {...rest}
      disabled={disabled || busy}
      className={`${base} ${variant === 'ghost' ? 'hover-surface' : 'hover:brightness-110'} ${className}`}
      style={{ ...looks[variant], ...style }}
    >
      {busy && <Loader2 className="size-4 animate-spin" aria-hidden />}
      {children}
    </button>
  )
}

interface ActionButtonProps extends ButtonProps {
  /** When set the button is disabled and this explains why. */
  reason?: string
}

/** A button that, when it cannot be used, says exactly why instead of just greying out. */
export function ActionButton({ reason, className = '', ...props }: ActionButtonProps) {
  return (
    <div className={className}>
      <Button {...props} disabled={Boolean(reason) || props.disabled} className="w-full" />
      {reason && (
        <p className="mt-1.5 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
          {reason}
        </p>
      )}
    </div>
  )
}

export type Tone = 'success' | 'warn' | 'danger' | 'neutral'

export const TONES: Record<Tone, { bg: string; fg: string }> = {
  success: { bg: 'var(--success-bg)', fg: 'var(--success)' },
  warn: { bg: 'var(--warn-bg)', fg: 'var(--warn)' },
  danger: { bg: 'var(--danger-bg)', fg: 'var(--danger)' },
  neutral: { bg: 'var(--neutral-bg)', fg: 'var(--ink-2)' },
}

export function StatusChip({ tone, children }: { tone: Tone; children: ReactNode }) {
  const t = TONES[tone]
  return (
    <span
      className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold"
      style={{ background: t.bg, color: t.fg }}
    >
      <span className="size-1.5 rounded-full" style={{ background: t.fg }} />
      {children}
    </span>
  )
}

export function Notice({ tone = 'neutral', children }: { tone?: Tone; children: ReactNode }) {
  const t = TONES[tone]
  return (
    <p className="rounded-2xl px-4 py-3 text-sm text-pretty" style={{ background: t.bg, color: t.fg }}>
      {children}
    </p>
  )
}

interface TextFieldProps extends InputHTMLAttributes<HTMLInputElement> {
  label: string
  hint?: string
  error?: string
}

export function TextField({ label, hint, error, className = '', ...rest }: TextFieldProps) {
  return (
    <label className={`block ${className}`}>
      <span className="mb-1 block text-xs font-semibold" style={{ color: 'var(--muted)' }}>
        {label}
      </span>
      <input
        {...rest}
        className="input-base min-h-11 w-full rounded-xl px-3 text-sm outline-none"
        aria-invalid={error ? true : undefined}
      />
      {error ? (
        <span className="mt-1 block text-xs" style={{ color: 'var(--danger)' }}>
          {error}
        </span>
      ) : (
        hint && (
          <span className="mt-1 block text-xs" style={{ color: 'var(--subtle)' }}>
            {hint}
          </span>
        )
      )}
    </label>
  )
}

interface AmountFieldProps {
  value: string
  onChange: (value: string) => void
  maxLabel?: string
  onMax?: () => void
}

/** Big USDC amount input (up to 6 decimals). */
export function AmountField({ value, onChange, maxLabel, onMax }: AmountFieldProps) {
  return (
    <div className="glass-inner rounded-2xl p-4">
      <input
        inputMode="decimal"
        aria-label="USDC amount"
        value={value}
        onChange={(e) => {
          const v = e.target.value
          if (v === '' || /^\d*\.?\d{0,6}$/.test(v)) onChange(v)
        }}
        placeholder="0.00"
        className="display w-full bg-transparent text-4xl font-bold tabular-nums outline-none placeholder:opacity-40"
        style={{ color: 'var(--ink)' }}
      />
      <div className="mt-2 flex items-center justify-between">
        <span className="text-xs" style={{ color: 'var(--subtle)' }}>
          USDC
        </span>
        {maxLabel && onMax && (
          <button type="button" onClick={onMax} className="text-xs font-semibold" style={{ color: 'var(--accent-hover)' }}>
            {maxLabel}
          </button>
        )}
      </div>
    </div>
  )
}
