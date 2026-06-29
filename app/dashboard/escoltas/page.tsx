'use client'

import { useEffect, useState, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { Plus, Search, Eye, Pencil, ArrowRight, MapPin, Clock, Truck, CheckCircle2, Shield, FileDown } from 'lucide-react'
import { printEscolta } from '@/utils/print'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_CRIAR_ESCOLTA } from '@/lib/permissions'

interface EscoltaRow {
  id: string
  codigo_escolta: string | null
  status: string
  data_hora_prevista: string
  origem_endereco: string
  destino_endereco: string
  checklist_pendente_no_inicio: boolean
  cliente: { nome_cliente: string; cor_destaque: string } | null
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

const STATUS_OPTIONS = [
  { value: 'todos', label: 'Todos' },
  { value: 'em_andamento', label: 'Em Andamento' },
  { value: 'agendada', label: 'Agendada' },
  { value: 'em_pre_inicio', label: 'Pré-Início' },
  { value: 'finalizada', label: 'Finalizada' },
  { value: 'cancelada', label: 'Cancelada' },
]

const PODE_CRIAR = PODE_CRIAR_ESCOLTA

const supabase = createClient()
const sb = supabase as any

export default function EscoltasPage() {
  const [escoltas, setEscoltas] = useState<EscoltaRow[]>([])
  const [busca, setBusca] = useState('')
  const [filtroStatus, setFiltroStatus] = useState('todos')
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()
  const router = useRouter()
  const perfil = (user?.perfil?.codigo ?? '') as any

  const carregar = useCallback(async () => {
    setLoading(true)
    let q = sb
      .from('escoltas')
      .select(`
        id, codigo_escolta, status, data_hora_prevista,
        origem_endereco, destino_endereco, checklist_pendente_no_inicio,
        cliente:clientes(nome_cliente, cor_destaque)
      `)
      .order('data_hora_prevista', { ascending: false })

    if (filtroStatus !== 'todos') {
      q = q.eq('status', filtroStatus)
    }

    const { data } = await q
    let rows = (data ?? []) as EscoltaRow[]

    // Filtragem de Visibilidade (Supervisor e Operador)
    if (perfil === 'operador') {
      rows = rows.filter((e) =>
        ['rascunho', 'agendada', 'em_pre_inicio', 'em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base'].includes(e.status)
      )
    }

    setEscoltas(rows)
    setLoading(false)
  }, [filtroStatus, perfil, user])

  useEffect(() => { carregar() }, [carregar])

  const escoltasFiltradas = escoltas.filter((e) => {
    if (!busca) return true
    const termo = busca.toLowerCase()
    return (
      e.codigo_escolta?.toLowerCase().includes(termo) ||
      e.origem_endereco.toLowerCase().includes(termo) ||
      e.destino_endereco.toLowerCase().includes(termo) ||
      e.cliente?.nome_cliente.toLowerCase().includes(termo)
    )
  })

  // Cálculos dos Cards
  const countNaoIniciadas = escoltas.filter(e => ['rascunho', 'agendada', 'em_pre_inicio'].includes(e.status)).length
  const countEmAndamento = escoltas.filter(e => e.status === 'em_andamento').length
  const countOrigemDestino = escoltas.filter(e => ['na_origem', 'no_destino'].includes(e.status)).length
  const countRetornoBase = escoltas.filter(e => ['retornando', 'na_base'].includes(e.status)).length

  // Segmentação por tabelas
  const naoIniciadas = escoltasFiltradas.filter(e => ['rascunho', 'agendada', 'em_pre_inicio'].includes(e.status))
  const ativas = escoltasFiltradas.filter(e => ['em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base'].includes(e.status))
  const concluidas = escoltasFiltradas.filter(e => ['finalizada', 'cancelada'].includes(e.status))

  const renderTabelaEscoltas = (lista: EscoltaRow[], tituloVazio: string) => {
    if (lista.length === 0) {
      return (
        <div className="py-8 text-center bg-white rounded border border-slate-100">
          <p className="text-xs font-semibold text-[#6B7E8A]">{tituloVazio}</p>
        </div>
      )
    }

    return (
      <>
        {/* Tabela — visível apenas em desktop (md+) */}
        <div className="hidden md:block card-light overflow-x-auto">
          <table className="table-content">
            <thead>
              <tr>
                <th>Código</th>
                <th>Cliente</th>
                <th className="hidden md:table-cell">Origem → Destino</th>
                <th className="hidden lg:table-cell">Data / Hora</th>
                <th>Status</th>
                <th className="text-right">Ações</th>
              </tr>
            </thead>
            <tbody>
              {lista.map((e) => {
                const s = STATUS_MAP[e.status] ?? { label: e.status, cls: 'badge-neutral' }
                const cor = e.cliente?.cor_destaque ?? '#4A90A4'
                return (
                  <tr
                    key={e.id}
                    onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                    style={{ cursor: 'pointer', borderLeft: `3px solid ${cor}` }}
                  >
                    <td>
                      <span className="font-mono text-xs font-bold" style={{ color: '#1E2D35' }}>
                        {e.codigo_escolta ?? 'Pendente'}
                      </span>
                      {e.checklist_pendente_no_inicio && (
                        <span className="badge-warning ml-2">Checklist</span>
                      )}
                    </td>
                    <td>
                      <span className="text-sm font-medium" style={{ color: '#1E2D35' }}>
                        {e.cliente?.nome_cliente ?? '—'}
                      </span>
                    </td>
                    <td className="hidden md:table-cell">
                      <div className="flex items-center gap-2 max-w-xs">
                        <MapPin size={11} style={{ color: '#C8D5DC', flexShrink: 0 }} />
                        <span className="text-xs truncate" style={{ color: '#6B7E8A' }}>{e.origem_endereco}</span>
                        <ArrowRight size={11} style={{ color: '#C8D5DC', flexShrink: 0 }} />
                        <span className="text-xs truncate" style={{ color: '#6B7E8A' }}>{e.destino_endereco}</span>
                      </div>
                    </td>
                    <td className="hidden lg:table-cell">
                      <span className="text-xs" style={{ color: '#6B7E8A' }}>
                        {new Date(e.data_hora_prevista).toLocaleDateString('pt-BR')}
                        {' '}
                        {new Date(e.data_hora_prevista).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                      </span>
                    </td>
                    <td>
                      <span className={s.cls}>{s.label}</span>
                    </td>
                    <td>
                      <div className="flex items-center justify-end gap-1" onClick={(ev) => ev.stopPropagation()}>
                        <button
                          onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                          className="flex items-center justify-center transition-all"
                          style={{ color: '#6B7E8A', width: '36px', height: '36px', borderRadius: '2px' }}
                          onMouseEnter={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = '#EBF3FC'; (ev.currentTarget as HTMLElement).style.color = '#2166A8' }}
                          onMouseLeave={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = ''; (ev.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                          title="Ver detalhes"
                          aria-label="Ver detalhes da escolta"
                        >
                          <Eye size={14} />
                        </button>
                        <button
                          onClick={() => router.push(`/dashboard/escoltas/${e.id}?acao=editar`)}
                          className="flex items-center justify-center transition-all"
                          style={{ color: '#6B7E8A', width: '36px', height: '36px', borderRadius: '2px' }}
                          onMouseEnter={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = '#EBF7F1'; (ev.currentTarget as HTMLElement).style.color = '#1E7C52' }}
                          onMouseLeave={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = ''; (ev.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                          title="Editar"
                          aria-label="Editar escolta"
                        >
                          <Pencil size={13} />
                        </button>
                        <button
                          onClick={() => printEscolta(e.id)}
                          className="flex items-center justify-center transition-all"
                          style={{ color: '#6B7E8A', width: '36px', height: '36px', borderRadius: '2px' }}
                          onMouseEnter={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = '#F0F4FA'; (ev.currentTarget as HTMLElement).style.color = '#1A2F4A' }}
                          onMouseLeave={(ev) => { (ev.currentTarget as HTMLElement).style.backgroundColor = ''; (ev.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                          title="Exportar PDF"
                          aria-label="Exportar PDF da escolta"
                        >
                          <FileDown size={13} />
                        </button>
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        {/* Cards mobile — visível apenas em telas menores que md */}
        <div className="md:hidden space-y-3">
          {lista.map((e) => {
            const s = STATUS_MAP[e.status] ?? { label: e.status, cls: 'badge-neutral' }
            const cor = e.cliente?.cor_destaque ?? '#4A90A4'
            return (
              <div
                key={e.id}
                className="bg-white rounded-xl p-4 shadow-sm border border-gray-100"
                style={{ borderLeft: `4px solid ${cor}` }}
                onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
              >
                {/* Linha 1: código + status */}
                <div className="flex items-start justify-between gap-2 mb-2">
                  <div>
                    <span className="font-mono text-sm font-black" style={{ color: '#1E2D35' }}>
                      {e.codigo_escolta ?? 'Pendente'}
                    </span>
                    {e.checklist_pendente_no_inicio && (
                      <span className="badge-warning ml-2 text-[10px]">Checklist</span>
                    )}
                  </div>
                  <span className={s.cls}>{s.label}</span>
                </div>

                {/* Linha 2: cliente */}
                <p className="text-sm font-semibold mb-1" style={{ color: '#0E1A33' }}>
                  {e.cliente?.nome_cliente ?? '—'}
                </p>

                {/* Linha 3: data/hora */}
                <p className="text-xs mb-2" style={{ color: '#5A6A80' }}>
                  {new Date(e.data_hora_prevista).toLocaleDateString('pt-BR')}
                  {' às '}
                  {new Date(e.data_hora_prevista).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                </p>

                {/* Linha 4: origem → destino */}
                <div className="flex items-start gap-1 mb-3">
                  <MapPin size={11} className="mt-0.5 shrink-0" style={{ color: '#ABB5C9' }} />
                  <p className="text-xs leading-snug" style={{ color: '#5A6A80' }}>
                    <span className="font-medium">{e.origem_endereco}</span>
                    <ArrowRight size={10} className="inline mx-1" style={{ color: '#ABB5C9' }} />
                    <span>{e.destino_endereco}</span>
                  </p>
                </div>

                {/* Botões de ação */}
                <div className="flex gap-2 pt-2 border-t border-gray-100" onClick={(ev) => ev.stopPropagation()}>
                  <button
                    onClick={() => router.push(`/dashboard/escoltas/${e.id}`)}
                    className="flex-1 flex items-center justify-center gap-1.5 rounded-lg text-xs font-semibold transition-colors"
                    style={{ minHeight: '44px', backgroundColor: '#EBF3FC', color: '#2166A8' }}
                    aria-label="Ver detalhes da escolta"
                  >
                    <Eye size={14} />
                    Ver
                  </button>
                  <button
                    onClick={() => router.push(`/dashboard/escoltas/${e.id}?acao=editar`)}
                    className="flex-1 flex items-center justify-center gap-1.5 rounded-lg text-xs font-semibold transition-colors"
                    style={{ minHeight: '44px', backgroundColor: '#EBF7F1', color: '#1E7C52' }}
                    aria-label="Editar escolta"
                  >
                    <Pencil size={13} />
                    Editar
                  </button>
                  <button
                    onClick={() => printEscolta(e.id)}
                    className="flex items-center justify-center rounded-lg transition-colors"
                    style={{ minHeight: '44px', minWidth: '44px', backgroundColor: '#F0F4FA', color: '#1A2F4A' }}
                    aria-label="Exportar PDF da escolta"
                  >
                    <FileDown size={14} />
                  </button>
                </div>
              </div>
            )
          })}
        </div>
      </>
    )
  }

  return (
    <div className="space-y-6">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <div className="eyebrow-tag mb-2">
            <Shield size={10} />
            Gestão de Operações
          </div>
          <h1 className="page-title">Escoltas</h1>
          <p className="page-subtitle">
            {escoltasFiltradas.length} escolta{escoltasFiltradas.length !== 1 ? 's' : ''} encontrada{escoltasFiltradas.length !== 1 ? 's' : ''}
          </p>
        </div>
        {PODE_CRIAR.includes(perfil) && (
          <button
            onClick={() => router.push('/dashboard/escoltas/nova')}
            className="btn-gradient"
          >
            <Plus size={15} />
            <span className="hidden sm:inline">Nova Escolta</span>
            <span className="sm:hidden">Nova</span>
          </button>
        )}
      </div>

      {/* ── Stat Cards ── */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        {([
          {
            label: 'Não Iniciadas',
            count: countNaoIniciadas,
            sub: 'rascunho · agendada · pré-início',
            icon: Clock,
            dark: false,
            iconBg: '#E6EAF2',
            iconCor: '#1A294A',
          },
          {
            label: 'Em Andamento',
            count: countEmAndamento,
            sub: 'em trânsito agora',
            icon: Truck,
            dark: true,
            iconBg: 'rgba(255,255,255,0.10)',
            iconCor: '#ABB5C9',
          },
          {
            label: 'Na Origem / Destino',
            count: countOrigemDestino,
            sub: 'na origem · no destino',
            icon: MapPin,
            dark: false,
            iconBg: '#EBF0F8',
            iconCor: '#53648A',
          },
          {
            label: 'Retornando / Na Base',
            count: countRetornoBase,
            sub: 'retornando · na base',
            icon: CheckCircle2,
            dark: false,
            iconBg: '#E6EAF2',
            iconCor: '#1A294A',
          },
        ] as const).map((c, i) => {
          const Icon = c.icon
          return (
            <div
              key={i}
              className={c.dark ? 'glow-active' : ''}
              style={{
                borderRadius: '2px',
                padding: '20px',
                minHeight: '148px',
                display: 'flex',
                flexDirection: 'column',
                justifyContent: 'space-between',
                transition: 'transform 400ms cubic-bezier(0.32,0.72,0,1), box-shadow 400ms cubic-bezier(0.32,0.72,0,1)',
                cursor: 'default',
                ...(c.dark
                  ? {
                      backgroundColor: '#1A294A',
                      outline: '1px solid rgba(255,255,255,0.08)',
                      boxShadow: '0 2px 8px rgba(0,0,0,0.15)',
                    }
                  : {
                      backgroundColor: '#fff',
                      border: '1px solid #D6DAE5',
                      boxShadow: '0 1px 3px rgba(0,0,0,0.05)',
                    }),
              }}
              onMouseEnter={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(-3px)'
                el.style.boxShadow = c.dark
                  ? '0 12px 32px rgba(0,0,0,0.35)'
                  : '0 12px 32px rgba(26,41,74,0.12)'
              }}
              onMouseLeave={e => {
                const el = e.currentTarget as HTMLElement
                el.style.transform = 'translateY(0)'
                el.style.boxShadow = c.dark
                  ? '0 2px 8px rgba(0,0,0,0.15)'
                  : '0 1px 3px rgba(0,0,0,0.05)'
              }}
            >
              {/* Topo: ícone + badge LIVE */}
              <div className="flex items-start justify-between">
                <div
                  style={{
                    width: '40px', height: '40px',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    backgroundColor: c.iconBg,
                    borderRadius: '2px',
                  }}
                >
                  <Icon size={19} style={{ color: c.iconCor }} />
                </div>
                {c.dark && (
                  <span style={{
                    backgroundColor: 'rgba(255,255,255,0.06)',
                    border: '1px solid rgba(255,255,255,0.12)',
                    borderRadius: '2px',
                    fontSize: '9px', fontWeight: 900,
                    letterSpacing: '0.1em', textTransform: 'uppercase',
                    color: 'rgba(255,255,255,0.45)',
                    padding: '3px 7px',
                  }}>
                    LIVE
                  </span>
                )}
              </div>

              {/* Rodapé: número + label */}
              <div>
                <p
                  className="text-3xl font-black tabular-nums"
                  style={{ color: c.dark ? '#fff' : '#0E1A33', lineHeight: 1 }}
                >
                  {loading ? '—' : c.count}
                </p>
                <p
                  className="text-[11px] font-semibold uppercase tracking-widest mt-1.5"
                  style={{ color: c.dark ? 'rgba(255,255,255,0.45)' : '#53648A' }}
                >
                  {c.label}
                </p>
                <p
                  className="text-[10px] mt-0.5 hidden sm:block"
                  style={{ color: c.dark ? 'rgba(255,255,255,0.25)' : '#ABB5C9' }}
                >
                  {c.sub}
                </p>
              </div>
            </div>
          )
        })}
      </div>

      {/* ── Filtros ── */}
      <div className="card-light p-4">
        <div className="flex flex-col md:flex-row gap-3">
          {/* Search */}
          <div className="relative flex-1">
            <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2" style={{ color: '#A8B8C2' }} />
            <input
              type="text"
              placeholder="Buscar por código, endereço ou cliente..."
              value={busca}
              onChange={(e) => setBusca(e.target.value)}
              className="input-light pl-9 w-full"
            />
          </div>

          {/* Status filter */}
          <select
            value={filtroStatus}
            onChange={(e) => setFiltroStatus(e.target.value)}
            className="select-light w-full md:w-auto"
            style={{ minWidth: '160px' }}
          >
            {STATUS_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </select>
        </div>

        {/* Quick filter pills */}
        <div className="flex gap-2 mt-3 flex-wrap">
          {STATUS_OPTIONS.slice(0, 5).map((opt) => (
            <button
              key={opt.value}
              onClick={() => setFiltroStatus(opt.value)}
              className="px-3 py-1 rounded text-[11px] font-semibold transition-all"
              style={
                filtroStatus === opt.value
                  ? { backgroundColor: '#3A5464', color: '#fff' }
                  : { backgroundColor: '#F0F2F4', color: '#6B7E8A' }
              }
              onMouseEnter={(e) => {
                if (filtroStatus !== opt.value) {
                  (e.currentTarget as HTMLElement).style.backgroundColor = '#E2E8EC'
                }
              }}
              onMouseLeave={(e) => {
                if (filtroStatus !== opt.value) {
                  (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
                }
              }}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </div>

      {/* ── Listagem de Escoltas ── */}
      {loading ? (
        <div className="py-16 flex items-center justify-center gap-3">
          <div className="w-5 h-5 rounded border-2 border-t-transparent animate-spin"
            style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
          <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando escoltas...</span>
        </div>
      ) : (
        <div className="space-y-6">
          {/* Seção 1: Não Iniciadas */}
          {filtroStatus === 'todos' || ['rascunho', 'agendada', 'em_pre_inicio'].includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#D97706', flexShrink: 0 }} />
                Escoltas Não Iniciadas
                <span className="badge-warning ml-auto">{naoIniciadas.length}</span>
              </div>
              {renderTabelaEscoltas(naoIniciadas, 'Nenhuma escolta pendente ou não iniciada no momento.')}
            </div>
          ) : null}

          {/* Seção 2: Ativas */}
          {filtroStatus === 'todos' || ['em_andamento', 'na_origem', 'no_destino', 'retornando', 'na_base'].includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#53648A', flexShrink: 0 }} />
                Escoltas Ativas / Em Rota
                <span className="badge-info ml-auto">{ativas.length}</span>
              </div>
              {renderTabelaEscoltas(ativas, 'Nenhuma escolta ativa ou em rota no momento.')}
            </div>
          ) : null}

          {/* Seção 3: Histórico */}
          {filtroStatus === 'todos' || ['finalizada', 'cancelada'].includes(filtroStatus) ? (
            <div className="space-y-0">
              <div className="cc-panel-header">
                <div style={{ width: '6px', height: '6px', borderRadius: '1px', backgroundColor: '#ABB5C9', flexShrink: 0 }} />
                Histórico de Escoltas
                <span className="badge-neutral ml-auto">{concluidas.length}</span>
              </div>
              {renderTabelaEscoltas(concluidas, 'Nenhuma escolta registrada no histórico.')}
            </div>
          ) : null}
        </div>
      )}
    </div>
  )
}
