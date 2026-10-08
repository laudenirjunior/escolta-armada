'use client'

/**
 * Central de avisos (lote 2026-10, onda J): a caixa pessoal de cada usuário, na tabela
 * notificacoes. Lista paginada (meus_avisos), filtro por tipo e por código da escolta,
 * marcar como lida (marcar_aviso_lido), marcar todas (marcar_todos_lidos), link para a
 * escolta e "Registrar check-in" no aviso de check-in vencido. Cada um vê só os próprios
 * avisos (decisão S5); a auditoria da gestão continua em logs_auditoria.
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { Bell, BellRing, Check, CheckCheck, ExternalLink, Radio, RefreshCw, Search } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { type AvisoCentral, horaBrasilia, useAbrirAviso, useAvisos } from '@/components/avisos-provider'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

const POR_PAGINA = 30

const TIPOS: { codigo: string; rotulo: string }[] = [
  { codigo: '', rotulo: 'Todos os tipos' },
  { codigo: 'checkin_vencido', rotulo: 'Check-in vencido' },
  { codigo: 'pedido_substituicao', rotulo: 'Pedido de substituição' },
  { codigo: 'decisao_substituicao', rotulo: 'Decisão sobre pedido' },
  { codigo: 'substituicao_equipe', rotulo: 'Substituição de equipe' },
  { codigo: 'edicao_escolta', rotulo: 'Escolta editada' },
  { codigo: 'reset_escolta', rotulo: 'Escolta reiniciada' },
  { codigo: 'conclusao_antecipada', rotulo: 'Conclusão antecipada' },
  { codigo: 'arquivamento_escolta', rotulo: 'Escolta arquivada' },
  { codigo: 'recuperacao_escolta', rotulo: 'Escolta recuperada' },
  { codigo: 'conflito_offline', rotulo: 'Registro offline em conflito' },
]

const C = { navy: '#1A294A', steel: '#53648A', border: '#D4D9E6', text: '#0E1A33', sub: '#5A6A80', muted: '#8899AA', red: '#B83832' }

export function CentralAvisos({ perfil }: { perfil?: string | null }) {
  const { naoLidas, atualizar } = useAvisos()
  const abrir = useAbrirAviso(perfil)
  const [avisos, setAvisos] = useState<AvisoCentral[]>([])
  const [carregando, setCarregando] = useState(true)
  const [erro, setErro] = useState<string | null>(null)
  const [temMais, setTemMais] = useState(false)
  const [tipo, setTipo] = useState('')
  const [soNaoLidas, setSoNaoLidas] = useState(false)
  const [codigo, setCodigo] = useState('')
  const [escoltaFiltro, setEscoltaFiltro] = useState<{ id: string; codigo: string } | null>(null)
  const [avisoFiltro, setAvisoFiltro] = useState<string | null>(null)
  const [marcandoTodas, setMarcandoTodas] = useState(false)
  const paginasRef = useRef(1)

  const buscar = useCallback(async (antes: string | null) => {
    const { data, error } = await sb.rpc('meus_avisos', {
      p_tipo: tipo || null,
      p_escolta_id: escoltaFiltro?.id ?? null,
      p_so_nao_lidas: soNaoLidas,
      p_limite: POR_PAGINA,
      p_antes: antes,
    })
    if (error) throw new Error(error.message)
    return (data ?? []) as AvisoCentral[]
  }, [tipo, escoltaFiltro, soNaoLidas])

  const carregar = useCallback(async () => {
    setCarregando(true)
    try {
      const lista = await buscar(null)
      setAvisos(lista)
      setTemMais(lista.length === POR_PAGINA)
      paginasRef.current = 1
      setErro(null)
    } catch {
      setErro('Não foi possível carregar os avisos. Tente de novo em instantes.')
    } finally {
      setCarregando(false)
    }
  }, [buscar])

  useEffect(() => { carregar() }, [carregar])

  // Aviso novo no contador: recarrega a primeira página (se ninguém estiver paginando).
  const ultimoContadorRef = useRef(naoLidas)
  useEffect(() => {
    if (naoLidas > ultimoContadorRef.current && paginasRef.current === 1) carregar()
    ultimoContadorRef.current = naoLidas
  }, [naoLidas, carregar])

  const carregarMais = async () => {
    const ultimo = avisos[avisos.length - 1]
    if (!ultimo) return
    try {
      const mais = await buscar(ultimo.criado_em)
      setAvisos(a => [...a, ...mais.filter(m => !a.some(x => x.id === m.id))])
      setTemMais(mais.length === POR_PAGINA)
      paginasRef.current += 1
    } catch {
      setErro('Não foi possível carregar mais avisos.')
    }
  }

  const filtrarPorCodigo = async () => {
    const c = codigo.trim()
    setAvisoFiltro(null)
    if (!c) { setEscoltaFiltro(null); return }
    const { data, error } = await sb.from('escoltas').select('id, codigo_escolta').ilike('codigo_escolta', c).limit(1)
    if (error || !data?.length) {
      setAvisoFiltro(`Nenhuma escolta com o código ${c} entre as que você acessa.`)
      return
    }
    setEscoltaFiltro({ id: data[0].id, codigo: data[0].codigo_escolta })
  }

  const marcarLida = async (a: AvisoCentral) => {
    const { data, error } = await sb.rpc('marcar_aviso_lido', { p_notificacao_id: a.id })
    if (error || data !== true) { setErro('O aviso não foi marcado como lido. Tente de novo.'); return }
    const agora = new Date().toISOString()
    setAvisos(lista => soNaoLidas ? lista.filter(x => x.id !== a.id) : lista.map(x => x.id === a.id ? { ...x, lida_em: agora } : x))
    atualizar()
  }

  const marcarTodas = async () => {
    setMarcandoTodas(true)
    const { error } = await sb.rpc('marcar_todos_lidos', { p_tipo: tipo || null })
    setMarcandoTodas(false)
    if (error) { setErro('Não foi possível marcar todos como lidos.'); return }
    atualizar()
    await carregar()
  }

  const naoLidasNaLista = avisos.filter(a => !a.lida_em).length

  return (
    <div className="flex flex-col gap-3" data-teste="central-avisos">
      {/* Filtros */}
      <div className="flex flex-col md:flex-row gap-2 md:items-center">
        <select
          value={tipo}
          onChange={e => setTipo(e.target.value)}
          aria-label="Filtrar por tipo"
          style={{ height: '44px', border: `1px solid ${C.border}`, borderRadius: '2px', padding: '0 10px', fontSize: '13px', color: C.text, backgroundColor: '#fff' }}
        >
          {TIPOS.map(t => <option key={t.codigo} value={t.codigo}>{t.rotulo}</option>)}
        </select>
        <div className="flex gap-2 flex-1">
          <div style={{ position: 'relative', flex: 1 }}>
            <Search size={13} style={{ position: 'absolute', left: '11px', top: '50%', transform: 'translateY(-50%)', color: C.muted, pointerEvents: 'none' }} />
            <input
              value={codigo}
              onChange={e => setCodigo(e.target.value)}
              onKeyDown={e => { if (e.key === 'Enter') filtrarPorCodigo() }}
              placeholder="Código da escolta (ex.: ESC-2026-0001)"
              aria-label="Filtrar por código da escolta"
              style={{ width: '100%', paddingLeft: '34px', paddingRight: '12px', height: '44px', border: `1px solid ${C.border}`, borderRadius: '2px', fontSize: '13px', color: C.text, boxSizing: 'border-box' }}
            />
          </div>
          <button type="button" onClick={filtrarPorCodigo}
            style={{ height: '44px', padding: '0 14px', border: `1px solid ${C.border}`, borderRadius: '2px', fontSize: '12px', fontWeight: 800, color: C.steel, backgroundColor: '#fff' }}>
            Filtrar
          </button>
          <button type="button" onClick={carregar} title="Atualizar" aria-label="Atualizar avisos"
            style={{ width: '44px', height: '44px', display: 'flex', alignItems: 'center', justifyContent: 'center', border: `1px solid ${C.border}`, borderRadius: '2px', color: C.steel, backgroundColor: '#fff' }}>
            <RefreshCw size={14} />
          </button>
        </div>
      </div>
      <div className="flex flex-wrap gap-2 items-center justify-between">
        <label className="flex items-center gap-2" style={{ fontSize: '12px', color: C.sub, minHeight: '40px' }}>
          <input type="checkbox" checked={soNaoLidas} onChange={e => setSoNaoLidas(e.target.checked)} />
          Só não lidas
        </label>
        <div className="flex items-center gap-3">
          <span style={{ fontSize: '12px', color: C.sub }} data-teste="central-nao-lidas">
            {naoLidas === 1 ? '1 não lida' : `${naoLidas} não lidas`}
          </span>
          <button type="button" onClick={marcarTodas} disabled={marcandoTodas || naoLidas === 0}
            className="flex items-center gap-1"
            style={{ minHeight: '40px', padding: '0 12px', border: `1px solid ${C.steel}`, borderRadius: '2px', fontSize: '12px', fontWeight: 800,
                     color: naoLidas === 0 ? C.muted : C.steel, backgroundColor: '#fff', opacity: naoLidas === 0 ? 0.6 : 1 }}>
            <CheckCheck size={14} /> Marcar todas como lidas
          </button>
        </div>
      </div>
      {escoltaFiltro && (
        <div className="flex items-center gap-2" style={{ fontSize: '12px', color: C.sub }}>
          Escolta {escoltaFiltro.codigo}
          <button type="button" onClick={() => { setEscoltaFiltro(null); setCodigo('') }} style={{ color: C.steel, fontWeight: 800 }}>limpar filtro</button>
        </div>
      )}
      {avisoFiltro && <p style={{ fontSize: '12px', color: C.red }}>{avisoFiltro}</p>}
      {erro && <p role="alert" style={{ fontSize: '12px', color: C.red }}>{erro}</p>}

      {/* Lista */}
      {carregando ? (
        <p style={{ fontSize: '13px', color: C.sub, padding: '24px 0', textAlign: 'center' }}>Carregando avisos...</p>
      ) : avisos.length === 0 ? (
        <div style={{ padding: '32px 16px', textAlign: 'center', backgroundColor: '#fff', border: `1px solid ${C.border}`, borderRadius: '2px' }}>
          <Bell size={20} style={{ color: C.muted, margin: '0 auto 8px' }} />
          <p style={{ fontSize: '13px', color: C.sub }}>Nenhum aviso {soNaoLidas || tipo || escoltaFiltro ? 'com esses filtros' : 'por enquanto'}.</p>
        </div>
      ) : (
        <ul className="flex flex-col gap-2" aria-label={`${naoLidasNaLista} não lidas nesta lista`}>
          {avisos.map(a => {
            const lida = !!a.lida_em
            const checkin = a.tipo === 'checkin_vencido'
            return (
              <li key={a.id} data-teste="aviso-central" data-lida={lida ? 'sim' : 'nao'}
                style={{ backgroundColor: lida ? '#fff' : '#F7F9FD', border: `1px solid ${lida ? C.border : '#B8C3DA'}`, borderLeft: `4px solid ${lida ? C.border : (checkin ? C.red : '#C8813A')}`, borderRadius: '2px', padding: '12px 14px' }}>
                <div className="flex items-start gap-3">
                  {checkin ? <Bell size={16} style={{ color: C.red, flexShrink: 0, marginTop: 2 }} /> : <BellRing size={16} style={{ color: '#8A5A10', flexShrink: 0, marginTop: 2 }} />}
                  <div className="flex-1 min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span style={{ fontSize: '10px', fontWeight: 900, textTransform: 'uppercase', letterSpacing: '0.08em', color: checkin ? C.red : '#8A5A10' }}>
                        {a.tipo_nome ?? a.tipo}
                      </span>
                      {!lida && <span style={{ fontSize: '9px', fontWeight: 900, color: '#fff', backgroundColor: C.red, borderRadius: '8px', padding: '1px 6px' }}>NÃO LIDA</span>}
                      <span style={{ fontSize: '11px', color: C.muted }}>{horaBrasilia(a.criado_em)}</span>
                    </div>
                    <p style={{ fontSize: '13px', fontWeight: 700, color: C.text, marginTop: '2px' }}>{a.titulo}</p>
                    {a.texto && <p style={{ fontSize: '13px', color: C.sub, marginTop: '2px' }}>{a.texto}</p>}
                    <div className="flex flex-wrap gap-2 mt-2">
                      {checkin && a.escolta_id && (
                        <button type="button" onClick={() => abrir(a, 'checkin')} className="flex items-center gap-1 font-black uppercase text-white"
                          style={{ minHeight: '40px', padding: '0 12px', fontSize: '12px', backgroundColor: C.red, borderRadius: '2px' }}>
                          <Radio size={14} /> Registrar check-in
                        </button>
                      )}
                      {a.escolta_id && (
                        <button type="button" onClick={() => abrir(a, 'escolta')} className="flex items-center gap-1"
                          style={{ minHeight: '40px', padding: '0 12px', fontSize: '12px', fontWeight: 800, color: C.steel, border: `1px solid ${C.border}`, borderRadius: '2px', backgroundColor: '#fff' }}>
                          <ExternalLink size={13} /> {a.codigo ? `Abrir ${a.codigo}` : 'Abrir escolta'}
                        </button>
                      )}
                      {!lida && (
                        <button type="button" onClick={() => marcarLida(a)} className="flex items-center gap-1"
                          style={{ minHeight: '40px', padding: '0 12px', fontSize: '12px', fontWeight: 800, color: C.navy, border: `1px solid ${C.border}`, borderRadius: '2px', backgroundColor: '#fff' }}>
                          <Check size={13} /> Marcar como lida
                        </button>
                      )}
                    </div>
                  </div>
                </div>
              </li>
            )
          })}
        </ul>
      )}
      {!carregando && temMais && (
        <button type="button" onClick={carregarMais}
          style={{ minHeight: '44px', border: `1px solid ${C.border}`, borderRadius: '2px', fontSize: '12px', fontWeight: 800, color: C.steel, backgroundColor: '#fff' }}>
          Carregar mais
        </button>
      )}
    </div>
  )
}
