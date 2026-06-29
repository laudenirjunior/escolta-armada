'use client'

import { useEffect, useState, useCallback } from 'react'
import { ClipboardList, Plus, ChevronDown, ChevronRight, X, Check, Clock, Layers } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'

const supabase = createClient()
const sb = supabase as any

// ── Types ──────────────────────────────────────────────────────────────────

interface ChecklistResposta {
  id: string
  descricao_item: string
  conforme: boolean
  observacao: string | null
}

interface ChecklistRow {
  id: string
  concluido: boolean
  data_conclusao: string | null
  criado_em: string
  modelo: { nome: string; tipo: string } | null
  escolta_veiculo: {
    escolta: { codigo_escolta: string | null } | null
  } | null
  respostas?: ChecklistResposta[]
}

interface ModeloItem {
  id: string
  descricao_item: string
  exige_foto: boolean
  ordem: number
}

interface ModeloRow {
  id: string
  nome: string
  tipo: string
  versao: number
  ativo: boolean
  criado_em: string
  itens?: ModeloItem[]
  _count?: number
}

// ── Page ──────────────────────────────────────────────────────────────────

export default function ChecklistsPage() {
  useAuth()
  const [tab, setTab] = useState<'checklists' | 'modelos'>('checklists')
  const [checklists, setChecklists] = useState<ChecklistRow[]>([])
  const [modelos, setModelos] = useState<ModeloRow[]>([])
  const [expandedChecklist, setExpandedChecklist] = useState<string | null>(null)
  const [expandedModelo, setExpandedModelo] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  // New modelo dialog
  const [dialogModelo, setDialogModelo] = useState(false)
  const [novoNome, setNovoNome] = useState('')
  const [novoTipo, setNovoTipo] = useState<'material' | 'viatura'>('material')
  const [saving, setSaving] = useState(false)
  const [erro, setErro] = useState('')

  const carregarChecklists = useCallback(async () => {
    const { data } = await sb
      .from('checklists')
      .select(`
        id, concluido, data_conclusao, criado_em,
        modelo:checklist_modelos(nome, tipo),
        escolta_veiculo:escolta_veiculos(
          escolta:escoltas(codigo_escolta)
        )
      `)
      .order('criado_em', { ascending: false })
      .limit(50)
    setChecklists((data ?? []) as ChecklistRow[])
  }, [])

  const carregarModelos = useCallback(async () => {
    const { data: mods } = await sb
      .from('checklist_modelos')
      .select('id, nome, tipo, versao, ativo, criado_em')
      .order('nome')

    if (mods) {
      // Get item counts
      const enriched = await Promise.all(
        (mods as ModeloRow[]).map(async (m) => {
          const { count } = await sb
            .from('checklist_modelo_itens')
            .select('id', { count: 'exact', head: true })
            .eq('modelo_id', m.id)
          return { ...m, _count: count ?? 0 }
        })
      )
      setModelos(enriched)
    }
  }, [])

  useEffect(() => {
    const init = async () => {
      setLoading(true)
      await Promise.all([carregarChecklists(), carregarModelos()])
      setLoading(false)
    }
    init()
  }, [carregarChecklists, carregarModelos])

  const toggleChecklistExpand = async (id: string) => {
    if (expandedChecklist === id) {
      setExpandedChecklist(null)
      return
    }
    setExpandedChecklist(id)
    // Load respostas
    const existing = checklists.find((c) => c.id === id)
    if (!existing?.respostas) {
      const { data } = await sb
        .from('checklist_respostas')
        .select('id, descricao_item, conforme, observacao')
        .eq('checklist_id', id)
        .order('criado_em')
      setChecklists((prev) =>
        prev.map((c) => (c.id === id ? { ...c, respostas: data ?? [] } : c))
      )
    }
  }

  const toggleModeloExpand = async (id: string) => {
    if (expandedModelo === id) {
      setExpandedModelo(null)
      return
    }
    setExpandedModelo(id)
    const existing = modelos.find((m) => m.id === id)
    if (!existing?.itens) {
      const { data } = await sb
        .from('checklist_modelo_itens')
        .select('id, descricao_item, exige_foto, ordem')
        .eq('modelo_id', id)
        .order('ordem')
      setModelos((prev) =>
        prev.map((m) => (m.id === id ? { ...m, itens: data ?? [] } : m))
      )
    }
  }

  const criarModelo = async () => {
    if (!novoNome.trim()) { setErro('Informe o nome do modelo.'); return }
    setSaving(true)
    setErro('')
    const { error } = await sb.from('checklist_modelos').insert({
      nome: novoNome.trim(),
      tipo: novoTipo,
      versao: 1,
      ativo: true,
    })
    if (error) {
      setErro(error.message ?? 'Erro ao criar modelo.')
    } else {
      setDialogModelo(false)
      setNovoNome('')
      setNovoTipo('material')
      await carregarModelos()
    }
    setSaving(false)
  }

  return (
    <div className="space-y-5">

      {/* ── Header ── */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="page-title">Checklists</h1>
          <p className="page-subtitle">Gestão de checklists operacionais</p>
        </div>
        {tab === 'modelos' && (
          <button onClick={() => setDialogModelo(true)} className="btn-gradient">
            <Plus size={15} />
            Novo Modelo
          </button>
        )}
      </div>

      {/* ── Tabs ── */}
      <div className="card-light p-1 flex gap-1 w-fit">
        {([
          { key: 'checklists', label: 'Checklists das Escoltas', icon: <ClipboardList size={14} /> },
          { key: 'modelos', label: 'Modelos de Checklist', icon: <Layers size={14} /> },
        ] as const).map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className="flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-semibold transition-all"
            style={
              tab === t.key
                ? { backgroundColor: '#3A5464', color: '#fff' }
                : { color: '#6B7E8A', backgroundColor: '' }
            }
            onMouseEnter={(e) => {
              if (tab !== t.key) (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'
            }}
            onMouseLeave={(e) => {
              if (tab !== t.key) (e.currentTarget as HTMLElement).style.backgroundColor = ''
            }}
          >
            {t.icon}
            {t.label}
          </button>
        ))}
      </div>

      {/* ── Tab: Checklists ── */}
      {tab === 'checklists' && (
        <div className="card-light">
          {loading ? (
            <div className="py-16 flex items-center justify-center gap-3">
              <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
                style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
              <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando...</span>
            </div>
          ) : checklists.length === 0 ? (
            <div className="py-16 text-center">
              <ClipboardList size={32} className="mx-auto mb-2" style={{ color: '#E2E8EC' }} />
              <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>
                Nenhum checklist registrado
              </p>
            </div>
          ) : (
            <div>
              {/* Table header */}
              <div className="grid grid-cols-12 gap-2 px-4 py-2.5 border-b"
                style={{ borderColor: '#E2E8EC', backgroundColor: '#F4F4F9' }}>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Escolta</div>
                <div className="col-span-3 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Modelo</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Tipo</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Status</div>
                <div className="col-span-3 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Data Conclusão</div>
              </div>

              {checklists.map((c) => {
                const isOpen = expandedChecklist === c.id
                const codigoEscolta = c.escolta_veiculo?.escolta?.codigo_escolta ?? '—'
                return (
                  <div key={c.id}>
                    <button
                      onClick={() => toggleChecklistExpand(c.id)}
                      className="w-full grid grid-cols-12 gap-2 px-4 py-3 border-b text-left transition-all"
                      style={{
                        borderColor: '#E2E8EC',
                        backgroundColor: isOpen ? '#F8FAFC' : '',
                      }}
                      onMouseEnter={(e) => {
                        if (!isOpen) (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC'
                      }}
                      onMouseLeave={(e) => {
                        if (!isOpen) (e.currentTarget as HTMLElement).style.backgroundColor = ''
                      }}
                    >
                      <div className="col-span-2 flex items-center gap-1">
                        {isOpen ? <ChevronDown size={12} style={{ color: '#4A90A4' }} /> : <ChevronRight size={12} style={{ color: '#C8D5DC' }} />}
                        <span className="text-xs font-mono font-bold" style={{ color: '#1E2D35' }}>{codigoEscolta}</span>
                      </div>
                      <div className="col-span-3">
                        <span className="text-xs" style={{ color: '#1E2D35' }}>{c.modelo?.nome ?? '—'}</span>
                      </div>
                      <div className="col-span-2">
                        <span className={c.modelo?.tipo === 'viatura' ? 'badge-info' : 'badge-neutral'}>
                          {c.modelo?.tipo === 'viatura' ? 'Viatura' : 'Material'}
                        </span>
                      </div>
                      <div className="col-span-2">
                        {c.concluido
                          ? <span className="badge-success flex items-center gap-1 w-fit"><Check size={10} /> Concluído</span>
                          : <span className="badge-warning flex items-center gap-1 w-fit"><Clock size={10} /> Pendente</span>
                        }
                      </div>
                      <div className="col-span-3">
                        <span className="text-xs" style={{ color: '#6B7E8A' }}>
                          {c.data_conclusao
                            ? new Date(c.data_conclusao).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
                            : '—'
                          }
                        </span>
                      </div>
                    </button>

                    {/* Expanded respostas */}
                    {isOpen && (
                      <div className="border-b" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
                        {!c.respostas ? (
                          <div className="py-4 flex items-center justify-center gap-2">
                            <div className="w-3 h-3 rounded-full border-2 border-t-transparent animate-spin"
                              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
                            <span className="text-xs" style={{ color: '#6B7E8A' }}>Carregando respostas...</span>
                          </div>
                        ) : c.respostas.length === 0 ? (
                          <p className="text-xs text-center py-4" style={{ color: '#A8B8C2' }}>
                            Nenhuma resposta registrada
                          </p>
                        ) : (
                          <div className="px-8 py-3 space-y-2">
                            {c.respostas.map((r) => (
                              <div key={r.id} className="flex items-start gap-3">
                                <div className="mt-0.5 w-5 h-5 rounded-full flex items-center justify-center shrink-0"
                                  style={{ backgroundColor: r.conforme ? '#EBF7F1' : '#FEF0EE' }}>
                                  {r.conforme
                                    ? <Check size={11} style={{ color: '#1E7C52' }} />
                                    : <X size={11} style={{ color: '#B83832' }} />
                                  }
                                </div>
                                <div>
                                  <p className="text-xs font-medium" style={{ color: '#1E2D35' }}>
                                    {r.descricao_item}
                                  </p>
                                  {r.observacao && (
                                    <p className="text-[11px] mt-0.5" style={{ color: '#6B7E8A' }}>
                                      Obs: {r.observacao}
                                    </p>
                                  )}
                                </div>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      )}

      {/* ── Tab: Modelos ── */}
      {tab === 'modelos' && (
        <div className="card-light">
          {loading ? (
            <div className="py-16 flex items-center justify-center gap-3">
              <div className="w-5 h-5 rounded-full border-2 border-t-transparent animate-spin"
                style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
              <span className="text-sm" style={{ color: '#6B7E8A' }}>Carregando...</span>
            </div>
          ) : modelos.length === 0 ? (
            <div className="py-16 text-center">
              <Layers size={32} className="mx-auto mb-2" style={{ color: '#E2E8EC' }} />
              <p className="text-sm font-semibold" style={{ color: '#6B7E8A' }}>Nenhum modelo cadastrado</p>
              <button onClick={() => setDialogModelo(true)} className="btn-primary mt-4 mx-auto">
                <Plus size={14} />
                Criar Modelo
              </button>
            </div>
          ) : (
            <div>
              {/* Table header */}
              <div className="grid grid-cols-12 gap-2 px-4 py-2.5 border-b"
                style={{ borderColor: '#E2E8EC', backgroundColor: '#F4F4F9' }}>
                <div className="col-span-4 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Nome</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Tipo</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Versão</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Itens</div>
                <div className="col-span-2 text-[11px] font-bold uppercase tracking-wider" style={{ color: '#6B7E8A' }}>Status</div>
              </div>

              {modelos.map((m) => {
                const isOpen = expandedModelo === m.id
                return (
                  <div key={m.id}>
                    <button
                      onClick={() => toggleModeloExpand(m.id)}
                      className="w-full grid grid-cols-12 gap-2 px-4 py-3 border-b text-left transition-all"
                      style={{
                        borderColor: '#E2E8EC',
                        backgroundColor: isOpen ? '#F8FAFC' : '',
                      }}
                      onMouseEnter={(e) => {
                        if (!isOpen) (e.currentTarget as HTMLElement).style.backgroundColor = '#F8FAFC'
                      }}
                      onMouseLeave={(e) => {
                        if (!isOpen) (e.currentTarget as HTMLElement).style.backgroundColor = ''
                      }}
                    >
                      <div className="col-span-4 flex items-center gap-1.5">
                        {isOpen ? <ChevronDown size={12} style={{ color: '#4A90A4' }} /> : <ChevronRight size={12} style={{ color: '#C8D5DC' }} />}
                        <span className="text-sm font-semibold" style={{ color: '#1E2D35' }}>{m.nome}</span>
                      </div>
                      <div className="col-span-2">
                        <span className={m.tipo === 'viatura' ? 'badge-info' : 'badge-neutral'}>
                          {m.tipo === 'viatura' ? 'Viatura' : 'Material'}
                        </span>
                      </div>
                      <div className="col-span-2">
                        <span className="text-xs" style={{ color: '#6B7E8A' }}>v{m.versao}</span>
                      </div>
                      <div className="col-span-2">
                        <span className="text-xs font-semibold" style={{ color: '#1E2D35' }}>
                          {m._count ?? '—'} item{(m._count ?? 0) !== 1 ? 's' : ''}
                        </span>
                      </div>
                      <div className="col-span-2">
                        <span className={m.ativo ? 'badge-success' : 'badge-neutral'}>
                          {m.ativo ? 'Ativo' : 'Inativo'}
                        </span>
                      </div>
                    </button>

                    {/* Expanded items */}
                    {isOpen && (
                      <div className="border-b" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
                        {!m.itens ? (
                          <div className="py-4 flex items-center justify-center gap-2">
                            <div className="w-3 h-3 rounded-full border-2 border-t-transparent animate-spin"
                              style={{ borderColor: '#4A90A4', borderTopColor: 'transparent' }} />
                          </div>
                        ) : m.itens.length === 0 ? (
                          <p className="text-xs text-center py-4" style={{ color: '#A8B8C2' }}>
                            Nenhum item neste modelo
                          </p>
                        ) : (
                          <div className="px-8 py-3 space-y-1.5">
                            {m.itens.map((item, idx) => (
                              <div key={item.id} className="flex items-center gap-3">
                                <span className="text-[10px] font-mono w-5 text-right shrink-0" style={{ color: '#A8B8C2' }}>
                                  {idx + 1}.
                                </span>
                                <span className="text-xs" style={{ color: '#1E2D35' }}>
                                  {item.descricao_item}
                                </span>
                                {item.exige_foto && (
                                  <span className="badge-info text-[9px]">Foto obrigatória</span>
                                )}
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>
      )}

      {/* ── Dialog Novo Modelo ── */}
      {dialogModelo && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: 'rgba(0,0,0,0.45)' }}>
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-sm"
            style={{ border: '1px solid #E2E8EC' }}>
            <div className="flex items-center justify-between px-6 py-4 border-b" style={{ borderColor: '#E2E8EC' }}>
              <h2 className="text-base font-bold" style={{ color: '#1E2D35' }}>Novo Modelo de Checklist</h2>
              <button onClick={() => setDialogModelo(false)}
                className="w-7 h-7 rounded-lg flex items-center justify-center"
                style={{ color: '#6B7E8A' }}
                onMouseEnter={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = '#F0F2F4'}
                onMouseLeave={(e) => (e.currentTarget as HTMLElement).style.backgroundColor = ''}>
                <X size={16} />
              </button>
            </div>
            <div className="px-6 py-5 space-y-4">
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider" style={{ color: '#6B7E8A' }}>
                  Nome do Modelo *
                </label>
                <input
                  type="text"
                  placeholder="Ex: Checklist Pré-Saída"
                  value={novoNome}
                  onChange={(e) => setNovoNome(e.target.value)}
                  className="input-light"
                />
              </div>
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wider" style={{ color: '#6B7E8A' }}>
                  Tipo
                </label>
                <select
                  value={novoTipo}
                  onChange={(e) => setNovoTipo(e.target.value as 'material' | 'viatura')}
                  className="select-light w-full"
                >
                  <option value="material">Material</option>
                  <option value="viatura">Viatura</option>
                </select>
              </div>
              {erro && (
                <div className="px-3 py-2 rounded-lg text-xs font-medium"
                  style={{ backgroundColor: '#FEF0EE', color: '#B83832' }}>
                  {erro}
                </div>
              )}
            </div>
            <div className="flex gap-3 px-6 py-4 border-t" style={{ borderColor: '#E2E8EC', backgroundColor: '#F8FAFC' }}>
              <button onClick={() => setDialogModelo(false)} className="btn-outline flex-1">Cancelar</button>
              <button onClick={criarModelo} disabled={saving} className="btn-primary flex-1">
                {saving ? 'Criando...' : 'Criar Modelo'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
