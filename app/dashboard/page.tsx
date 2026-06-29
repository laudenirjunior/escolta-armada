'use client'

import { useEffect, useState } from 'react'
import {
  Shield, AlertTriangle, CheckCircle, Clock,
  ArrowUpRight, ArrowRight, MapPin, Users, Car, Crosshair,
  TrendingUp, TrendingDown,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

interface Resumo {
  escoltas_ativas: number
  escoltas_hoje: number
  emergencias_abertas: number
  checklists_pendentes: number
}

interface StatsExtra {
  vigilantes_ativos: number
  veiculos_disponiveis: number
  armamentos_ativos: number
  escoltas_mes_atual: number
  escoltas_mes_anterior: number
}

interface EscoltaRecente {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  cliente: { nome_cliente: string; cor_destaque: string } | null
  origem_endereco: string
  destino_endereco: string
}

const STATUS_MAP: Record<string, { label: string; cls: string }> = {
  rascunho:      { label: 'Rascunho',     cls: 'badge-neutral' },
  agendada:      { label: 'Agendada',     cls: 'badge-info' },
  em_pre_inicio: { label: 'Pré-Início',   cls: 'badge-warning' },
  em_andamento:  { label: 'Em Andamento', cls: 'badge-info' },
  na_origem:     { label: 'Na Origem',    cls: 'badge-info' },
  no_destino:    { label: 'No Destino',   cls: 'badge-success' },
  retornando:    { label: 'Retornando',   cls: 'badge-warning' },
  na_base:       { label: 'Na Base',      cls: 'badge-success' },
  finalizada:    { label: 'Finalizada',   cls: 'badge-success' },
  cancelada:     { label: 'Cancelada',    cls: 'badge-danger' },
}

const STATUS_ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base']

const supabase = createClient()
const sb = supabase as any

export default function DashboardPage() {
  const { user } = useAuth()
  const [resumo, setResumo] = useState<Resumo>({
    escoltas_ativas: 0,
    escoltas_hoje: 0,
    emergencias_abertas: 0,
    checklists_pendentes: 0,
  })
  const [stats, setStats] = useState<StatsExtra>({
    vigilantes_ativos: 0,
    veiculos_disponiveis: 0,
    armamentos_ativos: 0,
    escoltas_mes_atual: 0,
    escoltas_mes_anterior: 0,
  })
  const [recentes, setRecentes] = useState<EscoltaRecente[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const carregar = async () => {
      const agora = new Date()
      const hoje = new Date(agora); hoje.setHours(0, 0, 0, 0)
      const amanha = new Date(hoje); amanha.setDate(amanha.getDate() + 1)

      const inicioMes = new Date(agora.getFullYear(), agora.getMonth(), 1)
      const inicioMesAnterior = new Date(agora.getFullYear(), agora.getMonth() - 1, 1)
      const fimMesAnterior = new Date(agora.getFullYear(), agora.getMonth(), 0, 23, 59, 59)

      const [
        ativas, hojeQ, emergQ, checkQ,
        vigilantesQ, veiculosQ, armamentosQ,
        mesAtualQ, mesAnteriorQ,
        recentesQ,
      ] = await Promise.all([
        sb.from('escoltas').select('id', { count: 'exact', head: true }).in('status', STATUS_ATIVOS),
        sb.from('escoltas').select('id', { count: 'exact', head: true })
          .gte('data_hora_prevista', hoje.toISOString())
          .lt('data_hora_prevista', amanha.toISOString()),
        sb.from('emergencias').select('id', { count: 'exact', head: true }).eq('status', 'aberta'),
        sb.from('checklists').select('id', { count: 'exact', head: true }).eq('concluido', false),
        sb.from('vigilantes').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('veiculos').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('armamentos').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('escoltas').select('id', { count: 'exact', head: true })
          .gte('criado_em', inicioMes.toISOString()),
        sb.from('escoltas').select('id', { count: 'exact', head: true })
          .gte('criado_em', inicioMesAnterior.toISOString())
          .lte('criado_em', fimMesAnterior.toISOString()),
        sb.from('escoltas')
          .select('id, codigo_escolta, status, data_hora_prevista, origem_endereco, destino_endereco, cliente:clientes(nome_cliente, cor_destaque)')
          .not('status', 'in', '("finalizada","cancelada")')
          .order('data_hora_prevista', { ascending: true })
          .limit(8),
      ])

      setResumo({
        escoltas_ativas: ativas.count ?? 0,
        escoltas_hoje: hojeQ.count ?? 0,
        emergencias_abertas: emergQ.count ?? 0,
        checklists_pendentes: checkQ.count ?? 0,
      })
      setStats({
        vigilantes_ativos: vigilantesQ.count ?? 0,
        veiculos_disponiveis: veiculosQ.count ?? 0,
        armamentos_ativos: armamentosQ.count ?? 0,
        escoltas_mes_atual: mesAtualQ.count ?? 0,
        escoltas_mes_anterior: mesAnteriorQ.count ?? 0,
      })
      setRecentes((recentesQ.data ?? []) as EscoltaRecente[])
      setLoading(false)
    }
    carregar()
  }, [])

  const primeiro = user?.nome_completo?.split(' ')[0] ?? ''
  const hora = new Date().getHours()
  const saudacao = hora < 12 ? 'Bom dia' : hora < 18 ? 'Boa tarde' : 'Boa noite'

  const variacaoMes = stats.escoltas_mes_anterior > 0
    ? Math.round(((stats.escoltas_mes_atual - stats.escoltas_mes_anterior) / stats.escoltas_mes_anterior) * 100)
    : 0

  return (
    <div className="space-y-4 md:space-y-6">

      {/* ── Page header ── */}
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h1 className="page-title">{saudacao}, {primeiro}.</h1>
          <p className="page-subtitle text-xs md:text-sm">
            {user?.perfil?.nome_exibicao} · {new Date().toLocaleDateString('pt-BR', {
              weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
            })}
          </p>
        </div>
        <a href="/dashboard/escoltas/nova" className="btn-gradient shrink-0 text-xs md:text-sm px-3 md:px-4 py-2 md:py-2.5">
          <Shield size={14} />
          <span className="hidden sm:inline">Nova Escolta</span>
          <span className="sm:hidden">Nova</span>
        </a>
      </div>

      {/* ── KPI cards ── */}
      <div className="grid grid-cols-2 xl:grid-cols-4 gap-3 md:gap-4">

        {/* Em operação */}
        <div className="card-kpi">
          <div className="flex items-start justify-between mb-4">
            <div className="w-10 h-10 rounded-lg flex items-center justify-center"
              style={{ backgroundColor: 'rgba(83,100,138,0.2)' }}>
              <Shield size={18} style={{ color: '#53648A' }} />
            </div>
            <span className="flex items-center gap-1 text-[11px] font-bold" style={{ color: '#4ade80' }}>
              <ArrowUpRight size={12} />LIVE
            </span>
          </div>
          <p className="text-3xl font-black text-white leading-none tabular-nums tracking-tight">
            {loading ? '—' : resumo.escoltas_ativas}
          </p>
          <p className="text-[11px] mt-1.5 uppercase tracking-widest" style={{ color: 'rgba(255,255,255,0.35)' }}>
            Em Operação
          </p>
          <div className="absolute bottom-0 right-0 w-24 h-24 rounded-full -mr-8 -mb-8"
            style={{ backgroundColor: 'rgba(83,100,138,0.05)' }} />
        </div>

        {/* Programadas hoje */}
        <div className="card-kpi">
          <div className="flex items-start justify-between mb-4">
            <div className="w-10 h-10 rounded-lg flex items-center justify-center"
              style={{ backgroundColor: 'rgba(92,107,115,0.25)' }}>
              <Clock size={18} style={{ color: '#9ab0bb' }} />
            </div>
            <span className="text-[11px] font-bold" style={{ color: 'rgba(255,255,255,0.3)' }}>HOJE</span>
          </div>
          <p className="text-3xl font-black text-white leading-none tabular-nums tracking-tight">
            {loading ? '—' : resumo.escoltas_hoje}
          </p>
          <p className="text-[11px] mt-1.5 uppercase tracking-widest" style={{ color: 'rgba(255,255,255,0.35)' }}>
            Programadas Hoje
          </p>
          <div className="absolute bottom-0 right-0 w-24 h-24 rounded-full -mr-8 -mb-8"
            style={{ backgroundColor: 'rgba(92,107,115,0.05)' }} />
        </div>

        {/* Emergências */}
        <div className="card-kpi" style={resumo.emergencias_abertas > 0 ? { outline: '1px solid rgba(184,56,50,0.4)', outlineOffset: '-1px' } : {}}>
          <div className="flex items-start justify-between mb-4">
            <div className="w-10 h-10 rounded-lg flex items-center justify-center"
              style={{ backgroundColor: resumo.emergencias_abertas > 0 ? 'rgba(184,56,50,0.2)' : 'rgba(30,124,82,0.15)' }}>
              <AlertTriangle size={18}
                style={{ color: resumo.emergencias_abertas > 0 ? '#e85248' : '#4ade80' }} />
            </div>
            {resumo.emergencias_abertas > 0 && (
              <span className="text-[11px] font-black animate-pulse" style={{ color: '#e85248' }}>ALERTA</span>
            )}
          </div>
          <p className="text-3xl font-black leading-none tabular-nums tracking-tight"
            style={{ color: resumo.emergencias_abertas > 0 ? '#e85248' : '#fff' }}>
            {loading ? '—' : resumo.emergencias_abertas}
          </p>
          <p className="text-[11px] mt-1.5 uppercase tracking-widest" style={{ color: 'rgba(255,255,255,0.35)' }}>
            Emergências Abertas
          </p>
          <div className="absolute bottom-0 right-0 w-24 h-24 rounded-full -mr-8 -mb-8"
            style={{ backgroundColor: 'rgba(184,56,50,0.04)' }} />
        </div>

        {/* Checklists */}
        <div className="card-kpi" style={resumo.checklists_pendentes > 0 ? { outline: '1px solid rgba(160,114,18,0.4)', outlineOffset: '-1px' } : {}}>
          <div className="flex items-start justify-between mb-4">
            <div className="w-10 h-10 rounded-lg flex items-center justify-center"
              style={{ backgroundColor: resumo.checklists_pendentes > 0 ? 'rgba(160,114,18,0.2)' : 'rgba(30,124,82,0.15)' }}>
              <CheckCircle size={18}
                style={{ color: resumo.checklists_pendentes > 0 ? '#f59e0b' : '#4ade80' }} />
            </div>
          </div>
          <p className="text-3xl font-black leading-none tabular-nums tracking-tight"
            style={{ color: resumo.checklists_pendentes > 0 ? '#f59e0b' : '#fff' }}>
            {loading ? '—' : resumo.checklists_pendentes}
          </p>
          <p className="text-[11px] mt-1.5 uppercase tracking-widest" style={{ color: 'rgba(255,255,255,0.35)' }}>
            Checklists Pendentes
          </p>
          <div className="absolute bottom-0 right-0 w-24 h-24 rounded-full -mr-8 -mb-8"
            style={{ backgroundColor: 'rgba(160,114,18,0.04)' }} />
        </div>
      </div>

      {/* ── Stats row ── */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3 md:gap-4">

        {/* Vigilantes */}
        <div className="card-light p-4 flex items-center gap-3">
          <div className="w-9 h-9 rounded-md flex items-center justify-center shrink-0"
            style={{ backgroundColor: 'rgba(26,41,74,0.07)' }}>
            <Users size={16} style={{ color: '#1A294A' }} />
          </div>
          <div className="min-w-0">
            <p className="text-xl font-black tabular-nums tracking-tight" style={{ color: '#0E1A33' }}>
              {loading ? '—' : stats.vigilantes_ativos}
            </p>
            <p className="text-[11px] uppercase tracking-wider truncate" style={{ color: '#5A6A80' }}>
              Vigilantes Ativos
            </p>
          </div>
        </div>

        {/* Veículos */}
        <div className="card-light p-4 flex items-center gap-3">
          <div className="w-9 h-9 rounded-md flex items-center justify-center shrink-0"
            style={{ backgroundColor: '#EBF7F1' }}>
            <Car size={16} style={{ color: '#1E7C52' }} />
          </div>
          <div className="min-w-0">
            <p className="text-xl font-black tabular-nums tracking-tight" style={{ color: '#0E1A33' }}>
              {loading ? '—' : stats.veiculos_disponiveis}
            </p>
            <p className="text-[11px] uppercase tracking-wider truncate" style={{ color: '#5A6A80' }}>
              Veículos Ativos
            </p>
          </div>
        </div>

        {/* Armamentos */}
        <div className="card-light p-4 flex items-center gap-3">
          <div className="w-9 h-9 rounded-md flex items-center justify-center shrink-0"
            style={{ backgroundColor: '#FFF8E8' }}>
            <Crosshair size={16} style={{ color: '#A07212' }} />
          </div>
          <div className="min-w-0">
            <p className="text-xl font-black tabular-nums tracking-tight" style={{ color: '#0E1A33' }}>
              {loading ? '—' : stats.armamentos_ativos}
            </p>
            <p className="text-[11px] uppercase tracking-wider truncate" style={{ color: '#5A6A80' }}>
              Armamentos Ativos
            </p>
          </div>
        </div>

        {/* Escoltas do mês */}
        <div className="card-light p-4 flex items-center gap-3">
          <div className="w-9 h-9 rounded-md flex items-center justify-center shrink-0"
            style={{ backgroundColor: '#F0F2F4' }}>
            <Shield size={16} style={{ color: '#5C6B73' }} />
          </div>
          <div className="min-w-0">
            <div className="flex items-end gap-2">
              <p className="text-xl font-black tabular-nums tracking-tight" style={{ color: '#0E1A33' }}>
                {loading ? '—' : stats.escoltas_mes_atual}
              </p>
              {!loading && variacaoMes !== 0 && (
                <span className={`text-[11px] font-bold mb-0.5 flex items-center gap-0.5 tabular-nums ${variacaoMes > 0 ? 'text-green-600' : 'text-red-500'}`}>
                  {variacaoMes > 0 ? <TrendingUp size={11} /> : <TrendingDown size={11} />}
                  {Math.abs(variacaoMes)}%
                </span>
              )}
            </div>
            <p className="text-[11px] uppercase tracking-wider truncate" style={{ color: '#5A6A80' }}>
              Escoltas no Mês
            </p>
          </div>
        </div>
      </div>

      {/* ── Operações em andamento ── */}
      <div className="card-light overflow-x-auto">
        <div className="flex items-center justify-between px-4 md:px-5 py-3 md:py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
          <div className="flex items-center gap-2.5">
            <div className="w-1 h-5 rounded-full" style={{ background: 'linear-gradient(180deg, #53648A, #9F906D)' }} />
            <div>
              <h2 className="text-sm font-bold" style={{ color: '#0E1A33' }}>Operações em Andamento</h2>
              <p className="text-[11px]" style={{ color: '#5A6A80' }}>Escoltas ativas no momento</p>
            </div>
          </div>
          <a href="/dashboard/escoltas"
            className="flex items-center gap-1 text-xs font-medium transition-colors shrink-0"
            style={{ color: '#53648A' }}
            onMouseEnter={(e) => (e.currentTarget as HTMLElement).style.color = '#3A5464'}
            onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.color = '#53648A'}
          >
            Ver todas <ArrowRight size={13} />
          </a>
        </div>

        {loading ? (
          <div className="py-12 flex items-center justify-center">
            <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
              style={{ borderColor: '#53648A', borderTopColor: 'transparent' }} />
          </div>
        ) : recentes.length === 0 ? (
          <div className="py-12 text-center">
            <CheckCircle size={32} className="mx-auto mb-2" style={{ color: '#E2E8EC' }} />
            <p className="text-sm" style={{ color: '#5A6A80' }}>Nenhuma operação ativa no momento</p>
          </div>
        ) : (
          <>
            {/* Tabela — visível apenas md+ */}
            <div className="hidden md:block" style={{ borderTop: 'none' }}>
              {recentes.map((e) => {
                const s = STATUS_MAP[e.status] ?? { label: e.status, cls: 'badge-neutral' }
                const cor = e.cliente?.cor_destaque ?? '#53648A'
                return (
                  <a
                    key={e.id}
                    href={`/dashboard/escoltas/${e.id}`}
                    className="flex items-center gap-4 px-5 py-3.5 transition-colors group"
                    style={{ borderBottom: '1px solid #E2E8EC', textDecoration: 'none' }}
                    onMouseEnter={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC'}
                    onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = ''}
                  >
                    <div className="w-1 h-10 rounded-full shrink-0" style={{ backgroundColor: cor }} />
                    <div className="w-32 shrink-0">
                      <p className="text-[11px] font-black uppercase tracking-wider" style={{ color: '#5A6A80' }}>
                        {e.codigo_escolta ?? 'Pendente'}
                      </p>
                      <span className={`${s.cls} mt-1`}>{s.label}</span>
                    </div>
                    {e.cliente && (
                      <div className="w-44 shrink-0 hidden lg:block">
                        <p className="text-xs font-semibold truncate" style={{ color: '#0E1A33' }}>
                          {e.cliente.nome_cliente}
                        </p>
                      </div>
                    )}
                    <div className="flex-1 flex items-center gap-2 min-w-0">
                      <MapPin size={12} className="shrink-0" style={{ color: '#C8D5DC' }} />
                      <p className="text-xs truncate" style={{ color: '#5A6A80' }}>{e.origem_endereco}</p>
                      <ArrowRight size={12} className="shrink-0" style={{ color: '#C8D5DC' }} />
                      <p className="text-xs truncate" style={{ color: '#5A6A80' }}>{e.destino_endereco}</p>
                    </div>
                    <div className="text-right shrink-0">
                      <p className="text-xs font-medium" style={{ color: '#5A6A80' }}>
                        {new Date(e.data_hora_prevista).toLocaleDateString('pt-BR')}
                      </p>
                      <p className="text-[11px]" style={{ color: '#A8B8C2' }}>
                        {new Date(e.data_hora_prevista).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                      </p>
                    </div>
                    <ArrowRight size={14} className="shrink-0 transition-colors" style={{ color: '#E2E8EC' }} />
                  </a>
                )
              })}
            </div>

            {/* Cards mobile — visível apenas abaixo de md */}
            <div className="md:hidden divide-y" style={{ borderColor: '#E2E8EC' }}>
              {recentes.map((e) => {
                const s = STATUS_MAP[e.status] ?? { label: e.status, cls: 'badge-neutral' }
                const cor = e.cliente?.cor_destaque ?? '#53648A'
                return (
                  <a
                    key={e.id}
                    href={`/dashboard/escoltas/${e.id}`}
                    className="flex items-start gap-3 px-4 py-4 transition-colors active:bg-[#F8FAFC]"
                    style={{ textDecoration: 'none', borderBottom: '1px solid #E2E8EC' }}
                  >
                    <div className="w-1 rounded-full shrink-0 self-stretch min-h-[44px]" style={{ backgroundColor: cor }} />
                    <div className="flex-1 min-w-0 space-y-1.5">
                      <div className="flex items-center justify-between gap-2">
                        <p className="text-[11px] font-black uppercase tracking-wider" style={{ color: '#5A6A80' }}>
                          {e.codigo_escolta ?? 'Pendente'}
                        </p>
                        <span className={s.cls}>{s.label}</span>
                      </div>
                      {e.cliente && (
                        <p className="text-sm font-semibold truncate" style={{ color: '#0E1A33' }}>
                          {e.cliente.nome_cliente}
                        </p>
                      )}
                      <div className="flex items-start gap-1 text-xs" style={{ color: '#5A6A80' }}>
                        <MapPin size={11} className="shrink-0 mt-0.5" style={{ color: '#C8D5DC' }} />
                        <span className="truncate">{e.origem_endereco}</span>
                      </div>
                      <div className="flex items-start gap-1 text-xs" style={{ color: '#5A6A80' }}>
                        <ArrowRight size={11} className="shrink-0 mt-0.5" style={{ color: '#C8D5DC' }} />
                        <span className="truncate">{e.destino_endereco}</span>
                      </div>
                      <p className="text-[11px]" style={{ color: '#A8B8C2' }}>
                        {new Date(e.data_hora_prevista).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' })}
                      </p>
                    </div>
                    <ArrowRight size={14} className="shrink-0 mt-1" style={{ color: '#E2E8EC' }} />
                  </a>
                )
              })}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
