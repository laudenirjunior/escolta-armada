'use client'

import { useEffect, useState, useCallback } from 'react'
import { Plus, Search, Edit2, Truck } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Card, CardContent } from '@/components/ui/card'
import { Dialog } from '@/components/ui/dialog'
import { Select } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { Label } from '@/components/ui/label'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { formatarPlaca } from '@/utils/formatters'

interface TipoVeiculoRow {
  id: string
  nome: string
}

interface VeiculoRow {
  id: string
  tipo_id: string
  tipo: { nome: string } | null
  placa: string
  modelo: string | null
  status: 'ativo' | 'inativo' | 'manutencao'
  observacoes: string | null
  criado_em: string
}

type FormData = {
  tipo_id: string
  placa: string
  modelo: string
  status: 'ativo' | 'inativo' | 'manutencao'
  observacoes: string
}

const FORM_VAZIO: FormData = {
  tipo_id: '',
  placa: '',
  modelo: '',
  status: 'ativo',
  observacoes: '',
}

const STATUS_INFO = {
  ativo: { label: 'Ativo', variant: 'success' as const },
  inativo: { label: 'Inativo', variant: 'default' as const },
  manutencao: { label: 'Manutenção', variant: 'warning' as const },
}

const PODE_EDITAR = ['administrador', 'gestor', 'supervisor']

export default function VeiculosPage() {
  const [veiculos, setVeiculos] = useState<VeiculoRow[]>([])
  const [tipos, setTipos] = useState<TipoVeiculoRow[]>([])
  const [busca, setBusca] = useState('')
  const [filtroStatus, setFiltroStatus] = useState<'todos' | 'ativo' | 'inativo' | 'manutencao'>('todos')
  const [loading, setLoading] = useState(true)
  const [dialogAberto, setDialogAberto] = useState(false)
  const [editando, setEditando] = useState<VeiculoRow | null>(null)
  const [form, setForm] = useState<FormData>(FORM_VAZIO)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const { user } = useAuth()
  const supabase = createClient()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = supabase as any
  const podeEditar = PODE_EDITAR.includes(user?.perfil?.codigo ?? '')

  const carregar = useCallback(async () => {
    setLoading(true)
    const [{ data: veics }, { data: tps }] = await Promise.all([
      sb.from('veiculos').select('id, tipo_id, tipo:dom_tipos_veiculo(nome), placa, modelo, status, observacoes, criado_em').order('placa') as Promise<{ data: VeiculoRow[] | null }>,
      sb.from('dom_tipos_veiculo').select('id, nome').eq('ativo', true).order('nome') as Promise<{ data: TipoVeiculoRow[] | null }>,
    ])
    setVeiculos(veics ?? [])
    setTipos(tps ?? [])
    setLoading(false)
  }, [sb])

  useEffect(() => { carregar() }, [carregar])

  const abrirNovo = () => {
    setEditando(null)
    setForm({ ...FORM_VAZIO, tipo_id: tipos[0]?.id ?? '' })
    setErro(null)
    setDialogAberto(true)
  }

  const abrirEdicao = (v: VeiculoRow) => {
    setEditando(v)
    setForm({
      tipo_id: v.tipo_id,
      placa: v.placa,
      modelo: v.modelo ?? '',
      status: v.status,
      observacoes: v.observacoes ?? '',
    })
    setErro(null)
    setDialogAberto(true)
  }

  const salvar = async () => {
    if (!form.placa.trim() || !form.tipo_id) {
      setErro('Placa e tipo são obrigatórios.')
      return
    }
    setSalvando(true)
    setErro(null)

    const payload = {
      tipo_id: form.tipo_id,
      placa: form.placa.replace(/[^A-Za-z0-9]/g, '').toUpperCase(),
      modelo: form.modelo.trim() || null,
      status: form.status,
      observacoes: form.observacoes.trim() || null,
    }

    const { error } = editando
      ? await sb.from('veiculos').update(payload).eq('id', editando.id)
      : await sb.from('veiculos').insert(payload)

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

  const filtrados = veiculos.filter((v) => {
    if (filtroStatus !== 'todos' && v.status !== filtroStatus) return false
    if (!busca) return true
    const t = busca.toLowerCase()
    return (
      v.placa.toLowerCase().includes(t) ||
      (v.modelo ?? '').toLowerCase().includes(t) ||
      (v.tipo?.nome ?? '').toLowerCase().includes(t)
    )
  })

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold text-white">Veículos</h2>
          <p className="text-sm text-text-secondary mt-0.5">
            {filtrados.length} veículo{filtrados.length !== 1 ? 's' : ''}
          </p>
        </div>
        {podeEditar && (
          <Button onClick={abrirNovo} className="gap-2">
            <Plus size={16} />
            Novo Veículo
          </Button>
        )}
      </div>

      <div className="flex gap-3 flex-wrap">
        <div className="relative flex-1 min-w-48">
          <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-white/30" />
          <Input
            placeholder="Buscar por placa, modelo ou tipo..."
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            className="pl-9"
          />
        </div>
        <div className="flex gap-1">
          {(['todos', 'ativo', 'inativo', 'manutencao'] as const).map((s) => (
            <button
              key={s}
              onClick={() => setFiltroStatus(s)}
              className={`px-3 py-1.5 rounded-sm text-xs font-medium transition-colors ${
                filtroStatus === s
                  ? 'bg-sky-500 text-white'
                  : 'bg-white/5 text-white/40 hover:bg-white/10 hover:text-white/70'
              }`}
            >
              {s === 'todos' ? 'Todos' : STATUS_INFO[s].label}
            </button>
          ))}
        </div>
      </div>

      {loading ? (
        <p className="text-sm text-text-secondary">Carregando...</p>
      ) : filtrados.length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center">
            <p className="text-text-secondary text-sm">Nenhum veículo encontrado.</p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-1.5">
          {filtrados.map((v) => {
            const info = STATUS_INFO[v.status]
            return (
              <div
                key={v.id}
                className="flex items-center gap-4 p-4 bg-white/2 border border-white/5 hover:border-white/10 rounded-sm transition-colors"
              >
                <div className="w-9 h-9 rounded-sm bg-white/5 flex items-center justify-center text-white/40 shrink-0">
                  <Truck size={16} />
                </div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="text-sm font-mono font-semibold text-white">
                      {formatarPlaca(v.placa)}
                    </span>
                    <Badge variant={info.variant} className="text-[10px] h-4">
                      {info.label}
                    </Badge>
                    <span className="text-xs text-text-secondary">{v.tipo?.nome}</span>
                  </div>
                  {v.modelo && (
                    <p className="text-xs text-white/40 mt-0.5">{v.modelo}</p>
                  )}
                </div>
                {podeEditar && (
                  <Button variant="ghost" size="icon-sm" onClick={() => abrirEdicao(v)}>
                    <Edit2 size={14} />
                  </Button>
                )}
              </div>
            )
          })}
        </div>
      )}

      <Dialog
        isOpen={dialogAberto}
        onClose={() => setDialogAberto(false)}
        title={editando ? 'Editar Veículo' : 'Novo Veículo'}
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

          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Placa *</Label>
              <Input
                value={form.placa}
                onChange={(e) => upd({ placa: e.target.value.toUpperCase() })}
                placeholder="ABC-1234"
                maxLength={8}
              />
            </div>
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Tipo *</Label>
              <Select
                value={form.tipo_id}
                onChange={(e) => upd({ tipo_id: e.target.value })}
              >
                <option value="">Selecione...</option>
                {tipos.map((t) => (
                  <option key={t.id} value={t.id}>{t.nome}</option>
                ))}
              </Select>
            </div>
          </div>

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Modelo</Label>
            <Input
              value={form.modelo}
              onChange={(e) => upd({ modelo: e.target.value })}
              placeholder="Ex: Volkswagen Amarok 2022"
            />
          </div>

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Status</Label>
            <Select
              value={form.status}
              onChange={(e) => upd({ status: e.target.value as FormData['status'] })}
            >
              <option value="ativo">Ativo</option>
              <option value="inativo">Inativo</option>
              <option value="manutencao">Manutenção</option>
            </Select>
          </div>

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Observações</Label>
            <Textarea
              value={form.observacoes}
              onChange={(e) => upd({ observacoes: e.target.value })}
              placeholder="Observações sobre o veículo..."
              rows={3}
            />
          </div>
        </div>
      </Dialog>
    </div>
  )
}
