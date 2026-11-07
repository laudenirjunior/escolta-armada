/**
 * Sessão sem internet (Lote 2026-10, onda L; docs/14, seção 16.3.5): o perfil do último login
 * fica no snapshot por auth_user_id, para o app abrir sem rede sem mandar ao login (o primeiro
 * login sempre exige internet). Logout e troca de usuário apagam o snapshot e o cache de
 * dados do service worker daquele usuário; a fila de registros fica (é dele e só ele envia).
 */
import { apagarSnapshots, filaDisponivel, lerSnapshot, salvarSnapshot } from './fila.ts'

const CHAVE_ULTIMO = 'escolta-campo:ultimo-usuario'
const CHAVE_PERSISTIR = 'escolta-campo:persistir-pedido'

/** Erro de rede (fetch sem resposta), não recusa do servidor. */
export function ehErroDeRede(e: unknown): boolean {
  const m = String((e as { message?: string } | null)?.message ?? e ?? '')
  const n = String((e as { name?: string } | null)?.name ?? '')
  // SEM_CONEXAO: resposta do service worker sem rede e sem cópia guardada (parte 2).
  if ((e as { code?: string } | null)?.code === 'SEM_CONEXAO') return true
  return n === 'AuthRetryableFetchError' || n === 'TypeError'
    || /failed to fetch|fetch failed|networkerror|network request failed|load failed|err_internet/i.test(m)
}

export function semRede(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false
}

/** Mensagem ao service worker (sem SW, não faz nada). */
export function avisarServiceWorker(msg: Record<string, unknown>): void {
  try {
    const sw = typeof navigator !== 'undefined' ? navigator.serviceWorker : undefined
    if (!sw) return
    const mandar = (alvo: ServiceWorker | null | undefined) => { try { alvo?.postMessage(msg) } catch { /* sem SW */ } }
    if (sw.controller) mandar(sw.controller)
    else void sw.ready.then(r => mandar(r.active)).catch(() => {})
  } catch { /* sem SW */ }
}

/** Login com internet: guarda o perfil para abrir sem rede e avisa o SW do usuário atual. */
export async function lembrarUsuario<T>(authUserId: string, perfil: T): Promise<void> {
  try {
    const anterior = globalThis.localStorage?.getItem(CHAVE_ULTIMO)
    globalThis.localStorage?.setItem(CHAVE_ULTIMO, authUserId)
    if (anterior && anterior !== authUserId) avisarServiceWorker({ tipo: 'sair', authUserId: anterior })
  } catch { /* sem localStorage: abre offline só se o navegador tiver a sessão */ }
  avisarServiceWorker({ tipo: 'usuario', authUserId })
  if (!filaDisponivel()) return
  try {
    await apagarSnapshots({ excetoUsuario: authUserId })
    await salvarSnapshot(authUserId, 'perfil', perfil)
  } catch { /* sem espaço: segue online */ }
}

/** Perfil guardado do último login (abrir sem internet). */
export async function perfilOffline<T>(authUserId?: string | null): Promise<{ authUserId: string; perfil: T } | null> {
  let id = authUserId ?? null
  if (!id) { try { id = globalThis.localStorage?.getItem(CHAVE_ULTIMO) ?? null } catch { id = null } }
  if (!id || !filaDisponivel()) return null
  try {
    const s = await lerSnapshot<T>(id, 'perfil')
    return s ? { authUserId: id, perfil: s.dados } : null
  } catch { return null }
}

/** Logout: apaga o snapshot e o cache de dados do SW deste usuário; a fila fica. */
export async function esquecerUsuario(authUserId: string | null): Promise<void> {
  try { globalThis.localStorage?.removeItem(CHAVE_ULTIMO) } catch { /* sem localStorage */ }
  if (authUserId) avisarServiceWorker({ tipo: 'sair', authUserId })
  if (authUserId && filaDisponivel()) { try { await apagarSnapshots({ doUsuario: authUserId }) } catch { /* segue */ } }
}

/** navigator.storage.persist() pedido uma vez, no primeiro login do aparelho. */
export async function pedirArmazenamentoPersistente(): Promise<boolean | null> {
  try {
    if (globalThis.localStorage?.getItem(CHAVE_PERSISTIR)) return null
    globalThis.localStorage?.setItem(CHAVE_PERSISTIR, new Date().toISOString())
  } catch { /* pede mesmo assim */ }
  try {
    const st = typeof navigator !== 'undefined' ? navigator.storage : undefined
    if (!st?.persist) return null
    return await st.persist()
  } catch { return null }
}

/** Pede ao SW que guarde o HTML destas telas (e os scripts que elas citam) para abrir sem internet. */
export function precarregarTelas(caminhos: string[]): void {
  if (!caminhos.length) return
  avisarServiceWorker({ tipo: 'precarregar', urls: Array.from(new Set(caminhos)) })
}

/**
 * Campo (carregar, com internet): guarda as escoltas do operador (com versao_gestao) para a
 * tela abrir sem rede e pede ao SW o HTML do detalhe de cada uma (16.3.6).
 */
export async function salvarEscoltasOffline<T extends { id: string }>(authUserId: string, escoltas: T[]): Promise<void> {
  if (filaDisponivel()) {
    try { await salvarSnapshot(authUserId, 'escoltas', escoltas) } catch { /* sem espaço: segue online */ }
  }
  precarregarTelas(['/dashboard/campo', '/dashboard', ...escoltas.map(e => `/dashboard/escoltas/${e.id}`)])
}

/** Campo sem internet: as escoltas guardadas no último carregar com rede. */
export async function escoltasOffline<T>(authUserId: string): Promise<T[] | null> {
  if (!filaDisponivel()) return null
  try { return (await lerSnapshot<T[]>(authUserId, 'escoltas'))?.dados ?? null } catch { return null }
}
