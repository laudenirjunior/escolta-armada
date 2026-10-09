'use client'

/**
 * Escoltas arquivadas (lote 2026-10, onda I, decisão 1 do adendo: arquivar, nunca apagar).
 * Só o administrador: a RLS (migration 214) esconde a escolta arquivada de todos os outros.
 * Mostra motivo, autor e data, e recupera pela RPC recuperar_escolta (218), com motivo.
 */
import { useCallback, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { Archive, Eye, Undo2 } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_VER_ARQUIVADAS, temPermissao } from '@/lib/permissions'
import { rotuloStatus } from '@/lib/fluxo-escolta'
import { MSG_ATUALIZACAO, ehFuncaoAusente, horaBR } from '@/lib/gestao'
import { CartaoEscolta } from '@/components/escolta/cartao-escolta'
import { SELECT_CARTAO, type CartaoEscolta as CartaoDados } from '@/lib/cartao-escolta'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

// Onda K: o cartão padrão (com a etiqueta Arquivada, só do administrador) mais motivo e autor.
interface Arquivada extends CartaoDados {
  arquivada_em: string; motivo_arquivamento: string | null
  arquivador: { nome_completo: string } | null
}

export default function ArquivadasPage() {
  const router = useRouter()
  const { user } = useAuth()
  const podeVer = temPermissao(user?.perfil?.codigo, PODE_VER_ARQUIVADAS)
  const [lista, setLista] = useState<Arquivada[]>([])
  const [carregando, setCarregando] = useState(true)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const [recuperando, setRecuperando] = useState<Arquivada | null>(null)
  const [motivo, setMotivo] = useState('')
  const [enviando, setEnviando] = useState(false)

  const carregar = useCallback(async () => {
    setCarregando(true)
    const { data, error } = await sb.from('escoltas')
      .select(`${SELECT_CARTAO}, motivo_arquivamento, arquivador:usuarios!arquivada_por(nome_completo)`)
      .not('arquivada_em', 'is', null)
      .order('arquivada_em', { ascending: false })
    if (error) setMsg({ ok: false, texto: error.message })
    setLista((data ?? []) as Arquivada[])
    setCarregando(false)
  }, [])

  useEffect(() => { if (podeVer) carregar() }, [podeVer, carregar])

  const recuperar = async () => {
    if (!recuperando) return
    setEnviando(true); setMsg(null)
    const { error } = await sb.rpc('recuperar_escolta', { p_escolta_id: recuperando.id, p_motivo: motivo.trim() })
    setEnviando(false)
    if (error) { setMsg({ ok: false, texto: ehFuncaoAusente(error) ? MSG_ATUALIZACAO : error.message }); return }
    setMsg({ ok: true, texto: `Escolta ${recuperando.codigo_escolta ?? ''} recuperada; voltou em ${rotuloStatus(recuperando.status)}.` })
    setRecuperando(null); setMotivo('')
    carregar()
  }

  if (!user) return null
  if (!podeVer) return <div className="p-6 text-sm">Acesso restrito ao administrador.</div>

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Archive size={20} style={{ color: '#1E2D35' }} />
        <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Escoltas arquivadas</h1>
      </div>
      <p className="text-sm" style={{ color: '#5A6A80' }}>Arquivadas pela gestão: fora das listas, do mural, do Campo, do mapa e dos indicadores. Nada foi apagado. Ao recuperar, a escolta volta no status em que estava.</p>
      {msg && (
        <div className="p-3 text-sm" data-teste="msg-arquivadas" style={{ backgroundColor: msg.ok ? '#E8F5EE' : 'rgba(184,56,50,0.08)', color: msg.ok ? '#1E7C52' : '#B83832', borderRadius: '4px' }}>{msg.texto}</div>
      )}
      {carregando ? <p className="text-sm" style={{ color: '#6B7E8A' }}>Carregando…</p>
        : lista.length === 0 ? <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhuma escolta arquivada.</p>
        : (
          <div className="space-y-2">
            {lista.map(e => (
              <div key={e.id} className="p-4 bg-white" style={{ border: '1px solid #D4D9E6', borderRadius: '4px' }} data-teste="arquivada">
                <CartaoEscolta variante="cartao" escolta={e} perfil={user?.perfil?.codigo} />
                <p className="text-sm mt-1" style={{ color: '#5A6A80' }}>Arquivada em {horaBR(e.arquivada_em)} (Brasília){e.arquivador?.nome_completo ? ` por ${e.arquivador.nome_completo}` : ''}.</p>
                <p className="text-sm mt-1"><strong>Motivo:</strong> {e.motivo_arquivamento ?? '-'}</p>
                <div className="mt-3 flex gap-2">
                  <button type="button" onClick={() => router.push(`/dashboard/escoltas/${e.id}`)} className="flex-1 flex items-center justify-center gap-1 text-xs font-bold" style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}><Eye size={14} /> Abrir</button>
                  <button type="button" onClick={() => { setRecuperando(e); setMotivo('') }} className="flex-1 flex items-center justify-center gap-1 text-xs font-black uppercase text-white" style={{ minHeight: '44px', backgroundColor: '#1A294A' }} data-teste="recuperar"><Undo2 size={14} /> Recuperar</button>
                </div>
                {recuperando?.id === e.id && (
                  <div className="mt-3 space-y-2">
                    <textarea value={motivo} onChange={ev => setMotivo(ev.target.value)} rows={2} className="input-light w-full text-sm" placeholder="Motivo da recuperação (mínimo de 10 caracteres)" data-teste="motivo-recuperar" />
                    <div className="flex gap-2">
                      <button type="button" onClick={recuperar} disabled={enviando || motivo.trim().length < 10} className="flex-1 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '44px', backgroundColor: '#1E7C52' }} data-teste="confirmar-recuperar">{enviando ? 'Recuperando…' : 'Confirmar recuperação'}</button>
                      <button type="button" onClick={() => setRecuperando(null)} className="flex-1 text-xs font-bold" style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>Cancelar</button>
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
    </div>
  )
}
