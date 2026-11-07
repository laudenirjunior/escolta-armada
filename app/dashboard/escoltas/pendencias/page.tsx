'use client'

/**
 * Pendências de conclusão (lote 2026-10, onda I, item 4.3.6 do adendo). Supervisor ou acima.
 * Escoltas concluídas pela gestão antes do fim, com o que não foi feito por etapa e viatura,
 * quem concluiu, quando e a observação. Filtro por período (data da conclusão) e cliente.
 * Lê escolta_conclusoes_antecipadas (só as válidas; a volta de etapa anula a lista) e
 * ignora escolta arquivada.
 */
import { useCallback, useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { ListChecks } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { PODE_VER_PENDENCIAS, temPermissao } from '@/lib/permissions'
import { rotuloStatus } from '@/lib/fluxo-escolta'
import { horaBR, totalItensPendentes, type PendenciaEtapa } from '@/lib/gestao'
import { ListaPendencias } from '@/components/escolta/acoes-gestao'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface Linha {
  id: string; escolta_id: string; status_no_momento: string; motivo: string; concluida_em: string
  pendencias: PendenciaEtapa[]; autor: { nome_completo: string } | null
  escolta: { codigo_escolta: string | null; cliente_id: string; cliente: { nome_cliente: string } | null } | null
}

const hojeISO = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' })

export default function PendenciasPage() {
  const router = useRouter()
  const { user } = useAuth()
  const podeVer = temPermissao(user?.perfil?.codigo, PODE_VER_PENDENCIAS)
  const [linhas, setLinhas] = useState<Linha[]>([])
  const [clientes, setClientes] = useState<{ id: string; nome_cliente: string }[]>([])
  const [de, setDe] = useState(() => { const d = new Date(Date.now() - 30 * 86400_000); return d.toLocaleDateString('sv-SE', { timeZone: 'America/Sao_Paulo' }) })
  const [ate, setAte] = useState(hojeISO)
  const [cliente, setCliente] = useState('')
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    let q = sb.from('escolta_conclusoes_antecipadas')
      .select('id, escolta_id, status_no_momento, motivo, concluida_em, pendencias, autor:usuarios!concluida_por(nome_completo), escolta:escoltas!inner(codigo_escolta, cliente_id, arquivada_em, cliente:clientes(nome_cliente))')
      .is('anulado_em', null)
      .is('escolta.arquivada_em', null)
      // Dia inteiro no horário de Brasília (UTC-3).
      .gte('concluida_em', `${de}T00:00:00-03:00`)
      .lte('concluida_em', `${ate}T23:59:59-03:00`)
      .order('concluida_em', { ascending: false })
    if (cliente) q = q.eq('escolta.cliente_id', cliente)
    const { data, error } = await q
    if (error) setErro(error.message)
    setLinhas((data ?? []) as Linha[])
    setCarregando(false)
  }, [de, ate, cliente])

  useEffect(() => { if (podeVer) carregar() }, [podeVer, carregar])
  useEffect(() => {
    if (!podeVer) return
    sb.from('clientes').select('id, nome_cliente').order('nome_cliente').then(({ data }: { data: { id: string; nome_cliente: string }[] | null }) => setClientes(data ?? []))
  }, [podeVer])

  if (!user) return null
  if (!podeVer) return <div className="p-6 text-sm">Acesso restrito a supervisor, gestor e administrador.</div>

  const total = linhas.reduce((s, l) => s + totalItensPendentes(l.pendencias), 0)

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <ListChecks size={20} style={{ color: '#1E2D35' }} />
        <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Pendências de conclusão</h1>
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <label className="text-xs font-semibold" style={{ color: '#5A6A80' }}>De<br /><input type="date" value={de} onChange={e => setDe(e.target.value)} className="input-light text-sm" /></label>
        <label className="text-xs font-semibold" style={{ color: '#5A6A80' }}>Até<br /><input type="date" value={ate} onChange={e => setAte(e.target.value)} className="input-light text-sm" /></label>
        <label className="text-xs font-semibold" style={{ color: '#5A6A80' }}>Cliente<br />
          <select value={cliente} onChange={e => setCliente(e.target.value)} className="input-light text-sm" data-teste="filtro-cliente">
            <option value="">Todos</option>
            {clientes.map(c => <option key={c.id} value={c.id}>{c.nome_cliente}</option>)}
          </select>
        </label>
      </div>
      {erro && <p className="text-sm" style={{ color: '#B83832' }}>{erro}</p>}
      {carregando ? <p className="text-sm" style={{ color: '#6B7E8A' }}>Carregando…</p>
        : linhas.length === 0 ? <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhuma escolta concluída com pendências no período.</p>
        : (
          <>
            <p className="text-sm" style={{ color: '#5A6A80' }}>{linhas.length} escolta(s), {total} item(ns) não feito(s).</p>
            <div className="space-y-3">
              {linhas.map(l => (
                <div key={l.id} className="p-4 bg-white space-y-2" style={{ border: '1px solid #D4D9E6', borderLeft: '4px solid #B7791F', borderRadius: '4px' }} data-teste="pendencia-escolta">
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <button type="button" onClick={() => router.push(`/dashboard/escoltas/${l.escolta_id}`)} className="text-sm font-black underline" style={{ color: '#1E2D35' }}>
                      {l.escolta?.codigo_escolta ?? 'Sem código'} · {l.escolta?.cliente?.nome_cliente ?? '-'}
                    </button>
                    <span className="text-xs" style={{ color: '#5A6A80' }}>{totalItensPendentes(l.pendencias)} item(ns)</span>
                  </div>
                  <p className="text-xs" style={{ color: '#5A6A80' }}>
                    Concluída em {horaBR(l.concluida_em)} (Brasília){l.autor?.nome_completo ? ` por ${l.autor.nome_completo}` : ''}, quando estava em {rotuloStatus(l.status_no_momento)}. Observação: {l.motivo}
                  </p>
                  <ListaPendencias pendencias={l.pendencias} />
                </div>
              ))}
            </div>
          </>
        )}
    </div>
  )
}
