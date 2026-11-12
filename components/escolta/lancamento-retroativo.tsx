'use client'

/**
 * Lançamento retroativo (pedido de Peçanha em 2026-11-12, migration 222). Só gestor e
 * administrador (podeLancarRetroativo), em escolta de Agendada até Na Base.
 *
 * O formulário lista as etapas que faltam, em ordem, cada uma com data e hora de Brasília,
 * observação opcional e fotos da galeria (input sem capture: nada de câmera, GPS ou carimbo ao
 * vivo). "Conferir" chama a RPC com p_previa = true e mostra o resumo do servidor; "Confirmar
 * lançamento" sobe as fotos, grava as linhas de `fotos` sem latitude e longitude e chama a RPC
 * de novo com os ids e o resumo da prévia. Se a escolta mudou entre as duas chamadas, o banco
 * recusa e a tela pede para conferir de novo.
 *
 * As fotos sobem só na confirmação (a prévia leva a quantidade). Se a RPC recusar depois do
 * envio, as fotos ficam no storage sem ponto (como no fluxo ao vivo quando a etapa falha) e não
 * aparecem em lugar nenhum; um novo envio sobe de novo.
 *
 * Regras e textos: lib/lancamento-retroativo.ts. Quem garante é o banco.
 */
import { useMemo, useState } from 'react'
import { History, ImagePlus, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { rotuloStatus } from '@/lib/fluxo-escolta'
import { ehFuncaoAusente } from '@/lib/gestao'
import { buscarUltimaAlteracao, classificarConflito, mensagemConflito } from '@/lib/concorrencia'
import {
  MAX_FOTOS_ETAPA, MOTIVO_MINIMO, MSG_DEPENDE_222, OBSERVACAO_MAXIMA, PREFIXO_FOTO_RETROATIVA,
  brasiliaParaIso, colunasFotoGaleria, erroMotivo, etapaTemPonto, etapasQueFaltam, isoParaBrasilia, montarPEtapas,
  validarEtapas, type EtapaInformada,
} from '@/lib/lancamento-retroativo'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

/** Tipo de foto dos pontos de controle (o mesmo da tela de detalhe). */
const TIPO_FOTO_PONTO = 'db608f8f-322e-4748-b4f8-fef572a6c1e6'

const C = { navy: '#1A294A', text: '#0E1A33', sub: '#5A6A80', border: '#D4D9E6', red: '#B83832', amber: '#B7791F', bgRed: '#FEF0EE', bgAmber: '#FFF7E6' }

interface CampoEtapa { status: string; data: string; hora: string; observacao: string; fotos: File[] }

interface PreviaRetroativo {
  status_atual: string
  etapas: { ordem: number; status: string; rotulo: string; data_hora_br: string; fotos: number; sem_foto: boolean; observacao: string | null }[]
  fotos: number
  etapas_sem_foto: number
  data_finalizacao_br: string
  ultimo_registro_br: string | null
  avisos: string[]
  resumo: Record<string, unknown>
}

export interface EscoltaRetroativo {
  id: string
  status: string
  codigo_escolta: string | null
  data_hora_prevista?: string | null
}

export function DialogoLancamentoRetroativo({ escolta, usuarioId, onFechar, onFeito }: {
  escolta: EscoltaRetroativo
  usuarioId: string | null | undefined
  onFechar: () => void
  onFeito: () => void
}) {
  const dataPadrao = escolta.data_hora_prevista ? isoParaBrasilia(escolta.data_hora_prevista).data : ''
  const [campos, setCampos] = useState<CampoEtapa[]>(() =>
    etapasQueFaltam(escolta.status).map(s => ({ status: s, data: dataPadrao, hora: '', observacao: '', fotos: [] })))
  const [motivo, setMotivo] = useState('')
  const [previa, setPrevia] = useState<PreviaRetroativo | null>(null)
  const [confirmo, setConfirmo] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [andamento, setAndamento] = useState<string | null>(null)
  const [erros, setErros] = useState<string[]>([])
  const [feito, setFeito] = useState<string | null>(null)

  const etapas: EtapaInformada[] = useMemo(() => campos.map(c => ({
    status: c.status, dataHora: brasiliaParaIso(c.data, c.hora), observacao: c.observacao, fotos: c.fotos.length,
  })), [campos])

  // Qualquer mudança no formulário invalida a conferência.
  const alterar = (i: number, parte: Partial<CampoEtapa>) => {
    setCampos(cs => cs.map((c, j) => (j === i ? { ...c, ...parte } : c)))
    setPrevia(null); setConfirmo(false)
  }

  const mensagem = (e: { code?: string; message?: string }) => (ehFuncaoAusente(e) ? MSG_DEPENDE_222 : (e.message ?? 'Erro inesperado.'))

  const conferir = async () => {
    const lista = [...validarEtapas({ statusAtual: escolta.status, etapas })]
    const m = erroMotivo(motivo)
    if (m) lista.push(m)
    setErros(lista)
    if (lista.length) return
    setEnviando(true)
    const { data, error } = await sb.rpc('lancar_escolta_retroativa', {
      p_escolta_id: escolta.id, p_etapas: montarPEtapas(etapas), p_motivo: motivo.trim(), p_previa: true,
    })
    setEnviando(false)
    if (error) { setErros([mensagem(error)]); return }
    setPrevia(data as PreviaRetroativo)
  }

  const subirFotos = async (): Promise<Record<string, string[]>> => {
    const ids: Record<string, string[]> = {}
    const total = campos.reduce((s, c) => s + (etapaTemPonto(c.status) ? c.fotos.length : 0), 0)
    let feitas = 0
    for (const c of campos) {
      if (!etapaTemPonto(c.status) || c.fotos.length === 0) continue
      const dataHora = brasiliaParaIso(c.data, c.hora) as string
      ids[c.status] = []
      for (const file of c.fotos.slice(0, MAX_FOTOS_ETAPA)) {
        feitas++
        setAndamento(`Enviando foto ${feitas} de ${total}`)
        const ext = (file.name.split('.').pop() ?? 'jpg').toLowerCase()
        const caminho = `${PREFIXO_FOTO_RETROATIVA}/${escolta.id}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`
        const { error: upErr } = await sb.storage.from('fotos').upload(caminho, file)
        if (upErr) throw new Error(`Erro no envio da foto: ${upErr.message}`)
        const { data: f, error: dbErr } = await sb.from('fotos').insert({
          caminho_arquivo: caminho, tipo_foto_id: TIPO_FOTO_PONTO, criado_por: usuarioId ?? null,
          ...colunasFotoGaleria(dataHora),
        }).select('id').single()
        if (dbErr) throw new Error(`Erro ao salvar a foto: ${dbErr.message}`)
        ids[c.status].push(f.id as string)
      }
    }
    return ids
  }

  const confirmar = async () => {
    if (!previa) return
    setEnviando(true); setErros([])
    try {
      const fotoIds = await subirFotos()
      setAndamento('Gravando o lançamento')
      const { data, error } = await sb.rpc('lancar_escolta_retroativa', {
        p_escolta_id: escolta.id, p_etapas: montarPEtapas(etapas, fotoIds), p_motivo: motivo.trim(),
        p_previa: false, p_resumo: previa.resumo,
      })
      if (error) {
        // Concorrência (2026-11-12): a escolta mudou desde a conferência; diz quem, o quê e quando.
        if (!ehFuncaoAusente(error) && classificarConflito(error.message) === 'previa') {
          setErros([mensagemConflito(await buscarUltimaAlteracao(sb, escolta.id), {
            nadaGravado: 'Nenhuma etapa foi lançada.', fecho: 'Confira de novo antes de confirmar.',
          })])
          setPrevia(null); setConfirmo(false)
          return
        }
        setErros([mensagem(error)])
        return
      }
      const d = (data ?? {}) as Record<string, unknown>
      setFeito(`Lançamento retroativo gravado: ${d.etapas ?? campos.length} etapa(s), ${d.fotos ?? 0} foto(s). A escolta está finalizada e marcada como retroativa.`)
      setTimeout(onFeito, 1500)
    } catch (e) {
      setErros([(e as Error).message])
    } finally {
      setEnviando(false); setAndamento(null)
    }
  }

  const n = motivo.trim().length

  return (
    <div className="fixed inset-0 z-[60] flex items-end sm:items-center justify-center" style={{ backgroundColor: 'rgba(28,43,53,0.55)' }} data-teste="dialogo-retroativo">
      <div className="w-full sm:max-w-2xl sm:mx-4 bg-white overflow-hidden rounded-t-2xl sm:rounded-2xl flex flex-col" style={{ boxShadow: '0 16px 48px rgba(0,0,0,0.2)', maxHeight: '92vh' }}>
        <div className="px-6 py-4 border-b flex items-start justify-between gap-3" style={{ borderColor: '#E2E8EC' }}>
          <div>
            <h2 className="font-bold text-base" style={{ color: C.text }}>Lançamento retroativo</h2>
            <p className="text-xs mt-0.5" style={{ color: C.sub }}>{escolta.codigo_escolta ?? ''} · {rotuloStatus(escolta.status)} até Finalizada</p>
          </div>
          <button type="button" onClick={onFechar} aria-label="Fechar" style={{ color: C.sub }}><X size={18} /></button>
        </div>

        <div className="px-6 py-4 space-y-4 overflow-y-auto">
          <p className="text-xs p-3" style={{ backgroundColor: C.bgAmber, color: C.amber }}>
            Para escolta que aconteceu e não foi registrada na hora. Informe quando cada etapa aconteceu (horário de Brasília).
            Os registros ficam marcados como retroativos, sem localização, com o horário em que aconteceram e o horário em que foram lançados.
            O Telegram recebe um único resumo no fim.
          </p>
          {erros.length > 0 && (
            <ul className="text-xs p-3 space-y-1" style={{ backgroundColor: C.bgRed, color: C.red }} data-teste="erro-retroativo">
              {erros.map((e, i) => <li key={i}>{e}</li>)}
            </ul>
          )}
          {feito && <p className="text-xs p-3" style={{ backgroundColor: '#EAF6EF', color: '#1E7C52' }} data-teste="retroativo-feito">{feito}</p>}

          {!feito && (
            <ol className="space-y-3">
              {campos.map((c, i) => (
                <li key={c.status} className="p-3 space-y-2" style={{ border: `1px solid ${C.border}` }} data-teste="etapa-retroativa">
                  <p className="text-[10px] font-black uppercase tracking-widest" style={{ color: C.navy }}>{i + 1}. {rotuloStatus(c.status)}</p>
                  <div className="grid grid-cols-2 gap-2">
                    <label className="text-[11px]" style={{ color: C.sub }}>
                      Data
                      <input type="date" value={c.data} onChange={e => alterar(i, { data: e.target.value })} className="input-light w-full text-sm" />
                    </label>
                    <label className="text-[11px]" style={{ color: C.sub }}>
                      Hora (Brasília)
                      <input type="time" value={c.hora} onChange={e => alterar(i, { hora: e.target.value })} className="input-light w-full text-sm" />
                    </label>
                  </div>
                  <input
                    type="text" value={c.observacao} maxLength={OBSERVACAO_MAXIMA}
                    onChange={e => alterar(i, { observacao: e.target.value })}
                    placeholder={c.status === 'finalizada' ? 'Relatório final (opcional)' : 'Observação (opcional)'}
                    className="input-light w-full text-sm"
                  />
                  {etapaTemPonto(c.status) && (
                    <div className="flex items-center gap-2 flex-wrap">
                      <label className="flex items-center gap-1.5 text-[11px] font-bold cursor-pointer px-3 py-1.5" style={{ border: `1px dashed ${C.border}`, color: C.navy }}>
                        <ImagePlus size={13} /> Fotos da galeria
                        {/* Sem capture: o arquivo vem da galeria, nunca da câmera ao vivo. */}
                        <input
                          type="file" accept="image/*" multiple className="hidden"
                          onChange={e => {
                            const lista = Array.from(e.target.files ?? []).slice(0, MAX_FOTOS_ETAPA)
                            alterar(i, { fotos: lista })
                            e.target.value = ''
                          }}
                        />
                      </label>
                      <span className="text-[11px]" style={{ color: c.fotos.length ? C.text : C.amber }}>
                        {c.fotos.length
                          ? `${c.fotos.length} foto(s): ${c.fotos.map(f => f.name).join(', ')}`
                          : `Sem foto (até ${MAX_FOTOS_ETAPA}; ao vivo esta etapa exige foto, a falta fica marcada)`}
                      </span>
                    </div>
                  )}
                </li>
              ))}
            </ol>
          )}

          {!feito && (
            <div>
              <label className="block text-xs font-semibold mb-1.5" style={{ color: C.sub }}>Motivo do lançamento retroativo *</label>
              <textarea
                value={motivo}
                onChange={e => { setMotivo(e.target.value); setPrevia(null); setConfirmo(false) }}
                rows={3}
                className="input-light resize-none w-full text-sm"
                placeholder="Por que não foi registrado na hora (mínimo de 10 caracteres)"
                data-teste="motivo-retroativo"
              />
              <p className="text-[10px] mt-1" style={{ color: n >= MOTIVO_MINIMO ? C.sub : C.red }}>
                {n} de {MOTIVO_MINIMO} caracteres no mínimo
              </p>
            </div>
          )}

          {previa && !feito && (
            <div className="space-y-2" data-teste="previa-retroativo">
              <p className="text-sm" style={{ color: C.text }}>
                Conferido pelo servidor. De <strong>{rotuloStatus(previa.status_atual)}</strong> até <strong>Finalizada</strong>,
                término em <strong>{previa.data_finalizacao_br}</strong> (Brasília).
              </p>
              <ul className="text-xs space-y-1 p-2" style={{ border: `1px solid ${C.border}` }}>
                {previa.etapas.map(e => (
                  <li key={e.ordem} className="flex justify-between gap-2">
                    <span style={{ color: C.text }}>{e.ordem}. {e.rotulo}{e.sem_foto ? ' (sem foto)' : e.fotos > 0 ? ` (${e.fotos} foto(s))` : ''}</span>
                    <span className="font-mono whitespace-nowrap" style={{ color: C.sub }}>{e.data_hora_br}</span>
                  </li>
                ))}
              </ul>
              {previa.ultimo_registro_br && (
                <p className="text-[11px]" style={{ color: C.sub }}>Último registro existente da escolta: {previa.ultimo_registro_br} (Brasília).</p>
              )}
              {previa.avisos.map((a, i) => <p key={i} className="text-xs p-2" style={{ backgroundColor: C.bgAmber, color: C.amber }}>{a}</p>)}
              <label className="flex items-start gap-2 text-xs" style={{ color: C.text }}>
                <input type="checkbox" checked={confirmo} onChange={e => setConfirmo(e.target.checked)} data-teste="confirmo-retroativo" />
                <span>Conferi os horários. O lançamento fica no histórico e na auditoria como retroativo, e a supervisão é avisada uma vez.</span>
              </label>
            </div>
          )}
          {andamento && <p className="text-xs" style={{ color: C.sub }}>{andamento}</p>}
        </div>

        <div className="px-6 py-4 border-t flex flex-col sm:flex-row justify-end gap-2" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8F9FB' }}>
          <button type="button" onClick={onFechar} className="btn-outline w-full sm:w-auto">{feito ? 'Fechar' : 'Cancelar'}</button>
          {!feito && !previa && (
            <button type="button" onClick={conferir} disabled={enviando} className="btn-gradient w-full sm:w-auto" data-teste="conferir-retroativo">
              {enviando ? 'Conferindo…' : 'Conferir'}
            </button>
          )}
          {!feito && previa && (
            <button type="button" onClick={confirmar} disabled={!confirmo || enviando} className="btn-gradient w-full sm:w-auto" data-teste="confirmar-retroativo">
              {enviando ? 'Gravando…' : 'Confirmar lançamento'}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

export interface MarcasRetroativo {
  /** Marca da escolta; null quando não é retroativa ou a 222 não foi aplicada. */
  escolta: { retroativo_em: string | null; retroativo_motivo: string | null; autor: string | null } | null
  /** Registros retroativos (histórico e pontos), por id: quando foram registrados. */
  registros: Record<string, { registrado_em: string | null }>
  /** Fotos vindas da galeria (sem localização). */
  fotosGaleria: Set<string>
}

export const SEM_MARCAS: MarcasRetroativo = { escolta: null, registros: {}, fotosGaleria: new Set() }

/**
 * Marcas do lançamento retroativo, lidas à parte das consultas da tela e sem derrubar nada:
 * sem a migration 222 as colunas não existem, a consulta falha e a tela segue como antes. Só
 * consulta histórico, pontos e fotos quando a escolta está marcada como retroativa.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function lerMarcasRetroativo(cliente: any, escoltaId: string, viaturaIds: string[], fotoIds: string[]): Promise<MarcasRetroativo> {
  try {
    const { data: e, error } = await cliente.from('escoltas')
      .select('lancamento_retroativo, retroativo_em, retroativo_motivo, autor:usuarios!retroativo_por(nome_completo)')
      .eq('id', escoltaId).maybeSingle()
    if (error || !e?.lancamento_retroativo) return SEM_MARCAS
    const registros: MarcasRetroativo['registros'] = {}
    const { data: hs } = await cliente.from('escolta_status_historico')
      .select('id, registrado_em').eq('escolta_id', escoltaId).eq('retroativo', true)
    for (const h of hs ?? []) registros[h.id] = { registrado_em: h.registrado_em ?? null }
    if (viaturaIds.length > 0) {
      const { data: ps } = await cliente.from('pontos_controle')
        .select('id, registrado_em').in('escolta_veiculo_id', viaturaIds).eq('retroativo', true)
      for (const p of ps ?? []) registros[p.id] = { registrado_em: p.registrado_em ?? null }
    }
    const fotosGaleria = new Set<string>()
    if (fotoIds.length > 0) {
      const { data: fs } = await cliente.from('fotos').select('id').in('id', Array.from(new Set(fotoIds))).eq('origem', 'galeria')
      for (const f of fs ?? []) fotosGaleria.add(f.id)
    }
    return {
      escolta: { retroativo_em: e.retroativo_em ?? null, retroativo_motivo: e.retroativo_motivo ?? null, autor: e.autor?.nome_completo ?? null },
      registros, fotosGaleria,
    }
  } catch {
    return SEM_MARCAS
  }
}

/** Selo "Retroativo" (cabeçalho, linha do tempo e impressão). */
export function SeloRetroativo({ titulo }: { titulo?: string }) {
  return (
    <span
      className="inline-flex items-center gap-1 text-[9px] font-black uppercase tracking-widest px-1.5 py-0.5"
      style={{ backgroundColor: C.bgAmber, color: C.amber, border: `1px solid ${C.amber}`, borderRadius: '1px' }}
      title={titulo}
      data-teste="selo-retroativo"
    >
      <History size={10} /> Retroativo
    </span>
  )
}
