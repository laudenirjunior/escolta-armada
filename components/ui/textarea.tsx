import type { TextareaHTMLAttributes } from 'react'

interface TextareaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {}

export function Textarea({ className = '', ...props }: TextareaProps) {
  return (
    <textarea
      className={`
        w-full min-h-[80px] px-3 py-2 rounded-sm text-sm
        bg-surface-alt border border-border text-foreground
        placeholder:text-white/30
        focus:outline-none focus:ring-2 focus:ring-primary/50
        disabled:opacity-50 disabled:cursor-not-allowed resize-none
        ${className}
      `}
      {...props}
    />
  )
}
