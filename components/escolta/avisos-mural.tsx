'use client'

/**
 * Avisos do mural no aplicativo (T4, lote 2026-10): pedido de substituição para a
 * supervisão, decisão para quem pediu e substituição para a equipe substituída.
 * "Ciente" marca como lido pela RPC marcar_aviso_lido, que só altera o próprio aviso, e
 * atualiza na hora o sino e o item Avisos (contador do AvisosProvider, onda J).
 */
import { useCallback, useEffect, useState } from 'react'
import { BellRing, Check } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAvisos } from '@/components/avisos-provider'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface AvisoMural { id: string; escolta_id: string; titulo: string; texto: string; criado_em: string; tipo: string }

export function AvisosMural({ intervaloMs = 30_000 }: { intervaloMs?: number }) {
  const [avisos, setAvisos] = useState<AvisoMural[]>([])
  const { atualizar } = useAvisos()
  const carregar = useCallback(async () => {
    const { data, error } = await sb.rpc('meus_avisos_mural')
    if (!error) setAvisos((data ?? []) as AvisoMural[])
  }, [])
  useEffect(() => {
    carregar()
    const t = setInterval(carregar, intervaloMs)
    return () => clearInterval(t)
  }, [carregar, intervaloMs])

  const ciente = async (id: string) => {
    setAvisos(a => a.filter(x => x.id !== id))
    await sb.rpc('marcar_aviso_lido', { p_notificacao_id: id })
    atualizar()
  }

  if (avisos.length === 0) return null
  return (
    <div className="space-y-2 mb-4" data-teste="avisos-mural">
      {avisos.map(a => (
        <div key={a.id} className="flex items-start gap-3 p-3" style={{ backgroundColor: '#FFF7E6', border: '1.5px solid #C8813A', borderRadius: '4px' }}>
          <BellRing size={16} style={{ color: '#8A5A10', flexShrink: 0, marginTop: 2 }} />
          <div className="flex-1 min-w-0">
            <p className="text-xs font-black uppercase tracking-wider" style={{ color: '#8A5A10' }}>{a.titulo}</p>
            <p className="text-sm mt-1" style={{ color: '#1E2D35' }}>{a.texto}</p>
            <p className="text-[10px] mt-1" style={{ color: '#6B7E8A' }}>
              {new Date(a.criado_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }).replace(',', '')}
            </p>
          </div>
          <button type="button" onClick={() => ciente(a.id)} className="flex items-center gap-1 text-xs font-bold px-3"
            style={{ minHeight: '40px', border: '1px solid #C8813A', color: '#8A5A10', borderRadius: '4px' }}>
            <Check size={14} /> Ciente
          </button>
        </div>
      ))}
    </div>
  )
}
