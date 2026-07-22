'use client'

import { useEffect, useState, useCallback } from 'react'
import {
  Plus, Search, Pencil, X, Info, Copy, CheckCircle2,
  RefreshCw, Key, Shield, UserX, UserCheck, Eye, EyeOff,
  Download, Printer, Filter, Users, ChevronDown
} from 'lucide-react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_GERENCIAR_USUARIOS } from '@/lib/permissions'

const supabase = createClient()
const sb = supabase as any

// ── Types ─────────────────────────────────────────────────────────────────────

interface Perfil {
  id: string
  codigo: string
  nome_exibicao: string
}

interface UsuarioRow {
  id: string
  nome_completo: string
  email: string
  cpf: string | null
  telefone: string | null
  status: string
  troca_senha_obrigatoria: boolean
  ultimo_acesso: string | null
  criado_em: string
  auth_user_id: string | null
  perfil: Perfil | null
}

interface FormData {
  nome_completo: string
  email: string
  cpf: string
  telefone: string
  perfil_id: string
  status: string
}

const FORM_INICIAL: FormData = {
  nome_completo: '', email: '', cpf: '', telefone: '', perfil_id: '', status: 'ativo',
}

const PODE_GERENCIAR = PODE_GERENCIAR_USUARIOS

function gerarSenhaTemporaria(): string {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789@#!'
  return Array.from({ length: 10 }, () => chars[Math.floor(Math.random() * chars.length)]).join('')
}

const PERFIL_CONFIG: Record<string, { label: string; color: string; bg: string }> = {
  administrador: { label: 'ADMIN',      color: '#B83832', bg: '#FEF0EE' },
  gestor:        { label: 'GESTOR',     color: '#7B3FA0', bg: '#F4EDFC' },
  supervisor:    { label: 'SUPERVISOR', color: '#1A6B9A', bg: '#E8F2FA' },
  central:       { label: 'CENTRAL',   color: '#1E7C52', bg: '#EBF5F1' },
  operador:      { label: 'OPERADOR',  color: '#7A5C1E', bg: '#FDF3E1' },
}

const STATUS_CONFIG: Record<string, { label: string; color: string; dot: string }> = {
  ativo:     { label: 'ATIVO',     color: '#1E7C52', dot: '#1E7C52' },
  inativo:   { label: 'INATIVO',   color: '#6B7E8A', dot: '#6B7E8A' },
  bloqueado: { label: 'BLOQUEADO', color: '#B83832', dot: '#B83832' },
  pendente:  { label: 'PENDENTE',  color: '#D97706', dot: '#D97706' },
}

// ── Page ─────────────────────────────────────────────────────────────────────

export default function UsuariosPage() {
  const { user } = useAuth()
  const router = useRouter()
  const perfilAtual = (user?.perfil?.codigo ?? '') as string
  const ehSupervisor = perfilAtual === 'supervisor'
  // Supervisor tem acesso restrito: vê e gerencia apenas operadores; criação vai para o cadastro de vigilante
  const podeGerenciar = PODE_GERENCIAR.includes(perfilAtual as any) || ehSupervisor
  const podeGerenciarTudo = PODE_GERENCIAR.includes(perfilAtual as any)

  const [usuarios, setUsuarios] = useState<UsuarioRow[]>([])
  const [perfis, setPerfis] = useState<Perfil[]>([])
  const [loading, setLoading] = useState(true)
  const [busca, setBusca] = useState('')
  const [filtroStatus, setFiltroStatus] = useState('todos')
  const [filtroPerfil, setFiltroPerfil] = useState('todos')
  const [mostrarFiltros, setMostrarFiltros] = useState(false)

  // Dialog criar/editar
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editando, setEditando] = useState<UsuarioRow | null>(null)
  const [form, setForm] = useState<FormData>(FORM_INICIAL)
  const [saving, setSaving] = useState(false)
  const [erro, setErro] = useState('')
  const [senhaTemporaria, setSenhaTemporaria] = useState('')

  // Modal de credenciais criadas
  const [usuarioCriado, setUsuarioCriado] = useState<{ email: string; senha: string } | null>(null)
  const [copiado, setCopiado] = useState(false)

  // Modal de reset de senha
  const [resetando, setResetando] = useState<UsuarioRow | null>(null)
  const [novaSenhaReset, setNovaSenhaReset] = useState('')
  const [savingReset, setSavingReset] = useState(false)

  // Confirmar exclusão
  const [excluindo, setExcluindo] = useState<UsuarioRow | null>(null)
  const [savingExcluir, setSavingExcluir] = useState(false)

  const carregar = useCallback(async () => {
    setLoading(true)
    const { data } = await sb
      .from('usuarios')
      .select('*, perfil:dom_perfis(id, codigo, nome_exibicao)')
      .order('nome_completo')
    let rows = (data ?? []) as UsuarioRow[]
    // Supervisor enxerga somente operadores
    if (ehSupervisor) rows = rows.filter(u => u.perfil?.codigo === 'operador')
    setUsuarios(rows)
    setLoading(false)
  }, [ehSupervisor])

  useEffect(() => {
    carregar()
    sb.from('dom_perfis').select('id, codigo, nome_exibicao').order('nome_exibicao')
      .then(({ data }: any) => setPerfis(data ?? []))
  }, [carregar])

  const copiarCredenciais = () => {
    if (!usuarioCriado) return
    navigator.clipboard.writeText(`E-mail: ${usuarioCriado.email}\nSenha: ${usuarioCriado.senha}`)
    setCopiado(true)
    setTimeout(() => setCopiado(false), 2000)
  }

  const abrirNovo = () => {
    // Supervisor cadastra operador (vigilante) na tela de Cadastros, onde o acesso é provisionado automaticamente
    if (ehSupervisor) {
      router.push('/dashboard/cadastros')
      return
    }
    setEditando(null)
    setForm(FORM_INICIAL)
    setErro('')
    setSenhaTemporaria(gerarSenhaTemporaria())
    setDialogOpen(true)
  }

  const abrirEditar = (u: UsuarioRow) => {
    setEditando(u)
    setForm({
      nome_completo: u.nome_completo,
      email: u.email,
      cpf: u.cpf ?? '',
      telefone: u.telefone ?? '',
      perfil_id: u.perfil?.id ?? '',
      status: u.status,
    })
    setErro('')
    setDialogOpen(true)
  }

  const fechar = () => { setDialogOpen(false); setEditando(null); setErro('') }

  const salvar = async () => {
    if (!form.nome_completo.trim()) { setErro('Informe o nome completo.'); return }
    if (!form.email.trim()) { setErro('Informe o e-mail.'); return }
    if (!form.perfil_id) { setErro('Selecione um perfil.'); return }
    setSaving(true); setErro('')

    if (editando) {
      const { error } = await sb.from('usuarios').update({
        nome_completo: form.nome_completo.trim(),
        cpf: form.cpf || null,
        telefone: form.telefone || null,
        perfil_id: form.perfil_id,
        status: form.status,
        atualizado_em: new Date().toISOString(),
      }).eq('id', editando.id)
      if (error) { setErro(error.message ?? 'Erro ao atualizar.') }
      else { fechar(); await carregar() }
    } else {
      const { error } = await sb.rpc('criar_usuario_completo', {
        p_email: form.email.trim().toLowerCase(),
        p_senha_temporaria: senhaTemporaria,
        p_nome: form.nome_completo.trim(),
        p_perfil_id: form.perfil_id,
        p_telefone: form.telefone || null,
        p_cpf: form.cpf || null,
      })
      if (error) { setErro(error.message ?? 'Erro ao criar usuário.') }
      else {
        setUsuarioCriado({ email: form.email.trim().toLowerCase(), senha: senhaTemporaria })
        fechar(); await carregar()
      }
    }
    setSaving(false)
  }

  const confirmarReset = async () => {
    if (!resetando || !novaSenhaReset.trim()) return
    setSavingReset(true)
    const { error } = await sb.rpc('redefinir_senha_usuario', {
      p_usuario_id: resetando.auth_user_id,
      p_nova_senha: novaSenhaReset.trim(),
    })
    if (!error) { setResetando(null); setNovaSenhaReset('') }
    setSavingReset(false)
  }

  const toggleStatus = async (u: UsuarioRow) => {
    const novoStatus = u.status === 'ativo' ? 'bloqueado' : 'ativo'
    await sb.from('usuarios').update({ status: novoStatus }).eq('id', u.id)
    await carregar()
  }

  const confirmarExcluir = async () => {
    if (!excluindo) return
    setSavingExcluir(true)
    await sb.from('usuarios').delete().eq('id', excluindo.id)
    if (excluindo.auth_user_id) {
      await sb.rpc('excluir_auth_usuario', { p_auth_uid: excluindo.auth_user_id })
    }
    setExcluindo(null)
    setSavingExcluir(false)
    await carregar()
  }

  const filtrados = usuarios.filter((u) => {
    const t = busca.toLowerCase()
    const matchBusca = !busca || u.nome_completo.toLowerCase().includes(t) || u.email.toLowerCase().includes(t)
    const matchStatus = filtroStatus === 'todos' || u.status === filtroStatus
    const matchPerfil = filtroPerfil === 'todos' || u.perfil?.codigo === filtroPerfil
    return matchBusca && matchStatus && matchPerfil
  })

  const getInitials = (nome: string) =>
    nome.split(' ').filter(Boolean).slice(0, 2).map(n => n[0]).join('').toUpperCase()

  const perfilCfg = (codigo?: string) =>
    PERFIL_CONFIG[codigo ?? ''] ?? { label: codigo?.toUpperCase() ?? '—', color: '#6B7E8A', bg: '#F0F2F4' }

  const statusCfg = (s: string) => STATUS_CONFIG[s] ?? { label: s.toUpperCase(), color: '#6B7E8A', dot: '#6B7E8A' }

  return (
    <div className="space-y-0">

      {/* ── Header ───────────────────────────────────────────────────────────── */}
      <div className="px-4 md:px-6 pt-6 pb-4">
        <div className="flex flex-col md:flex-row md:items-start md:justify-between gap-3">
          <div>
            <h1 className="text-2xl font-black tracking-tight uppercase" style={{ color: '#0E1A33', letterSpacing: '0.04em' }}>
              Governança de Acessos
            </h1>
            <p className="text-xs mt-1 flex items-center gap-1.5" style={{ color: '#6B7E8A' }}>
              <span className="w-1.5 h-1.5 rounded-full inline-block" style={{ backgroundColor: '#1E7C52' }} />
              Gerencie permissões e perfis de segurança do sistema
            </p>
          </div>
          <div className="flex items-center gap-2 text-xs" style={{ color: '#6B7E8A' }}>
            <Shield size={13} style={{ color: '#4A90A4' }} />
            {filtrados.length} operador{filtrados.length !== 1 ? 'es' : ''} no sistema
          </div>
        </div>
      </div>

      {/* ── Toolbar ──────────────────────────────────────────────────────────── */}
      <div className="px-4 md:px-6 pb-4 flex flex-col md:flex-row md:items-center md:justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2">
          {/* Busca */}
          <div className="relative flex-1 min-w-0 md:flex-none">
            <Search size={13} className="absolute left-3 top-1/2 -translate-y-1/2" style={{ color: '#A8B8C2' }} />
            <input
              type="text"
              placeholder="Buscar operador..."
              value={busca}
              onChange={e => setBusca(e.target.value)}
              className="input-light pl-8 pr-3 py-2 text-xs w-full md:w-52"
            />
          </div>

          {/* Filtros toggle */}
          <button
            onClick={() => setMostrarFiltros(v => !v)}
            className="flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-semibold transition-all"
            style={{
              backgroundColor: mostrarFiltros ? '#1A2F4A' : '#F0F2F4',
              color: mostrarFiltros ? '#fff' : '#4A5568',
              border: '1px solid ' + (mostrarFiltros ? '#1A2F4A' : '#DDE3E8'),
            }}
          >
            <Filter size={12} />
            Filtros
            <ChevronDown size={11} className={`transition-transform ${mostrarFiltros ? 'rotate-180' : ''}`} />
          </button>

          {/* Export / Print — ocultos no mobile para economizar espaço */}
          <button
            className="hidden md:flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-semibold transition-all"
            style={{ backgroundColor: '#F0F2F4', color: '#4A5568', border: '1px solid #DDE3E8' }}
            title="Exportar"
          >
            <Download size={12} />
            Exportar
          </button>
          <button
            className="hidden md:flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-semibold transition-all"
            style={{ backgroundColor: '#F0F2F4', color: '#4A5568', border: '1px solid #DDE3E8' }}
            title="Imprimir"
          >
            <Printer size={12} />
            Imprimir
          </button>
        </div>

        {/* Provisionar */}
        {podeGerenciar && (
          <button
            onClick={abrirNovo}
            className="flex items-center justify-center gap-2 px-4 py-2.5 rounded-lg text-xs font-bold text-white transition-all w-full md:w-auto min-h-[44px] md:min-h-0"
            style={{ background: 'linear-gradient(135deg, #1A2F4A 0%, #2C4A6B 100%)' }}
          >
            <Plus size={13} />
            {ehSupervisor ? 'Cadastrar Operador' : 'Provisionar Acesso'}
          </button>
        )}
      </div>

      {/* ── Filtros expandidos ────────────────────────────────────────────────── */}
      {mostrarFiltros && (
        <div className="mx-4 md:mx-6 mb-4 p-4 rounded-xl flex flex-col md:flex-row md:items-center gap-4"
          style={{ backgroundColor: '#F7F9FB', border: '1px solid #E2E8EC' }}>
          <div className="flex-1 md:flex-none">
            <label className="block text-[10px] font-bold uppercase tracking-wider mb-1" style={{ color: '#7A8FA0' }}>Status</label>
            <select value={filtroStatus} onChange={e => setFiltroStatus(e.target.value)} className="select-light text-xs py-1.5 w-full md:w-auto min-h-[44px] md:min-h-0">
              <option value="todos">Todos</option>
              <option value="ativo">Ativo</option>
              <option value="inativo">Inativo</option>
              <option value="bloqueado">Bloqueado</option>
              <option value="pendente">Pendente</option>
            </select>
          </div>
          <div className="flex-1 md:flex-none">
            <label className="block text-[10px] font-bold uppercase tracking-wider mb-1" style={{ color: '#7A8FA0' }}>Perfil</label>
            <select value={filtroPerfil} onChange={e => setFiltroPerfil(e.target.value)} className="select-light text-xs py-1.5 w-full md:w-auto min-h-[44px] md:min-h-0">
              <option value="todos">Todos</option>
              {perfis.map(p => <option key={p.id} value={p.codigo}>{p.nome_exibicao}</option>)}
            </select>
          </div>
          <button onClick={() => { setFiltroStatus('todos'); setFiltroPerfil('todos'); setBusca('') }}
            className="text-xs font-semibold md:mt-4" style={{ color: '#B83832' }}>
            Limpar filtros
          </button>
        </div>
      )}

      {/* ── Tabela Desktop ───────────────────────────────────────────────────── */}
      <div className="hidden md:block mx-6 rounded-xl overflow-hidden" style={{ border: '1px solid #E2E8EC' }}>
        {/* Header da tabela */}
        <div className="grid text-[10px] font-black uppercase tracking-widest px-4 py-3"
          style={{
            gridTemplateColumns: '2fr 2fr 1fr 1fr 1fr',
            backgroundColor: '#0E1A33',
            color: '#8BA3BC',
          }}>
          <span>Operador</span>
          <span>E-mail / Acesso</span>
          <span>Perfil</span>
          <span>Status</span>
          <span className="text-right">Ações</span>
        </div>

        {/* Linhas */}
        {loading ? (
          <div className="py-16 flex items-center justify-center gap-3 bg-white">
            <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
            <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando operadores...</span>
          </div>
        ) : filtrados.length === 0 ? (
          <div className="py-16 text-center bg-white">
            <Users size={32} className="mx-auto mb-3" style={{ color: '#C8D5DC' }} />
            <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhum operador encontrado</p>
          </div>
        ) : (
          filtrados.map((u, i) => {
            const isMe = u.id === user?.id
            const pCfg = perfilCfg(u.perfil?.codigo)
            const sCfg = statusCfg(u.status)
            const primeiroAcesso = u.troca_senha_obrigatoria

            return (
              <div
                key={u.id}
                className="grid items-center px-4 py-3.5 transition-colors"
                style={{
                  gridTemplateColumns: '2fr 2fr 1fr 1fr 1fr',
                  borderTop: i > 0 ? '1px solid #F0F2F4' : undefined,
                  backgroundColor: isMe ? '#F0F7FF' : 'white',
                }}
                onMouseEnter={e => { if (!isMe) (e.currentTarget as HTMLElement).style.backgroundColor = '#FAFBFC' }}
                onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = isMe ? '#F0F7FF' : 'white' }}
              >
                {/* Operador */}
                <div className="flex items-center gap-3">
                  <div className="w-9 h-9 rounded-xl flex items-center justify-center shrink-0 font-black text-xs text-white"
                    style={{ background: `linear-gradient(135deg, ${pCfg.color}CC, ${pCfg.color}88)` }}>
                    {getInitials(u.nome_completo)}
                  </div>
                  <div>
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-bold" style={{ color: '#0E1A33' }}>{u.nome_completo}</span>
                      {isMe && (
                        <span className="text-[9px] font-black px-1.5 py-0.5 rounded-full"
                          style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}>VOCÊ</span>
                      )}
                    </div>
                    {primeiroAcesso && (
                      <span className="text-[9px] font-black tracking-wider"
                        style={{ color: '#D97706' }}>AGUARD. 1º ACESSO</span>
                    )}
                    {!primeiroAcesso && u.ultimo_acesso && (
                      <span className="text-[10px]" style={{ color: '#A8B8C2' }}>
                        Último acesso {new Date(u.ultimo_acesso).toLocaleDateString('pt-BR')}
                      </span>
                    )}
                    {!primeiroAcesso && !u.ultimo_acesso && (
                      <span className="text-[10px]" style={{ color: '#A8B8C2' }}>Nunca acessou</span>
                    )}
                  </div>
                </div>

                {/* E-mail */}
                <div>
                  <div className="flex items-center gap-1.5">
                    <code className="text-xs font-mono" style={{ color: '#1A2F4A' }}>{u.email}</code>
                    <button
                      onClick={() => navigator.clipboard.writeText(u.email)}
                      className="p-1 rounded opacity-0 hover:opacity-100 transition-opacity"
                      title="Copiar e-mail"
                      style={{ color: '#6B7E8A' }}
                    >
                      <Copy size={11} />
                    </button>
                  </div>
                  <div className="flex items-center gap-1 mt-0.5">
                    <span className="text-[10px]" style={{ color: '#A8B8C2' }}>••••••••••</span>
                    {u.auth_user_id ? (
                      <span className="text-[9px] font-semibold px-1 py-0.5 rounded"
                        style={{ backgroundColor: '#EBF5F1', color: '#1E7C52' }}>AUTH ATIVO</span>
                    ) : (
                      <span className="text-[9px] font-semibold px-1 py-0.5 rounded"
                        style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>SEM AUTH</span>
                    )}
                  </div>
                </div>

                {/* Perfil */}
                <div>
                  <span className="text-[10px] font-black px-2 py-1 rounded-md tracking-wider"
                    style={{ backgroundColor: pCfg.bg, color: pCfg.color }}>
                    {pCfg.label}
                  </span>
                </div>

                {/* Status */}
                <div className="flex items-center gap-1.5">
                  <span className="w-1.5 h-1.5 rounded-full shrink-0" style={{ backgroundColor: sCfg.dot }} />
                  <span className="text-[10px] font-black tracking-wider" style={{ color: sCfg.color }}>
                    {sCfg.label}
                  </span>
                </div>

                {/* Ações */}
                {podeGerenciar ? (
                  <div className="flex items-center justify-end gap-1">
                    {/* Reset senha */}
                    <button
                      onClick={() => { setResetando(u); setNovaSenhaReset(gerarSenhaTemporaria()) }}
                      title="Redefinir senha"
                      className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                      style={{ color: '#6B7E8A' }}
                      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#F4EDFC'; (e.currentTarget as HTMLElement).style.color = '#7B3FA0' }}
                      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = ''; (e.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                    >
                      <Key size={13} />
                    </button>
                    {/* Bloquear/ativar */}
                    <button
                      onClick={() => toggleStatus(u)}
                      title={u.status === 'ativo' ? 'Bloquear' : 'Ativar'}
                      className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                      style={{ color: '#6B7E8A' }}
                      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = u.status === 'ativo' ? '#FEF0EE' : '#EBF5F1'; (e.currentTarget as HTMLElement).style.color = u.status === 'ativo' ? '#B83832' : '#1E7C52' }}
                      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = ''; (e.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                    >
                      {u.status === 'ativo' ? <UserX size={13} /> : <UserCheck size={13} />}
                    </button>
                    {/* Editar */}
                    <button
                      onClick={() => abrirEditar(u)}
                      title="Editar"
                      className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                      style={{ color: '#6B7E8A' }}
                      onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#EBF3FC'; (e.currentTarget as HTMLElement).style.color = '#2166A8' }}
                      onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = ''; (e.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                    >
                      <Pencil size={13} />
                    </button>
                    {/* Excluir (não pode excluir a si mesmo; supervisor não exclui) */}
                    {!isMe && podeGerenciarTudo && (
                      <button
                        onClick={() => setExcluindo(u)}
                        title="Excluir"
                        className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                        style={{ color: '#6B7E8A' }}
                        onMouseEnter={e => { (e.currentTarget as HTMLElement).style.backgroundColor = '#FEF0EE'; (e.currentTarget as HTMLElement).style.color = '#B83832' }}
                        onMouseLeave={e => { (e.currentTarget as HTMLElement).style.backgroundColor = ''; (e.currentTarget as HTMLElement).style.color = '#6B7E8A' }}
                      >
                        <X size={13} />
                      </button>
                    )}
                  </div>
                ) : <div />}
              </div>
            )
          })
        )}
      </div>

      {/* ── Cards Mobile ─────────────────────────────────────────────────────── */}
      <div className="md:hidden px-4 pb-4">
        {loading ? (
          <div className="py-16 flex items-center justify-center gap-3">
            <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
            <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando operadores...</span>
          </div>
        ) : filtrados.length === 0 ? (
          <div className="py-16 text-center">
            <Users size={32} className="mx-auto mb-3" style={{ color: '#C8D5DC' }} />
            <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhum operador encontrado</p>
          </div>
        ) : (
          <div className="space-y-3">
            {filtrados.map((u) => {
              const isMe = u.id === user?.id
              const pCfg = perfilCfg(u.perfil?.codigo)
              const sCfg = statusCfg(u.status)
              const primeiroAcesso = u.troca_senha_obrigatoria

              return (
                <div
                  key={u.id}
                  className="bg-white rounded-xl p-4 shadow-sm border border-gray-100"
                  style={{ backgroundColor: isMe ? '#F0F7FF' : 'white' }}
                >
                  {/* Topo: avatar + nome + badges */}
                  <div className="flex items-start gap-3 mb-3">
                    <div className="w-10 h-10 rounded-xl flex items-center justify-center shrink-0 font-black text-xs text-white"
                      style={{ background: `linear-gradient(135deg, ${pCfg.color}CC, ${pCfg.color}88)` }}>
                      {getInitials(u.nome_completo)}
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-bold truncate" style={{ color: '#0E1A33' }}>{u.nome_completo}</span>
                        {isMe && (
                          <span className="text-[9px] font-black px-1.5 py-0.5 rounded-full shrink-0"
                            style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}>VOCÊ</span>
                        )}
                      </div>
                      <code className="text-xs font-mono block truncate mt-0.5" style={{ color: '#53648A' }}>{u.email}</code>
                      {primeiroAcesso ? (
                        <span className="text-[9px] font-black tracking-wider" style={{ color: '#D97706' }}>AGUARD. 1º ACESSO</span>
                      ) : u.ultimo_acesso ? (
                        <span className="text-[10px]" style={{ color: '#A8B8C2' }}>
                          Último acesso {new Date(u.ultimo_acesso).toLocaleDateString('pt-BR')}
                        </span>
                      ) : (
                        <span className="text-[10px]" style={{ color: '#A8B8C2' }}>Nunca acessou</span>
                      )}
                    </div>
                  </div>

                  {/* Badges: perfil + status + auth */}
                  <div className="flex items-center gap-2 flex-wrap mb-3">
                    <span className="text-[10px] font-black px-2 py-1 rounded-md tracking-wider"
                      style={{ backgroundColor: pCfg.bg, color: pCfg.color }}>
                      {pCfg.label}
                    </span>
                    <div className="flex items-center gap-1">
                      <span className="w-1.5 h-1.5 rounded-full shrink-0" style={{ backgroundColor: sCfg.dot }} />
                      <span className="text-[10px] font-black tracking-wider" style={{ color: sCfg.color }}>
                        {sCfg.label}
                      </span>
                    </div>
                    {u.auth_user_id ? (
                      <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded"
                        style={{ backgroundColor: '#EBF5F1', color: '#1E7C52' }}>AUTH ATIVO</span>
                    ) : (
                      <span className="text-[9px] font-semibold px-1.5 py-0.5 rounded"
                        style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>SEM AUTH</span>
                    )}
                  </div>

                  {/* Ações */}
                  {podeGerenciar && (
                    <div className="flex gap-2 pt-3 border-t border-gray-100">
                      <button
                        onClick={() => { setResetando(u); setNovaSenhaReset(gerarSenhaTemporaria()) }}
                        className="flex-1 flex items-center justify-center gap-1.5 py-2.5 rounded-lg text-xs font-semibold"
                        style={{ backgroundColor: '#F4EDFC', color: '#7B3FA0' }}
                        title="Redefinir senha"
                      >
                        <Key size={13} />
                        Senha
                      </button>
                      <button
                        onClick={() => toggleStatus(u)}
                        className="flex-1 flex items-center justify-center gap-1.5 py-2.5 rounded-lg text-xs font-semibold"
                        style={{
                          backgroundColor: u.status === 'ativo' ? '#FEF0EE' : '#EBF5F1',
                          color: u.status === 'ativo' ? '#B83832' : '#1E7C52'
                        }}
                        title={u.status === 'ativo' ? 'Bloquear' : 'Ativar'}
                      >
                        {u.status === 'ativo' ? <UserX size={13} /> : <UserCheck size={13} />}
                        {u.status === 'ativo' ? 'Bloquear' : 'Ativar'}
                      </button>
                      <button
                        onClick={() => abrirEditar(u)}
                        className="flex-1 flex items-center justify-center gap-1.5 py-2.5 rounded-lg text-xs font-semibold"
                        style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}
                        title="Editar"
                      >
                        <Pencil size={13} />
                        Editar
                      </button>
                      {!isMe && podeGerenciarTudo && (
                        <button
                          onClick={() => setExcluindo(u)}
                          className="flex items-center justify-center p-2.5 rounded-lg"
                          style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}
                          title="Excluir"
                        >
                          <X size={14} />
                        </button>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}
      </div>

      {/* ── Modal: Credenciais criadas ─────────────────────────────────────── */}
      {usuarioCriado && (
        <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center md:p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.55)' }}>
          <div className="bg-white rounded-t-2xl md:rounded-2xl shadow-2xl w-full mx-4 md:mx-auto md:max-w-md" style={{ border: '1px solid #E2E8EC' }}>
            <div className="px-6 pt-6 pb-4 text-center">
              <div className="w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3"
                style={{ backgroundColor: '#E8F5EE' }}>
                <CheckCircle2 size={24} style={{ color: '#1E7C52' }} />
              </div>
              <h2 className="text-base font-black mb-1" style={{ color: '#0E1A33' }}>Acesso provisionado!</h2>
              <p className="text-xs" style={{ color: '#6B7E8A' }}>
                Repasse estas credenciais ao operador. A senha não poderá ser recuperada após fechar.
              </p>
            </div>
            <div className="mx-6 mb-5 rounded-xl overflow-hidden" style={{ border: '1px solid #D5E0E6' }}>
              <div className="px-4 py-3" style={{ backgroundColor: '#F7FAFC' }}>
                <p className="text-[10px] font-bold uppercase tracking-wider mb-1" style={{ color: '#7A8FA0' }}>Login (E-mail)</p>
                <p className="text-sm font-mono font-semibold" style={{ color: '#1A2535' }}>{usuarioCriado.email}</p>
              </div>
              <div className="px-4 py-3 border-t" style={{ borderColor: '#D5E0E6', backgroundColor: '#F0F4FA' }}>
                <p className="text-[10px] font-bold uppercase tracking-wider mb-1" style={{ color: '#7A8FA0' }}>Senha Temporária</p>
                <p className="text-xl font-mono font-black tracking-widest" style={{ color: '#1A2F4A' }}>{usuarioCriado.senha}</p>
              </div>
            </div>
            <div className="flex gap-3 px-6 pb-6">
              <button onClick={copiarCredenciais}
                className="flex-1 flex items-center justify-center gap-2 font-bold text-sm py-3 rounded-lg transition-all"
                style={{ backgroundColor: '#F0F4FA', color: '#1A2F4A', border: '1px solid #D0DAEB' }}>
                {copiado ? <CheckCircle2 size={14} style={{ color: '#1E7C52' }} /> : <Copy size={14} />}
                {copiado ? 'Copiado!' : 'Copiar credenciais'}
              </button>
              <button onClick={() => setUsuarioCriado(null)}
                className="flex-1 font-bold text-sm py-3 rounded-lg text-white"
                style={{ backgroundColor: '#1A2F4A' }}>
                Fechar
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Modal: Redefinir senha ─────────────────────────────────────────── */}
      {resetando && (
        <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center md:p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.55)' }}>
          <div className="bg-white rounded-t-2xl md:rounded-2xl shadow-2xl w-full mx-4 md:mx-auto md:max-w-sm" style={{ border: '1px solid #E2E8EC' }}>
            <div className="px-5 py-4 border-b flex items-center justify-between" style={{ borderColor: '#E2E8EC' }}>
              <div className="flex items-center gap-2">
                <Key size={15} style={{ color: '#7B3FA0' }} />
                <h2 className="text-sm font-bold" style={{ color: '#0E1A33' }}>Redefinir Senha</h2>
              </div>
              <button onClick={() => setResetando(null)} className="p-1 rounded" style={{ color: '#6B7E8A' }}>
                <X size={15} />
              </button>
            </div>
            <div className="px-5 py-4 space-y-3">
              <p className="text-xs" style={{ color: '#6B7E8A' }}>
                Nova senha para <strong style={{ color: '#0E1A33' }}>{resetando.nome_completo}</strong>
              </p>
              <div className="flex items-center gap-2">
                <input
                  type="text"
                  value={novaSenhaReset}
                  onChange={e => setNovaSenhaReset(e.target.value)}
                  className="input-light flex-1 font-mono text-sm min-h-[48px] md:min-h-0"
                  placeholder="Nova senha"
                />
                <button onClick={() => setNovaSenhaReset(gerarSenhaTemporaria())}
                  className="p-2 rounded-lg transition-all" style={{ backgroundColor: '#F0F2F4', color: '#4A5568' }}
                  title="Gerar nova">
                  <RefreshCw size={14} />
                </button>
              </div>
              <p className="text-[10px]" style={{ color: '#A8B8C2' }}>
                O usuário será obrigado a trocar a senha no próximo acesso.
              </p>
            </div>
            <div className="flex gap-3 px-5 pb-5">
              <button onClick={() => setResetando(null)} className="btn-outline flex-1 text-xs min-h-[44px]">Cancelar</button>
              <button onClick={confirmarReset} disabled={savingReset || !novaSenhaReset}
                className="btn-primary flex-1 text-xs min-h-[44px]">
                {savingReset ? 'Salvando...' : 'Redefinir Senha'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Modal: Confirmar exclusão ──────────────────────────────────────── */}
      {excluindo && (
        <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center md:p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.55)' }}>
          <div className="bg-white rounded-t-2xl md:rounded-2xl shadow-2xl w-full mx-4 md:mx-auto md:max-w-sm" style={{ border: '1px solid #E2E8EC' }}>
            <div className="px-5 py-5 text-center">
              <div className="w-11 h-11 rounded-full flex items-center justify-center mx-auto mb-3"
                style={{ backgroundColor: '#FEF0EE' }}>
                <UserX size={20} style={{ color: '#B83832' }} />
              </div>
              <h2 className="text-sm font-bold mb-1" style={{ color: '#0E1A33' }}>Excluir operador?</h2>
              <p className="text-xs" style={{ color: '#6B7E8A' }}>
                <strong>{excluindo.nome_completo}</strong> perderá todo o acesso ao sistema. Esta ação não pode ser desfeita.
              </p>
            </div>
            <div className="flex gap-3 px-5 pb-5">
              <button onClick={() => setExcluindo(null)} className="btn-outline flex-1 text-xs min-h-[44px]">Cancelar</button>
              <button onClick={confirmarExcluir} disabled={savingExcluir}
                className="flex-1 text-xs font-bold py-2 rounded-lg text-white transition-all min-h-[44px]"
                style={{ backgroundColor: '#B83832' }}>
                {savingExcluir ? 'Excluindo...' : 'Sim, excluir'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Dialog: Criar / Editar ─────────────────────────────────────────── */}
      {dialogOpen && (
        <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center md:p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.55)' }}>
          <div className="bg-white rounded-t-2xl md:rounded-2xl shadow-2xl w-full mx-4 md:mx-auto md:max-w-lg" style={{ border: '1px solid #E2E8EC' }}>
            <div className="flex items-center justify-between px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="text-sm font-black uppercase tracking-wide" style={{ color: '#0E1A33' }}>
                {editando ? 'Editar Operador' : 'Provisionar Acesso'}
              </h2>
              <button onClick={fechar} className="w-7 h-7 rounded-lg flex items-center justify-center"
                style={{ color: '#6B7E8A' }}
                onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'}
                onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = ''}>
                <X size={15} />
              </button>
            </div>

            <div className="px-6 py-5 space-y-4 max-h-[65vh] overflow-y-auto">
              {/* Senha temp */}
              {!editando && (
                <div className="rounded-xl overflow-hidden" style={{ border: '1px solid #C8DCF0' }}>
                  <div className="flex items-center gap-2 px-3 py-2" style={{ backgroundColor: '#EBF3FC' }}>
                    <Key size={12} style={{ color: '#2166A8' }} />
                    <p className="text-xs font-bold" style={{ color: '#2166A8' }}>Senha temporária gerada</p>
                  </div>
                  <div className="flex items-center justify-between gap-2 px-3 py-2.5" style={{ backgroundColor: '#F7FAFC' }}>
                    <code className="text-sm font-mono font-black tracking-widest" style={{ color: '#1A2F4A' }}>
                      {senhaTemporaria}
                    </code>
                    <button type="button" onClick={() => setSenhaTemporaria(gerarSenhaTemporaria())}
                      title="Gerar nova"
                      className="p-1.5 rounded transition-all" style={{ color: '#6B7E8A' }}
                      onMouseEnter={e => (e.currentTarget as HTMLElement).style.backgroundColor = '#E2EAF4'}
                      onMouseLeave={e => (e.currentTarget as HTMLElement).style.backgroundColor = ''}>
                      <RefreshCw size={12} />
                    </button>
                  </div>
                </div>
              )}

              {/* Nome */}
              <div>
                <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>
                  Nome Completo *
                </label>
                <input type="text" placeholder="Nome completo do operador"
                  value={form.nome_completo}
                  onChange={e => setForm({ ...form, nome_completo: e.target.value })}
                  className="input-light min-h-[48px] md:min-h-0" />
              </div>

              {/* Email */}
              <div>
                <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>
                  E-mail (Login) *
                </label>
                <input type="email" placeholder="email@empresa.com"
                  value={form.email}
                  onChange={e => setForm({ ...form, email: e.target.value })}
                  className="input-light min-h-[48px] md:min-h-0"
                  readOnly={!!editando}
                  style={editando ? { backgroundColor: '#F4F4F9', cursor: 'not-allowed' } : {}} />
              </div>

              {/* CPF + Telefone */}
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>CPF</label>
                  <input type="text" placeholder="000.000.000-00"
                    value={form.cpf}
                    onChange={e => setForm({ ...form, cpf: e.target.value })}
                    className="input-light min-h-[48px] md:min-h-0" />
                </div>
                <div>
                  <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>Telefone</label>
                  <input type="text" placeholder="(00) 00000-0000"
                    value={form.telefone}
                    onChange={e => setForm({ ...form, telefone: e.target.value })}
                    className="input-light min-h-[48px] md:min-h-0" />
                </div>
              </div>

              {/* Perfil + Status */}
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                <div>
                  <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>Perfil *</label>
                  <select value={form.perfil_id} onChange={e => setForm({ ...form, perfil_id: e.target.value })}
                    disabled={ehSupervisor}
                    className="select-light w-full min-h-[48px] md:min-h-0">
                    <option value="">Selecione...</option>
                    {perfis.map(p => <option key={p.id} value={p.id}>{p.nome_exibicao}</option>)}
                  </select>
                </div>
                <div>
                  <label className="block text-[10px] font-black uppercase tracking-widest mb-1.5" style={{ color: '#7A8FA0' }}>Status</label>
                  <select value={form.status} onChange={e => setForm({ ...form, status: e.target.value })}
                    className="select-light w-full min-h-[48px] md:min-h-0">
                    <option value="ativo">Ativo</option>
                    <option value="inativo">Inativo</option>
                    <option value="pendente">Pendente</option>
                    <option value="bloqueado">Bloqueado</option>
                  </select>
                </div>
              </div>

              {erro && (
                <div className="px-3 py-2 rounded-lg text-xs font-semibold"
                  style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>{erro}</div>
              )}
            </div>

            <div className="flex flex-col-reverse md:flex-row gap-3 px-6 py-4 border-t" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
              <button onClick={fechar} className="btn-outline w-full md:flex-1 text-xs min-h-[44px]">Cancelar</button>
              <button onClick={salvar} disabled={saving}
                className="w-full md:flex-1 text-xs font-black py-2.5 rounded-lg text-white uppercase tracking-wider transition-all min-h-[44px]"
                style={{ background: 'linear-gradient(135deg, #1A2F4A, #2C4A6B)' }}>
                {saving ? 'Salvando...' : editando ? 'Salvar Alterações' : 'Provisionar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
