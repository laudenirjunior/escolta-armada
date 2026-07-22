'use client'

import { useEffect, useState, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import {
  Bell, MessageSquare, Send, Search,
  AlertTriangle, Navigation, UserCheck, RefreshCw,
  Users, X, Camera, ExternalLink, Clock,
  ChevronRight, Radio, Shield, MapPin,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const sb = createClient() as any
const sbStorage = createClient()

// ─── Palette ──────────────────────────────────────────────────────────────────
const P = {
  navy:    '#1A294A',
  steel:   '#53648A',
  light:   '#ABB5C9',
  bg:      '#EEF0F5',
  surface: '#FFFFFF',
  border:  '#D4D9E6',
  text:    '#0E1A33',
  sub:     '#5A6A80',
  muted:   '#8899AA',
}

// ─── Tipo badge config ─────────────────────────────────────────────────────────
const TIPO_CONFIG: Record<string, { label: string; color: string; bg: string; icon: React.ReactNode }> = {
  ponto_controle: { label: 'Check-in',   color: '#1E7C52', bg: '#E6F4ED', icon: <Navigation size={13} /> },
  presenca:       { label: 'Presença',   color: '#7C3AED', bg: '#EDE9FE', icon: <UserCheck size={13} /> },
  ocorrencia:     { label: 'Ocorrência', color: '#B83832', bg: '#FAEAE9', icon: <AlertTriangle size={13} /> },
  status:         { label: 'Status',     color: P.steel,   bg: '#EBF0F8', icon: <RefreshCw size={13} /> },
}

// ─── Status escolta ────────────────────────────────────────────────────────────
const ESCOLTA_STATUS: Record<string, { label: string; color: string; bg: string }> = {
  rascunho:      { label: 'Rascunho',    color: '#8899AA', bg: '#EEF0F5' },
  agendada:      { label: 'Agendada',    color: '#53648A', bg: '#EBF0F8' },
  em_pre_inicio: { label: 'Pré-Início',  color: '#8B6914', bg: '#FBF3DE' },
  em_andamento:  { label: 'Em Rota',     color: '#1E7C52', bg: '#E6F4ED' },
  na_origem:     { label: 'Na Origem',   color: '#0891B2', bg: '#E0F4FA' },
  em_transito_destino: { label: 'Trânsito p/ Destino', color: '#2563EB', bg: '#E7EEFE' },
  no_destino:    { label: 'No Destino',  color: '#0891B2', bg: '#E0F4FA' },
  retornando:    { label: 'Retornando',  color: '#8B6914', bg: '#FBF3DE' },
  na_base:       { label: 'Na Base',     color: '#53648A', bg: '#EBF0F8' },
  finalizada:    { label: 'Finalizada',  color: '#53648A', bg: '#EBF0F8' },
  cancelada:     { label: 'Cancelada',   color: '#B83832', bg: '#FAEAE9' },
}

const STATUS_LABEL: Record<string, string> = {
  rascunho: 'Rascunho', agendada: 'Agendada', em_pre_inicio: 'Pré-Início',
  em_andamento: 'Em Andamento', na_origem: 'Na Origem', em_transito_destino: 'Trânsito p/ Destino', no_destino: 'No Destino',
  retornando: 'Retornando', na_base: 'Na Base', finalizada: 'Finalizada', cancelada: 'Cancelada',
}

// ─── Tipos ────────────────────────────────────────────────────────────────────
interface NotificacaoFeed {
  id: string
  tipo: string
  titulo: string
  descricao: string
  data_hora: string
  escolta_id: string | null
  escolta_codigo: string | null
  escolta_status: string | null
  cliente_nome: string | null
  efetivo: string | null
  veiculo: string | null
  foto_url: string | null
  lida: boolean
}

interface ChatUser {
  id: string
  nome_completo: string
  email: string
  perfil: { nome_exibicao: string } | null
}

interface ChatMensagem {
  id: string
  de_usuario_id: string
  mensagem: string
  lida: boolean
  criado_em: string
  de_usuario: { nome_completo: string } | null
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
function formatDH(iso: string) {
  const d = new Date(iso)
  const hoje = new Date()
  const diff = hoje.getTime() - d.getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'agora'
  if (mins < 60) return `${mins}min`
  if (mins < 1440) return `${Math.floor(mins / 60)}h`
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' })
}

function formatDHFull(iso: string) {
  return new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  })
}

function parseObservacao(raw: string | null): string {
  if (!raw) return ''
  const trimmed = raw.trim()
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      const obj = JSON.parse(trimmed)
      const parts: string[] = []
      if (obj.tipoLabel && typeof obj.tipoLabel === 'string') parts.push(obj.tipoLabel)
      if (obj.observacao && typeof obj.observacao === 'string' && obj.observacao.trim()) {
        parts.push(obj.observacao.trim())
      }
      if (obj.endereco && typeof obj.endereco === 'string') {
        const addr = obj.endereco.split(',').slice(0, 3).join(',').trim()
        parts.push(addr)
      }
      if (obj.precisao_metros && typeof obj.precisao_metros === 'number') {
        parts.push(`±${obj.precisao_metros}m`)
      }
      return parts.length > 0 ? parts.join(' · ') : trimmed
    } catch {
      return trimmed
    }
  }
  return trimmed
}

// ─── Page ─────────────────────────────────────────────────────────────────────
export default function NotificacoesPage() {
  const { user } = useAuth()
  const router = useRouter()

  const [tab, setTab] = useState<'notificacoes' | 'chat'>('notificacoes')

  const [notificacoes, setNotificacoes] = useState<NotificacaoFeed[]>([])
  const [loadingNot, setLoadingNot] = useState(true)
  const [filtroTipo, setFiltroTipo] = useState('todos')
  const [buscaNot, setBuscaNot] = useState('')
  const [selecionada, setSelecionada] = useState<NotificacaoFeed | null>(null)
  const [fotoAmpliada, setFotoAmpliada] = useState<string | null>(null)

  const [usuarios, setUsuarios] = useState<ChatUser[]>([])
  const [chatSelecionado, setChatSelecionado] = useState<ChatUser | null>(null)
  const [mensagens, setMensagens] = useState<ChatMensagem[]>([])
  const [novaMensagem, setNovaMensagem] = useState('')
  const [enviando, setEnviando] = useState(false)
  const [buscaUser, setBuscaUser] = useState('')
  const msgEndRef = useRef<HTMLDivElement>(null)

  const toPublicUrl = useCallback((path: string | null): string | null => {
    if (!path) return null
    if (path.startsWith('http')) return path
    const { data } = sbStorage.storage.from('fotos').getPublicUrl(path)
    return data?.publicUrl ?? null
  }, [])

  const carregarNotificacoes = useCallback(async () => {
    setLoadingNot(true)
    try {
      // ── Pontos de controle ──
      const { data: pts } = await sb
        .from('pontos_controle')
        .select(`
          id, data_hora, observacoes,
          tipo:dom_tipos_ponto(codigo, nome_exibicao),
          lancado_por:usuarios!lancado_por(nome_completo),
          escolta_veiculo:escolta_veiculos(
            veiculo:veiculos(placa),
            escolta:escoltas(id, codigo_escolta, status, cliente:clientes(nome_cliente))
          ),
          foto:fotos!foto_id(caminho_arquivo)
        `)
        .order('data_hora', { ascending: false })
        .limit(100)

      const feedPts: NotificacaoFeed[] = (pts ?? []).map((p: any) => ({
        id: `pc_${p.id}`,
        tipo: 'ponto_controle',
        titulo: p.tipo?.nome_exibicao ?? 'Ponto de Controle',
        descricao: parseObservacao(p.observacoes),
        data_hora: p.data_hora,
        escolta_id: p.escolta_veiculo?.escolta?.id ?? null,
        escolta_codigo: p.escolta_veiculo?.escolta?.codigo_escolta ?? null,
        escolta_status: p.escolta_veiculo?.escolta?.status ?? null,
        cliente_nome: p.escolta_veiculo?.escolta?.cliente?.nome_cliente ?? null,
        efetivo: p.lancado_por?.nome_completo ?? null,
        veiculo: p.escolta_veiculo?.veiculo?.placa ?? null,
        foto_url: toPublicUrl(p.foto?.caminho_arquivo ?? null),
        lida: false,
      }))

      // ── Ocorrências ──
      const { data: ocorrs } = await sb
        .from('ocorrencias')
        .select(`
          id, descricao, data_hora,
          tipo:dom_tipos_ocorrencia(nome),
          autor:usuarios!registrado_por(nome_completo),
          escolta:escoltas!escolta_id(id, codigo_escolta, status, cliente:clientes(nome_cliente)),
          foto:fotos!foto_id(caminho_arquivo)
        `)
        .order('data_hora', { ascending: false })
        .limit(50)

      const feedOcorrs: NotificacaoFeed[] = (ocorrs ?? []).map((o: any) => ({
        id: `oc_${o.id}`,
        tipo: 'ocorrencia',
        titulo: o.tipo?.nome ?? 'Ocorrência',
        descricao: parseObservacao(o.descricao),
        data_hora: o.data_hora,
        escolta_id: o.escolta?.id ?? null,
        escolta_codigo: o.escolta?.codigo_escolta ?? null,
        escolta_status: o.escolta?.status ?? null,
        cliente_nome: o.escolta?.cliente?.nome_cliente ?? null,
        efetivo: o.autor?.nome_completo ?? null,
        veiculo: null,
        foto_url: toPublicUrl(o.foto?.caminho_arquivo ?? null),
        lida: false,
      }))

      // ── Histórico de status ──
      const { data: hist } = await sb
        .from('escolta_status_historico')
        .select(`
          id, data_hora, status_novo, status_anterior,
          autor:usuarios!alterado_por(nome_completo),
          escolta:escoltas!escolta_id(id, codigo_escolta, status, cliente:clientes(nome_cliente))
        `)
        .not('status_novo', 'in', '(na_origem,em_transito_destino,no_destino,retornando,na_base)')
        .order('data_hora', { ascending: false })
        .limit(50)

      const feedHist: NotificacaoFeed[] = (hist ?? []).map((h: any) => ({
        id: `st_${h.id}`,
        tipo: 'status',
        titulo: STATUS_LABEL[h.status_novo] ?? h.status_novo,
        descricao: `${STATUS_LABEL[h.status_anterior] ?? h.status_anterior} → ${STATUS_LABEL[h.status_novo] ?? h.status_novo}`,
        data_hora: h.data_hora,
        escolta_id: h.escolta?.id ?? null,
        escolta_codigo: h.escolta?.codigo_escolta ?? null,
        escolta_status: h.escolta?.status ?? null,
        cliente_nome: h.escolta?.cliente?.nome_cliente ?? null,
        efetivo: h.autor?.nome_completo ?? null,
        veiculo: null,
        foto_url: null,
        lida: false,
      }))

      // ── Presenças ──
      const { data: pres } = await sb
        .from('presencas')
        .select(`
          id, data_hora,
          vigilante:vigilantes!vigilante_id(nome_completo),
          escolta:escoltas!escolta_id(id, codigo_escolta, status, cliente:clientes(nome_cliente)),
          foto:fotos!foto_id(caminho_arquivo)
        `)
        .order('data_hora', { ascending: false })
        .limit(50)

      const feedPres: NotificacaoFeed[] = (pres ?? []).map((p: any) => ({
        id: `pr_${p.id}`,
        tipo: 'presenca',
        titulo: 'Presença Confirmada',
        descricao: `${p.vigilante?.nome_completo ?? 'Vigilante'} confirmou presença na escolta`,
        data_hora: p.data_hora,
        escolta_id: p.escolta?.id ?? null,
        escolta_codigo: p.escolta?.codigo_escolta ?? null,
        escolta_status: p.escolta?.status ?? null,
        cliente_nome: p.escolta?.cliente?.nome_cliente ?? null,
        efetivo: p.vigilante?.nome_completo ?? null,
        veiculo: null,
        foto_url: toPublicUrl(p.foto?.caminho_arquivo ?? null),
        lida: false,
      }))

      const tudo = [...feedPts, ...feedOcorrs, ...feedHist, ...feedPres]
        .sort((a, b) => new Date(b.data_hora).getTime() - new Date(a.data_hora).getTime())

      setNotificacoes(tudo)
    } finally {
      setLoadingNot(false)
    }
  }, [toPublicUrl])

  const carregarUsuarios = useCallback(async () => {
    const { data } = await sb
      .from('usuarios')
      .select('id, nome_completo, email, perfil:dom_perfis(nome_exibicao)')
      .neq('id', user?.id ?? '')
      .eq('status', 'ativo')
      .order('nome_completo')
    setUsuarios((data ?? []) as ChatUser[])
  }, [user?.id])

  useEffect(() => { carregarNotificacoes() }, [carregarNotificacoes])
  useEffect(() => { carregarUsuarios() }, [carregarUsuarios])

  const carregarMensagens = useCallback(async () => {
    if (!chatSelecionado || !user) return
    const { data } = await sb
      .from('chat_mensagens')
      .select('id, de_usuario_id, mensagem, lida, criado_em, de_usuario:usuarios!de_usuario_id(nome_completo)')
      .or(`and(de_usuario_id.eq.${user.id},para_usuario_id.eq.${chatSelecionado.id}),and(de_usuario_id.eq.${chatSelecionado.id},para_usuario_id.eq.${user.id})`)
      .order('criado_em', { ascending: true })
    setMensagens((data ?? []) as ChatMensagem[])
  }, [chatSelecionado, user])

  useEffect(() => { carregarMensagens() }, [carregarMensagens])
  useEffect(() => { msgEndRef.current?.scrollIntoView({ behavior: 'smooth' }) }, [mensagens])

  useEffect(() => {
    const ch = sb.channel('notif-feed-v3')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'pontos_controle' }, () => carregarNotificacoes())
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'ocorrencias' }, () => carregarNotificacoes())
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'escolta_status_historico' }, () => carregarNotificacoes())
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'presencas' }, () => carregarNotificacoes())
      .subscribe()
    return () => { sb.removeChannel(ch) }
  }, [carregarNotificacoes])

  useEffect(() => {
    if (!chatSelecionado) return
    const ch = sb.channel('chat-msgs-v3')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'chat_mensagens' }, () => carregarMensagens())
      .subscribe()
    return () => { sb.removeChannel(ch) }
  }, [chatSelecionado, carregarMensagens])

  const enviarMensagem = async () => {
    if (!novaMensagem.trim() || !chatSelecionado || !user || enviando) return
    setEnviando(true)
    await sb.from('chat_mensagens').insert({
      de_usuario_id: user.id,
      para_usuario_id: chatSelecionado.id,
      mensagem: novaMensagem.trim(),
    })
    setNovaMensagem('')
    await carregarMensagens()
    setEnviando(false)
  }

  const notFiltradas = notificacoes.filter(n => {
    if (filtroTipo !== 'todos' && n.tipo !== filtroTipo) return false
    if (!buscaNot) return true
    const q = buscaNot.toLowerCase()
    return (
      n.titulo.toLowerCase().includes(q) ||
      (n.escolta_codigo ?? '').toLowerCase().includes(q) ||
      (n.cliente_nome ?? '').toLowerCase().includes(q) ||
      (n.efetivo ?? '').toLowerCase().includes(q) ||
      (n.descricao ?? '').toLowerCase().includes(q)
    )
  })

  const usuariosFiltrados = usuarios.filter(u =>
    !buscaUser || u.nome_completo.toLowerCase().includes(buscaUser.toLowerCase())
  )

  const counts = {
    total: notificacoes.length,
    ponto_controle: notificacoes.filter(n => n.tipo === 'ponto_controle').length,
    ocorrencia: notificacoes.filter(n => n.tipo === 'ocorrencia').length,
    status: notificacoes.filter(n => n.tipo === 'status').length,
    presenca: notificacoes.filter(n => n.tipo === 'presenca').length,
    comFoto: notificacoes.filter(n => n.foto_url).length,
  }

  const cfg = (tipo: string) => TIPO_CONFIG[tipo] ?? { label: tipo, color: P.muted, bg: P.bg, icon: <Bell size={13} /> }

  return (
    <>
    <div className="flex flex-col gap-4 md:gap-5">

      {/* ── Header ── */}
      <div className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-3">
        <div>
          <div className="eyebrow-tag mb-2">
            <Radio size={10} />Central de Comunicações · Tempo Real
          </div>
          <h1 className="page-title" style={{ marginBottom: '2px' }}>Notificações & Chat</h1>
          <p className="page-subtitle">{loadingNot ? 'Carregando...' : `${counts.total} eventos · ${counts.comFoto} com foto`}</p>
        </div>

        {/* Tabs */}
        <div className="flex gap-0.5 self-start sm:self-auto shrink-0" style={{ backgroundColor: '#E2E6F0', padding: '3px', borderRadius: '3px' }}>
          {([
            { key: 'notificacoes', label: 'Notificações', icon: <Bell size={12} /> },
            { key: 'chat', label: 'Chat Interno', icon: <MessageSquare size={12} /> },
          ] as const).map(t => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              style={{
                display: 'flex', alignItems: 'center', gap: '6px',
                padding: '8px 12px', borderRadius: '2px', fontSize: '11px', fontWeight: 900,
                textTransform: 'uppercase', letterSpacing: '0.11em', border: 'none', cursor: 'pointer',
                transition: 'all 180ms', minHeight: '40px',
                backgroundColor: tab === t.key ? P.navy : 'transparent',
                color: tab === t.key ? '#fff' : P.sub,
                boxShadow: tab === t.key ? '0 1px 4px rgba(26,41,74,0.3)' : 'none',
              }}
            >
              {t.icon}<span className="hidden xs:inline sm:hidden md:inline">{t.label}</span>
              {t.key === 'notificacoes' && counts.total > 0 && (
                <span style={{ backgroundColor: tab === 'notificacoes' ? 'rgba(255,255,255,0.2)' : '#B83832', color: '#fff', borderRadius: '10px', fontSize: '9px', fontWeight: 900, padding: '1px 6px', minWidth: '18px', textAlign: 'center' }}>
                  {counts.total}
                </span>
              )}
            </button>
          ))}
        </div>
      </div>

      {/* ══════════ NOTIFICAÇÕES ══════════ */}
      {tab === 'notificacoes' && (
        <div className={`grid gap-3 md:gap-4 items-start ${selecionada ? 'grid-cols-1 lg:grid-cols-[1fr_340px]' : 'grid-cols-1 lg:grid-cols-[1fr_200px]'}`}>

          {/* ── Feed principal ── */}
          <div className="flex flex-col gap-3">

            {/* Barra de busca */}
            <div className="flex gap-2 items-center">
              <div style={{ position: 'relative', flex: 1 }}>
                <Search size={13} style={{ position: 'absolute', left: '11px', top: '50%', transform: 'translateY(-50%)', color: P.light, pointerEvents: 'none' }} />
                <input
                  value={buscaNot}
                  onChange={e => setBuscaNot(e.target.value)}
                  placeholder="Buscar por escolta, cliente, efetivo..."
                  style={{ width: '100%', paddingLeft: '34px', paddingRight: '12px', height: '44px', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', fontSize: '13px', color: P.text, outline: 'none', boxSizing: 'border-box' }}
                />
              </div>
              <button
                onClick={carregarNotificacoes}
                style={{ width: '44px', height: '44px', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', cursor: 'pointer', color: P.steel, flexShrink: 0 }}
                title="Atualizar"
              >
                <RefreshCw size={14} />
              </button>
            </div>

            {/* Filtros de tipo — scroll horizontal no mobile */}
            <div className="flex gap-1.5 overflow-x-auto pb-1" style={{ scrollbarWidth: 'none' }}>
              {[
                { key: 'todos',          label: 'Todos',       count: counts.total },
                { key: 'ponto_controle', label: 'Check-ins',   count: counts.ponto_controle },
                { key: 'ocorrencia',     label: 'Ocorrências', count: counts.ocorrencia },
                { key: 'status',         label: 'Status',      count: counts.status },
                { key: 'presenca',       label: 'Presenças',   count: counts.presenca },
              ].map(f => (
                <button
                  key={f.key}
                  onClick={() => setFiltroTipo(f.key)}
                  style={{
                    display: 'flex', alignItems: 'center', gap: '5px', flexShrink: 0,
                    padding: '0 12px', height: '36px', borderRadius: '2px',
                    fontSize: '10px', fontWeight: 800, textTransform: 'uppercase', letterSpacing: '0.1em',
                    border: 'none', cursor: 'pointer', transition: 'all 150ms',
                    backgroundColor: filtroTipo === f.key ? P.navy : P.surface,
                    color: filtroTipo === f.key ? '#fff' : P.sub,
                    boxShadow: filtroTipo === f.key ? '0 1px 4px rgba(26,41,74,0.2)' : `inset 0 0 0 1px ${P.border}`,
                  }}
                >
                  {f.label}
                  <span style={{
                    fontSize: '9px', fontWeight: 900, padding: '1px 5px', borderRadius: '8px',
                    backgroundColor: filtroTipo === f.key ? 'rgba(255,255,255,0.2)' : P.bg,
                    color: filtroTipo === f.key ? '#fff' : P.muted,
                    minWidth: '16px', textAlign: 'center',
                  }}>
                    {f.count}
                  </span>
                </button>
              ))}
            </div>

            {/* Contador de resultados */}
            {(buscaNot || filtroTipo !== 'todos') && (
              <p style={{ fontSize: '10px', color: P.muted, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '0.1em' }}>
                {notFiltradas.length} resultado{notFiltradas.length !== 1 ? 's' : ''}
                {filtroTipo !== 'todos' && ` · ${cfg(filtroTipo).label}`}
              </p>
            )}

            {/* Lista de eventos */}
            {loadingNot ? (
              <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                {Array.from({ length: 6 }).map((_, i) => (
                  <div key={i} className="animate-pulse" style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', height: '96px', opacity: 1 - i * 0.12 }} />
                ))}
              </div>
            ) : notFiltradas.length === 0 ? (
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '60px 24px', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', gap: '10px' }}>
                <Bell size={28} style={{ color: P.light }} />
                <p style={{ fontSize: '13px', color: P.sub, fontWeight: 600 }}>Nenhum evento encontrado</p>
                <p style={{ fontSize: '11px', color: P.muted }}>Tente ajustar os filtros ou a busca</p>
              </div>
            ) : (
              <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                {notFiltradas.map(n => {
                  const c = cfg(n.tipo)
                  const isSelected = selecionada?.id === n.id
                  const escStatus = n.escolta_status ? ESCOLTA_STATUS[n.escolta_status] : null

                  return (
                    <div
                      key={n.id}
                      onClick={() => setSelecionada(isSelected ? null : n)}
                      style={{
                        backgroundColor: isSelected ? '#F0F4FF' : P.surface,
                        border: `1px solid ${isSelected ? '#C0CAE8' : P.border}`,
                        borderLeft: `4px solid ${c.color}`,
                        borderRadius: '2px',
                        padding: '14px 14px',
                        cursor: 'pointer',
                        transition: 'all 150ms',
                        display: 'flex',
                        alignItems: 'stretch',
                        gap: '12px',
                        minHeight: '72px',
                        boxShadow: isSelected ? '0 2px 10px rgba(83,100,138,0.14)' : 'none',
                      }}
                      onMouseEnter={e => {
                        if (!isSelected) {
                          (e.currentTarget as HTMLElement).style.backgroundColor = '#F8F9FC'
                          ;(e.currentTarget as HTMLElement).style.boxShadow = '0 1px 4px rgba(26,41,74,0.06)'
                        }
                      }}
                      onMouseLeave={e => {
                        if (!isSelected) {
                          (e.currentTarget as HTMLElement).style.backgroundColor = P.surface
                          ;(e.currentTarget as HTMLElement).style.boxShadow = 'none'
                        }
                      }}
                    >
                      {/* Ícone do tipo */}
                      <div style={{
                        width: '36px', height: '36px', borderRadius: '2px',
                        backgroundColor: c.bg, flexShrink: 0,
                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                        color: c.color, marginTop: '2px',
                      }}>
                        {c.icon}
                      </div>

                      {/* Conteúdo principal */}
                      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: '5px' }}>

                        {/* Linha 1: badge tipo + código + cliente */}
                        <div style={{ display: 'flex', alignItems: 'center', gap: '6px', flexWrap: 'wrap' }}>
                          <span style={{
                            fontSize: '8px', fontWeight: 900, textTransform: 'uppercase',
                            letterSpacing: '0.16em', padding: '2px 7px', borderRadius: '2px',
                            backgroundColor: c.bg, color: c.color, flexShrink: 0,
                          }}>
                            {c.label}
                          </span>
                          {n.escolta_codigo && (
                            <span style={{
                              fontSize: '10px', fontWeight: 800, color: P.navy,
                              fontFamily: 'monospace', backgroundColor: '#E8EBF5',
                              padding: '2px 7px', borderRadius: '2px', flexShrink: 0, letterSpacing: '0.04em',
                            }}>
                              {n.escolta_codigo}
                            </span>
                          )}
                          {n.cliente_nome && (
                            <span style={{
                              fontSize: '11px', fontWeight: 600, color: P.sub,
                              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                              maxWidth: '200px',
                            }}>
                              {n.cliente_nome}
                            </span>
                          )}
                        </div>

                        {/* Linha 2: título do evento */}
                        <p style={{ fontSize: '13px', fontWeight: 800, color: P.text, lineHeight: 1.25 }}>
                          {n.titulo}
                        </p>

                        {/* Linha 3: status atual da escolta */}
                        {escStatus && (
                          <span style={{
                            alignSelf: 'flex-start',
                            fontSize: '9px', fontWeight: 900, textTransform: 'uppercase',
                            letterSpacing: '0.12em', padding: '2px 8px', borderRadius: '2px',
                            backgroundColor: escStatus.bg, color: escStatus.color,
                          }}>
                            {escStatus.label}
                          </span>
                        )}

                        {/* Linha 4: efetivo + viatura + foto badge */}
                        <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flexWrap: 'wrap' }}>
                          {n.efetivo && (
                            <span style={{ fontSize: '10px', color: P.muted, display: 'flex', alignItems: 'center', gap: '4px' }}>
                              <UserCheck size={10} style={{ flexShrink: 0 }} />
                              {n.efetivo.split(' ').slice(0, 2).join(' ')}
                            </span>
                          )}
                          {n.veiculo && (
                            <span style={{ fontSize: '10px', color: P.muted, fontFamily: 'monospace', display: 'flex', alignItems: 'center', gap: '4px' }}>
                              <Shield size={10} style={{ flexShrink: 0 }} />
                              {n.veiculo}
                            </span>
                          )}
                          {n.foto_url && (
                            <span style={{ fontSize: '10px', color: '#1E7C52', fontWeight: 700, display: 'flex', alignItems: 'center', gap: '4px' }}>
                              <Camera size={10} style={{ flexShrink: 0 }} />
                              Foto
                            </span>
                          )}
                        </div>

                        {/* Linha 5: descrição (máx 2 linhas) */}
                        {n.descricao && (
                          <p style={{
                            fontSize: '11px', color: P.sub, lineHeight: 1.45,
                            display: '-webkit-box',
                            WebkitLineClamp: 2,
                            WebkitBoxOrient: 'vertical',
                            overflow: 'hidden',
                          }}>
                            {n.descricao}
                          </p>
                        )}
                      </div>

                      {/* Foto thumbnail — visível sempre que houver foto */}
                      {n.foto_url && (
                        <div
                          style={{
                            width: '64px', height: '64px', flexShrink: 0,
                            borderRadius: '2px', overflow: 'hidden',
                            border: `1px solid ${P.border}`,
                            position: 'relative', cursor: 'pointer',
                            alignSelf: 'center',
                            boxShadow: '0 1px 4px rgba(0,0,0,0.1)',
                          }}
                          onClick={e => { e.stopPropagation(); setFotoAmpliada(n.foto_url!) }}
                          title="Ver foto em tamanho real"
                        >
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img
                            src={n.foto_url}
                            alt="foto"
                            style={{ width: '100%', height: '100%', objectFit: 'cover', display: 'block' }}
                            onError={e => {
                              const el = e.target as HTMLImageElement
                              el.style.display = 'none'
                              const p = el.parentElement
                              if (p) {
                                p.style.backgroundColor = P.bg
                                p.style.display = 'flex'
                                p.style.alignItems = 'center'
                                p.style.justifyContent = 'center'
                              }
                            }}
                          />
                          <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(to bottom, transparent 50%, rgba(0,0,0,0.18))', pointerEvents: 'none' }} />
                          <div style={{ position: 'absolute', bottom: '3px', right: '3px', fontSize: '7px', color: 'rgba(255,255,255,0.8)', fontWeight: 700 }}>
                            ⊕
                          </div>
                        </div>
                      )}

                      {/* Timestamp + seta */}
                      <div style={{ flexShrink: 0, display: 'flex', flexDirection: 'column', alignItems: 'flex-end', justifyContent: 'space-between', paddingLeft: '4px' }}>
                        <span style={{ fontSize: '10px', fontWeight: 700, color: P.muted, fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
                          {formatDH(n.data_hora)}
                        </span>
                        <ChevronRight size={13} style={{ color: isSelected ? P.steel : P.light, transition: 'color 150ms' }} />
                      </div>
                    </div>
                  )
                })}
              </div>
            )}
          </div>

          {/* ── Painel lateral (hidden on mobile unless selected) ── */}
          <div className={`flex-col gap-2.5 lg:flex ${selecionada ? 'flex' : 'hidden lg:flex'}`} style={{ position: 'sticky', top: '16px' }}>

            {selecionada ? (
              /* Detalhe do evento selecionado */
              <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', overflow: 'hidden', borderTop: `3px solid ${cfg(selecionada.tipo).color}` }}>
                <div style={{ padding: '12px 14px', borderBottom: `1px solid ${P.border}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                    <div style={{ color: cfg(selecionada.tipo).color }}>{cfg(selecionada.tipo).icon}</div>
                    <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.14em', color: P.sub }}>
                      {cfg(selecionada.tipo).label}
                    </span>
                  </div>
                  <button onClick={() => setSelecionada(null)} style={{ background: 'none', border: 'none', cursor: 'pointer', color: P.muted, padding: '2px' }}>
                    <X size={13} />
                  </button>
                </div>

                <div style={{ padding: '14px' }}>
                  {selecionada.foto_url && (
                    <div
                      style={{ borderRadius: '2px', overflow: 'hidden', marginBottom: '14px', cursor: 'pointer', position: 'relative', border: `1px solid ${P.border}` }}
                      onClick={() => setFotoAmpliada(selecionada.foto_url!)}
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={selecionada.foto_url} alt="foto" style={{ width: '100%', height: '180px', objectFit: 'cover', display: 'block' }} onError={e => { (e.target as HTMLImageElement).parentElement!.style.display = 'none' }} />
                      <div style={{ position: 'absolute', bottom: '8px', right: '8px', backgroundColor: 'rgba(0,0,0,0.6)', borderRadius: '2px', padding: '4px 8px', display: 'flex', alignItems: 'center', gap: '4px' }}>
                        <span style={{ fontSize: '9px', color: '#fff', fontWeight: 700 }}>Ampliar</span>
                      </div>
                    </div>
                  )}

                  <p style={{ fontSize: '15px', fontWeight: 900, color: P.text, marginBottom: '6px', lineHeight: 1.3 }}>{selecionada.titulo}</p>

                  {selecionada.cliente_nome && (
                    <p style={{ fontSize: '12px', color: P.steel, fontWeight: 600, marginBottom: '4px' }}>{selecionada.cliente_nome}</p>
                  )}

                  {selecionada.descricao && (
                    <p style={{ fontSize: '12px', color: P.sub, marginBottom: '14px', lineHeight: 1.55 }}>{selecionada.descricao}</p>
                  )}

                  <div style={{ display: 'flex', flexDirection: 'column', gap: '8px', borderTop: `1px solid ${P.border}`, paddingTop: '12px' }}>
                    {[
                      { label: 'Data/Hora', value: formatDHFull(selecionada.data_hora), icon: <Clock size={10} /> },
                      selecionada.escolta_codigo ? { label: 'Escolta', value: selecionada.escolta_codigo, icon: <Shield size={10} />, mono: true } : null,
                      selecionada.cliente_nome ? { label: 'Cliente', value: selecionada.cliente_nome, icon: <UserCheck size={10} /> } : null,
                      selecionada.escolta_status ? {
                        label: 'Status atual', value: ESCOLTA_STATUS[selecionada.escolta_status]?.label ?? selecionada.escolta_status, icon: <Radio size={10} />,
                      } : null,
                      selecionada.efetivo ? { label: 'Efetivo', value: selecionada.efetivo, icon: <UserCheck size={10} /> } : null,
                      selecionada.veiculo ? { label: 'Viatura', value: selecionada.veiculo, icon: <Navigation size={10} />, mono: true } : null,
                    ].filter(Boolean).map((row: any) => (
                      <div key={row.label} style={{ display: 'flex', alignItems: 'flex-start', gap: '8px' }}>
                        <span style={{ color: P.muted, marginTop: '1px', flexShrink: 0 }}>{row.icon}</span>
                        <div style={{ minWidth: 0 }}>
                          <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.muted, marginBottom: '1px' }}>{row.label}</p>
                          <p style={{ fontSize: '11px', fontWeight: 700, color: P.text, fontFamily: row.mono ? 'monospace' : 'inherit' }}>{row.value}</p>
                        </div>
                      </div>
                    ))}
                  </div>

                  {selecionada.escolta_id && (
                    <button
                      onClick={() => router.push(`/dashboard/escoltas/${selecionada.escolta_id}`)}
                      style={{
                        width: '100%', marginTop: '14px', padding: '12px 14px',
                        minHeight: '48px',
                        backgroundColor: P.navy, color: '#fff', border: 'none', borderRadius: '2px',
                        fontSize: '11px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em',
                        cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '6px',
                        transition: 'all 150ms',
                      }}
                      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#253562' }}
                      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = P.navy }}
                    >
                      <ExternalLink size={12} />
                      Abrir Escolta {selecionada.escolta_codigo}
                    </button>
                  )}
                </div>
              </div>
            ) : (
              /* Resumo quando nada selecionado */
              <div style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', overflow: 'hidden' }}>
                <div className="cc-panel-header">
                  <div style={{ width: '4px', height: '4px', borderRadius: '50%', backgroundColor: '#1E7C52' }} />
                  Resumo do Feed
                </div>
                <div style={{ padding: '2px 0' }}>
                  {[
                    { label: 'Total de eventos', value: counts.total, color: P.navy },
                    { label: 'Check-ins',         value: counts.ponto_controle, color: '#1E7C52' },
                    { label: 'Ocorrências',       value: counts.ocorrencia, color: '#B83832' },
                    { label: 'Mudanças status',   value: counts.status, color: P.steel },
                    { label: 'Presenças',         value: counts.presenca, color: '#7C3AED' },
                    { label: 'Com foto',          value: counts.comFoto, color: '#0891B2' },
                  ].map((r, i, arr) => (
                    <div key={r.label} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 14px', borderBottom: i < arr.length - 1 ? `1px solid ${P.border}` : 'none' }}>
                      <span style={{ fontSize: '11px', color: P.sub }}>{r.label}</span>
                      <span style={{ fontSize: '15px', fontWeight: 900, color: r.color, fontVariantNumeric: 'tabular-nums' }}>{r.value}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {!selecionada && (
              <div style={{ backgroundColor: '#EBF0F8', border: `1px solid #C8D4E8`, borderRadius: '2px', padding: '10px 12px' }}>
                <p style={{ fontSize: '10px', color: P.steel, fontWeight: 700, lineHeight: 1.5 }}>
                  💡 Clique em qualquer evento para ver todos os detalhes e abrir a escolta correspondente.
                </p>
              </div>
            )}
          </div>
        </div>
      )}

      {/* ══════════ CHAT ══════════ */}
      {tab === 'chat' && (
        <div className="grid grid-cols-1 md:grid-cols-[240px_1fr] gap-3" style={{ height: 'calc(100vh - 260px)', minHeight: '480px' }}>

          {/* Lista de usuários — visível quando nenhum chat selecionado no mobile */}
          <div
            className={`flex flex-col overflow-hidden ${chatSelecionado ? 'hidden md:flex' : 'flex'}`}
            style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px' }}
          >
            <div className="cc-panel-header">
              <Users size={11} />Conversas
            </div>
            <div style={{ padding: '8px', borderBottom: `1px solid ${P.border}` }}>
              <div style={{ position: 'relative' }}>
                <Search size={12} style={{ position: 'absolute', left: '8px', top: '50%', transform: 'translateY(-50%)', color: P.light, pointerEvents: 'none' }} />
                <input
                  value={buscaUser}
                  onChange={e => setBuscaUser(e.target.value)}
                  placeholder="Buscar..."
                  style={{ width: '100%', paddingLeft: '28px', height: '36px', backgroundColor: P.bg, border: `1px solid ${P.border}`, borderRadius: '2px', fontSize: '12px', color: P.text, outline: 'none', boxSizing: 'border-box' }}
                />
              </div>
            </div>
            <div style={{ flex: 1, overflowY: 'auto' }}>
              {usuariosFiltrados.length === 0 ? (
                <p style={{ textAlign: 'center', fontSize: '11px', color: P.muted, padding: '20px 12px' }}>Nenhum usuário</p>
              ) : usuariosFiltrados.map(u => (
                <button
                  key={u.id}
                  onClick={() => setChatSelecionado(u)}
                  style={{
                    width: '100%', textAlign: 'left', padding: '11px 12px',
                    minHeight: '56px',
                    display: 'flex', alignItems: 'center', gap: '9px',
                    backgroundColor: chatSelecionado?.id === u.id ? '#EBF0F8' : 'transparent',
                    borderLeft: `3px solid ${chatSelecionado?.id === u.id ? P.steel : 'transparent'}`,
                    border: 'none', borderBottom: `1px solid ${P.border}`, cursor: 'pointer',
                    transition: 'all 150ms',
                  }}
                >
                  <div style={{ width: '34px', height: '34px', borderRadius: '2px', flexShrink: 0, background: `linear-gradient(135deg, ${P.steel}, ${P.navy})`, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: '11px', fontWeight: 900 }}>
                    {u.nome_completo.split(' ').slice(0, 2).map(n => n[0]).join('')}
                  </div>
                  <div style={{ minWidth: 0 }}>
                    <p style={{ fontSize: '13px', fontWeight: 700, color: P.text, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{u.nome_completo.split(' ').slice(0, 2).join(' ')}</p>
                    <p style={{ fontSize: '9px', color: P.muted, textTransform: 'uppercase', letterSpacing: '0.1em' }}>{u.perfil?.nome_exibicao ?? 'Usuário'}</p>
                  </div>
                </button>
              ))}
            </div>
          </div>

          {/* Área de conversa — visível quando chat selecionado no mobile, sempre no md+ */}
          <div
            className={`flex flex-col overflow-hidden ${chatSelecionado ? 'flex' : 'hidden md:flex'}`}
            style={{ backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px' }}
          >
            {!chatSelecionado ? (
              <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: '10px' }}>
                <MessageSquare size={36} style={{ color: P.light }} />
                <p style={{ fontSize: '13px', color: P.sub, fontWeight: 600 }}>Selecione um usuário</p>
                <p style={{ fontSize: '11px', color: P.muted }}>Escolha à esquerda para iniciar</p>
              </div>
            ) : (
              <>
                <div style={{ padding: '11px 16px', borderBottom: `1px solid ${P.border}`, display: 'flex', alignItems: 'center', justifyContent: 'space-between', backgroundColor: '#F8F9FC' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                    {/* Botão voltar — apenas mobile */}
                    <button
                      className="md:hidden flex items-center justify-center"
                      onClick={() => setChatSelecionado(null)}
                      style={{ width: '32px', height: '32px', background: 'none', border: 'none', cursor: 'pointer', color: P.muted, marginRight: '2px' }}
                    >
                      <X size={16} />
                    </button>
                    <div style={{ width: '32px', height: '32px', borderRadius: '2px', background: `linear-gradient(135deg, ${P.steel}, ${P.navy})`, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontSize: '11px', fontWeight: 900 }}>
                      {chatSelecionado.nome_completo.split(' ').slice(0, 2).map(n => n[0]).join('')}
                    </div>
                    <div>
                      <p style={{ fontSize: '13px', fontWeight: 700, color: P.text }}>{chatSelecionado.nome_completo}</p>
                      <p style={{ fontSize: '9px', color: P.muted, textTransform: 'uppercase', letterSpacing: '0.12em' }}>{chatSelecionado.perfil?.nome_exibicao ?? chatSelecionado.email}</p>
                    </div>
                  </div>
                  <button onClick={() => setChatSelecionado(null)} className="hidden md:block" style={{ background: 'none', border: 'none', cursor: 'pointer', color: P.muted }}>
                    <X size={14} />
                  </button>
                </div>

                <div style={{ flex: 1, overflowY: 'auto', padding: '14px', display: 'flex', flexDirection: 'column', gap: '8px' }}>
                  {mensagens.length === 0 ? (
                    <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                      <p style={{ fontSize: '12px', color: P.muted }}>Nenhuma mensagem. Inicie a conversa!</p>
                    </div>
                  ) : mensagens.map(m => {
                    const minha = m.de_usuario_id === user?.id
                    return (
                      <div key={m.id} style={{ display: 'flex', justifyContent: minha ? 'flex-end' : 'flex-start' }}>
                        <div style={{ maxWidth: '80%', backgroundColor: minha ? P.navy : '#F0F3F9', borderRadius: '2px', padding: '8px 12px', border: minha ? 'none' : `1px solid ${P.border}` }}>
                          {!minha && (
                            <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.12em', color: P.steel, marginBottom: '3px' }}>
                              {m.de_usuario?.nome_completo?.split(' ')[0]}
                            </p>
                          )}
                          <p style={{ fontSize: '14px', color: minha ? '#fff' : P.text, lineHeight: 1.45, wordBreak: 'break-word' }}>{m.mensagem}</p>
                          <p style={{ fontSize: '9px', color: minha ? 'rgba(255,255,255,0.4)' : P.muted, marginTop: '4px', textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                            {new Date(m.criado_em).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}
                            {minha && ` · ${m.lida ? 'Lida' : 'Enviada'}`}
                          </p>
                        </div>
                      </div>
                    )
                  })}
                  <div ref={msgEndRef} />
                </div>

                <div style={{ padding: '10px 14px', borderTop: `1px solid ${P.border}`, display: 'flex', gap: '8px', alignItems: 'center', backgroundColor: '#F8F9FC' }}>
                  <input
                    value={novaMensagem}
                    onChange={e => setNovaMensagem(e.target.value)}
                    onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); enviarMensagem() } }}
                    placeholder={`Mensagem para ${chatSelecionado.nome_completo.split(' ')[0]}...`}
                    style={{ flex: 1, height: '44px', padding: '0 12px', backgroundColor: P.surface, border: `1px solid ${P.border}`, borderRadius: '2px', fontSize: '14px', color: P.text, outline: 'none' }}
                  />
                  <button
                    onClick={enviarMensagem}
                    disabled={!novaMensagem.trim() || enviando}
                    style={{ width: '44px', height: '44px', borderRadius: '2px', border: 'none', cursor: !novaMensagem.trim() ? 'not-allowed' : 'pointer', backgroundColor: novaMensagem.trim() ? P.navy : P.light, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', transition: 'all 150ms', flexShrink: 0 }}
                  >
                    <Send size={16} />
                  </button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </div>

    {/* ── Lightbox de foto ── */}

    {fotoAmpliada && (
      <div
        onClick={() => setFotoAmpliada(null)}
        style={{
          position: 'fixed', inset: 0, zIndex: 9999,
          backgroundColor: 'rgba(0,0,0,0.92)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: '24px',
          cursor: 'zoom-out',
        }}
      >
        <button
          onClick={() => setFotoAmpliada(null)}
          style={{
            position: 'absolute', top: '16px', right: '16px',
            background: 'rgba(255,255,255,0.1)', border: '1px solid rgba(255,255,255,0.2)',
            borderRadius: '2px', width: '36px', height: '36px',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            color: '#fff', cursor: 'pointer',
          }}
        >
          <X size={16} />
        </button>
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={fotoAmpliada}
          alt="foto ampliada"
          onClick={e => e.stopPropagation()}
          style={{
            maxWidth: '100%', maxHeight: '100%',
            objectFit: 'contain',
            borderRadius: '2px',
            boxShadow: '0 8px 48px rgba(0,0,0,0.6)',
            cursor: 'default',
          }}
        />
      </div>
    )}
    </>
  )
}
