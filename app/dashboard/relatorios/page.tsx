'use client'

import { useState, useCallback, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import {
  FileText, Download, Filter, Calendar, BarChart2, Shield, Truck, Users,
  MapPin, AlertTriangle, CheckCircle2, XCircle, Clock, ChevronRight, Search,
  RefreshCw, TrendingUp, TrendingDown, Minus, FileDown, Table2, PieChart,
  Activity, Info, ChevronDown,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'

// ─── Paleta ───────────────────────────────────────────────────────────────────
const P = {
  navy:        '#1A294A',
  steel:       '#53648A',
  light:       '#ABB5C9',
  navyBg:      '#E6EAF2',
  steelBg:     '#EBF0F8',
  bg:          '#F5F7FA',
  border:      '#D6DAE5',
  text:        '#0E1A33',
  textSub:     '#5A6A80',
  alertBg:     '#FEF3C7',
  alertBorder: '#D97706',
  alertText:   '#92400E',
  errorBg:     '#FAEAE9',
  errorText:   '#B83832',
  successBg:   '#E6F4ED',
  successText: '#1E7C52',
}

// ─── Constantes de Status ──────────────────────────────────────────────────────
const STATUS_LABEL: Record<string, string> = {
  rascunho:     'Rascunho',
  agendada:     'Agendada',
  em_pre_inicio:'Pré-Início',
  em_andamento: 'Em Andamento',
  na_origem:    'Na Origem',
  no_destino:   'No Destino',
  retornando:   'Retornando',
  na_base:      'Na Base',
  finalizada:   'Finalizada',
  cancelada:    'Cancelada',
}
const STATUS_BADGE: Record<string, string> = {
  finalizada:   'badge-success',
  cancelada:    'badge-danger',
  em_andamento: 'badge-info',
  na_origem:    'badge-info',
  no_destino:   'badge-info',
  na_base:      'badge-warning',
  retornando:   'badge-warning',
  agendada:     'badge-neutral',
  rascunho:     'badge-neutral',
  em_pre_inicio:'badge-warning',
}
const STATUSES_ATIVOS     = ['em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']
const STATUSES_CONCLUIDOS = ['finalizada']
const STATUSES_CANCELADOS = ['cancelada']

// ─── Tipos ────────────────────────────────────────────────────────────────────
type TipoPeriodo = 'hoje' | 'semana' | 'mes' | 'trimestre' | 'personalizado'
type TabId       = 'resumo' | 'escoltas' | 'clientes' | 'ocorrencias'
type SortDir     = 'asc' | 'desc' | null

interface EscoltaRelatorio {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  data_finalizacao: string | null
  criado_em: string
  origem_endereco: string | null
  destino_endereco: string | null
  cliente: { id: string; nome_cliente: string; cor_destaque: string | null } | null
  veiculos: { quilometragem_saida: number; quilometragem_retorno: number | null }[]
}
interface OcorrenciaRelatorio {
  id: string
  descricao: string
  data_hora: string
  tipo: { nome: string } | null
  autor: { nome_completo: string } | null
  escolta: { codigo_escolta: string | null } | null
}
interface ClienteMetrica {
  id: string
  nome: string
  cor: string
  total: number
  concluidas: number
  canceladas: number
  ativas: number
  kmTotal: number
  duracaoMediaMin: number
}
interface ClienteOpt { id: string; nome_cliente: string }

// ─── Helpers ──────────────────────────────────────────────────────────────────
function diffMinutes(from: string): number {
  return Math.floor((Date.now() - new Date(from).getTime()) / 60000)
}

function formatDuracao(min: number): string {
  if (min < 0) return '—'
  const h = Math.floor(min / 60)
  const m = min % 60
  return h === 0 ? `${m}min` : `${h}h${m.toString().padStart(2, '0')}m`
}

function calcKmEscolta(veiculos: { quilometragem_saida: number; quilometragem_retorno: number | null }[]): number {
  return veiculos.reduce((sum, v) => {
    const ret = v.quilometragem_retorno ?? v.quilometragem_saida
    return sum + Math.max(0, ret - v.quilometragem_saida)
  }, 0)
}

function calcDuracaoMin(e: EscoltaRelatorio): number {
  const fim = e.data_finalizacao ? new Date(e.data_finalizacao) : new Date()
  return Math.floor((fim.getTime() - new Date(e.data_hora_prevista).getTime()) / 60000)
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
    const day = s.getDay(); const diff = day === 0 ? -6 : 1 - day
    s.setDate(s.getDate() + diff); s.setHours(0, 0, 0, 0)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  if (tipo === 'mes') {
    const s = new Date(now.getFullYear(), now.getMonth(), 1)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  if (tipo === 'trimestre') {
    const s = new Date(now); s.setMonth(s.getMonth() - 3); s.setHours(0, 0, 0, 0)
    return { from: s.toISOString(), to: end.toISOString() }
  }
  const from = di ? new Date(di + 'T00:00:00').toISOString() : new Date(now.getFullYear(), now.getMonth(), 1).toISOString()
  const to   = df ? new Date(df + 'T23:59:59').toISOString() : end.toISOString()
  return { from, to }
}

function labelPeriodoStr(tipo: TipoPeriodo, di: string, df: string): string {
  if (tipo === 'hoje')      return 'hoje'
  if (tipo === 'semana')    return 'semana'
  if (tipo === 'mes')       return 'mes'
  if (tipo === 'trimestre') return 'trimestre'
  return `${di}_${df}`
}

// ─── Export helpers ────────────────────────────────────────────────────────────
function downloadCSV(csvContent: string, filename: string) {
  const blob = new Blob(['﻿' + csvContent], { type: 'text/csv;charset=utf-8;' })
  const url  = URL.createObjectURL(blob)
  const a    = document.createElement('a')
  a.href = url; a.download = filename; a.click()
  URL.revokeObjectURL(url)
}

function toCSVRow(fields: (string | number | null | undefined)[]): string {
  return fields.map(f => `"${String(f ?? '').replace(/"/g, '""')}"`).join(',')
}

function exportarCSVEscoltas(data: EscoltaRelatorio[], periodo: string): void {
  const headers = toCSVRow(['Código','Cliente','Status','Origem','Destino','Data/Hora Prevista','Data Finalização','Duração (min)','KM Rodado'])
  const rows = data.map(e => toCSVRow([
    e.codigo_escolta,
    e.cliente?.nome_cliente,
    STATUS_LABEL[e.status] ?? e.status,
    e.origem_endereco,
    e.destino_endereco,
    new Date(e.data_hora_prevista).toLocaleString('pt-BR'),
    e.data_finalizacao ? new Date(e.data_finalizacao).toLocaleString('pt-BR') : '',
    calcDuracaoMin(e),
    calcKmEscolta(e.veiculos),
  ]))
  downloadCSV([headers, ...rows].join('\n'), `escoltas_${periodo}_${new Date().toISOString().slice(0,10)}.csv`)
}

function exportarCSVClientes(data: ClienteMetrica[], periodo: string): void {
  const headers = toCSVRow(['Cliente','Total','Concluídas','Canceladas','Taxa Conclusão (%)','KM Total','Duração Média (min)'])
  const rows = data.map(c => {
    const tx = (c.concluidas + c.canceladas) > 0 ? Math.round((c.concluidas / (c.concluidas + c.canceladas)) * 100) : 0
    return toCSVRow([c.nome, c.total, c.concluidas, c.canceladas, tx, c.kmTotal, Math.round(c.duracaoMediaMin)])
  })
  downloadCSV([headers, ...rows].join('\n'), `clientes_${periodo}_${new Date().toISOString().slice(0,10)}.csv`)
}

function exportarCSVOcorrencias(data: OcorrenciaRelatorio[], periodo: string): void {
  const headers = toCSVRow(['Data/Hora','Código Escolta','Tipo','Descrição','Registrado por'])
  const rows = data.map(o => toCSVRow([
    new Date(o.data_hora).toLocaleString('pt-BR'),
    o.escolta?.codigo_escolta,
    o.tipo?.nome,
    o.descricao,
    o.autor?.nome_completo,
  ]))
  downloadCSV([headers, ...rows].join('\n'), `ocorrencias_${periodo}_${new Date().toISOString().slice(0,10)}.csv`)
}

function exportarCSVCompleto(
  escoltas: EscoltaRelatorio[],
  clientes: ClienteMetrica[],
  ocorrencias: OcorrenciaRelatorio[],
  periodo: string
): void {
  const secEscoltas  = ['# ESCOLTAS', toCSVRow(['Código','Cliente','Status','Origem','Destino','Data Prevista','Data Fin.','Duração (min)','KM']),
    ...escoltas.map(e => toCSVRow([e.codigo_escolta, e.cliente?.nome_cliente, STATUS_LABEL[e.status]??e.status, e.origem_endereco, e.destino_endereco, new Date(e.data_hora_prevista).toLocaleString('pt-BR'), e.data_finalizacao ? new Date(e.data_finalizacao).toLocaleString('pt-BR'):'', calcDuracaoMin(e), calcKmEscolta(e.veiculos)]))]
  const secClientes = ['', '# ANÁLISE POR CLIENTE', toCSVRow(['Cliente','Total','Concluídas','Canceladas','KM Total']),
    ...clientes.map(c => toCSVRow([c.nome, c.total, c.concluidas, c.canceladas, c.kmTotal]))]
  const secOcorr    = ['', '# OCORRÊNCIAS', toCSVRow(['Data/Hora','Código Escolta','Tipo','Descrição','Registrado por']),
    ...ocorrencias.map(o => toCSVRow([new Date(o.data_hora).toLocaleString('pt-BR'), o.escolta?.codigo_escolta, o.tipo?.nome, o.descricao, o.autor?.nome_completo]))]
  downloadCSV([...secEscoltas, ...secClientes, ...secOcorr].join('\n'), `relatorio_completo_${periodo}_${new Date().toISOString().slice(0,10)}.csv`)
}

// ─── Sub-componentes ──────────────────────────────────────────────────────────
function SectionTitle({ icon: Icon, label }: { icon: React.ElementType; label: string }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
      <div style={{ width: '6px', height: '6px', borderRadius: '2px', backgroundColor: P.steel, flexShrink: 0 }} />
      <Icon size={15} style={{ color: P.navy }} />
      <p style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.text, margin: 0 }}>{label}</p>
    </div>
  )
}

function MiniBar({ pct, color = P.navy }: { pct: number; color?: string }) {
  return (
    <div style={{ height: '6px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden', flex: 1 }}>
      <div style={{ width: `${Math.min(Math.max(pct, 0), 100)}%`, height: '100%', borderRadius: '2px', backgroundColor: color, transition: 'width 0.8s ease' }} />
    </div>
  )
}

function SkeletonRows({ n = 5, cols = 5 }: { n?: number; cols?: number }) {
  return (
    <div style={{ padding: '12px 16px' }}>
      {Array.from({ length: n }).map((_, i) => (
        <div key={i} style={{ display: 'grid', gridTemplateColumns: `repeat(${cols}, 1fr)`, gap: '8px', marginBottom: '8px' }}>
          {Array.from({ length: cols }).map((__, j) => (
            <div key={j} className="animate-pulse" style={{ height: '32px', backgroundColor: P.steelBg, borderRadius: '2px' }} />
          ))}
        </div>
      ))}
    </div>
  )
}

function EmptyState({ icon: Icon, msg }: { icon: React.ElementType; msg: string }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '48px 16px', gap: '12px' }}>
      <div style={{ width: '48px', height: '48px', borderRadius: '2px', backgroundColor: P.steelBg, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon size={22} style={{ color: P.light }} />
      </div>
      <p style={{ fontSize: '12px', color: P.light, textAlign: 'center' }}>{msg}</p>
    </div>
  )
}

function SortIcon({ col, sortCol, sortDir }: { col: string; sortCol: string; sortDir: SortDir }) {
  if (col !== sortCol) return <Minus size={10} style={{ color: P.light, opacity: 0.4 }} />
  if (sortDir === 'asc')  return <TrendingUp size={10} style={{ color: '#fff' }} />
  if (sortDir === 'desc') return <TrendingDown size={10} style={{ color: '#fff' }} />
  return <Minus size={10} style={{ color: P.light }} />
}

// ─── Page ─────────────────────────────────────────────────────────────────────
export default function RelatoriosPage() {
  const router = useRouter()
  const sb = createClient() as any

  // Tab
  const [tab, setTab] = useState<TabId>('resumo')

  // Filtros
  const [tipoPeriodo, setTipoPeriodo] = useState<TipoPeriodo>('mes')
  const [dataInicio, setDataInicio]   = useState('')
  const [dataFim, setDataFim]         = useState('')
  const [clienteFiltroId, setClienteFiltroId] = useState('')
  const [statusFiltro, setStatusFiltro]       = useState('')
  const [clientes, setClientes]       = useState<ClienteOpt[]>([])

  // Dados
  const [loading, setLoading]             = useState(true)
  const [escoltas, setEscoltas]           = useState<EscoltaRelatorio[]>([])
  const [ocorrencias, setOcorrencias]     = useState<OcorrenciaRelatorio[]>([])
  const [loadingOcorr, setLoadingOcorr]   = useState(false)
  const [tiposOcorrencia, setTiposOcorrencia] = useState<string[]>([])
  const [tipoOcorrFiltro, setTipoOcorrFiltro] = useState('')

  // Tabela Escoltas
  const [searchEsc, setSearchEsc]   = useState('')
  const [pageEsc, setPageEsc]       = useState(0)
  const [sortCol, setSortCol]       = useState('data_hora_prevista')
  const [sortDir, setSortDir]       = useState<SortDir>('desc')
  const PAGE_ESC = 20

  // Tabela Ocorrências
  const [pageOcorr, setPageOcorr]   = useState(0)
  const PAGE_OCORR = 15

  // Clientes
  const [clientesMetrica, setClientesMetrica] = useState<ClienteMetrica[]>([])

  const periodo = labelPeriodoStr(tipoPeriodo, dataInicio, dataFim)

  // Carrega clientes
  useEffect(() => {
    sb.from('clientes').select('id, nome_cliente').order('nome_cliente')
      .then(({ data }: { data: ClienteOpt[] | null }) => setClientes(data ?? []))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Carrega escoltas
  const carregarEscoltas = useCallback(async () => {
    setLoading(true)
    const { from, to } = computeRange(tipoPeriodo, dataInicio, dataFim)

    let q = sb.from('escoltas').select(`
      id, codigo_escolta, status, data_hora_prevista, data_finalizacao, criado_em,
      origem_endereco, destino_endereco,
      cliente:clientes(id, nome_cliente, cor_destaque),
      veiculos:escolta_veiculos(quilometragem_saida, quilometragem_retorno)
    `)
    .gte('data_hora_prevista', from)
    .lte('data_hora_prevista', to)
    .order('data_hora_prevista', { ascending: false })

    if (clienteFiltroId) q = q.eq('cliente_id', clienteFiltroId)
    if (statusFiltro)    q = q.eq('status', statusFiltro)

    const { data } = await q
    const rows = (data ?? []) as EscoltaRelatorio[]
    setEscoltas(rows)

    // Compute client metrics
    const map: Record<string, ClienteMetrica> = {}
    for (const e of rows) {
      const cid  = e.cliente?.id ?? '__sem_cliente__'
      const nome = e.cliente?.nome_cliente ?? 'Sem cliente'
      const cor  = e.cliente?.cor_destaque ?? P.steel
      if (!map[cid]) map[cid] = { id: cid, nome, cor, total: 0, concluidas: 0, canceladas: 0, ativas: 0, kmTotal: 0, duracaoMediaMin: 0 }
      map[cid].total++
      if (STATUSES_CONCLUIDOS.includes(e.status)) {
        map[cid].concluidas++
        map[cid].duracaoMediaMin += calcDuracaoMin(e)
      }
      if (STATUSES_CANCELADOS.includes(e.status)) map[cid].canceladas++
      if (STATUSES_ATIVOS.includes(e.status))     map[cid].ativas++
      map[cid].kmTotal += calcKmEscolta(e.veiculos)
    }
    const metricas = Object.values(map)
      .map(c => ({ ...c, duracaoMediaMin: c.concluidas > 0 ? c.duracaoMediaMin / c.concluidas : 0 }))
      .sort((a, b) => b.total - a.total)
    setClientesMetrica(metricas)
    setLoading(false)
  }, [tipoPeriodo, dataInicio, dataFim, clienteFiltroId, statusFiltro, sb])

  // Carrega ocorrências
  const carregarOcorrencias = useCallback(async () => {
    setLoadingOcorr(true)
    const { from, to } = computeRange(tipoPeriodo, dataInicio, dataFim)

    let q = sb.from('ocorrencias').select(`
      id, descricao, data_hora,
      tipo:dom_tipos_ocorrencia(nome),
      autor:usuarios!registrado_por(nome_completo),
      escolta:escoltas(codigo_escolta)
    `)
    .gte('data_hora', from)
    .lte('data_hora', to)
    .order('data_hora', { ascending: false })

    const { data } = await q
    const rows = (data ?? []) as OcorrenciaRelatorio[]
    setOcorrencias(rows)

    const tipos = Array.from(new Set(rows.map(o => o.tipo?.nome).filter(Boolean))) as string[]
    setTiposOcorrencia(tipos)
    setLoadingOcorr(false)
  }, [tipoPeriodo, dataInicio, dataFim, sb])

  useEffect(() => { carregarEscoltas() }, [carregarEscoltas])
  useEffect(() => {
    if (tab === 'ocorrencias') carregarOcorrencias()
  }, [tab, carregarOcorrencias])

  // Reset pagination on filter change
  useEffect(() => { setPageEsc(0) }, [searchEsc, statusFiltro, clienteFiltroId, tipoPeriodo])
  useEffect(() => { setPageOcorr(0) }, [tipoOcorrFiltro])

  // ─── Computed KPIs ──────────────────────────────────────────────────────────
  const total      = escoltas.length
  const ativas     = escoltas.filter(e => STATUSES_ATIVOS.includes(e.status))
  const concluidas = escoltas.filter(e => STATUSES_CONCLUIDOS.includes(e.status))
  const canceladas = escoltas.filter(e => STATUSES_CANCELADOS.includes(e.status))
  const kmTotal    = escoltas.reduce((s, e) => s + calcKmEscolta(e.veiculos), 0)
  const slaExcedidos = ativas.filter(e => diffMinutes(e.data_hora_prevista) > 600).length
  const txConclusao  = (concluidas.length + canceladas.length) > 0
    ? Math.round((concluidas.length / (concluidas.length + canceladas.length)) * 100) : 0
  const txCancelamento = total > 0 ? Math.round((canceladas.length / total) * 100) : 0
  const kmMedio = concluidas.length > 0 ? Math.round(kmTotal / concluidas.length) : 0

  const duracaoMediaMin = concluidas.length > 0
    ? Math.round(concluidas.reduce((s, e) => s + calcDuracaoMin(e), 0) / concluidas.length) : 0

  // Distribuição por status
  const distStatus = Object.entries(STATUS_LABEL).map(([key, label]) => {
    const count = escoltas.filter(e => e.status === key).length
    return { key, label, count, pct: total > 0 ? (count / total) * 100 : 0 }
  }).filter(d => d.count > 0).sort((a, b) => b.count - a.count)

  // Top 5 clientes
  const top5 = clientesMetrica.slice(0, 5)
  const maxTop5 = Math.max(...top5.map(c => c.total), 1)

  // ─── Tabela Escoltas filtrada/ordenada ───────────────────────────────────────
  const escFiltradas = escoltas.filter(e => {
    if (!searchEsc) return true
    const q = searchEsc.toLowerCase()
    return (
      (e.codigo_escolta ?? '').toLowerCase().includes(q) ||
      (e.cliente?.nome_cliente ?? '').toLowerCase().includes(q) ||
      (e.origem_endereco ?? '').toLowerCase().includes(q) ||
      (e.destino_endereco ?? '').toLowerCase().includes(q)
    )
  })

  const escOrdenadas = [...escFiltradas].sort((a, b) => {
    if (!sortDir) return 0
    let va: string | number = '', vb: string | number = ''
    if (sortCol === 'codigo_escolta')    { va = a.codigo_escolta ?? ''; vb = b.codigo_escolta ?? '' }
    if (sortCol === 'cliente')           { va = a.cliente?.nome_cliente ?? ''; vb = b.cliente?.nome_cliente ?? '' }
    if (sortCol === 'status')            { va = a.status; vb = b.status }
    if (sortCol === 'data_hora_prevista'){ va = a.data_hora_prevista; vb = b.data_hora_prevista }
    if (sortCol === 'data_finalizacao')  { va = a.data_finalizacao ?? ''; vb = b.data_finalizacao ?? '' }
    if (sortCol === 'km')                { va = calcKmEscolta(a.veiculos); vb = calcKmEscolta(b.veiculos) }
    if (sortCol === 'duracao')           { va = calcDuracaoMin(a); vb = calcDuracaoMin(b) }
    if (va < vb) return sortDir === 'asc' ? -1 : 1
    if (va > vb) return sortDir === 'asc' ? 1  : -1
    return 0
  })

  const escPagina   = escOrdenadas.slice(pageEsc * PAGE_ESC, (pageEsc + 1) * PAGE_ESC)
  const totalPagesEsc = Math.ceil(escOrdenadas.length / PAGE_ESC)

  function toggleSort(col: string) {
    if (sortCol !== col) { setSortCol(col); setSortDir('asc') }
    else if (sortDir === 'asc')  setSortDir('desc')
    else if (sortDir === 'desc') setSortDir(null)
    else { setSortDir('asc') }
  }

  const thStyle = (col: string): React.CSSProperties => ({
    cursor: 'pointer',
    userSelect: 'none',
    whiteSpace: 'nowrap',
    backgroundColor: sortCol === col ? P.steel : undefined,
  })

  // Ocorrências filtradas
  const ocorrFiltradas = tipoOcorrFiltro
    ? ocorrencias.filter(o => o.tipo?.nome === tipoOcorrFiltro)
    : ocorrencias
  const ocorrPagina    = ocorrFiltradas.slice(pageOcorr * PAGE_OCORR, (pageOcorr + 1) * PAGE_OCORR)
  const totalPagesOcorr = Math.ceil(ocorrFiltradas.length / PAGE_OCORR)

  // ─── Totais da tabela escoltas ───────────────────────────────────────────────
  const totalKmTabela   = escFiltradas.reduce((s, e) => s + calcKmEscolta(e.veiculos), 0)
  const avgDuracaoTabela = concluidas.length > 0
    ? Math.round(concluidas.reduce((s, e) => s + calcDuracaoMin(e), 0) / concluidas.length) : 0

  // ─── Styles ───────────────────────────────────────────────────────────────────
  const cardStyle: React.CSSProperties = {
    background: '#fff',
    border: `1px solid ${P.border}`,
    borderRadius: '2px',
    boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
    overflow: 'hidden',
  }
  const btnTabStyle = (active: boolean): React.CSSProperties => ({
    display: 'inline-flex', alignItems: 'center', gap: '6px',
    padding: '8px 16px', borderRadius: '2px', cursor: 'pointer', border: 'none',
    fontSize: '11px', fontWeight: 900, letterSpacing: '0.08em', textTransform: 'uppercase',
    transition: 'all 0.15s',
    backgroundColor: active ? P.navy : 'transparent',
    color:           active ? '#fff' : P.textSub,
  })
  const periodBtnStyle = (active: boolean): React.CSSProperties => ({
    padding: '7px 14px', fontSize: '11px', fontWeight: 700, cursor: 'pointer',
    border: `1.5px solid ${active ? P.navy : P.border}`, borderRadius: '2px',
    backgroundColor: active ? P.navy : 'transparent', color: active ? '#fff' : P.textSub,
    letterSpacing: '0.06em', transition: 'all 0.15s',
  })
  const exportBtnStyle: React.CSSProperties = {
    display: 'inline-flex', alignItems: 'center', gap: '6px',
    padding: '8px 14px', fontSize: '10px', fontWeight: 900, cursor: 'pointer',
    border: `1.5px solid ${P.border}`, borderRadius: '2px',
    backgroundColor: '#fff', color: P.steel, letterSpacing: '0.08em', textTransform: 'uppercase',
    transition: 'all 0.15s', minHeight: '36px',
  }

  const TABS: { id: TabId; icon: React.ElementType; label: string }[] = [
    { id: 'resumo',     icon: BarChart2, label: 'Resumo Executivo'  },
    { id: 'escoltas',   icon: Table2,    label: 'Relatório de Escoltas' },
    { id: 'clientes',   icon: Users,     label: 'Análise por Cliente' },
    { id: 'ocorrencias',icon: AlertTriangle, label: 'Ocorrências'   },
  ]

  const PERIODOS: { key: TipoPeriodo; label: string }[] = [
    { key: 'hoje',         label: 'Hoje'         },
    { key: 'semana',       label: 'Semana'       },
    { key: 'mes',          label: 'Mês'          },
    { key: 'trimestre',    label: 'Trimestre'    },
    { key: 'personalizado',label: 'Personalizado'},
  ]

  // ─── Render ──────────────────────────────────────────────────────────────────
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>

      {/* ── Header ── */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:flex-wrap">
        <div>
          <div className="eyebrow-tag" style={{ marginBottom: '8px' }}>
            <FileText size={10} />
            Centro de Relatórios
          </div>
          <h1 className="page-title">Relatórios</h1>
          <p className="page-subtitle">Análise gerencial e operacional do período selecionado.</p>
        </div>
        <button
          style={exportBtnStyle}
          className="w-full sm:w-auto justify-center"
          onClick={() => exportarCSVCompleto(escoltas, clientesMetrica, ocorrencias, periodo)}
          disabled={loading || escoltas.length === 0}
          onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
          onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.steel }}
        >
          <FileDown size={13} /> Exportar Tudo CSV
        </button>
      </div>

      {/* ── Filter Bar ── */}
      <div style={{ ...cardStyle, padding: '16px', display: 'flex', flexDirection: 'column', gap: '12px' }}>
        {/* Período */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
          <Filter size={12} style={{ color: P.steel, flexShrink: 0 }} />
          <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.textSub }}>Período</span>
          {PERIODOS.map(p => (
            <button key={p.key} style={periodBtnStyle(tipoPeriodo === p.key)} onClick={() => setTipoPeriodo(p.key)}>
              {p.label}
            </button>
          ))}
        </div>

        {/* Datas personalizadas */}
        {tipoPeriodo === 'personalizado' && (
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:flex-wrap" style={{ gap: '8px' }}>
            <label style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>De</label>
            <input type="date" value={dataInicio} onChange={e => setDataInicio(e.target.value)}
              className="w-full sm:w-auto"
              style={{ padding: '7px 10px', fontSize: '12px', border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
            <label style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>Até</label>
            <input type="date" value={dataFim} onChange={e => setDataFim(e.target.value)}
              className="w-full sm:w-auto"
              style={{ padding: '7px 10px', fontSize: '12px', border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
          </div>
        )}

        {/* Cliente + Status + Gerar */}
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center" style={{ borderTop: `1px solid ${P.steelBg}`, paddingTop: '12px', gap: '10px' }}>
          <div style={{ position: 'relative' }} className="w-full sm:w-auto">
            <select value={clienteFiltroId} onChange={e => setClienteFiltroId(e.target.value)}
              className="w-full sm:w-auto"
              style={{ padding: '8px 32px 8px 10px', fontSize: '12px', fontWeight: 600, border: `1.5px solid ${clienteFiltroId ? P.navy : P.border}`, borderRadius: '2px', color: clienteFiltroId ? P.navy : P.textSub, backgroundColor: clienteFiltroId ? P.navyBg : '#fff', outline: 'none', appearance: 'none', minWidth: '200px', cursor: 'pointer' }}>
              <option value="">Todos os clientes</option>
              {clientes.map(c => <option key={c.id} value={c.id}>{c.nome_cliente}</option>)}
            </select>
            <ChevronDown size={11} style={{ position: 'absolute', right: '10px', top: '50%', transform: 'translateY(-50%)', color: P.textSub, pointerEvents: 'none' }} />
          </div>
          <div style={{ position: 'relative' }} className="w-full sm:w-auto">
            <select value={statusFiltro} onChange={e => setStatusFiltro(e.target.value)}
              className="w-full sm:w-auto"
              style={{ padding: '8px 32px 8px 10px', fontSize: '12px', fontWeight: 600, border: `1.5px solid ${statusFiltro ? P.navy : P.border}`, borderRadius: '2px', color: statusFiltro ? P.navy : P.textSub, backgroundColor: statusFiltro ? P.navyBg : '#fff', outline: 'none', appearance: 'none', minWidth: '170px', cursor: 'pointer' }}>
              <option value="">Todos os status</option>
              {Object.entries(STATUS_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
            <ChevronDown size={11} style={{ position: 'absolute', right: '10px', top: '50%', transform: 'translateY(-50%)', color: P.textSub, pointerEvents: 'none' }} />
          </div>
          <button
            className="btn-primary w-full sm:w-auto"
            style={{ minHeight: '44px', gap: '6px' }}
            onClick={() => { carregarEscoltas(); if (tab === 'ocorrencias') carregarOcorrencias() }}
          >
            <RefreshCw size={12} /> Gerar Relatório
          </button>
        </div>
      </div>

      {/* ── Tab Navigation ── */}
      <div className="overflow-x-auto -mx-1 px-1" style={{ scrollbarWidth: 'none' }}>
        <div style={{ display: 'flex', gap: '4px', whiteSpace: 'nowrap' }}>
          {TABS.map(t => (
            <button key={t.id} style={btnTabStyle(tab === t.id)} onClick={() => setTab(t.id)}>
              <t.icon size={13} /> {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* ══════════════════════════════════════════════════════
          TAB 1 — RESUMO EXECUTIVO
      ══════════════════════════════════════════════════════ */}
      {tab === 'resumo' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>

          {/* KPI Cards */}
          <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-2.5">
            {[
              {
                label: 'Total Escoltas',
                valor: loading ? '—' : total.toLocaleString('pt-BR'),
                sub: 'no período',
                icon: Shield,
                dark: true,
                live: false,
                badge: null,
              },
              {
                label: 'Concluídas',
                valor: loading ? '—' : concluidas.length.toLocaleString('pt-BR'),
                sub: total > 0 ? `${Math.round((concluidas.length/total)*100)}% do total` : '—',
                icon: CheckCircle2,
                dark: false,
                live: false,
                badge: null,
              },
              {
                label: 'Canceladas',
                valor: loading ? '—' : canceladas.length.toLocaleString('pt-BR'),
                sub: `${txCancelamento}% do total`,
                icon: XCircle,
                dark: false,
                live: false,
                badge: canceladas.length > 0 ? 'danger' : null,
              },
              {
                label: 'Ativas Agora',
                valor: loading ? '—' : ativas.length.toLocaleString('pt-BR'),
                sub: `${slaExcedidos} com SLA excedido`,
                icon: Activity,
                dark: false,
                live: true,
                badge: null,
              },
              {
                label: 'KM Total',
                valor: loading ? '—' : `${kmTotal.toLocaleString('pt-BR')} km`,
                sub: `~${kmMedio.toLocaleString('pt-BR')} km/escolta`,
                icon: Truck,
                dark: false,
                live: false,
                badge: null,
              },
              {
                label: 'Ocorrências',
                valor: loading ? '—' : ocorrencias.length > 0 ? ocorrencias.length.toLocaleString('pt-BR') : '—',
                sub: 'registradas no período',
                icon: AlertTriangle,
                dark: false,
                live: false,
                badge: ocorrencias.length > 5 ? 'danger' : null,
              },
            ].map((k, i) => {
              const Icon = k.icon
              return (
                <div key={k.label} style={{
                  minHeight: '130px', padding: '16px', borderRadius: '2px',
                  display: 'flex', flexDirection: 'column', justifyContent: 'space-between',
                  ...(k.dark
                    ? { backgroundColor: P.navy, boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }
                    : { backgroundColor: '#fff', border: `1px solid ${P.border}`, boxShadow: '0 1px 3px rgba(0,0,0,0.05)' })
                }}>
                  <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
                    <div style={{ width: '34px', height: '34px', borderRadius: '2px', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: k.dark ? 'rgba(255,255,255,0.08)' : P.steelBg }}>
                      <Icon size={16} style={{ color: k.dark ? P.light : P.steel }} />
                    </div>
                    {k.live && (
                      <span className="glow-active" style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', padding: '2px 6px', borderRadius: '2px', backgroundColor: P.navyBg, color: P.navy, border: `1px solid ${P.border}` }}>LIVE</span>
                    )}
                    {k.badge === 'danger' && (
                      <span style={{ fontSize: '9px', fontWeight: 900, padding: '2px 6px', borderRadius: '2px', backgroundColor: '#FAEAE9', color: '#B83832', border: '1px solid rgba(184,56,50,0.2)' }}>!</span>
                    )}
                  </div>
                  <div>
                    <p style={{ fontSize: i === 4 ? '16px' : '22px', fontWeight: 900, color: k.dark ? '#fff' : P.text, lineHeight: 1.2 }}>{k.valor}</p>
                    <p style={{ fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em', color: k.dark ? 'rgba(255,255,255,0.45)' : P.textSub, marginTop: '2px' }}>{k.label}</p>
                    <p style={{ fontSize: '10px', color: k.dark ? 'rgba(255,255,255,0.3)' : P.light, marginTop: '2px' }}>{k.sub}</p>
                  </div>
                </div>
              )
            })}
          </div>

          {/* Metrics Grid */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">

            {/* Distribuição por Status */}
            <div style={cardStyle}>
              <div style={{ padding: '14px 16px', borderBottom: `1px solid ${P.border}` }}>
                <SectionTitle icon={PieChart} label="Distribuição por Status" />
              </div>
              <div style={{ padding: '16px', display: 'flex', flexDirection: 'column', gap: '10px' }}>
                {loading ? <SkeletonRows n={4} cols={1} /> : distStatus.length === 0 ? (
                  <EmptyState icon={BarChart2} msg="Nenhuma escolta no período" />
                ) : distStatus.map(d => (
                  <div key={d.key}>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '4px' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                        <span className={STATUS_BADGE[d.key] ?? 'badge-neutral'}>{d.label}</span>
                      </div>
                      <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                        <span style={{ fontSize: '10px', color: P.textSub }}>{d.count}</span>
                        <span style={{ fontSize: '10px', fontWeight: 700, color: P.text, width: '34px', textAlign: 'right' }}>{d.pct.toFixed(0)}%</span>
                      </div>
                    </div>
                    <MiniBar pct={d.pct} color={STATUSES_CONCLUIDOS.includes(d.key) ? P.successText : STATUSES_CANCELADOS.includes(d.key) ? P.errorText : P.navy} />
                  </div>
                ))}
              </div>
            </div>

            {/* Eficiência Operacional */}
            <div style={cardStyle}>
              <div style={{ padding: '14px 16px', borderBottom: `1px solid ${P.border}` }}>
                <SectionTitle icon={Activity} label="Eficiência Operacional" />
              </div>
              <div style={{ padding: '16px', display: 'flex', flexDirection: 'column', gap: '14px' }}>
                {[
                  { label: 'Taxa de Conclusão',    valor: `${txConclusao}%`,   pct: txConclusao,    cor: txConclusao >= 80 ? P.navy : P.errorText },
                  { label: 'Taxa de Cancelamento', valor: `${txCancelamento}%`, pct: txCancelamento, cor: txCancelamento <= 10 ? P.steel : P.errorText },
                  { label: 'SLA Excedido (>10h)',  valor: slaExcedidos.toString(), pct: ativas.length > 0 ? (slaExcedidos/ativas.length)*100 : 0, cor: slaExcedidos > 0 ? P.alertBorder : P.steel },
                  { label: 'KM Médio / Escolta',   valor: `${kmMedio.toLocaleString('pt-BR')} km`, pct: 100, cor: P.navy },
                ].map(m => (
                  <div key={m.label}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '4px', alignItems: 'center' }}>
                      <span style={{ fontSize: '11px', fontWeight: 600, color: P.text }}>{m.label}</span>
                      <span style={{ fontSize: '13px', fontWeight: 900, color: loading ? P.light : m.cor }}>{loading ? '—' : m.valor}</span>
                    </div>
                    <MiniBar pct={m.pct} color={m.cor} />
                  </div>
                ))}

                <div style={{ marginTop: '8px', padding: '10px 12px', backgroundColor: P.navyBg, borderRadius: '2px', display: 'flex', alignItems: 'flex-start', gap: '8px' }}>
                  <Info size={12} style={{ color: P.steel, flexShrink: 0, marginTop: '1px' }} />
                  <p style={{ fontSize: '10px', color: P.textSub, lineHeight: 1.5, margin: 0 }}>
                    Duração média das finalizadas: <strong style={{ color: P.navy }}>{loading ? '—' : formatDuracao(duracaoMediaMin)}</strong>
                  </p>
                </div>
              </div>
            </div>
          </div>

          {/* Top 5 Clientes */}
          <div style={cardStyle}>
            <div style={{ padding: '14px 16px', borderBottom: `1px solid ${P.border}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <SectionTitle icon={Users} label="Performance por Cliente — Top 5" />
              <span className="badge-neutral">{clientesMetrica.length} clientes</span>
            </div>
            <div style={{ padding: '16px' }}>
              {loading ? <SkeletonRows n={5} cols={3} /> : top5.length === 0 ? (
                <EmptyState icon={Users} msg="Nenhum cliente no período" />
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
                  {top5.map((c, idx) => {
                    const tx = (c.concluidas + c.canceladas) > 0 ? Math.round((c.concluidas / (c.concluidas + c.canceladas)) * 100) : 0
                    return (
                      <div key={c.id}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '5px' }}>
                          <span style={{ fontSize: '11px', fontWeight: 900, color: P.light, width: '16px', flexShrink: 0 }}>{idx + 1}</span>
                          <div style={{ width: '8px', height: '8px', borderRadius: '2px', backgroundColor: c.cor, flexShrink: 0 }} />
                          <span style={{ fontSize: '12px', fontWeight: 700, color: P.text, flex: 1, minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{c.nome}</span>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                            <span className="badge-neutral">{c.total} total</span>
                            <span className="badge-success">{tx}% concl.</span>
                          </div>
                        </div>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                          <span style={{ width: '16px', flexShrink: 0 }} />
                          <div style={{ flex: 1, height: '8px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
                            <div style={{ width: `${(c.total / maxTop5) * 100}%`, height: '100%', backgroundColor: c.cor || P.navy, borderRadius: '2px', transition: 'width 0.8s ease' }} />
                          </div>
                          <span style={{ fontSize: '10px', color: P.textSub, width: '48px', flexShrink: 0 }}>{c.kmTotal.toLocaleString('pt-BR')} km</span>
                        </div>
                      </div>
                    )
                  })}
                </div>
              )}
            </div>
          </div>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════
          TAB 2 — RELATÓRIO DE ESCOLTAS
      ══════════════════════════════════════════════════════ */}
      {tab === 'escoltas' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          {/* Sub-header */}
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:flex-wrap">
            <div style={{ display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' }}>
              <span className="badge-neutral">{escFiltradas.length.toLocaleString('pt-BR')} registros</span>
              {searchEsc && <span style={{ fontSize: '10px', color: P.textSub }}>filtrado por &quot;{searchEsc}&quot;</span>}
            </div>
            <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
              {/* Search */}
              <div style={{ position: 'relative' }}>
                <Search size={12} style={{ position: 'absolute', left: '10px', top: '50%', transform: 'translateY(-50%)', color: P.light, pointerEvents: 'none' }} />
                <input
                  type="text"
                  placeholder="Buscar código, cliente, endereço..."
                  value={searchEsc}
                  onChange={e => setSearchEsc(e.target.value)}
                  className="w-full sm:w-auto"
                  style={{ padding: '8px 10px 8px 30px', fontSize: '12px', border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none', minWidth: '200px' }}
                />
              </div>
              <button style={exportBtnStyle} onClick={() => exportarCSVEscoltas(escFiltradas, periodo)}
                disabled={escFiltradas.length === 0}
                className="w-full sm:w-auto justify-center"
                onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
                onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.steel }}>
                <Download size={12} /> Exportar CSV
              </button>
            </div>
          </div>

          {/* Tabela */}
          <div style={cardStyle}>
            {loading ? <SkeletonRows n={8} cols={6} /> : escFiltradas.length === 0 ? (
              <EmptyState icon={FileText} msg="Nenhuma escolta encontrada" />
            ) : (
              <>
                {/* Desktop table */}
                <div className="hidden md:block" style={{ overflowX: 'auto' }}>
                  <table className="table-content">
                    <thead>
                      <tr>
                        {[
                          { col: 'codigo_escolta',    label: 'Código'   },
                          { col: 'cliente',            label: 'Cliente'  },
                          { col: 'status',             label: 'Status'   },
                          { col: 'origem',             label: 'Origem'   },
                          { col: 'destino',            label: 'Destino'  },
                          { col: 'data_hora_prevista', label: 'Previsto' },
                          { col: 'data_finalizacao',   label: 'Finaliz.' },
                          { col: 'duracao',            label: 'Duração'  },
                          { col: 'km',                 label: 'KM'       },
                        ].map(h => (
                          <th key={h.col} style={thStyle(h.col)} onClick={() => toggleSort(h.col)}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                              {h.label} <SortIcon col={h.col} sortCol={sortCol} sortDir={sortDir} />
                            </div>
                          </th>
                        ))}
                        <th style={{ width: '36px' }} />
                      </tr>
                    </thead>
                    <tbody>
                      {escPagina.map(e => {
                        const km  = calcKmEscolta(e.veiculos)
                        const dur = calcDuracaoMin(e)
                        return (
                          <tr key={e.id}
                            style={{ cursor: 'pointer' }}
                            onClick={() => window.open(`/dashboard/escoltas/${e.id}`, '_blank')}
                          >
                            <td><span style={{ fontFamily: 'monospace', fontSize: '12px', fontWeight: 700, color: P.text }}>{e.codigo_escolta ?? '—'}</span></td>
                            <td>
                              <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                                {e.cliente?.cor_destaque && <div style={{ width: '6px', height: '6px', borderRadius: '2px', backgroundColor: e.cliente.cor_destaque, flexShrink: 0 }} />}
                                <span style={{ fontSize: '12px', color: P.text, maxWidth: '130px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.cliente?.nome_cliente ?? '—'}</span>
                              </div>
                            </td>
                            <td><span className={STATUS_BADGE[e.status] ?? 'badge-neutral'}>{STATUS_LABEL[e.status] ?? e.status}</span></td>
                            <td><span style={{ fontSize: '11px', color: P.textSub, maxWidth: '140px', display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.origem_endereco ? e.origem_endereco.split(',').slice(0,2).join(',') : '—'}</span></td>
                            <td><span style={{ fontSize: '11px', color: P.textSub, maxWidth: '140px', display: 'block', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.destino_endereco ? e.destino_endereco.split(',').slice(0,2).join(',') : '—'}</span></td>
                            <td><span style={{ fontSize: '11px', color: P.textSub, whiteSpace: 'nowrap' }}>{new Date(e.data_hora_prevista).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' })}</span></td>
                            <td><span style={{ fontSize: '11px', color: P.textSub, whiteSpace: 'nowrap' }}>{e.data_finalizacao ? new Date(e.data_finalizacao).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' }) : '—'}</span></td>
                            <td><span style={{ fontSize: '11px', color: P.text, fontWeight: 600 }}>{STATUSES_CONCLUIDOS.includes(e.status) ? formatDuracao(dur) : '—'}</span></td>
                            <td><span style={{ fontSize: '11px', color: km > 0 ? P.text : P.light, fontWeight: km > 0 ? 700 : 400 }}>{km > 0 ? `${km.toLocaleString('pt-BR')} km` : '—'}</span></td>
                            <td><ChevronRight size={13} style={{ color: P.border }} /></td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>

                {/* Mobile cards */}
                <div className="md:hidden space-y-2 p-3">
                  {escPagina.map(e => {
                    const km  = calcKmEscolta(e.veiculos)
                    const dur = calcDuracaoMin(e)
                    return (
                      <button key={e.id}
                        onClick={() => window.open(`/dashboard/escoltas/${e.id}`, '_blank')}
                        className="w-full text-left rounded-lg p-3 border transition-all active:scale-[0.99]"
                        style={{ borderColor: P.border, backgroundColor: '#fff' }}>
                        <div className="flex items-center justify-between mb-1.5">
                          <span style={{ fontFamily: 'monospace', fontSize: '13px', fontWeight: 700, color: P.text }}>{e.codigo_escolta ?? '—'}</span>
                          <span className={STATUS_BADGE[e.status] ?? 'badge-neutral'}>{STATUS_LABEL[e.status] ?? e.status}</span>
                        </div>
                        <div className="flex items-center gap-1.5 mb-1">
                          {e.cliente?.cor_destaque && <div style={{ width: '6px', height: '6px', borderRadius: '2px', backgroundColor: e.cliente.cor_destaque, flexShrink: 0 }} />}
                          <span style={{ fontSize: '12px', fontWeight: 600, color: P.text }}>{e.cliente?.nome_cliente ?? '—'}</span>
                        </div>
                        <p style={{ fontSize: '11px', color: P.textSub }} className="truncate">{e.origem_endereco ? e.origem_endereco.split(',').slice(0,2).join(',') : '—'}</p>
                        <div className="flex items-center justify-between mt-1.5">
                          <span style={{ fontSize: '11px', color: P.light }}>{new Date(e.data_hora_prevista).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' })}</span>
                          <div className="flex items-center gap-2">
                            {km > 0 && <span style={{ fontSize: '11px', color: P.text, fontWeight: 700 }}>{km.toLocaleString('pt-BR')} km</span>}
                            {STATUSES_CONCLUIDOS.includes(e.status) && <span style={{ fontSize: '11px', color: P.textSub }}>{formatDuracao(dur)}</span>}
                          </div>
                        </div>
                      </button>
                    )
                  })}
                </div>
              </>
            )}

            {/* Footer totais */}
            {escFiltradas.length > 0 && (
              <div style={{ borderTop: `1px solid ${P.border}`, padding: '10px 16px', display: 'flex', alignItems: 'center', gap: '16px', flexWrap: 'wrap', backgroundColor: P.bg }}>
                <span style={{ fontSize: '10px', fontWeight: 700, color: P.textSub }}>
                  KM Total: <strong style={{ color: P.text }}>{totalKmTabela.toLocaleString('pt-BR')} km</strong>
                </span>
                <span style={{ fontSize: '10px', fontWeight: 700, color: P.textSub }}>
                  Duração Média (finalizadas): <strong style={{ color: P.text }}>{formatDuracao(avgDuracaoTabela)}</strong>
                </span>
              </div>
            )}

            {/* Paginação */}
            {totalPagesEsc > 1 && (
              <div style={{ borderTop: `1px solid ${P.border}`, padding: '10px 16px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <button
                  disabled={pageEsc === 0}
                  onClick={() => setPageEsc(p => p - 1)}
                  className="btn-outline"
                  style={{ minHeight: '36px', padding: '6px 14px', opacity: pageEsc === 0 ? 0.4 : 1 }}
                >
                  Anterior
                </button>
                <span style={{ fontSize: '11px', color: P.textSub }}>
                  Pág. {pageEsc + 1} de {totalPagesEsc} · {escFiltradas.length} registros
                </span>
                <button
                  disabled={pageEsc >= totalPagesEsc - 1}
                  onClick={() => setPageEsc(p => p + 1)}
                  className="btn-outline"
                  style={{ minHeight: '36px', padding: '6px 14px', opacity: pageEsc >= totalPagesEsc - 1 ? 0.4 : 1 }}
                >
                  Próximo
                </button>
              </div>
            )}
          </div>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════
          TAB 3 — ANÁLISE POR CLIENTE
      ══════════════════════════════════════════════════════ */}
      {tab === 'clientes' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end' }}>
            <button style={exportBtnStyle} onClick={() => exportarCSVClientes(clientesMetrica, periodo)}
              disabled={clientesMetrica.length === 0}
              onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
              onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.steel }}>
              <Download size={12} /> Exportar CSV
            </button>
          </div>

          <div style={cardStyle}>
            {loading ? <SkeletonRows n={5} cols={6} /> : clientesMetrica.length === 0 ? (
              <EmptyState icon={Users} msg="Nenhum dado de clientes no período" />
            ) : (
              <>
                {/* Desktop table */}
                <div className="hidden md:block" style={{ overflowX: 'auto' }}>
                  <table className="table-content">
                    <thead>
                      <tr>
                        <th>Cliente</th>
                        <th>Total</th>
                        <th>Concluídas</th>
                        <th>Canceladas</th>
                        <th>Taxa Conclusão</th>
                        <th>KM Total</th>
                        <th>Duração Média</th>
                        <th>Participação</th>
                      </tr>
                    </thead>
                    <tbody>
                      {clientesMetrica.map(c => {
                        const tx = (c.concluidas + c.canceladas) > 0
                          ? Math.round((c.concluidas / (c.concluidas + c.canceladas)) * 100) : 0
                        const participacao = total > 0 ? (c.total / total) * 100 : 0
                        return (
                          <tr key={c.id}>
                            <td>
                              <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                                <div style={{ width: '8px', height: '8px', borderRadius: '2px', backgroundColor: c.cor, flexShrink: 0 }} />
                                <span style={{ fontSize: '12px', fontWeight: 700, color: P.text }}>{c.nome}</span>
                              </div>
                            </td>
                            <td><span style={{ fontSize: '14px', fontWeight: 900, color: P.text }}>{c.total}</span></td>
                            <td><span style={{ fontSize: '12px', fontWeight: 600, color: P.successText }}>{c.concluidas}</span></td>
                            <td><span style={{ fontSize: '12px', fontWeight: 600, color: c.canceladas > 0 ? P.errorText : P.light }}>{c.canceladas}</span></td>
                            <td><span style={{ fontSize: '12px', fontWeight: 700, color: tx >= 80 ? P.navy : P.errorText }}>{tx}%</span></td>
                            <td><span style={{ fontSize: '12px', color: P.text }}>{c.kmTotal.toLocaleString('pt-BR')} km</span></td>
                            <td><span style={{ fontSize: '12px', color: P.textSub }}>{c.duracaoMediaMin > 0 ? formatDuracao(Math.round(c.duracaoMediaMin)) : '—'}</span></td>
                            <td>
                              <div style={{ display: 'flex', alignItems: 'center', gap: '8px', minWidth: '100px' }}>
                                <MiniBar pct={participacao} color={c.cor || P.navy} />
                                <span style={{ fontSize: '10px', color: P.textSub, flexShrink: 0 }}>{participacao.toFixed(0)}%</span>
                              </div>
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>

                {/* Mobile cards */}
                <div className="md:hidden space-y-2 p-3">
                  {clientesMetrica.map(c => {
                    const tx = (c.concluidas + c.canceladas) > 0
                      ? Math.round((c.concluidas / (c.concluidas + c.canceladas)) * 100) : 0
                    const participacao = total > 0 ? (c.total / total) * 100 : 0
                    return (
                      <div key={c.id} className="rounded-lg p-3 border" style={{ borderColor: P.border, backgroundColor: '#fff' }}>
                        <div className="flex items-center justify-between mb-2">
                          <div className="flex items-center gap-2">
                            <div style={{ width: '8px', height: '8px', borderRadius: '2px', backgroundColor: c.cor, flexShrink: 0 }} />
                            <span style={{ fontSize: '13px', fontWeight: 700, color: P.text }}>{c.nome}</span>
                          </div>
                          <span style={{ fontSize: '16px', fontWeight: 900, color: P.text }}>{c.total}</span>
                        </div>
                        <div className="grid grid-cols-3 gap-2 mb-2">
                          <div className="text-center p-1.5 rounded" style={{ backgroundColor: P.successBg }}>
                            <p style={{ fontSize: '13px', fontWeight: 700, color: P.successText }}>{c.concluidas}</p>
                            <p style={{ fontSize: '9px', color: P.successText }}>Concluídas</p>
                          </div>
                          <div className="text-center p-1.5 rounded" style={{ backgroundColor: c.canceladas > 0 ? P.errorBg : P.steelBg }}>
                            <p style={{ fontSize: '13px', fontWeight: 700, color: c.canceladas > 0 ? P.errorText : P.light }}>{c.canceladas}</p>
                            <p style={{ fontSize: '9px', color: c.canceladas > 0 ? P.errorText : P.light }}>Canceladas</p>
                          </div>
                          <div className="text-center p-1.5 rounded" style={{ backgroundColor: tx >= 80 ? P.navyBg : P.errorBg }}>
                            <p style={{ fontSize: '13px', fontWeight: 700, color: tx >= 80 ? P.navy : P.errorText }}>{tx}%</p>
                            <p style={{ fontSize: '9px', color: tx >= 80 ? P.navy : P.errorText }}>Conclusão</p>
                          </div>
                        </div>
                        <div className="flex items-center gap-2 mt-1">
                          <MiniBar pct={participacao} color={c.cor || P.navy} />
                          <span style={{ fontSize: '10px', color: P.textSub, flexShrink: 0 }}>{participacao.toFixed(0)}%</span>
                        </div>
                        <div className="flex items-center justify-between mt-1">
                          <span style={{ fontSize: '11px', color: P.textSub }}>{c.kmTotal.toLocaleString('pt-BR')} km</span>
                          <span style={{ fontSize: '11px', color: P.textSub }}>{c.duracaoMediaMin > 0 ? formatDuracao(Math.round(c.duracaoMediaMin)) : '—'}</span>
                        </div>
                      </div>
                    )
                  })}
                </div>
              </>
            )}
          </div>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════
          TAB 4 — OCORRÊNCIAS
      ══════════════════════════════════════════════════════ */}
      {tab === 'ocorrencias' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between sm:flex-wrap">
            <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-2">
              {/* Filtro tipo */}
              <div style={{ position: 'relative' }} className="w-full sm:w-auto">
                <select value={tipoOcorrFiltro} onChange={e => setTipoOcorrFiltro(e.target.value)}
                  className="w-full sm:w-auto"
                  style={{ padding: '8px 30px 8px 10px', fontSize: '12px', fontWeight: 600, border: `1.5px solid ${tipoOcorrFiltro ? P.navy : P.border}`, borderRadius: '2px', color: tipoOcorrFiltro ? P.navy : P.textSub, backgroundColor: tipoOcorrFiltro ? P.navyBg : '#fff', outline: 'none', appearance: 'none', minWidth: '180px', cursor: 'pointer' }}>
                  <option value="">Todos os tipos</option>
                  {tiposOcorrencia.map(t => <option key={t} value={t}>{t}</option>)}
                </select>
                <ChevronDown size={11} style={{ position: 'absolute', right: '10px', top: '50%', transform: 'translateY(-50%)', color: P.textSub, pointerEvents: 'none' }} />
              </div>
              <span className="badge-neutral">{ocorrFiltradas.length} registros</span>
            </div>
            <button style={exportBtnStyle} onClick={() => exportarCSVOcorrencias(ocorrFiltradas, periodo)}
              disabled={ocorrFiltradas.length === 0}
              className="w-full sm:w-auto justify-center"
              onMouseEnter={e => { (e.currentTarget as HTMLElement).style.borderColor = P.navy; (e.currentTarget as HTMLElement).style.color = P.navy }}
              onMouseLeave={e => { (e.currentTarget as HTMLElement).style.borderColor = P.border; (e.currentTarget as HTMLElement).style.color = P.steel }}>
              <Download size={12} /> Exportar CSV
            </button>
          </div>

          <div style={cardStyle}>
            {loadingOcorr ? <SkeletonRows n={6} cols={5} /> : ocorrFiltradas.length === 0 ? (
              <EmptyState icon={AlertTriangle} msg="Nenhuma ocorrência no período" />
            ) : (
              <>
                {/* Desktop table */}
                <div className="hidden md:block" style={{ overflowX: 'auto' }}>
                  <table className="table-content">
                    <thead>
                      <tr>
                        <th>Data/Hora</th>
                        <th>Código Escolta</th>
                        <th>Tipo</th>
                        <th>Descrição</th>
                        <th>Registrado por</th>
                      </tr>
                    </thead>
                    <tbody>
                      {ocorrPagina.map(o => (
                        <tr key={o.id}>
                          <td><span style={{ fontSize: '11px', color: P.textSub, whiteSpace: 'nowrap' }}>{new Date(o.data_hora).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' })}</span></td>
                          <td><span style={{ fontFamily: 'monospace', fontSize: '12px', fontWeight: 700, color: P.navy }}>{o.escolta?.codigo_escolta ?? '—'}</span></td>
                          <td>{o.tipo?.nome ? <span className="badge-warning">{o.tipo.nome}</span> : <span style={{ fontSize: '11px', color: P.light }}>—</span>}</td>
                          <td><span style={{ fontSize: '12px', color: P.text, display: 'block', maxWidth: '320px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{o.descricao}</span></td>
                          <td><span style={{ fontSize: '11px', color: P.textSub }}>{o.autor?.nome_completo ?? '—'}</span></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>

                {/* Mobile cards */}
                <div className="md:hidden space-y-2 p-3">
                  {ocorrPagina.map(o => (
                    <div key={o.id} className="rounded-lg p-3 border" style={{ borderColor: P.border, backgroundColor: '#fff' }}>
                      <div className="flex items-start justify-between gap-2 mb-1.5">
                        <span style={{ fontFamily: 'monospace', fontSize: '13px', fontWeight: 700, color: P.navy }}>{o.escolta?.codigo_escolta ?? '—'}</span>
                        {o.tipo?.nome ? <span className="badge-warning">{o.tipo.nome}</span> : <span style={{ fontSize: '11px', color: P.light }}>—</span>}
                      </div>
                      <p style={{ fontSize: '12px', color: P.text }} className="line-clamp-2 mb-1.5">{o.descricao}</p>
                      <div className="flex items-center justify-between">
                        <span style={{ fontSize: '11px', color: P.textSub }}>{o.autor?.nome_completo ?? '—'}</span>
                        <span style={{ fontSize: '11px', color: P.light }}>{new Date(o.data_hora).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit', hour:'2-digit', minute:'2-digit' })}</span>
                      </div>
                    </div>
                  ))}
                </div>
              </>
            )}

            {/* Paginação ocorrências */}
            {totalPagesOcorr > 1 && (
              <div style={{ borderTop: `1px solid ${P.border}`, padding: '10px 16px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                <button
                  disabled={pageOcorr === 0}
                  onClick={() => setPageOcorr(p => p - 1)}
                  className="btn-outline"
                  style={{ minHeight: '36px', padding: '6px 14px', opacity: pageOcorr === 0 ? 0.4 : 1 }}
                >
                  Anterior
                </button>
                <span style={{ fontSize: '11px', color: P.textSub }}>
                  Pág. {pageOcorr + 1} de {totalPagesOcorr} · {ocorrFiltradas.length} registros
                </span>
                <button
                  disabled={pageOcorr >= totalPagesOcorr - 1}
                  onClick={() => setPageOcorr(p => p + 1)}
                  className="btn-outline"
                  style={{ minHeight: '36px', padding: '6px 14px', opacity: pageOcorr >= totalPagesOcorr - 1 ? 0.4 : 1 }}
                >
                  Próximo
                </button>
              </div>
            )}
          </div>
        </div>
      )}

    </div>
  )
}
