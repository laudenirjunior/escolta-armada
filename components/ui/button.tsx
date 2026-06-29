import type { ReactNode } from 'react'

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  children: ReactNode
  variant?: 'default' | 'outline' | 'secondary' | 'ghost' | 'destructive'
  size?: 'default' | 'xs' | 'sm' | 'lg' | 'icon' | 'icon-xs' | 'icon-sm'
}

const variantStyles = {
  default: 'bg-primary text-white hover:bg-primary-dark shadow-md',
  outline: 'border border-border text-foreground hover:bg-surface-alt',
  secondary: 'bg-primary-light text-white hover:bg-primary',
  ghost: 'hover:bg-primary-ghost text-foreground',
  destructive: 'bg-red-500/10 text-red-500 hover:bg-red-500/20',
}

const sizeStyles = {
  default: 'h-8 px-3 py-2 text-sm',
  xs: 'h-6 px-2 text-xs',
  sm: 'h-7 px-2.5 text-[0.8rem]',
  lg: 'h-9 px-4 text-base',
  icon: 'h-8 w-8',
  'icon-xs': 'h-6 w-6',
  'icon-sm': 'h-7 w-7',
}

export function Button({
  children,
  variant = 'default',
  size = 'default',
  className = '',
  ...props
}: ButtonProps) {
  return (
    <button
      className={`
        rounded-sm font-medium transition-colors
        focus:outline-none focus:ring-2 focus:ring-primary/50
        active:translate-y-px disabled:opacity-50 disabled:cursor-not-allowed
        ${variantStyles[variant]}
        ${sizeStyles[size]}
        ${className}
      `}
      {...props}
    >
      {children}
    </button>
  )
}
