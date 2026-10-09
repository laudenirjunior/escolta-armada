'use client'

/**
 * Locais salvos (lote 2026-10, M2). Supervisor ou acima cadastra e edita; só gestor e
 * administrador conferem o pino e ativam (decisão 6). Só os ativos viram atalho na
 * origem e no destino. As regras valem no banco (migration 205). Onda D2 (215): UF do local
 * (mostrada e editável) e quantas vezes ele foi usado, que ordena os atalhos.
 */
import { useCallback, useEffect, useState } from 'react'
import { MapPin, Plus, CheckCircle2, Ban, Save } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useAuth } from '@/hooks/useAuth'
import { MapaPino } from '@/components/mapa/mapa-pino'
import { LocalSalvo, PERFIS_ATIVAM_LOCAL, PERFIS_CADASTRAM_LOCAL, UFS } from '@/lib/locais'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

const SITUACAO: Record<string, { texto: string; cor: string; fundo: string }> = {
  ativo: { texto: 'Ativo', cor: '#1E7C52', fundo: '#E8F5EE' },
  aguardando_conferencia: { texto: 'Aguardando conferência', cor: '#8A5A10', fundo: '#FFF7E6' },
  inativo: { texto: 'Inativo', cor: '#6B7E8A', fundo: '#EEF1F5' },
}

type Edicao = Pick<LocalSalvo, 'nome' | 'endereco' | 'complemento' | 'latitude' | 'longitude'> & { id: string | null; uf: string }

export default function LocaisSalvosPage() {
  const { user, loading } = useAuth()
  const perfil = (user?.perfil?.codigo ?? '') as string
  const podeEditar = PERFIS_CADASTRAM_LOCAL.includes(perfil)
  const podeAtivar = PERFIS_ATIVAM_LOCAL.includes(perfil)
  const [locais, setLocais] = useState<LocalSalvo[]>([])
  const [edicao, setEdicao] = useState<Edicao | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; texto: string } | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const carregar = useCallback(async () => {
    const { data } = await sb.from('locais_salvos')
      .select('id, nome, endereco, complemento, latitude, longitude, situacao, fonte_coordenada, conferido_em, uf, vezes_usado, conferidor:usuarios!conferido_por(nome_completo)')
      .order('situacao').order('vezes_usado', { ascending: false }).order('nome')
    setLocais(((data ?? []) as LocalSalvo[]).map(l => ({ ...l, latitude: l.latitude != null ? Number(l.latitude) : null, longitude: l.longitude != null ? Number(l.longitude) : null })))
  }, [])
  useEffect(() => { if (podeEditar) carregar() }, [podeEditar, carregar])

  const salvar = async (ativarDepois = false) => {
    if (!edicao) return
    setOcupado(true); setMsg(null)
    const campos = { nome: edicao.nome.trim(), endereco: edicao.endereco.trim(), complemento: edicao.complemento?.trim() || null, latitude: edicao.latitude, longitude: edicao.longitude, uf: edicao.uf || null }
    const r = edicao.id
      ? await sb.from('locais_salvos').update(campos).eq('id', edicao.id).select('id')
      : await sb.from('locais_salvos').insert({ ...campos, situacao: 'aguardando_conferencia', fonte_coordenada: 'Cadastrado na tela de locais salvos' }).select('id')
    setMsg(r.error || !r.data?.length ? { ok: false, texto: r.error?.message ?? 'Sem permissão.' } : { ok: true, texto: edicao.id ? 'Local salvo. Se a coordenada mudou, ele volta para conferência.' : 'Local criado, aguardando conferência.' })
    if (!r.error && r.data?.length && ativarDepois) {
      // Conferência com o mapa aberto: salva o pino e ativa na mesma ação (decisão 6).
      const a = await sb.from('locais_salvos').update({ situacao: 'ativo' }).eq('id', r.data[0].id).select('id')
      setMsg(a.error || !a.data?.length ? { ok: false, texto: a.error?.message ?? 'Sem permissão para ativar.' } : { ok: true, texto: `"${edicao.nome}" conferido no mapa e ativo: já aparece como atalho.` })
    }
    setOcupado(false)
    if (!r.error) { setEdicao(null); await carregar() }
  }

  const mudarSituacao = async (l: LocalSalvo, situacao: LocalSalvo['situacao']) => {
    setOcupado(true); setMsg(null)
    const { data, error } = await sb.from('locais_salvos').update({ situacao }).eq('id', l.id).select('id')
    setMsg(error || !data?.length ? { ok: false, texto: error?.message ?? 'Sem permissão.' }
      : { ok: true, texto: situacao === 'ativo' ? `"${l.nome}" conferido e ativo: já aparece como atalho.` : `"${l.nome}" ${situacao === 'inativo' ? 'inativado' : 'devolvido para conferência'}.` })
    setOcupado(false); await carregar()
  }

  if (loading) return null
  if (!podeEditar) return <div className="p-6 text-sm">Acesso restrito a supervisor, gestor e administrador.</div>

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div className="flex items-center gap-3">
          <MapPin size={20} style={{ color: '#1E2D35' }} />
          <h1 className="text-xl font-black" style={{ color: '#1E2D35' }}>Locais Salvos</h1>
        </div>
        <button type="button" onClick={() => setEdicao({ id: null, nome: '', endereco: '', complemento: '', latitude: null, longitude: null, uf: '' })}
          className="inline-flex items-center gap-1.5 px-4 text-xs font-black uppercase text-white" style={{ minHeight: '40px', backgroundColor: '#1E2D35' }}>
          <Plus size={14} /> Novo local
        </button>
      </div>
      <p className="text-xs" style={{ color: '#5A6A80' }}>
        Atalhos de origem e destino. Só os locais <strong>ativos</strong> aparecem no formulário de escolta, os mais usados primeiro. Um local só fica ativo depois que gestor ou administrador confere o pino no mapa; mudar endereço, pino ou UF de um local ativo pede nova conferência.
      </p>

      {msg && <div className="p-3 text-sm" style={{ backgroundColor: msg.ok ? '#E8F5EE' : 'rgba(184,56,50,0.08)', color: msg.ok ? '#1E7C52' : '#B83832', borderRadius: '4px' }}>{msg.texto}</div>}

      {edicao && (
        <div className="bg-white p-4 space-y-3" style={{ border: '1.5px solid #1E2D35', borderRadius: '4px' }} data-teste="edicao-local">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <label className="text-xs" style={{ color: '#5A6A80' }}>Nome do atalho
              <input value={edicao.nome} onChange={e => setEdicao({ ...edicao, nome: e.target.value })} maxLength={40} className="input-light w-full mt-1" />
            </label>
            <label className="text-xs md:col-span-2" style={{ color: '#5A6A80' }}>Endereço (como deve aparecer na escolta)
              <input value={edicao.endereco} onChange={e => setEdicao({ ...edicao, endereco: e.target.value })} className="input-light w-full mt-1" />
            </label>
            <label className="text-xs md:col-span-2" style={{ color: '#5A6A80' }}>Complemento (portão, doca)
              <input value={edicao.complemento ?? ''} onChange={e => setEdicao({ ...edicao, complemento: e.target.value })} className="input-light w-full mt-1" />
            </label>
            <label className="text-xs" style={{ color: '#5A6A80' }}>UF
              <select value={edicao.uf} onChange={e => setEdicao({ ...edicao, uf: e.target.value })} className="input-light w-full mt-1" data-teste="uf-local">
                <option value="">Não informada</option>
                {UFS.map(u => <option key={u} value={u}>{u}</option>)}
              </select>
            </label>
          </div>
          <p className="text-xs font-bold" style={{ color: '#1E2D35' }}>Arraste o pino até o ponto exato (portão, doca).</p>
          <MapaPino key={edicao.id ?? "novo"} lat={edicao.latitude} lng={edicao.longitude} onMover={(lat, lng) => setEdicao({ ...edicao, latitude: lat, longitude: lng })} altura={300} />
          <div className="flex gap-2">
            <button type="button" onClick={() => salvar()} disabled={ocupado || edicao.nome.trim().length < 2 || !edicao.endereco.trim()}
              className="inline-flex items-center gap-1.5 px-4 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '40px', backgroundColor: '#1E7C52' }}>
              <Save size={14} /> Salvar local
            </button>
            {podeAtivar && edicao.id && (
              <button type="button" onClick={() => salvar(true)} disabled={ocupado || edicao.latitude == null || edicao.longitude == null || edicao.nome.trim().length < 2}
                className="inline-flex items-center gap-1.5 px-4 text-xs font-black uppercase text-white disabled:opacity-50" style={{ minHeight: '40px', backgroundColor: '#1E2D35' }}>
                <CheckCircle2 size={14} /> Conferi no mapa, ativar
              </button>
            )}
            <button type="button" onClick={() => setEdicao(null)} className="px-4 text-xs font-bold" style={{ minHeight: '40px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>Cancelar</button>
          </div>
        </div>
      )}

      <div className="space-y-2">
        {locais.map(l => {
          const s = SITUACAO[l.situacao]
          return (
            <div key={l.id} className="bg-white p-4 flex flex-wrap items-start justify-between gap-3" style={{ border: '1px solid #E2E8EC', borderRadius: '4px' }}>
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2 flex-wrap">
                  <p className="text-sm font-black" style={{ color: '#1E2D35' }}>{l.nome}</p>
                  <span className="text-[10px] font-black uppercase tracking-wider px-2 py-0.5" style={{ color: s.cor, backgroundColor: s.fundo }}>{s.texto}</span>
                  <span className="text-[10px] font-black px-2 py-0.5" style={{ color: '#1E2D35', backgroundColor: '#EEF1F5' }} data-teste="uf">{l.uf ? `UF ${l.uf}` : 'UF não informada'}</span>
                  <span className="text-[10px] font-bold" style={{ color: '#6B7E8A' }} data-teste="vezes-usado">{`Usado ${l.vezes_usado ?? 0} ${(l.vezes_usado ?? 0) === 1 ? 'vez' : 'vezes'} em escoltas`}</span>
                </div>
                <p className="text-sm mt-1" style={{ color: '#1E2D35' }}>{l.endereco}{l.complemento ? ` (${l.complemento})` : ''}</p>
                <p className="text-xs mt-1" style={{ color: '#6B7E8A' }}>
                  {l.latitude != null && l.longitude != null ? `${l.latitude.toFixed(6)}, ${l.longitude.toFixed(6)}` : 'Sem coordenada: pôr o pino na conferência'}
                  {l.fonte_coordenada ? ` · ${l.fonte_coordenada}` : ''}
                </p>
                {l.situacao === 'ativo' && l.conferido_em && (
                  <p className="text-xs mt-1" style={{ color: '#1E7C52' }}>Conferido por {l.conferidor?.nome_completo ?? '-'} em {new Date(l.conferido_em).toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo' })}</p>
                )}
              </div>
              <div className="flex gap-2 flex-wrap">
                <button type="button" onClick={() => setEdicao({ id: l.id, nome: l.nome, endereco: l.endereco, complemento: l.complemento, latitude: l.latitude, longitude: l.longitude, uf: l.uf ?? '' })}
                  className="px-3 text-xs font-bold" style={{ minHeight: '36px', border: '1px solid #C8D5DC', color: '#1E2D35' }}>
                  {podeAtivar && l.situacao !== 'ativo' ? 'Conferir no mapa' : 'Editar e pôr o pino'}
                </button>
                {l.situacao !== 'inativo' && (
                  <button type="button" disabled={ocupado} onClick={() => mudarSituacao(l, 'inativo')}
                    className="inline-flex items-center gap-1 px-3 text-xs font-bold disabled:opacity-50" style={{ minHeight: '36px', border: '1px solid #B83832', color: '#B83832' }}>
                    <Ban size={13} /> Inativar
                  </button>
                )}
                {l.situacao === 'inativo' && (
                  <button type="button" disabled={ocupado} onClick={() => mudarSituacao(l, 'aguardando_conferencia')}
                    className="px-3 text-xs font-bold disabled:opacity-50" style={{ minHeight: '36px', border: '1px solid #C8D5DC', color: '#5A6A80' }}>Reativar (vai para conferência)</button>
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
