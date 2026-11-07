'use client'

/**
 * Onda O (B3): o gestor registra ocorrência pela tela de detalhe (antes só pelo Campo).
 *
 * Mesmas categorias da onda M (CATEGORIAS_OCORRENCIA, marcadas por toque) e a mesma regra: a
 * categoria sozinha não é relato (relatoAlemDaCategoria). Grava direto, como a gestão faz na
 * mesa: sem GPS (a coordenada da ocorrência fica nula, a tabela aceita) e sem foto. A RLS de
 * ocorrencias já permite administrador, gestor, supervisor, central e quem é do efetivo.
 */
import { useEffect, useState } from 'react'
import { AlertTriangle, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { CATEGORIAS_OCORRENCIA, comCategoria, relatoAlemDaCategoria } from '@/lib/textos-padrao'
import { SugestoesTexto } from '@/components/ui/sugestoes-texto'
import { ErroJuntoAoBotao } from '@/components/ui/erro-junto'

export function RegistrarOcorrenciaGestao({ escoltaId, escoltaVeiculoId, usuarioId, onFechar, onRegistrada }: {
  escoltaId: string
  escoltaVeiculoId: string | null
  usuarioId: string | null
  onFechar: () => void
  /** Recebe o nome do tipo e a descrição, para o aviso ao Telegram de quem chama. */
  onRegistrada: (tipo: string, descricao: string) => void
}) {
  const sb = createClient()
  const [tipos, setTipos] = useState<{ id: string; nome: string }[]>([])
  const [tipoId, setTipoId] = useState('')
  const [descricao, setDescricao] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [enviando, setEnviando] = useState(false)

  useEffect(() => {
    sb.from('dom_tipos_ocorrencia').select('id, nome').eq('ativo', true).order('nome')
      .then(({ data }) => setTipos((data ?? []) as { id: string; nome: string }[]))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const registrar = async () => {
    if (!usuarioId) { setErro('Sessão expirada. Entre de novo para registrar.'); return }
    if (!tipoId) { setErro('Escolha o tipo da ocorrência.'); return }
    if (!relatoAlemDaCategoria(descricao)) { setErro('Descreva o que aconteceu: a categoria sozinha não basta.'); return }
    setEnviando(true); setErro(null)
    const { error } = await sb.from('ocorrencias').insert({
      escolta_id: escoltaId,
      escolta_veiculo_id: escoltaVeiculoId,
      tipo_ocorrencia_id: tipoId,
      descricao: descricao.trim(),
      data_hora: new Date().toISOString(),
      latitude: null,
      longitude: null,
      registrado_por: usuarioId,
      sincronizado: true,
    })
    setEnviando(false)
    if (error) { setErro(`Não foi possível registrar a ocorrência: ${error.message}`); return }
    onRegistrada(tipos.find(t => t.id === tipoId)?.nome ?? 'Ocorrência', descricao.trim())
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }} data-teste="dialogo-ocorrencia-gestao">
      <div className="w-full sm:max-w-md sm:mx-4 bg-white overflow-hidden rounded-t-2xl sm:rounded-2xl" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.18)', maxHeight: '92vh', overflowY: 'auto' }}>
        <div className="px-6 py-4 border-b flex items-start justify-between gap-3" style={{ borderColor: '#E2E8EC' }}>
          <h2 className="font-bold text-base text-[#0E1A33] flex items-center gap-2"><AlertTriangle size={16} style={{ color: '#A07212' }} /> Registrar ocorrência</h2>
          <button type="button" onClick={onFechar} aria-label="Fechar" style={{ color: '#5A6A80' }}><X size={18} /></button>
        </div>
        <div className="px-6 py-5 space-y-4">
          <div>
            <label htmlFor="tipo-ocorrencia-gestao" className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">Tipo *</label>
            <select id="tipo-ocorrencia-gestao" value={tipoId} onChange={e => setTipoId(e.target.value)} className="input-light w-full" data-teste="tipo-ocorrencia">
              <option value="">Selecione o tipo...</option>
              {tipos.map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
            </select>
          </div>
          <div>
            <label className="block text-xs font-semibold mb-1.5 text-[#5A6A80]">O que aconteceu *</label>
            <SugestoesTexto className="mb-2" titulo="Categoria (toque para marcar; depois descreva o fato)" sugestoes={CATEGORIAS_OCORRENCIA} onInserir={(c) => setDescricao(d => comCategoria(d, c))} />
            <textarea value={descricao} onChange={e => setDescricao(e.target.value)} rows={4} className="input-light resize-none w-full text-sm"
              placeholder="Descreva o fato: o que, onde, quem foi avisado." data-teste="descricao-ocorrencia" />
          </div>
          <p className="text-[11px]" style={{ color: '#6B7E8A' }}>Registrada pela gestão, sem localização. A supervisão é avisada pelo Telegram.</p>
        </div>
        <ErroJuntoAoBotao texto={erro} className="mx-6 mb-3" />
        <div className="px-6 py-4 border-t flex flex-col-reverse sm:flex-row justify-end gap-2 sm:gap-3" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
          <button type="button" onClick={onFechar} className="btn-outline w-full sm:w-auto">Cancelar</button>
          <button type="button" onClick={registrar} disabled={enviando || !tipoId || !relatoAlemDaCategoria(descricao)} className="btn-gradient w-full sm:w-auto" data-teste="confirmar-ocorrencia">
            {enviando ? 'Registrando...' : 'Registrar ocorrência'}
          </button>
        </div>
      </div>
    </div>
  )
}
