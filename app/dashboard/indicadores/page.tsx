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
type Aba = 'operacional' | 'financeiro' | 'pessoas' | 'frota' | 'qualidade' | 'clientes'

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
  veiculos: { abastecimento_valor: number | null; abastecimento_litros: number | null }[]
  efetivo_financeiro: { valor_pago_vigilante: number | null }[]
}

const PERFIS_FINANCEIRO_IND = ['administrador', 'gestor', 'supervisor']
interface ClienteOpt { id: string; nome_cliente: string }
interface AlertaSLA {
  id: string; codigo: string; cliente: string
  minutosEmCampo: number; minutosExcedidos: number
}
interface VigRanking { nome: string; total: number; escoltaIds: string[] }

interface CheckinsData { total: number; mediaPerEscolta: number; offlineCount: number; precisaoMedia: number | null }
interface EmergenciasData { total: number; abertas: number; encerradas: number; tempoMedioResolucaoMin: number | null }
interface PessoasData {
  totalEfetivo: number; confirmados: number; comPresenca: number
  porPapel: { comandante: number; operador: number }
  rankingRemuneracao: { nome: string; total: number; escalacoes: number }[]
}
interface FrotaDetalhe { placa: string; modelo: string | null; kmTotal: number; litros: number; custo: number; viagens: number }
interface FrotaGlobal {
  veiculosPorStatus: { ativo: number; inativo: number; manutencao: number }
  armamentosPorTipo: { tipo: string; qtd: number }[]
  armamentosAtivos: number; armamentosInativos: number
}
interface QualidadeData {
  total: number; concluidos: number; totalItens: number; conformes: number
  material: { total: number; conformes: number }
  viatura: { total: number; conformes: number }
  itensMaisReprovados: { descricao: string; total: number }[]
  tempoMedioMin: number | null
}
interface ClientesGlobal { ativos: number; inativos: number; comTelegram: number; semTelegram: number }

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

const MESES_ABREV = ['Jan', 'Fev', 'Mar', 'Abr', 'Mai', 'Jun', 'Jul', 'Ago', 'Set', 'Out', 'Nov', 'Dez']

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

  // Aba ativa
  const [abaAtiva, setAbaAtiva] = useState<Aba>('operacional')

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

  // Novos states
  const [volumeMensal, setVolumeMensal] = useState<{ label: string; total: number; finalizadas: number }[]>([])
  const [tempos, setTempos] = useState<{ media: number; menor: number; maior: number } | null>(null)
  const [rankingVigilantes, setRankingVigilantes] = useState<VigRanking[]>([])
  const [rankingVeiculos, setRankingVeiculos] = useState<{ placa: string; modelo: string | null; kmTotal: number; viagens: number }[]>([])

  // Estados das novas abas
  const [checkinsStats, setCheckinsStats] = useState<CheckinsData | null>(null)
  const [emergenciasStats, setEmergenciasStats] = useState<EmergenciasData | null>(null)
  const [pessoasStats, setPessoasStats] = useState<PessoasData | null>(null)
  const [frotaDetalhes, setFrotaDetalhes] = useState<FrotaDetalhe[]>([])
  const [frotaGlobal, setFrotaGlobal] = useState<FrotaGlobal | null>(null)
  const [qualidadeStats, setQualidadeStats] = useState<QualidadeData | null>(null)
  const [clientesGlobal, setClientesGlobal] = useState<ClientesGlobal | null>(null)
  const [ocorrTipos, setOcorrTipos] = useState<{ tipo: string; total: number }[]>([])

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

  // Carrega volume mensal (independente do filtro de período)
  useEffect(() => {
    const dozeAtras = new Date()
    dozeAtras.setMonth(dozeAtras.getMonth() - 11)
    dozeAtras.setDate(1)
    dozeAtras.setHours(0, 0, 0, 0)

    sb.from('escoltas')
      .select('data_hora_prevista, status')
      .gte('data_hora_prevista', dozeAtras.toISOString())
      .not('status', 'in', '(rascunho,cancelada)')
      .then(({ data }) => {
        const agora = new Date()
        const meses: { label: string; total: number; finalizadas: number }[] = []
        for (let i = 11; i >= 0; i--) {
          const d = new Date(agora.getFullYear(), agora.getMonth() - i, 1)
          meses.push({ label: `${MESES_ABREV[d.getMonth()]}/${String(d.getFullYear()).slice(2)}`, total: 0, finalizadas: 0 })
        }
        ;(data ?? []).forEach((e: any) => {
          const d = new Date(e.data_hora_prevista)
          const diffMes = (agora.getFullYear() - d.getFullYear()) * 12 + (agora.getMonth() - d.getMonth())
          if (diffMes >= 0 && diffMes <= 11) {
            const idx = 11 - diffMes
            meses[idx].total++
            if (e.status === 'finalizada') meses[idx].finalizadas++
          }
        })
        setVolumeMensal(meses)
      })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Frota global (period-independent)
  useEffect(() => {
    Promise.all([
      sb.from('veiculos').select('id, status'),
      sb.from('armamentos').select('id, status, tipo:dom_tipos_armamento(nome)'),
    ]).then(([{ data: veics }, { data: arms }]) => {
      const vsArr = (veics ?? []) as any[]
      const armsArr = (arms ?? []) as any[]
      const armTipos: Record<string, number> = {}
      armsArr.forEach((a: any) => {
        const tipo = (a.tipo as any)?.nome ?? 'Outros'
        armTipos[tipo] = (armTipos[tipo] ?? 0) + 1
      })
      setFrotaGlobal({
        veiculosPorStatus: {
          ativo: vsArr.filter(v => v.status === 'ativo').length,
          inativo: vsArr.filter(v => v.status === 'inativo').length,
          manutencao: vsArr.filter(v => v.status === 'manutencao').length,
        },
        armamentosPorTipo: Object.entries(armTipos).map(([tipo, qtd]) => ({ tipo, qtd })).sort((a, b) => b.qtd - a.qtd),
        armamentosAtivos: armsArr.filter((a: any) => a.status === 'ativo').length,
        armamentosInativos: armsArr.filter((a: any) => a.status === 'inativo').length,
      })
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Clientes global (period-independent)
  useEffect(() => {
    sb.from('clientes').select('id, status, telegram_chat_id').then(({ data }) => {
      const arr = (data ?? []) as any[]
      setClientesGlobal({
        ativos: arr.filter(c => c.status === 'ativo').length,
        inativos: arr.filter(c => c.status === 'inativo').length,
        comTelegram: arr.filter(c => c.telegram_chat_id).length,
        semTelegram: arr.filter(c => !c.telegram_chat_id).length,
      })
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const carregar = useCallback(async () => {
    setLoading(true)
    setTempos(null)
    setRankingVigilantes([])
    setRankingVeiculos([])
    setCheckinsStats(null)
    setEmergenciasStats(null)
    setPessoasStats(null)
    setFrotaDetalhes([])
    setQualidadeStats(null)
    setOcorrTipos([])

    const { from, to } = computeRange(tipoPeriodo, dataInicio, dataFim)

    let q = sb.from('escoltas').select(`
      id, codigo_escolta, status, data_hora_prevista, data_finalizacao,
      origem_endereco, destino_endereco, valor_cobrado, outros_custos,
      cliente:clientes(nome_cliente, cor_destaque),
      veiculos:escolta_veiculos(abastecimento_valor, abastecimento_litros),
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

    if (rows.length > 0) {
      const rowIds = rows.map((e: any) => e.id)
      const escoltasFinalizadasIds = rows.filter(e => e.status === 'finalizada').map(e => e.id)

      const [{ data: efetivos }, { data: escVeicsAll }, { data: escVeics }] = await Promise.all([
        sb.from('escolta_efetivo')
          .select('vigilante_id, vigilante:vigilantes(nome_completo), escolta_id, confirmado, papel_na_escolta, valor_pago_vigilante')
          .in('escolta_id', rowIds),
        sb.from('escolta_veiculos')
          .select('id, veiculo_id, veiculo:veiculos(placa, modelo), quilometragem_saida, quilometragem_retorno, abastecimento_litros, abastecimento_valor, escolta_id')
          .in('escolta_id', rowIds),
        sb.from('escolta_veiculos')
          .select('veiculo_id, veiculo:veiculos(placa, modelo), quilometragem_saida, quilometragem_retorno, escolta_id')
          .in('escolta_id', rowIds)
          .not('quilometragem_retorno', 'is', null)
          .not('quilometragem_saida', 'is', null),
      ])

      // Ranking de vigilantes
      const vigMap: Record<string, VigRanking> = {}
      ;(efetivos ?? []).forEach((ef: any) => {
        const vid = ef.vigilante_id
        if (!vid) return
        const nome = (ef.vigilante as any)?.nome_completo ?? 'Desconhecido'
        if (!vigMap[vid]) vigMap[vid] = { nome, total: 0, escoltaIds: [] }
        vigMap[vid].total++
        vigMap[vid].escoltaIds.push(ef.escolta_id)
      })
      setRankingVigilantes(Object.values(vigMap).sort((a, b) => b.total - a.total).slice(0, 5))

      // Ranking de veículos por KM
      const veicMap: Record<string, { placa: string; modelo: string | null; kmTotal: number; viagens: number }> = {}
      ;(escVeics ?? []).forEach((ev: any) => {
        const vid = ev.veiculo_id
        if (!vid) return
        const km = (ev.quilometragem_retorno ?? 0) - (ev.quilometragem_saida ?? 0)
        if (km <= 0) return
        const placa = (ev.veiculo as any)?.placa ?? '—'
        const modelo = (ev.veiculo as any)?.modelo ?? null
        if (!veicMap[vid]) veicMap[vid] = { placa, modelo, kmTotal: 0, viagens: 0 }
        veicMap[vid].kmTotal += km
        veicMap[vid].viagens++
      })
      setRankingVeiculos(Object.values(veicMap).sort((a, b) => b.kmTotal - a.kmTotal).slice(0, 5))

      // Frota detalhes (todos veículos, com litros/custo)
      const veicMapFrota: Record<string, FrotaDetalhe> = {}
      ;(escVeicsAll ?? []).forEach((ev: any) => {
        const vid = ev.veiculo_id; if (!vid) return
        const km = (ev.quilometragem_retorno ?? 0) - (ev.quilometragem_saida ?? 0)
        const placa = (ev.veiculo as any)?.placa ?? '—'
        const modelo = (ev.veiculo as any)?.modelo ?? null
        if (!veicMapFrota[vid]) veicMapFrota[vid] = { placa, modelo, kmTotal: 0, litros: 0, custo: 0, viagens: 0 }
        if (km > 0) { veicMapFrota[vid].kmTotal += km; veicMapFrota[vid].viagens++ }
        veicMapFrota[vid].litros += ev.abastecimento_litros ?? 0
        veicMapFrota[vid].custo += ev.abastecimento_valor ?? 0
      })
      setFrotaDetalhes(Object.values(veicMapFrota).sort((a, b) => b.kmTotal - a.kmTotal))

      // IDs de escolta_veiculos para queries de pontos/checklists
      const escoltaVeiculoIds = (escVeicsAll ?? []).map((ev: any) => ev.id as string)

      // Segunda bateria de queries (operacional/qualidade/pessoas)
      const [{ data: pontosData }, { data: emergData }, { data: presData }, { data: clkData }, { data: ocorrTipoData }] = await Promise.all([
        escoltaVeiculoIds.length > 0
          ? sb.from('pontos_controle').select('id, criado_offline, precisao_metros, escolta_veiculo_id').in('escolta_veiculo_id', escoltaVeiculoIds)
          : Promise.resolve({ data: [] as any[] }),
        sb.from('emergencias').select('id, status, data_hora, atualizado_em').in('escolta_id', rowIds),
        sb.from('presencas').select('vigilante_id, escolta_id').in('escolta_id', rowIds),
        escoltaVeiculoIds.length > 0
          ? sb.from('checklists').select('id, concluido, data_inicio, data_conclusao, tipo, checklist_respostas(conforme, descricao_item)').in('escolta_veiculo_id', escoltaVeiculoIds)
          : Promise.resolve({ data: [] as any[] }),
        sb.from('ocorrencias').select('id, tipo:dom_tipos_ocorrencia(nome)').gte('data_hora', from).lte('data_hora', to),
      ])

      // Check-ins stats
      const pontos = (pontosData ?? []) as any[]
      const evIdsComPontos = [...new Set(pontos.map((p: any) => p.escolta_veiculo_id))]
      setCheckinsStats({
        total: pontos.length,
        mediaPerEscolta: evIdsComPontos.length > 0 ? Math.round(pontos.length / evIdsComPontos.length) : 0,
        offlineCount: pontos.filter((p: any) => p.criado_offline).length,
        precisaoMedia: pontos.filter((p: any) => p.precisao_metros).length > 0
          ? Math.round(pontos.filter((p: any) => p.precisao_metros).reduce((s: number, p: any) => s + Number(p.precisao_metros), 0) / pontos.filter((p: any) => p.precisao_metros).length)
          : null,
      })

      // Emergências stats
      const emergs = (emergData ?? []) as any[]
      const emergEncerradas = emergs.filter((e: any) => e.status === 'encerrada')
      const temposEncerr = emergEncerradas
        .filter((e: any) => e.data_hora && e.atualizado_em)
        .map((e: any) => new Date(e.atualizado_em).getTime() - new Date(e.data_hora).getTime())
        .filter((t: number) => t > 0)
      setEmergenciasStats({
        total: emergs.length,
        abertas: emergs.filter((e: any) => e.status !== 'encerrada').length,
        encerradas: emergEncerradas.length,
        tempoMedioResolucaoMin: temposEncerr.length > 0
          ? Math.round(temposEncerr.reduce((s: number, t: number) => s + t, 0) / temposEncerr.length / 60000)
          : null,
      })

      // Pessoas stats
      const presArr = (presData ?? []) as any[]
      const vigilantesComPresenca = new Set(presArr.map((p: any) => p.vigilante_id))
      const efetivosArr = (efetivos ?? []) as any[]
      const remunMap: Record<string, { nome: string; total: number; escalacoes: number }> = {}
      efetivosArr.forEach((ef: any) => {
        const vid = ef.vigilante_id; if (!vid) return
        const nome = (ef.vigilante as any)?.nome_completo ?? 'Desconhecido'
        if (!remunMap[vid]) remunMap[vid] = { nome, total: 0, escalacoes: 0 }
        remunMap[vid].total += ef.valor_pago_vigilante ?? 0
        remunMap[vid].escalacoes++
      })
      setPessoasStats({
        totalEfetivo: efetivosArr.length,
        confirmados: efetivosArr.filter((ef: any) => ef.confirmado).length,
        comPresenca: efetivosArr.filter((ef: any) => vigilantesComPresenca.has(ef.vigilante_id)).length,
        porPapel: {
          comandante: efetivosArr.filter((ef: any) => ef.papel_na_escolta === 'comandante').length,
          operador: efetivosArr.filter((ef: any) => ef.papel_na_escolta === 'operador').length,
        },
        rankingRemuneracao: Object.values(remunMap).sort((a, b) => b.total - a.total).slice(0, 5),
      })

      // Qualidade stats
      const clks = (clkData ?? []) as any[]
      let qTotalItens = 0, qConformes = 0, qMatTotal = 0, qMatConf = 0, qViatTotal = 0, qViatConf = 0
      const repMap: Record<string, number> = {}
      const temposClk: number[] = []
      clks.forEach((c: any) => {
        if (c.data_inicio && c.data_conclusao) {
          const t = new Date(c.data_conclusao).getTime() - new Date(c.data_inicio).getTime()
          if (t > 0) temposClk.push(t)
        }
        ;(c.checklist_respostas ?? []).forEach((r: any) => {
          qTotalItens++
          if (c.tipo === 'material') qMatTotal++; else qViatTotal++
          if (r.conforme) { qConformes++; if (c.tipo === 'material') qMatConf++; else qViatConf++ }
          else { const d = r.descricao_item ?? '—'; repMap[d] = (repMap[d] ?? 0) + 1 }
        })
      })
      setQualidadeStats({
        total: clks.length, concluidos: clks.filter((c: any) => c.concluido).length,
        totalItens: qTotalItens, conformes: qConformes,
        material: { total: qMatTotal, conformes: qMatConf },
        viatura: { total: qViatTotal, conformes: qViatConf },
        itensMaisReprovados: Object.entries(repMap).map(([descricao, total]) => ({ descricao, total })).sort((a, b) => b.total - a.total).slice(0, 5),
        tempoMedioMin: temposClk.length > 0 ? Math.round(temposClk.reduce((s, t) => s + t, 0) / temposClk.length / 60000) : null,
      })

      // Ocorrências por tipo
      const ocorrMap: Record<string, number> = {}
      ;(ocorrTipoData ?? []).forEach((o: any) => {
        const tipo = (o.tipo as any)?.nome ?? 'Outros'
        ocorrMap[tipo] = (ocorrMap[tipo] ?? 0) + 1
      })
      setOcorrTipos(Object.entries(ocorrMap).map(([tipo, total]) => ({ tipo, total })).sort((a, b) => b.total - a.total))

      // Tempo médio de escolta
      if (escoltasFinalizadasIds.length > 0) {
        const { data: histStatus } = await sb.from('escolta_status_historico')
          .select('escolta_id, status_novo, data_hora')
          .in('escolta_id', escoltasFinalizadasIds)
          .in('status_novo', ['em_andamento', 'finalizada'])

        if (histStatus && histStatus.length > 0) {
          const porEscolta: Record<string, { inicio?: number; fim?: number }> = {}
          ;(histStatus as any[]).forEach(h => {
            if (!porEscolta[h.escolta_id]) porEscolta[h.escolta_id] = {}
            const ts = new Date(h.data_hora).getTime()
            if (h.status_novo === 'em_andamento') {
              if (!porEscolta[h.escolta_id].inicio || ts < porEscolta[h.escolta_id].inicio!) {
                porEscolta[h.escolta_id].inicio = ts
              }
            }
            if (h.status_novo === 'finalizada') {
              if (!porEscolta[h.escolta_id].fim || ts > porEscolta[h.escolta_id].fim!) {
                porEscolta[h.escolta_id].fim = ts
              }
            }
          })

          const duracoes: number[] = Object.values(porEscolta)
            .filter(d => d.inicio && d.fim && d.fim > d.inicio)
            .map(d => Math.round((d.fim! - d.inicio!) / 60000))

          if (duracoes.length > 0) {
            const media = Math.round(duracoes.reduce((s, v) => s + v, 0) / duracoes.length)
            const menor = Math.min(...duracoes)
            const maior = Math.max(...duracoes)
            setTempos({ media, menor, maior })
          }
        }
      }
    }

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

  // Financeiro por cliente
  const finPorCliente = Object.values(
    escoltasConcluidas.reduce((acc, e) => {
      const nome = e.cliente?.nome_cliente ?? 'Sem cliente'
      const cor  = e.cliente?.cor_destaque ?? P.steel
      if (!acc[nome]) acc[nome] = { nome, cor, total: 0, receita: 0, custo: 0 }
      acc[nome].total++
      acc[nome].receita += e.valor_cobrado ?? 0
      const cp = e.efetivo_financeiro.reduce((s, ef) => s + (ef.valor_pago_vigilante ?? 0), 0)
      const cc = e.veiculos.reduce((s, v) => s + (v.abastecimento_valor ?? 0), 0)
      acc[nome].custo += cp + cc + (e.outros_custos ?? 0)
      return acc
    }, {} as Record<string, { nome: string; cor: string; total: number; receita: number; custo: number }>)
  ).map(r => ({ ...r, margem: r.receita - r.custo, margemPct: r.receita > 0 ? ((r.receita - r.custo) / r.receita) * 100 : null }))
    .sort((a, b) => b.receita - a.receita)

  // Frota totais do período
  const litrosTotalPeriodo = escoltas.reduce((s, e) => s + e.veiculos.reduce((ss, v) => ss + (v.abastecimento_litros ?? 0), 0), 0)
  const custoCombuPeriodo  = escoltas.reduce((s, e) => s + e.veiculos.reduce((ss, v) => ss + (v.abastecimento_valor ?? 0), 0), 0)
  const kmTotalPeriodo     = frotaDetalhes.reduce((s, v) => s + v.kmTotal, 0)

  // Qualidade rates
  const taxaConclusaoClk = qualidadeStats && qualidadeStats.total > 0
    ? Math.round((qualidadeStats.concluidos / qualidadeStats.total) * 100) : null
  const taxaConformidade = qualidadeStats && qualidadeStats.totalItens > 0
    ? Math.round((qualidadeStats.conformes / qualidadeStats.totalItens) * 100) : null

  // Pessoas rates
  const taxaConfirmacao = pessoasStats && pessoasStats.totalEfetivo > 0
    ? Math.round((pessoasStats.confirmados / pessoasStats.totalEfetivo) * 100) : null
  const taxaPresenca = pessoasStats && pessoasStats.totalEfetivo > 0
    ? Math.round((pessoasStats.comPresenca / pessoasStats.totalEfetivo) * 100) : null

  const now = new Date()
  const mesLabel = now.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' })
  const nomeCliente = clientes.find(c => c.id === clienteFiltroId)?.nome_cliente

  const maxVolumeMensal = Math.max(...volumeMensal.map(m => m.total), 1)

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
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:flex-wrap">
        <div>
          <div className="eyebrow-tag mb-2">
            <BarChart2 size={10} />
            Centro de Análise Operacional
          </div>
          <h1 className="page-title">Indicadores</h1>
          <p className="page-subtitle flex items-center gap-1.5 flex-wrap">
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
          className="flex items-center justify-center gap-2 px-4 py-2 transition-all text-xs font-bold uppercase tracking-wider disabled:opacity-40 w-full sm:w-auto"
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
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3 pt-1">
            <div className="flex items-center gap-2">
              <label className="text-[10px] font-black uppercase tracking-widest shrink-0" style={{ color: P.textSub }}>De</label>
              <input type="date" value={dataInicio} onChange={e => setDataInicio(e.target.value)}
                className="px-2 py-1.5 text-xs w-full sm:w-auto"
                style={{ border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
            </div>
            <div className="flex items-center gap-2">
              <label className="text-[10px] font-black uppercase tracking-widest shrink-0" style={{ color: P.textSub }}>Até</label>
              <input type="date" value={dataFim} onChange={e => setDataFim(e.target.value)}
                className="px-2 py-1.5 text-xs w-full sm:w-auto"
                style={{ border: `1.5px solid ${P.border}`, borderRadius: '2px', color: P.text, outline: 'none' }} />
            </div>
          </div>
        )}

        {/* Filtro por cliente */}
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3 pt-1 border-t" style={{ borderColor: P.steelBg }}>
          <span className="text-[10px] font-black uppercase tracking-widest" style={{ color: P.textSub }}>Cliente</span>
          <div className="relative w-full sm:w-auto">
            <select
              value={clienteFiltroId}
              onChange={e => setClienteFiltroId(e.target.value)}
              className="appearance-none pr-8 pl-3 py-1.5 text-xs font-semibold w-full sm:w-auto"
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

      {/* ── Barra de Abas ── */}
      <div style={{ display: 'flex', borderBottom: `2px solid ${P.border}`, flexWrap: 'wrap', backgroundColor: '#fff', borderRadius: '2px 2px 0 0', gap: '0' }}>
        {([
          { key: 'operacional', label: 'Operacional' },
          { key: 'financeiro',  label: 'Financeiro',   hidden: !verFinanceiro },
          { key: 'pessoas',     label: 'Pessoas' },
          { key: 'frota',       label: 'Frota & Armas' },
          { key: 'qualidade',   label: 'Qualidade' },
          { key: 'clientes',    label: 'Clientes' },
        ] as { key: Aba; label: string; hidden?: boolean }[]).filter(t => !t.hidden).map(tab => (
          <button key={tab.key} onClick={() => setAbaAtiva(tab.key)}
            style={{
              padding: '11px 20px', fontSize: '11px', fontWeight: 700,
              textTransform: 'uppercase', letterSpacing: '0.08em',
              outline: 'none', cursor: 'pointer', background: 'none',
              borderTop: 'none', borderLeft: 'none', borderRight: 'none',
              borderBottom: abaAtiva === tab.key ? `3px solid ${P.navy}` : '3px solid transparent',
              color: abaAtiva === tab.key ? P.navy : P.textSub,
              marginBottom: '-2px',
            }}>
            {tab.label}
          </button>
        ))}
      </div>

      {/* ── ABA: OPERACIONAL ── */}
      {abaAtiva === 'operacional' && <>

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
            <div key={alerta.id} className="flex items-start gap-3 glow-amber"
              style={{ backgroundColor: P.alertBg, border: `1.5px solid ${P.alertBorder}`, borderRadius: '2px', padding: '12px 14px' }}>
              <div style={{ backgroundColor: P.alertIcon, borderRadius: '2px', padding: '8px', flexShrink: 0 }}>
                <Clock size={16} className="animate-pulse" style={{ color: '#fff' }} />
              </div>
              {/* Conteúdo clicável */}
              <button className="flex-1 min-w-0 text-left transition-all active:scale-[0.99]"
                onClick={() => router.push(`/dashboard/escoltas/${alerta.id}`)}>
                <p className="text-xs font-black uppercase tracking-widest" style={{ color: P.alertText }}>
                  Alerta SLA — {alerta.codigo} há {formatDuracao(alerta.minutosEmCampo)}
                </p>
                <p className="text-[11px] mt-0.5" style={{ color: P.alertSub }}>
                  Excedido em <strong>{formatDuracao(alerta.minutosExcedidos)}</strong> · {alerta.cliente}
                </p>
                <button onClick={() => router.push(`/dashboard/escoltas/${alerta.id}`)}
                  className="mt-2 flex items-center gap-1 sm:hidden"
                  style={{ backgroundColor: P.alertIcon, color: '#fff', borderRadius: '2px', padding: '5px 10px', fontSize: '10px', fontWeight: 900 }}>
                  Ver Escolta <ChevronRight size={11} />
                </button>
              </button>
              {/* Ver escolta (desktop) */}
              <button onClick={() => router.push(`/dashboard/escoltas/${alerta.id}`)}
                className="hidden sm:flex items-center gap-2 shrink-0 transition-opacity hover:opacity-80"
                style={{ backgroundColor: P.alertIcon, color: '#fff', borderRadius: '2px', padding: '6px 12px' }}>
                <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.08em' }}>Ver Escolta</span>
                <ChevronRight size={13} />
              </button>
              {/* Fechar alerta */}
              <button
                onClick={() => setAlertasFechados(prev => new Set([...prev, alerta.id]))}
                title="Fechar alerta"
                className="flex items-center justify-center shrink-0 transition-all hover:opacity-70"
                style={{ width: '36px', height: '36px', borderRadius: '2px', border: `1.5px solid ${P.alertBorder}`, color: P.alertText, backgroundColor: 'transparent' }}>
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

      {/* ── Check-ins + Emergências ── */}
      {(checkinsStats || emergenciasStats) && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          {[
            { label: 'Check-ins Realizados', valor: checkinsStats?.total ?? '—', sub: `média ${checkinsStats?.mediaPerEscolta ?? 0}/veículo`, cor: P.navy, corTop: P.steel },
            { label: 'Check-ins Offline',    valor: checkinsStats?.offlineCount ?? '—', sub: 'criados sem conexão', cor: checkinsStats?.offlineCount ? P.steel : P.light, corTop: P.light },
            { label: 'Emergências',          valor: emergenciasStats?.total ?? '—', sub: `${emergenciasStats?.abertas ?? 0} abertas · ${emergenciasStats?.encerradas ?? 0} encerradas`, cor: (emergenciasStats?.abertas ?? 0) > 0 ? P.errorText : P.navy, corTop: (emergenciasStats?.abertas ?? 0) > 0 ? P.errorText : P.light },
            { label: 'Tempo Médio Emergência', valor: emergenciasStats?.tempoMedioResolucaoMin != null ? formatDuracao(emergenciasStats.tempoMedioResolucaoMin) : '—', sub: 'tempo médio de encerramento', cor: P.navy, corTop: P.steel },
          ].map(k => (
            <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.corTop}` }}>
              <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
              <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{loading ? '—' : k.valor}</p>
              <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
            </div>
          ))}
        </div>
      )}

      {/* ── Ocorrências por Tipo ── */}
      {ocorrTipos.length > 0 && (
        <div style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '16px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '12px' }}>
            <div style={{ width: '5px', height: '5px', borderRadius: '1px', backgroundColor: P.steel }} />
            <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: P.textSub }}>Ocorrências por Tipo</p>
          </div>
          <div className="space-y-2">
            {ocorrTipos.map(o => (
              <div key={o.tipo} style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                <span style={{ fontSize: '11px', color: P.text, fontWeight: 600, minWidth: '160px' }}>{o.tipo}</span>
                <div style={{ flex: 1, height: '8px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
                  <div style={{ width: `${(o.total / (ocorrTipos[0]?.total || 1)) * 100}%`, height: '100%', backgroundColor: P.navy, borderRadius: '2px', transition: 'width 0.8s ease' }} />
                </div>
                <span style={{ fontSize: '11px', fontWeight: 900, color: P.navy, minWidth: '20px', textAlign: 'right' }}>{o.total}</span>
              </div>
            ))}
          </div>
        </div>
      )}


      {/* ── Volume Mensal ── */}
      <div className="card-light p-5">
        <div className="flex items-center justify-between mb-5">
          <SectionTitle icon={BarChart2} label="Volume Mensal — Últimos 12 Meses" />
        </div>
        {volumeMensal.length === 0 ? (
          <div className="animate-pulse" style={{ height: '160px', backgroundColor: P.steelBg, borderRadius: '2px' }} />
        ) : (
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: '6px', height: '160px', paddingBottom: '0' }}>
            {volumeMensal.map((m, idx) => {
              const pctTotal = maxVolumeMensal > 0 ? (m.total / maxVolumeMensal) * 100 : 0
              const pctFin   = m.total > 0 ? (m.finalizadas / m.total) * 100 : 0
              const barH     = Math.max(pctTotal * 1.2, m.total > 0 ? 6 : 0)
              return (
                <div key={m.label} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '4px', minWidth: 0 }}>
                  <span style={{ fontSize: '9px', fontWeight: 900, color: m.total > 0 ? P.text : P.light, lineHeight: 1 }}>{m.total > 0 ? m.total : ''}</span>
                  <div style={{ width: '100%', height: '120px', display: 'flex', alignItems: 'flex-end', position: 'relative' }}>
                    <div style={{ width: '100%', height: `${pctTotal}%`, backgroundColor: P.navyBg, borderRadius: '2px 2px 0 0', position: 'relative', overflow: 'hidden', minHeight: m.total > 0 ? '4px' : '0' }}>
                      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, height: `${pctFin}%`, backgroundColor: P.navy, borderRadius: '2px 2px 0 0', transition: 'height 0.8s ease' }} />
                      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, top: 0, backgroundColor: P.steel, opacity: 0.18 }} />
                    </div>
                  </div>
                  <span style={{ fontSize: '8px', fontWeight: 700, color: P.textSub, textAlign: 'center', lineHeight: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', maxWidth: '100%' }}>{m.label}</span>
                </div>
              )
            })}
          </div>
        )}
        {volumeMensal.length > 0 && (
          <div style={{ display: 'flex', gap: '14px', marginTop: '10px', flexWrap: 'wrap' }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: '4px', fontSize: '10px', color: P.textSub }}>
              <span style={{ display: 'inline-block', width: '8px', height: '8px', borderRadius: '2px', backgroundColor: P.navy }} />
              Finalizadas
            </span>
            <span style={{ display: 'flex', alignItems: 'center', gap: '4px', fontSize: '10px', color: P.textSub }}>
              <span style={{ display: 'inline-block', width: '8px', height: '8px', borderRadius: '2px', backgroundColor: P.navyBg, border: `1px solid ${P.border}` }} />
              Demais status
            </span>
          </div>
        )}
      </div>

      {/* ── Linha 2: Clientes + Resumo + Tempo Médio ── */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-4">

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

          {/* Ranking de Vigilantes */}
          {rankingVigilantes.length > 0 && (
            <div style={{ marginTop: '20px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '6px', marginBottom: '10px' }}>
                <div style={{ width: '4px', height: '4px', borderRadius: '1px', backgroundColor: P.steel, flexShrink: 0 }} />
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: P.textSub }}>Top 5 Vigilantes</p>
              </div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                <thead>
                  <tr style={{ borderBottom: `1px solid ${P.border}` }}>
                    {['#', 'Nome', 'Escoltas'].map(h => (
                      <th key={h} style={{ textAlign: h === 'Escoltas' ? 'right' : 'left', padding: '3px 6px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {rankingVigilantes.map((v, idx) => (
                    <tr key={v.nome} style={{ borderBottom: `1px solid ${P.steelBg}` }}>
                      <td style={{ padding: '4px 6px', color: P.light, fontWeight: 900, fontSize: '10px' }}>{idx + 1}</td>
                      <td style={{ padding: '4px 6px', color: P.text, fontWeight: 600 }}>{v.nome}</td>
                      <td style={{ padding: '4px 6px', color: P.navy, fontWeight: 900, textAlign: 'right' }}>{v.total}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {/* Ranking de Veículos */}
          {rankingVeiculos.length > 0 && (
            <div style={{ marginTop: '20px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '6px', marginBottom: '10px' }}>
                <div style={{ width: '4px', height: '4px', borderRadius: '1px', backgroundColor: P.steel, flexShrink: 0 }} />
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: P.textSub }}>Top 5 Veículos por KM</p>
              </div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                <thead>
                  <tr style={{ borderBottom: `1px solid ${P.border}` }}>
                    {['#', 'Placa', 'KM', 'Viagens'].map(h => (
                      <th key={h} style={{ textAlign: h === '#' || h === 'Placa' ? 'left' : 'right', padding: '3px 6px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>{h}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {rankingVeiculos.map((v, idx) => (
                    <tr key={v.placa} style={{ borderBottom: `1px solid ${P.steelBg}` }}>
                      <td style={{ padding: '4px 6px', color: P.light, fontWeight: 900, fontSize: '10px' }}>{idx + 1}</td>
                      <td style={{ padding: '4px 6px' }}>
                        <div>
                          <span style={{ color: P.text, fontWeight: 700, fontFamily: 'monospace' }}>{v.placa}</span>
                          {v.modelo && <span style={{ display: 'block', fontSize: '9px', color: P.light }}>{v.modelo}</span>}
                        </div>
                      </td>
                      <td style={{ padding: '4px 6px', color: P.navy, fontWeight: 900, textAlign: 'right' }}>{v.kmTotal.toLocaleString('pt-BR')}</td>
                      <td style={{ padding: '4px 6px', color: P.textSub, fontWeight: 700, textAlign: 'right' }}>{v.viagens}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
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

        {/* Tempo Médio de Escolta */}
        <div className="card-light p-5 animate-in fade-in slide-in-from-right-4" style={{ animationDuration: '600ms', animationDelay: '80ms', animationFillMode: 'both' }}>
          <div className="mb-5">
            <SectionTitle icon={Clock} label="Tempo de Escolta" />
          </div>
          {loading ? (
            <div className="space-y-3">{[1,2,3].map(i => (
              <div key={i} className="animate-pulse h-14" style={{ backgroundColor: P.steelBg, borderRadius: '2px' }} />
            ))}</div>
          ) : tempos === null ? (
            <p className="text-xs text-center py-8" style={{ color: P.light }}>Sem dados de duração no período</p>
          ) : (
            <div className="space-y-3">
              {[
                { label: 'Tempo Médio', valor: formatDuracao(tempos.media), cor: P.navy, bg: P.navyBg },
                { label: 'Menor Tempo', valor: formatDuracao(tempos.menor), cor: P.steel, bg: P.steelBg },
                { label: 'Maior Tempo', valor: formatDuracao(tempos.maior), cor: P.textSub, bg: P.bg },
              ].map(t => (
                <div key={t.label} style={{ backgroundColor: t.bg, borderRadius: '2px', padding: '12px 14px', border: `1px solid ${P.border}` }}>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '4px' }}>{t.label}</p>
                  <p style={{ fontSize: '22px', fontWeight: 900, color: t.cor, lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{t.valor}</p>
                </div>
              ))}
            </div>
          )}
          {!loading && tempos !== null && (
            <div className="mt-4 p-3 flex items-start gap-2" style={{ backgroundColor: P.steelBg, borderRadius: '2px' }}>
              <Info size={12} style={{ color: P.steel, flexShrink: 0, marginTop: '1px' }} />
              <p style={{ fontSize: '10px', color: P.textSub, lineHeight: 1.5 }}>
                Calculado com base nas escoltas com status <strong style={{ color: P.navy }}>finalizadas</strong> no período, a partir do registro de histórico de status.
              </p>
            </div>
          )}
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
          <>
            {/* Desktop table */}
            <div className="hidden md:block overflow-x-auto">
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

            {/* Mobile cards */}
            <div className="md:hidden space-y-2 p-3">
              {escoltas.slice(0, 20).map(e => {
                const isSla = alertasSLA.some(a => a.id === e.id)
                return (
                  <button key={e.id}
                    onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                    className="w-full text-left rounded-lg p-3 border transition-all active:scale-[0.99]"
                    style={{ borderColor: isSla ? P.alertBorder : P.border, backgroundColor: isSla ? P.alertBg : '#fff' }}>
                    <div className="flex items-center justify-between mb-1.5">
                      <div className="flex items-center gap-1.5">
                        {isSla && <span style={{ fontSize: '9px', color: P.alertIcon }}>⚠</span>}
                        <span className="font-mono text-sm font-bold" style={{ color: P.text }}>{e.codigo_escolta}</span>
                      </div>
                      <span className={STATUS_BADGE[e.status] ?? 'badge-neutral'}>{STATUS_LABEL[e.status] ?? e.status}</span>
                    </div>
                    <div className="flex items-center gap-1.5 mb-1">
                      {e.cliente?.cor_destaque && <div style={{ width: '6px', height: '6px', backgroundColor: e.cliente.cor_destaque, borderRadius: '2px', flexShrink: 0 }} />}
                      <span className="text-xs font-medium" style={{ color: P.text }}>{e.cliente?.nome_cliente ?? '—'}</span>
                    </div>
                    <p className="text-[11px] truncate" style={{ color: P.textSub }}>
                      {e.origem_endereco ? e.origem_endereco.split(',').slice(0, 2).join(',') : '—'}
                    </p>
                    <p className="text-[11px] mt-0.5" style={{ color: P.light }}>
                      {new Date(e.data_hora_prevista).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })}
                    </p>
                  </button>
                )
              })}
            </div>
          </>
        )}
      </div>

      </> /* fim ABA OPERACIONAL */}

      {/* ── ABA: FINANCEIRO ── */}
      {abaAtiva === 'financeiro' && verFinanceiro && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: 'Receita Total',    value: loading ? '—' : fmtBRL(receitaTotal),  color: receitaTotal > 0 ? '#1E7C52' : P.light, sub: `${escoltasConcluidas.length} escolta(s) concluída(s)` },
              { label: 'Custo Total',      value: loading ? '—' : fmtBRL(custoTotal),    color: custoTotal > 0 ? '#B83832' : P.light,    sub: 'Pessoal + combustível + outros' },
              { label: 'Margem Bruta',     value: loading ? '—' : fmtBRL(margemBruta),   color: margemBruta >= 0 ? '#1E7C52' : '#B83832', sub: txMargem != null ? `${txMargem.toFixed(1)}% da receita` : 'Sem receita' },
              { label: 'Custo de Pessoal', value: loading ? '—' : fmtBRL(custoPessoal),  color: '#B83832',                                sub: `+ ${fmtBRL(custoCombustivel)} combustível` },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.color}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
                <p style={{ fontSize: '18px', fontWeight: 900, color: k.color, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{k.value}</p>
                <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
              </div>
            ))}
          </div>
          {receitaTotal > 0 && !loading && (
            <div style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '16px' }}>
              <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '10px' }}>Composição dos Custos sobre Receita</p>
              <div style={{ display: 'flex', height: '10px', borderRadius: '2px', overflow: 'hidden', backgroundColor: P.steelBg }}>
                <div title={`Pessoal: ${fmtBRL(custoPessoal)}`}       style={{ width: `${Math.min((custoPessoal/receitaTotal)*100,100)}%`,       backgroundColor: '#B83832' }} />
                <div title={`Combustível: ${fmtBRL(custoCombustivel)}`} style={{ width: `${Math.min((custoCombustivel/receitaTotal)*100,100)}%`,   backgroundColor: '#D97706' }} />
                <div title={`Outros: ${fmtBRL(outrosCustsTotal)}`}     style={{ width: `${Math.min((outrosCustsTotal/receitaTotal)*100,100)}%`,    backgroundColor: P.light  }} />
                {margemBruta > 0 && <div title={`Margem: ${fmtBRL(margemBruta)}`} style={{ flex: 1, backgroundColor: '#1E7C52' }} />}
              </div>
              <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', marginTop: '8px' }}>
                {[{ l: 'Pessoal', v: custoPessoal, c: '#B83832' }, { l: 'Combustível', v: custoCombustivel, c: '#D97706' }, { l: 'Outros', v: outrosCustsTotal, c: P.light }, { l: 'Margem', v: margemBruta, c: '#1E7C52' }].map(i => (
                  <span key={i.l} style={{ display: 'flex', alignItems: 'center', gap: '4px', fontSize: '10px', color: P.textSub }}>
                    <span style={{ display: 'inline-block', width: '8px', height: '8px', borderRadius: '2px', backgroundColor: i.c }} />
                    {i.l}: <strong style={{ color: P.text }}>{fmtBRL(i.v)}</strong>
                  </span>
                ))}
              </div>
            </div>
          )}
          {finPorCliente.length > 0 && (
            <div style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '16px' }}>
              <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '10px' }}>Financeiro por Cliente</p>
              <div style={{ overflowX: 'auto' }}>
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                  <thead>
                    <tr style={{ borderBottom: `1px solid ${P.border}` }}>
                      {['Cliente', 'Escoltas', 'Receita', 'Custo', 'Margem', 'Margem %'].map(h => (
                        <th key={h} style={{ textAlign: 'left', padding: '4px 8px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.textSub, whiteSpace: 'nowrap' }}>{h}</th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {finPorCliente.map((r, idx) => (
                      <tr key={r.nome} style={{ borderBottom: `1px solid ${P.steelBg}`, backgroundColor: idx % 2 === 0 ? '#fff' : P.bg }}>
                        <td style={{ padding: '5px 8px', whiteSpace: 'nowrap' }}>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                            <div style={{ width: '7px', height: '7px', backgroundColor: r.cor, borderRadius: '2px', flexShrink: 0 }} />
                            <span style={{ color: P.text, fontWeight: 600 }}>{r.nome}</span>
                          </div>
                        </td>
                        <td style={{ padding: '5px 8px', color: P.textSub, fontWeight: 700, textAlign: 'right' }}>{r.total}</td>
                        <td style={{ padding: '5px 8px', color: '#1E7C52', fontWeight: 700, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.receita)}</td>
                        <td style={{ padding: '5px 8px', color: P.errorText, fontWeight: 700, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.custo)}</td>
                        <td style={{ padding: '5px 8px', color: r.margem >= 0 ? '#1E7C52' : P.errorText, fontWeight: 700, whiteSpace: 'nowrap', fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.margem)}</td>
                        <td style={{ padding: '5px 8px', whiteSpace: 'nowrap' }}>
                          <span style={{ fontSize: '10px', fontWeight: 900, color: r.margemPct != null ? (r.margemPct >= 0 ? '#1E7C52' : P.errorText) : P.light }}>
                            {r.margemPct != null ? `${r.margemPct.toFixed(1)}%` : '—'}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
          {escoltasConcluidas.length === 0 && !loading && (
            <p style={{ textAlign: 'center', color: P.light, fontSize: '13px', padding: '40px' }}>Sem escoltas concluídas no período</p>
          )}
        </div>
      )}

      {/* ── ABA: PESSOAS ── */}
      {abaAtiva === 'pessoas' && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 md:grid-cols-3 xl:grid-cols-6 gap-3">
            {[
              { label: 'Total Efetivo',    valor: pessoasStats?.totalEfetivo ?? '—',    sub: 'escalações no período',                                   cor: P.navy,      corTop: P.navy    },
              { label: 'Confirmados',      valor: pessoasStats?.confirmados ?? '—',      sub: `${taxaConfirmacao ?? '—'}% de confirmação`,                cor: '#1E7C52',   corTop: '#1E7C52' },
              { label: 'Taxa Confirmação', valor: taxaConfirmacao != null ? `${taxaConfirmacao}%` : '—', sub: 'efetivo confirmado',                      cor: taxaConfirmacao != null && taxaConfirmacao >= 80 ? '#1E7C52' : '#B83832', corTop: taxaConfirmacao != null && taxaConfirmacao >= 80 ? '#1E7C52' : '#B83832' },
              { label: 'Com Presença',     valor: pessoasStats?.comPresenca ?? '—',      sub: `${taxaPresenca ?? '—'}% do efetivo`,                      cor: P.steel,     corTop: P.steel   },
              { label: 'Comandantes',      valor: pessoasStats?.porPapel.comandante ?? '—', sub: 'papel: comandante',                                    cor: P.navy,      corTop: P.navy    },
              { label: 'Operadores',       valor: pessoasStats?.porPapel.operador ?? '—',   sub: 'papel: operador',                                     cor: P.steel,     corTop: P.steel   },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '16px', borderTop: `3px solid ${k.corTop}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '8px' }}>{k.label}</p>
                <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{loading ? '—' : k.valor}</p>
              </div>
            ))}
          </div>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div className="card-light p-5">
              <SectionTitle icon={Users} label="Distribuição de Papéis" />
              <div className="mt-4 space-y-4">
                {pessoasStats ? (() => {
                  const total = pessoasStats.porPapel.comandante + pessoasStats.porPapel.operador
                  return [
                    { label: 'Comandantes', valor: pessoasStats.porPapel.comandante, cor: P.navy },
                    { label: 'Operadores',  valor: pessoasStats.porPapel.operador,   cor: P.steel },
                  ].map(r => (
                    <div key={r.label}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <span style={{ fontSize: '12px', fontWeight: 600, color: P.text }}>{r.label}</span>
                        <span style={{ fontSize: '12px', fontWeight: 900, color: r.cor }}>{r.valor} <span style={{ color: P.light, fontWeight: 400 }}>({total > 0 ? Math.round(r.valor/total*100) : 0}%)</span></span>
                      </div>
                      <MiniBar pct={total > 0 ? (r.valor/total)*100 : 0} />
                    </div>
                  ))
                })() : <p style={{ fontSize: '11px', color: P.light, textAlign: 'center', padding: '20px' }}>Sem dados no período</p>}
                {pessoasStats && (
                  <div style={{ marginTop: '12px', padding: '10px', backgroundColor: P.steelBg, borderRadius: '2px' }}>
                    <p style={{ fontSize: '10px', color: P.textSub }}>
                      <strong style={{ color: P.navy }}>Confirmados:</strong> {pessoasStats.confirmados}/{pessoasStats.totalEfetivo}
                      {' · '}
                      <strong style={{ color: P.navy }}>Com Presença:</strong> {pessoasStats.comPresenca}/{pessoasStats.totalEfetivo}
                    </p>
                  </div>
                )}
              </div>
            </div>
            <div className="card-light p-5">
              <SectionTitle icon={Users} label="Top Vigilantes" />
              <div className="mt-4">
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '8px' }}>Por Escalações</p>
                {rankingVigilantes.length > 0 ? (
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                    <thead><tr style={{ borderBottom: `1px solid ${P.border}` }}>
                      {['#', 'Nome', 'Esc.'].map(h => (<th key={h} style={{ textAlign: h === 'Esc.' ? 'right' : 'left', padding: '3px 6px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>{h}</th>))}
                    </tr></thead>
                    <tbody>{rankingVigilantes.map((v, idx) => (
                      <tr key={v.nome} style={{ borderBottom: `1px solid ${P.steelBg}` }}>
                        <td style={{ padding: '4px 6px', color: P.light, fontWeight: 900, fontSize: '10px' }}>{idx + 1}</td>
                        <td style={{ padding: '4px 6px', color: P.text, fontWeight: 600 }}>{v.nome}</td>
                        <td style={{ padding: '4px 6px', color: P.navy, fontWeight: 900, textAlign: 'right' }}>{v.total}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                ) : <p style={{ fontSize: '11px', color: P.light }}>Sem dados</p>}
                {pessoasStats?.rankingRemuneracao.some(r => r.total > 0) && (
                  <div style={{ marginTop: '16px' }}>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '8px' }}>Por Remuneração</p>
                    <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                      <thead><tr style={{ borderBottom: `1px solid ${P.border}` }}>
                        {['#', 'Nome', 'Total Pago'].map(h => (<th key={h} style={{ textAlign: h === 'Total Pago' ? 'right' : 'left', padding: '3px 6px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>{h}</th>))}
                      </tr></thead>
                      <tbody>{pessoasStats.rankingRemuneracao.map((v, idx) => (
                        <tr key={v.nome} style={{ borderBottom: `1px solid ${P.steelBg}` }}>
                          <td style={{ padding: '4px 6px', color: P.light, fontWeight: 900, fontSize: '10px' }}>{idx + 1}</td>
                          <td style={{ padding: '4px 6px', color: P.text, fontWeight: 600 }}>{v.nome}</td>
                          <td style={{ padding: '4px 6px', color: '#1E7C52', fontWeight: 900, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(v.total)}</td>
                        </tr>
                      ))}</tbody>
                    </table>
                  </div>
                )}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ── ABA: FROTA & ARMAS ── */}
      {abaAtiva === 'frota' && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: 'Veículos Ativos',    valor: frotaGlobal?.veiculosPorStatus.ativo ?? '—',        sub: 'na frota',               cor: '#1E7C52', corTop: '#1E7C52' },
              { label: 'Em Manutenção',      valor: frotaGlobal?.veiculosPorStatus.manutencao ?? '—',   sub: 'indisponíveis',          cor: '#D97706', corTop: '#D97706' },
              { label: 'KM Rodado',          valor: kmTotalPeriodo > 0 ? kmTotalPeriodo.toLocaleString('pt-BR') : '—', sub: 'no período', cor: P.navy, corTop: P.navy },
              { label: 'Litros Abastecidos', valor: litrosTotalPeriodo > 0 ? litrosTotalPeriodo.toLocaleString('pt-BR', { maximumFractionDigits: 1 }) : '—', sub: `custo: ${fmtBRL(custoCombuPeriodo)}`, cor: P.steel, corTop: P.steel },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.corTop}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
                <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{loading ? '—' : k.valor}</p>
                <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
              </div>
            ))}
          </div>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div className="card-light p-5">
              <SectionTitle icon={Truck} label="Status da Frota" />
              <div className="mt-4 space-y-3">
                {frotaGlobal ? (() => {
                  const tot = frotaGlobal.veiculosPorStatus.ativo + frotaGlobal.veiculosPorStatus.inativo + frotaGlobal.veiculosPorStatus.manutencao
                  return [
                    { label: 'Ativos',         valor: frotaGlobal.veiculosPorStatus.ativo,       cor: '#1E7C52' },
                    { label: 'Em Manutenção',  valor: frotaGlobal.veiculosPorStatus.manutencao,  cor: '#D97706' },
                    { label: 'Inativos',       valor: frotaGlobal.veiculosPorStatus.inativo,     cor: P.light   },
                  ].map(r => (
                    <div key={r.label}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <span style={{ fontSize: '12px', fontWeight: 600, color: P.text }}>{r.label}</span>
                        <span style={{ fontSize: '12px', fontWeight: 900, color: r.cor }}>{r.valor}</span>
                      </div>
                      <div style={{ height: '8px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
                        <div style={{ width: `${tot > 0 ? (r.valor/tot)*100 : 0}%`, height: '100%', backgroundColor: r.cor, borderRadius: '2px', transition: 'width 0.8s ease' }} />
                      </div>
                    </div>
                  ))
                })() : <p style={{ fontSize: '11px', color: P.light }}>Carregando...</p>}
              </div>
              {frotaGlobal && (
                <div style={{ marginTop: '20px' }}>
                  <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.18em', color: P.textSub, marginBottom: '10px' }}>Armamentos</p>
                  <div style={{ display: 'flex', gap: '8px', marginBottom: '10px' }}>
                    <div style={{ flex: 1, padding: '10px', backgroundColor: '#E6F4EC', borderRadius: '2px', textAlign: 'center' }}>
                      <p style={{ fontSize: '18px', fontWeight: 900, color: '#1E7C52' }}>{frotaGlobal.armamentosAtivos}</p>
                      <p style={{ fontSize: '9px', color: '#1E7C52', fontWeight: 700, textTransform: 'uppercase' }}>Ativos</p>
                    </div>
                    <div style={{ flex: 1, padding: '10px', backgroundColor: P.errorBg, borderRadius: '2px', textAlign: 'center' }}>
                      <p style={{ fontSize: '18px', fontWeight: 900, color: P.errorText }}>{frotaGlobal.armamentosInativos}</p>
                      <p style={{ fontSize: '9px', color: P.errorText, fontWeight: 700, textTransform: 'uppercase' }}>Inativos</p>
                    </div>
                  </div>
                  {frotaGlobal.armamentosPorTipo.length > 0 && (
                    <div className="space-y-2">
                      {frotaGlobal.armamentosPorTipo.map(a => (
                        <div key={a.tipo} style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                          <span style={{ fontSize: '11px', color: P.text, fontWeight: 600, minWidth: '120px' }}>{a.tipo}</span>
                          <div style={{ flex: 1, height: '6px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
                            <div style={{ width: `${(a.qtd / (frotaGlobal.armamentosPorTipo[0]?.qtd || 1)) * 100}%`, height: '100%', backgroundColor: P.navy, borderRadius: '2px' }} />
                          </div>
                          <span style={{ fontSize: '11px', fontWeight: 900, color: P.navy, minWidth: '20px', textAlign: 'right' }}>{a.qtd}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>
            <div className="card-light p-5">
              <SectionTitle icon={Truck} label="Veículos — Detalhes do Período" />
              <div className="mt-4 overflow-x-auto">
                {frotaDetalhes.length > 0 ? (
                  <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                    <thead><tr style={{ borderBottom: `1px solid ${P.border}` }}>
                      {['Placa', 'KM', 'Litros', 'Custo', 'Viag.'].map(h => (
                        <th key={h} style={{ textAlign: h === 'Placa' ? 'left' : 'right', padding: '3px 6px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.1em', color: P.textSub }}>{h}</th>
                      ))}
                    </tr></thead>
                    <tbody>{frotaDetalhes.map((v, idx) => (
                      <tr key={v.placa} style={{ borderBottom: `1px solid ${P.steelBg}`, backgroundColor: idx % 2 === 0 ? '#fff' : P.bg }}>
                        <td style={{ padding: '5px 6px' }}>
                          <span style={{ fontFamily: 'monospace', fontWeight: 700, color: P.text }}>{v.placa}</span>
                          {v.modelo && <span style={{ display: 'block', fontSize: '9px', color: P.light }}>{v.modelo}</span>}
                        </td>
                        <td style={{ padding: '5px 6px', textAlign: 'right', color: P.navy, fontWeight: 900, fontVariantNumeric: 'tabular-nums' }}>{v.kmTotal > 0 ? v.kmTotal.toLocaleString('pt-BR') : '—'}</td>
                        <td style={{ padding: '5px 6px', textAlign: 'right', color: P.textSub, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{v.litros > 0 ? v.litros.toLocaleString('pt-BR', { maximumFractionDigits: 1 }) : '—'}</td>
                        <td style={{ padding: '5px 6px', textAlign: 'right', color: P.steel, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{v.custo > 0 ? fmtBRL(v.custo) : '—'}</td>
                        <td style={{ padding: '5px 6px', textAlign: 'right', color: P.textSub, fontWeight: 700 }}>{v.viagens}</td>
                      </tr>
                    ))}</tbody>
                  </table>
                ) : <p style={{ fontSize: '11px', color: P.light, padding: '20px', textAlign: 'center' }}>Sem dados de veículos no período</p>}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ── ABA: QUALIDADE ── */}
      {abaAtiva === 'qualidade' && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: 'Total Checklists',   valor: qualidadeStats?.total ?? '—',                                                               sub: `${qualidadeStats?.concluidos ?? 0} concluídos`,            cor: P.navy,      corTop: P.navy    },
              { label: 'Taxa de Conclusão',  valor: taxaConclusaoClk != null ? `${taxaConclusaoClk}%` : '—',                                    sub: 'checklists concluídos',                                     cor: taxaConclusaoClk != null && taxaConclusaoClk >= 80 ? '#1E7C52' : '#B83832', corTop: taxaConclusaoClk != null && taxaConclusaoClk >= 80 ? '#1E7C52' : '#B83832' },
              { label: 'Taxa Conformidade',  valor: taxaConformidade != null ? `${taxaConformidade}%` : '—',                                    sub: `${qualidadeStats?.conformes ?? 0}/${qualidadeStats?.totalItens ?? 0} itens`, cor: taxaConformidade != null && taxaConformidade >= 90 ? '#1E7C52' : '#D97706', corTop: taxaConformidade != null && taxaConformidade >= 90 ? '#1E7C52' : '#D97706' },
              { label: 'Não Conformidades',  valor: qualidadeStats ? qualidadeStats.totalItens - qualidadeStats.conformes : '—',                sub: 'itens reprovados',                                          cor: (qualidadeStats && qualidadeStats.totalItens - qualidadeStats.conformes > 0) ? '#B83832' : '#1E7C52', corTop: (qualidadeStats && qualidadeStats.totalItens - qualidadeStats.conformes > 0) ? '#B83832' : '#1E7C52' },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.corTop}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
                <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{loading ? '—' : k.valor}</p>
                <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
              </div>
            ))}
          </div>
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
            <div className="card-light p-5">
              <SectionTitle icon={CheckCircle2} label="Material vs Viatura" />
              <div className="mt-4 space-y-4">
                {qualidadeStats ? [
                  { label: 'Checklist Material', total: qualidadeStats.material.total, conformes: qualidadeStats.material.conformes },
                  { label: 'Checklist Viatura',  total: qualidadeStats.viatura.total,  conformes: qualidadeStats.viatura.conformes  },
                ].map(r => {
                  const pct = r.total > 0 ? Math.round((r.conformes / r.total) * 100) : null
                  return (
                    <div key={r.label}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '4px' }}>
                        <span style={{ fontSize: '12px', fontWeight: 600, color: P.text }}>{r.label}</span>
                        <span style={{ fontSize: '12px', fontWeight: 900, color: pct != null && pct >= 90 ? '#1E7C52' : '#D97706' }}>{pct != null ? `${pct}%` : '—'}</span>
                      </div>
                      <div style={{ height: '8px', backgroundColor: P.steelBg, borderRadius: '2px', overflow: 'hidden' }}>
                        <div style={{ width: `${pct ?? 0}%`, height: '100%', backgroundColor: pct != null && pct >= 90 ? '#1E7C52' : '#D97706', borderRadius: '2px', transition: 'width 0.8s ease' }} />
                      </div>
                      <p style={{ fontSize: '10px', color: P.light, marginTop: '3px' }}>{r.conformes}/{r.total} itens conformes</p>
                    </div>
                  )
                }) : <p style={{ fontSize: '11px', color: P.light, textAlign: 'center', padding: '20px' }}>Sem dados no período</p>}
                {qualidadeStats?.tempoMedioMin != null && (
                  <div style={{ padding: '10px', backgroundColor: P.steelBg, borderRadius: '2px', marginTop: '8px' }}>
                    <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.14em', color: P.textSub }}>Tempo Médio p/ Completar</p>
                    <p style={{ fontSize: '18px', fontWeight: 900, color: P.navy, marginTop: '4px', fontVariantNumeric: 'tabular-nums' }}>{formatDuracao(qualidadeStats.tempoMedioMin)}</p>
                  </div>
                )}
              </div>
            </div>
            <div className="card-light p-5">
              <SectionTitle icon={AlertTriangle} label="Itens Mais Reprovados" />
              <div className="mt-4">
                {qualidadeStats?.itensMaisReprovados.length ? (
                  <div className="space-y-2">
                    {qualidadeStats.itensMaisReprovados.map((item, i) => (
                      <div key={i} style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                        <span style={{ fontSize: '10px', color: P.light, fontWeight: 900, minWidth: '16px' }}>{i + 1}</span>
                        <span style={{ fontSize: '11px', color: P.text, fontWeight: 600, flex: 1 }}>{item.descricao}</span>
                        <span style={{ fontSize: '11px', fontWeight: 900, color: '#B83832', minWidth: '20px', textAlign: 'right' }}>{item.total}</span>
                      </div>
                    ))}
                  </div>
                ) : <p style={{ fontSize: '11px', color: P.light, textAlign: 'center', padding: '20px' }}>Nenhuma não conformidade no período</p>}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* ── ABA: CLIENTES ── */}
      {abaAtiva === 'clientes' && (
        <div className="space-y-6">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: 'Clientes Ativos',  valor: clientesGlobal?.ativos ?? '—',       sub: 'na base cadastral',         cor: '#1E7C52', corTop: '#1E7C52' },
              { label: 'Inativos',         valor: clientesGlobal?.inativos ?? '—',      sub: 'sem atividade',             cor: P.light,   corTop: P.border  },
              { label: 'Com Telegram',     valor: clientesGlobal?.comTelegram ?? '—',   sub: 'notificações ativas',       cor: P.navy,    corTop: P.navy    },
              { label: 'Sem Telegram',     valor: clientesGlobal?.semTelegram ?? '—',   sub: 'sem integração de alerta',  cor: P.textSub, corTop: P.light   },
            ].map(k => (
              <div key={k.label} style={{ backgroundColor: '#fff', border: `1px solid ${P.border}`, borderRadius: '2px', padding: '14px', borderTop: `3px solid ${k.corTop}` }}>
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.16em', color: P.textSub, marginBottom: '6px' }}>{k.label}</p>
                <p style={{ fontSize: '22px', fontWeight: 900, color: k.cor, fontVariantNumeric: 'tabular-nums', lineHeight: 1 }}>{k.valor}</p>
                <p style={{ fontSize: '10px', color: P.light, marginTop: '4px' }}>{k.sub}</p>
              </div>
            ))}
          </div>
          <div className="card-light p-5">
            <SectionTitle icon={Users} label="Escoltas por Cliente no Período" />
            <div className="mt-4 space-y-3">
              {porCliente.length > 0 ? porCliente.map((c, idx) => {
                const cor = c.cor !== P.steel ? c.cor : gradientCors[idx] ?? P.light
                return (
                  <div key={c.nome} className="space-y-1">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div style={{ width: '8px', height: '8px', backgroundColor: cor, borderRadius: '2px', flexShrink: 0 }} />
                        <span className="text-xs font-semibold" style={{ color: P.text }}>{c.nome}</span>
                      </div>
                      <span style={{ fontSize: '10px', color: P.textSub }}>{c.concluidas}/{c.total}</span>
                    </div>
                    <ClienteBar value={c.total} max={maxCliente} cor={cor} />
                  </div>
                )
              }) : <p style={{ fontSize: '11px', color: P.light, textAlign: 'center', padding: '20px' }}>Sem dados no período</p>}
            </div>
          </div>
          {verFinanceiro && finPorCliente.length > 0 && (
            <div className="card-light p-5">
              <SectionTitle icon={Users} label="Financeiro por Cliente" />
              <div className="mt-4 overflow-x-auto">
                <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}>
                  <thead><tr style={{ borderBottom: `1px solid ${P.border}` }}>
                    {['Cliente', 'Escoltas', 'Receita', 'Custo', 'Margem', '%'].map(h => (
                      <th key={h} style={{ textAlign: h === 'Cliente' ? 'left' : 'right', padding: '4px 8px', fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.textSub }}>{h}</th>
                    ))}
                  </tr></thead>
                  <tbody>{finPorCliente.map((r, idx) => (
                    <tr key={r.nome} style={{ borderBottom: `1px solid ${P.steelBg}`, backgroundColor: idx % 2 === 0 ? '#fff' : P.bg }}>
                      <td style={{ padding: '5px 8px' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                          <div style={{ width: '7px', height: '7px', backgroundColor: r.cor, borderRadius: '2px', flexShrink: 0 }} />
                          <span style={{ color: P.text, fontWeight: 600 }}>{r.nome}</span>
                        </div>
                      </td>
                      <td style={{ padding: '5px 8px', textAlign: 'right', color: P.textSub, fontWeight: 700 }}>{r.total}</td>
                      <td style={{ padding: '5px 8px', textAlign: 'right', color: '#1E7C52', fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.receita)}</td>
                      <td style={{ padding: '5px 8px', textAlign: 'right', color: P.errorText, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.custo)}</td>
                      <td style={{ padding: '5px 8px', textAlign: 'right', color: r.margem >= 0 ? '#1E7C52' : P.errorText, fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>{fmtBRL(r.margem)}</td>
                      <td style={{ padding: '5px 8px', textAlign: 'right' }}>
                        <span style={{ fontSize: '10px', fontWeight: 900, color: r.margemPct != null ? (r.margemPct >= 0 ? '#1E7C52' : P.errorText) : P.light }}>
                          {r.margemPct != null ? `${r.margemPct.toFixed(1)}%` : '—'}
                        </span>
                      </td>
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      )}

    </div>
  )
}
