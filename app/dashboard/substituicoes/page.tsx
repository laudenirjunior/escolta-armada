'use client'

/**
 * Substituições de equipe (lote 2026-10, M5, T3 e T7). Supervisor ou acima.
 *
 * Fila de pedidos pendentes com Aprovar e Recusar, histórico (quem, de quem, quando,
 * antecedência, motivo, quem decidiu, liberado por tempo) e os parâmetros das travas,
 * que só gestor e administrador editam. Toda regra é validada nas RPCs da migration 204.
 */
import { useCallback, useEffect, useState } from 'react'
import { Repeat, Check, X, Clock, Settings2, AlertTriangle } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { AvisosMural } from '@/components/escolta/avisos-mural'
import { horaBrasilia } from '@/lib/mural'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface Pedido {
  id: string; escolta_id: string; codigo: string; cliente: string; data_hora_prevista: string
  solicitante: string; equipe_antes: string; motivo: string; status: string
  criado_em: string; expira_em: string; antecedencia_min: number | null
  decidido_por: string | null; decidido_em: string | null; observacao_decisao: string | null
}
interface Config {
  janela_substituicao_min: number; aprovacao_tempo_limite_min: number; intervalo_comandante_h: number
  presenca_ligada: boolean; aviso_ligado: boolean
}
interface ResumoAvisos { envio_pelo_banco: boolean; erro_24h: number; pendente: number; enviado_24h: number }

const ROTULO: Record<string, { texto: string; cor: string }> = {
  pendente: { texto: 'Pendente', cor: '#8A5A10' },
  aprovado: { texto: 'Aprovado', cor: '#1E7C52' },
  liberado_por_tempo: { texto: 'Liberado por tempo', cor: '#2166A8' },
  recusado: { texto: 'Recusado', cor: '#B83832' },
  cancelado: { texto: 'Cancelado', cor: '#6B7E8A' },
  invalidado: { texto: 'Invalidado', cor: '#6B7E8A' },
}

const dataHora = (iso: string | null) => iso ? new Date(iso).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '-'
const antecedencia = (min: number | null) => min == null ? '-' : min >= 0 ? `${min} min antes` : `${-min} min depois`

export default function SubstituicoesPage() {
  const { user, loading: carregandoUsuario } = useAuth()
  const perfil = (user?.perfil?.codigo ?? '') as string
  const podeVer = ['administrador', 'gestor', 'supervisor'].includes(perfil)
  const podeConfigurar = ['administrador', 'gestor'].includes(perfil)

  const [pedidos, setPedidos] = useState<Pedido[]>([])
  const [config, setConfig] = useState<Config | null>(null)
  const [resumo, setResumo] = useState<ResumoAvisos | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const [ocupado, setOcupado] = useState<string | null>(null)
  const [recusando, setRecusando] = useState<string | null>(null)
  const [motivoRecusa, setMotivoRecusa] = useState('')

  const carregar = useCallback(async () => {
    const [{ data: p, error: e1 }, { data: c }, { data: r }] = await Promise.all([
      sb.rpc('listar_pedidos_mural', { p_desde: new Date(Date.now() - 30 * 86400_000).toISOString() }),
      sb.from('configuracoes_mural').select('janela_substituicao_min, aprovacao_tempo_limite_min, intervalo_comandante_h, presenca_ligada, aviso_ligado').maybeSingle(),
      sb.rpc('avisos_telegram_resumo'),
    ])
    if (e1) setMsg({ ok: false, texto: e1.message })
    setPedidos((p ?? []) as Pedido[])
    if (c) setConfig(c as Config)
    if (r) setResumo(r as ResumoAvisos)
  }, [])

  useEffect(() => {
    if (!podeVer) return
    carregar()
    const t = setInterval(carregar, 30_000)
    return () => clearInterval(t)
  }, [podeVer, carregar])

  const aprovar = async (p: Pedido) => {
    setOcupado(p.id); setMsg(null)
    const { data, error } = await sb.rpc('aprovar_pedido_mural', { p_pedido_id: p.id })
    if (error) setMsg({ ok: false, texto: error.message })
    else {
      setMsg({ ok: true, texto: data?.executado ? `Pedido aprovado: ${p.solicitante} assumiu a escolta ${p.codigo}.` : 'Pedido aprovado, mas a escolta mudou antes da execução; nada foi trocado.' })
      if (data?.aviso_pelo_banco === false) avisoCentral(p, 'Pedido de substituição aprovado', `${p.solicitante} assumiu. Equipe anterior: ${p.equipe_antes}.`)
    }
    setOcupado(null); await carregar()
  }

  const recusar = async (p: Pedido) => {
    setOcupado(p.id); setMsg(null)
    const { data, error } = await sb.rpc('recusar_pedido_mural', { p_pedido_id: p.id, p_motivo: motivoRecusa.trim() || null })
    if (error) setMsg({ ok: false, texto: error.message })
    else {
      setMsg({ ok: true, texto: `Pedido de ${p.solicitante} recusado. A equipe escalada continua.` })
      if (data?.aviso_pelo_banco === false) avisoCentral(p, 'Pedido de substituição recusado', `Motivo: ${motivoRecusa.trim() || 'não informado'}.`)
    }
    setRecusando(null); setMotivoRecusa(''); setOcupado(null); await carregar()
  }

  // Sem o envio pelo banco, o aviso ao chat central sai pela rota antiga, uma vez, de quem decidiu.
  const avisoCentral = (p: Pedido, titulo: string, descricao: string) => {
    fetch('/api/telegram', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tipo: 'status', destino: 'central', titulo, descricao, escolta_id: p.escolta_id, escolta_codigo: p.codigo }),
    }).catch(() => {})
  }

  const salvarConfig = async () => {
    if (!config) return
    setOcupado('config'); setMsg(null)
    const { data, error } = await sb.from('configuracoes_mural').update({ ...config, atualizado_em: new Date().toISOString() }).eq('id', 1).select('id')
    setMsg(error || !data?.length ? { ok: false, texto: error?.message ?? 'Sem permissão para alterar os parâmetros.' } : { ok: true, texto: 'Parâmetros salvos.' })
    setOcupado(null); await carregar()
  }

  if (carregandoUsuario) return null
  if (!podeVer) return <div className="p-6 text-sm">Acesso restrito a supervisor, gestor e administrador.</div>

  const pendentes = pedidos.filter(p => p.status === 'pendente')
  const historico = pedidos.filter(p => p.status !== 'pendente')

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3">
        <Repeat size={20} style={{ color: '#1E2D35' }} />
        <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Substituições de Equipe</h1>
      </div>

      <AvisosMural />

      {msg && (
        <div className="p-3 text-sm" style={{ backgroundColor: msg.ok ? '#E8F5EE' : 'rgba(184,56,50,0.08)', color: msg.ok ? '#1E7C52' : '#B83832', borderRadius: '4px' }}>
          {msg.texto}
        </div>
      )}

      {resumo && (resumo.erro_24h > 0 || !resumo.envio_pelo_banco) && (
        <div className="p-3 text-xs flex items-start gap-2" style={{ backgroundColor: '#FFF7E6', color: '#8A5A10', border: '1px solid #E9C46A', borderRadius: '4px' }}>
          <AlertTriangle size={14} style={{ flexShrink: 0, marginTop: 1 }} />
          <span>
            {!resumo.envio_pelo_banco
              ? 'O envio de avisos ao Telegram pelo banco não está configurado: os avisos do mural saem pelo navegador de quem gerou o evento, e a liberação por tempo avisa só no aplicativo.'
              : `${resumo.erro_24h} aviso(s) ao Telegram com erro nas últimas 24 h. Confira o token e o chat central no Vault.`}
          </span>
        </div>
      )}

      <section>
        <h2 className="text-xs font-black uppercase tracking-widest mb-2" style={{ color: '#6B7E8A' }}>Pedidos pendentes ({pendentes.length})</h2>
        {pendentes.length === 0 && <p className="text-sm" style={{ color: '#6B7E8A' }}>Nenhum pedido aguardando decisão.</p>}
        <div className="space-y-2">
          {pendentes.map(p => (
            <div key={p.id} className="p-4 bg-white" style={{ border: '1.5px solid #C8813A', borderRadius: '4px' }}>
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <p className="text-sm font-black" style={{ color: '#1E2D35' }}>{p.codigo} · {p.cliente}</p>
                <p className="text-xs flex items-center gap-1" style={{ color: '#8A5A10' }}>
                  <Clock size={12} /> Liberado às {horaBrasilia(p.expira_em)} se ninguém responder
                </p>
              </div>
              <p className="text-sm mt-2"><strong>{p.solicitante}</strong> pede para assumir. Equipe escalada: {p.equipe_antes}.</p>
              <p className="text-sm mt-1" style={{ color: '#5A6A80' }}>Prevista {dataHora(p.data_hora_prevista)} · pedido {antecedencia(p.antecedencia_min)}</p>
              <p className="text-sm mt-1"><strong>Motivo:</strong> {p.motivo}</p>
              {recusando === p.id ? (
                <div className="mt-3 space-y-2">
                  <textarea value={motivoRecusa} onChange={e => setMotivoRecusa(e.target.value)} rows={2} className="input-light w-full text-sm" placeholder="Motivo da recusa (vai para quem pediu e para o histórico)" />
                  <div className="flex gap-2">
                    <button type="button" onClick={() => recusar(p)} disabled={ocupado === p.id} className="flex-1 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '44px', backgroundColor: '#B83832' }}>Confirmar recusa</button>
                    <button type="button" onClick={() => setRecusando(null)} className="flex-1 text-xs font-bold" style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>Voltar</button>
                  </div>
                </div>
              ) : (
                <div className="mt-3 flex gap-2">
                  <button type="button" onClick={() => aprovar(p)} disabled={ocupado === p.id} className="flex-1 flex items-center justify-center gap-1 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '44px', backgroundColor: '#1E7C52' }}><Check size={14} /> Aprovar</button>
                  <button type="button" onClick={() => { setRecusando(p.id); setMotivoRecusa('') }} disabled={ocupado === p.id} className="flex-1 flex items-center justify-center gap-1 text-xs font-black uppercase disabled:opacity-50" style={{ minHeight: '44px', border: '1px solid #B83832', color: '#B83832' }}><X size={14} /> Recusar</button>
                </div>
              )}
            </div>
          ))}
        </div>
      </section>

      <section>
        <h2 className="text-xs font-black uppercase tracking-widest mb-2" style={{ color: '#6B7E8A' }}>Histórico (30 dias)</h2>
        <div className="overflow-x-auto bg-white" style={{ border: '1px solid #E2E8EC' }}>
          <table className="w-full text-xs">
            <thead>
              <tr style={{ backgroundColor: '#F4F6F9', color: '#5A6A80' }}>
                {['Pedido em', 'Escolta', 'Quem assumiu', 'De quem', 'Antecedência', 'Motivo', 'Resultado', 'Decidido por'].map(h => (
                  <th key={h} className="text-left px-3 py-2 font-black uppercase tracking-wider">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {historico.length === 0 && <tr><td colSpan={8} className="px-3 py-4" style={{ color: '#6B7E8A' }}>Nenhum pedido no período.</td></tr>}
              {historico.map(p => (
                <tr key={p.id} style={{ borderTop: '1px solid #EEF1F5' }}>
                  <td className="px-3 py-2 whitespace-nowrap">{dataHora(p.criado_em)}</td>
                  <td className="px-3 py-2 whitespace-nowrap font-mono">{p.codigo}</td>
                  <td className="px-3 py-2">{p.solicitante}</td>
                  <td className="px-3 py-2">{p.equipe_antes}</td>
                  <td className="px-3 py-2 whitespace-nowrap">{antecedencia(p.antecedencia_min)}</td>
                  <td className="px-3 py-2">{p.motivo}</td>
                  <td className="px-3 py-2 font-bold" style={{ color: ROTULO[p.status]?.cor }}>
                    {ROTULO[p.status]?.texto ?? p.status}
                    {p.observacao_decisao && <span className="block font-normal" style={{ color: '#6B7E8A' }}>{p.observacao_decisao}</span>}
                  </td>
                  <td className="px-3 py-2">{p.status === 'liberado_por_tempo' ? 'liberado por tempo' : p.decidido_por ?? '-'}{p.decidido_em ? ` · ${dataHora(p.decidido_em)}` : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      {config && (
        <section className="bg-white p-4" style={{ border: '1px solid #E2E8EC' }}>
          <h2 className="text-xs font-black uppercase tracking-widest mb-3 flex items-center gap-2" style={{ color: '#6B7E8A' }}>
            <Settings2 size={14} /> Regras do mural {podeConfigurar ? '' : '(só gestor e administrador alteram)'}
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3 text-sm">
            {([
              ['janela_substituicao_min', 'Substituição a partir de (min antes da hora prevista)'],
              ['aprovacao_tempo_limite_min', 'Tempo para a supervisão responder (min)'],
              ['intervalo_comandante_h', 'Intervalo mínimo entre escoltas do mesmo comandante (h)'],
            ] as const).map(([chave, rotulo]) => (
              <label key={chave} className="block">
                <span className="text-xs" style={{ color: '#5A6A80' }}>{rotulo}</span>
                <input type="number" min={0} disabled={!podeConfigurar} value={config[chave]}
                  onChange={e => setConfig({ ...config, [chave]: Number(e.target.value) })}
                  className="input-light w-full mt-1" />
              </label>
            ))}
            <label className="flex items-center gap-2"><input type="checkbox" disabled={!podeConfigurar} checked={config.presenca_ligada} onChange={e => setConfig({ ...config, presenca_ligada: e.target.checked })} /> Presença na base trava a substituição</label>
            <label className="flex items-center gap-2"><input type="checkbox" disabled={!podeConfigurar} checked={config.aviso_ligado} onChange={e => setConfig({ ...config, aviso_ligado: e.target.checked })} /> Avisos no aplicativo</label>
          </div>
          {podeConfigurar && (
            <button type="button" onClick={salvarConfig} disabled={ocupado === 'config'} className="mt-3 px-4 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '40px', backgroundColor: '#1E2D35' }}>
              Salvar regras
            </button>
          )}
        </section>
      )}
    </div>
  )
}
