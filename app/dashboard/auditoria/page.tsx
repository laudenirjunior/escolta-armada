'use client'

import { useEffect, useState, useCallback } from 'react'
import {
  ShieldAlert, Search, ChevronDown, ChevronRight, ChevronLeft,
  Calendar, Filter,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const supabase = createClient()
const sb = supabase as any

const PAGE_SIZE = 50

// ── Types ──────────────────────────────────────────────────────────────────

interface LogRow {
  id: string
  acao: string
  entidade_afetada: string
  registro_id: string | null
  dados_antes: Record<string, unknown> | null
  dados_depois: Record<string, unknown> | null
  data_hora: string
  ip: string | null
  usuario: { nome_completo: string } | null
  expanded?: boolean
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const ACAO_BADGE: Record<string, string> = {
  CREATE: 'badge-success',
  UPDATE: 'badge-info',
  DELETE: 'badge-danger',
  LOGIN: 'badge-neutral',
  LOGOUT: 'badge-neutral',
}

const ACAO_LABEL: Record<string, string> = {
  CREATE: 'Criação',
  UPDATE: 'Atualização',
  DELETE: 'Exclusão',
  LOGIN: 'Login',
  LOGOUT: 'Logout',
}

function badgeAcao(acao: string): string {
  const upper = acao.toUpperCase()
  return ACAO_BADGE[upper] ?? 'badge-neutral'
}

function labelAcao(acao: string): string {
  const upper = acao.toUpperCase()
  return ACAO_LABEL[upper] ?? acao
}

type RangeOpt = 'hoje' | '7dias' | '30dias' | 'custom'

// ── Page ──────────────────────────────────────────────────────────────────

export default function AuditoriaPage() {
  useAuth()
  const [logs, setLogs] = useState<LogRow[]>([])
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(0)
  const [total, setTotal] = useState(0)

  // Filters
  const [range, setRange] = useState<RangeOpt>('7dias')
  const [customStart, setCustomStart] = useState('')
  const [customEnd, setCustomEnd] = useState('')
  const [filtroAcao, setFiltroAcao] = useState('all')
  const [filtroEntidade, setFiltroEntidade] = useState('all')
  const [busca, setBusca] = useState('')

  function buildDateRange(): { from: string; to: string } {
    const now = new Date()
    const to = now.toISOString()
    if (range === 'hoje') {
      const start = new Date(now); start.setHours(0, 0, 0, 0)
      return { from: start.toISOString(), to }
    }
    if (range === '7dias') {
      const start = new Date(now); start.setDate(start.getDate() - 7)
      return { from: start.toISOString(), to }
    }
    if (range === '30dias') {
      const start = new Date(now); start.setDate(start.getDate() - 30)
      return { from: start.toISOString(), to }
    }
    // custom
    return {
      from: customStart ? new Date(customStart).toISOString() : new Date(0).toISOString(),
      to: customEnd ? new Date(customEnd + 'T23:59:59').toISOString() : to,
    }
  }

  const carregar = useCallback(async () => {
    setLoading(true)
    const { from, to } = buildDateRange()

    let q = sb.from('logs_auditoria')
      .select('id, acao, entidade_afetada, registro_id, dados_antes, dados_depois, data_hora, ip, usuario:usuarios(nome_completo)', { count: 'exact' })
      .gte('data_hora', from)
      .lte('data_hora', to)
      .order('data_hora', { ascending: false })
      .range(page * PAGE_SIZE, (page + 1) * PAGE_SIZE - 1)

    if (filtroAcao !== 'all') q = q.ilike('acao', filtroAcao)
    if (filtroEntidade !== 'all') q = q.ilike('entidade_afetada', filtroEntidade)

    const { data, count } = await q
    setLogs((data ?? []) as LogRow[])
    setTotal(count ?? 0)
    setLoading(false)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, range, customStart, customEnd, filtroAcao, filtroEntidade])

  useEffect(() => {
    setPage(0)
  }, [range, customStart, customEnd, filtroAcao, filtroEntidade])

  useEffect(() => {
    carregar()
  }, [carregar])

  const toggleExpand = (id: string) => {
    setLogs((prev) => prev.map((l) => l.id === id ? { ...l, expanded: !l.expanded } : l))
  }

  const filtradosBusca = logs.filter((l) => {
    if (!busca) return true
    const t = busca.toLowerCase()
    return (
      l.usuario?.nome_completo.toLowerCase().includes(t) ||
      l.entidade_afetada.toLowerCase().includes(t) ||
      l.acao.toLowerCase().includes(t) ||
      l.registro_id?.toLowerCase().includes(t)
    )
  })

  const totalPages = Math.ceil(total / PAGE_SIZE)

  return (
    <div className="space-y-5">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="page-title">Auditoria</h1>
          <p className="page-subtitle">
            Trilha de auditoria · {total} registro{total !== 1 ? 's' : ''} encontrado{total !== 1 ? 's' : ''}
          </p>
        </div>
      </div>

      {/* ── Filters ── */}
      <div className="card-light p-4 space-y-3">
        {/* Date range pills */}
        <div className="flex flex-wrap gap-2">
          <div className="flex items-center gap-1 mr-2">
            <Calendar size={13} style={{ color: '#6B7E8A' }} />
            <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>
              Período:
            </span>
          </div>
          {([
            { key: 'hoje', label: 'Hoje' },
            { key: '7dias', label: 'Últimos 7 dias' },
            { key: '30dias', label: 'Últimos 30 dias' },
            { key: 'custom', label: 'Personalizado' },
          ] as const).map((opt) => (
            <button
              key={opt.key}
              onClick={() => setRange(opt.key)}
              className="px-3 py-1 text-[10px] font-black uppercase tracking-wider transition-all"
              style={range === opt.key
                ? { backgroundColor: '#1A294A', color: '#fff', borderRadius: '1px' }
                : { backgroundColor: '#F0F2F4', color: '#6B7E8A', borderRadius: '1px' }
              }
              onMouseEnter={(e) => {
                if (range !== opt.key) (e.currentTarget as HTMLElement).style.backgroundColor = '#E2E8EC'
              }}
              onMouseLeave={(e) => {
                if (range !== opt.key) (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
              }}
            >
              {opt.label}
            </button>
          ))}
        </div>

        {/* Custom date range */}
        {range === 'custom' && (
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
            <input type="date" value={customStart}
              onChange={(e) => setCustomStart(e.target.value)}
              className="input-light text-xs w-full sm:w-auto" />
            <span className="text-xs hidden sm:block" style={{ color: '#6B7E8A' }}>até</span>
            <input type="date" value={customEnd}
              onChange={(e) => setCustomEnd(e.target.value)}
              className="input-light text-xs w-full sm:w-auto" />
          </div>
        )}

        {/* Second row filters */}
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center sm:gap-3">
          {/* Search */}
          <div className="relative w-full sm:flex-1 sm:min-w-48">
            <Search size={13} className="absolute left-3 top-1/2 -translate-y-1/2" style={{ color: '#A8B8C2' }} />
            <input type="text" placeholder="Buscar por usuário, entidade..."
              value={busca} onChange={(e) => setBusca(e.target.value)}
              className="input-light pl-9 text-xs w-full" />
          </div>

          {/* Action filter */}
          <div className="flex items-center gap-1.5 w-full sm:w-auto">
            <Filter size={13} style={{ color: '#6B7E8A', flexShrink: 0 }} />
            <select value={filtroAcao} onChange={(e) => setFiltroAcao(e.target.value)}
              className="select-light text-xs w-full sm:w-auto" style={{ minWidth: '130px' }}>
              <option value="all">Todas as ações</option>
              <option value="CREATE">Criação</option>
              <option value="UPDATE">Atualização</option>
              <option value="DELETE">Exclusão</option>
              <option value="LOGIN">Login</option>
            </select>
          </div>

          {/* Entity filter */}
          <select value={filtroEntidade} onChange={(e) => setFiltroEntidade(e.target.value)}
            className="select-light text-xs w-full sm:w-auto" style={{ minWidth: '140px' }}>
            <option value="all">Todas as entidades</option>
            <option value="escoltas">Escoltas</option>
            <option value="vigilantes">Vigilantes</option>
            <option value="armamentos">Armamentos</option>
            <option value="usuarios">Usuários</option>
            <option value="veiculos">Veículos</option>
            <option value="clientes">Clientes</option>
          </select>
        </div>
      </div>

      {/* ── Table ── */}
      <div className="card-light">
        {loading ? (
          <div className="py-16 flex items-center justify-center gap-3">
            <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
            <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando logs...</span>
          </div>
        ) : filtradosBusca.length === 0 ? (
          <div className="py-16 text-center">
            <div className="w-12 h-12 rounded-xl mx-auto mb-3 flex items-center justify-center"
              style={{ backgroundColor: '#F0F2F4' }}>
              <ShieldAlert size={20} style={{ color: '#C8D5DC' }} />
            </div>
            <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhum log encontrado</p>
            <p className="text-xs mt-1" style={{ color: '#A8B8C2' }}>Tente ajustar os filtros</p>
          </div>
        ) : (
          <>
            {/* ── Desktop table ── */}
            <div className="hidden md:block">
              <div className="grid grid-cols-12 gap-2 px-4 py-2.5 border-b"
                style={{ borderColor: '#E2E8EC', backgroundColor: '#F4F4F9' }}>
                <div className="col-span-3 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Data / Hora</div>
                <div className="col-span-3 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Usuário</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Ação</div>
                <div className="col-span-3 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Entidade</div>
                <div className="col-span-1 text-[11px] font-bold uppercase tracking-wider text-right" style={{ color: '#6B7E8A' }}>Det.</div>
              </div>

              {filtradosBusca.map((log) => (
                <div key={log.id}>
                  <button
                    onClick={() => (log.dados_antes || log.dados_depois) ? toggleExpand(log.id) : undefined}
                    className="w-full grid grid-cols-12 gap-2 px-4 py-3 border-b text-left transition-all"
                    style={{ borderColor: '#E2E8EC', cursor: (log.dados_antes || log.dados_depois) ? 'pointer' : 'default', backgroundColor: log.expanded ? '#F8FAFC' : '' }}
                    onMouseEnter={(e) => { if (log.dados_antes || log.dados_depois) (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC' }}
                    onMouseLeave={(e) => { if (!log.expanded) (e.currentTarget as HTMLElement).style.backgroundColor = '' }}
                  >
                    <div className="col-span-3">
                      <p className="text-xs font-medium" style={{ color: '#1E2D35' }}>{new Date(log.data_hora).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' })}</p>
                      <p className="text-[11px] font-mono" style={{ color: '#6B7E8A' }}>{new Date(log.data_hora).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</p>
                    </div>
                    <div className="col-span-3">
                      <p className="text-xs font-medium truncate" style={{ color: '#1E2D35' }}>{log.usuario?.nome_completo ?? 'Sistema'}</p>
                      {log.ip && <p className="text-[10px] font-mono" style={{ color: '#A8B8C2' }}>{log.ip}</p>}
                    </div>
                    <div className="col-span-2"><span className={badgeAcao(log.acao)}>{labelAcao(log.acao)}</span></div>
                    <div className="col-span-3">
                      <p className="text-xs capitalize" style={{ color: '#1E2D35' }}>{log.entidade_afetada}</p>
                      {log.registro_id && <p className="text-[10px] font-mono truncate" style={{ color: '#A8B8C2' }}>#{log.registro_id.slice(0, 8)}</p>}
                    </div>
                    <div className="col-span-1 flex items-start justify-end">
                      {(log.dados_antes || log.dados_depois) && (log.expanded ? <ChevronDown size={14} style={{ color: '#4A90A4' }} /> : <ChevronRight size={14} style={{ color: '#C8D5DC' }} />)}
                    </div>
                  </button>

                  {log.expanded && (
                    <div className="border-b px-4 py-4" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
                      <div className="grid grid-cols-2 gap-4">
                        <div>
                          <p className="text-[10px] font-bold uppercase tracking-wider mb-2" style={{ color: '#B83832' }}>Antes</p>
                          {log.dados_antes ? (
                            <pre className="text-[10px] p-2 rounded-lg overflow-auto max-h-48 font-mono" style={{ backgroundColor: '#FEF0EE', color: '#B83832', border: '1px solid #F5C2BE' }}>{JSON.stringify(log.dados_antes, null, 2)}</pre>
                          ) : <p className="text-[11px] italic" style={{ color: '#A8B8C2' }}>— sem dados anteriores</p>}
                        </div>
                        <div>
                          <p className="text-[10px] font-bold uppercase tracking-wider mb-2" style={{ color: '#1E7C52' }}>Depois</p>
                          {log.dados_depois ? (
                            <pre className="text-[10px] p-2 rounded-lg overflow-auto max-h-48 font-mono" style={{ backgroundColor: '#EBF7F1', color: '#1E7C52', border: '1px solid #B2E4CB' }}>{JSON.stringify(log.dados_depois, null, 2)}</pre>
                          ) : <p className="text-[11px] italic" style={{ color: '#A8B8C2' }}>— sem dados posteriores</p>}
                        </div>
                      </div>
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* ── Mobile cards ── */}
            <div className="md:hidden space-y-2 p-3">
              {filtradosBusca.map((log) => (
                <div key={log.id} className="rounded-xl border overflow-hidden"
                  style={{ borderColor: '#E2E8EC', backgroundColor: log.expanded ? '#F8FAFC' : '#fff' }}>
                  <button
                    onClick={() => (log.dados_antes || log.dados_depois) ? toggleExpand(log.id) : undefined}
                    className="w-full p-3 text-left"
                    style={{ cursor: (log.dados_antes || log.dados_depois) ? 'pointer' : 'default' }}
                  >
                    <div className="flex items-start justify-between gap-2 mb-1.5">
                      <div>
                        <p className="text-xs font-medium" style={{ color: '#1E2D35' }}>{log.usuario?.nome_completo ?? 'Sistema'}</p>
                        <p className="text-[11px] font-mono" style={{ color: '#6B7E8A' }}>{new Date(log.data_hora).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' })}</p>
                      </div>
                      <div className="flex items-center gap-1.5 shrink-0">
                        <span className={badgeAcao(log.acao)}>{labelAcao(log.acao)}</span>
                        {(log.dados_antes || log.dados_depois) && (log.expanded ? <ChevronDown size={13} style={{ color: '#4A90A4' }} /> : <ChevronRight size={13} style={{ color: '#C8D5DC' }} />)}
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      <p className="text-xs capitalize" style={{ color: '#1E2D35' }}>{log.entidade_afetada}</p>
                      {log.registro_id && <p className="text-[10px] font-mono" style={{ color: '#A8B8C2' }}>#{log.registro_id.slice(0, 8)}</p>}
                    </div>
                  </button>

                  {log.expanded && (
                    <div className="border-t px-3 py-3 space-y-3" style={{ borderColor: '#E2E8EC' }}>
                      {log.dados_antes && (
                        <div>
                          <p className="text-[10px] font-bold uppercase tracking-wider mb-1.5" style={{ color: '#B83832' }}>Antes</p>
                          <pre className="text-[10px] p-2 rounded-lg overflow-auto max-h-36 font-mono" style={{ backgroundColor: '#FEF0EE', color: '#B83832', border: '1px solid #F5C2BE' }}>{JSON.stringify(log.dados_antes, null, 2)}</pre>
                        </div>
                      )}
                      {log.dados_depois && (
                        <div>
                          <p className="text-[10px] font-bold uppercase tracking-wider mb-1.5" style={{ color: '#1E7C52' }}>Depois</p>
                          <pre className="text-[10px] p-2 rounded-lg overflow-auto max-h-36 font-mono" style={{ backgroundColor: '#EBF7F1', color: '#1E7C52', border: '1px solid #B2E4CB' }}>{JSON.stringify(log.dados_depois, null, 2)}</pre>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* Pagination */}
            {totalPages > 1 && (
              <div className="flex items-center justify-between px-4 py-3 border-t"
                style={{ borderColor: '#E2E8EC' }}>
                <p className="text-xs" style={{ color: '#6B7E8A' }}>
                  Página {page + 1} de {totalPages} · {total} registros
                </p>
                <div className="flex gap-2">
                  <button
                    onClick={() => setPage((p) => Math.max(0, p - 1))}
                    disabled={page === 0}
                    className="w-8 h-8 rounded-lg flex items-center justify-center transition-all disabled:opacity-40"
                    style={{ border: '1px solid #E2E8EC', color: '#6B7E8A' }}
                    onMouseEnter={(e) => {
                      if (!e.currentTarget.disabled)
                        (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
                    }}
                    onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = ''}
                  >
                    <ChevronLeft size={14} />
                  </button>
                  <button
                    onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
                    disabled={page >= totalPages - 1}
                    className="w-8 h-8 rounded-lg flex items-center justify-center transition-all disabled:opacity-40"
                    style={{ border: '1px solid #E2E8EC', color: '#6B7E8A' }}
                    onMouseEnter={(e) => {
                      if (!e.currentTarget.disabled)
                        (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
                    }}
                    onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = ''}
                  >
                    <ChevronRight size={14} />
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
