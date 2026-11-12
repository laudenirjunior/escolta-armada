'use client'

/**
 * Escoltas excluídas (controle total, pedido de Peçanha em 2026-11-12). Só gestor e
 * administrador. A exclusão é lógica (migration 221): a RLS esconde a escolta excluída de
 * todos os perfis no SELECT direto, e esta tela lê pela RPC listar_escoltas_excluidas. Desfazer
 * (restaurar_escolta_excluida) devolve a escolta para Arquivadas, de onde sai por Recuperar.
 * Sem a migration 221 as RPCs não existem: a tela mostra o aviso e nada mais.
 */
import { useCallback, useEffect, useState } from 'react'
import { Trash2, Undo2, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { rotuloStatus } from '@/lib/fluxo-escolta'
import { ehFuncaoAusente, horaBR } from '@/lib/gestao'
import { MOTIVO_MINIMO, MSG_DEPENDE_221, podeExcluirEscolta } from '@/lib/controle-total'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface Excluida {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string | null
  origem_endereco: string | null
  destino_endereco: string | null
  cliente: string | null
  excluida_em: string
  motivo_exclusao: string | null
  excluida_por: string | null
}

export default function ExcluidasPage() {
  const { user } = useAuth()
  const podeVer = podeExcluirEscolta(user?.perfil?.codigo)
  const [lista, setLista] = useState<Excluida[]>([])
  const [carregando, setCarregando] = useState(true)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const [restaurando, setRestaurando] = useState<Excluida | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true)
    const { data, error } = await sb.rpc('listar_escoltas_excluidas')
    if (error) setMsg({ ok: false, texto: ehFuncaoAusente(error) ? MSG_DEPENDE_221 : error.message })
    setLista((data ?? []) as Excluida[])
    setCarregando(false)
  }, [])

  useEffect(() => { if (podeVer) carregar() }, [podeVer, carregar])

  if (!user) return null
  if (!podeVer) return <div className="p-6 text-sm">Acesso restrito ao gestor e ao administrador.</div>

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Trash2 size={20} style={{ color: '#1E2D35' }} />
        <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Escoltas excluídas</h1>
      </div>
      <p className="text-sm" style={{ color: '#5A6A80' }}>
        Excluídas pela gestão: fora de todas as telas operacionais, para todos os perfis. Nada foi apagado do banco
        (fotos, GPS, pontos, checklists, ocorrências, histórico e financeiro continuam guardados). Desfazer a exclusão
        devolve a escolta para Arquivadas, de onde ela é recuperada.
      </p>
      {msg && (
        <div className="p-3 text-sm" data-teste="msg-excluidas" style={{ backgroundColor: msg.ok ? '#E8F5EE' : 'rgba(184,56,50,0.08)', color: msg.ok ? '#1E7C52' : '#B83832', borderRadius: '4px' }}>{msg.texto}</div>
      )}
      {carregando ? <p className="text-sm" style={{ color: '#6B7E8A' }}>Carregando…</p>
        : lista.length === 0 ? (!msg || msg.ok) && <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhuma escolta excluída.</p>
        : (
          <div className="space-y-2">
            {lista.map(e => (
              <div key={e.id} className="p-4 bg-white" style={{ border: '1px solid #D4D9E6', borderRadius: '4px' }} data-teste="excluida">
                <p className="text-sm font-black" style={{ color: '#0E1A33' }}>
                  <span className="font-mono">{e.codigo_escolta ?? '-'}</span> · {e.cliente ?? 'sem cliente'} · {rotuloStatus(e.status)}
                </p>
                {e.data_hora_prevista && <p className="text-xs mt-1" style={{ color: '#5A6A80' }}>Prevista para {horaBR(e.data_hora_prevista)} (Brasília)</p>}
                {(e.origem_endereco || e.destino_endereco) && (
                  <p className="text-xs mt-1" style={{ color: '#5A6A80' }}>{e.origem_endereco ?? '-'} → {e.destino_endereco ?? '-'}</p>
                )}
                <p className="text-sm mt-2" style={{ color: '#5A6A80' }}>Excluída em {horaBR(e.excluida_em)} (Brasília){e.excluida_por ? ` por ${e.excluida_por}` : ''}.</p>
                <p className="text-sm mt-1"><strong>Motivo:</strong> {e.motivo_exclusao ?? '-'}</p>
                <div className="mt-3">
                  <button type="button" onClick={() => { setRestaurando(e); setMsg(null) }} className="w-full flex items-center justify-center gap-1 text-xs font-black uppercase text-white" style={{ minHeight: '44px', backgroundColor: '#1A294A' }} data-teste="restaurar">
                    <Undo2 size={14} /> Desfazer exclusão
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      {restaurando && (
        <DialogoRestaurar escolta={restaurando}
          onFechar={() => setRestaurando(null)}
          onFeito={() => {
            setMsg({ ok: true, texto: `Exclusão da escolta ${restaurando.codigo_escolta ?? ''} desfeita: ela está em Arquivadas.` })
            setRestaurando(null)
            carregar()
          }} />
      )}
    </div>
  )
}

function DialogoRestaurar({ escolta, onFechar, onFeito }: { escolta: Excluida; onFechar: () => void; onFeito: () => void }) {
  const [motivo, setMotivo] = useState('')
  const [confirmo, setConfirmo] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const pronto = motivo.trim().length >= MOTIVO_MINIMO && confirmo && !enviando

  const restaurar = async () => {
    setEnviando(true); setErro(null)
    const { error } = await sb.rpc('restaurar_escolta_excluida', { p_escolta_id: escolta.id, p_motivo: motivo.trim() })
    setEnviando(false)
    if (error) { setErro(ehFuncaoAusente(error) ? MSG_DEPENDE_221 : error.message); return }
    onFeito()
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }} data-teste="dialogo-restaurar">
      <div className="w-full sm:max-w-lg sm:mx-4 bg-white overflow-hidden rounded-t-2xl sm:rounded-2xl flex flex-col" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.2)', maxHeight: '92vh' }}>
        <div className="px-6 py-4 border-b flex items-start justify-between gap-3" style={{ borderColor: '#E2E8EC' }}>
          <div>
            <h2 className="font-bold text-base" style={{ color: '#0E1A33' }}>Desfazer exclusão</h2>
            <p className="text-xs mt-0.5" style={{ color: '#5A6A80' }}>{escolta.codigo_escolta ?? ''} · {rotuloStatus(escolta.status)}</p>
          </div>
          <button type="button" onClick={onFechar} aria-label="Fechar" style={{ color: '#5A6A80' }}><X size={18} /></button>
        </div>
        <div className="px-6 py-4 space-y-4 overflow-y-auto">
          {erro && <p className="text-xs p-3" style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</p>}
          <p className="text-sm" style={{ color: '#5A6A80' }}>A escolta volta para Arquivadas, no status em que ficou ({rotuloStatus(escolta.status)}). Para voltar às listas, recupere-a de lá. Fica na auditoria e a supervisão é avisada.</p>
          <div>
            <label className="block text-xs font-semibold mb-1.5" style={{ color: '#5A6A80' }}>Motivo *</label>
            <textarea value={motivo} onChange={e => setMotivo(e.target.value)} rows={3} className="input-light resize-none w-full text-sm" placeholder={`Mínimo de ${MOTIVO_MINIMO} caracteres`} />
          </div>
          <label className="flex items-start gap-2 text-xs" style={{ color: '#0E1A33' }}>
            <input type="checkbox" checked={confirmo} onChange={e => setConfirmo(e.target.checked)} />
            <span>Confirmo que quero desfazer a exclusão desta escolta.</span>
          </label>
        </div>
        <div className="px-6 py-4 border-t flex flex-col sm:flex-row justify-end gap-2" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
          <button type="button" onClick={onFechar} className="btn-outline w-full sm:w-auto">Cancelar</button>
          <button type="button" onClick={restaurar} disabled={!pronto} className="btn-gradient w-full sm:w-auto">{enviando ? 'Processando…' : 'Confirmar: desfazer exclusão'}</button>
        </div>
      </div>
    </div>
  )
}
