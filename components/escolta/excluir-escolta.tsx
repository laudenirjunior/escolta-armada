'use client'

/**
 * Exclusão de escolta pela gestão (controle total, pedido de Peçanha em 2026-11-12). Só
 * gestor e administrador. Exclusão LÓGICA pela RPC excluir_escolta (migration 221): a escolta
 * some de todas as listas, do mural, do Campo e dos indicadores para todos os perfis, mas
 * nada é apagado (fotos, GPS, pontos, checklists, ocorrências, histórico e financeiro ficam);
 * gestor e administrador a veem em "Excluídas" e podem desfazer.
 *
 * Duas etapas explícitas: (1) aviso, motivo de 10 a 1000 caracteres e "entendi"; (2) digitar
 * o código da escolta. Só então a RPC é chamada. Sem a migration 221 o banco não tem a RPC:
 * a tela mostra MSG_DEPENDE_221 e nada muda.
 */
import { useState } from 'react'
import { Trash2, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { rotuloStatus } from '@/lib/fluxo-escolta'
import { ehFuncaoAusente } from '@/lib/gestao'
import { MOTIVO_MAXIMO, MOTIVO_MINIMO, MSG_DEPENDE_221, exclusaoEtapa1Ok, exclusaoEtapa2Ok } from '@/lib/controle-total'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

const C = { text: '#0E1A33', sub: '#5A6A80', border: '#D4D9E6', red: '#B83832', bgRed: '#FEF0EE' }

export function DialogoExcluir({ escolta, onFechar, onFeito }: {
  escolta: { id: string; status: string; codigo_escolta: string | null; arquivada_em?: string | null }
  onFechar: () => void
  onFeito: () => void
}) {
  const [etapa, setEtapa] = useState<1 | 2>(1)
  const [motivo, setMotivo] = useState('')
  const [entendi, setEntendi] = useState(false)
  const [codigo, setCodigo] = useState('')
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [feito, setFeito] = useState(false)

  const emAndamento = !escolta.arquivada_em && !['rascunho', 'agendada', 'finalizada', 'cancelada'].includes(escolta.status)
  const etapa1 = exclusaoEtapa1Ok(motivo, entendi)
  const etapa2 = exclusaoEtapa2Ok(codigo, escolta.codigo_escolta)

  const excluir = async () => {
    if (!etapa1 || !etapa2) return
    setEnviando(true); setErro(null)
    const { error } = await sb.rpc('excluir_escolta', { p_escolta_id: escolta.id, p_motivo: motivo.trim() })
    setEnviando(false)
    if (error) { setErro(ehFuncaoAusente(error) ? MSG_DEPENDE_221 : (error.message ?? 'Erro inesperado.')); return }
    setFeito(true)
    setTimeout(onFeito, 1500)
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }} data-teste="dialogo-excluir">
      <div className="w-full sm:max-w-lg sm:mx-4 bg-white overflow-hidden rounded-t-2xl sm:rounded-2xl flex flex-col" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.2)', maxHeight: '92vh' }}>
        <div className="px-6 py-4 border-b flex items-start justify-between gap-3" style={{ borderColor: '#E2E8EC' }}>
          <div>
            <h2 className="font-bold text-base" style={{ color: C.red }}>Excluir escolta ({etapa} de 2)</h2>
            <p className="text-xs mt-0.5" style={{ color: C.sub }}>{escolta.codigo_escolta ?? ''} · {rotuloStatus(escolta.status)}{escolta.arquivada_em ? ' · arquivada' : ''}</p>
          </div>
          <button type="button" onClick={onFechar} aria-label="Fechar" style={{ color: C.sub }}><X size={18} /></button>
        </div>

        <div className="px-6 py-4 space-y-4 overflow-y-auto">
          {erro && <p className="text-xs p-3" style={{ backgroundColor: C.bgRed, color: C.red }} data-teste="erro-excluir">{erro}</p>}
          {feito && <p className="text-xs p-3" style={{ backgroundColor: '#EAF6EF', color: '#1E7C52' }} data-teste="excluir-feito">Escolta excluída. Ela está em Escoltas excluídas, onde a gestão pode desfazer.</p>}

          {!feito && etapa === 1 && (
            <>
              <div className="p-3 text-xs space-y-1" style={{ backgroundColor: C.bgRed, color: C.red }}>
                <p className="font-bold">Isto é uma EXCLUSÃO, não um arquivamento.</p>
                <p>A escolta some para todos os perfis: listas, mural, Campo, mapa, relatórios e indicadores. Só gestor e administrador a veem, em Escoltas excluídas.</p>
                {emAndamento && <p className="font-bold">Ela está em andamento: será CANCELADA na mesma operação, e a equipe deixa de registrar por ela.</p>}
                <p>Nada é apagado do banco (fotos, GPS, pontos, checklists, ocorrências, histórico e financeiro ficam guardados). A exclusão fica na auditoria e a supervisão é avisada.</p>
              </div>
              <div>
                <label className="block text-xs font-semibold mb-1.5" style={{ color: C.sub }}>Motivo da exclusão *</label>
                <textarea
                  value={motivo}
                  onChange={e => setMotivo(e.target.value)}
                  rows={3}
                  maxLength={MOTIVO_MAXIMO}
                  className="input-light resize-none w-full text-sm"
                  placeholder={`Mínimo de ${MOTIVO_MINIMO} caracteres`}
                  data-teste="motivo-excluir"
                />
                {motivo.length > 0 && motivo.trim().length < MOTIVO_MINIMO && <p className="text-[10px] mt-1" style={{ color: C.red }}>Mínimo de {MOTIVO_MINIMO} caracteres.</p>}
              </div>
              <label className="flex items-start gap-2 text-xs" style={{ color: C.text }}>
                <input type="checkbox" checked={entendi} onChange={e => setEntendi(e.target.checked)} data-teste="entendi-excluir" />
                <span>Entendi que a escolta sai de todas as telas operacionais e que a exclusão fica registrada em meu nome.</span>
              </label>
            </>
          )}

          {!feito && etapa === 2 && (
            <>
              <p className="text-sm" style={{ color: C.text }}>
                Para confirmar, digite o código da escolta: <strong className="font-mono">{escolta.codigo_escolta}</strong>
              </p>
              <input
                value={codigo}
                onChange={e => setCodigo(e.target.value)}
                className="input-light w-full text-sm font-mono"
                placeholder={escolta.codigo_escolta ?? ''}
                autoComplete="off"
                data-teste="codigo-excluir"
              />
              <p className="text-xs" style={{ color: C.sub }}><strong>Motivo:</strong> {motivo.trim()}</p>
            </>
          )}
        </div>

        <div className="px-6 py-4 border-t flex flex-col sm:flex-row justify-end gap-2" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
          <button type="button" onClick={feito ? onFeito : etapa === 2 ? () => { setEtapa(1); setErro(null) } : onFechar} className="btn-outline w-full sm:w-auto">
            {feito ? 'Fechar' : etapa === 2 ? 'Voltar' : 'Cancelar'}
          </button>
          {!feito && etapa === 1 && (
            <button type="button" onClick={() => { setEtapa(2); setErro(null) }} disabled={!etapa1} className="btn-danger w-full sm:w-auto" data-teste="excluir-continuar">
              Continuar
            </button>
          )}
          {!feito && etapa === 2 && (
            <button type="button" onClick={excluir} disabled={!etapa1 || !etapa2 || enviando} className="btn-danger w-full sm:w-auto flex items-center justify-center gap-1.5" data-teste="excluir-confirmar">
              <Trash2 size={13} /> {enviando ? 'Excluindo…' : 'Excluir definitivamente das telas'}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
