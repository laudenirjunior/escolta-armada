'use client'

/**
 * Ações da gestão na tela da escolta (lote 2026-10, onda I). Só gestor e administrador
 * (PODE_PODER_TOTAL) veem o menu: Editar, Voltar uma etapa, Zerar para agendada, Concluir
 * agora e Arquivar. Cada ação abre um diálogo com a prévia do que muda (lista do que será
 * anulado, ou das pendências), pede o motivo (mínimo de 10 caracteres) e uma confirmação
 * explícita, e só então chama a RPC da migration 218. Quem garante a regra é o banco: as
 * RPCs recusam outros perfis, status inválidos (S7, S8) e emergência aberta.
 *
 * A confirmação de voltar e zerar manda de volta o resumo que a prévia devolveu (versão,
 * status, total e hash dos ids a anular): se a escolta mudou entre a prévia e a confirmação,
 * o banco recusa e a tela pede para conferir de novo.
 *
 * Escolta arquivada (só o administrador a abre): faixa "Arquivada em ... por Nome: motivo" e
 * o menu oferece só Recuperar.
 *
 * Fica fora da tela de detalhe de propósito (regra 7 do plano: mudança mínima no detalhe).
 * Também daqui: a faixa "Concluída com pendências" e a seção com a lista.
 */
import { useCallback, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { Archive, ArchiveRestore, CheckCheck, ChevronDown, Pencil, RotateCcw, ShieldAlert, Undo2, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { PODE_PODER_TOTAL, temPermissao } from '@/lib/permissions'
import { rotuloStatus, statusAnterior } from '@/lib/fluxo-escolta'
import {
  MSG_ATUALIZACAO, ehFuncaoAusente, horaBR, totalItensPendentes,
  type ConclusaoAntecipada, type PendenciaEtapa,
} from '@/lib/gestao'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

type Acao = 'voltar' | 'zerar' | 'concluir' | 'arquivar' | 'recuperar'

interface ItemPrevia { tabela: string; id: string; quando_br: string; descricao: string; criterio: string }
interface Previa {
  status_atual: string; destino: string; rotulo_destino: string; tipo: string; total: number
  itens: ItemPrevia[]; avisos: string[]
  /** Devolvido na confirmação: o banco recusa se a escolta mudou desde a prévia. */
  resumo: Record<string, unknown>
  valores: { km: { placa: string; quilometragem_saida: number | null; quilometragem_retorno: number | null }[] }
}

const C = { navy: '#1A294A', text: '#0E1A33', sub: '#5A6A80', border: '#D4D9E6', red: '#B83832', amber: '#B7791F', bgRed: '#FEF0EE', bgAmber: '#FFF7E6' }
const CRITERIO: Record<string, string> = {
  etapa: 'produzido pela entrada na etapa', historico: 'histórico da etapa', carimbo: 'gravado durante a etapa',
  janela: 'registro antigo, pelo horário', zerar: 'registro de campo',
}
const STATUS_INICIADOS_ARQUIVO = ['rascunho', 'agendada', 'finalizada', 'cancelada']

interface Props {
  escolta: {
    id: string; status: string; codigo_escolta: string | null
    arquivada_em?: string | null; motivo_arquivamento?: string | null
    arquivador?: { nome_completo?: string | null } | null
  }
  perfil: string | null | undefined
  onAlterado: () => void
}

export function AcoesGestao({ escolta, perfil, onAlterado }: Props) {
  const router = useRouter()
  const [menu, setMenu] = useState(false)
  const [acao, setAcao] = useState<Acao | null>(null)
  if (!temPermissao(perfil, PODE_PODER_TOTAL)) return null

  // Arquivada: só o administrador a vê; a única ação é recuperar (o banco recusa as outras).
  if (escolta.arquivada_em) {
    return (
      <div className="space-y-2" data-teste="acoes-gestao">
        <div className="p-3 text-sm flex flex-col sm:flex-row sm:items-center justify-between gap-2" style={{ backgroundColor: C.bgAmber, color: C.amber, border: `1px solid ${C.amber}` }} data-teste="faixa-arquivada">
          <span>
            <strong>Arquivada em {horaBR(escolta.arquivada_em)} (Brasília){escolta.arquivador?.nome_completo ? ` por ${escolta.arquivador.nome_completo}` : ''}:</strong>{' '}
            {escolta.motivo_arquivamento ?? 'sem motivo'}
          </span>
          {perfil === 'administrador' && (
            <button
              type="button"
              onClick={() => setAcao('recuperar')}
              className="flex items-center justify-center gap-1.5 font-black text-[10px] uppercase tracking-widest px-4 py-2 text-white"
              style={{ backgroundColor: C.navy, borderRadius: '1px', minHeight: '40px' }}
              data-teste="acao-recuperar"
            >
              <ArchiveRestore size={13} /> Recuperar
            </button>
          )}
        </div>
        {acao && <DialogoAcao acao={acao} escolta={escolta} onFechar={() => setAcao(null)} onFeito={() => { setAcao(null); onAlterado() }} />}
      </div>
    )
  }

  const st = escolta.status
  const podeVoltar = statusAnterior(st) !== null
  const podeConcluir = !['rascunho', 'finalizada', 'cancelada'].includes(st)
  const podeArquivar = STATUS_INICIADOS_ARQUIVO.includes(st)

  const itens: { chave: Acao | 'editar'; rotulo: string; icone: React.ReactNode; ativo: boolean; dica?: string }[] = [
    { chave: 'editar', rotulo: 'Editar escolta', icone: <Pencil size={14} />, ativo: true },
    { chave: 'voltar', rotulo: 'Voltar uma etapa', icone: <Undo2 size={14} />, ativo: podeVoltar,
      dica: podeVoltar ? `Volta para ${rotuloStatus(statusAnterior(st) ?? '')}` : 'Sem etapa de campo para desfazer' },
    { chave: 'zerar', rotulo: 'Zerar para agendada', icone: <RotateCcw size={14} />, ativo: podeVoltar,
      dica: podeVoltar ? 'Todos os registros de campo ficam anulados' : 'Sem etapa de campo para desfazer' },
    { chave: 'concluir', rotulo: 'Concluir agora', icone: <CheckCheck size={14} />, ativo: podeConcluir,
      dica: podeConcluir ? 'Mostra o que não foi feito antes de concluir' : 'Escolta já encerrada' },
    { chave: 'arquivar', rotulo: 'Arquivar', icone: <Archive size={14} />, ativo: podeArquivar,
      dica: podeArquivar ? 'Some das listas, do mural e dos indicadores' : 'Em andamento: conclua ou cancele antes (S7)' },
  ]

  return (
    <div className="flex justify-end" data-teste="acoes-gestao">
      <div className="relative">
        <button
          type="button"
          onClick={() => setMenu(m => !m)}
          className="flex items-center gap-1.5 font-black text-[10px] uppercase tracking-widest px-4 py-2"
          style={{ backgroundColor: '#FFFFFF', color: C.navy, border: `1px solid ${C.border}`, borderRadius: '1px' }}
          aria-expanded={menu}
        >
          <ShieldAlert size={13} /> Ações da gestão <ChevronDown size={13} />
        </button>
        {menu && (
          <div className="absolute right-0 mt-1 z-[55] bg-white w-72" style={{ border: `1px solid ${C.border}`, boxShadow: '0 8px 24px rgba(0,0,0,0.12)' }} role="menu">
            {itens.map(it => (
              <button
                key={it.chave}
                type="button"
                role="menuitem"
                data-teste={`acao-${it.chave}`}
                disabled={!it.ativo}
                onClick={() => {
                  setMenu(false)
                  if (it.chave === 'editar') router.push(`/dashboard/escoltas/nova?editar=${escolta.id}`)
                  else setAcao(it.chave)
                }}
                className="w-full text-left px-4 py-2.5 flex items-start gap-2 disabled:opacity-45 hover:bg-[#F4F6FA]"
                style={{ borderBottom: '1px solid #EEF1F7' }}
              >
                <span className="mt-0.5" style={{ color: C.navy }}>{it.icone}</span>
                <span>
                  <span className="block text-xs font-bold" style={{ color: C.text }}>{it.rotulo}</span>
                  {it.dica && <span className="block text-[10px]" style={{ color: C.sub }}>{it.dica}</span>}
                </span>
              </button>
            ))}
          </div>
        )}
      </div>
      {acao && (
        <DialogoAcao
          acao={acao}
          escolta={escolta}
          onFechar={() => setAcao(null)}
          onFeito={() => {
            const a = acao
            setAcao(null)
            // Arquivada some para o gestor (só o administrador a vê): volta para a lista.
            if (a === 'arquivar' && perfil !== 'administrador') router.push('/dashboard/escoltas')
            else onAlterado()
          }}
        />
      )}
    </div>
  )
}

function DialogoAcao({ acao, escolta, onFechar, onFeito }: {
  acao: Acao; escolta: Props['escolta']; onFechar: () => void; onFeito: () => void
}) {
  const [carregando, setCarregando] = useState(acao !== 'arquivar' && acao !== 'recuperar')
  const [previa, setPrevia] = useState<Previa | null>(null)
  const [pendencias, setPendencias] = useState<PendenciaEtapa[] | null>(null)
  const [motivo, setMotivo] = useState('')
  const [confirmo, setConfirmo] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [feito, setFeito] = useState<string | null>(null)

  const mensagemDeErro = (e: { code?: string; message?: string }) => ehFuncaoAusente(e) ? MSG_ATUALIZACAO : (e.message ?? 'Erro inesperado.')

  const carregar = useCallback(async () => {
    setErro(null)
    if (acao === 'voltar' || acao === 'zerar') {
      const { data, error } = await sb.rpc(acao === 'voltar' ? 'voltar_etapa_escolta' : 'zerar_escolta',
        { p_escolta_id: escolta.id, p_motivo: null, p_previa: true })
      if (error) setErro(mensagemDeErro(error)); else setPrevia(data as Previa)
    } else if (acao === 'concluir') {
      const { data, error } = await sb.rpc('pendencias_da_escolta', { p_escolta_id: escolta.id })
      if (error) setErro(mensagemDeErro(error)); else setPendencias((data ?? []) as PendenciaEtapa[])
    }
    setCarregando(false)
  }, [acao, escolta.id])

  useEffect(() => { carregar() }, [carregar])

  const titulo = { voltar: 'Voltar uma etapa', zerar: 'Zerar para agendada', concluir: 'Concluir agora', arquivar: 'Arquivar escolta', recuperar: 'Recuperar do arquivo' }[acao]
  const motivoOk = motivo.trim().length >= 10
  const pronto = !carregando && !erro && motivoOk && confirmo && !feito

  const confirmar = async () => {
    setEnviando(true); setErro(null)
    const args = { p_escolta_id: escolta.id, p_motivo: motivo.trim() }
    const chamada = acao === 'voltar' ? sb.rpc('voltar_etapa_escolta', { ...args, p_previa: false, p_resumo: previa?.resumo ?? null })
      : acao === 'zerar' ? sb.rpc('zerar_escolta', { ...args, p_previa: false, p_resumo: previa?.resumo ?? null })
      : acao === 'concluir' ? sb.rpc('concluir_escolta_antecipada', args)
      : acao === 'recuperar' ? sb.rpc('recuperar_escolta', args)
      : sb.rpc('arquivar_escolta', args)
    const { data, error } = await chamada
    setEnviando(false)
    if (error) {
      setErro(mensagemDeErro(error))
      // A escolta mudou desde a prévia: busca a lista nova e pede nova confirmação.
      if ((acao === 'voltar' || acao === 'zerar') && /mudou desde a prévia/.test(error.message ?? '')) {
        setConfirmo(false); setPrevia(null); setCarregando(true); carregar()
      }
      return
    }
    const d = (data ?? {}) as Record<string, unknown>
    setFeito(acao === 'voltar' || acao === 'zerar'
      ? `Feito: a escolta voltou para ${rotuloStatus(String(d.para ?? ''))}. ${d.anulados ?? 0} registro(s) anulado(s), nada apagado.`
      : acao === 'concluir'
        ? (Number(d.itens ?? 0) > 0 ? `Concluída com ${d.itens} pendência(s) registrada(s).` : 'Concluída sem pendências.')
        : acao === 'recuperar' ? `Escolta recuperada; voltou em ${rotuloStatus(String(d.status ?? escolta.status))}.`
        : 'Escolta arquivada.')
    setTimeout(onFeito, 1200)
  }

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }} data-teste={`dialogo-${acao}`}>
      <div className="w-full sm:max-w-lg sm:mx-4 bg-white overflow-hidden rounded-t-2xl sm:rounded-2xl flex flex-col" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.2)', maxHeight: '92vh' }}>
        <div className="px-6 py-4 border-b flex items-start justify-between gap-3" style={{ borderColor: '#E2E8EC' }}>
          <div>
            <h2 className="font-bold text-base" style={{ color: C.text }}>{titulo}</h2>
            <p className="text-xs mt-0.5" style={{ color: C.sub }}>{escolta.codigo_escolta ?? ''} · {rotuloStatus(escolta.status)}</p>
          </div>
          <button type="button" onClick={onFechar} aria-label="Fechar" style={{ color: C.sub }}><X size={18} /></button>
        </div>

        <div className="px-6 py-4 space-y-4 overflow-y-auto">
          {erro && <p className="text-xs p-3" style={{ backgroundColor: C.bgRed, color: C.red }} data-teste="erro-acao">{erro}</p>}
          {feito && <p className="text-xs p-3" style={{ backgroundColor: '#EAF6EF', color: '#1E7C52' }} data-teste="acao-feita">{feito}</p>}
          {carregando && <p className="text-sm" style={{ color: C.sub }}>Carregando a prévia…</p>}

          {previa && (
            <div className="space-y-3" data-teste="previa">
              <p className="text-sm" style={{ color: C.sub }}>
                A escolta volta de <strong style={{ color: C.text }}>{rotuloStatus(previa.status_atual)}</strong> para{' '}
                <strong style={{ color: C.text }} data-teste="previa-destino">{previa.rotulo_destino}</strong>.
                {' '}{previa.total} registro(s) ficam <strong>anulados</strong> (marcados, nunca apagados):
              </p>
              {previa.avisos.map((a, i) => <p key={i} className="text-xs p-2" style={{ backgroundColor: C.bgAmber, color: C.amber }}>{a}</p>)}
              <ul className="text-xs space-y-1 max-h-56 overflow-y-auto p-2" style={{ border: `1px solid ${C.border}` }}>
                {previa.itens.length === 0 && <li style={{ color: C.sub }}>Nenhum registro de campo a anular.</li>}
                {previa.itens.map(it => (
                  <li key={`${it.tabela}:${it.id}`} className="flex justify-between gap-2" data-teste="previa-item">
                    <span style={{ color: C.text }}>{it.descricao} <span style={{ color: C.sub }}>({CRITERIO[it.criterio] ?? it.criterio})</span></span>
                    <span className="font-mono whitespace-nowrap" style={{ color: C.sub }}>{it.quando_br}</span>
                  </li>
                ))}
              </ul>
              {(previa.tipo === 'zerar' || previa.status_atual === 'em_andamento' || previa.status_atual === 'na_base') && previa.valores.km.some(k => k.quilometragem_saida != null || k.quilometragem_retorno != null) && (
                <p className="text-xs" style={{ color: C.sub }}>
                  KM guardado e limpo: {previa.valores.km.map(k => `${k.placa} (saída ${k.quilometragem_saida ?? '-'}, retorno ${k.quilometragem_retorno ?? '-'})`).join('; ')}.
                </p>
              )}
              {previa.tipo === 'zerar' && (
                <p className="text-xs" style={{ color: C.sub }}>Equipe e viaturas continuam escaladas. A escolta volta ao mural com a etiqueta &quot;Reiniciada pela gestão&quot;, e o pré-início é feito de novo do começo.</p>
              )}
            </div>
          )}

          {pendencias && (
            <div className="space-y-2" data-teste="lista-pendencias">
              {pendencias.length === 0
                ? <p className="text-sm" style={{ color: '#1E7C52' }}>Nada pendente: a escolta será concluída normalmente.</p>
                : <p className="text-sm" style={{ color: C.sub }}>Ficam registrados como <strong>não feitos</strong> ({totalItensPendentes(pendencias)} item(ns)):</p>}
              <ListaPendencias pendencias={pendencias} />
            </div>
          )}

          {acao === 'arquivar' && (
            <p className="text-sm" style={{ color: C.sub }}>A escolta some das listas, do mural, do Campo, do mapa e dos indicadores. Nada é apagado; o administrador vê em Arquivadas e pode recuperar.</p>
          )}
          {acao === 'recuperar' && (
            <p className="text-sm" style={{ color: C.sub }}>A escolta volta às listas no status em que estava ({rotuloStatus(escolta.status)}). A recuperação fica na auditoria, e a supervisão é avisada.</p>
          )}

          {!feito && (
            <>
              <div>
                <label className="block text-xs font-semibold mb-1.5" style={{ color: C.sub }}>
                  {acao === 'concluir' ? 'Motivo e observação (vai para o relatório final) *' : 'Motivo *'}
                </label>
                <textarea
                  value={motivo}
                  onChange={e => setMotivo(e.target.value)}
                  rows={3}
                  className="input-light resize-none w-full text-sm"
                  placeholder="Mínimo de 10 caracteres"
                  data-teste="motivo-acao"
                />
                {!motivoOk && motivo.length > 0 && <p className="text-[10px] mt-1" style={{ color: C.red }}>Mínimo de 10 caracteres.</p>}
              </div>
              <label className="flex items-start gap-2 text-xs" style={{ color: C.text }}>
                <input type="checkbox" checked={confirmo} onChange={e => setConfirmo(e.target.checked)} data-teste="confirmo-acao" />
                <span>Li {acao === 'arquivar' || acao === 'recuperar' ? 'o aviso' : 'a lista'} acima e confirmo. A ação fica na auditoria{acao === 'arquivar' || acao === 'recuperar' ? '' : ' e no histórico'}, e a supervisão é avisada.</span>
              </label>
            </>
          )}
        </div>

        <div className="px-6 py-4 border-t flex flex-col sm:flex-row justify-end gap-2" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
          <button type="button" onClick={onFechar} className="btn-outline w-full sm:w-auto">{feito ? 'Fechar' : 'Cancelar'}</button>
          {!feito && (
            <button type="button" onClick={confirmar} disabled={!pronto || enviando} className="btn-gradient w-full sm:w-auto" data-teste="confirmar-acao">
              {enviando ? 'Processando…' : `Confirmar: ${titulo.toLowerCase()}`}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

export function ListaPendencias({ pendencias }: { pendencias: PendenciaEtapa[] }) {
  if (!pendencias.length) return null
  return (
    <div className="space-y-2">
      {pendencias.map(et => (
        <div key={et.etapa} className="p-2" style={{ border: `1px solid ${C.border}` }}>
          <p className="text-[10px] font-black uppercase tracking-widest" style={{ color: C.navy }}>{et.rotulo}</p>
          <ul className="mt-1 space-y-0.5">
            {et.viaturas.map(v => (
              <li key={v.escolta_veiculo_id} className="text-xs" style={{ color: C.text }}>
                <span className="font-mono font-bold">{v.placa}</span>: {v.faltando.join(', ')}
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  )
}

/** Conclusão antecipada válida da escolta (a RLS mostra à supervisão e ao efetivo). */
export function useConclusaoAntecipada(escoltaId: string, chave?: unknown) {
  const [conclusao, setConclusao] = useState<ConclusaoAntecipada | null>(null)
  useEffect(() => {
    let vivo = true
    sb.from('escolta_conclusoes_antecipadas')
      .select('id, status_no_momento, motivo, concluida_em, pendencias, autor:usuarios!concluida_por(nome_completo)')
      .eq('escolta_id', escoltaId).is('anulado_em', null).maybeSingle()
      .then(({ data }: { data: ConclusaoAntecipada | null }) => { if (vivo) setConclusao(data ?? null) })
    return () => { vivo = false }
  }, [escoltaId, chave])
  return conclusao
}

/** Faixa "Concluída com pendências" (cabeçalho) ou seção com a lista (aba Geral). */
export function PendenciasConclusao({ escoltaId, modo, chave }: { escoltaId: string; modo: 'faixa' | 'secao'; chave?: unknown }) {
  const c = useConclusaoAntecipada(escoltaId, chave)
  if (!c) return null
  if (modo === 'faixa') return <span className="badge-warning" data-teste="faixa-pendencias">Concluída com pendências</span>
  return (
    <div className="card-light p-5 space-y-3" style={{ borderLeft: `4px solid ${C.amber}` }} data-teste="secao-pendencias">
      <div>
        <h3 className="text-[10px] font-black uppercase tracking-widest" style={{ color: C.amber }}>Pendências de conclusão</h3>
        <p className="text-xs mt-1" style={{ color: C.sub }}>
          Concluída pela gestão em {horaBR(c.concluida_em)} (Brasília){c.autor?.nome_completo ? ` por ${c.autor.nome_completo}` : ''}, quando estava em {rotuloStatus(c.status_no_momento)}.
          {' '}Observação: {c.motivo}
        </p>
      </div>
      <ListaPendencias pendencias={c.pendencias} />
    </div>
  )
}
