'use client'

/**
 * "Estou na base" no Painel Guiado (T2, lote 2026-10). Aparece para a equipe escalada
 * a partir do início da janela; depois de confirmado, ninguém assume a escolta.
 */
import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, Clock } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { InfoMural, lerInfoMural, confirmarPresencaBase, horaBrasilia } from '@/lib/mural'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

export function EstouNaBase({ escoltaId }: { escoltaId: string }) {
  const [info, setInfo] = useState<InfoMural | null>(null)
  const [ativo, setAtivo] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const carregar = useCallback(async () => {
    const lido = await lerInfoMural(sb, [escoltaId])
    setAtivo(lido.ativo)
    setInfo(lido.info[escoltaId] ?? null)
  }, [escoltaId])
  useEffect(() => {
    carregar()
    const t = setInterval(carregar, 30_000)
    return () => clearInterval(t)
  }, [carregar])

  if (!ativo || !info) return null
  if (info.eu_confirmei) {
    return (
      <p className="flex items-center gap-2 font-bold" style={{ fontSize: '16px', color: '#1E7C52' }}>
        <CheckCircle2 size={18} /> Presença na base confirmada
      </p>
    )
  }
  if (Date.now() < new Date(info.janela_inicio).getTime()) {
    return (
      <p className="flex items-center gap-2" style={{ fontSize: '15px', color: '#5A6A80' }}>
        <Clock size={16} /> Confirmação de presença na base a partir das {horaBrasilia(info.janela_inicio)}
      </p>
    )
  }
  return (
    <div className="space-y-2">
      <button type="button" disabled={enviando}
        onClick={async () => {
          setEnviando(true)
          const erro = await confirmarPresencaBase(sb, escoltaId)
          setMsg(erro ? { ok: false, texto: erro } : { ok: true, texto: 'Presença confirmada.' })
          setEnviando(false)
          await carregar()
        }}
        className="w-full flex items-center justify-center gap-2 font-black uppercase text-white disabled:opacity-50"
        style={{ minHeight: '56px', fontSize: '16px', backgroundColor: '#1E7C52', borderRadius: '4px' }}>
        <CheckCircle2 size={20} /> {enviando ? 'Confirmando...' : 'Estou na base'}
      </button>
      {msg && <p style={{ fontSize: '14px', color: msg.ok ? '#1E7C52' : '#B83832' }}>{msg.texto}</p>}
    </div>
  )
}
