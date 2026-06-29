'use client'

import { useEffect, useState, useCallback } from 'react'
import {
  Plus, Search, Pencil, Trash2, X, Building2,
  UserCheck, Truck, CheckCircle, XCircle,
} from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const supabase = createClient()
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = supabase as any

type Tab = 'clientes' | 'vigilantes' | 'veiculos'

/* ─── CLIENTES ─────────────────────────────────────── */
interface Cliente {
  id: string; nome_cliente: string; cnpj: string | null; contato: string | null
  telefone: string | null; cor_destaque: string | null; status: string
  observacoes: string | null
}
const emptyCliente = (): Omit<Cliente,'id'> => ({
  nome_cliente:'', cnpj:'', contato:'', telefone:'',
  cor_destaque:'#3b82f6', status:'ativo', observacoes:'',
})

/* ─── VIGILANTES ────────────────────────────────────── */
interface Funcao { id: string; nome: string }
interface Vigilante {
  id: string; nome_completo: string; cpf: string; funcao_id: string | null
  cnv: string | null; extensao_escolta_armada: string | null
  valor_padrao_pago: number | null; status: string
}
const emptyVigilante = (): Omit<Vigilante,'id'> => ({
  nome_completo:'', cpf:'', funcao_id:'', cnv:'',
  extensao_escolta_armada:'', valor_padrao_pago: 0, status:'ativo',
})

/* ─── VEÍCULOS ──────────────────────────────────────── */
interface TipoVeiculo { id: string; nome: string }
interface Veiculo {
  id: string; tipo_id: string | null; placa: string; modelo: string | null; status: string; observacoes: string | null
}
const emptyVeiculo = (): Omit<Veiculo,'id'> => ({
  tipo_id:'', placa:'', modelo:'', status:'ativo', observacoes:'',
})

/* ─── DIALOG GENÉRICO ─────────────────────────────── */
function Dialog({ open, onClose, title, subtitle, children }: {
  open: boolean; onClose: () => void; title: string; subtitle?: string; children: React.ReactNode
}) {
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-end md:items-center justify-center md:p-4">
      <div className="absolute inset-0 bg-black/50 backdrop-blur-sm" onClick={onClose} />
      <div className="relative w-full mx-4 md:mx-auto md:max-w-lg bg-white rounded-t-2xl md:rounded-2xl shadow-2xl overflow-hidden">
        {/* Header */}
        <div className="flex items-start gap-4 px-6 py-5 border-b border-gray-100">
          <div className="flex-1">
            <h3 className="text-base font-black text-gray-900">{title}</h3>
            {subtitle && <p className="text-xs text-gray-400 mt-0.5">{subtitle}</p>}
          </div>
          <button onClick={onClose} className="w-8 h-8 flex items-center justify-center rounded-lg text-gray-400 hover:bg-gray-100 transition-colors">
            <X size={16} />
          </button>
        </div>
        {/* Body */}
        <div className="px-6 py-5 space-y-4 max-h-[65vh] overflow-y-auto">
          {children}
        </div>
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="block text-[11px] font-black text-gray-500 uppercase tracking-widest mb-1">{label}</label>
      {children}
    </div>
  )
}

/* ─── STATUS BADGE ────────────────────────────────── */
function StatusBadge({ status }: { status: string }) {
  const active = status === 'ativo'
  return (
    <span className={active ? 'badge-success' : 'badge-neutral'}>
      {active ? <CheckCircle size={10} /> : <XCircle size={10} />}
      {active ? 'Ativo' : status === 'inativo' ? 'Inativo' : status}
    </span>
  )
}

/* ─── PAGE ────────────────────────────────────────── */
export default function CadastrosPage() {
  const { user } = useAuth()
  const [tab, setTab] = useState<Tab>('clientes')
  const [search, setSearch] = useState('')

  /* Clientes */
  const [clientes, setClientes] = useState<Cliente[]>([])
  const [dialogCliente, setDialogCliente] = useState(false)
  const [formCliente, setFormCliente] = useState<Omit<Cliente,'id'>>(emptyCliente())
  const [editCliente, setEditCliente] = useState<string|null>(null)

  /* Vigilantes */
  const [vigilantes, setVigilantes] = useState<Vigilante[]>([])
  const [funcoes, setFuncoes] = useState<Funcao[]>([])
  const [dialogVigilante, setDialogVigilante] = useState(false)
  const [formVigilante, setFormVigilante] = useState<Omit<Vigilante,'id'>>(emptyVigilante())
  const [editVigilante, setEditVigilante] = useState<string|null>(null)

  /* Veículos */
  const [veiculos, setVeiculos] = useState<Veiculo[]>([])
  const [tipos, setTipos] = useState<TipoVeiculo[]>([])
  const [dialogVeiculo, setDialogVeiculo] = useState(false)
  const [formVeiculo, setFormVeiculo] = useState<Omit<Veiculo,'id'>>(emptyVeiculo())
  const [editVeiculo, setEditVeiculo] = useState<string|null>(null)

  const [saving, setSaving] = useState(false)

  const canEdit = ['administrador','gestor','supervisor'].includes((user?.perfil?.codigo ?? '') as any)

  /* ── Load ── */
  const loadClientes = useCallback(async () => {
    const { data } = await sb.from('clientes').select('*').order('nome_cliente')
    setClientes(data ?? [])
  }, [])

  const loadVigilantes = useCallback(async () => {
    const [v, f] = await Promise.all([
      sb.from('vigilantes').select('*').order('nome_completo'),
      sb.from('dom_funcoes').select('id, nome').order('nome'),
    ])
    setVigilantes(v.data ?? [])
    setFuncoes(f.data ?? [])
  }, [])

  const loadVeiculos = useCallback(async () => {
    const [ve, t] = await Promise.all([
      sb.from('veiculos').select('*').order('placa'),
      sb.from('dom_tipos_veiculo').select('id, nome').order('nome'),
    ])
    setVeiculos(ve.data ?? [])
    setTipos(t.data ?? [])
  }, [])

  useEffect(() => { loadClientes(); loadVigilantes(); loadVeiculos() }, [loadClientes, loadVigilantes, loadVeiculos])

  /* ── Save helpers ── */
  const saveCliente = async () => {
    setSaving(true)
    if (editCliente) {
      await sb.from('clientes').update({ ...formCliente, atualizado_por: user?.id }).eq('id', editCliente)
    } else {
      await sb.from('clientes').insert({ ...formCliente, criado_por: user?.id })
    }
    setSaving(false); setDialogCliente(false); loadClientes()
  }

  const deleteCliente = async (id: string) => {
    if (!confirm('Excluir cliente?')) return
    await sb.from('clientes').delete().eq('id', id)
    loadClientes()
  }

  const saveVigilante = async () => {
    setSaving(true)
    if (editVigilante) {
      await sb.from('vigilantes').update({ ...formVigilante, atualizado_por: user?.id }).eq('id', editVigilante)
    } else {
      await sb.from('vigilantes').insert({ ...formVigilante, criado_por: user?.id })
    }
    setSaving(false); setDialogVigilante(false); loadVigilantes()
  }

  const deleteVigilante = async (id: string) => {
    if (!confirm('Excluir vigilante?')) return
    await sb.from('vigilantes').delete().eq('id', id)
    loadVigilantes()
  }

  const saveVeiculo = async () => {
    setSaving(true)
    if (editVeiculo) {
      await sb.from('veiculos').update({ ...formVeiculo, atualizado_por: user?.id }).eq('id', editVeiculo)
    } else {
      await sb.from('veiculos').insert({ ...formVeiculo, criado_por: user?.id })
    }
    setSaving(false); setDialogVeiculo(false); loadVeiculos()
  }

  const deleteVeiculo = async (id: string) => {
    if (!confirm('Excluir veículo?')) return
    await sb.from('veiculos').delete().eq('id', id)
    loadVeiculos()
  }

  /* ── Filter ── */
  const filteredClientes = clientes.filter(c =>
    c.nome_cliente.toLowerCase().includes(search.toLowerCase()) ||
    (c.cnpj ?? '').includes(search)
  )
  const filteredVigilantes = vigilantes.filter(v =>
    v.nome_completo.toLowerCase().includes(search.toLowerCase()) ||
    v.cpf.includes(search)
  )
  const filteredVeiculos = veiculos.filter(v =>
    v.placa.toLowerCase().includes(search.toLowerCase()) ||
    (v.modelo ?? '').toLowerCase().includes(search.toLowerCase())
  )

  /* ── Tabs config ── */
  const TABS: { id: Tab; label: string; icon: React.ReactNode; count: number }[] = [
    { id:'clientes',   label:'Clientes',   icon:<Building2 size={15}/>,  count: clientes.length },
    { id:'vigilantes', label:'Vigilantes', icon:<UserCheck size={15}/>,  count: vigilantes.length },
    { id:'veiculos',   label:'Veículos',   icon:<Truck size={15}/>,      count: veiculos.length },
  ]

  return (
    <div className="space-y-5">

      {/* ── Header ── */}
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-3">
        <div>
          <h1 className="page-title">Cadastros</h1>
          <p className="page-subtitle">Gestão de clientes, vigilantes e veículos</p>
        </div>
      </div>

      {/* ── Tabs + Search + Add ── */}
      <div className="card-light">
        {/* Tab bar */}
        <div className="flex items-center gap-1 px-4 pt-4 border-b border-gray-100 overflow-x-auto">
          {TABS.map(t => (
            <button
              key={t.id}
              onClick={() => { setTab(t.id); setSearch('') }}
              className={`flex items-center gap-2 px-3 md:px-4 py-2.5 text-sm font-semibold rounded-t-lg border-b-2 -mb-px transition-all whitespace-nowrap ${
                tab === t.id
                  ? 'border-blue-500 text-blue-600 bg-blue-50/50'
                  : 'border-transparent text-gray-500 hover:text-gray-700 hover:bg-gray-50'
              }`}
            >
              {t.icon}
              <span className="hidden sm:inline">{t.label}</span>
              <span className="sm:hidden">{t.label.slice(0,3)}</span>
              <span className={`px-1.5 py-0.5 text-[9px] font-black uppercase tracking-wider ${
                tab === t.id ? 'text-white' : 'text-[#5A6A80]'
              }`} style={{ backgroundColor: tab === t.id ? '#1A294A' : '#ECEEF2', borderRadius: '1px' }}>
                {t.count}
              </span>
            </button>
          ))}
        </div>

        {/* Toolbar */}
        <div className="flex flex-col sm:flex-row sm:items-center gap-3 px-4 py-3">
          <div className="relative flex-1">
            <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-300" />
            <input
              className="input-light pl-9 w-full"
              placeholder={`Buscar ${tab}...`}
              value={search}
              onChange={e => setSearch(e.target.value)}
            />
          </div>
          {canEdit && (
            <button
              onClick={() => {
                if (tab==='clientes') { setEditCliente(null); setFormCliente(emptyCliente()); setDialogCliente(true) }
                if (tab==='vigilantes') { setEditVigilante(null); setFormVigilante(emptyVigilante()); setDialogVigilante(true) }
                if (tab==='veiculos') { setEditVeiculo(null); setFormVeiculo(emptyVeiculo()); setDialogVeiculo(true) }
              }}
              className="btn-gradient w-full sm:w-auto min-h-[44px] sm:min-h-0"
            >
              <Plus size={15} />
              {tab==='clientes' ? 'Novo Cliente' : tab==='vigilantes' ? 'Novo Vigilante' : 'Novo Veículo'}
            </button>
          )}
        </div>

        {/* ── TABLE CLIENTES — Desktop ── */}
        {tab === 'clientes' && (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full table-content">
                <thead>
                  <tr>
                    <th>Cliente</th>
                    <th>CNPJ</th>
                    <th>Contato</th>
                    <th>Telefone</th>
                    <th>Status</th>
                    {canEdit && <th className="text-right">Ações</th>}
                  </tr>
                </thead>
                <tbody>
                  {filteredClientes.length === 0 && (
                    <tr><td colSpan={6} className="text-center py-10 text-gray-400">Nenhum cliente cadastrado</td></tr>
                  )}
                  {filteredClientes.map(c => (
                    <tr key={c.id}>
                      <td>
                        <div className="flex items-center gap-2.5">
                          <div className="w-3 h-3 rounded-full shrink-0" style={{ backgroundColor: c.cor_destaque ?? '#3b82f6' }} />
                          <span className="font-semibold text-gray-800">{c.nome_cliente}</span>
                        </div>
                      </td>
                      <td className="font-mono text-gray-500">{c.cnpj ?? '—'}</td>
                      <td>{c.contato ?? '—'}</td>
                      <td>{c.telefone ?? '—'}</td>
                      <td><StatusBadge status={c.status} /></td>
                      {canEdit && (
                        <td className="text-right">
                          <div className="flex items-center justify-end gap-1">
                            <button onClick={() => { setEditCliente(c.id); setFormCliente({ nome_cliente:c.nome_cliente, cnpj:c.cnpj??'', contato:c.contato??'', telefone:c.telefone??'', cor_destaque:c.cor_destaque??'#3b82f6', status:c.status, observacoes:c.observacoes??'' }); setDialogCliente(true) }}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-blue-600 hover:bg-blue-50 transition-colors">
                              <Pencil size={14} />
                            </button>
                            <button onClick={() => deleteCliente(c.id)}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-red-600 hover:bg-red-50 transition-colors">
                              <Trash2 size={14} />
                            </button>
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Cards Clientes Mobile */}
            <div className="md:hidden px-4 pb-4 space-y-3">
              {filteredClientes.length === 0 && (
                <p className="text-center py-10 text-gray-400 text-sm">Nenhum cliente cadastrado</p>
              )}
              {filteredClientes.map(c => (
                <div key={c.id} className="bg-white rounded-xl p-4 shadow-sm border border-gray-100">
                  <div className="flex items-start justify-between gap-2 mb-2">
                    <div className="flex items-center gap-2.5">
                      <div className="w-4 h-4 rounded-full shrink-0 mt-0.5" style={{ backgroundColor: c.cor_destaque ?? '#3b82f6' }} />
                      <span className="font-bold text-gray-800 text-sm">{c.nome_cliente}</span>
                    </div>
                    <StatusBadge status={c.status} />
                  </div>
                  <div className="space-y-1 text-xs mb-3 pl-6">
                    {c.cnpj && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-14 shrink-0">CNPJ</span>
                        <span className="font-mono text-gray-600">{c.cnpj}</span>
                      </div>
                    )}
                    {c.contato && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-14 shrink-0">Contato</span>
                        <span className="text-gray-600">{c.contato}</span>
                      </div>
                    )}
                    {c.telefone && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-14 shrink-0">Tel.</span>
                        <span className="text-gray-600">{c.telefone}</span>
                      </div>
                    )}
                  </div>
                  {canEdit && (
                    <div className="flex gap-2 pt-3 border-t border-gray-100">
                      <button
                        onClick={() => { setEditCliente(c.id); setFormCliente({ nome_cliente:c.nome_cliente, cnpj:c.cnpj??'', contato:c.contato??'', telefone:c.telefone??'', cor_destaque:c.cor_destaque??'#3b82f6', status:c.status, observacoes:c.observacoes??'' }); setDialogCliente(true) }}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}>
                        <Pencil size={14} /> Editar
                      </button>
                      <button
                        onClick={() => deleteCliente(c.id)}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>
                        <Trash2 size={14} /> Excluir
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </>
        )}

        {/* ── TABLE VIGILANTES — Desktop ── */}
        {tab === 'vigilantes' && (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full table-content">
                <thead>
                  <tr>
                    <th>Nome</th>
                    <th>CPF</th>
                    <th>Função</th>
                    <th>CNV</th>
                    <th>Valor Padrão</th>
                    <th>Status</th>
                    {canEdit && <th className="text-right">Ações</th>}
                  </tr>
                </thead>
                <tbody>
                  {filteredVigilantes.length === 0 && (
                    <tr><td colSpan={7} className="text-center py-10 text-gray-400">Nenhum vigilante cadastrado</td></tr>
                  )}
                  {filteredVigilantes.map(v => (
                    <tr key={v.id}>
                      <td className="font-semibold text-gray-800">{v.nome_completo}</td>
                      <td className="font-mono text-gray-500">{v.cpf}</td>
                      <td className="text-gray-600">{funcoes.find(f => f.id === v.funcao_id)?.nome ?? '—'}</td>
                      <td className="font-mono text-gray-500">{v.cnv ?? '—'}</td>
                      <td className="text-gray-700">
                        {v.valor_padrao_pago != null
                          ? new Intl.NumberFormat('pt-BR', { style:'currency', currency:'BRL' }).format(v.valor_padrao_pago)
                          : '—'}
                      </td>
                      <td><StatusBadge status={v.status} /></td>
                      {canEdit && (
                        <td className="text-right">
                          <div className="flex items-center justify-end gap-1">
                            <button onClick={() => { setEditVigilante(v.id); setFormVigilante({ nome_completo:v.nome_completo, cpf:v.cpf, funcao_id:v.funcao_id??'', cnv:v.cnv??'', extensao_escolta_armada:v.extensao_escolta_armada??'', valor_padrao_pago:v.valor_padrao_pago??0, status:v.status }); setDialogVigilante(true) }}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-blue-600 hover:bg-blue-50 transition-colors">
                              <Pencil size={14} />
                            </button>
                            <button onClick={() => deleteVigilante(v.id)}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-red-600 hover:bg-red-50 transition-colors">
                              <Trash2 size={14} />
                            </button>
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Cards Vigilantes Mobile */}
            <div className="md:hidden px-4 pb-4 space-y-3">
              {filteredVigilantes.length === 0 && (
                <p className="text-center py-10 text-gray-400 text-sm">Nenhum vigilante cadastrado</p>
              )}
              {filteredVigilantes.map(v => (
                <div key={v.id} className="bg-white rounded-xl p-4 shadow-sm border border-gray-100">
                  <div className="flex items-start justify-between gap-2 mb-2">
                    <span className="font-bold text-gray-800 text-sm">{v.nome_completo}</span>
                    <StatusBadge status={v.status} />
                  </div>
                  <div className="space-y-1 text-xs mb-3">
                    <div className="flex gap-2">
                      <span className="text-gray-400 w-16 shrink-0">CPF</span>
                      <span className="font-mono text-gray-600">{v.cpf}</span>
                    </div>
                    <div className="flex gap-2">
                      <span className="text-gray-400 w-16 shrink-0">Função</span>
                      <span className="text-gray-600">{funcoes.find(f => f.id === v.funcao_id)?.nome ?? '—'}</span>
                    </div>
                    {v.cnv && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-16 shrink-0">CNV</span>
                        <span className="font-mono text-gray-600">{v.cnv}</span>
                      </div>
                    )}
                    {v.valor_padrao_pago != null && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-16 shrink-0">Valor</span>
                        <span className="text-gray-700 font-semibold">
                          {new Intl.NumberFormat('pt-BR', { style:'currency', currency:'BRL' }).format(v.valor_padrao_pago)}
                        </span>
                      </div>
                    )}
                  </div>
                  {canEdit && (
                    <div className="flex gap-2 pt-3 border-t border-gray-100">
                      <button
                        onClick={() => { setEditVigilante(v.id); setFormVigilante({ nome_completo:v.nome_completo, cpf:v.cpf, funcao_id:v.funcao_id??'', cnv:v.cnv??'', extensao_escolta_armada:v.extensao_escolta_armada??'', valor_padrao_pago:v.valor_padrao_pago??0, status:v.status }); setDialogVigilante(true) }}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}>
                        <Pencil size={14} /> Editar
                      </button>
                      <button
                        onClick={() => deleteVigilante(v.id)}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>
                        <Trash2 size={14} /> Excluir
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </>
        )}

        {/* ── TABLE VEÍCULOS — Desktop ── */}
        {tab === 'veiculos' && (
          <>
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full table-content">
                <thead>
                  <tr>
                    <th>Placa</th>
                    <th>Modelo</th>
                    <th>Tipo</th>
                    <th>Status</th>
                    {canEdit && <th className="text-right">Ações</th>}
                  </tr>
                </thead>
                <tbody>
                  {filteredVeiculos.length === 0 && (
                    <tr><td colSpan={5} className="text-center py-10 text-gray-400">Nenhum veículo cadastrado</td></tr>
                  )}
                  {filteredVeiculos.map(v => (
                    <tr key={v.id}>
                      <td className="font-mono font-bold text-gray-800">{v.placa}</td>
                      <td className="text-gray-700">{v.modelo ?? '—'}</td>
                      <td className="text-gray-600">{tipos.find(t => t.id === v.tipo_id)?.nome ?? '—'}</td>
                      <td>
                        <span className={v.status === 'ativo' ? 'badge-success' : v.status === 'manutencao' ? 'badge-warning' : 'badge-neutral'}>
                          {v.status === 'ativo' ? <CheckCircle size={10}/> : <XCircle size={10}/>}
                          {v.status}
                        </span>
                      </td>
                      {canEdit && (
                        <td className="text-right">
                          <div className="flex items-center justify-end gap-1">
                            <button onClick={() => { setEditVeiculo(v.id); setFormVeiculo({ tipo_id:v.tipo_id??'', placa:v.placa, modelo:v.modelo??'', status:v.status, observacoes:v.observacoes??'' }); setDialogVeiculo(true) }}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-blue-600 hover:bg-blue-50 transition-colors">
                              <Pencil size={14} />
                            </button>
                            <button onClick={() => deleteVeiculo(v.id)}
                              className="p-1.5 rounded-lg text-gray-400 hover:text-red-600 hover:bg-red-50 transition-colors">
                              <Trash2 size={14} />
                            </button>
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Cards Veículos Mobile */}
            <div className="md:hidden px-4 pb-4 space-y-3">
              {filteredVeiculos.length === 0 && (
                <p className="text-center py-10 text-gray-400 text-sm">Nenhum veículo cadastrado</p>
              )}
              {filteredVeiculos.map(v => (
                <div key={v.id} className="bg-white rounded-xl p-4 shadow-sm border border-gray-100">
                  <div className="flex items-start justify-between gap-2 mb-2">
                    <span className="font-mono font-bold text-gray-800 text-base">{v.placa}</span>
                    <span className={v.status === 'ativo' ? 'badge-success' : v.status === 'manutencao' ? 'badge-warning' : 'badge-neutral'}>
                      {v.status === 'ativo' ? <CheckCircle size={10}/> : <XCircle size={10}/>}
                      {v.status}
                    </span>
                  </div>
                  <div className="space-y-1 text-xs mb-3">
                    {v.modelo && (
                      <div className="flex gap-2">
                        <span className="text-gray-400 w-12 shrink-0">Modelo</span>
                        <span className="text-gray-700">{v.modelo}</span>
                      </div>
                    )}
                    <div className="flex gap-2">
                      <span className="text-gray-400 w-12 shrink-0">Tipo</span>
                      <span className="text-gray-600">{tipos.find(t => t.id === v.tipo_id)?.nome ?? '—'}</span>
                    </div>
                  </div>
                  {canEdit && (
                    <div className="flex gap-2 pt-3 border-t border-gray-100">
                      <button
                        onClick={() => { setEditVeiculo(v.id); setFormVeiculo({ tipo_id:v.tipo_id??'', placa:v.placa, modelo:v.modelo??'', status:v.status, observacoes:v.observacoes??'' }); setDialogVeiculo(true) }}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#EBF3FC', color: '#2166A8' }}>
                        <Pencil size={14} /> Editar
                      </button>
                      <button
                        onClick={() => deleteVeiculo(v.id)}
                        className="flex-1 flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-semibold"
                        style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>
                        <Trash2 size={14} /> Excluir
                      </button>
                    </div>
                  )}
                </div>
              ))}
            </div>
          </>
        )}

        {/* Footer */}
        <div className="px-4 py-3 border-t border-gray-100 flex items-center">
          <p className="text-xs text-gray-400">
            {tab==='clientes' ? filteredClientes.length : tab==='vigilantes' ? filteredVigilantes.length : filteredVeiculos.length} registro(s) encontrado(s)
          </p>
        </div>
      </div>

      {/* ── DIALOG: CLIENTE ── */}
      <Dialog open={dialogCliente} onClose={() => setDialogCliente(false)}
        title={editCliente ? 'Editar Cliente' : 'Novo Cliente'}
        subtitle="Preencha os dados do cliente">
        <Field label="Nome do Cliente *">
          <input className="input-light min-h-[48px] md:min-h-0" value={formCliente.nome_cliente} onChange={e => setFormCliente(p => ({...p, nome_cliente:e.target.value}))} />
        </Field>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="CNPJ">
            <input className="input-light min-h-[48px] md:min-h-0" value={formCliente.cnpj??''} onChange={e => setFormCliente(p => ({...p, cnpj:e.target.value}))} />
          </Field>
          <Field label="Telefone">
            <input className="input-light min-h-[48px] md:min-h-0" value={formCliente.telefone??''} onChange={e => setFormCliente(p => ({...p, telefone:e.target.value}))} />
          </Field>
        </div>
        <Field label="Contato">
          <input className="input-light min-h-[48px] md:min-h-0" value={formCliente.contato??''} onChange={e => setFormCliente(p => ({...p, contato:e.target.value}))} />
        </Field>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="Cor de Destaque">
            <div className="flex items-center gap-2">
              <input type="color" value={formCliente.cor_destaque??'#3b82f6'} onChange={e => setFormCliente(p => ({...p, cor_destaque:e.target.value}))}
                className="w-10 h-9 rounded-lg border border-gray-300 cursor-pointer" />
              <span className="text-sm font-mono text-gray-500">{formCliente.cor_destaque}</span>
            </div>
          </Field>
          <Field label="Status">
            <select className="input-light min-h-[48px] md:min-h-0" value={formCliente.status} onChange={e => setFormCliente(p => ({...p, status:e.target.value}))}>
              <option value="ativo">Ativo</option>
              <option value="inativo">Inativo</option>
            </select>
          </Field>
        </div>
        <Field label="Observações">
          <textarea className="input-light min-h-[72px] resize-none" value={formCliente.observacoes??''} onChange={e => setFormCliente(p => ({...p, observacoes:e.target.value}))} />
        </Field>
        <div className="flex flex-col-reverse md:flex-row gap-2 pt-2">
          <button onClick={() => setDialogCliente(false)} className="btn-outline w-full md:flex-1 min-h-[44px]">Cancelar</button>
          <button onClick={saveCliente} disabled={!formCliente.nome_cliente || saving} className="btn-gradient w-full md:flex-1 min-h-[44px]">
            {saving ? 'Salvando...' : 'Salvar'}
          </button>
        </div>
      </Dialog>

      {/* ── DIALOG: VIGILANTE ── */}
      <Dialog open={dialogVigilante} onClose={() => setDialogVigilante(false)}
        title={editVigilante ? 'Editar Vigilante' : 'Novo Vigilante'}
        subtitle="Preencha os dados do vigilante">
        <Field label="Nome Completo *">
          <input className="input-light min-h-[48px] md:min-h-0" value={formVigilante.nome_completo} onChange={e => setFormVigilante(p => ({...p, nome_completo:e.target.value}))} />
        </Field>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="CPF *">
            <input className="input-light font-mono min-h-[48px] md:min-h-0" value={formVigilante.cpf} onChange={e => setFormVigilante(p => ({...p, cpf:e.target.value}))} />
          </Field>
          <Field label="Função">
            <select className="input-light min-h-[48px] md:min-h-0" value={formVigilante.funcao_id??''} onChange={e => setFormVigilante(p => ({...p, funcao_id:e.target.value}))}>
              <option value="">Selecione...</option>
              {funcoes.map(f => <option key={f.id} value={f.id}>{f.nome}</option>)}
            </select>
          </Field>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="CNV">
            <input className="input-light font-mono min-h-[48px] md:min-h-0" value={formVigilante.cnv??''} onChange={e => setFormVigilante(p => ({...p, cnv:e.target.value}))} />
          </Field>
          <Field label="Extensão EEA">
            <input className="input-light font-mono min-h-[48px] md:min-h-0" value={formVigilante.extensao_escolta_armada??''} onChange={e => setFormVigilante(p => ({...p, extensao_escolta_armada:e.target.value}))} />
          </Field>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="Valor Padrão (R$)">
            <input type="number" className="input-light min-h-[48px] md:min-h-0" value={formVigilante.valor_padrao_pago??0} onChange={e => setFormVigilante(p => ({...p, valor_padrao_pago:Number(e.target.value)}))} />
          </Field>
          <Field label="Status">
            <select className="input-light min-h-[48px] md:min-h-0" value={formVigilante.status} onChange={e => setFormVigilante(p => ({...p, status:e.target.value}))}>
              <option value="ativo">Ativo</option>
              <option value="inativo">Inativo</option>
            </select>
          </Field>
        </div>
        <div className="flex flex-col-reverse md:flex-row gap-2 pt-2">
          <button onClick={() => setDialogVigilante(false)} className="btn-outline w-full md:flex-1 min-h-[44px]">Cancelar</button>
          <button onClick={saveVigilante} disabled={!formVigilante.nome_completo || !formVigilante.cpf || saving} className="btn-gradient w-full md:flex-1 min-h-[44px]">
            {saving ? 'Salvando...' : 'Salvar'}
          </button>
        </div>
      </Dialog>

      {/* ── DIALOG: VEÍCULO ── */}
      <Dialog open={dialogVeiculo} onClose={() => setDialogVeiculo(false)}
        title={editVeiculo ? 'Editar Veículo' : 'Novo Veículo'}
        subtitle="Preencha os dados do veículo">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
          <Field label="Placa *">
            <input className="input-light font-mono uppercase min-h-[48px] md:min-h-0" value={formVeiculo.placa} onChange={e => setFormVeiculo(p => ({...p, placa:e.target.value.toUpperCase()}))} />
          </Field>
          <Field label="Tipo">
            <select className="input-light min-h-[48px] md:min-h-0" value={formVeiculo.tipo_id??''} onChange={e => setFormVeiculo(p => ({...p, tipo_id:e.target.value}))}>
              <option value="">Selecione...</option>
              {tipos.map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
            </select>
          </Field>
        </div>
        <Field label="Modelo">
          <input className="input-light min-h-[48px] md:min-h-0" value={formVeiculo.modelo??''} onChange={e => setFormVeiculo(p => ({...p, modelo:e.target.value}))} />
        </Field>
        <Field label="Status">
          <select className="input-light min-h-[48px] md:min-h-0" value={formVeiculo.status} onChange={e => setFormVeiculo(p => ({...p, status:e.target.value}))}>
            <option value="ativo">Ativo</option>
            <option value="inativo">Inativo</option>
            <option value="manutencao">Em Manutenção</option>
          </select>
        </Field>
        <Field label="Observações">
          <textarea className="input-light min-h-[72px] resize-none" value={formVeiculo.observacoes??''} onChange={e => setFormVeiculo(p => ({...p, observacoes:e.target.value}))} />
        </Field>
        <div className="flex flex-col-reverse md:flex-row gap-2 pt-2">
          <button onClick={() => setDialogVeiculo(false)} className="btn-outline w-full md:flex-1 min-h-[44px]">Cancelar</button>
          <button onClick={saveVeiculo} disabled={!formVeiculo.placa || saving} className="btn-gradient w-full md:flex-1 min-h-[44px]">
            {saving ? 'Salvando...' : 'Salvar'}
          </button>
        </div>
      </Dialog>
    </div>
  )
}
