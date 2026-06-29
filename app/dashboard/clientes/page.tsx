'use client'

import { useEffect, useState, useCallback } from 'react'
import { Plus, Search, Edit2 } from 'lucide-react'
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

interface ClienteRow {
  id: string
  nome_cliente: string
  cnpj: string | null
  contato: string
  telefone: string
  cor_destaque: string
  telegram_chat_id: string | null
  observacoes: string | null
  status: 'ativo' | 'inativo'
  valor_padrao_escolta: number | null
  criado_em: string
}

type FormData = {
  nome_cliente: string
  cnpj: string
  contato: string
  telefone: string
  cor_destaque: string
  telegram_chat_id: string
  observacoes: string
  status: 'ativo' | 'inativo'
  valor_padrao_escolta: string
}

const FORM_VAZIO: FormData = {
  nome_cliente: '',
  cnpj: '',
  contato: '',
  telefone: '',
  cor_destaque: '#3B82F6',
  telegram_chat_id: '',
  observacoes: '',
  status: 'ativo',
  valor_padrao_escolta: '',
}

const PODE_VER_FINANCEIRO = ['administrador', 'gestor', 'supervisor']

const PODE_EDITAR = ['administrador', 'gestor', 'supervisor']

export default function ClientesPage() {
  const [clientes, setClientes] = useState<ClienteRow[]>([])
  const [busca, setBusca] = useState('')
  const [loading, setLoading] = useState(true)
  const [dialogAberto, setDialogAberto] = useState(false)
  const [editando, setEditando] = useState<ClienteRow | null>(null)
  const [form, setForm] = useState<FormData>(FORM_VAZIO)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const { user } = useAuth()
  const supabase = createClient()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sb = supabase as any
  const podeEditar = PODE_EDITAR.includes((user?.perfil?.codigo ?? '') as any)
  const verFinanceiro = PODE_VER_FINANCEIRO.includes((user?.perfil?.codigo ?? '') as any)

  const carregar = useCallback(async () => {
    setLoading(true)
    const { data } = await sb
      .from('clientes')
      .select('id, nome_cliente, cnpj, contato, telefone, cor_destaque, telegram_chat_id, observacoes, status, valor_padrao_escolta, criado_em')
      .order('nome_cliente') as { data: ClienteRow[] | null }
    setClientes(data ?? [])
    setLoading(false)
  }, [sb])

  useEffect(() => { carregar() }, [carregar])

  const abrirNovo = () => {
    setEditando(null)
    setForm(FORM_VAZIO)
    setErro(null)
    setDialogAberto(true)
  }

  const abrirEdicao = (c: ClienteRow) => {
    setEditando(c)
    setForm({
      nome_cliente: c.nome_cliente,
      cnpj: c.cnpj ?? '',
      contato: c.contato,
      telefone: c.telefone,
      cor_destaque: c.cor_destaque,
      telegram_chat_id: c.telegram_chat_id ?? '',
      observacoes: c.observacoes ?? '',
      status: c.status,
      valor_padrao_escolta: c.valor_padrao_escolta?.toString() ?? '',
    })
    setErro(null)
    setDialogAberto(true)
  }

  const salvar = async () => {
    if (!form.nome_cliente.trim() || !form.contato.trim() || !form.telefone.trim()) {
      setErro('Nome, contato e telefone são obrigatórios.')
      return
    }
    setSalvando(true)
    setErro(null)

    const payload = {
      nome_cliente: form.nome_cliente.trim(),
      cnpj: form.cnpj.trim() || null,
      contato: form.contato.trim(),
      telefone: form.telefone.trim(),
      cor_destaque: form.cor_destaque,
      telegram_chat_id: form.telegram_chat_id.trim() || null,
      observacoes: form.observacoes.trim() || null,
      status: form.status,
      valor_padrao_escolta: form.valor_padrao_escolta ? parseFloat(form.valor_padrao_escolta) : null,
    }

    const { error } = editando
      ? await sb.from('clientes').update(payload).eq('id', editando.id)
      : await sb.from('clientes').insert(payload)

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

  const filtrados = clientes.filter((c) => {
    if (!busca) return true
    const t = busca.toLowerCase()
    return (
      c.nome_cliente.toLowerCase().includes(t) ||
      (c.cnpj ?? '').toLowerCase().includes(t) ||
      c.contato.toLowerCase().includes(t) ||
      c.telefone.includes(t)
    )
  })

  return (
    <div className="space-y-5">
      {/* ── Header ── */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold text-white">Clientes</h2>
          <p className="text-sm text-text-secondary mt-0.5">
            {filtrados.length} cliente{filtrados.length !== 1 ? 's' : ''}
          </p>
        </div>
        {podeEditar && (
          <Button onClick={abrirNovo} className="gap-2">
            <Plus size={16} />
            <span className="hidden sm:inline">Novo Cliente</span>
            <span className="sm:hidden">Novo</span>
          </Button>
        )}
      </div>

      {/* ── Busca ── */}
      <div className="relative w-full md:max-w-sm">
        <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-white/30" />
        <Input
          placeholder="Buscar cliente..."
          value={busca}
          onChange={(e) => setBusca(e.target.value)}
          className="pl-9 w-full"
        />
      </div>

      {/* ── Lista ── */}
      {loading ? (
        <p className="text-sm text-text-secondary">Carregando...</p>
      ) : filtrados.length === 0 ? (
        <Card>
          <CardContent className="py-12 text-center">
            <p className="text-text-secondary text-sm">Nenhum cliente encontrado.</p>
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-1.5">
          {filtrados.map((c) => (
            <div
              key={c.id}
              className="flex items-center gap-4 p-4 bg-white/2 border border-white/5 hover:border-white/10 rounded-sm transition-colors"
              style={{ borderLeftColor: c.cor_destaque, borderLeftWidth: 3 }}
            >
              <div className="flex-1 min-w-0">
                {/* Linha 1: nome + badges */}
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm font-semibold text-white">{c.nome_cliente}</span>
                  <Badge variant={c.status === 'ativo' ? 'success' : 'default'} className="text-[10px] h-4">
                    {c.status === 'ativo' ? 'Ativo' : 'Inativo'}
                  </Badge>
                  {c.telegram_chat_id && (
                    <Badge variant="info" className="text-[10px] h-4">Telegram</Badge>
                  )}
                </div>
                {/* Linha 2: contato + telefone + CNPJ — empilha no mobile */}
                <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 mt-0.5">
                  <span className="text-xs text-text-secondary">{c.contato}</span>
                  <span className="text-xs text-text-secondary hidden sm:inline">·</span>
                  <span className="text-xs text-text-secondary">{c.telefone}</span>
                  {c.cnpj && (
                    <>
                      <span className="text-xs text-text-secondary hidden sm:inline">·</span>
                      <span className="text-xs text-text-secondary">{c.cnpj}</span>
                    </>
                  )}
                </div>
              </div>
              {/* Valor padrão */}
              {verFinanceiro && c.valor_padrao_escolta != null && (
                <div style={{ textAlign: 'right', flexShrink: 0 }}>
                  <p style={{ fontSize: '11px', fontWeight: 900, color: '#4ade80', fontVariantNumeric: 'tabular-nums' }}>
                    R$ {c.valor_padrao_escolta.toLocaleString('pt-BR', { minimumFractionDigits: 2 })}
                  </p>
                  <p style={{ fontSize: '9px', color: 'rgba(255,255,255,0.3)', textTransform: 'uppercase', letterSpacing: '0.1em' }}>Valor padrão</p>
                </div>
              )}
              {/* Botão editar touch-friendly */}
              {podeEditar && (
                <Button
                  variant="ghost"
                  size="icon-sm"
                  onClick={() => abrirEdicao(c)}
                  className="min-h-[44px] min-w-[44px]"
                >
                  <Edit2 size={14} />
                </Button>
              )}
            </div>
          ))}
        </div>
      )}

      {/* ── Dialog ── */}
      <Dialog
        isOpen={dialogAberto}
        onClose={() => setDialogAberto(false)}
        title={editando ? 'Editar Cliente' : 'Novo Cliente'}
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
            <Label className="text-xs text-text-secondary mb-1 block">Nome *</Label>
            <Input
              value={form.nome_cliente}
              onChange={(e) => upd({ nome_cliente: e.target.value })}
              placeholder="Nome do cliente ou empresa"
            />
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">CNPJ</Label>
              <Input
                value={form.cnpj}
                onChange={(e) => upd({ cnpj: e.target.value })}
                placeholder="00.000.000/0000-00"
              />
            </div>
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Cor destaque</Label>
              <div className="flex items-center gap-2 h-8">
                <input
                  type="color"
                  value={form.cor_destaque}
                  onChange={(e) => upd({ cor_destaque: e.target.value })}
                  className="w-8 h-8 rounded-sm cursor-pointer border border-border bg-transparent"
                />
                <span className="text-xs text-text-secondary font-mono">{form.cor_destaque}</span>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Contato *</Label>
              <Input
                value={form.contato}
                onChange={(e) => upd({ contato: e.target.value })}
                placeholder="Nome do responsável"
              />
            </div>
            <div>
              <Label className="text-xs text-text-secondary mb-1 block">Telefone *</Label>
              <Input
                value={form.telefone}
                onChange={(e) => upd({ telefone: e.target.value })}
                placeholder="(11) 99999-9999"
              />
            </div>
          </div>

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Telegram Chat ID</Label>
            <Input
              value={form.telegram_chat_id}
              onChange={(e) => upd({ telegram_chat_id: e.target.value })}
              placeholder="-100123456789"
            />
          </div>

          {verFinanceiro && (
            <div style={{ borderTop: '1px solid rgba(255,255,255,0.06)', paddingTop: '12px', marginTop: '4px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '10px' }}>
                <div style={{ width: '3px', height: '3px', borderRadius: '50%', backgroundColor: '#4ade80', flexShrink: 0 }} />
                <p style={{ fontSize: '9px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.2em', color: 'rgba(255,255,255,0.3)', margin: 0 }}>Financeiro</p>
              </div>
              <div>
                <Label className="text-xs text-text-secondary mb-1 block">Valor padrão da escolta (R$)</Label>
                <Input
                  type="number"
                  min="0"
                  step="0.01"
                  value={form.valor_padrao_escolta}
                  onChange={(e) => upd({ valor_padrao_escolta: e.target.value })}
                  placeholder="0,00"
                />
                <p style={{ fontSize: '10px', color: 'rgba(255,255,255,0.25)', marginTop: '4px' }}>
                  Preenchido automaticamente ao criar uma nova escolta para este cliente.
                </p>
              </div>
            </div>
          )}

          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Observações</Label>
            <Textarea
              value={form.observacoes}
              onChange={(e) => upd({ observacoes: e.target.value })}
              placeholder="Informações adicionais..."
              rows={3}
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
      </Dialog>
    </div>
  )
}
