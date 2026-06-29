'use client'

import { useState } from 'react'
import { Sparkles, Loader2 } from 'lucide-react'

interface AiTextButtonProps {
  value: string
  onChange: (newValue: string) => void
  contexto?: string
  style?: React.CSSProperties
  className?: string
  disabled?: boolean
}

export function AiTextButton({ value, onChange, contexto, style, className, disabled }: AiTextButtonProps) {
  const [loading, setLoading] = useState(false)
  const [erro, setErro] = useState(false)

  const melhorar = async () => {
    if (!value.trim() || loading) return
    setLoading(true)
    setErro(false)
    try {
      const resp = await fetch('/api/ai/melhorar-texto', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ texto: value, contexto }),
      })
      if (!resp.ok) { setErro(true); return }
      const { melhorado } = await resp.json()
      if (melhorado) onChange(melhorado)
    } catch {
      setErro(true)
    } finally {
      setLoading(false)
      if (erro) setTimeout(() => setErro(false), 2000)
    }
  }

  return (
    <button
      type="button"
      onClick={melhorar}
      disabled={!value.trim() || loading || disabled}
      title="Melhorar texto com IA"
      className={className}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '4px',
        height: '28px',
        padding: '0 10px',
        borderRadius: '2px',
        fontSize: '10px',
        fontWeight: 900,
        textTransform: 'uppercase',
        letterSpacing: '0.1em',
        border: erro ? '1px solid #B83832' : '1px solid rgba(83,100,138,0.3)',
        backgroundColor: erro ? 'rgba(184,56,50,0.1)' : loading ? 'rgba(83,100,138,0.15)' : 'rgba(83,100,138,0.08)',
        color: erro ? '#B83832' : '#53648A',
        cursor: !value.trim() || loading || disabled ? 'not-allowed' : 'pointer',
        opacity: !value.trim() || disabled ? 0.5 : 1,
        transition: 'all 150ms',
        flexShrink: 0,
        ...style,
      }}
    >
      {loading ? (
        <Loader2 size={11} style={{ animation: 'spin 1s linear infinite' }} />
      ) : (
        <Sparkles size={11} />
      )}
      {erro ? 'Erro' : loading ? 'Melhorando...' : 'IA'}
    </button>
  )
}
