'use client'

import { useEffect, useState } from 'react'
import { useParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

const sb = createClient() as any

interface PrintData {
  escolta: {
    id: string
    codigo_escolta: string | null
    status: string
    data_hora_prevista: string
    data_finalizacao: string | null
    origem_endereco: string
    destino_endereco: string
    observacao_fechamento: string | null
    criado_em: string
    cliente: { nome_cliente: string; telefone: string } | null
    valor_cobrado: number | null
    outros_custos: number | null
  }
  viaturas: Array<{
    id: string
    placa: string
    modelo: string | null
    tipo: string | null
    quilometragem_saida: number
    quilometragem_retorno: number | null
    efetivo: Array<{ nome: string; papel: string; confirmado: boolean }>
  }>
  historico: Array<{ status_novo: string; data_hora: string; observacao: string | null; autor: string }>
  pontos: Array<{ tipo: string; data_hora: string; autor: string; fotoUrl: string | null; justificativa: string }>
  ocorrencias: Array<{ tipo: string; descricao: string; data_hora: string; autor: string; fotoUrl: string | null }>
  checklists: Array<{ tipo: string; data_conclusao: string; autor: string; conformes: number; total: number }>
}

const STATUS_LABEL: Record<string, string> = {
  rascunho: 'Rascunho', agendada: 'Agendada', em_pre_inicio: 'Pré-Início',
  em_andamento: 'Em Rota', na_origem: 'Na Origem', no_destino: 'No Destino',
  retornando: 'Em Retorno', na_base: 'Na Base', finalizada: 'Finalizada', cancelada: 'Cancelada',
}

const TL_LABEL: Record<string, string> = {
  em_andamento: 'Saída da Base', na_origem: 'Chegada na Origem',
  no_destino: 'Chegada no Destino', retornando: 'Retorno Iniciado',
  na_base: 'Chegada na Base', finalizada: 'Escolta Finalizada',
  rascunho: 'Rascunho', agendada: 'Agendada', em_pre_inicio: 'Pré-Início',
}

function fmt(iso: string) {
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  })
}

function fmtPlaca(p: string) {
  const l = p.replace(/[^A-Za-z0-9]/g, '').toUpperCase()
  return l.length === 7 ? `${l.slice(0, 3)}-${l.slice(3)}` : p
}

export default function EscoltaPrintPage() {
  const params = useParams()
  const id = params?.id as string
  const [dados, setDados] = useState<PrintData | null>(null)
  const [loading, setLoading] = useState(true)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => {
    if (!id) return

    const carregar = async () => {
      try {
        // Escolta
        const { data: esc, error: escErr } = await sb
          .from('escoltas')
          .select(`id, codigo_escolta, status, data_hora_prevista, data_finalizacao,
            origem_endereco, destino_endereco, observacao_fechamento, criado_em,
            valor_cobrado, outros_custos,
            cliente:clientes(nome_cliente, telefone)`)
          .eq('id', id)
          .maybeSingle()
        if (escErr || !esc) { setErro('Escolta não encontrada.'); setLoading(false); return }

        // Viaturas
        const { data: viats } = await sb
          .from('escolta_veiculos')
          .select(`id, quilometragem_saida, quilometragem_retorno,
            veiculo:veiculos(placa, modelo, tipo:dom_tipos_veiculo(nome))`)
          .eq('escolta_id', id)
        const viatIds = (viats ?? []).map((v: any) => v.id)

        // Efetivos
        const { data: efetData } = viatIds.length > 0
          ? await sb.from('escolta_efetivo')
              .select('escolta_veiculo_id, papel_na_escolta, confirmado, vigilante:vigilantes(nome_completo)')
              .in('escolta_veiculo_id', viatIds)
          : { data: [] }

        const viaturas = (viats ?? []).map((v: any) => ({
          id: v.id,
          placa: v.veiculo?.placa ?? '—',
          modelo: v.veiculo?.modelo ?? null,
          tipo: v.veiculo?.tipo?.nome ?? null,
          quilometragem_saida: v.quilometragem_saida,
          quilometragem_retorno: v.quilometragem_retorno,
          efetivo: (efetData ?? [])
            .filter((e: any) => e.escolta_veiculo_id === v.id)
            .map((e: any) => ({
              nome: e.vigilante?.nome_completo ?? '—',
              papel: e.papel_na_escolta ?? '—',
              confirmado: e.confirmado ?? false,
            })),
        }))

        // Histórico de status
        const { data: hist } = await sb
          .from('escolta_status_historico')
          .select('status_novo, data_hora, observacao, autor:usuarios!alterado_por(nome_completo)')
          .eq('escolta_id', id)
          .order('data_hora', { ascending: true })

        const historico = (hist ?? []).map((h: any) => ({
          status_novo: h.status_novo,
          data_hora: h.data_hora,
          observacao: h.observacao ?? null,
          autor: h.autor?.nome_completo ?? 'Sistema',
        }))

        // Pontos de controle
        const { data: pts } = viatIds.length > 0
          ? await sb.from('pontos_controle')
              .select('data_hora, observacoes, tipo:dom_tipos_ponto(nome_exibicao), foto:fotos(caminho_arquivo), autor:usuarios!lancado_por(nome_completo)')
              .in('escolta_veiculo_id', viatIds)
              .order('data_hora', { ascending: true })
          : { data: [] }

        const pontos = await Promise.all((pts ?? []).map(async (p: any) => {
          let tipoLabel = p.tipo?.nome_exibicao ?? 'Ponto de Controle'
          let justificativa = ''
          try {
            const parsed = JSON.parse(p.observacoes ?? '{}')
            if (parsed.tipoLabel) tipoLabel = parsed.tipoLabel
            if (parsed.justificativa) justificativa = parsed.justificativa
          } catch { justificativa = p.observacoes ?? '' }

          let fotoUrl: string | null = null
          if (p.foto?.caminho_arquivo) {
            const path = p.foto.caminho_arquivo as string
            fotoUrl = path.startsWith('http') ? path
              : sb.storage.from('fotos').getPublicUrl(path).data?.publicUrl ?? null
          }

          return { tipo: tipoLabel, data_hora: p.data_hora, autor: p.autor?.nome_completo ?? '—', fotoUrl, justificativa }
        }))

        // Ocorrências
        const { data: ocorrs } = await sb
          .from('ocorrencias')
          .select('descricao, data_hora, tipo:dom_tipos_ocorrencia(nome), autor:usuarios!registrado_por(nome_completo), foto:fotos!foto_id(caminho_arquivo)')
          .eq('escolta_id', id)
          .order('data_hora', { ascending: true })

        const ocorrencias = await Promise.all((ocorrs ?? []).map(async (o: any) => {
          let fotoUrl: string | null = null
          if (o.foto?.caminho_arquivo) {
            const path = o.foto.caminho_arquivo as string
            fotoUrl = path.startsWith('http') ? path
              : sb.storage.from('fotos').getPublicUrl(path).data?.publicUrl ?? null
          }
          return {
            tipo: o.tipo?.nome ?? 'Ocorrência',
            descricao: o.descricao ?? '',
            data_hora: o.data_hora,
            autor: o.autor?.nome_completo ?? '—',
            fotoUrl,
          }
        }))

        // Checklists
        const { data: chks } = viatIds.length > 0
          ? await sb.from('checklists')
              .select('tipo, data_conclusao, autor:usuarios!responsavel_id(nome_completo), respostas:checklist_respostas(conforme)')
              .in('escolta_veiculo_id', viatIds)
              .not('data_conclusao', 'is', null)
          : { data: [] }

        const checklists = (chks ?? []).map((c: any) => {
          const total = (c.respostas ?? []).length
          const conformes = (c.respostas ?? []).filter((r: any) => r.conforme).length
          return {
            tipo: c.tipo === 'viatura' ? 'Checklist de Viatura' : 'Checklist de Material',
            data_conclusao: c.data_conclusao,
            autor: c.autor?.nome_completo ?? 'Supervisor',
            conformes,
            total,
          }
        })

        setDados({ escolta: esc, viaturas, historico, pontos, ocorrencias, checklists })
      } catch (e: any) {
        setErro(e.message ?? 'Erro ao carregar dados.')
      } finally {
        setLoading(false)
      }
    }

    carregar()
  }, [id])

  // Auto-print quando carregado dentro de iframe (detector: window !== top)
  useEffect(() => {
    if (!loading && dados && window !== window.top) {
      const t = setTimeout(() => window.print(), 600)
      return () => clearTimeout(t)
    }
  }, [loading, dados])

  if (loading) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', fontFamily: 'sans-serif', color: '#555' }}>
        Carregando dados para impressão…
      </div>
    )
  }

  if (erro || !dados) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100vh', fontFamily: 'sans-serif', color: '#B83832' }}>
        {erro ?? 'Dados não encontrados.'}
      </div>
    )
  }

  const { escolta, viaturas, historico, pontos, ocorrencias, checklists } = dados
  const statusLabel = STATUS_LABEL[escolta.status] ?? escolta.status
  const isFinalizada = escolta.status === 'finalizada'

  // Timeline unificada (status + pontos), ordenada por data
  const tlEventos: Array<{ data_hora: string; label: string; obs?: string; tipo: string }> = [
    ...historico
      .filter(h => !['rascunho', 'agendada'].includes(h.status_novo))
      .map(h => ({
        data_hora: h.data_hora,
        label: TL_LABEL[h.status_novo] ?? STATUS_LABEL[h.status_novo] ?? h.status_novo,
        obs: h.observacao ?? undefined,
        tipo: 'status',
      })),
    ...checklists.map(c => ({
      data_hora: c.data_conclusao,
      label: c.tipo,
      obs: `${c.conformes}/${c.total} itens conformes`,
      tipo: 'checklist',
    })),
    ...pontos.map(p => ({
      data_hora: p.data_hora,
      label: p.tipo,
      obs: p.justificativa || undefined,
      tipo: 'ponto',
    })),
    ...ocorrencias.map(o => ({
      data_hora: o.data_hora,
      label: `Ocorrência: ${o.tipo}`,
      obs: o.descricao.slice(0, 120),
      tipo: 'ocorrencia',
    })),
  ].sort((a, b) => new Date(a.data_hora).getTime() - new Date(b.data_hora).getTime())

  // Duração
  const inicioHist = historico.find(h => h.status_novo === 'em_andamento')
  const fimHist = escolta.data_finalizacao ?? historico.slice(-1)[0]?.data_hora
  let duracao = '—'
  if (inicioHist && fimHist) {
    const ms = new Date(fimHist).getTime() - new Date(inicioHist.data_hora).getTime()
    const h = Math.floor(ms / 3600000)
    const m = Math.floor((ms % 3600000) / 60000)
    duracao = `${h}h ${m}min`
  }

  const totalKm = viaturas.reduce((acc, v) => {
    if (v.quilometragem_saida != null && v.quilometragem_retorno != null)
      return acc + (v.quilometragem_retorno - v.quilometragem_saida)
    return acc
  }, 0)

  const c: React.CSSProperties = {
    fontFamily: "'Segoe UI', Arial, sans-serif",
    fontSize: '11px',
    color: '#1A2535',
    lineHeight: '1.5',
    maxWidth: '800px',
    margin: '0 auto',
    padding: '32px 40px',
    background: '#fff',
  }

  const sectionTitle = (title: string): React.CSSProperties => ({
    fontSize: '10px', fontWeight: 800, letterSpacing: '0.1em',
    textTransform: 'uppercase', color: '#4A6B7A',
    borderBottom: '1.5px solid #E0E8ED', paddingBottom: '4px',
    marginBottom: '10px', marginTop: '20px',
  })

  const tableSt: React.CSSProperties = {
    width: '100%', borderCollapse: 'collapse', fontSize: '11px',
  }

  const th: React.CSSProperties = {
    background: '#F3F6F8', padding: '6px 8px', fontWeight: 700,
    textAlign: 'left', borderBottom: '1px solid #D5E0E6', fontSize: '10px',
  }

  const td: React.CSSProperties = {
    padding: '6px 8px', borderBottom: '1px solid #EEF2F4', verticalAlign: 'top',
  }

  return (
    <>
      <style>{`
        * { box-sizing: border-box; }

        @media screen {
          body { background: #e8edf2; }
          .print-container {
            box-shadow: 0 4px 32px rgba(0,0,0,0.15);
            margin: 40px auto 60px;
            border-radius: 2px;
          }
        }

        @media print {
          html, body {
            width: auto !important;
            height: auto !important;
            overflow: visible !important;
            margin: 0 !important;
            padding: 0 !important;
            background: #fff !important;
          }
          .no-print { display: none !important; }
          .print-container {
            max-width: none !important;
            width: 100% !important;
            margin: 0 !important;
            padding: 0 !important;
            box-shadow: none !important;
          }
          table {
            page-break-inside: auto;
            width: 100%;
          }
          tr {
            page-break-inside: avoid;
            page-break-after: auto;
          }
          thead {
            display: table-header-group;
          }
          tfoot {
            display: table-footer-group;
          }
          .section-block {
            page-break-inside: avoid;
            break-inside: avoid;
          }
          .ocorrencia-block {
            page-break-inside: avoid;
            break-inside: avoid;
          }
          * {
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
          }
          @page {
            margin: 14mm 12mm;
            size: A4 portrait;
          }
        }
      `}</style>

      {/* Botão imprimir (só na tela) */}
      <div className="no-print" style={{
        position: 'fixed', top: '16px', right: '16px', zIndex: 1000,
        display: 'flex', gap: '8px',
      }}>
        <button
          onClick={() => window.print()}
          style={{
            background: '#1A2F4A', color: '#fff', border: 'none',
            padding: '8px 18px', borderRadius: '4px', cursor: 'pointer',
            fontSize: '12px', fontWeight: 700, letterSpacing: '0.05em',
          }}
        >
          Imprimir / Salvar PDF
        </button>
        <button
          onClick={() => window.close()}
          style={{
            background: '#E8EFF3', color: '#1A2F4A', border: 'none',
            padding: '8px 14px', borderRadius: '4px', cursor: 'pointer',
            fontSize: '12px', fontWeight: 700,
          }}
        >
          Fechar
        </button>
      </div>

      <div style={c} className="print-container">

        {/* ── Cabeçalho ── */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '20px', paddingBottom: '16px', borderBottom: '2px solid #1A2F4A' }}>
          <div>
            <div style={{ fontSize: '9px', fontWeight: 800, letterSpacing: '0.15em', textTransform: 'uppercase', color: '#4A6B7A', marginBottom: '4px' }}>
              Relatório de Operação
            </div>
            <div style={{ fontSize: '22px', fontWeight: 800, color: '#1A2F4A', letterSpacing: '-0.5px', lineHeight: 1 }}>
              {escolta.codigo_escolta ?? 'Escolta'}
            </div>
            <div style={{ fontSize: '13px', color: '#3A6A8A', fontWeight: 600, marginTop: '4px' }}>
              {escolta.cliente?.nome_cliente ?? '—'}
            </div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div style={{
              display: 'inline-block', padding: '4px 12px', borderRadius: '3px',
              background: isFinalizada ? '#E8F5EE' : '#EBF3FC',
              color: isFinalizada ? '#1E7C52' : '#2166A8',
              fontWeight: 800, fontSize: '11px', letterSpacing: '0.06em',
              textTransform: 'uppercase', marginBottom: '6px',
            }}>
              {statusLabel}
            </div>
            <div style={{ fontSize: '10px', color: '#7A8FA0', marginTop: '4px' }}>
              Gerado em {new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}
            </div>
            {escolta.cliente?.telefone && (
              <div style={{ fontSize: '10px', color: '#7A8FA0', marginTop: '2px' }}>
                Tel: {escolta.cliente.telefone}
              </div>
            )}
          </div>
        </div>

        {/* ── Dados Gerais ── */}
        <div style={sectionTitle('aaaa')}>Informações da Operação</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '6px 24px', marginBottom: '4px' }}>
          <InfoRow label="Data / Hora Prevista" value={fmt(escolta.data_hora_prevista)} />
          {escolta.data_finalizacao && <InfoRow label="Data de Finalização" value={fmt(escolta.data_finalizacao)} />}
          {inicioHist && <InfoRow label="Início da Operação" value={fmt(inicioHist.data_hora)} />}
          <InfoRow label="Duração Total" value={duracao} />
          {totalKm > 0 && <InfoRow label="KM Total Percorrido" value={`${totalKm.toLocaleString('pt-BR')} km`} />}
        </div>

        {/* ── Rota ── */}
        <div style={sectionTitle('bbb')}>Rota</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '6px 24px' }}>
          <InfoRow label="Origem" value={escolta.origem_endereco} />
          <InfoRow label="Destino" value={escolta.destino_endereco} />
        </div>

        {/* ── Veículos ── */}
        {viaturas.length > 0 && (
          <>
            <div style={sectionTitle('ccc')}>Veículos</div>
            <table style={tableSt}>
              <thead>
                <tr>
                  <th style={th}>Placa</th>
                  <th style={th}>Modelo</th>
                  <th style={th}>Tipo</th>
                  <th style={th}>KM Saída</th>
                  <th style={th}>KM Retorno</th>
                  <th style={th}>KM Percorrido</th>
                </tr>
              </thead>
              <tbody>
                {viaturas.map((v, i) => (
                  <tr key={i}>
                    <td style={{ ...td, fontWeight: 700, fontFamily: 'monospace' }}>{fmtPlaca(v.placa)}</td>
                    <td style={td}>{v.modelo ?? '—'}</td>
                    <td style={td}>{v.tipo ?? '—'}</td>
                    <td style={td}>{v.quilometragem_saida?.toLocaleString('pt-BR') ?? '—'}</td>
                    <td style={td}>{v.quilometragem_retorno?.toLocaleString('pt-BR') ?? '—'}</td>
                    <td style={{ ...td, fontWeight: 700 }}>
                      {v.quilometragem_saida != null && v.quilometragem_retorno != null
                        ? `${(v.quilometragem_retorno - v.quilometragem_saida).toLocaleString('pt-BR')} km`
                        : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}

        {/* ── Efetivo ── */}
        {viaturas.some(v => v.efetivo.length > 0) && (
          <>
            <div style={sectionTitle('ddd')}>Efetivo Escalado</div>
            <table style={tableSt}>
              <thead>
                <tr>
                  <th style={th}>Nome</th>
                  <th style={th}>Papel na Escolta</th>
                  <th style={th}>Viatura</th>
                  <th style={th}>Confirmado</th>
                </tr>
              </thead>
              <tbody>
                {viaturas.flatMap(v =>
                  v.efetivo.map((e, i) => (
                    <tr key={`${v.id}-${i}`}>
                      <td style={{ ...td, fontWeight: 600 }}>{e.nome}</td>
                      <td style={td}>{e.papel}</td>
                      <td style={{ ...td, fontFamily: 'monospace', fontSize: '10px' }}>{fmtPlaca(v.placa)}</td>
                      <td style={td}>
                        <span style={{ color: e.confirmado ? '#1E7C52' : '#B83832', fontWeight: 700 }}>
                          {e.confirmado ? 'Sim' : 'Não'}
                        </span>
                      </td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </>
        )}

        {/* ── Linha do Tempo ── */}
        {tlEventos.length > 0 && (
          <>
            <div style={sectionTitle('eee')}>Linha do Tempo</div>
            <table style={tableSt}>
              <thead>
                <tr>
                  <th style={{ ...th, width: '140px' }}>Data / Hora</th>
                  <th style={th}>Evento</th>
                  <th style={th}>Observação</th>
                </tr>
              </thead>
              <tbody>
                {tlEventos.map((ev, i) => (
                  <tr key={i} style={{ background: ev.tipo === 'ocorrencia' ? '#FEF9EC' : ev.tipo === 'status' ? '#F7FAFC' : '#fff' }}>
                    <td style={{ ...td, fontFamily: 'monospace', fontSize: '10px', whiteSpace: 'nowrap', color: '#4A6B7A' }}>
                      {fmt(ev.data_hora)}
                    </td>
                    <td style={{ ...td, fontWeight: ev.tipo === 'status' ? 700 : 400, color: ev.tipo === 'ocorrencia' ? '#A07212' : '#1A2535' }}>
                      {ev.tipo === 'ocorrencia' ? `⚠ ${ev.label}` : ev.label}
                    </td>
                    <td style={{ ...td, color: '#6B7E8A', fontSize: '10px' }}>{ev.obs ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}

        {/* ── Ocorrências detalhadas ── */}
        {ocorrencias.length > 0 && (
          <>
            <div style={sectionTitle('fff')}>Ocorrências Registradas</div>
            {ocorrencias.map((o, i) => (
              <div key={i} className="ocorrencia-block" style={{ marginBottom: '12px', padding: '10px 12px', background: '#FEF9EC', border: '1px solid #F5E0A0', borderLeft: '3px solid #A07212', borderRadius: '3px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '4px' }}>
                  <span style={{ fontWeight: 700, fontSize: '11px', color: '#A07212' }}>⚠ {o.tipo}</span>
                  <span style={{ fontSize: '10px', color: '#6B7E8A', fontFamily: 'monospace' }}>{fmt(o.data_hora)}</span>
                </div>
                <div style={{ fontSize: '11px', color: '#1A2535' }}>{o.descricao}</div>
                <div style={{ fontSize: '10px', color: '#7A8FA0', marginTop: '4px' }}>Registrado por: {o.autor}</div>
                {o.fotoUrl && (
                  <img
                    src={o.fotoUrl}
                    alt="Foto da ocorrência"
                    style={{ marginTop: '8px', maxWidth: '240px', maxHeight: '160px', objectFit: 'cover', borderRadius: '3px', border: '1px solid #E0C87A' }}
                  />
                )}
              </div>
            ))}
          </>
        )}

        {/* ── Relatório Final ── */}
        {isFinalizada && escolta.observacao_fechamento && (
          <>
            <div style={sectionTitle('ggg')}>Relatório Final</div>
            <div style={{ padding: '12px 14px', background: '#F7FAFC', border: '1px solid #D5E0E6', borderLeft: '3px solid #1A2F4A', borderRadius: '3px', fontSize: '11px', lineHeight: '1.7', color: '#1A2535', whiteSpace: 'pre-wrap' }}>
              {escolta.observacao_fechamento}
            </div>
          </>
        )}

        {/* ── Financeiro ── */}
        {(escolta.valor_cobrado != null || escolta.outros_custos != null) && (
          <>
            <div style={sectionTitle('hhh')}>Financeiro</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '6px 24px' }}>
              {escolta.valor_cobrado != null && (
                <InfoRow label="Valor Cobrado"
                  value={escolta.valor_cobrado.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })} />
              )}
              {escolta.outros_custos != null && (
                <InfoRow label="Outros Custos"
                  value={escolta.outros_custos.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })} />
              )}
            </div>
          </>
        )}

        {/* ── Rodapé ── */}
        <div style={{ marginTop: '32px', paddingTop: '12px', borderTop: '1px solid #E0E8ED', display: 'flex', justifyContent: 'space-between', fontSize: '9px', color: '#9AAAB8' }}>
          <span>Sistema Escolta Armada — Documento gerado automaticamente</span>
          <span>{escolta.codigo_escolta ?? ''} · {new Date().toLocaleDateString('pt-BR')}</span>
        </div>

      </div>
    </>
  )
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div style={{ padding: '4px 0' }}>
      <span style={{ fontSize: '9px', fontWeight: 700, letterSpacing: '0.08em', textTransform: 'uppercase', color: '#7A8FA0', display: 'block' }}>
        {label}
      </span>
      <span style={{ fontSize: '11px', color: '#1A2535', fontWeight: 500 }}>{value}</span>
    </div>
  )
}
