'use client'

/**
 * Onda O (A1): faixa de andamento da gravação ("Enviando foto 3 de 7", "Gravando no sistema").
 *
 * No teste de 07/11 a tela ficou 25 s em "Iniciando..." sem mudar nada e parecia travada. A
 * faixa fica por cima das janelas, perto do polegar, e anuncia cada passo para leitor de tela.
 * Sem texto, não ocupa espaço.
 */
import { Loader2 } from 'lucide-react'

export function FaixaAndamento({ texto }: { texto: string | null | undefined }) {
  if (!texto) return null
  return (
    <div
      role="status"
      aria-live="polite"
      data-andamento
      className="fixed left-1/2 -translate-x-1/2 bottom-4 z-[100000] flex items-center gap-2 px-4 py-2.5 text-white shadow-lg"
      style={{ backgroundColor: '#0E1A33', fontSize: '12px', fontWeight: 700, maxWidth: 'calc(100vw - 32px)' }}
    >
      <Loader2 size={14} className="animate-spin shrink-0" aria-hidden />
      <span>{texto}</span>
    </div>
  )
}
