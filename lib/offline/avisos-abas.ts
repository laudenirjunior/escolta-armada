/**
 * Aviso entre abas do mesmo aparelho (BroadcastChannel). Teste de 12/11/2026: a aba do detalhe
 * continuou na etapa antiga depois do avanço feito no Campo, até recarregar. Sem rede, nem o
 * tempo real nem a releitura do servidor mostram o registro guardado; este aviso faz as outras
 * abas relerem (cópia do aparelho + fila) na hora em que a fila muda.
 *
 * - "guardado": registro novo na fila deste aparelho (status otimista nas outras abas);
 * - "enviado": o envio concluiu um registro (aplicado, conflito ou recusado).
 *
 * Sem BroadcastChannel (navegador antigo), não faz nada: ficam os outros gatilhos.
 */
export const CANAL_ABAS = 'escolta-campo-fila'

export interface AvisoAbas {
  tipo: 'guardado' | 'enviado'
  escoltaId: string
  clientId?: string
}

type Canal = { postMessage(m: unknown): void; close(): void; onmessage: ((ev: { data: unknown }) => void) | null; unref?: () => void }

function novoCanal(): Canal | null {
  try {
    const BC = (globalThis as { BroadcastChannel?: new (nome: string) => Canal }).BroadcastChannel
    if (typeof BC !== 'function') return null
    const c = new BC(CANAL_ABAS)
    // Node (testes): não segura o processo aberto. No navegador, não existe.
    c.unref?.()
    return c
  } catch { return null }
}

let emissor: Canal | null | undefined

/** Avisa as OUTRAS abas (o BroadcastChannel não entrega na própria). Nunca lança. */
export function avisarOutrasAbas(aviso: AvisoAbas): void {
  try {
    if (emissor === undefined) emissor = novoCanal()
    emissor?.postMessage(aviso)
  } catch { /* aviso é só conveniência */ }
}

function ehAviso(d: unknown): d is AvisoAbas {
  const a = d as AvisoAbas | null
  return !!a && (a.tipo === 'guardado' || a.tipo === 'enviado') && typeof a.escoltaId === 'string'
}

/** Ouve os avisos das outras abas; devolve a função que para de ouvir. */
export function ouvirOutrasAbas(fn: (aviso: AvisoAbas) => void): () => void {
  const c = novoCanal()
  if (!c) return () => {}
  c.onmessage = (ev) => { if (ehAviso(ev.data)) { try { fn(ev.data) } catch { /* ouvinte não derruba */ } } }
  return () => { c.onmessage = null; c.close() }
}

/** Só para os testes. */
export function fecharAvisosAbas(): void {
  try { emissor?.close() } catch { /* nada */ }
  emissor = undefined
}
