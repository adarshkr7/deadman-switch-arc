import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'

export type Theme = 'light' | 'dark'

interface PrefsValue {
  theme: Theme
  toggleTheme: () => void
  /** Demo mode: the create wizard offers 60-second-scale windows instead of days. */
  demo: boolean
  setDemo: (value: boolean) => void
}

const PrefsContext = createContext<PrefsValue | null>(null)

function initialTheme(): Theme {
  try {
    const saved = localStorage.getItem('theme')
    if (saved === 'light' || saved === 'dark') return saved
  } catch {
    // storage unavailable: fall through to the system preference
  }
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function initialDemo(): boolean {
  try {
    return localStorage.getItem('demo-mode') === '1'
  } catch {
    return false
  }
}

export function PrefsProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState<Theme>(initialTheme)
  const [demo, setDemoState] = useState<boolean>(initialDemo)

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    try {
      localStorage.setItem('theme', theme)
    } catch {
      // ignore
    }
  }, [theme])

  const toggleTheme = useCallback(() => setTheme((t) => (t === 'dark' ? 'light' : 'dark')), [])
  const setDemo = useCallback((value: boolean) => {
    setDemoState(value)
    try {
      localStorage.setItem('demo-mode', value ? '1' : '0')
    } catch {
      // ignore
    }
  }, [])

  const value = useMemo(() => ({ theme, toggleTheme, demo, setDemo }), [theme, toggleTheme, demo, setDemo])
  return <PrefsContext.Provider value={value}>{children}</PrefsContext.Provider>
}

export function usePrefs(): PrefsValue {
  const ctx = useContext(PrefsContext)
  if (!ctx) throw new Error('usePrefs must be used inside PrefsProvider')
  return ctx
}
