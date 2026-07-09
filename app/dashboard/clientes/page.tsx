'use client'

import { useEffect, useState, useCallback } from 'react'
import { Plus, Search, Edit2, Upload, X, ImageIcon } from 'lucide-react'
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
  km_franquia: number | null
  valor_km_excedente: number | null
  criado_em: string
  metadados: { logo_url?: string } | null
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
  km_franquia: string
  valor_km_excedente: string
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
  km_franquia: '',
  valor_km_excedente: '',
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
  const [logoFile, setLogoFile] = useState<File | null>(null)
  const [logoPreview, setLogoPreview] = useState<string>('')
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
      .select('id, nome_cliente, cnpj, contato, telefone, cor_destaque, telegram_chat_id, observacoes, status, valor_padrao_escolta, km_franquia, valor_km_excedente, criado_em, metadados')
      .order('nome_cliente') as { data: ClienteRow[] | null }
    setClientes(data ?? [])
    setLoading(false)
  }, [sb])

  useEffect(() => { carregar() }, [carregar])

  const abrirNovo = () => {
    setEditando(null)
    setForm(FORM_VAZIO)
    setLogoFile(null)
    setLogoPreview('')
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
      km_franquia: c.km_franquia?.toString() ?? '',
      valor_km_excedente: c.valor_km_excedente?.toString() ?? '',
    })
    setLogoFile(null)
    setLogoPreview(c.metadados?.logo_url ?? '')
    setErro(null)
    setDialogAberto(true)
  }

  const selecionarLogo = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setLogoFile(file)
    setLogoPreview(URL.createObjectURL(file))
  }

  const removerLogo = () => {
    setLogoFile(null)
    setLogoPreview('')
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
      km_franquia: form.km_franquia ? parseInt(form.km_franquia) : 200,
      valor_km_excedente: form.valor_km_excedente ? parseFloat(form.valor_km_excedente) : 0,
    }

    let clienteId = editando?.id ?? ''

    const { data: savedData, error } = editando
      ? await sb.from('clientes').update(payload).eq('id', editando.id).select('id').single()
      : await sb.from('clientes').insert(payload).select('id').single()

    if (error) {
      setErro(error.message)
      setSalvando(false)
      return
    }

    if (!clienteId && savedData?.id) clienteId = savedData.id

    // Upload da logo se houver arquivo novo
    if (logoFile && clienteId) {
      const ext = logoFile.name.split('.').pop()?.toLowerCase() ?? 'png'
      const path = `logos/clientes/${clienteId}/logo.${ext}`
      const { error: upErr } = await sb.storage.from('fotos').upload(path, logoFile, { upsert: true })
      if (!upErr) {
        const { data: pub } = sb.storage.from('fotos').getPublicUrl(path)
        const metaAtual = editando?.metadados ?? {}
        await sb.from('clientes').update({
          metadados: { ...metaAtual, logo_url: pub.publicUrl },
        }).eq('id', clienteId)
      }
    } else if (!logoPreview && editando?.metadados?.logo_url) {
      // Logo foi removida manualmente
      const metaAtual = { ...editando.metadados }
      delete metaAtual.logo_url
      await sb.from('clientes').update({ metadados: metaAtual }).eq('id', clienteId)
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
              {/* Logo do cliente */}
              <div style={{ width: '40px', height: '40px', borderRadius: '4px', border: '1px solid rgba(255,255,255,0.1)', overflow: 'hidden', flexShrink: 0, backgroundColor: 'rgba(255,255,255,0.04)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                {c.metadados?.logo_url
                  ? <img src={c.metadados.logo_url} alt={c.nome_cliente} style={{ width: '100%', height: '100%', objectFit: 'contain', padding: '4px' }} />
                  : <ImageIcon size={16} style={{ color: 'rgba(255,255,255,0.15)' }} />}
              </div>
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
              <div className="grid grid-cols-2 gap-3" style={{ marginTop: '12px' }}>
                <div>
                  <Label className="text-xs text-text-secondary mb-1 block">Franquia KM</Label>
                  <Input
                    type="number"
                    min="1"
                    step="1"
                    value={form.km_franquia}
                    onChange={(e) => upd({ km_franquia: e.target.value })}
                    placeholder="200"
                  />
                </div>
                <div>
                  <Label className="text-xs text-text-secondary mb-1 block">Valor por KM Excedente (R$)</Label>
                  <Input
                    type="number"
                    min="0"
                    step="0.01"
                    value={form.valor_km_excedente}
                    onChange={(e) => upd({ valor_km_excedente: e.target.value })}
                    placeholder="0,00"
                  />
                </div>
              </div>
              <p style={{ fontSize: '10px', color: 'rgba(255,255,255,0.25)', marginTop: '4px' }}>
                Quilômetros extras acima da franquia serão cobrados pelo valor por KM.
              </p>
            </div>
          )}

          {/* ── Logo do Cliente ── */}
          <div>
            <Label className="text-xs text-text-secondary mb-1 block">Logo do Cliente</Label>
            {logoPreview ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: '12px', padding: '10px 12px', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '4px', backgroundColor: 'rgba(255,255,255,0.03)' }}>
                <img
                  src={logoPreview}
                  alt="Logo"
                  style={{ width: '64px', height: '40px', objectFit: 'contain', borderRadius: '2px', backgroundColor: '#fff', padding: '4px' }}
                />
                <div style={{ flex: 1 }}>
                  <p style={{ fontSize: '11px', color: 'rgba(255,255,255,0.7)', marginBottom: '2px' }}>{logoFile ? logoFile.name : 'Logo atual'}</p>
                  <p style={{ fontSize: '10px', color: 'rgba(255,255,255,0.3)' }}>Será usada nos relatórios PDF</p>
                </div>
                <button
                  type="button"
                  onClick={removerLogo}
                  style={{ padding: '4px', color: 'rgba(255,255,255,0.4)', background: 'none', border: 'none', cursor: 'pointer', borderRadius: '2px' }}
                  title="Remover logo"
                >
                  <X size={14} />
                </button>
              </div>
            ) : (
              <label style={{ display: 'flex', alignItems: 'center', gap: '10px', padding: '10px 14px', border: '1.5px dashed rgba(255,255,255,0.12)', borderRadius: '4px', cursor: 'pointer', backgroundColor: 'rgba(255,255,255,0.02)' }}
                onMouseEnter={e => (e.currentTarget as HTMLElement).style.borderColor = 'rgba(255,255,255,0.25)'}
                onMouseLeave={e => (e.currentTarget as HTMLElement).style.borderColor = 'rgba(255,255,255,0.12)'}
              >
                <Upload size={15} style={{ color: 'rgba(255,255,255,0.3)', flexShrink: 0 }} />
                <span style={{ fontSize: '12px', color: 'rgba(255,255,255,0.4)' }}>Clique para selecionar — PNG, JPG, SVG</span>
                <input type="file" accept="image/png,image/jpeg,image/svg+xml,image/webp" onChange={selecionarLogo} style={{ display: 'none' }} />
              </label>
            )}
          </div>

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
