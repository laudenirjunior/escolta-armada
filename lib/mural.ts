/**
 * Mural de escoltas, lote 2026-10 (M5): estado das travas vindo do servidor.
 *
 * As regras (janela, presença, aprovação, sobreposição, escala fixa) são todas
 * validadas nas RPCs da migration 204. Aqui fica só o que a tela precisa para mostrar
 * o botão certo e a hora certa. Horários sempre em Brasília.
 */

export interface InfoMural {
  janela_inicio: string
  escala_fixa: boolean
  /** Lido pelo servidor: o operador não enxerga o efetivo dos colegas pela RLS. */
  tem_equipe: boolean
  /** Nomes de quem da equipe atual confirmou presença na base, ou null. */
  presenca: string | null
  eu_confirmei: boolean
  sou_da_equipe: boolean
  pedido: { id: string; expira_em: string; meu: boolean } | null
}

export type MapaInfoMural = Record<string, InfoMural>

export function horaBrasilia(iso: string | null | undefined): string {
  if (!iso) return '--:--'
  return new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' })
}

// Função ausente (master sem a 204) ou sem permissão: o mural antigo vale. Qualquer outro
// erro (rede, tempo esgotado, 500) é passageiro.
const CODIGOS_SEM_TRAVAS = ['PGRST202', '42883', '42501']

/**
 * Lê o estado do mural. `ativo` falso: a migration 204 ainda não foi aplicada.
 * Onda G: erro passageiro ganha uma nova tentativa; se persistir, volta `falhou` e a
 * tela mantém o último estado lido em vez de tratar o mural como desligado.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function lerInfoMural(sb: any, ids: string[]): Promise<{ ativo: boolean; info: MapaInfoMural; falhou?: boolean }> {
  const chamar = () => ids.length === 0 ? sb.rpc('mural_travas_ativas') : sb.rpc('mural_info', { p_escolta_ids: ids })
  const semTravas = (e: { code?: string } | null) => Boolean(e && CODIGOS_SEM_TRAVAS.includes(e.code ?? ''))
  // O construtor do supabase-js só tem then (sem catch): a falha de rede vira erro aqui.
  const tentar = async (): Promise<{ data: unknown; error: { code?: string; message?: string } | null }> => {
    try { return await chamar() } catch (e) { return { data: null, error: { message: String(e) } } }
  }
  let r = await tentar()
  if (r.error && !semTravas(r.error)) {
    await new Promise(ok => setTimeout(ok, 1500))
    r = await tentar()
  }
  if (!r.error) return { ativo: true, info: ids.length === 0 ? {} : ((r.data ?? {}) as MapaInfoMural) }
  if (semTravas(r.error)) return { ativo: false, info: {} }
  return { ativo: false, info: {}, falhou: true }
}

/** GPS do aparelho, sem bloquear: sem sinal ou sem permissão volta null. */
export function lerGps(timeoutMs = 10_000): Promise<{ lat: number; lng: number; precisao: number } | null> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return resolve(null)
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, precisao: p.coords.accuracy }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30_000 },
    )
  })
}

/** "Estou na base" (T2). Devolve a mensagem de erro da RPC, ou null se deu certo. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function confirmarPresencaBase(sb: any, escoltaId: string): Promise<string | null> {
  const gps = await lerGps()
  const { error } = await sb.rpc('confirmar_presenca_base', {
    p_escolta_id: escoltaId,
    p_lat: gps?.lat ?? null,
    p_lng: gps?.lng ?? null,
    p_precisao: gps?.precisao ?? null,
  })
  return error ? (error.message ?? 'Não foi possível confirmar a presença.') : null
}
