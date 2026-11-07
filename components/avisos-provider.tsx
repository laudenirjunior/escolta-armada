'use client'

/**
 * Central de avisos (lote 2026-10, onda J): substitui o CheckinAlertProvider.
 *
 * Os avisos são gravados pelo servidor, uma linha por destinatário e por evento, na
 * tabela notificacoes (check-in vencido pelo cron do banco, migration 212; avisos do mural
 * pela 217). Aqui só se lê:
 * - a cada 20 s, contar_avisos_nao_lidos (sino e item Avisos da barra inferior) e os não
 *   lidos mais recentes (meus_avisos);
 * - cada aviso novo aparece no canto e some sozinho em 2 s, sem botão; o clique abre a
 *   escolta. O aviso continua na Central até ser marcado como lido.
 * "Já mostrado": pelo id do aviso (em memória e em localStorage por usuário), para não
 * repetir ao recarregar nem perder aviso gravado fora de ordem; o último criado_em visto só
 * corta a primeira leitura de cada aba. Duas abas: a leitura e a marca rodam sob uma trava
 * do navegador (navigator.locks) e o BroadcastChannel avisa as outras abas; sem a trava,
 * a primeira leitura espera de 0 a 2 s ao acaso. A linha no banco é uma só de qualquer jeito.
 * Telegram do check-in (decisão S4 e item 6.2.3): sai pelo cron do banco quando o envio
 * pelo banco está ativo e a 217 foi aplicada. Fora disso, este provider pede a cada minuto
 * reservar_alertas_checkin (212): o banco reserva a chave de cada alerta vencido e só o
 * primeiro navegador (gestão ou equipe da escolta) recebe o alerta e manda pelo
 * /api/telegram, com o mesmo texto e destino do alerta antigo.
 */
import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { usePathname, useRouter } from 'next/navigation'
import { Bell, BellRing } from 'lucide-react'
import { createClient } from '@/lib/supabase/client'
import { useModoGuiado } from '@/hooks/useModoGuiado'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const sb = createClient() as any

export const INTERVALO_AVISOS_MS = 20_000
export const DURACAO_AVISO_MS = 2_000
const MAX_NO_CANTO = 3
const INTERVALO_TELEGRAM_MS = 60_000
const MAX_IDS_GUARDADOS = 300

// Rótulos do alerta antigo (CheckinAlertProvider da master), para o texto sair igual.
const ROTULO_STATUS: Record<string, string> = {
  em_andamento: 'Em Rota', na_origem: 'Na Origem',
  em_transito_destino: 'Trânsito p/ Destino',
  no_destino: 'No Destino', retornando: 'Em Retorno',
}

interface AlertaReservado {
  escolta_id: string
  codigo: string | null
  cliente: string | null
  status: string
  atraso_min: number
  periodicidade_min: number
  efetivos: string[]
}

export interface AvisoCentral {
  id: string
  escolta_id: string | null
  codigo: string | null
  tipo: string
  tipo_nome: string | null
  titulo: string
  texto: string | null
  criado_em: string
  lida_em: string | null
}

interface ContextoAvisos {
  naoLidas: number
  /** Relê o contador (depois de marcar como lido) e avisa as outras abas. */
  atualizar: () => void
}

const AvisosContext = createContext<ContextoAvisos>({ naoLidas: 0, atualizar: () => {} })

export function useAvisos(): ContextoAvisos {
  return useContext(AvisosContext)
}

/** Hora de Brasília no formato DD/MM/AAAA HH:MM. */
export function horaBrasilia(iso: string): string {
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).replace(',', '')
}

/**
 * Para onde leva o clique num aviso. Check-in vencido vai direto ao registro (o operador
 * no Modo Guiado ao Painel; os demais ao diálogo da tela de detalhe), como o alerta antigo;
 * pedido de substituição leva a gestão à fila de Substituições; o resto abre a escolta.
 */
export function useAbrirAviso(perfil?: string | null) {
  const router = useRouter()
  const pathname = usePathname()
  const { ligado: modoGuiado } = useModoGuiado()
  return useCallback((aviso: Pick<AvisoCentral, 'escolta_id' | 'tipo'>, modo: 'auto' | 'checkin' | 'escolta' = 'auto') => {
    const id = aviso.escolta_id
    const registrarCheckin = modo === 'checkin' || (modo === 'auto' && aviso.tipo === 'checkin_vencido')
    if (modo === 'auto' && aviso.tipo === 'pedido_substituicao' && perfil && ['administrador', 'gestor', 'supervisor'].includes(perfil)) {
      router.push('/dashboard/substituicoes')
      return
    }
    if (!id) return
    if (registrarCheckin) {
      if (perfil === 'operador' && modoGuiado) {
        if (pathname === '/dashboard/campo') {
          window.dispatchEvent(new CustomEvent('campo:registrar-checkin', { detail: { escoltaId: id } }))
        } else {
          router.push(`/dashboard/campo?escolta=${id}&acao=checkin`)
        }
        return
      }
      router.push(`/dashboard/escoltas/${id}?acao=checkin`)
      return
    }
    router.push(`/dashboard/escoltas/${id}`)
  }, [perfil, modoGuiado, pathname, router])
}

/** Compara instantes (ISO) pelo relógio, não pelo texto. */
function depois(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a) return false
  if (!b) return true
  return Date.parse(a) > Date.parse(b)
}

function lerUltimoVisto(chave: string): string | null {
  try { return window.localStorage.getItem(chave) } catch { return null }
}
function gravarUltimoVisto(chave: string, valor: string) {
  try { window.localStorage.setItem(chave, valor) } catch { /* modo privado: fica só em memória */ }
}
/** Ids já mostrados neste aparelho; null quando nunca foi gravado (primeiro acesso). */
function lerIds(chave: string): string[] | null {
  try {
    const v = window.localStorage.getItem(chave)
    if (!v) return null
    const a = JSON.parse(v)
    return Array.isArray(a) ? a.filter((x): x is string => typeof x === 'string') : null
  } catch { return null }
}
function gravarIds(chave: string, ids: Iterable<string>) {
  try { window.localStorage.setItem(chave, JSON.stringify(Array.from(ids).slice(-MAX_IDS_GUARDADOS))) } catch { /* idem */ }
}

/** Roda fn sob uma trava entre as abas do mesmo navegador (Web Locks); sem ela, roda direto. */
async function comTrava<T>(nome: string, fn: () => Promise<T>): Promise<{ valor: T }> {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const locks = typeof navigator !== 'undefined' ? (navigator as any).locks : undefined
  if (locks?.request) {
    try {
      const valor = await locks.request(nome, fn) as T
      return { valor }
    } catch { /* trava indisponível: segue sem ela */ }
  }
  return { valor: await fn() }
}

export function AvisosProvider({ usuarioId, perfil, children }: { usuarioId: string | null; perfil?: string | null; children: ReactNode }) {
  const [naoLidas, setNaoLidas] = useState(0)
  const [noCanto, setNoCanto] = useState<AvisoCentral[]>([])
  const mostradosRef = useRef<Set<string>>(new Set())
  const iniciadoRef = useRef(false)
  const canalRef = useRef<BroadcastChannel | null>(null)
  const abrir = useAbrirAviso(perfil)
  const chave = usuarioId ? `ea_avisos_ultimo_visto:${usuarioId}` : null
  const chaveIds = usuarioId ? `ea_avisos_mostrados:${usuarioId}` : null

  const contar = useCallback(async () => {
    const { data, error } = await sb.rpc('contar_avisos_nao_lidos')
    if (!error && typeof data === 'number') setNaoLidas(data)
  }, [])

  const mostrar = useCallback((avisos: AvisoCentral[]) => {
    if (!avisos.length) return
    setNoCanto(atual => [...avisos, ...atual].slice(0, MAX_NO_CANTO))
    for (const a of avisos) {
      window.setTimeout(() => setNoCanto(atual => atual.filter(x => x.id !== a.id)), DURACAO_AVISO_MS)
    }
  }, [])

  const verificar = useCallback(async () => {
    if (!chave || !chaveIds || !usuarioId) return
    await contar()
    const { data, error } = await sb.rpc('meus_avisos', { p_so_nao_lidas: true, p_limite: 20 })
    if (error || !Array.isArray(data)) return
    const lista = data as AvisoCentral[]
    // Decidir o que vai ao canto e gravar a marca acontecem dentro da trava: a outra aba
    // só lê depois que esta gravou, e não mostra o mesmo aviso.
    const decidir = async (): Promise<AvisoCentral[]> => {
      const salvos = lerIds(chaveIds)
      salvos?.forEach(id => mostradosRef.current.add(id))
      const ultimo = lerUltimoVisto(chave)
      const maisNovo = lista.reduce<string | null>((m, a) => (depois(a.criado_em, m) ? a.criado_em : m), null)
      if (maisNovo && depois(maisNovo, ultimo)) gravarUltimoVisto(chave, maisNovo)
      if (!iniciadoRef.current) {
        iniciadoRef.current = true
        // Primeiro acesso neste aparelho: o que já estava na caixa vai para o contador e a
        // Central, sem enfileirar avisos antigos no canto.
        if (salvos === null && !ultimo) {
          lista.forEach(a => mostradosRef.current.add(a.id))
          gravarIds(chaveIds, mostradosRef.current)
          return []
        }
        // Primeira leitura desta aba: o que é anterior à última marca já passou pelo canto.
        if (ultimo) lista.forEach(a => { if (!depois(a.criado_em, ultimo)) mostradosRef.current.add(a.id) })
      }
      // Daqui em diante, pelo id: aviso gravado numa transação mais longa (criado_em mais
      // antigo que outro já mostrado) também vai ao canto.
      const novos = lista.filter(a => !mostradosRef.current.has(a.id)).slice(0, MAX_NO_CANTO)
      lista.forEach(a => mostradosRef.current.add(a.id))
      gravarIds(chaveIds, mostradosRef.current)
      return novos
    }
    const { valor: novos } = await comTrava(`ea-avisos-${usuarioId}`, decidir)
    if (!novos.length) return
    canalRef.current?.postMessage({ tipo: 'mostrados', ids: novos.map(a => a.id) })
    mostrar(novos)
  }, [chave, chaveIds, usuarioId, contar, mostrar])

  // Telegram do check-in quando o cron não manda (ver o cabeçalho). Só quem o banco
  // autoriza (gestão ou equipe) recebe alerta, e cada alerta vem para um navegador só.
  const telegramCheckin = useCallback(async () => {
    let r: { data: unknown; error: unknown }
    try { r = await sb.rpc('reservar_alertas_checkin') } catch { return }
    if (r.error || !Array.isArray(r.data)) return
    for (const a of r.data as AlertaReservado[]) {
      const atraso = a.atraso_min
      fetch('/api/telegram', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          tipo: 'alerta_checkin',
          titulo: `Alerta: Check-in em Atraso (${atraso} min)`,
          descricao: `A escolta não realizou check-in há ${atraso} minuto${atraso > 1 ? 's' : ''}. Periodicidade configurada: a cada ${a.periodicidade_min} min.`,
          escolta_id: a.escolta_id,
          escolta_codigo: a.codigo,
          cliente: a.cliente,
          status_atual: ROTULO_STATUS[a.status] ?? a.status,
          efetivos: a.efetivos ?? [],
          // Sem data_hora: a rota grava DD/MM/AAAA HH:MM de Brasília.
        }),
      }).catch(() => {})
    }
  }, [])

  const atualizar = useCallback(() => {
    contar()
    canalRef.current?.postMessage({ tipo: 'atualizar' })
  }, [contar])

  useEffect(() => {
    if (!usuarioId) return
    mostradosRef.current = new Set()
    iniciadoRef.current = false
    let canal: BroadcastChannel | null = null
    try {
      canal = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel(`ea-avisos-${usuarioId}`) : null
    } catch { canal = null }
    canalRef.current = canal
    if (canal) {
      canal.onmessage = (ev: MessageEvent) => {
        const m = ev.data as { tipo?: string; ids?: string[] }
        if (m?.tipo === 'mostrados') {
          (m.ids ?? []).forEach(id => mostradosRef.current.add(id))
          contar()
        } else if (m?.tipo === 'atualizar') {
          contar()
        }
      }
    }
    // Sem trava entre abas, a primeira leitura de cada aba espera de 0 a 2 s ao acaso,
    // para duas abas abertas juntas não lerem no mesmo instante.
    const semTrava = typeof navigator === 'undefined' || !('locks' in navigator)
    const inicio = window.setTimeout(verificar, semTrava ? Math.floor(Math.random() * 2000) : 0)
    const t = window.setInterval(verificar, INTERVALO_AVISOS_MS)
    telegramCheckin()
    const tg = window.setInterval(telegramCheckin, INTERVALO_TELEGRAM_MS)
    return () => {
      window.clearTimeout(inicio); window.clearInterval(t); window.clearInterval(tg)
      canal?.close(); canalRef.current = null
    }
  }, [usuarioId, verificar, contar, telegramCheckin])

  return (
    <AvisosContext.Provider value={{ naoLidas, atualizar }}>
      {children}
      {/* Região viva sempre montada: o leitor de tela anuncia cada aviso que entra. */}
      <div
        data-teste="avisos-canto"
        role="status"
        aria-live="polite"
        style={{ position: 'fixed', top: '64px', right: '16px', zIndex: 9000, display: 'flex', flexDirection: 'column', gap: '8px', maxWidth: '360px', width: 'calc(100% - 32px)', pointerEvents: noCanto.length ? 'auto' : 'none' }}
      >
          {noCanto.map(a => {
            const checkin = a.tipo === 'checkin_vencido'
            const cor = checkin ? '#B83832' : '#8A5A10'
            return (
              <button
                key={a.id}
                type="button"
                data-teste="aviso-canto"
                onClick={() => { setNoCanto(atual => atual.filter(x => x.id !== a.id)); abrir(a) }}
                style={{
                  backgroundColor: '#fff', border: `1.5px solid ${checkin ? '#F5C6C4' : '#E8C98F'}`, borderLeft: `4px solid ${cor}`,
                  borderRadius: '4px', padding: '12px 14px', boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
                  display: 'flex', gap: '10px', alignItems: 'flex-start', textAlign: 'left', cursor: 'pointer',
                }}
              >
                {checkin
                  ? <Bell size={15} style={{ color: cor, flexShrink: 0, marginTop: '2px' }} />
                  : <BellRing size={15} style={{ color: cor, flexShrink: 0, marginTop: '2px' }} />}
                <span style={{ flex: 1, minWidth: 0 }}>
                  <span style={{ display: 'block', fontSize: '11px', fontWeight: 800, color: cor, textTransform: 'uppercase', letterSpacing: '0.08em' }}>
                    {checkin ? 'Check-in atrasado' : (a.tipo_nome ?? 'Aviso')}
                  </span>
                  <span style={{ display: 'block', fontSize: '12px', fontWeight: 600, color: '#0E1A33', marginTop: '2px' }}>{a.titulo}</span>
                  {a.texto && (
                    <span style={{ fontSize: '12px', color: '#5A6A80', marginTop: '2px', overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical' }}>
                      {a.texto}
                    </span>
                  )}
                </span>
              </button>
            )
          })}
      </div>
    </AvisosContext.Provider>
  )
}
