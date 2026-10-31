import { useId } from 'react'
import type { UiState } from '@/lib/phase'

/** red, orange, yellow: the three stops every shape is painted with. */
const PALETTES: Record<UiState, [string, string, string]> = {
  active: ['#ff3d14', '#ff7a1a', '#f7a531'],
  warning: ['#ff1f1f', '#ff4a1c', '#ff8a3a'],
  challenge: ['#ff5a14', '#ff9a1f', '#ffc95a'],
  triggered: ['#ff3d14', '#ff7a1a', '#f7a531'],
  swept: ['#a8361a', '#c26a22', '#d39a4a'],
}

interface GrainArtProps {
  /** "wave": the large flowing swirl; "swirl": the S-curve split used for thumbnails. */
  variant: 'wave' | 'swirl'
  state: UiState
  className?: string
}

/** Grainy orange gradient artwork on black: soft-edged shapes plus a film-grain layer. */
export function GrainArt({ variant, state, className = '' }: GrainArtProps) {
  const id = useId().replace(/:/g, '')
  const [red, orange, yellow] = PALETTES[state]
  const dim = state === 'swept' ? 0.7 : 1

  return (
    <svg
      className={`grain-svg ${className}`}
      viewBox={variant === 'wave' ? '0 0 400 500' : '0 0 200 200'}
      preserveAspectRatio="xMidYMid slice"
      aria-hidden
    >
      <defs>
        <linearGradient id={`hot-${id}`} x1="0" y1="1" x2="1" y2="0">
          <stop offset="0" stopColor={red} />
          <stop offset="0.55" stopColor={orange} />
          <stop offset="1" stopColor={yellow} />
        </linearGradient>
        <linearGradient id={`warm-${id}`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor={yellow} />
          <stop offset="1" stopColor={orange} />
        </linearGradient>
        <filter id={`soft-${id}`} filterUnits="userSpaceOnUse" x="-200" y="-200" width="800" height="900">
          <feGaussianBlur stdDeviation={variant === 'wave' ? 26 : 11} />
        </filter>
        <filter id={`grain-${id}`} x="0" y="0" width="100%" height="100%">
          <feTurbulence type="fractalNoise" baseFrequency={variant === 'wave' ? 1.1 : 1.6} numOctaves="3" stitchTiles="stitch" />
          <feColorMatrix type="matrix" values="1 0 0 0 0  1 0 0 0 0  1 0 0 0 0  0 0 0 0 0.55" />
        </filter>
      </defs>

      <rect width="100%" height="100%" fill="#0b0b0c" />

      {variant === 'wave' ? (
        <g filter={`url(#soft-${id})`} opacity={dim} className="grain-drift">
          {/* deep red mass low on the left */}
          <path d="M-80 330 C-10 300 50 345 95 390 C135 430 120 500 40 530 L-80 530 Z" fill={red} opacity="0.95" />
          {/* the folded ribbon: red at the bottom left, orange through the middle, yellow at the top right */}
          <path
            d="M-60 280 C20 230 90 270 150 250 C220 225 250 150 320 100 C370 65 430 70 460 95 L460 175 C400 175 350 215 310 270 C260 335 190 365 120 355 C60 348 0 335 -60 345 Z"
            fill={`url(#hot-${id})`}
          />
          {/* bright crest */}
          <path d="M190 215 C235 170 270 118 325 100 C360 90 390 98 395 118 C350 130 305 172 268 218 C240 250 210 248 190 215 Z" fill={`url(#warm-${id})`} opacity="0.9" />
          {/* soft dark fold inside the swirl */}
          <ellipse cx="215" cy="300" rx="62" ry="30" fill="#0b0b0c" opacity="0.6" transform="rotate(-30 215 300)" />
          {/* orange lobe on the right */}
          <path d="M310 345 C345 320 390 315 460 322 L460 395 C405 392 365 405 338 440 C318 415 300 370 310 345 Z" fill={red} opacity="0.85" />
        </g>
      ) : (
        <g opacity={dim}>
          {/* dark red glow along the S boundary */}
          <path d="M128 -20 C72 30 160 85 110 135 C80 165 114 196 126 225" fill="none" stroke={red} strokeWidth="46" opacity="0.75" filter={`url(#soft-${id})`} />
          {/* bright orange field to the right of the S */}
          <path d="M146 -20 C92 30 180 85 130 135 C102 163 134 196 146 225 L230 225 L230 -20 Z" fill={`url(#warm-${id})`} filter={`url(#soft-${id})`} />
          {/* slight shading in the bottom-right corner */}
          <ellipse cx="200" cy="205" rx="60" ry="40" fill={red} opacity="0.35" filter={`url(#soft-${id})`} />
        </g>
      )}

      <rect width="100%" height="100%" filter={`url(#grain-${id})`} opacity="0.7" style={{ mixBlendMode: 'overlay' }} />
    </svg>
  )
}
