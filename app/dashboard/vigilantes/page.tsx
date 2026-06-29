'use client'

import { useEffect, useState, useCallback } from 'react'
import { Plus, Search, Edit2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent } from '@/components/ui/card'
import { Dialog } from '@/components/ui/dialog'
import { Select } from '@/components/ui/select'
import { Label } from '@/components/ui/label'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatarCPF } from '@/utils/formatters'

interface FuncaoRow {
  id: string
  nome: string
}

interface VigilanteRow {
  id: string
  nome_completo: string
  cpf: string
  funcao_id: string
  funcao: { nome: string } | null
  cnv: string | null
  extensao_escolta_armada: string | null
  valor_padrao_pago: number | null
  status: 'ativo' | 'inativo'
  criado_em: string
}

type FormData = {
  nome_completo: string
  cpf: string
  funcao_id: string
  cnv: string
  extensao_escolta_armada: string
  valor_padrao_pago: string
  status: 'ativo' | 'inativo'
}

const FORM_VAZIO: FormData = {
  nome_completo: '',
  cpf: '',
  funcao_id: '',
  cnv: '',
  extensao_escolta_armada: '',
  valor_padrao_pago: '',
  status: 'ativo',
}

const PODE_EDITAR = ['administrador', 'gestor', 'supervisor']

export default function VigilantesPage() {
  const [vigilantes, setVigilantes] = useState<VigilanteRow[]>([])
  const [funcoes, setFuncoes] = useState<FuncaoRow[]>([])
  const [busca, setBusca] = useState('')
  const [filtroStatus, setFiltroStatus] = useState<'todos' | 'ativo' | 'inativo'>('todos')
  const [loading, setLoading] = useState(true)
  const [dialogAberto, setDialogAberto] = useState(false)
  const [editando, setEditando] = useState<VigilanteRow | null>(null)
  const [form, setForm] = useState<FormData>(FORM_VAZIO)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const { user } = useAuth()
  const supabase = createClient()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = supabase as any
  const podeEditar = PODE_EDITAR.includes((user?.perfil?.codigo ?? '') as any)
  const verFinanceiro = PODE_EDITAR.includes((user?.perfil?.codigo ?? '') as any)

  const carregar = useCallback(async () => {
    setLoading(true)
    const [{ data: vigs }, { data: funs }] = await Promise.all([
      sb.from('vigilantes').select('id, nome_completo, cpf, funcao_id, funcao:dom_funcoes(nome), cnv, extensao_escolta_armada, valor_padrao_pago, status, criado_em').order('nome_completo') as Promise<{ data: VigilanteRow[] | null }>,
      sb.from('dom_funcoes').select('id, nome').eq('ativo', true).order('nome') as Promise<{ data: FuncaoRow[] | null }>,
    ])
    setVigilantes(vigs ?? [])
    setFuncoes(funs ?? [])
    setLoading(false)
  }, [sb])

  useEffect(() => { carregar() }, [carregar])

  const abrirNovo = () => {
    setEditando(null)
    setForm({ ...FORM_VAZIO, funcao_id: funcoes[0]?.id ?? '' })
    setErro(null)
    setDialogAberto(true)
  }

  const abrirEdicao = (v: VigilanteRow) => {
    setEditando(v)
    setForm({
      nome_completo: v.nome_completo,
      cpf: v.cpf,
      funcao_id: v.funcao_id,
      cnv: v.cnv ?? '',
      extensao_escolta_armada: v.extensao_escolta_armada ?? '',
      valor_padrao_pago: v.valor_padrao_pago?.toString() ?? '',
      status: v.status,
    })
    setErro(null)
    setDialogAberto(true)
  }

  const salvar = async () => {
    if (!form.nome_completo.trim() || !form.cpf.trim() || !form.funcao_id) {
      setErro('Nome, CPF e função são obrigatórios.')
      return
    }
    setSalvando(true)
    setErro(null)

    const payload = {
      nome_completo: form.nome_completo.trim(),
      cpf: form.cpf.replace(/\D/g, ''),
      funcao_id: form.funcao_id,
      cnv: form.cnv.trim() || null,
      extensao_escolta_armada: form.extensao_escolta_armada.trim() || null,
      valor_padrao_pago: form.valor_padrao_pago ? parseFloat(form.valor_padrao_pago) : null,
      status: form.status,
    }

    const { error } = editando
      ? await sb.from('vigilantes').update(payload).eq('id', editando.id)
      : await sb.from('vigilantes').insert(payload)

    if (error) {
      setErro(error.message)
      setSalvando(false)
      return
    }

    setDialogAberto(false)
    setSalvando(false)
    carregar()
  }

  const upd = (patch: Partial<FormData>) => setForm(f => ({ ...f, ...patch }))

  const filtrados = vigilantes.filter((v) => {
    if (filtroStatus !== 'todos' && v.status !== filtroStatus) return false
    if (!busca) return true
    const t = busca.toLowerCase()
    return (
      v.nome_completo.toLowerCase().includes(t) ||
      v.cpf.includes(t) ||
      (v.cnv ?? '').toLowerCase().includes(t)
    )
  })

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold text-white">Vigilantes</h2>
          <p className="text-sm text-text-secondary mt-0.5">
            {filtrados.length} vigilante{filtrados.length !== 1 ? 's' : ''}
          </p>
        </div>
        {podeEditar && (
          <Button onClick={abrirNovo} className="gap-2">
            <Plus size={16} />
            Novo Vigilante
          </Button>
        )}
      </div>

      <div className="flex gap-3 flex-wrap">
        <div className="relative flex-1 min-w-48">
          <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-white/30" />
          <Input
            placeholder="Buscar por nome ou CPF..."
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            className="pl-9"
          />
        </div>
        <div className="flex gap-1">
          {(['todos', 'ativo', 'inativo'] as const).map((s) => (
            <button
              key={s}
              onClick={() => setFiltroStatus(s)}
              className={`px-3 py-1.5 rounded-sm text-xs font-medium transition-colors ${
                filtroStatus === s
                  ? 'bg-sky-500 text-white'
                  : 'bg-white/5 text-white/40 hover:bg-white/10 hover:text-white/70'
              }`}
            >
              {s === 'todos' ? 'Todos' : s === 'ativo' ? 'Ativos' : 'Inativos'}
            </button>
          ))}
        </div>
      </div>

      {loading ? (
        <p className="text-sm text-text-secondary">Carregando...</p>
      ) : filtrados.length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center">
            <p className="text-text-secondary text-sm">Nenhum vigilante encontrado.</p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-1.5">
          {filtrados.map((v) => (
            <div
              key={v.id}
              className="flex items-center gap-4 p-4 bg-white/2 border border-white/5 hover:border-white/10 rounded-sm transition-colors"
            >
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm font-semibold text-white">{v.nome_completo}</span>
                  <Badge variant={v.status === 'ativo' ? 'success' : 'default'} className="text-[10px] h-4">
                    {v.status === 'ativo' ? 'Ativo' : 'Inativo'}
                  </Badge>
                  <span className="text-xs text-text-secondary">{v.funcao?.nome}</span>
                </div>
                <div className="flex items-center gap-3 mt-0.5">
                  <span className="text-xs text-white/40 font-mono">{formatarCPF(v.cpf)}</span>
                  {v.cnv && <span className="text-xs text-text-secondary">CNV: {v.cnv}</span>}
                  {v.extensao_escolta_armada && (
                    <span className="text-xs text-text-secondary">Ext: {v.extensao_escolta_armada}</span>
                  )}
                </div>
              </div>
              {verFinanceiro && v.valor_padrao_pago != null && (
                <div style={{ textAlign: 'right', flexShrink: 0, marginRight: '8px' }}>
                  <p style={{ fontSize: '11px', fontWeight: 900, color: '#4ade80', fontVariantNumeric: 'tabular-nums' }}>
                    R$ {v.valor_padrao_pago.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}
                  </p>
                  <p style={{ fontSize: '9px', color: 'rgba(255,255,255,0.3)', textTransform: 'uppercase', letterSpacing: '0.1em' }}>Diária</p>
                </div>
              )}
              {podeEditar && (
                <Button variant="ghost" size="icon-sm" onClick={() => abrirEdicao(v)}>
                  <Edit2 size={14} />
                </Button>
              )}
            </div>
          ))}
        </div>
      )}

      <Dialog
        isOpen={dialogAberto}
        onClose={() => setDialogAberto(false)}
        title={editando ? 'Editar Vigilante' : 'Novo Vigilante'}
        footer={
          <>
            <Button variant="outline" onClick={() => setDialogAberto(false)}>Cancelar</Button>
            <Button onClick={salvar} disabled={salvando}>
              {salvando ? 'Salvando...' : 'Salvar'}
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          {erro && (
            <p className="text-xs text-red-400 bg-red-500/10 px-3 py-2 rounded-sm">{erro}</p>
          )}

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Nome completo *</Label>
            <Input
              value={form.nome_completo}
              onChange={(e) => upd({ nome_completo: e.target.value })}
              placeholder="Nome do vigilante"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">CPF *</Label>
              <Input
                value={form.cpf}
                onChange={(e) => upd({ cpf: e.target.value })}
                placeholder="000.000.000-00"
                maxLength={14}
              />
            </div>
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Função *</Label>
              <Select
                value={form.funcao_id}
                onChange={(e) => upd({ funcao_id: e.target.value })}
              >
                <option value="">Selecione...</option>
                {funcoes.map((f) => (
                  <option key={f.id} value={f.id}>{f.nome}</option>
                ))}
              </Select>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">CNV</Label>
              <Input
                value={form.cnv}
                onChange={(e) => upd({ cnv: e.target.value })}
                placeholder="Número do CNV"
              />
            </div>
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Extensão Escolta Armada</Label>
              <Input
                value={form.extensao_escolta_armada}
                onChange={(e) => upd({ extensao_escolta_armada: e.target.value })}
                placeholder="Número extensão"
              />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Valor padrão pago (R$)</Label>
              <Input
                type="number"
                min="0"
                step="0.01"
                value={form.valor_padrao_pago}
                onChange={(e) => upd({ valor_padrao_pago: e.target.value })}
                placeholder="0,00"
              />
            </div>
            {editando && (
              <div>
                <Label className="text-xs text-text-secondary mb-1 block">Status</Label>
                <Select
                  value={form.status}
                  onChange={(e) => upd({ status: e.target.value as 'ativo' | 'inativo' })}
                >
                  <option value="ativo">Ativo</option>
                  <option value="inativo">Inativo</option>
                </Select>
              </div>
            )}
          </div>
        </div>
      </Dialog>
    </div>
  )
}
