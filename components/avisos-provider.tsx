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
 * "Já mostrado": ids em memória e o último criado_em visto em localStorage por usuário,
 * para não repetir ao recarregar; BroadcastChannel avisa as outras abas. Sem ele, o aviso
 * pode aparecer nas duas abas, mas a linha no banco é uma só.
 * O Telegram do check-in não sai mais daqui: é do cron do banco (decisão S4).
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

export function AvisosProvider({ usuarioId, perfil, children }: { usuarioId: string | null; perfil?: string | null; children: ReactNode }) {
  const [naoLidas, setNaoLidas] = useState(0)
  const [noCanto, setNoCanto] = useState<AvisoCentral[]>([])
  const mostradosRef = useRef<Set<string>>(new Set())
  const ultimoRef = useRef<string | null>(null)
  const iniciadoRef = useRef(false)
  const canalRef = useRef<BroadcastChannel | null>(null)
  const abrir = useAbrirAviso(perfil)
  const chave = usuarioId ? `ea_avisos_ultimo_visto:${usuarioId}` : null

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
    if (!chave) return
    await contar()
    const { data, error } = await sb.rpc('meus_avisos', { p_so_nao_lidas: true, p_limite: 20 })
    if (error || !Array.isArray(data)) return
    const lista = data as AvisoCentral[]
    // Outra aba pode ter mostrado e gravado o último visto depois da nossa última leitura.
    const salvo = lerUltimoVisto(chave)
    if (depois(salvo, ultimoRef.current)) ultimoRef.current = salvo
    const maisNovo = lista.reduce<string | null>((m, a) => (depois(a.criado_em, m) ? a.criado_em : m), null)
    if (!iniciadoRef.current) {
      iniciadoRef.current = true
      // Primeira leitura sem marca salva (primeiro acesso neste aparelho): o que já estava
      // na caixa vai para o contador e a Central, sem enfileirar avisos antigos no canto.
      if (!ultimoRef.current) {
        lista.forEach(a => mostradosRef.current.add(a.id))
        if (maisNovo) { ultimoRef.current = maisNovo; gravarUltimoVisto(chave, maisNovo) }
        return
      }
    }
    const comparar = (a: AvisoCentral) => new Date(a.criado_em).getTime()
    const corte = ultimoRef.current ? new Date(ultimoRef.current).getTime() : null
    const novos = lista
      .filter(a => !mostradosRef.current.has(a.id) && (corte === null || comparar(a) > corte))
      .slice(0, MAX_NO_CANTO)
    lista.forEach(a => { if (corte !== null && comparar(a) <= corte) mostradosRef.current.add(a.id) })
    if (!novos.length) return
    novos.forEach(a => mostradosRef.current.add(a.id))
    if (maisNovo && depois(maisNovo, ultimoRef.current)) {
      ultimoRef.current = maisNovo
      gravarUltimoVisto(chave, maisNovo)
    }
    canalRef.current?.postMessage({ tipo: 'mostrados', ids: novos.map(a => a.id), ultimo: ultimoRef.current })
    mostrar(novos)
  }, [chave, contar, mostrar])

  const atualizar = useCallback(() => {
    contar()
    canalRef.current?.postMessage({ tipo: 'atualizar' })
  }, [contar])

  useEffect(() => {
    if (!usuarioId) return
    mostradosRef.current = new Set()
    ultimoRef.current = null
    iniciadoRef.current = false
    let canal: BroadcastChannel | null = null
    try {
      canal = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel(`ea-avisos-${usuarioId}`) : null
    } catch { canal = null }
    canalRef.current = canal
    if (canal) {
      canal.onmessage = (ev: MessageEvent) => {
        const m = ev.data as { tipo?: string; ids?: string[]; ultimo?: string | null }
        if (m?.tipo === 'mostrados') {
          (m.ids ?? []).forEach(id => mostradosRef.current.add(id))
          if (depois(m.ultimo, ultimoRef.current)) ultimoRef.current = m.ultimo ?? null
          contar()
        } else if (m?.tipo === 'atualizar') {
          contar()
        }
      }
    }
    verificar()
    const t = window.setInterval(verificar, INTERVALO_AVISOS_MS)
    return () => { window.clearInterval(t); canal?.close(); canalRef.current = null }
  }, [usuarioId, verificar, contar])

  return (
    <AvisosContext.Provider value={{ naoLidas, atualizar }}>
      {children}
      {noCanto.length > 0 && (
        <div
          data-teste="avisos-canto"
          style={{ position: 'fixed', top: '64px', right: '16px', zIndex: 9000, display: 'flex', flexDirection: 'column', gap: '8px', maxWidth: '360px', width: 'calc(100% - 32px)' }}
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
      )}
    </AvisosContext.Provider>
  )
}
