import type { ReactNode } from 'react'

interface LayoutProps {
  children: ReactNode
}

export function RootLayout({ children }: LayoutProps) {
  return (
    <div className="min-h-screen bg-background text-foreground">
      {children}
    </div>
  )
}

export function MainLayout({ children }: LayoutProps) {
  return (
    <div className="flex h-screen overflow-hidden">
      {children}
    </div>
  )
}

export function PageLayout({ children }: LayoutProps) {
  return (
    <div className="flex-1 overflow-y-auto">
      {children}
    </div>
  )
}
