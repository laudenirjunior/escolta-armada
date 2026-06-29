'use client'

import { useState, useCallback, useEffect, useRef } from 'react'
import { useRouter } from 'next/navigation'
import {
  Shield, Clock, AlertTriangle, CheckCircle2,
  Truck, Users, MapPin,  ArrowUpRight, ArrowDownRight, Calendar,
  BarChart2, Filter, ChevronRight, Info, Zap, TrendingUp,
  X, Download, ChevronDown,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

// ─── Paleta ──────────────────────────────────────────────────────────────────
const P = {
  navy:    '#1A294A',
  steel:   '#53648A',
  light:   '#ABB5C9',
  navyBg:  '#E6EAF2',
  steelBg: '#EBF0F8',
  bg:      '#F5F7FA',
  border:  '#D6DAE5',
  text:    '#0E1A33',
  textSub: '#5A6A80',
  alertBg:     '#FEF3C7',
  alertBorder: '#D97706',
  alertText:   '#92400E',
  alertSub:    '#B45309',
  alertIcon:   '#D97706',
  errorBg:  '#FAEAE9',
  errorText:'#B83832',
}

// ─── Parâmetro SLA ────────────────────────────────────────────────────────────
const SLA_HORAS_LIMITE = 10   // alerta quando escolta ativa ultrapassa 10h do horário previsto

const STATUSES_ATIVOS    = ['em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']
const STATUSES_CONCLUIDOS = ['finalizada']

const STATUS_LABEL: Record<string, string> = {
  rascunho:     'Rascunho',    agendada:     'Agendada',
  em_pre_inicio:'Pré-Início',  em_andamento: 'Em Andamento',
  na_origem:    'Na Origem',   no_destino:   'No Destino',
  retornando:   'Retornando',  na_base:      'Na Base',
  finalizada:   'Finalizada',  cancelada:    'Cancelada',
}
const STATUS_BADGE: Record<string, string> = {
  finalizada: 'badge-success', retornando: 'badge-warning',
  em_andamento:'badge-info',   na_origem:  'badge-info',
  no_destino: 'badge-info',    na_base:    'badge-warning',
  cancelada:  'badge-danger',  agendada:   'badge-neutral',
  rascunho:   'badge-neutral',
}

// ─── Tipos ────────────────────────────────────────────────────────────────────
type TipoPeriodo = 'hoje' | 'semana' | 'mes' | 'personalizado'

interface EscoltaRow {
  id: string
  codigo_escolta: string
  status: string
  data_hora_prevista: string
  data_finalizacao: string | null
  origem_endereco: string | null
  destino_endereco: string | null
  valor_cobrado: number | null
  outros_custos: number | null
  cliente: { nome_cliente: string; cor_destaque: string | null } | null
  veiculos: { abastecimento_valor: number | null }[]
  efetivo_financeiro: { valor_pago_vigilante: number | null }[]
}

const PERFIS_FINANCEIRO_IND = ['administrador', 'gestor', 'supervisor']
interface ClienteOpt { id: string; nome_cliente: string }
interface AlertaSLA {
  id: string; codigo: string; cliente: string
  minutosEmCampo: number; minutosExcedidos: number
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
function diffMinutes(from: string) {
  return Math.floor((Date.now() - new Date(from).getTime()) / 60000)
}
function formatDuracao(min: number) {
  const h = Math.floor(min / 60); const m = min % 60
  return h === 0 ? `${m}min` : `${h}h${m.toString().padStart(2, '0')}m`
}
function computeRange(tipo: TipoPeriodo, di: string, df: string): { from: string; to: string } {
  const now = new Date()
  const end = new Date(); end.setHours(23, 59, 59, 999)
  if (tipo === 'hoje') {
    const s = new Date(); s.setHours(0, 0, 0, 0)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  if (tipo === 'semana') {
    const s = new Date()
    // segunda-feira
    const day = s.getDay(); const diff = day === 0 ? -6 : 1 - day
    s.setDate(s.getDate() + diff); s.setHours(0, 0, 0, 0)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  if (tipo === 'mes') {
    const s = new Date(now.getFullYear(), now.getMonth(), 1)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  // personalizado
  const from = di ? new Date(di + 'T00:00:00').toISOString() : new Date(now.getFullYear(), now.getMonth(), 1).toISOString()
  const to   = df ? new Date(df + 'T23:59:59').toISOString() : end.toISOString()
  return { from, to }
}

function exportarCSV(escoltas: EscoltaRow[], labelPeriodo: string) {
  const headers = ['Código', 'Cliente', 'Status', 'Origem', 'Destino', 'Data/Hora Prevista']
  const rows = escoltas.map(e => [
    e.codigo_escolta,
    e.cliente?.nome_cliente ?? '',
    STATUS_LABEL[e.status] ?? e.status,
    e.origem_endereco ?? '',
    e.destino_endereco ?? '',
    new Date(e.data_hora_prevista).toLocaleString('pt-BR'),
  ])
  const csv = [headers, ...rows]
    .map(r => r.map(c => `"${String(c).replace(/"/g, '""')}"`).join(','))
    .join('\n')
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' })
  const url  = URL.createObjectURL(blob)
  const a    = document.createElement('a')
  a.href     = url
  a.download = `indicadores_${labelPeriodo}_${new Date().toISOString().slice(0,10)}.csv`
  a.click()
  URL.revokeObjectURL(url)
}

// ─── Sub-componentes ──────────────────────────────────────────────────────────
function SectionTitle({ icon: Icon, label }: { icon: React.ElementType; label: string }) {
  return (
    <div className="flex items-center gap-2">
      <div style={{ width: '6px', height: '6px', borderRadius: '2px', backgroundColor: P.steel, flexShrink: 0 }} />
      <Icon size={15} style={{ color: P.navy }} />
      <p className="text-xs font-black uppercase tracking-widest" style={{ color: P.text }}>{label}</p>
    </div>
  )
}
function MiniBar({ pct, dim = false }: { pct: number; dim?: boolean }) {
  return (
    <div style={{ height: '6px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
      <div style={{ width: `${Math.min(pct, 100)}%`, height: '100%', borderRadius: '2px', backgroundColor: dim ? P.light : P.navy, transition: 'width 0.8s ease' }} />
    </div>
  )
}
function ClienteBar({ value, max, cor }: { value: number; max: number; cor: string }) {
  const pct = max > 0 ? (value / max) * 100 : 0
  return (
    <div className="flex items-center gap-2 flex-1">
      <div className="flex-1 h-2.5" style={{ backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
        <div style={{ width: `${pct}%`, backgroundColor: cor, height: '100%', borderRadius: '2px', transition: 'width 0.8s ease' }} />
      </div>
      <span className="text-xs font-bold w-5 text-right" style={{ color: P.text }}>{value}</span>
    </div>
  )
}

// ─── Page ─────────────────────────────────────────────────────────────────────
export default function IndicadoresPage() {
  const router = useRouter()
  const sb = createClient()
  const { user } = useAuth()
  const verFinanceiro = PERFIS_FINANCEIRO_IND.includes((user?.perfil?.codigo ?? '') as any)

  // Filtros
  const [tipoPeriodo, setTipoPeriodo] = useState<TipoPeriodo>('mes')
  const [dataInicio, setDataInicio]   = useState('')
  const [dataFim, setDataFim]         = useState('')
  const [clienteFiltroId, setClienteFiltroId] = useState('')
  const [clientes, setClientes]       = useState<ClienteOpt[]>([])

  // Dados
  const [loading, setLoading]         = useState(true)
  const [escoltas, setEscoltas]       = useState<EscoltaRow[]>([])
  const [totalOcorrencias, setTotalOcorrencias] = useState(0)
  const [alertasSLA, setAlertasSLA]   = useState<AlertaSLA[]>([])
  const [alertasFechados, setAlertasFechados] = useState<Set<string>>(new Set())

  const labelPeriodo = tipoPeriodo === 'hoje' ? 'hoje'
    : tipoPeriodo === 'semana' ? 'semana'
    : tipoPeriodo === 'mes'    ? 'mes'
    : `${dataInicio}_${dataFim}`

  // Carrega clientes para o filtro
  useEffect(() => {
    sb.from('clientes').select('id, nome_cliente').eq('status', 'ativo').order('nome_cliente')
      .then(({ data }) => setClientes((data ?? []) as ClienteOpt[]))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const carregar = useCallback(async () => {
    setLoading(true)
    const { from, to } = computeRange(tipoPeriodo, dataInicio, dataFim)

    let q = sb.from('escoltas').select(`
      id, codigo_escolta, status, data_hora_prevista, data_finalizacao,
      origem_endereco, destino_endereco, valor_cobrado, outros_custos,
      cliente:clientes(nome_cliente, cor_destaque),
      veiculos:escolta_veiculos(abastecimento_valor),
      efetivo_financeiro:escolta_efetivo(valor_pago_vigilante)
    `)
    .gte('data_hora_prevista', from)
    .lte('data_hora_prevista', to)
    .order('data_hora_prevista', { ascending: false })

    if (clienteFiltroId) {
      q = (q as any).eq('cliente_id', clienteFiltroId)
    }

    let ocQ = sb.from('ocorrencias').select('id', { count: 'exact', head: true })
      .gte('data_hora', from).lte('data_hora', to)

    const [{ data: escData }, { count: ocCount }] = await Promise.all([q, ocQ])

    const rows = (escData ?? []) as EscoltaRow[]
    setEscoltas(rows)
    setTotalOcorrencias(ocCount ?? 0)

    const alertas: AlertaSLA[] = rows
      .filter(e => STATUSES_ATIVOS.includes(e.status))
      .map(e => ({
        id: e.id, codigo: e.codigo_escolta,
        cliente: e.cliente?.nome_cliente ?? '—',
        minutosEmCampo: diffMinutes(e.data_hora_prevista),
        minutosExcedidos: diffMinutes(e.data_hora_prevista) - SLA_HORAS_LIMITE * 60,
      }))
      .filter(a => a.minutosExcedidos > 0)

    setAlertasSLA(alertas)
    setLoading(false)
  }, [tipoPeriodo, dataInicio, dataFim, clienteFiltroId])

  useEffect(() => { carregar() }, [carregar])

  // KPIs calculados
  const totalMes      = escoltas.length
  const ativas        = escoltas.filter(e => STATUSES_ATIVOS.includes(e.status))
  const concluidas    = escoltas.filter(e => STATUSES_CONCLUIDOS.includes(e.status))
  const canceladas    = escoltas.filter(e => e.status === 'cancelada')
  const taxaConclusao = totalMes > 0 ? Math.round((concluidas.length / totalMes) * 100) : 0
  const txSla         = ativas.length > 0 ? Math.round(((ativas.length - alertasSLA.length) / ativas.length) * 100) : 100
  const txCanc        = totalMes > 0 ? Math.round((canceladas.length / totalMes) * 100) : 0

  const alertasVisiveis = alertasSLA.filter(a => !alertasFechados.has(a.id))

  const porCliente = Object.values(
    escoltas.reduce((acc, e) => {
      const nome = e.cliente?.nome_cliente ?? 'Sem cliente'
      const cor  = e.cliente?.cor_destaque ?? P.steel
      if (!acc[nome]) acc[nome] = { nome, total: 0, concluidas: 0, cor }
      acc[nome].total++
      if (STATUSES_CONCLUIDOS.includes(e.status)) acc[nome].concluidas++
      return acc
    }, {} as Record<string, { nome: string; total: number; concluidas: number; cor: string }>)
  ).sort((a, b) => b.total - a.total).slice(0, 6)
  const maxCliente = Math.max(...porCliente.map(c => c.total), 1)

  const gradientCors = [P.navy, '#2C3F6A', P.steel, '#7B8FAD', P.light, '#C8CED9']

  // KPIs Financeiros (supervisor+)
  const fmtBRL = (v: number) => v.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
  const escoltasConcluidas = escoltas.filter(e => STATUSES_CONCLUIDOS.includes(e.status))
  const receitaTotal  = escoltasConcluidas.reduce((s, e) => s + (e.valor_cobrado ?? 0), 0)
  const custoPessoal  = escoltasConcluidas.reduce((s, e) => s + e.efetivo_financeiro.reduce((ss, ef) => ss + (ef.valor_pago_vigilante ?? 0), 0), 0)
  const custoCombustivel = escoltasConcluidas.reduce((s, e) => s + e.veiculos.reduce((ss, v) => ss + (v.abastecimento_valor ?? 0), 0), 0)
  const outrosCustsTotal = escoltasConcluidas.reduce((s, e) => s + (e.outros_custos ?? 0), 0)
  const custoTotal    = custoPessoal + custoCombustivel + outrosCustsTotal
  const margemBruta   = receitaTotal - custoTotal
  const txMargem      = receitaTotal > 0 ? (margemBruta / receitaTotal) * 100 : null

  const now = new Date()
  const mesLabel = now.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' })
  const nomeCliente = clientes.find(c => c.id === clienteFiltroId)?.nome_cliente

  const KPI_CARDS = [
    { label: 'Escoltas no Período', valor: loading ? '—' : totalMes,      sub: nomeCliente ?? `filtro: ${tipoPeriodo}`,           tendencia: 'neutro',                                   icon: Shield,       cor: P.navy,      corBg: P.navyBg,  dark: false },
    { label: 'Em Andamento',        valor: loading ? '—' : ativas.length, sub: `${alertasVisiveis.length} alerta(s) SLA`,         tendencia: alertasVisiveis.length > 0 ? 'alerta' : 'neutro', icon: Truck, cor: P.navy,      corBg: P.navyBg,  dark: true  },
    { label: 'Concluídas',          valor: loading ? '—' : concluidas.length, sub: `${taxaConclusao}% de conclusão`,              tendencia: taxaConclusao >= 80 ? 'up' : 'down',        icon: CheckCircle2, cor: P.steel,     corBg: P.steelBg, dark: false },
    { label: 'Ocorrências',         valor: loading ? '—' : totalOcorrencias, sub: 'registradas no período',                       tendencia: totalOcorrencias > 5 ? 'down' : 'up',       icon: AlertTriangle,cor: P.errorText, corBg: P.errorBg, dark: false },
    { label: 'Canceladas',          valor: loading ? '—' : canceladas.length, sub: `${txCanc}% do total`,                         tendencia: canceladas.length > 3 ? 'down' : 'neutro',  icon: Zap,          cor: P.steel,     corBg: P.steelBg, dark: false },
    { label: 'Taxa SLA',            valor: loading ? '—' : `${txSla}%`,  sub: `${SLA_HORAS_LIMITE}h = limite operacional`,       tendencia: alertasVisiveis.length === 0 ? 'up' : 'down',icon: TrendingUp,   cor: P.navy,      corBg: P.navyBg,  dark: false },
  ]

  return (
    <div className="space-y-6">

      {/* ── Header ── */}
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <div className="eyebrow-tag mb-2">
            <BarChart2 size={10} />
            Centro de Análise Operacional
          </div>
          <h1 className="page-title">Indicadores</h1>
          <p className="page-subtitle flex items-center gap-1.5">
            <Calendar size={13} />
            {mesLabel.charAt(0).toUpperCase() + mesLabel.slice(1)}
            {nomeCliente && <span> · <strong style={{ color: P.navy }}>{nomeCliente}</strong></span>}
            {loading && <span className="ml-2 text-[10px] uppercase tracking-widest" style={{ color: P.light }}>atualizando...</span>}
          </p>
        </div>

        {/* Botão exportar */}
        <button
          onClick={() => exportarCSV(escoltas, labelPeriodo)}
          disabled={escoltas.length === 0}
          className="flex items-center gap-2 px-4 py-2 transition-all text-xs font-bold uppercase tracking-wider disabled:opacity-40"
          style={{ border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.steel, backgroundColor: '#fff' }}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.steel }}
        >
          <Download size={13} /> Exportar CSV
        </button>
      </div>

      {/* ── Barra de Filtros ── */}
      <div className="rounded p-4 space-y-3" style={{ backgroundColor: '#fff', border: `1px solid ${P.border}` }}>
        <div className="flex items-center gap-2 flex-wrap">
          <Filter size={13} style={{ color: P.steel, flexShrink: 0 }} />
          <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.textSub }}>Período</span>

          {/* Seletores de período */}
          {([
            { key: 'hoje',          label: 'Hoje'              },
            { key: 'semana',        label: 'Esta Semana'       },
            { key: 'mes',           label: 'Este Mês'          },
            { key: 'personalizado', label: 'Personalizado'     },
          ] as const).map(op => (
            <button key={op.key} onClick={() => setTipoPeriodo(op.key)}
              className="px-3 py-1.5 text-xs font-bold uppercase tracking-wider transition-all"
              style={{
                borderRadius: '2px',
                backgroundColor: tipoPeriodo === op.key ? P.navy : 'transparent',
                color: tipoPeriodo === op.key ? '#fff' : P.textSub,
                border: `1.5px solid ${tipoPeriodo === op.key ? P.navy : P.border}`,
              }}>
              {op.label}
            </button>
          ))}
        </div>

        {/* Datas personalizadas */}
        {tipoPeriodo === 'personalizado' && (
          <div className="flex items-center gap-3 flex-wrap pt-1">
            <div className="flex items-center gap-2">
              <label className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.textSub }}>De</label>
              <input type="date" value={dataInicio} onChange={e => setDataInicio(e.target.value)}
                className="px-2 py-1.5 text-xs"
                style={{ border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
            </div>
            <div className="flex items-center gap-2">
              <label className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.textSub }}>Até</label>
              <input type="date" value={dataFim} onChange={e => setDataFim(e.target.value)}
                className="px-2 py-1.5 text-xs"
                style={{ border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
            </div>
          </div>
        )}

        {/* Filtro por cliente */}
        <div className="flex items-center gap-3 flex-wrap pt-1 border-t" style={{ borderColor: P.steelBg }}>
          <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.textSub }}>Cliente</span>
          <div className="relative">
            <select
              value={clienteFiltroId}
              onChange={e => setClienteFiltroId(e.target.value)}
              className="appearance-none pr-8 pl-3 py-1.5 text-xs font-semibold"
              style={{ border: `1.5px solid ${clienteFiltroId ? P.navy : P.border}`, borderRadius: '2px', color: clienteFiltroId ? P.navy : P.textSub, backgroundColor: clienteFiltroId ? P.navyBg : '#fff', outline: 'none', minWidth: '220px' }}
            >
              <option value="">Todos os clientes</option>
              {clientes.map(c => (
                <option key={c.id} value={c.id}>{c.nome_cliente}</option>
              ))}
            </select>
            <ChevronDown size={11} style={{ position: 'absolute', right: '10px', top: '50%', transform: 'translateY(-50%)', color: P.textSub, pointerEvents: 'none' }} />
          </div>
          {clienteFiltroId && (
            <button onClick={() => setClienteFiltroId('')}
              className="flex items-center gap-1 text-[10px] font-bold"
              style={{ color: P.errorText }}>
              <X size={11} /> Limpar filtro
            </button>
          )}
        </div>
      </div>

      {/* ── Alertas SLA ── */}
      {alertasVisiveis.length > 0 && (
        <div className="space-y-2">
          <div className="flex items-center gap-2 px-1">
            <Info size={11} style={{ color: P.light }} />
            <p style={{ fontSize: '10px', color: P.light }}>
              Parâmetro SLA: alerta gerado quando escolta ativa ultrapassa{' '}
              <strong style={{ color: P.alertIcon }}>{SLA_HORAS_LIMITE}h</strong> a partir do horário de início previsto
            </p>
          </div>
          {alertasVisiveis.map(alerta => (
            <div key={alerta.id} className="flex items-center gap-4 glow-amber"
              style={{ backgroundColor: P.alertBg, border: `1.5px solid ${P.alertBorder}`, borderRadius: '2px', padding: '14px 18px' }}>
              <div style={{ backgroundColor: P.alertIcon, borderRadius: '2px', padding: '8px', flexShrink: 0 }}>
                <Clock size={16} className="animate-pulse" style={{ color: '#fff' }} />
              </div>
              {/* Conteúdo clicável */}
              <button className="flex-1 min-w-0 text-left transition-all active:scale-[0.99]"
                onClick={() => router.push(`/dashboard/escoltas/${alerta.id}`)}>
                <p className="text-xs font-black uppercase tracking-widest" style={{ color: P.alertText }}>
                  Alerta de SLA — {alerta.codigo} está em campo há {formatDuracao(alerta.minutosEmCampo)}
                </p>
                <p className="text-[11px] mt-0.5" style={{ color: P.alertSub }}>
                  Prazo excedido em <strong>{formatDuracao(alerta.minutosExcedidos)}</strong> · Parâmetro: {SLA_HORAS_LIMITE}h · Cliente: {alerta.cliente}
                </p>
              </button>
              {/* Ver escolta */}
              <button onClick={() => router.push(`/dashboard/escoltas/${alerta.id}`)}
                className="flex items-center gap-2 shrink-0 transition-opacity hover:opacity-80"
                style={{ backgroundColor: P.alertIcon, color: '#fff', borderRadius: '2px', padding: '6px 12px' }}>
                <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.08em' }}>Ver Escolta</span>
                <ChevronRight size={13} />
              </button>
              {/* Fechar alerta */}
              <button
                onClick={() => setAlertasFechados(prev => new Set([...prev, alerta.id]))}
                title="Fechar alerta"
                className="flex items-center justify-center shrink-0 transition-all hover:opacity-70"
                style={{ width: '44px', height: '44px', borderRadius: '2px', border: `1.5px solid ${P.alertBorder}`, color: P.alertText, backgroundColor: 'transparent' }}>
                <X size={13} />
              </button>
            </div>
          ))}
        </div>
      )}

      {/* ── KPI Cards ── */}
      <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
        {KPI_CARDS.map((k, i) => {
          const Icon = k.icon
          return (
            <div key={k.label}
              className="animate-in fade-in zoom-in-95"
              style={{
                animationDuration: '500ms', animationDelay: `${i * 60}ms`, animationFillMode: 'both',
                borderRadius: '2px', padding: '16px', display: 'flex', flexDirection: 'column',
                gap: '12px', minHeight: '140px', justifyContent: 'space-between',
                cursor: 'default',
                transition: 'transform 400ms cubic-bezier(0.32,0.72,0,1), box-shadow 400ms cubic-bezier(0.32,0.72,0,1)',
                ...(k.dark
                  ? { backgroundColor: P.navy, outline: '1px solid rgba(255,255,255,0.08)', boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }
                  : { backgroundColor: '#fff', border: `1px solid ${P.border}`, boxShadow: '0 1px 3px rgba(0,0,0,0.05)' }),
              }}
              onMouseEnter={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(-3px)'
                el.style.boxShadow = k.dark ? '0 12px 32px rgba(0,0,0,0.35)' : '0 12px 32px rgba(26,41,74,0.12)'
              }}
              onMouseLeave={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(0)'
                el.style.boxShadow = k.dark ? '0 2px 8px rgba(0,0,0,0.15)' : '0 1px 3px rgba(0,0,0,0.05)'
              }}
            >
              <div className="flex items-start justify-between">
                <div className="w-9 h-9 flex items-center justify-center"
                  style={{ backgroundColor: k.dark ? 'rgba(255,255,255,0.08)' : k.corBg, borderRadius: '2px' }}>
                  <Icon size={17} style={{ color: k.dark ? '#ABB5C9' : k.cor }} />
                </div>
                <div className="flex items-center gap-1.5">
                  {k.dark && (
                    <span style={{ backgroundColor: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.12)', borderRadius: '2px', fontSize: '9px', fontWeight: 900, letterSpacing: '0.1em', textTransform: 'uppercase', color: 'rgba(255,255,255,0.5)', padding: '2px 6px' }}>LIVE</span>
                  )}
                  {k.tendencia === 'up'    && <ArrowUpRight    size={13} style={{ color: k.dark ? 'rgba(255,255,255,0.5)' : P.steel }} />}
                  {k.tendencia === 'down'  && <ArrowDownRight  size={13} style={{ color: k.dark ? 'rgba(255,255,255,0.5)' : P.errorText }} />}
                  {k.tendencia === 'alerta' && alertasVisiveis.length > 0 && (
                    <span style={{ fontSize: '9px', fontWeight: 900, color: P.alertIcon, backgroundColor: P.alertBg, padding: '2px 5px', borderRadius: '2px', border: `1px solid ${P.alertIcon}` }}>⚠ SLA</span>
                  )}
                </div>
              </div>
              <div>
                <p className="text-2xl font-black" style={{ color: k.dark ? '#fff' : P.text }}>{k.valor}</p>
                <p className="text-[11px] font-semibold uppercase tracking-wide mt-0.5" style={{ color: k.dark ? 'rgba(255,255,255,0.45)' : P.textSub }}>{k.label}</p>
                <p className="text-[11px] mt-0.5" style={{ color: k.dark ? 'rgba(255,255,255,0.3)' : P.light }}>{k.sub}</p>
              </div>
            </div>
          )
        })}
      </div>

      {/* ── KPIs Financeiros (supervisor+) ── */}
      {verFinanceiro && (
        <div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '10px' }}>
            <div style={{ width: '3px', height: '3px', backgroundColor: '#1E7C52', borderRadius: '50%' }} />
            <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.22em', color: P.textSub }}>Painel Financeiro · Escoltas Concluídas</p>
          </div>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: 'Receita Total', value: loading ? '—' : fmtBRL(receitaTotal), color: receitaTotal > 0 ? '#1E7C52' : P.light, sub: `${escoltasConcluidas.length} escolta(s) concluída(s)` },
              { label: 'Custo Total', value: loading ? '—' : fmtBRL(custoTotal), color: custoTotal > 0 ? '#B83832' : P.light, sub: `Pessoal + combustível + outros` },
              { label: 'Margem Bruta', value: loading ? '—' : fmtBRL(margemBruta), color: margemBruta >= 0 ? '#1E7C52' : '#B83832', sub: txMargem != null ? `${txMargem.toFixed(1)}% da receita` : 'Sem receita' },
              { label: 'Custo de Pessoal', value: loading ? '—' : fmtBRL(custoPessoal), color: '#B83832', sub: `+ ${fmtBRL(custoCombustivel)} combustível` },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.color}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
                <p style={{ fontSize: '18px', fontWeight: 900, color: k.color, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{k.value}</p>
                <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
              </div>
            ))}
          </div>
          {/* Barra de composição de custos */}
          {receitaTotal > 0 && !loading && (
            <div style={{ marginTop: '10px', backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '12px 16px' }}>
              <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '8px' }}>Composição dos Custos sobre Receita</p>
              <div style={{ display: 'flex', height: '10px', borderRadius: '2px', overflow: 'hidden', backgroundColor: P.steelBg }}>
                <div title={`Pessoal: ${fmtBRL(custoPessoal)}`} style={{ width: `${Math.min((custoPessoal/receitaTotal)*100,100)}%`, backgroundColor: '#B83832' }} />
                <div title={`Combustível: ${fmtBRL(custoCombustivel)}`} style={{ width: `${Math.min((custoCombustivel/receitaTotal)*100,100)}%`, backgroundColor: '#D97706' }} />
                <div title={`Outros: ${fmtBRL(outrosCustsTotal)}`} style={{ width: `${Math.min((outrosCustsTotal/receitaTotal)*100,100)}%`, backgroundColor: P.light }} />
                {margemBruta > 0 && <div title={`Margem: ${fmtBRL(margemBruta)}`} style={{ flex: 1, backgroundColor: '#1E7C52' }} />}
              </div>
              <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', marginTop: '8px' }}>
                {[{ l: 'Pessoal', v: custoPessoal, c: '#B83832' }, { l: 'Combustível', v: custoCombustivel, c: '#D97706' }, { l: 'Outros', v: outrosCustsTotal, c: P.light }, { l: 'Margem', v: margemBruta, c: '#1E7C52' }].map(i => (
                  <span key={i.l} style={{ display: 'flex', alignItems: 'center', gap: '4px', fontSize: '10px', color: P.textSub }}>
                    <span style={{ display: 'inline-block', width: '8px', height: '8px', borderRadius: '2px', backgroundColor: i.c, flexShrink: 0 }} />
                    {i.l}: <strong style={{ color: P.text }}>{fmtBRL(i.v)}</strong>
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>
      )}

      {/* ── Linha 2: Clientes + Resumo ── */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">

        {/* Escoltas por Cliente */}
        <div className="card-light p-5 animate-in fade-in slide-in-from-left-4" style={{ animationDuration: '600ms', animationFillMode: 'both' }}>
          <div className="flex items-center justify-between mb-5">
            <SectionTitle icon={Users} label="Escoltas por Cliente" />
            <span className="badge-neutral">{porCliente.length} clientes</span>
          </div>
          {loading ? (
            <div className="space-y-3">{[1,2,3,4].map(i => (
              <div key={i} className="animate-pulse h-8" style={{ backgroundColor: P.steelBg, borderRadius: '2px' }} />
            ))}</div>
          ) : porCliente.length === 0 ? (
            <p className="text-xs text-center py-8" style={{ color: P.light }}>Nenhuma escolta no período</p>
          ) : (
            <div className="space-y-3">
              {porCliente.map((c, idx) => {
                const cor = c.cor !== P.steel ? c.cor : gradientCors[idx] ?? P.light
                return (
                  <div key={c.nome} className="space-y-1">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div style={{ width: '8px', height: '8px', backgroundColor: cor, borderRadius: '2px', flexShrink: 0 }} />
                        <span className="text-xs font-semibold truncate" style={{ color: P.text, maxWidth: '180px' }}>{c.nome}</span>
                      </div>
                      <span className="text-[10px]" style={{ color: P.textSub }}>{c.concluidas}/{c.total}</span>
                    </div>
                    <ClienteBar value={c.total} max={maxCliente} cor={cor} />
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Resumo Operacional */}
        <div className="card-light p-5 animate-in fade-in slide-in-from-right-4" style={{ animationDuration: '600ms', animationFillMode: 'both' }}>
          <div className="mb-5">
            <SectionTitle icon={BarChart2} label="Resumo Operacional" />
          </div>
          <div className="space-y-4">
            <div>
              <div className="flex justify-between mb-1.5">
                <span className="text-xs font-semibold" style={{ color: P.text }}>Taxa de Conclusão</span>
                <span className="text-xs font-black" style={{ color: taxaConclusao >= 80 ? P.navy : P.errorText }}>{taxaConclusao}%</span>
              </div>
              <MiniBar pct={taxaConclusao} />
            </div>
            <div>
              <div className="flex justify-between mb-1.5">
                <span className="text-xs font-semibold" style={{ color: P.text }}>Conformidade SLA (ativas)</span>
                <span className="text-xs font-black" style={{ color: txSla >= 80 ? P.navy : P.errorText }}>{txSla}%</span>
              </div>
              <MiniBar pct={txSla} dim={txSla < 80} />
            </div>
            <div>
              <div className="flex justify-between mb-1.5">
                <span className="text-xs font-semibold" style={{ color: P.text }}>Taxa de Cancelamento</span>
                <span className="text-xs font-black" style={{ color: txCanc <= 10 ? P.steel : P.errorText }}>{txCanc}%</span>
              </div>
              <MiniBar pct={txCanc} dim />
            </div>
          </div>

          <div className="grid grid-cols-3 gap-2 mt-5">
            {[
              { label: 'Ativas',     valor: ativas.length,     cor: P.navy,      bg: P.navyBg  },
              { label: 'Concluídas', valor: concluidas.length, cor: P.steel,     bg: P.steelBg },
              { label: 'Canceladas', valor: canceladas.length, cor: P.errorText, bg: P.errorBg },
            ].map(m => (
              <div key={m.label} className="p-3 text-center" style={{ backgroundColor: m.bg, borderRadius: '2px' }}>
                <p className="text-xl font-black" style={{ color: m.cor }}>{loading ? '—' : m.valor}</p>
                <p className="text-[9px] uppercase font-bold tracking-wider" style={{ color: m.cor }}>{m.label}</p>
              </div>
            ))}
          </div>

          <div className="mt-4 p-3 flex items-start gap-2" style={{ backgroundColor: P.navyBg, borderRadius: '2px', border: `1px solid ${P.border}` }}>
            <Info size={12} style={{ color: P.steel, flexShrink: 0, marginTop: '1px' }} />
            <p style={{ fontSize: '10px', color: P.textSub, lineHeight: 1.5 }}>
              <strong style={{ color: P.navy }}>Parâmetro SLA:</strong> alerta disparado automaticamente quando
              escolta ativa ultrapassa <strong style={{ color: P.navy }}>{SLA_HORAS_LIMITE}h</strong> do horário de início previsto.
            </p>
          </div>
        </div>
      </div>

      {/* ── Tabela Operações ── */}
      <div className="card-light animate-in fade-in slide-in-from-bottom-4" style={{ animationDuration: '600ms', animationDelay: '150ms', animationFillMode: 'both' }}>
        <div className="px-5 py-4 flex items-center justify-between" style={{ borderBottom: `1px solid ${P.border}` }}>
          <SectionTitle icon={MapPin} label="Operações Recentes" />
          <div className="flex items-center gap-3">
            <span className="badge-neutral">{escoltas.length} registros</span>
            <button onClick={() => router.push('/dashboard/escoltas')}
              className="text-[10px] font-bold flex items-center gap-1 transition-colors"
              style={{ color: P.steel }}
              onMouseEnter={e => (e.currentTarget as HTMLElement).style.color = P.navy}
              onMouseLeave={e => (e.currentTarget as HTMLElement).style.color = P.steel}>
              Ver todas <ChevronRight size={11} />
            </button>
          </div>
        </div>

        {loading ? (
          <div className="p-5 space-y-2">{[1,2,3,4].map(i => (
            <div key={i} className="animate-pulse h-10" style={{ backgroundColor: P.steelBg, borderRadius: '2px' }} />
          ))}</div>
        ) : escoltas.length === 0 ? (
          <div className="p-8 text-center">
            <p className="text-sm" style={{ color: P.light }}>Nenhuma operação no período selecionado</p>
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="table-content">
              <thead>
                <tr>
                  <th>Código</th><th>Cliente</th><th>Origem</th><th>Previsto</th><th>Status</th>
                  <th style={{ width: '40px' }} />
                </tr>
              </thead>
              <tbody>
                {escoltas.slice(0, 20).map(e => {
                  const isSla = alertasSLA.some(a => a.id === e.id)
                  return (
                    <tr key={e.id}
                      onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                      style={{ cursor: 'pointer', backgroundColor: isSla ? P.alertBg : '' }}
                      onMouseEnter={ev => (ev.currentTarget as HTMLElement).style.backgroundColor = isSla ? '#FDE68A' : P.bg}
                      onMouseLeave={ev => (ev.currentTarget as HTMLElement).style.backgroundColor = isSla ? P.alertBg : ''}>
                      <td>
                        <div className="flex items-center gap-1.5">
                          {isSla && <span style={{ fontSize: '9px', color: P.alertIcon }}>⚠</span>}
                          <span className="font-mono text-xs font-bold" style={{ color: P.text }}>{e.codigo_escolta}</span>
                        </div>
                      </td>
                      <td>
                        <div className="flex items-center gap-2">
                          {e.cliente?.cor_destaque && <div style={{ width: '6px', height: '6px', backgroundColor: e.cliente.cor_destaque, borderRadius: '2px', flexShrink: 0 }} />}
                          <span className="text-xs truncate" style={{ color: P.text, maxWidth: '140px' }}>{e.cliente?.nome_cliente ?? '—'}</span>
                        </div>
                      </td>
                      <td>
                        <span className="text-xs truncate block" style={{ color: P.textSub, maxWidth: '160px' }}>
                          {e.origem_endereco ? e.origem_endereco.split(',').slice(0, 2).join(',') : '—'}
                        </span>
                      </td>
                      <td>
                        <span className="text-xs" style={{ color: P.textSub }}>
                          {new Date(e.data_hora_prevista).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' })}{' '}
                          {new Date(e.data_hora_prevista).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                        </span>
                      </td>
                      <td><span className={STATUS_BADGE[e.status] ?? 'badge-neutral'}>{STATUS_LABEL[e.status] ?? e.status}</span></td>
                      <td><ChevronRight size={13} style={{ color: P.border }} /></td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

    </div>
  )
}
