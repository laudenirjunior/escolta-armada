'use client'

import { useEffect, useState, useCallback } from 'react'
import { useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

const sb = createClient() as any

// ─── Tipos ───────────────────────────────────────────────────────────────────
type SecaoId = 'capa' | 'resumo' | 'escoltas' | 'clientes' | 'ocorrencias' | 'efetivo' | 'frota' | 'financeiro' | 'checklists' | 'sla'

interface EscoltaPDF {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  data_finalizacao: string | null
  origem_endereco: string | null
  destino_endereco: string | null
  valor_cobrado: number | null
  outros_custos: number | null
  cliente: { id: string; nome_cliente: string; cor_destaque: string | null } | null
  veiculos: { quilometragem_saida: number; quilometragem_retorno: number | null; abastecimento_valor: number | null; abastecimento_litros: number | null }[]
  efetivo: { valor_pago_vigilante: number | null; papel: string | null; confirmado: boolean; vigilante: { nome_completo: string } | null }[]
}
interface OcorrenciaPDF {
  id: string; descricao: string; data_hora: string
  tipo: { nome: string } | null
  autor: { nome_completo: string } | null
  escolta: { codigo_escolta: string | null } | null
}
interface ChecklistPDF {
  id: string; tipo: string | null; concluido: boolean; data_inicio: string | null; data_conclusao: string | null
  respostas: { conforme: boolean | null; descricao_item: string | null }[]
}
interface VigPDF {
  nome: string; funcao: string | null
  escalacoes: number; confirmacoes: number; valor_total: number
}
interface VeiculoPDF {
  id: string; placa: string; modelo: string | null
  operacoes: number; km_total: number; litros: number; custo_comb: number
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
const STATUS_LABEL: Record<string, string> = {
  rascunho: 'Rascunho', agendada: 'Agendada', em_pre_inicio: 'Pré-Início',
  em_andamento: 'Em Andamento', na_origem: 'Na Origem', em_transito_destino: 'Trânsito p/ Destino', no_destino: 'No Destino',
  retornando: 'Retornando', na_base: 'Na Base', finalizada: 'Finalizada', cancelada: 'Cancelada',
}
function fmt(iso: string) {
  return new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}
function fmtData(iso: string) {
  return new Date(iso).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric' })
}
function calcKm(v: { quilometragem_saida: number; quilometragem_retorno: number | null }[]) {
  return v.reduce((s, x) => s + Math.max(0, (x.quilometragem_retorno ?? x.quilometragem_saida) - x.quilometragem_saida), 0)
}
function calcDurMin(e: { data_hora_prevista: string; data_finalizacao: string | null }) {
  const fim = e.data_finalizacao ? new Date(e.data_finalizacao) : new Date()
  return Math.floor((fim.getTime() - new Date(e.data_hora_prevista).getTime()) / 60000)
}
function fmtDur(min: number) {
  if (min < 0) return '—'
  const h = Math.floor(min / 60), m = min % 60
  return h === 0 ? `${m}min` : `${h}h${m.toString().padStart(2, '0')}m`
}
function fmtBRL(v: number) { return v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }) }

// ─── Cabeçalho com logos (aparece em todas as seções no topo) ────────────────
function CabecalhoLogos({ clienteLogoUrl, clienteNome }: { clienteLogoUrl?: string; clienteNome?: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '14px 60px', borderBottom: '1px solid #EBF0F8', backgroundColor: '#F5F7FA' }}>
      {/* Logo Esquematiza */}
      <img src="/logo.png" alt="Esquematiza" style={{ height: '32px', objectFit: 'contain' }} />
      {/* Logo do cliente */}
      {clienteLogoUrl && (
        <img src={clienteLogoUrl} alt={clienteNome ?? 'Cliente'} style={{ height: '32px', maxWidth: '160px', objectFit: 'contain' }} />
      )}
    </div>
  )
}

// ─── Componentes de Seção ────────────────────────────────────────────────────
function SecaoCapa({ clienteNome, clienteLogoUrl, periodo }: { clienteNome: string; clienteLogoUrl?: string; periodo: string }) {
  const agora = new Date().toLocaleDateString('pt-BR', { day: '2-digit', month: 'long', year: 'numeric' })
  return (
    <div className="secao capa" style={{ minHeight: '100vh', display: 'flex', flexDirection: 'column', justifyContent: 'space-between', padding: '0' }}>
      {/* Topo: logos */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '32px 60px 24px', borderBottom: '1px solid #EBF0F8' }}>
        <img src="/logo.png" alt="Esquematiza" style={{ height: '40px', objectFit: 'contain' }} />
        {clienteLogoUrl && (
          <img src={clienteLogoUrl} alt={clienteNome} style={{ height: '40px', maxWidth: '180px', objectFit: 'contain' }} />
        )}
      </div>

      {/* Corpo principal */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', padding: '60px' }}>
        <div style={{ borderBottom: '3px solid #1E7C52', paddingBottom: '32px', marginBottom: '32px' }}>
          <p style={{ fontSize: '11px', fontWeight: 800, letterSpacing: '0.2em', textTransform: 'uppercase', color: '#1E7C52', marginBottom: '16px' }}>Escolta Armada · Plataforma de Gestão</p>
          <h1 style={{ fontSize: '40px', fontWeight: 900, color: '#0E1A33', lineHeight: 1.2, marginBottom: '8px' }}>Relatório Operacional</h1>
          <p style={{ fontSize: '16px', color: '#53648A' }}>Documento gerado automaticamente pelo sistema</p>
        </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '40px' }}>
        <div>
          <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.15em', color: '#ABB5C9', marginBottom: '6px' }}>Cliente / Destino</p>
          <p style={{ fontSize: '20px', fontWeight: 700, color: '#0E1A33' }}>{clienteNome || 'Todos os Clientes'}</p>
        </div>
        <div>
          <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.15em', color: '#ABB5C9', marginBottom: '6px' }}>Período de Análise</p>
          <p style={{ fontSize: '18px', fontWeight: 700, color: '#0E1A33' }}>{periodo}</p>
        </div>
        <div>
          <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.15em', color: '#ABB5C9', marginBottom: '6px' }}>Data de Emissão</p>
          <p style={{ fontSize: '16px', fontWeight: 600, color: '#53648A' }}>{agora}</p>
        </div>
        <div>
          <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.15em', color: '#ABB5C9', marginBottom: '6px' }}>Classificação</p>
          <p style={{ fontSize: '16px', fontWeight: 600, color: '#53648A' }}>Documento Confidencial</p>
        </div>
      </div>
      </div>
    </div>
  )
}

function SecaoResumo({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const total = escoltas.length
  const concluidas = escoltas.filter(e => e.status === 'finalizada').length
  const canceladas = escoltas.filter(e => e.status === 'cancelada').length
  const ativas = escoltas.filter(e => ['em_andamento','na_origem','em_transito_destino','no_destino','retornando','na_base'].includes(e.status)).length
  const kmTotal = escoltas.reduce((s, e) => s + calcKm(e.veiculos), 0)
  const txConc = (concluidas + canceladas) > 0 ? Math.round((concluidas / (concluidas + canceladas)) * 100) : 0
  const duracaoMedia = concluidas > 0 ? Math.round(escoltas.filter(e => e.status === 'finalizada').reduce((s, e) => s + calcDurMin(e), 0) / concluidas) : 0

  const kpis = [
    { label: 'Total de Escoltas', valor: total.toString(), cor: '#0E1A33' },
    { label: 'Concluídas', valor: concluidas.toString(), cor: '#1E7C52' },
    { label: 'Canceladas', valor: canceladas.toString(), cor: '#B83832' },
    { label: 'Em Andamento', valor: ativas.toString(), cor: '#53648A' },
    { label: 'KM Total', valor: `${kmTotal.toLocaleString('pt-BR')} km`, cor: '#0E1A33' },
    { label: 'Taxa de Conclusão', valor: `${txConc}%`, cor: txConc >= 80 ? '#1E7C52' : '#B83832' },
    { label: 'Duração Média', valor: fmtDur(duracaoMedia), cor: '#53648A' },
    { label: 'KM Médio', valor: `${concluidas > 0 ? Math.round(kmTotal/concluidas) : 0} km/esc`, cor: '#53648A' },
  ]

  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">01</span><h2>Resumo Executivo</h2></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '12px', marginBottom: '24px' }}>
        {kpis.map(k => (
          <div key={k.label} style={{ border: '1px solid #D6DAE5', borderRadius: '2px', padding: '14px 16px' }}>
            <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, marginBottom: '4px', fontVariantNumeric: 'tabular-nums' }}>{k.valor}</p>
            <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#ABB5C9' }}>{k.label}</p>
          </div>
        ))}
      </div>
      {/* Distribuição por status */}
      <div style={{ border: '1px solid #D6DAE5', borderRadius: '2px', padding: '16px' }}>
        <p style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#53648A', marginBottom: '14px' }}>Distribuição por Status</p>
        {Object.entries(STATUS_LABEL).map(([key, label]) => {
          const count = escoltas.filter(e => e.status === key).length
          if (!count) return null
          const pct = total > 0 ? (count / total) * 100 : 0
          return (
            <div key={key} style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' }}>
              <span style={{ width: '140px', fontSize: '12px', color: '#0E1A33' }}>{label}</span>
              <div style={{ flex: 1, height: '8px', backgroundColor: '#EBF0F8', borderRadius: '2px' }}>
                <div style={{ width: `${pct}%`, height: '100%', backgroundColor: key === 'finalizada' ? '#1E7C52' : key === 'cancelada' ? '#B83832' : '#1A294A', borderRadius: '2px' }} />
              </div>
              <span style={{ width: '30px', textAlign: 'right', fontSize: '11px', fontWeight: 700, color: '#0E1A33', fontVariantNumeric: 'tabular-nums' }}>{count}</span>
              <span style={{ width: '36px', textAlign: 'right', fontSize: '10px', color: '#ABB5C9', fontVariantNumeric: 'tabular-nums' }}>{pct.toFixed(0)}%</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function SecaoEscoltas({ escoltas }: { escoltas: EscoltaPDF[] }) {
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">02</span><h2>Lista de Escoltas</h2></div>
      <p style={{ fontSize: '11px', color: '#53648A', marginBottom: '16px' }}>{escoltas.length} escolta{escoltas.length !== 1 ? 's' : ''} no período selecionado</p>
      <table className="tabela">
        <thead>
          <tr>
            <th>Código</th><th>Cliente</th><th>Origem → Destino</th><th>Status</th><th>Data Prevista</th><th>Finalização</th><th>Duração</th><th>KM</th>
          </tr>
        </thead>
        <tbody>
          {escoltas.map(e => (
            <tr key={e.id}>
              <td style={{ fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{e.codigo_escolta ?? '—'}</td>
              <td>{e.cliente?.nome_cliente ?? '—'}</td>
              <td style={{ fontSize: '10px', maxWidth: '200px' }}>
                <span style={{ display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {(e.origem_endereco ?? '—').split(',')[0]} → {(e.destino_endereco ?? '—').split(',')[0]}
                </span>
              </td>
              <td><span className={`status-badge status-${e.status}`}>{STATUS_LABEL[e.status] ?? e.status}</span></td>
              <td style={{ fontVariantNumeric: 'tabular-nums', fontSize: '10px' }}>{fmt(e.data_hora_prevista)}</td>
              <td style={{ fontVariantNumeric: 'tabular-nums', fontSize: '10px' }}>{e.data_finalizacao ? fmt(e.data_finalizacao) : '—'}</td>
              <td style={{ fontVariantNumeric: 'tabular-nums' }}>{fmtDur(calcDurMin(e))}</td>
              <td style={{ fontVariantNumeric: 'tabular-nums' }}>{calcKm(e.veiculos).toLocaleString('pt-BR')}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <td colSpan={7} style={{ fontWeight: 900, textAlign: 'right' }}>Total KM:</td>
            <td style={{ fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{escoltas.reduce((s,e) => s + calcKm(e.veiculos), 0).toLocaleString('pt-BR')}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  )
}

function SecaoClientes({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const map: Record<string, { nome: string; total: number; conc: number; canc: number; km: number; durMin: number }> = {}
  for (const e of escoltas) {
    const k = e.cliente?.id ?? '__'
    if (!map[k]) map[k] = { nome: e.cliente?.nome_cliente ?? 'Sem cliente', total: 0, conc: 0, canc: 0, km: 0, durMin: 0 }
    map[k].total++
    if (e.status === 'finalizada') { map[k].conc++; map[k].durMin += calcDurMin(e) }
    if (e.status === 'cancelada') map[k].canc++
    map[k].km += calcKm(e.veiculos)
  }
  const clientes = Object.values(map).sort((a, b) => b.total - a.total)
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">03</span><h2>Análise por Cliente</h2></div>
      <table className="tabela">
        <thead>
          <tr><th>Cliente</th><th>Total</th><th>Concluídas</th><th>Canceladas</th><th>Taxa Conclusão</th><th>KM Total</th><th>Duração Média</th></tr>
        </thead>
        <tbody>
          {clientes.map(c => {
            const tx = (c.conc + c.canc) > 0 ? Math.round((c.conc / (c.conc + c.canc)) * 100) : 0
            return (
              <tr key={c.nome}>
                <td style={{ fontWeight: 700 }}>{c.nome}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{c.total}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', color: '#1E7C52', fontWeight: 700 }}>{c.conc}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', color: c.canc > 0 ? '#B83832' : '#ABB5C9' }}>{c.canc}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 700, color: tx >= 80 ? '#1E7C52' : '#B83832' }}>{tx}%</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{c.km.toLocaleString('pt-BR')} km</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{fmtDur(c.conc > 0 ? Math.round(c.durMin / c.conc) : 0)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function SecaoOcorrencias({ ocorrencias }: { ocorrencias: OcorrenciaPDF[] }) {
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">04</span><h2>Ocorrências</h2></div>
      {ocorrencias.length === 0 ? (
        <p style={{ color: '#ABB5C9', fontStyle: 'italic', fontSize: '13px' }}>Nenhuma ocorrência registrada no período.</p>
      ) : (
        <table className="tabela">
          <thead>
            <tr><th>Data/Hora</th><th>Escolta</th><th>Tipo</th><th>Descrição</th><th>Registrado por</th></tr>
          </thead>
          <tbody>
            {ocorrencias.map(o => (
              <tr key={o.id}>
                <td style={{ fontVariantNumeric: 'tabular-nums', fontSize: '10px', whiteSpace: 'nowrap' }}>{fmt(o.data_hora)}</td>
                <td style={{ fontWeight: 700 }}>{o.escolta?.codigo_escolta ?? '—'}</td>
                <td>{o.tipo?.nome ?? '—'}</td>
                <td style={{ fontSize: '11px' }}>{o.descricao}</td>
                <td style={{ fontSize: '10px' }}>{o.autor?.nome_completo ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}

function SecaoSLA({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const SLA_MIN = 600
  const finalizadas = escoltas.filter(e => e.status === 'finalizada')
  const comDesvio = finalizadas.filter(e => calcDurMin(e) > SLA_MIN)
  const dentroSLA = finalizadas.filter(e => calcDurMin(e) <= SLA_MIN)
  const txSLA = finalizadas.length > 0 ? Math.round((dentroSLA.length / finalizadas.length) * 100) : 100
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">05</span><h2>SLA e Pontualidade</h2></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px', marginBottom: '20px' }}>
        {[
          { label: 'Dentro do SLA', valor: `${dentroSLA.length}`, cor: '#1E7C52' },
          { label: 'Acima do SLA (>10h)', valor: `${comDesvio.length}`, cor: comDesvio.length > 0 ? '#B83832' : '#ABB5C9' },
          { label: 'Taxa SLA', valor: `${txSLA}%`, cor: txSLA >= 90 ? '#1E7C52' : '#B83832' },
        ].map(k => (
          <div key={k.label} style={{ border: '1px solid #D6DAE5', borderRadius: '2px', padding: '14px 16px' }}>
            <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums' }}>{k.valor}</p>
            <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#ABB5C9' }}>{k.label}</p>
          </div>
        ))}
      </div>
      {comDesvio.length > 0 && (
        <>
          <p style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#B83832', marginBottom: '10px' }}>Escoltas que excederam o SLA</p>
          <table className="tabela">
            <thead><tr><th>Código</th><th>Cliente</th><th>Data</th><th>Duração Real</th><th>Excesso</th></tr></thead>
            <tbody>
              {comDesvio.sort((a, b) => calcDurMin(b) - calcDurMin(a)).map(e => {
                const dur = calcDurMin(e)
                return (
                  <tr key={e.id}>
                    <td style={{ fontWeight: 700 }}>{e.codigo_escolta}</td>
                    <td>{e.cliente?.nome_cliente ?? '—'}</td>
                    <td style={{ fontSize: '10px', fontVariantNumeric: 'tabular-nums' }}>{fmtData(e.data_hora_prevista)}</td>
                    <td style={{ fontVariantNumeric: 'tabular-nums', color: '#B83832', fontWeight: 700 }}>{fmtDur(dur)}</td>
                    <td style={{ fontVariantNumeric: 'tabular-nums', color: '#B83832' }}>+{fmtDur(dur - SLA_MIN)}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

function SecaoEfetivo({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const map: Record<string, VigPDF> = {}
  for (const e of escoltas) {
    for (const ef of e.efetivo) {
      const nome = ef.vigilante?.nome_completo ?? 'Desconhecido'
      if (!map[nome]) map[nome] = { nome, funcao: ef.papel, escalacoes: 0, confirmacoes: 0, valor_total: 0 }
      map[nome].escalacoes++
      if (ef.confirmado) map[nome].confirmacoes++
      map[nome].valor_total += ef.valor_pago_vigilante ?? 0
    }
  }
  const vigs = Object.values(map).sort((a, b) => b.escalacoes - a.escalacoes)
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">06</span><h2>Efetivo / Vigilantes</h2></div>
      {vigs.length === 0 ? <p style={{ color: '#ABB5C9', fontStyle: 'italic' }}>Sem dados de efetivo no período.</p> : (
        <table className="tabela">
          <thead><tr><th>Vigilante</th><th>Função</th><th>Escalações</th><th>Confirmações</th><th>Presença</th><th>Remuneração</th></tr></thead>
          <tbody>
            {vigs.map(v => (
              <tr key={v.nome}>
                <td style={{ fontWeight: 700 }}>{v.nome}</td>
                <td style={{ fontSize: '10px' }}>{v.funcao ?? '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{v.escalacoes}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{v.confirmacoes}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', color: v.escalacoes > 0 ? (v.confirmacoes/v.escalacoes >= 0.9 ? '#1E7C52' : '#B83832') : '#ABB5C9' }}>
                  {v.escalacoes > 0 ? `${Math.round((v.confirmacoes/v.escalacoes)*100)}%` : '—'}
                </td>
                <td style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 700 }}>{v.valor_total > 0 ? fmtBRL(v.valor_total) : '—'}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={5} style={{ fontWeight: 900, textAlign: 'right' }}>Total remuneração:</td>
              <td style={{ fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(vigs.reduce((s,v) => s + v.valor_total, 0))}</td>
            </tr>
          </tfoot>
        </table>
      )}
    </div>
  )
}

function SecaoFrota({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const map: Record<string, VeiculoPDF> = {}
  for (const e of escoltas) {
    for (const v of e.veiculos as any[]) {
      const id = v.veiculo_id ?? v.id ?? 'x'
      const placa = v.placa ?? v.veiculo?.placa ?? '—'
      const modelo = v.modelo ?? v.veiculo?.modelo ?? null
      if (!map[id]) map[id] = { id, placa, modelo, operacoes: 0, km_total: 0, litros: 0, custo_comb: 0 }
      map[id].operacoes++
      map[id].km_total += Math.max(0, (v.quilometragem_retorno ?? v.quilometragem_saida) - v.quilometragem_saida)
      map[id].litros += v.abastecimento_litros ?? 0
      map[id].custo_comb += v.abastecimento_valor ?? 0
    }
  }
  const veiculos = Object.values(map).sort((a, b) => b.operacoes - a.operacoes)
  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">07</span><h2>Frota e Combustível</h2></div>
      {veiculos.length === 0 ? <p style={{ color: '#ABB5C9', fontStyle: 'italic' }}>Sem dados de frota no período.</p> : (
        <table className="tabela">
          <thead><tr><th>Placa</th><th>Modelo</th><th>Operações</th><th>KM Rodado</th><th>Litros</th><th>Custo Combustível</th></tr></thead>
          <tbody>
            {veiculos.map(v => (
              <tr key={v.id}>
                <td style={{ fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{v.placa}</td>
                <td>{v.modelo ?? '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{v.operacoes}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{v.km_total.toLocaleString('pt-BR')} km</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{v.litros > 0 ? `${v.litros.toFixed(1)} L` : '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', fontWeight: v.custo_comb > 0 ? 700 : 400 }}>{v.custo_comb > 0 ? fmtBRL(v.custo_comb) : '—'}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={3} style={{ fontWeight: 900, textAlign: 'right' }}>Totais:</td>
              <td style={{ fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{veiculos.reduce((s,v) => s + v.km_total,0).toLocaleString('pt-BR')} km</td>
              <td style={{ fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{veiculos.reduce((s,v) => s + v.litros, 0).toFixed(1)} L</td>
              <td style={{ fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(veiculos.reduce((s,v) => s + v.custo_comb, 0))}</td>
            </tr>
          </tfoot>
        </table>
      )}
    </div>
  )
}

function SecaoFinanceiro({ escoltas }: { escoltas: EscoltaPDF[] }) {
  const total_faturado = escoltas.reduce((s, e) => s + (e.valor_cobrado ?? 0), 0)
  const total_outros = escoltas.reduce((s, e) => s + (e.outros_custos ?? 0), 0)
  const total_efetivo = escoltas.reduce((s, e) => s + e.efetivo.reduce((se, ef) => se + (ef.valor_pago_vigilante ?? 0), 0), 0)
  const total_combustivel = escoltas.reduce((s, e) => s + e.veiculos.reduce((sv, v) => sv + (v.abastecimento_valor ?? 0), 0), 0)
  const total_custos = total_outros + total_efetivo + total_combustivel
  const margem = total_faturado - total_custos

  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">08</span><h2>Financeiro</h2></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: '12px', marginBottom: '24px' }}>
        {[
          { label: 'Faturamento Total', valor: fmtBRL(total_faturado), cor: '#1E7C52', destaque: true },
          { label: 'Margem Estimada', valor: fmtBRL(margem), cor: margem >= 0 ? '#1E7C52' : '#B83832', destaque: true },
          { label: 'Custo Efetivo', valor: fmtBRL(total_efetivo), cor: '#53648A', destaque: false },
          { label: 'Custo Combustível', valor: fmtBRL(total_combustivel), cor: '#53648A', destaque: false },
          { label: 'Outros Custos', valor: fmtBRL(total_outros), cor: '#53648A', destaque: false },
          { label: 'Total de Custos', valor: fmtBRL(total_custos), cor: '#B83832', destaque: false },
        ].map(k => (
          <div key={k.label} style={{ border: `1px solid ${k.destaque ? k.cor : '#D6DAE5'}`, borderRadius: '2px', padding: '14px 16px', backgroundColor: k.destaque ? 'rgba(30,124,82,0.04)' : '#fff' }}>
            <p style={{ fontSize: k.destaque ? '22px' : '18px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums' }}>{k.valor}</p>
            <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#ABB5C9' }}>{k.label}</p>
          </div>
        ))}
      </div>
      <p style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#53648A', marginBottom: '10px' }}>Por Escolta</p>
      <table className="tabela">
        <thead><tr><th>Código</th><th>Cliente</th><th>Faturado</th><th>Custo Efetivo</th><th>Custo Comb.</th><th>Outros</th><th>Margem</th></tr></thead>
        <tbody>
          {escoltas.filter(e => e.valor_cobrado).map(e => {
            const fat = e.valor_cobrado ?? 0
            const efet = e.efetivo.reduce((s, ef) => s + (ef.valor_pago_vigilante ?? 0), 0)
            const comb = e.veiculos.reduce((s, v) => s + (v.abastecimento_valor ?? 0), 0)
            const out = e.outros_custos ?? 0
            const mg = fat - efet - comb - out
            return (
              <tr key={e.id}>
                <td style={{ fontWeight: 700 }}>{e.codigo_escolta}</td>
                <td>{e.cliente?.nome_cliente ?? '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', color: '#1E7C52' }}>{fmtBRL(fat)}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{efet > 0 ? fmtBRL(efet) : '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{comb > 0 ? fmtBRL(comb) : '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums' }}>{out > 0 ? fmtBRL(out) : '—'}</td>
                <td style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 700, color: mg >= 0 ? '#1E7C52' : '#B83832' }}>{fmtBRL(mg)}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function SecaoChecklists({ checklists }: { checklists: ChecklistPDF[] }) {
  const total = checklists.length
  const concluidos = checklists.filter(c => c.concluido).length
  const totalItens = checklists.reduce((s, c) => s + c.respostas.length, 0)
  const conformes = checklists.reduce((s, c) => s + c.respostas.filter(r => r.conforme === true).length, 0)
  const txConf = totalItens > 0 ? Math.round((conformes / totalItens) * 100) : 0

  const reprovados: Record<string, number> = {}
  for (const c of checklists) {
    for (const r of c.respostas) {
      if (r.conforme === false && r.descricao_item) {
        reprovados[r.descricao_item] = (reprovados[r.descricao_item] ?? 0) + 1
      }
    }
  }
  const top5Rep = Object.entries(reprovados).sort((a, b) => b[1] - a[1]).slice(0, 5)

  return (
    <div className="secao">
      <div className="secao-header"><span className="secao-num">09</span><h2>Conformidade de Checklists</h2></div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '12px', marginBottom: '20px' }}>
        {[
          { label: 'Checklists', valor: `${concluidos}/${total}`, cor: '#0E1A33' },
          { label: 'Itens Avaliados', valor: totalItens.toString(), cor: '#53648A' },
          { label: 'Conformes', valor: conformes.toString(), cor: '#1E7C52' },
          { label: 'Taxa Conformidade', valor: `${txConf}%`, cor: txConf >= 90 ? '#1E7C52' : '#B83832' },
        ].map(k => (
          <div key={k.label} style={{ border: '1px solid #D6DAE5', borderRadius: '2px', padding: '14px 16px' }}>
            <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums' }}>{k.valor}</p>
            <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em', color: '#ABB5C9' }}>{k.label}</p>
          </div>
        ))}
      </div>
      {top5Rep.length > 0 && (
        <>
          <p style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: '#B83832', marginBottom: '10px' }}>Itens mais reprovados</p>
          <table className="tabela">
            <thead><tr><th>Item</th><th>Reprovações</th></tr></thead>
            <tbody>
              {top5Rep.map(([item, count]) => (
                <tr key={item}><td>{item}</td><td style={{ fontVariantNumeric: 'tabular-nums', fontWeight: 700, color: '#B83832' }}>{count}</td></tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

// ─── Rodapé ──────────────────────────────────────────────────────────────────
function Rodape({ paginaAtual, totalPaginas }: { paginaAtual?: number; totalPaginas?: number }) {
  return (
    <div className="rodape">
      <span>Escolta Armada · Plataforma de Gestão · Documento Confidencial</span>
      <span>Gerado em {new Date().toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</span>
    </div>
  )
}

// ─── Página Principal ────────────────────────────────────────────────────────
export default function RelatoriosPDFPage() {
  const searchParams = useSearchParams()
  const secoesParam = searchParams?.get('secoes') ?? 'resumo,escoltas'
  const from = searchParams?.get('from') ?? ''
  const to = searchParams?.get('to') ?? ''
  const clienteId = searchParams?.get('clienteId') ?? ''
  const periodo = searchParams?.get('periodo') ?? ''
  const secoes = secoesParam.split(',').filter(Boolean) as SecaoId[]

  const [loading, setLoading] = useState(true)
  const [erro, setErro] = useState<string | null>(null)
  const [escoltas, setEscoltas] = useState<EscoltaPDF[]>([])
  const [ocorrencias, setOcorrencias] = useState<OcorrenciaPDF[]>([])
  const [checklists, setChecklists] = useState<ChecklistPDF[]>([])
  const [clienteNome, setClienteNome] = useState('')
  const [clienteLogoUrl, setClienteLogoUrl] = useState('')

  const carregar = useCallback(async () => {
    try {
      setLoading(true)
      const needsEscoltas = secoes.some(s => ['resumo','escoltas','clientes','sla','efetivo','frota','financeiro'].includes(s))
      const needsOcorr = secoes.includes('ocorrencias')
      const needsChecklists = secoes.includes('checklists')

      let escoltasQ = sb.from('escoltas').select(`
        id, codigo_escolta, status, data_hora_prevista, data_finalizacao,
        origem_endereco, destino_endereco, valor_cobrado, outros_custos,
        cliente:clientes(id, nome_cliente, cor_destaque),
        veiculos:escolta_veiculos(
          quilometragem_saida, quilometragem_retorno,
          abastecimento_valor, abastecimento_litros
        ),
        efetivo:escolta_efetivo(
          valor_pago_vigilante, papel, confirmado,
          vigilante:vigilantes(nome_completo)
        )
      `)

      if (from) escoltasQ = escoltasQ.gte('data_hora_prevista', from)
      if (to)   escoltasQ = escoltasQ.lte('data_hora_prevista', to)
      if (clienteId) escoltasQ = escoltasQ.eq('cliente_id', clienteId)
      escoltasQ = escoltasQ.order('data_hora_prevista', { ascending: false })

      const promises: Promise<any>[] = []
      if (needsEscoltas) promises.push(escoltasQ)
      else promises.push(Promise.resolve({ data: [] }))

      if (needsOcorr) {
        let oQ = sb.from('ocorrencias').select(`id, descricao, data_hora, tipo:dom_tipos_ocorrencia(nome), autor:usuarios!registrado_por(nome_completo), escolta:escoltas(codigo_escolta)`)
        if (from) oQ = oQ.gte('data_hora', from)
        if (to)   oQ = oQ.lte('data_hora', to)
        oQ = oQ.order('data_hora', { ascending: false })
        promises.push(oQ)
      } else promises.push(Promise.resolve({ data: [] }))

      if (needsChecklists) {
        const { data: escData } = await escoltasQ
        const escIds = (escData ?? []).map((e: any) => e.id)
        const escVeicIds: string[] = []
        for (const e of (escData ?? [])) {
          for (const v of e.veiculos ?? []) {
            if (v.id) escVeicIds.push(v.id)
          }
        }
        let cQ = sb.from('checklists').select(`id, tipo, concluido, data_inicio, data_conclusao, checklist_respostas(conforme, descricao_item)`)
        if (escVeicIds.length > 0) cQ = cQ.in('escolta_veiculo_id', escVeicIds)
        else if (escIds.length > 0) cQ = cQ.in('escolta_id', escIds)
        promises.push(cQ)
      } else promises.push(Promise.resolve({ data: [] }))

      if (clienteId) {
        const { data: cliData } = await sb.from('clientes').select('nome_cliente, metadados').eq('id', clienteId).maybeSingle() as any
        setClienteNome(cliData?.nome_cliente ?? '')
        setClienteLogoUrl(cliData?.metadados?.logo_url ?? '')
      }

      const [escResult, ocorrResult, checkResult] = await Promise.all(promises)
      setEscoltas((escResult.data ?? []) as EscoltaPDF[])
      setOcorrencias((ocorrResult.data ?? []) as OcorrenciaPDF[])
      setChecklists((checkResult.data ?? []) as ChecklistPDF[])
    } catch (e: any) {
      setErro(e.message ?? 'Erro ao carregar dados')
    } finally {
      setLoading(false)
    }
  }, [from, to, clienteId, secoesParam])

  useEffect(() => { carregar() }, [carregar])

  useEffect(() => {
    if (!loading && !erro) {
      const t = setTimeout(() => window.print(), 800)
      return () => clearTimeout(t)
    }
  }, [loading, erro])

  const labelPeriodo = () => {
    if (periodo === 'hoje') return 'Hoje'
    if (periodo === 'semana') return 'Semana Atual'
    if (periodo === 'mes') return 'Mês Atual'
    if (periodo === 'trimestre') return 'Último Trimestre'
    if (from && to) {
      return `${fmtData(from)} a ${fmtData(to)}`
    }
    return 'Período Selecionado'
  }

  if (loading) return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '100vh', flexDirection: 'column', gap: '12px', fontFamily: 'system-ui, sans-serif' }}>
      <div style={{ width: '40px', height: '40px', border: '3px solid #EBF0F8', borderTop: '3px solid #1A294A', borderRadius: '50%', animation: 'spin 1s linear infinite' }} />
      <p style={{ color: '#53648A', fontSize: '13px' }}>Preparando relatório...</p>
      <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
    </div>
  )

  if (erro) return (
    <div style={{ padding: '40px', fontFamily: 'system-ui, sans-serif', color: '#B83832' }}>
      <p style={{ fontWeight: 700 }}>Erro ao carregar relatório:</p>
      <p>{erro}</p>
    </div>
  )

  const SECOES_ORDEM: SecaoId[] = ['capa', 'resumo', 'escoltas', 'clientes', 'ocorrencias', 'sla', 'checklists', 'efetivo', 'frota', 'financeiro']
  const secoesOrdenadas = SECOES_ORDEM.filter(s => secoes.includes(s))

  return (
    <>
      <style>{`
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; font-size: 12px; line-height: 1.5; color: #0E1A33; background: #fff; }
        .secao { padding: 40px 60px; border-bottom: 1px solid #EBF0F8; }
        .capa { border-bottom: none; }
        .secao-header { display: flex; align-items: center; gap: 14px; margin-bottom: 24px; padding-bottom: 14px; border-bottom: 2px solid #EBF0F8; }
        .secao-num { font-size: 10px; font-weight: 900; letter-spacing: 0.18em; color: #ABB5C9; }
        .secao-header h2 { font-size: 18px; font-weight: 900; color: #0E1A33; }
        .tabela { width: 100%; border-collapse: collapse; font-size: 11px; }
        .tabela th { text-align: left; font-size: 9px; font-weight: 900; letter-spacing: 0.12em; text-transform: uppercase; color: #8A9BB8; padding: 8px 10px; border-bottom: 2px solid #D6DAE5; white-space: nowrap; background: #F5F7FA; }
        .tabela td { padding: 8px 10px; border-bottom: 1px solid #EBF0F8; color: #0E1A33; vertical-align: top; }
        .tabela tfoot td { background: #F5F7FA; font-size: 11px; border-top: 2px solid #D6DAE5; border-bottom: none; }
        .tabela tr:hover td { background: #F9FAFB; }
        .status-badge { display: inline-block; padding: 2px 7px; border-radius: 2px; font-size: 9px; font-weight: 800; text-transform: uppercase; letter-spacing: 0.08em; }
        .status-finalizada { background: #E6F4ED; color: #1E7C52; }
        .status-cancelada { background: #FAEAE9; color: #B83832; }
        .status-em_andamento, .status-na_origem, .status-em_transito_destino, .status-no_destino, .status-retornando { background: #E6EAF2; color: #1A294A; }
        .status-agendada, .status-rascunho, .status-em_pre_inicio, .status-na_base { background: #FBF3DE; color: #8B6914; }
        .rodape { position: fixed; bottom: 0; left: 0; right: 0; display: flex; justify-content: space-between; align-items: center; padding: 10px 60px; font-size: 9px; font-weight: 600; color: #ABB5C9; border-top: 1px solid #EBF0F8; background: #fff; letter-spacing: 0.06em; text-transform: uppercase; }
        @media print {
          @page { margin: 0; size: A4; }
          body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
          .secao { page-break-after: always; }
          .secao:last-of-type { page-break-after: avoid; }
          .tabela tr { page-break-inside: avoid; }
          thead { display: table-header-group; }
          tfoot { display: table-footer-group; }
          .rodape { position: fixed; }
          .no-print { display: none !important; }
        }
        @media screen {
          body { background: #EBF0F8; }
          .secao { background: #fff; max-width: 960px; margin: 0 auto 2px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
          .capa { margin-top: 0; }
        }
      `}</style>

      <div className="no-print" style={{ position: 'fixed', top: 0, left: 0, right: 0, zIndex: 999, backgroundColor: '#1A294A', padding: '10px 24px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ color: 'rgba(255,255,255,0.7)', fontSize: '12px' }}>Relatório · {secoesOrdenadas.length} seção(ões) · {escoltas.length} escolta(s)</span>
        <div style={{ display: 'flex', gap: '8px' }}>
          <button onClick={() => window.print()} style={{ padding: '6px 16px', fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', backgroundColor: '#1E7C52', color: '#fff', border: 'none', borderRadius: '2px', cursor: 'pointer' }}>
            Imprimir / Salvar PDF
          </button>
          <button onClick={() => window.close()} style={{ padding: '6px 16px', fontSize: '11px', fontWeight: 700, backgroundColor: 'rgba(255,255,255,0.1)', color: 'rgba(255,255,255,0.7)', border: '1px solid rgba(255,255,255,0.2)', borderRadius: '2px', cursor: 'pointer' }}>
            Fechar
          </button>
        </div>
      </div>

      <div style={{ paddingTop: '40px' }}>
        {secoesOrdenadas.map(s => {
          if (s === 'capa')        return <SecaoCapa key={s} clienteNome={clienteNome} clienteLogoUrl={clienteLogoUrl} periodo={labelPeriodo()} />
          if (s === 'resumo')      return <SecaoResumo key={s} escoltas={escoltas} />
          if (s === 'escoltas')    return <SecaoEscoltas key={s} escoltas={escoltas} />
          if (s === 'clientes')    return <SecaoClientes key={s} escoltas={escoltas} />
          if (s === 'ocorrencias') return <SecaoOcorrencias key={s} ocorrencias={ocorrencias} />
          if (s === 'sla')         return <SecaoSLA key={s} escoltas={escoltas} />
          if (s === 'efetivo')     return <SecaoEfetivo key={s} escoltas={escoltas} />
          if (s === 'frota')       return <SecaoFrota key={s} escoltas={escoltas} />
          if (s === 'financeiro')  return <SecaoFinanceiro key={s} escoltas={escoltas} />
          if (s === 'checklists')  return <SecaoChecklists key={s} checklists={checklists} />
          return null
        })}
      </div>

      <Rodape />
    </>
  )
}
