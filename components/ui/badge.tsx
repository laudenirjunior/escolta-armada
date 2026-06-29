import type { ReactNode } from 'react'

interface BadgeProps {
  children: ReactNode
  variant?: 'default' | 'success' | 'warning' | 'error' | 'info' | 'pending'
  className?: string
}

const variantStyles = {
  default: 'bg-primary-ghost text-primary',
  success: 'bg-emerald-500/10 text-emerald-500',
  warning: 'bg-amber-100 text-amber-700',
  error: 'bg-red-500/10 text-red-500',
  info: 'bg-blue-500/10 text-blue-500',
  pending: 'bg-amber-100 text-amber-700',
}

export function Badge({ children, variant = 'default', className = '' }: BadgeProps) {
  return (
    <span
      className={`
        inline-flex h-5 items-center justify-center gap-1 px-2 py-0.5
        text-[10px] font-black uppercase tracking-[0.15em]
        border border-transparent rounded-sm
        ${variantStyles[variant]}
        ${className}
      `}
    >
      {children}
    </span>
  )
}
