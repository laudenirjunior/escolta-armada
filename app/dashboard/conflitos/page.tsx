'use client'

/**
 * Conflitos dos registros de campo (Lote 2026-10, onda L; docs/14, seção 16.3.9).
 * Supervisor, gestor ou administrador.
 *
 * Registro feito pelo operador (com ou sem conexão) que o servidor não aplicou: a escolta
 * mudou pela gestão (reset, arquivamento, conclusão), o status já era outro, a viatura
 * saiu, a etapa já tinha ponto, o operador saiu da equipe ou o banco recusou. Nada é
 * descartado: o conteúdo completo fica no livro (registros_campo) e aparece aqui, com as
 * fotos por URL assinada. "Marcar como tratado" exige justificativa e não apaga nada.
 * Leitura e tratamento só pelas RPCs listar_conflitos e tratar_conflito (migration 219).
 */
import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, ShieldAlert } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { urlsAssinadas } from '@/lib/fotos-url'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

interface Conflito {
  client_id: string
  tipo: string
  usuario_nome: string | null
  escolta_id: string
  escolta_codigo: string | null
  escolta_existe: boolean
  escolta_arquivada: boolean
  payload: Record<string, unknown>
  versao_gestao_vista: number | null
  versao_gestao_no_envio: number | null
  status_servidor_no_envio: string | null
  data_hora_acao: string
  recebido_em: string
  motivo: string | null
  motivo_detalhe: string | null
  motivo_texto: string | null
  tratado_por_nome: string | null
  tratado_em: string | null
  tratamento: string | null
  fotos: string[]
}

const TIPO: Record<string, string> = {
  etapa: 'Etapa',
  linhas: 'Registro de campo',
  presenca_base: 'Presença na base',
  emergencia: 'EMERGÊNCIA',
}

/** DD/MM/AAAA HH:MM no horário de Brasília. */
function dataHora(iso: string | null): string {
  if (!iso) return '-'
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).replace(',', '')
}

/** O que o operador registrou, em uma linha (o conteúdo inteiro fica no bloco abaixo). */
function resumo(c: Conflito): string {
  const partes: string[] = []
  const etapa = c.payload?.etapa as { status_atual?: string; status_novo?: string; pontos?: unknown[] } | undefined
  if (etapa?.status_novo) partes.push(`etapa ${etapa.status_atual ?? '?'} para ${etapa.status_novo}`)
  if (etapa?.pontos?.length) partes.push(`${etapa.pontos.length} ponto(s) da etapa`)
  const linhas = (c.payload?.linhas ?? {}) as Record<string, unknown[]>
  const nomes: Record<string, string> = {
    fotos: 'foto(s)', checklists: 'checklist(s)', checklist_respostas: 'resposta(s) de checklist', pontos_controle: 'ponto(s)',
    ocorrencias: 'ocorrência(s)', emergencias: 'emergência(s)', km: 'KM de viatura(s)',
  }
  for (const [k, v] of Object.entries(linhas)) if (Array.isArray(v) && v.length) partes.push(`${v.length} ${nomes[k] ?? k}`)
  if (c.payload?.presenca) partes.push('confirmação de presença na base')
  return partes.join(', ') || 'sem linhas'
}

export default function ConflitosPage() {
  const { user, loading: carregandoUsuario } = useAuth()
  const perfil = (user?.perfil?.codigo ?? '') as string
  const podeVer = ['administrador', 'gestor', 'supervisor'].includes(perfil)

  const [conflitos, setConflitos] = useState<Conflito[]>([])
  const [soAbertos, setSoAbertos] = useState(true)
  const [urls, setUrls] = useState<Record<string, string>>({})
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const [tratando, setTratando] = useState<string | null>(null)
  const [justificativa, setJustificativa] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [carregando, setCarregando] = useState(true)

  const carregar = useCallback(async () => {
    const { data, error } = await sb.rpc('listar_conflitos', { p_so_abertos: soAbertos, p_limite: 200 })
    if (error) {
      setMsg({ ok: false, texto: error.code === 'PGRST202' ? 'Atualização em andamento: a lista de conflitos ainda não está disponível.' : error.message })
      setCarregando(false)
      return
    }
    const lista = (data ?? []) as Conflito[]
    setConflitos(lista)
    setUrls(await urlsAssinadas(sb, lista.flatMap(c => c.fotos ?? [])))
    setCarregando(false)
  }, [soAbertos])

  useEffect(() => {
    if (!podeVer) return
    carregar()
    const t = setInterval(carregar, 60_000)
    return () => clearInterval(t)
  }, [podeVer, carregar])

  const tratar = async (c: Conflito) => {
    setOcupado(true); setMsg(null)
    const { error } = await sb.rpc('tratar_conflito', { p_client_id: c.client_id, p_tratamento: justificativa.trim() })
    if (error) setMsg({ ok: false, texto: error.message })
    else setMsg({ ok: true, texto: `Conflito de ${c.usuario_nome ?? 'operador'} na escolta ${c.escolta_codigo ?? ''} marcado como tratado.` })
    setTratando(null); setJustificativa(''); setOcupado(false)
    await carregar()
  }

  if (carregandoUsuario) return null
  if (!podeVer) return <div className="p-6 text-sm">Acesso restrito a supervisor, gestor e administrador.</div>

  return (
    <div className="space-y-5">
      <div className="flex items-center gap-3">
        <ShieldAlert size={20} style={{ color: '#1E2D35' }} />
        <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Conflitos de registros de campo</h1>
      </div>
      <p className="text-sm" style={{ color: '#5A6A80' }}>
        Registros do operador que o sistema não aplicou porque a escolta mudou enquanto ele estava sem sinal (ou por outro
        motivo abaixo). Nada foi descartado: o conteúdo completo e as fotos ficam aqui. Marcar como tratado não grava o
        registro na escolta; registre a justificativa do que foi feito.
      </p>

      <div className="flex gap-2">
        {[{ v: true, t: 'Abertos' }, { v: false, t: 'Todos' }].map(o => (
          <button key={String(o.v)} type="button" onClick={() => { setCarregando(true); setSoAbertos(o.v) }}
            className="px-3 text-xs font-bold" data-teste={`filtro-${o.t.toLowerCase()}`}
            style={{ minHeight: '36px', borderRadius: '4px', border: '1px solid #C8D5DC',
              backgroundColor: soAbertos === o.v ? '#1A294A' : '#fff', color: soAbertos === o.v ? '#fff' : '#5A6A80' }}>
            {o.t}
          </button>
        ))}
      </div>

      {msg && (
        <div className="p-3 text-sm" style={{ backgroundColor: msg.ok ? '#E8F5EE' : 'rgba(184,56,50,0.08)', color: msg.ok ? '#1E7C52' : '#B83832', borderRadius: '4px' }}>
          {msg.texto}
        </div>
      )}

      {!carregando && conflitos.length === 0 && (
        <p className="text-sm" style={{ color: '#6B7E8A' }}>{soAbertos ? 'Nenhum conflito aberto.' : 'Nenhum conflito registrado.'}</p>
      )}

      <div className="space-y-3">
        {conflitos.map(c => (
          <div key={c.client_id} data-teste="conflito" data-client-id={c.client_id} className="p-4 bg-white space-y-2"
            style={{ border: `1.5px solid ${c.tratado_em ? '#C8D5DC' : c.tipo === 'emergencia' ? '#B83832' : '#C8813A'}`, borderRadius: '4px' }}>
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <p className="text-sm font-black" style={{ color: c.tipo === 'emergencia' ? '#B83832' : '#1E2D35' }}>
                {TIPO[c.tipo] ?? c.tipo} · escolta <span className="font-mono">{c.escolta_codigo ?? c.escolta_id}</span>
                {!c.escolta_existe && ' (apagada)'}
                {c.escolta_arquivada && ' (arquivada)'}
              </p>
              <p className="text-xs" style={{ color: '#5A6A80' }}>{c.usuario_nome ?? 'Operador'}</p>
            </div>
            <p className="text-sm flex items-start gap-1.5" style={{ color: '#8A2420' }}>
              <AlertTriangle size={14} style={{ flexShrink: 0, marginTop: 2 }} />
              <span data-teste="motivo">{c.motivo_texto ?? c.motivo}</span>
            </p>
            <p className="text-xs" style={{ color: '#5A6A80' }}>
              Registrado no aparelho em {dataHora(c.data_hora_acao)} · recebido em {dataHora(c.recebido_em)} (Brasília)
              {c.status_servidor_no_envio ? ` · status no envio: ${c.status_servidor_no_envio}` : ''}
              {c.versao_gestao_vista != null ? ` · versão vista ${c.versao_gestao_vista}, no envio ${c.versao_gestao_no_envio ?? '-'}` : ''}
            </p>
            <p className="text-sm"><strong>Conteúdo:</strong> {resumo(c)}</p>
            {c.fotos?.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {c.fotos.map(f => urls[f]
                  ? (
                    <a key={f} href={urls[f]} target="_blank" rel="noreferrer">
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={urls[f]} alt="Foto do registro" data-teste="foto-conflito" className="w-24 h-24 object-cover" style={{ border: '1px solid #E2E8EC' }} />
                    </a>
                  )
                  : <span key={f} className="text-xs" style={{ color: '#6B7E8A' }}>Foto ainda não recebida</span>)}
              </div>
            )}
            <details>
              <summary className="text-xs font-bold cursor-pointer" style={{ color: '#1A294A' }}>Conteúdo completo</summary>
              <pre className="text-[11px] mt-2 p-2 overflow-x-auto" style={{ backgroundColor: '#F4F6F9', maxHeight: '320px' }}>
                {JSON.stringify(c.payload, null, 2)}
              </pre>
              {c.motivo_detalhe && <p className="text-xs mt-1" style={{ color: '#5A6A80' }}>Detalhe: {c.motivo_detalhe}</p>}
            </details>
            {c.tratado_em ? (
              <p className="text-xs flex items-start gap-1.5" style={{ color: '#1E7C52' }}>
                <CheckCircle2 size={14} style={{ flexShrink: 0, marginTop: 1 }} />
                Tratado por {c.tratado_por_nome ?? '-'} em {dataHora(c.tratado_em)}: {c.tratamento}
              </p>
            ) : tratando === c.client_id ? (
              <div className="space-y-2">
                <textarea value={justificativa} onChange={e => setJustificativa(e.target.value)} rows={2} className="input-light w-full text-sm"
                  placeholder="Justificativa (pelo menos 10 caracteres): o que foi conferido e o que foi feito" data-teste="justificativa" />
                <div className="flex gap-2">
                  <button type="button" onClick={() => tratar(c)} disabled={ocupado || justificativa.trim().length < 10}
                    className="flex-1 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '44px', backgroundColor: '#1E7C52' }}>
                    Confirmar tratamento
                  </button>
                  <button type="button" onClick={() => setTratando(null)} className="flex-1 text-xs font-bold"
                    style={{ minHeight: '44px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>Voltar</button>
                </div>
              </div>
            ) : (
              <button type="button" onClick={() => { setTratando(c.client_id); setJustificativa('') }}
                className="text-xs font-black uppercase" style={{ minHeight: '40px', padding: '0 14px', border: '1px solid #1A294A', color: '#1A294A', borderRadius: '4px' }}>
                Marcar como tratado
              </button>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
