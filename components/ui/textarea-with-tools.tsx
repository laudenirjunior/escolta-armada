'use client'

import { AiTextButton } from './ai-text-button'

interface TextAreaWithToolsProps {
  value: string
  onChange: (v: string) => void
  placeholder?: string
  rows?: number
  disabled?: boolean
  contextoAI?: string
  style?: React.CSSProperties
  className?: string
  textareaClassName?: string
  textareaStyle?: React.CSSProperties
}

export function TextAreaWithTools({
  value,
  onChange,
  placeholder = 'Digite aqui...',
  rows = 3,
  disabled = false,
  contextoAI,
  style,
  className,
  textareaClassName,
  textareaStyle,
}: TextAreaWithToolsProps) {
  const defaultTextareaStyle: React.CSSProperties = textareaClassName ? {} : {
    width: '100%',
    padding: '8px 12px',
    backgroundColor: 'rgba(255,255,255,0.05)',
    border: '1px solid rgba(255,255,255,0.1)',
    borderRadius: '2px',
    color: '#fff',
    fontSize: '13px',
    resize: 'vertical',
    outline: 'none',
    fontFamily: 'inherit',
    lineHeight: 1.5,
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '4px', ...style }} className={className}>
      {/* Barra de ferramentas */}
      <div style={{ display: 'flex', alignItems: 'center', gap: '4px', justifyContent: 'flex-end' }}>
        <AiTextButton value={value} onChange={onChange} contexto={contextoAI} disabled={disabled} />
      </div>

      <textarea
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        rows={rows}
        disabled={disabled}
        className={textareaClassName}
        style={{ ...defaultTextareaStyle, ...textareaStyle }}
      />
    </div>
  )
}
