'use client'

import Link from 'next/link'

import { useEffect, useState } from 'react'
import {
  Shield, AlertTriangle, CheckCircle, Clock,
  ArrowUpRight, ArrowRight, Users, Car, Crosshair,
  TrendingUp, TrendingDown,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_CRIAR_ESCOLTA, type CodigoPerfil } from '@/lib/permissions'
import { CartaoEscolta } from '@/components/escolta/cartao-escolta'
import { SELECT_CARTAO, type CartaoEscolta as CartaoDados, completarCoresClientes } from '@/lib/cartao-escolta'

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

// Onda K: o painel usa o cartão padrão (lib/cartao-escolta.ts); status e rótulos vêm de
// lib/fluxo-escolta.ts (acabou o STATUS_MAP duplicado, que não tinha em_transito_retorno).
type EscoltaRecente = CartaoDados

const STATUS_ATIVOS = ['em_pre_inicio', 'em_andamento', 'na_origem', 'em_transito_destino', 'no_destino', 'em_transito_retorno', 'retornando', 'na_base']

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
        // Onda I: escolta arquivada e registro anulado fora dos números do painel.
        sb.from('escoltas').select('id', { count: 'exact', head: true }).in('status', STATUS_ATIVOS).is('arquivada_em', null),
        sb.from('escoltas').select('id', { count: 'exact', head: true }).is('arquivada_em', null)
          .gte('data_hora_prevista', hoje.toISOString())
          .lt('data_hora_prevista', amanha.toISOString()),
        sb.from('emergencias').select('id, escolta:escoltas!inner(arquivada_em)', { count: 'exact', head: true })
          .eq('status', 'aberta').is('anulado_em', null).is('escolta.arquivada_em', null),
        sb.from('checklists').select('id, ev:escolta_veiculos!inner(escolta:escoltas!inner(arquivada_em))', { count: 'exact', head: true })
          .eq('concluido', false).is('anulado_em', null).is('ev.escolta.arquivada_em', null),
        sb.from('vigilantes').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('veiculos').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('armamentos').select('id', { count: 'exact', head: true }).eq('status', 'ativo'),
        sb.from('escoltas').select('id', { count: 'exact', head: true }).is('arquivada_em', null)
          .gte('criado_em', inicioMes.toISOString()),
        sb.from('escoltas').select('id', { count: 'exact', head: true }).is('arquivada_em', null)
          .gte('criado_em', inicioMesAnterior.toISOString())
          .lte('criado_em', fimMesAnterior.toISOString()),
        sb.from('escoltas')
          .select(SELECT_CARTAO)
          .not('status', 'in', '("finalizada","cancelada")')
          .is('arquivada_em', null)
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
      // Onda K: cor das linhas sem o cliente no embed (a RPC não devolve ao operador a das escoltas
      // de outra equipe, decisão S17: essas saem no cinza neutro).
      setRecentes(await completarCoresClientes(sb, (recentesQ.data ?? []) as EscoltaRecente[]))
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
        {/* Criar escolta e ato de gestao. Este botao nao tinha guarda nenhuma, entao o
            operador via "Nova Escolta" no painel e caia num formulario que o banco nao
            deixaria salvar. */}
        {PODE_CRIAR_ESCOLTA.includes((user?.perfil?.codigo ?? '') as CodigoPerfil) && (
          <Link href="/dashboard/escoltas/nova" className="btn-gradient shrink-0 text-xs md:text-sm px-3 md:px-4 py-2 md:py-2.5">
            <Shield size={14} />
            <span className="hidden sm:inline">Nova Escolta</span>
            <span className="sm:hidden">Nova</span>
          </Link>
        )}
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
              <ArrowUpRight size={12} />AGORA
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
          <Link href="/dashboard/escoltas"
            className="flex items-center gap-1 text-xs font-medium transition-colors shrink-0"
            style={{ color: '#53648A' }}
            onMouseEnter={(e) => (e.currentTarget as HTMLElement).style.color = '#3A5464'}
            onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.color = '#53648A'}
          >
            Ver todas <ArrowRight size={13} />
          </Link>
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
            {/* Onda K: o mesmo cartão da lista, do mural, do Modo Guiado e do mapa. */}
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 p-4">
              {recentes.map((e) => (
                <a key={e.id} href={`/dashboard/escoltas/${e.id}`} style={{ textDecoration: 'none' }}>
                  {/* Decisão S17: para o operador, escolta em que ele não está (sem efetivo visível
                      pela RLS) sai no cinza neutro, como no mural. */}
                  <CartaoEscolta variante="cartao" perfil={user?.perfil?.codigo}
                    escolta={user?.perfil?.codigo === 'operador' && !(e.efetivo ?? []).length ? { ...e, cor_sigilosa: true } : e} />
                </a>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
