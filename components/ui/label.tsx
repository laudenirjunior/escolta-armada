interface LabelProps extends React.LabelHTMLAttributes<HTMLLabelElement> {
  children: React.ReactNode
}

export function Label({ children, className = '', ...props }: LabelProps) {
  return (
    <label
      className={`
        text-[11px] font-black uppercase tracking-widest text-slate-500
        block mb-1
        ${className}
      `}
      {...props}
    >
      {children}
    </label>
  )
}
