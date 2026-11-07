'use client'

interface SugestoesTextoProps {
  sugestoes: readonly string[]
  onInserir: (sugestao: string) => void
  disabled?: boolean
  titulo?: string
  className?: string
}

/**
 * Atalhos opt-in para campos de texto.
 *
 * O componente não escolhe, não preenche ao montar e não confirma o campo. A frase
 * só chega ao formulário depois de um toque explícito e continua editável.
 */
export function SugestoesTexto({
  sugestoes,
  onInserir,
  disabled = false,
  titulo = 'Sugestões',
  className = '',
}: SugestoesTextoProps) {
  if (sugestoes.length === 0) return null

  return (
    <div className={`space-y-1.5 ${className}`}>
      <p className="text-[11px] font-bold text-text-muted">{titulo}</p>
      <div className="flex flex-wrap gap-1.5" role="group" aria-label={titulo}>
        {sugestoes.map((sugestao) => (
          <button
            key={sugestao}
            type="button"
            disabled={disabled}
            onClick={() => onInserir(sugestao)}
            className="min-h-8 rounded-sm border border-border bg-surface-alt px-2.5 py-1 text-left text-xs font-medium text-foreground transition-colors hover:border-primary hover:bg-primary-ghost disabled:cursor-not-allowed disabled:opacity-50"
          >
            {sugestao}
          </button>
        ))}
      </div>
    </div>
  )
}
