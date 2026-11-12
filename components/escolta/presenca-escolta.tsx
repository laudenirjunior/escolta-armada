'use client'

/**
 * Barra de presença da escolta (pedido de Peçanha em 2026-11-12): quem mais está com a escolta
 * aberta agora, com nome, perfil e avatar de iniciais, e quem está com uma janela de ação
 * aberta ("editando").
 *
 * Usa o Presence do Supabase Realtime num canal por escolta (escolta:<id>), sem tabela e sem
 * migration. Cada aba entra com uma chave própria; a barra junta as abas do mesmo usuário e
 * não mostra o próprio usuário (agruparPresenca, lib/concorrencia.ts). A aba sai do canal ao
 * sair da tela (unmount), ao ficar escondida (troca de aba, celular bloqueado) e ao fechar;
 * volta quando fica visível de novo.
 *
 * O canal é público para quem tem a chave anon do projeto e sabe o id da escolta: só nome e
 * perfil de quem está olhando trafegam por ele (nada da escolta). Ver docs/12, pendências.
 */
import { useEffect, useMemo, useRef, useState } from 'react'
import type { RealtimeChannel } from '@supabase/supabase-js'
import { createClient } from '@/lib/supabase/client'
import { agruparPresenca, rotuloPresenca, type MetaPresenca, type PessoaPresente } from '@/lib/concorrencia'

const C = { navy: '#1A294A', sub: '#5A6A80', border: '#D4D9E6', amber: '#B7791F', bgAmber: '#FFF7E6', surface: '#F5F7FA' }

export interface EuNaPresenca {
  id: string
  nome: string
  perfil: string | null
}

export function usePresencaEscolta(escoltaId: string | null | undefined, eu: EuNaPresenca | null, editando: boolean): PessoaPresente[] {
  const [estado, setEstado] = useState<Record<string, MetaPresenca[]>>({})
  const canalRef = useRef<RealtimeChannel | null>(null)
  const inscritoRef = useRef(false)
  const abaRef = useRef(`${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`)
  const desdeRef = useRef(new Date().toISOString())
  const editandoRef = useRef(editando)
  editandoRef.current = editando

  const euId = eu?.id ?? null
  const euNome = eu?.nome ?? ''
  const euPerfil = eu?.perfil ?? null

  useEffect(() => {
    if (!escoltaId || !euId) return
    const sb = createClient()
    const canal = sb.channel(`escolta:${escoltaId}`, { config: { presence: { key: abaRef.current } } })
    canalRef.current = canal
    const meta = (): MetaPresenca => ({
      usuario_id: euId, nome: euNome, perfil: euPerfil, editando: editandoRef.current, desde: desdeRef.current, aba: abaRef.current,
    })
    const entrar = () => { if (inscritoRef.current && document.visibilityState === 'visible') void canal.track({ ...meta() }) }
    const sair = () => { if (inscritoRef.current) void canal.untrack() }
    const sincronizar = () => setEstado({ ...(canal.presenceState() as unknown as Record<string, MetaPresenca[]>) })

    canal
      .on('presence', { event: 'sync' }, sincronizar)
      .on('presence', { event: 'join' }, sincronizar)
      .on('presence', { event: 'leave' }, sincronizar)
      .subscribe((status) => {
        inscritoRef.current = status === 'SUBSCRIBED'
        if (inscritoRef.current) entrar()
      })

    const aoMudarVisibilidade = () => { if (document.visibilityState === 'visible') entrar(); else sair() }
    document.addEventListener('visibilitychange', aoMudarVisibilidade)
    window.addEventListener('pagehide', sair)
    return () => {
      document.removeEventListener('visibilitychange', aoMudarVisibilidade)
      window.removeEventListener('pagehide', sair)
      sair()
      inscritoRef.current = false
      canalRef.current = null
      void sb.removeChannel(canal)
      setEstado({})
    }
  }, [escoltaId, euId, euNome, euPerfil])

  // Abriu ou fechou uma janela de ação: publica o novo estado (mesma chave, substitui o anterior).
  useEffect(() => {
    const canal = canalRef.current
    if (!canal || !inscritoRef.current || !euId || document.visibilityState !== 'visible') return
    void canal.track({
      usuario_id: euId, nome: euNome, perfil: euPerfil, editando, desde: desdeRef.current, aba: abaRef.current,
    })
  }, [editando, euId, euNome, euPerfil])

  return useMemo(() => agruparPresenca(estado, euId), [estado, euId])
}

export function BarraPresenca({ pessoas }: { pessoas: PessoaPresente[] }) {
  if (pessoas.length === 0) return null
  return (
    <div className="flex flex-wrap items-center gap-2 px-3 py-2 text-xs" data-teste="barra-presenca"
      style={{ backgroundColor: C.surface, border: `1px solid ${C.border}`, borderRadius: '2px', color: C.sub }}>
      <span className="font-bold uppercase tracking-wider text-[10px]">Também com esta escolta aberta:</span>
      {pessoas.map(p => (
        <span key={p.usuarioId} className="inline-flex items-center gap-1.5" title={rotuloPresenca(p)} data-teste="presenca-pessoa">
          <span className="inline-flex items-center justify-center text-[10px] font-black text-white"
            style={{ width: 22, height: 22, borderRadius: '50%', backgroundColor: C.navy,
              boxShadow: p.editando ? `0 0 0 2px ${C.amber}` : undefined }}>
            {p.iniciais}
          </span>
          <span style={{ color: C.navy }} className="font-semibold">{p.nome}</span>
          {p.perfil && <span>({p.perfil})</span>}
          {p.editando && (
            <span className="text-[10px] font-bold px-1" style={{ backgroundColor: C.bgAmber, color: C.amber, borderRadius: '2px' }}>editando</span>
          )}
        </span>
      ))}
    </div>
  )
}
