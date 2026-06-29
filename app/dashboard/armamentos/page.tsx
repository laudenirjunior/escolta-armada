'use client'

import { useEffect, useState, useCallback } from 'react'
import { Plus, Pencil, Trash2, Search, Crosshair, X } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

interface TipoArmamento { id: string; nome: string }
interface Calibre { id: string; nome: string }

interface ArmamentoRow {
  id: string
  numeracao: string | null
  documentacao: string | null
  status: 'ativo' | 'inativo'
  criado_em: string
  tipo: TipoArmamento | null
  calibre: Calibre | null
}

interface FormData {
  tipo_id: string
  calibre_id: string
  numeracao: string
  documentacao: string
  status: 'ativo' | 'inativo'
}

const FORM_INICIAL: FormData = {
  tipo_id: '',
  calibre_id: '',
  numeracao: '',
  documentacao: '',
  status: 'ativo',
}

const supabase = createClient()
const sb = supabase as any

const PODE_EDITAR = ['administrador', 'gestor', 'supervisor']

export default function ArmamentosPage() {
  const { user } = useAuth()
  const [armamentos, setArmamentos] = useState<ArmamentoRow[]>([])
  const [tipos, setTipos] = useState<TipoArmamento[]>([])
  const [calibres, setCalibre] = useState<Calibre[]>([])
  const [busca, setBusca] = useState('')
  const [loading, setLoading] = useState(true)
  const [dialogOpen, setDialogOpen] = useState(false)
  const [editando, setEditando] = useState<ArmamentoRow | null>(null)
  const [form, setForm] = useState<FormData>(FORM_INICIAL)
  const [saving, setSaving] = useState(false)
  const [erro, setErro] = useState('')
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)

  const perfil = user?.perfil?.codigo ?? ''
  const podeEditar = PODE_EDITAR.includes(perfil)

  const carregar = useCallback(async () => {
    setLoading(true)
    const [armQ, tipoQ, calQ] = await Promise.all([
      sb.from('armamentos').select(`
        id, numeracao, documentacao, status, criado_em,
        tipo:dom_tipos_armamento(id, nome),
        calibre:dom_calibres(id, nome)
      `).order('criado_em', { ascending: false }),
      sb.from('dom_tipos_armamento').select('id, nome').order('nome'),
      sb.from('dom_calibres').select('id, nome').order('nome'),
    ])
    setArmamentos((armQ.data ?? []) as ArmamentoRow[])
    setTipos((tipoQ.data ?? []) as TipoArmamento[])
    setCalibre((calQ.data ?? []) as Calibre[])
    setLoading(false)
  }, [])

  useEffect(() => { carregar() }, [carregar])

  const abrirNovo = () => {
    setEditando(null)
    setForm(FORM_INICIAL)
    setErro('')
    setDialogOpen(true)
  }

  const abrirEditar = (a: ArmamentoRow) => {
    setEditando(a)
    setForm({
      tipo_id: a.tipo?.id ?? '',
      calibre_id: a.calibre?.id ?? '',
      numeracao: a.numeracao ?? '',
      documentacao: a.documentacao ?? '',
      status: a.status,
    })
    setErro('')
    setDialogOpen(true)
  }

  const fecharDialog = () => {
    setDialogOpen(false)
    setEditando(null)
    setErro('')
  }

  const salvar = async () => {
    if (!form.tipo_id) { setErro('Selecione o tipo de armamento.'); return }
    if (!form.calibre_id) { setErro('Selecione o calibre.'); return }
    setSaving(true)
    setErro('')

    const payload = {
      tipo_id: form.tipo_id,
      calibre_id: form.calibre_id,
      numeracao: form.numeracao || null,
      documentacao: form.documentacao || null,
      status: form.status,
    }

    let err
    if (editando) {
      const res = await sb.from('armamentos').update(payload).eq('id', editando.id)
      err = res.error
    } else {
      const res = await sb.from('armamentos').insert(payload)
      err = res.error
    }

    if (err) {
      setErro(err.message ?? 'Erro ao salvar.')
    } else {
      fecharDialog()
      await carregar()
    }
    setSaving(false)
  }

  const excluir = async (id: string) => {
    const { error } = await sb.from('armamentos').delete().eq('id', id)
    if (!error) {
      setConfirmDelete(null)
      await carregar()
    }
  }

  const filtrados = armamentos.filter((a) => {
    if (!busca) return true
    const t = busca.toLowerCase()
    return (
      a.numeracao?.toLowerCase().includes(t) ||
      a.documentacao?.toLowerCase().includes(t) ||
      a.tipo?.nome.toLowerCase().includes(t) ||
      a.calibre?.nome.toLowerCase().includes(t)
    )
  })

  return (
    <div className="space-y-5">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="page-title">Armamentos</h1>
          <p className="page-subtitle">
            {filtrados.length} armamento{filtrados.length !== 1 ? 's' : ''} cadastrado{filtrados.length !== 1 ? 's' : ''}
          </p>
        </div>
        {podeEditar && (
          <button onClick={abrirNovo} className="btn-gradient">
            <Plus size={15} />
            Novo Armamento
          </button>
        )}
      </div>

      {/* ── Filtro ── */}
      <div className="card-light p-4">
        <div className="relative max-w-md">
          <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2" style={{ color: '#A8B8C2' }} />
          <input
            type="text"
            placeholder="Buscar por numeração, tipo, calibre..."
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            className="input-light pl-9"
          />
        </div>
      </div>

      {/* ── Table ── */}
      <div className="card-light overflow-x-auto">
        {loading ? (
          <div className="py-16 flex items-center justify-center gap-3">
            <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
            <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando...</span>
          </div>
        ) : filtrados.length === 0 ? (
          <div className="py-16 text-center">
            <div className="w-12 h-12 rounded-xl mx-auto mb-3 flex items-center justify-center"
              style={{ backgroundColor: '#F0F2F4' }}>
              <Crosshair size={20} style={{ color: '#C8D5DC' }} />
            </div>
            <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhum armamento encontrado</p>
            {podeEditar && (
              <button onClick={abrirNovo} className="btn-primary mt-4 mx-auto">
                <Plus size={14} />
                Cadastrar Armamento
              </button>
            )}
          </div>
        ) : (
          <table className="table-content">
            <thead>
              <tr>
                <th>Numeração</th>
                <th>Tipo</th>
                <th>Calibre</th>
                <th className="hidden md:table-cell">Documentação (GU)</th>
                <th>Status</th>
                {podeEditar && <th className="text-right">Ações</th>}
              </tr>
            </thead>
            <tbody>
              {filtrados.map((a) => (
                <tr key={a.id}>
                  <td>
                    <span className="font-mono text-xs font-bold" style={{ color: '#1E2D35' }}>
                      {a.numeracao ?? '—'}
                    </span>
                  </td>
                  <td>
                    <span className="text-sm" style={{ color: '#1E2D35' }}>
                      {a.tipo?.nome ?? '—'}
                    </span>
                  </td>
                  <td>
                    <span className="text-sm" style={{ color: '#1E2D35' }}>
                      {a.calibre?.nome ?? '—'}
                    </span>
                  </td>
                  <td className="hidden md:table-cell">
                    <span className="text-sm font-mono" style={{ color: '#6B7E8A' }}>
                      {a.documentacao ?? '—'}
                    </span>
                  </td>
                  <td>
                    <span className={a.status === 'ativo' ? 'badge-success' : 'badge-neutral'}>
                      {a.status === 'ativo' ? 'Ativo' : 'Inativo'}
                    </span>
                  </td>
                  {podeEditar && (
                    <td>
                      <div className="flex items-center justify-end gap-1">
                        <button
                          onClick={() => abrirEditar(a)}
                          className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                          style={{ color: '#6B7E8A' }}
                          onMouseEnter={(e) => {
                            (e.currentTarget as HTMLElement).style.backgroundColor = '#EBF7F1'
                            ;(e.currentTarget as HTMLElement).style.color = '#1E7C52'
                          }}
                          onMouseLeave={(e) => {
                            (e.currentTarget as HTMLElement).style.backgroundColor = ''
                            ;(e.currentTarget as HTMLElement).style.color = '#6B7E8A'
                          }}
                          title="Editar"
                        >
                          <Pencil size={13} />
                        </button>
                        <button
                          onClick={() => setConfirmDelete(a.id)}
                          className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                          style={{ color: '#6B7E8A' }}
                          onMouseEnter={(e) => {
                            (e.currentTarget as HTMLElement).style.backgroundColor = '#FEF0EE'
                            ;(e.currentTarget as HTMLElement).style.color = '#B83832'
                          }}
                          onMouseLeave={(e) => {
                            (e.currentTarget as HTMLElement).style.backgroundColor = ''
                            ;(e.currentTarget as HTMLElement).style.color = '#6B7E8A'
                          }}
                          title="Excluir"
                        >
                          <Trash2 size={13} />
                        </button>
                      </div>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* ── Dialog Add/Edit ── */}
      {dialogOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.45)' }}>
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-md"
            style={{ border: '1px solid #E2E8EC' }}>

            {/* Dialog header */}
            <div className="flex items-center justify-between px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="text-base font-bold" style={{ color: '#1E2D35' }}>
                {editando ? 'Editar Armamento' : 'Novo Armamento'}
              </h2>
              <button onClick={fecharDialog}
                className="w-7 h-7 rounded-lg flex items-center justify-center transition-all"
                style={{ color: '#6B7E8A' }}
                onMouseEnter={(e) => {
                  (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
                }}
                onMouseLeave={(e) => {
                  (e.currentTarget as HTMLElement).style.backgroundColor = ''
                }}
              >
                <X size={16} />
              </button>
            </div>

            {/* Dialog body */}
            <div className="px-6 py-5 space-y-4">

              {/* Tipo */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider"
                  style={{ color: '#6B7E8A' }}>
                  Tipo de Armamento *
                </label>
                <select
                  value={form.tipo_id}
                  onChange={(e) => setForm({ ...form, tipo_id: e.target.value })}
                  className="select-light w-full"
                >
                  <option value="">Selecione...</option>
                  {tipos.map((t) => (
                    <option key={t.id} value={t.id}>{t.nome}</option>
                  ))}
                </select>
              </div>

              {/* Calibre */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider"
                  style={{ color: '#6B7E8A' }}>
                  Calibre *
                </label>
                <select
                  value={form.calibre_id}
                  onChange={(e) => setForm({ ...form, calibre_id: e.target.value })}
                  className="select-light w-full"
                >
                  <option value="">Selecione...</option>
                  {calibres.map((c) => (
                    <option key={c.id} value={c.id}>{c.nome}</option>
                  ))}
                </select>
              </div>

              {/* Numeração */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider"
                  style={{ color: '#6B7E8A' }}>
                  Numeração (Série)
                </label>
                <input
                  type="text"
                  placeholder="Ex: AB1234567"
                  value={form.numeracao}
                  onChange={(e) => setForm({ ...form, numeracao: e.target.value })}
                  className="input-light"
                />
              </div>

              {/* Documentação */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider"
                  style={{ color: '#6B7E8A' }}>
                  Documentação (GU)
                </label>
                <input
                  type="text"
                  placeholder="Número do GU"
                  value={form.documentacao}
                  onChange={(e) => setForm({ ...form, documentacao: e.target.value })}
                  className="input-light"
                />
              </div>

              {/* Status */}
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider"
                  style={{ color: '#6B7E8A' }}>
                  Status
                </label>
                <select
                  value={form.status}
                  onChange={(e) => setForm({ ...form, status: e.target.value as 'ativo' | 'inativo' })}
                  className="select-light w-full"
                >
                  <option value="ativo">Ativo</option>
                  <option value="inativo">Inativo</option>
                </select>
              </div>

              {/* Error */}
              {erro && (
                <div className="px-3 py-2 rounded-lg text-xs font-medium"
                  style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>
                  {erro}
                </div>
              )}
            </div>

            {/* Dialog footer */}
            <div className="flex items-center justify-end gap-3 px-6 py-4 border-t"
              style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
              <button onClick={fecharDialog} className="btn-outline">
                Cancelar
              </button>
              <button onClick={salvar} disabled={saving} className="btn-primary">
                {saving ? 'Salvando...' : editando ? 'Salvar Alterações' : 'Cadastrar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* ── Confirm Delete ── */}
      {confirmDelete && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.45)' }}>
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-sm p-6"
            style={{ border: '1px solid #E2E8EC' }}>
            <div className="flex flex-col items-center text-center gap-3">
              <div className="w-12 h-12 rounded-full flex items-center justify-center"
                style={{ backgroundColor: '#FEF0EE' }}>
                <Trash2 size={20} style={{ color: '#B83832' }} />
              </div>
              <h3 className="text-base font-bold" style={{ color: '#1E2D35' }}>
                Excluir armamento?
              </h3>
              <p className="text-sm" style={{ color: '#6B7E8A' }}>
                Esta ação não pode ser desfeita. O armamento será removido permanentemente.
              </p>
            </div>
            <div className="flex gap-3 mt-5">
              <button onClick={() => setConfirmDelete(null)} className="btn-outline flex-1">
                Cancelar
              </button>
              <button onClick={() => excluir(confirmDelete)} className="btn-danger flex-1">
                Excluir
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
