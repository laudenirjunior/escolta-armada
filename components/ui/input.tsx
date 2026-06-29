interface InputProps extends React.InputHTMLAttributes<HTMLInputElement> {
  error?: boolean
}

export function Input({ error = false, className = '', ...props }: InputProps) {
  return (
    <input
      className={`
        h-8 w-full rounded-sm border bg-transparent px-2.5 py-1 text-sm
        font-sans transition-colors outline-none
        border-border focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/50
        placeholder:text-text-muted disabled:cursor-not-allowed disabled:opacity-50
        ${error ? 'border-red-500 ring-2 ring-red-500/20' : ''}
        ${className}
      `}
      {...props}
    />
  )
}
